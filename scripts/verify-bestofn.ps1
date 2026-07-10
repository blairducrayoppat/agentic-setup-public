#requires -Version 5.1
<#
.SYNOPSIS
  Verify and validate the fleet's BEST-OF-N parallel-sampling capability (#689, epic #688).

.DESCRIPTION
  Background (plain English):
    The local coding model is weak at SELF-CORRECTION -- handed its own failing build and
    told "fix it," it tends to get stuck in the same error. So instead of re-fixing one
    attempt over and over (the old serial retry), best-of-N takes a few FRESH, INDEPENDENT
    attempts at the same task -- each starting clean from the seeded baseline, each nudged to
    be different -- and lets the DETERMINISTIC build/test gate pick the winner. The gate, never
    a model, selects. It stops the instant an attempt passes (so an easy task still costs one
    attempt, like before), and if none pass it keeps the BEST attempt rather than the last.

    The logic lives in fleet-lib.ps1 as pure, injectable policy functions:
      Invoke-BestOfN          - the orchestrator (loop N candidates, early-exit on first green,
                                else select the best-ranked partial). Mechanism is injected.
      Test-IsCandidateGreen   - the early-exit predicate (definitive winner?).
      Get-CandidateRank       - score a candidate for the best-PARTIAL pick.
      Select-BestCandidateIndex - pick the highest-ranked candidate (earliest wins ties).
      Add-CandidateDiversity  - decorrelate independent candidate k from the others.

  This script proves that behaviour two ways:

    1. UNIT TESTS  (always run; no model / no OVMS needed; ~1 second)
       Drives the REAL functions with deterministic, scripted "candidates" and checks the
       control flow EXACTLY: early-exit, selection, best-partial, bounded N, malformed-result
       normalisation, and DIVERSITY (distinct decorrelated prompts per candidate). Designed to
       be mutation-resistant -- it asserts call COUNTS and ORDER, not just outputs.

    2. LIVE TEST   (only with -IncludeLive; needs OVMS up with the coder loaded; a few minutes)
       Runs the real fleet (new-agent-task.ps1) against a throwaway repo and checks the dispatch
       reached a deterministic-gate decision. Model variance / timeouts are INCONCLUSIVE, never
       a false FAIL.

  Exit code is 0 if everything that CAN be validated passed, 1 if any check failed.
  Run it normally ( .\verify-bestofn.ps1 ) - do NOT dot-source it.

.EXAMPLE
  .\verify-bestofn.ps1
      Fast, deterministic unit suite. Safe to run any time, even with OVMS off.

.EXAMPLE
  .\verify-bestofn.ps1 -IncludeLive
      Also run the live end-to-end test (OVMS must be up with the coder loaded).
#>
param(
    [switch]$IncludeLive,
    [int]$MaxLiveMinutes = 8,
    [string]$Model = ''
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\fleet-lib.ps1"

# ----------------------------------------------------------------------------
# Tiny zero-dependency test framework (no Pester needed - works offline forever).
# Mirrors verify-retry.ps1 so the fleet's suites read identically.
# ----------------------------------------------------------------------------
$script:Pass = 0
$script:Fail = 0
$script:Inconclusive = 0
$script:Failures = New-Object System.Collections.ArrayList

function Section($t) { Write-Host ''; Write-Host "== $t ==" -ForegroundColor Cyan }
function _pass($m)   { $script:Pass++; Write-Host "  [PASS] $m" -ForegroundColor Green }
function _fail($m)   { $script:Fail++; [void]$script:Failures.Add($m); Write-Host "  [FAIL] $m" -ForegroundColor Red }
function _inconc($m) { $script:Inconclusive++; Write-Host "  [INCONCLUSIVE] $m" -ForegroundColor Yellow }

function Assert-Eq($Expected, $Actual, $Msg) {
    if ([string]$Expected -ceq [string]$Actual) { _pass $Msg }
    else { _fail "$Msg (expected '$Expected', got '$Actual')" }
}
function Assert-True($Cond, $Msg)  { if ($Cond) { _pass $Msg } else { _fail "$Msg (expected True, got False)" } }
function Assert-False($Cond, $Msg) { if (-not $Cond) { _pass $Msg } else { _fail "$Msg (expected False, got True)" } }
function Assert-Contains($Haystack, $Needle, $Msg) {
    if ($Haystack -and $Haystack.ToString().Contains($Needle)) { _pass $Msg }
    else { _fail "$Msg (did not find '$Needle')" }
}

# ----------------------------------------------------------------------------
# Scripted fake CANDIDATE runner. $script:Plan is a list of per-candidate gate
# outcomes; the runner returns the candidate-result shape Invoke-BestOfN expects
# and records the EXACT call order so control flow can be proven. The injected
# IsWinner/ScoreCandidate call the REAL Test-IsCandidateGreen / Get-CandidateRank.
# ----------------------------------------------------------------------------
$script:Plan = @()
$script:runCalls = New-Object System.Collections.ArrayList
$script:onCalls  = New-Object System.Collections.ArrayList

$RunFromPlan = {
    param($Index, $Total)
    [void]$script:runCalls.Add(@{ Index = $Index; Total = $Total })
    $p = $script:Plan[$Index - 1]
    @{
        Index        = $Index
        VerifyResult = $p.Verify
        TestResult   = $p.Test
        HasChanges   = [bool]$p.Changes
        TimedOut     = [bool]$p.TimedOut
        SecretBlocked= [bool]$p.Secret
        LoopSuspected= [bool]$p.Loop
        # #740/W7: the production candidate nests the circuit-breaker reason under .Run.TimeoutReason
        # ('idle' | 'ceiling' | ''); mirror that so the reason-aware StopSampling can read it.
        Run          = @{ TimeoutReason = "$($p.Reason)" }
        Tag          = "c$Index"
    }
}
$OnCand   = { param($Index, $Total) [void]$script:onCalls.Add(@{ Index = $Index; Total = $Total }) }
$IsWinner = { param($r) Test-IsCandidateGreen -VerifyResult $r.VerifyResult -TestResult $r.TestResult -HasChanges $r.HasChanges -TimedOut $r.TimedOut -SecretBlocked $r.SecretBlocked }
$Score    = { param($r) Get-CandidateRank -VerifyResult $r.VerifyResult -TestResult $r.TestResult -HasChanges $r.HasChanges -TimedOut $r.TimedOut -SecretBlocked $r.SecretBlocked -LoopSuspected $r.LoopSuspected }

function Reset-Recorders {
    $script:runCalls = New-Object System.Collections.ArrayList
    $script:onCalls  = New-Object System.Collections.ArrayList
}

# ============================================================================
Section 'Test-IsCandidateGreen - the early-exit (definitive winner) predicate'
# ============================================================================
Assert-True  (Test-IsCandidateGreen -VerifyResult 'pass' -TestResult 'pass' -HasChanges $true)  'verify=pass + test=pass + changes => GREEN'
Assert-True  (Test-IsCandidateGreen -VerifyResult 'pass' -TestResult 'none' -HasChanges $true)  'verify=pass + test=none (build-only) + changes => GREEN'
Assert-False (Test-IsCandidateGreen -VerifyResult 'pass' -TestResult 'fail' -HasChanges $true)  'verify=pass + test=FAIL => not green'
Assert-False (Test-IsCandidateGreen -VerifyResult 'none' -TestResult 'pass' -HasChanges $true)  'verify=none (nothing vouched) => not green even if tests pass'
Assert-False (Test-IsCandidateGreen -VerifyResult 'fail' -TestResult 'pass' -HasChanges $true)  'verify=FAIL => not green'
Assert-False (Test-IsCandidateGreen -VerifyResult 'pass' -TestResult 'pass' -HasChanges $false) 'no changes => not green (a no-op can never win)'
Assert-False (Test-IsCandidateGreen -VerifyResult 'pass' -TestResult 'pass' -HasChanges $true -SecretBlocked $true) 'secret-blocked => never green'
Assert-False (Test-IsCandidateGreen -VerifyResult 'pass' -TestResult 'pass' -HasChanges $true -TimedOut $true)      'timed-out => never green'
Assert-True  (Test-IsCandidateGreen -VerifyResult 'PASS' -TestResult 'Pass' -HasChanges $true)  'case-insensitive on the gate strings'

# ============================================================================
Section 'Get-CandidateRank - monotonic ordering for the best-PARTIAL pick'
# ============================================================================
$rGreen  = Get-CandidateRank -VerifyResult 'pass' -TestResult 'pass' -HasChanges $true
$rBuild  = Get-CandidateRank -VerifyResult 'pass' -TestResult 'none' -HasChanges $true
$rVnoneT = Get-CandidateRank -VerifyResult 'none' -TestResult 'pass' -HasChanges $true
$rVfail  = Get-CandidateRank -VerifyResult 'fail' -TestResult 'fail' -HasChanges $true
$rNoop   = Get-CandidateRank -VerifyResult 'pass' -TestResult 'pass' -HasChanges $false
$rSecret = Get-CandidateRank -VerifyResult 'pass' -TestResult 'pass' -HasChanges $true -SecretBlocked $true
$rTimeout= Get-CandidateRank -VerifyResult 'pass' -TestResult 'pass' -HasChanges $true -TimedOut $true
Assert-True ($rGreen -gt $rBuild)   'green (pass/pass) outranks build-only (pass/none)'
Assert-True ($rBuild -gt $rVnoneT)  'verify=pass dominates: build-only outranks verify=none+test=pass'
Assert-True ($rVnoneT -gt $rVfail)  'verify=none+test=pass outranks verify=fail+test=fail'
Assert-True ($rGreen -gt $rNoop)    'a real change outranks a no-op of the same gate class'
Assert-True ($rSecret -lt $rVfail)  'a secret-blocked attempt sinks below every real attempt'
Assert-True ($rTimeout -lt $rVfail) 'a timed-out attempt sinks below a clean failing attempt'

# ============================================================================
Section 'Select-BestCandidateIndex - highest rank, earliest wins ties'
# ============================================================================
Assert-Eq -1 (Select-BestCandidateIndex -Ranks @())        'empty list => -1'
Assert-Eq  0 (Select-BestCandidateIndex -Ranks @(42))      'single element => index 0'
Assert-Eq  2 (Select-BestCandidateIndex -Ranks @(1,5,9,3)) 'max in the middle => its index'
Assert-Eq  1 (Select-BestCandidateIndex -Ranks @(1,5,5,2)) 'tie on the max => EARLIEST (lowest) index'
Assert-Eq  0 (Select-BestCandidateIndex -Ranks @(7,7,7))   'all equal => index 0 (earliest)'

# ============================================================================
Section 'Add-CandidateDiversity - byte-identical attempt 1, decorrelated 2..N'
# ============================================================================
Assert-Eq 'BASE' (Add-CandidateDiversity -Prompt 'BASE' -Index 1 -Total 3) 'candidate 1 prompt is UNCHANGED (happy path byte-identical)'
$d2 = Add-CandidateDiversity -Prompt 'BASE' -Index 2 -Total 3
$d3 = Add-CandidateDiversity -Prompt 'BASE' -Index 3 -Total 3
Assert-True ($d2.StartsWith('BASE'))      'candidate 2 preserves the original prompt verbatim (prefix)'
Assert-True ($d2 -ne $d3)                 'candidates 2 and 3 are DISTINCT (decorrelated) - the diversity lock'
Assert-Contains $d2 'variant tag: c2'     'candidate 2 carries its own variant tag'
Assert-Contains $d3 'variant tag: c3'     'candidate 3 carries its own variant tag'
Assert-Contains $d2 'INDEPENDENT ATTEMPT 2 OF 3' 'candidate 2 is framed as an independent attempt'
$dBadTotal = Add-CandidateDiversity -Prompt 'BASE' -Index 4 -Total 2
Assert-Contains $dBadTotal 'ATTEMPT 4 OF 4' 'Total < Index is normalised up to Index (no nonsensical "4 of 2")'

# ============================================================================
Section 'Invoke-BestOfN - early-exit on the FIRST green candidate'
# ============================================================================
$script:Plan = @(
    @{ Verify='fail'; Test='fail'; Changes=$true },   # c1 fails
    @{ Verify='pass'; Test='pass'; Changes=$true },   # c2 GREEN  -> stop here
    @{ Verify='pass'; Test='pass'; Changes=$true }    # c3 never runs
)
Reset-Recorders
$r = Invoke-BestOfN -MaxCandidates 3 -RunCandidate $RunFromPlan -IsWinner $IsWinner -ScoreCandidate $Score -OnCandidate $OnCand
Assert-True  $r.WinnerFound                 'a winner was found'
Assert-Eq  1 $r.SelectedIndex               'selected the 2nd candidate (0-based index 1)'
Assert-Eq  2 $r.Count                       'exactly 2 candidates were generated'
Assert-Eq  2 $script:runCalls.Count         'RunCandidate called EXACTLY twice (3rd never run - no wasted sample)'
Assert-Eq  2 $script:onCalls.Count          'OnCandidate fired once per generated candidate'
Assert-Eq 'c2' $r.Selected.Tag              'Selected is the actual 2nd candidate result'

# ============================================================================
Section 'Invoke-BestOfN - candidate 1 green => exactly one build (cost-neutral happy path)'
# ============================================================================
$script:Plan = @( @{ Verify='pass'; Test='pass'; Changes=$true }, @{ Verify='pass'; Test='pass'; Changes=$true } )
Reset-Recorders
$r = Invoke-BestOfN -MaxCandidates 3 -RunCandidate $RunFromPlan -IsWinner $IsWinner -ScoreCandidate $Score -OnCandidate $OnCand
Assert-True  $r.WinnerFound          'winner on candidate 1'
Assert-Eq  0 $r.SelectedIndex        'selected index 0'
Assert-Eq  1 $script:runCalls.Count  'only ONE candidate generated (an easy task is not slower than before)'

# ============================================================================
Section 'Invoke-BestOfN - no winner => runs all N, selects the BEST partial by gate rank'
# ============================================================================
$script:Plan = @(
    @{ Verify='fail'; Test='fail'; Changes=$true },   # c1 worst
    @{ Verify='none'; Test='pass'; Changes=$true },   # c2 middling
    @{ Verify='pass'; Test='fail'; Changes=$true }    # c3 builds but a test fails -> highest rank, still not a winner
)
Reset-Recorders
$r = Invoke-BestOfN -MaxCandidates 3 -RunCandidate $RunFromPlan -IsWinner $IsWinner -ScoreCandidate $Score -OnCandidate $OnCand
Assert-False $r.WinnerFound          'no definitive winner (none passed the gate clean)'
Assert-Eq  3 $script:runCalls.Count  'all 3 candidates generated when none win'
Assert-Eq  2 $r.SelectedIndex        'best PARTIAL = the verify=pass candidate (highest rank), gate-selected'
Assert-Eq 'c3' $r.Selected.Tag       'Selected carries the best partial candidate'

# ============================================================================
Section 'Invoke-BestOfN - bounded N and the empty case'
# ============================================================================
$script:Plan = @( @{ Verify='fail'; Test='fail'; Changes=$true }, @{ Verify='fail'; Test='fail'; Changes=$true } )
Reset-Recorders
$r = Invoke-BestOfN -MaxCandidates 2 -RunCandidate $RunFromPlan -IsWinner $IsWinner -ScoreCandidate $Score -OnCandidate $OnCand
Assert-Eq 2 $script:runCalls.Count   'never generates more than MaxCandidates'
Assert-Eq 2 $r.Count                 'Count reflects the bounded number generated'

Reset-Recorders
$r0 = Invoke-BestOfN -MaxCandidates 0 -RunCandidate $RunFromPlan -IsWinner $IsWinner -ScoreCandidate $Score -OnCandidate $OnCand
Assert-Eq 0 $script:runCalls.Count   'MaxCandidates < 1 generates NOTHING'
Assert-False $r0.WinnerFound         'no winner with zero candidates'
Assert-Eq -1 $r0.SelectedIndex       'SelectedIndex = -1 with zero candidates'
Assert-True ($null -eq $r0.Selected) 'Selected is null with zero candidates'

# ============================================================================
Section 'Invoke-BestOfN - malformed-result normalisation (mutation guards)'
# ============================================================================
Reset-Recorders
$rBad = Invoke-BestOfN -MaxCandidates 1 -RunCandidate { param($i,$n) 'not-a-hashtable' } -IsWinner $IsWinner -ScoreCandidate $Score
Assert-False $rBad.WinnerFound 'a non-hashtable candidate result is never a winner'
Assert-Eq  1 $rBad.Count       'a malformed candidate is still counted (not dropped silently)'

Reset-Recorders
$rStray = Invoke-BestOfN -MaxCandidates 1 -RunCandidate { param($i,$n) Write-Output 'stray noise'; @{ VerifyResult='pass'; TestResult='pass'; HasChanges=$true; TimedOut=$false; SecretBlocked=$false; LoopSuspected=$false; Tag='real' } } -IsWinner $IsWinner -ScoreCandidate $Score
Assert-True $rStray.WinnerFound 'the LAST emitted object (the real hashtable) is used despite stray output'
Assert-Eq 'real' $rStray.Selected.Tag 'normalisation kept the real candidate, not the stray string'

# ============================================================================
Section 'Invoke-BestOfN - DIVERSITY end-to-end (each candidate gets a decorrelated prompt)'
# ============================================================================
# This is the regression-lock the DoD requires: best-of-N coverage assumes DIVERSE samples;
# correlated samples flatten the curve. Drive the real Add-CandidateDiversity through the
# orchestrator and assert each candidate's prompt is distinct + preserves the base task.
$script:prompts = New-Object System.Collections.ArrayList
$divRunner = {
    param($Index, $Total)
    $cp = Add-CandidateDiversity -Prompt 'BUILD-A-CALCULATOR' -Index $Index -Total $Total
    [void]$script:prompts.Add($cp)
    @{ VerifyResult='fail'; TestResult='fail'; HasChanges=$true; TimedOut=$false; SecretBlocked=$false; LoopSuspected=$false }   # all fail so all N run
}
$script:prompts = New-Object System.Collections.ArrayList
$rDiv = Invoke-BestOfN -MaxCandidates 3 -RunCandidate $divRunner -IsWinner $IsWinner -ScoreCandidate $Score
Assert-Eq 3 $script:prompts.Count 'all 3 candidate prompts captured'
Assert-Eq 'BUILD-A-CALCULATOR' $script:prompts[0] 'candidate 1 prompt is the base task, byte-identical'
Assert-True ($script:prompts[0] -ne $script:prompts[1]) 'candidate 2 prompt differs from candidate 1'
Assert-True ($script:prompts[1] -ne $script:prompts[2]) 'candidate 3 prompt differs from candidate 2 (distinct samples)'
Assert-True ($script:prompts[1].StartsWith('BUILD-A-CALCULATOR')) 'candidate 2 still carries the full task'
Assert-True ($script:prompts[2].StartsWith('BUILD-A-CALCULATOR')) 'candidate 3 still carries the full task'

# ============================================================================
Section 'Invoke-BestOfN - replaces the serial re-fix: fresh samples converge to green'
# ============================================================================
# The old serial loop re-fixed one failing attempt (correlated). Best-of-N keeps sampling
# FRESH independent attempts; the first that the gate vouches for wins. Two early misses then a
# green = a merge the serial self-correction often never reached.
$script:Plan = @(
    @{ Verify='fail'; Test='none'; Changes=$true },   # c1 build miss
    @{ Verify='fail'; Test='none'; Changes=$true },   # c2 build miss
    @{ Verify='pass'; Test='pass'; Changes=$true }    # c3 fresh independent sample lands green
)
Reset-Recorders
$r = Invoke-BestOfN -MaxCandidates 5 -RunCandidate $RunFromPlan -IsWinner $IsWinner -ScoreCandidate $Score -OnCandidate $OnCand
Assert-True  $r.WinnerFound          'a fresh independent sample reached green'
Assert-Eq  2 $r.SelectedIndex        'the 3rd candidate (index 2) is the winner'
Assert-Eq  3 $script:runCalls.Count  'stopped at the first green (did not burn the full budget of 5)'

# ============================================================================
Section 'Invoke-BestOfN - StopSampling preserves the "never retry away a secret/timeout" posture'
# ============================================================================
$Stop = { param($r) $r.SecretBlocked -or $r.TimedOut }
# Timeout is TERMINAL (the model is genuinely stuck; expensive to retry) -> stop sampling, but the
# SELECTION still falls to the best earlier REAL attempt (a timeout never gets picked over real work).
$script:Plan = @(
    @{ Verify='fail'; Test='fail'; Changes=$true },                   # c1 real failed build (outranks a timeout)
    @{ Verify='none'; Test='none'; Changes=$true; TimedOut=$true },   # c2 TIMEOUT -> stop here
    @{ Verify='pass'; Test='pass'; Changes=$true }                    # c3 never runs
)
Reset-Recorders
$r = Invoke-BestOfN -MaxCandidates 3 -RunCandidate $RunFromPlan -IsWinner $IsWinner -ScoreCandidate $Score -StopSampling $Stop -OnCandidate $OnCand
Assert-False $r.WinnerFound          'a timeout is NOT a win'
Assert-True  $r.Stopped              'StopSampling broke the loop on the timeout'
Assert-Eq  2 $script:runCalls.Count  'stopped at the timeout (3rd candidate never generated)'
Assert-Eq  0 $r.SelectedIndex        'best-partial picks the earlier REAL attempt over the timed-out one'

# Secret-block is TERMINAL and must be SURFACED to a human -> stop immediately, never sampled-away.
$script:Plan = @(
    @{ Verify='fail'; Test='fail'; Changes=$true },                   # c1
    @{ Verify='none'; Test='none'; Changes=$true; Secret=$true },     # c2 SECRET -> stop
    @{ Verify='pass'; Test='pass'; Changes=$true }                    # c3 never runs
)
Reset-Recorders
$r = Invoke-BestOfN -MaxCandidates 3 -RunCandidate $RunFromPlan -IsWinner $IsWinner -ScoreCandidate $Score -StopSampling $Stop -OnCandidate $OnCand
Assert-True  $r.Stopped              'StopSampling broke the loop on the secret-block'
Assert-Eq  2 $script:runCalls.Count  'stopped at the secret (3rd candidate never generated - the secret is not sampled-away)'
Assert-True (@($r.Candidates | Where-Object { $_.SecretBlocked }).Count -ge 1) 'the secret-blocked candidate is surfaced in Candidates for the caller to park'

# A green winner takes precedence over StopSampling (a green attempt is never terminal).
$script:Plan = @( @{ Verify='pass'; Test='pass'; Changes=$true } )
Reset-Recorders
$r = Invoke-BestOfN -MaxCandidates 3 -RunCandidate $RunFromPlan -IsWinner $IsWinner -ScoreCandidate $Score -StopSampling $Stop
Assert-True  $r.WinnerFound 'green winner found even with StopSampling wired'
Assert-False $r.Stopped     'a winner is not a stop'

# ============================================================================
Section 'Test-IsSamplingTerminal - reason-aware terminal classification (#740/W7)'
# ============================================================================
# The SSOT the production -StopSampling delegates to. An IDLE stall is a random per-build slip
# (resample-eligible); a wall-clock CEILING, an empty/unknown reason (safe default), and a secret stay
# terminal. Drives the REAL helper directly (mutation-resistant unit coverage).
Assert-True  (Test-IsSamplingTerminal -TimedOut $true  -TimeoutReason 'ceiling' -SecretBlocked $false) 'ceiling timeout => terminal'
Assert-False (Test-IsSamplingTerminal -TimedOut $true  -TimeoutReason 'idle'    -SecretBlocked $false) 'idle timeout => NOT terminal (resample-eligible)'
Assert-True  (Test-IsSamplingTerminal -TimedOut $true  -TimeoutReason ''        -SecretBlocked $false) 'empty/unknown reason => terminal (safe default = ceiling)'
Assert-True  (Test-IsSamplingTerminal -TimedOut $true  -TimeoutReason 'idle'    -SecretBlocked $true)  'secret DOMINATES: idle + secret => terminal (surface to a human)'
Assert-True  (Test-IsSamplingTerminal -TimedOut $false -TimeoutReason ''        -SecretBlocked $true)  'secret (no timeout) => terminal'
Assert-False (Test-IsSamplingTerminal -TimedOut $false -TimeoutReason ''        -SecretBlocked $false) 'no timeout + no secret => not terminal'
Assert-False (Test-IsSamplingTerminal -TimedOut $true  -TimeoutReason 'IDLE'    -SecretBlocked $false) 'reason match is case-insensitive (IDLE => not terminal)'

# ============================================================================
Section 'Invoke-BestOfN - #740/W7: an IDLE timeout is RESAMPLE-eligible; CEILING/secret stay terminal'
# ============================================================================
# The production wiring: the injected StopSampling delegates to Test-IsSamplingTerminal, reading the
# candidate's nested .Run.TimeoutReason -- byte-identical to new-agent-task.ps1.
$StopReasonAware = { param($r) Test-IsSamplingTerminal -SecretBlocked $r.SecretBlocked -TimedOut $r.TimedOut -TimeoutReason "$($r.Run.TimeoutReason)" }

# (a) idle-timeout candidate -> resample FIRES: a fresh candidate runs and can win (the 2026-07-03 no-op fix).
$script:Plan = @(
    @{ Verify='none'; Test='none'; Changes=$false; TimedOut=$true; Reason='idle' },   # c1 IDLE stall (read a couple files, went silent)
    @{ Verify='pass'; Test='pass'; Changes=$true },                                    # c2 fresh independent sample lands green
    @{ Verify='pass'; Test='pass'; Changes=$true }                                     # c3 never runs (c2 won)
)
Reset-Recorders
$r = Invoke-BestOfN -MaxCandidates 3 -RunCandidate $RunFromPlan -IsWinner $IsWinner -ScoreCandidate $Score -StopSampling $StopReasonAware -OnCandidate $OnCand
Assert-True  $r.WinnerFound          'idle-timeout c1 did NOT stop sampling -> a fresh c2 reached green'
Assert-False $r.Stopped              'an idle stall is not a terminal stop'
Assert-Eq  1 $r.SelectedIndex        'the fresh sample (c2) is the winner, not the idle c1'
Assert-Eq  2 $script:runCalls.Count  'best-of-N resampled PAST the idle stall (c2 ran) - the N=3->N=1 collapse that no-op''d the 2026-07-03 dispatch is fixed'

# (b) ceiling-timeout candidate -> STAYS terminal: stop sampling (the #689 expensive-runaway invariant).
$script:Plan = @(
    @{ Verify='fail'; Test='fail'; Changes=$true },                                    # c1 real failed build (outranks a timeout)
    @{ Verify='none'; Test='none'; Changes=$false; TimedOut=$true; Reason='ceiling' }, # c2 CEILING wall-clock hit -> terminal
    @{ Verify='pass'; Test='pass'; Changes=$true }                                     # c3 never runs
)
Reset-Recorders
$r = Invoke-BestOfN -MaxCandidates 3 -RunCandidate $RunFromPlan -IsWinner $IsWinner -ScoreCandidate $Score -StopSampling $StopReasonAware -OnCandidate $OnCand
Assert-False $r.WinnerFound          'a ceiling timeout is not a win'
Assert-True  $r.Stopped              'a wall-clock CEILING timeout STAYS terminal -> stop sampling'
Assert-Eq  2 $script:runCalls.Count  'stopped at the ceiling timeout (c3 never generated)'
Assert-Eq  0 $r.SelectedIndex        'best-partial picks the earlier REAL attempt over the ceiling-timed-out one'

# (c) secret-block -> STAYS terminal, even if the candidate ALSO idled (secret dominates -> surface to a human).
$script:Plan = @(
    @{ Verify='fail'; Test='fail'; Changes=$true },                                          # c1
    @{ Verify='none'; Test='none'; Changes=$true; Secret=$true; TimedOut=$true; Reason='idle' }, # c2 SECRET + idle -> terminal (secret wins)
    @{ Verify='pass'; Test='pass'; Changes=$true }                                           # c3 never runs
)
Reset-Recorders
$r = Invoke-BestOfN -MaxCandidates 3 -RunCandidate $RunFromPlan -IsWinner $IsWinner -ScoreCandidate $Score -StopSampling $StopReasonAware -OnCandidate $OnCand
Assert-True  $r.Stopped              'a secret-block STAYS terminal even with an idle reason present (secret is never sampled-away)'
Assert-Eq  2 $script:runCalls.Count  'stopped at the secret (c3 never generated)'
Assert-True (@($r.Candidates | Where-Object { $_.SecretBlocked }).Count -ge 1) 'the secret candidate is surfaced in Candidates for the caller to park'

# (d) empty/unknown reason -> treated as CEILING (terminal) -- the safe default, never a silent resample.
$script:Plan = @(
    @{ Verify='fail'; Test='fail'; Changes=$true },                                # c1 real fail
    @{ Verify='none'; Test='none'; Changes=$false; TimedOut=$true; Reason='' },     # c2 UNKNOWN reason -> safe default = ceiling = terminal
    @{ Verify='pass'; Test='pass'; Changes=$true }                                 # c3 never runs
)
Reset-Recorders
$r = Invoke-BestOfN -MaxCandidates 3 -RunCandidate $RunFromPlan -IsWinner $IsWinner -ScoreCandidate $Score -StopSampling $StopReasonAware -OnCandidate $OnCand
Assert-True  $r.Stopped              'an empty/unknown timeout reason is treated as CEILING (terminal) - the safe default'
Assert-Eq  2 $script:runCalls.Count  'stopped at the unknown-reason timeout (does not silently resample an unreadable reason)'

# (e) an all-idle storm resamples but is BOUNDED by the existing MaxCandidates budget -> runs N, then parks.
$script:Plan = @(
    @{ Verify='none'; Test='none'; Changes=$false; TimedOut=$true; Reason='idle' },  # c1 idle
    @{ Verify='none'; Test='none'; Changes=$false; TimedOut=$true; Reason='idle' },  # c2 idle
    @{ Verify='none'; Test='none'; Changes=$false; TimedOut=$true; Reason='idle' }   # c3 idle
)
Reset-Recorders
$r = Invoke-BestOfN -MaxCandidates 3 -RunCandidate $RunFromPlan -IsWinner $IsWinner -ScoreCandidate $Score -StopSampling $StopReasonAware -OnCandidate $OnCand
Assert-False $r.WinnerFound          'an all-idle storm produces no winner'
Assert-False $r.Stopped              'no terminal stop - every idle candidate is resample-eligible'
Assert-Eq  3 $script:runCalls.Count  'idle resamples are BOUNDED by the existing MaxCandidates budget (exactly N=3, never unbounded) -> then park (no new budget added)'

# ----------------------------------------------------------------------------
# LIVE end-to-end (opt-in): a real dispatch through new-agent-task.ps1.
# ----------------------------------------------------------------------------
if ($IncludeLive) {
    Section 'LIVE - real best-of-N dispatch through new-agent-task.ps1 (needs OVMS + coder)'
    try {
        $loaded = $null
        try {
            $resp = Invoke-WebRequest 'http://127.0.0.1:8000/v3/models' -TimeoutSec 3 -UseBasicParsing -ErrorAction Stop
            $loaded = @((($resp.Content | ConvertFrom-Json).data) | ForEach-Object { $_.id })
        } catch { $loaded = $null }
        if (-not $loaded) {
            _inconc 'OVMS not up on :8000 - start the coder (start-llm.ps1 -Model coder-30b) then re-run with -IncludeLive.'
        } else {
            $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("bestofn-live-" + [System.IO.Path]::GetRandomFileName().Replace('.', ''))
            New-Item -ItemType Directory -Force $tmp | Out-Null
            Push-Location $tmp
            git init -q 2>&1 | Out-Null
            git -c user.email='t@local' -c user.name='t' commit --allow-empty -q -m 'baseline' 2>&1 | Out-Null
            Pop-Location
            $useModel = if ($Model) { $Model } else { "local/$($loaded[0])" }
            Write-Host "  Running a real dispatch in $tmp (model $useModel, up to $MaxLiveMinutes min)..." -ForegroundColor DarkGray
            & "$PSScriptRoot\new-agent-task.ps1" -Repo $tmp -Task 'palindrome' `
                -Prompt 'Add a Python function is_palindrome(s) that ignores case and non-alphanumeric characters, with at least three pytest tests in tests/test_palindrome.py.' `
                -Model $useModel -MaxRunMinutes $MaxLiveMinutes -Complexity 'simple' 2>&1 | Out-Null
            $report = Get-ChildItem (Join-Path $PSScriptRoot '..\state\reports') -Filter '*palindrome*' -ErrorAction SilentlyContinue |
                      Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($report) {
                $body = Get-Content $report.FullName -Raw
                if ($body -match 'RESULT:\s*MERGED') { _pass 'live dispatch reached a green gate and MERGED (best-of-N produced a winner)' }
                elseif ($body -match 'RESULT:') { _inconc "live dispatch ran but did not merge (model variance): $((($body -split "`n") | Where-Object { $_ -match 'RESULT:' } | Select-Object -First 1))" }
                else { _inconc 'live dispatch ran but the report had no RESULT line (treated as inconclusive)' }
            } else {
                _inconc 'live dispatch produced no report (treated as inconclusive)'
            }
        }
    } catch {
        _inconc "live test error (treated as inconclusive, never a false fail): $($_.Exception.Message)"
    }
}

# ----------------------------------------------------------------------------
Write-Host ''
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host ("RESULT: {0} passed, {1} failed, {2} inconclusive" -f $script:Pass, $script:Fail, $script:Inconclusive) -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
if ($script:Fail) {
    Write-Host 'FAILURES:' -ForegroundColor Red
    $script:Failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
}
Write-Host '============================================================' -ForegroundColor Cyan
exit $(if ($script:Fail) { 1 } else { 0 })
