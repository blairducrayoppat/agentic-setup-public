# verification

## MEMORY BUDGET VERDICT
MEASURED GROUND TRUTH (verified on the machine, not taken from the digest): 31.32GB usable RAM confirmed; BlarAI-Orchestrator Hyper-V VM is 2GB STATIC and was RUNNING during this review; live in-use memory at near-idle was \~15.0GB (16.3GB free) — far above the 5-9GB "Windows + tools" assumptions used across the digest. The iGPU shared window is 18.3GB by default (dxdiag: 18,282MB = Intel's 57% default), not "\~16GB" as three sections claim; the Shared GPU Memory Override raises it to \~87% (\~27GB) per Intel article 000101789 — but the override does not create memory, it only lets GPU allocations starve the OS from the same 31.3GB pool. The digest's claim that ".wslconfig already caps WSL memory" is FALSE — the file contains only networkingMode=mirrored, so WSL2 defaults to \~15.7GB (50%), which invalidates the fleet-tier math as written.

Component figures used below: Windows 11 + services lean 6.5-8GB; BlarAI VM 2GB static; VS Code + LSP + OpenCode/terminal 2.5-3.5GB; browser 1.5-2.5GB; Qwen3-14B INT4 server \~10.5GB (8.5 weights + KV + runtime); gpt-oss-20b \~14.5GB; Qwen3-Coder-30B-A3B INT4-ov \~17-19GB (16.3 weights + 32k q8 KV \~1.5 + OVMS \~1; matches the cited "\~17GB resident" report); Qwen3.6-35B-A3B IQ4_XS \~21.5-22.5GB (19.7 weights + KV + runtime); Qwen3-VL-8B INT4 \~5.5-6GB; HAOS VM 3GB static; WSL2 (OpenClaw) realistic 3-4GB but currently uncapped.

TIER 1 — IDLE (no model loaded): 7 (Win) + 2 (BlarAI VM) + 2.5 (VS Code/terminals) ≈ 11.5GB used, \~20GB free. PASS comfortably. (Live measurement was 15GB in use, so even "idle" is heavier than the digest assumes.)

TIER 2 — CODING (one coder model + OpenCode + editor):
- Qwen3-14B INT4: 10.5 + 7 + 2 (VM) + 3 + 2 (browser) = 24.5GB → \~7GB headroom. PASS. The only comfortable big-tier config.
- gpt-oss-20b: 14.5 + 7 + 2 + 3 + 2 = 28.5GB → \~3GB headroom. Marginal PASS (but see tool-calling conflict).
- Qwen3-Coder-30B-A3B INT4 (inference section's primary): 18.8 + 7 + 2 + 3 + 2 = 32.8GB → FAIL as casually described. Only fits with BlarAI VM shut down and no/lean browser: 18.8 + 7 + 3 = \~28.8GB → \~2.5GB headroom. CONDITIONAL PASS with discipline. Note: 16.3GB weights DO fit the real 18.3GB default GPU window (digest wrongly says they don't), though weights+KV wants the override anyway.
- Qwen3.6-35B-A3B IQ4_XS (models section's top pick): 21.5-22.5 + 6.5 (lean Win) + 3 = 31-32GB with NOTHING else running → less than 0.5GB headroom at best. Effectively FAIL. The models section's own layout ("19GB model + 0.6 embedder + 9GB OS/tools ≈ full") admits zero margin — unacceptable when GPU allocations, OS page cache, and compile jobs share one pool. The OpenVINO path is worse: OpenVINO's own release notes state prefix caching with Qwen3.5/3.6 linear-attention models "consumes exceeding amount of memory" (open issue), directly undermining the "near-free KV cache" selling point on the recommended runtime.

TIER 3 — CODING + VISION (coder + Qwen3-VL-8B both resident):
- 14B + VL-8B: 10.5 + 6 + 7 + 3 = 26.5GB → \~4.8GB headroom. PASS. The only resident-vision config that fits.
- gpt-oss-20b + VL-8B: 14.5 + 6 + 7 + 3 = 30.5GB → <1GB headroom. Edge FAIL with a browser open.
- 30B-coder + VL-8B: 18.8 + 6 + 7 + 3 = 34.8GB → FAIL outright. Requires swap-on-demand (tens of seconds per switch, no swap mechanism specified anywhere in the digest).
- Single multimodal Qwen3.6-35B (the "one model does both" idea): same as Tier-2 35B → FAIL.

TIER 4 — FLEET (overnight: model server + OpenClaw + opencode serve + build/test processes, no human apps):
- 14B: 10.5 + 6.5 + 3.5 (WSL2 OpenClaw, IF capped) + 1 (opencode serve) + 2-4 (npm/pytest spikes; a gradle daemon alone is 2-4GB) = 23.5-25.5GB → PASS with \~6-8GB headroom, ONLY after adding a memory= cap to .wslconfig and keeping Android builds out of the loop.
- 30B-A3B: 18.8 + 6.5 + 3.5 + 1 + 2-4 = 31.8-33.8GB → FAIL/edge; the first npm ci or test run pushes it into paging exactly when an agent is mid-task.
- Any fleet tier + the smarthome plan's always-on HAOS VM (3GB static, -AutomaticStartAction Start) + BlarAI VM (2GB): subtract 5GB from every figure above → only lean-14B survives.

BOTTOM LINE: The stack fits 31.3GB ONLY at the 14B-class tier with comfort. The inference section's Qwen3-Coder-30B-A3B INT4 is a legitimate coding-only stretch goal (\~2.5GB headroom with BlarAI VM off and no resident vision model). The models section's headline Qwen3.6-35B-A3B pick does NOT realistically fit, the coder+VLM resident combo fits only at 14B, and the fleet tier as written is unsafe because WSL2 is uncapped. The smarthome section's "\~21GB left for dev/LLM" coexistence claim is arithmetic fiction once any recommended coder model loads.

## CONFLICTS
1. FOUR SECTIONS RECOMMEND FOUR DIFFERENT PRIMARY MODELS: opencode → gpt-oss-20b-int4-ov; inference → Qwen3-Coder-30B-A3B INT4 on OVMS; models → Qwen3.6-35B-A3B IQ4_XS; orchestration/openclaw → Qwen3-14B INT4 or the old qwen2.5-coder-14b blobs. Who's right: orchestration's 14B realism for fleet/vision tiers; inference's 30B-coder for the coding-only stretch; models' 35B pick fails the RAM budget on this machine despite being the best model (Qwen3.6-35B-A3B itself is real — confirmed via apxml.com, llm-stats.com, HF — the model isn't wrong, the fit is).

2. gpt-oss-20b TOOL CALLING — direct contradiction: opencode section says "repeatedly reported good in OpenCode"; models section says a 2026 arXiv eval found "ZERO successful scaffold tool calls" and 25.6 format errors/instance. Verified resolution: anomalyco/opencode issue #1633 confirms OpenCode does NOT natively handle the Harmony format. Both sections are conditionally right: gpt-oss-20b works ONLY when the serving layer translates Harmony to OpenAI tool_calls (Ollama's native renderer, OVMS --tool_parser gptoss); it fails over generic OpenAI-compatible serving. The opencode section's recommendation silently depends on the serving layer; the models section's blanket rejection overstates. The models section is the safer guidance for a novice.

3. THE 16.8GB OLLAMA BLOBS — three-way conflict: offline-toolchains says "delete them, priority #1"; orchestration says "reuse qwen2.5-coder:14b via llama-server, zero-download start tonight"; openclaw says "reinstall Ollama, the blobs are reusable and 14b-q6_K is the best of them"; opencode says qwen2.5-coder has "multiple reports of unreliable/failed tool calling in OpenCode." Right answer: opencode's skepticism is correct (2-generation-old model, weak agentic tool calling); keep the blobs only as a day-one smoke test, delete after the replacement model is downloaded and verified. openclaw's "best of them" framing is the most misleading.

4. OLLAMA VULKAN STATUS: inference says "enabled by default in v0.30.x"; openclaw caveats say "Vulkan backend experimental... may run CPU-only." Inference is right and openclaw is stale: ollama/ollama issue #13212 ("Vulkan is enabled by default and can't be disabled with OLLAMA_VULKAN=0") corroborates default-on — and incidentally reveals even the disable path was buggy.

5. VULKAN SAFETY ON XE2: inference recommends llama.cpp win-vulkan prebuilt as the fallback (with GGML_VK_DISABLE_COOPMAT workaround); models section says "avoid the Vulkan backend on this iGPU — SYCL or OpenVINO are the stable paths." Models is the safer call for a novice given live TDR bug ggml-org/llama.cpp#20554. CRITICAL STALENESS FINDING: the machine's actual installed driver is 32.0.101.8826, newer than every driver version discussed in the digest (101.7026/101.8509/101.8531) — the TDR bug status on the current driver is unknown and must be retested, not assumed in either direction.

6. KV CACHE "NEAR-FREE" CLAIM vs OPENVINO REALITY: models section sells Qwen3.6's hybrid DeltaNet as making KV "almost free" and simultaneously recommends running it via OpenVINO GenAI; OpenVINO's own release notes admit prefix caching with Qwen3.5/3.6 linear-attention models "consumes exceeding amount of memory which will be addressed shortly." The KV advantage currently holds on llama.cpp, not on the recommended OpenVINO path. Models section is wrong as applied to its own recommended runtime.

7. OS BASELINE DISAGREEMENT: smarthome assumes Windows \~5GB (and concludes "\~21GB left for dev/LLM" with two VMs running); models assumes 6-8GB + tools ≈ 9GB; live measurement on the actual machine was \~15GB in use near-idle. Smarthome's figure is the most wrong, and its coexistence conclusion collapses against the models/inference RAM plans — the digest never reconciles "always-on HAOS VM" with "19GB resident coder."

8. iGPU SHARED WINDOW: opencode, inference, and orchestration all say "\~16GB"; measured reality is 18.3GB default (Intel's 57% default; dxdiag 18,282MB), override to \~87% (\~27GB, Intel article 000101789 — inference's "\~24GB" was close). Consequence: inference's claim that the 16.3GB INT4 30B-coder "exceeds the shared-GPU budget" is wrong at default settings — weights alone fit; only weights+KV needs the override. All sections erred conservative, so this conflict softens (slightly) the capacity squeeze they describe.

9. WSL2 MEMORY CAP: orchestration asserts "user already has a .wslconfig to cap VM memory." Verified FALSE — C:\Users\mrbla\.wslconfig contains only networkingMode=mirrored. Silver lining the digest missed: mirrored networking already solves the WSL-localhost issue the opencode section worries about.

10. MINOR VERSION DRIFT: opencode section pins OVMS 2026.1, inference says 2026.2 (May 28) is current — inference right. Context-length advice is mutually incompatible across sections (64k recommended by opencode docs; 32-48k RAM cap from models; 64k split across 2 slots = 32k each in orchestration) — not contradictory in principle, but a novice following all three at once will misconfigure.

## GAPS
1. NO MEASURED BASELINE: nobody ran a memory audit on the actual machine. Live check shows \~15GB in use near-idle with the BlarAI VM up — every tier budget in the digest starts from fantasy OS figures. A complete blueprint needs a measured baseline + a target "lean profile" checklist (what to close before loading the coder).

2. NO BENCHMARK-FIRST GATE: zero published t/s numbers exist for Qwen3.6-35B-A3B or Qwen3-Coder-30B INT4 on a 258V/Arc 140V (digest admits ±30% triangulation). The blueprint needs a mandatory 30-minute bench step (download one model, measure pp/tg and resident RAM at target ctx) before committing to 20GB downloads and config sprawl.

3. NO CONSOLIDATED DISK BUDGET: models (\~20GB primary + 18GB + 17.7GB alternates + VLM + OCR) + toolchain seeding (40-60GB) + HAOS vhdx (up to 32GB dynamic) + WSL distro + Verdaccio storage + Frigate retention (1-2GB/cam/day) + existing 16.8GB blobs against 230.5GB free. Summed, the maximal plan oversubscribes the disk; nobody prioritized what NOT to download.

4. THERMALS/POWER/UPTIME: a thin Lunar Lake laptop running multi-hour overnight fleet inference will throttle; Modern Standby, lid policy, Windows Update auto-reboot, and battery vs dock behavior are unaddressed — these kill overnight runs more often than OOM does. Needs powercfg settings, active-hours config, and a "fleet runs only on AC + lid open or external policy" rule.

5. WSL2 CONFIG: the actual fix (.wslconfig memory=6GB cap; note mirrored networking already present) is never spelled out, despite the fleet tier depending on it.

6. DRIVER MANAGEMENT PLAN: current Arc driver 32.0.101.8826 postdates all bug discussions in the digest; no procedure to test/pin GPU + NPU driver versions, no rollback instruction. For a machine whose inference stability is driver-bound, this is a first-class gap.

7. MODEL SWAP MECHANISM: the RAM math forces sequential loading (coder vs VLM vs BlarAI's Qwen3-14B), but no section names a swap tool or pattern (llama-swap, OVMS config reload, a PowerShell stop/start script) or budgets the 20-60s swap latency in agent workflows.

8. VISION PLUMBING END-TO-END: serving coder + Qwen3-VL-8B simultaneously from OVMS (multi-model config), wiring attachment:true through OpenCode to the VLM, and whether streamed image payloads work — described in fragments, never as one tested path.

9. THE ACTUAL USE-CASE STACK: no database choice for the inventory/ecommerce system (SQLite vs Postgres, and Postgres's RAM share), no web-app serving budget, no Android tier math (gradle daemon 2-4GB + Android Studio 2-3GB never appear in any tier despite Pixel 8 Pro apps being a stated use case).

10. SECURITY RECONCILIATION WITH BLARAI: the digest hardens OpenClaw in isolation but never resolves the architecture question — autonomous agents with exec rights (coding-agent skill explicitly uses bypass-permissions modes, ACP execution unsandboxed) on the same physical machine as the security-first BlarAI stack. Needs an explicit isolation decision: separate Windows user, Hyper-V VM for the orchestrator, per-exe outbound firewall rules, or acceptance of shared blast radius.

11. BACKUP/ROLLBACK BEFORE AUTONOMY: git worktrees protect repos, nothing protects the system — no restore points, no config snapshots, no "known-good" model+config archive before letting overnight agents run.

12. MONITORING/WATCHDOG: nothing teaches the novice to see trouble coming — Task Manager shared-GPU-memory readout, a perf counter alert on commit charge, auto-restart of the model server, or log triage for the failure signatures the digest itself catalogs (ErrorOutOfDeviceMemory, TDR, tool-JSON-as-text).

13. FINAL TOPOLOGY DECISION: OpenClaw native-Windows vs WSL2 vs Hyper-V VM is left split across two sections, with repo location (\\wsl$ performance tax vs Windows-native checkouts) unresolved.

## TOP RISKS
1. MEMORY OVERCOMMIT DEATH SPIRAL (most likely, day one): novice follows the models section, loads the 19.7GB Qwen3.6 (or 30B-coder with browser + BlarAI VM still up), and the machine starts paging mid-agent-run — GPU allocation failures (ErrorOutOfDeviceMemory), frozen TUI, possible full system stall. Because the iGPU, OS, VMs, and build jobs share one 31.3GB pool, failure is sudden and looks like "the AI broke my laptop." No section gives the novice a way to see it coming (no monitoring guidance) or a rule like "BlarAI VM off + browser closed before loading >14GB models."

2. TOOL-CALLING PLUMBING MISMATCH (most likely silent failure): the digest documents at least six distinct ways the agent loop silently degrades — wrong endpoint (/v1 vs /v3 vs Ollama-native, where OpenCode requires /v1 and OpenClaw forbids it), wrong/missing tool parser (qwen3coder XML vs hermes vs gptoss Harmony), context below 16-32k, output-token truncation chopping tool args, preserve_thinking unset, Ollama's miswired Qwen3 templates. Symptom is always the same: the model prints raw JSON/XML as text or loops doing nothing, with no error. A novice cannot distinguish "bad model" from "wrong flag" and will burn days here.

3. OPENCLAW SECURITY BLAST RADIUS: 137+ advisories in two months, actively-exploited one-click RCE (CVE-2026-25253), \~1-in-12 malicious ClawHub skills, skills running in-process with full gateway access, and — on this Docker-less machine — NO working sandbox backend, while the coding-agent skill launches harnesses in bypass-permissions mode explicitly outside any sandbox. One curious `clawhub install` or one exposed port compromises the same machine hosting the security-first BlarAI project. The digest says "treat as a sandboxed experiment" but the sandbox it assumes doesn't exist here.

4. OVERNIGHT FLEET DIES OR DOES DAMAGE: laptop sleep/Modern Standby, Windows Update reboots, thermal throttling, and the uncapped WSL2 VM (up to \~15.7GB) make multi-hour unattended runs unreliable; when they do run, an agent operating outside strict worktree discipline (or merging "tests pass" semantic garbage) damages the main checkout. The honest throughput (\~5-15 tasks/night at 10-25 t/s, prefill-dominated 100k+-token turns) also means expectations set by cloud-agent blogs will be missed by 10x, tempting the novice to raise concurrency — which the RAM cannot absorb.

5. OFFLINE BRITTLENESS + VERSION CHURN: the stack is pinned to a moving target — OpenCode ships multiple releases/day and still phones home to models.dev at startup (offline flag unimplemented; cached-catalog behavior community-reported only), OpenClaw is date-versioned with weekly drift, npm scaffolders fail without Verdaccio seeding, Python 3.14 lacks wheels for key packages (paddlepaddle), and every "add one new dependency while offline" fails by design. The first unseeded package or silent auto-update breaks a working setup, and the digest's exact versions, flags, and config keys (its own caveats admit) may be stale within weeks of execution.
