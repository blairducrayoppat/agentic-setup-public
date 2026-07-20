# add-fleet-task.ps1 - append a task to the overnight fleet queue (novice-friendly).
#   .\add-fleet-task.ps1 -Repo C:\Users\mrbla\projects\myapp -Task fix-logging `
#       -Prompt "Fix the noisy logging and add a test."
# Then run them all unattended with run-fleet.ps1.
param(
    [Parameter(Mandatory)][string]$Repo,
    [Parameter(Mandatory)][string]$Task,
    [Parameter(Mandatory)][string]$Prompt,
    [string]$Model = '',
    [ValidateSet('', 'simple', 'moderate', 'complex')][string]$Complexity = '',  # coarse upstream label -> scales the pass budgets
    # INCREMENT-1 (#675): the 14B's coarse platform label -> drives the curated build profile (scaffold +
    # structural contract). Validated to the surface enum; absent/unknown -> today's keyword heuristic.
    [ValidateSet('', 'desktop-gui', 'web', 'web-static', 'mobile', 'command-line', 'automation', 'library', 'unknown')][string]$Surface = '',
    # INCREMENT-1 (#675): optional language refinement for the ambiguous surfaces (command-line, library).
    [ValidateSet('', 'python', 'dotnet', 'node', 'cpp', 'powershell')][string]$LanguageHint = '',
    # #698: the remaining rich PLAN fields compile_prompts stamps onto each task dict — the VLM-critique inputs
    # and the #690 shared acceptance oracle. run-fleet.ps1 already READS these queue keys and forwards them to
    # new-agent-task.ps1; add-fleet-task now PERSISTS them so the deterministic enqueue path is field-complete
    # (the live swap path already carries them by writing the whole task dict). Absent -> omitted (back-compat).
    [string]$Goal = '',                 # plain-English product goal (queue key: goal) -> post-merge VLM critique
    [string]$VisualCriteriaJson = '',   # visual-tier criterion texts, JSON array string (queue key: visual_criteria_json)
    [string]$AcceptanceTestCode = '',   # the #690 spec-derived acceptance ORACLE body (queue key: acceptance_test_code)
    [string]$AcceptanceTestPath = '',   # repo-relative path the oracle is seeded at (queue key: acceptance_test_path)
    [string]$Queue = 'C:\Users\mrbla\agentic-setup\state\fleet-queue.json'
)
$ErrorActionPreference = 'Stop'

if (-not (Test-Path (Join-Path $Repo '.git'))) {
    Write-Host "WARNING: $Repo is not a git repo yet. The fleet will refuse it - use 'Open Coding Chat' once to create the project (it git-inits safely)." -ForegroundColor Yellow
}

$list = @()
if (Test-Path $Queue) {
    try { $list = @(Get-Content $Queue -Raw -Encoding UTF8 | ConvertFrom-Json) }
    catch { Write-Host "ERROR: existing queue '$Queue' is invalid JSON. Fix or delete it first (not adding, to avoid clobbering your other tasks)." -ForegroundColor Red; exit 1 }
}
$item = [ordered]@{ repo = $Repo; task = $Task; prompt = $Prompt }
if ($Model) { $item.model = $Model }
if ($Complexity) { $item.complexity = $Complexity }
if ($Surface) { $item.surface = $Surface }                 # INCREMENT-1 (#675): persist the platform label (run-fleet forwards it)
if ($LanguageHint) { $item.language_hint = $LanguageHint }  # INCREMENT-1 (#675): persist the optional language refinement
if ($Goal) { $item.goal = $Goal }                          # #698: persist the VLM-critique goal (run-fleet reads $t.goal)
if ($VisualCriteriaJson) { $item.visual_criteria_json = $VisualCriteriaJson }  # #698: run-fleet reads $t.visual_criteria_json
if ($AcceptanceTestCode) { $item.acceptance_test_code = $AcceptanceTestCode }  # #698: run-fleet reads $t.acceptance_test_code
if ($AcceptanceTestPath) { $item.acceptance_test_path = $AcceptanceTestPath }  # #698: run-fleet reads $t.acceptance_test_path
$list += [pscustomobject]$item

$dir = Split-Path $Queue -Parent
if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
# Wrap in @() on write so a single-task queue still serializes as a JSON array.
ConvertTo-Json -Depth 5 -InputObject @($list) | Set-Content $Queue -Encoding UTF8
Write-Host "Added '$Task' to the fleet queue ($($list.Count) task(s) total)." -ForegroundColor Green
Write-Host "Queue: $Queue" -ForegroundColor Cyan
Write-Host "Run them unattended with:  run-fleet.ps1" -ForegroundColor Cyan
