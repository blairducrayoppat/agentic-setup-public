# Opens an OpenCode coding session in a project folder you pick.
# No typing of paths needed: numbered list (recent projects first),
# Enter repeats the last project, B opens a visual folder browser.
# (Pure ASCII on purpose - this file must parse in both PowerShell editions.)
$ErrorActionPreference = 'Stop'
$ProjectsRoot = 'C:\Users\mrbla\projects'
$StateDir     = 'C:\Users\mrbla\agentic-setup\state'
$RecentFile   = Join-Path $StateDir 'recent-projects.txt'
New-Item -ItemType Directory -Force $ProjectsRoot, $StateDir | Out-Null

# ---- 1. Is a model running? ----
$ids = @()
try {
    $resp = Invoke-WebRequest 'http://127.0.0.1:8000/v3/models' -TimeoutSec 3 -UseBasicParsing
    $ids = @((($resp.Content | ConvertFrom-Json).data) | ForEach-Object { $_.id })
} catch {}
$loaded = $ids -join ', '
if (-not $loaded) {
    Write-Host ""
    Write-Host "No AI model is running yet." -ForegroundColor Yellow
    Write-Host "First double-click 'Deep Coding (30B)' or 'Everyday AI (14B)' on the Desktop,"
    Write-Host "wait for READY, then run this again."
    Read-Host "Press Enter to close"
    exit 1
}
Write-Host "Model loaded and ready: $loaded" -ForegroundColor Green
Write-Host ""

# ---- 2. Build the project list: recents first, then projects folder ----
$recents = @()
if (Test-Path $RecentFile) {
    $recents = @(Get-Content $RecentFile | Where-Object { $_ -and (Test-Path $_) })
}
$rootDirs = @(Get-ChildItem $ProjectsRoot -Directory | Sort-Object Name | ForEach-Object { $_.FullName })
$all = @()
foreach ($p in ($recents + $rootDirs)) {
    if ($all -notcontains $p) { $all += $p }
}

Write-Host "Where do you want to work?" -ForegroundColor Cyan
if ($recents.Count -gt 0) {
    Write-Host ("  [Enter] {0}   (your last project)" -f $recents[0]) -ForegroundColor Green
}
for ($i = 0; $i -lt $all.Count; $i++) {
    $tag = if ($recents -contains $all[$i]) { 'recent' } else { 'projects folder' }
    Write-Host ("  [{0}] {1}   ({2})" -f ($i+1), $all[$i], $tag)
}
Write-Host "  [N] New project (just type a name, I do the rest)"
Write-Host "  [B] Browse... (pick any folder with the mouse)"
$choice = Read-Host "Pick an option"

$target = $null
if ($choice -eq '' -and $recents.Count -gt 0) {
    $target = $recents[0]
}
elseif ($choice -match '^\d+$' -and [int]$choice -ge 1 -and [int]$choice -le $all.Count) {
    $target = $all[[int]$choice - 1]
}
elseif ($choice -match '^[Nn]$') {
    $name = Read-Host "Name for the new project (letters, numbers, dashes)"
    $name = $name -replace '[^\w\-]', '-'
    if (-not $name) { Write-Host "No name given."; Read-Host "Press Enter to close"; exit 1 }
    $target = Join-Path $ProjectsRoot $name
    New-Item -ItemType Directory -Force $target | Out-Null
    git -C $target -c init.defaultBranch=main init *> $null   # version control from day one (safety net for AI edits)
    Write-Host "Created $target (with git version control)." -ForegroundColor Green
}
elseif ($choice -match '^[Bb]$') {
    Add-Type -AssemblyName System.Windows.Forms
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = 'Pick the project folder for OpenCode'
    $dlg.SelectedPath = $ProjectsRoot
    if ($dlg.ShowDialog() -eq 'OK' -and $dlg.SelectedPath) { $target = $dlg.SelectedPath }
    else { Write-Host "Nothing picked."; Read-Host "Press Enter to close"; exit 1 }
    if ($env:OneDrive -and $target -like "$env:OneDrive*") {
        Write-Host "Heads up: that folder is inside OneDrive. Coding projects there cause sync churn" -ForegroundColor Yellow
        Write-Host "(thousands of small files) and can corrupt git state. A folder under C:\Users\mrbla\projects is safer." -ForegroundColor Yellow
        $go = Read-Host "Use it anyway? (y/N)"
        if ($go -ne 'y') { Write-Host "Cancelled."; Read-Host "Press Enter to close"; exit 1 }
    }
}
else {
    Write-Host "Not a valid option."; Read-Host "Press Enter to close"; exit 1
}

# Safety: agents never work inside BlarAI or OpenClaw state dirs (see BLUEPRINT.md)
foreach ($forbidden in @("$env:USERPROFILE\BlarAI", "$env:USERPROFILE\.openclaw")) {
    if ($target.TrimEnd('\') -like "$forbidden*") {
        Write-Host "That folder is off-limits for coding agents (BlarAI/OpenClaw have their own rules)." -ForegroundColor Red
        Read-Host "Press Enter to close"; exit 1
    }
}

# Safety: C:\Users\mrbla itself is a git repository. A project folder WITHOUT
# its own .git lets every git command (including an AI agent's) walk up and
# operate on the entire home directory. Give such folders their own repo.
if (-not (Test-Path (Join-Path $target '.git'))) {
    Write-Host ""
    Write-Host "This folder has no version control of its own. Without it, AI changes can't be" -ForegroundColor Yellow
    Write-Host "undone here - and git commands could accidentally affect your whole home folder." -ForegroundColor Yellow
    $mk = Read-Host "Set up version control in this folder now? (Y/n)"
    if ($mk -ne 'n') {
        git -C $target -c init.defaultBranch=main init *> $null
        Write-Host "Done - this folder now has its own safety net." -ForegroundColor Green
    }
}

# ---- 3. Remember the choice (most recent first, max 10) ----
$newRecents = @($target) + @($recents | Where-Object { $_ -ne $target })
$newRecents | Select-Object -First 10 | Set-Content $RecentFile

# ---- 4. Launch OpenCode there, pinned to the model that is ACTUALLY loaded ----
Write-Host ""
Write-Host "Starting OpenCode in $target ..." -ForegroundColor Cyan
Write-Host "Tips: TAB cycles agents - Build / Plan / debug / review. Use 'debug' when something is broken," -ForegroundColor Cyan
Write-Host "      'review' to judge changes. | f2 cycles models | /new = fresh task | Ctrl+C twice exits."
Set-Location $target
$known = @('coder-30b','qwen3-14b','qwen3-vl-8b')
if ($ids.Count -ge 1 -and ($known -contains $ids[0])) {
    Write-Host ("Using the model that is loaded right now: local/{0}" -f $ids[0]) -ForegroundColor Green
    opencode -m ("local/" + $ids[0])
} else {
    Write-Host "Loaded model not recognized - starting OpenCode with its default; use /models to switch." -ForegroundColor Yellow
    opencode
}
