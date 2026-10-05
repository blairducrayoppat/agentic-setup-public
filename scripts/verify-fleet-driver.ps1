#requires -Version 5.1
<#
.SYNOPSIS
  Verify the #775 ACP-01 fleet-driver seam reads its flags correctly and fails safe (no model, no GPU).

.DESCRIPTION
  Background (plain English):
    ACP-01 adds a `driver = stdin | acp` seam and a `containment = off | restricted_account` flag, read
    from configs/fleet-driver.json by Get-FleetDriverConfig. The load-bearing safety property is that
    with an unreadable/absent/garbled manifest the fleet behaves EXACTLY as the dormant default:
    driver=stdin, containment=off. The shipped manifest's own driver value is a config decision that
    changes by editing the config alone, so it is NOT asserted here -- this suite asserts that the
    READER honours whatever the manifest says. It proves:
      * the SHIPPED manifest's containment is 'off' and its driver is a recognised value that the reader
        returns exactly as written,
      * Resolve-WorktreeBase and Invoke-CoderDriver carry the containment branch (the flag-reading logic),
      * a MISSING or MALFORMED manifest fails safe to the dormant defaults (never enables a non-default
        posture on a read error -- the fail-closed rule),
      * a manifest that DELIBERATELY says acp/restricted_account is read as such (the flag actually works),
      * an INVALID flag value is coerced back to the safe default,
      * Invoke-AcpCoderRun falls back to stdin (Ok=$false) when no ACP python interpreter is provisioned,
        which is the dormant state (acp.python='' in the shipped manifest) -- so flipping driver=acp with
        no interpreter can never silently break a dispatch.

  Run it normally ( .\verify-fleet-driver.ps1 ) - do NOT dot-source it.
  Exit code 0 if everything passed, 1 if any check failed.  No model, no opencode spawn, no GPU.
#>
param()
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\fleet-lib.ps1"

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

# A helper to build a temp <root>/scripts + <root>/configs/fleet-driver.json and read it fresh.
function New-TempDriverRoot([string]$Json) {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("acp01-driver-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force (Join-Path $root 'scripts') | Out-Null
    New-Item -ItemType Directory -Force (Join-Path $root 'configs') | Out-Null
    if ($null -ne $Json) { Set-Content -Path (Join-Path $root 'configs\fleet-driver.json') -Value $Json -Encoding UTF8 }
    return $root
}

Section 'The SHIPPED manifest: containment is off and the driver value is read exactly as written'
$shipped = Get-FleetDriverConfig -ScriptRoot $PSScriptRoot -Fresh
$shippedRaw = Get-Content (Join-Path (Split-Path $PSScriptRoot -Parent) 'configs\fleet-driver.json') -Raw | ConvertFrom-Json
Assert-True ($shipped.driver -in @('stdin','acp')) "shipped driver is a recognised value ('$($shipped.driver)')"
Assert-Eq $shippedRaw.driver $shipped.driver 'the reader returns the shipped manifest driver exactly as written'
Assert-Eq 'off'   $shipped.containment 'shipped containment == off'
Assert-Eq $shippedRaw.containment $shipped.containment 'the reader returns the shipped manifest containment exactly as written'
Assert-False $shipped.containment_invalid 'the shipped containment value is recognised (not flagged invalid)'
Assert-False $shipped.containment_unresolved 'the shipped manifest is readable (not unresolved)'
# Dormancy rides the TWO FLAGS above, not the interpreter path: with driver=stdin the ACP
# path is never entered, so a provisioned acp.python is inert. The durable invariant is
# "when set, the path must be a REAL interpreter" (a dangling path would turn the first
# driver=acp run into a silent stdin fallback instead of the intended ACP run).
$shippedPy = [string]$shipped.acp.python
if ($shippedPy -eq '') {
    Assert-True $true 'shipped acp.python empty (interpreter not yet provisioned) - acceptable dormant state'
} else {
    Assert-True (Test-Path $shippedPy) "shipped acp.python points at an existing interpreter ($shippedPy)"
}

Section 'A MISSING manifest fails safe to the dormant defaults'
$rootMissing = New-TempDriverRoot $null
$cfgMissing = Get-FleetDriverConfig -ScriptRoot (Join-Path $rootMissing 'scripts') -Fresh
Assert-Eq 'stdin' $cfgMissing.driver 'missing manifest -> driver stdin'
Assert-Eq 'off'   $cfgMissing.containment 'missing manifest -> containment off'
Assert-True $cfgMissing.containment_unresolved 'missing manifest -> containment_unresolved (off is a substitute, not a decision)'

$cfgNoDir = Get-FleetDriverConfig -ScriptRoot (Join-Path $rootMissing 'nowhere\scripts') -Fresh
Assert-True ($cfgNoDir.containment_unresolved -and $cfgNoDir.containment -eq 'off') 'an absent manifest file -> off + containment_unresolved'
foreach ($scalar in 'null', '42', '"text"') {
    $rootScalar = New-TempDriverRoot $scalar
    $cfgScalar = Get-FleetDriverConfig -ScriptRoot (Join-Path $rootScalar 'scripts') -Fresh
    Assert-True ($cfgScalar.containment_unresolved -and $cfgScalar.driver -eq 'stdin') "a manifest holding just $scalar -> unresolved dormant defaults"
    Remove-Item $rootScalar -Recurse -Force -ErrorAction SilentlyContinue
}

Section 'A MALFORMED manifest fails safe (never enables a non-default posture on a read error)'
$rootBad = New-TempDriverRoot '{ this is not valid json '
$cfgBad = Get-FleetDriverConfig -ScriptRoot (Join-Path $rootBad 'scripts') -Fresh
Assert-Eq 'stdin' $cfgBad.driver 'malformed manifest -> driver stdin'
Assert-Eq 'off'   $cfgBad.containment 'malformed manifest -> containment off'
Assert-True $cfgBad.containment_unresolved 'malformed manifest -> containment_unresolved'

Section 'A DELIBERATE acp/restricted_account manifest IS read as such (the flag works)'
$rootLive = New-TempDriverRoot '{ "driver": "acp", "containment": "restricted_account", "acp": { "python": "", "idle_sec": 120, "max_steps": 45, "spin_steps": 10 } }'
$cfgLive = Get-FleetDriverConfig -ScriptRoot (Join-Path $rootLive 'scripts') -Fresh
Assert-Eq 'acp' $cfgLive.driver 'explicit driver acp is honoured'
Assert-Eq 'restricted_account' $cfgLive.containment 'explicit containment restricted_account is honoured'

Section 'The flag-reading logic: worktree base and the driver branch'
$wtOff = Resolve-WorktreeBase -ScriptRoot $PSScriptRoot -Containment 'off'
Assert-Eq (Join-Path (Split-Path $PSScriptRoot -Parent) 'state\worktrees') $wtOff 'containment off -> the historical state\worktrees base'
Assert-Eq 'C:\blarai-fleet\worktrees' (Resolve-WorktreeBase -ScriptRoot $PSScriptRoot -Containment 'restricted_account') 'restricted_account -> the shared dual-SID worktree base'
$drvBody = (Get-Command Invoke-CoderDriver).ScriptBlock.ToString()
Assert-True ($drvBody -match "containment -eq 'restricted_account'") 'Invoke-CoderDriver branches on containment restricted_account'
Assert-True ($drvBody -match 'Invoke-FusedCoderRun') 'the restricted_account branch calls the fused leg'
Assert-True ($drvBody -match 'containment_invalid') 'Invoke-CoderDriver refuses an unrecognised containment value'
Assert-True ($drvBody.IndexOf('containment_invalid') -lt $drvBody.IndexOf("driver -eq 'acp'")) 'the containment decision precedes any driver work'

Section 'An INVALID flag value is coerced back to the safe default'
$rootJunk = New-TempDriverRoot '{ "driver": "banana", "containment": "wide-open" }'
$cfgJunk = Get-FleetDriverConfig -ScriptRoot (Join-Path $rootJunk 'scripts') -Fresh
Assert-Eq 'stdin' $cfgJunk.driver 'invalid driver value -> coerced to stdin'
Assert-Eq 'off'   $cfgJunk.containment 'invalid containment value -> coerced to off'
Assert-True $cfgJunk.containment_invalid 'invalid containment value is FLAGGED (so Invoke-CoderDriver can refuse it)'
Assert-False $cfgMissing.containment_invalid 'a missing manifest is not flagged invalid (dormant default)'
Assert-False $cfgLive.containment_invalid 'restricted_account is not flagged invalid'
Assert-False $cfgLive.containment_unresolved 'a readable manifest is not unresolved'
Assert-False $cfgJunk.containment_unresolved 'a readable manifest with a bad containment value is invalid, not unresolved'
Assert-True ($drvBody -match 'containment_unresolved') 'Invoke-CoderDriver refuses an unreadable manifest where containment is expected'

Section 'Invoke-AcpCoderRun falls back (Ok=$false) with no ACP interpreter provisioned'
$acpNone = [pscustomobject]@{ python = ''; blarai_root = 'C:/Users/mrbla/blarai'; idle_sec = 120; max_steps = 45; spin_steps = 10 }
$logTmp = Join-Path ([System.IO.Path]::GetTempPath()) ("acp01-log-" + [guid]::NewGuid().ToString('N') + '.log')
$r1 = Invoke-AcpCoderRun -WorkDir 'C:\nope' -Model 'local/coder-30b' -Prompt 'x' -LogPath $logTmp -Acp $acpNone
Assert-False $r1.Ok 'empty acp.python -> Ok=$false (fall back to stdin)'
Assert-True ($r1.Reason -like '*no ACP python interpreter*') 'reason names the missing interpreter'
Assert-False (Test-Path "$logTmp.acp-prompt.txt") 'no prompt file staged when there is no interpreter (bailed early)'

$acpBogus = [pscustomobject]@{ python = 'C:\definitely\not\here\python.exe'; blarai_root = 'C:/Users/mrbla/blarai'; idle_sec = 120; max_steps = 45; spin_steps = 10 }
$r2 = Invoke-AcpCoderRun -WorkDir 'C:\nope' -Model 'local/coder-30b' -Prompt 'x' -LogPath $logTmp -Acp $acpBogus
Assert-False $r2.Ok 'nonexistent acp.python -> Ok=$false (fall back to stdin)'

# tidy temp roots
foreach ($r in @($rootMissing,$rootBad,$rootLive,$rootJunk)) { Remove-Item $r -Recurse -Force -ErrorAction SilentlyContinue }
# restore the process-memoised config to the shipped one so a later dot-source in the same session is clean
[void](Get-FleetDriverConfig -ScriptRoot $PSScriptRoot -Fresh)

Write-Host ''
if ($script:Fail -eq 0) {
    Write-Host "RESULT: $($script:Pass) passed, 0 failed" -ForegroundColor Green; exit 0
} else {
    Write-Host "RESULT: $($script:Pass) passed, $($script:Fail) failed" -ForegroundColor Red
    $script:Failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}
