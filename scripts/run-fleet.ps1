# run-fleet.ps1 - resilient unattended task supervisor (the "longer sessions" engine).
# Runs a QUEUE of coding tasks serially (matches the 1-active-agent design), each in
# its own worktree via new-agent-task.ps1, and survives the things that end long
# unattended runs:
#   - server health: waits for OVMS to be READY before each task (it never starts
#     or stops models itself - the watchdog/you do that); stops cleanly if the
#     server stays down so you can resume later.
#   - resume: every processed task is recorded; re-run with -RunId <id> to continue
#     a run that was interrupted (crash, reboot, manual stop) without redoing work.
#   - time budget: stops gracefully at -OverallBudgetHours and is resumable.
#   - journal: every step is appended to a readable journal; a morning SUMMARY.txt
#     aggregates every task outcome.
# Per-task wall-clock caps, secret-scan, verify gate, and loop detection all come
# from new-agent-task.ps1 (which this calls).
#
#   .\run-fleet.ps1                                  # run the default queue
#   .\run-fleet.ps1 -Queue C:\...\my-queue.json
#   .\run-fleet.ps1 -RunId 20260614-2200             # RESUME an interrupted run
param(
    [string]$Queue = 'C:\Users\mrbla\agentic-setup\state\fleet-queue.json',
    [int]$MaxRunMinutes = 60,    # #682: generous hard ceiling (idle-detection is the fast kill)
    [int]$MaxReviewMinutes = 10,
    [int]$IdleTimeoutSec = 240,  # #682: kill a coder that makes NO progress for this long (stuck)
    [double]$OverallBudgetHours = 8,
    [int]$ServerWaitMinutes = 10,
    [string]$RunId = '',
    [int]$Concurrency = 0        # #695 best-of-N concurrency override for THIS run (0 = let new-agent-task
                                 # resolve from BLARAI_DISPATCH_CONCURRENCY + the built-in default). A queue
                                 # task's own .concurrency wins over this run-level value.
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\fleet-lib.ps1"

$Setup     = 'C:\Users\mrbla\agentic-setup'
$StateDir  = Join-Path $Setup 'state'
$ReportDir = Join-Path $StateDir 'reports'
$RunsDir   = Join-Path $StateDir 'fleet-runs'

if (-not (Test-Path $Queue)) {
    throw "Queue file not found: $Queue`nCreate one (a JSON array of {repo,task,prompt,model?}) - see configs\fleet-queue.sample.json, or use add-fleet-task.ps1."
}
try {
    $tasks = @(Get-Content $Queue -Raw -Encoding UTF8 | ConvertFrom-Json)
} catch {
    throw "Could not parse the queue file '$Queue' as JSON. It must be a [] array of {repo,task,prompt,model?} objects (see configs\fleet-queue.sample.json). Parser said: $($_.Exception.Message)"
}
if ($tasks.Count -eq 0) { Write-Host "Queue is empty - nothing to do." -ForegroundColor Yellow; exit 0 }

if (-not $RunId) { $RunId = Get-Date -Format 'yyyyMMdd-HHmmss' }
$RunDir = Join-Path $RunsDir $RunId
New-Item -ItemType Directory -Force $RunDir | Out-Null
$Journal  = Join-Path $RunDir 'journal.log'
$DoneList = Join-Path $RunDir 'done.txt'
$done = @(); if (Test-Path $DoneList) { $done = @(Get-Content $DoneList | Where-Object { $_ }) }

Write-Journal $Journal 'RUN-START' "queue=$Queue tasks=$($tasks.Count) runid=$RunId resume_done=$($done.Count)"
Write-Host "Fleet run $RunId : $($tasks.Count) task(s). Journal: $Journal" -ForegroundColor Cyan

$deadline = (Get-Date).AddHours($OverallBudgetHours)
$results  = New-Object System.Collections.ArrayList

for ($i = 0; $i -lt $tasks.Count; $i++) {
    $t = $tasks[$i]
    $taskId = if ($t.task) { "$($t.task)" } else { "task$($i + 1)" }

    if ($done -contains $taskId) { Write-Host "  [skip] $taskId (already processed in this run)" -ForegroundColor DarkGray; continue }
    if ((Get-Date) -ge $deadline) {
        Write-Journal $Journal 'BUDGET-STOP' "overall budget of $OverallBudgetHours h reached before $taskId"
        Write-Host "Overall time budget reached - stopping. Resume later with: -RunId $RunId" -ForegroundColor Yellow
        break
    }
    if (-not $t.repo -or -not $t.task -or -not $t.prompt) {
        Write-Journal $Journal 'SKIP-INVALID' "task index $($i + 1) missing repo/task/prompt"
        [void]$results.Add([pscustomobject]@{ task = $taskId; outcome = 'invalid (missing repo/task/prompt)'; result = ''; report = '' })
        Add-Content $DoneList $taskId
        continue
    }

    # Ensure the model server is READY before spending a task on it. We never start
    # or stop models here (RAM/safety) - we wait for the running server/watchdog.
    $waitDeadline = (Get-Date).AddMinutes($ServerWaitMinutes)
    $model = Get-LoadedModelId
    if (-not $model) {
        Write-Host "  model server not ready - waiting up to $ServerWaitMinutes min (to start one: start-llm.ps1 -Model coder-30b)..." -ForegroundColor Yellow
    }
    while (-not $model -and (Get-Date) -lt $waitDeadline) {
        Start-Sleep -Seconds 15
        $model = Get-LoadedModelId
    }
    if (-not $model) {
        Write-Journal $Journal 'SERVER-DOWN' "no model ready after $ServerWaitMinutes min; stopping (resume with -RunId $RunId)"
        Write-Host "Model server not ready after $ServerWaitMinutes min. Stopping. Resume later with: -RunId $RunId" -ForegroundColor Red
        break
    }

    Write-Journal $Journal 'TASK-START' "$taskId repo=$($t.repo) model=$model"
    Write-Host ("[{0}/{1}] {2}" -f ($i + 1), $tasks.Count, $taskId) -ForegroundColor Cyan
    $safeTask  = $taskId -replace '[^\w\-]', '-'
    $repoName  = Split-Path $t.repo -Leaf
    $startTime = Get-Date
    $outcome = ''; $attempts = 0; $maxAttempts = 2
    while ($attempts -lt $maxAttempts) {
        $attempts++
        try {
            $params = @{ Repo = $t.repo; Task = $taskId; Prompt = $t.prompt; MaxRunMinutes = $MaxRunMinutes; MaxReviewMinutes = $MaxReviewMinutes; IdleTimeoutSec = $IdleTimeoutSec }
            if ($t.model) { $params.Model = $t.model }
            if ($t.complexity) { $params.Complexity = $t.complexity }  # forward the upstream coarse label (scales the pass budgets)
            if ($t.surface) { $params.Surface = $t.surface }           # INCREMENT-1 (#675): forward the 14B's coarse platform label (drives the curated build profile)
            if ($t.language_hint) { $params.LanguageHint = $t.language_hint }  # INCREMENT-1 (#675): optional language refinement for the ambiguous surfaces
            if ($t.goal) { $params.Goal = $t.goal }                     # UC-010 Phase 3: plain-English product goal for the post-merge VLM critique
            if ($t.visual_criteria_json) { $params.VisualCriteriaJson = $t.visual_criteria_json }  # UC-010 Phase 3: visual-tier criterion texts (JSON array string); gates the critique hook
            if ($t.acceptance_test_code) { $params.AcceptanceTestCode = $t.acceptance_test_code }  # #690: the shared spec-derived ORACLE (python single-feature); seeded + protected + restored before the gate
            if ($t.acceptance_test_path) { $params.AcceptanceTestPath = $t.acceptance_test_path }  # #690: repo-relative path the oracle is seeded to
            if ($t.canonical_package) { $params.CanonicalPackage = $t.canonical_package }  # #790 sub-task 5: the job-oracle contract's ONE top-level package -- the python skeleton seeds under this name (no generic app/ twin beside the oracle's package)
            if ($Concurrency -gt 0) { $params.Concurrency = $Concurrency }  # #695: run-level best-of-N concurrency override
            if ($t.concurrency) { $params.Concurrency = $t.concurrency }    # #695: a queue task's own concurrency wins over the run-level value
            # GO-LIVE (2026-06-25, operator-approved): the VLM design-critique + auto-FIX loop is LIVE.
            # The [6/6] hook STILL self-gates on visual_criteria_json being present, so a non-visual task
            # (no visual criteria stamped upstream) is an automatic no-op -- only visual tasks get the design
            # loop. The coder CODE loop ([4/5] review->FIX->re-review) is always-on and independent. The
            # critique runs POST-MERGE and fail-soft, so a critique/loop error can never change a task's RESULT.
            $params.EnableVisualCritique = $true
            & "$PSScriptRoot\new-agent-task.ps1" @params
            $outcome = 'processed'
            break
        } catch {
            Write-Journal $Journal 'TASK-ERROR' "$taskId attempt $attempts : $($_.Exception.ToString())"
            $outcome = "error: $($_.Exception.Message)"
            if ($attempts -lt $maxAttempts) { Start-Sleep -Seconds 10 }
        }
    }

    # Pull the RESULT line from this task's freshest report for the summary.
    $report = Get-ChildItem $ReportDir -Filter "$repoName-$safeTask-*.txt" -ErrorAction SilentlyContinue |
              Where-Object { $_.LastWriteTime -ge $startTime.AddSeconds(-10) } |
              Sort-Object LastWriteTime -Descending | Select-Object -First 1
    $resultLine = ''
    if ($report) {
        $rl = Select-String -Path $report.FullName -Pattern '^RESULT:' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($rl) { $resultLine = $rl.Line }
    }
    Write-Journal $Journal 'TASK-END' "$taskId outcome=$outcome | $resultLine"
    [void]$results.Add([pscustomobject]@{ task = $taskId; outcome = $outcome; result = $resultLine; report = $(if ($report) { $report.FullName } else { '' }) })
    if ($outcome -eq 'processed') { Add-Content $DoneList $taskId }
    else { Write-Journal $Journal 'TASK-RETRIABLE' "$taskId errored; not marked done so a resume (-RunId) retries it" }
}

# ---- Morning summary ----
$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine("FLEET RUN $RunId  ($(Get-Date -Format 'yyyy-MM-dd HH:mm'))")
[void]$sb.AppendLine("Queue: $Queue")
[void]$sb.AppendLine("Processed this run: $($results.Count) of $($tasks.Count) queued")
[void]$sb.AppendLine('')
foreach ($r in $results) {
    [void]$sb.AppendLine("- $($r.task): $($r.outcome)")
    if ($r.result) { [void]$sb.AppendLine("    $($r.result)") }
    if ($r.report) { [void]$sb.AppendLine("    full report: $($r.report)") }
}
$SummaryPath = Join-Path $RunDir 'SUMMARY.txt'
Set-Content $SummaryPath $sb.ToString()
Write-Journal $Journal 'RUN-END' "processed=$($results.Count)"
Write-Host ''
Write-Host $sb.ToString()
Write-Host "Summary saved: $SummaryPath" -ForegroundColor Cyan
