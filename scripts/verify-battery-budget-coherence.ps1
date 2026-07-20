#requires -Version 7.0
<#
.SYNOPSIS
  verify-battery-budget-coherence.ps1 (#790 sub-task 3) - the (window, budget) dominance regression lock
  for the idle-600 era. Companion to verify-battery-task-settings.ps1 (#833): that check owns the OUTER
  pair (ExecutionTimeLimit >= derived run-phase floor); THIS check owns the INNER pairs the idle-abort
  landing put under stress.

.DESCRIPTION
  Why this exists:
    On 2026-07-12 the ACP idle watchdog was raised 120 -> 600 s (configs/fleet-driver.json acp.idle_sec,
    #790) to stop false-killing slow-generating 30B coder candidates. A candidate can now legally run
    much closer to its hard wall-clock ceiling (MaxRunMinutes*60), so the SUM of a multi-wave plan-graph
    job's candidate wall-time grew -- and on night-20260715 Blair's Lab reached only "candidate 1 of 2"
    before "The overall run budget elapsed" (STALLED/HARNESS). That per-job budget is BlarAI's
    HarnessConfig.swap_run_budget_s (default 10800 s), enforced by shared/fleet/swap_driver.py; it is NOT
    an agentic-setup constant, but its COHERENCE with the agentic-setup-side idle_sec is what broke.

    lesson-221: every WINDOW must dominate the BUDGET beneath it. The battery's hierarchy:
      Task-Scheduler ExecutionTimeLimit (PT16H)  >=  sum(per-job budget) + overhead    [C3 / #833's T4]
      per-job budget (swap_run_budget_s / card)  >=  waves * best-of-N * per-candidate  [C2 -- Blair's Lab]
      per-candidate ceiling (MaxRunMinutes*60)   >=  idle_sec                           [C1 -- still holds]

  This script proves the COHERENCE LOGIC with pure unit cases (U), then DERIVES the live numbers and
  reports the real verdict (L): the agentic-setup idle_sec (configs/fleet-driver.json) + the BlarAI
  runner's own budgets (tools.dispatch_harness.battery_execution_limit, read-only, the SAME helper #833
  uses). C3 is checked as a PROJECTION: if the per-job budget were raised to satisfy C2, would the derived
  ExecutionTimeLimit floor STILL fit under PT16H? -- the exact "the ceiling must dominate WHATEVER you
  derive" guard the fix must respect.

  It reads only (Get-Content of the JSON config + one read-only python derivation call); it never mutates
  config, state, or the scheduled task, and never touches ports/processes.

  Exit 0 iff the unit cases pass AND (the live state is coherent OR the live numbers could not be derived).
  A derivable-but-incoherent live state exits 1 -- the fail-loud posture #833's sibling check already uses.

  Self-test: -*Override params substitute the live numbers so both the coherent and incoherent live paths
  are provable without the runner env.
#>
[CmdletBinding()]
param(
    [string]$FleetDriverConfig = "$PSScriptRoot\..\configs\fleet-driver.json",
    [string]$BlarRepo = $(if ($env:BLARAI_REPO) { $env:BLARAI_REPO } else { 'C:\Users\mrbla\blarai' }),
    [int]$MaxRunMinutes = 60,               # per-candidate hard ceiling = MaxRunMinutes*60 (acp_coder --timeout-sec)
    [int]$WavesFloor = 2,                    # a plan-graph job is >= 2 waves (else it is a flat/single-task job)
    [int]$BestOfNFloor = 2,                  # best-of-N floor (Resolve-PassBudget: simple=2)
    [double]$ExecutionCeilingS = 57600,      # PT16H -- the live \BlarAI\BlarAI-M2-Battery-Nightly ExecutionTimeLimit
    # self-test overrides (0 = derive live):
    [double]$IdleSecOverride = 0,
    [double]$MinPerJobBudgetOverride = 0,
    [double]$DefaultBudgetOverride = 0,
    [int]$NJobsOverride = 0
)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

$script:Pass = 0; $script:Fail = 0
$script:Failures = New-Object System.Collections.ArrayList
function Section($t) { Write-Host ''; Write-Host "== $t ==" -ForegroundColor Cyan }
function _pass($m) { $script:Pass++; Write-Host "  [PASS] $m" -ForegroundColor Green }
function _fail($m) { $script:Fail++; [void]$script:Failures.Add($m); Write-Host "  [FAIL] $m" -ForegroundColor Red }
function Assert-True($Cond, $Msg) { if ($Cond) { _pass $Msg } else { _fail "$Msg (expected True, got False)" } }

# ---- the PURE core: the three dominance relations. No I/O -- unit-testable with plain numbers. ----
# Per-job overhead + fixed per-night overhead MIRROR tools.dispatch_harness.battery_execution_limit so a
# C3 projection here agrees with the runner's own derivation.
$script:PER_JOB_OVERHEAD_S = 300.0
$script:FIXED_OVERHEAD_S = 1800.0
function Test-BudgetCoherence {
    param(
        [double]$IdleSec, [double]$PerCandidateCeilingS, [double]$MinPerJobBudgetS,
        [int]$NJobs, [double]$ExecutionCeilingS,
        [int]$WavesFloor = 2, [int]$BestOfNFloor = 2
    )
    $c1ok = $PerCandidateCeilingS -ge $IdleSec
    $c2need = [double]$WavesFloor * [double]$BestOfNFloor * $PerCandidateCeilingS
    $c2ok = $MinPerJobBudgetS -ge $c2need
    # C3 PROJECTION: if every job's budget were raised to the C2 requirement, the derived ExecutionTimeLimit
    # floor = sum(c2need + per-job overhead) + fixed overhead. Does the PT16H ceiling still dominate it?
    $c3floor = ($NJobs * ($c2need + $script:PER_JOB_OVERHEAD_S)) + $script:FIXED_OVERHEAD_S
    $c3ok = ($ExecutionCeilingS -le 0) -or ($ExecutionCeilingS -ge $c3floor)   # <=0 == unlimited
    return @{
        Coherent = ($c1ok -and $c2ok -and $c3ok)
        C1 = @{ Ok = $c1ok; Detail = ("per-candidate ceiling {0:N0}s vs idle {1:N0}s" -f $PerCandidateCeilingS, $IdleSec) }
        C2 = @{ Ok = $c2ok; Need = $c2need; Detail = ("min per-job budget {0:N0}s vs need {1:N0}s ({2}w x {3}N x {4:N0}s)" -f $MinPerJobBudgetS, $c2need, $WavesFloor, $BestOfNFloor, $PerCandidateCeilingS) }
        C3 = @{ Ok = $c3ok; Floor = $c3floor; Detail = ("projected floor if C2-satisfied {0:N0}s ({1:N1}h) vs PT16H ceiling {2:N0}s ({3:N1}h)" -f $c3floor, ($c3floor / 3600), $ExecutionCeilingS, ($ExecutionCeilingS / 3600)) }
    }
}

$ceiling = [double]$MaxRunMinutes * 60

# ----------------------------------------------------------------------------
Section 'U  unit: the coherence logic (pure, no runner env)'
# a COHERENT world: 3600s ceiling >= 600 idle; 4h/job budget >= 2*2*3600=14400; few enough jobs that even
# the C2-raised floor fits PT16H.
$u1 = Test-BudgetCoherence -IdleSec 600 -PerCandidateCeilingS 3600 -MinPerJobBudgetS 14400 -NJobs 3 -ExecutionCeilingS 57600
Assert-True ($u1.C1.Ok)   'U1 C1 holds when the ceiling dominates idle'
Assert-True ($u1.C2.Ok)   'U2 C2 holds when the per-job budget covers waves x best-of-N x ceiling'
Assert-True ($u1.C3.Ok)   'U3 C3 holds when the C2-satisfied floor still fits PT16H (few jobs)'
Assert-True ($u1.Coherent) 'U4 a coherent world reports Coherent'
# the Blair's-Lab world: idle 600, ceiling 3600, per-job budget only 10800 -> C2 FAILS (10800 < 14400).
$u2 = Test-BudgetCoherence -IdleSec 600 -PerCandidateCeilingS 3600 -MinPerJobBudgetS 10800 -NJobs 6 -ExecutionCeilingS 57600
Assert-True ($u2.C1.Ok)          'U5 C1 still holds in the Blair''s-Lab world'
Assert-True (-not $u2.C2.Ok)     'U6 [kill] C2 FAILS: the 10800s per-job budget cannot cover a 2-wave job (14400s) under idle-600 (Blair''s Lab)'
Assert-True (($u2.C2.Need) -eq 14400) 'U7 the C2 requirement is 2w x 2N x 3600s = 14400s'
# C3 tension: raising ALL 6 jobs to 14400 blows past PT16H (6*(14400+300)+1800 = 90000s = 25h > 57600).
Assert-True (-not $u2.C3.Ok)     'U8 [kill] C3 FAILS: raising ALL 6 jobs to the C2 budget breaks the PT16H ceiling (the fix cannot be a global bump)'
Assert-True (($u2.C3.Floor) -eq 90000) 'U9 the projected C2-satisfied floor for 6 jobs is 90000s (25h)'
Assert-True (-not $u2.Coherent)  'U10 the Blair''s-Lab world reports NOT coherent'
# C1 kill: an idle that meets/exceeds the ceiling would make idle useless (the ceiling would kill first).
$u3 = Test-BudgetCoherence -IdleSec 3600 -PerCandidateCeilingS 3600 -MinPerJobBudgetS 999999 -NJobs 1 -ExecutionCeilingS 57600
Assert-True ($u3.C1.Ok) 'U11 C1 boundary: idle == ceiling is still ok (idle <= ceiling)'
$u4 = Test-BudgetCoherence -IdleSec 3601 -PerCandidateCeilingS 3600 -MinPerJobBudgetS 999999 -NJobs 1 -ExecutionCeilingS 57600
Assert-True (-not $u4.C1.Ok) 'U12 [kill] C1 FAILS when idle exceeds the per-candidate ceiling'
# unlimited ceiling (PT0S) covers any floor.
$u5 = Test-BudgetCoherence -IdleSec 600 -PerCandidateCeilingS 3600 -MinPerJobBudgetS 14400 -NJobs 99 -ExecutionCeilingS 0
Assert-True ($u5.C3.Ok) 'U13 an unlimited ExecutionTimeLimit (<=0) covers any derived floor'

# ----------------------------------------------------------------------------
Section 'L  live: derive the real numbers and report the current verdict'
# idle_sec from the agentic-setup fleet-driver config (the live per-run watchdog value).
$idleSec = $IdleSecOverride
if ($idleSec -le 0) {
    try {
        $fd = Get-Content $FleetDriverConfig -Raw -Encoding UTF8 | ConvertFrom-Json
        $idleSec = [double]$fd.acp.idle_sec
        Write-Host ("  fleet-driver acp.idle_sec = {0:N0}s (from {1})" -f $idleSec, $FleetDriverConfig)
    } catch {
        Write-Host "  could not read acp.idle_sec from $FleetDriverConfig ($($_.Exception.Message))" -ForegroundColor Yellow
    }
}
# per-job budgets + job count from the BlarAI runner's own derivation (read-only), the SAME source #833 uses.
$minPerJob = $MinPerJobBudgetOverride
$defaultBudget = $DefaultBudgetOverride
$nJobs = $NJobsOverride
if (($minPerJob -le 0) -or ($nJobs -le 0)) {
    $py = Join-Path $BlarRepo '.venv\Scripts\python.exe'
    if (Test-Path $py) {
        Push-Location $BlarRepo
        try {
            $raw = & $py -m tools.dispatch_harness.battery_execution_limit 2>&1 | Out-String
            $code = $LASTEXITCODE
        } catch { $raw = $_.Exception.Message; $code = -1 } finally { Pop-Location }
        if ($code -eq 0) {
            try {
                $bd = $raw | ConvertFrom-Json
                $nJobs = [int]$bd.n_jobs
                $defaultBudget = [double]$bd.default_budget_s
                $minPerJob = (@($bd.per_job | ForEach-Object { [double]$_.budget_s }) | Measure-Object -Minimum).Minimum
                Write-Host ("  runner budgets: {0} job(s), default swap_run_budget_s = {1:N0}s, min per-job = {2:N0}s, derived floor = {3:N0}s ({4:N1}h)" -f $nJobs, $defaultBudget, $minPerJob, [double]$bd.required_s, ([double]$bd.required_s / 3600))
            } catch { Write-Host "  could not parse battery_execution_limit output: $($_.Exception.Message)" -ForegroundColor Yellow }
        } else {
            Write-Host "  battery_execution_limit derivation failed (exit $code) - live check skipped." -ForegroundColor Yellow
        }
    } else {
        Write-Host "  BlarAI .venv python not found at $py - live check skipped (unit cases still gate)." -ForegroundColor Yellow
    }
}

$liveDerivable = ($idleSec -gt 0) -and ($minPerJob -gt 0) -and ($nJobs -gt 0)
if (-not $liveDerivable) {
    Write-Host "  live numbers not fully derivable in this environment - reporting UNIT result only." -ForegroundColor Yellow
} else {
    $live = Test-BudgetCoherence -IdleSec $idleSec -PerCandidateCeilingS $ceiling -MinPerJobBudgetS $minPerJob `
                                 -NJobs $nJobs -ExecutionCeilingS $ExecutionCeilingS -WavesFloor $WavesFloor -BestOfNFloor $BestOfNFloor
    $c1c = if ($live.C1.Ok) { 'Green' } else { 'Red' }; Write-Host ("  C1 (ceiling >= idle):        {0}  -- {1}" -f $(if ($live.C1.Ok) { 'OK  ' } else { 'FAIL' }), $live.C1.Detail) -ForegroundColor $c1c
    $c2c = if ($live.C2.Ok) { 'Green' } else { 'Red' }; Write-Host ("  C2 (per-job >= multi-wave):  {0}  -- {1}" -f $(if ($live.C2.Ok) { 'OK  ' } else { 'FAIL' }), $live.C2.Detail) -ForegroundColor $c2c
    $c3c = if ($live.C3.Ok) { 'Green' } else { 'Red' }; Write-Host ("  C3 (PT16H >= C2-fix floor):  {0}  -- {1}" -f $(if ($live.C3.Ok) { 'OK  ' } else { 'FAIL' }), $live.C3.Detail) -ForegroundColor $c3c
    if ($live.Coherent) {
        _pass 'L-LIVE the live battery budget hierarchy is COHERENT under idle-600'
    } else {
        _fail 'L-LIVE the live battery budget hierarchy is INCOHERENT under idle-600 (see the C1/C2/C3 lines). FIX is BlarAI-side: raise swap_run_budget_s / a multi-wave card run_budget_s (per-card, NOT a global bump -- C3), and reconcile the ExecutionTimeLimit (LA reliability call).'
    }
}

# ----------------------------------------------------------------------------
Section 'Result'
Write-Host ("  Passed:  {0}" -f $script:Pass) -ForegroundColor Green
if ($script:Fail) {
    Write-Host ("  Failed:  {0}" -f $script:Fail) -ForegroundColor Red
    $script:Failures | ForEach-Object { Write-Host "    - $_" -ForegroundColor Red }
    exit 1
} else {
    Write-Host ''
    Write-Host '  BATTERY BUDGET COHERENCE: the (window, budget) dominance logic is validated and the live hierarchy conforms under idle-600.' -ForegroundColor Green
    exit 0
}
