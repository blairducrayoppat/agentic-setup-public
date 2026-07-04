# Restores configs from a backup zip made by backup-config.ps1.
# Shows the available backups, you pick one, it extracts to a staging folder
# and copies the two live config files back with your confirmation.
$ErrorActionPreference = 'Stop'
$BakDir = 'C:\Users\mrbla\agentic-setup\state\backups'
$zips = @(Get-ChildItem $BakDir -Filter 'config-*.zip' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
if (-not $zips) { Write-Host "No backups found in $BakDir."; Read-Host 'Press Enter to close'; exit 1 }

Write-Host "Available backups (newest first):" -ForegroundColor Cyan
for ($i = 0; $i -lt $zips.Count; $i++) { Write-Host ("  [{0}] {1}" -f ($i+1), $zips[$i].Name) }
$pick = Read-Host "Which one? (number)"
if ($pick -notmatch '^\d+$' -or [int]$pick -lt 1 -or [int]$pick -gt $zips.Count) { Write-Host 'Invalid.'; exit 1 }
$zip = $zips[[int]$pick - 1].FullName

$stage = Join-Path $env:TEMP "config-restore-$(Get-Date -Format HHmmss)"
Expand-Archive $zip -DestinationPath $stage -Force
Write-Host "Extracted to $stage - contents:" -ForegroundColor Cyan
Get-ChildItem $stage -Recurse -File | ForEach-Object { "  " + $_.FullName.Replace($stage, '') }

$ok = Read-Host "Copy opencode.json + AGENTS.md + .wslconfig back to their live locations? (y/N)"
if ($ok -eq 'y') {
    if (Test-Path "$stage\opencode.json") { Copy-Item "$stage\opencode.json" "$env:USERPROFILE\.config\opencode\opencode.json" -Force; Write-Host 'opencode.json restored.' }
    if (Test-Path "$stage\AGENTS.md")     { Copy-Item "$stage\AGENTS.md" "$env:USERPROFILE\.config\opencode\AGENTS.md" -Force; Write-Host 'AGENTS.md restored.' }
    if (Test-Path "$stage\.wslconfig")    { Copy-Item "$stage\.wslconfig" "$env:USERPROFILE\.wslconfig" -Force; Write-Host '.wslconfig restored.' }
    Write-Host "Done. Scripts/launchers live in the staged 'scripts' folder - copy manually if needed." -ForegroundColor Green
} else {
    Write-Host "Nothing copied. The staged files remain at $stage for manual use."
}
