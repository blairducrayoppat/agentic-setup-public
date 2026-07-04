# Undo AI changes in a project - no git knowledge needed.
# Shows what changed in plain language and offers two undo levels.
$ErrorActionPreference = 'Stop'
$RecentFile = 'C:\Users\mrbla\agentic-setup\state\recent-projects.txt'

# Pick a project (same list as Open Coding Chat)
$recents = @()
if (Test-Path $RecentFile) { $recents = @(Get-Content $RecentFile | Where-Object { $_ -and (Test-Path $_) }) }
if (-not $recents) { Write-Host "No known projects yet."; Read-Host "Press Enter to close"; exit 1 }
Write-Host "Which project needs undoing?" -ForegroundColor Cyan
for ($i = 0; $i -lt $recents.Count; $i++) { Write-Host ("  [{0}] {1}" -f ($i+1), $recents[$i]) }
$pick = Read-Host "Pick a number"
if ($pick -notmatch '^\d+$' -or [int]$pick -lt 1 -or [int]$pick -gt $recents.Count) { Write-Host "Invalid."; exit 1 }
$proj = $recents[[int]$pick - 1]
if (-not (Test-Path (Join-Path $proj '.git'))) { Write-Host "This folder has no version history - nothing can be undone automatically."; Read-Host "Press Enter to close"; exit 1 }

# Show state in plain language
$dirty = @(git -C $proj status --porcelain 2>$null)
Write-Host ""
Write-Host "Recent saved snapshots (newest first):" -ForegroundColor Cyan
git -C $proj log --oneline -5 2>$null | ForEach-Object { "  $_" }
Write-Host ("Unsaved changes since the last snapshot: {0} file(s)" -f $dirty.Count) -ForegroundColor $(if ($dirty.Count) {'Yellow'} else {'Green'})
$dirty | Select-Object -First 10 | ForEach-Object { "    $_" }

Write-Host ""
Write-Host "What do you want to undo?" -ForegroundColor Cyan
Write-Host "  [1] Throw away the UNSAVED changes (go back to the last snapshot)"
Write-Host "  [2] Undo the LAST SNAPSHOT (adds a new snapshot that reverses it - nothing is lost)"
Write-Host "  [Q] Cancel"
$choice = Read-Host "Pick an option"

if ($choice -eq '1') {
    if (-not $dirty) { Write-Host "There are no unsaved changes - nothing to do."; Read-Host "Press Enter to close"; exit 0 }
    Write-Host "This permanently discards the $($dirty.Count) file change(s) listed above, including any NEW files." -ForegroundColor Yellow
    $ok = Read-Host "Are you sure? (y/N)"
    if ($ok -eq 'y') {
        git -C $proj restore --staged . 2>$null
        git -C $proj restore . 2>$null
        git -C $proj clean -fd 2>$null
        Write-Host "Done - the project is back to its last snapshot." -ForegroundColor Green
    } else { Write-Host "Cancelled - nothing changed." }
}
elseif ($choice -eq '2') {
    $last = git -C $proj log --oneline -1 2>$null
    $ok = Read-Host "Reverse this snapshot: '$last'? (y/N)"
    if ($ok -eq 'y') {
        git -C $proj -c user.email='undo@local' -c user.name='undo' revert --no-edit HEAD 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { Write-Host "Done - that change has been reversed (and the reversal is itself undoable)." -ForegroundColor Green }
        else { Write-Host "Could not reverse automatically (the change may overlap with unsaved edits). Ask your assistant for help." -ForegroundColor Red }
    } else { Write-Host "Cancelled - nothing changed." }
}
else { Write-Host "Cancelled - nothing changed." }
Read-Host "Press Enter to close"
