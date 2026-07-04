#requires -Version 5.1
<#
.SYNOPSIS
  Tier-2 foreground capture: launch the built app, bring its window to front,
  capture ONLY that window's rectangle to a PNG, close the app.
  Intended as a fallback when the headless --render-to-file tier fails.

.DESCRIPTION
  Launch -> wait for main window (bounded) -> SetForegroundWindow -> GDI
  CopyFromScreen over the window rect -> save PNG -> kill the process.
  Steals focus briefly; acceptable only as a fallback (the caller, capture-app.ps1,
  tries Tier-1 headless first).

  WINDOWS POWERSHELL 5.1 REQUIRED FOR THE GDI BODY (the load-bearing detail):
    The fleet runs on PowerShell 7 (pwsh, PSEdition=Core). On .NET (Core), the
    System.Drawing types (Bitmap, Graphics, ...) are NOT in System.Drawing -- they
    are type-forwarded to System.Drawing.Common, which cascades to
    System.Drawing.Primitives -> System.Private.Windows.GdiPlus, an endless
    -ReferencedAssemblies chain that makes an inline `Add-Type` FAIL TO COMPILE
    under pwsh 7 (CS1069 'Bitmap' could not be found / CS0012 'Size'/'IImage'
    not referenced). Windows PowerShell 5.1 (powershell.exe, PSEdition=Desktop)
    ships System.Drawing natively with no cascade, so the capture body compiles and
    runs there with a single `@('System.Drawing')` reference.

    THE FIX: if this script is invoked under Core (pwsh 7), it RE-INVOKES ITSELF
    via `powershell.exe -NoProfile -ExecutionPolicy Bypass -File <self> ...`,
    forwarding the same -AppExe/-OutPng/-LaunchTimeoutSec/-SettleSec, and returns
    that child's exit code + stdout. The GDI capture body below therefore only ever
    runs under Windows PowerShell 5.1. A single script works whether called from
    pwsh 7 or 5.1, with the same param interface and the same
    CAPTURE-OK:/CAPTURE-FAIL: stdout contract that capture-app.ps1 parses.

  Always timeout-bounded:
    -LaunchTimeoutSec (default 20): time to wait for the main window to appear.
  A hung app is killed before this script returns.

.PARAMETER AppExe
  Full path to the built App.exe.

.PARAMETER OutPng
  Destination PNG path (parent directory is created if absent).

.PARAMETER LaunchTimeoutSec
  Max seconds to wait for the app window to appear (default 20).

.PARAMETER SettleSec
  Seconds to let the app render after foregrounding (default 1).

.PARAMETER CompileProbeOnly
  Internal/test hook: compile the GDI capture types and exit (no launch/capture).
  Prints "COMPILE-OK" + exit 0 if the types compile under the edition where the body
  actually runs (5.1), or surfaces the compile failure. Under pwsh 7 this still
  re-invokes to 5.1 first, so the probe reflects where the real body runs. Used by
  verify-capture.ps1 to ACTUALLY exercise the Add-Type path end to end (the
  mock-passes/runtime-fails guard).

.OUTPUTS
  Exit 0 and prints "CAPTURE-OK: <path> (<WxH>)" on success.
  Exit 1 and prints "CAPTURE-FAIL: <reason>" on failure (app never started, no
  window appeared, or GDI failed). The app process is always killed on exit.
#>
param(
    [Parameter(Mandatory)][string]$AppExe,
    [Parameter(Mandatory)][string]$OutPng,
    [int]$LaunchTimeoutSec = 20,
    [double]$SettleSec = 1.0,
    [switch]$CompileProbeOnly
)
$ErrorActionPreference = 'Stop'

# ===========================================================================
# EDITION GUARD: the GDI body below needs Windows PowerShell 5.1 (Desktop). If we
# are running under pwsh 7 (Core), re-invoke OURSELVES via powershell.exe and pass
# the child's stdout + exit code straight through. This is the FIRST thing the
# script does, before any Add-Type -- so the System.Drawing cascade is never hit.
# ===========================================================================
if ($PSVersionTable.PSEdition -eq 'Core') {
    $ps51 = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path $ps51)) {
        Write-Output "CAPTURE-FAIL: Windows PowerShell 5.1 (powershell.exe) not found at $ps51; cannot run the GDI capture body off Core"
        exit 1
    }
    $selfPath = $PSCommandPath
    if (-not $selfPath) { $selfPath = $MyInvocation.MyCommand.Path }
    $childArgs = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $selfPath,
        '-AppExe', $AppExe,
        '-OutPng', $OutPng,
        '-LaunchTimeoutSec', $LaunchTimeoutSec,
        '-SettleSec', $SettleSec
    )
    if ($CompileProbeOnly) { $childArgs += '-CompileProbeOnly' }
    # & invokes the child and streams its stdout through; $LASTEXITCODE carries its code.
    & $ps51 @childArgs
    exit $LASTEXITCODE
}

# ===========================================================================
# From here down: GUARANTEED Windows PowerShell 5.1 (Desktop edition).
# System.Drawing is native -- the inline Add-Type compiles with no cascade.
# (-ErrorAction Stop, NOT SilentlyContinue: a compile failure must be LOUD, never
# swallowed into a later confusing "[WinCapture] type not found" error.)
# ===========================================================================
Add-Type -TypeDefinition @'
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.IO;

public static class WinCapture {
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);

    public const int SW_RESTORE = 9;
    public const int SW_SHOW    = 5;

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT {
        public int Left, Top, Right, Bottom;
        public int Width  { get { return Right  - Left; } }
        public int Height { get { return Bottom - Top; } }
    }

    // Capture the rectangle of an HWND to a PNG file.
    // Returns "" on success, an error message on failure.
    public static string CaptureWindowToPng(IntPtr hwnd, string outPath) {
        RECT r;
        if (!GetWindowRect(hwnd, out r))
            return "GetWindowRect failed";
        int w = r.Width;
        int h = r.Height;
        if (w <= 0 || h <= 0)
            return string.Format("Window rect is {0}x{1} (collapsed or off-screen)", w, h);

        try {
            using (var bmp = new Bitmap(w, h, PixelFormat.Format32bppArgb))
            using (var g = Graphics.FromImage(bmp)) {
                g.CopyFromScreen(r.Left, r.Top, 0, 0, new Size(w, h), CopyPixelOperation.SourceCopy);
                var dir = Path.GetDirectoryName(outPath);
                if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
                bmp.Save(outPath, ImageFormat.Png);
                return "";  // success
            }
        } catch (Exception ex) {
            return "GDI capture failed: " + ex.Message;
        }
    }

    // Foreground the window as robustly as possible (mirrors winui_foreground.py).
    public static void BestEffortForeground(IntPtr hwnd) {
        try { if (IsIconic(hwnd)) ShowWindow(hwnd, SW_RESTORE); else ShowWindow(hwnd, SW_SHOW); } catch {}
        try { BringWindowToTop(hwnd); } catch {}
        try { SetForegroundWindow(hwnd); } catch {}
    }
}
'@ -ReferencedAssemblies @('System.Drawing') -ErrorAction Stop

# COMPILE PROBE (test hook): if we got here under 5.1, the Add-Type above succeeded.
if ($CompileProbeOnly) {
    Write-Output "COMPILE-OK"
    exit 0
}

function Fail($msg) { Write-Output "CAPTURE-FAIL: $msg"; exit 1 }

# -- Validate inputs --
if (-not (Test-Path $AppExe)) { Fail "App exe not found: $AppExe" }

# -- Launch the app --
$proc = $null
try {
    $proc = Start-Process -FilePath $AppExe -PassThru -WindowStyle Hidden -ErrorAction Stop
} catch {
    Fail "Could not launch app: $($_.Exception.Message)"
}

# -- Find the main window (bounded poll) --
$hwnd = [IntPtr]::Zero
$deadline = (Get-Date).AddSeconds($LaunchTimeoutSec)
while ((Get-Date) -lt $deadline) {
    if ($proc.HasExited) { Fail "App exited immediately (code $($proc.ExitCode)) before a window appeared" }
    $proc.Refresh()
    if ($proc.MainWindowHandle -ne [IntPtr]::Zero) {
        $hwnd = $proc.MainWindowHandle
        break
    }
    Start-Sleep -Milliseconds 200
}
if ($hwnd -eq [IntPtr]::Zero) {
    try { $proc.Kill() } catch {}
    Fail "No main window appeared within ${LaunchTimeoutSec}s"
}

# -- Foreground + settle --
[WinCapture]::BestEffortForeground($hwnd)
Start-Sleep -Seconds $SettleSec

# -- Capture --
$err = [WinCapture]::CaptureWindowToPng($hwnd, $OutPng)

# -- Kill the app --
try { $proc.Kill() } catch {}

# -- Report --
if ($err) {
    Fail $err
}
$bmp = [System.Drawing.Image]::FromFile($OutPng)
$w = $bmp.Width; $h = $bmp.Height; $bmp.Dispose()
Write-Output "CAPTURE-OK: $OutPng ($w x $h)"
exit 0
