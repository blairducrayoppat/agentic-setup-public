# run-fleet.ps1 - resilient unattended task supervisor (the "longer sessions" engine).
# Runs a QUEUE of coding tasks serially (matches the 1-active-agent design), each in
# its own worktree via new-agent-task.ps1, and survives the things that end long
# unattended runs:
#   - server health: waits for OVMS to be READY before each task (it never starts
#     or stops models itself - the watchdog/you do that); stops cleanly if the
#     server stays down so you can resume later.
#   - resume: every task that DELIVERED is recorded; re-run with -RunId <id> to continue
#     a run that was interrupted (crash, reboot, manual stop) without redoing work.
#     "Delivered" means the task's RESULT line says its work MERGED - not merely that
#     its script exited without throwing (#1075). A task that attempted and produced
#     nothing stays re-dispatchable within the run, which is what the driver's targeted
#     fix cycles need; -MaxTaskDispatches bounds how often any one task may be spent.
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
    [int]$Concurrency = 0,       # #695 best-of-N concurrency override for THIS run (0 = let new-agent-task
                                 # resolve from BLARAI_DISPATCH_CONCURRENCY + the built-in default). A queue
                                 # task's own .concurrency wins over this run-level value.
    [int]$MaxTaskDispatches = 4  # #1075: how many times ONE task id may be dispatched within a run
                                 # (RunId): the initial build plus the driver's THREE INDEPENDENT
                                 # repair budgets, each of which can target the SAME plan-task id -
                                 # the layout fix cycle, the executability fix cycle and the static
                                 # pre-gate fix cycle (swap_driver.py: _layout_fix_spent,
                                 # _exec_smoke_fix_spent, _run_static_pregate_fix_cycle).
                                 # Sizing this to ONE repair would re-create the very defect this
                                 # ticket closes, at a new threshold: the layout fix can succeed, the
                                 # app still fail to boot, and the executability repair then be refused
                                 # by the budget - surfacing as "the fix cycle did not resolve the boot
                                 # failure" when no coder ever ran. A delivering task is recorded done
                                 # immediately and never re-dispatched regardless of this budget, which
                                 # bounds only the NON-delivering path, so a repeatedly-empty task
                                 # cannot loop.
                                 # It counts DISPATCHES, not coder spawns: the retry loop below may
                                 # spawn new-agent-task.ps1 up to $maxAttempts times within ONE
                                 # ledgered dispatch on a THROWN error, so the worst-case spawn count
                                 # is this value x $maxAttempts. Both are finite; the product is the
                                 # real ceiling.
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\fleet-lib.ps1"

# The fleet ROOT (state\ + reports\ live under it). BlarAI's dispatch layer resolves the
# same root from BLARAI_FLEET_AGENTIC_SETUP_DIR (shared/fleet/dispatch.py
# resolve_fleet_root / FLEET_AGENTIC_SETUP_DIR_ENV) before it invokes this script and then
# reads SUMMARY.txt back out of it - so this script MUST honor the same variable or the two
# halves write and read different trees whenever the operator overrides the root.
$Setup     = if ($env:BLARAI_FLEET_AGENTIC_SETUP_DIR) { $env:BLARAI_FLEET_AGENTIC_SETUP_DIR } else { 'C:\Users\mrbla\agentic-setup' }
$StateDir  = Join-Path $Setup 'state'
$ReportDir = Join-Path $StateDir 'reports'
$RunsDir   = Join-Path $StateDir 'fleet-runs'

function Test-TaskDelivered {
    # #1075: did this dispatch DELIVER, i.e. did its work land on the project's main line?
    # The ONLY delivering shape new-agent-task.ps1 emits is "MERGED into your project"; the
    # other six RESULT shapes (ERRORED by a git capture fault, BLOCKED by the secret scan,
    # "NOT merged" parked on a branch, "Nothing to merge", "Nothing to merge - NO CHANGE
    # NEEDED", "Nothing to merge from the selected candidate" with a sibling capture fault)
    # all leave main untouched. Order matters: the parked line interpolates a branch/worktree
    # name that may itself contain the word "merged", so the negative shapes are tested FIRST.
    # Every non-delivering shape gets an EXPLICIT check rather than falling through to the
    # final fallback by accident (#1074's ERRORED shape used to do exactly that - it happened
    # to classify correctly only because its wording never contains "merged", which is the
    # same "a fallback decided by coincidence" class test_fleet_script_agreement.py exists to
    # catch).
    param([string]$ResultLine)
    if (-not $ResultLine) { return $false }   # no RESULT line = nothing we can call delivery
    $low = $ResultLine.ToLowerInvariant()
    if ($low -match 'errored')           { return $false }
    if ($low -match 'not merged')        { return $false }
    if ($low -match 'nothing to merge')  { return $false }
    if ($low -match 'blocked')           { return $false }
    return [bool]($low -match 'merged')
}

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
# #1075: done.txt is the TERMINAL skip list - a task lands on it when it DELIVERED, or when
# its dispatch budget is spent. dispatches.txt is the separate per-run ledger that bounds the
# retries: one line per dispatch actually spent on a task id. It is written BEFORE the coder
# runs, so a tree-killed dispatch still consumes its budget and a wedged task cannot be
# re-dispatched forever.
$DispatchList = Join-Path $RunDir 'dispatches.txt'
# #1075 O1 (the STRUCTURAL control): done.txt records the FACT that a task is terminal and never
# the REASON, and three separate point-fixes to one `if/elseif/else` proved the reason cannot be
# re-derived afterwards - it claimed "delivered" for a spent budget (F4), "budget spent" for a
# task that delivered on its last permitted dispatch (N1), and "never dispatched" for a task
# that was dispatched but whose reason went missing or whose budget was raised on resume (O1).
# Three instances of one class: THE SKIP LINE ASSERTING A REASON IT CANNOT KNOW.
#
# So the reason is written down at the moment it is true, for EVERY arrival path, and the skip
# LOOKS IT UP. There is no predicate left to get wrong, because there is no branch: an id that
# is not in the map yields an honest "not recorded", never a confident wrong answer.
$ReasonList = Join-Path $RunDir 'done-reasons.txt'
$done = @(); if (Test-Path $DoneList) { $done = @(Get-Content $DoneList | Where-Object { $_ }) }
$spent = @(); if (Test-Path $DispatchList) { $spent = @(Get-Content $DispatchList | Where-Object { $_ }) }
$doneReason = @{}
if (Test-Path $ReasonList) {
    foreach ($line in (Get-Content $ReasonList)) {
        if (-not $line) { continue }
        $parts = $line -split "`t", 2
        if ($parts.Count -eq 2) { $doneReason[$parts[0]] = $parts[1] }
    }
}

function Set-TaskDone {
    # The ONE way a task becomes terminal (#1075 O1). Fact and reason are written together, and
    # the FACT goes first on purpose: a crash between the two writes leaves the task terminal
    # with an unrecorded reason - honest, and safe, because already-merged work is never
    # re-dispatched. Writing the reason first would invert that, making the task look retriable
    # and re-running work that is already in the project. This subtree really is tree-killed:
    # the per-task ceiling and the budget watchdog both do it, which is the same hazard that
    # put the dispatch ledger's write BEFORE the coder spawns.
    param([Parameter(Mandatory)][string]$TaskId, [Parameter(Mandatory)][string]$Reason)
    Add-Content $script:DoneList $TaskId
    Add-Content $script:ReasonList ("{0}`t{1}" -f $TaskId, $Reason)
    $script:done += $TaskId
    $script:doneReason[$TaskId] = $Reason
}

Write-Journal $Journal 'RUN-START' "queue=$Queue tasks=$($tasks.Count) runid=$RunId resume_done=$($done.Count) prior_dispatches=$($spent.Count) max_task_dispatches=$MaxTaskDispatches"
Write-Host "Fleet run $RunId : $($tasks.Count) task(s). Journal: $Journal" -ForegroundColor Cyan

$deadline = (Get-Date).AddHours($OverallBudgetHours)
$results  = New-Object System.Collections.ArrayList

for ($i = 0; $i -lt $tasks.Count; $i++) {
    $t = $tasks[$i]
    $taskId = if ($t.task) { "$($t.task)" } else { "task$($i + 1)" }

    $spentForTask = @($spent | Where-Object { $_ -eq $taskId }).Count
    # #1075: the dedup guard. done.txt now means DELIVERED (or budget spent), never merely
    # "the script exited". A skip records a parseable result row + a journal line so the
    # caller sees WHY nothing ran, instead of the silent no-SUMMARY hole that read as a
    # tree-kill mystery.
    if ($done -contains $taskId) {
        # Say WHY it is on done.txt - a wrong reason here is a falsehood in the operator's
        # console, the journal AND the SUMMARY row parse_summary feeds the driver and
        # /dispatch status. This is a LOOKUP, never a deduction (#1075 O1): every writer
        # records its reason through Set-TaskDone, so there is no branch here to get wrong.
        # An id with no recorded reason says exactly that and STOPS THERE (#1075 P1). Naming a
        # cause would be the same defect one layer down: a kill between the two writes is only
        # one way to get here, and the commonest is mundane - a run directory written before
        # this change and resumed after it has no reason ledger at all.
        $why = if ($doneReason.ContainsKey($taskId)) { $doneReason[$taskId] }
               else { 'it is recorded done for this run and the reason is not recorded for it' }
        Write-Host "  [skip] $taskId ($why)" -ForegroundColor DarkGray
        Write-Journal $Journal 'TASK-SKIP-DONE' "$taskId is on done.txt - $why (dispatches=$spentForTask/$MaxTaskDispatches); not re-dispatched"
        [void]$results.Add([pscustomobject]@{ task = $taskId; outcome = "skipped ($why)"; result = "RESULT: SKIPPED - $why; it was not re-dispatched."; report = '' })
        continue
    }
    if ($spentForTask -ge $MaxTaskDispatches) {
        # The retry bound. Record it done so every later invocation skips cheaply through the
        # one list, and say so out loud - an exhausted budget is a finding, not a quiet stop.
        # The reason is recorded WITH the fact and names the budget in force when it was spent,
        # so a resume under a larger -MaxTaskDispatches still reads back what actually happened.
        # ONE string for that reason, reused by the journal, the console and the SUMMARY row:
        # this branch previously said the same fact in two independently-worded strings, which
        # is the seam a single-source design exists to close.
        $budgetReason = "its $MaxTaskDispatches-dispatch budget was spent without delivering"
        Set-TaskDone -TaskId $taskId -Reason $budgetReason
        Write-Journal $Journal 'TASK-BUDGET-SPENT' "$taskId - $budgetReason; refusing further re-dispatch"
        Write-Host "  [skip] $taskId ($budgetReason)" -ForegroundColor Yellow
        [void]$results.Add([pscustomobject]@{ task = $taskId; outcome = "skipped ($budgetReason)"; result = "RESULT: SKIPPED - $budgetReason; it was not re-dispatched."; report = '' })
        continue
    }
    if ((Get-Date) -ge $deadline) {
        Write-Journal $Journal 'BUDGET-STOP' "overall budget of $OverallBudgetHours h reached before $taskId"
        Write-Host "Overall time budget reached - stopping. Resume later with: -RunId $RunId" -ForegroundColor Yellow
        break
    }
    if (-not $t.repo -or -not $t.task -or -not $t.prompt) {
        Write-Journal $Journal 'SKIP-INVALID' "task index $($i + 1) missing repo/task/prompt"
        [void]$results.Add([pscustomobject]@{ task = $taskId; outcome = 'invalid (missing repo/task/prompt)'; result = ''; report = '' })
        # A malformed queue entry is terminal, not retriable - no coder can fix the queue.
        Set-TaskDone -TaskId $taskId -Reason 'its queue entry is malformed (missing repo/task/prompt), which no coder can fix'
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

    # #1075: consume the dispatch budget BEFORE the coder runs. Recording it afterwards would
    # leave a tree-killed dispatch (the per-task ceiling / budget watchdog kills this whole
    # subtree) costing nothing, so a wedging task could be re-dispatched without end.
    Add-Content $DispatchList $taskId; $spent += $taskId
    $dispatchNo = $spentForTask + 1
    Write-Journal $Journal 'TASK-START' "$taskId repo=$($t.repo) model=$model dispatch=$dispatchNo/$MaxTaskDispatches"
    Write-Host ("[{0}/{1}] {2} (dispatch {3}/{4})" -f ($i + 1), $tasks.Count, $taskId, $dispatchNo, $MaxTaskDispatches) -ForegroundColor Cyan
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
    # #1075: the guard's predicate is DELIVERY, not a clean exit. The RESULT line scraped just
    # above is the discriminator the driver itself keys on, and it was already being logged
    # beside the outcome and then thrown away - "TASK-END | add-card outcome=processed |
    # RESULT: Nothing to merge." went on done.txt, which made every empty task permanently
    # unrepairable inside its own run and refused the layout fix cycle that B4 needed.
    $delivered = (($outcome -eq 'processed') -and (Test-TaskDelivered $resultLine))
    Write-Journal $Journal 'TASK-END' "$taskId outcome=$outcome delivered=$delivered | $resultLine"
    [void]$results.Add([pscustomobject]@{ task = $taskId; outcome = $outcome; result = $resultLine; report = $(if ($report) { $report.FullName } else { '' }) })
    if ($delivered) {
        # It landed on main. THIS is what the guard exists to protect: never spend a coder
        # re-running work that is already in the project.
        Set-TaskDone -TaskId $taskId -Reason 'it already delivered'
    }
    else {
        $left = $MaxTaskDispatches - $dispatchNo
        Write-Journal $Journal 'TASK-RETRIABLE' "$taskId did not deliver ($(if ($resultLine) { $resultLine } else { 'no RESULT line' })); not marked done so a targeted fix cycle or a resume (-RunId) can retry it ($left dispatch(es) left)"
    }
}

# ---- Morning summary ----
$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine("FLEET RUN $RunId  ($(Get-Date -Format 'yyyy-MM-dd HH:mm'))")
[void]$sb.AppendLine("Queue: $Queue")
[void]$sb.AppendLine("Processed this run: $($results.Count) of $($tasks.Count) queued")

# DoD row 8 clause 3: "at any moment the operator can be told how much of the PRODUCT exists".
#
# The line above is true and answers a different question. Its denominator is the one-task
# QUEUE BUFFER, so a mid-build run prints "Processed this run: 1 of 1 queued" — which reads
# like completion to anyone who did not write it. On 2026-08-15 that line sat in SUMMARY.txt
# while the site was four tasks of seven: a real number about the wrong population, which is
# the #1231 shape aimed at the operator instead of at a grader.
#
# Both figures were already on disk and neither was ever put together: done.txt is the
# terminal-task list and decompose-diagnostics.json carries the plan's own task count.
$planned = $null
$diagPath = Join-Path $RunDir 'decompose-diagnostics.json'
if (Test-Path $diagPath) {
    try {
        $diag = Get-Content $diagPath -Raw | ConvertFrom-Json
        if ($null -ne $diag.cleaned_task_count) { $planned = [int]$diag.cleaned_task_count }
    } catch { $planned = $null }
}
$built = if (Test-Path $DoneList) { @(Get-Content $DoneList | Where-Object { $_.Trim() }).Count } else { 0 }
if ($null -ne $planned -and $planned -gt 0) {
    $pct = [math]::Round(100.0 * $built / $planned)
    [void]$sb.AppendLine("Product: $built of $planned planned tasks built ($pct%)")
} else {
    # NAMED, never omitted. A missing progress line reads as "no progress worth reporting";
    # this says the plan could not be read, which is a different and checkable claim.
    [void]$sb.AppendLine("Product: $built task(s) built; the plan's task count could not be read from decompose-diagnostics.json, so how much of the product exists is UNKNOWN")
}
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
