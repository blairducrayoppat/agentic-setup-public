# ovms-ops

## VERIFIED FACTS
1) LOGGING (verified by running C:\ovms\ovms.exe --help, version 2026.2.5e9dcfc46): `--log_level LOG_LEVEL` accepts TRACE, DEBUG, INFO, WARNING, ERROR (default INFO); `--log_path LOG_PATH` = "Optional path to the log file". NO rotation exists: src/logging.cpp on releases/2026/2 includes only spdlog `basic_file_sink` (append-only) — dated/rotating files must be created by the launcher. INFO is the right production level: it includes the llm_executor lines ("All requests: N; Scheduled: N; Cache usage X%") that are the only way to watch KV-cache usage (GenAI metrics are NOT in /metrics — documented limitation in docs/llm/reference.md).

2) WINDOWS SERVICE (verified by reading C:\ovms\install_ovms_service.bat locally + docs/windows_service.md + src/main_windows.cpp): install = `install_ovms_service.bat C:\models` then `sc start ovms`. The bat runs `sc create ovms binPath= "...ovms.exe --rest_port 8000 --config_path <repo>\config.json --log_level INFO --log_path <ovms_dir>ovms_server.log"` plus `ovms.exe install` (writes PYTHONHOME registry + service description). Per-start overrides are supported: `sc start ovms --rest_port 8000 --config_path ... --log_level DEBUG --log_path ...`. CRITICAL: the stock binPath has NO --rest_bind_address, and OVMS defaults to 0.0.0.0, so the service would listen on ALL interfaces — violates the loopback-only requirement unless --rest_bind_address 127.0.0.1 is added to binPath. Service mode does NOT take per-model GenAI CLI args (--tool_parser etc.); it is config.json-driven, with per-model options in each model dir's graph.pbtxt. Service stop IS graceful: serviceCtrlHandler handles SERVICE_CONTROL_STOP -> server.setShutdownRequest(1) (main_windows.cpp lines 479-503, 761). Verdict for this setup: a service is NOT required for the swap workflow — the same swap-without-restart benefit comes from running console ovms with --config_path; the service mainly adds boot autostart and LocalSystem execution (a security downgrade vs user-context Start-Process).

3) HEALTH (verified docs/model_server_rest_api_kfs.md + v2026.2 release notes): best watchdog endpoint is `GET /v2/health/ready` (HTTP 200 = all models fully initialized; 2026.2 release notes explicitly FIXED this endpoint: "now correctly reports success when all models are fully initialized and returns appropriate errors when models are not loaded"). Also available: `GET /v2/health/live` (liveness), per-model `GET /v2/models/{name}/ready`, OpenAI list `GET /v3/models` (already used by start-llm.ps1), config status `GET /v1/config`, manual reload `POST /v1/config/reload`. Note: TFS /v1 model endpoints are scheduled for removal in 2026.3; /v3 stays.

4) MULTI-MODEL (verified docs/starting_server.md, docs/mediapipe.md, docs/online_config_changes.md, src/llm/llm_calculator.proto, and maintainer-confirmed issue #4071): YES — one instance serves multiple GenAI models via `ovms --config_path C:\models\config.json --rest_port 8000 --rest_bind_address 127.0.0.1`. GenAI options (task, tool_parser, device, cache, kv precision) are NOT valid in config.json's model_config_list — they must live in a `graph.pbtxt` inside each model dir (LLMCalculatorOptions: models_path, device:"GPU", cache_size, enable_prefix_caching [proto default FALSE — unlike CLI default true], plugin_config '{"KV_CACHE_PRECISION":"u8"}', tool_parser, reasoning_parser, enable_tool_guided_generation, pipeline_type AUTO/VLM, max_num_seqs, max_num_batched_tokens). Verified locally: C:\models\coder-30b has NO graph.pbtxt (CLI single-model mode synthesizes the graph from --task flags; config-file mode requires the file — generate by hand from the template in docs/llm/reference.md, or via `ovms --pull` / export_model.py). Runtime load/unload IS documented (docs/online_config_changes.md): config.json is polled every --file_system_poll_wait_seconds (default 1s); adding/removing entries loads/unloads servables at runtime; removal unloads "after already running inference operations have been completed" (graceful); helpers `ovms --add_to_config / --remove_from_config` edit config.json from CLI; `POST /v1/config/reload` forces it. This enables swap-without-restart: remove coder-30b entry, wait for unload, add vision entry — server process and port stay up. RAM rule: every entry present in config.json is resident simultaneously, so 14B+VL can share one config permanently, but 30B and VL must never be in the file at the same time.

5) SHUTDOWN (verified src/main.cpp + src/main_windows.cpp on releases/2026/2): in console mode on Windows NO console-ctrl handler is registered — the console path just calls server.start(), so taskkill /F (= current Stop-Process -Force) is the de facto stop and there is no gentler console option. Safety: model weights are opened read-only and KV/prefix cache is RAM-only — nothing durable can corrupt. Residual risks only: in-flight responses cut off, last log lines unflushed, and if killed mid-FIRST-load a partial GPU compile-cache entry could be left in the model cache dir (default c:\Intel\openvino_cache if present; C:\models\ov_cache exists locally) — if a model ever fails to load after a hard kill, delete that cache dir. Graceful stop exists only via Windows service (`sc stop ovms`).

6) GENERATION DEFAULTS (verified by reading C:\models\coder-30b\generation_config.json AND fetching https://huggingface.co/OpenVINO/Qwen3-Coder-30B-A3B-Instruct-int4-ov/raw/main/generation_config.json — byte-identical values; precedence documented in docs/llm/reference.md): defaults come from generation_config.json in the model dir, read ONCE at server start (restart after editing); precedence = request body -> generation_config.json -> OVMS built-in default. The export ALREADY contains exactly the Qwen3-Coder recommended values: do_sample=true, temperature=0.7, top_p=0.8, top_k=20, repetition_penalty=1.05. Nothing to change — but any temperature OpenCode sends in the request overrides these.

7) 2026.2 KNOWN ISSUES relevant to Arc iGPU long sessions (verified v2026.2 release notes + GitHub issues): (a) release-notes limitation: prefix caching with Linear-Attention models (Qwen3.5/3.6) "consumes exceeding amount of memory" — does NOT affect Qwen3-Coder-30B-A3B or Qwen3-14B (classic attention), but avoid Qwen3.5/3.6 for now; (b) issue #4035: this EXACT model (Qwen3-Coder-30B int4) on GPU exhausts system RAM on Meteor Lake and older iGPUs (Intel: MoE-on-GPU "not supported on MTL and former generations") — Lunar Lake/Arc 140V (Xe2) is supported (2026.x added Xe MoE support; 2026.2 further improved Qwen3-30B MoE), but a commenter confirmed load transiently stages a CPU-RAM copy plus the GPU copy, so the load-time RAM spike is real — the start-llm memory assistant's \~21GB headroom requirement is correct and should not be relaxed; (c) open issue #4230: --cache_dir is not propagated to continuous-batching pipelines (regression), so the 30-90s GPU compile happens every start — no fix to apply locally, just expectation-setting; (d) open feature request #4141: no idle auto-unload exists — swap remains script-driven; (e) steady-state KV growth is already bounded by their --cache_size 4 (docs warn dynamic allocation "could lead to consuming all available RAM" — pinning it was the right call; prefix-cache blocks auto-evict when the fixed cache fills, per docs/llm/reference.md). Side finding: the Windows binary is a python-OFF build (ovms.exe --version prints "win_mp_on_py_off") while docs/llm/reference.md still claims "using tools is not supported in configuration without Python" — empirically stale, since qwen3coder tool parsing is validated working on this machine; treat tool-template edge cases as a possible source of quirks, not the parser itself.

## IMPROVEMENTS

### [P0/small] Add a dated log file to start-llm.ps1 (currently all OVMS output is lost when the window closes)
start-llm.ps1 launches ovms.exe with no --log_path, so after a crash or compaction-style failure there is nothing to diagnose. OVMS has no built-in rotation (spdlog basic_file_sink, append-only), so put the date in the filename per start and prune old files — this gives rotation for free and matches the user's no-commands-to-remember pattern. INFO level is correct for production: it is the ONLY place KV 'Cache usage %' is visible (GenAI metrics are not exposed on /metrics in 2026.2).
```text
In C:\Users\mrbla\agentic-setup\scripts\start-llm.ps1, before the $args2 line add:
$logDir = 'C:\Users\mrbla\agentic-setup\logs'
New-Item -ItemType Directory -Force $logDir | Out-Null
Get-ChildItem $logDir -Filter 'ovms-*.log' | Where-Object LastWriteTime -lt (Get-Date).AddDays(-14) | Remove-Item -Force
$logFile = Join-Path $logDir ("ovms-{0}-{1}.log" -f $name, (Get-Date -Format 'yyyyMMdd-HHmmss'))
Then extend the args:
$args2 = @('--rest_port','8000','--rest_bind_address','127.0.0.1','--model_path',$path,'--model_name',$name,'--task','text_generation','--target_device','GPU','--cache_size','4','--log_level','INFO','--log_path',$logFile) + $extra
And on failure paths (HasExited / timeout throws) append: "Log file: $logFile" to the message.
```
RISK: None functional. Disk growth is bounded by the 14-day prune. OVMS still prints to the console window as before.

### [P1/small] Health-check on GET /v2/health/ready (the endpoint 2026.2 specifically fixed) instead of only /v3/models
The 2026.2 release notes state /v2/health/ready 'now correctly reports success when all models are fully initialized and returns appropriate errors when models are not loaded' — it is the documented readiness contract and returns plain HTTP 200/4xx with no body to parse, ideal for a watchdog. Keep /v3/models afterwards only to print the loaded model name. Per-model probe (useful later in multi-model mode): GET /v2/models/coder-30b/ready.
```text
In start-llm.ps1's readiness loop replace the single probe with:
$null = Invoke-WebRequest 'http://127.0.0.1:8000/v2/health/ready' -TimeoutSec 3   # throws until ready
$resp = Invoke-WebRequest 'http://127.0.0.1:8000/v3/models' -TimeoutSec 3        # for the friendly name printout
For any future watchdog script: healthy == (Invoke-WebRequest 'http://127.0.0.1:8000/v2/health/ready').StatusCode -eq 200.
```
RISK: Negligible — /v2/health/ready also returns 200 only when the model is loaded, same as the current behavior but per the documented contract.

### [P1/small] Do NOT install the Windows service as-is; if ever installed, it must be loopback-pinned first
C:\ovms\install_ovms_service.bat creates the service with binPath '...ovms.exe --rest_port 8000 --config_path ...' and NO --rest_bind_address — OVMS defaults to 0.0.0.0, so the service would expose the API on every network interface, breaking the loopback-only security posture. It also runs as LocalSystem and is config.json-driven (per-model CLI args like --tool_parser don't apply), and it removes the interactive memory-assistant step that makes the current workflow work for this user. The current Start-Process approach is the right architecture for a one-model-at-a-time swap on this RAM-constrained machine.
```text
Decision to record in agentic-setup\BLUEPRINT.md: 'Windows service deferred — stock installer binds 0.0.0.0 and runs as LocalSystem.' If a service is ever wanted (e.g., auto-start at boot), after running install_ovms_service.bat fix the binding before first start:
sc config ovms binPath= "\"C:\ovms\ovms.exe\" --rest_port 8000 --rest_bind_address 127.0.0.1 --config_path \"C:\models\config.json\" --log_level INFO --log_path \"C:\ovms\ovms_server.log\""
Then: sc start ovms / sc stop ovms (sc stop is a verified graceful shutdown via SERVICE_CONTROL_STOP).
```
RISK: None — this is a guard rail, not a change to the running setup.

### [P2/medium] Optional 'everyday + vision' mode: one OVMS instance serving qwen3-14b AND qwen3-vl-8b from config.json
14B+VL fit in RAM together, so a config-file instance can answer vision questions without a model swap. Requires creating a graph.pbtxt in each model dir (the dirs currently have none — CLI mode synthesizes the graph, config mode does not) plus a config.json, and a fourth Desktop launcher. The 30B coder stays on the existing single-model launcher (30B+VL never together). Bonus: with --config_path, models can also be added/removed at runtime by editing config.json (polled every 1s; unload waits for in-flight requests), enabling future swap-without-restart via 'ovms --remove_from_config/--add_to_config'.
```text
1) C:\models\qwen3-14b\graph.pbtxt — copy the template from docs/llm/reference.md verbatim, changing only node_options to:
node_options: { [type.googleapis.com / mediapipe.LLMCalculatorOptions]: { models_path: "./", device: "GPU", cache_size: 2, enable_prefix_caching: true, plugin_config: '{"KV_CACHE_PRECISION":"u8"}', tool_parser: "hermes3", reasoning_parser: "qwen3" } }
2) C:\models\qwen3-vl-8b\graph.pbtxt — same template with:
node_options: { [type.googleapis.com / mediapipe.LLMCalculatorOptions]: { models_path: "./", device: "GPU", cache_size: 1, enable_prefix_caching: true, pipeline_type: VLM } }
(NOTE: enable_prefix_caching defaults to FALSE in graph.pbtxt, unlike the CLI where it defaults true — set it explicitly.)
3) C:\models\config.json:
{ "model_config_list": [
  { "config": { "name": "qwen3-14b",   "base_path": "C:\\models\\qwen3-14b",   "graph_path": "graph.pbtxt" } },
  { "config": { "name": "qwen3-vl-8b", "base_path": "C:\\models\\qwen3-vl-8b", "graph_path": "graph.pbtxt" } }
] }
4) Launch: C:\ovms\ovms.exe --rest_port 8000 --rest_bind_address 127.0.0.1 --config_path C:\models\config.json --log_level INFO --log_path <dated file>
5) Add a start-llm.ps1 branch '-Model everyday-vision' (needGB ~16) and a Desktop .cmd.
```
RISK: Medium: graph.pbtxt syntax errors fail the servable load (check log / /v2/health/ready); vision model path must be confirmed (script searches C:\models\qwen3-vl-8b and BlarAI copy); both models resident means less headroom for builds — keep the memory assistant gate at \~16GB. Validate tool calling still works for OpenCode against the 14B entry before adopting.

### [P2/small] Keep Stop-Process -Force as the stop mechanism — verified safe — but document the one cache caveat
Console-mode ovms.exe on Windows registers no Ctrl handler (verified in src/main_windows.cpp), so there is no graceful console stop; hard kill is the supported reality. It cannot corrupt anything durable: weights are read-only, KV/prefix cache is RAM-only. The only artifact at risk is a partial GPU compile-cache entry if killed during a model's FIRST load.
```text
Add two lines to stop-llm.ps1's success message and BLUEPRINT.md troubleshooting: 'Hard-stopping OVMS is safe for your models. If a model ever fails to load right after a stop that happened DURING loading, delete the cache folder (C:\models\ov_cache and c:\Intel\openvino_cache if present) and start it again — it will rebuild in a few minutes.'
```
RISK: None — documentation only.

### [P2/small] Pin a note: do not adopt Qwen3.5/3.6 models with prefix caching on 2026.2
2026.2 release notes list a live limitation: 'Using prefix caching with new Linear Attention models such as Qwen3.5/Qwen3.6 consumes exceeding amount of memory which will be addressed shortly.' The current models (Qwen3-Coder-30B-A3B, Qwen3-14B, Qwen3-VL-8B) are unaffected, but on a 31GB shared-RAM machine this would be a session-killer if a future model upgrade picks Qwen3.5/3.6. Also note open issue #4230 (--cache_dir not propagated to CB pipelines) explains why every model start pays the full 30-90s GPU compile.
```text
Add to agentic-setup\BLUEPRINT.md known-issues section: 'OVMS 2026.2: (1) Qwen3.5/Qwen3.6 + prefix caching = runaway RAM (release-notes limitation) — wait for 2026.3 before trying those models; (2) GPU compile cache is not reused for LLM pipelines (github issue #4230), so the 30-90s load on every start is expected, not a fault.'
```
RISK: None — documentation only.

