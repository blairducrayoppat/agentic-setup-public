#requires -Version 5.1
<#
.SYNOPSIS
  Verify the installed opencode binary matches the pinned manifest (#762 version pin).

.DESCRIPTION
  opencode ships as an UNPINNED global npm package with autoupdate:false. This standalone
  checker is the drift alarm: it reads configs/opencode-version-pin.json and asserts the
  live opencode.exe -- its resolved path, `opencode --version` string, and SHA-256 -- still
  matches the exact release the fleet was validated against. A silent npm upgrade (or a
  tampered binary) flips it to DRIFT.

  This is a STANDALONE checker (like verify-plugin-canary.ps1 and verify-critic-diff.ps1).
  It is deliberately NOT wired into the live coder-spawn path (scripts/fleet-lib.ps1 /
  Invoke-AgentRun) -- that wiring is a separate daylight live-verify job. It does not import
  fleet-lib, touch the GPU, load a model, or hit the network.

  Exit 0 = PASS (live binary matches the pin). Exit 1 = DRIFT (or the pin can't be verified).

  A deliberate opencode upgrade is expected to fail this until the manifest is refreshed:
  update configs/opencode-version-pin.json (version + sha256) and re-run the plugin canary
  before the fleet serves real dispatches again.
#>
$ErrorActionPreference = 'Stop'

$script:Pass = 0; $script:Fail = 0
function _pass($m) { $script:Pass++; Write-Host "  [PASS] $m" -ForegroundColor Green }
function _fail($m) { $script:Fail++; Write-Host "  [DRIFT] $m" -ForegroundColor Red }
function Assert($cond, $msg) { if ($cond) { _pass $msg } else { _fail $msg } }

Write-Host "== opencode version-pin verification ==" -ForegroundColor Cyan

# --- Load the manifest -------------------------------------------------------
$manifestPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'configs\opencode-version-pin.json'
Assert (Test-Path $manifestPath) "manifest exists: configs/opencode-version-pin.json"
if (-not (Test-Path $manifestPath)) {
    Write-Host ""
    Write-Host ("  Passed: {0}   Drift: {1}" -f $script:Pass, $script:Fail) -ForegroundColor Red
    exit 1
}

$manifest = $null
try {
    $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
    _pass "manifest parses as JSON"
} catch {
    _fail "manifest parses as JSON ($($_.Exception.Message))"
}
if ($null -eq $manifest) {
    Write-Host ""
    Write-Host ("  Passed: {0}   Drift: {1}" -f $script:Pass, $script:Fail) -ForegroundColor Red
    exit 1
}

Assert ([bool]$manifest.version) "manifest records a version ('$($manifest.version)')"
Assert ([bool]$manifest.sha256)  "manifest records a sha256"
Assert ([bool]$manifest.exe_path) "manifest records an exe_path"

# --- Resolve the live binary -------------------------------------------------
$liveExe = $null
try {
    $src = (Get-Command opencode -ErrorAction Stop).Source
    $liveExe = Join-Path (Split-Path $src -Parent) 'node_modules\opencode-ai\bin\opencode.exe'
} catch {
    _fail "resolve live opencode via Get-Command ($($_.Exception.Message))"
}

if ($liveExe -and (Test-Path $liveExe)) {
    _pass "live opencode.exe resolved and exists"

    # Compare resolved path to the manifest (normalize slashes/case for the compare).
    $liveExeNorm = ($liveExe -replace '\\', '/')
    $pinExeNorm  = ([string]$manifest.exe_path -replace '\\', '/')
    Assert ($liveExeNorm -ieq $pinExeNorm) `
        "exe_path matches manifest (live '$liveExeNorm' vs pin '$pinExeNorm')"

    # --- Version compare ---
    $liveVersion = $null
    try {
        $liveVersion = (& opencode --version 2>$null | Select-Object -First 1).ToString().Trim()
    } catch {
        _fail "run 'opencode --version' ($($_.Exception.Message))"
    }
    if ($liveVersion) {
        Assert ($liveVersion -eq [string]$manifest.version) `
            "version matches manifest (live '$liveVersion' vs pin '$($manifest.version)')"
    }

    # --- SHA-256 compare ---
    $liveHash = (Get-FileHash $liveExe -Algorithm SHA256).Hash
    Assert ($liveHash -ieq [string]$manifest.sha256) `
        "sha256 matches manifest (live '$liveHash' vs pin '$($manifest.sha256)')"
} else {
    _fail "live opencode.exe exists at the resolved path ('$liveExe')"
}

# --- Summary -----------------------------------------------------------------
Write-Host ""
Write-Host ("  Passed: {0}   Drift: {1}" -f $script:Pass, $script:Fail) `
    -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
if ($script:Fail) {
    Write-Host "  OPENCODE-PIN: DRIFT -- the live binary no longer matches the pin." -ForegroundColor Red
    Write-Host "  If this is a deliberate upgrade, refresh configs/opencode-version-pin.json" -ForegroundColor Yellow
    Write-Host "  (version + sha256) and re-run the plugin canary before serving dispatches." -ForegroundColor Yellow
    exit 1
} else {
    Write-Host "  OPENCODE-PIN: VALIDATED." -ForegroundColor Green
    exit 0
}
