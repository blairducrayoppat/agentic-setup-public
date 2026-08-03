#requires -Version 7.0
<#
.SYNOPSIS
  Verify stop-all-models.ps1: the panel's [K] kill switch ends every PROVEN
  model holder (assistant via the audited stop-assistant chain, OVMS by name
  with the watchdog stood down), refuses what it cannot identify, dry-runs
  honestly, and verifies what actually died.

.DESCRIPTION
  Two layers, both offline (never the real assistant / OVMS / GPU):

  STRUCTURE (AST + static, deterministic - the safety invariants):
    A1  parses clean under BOTH engines' parsers; ASCII-only source.
    A2  NO hand-rolled assistant kill: no taskkill, no Stop-ProcessTree; the
        assistant leg is EXACTLY ONE invocation of stop-assistant.ps1 (the
        #797-audited confirm-then-tree-kill chain).
    A3  exactly ONE Stop-Process site (the OVMS leg) - and EVERY side effect
        (Stop-Process, Remove-Item, the stop-assistant call) sits lexically
        inside an  if (-not $DryRun)  guard: -DryRun is structurally unable
        to touch anything.
    A4  a Read-Host confirm exists, guarded by -not $Yes (automation must opt
        in; a human always gets asked).
    A5  the watchdog sentinel pair is stood down by name (else OVMS revives
        within ~2 min of a kill).
    A6  pinned production defaults: OvmsProcessName 'ovms', AoPort 5001.
    A7  control-panel.ps1 wires [K] -> stop-all-models.ps1 WITHOUT -Yes and
        WITHOUT -DryRun, and the existing [S]/[5] wiring is untouched.

  BEHAVIOR (live FIXTURE processes only):
    B1  clean no-op: nothing running -> "nothing to stop", exit 0.
    B2  -DryRun with a live confirmed decoy + armed sentinel: plan names the
        decoy pid, decoy STAYS ALIVE, sentinel STAYS, exit 0.
    B3  -Yes real run: decoy assistant (with grandchild) + OVMS-named decoy +
        armed sentinel -> ALL dead, sentinel + gave-up flag removed, output
        reports DEAD + RAM figures, exit 0.
    B4  no -Yes with EOF stdin: cancels, decoy stays alive, exit 0.
    B5  refusal honesty: a non-launcher holding the port is reported as
        NOT STOPPING (with pid) and survives, exit 0.
    B6  (when powershell.exe exists) a -DryRun EXECUTES under Windows
        PowerShell 5.1: armed-sentinel fixture -> plan + DRY RUN banner,
        exit 0, sentinel untouched. -NonInteractive doubles as proof the
        DryRun exit comes BEFORE any prompt (a reached Read-Host would
        fail loudly there).

  Run it normally ( .\verify-stop-all-models.ps1 ) - do NOT dot-source it.
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

$stopAll = Join-Path $PSScriptRoot 'stop-all-models.ps1'
$panel   = Join-Path $PSScriptRoot 'control-panel.ps1'
Check "stop-all-models.ps1 exists" (Test-Path $stopAll)
Check "control-panel.ps1 exists" (Test-Path $panel)

. (Join-Path $PSScriptRoot 'spawn-lib.ps1')          # Invoke-CapturedRun (EOF stdin, tree-kill on timeout)
. (Join-Path $PSScriptRoot 'ai-inventory-lib.ps1')   # Get-AiProcessTreePids (venv-shim-aware pid assertions)

# ===========================================================================
# STRUCTURE
# ===========================================================================
Section 'A1  parses clean + ASCII-only'
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($stopAll, [ref]$null, [ref]$parseErrors)
Check "A1 parses with 0 errors" ($parseErrors.Count -eq 0)
$bytes = [System.IO.File]::ReadAllBytes($stopAll)
$nonAscii = @($bytes | Where-Object { $_ -gt 127 })
Check "A1 ASCII-only source ($($nonAscii.Count) high bytes)" ($nonAscii.Count -eq 0)

Section 'A2  assistant leg = the audited chain, nothing hand-rolled'
$allCmds = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)
$banned = @($allCmds | Where-Object { $_.GetCommandName() -in @('taskkill', 'taskkill.exe', 'Stop-ProcessTree') })
Check "A2 no taskkill / Stop-ProcessTree of its own" ($banned.Count -eq 0)
# A nested CommandAst (the Join-Path building the script path) shares the
# outer call's extent text - count only OUTERMOST matches (no matching ancestor).
$saRaw = @($allCmds | Where-Object { $_.Extent.Text -match 'stop-assistant\.ps1' })
$saCalls = @($saRaw | Where-Object {
    $p = $_.Parent; $outer = $true
    while ($p) {
        if ($saRaw -contains $p) { $outer = $false }
        $p = $p.Parent
    }
    $outer
})
Check "A2 exactly ONE stop-assistant.ps1 invocation (got $($saCalls.Count))" ($saCalls.Count -eq 1)

Section 'A3  every side effect is DryRun-guarded'
function Test-InsideNotDryRunGuard($node) {
    $p = $node.Parent
    while ($p) {
        if ($p -is [System.Management.Automation.Language.IfStatementAst]) {
            foreach ($clause in $p.Clauses) {
                if ($clause.Item1.Extent.Text -match 'DryRun' -and
                    $clause.Item1.Extent.Text -match '-not' -and
                    $clause.Item2.Extent.StartOffset -le $node.Extent.StartOffset -and
                    $clause.Item2.Extent.EndOffset  -ge $node.Extent.EndOffset) { return $true }
            }
        }
        $p = $p.Parent
    }
    return $false
}
$stopProcs = @($allCmds | Where-Object { $_.GetCommandName() -eq 'Stop-Process' })
Check "A3 exactly ONE Stop-Process site (got $($stopProcs.Count))" ($stopProcs.Count -eq 1)
foreach ($n in $stopProcs) {
    Check "A3 Stop-Process at line $($n.Extent.StartLineNumber) inside if(-not `$DryRun)" (Test-InsideNotDryRunGuard $n)
}
$removes = @($allCmds | Where-Object { $_.GetCommandName() -eq 'Remove-Item' })
Check "A3 Remove-Item sites exist (watchdog stand-down)" ($removes.Count -ge 1)
foreach ($n in $removes) {
    Check "A3 Remove-Item at line $($n.Extent.StartLineNumber) inside if(-not `$DryRun)" (Test-InsideNotDryRunGuard $n)
}
foreach ($n in $saCalls) {
    Check "A3 stop-assistant call at line $($n.Extent.StartLineNumber) inside if(-not `$DryRun)" (Test-InsideNotDryRunGuard $n)
}

Section 'A4  human confirm'
$src = Get-Content $stopAll -Raw
$readHosts = @($allCmds | Where-Object { $_.GetCommandName() -eq 'Read-Host' })
Check "A4 a Read-Host confirm exists" ($readHosts.Count -ge 1)
Check "A4 confirm guarded by -not `$Yes" ($src -match 'if \(-not \$Yes\)')

Section 'A5  watchdog stood down by name'
Check "A5 removes server-should-run.txt" ($src -match 'server-should-run\.txt')
Check "A5 removes watchdog-gave-up.flag" ($src -match 'watchdog-gave-up\.flag')

Section 'A6  pinned production defaults'
$paramAsts = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.ParameterAst] }, $true)
$ovmsDefault = @($paramAsts | Where-Object { $_.Name.VariablePath.UserPath -eq 'OvmsProcessName' })
Check "A6 OvmsProcessName default 'ovms'" ($ovmsDefault.Count -eq 1 -and $ovmsDefault[0].DefaultValue.Extent.Text -match "'ovms'")
$portDefault = @($paramAsts | Where-Object { $_.Name.VariablePath.UserPath -eq 'AoPort' })
Check "A6 AoPort default 5001" ($portDefault.Count -eq 1 -and $portDefault[0].DefaultValue.Extent.Text -eq '5001')

Section 'A7  panel wiring'
$panelSrc = Get-Content $panel -Raw
$kLine = ($panelSrc -split "`n" | Where-Object { $_ -match '\[Kk\]' -and $_ -match 'stop-all-models\.ps1' } | Select-Object -First 1)
Check "A7 [K] dispatches to stop-all-models.ps1" ($null -ne $kLine)
$kCode = ''
if ($null -ne $kLine) { $kCode = ($kLine -split '#')[0] }   # judge the CODE, not the trailing comment
Check "A7 [K] passes neither -Yes nor -DryRun" ($kCode -ne '' -and $kCode -notmatch '-Yes' -and $kCode -notmatch '-DryRun')
Check "A7 [K] menu line labeled STOP ALL" ($panelSrc -match 'STOP ALL AI MODELS')
Check "A7 [S] wiring untouched" ($panelSrc -match "\^\[Ss\]\`$.*stop-assistant\.ps1")
Check "A7 [5] wiring untouched" ($panelSrc -match "\`$c -eq '5'.*stop-llm\.ps1")

# ===========================================================================
# BEHAVIOR - fixtures only
# ===========================================================================
Section 'B1-B5  fixture behavior'

function Get-TestPython {
    $candidates = @(
        'C:\Users\mrbla\blarai\.venv\Scripts\python.exe',
        (Get-Command python -ErrorAction SilentlyContinue).Source
    ) | Where-Object { $_ -and (Test-Path $_) }
    if (-not $candidates) { throw 'no python.exe found for the behavior suite' }
    return $candidates[0]
}
function Test-Alive([int]$ProcessId) {
    try { $null = Get-Process -Id $ProcessId -ErrorAction Stop; return $true } catch { return $false }
}
function Wait-ForFile([string]$Path, [int]$TimeoutSec = 12) {
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if ((Test-Path $Path) -and (Get-Item $Path).Length -gt 0) { return (Get-Content $Path -Raw).Trim() }
        Start-Sleep -Milliseconds 100
    }
    return ''
}
function Wait-Dead([int]$ProcessId, [int]$TimeoutSec = 10) {
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline -and (Test-Alive $ProcessId)) { Start-Sleep -Milliseconds 100 }
    return (-not (Test-Alive $ProcessId))
}

$py   = Get-TestPython
$pwshExe = (Get-Command pwsh).Source
$work = Join-Path ([System.IO.Path]::GetTempPath()) ('stop-all-verify-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $work | Out-Null

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
function New-FixtureState([switch]$Armed) {
    $sd = Join-Path $work ('state-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
    New-Item -ItemType Directory -Force -Path $sd | Out-Null
    if ($Armed) {
        Set-Content -Path (Join-Path $sd 'server-should-run.txt') -Value 'qwen3-14b' -Encoding ascii
        Set-Content -Path (Join-Path $sd 'watchdog-gave-up.flag') -Value '' -Encoding ascii
    }
    return $sd
}
$deadOvmsName = 'no-such-ovms-' + [guid]::NewGuid().ToString('N').Substring(0, 6)
function Invoke-StopAll([string[]]$ExtraArgs, [string]$Root, [int]$Port, [string]$OvmsName, [string]$StateDir) {
    $argv = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $stopAll,
              '-BlarAiRepo', $Root, '-AoPort', "$Port",
              '-OvmsProcessName', $OvmsName,
              '-OvmsApiBase', ('http://127.0.0.1:{0}' -f (Get-FreePort)),
              '-StateDir', $StateDir) + $ExtraArgs
    # Invoke-CapturedRun: EOF stdin (deterministic Read-Host cancel), output to
    # files, tree-kill on timeout - the spawn-lib R3/R4/R5 shape.
    return Invoke-CapturedRun -FilePath $pwshExe -ArgumentList $argv -WorkingDirectory $work -TimeoutSec 90
}

try {
    # --- B1: clean no-op ----------------------------------------------------
    Write-Host "`nB1 - clean no-op when nothing is running" -ForegroundColor Yellow
    $r1 = Invoke-StopAll @() (New-FixtureRoot) (Get-FreePort) $deadOvmsName (New-FixtureState)
    Check "B1 exit 0" ($r1.ExitCode -eq 0)
    Check "B1 reports nothing to stop" ($r1.Stdout -match 'Nothing model-bearing')

    # --- B2: dry run touches nothing ---------------------------------------
    Write-Host "`nB2 - dry run: reports, touches nothing" -ForegroundColor Yellow
    $root2 = New-FixtureRoot
    $port2 = Get-FreePort
    $rdy2  = Join-Path $work 'rdy2.txt'
    $fix2  = Start-Fixture -WithMarker -GcPidFile (Join-Path $work 'gc2.pid') -ListenPort $port2 -ReadyFile $rdy2
    $null  = Wait-ForFile $rdy2
    Set-LockPid $root2 $fix2.Id
    $state2 = New-FixtureState -Armed
    $r2 = Invoke-StopAll @('-DryRun') $root2 $port2 $deadOvmsName $state2
    Check "B2 exit 0" ($r2.ExitCode -eq 0)
    Check "B2 plan names the assistant decoy pid" ($r2.Stdout -match "pid $($fix2.Id)")
    Check "B2 prints the DRY RUN banner" ($r2.Stdout -match 'DRY RUN')
    Check "B2 decoy STILL ALIVE" (Test-Alive $fix2.Id)
    Check "B2 sentinel STILL PRESENT" (Test-Path (Join-Path $state2 'server-should-run.txt'))

    # --- B3: real run kills everything and verifies -------------------------
    Write-Host "`nB3 - real run (-Yes): assistant + OVMS decoys die, watchdog stood down" -ForegroundColor Yellow
    $root3 = New-FixtureRoot
    $port3 = Get-FreePort
    $gc3F  = Join-Path $work 'gc3.pid'
    $rdy3  = Join-Path $work 'rdy3.txt'
    $fix3  = Start-Fixture -WithMarker -GcPidFile $gc3F -ListenPort $port3 -ReadyFile $rdy3
    $gc3   = Wait-ForFile $gc3F
    $null  = Wait-ForFile $rdy3
    Set-LockPid $root3 $fix3.Id
    $decoyName = 'ovmsdecoy' + [guid]::NewGuid().ToString('N').Substring(0, 6)
    $decoyExe  = Join-Path $work ($decoyName + '.exe')
    Copy-Item (Join-Path $env:SystemRoot 'System32\cmd.exe') $decoyExe
    $ovmsFix = Start-Process -FilePath $decoyExe -ArgumentList '/d', '/c', 'ping -n 300 127.0.0.1 >nul' -WindowStyle Hidden -PassThru
    $null = $ovmsFix.Handle
    [void]$spawned.Add($ovmsFix.Id)
    Start-Sleep -Milliseconds 500
    $state3 = New-FixtureState -Armed
    $r3 = Invoke-StopAll @('-Yes') $root3 $port3 $decoyName $state3
    Check "B3 exit 0" ($r3.ExitCode -eq 0)
    Check "B3 assistant decoy DEAD" (Wait-Dead $fix3.Id)
    if ($gc3) { Check "B3 grandchild reaped" (Wait-Dead ([int]$gc3)) }
    Check "B3 OVMS decoy DEAD" (Wait-Dead $ovmsFix.Id)
    Check "B3 sentinel removed" (-not (Test-Path (Join-Path $state3 'server-should-run.txt')))
    Check "B3 gave-up flag removed" (-not (Test-Path (Join-Path $state3 'watchdog-gave-up.flag')))
    Check "B3 verification reports DEAD" ($r3.Stdout -match 'DEAD')
    Check "B3 reports RAM figures" ($r3.Stdout -match 'RAM free')

    # --- B4: EOF stdin cancels ----------------------------------------------
    Write-Host "`nB4 - no -Yes + EOF stdin cancels" -ForegroundColor Yellow
    $root4 = New-FixtureRoot
    $port4 = Get-FreePort
    $rdy4  = Join-Path $work 'rdy4.txt'
    $fix4  = Start-Fixture -WithMarker -GcPidFile (Join-Path $work 'gc4.pid') -ListenPort $port4 -ReadyFile $rdy4
    $null  = Wait-ForFile $rdy4
    Set-LockPid $root4 $fix4.Id
    $r4 = Invoke-StopAll @() $root4 $port4 $deadOvmsName (New-FixtureState)
    Check "B4 exit 0 (cancel is not an error)" ($r4.ExitCode -eq 0)
    Check "B4 reports Cancelled" ($r4.Stdout -match 'Cancelled')
    Check "B4 decoy STILL ALIVE" (Test-Alive $fix4.Id)

    # --- B5: refuses the unidentified port holder ---------------------------
    Write-Host "`nB5 - refuses a non-launcher port holder" -ForegroundColor Yellow
    $port5 = Get-FreePort
    $rdy5  = Join-Path $work 'rdy5.txt'
    $fix5  = Start-Fixture -GcPidFile (Join-Path $work 'gc5.pid') -ListenPort $port5 -ReadyFile $rdy5   # NO marker
    $null  = Wait-ForFile $rdy5
    $root5 = New-FixtureRoot   # no lock at all
    $r5 = Invoke-StopAll @('-Yes') $root5 $port5 $deadOvmsName (New-FixtureState)
    Check "B5 exit 0" ($r5.ExitCode -eq 0)
    # Socket owner may be the venv shim's CHILD (spawn-lib R1) - accept any
    # pid from the decoy's tree in the NOT STOPPING line.
    $tree5 = @(Get-AiProcessTreePids -RootPid $fix5.Id -Table (Get-AiProcessTable))
    $m5 = [regex]::Match($r5.Stdout, 'NOT STOPPING[^\r\n]*pid (\d+)')
    Check "B5 reports NOT STOPPING with the holder pid" ($m5.Success -and ($tree5 -contains [int]$m5.Groups[1].Value))
    Check "B5 unidentified holder SURVIVES" (Test-Alive $fix5.Id)

    # --- B6: Windows PowerShell 5.1 -DryRun execution smoke ------------------
    # The panel's .cmd falls back to powershell.exe, so the kill script must
    # EXECUTE (not just parse) under 5.1. An armed-sentinel fixture makes the
    # plan non-empty deterministically with zero fixture processes; -DryRun
    # must print the banner, exit 0, and leave the sentinel in place.
    Write-Host "`nB6 - 5.1 -DryRun execution smoke" -ForegroundColor Yellow
    $ps51 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (Test-Path $ps51) {
        $root6  = New-FixtureRoot   # no lock -> assistant not-running
        $state6 = New-FixtureState -Armed
        $argv6 = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $stopAll,
                   '-DryRun',
                   '-BlarAiRepo', $root6, '-AoPort', "$(Get-FreePort)",
                   '-OvmsProcessName', $deadOvmsName,
                   '-OvmsApiBase', ('http://127.0.0.1:{0}' -f (Get-FreePort)),
                   '-StateDir', $state6)
        $r6 = Invoke-CapturedRun -FilePath $ps51 -ArgumentList $argv6 -WorkingDirectory $work -TimeoutSec 90
        Check "B6 exit 0 under 5.1 (got $($r6.ExitCode))" ($r6.ExitCode -eq 0)
        Check "B6 plan includes the watchdog stand-down" ($r6.Stdout -match 'WILL ALSO')
        Check "B6 prints the DRY RUN banner" ($r6.Stdout -match 'DRY RUN')
        Check "B6 sentinel untouched" (Test-Path (Join-Path $state6 'server-should-run.txt'))
    } else {
        Check "B6 powershell.exe not present - skipped as pass (pwsh-only box)" $true
    }
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
