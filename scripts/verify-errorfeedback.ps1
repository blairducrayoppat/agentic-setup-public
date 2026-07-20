#requires -Version 5.1
<#
.SYNOPSIS
  Verify and validate the fleet's ERROR-FEEDBACK capability.

.DESCRIPTION
  Background (plain English):
    When a build attempt FAILS the verify gate (it compiled-error'd), the old behaviour
    was to throw the work away and re-run the coder from a CLEAN worktree on the SAME
    prompt - a "blind resample". That converges a RANDOM slip, but it cannot fix a
    SYSTEMATIC bug: the model just repeats it. (Observed live: the 30B kept writing a
    WinUI event handler taking `RoutedEventArgs` but omitting `using Microsoft.UI.Xaml;`,
    so every resample failed CS0246 the same way and the task parked after burning the
    whole attempt budget.)

    Error-feedback ORIGINALLY fixed that: on a verify FAIL the runner KEPT the failing code and
    handed the coder the EXACT build error with an instruction to fix it. #689 (best-of-N) RETIRED
    that serial self-correction re-fix -- the weak local model is worst at self-correcting (it
    enters error traps and stays stuck), so the runner now resamples N fresh INDEPENDENT candidates
    and the deterministic gate selects. What REMAINS is the capture piece in fleet-lib.ps1, unit-
    tested without a model:
      - Format-VerifyError : pull the failing checks' captured output into one string (still used
        for the report/diagnostics AND fed to the best-of-N candidate pipeline).
    (The prompt-augmentation piece, Add-BuildErrorFeedback, retired with the re-fix and was removed
    in #696; its unit tests went with it.)

  This script proves the behaviour deterministically (no model / no OVMS needed, ~1s):
    UNIT TESTS drive the REAL Format-VerifyError with scripted inputs and assert it extracts +
    formats EXACTLY as specified - including the empty/none cases. WIRING tests regex-assert that
    the runner captures the verify error via Format-VerifyError AND drives best-of-N fresh
    resampling on a build failure (a substring match would pass on the explanatory comment alone).
    The suite is built to be mutation-resistant: each [MUTATION-KILL] case fails a specific wrong impl.

  Exit code is 0 if everything passed, 1 if any check failed.
  Run it normally ( .\verify-errorfeedback.ps1 ) - do NOT dot-source it.
#>
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\fleet-lib.ps1"

# ----------------------------------------------------------------------------
# Tiny zero-dependency test framework (no Pester - works offline forever)
# ----------------------------------------------------------------------------
$script:Pass = 0
$script:Fail = 0
$script:Failures = New-Object System.Collections.ArrayList
function Section($t) { Write-Host ''; Write-Host "== $t ==" -ForegroundColor Cyan }
function _pass($m)   { $script:Pass++; Write-Host "  [PASS] $m" -ForegroundColor Green }
function _fail($m)   { $script:Fail++; [void]$script:Failures.Add($m); Write-Host "  [FAIL] $m" -ForegroundColor Red }
# Case-SENSITIVE exact match (so 'True' vs 'true' would be caught).
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
function Assert-NotContains($Haystack, $Needle, $Msg) {
    if (-not ($Haystack -and $Haystack.ToString().Contains($Needle))) { _pass $Msg }
    else { _fail "$Msg (unexpectedly found '$Needle')" }
}

# Fake verify check (shape matches verify-project.ps1 -Json output: name/status/seconds/detail).
function New-Check($name, $status, $detail) { [pscustomobject]@{ name = $name; status = $status; seconds = 1; detail = $detail } }

# ----------------------------------------------------------------------------
# UNIT TESTS: Format-VerifyError - extract the FAILING checks' build output
# ----------------------------------------------------------------------------
Section 'Unit tests: Format-VerifyError'

# F1: a single failing check -> "[name]\n<detail>".
$f1 = Format-VerifyError -Checks @(New-Check 'dotnet:build' 'fail' 'error CS0246: RoutedEventArgs could not be found')
Assert-Contains $f1 'RoutedEventArgs' 'F1 single fail: includes the build error detail'
Assert-Contains $f1 '[dotnet:build]'  'F1 single fail: labels the check name'

# F2: multiple failing checks -> both details present.
$f2 = Format-VerifyError -Checks @((New-Check 'dotnet:build' 'fail' 'BUILD-ERR-A'), (New-Check 'lint' 'fail' 'LINT-ERR-B'))
Assert-Contains $f2 'BUILD-ERR-A' 'F2 multi fail: includes the first failing check'
Assert-Contains $f2 'LINT-ERR-B'  'F2 multi fail: includes the second failing check'

# F3: NOTHING failed (pass/skip) -> '' so the caller falls back to a fresh resample.
$f3 = Format-VerifyError -Checks @((New-Check 'dotnet:build' 'pass' 'all good'), (New-Check 'lint' 'skip' 'no linter'))
Assert-Eq '' $f3 'F3 no failures: returns empty string (caller will resample fresh)'

# F4 [MUTATION-KILL]: a PASS check is EXCLUDED; only the FAIL detail survives. Fails any
#     mutation that filters on the wrong status (-ne 'fail', -eq 'pass', or no filter at all).
$f4 = Format-VerifyError -Checks @((New-Check 'dotnet:build' 'fail' 'REAL-FAILURE-TEXT'), (New-Check 'tests' 'pass' 'PASSING-CHECK-TEXT'))
Assert-Contains    $f4 'REAL-FAILURE-TEXT'  'F4 mixed: the FAILING check detail is included'
Assert-NotContains $f4 'PASSING-CHECK-TEXT' 'F4 mixed: a PASSING check is NOT included (filter is status -eq fail)'

# F5: defensive - empty/null list and a missing .detail never throw.
Assert-Eq '' (Format-VerifyError -Checks @())   'F5a empty list: returns empty string, no throw'
Assert-Eq '' (Format-VerifyError -Checks $null) 'F5b null list: returns empty string, no throw'
$f5c = Format-VerifyError -Checks @(New-Check 'dotnet:build' 'fail' $null)
Assert-Contains $f5c '[dotnet:build]' 'F5c null detail: still labels the check, no throw'

# ----------------------------------------------------------------------------
# WIRING: on a build failure the runner drives best-of-N fresh resampling (#689);
# Format-VerifyError still CAPTURES the failing checks' output for the report + the
# best-of-N candidate pipeline. (The prompt-augmentation re-fix, Add-BuildErrorFeedback,
# was retired + removed in #696 -- there is no augmented-prompt wiring to assert anymore.)
# ----------------------------------------------------------------------------
Section 'Wiring: build failures are handled by best-of-N fresh resampling (#689 -- error-feedback retired)'
$nat = Get-Content "$PSScriptRoot\new-agent-task.ps1" -Raw
# #689: the serial error-feedback re-fix (Add-BuildErrorFeedback) is RETIRED from the runner -- it asked the
# weak model to SELF-CORRECT (its worst skill; it enters error traps and stays stuck). The runner now takes
# up to N INDEPENDENT, diverse candidates and lets the deterministic gate SELECT (best-of-N). Format-VerifyError
# REMAINS (it captures the verify error for the report + the best-of-N candidate pipeline; unit-tested above);
# the dormant Add-BuildErrorFeedback augmentation function + its unit tests were REMOVED in #696 (#689 follow-up).
$lib = Get-Content "$PSScriptRoot\fleet-lib.ps1" -Raw   # #700: the per-candidate gate body moved to Invoke-CandidateBuild
Assert-True ([regex]::IsMatch($lib, 'Format-VerifyError\s+-Checks\s+\$vobj\.checks')) `
    'W1 wiring: the candidate pipeline (Invoke-CandidateBuild) CAPTURES the verify error via Format-VerifyError'
Assert-True ([regex]::IsMatch($nat, '(?m)^\s*\$bon\s*=\s*Invoke-BestOfN\b')) `
    'W2 wiring: a build failure is handled by best-of-N (Invoke-BestOfN) -- N independent candidates, the gate selects -- NOT a serial error-feedback re-fix'
Assert-True ([regex]::IsMatch($nat, 'Add-CandidateDiversity\s+-Prompt\s+\$Prompt')) `
    'W3 wiring: each fresh candidate gets a DECORRELATED prompt via Add-CandidateDiversity (independent samples, not a re-fix of the last attempt)'
Assert-True ([regex]::IsMatch($lib, 'reset --hard \$CodeBase')) `
    'W4 wiring: a fresh candidate (k>1) starts from a CLEAN seeded baseline (reset --hard $codeBase)'

# ----------------------------------------------------------------------------
# RESULT
# ----------------------------------------------------------------------------
Section 'Result'
Write-Host ("  Passed:  {0}" -f $script:Pass) -ForegroundColor Green
if ($script:Fail) {
    Write-Host ("  Failed:  {0}" -f $script:Fail) -ForegroundColor Red
    Write-Host ''
    Write-Host '  ERROR-FEEDBACK: NOT VALIDATED - see the [FAIL] lines above:' -ForegroundColor Red
    $script:Failures | ForEach-Object { Write-Host "    - $_" -ForegroundColor Red }
    exit 1
} else {
    Write-Host ''
    Write-Host '  ERROR-FEEDBACK capture VALIDATED (Format-VerifyError) + best-of-N replacement WIRED (#689): on a verify fail the runner takes fresh INDEPENDENT candidates and the gate selects (the Add-BuildErrorFeedback augmentation was retired + removed, #696).' -ForegroundColor Green
    exit 0
}
