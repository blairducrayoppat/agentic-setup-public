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

function Write-Log([string]$msg) { Write-Output "[$(Get-Date -Format HH:mm:ss)] $msg" }

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
$LEAN_SAFE_PROCS = @('firefox', 'OneDrive')

# Measure the post-unload headroom, leaning the restartable apps if the first projection is
# short; returns @{ Avail; Projected } POST-lean. No probe, no block — the admission/-Now
# callers decide what to do with the number.
function Measure-SwapHeadroom {
    $aoNow = Test-NetConnection -ComputerName 127.0.0.1 -Port 5001 -InformationLevel Quiet -WarningAction SilentlyContinue
    $h = Get-ProjectedSwapHeadroomGiB -AoUp $aoNow
    Write-Log ("lean preflight: available {0:N1} GiB, projected post-unload {1:N1} GiB (fast-path gate {2} GiB)" -f $h.Avail, $h.Projected, $LEAN_GATE_GIB)
    if ($h.Projected -ge $LEAN_GATE_GIB) { return $h }
    foreach ($p in $LEAN_SAFE_PROCS) {
        $procs = Get-Process -Name $p -ErrorAction SilentlyContinue
        if ($procs) {
            Write-Log "lean preflight: headroom short — stopping $p ($(($procs | Measure-Object WorkingSet64 -Sum).Sum / 1GB | ForEach-Object { '{0:N1}' -f $_ }) GB resident, restartable)."
            $procs | Stop-Process -Force -ErrorAction SilentlyContinue
        }
    }
    Start-Sleep -Seconds 20   # let the working sets actually return
    $aoNow2 = Test-NetConnection -ComputerName 127.0.0.1 -Port 5001 -InformationLevel Quiet -WarningAction SilentlyContinue
    $h2 = Get-ProjectedSwapHeadroomGiB -AoUp $aoNow2
    Write-Log ("lean preflight: post-lean available {0:N1} GiB, projected {1:N1} GiB" -f $h2.Avail, $h2.Projected)
    return $h2
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
    $aoUp = Test-NetConnection -ComputerName 127.0.0.1 -Port 5001 -InformationLevel Quiet -WarningAction SilentlyContinue
    if (-not $aoUp) {
        Write-Log "booting the AO headless (detached)..."
        $bootPy = 'import sys; from pathlib import Path; from tools.dispatch_harness.battery import boot_launcher_detached; boot_launcher_detached(Path(sys.argv[1]), Path(sys.argv[2]))'
        Push-Location $BlarRoot
        try {
            & $Python -c $bootPy $BlarRoot "$NightDir\ao-boot.log"
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
    } else { Write-Log "AO already up on :5001 — the runner's per-job AoReensurer verifies its mTLS health before each job and re-boots on cert-drift." }
}

# ONE admission decision: $true to ADMIT (run tonight), $false to RETRY (rejoin the wait loop).
# Fast path first; then the #784 probe in the marginal band. Only ever called under NON-$Now.
function Test-NightAdmission {
    $h = Measure-SwapHeadroom
    if ($h.Projected -ge $LEAN_GATE_GIB) {
        Write-Log ("lean preflight: fast path — projected {0:N1} GiB clears the {1} GiB gate." -f $h.Projected, $LEAN_GATE_GIB)
        return $true
    }
    if ($h.Avail -lt $PROBE_FLOOR_GIB) {
        Write-Log ("lean preflight: available {0:N1} GiB below the probe floor {1} GiB — too starved to probe; retrying." -f $h.Avail, $PROBE_FLOOR_GIB)
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
    if ($probeExit -eq 0) {
        Write-Log "probe: the 30B loaded outside any job (exit 0) — ADMITTING the night."
        Ensure-AoHeadless   # the probe restored the AO; re-verify + re-boot if needed (non-fatal)
        return $true
    }
    Write-Log "probe: did NOT admit (exit $probeExit) — rejoining the 30-min retry loop."
    return $false
}

if (-not $Now) {
    $cutoffLean = (Get-Date).Date.AddDays(1).AddHours(4)
    while (-not (Test-NightAdmission)) {
        if ((Get-Date) -gt $cutoffLean) {
            Write-Log "lean preflight: never admitted by 04:00 — skipping tonight (not counted as a pass; NOT a burned attempt)."
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
}

Ensure-AoHeadless

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
$fullPass = ($jobs | Where-Object { -not $verdicts.ContainsKey($_) }).Count -eq 0
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
    $baselineJobs = if ($camp.PSObject.Properties.Name -contains 'baseline_jobs') { @($camp.baseline_jobs) } else { @() }
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
Stop-Transcript | Out-Null
exit $runnerExit
