# Local Agentic Coding Setup — Blueprint
**Machine:** ASUS ExpertBook P5405CSA · Intel Core Ultra 7 258V (Lunar Lake) · Arc 140V iGPU · 31.3 GB shared LPDDR5X (not upgradable) · Windows 11 Pro
**Written:** 2026-06-10 · Research basis: `research/*.md` (7 web-research agents + adversarial verification, June 2026 sources)

---

## 0. The one-page summary

You are building a fully-offline-capable agentic dev stack with **three layers**:

```
┌─────────────────────────────────────────────────────────────────┐
│  ORCHESTRATION   The fleet (run-fleet.ps1) = the coding         │
│                  orchestrator: serial queue · worktree ·        │
│                  gitleaks/verify/review gates.                  │
│                  Chat dispatch = BlarAI AO/PA. (OpenClaw §5)    │
├─────────────────────────────────────────────────────────────────┤
│  CODING AGENT    OpenCode (terminal TUI + `opencode serve` API) │
│                  LSP · MCP · subagents · git-worktree-per-task  │
├─────────────────────────────────────────────────────────────────┤
│  MODEL SERVER    OpenVINO Model Server (ovms.exe, native, GPU)  │
│                  ONE model resident at a time:                  │
│                    coder-30b  = deep coding   (~18 GB, lean!)   │
│                    qwen3-14b  = everyday/fleet (~10.5 GB)       │
│                    qwen3-vl-8b = screenshots   (~6 GB)          │
│                  + RapidOCR on the NPU (~80 MB, always cheap)   │
└─────────────────────────────────────────────────────────────────┘
```

**The cardinal rule of this machine:** CPU, iGPU, OS, VMs, and build jobs all share ONE 31.3 GB pool. Every decision below follows from that. Your machine idles at **~15 GB in use** with the BlarAI VM running — leaner profiles must be deliberate, not assumed.

**First hour:** run `scripts\01-install-opencode.ps1` (done for you), then `scripts\02-install-ovms-and-models.ps1` (downloads ~17 GB — needs internet + time), then `scripts\start-llm.ps1 -Model coder-30b`, then open a terminal in any repo and type `opencode`.

---

## 1. Memory tiers — what can run together

Verified arithmetic (see `research/verification.md`). "Win+tools" = Windows ~6.5–7 GB lean + VS Code/terminals ~3 GB.

| Tier | Resident model(s) | Also running | Total | Headroom | Verdict |
|---|---|---|---|---|---|
| **Everyday** | qwen3-14b (~10.5 GB) | Win+tools, BlarAI VM (2), browser (2) | ~24.5 | ~7 GB | ✅ comfortable default |
| **Everyday+Vision** | qwen3-14b + qwen3-vl-8b (~6) | Win+tools | ~26.5 | ~5 GB | ✅ stop BlarAI VM or close browser |
| **Power coding** | coder-30b (~18.8 GB) | Win+tools ONLY | ~28.8 | ~2.5 GB | ⚠️ LEAN PROFILE required (below) |
| **Overnight fleet** | qwen3-14b | OpenClaw (capped), opencode serve, builds | ~24–26 | ~5–7 GB | ✅ 14B only — never fleet on 30B |
| **Smart-home dev** | qwen3-14b | HAOS VM (3 GB static), Win+tools | ~26.5 | ~5 GB | ✅ BlarAI VM off |
| ❌ coder-30b + vision resident | 18.8 + 6 | anything | ~35 | — | FAIL — swap models instead |
| ❌ Qwen3.6-35B-A3B (best model of mid-2026) | ~21.5–22.5 | lean Win | ~31–32 | <0.5 GB | FAIL — rejected |

**Lean profile is now AUTOMATED (2026-06-10):** `start-llm.ps1` is a guided memory assistant — it measures available RAM, and if there isn't enough it lists what's using memory (BlarAI VM, browser, heavy apps) with how much each would free, and offers to close them one at a time (graceful close, always asks, force-close only with a second explicit yes). It remembers when it stopped the BlarAI VM and offers to restart it when you switch back to the everyday model. **Double-click launchers** exist on the Desktop and in this folder: `Deep Coding (30B).cmd`, `Everyday AI (14B).cmd`, `Screenshot Vision (8B).cmd`, `Stop AI Models.cmd`. For reference, what "lean" means:
1. BlarAI VM stopped (frees 2 GB).
2. Browser closed (or ≤3 tabs), no Android Studio, no HAOS VM.
3. **≥21 GB available** before loading the 30B (the script checks this for you).
4. GPU note — **the Shared GPU Memory Override is REQUIRED for the 30B, not optional (measured 2026-06-17, see `bench/`):** the Arc 140V's default shared-GPU window is ~17.9–18.3 GB. The 30B's working set (~18 GB: INT4 weights + KV + runtime) *exceeds* it, so it spills onto the slow path and decode collapses to **~3.5 t/s** (GPU memory shows maxed at 17.9/17.9). Enabling Intel Graphics Software → System → **Shared GPU Memory Override → ~87%** and then **rebooting** raises the window to ~27 GB so the whole model fits → decode jumps to **~35–45 t/s (~10×)**, beating Intel's published 34 t/s on the larger 285H. Without it the 30B is effectively unusable for interactive coding. The override doesn't create RAM — it raises the GPU's max share of the same pool; cost is ~3 GB of baseline RAM (the GPU reserves more at idle) in exchange for the 10×.

**Model swap latency is real:** stopping one model and loading another takes ~20–60 s. The `start-llm.ps1` / `stop-llm.ps1` scripts are the swap mechanism. Plan workflows around it (e.g., batch your screenshot-debugging, don't ping-pong).

---

## 2. Model stack — decisions and rejected alternatives

| Role | Model | Why | Footprint |
|---|---|---|---|
| **Deep agentic coding** | **Qwen3-Coder-30B-A3B-Instruct INT4** (`OpenVINO/Qwen3-Coder-30B-A3B-Instruct-int4-ov`) | The proven local OpenCode model of 2025–26; MoE with 3.3B active params → 20–30 t/s on this iGPU (dense 24B ≈ 5–7 t/s); purpose-built tool-call format served via OVMS's `qwen3coder` parser + the qwen-proxy repair (§3); 64k ctx (u8 KV cache, `opencode.json`) | ~16.3 GB weights, ~18 GB resident @32k |
| **Everyday / fleet / orchestrator** | **Qwen3-14B INT4** (already on disk — BlarAI's `models/qwen3-14b`, or pull `OpenVINO/Qwen3-14B-int4-ov` for a decoupled copy) | Already validated on YOUR Arc 140V by BlarAI; leaves room for everything else; good (not great) tool calling | ~8.5 GB weights, ~10.5 GB resident |
| **Vision (screenshots, UI debugging)** | **Qwen3-VL-8B-Instruct INT4** (already on disk in BlarAI models) | Still class-leading at 8B for UI work: ScreenSpot 94.4%, DocVQA 96.1%, OCRBench 89.6% | ~6 GB resident |
| **Product-label OCR** | **RapidOCR + PP-OCRv5 (OpenVINO backend, NPU target)** | ~80 MB, sub-second/page, fully offline, runs on the NPU so it costs ZERO GPU/LLM memory; escalate hard labels (curved/stylized) to Qwen3-VL-8B | ~80 MB |
| Tab autocomplete (optional) | qwen2.5-coder:1.5b (existing blob — it's a plain GGUF) via llama.cpp + Continue.dev | Free, you already have it | ~1 GB |
| Embeddings (future RAG) | jina-code-embeddings-0.5b or Qwen3-Embedding-0.6B | Current 2026 leaders; your nomic-embed/bge-small are now mid-tier | ~0.6 GB |

**Rejected (and why), so you don't relitigate later:**
- **Qwen3.6-35B-A3B** — genuinely the best ≤32 GB-class agentic model (SWE-bench Verified 73.4%, natively multimodal), but IQ4_XS is 19.7 GB and total resident ~21.5–22.5 GB → <0.5 GB headroom on this machine. Also its "near-free KV cache" advantage currently does NOT hold on OpenVINO (open issue: prefix caching with Qwen3.5/3.6 linear-attention "consumes exceeding amount of memory"). Revisit only on future hardware.
- **gpt-oss-20b** — works in OpenCode *only* when the serving layer translates its Harmony format (a 2026 arXiv eval measured ZERO successful scaffold tool calls without it). OVMS does have a `gptoss` parser, so it's a legitimate *alternate*, but Qwen3-Coder is the safer primary.
- **Devstral Small 2 (24B dense)** — great model, wrong hardware: dense 24B ≈ 5–7 t/s on 136.5 GB/s LPDDR5X. MoE or bust on this machine.
- **Qwen3-Coder-Next 80B-A3B, GLM-4.5-Air class** — don't fit 31.3 GB at any usable quant.
- **Your qwen2.5-coder Ollama blobs** — two generations old; multiple community reports of failed tool calling in OpenCode. Keep only for a day-one plumbing smoke test; delete the 16.8 GB after coder-30b is verified (`Remove-Item -Recurse $env:USERPROFILE\.ollama`).

**Re-checked 2026-06-24 (Dispatch LA), prompted by the dispatch's non-functional output.** The rejections above all still stand — and they are *hardware/memory*, not substrate. The OpenVINO **substrate did advance** (OV 2026: native MoE support, **EAGLE-3 speculative decoding**, Optimum Intel 2.0 OpenVINO-first conversion), so the generic "OV can't run these yet" belief is now stale. But: Devstral Small 2 (dense 24B → 5–7 t/s) and Qwen3-Coder-Next (80B-A3B, won't fit 31.3 GB) are capped by iGPU bandwidth + RAM, and Qwen3.6-35B-A3B is still gated by the **open OV prefix-caching memory issue + <0.5 GB headroom**. **Net: Qwen3-Coder-30B-A3B remains the correct coder — the only model that is strong *and* MoE-fast *and* fits.** The model is therefore **not** the dispatch's lever; the no-wired-keypad failure was *process* (staged prompt said "theme the shell" + the no-execute rule + the iteration budget). Two non-swap levers now exist: (1) **EAGLE-3 spec-decode** on the resident 30B-A3B → more t/s → more iterations per budget; (2) **future hardware** (more RAM/bandwidth) is the trigger to revisit Qwen3.6-35B-A3B.

---

## 3. Serving layer — OpenVINO Model Server (primary)

**Why OVMS over Ollama/llama.cpp/LM Studio on THIS machine:**
- You're an OpenVINO upstream contributor; OpenVINO GenAI already runs Qwen3-14B on this exact GPU (BlarAI). Zero new runtime surface.
- OVMS 2026.2 has a **dedicated `qwen3coder` tool parser** + XGrammar tool-guided generation — exactly the plumbing agentic tool-calling needs. Ollama's Qwen3-Coder templates are demonstrably miswired (issues #14493, #14570); llama.cpp's parsing is good but generic.
- OVMS uses the oneDNN/OpenCL path with XMX — it does **not** depend on the Intel Vulkan driver, which currently has a live TDR/reset bug on Arc 140V (llama.cpp #20554). Driver 32.0.101.8826 (installed) postdates those reports — status unknown, so don't bet on Vulkan.
- Best published decode for 30B-A3B on Intel iGPU (Intel: 34 t/s on Arc 140T; expect ~25–30 t/s here).
- Native Windows exe, Windows-service deployment, continuous batching, prefix caching, OpenAI-compatible API at **`/v3`**.

**Endpoints:** OVMS serves the OpenAI-compatible API at `http://127.0.0.1:8000/v3`. **OpenCode points at the qwen-proxy at `http://127.0.0.1:8099/v3`** (`tools\qwen-proxy.py`, auto-started by `start-llm.ps1` when a model loads), which transparently forwards to OVMS and repairs Qwen3-Coder-30B's multi-turn tool-call format (plain passthrough for the 14B and VLM). **OpenClaw was evaluated and dropped (see §5)** — orchestration is the fleet + BlarAI's AO/PA, so no extra gateway points at OVMS on your behalf. One model resident at a time; `scripts\start-llm.ps1` is the swapper.

**Fallback (documented, not installed):** upstream llama.cpp official **SYCL** win-x64 prebuilt (avoid Vulkan on this iGPU until the TDR bug is confirmed fixed on your driver):
```
llama-server -hf unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF:Q4_K_XL --jinja -ngl 99 \
  --ctx-size 32768 --cache-type-k q8_0 --cache-type-v q8_0 --temp 0.7 --top-p 0.8 --top-k 20
```
This can also load your existing Ollama blobs directly (they're plain GGUF): `-m C:\Users\mrbla\.ollama\models\blobs\sha256-998e730e...` (qwen2.5-coder:14b-q6_K) — useful as a zero-download smoke test, but expect flaky tool calls from that old model.

**OVMS flag drift warning:** OVMS releases move; if a start script errors, run `C:\ovms\ovms.exe --help` and compare. The intent of every flag is recorded in the scripts' comments.

**✅ VALIDATED on this machine, OVMS 2026.2, 2026-06-10** (qwen3-14b on GPU; full chat completion + structured tool call returned):
- Local model dirs are served with `--model_path <dir>` — `--source_model` is HF-pull mode only (it tries to git-clone the value).
- `--tool_parser qwen3` does NOT exist; Qwen3 (thinking) uses **`hermes3`**, Qwen3-Coder uses **`qwen3coder`**. `--reasoning_parser qwen3` is valid and correctly splits `reasoning_content` from `content`.
- **OVMS defaults to binding 0.0.0.0 (all interfaces)** — `--rest_bind_address 127.0.0.1` is mandatory for the loopback-only posture. The scripts include it.

---

## 4. OpenCode (the coding workhorse)

- Install: `npm install -g opencode-ai` (native Windows; repo is now `anomalyco/opencode`; multiple releases/day, so `autoupdate: false` and update deliberately).
- Global config installed at `%USERPROFILE%\.config\opencode\opencode.json` (yes, `.config` on Windows) — see `configs\opencode.json`. It defines all three local models with correct flags (`tool_call: true` for coders; `attachment: true` + image modality for the VLM).
- **Use Windows Terminal** — the TUI has known bugs in cmd.exe and git-bash (#7943, #7539).
- **Offline caveat (important):** OpenCode fetches a model catalog from models.dev at startup; the response is cached under `~/.cache/opencode` after one online run, and a true `--offline` flag is still an open feature request (#2224/#16117). **Run OpenCode once while online**, then verify it starts in airplane mode. Set `"lsp": false` if it tries to download LSP servers you don't have.
- Headless/orchestration: `opencode serve --port 4096 --hostname 127.0.0.1` (+ `OPENCODE_SERVER_PASSWORD`) exposes the full OpenAPI; `opencode run "task" --attach http://localhost:4096 --dir <worktree>` dispatches one-shot tasks; `@opencode-ai/sdk` for TypeScript automation.
- Screenshots: paste (Ctrl+V) or drag into the TUI **with the vision model selected** (`local/qwen3-vl-8b`). Workflow: hit a UI bug → swap to vision (`start-llm.ps1 -Model vision`), diagnose with screenshots, swap back to the coder.
- Tool calls misbehaving? It is almost always plumbing, not the model: check (a) base URL is `/v3` for OVMS, (b) context ≥ 32k, (c) the right `--tool_parser` was passed at server start, (d) output limit not truncating tool args. Symptom of all four: the model prints raw JSON/XML as text instead of acting.

## 5. OpenClaw (the orchestrator/assistant) — EVALUATED AND DROPPED (2026-06-21)

**Decision: do not install OpenClaw.** It was the planned Phase-4 orchestration brain (cron-dispatch coding tasks, a WebChat UI, smart-home chat). Since the blueprint was written, the build produced that capability two safer ways — so OpenClaw no longer earns its place, and it carries by far the worst security profile in the stack. It was never installed (`03-install-openclaw.ps1` never ran), so this is a plan decision, not a teardown.

**Its three intended jobs all found other homes:**
1. **Coding dispatch + nightly cron → the fleet.** `run-fleet.ps1` + `new-agent-task.ps1` already run a serial queue with worktree isolation, secret-scan/verify/review gates, crash-resume, a time budget, and a morning `SUMMARY.txt` (§8, §13). Cron is Windows Task Scheduler invoking `run-fleet.ps1`. That is *more* than OpenClaw's cron, with guardrails it would not give.
2. **Conversational "describe an idea → decompose → dispatch" → BlarAI's 14B AO/PA.** That decompose-and-dispatch brain is the agreed BlarAI integration (`docs/blarai-headless-coding-agent-brief.md`): you talk to the 14B, it enqueues fleet tasks and reads results back. An OpenClaw gateway in the same seat would be a redundant second brain — one with exec rights, the opposite of BlarAI's air-gapped posture.
3. **Smart-home chat → Home Assistant's own Assist.** When the HAOS VM lands (§6.3), HA Assist can point its conversation agent at the OVMS endpoint (local LLM, loopback) for "dim the lights"-style control with no separate gateway; BlarAI could front it later too.

**Why not install it hardened anyway? The security math is lopsided.** OpenClaw is the most dangerous component the blueprint ever contemplated: it had **137+ security advisories in Feb–Apr 2026**, an actively-exploited one-click RCE (CVE-2026-25253 "ClawBleed"), and a skill registry where ~1 in 12 packages was malicious ("ClawHavoc"). Skills run **in-process with full gateway access**; its per-tool sandbox needs Docker (you don't have it) — and that sandbox **does not even wrap the ACP coding harnesses it would spawn**. Community data also put 14B-class local models in "flaky tool calls" territory for its loop. Bolting the stack's largest attack surface onto a security-first machine to cover jobs now done by a PowerShell supervisor and an air-gapped model is a bad trade.

**Revisit only if** a concrete need for a unified *multi-channel* chat gateway (WhatsApp/Telegram/Matrix in one brain) appears that HA Assist + BlarAI genuinely cannot meet — and then pinned, loopback-only, zero ClawHub skills, ideally in a memory-capped WSL2 distro, as a deliberate decision rather than a default phase. The full hardened-install plan (posture rules, the WSL2 isolation snippet, OVMS wiring) is preserved in git history (this section before 2026-06-21) and in `research/openclaw.md` if that day comes.

---

## 6. Use-case playbooks

### 6.1 OCR product scanning → inventory DB
- **Pipeline:** phone/camera image → RapidOCR (PP-OCRv5 on NPU via OpenVINO EP) for text extraction → Qwen3-VL-8B only for hard cases (curved labels, stylized fonts) → normalize → SQLite.
- **Database: SQLite** (via Python `sqlite3`/SQLAlchemy or EF Core). Zero-server, zero-RAM-budget, perfect offline, and the e-commerce site reads the same file. Move to Postgres only if you outgrow it (you won't soon).
- Python project on **uv-managed Python 3.12** (NOT 3.14 — paddle/OCR wheels lag): `uv init inventory && uv python pin 3.12 && uv add rapidocr-openvino fastapi sqlalchemy`.

### 6.2 E-commerce site against the inventory DB
- Stack the agent should target: **FastAPI (Python) or Express/Node backend + Vite+React frontend + SQLite**, served on LAN. All seeded for offline via Verdaccio + wheelhouse (§9).
- Have OpenCode scaffold it in the Everyday tier (14B is fine for CRUD web work; swap to coder-30b for the gnarly parts).

### 6.3 Smart home + dashboards + cameras
- **Home Assistant OS in a Hyper-V Gen-2 VM** (3 GB static, Secure Boot OFF, External vSwitch — works reliably over **Ethernet/dock only**; Wi-Fi bridging is flaky). HA Core/venv is deprecated upstream — don't chase it. Add-ons inside HAOS give you Mosquitto, Zigbee2MQTT, Node-RED one-click.
- **Zigbee: buy a NETWORK coordinator** — SMLIGHT SLZB-06MG24 (~$45, Ethernet/PoE). Hyper-V has NO USB passthrough, so a USB stick can never reach the VM; the network coordinator sidesteps it and survives any future host migration.
- **Cameras:** ONVIF/RTSP PoE cameras only (Reolink/Amcrest class, never cloud-only). **go2rtc** (single native Windows exe) restreams everything; custom dashboards get sub-second WebRTC video from its `:1984`/`:8555` API.
- **Dashboards:** HA Lovelace first (covers 90% with zero code, works on Pixel 8 Pro + your Legion Y700 as wall panel). The coding agent builds a custom React page only for the multi-camera live wall (HA WebSocket API for state/control + go2rtc WebRTC for video).
- **Frigate (person detection): defer to Phase 2.** It's Linux/Docker-only; on this laptop it needs Docker Desktop+WSL2 with fragile iGPU passthrough and the NPU is unreachable from WSL2 today. The honest 24/7 answer: a **~$160 Intel N150 mini PC running HAOS bare-metal with the Frigate add-on** (OpenVINO on its iGPU). Your laptop is a dev machine that sleeps and reboots — don't make it the house's brainstem. HA full-backup restore makes the migration turnkey, and the network Zigbee coordinator moves with zero reconfig.
- APIs for the agent: HA REST + WebSocket (long-lived access token), MQTT, go2rtc HTTP API.

### 6.4 Android apps for the Pixel 8 Pro
- **Native Kotlin + Android Studio** (current stable; bundles its own JDK). Seed while online: SDK packages (`platform-tools`, latest platform + build-tools, usb_driver), accept licenses, build one real project to populate `~/.gradle` (wrapper dist + all Maven deps), add a `resolveAllDependencies` task, then live in **`gradlew --offline`** / Studio's "Offline work" toggle.
- ADB over USB to the Pixel is fully offline (enable Developer options + USB debugging). Skip emulator images (~8 GB each) — you have the real device. Skip NDK unless you do JNI.
- The chronic pain (all frameworks): **adding a NEW dependency while offline fails by design** — budget periodic online re-seeding sessions. If you ever build a C#-centric app: .NET MAUI is actually the most offline-friendly Android pipeline (pure NuGet + workload cache, no Gradle).
- **RAM:** Android Studio + Gradle daemon = 4–7 GB. Run it in the Everyday tier (14B), never alongside coder-30b.

### 6.5 Screenshot debugging
Swap to `qwen3-vl-8b` (or stay in Everyday tier where 14B+VL fit together), paste the screenshot into OpenCode, ask for diagnosis, swap back. With 14B resident you can keep both loaded — that's the recommended "UI debugging day" configuration.

### 6.6 Local AI applications (BlarAI-adjacent)
Your OpenVINO GenAI stack IS the platform: Python 3.12 venvs + `openvino`, `openvino-genai`, `openvino-tokenizers` wheels (seed them in the wheelhouse). The agent can develop against the same OVMS endpoint it uses for itself. Whisper-small + Kokoro on disk give you STT/TTS for assistant-style apps. Keep BlarAI's repo itself off-limits to agents.

---

## 7. Languages coverage

| Language | Toolchain | Offline strategy |
|---|---|---|
| Python | uv + Pythons 3.12/3.13/3.14 | uv cache (19.4 GB already!) + `C:\offline\wheelhouse` (cp312 AND cp314), `UV_OFFLINE=1` |
| JS/HTML/CSS | Node 24 + pnpm + Verdaccio local registry | Verdaccio proxy-cache (the ONLY way scaffolders like `npm create vite` work offline) |
| C# | .NET 10 LTS (8 dies 2026-11-10!) | offline SDK installer + NuGet folder feed + `--locked-mode` + workload cache for MAUI |
| C++ | VS Build Tools offline layout (~10 GB, MSVC ABI — you need it as an OpenVINO contributor anyway) + w64devkit (120 MB, can-never-break fallback) | layout + vcpkg asset cache (`X_VCPKG_ASSET_SOURCES`) |
| Android/Kotlin | Android Studio + seeded SDK/Gradle | `gradlew --offline` after seeding |
| JSON/config | — | free |
| Docs for humans | Zeal + docsets | offline by design |
| Docs for agents | `C:\offline\docs` — git clones of mdn/content (~0.5 GB pure Markdown), dotnet/docs, framework docs repos, Python plain-text docs | agents grep Markdown far better than they drive doc apps |

---

## 8. Autonomous / fleet operation — honest expectations

**The realistic fleet on this hardware is a serial queue: 1 active coding agent (+1 light lane).** Two 14B agents on one server each run at half speed; more is counterproductive. Cloud-agent blogs assume 64 GB+ or discrete GPUs — calibrate to ~**5–15 completed tasks per night** (agent turns are prefill-dominated, ~100k+ tokens/task at 10–25 t/s).

**The pattern:**
1. `opencode serve --hostname 127.0.0.1 --port 4096` running persistently (with `OPENCODE_SERVER_PASSWORD`).
2. **One task → one branch → one worktree → one agent** (`scripts\new-agent-task.ps1` automates: `git worktree add ..\repo-task -b agent/task` → `opencode run --dir <worktree> "<task>"`). Worktrees prevent file collisions, NOT semantic conflicts — keep task boundaries disjoint.
3. Merge gate every morning: tests pass + you read the diff (`git diff main...agent/task`) like a colleague's PR. Never let an agent run in your main checkout.
4. Nightly dispatch via **Windows Task Scheduler** → `run-fleet.ps1` over a queue built with `add-fleet-task.ps1` (§13), with 1 active agent (+1 light lane) — the honest limit of this box. (OpenClaw's cron was the original Phase-4 plan; it was dropped — see §5. Conversational dispatch instead comes from BlarAI's 14B AO/PA enqueuing fleet tasks.)
5. **Overnight survival** (`scripts\05-overnight-power.ps1`): AC power required, sleep/hibernate disabled while plugged in, Windows Update active hours set. A thin laptop will thermally throttle on multi-hour inference — expect reduced t/s, that's fine. These kill overnight runs more often than OOM does.
6. Fleet tier = **qwen3-14b only**. The first `npm ci` or pytest spike on top of coder-30b starts paging exactly when an agent is mid-task.

---

## 9. Offline seeding plan (one weekend, while online)

Priority order — `scripts\04-seed-offline.ps1` automates the top of this list:
1. **Python:** `uv python install 3.12 3.13 3.14`; build `C:\offline\wheelhouse` with `pip download --only-binary=:all:` for **both cp314 and cp312** (paddle/OCR needs 3.12; uses `configs\requirements-all.txt`). NEVER run `uv cache clean` — the 19.4 GB cache is your offline safety net.
2. **Node:** Verdaccio (+ offline-storage plugin) as a logon task at `http://localhost:4873`; point npm + pnpm at it; scaffold each stack once online (Vite/React/Vue/Next/Express/Tailwind + your e-commerce deps) so every tarball gets cached.
3. **.NET:** download .NET 10 SDK offline installer NOW; seed `C:\offline\nuget-feed` via a kitchen-sink `dotnet restore --packages`; lockfiles + `--locked-mode`; `dotnet workload install maui-android --download-to-cache` if MAUI interests you.
4. **C++:** VS Build Tools offline layout (`--layout C:\offline\vslayout --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended`, ~6–12 GB) + drop w64devkit zip on disk; set `X_VCPKG_ASSET_SOURCES` file cache.
5. **Android:** Android Studio + SDK seeding + one full Gradle build (§6.4).
6. **Docs:** clone mdn/content, dotnet/docs, framework docs; download Python plain-text docs; install Zeal.
7. **Verification ritual:** airplane mode ON → `uv add` from wheelhouse, `npm create vite`, `dotnet build` with a cached package, `cl /EHsc hello.cpp`, `gradlew --offline assembleDebug`, `adb install`, OpenCode starts and completes a task against OVMS. For hard guarantees, use per-exe outbound firewall rules instead of airplane mode.

**Disk budget:** models ~17 GB new + toolchain seeds 40–60 GB against 230 GB free = fine, but don't add MDN ZIM (10 GB), NDK (4 GB), emulator images (8 GB each), or Flutter (5 GB) until actually needed. Reclaim 16.8 GB by deleting `~/.ollama` after coder-30b is verified.

---

## 10. Monitoring, failure signatures, and rollback

- **Watch:** Task Manager → Performance → GPU → "Shared GPU memory"; and Memory → "In use". Yellow line: >26 GB in use. `scripts\start-llm.ps1` pre-checks free RAM and warns.
- **Failure signatures → causes:**
  - A command/tool fails with `EPERM`/`operation not permitted`/access denied for no visible reason → check Bitdefender Notifications first. Its Advanced Threat Defense blocks PowerShell command lines that pattern-match recon (Bypass + web request + process listing) — confirmed 2026-06-10 (it blocked a benign health check). Policy: NO broad exclusions (never whitelist pwsh.exe); if a specific agent workflow is repeatedly blocked, decide a narrow per-detection exception then, not before. Overnight runs that died mysteriously: check here before blaming the stack.
  - `ErrorOutOfDeviceMemory` / model load fails → memory tier violated; run the lean-profile checklist.
  - Model prints raw JSON/XML instead of acting → tool-calling plumbing (wrong endpoint path, missing `--tool_parser`, ctx too small, output truncation). Not a bad model.
  - Screen freeze/black flicker during inference → GPU driver TDR; note driver version, avoid Vulkan backends, report/rollback driver.
  - Overnight run dead at 3am → power/sleep/Windows Update, not the stack. Re-run `05-overnight-power.ps1`.
- **Driver policy:** current Arc driver 32.0.101.8826 (2026-05-28) postdates all known-bad versions. Before any driver update: finish in-flight work, note the current version, keep the previous installer. Inference stability on this machine is driver-bound.
- **Before first autonomous run:** create a restore point + zip your key config files (opencode.json, the OVMS start scripts, the fleet scripts/configs under `scripts\`). Known-good config archive = 5 minutes now, hours saved later.
- **Version pinning doctrine:** OpenCode ships multiple releases/day; OpenClaw weekly. Pin both; update on YOUR schedule (monthly, reading release notes), re-verify offline behavior after each update.

---

## 11. Install order (phases)

| Phase | What | Script | Status |
|---|---|---|---|
| 0 | Recon, blueprint, configs | — | ✅ done (this doc) |
| 1 | OpenCode + global config | `01-install-opencode.ps1` | ✅ executed 2026-06-10 |
| 2 | OVMS + coder-30b download (~17 GB) | `02-install-ovms-and-models.ps1` | ⬜ run while online |
| 3 | First agentic session: `start-llm.ps1 -Model coder-30b` → `opencode` in a test repo | — | ⬜ |
| 4 | ~~OpenClaw pinned + hardened~~ — **dropped (see §5)**; orchestration = fleet + BlarAI AO/PA, cron = Task Scheduler, HA chat = HA Assist | — | ❌ |
| 5 | Offline seeding weekend | `04-seed-offline.ps1` + §9 manual items | ⬜ |
| 6 | Smart-home: HAOS VM + SLZB-06MG24 + go2rtc | §6.3 | ⬜ |
| 7 | Android: Studio + SDK + Gradle seed | §6.4 | ⬜ |
| 8 | First overnight fleet run (14B, one task) | `05-overnight-power.ps1`, `new-agent-task.ps1` | ⬜ |
| 9 | Phase-2 hardware: N150 mini PC for HA/Frigate 24/7 | §6.3 | ⬜ future |

---

## 12. Maturity wave (2026-06-10) — what changed and the operating notes

Implemented from a 5-agent audit (`research/maturity/`, plan in `verdict.md`). This folder is now a **local git repo** — every config change is committed; `git log` here is the change history.

**New Desktop buttons:** `AI Status` (read-only health view — start here when anything seems wrong), `Backup AI Configs` (dated zip, keeps 12), `Check AI Updates` (report-only, never installs), `Harden (Admin, run once)` (OVMS outbound firewall block + Windows Update active hours 13:00–07:00). Desktop .cmd files are now 2-line stubs calling the originals here — edit only in this folder.

**Hardening now active:**
- OpenCode permissions: asks before destructive bash (rm/del/git push/reset --hard/clean), denies reads of `~/.ssh`, `~/.git-credentials`, `~/.blarai-fleet`; web tools disabled (offline-first); compaction pruning + tool-output caps (anti-compaction-loop); Qwen-correct sampling (temp 0.7/top_p 0.8); global rules in `~/.config/opencode/AGENTS.md`.
- **Home-dir repo guard:** `C:\Users\mrbla` is itself a git repository — Open Coding Chat now offers `git init` for any picked folder lacking its own `.git`, so agent git commands can't walk up into the home repo.
- `.wslconfig` capped (memory=4GB, processors=4) — disarms the WSL2 50%-RAM balloon (general WSL2 hygiene; was staged for OpenClaw, now dropped — §5).
- Server logs: every start writes `state\logs\ovms-<model>-<stamp>.{out,err}.log` (newest 20 kept); failures auto-print the last 15 lines.

**OVMS operating notes (from the audit):**
- Do NOT use OVMS's built-in Windows-service installer — it binds 0.0.0.0 and runs as LocalSystem (violates loopback-only). The launcher scripts are the supported path.
- Hard-stopping ovms.exe is safe (model files read-only). If a model *load* was interrupted and later starts fail oddly: delete `C:\models\ov_cache`, retry.
- 30–90s of compile/load time on every model start is expected behavior, not a fault.
- Future watchdog contract (Phase 8): health = GET `/v2/health/ready` + id-match on `/v3/models`; must be sentinel-gated so it never fights "Stop AI Models".
- Vision = swap workflow by policy. No third-party vision plugins (the popular ones are Ollama-hardcoded and would double model RAM).
- **Browser tool file access:** playwright-mcp blocks `file://` navigation by default; we pass `--allow-unrestricted-file-access` (gauntlet test 2026-06-11 caught this). Accepted residual: the browser can technically read files the agent's read-tool denies (.ssh etc.) — layered defense (AGENTS.md prohibition + harness tamper-evidence) covers it; revisit if multi-user.
- **Prefix caching is ON** (pinned `--enable_prefix_caching true`; verified 2026-06-10: ~2,900-token re-read dropped from ~14s to ~1s). Conversations do NOT re-read from scratch each turn. The cache legitimately misses (one-time re-read) after: a session compaction (transcript gets rewritten), a model swap or server restart, or when the 4 GB cache pool evicts old sessions. Does not apply to Qwen3.5/3.6-class hybrid models (known OpenVINO memory issue) — ours are unaffected architectures.

**Keys cheat-sheet (OpenCode):** `f2` cycle recent models · `ctrl+x m` model list · `Tab` Build/Plan · `ctrl+x c` compact session · `/new` fresh task · custom keybinds belong in `~/.config/opencode/tui.json`, never opencode.json.

**5-minute smoke checklist (run after any update):** Everyday launcher → READY names qwen3-14b → AI Status shows it green → Open Coding Chat auto-picks it → Stop AI Models → VM restart offered if one was stopped → a dated log pair exists in `state\logs`. Executed 2026-06-10: all pass.

## 13. Autonomous maturity session (2026-06-14) — guardrails for small models + longer unattended runs

Built unattended by Claude (Opus 4.8) on branch `maturity/autonomous-2026-06-14`. Goal: make longer agentic sessions safe with smaller (error-prone) models. All new scripts are ASCII + UTF-8-BOM and AST-parse clean; shared helpers live in `scripts/fleet-lib.ps1`.

**Guardrails added to the fleet pipeline (`new-agent-task.ps1`):**
1. **Circuit breaker** — every model call (build + review) runs under a hard wall-clock cap (`-MaxRunMinutes` 30 / `-MaxReviewMinutes` 10); on timeout the whole process tree is killed. A post-run scan (`Get-RunAnomalies`) flags doom-loops (a line repeated >=12x), opencode's doom flag, and non-zero exits.
2. **Secret-scan gate** — `secret-scan.ps1` runs gitleaks on staged changes BEFORE the commit; a detected secret means nothing is committed (never enters history) and nothing merges. Fail-closed.
3. **Verify gate** — `verify-project.ps1` runs build/typecheck/lint (Node, Python, .NET), offline + forgiving (missing tool/config = skip; only a real non-zero or a hang = fail).
4. **Auto-merge gate** now requires: changes present AND not secret-blocked AND not timed-out AND no loop AND tests != fail AND verify != fail AND review verdict = MERGE; otherwise the task is parked for the morning review. The report gained TRANSCRIPT / VERIFY / SECRETS / ANOMALIES lines.

**Longer unattended runs — `run-fleet.ps1` (the supervisor):** runs a JSON task queue serially (1 active agent), each task in its own worktree via `new-agent-task.ps1`. Survives long runs: waits for OVMS READY before each task (never starts/stops models itself), RESUMES after a crash/reboot (`-RunId`), stops cleanly at an overall time budget, journals every step, writes a morning `SUMMARY.txt`. Build a queue with `add-fleet-task.ps1` (format in `configs\fleet-queue.sample.json`).

**Secret scanner install:** `install-gitleaks.ps1` — pinned gitleaks v8.30.1, SHA-256 verified, installs to `tools\gitleaks\` (gitignored). Optional `-SetGlobalTemplate` makes new `git init` repos inherit the pre-commit hook (`configs\gitleaks\git-template\hooks\pre-commit`); allowlist in `configs\gitleaks\gitleaks.toml`.

**Inference reliability (opt-in / staged — needs a live smoke test before trusting):**
- `start-llm.ps1 -GuidedGen` adds `--enable_tool_guided_generation` to the qwen3-14b launch (coder-30b already has it). DEFAULT OFF — validate first with `test-guided-gen.ps1` (reasoning+grammar interaction unproven), then adopt.
- `configs\opencode-plugins\qwen-sampling.js` (staged, not installed): `top_k=20` + `repetition_penalty=1.05`. Install + verify per its README before trusting.

**Evidence layer (measure, don't guess):** `run-evals.ps1` (tiny golden-task regression suite in `evals\tasks\`; `-Mock` self-tests offline) and `fleet-report.ps1` (per-task reports -> plain trend: merged/parked/blocked + which guardrails fired).

Surfaced in the AI Control Panel (keys F/E/G/T). Everything offline, loopback-only, RAM-respecting (no second resident model), reversible. Session archive: `docs/sessions/2026-06-14-maturity/` (plan + review). Try-it-out + re-runnable checks: `docs/testing-guide.md`.

## 14. Source map

Full research with URLs: `research/opencode.md`, `research/openclaw.md`, `research/inference.md`, `research/models.md`, `research/offline-toolchains.md`, `research/smarthome.md`, `research/orchestration.md`, and the adversarial cross-check in `research/verification.md`. Everything above that contradicts a blog you read later — check the verification file first; it caught the blogs being wrong four times.
