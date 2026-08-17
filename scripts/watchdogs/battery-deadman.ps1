# Battery night DEAD-MAN'S WATCH.
#
# The problem it exists for (#1378, 2026-08-11): the morning report is written BY the night,
# in its postlude. A night that is KILLED -- power loss, hard shutdown, tree-kill -- runs no
# postlude, no trap, no finally. It writes nothing. So MORNING-REPORT.md still holds the
# PREVIOUS night, and silence is indistinguishable from success. On 2026-08-10 a night ran
# 7.5 productive hours, died 16 minutes after its last commit, and reported nothing; the
# operator's morning read showed the night before and looked normal.
#
# This runs OUTSIDE the night, on its own schedule, and asks the only question the night
# cannot answer about itself: did it finish? If it did not, THIS writes the morning report.
# The alarm lands on the exact artifact the operator already opens, because an alarm he has
# to go looking for is not an alarm.
#
# Deliberately fail-LOUD and fail-CLOSED: any state it cannot positively confirm as a
# completed night is reported as a problem, never passed over. A watchdog that stays quiet
# when confused is the defect it was built to catch.
#
# Location note: lives outside every git repo on purpose, so it cannot dirty a tree the
# battery inspects, and so no repo checkout/branch state can take it out. Owed a proper home
# in BlarAI with tests (#1378).

$ErrorActionPreference = 'Stop'
$BatteryDir = 'C:\Users\mrbla\agentic-setup\state\battery'
$Report     = Join-Path $BatteryDir 'MORNING-REPORT.md'
$Log        = 'C:\Users\mrbla\blarai-ops\deadman\deadman.log'
$Now        = Get-Date

function Write-DeadmanLog([string]$m) {
    $line = "{0} | {1}" -f $Now.ToString('yyyy-MM-dd HH:mm:ss K'), $m
    try { Add-Content -LiteralPath $Log -Value $line -Encoding utf8 } catch { }
}

# The alarm. Replaces the morning report so the stale one cannot be read as current.
function Write-Alarm([string]$headline, [string]$detail, [string]$nightName) {
    $body = @(
        "# Battery - THE NIGHT DID NOT REPORT ($($Now.ToString('yyyy-MM-dd HH:mm')))",
        "",
        "**$headline**",
        "",
        $detail,
        "",
        "## What this means",
        "",
        "This notice was written by the dead-man's watch, NOT by the battery. The battery",
        "writes its own report at the END of a night; if you are reading this, it never got",
        "there. **The previous report was replaced so it could not be mistaken for last",
        "night's.**",
        "",
        "**Work may still exist.** A killed night usually leaves real commits behind in its",
        "sandbox even when it banked nothing - check the job repo under C:\Users\mrbla\projects",
        "with ``git log`` before assuming the night was wasted. What is lost in that case is the",
        "MEASUREMENT (scorecards, campaign counters), not necessarily the work.",
        "",
        "Night inspected: ``$nightName``",
        "Watch log: $Log",
        "Ticket: #1378"
    ) -join "`n"
    Set-Content -LiteralPath $Report -Value $body -Encoding utf8
    Write-DeadmanLog "ALARM: $headline (night=$nightName)"
}

try {
    if (-not (Test-Path -LiteralPath $BatteryDir -PathType Container)) {
        Write-DeadmanLog "CANNOT CHECK: battery state dir missing at $BatteryDir"
        exit 0
    }

    # Is a battery actually running right now? A late-admitted night can still be working at
    # this hour (admission may wait until 04:00), and calling a live run dead would be its own
    # false alarm.
    #
    # The pattern MUST cover the whole night, not just its final stage. An earlier version
    # matched only `python.exe -m tools.dispatch_harness.battery` and false-alarmed on a live
    # night during its preflight probe (2026-08-11 23:11) - at that point the bootstrap and
    # the driver are running but the python runner has not launched yet, so the night looked
    # dead to a check aimed at its last phase. A liveness probe that only recognises one stage
    # reports every other stage as death.
    # MATCH THE INVOCATION, NEVER A MENTION. A bare substring match on the script names counts
    # any process whose command line merely CONTAINS them - including a Claude tool shell, an
    # editor, or a grep. Measured 2026-08-12 00:20: this check reported "1 battery process
    # executing" when the only match was the very command that had just written the word into
    # its own arguments. That is a false NEGATIVE, and it is the dangerous direction: it makes
    # the watchdog go quiet, which is indistinguishable from "the night is fine" and is exactly
    # the silence this whole mechanism exists to break.
    #
    # So require the process to BE the battery, not to talk about it: the right executable AND
    # the invocation form that actually runs it (-File <script>.ps1 / -m <module>).
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
        Write-DeadmanLog "OK-SO-FAR: a battery process is still executing ($running). No verdict yet."
        exit 0
    }

    # The most recent night directory is the one under judgement.
    $night = Get-ChildItem $BatteryDir -Directory -Filter 'night-*' -ErrorAction SilentlyContinue |
             Sort-Object Name -Descending | Select-Object -First 1
    if (-not $night) {
        Write-Alarm "No battery night directory exists at all." `
                    "Nothing under ``$BatteryDir`` matches ``night-*``. Either the battery has never run here, or its state directory was moved or cleared." `
                    '(none)'
        exit 0
    }

    # Did it START recently enough to be "last night"? The directory name carries the stamp
    # the night minted for itself (yyyyMMdd-HHmmss) - trusted over file mtimes, which shift
    # wholesale when the machine changes timezone.
    $stamp = $null
    if ($night.Name -match 'night-(\d{8}-\d{6})') {
        try { $stamp = [datetime]::ParseExact($Matches[1], 'yyyyMMdd-HHmmss', $null) } catch { }
    }
    if (-not $stamp) {
        Write-Alarm "Could not read a start time from the newest night's name." `
                    "Newest directory is ``$($night.Name)``, which does not carry a parseable ``yyyyMMdd-HHmmss`` stamp. Refusing to guess whether it is last night's." `
                    $night.Name
        exit 0
    }

    $ageHours = [math]::Round(($Now - $stamp).TotalHours, 1)
    if ($ageHours -gt 26) {
        Write-Alarm "No battery night has started in $ageHours hours." `
                    "The newest night is ``$($night.Name)``, started $($stamp.ToString('yyyy-MM-dd HH:mm')) - $ageHours hours ago. A nightly job that has not started in over a day is not running. Check that the scheduled task ``\BlarAI\BlarAI-M2-Battery-Nightly`` is still Enabled and that its trigger has not passed its end boundary." `
                    $night.Name
        exit 0
    }

    # SECOND GUARD, independent of the process check above. A night still inside its own budget
    # window has not failed to finish - it has not finished YET, and those are different claims.
    # The derived run-phase floor is 30,900 s (8.6 h) from the night's start, so anything younger
    # than that cannot be judged dead no matter what the process table says. This exists because
    # the process check alone is a single point of failure: it was wrong once already (too narrow
    # a pattern, 2026-08-11), and a watchdog whose only guard against false alarms is one process
    # match will eventually cry wolf on a healthy night. Two independent guards, per the
    # defence-in-depth rule that a lock which is only a side effect of another is not a lock.
    if ($ageHours -lt 9.0) {
        Write-DeadmanLog "TOO YOUNG TO JUDGE: $($night.Name) is $ageHours h old, inside the 8.6 h run-phase floor. No verdict."
        exit 0
    }

    # COMPLETION EVIDENCE. Scorecards are what a finished night produces.
    $cards = @(Get-ChildItem (Join-Path $night.FullName 'scorecards') -File -ErrorAction SilentlyContinue).Count
    $reportFresh = $false
    if (Test-Path -LiteralPath $Report -PathType Leaf) {
        $reportFresh = ((Get-Item -LiteralPath $Report).LastWriteTime -ge $stamp)
    }

    if ($cards -gt 0 -and $reportFresh) {
        Write-DeadmanLog "OK: $($night.Name) completed - $cards scorecard(s), report refreshed."
        exit 0
    }

    $runnerLog = Join-Path $night.FullName 'battery-runner.log'
    $runnerBytes = if (Test-Path -LiteralPath $runnerLog) { (Get-Item -LiteralPath $runnerLog).Length } else { 'absent' }

    $detail = @(
        "Night ``$($night.Name)`` started $($stamp.ToString('yyyy-MM-dd HH:mm')) ($ageHours h ago) and has not finished cleanly.",
        "",
        "| check | result |",
        "|---|---|",
        "| scorecards written | **$cards** |",
        "| morning report refreshed for this night | **$(if ($reportFresh) { 'yes' } else { 'NO' })** |",
        "| runner log size | **$runnerBytes bytes** |",
        "| runner process still alive | **no** |",
        "",
        "A runner log of 0 bytes does NOT mean the night never started - the runner's output is",
        "buffered and only reaches disk when the process exits, so a killed night leaves exactly",
        "0 bytes no matter how long it worked."
    ) -join "`n"

    Write-Alarm "Last night's battery did not finish, and did not report." $detail $night.Name
}
catch {
    # The watch itself failing must not be silent - that would reproduce the exact defect.
    Write-DeadmanLog "WATCH ERROR: $($_.Exception.Message)"
    try {
        Set-Content -LiteralPath $Report -Encoding utf8 -Value (@(
            "# Battery - the dead-man's watch itself failed ($($Now.ToString('yyyy-MM-dd HH:mm')))",
            "",
            "The watch that checks whether last night reported could not complete its own check:",
            "",
            "``$($_.Exception.Message)``",
            "",
            "**Treat last night's status as UNKNOWN.** Do not read any older report as current.",
            "Watch log: $Log"
        ) -join "`n")
    } catch { }
}
