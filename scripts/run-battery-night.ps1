# run-battery-night.ps1 — the M2 nightly battery launcher (#740 W8/§9.5 campaign).
#
# Fires from Task Scheduler (\BlarAI\BlarAI-M2-Battery-Nightly, daily 23:00) or by
# hand. Behavior, in order:
#   1. CAMPAIGN CHECK  — reads state/battery-campaign.json; if the campaign is
#      complete (target passes reached) it UNREGISTERS its own scheduled task and
#      exits (Task Scheduler hygiene — the LA's explicit requirement).
#   2. DISPATCH GUARD  — if the coder port (:8000) is busy a dispatch is already
#      running: WAIT 30 min and re-check (until the cutoff). Never clobber a run
#      in flight. Presence checks (input idle / app window) were REMOVED by LA
#      direction 2026-07-09 ("it's fine to start at 23:00" — the guard kept
#      deferring nights he wanted run; #740).
#   3. PREFLIGHT       — swap admission (fast-path projection, then the #784 real-load
#      PROBE in the marginal band — see the LEAN + PROBE ADMISSION block), AO headless
#      up on :5001 (boot if absent), :8000 free, stale cancel file cleared, fresh sandbox
#      repos for the night's jobs (the previous night's repos are ARCHIVED by rename,
#      never deleted).
#   4. RUN             — python -m tools.dispatch_harness.battery --jobs <set>;
#      scorecards land under state/battery/<stamp>/.
#   5. MORNING REPORT  — a human-readable summary at state/battery/MORNING-REPORT.md
#      (+ the dated copy), pass counter updated, self-unregister when done.
#
# The job set comes from the campaign config, NOT hardcoded — B3/B5/B7 join when
# node-side oracle seeding is live; B8 joins when live rig injection lands. Any
# job trimmed for the night (late start) is LOGGED, never silent.

[CmdletBinding()]
param(
    # Resolved in the body against the STATE root, not $PSScriptRoot (#1181a): when this
    # script runs from the pinned worktree, $PSScriptRoot is the MEASURED tree, whose
    # state\ is empty. Defaulting there would silently start a brand-new campaign at pass 0.
    [string]$CampaignConfig,
    [switch]$Now,  # skip the dispatch guard + lean wait-loop (manual daytime invocation)

    # #1334 — THE OPERATOR'S ESCAPE FROM A WEDGED GUARD.
    #
    # The live-dispatch guard identifies a running dispatch by its driving PROCESS, which
    # is the only witness that spans a whole run. The cost of that choice: a process that
    # exists but is DEAD pins the guard forever. This is not hypothetical — swap drivers
    # are spawned DETACHED | NEW_GROUP | CREATE_BREAKAWAY_FROM_JOB precisely so they
    # survive a tree-kill, which is exactly what an ExecutionTimeLimit does to a night, so
    # the system is built to produce orphans. One of them makes every night wait to 04:00,
    # write a plausible-looking skip report and bank nothing, indefinitely.
    #
    # WHY A SWITCH AND NOT A HEURISTIC. An age cap or a CPU-idle test would clear the
    # wedge automatically and would ALSO re-introduce the false negative this whole ticket
    # exists to remove: a legitimately quiet driver (measured — a supervising swap driver
    # burns ~0 CPU for hours while its children work) is indistinguishable from a hung one
    # by any threshold, and guessing wrong destroys somebody's run. A guess that fails
    # silently is what was here before. An operator saying "I have looked, it is dead" is
    # evidence a threshold cannot manufacture.
    #
    # It is deliberately LOUD, not convenient: it logs a warning, names every process it
    # is overriding, and rides the night's admission record so the morning report shows
    # the night ran under an override rather than cleanly. The scheduled task does not
    # pass it and must never pass it — automation asserting "I have looked" is the lie
    # this switch exists to keep honest.
    [switch]$IgnoreLiveDispatch
)

$ErrorActionPreference = "Stop"

# ---- the two AGENTIC roots (#1181a) ------------------------------------------
# Exactly the split applied to the BlarAI side below, applied to this repo, and for the
# same reason: once the scheduled task points at a PINNED worktree so the driver is a
# commit that exists on main, "where this script lives" and "where this campaign's
# history lives" stop being the same directory.
#
#   CODE root  -- where this script and its siblings live. Follows $PSScriptRoot, so it
#                 is the pinned worktree when pinned and the primary checkout when not.
#                 Governs ao-ownership-lib.ps1, stop-assistant.ps1 and the verifiers:
#                 those are CODE and must be pinned along with their caller.
#   STATE root -- the primary checkout, always. Governs the campaign config, the per-night
#                 directories, the morning report, the fleet-swap cancel file and the
#                 worktree base. This is accumulated history: a pinned worktree is
#                 detached to a new commit every night, so state kept there would be a
#                 fresh empty campaign each time -- the pass counter would never advance
#                 and the self-unregister guard would compare against the wrong config.
$AgenticCodeRoot  = Resolve-Path "$PSScriptRoot\.."
$AgenticStateRoot = $AgenticCodeRoot

$agenticStateOverride = $env:BLARAI_BATTERY_AGENTIC_STATE_ROOT
if ($agenticStateOverride) {
    # Set by battery-bootstrap.ps1. Validated and FATAL on a bad value: falling back to the
    # code root would silently start a new campaign in the pinned tree while reporting a
    # normal night, which is the confound this whole change exists to remove.
    $resolvedState = (Resolve-Path -LiteralPath $agenticStateOverride -ErrorAction SilentlyContinue)
    if (-not $resolvedState) {
        throw "BLARAI_BATTERY_AGENTIC_STATE_ROOT='$agenticStateOverride' does not exist. It must name the PRIMARY agentic-setup checkout - the one holding this campaign's state\."
    }
    if (-not (Test-Path -LiteralPath (Join-Path $resolvedState.Path '.git') -PathType Container)) {
        throw "BLARAI_BATTERY_AGENTIC_STATE_ROOT='$agenticStateOverride' is not the primary agentic-setup checkout (its .git is not a directory, so it is a linked worktree). Campaign state must not live in a tree that is re-detached every night."
    }
    if (-not (Test-Path -LiteralPath (Join-Path $resolvedState.Path 'state') -PathType Container)) {
        throw "BLARAI_BATTERY_AGENTIC_STATE_ROOT='$agenticStateOverride' has no state\ directory, so it cannot be the campaign's home."
    }
    $AgenticStateRoot = $resolvedState.Path
}

# Kept as the historical spelling for the STATE-side reads below; the code-side reads use
# $PSScriptRoot directly so the two can never be confused again by a later edit.
$AgenticRoot = $AgenticStateRoot
# ---- the two BlarAI roots (#1181) -------------------------------------------
# These were ONE variable, spelled $BlarRoot, and that is the whole bug. A night resolved
# `-m tools.dispatch_harness.battery` AND read the frozen exam cards out of the primary
# checkout, so it measured whatever branch another session had left parked there -- and
# then stamped the result "blarai": <that branch's tip>, which reads like a release
# identifier. 2026-07-29 banked a night stamped 21b4e9be, an unmerged feature-branch tip,
# while main was f2e4f27b. Merging a harness fix did not reach the next run either.
#
# They are two different questions and only one of them can be pinned:
#
#   MEASURED ROOT -- which version of the measuring instrument ran. Pinned to a named
#   commit on main so a night is attributable and merging actually deploys. Governs the
#   runner module and the frozen cards.
#
#   RUNTIME ROOT -- which installation was exercised. CANNOT be a worktree: models/ is
#   gitignored (46 GB in one checkout, 3 manifest stubs everywhere else), certs/ holds the
#   per-boot mTLS chain the launcher mints, and certs/launcher.lock is what the teardown
#   barrier reads. Governs the AO boot/stop, the admission probe, and the venv.
#
# Collapsing them again in either direction breaks a night. Measured-for-everything boots
# an AO with no weights; runtime-for-everything is the unpinned measurement above.
$BlarRuntimeRoot = "C:\Users\mrbla\blarai"
$BlarMeasuredRoot = "C:\Users\mrbla\blarai-battery-measured"
$Python      = "$BlarRuntimeRoot\.venv\Scripts\python.exe"
$ProjectsDir = "C:\Users\mrbla\projects"
$TaskPath    = "\BlarAI\"
$TaskName    = "BlarAI-M2-Battery-Nightly"
# Self-unregister is scoped to the DEFAULT campaign config ONLY (2026-07-09
# incident): a SUPERVISED one-shot run (`-CampaignConfig <side-file>`, e.g. the
# B8/B7 hygiene verify) hit its own 1/1 target and the post-run check silently
# unregistered the REAL nightly task — the 23:00 campaign would simply not have
# fired, discovered only by the LA's pre-battery checklist question. A side
# config completing must never touch the shared task.
#
# STATE root, not $PSScriptRoot (#1181a). Under a pinned driver $PSScriptRoot is the
# measured worktree, whose state\ is empty: $DefaultCampaignConfig would resolve to
# $null, $IsDefaultCampaign would be FALSE for the real nightly campaign, and the
# self-unregister guard would stop firing for the one config it is meant to fire for.
# That fails safe rather than dangerous — a spent campaign would keep running instead of
# unregistering — but it is still a guard silently doing nothing, so it is pinned to the
# same root the campaign itself lives in.
$DefaultCampaignConfig = (Resolve-Path "$AgenticStateRoot\state\battery-campaign.json" -ErrorAction SilentlyContinue).Path
if (-not $CampaignConfig) { $CampaignConfig = "$AgenticStateRoot\state\battery-campaign.json" }
$IsDefaultCampaign = $DefaultCampaignConfig -and ((Resolve-Path $CampaignConfig -ErrorAction SilentlyContinue).Path -eq $DefaultCampaignConfig)
$Stamp       = Get-Date -Format "yyyyMMdd-HHmmss"
# Assigned for real once the pin has run; declared here so the postlude can render it under
# StrictMode no matter which path got there.
$DriverStamp = ''
$NightDir    = "$AgenticRoot\state\battery\night-$Stamp"
New-Item -ItemType Directory -Force $NightDir | Out-Null
Start-Transcript -Path "$NightDir\launcher.log" -Force | Out-Null

# #1334: an overridden night must be identifiable as one FOREVER, not just while someone
# remembers typing the flag. Announced here, immediately after the transcript opens, so it
# is the first thing in the night's permanent log — and loudly, because a night that ran
# with a safety check disabled is not comparable to one that did not, and whoever reads
# this log later must not have to infer that from an absence.
if ($IgnoreLiveDispatch) {
    @(
        "!! =====================================================================",
        "!! -IgnoreLiveDispatch IS SET. The live-dispatch guard is DISABLED for",
        "!! this run. If a coding dispatch is actually running, this night will",
        "!! reclaim its assistant and archive the folder it is building in --",
        "!! which is the 2026-08-07 incident this guard exists to prevent.",
        "!! Use this ONLY after checking that the process is a dead leftover.",
        "!! ====================================================================="
    ) | ForEach-Object { Write-Warning $_ }
}

# AO lifecycle ownership (2026-07-20). The night that boots an AO must also stop it:
# three paths bring one up (this preflight, the runner's per-job AoReensurer, the swap
# driver's swap-back relaunch after EVERY job) and none tore it down, so the last
# relaunch of the night held the resident 14B - 11.63 GB, measured - until the operator
# killed it by hand. See ao-ownership-lib.ps1 for the night-scoped ownership model and
# why a per-PID claim cannot work (the swap driver replaces the process mid-night).
. (Join-Path $PSScriptRoot 'ao-ownership-lib.ps1')
$AoOwnerSentinel   = Get-AoOwnerSentinelPath -AgenticRoot $AgenticRoot
$StopAssistantPath = Join-Path $PSScriptRoot 'stop-assistant.ps1'
$AoOwnedByThisNight = $false

# ---- admission provenance (2026-07-20) --------------------------------------
# Every night must record WHICH ADMISSION PATH it took and WHO BOOTED THE AO, in its
# own night dir, without inference. It could not before: Ensure-AoHeadless wrote
# $NightDir\ao-boot.log ONLY inside its `if (-not $aoUp)` branch, so a night admitted
# via the #784 probe (which RESTORES the AO itself) took the `else` branch and left no
# boot log at all -- while FIELD_NOTES.md tells the reader to "check the prior night's
# dir for ao-boot.log to see which topology it ran under".
# The 2026-07-19 night is exactly that hole, and it was the A/B night: nights 07-16,
# 07-17 and 07-18 each have an ao-boot.log; 07-19 has none. It WAS probe-admitted --
# recoverable now only from two file mtimes in a DIFFERENT directory
# (state/fleet-runs/start-llm.log at 23:01 showing the probe's real 30B load, and
# probe-ao-reboot.log at 23:03 showing its AO restore). Worse, the probe's own
# decision lines were invisible too: every Write-Log inside Test-NightAdmission went
# into that function's return value (the Write-Output defect above), so the memory
# numbers, the probe exit code and the AO restore were all swallowed together.
# Same defect class as the leak: something happens and nothing records that it did.
$script:AoBootSource      = 'not-booted'   # preflight-boot | probe-restore | already-up-preexisting
$script:AdmissionPath     = 'not-evaluated'
$script:AdmissionSamples  = @()
$script:AdmissionAttempts = 0
$script:ProbeRan          = $false
$script:ProbeExitCode     = $null
$script:ProbeOutcome      = ''
$script:StaleClaimReclaimed = $null
$script:ReclaimReason     = 'not-run'   # no-ao | claim-without-ao | stale-claim | unowned-ao | current-night

function Add-AdmissionSample([double]$Avail, [double]$Projected, [bool]$AoUp, [string]$Stage) {
    # Assignment only -- NOTHING here may emit to the success stream. These helpers are
    # called from inside value-returning functions, and a stray emission would land in
    # the caller's return value: the exact defect that killed the gate.
    $script:AdmissionSamples += ,([ordered]@{
        at = (Get-Date).ToUniversalTime().ToString('o')
        available_gib = [math]::Round($Avail, 2)
        projected_gib = [math]::Round($Projected, 2)
        ao_up = $AoUp
        stage = $Stage
    })
}

function Write-AoBootProvenance([string]$Line) {
    # ao-boot.log is written on EVERY path now, not just when this script boots the AO,
    # so its ABSENCE means "the night never reached preflight" rather than the
    # ambiguous "either it was already up or nobody recorded it". boot_launcher_detached
    # opens the same file in APPEND mode, so a header written here survives the boot.
    try {
        Add-Content -Path "$NightDir\ao-boot.log" -Encoding utf8 `
            -Value ("[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Line)
    } catch { }
}

function Write-AdmissionRecord([string]$Outcome) {
    # The night's provenance, machine-readable, in the night dir. Answers "what topology
    # did this night run under, and how was it admitted?" from the night directory alone.
    # Written on the admitted path AND on both skip paths, so a night that never ran
    # still says why. Never throws: provenance must not be able to sink a night.
    $record = [ordered]@{
        schema  = 'battery-admission/v1'
        night   = $Stamp
        outcome = $Outcome
        admission_path = $script:AdmissionPath
        attempts = $script:AdmissionAttempts
        gate = [ordered]@{ lean_gate_gib = $LEAN_GATE_GIB; probe_floor_gib = $PROBE_FLOOR_GIB }
        samples = @($script:AdmissionSamples)
        probe = [ordered]@{
            ran = $script:ProbeRan
            exit_code = $script:ProbeExitCode
            outcome = $script:ProbeOutcome
        }
        ao = [ordered]@{
            boot_source = $script:AoBootSource
            owned_by_this_night = $AoOwnedByThisNight
            stale_claim_reclaimed = $script:StaleClaimReclaimed
            preflight_reclaim = $script:ReclaimReason
            boot_log = 'ao-boot.log'
        }
        written_utc = (Get-Date).ToUniversalTime().ToString('o')
    }
    try {
        $record | ConvertTo-Json -Depth 6 | Set-Content "$NightDir\admission.json" -Encoding utf8
        Write-Log ("admission provenance: path={0} ao-boot-source={1} probe-ran={2} -> admission.json" -f `
            $script:AdmissionPath, $script:AoBootSource, $script:ProbeRan)
    } catch {
        Write-Log "WARNING: could not write admission.json ($($_.Exception.Message)) - provenance is on the transcript only."
    }
}

# Write-Host, NOT Write-Output (2026-07-20 fix). Write-Output writes to the SUCCESS
# stream, so a Write-Log call inside a VALUE-RETURNING function was captured into that
# function's return value instead of the transcript. Measured consequence: every
# `lean preflight:` line was swallowed (no night dir has ever logged a GiB number),
# and worse, Test-NightAdmission returned @("<log string>", $false) - a 2-element
# array, which PowerShell coerces TRUE - so `while (-not (Test-NightAdmission))` was
# ALWAYS false and the whole admission gate + 30-min retry + 04:00 skip was dead code.
# Write-Host bypasses the success stream (it cannot pollute a return value) and is
# still captured by Start-Transcript, so the log lines land where they always should
# have. verify-battery-ao-lifecycle.ps1 A6/B1 lock this shut.
function Write-Log([string]$msg) { Write-Host "[$(Get-Date -Format HH:mm:ss)] $msg" }

# A skipped night must not be SILENT. Both 04:00 skip paths used to `exit 0` having
# written only the launcher transcript, so state/battery/MORNING-REPORT.md still held
# the PREVIOUS night's result - the operator's morning read reported a night that never
# ran as if it had. That mattered little while the admission gate was dead code (it
# could never fire); resurrecting the gate makes this path reachable, so it now stamps
# its own report. Fail-loud (a control that degrades quietly is worse than none).
function Write-SkipReport([string]$reason) {
    $body = @(
        # ${Stamp} braces are REQUIRED before a colon: PowerShell reads `$Stamp:` as a
        # scope/drive qualifier (like $env:) and fails to parse the whole file.
        "# M2 battery — night ${Stamp}: SKIPPED",
        "",
        "## !! THE BATTERY DID NOT RUN TONIGHT !!",
        "",
        $reason,
        "",
        "No jobs were dispatched and no scorecards exist for this night. This is NOT",
        "counted as a pass and NOT a burned attempt - the campaign counters are unchanged.",
        "Launcher transcript: $NightDir\launcher.log"
    ) -join "`n"
    try {
        Set-Content "$NightDir\MORNING-REPORT.md" $body
        Set-Content "$AgenticRoot\state\battery\MORNING-REPORT.md" $body
        Write-Log "skip report written to state\battery\MORNING-REPORT.md (the morning read shows the skip, not last night's stale result)."
    } catch {
        Write-Log "WARNING: could not write the skip report ($($_.Exception.Message)) - the skip is on the transcript only."
    }
}

# ---- 0. elevation check (#756) ------------------------------------------------
# The BlarAI launcher SELF-ELEVATES when not admin (ShellExecute -> a UAC "Python"
# prompt nobody is present to click -> silent exit). On the 2026-07-07 night-2 run,
# BOTH non-elevated AO boots (the 23:53 preflight AND the 23:58 AoReensurer re-boot)
# died exactly this way — the AO never reached :5001 and the whole battery stalled.
# Warn LOUDLY (console + transcript, after Start-Transcript so it is on the record)
# but do NOT abort: an already-up AO can carry a non-elevated run, and a needed
# re-boot then fails honestly per-job, never silently.
$IsElevated = [Security.Principal.WindowsPrincipal]::new(
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $IsElevated) {
    @(
        "!! =====================================================================",
        "!! NOT ELEVATED: this shell is not running as Administrator.",
        "!! Any AO boot this run needs (preflight or a per-job AoReensurer re-boot)",
        "!! will STRAND on a UAC prompt with nobody present to click it — the",
        "!! launcher self-elevates via ShellExecute and silently exits (the night-2",
        "!! 2026-07-07 root cause: the AO never reached :5001).",
        "!! The correct manual invocation is the pre-elevated scheduled task:",
        "!!   Start-ScheduledTask -TaskPath '\BlarAI\' -TaskName 'BlarAI-M2-Battery-Nightly'",
        "!! (RunLevel=Highest, zero prompts). Proceeding anyway — an already-running",
        "!! AO can carry this run, but any needed re-boot WILL fail.",
        "!! ====================================================================="
    ) | ForEach-Object { Write-Warning $_ }
} else {
    Write-Log "elevation check: running as Administrator — AO boots will not UAC-strand."
}

# ---- 1. campaign state ------------------------------------------------------
# A bare `throw` here left NO morning report, so the one invocation a session is most
# likely to type by accident -- this driver by hand, without the bootstrap that hands it
# the state root -- failed with a stack trace and left the operator's morning read showing
# the previous night. Refuse in words instead, and name the actual cause when it is
# knowable: a pinned worktree's state\ is empty by construction, so the campaign is not
# missing, it is being looked for in the tree that never holds it.
if (-not (Test-Path $CampaignConfig)) {
    $hint = if (($AgenticStateRoot -eq $AgenticCodeRoot) -and
                (Test-Path -LiteralPath (Join-Path $AgenticCodeRoot '.git') -PathType Leaf)) {
        "This driver is running out of a PINNED worktree ($AgenticCodeRoot) with no state root handed to it, so it looked for the campaign in that worktree's empty state\ directory. Launch scripts\battery-bootstrap.ps1 instead - it is the entry point, and it is what tells this script where the campaign actually lives."
    } else {
        "There is no file at that path. It is the file that tells the night which jobs to run and holds the pass counters."
    }
    Write-Log "CAMPAIGN CONFIG MISSING: $CampaignConfig"
    Write-SkipReport "The battery did not start because it could not find the campaign file that tells it what to run. $hint Nothing was changed or deleted."
    Stop-Transcript | Out-Null
    exit 0
}
$camp = Get-Content $CampaignConfig -Raw | ConvertFrom-Json

# ---- 1a. hard end date (LA direction 2026-07-14) -----------------------------
# The campaign must not run indefinitely chasing a pass target that may never
# bank — LA set a calendar backstop independent of completed_passes ("extra
# passes are fine, running forever is not"). Optional field: absent/blank
# end_date = no calendar cutoff (a side/manual config just omits it). Scoped to
# $IsDefaultCampaign like the pass-count check below (2026-07-09 scoping fix) —
# a side config's cutoff must never touch the shared nightly task.
#
# THE PRESENCE TEST IS LOAD-BEARING, NOT DEFENSIVE (#1045). Without it the line above
# states a contract this check cannot honour. This script dot-sources ao-ownership-lib.ps1,
# which sets `Set-StrictMode -Version Latest`; dot-sourcing runs in the CALLER's scope, so
# StrictMode is live for the rest of this file, and under it a key the config does not have
# THROWS ("The property 'end_date' cannot be found on this object") instead of returning
# null. Measured across pwsh 7.6.4 and powershell 5.1, StrictMode on and off: the edition is
# irrelevant, StrictMode decides all of it.
#
# The default campaign always carries end_date, so the nightly never took this branch and no
# automated path could see the defect -- it was reachable ONLY from the documented
# side-config route, which is the daytime targeted-run mechanism. #1045 was closed
# 2026-07-22 by a commit fixing a DIFFERENT StrictMode instance in this same file (the
# postlude, 84891b2) while the reported one survived behind the runbook's "2099-12-31"
# workaround. Regression-locked by verify-side-config-optional-keys.ps1, which also pins
# this idiom so a future edit cannot quietly revert it. The idiom itself is the one this
# script already uses correctly for pass_banking_frozen and baseline_jobs.
if (($camp.PSObject.Properties.Name -contains 'end_date') -and $camp.end_date) {
    $endDate = [datetime]::ParseExact($camp.end_date, "yyyy-MM-dd", $null)
    if ((Get-Date).Date -gt $endDate) {
        Write-Log "Campaign end date ($($camp.end_date)) has passed ($($camp.completed_passes)/$($camp.target_full_passes) passes banked) — unregistering the scheduled task per the hard calendar cutoff."
        if ($IsDefaultCampaign) {
            try { Unregister-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -Confirm:$false } catch {}
        } else {
            Write-Log "side campaign config past its end date — NOT touching the shared scheduled task (scoping fix, 2026-07-09)."
        }
        Stop-Transcript | Out-Null
        exit 0
    }
}

if ($camp.completed_passes -ge $camp.target_full_passes) {
    if ($IsDefaultCampaign) {
        Write-Log "Campaign COMPLETE ($($camp.completed_passes)/$($camp.target_full_passes) passes) — unregistering the scheduled task."
        try { Unregister-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -Confirm:$false } catch {}
    } else {
        Write-Log "side campaign config complete ($($camp.completed_passes)/$($camp.target_full_passes)) — NOT touching the shared scheduled task (scoping fix, 2026-07-09)."
    }
    Stop-Transcript | Out-Null
    exit 0
}

# ---- 1b. pin the measured tree (#1181) ---------------------------------------
# Advance the measured worktree to main and PROVE it is what will execute, before the
# night touches anything. Placed here deliberately: no AO has been claimed, no sandbox
# built, no :5001 slot taken, so a refusal here costs nothing but the night.
#
# The refusal is the point. Every failure below stands the night down rather than falling
# back to the primary checkout -- a fallback would silently restore exactly the confound
# this replaces, while reporting a normal night. #1058 already refuses a dirty SANDBOX
# rather than measuring confounded; this is the same posture one level up, for the code
# doing the measuring.
#
# NOT destructive, ever. A dirty measured tree is REFUSED and left untouched: nobody should
# have work there, so if someone does it is either a bug worth seeing or a deliberate
# experiment, and discarding either is forbidden. `git switch --detach` also refuses on its
# own if it would overwrite local modifications -- git fails closed here too.
function Invoke-GitRead {
    # Native exit codes are the signal, so scope off the host preference that would turn a
    # non-zero exit into a throw (#903 pattern) and hand the caller both streams.
    param([Parameter(Mandatory)][string[]]$GitArgs)
    $prev = $PSNativeCommandUseErrorActionPreference
    try {
        $PSNativeCommandUseErrorActionPreference = $false
        $out = (& git @GitArgs 2>&1 | Out-String).Trim()
        return [pscustomobject]@{ Ok = ($LASTEXITCODE -eq 0); Out = $out; Code = $LASTEXITCODE }
    } catch {
        # `& git` when git is NOT ON PATH raises CommandNotFoundException, and that is
        # TERMINATING no matter what the preference above says -- that switch neutralises
        # native EXIT CODES, not "there is no such command". Uncaught it escapes the caller
        # entirely, so the stand-down report never runs and the operator's morning read
        # still shows the PREVIOUS night's result: a night that did not happen, reported as
        # one that did. Turn it into the failed read it actually is.
        return [pscustomobject]@{ Ok = $false; Out = "git could not be run: $($_.Exception.Message)"; Code = -1 }
    } finally { $PSNativeCommandUseErrorActionPreference = $prev }
}

function Sync-MeasuredTree {
    # Returns @{ Ok; Reason; Sha; Created }. NEVER falls back: a $false Ok is a stand-down,
    # and the caller must treat it as one. It does not throw for any git-side condition
    # (Invoke-GitRead absorbs those into a failed read); the call site still wraps it,
    # because a claim that something cannot throw is not a substitute for the caller being
    # able to survive it doing so.
    param(
        [Parameter(Mandatory)][string]$RuntimeRoot,
        [Parameter(Mandatory)][string]$MeasuredRoot
    )
    $bad = { param($why) [pscustomobject]@{ Ok = $false; Reason = $why; Sha = $null; Created = $false } }

    # The runtime root must be the PRIMARY checkout. In a linked worktree `.git` is a FILE
    # holding a `gitdir:` pointer; in the primary checkout it is a DIRECTORY. That one-stat
    # test is the cheapest honest proof that the weights and the minted certs live here,
    # and it catches the catastrophic mix-up (runtime pointed at a worktree) structurally.
    if (-not (Test-Path -LiteralPath $RuntimeRoot -PathType Container)) {
        return & $bad "the BlarAI runtime checkout is missing at $RuntimeRoot."
    }
    if (-not (Test-Path -LiteralPath (Join-Path $RuntimeRoot '.git') -PathType Container)) {
        return & $bad "$RuntimeRoot is not the primary BlarAI checkout (its .git is not a directory, so it is a linked worktree). The AO must boot from the primary checkout - it is the only one holding the gitignored model weights."
    }
    if (-not (Test-Path -LiteralPath (Join-Path $RuntimeRoot 'models') -PathType Container)) {
        return & $bad "$RuntimeRoot has no models\ directory, so the AO has no weights to load."
    }

    $mainRef = Invoke-GitRead @('-C', $RuntimeRoot, 'rev-parse', 'main')
    if (-not $mainRef.Ok) { return & $bad "could not read main's commit from $RuntimeRoot : $($mainRef.Out)" }
    $mainSha = $mainRef.Out

    # Create on absence. `git worktree add --detach` is PURELY ADDITIVE - a new directory
    # plus an admin entry; it cannot modify or destroy another session's work, and detached
    # means it claims no branch name anyone else might want. (It must be detached anyway:
    # git refuses to check out `main` in a second worktree, and another worktree already
    # holds it.) Refusing outright instead would cost a whole night for a condition the
    # script can repair safely in one additive command.
    $created = $false
    if (-not (Test-Path -LiteralPath $MeasuredRoot -PathType Container)) {
        Write-Log "measured tree absent - creating $MeasuredRoot detached at main $mainSha."
        $add = Invoke-GitRead @('-C', $RuntimeRoot, 'worktree', 'add', '--detach', $MeasuredRoot, $mainSha)
        if (-not $add.Ok) { return & $bad "could not create the measured worktree at $MeasuredRoot : $($add.Out)" }
        $created = $true
    }

    # ...and it must BE a linked worktree. The inverse of the runtime check: if this ever
    # resolved to the primary checkout, pinning would be a no-op wearing a pinned name.
    if (-not (Test-Path -LiteralPath (Join-Path $MeasuredRoot '.git') -PathType Leaf)) {
        return & $bad "$MeasuredRoot is not a linked git worktree (its .git is not a gitdir pointer file). Refusing rather than measuring an unpinned tree."
    }
    $commonA = Invoke-GitRead @('-C', $RuntimeRoot, 'rev-parse', '--path-format=absolute', '--git-common-dir')
    $commonB = Invoke-GitRead @('-C', $MeasuredRoot, 'rev-parse', '--path-format=absolute', '--git-common-dir')
    if (-not $commonA.Ok -or -not $commonB.Ok) { return & $bad "could not compare the two checkouts' git directories." }
    if ($commonA.Out -ne $commonB.Out) {
        return & $bad "$MeasuredRoot belongs to a different repository than $RuntimeRoot ($($commonB.Out) vs $($commonA.Out))."
    }

    # Cleanliness BEFORE the advance, so the advance only ever runs on a verified-clean tree.
    $dirty = Invoke-GitRead @('-C', $MeasuredRoot, 'status', '--porcelain')
    if (-not $dirty.Ok) { return & $bad "could not read the measured tree's status: $($dirty.Out)" }
    if ($dirty.Out) {
        $paths = ($dirty.Out -split "`n" | Select-Object -First 10) -join '; '
        return & $bad "the measured tree $MeasuredRoot is DIRTY and was left untouched (nothing is ever discarded there). Uncommitted paths: $paths"
    }

    $headRef = Invoke-GitRead @('-C', $MeasuredRoot, 'rev-parse', 'HEAD')
    if (-not $headRef.Ok) { return & $bad "could not read the measured tree's HEAD: $($headRef.Out)" }
    if ($headRef.Out -ne $mainSha) {
        Write-Log "advancing the measured tree $($headRef.Out.Substring(0,8)) -> main $($mainSha.Substring(0,8))."
        $sw = Invoke-GitRead @('-C', $MeasuredRoot, 'switch', '--detach', $mainSha)
        if (-not $sw.Ok) { return & $bad "could not advance the measured tree to main $mainSha : $($sw.Out)" }
    }

    # Re-verify AFTER the advance rather than trusting it: the advance is the step most
    # likely to half-succeed, and a half-advanced tree is the confound wearing a clean name.
    $headRef = Invoke-GitRead @('-C', $MeasuredRoot, 'rev-parse', 'HEAD')
    if (-not $headRef.Ok -or $headRef.Out -ne $mainSha) {
        return & $bad "the measured tree is at $($headRef.Out) after the advance, not main $mainSha."
    }
    $dirty = Invoke-GitRead @('-C', $MeasuredRoot, 'status', '--porcelain')
    if (-not $dirty.Ok -or $dirty.Out) {
        return & $bad "the measured tree is dirty immediately after advancing to main - refusing rather than measuring it."
    }
    # Belt: the commit must actually BE on main. `switch --detach <sha>` cannot land anywhere
    # else, but the whole ticket is about a version stamp nobody could find on main, so the
    # claim gets checked rather than assumed.
    $anc = Invoke-GitRead @('-C', $MeasuredRoot, 'merge-base', '--is-ancestor', $mainSha, 'main')
    if (-not $anc.Ok) { return & $bad "the pinned commit $mainSha is not contained in main." }

    return [pscustomobject]@{ Ok = $true; Reason = $null; Sha = $mainSha; Created = $created }
}

# The outer belt. Every failure the pin can NAME comes back as a $false Ok; this catch is
# for the ones it cannot -- a git binary that has moved, a permission error mid-stat, a
# filesystem that vanishes. Without it those escape to the top of the script, past
# Write-SkipReport, and leave state\battery\MORNING-REPORT.md holding LAST night's result:
# the operator reads a night that never ran as though it had, which is precisely the hole
# the skip report exists to close.
try {
    $MeasuredPin = Sync-MeasuredTree -RuntimeRoot $BlarRuntimeRoot -MeasuredRoot $BlarMeasuredRoot
} catch {
    Write-Log "MEASURED-TREE PIN ERRORED: $($_.Exception.Message)"
    Write-SkipReport "The battery could not check which version of itself it was about to run - the check itself failed with an unexpected error ($($_.Exception.Message)). It stood down rather than measure something it could not identify. Nothing was changed or deleted; the next scheduled night runs normally once that is resolved."
    Stop-Transcript | Out-Null
    exit 0
}
if (-not $MeasuredPin.Ok) {
    Write-Log "MEASURED-TREE PIN FAILED: $($MeasuredPin.Reason)"
    Write-SkipReport "The battery could not prove which version of itself it was about to run, so it stood down instead of producing a number nobody could trace. $($MeasuredPin.Reason) Nothing was changed or deleted. Once that is resolved the next scheduled night runs normally."
    Stop-Transcript | Out-Null
    exit 0
}
Write-Log "measured tree PINNED: $BlarMeasuredRoot @ main $($MeasuredPin.Sha)$(if ($MeasuredPin.Created) { ' (created tonight)' })."

# The runner, the probe and the AO boot all inherit this. It is what keeps the AO booting
# from the installation while the harness runs from the measured tree; without it the
# harness resolves certs/ and the per-job AO reboot against a worktree that has neither.
$env:BLARAI_BATTERY_RUNTIME_ROOT = $BlarRuntimeRoot

# REACHABILITY, not configuration. Import the measured tree's own runner under the env var
# just set and make it report the root it would boot an AO in. This is the one check that
# cannot be satisfied by a stale tree: if main does not yet carry the runtime-root split,
# the import prints the MEASURED root and the night stands down instead of STALLING every
# card on a certs/ directory that does not exist. Drives the real module, not a grep.
#
# BOTH modules, because proving one says nothing about the other: battery.py does not import
# probe.py, and the admission probe now runs from the measured tree as well. An import error
# in main's probe.py or config.py exits 1 down in the admission band, where exit 1 already
# means LOAD_FAILED -- so the night would rejoin the 30-minute retry loop and eventually tell
# the operator "the box never had enough free memory for the 30B coder model". A wrong cause,
# on the surface he actually reads, from a fault that has nothing to do with memory. Caught
# here it stands the night down once, with the real reason on the transcript.
#
# The answers arrive on NAMED lines, not as "the whole captured stream". Both streams are
# folded together for the transcript, so any deprecation notice, any import-time warning,
# any stderr line at all used to be part of the value being compared -- one of them and the
# night stands down for a pin that is working. Marker lines, last one wins, everything else
# is log.
$probeMarker = 'AO_BOOT_ROOT='
$probeMarker2 = 'PROBE_BOOT_ROOT='
$probeSrc = 'from tools.dispatch_harness import battery, probe; print("AO_BOOT_ROOT=" + str(battery._BLARAI_REPO_ROOT)); print("PROBE_BOOT_ROOT=" + str(probe._BLARAI_REPO_ROOT))'
$probeExit = -1
$probeRaw = ''
try {
    Push-Location $BlarMeasuredRoot
    try {
        $prevNativePref = $PSNativeCommandUseErrorActionPreference
        try {
            $PSNativeCommandUseErrorActionPreference = $false
            $probeRaw = (& $Python -c $probeSrc 2>&1 | Out-String).Trim()
            $probeExit = $LASTEXITCODE
        } finally { $PSNativeCommandUseErrorActionPreference = $prevNativePref }
    } finally { Pop-Location }
} catch {
    # `& $Python` with the venv python moved or rebuilt raises CommandNotFoundException --
    # terminating, and the likeliest way this block ever fails. Same shape and same stakes
    # as the git case above: uncaught, no morning report is written and the operator reads
    # last night's result as tonight's.
    Write-Log "MEASURED-TREE PIN ERRORED: could not run the reachability probe: $($_.Exception.Message)"
    Write-SkipReport "The battery stood down because it could not run the check that proves it knows where the assistant is installed ($($_.Exception.Message)). Its Python interpreter at $Python is the likely cause. Nothing was changed or deleted; the next scheduled night runs normally once that is resolved."
    Stop-Transcript | Out-Null
    exit 0
}
function Get-MarkedValue([string]$Raw, [string]$Marker) {
    # Last marked line wins; absent marker = '' (never $null, so the comparison below is a
    # mismatch rather than a member access on nothing).
    $hits = @($Raw -split "`r?`n" | Where-Object { $_.Trim().StartsWith($Marker) } |
        ForEach-Object { $_.Trim().Substring($Marker.Length).Trim() })
    if ($hits.Count -gt 0) { return $hits[-1] }
    return ''
}
$reportedRoot = Get-MarkedValue $probeRaw $probeMarker
$reportedProbeRoot = Get-MarkedValue $probeRaw $probeMarker2
$expectedRoot = (Resolve-Path -LiteralPath $BlarRuntimeRoot).Path.TrimEnd('\')
# Windows paths differ in case between the two spellings in use here ("C:\Users\mrbla\blarai"
# as configured, "C:\Users\mrbla\BlarAI" as python canonicalises it), so the comparison is
# case-insensitive BY STATEMENT rather than by PowerShell's default -- an editor tightening
# `-ne` to `-cne` would otherwise stand down every night, and the code would look stricter.
$rootsMatch = [string]::Equals($reportedRoot.TrimEnd('\'), $expectedRoot, [System.StringComparison]::OrdinalIgnoreCase)
$probeRootMatch = [string]::Equals($reportedProbeRoot.TrimEnd('\'), $expectedRoot, [System.StringComparison]::OrdinalIgnoreCase)
if ($probeExit -ne 0 -or -not $rootsMatch -or -not $probeRootMatch) {
    Write-Log "MEASURED-TREE PIN FAILED: the measured runner reports its AO-boot root as '$reportedRoot' and the admission probe's as '$reportedProbeRoot' (exit $probeExit), expected '$expectedRoot' for both. Full output: $probeRaw"
    Write-SkipReport "The battery stood down because the version of itself on main cannot yet be told where the assistant is installed, or could not be loaded at all. It reported '$reportedRoot' (runner) and '$reportedProbeRoot' (memory-admission check) instead of '$expectedRoot'. Running anyway would have failed every job for a missing security-certificate folder, or blamed a memory shortage that is not there. Nothing was changed or deleted; the next scheduled night runs normally once the matching BlarAI change is on main."
    Stop-Transcript | Out-Null
    exit 0
}
Write-Log "measured runner reachability: AO-boot root resolves to $reportedRoot (the installation) for the runner and $reportedProbeRoot for the admission probe; harness runs from $BlarMeasuredRoot (the measurement)."

# ---- the DRIVER's own commit (#1181) -----------------------------------------
# #1181's predicate is that a night records the state of BOTH trees. The scorecards stamp
# the BlarAI tree; nothing stamped this one -- yet the driver owns the job set, the
# admission gate, the budgets and the banking, so "which driver ran?" is half of what makes
# a night reproducible. It was recoverable only from a gitignored bootstrap log nothing
# points at. Computed here, rendered into the morning report the operator actually reads.
# $PSScriptRoot is the CODE root, so this is the pinned tree whenever the pin is in force.
$driverSha = Invoke-GitRead @('-C', $PSScriptRoot, 'rev-parse', '--short', 'HEAD')
$driverAnc = Invoke-GitRead @('-C', $PSScriptRoot, 'merge-base', '--is-ancestor', 'HEAD', 'main')
$DriverStamp = if (-not $driverSha.Ok) {
    "NOT RECORDED (could not read the driver's commit: $($driverSha.Out))"
} else {
    # Containment, not the branch name -- the pinned tree is detached by design, and the
    # only question worth asking of it is whether its commit is on main.
    $onMain = if ($driverAnc.Code -eq 0) { 'yes' } elseif ($driverAnc.Code -eq 1) { 'no' } else { 'unknown' }
    "{0} [on main: {1}] from {2}" -f $driverSha.Out, $onMain, $PSScriptRoot
}
Write-Log "driver stamp: $DriverStamp"

# LIVE-DISPATCH DETECTION (#1334, 2026-08-08). An INTERVAL question needs INTERVAL
# evidence, and every file-based marker in this system answers a SHORTER question than
# the one being asked.
#
# WHAT DEFEATED THE TWO PRIOR GUARDS
# ==================================
# Guard A watched :8000 ("no dispatch in flight"). That is the OVMS port, and the swap
# driver restores the 14B between jobs, so :8000 is NECESSARILY down between waves.
# Port-watching cannot be repaired; it samples an instant.
# Guard B (b7af0a0) counted TASK-START vs TASK-END in fleet-run journals. Between two
# waves those balance, correctly, while a run still owns its sandbox.
#
# AND THE OBVIOUS THIRD TRY IS ALSO WRONG. Journals also carry RUN-START/RUN-END, so
# "just go run-level" looks like the fix. It is not: those markers are emitted PER WAVE.
# Measured on the run destroyed 2026-08-07 23:01:15 (20260807-195617-bd): RUN-START=6,
# RUN-END=6 -- balanced. A run-level journal predicate would have admitted the collision
# for exactly the same reason the task-level one did. The journal has no marker for the
# outer interval at ANY level, so no reading of it can answer this.
#
# THE SOUND WITNESS IS THE DRIVING PROCESS
# ========================================
# A dispatch is live iff the process driving it exists. A process is an interval by
# construction: it spans the whole run INCLUDING the between-wave gaps that defeat every
# file marker. Measured against the live operator dispatch 2026-08-08 11:03:
#   pwsh    -File ...\scripts\run-fleet.ps1 -Queue ...   <- outer driver, whole dispatch
#   pythonw -m shared.fleet.swap_ops --spec ...          <- swap driver
#   python  -m tools.dispatch_harness.acp_coder ...      <- the coder leg
# This also covers OPERATOR-initiated dispatches, which claim no AO by design (:691) and
# were therefore invisible to every prior check -- the exact hole that let the 23:00
# nightly reclaim a live run's AO.
#
# IDENTITY comes from state/fleet-swap/spec.json (run_id/session_id), and ONLY identity.
# Never liveness: current.json still named a run that ended the previous night while a
# different run was live, so a file-keyed guard would name the wrong run confidently.
#
# FAIL-CLOSED: if the process table cannot be read, that is not evidence of absence --
# report LIVE and let the caller stand down.
#
# LOCKED BY scripts/verify-battery-live-dispatch-guard.ps1 -- S2/S4 the detector shapes,
# S3 the self-match trap, S5 the library lock with its toggle, S7 the wiring and the
# stand-down's four halves, S9 the elevation blind spot. Run it after touching ANY of the
# three call sites. Two modes: default REFUSES while a dispatch is live (the idle-box cases
# cannot be evaluated then), -LiveProof proves the detector against a real in-flight run.
#
# ORDERING REQUIREMENT, not an accident: `-m tools.dispatch_harness.` matches this script's
# OWN children -- the admission probe and the runner. The night avoids refusing itself only
# because the probe is synchronous and the archive loop runs BEFORE the runner launches.
# S7 asserts that order; do not reorder them without reading it.
function Get-LiveDispatch {
    # Returns $null when nothing is driving a dispatch, else a descriptor naming who.
    # Never throws.
    #
    # THE OVERRIDE IS HONOURED HERE, at the single point every caller goes through, rather
    # than at the four call sites — a lock that must be remembered in four places is a lock
    # that gets forgotten in one. See the -IgnoreLiveDispatch parameter for why this is a
    # switch and not a heuristic.
    #
    # Read via Get-Variable, not bare: this function is extracted by AST and run in an
    # isolated scope by verify-battery-live-dispatch-guard.ps1, where the parameter does
    # not exist and StrictMode would make a bare read a terminating error. Absent = not
    # overridden, which is the safe default.
    $overrideGuard = $false
    try { $overrideGuard = [bool](Get-Variable -Name IgnoreLiveDispatch -Scope Script -ValueOnly -ErrorAction Stop) } catch { }

    $all = @()
    try {
        $all = @(Get-CimInstance Win32_Process -ErrorAction Stop)
    } catch {
        if ($overrideGuard) {
            Write-Warning "OVERRIDE: -IgnoreLiveDispatch is set and the process table could not be read ($($_.Exception.Message)). Proceeding on the operator's assertion that no dispatch is live."
            return $null
        }
        return [pscustomobject]@{
            Why     = 'process-table-unreadable'
            Detail  = "could not enumerate processes ($($_.Exception.Message)); refusing rather than assuming the box is idle"
            Pids    = @()
            RunId   = ''
        }
    }

    $procs = @($all | Where-Object {
        # THE IMAGE AND THE FORM TOGETHER, never the form alone. Matching only the
        # argument text is not "invocation-form matching" — `-m shared.fleet.swap_ops`
        # appears verbatim inside any shell whose -Command MENTIONS it, so a diagnostic
        # one-liner, a grep, or this file's own verifier pinned the guard as though a
        # dispatch were live. That is the permanent-wedge route: the battery would wait
        # to 04:00 and stand down every night because somebody once ran a search.
        #
        # Caught by S3 the first time the suite was run in DEFAULT mode on an idle box —
        # the check existed from the start and had never once been evaluated, because a
        # dispatch was live every time it ran. An unrun check is not a passing check.
        #
        # Binding each pattern to the executable that can actually host it makes the match
        # a real form: a .ps1 is run by a shell, a `-m <module>` by an interpreter.
        $_.ProcessId -ne $PID -and $_.CommandLine -and (
            ($_.Name -match '^(pwsh|powershell)\.exe$' -and
             $_.CommandLine -match '-File\s+\S*run-fleet\.ps1') -or
            ($_.Name -match '^(python|pythonw)\.exe$' -and (
                $_.CommandLine -match '-m\s+shared\.fleet\.swap_ops' -or
                $_.CommandLine -match '-m\s+tools\.dispatch_harness\.'))
        )
    })
    if ($overrideGuard) {
        # Enumerated FIRST, then overridden, so the log NAMES what is being walked past.
        # An override that says only "proceeding" is worth much less to whoever reads this
        # transcript afterwards than one that says which pids the operator declared dead.
        if ($procs.Count -gt 0) {
            $names = ($procs | ForEach-Object { "$($_.Name):$($_.ProcessId) (started $($_.CreationDate))" }) -join '; '
            Write-Warning ("OVERRIDE: -IgnoreLiveDispatch is set. $($procs.Count) driving process(es) " +
                           "are being IGNORED on the operator's assertion that they are dead: $names")
        } else {
            Write-Warning "OVERRIDE: -IgnoreLiveDispatch is set, but no driving process was found anyway - the switch changed nothing."
        }
        return $null
    }
    if ($procs.Count -gt 0) {
        # fall through to the descriptor below
    } else {
        # NOTHING MATCHED - but "I saw nothing" is only evidence of absence if I could SEE.
        #
        # A non-elevated process cannot read an ELEVATED process's CommandLine: WMI returns
        # it as null. The matcher above requires a non-null CommandLine, so on a
        # non-elevated run every elevated driver is silently skipped and this function
        # would confidently report an idle box while a dispatch is mid-build. That is
        # fail-OPEN in the one direction that destroys somebody's work, and it is reachable
        # because the elevation check at the top of this script WARNS AND PROCEEDS by
        # design (#756: an already-up AO can carry a non-elevated run).
        #
        # So a negative answer is only returned when the blind spot is empty. Measured on a
        # healthy elevated box: 21 of 253 processes carry a null CommandLine and NONE of
        # them is a driver-capable image - those are System/Registry/Memory-Compression,
        # which have no command line at all rather than a hidden one. A driver-capable
        # image with an unreadable command line is therefore anomalous, and the honest
        # answer is "I cannot tell", which fails closed.
        $blind = @($all | Where-Object {
            -not $_.CommandLine -and $_.Name -match '^(python|pythonw|pwsh|powershell|node|opencode)\.exe$'
        })
        if ($blind.Count -gt 0) {
            # Elevation computed HERE rather than read from the script-scope $IsElevated:
            # this function is extracted by AST and run in an isolated scope by
            # verify-battery-live-dispatch-guard.ps1, where that variable does not exist and
            # StrictMode would make reading it a terminating error. A guard that throws
            # inside its own verifier is not a guard.
            $elev = try {
                [Security.Principal.WindowsPrincipal]::new(
                    [Security.Principal.WindowsIdentity]::GetCurrent()
                ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
            } catch { 'unknown' }
            $names = ($blind | ForEach-Object { "$($_.Name):$($_.ProcessId)" }) -join ', '
            return [pscustomobject]@{
                Why    = 'command-lines-unreadable'
                Detail = ("$($blind.Count) driver-capable process(es) have an unreadable command line " +
                          "($names) - this shell cannot see whether they are dispatch drivers " +
                          "(elevated=$elev). Refusing rather than reporting an idle box.")
                Pids   = @($blind | ForEach-Object { $_.ProcessId })
                RunId  = ''
            }
        }
        return $null
    }

    # Identity is best-effort and NEVER gates the refusal: an unnamed live dispatch is
    # still a live dispatch.
    $runId = ''
    try {
        $specPath = Join-Path $AgenticRoot 'state\fleet-swap\spec.json'
        if (Test-Path $specPath) {
            $spec = Get-Content $specPath -Raw -ErrorAction Stop | ConvertFrom-Json
            if ($spec.PSObject.Properties.Name -contains 'run_id') { $runId = [string]$spec.run_id }
        }
    } catch { $runId = '' }
    $first = $procs | Sort-Object CreationDate | Select-Object -First 1
    return [pscustomobject]@{
        Why    = 'driving-process-alive'
        Detail = ("pid $($first.ProcessId) ($($first.Name)) started $($first.CreationDate), " +
                  "$($procs.Count) driving process(es) total")
        Pids   = @($procs | ForEach-Object { $_.ProcessId })
        RunId  = $runId
    }
}

# ---- 2. dispatch guard --------------------------------------------------------
# Presence checks (LASTINPUTINFO idle + BlarAI app window) removed 2026-07-09 by
# LA direction: the battery launches at 23:00 regardless of operator presence.
# A dispatch already in flight defers the launch (collision, not presence).
$script:DispatchBusyReason = $null
function Test-DispatchBusy {
    # PRIMARY: the driving process, an INTERVAL. See the LIVE-DISPATCH DETECTION note
    # above for why the :8000 check below cannot answer this alone -- it is what logged
    # "guard clear - no dispatch in flight" at 2026-08-07 23:00:07 while a dispatch that
    # had been building for three hours was in flight, and the night then reclaimed that
    # run's AO and archived its sandbox (#1334).
    $live = Get-LiveDispatch
    if ($live) {
        $script:DispatchBusyReason = $live
        $named = if ($live.RunId) { " (run $($live.RunId))" } else { '' }
        Write-Log ("guard: a dispatch is LIVE$named - $($live.Detail). Waiting. This night will " +
                   "not reclaim the assistant or archive any sandbox while it runs.")
        return $true
    }
    # SECONDARY, kept as an INDEPENDENT lock rather than replaced: :8000 held with no
    # driving process still means something is using the coder model server. It is the
    # weaker signal (necessarily down between waves), so it is never the only one.
    $coderBusy = Test-NetConnection -ComputerName 127.0.0.1 -Port 8000 -InformationLevel Quiet -WarningAction SilentlyContinue
    if ($coderBusy) {
        $script:DispatchBusyReason = [pscustomobject]@{
            Why = 'coder-port-held'; Detail = ':8000 is held but no driving process was found'
            Pids = @(); RunId = ''
        }
        Write-Log "guard: :8000 busy (the coder model server is in use) - waiting."
        return $true
    }
    $script:DispatchBusyReason = $null
    return $false
}
if (-not $Now) {
    $cutoff = (Get-Date).Date.AddDays(1).AddHours(4)   # stop retrying at 04:00
    while (Test-DispatchBusy) {
        if ((Get-Date) -gt $cutoff) {
            # SAY WHICH LOCK HELD. "the coder port" was the only reason this could ever
            # give, so a stand-down caused by a live operator dispatch would have been
            # reported as a port collision -- right stand-down, wrong cause, and the
            # operator reads this text.
            $why = if ($script:DispatchBusyReason) {
                switch ($script:DispatchBusyReason.Why) {
                    'driving-process-alive'      { "A coding dispatch was still running ($($script:DispatchBusyReason.Detail))" }
                    'process-table-unreadable'   { "The battery could not check whether anything else was running ($($script:DispatchBusyReason.Detail))" }
                    default                      { "The coder model server was in use ($($script:DispatchBusyReason.Detail))" }
                }
            } else { "Something held the box" }
            Write-Log "Guard never cleared by 04:00 - skipping tonight (not counted as a pass)."
            Write-SkipReport "$why continuously from 23:00 to 04:00, so the battery never had the box to itself. It waited on 30-minute retries and then stood down rather than clobber a run in flight."
            $script:AdmissionPath = 'dispatch-busy'
            Write-AdmissionRecord 'skipped-dispatch-busy'
            Stop-Transcript | Out-Null; exit 0
        }
        Write-Log "guard: retrying in 30 min."
        Start-Sleep -Seconds 1800
    }
    # CLAIM ONLY WHAT WAS CHECKED (#1324's lesson, applied here): name both locks, so a
    # future reader knows this line rests on a process scan AND a port probe, not on one
    # port probe wearing the words "no dispatch in flight".
    Write-Log "guard clear - no driving dispatch process, and :8000 is free."
}

# ---- job set for the night --------------------------------------------------
$jobs = @($camp.jobs)
# `excluded` is OPTIONAL and was the second live instance of #1045's defect, found by the
# sweep that ticket asked for: a side config with nothing to exclude has no reason to carry
# the key, and the bare access throws under the StrictMode that ao-ownership-lib.ps1
# leaks into this scope when it is dot-sourced.
# `jobs`, `completed_passes` and `target_full_passes` are deliberately left bare -- they are
# REQUIRED, a campaign without them is meaningless, and a missing one should fail loud here
# rather than be silently defaulted into a night that runs the wrong job set.
$excludedRaw = if ($camp.PSObject.Properties.Name -contains 'excluded') { $camp.excluded } else { @() }
$excluded = @($excludedRaw | ForEach-Object { "$($_.id) ($($_.reason))" })
if ($excluded) { Write-Log ("excluded (config, NOT silent): " + ($excluded -join "; ")) }
if ((Get-Date).Hour -ge 1 -and (Get-Date).Hour -lt 12 -and $jobs -contains "B6") {
    Write-Log "late start ($(Get-Date -Format HH:mm)) — trimming the B6 stretch job tonight (logged, not silent)."
    $jobs = $jobs | Where-Object { $_ -ne "B6" }
}
Write-Log ("tonight's jobs: " + ($jobs -join ", "))

# ---- 3. preflight -----------------------------------------------------------
# Stale cancel file from a prior manual stop must not kill the first job.
$cancel = "$AgenticRoot\state\fleet-swap\cancel"
if (Test-Path $cancel) { Remove-Item $cancel -Force; Write-Log "cleared stale cancel file." }

# LEG B - preflight reclaim (2026-07-20). Clear the :5001 slot before anything measures
# memory. Reclaim it HERE: before the task-settings and budget checks, and well before
# Measure-SwapHeadroom, so the freed RAM has settled by the time the admission gate reads
# Available. This is the leg that makes the fix structural rather than vigilance - Leg A
# below can be skipped by a kill -9, but the slot is re-examined every night regardless.
#
# The trigger is the SLOT, not a sentinel (review finding): reclaiming only sentinel-owned
# AOs missed everything nothing ever claimed - a hand-run probe restore, an operator
# session, a night that died before claiming - and the resurrected gate turns that miss
# into a LOST night, because an unowned resident AO fails the fast path (Projected =
# Available + 8.0 ~= 14 GiB, short of $LEAN_GATE_GIB) AND the probe floor (raw Available
# ~= 6 GiB < 15.0).
# See ao-ownership-lib.ps1's Invoke-AoPreflightReclaim for why this is safe.
# Scoped to the scheduled night: under -Now a human is at the keyboard and owns the
# box (the standing -Now posture - verify-battery-probe-admission.ps1 S5).
if (-not $Now) {
    try {
        # The launcher observes the slot; the library decides whether to stop. Keeping the
        # detection here means ao-ownership-lib.ps1 never grows a second process detector.
        $aoHeld = [bool](Test-NetConnection -ComputerName 127.0.0.1 -Port 5001 -InformationLevel Quiet -WarningAction SilentlyContinue)
        # RE-CHECKED here, not reused from the dispatch guard above: that loop can wait on
        # 30-minute retries until 04:00, so its answer may be hours old by now, and a
        # dispatch can start in the gap. A stale liveness reading is the defect this
        # ticket exists to remove, not a shortcut to take while removing it.
        $liveNow = Get-LiveDispatch
        $reclaim = Invoke-AoPreflightReclaim -SentinelPath $AoOwnerSentinel -CurrentNight $Stamp `
            -AoPresent $aoHeld -LiveDispatch $liveNow -BlarAiRepo $BlarRuntimeRoot `
            -StopAssistantPath $StopAssistantPath -Log ${function:Write-Log}
        if ($reclaim) {
            $script:ReclaimReason = [string]$reclaim.Reason
            if ($reclaim.Reclaimed) { $script:StaleClaimReclaimed = [string]$reclaim.ClaimedNight }
        }
    } catch {
        Write-Log "ao-ownership: preflight reclaim errored ($($_.Exception.Message)) - non-fatal, continuing the night."
    }

    # CLAIM HERE, not after admission (same review finding). The #784 probe runs DURING
    # admission and its always-restore discipline boots an AO; claiming only after
    # admission left that AO unowned for the entire retry window, so a night killed
    # mid-admission leaked it with no sentinel at all. Claiming before the measurement
    # means the night owns the :5001 SLOT from preflight onward, whoever fills it.
    $null = Set-AoOwner -SentinelPath $AoOwnerSentinel -Night $Stamp -OwnerPid $PID
    $AoOwnedByThisNight = $true
    Write-Log "ao-ownership: night $Stamp CLAIMED the :5001 slot (sentinel $AoOwnerSentinel) before the admission measurement; whatever ends up holding it is torn down at end of night."
} else {
    Write-Log "ao-ownership: manual (-Now) run - NOT reclaiming and NOT claiming (the operator owns the box in daylight)."
}

# #833 task-settings conformance: the scheduled task's OWN ExecutionTimeLimit must still
# DOMINATE the runner's per-job budgets (the durable control for the 2026-07-11 PT10H
# incident, where the ceiling tree-killed the runner 3 min before its last job finished).
# READ-ONLY + NON-FATAL: a drift is logged loud and banners the morning report so it is
# caught the next morning at the latest, but it never aborts a night (a too-low ceiling
# only risks a LATE kill; denying the night outright would be worse). A missing or
# throwing check must equally never sink the run, so it is wrapped despite the script's
# ErrorActionPreference=Stop. verify-battery-task-settings.ps1 derives the required floor
# from BlarAI's own runner constants (tools.dispatch_harness.battery_execution_limit).
$TaskSettingsDrift = $null
$verifyTaskSettings = "$PSScriptRoot\verify-battery-task-settings.ps1"
try {
    if (Test-Path $verifyTaskSettings) {
        # The drift SIGNAL rides the child's exit code, so read it host-preference-independently
        # (#903). This launcher runs ErrorActionPreference=Stop; on a host where
        # $PSNativeCommandUseErrorActionPreference is $true, a non-zero `& pwsh` exit would THROW
        # instead of setting $LASTEXITCODE — the throw would land in the generic catch below and
        # MISLABEL a real settings drift as "check errored", muddying the morning DRIFT banner.
        # (The night is never aborted either way — this check is non-fatal — so this is pure
        # signal fidelity, not a run-safety fix.) Scope the preference to $false around JUST this
        # call (save/restore), leaving the launcher's other native calls — git, the python probe,
        # the runner — on the box default. Mirrors verify-battery-task-settings.ps1's own internal
        # setting; a genuine launch failure (child missing/uninvokable) still throws -> the catch's
        # honest "errored" path, distinct from a drift.
        $prevNativeErrPref = $PSNativeCommandUseErrorActionPreference
        try {
            $PSNativeCommandUseErrorActionPreference = $false
            # -CampaignConfig is the DEFAULT campaign deliberately, never $CampaignConfig:
            # T7 checks the two-lock calendar cutoff between the SHARED nightly task and the
            # campaign that governs it. Handing it a side config during a targeted run would
            # compare the task's EndBoundary against a campaign that does not own it and
            # report drift that is not there (#1181a; the §3 side-config discipline).
            & pwsh -NoProfile -ExecutionPolicy Bypass -File $verifyTaskSettings `
                    -BlarRepo $BlarRuntimeRoot -CampaignConfig $DefaultCampaignConfig *>&1 |
                ForEach-Object { Write-Log "task-settings: $_" }
            $verifyExit = $LASTEXITCODE
        } finally {
            $PSNativeCommandUseErrorActionPreference = $prevNativeErrPref
        }
        if ($verifyExit -ne 0) {
            $TaskSettingsDrift = "scheduled-task settings DRIFTED (verify-battery-task-settings.ps1 exit $verifyExit) - the ExecutionTimeLimit/trigger/RestartCount no longer conform (see the launcher log above). A drifted ExecutionTimeLimit is the PT10H incident class."
            Write-Log "WARNING: $TaskSettingsDrift"
        } else {
            Write-Log "task-settings: conform (ExecutionTimeLimit covers the runner run-phase floor)."
        }
    } else {
        Write-Log "task-settings: verify-battery-task-settings.ps1 not found at $verifyTaskSettings - skipping (non-fatal)."
    }
} catch {
    Write-Log "task-settings: check errored ($($_.Exception.Message)) - non-fatal, continuing the night."
}

# #790 budget-coherence conformance: the (window, budget) INNER pairs the idle-600 landing put under
# stress -- the per-candidate ceiling must dominate acp.idle_sec (C1), and each per-job budget must cover
# a multi-wave job's candidate wall-time under idle-600 (C2, the Blair's Lab starvation), while a C2-fix
# must still fit PT16H (C3). This is the sibling of the #833 task-settings check (which owns the OUTER
# ExecutionTimeLimit pair). READ-ONLY + NON-FATAL, same posture: a drift is logged loud and banners the
# morning report, but never aborts a night (a starved multi-wave job is a reliability loss, not a reason
# to deny the whole battery). Wrapped despite ErrorActionPreference=Stop so a missing/throwing check
# never sinks the run.
$BudgetDrift = $null
$verifyBudget = "$PSScriptRoot\verify-battery-budget-coherence.ps1"
try {
    if (Test-Path $verifyBudget) {
        $prevNativeErrPref = $PSNativeCommandUseErrorActionPreference
        try {
            $PSNativeCommandUseErrorActionPreference = $false
            & pwsh -NoProfile -ExecutionPolicy Bypass -File $verifyBudget -BlarRepo $BlarRuntimeRoot *>&1 |
                ForEach-Object { Write-Log "budget-coherence: $_" }
            $budgetExit = $LASTEXITCODE
        } finally {
            $PSNativeCommandUseErrorActionPreference = $prevNativeErrPref
        }
        if ($budgetExit -ne 0) {
            $BudgetDrift = "battery budget INCOHERENT under idle-600 (verify-battery-budget-coherence.ps1 exit $budgetExit) - a multi-wave job can starve on its per-job run budget (the Blair's Lab STALLED/HARNESS class). Fix is BlarAI-side (swap_run_budget_s / a multi-wave card run_budget_s); see the launcher log above."
            Write-Log "WARNING: $BudgetDrift"
        } else {
            Write-Log "budget-coherence: conform (per-job budget covers a multi-wave job under idle-600)."
        }
    } else {
        Write-Log "budget-coherence: verify-battery-budget-coherence.ps1 not found at $verifyBudget - skipping (non-fatal)."
    }
} catch {
    Write-Log "budget-coherence: check errored ($($_.Exception.Message)) - non-fatal, continuing the night."
}

# LEAN + PROBE ADMISSION (#784, reworked 2026-07-10; supersedes the #740 c.1504 arithmetic-
# only gate). The 30B swap needs the BlarAI swap gate's worth of system RAM free AFTER the 14B
# unloads (swap_driver gate_gb, resolved from [fleet_dispatch].swap_min_free_gb — 19.0 by LA
# directive #1313 since 2026-08-07, and UNMEASURED at that value; the 14B returns ~8.7 GiB,
# projected conservatively at 8.0 here). Two-stage admission:
#
#   FAST PATH (unchanged) — PROJECT post-unload headroom; if it clears $LEAN_GATE_GIB (the swap
#     gate + 0.5 margin) proceed immediately. Short -> lean the known-safe restartable apps
#     (firefox, OneDrive — the LA's standing process authority, codified in settings 2026-07-09;
#     firefox restores its session, OneDrive re-syncs) and re-project.
#
#   PROBE (new, #784) — the arithmetic gate has a DEAD BAND: #777 proved a CLEAN load from
#     19.85 GiB, yet the projection gate (20.5 at the time) would wait all night on it (nights 2026-07-08
#     attempt 1+2 burned SIX stalls at 20.7/20.6 GiB and ~2.5 h of darkness on exactly this
#     gap). Predicting a threshold never ends the 20-vs-18-vs-17.5 argument; MEASURING does. So
#     when the projection is still short after leaning but Available >= $PROBE_FLOOR_GIB (15.0,
#     a sanity floor, NOT a prediction), attempt the REAL 30B load once, OUTSIDE any job (the
#     probe stamps no verdict/swap-state/scorecard), bounded by this same 04:00 deadline and an
#     always-restore abort. Probe exit 0 -> admit the night; 1/2/3 -> rejoin the 30-min retry
#     loop. Below the floor -> too starved to probe; retry. GiB is BINARY (/1024), matching
#     swap_ops.real_available_gb — the F1 decimal-GB trap.
function Get-ProjectedSwapHeadroomGiB {
    param([bool]$AoUp)
    $availGiB = (Get-Counter '\Memory\Available MBytes' -ErrorAction Stop).CounterSamples[0].CookedValue / 1024
    # With the 14B resident its ~8 GiB comes back at unload; with the AO down it is already free.
    if ($AoUp) { return @{ Avail = $availGiB; Projected = $availGiB + 8.0 } }
    return @{ Avail = $availGiB; Projected = $availGiB }
}
$LEAN_GATE_GIB   = 19.5   # fast-path projection gate: the BlarAI swap gate + 0.5 margin. The gate is
                          # 19.0 by LA directive (#1313, 2026-08-07) and is NOT measured — read
                          # [fleet_dispatch].swap_min_free_gb's comment before trusting this number.
$PROBE_FLOOR_GIB = 15.0   # #784: below this Available, too starved to even probe (sanity, not prediction)
# Apps the night MAY force-stop to make room. Every entry must restart clean with no
# operator data at risk: browsers restore their session, OneDrive re-syncs, chat/media
# clients are stateless. (LA standing process authority, codified 2026-07-09. BROADENED
# 2026-07-20: the original two-app list still let Chrome / Edge / Slack / Teams block a
# night — the identical "I forgot to close it" failure firefox was already covered for.)
$LEAN_SAFE_PROCS = @(
    'firefox', 'OneDrive',
    'msedge', 'chrome', 'brave', 'opera', 'vivaldi',
    'Slack', 'Teams', 'ms-teams', 'Discord', 'Spotify', 'WhatsApp', 'Telegram', 'Steam',
    # WINWORD added 2026-07-20 on the LA's explicit instruction: he runs Word with AutoSave
    # to cloud ON, so a force-stop does not cost him the document, and he does not want a
    # night skipped because Word was left open. Word's own AutoRecover is the second net.
    # EXCEL / POWERPNT deliberately NOT added — the same AutoSave reasoning probably applies
    # but has not been confirmed for them, and guessing with someone's spreadsheet is not ours
    # to do. Adding them is a one-line change once confirmed.
    'WINWORD'
)

# NEVER lean these: they can hold UNSAVED operator work with no cloud AutoSave behind it,
# and a force-stop DESTROYS it. A night that skips because one of these is resident is the
# CORRECT outcome — losing the operator's work to buy one battery run is never the right
# trade. Named explicitly so a later session broadening the safe list cannot quietly add
# one; the guard below has teeth. (Editors/IDEs especially: they hold unsaved buffers.)
$LEAN_NEVER_PROCS = @(
    'EXCEL', 'POWERPNT', 'OUTLOOK', 'ONENOTE', 'Acrobat', 'AcroRd32',
    'Code', 'devenv', 'notepad', 'notepad++', 'sublime_text', 'pycharm64', 'idea64'
)
$__leanOverlap = @($LEAN_SAFE_PROCS | Where-Object { $LEAN_NEVER_PROCS -contains $_ })
if ($__leanOverlap.Count -gt 0) {
    throw "lean safe-list contains a never-lean process (would destroy unsaved work): $($__leanOverlap -join ', ')"
}

# Measure the post-unload headroom, leaning the restartable apps if the first projection is
# short; returns @{ Avail; Projected } POST-lean. No probe, no block — the admission/-Now
# callers decide what to do with the number.
function Measure-SwapHeadroom {
    $aoNow = Test-NetConnection -ComputerName 127.0.0.1 -Port 5001 -InformationLevel Quiet -WarningAction SilentlyContinue
    $h = Get-ProjectedSwapHeadroomGiB -AoUp $aoNow
    Write-Log ("lean preflight: available {0:N1} GiB, projected post-unload {1:N1} GiB (fast-path gate {2} GiB)" -f $h.Avail, $h.Projected, $LEAN_GATE_GIB)
    Add-AdmissionSample $h.Avail $h.Projected ([bool]$aoNow) 'initial'
    # LEAN UNCONDITIONALLY at the START of every night (LA instruction 2026-07-20) rather
    # than only when the projection already looks short. The night runs at 23:00 with the
    # operator asleep and every safe-list entry restores itself, so the cost is nil — and it
    # takes the threshold arithmetic OUT of the path that decides whether the night happens
    # at all. A night must never be lost to an app someone forgot to close.
    $stopped = 0
    foreach ($p in $LEAN_SAFE_PROCS) {
        $procs = Get-Process -Name $p -ErrorAction SilentlyContinue
        if ($procs) {
            $gb = ($procs | Measure-Object WorkingSet64 -Sum).Sum / 1GB
            Write-Log ("lean preflight: stopping {0} ({1:N1} GB resident, restartable)." -f $p, $gb)
            $procs | Stop-Process -Force -ErrorAction SilentlyContinue
            $stopped++
        }
    }
    if ($stopped -gt 0) {
        Start-Sleep -Seconds 20   # let the working sets actually return
        $aoNow2 = Test-NetConnection -ComputerName 127.0.0.1 -Port 5001 -InformationLevel Quiet -WarningAction SilentlyContinue
        $h = Get-ProjectedSwapHeadroomGiB -AoUp $aoNow2
        Write-Log ("lean preflight: post-lean available {0:N1} GiB, projected {1:N1} GiB ({2} app(s) stopped)" -f $h.Avail, $h.Projected, $stopped)
        Add-AdmissionSample $h.Avail $h.Projected ([bool]$aoNow2) 'post-lean'
    } else {
        Write-Log "lean preflight: nothing to lean — no restartable app was running."
    }
    # Still short? Name the never-lean holders. Turns a silent skip into an actionable
    # morning line ("WINWORD held 0.6 GiB and was deliberately left alone") instead of an
    # unexplained one. Assignment + Write-Log (Write-Host) ONLY — nothing here may reach the
    # success stream or it pollutes this function's return value (the #987 defect).
    if ($h.Projected -lt $LEAN_GATE_GIB) {
        $held = @(Get-Process -ErrorAction SilentlyContinue |
            Where-Object { $LEAN_NEVER_PROCS -contains $_.ProcessName } |
            Group-Object ProcessName |
            ForEach-Object { '{0} ({1:N1} GiB)' -f $_.Name, (($_.Group | Measure-Object WorkingSet64 -Sum).Sum / 1GB) })
        if ($held.Count -gt 0) {
            Write-Log ("lean preflight: still short — these were NOT auto-closed because they can hold unsaved work: {0}" -f ($held -join ', '))
        }
    }
    return $h
}

# AO headless on :5001 (production env — no debug vars). Boot via the SAME tested detached
# path the battery runner uses (tools.dispatch_harness.battery.boot_launcher_detached): a plain
# `Start-Process -WindowStyle Hidden` hands the launcher a hidden CONSOLE, which drives Textual
# into "Driver must be in application mode" and crashes the boot in an interactive/`-Now` run;
# DETACHED_PROCESS (no console) makes it fall back to the headless driver (found live 2026-07-06).
# The wait is NON-FATAL: the runner's per-job AoReensurer re-boots (and heals cert-drift — a
# socket that is up but whose mTLS leaf no longer verifies) as the backstop, so a slow or failed
# boot must NOT abort the night. Called at preflight AND after a successful probe (which restores
# the AO — the runner expects it up at start).
function Ensure-AoHeadless {
    # $Context names WHICH call site this is, so ao-boot.log records not just "the AO was
    # up" but who put it there: the post-probe call can only find it up because the probe
    # restored it.
    param([string]$Context = 'preflight')
    $aoUp = Test-NetConnection -ComputerName 127.0.0.1 -Port 5001 -InformationLevel Quiet -WarningAction SilentlyContinue
    if (-not $aoUp) {
        Write-Log "booting the AO headless (detached)..."
        $script:AoBootSource = 'preflight-boot'
        Write-AoBootProvenance "AO DOWN at the $Context check - this launcher is booting it (boot_launcher_detached, production, detached). Boot output follows."
        $bootPy = 'import sys; from pathlib import Path; from tools.dispatch_harness.battery import boot_launcher_detached; boot_launcher_detached(Path(sys.argv[1]), Path(sys.argv[2]))'
        Push-Location $BlarRuntimeRoot
        try {
            # Route the boot command's own output through Write-Log rather than letting it
            # fall to the success stream. Ensure-AoHeadless is called FROM INSIDE
            # Test-NightAdmission (the post-probe re-verify), so a bare native call here
            # would land its stdout in that function's return value -- the same
            # array-instead-of-bool shape that killed the admission gate. Nothing is lost:
            # the boot's real log is the file passed as its second argument.
            & $Python -c $bootPy $BlarRuntimeRoot "$NightDir\ao-boot.log" 2>&1 |
                ForEach-Object { Write-Log "ao-boot: $_" }
        } finally { Pop-Location }
        $deadline = (Get-Date).AddSeconds(240)   # a cold 14B load can exceed 2 min
        while (-not (Test-NetConnection 127.0.0.1 -Port 5001 -InformationLevel Quiet -WarningAction SilentlyContinue)) {
            if ((Get-Date) -gt $deadline) {
                Write-Log "WARNING: AO not up on :5001 within 240s of the preflight boot — proceeding anyway; the runner's per-job AoReensurer will re-boot it (non-fatal backstop)."
                break
            }
            Start-Sleep -Seconds 3
        }
        # SAY ONLY WHAT WAS MEASURED (#1324). This is a TCP accept on :5001 and nothing more
        # -- NOT evidence the model loaded or that the AO can answer anything. Measured
        # 2026-08-07: on B9 run 1 this logged "AO up." 31 seconds after boot while the GPU
        # had already failed to initialise ("no opencl gpu device is available"), the model
        # never loaded, and every request that followed timed out. The line was true about
        # the socket and false about the assistant, and the failure was then charged to
        # HARNESS-BUDGET -- right bucket, wrong cause, because the log had asserted a
        # readiness nobody had checked. A real serve-probe (issue a request the model must
        # answer) is the actual fix and remains open on #1324; until it exists this line must
        # not claim more than a port check can support. A 14B does not load in 31 seconds.
        if (Test-NetConnection 127.0.0.1 -Port 5001 -InformationLevel Quiet -WarningAction SilentlyContinue) {
            Write-Log "AO port :5001 accepting (TCP check only - NOT proof the model loaded or can serve; #1324)."
        }
    } else {
        Write-Log "AO already up on :5001 — the runner's per-job AoReensurer verifies its mTLS health before each job and re-boots on cert-drift."
        # The ELSE branch used to record NOTHING. Attribute the AO instead of leaving the
        # night dir silent: after a successful probe the AO can only be up because the
        # probe restored it, so that path is named rather than inferred.
        if ($script:AoBootSource -eq 'not-booted') {
            $script:AoBootSource = if ($Context -eq 'post-probe') { 'probe-restore' } else { 'already-up-preexisting' }
        }
        Write-AoBootProvenance ("AO ALREADY UP at the $Context check - not booted by this launcher. Attributed to: {0}." -f $script:AoBootSource)
    }
}

# ONE admission decision: $true to ADMIT (run tonight), $false to RETRY (rejoin the wait loop).
# Fast path first; then the #784 probe in the marginal band. Only ever called under NON-$Now.
function Test-NightAdmission {
    # Every statement added here is an ASSIGNMENT to a $script: variable. Nothing in this
    # function may emit to the success stream -- an emission is captured into the return
    # value and turns the boolean into a truthy array, which is precisely how this gate
    # came to be dead code. verify-battery-ao-lifecycle.ps1 B1 locks the return type.
    $script:AdmissionAttempts++
    $h = Measure-SwapHeadroom
    if ($h.Projected -ge $LEAN_GATE_GIB) {
        Write-Log ("lean preflight: fast path — projected {0:N1} GiB clears the {1} GiB gate." -f $h.Projected, $LEAN_GATE_GIB)
        $script:AdmissionPath = 'fast-path'
        return $true
    }
    if ($h.Avail -lt $PROBE_FLOOR_GIB) {
        Write-Log ("lean preflight: available {0:N1} GiB below the probe floor {1} GiB — too starved to probe; retrying." -f $h.Avail, $PROBE_FLOOR_GIB)
        $script:AdmissionPath = 'below-probe-floor'
        return $false
    }
    Write-Log ("lean preflight: projected {0:N1} GiB short of {1} but available {2:N1} GiB >= probe floor {3} — PROBING a real 30B load (#784; ends the dead band #777 exposed)." -f $h.Projected, $LEAN_GATE_GIB, $h.Avail, $PROBE_FLOOR_GIB)
    # MEASURED root, like the runner below it (#1181). `-m` resolves the module from the
    # cwd, so this is what decides whether the admission gate is pinned code -- and the
    # admission gate decides whether the night happens at all, which makes it part of the
    # instrument, not part of the installation. Run from the runtime root it was the one
    # piece of the night still executing whatever branch that checkout was parked on.
    # The probe still ACTS on the installation: BLARAI_BATTERY_RUNTIME_ROOT is exported
    # above, and probe._BLARAI_REPO_ROOT resolves through it, so the AO it stops and
    # restores is the installed one and the config it reads is the installation's.
    Push-Location $BlarMeasuredRoot
    try {
        # 2>&1 folds the probe's stderr log line into the captured output (kept for the
        # transcript); the branch is on the EXIT CODE, which is the reliable signal.
        $probeOut = (& $Python -m tools.dispatch_harness.probe --min-free-gb $PROBE_FLOOR_GIB --json 2>&1 | Out-String).Trim()
        $probeExit = $LASTEXITCODE
    } finally { Pop-Location }
    Write-Log "probe: exit $probeExit -- $probeOut"
    $script:ProbeRan = $true
    $script:ProbeExitCode = $probeExit
    $script:ProbeOutcome = $probeOut
    if ($probeExit -eq 0) {
        Write-Log "probe: the 30B loaded outside any job (exit 0) — ADMITTING the night."
        $script:AdmissionPath = 'probe-admitted'
        # -Context 'post-probe' is what lets ao-boot.log attribute an already-up AO to the
        # probe's restore instead of leaving the night dir silent (the 2026-07-19 hole).
        Ensure-AoHeadless -Context 'post-probe'   # the probe restored the AO; re-verify + re-boot if needed (non-fatal)
        return $true
    }
    Write-Log "probe: did NOT admit (exit $probeExit) — rejoining the 30-min retry loop."
    $script:AdmissionPath = 'probe-refused'
    return $false
}

if (-not $Now) {
    $cutoffLean = (Get-Date).Date.AddDays(1).AddHours(4)
    while (-not (Test-NightAdmission)) {
        if ((Get-Date) -gt $cutoffLean) {
            Write-Log "lean preflight: never admitted by 04:00 — skipping tonight (not counted as a pass; NOT a burned attempt)."
            Write-SkipReport "The box never had enough free memory for the 30B coder model. From 23:00 to 04:00 the admission gate re-measured every 30 minutes (and probed a real load whenever available memory cleared the $PROBE_FLOOR_GIB GiB floor) and never cleared, so the battery stood down rather than run jobs that would stall. Something large was resident all night - check what was holding RAM (see the 'lean preflight:' lines in the transcript for the measured numbers)."
            Write-AdmissionRecord 'skipped-memory'
            # The night claimed the slot at preflight, so it must release it even when it
            # never ran: the #784 probe's always-restore may have left an AO resident
            # during the retry window, and leaving it would starve tomorrow night the same
            # way it starved this one. Same guard and same non-fatal posture as Leg A.
            if ($AoOwnedByThisNight) {
                try {
                    $null = Stop-OwnedAo -SentinelPath $AoOwnerSentinel -BlarAiRepo $BlarRuntimeRoot `
                        -StopAssistantPath $StopAssistantPath -Context "skipped night $Stamp (never admitted)" -Log ${function:Write-Log}
                } catch {
                    Write-Log "ao-ownership: skip-path teardown errored ($($_.Exception.Message)) - non-fatal; the claim is kept for the next night's reclaim."
                }
            }
            Stop-Transcript | Out-Null; exit 0
        }
        Write-Log "lean preflight: retrying in 30 min."
        Start-Sleep -Seconds 1800
    }
    Write-Log "lean preflight: night admitted."
} else {
    # Manual/supervised runs have a human watching — measure + warn, never block, never probe.
    $h = Measure-SwapHeadroom
    Write-Log ("manual (-Now): available {0:N1} GiB, projected {1:N1} GiB (fast-path gate {2}); NOT blocking, NOT probing." -f $h.Avail, $h.Projected, $LEAN_GATE_GIB)
    $script:AdmissionPath = 'manual-now'
}

Ensure-AoHeadless

# Provenance BEFORE the run, not after: a night tree-killed mid-run (the PT10H
# ExecutionTimeLimit class) still leaves a night dir that says how it was admitted and
# who booted the AO. Writing it only at the end would lose exactly the nights whose
# provenance is most worth having.
Write-AdmissionRecord 'admitted'

# Fresh sandbox repos: archive last night's (rename — zero deletion), re-init.
$cards = Get-ChildItem "$BlarMeasuredRoot\evals\battery\B*.json"
$repoArchive = "$NightDir\repos-archived"
foreach ($j in $jobs) {
    $card = $cards | Where-Object { $_.BaseName -eq $j } | Select-Object -First 1
    if (-not $card) { throw "no battery card for job $j" }
    $repoName = (Get-Content $card.FullName -Raw | ConvertFrom-Json).repo
    if (-not $repoName.StartsWith("battery-")) { throw "card $j repo '$repoName' violates the battery- prefix rule" }
    $repoPath = Join-Path $ProjectsDir $repoName

    # ADMISSION: refuse to archive a sandbox a PRIOR DISPATCH STILL OWNS.
    # 2026-08-07, B9 runs 1 and 3: run 1's runner exited at 17:45 but its swap driver is
    # DETACHED ("Swap driver spawned; the launcher is exiting now") and kept building in
    # this repo until 18:39:53. Run 3 archived the directory out from under it at 18:13:47.
    # Both died: run 3 on the locked `public\` folder, and run 1's candidates on
    # `fatal: not a git repository: (NULL)` once their worktree's .git pointer was emptied.
    # MEMORY IS THE WRONG INSTRUMENT for this -- run 3's preflight read a clean 26.2 GiB
    # while that dispatch was live, because a swap driver mid-build is not a memory hog.
    # Ownership is on disk: a fleet run with RUN-START and no RUN-END still owns its repo.
    # LOCK 1 (#1334): the driving process. Checked FIRST and independently of the journal
    # scan below, because the journal scan cannot answer this:
    #   * TASK-START/TASK-END balance between waves (the 2026-08-07 23:01:15 collision);
    #   * RUN-START/RUN-END balance too -- they are emitted PER WAVE, so the run destroyed
    #     that night reads 6/6, and "just go run-level" would have admitted it identically;
    #   * a run whose journal.log does not exist yet is skipped entirely by the `continue`
    #     below -- measured 11 minutes wide on a real operator dispatch (dispatched
    #     10:45:36, journal first written 10:56:47), covering planning, asset generation
    #     and oracle seeding.
    # A process spans all of that by construction.
    $liveDispatch = Get-LiveDispatch
    if ($liveDispatch) {
        $named = if ($liveDispatch.RunId) { " (run $($liveDispatch.RunId))" } else { '' }
        # A CLEAN STAND-DOWN, NOT A BARE `throw`. This loop is TOP-LEVEL - no enclosing
        # try - so an uncaught throw here exits the script and jumps over three things the
        # file already learned it needs:
        #   * Write-SkipReport, so state\battery\MORNING-REPORT.md keeps LAST night's
        #     result and the operator's morning read silently shows a stale success (the
        #     consequence this file names at :496 and every other stand-down avoids);
        #   * Write-AdmissionRecord, so the night leaves no provenance;
        #   * the LEG A teardown below, so a scheduled night that already claimed and
        #     booted an AO leaves the 14B resident - the measured #1045 harm.
        # LOCK 2's throw below has the same shape and predates this change, but it is
        # REPO-scoped and rare; LOCK 1 is box-wide, which would have made a rare path the
        # routine one. Fixed here for LOCK 1; LOCK 2 is left alone deliberately so this
        # commit changes one thing, and it is ticketed.
        Write-Log ("archive guard: REFUSING - a dispatch is LIVE${named}: $($liveDispatch.Detail). " +
                   "Archiving $repoName would pull the directory out from under a running build.")
        # THE ESCAPE IS IN THE REPORT, not in someone's memory. If the process is actually a
        # dead orphan (they exist by design — swap drivers break away from the job object so
        # they survive a tree-kill), this stand-down repeats every night and banks nothing.
        # The one place a person is guaranteed to be looking when that happens is this
        # report, so the way out is printed here, with the pids to check first.
        $pidList = (@($liveDispatch.Pids) -join ', ')
        Write-SkipReport ("A coding dispatch was still running, so the battery stood down rather than " +
                          "archive the folder it was building in$named. Nothing was changed, moved or " +
                          "deleted. Details: $($liveDispatch.Detail). The next scheduled night runs " +
                          "normally once that dispatch has finished.`n`n" +
                          "IF THIS KEEPS HAPPENING, the process may be a leftover that never exited. " +
                          "Check whether process id(s) $pidList are really doing anything (Task Manager, " +
                          "or ask for a look). If they are dead, either stop them, or run the battery " +
                          "once telling it to ignore them:`n" +
                          "    Start-ScheduledTask -TaskPath '\BlarAI\' -TaskName 'BlarAI-M2-Battery-Nightly'   # normal`n" +
                          "    ...or, to override the check for ONE run, the battery must be started by hand with -IgnoreLiveDispatch.`n" +
                          "Only override after checking: the check exists because a night once destroyed a " +
                          "running build by assuming the box was idle.")
        $script:AdmissionPath = 'live-dispatch'
        Write-AdmissionRecord 'skipped-live-dispatch'
        if ($AoOwnedByThisNight) {
            # The probe/preflight may already have booted an AO under this night's claim.
            # Releasing it here is the whole point of not throwing.
            try {
                $null = Stop-OwnedAo -SentinelPath $AoOwnerSentinel -BlarAiRepo $BlarRuntimeRoot `
                    -StopAssistantPath $StopAssistantPath -Context "stood down for a live dispatch ($Stamp)" -Log ${function:Write-Log}
            } catch {
                Write-Log "ao-ownership: stand-down teardown errored ($($_.Exception.Message)) - non-fatal; the claim is kept for the next night's reclaim."
            }
        }
        Stop-Transcript | Out-Null; exit 0
    }

    # LOCK 2: the journal scan. KEPT rather than replaced -- it answers a question the
    # process check does not, namely which REPO a run owns, and it still catches the
    # original b7af0a0 case where a DETACHED swap driver outlives the runner that spawned
    # it. Weaker on its own (see above); independent of lock 1, which is the point.
    $liveOwner = $null
    $fleetRuns = Join-Path $AgenticRoot 'state\fleet-runs'
    if (Test-Path $fleetRuns) {
        foreach ($rd in (Get-ChildItem $fleetRuns -Directory -ErrorAction SilentlyContinue |
                         Sort-Object Name -Descending | Select-Object -First 12)) {
            $jl = Join-Path $rd.FullName 'journal.log'
            if (-not (Test-Path $jl)) { continue }
            $txt = Get-Content $jl -Raw -ErrorAction SilentlyContinue
            if (-not $txt) { continue }
            # Names THIS repo, has started a task, and has not finished it.
            if ($txt -match [regex]::Escape($repoPath)) {
                $starts = ([regex]::Matches($txt, 'TASK-START')).Count
                $ends   = ([regex]::Matches($txt, 'TASK-END')).Count
                if ($starts -gt $ends) {
                    # UNBALANCED IS NOT THE SAME AS LIVE (#1360, 2026-08-09).
                    # A run KILLED mid-task -- budget elapsed, tree-kill, doom stop --
                    # never writes its final TASK-END, so its journal stays unbalanced
                    # FOREVER and this lock blocks every later run on that repo until a
                    # human intervenes. Measured: run 20260809-154357-bd was killed at
                    # 10,901 s with 4 TASK-START / 3 TASK-END, and the next battery stood
                    # down 42 s after launch. It would have done so every night after.
                    #
                    # The swap driver's OWN account is the independent evidence. Restoring
                    # the 14B is its LAST act, written to swap-progress.log after the 30B
                    # is stopped. A run that got that far is over, whatever its journal
                    # balance says -- and reading the run's own terminal record keeps this
                    # lock independent of LOCK 1's process check, which is the point of
                    # having two.
                    $sp = Join-Path $rd.FullName 'swap-progress.log'
                    $spTxt = ''
                    if (Test-Path $sp) { $spTxt = Get-Content $sp -Raw -ErrorAction SilentlyContinue }
                    if ($spTxt -and ($spTxt -match '14B is back')) {
                        Write-Log ("archive guard: run $($rd.Name) has an unbalanced journal " +
                                   "($starts TASK-START / $ends TASK-END) but its swap-back " +
                                   "COMPLETED, so it is FINISHED, not live -- killed mid-task " +
                                   "and never wrote its last TASK-END. Not blocking.")
                        continue
                    }
                    $liveOwner = $rd.Name; break
                }
            }
        }
    }
    if ($liveOwner) {
        throw ("REFUSING to archive $repoName — fleet run $liveOwner still owns it " +
               "($repoPath): its journal has more TASK-START than TASK-END, so a prior " +
               "dispatch is still building there. Archiving now would corrupt both runs. " +
               "Let it finish, or reap it, then re-run.")
    }

    if (Test-Path $repoPath) {
        New-Item -ItemType Directory -Force $repoArchive | Out-Null
        # ATOMIC-OR-ABORT. An unguarded Move-Item that throws partway leaves the repo SPLIT
        # across two locations with an EMPTIED .git -- measured 2026-08-07: .git and
        # README.md moved, `public\` and `tests\` did not, and the remains were corrupt.
        # A half-moved sandbox is worse than an unarchived one, so put back what moved.
        $dest = Join-Path $repoArchive $repoName
        try {
            Move-Item $repoPath $dest -ErrorAction Stop
            Write-Log "archived previous $repoName."
        } catch {
            $partial = (Test-Path $dest) -and (Test-Path $repoPath)
            if ($partial) {
                try {
                    Get-ChildItem $dest -Force -ErrorAction Stop |
                        Move-Item -Destination $repoPath -Force -ErrorAction Stop
                    Remove-Item $dest -Force -Recurse -ErrorAction SilentlyContinue
                    Write-Log "archive of $repoName FAILED and was rolled back intact."
                } catch {
                    Write-Log ("archive of $repoName failed AND the rollback failed — the " +
                               "sandbox is split between $repoPath and $dest and must be " +
                               "repaired by hand before this card runs again.")
                }
            }
            throw ("could not archive $repoName ($($_.Exception.Message)). Something still " +
                   "holds a file under $repoPath — a live dispatch, an open handle, or a " +
                   "scanner. The sandbox was left as found rather than half-moved.")
        }
    }
    # A PARKED run leaves its worktree at state/worktrees/<repo>-<task> (the fleet-owned #714
    # hidden base). Those are NOT under $repoPath, so the archive above does not move them; and
    # the swap driver's own sweep both targets a stale pre-#714 path AND (by design) refuses to
    # remove parked/committed-unmerged worktrees. So on a re-run `git worktree add <existing
    # path>` FAILS ("could not create the isolated workspace") and the job parks INSTANTLY (found
    # live 2026-07-06 re-running B2). Battery sandboxes are THROWAWAY (the outcome lives in the
    # scorecard + run dir), so force-remove THIS job's stale worktrees before the fresh sandbox.
    $wtBase = Join-Path $AgenticRoot 'state\worktrees'
    if (Test-Path $wtBase) {
        Get-ChildItem $wtBase -Directory -Filter "$repoName-*" -ErrorAction SilentlyContinue |
            ForEach-Object {
                Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
                Write-Log "cleaned stale worktree $($_.Name) (throwaway; blocks the re-run otherwise)."
            }
    }
    New-Item -ItemType Directory -Force $repoPath | Out-Null
    Push-Location $repoPath
    git init -q
    Set-Content README.md "# $repoName (M2 battery sandbox — throwaway)"
    git add README.md; git commit -qm "init battery sandbox" | Out-Null
    Pop-Location
    Write-Log "fresh sandbox: $repoName"
}

# ---- 4. run the battery ------------------------------------------------------
Write-Log "launching the battery runner..."
$jobArg = $jobs -join ","
# `-m tools.dispatch_harness.battery` resolves from the CWD, so this Push-Location is what
# pins the measurement: the runner, the graders and the frozen cards all come from the
# measured tree. The interpreter is deliberately the RUNTIME venv -- battery.py imports
# nothing from the editable-installed `app` package, so the venv does not pin any code, and
# the measured worktree has no .venv of its own.
#
# --config names the RUNTIME tree's default.toml on purpose. It carries the port and the
# fleet roots, and the AO reads its OWN copy from the tree it booted in; letting the harness
# read the measured tree's copy instead would let the two disagree about which port to talk
# on. Config is the installation's, not the measurement's.
Push-Location $BlarMeasuredRoot
try {
    & $Python -m tools.dispatch_harness.battery --jobs $jobArg --out "$NightDir\scorecards" `
        --config "$BlarRuntimeRoot\services\assistant_orchestrator\config\default.toml" `
        *> "$NightDir\battery-runner.log"
    $runnerExit = $LASTEXITCODE
} finally { Pop-Location }
Write-Log "battery runner exit: $runnerExit"

# Belt: never leave the 30B resident.
if (Get-Process -Name ovms -ErrorAction SilentlyContinue) {
    Write-Log "WARNING: OVMS still resident post-run — the driver should have stopped it. Leaving for diagnosis (logged loud)."
}

# ---- 5. morning report + campaign accounting ---------------------------------
# #1045: the whole postlude runs inside a try so that a throw here CANNOT skip the
# end-of-night AO teardown at LEG A below. Ordering is unchanged and deliberate - the
# teardown still runs after the report, so a teardown problem cannot cost the night its
# scorecards. What changed is that the reverse is now also true: a postlude problem
# cannot cost the night its RAM. On 2026-07-22 a single terminating error here (an
# empty-array unroll, fixed above) skipped the teardown and left a 12.54 GB resident 14B
# for ~50 minutes - reopening the exact failure the #987 ownership model closed. A
# control a crash can jump over is not a control on the path that matters, so this
# containment is deliberately BROADER than the one bug: it catches the NEXT unknown
# throw too. Fail-loud, never silent, and $runnerExit is untouched - a completed night
# stays a completed night even if its report could not be written.
$__postludeError = $null
try {
# battery.py writes the AGGREGATE battery-summary.json into this same directory, so a bare
# *.json sweep picks it up as though it were a per-job scorecard (#1180). It has no job_id,
# and under the StrictMode Latest that ao-ownership-lib.ps1 puts in scope that read is a
# TERMINATING error -- which landed in the catch below and printed "unreadable scorecard"
# on EVERY night's report. Nothing was ever unreadable. Exclude it by name; the shape check
# in the loop is the backstop, not the primary defence.
$scorecards = Get-ChildItem "$NightDir\scorecards" -Filter "*.json" -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -ne 'battery-summary.json' }
$lines = @("# M2 battery — night $Stamp", "",
           "jobs requested: $($jobs -join ', ')  |  runner exit: $runnerExit", "")
$verdicts = @{}
# #789 measurement fairness: segment the GREEN-rate over plan-graph-ELIGIBLE jobs only.
# A flat-queue job (under-decomposed to <2 tasks) is structurally non-GREEN, so counting
# it in the denominator quietly depresses the coder rate. mode rides evidence.mode
# ("plan-graph"|"flat"), stamped by the driver's scorecard; absent = mode-unknown.
$green = 0; $planEligible = 0; $flatQueue = 0; $modeUnknown = 0
# #1181: read the tree stamp battery.py writes and say plainly what was measured. Null
# until a scorecard supplies it -- scorecards written before the stamp existed cannot tell
# us, and "cannot tell" must not render as "clean".
$measuredTree = $null; $measuredClean = $false
foreach ($sc in $scorecards) {
  # PER-SCORECARD CONTAINMENT. This outer try is load-bearing and must wrap the WHOLE body,
  # not just the parse. Under StrictMode Latest every member read below is a potential
  # TERMINATING error, and an escape from this loop lands in the postlude catch (:885) --
  # which means NO MORNING-REPORT.md and NO campaign banking for the night. One malformed
  # scorecard must cost its own line, never the whole night's evidence. A first cut of #1180
  # narrowed this guard to the parse alone; review caught that it turned a partial failure
  # total, on the unattended 23:00 path, in the #1019 shape.
  try {
    $d = $null
    try { $d = Get-Content $sc.FullName -Raw | ConvertFrom-Json }
    catch {
        # A file that is genuinely not parseable. This is the loud case and it must stay
        # distinguishable from "this is not a scorecard" -- #1180 collapsed the two, so the
        # only line that can announce lost evidence became the line nobody reads.
        $lines += "* !! UNREADABLE scorecard (not valid JSON): $($sc.Name) — evidence for this job is LOST"
        continue
    }
    # An empty or whitespace-only file parses to $null and does NOT throw, so the catch
    # above never fires -- the truncated/interrupted-write shape. Without this the next
    # member read terminates and takes the postlude with it.
    if ($null -eq $d) {
        $lines += "* !! UNREADABLE scorecard (empty or null): $($sc.Name) — evidence for this job is LOST"
        continue
    }
    # StrictMode Latest is in scope, so a missing member THROWS rather than yielding $null.
    # Test membership before reading, and report an unexpected shape as its own thing.
    if ($d.PSObject.Properties.Name -notcontains 'job_id') {
        $lines += "* skipped, not a per-job scorecard (no job_id): $($sc.Name)"
        continue
    }
    $verdicts[$d.job_id] = $d.verdict
    if ($d.verdict -eq "GREEN") { $green++ }
    # Every scorecard in a night SHOULD carry the same stamp -- but nothing enforces that,
    # and a checkout switched mid-run is exactly the confound this stamp exists to expose.
    # So detect disagreement rather than assert the invariant and keep the first value.
    if ($d.PSObject.Properties.Name -contains 'versions') {
        $v = $d.versions
        if ($v.PSObject.Properties.Name -contains 'blarai_branch') {
            # CONTAINMENT is the test; the branch name is provenance beside it. The name
            # was only ever standing in for "is this code merged", and it breaks on the
            # tree that matters most: a pinned measurement worktree is DETACHED by
            # construction (git refuses to check out main twice), so a name test brands
            # every correctly-pinned night as unmerged and prints a red banner on the
            # operator's morning read the night the pin first works, and every night after.
            # An alarm that fires on every normal night is an alarm already switched off.
            # Absent field = an older scorecard that cannot answer: unknown, never a pass.
            $thisOnMain = if ($v.PSObject.Properties.Name -contains 'blarai_on_main') { [string]$v.blarai_on_main } else { 'unknown' }
            $thisTree = "{0} @ {1} [{2}; on main: {3}]" -f $v.blarai_branch, $v.blarai, $v.blarai_tree, $thisOnMain
            if ($null -eq $measuredTree) {
                $measuredTree = $thisTree
                $measuredClean = ($thisOnMain -eq 'yes' -and $v.blarai_tree -eq 'clean')
            } elseif ($measuredTree -ne $thisTree -and $measuredTree -notmatch '^DISAGREEMENT') {
                $measuredTree = "DISAGREEMENT between jobs — '$measuredTree' vs '$thisTree' (a checkout moved mid-night; NO job in this night is condition-matched)"
                $measuredClean = $false
            }
        }
    }
    # MEMBERSHIP BEFORE READ (:1165's own rule, and the pattern `attribution` already uses
    # below). Under StrictMode Latest a bare $d.evidence.mode on a scorecard that carries no
    # `mode` is a TERMINATING error, so it escaped to the catch and rendered the whole card as
    # "evidence for this job is LOST" -- while the scorecard sat there complete, naming its own
    # cause. The `default` arm was written for exactly this case (:1133 "absent = mode-unknown")
    # and was UNREACHABLE by the only path that produces it. Measured 2026-08-07 on B9's first
    # ever run: a STALLED/HARNESS card with verdict, attribution, failure_class and a notes
    # field reading "approve did not fire EXECUTE: No response from the Assistant Orchestrator"
    # was reported to the operator as lost. The true cause was in the file the report said was
    # unreadable.
    $modeVal = $null
    if ($d.PSObject.Properties.Name -contains 'evidence' -and $null -ne $d.evidence -and
        $d.evidence.PSObject.Properties.Name -contains 'mode') {
        $modeVal = $d.evidence.mode
    }
    switch ($modeVal) {
        "plan-graph" { $planEligible++ }
        "flat"       { $flatQueue++ }
        default      { $modeUnknown++ }
    }
    $ga = if ($d.PSObject.Properties.Name -contains 'evidence' -and $null -ne $d.evidence -and
              $d.evidence.PSObject.Properties.Name -contains 'guest_agreement') {
        $d.evidence.guest_agreement
    } else { $null }
    $gaNote = if ($ga) { "; guest: $ga" } else { "" }
    # attribution is "" on every job until #740's window lands. Rendering the LABEL with
    # nothing after it taught the reader to skip a field that will one day carry meaning,
    # so omit the label entirely while it is empty rather than printing a bare heading.
    $attrNote = if ($d.PSObject.Properties.Name -contains 'attribution' -and $d.attribution) {
        "; attribution: $($d.attribution)"
    } else { "" }
    $lines += ("* **{0}**: {1} ({2}; {3:n0}s{4}{5})" -f
        $d.job_id, $d.verdict, $d.notes, $d.wall_clock_s, $attrNote, $gaNote)
    if ($ga -eq "DIVERGENCE") {
        $lines = @("## !! GUEST-ORACLE DIVERGENCE on $($d.job_id) — host and clean-room disagree !!", "") + $lines
    }
  } catch {
    # Any OTHER unexpected shape (a scorecard missing verdict/notes/evidence, a versions
    # block missing a key). Contained to this card: it costs one honest line and the rest
    # of the night still reports. Deliberately worded as lost evidence, not as noise.
    $lines += "* !! UNREADABLE scorecard (unexpected shape: $($_.Exception.Message)): $($sc.Name) — evidence for this job is LOST"
  }
}
# The honest denominator: GREEN over plan-graph-eligible, with the raw rate + the
# structurally-non-GREEN flat count both shown (nothing hidden; no verdict altered).
$relLine = ("reliability (#789 — honest denominator): GREEN {0}/{1} plan-graph-eligible (raw {0}/{2}); flat-queue={3} (structurally non-GREEN, under-decomposed)" -f `
    $green, $planEligible, $verdicts.Count, $flatQueue)
if ($modeUnknown -gt 0) { $relLine += ("; mode-unknown={0}" -f $modeUnknown) }
$lines += ""; $lines += $relLine
# #1181: name the conditions this night actually measured. A run against an unmerged branch
# or a tree carrying uncommitted work is not condition-matched to the night before it, which
# is the baseline the one-change-per-run attribution rule assumes. Silence here let a night
# be stamped with a feature-branch tip that reads like a release.
if ($measuredTree) {
    $lines += "measured tree (#1181): BlarAI $measuredTree"
    if (-not $measuredClean) {
        $lines = @("## !! MEASURED AN UNMERGED OR DIRTY TREE — not condition-matched to main: $measuredTree !!", "") + $lines
    }
} else {
    $lines += "measured tree (#1181): NOT RECORDED — the branch and cleanliness of the tree this night ran from are unknown (scorecards predate the stamp)."
}
# The OTHER tree. #1181 asks for the state of both, and only one of them is in the
# scorecards: this driver owns the job set, the admission gate, the budgets and the
# banking, so a night is not reproducible from the BlarAI commit alone. Deliberately not a
# banner -- a driver off main is worth seeing in the report, and the stand-downs upstream
# are what actually stop it, so this line informs rather than alarms.
if ($DriverStamp) {
    $lines += "driver tree (#1181): agentic-setup $DriverStamp"
} else {
    $lines += "driver tree (#1181): NOT RECORDED — the commit of the launcher that ran this night is unknown."
}
$falseDone = $verdicts.Values | Where-Object { $_ -eq "FALSE-DONE" }
if ($falseDone) { $lines = @("## !! FALSE-DONE DETECTED — RED ALERT !!", "") + $lines }
if ($TaskSettingsDrift) { $lines = @("## !! BATTERY TASK-SETTINGS DRIFT (#833) — $TaskSettingsDrift", "") + $lines }
if ($BudgetDrift) { $lines = @("## !! BATTERY BUDGET INCOHERENCE (#790) — $BudgetDrift", "") + $lines }
# @() is load-bearing: ao-ownership-lib.ps1 (dot-sourced at :59, #987) sets
# StrictMode Latest at caller scope, so on a COMPLETE night this pipeline yields
# $null and a bare .Count is a TERMINATING error — which killed the postlude
# (no banking, no morning report) on the first complete night after #987
# (night-20260720, runner exit 0 then TerminatingError).
$fullPass = @($jobs | Where-Object { -not $verdicts.ContainsKey($_) }).Count -eq 0
# #904 (LA-directed trim, 2026-07-15): the campaign config may FREEZE pass banking.
# The nightly set was cut to a lean diagnostic; a clean lean night must NOT bank a
# "pass" of the closed baseline 6-job campaign — that would silently change what a
# pass measures (#763's landing trigger counts BASELINE passes, frozen at their
# banked count). Absent/false flag = the legacy banking, byte-identical.
# NOTE: the flag must be a JSON BOOLEAN (true/false) — a quoted string "false"
# coerces truthy in PowerShell and would freeze (fails safe, but confusing).
# TWO-COUNTER BANKING (LA direction 2026-07-19: "two counters. one for the lean
# battery and one for the full battery"): a "pass" is a COMPLETENESS measure of the
# harness (every scheduled card produced a scorecard), so a complete 2-card night
# and a complete 6-card night are different events and must not share a counter.
# The runner classifies TONIGHT'S ACTUAL job set (post any late-start trim) against
# baseline_jobs: set-equal (order-insensitive) -> FULL pass (completed_passes, the
# frozen-at-3/5 historical meaning, unchanged); anything else -> LEAN pass
# (lean_passes, a bare diagnostic count with NO target — the lean battery is
# open-ended, and a lean target would recreate the completion-shaped machinery the
# #904 freeze existed to block). baseline_jobs ABSENT = a pre-#904 config with only
# one notion of a pass -> FULL (legacy, byte-identical). $nightClass is the single
# extension seam: the #973 day-keyed rotation adds a third class here (its own
# elseif + its own counter), never a rewrite. A frozen config still banks NOTHING.
$bankingFrozen = ($camp.PSObject.Properties.Name -contains 'pass_banking_frozen') -and [bool]$camp.pass_banking_frozen
if ($bankingFrozen) {
    $lines += ""; $lines += "campaign: pass banking FROZEN at $($camp.completed_passes)/$($camp.target_full_passes) (#904 trim closed the baseline set; a lean night is a diagnostic, never a pass)."
} elseif ($fullPass -and $runnerExit -eq 0) {
    # #1045: the @() wraps the WHOLE conditional, not the inner value. An empty array
    # returned from an `if` is UNROLLED on assignment, so `... else { @() }` yields $null,
    # and $null.Count is a TERMINATING error under the StrictMode ao-ownership-lib.ps1
    # leaks at :59. That is what crashed the 2026-07-22 B1 postlude - and only for a SIDE
    # config, since the default campaign always has baseline_jobs and never reaches the
    # else. Correct form already in-repo at fleet-lib.ps1:2450.
    $baselineJobs = @(if ($camp.PSObject.Properties.Name -contains 'baseline_jobs') { $camp.baseline_jobs } else { @() })
    $isBaselineNight = ($baselineJobs.Count -eq 0) -or (-not (Compare-Object @($jobs) $baselineJobs))
    $nightClass = if ($isBaselineNight) { 'FULL' } else { 'LEAN' }
    if ($nightClass -eq 'FULL') {
        $camp.completed_passes = [int]$camp.completed_passes + 1
        $fullReason = if ($baselineJobs.Count -eq 0) { "this config defines no baseline set, so every complete night is a full pass (legacy behavior)" }
                      else { "tonight's job set ($($jobs -join ', ')) matches the baseline set" }
        $lines += ""; $lines += "campaign: FULL pass $($camp.completed_passes)/$($camp.target_full_passes) BANKED — every scheduled card produced a scorecard, and $fullReason. The full counter measures complete nights of the original baseline campaign."
    } elseif ($nightClass -eq 'LEAN') {
        $leanPassesSoFar = if ($camp.PSObject.Properties.Name -contains 'lean_passes') { [int]$camp.lean_passes } else { 0 }
        $camp | Add-Member -NotePropertyName 'lean_passes' -NotePropertyValue ($leanPassesSoFar + 1) -Force
        $lines += ""; $lines += "campaign: LEAN pass $($camp.lean_passes) BANKED — tonight's job set ($($jobs -join ', ')) is not the baseline set ($($baselineJobs -join ', ')), so this counts on the lean diagnostic counter, not toward the full-campaign target ($($camp.completed_passes)/$($camp.target_full_passes)). The lean counter simply tallies complete diagnostic nights; it has no target."
    }
} else {
    $lines += ""; $lines += "campaign: NOT counted as a full pass (missing scorecards or nonzero exit)."
}
$camp | ConvertTo-Json -Depth 6 | Set-Content $CampaignConfig

# ---- #1327: the operator's validation exercise --------------------------------------
# Capabilities ship LIVE and are validated after, so the report owes him a runnable check
# rather than an approval request. Rendered by BlarAI (which owns what is live and what the
# capability's observable is); this launcher only appends what it is handed.
#
# FAIL-SOFT, and the asymmetry is deliberate. A failure here must never cost the night's
# results -- those are measurements and this is an addendum. But it must never fail SILENTLY
# either, because a missing section and a broken renderer are different facts and the whole
# feature rests on him being able to tell them apart. So: exit 2 (malformed exercise) and any
# other fault both append a loud line naming the cause, and the report is still written.
try {
    # Script from the MEASURED tree (so the exercise matches the code this night ran) but
    # interpreter from the RUNTIME installation -- the measured tree is a worktree and its
    # .venv is gitignored, exactly the split the AO-boot reachability line already reports.
    $renderer = Join-Path $BlarMeasuredRoot "scripts\render_morning_validation.py"
    if (-not (Test-Path $renderer)) {
        $renderer = Join-Path $BlarRuntimeRoot "scripts\render_morning_validation.py"
    }
    if (Test-Path $renderer) {
        $py = Join-Path $BlarRuntimeRoot ".venv\Scripts\python.exe"
        if (-not (Test-Path $py)) { $py = "python" }
        $prevEnc = [Console]::OutputEncoding
        [Console]::OutputEncoding = [System.Text.Encoding]::UTF8   # em-dashes survive the pipe
        $val = & $py $renderer 2>&1
        $rc = $LASTEXITCODE
        [Console]::OutputEncoding = $prevEnc
        if ($rc -eq 0 -and $val) {
            $lines += ""; $lines += ($val -join "`n")
        } elseif ($rc -ne 0) {
            $lines += ""
            $lines += "* !! the validation exercise could not be produced (renderer exit $rc): $($val -join ' ')"
            $lines += "  This is a fault in the checking machinery, not a quiet morning. Nothing was validated."
        }
    } else {
        $lines += ""; $lines += "* !! validation renderer not found at $renderer — no exercise was produced."
    }
} catch {
    $lines += ""
    $lines += "* !! the validation exercise could not be produced: $($_.Exception.Message)"
    $lines += "  This is a fault in the checking machinery, not a quiet morning. Nothing was validated."
}

$report = $lines -join "`n"
Set-Content "$NightDir\MORNING-REPORT.md" $report -Encoding UTF8
Set-Content "$AgenticRoot\state\battery\MORNING-REPORT.md" $report -Encoding UTF8
Write-Log "morning report written."

if ($camp.completed_passes -ge $camp.target_full_passes) {
    if ($IsDefaultCampaign) {
        Write-Log "campaign target reached — unregistering the scheduled task NOW."
        try { Unregister-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -Confirm:$false } catch {}
    } else {
        Write-Log "side campaign config reached its target — NOT touching the shared scheduled task (scoping fix, 2026-07-09)."
    }
}

} catch {
    # LOUD. The night's measurement (scorecards) is already on disk and is unaffected;
    # what is lost is the report and/or the banking, and that must never be silent.
    $__postludeError = $_
    Write-Log "!! POSTLUDE FAILED (#1045): $($_.Exception.Message)"
    Write-Log "!! line $($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())"
    Write-Log "!! scorecards are intact under $NightDir\scorecards - the morning report and/or campaign banking did NOT complete. Continuing to the AO teardown so the 14B is released."
}

# LEG A - end-of-night teardown (2026-07-20). The night releases the AO it claimed, so
# the resident 14B does not sit in RAM through the operator's whole morning. Runs AFTER
# the morning report so a teardown problem can never cost the night its scorecards or
# its report, and NON-FATALLY so it can never change $runnerExit - a completed night
# stays a completed night. A failed stop deliberately KEEPS the sentinel, so the next
# night's Leg B retries the reclaim.
if ($AoOwnedByThisNight) {
    # #1334: RE-CHECK LIVENESS HERE TOO. The guard at the top of the night and the preflight
    # reclaim both protect the START of the night; this teardown fires HOURS later and used
    # to stop whatever holds :5001 unconditionally. A dispatch that began at 01:00 - after
    # the guard cleared - would lose its assistant at end-of-night: the 2026-08-07
    # destruction, moved later in the same night. The guard's own log line asserted the
    # night "will not reclaim the assistant while it runs", which was true of the preflight
    # and false of this. An assertion the code does not honour is the defect this whole
    # ticket is about, so it is honoured here rather than reworded.
    #
    # Leaving the AO up is the RIGHT outcome when a dispatch is live - it needs it - and it
    # is self-healing: the claim is kept, and the next night's Leg B reclaim collects it
    # once the box is genuinely idle. The #1045 leak this teardown exists to prevent is
    # bounded by that, not reopened.
    $liveAtTeardown = Get-LiveDispatch
    if ($liveAtTeardown) {
        $tdNamed = if ($liveAtTeardown.RunId) { " (run $($liveAtTeardown.RunId))" } else { '' }
        Write-Log ("ao-ownership: end-of-night teardown SKIPPED - a dispatch is LIVE$tdNamed " +
                   "($($liveAtTeardown.Detail)). Leaving the assistant up; the claim is kept and " +
                   "the next night's preflight reclaim collects it once the box is idle.")
    } else {
        try {
            $null = Stop-OwnedAo -SentinelPath $AoOwnerSentinel -BlarAiRepo $BlarRuntimeRoot `
                -StopAssistantPath $StopAssistantPath -Context "end-of-night (night $Stamp)" -Log ${function:Write-Log}
        } catch {
            Write-Log "ao-ownership: end-of-night teardown errored ($($_.Exception.Message)) - non-fatal; the claim is kept for the next night's reclaim."
        }
    }
} else {
    Write-Log "ao-ownership: this run claimed no AO (manual -Now run) - leaving the assistant running."
}
Stop-Transcript | Out-Null
exit $runnerExit
