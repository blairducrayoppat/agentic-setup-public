#requires -Version 7.0
<#
.SYNOPSIS
  Verify stop-assistant.ps1 (#797): the Control Panel's "Stop the assistant" path
  stops the AO/launcher's resident 14B safely - confirming the target is a live
  `-m launcher` before killing, and killing ONLY through the audited spawn-lib seam.

.DESCRIPTION
  Two layers, both offline:

  STRUCTURE (AST + static, deterministic - the safety invariants):
    A1  stop-assistant.ps1 uses the audited kill seam (Stop-ProcessTree from
        spawn-lib.ps1) and contains NO hand-rolled kill (taskkill / Stop-Process).
    A2  every Stop-ProcessTree call site is lexically guarded by a
        Test-IsLiveLauncher(...) if-block - the "never kill by pid/name alone" rule
        made structural (AST walk, like verify-battery-unregister-scoping.ps1).
    A3  the confirmation checks the '-m launcher' cmdline marker.
    A4  control-panel.ps1 wires [S] -> stop-assistant.ps1, keeps menu 5 -> stop-llm.ps1
        (OVMS unchanged), and labels the two RAM consumers distinctly.

  BEHAVIOR (live, FIXTURE processes only - never the real launcher / OVMS / GPU):
    B1  a confirmed `-m launcher` decoy (with a grandchild) is tree-killed dead,
        grandchild reaped, exit 0.
    B2  a NON-launcher decoy whose pid is planted in the lock is REFUSED - it stays
        alive, exit 0, message says "not a live '-m launcher'".
    B3  a dead pid in the lock -> graceful "not running", exit 0, nothing touched.
    B4  no lock file -> graceful "not running", exit 0.

  Run it normally ( .\verify-stop-assistant.ps1 ) - do NOT dot-source it.
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

$stopAssistant = Join-Path $PSScriptRoot 'stop-assistant.ps1'
$controlPanel  = Join-Path $PSScriptRoot 'control-panel.ps1'
Check "stop-assistant.ps1 exists" (Test-Path $stopAssistant)
Check "control-panel.ps1 exists" (Test-Path $controlPanel)

# ===========================================================================
# STRUCTURE - AST + static
# ===========================================================================
Section 'A1-A3  stop-assistant.ps1 uses the audited seam behind a launcher-confirmation guard'
$ast = [System.Management.Automation.Language.Parser]::ParseFile($stopAssistant, [ref]$null, [ref]$null)
$src = Get-Content $stopAssistant -Raw

# A1a: it references / uses the blessed teardown.
$kills = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and
                        $n.GetCommandName() -eq 'Stop-ProcessTree' }, $true)
Check "A1 calls Stop-ProcessTree (spawn-lib audited seam) - exactly 1 site (got $($kills.Count))" ($kills.Count -eq 1)
Check "A1 dot-sources spawn-lib.ps1 (source of Stop-ProcessTree)" ($src -match 'spawn-lib\.ps1')

# A1b: NO hand-rolled kill anywhere in the script.
$allCmds = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)
$banned  = @($allCmds | Where-Object { $_.GetCommandName() -in @('taskkill', 'taskkill.exe', 'Stop-Process') })
Check "A1 NO hand-rolled kill (taskkill / Stop-Process) in stop-assistant.ps1" ($banned.Count -eq 0)

# A2: every kill site sits inside a Test-IsLiveLauncher(...) if-guard.
foreach ($k in $kills) {
    $guarded = $false
    $p = $k.Parent
    while ($p) {
        if ($p -is [System.Management.Automation.Language.IfStatementAst]) {
            foreach ($clause in $p.Clauses) {
                if ($clause.Item1.Extent.Text -match 'Test-IsLiveLauncher' -and
                    $clause.Item1.Extent.StartOffset -lt $k.Extent.StartOffset -and
                    $clause.Item2.Extent.EndOffset  -ge $k.Extent.EndOffset) { $guarded = $true }
            }
        }
        $p = $p.Parent
    }
    Check "A2 Stop-ProcessTree at line $($k.Extent.StartLineNumber) is inside a Test-IsLiveLauncher guard" $guarded
}

# A3: the confirmation is about the '-m launcher' cmdline marker (never name-only).
Check "A3 confirmation checks the '-m launcher' cmdline marker" ($src -match '-m launcher')
Check "A3 reads the launcher single-instance lock (certs/launcher.lock)" ($src -match 'launcher\.lock')

Section 'A4  control-panel.ps1 wiring + labels'
$panel = Get-Content $controlPanel -Raw
Check "A4 [S] dispatches to stop-assistant.ps1" ($panel -match "\^\[Ss\]\`$.*stop-assistant\.ps1")
Check "A4 menu 5 still dispatches to stop-llm.ps1 (OVMS path unchanged)" ($panel -match "\`$c -eq '5'.*stop-llm\.ps1")
Check "A4 label names the assistant consumer" ($panel -match 'Stop the assistant')
Check "A4 label names the model-server (OVMS) consumer distinctly" ($panel -match 'Stop the model server')

# ===========================================================================
# BEHAVIOR - live fixtures (NEVER the real launcher / OVMS / GPU)
# ===========================================================================
Section 'B1-B4  live fixture behavior'

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
function Wait-ForFile([string]$Path, [int]$TimeoutSec = 10) {
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if ((Test-Path $Path) -and (Get-Item $Path).Length -gt 0) { return (Get-Content $Path -Raw).Trim() }
        Start-Sleep -Milliseconds 100
    }
    return ''
}
function Wait-Dead([int]$ProcessId, [int]$TimeoutSec = 8) {
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline -and (Test-Alive $ProcessId)) { Start-Sleep -Milliseconds 100 }
    return (-not (Test-Alive $ProcessId))
}
function Invoke-StopAssistant([string]$Root) {
    $raw  = & pwsh -NoProfile -ExecutionPolicy Bypass -File $stopAssistant -BlarAiRepo $Root 2>&1
    $code = $LASTEXITCODE
    return @{ Code = $code; Out = ($raw | Out-String) }
}

$py   = Get-TestPython
$work = Join-Path ([System.IO.Path]::GetTempPath()) ('stop-assistant-verify-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $work | Out-Null

# Fixture: spawn a grandchild sleeper, record its pid, then sleep. Trailing script
# args (e.g. '-m launcher') land in this process's CommandLine WITHOUT python
# treating them as interpreter options - a valid decoy for the cmdline confirmation.
$fixture = Join-Path $work 'fixture.py'
Set-Content -Path $fixture -Encoding utf8 -Value @'
import os, subprocess, sys, time
gc = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(300)'])
gc_file = os.environ.get('GC_PID_FILE')
if gc_file:
    open(gc_file, 'w').write(str(gc.pid))
time.sleep(300)
'@

$spawned = New-Object System.Collections.ArrayList
function Start-Fixture([switch]$WithMarker, [string]$GcPidFile) {
    $tag = [guid]::NewGuid().ToString('N').Substring(0, 6)
    $inEmpty = Join-Path $work "in-$tag"; Set-Content -Path $inEmpty -Value '' -NoNewline -Encoding ascii
    $out = "$inEmpty.out"; $err = "$inEmpty.err"
    $argv = @($fixture)
    if ($WithMarker) { $argv += @('-m', 'launcher') }
    $prev = $env:GC_PID_FILE
    $env:GC_PID_FILE = $GcPidFile
    try {
        $p = Start-Process -FilePath $py -ArgumentList $argv -WorkingDirectory $work `
                -RedirectStandardInput $inEmpty -RedirectStandardOutput $out -RedirectStandardError $err `
                -NoNewWindow -PassThru
        $null = $p.Handle
    } finally {
        if ($null -eq $prev) { Remove-Item Env:\GC_PID_FILE -ErrorAction SilentlyContinue } else { $env:GC_PID_FILE = $prev }
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

try {
    # --- B1: confirmed launcher -> tree-killed, grandchild reaped, exit 0 ----
    Write-Host "`nB1 - confirmed '-m launcher' decoy is tree-killed" -ForegroundColor Yellow
    $root1  = New-FixtureRoot
    $gcFile = Join-Path $work 'gc1.pid'
    $fix1   = Start-Fixture -WithMarker -GcPidFile $gcFile
    $gcTxt  = Wait-ForFile $gcFile 12
    Check "B1 decoy launched + grandchild registered" ($gcTxt -ne '')
    $cmd1 = (Get-CimInstance Win32_Process -Filter "ProcessId=$($fix1.Id)" -ErrorAction SilentlyContinue).CommandLine
    Check "B1 decoy cmdline carries '-m launcher' (valid decoy for the guard)" ([bool]($cmd1 -match '-m launcher'))
    Set-LockPid $root1 $fix1.Id
    $r1 = Invoke-StopAssistant $root1
    Check "B1 exit 0 on a confirmed launcher" ($r1.Code -eq 0)
    Check "B1 parent tree-killed (dead)" (Wait-Dead $fix1.Id 8)
    if ($gcTxt) { Check "B1 grandchild reaped (no orphan)" (Wait-Dead ([int]$gcTxt) 8) }
    Check "B1 reports the stop" ($r1.Out -match 'Assistant stopped')

    # --- B2: non-launcher pid in the lock -> REFUSED, stays alive -------------
    Write-Host "`nB2 - a NON-launcher pid planted in the lock is refused" -ForegroundColor Yellow
    $root2 = New-FixtureRoot
    $fix2  = Start-Fixture -GcPidFile (Join-Path $work 'gc2.pid')   # NO -m launcher marker
    Start-Sleep -Milliseconds 400
    $cmd2 = (Get-CimInstance Win32_Process -Filter "ProcessId=$($fix2.Id)" -ErrorAction SilentlyContinue).CommandLine
    Check "B2 non-launcher decoy cmdline lacks '-m launcher'" (-not ([bool]($cmd2 -match '-m launcher')))
    Set-LockPid $root2 $fix2.Id
    $r2 = Invoke-StopAssistant $root2
    Check "B2 exit 0 (graceful, not an error)" ($r2.Code -eq 0)
    Check "B2 refused to kill the non-launcher (still ALIVE)" (Test-Alive $fix2.Id)
    Check "B2 message says the pid is not a live '-m launcher'" ($r2.Out -match "not a live '-m launcher'")

    # --- B3: dead pid in the lock -> graceful not-running --------------------
    Write-Host "`nB3 - a dead pid in the lock is handled gracefully" -ForegroundColor Yellow
    $throw = Start-Process -FilePath $py -ArgumentList @('-c', 'pass') -NoNewWindow -PassThru
    $null = $throw.Handle; $throw.WaitForExit(5000) | Out-Null
    $deadPid = $throw.Id
    $root3 = New-FixtureRoot; Set-LockPid $root3 $deadPid
    $r3 = Invoke-StopAssistant $root3
    Check "B3 exit 0 on a dead lock pid" ($r3.Code -eq 0)
    Check "B3 reports not-running (stale)" ($r3.Out -match 'not running')

    # --- B4: no lock file -> graceful not-running ---------------------------
    Write-Host "`nB4 - no lock file at all" -ForegroundColor Yellow
    $root4 = New-FixtureRoot   # certs/ exists, no launcher.lock
    $r4 = Invoke-StopAssistant $root4
    Check "B4 exit 0 when there is no lock" ($r4.Code -eq 0)
    Check "B4 reports no launcher lock" ($r4.Out -match 'no launcher lock')
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
