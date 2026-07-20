#requires -Version 7.0
<#
.SYNOPSIS
  verify-battery-task-settings.ps1 (#833) - fail-loud conformance check that the
  nightly battery scheduled task's SETTINGS still cover the runner's own budgets.

.DESCRIPTION
  The durable control for the PT10H incident (2026-07-11): the scheduled task's
  ExecutionTimeLimit (then PT10H) tree-killed the battery runner at 10:00:00, three
  minutes before the final job finished. That ceiling is an OUTER wall-clock window
  that must COVER the runner's INNER per-job budgets, or it silently preempts the
  runner's own completion/abort logic (the lesson-221 (window, budget) pair the
  ceiling belongs to; the pair had no owner because the ceiling lives in Task
  Scheduler, invisible to shared/timeout_registry.py - lesson 217).

  This script reads the LIVE scheduled task and fails loud (exit 1, naming each
  drift) if any of these no longer holds:
    T1  the task EXISTS (registered).
    T2  it is not Disabled (a disabled battery task is a silent no-run).
    T3  it has a DAILY trigger at the expected hour (23:00).
    T4  ExecutionTimeLimit >= the runner's derived RUN-PHASE floor (or is unlimited).
    T5  RestartCount is as-designed (0 - a restart mid-run would collide/double-run
        a non-restart-safe campaign).
    T6  MultipleInstances is IgnoreNew (a night overrunning past the next 23:00
        trigger must not double-start a second concurrent run).

  T4's required minimum is DERIVED, never hard-coded: it calls the runner's own
  helper (tools.dispatch_harness.battery_execution_limit) which computes
  sum(per-job budget) + per-job re-ensure overhead + fixed overhead from the SAME
  constants the runner uses (swap_run_budget_s, each active card's run_budget_s, the
  campaign job set), so this check can never rot the way a hand-typed PT16H did.

  SCOPE of T4 (necessary, not sufficient): the derived floor covers the RUN phase
  only. It deliberately EXCLUDES the launcher's 23:00->04:00 dispatch/lean admission
  wait, which is independently bounded by its own 04:00 self-exit cutoff. So a T4
  PASS means the ceiling covers a full run once it starts; a night that admits very
  late could still be preempted even at the floor - the lever there is fewer /
  re-grained jobs, not a bigger ceiling (a full no-preempt bound would exceed the
  24 h daily cadence). T6 is why a late overrun is nonetheless safe: the next
  trigger is ignored, not run in parallel.

  READ-ONLY: only Get-ScheduledTask and one read-only python derivation call. It
  never registers, unregisters, enables, disables, or otherwise mutates the task.

  Self-test (no mutation, box-state.ps1 B2/B3 style): -RequiredMinOverrideS <n>
  substitutes the derived minimum, so the PASS path (a small n the live ceiling
  clears) and the FAIL path (a large n it does not) can both be proven without
  touching the production task.

  Run it normally ( .\verify-battery-task-settings.ps1 ). Exit 0 iff every check passes.

.PARAMETER RequiredMinOverrideS
  >0: use this value as T4's required minimum instead of deriving it (self-test).
  0 (default): derive from the runner via the .venv python helper.
#>
[CmdletBinding()]
param(
    [string]$TaskPath = '\BlarAI\',
    [string]$TaskName = 'BlarAI-M2-Battery-Nightly',
    [string]$BlarRepo = $(if ($env:BLARAI_REPO) { $env:BLARAI_REPO } else { 'C:\Users\mrbla\blarai' }),
    [double]$RequiredMinOverrideS = 0,
    [int]$ExpectedTriggerHour = 23,
    [int]$ExpectedRestartCount = 0,
    [string]$ExpectedMultipleInstances = 'IgnoreNew'
)
$ErrorActionPreference = 'Stop'
# Branch on $LASTEXITCODE / a parsed integer, never on a thrown native error:
# make native-command exit handling deterministic regardless of the host default.
$PSNativeCommandUseErrorActionPreference = $false

$script:Pass = 0
$script:Fail = 0
function Check([string]$name, [bool]$ok) {
    if ($ok) { $script:Pass++; Write-Host "  [PASS] $name" -ForegroundColor Green }
    else     { $script:Fail++; Write-Host "  [FAIL] $name" -ForegroundColor Red }
}
function Section($t) { Write-Host ''; Write-Host "== $t ==" -ForegroundColor Cyan }

Write-Host '============ BATTERY TASK-SETTINGS CONFORMANCE (#833) ============' -ForegroundColor Cyan
Write-Host ("task {0}{1}  |  {2}" -f $TaskPath, $TaskName, (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))

# ---- derive the required minimum (or use the self-test override) -------------
Section 'derive required run-phase floor (from the runner constants)'
$requiredS = $null
if ($RequiredMinOverrideS -gt 0) {
    $requiredS = $RequiredMinOverrideS
    Write-Host ("  self-test override: required minimum = {0:N0}s ({1:N1}h)" -f $requiredS, ($requiredS / 3600))
}
else {
    $py = Join-Path $BlarRepo '.venv\Scripts\python.exe'
    if (-not (Test-Path $py)) {
        Check "derive required minimum (found .venv python at $py)" $false
    }
    else {
        Push-Location $BlarRepo
        try {
            # Keep stderr for the diagnostic log (2>&1), but parse only the LAST
            # non-empty line: an import-time warning must not corrupt the integer.
            $raw = & $py -m tools.dispatch_harness.battery_execution_limit --seconds-only 2>&1
            $code = $LASTEXITCODE
        }
        catch {
            # A throw (e.g. if the host forces native errors to terminate) is a
            # derivation failure, not a pass: fail-closed.
            $raw = $_.Exception.Message
            $code = -1
        }
        finally { Pop-Location }
        $lines = @($raw | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
        $lastLine = if ($lines.Count -gt 0) { $lines[-1] } else { '' }
        $parsed = 0
        if ($code -eq 0 -and [int]::TryParse($lastLine, [ref]$parsed) -and $parsed -gt 0) {
            $requiredS = [double]$parsed
            Write-Host ("  derived required run-phase floor = {0:N0}s ({1:N1}h)" -f $requiredS, ($requiredS / 3600))
        }
        else {
            # Fail-closed: a derivation we cannot trust must not silently pass T4.
            Check "derive required minimum (helper exit=$code, output='$($lines -join ' | ')')" $false
        }
    }
}

# ---- fetch the live task -----------------------------------------------------
Section 'T1  the scheduled task exists'
$task = Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction SilentlyContinue
Check "T1 task $TaskPath$TaskName is registered" ($null -ne $task)
if ($null -eq $task) {
    Write-Host ''
    Write-Host "RESULT: $($script:Pass) passed, $($script:Fail) failed (task absent - cannot check settings)" -ForegroundColor Red
    Write-Host '=================================================================' -ForegroundColor Cyan
    exit 1
}

Section 'T2  the task is enabled (not Disabled)'
Check "T2 State is '$($task.State)' (not Disabled)" ($task.State -ne 'Disabled')

Section "T3  a daily trigger at ${ExpectedTriggerHour}:00"
$dailyAtHour = @($task.Triggers | Where-Object {
        $_.CimClass.CimClassName -eq 'MSFT_TaskDailyTrigger' -and
        $_.StartBoundary -and (([datetime]$_.StartBoundary).Hour -eq $ExpectedTriggerHour) -and
        (([datetime]$_.StartBoundary).Minute -eq 0)
    })
$trigDesc = ($task.Triggers | ForEach-Object {
        $sb = if ($_.StartBoundary) { ([datetime]$_.StartBoundary).ToString('HH:mm') } else { '??:??' }
        "$($_.CimClass.CimClassName)@$sb"
    }) -join ', '
Check "T3 has a daily trigger at ${ExpectedTriggerHour}:00 (triggers: $trigDesc)" ($dailyAtHour.Count -ge 1)

Section 'T4  ExecutionTimeLimit covers the runner run-phase floor'
$etlRaw = $task.Settings.ExecutionTimeLimit
if ([string]::IsNullOrWhiteSpace($etlRaw) -or $etlRaw -eq 'PT0S') {
    # Task Scheduler: no time limit set == unlimited == covers any finite floor.
    Write-Host "  ExecutionTimeLimit = '$etlRaw' -> UNLIMITED (no ceiling; covers by definition)" -ForegroundColor Yellow
    if ($null -ne $requiredS) {
        Check "T4 ExecutionTimeLimit (unlimited) >= required run-phase floor $([int]$requiredS)s" $true
    }
}
else {
    $etlS = [System.Xml.XmlConvert]::ToTimeSpan($etlRaw).TotalSeconds
    if ($null -eq $requiredS) {
        Write-Host "  ExecutionTimeLimit = $etlRaw ($([int]$etlS)s) but the required floor could not be derived (see above)." -ForegroundColor Red
    }
    else {
        $ok = $etlS -ge $requiredS
        $delta = $etlS - $requiredS
        Write-Host ("  ExecutionTimeLimit = {0} ({1:N0}s / {2:N1}h)  vs required run-phase floor {3:N0}s / {4:N1}h  (headroom {5:N0}s / {6:N1}h; excludes the 23:00->04:00 admission wait)" -f `
                $etlRaw, $etlS, ($etlS / 3600), $requiredS, ($requiredS / 3600), $delta, ($delta / 3600)) -ForegroundColor $(if ($ok) { 'Green' } else { 'Red' })
        Check "T4 ExecutionTimeLimit ($([int]$etlS)s) >= required run-phase floor ($([int]$requiredS)s; per-job budget sum, excludes admission wait)" $ok
    }
}

Section "T5  RestartCount is as-designed ($ExpectedRestartCount)"
$rc = [int]$task.Settings.RestartCount
Check "T5 RestartCount is $rc (expected $ExpectedRestartCount; a restart would collide a non-restart-safe run)" ($rc -eq $ExpectedRestartCount)

Section "T6  MultipleInstances prevents concurrent runs ($ExpectedMultipleInstances)"
$mi = [string]$task.Settings.MultipleInstances
Check "T6 MultipleInstances is '$mi' (expected $ExpectedMultipleInstances; a night overrunning past the next ${ExpectedTriggerHour}:00 must not double-start)" ($mi -eq $ExpectedMultipleInstances)

# ---- verdict -----------------------------------------------------------------
Write-Host ''
if ($script:Fail -eq 0) {
    Write-Host "RESULT: $($script:Pass) passed, 0 failed - the battery task settings conform." -ForegroundColor Green
    Write-Host '=================================================================' -ForegroundColor Cyan
    exit 0
}
else {
    Write-Host "RESULT: $($script:Pass) passed, $($script:Fail) FAILED - the battery task settings have DRIFTED (see [FAIL] lines)." -ForegroundColor Red
    Write-Host '=================================================================' -ForegroundColor Cyan
    exit 1
}
