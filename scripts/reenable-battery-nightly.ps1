# Re-enable the BlarAI nightly battery scheduled task.
#
# WHY THIS EXISTS: on 2026-07-22 the Lead Architect yielded the GPU for one night to an
# upstream OpenVINO 35B measurement. The battery loads the 14B/30B; the two cannot share
# one Arc 140V or fit together in 32 GB, so the nightly was DISABLED for that night only.
# A disabled task that nobody re-enables silently kills battery data for every following
# night, so the re-enable is a MECHANISM, not a note in someone's memory.
#
# Scope: this ONLY flips the task's enabled bit back. It does not touch
# state/battery-campaign.json - a skipped night is not a campaign change, and the
# m2-baseline counters (completed_passes, lean_passes, jobs) must stay exactly as they are.
#
# Interpreter note: invoked with Windows PowerShell 5.1 at its System32 path, NOT pwsh.
# pwsh here is an MSIX/Store package under C:\Program Files\WindowsApps, whose ACLs deny
# the SYSTEM principal - a scheduled task running as SYSTEM fails with win32 1920
# (ERROR_CANT_ACCESS_FILE) before the script ever runs. Measured 2026-07-22, not assumed.
# (This is a DIFFERENT problem from the battery runbook's "use pwsh, not powershell" rule,
# which is about parsing a BOM-less .ps1 FILE. This script is ASCII-only, so 5.1 is safe.)

$ErrorActionPreference = 'Stop'
$taskPath = '\BlarAI\'
$taskName = 'BlarAI-M2-Battery-Nightly'
$log      = 'C:\Users\mrbla\agentic-setup\state\battery-reenable.log'
$stamp    = (Get-Date -Format o)

try {
    Enable-ScheduledTask -TaskPath $taskPath -TaskName $taskName | Out-Null
    $state = (Get-ScheduledTask -TaskPath $taskPath -TaskName $taskName).State
    $next  = (Get-ScheduledTaskInfo -TaskPath $taskPath -TaskName $taskName).NextRunTime
    if ($state -eq 'Ready') {
        Add-Content -Path $log -Value ("{0} RE-ENABLE OK    state={1} next={2}" -f $stamp, $state, $next)
        exit 0
    }
    # Fail LOUD rather than logging a success we did not achieve.
    Add-Content -Path $log -Value ("{0} RE-ENABLE WRONG-STATE state={1} (expected Ready)" -f $stamp, $state)
    exit 1
}
catch {
    Add-Content -Path $log -Value ("{0} RE-ENABLE FAILED {1}" -f $stamp, $_.Exception.Message)
    exit 1
}
