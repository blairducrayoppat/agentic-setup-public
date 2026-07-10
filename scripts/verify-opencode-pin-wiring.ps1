#requires -Version 5.1
<#
.SYNOPSIS
  Verify Get-OpencodePinVerdict (fleet-lib.ps1) -- the PURE half of the #762 fail-closed opencode
  spawn tripwire now wired into Invoke-AgentRun's HEAD.

.DESCRIPTION
  opencode ships as an UNPINNED global npm package, so a silent autoupgrade or a tampered binary would
  run a DIFFERENT release than the fleet was validated against. Invoke-AgentRun now REFUSES to spawn on
  any drift (configs/opencode-version-pin.json is the pin). The compare LOGIC lives in the pure, injectable
  Get-OpencodePinVerdict so it is unit-testable WITHOUT opencode installed; this suite drives it with
  scripted inputs, each scenario killing a specific wrong implementation:
    S1  path+version+hash all match           -> Ok
    S2  version drift                          -> refuse, reason names VERSION (silent-upgrade case)
    S3  sha256 drift (version+path match)      -> refuse, reason names BINARY (tampered-binary case)
    S4  exe_path drift                         -> refuse, reason names PATH
    S5  null manifest (missing/unreadable)     -> refuse fail-closed (drop this -> a missing pin runs anything)
    S6  manifest missing sha256                -> refuse (incomplete pin is not a pin)
    S7  live binary unresolved                 -> refuse
    S8  neither version NOR hash probed        -> refuse (vacuous "path matched" is not a validation)
    S9  version matches, hash not computed      -> Ok (a strong signal alone validates)
    S10 hash matches, version not read          -> Ok (the sha is the strongest signal)
    S11 hash compare is case-insensitive        -> Ok (Get-FileHash upper vs a lower-case pin)
  Get-OpencodePinVerdict NEVER throws. PS 5.1 & 7 safe; no model, no network, no opencode needed.

  This is the OFFLINE unit layer; the LIVE drift alarm (probe the real installed binary) stays in the
  standalone verify-opencode-pin.ps1, and the per-run fail-closed refusal is the coordinator's watched
  live-verify. Exit 0 if all pass, 1 on any failure. Run it normally - do NOT dot-source it.
#>
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\fleet-lib.ps1"

$script:Pass = 0; $script:Fail = 0
$script:Failures = New-Object System.Collections.ArrayList
function _pass($m) { $script:Pass++; Write-Host "  [PASS] $m" -ForegroundColor Green }
function _fail($m) { $script:Fail++; [void]$script:Failures.Add($m); Write-Host "  [FAIL] $m" -ForegroundColor Red }
function Assert($cond, $msg) { if ($cond) { _pass $msg } else { _fail $msg } }

# A stand-in for the ConvertFrom-Json manifest (the real pin's shape).
function New-PinManifest {
    param([string]$Version = '1.17.8', [string]$Sha = 'ABCDEF0123', [string]$Exe = 'C:/npm/node_modules/opencode-ai/bin/opencode.exe')
    [pscustomobject]@{ version = $Version; sha256 = $Sha; exe_path = $Exe }
}
$goodExe = 'C:/npm/node_modules/opencode-ai/bin/opencode.exe'

Write-Host "== opencode pin-verdict verification ==" -ForegroundColor Cyan

# S1 -- full match
$v = Get-OpencodePinVerdict -Manifest (New-PinManifest) -LiveExePath $goodExe -LiveVersion '1.17.8' -LiveHash 'ABCDEF0123'
Assert ($v.Ok -eq $true) 'S1 all-match => Ok'

# S2 -- version drift
$v = Get-OpencodePinVerdict -Manifest (New-PinManifest) -LiveExePath $goodExe -LiveVersion '1.18.0' -LiveHash 'ABCDEF0123'
Assert ($v.Ok -eq $false) 'S2 version drift => refuse'
Assert ($v.Reason -match 'VERSION drift') 'S2 reason names the VERSION drift'

# S3 -- binary/sha drift (path + version match)
$v = Get-OpencodePinVerdict -Manifest (New-PinManifest) -LiveExePath $goodExe -LiveVersion '1.17.8' -LiveHash 'DEADBEEF99'
Assert ($v.Ok -eq $false) 'S3 sha drift => refuse'
Assert ($v.Reason -match 'BINARY drift') 'S3 reason names the BINARY drift'

# S4 -- path drift
$v = Get-OpencodePinVerdict -Manifest (New-PinManifest) -LiveExePath 'C:/somewhere/else/opencode.exe' -LiveVersion '1.17.8' -LiveHash 'ABCDEF0123'
Assert ($v.Ok -eq $false) 'S4 path drift => refuse'
Assert ($v.Reason -match 'PATH drift') 'S4 reason names the PATH drift'

# S5 -- null manifest (fail-closed)
$v = Get-OpencodePinVerdict -Manifest $null -LiveExePath $goodExe -LiveVersion '1.17.8' -LiveHash 'ABCDEF0123'
Assert ($v.Ok -eq $false) 'S5 null manifest => refuse fail-closed'
Assert ($v.Reason -match 'manifest missing') 'S5 reason names the missing manifest'

# S6 -- incomplete manifest (no sha256)
$v = Get-OpencodePinVerdict -Manifest (New-PinManifest -Sha '') -LiveExePath $goodExe -LiveVersion '1.17.8' -LiveHash 'ABCDEF0123'
Assert ($v.Ok -eq $false) 'S6 manifest without sha256 => refuse'
Assert ($v.Reason -match 'incomplete') 'S6 reason names the incomplete manifest'

# S7 -- unresolved live binary
$v = Get-OpencodePinVerdict -Manifest (New-PinManifest) -LiveExePath '' -LiveVersion '1.17.8' -LiveHash 'ABCDEF0123'
Assert ($v.Ok -eq $false) 'S7 unresolved live binary => refuse'
Assert ($v.Reason -match 'could not be resolved') 'S7 reason names the unresolved binary'

# S8 -- neither version nor hash probed (vacuous-pass guard)
$v = Get-OpencodePinVerdict -Manifest (New-PinManifest) -LiveExePath $goodExe -LiveVersion '' -LiveHash ''
Assert ($v.Ok -eq $false) 'S8 no version + no hash => refuse (never a vacuous path-only pass)'
Assert ($v.Reason -match 'could not probe') 'S8 reason names the failed probe'

# S9 -- version matches, hash absent (a strong signal alone validates)
$v = Get-OpencodePinVerdict -Manifest (New-PinManifest) -LiveExePath $goodExe -LiveVersion '1.17.8' -LiveHash ''
Assert ($v.Ok -eq $true) 'S9 version match with no hash => Ok'

# S10 -- hash matches, version absent
$v = Get-OpencodePinVerdict -Manifest (New-PinManifest) -LiveExePath $goodExe -LiveVersion '' -LiveHash 'ABCDEF0123'
Assert ($v.Ok -eq $true) 'S10 hash match with no version => Ok'

# S11 -- hash compare is case-insensitive (Get-FileHash returns UPPER; a pin may be lower)
$v = Get-OpencodePinVerdict -Manifest (New-PinManifest -Sha 'abcdef0123') -LiveExePath $goodExe -LiveVersion '1.17.8' -LiveHash 'ABCDEF0123'
Assert ($v.Ok -eq $true) 'S11 sha compare is case-insensitive => Ok'

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
