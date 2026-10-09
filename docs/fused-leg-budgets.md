# Fused coder leg: wait budgets, for registration on the BlarAI side

Single source in this repository: `Get-FusedLegBudgets -TimeoutSec <T>` in `scripts/fleet-lib.ps1`.
`Invoke-FusedCoderRun` takes every wait from it. `scripts/verify-coder-fused-seam.ps1` asserts the values
and the nesting below (section "the SHIPPED wait budgets"). Nothing here is registered in BlarAI yet: the
registry is `C:/Users/mrbla/BlarAI/shared/timeout_registry.py`, which this change does not edit.

`T` is the per-run timeout the caller passes (`$MaxRunMinutes * 60` through `Invoke-CoderDriver`; 1800 s is the
function default and the reference value used for the numbers below).

## Entries to register (names, values at T = 1800, role, nesting)

| Name | Formula | Value at T=1800 | Role | Must exceed |
|---|---|---|---|---|
| Fused leg: task start proof | constant | 20 s (`StartWaitSec`) | probe | none (bounds ONE start check, then fails loudly with the 0x41303 diagnosis) |
| Fused leg: result wait | `T + 300 + 60` | 2160 s (`ResultWaitSec`) | watchdog | `T`; and the ACP client's own outer ceiling `T + 300` that `Invoke-AcpCoderRun` enforces (`WaitForExit($TimeoutSec + 300)`) |
| Fused leg: stop confirmation | constant | 30 s (`StopWaitSec`) | probe | none |
| Fused leg: turn wait (serialize) | `2 x (StartWaitSec + ResultWaitSec + StopWaitSec)` | 4420 s (`QueueWaitSec`) | budget | one full candidate: `StartWaitSec + ResultWaitSec + StopWaitSec` (2210 s) |
| Fused leg: cancel poll slice | constant | 5 s (`CancelSliceSec`) | cadence | n/a (a poll interval; bounds the latency of a `/dispatch stop` while waiting) |
| Fused leg: task poll cadence | constant | 750 ms (`PollMs`) | cadence | n/a |

Reasons for the numbers:

- **Result wait = T + 360.** The coder runs under Task Scheduler, outside the run-fleet process tree. The leg's
  own ACP client bounds itself at `T` and its outer ceiling at `T + 300`; the orchestrator must outlast that
  ceiling plus task startup (60 s), or it gives up on a coder that is still inside its own budget and then
  stops it. The wait is sliced (`CancelSliceSec`) so `/dispatch stop` is honoured within one slice.
- **Turn wait = two candidates ahead.** The task is single-instance (`MultipleInstances IgnoreNew`), so
  best-of-N candidates take turns behind one named mutex. A candidate waits at most two full earlier turns;
  past that it throws (never drops or double-runs). With best-of-3 the third candidate is the worst case.
  Cancellation is polled in `CancelSliceSec` slices during the wait, so the wait never has to be sat out.
- **Worst case for one candidate** is `QueueWaitSec + StartWaitSec + ResultWaitSec + StopWaitSec`
  (4420 + 20 + 2160 + 30 = 6630 s at T=1800). This is NOT checked against the per-card or battery budget
  today: that nesting (`swap_run_budget_s`, `HarnessConfig`, the battery ExecutionTimeLimit) is the BlarAI
  side's to assert once these are registered.

## How to register (the registry resolves Python constants only)

`TimeoutEntry` locates the live value by `module` + `attribute` and the gate compares it. These numbers live in
PowerShell, so a direct entry cannot resolve them. Two options for the lead:

1. **Recommended: mirror the formulas in a BlarAI constants module** (for example
   `shared/fleet/fused_leg_budgets.py` with `START_WAIT_S = 20`, `STOP_WAIT_S = 30`,
   `result_wait_s(t) = t + 360`, `queue_wait_s(t) = 2 * (START_WAIT_S + result_wait_s(t) + STOP_WAIT_S)`),
   register those, declare `must_exceed` as in the table, and add a parity test that runs
   `pwsh -NoProfile -Command ". scripts/fleet-lib.ps1; Get-FusedLegBudgets -TimeoutSec <T> | ConvertTo-Json"`
   for a few `T` and compares. Extend `tests/security/test_watchdog_windows_nest.py` with: result wait >
   `T + 300`; queue wait >= start + result + stop.
2. Add the rows to the registry's backlog list (the "honest to-do" near the end of the file) until option 1 lands.

If the formulas in `Get-FusedLegBudgets` change, this file and the suite section change in the same commit.

## Waits added by the tool-chain setup probe (#775 plan step 4)

These live in `scripts/coder-containment-probe.ps1` and run inside the verify probe job, so they nest under the verify
script's result wait (`-TimeoutSec 180`, `Wait-CoderLegResult`). They are probe-side waits, not dispatch budgets.

| Name | Value | Role | Must stay under |
|---|---|---|---|
| Probe: model proxy GET | 10 s (`Invoke-WebRequest -TimeoutSec`, same as the `:8000` loopback check) | probe | the verify result wait |
| Probe: toolchain `--version` per executable | 15 s (`-ToolchainTimeoutSec`, hard kill of the process tree) x 5 executables | probe | 180 s together with the other checks (worst case about 75 s for the five) |
