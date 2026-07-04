# BRIEF: Giving BlarAI a Headless Coding Capability by DISPATCHING to the Fleet

**Audience:** the Claude agent implementing the headless-coding feature *inside* BlarAI. **Author:** the agentic-setup side, which has already built and battle-tested a complete headless coding fleet (30B/OVMS/proxy/decompose/verify/merge) on this exact host, and must not inspect or modify BlarAI's *source/orchestration/internals*.

**The single most important correction in this revision:** the agentic-setup IS ALREADY a headless coding agent — "the fleet." BlarAI does **NOT** build, embed, or re-implement a coding agent. BlarAI's 14B **DISPATCHES** to the fleet: it decomposes the user's idea into fleet tasks, enqueues them, triggers the run, and reads the results back. The new surface inside BlarAI is tiny and file-based (write a queue, trigger a run, read a summary/reports, own the model swap). Because the integration is this thin, the "don't touch BlarAI internals" fence is a near-non-issue — the fleet lives entirely on the agentic-setup side and runs in separate project dirs.

Tags: **[DISCOVER]** = a fact only you can learn in-tree; **[DECIDE]** = a choice only you can make in-tree; **[VERIFY]** = stated from prior knowledge / a different layer, confirm before relying on it; **[ESTIMATE]** = a starting number you must recalibrate by measuring on your box.

**Boundary note (model store is shared; code is not):** `start-llm.ps1` (lines 72, 85) uses `C:\Users\mrbla\BlarAI\models\qwen3-14b` and `...\qwen3-vl-8b-instruct` as IR-path fallbacks. So model IR dirs under `BlarAI\models` are shared on this host (a discovery hint: the coder IR may already be seeded there). The hard boundary is BlarAI's code/orchestration/secrets, NOT its model dirs.

---

## 1. Mission & the one-paragraph DISPATCH architecture

A novice user describes a vague idea ("build a calculator") to BlarAI's 14B AO/PA. The flow:

> **user idea → 14B AO/PA DECOMPOSES** it into an ordered set of small, well-scoped, separately-tested fleet tasks (each sized to the 30B's reliable one-shot capacity), hand-authoring/validating acceptance tests per task → **ENQUEUE**: append `{repo,task,prompt,model?}` entries to `state/fleet-queue.json` (via `add-fleet-task.ps1`, or by writing the JSON directly) → **SWAP (Option A)**: persist AO/PA state, RELEASE the embedded 14B to free RAM, `start-llm.ps1 -Model coder-30b`, wait READY → **TRIGGER**: `run-fleet.ps1` runs the queue serially; per task it isolates a git worktree, builds via OpenCode routed through the `:8099` repair proxy, secret-scans, tests, runs a deterministic verify gate, resamples on failure, reviews, and AUTO-MERGES or PARKS — writing a machine-readable `RESULT:` line per task → **SWAP BACK**: stop the 30B (after disarming the watchdog), re-instantiate the embedded 14B, restore state, coherence smoke-check → **READ RESULTS**: parse `SUMMARY.txt` + per-task reports and report up to the user.

This is fundamentally a **dispatch + resource problem**: BlarAI reuses an existing execution backend, and the only genuinely new hard part is the **model swap** (the 14B and the 30B cannot coexist in \~31 GB shared RAM, so one large model is resident at a time). The orchestration problem (a small model can't one-shot a large spec) is **already solved inside the fleet** — your 14B's job is to feed it well-decomposed tasks, not to re-solve it.

**Two foot-guns the swap automation MUST avoid (both verified against the scripts):** (a) `start-llm.ps1` WITHOUT `-Force` runs an interactive memory assistant that, to free RAM, will offer to `Stop-VM BlarAI-Orchestrator` (lines 127-182) — under Option A that could kill the assistant itself, so **`-Force` is mandatory, not optional**. (b) `stop-llm.ps1` is **interactive** (`Read-Host`, no `-Force` switch) and will `Start-VM` any name left in `state/stopped-vms.txt` (lines 37-38); from automation it degrades (`Read-Host` returns `$null` with no console) but may still try a VM restart — so **do NOT use `stop-llm.ps1` in the swap**; use the deterministic non-interactive path `rm state/server-should-run.txt` then `Stop-Process -Force -Name ovms` (§4.2).

**Premise honesty:** "BlarAI's 14B runs EMBEDDED in-process via OpenVINO GenAI, NOT OVMS" comes from the session FACTS, not from anything the agentic-setup side can independently verify. Treat the embedded-GenAI premise as **[VERIFY]**; the entire Option-A swap (§4) hinges on it and on a working embedded release/reload path inside BlarAI.

---

## 2. The non-negotiables (honor verbatim)

1. **DISPATCH, don't rebuild.** The fleet already builds, isolates, tests, verifies, reviews, and merges. BlarAI enqueues tasks and reads results. Do **NOT** re-implement worktrees, the build loop, the verify gate, secret-scan, resample, review, or auto-merge inside BlarAI. Reuse `add-fleet-task.ps1` / `run-fleet.ps1` / `new-agent-task.ps1` verbatim.
2. **Run coding work OUTSIDE BlarAI.** The fleet refuses any repo under `%USERPROFILE%\BlarAI` or `%USERPROFILE%\.openclaw` (`new-agent-task.ps1` lines 25-27 THROW). Fleet tasks target separate project dirs (e.g. `C:\Users\mrbla\projects\*`). This refusal IS the isolation; don't defeat it.
3. **One large model resident at a time.** \~31 GB shared LPDDR5X; 30B ≈18–21 GB, 14B ≈10–13 GB. They cannot coexist. The swap is mandatory, not an optimization. Never load the 30B before the 14B is released; never end stuck at zero models.
4. **Route the 30B coder traffic through `:8099`, NEVER raw OVMS `:8000`.** The fleet inherits this at the **config layer**, not via any fleet script: OpenCode's `local` provider `baseURL` in `opencode.json` points at `http://127.0.0.1:8099/v3`. **No fleet script passes a port** — `Invoke-AgentRun` (fleet-lib.ps1) just runs `opencode run` and trusts the config; the fleet's own OVMS readiness/model-resolution probes correctly hit raw `:8000` (that is expected — only the *coder chat traffic* must traverse `:8099`). Practical consequence: **confirm `opencode.json`'s local `baseURL` still points at `:8099` before relying on the repair**, and never stand up your own coder client that talks straight to `:8000`.
5. **Honor BlarAI's security/offline posture.** Air-gapped, zero egress; loopback-only binds; scope every control to the agent layer (NEVER a system-wide OS/firewall/AV change); the local 30B is prompt-injectable — contain it (the fleet's read-denies / gitleaks fail-closed / worktree gate / external-dir block do this) and never trust a prompt rule.
6. **Verification is the deterministic gate + the tests, never the model's self-report.** Pre-validate the acceptance ruler up front; mutation-test any gate you add; treat the same-model review verdict as advisory only (§7.3). The fleet already enforces this — don't weaken it.

---

## 3. Reuse the fleet (your execution backend) — the exact interface

The fleet is the whole coding agent. You interact with it through **four files/commands** and read **two outputs**. Nothing else needs to change on the agentic-setup side.

### 3.1 ENQUEUE — `scripts/add-fleet-task.ps1`
```
add-fleet-task.ps1 -Repo <gitdir> -Task <name> -Prompt <text> [-Model local/coder-30b] [-Queue <path>]
```
Appends `{repo,task,prompt,model?}` to `state/fleet-queue.json` (default queue path). The queue is a **JSON array**; the script reads the existing array, appends, and re-serializes wrapped in `@()` so even a single task stays a valid array. **You may also write that JSON directly** (same shape) if calling PowerShell from BlarAI's runtime is awkward — the run side only requires a parseable `[ {repo,task,prompt,model?}, ... ]`. `-Repo` must be an existing git repo (the script warns otherwise; the run side will refuse a non-repo). Enqueue your whole decomposed unit set **before** triggering.

### 3.2 EXECUTE — `scripts/run-fleet.ps1`
```
run-fleet.ps1 [-Queue <path>] [-RunId <id-to-resume>] [-MaxRunMinutes 30] [-MaxReviewMinutes 10] [-OverallBudgetHours 8] [-ServerWaitMinutes 10]
```
- Runs the queue **SERIALLY** (matches the 1-active-agent design — never fan out concurrent coders; one model is resident).
- **WAITS for OVMS to be READY** before each task (polls `Get-LoadedModelId` = `GET /v3/models` first id) up to `-ServerWaitMinutes`; if no model appears it stops cleanly and is resumable. It **NEVER starts or stops models itself** — that is the swap caller's job (yours, in Option A).
- **Resumable:** every processed task is recorded in `done.txt`; re-run with `-RunId <id>` to continue after a crash/reboot/budget-stop without redoing work. Errored tasks are NOT marked done, so a resume retries them.
- **Outer per-task retry:** `run-fleet` wraps each `new-agent-task.ps1` call in a **2-attempt loop** (`maxAttempts=2`, lines 97-111) that retries once more, 10s apart, if the call THROWS, before recording the task errored. **This is a SECOND, outer layer separate from the in-task no-op/verify resamples** (§3.3) — so a single queued task can invoke `new-agent-task.ps1` twice on a thrown error; keep that in mind for idempotency/timing.
- **Budget:** stops gracefully at `-OverallBudgetHours`, resumable.

### 3.3 PER TASK — `scripts/new-agent-task.ps1` (what `run-fleet` calls; do not re-implement)
For each task, in order:
- **Refuse** if `-Repo` is under `BlarAI` / `.openclaw` (THROWS — see §2.2), or not a git repo.
- **Baseline-commit** the repo (handles brand-new repos / dirty interactive state) → create an **isolated git worktree** + `agent/<task>` branch off `main` (or current branch).
- **[1/5] Build** via `opencode run --dir <wt> -m local/<id> <prompt>` (routed through `:8099`) with **retry-on-NO-OP** up to `MaxBuildAttempts` (=3): a small model intermittently makes zero changes (prints a tool call as text, or writes to a denied path); each retry resets to a clean worktree. **Never** retries a timeout.
- **Stage + gitleaks secret-scan** (`secret-scan.ps1`): a hit ⇒ NO commit, NO merge, work left **uncommitted** in the worktree for a human. Clean/unavailable ⇒ commit `agent: <task>`.
- **[2/5] Tests:** npm test (if `package.json`+`node_modules`+a `"test"` script) or pytest (if `pyproject.toml`/`tests/`). **Forgiving:** absent tests = skip (`none`), exit 5 = none; real non-zero = `fail`.
- **[3/5] Deterministic verify gate** (`verify-project.ps1 -Json`, 600s): build/typecheck/lint, **offline-aware** — missing tools/env = `skip`/`none`, real non-zero or hang = `fail`. This is the **real** gate.
- **RESAMPLE** the whole build up to `MaxVerifyAttempts` (=3) iff `(verify==fail OR tests==fail)` AND attempts remain AND **NOT** timed-out AND **NOT** secret-blocked (pure `Test-ShouldResample`). Converges a random per-build slip; resets the worktree between attempts.
- **[4/5] Review agent** (`opencode run --agent review`) ⇒ a final `VERDICT: MERGE` or `VERDICT: FIX FIRST` line (advisory; see §7.3).
- **[5/5] AUTO-MERGE** only if `changes ∧ ¬secretBlocked ∧ ¬timeout ∧ ¬loop ∧ tests≠fail ∧ verify≠fail ∧ verdict==MERGE`, else **PARK** on the branch. Hard wall-clock circuit breakers (`Invoke-AgentRun` tree-kills past the timeout) + doom-loop detection (`Get-RunAnomalies`) throughout. Writes a plain-language report.

### 3.4 OUTPUTS — what you read back
- `state/fleet-runs/<RunId>/journal.log` — every step, structured, timestamped (resumable trail).
- `state/fleet-runs/<RunId>/SUMMARY.txt` — per-task one-liners: `- <task>: <outcome>` + the task's `RESULT:` line + the full-report path. **Read this for the user-facing summary.**
- `state/fleet-runs/<RunId>/done.txt` — processed task ids (for resume).
- `state/reports/<repoName>-<task>-<stamp>.txt` — the per-task report; its **`RESULT:`** line is the machine-readable outcome: **`MERGED ...`** / **`NOT merged ...`** (parked on `agent/<task>`) / **`BLOCKED: ...`** (secret) / **`Nothing to merge.`** Parse `RESULT:` to drive what you tell the user and whether to re-decompose/retry.

### 3.5 The isolation that makes the fence a non-issue
Because (a) the fleet refuses BlarAI/`.openclaw` repos, (b) coding happens in external project worktrees, and (c) BlarAI only writes a queue file + reads report files, **BlarAI never hosts the coding agent and the 30B never runs against BlarAI's tree.** The integration is: write `fleet-queue.json`, own the swap, read `SUMMARY.txt`/reports. That is the entire new surface.

---

## 4. The Option-A model-swap state machine (the one genuinely new hard part)

**Decision made: Option A — keep BlarAI's 14B EMBEDDED in-process.** This is the purest air-gap: no new listening service inside BlarAI's trust domain, the 14B stays where it is, and BlarAI just frees/reloads it around the fleet run.

**Option B (serve the 14B via OVMS) was considered and REJECTED:** putting the 14B behind OVMS would add a second loopback listener inside BlarAI's security-first trust domain and a network surface for the assistant itself, trading air-gap purity for a marginally simpler unload. Air-gap purity won. (One sentence, on the record, so a future reader knows it was deliberate — not an oversight.)

### 4.1 The swap handshake the AO/PA owns
```
persist AO/PA state
  -> RELEASE the embedded 14B            (free ~10-13 GB)
  -> start-llm.ps1 -Model coder-30b -Force   (kills+restarts ovms, loads 30B, ARMS watchdog, starts :8099)
                                             (-Force is MANDATORY: skips the interactive memory
                                              assistant that would otherwise offer to Stop-VM the
                                              BlarAI-Orchestrator VM to free RAM)
  -> wait READY                          (GET http://127.0.0.1:8000/v3/models, id == coder-30b
                                          -- this is RAW OVMS on :8000, NOT the :8099 coder route)
  -> run-fleet.ps1                        (serial queue; fleet owns build/verify/merge)
  -> on finish: rm state/server-should-run.txt   (DISARM the watchdog FIRST)
  -> Stop-Process -Force -Name ovms       (free ~18-21 GB -- do NOT use interactive stop-llm.ps1)
  -> RE-INSTANTIATE the embedded 14B + restore state
  -> coherence smoke-check
  -> read SUMMARY.txt -> report to user
```

### 4.2 The state machine (persist state to disk for crash recovery)
States: `IDLE-14B → UNLOAD-14B → LOAD-30B → CODE → UNLOAD-30B → RELOAD-14B → IDLE-14B`. Persist an explicit swap-state variable to disk so a crash/reboot mid-swap is **recoverable and idempotent** (default recovery action = "tear everything down, cold-load the 14B"). Mirror the fleet's `state/server-should-run.txt` sentinel pattern.

```
IDLE-14B  (embedded 14B serving the AO/PA)

→ UNLOAD-14B   [trigger: user gave a coding idea; AO/PA decomposed it AND enqueued the tasks]
  1. Finish/persist any in-flight 14B generation (NO mid-stream teardown).
  2. Persist AO/PA conversation state to disk (post-swap 14B resumes context).
  3. RELEASE the embedded pipeline: drop ALL refs (pipe/compiled/tokenizer/session) + gc.collect()
     (some builds expose compiled.release_memory()).  [DISCOVER the real release path — §6.1]
  4. MEASURE free RAM. GATE >= a measured load-time-peak threshold (~21 GB [ESTIMATE], the same
     headroom start-llm.ps1 pre-checks for coder-30b; LNL may NOT auto-free — see §6.1).
     FAIL -> retry teardown once; still short -> ABORT to IDLE-14B, tell the user "couldn't free
     memory for the coder." NEVER load the 30B into insufficient RAM (paging death-spiral).

→ LOAD-30B
  1. start-llm.ps1 -Model coder-30b -Force   (it kills+restarts ovms with the qwen3coder flags,
     ARMS the watchdog via server-should-run.txt, and auto-starts the tools\qwen-proxy.py proxy on
     :8099 if free).  -Force IS MANDATORY: without it (lines 116-205) start-llm runs the interactive
     memory assistant which, to free RAM, will OFFER TO Stop-VM 'BlarAI-Orchestrator' (line 178) --
     under the embedded-14B (Option A) premise that is the WRONG thing and could kill the assistant.
     -Force (line 42/116) skips that whole path. Do NOT load the 30B yourself by another path; let
     start-llm own it.
  2. WAIT READY: it polls GET http://127.0.0.1:8000/v3/models (RAW OVMS on :8000, NOT :8099) until
     id==coder-30b (30-90s GPU compile every start), with per-poll HasExited fail-fast, ~240s
     deadline. (run-fleet ALSO waits for READY via the same :8000 probe, so this is belt-and-
     suspenders.) If you implement an INDEPENDENT readiness check, poll :8000 -- :8099 is the
     coder chat route, not the model-list endpoint.
     FAIL (timeout/wrong id/exited) -> ROLLBACK to RELOAD-14B (never strand the user with no model).

→ CODE
  - run-fleet.ps1 -Queue <your queue>.  The fleet dispatches the WHOLE unit set serially through
    :8099, one worktree per task, verify-on-disk per task, auto-merge-or-park, wall-clock breakers.
  - Stay in 30B residency for the WHOLE queue — do NOT swap mid-queue (each swap is 30-90s dead
    GPU compile). Decompose+enqueue first, swap once, run the queue, swap back once.

→ UNLOAD-30B
  1. DISARM the watchdog FIRST: rm state/server-should-run.txt.  (CRITICAL — start-llm armed a
     watchdog that auto-restarts ovms WHILE that file exists; stop ovms without removing it and the
     watchdog reloads the 30B and the 14B RAM is never freed.)
  2. Stop ovms with Stop-Process -Force -Name ovms.  Safe: read-only weights, RAM-only cache.
     DO NOT call stop-llm.ps1 from automation: it is INTERACTIVE (Read-Host, no -Force switch) and
     will offer/attempt Start-VM for any name in state/stopped-vms.txt (lines 37-38). With no console
     its Read-Host returns $null so it degrades, but it can still trigger a VM restart mid-swap.
     (stop-llm DOES also rm server-should-run.txt, so the disarm would be doubly safe via it — but
     the VM side-effect makes the bare Stop-Process path the correct one. Disarm yourself in step 1
     either way: a bare Stop-Process WITHOUT the rm leaves the watchdog armed.)
  3. MEASURE free RAM (separate-process OVMS returns cleanly to the host).

→ RELOAD-14B
  1. Re-instantiate the embedded pipeline FRESH (new LLMPipeline; do NOT resume a half-freed one
     — LNL #33896 -> garbled output).
  2. Restore persisted AO/PA conversation state.
  3. COHERENCE SMOKE-CHECK: one tiny generation must return coherent (not garbled). FAIL -> GPU may
     still hold 30B residue / 14B half-freed; last resort = full BlarAI process restart (OS reclaims
     all GPU/RAM), cold-load 14B.

→ IDLE-14B  (read SUMMARY.txt + per-task RESULT: lines, report results up to the user)
```

### 4.3 Invariants & rollback
- **Never two large models resident at once.** 30B+14B ≈28–29 GB of models alone against a \~15 GB baseline on 31.3 GB usable → demand far exceeds RAM; the first `npm ci`/pytest spike pages and "looks like the AI broke the laptop." Release the 14B *before* loading the 30B; the load-time staged CPU+GPU copy makes a steady-state estimate under-gate, so gate on a **measured** peak (\~21 GB [ESTIMATE], recalibrate).
- **Never end stuck at zero models.** EVERY failure path (release-fail, 30B-load-fail, mid-run crash, coherence-fail) must restore SOME model, preferring the 14B. The fleet itself never strands you (it just stops and is resumable); the danger is the swap.
- **Persist swap-state to disk; make the swap idempotent.** A crash mid-swap resumes to a known state; default to full teardown + cold 14B load.
- **Disarm before stop.** Always `rm state/server-should-run.txt` before `Stop-Process -Force -Name ovms`, or the watchdog reloads the 30B and the unload silently fails. Do NOT use `stop-llm.ps1` (interactive; may `Start-VM` the BlarAI VM).
- **`start-llm` requires `-Force` in automation** (skips the interactive memory assistant that would offer to stop the BlarAI VM).
- **The `:8099` proxy is fixed infrastructure** — stateless, never touches OVMS, survives the whole 14B→30B→14B transition. `start-llm` starts `tools\qwen-proxy.py` once if `:8099` is free; leave it running. (Routing to it is a property of `opencode.json`, not of any fleet script — confirm the config still points there.)

---

## 5. Headless OpenCode — the fleet already drives it (you don't invoke `opencode`)

**You do NOT call `opencode` yourself.** The fleet's `Invoke-AgentRun` (fleet-lib.ps1) runs the real compiled `opencode.exe run --dir <wt> -m local/<id> <prompt>` for you, under a hard wall-clock timeout with tree-kill, capturing the transcript for anomaly scanning. The hard-won mechanics are already baked in and must NOT be re-litigated inside BlarAI:

- **Provider/baseURL (config-level, not script-enforced):** OpenCode's `opencode.json` points the `local` provider at `http://127.0.0.1:8099/v3` (the proxy). `Invoke-AgentRun` passes NO endpoint — routing to `:8099` is purely this config. Select `local/coder-30b`; the fleet qualifies a bare model id to `local/<id>` automatically. **Confirm the config still points at `:8099`** before trusting the repair.
- **Routing through `:8099` is therefore automatic at the config layer** — the multi-turn tool-call repair (§7.1) is inherited; never point the coder at `:8000`. (The fleet's own readiness/model-resolution probes DO use raw `:8000` — that is correct and unrelated to coder chat traffic.)
- **Three already-fixed launch landmines** (do not "improve" them): (a) headless `opencode run` blocks at "init" reading a non-TTY stdin that never EOFs → the fleet feeds an empty stdin file (A/B: stall>60s → completes \~20s); (b) array `-ArgumentList` space-splits the prompt and breaks opencode's parser → the fleet builds a single properly-quoted arg string (`ConvertTo-Win32Arg`); (c) going through `cmd /c` mis-parses prompts containing `< > & |` → the fleet runs `opencode.exe` directly via `Start-Process` (CreateProcess, no shell).
- **Completion detection / merge gate:** the fleet treats clean exit as completion, runs ITS OWN tests + verify gate for the verdict, and never merges on the model's self-report. The wall-clock timeout per task is `MaxRunMinutes`.

If you ever find yourself writing `opencode ...` inside BlarAI, stop — enqueue a fleet task instead.

---

## 6. WHAT YOU MUST DISCOVER INSIDE BLARAI (thinner now — the integration is just dispatch + swap)

The agentic-setup side knows BlarAI only as a black box (a Hyper-V VM whose name `start-llm.ps1` reads generically from `state/stopped-vms.txt` — line 286 — though line 31/178 reference `BlarAI-Orchestrator`; **[VERIFY] the real VM name in-tree**, don't hardcode it) serving a 14B presumed embedded via OpenVINO GenAI. Only three things are genuinely unknowable from outside and on the critical path:

1. **The embedded-14B RELEASE/RELOAD path (the hinge of Option A).** The exact `ov_genai.LLMPipeline`/`CompiledModel`/`Tokenizer`/session handles + wrapper, and the dispose path that *actually* returns RAM+KV cache. There is **no first-class GenAI unload API** (openvino #11978, open since 2022). Practical pattern: drop EVERY reference + `import gc; gc.collect()` to force the C++ destructors that free GPU memory; some builds expose `release_memory()`. **LUNAR-LAKE LANDMINE (openvino #33896):** on LNL (this machine) GPU memory is **NOT auto-released on idle**, and a half-released/re-acquired pipeline produces **GARBLED output** → treat release as a full teardown and reload as a fresh cold load, never a resume. **[DISCOVER]** whether `del + gc.collect()` actually frees on BlarAI's GenAI build — confirm by **MEASURING** (`Get-Counter '\Memory\Available MBytes'`, Task Manager → Shared GPU memory) before letting the 30B load.

2. **AO/PA ↔ fleet reach across the VM boundary, and the memory domain.** Does the 14B run *inside* the VM or a host process? Is the VM's RAM static or dynamic, and how much? **Does releasing the 14B inside the VM actually return RAM to the host where OVMS+the 30B load?** If the VM has static RAM and OVMS runs on the host, freeing the 14B in-VM does NOT help the host (and the naive swap silently fails) — **measure the memory/GPU domain before trusting the swap.** Likewise: how does the AO/PA *reach* `add-fleet-task.ps1` / `run-fleet.ps1` and read `state/fleet-runs/*` — does it run them on the host (cross-VM file/exec), or is BlarAI itself a host process? Resolve this before the swap design is real.

3. **Returning results to the user + persisting state across the swap.** How BlarAI persists/restores the AO/PA conversation across the swap; how it persists swap-state for crash recovery (analogue of `server-should-run.txt`); and the readiness/coherence gate for the embedded 14B post-reload (the OVMS `/v3/models`-id gate doesn't exist in-process — you need an "pipeline loaded + producing coherent output" equivalent). Then map `SUMMARY.txt` + per-task `RESULT:` lines into the AO/PA's user-facing report.

Secondary (lower-risk because the fleet already handles execution): the 30B model id BlarAI's store expects (align with the proxy's `qwen3coder` format map / `FIX_MODELS` — the coder IR may already live under `BlarAI\models`, §boundary note); whether cross-VM loopback to `:8099`/`:8000` is permitted under BlarAI's egress policy (it shouldn't matter if the AO/PA only writes a queue file and the fleet runs host-side, but confirm).

---

## 7. The decompose → enqueue → read-results pipeline (the 14B's actual job)

Your 14B is **not** the coding agent — it is the **decomposer/dispatcher/reporter**. It turns the vague idea into well-scoped fleet tasks, enqueues them, triggers the run, and explains the results. The fleet does the building and verifying.

### 7.1 Why the 30B route works without you touching it (proxy reliability, inherited)
**[VERIFY] — the proxy internals below come from `qwen3coder-toolcall-fix.md` + `tools\qwen-proxy.py`, NOT from the five fleet scripts verified for this brief; treat the internal mechanics (`xmlify_history`/`salvage_tool_calls`/`strip_trailing_tool_marker`, the 14B branch state) as documented-but-unconfirmed-here.** What IS script-confirmed: `start-llm.ps1` (line 259) auto-starts `tools\qwen-proxy.py` on `:8099`; the 14B is loaded with `--tool_parser hermes3` and guided-gen OFF by default (lines 75/81).

OVMS's `qwen3coder` parser is **string-marker-only** (detects a tool call solely via `find("<tool_call>")`/`find("<function=")`, no JSON fallback). In a multi-turn loop the INT4 30B intermittently emits its call as an OpenAI JSON envelope or a stray `<tool_call>` inside `content`; the parser returns `tool_calls=[]`, `finish_reason=stop`, the loop stalls, and echoing the bad turn degrades it to `name=read`. The fix is `tools/qwen-proxy.py` on `:8099`: `xmlify_history` (PREVENTION — rewrite prior tool-call turns into the model's native format as plain text so it never drifts; the decisive lever), `salvage_tool_calls` (RECOVERY — reconstruct a leaked call; fires only when `tool_calls==[]` AND `finish_reason=stop`; hardened to never raise), `strip_trailing_tool_marker` (COSMETIC). Proven in a real OpenCode session (raw `:8000` → 2/3 files, leaks; via `:8099` → 3/3, 0 leaks). **The fleet already routes through `:8099`, so you inherit all of this for free — do not bypass it and do not re-implement it.** Caveats that still matter to you: the fix is **proven only for the 30B (qwen3coder)**; the hermes/14B branch ships **OFF** (no evidence the 14B has the leak — it does parallel one-turn calls — and buffering the slow dense 14B costs latency); and the `:8099` proxy **buffers all chat/completions** (time-to-first-token = full decode), so do NOT wire `:8099` behind a human-facing streaming UI — route interactive 14B chat at its own endpoint, not the proxy. **(Hardened + CONFIRMED LIVE 2026-06-21 — see §10.)** The proxy had a latent footgun: a hardcoded 600s upstream timeout that, on a long coding turn (a large-file generation took 1387s), fired and dropped into an *unrepaired* fallback, leaking the envelope to OpenCode exactly as before the fix. Now fixed in `tools\qwen-proxy.py` (`UPSTREAM_TIMEOUT` env, default 1800s; fallback returns a loud `504` instead of an unrepaired passthrough; every `200` always runs salvage), and re-verified end-to-end through `:8099` (calculator 4 turns / investigation 9 turns / streaming, **0 leaks**) — so the §7.1 mechanics above are now confirmed-here, not just documented. **Transferable to YOUR dispatch layer: a repair/safety wrapper must FAIL LOUD, never silently bypass the protection it exists for** — a timed-out or failed dispatched task must surface as a clear error, never as partial output passed off as success.

### 7.2 The MASTER LESSON + sizing (so your decomposition feeds the fleet well)
A small local model **cannot one-shot a large nuanced spec** (the 30B hit a \~26/27 one-shot ceiling, not promptable, not resamplable to zero; decomposition into 4 small separately-tested helpers reached 61/61). **→ Size each fleet task to the small model's reliable one-shot capacity, give it acceptance tests, compose.** Sizing rules to bake into your prompts:
- **One cohesive function/helper per task.** If a task needs *conflicting* sub-heuristics, split it.
- **Minimize tool-call surface** (success ≈ (1−p)^N over N tool calls): inline the full contract (types, signatures, rules) so the implementer goes straight to write→test. Biggest single win: **"your FIRST tool call MUST be WRITE; do not read/glob"** (1/27 → 21/27).
- **Keep prompts LEAN — hand it a verified ALGORITHM, not a pile of examples** (14 worked examples doom-looped the 30B to \~0/27; a lean prompt with a hand-verified algorithm hit 26/27).
- **Steer off bug-classes:** forbid regex backslash escapes (`\b \w \s` get doubled in JSON tool-writes); demand plain string ops; "re-run tests after every change; revert any change that increases failures; never stop while red." Short, simple, relative paths (the model truncates long absolute paths → writes to the wrong place → no-op).
- The fleet **already resamples** a random per-build slip (`Test-ShouldResample`, up to 3x) and **already retries no-ops** (`Invoke-BuildWithRetry`) — so you do NOT add resampling; just size tasks so a single fresh attempt can plausibly pass.
- **[DECIDE]** the exact reliable size is model/quant-specific — calibrate against a fixed graded task on *your* 30B, not these numbers.

### 7.3 PRE-VALIDATE THE RULER + the weak-self-review caveat (this is YOUR responsibility)
The tests **are** the spec, and the fleet's deterministic verify gate + tests are the **real** acceptance gate — but they are only meaningful if the ruler is correct. So, **up front, before enqueuing**:
- **Hand-author/verify each task's acceptance tests** — never let the implementer author its own.
- **PRE-VALIDATE THE RULER:** write a throwaway reference impl, run the tests; if green, the ruler is correct + satisfiable → revert to stubs and enqueue. (This caught 0 wasted runs where used vs 2 wasted where skipped.) This is the single most load-bearing thing your 14B-as-decomposer must get right.
- **WEAK-SELF-REVIEW CAVEAT:** the fleet's `[4/5]` review agent is the **SAME local model judging itself** — advisory only. The REAL gate is `verify-project.ps1` + the tests. **Never let the 30B grade its own homework as the sole gate**, and never relax the auto-merge condition to depend on the verdict alone. Mutation-resistance: if you ever add a gate of your own, prove it goes RED on broken code before trusting it; a guard you don't mutation-test is theater.
- **Resample converges RANDOM slips, not a consistent bug.** If a task's `RESULT:` shows the same failure every fleet resample, that's a **spec ambiguity** only your 14B/Guide can fix — re-decompose or sharpen the spec/algorithm; don't just re-enqueue the same prompt.

### 7.4 Be honest — the 14B-as-decomposer is the riskiest assumption
Decomposition + test-authoring + algorithm-verification is **harder** than the implementation it decomposes, and a 14B is itself a small model → expecting it to one-shot the *planning* layer is the same failure mode one level up. Practical split **[DECIDE which tier you can afford]**: (1) 14B does the cheap structural part (restate the idea, propose a coarse ordered task list, draft candidate acceptance cases) — first draft for review, never ground truth; (2) **templated decomposition** for known shapes (CRUD module, classifier, CLI command) — hand-authored task templates + ruler skeletons the 14B fills (most reliability comes from here); (3) ruler validation via (a) human PASS/FAIL, (b) a larger local model loaded transiently as Guide (you already pay a swap), or (c) pre-validate-the-ruler via a 30B-run reference impl as a satisfiability check. **Never let the 14B self-certify a decomposition and ship it. [DISCOVER]** whether your 14B produces usable coarse decomposition — measure against hand-authored gold first.

---

## 8. DO NOT — pitfalls already paid for

- **DO NOT rebuild the fleet.** It already does worktrees, build-with-retry, secret-scan, tests, the deterministic verify gate, resample, review, and auto-merge. Enqueue tasks; don't reimplement any of it inside BlarAI.
- **DO NOT run coding work inside BlarAI.** The fleet refuses `BlarAI`/`.openclaw` repos (THROWS) — target external project dirs. Don't try to defeat the refusal.
- **DO NOT add OpenClaw** (or any second agent harness) into this path. The fleet + OpenCode is the proven backend; a parallel harness is untested surface and more to contain.
- **DO NOT load the 30B before releasing the 14B** — they cannot coexist; you'll page into a death-spiral. Release + MEASURE free RAM first.
- **DO NOT stop ovms without first disarming the watchdog** (`rm state/server-should-run.txt`) — otherwise the watchdog auto-restarts the 30B and the 14B RAM is never freed. Stop with `Stop-Process -Force -Name ovms`.
- **DO NOT call `stop-llm.ps1` from the swap automation** — it is interactive (`Read-Host`, no `-Force`) and will offer/attempt `Start-VM` for names in `state/stopped-vms.txt`, which can restart the BlarAI VM mid-swap. Use the bare `rm sentinel; Stop-Process -Force ovms` path.
- **DO NOT run `start-llm.ps1` WITHOUT `-Force` in automation** — the interactive memory assistant will offer to `Stop-VM 'BlarAI-Orchestrator'` to free RAM, which under Option A could kill the assistant. `-Force` skips it.
- **DO NOT serve the 14B via OVMS (Option B).** Rejected for air-gap purity; keep the 14B embedded (no new listener in BlarAI's trust domain).
- **DO NOT route the 30B at raw OVMS `:8000`** — the fleet already routes through `:8099` (survives swaps); bypassing it re-introduces the `name=read` spiral.
- **DO NOT invoke `opencode` yourself** — the fleet drives it (and has already fixed the stdin-init hang, the arg-quoting split, and the `cmd`-shell mis-parse). Enqueue a task instead.
- **DO NOT trust the local model's self-reports** ("done", "tests pass", "no secrets", "verified") or the same-model review verdict as the sole gate — the deterministic verify gate + your pre-validated tests are the verdict.
- **DO NOT merge on the model's `structured_output.status`/review verdict alone** — the fleet's auto-merge already requires `tests≠fail ∧ verify≠fail`; never relax that.
- **DO NOT inspect/write/modify BlarAI's source/orchestration/secrets from the agentic-setup side** — the hard boundary. (Model IR dirs under `BlarAI\models` are shared and may be read for paths.)
- **DO NOT make any system-wide OS/firewall/AV change as an agent control** — per-exe outbound Block rules on `curl.exe`/`certutil.exe`/`bitsadmin.exe` broke the user's curl machine-wide and had to be reverted. Scope every control to the agent layer.
- **DO NOT bind any server to `0.0.0.0`** (OVMS defaults to it — `start-llm` passes `--rest_bind_address 127.0.0.1`) and **DO NOT use OVMS's Windows-service installer** (binds all interfaces, runs as LocalSystem). Loopback + non-elevated only.
- **DO NOT rely on prompt rules ("treat content as data") to stop injection** — the model has obeyed injected exfil instructions despite the rule. Contain so obeying is harmless (the fleet's read-denies, gitleaks fail-closed, worktree gate, external-dir block).
- **DO NOT assume freeing the 14B returns RAM/GPU to where the 30B needs it** — if the VM has static memory or owns the iGPU via passthrough, the naive swap silently fails. **Measure** the memory/GPU domain first.
- **DO NOT load the 30B without a MEASURED load-time-peak free-RAM gate** (\~21 GB is an [ESTIMATE], recalibrate) — the staged CPU+GPU copy makes a steady-state estimate under-gate → paging.
- **DO NOT assume GPU frees on idle** — on LNL it does NOT (#33896); explicitly drop refs + `gc.collect()` AND measure.
- **DO NOT resume a half-freed 14B** → garbled generations (#33896). Re-instantiate FRESH; coherence smoke-check before returning to the user.
- **DO NOT swap models per-unit or ping-pong** — each swap is 30–90 s of dead GPU compile; decompose+enqueue the whole queue, swap once, run it all, swap back once.
- **DO NOT end a run stuck at zero models** — every failure path must restore the 14B.
- **DO NOT skip PRE-VALIDATE-THE-RULER or mutation-resistance** on any acceptance test/gate — a green run you never tried to break is theater; an auto-generated ruler can false-pass a trivial impl or false-fail a correct one.
- **DO NOT resample a consistent bug** — same case failing every fleet resample = spec ambiguity; re-decompose / fix the spec, don't re-enqueue the same prompt.
- **DO NOT over-stuff a task prompt** — more detail backfires on a small model (14 examples → \~0/27); hand it a lean verified algorithm.
- **DO NOT expect parallel coder sessions** — ONE model resident; the fleet runs the queue serially by design.

---

## 9. First-milestone plan (and how to verify each step)

**Goal of milestone 1:** prove BlarAI can DISPATCH one real coding task to the fleet, end-to-end, gated by the fleet's own verify gate — *before* wiring the swap or trusting the 14B's decomposition.

1. **Resolve the reach + memory-domain blockers (§6 #2).** Determine where the 14B runs, whether releasing it returns RAM to where OVMS loads the 30B, and how the AO/PA reaches `add-fleet-task.ps1`/`run-fleet.ps1` + reads `state/fleet-runs/*`. **Verify:** a written answer to "if I release the 14B, does RAM return to where the 30B will load?" backed by a measured before/after (`Get-Counter '\Memory\Available MBytes'` + Task Manager Shared GPU). *Until answered, the swap design is not real.*
2. **Confirm the GPU shared-memory override is set + benchmark raw 30B.** (Intel Graphics Software → Shared GPU Memory Override → \~87% + reboot; without it the 30B decode collapses to \~3.5 t/s.) **Verify:** decode ≥35 t/s on a trivial generation; if \~3.5 t/s, fix the override first.
3. **Exercise the fleet WITHOUT BlarAI, manually.** With the 30B loaded (`start-llm.ps1 -Model coder-30b`), hand-author a tiny task in an external repo (e.g. `C:\Users\mrbla\projects\smoke`), PRE-VALIDATE its ruler (reference impl → green → revert to stubs), `add-fleet-task.ps1`, `run-fleet.ps1`. **Verify:** `SUMMARY.txt` exists; the task's `RESULT:` line is `MERGED` (or a sane PARK); the proxy on `:8099` is up and the build transcript shows the coder routed through it (the proxy file is `tools\qwen-proxy.py` [confirmed]; if it ships a self-test entrypoint, run it — exact self-test filename **[VERIFY]** against the repo, not asserted here). Mutation-check: break the reference impl, confirm the verify gate would have gone `fail` → the task PARKS, not merges.
4. **Drive that same enqueue+run+read-results from BlarAI's runtime (still 14B held; no swap yet — load the 30B manually).** Have the AO/PA write `fleet-queue.json` (or call `add-fleet-task.ps1`), trigger `run-fleet.ps1`, then parse `SUMMARY.txt` + `RESULT:` into a user-facing report. **Verify:** the user-facing message correctly reflects MERGED vs PARK vs BLOCKED for a task you rigged each way; confirm it ran air-gapped (no egress).
5. **Implement the embedded-14B RELEASE/RELOAD (§6 #1) in isolation.** Drop refs + `gc.collect()` (or `release_memory()`); reload FRESH; coherence smoke-check. **Verify:** measured free RAM rises by \~10–13 GB after release and the reloaded 14B passes the coherence check (not garbled — #33896); a half-freed-then-reused pipeline is NEVER used.
6. **Wire the full Option-A swap state machine (§4) around step 4.** Persist swap-state; release 14B → `start-llm.ps1 -Model coder-30b -Force` → wait READY (`GET http://127.0.0.1:8000/v3/models`) → `run-fleet.ps1` → `rm server-should-run.txt` → `Stop-Process -Force -Name ovms` (NOT `stop-llm.ps1`) → reload 14B → smoke-check → read SUMMARY. **Verify:** a forced crash mid-swap resumes to a known state and NEVER leaves zero models resident; pre/post free-RAM assertions hold; the watchdog is provably disarmed before ovms is stopped (RAM actually frees); the BlarAI VM is NEVER touched by the swap; the reloaded 14B is coherent.
7. **Only then trust the 14B decomposer (§7.4).** Measure the 14B's coarse decomposition against hand-authored gold; back it with templates + pre-validate-the-ruler + a human/transient-larger Guide; never self-certify.

**Sequence discipline:** do not advance a step until its verification passes. Steps 1–2 are blockers (resource/reach reality); 3–4 prove dispatch works with no swap; 5–6 are the one genuinely new hard part; 7 is the planning layer. Batch all 30B work into one residency, keep swap-state on disk, and let the fleet journal every step.

## 10. Operational lessons (running log — appended as the agentic-setup side learns more)

> This section grows over time; the user is keeping these docs current *before* handing them to you.
> Each entry = a real lesson from running the stack on this host, and what it means for YOUR build. Newest first.

**2026-06-26 — the highest-leverage lever for a weak local coder is BEST-OF-N sampling with the gate as selector, NOT more reviewers.**
A primary-sourced strategic assessment (BlarAI `docs/research/dispatch-capability-and-leverage-assessment-2026-06.md`,
LA-ACCEPTED, Vikunja epic #688) found the dispatch over-invested in review surfaces — which are *saturated* (METR
clocked added scaffolding at +8pp, statistically insignificant) — while leaving the biggest local lever unpulled. The
models are a real, *length-dependent* ceiling: a \~30B local coder builds a simple app end-to-end only \~15-35% (single
digits multi-feature), success falls ≈ pᴺ with step count, and weak models specifically fail at **self-correction** — so
the serial resample-on-fail loop fights their worst skill. **For you (fleet side):** the verify gate is already the
high-precision SELECTOR that best-of-N needs — the next build generates **N *independent* coder candidates per step and
lets the gate pick the green one, REPLACING** the serial resample (not adding to it). Near-free locally (the marginal
sample is electricity, not API dollars); evidence — a weaker open model went **15.9% → 56%** on SWE-bench Lite via
repeated sampling, beating frontier single-shot (arXiv 2407.21787). Also accepted: feed the spec-blind acceptance tests
to the coder as **input** (not only the gate — \~+30pp for weak models, but the coder must NOT author its own oracle),
**right-size the task envelope** (short gated steps), and evaluate **Devstral-Small-24B / Qwen3-Coder-30B-A3B at INT8**
(INT4 hurts long agentic trajectories disproportionately). GUARDRAIL: **freeze the review side — no fourth reviewer.**
Tracked: #688 (+ children #689-#692), sequenced AFTER the #687 critical-loops queue (#6 design loop / #685 + #9 critic swap).

**2026-06-22 — a git worktree does NOT contain the repo's `.venv`; use the main checkout's venv + `PYTHONPATH`=worktree-root.**
A builder agent working in an isolated BlarAI worktree (`.worktrees/<task>`) ran `python` and hit
`ModuleNotFoundError: No module named 'jwt'`. Cause: a git **worktree is a separate directory and does
not carry `.venv`** (it's gitignored, present only in the main checkout), so `python` fell through to the
*system* interpreter, which has none of BlarAI's deps. **For you:** never rebuild a venv or `pip install`
into the shared one (CLAUDE.md forbids un-approved installs and the deps already exist — BlarAI's `.venv`
has Python 3.11.9 + PyJWT 2.11.0). Run code/tests with the **main checkout's interpreter by absolute path**
(`C:\Users\mrbla\BlarAI\.venv\Scripts\python.exe`) **and** export `PYTHONPATH=<your-worktree-root>` so
imports resolve to *your* code, not `main`'s — critical if the package is editable-installed
(`pip install -e .`) in the venv, or you'd silently test `main` instead of your changes. Sanity-check with
`python -c "import sys; print(sys.executable)"` (must print the `.venv` path). This is exactly the rule the
agentic-setup fleet already encodes — `PYTHONPATH`=worktree-root for both the verify gate and the agent's
own shell (`new-agent-task.ps1` / `fleet-lib.ps1`) — restated here for in-BlarAI builder agents.

**2026-06-21 — scope an `edit`'s oldString to the minimal block, not the whole file.**
The 30B correctly refactored 3 HTML files (inline CSS → a linked stylesheet) but took **\~500s per
edit** — because it matched each *entire file* as the edit `oldString` and re-emitted the *entire file*
as `newString` (≈2× a \~7 KB file of decode per edit; \~25 min for a trivial change). It was verified
correct, just needlessly slow. **For you:** when a fleet task removes/replaces a region of a file, the
task prompt must say *"match ONLY the target block (e.g. the `<style>…</style>` element) as the edit
oldString — never the whole file."* Tiny old/new strings = fast edits and fewer match failures. (Same
family as §7.2's minimize-tool-call-surface, applied to edit sizing.) Also seen: the model reached for
Unix `head` in the PowerShell shell; the live `AGENTS.md` now steers it to the `read`/`grep` tools
instead of shell for reading/searching.

**2026-06-21 — the `:8099` proxy can be silently bypassed by its own timeout (now fixed).**
A real coding turn that generated a large file took 1387s and blew past the proxy's hardcoded 600s
upstream timeout; the timeout threw into a fallback that forwarded the request *unrepaired*, so a leaked
tool-call envelope reached OpenCode as plain text and the write never happened. Fixed in
`tools\qwen-proxy.py`: `UPSTREAM_TIMEOUT` env (default 1800s) + the fallback now returns a loud `504`
instead of an unrepaired passthrough (every `200` always runs salvage). **For you:** (a) you inherit the
fix — dispatched fleet tasks route through the same proxy; (b) if a dispatched task legitimately needs
>1800s of generation, raise `UPSTREAM_TIMEOUT`; (c) **design principle — a repair/safety wrapper must
FAIL LOUD, never silently bypass the protection it exists to provide.** In your dispatch layer, a
timed-out/failed task must surface as a clear error, never as partial output masquerading as success.

**2026-06-21 — the OpenCode `bash` tool runs PowerShell, not Unix bash.**
The 30B repeatedly tried `ls -la` / `mkdir -p` and got PowerShell errors, wasting turns and adding
failure-noise that nudges the INT4 model toward format drift. Mitigation now lives in the live
`~/.config/opencode/AGENTS.md` (read by every fleet task): *"the bash tool is PowerShell; use
Get-ChildItem, New-Item, …"*. **For you:** dispatched tasks inherit this automatically; when you author
task prompts, phrase any shell step in PowerShell, not bash. (Note: this applies to the *fleet's*
OpenCode tool — a Claude Code session you run inside BlarAI has its own separate bash/PowerShell tools.)

**2026-06-21 — context hygiene keeps the small model fast AND in-format.**
In one session the coder inlined a shared `style.css` into every HTML file (after a "can't run the
server" detour it never needed — a linked stylesheet works fine over `file://`), tripling file sizes;
each later write then regenerated a bloated file and the context ballooned — both slowing turns and
raising leak pressure. **For you:** this is the **decompose-small** principle (§7.2) seen from the
runtime side — size each fleet task so its output is small and self-contained, prefer shared/linked
assets over duplication, and rely on the per-task worktrees to keep each task's context tight. Small
tasks aren't just easier to verify; they keep the model out of the degraded zone where it leaks.

---

(Final document saved at `C:\Users\mrbla\agentic-setup\docs\blarai-headless-coding-agent-brief.md`.)
