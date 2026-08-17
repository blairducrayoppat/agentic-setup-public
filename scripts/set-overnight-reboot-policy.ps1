<#
.SYNOPSIS
  Stop Windows from AUTO-RESTARTING the box while a battery night is running (#1380).
  Updates still download and install on their normal schedule -- only the unattended
  reboot is refused.

.DESCRIPTION
  WHY THIS EXISTS
  ===============
  2026-08-12, 03:29:07: MoUsoCoreWorker.exe initiated a restart ("Operating System:
  Service pack (Planned)"), followed by two TrustedInstaller restarts at 03:36:06 and
  03:36:42. Fleet run 20260811-232102-bd was mid-task. It had already merged three of
  seven pages on first dispatch and was 40 minutes into the fourth. The reboot killed it
  with TASK-START written and TASK-END never written, which wedged the battery's archive
  guard and cost five further nights (#1380).

  Active hours were set 13:00-07:00 and DID NOT PREVENT IT. Feature and servicing-stack
  updates override active hours; that is by design, and it is why widening the window is
  not the fix.

  WHAT THIS CHANGES, AND WHAT IT DELIBERATELY DOES NOT
  ====================================================
  Sets exactly one policy value:

      HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU
        NoAutoRebootWithLoggedOnUsers = 1

  That refuses the UNATTENDED restart while a user session exists. It does NOT defer,
  pause, block or delay the DOWNLOAD or INSTALLATION of any update, including security
  updates -- those continue on their normal schedule and are staged exactly as before.
  The only thing withheld is Windows choosing its own moment to reboot. The reboot then
  happens when the operator restarts the machine, which he does routinely.

  Operator decision, 2026-08-14, in his words: "block the automatic RESTART, don't defer
  the INSTALLATION. Patches keep installing; only the reboot is refused. No security
  cost." He also named this a STOPGAP: the durable answer is that a battery night should
  survive a reboot at all, which is separate work and needs no decision from him.

  A NOTE ON WHAT THIS CANNOT DO
  =============================
  It cannot stop a power loss, a thermal shutdown, or the operator closing the laptop --
  all of which kill a night the same way. The archive guard's boot-death predicate
  (#1380) is what makes those survivable at the BATTERY's end; this only removes the one
  cause that was self-inflicted and preventable.

.EXAMPLE
  .\set-overnight-reboot-policy.ps1 -Status     # report, change nothing
  .\set-overnight-reboot-policy.ps1 -Enable     # refuse unattended restarts
  .\set-overnight-reboot-policy.ps1 -Disable    # hand the decision back to Windows
#>
[CmdletBinding(DefaultParameterSetName = 'Status')]
param(
    [Parameter(ParameterSetName = 'Enable')][switch]$Enable,
    [Parameter(ParameterSetName = 'Disable')][switch]$Disable,
    [Parameter(ParameterSetName = 'Status')][switch]$Status
)
$ErrorActionPreference = 'Stop'

$AuKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
$Name  = 'NoAutoRebootWithLoggedOnUsers'

function Get-Current {
    if (-not (Test-Path $AuKey)) { return $null }
    $p = Get-ItemProperty -Path $AuKey -Name $Name -ErrorAction SilentlyContinue
    if (-not $p) { return $null }
    return [int]$p.$Name
}

function Test-Elevated {
    try {
        return [Security.Principal.WindowsPrincipal]::new(
            [Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

function Show-Status {
    $cur = Get-Current
    Write-Host ''
    Write-Host 'Windows unattended-restart policy' -ForegroundColor Cyan
    Write-Host "  key   : $AuKey"
    Write-Host "  value : $Name"
    if ($null -eq $cur) {
        Write-Host '  state : NOT SET -- Windows may restart this machine on its own.' -ForegroundColor Yellow
    } elseif ($cur -eq 1) {
        Write-Host '  state : ENABLED -- unattended restarts are refused while a user is logged on.' -ForegroundColor Green
    } else {
        Write-Host "  state : set to $cur -- that is not 1, so restarts are NOT refused." -ForegroundColor Yellow
    }

    # Active hours are reported because they are the setting people REACH FOR first, and
    # they did not hold on 2026-08-12. Naming them here stops the next person re-trying it.
    $ux = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings' -ErrorAction SilentlyContinue
    if ($ux) {
        Write-Host ''
        Write-Host "  active hours: $($ux.ActiveHoursStart):00 - $($ux.ActiveHoursEnd):00 (informational)"
        Write-Host '    Feature and servicing-stack updates override active hours. On 2026-08-12'
        Write-Host '    a restart landed at 03:29 INSIDE this window. Active hours are not the lock.'
    }

    # Whether a reboot is queued RIGHT NOW, distinguishing the two authoritative Windows
    # Update signals from PendingFileRenameOperations, which many ordinary installers set
    # and which on its own does not mean an update reboot is coming.
    $wu  = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    $cbs = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
    Write-Host ''
    if ($wu -or $cbs) {
        Write-Host '  A WINDOWS UPDATE REBOOT IS QUEUED right now' -ForegroundColor Yellow
        Write-Host "    (WindowsUpdate/RebootRequired=$wu, CBS/RebootPending=$cbs)"
        Write-Host '    With the policy ENABLED it will wait for a human. With it off, it may not.'
    } else {
        Write-Host '  No Windows Update reboot is queued (RebootRequired and CBS/RebootPending both absent).' -ForegroundColor Green
    }
    Write-Host ''
}

if ($Enable -or $Disable) {
    if (-not (Test-Elevated)) {
        Write-Host ''
        Write-Host 'This needs Administrator rights to write a machine policy.' -ForegroundColor Red
        Write-Host 'Re-run it from an elevated PowerShell, or launch it via an elevated scheduled task.'
        Write-Host ''
        exit 2
    }
    if (-not (Test-Path $AuKey)) { New-Item -Path $AuKey -Force | Out-Null }
    $target = if ($Enable) { 1 } else { 0 }
    Set-ItemProperty -Path $AuKey -Name $Name -Value $target -Type DWord
    $after = Get-Current
    if ($after -ne $target) {
        Write-Host "FAILED: wrote $target but the key reads '$after'." -ForegroundColor Red
        exit 1
    }
    # Read back and REPORT rather than announcing success from the write's return value --
    # the whole ticket this belongs to is about controls that reported a state they had
    # not verified.
    Write-Host ''
    Write-Host ("Unattended restarts are now {0}." -f $(if ($target -eq 1) { 'REFUSED' } else { 'ALLOWED (Windows decides again)' })) -ForegroundColor Green
    Show-Status
    exit 0
}

Show-Status
exit 0
