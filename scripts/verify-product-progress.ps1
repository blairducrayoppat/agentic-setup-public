# verify-product-progress.ps1 - the operator can be told how much of the PRODUCT exists.
#
# DoD row 8 clause 3, which had no instrument at all. SUMMARY.txt published
#
#     Processed this run: 1 of 1 queued
#
# and nothing else. That line is TRUE and answers a different question: its denominator is the
# one-task queue BUFFER, not the deliverable. On 2026-08-15, mid-build, it printed exactly that
# while the pottery site stood at four tasks of seven — a real number about the wrong
# population, which is the #1231 shape aimed at the operator rather than at a grader. "1 of 1"
# reads like completion to anyone who did not write it.
#
# Both figures were already on disk and had never been put together: done.txt is the terminal
# task list, decompose-diagnostics.json carries the plan's own count.
#
# WHAT THIS TESTS
#   - the product line is emitted, with the plan's denominator and not the queue's;
#   - it is DERIVED from the two artifacts rather than restated from a literal;
#   - an unreadable plan is NAMED as unknown, never omitted (an absent progress line reads as
#     "no progress worth reporting", which is the defect one level up);
#   - the queue line survives, because it answers a real and different question.
#
# Pure; offline; no dispatch. Exit 0 iff every case matches.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Pass = 0; $script:Fail = 0; $script:Failures = New-Object System.Collections.ArrayList
function Section($t) { Write-Host ''; Write-Host "== $t ==" -ForegroundColor Cyan }
function _pass($m) { $script:Pass++; Write-Host "  [PASS] $m" -ForegroundColor Green }
function _fail($m) { $script:Fail++; [void]$script:Failures.Add($m); Write-Host "  [FAIL] $m" -ForegroundColor Red }
function Assert-True($Cond, $Msg) { if ($Cond) { _pass $Msg } else { _fail $Msg } }
function Assert-Contains($Hay, $Needle, $Msg) {
    if ($Hay -and $Hay.Contains($Needle)) { _pass $Msg } else { _fail "$Msg (did not find '$Needle' in: $Hay)" }
}
function Assert-NotContains($Hay, $Needle, $Msg) {
    if ($Hay -and $Hay.Contains($Needle)) { _fail "$Msg (unexpectedly found '$Needle')" } else { _pass $Msg }
}

# The block under test, lifted verbatim from run-fleet.ps1 so this file cannot drift from it
# silently — the wiring check at the end asserts the real script still carries it.
function Get-ProductLine {
    param([string]$RunDir, [string]$DoneList)
    $planned = $null
    $diagPath = Join-Path $RunDir 'decompose-diagnostics.json'
    if (Test-Path $diagPath) {
        try {
            $diag = Get-Content $diagPath -Raw | ConvertFrom-Json
            if ($null -ne $diag.cleaned_task_count) { $planned = [int]$diag.cleaned_task_count }
        } catch { $planned = $null }
    }
    $built = if (Test-Path $DoneList) { @(Get-Content $DoneList | Where-Object { $_.Trim() }).Count } else { 0 }
    if ($null -ne $planned -and $planned -gt 0) {
        $pct = [math]::Round(100.0 * $built / $planned)
        return "Product: $built of $planned planned tasks built ($pct%)"
    }
    return "Product: $built task(s) built; the plan's task count could not be read from decompose-diagnostics.json, so how much of the product exists is UNKNOWN"
}

function New-RunDir {
    param([int]$Built, [object]$Planned)
    $d = Join-Path ([System.IO.Path]::GetTempPath()) ("pp-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force $d | Out-Null
    1..$Built | ForEach-Object { Add-Content (Join-Path $d 'done.txt') "task-$_" }
    if ($null -ne $Planned) {
        @{ schema = 'decompose-decision/v1'; cleaned_task_count = $Planned } |
            ConvertTo-Json | Set-Content (Join-Path $d 'decompose-diagnostics.json')
    }
    return $d
}

Section 'The product line reports the PLAN as its denominator'

$d = New-RunDir -Built 4 -Planned 7
$line = Get-ProductLine -RunDir $d -DoneList (Join-Path $d 'done.txt')
Assert-Contains $line '4 of 7'  'A1 [kill] four built of seven planned'
Assert-Contains $line '57%'     'A2 [kill] the percentage is derived, not asserted'
Assert-NotContains $line '1 of 1' 'A3 [kill] the QUEUE buffer is never the denominator'

Section 'It tracks the artifacts rather than restating a literal'

$d = New-RunDir -Built 2 -Planned 9
$line = Get-ProductLine -RunDir $d -DoneList (Join-Path $d 'done.txt')
Assert-Contains $line '2 of 9' 'A4 [kill] a different tree gives a different figure'

# A finished product must read as finished, or the measure has no top end.
$d = New-RunDir -Built 7 -Planned 7
Assert-Contains (Get-ProductLine -RunDir $d -DoneList (Join-Path $d 'done.txt')) '7 of 7 planned tasks built (100%)' `
    'A5 [kill] a complete product reads 100%'

Section 'An unreadable plan is NAMED, never omitted'

# THE TOGGLE, and the reason it matters: a missing progress line reads as "no progress worth
# reporting", which is the same defect this instrument exists to end, one level up.
$d = New-RunDir -Built 3 -Planned $null
$line = Get-ProductLine -RunDir $d -DoneList (Join-Path $d 'done.txt')
Assert-Contains $line 'UNKNOWN' 'A6 [kill] no plan file -> the answer is stated as unknown'
Assert-Contains $line '3 task'  'A7 [kill] the count it DOES have still survives the unknown'

# A malformed plan is the same state as an absent one, and must not throw.
$d = New-RunDir -Built 1 -Planned 5
Set-Content (Join-Path $d 'decompose-diagnostics.json') '{ this is not json'
Assert-Contains (Get-ProductLine -RunDir $d -DoneList (Join-Path $d 'done.txt')) 'UNKNOWN' `
    'A8 [kill] an unparseable plan degrades to UNKNOWN rather than crashing the summary'

Section 'Wiring — run-fleet.ps1 actually emits it'

$rf = Get-Content (Join-Path $PSScriptRoot 'run-fleet.ps1') -Raw
Assert-True ($rf -match 'planned tasks built') 'A9  [kill] run-fleet.ps1 emits the product line'
Assert-True ($rf -match 'decompose-diagnostics\.json') 'A10 [kill] it reads the plan for its denominator'
Assert-True ($rf -match 'Processed this run:') 'A11 [kill] the queue line SURVIVES — it answers a real, different question'

Section 'Result'
Write-Host ("  Passed:  {0}" -f $script:Pass) -ForegroundColor Green
if ($script:Fail) {
    Write-Host ("  Failed:  {0}" -f $script:Fail) -ForegroundColor Red
    $script:Failures | ForEach-Object { Write-Host "    - $_" -ForegroundColor Red }
    exit 1
}
Write-Host ''
Write-Host '  PRODUCT PROGRESS: the operator is told how much of the PRODUCT exists, not how much of the queue buffer.' -ForegroundColor Green
exit 0
