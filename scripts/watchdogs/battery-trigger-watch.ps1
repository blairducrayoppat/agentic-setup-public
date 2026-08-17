# Battery TRIGGER watchdog.
#
# The problem it exists for (#1379, 2026-08-11): the 23:00 nightly trigger can be silently
# SKIPPED. A timezone move (+3h, Pacific -> Eastern) re-dated the previous night's run onto
# the current day, Windows Task Scheduler judged the day's occurrence already satisfied, and
# advanced NextRun to tomorrow. The trigger definition was intact and Enabled the whole time.
# A whole night vanished from the campaign with no artifact, no log, and no alarm - because
# every other instrument in the system is downstream of the night STARTING.
#
# This watches for the ABSENCE OF A START. It is the same dead-man's-switch shape as
# battery-deadman.ps1, moved one layer earlier: that one asks "did the night finish?", this
# one asks "did the night begin at all?".
#
# Why not -StartWhenAvailable on the battery task: Windows did not consider the occurrence
# MISSED, it considered it SATISFIED, so the missed-run machinery never engages. The fix has
# to be an independent observer, not a setting on the component that failed.
#
# Idempotent by construction: the battery task is MultipleInstances=IgnoreNew, so a redundant
# start is a no-op rather than a collision.
#
# Location note: outside every git repo on purpose. Owed a proper home in BlarAI with tests.

$ErrorActionPreference = 'Stop'
$BatteryDir = 'C:\Users\mrbla\agentic-setup\state\battery'
$Log        = 'C:\Users\mrbla\blarai-ops\deadman\trigger-watch.log'
$TaskName   = 'BlarAI-M2-Battery-Nightly'
$TaskPath   = '\BlarAI\'
$Now        = Get-Date

function Write-WatchLog([string]$m) {
    $line = "{0} | {1}" -f $Now.ToString('yyyy-MM-dd HH:mm:ss K'), $m
    Write-Output $line
    try { Add-Content -LiteralPath $Log -Value $line -Encoding utf8 } catch { }
}

try {
    # 1. Is a battery already executing? Covers both a night that started normally minutes ago
    #    and a long night from yesterday still in its run phase. Either way, hands off.
    # MATCH THE INVOCATION, NEVER A MENTION - see the same fix in battery-deadman.ps1.
    # A bare substring match counts any process whose command line merely CONTAINS these names,
    # including a Claude tool shell or an editor. Measured 2026-08-12 00:20. Here the harm runs
    # the other way from the deadman's: a phantom "battery already executing" makes this watch
    # stand down, so a genuinely skipped trigger goes unstarted and the night is simply lost -
    # the exact outcome (#1379) this file exists to prevent.
    $running = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        $c = $_.CommandLine
        $c -and (
            ($_.Name -match '^(pwsh|powershell)\.exe$' -and
             $c -match '-File\s+"?[^"]*[\\/](battery-bootstrap|run-battery-night)\.ps1') -or
            ($_.Name -match '^pythonw?\.exe$' -and
             $c -match '-m\s+tools\.dispatch_harness\.battery')
        )
    }).Count
    if ($running -gt 0) {
        Write-WatchLog "OK: a battery process is already executing ($running). No action."
        exit 0
    }

    # 2. Did TONIGHT'S night start? The directory name carries the stamp the night minted
    #    for itself in LOCAL time, which is the same clock this check runs on. Deliberately
    #    NOT file mtimes - those shift wholesale when the machine changes timezone, which is
    #    the very event this watchdog exists for.
    #
    #    THE STAMP'S TIME MATTERS, NOT ONLY ITS DATE (fixed 2026-08-14, #1379).
    #    This asked "does any night-<today>-* directory exist". Any battery start on the
    #    same calendar day satisfied that - including one that is nothing to do with the
    #    23:00 trigger. Measured today: the machine was off overnight, came back at 13:19,
    #    and Windows' missed-task catch-up fired a battery attempt at 13:28 which created
    #    night-20260814-132831 and then stood down having run zero jobs. At 23:30 this
    #    check would have found that directory, reported "night started today", and stood
    #    down - so a genuinely skipped 23:00 trigger would have gone unrescued by the one
    #    watchdog built to rescue it. The wedge that cost five nights was still in force at
    #    the time, which is precisely when a trigger watchdog is most load-bearing.
    #
    #    A DIRECTORY THAT EXISTS IS NOT A NIGHT THAT RAN. The honest question is whether a
    #    night started in THIS trigger's window, so the stamp is parsed and its time-of-day
    #    compared against the trigger's own hour rather than thrown away. An unparseable
    #    stamp counts as a start (fail-safe: this watchdog's failure mode is starting a
    #    redundant night, which IgnoreNew makes a no-op, versus force-starting one that
    #    should not run).
    $today = $Now.ToString('yyyyMMdd')
    # The hour comes from the TASK'S OWN TRIGGER, not a constant, so moving the battery to
    # a different hour cannot leave this check silently comparing against 23:00 forever.
    # 23:00 is only the fallback for an unreadable task.
    $triggerStart = $null
    try {
        $tt = (Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction Stop).Triggers |
              Select-Object -First 1
        if ($tt -and $tt.StartBoundary) { $triggerStart = ([datetime]$tt.StartBoundary).TimeOfDay }
    } catch { }
    if ($null -eq $triggerStart) { $triggerStart = [timespan]::FromHours(23) }

    $tonight = @(Get-ChildItem $BatteryDir -Directory -Filter "night-$today-*" -ErrorAction SilentlyContinue |
        Where-Object {
            if ($_.Name -match '^night-\d{8}-(\d{2})(\d{2})(\d{2})$') {
                $t = [timespan]::new([int]$Matches[1], [int]$Matches[2], [int]$Matches[3])
                return ($t -ge $triggerStart)
            }
            return $true   # unparseable stamp -> treat as a start, see fail-safe note above
        })
    if ($tonight.Count -gt 0) {
        Write-WatchLog "OK: tonight's night started - $($tonight[0].Name) (at or after the $($triggerStart) trigger). No action."
        exit 0
    }
    $earlier = @(Get-ChildItem $BatteryDir -Directory -Filter "night-$today-*" -ErrorAction SilentlyContinue)
    if ($earlier.Count -gt 0) {
        # Named rather than passed over in silence: this is the state that used to be an
        # unearned "OK", and a reader of this log should be able to see it was considered.
        Write-WatchLog "NOTE: $($earlier.Count) battery start(s) today PRECEDE the $($triggerStart) trigger (e.g. $($earlier[0].Name)) - not evidence tonight's trigger fired. Continuing to check."
    }

    # 3. Nothing started and nothing is running. Before acting, confirm the task is actually
    #    supposed to run - a deliberately disabled task or an expired campaign must not be
    #    force-started by a watchdog. Fail-closed: refuse rather than guess.
    $task = Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction SilentlyContinue
    if (-not $task) {
        Write-WatchLog "REFUSING: scheduled task $TaskPath$TaskName is not registered. Not starting anything."
        exit 0
    }
    if ($task.State -eq 'Disabled') {
        Write-WatchLog "REFUSING: $TaskName is DISABLED - that is a deliberate operator state, not a fault. Not starting."
        exit 0
    }
    $trigger = $task.Triggers | Select-Object -First 1
    if ($trigger -and $trigger.EndBoundary) {
        try {
            if ([datetime]$trigger.EndBoundary -le $Now) {
                Write-WatchLog "REFUSING: the campaign trigger's EndBoundary ($($trigger.EndBoundary)) has passed. The campaign is over. Not starting."
                exit 0
            }
        } catch { }
    }

    # 4. The trigger should have fired and did not. Start it.
    Write-WatchLog "TRIGGER MISS: no night-$today-* directory and no battery process, task is Enabled and in-campaign. Starting the battery now (#1379)."
    Start-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath
    Start-Sleep -Seconds 25

    $after = @(Get-ChildItem $BatteryDir -Directory -Filter "night-$today-*" -ErrorAction SilentlyContinue)
    if ($after.Count -gt 0) {
        Write-WatchLog "RECOVERED: $($after[0].Name) created. The night is running."
    } else {
        # Fail LOUD. A recovery that did not recover must not look like one - put it where the
        # operator actually reads, the same surface battery-deadman.ps1 uses.
        Write-WatchLog "RECOVERY FAILED: Start-ScheduledTask returned but no night directory appeared within 25s."
        $report = Join-Path $BatteryDir 'MORNING-REPORT.md'
        $body = @(
            "# Battery - the night did not start, and recovery FAILED ($($Now.ToString('yyyy-MM-dd HH:mm')))",
            "",
            "The 23:00 trigger did not fire tonight. The trigger watchdog detected that and tried",
            "to start the battery by hand. **That also did not work.**",
            "",
            "No night ran. Nothing was damaged and nothing was lost from the campaign - the count",
            "is simply unchanged - but tonight produced no measurement.",
            "",
            "Watch log: $Log",
            "Ticket: #1379"
        ) -join "`n"
        try { Set-Content -LiteralPath $report -Value $body -Encoding utf8 } catch { }
    }
}
catch {
    Write-WatchLog "WATCH ERROR: $($_.Exception.Message)"
}
