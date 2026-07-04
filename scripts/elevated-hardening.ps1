# One-time hardening that needs Administrator rights. Run via the
# 'Harden (Admin, run once).cmd' launcher (it asks Windows for elevation).
# Everything here is reversible; revert commands are printed at the end.
$ErrorActionPreference = 'Stop'
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Write-Host "This needs Administrator. Use the 'Harden (Admin, run once).cmd' launcher."; Read-Host 'Press Enter to close'; exit 1 }

# 1. Block outbound network for the model server. It never needs the internet
#    (model downloads happen via a separate tool); defense in depth.
if (-not (Get-NetFirewallRule -DisplayName 'Block OVMS outbound' -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -DisplayName 'Block OVMS outbound' -Direction Outbound `
        -Program 'C:\ovms\ovms.exe' -Action Block -Profile Any | Out-Null
    Write-Host "Firewall: outbound traffic from ovms.exe is now blocked." -ForegroundColor Green
} else { Write-Host "Firewall rule already exists." }

# NOTE (2026-06-18): we DELIBERATELY do NOT add system-wide outbound blocks for
# curl.exe / certutil.exe / bitsadmin.exe. A per-exe Block (Profile Any) hits EVERY
# use of those tools on the machine -- the user's own curl, installers, scripts, and
# anything that shells out to them -- which is far too broad a blast radius for a
# coding-agent control. Agent egress is contained at the AGENT layer, scoped to the
# agent only: OpenCode's bash ask-rules (curl/wget/iwr/ssh/... -> auto-reject headless),
# web tools off, and loopback-only model serving. Do NOT reintroduce a global LOLBin
# firewall here. (If you ever applied the old 'Block agent exfil - *' rules, remove them:
#   Remove-NetFirewallRule -DisplayName 'Block agent exfil - *'   )

# 2. Windows Update active hours 13:00-07:00 - covers overnight agent runs
#    (active hours = the window Windows will NOT auto-restart in).
$ux = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'
Set-ItemProperty -Path $ux -Name ActiveHoursStart -Value 13 -Type DWord
Set-ItemProperty -Path $ux -Name ActiveHoursEnd   -Value 7  -Type DWord
Write-Host "Windows Update active hours set to 13:00-07:00 (no auto-restarts in that window)." -ForegroundColor Green

Write-Host ""
Write-Host "REVERT any time (as admin):" -ForegroundColor Cyan
Write-Host "  Remove-NetFirewallRule -DisplayName 'Block OVMS outbound'"
Write-Host "  (Active hours: Settings > Windows Update > Advanced options > Active hours)"
Read-Host 'Done. Press Enter to close'
