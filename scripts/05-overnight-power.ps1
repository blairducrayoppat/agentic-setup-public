# Phase 8 prerequisite: make overnight agent runs survive Windows.
# Sleep/Modern Standby and Windows Update kill overnight runs more often than OOM does.
# Run as Administrator. Re-run anytime; revert notes at the bottom.
$ErrorActionPreference = 'Continue'
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Write-Host "This script needs Administrator (right-click > Run as administrator). Nothing was changed." -ForegroundColor Red; exit 1 }

Write-Host "== Power settings for unattended runs (AC only) ==" -ForegroundColor Cyan
powercfg /change standby-timeout-ac 0      # never sleep on AC
powercfg /change hibernate-timeout-ac 0    # never hibernate on AC
powercfg /change monitor-timeout-ac 10     # screen may sleep; the run continues
# Lid close on AC: do nothing (GUID: power button/lid action)
powercfg /setacvalueindex SCHEME_CURRENT 4f971e89-eebd-4455-a8de-9e59040e7347 5ca83367-6e45-459f-a27b-476b1d01c936 0
powercfg /setactive SCHEME_CURRENT

Write-Host "== Windows Update active hours (manual step) ==" -ForegroundColor Yellow
Write-Host "Active hours = the window Windows will NOT auto-restart in. Set them to COVER your agent window:"
Write-Host "Settings > Windows Update > Advanced options > Active hours > Manual: e.g. 22:00 - 07:00."

Write-Host @"

RULES FOR FLEET NIGHTS (BLUEPRINT.md section 8):
  - Laptop on AC power, lid open or lid-action verified
  - Fleet codes on coder-30b (loaded by BlarAI's dispatch driver before each run)
  - WSL2 memory cap in place if OpenClaw lives there (configs\wslconfig-snippet.txt)
  - Expect thermal throttling on a thin laptop — slower, not broken

REVERT: powercfg /change standby-timeout-ac 30 ; powercfg /setacvalueindex SCHEME_CURRENT 4f971e89-... 5ca83367-... 1
"@ -ForegroundColor Cyan
