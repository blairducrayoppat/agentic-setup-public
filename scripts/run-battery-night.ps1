# run-battery-night.ps1 — the M2 nightly battery launcher (#740 W8/§9.5 campaign).
#
# Fires from Task Scheduler (\BlarAI\BlarAI-M2-Battery-Nightly, daily 23:00) or by
# hand. Behavior, in order:
#   1. CAMPAIGN CHECK  — reads state/battery-campaign.json; if the campaign is
#      complete (target passes reached) it UNREGISTERS its own scheduled task and
#      exits (Task Scheduler hygiene — the LA's explicit requirement).
#   2. OPERATOR GUARD  — the box owner may be on the device until ~00:30: if there
#      has been keyboard/mouse input in the last 15 min, or a BlarAI app window is
#      up, or the coder port is busy, WAIT 30 min and re-check (until the cutoff).
#      Never seize the GPU from a human.
#   3. PREFLIGHT       — AO headless up on :5001 (boot if absent), :8000 free,
#      stale cancel file cleared, fresh sandbox repos for the night's jobs (the
#      previous night's repos are ARCHIVED by rename, never deleted).
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
    [switch]$Now  # skip the operator guard (manual daytime invocation)
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

# ---- 2. operator guard ------------------------------------------------------
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class IdleTime {
    [StructLayout(LayoutKind.Sequential)] struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
    [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);
    public static uint MinutesIdle() {
        var lii = new LASTINPUTINFO(); lii.cbSize = (uint)Marshal.SizeOf(typeof(LASTINPUTINFO));
        GetLastInputInfo(ref lii);
        return ((uint)Environment.TickCount - lii.dwTime) / 60000u;
    }
}
'@
function Test-OperatorActive {
    $idle = [IdleTime]::MinutesIdle()
    $app  = Get-Process -Name "BlarAI*" -ErrorAction SilentlyContinue |
            Where-Object { $_.MainWindowHandle -ne 0 }
    $coderBusy = Test-NetConnection -ComputerName 127.0.0.1 -Port 8000 -InformationLevel Quiet -WarningAction SilentlyContinue
    if ($idle -lt 15)  { Write-Log "guard: input $idle min ago — operator active."; return $true }
    if ($app)          { Write-Log "guard: a BlarAI app window is open — operator active."; return $true }
    if ($coderBusy)    { Write-Log "guard: :8000 busy (a dispatch is running) — waiting."; return $true }
    return $false
}
if (-not $Now) {
    $cutoff = (Get-Date).Date.AddDays(1).AddHours(4)   # stop retrying at 04:00
    while (Test-OperatorActive) {
        if ((Get-Date) -gt $cutoff) {
            Write-Log "Guard never cleared by 04:00 — skipping tonight (not counted as a pass)."
            Stop-Transcript | Out-Null; exit 0
        }
        Write-Log "guard: retrying in 30 min."
        Start-Sleep -Seconds 1800
    }
    Write-Log "guard clear — box is idle."
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

# LEAN PREFLIGHT (#740 c.1504, built 2026-07-09): the 30B swap gate needs 21 GiB of system
# RAM free AFTER the 14B unloads (swap_ops gate_gb=21.0; the 14B returns ~8.7 GiB — projected
# conservatively at 8.0 here). Nights 2026-07-08 attempt 1+2 burned SIX stalls on this exact
# gap (20.7 / 20.6 GiB measured at swap time — the operator's browser held the missing
# margin) and cost ~2.5 h of darkness. So: PROJECT the post-unload headroom BEFORE
# dispatching. Short + operator idle -> lean the known-safe restartable apps (firefox,
# OneDrive — the LA's standing process authority, granted live 2026-07-09 01:55 and codified
# in settings the same day) and re-measure; still short (or operator active) -> rejoin the
# 30-min guard loop rather than burning a pass on a known number. GiB is BINARY (/1024),
# matching swap_ops.real_available_gb — the F1 decimal-GB trap.
function Get-ProjectedSwapHeadroomGiB {
    param([bool]$AoUp)
    $availGiB = (Get-Counter '\Memory\Available MBytes' -ErrorAction Stop).CounterSamples[0].CookedValue / 1024
    # With the 14B resident its ~8 GiB comes back at unload; with the AO down it is already free.
    if ($AoUp) { return @{ Avail = $availGiB; Projected = $availGiB + 8.0 } }
    return @{ Avail = $availGiB; Projected = $availGiB }
}
$LEAN_GATE_GIB   = 20.5   # swap gate 20.0 (#777, 2026-07-09) + 0.5 margin
$LEAN_SAFE_PROCS = @('firefox', 'OneDrive')
function Test-SwapHeadroom {
    $aoNow = Test-NetConnection -ComputerName 127.0.0.1 -Port 5001 -InformationLevel Quiet -WarningAction SilentlyContinue
    $h = Get-ProjectedSwapHeadroomGiB -AoUp $aoNow
    Write-Log ("lean preflight: available {0:N1} GiB, projected post-unload {1:N1} GiB (gate {2} GiB)" -f $h.Avail, $h.Projected, $LEAN_GATE_GIB)
    if ($h.Projected -ge $LEAN_GATE_GIB) { return $true }
    if ([IdleTime]::MinutesIdle() -ge 15) {
        foreach ($p in $LEAN_SAFE_PROCS) {
            $procs = Get-Process -Name $p -ErrorAction SilentlyContinue
            if ($procs) {
                Write-Log "lean preflight: headroom short — stopping $p ($(($procs | Measure-Object WorkingSet64 -Sum).Sum / 1GB | ForEach-Object { '{0:N1}' -f $_ }) GB resident, restartable)."
                $procs | Stop-Process -Force -ErrorAction SilentlyContinue
            }
        }
        Start-Sleep -Seconds 20   # let the working sets actually return
        $h2 = Get-ProjectedSwapHeadroomGiB -AoUp $aoNow
        Write-Log ("lean preflight: post-lean available {0:N1} GiB, projected {1:N1} GiB" -f $h2.Avail, $h2.Projected)
        return ($h2.Projected -ge $LEAN_GATE_GIB)
    }
    Write-Log "lean preflight: headroom short but operator recently active — will not lean; waiting."
    return $false
}
if (-not $Now) {
    $cutoffLean = (Get-Date).Date.AddDays(1).AddHours(4)
    while (-not (Test-SwapHeadroom)) {
        if ((Get-Date) -gt $cutoffLean) {
            Write-Log "lean preflight: headroom never cleared by 04:00 — skipping tonight (not counted as a pass; NOT a burned attempt)."
            Stop-Transcript | Out-Null; exit 0
        }
        Write-Log "lean preflight: retrying in 30 min."
        Start-Sleep -Seconds 1800
    }
    Write-Log "lean preflight: headroom OK."
} else {
    # Manual/supervised runs have a human watching — measure + warn, never block.
    $null = Test-SwapHeadroom
}

# AO headless on :5001 (production env — no debug vars). Boot via the SAME tested detached
# path the battery runner uses (tools.dispatch_harness.battery.boot_launcher_detached): a plain
# `Start-Process -WindowStyle Hidden` hands the launcher a hidden CONSOLE, which drives Textual
# into "Driver must be in application mode" and crashes the boot in an interactive/`-Now` run;
# DETACHED_PROCESS (no console) makes it fall back to the headless driver (found live 2026-07-06).
# The wait is NON-FATAL: the runner's per-job AoReensurer re-boots (and now heals cert-drift —
# a socket that is up but whose mTLS leaf no longer verifies) as the backstop, so a slow or
# failed preflight boot must NOT abort the whole night.
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
foreach ($sc in $scorecards) {
    try {
        $d = Get-Content $sc.FullName -Raw | ConvertFrom-Json
        if ($d.job_id) {
            $verdicts[$d.job_id] = $d.verdict
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
$falseDone = $verdicts.Values | Where-Object { $_ -eq "FALSE-DONE" }
if ($falseDone) { $lines = @("## !! FALSE-DONE DETECTED — RED ALERT !!", "") + $lines }
$fullPass = ($jobs | Where-Object { -not $verdicts.ContainsKey($_) }).Count -eq 0
if ($fullPass -and $runnerExit -eq 0) {
    $camp.completed_passes = [int]$camp.completed_passes + 1
    $lines += ""; $lines += "campaign: pass $($camp.completed_passes)/$($camp.target_full_passes) BANKED."
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
