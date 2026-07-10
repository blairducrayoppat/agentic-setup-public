#requires -Version 5.1
<#
.SYNOPSIS
  Verify the fleet's CONCURRENT best-of-N batched orchestrator + the concurrency knob (#695, epic #688).

.DESCRIPTION
  Background (plain English):
    Sequential best-of-N (#689) takes a few FRESH, INDEPENDENT attempts at a task and lets the
    deterministic gate pick the winner. #695 makes those attempts run CONCURRENTLY -- up to C at a time,
    each in its own git worktree, hitting OVMS continuous batching (measured viable on the Arc 140V).
    The CONTROL FLOW (which batch runs, when to stop, who is selected) is the pure Invoke-BestOfNBatched;
    the concurrent MECHANISM (worktrees + Start-Job) is INJECTED so the policy is unit-tested with NO model.

    This suite drives the REAL Invoke-BestOfNBatched / Resolve-DispatchConcurrency with scripted, deterministic
    "candidates" and proves the control flow EXACTLY -- mutation-resistant: it asserts batch COMPOSITION,
    batch-level early-exit, the secret/timeout-under-batching posture (#695 section 6, the highest-risk
    regression), best-partial selection, the C=1-reduces-to-sequential equivalence, and the knob resolution
    (explicit > env > default, clamped). It needs no OVMS and no coder; it runs in ~1 second.

  Run it normally ( .\verify-bestofn-concurrent.ps1 ) - do NOT dot-source it.
  Exit code 0 if everything passed, 1 if any check failed.
#>
param()
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\fleet-lib.ps1"

# ----------------------------------------------------------------------------
# Tiny zero-dependency test framework (mirrors verify-bestofn.ps1 so the suites read identically).
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
function Assert-True($Cond, $Msg)  { if ($Cond) { _pass $Msg } else { _fail "$Msg (expected True, got False)" } }
function Assert-False($Cond, $Msg) { if (-not $Cond) { _pass $Msg } else { _fail "$Msg (expected False, got True)" } }

# REAL injected predicates (identical to the production new-agent-task.ps1 wiring).
$IsWinner = { param($r) Test-IsCandidateGreen -VerifyResult $r.VerifyResult -TestResult $r.TestResult -HasChanges $r.HasChanges -TimedOut $r.TimedOut -SecretBlocked $r.SecretBlocked }
$Score    = { param($r) Get-CandidateRank -VerifyResult $r.VerifyResult -TestResult $r.TestResult -HasChanges $r.HasChanges -TimedOut $r.TimedOut -SecretBlocked $r.SecretBlocked -LoopSuspected $r.LoopSuspected }
$Stop     = { param($r) ([bool]$r.SecretBlocked) -or ([bool]$r.TimedOut) }

# ----------------------------------------------------------------------------
# Scripted fake BATCH runner. $script:Plan is a per-candidate gate-outcome list; the runner returns the
# batch's candidate-result shapes IN INDEX ORDER, and records the exact batch COMPOSITION each call so the
# concurrent control flow can be proven (which candidates ran together, when sampling stopped).
# ----------------------------------------------------------------------------
$script:Plan = @()
$script:batchCalls   = New-Object System.Collections.ArrayList
$script:onBatchCalls = New-Object System.Collections.ArrayList
$RunBatchFromPlan = {
    param($Indices, $Total)
    [void]$script:batchCalls.Add(@($Indices))
    $out = @()
    foreach ($k in $Indices) {
        $p = $script:Plan[$k - 1]
        $out += @{
            Index = $k; VerifyResult = $p.Verify; TestResult = $p.Test; HasChanges = [bool]$p.Changes
            TimedOut = [bool]$p.TimedOut; SecretBlocked = [bool]$p.Secret; LoopSuspected = [bool]$p.Loop; Tag = "c$k"
            # #740/W7: mirror the production candidate's nested circuit-breaker reason ('idle' | 'ceiling' | '')
            # so the reason-aware StopSampling can distinguish an idle stall from a wall-clock ceiling.
            Run = @{ TimeoutReason = "$($p.Reason)" }
        }
    }
    return $out
}
$OnBatch = { param($Indices, $Total) [void]$script:onBatchCalls.Add(@($Indices)) }
function Reset-Rec { $script:batchCalls = New-Object System.Collections.ArrayList; $script:onBatchCalls = New-Object System.Collections.ArrayList }

# ============================================================================
Section 'Resolve-DispatchConcurrency - explicit > env > default, clamped to [1, Max]'
# ============================================================================
# The no-arg result IS the PRODUCTION DEFAULT (the function's -Default). LA-set to 3 (2026-06-27), live-proven
# on the Arc 140V. These three lock it mutation-resistantly: exact value, "concurrent not sequential", and
# "within the measured 2-3 sweet spot" -- a revert to 1, a drift to 2, or a runaway each fail a distinct check.
Assert-Eq 3 (Resolve-DispatchConcurrency)             'no args -> the production default is 3 (LA-chosen, live-proven)'
Assert-True ((Resolve-DispatchConcurrency) -gt 1)     '[kill] the default is CONCURRENT (>1), not a regression to sequential C=1'
Assert-True ((Resolve-DispatchConcurrency) -le 3)     '[kill] the default stays within the measured compute-bound sweet spot (<=3)'
Assert-Eq 3 (Resolve-DispatchConcurrency -Explicit 3)                 'an explicit value wins'
Assert-Eq 2 (Resolve-DispatchConcurrency -EnvValue '2')              'env value parsed when no explicit'
Assert-Eq 4 (Resolve-DispatchConcurrency -Explicit 4 -EnvValue '2')  'explicit overrides env'
Assert-Eq 5 (Resolve-DispatchConcurrency -EnvValue '  5 ')           'env value is trimmed then parsed'
# These test the FALLBACK MECHANISM (invalid/unset -> the default) against the no-arg default, so the exact
# default value stays locked in ONE place (the Assert-Eq 3 above) and a future change does not have to chase them.
$__def = Resolve-DispatchConcurrency
Assert-Eq $__def (Resolve-DispatchConcurrency -EnvValue 'abc')       'non-numeric env is ignored -> falls through to the default'
Assert-Eq $__def (Resolve-DispatchConcurrency -EnvValue '0')        'env 0 -> falls through to the default (never < 1)'
Assert-Eq $__def (Resolve-DispatchConcurrency -Explicit 0)         'explicit 0 means unset -> falls through to the default'
Assert-Eq $__def (Resolve-DispatchConcurrency -Explicit -5)        'a negative explicit is ignored -> falls through to the default (never < 1)'
Assert-Eq 8 (Resolve-DispatchConcurrency -Explicit 99)              'clamped to the Max ceiling (8)'
Assert-Eq 7 (Resolve-DispatchConcurrency -Explicit 99 -Max 7)       'clamp respects a custom Max'
Assert-Eq 2 (Resolve-DispatchConcurrency -Default 2)               'the -Default IS the single knob (proves the flip point: -Default 2 => 2)'
Assert-Eq 3 (Resolve-DispatchConcurrency -EnvValue '99' -Max 3)     'an env value is clamped to Max too'

# ----------------------------------------------------------------------------
Section 'Resolve-DispatchConcurrency - RAM-headroom guard (#714, the tight-box stall fix)'
Assert-Eq 3 (Resolve-DispatchConcurrency -AvailableGiB 0)             '[kill] AvailableGiB=0 (default / unit tests) -> NO guard, pure resolution unchanged (C=3)'
Assert-Eq 1 (Resolve-DispatchConcurrency -AvailableGiB 5)             '5 GiB free -> C=1 (the measured F2 starve threshold that hung production)'
Assert-Eq 1 (Resolve-DispatchConcurrency -Explicit 3 -AvailableGiB 5) 'the guard caps even an EXPLICIT C=3 down to 1 on a tight box'
Assert-Eq 2 (Resolve-DispatchConcurrency -AvailableGiB 15)            '15 GiB free -> C=2'
Assert-Eq 3 (Resolve-DispatchConcurrency -AvailableGiB 25)            '25 GiB free -> C=3 (ample headroom, default unchanged)'
Assert-Eq 2 (Resolve-DispatchConcurrency -Explicit 2 -AvailableGiB 100) '[kill] the guard only LOWERS C, never raises it above the requested value'
Assert-Eq 1 (Resolve-DispatchConcurrency -AvailableGiB 3)             '[kill] never below 1 even on a nearly-full box'
Assert-Eq 1 (Resolve-DispatchConcurrency -Explicit 8 -AvailableGiB 6 -GiBPerCandidate 7) 'GiBPerCandidate tunable; 6/7 -> floor 0 -> clamped to 1'

# ============================================================================
Section 'Invoke-BestOfNBatched - batch COMPOSITION (C=2, N=3 => [1,2] then [3])'
# ============================================================================
$script:Plan = @(
    @{ Verify='fail'; Test='fail'; Changes=$true },   # c1
    @{ Verify='fail'; Test='fail'; Changes=$true },   # c2
    @{ Verify='fail'; Test='fail'; Changes=$true }    # c3
)
Reset-Rec
$r = Invoke-BestOfNBatched -MaxCandidates 3 -Concurrency 2 -RunBatch $RunBatchFromPlan -IsWinner $IsWinner -ScoreCandidate $Score -StopSampling $Stop -OnBatch $OnBatch
Assert-Eq 2 $script:batchCalls.Count          'two batches launched for N=3 at C=2'
Assert-Eq '1,2' ($script:batchCalls[0] -join ',') 'batch 1 = candidates 1,2 (run concurrently)'
Assert-Eq '3'   ($script:batchCalls[1] -join ',') 'batch 2 = candidate 3'
Assert-Eq 3 $r.Count                          'all 3 candidates ran (none green)'
Assert-Eq 2 $script:onBatchCalls.Count        'OnBatch fired once per batch'
Assert-Eq '1,2' ($script:onBatchCalls[0] -join ',') 'OnBatch carries the batch-1 indices'

# ============================================================================
Section 'PRODUCTION CONFIG (LA 2026-06-27): default concurrency 3 + complex budget 8 compose to 3 waves of 3,3,2'
# ============================================================================
# Ties the two LA-chosen knobs together through the REAL production functions, so "do the new concurrency +
# complexity choices actually work end-to-end" is a LOCKED test, not a hope: derive C and N from the
# production functions and drive the orchestrator -- a complex task at the default concurrency must run all
# 8 candidates in three waves (3, 3, 2), no phantom 9th, none dropped.
$prodC = Resolve-DispatchConcurrency                       # the production default concurrency (=3)
$prodN = (Resolve-PassBudget -Complexity 'complex').Build  # the complex best-of-N budget (=8)
Assert-Eq 3 $prodC 'derived production concurrency is 3'
Assert-Eq 8 $prodN 'derived complex best-of-N budget is 8'
$script:Plan = @(1..8 | ForEach-Object { @{ Verify='fail'; Test='fail'; Changes=$true } })   # all fail -> run the full budget
Reset-Rec
$rProd = Invoke-BestOfNBatched -MaxCandidates $prodN -Concurrency $prodC -RunBatch $RunBatchFromPlan -IsWinner $IsWinner -ScoreCandidate $Score -StopSampling $Stop -OnBatch $OnBatch
Assert-Eq 3 $script:batchCalls.Count                'a complex task (N=8) at the default C=3 runs in exactly 3 waves'
Assert-Eq '1,2,3' ($script:batchCalls[0] -join ',') 'wave 1 = candidates 1,2,3 (full concurrency width)'
Assert-Eq '4,5,6' ($script:batchCalls[1] -join ',') 'wave 2 = candidates 4,5,6'
Assert-Eq '7,8'   ($script:batchCalls[2] -join ',') 'wave 3 = the remaining 7,8 (no phantom 9th candidate)'
Assert-Eq 8 $rProd.Count                            'exactly 8 candidates ran -- the full complex budget, none dropped'

# ============================================================================
Section 'Invoke-BestOfNBatched - earliest-index winner in a batch wins, and stops further batches'
# ============================================================================
$script:Plan = @(
    @{ Verify='fail'; Test='fail'; Changes=$true },   # c1 fails
    @{ Verify='pass'; Test='pass'; Changes=$true },   # c2 GREEN
    @{ Verify='pass'; Test='pass'; Changes=$true }    # c3 never runs
)
Reset-Rec
$r = Invoke-BestOfNBatched -MaxCandidates 3 -Concurrency 2 -RunBatch $RunBatchFromPlan -IsWinner $IsWinner -ScoreCandidate $Score -StopSampling $Stop
Assert-True  $r.WinnerFound          'a winner was found in batch 1'
Assert-Eq  1 $r.SelectedIndex        'winner is c2 (0-based index 1)'
Assert-Eq  1 $script:batchCalls.Count 'a winning batch STOPS further batches (batch 2 never launched)'
Assert-Eq  2 $r.Count                'only the 2 batch-1 candidates ran'
Assert-Eq 'c2' $r.Selected.Tag       'Selected is the real c2 result'

# two greens in ONE batch -> the EARLIEST wins (deterministic, favours the cheapest)
$script:Plan = @(
    @{ Verify='pass'; Test='pass'; Changes=$true },   # c1 GREEN
    @{ Verify='pass'; Test='pass'; Changes=$true }    # c2 GREEN
)
Reset-Rec
$r = Invoke-BestOfNBatched -MaxCandidates 2 -Concurrency 2 -RunBatch $RunBatchFromPlan -IsWinner $IsWinner -ScoreCandidate $Score -StopSampling $Stop
Assert-True  $r.WinnerFound  'a winner among two greens'
Assert-Eq  0 $r.SelectedIndex 'the EARLIEST-index winner in the batch wins (c1, not c2)'

# ============================================================================
Section 'Invoke-BestOfNBatched - SECTION 6: a green winner takes precedence over a co-batch secret/timeout'
# ============================================================================
# The highest-risk regression: a single concurrent batch can hold BOTH a green winner AND a secret/timeout
# candidate (impossible in the sequential loop). A clean, independent green winner still wins (it is real,
# gated work); the non-selected secret candidate''s work is discarded with its worktree (never committed,
# cannot leak) but stays in Candidates so the caller can surface a non-blocking note.
$script:Plan = @(
    @{ Verify='pass'; Test='pass'; Changes=$true },                 # c1 GREEN
    @{ Verify='none'; Test='none'; Changes=$true; Secret=$true }    # c2 SECRET (same batch)
)
Reset-Rec
$r = Invoke-BestOfNBatched -MaxCandidates 2 -Concurrency 2 -RunBatch $RunBatchFromPlan -IsWinner $IsWinner -ScoreCandidate $Score -StopSampling $Stop
Assert-True  $r.WinnerFound  'a clean green winner takes precedence over a co-batch secret (green is never terminal)'
Assert-Eq  0 $r.SelectedIndex 'the winner c1 is selected, not the secret'
Assert-False $r.Stopped      'a winning batch is not a stop'
Assert-True (@($r.Candidates | Where-Object { $_.SecretBlocked }).Count -ge 1) 'the co-batch secret candidate is still present in Candidates for a non-blocking surface'

# ============================================================================
Section 'Invoke-BestOfNBatched - SECTION 6: a secret (no winner) stops further batches + is surfaced, never selected'
# ============================================================================
$script:Plan = @(
    @{ Verify='fail'; Test='fail'; Changes=$true },                 # c1 real fail (outranks a secret)
    @{ Verify='none'; Test='none'; Changes=$true; Secret=$true },   # c2 SECRET -> stop
    @{ Verify='pass'; Test='pass'; Changes=$true }                  # c3 never runs
)
Reset-Rec
$r = Invoke-BestOfNBatched -MaxCandidates 3 -Concurrency 2 -RunBatch $RunBatchFromPlan -IsWinner $IsWinner -ScoreCandidate $Score -StopSampling $Stop
Assert-False $r.WinnerFound          'a secret is NOT a win'
Assert-True  $r.Stopped              'a secret in the batch stopped sampling'
Assert-Eq  1 $script:batchCalls.Count 'batch 2 (candidate 3) was NOT launched after the secret (not sampled-away)'
Assert-True (@($r.Candidates | Where-Object { $_.SecretBlocked }).Count -ge 1) 'the secret candidate is surfaced in Candidates for the caller to park'
Assert-Eq  0 $r.SelectedIndex        'best-partial picks the real failing attempt (c1) over the secret'

# ============================================================================
Section 'Invoke-BestOfNBatched - SECTION 6: a timeout is terminal, never selected over an earlier real attempt'
# ============================================================================
$script:Plan = @(
    @{ Verify='fail'; Test='fail'; Changes=$true },                  # c1 real failed build (outranks a timeout)
    @{ Verify='none'; Test='none'; Changes=$true; TimedOut=$true }   # c2 TIMEOUT (same batch)
)
Reset-Rec
$r = Invoke-BestOfNBatched -MaxCandidates 2 -Concurrency 2 -RunBatch $RunBatchFromPlan -IsWinner $IsWinner -ScoreCandidate $Score -StopSampling $Stop
Assert-False $r.WinnerFound   'a timeout is not a win'
Assert-True  $r.Stopped       'a timeout in the batch stopped sampling'
Assert-Eq  0 $r.SelectedIndex 'a timed-out candidate is NEVER selected over an earlier real attempt'

# ============================================================================
Section 'Invoke-BestOfNBatched - #740/W7: an IDLE timeout is RESAMPLE-eligible; CEILING/secret stay terminal (under batching)'
# ============================================================================
# The production wiring: the injected StopSampling delegates to Test-IsSamplingTerminal, reading the
# candidate's nested .Run.TimeoutReason -- byte-identical to new-agent-task.ps1. The batch posture invariant
# (#695 section 6) is PRESERVED: a batch holding a ceiling/secret candidate still terminates sampling; a
# batch holding only idle candidates does NOT.
$StopReasonAware = { param($r) Test-IsSamplingTerminal -SecretBlocked $r.SecretBlocked -TimedOut $r.TimedOut -TimeoutReason "$($r.Run.TimeoutReason)" }

# (a) an IDLE candidate does NOT stop sampling -> the next batch launches (C=1 -> each candidate is its own batch).
$script:Plan = @(
    @{ Verify='none'; Test='none'; Changes=$false; TimedOut=$true; Reason='idle' },  # c1 idle (batch 1)
    @{ Verify='pass'; Test='pass'; Changes=$true },                                   # c2 green (batch 2)
    @{ Verify='pass'; Test='pass'; Changes=$true }                                    # c3 never runs
)
Reset-Rec
$r = Invoke-BestOfNBatched -MaxCandidates 3 -Concurrency 1 -RunBatch $RunBatchFromPlan -IsWinner $IsWinner -ScoreCandidate $Score -StopSampling $StopReasonAware -OnBatch $OnBatch
Assert-True  $r.WinnerFound           'idle c1 did not stop batching -> a fresh c2 batch reached green'
Assert-False $r.Stopped               'an idle stall is not a terminal stop under batching'
Assert-Eq  1 $r.SelectedIndex         'c2 (index 1) is the winner, not the idle c1'
Assert-Eq  2 $script:batchCalls.Count 'the batch AFTER the idle stall launched (idle is resample-eligible; the 2026-07-03 no-op fix under concurrency)'

# (b) a CEILING candidate STAYS terminal -> stop launching further batches.
$script:Plan = @(
    @{ Verify='fail'; Test='fail'; Changes=$true },                                    # c1 real fail (batch 1)
    @{ Verify='none'; Test='none'; Changes=$false; TimedOut=$true; Reason='ceiling' }, # c2 ceiling (batch 2) -> terminal
    @{ Verify='pass'; Test='pass'; Changes=$true }                                     # c3 never runs
)
Reset-Rec
$r = Invoke-BestOfNBatched -MaxCandidates 3 -Concurrency 1 -RunBatch $RunBatchFromPlan -IsWinner $IsWinner -ScoreCandidate $Score -StopSampling $StopReasonAware -OnBatch $OnBatch
Assert-True  $r.Stopped               'a ceiling timeout STAYS terminal under batching -> stop launching further batches'
Assert-Eq  2 $script:batchCalls.Count 'stopped after the ceiling batch (the c3 batch never launched)'
Assert-Eq  0 $r.SelectedIndex         'best-partial picks the real failing c1 over the ceiling c2'

# (posture) a SINGLE batch holding BOTH an idle AND a ceiling candidate STILL terminates (ceiling wins; idle
# alone would not have). The concurrent analogue of the section-6 secret/timeout-in-one-batch posture.
$script:Plan = @(
    @{ Verify='none'; Test='none'; Changes=$false; TimedOut=$true; Reason='idle' },    # c1 idle    (same batch)
    @{ Verify='none'; Test='none'; Changes=$false; TimedOut=$true; Reason='ceiling' }, # c2 ceiling (same batch)
    @{ Verify='pass'; Test='pass'; Changes=$true }                                     # c3 never runs
)
Reset-Rec
$r = Invoke-BestOfNBatched -MaxCandidates 3 -Concurrency 2 -RunBatch $RunBatchFromPlan -IsWinner $IsWinner -ScoreCandidate $Score -StopSampling $StopReasonAware -OnBatch $OnBatch
Assert-True  $r.Stopped               'a batch containing a CEILING candidate terminates sampling even though it also holds an idle candidate'
Assert-Eq  1 $script:batchCalls.Count 'the ceiling stopped the batch loop (the second wave holding c3 never launched)'

# (posture) a green winner alongside a co-batch idle candidate STILL wins (green is never terminal).
$script:Plan = @(
    @{ Verify='pass'; Test='pass'; Changes=$true },                                  # c1 GREEN
    @{ Verify='none'; Test='none'; Changes=$false; TimedOut=$true; Reason='idle' }    # c2 idle (same batch)
)
Reset-Rec
$r = Invoke-BestOfNBatched -MaxCandidates 2 -Concurrency 2 -RunBatch $RunBatchFromPlan -IsWinner $IsWinner -ScoreCandidate $Score -StopSampling $StopReasonAware -OnBatch $OnBatch
Assert-True  $r.WinnerFound   'a clean green winner takes precedence over a co-batch idle candidate'
Assert-Eq  0 $r.SelectedIndex 'the green c1 is selected, not the idle c2'
Assert-False $r.Stopped       'a winning batch is not a stop'

# (c) a SECRET stays terminal even alongside an idle reason (secret dominates -> surface to a human).
$script:Plan = @(
    @{ Verify='fail'; Test='fail'; Changes=$true },                                              # c1 real fail (batch 1)
    @{ Verify='none'; Test='none'; Changes=$true; Secret=$true; TimedOut=$true; Reason='idle' }, # c2 secret + idle (batch 2)
    @{ Verify='pass'; Test='pass'; Changes=$true }                                               # c3 never runs
)
Reset-Rec
$r = Invoke-BestOfNBatched -MaxCandidates 3 -Concurrency 1 -RunBatch $RunBatchFromPlan -IsWinner $IsWinner -ScoreCandidate $Score -StopSampling $StopReasonAware -OnBatch $OnBatch
Assert-True  $r.Stopped               'a secret-block stays terminal under batching even with an idle reason present'
Assert-Eq  2 $script:batchCalls.Count 'stopped at the secret batch (the c3 batch never launched)'
Assert-True (@($r.Candidates | Where-Object { $_.SecretBlocked }).Count -ge 1) 'the secret candidate is surfaced in Candidates for the caller to park'

# (d) an empty/unknown reason is treated as CEILING (terminal) under batching too.
$script:Plan = @(
    @{ Verify='fail'; Test='fail'; Changes=$true },                            # c1 real fail (batch 1)
    @{ Verify='none'; Test='none'; Changes=$false; TimedOut=$true; Reason='' }, # c2 unknown reason (batch 2) -> ceiling = terminal
    @{ Verify='pass'; Test='pass'; Changes=$true }                             # c3 never runs
)
Reset-Rec
$r = Invoke-BestOfNBatched -MaxCandidates 3 -Concurrency 1 -RunBatch $RunBatchFromPlan -IsWinner $IsWinner -ScoreCandidate $Score -StopSampling $StopReasonAware -OnBatch $OnBatch
Assert-True  $r.Stopped               'empty/unknown reason under batching -> terminal (safe default = ceiling)'
Assert-Eq  2 $script:batchCalls.Count 'stopped at the unknown-reason batch (does not silently resample an unreadable reason)'

# (e) an all-idle storm resamples across waves but is BOUNDED by MaxCandidates -> runs N, then parks.
$script:Plan = @(
    @{ Verify='none'; Test='none'; Changes=$false; TimedOut=$true; Reason='idle' },
    @{ Verify='none'; Test='none'; Changes=$false; TimedOut=$true; Reason='idle' },
    @{ Verify='none'; Test='none'; Changes=$false; TimedOut=$true; Reason='idle' }
)
Reset-Rec
$r = Invoke-BestOfNBatched -MaxCandidates 3 -Concurrency 2 -RunBatch $RunBatchFromPlan -IsWinner $IsWinner -ScoreCandidate $Score -StopSampling $StopReasonAware -OnBatch $OnBatch
Assert-False $r.WinnerFound  'an all-idle storm produces no winner'
Assert-False $r.Stopped      'no terminal stop - every idle candidate is resample-eligible'
Assert-Eq  3 $r.Count        'idle resamples BOUNDED by MaxCandidates (exactly N=3 ran across the waves) -> then park (no new budget)'

# ============================================================================
Section 'Invoke-BestOfNBatched - no winner across batches => best PARTIAL by gate rank'
# ============================================================================
$script:Plan = @(
    @{ Verify='fail'; Test='fail'; Changes=$true },   # c1 worst
    @{ Verify='none'; Test='pass'; Changes=$true },   # c2 middling
    @{ Verify='pass'; Test='fail'; Changes=$true }    # c3 builds but a test fails -> highest rank, not a winner
)
Reset-Rec
$r = Invoke-BestOfNBatched -MaxCandidates 3 -Concurrency 2 -RunBatch $RunBatchFromPlan -IsWinner $IsWinner -ScoreCandidate $Score -StopSampling $Stop
Assert-False $r.WinnerFound   'no definitive winner (none passed the gate clean)'
Assert-Eq  3 $r.Count         'all 3 candidates ran across the two batches'
Assert-Eq  2 $r.SelectedIndex 'best PARTIAL = the verify=pass candidate (c3), gate-ranked across batches'
Assert-Eq 'c3' $r.Selected.Tag 'Selected carries the best-partial candidate'

# ============================================================================
Section 'Invoke-BestOfNBatched - C=1 reduces to the sequential Invoke-BestOfN behaviour'
# ============================================================================
$script:Plan = @(
    @{ Verify='fail'; Test='fail'; Changes=$true },
    @{ Verify='pass'; Test='pass'; Changes=$true },   # c2 GREEN
    @{ Verify='pass'; Test='pass'; Changes=$true }
)
Reset-Rec
$r = Invoke-BestOfNBatched -MaxCandidates 3 -Concurrency 1 -RunBatch $RunBatchFromPlan -IsWinner $IsWinner -ScoreCandidate $Score -StopSampling $Stop
Assert-True  $r.WinnerFound          'C=1 finds the winner'
Assert-Eq  1 $r.SelectedIndex        'C=1 selects c2 (index 1)'
Assert-Eq  2 $r.Count                'C=1 early-exits at the first green (2 candidates ran) - sequential-equivalent'
Assert-Eq  2 $script:batchCalls.Count 'C=1 => exactly one candidate per batch'
Assert-Eq '1' ($script:batchCalls[0] -join ',') 'C=1 batch 1 = [1]'
Assert-Eq '2' ($script:batchCalls[1] -join ',') 'C=1 batch 2 = [2]'

# ============================================================================
Section 'Invoke-BestOfNBatched - bounds: C>=N is one batch; C<1 clamps to 1; the empty case'
# ============================================================================
$script:Plan = @( @{ Verify='fail'; Test='fail'; Changes=$true }, @{ Verify='fail'; Test='fail'; Changes=$true } )
Reset-Rec
$r = Invoke-BestOfNBatched -MaxCandidates 2 -Concurrency 4 -RunBatch $RunBatchFromPlan -IsWinner $IsWinner -ScoreCandidate $Score -StopSampling $Stop
Assert-Eq 1 $script:batchCalls.Count          'C>=N => a single batch'
Assert-Eq '1,2' ($script:batchCalls[0] -join ',') 'the single batch holds exactly N candidates (capped at MaxCandidates, not C)'
Assert-Eq 2 $r.Count                          'never more than MaxCandidates run'

Reset-Rec
$r = Invoke-BestOfNBatched -MaxCandidates 2 -Concurrency 0 -RunBatch $RunBatchFromPlan -IsWinner $IsWinner -ScoreCandidate $Score -StopSampling $Stop
Assert-Eq 2 $script:batchCalls.Count 'Concurrency < 1 is clamped to 1 (one candidate per batch)'

Reset-Rec
$r0 = Invoke-BestOfNBatched -MaxCandidates 0 -Concurrency 2 -RunBatch $RunBatchFromPlan -IsWinner $IsWinner -ScoreCandidate $Score
Assert-Eq 0 $script:batchCalls.Count 'MaxCandidates < 1 launches NOTHING'
Assert-False $r0.WinnerFound         'no winner with zero candidates'
Assert-Eq -1 $r0.SelectedIndex       'SelectedIndex = -1 with zero candidates'
Assert-True ($null -eq $r0.Selected) 'Selected is null with zero candidates'

# ============================================================================
Section 'Invoke-BestOfNBatched - malformed / short batch normalisation (mutation guards)'
# ============================================================================
Reset-Rec
$rBad = Invoke-BestOfNBatched -MaxCandidates 2 -Concurrency 2 -RunBatch { param($idx, $n) @('not-a-hashtable', 'also-bad') } -IsWinner $IsWinner -ScoreCandidate $Score
Assert-False $rBad.WinnerFound 'non-hashtable batch results never win'
Assert-Eq  2 $rBad.Count       'malformed candidates are still counted (normalised, not dropped)'

# a batch that returns FEWER results than indices: the missing slots become disqualified placeholders.
Reset-Rec
$rShort = Invoke-BestOfNBatched -MaxCandidates 2 -Concurrency 2 -IsWinner $IsWinner -ScoreCandidate $Score -RunBatch {
    param($idx, $n) @( @{ VerifyResult='pass'; TestResult='pass'; HasChanges=$true; TimedOut=$false; SecretBlocked=$false; LoopSuspected=$false; Tag='only1' } )
}
Assert-True  $rShort.WinnerFound 'a short batch (fewer results than indices) still finds the present winner'
Assert-Eq  2 $rShort.Count       'the missing slot is normalised to a placeholder (count == batch size)'
Assert-Eq  0 $rShort.SelectedIndex 'the present (first) candidate is the winner'

# ============================================================================
Section 'ConvertTo-CandidateResult - re-normalises a (deserialised) job result + tags it; null -> placeholder'
# ============================================================================
# A null/failed job becomes a fully-disqualified placeholder (can never win, never outranks a real attempt).
$pl = ConvertTo-CandidateResult -Raw $null -Index 3 -Worktree 'C:\x-c3' -Branch 'agent/t-c3'
Assert-True ($pl -is [hashtable])      'a null job result -> a real hashtable placeholder'
Assert-Eq 3 $pl.Index                  'placeholder carries the Index'
Assert-Eq 'C:\x-c3' $pl.Worktree       'placeholder carries the Worktree (for promotion/cleanup)'
Assert-Eq 'agent/t-c3' $pl.Branch      'placeholder carries the Branch'
Assert-False $pl.HasChanges            'placeholder has no changes'
Assert-False (Test-IsCandidateGreen -VerifyResult $pl.VerifyResult -TestResult $pl.TestResult -HasChanges $pl.HasChanges -TimedOut $pl.TimedOut -SecretBlocked $pl.SecretBlocked) 'a placeholder is never green'
Assert-True ($pl.Run -is [hashtable])  'placeholder Run is a clean nested hashtable'
Assert-True ($pl.Anomaly.Anomalies -is [array]) 'placeholder Anomalies is an array (downstream does .Count / -join)'

# A deserialised-like candidate (PSCustomObject mirrors the CliXml shape a Start-Job result comes back as)
# -> a clean hashtable with real scalars + nested hashtables (not Deserialized.*), tagged with Index/Worktree.
$des = [pscustomobject]@{
    VerifyResult='pass'; TestResult='none'; HasChanges=$true; TimedOut=$false; SecretBlocked=$false; LoopSuspected=$false
    SHA='abc123'; BuildAttempts=2; TestError=''; VerifyDetail='[pass] dotnet:build'; VerifyError=''; AgentLog='C:\log'
    Run=[pscustomobject]@{ ExitCode=0; TimedOut=$false; TimeoutReason=''; Capped=$false; CappedReason=''; Seconds=12.3; Error='' }
    Secret=[pscustomobject]@{ status='clean'; detail='' }
    Anomaly=[pscustomobject]@{ Anomalies=@(); LoopSuspected=$false }
}
$cn = ConvertTo-CandidateResult -Raw $des -Index 1 -Worktree 'C:\x-c1' -Branch 'agent/t-c1'
Assert-True ($cn -is [hashtable])  'a deserialised candidate -> a real hashtable'
Assert-Eq 'pass' $cn.VerifyResult  'VerifyResult preserved'
Assert-Eq 'abc123' $cn.SHA         'SHA preserved'
Assert-Eq 1 $cn.Index              'Index tagged from the parent'
Assert-True ($cn.HasChanges -is [bool]) 'HasChanges coerced to a real bool'
Assert-Eq 0 $cn.Run.ExitCode       'nested Run.ExitCode preserved'
Assert-True ($cn.Run -is [hashtable]) 'nested Run is a clean hashtable (not Deserialized.*)'
Assert-True (Test-IsCandidateGreen -VerifyResult $cn.VerifyResult -TestResult $cn.TestResult -HasChanges $cn.HasChanges -TimedOut $cn.TimedOut -SecretBlocked $cn.SecretBlocked) 'a pass/none/changes candidate is correctly GREEN after normalisation'

# ============================================================================
Section 'Wiring: new-agent-task + run-fleet + fleet-lib carry the concurrent path (and PRESERVE C=1)'
# ============================================================================
$nat      = Get-Content "$PSScriptRoot\new-agent-task.ps1" -Raw
$lib      = Get-Content "$PSScriptRoot\fleet-lib.ps1" -Raw
$runFleet = Get-Content "$PSScriptRoot\run-fleet.ps1" -Raw
Assert-True ([regex]::IsMatch($lib, 'function Resolve-DispatchConcurrency')) 'fleet-lib defines Resolve-DispatchConcurrency'
Assert-True ([regex]::IsMatch($lib, 'function Invoke-BestOfNBatched'))       'fleet-lib defines Invoke-BestOfNBatched'
Assert-True ([regex]::IsMatch($lib, 'function Invoke-CandidateBuild'))       'fleet-lib defines Invoke-CandidateBuild'
Assert-True ([regex]::IsMatch($nat, '\[int\]\$Concurrency'))                 'new-agent-task accepts a -Concurrency parameter'
Assert-True ([regex]::IsMatch($nat, 'Resolve-DispatchConcurrency'))          'new-agent-task resolves the effective concurrency'
Assert-True ([regex]::IsMatch($nat, '\$bonc?\s*=\s*Invoke-BestOfNBatched'))  'new-agent-task drives the concurrent path via Invoke-BestOfNBatched'
Assert-True ([regex]::IsMatch($nat, 'Start-Job'))                            'new-agent-task launches concurrent candidates via Start-Job (process isolation)'
Assert-True ([regex]::IsMatch($nat, 'Invoke-CandidateBuild'))                'new-agent-task runs each concurrent candidate through Invoke-CandidateBuild'
Assert-True ([regex]::IsMatch($nat, '(?m)^\s*\$bon\s*=\s*Invoke-BestOfN\b')) 'the SEQUENTIAL best-of-N path (C=1) is preserved (Invoke-BestOfN still wired, byte-identical)'
Assert-True ([regex]::IsMatch($runFleet, '\$params\.Concurrency'))           'run-fleet forwards a concurrency override to new-agent-task'

# #740/W7 idle-resample wiring: the best-of-N terminal decision now delegates to the reason-aware SSOT so an
# IDLE stall no longer collapses N=3 to N=1. These mutation-lock BOTH the helper's existence and the wiring.
Assert-True ([regex]::IsMatch($lib, 'function Test-IsSamplingTerminal'))                       'fleet-lib defines Test-IsSamplingTerminal (the reason-aware terminal SSOT, #740/W7)'
Assert-Eq 2 ([regex]::Matches($nat, 'StopSampling\s*\{[^}]*Test-IsSamplingTerminal').Count)    'BOTH best-of-N paths (sequential + concurrent) delegate StopSampling to Test-IsSamplingTerminal'
Assert-True ([regex]::IsMatch($nat, 'StopSampling\s*\{[^}]*TimeoutReason'))                    'the StopSampling predicate reads the candidate timeout REASON (idle vs ceiling), not just TimedOut'
Assert-False ([regex]::IsMatch($nat, '\(\[bool\]\$c\.SecretBlocked\)\s*-or\s*\(\[bool\]\$c\.TimedOut\)')) '[kill] the pre-change blanket "secret OR any timeout" StopSampling is GONE (an idle timeout no longer stops best-of-N)'

# ============================================================================
Section 'Wiring: #700 unification -- ONE per-candidate pipeline (Invoke-CandidateBuild), no duplicated gate body'
# ============================================================================
# #700 folded new-agent-task's $BuildTestVerify gate body INTO Invoke-CandidateBuild so the sequential (C=1)
# and concurrent (C>1) paths run the SAME function -- removing the drift hazard of two copies. These lock it.
Assert-True ([regex]::IsMatch($nat, '\$BuildTestVerify\s*=\s*\{[\s\S]{0,500}Invoke-CandidateBuild')) 'the sequential $BuildTestVerify DELEGATES to Invoke-CandidateBuild (C=1 runs the SAME pipeline as C>1)'
Assert-False ([regex]::IsMatch($nat, 'Format-VerifyError\s+-Checks\s+\$vobj\.checks')) '[kill] the duplicated gate body is GONE from new-agent-task -- the gate lives ONLY in Invoke-CandidateBuild (#700, no drift)'
Assert-True ([regex]::IsMatch($lib, 'function Invoke-CandidateBuild[\s\S]{0,12000}Format-VerifyError\s+-Checks\s+\$vobj\.checks')) '[kill] the single gate body (Format-VerifyError) lives inside Invoke-CandidateBuild'
Assert-True ([regex]::IsMatch($lib, '\[bool\]\$ResetToBase')) 'Invoke-CandidateBuild has -ResetToBase (the sequential reuse-one-worktree reset folded in by #700)'

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
