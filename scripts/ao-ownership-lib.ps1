# ao-ownership-lib.ps1 - Night-scoped ownership of the Assistant Orchestrator (AO).
#
# WHY THIS EXISTS
# ===============
# The nightly battery (run-battery-night.ps1) BOOTS an AO it never stops. Three
# independent code paths bring a `python -m launcher` up during a night:
#   1. run-battery-night.ps1 Ensure-AoHeadless (preflight, and after a probe admit),
#   2. the runner's per-job AoReensurer (blarai tools/dispatch_harness/battery.py),
#   3. the swap driver's swap-back relaunch (blarai shared/fleet/swap_ops.py
#      restart_launcher) - which fires at the END of EVERY job, so the AO alive when
#      the runner exits is always one the night's own machinery spawned.
# NOTHING tore any of them down. Measured 2026-07-20: the 2026-07-19 night's final
# swap-back relaunch (PID 3468, 00:13:39) held the resident 14B - 11.63 GB - for 9.5
# hours until the operator stopped it by hand. Its spawning driver had already
# exited, so the launcher was an unowned orphan: no parent, no teardown, no owner.
#
# THE OWNERSHIP MODEL
# ===================
# Ownership is NIGHT-scoped, not process-scoped, and that distinction is the whole
# design. A per-PID claim cannot work: the swap driver kills and RELAUNCHES the AO
# on every job, so the process alive at 02:00 is not the one the preflight booted.
# What survives the night is the CLAIM - a sentinel recording which night is
# responsible for whatever `-m launcher` currently holds :5001.
#
# Two legs, so a leak cannot outlive one night:
#   LEG A (end-of-night teardown) - the night that claimed the AO stops it after the
#     morning report. The normal path.
#   LEG B (stale-claim reclaim)   - a sentinel from an EARLIER night proves that
#     night died without releasing (tree-killed by the scheduled task's
#     ExecutionTimeLimit - the PT10H incident class - or aborted on a throw). The
#     next night reclaims that orphan at preflight, BEFORE it measures RAM, so the
#     freed ~11.6 GiB counts toward the admission gate.
# Leg B is what makes this structural rather than vigilance: Leg A can be skipped by
# a kill -9, but the sentinel it left behind cannot be, and the next night reads it.
#
# WHY RECLAIMING A PRE-EXISTING AO IS NOT A NEW HAZARD
# ====================================================
# Leg B stops an AO that was alive before the night started. That sounds like it
# could destroy an operator session - it does not, because the night ALREADY
# destroys it: a battery job dispatches through the AO, and the AO STEPS ASIDE
# (exits itself) so the 30B can load. Any AO alive at 23:00 is dead by ~23:05
# regardless of this library. Leg B only moves that certain teardown a few minutes
# earlier, where the freed RAM is still useful to the admission gate.
# The one case where a human could genuinely be at the keyboard is a manual
# daytime `-Now` run, so BOTH legs are caller-gated to the scheduled night - see
# run-battery-night.ps1, where every entry point sits inside `if (-not $Now)`.
# This mirrors the standing -Now posture (verify-battery-probe-admission.ps1 S5:
# "a probe under -Now would stop the operator's live AO in daylight").
#
# THE KILL IS NOT OURS
# ====================
# Stopping the AO is delegated WHOLE to stop-assistant.ps1 (#797), the audited stop
# seam: it reads the launcher single-instance lock, CONFIRMS the pid is genuinely a
# live `-m launcher` (never a recycled pid), and tree-kills through spawn-lib's
# Stop-ProcessTree. This library contains no kill of its own and must never grow
# one - it decides WHETHER to stop, never HOW.
#
# NOTE ON THIS FILE'S ENCODING: ASCII-only, same rule as spawn-lib.ps1 - PowerShell
# 5.1's [Parser] reads a UTF-8-no-BOM .ps1 as cp1252 and throws spurious "unexpected
# token" on em-dashes (FIELD_NOTES 2026-07-06).

Set-StrictMode -Version Latest

#: The sentinel lives beside the night dirs in the gitignored runtime state tree.
function Get-AoOwnerSentinelPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$AgenticRoot)
    return (Join-Path $AgenticRoot 'state\battery\ao-owner.json')
}

function Set-AoOwner {
    # CLAIM: this night is responsible for whatever `-m launcher` holds :5001 until
    # it releases. OwnerPid is the battery launcher's own pid - recorded for forensics
    # (was the owning night still alive when the orphan was found?), never as a kill
    # target. The AO's pid is deliberately NOT recorded: the swap driver replaces the
    # process mid-night, so a recorded pid would be stale by the first job.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SentinelPath,
        [Parameter(Mandatory)][string]$Night,
        [int]$OwnerPid = $PID
    )
    $dir = Split-Path -Parent $SentinelPath
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
    $claim = [ordered]@{
        night       = $Night
        owner_pid   = $OwnerPid
        claimed_utc = (Get-Date).ToUniversalTime().ToString('o')
        note        = 'The battery night named here owns the AO on :5001. A sentinel whose night is not the CURRENT night means that night died without releasing - reclaim the orphan.'
    }
    $claim | ConvertTo-Json -Depth 4 | Set-Content -Path $SentinelPath -Encoding utf8
    return $SentinelPath
}

function Get-AoOwner {
    # The recorded claim, or $null when absent/unreadable/corrupt. A corrupt sentinel
    # is treated as NO claim: the fail-safe direction here is to leave a running AO
    # alone rather than stop one we cannot prove we own.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SentinelPath)
    if (-not (Test-Path $SentinelPath)) { return $null }
    try { $raw = Get-Content -Path $SentinelPath -Raw -ErrorAction Stop }
    catch { return $null }
    if (-not $raw -or -not $raw.Trim()) { return $null }
    try { return ($raw | ConvertFrom-Json -ErrorAction Stop) }
    catch { return $null }
}

function Clear-AoOwner {
    # RELEASE the claim. Idempotent: a missing sentinel is success, not an error.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SentinelPath)
    if (Test-Path $SentinelPath) { Remove-Item -Path $SentinelPath -Force -ErrorAction SilentlyContinue }
}

function Stop-OwnedAo {
    # Stop the AO this night owns, through the audited seam, then release the claim.
    #
    # Returns a result object ({ Stopped; Reason; ExitCode; Output }) and NEVER throws:
    # a teardown failure must not change the night's exit code or sink a completed
    # run. Every outcome is reported through $Log so a failure is loud in the
    # transcript rather than silent (fail-loud: a teardown that degrades quietly is
    # worse than none, because the next night's Leg B would be the only signal).
    #
    # The claim is released only when the stop actually SUCCEEDED. A failed stop keeps
    # the sentinel, so the next night's Leg B retries the reclaim - the leak stays
    # bounded even when the stop seam itself fails.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SentinelPath,
        [Parameter(Mandatory)][string]$BlarAiRepo,
        [Parameter(Mandatory)][string]$StopAssistantPath,
        [string]$Context = 'end-of-night',
        [scriptblock]$Log = { param($m) Write-Host $m }
    )
    $emit = { param($m) try { & $Log "ao-ownership: $m" } catch { } }

    if (-not (Test-Path $StopAssistantPath)) {
        & $emit "$Context - stop-assistant.ps1 NOT FOUND at $StopAssistantPath; cannot release the AO (the claim is KEPT so the next night retries)."
        return [pscustomobject]@{ Stopped = $false; Reason = 'stop-script-missing'; ExitCode = $null; Output = '' }
    }

    & $emit "$Context - stopping the AO this night owns (via the audited stop-assistant seam)."
    $out = ''
    $code = $null
    try {
        # Child pwsh, exactly like the launcher's other verify-script call sites: the
        # stop script sets its own StrictMode/ErrorActionPreference and exits with a
        # code, and an in-process dot-source would leak both into the caller.
        $raw = & pwsh -NoProfile -ExecutionPolicy Bypass -File $StopAssistantPath -BlarAiRepo $BlarAiRepo 2>&1
        $code = $LASTEXITCODE
        $out = ($raw | Out-String).Trim()
    } catch {
        & $emit "$Context - the stop seam THREW ($($_.Exception.Message)); the claim is KEPT so the next night retries."
        return [pscustomobject]@{ Stopped = $false; Reason = 'stop-threw'; ExitCode = $null; Output = $out }
    }
    foreach ($line in ($out -split "`r?`n")) { if ($line.Trim()) { & $emit "  $line" } }

    if ($code -eq 0) {
        Clear-AoOwner -SentinelPath $SentinelPath
        & $emit "$Context - AO released and the ownership claim cleared."
        return [pscustomobject]@{ Stopped = $true; Reason = 'stopped'; ExitCode = $code; Output = $out }
    }
    & $emit "$Context - the stop seam exited $code (the AO may still be resident); the claim is KEPT so the next night's stale-claim reclaim retries."
    return [pscustomobject]@{ Stopped = $false; Reason = 'stop-nonzero'; ExitCode = $code; Output = $out }
}

function Invoke-AoPreflightReclaim {
    # LEG B. Clear the :5001 slot before the caller measures RAM for the admission gate.
    #
    # WHY THIS IS NOT SENTINEL-DRIVEN (2026-07-20, review finding)
    # ===========================================================
    # The first cut reclaimed ONLY when a sentinel named an earlier night. That misses
    # every AO nothing ever claimed, and the resurrected admission gate turns that miss
    # into a LOST NIGHT rather than a degraded one: with an unowned AO resident,
    # Measure-SwapHeadroom sees the AO up so Projected = Available + 8.0 ~= 14 GiB
    # (short of the lean gate), while raw Available ~= 6 GiB is BELOW the 15.0 probe
    # floor -- so admission refuses, retries to 04:00 and skips. Demonstrated live: a
    # hand-run probe restored an AO (its always-restore discipline) and took Available
    # 17.59 -> 6.03 GiB, carrying no sentinel because no night claimed it.
    #
    # So the trigger is the SLOT, not the claim: on a scheduled night, an AO holding
    # :5001 at preflight is reclaimed whether or not anything owns it. The sentinel
    # still decides the REASON (stale-claim vs unowned) and protects a run in progress.
    #
    # This is safe for the same reason the stale-claim leg is: a battery job dispatches
    # THROUGH the AO, and the AO steps aside (exits itself) so the 30B can load. Any AO
    # alive at 23:00 is dead by ~23:05 regardless. Reclaiming moves that certain
    # teardown a few minutes earlier, where the freed RAM still counts. The one case
    # with a human at the keyboard is a manual -Now run, and the CALLER gates every
    # entry point behind `if (-not $Now)`.
    #
    # *AoPresent* is supplied by the caller rather than probed here: the launcher
    # already observes :5001 with Test-NetConnection, and this library must not grow a
    # second detector (it decides WHETHER to stop, never HOW, and never WHO is there).
    # Returns a result object; never throws.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SentinelPath,
        [Parameter(Mandatory)][string]$CurrentNight,
        [Parameter(Mandatory)][bool]$AoPresent,
        [Parameter(Mandatory)][string]$BlarAiRepo,
        [Parameter(Mandatory)][string]$StopAssistantPath,
        # #1334. Null when nothing is driving a dispatch; otherwise the caller's
        # descriptor of what is. MANDATORY with [AllowNull()] rather than optional: the
        # normal value IS null, but an optional lock is one a future call site can simply
        # forget, and this one stands between a scheduled night and somebody's live work.
        # Supplied by the caller for the same reason $AoPresent is -- this library decides
        # WHETHER to stop, never HOW to look, and never grows a second detector.
        [Parameter(Mandatory)][AllowNull()][psobject]$LiveDispatch,
        [scriptblock]$Log = { param($m) Write-Host $m }
    )
    $emit = { param($m) try { & $Log "ao-ownership: $m" } catch { } }

    $owner = Get-AoOwner -SentinelPath $SentinelPath
    $claimedNight = if ($owner) { [string]$owner.night } else { '' }

    # A LIVE DISPATCH DOMINATES EVERYTHING BELOW, including the "reclaim the SLOT, not the
    # claim" rule this function is built around. That rule is correct for an ORPHAN: an
    # unowned resident AO starves the admission gate into skipping the night, so taking it
    # is the lesser harm. It is catastrophic for an AO a live run is actively USING, and
    # the two are indistinguishable from the sentinel alone -- an operator dispatch claims
    # no AO by design, so it lands in the "NOTHING owns it" branch below and reads exactly
    # like an orphan.
    #
    # Measured 2026-08-07 23:00:11: this function stopped pid 28152 under that reasoning
    # while a dispatch which had already delivered six tasks was mid-flight. The night
    # that took it then stalled 256 s later, when its own replacement AO was torn down by
    # the cleanup of the run it had just orphaned. Two runs destroyed, one guard, one gap.
    if ($LiveDispatch) {
        $named = if ($LiveDispatch.RunId) { " for run $($LiveDispatch.RunId)" } else { '' }
        & $emit ("preflight reclaim REFUSED - a dispatch is live$named ($($LiveDispatch.Detail)). " +
                 "The AO on :5001 may be in use by it. Nothing stopped, nothing archived, " +
                 "no claim taken.")
        return [pscustomobject]@{ Reclaimed = $false; Reason = 'live-dispatch'; ClaimedNight = $claimedNight }
    }

    # A claim naming THIS night means a run is already in flight under this stamp
    # (re-entrant invocation): never tear down the run in progress. Checked first so it
    # dominates every other case.
    if ($owner -and $claimedNight -eq $CurrentNight) {
        & $emit "preflight reclaim - the sentinel names THIS night ($CurrentNight); a run is in flight (nothing stopped)."
        return [pscustomobject]@{ Reclaimed = $false; Reason = 'current-night'; ClaimedNight = $claimedNight }
    }

    if (-not $AoPresent) {
        if ($owner) {
            # A claim whose AO is already gone: tidy it, or every later preflight would
            # keep trying to reclaim a process that died long ago.
            Clear-AoOwner -SentinelPath $SentinelPath
            & $emit "preflight reclaim - :5001 is free but a stale claim from night $claimedNight remained; cleared it (nothing to stop)."
            return [pscustomobject]@{ Reclaimed = $false; Reason = 'claim-without-ao'; ClaimedNight = $claimedNight }
        }
        & $emit 'preflight reclaim - :5001 is free and nothing is claimed; the slot is already clear.'
        return [pscustomobject]@{ Reclaimed = $false; Reason = 'no-ao'; ClaimedNight = '' }
    }

    # An AO IS holding :5001. Reclaim it; the sentinel only names the reason.
    if ($owner) {
        $ownerPid = 0
        if ($owner.PSObject.Properties.Name -contains 'owner_pid') { $ownerPid = [int]$owner.owner_pid }
        $ownerAlive = $false
        if ($ownerPid -gt 0) { $ownerAlive = [bool](Get-Process -Id $ownerPid -ErrorAction SilentlyContinue) }
        $why = 'stale-claim'
        & $emit ("preflight reclaim - :5001 is held and the sentinel names night $claimedNight (owning launcher pid " +
                 "$ownerPid is $(if ($ownerAlive) { 'STILL ALIVE - that night never released' } else { 'gone - that night died without releasing' })" +
                 "); its AO is an orphan holding the resident 14B. Reclaiming before the RAM measurement.")
    } else {
        $why = 'unowned-ao'
        & $emit ('preflight reclaim - :5001 is held but NOTHING owns it: no battery night claimed this AO. ' +
                 'A hand-run probe restore, an operator session, or a night that died before claiming all land here. ' +
                 'On a scheduled night the swap step-aside would destroy it within minutes anyway, and leaving it ' +
                 'resident would starve the admission gate into skipping the night. Reclaiming before the RAM measurement.')
    }
    $res = Stop-OwnedAo -SentinelPath $SentinelPath -BlarAiRepo $BlarAiRepo `
        -StopAssistantPath $StopAssistantPath -Context "preflight reclaim ($why)" -Log $Log
    return [pscustomobject]@{
        Reclaimed = [bool]$res.Stopped
        Reason    = if ($res.Stopped) { $why } else { $res.Reason }
        ClaimedNight = $claimedNight
    }
}
