#requires -Version 5.1
<#
.SYNOPSIS
  The de-elevated coder leg (#775 ACP-01 Stage 4) — the scheduled-task action that runs AS blarai-coder,
  claims one coder-leg job off the file-queue, runs it (an ACP dispatch or a containment probe), and
  writes the result. It only runs when something Start-ScheduledTask's it: the orchestrator does so
  only when configs/fleet-driver.json says containment = restricted_account (Invoke-FusedCoderRun in
  fleet-lib.ps1), and verify-coder-containment.ps1 does so for its probe job.

.DESCRIPTION
  This is the "whole coder leg as the restricted account" resolution to the stdio collision (ACP-01 §3.3):
  the elevated orchestrator cannot hand a scheduled task opencode's stdio, so it talks to this leg over
  FILES. Registered as blarai-coder / RunLevel Limited (register-coder-leg-task.ps1), so the ACP driver,
  the opencode process it spawns, and every build child all live inside the ONE coder-SID process tree the
  ACL-deny covers -- even though the orchestrator that triggered it is elevated. The per-SID outbound
  firewall rule is not an enforced lock on this machine (accepted gap, #775 c.1653; see
  Assert-CoderEgressContained in fleet-lib.ps1).

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
. "$PSScriptRoot\coder-setup-lib.ps1"   # the tool-chain manifest (the coder's PATH prefix); read only on this leg

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
            # the narrowing checks (#1678): each list is optional; a probe job without them runs the four original checks
            $extra = @{}
            foreach ($pair in @(@('write_deny_dirs', 'WriteDenyDirs'), @('source_git_repos', 'SourceGitRepos'), @('read_files', 'ReadFiles'), @('worktree_paths', 'WorktreePaths'),
                                @('operator_deny_paths', 'OperatorDenyPaths'), @('toolchain_exes', 'ToolchainExes'), @('extra_write_deny_dirs', 'ExtraWriteDenyDirs'))) {
                if ($job.probe -and $job.probe.($pair[0])) { $extra[$pair[1]] = @($job.probe.($pair[0])) }
            }
            foreach ($pair in @(@('proxy_url', 'ProxyUrl'), @('config_dir', 'ConfigDir'))) {
                if ($job.probe -and $job.probe.($pair[0])) { $extra[$pair[1]] = [string]$job.probe.($pair[0]) }
            }
            if ($job.probe -and $job.probe.check_config -eq $true) { $extra['CheckConfig'] = $true }
            & "$PSScriptRoot\coder-containment-probe.ps1" -SecretPaths $secretPaths -LoopbackUrl $loopback -OutJson $probeOut @extra
            $result.result = (ConvertFrom-StrictJsonBytes -Bytes ([IO.File]::ReadAllBytes($probeOut)) -Schema @{ Type = 'any' } -What 'the probe output')
            Remove-Item $probeOut -ErrorAction SilentlyContinue
            $result.ok = $true
        }
        'dispatch' {
            # The coder's whole process tree lives in a kill-on-close job object with no breakaway. The runner
            # starts the ACP client INSIDE it (suspended, assigned, resumed), so every descendant is born inside
            # it; after the run every process in the job is terminated and the job is QUERIED until it is empty.
            # That fact goes into the result (job_zero_confirmed); the operator refuses a dispatch result without
            # it. If the runner is killed instead, closing its job handle kills the tree. If the job cannot be
            # created, the coder is never started.
            $cj = $null; $coderStarted = $false
            try {
                Assert-CoderLegJobPathsSafe -Job $job
                # git inside this leg: no optional locks, no prompts, safe.directory for this worktree only. The
                # variables are set before the coder is started so every child of the runner inherits them. (The
                # ACP client builds a whitelisted environment for the opencode child and passes these seven names
                # through: GIT_SAFETY_ENV_VARS in BlarAI tools/dispatch_harness/acp_coder.py must match this list.)
                foreach ($kv in (Get-CoderLegGitEnv -WorkDir ([string]$job.workdir)).GetEnumerator()) { Set-Item -LiteralPath "Env:\$($kv.Key)" -Value ([string]$kv.Value) }
                # the coder's PATH gets the folder that holds the opencode shim (the ACP client resolves the compiled exe
                # next to it). Appended, so a machine-wide tool always wins; the manifest is the one place that names it, and
                # one that cannot be read refuses the run before anything is started.
                $tcm = Read-CoderToolchainManifest -Path (Join-Path (Split-Path $PSScriptRoot -Parent) 'configs\coder-toolchain.json')
                $env:PATH = $env:PATH.TrimEnd(';') + ';' + ((Get-CoderToolchainPathPrefix -Manifest $tcm) -join ';')
                $cj = New-CoderJob
                $cfg = Get-FleetDriverConfig -ScriptRoot $PSScriptRoot -Fresh
                $coderStarted = $true
                $acpRun = Invoke-AcpCoderRun -WorkDir ([string]$job.workdir) -Model ([string]$job.model) `
                    -Prompt (Get-Content ([string]$job.prompt_file) -Raw) -LogPath ([string]$job.log_path) `
                    -Acp $cfg.acp -TimeoutSec ([int]$job.timeout_sec) -IdleTimeoutSec ([int]$job.idle_sec) `
                    -MaxSteps ([int]$job.max_steps) -SpinSteps ([int]$job.spin_steps) -Job $cj
                $result.result = $acpRun
                $result.ok = [bool]$acpRun.Ok
                if (-not $acpRun.Ok) { $result.error = [string]$acpRun.Reason }
            } finally {
                if ($cj) {
                    $drain = Stop-CoderJobProcesses -Job $cj -WaitSec 20
                    $result.job_zero_confirmed = [bool]$drain.Zero
                    $result.job_active = [int]$drain.Active
                    if ($drain.Zero) { Close-CoderJob -Job $cj }
                } elseif (-not $coderStarted) {
                    # the job could not be created: nothing was started, so nothing can be running
                    $result.job_zero_confirmed = $true; $result.job_active = 0
                }
            }
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
