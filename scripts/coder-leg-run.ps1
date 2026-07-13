#requires -Version 5.1
<#
.SYNOPSIS
  The de-elevated coder leg (#775 ACP-01 Stage 4) — the scheduled-task action that runs AS blarai-coder,
  claims one coder-leg job off the file-queue, runs it (an ACP dispatch or a containment probe), and
  writes the result. DORMANT: only ever runs when the orchestrator Start-ScheduledTask's it, which it
  only does when [fleet_dispatch].containment = restricted_account.

.DESCRIPTION
  This is the "whole coder leg as the restricted account" resolution to the stdio collision (ACP-01 §3.3):
  the elevated orchestrator cannot hand a scheduled task opencode's stdio, so it talks to this leg over
  FILES. Registered as blarai-coder / RunLevel Limited (register-coder-leg-task.ps1), so the ACP driver,
  the opencode process it spawns, and every build child all live inside the ONE coder-SID process tree the
  per-SID firewall block + the ACL-deny cover — even though the orchestrator that triggered it is elevated.

  One invocation drains AT MOST one job (the battery pattern: trigger per job, poll the result). It never
  loops or self-schedules. Any failure is written to the result file, never thrown into the void.
#>
[CmdletBinding()]
param(
    [switch]$Once = $true   # drain a single job then exit (reserved for a future -All drain mode)
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\coder-leg-queue.ps1"
. "$PSScriptRoot\fleet-lib.ps1"

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
Write-Host "[coder-leg] running as $($id.Name) (SID $($id.User.Value))"

$claim = Get-NextCoderLegJob
if ($null -eq $claim) { Write-Host "[coder-leg] queue empty — nothing to do."; exit 0 }
$job = $claim.Job
Write-Host "[coder-leg] claimed $($job.id) (kind=$($job.kind))"

$result = @{ id = $job.id; kind = $job.kind; ok = $false; ran_as_sid = $id.User.Value; ran_as_user = $id.Name; error = '' }
try {
    switch ($job.kind) {
        'probe' {
            $probeOut = Join-Path (Get-CoderLegPaths).Results "$($job.id).probe.json"
            $secretPaths = @()
            if ($job.probe -and $job.probe.secret_paths) { $secretPaths = @($job.probe.secret_paths) }
            $loopback = if ($job.probe -and $job.probe.loopback_url) { [string]$job.probe.loopback_url } else { 'http://127.0.0.1:8000/v3/models' }
            & "$PSScriptRoot\coder-containment-probe.ps1" -SecretPaths $secretPaths -LoopbackUrl $loopback -OutJson $probeOut
            $result.result = (Get-Content $probeOut -Raw | ConvertFrom-Json)
            Remove-Item $probeOut -ErrorAction SilentlyContinue
            $result.ok = $true
        }
        'dispatch' {
            $cfg = Get-FleetDriverConfig -ScriptRoot $PSScriptRoot -Fresh
            $acpRun = Invoke-AcpCoderRun -WorkDir ([string]$job.workdir) -Model ([string]$job.model) `
                -Prompt (Get-Content ([string]$job.prompt_file) -Raw) -LogPath ([string]$job.log_path) `
                -Acp $cfg.acp -TimeoutSec ([int]$job.timeout_sec) -IdleTimeoutSec ([int]$job.idle_sec) `
                -MaxSteps ([int]$job.max_steps) -SpinSteps ([int]$job.spin_steps)
            $result.result = $acpRun
            $result.ok = [bool]$acpRun.Ok
            if (-not $acpRun.Ok) { $result.error = [string]$acpRun.Reason }
        }
        default {
            $result.error = "unknown job kind '$($job.kind)'"
        }
    }
} catch {
    $result.error = "coder-leg job failed: $($_.Exception.Message)"
    Write-Host "[coder-leg] ERROR: $($result.error)" -ForegroundColor Red
}
$written = Write-CoderLegResult -Result $result -ClaimPath $claim.ClaimPath
Write-Host "[coder-leg] wrote result -> $written (ok=$($result.ok))"
exit 0
