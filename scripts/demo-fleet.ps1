# demo-fleet.ps1 - one-command demo of an unattended agent task running through ALL
# the safety gates (timeout -> secret-scan -> tests -> build/lint verify -> review ->
# merge or park). It SEEDS a known-good test and asks the agent to write code that
# passes it (TDD-style) - the reliable way to get a clean MERGE from a small model,
# and a good template for how to phrase your own fleet tasks.
# Throwaway + repeatable. Needs a model loaded first (Control Panel -> 3).
#   .\demo-fleet.ps1
$ErrorActionPreference = 'Continue'
. "$PSScriptRoot\fleet-lib.ps1"

if (-not (Get-LoadedModelId)) {
    Write-Host "No AI model is loaded yet." -ForegroundColor Yellow
    Write-Host "Open the AI Control Panel, press 3 (Everyday 14B), wait for READY, then run this again." -ForegroundColor Yellow
    return
}

$projects = Join-Path ([Environment]::GetFolderPath('UserProfile')) 'projects'
$proj = Join-Path $projects 'fleet-demo'
$wt   = Join-Path $projects 'fleet-demo-hello'

# Repeatable: clear any leftovers, then re-seed a fresh project with a known-good
# test the agent must satisfy (and NO greet.py, so the agent has to write it).
if (Test-Path (Join-Path $proj '.git')) {
    git -C $proj worktree remove $wt --force 2>$null
    git -C $proj branch -D agent/hello 2>$null
}
New-Item -ItemType Directory -Force (Join-Path $proj 'tests') | Out-Null
Remove-Item (Join-Path $proj 'greet.py') -ErrorAction SilentlyContinue
@(
    'from greet import greet',
    '',
    '',
    'def test_greet():',
    '    assert greet("World") == "Hello, World!"'
) | Set-Content (Join-Path $proj 'tests\test_greet.py') -Encoding UTF8
@('__pycache__/', '*.pyc', '.pytest_cache/') | Set-Content (Join-Path $proj '.gitignore') -Encoding UTF8
if (-not (Test-Path (Join-Path $proj '.git'))) { git -C $proj init -q }
git -C $proj add -A 2>$null
git -C $proj -c user.email=demo@local -c user.name=demo commit -q -m "seed: failing test for greet" 2>$null

# Dedicated demo queue so we never touch your real fleet-queue.json.
$q = 'C:\Users\mrbla\agentic-setup\state\demo-queue.json'
Remove-Item $q -ErrorAction SilentlyContinue
& "$PSScriptRoot\add-fleet-task.ps1" -Repo $proj -Task hello -Queue $q `
    -Prompt "There is a failing test at tests/test_greet.py. Create greet.py at the project root with a function greet(name) so the test passes - it expects greet('World') to return the string 'Hello, World!'. Then run the tests to confirm." | Out-Null

Write-Host ""
Write-Host "Running one task through the fleet (this calls the AI model; about 1-5 min)..." -ForegroundColor Cyan
& "$PSScriptRoot\run-fleet.ps1" -Queue $q -MaxRunMinutes 8 -MaxReviewMinutes 5

Write-Host ""
Write-Host "Done. If the result above says MERGED, see what the AI built:" -ForegroundColor Cyan
Write-Host ("  Get-Content `"{0}\greet.py`"" -f $proj) -ForegroundColor Gray
