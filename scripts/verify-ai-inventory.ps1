#requires -Version 7.0
<#
.SYNOPSIS
  Verify ai-inventory-lib.ps1: the ONE shared "what AI models are in RAM"
  detection behind the panel header, [V] refresh, [6] full status and the
  stop-all kill switch's plan/verify passes.

.DESCRIPTION
  Two layers, both offline (never the real assistant / OVMS / GPU / VM):

  STRUCTURE (AST + static, deterministic):
    A1  the lib parses clean under BOTH engines' parsers (the panel's .cmd
        falls back to Windows PowerShell 5.1) and is ASCII-only (spawn-lib
        convention: 5.1 reads UTF-8-no-BOM as cp1252).
    A2  the lib is READ-ONLY: no process-killing / file-writing / spawning
        command anywhere in it (the shared detection can never grow a side
        effect).
    A3  the assistant confirmation is the proven pair: launcher.lock + the
        '-m launcher' cmdline marker (mirrors stop-assistant.ps1 /
        instance_lock.py).
    A4  the blind-spot honesty lines name the in-process models (Whisper,
        SDXL, VLM, embedder/NPU), the GPU/NPU shared-RAM caveat and the VM
        opacity - and both renderers PRINT the gaps they cannot see.
    A5  control-panel.ps1 dot-sources the lib and renders the header from
        Get-AiModelInventory / Write-AiInventoryHeader; its old private
        :8000-only probe is GONE (the "No model loaded" lie's root cause).
    A6  ai-status.ps1 dot-sources the lib and renders via
        Write-AiInventoryReport.

  BEHAVIOR (live FIXTURE processes only):
    B1  a confirmed '-m launcher' decoy LISTENING on the probe port ->
        State 'running', PortServing, tree includes the grandchild, pids
        excluded from OtherLarge.
    B2  the same decoy probed on a DIFFERENT (quiet) port ->
        'starting-or-wedged'.
    B3  a dead pid in the lock -> 'not-running' (stale named).
    B4  no lock but the port is HELD by a non-launcher -> 'port-conflict'
        naming the holder pid.
    B5  OVMS by decoy process name: absent -> 'not-running'; present with a
        dead API -> 'not-answering' with its pid.
    B6  a plain python decoy shows up in OtherLarge at a tiny threshold.
    B7  WatchdogArmed tracks the server-should-run sentinel.
    B8  (when powershell.exe exists) the lib loads and runs under 5.1.
    B9  ELEVATION SHAPE (#1164, via injected table): the lock pid's row has a
        NULL CommandLine (what non-elevated WMI returns for an elevated
        process) but the pid OWNS the probe port -> identified 'running' with
        the lock+port-agreement caveat, tree still excluded from OtherLarge.
    B10 same null-cmdline row, port QUIET -> NOT identified; the detail names
        the unreadable command line and says to run the panel elevated.
    B11 the provably-foreign gate tested OFF (real WMI, no injection): a live
        marker-less decoy's pid planted in the lock -> port-conflict with the
        port (never identified), honest stale on a quiet port.

  Run it normally ( .\verify-ai-inventory.ps1 ) - do NOT dot-source it.
  Exit 0 iff every check passes.
#>
param()
$ErrorActionPreference = 'Stop'

$script:Pass = 0
$script:Fail = 0
function Check([string]$name, [bool]$ok) {
    if ($ok) { $script:Pass++; Write-Host "  [PASS] $name" -ForegroundColor Green }
    else     { $script:Fail++; Write-Host "  [FAIL] $name" -ForegroundColor Red }
}
function Section($t) { Write-Host ''; Write-Host "== $t ==" -ForegroundColor Cyan }

$lib    = Join-Path $PSScriptRoot 'ai-inventory-lib.ps1'
$panel  = Join-Path $PSScriptRoot 'control-panel.ps1'
$status = Join-Path $PSScriptRoot 'ai-status.ps1'
Check "ai-inventory-lib.ps1 exists" (Test-Path $lib)
Check "control-panel.ps1 exists" (Test-Path $panel)
Check "ai-status.ps1 exists" (Test-Path $status)

# ===========================================================================
# STRUCTURE
# ===========================================================================
Section 'A1  parses clean + ASCII-only'
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($lib, [ref]$null, [ref]$parseErrors)
Check "A1 lib parses with 0 errors (pwsh parser)" ($parseErrors.Count -eq 0)
$bytes = [System.IO.File]::ReadAllBytes($lib)
$nonAscii = @($bytes | Where-Object { $_ -gt 127 })
Check "A1 lib source is ASCII-only ($($nonAscii.Count) high bytes)" ($nonAscii.Count -eq 0)

Section 'A2  the lib is read-only'
$allCmds = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)
$sideEffecting = @('Stop-Process', 'Stop-ProcessTree', 'taskkill', 'taskkill.exe', 'Remove-Item',
                   'Set-Content', 'Add-Content', 'New-Item', 'Start-Process', 'Stop-VM', 'Start-VM',
                   'Move-Item', 'Copy-Item', 'Out-File', 'Stop-Service', 'Restart-Service')
$bad = @($allCmds | Where-Object { $_.GetCommandName() -in $sideEffecting })
Check "A2 no side-effecting command in the lib (found: $(@($bad | ForEach-Object { $_.GetCommandName() }) -join ','))" ($bad.Count -eq 0)

Section 'A3  proven assistant confirmation'
$libSrc = Get-Content $lib -Raw
Check "A3 reads the launcher single-instance lock (certs\launcher.lock)" ($libSrc -match 'launcher\.lock')
Check "A3 confirms the '-m launcher' cmdline marker" ($libSrc -match '-m launcher')

Section 'A4  fail-loud honesty about the gaps'
Check "A4 blind lines name Whisper" ($libSrc -match 'Whisper')
Check "A4 blind lines name SDXL" ($libSrc -match 'SDXL')
Check "A4 blind lines name the embedder + NPU" ($libSrc -match 'embedder' -and $libSrc -match 'NPU')
Check "A4 blind lines name the VM opacity" ($libSrc -match 'inside a running VM')
Check "A4 header renderer prints the cannot-see note" ($libSrc -match 'load INSIDE the assistant')
Check "A4 report renderer prints NOT VISIBLE" ($libSrc -match 'NOT VISIBLE from outside')

Section 'A5  control-panel.ps1 consumes the shared truth'
$panelSrc = Get-Content $panel -Raw
Check "A5 panel dot-sources ai-inventory-lib.ps1" ($panelSrc -match 'ai-inventory-lib\.ps1')
Check "A5 panel calls Get-AiModelInventory" ($panelSrc -match 'Get-AiModelInventory')
Check "A5 panel renders via Write-AiInventoryHeader" ($panelSrc -match 'Write-AiInventoryHeader')
Check "A5 panel's old private :8000 probe is gone (no v3/models literal)" (-not ($panelSrc -match 'v3/models'))
Check "A5 panel no longer defines Get-LoadedModel" (-not ($panelSrc -match 'function Get-LoadedModel'))

Section 'A6  ai-status.ps1 consumes the shared truth'
$statusSrc = Get-Content $status -Raw
Check "A6 status dot-sources ai-inventory-lib.ps1" ($statusSrc -match 'ai-inventory-lib\.ps1')
Check "A6 status renders via Write-AiInventoryReport" ($statusSrc -match 'Write-AiInventoryReport')

# ===========================================================================
# BEHAVIOR - fixtures only
# ===========================================================================
Section 'B1-B8  fixture behavior'

function Get-TestPython {
    $candidates = @(
        'C:\Users\mrbla\blarai\.venv\Scripts\python.exe',
        (Get-Command python -ErrorAction SilentlyContinue).Source
    ) | Where-Object { $_ -and (Test-Path $_) }
    if (-not $candidates) { throw 'no python.exe found for the behavior suite' }
    return $candidates[0]
}
function Wait-ForFile([string]$Path, [int]$TimeoutSec = 12) {
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if ((Test-Path $Path) -and (Get-Item $Path).Length -gt 0) { return (Get-Content $Path -Raw).Trim() }
        Start-Sleep -Milliseconds 100
    }
    return ''
}

. $lib   # the functions under test

$py   = Get-TestPython
$work = Join-Path ([System.IO.Path]::GetTempPath()) ('ai-inventory-verify-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $work | Out-Null

# Decoy: spawns a grandchild, optionally LISTENS on LISTEN_PORT, writes READY_FILE,
# then sleeps. Trailing '-m launcher' args make it a valid cmdline-marker decoy.
$fixture = Join-Path $work 'fixture.py'
Set-Content -Path $fixture -Encoding utf8 -Value @'
import os, socket, subprocess, sys, time
gc = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(300)'])
f = os.environ.get('GC_PID_FILE')
if f:
    open(f, 'w').write(str(gc.pid))
port = int(os.environ.get('LISTEN_PORT', '0'))
if port:
    s = socket.socket()
    s.bind(('127.0.0.1', port))
    s.listen(1)
rf = os.environ.get('READY_FILE')
if rf:
    open(rf, 'w').write('ready')
time.sleep(300)
'@

$spawned = New-Object System.Collections.ArrayList
function Start-Fixture([switch]$WithMarker, [string]$GcPidFile, [int]$ListenPort = 0, [string]$ReadyFile = '') {
    $tag = [guid]::NewGuid().ToString('N').Substring(0, 6)
    $inEmpty = Join-Path $work "in-$tag"; Set-Content -Path $inEmpty -Value '' -NoNewline -Encoding ascii
    $out = "$inEmpty.out"; $err = "$inEmpty.err"
    $argv = @($fixture)
    if ($WithMarker) { $argv += @('-m', 'launcher') }
    $prevGc = $env:GC_PID_FILE; $prevLp = $env:LISTEN_PORT; $prevRf = $env:READY_FILE
    $env:GC_PID_FILE = $GcPidFile
    $env:LISTEN_PORT = "$ListenPort"
    $env:READY_FILE  = $ReadyFile
    try {
        $p = Start-Process -FilePath $py -ArgumentList $argv -WorkingDirectory $work `
                -RedirectStandardInput $inEmpty -RedirectStandardOutput $out -RedirectStandardError $err `
                -NoNewWindow -PassThru
        $null = $p.Handle
    } finally {
        if ($null -eq $prevGc) { Remove-Item Env:\GC_PID_FILE -ErrorAction SilentlyContinue } else { $env:GC_PID_FILE = $prevGc }
        if ($null -eq $prevLp) { Remove-Item Env:\LISTEN_PORT -ErrorAction SilentlyContinue } else { $env:LISTEN_PORT = $prevLp }
        if ($null -eq $prevRf) { Remove-Item Env:\READY_FILE -ErrorAction SilentlyContinue } else { $env:READY_FILE = $prevRf }
    }
    [void]$spawned.Add($p.Id)
    return $p
}
function New-FixtureRoot {
    $root = Join-Path $work ('root-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
    New-Item -ItemType Directory -Force -Path (Join-Path $root 'certs') | Out-Null
    return $root
}
function Set-LockPid([string]$Root, [int]$LockPid) {
    Set-Content -Path (Join-Path $Root 'certs\launcher.lock') -Value $LockPid -NoNewline -Encoding ascii
}
function Get-FreePort {
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $p = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
    $listener.Stop()
    return $p
}
# Every inventory call below points OVMS/state params at inert fixtures so the
# REAL box state can never leak into an assertion.
$deadOvmsName = 'no-such-ovms-' + [guid]::NewGuid().ToString('N').Substring(0, 6)
$fixtureState = Join-Path $work 'state'
New-Item -ItemType Directory -Force -Path $fixtureState | Out-Null
function Invoke-Inventory([string]$Root, [int]$Port, [string]$OvmsName = $deadOvmsName, [double]$MinGb = 999.0, [object[]]$Table = $null) {
    return Get-AiModelInventory -BlarAiRepo $Root -AoPort $Port `
        -OvmsProcessName $OvmsName -OvmsApiBase ('http://127.0.0.1:{0}' -f (Get-FreePort)) `
        -OtherLargeMinGb $MinGb -IncludeVm:$false -StateDir $fixtureState -ProcessTable $Table
}
function Get-NullCmdlineTable([int]$TargetPid) {
    # The elevated-process shape, synthesized: the real table with the target
    # row's CommandLine nulled (pid/name/parent/RSS stay visible - exactly what
    # non-elevated WMI shows for an elevated process).
    $synth = @()
    foreach ($row in (Get-AiProcessTable)) {
        if ([int]$row.ProcessId -eq $TargetPid) {
            $synth += [pscustomobject]@{
                ProcessId = $row.ProcessId; ParentProcessId = $row.ParentProcessId
                Name = $row.Name; CommandLine = $null; WorkingSetSize = $row.WorkingSetSize
            }
        } else { $synth += $row }
    }
    return $synth
}

try {
    # --- B1: confirmed launcher, listening -> running ------------------------
    Write-Host "`nB1 - confirmed '-m launcher' decoy listening on the probe port" -ForegroundColor Yellow
    $root1 = New-FixtureRoot
    $port1 = Get-FreePort
    $gcF   = Join-Path $work 'gc1.pid'
    $rdyF  = Join-Path $work 'rdy1.txt'
    $fix1  = Start-Fixture -WithMarker -GcPidFile $gcF -ListenPort $port1 -ReadyFile $rdyF
    $gcTxt = Wait-ForFile $gcF
    $rdy   = Wait-ForFile $rdyF
    Check "B1 decoy up (grandchild registered, listener ready)" ($gcTxt -ne '' -and $rdy -eq 'ready')
    Set-LockPid $root1 $fix1.Id
    $inv1 = Invoke-Inventory $root1 $port1 $deadOvmsName 0.001
    Check "B1 Assistant.State = running (got '$($inv1.Assistant.State)')" ($inv1.Assistant.State -eq 'running')
    Check "B1 Assistant.Pid = decoy pid" ($inv1.Assistant.Pid -eq $fix1.Id)
    Check "B1 PortServing" ($inv1.Assistant.PortServing)
    Check "B1 tree contains the grandchild" ($gcTxt -ne '' -and ($inv1.Assistant.TreePids -contains [int]$gcTxt))
    Check "B1 TreeRssGb is a number >= 0" ($inv1.Assistant.TreeRssGb -ge 0)
    $treeInOther = @($inv1.OtherLarge | Where-Object { $inv1.Assistant.TreePids -contains $_.Pid })
    Check "B1 assistant tree pids EXCLUDED from OtherLarge" ($treeInOther.Count -eq 0)

    # --- B2: same decoy, quiet probe port -> starting-or-wedged --------------
    Write-Host "`nB2 - confirmed decoy probed on a QUIET port" -ForegroundColor Yellow
    $quiet = Get-FreePort
    $inv2 = Invoke-Inventory $root1 $quiet
    Check "B2 State = starting-or-wedged (got '$($inv2.Assistant.State)')" ($inv2.Assistant.State -eq 'starting-or-wedged')
    Check "B2 detail says NOT serving" ($inv2.Assistant.Detail -match 'NOT serving')

    # --- B3: dead pid in the lock -> not-running (stale) ---------------------
    Write-Host "`nB3 - dead pid in the lock" -ForegroundColor Yellow
    $throw = Start-Process -FilePath $py -ArgumentList @('-c', 'pass') -NoNewWindow -PassThru
    $null = $throw.Handle; $throw.WaitForExit(5000) | Out-Null
    $root3 = New-FixtureRoot; Set-LockPid $root3 $throw.Id
    $inv3 = Invoke-Inventory $root3 (Get-FreePort)
    Check "B3 State = not-running (got '$($inv3.Assistant.State)')" ($inv3.Assistant.State -eq 'not-running')
    Check "B3 detail names the stale lock" ($inv3.Assistant.Detail -match 'stale')

    # --- B4: no lock, port held by a NON-launcher -> port-conflict -----------
    Write-Host "`nB4 - port held by a non-launcher, no lock" -ForegroundColor Yellow
    $port4 = Get-FreePort
    $rdy4  = Join-Path $work 'rdy4.txt'
    $fix4  = Start-Fixture -GcPidFile (Join-Path $work 'gc4.pid') -ListenPort $port4 -ReadyFile $rdy4   # NO marker
    $null  = Wait-ForFile $rdy4
    $root4 = New-FixtureRoot   # certs/ exists, no lock file
    $inv4 = Invoke-Inventory $root4 $port4
    Check "B4 State = port-conflict (got '$($inv4.Assistant.State)')" ($inv4.Assistant.State -eq 'port-conflict')
    # The venv python.exe is a SHIM that re-spawns the real interpreter as a
    # child (spawn-lib R1), so the socket owner may be a DESCENDANT of the
    # decoy - assert the named pid is in the decoy's tree, not equal to it.
    $tree4 = @(Get-AiProcessTreePids -RootPid $fix4.Id -Table (Get-AiProcessTable))
    $m4 = [regex]::Match($inv4.Assistant.Detail, 'pid (\d+)')
    Check "B4 detail names the holder pid (within the decoy tree)" ($m4.Success -and ($tree4 -contains [int]$m4.Groups[1].Value))

    # --- B5: OVMS decoy name -------------------------------------------------
    Write-Host "`nB5 - OVMS decoy process name" -ForegroundColor Yellow
    $inv5a = Invoke-Inventory $root4 (Get-FreePort)
    Check "B5 absent name -> not-running (got '$($inv5a.Ovms.State)')" ($inv5a.Ovms.State -eq 'not-running')
    $decoyName = 'ovmsdecoy' + [guid]::NewGuid().ToString('N').Substring(0, 6)
    $decoyExe  = Join-Path $work ($decoyName + '.exe')
    Copy-Item (Join-Path $env:SystemRoot 'System32\cmd.exe') $decoyExe
    $ovmsFix = Start-Process -FilePath $decoyExe -ArgumentList '/d', '/c', 'ping -n 300 127.0.0.1 >nul' -WindowStyle Hidden -PassThru
    $null = $ovmsFix.Handle
    [void]$spawned.Add($ovmsFix.Id)
    Start-Sleep -Milliseconds 500
    $inv5b = Invoke-Inventory $root4 (Get-FreePort) $decoyName
    Check "B5 present + dead API -> not-answering (got '$($inv5b.Ovms.State)')" ($inv5b.Ovms.State -eq 'not-answering')
    Check "B5 reports the decoy pid" ($inv5b.Ovms.Pids -contains $ovmsFix.Id)

    # --- B6: OtherLarge picks up a plain python decoy ------------------------
    Write-Host "`nB6 - OtherLarge at a tiny threshold" -ForegroundColor Yellow
    $inv6 = Invoke-Inventory $root3 (Get-FreePort) $deadOvmsName 0.001
    $mine = @($inv6.OtherLarge | Where-Object { $_.Pid -eq $fix4.Id })
    Check "B6 the plain python decoy appears in OtherLarge" ($mine.Count -eq 1)
    Check "B6 with a RssGb figure >= 0" ($mine.Count -eq 1 -and $mine[0].RssGb -ge 0)

    # --- B7: watchdog sentinel ----------------------------------------------
    Write-Host "`nB7 - watchdog sentinel tracking" -ForegroundColor Yellow
    $inv7a = Invoke-Inventory $root3 (Get-FreePort)
    Check "B7 no sentinel -> not armed" (-not $inv7a.WatchdogArmed)
    Set-Content -Path (Join-Path $fixtureState 'server-should-run.txt') -Value 'qwen3-14b' -Encoding ascii
    $inv7b = Invoke-Inventory $root3 (Get-FreePort)
    Check "B7 sentinel present -> armed" ($inv7b.WatchdogArmed)
    Remove-Item (Join-Path $fixtureState 'server-should-run.txt') -ErrorAction SilentlyContinue

    # --- B8: Windows PowerShell 5.1 smoke ------------------------------------
    Write-Host "`nB8 - 5.1 compatibility smoke" -ForegroundColor Yellow
    $ps51 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (Test-Path $ps51) {
        $smoke = ". '$lib'; `$i = Get-AiModelInventory -BlarAiRepo '$root3' -AoPort $(Get-FreePort) " +
                 "-OvmsProcessName '$deadOvmsName' -OvmsApiBase 'http://127.0.0.1:$(Get-FreePort)' " +
                 "-OtherLargeMinGb 999 -IncludeVm:`$false -StateDir '$fixtureState'; " +
                 "if (`$i.Assistant.State -eq 'not-running') { exit 0 } else { exit 1 }"
        & $ps51 -NoProfile -NonInteractive -Command $smoke *> $null
        Check "B8 lib loads + runs under Windows PowerShell 5.1" ($LASTEXITCODE -eq 0)
    } else {
        Check "B8 powershell.exe not present - skipped as pass (pwsh-only box)" $true
    }

    # --- B9: elevated shape - null cmdline BUT lock+port agree -> running -----
    Write-Host "`nB9 - null CommandLine (elevated shape) with lock+port agreement" -ForegroundColor Yellow
    $synth9 = Get-NullCmdlineTable -TargetPid $fix1.Id
    $inv9 = Invoke-Inventory $root1 $port1 $deadOvmsName 0.001 $synth9
    Check "B9 State = running (got '$($inv9.Assistant.State)')" ($inv9.Assistant.State -eq 'running')
    Check "B9 Pid = decoy pid" ($inv9.Assistant.Pid -eq $fix1.Id)
    Check "B9 detail carries the lock+port-agreement caveat" ($inv9.Assistant.Detail -like '*lock+port agreement*')
    Check "B9 detail says run the panel elevated" ($inv9.Assistant.Detail -like '*elevated*')
    $tree9 = @($inv9.OtherLarge | Where-Object { $inv9.Assistant.TreePids -contains $_.Pid })
    Check "B9 assistant tree still EXCLUDED from OtherLarge" ($tree9.Count -eq 0)

    # --- B10: null cmdline, port QUIET -> honest non-identification -----------
    Write-Host "`nB10 - null CommandLine, quiet port" -ForegroundColor Yellow
    $inv10 = Invoke-Inventory $root1 (Get-FreePort) $deadOvmsName 999.0 $synth9
    Check "B10 State = not-running (got '$($inv10.Assistant.State)')" ($inv10.Assistant.State -eq 'not-running')
    Check "B10 detail names the unreadable command line" ($inv10.Assistant.Detail -like '*unreadable*')
    Check "B10 detail says run the panel elevated" ($inv10.Assistant.Detail -like '*elevated*')

    # --- B11: provably-foreign gate (review fc762f5 MED-1) --------------------
    # The invariant the design comment stakes: a READABLE cmdline WITHOUT the
    # '-m launcher' marker (recycled lock pid) is NEVER identified - port
    # agreement or not. B9/B10 cover only the null-cmdline arms; this is the
    # control tested OFF for the readable arm.
    Write-Host "`nB11 - recycled lock pid (readable marker-less cmdline) never identified" -ForegroundColor Yellow
    $root11 = New-FixtureRoot
    Set-LockPid $root11 $fix4.Id      # B4's NO-marker decoy, still alive + holding port4
    $inv11 = Invoke-Inventory $root11 $port4
    Check "B11 with the port: State = port-conflict, NOT running (got '$($inv11.Assistant.State)')" ($inv11.Assistant.State -eq 'port-conflict')
    Check "B11 conflict detail says investigate, never identifies" ($inv11.Assistant.Detail -like '*NOT the recorded assistant*')
    $inv11q = Invoke-Inventory $root11 (Get-FreePort)
    Check "B11 quiet port: honest stale, NOT the elevated caveat (got '$($inv11q.Assistant.State)')" ($inv11q.Assistant.State -eq 'not-running' -and $inv11q.Assistant.Detail -like '*stale*')
}
finally {
    foreach ($id in $spawned) { try { & taskkill.exe /T /F /PID $id *> $null } catch {} }
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($script:Fail -eq 0) {
    Write-Host "RESULT: $($script:Pass) passed, 0 failed" -ForegroundColor Green
    exit 0
} else {
    Write-Host "RESULT: $($script:Pass) passed, $($script:Fail) failed" -ForegroundColor Red
    exit 1
}
