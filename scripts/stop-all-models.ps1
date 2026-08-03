# stop-all-models.ps1 - the panel's ONE kill switch: end every AI model this
# box can PROVE is loaded, with a single confirm, then verify what actually
# died and how much RAM came back.
#
# WHAT IT STOPS (each leg is an already-audited path, never a new kill)
# ====================================================================
#   * ASSISTANT (resident 14B on the AO port): delegated to stop-assistant.ps1
#     - the #797-verified chain (launcher.lock pid -> '-m launcher' cmdline
#     confirm -> spawn-lib Stop-ProcessTree). This script contains NO kill
#     logic of its own for the assistant.
#   * MODEL SERVER (OVMS swap models): watchdog sentinel stood down FIRST
#     (server-should-run.txt - an armed watchdog would revive OVMS within
#     ~2 min), then the ovms process is hard-stopped (safe: model files are
#     read-only - stop-llm.ps1's long-standing contract).
#
# WHAT IT REFUSES TO STOP (reported, never silently skipped)
# ==========================================================
#   * A port holder that is NOT the confirmed assistant / OVMS (recycled pid,
#     stranger on the port): killing what we cannot identify is the exact
#     blind-kill this repo's stop scripts exist to prevent.
#   * Other large python processes: could be an eval or conversion job holding
#     a model - or an MCP server. Listed with pids so the operator decides.
#   * The guest VM: it hosts isolated services, not models. Reported if
#     running; stop it from Hyper-V if that is really wanted.
#
# MODES
# =====
#   (default)  show the plan, ask ONCE ("y" stops everything), execute, verify.
#   -DryRun    print exactly what WOULD be stopped (pids + evidence) and exit.
#              Touches NOTHING - no flags removed, no prompt, no kills.
#   -Yes       skip the confirm prompt (for automation/tests; the panel's [K]
#              entry deliberately does NOT pass it).
#   Safe when nothing is loaded: reports a clean no-op and exits 0.
#
# Exit codes: 0 = done / clean no-op / cancelled / dry-run; 1 = something it
# tried to stop is still alive (loud, with pids).
#
# ASCII-only source (spawn-lib convention). PS 5.1 compatible.
param(
    [switch]$DryRun,
    [switch]$Yes,
    [string]$BlarAiRepo = $(if ($env:BLARAI_REPO) { $env:BLARAI_REPO } else { 'C:\Users\mrbla\blarai' }),
    [int]$AoPort = 5001,
    [string]$OvmsProcessName = 'ovms',
    [string]$OvmsApiBase = 'http://127.0.0.1:8000',
    [string]$StateDir = 'C:\Users\mrbla\agentic-setup\state'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'ai-inventory-lib.ps1')   # the ONE shared detection

# --- 1. Inventory (pure read) ----------------------------------------------
$inv = Get-AiModelInventory -BlarAiRepo $BlarAiRepo -AoPort $AoPort `
    -OvmsProcessName $OvmsProcessName -OvmsApiBase $OvmsApiBase -StateDir $StateDir
$before = $inv.AvailGb

$stopAssistant = ($inv.Assistant.State -eq 'running' -or $inv.Assistant.State -eq 'starting-or-wedged')
$stopOvms      = ($inv.Ovms.Pids.Count -gt 0)
$standDownWatchdog = $inv.WatchdogArmed

# --- 2. The plan, shown before anything is touched -------------------------
Write-Host ''
Write-Host '=============== STOP ALL AI MODELS ===============' -ForegroundColor Cyan
if ($stopAssistant) {
    Write-Host (' WILL STOP  Assistant (resident 14B): ~{0} GB, {1}' -f $inv.Assistant.TreeRssGb, $inv.Assistant.Detail) -ForegroundColor Yellow
    if ($inv.Assistant.Detail -like '*lock+port agreement*') {
        Write-Host ('            evidence: the lock pid owns the AO port, but its command line is unreadable from a non-elevated shell (#1164) - the audited stop-assistant path makes the FINAL confirm and will refuse from this window; run elevated to stop it')
    } else {
        Write-Host ('            evidence: launcher.lock pid confirmed as a live ''-m launcher''; killed via the audited stop-assistant path')
    }
}
if ($stopOvms) {
    Write-Host (' WILL STOP  Model server (OVMS): pid {0}, ~{1} GB, state: {2}' -f ($inv.Ovms.Pids -join ','), $inv.Ovms.RssGb, $inv.Ovms.State) -ForegroundColor Yellow
}
if ($standDownWatchdog) {
    Write-Host ' WILL ALSO  stand the OVMS watchdog down (else it revives the server in ~2 min)' -ForegroundColor Yellow
}
if ($inv.Assistant.State -eq 'port-conflict') {
    Write-Host (' NOT STOPPING  {0}' -f $inv.Assistant.Detail) -ForegroundColor Red
}
if ($inv.Ovms.State -eq 'port-conflict') {
    Write-Host (' NOT STOPPING  {0}' -f $inv.Ovms.Detail) -ForegroundColor Red
}
foreach ($x in $inv.OtherLarge) {
    Write-Host (' NOT STOPPING  {0} pid {1} (~{2} GB): a python job this panel cannot prove is a model - stop it yourself if you meant it' -f $x.Name, $x.Pid, $x.RssGb) -ForegroundColor Yellow
}
if ($inv.Vm.State -eq 'Running') {
    Write-Host (' NOT STOPPING  guest VM {0} (pins ~{1} GB): it hosts isolated services, not models - use Hyper-V to stop it' -f $inv.Vm.Name, $inv.Vm.MemAssignedGb) -ForegroundColor Yellow
}

if (-not $stopAssistant -and -not $stopOvms -and -not $standDownWatchdog) {
    $ramText = '?'
    if ($null -ne $before) { $ramText = $before }
    Write-Host (' Nothing model-bearing is running - nothing to stop. RAM free: {0} GB.' -f $ramText) -ForegroundColor Green
    exit 0
}

if ($DryRun) {
    Write-Host ''
    Write-Host ' [DRY RUN] Nothing was touched - the lines above are what a real run would stop.' -ForegroundColor Cyan
    exit 0
}

# --- 3. One confirm, fail-safe to cancel ------------------------------------
if (-not $Yes) {
    $answer = $null
    try { $answer = Read-Host ' Type y to STOP everything listed above (anything else cancels)' } catch { $answer = $null }
    if ($answer -ne 'y') {
        Write-Host ' Cancelled - nothing was touched.' -ForegroundColor Yellow
        exit 0
    }
}

# --- 4. Execute (every side effect lives inside this guard) -----------------
$assistantExit = 0
if (-not $DryRun) {
    if ($standDownWatchdog -or $stopOvms) {
        Remove-Item (Join-Path $StateDir 'server-should-run.txt') -ErrorAction SilentlyContinue
        Remove-Item (Join-Path $StateDir 'watchdog-gave-up.flag') -ErrorAction SilentlyContinue
        Write-Host ' Watchdog stood down (it will not revive the model server).' -ForegroundColor Green
    }
    if ($stopOvms) {
        $procs = @(Get-Process -Name $OvmsProcessName -ErrorAction SilentlyContinue)
        if ($procs.Count -gt 0) { $procs | Stop-Process -Force -ErrorAction SilentlyContinue }
        Write-Host (' Model server stop issued (pid {0}).' -f ($inv.Ovms.Pids -join ',')) -ForegroundColor Green
    }
    if ($stopAssistant) {
        # The audited chain: confirm-then-tree-kill lives in stop-assistant.ps1.
        & (Join-Path $PSScriptRoot 'stop-assistant.ps1') -BlarAiRepo $BlarAiRepo
        $assistantExit = $LASTEXITCODE
    }
}

# --- 5. Verify: report what actually died and what RAM came back ------------
$deadline = (Get-Date).AddSeconds(10)
while ((Get-Date) -lt $deadline) {
    $aliveA = $false
    if ($stopAssistant) {
        foreach ($tp in $inv.Assistant.TreePids) {
            if (Get-Process -Id $tp -ErrorAction SilentlyContinue) { $aliveA = $true }
        }
    }
    $aliveO = $false
    if ($stopOvms) {
        foreach ($op in $inv.Ovms.Pids) {
            if (Get-Process -Id $op -ErrorAction SilentlyContinue) { $aliveO = $true }
        }
    }
    if (-not $aliveA -and -not $aliveO) { break }
    Start-Sleep -Milliseconds 300
}
Start-Sleep -Milliseconds 1500   # let freed pages land in the Available counter

Write-Host ''
Write-Host ' --- verification ---' -ForegroundColor Cyan
$failed = $false
if ($stopAssistant) {
    $survivors = @()
    foreach ($tp in $inv.Assistant.TreePids) {
        if (Get-Process -Id $tp -ErrorAction SilentlyContinue) { $survivors += $tp }
    }
    if ($survivors.Count -eq 0) {
        Write-Host (' Assistant: DEAD (tree {0} gone; :{1} released)' -f ($inv.Assistant.TreePids -join ','), $AoPort) -ForegroundColor Green
    } else {
        Write-Host (' Assistant: STILL ALIVE - pid(s) {0} survived. Check them manually.' -f ($survivors -join ',')) -ForegroundColor Red
        $failed = $true
    }
}
if ($stopOvms) {
    $survivors = @()
    foreach ($op in $inv.Ovms.Pids) {
        if (Get-Process -Id $op -ErrorAction SilentlyContinue) { $survivors += $op }
    }
    if ($survivors.Count -eq 0) {
        Write-Host (' Model server: DEAD (pid {0} gone)' -f ($inv.Ovms.Pids -join ',')) -ForegroundColor Green
    } else {
        Write-Host (' Model server: STILL ALIVE - pid(s) {0} survived. Check them manually.' -f ($survivors -join ',')) -ForegroundColor Red
        $failed = $true
    }
}
if ($assistantExit -ne 0) {
    Write-Host (' Note: stop-assistant reported exit {0} - read its message above.' -f $assistantExit) -ForegroundColor Red
    $failed = $true
}
$after = Get-AiAvailableGb
if ($null -ne $before -and $null -ne $after) {
    $freed = [math]::Round($after - $before, 1)
    Write-Host (' RAM free: {0} GB -> {1} GB ({2} GB came back)' -f $before, $after, $freed) -ForegroundColor Green
} elseif ($null -ne $after) {
    Write-Host (' RAM free now: {0} GB' -f $after) -ForegroundColor Green
}
if ($failed) { exit 1 }
Write-Host ' All visible models are down.' -ForegroundColor Green
exit 0
