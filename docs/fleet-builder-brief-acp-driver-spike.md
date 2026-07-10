# Fleet builder brief — ACP driver spike (Vikunja #759)

*Approved program of record: LA accepted 2026-07-07. Origin + full rationale: blarai `docs/research/agent-protocol-evaluation-2026-07.md` (status APPROVED — read §4–§6 before starting). Ticket: Vikunja **#759** (project 4). Authored 2026-07-07.*

---

## 0. Read this first — comprehension gate (non-negotiable)

Before any substantive action: ground yourself on disk with the first-action reads below (≤6 items), then present a comprehension gate — your own-words understanding of the role, the task, the scope fence, and the risks — and **WAIT for LA confirmation**. Approval of the spike is not approval to skip the gate.

First-action reads:
1. This brief, in full.
2. blarai `docs/research/agent-protocol-evaluation-2026-07.md` §4–§6 (the seam map + the approved opportunity).
3. `scripts/fleet-lib.ps1:130-282` (`Invoke-AgentRun` — how opencode is driven today) and `:244-259` (`Get-AgentTranscriptSignals` region — the transcript-regex progress inference).
4. blarai `tools/dispatch_harness/monitor.py:91-210` (`RunSignals` + `classify_run_health` — the mtime/CPU doom heuristic this spike would subsume).
5. `configs/opencode.json` (the `local` provider → `http://127.0.0.1:8099/v3`; permissions; plugins load from `configs/opencode-plugins/`).
6. Vikunja #759 (the ticket carries the decision record, including the A2A watchlist disposition).

## 1. What this spike is — and is not

**Is:** a bounded, **side-by-side** experiment. Drive ONE real coder candidate build through opencode's native **ACP** (Agent Client Protocol — the Zed/JetBrains editor↔agent standard: JSON-RPC 2.0 over stdio, persistent session, typed event stream) and A/B it against the production `opencode run` + transcript-regex path. Output: measurements + a go/no-go recommendation. **The production fleet path is not modified in any way.**

**Is not:** an integration (if GO, integration is scoped as a follow-up ticket for LA review); not an A2A/agent-federation build (A2A is watchlist-only — see #759); not a fix for coder capability (F2 / the p^N length ceiling is a model problem, untouched by transport); not a change to opencode↔OVMS (the `:8099` repair proxy and OpenAI-compatible HTTP stay exactly as they are — ACP sits between the *harness* and *opencode*, never between opencode and the model).

## 2. Verified starting state (2026-07-07) — re-verify before starting

| Fact | Verified how | Re-verify with |
|---|---|---|
| opencode **1.17.8** installed (npm), ships **`opencode acp`** ("start ACP (Agent Client Protocol) server") | `opencode --help` on this machine, 2026-07-07 | `opencode --version; opencode --help` |
| **F1** path-mangling fix SHIPPED: `configs/opencode-plugins/path-normalize.js` (+ test), main, 2026-06-30 | `ls configs/opencode-plugins/` | same |
| **F3** offline-only seed SHIPPED: `Add-WebHint` (`scripts/fleet-lib.ps1:576-597`) | fleet-map grounding pass | grep `Add-WebHint` |
| Python SDK **`agent-client-protocol` 0.11.0** installs + `import acp` works on **py -3.14** | throwaway venv, 2026-07-07 | fresh venv install; **pin 0.11.0** (pre-1.0 — API may move) |
| ACP protocol **v1** stable; schema-v1.19.0 (2026-07-06); a v2 is drafting | web research 2026-07-07 (sources in the evaluation doc §7) | agentclientprotocol.com |
| OVMS serves the coder at `http://127.0.0.1:8000/v3`; opencode talks to the repair proxy `:8099/v3` | `configs/opencode.json:5-37`, `tools/qwen-proxy.py` | read those files |

The approved sequencing condition ("after F1/F3") is therefore **already met**. The spike needs a **machine-free window**: the 30B occupies the GPU, so no battery/dispatch may be running (and the spike must not run during one).

## 3. The seam today (what we are A/B-ing against)

- **Invocation:** `Invoke-AgentRun` spawns `opencode run --dir <worktree> -m local/<id> [--format json] <prompt>` per turn via `Start-Process` (`scripts/fleet-lib.ps1:130-282`), with three hard-won workarounds: an **empty-stdin file** (headless opencode blocks on non-EOF stdin), **`ConvertTo-Win32Arg`** single-argv quoting (array args space-split the prompt), and **direct-exe spawn** (cmd mis-parses `< > & |`). `OPENCODE_GIT_BASH_PATH` pins bash to git-bash (`:167`).
- **Progress:** regex over the JSON transcript logfile — `"type":"step_finish"` counts and `"tool":"(write|edit|patch|multiedit)"` counts (`:244-259`) — feeding `Resolve-RunStopDecision` (`:345-385`, idle-vs-ceiling kill) and, on the BlarAI side, `classify_run_health` (file-mtimes across seven artifact families + psutil CPU ≥5% over `stall_grace_s=90`, `monitor.py:91-210`).
- **Termination:** process-tree kill on timeout; #757 added honest TIMED-OUT labeling on both kill paths.

The spike's thesis: ACP's `session/update` stream (typed `tool_call`/`tool_call_update` events with status transitions, `plan`, message/thought chunks, `usage_update`) plus StopReasons (`end_turn` / `cancelled` / `max_tokens` / `refusal`) and `session/cancel` replace all of the above with protocol primitives.

## 4. Spike protocol

1. **Recon (no GPU needed):** run `opencode acp` bare in a scratch dir; handshake by hand or via the SDK (`initialize` → confirm `protocolVersion: 1`, capabilities). Establish: does ACP mode load the project config (`opencode.json`) and plugins (`path-normalize.js`)? Does it honor `--dir`/cwd and `-m local/coder-30b` model selection (flag, config, or session param)? Document the exact invocation.
2. **Harness:** a minimal Python ACP client (py -3.14 + `agent-client-protocol==0.11.0`, or raw ndjson JSON-RPC if the SDK fights Windows) in `tools/acp_spike/` — spawn `opencode acp` with cwd = a throwaway git worktree, `session/new` (declare fs/terminal capabilities OFF so opencode uses its own tools, matching today's behavior), `session/prompt` with a real fleet-style build prompt (reuse a recent baseline task's prompt verbatim), append every `session/update` to `state/acp-spike/events-<ts>.ndjson`, auto-answer `session/request_permission` per current fleet posture (allow within the worktree — mirror `opencode.json` permissions; log every grant).
3. **Live run (machine-free window):** `scripts/start-llm.ps1 -Model coder-30b -Force`, wait READY, run ONE candidate build through the harness end-to-end. Capture wall-clock, event stream, final StopReason, and the produced diff.
4. **Baseline:** the same task via the production `Invoke-AgentRun` path (or reuse a recent recorded run of the same task if byte-comparable), capturing the same measures.
5. **Stall probe:** induce a hang (e.g., suspend the OVMS process briefly, or prompt a deliberately blocking command) under both paths; measure time-to-detection: "no `session/update` for N s" vs the mtime+CPU heuristic. Then prove **cooperative cancel**: `session/cancel` → confirm `cancelled` StopReason + clean subprocess exit, tree-kill only as backstop.
6. **Write-up:** results section appended to this brief + go/no-go on #759. If GO: scope the integration (which side owns the ACP client — `fleet-lib.ps1` driver vs the Python monitor — plus event-schema mapping to `journal.log`/scorecard) as a **follow-up ticket for LA decision**. Do not integrate in the spike.

## 5. Measurements + evidence (record, don't narrate)

To `state/acp-spike/` + the results section here: (a) **event fidelity** — count of tool_call/status events vs `step_finish` regex hits for the same run; any activity invisible to one side; (b) **stall latency** — seconds-to-DOOMED under each path; (c) **Windows robustness** — deadlocks/CRLF framing issues/orphaned processes (none tolerated); cancel behavior; (d) **overhead** — wall-clock delta ACP vs `run` path; (e) exact versions (opencode, SDK, protocol schema) for reproducibility.

## 6. Gotchas and traps (hard-won — do not relearn these)

- **The empty-stdin trick does NOT apply to ACP mode** — stdin *is* the protocol channel. Never close it; frame per the spec (newline-delimited JSON-RPC; verify framing in recon and watch CRLF on Windows).
- **The argv-quoting problem should disappear** (the prompt travels as JSON, not argv) — but verify no shell is involved in spawning `opencode acp` (spawn the exe/ps1 directly, vector argv, as `_pwsh()`/`Invoke-AgentRun` already do).
- **Config/plugin parity is the load-bearing unknown.** If `opencode acp` does not load `opencode.json` + `configs/opencode-plugins/` (F1 path-normalize, command-timeout, qwen-sampling) the coder behaves differently than production and the A/B is invalid — establish this in recon step 1 before burning a GPU window. If plugins don't load in ACP mode, that alone is a NO-GO finding (report it upstream; opencode is Apache-2.0 and actively developed).
- **`OPENCODE_GIT_BASH_PATH` and the env** must be set identically to `Invoke-AgentRun`'s environment (`fleet-lib.ps1:167`) or bash-tool behavior diverges.
- **Windows asyncio:** py 3.14 + subprocess pipes needs the Proactor event loop (default on Windows — don't switch to Selector).
- **Do not point the spike at a real project repo.** Throwaway worktree under `C:/Users/mrbla/projects/` sandbox conventions only; the secret-scan and worktree-location guards still apply if any fleet script is reused.
- **One model at a time:** the 14B must not be resident (BlarAI app closed / stepped aside) — this is a 30B-standalone scenario, the MARGINAL-but-sound case from the swap measurement.

## 7. Definition of done

- [ ] Recon findings recorded (ACP invocation, config/plugin parity verdict, framing).
- [ ] One real candidate build completed through ACP with full NDJSON event capture, plus the baseline comparison.
- [ ] Stall + cooperative-cancel probes measured under both paths.
- [ ] A/B table + go/no-go recommendation appended here; #759 commented with the verdict and evidence paths.
- [ ] Zero changes to production fleet scripts; harness confined to `tools/acp_spike/` + `state/acp-spike/`.
- [ ] BUILD_JOURNAL fragment (blarai `docs/journal_fragments/`) per journal discipline.

## 8. Out of scope

A2A / Agent2Agent anything (watchlist-only, two revisit triggers on #759); integration into `run-fleet.ps1`/`fleet-lib.ps1`; changes to the review side (#688 item 5 FREEZE stands); the `:8099` proxy and OVMS flags; F2 (coder stalls rooted in model capability); editor/UI attach surfaces.

## 9. Biggest residual risk

**ACP-mode parity on Windows headless** — that `opencode acp` under a Python-spawned stdio session behaves differently from `opencode run` (config/plugins/model routing/tool behavior), or that Windows stdio framing is flaky. This is precisely what the spike exists to measure, and recon (step 1, no GPU) resolves most of it before the live window. Secondary: SDK churn (0.11.0 pre-1.0; protocol v2 drafting) — pinned versions + the protocol's v1 negotiation contain it.

---

## Results (executed 2026-07-09, Arc 140V; full evidence: `state/acp-spike/RESULTS.md`)

**Verdict: GO** for a bounded, decision-gated integration follow-up (new ticket for LA review; nothing integrated in the spike). Substrate: opencode 1.17.8, `agent-client-protocol` 0.11.0 on py-3.14, ACP protocol v1, GPU driver 32.0.101.8826, OVMS `coder-30b` on :8000. Identical prompt on both legs.

**Recon parity gate — PASS (no GPU).** `opencode acp` negotiated protocolVersion 1; loaded the same global `~/.config/opencode/` config (SHA256-identical to repo `configs/opencode.json`) with **both plugins loaded** (`[command-timeout] loaded` + `[path-normalize] loaded`, 0 loader errors, read from opencode's own stderr in ACP mode); model selected via the `set_config_option` `model` config-option (no `-m` flag exists in acp mode); clean Windows stdio framing.

**Measured A/B:**
- **Event fidelity (decisive, transport-attributable):** ACP leg emitted **212 typed events** (34 `tool_call` + 143 `tool_call_update` with pending→in_progress→completed/**failed** lifecycle, typed `kind` edit/execute/read/other, per-call identity, agent messages, `usage_update`, **4 explicit tool failures**) vs the production transcript-regex's **7 integers** (5 `step_finish` + 2 tool-write hits) with no type/status/failure/identity. Categorically richer, independent of run length.
- **Wall-clock (CONFOUNDED — reported honestly):** ACP 1203 s (hit the harness 1200 s ceiling, `stop_reason=null`) vs baseline **117 s (clean, exit 0)** — but this is **coder non-determinism** (opencode `build` agent temp 0.7), NOT transport: the ACP run stochastically fell into an F2 "leftover-operands" debug loop (~15 diagnostic `python -c` probes), the baseline converged. Transport overhead on a single turn is negligible; the multi-turn persistent-session amortization (the fleet's real win) was NOT isolated by this single-turn spike.
- **Stall detection:** ACP idle = "no `session/update` for N s"; measured max healthy inter-event gap **83 s** (cold prefill), p90 29.5 s → safe threshold ~120 s on a **semantic** signal, vs production's indirect mtime + CPU heuristic (`IdleTimeoutSec=240` / monitor `stall_grace_s=90`) whose CPU-idle≠wedged confusion caused the #687 false-doom. Faster + no false-doom class.
- **Cooperative cancel:** `session/cancel` honored in **~2.1 s** on both probes (cancel at 90 s and at 150 s deep in a 6-tool run), clean, no orphans — **but StopReason returned `end_turn`, not the spec's `cancelled`** (opencode 1.17.8 fidelity gap; the integration must track its own cancels).
- **Windows robustness:** framing clean across 4 sessions. **One real finding:** on the hard-timeout path the SDK's connection-close orphaned **9 `node.exe`** children (opencode's runtime tree); the integration MUST reuse the existing `terminate_process_tree` (it already exists). Cancel/clean-exit paths left zero orphans.

**Integration cost: MEDIUM** — a production ACP client (~250 LOC; this harness is a working proof) beside `tools/dispatch_harness/monitor.py`, + event→`journal.log`/scorecard mapping + tree-kill teardown + step/spin cap rebuilt on the event stream + own-cancel tracking + the best-of-N/review-fix loop re-expressed on a persistent session + parity tests. A focused multi-day single-builder effort, behind a flag, A/B'd before cutover — a parallel driver, never a rip-and-replace. **LA capability decision** (changes how the fleet drives the coder) → recommended, drafted as a follow-up ticket, not taken here.
