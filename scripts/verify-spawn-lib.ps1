# verify-spawn-lib.ps1 - Conformance suite for spawn-lib.ps1 (the POSITIVE CONTROL, #774).
#
# 2026-07-09 lesson: a verdict-issuing instrument needs a positive control. Every
# blessed shape in spawn-lib.ps1 is exercised against a REAL child process and
# asserted on its OBSERVABLE END PROPERTY (lesson 219 - verify the property the
# control exists for, never the flag at the spawn site):
#   R1  no console  -> the detached child self-reports GetConsoleWindow() is NULL
#                      (and runs under pythonw, proving the venv-shim resolve).
#   R3  unicode     -> emoji + euro/arrow round-trip through stdout AND stderr.
#   R4  capture/EOF -> full output captured, exit code honest; a stdin-reading child
#                      does not hang (empty stdin == instant EOF).
#   R5  tree-kill   -> a child-with-grandchild is ACTUALLY dead after a timeout kill.
#
# All children are short python one-liners the suite creates. Run with pwsh (PS7),
# which is also what the scheduled task uses. Exits 0 iff every check passes.
# Source is ASCII-only; the unicode probe is built from code points at runtime.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'spawn-lib.ps1')

# --- tiny assert harness --------------------------------------------------
$script:Failures = 0
function Assert-True {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Label)
    if ($Condition) { Write-Host "  PASS  $Label" -ForegroundColor Green }
    else { Write-Host "  FAIL  $Label" -ForegroundColor Red; $script:Failures++ }
}

# --- locate a python.exe with a pythonw sibling ---------------------------
function Get-TestPython {
    $candidates = @(
        'C:\Users\mrbla\blarai\.venv\Scripts\python.exe',
        (Get-Command python -ErrorAction SilentlyContinue).Source
    ) | Where-Object { $_ -and (Test-Path $_) }
    if (-not $candidates) { throw 'no python.exe found for the conformance suite' }
    return $candidates[0]
}
$py = Get-TestPython
$work = Join-Path ([System.IO.Path]::GetTempPath()) ("spawnlib-verify-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $work | Out-Null
Write-Host "spawn-lib conformance suite - python=$py" -ForegroundColor Cyan
Write-Host "  workdir=$work"

function New-Child {
    param([string]$Name, [string]$Body)
    $p = Join-Path $work $Name
    Set-Content -Path $p -Value $Body -Encoding utf8
    return $p
}
function Wait-ForFile {
    param([string]$Path, [int]$TimeoutSec = 10)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if ((Test-Path $Path) -and (Get-Item $Path).Length -gt 0) {
            return (Get-Content $Path -Raw -Encoding utf8).Trim()
        }
        Start-Sleep -Milliseconds 100
    }
    return ''
}
function Test-Alive {
    param([int]$ProcessId)
    try { $null = Get-Process -Id $ProcessId -ErrorAction Stop; return $true } catch { return $false }
}

try {
    # === R1: pythonw resolve + no-console end property ====================
    Write-Host "`nR1 - detached, console-less (venv-shim resolve)" -ForegroundColor Yellow
    $resolved = Resolve-PythonwSibling $py
    $hasPythonw = Test-Path (Join-Path (Split-Path $py -Parent) 'pythonw.exe')
    if ($hasPythonw) {
        Assert-True ($resolved.ToLower().EndsWith('pythonw.exe')) "Resolve-PythonwSibling -> pythonw.exe ($resolved)"
    } else {
        Assert-True ($resolved -eq $py) "Resolve-PythonwSibling unchanged (no sibling)"
    }

    $r1log = Join-Path $work 'r1.log'
    $r1child = New-Child 'r1_child.py' @'
import ctypes, sys
ctypes.windll.kernel32.GetConsoleWindow.restype = ctypes.c_void_p
hwnd = ctypes.windll.kernel32.GetConsoleWindow()
print('CONSOLE_HWND=%s' % ('NULL' if hwnd in (None, 0) else 'PRESENT'))
print('EXE=%s' % sys.executable)
'@
    $p1 = Start-DetachedProcess -FilePath $py -ArgumentList @($r1child) -WorkingDirectory $work -LogPath $r1log
    $null = $p1.WaitForExit(15000)
    $r1out = Wait-ForFile $r1log 10
    Assert-True ($r1out -match 'CONSOLE_HWND=NULL') "detached child has NO console (end property): $r1out"
    if ($hasPythonw) {
        Assert-True ($r1out.ToLower() -match 'pythonw\.exe') "child ran under pythonw (the resolve mechanism)"
    }

    # === R3: unicode round-trip through stdout AND stderr =================
    Write-Host "`nR3 - unicode round-trip (cp1252 banner-crash class)" -ForegroundColor Yellow
    $fire = [char]::ConvertFromUtf32(0x1F525)   # fire emoji (non-BMP)
    $euro = [string][char]0x20AC                # cp1252-trap
    $r3child = New-Child 'r3_child.py' @'
import sys
s = "PROBE " + chr(0x1F525) + " " + chr(0x20AC) + " " + chr(0x2192) + " END"
sys.stdout.write(s + "\n"); sys.stdout.flush()
sys.stderr.write(s + "\n"); sys.stderr.flush()
sys.exit(0)
'@
    $r3 = Invoke-CapturedRun -FilePath $py -ArgumentList @($r3child) -WorkingDirectory $work -TimeoutSec 30
    Assert-True ($r3.ExitCode -eq 0) "exit code honest (0)"
    Assert-True (-not $r3.TimedOut) "did not time out"
    Assert-True ($r3.Stdout.Contains($fire) -and $r3.Stdout.Contains($euro)) "emoji + euro round-trip on STDOUT"
    Assert-True ($r3.Stderr.Contains($fire) -and $r3.Stderr.Contains($euro)) "emoji + euro round-trip on STDERR"

    # === R4: full capture, honest exit, DEVNULL/empty stdin no-hang ======
    Write-Host "`nR4 - capture completeness + stdin EOF" -ForegroundColor Yellow
    $r4child = New-Child 'r4_child.py' @'
import sys
for i in range(500):
    print('line-%04d' % i)
sys.exit(3)
'@
    $r4 = Invoke-CapturedRun -FilePath $py -ArgumentList @($r4child) -WorkingDirectory $work -TimeoutSec 30
    $lineCount = ([regex]::Matches($r4.Stdout, 'line-')).Count
    Assert-True ($r4.ExitCode -eq 3) "honest non-zero exit code (3)"
    Assert-True ($lineCount -eq 500) "captured ALL output ($lineCount/500 lines)"

    $r4stdin = New-Child 'r4_stdin.py' @'
import sys
data = sys.stdin.read()   # would block forever on a never-EOF stdin
print('READ_LEN=%d' % len(data))
print('DONE')
'@
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $r4b = Invoke-CapturedRun -FilePath $py -ArgumentList @($r4stdin) -WorkingDirectory $work -TimeoutSec 15
    $sw.Stop()
    Assert-True (-not $r4b.TimedOut) "stdin-reading child did NOT hang (empty stdin -> EOF)"
    Assert-True ($r4b.Stdout -match 'DONE' -and $r4b.Stdout -match 'READ_LEN=0') "child read EOF and finished"
    Assert-True ($sw.Elapsed.TotalSeconds -lt 15) "finished well under the timeout"

    # === R5: tree-kill - grandchild actually dies ========================
    Write-Host "`nR5 - tree-kill (grandchild reaped)" -ForegroundColor Yellow
    $gcPidFile = (Join-Path $work 'gc.pid') -replace '\\', '/'
    $r5child = New-Child 'r5_parent.py' @"
import subprocess, sys, time
gc = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(60)'])
open(r'$gcPidFile', 'w').write(str(gc.pid))
time.sleep(60)
"@
    # Launch in the background so we can grab the grandchild pid, then kill the tree.
    $inEmpty = Join-Path $work 'r5.in'; Set-Content -Path $inEmpty -Value '' -NoNewline -Encoding ascii
    $r5out = Join-Path $work 'r5.out'; $r5err = Join-Path $work 'r5.err'
    $parent = Start-Process -FilePath $py -ArgumentList @($r5child) -WorkingDirectory $work `
        -RedirectStandardInput $inEmpty -RedirectStandardOutput $r5out -RedirectStandardError $r5err `
        -NoNewWindow -PassThru
    $null = $parent.Handle
    $gcTxt = Wait-ForFile (Join-Path $work 'gc.pid') 10
    Assert-True ($gcTxt -ne '') "grandchild registered its pid"
    if ($gcTxt) {
        $gcPid = [int]$gcTxt
        Assert-True (Test-Alive $parent.Id) "setup: parent alive"
        Assert-True (Test-Alive $gcPid) "setup: grandchild alive"

        Stop-ProcessTree -ProcessId $parent.Id   # the blessed R5 teardown

        $deadline = (Get-Date).AddSeconds(8)
        while ((Get-Date) -lt $deadline -and ((Test-Alive $parent.Id) -or (Test-Alive $gcPid))) { Start-Sleep -Milliseconds 100 }
        Assert-True (-not (Test-Alive $parent.Id)) "parent dead after tree-kill"
        Assert-True (-not (Test-Alive $gcPid)) "grandchild dead after tree-kill (no orphan leak)"
    }
}
finally {
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""
if ($script:Failures -eq 0) {
    Write-Host "spawn-lib conformance: ALL CHECKS PASSED" -ForegroundColor Green
    exit 0
} else {
    Write-Host "spawn-lib conformance: $script:Failures CHECK(S) FAILED" -ForegroundColor Red
    exit 1
}
