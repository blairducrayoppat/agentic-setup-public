# Start the local AI model server with ONE resident model (the swap mechanism).
# Novice-friendly: checks memory first; if there isn't enough, it shows what is
# using RAM and OFFERS to close things (always asks, closes gracefully so apps
# can prompt you to save). Nothing is ever closed without your y/n.
#
# Usage (or just double-click the .cmd launchers on the Desktop):
#   .\start-llm.ps1 -Model coder-30b     # deep coding  (needs ~21 GB free)
#   .\start-llm.ps1 -Model qwen3-14b     # everyday     (needs ~13 GB free)
#   .\start-llm.ps1 -Model vision        # screenshots  (needs ~10 GB free)
#   -Force skips all prompts (for automation).
# Endpoint when READY:  http://127.0.0.1:8000/v3   (OpenAI-compatible)
# Server output is captured to agentic-setup\state\logs\ovms-<model>-<stamp>.*.log
param(
    [Parameter(Mandatory)][ValidateSet('coder-30b','qwen3-14b','vision')]
    [string]$Model,
    [switch]$Force,
    [switch]$GuidedGen
)
$ErrorActionPreference = 'Stop'
$Ovms     = 'C:\ovms\ovms.exe'
$Setup    = 'C:\Users\mrbla\agentic-setup'
$StateDir = Join-Path $Setup 'state'
$LogDir   = Join-Path $StateDir 'logs'
# NOTE (#747): a #740/W7 attempt to add OVMS `--cache_dir` (compiled-model cache) was REVERTED
# 2026-07-05 — on the continuous-batching LLM servable OVMS folds it into the plugin_config JSON as
# CACHE_DIR, and the Windows backslash path made that JSON invalid ("Plugin config is in wrong
# format"), so the 30B refused to load in the live-verify. The compile-cache optimisation is re-scoped
# to #747 (correct mechanism + forward-slash/escaped path, tested against a live OVMS start first).
$StoppedVms = Join-Path $StateDir 'stopped-vms.txt'
New-Item -ItemType Directory -Force $StateDir, $LogDir | Out-Null
if (-not (Test-Path $Ovms)) { throw "OVMS not found at $Ovms - run 02-install-ovms-and-models.ps1 first." }

# One-time migrations: legacy %TEMP% flag (Storage Sense purges %TEMP%) + stray root logs
$LegacyFlag = Join-Path $env:TEMP 'agentic-blarai-vm-stopped.flag'
if (Test-Path $LegacyFlag) {
    if (-not (Test-Path $StoppedVms) -or -not (Select-String -Path $StoppedVms -Pattern 'BlarAI-Orchestrator' -Quiet)) {
        Add-Content $StoppedVms 'BlarAI-Orchestrator'
    }
    Remove-Item $LegacyFlag -ErrorAction SilentlyContinue
}
Get-ChildItem "$Setup\ovms-*.log" -ErrorAction SilentlyContinue | Move-Item -Destination $LogDir -Force -ErrorAction SilentlyContinue
& "$PSScriptRoot\sync-harness.ps1"   # record any live-harness drift in git history

# Ask: Read-Host that degrades gracefully when no console input exists.
# Returns $null when input is impossible (automation), '' when user pressed Enter.
function Ask([string]$Prompt) {
    if ($Force) { return $null }
    try { return (Read-Host $Prompt) } catch { return $null }
}
function Get-AvailableGB {
    try { return [math]::Round((Get-Counter '\Memory\Available MBytes').CounterSamples[0].CookedValue / 1024, 1) }
    catch { return [math]::Round((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1MB, 1) }
}
function Find-OvDir([string[]]$candidates) {
    foreach ($c in $candidates) {
        if (Test-Path $c) {
            $xml = Get-ChildItem $c -Recurse -Filter 'openvino_model.xml' -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($xml) { return $xml.DirectoryName }
        }
    }
    return $null
}

# Parser values VALIDATED on OVMS 2026.2 (2026-06-10): 'qwen3' is NOT a valid
# tool_parser; Qwen3 (thinking) uses hermes3. qwen3coder is the dedicated
# parser for the Qwen3-Coder XML format. 'qwen3' IS valid as reasoning_parser.
switch ($Model) {
    'coder-30b' {
        $path  = Find-OvDir @('C:\models\coder-30b')
        $name  = 'coder-30b'
        $label = 'Qwen3-Coder-30B (deep coding)'
        # --enable_tool_guided_generation REQUIRES an explicit value; u8 KV halves cache RAM (64k ctx)
        $extra = @('--tool_parser','qwen3coder','--enable_tool_guided_generation','true','--kv_cache_precision','u8','--enable_prefix_caching','true')
        # OpenVINO 2026.2 known limitation: Qwen3-MoE (this 30B-A3B) in INT4 on the GPU can
        # lose accuracy on LONG prompts (the coding agent's repo-context case). The documented
        # workaround disables the micro-GEMM prefill transform (slight TTFT cost only). It is an
        # ENV var, not a CLI flag, so the inherited OVMS process below picks it up.
        # Added 2026-06-29 (BlarAI OpenVINO 2026.2 upgrade, §5 candidate A4). Measure the TTFT delta.
        $env:MOE_USE_MICRO_GEMM_PREFILL = '0'
        $needGB = 20   # was 21; #777 measured 2026-07-09 — clean READY from 19.85 GiB, no storm (see blarai PERFORMANCE_LOG)
    }
    'qwen3-14b' {
        $path  = Find-OvDir @('C:\models\qwen3-14b', 'C:\Users\mrbla\BlarAI\models\qwen3-14b')
        $name  = 'qwen3-14b'
        $label = 'Qwen3-14B (everyday)'
        $extra = @('--tool_parser','hermes3','--reasoning_parser','qwen3','--kv_cache_precision','u8','--enable_prefix_caching','true')
        # OPT-IN guardrail (default OFF): XGrammar-constrain tool calls to schema-valid
        # form like coder-30b does (closes the malformed-tool-call class on the fleet's
        # default model). UNPROVEN with this model's reasoning_parser (grammar + thinking
        # can interact badly upstream), so validate with test-guided-gen.ps1 BEFORE relying
        # on it overnight, then pass -GuidedGen. Back out = just drop the switch.
        if ($GuidedGen) { $extra += @('--enable_tool_guided_generation', 'true') }
        $needGB = 13
    }
    'vision' {
        $path  = Find-OvDir @('C:\models\qwen3-vl-8b', 'C:\Users\mrbla\BlarAI\models\qwen3-vl-8b-instruct')
        $name  = 'qwen3-vl-8b'
        $label = 'Qwen3-VL-8B (screenshots)'
        $extra = @()
        $needGB = 10   # 6GB weights + KV cache headroom
    }
}
if (-not $path) { throw "Model files for '$Model' not found. Run 02-install-ovms-and-models.ps1 (or uncomment its optional downloads)." }

# Port pre-flight: something non-OVMS on 8000 would cause a misleading failure (or a false READY)
$listener = Get-NetTCPConnection -LocalPort 8000 -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
if ($listener) {
    $owner = Get-Process -Id $listener.OwningProcess -ErrorAction SilentlyContinue
    if ($owner -and $owner.Name -ne 'ovms') {
        throw "Port 8000 is in use by '$($owner.Name)' (PID $($owner.Id)) which is NOT the model server. Close that program (or reboot) and try again."
    }
}

# The currently-loaded model's RAM comes back when we stop it - count the right amount per model.
$residentGB = @{ 'coder-30b' = 18; 'qwen3-14b' = 10; 'qwen3-vl-8b' = 6 }
$reclaimFromOvms = 0
if (Get-Process ovms -ErrorAction SilentlyContinue) {
    $cur = $null
    try {
        $r = Invoke-WebRequest 'http://127.0.0.1:8000/v3/models' -TimeoutSec 3 -UseBasicParsing
        $cur = (($r.Content | ConvertFrom-Json).data | Select-Object -First 1).id
    } catch {}
    $reclaimFromOvms = if ($cur -and $residentGB.ContainsKey($cur)) { $residentGB[$cur] } else { 6 }
}

# ---------------- Memory assistant ----------------
if (-not $Force) {
    while ($true) {
        $avail = (Get-AvailableGB) + $reclaimFromOvms
        if ($avail -ge $needGB) { break }
        $shortfall = [math]::Round($needGB - $avail, 1)

        Write-Host ""
        Write-Host ("Loading {0} needs ~{1} GB available; you have ~{2} GB (about {3} GB short)." -f $label, $needGB, $avail, $shortfall) -ForegroundColor Yellow
        Write-Host "Here's what's using memory that you could close (SAVE YOUR WORK in them first):" -ForegroundColor Yellow

        $menu = @()
        $vm = Get-VM -Name 'BlarAI-Orchestrator' -ErrorAction SilentlyContinue
        if ($vm -and $vm.State -eq 'Running') {
            $menu += [pscustomobject]@{ Kind='vm'; Name='BlarAI assistant VM'; GB=2.0 }
        }
        $excluded = @('ovms','pwsh','powershell','WindowsTerminal','conhost','cmd','explorer','dwm',
                      'TextInputHost','ApplicationFrameHost','SystemSettings','TabTip','ShellExperienceHost')
        $apps = Get-Process |
            Where-Object { $_.Id -ne $PID } |
            Group-Object Name |
            ForEach-Object {
                [pscustomobject]@{
                    Kind = 'app'; Name = $_.Name
                    GB = [math]::Round((($_.Group | Measure-Object WorkingSet64 -Sum).Sum) / 1GB, 1)
                    HasWindow = ($_.Group | Where-Object { $_.MainWindowTitle }).Count -gt 0
                }
            } |
            Where-Object { $_.HasWindow -and $_.GB -ge 0.3 -and ($excluded -notcontains $_.Name) } |
            Sort-Object GB -Descending | Select-Object -First 7
        $menu += $apps

        if (-not $menu) {
            Write-Host "No obvious apps to close. Re-check after closing things yourself, or Continue anyway." -ForegroundColor Yellow
        }
        for ($i = 0; $i -lt $menu.Count; $i++) {
            Write-Host ("  [{0}] Close {1}   (frees ~{2} GB)" -f ($i+1), $menu[$i].Name, $menu[$i].GB)
        }
        Write-Host "  [R] Re-check memory    [C] Continue anyway (may freeze the machine)    [Q] Quit"
        $choice = Ask "Pick an option"

        if ($null -eq $choice) {
            Write-Host "No console input available - continuing without the assistant." -ForegroundColor Yellow
            break
        }
        elseif ($choice -match '^[Qq]$') {
            Write-Host "Nothing was loaded. Run this again when ready."
            exit 0
        }
        elseif ($choice -match '^[Cc]$') {
            Write-Host "Continuing despite low memory - if the machine crawls, close apps or reboot." -ForegroundColor Red
            break
        }
        elseif ($choice -match '^[Rr]$') {
            continue
        }
        elseif ($choice -match '^\d+$') {
            $idx = [int]$choice - 1
            if ($idx -lt 0 -or $idx -ge $menu.Count) { Write-Host "Not a valid number."; continue }
            $item = $menu[$idx]
            if ($item.Kind -eq 'vm') {
                $ok = Ask "Stop the BlarAI assistant VM? It can be restarted later; this script will offer to. (y/N)"
                if ($ok -eq 'y') {
                    Stop-VM -Name 'BlarAI-Orchestrator'
                    if (-not (Test-Path $StoppedVms) -or -not (Select-String -Path $StoppedVms -Pattern 'BlarAI-Orchestrator' -Quiet)) {
                        Add-Content $StoppedVms 'BlarAI-Orchestrator'
                    }
                    Write-Host "BlarAI VM stopped (the restart offer is remembered until you accept it)." -ForegroundColor Green
                }
            } else {
                $ok = Ask "Close $($item.Name)? Save any work in it FIRST. (y/N)"
                if ($ok -eq 'y') {
                    Get-Process -Name $item.Name -ErrorAction SilentlyContinue |
                        Where-Object { $_.MainWindowTitle } |
                        ForEach-Object { $null = $_.CloseMainWindow() }
                    Start-Sleep -Seconds 5
                    $left = Get-Process -Name $item.Name -ErrorAction SilentlyContinue
                    if ($left) {
                        $forceClose = Ask "$($item.Name) is still running (it may be asking you to save). Force-close it? Unsaved work WILL be lost. (y/N)"
                        if ($forceClose -eq 'y') { $left | Stop-Process -Force }
                    }
                }
            }
            continue
        }
        else {
            Write-Host "Not a valid option."
            continue
        }
    }
}

# ---------------- Stop old model, start the new one ----------------
Remove-Item "$StateDir\server-should-run.txt" -ErrorAction SilentlyContinue   # watchdog stands down during the swap
Get-Process ovms -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 2

# Flags VALIDATED against OVMS 2026.2 on this machine (2026-06-10):
#   --model_path <dir>    local OpenVINO IR model (--source_model is HF-pull mode ONLY)
#   --model_name          served name (= model id in opencode.json / openclaw.json)
#   --rest_bind_address 127.0.0.1  REQUIRED - OVMS defaults to 0.0.0.0 (all interfaces)!
#   --cache_size 4        KV-cache POOL size in GB (runtime attention cache) -- NOT the compile cache.
#   --cache_dir <dir>     COMPILED-MODEL on-disk cache (#747). OVMS folds this into the CB LLM node's
#                         plugin_config JSON as CACHE_DIR. The #740/W7 revert was a PATH-FORMAT bug, not
#                         a mechanism bug: a Windows BACKSLASH path (C:\Users\...) makes the folded JSON
#                         invalid (\U is not a valid JSON escape -> "Plugin config is in wrong format").
#                         A FORWARD-SLASH path folds into valid JSON (docs example: --cache_dir
#                         /models/.ov_cache). On GPU the cache is compiled kernels (.cl_cache), reused
#                         across restarts for the same OVMS version/device/model/shape -> ~30-90s saved
#                         per swap. Shared dir is safe (files are keyed per model). Live-tested against a
#                         coder-30b start before merge (#747 non-negotiable).
$ModelCacheDir = ((Join-Path $StateDir 'ovms-model-cache') -replace '\\','/')
New-Item -ItemType Directory -Force $ModelCacheDir | Out-Null
$args2 = @('--rest_port','8000','--rest_bind_address','127.0.0.1','--model_path',$path,'--model_name',$name,
           '--task','text_generation','--target_device','GPU','--cache_size','4',
           '--cache_dir',$ModelCacheDir) + $extra

# Dated server logs (rotated, keep newest 20) - these ARE the diagnostics when something dies later
Get-ChildItem $LogDir -Filter 'ovms-*.log' -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -Skip 20 |
    Remove-Item -ErrorAction SilentlyContinue
$stamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
$OutLog = Join-Path $LogDir "ovms-$Model-$stamp.out.log"
$ErrLog = Join-Path $LogDir "ovms-$Model-$stamp.err.log"

Write-Host ""
Write-Host "Starting $label ... (~15s on a warm compile cache; up to ~5 min COLD — the first load after install or an OVMS upgrade compiles + writes the .cl_cache, #747)" -ForegroundColor Cyan
# -WindowStyle Hidden (2026-07-08, LA-requested; the #761/lesson-219 sweep's
# console-children rule): OVMS is a non-interactive console server with stdout+
# stderr fully file-redirected — its window carried nothing and was one
# accidental click from killing a live dispatch. Hidden ONLY because it is not
# a TUI: NEVER hide the BlarAI launcher (Textual crashes on a hidden console).
$proc = Start-Process -FilePath $Ovms -ArgumentList $args2 -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput $OutLog -RedirectStandardError $ErrLog

function Show-LogTail {
    $tailFile = if ((Test-Path $ErrLog) -and (Get-Item $ErrLog).Length -gt 0) { $ErrLog } else { $OutLog }
    Write-Host "--- last 15 lines of the server log ---" -ForegroundColor Yellow
    Get-Content $tailFile -Tail 15 -ErrorAction SilentlyContinue
    Write-Host "Full log: $tailFile" -ForegroundColor Yellow
}

# 480s (not 240): a COLD compile-cache load measured ~289s live (#747 — first compile +
# writing ~15 GB of .cl_cache); 240 threw on it even though the model loaded fine. A WARM
# load is ~12s, far under this. The ceiling only matters cold (first install / OVMS upgrade).
$deadline = (Get-Date).AddSeconds(480)
do {
    Start-Sleep -Seconds 3
    try {
        $resp = Invoke-WebRequest 'http://127.0.0.1:8000/v3/models' -TimeoutSec 3 -UseBasicParsing
        $ids = @((($resp.Content | ConvertFrom-Json).data) | ForEach-Object { $_.id })
        if ($ids -contains $name) {
            Set-Content "$StateDir\server-should-run.txt" $Model   # arm the watchdog for THIS model
            Write-Host "READY: $name is now loaded. (Watchdog armed: auto-restart if it dies.)" -ForegroundColor Green
            Write-Host "Double-click 'Open Coding Chat' to start coding (it picks this model automatically)." -ForegroundColor Green

            # --- Tool-call repair proxy (qwen-proxy) ---------------------------------
            # OpenCode points at http://127.0.0.1:8099 (see opencode.json); this proxy
            # forwards to OVMS and repairs Qwen3-Coder-30B's multi-turn tool-call format
            # (transparent passthrough for the other models). Started once; it is
            # stateless and survives model swaps, so we only start it if 8099 is free.
            $proxyUp = Get-NetTCPConnection -LocalPort 8099 -State Listen -ErrorAction SilentlyContinue
            if ($proxyUp) {
                Write-Host "Tool-call fixer already running on http://127.0.0.1:8099." -ForegroundColor Green
            } else {
                $proxyPy = Join-Path $Setup 'tools\qwen-proxy.py'
                if (Test-Path $proxyPy) {
                    $py = (Get-Command pythonw -ErrorAction SilentlyContinue).Source
                    if (-not $py) { $py = (Get-Command python -ErrorAction SilentlyContinue).Source }
                    if ($py) {
                        try {
                            Start-Process -FilePath $py -ArgumentList $proxyPy `
                                -WorkingDirectory (Join-Path $Setup 'tools') -WindowStyle Hidden | Out-Null
                            Write-Host "Tool-call fixer started on http://127.0.0.1:8099 (the coding agent talks to it)." -ForegroundColor Green
                        } catch {
                            Write-Host "Could not auto-start the tool-call fixer ($($_.Exception.Message)); double-click tools\start-coding-proxy.cmd." -ForegroundColor Yellow
                        }
                    } else {
                        Write-Host "Python not on PATH; double-click tools\start-coding-proxy.cmd to start the tool-call fixer." -ForegroundColor Yellow
                    }
                }
            }
            # -------------------------------------------------------------------------

            # Offer to restart VMs this tool stopped earlier (names removed ONLY when restarted)
            if ($Model -ne 'coder-30b' -and (Test-Path $StoppedVms)) {
                $vmNames = @(Get-Content $StoppedVms | Where-Object { $_ })
                $remaining = @()
                foreach ($vmName in $vmNames) {
                    $vm = Get-VM -Name $vmName -ErrorAction SilentlyContinue
                    if ($vm -and $vm.State -ne 'Running') {
                        $back = Ask "Earlier I stopped the '$vmName' VM. Start it again now? (y/N)"
                        if ($back -eq 'y') { Start-VM -Name $vmName; Write-Host "$vmName starting." -ForegroundColor Green }
                        else { $remaining += $vmName }   # keep the offer for next time
                    }
                }
                if ($remaining.Count -gt 0) { Set-Content $StoppedVms $remaining } else { Remove-Item $StoppedVms -ErrorAction SilentlyContinue }
            }
            exit 0
        } elseif ($ids.Count -eq 0) {
            Write-Host "  server is up, model still loading..."
        } else {
            Write-Host "  a server answered but with the wrong model ($($ids -join ',')) - still waiting..." -ForegroundColor Yellow
        }
    } catch { Write-Host "  loading..." }
    if ($proc.HasExited) {
        Show-LogTail
        throw "The model server exited (code $($proc.ExitCode)). NOTE: your previous model was already stopped - double-click a model launcher to load one."
    }
} while ((Get-Date) -lt $deadline)
Show-LogTail
throw "The model server did not become ready in 480s. NOTE: your previous model was already stopped - double-click a model launcher to retry."
