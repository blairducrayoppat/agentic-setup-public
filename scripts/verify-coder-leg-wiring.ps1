#requires -Version 5.1
<#
.SYNOPSIS
  Verify the #775 ACP-01 Stage 4 coder-leg wiring is sound and DORMANT-safe, fully OFFLINE — no coder
  account, no scheduled task registered, no opencode, no model, no real egress.

.DESCRIPTION
  The live, fused proof (the coder leg actually running as blarai-coder) is the coordinator's GPU window.
  This suite locks the plumbing that must hold BEFORE that, with zero side effects on the real system:
    1. QUEUE CONTRACT  — enqueue -> atomic claim (not re-claimable) -> write result -> poll (consume-once),
       against a TEMP root ($env:BLARAI_CODER_LEG_ROOT), so C:\blarai-fleet is never touched.
    2. DE-ELEVATION    — the coder-leg task principal is RunLevel **Limited** (NOT Highest) with LogonType
       Password — the structural de-elevation D-C depends on (built, not registered).
    3. DISPATCH PATH   — coder-leg-run.ps1's 'dispatch' branch, with the shipped dormant config
       (acp.python=''), returns a well-formed result with ok=$false and a fallback reason WITHOUT spawning
       opencode or the model — proving the claim->run->result plumbing end-to-end offline.

  Run it normally ( .\verify-coder-leg-wiring.ps1 ). Exit 0 if everything passed, 1 otherwise.
#>
param()
$ErrorActionPreference = 'Stop'

$script:Pass = 0; $script:Fail = 0
$script:Failures = New-Object System.Collections.ArrayList
function _pass($m) { $script:Pass++; Write-Host "  [PASS] $m" -ForegroundColor Green }
function _fail($m) { $script:Fail++; [void]$script:Failures.Add($m); Write-Host "  [FAIL] $m" -ForegroundColor Red }
function Section($t) { Write-Host ''; Write-Host "== $t ==" -ForegroundColor Cyan }
function Assert-True($c, $m)  { if ($c) { _pass $m } else { _fail "$m (expected True)" } }
function Assert-False($c, $m) { if (-not $c) { _pass $m } else { _fail "$m (expected False)" } }
function Assert-Eq($e, $a, $m) { if ([string]$e -ceq [string]$a) { _pass $m } else { _fail "$m (expected '$e', got '$a')" } }

$tmpRoot = Join-Path ([IO.Path]::GetTempPath()) ("acp01-leg-" + [guid]::NewGuid().ToString('N'))
$env:BLARAI_CODER_LEG_ROOT = $tmpRoot
. "$PSScriptRoot\coder-leg-queue.ps1"

# Guard: refuse to run if the override did not take (never touch the real shared tree in a test).
$paths = Get-CoderLegPaths
if ($paths.Root -ne $tmpRoot) {
    Write-Host "ABORT: queue-root override did not take (root=$($paths.Root)) — refusing to touch the real path." -ForegroundColor Red
    exit 2
}

try {
    Section 'Queue contract: enqueue -> atomic claim -> result -> consume-once (temp root)'
    $jid = Add-CoderLegJob -Job @{ kind = 'probe'; probe = @{ secret_paths = @('C:\x'); loopback_url = 'http://127.0.0.1:8000/v3/models' } }
    Assert-True ([bool]$jid) 'enqueue returns a job id'
    $claim = Get-NextCoderLegJob
    Assert-True ($null -ne $claim) 'oldest job is claimed'
    Assert-Eq 'probe' $claim.Job.kind 'claimed job carries its kind'
    $again = Get-NextCoderLegJob
    Assert-True ($null -eq $again) 'a claimed job is NOT re-claimable (atomic claim)'
    [void](Write-CoderLegResult -Result @{ id = $claim.Job.id; kind = 'probe'; ok = $true } -ClaimPath $claim.ClaimPath)
    $r = Wait-CoderLegResult -JobId $claim.Job.id -TimeoutSec 5
    Assert-True ($r -and $r.ok) 'result polls back'
    $r2 = Wait-CoderLegResult -JobId $claim.Job.id -TimeoutSec 2
    Assert-True ($null -eq $r2) 'result is consume-once'

    Section 'De-elevation: the coder-leg task principal is RunLevel Limited (NOT Highest)'
    $principal = New-ScheduledTaskPrincipal -UserId 'blarai-coder' -LogonType Password -RunLevel Limited
    Assert-Eq 'Limited' ([string]$principal.RunLevel) 'principal RunLevel is Limited (the structural de-elevation)'
    Assert-Eq 'blarai-coder' ([string]$principal.UserId) 'principal runs as blarai-coder'

    Section 'Dispatch path: coder-leg-run dispatches, falls back offline (no opencode, no model, no egress)'
    # Force the DORMANT driver config (acp.python='') via the test-only BLARAI_FLEET_DRIVER_CONFIG override
    # so Invoke-AcpCoderRun returns Ok=$false immediately (no interpreter) and coder-leg-run writes an
    # ok=$false result WITHOUT spawning opencode. (The real configs/fleet-driver.json now points acp.python
    # at the provisioned .venv314-acp, so without this override the dispatch would perform a real opencode
    # handshake — the override keeps this a pure, hermetic plumbing proof.)
    $tmpCfg = Join-Path $tmpRoot 'fleet-driver.json'
    New-Item -ItemType Directory -Force $tmpRoot | Out-Null
    Set-Content -Path $tmpCfg -Encoding UTF8 -Value '{ "driver": "acp", "containment": "off", "acp": { "python": "", "idle_sec": 120, "max_steps": 45, "spin_steps": 10 } }'
    $env:BLARAI_FLEET_DRIVER_CONFIG = $tmpCfg
    $promptFile = Join-Path $tmpRoot 'p.txt'
    Set-Content -Path $promptFile -Value 'implement rpn.py' -Encoding UTF8
    $djid = Add-CoderLegJob -Job @{
        kind = 'dispatch'; workdir = $tmpRoot; model = 'local/coder-30b'; prompt_file = $promptFile
        log_path = (Join-Path $tmpRoot 'run.log'); timeout_sec = 60; idle_sec = 120; max_steps = 45; spin_steps = 10
    }
    & "$PSScriptRoot\coder-leg-run.ps1" | Out-Null
    $dres = Wait-CoderLegResult -JobId $djid -TimeoutSec 30
    Assert-True ($null -ne $dres) 'dispatch job produced a result'
    Assert-Eq 'dispatch' ([string]$dres.kind) 'result carries kind=dispatch'
    Assert-False ([bool]$dres.ok) 'dispatch fell back (ok=$false) under the forced-dormant config (no opencode spawned)'
    Assert-True ([bool]$dres.ran_as_sid) 'result records the SID it ran as (the containment audit field)'
}
finally {
    Remove-Item Env:\BLARAI_CODER_LEG_ROOT -ErrorAction SilentlyContinue
    Remove-Item Env:\BLARAI_FLEET_DRIVER_CONFIG -ErrorAction SilentlyContinue
    if ($tmpRoot -like '*\Temp\acp01-leg-*') { Remove-Item $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host ''
if ($script:Fail -eq 0) {
    Write-Host "RESULT: $($script:Pass) passed, 0 failed" -ForegroundColor Green; exit 0
} else {
    Write-Host "RESULT: $($script:Pass) passed, $($script:Fail) failed" -ForegroundColor Red
    $script:Failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}
