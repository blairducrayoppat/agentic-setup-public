# spawn-lib.ps1 - Blessed Windows process-spawn helpers for PowerShell (#774).
#
# WHY THIS EXISTS
# ===============
# The PowerShell twin of blarai shared/procspawn.py. Spawning child processes on
# Windows has cost this project at least five paid incidents; the rules kept being
# re-discovered one scar at a time. This is the single blessed PS surface - each
# function encodes a learned rule and carries the incident that justified it.
#
# Nothing here is wired into a live script yet; existing spawn sites migrate later,
# deliberately. The conformance suite (verify-spawn-lib.ps1) is the positive control
# (2026-07-09 lesson): each shape asserts its OBSERVABLE END PROPERTY on a real child
# process, never the flag at the spawn site (lesson 219).
#
# NOTE ON THIS FILE'S ENCODING: the source is deliberately ASCII-only (no em-dash,
# no section sign, no emoji as literals). PowerShell 5.1's [Parser] reads a
# UTF-8-no-BOM .ps1 as cp1252 and throws spurious "unexpected token" on such
# characters (FIELD_NOTES 2026-07-06). Any unicode this library needs is built from
# code points at runtime, so the file parses on every shell.
#
# THE RULES -> THE INCIDENTS
# ==========================
# R1  A console-less DETACHED python child must run via pythonw.exe, not the venv
#     python.exe shim (#761 / blarai lesson 219). The shim re-spawns the base
#     console-subsystem interpreter as a CHILD; a detach does not inherit, so the
#     child gets a fresh VISIBLE console the operator can accidentally close.
#     pythonw.exe is GUI-subsystem all the way down: no console is ever allocated,
#     and a Textual launcher takes its proven headless-driver fallback.
# R2  Never hide the console of an INTERACTIVE/Textual python child; a hidden
#     console crashed Textual on 2026-07-06 ("Driver must be in application mode").
#     Hiding is safe ONLY for non-interactive console children (git/tasklist/cmd).
# R3  A console-less child with inherited-but-broken cp1252 stdio crashes on its
#     first non-ASCII print (#761 banner crash). Always pin PYTHONUTF8=1 +
#     PYTHONIOENCODING=utf-8 and redirect stdio to a file, never leave it bare.
# R4  A child reading an inherited non-TTY stdin that never EOFs blocks forever
#     (opencode-run init stall, fleet-lib Invoke-AgentRun); a parent holding a
#     captured PIPE a grandchild inherits deadlocks (Tee-Object server-launcher
#     hang, FIELD_NOTES lesson 161; #759 ACP-spike undrained-PIPE dodge). Feed an
#     EMPTY stdin file (instant EOF) and redirect stdout/stderr to FILES, never a
#     parent-held pipe.
# R5  On timeout, kill the whole PROCESS TREE (taskkill /T /F), not just the
#     launched process (#630) - a launcher's grandchildren (OVMS, backends) outlive
#     a parent-only kill and hold ports / bleed the budget.
#
# CAVEAT: a process EXIT CODE is not proof its side effect completed. msedge
# --screenshot hands the write to a DETACHED worker; the launcher exits 0 ~4s
# before the PNG lands, and --screenshot silently no-ops on flag order
# (capture-app.ps1, pinned 2026-06-26). When a spawn's deliverable is a side
# effect, POLL for the end property - do not trust process exit.

Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# R1 - interpreter resolution
# ---------------------------------------------------------------------------

function Resolve-PythonwSibling {
    # R1 (#761 / lesson 219). Return the GUI-subsystem pythonw.exe beside a venv
    # python.exe, else the input unchanged (fail-safe: never a broken spawn).
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$PythonExe)
    $leaf = Split-Path $PythonExe -Leaf
    if ($leaf.ToLower() -eq 'python.exe') {
        $sibling = Join-Path (Split-Path $PythonExe -Parent) 'pythonw.exe'
        if (Test-Path $sibling) { return $sibling }
    }
    return $PythonExe
}

function Set-Utf8ChildEnv {
    # R3: pin the child's stdio to UTF-8 so a redirected pipe cannot default to
    # cp1252 and crash the first non-ASCII print. Returns the prior values so the
    # caller can restore them.
    [CmdletBinding()]
    param()
    $prior = @{ PYTHONUTF8 = $env:PYTHONUTF8; PYTHONIOENCODING = $env:PYTHONIOENCODING }
    $env:PYTHONUTF8 = '1'
    $env:PYTHONIOENCODING = 'utf-8'
    return $prior
}

function Restore-ChildEnv {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Prior)
    foreach ($k in $Prior.Keys) {
        if ($null -eq $Prior[$k]) { Remove-Item "Env:\$k" -ErrorAction SilentlyContinue }
        else { Set-Item "Env:\$k" $Prior[$k] }
    }
}

# ---------------------------------------------------------------------------
# R1+R3 - detached, console-less spawn (launcher / Textual chains)
# ---------------------------------------------------------------------------

function Start-DetachedProcess {
    # Spawn a child DETACHED (no console, outlives this session), stdio to files.
    # For a python launcher / Textual chain (python -m launcher), swap drivers,
    # night-boot. Encodes R1 (pythonw resolve), R3 (empty stdin + UTF-8 log +
    # env pins). Deliberately NOT a hidden console (R2). Returns the Process object
    # (-PassThru) - the caller does NOT wait; the child is detached by design.
    #
    # NOTE: PowerShell's Start-Process cannot set the DETACHED_PROCESS creation flag
    # directly, so the no-console guarantee for a python child rides R1 (pythonw is
    # console-less by subsystem). Redirecting stdout/stderr to FILES (not a parent
    # pipe) is what actually keeps the child independent of this session's lifetime
    # (R4 - never hold a server launcher's pipe).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [string]$WorkingDirectory = (Get-Location).Path,
        [Parameter(Mandatory)][string]$LogPath
    )
    $exe = Resolve-PythonwSibling $FilePath
    $logDir = Split-Path $LogPath -Parent
    if ($logDir -and -not (Test-Path $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
    $errPath = "$LogPath.err"
    $inPath = "$LogPath.stdin"
    Set-Content -Path $inPath -Value '' -NoNewline -Encoding ascii   # empty -> instant EOF (R4)

    $prior = Set-Utf8ChildEnv
    try {
        $spArgs = @{
            FilePath               = $exe
            WorkingDirectory       = $WorkingDirectory
            RedirectStandardInput  = $inPath
            RedirectStandardOutput = $LogPath
            RedirectStandardError  = $errPath
            PassThru               = $true
            ErrorAction            = 'Stop'
        }
        if ($ArgumentList.Count -gt 0) { $spArgs['ArgumentList'] = $ArgumentList }
        # NO -WindowStyle Hidden: for pythonw there is no console anyway, and Hidden
        # on a console child is the exact R2 shape that crashed Textual.
        return Start-Process @spArgs
    }
    finally { Restore-ChildEnv $prior }
}

# ---------------------------------------------------------------------------
# R2 - hidden-console spawn (NON-interactive console children only)
# ---------------------------------------------------------------------------

function Start-HiddenProcess {
    # Run a NON-interactive console child (git / tasklist / cmd) with NO visible
    # window, captured, blocking up to -TimeoutSec. Uses .NET CreateNoWindow=true.
    # DO NOT use for a python launcher / Textual child (R2). Returns
    # @{ ExitCode; Stdout; Stderr; TimedOut; Seconds }.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [string]$WorkingDirectory = (Get-Location).Path,
        [int]$TimeoutSec = 120
    )
    return (Invoke-CapturedRun -FilePath $FilePath -ArgumentList $ArgumentList `
            -WorkingDirectory $WorkingDirectory -TimeoutSec $TimeoutSec)
}

# ---------------------------------------------------------------------------
# R4+R5 - captured run with UTF-8, EOF stdin, timeout + tree-kill
# ---------------------------------------------------------------------------

function Invoke-CapturedRun {
    # Run a child to completion, capturing stdout/stderr to FILES, with R3/R4/R5
    # guarantees. Mirrors the proven fleet-lib Invoke-AgentRun shape:
    #   R3/R4 - empty stdin file (instant EOF; no init stall), UTF-8 child env,
    #           stdout+stderr redirected to files (never a parent-held pipe).
    #   R5    - on timeout, taskkill /T /F kills the WHOLE process tree, not just
    #           the launched process (orphaned grandchildren cannot bleed the budget).
    # Never throws on timeout: returns TimedOut=$true with whatever was captured.
    # The console is created hidden (CreateNoWindow) - safe here: captured,
    # non-interactive.
    # Returns @{ Pid; ExitCode; Stdout; Stderr; TimedOut; Seconds; TreeKilled }.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [string]$WorkingDirectory = (Get-Location).Path,
        [int]$TimeoutSec = 120,
        [string]$InputText = ''
    )
    $tmp = [System.IO.Path]::GetTempFileName()
    $outPath = "$tmp.out"; $errPath = "$tmp.err"; $inPath = "$tmp.in"
    Set-Content -Path $inPath -Value $InputText -NoNewline -Encoding utf8   # empty by default -> EOF (R4)

    $prior = Set-Utf8ChildEnv
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $timedOut = $false; $treeKilled = $false; $exitCode = $null
    try {
        $spArgs = @{
            FilePath               = $FilePath
            WorkingDirectory       = $WorkingDirectory
            RedirectStandardInput  = $inPath
            RedirectStandardOutput = $outPath
            RedirectStandardError  = $errPath
            NoNewWindow            = $true     # captured, non-interactive -> hidden is safe (R2)
            PassThru               = $true
            ErrorAction            = 'Stop'
        }
        if ($ArgumentList.Count -gt 0) { $spArgs['ArgumentList'] = $ArgumentList }
        $p = Start-Process @spArgs
        $null = $p.Handle   # PS 5.1: cache the handle so ExitCode is readable after exit
        if (-not $p.WaitForExit($TimeoutSec * 1000)) {
            $timedOut = $true
            Stop-ProcessTree -ProcessId $p.Id      # R5: kill the whole tree
            $treeKilled = $true
            try { $null = $p.WaitForExit(5000) } catch {}
        }
        else { $exitCode = $p.ExitCode }
    }
    finally { Restore-ChildEnv $prior; $sw.Stop() }

    $stdout = if (Test-Path $outPath) { Get-Content $outPath -Raw -Encoding utf8 -ErrorAction SilentlyContinue } else { '' }
    $stderr = if (Test-Path $errPath) { Get-Content $errPath -Raw -Encoding utf8 -ErrorAction SilentlyContinue } else { '' }
    foreach ($f in @($outPath, $errPath, $inPath, $tmp)) { Remove-Item $f -ErrorAction SilentlyContinue }

    return @{
        Pid        = $p.Id
        ExitCode   = $exitCode
        Stdout     = [string]$stdout
        Stderr     = [string]$stderr
        TimedOut   = $timedOut
        Seconds    = $sw.Elapsed.TotalSeconds
        TreeKilled = $treeKilled
    }
}

# ---------------------------------------------------------------------------
# R5 - process-tree teardown
# ---------------------------------------------------------------------------

function Stop-ProcessTree {
    # R5 (#630). Kill a process AND all descendants via taskkill /T /F - a bare
    # Stop-Process kills only the named process, orphaning grandchildren that hold
    # ports / bleed budget. Best-effort; never throws.
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$ProcessId)
    try { & taskkill.exe /T /F /PID $ProcessId *> $null } catch {}
}
