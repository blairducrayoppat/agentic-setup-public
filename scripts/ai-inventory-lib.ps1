# ai-inventory-lib.ps1 - ONE truth for "which AI models are in RAM right now".
#
# WHY THIS EXISTS
# ===============
# The panel header used to ask ONLY the OVMS swap server (:8000) and printed
# "No model loaded" while the assistant's resident 14B held ~12.6 GB on :5001
# (operator screenshot, 2026-07-29). Every surface that answers "what is
# loaded" - the panel header, [V] refresh, [6] full status, and the stop-all
# kill switch's plan + verify passes - dot-sources THIS file and calls
# Get-AiModelInventory, so the answers can never disagree again.
#
# WHAT IT SEES (and how)
# ======================
#   * ASSISTANT (BlarAI's resident 14B on the AO port): the launcher's
#     single-instance lock (<blarai>\certs\launcher.lock) names the pid; the
#     pid is CONFIRMED live with '-m launcher' in its cmdline (a recycled pid
#     is never trusted - mirrors stop-assistant.ps1 and blarai
#     launcher/instance_lock.py, the #797/#863-proven identification); then
#     its process TREE is walked and working sets are summed, and the AO port
#     listener is matched against the tree.
#   * MODEL SERVER (OVMS - the coder/vision/everyday swap models): process by
#     name, plus the REST config endpoint on its serving port (/v1/config for
#     per-model state, /v3/models as fallback), plus process RSS.
#   * GUEST VM: Hyper-V state; a running VM pins its assigned host RAM.
#   * OTHER LARGE python processes (>= threshold): reported as "seen,
#     unproven" - an eval run or a conversion job can hold a model too.
#   * WATCHDOG: whether the OVMS watchdog sentinel is armed (an armed watchdog
#     revives a dead OVMS within ~2 minutes - the kill switch must know).
#
# WHAT IT CANNOT SEE (said out loud, never implied away)
# ======================================================
#   * Load-on-demand models - Whisper voice, SDXL image generation, the VLM,
#     the bge embedder (NPU) - load INSIDE the assistant process. From outside
#     they are part of the assistant's GB figure, not separately listable.
#   * GPU/NPU shared-memory allocations are only PARTLY visible in process
#     working sets (same caveat ai-status.ps1 has always printed).
#   * Whatever executes inside a running VM is not enumerable from the host.
# The inventory carries these as .Blind lines and the renderers PRINT them, so
# absence in the list is never mistaken for absence in RAM.
#
# Read-only: nothing in this file changes system state.
# ASCII-only source (spawn-lib convention: PS 5.1 parses UTF-8-no-BOM as
# cp1252). PS 5.1 compatible - the panel's .cmd falls back to Windows
# PowerShell when pwsh is absent, so no ternary / '??' / '&&' here.

Set-StrictMode -Version Latest

# Mirrors instance_lock.py's _LAUNCHER_CMDLINE_MARKER (and stop-assistant.ps1).
$script:AiLauncherCmdlineMarker = '-m launcher'

function Get-AiLockPid {
    # Read the launcher's recorded pid from its single-instance lock.
    # Missing / unreadable / corrupt -> 0 (no holder). Mirrors
    # instance_lock._read_holder_pid via stop-assistant.ps1's Get-LauncherLockPid.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$LockPath)
    if (-not (Test-Path $LockPath)) { return 0 }
    try { $text = (Get-Content -Path $LockPath -Raw -ErrorAction Stop).Trim() }
    catch { return 0 }
    $parsed = 0
    if ([int]::TryParse($text, [ref]$parsed)) { return $parsed }
    return 0
}

function Test-AiLiveLauncher {
    # KILL-GRADE confirmation ONLY (#1164): true ONLY if the pid is alive AND
    # its cmdline READS and carries '-m launcher'. An unreadable cmdline fails
    # this check even for the GENUINE elevated assistant (non-elevated WMI
    # returns null across the elevation boundary) - which is exactly right for
    # a kill decision and exactly wrong for display. Display identity lives in
    # Get-AiModelInventory's table-based logic; do NOT reach for this helper
    # from a display path. Mirrors instance_lock._is_live_launcher via
    # stop-assistant.ps1's Test-IsLiveLauncher.
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$ProcessId)
    if ($ProcessId -le 0) { return $false }
    if (-not (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)) { return $false }
    try { $cmd = (Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction Stop).CommandLine }
    catch { return $false }
    if (-not $cmd) { return $false }
    return ([string]$cmd).Contains($script:AiLauncherCmdlineMarker)
}

function Get-AiProcessTable {
    # One WMI fetch shared by the tree walk and the large-process scan.
    [CmdletBinding()]
    param()
    try {
        return @(Get-CimInstance Win32_Process -ErrorAction Stop |
                 Select-Object ProcessId, ParentProcessId, Name, CommandLine, WorkingSetSize)
    } catch { return @() }
}

function Get-AiProcessTreePids {
    # Breadth-first descendants of $RootPid (root included) from a prefetched
    # table. A visited set guards against parent-pid recycling cycles.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$RootPid,
        [Parameter(Mandatory)][object[]]$Table
    )
    $seen = @{}
    $queue = New-Object System.Collections.Queue
    $queue.Enqueue($RootPid)
    while ($queue.Count -gt 0) {
        $cur = [int]$queue.Dequeue()
        if ($seen.ContainsKey($cur)) { continue }
        $seen[$cur] = $true
        foreach ($row in $Table) {
            if ([int]$row.ParentProcessId -eq $cur -and -not $seen.ContainsKey([int]$row.ProcessId)) {
                $queue.Enqueue([int]$row.ProcessId)
            }
        }
    }
    return @($seen.Keys | ForEach-Object { [int]$_ })
}

function Get-AiPortListenerPids {
    # Unique owning pids of LISTEN sockets on a local port (IPv4 + IPv6).
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$Port)
    try {
        $conns = @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction Stop)
    } catch { return @() }
    return @($conns | ForEach-Object { [int]$_.OwningProcess } | Sort-Object -Unique)
}

function Get-AiAvailableGb {
    try { return [math]::Round((Get-Counter '\Memory\Available MBytes').CounterSamples[0].CookedValue / 1024, 1) }
    catch { return $null }
}

function Get-AiOvmsModelLines {
    # Ask the OVMS REST surface what it holds. /v1/config reports per-model
    # version STATE (AVAILABLE / LOADING / ...); /v3/models (the OpenAI-compat
    # list the panel always used) is the fallback. Returns @() when nothing
    # answers - the caller decides what that means.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ApiBase)
    $lines = @()
    try {
        $r = Invoke-WebRequest ($ApiBase.TrimEnd('/') + '/v1/config') -TimeoutSec 3 -UseBasicParsing
        $cfg = $r.Content | ConvertFrom-Json
        foreach ($prop in $cfg.PSObject.Properties) {
            $states = @()
            try { $states = @($prop.Value.model_version_status | ForEach-Object { [string]$_.state }) } catch {}
            if ($states.Count -gt 0) { $lines += ('{0} ({1})' -f $prop.Name, ($states -join ', ')) }
            else { $lines += [string]$prop.Name }
        }
    } catch {}
    if ($lines.Count -gt 0) { return $lines }
    try {
        $r = Invoke-WebRequest ($ApiBase.TrimEnd('/') + '/v3/models') -TimeoutSec 2 -UseBasicParsing
        $lines = @((($r.Content | ConvertFrom-Json).data) | ForEach-Object { [string]$_.id })
    } catch {}
    return $lines
}

function Get-AiModelInventory {
    # The one shared answer to "what AI models are in RAM, and what can't we
    # see". Pure read. Parameters exist so the verify suites can drive the SAME
    # code against fixtures (a decoy repo root / port / process name) without
    # ever touching the real assistant, OVMS, or GPU.
    [CmdletBinding()]
    param(
        [string]$BlarAiRepo = $(if ($env:BLARAI_REPO) { $env:BLARAI_REPO } else { 'C:\Users\mrbla\blarai' }),
        [int]$AoPort = 5001,
        [string]$OvmsProcessName = 'ovms',
        [string]$OvmsApiBase = 'http://127.0.0.1:8000',
        [double]$OtherLargeMinGb = 2.0,
        [bool]$IncludeVm = $true,
        [string]$VmName = 'BlarAI-Orchestrator',
        [string]$StateDir = 'C:\Users\mrbla\agentic-setup\state',
        [object[]]$ProcessTable = $null
    )

    # $ProcessTable exists so the verify suite can inject a synthetic table
    # (e.g. a row whose CommandLine is NULL, the elevated-process shape) without
    # needing a real cross-elevation fixture. Real callers omit it.
    $table = $ProcessTable
    if ($null -eq $table -or $table.Count -eq 0) { $table = Get-AiProcessTable }

    # --- Assistant (lock pid -> confirm -> tree RSS -> port match) ----------
    $lockPath = Join-Path $BlarAiRepo 'certs\launcher.lock'
    $lockPid = Get-AiLockPid -LockPath $lockPath
    $portPids = @(Get-AiPortListenerPids -Port $AoPort)
    $assistant = @{
        State = 'not-running'; Pid = 0; PortServing = $false
        TreePids = @(); TreeRssGb = 0.0; Detail = ''
    }
    # Identity is ELEVATION-AWARE (#1164): a non-elevated query still sees an
    # elevated launcher's process row (pid / name / parent / RSS) but WMI hides
    # its CommandLine (comes back null), so the cmdline marker cannot confirm.
    # Two independent records agreeing - the lock pid ALIVE and OWNING the AO
    # port - is identity enough for DISPLAY, said with the caveat. A readable
    # cmdline WITHOUT the marker stays provably-foreign (recycled pid): never
    # identified, port agreement or not. The kill paths keep the strict cmdline
    # confirm (stop-assistant.ps1, #797) - elevation satisfies it.
    $lockRow = $null
    if ($lockPid -gt 0) {
        foreach ($row in $table) {
            if ([int]$row.ProcessId -eq $lockPid) { $lockRow = $row; break }
        }
    }
    $lockAlive = ($null -ne $lockRow)
    $lockCmd = ''
    if ($lockAlive -and $null -ne $lockRow.CommandLine) { $lockCmd = [string]$lockRow.CommandLine }
    $lockConfirmed = ($lockAlive -and $lockCmd -ne '' -and $lockCmd.Contains($script:AiLauncherCmdlineMarker))
    $lockProvablyForeign = ($lockAlive -and $lockCmd -ne '' -and -not $lockCmd.Contains($script:AiLauncherCmdlineMarker))
    # Agreement = a port owner INSIDE the lock pid's process tree (the same
    # membership the serving check uses - the launcher may hold the socket
    # itself or via a child; parent links stay visible across elevation).
    $lockTreePids = @()
    if ($lockAlive) { $lockTreePids = @(Get-AiProcessTreePids -RootPid $lockPid -Table $table) }
    $portAgrees = $false
    if ($lockAlive -and -not $lockProvablyForeign) {
        foreach ($p in $portPids) { if ($lockTreePids -contains $p) { $portAgrees = $true } }
    }
    if ($lockConfirmed -or $portAgrees) {
        $treePids = $lockTreePids
        $rss = 0.0
        foreach ($row in $table) {
            if ($treePids -contains [int]$row.ProcessId) { $rss += [double]$row.WorkingSetSize }
        }
        $assistant.Pid = $lockPid
        $assistant.TreePids = $treePids
        $assistant.TreeRssGb = [math]::Round($rss / 1GB, 1)
        $serving = $false
        foreach ($p in $portPids) { if ($treePids -contains $p) { $serving = $true } }
        $assistant.PortServing = $serving
        if ($serving) {
            $assistant.State = 'running'
            $assistant.Detail = ('pid {0}, serving :{1}' -f $lockPid, $AoPort)
            if (-not $lockConfirmed) {
                $assistant.Detail += ' (identity via lock+port agreement: the command line is unreadable from a non-elevated shell - run the panel elevated for the full confirm)'
            }
        } else {
            $assistant.State = 'starting-or-wedged'
            $assistant.Detail = ('pid {0} alive but :{1} is NOT serving (starting up, or wedged)' -f $lockPid, $AoPort)
        }
    } else {
        if ($portPids.Count -gt 0) {
            $ownerId = $portPids[0]
            $ownerName = '?'
            foreach ($row in $table) { if ([int]$row.ProcessId -eq $ownerId) { $ownerName = [string]$row.Name } }
            $assistant.State = 'port-conflict'
            $assistant.Pid = $ownerId
            $assistant.Detail = (":{0} is held by '{1}' pid {2}, which is NOT the recorded assistant - investigate before trusting or killing it" -f $AoPort, $ownerName, $ownerId)
        } elseif ($lockAlive -and $lockCmd -eq '') {
            $assistant.Detail = ('lock pid {0} is alive but its command line is unreadable from this shell and :{1} is quiet - starting up, or run the panel elevated to confirm' -f $lockPid, $AoPort)
        } elseif ($lockPid -gt 0) {
            $assistant.Detail = ('lock pid {0} is stale (dead or not a live ''-m launcher''); :{1} is quiet' -f $lockPid, $AoPort)
        } else {
            $assistant.Detail = ('no launcher lock; :{0} is quiet' -f $AoPort)
        }
    }

    # --- OVMS (process by name -> REST states -> RSS) -----------------------
    $ovmsPort = 8000
    try { $ovmsPort = ([uri]$OvmsApiBase).Port } catch {}
    $ovmsProcs = @(Get-Process -Name $OvmsProcessName -ErrorAction SilentlyContinue)
    $ovms = @{
        State = 'not-running'; Pids = @(); RssGb = 0.0; Models = @(); Detail = ''
    }
    if ($ovmsProcs.Count -gt 0) {
        $ovms.Pids = @($ovmsProcs | ForEach-Object { [int]$_.Id })
        $sum = 0.0
        foreach ($p in $ovmsProcs) { $sum += [double]$p.WorkingSet64 }
        $ovms.RssGb = [math]::Round($sum / 1GB, 1)
        $ovms.Models = @(Get-AiOvmsModelLines -ApiBase $OvmsApiBase)
        if ($ovms.Models.Count -gt 0) {
            $ovms.State = 'running'
            $ovms.Detail = ('pid {0} - {1}' -f ($ovms.Pids -join ','), ($ovms.Models -join '; '))
        } else {
            $ovms.State = 'not-answering'
            $ovms.Detail = ('pid {0} exists but the API on :{1} is not answering (still loading, or wedged)' -f ($ovms.Pids -join ','), $ovmsPort)
        }
    } else {
        $ovmsPortPids = @(Get-AiPortListenerPids -Port $ovmsPort)
        if ($ovmsPortPids.Count -gt 0) {
            $ownerId = $ovmsPortPids[0]
            $ownerName = '?'
            foreach ($row in $table) { if ([int]$row.ProcessId -eq $ownerId) { $ownerName = [string]$row.Name } }
            $ovms.State = 'port-conflict'
            $ovms.Detail = (":{0} is held by '{1}' pid {2} (not '{3}') - model launchers will refuse to start" -f $ovmsPort, $ownerName, $ownerId, $OvmsProcessName)
        } else {
            $ovms.Detail = ('no ''{0}'' process; :{1} is free' -f $OvmsProcessName, $ovmsPort)
        }
    }

    # --- Guest VM -----------------------------------------------------------
    $vm = @{ Name = $VmName; State = 'Unknown'; MemAssignedGb = 0.0 }
    if ($IncludeVm) {
        try {
            $v = Get-VM -Name $VmName -ErrorAction Stop
            $vm.State = [string]$v.State
            $vm.MemAssignedGb = [math]::Round([double]$v.MemoryAssigned / 1GB, 1)
        } catch { $vm.State = 'Unknown' }
    }

    # --- Other large python processes (seen, unproven) ----------------------
    $otherLarge = @()
    $minBytes = $OtherLargeMinGb * 1GB
    foreach ($row in $table) {
        $n = [string]$row.Name
        if ($n -ne 'python.exe' -and $n -ne 'pythonw.exe') { continue }
        $rowPid = [int]$row.ProcessId
        if ($assistant.TreePids -contains $rowPid) { continue }
        if ($ovms.Pids -contains $rowPid) { continue }
        if ([double]$row.WorkingSetSize -lt $minBytes) { continue }
        $cmd = [string]$row.CommandLine
        if ($cmd.Length -gt 100) { $cmd = $cmd.Substring(0, 100) + '...' }
        $otherLarge += @{
            Pid = $rowPid; Name = $n
            RssGb = [math]::Round([double]$row.WorkingSetSize / 1GB, 1)
            Cmd = $cmd
        }
    }

    # --- Watchdog sentinel (revives OVMS while armed) -----------------------
    $watchdogArmed = Test-Path (Join-Path $StateDir 'server-should-run.txt')

    return @{
        TakenAt = Get-Date
        AvailGb = Get-AiAvailableGb
        Assistant = $assistant
        Ovms = $ovms
        Vm = $vm
        OtherLarge = $otherLarge
        WatchdogArmed = $watchdogArmed
        Blind = @(
            'Voice (Whisper), image generation (SDXL), the VLM and the bge embedder (NPU) load INSIDE the assistant process - when loaded they are part of its GB figure above, not separately listable from outside.',
            'GPU/NPU shared-memory allocations are only partly visible in these working-set figures.',
            'Whatever executes inside a running VM is not enumerable from the host.'
        )
    }
}

function Write-AiInventoryHeader {
    # The panel header block: every model class on its own aligned line, plus
    # the cannot-see note whenever a figure exists that the note qualifies.
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Inventory)
    $a = $Inventory.Assistant
    $o = $Inventory.Ovms
    Write-Host ' AI models in RAM:' -ForegroundColor Cyan
    switch ($a.State) {
        'running'            { Write-Host ('   Assistant (resident 14B)   RUNNING   ~{0} GB   {1}' -f $a.TreeRssGb, $a.Detail) -ForegroundColor Green }
        'starting-or-wedged' { Write-Host ('   Assistant (resident 14B)   LOADED    ~{0} GB   {1}' -f $a.TreeRssGb, $a.Detail) -ForegroundColor Yellow }
        'port-conflict'      { Write-Host ('   Assistant (resident 14B)   CONFLICT  {0}' -f $a.Detail) -ForegroundColor Red }
        default              { Write-Host '   Assistant (resident 14B)   not running' -ForegroundColor DarkGray }
    }
    switch ($o.State) {
        'running'       { Write-Host ('   Model server (OVMS swap)   RUNNING   ~{0} GB   {1}' -f $o.RssGb, $o.Detail) -ForegroundColor Green }
        'not-answering' { Write-Host ('   Model server (OVMS swap)   LOADED    ~{0} GB   {1}' -f $o.RssGb, $o.Detail) -ForegroundColor Yellow }
        'port-conflict' { Write-Host ('   Model server (OVMS swap)   CONFLICT  {0}' -f $o.Detail) -ForegroundColor Red }
        default         { Write-Host '   Model server (OVMS swap)   not running' -ForegroundColor DarkGray }
    }
    foreach ($x in $Inventory.OtherLarge) {
        Write-Host ('   Also large: {0} pid {1} ~{2} GB (a python job, not a known model server)' -f $x.Name, $x.Pid, $x.RssGb) -ForegroundColor Yellow
    }
    if ($Inventory.WatchdogArmed -and $o.State -eq 'not-running') {
        Write-Host '   Watchdog ARMED: OVMS is down but its watchdog will restart it within ~2 min.' -ForegroundColor Yellow
    }
    $anyFigure = ($a.State -eq 'running' -or $a.State -eq 'starting-or-wedged' -or
                  $o.State -eq 'running' -or $o.State -eq 'not-answering')
    if ($anyFigure) {
        Write-Host ' (Voice/image/embedding models load INSIDE the assistant when used - its GB' -ForegroundColor DarkGray
        Write-Host '  figure includes them. GPU/NPU shared RAM is only partly visible.)' -ForegroundColor DarkGray
    }
}

function Write-AiInventoryReport {
    # The [6] full-status block: same truth, more evidence per line, and the
    # NOT-VISIBLE list printed in full (fail-loud honesty about the gaps).
    # -NoVmLine: for callers that render their own richer VM section
    # (ai-status.ps1 lists ALL VMs plus the stopped-vms restart note).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Inventory,
        [switch]$NoVmLine
    )
    $a = $Inventory.Assistant
    $o = $Inventory.Ovms
    Write-Host '--- AI models in RAM (shared detection: ai-inventory-lib) ---' -ForegroundColor Cyan
    switch ($a.State) {
        'running' {
            Write-Host ("Assistant    : RUNNING - {0} ('-m launcher' confirmed via certs\launcher.lock)" -f $a.Detail) -ForegroundColor Green
            Write-Host ('               process tree: {0} process(es), ~{1} GB working set' -f $a.TreePids.Count, $a.TreeRssGb)
        }
        'starting-or-wedged' {
            Write-Host ("Assistant    : LOADED but NOT SERVING - {0}" -f $a.Detail) -ForegroundColor Yellow
            Write-Host ('               process tree: {0} process(es), ~{1} GB working set' -f $a.TreePids.Count, $a.TreeRssGb)
        }
        'port-conflict' { Write-Host ('Assistant    : CONFLICT - {0}' -f $a.Detail) -ForegroundColor Red }
        default         { Write-Host ('Assistant    : not running ({0})' -f $a.Detail) -ForegroundColor DarkGray }
    }
    switch ($o.State) {
        'running'       { Write-Host ('Model server : RUNNING - {0}, ~{1} GB working set' -f $o.Detail, $o.RssGb) -ForegroundColor Green }
        'not-answering' { Write-Host ('Model server : LOADED but NOT ANSWERING - {0}, ~{1} GB working set' -f $o.Detail, $o.RssGb) -ForegroundColor Yellow }
        'port-conflict' { Write-Host ('Model server : CONFLICT - {0}' -f $o.Detail) -ForegroundColor Red }
        default         { Write-Host ('Model server : not running ({0})' -f $o.Detail) -ForegroundColor DarkGray }
    }
    if ($Inventory.WatchdogArmed) {
        Write-Host 'Watchdog     : ARMED - if OVMS dies or is stopped without standing this down, it restarts within ~2 min.' -ForegroundColor Yellow
    } else {
        Write-Host 'Watchdog     : standing down (no server-should-run sentinel).' -ForegroundColor DarkGray
    }
    if (-not $NoVmLine) {
        if ($Inventory.Vm.State -eq 'Running') {
            Write-Host ('Guest VM     : {0} Running - pins ~{1} GB host RAM' -f $Inventory.Vm.Name, $Inventory.Vm.MemAssignedGb) -ForegroundColor Green
        } else {
            Write-Host ('Guest VM     : {0} - {1}' -f $Inventory.Vm.Name, $Inventory.Vm.State) -ForegroundColor DarkGray
        }
    }
    if ($Inventory.OtherLarge.Count -gt 0) {
        Write-Host 'Other large python processes (could hold a model - this panel cannot prove it):' -ForegroundColor Yellow
        foreach ($x in $Inventory.OtherLarge) {
            Write-Host ('   {0} pid {1} ~{2} GB  {3}' -f $x.Name, $x.Pid, $x.RssGb, $x.Cmd)
        }
    } else {
        Write-Host 'Other large python processes: none seen.' -ForegroundColor DarkGray
    }
    Write-Host 'NOT VISIBLE from outside (absence above is NOT proof of absence):' -ForegroundColor Yellow
    foreach ($b in $Inventory.Blind) { Write-Host ('   - {0}' -f $b) }
}
