#requires -Version 7.0
<#
.SYNOPSIS
  box-state.ps1 - the ONE canonical "what is consuming this box right now" report
  for the BlarAI consumer model. Read-only by default (ALWAYS exits 0);
  -Baseline lean FAILS LOUDLY on any deviation from an idle, model-free box.

.DESCRIPTION
  Why this exists (the unnoticed-VM incident, 2026-07-10, Vikunja #816):
    A sealed Orchestrator Hyper-V VM ran for ~7 hours through an entire evening of
    perf measurements AND the coordinator's restore checklist, unnoticed, because
    every box-state sweep was ENUMERATED FROM MEMORY (processes / ports / RAM /
    tasks) and a VM is the one consumer class invisible to a process-name sweep.
    RAM arithmetic stayed silent because the guest was small. This is the
    "checklist that implies 100% while covering 80%" failure. The fix is a single
    canonical report that every gate / restore / watch check runs INSTEAD of a
    hand-rolled sweep - and that enumerates ALL guests (Get-VM), never a known name.

  Two modes:
    (default)        Read-only report. Prints every consumer class. ALWAYS exits 0.
    -Baseline lean   Same report, then a fail-loud verdict: exits 1 (naming each
                     deviation) if ANY of these holds -
                       * any Hyper-V VM is Running (or Get-VM cannot be queried),
                       * the AO is resident (:5001 held / a live '-m launcher'),
                       * the OVMS model server is resident (ovms.exe or :8000 held),
                       * available RAM is below the lean band (-MinLeanAvailableGiB),
                       * a lean-relevant probe errored (fail-closed: cannot prove lean).

  Consumer classes reported (each a tagged section):
    [VM]     Hyper-V guests - ALL of them, Name + State + assigned memory.
    [MODEL]  OVMS model server (:8000) - process + loaded model ids.
    [AO]     Assistant Orchestrator (:5001) - launcher lock + live '-m launcher'.
    [PORTS]  Listeners on the ports of interest, with owning process names.
    [GPU]    Arc adapter + driver; best-effort per-process GPU memory if cheap.
    [PROC]   python / pythonw / node / opencode inventory, with command lines.
    [RAM]    Total / available / used, evaluated against the lean band.
    [TASK]   \BlarAI\ scheduled tasks - state + last result.

  READ-ONLY GUARANTEE: this script issues only Get-* / Test-Path / Join-Path and a
  localhost GET (Invoke-WebRequest to the OVMS model list, exactly as ai-status.ps1
  does). It never stops, kills, unregisters, writes, or otherwise mutates anything.
  verify-box-state.ps1 enforces that structurally (an AST denylist of every
  mutating cmdlet).

  Source is ASCII-only (no em-dash / section-sign literals) so it renders and pipes
  identically under every pwsh host the gate/restore/watch checks invoke it from.

.PARAMETER Baseline
  'lean' turns on the fail-loud baseline verdict. Omit for a pure read-only report.

.PARAMETER MinLeanAvailableGiB
  Lean-band floor in GiB. Below this available RAM, -Baseline lean fails. Default
  14.0 - deliberately just under run-battery-night.ps1's established 15.0 GiB
  probe-floor ("too starved to even probe"). It catches a resident 14B (~12.6 GB ->
  available ~7-10 GiB, well under 14) or any comparably large UNNAMED consumer,
  while leaving generous headroom so a busy-but-model-free dev box (available ~18-22
  GiB) passes. The named consumers (VM / OVMS / AO) are caught by name regardless of
  size; this floor is only the backstop for a consumer no section names.

.PARAMETER Ports
  Ports of interest for the listener sweep. Default: 5001 (AO / assistant), 8000
  (OVMS model server REST), 8099 (tool-call fixer proxy the coding agent talks to),
  9000 (auxiliary model-server / reverse-proxy).

.PARAMETER BlarAiRepo
  BlarAI checkout that owns the launcher single-instance lock (certs\launcher.lock).
  Mirrors stop-assistant.ps1's resolution so both point at the same checkout.

.PARAMETER TaskPath
  Scheduled-task folder to enumerate. Default '\BlarAI\'.

.EXAMPLE
  .\box-state.ps1
  Read-only report; exit 0 always.

.EXAMPLE
  .\box-state.ps1 -Baseline lean
  Report + fail-loud verdict; exit 1 if the box is not idle / model-free.
#>
[CmdletBinding()]
param(
    [ValidateSet('lean')]
    [string]$Baseline,
    [double]$MinLeanAvailableGiB = 14.0,
    [int[]]$Ports = @(5001, 8000, 8099, 9000),
    [string]$BlarAiRepo = $(if ($env:BLARAI_REPO) { $env:BLARAI_REPO } else { 'C:\Users\mrbla\blarai' }),
    [string]$TaskPath = '\BlarAI\'
)

# A report must SURVIVE a failing probe and still print the rest - each probe below
# self-guards with try/catch and returns a structured result (with .Ok=$false on a
# genuine query failure, which -Baseline lean then treats as fail-closed). We never
# want one flaky counter to abort the whole sweep, so the top level is Continue.
$ErrorActionPreference = 'Continue'

# Known roles for the ports we sweep (labels only; the sweep itself is generic).
$script:PortRoles = @{
    5001 = 'AO / assistant'
    8000 = 'OVMS model server (REST)'
    8099 = 'tool-call fixer proxy (OpenCode)'
    9000 = 'aux model-server / reverse-proxy'
}

# Lean-mode deviations accumulate here; the verdict block reads them at the end.
$script:Deviations = [System.Collections.Generic.List[string]]::new()
function Add-Deviation([string]$msg) { [void]$script:Deviations.Add($msg) }

function Section([string]$t) { Write-Host ''; Write-Host "== $t ==" -ForegroundColor Cyan }

# ---------------------------------------------------------------------------
# Probes - each returns a plain hashtable; NONE of them mutate anything.
# ---------------------------------------------------------------------------

function Get-VmReport {
    # ALL Hyper-V guests (the incident fix: never a known name). Distinguishes
    # "Hyper-V not installed" (no guests possible -> lean-OK) from "query failed"
    # (cannot prove no VM -> fail-closed under -Baseline lean).
    try {
        $vms = @(Get-VM -ErrorAction Stop)
        $rows = foreach ($vm in $vms) {
            $memGiB = $null
            if ($vm.State -eq 'Running') { $memGiB = [math]::Round($vm.MemoryAssigned / 1GB, 2) }
            [pscustomobject]@{ Name = $vm.Name; State = [string]$vm.State; MemGiB = $memGiB }
        }
        $running = @($rows | Where-Object { $_.State -eq 'Running' } | ForEach-Object { $_.Name })
        return @{ Ok = $true; Present = $true; Rows = @($rows); Running = @($running) }
    }
    catch [System.Management.Automation.CommandNotFoundException] {
        # Hyper-V PowerShell module absent -> this host cannot run guests.
        return @{ Ok = $true; Present = $false; Rows = @(); Running = @() }
    }
    catch {
        return @{ Ok = $false; Present = $true; Error = "$($_.Exception.Message)"; Rows = @(); Running = @() }
    }
}

function Get-ModelServerReport {
    # OVMS model server: the ovms process + (if up) the loaded model ids over the
    # local REST endpoint - the same localhost GET ai-status.ps1 performs.
    $p = Get-Process ovms -ErrorAction SilentlyContinue | Select-Object -First 1
    $ids = $null
    $wsGiB = $null
    if ($p) {
        $wsGiB = [math]::Round($p.WorkingSet64 / 1GB, 1)
        try {
            $r = Invoke-WebRequest 'http://127.0.0.1:8000/v3/models' -TimeoutSec 3 -UseBasicParsing
            $ids = @((($r.Content | ConvertFrom-Json).data) | ForEach-Object { $_.id }) -join ', '
        }
        catch { $ids = $null }
    }
    return @{ Running = [bool]$p; Pid = $(if ($p) { $p.Id } else { 0 }); WorkingSetGiB = $wsGiB; Models = $ids }
}

function Get-AoReport {
    # AO / assistant: the authoritative signal is the launcher single-instance lock
    # (certs\launcher.lock) confirmed to point at a LIVE '-m launcher' (mirrors
    # stop-assistant.ps1 / instance_lock.py - a bare pid can be recycled). We also
    # note whether :5001 is actually listening. READ-ONLY: we only read the lock and
    # the process cmdline; we never touch either.
    $lock = Join-Path $BlarAiRepo 'certs\launcher.lock'
    $lockPid = 0
    if (Test-Path $lock) {
        try {
            $text = (Get-Content -Path $lock -Raw -ErrorAction Stop).Trim()
            [void][int]::TryParse($text, [ref]$lockPid)
        }
        catch { $lockPid = 0 }
    }
    $live = $false
    if ($lockPid -gt 0 -and (Get-Process -Id $lockPid -ErrorAction SilentlyContinue)) {
        try {
            $cmd = (Get-CimInstance Win32_Process -Filter "ProcessId=$lockPid" -ErrorAction Stop).CommandLine
            if ($cmd -and ([string]$cmd).Contains('-m launcher')) { $live = $true }
        }
        catch { $live = $false }
    }
    # :5001 listener + owner (the AO may hold the port before/after the lock exists).
    $portHeld = $false; $portPid = 0; $portOwner = $null
    $conn = Get-NetTCPConnection -LocalPort 5001 -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($conn) {
        $portHeld = $true
        $portPid = [int]$conn.OwningProcess
        $portOwner = (Get-Process -Id $portPid -ErrorAction SilentlyContinue).Name
    }
    return @{ LockPid = $lockPid; Live = $live; PortHeld = $portHeld; PortPid = $portPid; PortOwner = $portOwner }
}

function Get-PortReport {
    # NB: the parameter is $PortList, NOT $Ports - PowerShell variables are
    # case-insensitive, so a local named $ports would alias the script's $Ports and
    # corrupt it on assignment. Keeping the names distinct avoids that footgun.
    param([int[]]$PortList)
    $rows = foreach ($port in $PortList) {
        $conns = @(Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue)
        if ($conns.Count -gt 0) {
            $ownerPid = [int]$conns[0].OwningProcess
            $owner = (Get-Process -Id $ownerPid -ErrorAction SilentlyContinue).Name
            [pscustomobject]@{ Port = $port; Role = $script:PortRoles[$port]; Held = $true; Pid = $ownerPid; Owner = $owner }
        }
        else {
            [pscustomobject]@{ Port = $port; Role = $script:PortRoles[$port]; Held = $false; Pid = 0; Owner = $null }
        }
    }
    return @($rows)
}

function Get-GpuReport {
    # Adapter + driver is always cheap (Win32_VideoController). Per-process GPU
    # memory is best-effort ONLY: one bounded counter sample; if the GPU counter set
    # is absent/localized we degrade to a note rather than slow or break the report.
    $adapters = @()
    try {
        $adapters = @(Get-CimInstance Win32_VideoController -ErrorAction Stop |
            Where-Object { $_.Name -match 'Arc|Intel|GPU|Graphics' } |
            ForEach-Object { [pscustomobject]@{ Name = $_.Name; Driver = $_.DriverVersion } })
    }
    catch { $adapters = @() }

    $procMem = $null
    try {
        $samples = (Get-Counter '\GPU Process Memory(*)\Local Usage' -MaxSamples 1 -ErrorAction Stop).CounterSamples
        $byPid = @{}
        foreach ($s in $samples) {
            if ($s.InstanceName -match '^pid_(\d+)_' -and $s.CookedValue -gt 0) {
                $thePid = [int]$Matches[1]
                $byPid[$thePid] = ([double]($byPid[$thePid])) + [double]$s.CookedValue
            }
        }
        $procMem = @($byPid.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 5 | ForEach-Object {
                $name = (Get-Process -Id $_.Key -ErrorAction SilentlyContinue).Name
                [pscustomobject]@{ Pid = $_.Key; Name = $name; MiB = [math]::Round($_.Value / 1MB, 0) }
            })
    }
    catch { $procMem = $null }

    return @{ Adapters = @($adapters); ProcMem = $procMem }
}

function Get-ProcReport {
    # Interpreter / agent inventory with command lines - surfaces MCP servers, fleet
    # legs, coder processes, opencode, etc. INFORMATIONAL: dev-box python.exe are
    # MCP servers, not leaks, so this section is never itself a lean deviation.
    $names = @('python.exe', 'pythonw.exe', 'node.exe', 'opencode.exe')
    $filter = ($names | ForEach-Object { "Name='$_'" }) -join ' OR '
    $rows = @()
    try {
        $procs = @(Get-CimInstance Win32_Process -Filter $filter -ErrorAction Stop)
        $rows = $procs | ForEach-Object {
            $cmd = [string]$_.CommandLine
            if ($cmd.Length -gt 140) { $cmd = $cmd.Substring(0, 137) + '...' }
            [pscustomobject]@{
                Pid     = [int]$_.ProcessId
                Name    = $_.Name
                WsMiB   = [math]::Round(([double]$_.WorkingSetSize) / 1MB, 0)
                Cmd     = $cmd
            }
        } | Sort-Object WsMiB -Descending
    }
    catch { $rows = @() }
    return @($rows)
}

function Get-MemReport {
    # Total / available / used. Mirrors ai-status.ps1 + stop-assistant.ps1: prefer the
    # '\Memory\Available MBytes' counter, fall back to Win32_OperatingSystem when the
    # counter path is unavailable (localized hosts). .Ok=$false only if BOTH fail.
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $totalGiB = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
        try { $availGiB = [math]::Round((Get-Counter '\Memory\Available MBytes' -ErrorAction Stop).CounterSamples[0].CookedValue / 1024, 1) }
        catch { $availGiB = [math]::Round($os.FreePhysicalMemory / 1MB, 1) }
        $usedGiB = [math]::Round($totalGiB - $availGiB, 1)
        return @{ Ok = $true; TotalGiB = $totalGiB; AvailableGiB = $availGiB; UsedGiB = $usedGiB }
    }
    catch {
        return @{ Ok = $false; Error = "$($_.Exception.Message)" }
    }
}

function Get-TaskReport {
    param([string]$TaskPath)
    # \BlarAI\ scheduled tasks - state + last result. INFORMATIONAL (a Running task
    # is surfaced but is not one of the ticket's enumerated lean deviations).
    $folder = $TaskPath.TrimEnd('\') + '\*'
    $rows = @()
    try {
        $tasks = @(Get-ScheduledTask -TaskPath $folder -ErrorAction Stop)
        $rows = foreach ($t in $tasks) {
            $last = $null; $lastRun = $null
            try {
                $info = Get-ScheduledTaskInfo -TaskPath $t.TaskPath -TaskName $t.TaskName -ErrorAction Stop
                $last = $info.LastTaskResult
                $lastRun = $info.LastRunTime
            }
            catch { }
            [pscustomobject]@{ Name = $t.TaskName; State = [string]$t.State; LastResult = $last; LastRun = $lastRun }
        }
    }
    catch { $rows = @() }
    return @($rows)
}

# ---------------------------------------------------------------------------
# Report - run every probe, render every section. This half NEVER exits non-zero.
# ---------------------------------------------------------------------------

Write-Host '================= BOX STATE =================' -ForegroundColor Cyan
Write-Host ("host {0}  |  {1}  |  mode: {2}" -f $env:COMPUTERNAME, (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $(if ($Baseline -eq 'lean') { "BASELINE lean (fail-loud, floor $MinLeanAvailableGiB GiB)" } else { 'read-only' }))

$vm = Get-VmReport
Section '[VM] Hyper-V guests (ALL guests, not a known name)'
if (-not $vm.Ok) {
    Write-Host "  QUERY FAILED: $($vm.Error)" -ForegroundColor Red
}
elseif (-not $vm.Present) {
    Write-Host '  Hyper-V PowerShell module not present - no guests possible on this host.' -ForegroundColor DarkGray
}
elseif ($vm.Rows.Count -eq 0) {
    Write-Host '  no VMs defined.' -ForegroundColor Green
}
else {
    foreach ($row in $vm.Rows) {
        $col = if ($row.State -eq 'Running') { 'Red' } else { 'Green' }
        $mem = if ($null -ne $row.MemGiB) { "  (assigned $($row.MemGiB) GiB)" } else { '' }
        Write-Host ("  {0,-28} {1}{2}" -f $row.Name, $row.State, $mem) -ForegroundColor $col
    }
}

$model = Get-ModelServerReport
Section '[MODEL] OVMS model server (:8000)'
if ($model.Running) {
    if ($model.Models) { Write-Host "  RUNNING - loaded: $($model.Models)" -ForegroundColor Red }
    else { Write-Host '  process resident but NOT answering :8000/v3/models (loading or wedged)' -ForegroundColor Yellow }
    Write-Host ("  ovms PID {0}, working set {1} GiB" -f $model.Pid, $model.WorkingSetGiB)
}
else {
    Write-Host '  not running.' -ForegroundColor Green
}

$ao = Get-AoReport
Section '[AO] Assistant Orchestrator (:5001, resident 14B)'
if ($ao.Live) {
    $listen = if ($ao.PortHeld) { ':5001 listening' } else { ':5001 not yet listening' }
    Write-Host ("  RESIDENT - live '-m launcher' (PID {0}), {1}" -f $ao.LockPid, $listen) -ForegroundColor Red
}
elseif ($ao.PortHeld) {
    Write-Host ("  :5001 held by '{0}' (PID {1}) - no confirmed launcher lock" -f $ao.PortOwner, $ao.PortPid) -ForegroundColor Yellow
}
else {
    Write-Host '  not running (no live launcher lock, :5001 free).' -ForegroundColor Green
}

$portRows = Get-PortReport -PortList $Ports
Section '[PORTS] listeners of interest (owning process)'
foreach ($row in $portRows) {
    if ($row.Held) {
        Write-Host ("  {0,-6} {1,-32} HELD by '{2}' (PID {3})" -f $row.Port, $row.Role, $row.Owner, $row.Pid) -ForegroundColor Yellow
    }
    else {
        Write-Host ("  {0,-6} {1,-32} free" -f $row.Port, $row.Role) -ForegroundColor Green
    }
}

$gpu = Get-GpuReport
Section '[GPU] adapter / driver + best-effort per-process memory'
if ($gpu.Adapters.Count -gt 0) {
    foreach ($a in $gpu.Adapters) { Write-Host ("  {0}  (driver {1})" -f $a.Name, $a.Driver) }
}
else {
    Write-Host '  no display adapter enumerated.' -ForegroundColor DarkGray
}
if ($null -eq $gpu.ProcMem) {
    Write-Host '  per-process GPU memory: not cheaply enumerable on this host (GPU counters unavailable).' -ForegroundColor DarkGray
}
elseif ($gpu.ProcMem.Count -eq 0) {
    Write-Host '  per-process GPU memory: no process holds local GPU memory.' -ForegroundColor DarkGray
}
else {
    foreach ($g in $gpu.ProcMem) { Write-Host ("  {0,-18} PID {1,-8} {2} MiB (local GPU mem)" -f $g.Name, $g.Pid, $g.MiB) }
}

$proc = Get-ProcReport
Section '[PROC] python / pythonw / node / opencode inventory (command lines)'
if ($proc.Count -eq 0) {
    Write-Host '  none.' -ForegroundColor Green
}
else {
    foreach ($row in $proc) {
        Write-Host ("  PID {0,-8} {1,-13} {2,6} MiB  {3}" -f $row.Pid, $row.Name, $row.WsMiB, $row.Cmd)
    }
}

$mem = Get-MemReport
Section '[RAM] physical memory vs the lean band'
if (-not $mem.Ok) {
    Write-Host "  QUERY FAILED: $($mem.Error)" -ForegroundColor Red
}
else {
    $col = if ($mem.AvailableGiB -lt $MinLeanAvailableGiB) { 'Red' } elseif ($mem.UsedGiB -gt 26) { 'Yellow' } else { 'Green' }
    Write-Host ("  {0} GiB used of {1} GiB  ({2} GiB available; lean floor {3} GiB)" -f $mem.UsedGiB, $mem.TotalGiB, $mem.AvailableGiB, $MinLeanAvailableGiB) -ForegroundColor $col
}

$tasks = Get-TaskReport -TaskPath $TaskPath
Section "[TASK] scheduled tasks under $TaskPath"
if ($tasks.Count -eq 0) {
    Write-Host '  none registered (or folder absent).' -ForegroundColor DarkGray
}
else {
    foreach ($t in $tasks) {
        $col = if ($t.State -eq 'Running') { 'Yellow' } else { 'Gray' }
        $res = if ($null -ne $t.LastResult) { ('0x{0:X}' -f [int]$t.LastResult) } else { 'n/a' }
        Write-Host ("  {0,-34} {1,-10} last={2}  run={3}" -f $t.Name, $t.State, $res, $t.LastRun) -ForegroundColor $col
    }
}

# ---------------------------------------------------------------------------
# Baseline verdict - the ONLY path that can exit non-zero. Default mode never
# reaches this block and falls through to the unconditional exit 0 below.
# ---------------------------------------------------------------------------

if ($Baseline -eq 'lean') {
    # D1 - any VM Running, OR Get-VM unqueryable (fail-closed: cannot prove no VM).
    if (-not $vm.Ok) {
        Add-Deviation "VM state UNKNOWN - Get-VM failed ($($vm.Error)); cannot prove no guest is running (fail-closed)"
    }
    elseif ($vm.Running.Count -gt 0) {
        Add-Deviation "VM(s) Running: $($vm.Running -join ', ')"
    }
    # D2 - AO resident (live launcher, or :5001 held).
    if ($ao.Live) {
        Add-Deviation "AO resident - live '-m launcher' (PID $($ao.LockPid)) holding the 14B"
    }
    elseif ($ao.PortHeld) {
        Add-Deviation "AO port :5001 held by '$($ao.PortOwner)' (PID $($ao.PortPid))"
    }
    # D3 - OVMS model server resident (process, or :8000 held).
    $p8000 = @($portRows | Where-Object { $_.Port -eq 8000 -and $_.Held }) | Select-Object -First 1
    if ($model.Running) {
        Add-Deviation "OVMS model server resident (ovms.exe PID $($model.Pid))"
    }
    elseif ($p8000) {
        Add-Deviation "model-server port :8000 held by '$($p8000.Owner)' (PID $($p8000.Pid))"
    }
    # D4 - RAM below the lean band, OR memory unqueryable (fail-closed).
    if (-not $mem.Ok) {
        Add-Deviation "RAM state UNKNOWN - memory probe failed ($($mem.Error)); cannot prove lean (fail-closed)"
    }
    elseif ($mem.AvailableGiB -lt $MinLeanAvailableGiB) {
        Add-Deviation "available RAM $($mem.AvailableGiB) GiB below lean band $MinLeanAvailableGiB GiB"
    }

    Section '[BASELINE] lean verdict'
    if ($script:Deviations.Count -eq 0) {
        Write-Host "LEAN: PASS - box is idle / model-free (0 deviations)." -ForegroundColor Green
        Write-Host '=============================================' -ForegroundColor Cyan
        exit 0
    }
    else {
        Write-Host "LEAN: FAIL - $($script:Deviations.Count) deviation(s) from an idle / model-free box:" -ForegroundColor Red
        foreach ($d in $script:Deviations) { Write-Host "  - $d" -ForegroundColor Red }
        Write-Host '=============================================' -ForegroundColor Cyan
        exit 1
    }
}

Write-Host '=============================================' -ForegroundColor Cyan
# Default read-only mode: ALWAYS exit 0 (a report never fails the caller).
exit 0
