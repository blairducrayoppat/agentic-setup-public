# Start the local AI model server with ONE resident model (the swap mechanism).
# Novice-friendly: checks memory first; if there isn't enough, it shows what is
# using RAM and OFFERS to close things (always asks, closes gracefully so apps
# can prompt you to save). Nothing is ever closed without your y/n.
#
# Usage (or just double-click the .cmd launchers on the Desktop):
#   .\start-llm.ps1 -Model coder-30b     # deep coding  (needs ~19 GB free)
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
        # KV pool + MoE expert offloading, MEASURED 2026-08-31 (#1477/#1484), coder ONLY.
        # 4 GB of pool = 87,381 tokens, which is what makes the 65,536+8,192 window in
        # opencode.json/model-profiles.json/openclaw.json5 hold WITHOUT the server evicting.
        # Offloading is what lets a 4 GB pool fit at all: weights 15.19 GiB + 4 GiB pool =
        # 19.19 GiB against a MEASURED 17.98 GiB budget, and offloading experts brings the
        # live figure to 15.7 GiB -- measured twice, 15.64 and 15.73, agreeing to 0.6%.
        # cache_size 2 without offload measured 18.04 and 18.18 GiB: OVER the budget, twice.
        # THROUGHPUT IS NOT THE REASON and must not be claimed as one. The same offload
        # config measured 16.55 tok/s and 11.82 tok/s an hour apart; between-pass variance
        # (40%) exceeds the between-config difference (12%), so no speed claim survives.
        # MEMORY and WINDOW are the reasons, and both replicate.
        # Only this model: qwen3-14b is dense, not MoE, so OFFLOAD_RATIO means nothing there.
        $cacheSizeGB  = '4'
        $offloadRatio = '30'
        # Lockstep with BlarAI's [fleet_dispatch].swap_min_free_gb — see that key's comment for
        # the full provenance. 19 is an LA DIRECTIVE (#1313, 2026-08-07), NOT a measurement: it
        # sits 0.85 GiB BELOW #777's measured-good 19.85 GiB ambient. The prior 20 was measured.
        $needGB = 19
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
        # Unchanged and deliberately so: a dense model with no experts to offload, and its
        # window is not what #1477 measured. Do not carry the coder's numbers across.
        $cacheSizeGB  = '2'
        $offloadRatio = $null
        $needGB = 13
    }
    'vision' {
        $path  = Find-OvDir @('C:\models\qwen3-vl-8b', 'C:\Users\mrbla\BlarAI\models\qwen3-vl-8b-instruct')
        $name  = 'qwen3-vl-8b'
        $label = 'Qwen3-VL-8B (screenshots)'
        $extra = @()
        $cacheSizeGB  = '2'
        $offloadRatio = $null
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
#                         PAIRED WITH --plugin_config OFFLOAD_RATIO ABOVE AND WITH THE CONTEXT
#                         WINDOW IN THREE OTHER FILES. Change one, change all four, and re-measure.
#
#                         THE POOL IS A TOKEN CEILING, not a speed knob. KV bytes/token at u8 for
#                         Qwen3-Coder-30B-A3B (48 layers, 4 KV heads, head_dim 128) = 2*48*4*128 =
#                         49,152, so:
#                             cache_size 1 -> 21,845 tokens
#                             cache_size 2 -> 43,690 tokens
#                             cache_size 3 -> 65,536 tokens
#                             cache_size 4 -> 87,381 tokens   <- HERE
#                         The declared window (opencode.json / model-profiles.json /
#                         openclaw.json5) is 65,536 + 8,192 = 73,728 -- 84% of the pool -- so the
#                         CLIENT compacts before the SERVER can evict. Never let the declared
#                         window exceed the pool: OVMS does not refuse an over-large request, it
#                         DIES, process gone and error log empty.
#
#                         WHY 4 FITS AT ALL, AND ONLY WITH OFFLOADING. Weights 15.19 GiB + a 4 GiB
#                         pool = 19.19 GiB against a MEASURED 17.98 GiB shared-GPU budget (dxdiag
#                         Display Memory -- NOT the 25.17 GiB the driver advertises, and NOT the
#                         15.66 GiB a 50%-of-RAM rule predicts; that figure was inferred from a web
#                         article, published as a root cause, and retracted the same day).
#                         Offloading experts brings the live figure to 15.7 GiB: measured twice,
#                         15.64 and 15.73, agreeing to 0.6%. Without offloading cache_size 2
#                         measured 18.04 and 18.18 GiB -- OVER the budget, also twice.
#
#                         THROUGHPUT IS NOT WHY, AND MUST NOT BE CLAIMED AS WHY. The identical
#                         offload config measured 16.55 tok/s (4 runs) and 11.82 tok/s (8 runs) an
#                         hour apart on an idle box. Between-pass variance for ONE config is ~40%;
#                         the gap between configs is ~12%. No speed claim survives that, in either
#                         direction. MEMORY and the WINDOW are the reasons, and both replicate.
#
#                         DO NOT QUOTE A SHORT PROBE AS CODER THROUGHPUT. Every historical figure
#                         (38.58 in June, "36-39", the "13x cliff") came from 128-256 token
#                         completions. Sustained realistic generation measures ~12 tok/s, and the
#                         June baseline this project anchored a whole investigation to was itself a
#                         256-token probe. Use scripts/measure_coder_sustained.py in the BlarAI
#                         repo: page-sized generations, continuous resource sampling, and DRIFT --
#                         drift is how an over-budget config reveals itself and a single sample
#                         cannot see it.
#
#                         WHY max_output_tokens STAYS AT 8192 rather than rising with the window:
#                         output is not what buys a longer session, context is. At ~12 tok/s an
#                         8,192-token reply already needs ~11 minutes of unbroken generation
#                         against a 600 s ACP idle breaker that cannot read a long file write as
#                         progress -- the exact shape that killed every candidate in the
#                         2026-08-31 00:39 dispatch. 16,384 would double that to ~23 minutes.
#
#                         STILL OPEN (#1477/#1485): why a 4 GB pool fitted on 2026-06-29 WITHOUT
#                         offloading, at the same model file, driver and reported GPU pool size.
#                         Not established. The resource envelope was never recorded, which is the
#                         durable lesson -- a version stamp is not a machine.
#   --cache_dir <dir>     COMPILED-MODEL on-disk cache (#747). OVMS folds this into the CB LLM node's
#                         plugin_config JSON as CACHE_DIR. The #740/W7 revert was a PATH-FORMAT bug, not
#                         a mechanism bug: a Windows BACKSLASH path (C:\Users\...) makes the folded JSON
#                         invalid (\U is not a valid JSON escape -> "Plugin config is in wrong format").
#                         A FORWARD-SLASH path folds into valid JSON (docs example: --cache_dir
#                         /models/.ov_cache). On GPU the cache is compiled kernels (.cl_cache), reused
#                         across restarts for the same OVMS version/device/model/shape -> ~30-90s saved
#                         per swap. Shared dir is safe (files are keyed per model). Live-tested against a
#                         coder-30b start before merge (#747 non-negotiable).
# #1484: the compiled-kernel cache lives on B:, NOT on C: beside the page file and the
# memory-mapped weights. C: measured 12.9 GB free of 951 GB (1%) with this cache holding
# 23.05 GiB of it; a cold compile could not complete and OVMS died silently, and the
# weights are mmap'd from that same starving volume. Overridable so a box without B:
# still works: BLARAI_OVMS_CACHE_DIR wins, else B: when present, else the old path.
$ModelCacheDir = if ($env:BLARAI_OVMS_CACHE_DIR) {
    $env:BLARAI_OVMS_CACHE_DIR -replace '\\','/'
} elseif (Test-Path 'B:\') {
    'B:/blarai/ovms-model-cache'
} else {
    ((Join-Path $StateDir 'ovms-model-cache') -replace '\\','/')
}
New-Item -ItemType Directory -Force $ModelCacheDir | Out-Null

# --cache_dir and --plugin_config CANNOT BOTH BE PASSED. On the continuous-batching LLM
# servable OVMS folds cache_dir INTO plugin_config as CACHE_DIR (#747), so supplying both
# yields "Plugin config is in wrong format" and the server dies during load with an EMPTY
# stderr -- observed 2026-08-31, twice, and it looks exactly like a model failure. So the
# cache directory now travels INSIDE the JSON, and --cache_dir is gone.
#
# THE BACKSLASHES ARE LOAD-BEARING. Start-Process -ArgumentList does not escape embedded
# double quotes, so a plain JSON string arrives at OVMS as {OFFLOAD_RATIO:30} -- not valid
# JSON, same fatal error. \" is what makes the child process receive a real quote. This was
# established by killing two measurement runs on it; do not "tidy" these away, and if you
# change this line, START THE SERVER and confirm it reaches AVAILABLE before committing.
$pluginJson = '{\"CACHE_DIR\":\"' + $ModelCacheDir + '\"'
if ($offloadRatio) { $pluginJson += ',\"OFFLOAD_RATIO\":\"' + $offloadRatio + '\"' }
$pluginJson += '}'

$args2 = @('--rest_port','8000','--rest_bind_address','127.0.0.1','--model_path',$path,'--model_name',$name,
           '--task','text_generation','--target_device','GPU','--cache_size',$cacheSizeGB,
           '--plugin_config',$pluginJson) + $extra

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
# #1497: the PYTHON-ENABLED OVMS build needs its own python DLLs on PATH, or ovms.exe dies at
# startup with STATUS_DLL_NOT_FOUND (0xC0000135) before writing a single log line -- an empty log
# and a dead server, which reads like anything at all.
#
# WHY THIS BUILD. The python_off package forces the MINJA chat-template engine (it is "the only
# option for builds without Python", per OVMS's own llm_calculator.proto), and OVMS 2026.3's
# release notes name Qwen3-Coder as one of exactly three templates MINJA CANNOT RENDER. Its docs
# are blunter still: "using tools is not supported in configuration without Python." So every
# coder run before 2026-09-01 rendered prior tool-call turns by dumping raw JSON into the prompt,
# which is the corruption qwen-proxy's xmlify_history was written to paper over. Measured on the
# swap: the SAME multi-turn conversation costs 439 prompt tokens under Minja and 380 under Jinja,
# and the startup warning "Minja cannot render this template's tool calls correctly" went 1 -> 0.
#
# Set on the PARENT so the child inherits it: a machine-wide PATH edit would be a shared-state
# change nobody asked for, and an env var set only in some other shell would not survive a reboot.
$ovmsPythonDir = Join-Path (Split-Path $Ovms -Parent) 'python'
if (Test-Path $ovmsPythonDir) {
    if (($env:PATH -split ';') -notcontains $ovmsPythonDir) {
        $env:PATH = "$ovmsPythonDir;$env:PATH"
    }
} else {
    Write-Host "NOTE: $ovmsPythonDir is absent - this looks like a python_off OVMS build. Tool calling is UNSUPPORTED on that build (OVMS docs) and multi-turn history will be corrupted; reinstall the python_on package. (#1497)" -ForegroundColor Yellow
}
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
            # READY is NOT announced here. The model is loaded, but the coding agent talks to the
            # proxy below, so "ready" is not true until that is listening. Printing it first and
            # then printing "Refusing to report READY" 90 lines later contradicts itself on the
            # same console. The sentinel IS written here: the watchdog's job is the model, which
            # really is up, and leaving it disarmed with a live server is its own defect.

            # --- Tool-call repair proxy (qwen-proxy) ---------------------------------
            # OpenCode points at http://127.0.0.1:8099 (see opencode.json); this proxy
            # forwards to OVMS and repairs Qwen3-Coder-30B's multi-turn tool-call format
            # (transparent passthrough for the other models). Started once; it is
            # stateless and survives model swaps, so we only start it if 8099 is free.
            #
            # THE INTERPRETER IS CHOSEN EXPLICITLY, NOT TAKEN FROM PATH. #1497 prepends
            # C:\ovms\python to PATH above so ovms.exe can find its DLLs. That directory
            # ships an EMBEDDED CPython carrying a python312._pth file, which puts it in
            # isolated mode -- and isolated mode does NOT place a script's own directory on
            # sys.path. `Get-Command pythonw` after that edit therefore returns an
            # interpreter that CANNOT import qwen-proxy's sibling qwen_toolcall_fix, and the
            # proxy dies at its import line in milliseconds. Measured 2026-09-01: the same
            # command returns C:\Python314\pythonw.exe before the prepend and
            # C:\ovms\python\pythonw.exe after it. The exclusion compares NORMALISED paths
            # with an explicit trailing separator; a bare prefix is wrong in both directions
            # (it rejects C:\ovms\python-tools, and misses a forward-slash PATH spelling).
            # It does not resolve junctions or subst drives (#1511) -- those are caught a
            # step later by the probe below rather than at selection.
            #
            # WHAT "VERIFIED" MEANS HERE IS THAT THE ENDPOINT ANSWERS, NOT THAT A PORT IS
            # OPEN AND NOT THAT A PID MATCHES. A port check proves only that something is
            # bound. A pid check is worse than it looks: the proxy may bind in a CHILD of the
            # process we launched (and the Store-Python App Execution Alias re-execs into a
            # different pid entirely), so comparing pids rejects a perfectly good proxy --
            # measured doing exactly that. And it would guard the wrong branch: the proxy
            # survives model swaps, so `already listening` is the NORMAL path on every swap
            # after the first, and a squatter found there was previously accepted outright.
            # Both paths therefore converge on ONE functional probe: ask the endpoint the
            # coding agent will use for the model it is about to use. Nothing that is not
            # this proxy in front of this model can answer that.
            #
            # A FATAL MUST `exit`, NOT `throw`. This block runs inside the READY poll's
            # try/catch. Under $ErrorActionPreference 'Stop' an unguarded failure becomes a
            # terminating error the poll swallows; the model is still loaded, so the poll
            # re-enters and prints READY every three seconds until the 480s deadline, then
            # reports a load timeout that never happened (measured: 37 false READY prints).
            $ProxyPort  = 8099
            $proxyFatal = $null
            $proxyUp    = $null
            try {
                $proxyUp = Get-NetTCPConnection -LocalPort $ProxyPort -State Listen -ErrorAction SilentlyContinue
                $proxyPreexisting = [bool]$proxyUp

                if (-not $proxyUp) {
                    $proxyPy   = Join-Path $Setup 'tools\qwen-proxy.py'
                    $ovmsPyDir = [IO.Path]::GetFullPath((Join-Path (Split-Path $Ovms -Parent) 'python')).TrimEnd([IO.Path]::DirectorySeparatorChar) +
                                 [IO.Path]::DirectorySeparatorChar

                    $py = $null
                    foreach ($proxyCand in @('pythonw', 'python')) {
                        foreach ($proxyFound in @(Get-Command $proxyCand -All -ErrorAction SilentlyContinue)) {
                            if (-not $proxyFound.Source) { continue }
                            $proxySrc = $proxyFound.Source
                            # A path GetFullPath cannot parse is not one we can compare. Keep the raw
                            # string: that fails the exclusion OPEN, and the probe below catches it.
                            try { $proxySrc = [IO.Path]::GetFullPath($proxySrc) } catch { }
                            if (-not $proxySrc.StartsWith($ovmsPyDir, [StringComparison]::OrdinalIgnoreCase)) {
                                $py = $proxySrc; break
                            }
                        }
                        if ($py) { break }
                    }

                    if (-not (Test-Path $proxyPy)) {
                        $proxyFatal = "the tool-call fixer is not on disk at $proxyPy."
                    } elseif (-not $py) {
                        $proxyFatal = "no Python outside $ovmsPyDir is on PATH. The OVMS build's embedded interpreter runs in isolated mode (python312._pth) and cannot import the fixer's sibling module, so it is not a usable substitute."
                    } else {
                        $proxyStamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
                        $proxyOutLog = Join-Path $LogDir "qwen-proxy-$proxyStamp.out.log"
                        $proxyErrLog = Join-Path $LogDir "qwen-proxy-$proxyStamp.err.log"
                        Start-Process -FilePath $py -ArgumentList $proxyPy `
                            -WorkingDirectory (Join-Path $Setup 'tools') -WindowStyle Hidden `
                            -RedirectStandardOutput $proxyOutLog -RedirectStandardError $proxyErrLog | Out-Null

                        # Poll rather than sleep-and-hope: binding a loopback port is near-instant on
                        # the healthy path, so this returns well inside a second when the proxy is fine.
                        $proxyDeadline = (Get-Date).AddSeconds(15)
                        do {
                            Start-Sleep -Milliseconds 250
                            $proxyUp = Get-NetTCPConnection -LocalPort $ProxyPort -State Listen -ErrorAction SilentlyContinue
                        } while (-not $proxyUp -and (Get-Date) -lt $proxyDeadline)

                        if (-not $proxyUp) {
                            $proxyWhy = @()
                            foreach ($proxyLog in @($proxyErrLog, $proxyOutLog)) {
                                if (Test-Path $proxyLog) {
                                    $proxyText = Get-Content -LiteralPath $proxyLog -Raw -ErrorAction SilentlyContinue
                                    if ($proxyText) { $proxyWhy += "--- $proxyLog ---"; $proxyWhy += $proxyText.TrimEnd() }
                                }
                            }
                            if (-not $proxyWhy) { $proxyWhy = @("(the proxy wrote nothing to $proxyErrLog)") }
                            $proxyFatal = ("the tool-call fixer did NOT come up on 127.0.0.1:$ProxyPort within 15s, started with $py. Its own output follows:" +
                                [Environment]::NewLine + ($proxyWhy -join [Environment]::NewLine))
                        }
                    }
                }

                # ONE probe for both paths: whatever is on that port -- pre-existing or just
                # started -- must serve the model the coding agent is about to ask for.
                if (-not $proxyFatal) {
                    $proxyServed = $null
                    try {
                        $proxyResp  = Invoke-WebRequest "http://127.0.0.1:$ProxyPort/v3/models" -TimeoutSec 15 -UseBasicParsing
                        $proxyServed = @((($proxyResp.Content | ConvertFrom-Json).data) | ForEach-Object { $_.id })
                    } catch {
                        $proxyFatal = "something is listening on 127.0.0.1:$ProxyPort but it did not answer a model query: $($_.Exception.Message)"
                    }
                    if (-not $proxyFatal) {
                        if ($proxyServed -contains $name) {
                            $proxyHow = if ($proxyPreexisting) { 'already running' } else { "started with $py" }
                            Write-Host "Tool-call fixer verified on http://127.0.0.1:$ProxyPort - it answered for $name ($proxyHow)." -ForegroundColor Green
                        } else {
                            $proxyFatal = "127.0.0.1:$ProxyPort answered, but it serves [$($proxyServed -join ', ')] rather than $name. That is not this model's fixer, so the coding agent would be talking to the wrong thing."
                        }
                    }
                }
            } catch {
                # Anything terminating in here -- a launch that cannot create the process, an
                # unreadable log, a malformed path -- IS the proxy failing to start. Recorded as
                # fatal so it exits below, rather than escaping into the READY poll to be retried.
                $proxyFatal = "the tool-call fixer could not be started: $($_.Exception.Message)"
            }

            if ($proxyFatal) {
                Write-Host ''
                Write-Host "FATAL: $proxyFatal" -ForegroundColor Red
                Write-Host "The coding agent's baseURL is http://127.0.0.1:$ProxyPort, so every model call would fail, every candidate would idle for its full breaker window and be killed having written nothing, and the model server would log 'All requests: 0'. Refusing to report READY. (#1495)" -ForegroundColor Red
                # Guarded on the variable too: this is the FATAL path, outside the try above, so a
                # throw here would escape into the READY poll and reinstate the retry loop.
                if ($StoppedVms -and (Test-Path $StoppedVms)) {
                    # exit skips the VM-restart offer further down; say so rather than leave a VM
                    # quietly stopped. The list persists, so the offer returns on the next good run.
                    Write-Host "NOTE: a VM stopped earlier by this tool is still down - its restart offer is further down the script and was not reached. It will be offered again on the next successful start." -ForegroundColor Yellow
                }
                exit 1   # NOT throw - the enclosing READY poll catches terminating errors and retries
            }
            # -------------------------------------------------------------------------

            # Now it is true: the model answers and the endpoint the coding agent uses is live.
            Write-Host "READY: $name is now loaded. (Watchdog armed: auto-restart if it dies.)" -ForegroundColor Green
            Write-Host "Double-click 'Open Coding Chat' to start coding (it picks this model automatically)." -ForegroundColor Green

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
