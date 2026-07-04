# verify-mutationgate.ps1 - self-test for the py:mutation soft-signal gate and
# the ConvertFrom-MutmutOutput / Get-MutationSignalNote pure helpers (#687 task 3).
#
# WHAT THIS TESTS:
#   - ConvertFrom-MutmutOutput: parses several mutmut output formats correctly.
#   - Get-MutationSignalNote:   produces a human-readable soft-signal note, NEVER
#     containing a hard-fail cue, always including the soft-signal disclaimer.
#   - Soft-signal invariant:    surviving mutants produce status='pass', not 'fail'.
#   - Wiring:                   verify-project.ps1 and new-agent-task.ps1 are wired
#     correctly (hypothesis added; mutation check present; never hard-fails).
#
# Mutation-resistant: each [kill] case fails a specific wrong implementation.
# Pure; offline; no mutmut process. Exit 0 iff every case matches.
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\fleet-lib.ps1"

$script:Pass = 0; $script:Fail = 0
$script:Failures = New-Object System.Collections.ArrayList
function Section($t) { Write-Host ''; Write-Host "== $t ==" -ForegroundColor Cyan }
function _pass($m) { $script:Pass++; Write-Host "  [PASS] $m" -ForegroundColor Green }
function _fail($m) { $script:Fail++; [void]$script:Failures.Add($m); Write-Host "  [FAIL] $m" -ForegroundColor Red }
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
function Assert-Contains($H, $N, $Msg) {
    if ($H -and $H.ToString().Contains($N)) { _pass $Msg }
    else { _fail "$Msg (did not find '$N' in: $H)" }
}
function Assert-NotContains($H, $N, $Msg) {
    if (-not ($H -and $H.ToString().Contains($N))) { _pass $Msg }
    else { _fail "$Msg (unexpectedly found '$N' in: $H)" }
}

# ===========================================================================
Section 'ConvertFrom-MutmutOutput -- parsing'

# P1-P3: empty output -> zeros, not timed-out -> Sampled=false
$r = ConvertFrom-MutmutOutput -Output '' -TimedOut $false
Assert-Eq 0      $r.Survived 'P1 [kill] empty output -> Survived=0'
Assert-Eq 0      $r.Total    'P2 [kill] empty output -> Total=0'
Assert-False $r.Sampled      'P3 [kill] TimedOut=false -> Sampled=false'

# P4: TimedOut propagates to Sampled
$r = ConvertFrom-MutmutOutput -Output '' -TimedOut $true
Assert-True $r.Sampled 'P4 [kill] TimedOut=true -> Sampled=true'

# P5: "bad_survived: N" format (mutmut results output)
$r = ConvertFrom-MutmutOutput -Output "bad_survived: 3`nok_killed: 7" -TimedOut $false
Assert-Eq 3 $r.Survived 'P5 [kill] bad_survived:3 -> Survived=3'

# P6-P7: "N survived of M" format
$r = ConvertFrom-MutmutOutput -Output '2 survived of 5 mutants' -TimedOut $false
Assert-Eq 2 $r.Survived 'P6 [kill] "2 survived of 5" -> Survived=2'
Assert-Eq 5 $r.Total    'P7 [kill] "2 survived of 5" -> Total=5'

# P8: "N/M" progress-bar format -> Total extracted
$r = ConvertFrom-MutmutOutput -Output 'Running 10/20 ...' -TimedOut $false
Assert-Eq 20 $r.Total 'P8 [kill] "10/20" -> Total=20'

# P9-P10: "Killed: N of M" -> survived = total - killed
$r = ConvertFrom-MutmutOutput -Output "Killed: 8 of 10" -TimedOut $false
Assert-Eq 10 $r.Total    'P9  [kill] "Killed: 8 of 10" -> Total=10'
Assert-Eq 2  $r.Survived 'P10 [kill] "Killed: 8 of 10" -> Survived=2 (10-8)'

# P11: "Survived: N" explicit label
$r = ConvertFrom-MutmutOutput -Output "Survived: 4`nTotal: 9" -TimedOut $false
Assert-Eq 4 $r.Survived 'P11 [kill] "Survived: 4" label -> Survived=4'

# P12: graceful on unrecognized input - no parse error, returns zeros
$r = ConvertFrom-MutmutOutput -Output 'no relevant text here, just noise' -TimedOut $false
Assert-Eq 0 $r.Survived 'P12 [kill] nonsense input -> Survived=0 (no parse error)'
Assert-Eq 0 $r.Total    'P12b nonsense input -> Total=0'

# ===========================================================================
Section 'Get-MutationSignalNote -- soft-signal notes'

# N1: always non-empty
$n = Get-MutationSignalNote -Survived 0 -Total 0
Assert-True ($n.Length -gt 0) 'N1 [kill] always returns non-empty string'

# N2: zero total -> "no mutants measured" phrase
$n = Get-MutationSignalNote -Survived 0 -Total 0
Assert-Contains    $n 'no mutants' 'N2 [kill] Total=0 -> note mentions "no mutants"'

# N3: all killed - contains total, does NOT mention surviving count
$n = Get-MutationSignalNote -Survived 0 -Total 5
Assert-Contains    $n '5'        'N3 [kill] all killed -> contains total count'
Assert-NotContains $n 'survived' 'N4 [kill] all killed -> does NOT say "survived"'

# N5-N7: surviving mutants -> note includes both counts and soft-signal disclaimer
$n = Get-MutationSignalNote -Survived 3 -Total 7
Assert-Contains $n '3'           'N5 [kill] 3 survived -> note contains 3'
Assert-Contains $n '7'           'N6 [kill] 3 of 7 -> note contains 7'
Assert-Contains $n 'soft signal' 'N7 [kill] surviving mutants -> includes "soft signal" disclaimer'

# N8: time-boxed partial run -> note says "time-boxed"
$n = Get-MutationSignalNote -Survived 1 -Total 3 -TimedOut $true
Assert-Contains $n 'time-boxed' 'N8 [kill] TimedOut=true -> note says "time-boxed"'

# N9: not time-boxed -> note does NOT say "time-boxed"
$n = Get-MutationSignalNote -Survived 0 -Total 4 -TimedOut $false
Assert-NotContains $n 'time-boxed' 'N9 [kill] TimedOut=false -> note does NOT say "time-boxed"'

# ===========================================================================
Section 'Soft-signal invariant: surviving mutants never produce a hard-fail cue'

# The gate contract: the note is used with status='pass', not 'fail'. The note itself
# must not accidentally sound like a hard failure (no "FAIL", no "ERROR", no "blocked").
$n1 = Get-MutationSignalNote -Survived 0  -Total 0
$n2 = Get-MutationSignalNote -Survived 5  -Total 5
$n3 = Get-MutationSignalNote -Survived 0  -Total 10
$n4 = Get-MutationSignalNote -Survived 10 -Total 10

Assert-NotContains $n1 'FAIL'    'S1 [kill] 0/0 -> note does not contain "FAIL"'
Assert-NotContains $n2 'FAIL'    'S2 [kill] all survived -> note does not contain "FAIL"'
Assert-NotContains $n3 'FAIL'    'S3 [kill] 0/10 survived -> note does not contain "FAIL"'
Assert-NotContains $n4 'FAIL'    'S4 [kill] 10/10 survived -> note does not contain "FAIL"'
Assert-NotContains $n4 'blocked' 'S5 [kill] note does not say "blocked" (only a signal, not a block)'

# Surviving mutants still produce a non-null, informative note (not silence)
Assert-True ($n4.Length -gt 10) 'S6 [kill] 10/10 survived -> note is non-trivial (informative)'

# ===========================================================================
Section 'Wiring: verify-project.ps1 and new-agent-task.ps1'

$vp  = Get-Content "$PSScriptRoot\verify-project.ps1" -Raw
$nat = Get-Content "$PSScriptRoot\new-agent-task.ps1" -Raw

# W1: py:mutation check exists in verify-project.ps1
Assert-True ([regex]::IsMatch($vp, "'py:mutation'")) `
    'W1 [kill] verify-project.ps1 contains py:mutation check'

# W2: py:mutation uses Add-Result with 'pass' status (the soft-signal contract)
Assert-True ([regex]::IsMatch($vp, "Add-Result 'py:mutation' 'pass'")) `
    'W2 [kill] py:mutation Add-Result uses pass status (soft signal)'

# W3: py:mutation NEVER hard-fails (no Add-Result 'py:mutation' 'fail' anywhere)
Assert-False ([regex]::IsMatch($vp, "Add-Result 'py:mutation' 'fail'")) `
    'W3 [kill] py:mutation does NOT use fail status (surviving mutants are a soft signal)'

# W4: --with hypothesis in verify-project.ps1 (PBT for the gate)
Assert-True ([regex]::IsMatch($vp, '--with hypothesis')) `
    'W4 [kill] verify-project.ps1 includes --with hypothesis for PBT'

# W5: --with hypothesis in the [2/5] pytest step. #700 moved the per-candidate pipeline out of new-agent-task
# into fleet-lib's Invoke-CandidateBuild (the SINGLE pipeline both the sequential + concurrent paths run).
$lib = Get-Content "$PSScriptRoot\fleet-lib.ps1" -Raw
Assert-True ([regex]::IsMatch($lib, '--with hypothesis')) `
    'W5 [kill] Invoke-CandidateBuild (the unified per-candidate pipeline) includes --with hypothesis in the pytest step'

# W6: --with mutmut in verify-project.ps1 (mutation scoring)
Assert-True ([regex]::IsMatch($vp, '--with mutmut')) `
    'W6 [kill] verify-project.ps1 includes --with mutmut'

# W7: ConvertFrom-MutmutOutput called in verify-project.ps1 (wired to fleet-lib)
Assert-True ([regex]::IsMatch($vp, 'ConvertFrom-MutmutOutput')) `
    'W7 [kill] verify-project.ps1 calls ConvertFrom-MutmutOutput'

# W8: Get-MutationSignalNote called in verify-project.ps1 (wired to fleet-lib)
Assert-True ([regex]::IsMatch($vp, 'Get-MutationSignalNote')) `
    'W8 [kill] verify-project.ps1 calls Get-MutationSignalNote'

# W9: hard time-box of 150s present in verify-project.ps1
Assert-True ([regex]::IsMatch($vp, 'TimeoutSec 150')) `
    'W9 [kill] mutation gate has 150s hard time-box (TimeoutSec 150)'

# W10: py:test still uses Invoke-GateCheck (so a real pytest failure still fails the gate)
# -- this distinguishes py:test (hard signal) from py:mutation (soft signal).
Assert-True ([regex]::IsMatch($vp, "Invoke-GateCheck 'py:test'")) `
    'W10 [kill] py:test uses Invoke-GateCheck (real pytest failures still hard-fail the gate)'

# W11: the mutation block also has a 'skip' path (no source + test pair -> graceful skip)
Assert-True ([regex]::IsMatch($vp, "Add-Result 'py:mutation' 'skip'")) `
    'W11 [kill] py:mutation has a skip path (no tests or source -> skip, never error)'

# ===========================================================================
Section 'Result'
Write-Host ("  Passed:  {0}" -f $script:Pass) -ForegroundColor Green
if ($script:Fail) {
    Write-Host ("  Failed:  {0}" -f $script:Fail) -ForegroundColor Red
    $script:Failures | ForEach-Object { Write-Host "    - $_" -ForegroundColor Red }
    exit 1
} else {
    Write-Host ''
    Write-Host '  MUTATION-GATE: VALIDATED. Surviving mutants are a soft signal; the gate never hard-fails on them. PBT (Hypothesis) is wired into both gate + build-loop pytest invocations.' -ForegroundColor Green
    exit 0
}
