# Backs up every config this setup depends on into a dated zip (keeps newest 12)
# and commits the agentic-setup folder to its local git repo.
# Deliberately EXCLUDED: OpenCode chat/session history (~\.local\share\opencode) -
# it can be large; lose it and you lose old chats, not your setup.
$ErrorActionPreference = 'Stop'
$Setup  = 'C:\Users\mrbla\agentic-setup'
$BakDir = Join-Path $Setup 'state\backups'
New-Item -ItemType Directory -Force $BakDir | Out-Null

& "$PSScriptRoot\sync-harness.ps1"   # capture drift before zipping
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$zip = Join-Path $BakDir "config-$stamp.zip"
$items = @(
    "$env:USERPROFILE\.config\opencode\opencode.json",
    "$env:USERPROFILE\.config\opencode\AGENTS.md",
    "$env:USERPROFILE\.wslconfig",
    "$env:USERPROFILE\.openclaw\openclaw.json",
    "$Setup\configs",
    "$Setup\scripts",
    "$Setup\state\recent-projects.txt"
) | Where-Object { Test-Path $_ }
$items += @(Get-ChildItem "$Setup\*.cmd" | ForEach-Object { $_.FullName })
Compress-Archive -Path $items -DestinationPath $zip -Force
Write-Host "Backup written: $zip" -ForegroundColor Green

# rotate: keep newest 12
Get-ChildItem $BakDir -Filter 'config-*.zip' | Sort-Object LastWriteTime -Descending |
    Select-Object -Skip 12 | Remove-Item -ErrorAction SilentlyContinue

# local git commit of the setup folder (restore point for scripts)
Set-Location $Setup
git add -A *> $null
git -c user.email='setup@local' -c user.name='agentic-setup' commit -m "Config backup $stamp" *> $null
Write-Host "Setup folder committed to its local git history." -ForegroundColor Green
Write-Host "To restore: scripts\restore-config.ps1 (or extract the zip by hand - it is just files)."
