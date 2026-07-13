# stop-assistant.ps1 - Stop BlarAI's resident assistant (the AO/launcher) so its
# ~12.6 GB 14B frees. This is a DIFFERENT RAM consumer from the OVMS model server
# that stop-llm.ps1 handles (#797).
#
# TWO SEPARATE MODEL-RAM CONSUMERS
# ================================
#   * stop-llm.ps1     -> the OVMS model server on :8000 (the coder/vision/everyday
#                         SWAP models the coding fleet loads). Files are read-only;
#                         a hard stop is safe.
#   * stop-assistant   -> the ASSISTANT: `pythonw -m launcher` (the AO), which holds
#                         the resident 14B in-process via OpenVINO GenAI and serves
#                         the chat backend on :5001. OVMS never holds this 14B, so
#                         stop-llm.ps1 can NEVER free it. This script does.
#
# The operator hit this live 2026-07-10: menu 5 ("clear RAM") stopped OVMS but left
# the assistant's 14B resident, so ~11 GiB stayed pinned and the URL-ingest go-live
# launcher could not start.
#
# HOW IT FINDS + CONFIRMS THE TARGET (never a blind pid kill)
# ===========================================================
# The launcher records its own pid in a single-instance lock at
# <blarai>/certs/launcher.lock (launcher/instance_lock.py). We read that pid and
# CONFIRM it is genuinely a live `-m launcher` process (its cmdline carries the
# marker) BEFORE touching it. After a crash the OS can recycle a dead launcher's pid
# to an unrelated process; a pid-only kill would then kill a stranger. If the pid is
# absent / dead / not-a-launcher we report "not running" and touch nothing - this is
# the exact confirmation `tools/dispatch_harness/probe.py:_real_stop_ao` performs.
#
# HOW IT STOPS THE TARGET (the audited seam, not a hand-rolled taskkill)
# ======================================================================
# The kill is delegated to Stop-ProcessTree in spawn-lib.ps1 - the blessed
# process-tree teardown (R5 / #630, lesson 219): a bare Stop-Process orphans the
# launcher's grandchildren (they hold :5001 / bleed RAM). Skipping the launcher's
# graceful cleanup leaves a stale lock, exactly like the swap driver's os._exit
# step-aside; the next boot reclaims it.
#
# Source is ASCII-only (spawn-lib convention): no em-dash / section-sign literals.
param(
    # BlarAI repo root that owns the launcher lock. Mirrors new-agent-task.ps1's
    # resolution so the panel and standalone use point at the same checkout.
    [string]$BlarAiRepo = $(if ($env:BLARAI_REPO) { $env:BLARAI_REPO } else { 'C:\Users\mrbla\blarai' })
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'spawn-lib.ps1')   # Stop-ProcessTree (the audited kill seam)

# A BlarAI launcher always runs as `python -m launcher` (the swap relaunch argv too),
# so a real holder's cmdline carries this marker. Mirrors instance_lock.py's
# _LAUNCHER_CMDLINE_MARKER. A bare pid-exists check is NOT enough (recycled pids).
$script:LauncherCmdlineMarker = '-m launcher'

function Get-LauncherLockPid {
    # Read the launcher's recorded pid from its single-instance lock. Mirrors
    # instance_lock._read_holder_pid: missing / unreadable / corrupt -> 0 (no holder).
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$LockPath)
    if (-not (Test-Path $LockPath)) { return 0 }
    try { $text = (Get-Content -Path $LockPath -Raw -ErrorAction Stop).Trim() }
    catch { return 0 }
    $parsed = 0
    if ([int]::TryParse($text, [ref]$parsed)) { return $parsed }
    return 0   # corrupt lock -> treat as no holder (nothing safe to stop)
}

function Test-IsLiveLauncher {
    # True ONLY if $ProcessId is a LIVE BlarAI launcher (alive AND its cmdline runs
    # `-m launcher`). Mirrors instance_lock._is_live_launcher: a dead pid, a recycled
    # pid now owned by something else, or an unreadable cmdline is NOT our launcher,
    # so the caller refuses to kill it. This is the "never kill by pid/name alone"
    # guard the whole fix turns on.
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$ProcessId)
    if ($ProcessId -le 0) { return $false }
    if (-not (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)) { return $false }  # dead pid
    try { $cmd = (Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction Stop).CommandLine }
    catch { return $false }   # unreadable -> provably not ours (a real launcher runs as us)
    if (-not $cmd) { return $false }
    return ([string]$cmd).Contains($script:LauncherCmdlineMarker)
}

function Get-AvailableGb {
    try { return [math]::Round((Get-Counter '\Memory\Available MBytes').CounterSamples[0].CookedValue / 1024, 1) }
    catch { return $null }
}

function Stop-Assistant {
    # Orchestrate: read the lock pid, CONFIRM it is a live launcher, then tree-kill via
    # the audited seam. Every not-running path reports and returns 0 (never errors).
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$BlarAiRepo)

    $lock = Join-Path $BlarAiRepo 'certs\launcher.lock'
    $targetPid = Get-LauncherLockPid -LockPath $lock

    if ($targetPid -le 0) {
        Write-Host "The assistant is not running (no launcher lock at $lock). Nothing to stop." -ForegroundColor Yellow
        return 0
    }

    if (Test-IsLiveLauncher -ProcessId $targetPid) {
        # CONFIRMED a live `-m launcher`. Everything below runs ONLY inside this guard
        # so the audited kill can never fire on an unconfirmed pid.
        $before = Get-AvailableGb
        Write-Host "Stopping the assistant (PID $targetPid, '-m launcher' on :5001)..." -ForegroundColor Cyan
        Stop-ProcessTree -ProcessId $targetPid   # spawn-lib R5: taskkill /T /F the whole tree

        $deadline = (Get-Date).AddSeconds(8)
        while ((Get-Date) -lt $deadline -and (Get-Process -Id $targetPid -ErrorAction SilentlyContinue)) {
            Start-Sleep -Milliseconds 150
        }
        if (Get-Process -Id $targetPid -ErrorAction SilentlyContinue) {
            Write-Host "WARNING: PID $targetPid is still alive after the tree-kill. Check the process manually." -ForegroundColor Red
            return 1
        }

        $after = Get-AvailableGb
        $freed = if ($null -ne $before -and $null -ne $after) { [math]::Round($after - $before, 1) } else { $null }
        $msg = "Assistant stopped (PID $targetPid). Its 14B RAM is free again (:5001 is down)."
        if ($null -ne $freed -and $freed -gt 0) { $msg += " Freed ~$freed GB (now $after GB available)." }
        elseif ($null -ne $after) { $msg += " ($after GB available.)" }
        Write-Host $msg -ForegroundColor Green
        Write-Host "(The stale launcher lock is reclaimed automatically on the next assistant start.)" -ForegroundColor DarkGray
        return 0
    }

    # Lock present but its pid is dead, or recycled to a NON-launcher process. Refuse
    # to kill it - report and touch nothing (the AO-not-running / stale-lock case).
    Write-Host "The assistant is not running - the launcher lock points at PID $targetPid, which is not a live '-m launcher' (stale or recycled). Nothing to stop." -ForegroundColor Yellow
    return 0
}

exit (Stop-Assistant -BlarAiRepo $BlarAiRepo)
