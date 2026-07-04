# Registers (or refreshes) the daily "BlarAI System Backup" scheduled task.
# Runs backup-system.ps1 every day at 20:30 as the current user, hidden,
# and also fires if the 20:30 slot was missed (StartWhenAvailable).
# Re-run this script any time to update the schedule. No elevation needed.

$scriptPath = Join-Path $PSScriptRoot 'backup-system.ps1'
if (-not (Test-Path $scriptPath)) { throw "backup-system.ps1 not found next to this script" }

$shell = if (Get-Command pwsh -ErrorAction SilentlyContinue) { (Get-Command pwsh).Source } else { 'powershell.exe' }

$action   = New-ScheduledTaskAction -Execute $shell `
            -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptPath`""
$trigger  = New-ScheduledTaskTrigger -Daily -At '20:30'
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -DontStopIfGoingOnBatteries `
            -AllowStartIfOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 2) `
            -MultipleInstances IgnoreNew

Register-ScheduledTask -TaskName 'BlarAI System Backup' -Action $action -Trigger $trigger `
    -Settings $settings -Description 'Daily backup: repos to GitHub, assets to OneDrive, secrets to local staging. Script: agentic-setup\scripts\backup-system.ps1' `
    -Force | Out-Null

Write-Host "Task 'BlarAI System Backup' registered: daily 20:30 (runs late if the slot was missed)."
Write-Host "Check last result any time: Get-ScheduledTaskInfo 'BlarAI System Backup'"
Write-Host "Or read: C:\Users\mrbla\OneDrive\BlarAI-Reformat-Backup-2026-07-01\LAST_BACKUP.txt"
