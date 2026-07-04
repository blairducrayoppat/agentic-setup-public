#requires -Version 5.1
<#
.SYNOPSIS
  Verify and validate the fleet's PROGRESS-AWARE coder-run timeout (#682).

.DESCRIPTION
  Background (plain English):
    The per-coder-run circuit breaker used to be a single absolute wall-clock: it
    killed a coder at a fixed deadline whether it was busy or stuck. That did two
    wrong things at once -- it guillotined a PRODUCTIVE-but-slow coder mid-work
    ("we're killing it too soon"), and it let a genuinely HUNG coder bleed the whole
    budget before dying. The fix splits the stop into two:
      - IDLE   : no new step_finish AND no new edit for IdleTimeoutSec -> the coder is
                 genuinely stuck (wedged / frozen / server dead) -> kill FAST.
      - CEILING: a generous absolute backstop so even a trickle-progress run cannot
                 run forever. A still-progressing coder runs until this ceiling rather
                 than a short fixed deadline.
    Every step or edit resets the idle clock, so a working coder is never idle-killed.
    The decision is the PURE function Resolve-RunStopDecision (fleet-lib.ps1), wired
    into Invoke-AgentRun's monitor loop.

  This script proves that behaviour deterministically:

    UNIT TESTS  (always run; no model / no OVMS / no real clock / no process needed)
      Drives the REAL Resolve-RunStopDecision with fixed datetimes and scripted
      progress counters and checks every branch EXACTLY. The suite is
      mutation-resistant: each assertion is chosen to go RED if the corresponding
      line of the policy is mutated (off-by-one on the idle/ceiling boundary,
      steps-only vs edits-or-steps progress, idle-clock not reset on progress,
      ceiling-vs-idle precedence, the <=0 disable).

  The end-to-end LIVE proof (a real dispatch where a slow-but-working coder is NOT
  killed, and a hung one dies fast) is the capstone dispatch, not this unit suite.

  Exit code is 0 if everything passed, 1 if any check failed. Run it normally
  ( .\verify-runtimeout.ps1 ) -- do NOT dot-source it.
#>
param()
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\fleet-lib.ps1"

# ----------------------------------------------------------------------------
# Tiny zero-dependency test framework (same shape as verify-retry.ps1)
# ----------------------------------------------------------------------------
$script:Pass = 0
$script:Fail = 0
$script:Failures = New-Object System.Collections.ArrayList

function Section($t) { Write-Host ''; Write-Host "== $t ==" -ForegroundColor Cyan }
function _pass($m)   { $script:Pass++; Write-Host "  [PASS] $m" -ForegroundColor Green }
function _fail($m)   { $script:Fail++; [void]$script:Failures.Add($m); Write-Host "  [FAIL] $m" -ForegroundColor Red }

function Assert-Eq($Expected, $Actual, $Msg) {
    if ([string]$Expected -ceq [string]$Actual) { _pass $Msg }
    else { _fail "$Msg (expected '$Expected', got '$Actual')" }
}
function Assert-True($Cond, $Msg) {
    if ($Cond) { _pass $Msg } else { _fail "$Msg (expected True, got False)" }
}
function Assert-False($Cond, $Msg) {
    if (-not $Cond) { _pass $Msg } else { _fail "$Msg (expected False, got True)" }
}

# ----------------------------------------------------------------------------
# Driver: call the REAL Resolve-RunStopDecision with a fixed clock so every branch
# is deterministic. All *Sec args are seconds offset from a fixed base $t0; the
# DeadlineUtc defaults to t0+3600 (a 1-hour ceiling) unless overridden.
# ----------------------------------------------------------------------------
$script:T0 = [datetime]'2026-06-25 12:00:00'
function Decide {
    param(
        [Parameter(Mandatory)][int]$NowSec,
        [Parameter(Mandatory)][int]$LastProgSec,
        [int]$Idle = 240,
        [int]$DeadlineSec = 3600,
        [int]$PrevSteps = 0,
        [int]$Steps = 0,
        [int]$PrevEdits = 0,
        [int]$Edits = 0
    )
    return Resolve-RunStopDecision `
        -NowUtc $script:T0.AddSeconds($NowSec) `
        -LastProgressUtc $script:T0.AddSeconds($LastProgSec) `
        -DeadlineUtc $script:T0.AddSeconds($DeadlineSec) `
        -PrevSteps $PrevSteps -Steps $Steps -PrevEdits $PrevEdits -Edits $Edits `
        -IdleTimeoutSec $Idle
}
function ProgUtcEq($Result, [int]$ExpectedSec, $Msg) {
    $delta = ($Result.LastProgressUtc - $script:T0.AddSeconds($ExpectedSec)).TotalSeconds
    Assert-True ([math]::Abs($delta) -lt 0.001) "$Msg (LastProgressUtc off by $delta s)"
}

# ============================================================================
Section 'Shape / smoke'
# ============================================================================
$r = Decide -NowSec 10 -LastProgSec 0
Assert-True ($r -is [hashtable]) 'returns a hashtable'
Assert-True ($r.ContainsKey('Stop') -and $r.ContainsKey('Reason') -and $r.ContainsKey('LastProgressUtc') -and $r.ContainsKey('Progressed')) 'has Stop/Reason/LastProgressUtc/Progressed keys'

# ============================================================================
Section 'Progress detection + idle-clock reset'
# ============================================================================
# P1: NEW steps => progressed, idle clock moves to Now.
$r = Decide -NowSec 100 -LastProgSec 0 -PrevSteps 3 -Steps 5 -PrevEdits 0 -Edits 0
Assert-True  $r.Progressed 'P1 new step_finish counts as progress'
Assert-False $r.Stop       'P1 progressing run is not stopped'
ProgUtcEq $r 100 'P1 idle clock advanced to Now on progress'

# P2: NEW edits only (steps unchanged) => progressed. Kills a steps-only mutant.
$r = Decide -NowSec 100 -LastProgSec 0 -PrevSteps 5 -Steps 5 -PrevEdits 1 -Edits 2
Assert-True  $r.Progressed 'P2 a new edit (no new step) still counts as progress'
Assert-False $r.Stop       'P2 progressing-by-edit run is not stopped'
ProgUtcEq $r 100 'P2 idle clock advanced to Now on an edit'

# P3: NO new steps and NO new edits => not progressed, idle clock UNCHANGED.
$r = Decide -NowSec 100 -LastProgSec 0 -PrevSteps 5 -Steps 5 -PrevEdits 2 -Edits 2
Assert-False $r.Progressed 'P3 no new step/edit is not progress'
Assert-False $r.Stop       'P3 within the idle window, no stop yet'
ProgUtcEq $r 0 'P3 idle clock NOT reset when there was no progress'

# ============================================================================
Section 'Idle stop (genuinely stuck -> kill fast)'
# ============================================================================
# I1: idle for exactly IdleTimeoutSec, no progress => STOP idle (>= boundary fires).
$r = Decide -NowSec 240 -LastProgSec 0 -Idle 240 -Steps 5 -PrevSteps 5
Assert-True $r.Stop        'I1 idle exactly at the threshold stops'
Assert-Eq  'idle' $r.Reason 'I1 reason is idle'

# I2: idle for 239s (one under) => NO stop. Kills a > vs >= off-by-one.
$r = Decide -NowSec 239 -LastProgSec 0 -Idle 240 -Steps 5 -PrevSteps 5
Assert-False $r.Stop       'I2 one second under the idle threshold does NOT stop'
Assert-Eq  '' $r.Reason    'I2 reason empty when not stopped'

# I3: CRITICAL "not killing it too soon" -- old LastProgressUtc is far back, but a
# NEW step arrives THIS poll => progress resets the clock => NOT idle-killed.
$r = Decide -NowSec 300 -LastProgSec 0 -Idle 240 -PrevSteps 4 -Steps 5
Assert-True  $r.Progressed 'I3 a fresh step counts as progress even past the idle window'
Assert-False $r.Stop       'I3 a still-progressing coder is NEVER idle-killed (the core #682 fix)'
ProgUtcEq $r 300 'I3 idle clock reset to Now by the fresh step'

# ============================================================================
Section 'Ceiling stop (absolute backstop)'
# ============================================================================
# C1: Now == Deadline, no progress => STOP ceiling (>= boundary fires).
$r = Decide -NowSec 3600 -LastProgSec 3500 -DeadlineSec 3600 -Steps 5 -PrevSteps 5
Assert-True $r.Stop           'C1 reaching the ceiling stops'
Assert-Eq  'ceiling' $r.Reason 'C1 reason is ceiling'

# C2: just under the ceiling and not idle => NO stop. Kills an early-stop mutant.
$r = Decide -NowSec 3599 -LastProgSec 3500 -DeadlineSec 3600 -Idle 240 -Steps 5 -PrevSteps 5
Assert-False $r.Stop          'C2 one second under the ceiling does NOT stop'

# C3: BOTH idle and ceiling true => ceiling WINS (documented precedence).
$r = Decide -NowSec 3600 -LastProgSec 0 -DeadlineSec 3600 -Idle 240 -Steps 5 -PrevSteps 5
Assert-True $r.Stop           'C3 stops when both idle and ceiling are true'
Assert-Eq  'ceiling' $r.Reason 'C3 ceiling takes precedence over idle when both fire'

# C4: ceiling fires EVEN IF progress happened this poll (an absolute cap).
$r = Decide -NowSec 3600 -LastProgSec 0 -DeadlineSec 3600 -PrevSteps 4 -Steps 5
Assert-True $r.Stop           'C4 a progressing run still cannot exceed the absolute ceiling'
Assert-Eq  'ceiling' $r.Reason 'C4 reason is ceiling even when progressing'

# ============================================================================
Section 'Idle disabled (IdleTimeoutSec <= 0 => ceiling-only, legacy)'
# ============================================================================
# D1: idle disabled (0), idle for a very long time, under ceiling => NO stop.
$r = Decide -NowSec 100000 -LastProgSec 0 -Idle 0 -DeadlineSec 999999 -Steps 5 -PrevSteps 5
Assert-False $r.Stop 'D1 IdleTimeoutSec=0 disables the idle kill'

# D2: idle disabled (negative) => NO stop on idle.
$r = Decide -NowSec 100000 -LastProgSec 0 -Idle -1 -DeadlineSec 999999 -Steps 5 -PrevSteps 5
Assert-False $r.Stop 'D2 a negative IdleTimeoutSec also disables the idle kill'

# D3: idle disabled but the ceiling still applies.
$r = Decide -NowSec 3600 -LastProgSec 0 -Idle 0 -DeadlineSec 3600 -Steps 5 -PrevSteps 5
Assert-True $r.Stop            'D3 disabling idle does NOT disable the ceiling'
Assert-Eq  'ceiling' $r.Reason 'D3 ceiling still fires with idle disabled'

# ============================================================================
# RESULT banner
# ============================================================================
Write-Host ''
Write-Host '========================================' -ForegroundColor Cyan
$total = $script:Pass + $script:Fail
$bannerColor = if ($script:Fail -eq 0) { 'Green' } else { 'Red' }
Write-Host ("  verify-runtimeout: {0}/{1} passed, {2} failed" -f $script:Pass, $total, $script:Fail) -ForegroundColor $bannerColor
if ($script:Fail -gt 0) {
    Write-Host '  Failures:' -ForegroundColor Red
    foreach ($f in $script:Failures) { Write-Host "    - $f" -ForegroundColor Red }
    exit 1
}
exit 0
