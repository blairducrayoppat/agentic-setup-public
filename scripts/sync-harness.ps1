# Captures drift between the LIVE harness files (the ones agents actually read)
# and the git-tracked copies in agentic-setup\configs. Called automatically by
# start-llm, the control panel, and backups - so any change to the live harness
# gets recorded in git history at the next use of the system.
$ErrorActionPreference = 'SilentlyContinue'
$Setup = 'C:\Users\mrbla\agentic-setup'

function Sync-One([string]$src, [string]$dst) {
    if (-not (Test-Path $src)) { return $false }
    if ((Test-Path $dst) -and ((Get-FileHash $src).Hash -eq (Get-FileHash $dst).Hash)) { return $false }
    New-Item -ItemType Directory -Force (Split-Path $dst) | Out-Null
    Copy-Item $src $dst -Force
    return $true
}

$changed = $false
$changed = (Sync-One "$env:USERPROFILE\.config\opencode\opencode.json" "$Setup\configs\opencode.json") -or $changed
$changed = (Sync-One "$env:USERPROFILE\.config\opencode\AGENTS.md"     "$Setup\configs\AGENTS.md")     -or $changed
$changed = (Sync-One "$env:USERPROFILE\.wslconfig"                     "$Setup\configs\wslconfig-live.txt") -or $changed
if (Test-Path "$env:USERPROFILE\.openclaw\openclaw.json") {
    $changed = (Sync-One "$env:USERPROFILE\.openclaw\openclaw.json" "$Setup\configs\openclaw-live.json") -or $changed
}
foreach ($f in (Get-ChildItem "$env:USERPROFILE\.config\opencode\agents\*.md" -ErrorAction SilentlyContinue)) {
    $changed = (Sync-One $f.FullName "$Setup\configs\agents\$($f.Name)") -or $changed
}

if ($changed) {
    git -C $Setup add -A 2>&1 | Out-Null
    git -C $Setup -c user.email='sync@local' -c user.name='harness-sync' commit -m "harness sync: live config drift captured" 2>&1 | Out-Null
    Write-Host "Harness change detected - recorded in setup history." -ForegroundColor DarkCyan
}
