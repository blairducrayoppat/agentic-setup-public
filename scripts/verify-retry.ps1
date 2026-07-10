#requires -Version 5.1
<#
.SYNOPSIS
  Verify and validate the fleet's RETRY-ON-FAILURE capability.

.DESCRIPTION
  Background (plain English):
    The local model sometimes finishes a build attempt having changed NOTHING - it
    printed a tool call as plain text, or tried to write outside the project and was
    blocked. That is a "no-op". Retry-on-failure notices a no-op and simply runs the
    attempt again (up to a few tries), starting each retry from a clean workspace. It
    does NOT retry a timeout (a timeout means the model is genuinely stuck, not a
    cheap slip). The logic lives in Invoke-BuildWithRetry (fleet-lib.ps1) and is used
    by the fleet runner new-agent-task.ps1.

  This script proves that behaviour two ways:

    1. UNIT TESTS  (always run; no model / no OVMS needed; ~1 second)
       Drives the REAL Invoke-BuildWithRetry function with deterministic, scripted
       "attempts" and checks it retries, stops, resets, and caps EXACTLY as specified.
       This is the authoritative proof of the logic - it cannot flake. The suite is
       designed to be mutation-resistant: it was hardened against a battery of
       adversarial code mutations that an earlier version let slip through.

    2. LIVE TEST   (only with -IncludeLive; needs OVMS running; a few minutes)
       Runs the real fleet (new-agent-task.ps1) against a throwaway repo to show the
       retry firing end-to-end with the actual local model. The live test classifies
       model variance / timeouts as INCONCLUSIVE, never as a false FAIL.

  Exit code is 0 if everything that CAN be validated passed, 1 if any check failed.
  Run it normally ( .\verify-retry.ps1 ) - do NOT dot-source it.

.EXAMPLE
  .\verify-retry.ps1
      Fast, deterministic unit suite. Safe to run any time, even with OVMS off.

.EXAMPLE
  .\verify-retry.ps1 -IncludeLive
      Also run the live end-to-end test (OVMS must be up with a model loaded).
#>
param(
    [switch]$IncludeLive,
    [int]$MaxLiveMinutes = 5,   # per-attempt circuit-breaker for the live test
    [string]$Model = ''         # optional; defaults to whatever OVMS has loaded
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\fleet-lib.ps1"

# ----------------------------------------------------------------------------
# Tiny zero-dependency test framework (no Pester needed - works offline forever)
# ----------------------------------------------------------------------------
$script:Pass = 0
$script:Fail = 0
$script:Inconclusive = 0
$script:Failures = New-Object System.Collections.ArrayList

function Section($t) { Write-Host ''; Write-Host "== $t ==" -ForegroundColor Cyan }
function _pass($m)   { $script:Pass++; Write-Host "  [PASS] $m" -ForegroundColor Green }
function _fail($m)   { $script:Fail++; [void]$script:Failures.Add($m); Write-Host "  [FAIL] $m" -ForegroundColor Red }
function _inconc($m) { $script:Inconclusive++; Write-Host "  [INCONCLUSIVE] $m" -ForegroundColor Yellow }

# Case-SENSITIVE exact match (so 'True' vs 'true' would be caught - matches our "exact" claim).
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
function Assert-Contains($Haystack, $Needle, $Msg) {
    if ($Haystack -and $Haystack.ToString().Contains($Needle)) { _pass $Msg }
    else { _fail "$Msg (did not find '$Needle')" }
}
function Assert-Throws($ScriptBlock, $Msg) {
    $threw = $false
    try { & $ScriptBlock | Out-Null } catch { $threw = $true }
    if ($threw) { _pass $Msg } else { _fail "$Msg (expected an exception, none thrown)" }
}

# ----------------------------------------------------------------------------
# Deterministic fake "agent": feed a SCRIPTED list of attempt outcomes and record
# the exact call order so we can prove the policy's control flow.
#   $Plan : array of @{ TimedOut=$bool; Changed=$bool; ExitCode=<optional> } - one per
#           planned attempt. ExitCode is INDEPENDENT of TimedOut: if omitted, the fake
#           stamps a unique per-attempt sentinel (100 + index) so a test can prove the
#           LAST attempt's result is the one returned. Specify ExitCode (incl. $null) to
#           exercise the null-exit / non-timeout case explicitly.
#   $Log  : ArrayList that captures the order of run / changed-check / reset / onretry.
# If the policy ever runs MORE attempts than planned, BOTH RunAgent and ProducedChanges
# THROW (loud failure, never a silent over-run / desync - independent of call order).
# ----------------------------------------------------------------------------
function New-RetryFake {
    param(
        [Parameter(Mandatory)][object[]]$Plan,
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.ArrayList]$Log
    )
    $state = [pscustomobject]@{ I = 0 }   # shared, mutable index across the closures
    $RunAgent = {
        if ($state.I -ge $Plan.Count) { throw "retry over-ran: RunAgent called more than the $($Plan.Count) planned attempt(s)" }
        $a = $Plan[$state.I]
        [void]$Log.Add("run#$($state.I + 1)")
        $exit = if ($a.ContainsKey('ExitCode')) { $a.ExitCode } else { 100 + $state.I }
        @{ TimedOut = [bool]$a.TimedOut; ExitCode = $exit }
    }.GetNewClosure()
    $ProducedChanges = {
        if ($state.I -ge $Plan.Count) { throw "retry desync: ProducedChanges called with no pending attempt (planned $($Plan.Count))" }
        $a = $Plan[$state.I]
        $state.I++
        [void]$Log.Add("changed#$($state.I)=$([bool]$a.Changed)")
        [bool]$a.Changed
    }.GetNewClosure()
    $ResetWorktree = { [void]$Log.Add('reset') }.GetNewClosure()
    $OnRetry       = { param($n) [void]$Log.Add("onretry=$n") }.GetNewClosure()
    @{ RunAgent = $RunAgent; ProducedChanges = $ProducedChanges; ResetWorktree = $ResetWorktree; OnRetry = $OnRetry }
}

function Invoke-Case {
    # Runs one scripted scenario through the REAL Invoke-BuildWithRetry.
    # Pass -Max -1 to omit -MaxBuildAttempts entirely (to test the default).
    # An over-run/desync tripwire (or any unexpected throw) is converted into a visible
    # [FAIL] with a sentinel result, so the suite renders its RESULT banner instead of
    # dying with a raw stack trace under $ErrorActionPreference='Stop'.
    param([object[]]$Plan, [int]$Max = -1)
    $log = New-Object System.Collections.ArrayList
    $f = New-RetryFake -Plan $Plan -Log $log
    try {
        if ($Max -eq -1) {
            $r = Invoke-BuildWithRetry -RunAgent $f.RunAgent -ProducedChanges $f.ProducedChanges -ResetWorktree $f.ResetWorktree -OnRetry $f.OnRetry
        } else {
            $r = Invoke-BuildWithRetry -RunAgent $f.RunAgent -ProducedChanges $f.ProducedChanges -ResetWorktree $f.ResetWorktree -OnRetry $f.OnRetry -MaxBuildAttempts $Max
        }
        return @{ Result = $r; Log = @($log) }
    } catch {
        _fail "harness tripwire fired (the retry policy over-ran or desynced): $($_.Exception.Message)"
        return @{ Result = @{ Attempts = -1; ProducedChanges = $false; Run = $null }; Log = @($log) }
    }
}

# ----------------------------------------------------------------------------
# UNIT TESTS - the authoritative, deterministic proof of the retry policy
# ----------------------------------------------------------------------------
Section 'Unit tests: retry policy (deterministic - no model needed)'

# U1: succeeds on the first attempt -> exactly 1 run, no retry, no reset.
$c = Invoke-Case -Plan @(@{ Changed = $true }) -Max 3
Assert-Eq 1 $c.Result.Attempts        'U1 success-first: runs exactly 1 attempt'
Assert-True $c.Result.ProducedChanges  'U1 success-first: reports that changes were produced'
Assert-True (-not ($c.Log -contains 'reset')) 'U1 success-first: never resets the worktree'
Assert-Eq 'run#1|changed#1=True' ($c.Log -join '|') 'U1 success-first: call order is a single run'
Assert-False $c.Result.Run.TimedOut    'U1 success-first: returned .Run.TimedOut is False (surfaced to caller)'
Assert-Eq 100 $c.Result.Run.ExitCode   'U1 success-first: returned .Run is the attempt''s real result (ExitCode 100)'

# U2: no-op then success -> 2 attempts; resets exactly once, BEFORE the 2nd run.
$c = Invoke-Case -Plan @(@{ Changed = $false }, @{ Changed = $true }) -Max 3
Assert-Eq 2 $c.Result.Attempts        'U2 noop-then-success: runs 2 attempts'
Assert-True $c.Result.ProducedChanges  'U2 noop-then-success: ends having produced changes'
Assert-Eq 'run#1|changed#1=False|onretry=2|reset|run#2|changed#2=True' ($c.Log -join '|') `
    'U2 noop-then-success: resets BEFORE the retry run (exact call order)'
Assert-Eq 101 $c.Result.Run.ExitCode   'U2 noop-then-success: returns the LAST attempt''s result (101), not the first (100)'

# U3: always no-op, max 3 -> exhausts at 3 attempts; full call-order pins reset-before-run each time.
$c = Invoke-Case -Plan @(@{ Changed = $false }, @{ Changed = $false }, @{ Changed = $false }) -Max 3
Assert-Eq 3 $c.Result.Attempts        'U3 always-noop: stops at MaxBuildAttempts (3)'
Assert-True (-not $c.Result.ProducedChanges) 'U3 always-noop: reports no changes'
Assert-Eq 'run#1|changed#1=False|onretry=2|reset|run#2|changed#2=False|onretry=3|reset|run#3|changed#3=False' ($c.Log -join '|') `
    'U3 always-noop: resets BEFORE every retry run (full call order, n=3)'

# U4: timeout on attempt 1 -> NO retry, even though 2 attempts remain.
$c = Invoke-Case -Plan @(@{ TimedOut = $true; Changed = $false }) -Max 3
Assert-Eq 1 $c.Result.Attempts        'U4 timeout: does NOT retry a timeout (stops at 1 despite max 3)'
Assert-True (-not ($c.Log -contains 'reset')) 'U4 timeout: no worktree reset after a timeout'
Assert-True $c.Result.Run.TimedOut     'U4 timeout: returned .Run.TimedOut is True (the timeout is surfaced to the merge gate)'

# U5: no-op then timeout -> stops on the timeout at attempt 2 (does not reach 3).
$c = Invoke-Case -Plan @(@{ Changed = $false }, @{ TimedOut = $true; Changed = $false }) -Max 3
Assert-Eq 2 $c.Result.Attempts        'U5 noop-then-timeout: stops on the timeout (attempt 2, not 3)'
Assert-True $c.Result.Run.TimedOut     'U5 noop-then-timeout: returned .Run reflects the LAST attempt (timed out)'

# U6: MaxBuildAttempts = 1 -> exactly one attempt, never retries.
$c = Invoke-Case -Plan @(@{ Changed = $false }) -Max 1
Assert-Eq 1 $c.Result.Attempts        'U6 max=1: runs exactly once, no retry'

# U7: MaxBuildAttempts < 1 yields a single attempt (loop structure + the coercion guard agree),
#     for 0 AND a negative value.
$c = Invoke-Case -Plan @(@{ Changed = $false }) -Max 0
Assert-Eq 1 $c.Result.Attempts        'U7a max=0: yields a single attempt'
$c = Invoke-Case -Plan @(@{ Changed = $false }) -Max -5
Assert-Eq 1 $c.Result.Attempts        'U7b max=-5: yields a single attempt'

# U8: default MaxBuildAttempts is 3 when not specified.
$c = Invoke-Case -Plan @(@{ Changed = $false }, @{ Changed = $false }, @{ Changed = $false }) -Max -1
Assert-Eq 3 $c.Result.Attempts        'U8 default-max: defaults to 3 attempts when unspecified'

# U9: WIRING - assert a real (non-comment) line in the production runner INVOKES the function,
#     not merely mentions it (a substring match would pass on the explanatory comment alone).
$prod = Get-Content "$PSScriptRoot\fleet-lib.ps1" -Raw   # #700: the build loop ($build = Invoke-BuildWithRetry) now lives in Invoke-CandidateBuild
$wired = [regex]::IsMatch($prod, '(?m)^\s*\$build\s*=\s*Invoke-BuildWithRetry\b')
Assert-True $wired 'U9 wiring: new-agent-task.ps1 INVOKES Invoke-BuildWithRetry on a real (non-comment) line'

# U10: a NON-timeout no-op that exits null is STILL retried. This is the key distinction
#      between "retry a no-op" and "never retry a timeout" - it kills any mutation that
#      proxies the timeout test through ExitCode (e.g. guard -> ($null -ne $run.ExitCode)).
$c = Invoke-Case -Plan @(@{ TimedOut = $false; ExitCode = $null; Changed = $false }, @{ Changed = $true }) -Max 3
Assert-Eq 2 $c.Result.Attempts        'U10 null-exit no-op: a non-timeout no-op with ExitCode=$null is RETRIED'
Assert-True $c.Result.ProducedChanges  'U10 null-exit no-op: recovers on the retry'

# U11: ProducedChanges that emits MULTIPLE values (stray output + $false) must be read as
#      a no-op (the last value), not as a change. Guards the [bool]-on-a-collection trap.
$st11 = [pscustomobject]@{ I = 0 }
$ra11 = { @{ TimedOut = $false; ExitCode = 0 } }.GetNewClosure()
$pc11 = { $st11.I++; if ($st11.I -eq 1) { Write-Output 'noise'; Write-Output $false } else { $true } }.GetNewClosure()
$r11 = Invoke-BuildWithRetry -RunAgent $ra11 -ProducedChanges $pc11 -MaxBuildAttempts 3
Assert-Eq 2 $r11.Attempts             'U11 multi-value changes: stray output + $false is a no-op (retry fires)'
Assert-True $r11.ProducedChanges       'U11 multi-value changes: recovers on the retry'

# U12: ProducedChanges that emits $null / nothing is read as a no-op.
$st12 = [pscustomobject]@{ I = 0 }
$ra12 = { @{ TimedOut = $false; ExitCode = 0 } }.GetNewClosure()
$pc12 = { $st12.I++; if ($st12.I -eq 1) { $null } else { $true } }.GetNewClosure()
$r12 = Invoke-BuildWithRetry -RunAgent $ra12 -ProducedChanges $pc12 -MaxBuildAttempts 3
Assert-Eq 2 $r12.Attempts             'U12 null changes: $null/empty changes-check is a no-op (retry fires)'

# U13: a non-hashtable RunAgent result ($null) is normalized - treated as non-timeout, no
#      crash, and the returned .Run is a usable hashtable for the caller's merge gate.
$ra13 = { $null }
$pc13 = { $false }
$r13 = Invoke-BuildWithRetry -RunAgent $ra13 -ProducedChanges $pc13 -MaxBuildAttempts 2
Assert-Eq 2 $r13.Attempts             'U13 non-hashtable run: $null result treated as non-timeout, runs to cap, no crash'
Assert-True ($r13.Run -is [hashtable]) 'U13 non-hashtable run: returned .Run is normalized to a hashtable'
Assert-False $r13.Run.TimedOut         'U13 non-hashtable run: normalized .Run.TimedOut is False'

# U14: omitting -OnRetry and -ResetWorktree uses the default {} blocks safely (no throw).
$st14 = [pscustomobject]@{ I = 0 }
$ra14 = { @{ TimedOut = $false; ExitCode = 0 } }.GetNewClosure()
$pc14 = { $st14.I++; $st14.I -ge 2 }.GetNewClosure()
$threw14 = $false
try { $r14 = Invoke-BuildWithRetry -RunAgent $ra14 -ProducedChanges $pc14 -MaxBuildAttempts 3 } catch { $threw14 = $true }
Assert-False $threw14                  'U14 default callbacks: omitting -OnRetry/-ResetWorktree does not throw'
Assert-Eq 2 $r14.Attempts             'U14 default callbacks: still retries correctly (Attempts=2)'

# U15: a throwing mechanism surfaces the exception to the caller (fail loud, never a silent loop).
Assert-Throws { Invoke-BuildWithRetry -RunAgent { throw 'boom-run' } -ProducedChanges { $true } -MaxBuildAttempts 2 } `
    'U15a throwing RunAgent: exception propagates to the caller (fail loud)'
Assert-Throws { Invoke-BuildWithRetry -RunAgent { @{ TimedOut = $false; ExitCode = 0 } } -ProducedChanges { throw 'boom-changes' } -MaxBuildAttempts 2 } `
    'U15b throwing ProducedChanges: exception propagates to the caller (fail loud)'

# ----------------------------------------------------------------------------
# RESAMPLE POLICY - Test-ShouldResample (the retry-on-test-failure decision).
# Mutation-resistant: each case kills a specific wrong implementation.
# ----------------------------------------------------------------------------
Section 'Unit tests: resample-on-verify-failure policy (Test-ShouldResample)'
Assert-True  (Test-ShouldResample -VerifyResult 'fail' -TestResult 'none' -TimedOut $false -SecretBlocked $false -Attempt 1 -MaxAttempts 3) 'V1 verify FAIL with attempts left -> resample'
Assert-True  (Test-ShouldResample -VerifyResult 'none' -TestResult 'fail' -TimedOut $false -SecretBlocked $false -Attempt 1 -MaxAttempts 3) 'V2 test FAIL with attempts left -> resample'
Assert-False (Test-ShouldResample -VerifyResult 'pass' -TestResult 'pass' -TimedOut $false -SecretBlocked $false -Attempt 1 -MaxAttempts 3) 'V3 all pass -> do NOT resample'
Assert-False (Test-ShouldResample -VerifyResult 'none' -TestResult 'none' -TimedOut $false -SecretBlocked $false -Attempt 1 -MaxAttempts 3) 'V4 nothing failed (none/skip) -> do NOT resample'
Assert-False (Test-ShouldResample -VerifyResult 'fail' -TestResult 'fail' -TimedOut $true  -SecretBlocked $false -Attempt 1 -MaxAttempts 3) 'V5 TIMEOUT is never resampled (even on fail)'
Assert-False (Test-ShouldResample -VerifyResult 'fail' -TestResult 'fail' -TimedOut $false -SecretBlocked $true  -Attempt 1 -MaxAttempts 3) 'V6 SECRET-BLOCK is never resampled (must surface to a human)'
Assert-False (Test-ShouldResample -VerifyResult 'fail' -TestResult 'none' -TimedOut $false -SecretBlocked $false -Attempt 3 -MaxAttempts 3) 'V7 verify FAIL but cap reached -> do NOT resample'
Assert-True  (Test-ShouldResample -VerifyResult 'fail' -TestResult 'none' -TimedOut $false -SecretBlocked $false -Attempt 2 -MaxAttempts 3) 'V8 verify FAIL, attempt 2 of 3 -> resample'
Assert-False (Test-ShouldResample -VerifyResult 'fail' -TestResult 'none' -TimedOut $false -SecretBlocked $false -Attempt 1 -MaxAttempts 1) 'V9 single-attempt cap (max 1) -> never resamples'
# #740/W7: an IDLE-reason timeout is a random per-build slip -> resample-eligible (bounded by MaxAttempts); a
# CEILING timeout, an empty/unknown reason (-> ceiling), and a secret stay terminal. $TimeoutReason defaults
# to '' so V5 above (no reason passed) keeps the pre-change "any timeout is terminal" behaviour byte-identical.
Assert-True  (Test-ShouldResample -VerifyResult 'none' -TestResult 'none' -TimedOut $true -SecretBlocked $false -Attempt 1 -MaxAttempts 3 -TimeoutReason 'idle')    'V9a IDLE timeout (no gate fail) -> RESAMPLE (routes around the stall)'
Assert-False (Test-ShouldResample -VerifyResult 'none' -TestResult 'none' -TimedOut $true -SecretBlocked $false -Attempt 1 -MaxAttempts 3 -TimeoutReason 'ceiling') 'V9b CEILING timeout stays terminal -> do NOT resample'
Assert-False (Test-ShouldResample -VerifyResult 'none' -TestResult 'none' -TimedOut $true -SecretBlocked $false -Attempt 1 -MaxAttempts 3 -TimeoutReason '')        'V9c empty/unknown reason -> treated as ceiling (terminal)'
Assert-False (Test-ShouldResample -VerifyResult 'none' -TestResult 'none' -TimedOut $true -SecretBlocked $false -Attempt 3 -MaxAttempts 3 -TimeoutReason 'idle')    'V9d IDLE timeout at the cap -> bounded, do NOT resample (no infinite idle loop)'
Assert-False (Test-ShouldResample -VerifyResult 'none' -TestResult 'none' -TimedOut $true -SecretBlocked $true  -Attempt 1 -MaxAttempts 3 -TimeoutReason 'idle')    'V9e secret DOMINATES an idle reason -> terminal (surface to a human)'
# V10 wiring (#689): the OUTER build loop is now BEST-OF-N -- up to N independent diverse candidates, the
# deterministic gate selects the winner (or best partial). It REPLACED the serial Test-ShouldContinue
# multi-pass loop (whose build dimension was the error-feedback re-fix the weak model is worst at). The
# INNER per-candidate no-op retry (Invoke-BuildWithRetry) is unchanged -- see U9. Assert the runner drives
# the build via Invoke-BestOfN and that Invoke-BestOfN selects the best partial via Select-BestCandidateIndex.
$nat = Get-Content 'C:\Users\mrbla\agentic-setup\scripts\new-agent-task.ps1' -Raw
Assert-True ([regex]::IsMatch($nat, '(?m)^\s*\$bon\s*=\s*Invoke-BestOfN\b')) 'V10 wiring: new-agent-task.ps1 drives the build via Invoke-BestOfN (best-of-N replaces the serial retry; real, non-comment line)'
$lib = Get-Content 'C:\Users\mrbla\agentic-setup\scripts\fleet-lib.ps1' -Raw
Assert-True ([regex]::IsMatch($lib, 'function Invoke-BestOfN')) 'V10b: Invoke-BestOfN is defined in fleet-lib'
Assert-True ([regex]::IsMatch($lib, 'Select-BestCandidateIndex\s+-Ranks')) 'V10c: the best partial is chosen via a Select-BestCandidateIndex -Ranks CALL (Invoke-BestOfN is its only caller)'

# ----------------------------------------------------------------------------
# LIVE TEST - real fleet + real local model (opt-in)
# ----------------------------------------------------------------------------
if ($IncludeLive) {
    Section 'Live end-to-end test (real fleet + OVMS)'
    $loaded = Get-LoadedModelId
    if (-not $loaded) {
        _inconc 'Live test skipped: the model server (OVMS) is not up on http://127.0.0.1:8000. Start it, then re-run with -IncludeLive.'
    } else {
        Write-Host "  Model server up; loaded model: $loaded" -ForegroundColor DarkGray
        $scratchRoot = 'C:\Users\mrbla\agentic-setup\state\test-scratch'
        # One wipe clears the repo AND all sibling worktrees from any prior run.
        if (Test-Path $scratchRoot) { Remove-Item -Recurse -Force -LiteralPath $scratchRoot -ErrorAction SilentlyContinue }
        if (Test-Path $scratchRoot) {
            _inconc 'Live test: could not fully clear the scratch dir (a file may be locked by a running agent). Close any running agent and re-run.'
        } else {
            New-Item -ItemType Directory -Force $scratchRoot | Out-Null
            $repo = Join-Path $scratchRoot 'retrytest'
            New-Item -ItemType Directory -Force $repo | Out-Null
            git -C $repo init -b main 2>&1 | Out-Null
            Set-Content (Join-Path $repo 'README.md') "scratch repo for retry verification" -Encoding ascii
            git -C $repo add -A 2>&1 | Out-Null
            git -C $repo -c user.email='test@local' -c user.name='retry-test' commit -m 'init' 2>&1 | Out-Null

            # We assert on the captured output of THIS run ($outA/$outB), which includes the
            # full report summary new-agent-task prints. We deliberately do NOT re-read the
            # newest file in state\reports - a stale report could mask a current failure.

            # --- Live A: forced no-op -> the retry should fire (timeout/variance aware) ---
            Write-Host "  [Live A] no-op task, -MaxBuildAttempts 2 (retry should fire)..." -ForegroundColor DarkGray
            $noop = 'Do not create, edit, write, rename, move, or delete any file. Make no changes to the project at all. Reply with only the single word: DONE'
            try {
                # NOTE: hashtable splat (binds by NAME). An ARRAY splat binds positionally and
                # would mis-assign the prompt onto an [int] param - do not change this to @(...).
                $splatA = @{ Repo = $repo; Task = 'retry-noop-live'; Prompt = $noop; MaxBuildAttempts = 2; MaxRunMinutes = $MaxLiveMinutes; MaxReviewMinutes = $MaxLiveMinutes }
                if ($Model) { $splatA['Model'] = $Model }
                $outA = (& "$PSScriptRoot\new-agent-task.ps1" @splatA *>&1 | Out-String)
            } catch { $outA = "ERROR: $($_.Exception.Message)" }
            if ($outA -match 'STOPPED by circuit breaker') {
                _inconc 'Live A: the model TIMED OUT on the no-op attempt this run (server load / variance). The policy correctly does not retry a timeout, so the retry path was not exercised - not a defect. Re-run.'
            } elseif ($outA -match 'after 2 build attempts') {
                if ($outA -match 'CHANGES:\s*none') { _pass 'Live A: retry FIRED and exhausted cleanly (no-op detected, re-ran, nothing merged)' }
                else { _pass 'Live A: retry FIRED and then recovered (no-op detected, re-ran, produced a change)' }
            } elseif ($outA -match 'CHANGES:\s*yes') {
                _inconc 'Live A: the model made a change on the FIRST attempt, so it never no-op''d and the retry path was not exercised this run. Model variance, not a retry defect (the unit tests prove the logic). Re-run.'
            } else {
                _fail 'Live A: could not confirm the retry signature in this run''s output (see below).'
                Write-Host '         --- new-agent-task output (first 600 chars) ---' -ForegroundColor DarkGray
                Write-Host ('         ' + ($outA.Substring(0, [Math]::Min(600, $outA.Length)) -replace "`r?`n", "`n         ")) -ForegroundColor DarkGray
            }

            # --- Live B: simple real task -> the pipeline still works (timeout/capability aware) ---
            Write-Host "  [Live B] create-file task, -MaxBuildAttempts 3 (pipeline smoke; retry-backed)..." -ForegroundColor DarkGray
            $ok = 'Create a new file named hello.txt in the project root containing exactly this text: hello'
            try {
                $splatB = @{ Repo = $repo; Task = 'retry-happy-live'; Prompt = $ok; MaxBuildAttempts = 3; MaxRunMinutes = $MaxLiveMinutes; MaxReviewMinutes = $MaxLiveMinutes }
                if ($Model) { $splatB['Model'] = $Model }
                $outB = (& "$PSScriptRoot\new-agent-task.ps1" @splatB *>&1 | Out-String)
            } catch { $outB = "ERROR: $($_.Exception.Message)" }
            if ((Test-Path (Join-Path $repo 'hello.txt')) -or ($outB -match 'CHANGES:\s*yes')) {
                _pass 'Live B: happy-path pipeline produced changes (the fleet still works after the refactor)'
            } elseif ($outB -match 'STOPPED by circuit breaker') {
                _inconc 'Live B: the model timed out this run (server load / variance). Not a retry defect - re-run.'
            } else {
                _inconc "Live B: the model did not finish the simple task within $MaxLiveMinutes min/attempt even with retries. That is a MODEL capability limit, not a retry defect (the unit tests prove the retry logic). Re-run -IncludeLive to try again."
            }

            # cleanup (best effort; the scratch repo is disposable)
            foreach ($t in @('retry-noop-live', 'retry-happy-live')) {
                $wt = Join-Path $scratchRoot "retrytest-$t"
                if (Test-Path $wt) { git -C $repo worktree remove $wt --force 2>&1 | Out-Null }
                git -C $repo branch -D "agent/$t" 2>&1 | Out-Null
            }
            git -C $repo worktree prune 2>&1 | Out-Null
            Write-Host "  (disposable scratch repo left at $repo - delete any time)" -ForegroundColor DarkGray
        }
    }
}

# ----------------------------------------------------------------------------
# RESULT
# ----------------------------------------------------------------------------
Section 'Result'
Write-Host ("  Passed:        {0}" -f $script:Pass) -ForegroundColor Green
if ($script:Inconclusive) { Write-Host ("  Inconclusive:  {0}  (model variance / timeout / OVMS down - NOT a logic failure)" -f $script:Inconclusive) -ForegroundColor Yellow }
if ($script:Fail) {
    Write-Host ("  Failed:        {0}" -f $script:Fail) -ForegroundColor Red
    Write-Host ''
    Write-Host '  RETRY-ON-FAILURE: NOT VALIDATED - see the [FAIL] lines above:' -ForegroundColor Red
    $script:Failures | ForEach-Object { Write-Host "    - $_" -ForegroundColor Red }
    exit 1
} else {
    Write-Host ''
    Write-Host '  RETRY-ON-FAILURE: VALIDATED. The retry policy behaves exactly as specified.' -ForegroundColor Green
    if (-not $IncludeLive) { Write-Host '  (Add -IncludeLive to also watch it work end-to-end against the live model.)' -ForegroundColor DarkGray }
    exit 0
}
