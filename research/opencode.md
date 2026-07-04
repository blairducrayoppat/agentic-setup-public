# opencode

## FINDINGS
## 1. Install and current version (June 2026)
- Repo moved from sst/opencode to **anomalyco/opencode** (SST = anomaly innovations; "anomalyco" GitHub org). npm package is still **opencode-ai**.
- Current version: **v1.17.3 (released June 10, 2026)**; v1.16.2 was June 5. Release cadence is multiple releases/day, so pin/check often.
- Windows install options (official docs): `npm install -g opencode-ai` (best fit here, Node 24 present), `scoop install opencode`, `choco install opencode`, bun/pnpm/yarn, direct Windows x64 zip from GitHub releases, `curl -fsSL https://opencode.ai/install | bash` (WSL). **winget is NOT documented.** Docs still say "WSL recommended" for best experience, but native Windows works.
- First run: `opencode` opens TUI; `/connect` adds providers (NOT required for local providers defined in config); `/init` generates AGENTS.md.

## 2. Local OpenAI-compatible provider config
Global config: `%USERPROFILE%\.config\opencode\opencode.json` (yes, `.config` even on Windows); project-level `opencode.json` overrides global. Env overrides: `OPENCODE_CONFIG`, `OPENCODE_CONFIG_DIR`, `OPENCODE_CONFIG_CONTENT` (inline JSON).

Canonical local provider block (works for Ollama/llama.cpp/LM Studio/OVMS — anything with /v1/chat/completions):
```json
{
  "$schema": "https://opencode.ai/config.json",
  "provider": {
    "local": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "Local",
      "options": { "baseURL": "http://127.0.0.1:8080/v1", "apiKey": "none" },
      "models": {
        "qwen3-coder-30b-a3b": {
          "name": "Qwen3 Coder 30B A3B",
          "tool_call": true,
          "attachment": false,
          "reasoning": false,
          "limit": { "context": 65536, "output": 8192 }
        }
      }
    }
  },
  "model": "local/qwen3-coder-30b-a3b",
  "autoupdate": false,
  "share": "disabled"
}
```
- Base URLs: Ollama `http://localhost:11434/v1` (must be /v1, not /api); llama.cpp server `http://127.0.0.1:8080/v1`; LM Studio `http://127.0.0.1:1234/v1`; **OpenVINO Model Server uses `/v3`** → `http://localhost:8000/v3` (OVMS 2026.1 exposes OpenAI chat/completions at /v3 with CPU/GPU/NPU, and supports tool calling via `--tool_parser` for e.g. gpt-oss, Qwen/Hermes-style models — documented in OVMS "Agentic AI" demo).
- Per-model schema flags (verified against https://opencode.ai/config.json schema): `tool_call`, `attachment`, `reasoning`, `temperature` (bools), `limit: {context, output}`, `modalities: {input: ["text","image",...]}`, `options` (passed through; `extraBody` for raw payload e.g. `{"extraBody": {"think": "high"}}` for gpt-oss on Ollama), `headers`, `variants`, per-model `provider.npm` override.
- Context window: OpenCode effectively needs >=16k; Ollama's own OpenCode integration doc recommends **>=64k**. For Ollama the OpenAI endpoint ignores opencode's limit — set context in Ollama itself: `ollama run model` then `/set parameter num_ctx 32768`, `/save model-32k`, or `OLLAMA_CONTEXT_LENGTH`. Official docs: "If tool calls aren't working, try increasing num_ctx... start around 16k-32k."

## 3. Offline / telemetry
- No account/auth-server requirement; local providers need no login; sharing is opt-in (`"share": "disabled"`); no analytics telemetry by default (only an opt-in `experimental.openTelemetry` flag for AI SDK spans); `"autoupdate": false` disables update checks.
- BUT it is **not cleanly air-gapped**: startup unconditionally fetches `https://models.dev/api.json` (provider/model catalog), downloads LSP server manifests/binaries on demand, and `opencode web` pulls CDN assets. Open feature requests #16117/#18492 (dup of #2224 from Aug 2025) for an `--offline` flag remain unimplemented as of early 2026. `OPENCODE_MODELS_URL` exists but is reported inconsistent (#11385). The models.dev response is cached under `~/.cache/opencode`, so after one online run startup generally works offline — but this is community-reported, not guaranteed. Community air-gapped forks exist: Chetic/opencode-offline and amitok2/opencode-offline (vendor models.json via `MODELS_DEV_API_JSON` at build time, bundle ripgrep/LSP). Set `"lsp": false` or configure only locally-installed LSP servers to avoid LSP downloads.
- Known native-Windows bugs (2025-2026 issues): TUI crash on terminal resize in CMD (#7943), freeze before TUI from missing fast-deep-equal in `~/.cache/opencode` node_modules (#9870), garbled TUI in git-bash (#7539), version mismatch in windows-x64 zip (#23554), localhost vs WSL-IP issues when mixing WSL server + Windows client. Use Windows Terminal/WezTerm/Ghostty; avoid cmd.exe and git-bash for the TUI.

## 4. Local models that work with the agentic loop (community, June 2026)
- **Qwen3-Coder-30B-A3B-Instruct** — most-cited local OpenCode model; MoE 3B-active so fast on modest hardware; needs 16k+ ctx; non-thinking; Q4_K_M GGUF \~18-19GB. Newer **Qwen3-Coder-Next (80B-A3B)** is the 2026 favorite but too big for 32GB.
- **gpt-oss-20b** — repeatedly reported good in OpenCode once ctx raised to 32k and reasoning set high (Bas Nijholt writeup with exact Ollama `/set parameter num_ctx 32768` + opencode.json `extraBody {"think":"high"}`); MXFP4 \~12-13GB; OpenVINO INT4 conversion exists (OpenVINO/gpt-oss-20b-int4-ov) and OVMS has a gpt-oss tool parser.
- **Devstral Small 2 (24B)** — 68% SWE-bench Verified, built for agentic SWE, runs in 32GB RAM at Q4 (\~14GB).
- Smaller: omnicoder-9b (purpose-tuned for OpenCode tool calling, virtualizationhowto May 2026), Gemma 3n E4B reported working.
- Reported NOT working well: DeepCoder 14B (no tools), **qwen2.5-coder (the user's existing Ollama blobs) — multiple reports of unreliable/failed tool calling in OpenCode's loop**.

## 5. Autonomous-dev features
- **LSP**: 30-40+ built-in language servers, auto-spawned by file type; diagnostics fed to the agent via a diagnostics tool; configurable/disable-able via `"lsp"` config.
- **MCP**: local (`{"type":"local","command":[...],"environment":{...}}`) and remote (`{"type":"remote","url":...,"headers":...}`) servers under `"mcp"`; per-server `enabled`; OAuth w/ RFC 7591 dynamic registration; `opencode mcp auth <name>`.
- **Agents**: primary agents (Build = full access, Plan = restricted) switched with Tab; subagents (General, Explore, Scout) invoked via @mention or auto-delegation, run as child sessions (parallel); custom agents in opencode.json or markdown files (`~/.config/opencode/agents/`, `.opencode/agents/`) with per-agent `model`, `temperature`, `steps` (max iterations), granular `permission` incl. bash glob patterns.
- **Headless/programmatic**: `opencode serve --port 4096 --hostname 127.0.0.1` exposes an OpenAPI 3.1 HTTP API (spec at `/doc`): session create/list/abort, message prompt, file search/read, event stream (SSE), even remote TUI control endpoints. Basic-auth via `OPENCODE_SERVER_PASSWORD`/`OPENCODE_SERVER_USERNAME`. Official JS/TS SDK **@opencode-ai/sdk** (`createOpencode()` spawns server+client; `createOpencodeClient({baseUrl})` attaches to a running one; `client.session.prompt({path:{id}, body:{parts, model:{providerID, modelID}}})`). No official Python SDK, but the OpenAPI spec allows generating one. Multiple concurrent sessions are first-class via the server API. Also `opencode run "prompt"` for one-shot non-interactive CLI use.

## 6. Vision/image input
- TUI supports drag-and-drop and clipboard paste (Ctrl+V) of images, but only if the active model is vision-capable. For custom local providers you must declare it: `"attachment": true` (and/or `"modalities": {"input": ["text","image"]}`) on the model; the image goes out as standard OpenAI `image_url` content, so it works with any local server that accepts that (Ollama vision models, llama.cpp multimodal, LM Studio, OVMS VLM serving — relevant since the user already runs Qwen3-VL-8B under OpenVINO).
- For non-vision coding models, community plugins route images to a local vision model: aosama/opencode-image-comprehension (intercepts pasted images, calls a local Ollama vision model via a `comprehend_image` tool) and DavidEasden/opencode-vision (MCP `local_vision` tool).

## RECOMMENDATION
For this machine: install natively with `npm install -g opencode-ai` (Node 24 already present; gets v1.17.x and easy `npm update -g` pinning) and run it inside Windows Terminal — skip WSL since everything else (OpenVINO, BlarAI/Hyper-V) is Windows-native and WSL adds a second filesystem boundary. Immediately set `"autoupdate": false` and `"share": "disabled"`, run it once online so the models.dev catalog caches, and set `"lsp": false` (or only locally-installed servers) if strict offline matters.

Backend: given the user is an OpenVINO contributor with a working Arc 140V GenAI stack, the cleanest path is **OpenVINO Model Server 2026.1** serving **gpt-oss-20b-int4-ov** (fits the \~16GB iGPU shared-memory budget, OVMS has a gpt-oss tool parser, community-proven in OpenCode at 32k ctx with high reasoning) with `baseURL: "http://localhost:8000/v3"`. Second model to try: **Qwen3-Coder-30B-A3B-Instruct INT4** (best local agentic reputation in OpenCode, MoE 3B-active so CPU/hybrid speed is acceptable, but \~19GB weights + KV means it must spill past the iGPU's 16GB shared limit — run it CPU-side or accept hybrid). If reinstalling Ollama instead, do NOT rely on the existing qwen2.5-coder blobs (community reports its tool calling fails in OpenCode); pull `gpt-oss:20b` and create a 32k-ctx tag (`/set parameter num_ctx 32768` → `/save`). Declare models with `tool_call: true` and explicit `limit: {context: 65536, output: 8192}` (32k minimum; Ollama's own doc says 64k+ for OpenCode).

For autonomous orchestration from another program, use `opencode serve` + `@opencode-ai/sdk` (or raw OpenAPI at :4096/doc) — sessions, prompts, aborts, and event streaming are all exposed, and `opencode run` covers one-shot scripting. For screenshots, serve Qwen3-VL-8B (already working on this machine) as a second OVMS/llama.cpp model with `"attachment": true`, or add the opencode-image-comprehension plugin to keep the coder model text-only.

## CAVEATS
- Strict air-gap is NOT first-class: startup fetches models.dev/api.json and LSP manifests; the --offline flag remains an open feature request (issues #2224/#16117/#18492). The "cached catalog works offline after first run" behavior is community-reported, not contractual — verify on this machine before depending on it, or use the Chetic/amitok2 opencode-offline forks / MODELS_DEV_API_JSON build-time vendoring.
- Native Windows is second-tier: documented TUI bugs (crash on resize in CMD #7943, startup freeze from cache corruption #9870, git-bash rendering #7539, release-zip version mismatch #23554). Upstream still recommends WSL; if the TUI misbehaves, `opencode serve` + SDK or `opencode run` avoid the TUI entirely.
- Memory math is tight: Qwen3-Coder-30B-A3B Q4/INT4 (\~19GB + KV at 32-64k ctx) exceeds the Arc 140V's \~16GB shared-GPU budget and will compete with the rest of the 32GB system; gpt-oss-20b or Devstral Small 24B are the realistic GPU-resident ceilings. NPU (47 TOPS) is irrelevant here — no serving path runs these agentic LLMs on it well.
- OVMS tool-parser coverage is model-specific (gpt-oss, Qwen/Hermes styles); verify the exact `--tool_parser` flag for the chosen model in OVMS 2026.1 docs before assuming OpenCode's loop works.
- Release velocity is extreme (4 releases on June 10 alone); exact version numbers and config-schema details in this report may be stale within weeks. winget support could not be confirmed (not in docs).
- Vision: image paste only reaches the model if `attachment: true` is set AND the local server accepts OpenAI image_url payloads; there is a known clipboard-paste bug report on some platforms (#10154).
- Some quantitative model claims (SWE-bench scores, "best model" rankings) come from secondary blogs/aggregators, not first-party benchmarks.

## SOURCES
https://opencode.ai/docs/
https://opencode.ai/docs/providers/
https://opencode.ai/docs/windows-wsl/
https://opencode.ai/docs/server/
https://opencode.ai/docs/sdk/
https://opencode.ai/docs/agents/
https://opencode.ai/docs/mcp-servers/
https://opencode.ai/docs/models/
https://opencode.ai/docs/lsp/
https://opencode.ai/config.json
https://github.com/anomalyco/opencode/releases
https://github.com/anomalyco/opencode/issues/16117
https://github.com/anomalyco/opencode/issues/18492
https://github.com/anomalyco/opencode/issues/9870
https://github.com/anomalyco/opencode/issues/7943
https://github.com/anomalyco/opencode/issues/7539
https://github.com/anomalyco/opencode/issues/23554
https://github.com/anomalyco/opencode/issues/10154
https://github.com/Chetic/opencode-offline
https://github.com/amitok2/opencode-offline
https://docs.ollama.com/integrations/opencode
https://www.nijho.lt/post/ollama-opencode/
https://www.virtualizationhowto.com/2026/05/i-built-a-local-ai-coding-agent-home-lab-setup-with-opencode-and-ollama/
https://medium.com/@lexy_eyn/how-to-connect-a-local-qwen3-coder-30b-to-opencode-and-create-a-self-hosted-claude-code-alternative-4f0db7f38cc2
https://github.com/aosama/opencode-image-comprehension
https://github.com/DavidEasden/opencode-vision
https://opencode.school/lessons/images/
https://docs.openvino.ai/2026/model-server/ovms_docs_rest_api_chat.html
https://docs.openvino.ai/2025/model-server/ovms_demos_continuous_batching_agent.html
https://huggingface.co/OpenVINO/gpt-oss-20b-int4-ov
https://www.mindstudio.ai/blog/best-open-source-llms-agentic-coding-2026
https://unsloth.ai/docs/models/qwen3-coder-next
https://opencodex.cc/en/tutorials/config-priority
https://haimaker.ai/blog/opencode-custom-provider-setup/
