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
    T7  the daily trigger's EndBoundary equals campaign end_date + 1 day at
        00:00:00 - the calendar cutoff is TWO deliberately independent locks
        (script preflight + OS trigger) and this check owns their consistency.
        The 2026-07-19 divergence (#972): end_date extended to 2026-08-11,
        EndBoundary left at 2026-07-22T00:00:00 - the campaign LOOKED extended
        and was not; the battery would have silently stopped after the 07-21
        night (no error, no log, no report).

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

  READ-ONLY: only Get-ScheduledTask, one campaign-config read, and one read-only
  python derivation call. It never registers, unregisters, enables, disables, or
  otherwise mutates the task.

  Self-test (no mutation, box-state.ps1 B2/B3 style): -RequiredMinOverrideS <n>
  substitutes the derived minimum, so the PASS path (a small n the live ceiling
  clears) and the FAIL path (a large n it does not) can both be proven without
  touching the production task. For T7, -EndDateOverride/-EndBoundaryOverride
  inject a synthetic (end_date, EndBoundary) pair ('none' = that side absent;
  both must be given together so the self-test never mixes synthetic and live
  state), so the divergence-FAIL and match-PASS paths are both provable without
  touching the task or the campaign file.

  Run it normally ( .\verify-battery-task-settings.ps1 ). Exit 0 iff every check passes.

.PARAMETER RequiredMinOverrideS
  >0: use this value as T4's required minimum instead of deriving it (self-test).
  0 (default): derive from the runner via the .venv python helper.

.PARAMETER CampaignConfig
  The campaign config T7 reads end_date from. The default mirrors the runner's
  own -CampaignConfig default (run-battery-night.ps1): ..\state\battery-campaign.json
  relative to this script - the same file lock 1 actually reads at 23:00. NOTE:
  the file is live state, not tracked - from a worktree, point this at the live
  checkout's copy.

.PARAMETER EndDateOverride
  T7 self-test: inject a synthetic campaign end_date (yyyy-MM-dd, or 'none' for
  an absent end_date). Must be given together with -EndBoundaryOverride.
  '' (default): read the live pair.

.PARAMETER EndBoundaryOverride
  T7 self-test: inject a synthetic trigger EndBoundary (a datetime string, or
  'none' for a trigger without one). Must be given together with -EndDateOverride.
  '' (default): read the live pair.
#>
[CmdletBinding()]
param(
    [string]$TaskPath = '\BlarAI\',
    [string]$TaskName = 'BlarAI-M2-Battery-Nightly',
    [string]$BlarRepo = $(if ($env:BLARAI_REPO) { $env:BLARAI_REPO } else { 'C:\Users\mrbla\blarai' }),
    [double]$RequiredMinOverrideS = 0,
    [int]$ExpectedTriggerHour = 23,
    [int]$ExpectedRestartCount = 0,
    [string]$ExpectedMultipleInstances = 'IgnoreNew',
    [string]$CampaignConfig = "$PSScriptRoot\..\state\battery-campaign.json",
    [string]$EndDateOverride = '',
    [string]$EndBoundaryOverride = ''
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

Section 'T7  campaign end_date and trigger EndBoundary agree (two-lock calendar cutoff)'
# The 2026-07-19 divergence (#972): the LA extended the campaign three weeks
# (end_date -> 2026-08-11) but the trigger's OS-level EndBoundary stayed
# 2026-07-22T00:00:00 - the campaign LOOKED extended and was not; the trigger
# would simply have stopped firing after the 07-21 night, no error, no log, no
# report. The cutoff is TWO deliberate, independent locks (the preflight's
# end_date self-unregister, run-battery-night.ps1; and the trigger EndBoundary,
# pure Task Scheduler) - this check owns their consistency. Convention (verified
# against the preflight by boundary simulation): end_date is the LAST NIGHT THAT
# RUNS - the preflight compares (Get-Date).Date (midnight-truncated) with -gt, so
# end_date's own 23:00 run still fires; EndBoundary must therefore be
# end_date + 1 day at 00:00:00 so the trigger can still fire at 23:00 that night.

# The last night a ${ExpectedTriggerHour}:00 firing can occur under an EndBoundary:
# the latest date D with D+<hour> strictly before it (Task Scheduler deactivates
# the trigger AT the boundary).
function Get-T7LastTriggerNight([datetime]$eb, [int]$hour) {
    if ($eb.TimeOfDay -gt [timespan]::FromHours($hour)) { $eb.Date } else { $eb.Date.AddDays(-1) }
}

$t7HasOverride = ($EndDateOverride -ne '') -or ($EndBoundaryOverride -ne '')
if ($t7HasOverride -and (($EndDateOverride -eq '') -or ($EndBoundaryOverride -eq ''))) {
    # Half an injected pair would silently mix synthetic with live state - refuse.
    Check "T7 self-test overrides form a full pair (-EndDateOverride AND -EndBoundaryOverride; 'none' = that side absent)" $false
}
else {
    $t7Ready = $true   # both lock values resolved into raw strings ('' = absent)
    $t7EndDateRaw = ''
    $t7EbRaw = ''
    if ($t7HasOverride) {
        $t7EndDateRaw = if ($EndDateOverride -eq 'none') { '' } else { $EndDateOverride }
        $t7EbRaw = if ($EndBoundaryOverride -eq 'none') { '' } else { $EndBoundaryOverride }
        Write-Host ("  self-test override: end_date='{0}'  EndBoundary='{1}'  (blank = absent)" -f $t7EndDateRaw, $t7EbRaw)
    }
    else {
        # Lock 1 - the campaign file, resolved exactly as the runner's own
        # -CampaignConfig default resolves it (same file the 23:00 preflight reads).
        $campResolved = Resolve-Path $CampaignConfig -ErrorAction SilentlyContinue
        if (-not $campResolved) {
            Check "T7 campaign config found at $CampaignConfig (fail-closed: lock 1 unreadable, consistency unverifiable)" $false
            $t7Ready = $false
        }
        else {
            try {
                $camp7 = Get-Content $campResolved.Path -Raw | ConvertFrom-Json
                $t7EndDateRaw = [string]$camp7.end_date
            }
            catch {
                Check "T7 campaign config parses as JSON ($($campResolved.Path); fail-closed: $($_.Exception.Message))" $false
                $t7Ready = $false
            }
        }
        # Lock 2 - the governing daily trigger's EndBoundary (T3's identification).
        if ($t7Ready) {
            if ($dailyAtHour.Count -lt 1) {
                Check "T7 governing daily ${ExpectedTriggerHour}:00 trigger identified (fail-closed: T3 found none, lock 2 unreadable)" $false
                $t7Ready = $false
            }
            else {
                $ebVals = @($dailyAtHour | ForEach-Object { ([string]$_.EndBoundary).Trim() } | Select-Object -Unique)
                if ($ebVals.Count -gt 1) {
                    Check "T7 daily ${ExpectedTriggerHour}:00 triggers agree on one EndBoundary (fail-closed: got $($ebVals -join ' vs '))" $false
                    $t7Ready = $false
                }
                else { $t7EbRaw = $ebVals[0] }
            }
        }
    }
    if ($t7Ready) {
        $edPresent = -not [string]::IsNullOrWhiteSpace($t7EndDateRaw)
        $ebPresent = -not [string]::IsNullOrWhiteSpace($t7EbRaw)
        if (-not $edPresent) {
            if (-not $ebPresent) {
                Write-Host '  campaign end_date absent/blank = documented "no calendar cutoff" (run-battery-night.ps1); the trigger carries no EndBoundary either.'
                Check 'T7 no campaign end_date and no trigger EndBoundary (both locks agree: no calendar cutoff)' $true
            }
            else {
                # SEVERITY CALL (#972): this direction FAILS too. The campaign says
                # "run until LA direction / pass target" but the OS would silently
                # stop firing at EndBoundary - the same no-error/no-log/no-report
                # cliff, mirrored; warn-but-pass would be a silently degrading
                # control (a fail-loud principle violation).
                $t7Eb = $null
                try { $t7Eb = [datetime]$t7EbRaw } catch {}
                if ($null -eq $t7Eb) {
                    Check "T7 trigger EndBoundary '$t7EbRaw' parses as a datetime (fail-closed: lock 2 unreadable)" $false
                }
                else {
                    $trigLastNight = Get-T7LastTriggerNight $t7Eb $ExpectedTriggerHour
                    Write-Host ("  DIVERGED: campaign has NO end_date (documented: no calendar cutoff) but the trigger has EndBoundary = {0} - the OS lock will SILENTLY stop the battery after the night of {1} (no error, no log, no report)." -f $t7Eb.ToString("yyyy-MM-dd'T'HH:mm:ss"), $trigLastNight.ToString('yyyy-MM-dd')) -ForegroundColor Red
                    Check ("T7 trigger EndBoundary absent when the campaign declares no calendar cutoff (got {0})" -f $t7Eb.ToString("yyyy-MM-dd'T'HH:mm:ss")) $false
                }
            }
        }
        else {
            $t7EndDate = $null
            try { $t7EndDate = [datetime]::ParseExact($t7EndDateRaw.Trim(), 'yyyy-MM-dd', $null) } catch {}
            if ($null -eq $t7EndDate) {
                Check "T7 campaign end_date '$t7EndDateRaw' parses as yyyy-MM-dd (fail-closed; the preflight uses this exact format and would THROW at 23:00)" $false
            }
            elseif (-not $ebPresent) {
                $expectedEb7 = $t7EndDate.AddDays(1)
                Write-Host ("  DIVERGED: campaign end_date = {0} but the daily trigger has NO EndBoundary - the OS-level calendar lock is MISSING (two deliberate locks degraded to one). The preflight alone now enforces the cutoff: last night that runs = {0}." -f $t7EndDate.ToString('yyyy-MM-dd')) -ForegroundColor Red
                Check ("T7 trigger EndBoundary present and == end_date + 1 day (expected {0}, got ABSENT)" -f $expectedEb7.ToString("yyyy-MM-dd'T'HH:mm:ss")) $false
            }
            else {
                $t7Eb = $null
                try { $t7Eb = [datetime]$t7EbRaw } catch {}
                if ($null -eq $t7Eb) {
                    Check "T7 trigger EndBoundary '$t7EbRaw' parses as a datetime (fail-closed: lock 2 unreadable)" $false
                }
                else {
                    $expectedEb7 = $t7EndDate.AddDays(1)   # midnight after the last running night
                    $trigLastNight = Get-T7LastTriggerNight $t7Eb $ExpectedTriggerHour
                    $scriptLastNight = $t7EndDate.Date
                    $effectiveLast = if ($trigLastNight -lt $scriptLastNight) { $trigLastNight } else { $scriptLastNight }
                    $ok7 = ($t7Eb -eq $expectedEb7)
                    if ($ok7) {
                        Write-Host ("  end_date = {0} (script lock)  EndBoundary = {1} (OS lock): consistent - last night that runs = {0}; the trigger still fires at {2}:00 that night and deactivates at the following midnight." -f $t7EndDate.ToString('yyyy-MM-dd'), $t7Eb.ToString("yyyy-MM-dd'T'HH:mm:ss"), $ExpectedTriggerHour) -ForegroundColor Green
                    }
                    else {
                        Write-Host ("  DIVERGED: campaign end_date = {0} (script lock: last night {1})  vs  trigger EndBoundary = {2} (OS lock: last firing night {3}); expected EndBoundary = {4} (end_date + 1 day at 00:00:00)." -f $t7EndDateRaw.Trim(), $scriptLastNight.ToString('yyyy-MM-dd'), $t7Eb.ToString("yyyy-MM-dd'T'HH:mm:ss"), $trigLastNight.ToString('yyyy-MM-dd'), $expectedEb7.ToString("yyyy-MM-dd'T'HH:mm:ss")) -ForegroundColor Red
                        Write-Host ("  The EARLIER lock wins SILENTLY: the last night that will actually run is {0} - after that the battery just stops firing (no error, no log, no report - the 2026-07-19 shape)." -f $effectiveLast.ToString('yyyy-MM-dd')) -ForegroundColor Red
                    }
                    Check ("T7 trigger EndBoundary ({0}) == campaign end_date + 1 day ({1})" -f $t7Eb.ToString("yyyy-MM-dd'T'HH:mm:ss"), $expectedEb7.ToString("yyyy-MM-dd'T'HH:mm:ss")) $ok7
                }
            }
        }
    }
}

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
