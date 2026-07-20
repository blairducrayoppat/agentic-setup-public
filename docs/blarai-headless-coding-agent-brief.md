# REFERENCE: BlarAI's Headless Coding Capability — the Fleet Dispatch Contract

**Status:** the feature this brief specified is **BUILT and LIVE** (BlarAI
`[fleet_dispatch].enabled=true` since 2026-06-30; ADR-034/035, Vikunja #670). This
document is now the **reference spec** for the standing contract between BlarAI (the
dispatcher) and this repo's fleet (the execution backend) — slimmed 2026-07-19 from the
357-line build brief (#945 D9; the full original is in git history, and its dated
running-log lessons moved to `docs/LESSONS-LEARNED.md`).
**Maintained by:** the merging session that changes what this file asserts — if your
change alters the queue shape, the swap contract, a script interface, or a port, update
this file in the SAME commit.
**Audience:** any agent working the BlarAI↔fleet seam from either side. The hard
boundary stands: the fleet never inspects/modifies BlarAI's source/orchestration/secrets
(model IR dirs under `BlarAI\models` are shared; code is not).

---

## 1. The architecture in one paragraph

A novice user describes a vague idea to BlarAI's 14B. The flow: **user idea → the 14B
DECOMPOSES** it into small, separately-tested fleet tasks (sized to the 30B's reliable
one-shot capacity) → **ENQUEUE** `{repo,task,prompt,model?}` entries into
`state/fleet-queue.json` → **SWAP** (persist assistant state, release the embedded 14B,
`start-llm.ps1 -Model coder-30b -Force`, wait READY) → **TRIGGER** `run-fleet.ps1` (the
fleet runs the queue serially: worktree isolation, build via OpenCode through the
`:8099` repair proxy, secret-scan, tests, deterministic verify gate, resample,
auto-merge-or-park, a machine-readable `RESULT:` line per task) → **SWAP BACK** (disarm
watchdog, stop OVMS, re-instantiate the 14B fresh, coherence-check) → **READ RESULTS**
(`SUMMARY.txt` + per-task reports) and report to the user. BlarAI never hosts the coding
agent; the 30B never runs against BlarAI's tree; the whole integration surface is a
queue file, a swap, and report files.

## 2. The fleet interface (the standing contract)

**ENQUEUE — `scripts/add-fleet-task.ps1`**
`add-fleet-task.ps1 -Repo <gitdir> -Task <name> -Prompt <text> [-Model local/coder-30b] [-Queue <path>]`
appends to `state/fleet-queue.json` (a JSON array; writing the same shape directly is
equally valid). `-Repo` must be an existing git repo OUTSIDE BlarAI. Enqueue the whole
decomposed set BEFORE triggering.

**EXECUTE — `scripts/run-fleet.ps1`**
`run-fleet.ps1 [-Queue <path>] [-RunId <resume-id>] [-MaxRunMinutes 30] [-MaxReviewMinutes 10] [-OverallBudgetHours 8] [-ServerWaitMinutes 10]`
— serial by design (one resident model); waits for OVMS READY before each task but
NEVER starts/stops models itself (the swap caller owns that); resumable via `done.txt`
+ `-RunId`; wraps each task in a 2-attempt outer retry (so a thrown error can invoke
the per-task script twice — keep tasks idempotent); stops gracefully at the budget.

**PER TASK (fleet-internal — never re-implement):** refuse BlarAI/`.openclaw` repos →
baseline-commit → isolated worktree + `agent/<task>` branch → build via
`opencode run` through `:8099` with no-op retry → gitleaks secret-scan (hit = no
commit, no merge, work left for a human) → tests (forgiving: absent = skip) →
deterministic `verify-project.ps1` gate (the REAL gate) → resample up to 3× on
fail (never on timeout/secret-block) → same-model review (ADVISORY only) →
auto-merge only if `changes ∧ ¬secret ∧ ¬timeout ∧ ¬loop ∧ tests≠fail ∧ verify≠fail ∧
verdict==MERGE`, else PARK on the branch.

**OUTPUTS:** `state/fleet-runs/<RunId>/journal.log` (step trail) · `SUMMARY.txt`
(per-task one-liners — the user-facing source) · `done.txt` (resume) ·
`state/reports/<repo>-<task>-<stamp>.txt` whose **`RESULT:`** line is the
machine-readable outcome: `MERGED …` / `NOT merged …` (parked) / `BLOCKED: …`
(secret) / `Nothing to merge.` — parse it to drive the user report and any
re-decomposition.

## 3. The model-swap contract (Option A — 14B stays embedded; implemented in BlarAI)

The 14B (~10–13 GB) and the 30B (~18–21 GB) cannot coexist in ~31 GB shared RAM. The
swap is owned by BlarAI's shipped swap driver; the contract with THIS repo's scripts:

```
persist assistant state → RELEASE the embedded 14B (full teardown + gc; measure free RAM,
gate on the measured load-peak threshold)
→ start-llm.ps1 -Model coder-30b -Force        (-Force MANDATORY: skips the interactive
                                                memory assistant that offers Stop-VM)
→ wait READY: GET http://127.0.0.1:8000/v3/models, id == coder-30b (raw OVMS :8000 —
  :8099 is the coder CHAT route, not the model-list endpoint)
→ run-fleet.ps1                                 (stay in 30B residency for the WHOLE queue)
→ rm state/server-should-run.txt                (DISARM the watchdog FIRST — always)
→ Stop-Process -Force -Name ovms                (never interactive stop-llm.ps1: it
                                                Read-Hosts and may Start-VM the BlarAI VM)
→ re-instantiate the 14B FRESH + restore state → coherence smoke-check → read SUMMARY
```

**Invariants:** never two large models resident · never end at zero models (every
failure path restores the 14B) · swap-state persisted to disk, idempotent recovery
(default = full teardown + cold 14B load) · disarm before stop, or the watchdog
reloads the 30B and the unload silently fails · one swap per queue, never per-task
(each swap costs 30–90 s of GPU compile) · the `:8099` proxy is fixed infrastructure
(stateless, survives swaps; routing to it lives in `opencode.json`'s local
`baseURL` — confirm it still points at `:8099` before trusting the repair; never
point coder traffic at raw `:8000`).

## 4. Decomposition doctrine (the dispatcher's load-bearing skill)

- **Size each task to the small model's reliable one-shot capacity** — one cohesive
  function/helper per task; split anything with conflicting sub-heuristics. (The 30B
  hit a ~26/27 one-shot ceiling on decomposed helpers vs single digits on a fused
  spec.)
- **Minimize tool-call surface** (success ≈ (1−p)^N): inline the full contract; the
  single biggest win was "your FIRST tool call MUST be WRITE" (1/27 → 21/27).
- **Lean prompts beat example piles** — hand a verified ALGORITHM (26/27), not 14
  worked examples (~0/27). Forbid regex backslash-escapes in JSON tool-writes; short
  relative paths; "re-run tests after every change; never stop while red."
- **PRE-VALIDATE THE RULER before enqueuing:** hand-author each task's acceptance
  tests; prove them satisfiable with a throwaway reference impl; revert to stubs;
  enqueue. Never let the implementer author its own oracle.
- **The same-model review verdict is advisory** — the deterministic gate + the
  pre-validated tests are the verdict; never relax the auto-merge condition. A gate
  you haven't mutation-tested (proved RED on broken code) is theater.
- **Resample converges random slips, not consistent bugs** — the same failure on
  every attempt = spec ambiguity; re-decompose, don't re-enqueue.
- The fleet already retries no-ops and resamples verify-fails; the dispatcher adds
  neither — it sizes tasks so one fresh attempt can plausibly pass.

## 5. DO NOT (the paid-for list, merged and deduplicated)

- Rebuild any fleet stage inside BlarAI (worktrees/build/scan/tests/verify/review/
  merge) — enqueue instead. If you're writing `opencode …` inside BlarAI, stop.
- Run coding work inside BlarAI or `.openclaw` (the fleet THROWS by design — that
  refusal IS the isolation).
- Load the 30B before the 14B is released, or skip the MEASURED free-RAM gate
  (steady-state estimates under-gate the staged load peak → paging death-spiral).
- Stop OVMS without disarming the watchdog, or use interactive `stop-llm.ps1` /
  `start-llm.ps1` without `-Force` in automation.
- Trust the model's self-reports ("done", "tests pass") or the same-model review as
  the sole gate; merge on a verdict alone.
- Bind any server beyond loopback, use the OVMS service installer, or make any
  system-wide OS/firewall/AV change as an agent control (scope controls to the agent
  layer — a machine-wide curl block once broke the operator's box).
- Rely on prompt rules to stop injection — contain instead (read-denies, gitleaks
  fail-closed, worktree gate, external-dir refusal).
- Add a second agent harness; expect parallel coders (serial by design); or swap
  models per-task.

## 6. Formerly-open questions — all RESOLVED (do not relitigate)

- **Embedded-14B unload path:** no first-class GenAI unload API exists (openvino
  #11978 closed without one) — full reference-drop + `gc.collect()` teardown, reload
  as a fresh cold load. On Lunar Lake GPU memory NEVER auto-releases on idle
  (#33896's corruption variant was Panther Lake); the shipped release/reload +
  coherence smoke-check implements exactly this. Watch model_server PR #4332
  (native idle-unload) as the sanctioned future replacement — tracked at #741.
- **Memory/GPU domain:** the 14B runs HOST-side (host-mode topology), so releasing
  it returns RAM where OVMS loads the 30B — measured and shipped (swap driver +
  probe-don't-predict admission, BlarAI #784).
- **VM name / reach:** verified in-tree during the build; the dispatcher runs
  host-side and reads/writes the fleet's state files directly.

## 7. Where the living detail is

- Running lessons: `docs/LESSONS-LEARNED.md` (this repo — the curated change-log; the
  brief's old §10 entries were transplanted there 2026-07-19).
- Per-dispatch coder context: `~/.config/opencode/AGENTS.md` + `configs/opencode.json`
  + `configs/agents/*.md` (these load fresh each task — edits leak into a running
  pass).
- The shipped BlarAI-side implementation: `shared/fleet/*` (swap driver/ops/state,
  decompose, plan-graph, acceptance) + `tools/dispatch_harness/*` in the BlarAI repo.
- Proxy mechanics + timeout hardening: `tools/qwen-proxy.py` (UPSTREAM_TIMEOUT env,
  default 1800 s; fail-loud 504 fallback).
