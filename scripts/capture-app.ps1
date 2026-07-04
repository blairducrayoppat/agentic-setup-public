#requires -Version 5.1
<#
.SYNOPSIS
  VLM design-loop render entry. Tries three capture tiers in order; uses the first
  that works. Never blocks the fleet loop on an unsolved render.

.DESCRIPTION
  The degrade chain (tried in order):

    Tier 1 -- Headless off-screen render (preferred):
      Build the project, run App.exe --render-to-file <OutPng>. The app positions
      its window off-screen (-32000,-32000) before showing it (no focus steal),
      renders via WinUI 3 RenderTargetBitmap, writes the PNG, exits. This is the
      minimum-visibility approach: a window IS created (WinUI 3 requires a live
      visual tree for the compositor), but it is never foregrounded/activated.

    Tier 2 -- Foreground window capture (fallback):
      Launch the built App.exe, wait for its main window, SetForegroundWindow
      (steals focus briefly -- acceptable only as a fallback), GDI CopyFromScreen
      over the window rect to OutPng, kill the app.

    Tier 3 -- Structural/static check (floor, never-block):
      A deterministic no-render inspection of the source XAML and assets. Produces
      a JSON with design signals; sets the STRUCTURAL_ONLY output flag. The loop
      always has *something* even when no pixels are available.

  Output on success (Tier 1 or 2):
    stdout line: "CAPTURE-OK: <path> (<W>x<H>) tier=<1|2>"
    OutPng file: the captured PNG.
    exit 0.

  Output on Tier 3 (structural-only floor):
    stdout line: "STRUCTURAL_ONLY"
    OutJson file (OutPng with .json extension): the structural signals JSON.
    OutPng is NOT written (or is empty/absent).
    exit 0. (Never-block: Tier 3 always exits 0.)

  Output on total failure (all three tiers failed):
    stdout line: "CAPTURE-FAIL: <reason>"
    exit 1. (Rare: only if Tier 3 also errored, which is structurally impossible
    since the structural check exits 0 always. Kept as a safety net.)

.PARAMETER AppDir
  The worktree root -- must contain the built App.exe (under bin/ or directly) AND
  the .xaml source files for the structural check.

.PARAMETER OutPng
  Destination PNG path for Tier 1 / Tier 2 captures. Parent directory is created
  if absent. For Tier 3 (structural-only), this path is unused for pixels; the JSON
  is written to OutPng + '.json'.

.PARAMETER AppExe
  Optional: explicit path to App.exe. If omitted, the script searches AppDir for the
  most recently built App.exe (under bin/x64/net8.0-windows*/win-x64/).

.PARAMETER SkipTier1
  Skip the headless-render tier (for testing / when the --render-to-file entry is
  known broken). Default: $false.

.PARAMETER SkipTier2
  Skip the foreground-capture tier. Default: $false.

.PARAMETER Tier1TimeoutSec
  Timeout for the --render-to-file process (default 30).

.PARAMETER Tier2LaunchTimeoutSec
  Max seconds to wait for the main window in the foreground capture (default 20).

.PARAMETER Tier2SettleSec
  Seconds to settle after foregrounding before the GDI capture (default 1).
#>
param(
    [Parameter(Mandatory)][string]$AppDir,
    [Parameter(Mandatory)][string]$OutPng,
    [string]$AppExe = '',
    [switch]$SkipTier1,
    [switch]$SkipTier2,
    [int]$Tier1TimeoutSec = 90,
    [int]$Tier2LaunchTimeoutSec = 40,
    [double]$Tier2SettleSec = 1.0,
    [int]$WebTimeoutSec = 30
)
$ErrorActionPreference = 'Stop'
$ScriptDir = $PSScriptRoot

function Write-Tier($n, $msg) { Write-Host "  [tier-$n] $msg" }

# -- Resolve App.exe ----------------------------------------------------------
function Find-AppExe {
    param([string]$Root)
    # Search common build-output paths: bin/x64/<tfm>/win-x64/ and bin/x64/<tfm>/
    $candidates = @(
        Get-ChildItem -Path $Root -Recurse -Filter 'App.exe' -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch '\\\.git\\' } |
            Sort-Object LastWriteTime -Descending
    )
    if ($candidates.Count -gt 0) { return $candidates[0].FullName }
    return $null
}

# -- Resolve a web entry page (#688: the web surface has no App.exe to capture) ------------
function Find-WebEntry {
    param([string]$Root)
    # Conventional entry points first (the web seed serves public/), else the newest index.html.
    foreach ($rel in 'public/index.html', 'index.html', 'src/index.html', 'dist/index.html', 'public/main.html') {
        $p = Join-Path $Root $rel
        if (Test-Path $p) { return (Resolve-Path $p).Path }
    }
    $c = Get-ChildItem -Path $Root -Recurse -Filter 'index.html' -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '\\(node_modules|\.git)\\' } |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($c) { return $c.FullName }
    return $null
}

function Find-Edge {
    $cmd = Get-Command msedge -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($p in "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe",
                   "C:\Program Files\Microsoft\Edge\Application\msedge.exe") {
        if (Test-Path $p) { return $p }
    }
    return $null
}

$resolvedExe = $AppExe
if (-not $resolvedExe) { $resolvedExe = Find-AppExe -Root $AppDir }

# -- Ensure output directory --------------------------------------------------
$outDir = Split-Path $OutPng -Parent
if ($outDir -and -not (Test-Path $outDir)) { New-Item -ItemType Directory -Force $outDir | Out-Null }

# ============================================================================
# TIER 1 -- Headless off-screen render
# ============================================================================
$tier1Ok = $false
if (-not $SkipTier1) {
    Write-Host "Tier 1: headless --render-to-file ..."
    if (-not $resolvedExe) {
        Write-Tier 1 "SKIP: App.exe not found under $AppDir"
    } elseif (-not (Test-Path $resolvedExe)) {
        Write-Tier 1 "SKIP: App.exe not found at $resolvedExe"
    } else {
        # Run App.exe --render-to-file <OutPng> under a hard timeout. Retry once:
        # a cold App.exe under memory/GPU pressure (e.g. the 30B coder still
        # resident at the post-merge [6/6] critique) can stall its first WinUI
        # compositor init past the timeout; the second attempt is warm and
        # typically completes in ~1s. This is the fix for the run-time capture
        # TIMEOUT that skipped the VLM critique on 2026-06-25.
        foreach ($attempt in 1, 2) {
            $outStdout = [System.IO.Path]::GetTempFileName()
            $outStderr = [System.IO.Path]::GetTempFileName()
            try {
                $proc = Start-Process -FilePath $resolvedExe -ArgumentList "--render-to-file", "`"$OutPng`"" `
                    -PassThru -NoNewWindow `
                    -RedirectStandardOutput $outStdout `
                    -RedirectStandardError  $outStderr `
                    -ErrorAction Stop
                $null = $proc.Handle
                $done = $proc.WaitForExit($Tier1TimeoutSec * 1000)
                if (-not $done) {
                    try { & taskkill.exe /PID $proc.Id /T /F *> $null } catch {}
                    try { $null = $proc.WaitForExit(3000) } catch {}
                    Write-Tier 1 "TIMEOUT after ${Tier1TimeoutSec}s (attempt $attempt/2)"
                } else {
                    $stdout = (Get-Content $outStdout -Raw -ErrorAction SilentlyContinue) ?? ''
                    $stderr = (Get-Content $outStderr -Raw -ErrorAction SilentlyContinue) ?? ''
                    if ($proc.ExitCode -eq 0 -and (Test-Path $OutPng) -and (Get-Item $OutPng).Length -gt 0) {
                        # Verify it is a real PNG (magic bytes: 89 50 4E 47)
                        $magic = [System.IO.File]::ReadAllBytes($OutPng) | Select-Object -First 4
                        if ($magic[0] -eq 0x89 -and $magic[1] -eq 0x50 -and $magic[2] -eq 0x4E -and $magic[3] -eq 0x47) {
                            Write-Tier 1 "SUCCESS: $($stdout.Trim())"
                            $tier1Ok = $true
                        } else {
                            Write-Tier 1 "FAIL: output file is not a valid PNG (attempt $attempt/2)"
                        }
                    } else {
                        $detail = if ($stderr.Trim()) { $stderr.Trim() } else { "exit=$($proc.ExitCode)" }
                        Write-Tier 1 "FAIL: $detail (attempt $attempt/2)"
                    }
                }
            } catch {
                Write-Tier 1 "FAIL: could not launch: $($_.Exception.Message) (attempt $attempt/2)"
            } finally {
                Remove-Item $outStdout, $outStderr -Force -ErrorAction SilentlyContinue
            }
            if ($tier1Ok) { break }
        }
        if (-not $tier1Ok) { Write-Tier 1 "all attempts failed -> fall through to tier 2" }
    }
}

if ($tier1Ok) {
    $dim = ''
    try {
        Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue
        $img = [System.Drawing.Image]::FromFile($OutPng)
        $dim = "$($img.Width)x$($img.Height)"; $img.Dispose()
    } catch {}
    # Write-Output for machine-parseable result (goes to pipeline/capture); Write-Host for console color.
    Write-Output "CAPTURE-OK: $OutPng $dim tier=1"
    Write-Host   "CAPTURE-OK: $OutPng $dim tier=1" -ForegroundColor Green
    exit 0
}

# ============================================================================
# TIER 2 -- Foreground window capture
# ============================================================================
$tier2Ok = $false
if (-not $SkipTier2) {
    Write-Host "Tier 2: foreground window capture ..."
    if (-not $resolvedExe) {
        Write-Tier 2 "SKIP: App.exe not found"
    } elseif (-not (Test-Path $resolvedExe)) {
        Write-Tier 2 "SKIP: App.exe not found at $resolvedExe"
    } else {
        $t2Script = Join-Path $ScriptDir 'capture-app-foreground.ps1'
        if (-not (Test-Path $t2Script)) {
            Write-Tier 2 "SKIP: capture-app-foreground.ps1 not found alongside this script"
        } else {
            try {
                $t2Out = & $t2Script -AppExe $resolvedExe -OutPng $OutPng `
                    -LaunchTimeoutSec $Tier2LaunchTimeoutSec -SettleSec $Tier2SettleSec 2>&1
                $t2ExitCode = $LASTEXITCODE
                if ($t2ExitCode -eq 0 -and (Test-Path $OutPng) -and (Get-Item $OutPng).Length -gt 0) {
                    Write-Tier 2 "SUCCESS: $($t2Out | Select-Object -Last 1)"
                    $tier2Ok = $true
                } else {
                    $detail = ($t2Out | Where-Object { $_ -match 'CAPTURE-FAIL' } | Select-Object -Last 1) ?? 'unknown error'
                    Write-Tier 2 "FAIL: $detail -> fall through to tier 3"
                }
            } catch {
                Write-Tier 2 "FAIL: $($_.Exception.Message) -> fall through to tier 3"
            }
        }
    }
}

if ($tier2Ok) {
    $dim = ''
    try {
        Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue
        $img = [System.Drawing.Image]::FromFile($OutPng)
        $dim = "$($img.Width)x$($img.Height)"; $img.Dispose()
    } catch {}
    Write-Output "CAPTURE-OK: $OutPng $dim tier=2"
    Write-Host   "CAPTURE-OK: $OutPng $dim tier=2" -ForegroundColor Green
    exit 0
}

# ============================================================================
# TIER WEB -- Headless browser render of a web app (#688)
# ============================================================================
# A web project (index.html, no App.exe) has no WinUI window to capture, so before #688 every
# web dispatch fell through to the structural floor and the VLM design critique was SKIPPED --
# the design loop was blind on the primary surface. Render the entry page off-screen with
# headless Edge (--headless=new needs its own --user-data-dir) into a PNG the VLM can judge.
# file:// renders the static layout/theme/colours the critique cares about (server-fetched data
# does not run, but the look does). Fails soft -> falls through to the structural floor.
$webOk = $false
if (-not $resolvedExe) {
    $indexHtml = Find-WebEntry -Root $AppDir
    if ($indexHtml) {
        Write-Host "Tier web: headless Edge render of $indexHtml ..."
        $edge = Find-Edge
        if (-not $edge) {
            Write-Tier web "SKIP: msedge.exe not found"
        } else {
            $edgeProfile = Join-Path ([System.IO.Path]::GetTempPath()) ("edge-capture-" + [guid]::NewGuid().ToString('N'))
            $uri = "file:///" + ($indexHtml -replace '\\', '/')
            try {
                # ARG ORDER + FLAGS ARE LOAD-BEARING (pinned empirically 2026-06-26): msedge
                # --screenshot SILENTLY no-ops (exit 0, NO PNG written) when --hide-scrollbars is
                # present OR when --window-size precedes --screenshot. The prior invocation had BOTH,
                # so the web design-loop NEVER produced pixels -- it fell through to the WinUI
                # structural floor on every web dispatch, even with the GPU fully free (this is the
                # real cause of the "msedge silently fails" symptom, NOT GPU contention). A working
                # shot requires NO --hide-scrollbars AND --screenshot BEFORE --window-size. Variants
                # A/E/F (either condition violated) wrote 0 bytes; B/D (both satisfied) wrote ~140 KB.
                $proc = Start-Process -FilePath $edge -ArgumentList @(
                    "--headless=new", "--disable-gpu", "--no-sandbox",
                    "--user-data-dir=$edgeProfile",
                    "--screenshot=$OutPng", "--window-size=1280,900", $uri
                ) -PassThru -NoNewWindow -ErrorAction Stop
                $null = $proc.Handle
                # msedge's LAUNCHER process exits ~immediately after handing the screenshot to a
                # DETACHED worker that writes the PNG ASYNCHRONOUSLY (pinned 2026-06-26: the file
                # materialized ~4s AFTER WaitForExit returned exit 0, with no existing Edge instance).
                # So waiting on the process and checking the file immediately ALWAYS missed it ->
                # every web capture fell to the structural floor (the real cause of "msedge silently
                # fails"). POLL for the PNG to appear + be a valid (non-truncated) PNG, up to the
                # timeout, instead of trusting process exit.
                $deadlineMs = $WebTimeoutSec * 1000
                $swWeb = [System.Diagnostics.Stopwatch]::StartNew()
                while ($swWeb.ElapsedMilliseconds -lt $deadlineMs) {
                    if ((Test-Path $OutPng) -and (Get-Item $OutPng).Length -gt 100) {
                        try {
                            $magic = [System.IO.File]::ReadAllBytes($OutPng) | Select-Object -First 4
                            if ($magic.Count -ge 4 -and $magic[0] -eq 0x89 -and $magic[1] -eq 0x50 -and $magic[2] -eq 0x4E -and $magic[3] -eq 0x47) { $webOk = $true; break }
                        } catch { }   # file locked mid-write -> keep polling
                    }
                    Start-Sleep -Milliseconds 300
                }
                # Best-effort reap of the launcher + worker tree for this one-shot capture.
                try { & taskkill.exe /PID $proc.Id /T /F *> $null } catch {}
                if (-not $webOk) { Write-Tier web "FAIL: no screenshot within ${WebTimeoutSec}s -> fall through to tier 3" }
            } catch {
                Write-Tier web "FAIL: $($_.Exception.Message) -> fall through to tier 3"
            }
        }
    }
}

if ($webOk) {
    $dim = ''
    try {
        Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue
        $img = [System.Drawing.Image]::FromFile($OutPng); $dim = "$($img.Width)x$($img.Height)"; $img.Dispose()
    } catch {}
    Write-Output "CAPTURE-OK: $OutPng $dim tier=web"
    Write-Host   "CAPTURE-OK: $OutPng $dim tier=web" -ForegroundColor Green
    exit 0
}

# ============================================================================
# TIER 3 -- Structural/static check (floor, never-block)
# ============================================================================
Write-Host "Tier 3: structural/static check (floor) ..."
$t3Script = Join-Path $ScriptDir 'check-design-structural.ps1'
$structJsonPath = "$OutPng.json"

if (-not (Test-Path $t3Script)) {
    # The structural check script is missing -- last resort: emit a minimal error JSON.
    $fallback = @{ notes = "Tier 3 script not found at $t3Script; no signals available"; seed_only = $false; has_image_assets = $false } | ConvertTo-Json -Compress
    Set-Content -Path $structJsonPath -Value $fallback -Encoding UTF8
    Write-Tier 3 "check-design-structural.ps1 not found; wrote minimal fallback JSON"
} else {
    try {
        & $t3Script -AppDir $AppDir -OutJson $structJsonPath 2>&1 | ForEach-Object { Write-Tier 3 $_ }
    } catch {
        $fallback = @{ notes = "Tier 3 structural check threw: $($_.Exception.Message)"; seed_only = $false } | ConvertTo-Json -Compress
        Set-Content -Path $structJsonPath -Value $fallback -Encoding UTF8
    }
}

Write-Output "STRUCTURAL_ONLY"
Write-Host   "STRUCTURAL_ONLY" -ForegroundColor Yellow
Write-Output "  JSON: $structJsonPath"
Write-Host   "  JSON: $structJsonPath" -ForegroundColor Yellow
exit 0
