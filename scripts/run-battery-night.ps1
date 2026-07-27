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
    [string]$CampaignConfig = "$PSScriptRoot\..\state\battery-campaign.json",
    [switch]$Now  # skip the dispatch guard + lean wait-loop (manual daytime invocation)
)

$ErrorActionPreference = "Stop"
$AgenticRoot = Resolve-Path "$PSScriptRoot\.."
$BlarRoot    = "C:\Users\mrbla\blarai"
$Python      = "$BlarRoot\.venv\Scripts\python.exe"
$ProjectsDir = "C:\Users\mrbla\projects"
$TaskPath    = "\BlarAI\"
$TaskName    = "BlarAI-M2-Battery-Nightly"
# Self-unregister is scoped to the DEFAULT campaign config ONLY (2026-07-09
# incident): a SUPERVISED one-shot run (`-CampaignConfig <side-file>`, e.g. the
# B8/B7 hygiene verify) hit its own 1/1 target and the post-run check silently
# unregistered the REAL nightly task — the 23:00 campaign would simply not have
# fired, discovered only by the LA's pre-battery checklist question. A side
# config completing must never touch the shared task.
$DefaultCampaignConfig = (Resolve-Path "$PSScriptRoot\..\state\battery-campaign.json" -ErrorAction SilentlyContinue).Path
$IsDefaultCampaign = $DefaultCampaignConfig -and ((Resolve-Path $CampaignConfig -ErrorAction SilentlyContinue).Path -eq $DefaultCampaignConfig)
$Stamp       = Get-Date -Format "yyyyMMdd-HHmmss"
$NightDir    = "$AgenticRoot\state\battery\night-$Stamp"
New-Item -ItemType Directory -Force $NightDir | Out-Null
Start-Transcript -Path "$NightDir\launcher.log" -Force | Out-Null

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
if (-not (Test-Path $CampaignConfig)) { throw "campaign config missing: $CampaignConfig" }
$camp = Get-Content $CampaignConfig -Raw | ConvertFrom-Json

# ---- 1a. hard end date (LA direction 2026-07-14) -----------------------------
# The campaign must not run indefinitely chasing a pass target that may never
# bank — LA set a calendar backstop independent of completed_passes ("extra
# passes are fine, running forever is not"). Optional field: absent/blank
# end_date = no calendar cutoff (a side/manual config just omits it). Scoped to
# $IsDefaultCampaign like the pass-count check below (2026-07-09 scoping fix) —
# a side config's cutoff must never touch the shared nightly task.
if ($camp.end_date) {
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

# ---- 2. dispatch guard --------------------------------------------------------
# Presence checks (LASTINPUTINFO idle + BlarAI app window) removed 2026-07-09 by
# LA direction: the battery launches at 23:00 regardless of operator presence.
# Only a dispatch already holding :8000 defers the launch (collision, not presence).
function Test-DispatchBusy {
    $coderBusy = Test-NetConnection -ComputerName 127.0.0.1 -Port 8000 -InformationLevel Quiet -WarningAction SilentlyContinue
    if ($coderBusy) { Write-Log "guard: :8000 busy (a dispatch is running) — waiting."; return $true }
    return $false
}
if (-not $Now) {
    $cutoff = (Get-Date).Date.AddDays(1).AddHours(4)   # stop retrying at 04:00
    while (Test-DispatchBusy) {
        if ((Get-Date) -gt $cutoff) {
            Write-Log "Guard never cleared by 04:00 — skipping tonight (not counted as a pass)."
            Write-SkipReport "A coding dispatch held the coder port (:8000) continuously from 23:00 to 04:00, so the battery never had the box to itself. It waited on 30-minute retries and then stood down rather than clobber a run in flight."
            $script:AdmissionPath = 'dispatch-busy'
            Write-AdmissionRecord 'skipped-dispatch-busy'
            Stop-Transcript | Out-Null; exit 0
        }
        Write-Log "guard: retrying in 30 min."
        Start-Sleep -Seconds 1800
    }
    Write-Log "guard clear — no dispatch in flight."
}

# ---- job set for the night --------------------------------------------------
$jobs = @($camp.jobs)
$excluded = @($camp.excluded | ForEach-Object { "$($_.id) ($($_.reason))" })
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
# Available + 8.0 ~= 14 GiB < 20.5) AND the probe floor (raw Available ~= 6 GiB < 15.0).
# See ao-ownership-lib.ps1's Invoke-AoPreflightReclaim for why this is safe.
# Scoped to the scheduled night: under -Now a human is at the keyboard and owns the
# box (the standing -Now posture - verify-battery-probe-admission.ps1 S5).
if (-not $Now) {
    try {
        # The launcher observes the slot; the library decides whether to stop. Keeping the
        # detection here means ao-ownership-lib.ps1 never grows a second process detector.
        $aoHeld = [bool](Test-NetConnection -ComputerName 127.0.0.1 -Port 5001 -InformationLevel Quiet -WarningAction SilentlyContinue)
        $reclaim = Invoke-AoPreflightReclaim -SentinelPath $AoOwnerSentinel -CurrentNight $Stamp `
            -AoPresent $aoHeld -BlarAiRepo $BlarRoot -StopAssistantPath $StopAssistantPath -Log ${function:Write-Log}
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
            & pwsh -NoProfile -ExecutionPolicy Bypass -File $verifyTaskSettings -BlarRepo $BlarRoot *>&1 |
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
            & pwsh -NoProfile -ExecutionPolicy Bypass -File $verifyBudget -BlarRepo $BlarRoot *>&1 |
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
# only gate). The 30B swap needs ~20 GiB of system RAM free AFTER the 14B unloads (swap_driver
# gate_gb=20.0, #777 measured 2026-07-09; the 14B returns ~8.7 GiB, projected conservatively at
# 8.0 here). Two-stage admission:
#
#   FAST PATH (unchanged) — PROJECT post-unload headroom; if it clears $LEAN_GATE_GIB (20.5 =
#     gate 20.0 + margin) proceed immediately. Short -> lean the known-safe restartable apps
#     (firefox, OneDrive — the LA's standing process authority, codified in settings 2026-07-09;
#     firefox restores its session, OneDrive re-syncs) and re-project.
#
#   PROBE (new, #784) — the arithmetic gate has a DEAD BAND: #777 proved a CLEAN load from
#     19.85 GiB, yet the projection gate (20.5) would wait all night on it (nights 2026-07-08
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
$LEAN_GATE_GIB   = 20.5   # fast-path projection gate: swap gate 20.0 (#777, 2026-07-09) + 0.5 margin
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
        Push-Location $BlarRoot
        try {
            # Route the boot command's own output through Write-Log rather than letting it
            # fall to the success stream. Ensure-AoHeadless is called FROM INSIDE
            # Test-NightAdmission (the post-probe re-verify), so a bare native call here
            # would land its stdout in that function's return value -- the same
            # array-instead-of-bool shape that killed the admission gate. Nothing is lost:
            # the boot's real log is the file passed as its second argument.
            & $Python -c $bootPy $BlarRoot "$NightDir\ao-boot.log" 2>&1 |
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
        if (Test-NetConnection 127.0.0.1 -Port 5001 -InformationLevel Quiet -WarningAction SilentlyContinue) { Write-Log "AO up." }
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
    Push-Location $BlarRoot   # `-m tools.dispatch_harness.probe` resolves from the repo root
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
                    $null = Stop-OwnedAo -SentinelPath $AoOwnerSentinel -BlarAiRepo $BlarRoot `
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
$cards = Get-ChildItem "$BlarRoot\evals\battery\B*.json"
$repoArchive = "$NightDir\repos-archived"
foreach ($j in $jobs) {
    $card = $cards | Where-Object { $_.BaseName -eq $j } | Select-Object -First 1
    if (-not $card) { throw "no battery card for job $j" }
    $repoName = (Get-Content $card.FullName -Raw | ConvertFrom-Json).repo
    if (-not $repoName.StartsWith("battery-")) { throw "card $j repo '$repoName' violates the battery- prefix rule" }
    $repoPath = Join-Path $ProjectsDir $repoName
    if (Test-Path $repoPath) {
        New-Item -ItemType Directory -Force $repoArchive | Out-Null
        Move-Item $repoPath (Join-Path $repoArchive $repoName)
        Write-Log "archived previous $repoName."
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
Push-Location $BlarRoot   # `-m tools.dispatch_harness.battery` resolves from the repo root
try {
    & $Python -m tools.dispatch_harness.battery --jobs $jobArg --out "$NightDir\scorecards" `
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
$scorecards = Get-ChildItem "$NightDir\scorecards" -Filter "*.json" -ErrorAction SilentlyContinue
$lines = @("# M2 battery — night $Stamp", "",
           "jobs requested: $($jobs -join ', ')  |  runner exit: $runnerExit", "")
$verdicts = @{}
# #789 measurement fairness: segment the GREEN-rate over plan-graph-ELIGIBLE jobs only.
# A flat-queue job (under-decomposed to <2 tasks) is structurally non-GREEN, so counting
# it in the denominator quietly depresses the coder rate. mode rides evidence.mode
# ("plan-graph"|"flat"), stamped by the driver's scorecard; absent = mode-unknown.
$green = 0; $planEligible = 0; $flatQueue = 0; $modeUnknown = 0
foreach ($sc in $scorecards) {
    try {
        $d = Get-Content $sc.FullName -Raw | ConvertFrom-Json
        if ($d.job_id) {
            $verdicts[$d.job_id] = $d.verdict
            if ($d.verdict -eq "GREEN") { $green++ }
            switch ($d.evidence.mode) {
                "plan-graph" { $planEligible++ }
                "flat"       { $flatQueue++ }
                default      { $modeUnknown++ }
            }
            $ga = $d.evidence.guest_agreement
            $gaNote = if ($ga) { "; guest: $ga" } else { "" }
            $lines += ("* **{0}**: {1} ({2}; {3:n0}s; attribution: {4}{5})" -f
                $d.job_id, $d.verdict, $d.notes, $d.wall_clock_s, $d.attribution, $gaNote)
            if ($ga -eq "DIVERGENCE") {
                $lines = @("## !! GUEST-ORACLE DIVERGENCE on $($d.job_id) — host and clean-room disagree !!", "") + $lines
            }
        }
    } catch { $lines += "* unreadable scorecard: $($sc.Name)" }
}
# The honest denominator: GREEN over plan-graph-eligible, with the raw rate + the
# structurally-non-GREEN flat count both shown (nothing hidden; no verdict altered).
$relLine = ("reliability (#789 — honest denominator): GREEN {0}/{1} plan-graph-eligible (raw {0}/{2}); flat-queue={3} (structurally non-GREEN, under-decomposed)" -f `
    $green, $planEligible, $verdicts.Count, $flatQueue)
if ($modeUnknown -gt 0) { $relLine += ("; mode-unknown={0}" -f $modeUnknown) }
$lines += ""; $lines += $relLine
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
$report = $lines -join "`n"
Set-Content "$NightDir\MORNING-REPORT.md" $report
Set-Content "$AgenticRoot\state\battery\MORNING-REPORT.md" $report
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
    try {
        $null = Stop-OwnedAo -SentinelPath $AoOwnerSentinel -BlarAiRepo $BlarRoot `
            -StopAssistantPath $StopAssistantPath -Context "end-of-night (night $Stamp)" -Log ${function:Write-Log}
    } catch {
        Write-Log "ao-ownership: end-of-night teardown errored ($($_.Exception.Message)) - non-fatal; the claim is kept for the next night's reclaim."
    }
} else {
    Write-Log "ao-ownership: this run claimed no AO (manual -Now run) - leaving the assistant running."
}
Stop-Transcript | Out-Null
exit $runnerExit
