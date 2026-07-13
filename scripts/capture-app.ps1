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
    # Search common build-output paths: bin/x64/<tfm>/win-x64/ and bin/x64/<tfm>/.
    # EXCLUDE node_modules (mirrors Find-WebEntry below): a WEB surface has no WinUI App.exe of
    # its own, but its dependency tree can ship a stray binary literally named App.exe. Found
    # LIVE 2026-07-06: a node_modules\...\App.exe made this return a false positive, which
    # SKIPPED the headless web tier AND drove Tier 2 to LAUNCH + SetForegroundWindow that
    # arbitrary binary -- an unattended screen-take + arbitrary-exec of a dependency binary,
    # then a blind structural floor. Excluding node_modules makes a web project route
    # deterministically to the headless web tier (the unattended-safe path).
    $candidates = @(
        Get-ChildItem -Path $Root -Recurse -Filter 'App.exe' -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch '\\(node_modules|\.git)\\' } |
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

# -- Resolve the app's real server entry, if one exists (#772) -----------------------------
function Find-WebServerEntry {
    param([string]$Root, [string]$IndexHtml)
    # The fleet web seed is src/server.js honoring $env:PORT (node built-ins
    # only, no npm install). Walk up from index.html to the dir holding
    # package.json (public/ lives beside src/), capped at the capture root.
    $dir = Split-Path -Parent $IndexHtml
    for ($i = 0; $i -lt 3 -and $dir -and ($dir.Length -ge $Root.Length); $i++) {
        if (Test-Path (Join-Path $dir 'package.json')) {
            foreach ($rel in 'src/server.js', 'server.js') {
                $srv = Join-Path $dir $rel
                if (Test-Path $srv) { return @{ Root = $dir; Server = (Resolve-Path $srv).Path } }
            }
            return $null   # package.json but no known server entry -> static fallback
        }
        $dir = Split-Path -Parent $dir
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
#
# THE CAPTURE MUST SERVE THE APP, NOT file:// IT (#772, proven 2026-07-09): browsers block
# <script type="module"> entirely over file:// (CORS, origin null) -- not just data fetches,
# the whole client never executes. The fleet's own web seed is "type":"module", so under
# file:// every module-JS app screenshots as a dead shell ("Loading...", flat pixels) and no
# design fix the coder makes can ever become visible -- B5 attempt-4 STALLED [VERIFY] on
# exactly this while the same merged code rendered fully over its real node server. So: start
# the app's server on an ephemeral port, capture http://127.0.0.1:<port>/, ALWAYS kill the
# server tree after (#773 class). file:// remains ONLY the fallback for genuinely static
# pages (no server entry), where it renders fine. Fails soft -> structural floor.
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
            $uri = "file:///" + ($indexHtml -replace '\\', '/')   # static-page fallback
            $srvProc = $null
            $serveInfo = Find-WebServerEntry -Root $AppDir -IndexHtml $indexHtml
            if ($serveInfo) {
                # Ephemeral port, never the seed default 3000 -- an orphaned job
                # server may still hold it (#773) and would serve the WRONG app.
                # The port must be VERIFIED FREE before the spawn: a standing
                # listener in the range (Vikunja lives on 3456) would kill node
                # on bind while the TCP probe happily connects to the squatter
                # and the shot captures the WRONG app -- worse than no shot.
                $port = 0
                foreach ($cand in (Get-Random -Minimum 3400 -Maximum 3999 -Count 20)) {
                    try {
                        $l = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $cand)
                        $l.Start(); $l.Stop(); $port = $cand; break
                    } catch { }
                }
                try {
                    if ($port -eq 0) { throw "no free port found in 3400-3999" }
                    $srvProc = Start-Process node -ArgumentList ('"' + $serveInfo.Server + '"') `
                        -WorkingDirectory $serveInfo.Root -WindowStyle Hidden -PassThru `
                        -Environment @{ PORT = "$port" } -ErrorAction Stop
                    $dlSrv = (Get-Date).AddSeconds(10)
                    $srvUp = $false
                    while ((Get-Date) -lt $dlSrv) {
                        if ($srvProc.HasExited) { break }   # crashed (bad entry, bind fail) -> fallback
                        try {
                            $probe = [System.Net.Sockets.TcpClient]::new()
                            $probe.Connect('127.0.0.1', $port); $probe.Close(); $srvUp = $true; break
                        } catch { Start-Sleep -Milliseconds 300 }
                    }
                    # Belt over the pre-check's braces: the answering socket only
                    # counts if OUR server is the thing still alive behind it.
                    if ($srvUp -and $srvProc.HasExited) { $srvUp = $false }
                    if ($srvUp) {
                        $uri = "http://127.0.0.1:$port/"
                        Write-Host "Tier web: serving $($serveInfo.Server) on :$port -- capturing the LIVE app"
                    } else {
                        Write-Tier web "app server did not come up in 10s -> file:// static fallback"
                    }
                } catch {
                    Write-Tier web "app server spawn failed ($($_.Exception.Message)) -> file:// static fallback"
                }
            }
            try {
                # ---- H8/H9 (#823): CDP console-capturing helper FIRST, msedge --screenshot fallback ----
                # capture-web-cdp.mjs drives Edge over the DevTools Protocol, so it captures the browser
                # console + uncaught exceptions (PROTOCOL events a page cannot suppress) AND runs a positive
                # behavior smoke, writing "$OutPng.console.json" beside the PNG. That is the runtime-error
                # channel the msedge --screenshot one-shot could never carry (B5n2: the thrown JS error sat
                # unread in the console). If node or the helper is unavailable/fails, we FALL BACK to the
                # proven --screenshot path and stamp a captured:false sidecar so the design loop degrades to
                # today's pixel-only behavior WITHOUT faking a richer verdict (the ok-flag discipline).
                $sidecar = "$OutPng.console.json"
                $cdpOk = $false
                $cdpScript = Join-Path $ScriptDir 'capture-web-cdp.mjs'
                $node = Get-Command node -ErrorAction SilentlyContinue
                if ($node -and (Test-Path $cdpScript)) {
                    try {
                        & $node.Source $cdpScript --url $uri --out $OutPng --console-out $sidecar `
                            --app-dir $AppDir --timeout-ms ($WebTimeoutSec * 1000) *> $null
                        if ($LASTEXITCODE -eq 0 -and (Test-Path $OutPng) -and (Get-Item $OutPng).Length -gt 100) {
                            $m = [System.IO.File]::ReadAllBytes($OutPng) | Select-Object -First 4
                            if ($m.Count -ge 4 -and $m[0] -eq 0x89 -and $m[1] -eq 0x50 -and $m[2] -eq 0x4E -and $m[3] -eq 0x47) {
                                $cdpOk = $true; $webOk = $true
                                Write-Tier web "CDP capture OK (protocol-level console + behavior smoke) -> $sidecar"
                            }
                        }
                    } catch { Write-Tier web "CDP helper threw: $($_.Exception.Message)" }
                    if (-not $cdpOk) { Write-Tier web "CDP console capture unavailable -> msedge --screenshot fallback (pixel-only)" }
                }

                if (-not $cdpOk) {
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
                # Honesty sidecar (#823 fail-soft): the --screenshot path captured NO console, so the
                # design loop must read captured:false and degrade to pixel-only -- never fake a runtime verdict.
                if ($webOk) {
                    try { '{"captured":false,"error":"cdp console capture unavailable (msedge --screenshot fallback)","console":[],"pageErrors":[],"findings":[]}' | Set-Content -Path $sidecar -Encoding UTF8 } catch {}
                }
                }
            } catch {
                Write-Tier web "FAIL: $($_.Exception.Message) -> fall through to tier 3"
            } finally {
                # The capture's OWN app server must never outlive the shot (#773):
                # kill its whole tree, whatever branch got us here.
                if ($srvProc -and -not $srvProc.HasExited) {
                    try { & taskkill.exe /PID $srvProc.Id /T /F *> $null } catch {}
                }
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
