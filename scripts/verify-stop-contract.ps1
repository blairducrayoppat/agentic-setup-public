#requires -Version 5.1
<#
.SYNOPSIS
  Verify the #771 STOP-CONTRACT: the best-of-N candidate loop honours a `/dispatch stop`
  BETWEEN candidates / batches, and the cancel consumer is a read-only Test-Path.

.DESCRIPTION
  Background (plain English):
    The dispatch monitor's `/dispatch stop` writes a cancel sentinel (state/fleet-swap/cancel).
    The Python swap DRIVER honoured it at each task boundary, but the PowerShell best-of-N loop
    inside a task did NOT -- so after a stop landed, candidate N's gate timed out and the loop went
    on to BUILD candidate N+1 (a fresh ~hour of GPU, OVMS holding the card) until the run-budget
    watchdog tore down an hour later (#771, run 2026-07-08). The fix: a read-only cancel consumer
    (Test-DispatchCancelled) checked BETWEEN candidates (Invoke-BestOfN), BETWEEN concurrent batches
    (Invoke-BestOfNBatched), and BETWEEN a candidate's gate steps (Invoke-CandidateBuild) so no FRESH
    work starts after a stop; the run then returns promptly and the driver tears down at the next
    boundary (limb 2).

  This script proves the OFFLINE-verifiable pieces (no model / no OVMS / no dispatch; ~1 second):
    1. Test-DispatchCancelled  -- true iff the sentinel exists; NEVER creates/deletes it (the writer +
       stale-clearers own that -- #758: the alive loop acts on its own stop, never presumes death).
    2. Invoke-BestOfN          -- ShouldCancel checked before each candidate; a stop stops fresh
       candidates, sets Cancelled, and the default { $false } preserves today's behaviour byte-for-byte.
    3. Invoke-BestOfNBatched   -- ShouldCancel checked before each batch; same posture, batch-grained.

  Invoke-CandidateBuild's between-gate-step cancel-skip runs the REAL pipeline (git + opencode) and is
  covered by the coordinator's watched live-verify, not here (this suite stays model-free, like
  verify-bestofn.ps1's unit layer). Mutation-resistant: asserts call COUNTS + the Cancelled/Count/
  SelectedIndex shape, not just a boolean.

  Exit 0 if everything that CAN be validated offline passed, 1 on any failure.
  Run it normally ( .\verify-stop-contract.ps1 ) - do NOT dot-source it.
#>
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\fleet-lib.ps1"

# Tiny zero-dependency test framework (mirrors verify-bestofn.ps1 so the suites read identically).
$script:Pass = 0
$script:Fail = 0
$script:Failures = New-Object System.Collections.ArrayList
function Section($t) { Write-Host ''; Write-Host "== $t ==" -ForegroundColor Cyan }
function _pass($m)   { $script:Pass++; Write-Host "  [PASS] $m" -ForegroundColor Green }
function _fail($m)   { $script:Fail++; [void]$script:Failures.Add($m); Write-Host "  [FAIL] $m" -ForegroundColor Red }
function Assert-Eq($Expected, $Actual, $Msg) {
    if ([string]$Expected -ceq [string]$Actual) { _pass $Msg } else { _fail "$Msg (expected '$Expected', got '$Actual')" }
}
function Assert-True($Cond, $Msg)  { if ($Cond) { _pass $Msg } else { _fail "$Msg (expected True, got False)" } }
function Assert-False($Cond, $Msg) { if (-not $Cond) { _pass $Msg } else { _fail "$Msg (expected False, got True)" } }

# ----------------------------------------------------------------------------
# Scripted fakes: a plan-driven candidate runner (records call order) + a cancel
# predicate that flips TRUE after a configured number of checks.
# ----------------------------------------------------------------------------
$script:Plan     = @()
$script:runCalls = New-Object System.Collections.ArrayList
$script:cancelChecks = 0
$script:cancelThreshold = [int]::MaxValue   # ShouldCancel returns TRUE once cancelChecks exceeds this

$RunFromPlan = {
    param($Index, $Total)
    [void]$script:runCalls.Add($Index)
    $p = $script:Plan[$Index - 1]
    @{ Index = $Index; VerifyResult = $p.Verify; TestResult = $p.Test; HasChanges = [bool]$p.Changes;
       TimedOut = [bool]$p.TimedOut; SecretBlocked = [bool]$p.Secret; LoopSuspected = $false;
       Run = @{ TimeoutReason = '' }; Tag = "c$Index" }
}
# Concurrent analogue: run a whole batch, one plan entry per index.
$RunBatchFromPlan = {
    param($Indices, $Total)
    $out = @()
    foreach ($k in $Indices) {
        [void]$script:runCalls.Add($k)
        $p = $script:Plan[$k - 1]
        $out += @{ Index = $k; VerifyResult = $p.Verify; TestResult = $p.Test; HasChanges = [bool]$p.Changes;
                   TimedOut = [bool]$p.TimedOut; SecretBlocked = [bool]$p.Secret; LoopSuspected = $false;
                   Run = @{ TimeoutReason = '' }; Tag = "c$k" }
    }
    return $out
}
$IsWinner = { param($r) Test-IsCandidateGreen -VerifyResult $r.VerifyResult -TestResult $r.TestResult -HasChanges $r.HasChanges -TimedOut $r.TimedOut -SecretBlocked $r.SecretBlocked }
$Score    = { param($r) Get-CandidateRank -VerifyResult $r.VerifyResult -TestResult $r.TestResult -HasChanges $r.HasChanges -TimedOut $r.TimedOut -SecretBlocked $r.SecretBlocked -LoopSuspected $r.LoopSuspected }
# ShouldCancel: returns TRUE on the check AFTER $script:cancelThreshold checks have happened.
# (Distinct name from the int threshold -- PowerShell variable names are case-INSENSITIVE, so
# $CancelPredicate must not collide with $cancelThreshold.)
$CancelPredicate = { $script:cancelChecks++; return ($script:cancelChecks -gt $script:cancelThreshold) }
function Reset-Fakes([int]$After) {
    $script:runCalls = New-Object System.Collections.ArrayList
    $script:cancelChecks = 0
    $script:cancelThreshold = $After
}

# ============================================================================
Section 'Test-DispatchCancelled - read-only consumer of the cancel sentinel'
# ============================================================================
# Build a fake agentic root: <tmp>/scripts (the ScriptRoot) with a sibling state/fleet-swap.
$tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("stopcontract-" + [System.IO.Path]::GetRandomFileName().Replace('.', ''))
$fakeScripts = Join-Path $tmpRoot 'scripts'
$swapDir = Join-Path $tmpRoot 'state\fleet-swap'
New-Item -ItemType Directory -Force $fakeScripts | Out-Null
New-Item -ItemType Directory -Force $swapDir | Out-Null
$cancelFile = Join-Path $swapDir 'cancel'
try {
    Assert-False (Test-DispatchCancelled -ScriptRoot $fakeScripts) 'no sentinel => not cancelled'
    Assert-False (Test-Path $cancelFile) 'the read-only probe did NOT create the sentinel (writer/ownership preserved)'
    Set-Content -Path $cancelFile -Value '' -NoNewline
    Assert-True  (Test-DispatchCancelled -ScriptRoot $fakeScripts) 'sentinel present => cancelled'
    Assert-True  (Test-Path $cancelFile) 'the probe did NOT delete the sentinel (never clears -- the launcher/driver own that)'
    Remove-Item $cancelFile -Force
    Assert-False (Test-DispatchCancelled -ScriptRoot $fakeScripts) 'sentinel removed => not cancelled again (pure read)'
} finally {
    Remove-Item $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
}

# ============================================================================
Section 'Invoke-BestOfN - default ShouldCancel { $false } is byte-compatible (no regression)'
# ============================================================================
# All candidates fail so all N run; with NO -ShouldCancel the loop must behave exactly as before.
$script:Plan = @( @{ Verify='fail'; Test='fail'; Changes=$true }, @{ Verify='fail'; Test='fail'; Changes=$true }, @{ Verify='fail'; Test='fail'; Changes=$true } )
Reset-Fakes ([int]::MaxValue)
$r = Invoke-BestOfN -MaxCandidates 3 -RunCandidate $RunFromPlan -IsWinner $IsWinner -ScoreCandidate $Score
Assert-Eq 3 $script:runCalls.Count 'all 3 candidates ran (default cancel predicate never fires)'
Assert-False $r.Cancelled          'Cancelled=$false on the default path'
Assert-False $r.WinnerFound        'no winner (all failed)'

# ============================================================================
Section 'Invoke-BestOfN - a stop BETWEEN candidates stops fresh candidates (#771)'
# ============================================================================
# cancelAfter=1: the check before c1 is #1 (<=1 -> false, c1 runs); the check before c2 is #2 (>1 -> TRUE -> break).
$script:Plan = @( @{ Verify='fail'; Test='fail'; Changes=$true }, @{ Verify='fail'; Test='fail'; Changes=$true }, @{ Verify='fail'; Test='fail'; Changes=$true } )
Reset-Fakes 1
$r = Invoke-BestOfN -MaxCandidates 3 -RunCandidate $RunFromPlan -IsWinner $IsWinner -ScoreCandidate $Score -ShouldCancel $CancelPredicate
Assert-Eq 1 $script:runCalls.Count 'candidate 2 was NOT started after the stop (the exact #771 defect)'
Assert-True  $r.Cancelled          'Cancelled=$true is surfaced to the caller'
Assert-False $r.WinnerFound        'a cancelled run has no winner'
Assert-Eq 1 $r.Count               'Count reflects only the candidate that ran before the stop'
Assert-Eq 0 $r.SelectedIndex       'the one parked candidate is the best-partial (index 0)'

# ============================================================================
Section 'Invoke-BestOfN - a stop BEFORE candidate 1 starts nothing'
# ============================================================================
$script:Plan = @( @{ Verify='pass'; Test='pass'; Changes=$true } )
Reset-Fakes 0   # check #1 (>0) -> TRUE immediately
$r = Invoke-BestOfN -MaxCandidates 3 -RunCandidate $RunFromPlan -IsWinner $IsWinner -ScoreCandidate $Score -ShouldCancel $CancelPredicate
Assert-Eq 0 $script:runCalls.Count 'no candidate ran (stop observed before candidate 1)'
Assert-True  $r.Cancelled          'Cancelled=$true'
Assert-Eq 0 $r.Count               'nothing generated'
Assert-Eq -1 $r.SelectedIndex      'no selection'
Assert-True ($null -eq $r.Selected) 'Selected is null'

# ============================================================================
Section 'Invoke-BestOfN - a green winner found BEFORE any stop is not cancelled'
# ============================================================================
# c1 is green -> the loop breaks on the winner before the pre-c2 cancel check is ever reached.
$script:Plan = @( @{ Verify='pass'; Test='pass'; Changes=$true }, @{ Verify='fail'; Test='fail'; Changes=$true } )
Reset-Fakes 1
$r = Invoke-BestOfN -MaxCandidates 3 -RunCandidate $RunFromPlan -IsWinner $IsWinner -ScoreCandidate $Score -ShouldCancel $CancelPredicate
Assert-True  $r.WinnerFound  'candidate 1 won on the gate'
Assert-False $r.Cancelled    'a completed green winner is NOT a cancellation (no partial-park, safe to merge)'
Assert-Eq 1 $script:runCalls.Count 'stopped at the first green (one candidate)'

# ============================================================================
Section 'Invoke-BestOfNBatched - default ShouldCancel is byte-compatible'
# ============================================================================
$script:Plan = @( @{ Verify='fail'; Test='fail'; Changes=$true }, @{ Verify='fail'; Test='fail'; Changes=$true }, @{ Verify='fail'; Test='fail'; Changes=$true }, @{ Verify='fail'; Test='fail'; Changes=$true } )
Reset-Fakes ([int]::MaxValue)
$r = Invoke-BestOfNBatched -MaxCandidates 4 -Concurrency 2 -RunBatch $RunBatchFromPlan -IsWinner $IsWinner -ScoreCandidate $Score
Assert-Eq 4 $script:runCalls.Count 'all 4 candidates ran across 2 batches (default cancel never fires)'
Assert-False $r.Cancelled          'Cancelled=$false on the default path'

# ============================================================================
Section 'Invoke-BestOfNBatched - a stop BETWEEN batches stops the next batch (#771)'
# ============================================================================
# cancelAfter=1: pre-batch1 check #1 (false -> batch 1 of 2 runs); pre-batch2 check #2 (TRUE -> break).
$script:Plan = @( @{ Verify='fail'; Test='fail'; Changes=$true }, @{ Verify='fail'; Test='fail'; Changes=$true }, @{ Verify='fail'; Test='fail'; Changes=$true }, @{ Verify='fail'; Test='fail'; Changes=$true } )
Reset-Fakes 1
$r = Invoke-BestOfNBatched -MaxCandidates 4 -Concurrency 2 -RunBatch $RunBatchFromPlan -IsWinner $IsWinner -ScoreCandidate $Score -ShouldCancel $CancelPredicate
Assert-Eq 2 $script:runCalls.Count 'only the first batch (2 candidates) ran; the second batch was NOT launched after the stop'
Assert-True  $r.Cancelled          'Cancelled=$true surfaced'
Assert-Eq 2 $r.Count               'Count reflects only the launched batch'

# ============================================================================
Section 'Invoke-BestOfNBatched - a stop BEFORE the first batch launches nothing'
# ============================================================================
$script:Plan = @( @{ Verify='pass'; Test='pass'; Changes=$true }, @{ Verify='pass'; Test='pass'; Changes=$true } )
Reset-Fakes 0
$r = Invoke-BestOfNBatched -MaxCandidates 2 -Concurrency 2 -RunBatch $RunBatchFromPlan -IsWinner $IsWinner -ScoreCandidate $Score -ShouldCancel $CancelPredicate
Assert-Eq 0 $script:runCalls.Count 'no batch launched (stop observed before batch 1)'
Assert-True  $r.Cancelled          'Cancelled=$true'
Assert-Eq 0 $r.Count               'nothing generated'

# ----------------------------------------------------------------------------
Write-Host ''
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host ("RESULT: {0} passed, {1} failed" -f $script:Pass, $script:Fail) -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
if ($script:Fail) {
    Write-Host 'FAILURES:' -ForegroundColor Red
    $script:Failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
}
Write-Host '============================================================' -ForegroundColor Cyan
exit $(if ($script:Fail) { 1 } else { 0 })
