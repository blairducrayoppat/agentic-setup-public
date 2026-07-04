# BlarAI Builder Brief — Autonomous-Dispatch Harness

**Audience:** a BlarAI builder session/subagent (all work in `C:\Users\mrbla\blarai`).
**Author:** Dispatch LA. **Tracking:** new Vikunja ticket (LA will open). **Goal:** a REUSABLE
Python harness that drives the `/dispatch` pipeline end-to-end **without the WinUI GUI**, so the LA
can run autonomous test dispatches across project types (the "sweep") hands-off.

Lead your final report with a comprehension summary + plan; do NOT merge — leave it on a branch
for the LA's gate. Create your own isolated worktree off `blarai` main
(`git -C C:/Users/mrbla/blarai worktree add C:/Users/mrbla/blarai/.worktrees/harness -b feat/dispatch-harness main`);
NEVER `git checkout`/`switch` the main `blarai` checkout. Verify `git branch --show-current == main`
for the main checkout before assuming anything.

---

## The architecture you're plugging into (verified map — but CONFIRM each API from the refs)

A client drives the gateway, which talks to the AO over IPC; on approve the AO enqueues to the
agentic-setup fleet + steps the 14B aside for the 30B. The harness is a **headless gateway driver**.

- **Transport (dev path):** TCP loopback `127.0.0.1:5001`, 4-byte length-prefix + JSON envelope.
  `shared/ipc/vsock.py` (`VsockTransport`, `VsockConfig`, `VsockAddress`, `dev_mode=True`);
  `shared/ipc/protocol.py` (`MessageFramer` — the `encode_*`/`decode_*` methods + `MessageType`).
- **The gateway dispatch entry:** `services/ui_gateway/src/transport.py` `TransportGateway` — it owns
  the real plan/execute wiring (`_dispatch_plan_fn` \~:977, `_dispatch_execute_fn` \~:1031) and a
  command entry (CONFIRM the exact method — the map says `handle_dispatch_command(session_id, cmd)`).
  Its dispatch logic lives in `services/ui_gateway/src/dispatch_coordinator.py`
  (`parse_dispatch_command`, `handle_command`, `_status`, the Inc-4 clarifying sub-state).
- **AO handlers:** `services/assistant_orchestrator/src/entrypoint.py` `_handle_plan_request`
  (\~:1773, runs `generate_plan` from `shared/fleet/acceptance.py`) and `_handle_execute_request`
  (\~:1819, `execute_swap_dispatch` → enqueue + spawn `run-fleet.ps1` + step aside).
- **Config gate:** `services/assistant_orchestrator/config/default.toml` `[fleet_dispatch].enabled`
  (+ `[ipc].vsock_port`, `agentic_setup_dir`, `projects_dir`, swap gates).
- **Run state / outcome:** `agentic-setup/state/fleet-runs/<RunId>/` (`SUMMARY.txt`); read via
  `shared/fleet/dispatch.py` `read_summary`/`parse_summary` → `TaskOutcome.result` ∈
  {MERGED, PARKED, BLOCKED, NOTHING, UNKNOWN}. The coder agent log:
  `agentic-setup/state/reports/<proj>-<stamp>.agent.log`; the fleet orchestrator log:
  `agentic-setup/state/fleet-runs/<RunId>/run-fleet-*.log`; OVMS:
  `agentic-setup/state/logs/ovms-*.out.log`.
- **Reuse the test patterns:** `tests/integration/test_dispatch_coordinator.py` (how the coordinator
  is constructed + the clarify/approve flow + injected `plan_fn`/`execute_fn`),
  `test_fleet_dispatch.py` (`read_summary`/`parse_summary`), `test_shared_ipc_transport.py` (the
  dev-mode TCP transport bring-up). **Confirm every signature against the real code — the map above
  has some guessed names.**

## Design (LA-locked)

1. **Drive the REAL gateway path, don't reinvent the IPC.** Construct the real `TransportGateway`
   (dev_mode, host=127.0.0.1, port=5001, `fleet_dispatch_enabled=True`, the agentic-setup/projects
   dirs) and drive its command entry exactly as the WinUI would: send the `/dispatch <repo> | <goal>`
   string, read the reply, handle a clarifying question, send `/dispatch approve`. If a clean
   command entry isn't exposed, drive the `DispatchCoordinator` with the gateway's real
   `plan_fn`/`execute_fn` (the transport calls to the AO). Either way the harness reuses the
   coordinator + the IPC + the swap — it is a headless WinUI, NOT a second implementation.
2. **The AO must be running** (the 14B + swap infra). v1: the harness CONNECTS to a running AO at
   `:5001` and FAILS CLEARLY (a helpful message) if it can't reach it / dispatch is disabled. If you
   can find a small dev-mode AO-start (no admin/VM), add an optional `--bring-up` that starts it;
   otherwise document "start the AO first" (the launcher, or a dev entrypoint). Do NOT require the
   full `python -m launcher` (admin/VM) for v1.
3. **Clarifying question (Inc 4):** when the PLAN reply is a clarifying question (surface ambiguous),
   the harness answers from a per-goal `clarify_answer` (the option label or number), defaulting to a
   configurable default (e.g. "on this computer" → desktop-gui). Log what it answered.
4. **Monitoring = SMART, with stop-doomed-fast (NON-NEGOTIABLE — this is the dev-cycle-speed lesson).**
   Do NOT just poll `SUMMARY.txt`. Poll the **fleet orchestrator log** for step progression, and
   detect a DETERMINED-doomed run and STOP IT FAST: a hang = the OVMS out-log mtime is stale (no
   generation) AND the relevant `dotnet`/coder child process shows \~0 CPU over a few seconds AND the
   agent log content isn't advancing. On "determined", stop the run (the clean `/dispatch stop` path
   if exposed; else surface it) rather than waiting out the 30-min breaker. Detect completion from
   `SUMMARY.txt` (MERGED/PARKED/...). Beware false-positives from grepping the agent log (it echoes
   seed docs containing words like "parked"/"CS0246") — read the FLEET log + process CPU, not agent-
   log token greps. A configurable overall timeout caps every run.
5. **Sweep loop:** the harness takes a LIST of jobs `{repo, goal, clarify_answer?, expected?}` (a
   small config / JSON) and runs each, accumulating a structured report (per job: plan ok?, asked?,
   answered, run_id, outcome, wall-clock, the stop reason if stopped). Support a single-job CLI too.
6. **Location:** `tools/dispatch_harness/` (a dev/ops tool — it drives a live stack + a real model;
   it is NOT a pytest unit test). A clear CLI entry (`python -m tools.dispatch_harness ...`).

## Verification bar (off-live, what the LA re-runs)

- **Unit tests** (no model, no live AO) for the harness's pure pieces: the job-config parsing, the
  clarifying-answer mapping (a question + answer → the chosen option), the doom-detection predicate
  (given fake mtimes/CPU/log-state → stop or continue), the report assembly, and the
  outcome-classification from a fake `SUMMARY.txt`. Reuse the `test_dispatch_coordinator.py` fakes
  for the flow. Put them under `tests/integration/test_dispatch_harness.py`.
- A **dry-run mode** (`--dry-run`) that exercises the full flow against a FAKE in-process AO
  (injected `plan_fn`/`execute_fn` + a fake fleet-run dir) and prints the report — provable without
  the GPU.
- The **full BlarAI standing gate stays green** (LOCALAPPDATA-redirected to a temp dir, the py3.11
  `.venv`): `pytest shared/ services/ launcher/ tests/integration/ tests/security/ -m "not hardware and not winui and not slow"` — report the pass count + delta.
- **NOT your job (the LA does it):** the live end-to-end run against the real stack + the 30B (that
  is the LA's gate, and it doubles as the rocket-calc fix confirmation). Surface clearly what the LA
  must do to run it live (start the AO, then `python -m tools.dispatch_harness ...`).

## Constraints

`blarai` ONLY; the harness is strictly a DRIVER — **no change to any BlarAI runtime module**
(gateway/AO/coordinator/IPC) beyond, at most, exposing an already-intended seam if one is genuinely
missing (flag it, don't silently refactor); dev_mode TCP loopback, no mTLS; do NOT flip any
`enabled` flag or go-live anything; Python strict type hints + PEP 8; separate commits per part;
append a `BUILD_JOURNAL` FRAGMENT `docs/journal_fragments/2026-06-24_dispatch-harness.md`. Report:
the diff, the gate pass count, the unit/dry-run evidence, the exact live-run command for the LA, the
worktree + branch. The LA independently gates (re-runs + a live dispatch) before merge.
