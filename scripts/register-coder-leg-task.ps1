#requires -Version 5.1
<#
.SYNOPSIS
  Register the DORMANT on-demand \BlarAI\BlarAI-Coder-Leg scheduled task (#775 ACP-01 Stage 4), running
  coder-leg-run.ps1 AS blarai-coder at RunLevel **Limited** — the structural de-elevation (D-C).

.DESCRIPTION
  The overnight battery self-elevates and the whole dispatch tree inherits that admin token, so the coder
  runs elevated today. ACP-01 de-elevates the coder leg SPECIFICALLY: this task runs as the restricted
  blarai-coder account regardless of the trigger's integrity, and the credential lives in the OS vault
  (LSA secrets) — beats runas /savecred (which caches a reusable credential in the very account we are
  isolating away from). The password is passed as a SecureString and materialized to plaintext ONLY at
  the Register-ScheduledTask API call, then zero-freed — never written to disk (D-C).

  DORMANT by construction: the task has **no trigger** (on-demand only). It fires solely when
  Start-ScheduledTask is called, which the orchestrator only does when containment=restricted_account.
  Registering it changes nothing about today's dispatch path.

  Normally invoked BY provision-coder-account.ps1 (which holds the freshly generated password in memory);
  can also be run standalone by the coordinator with a SecureString password.

.PARAMETER PasswordSecure
  The blarai-coder account password as a SecureString (mandatory). Never logged, never written to disk.
#>
[CmdletBinding()]
param(
    [string]$CoderUser = 'blarai-coder',
    [Parameter(Mandatory)][System.Security.SecureString]$PasswordSecure,
    [string]$TaskPath = '\BlarAI\',
    [string]$TaskName = 'BlarAI-Coder-Leg',
    [string]$ScriptsDir = $PSScriptRoot
)
$ErrorActionPreference = 'Stop'

$pwsh = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
if (-not $pwsh) { $pwsh = 'powershell.exe' }   # fall back to Windows PowerShell if pwsh 7 absent
$legScript = Join-Path $ScriptsDir 'coder-leg-run.ps1'
if (-not (Test-Path $legScript)) { throw "coder-leg-run.ps1 not found at $legScript" }

$action = New-ScheduledTaskAction -Execute $pwsh `
    -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$legScript`"" `
    -WorkingDirectory $ScriptsDir

# RunLevel Limited = the de-elevation (NOT Highest). LogonType Password so the OS vaults the credential.
$principal = New-ScheduledTaskPrincipal -UserId $CoderUser -LogonType Password -RunLevel Limited

$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 5) -StartWhenAvailable:$false

# NO trigger -> on-demand only -> DORMANT until Start-ScheduledTask is called.
$task = New-ScheduledTask -Action $action -Principal $principal -Settings $settings `
    -Description 'ACP-01 Stage 4 (#775): the de-elevated coder leg. Runs coder-leg-run.ps1 as blarai-coder (RunLevel Limited). On-demand only (no trigger) — DORMANT until the orchestrator triggers it under containment=restricted_account.'

# Materialize the plaintext ONLY for the vaulting API call, then zero-free it.
$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($PasswordSecure)
try {
    $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    # Ensure the task folder exists by passing -TaskPath; -Force replaces any prior registration.
    Register-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -InputObject $task `
        -User $CoderUser -Password $plain -Force | Out-Null
} finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    $plain = $null
}
Write-Host "[register-coder-leg] registered DORMANT on-demand task $TaskPath$TaskName as $CoderUser (RunLevel Limited; credential vaulted)." -ForegroundColor Green
