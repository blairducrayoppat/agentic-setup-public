# openclaw

## FINDINGS
## 1. What OpenClaw is now (June 2026)

- History confirmed: published Nov 2025 by Peter Steinberger (PSPDFKit founder), originally Clawdbot/"Warelay"-derived, renamed Moltbot on 2026-01-27 (Anthropic trademark complaint), then OpenClaw on 2026-01-30. Steinberger joined OpenAI 2026-02-15; the project is now stewarded by the OpenClaw Foundation. ~378k GitHub stars, 79k forks, MIT license.
- Current npm version: **2026.6.5** (date-based vYYYY.M.D scheme; stable/beta/dev dist-tags). Requires **Node >= 22.19.0, Node 24 recommended** (the target machine's Node 24 satisfies this).
- Architecture: a local-first **Gateway** (Node.js WebSocket server, default port **18789**) is the control plane. Around it: **Channels** (20+: WhatsApp, Telegram, Slack, Discord, Signal, iMessage, Matrix, IRC, MS Teams, WebChat/browser Control UI, etc.), **Skills** (workspace folders of markdown + scripts; public registry = ClawHub), **Cron** (scheduled jobs), **Nodes** (paired devices — iOS/Android/macOS/Windows companion apps exposing screen/camera/TTS/STT/notifications), **Agents** (multi-agent routing with isolated workspaces), sessions stored via SQLite/kysely.
- Windows: runs **native** (no WSL strictly required). Three options: (a) **Windows Hub** — signed WinUI companion app (OpenClawCompanion-Setup-x64.exe, no admin needed; tray, chat, node mode, can create an app-owned "OpenClawGateway" WSL distro); (b) **native CLI/gateway**: `iwr -useb https://openclaw.ai/install.ps1 | iex` or `npm install -g openclaw@latest` then `openclaw onboard --install-daemon`; `openclaw gateway install` registers a Windows service; (c) **WSL2**, which docs call "the most Linux-compatible Gateway runtime on Windows" — preferred for full channel/tool compatibility.

## 2. Local-model configuration (exact)

Config file: `~/.openclaw/openclaw.json` (JSON5). Ollama native API is the most reliable local path; **do NOT point it at Ollama's `/v1` OpenAI endpoint — docs warn this breaks tool calling** ("models may output raw tool JSON as plain text").

Ollama (native API):
```json5
{ models: { providers: { ollama: {
    baseUrl: "http://127.0.0.1:11434",   // no /v1 suffix
    apiKey: "ollama-local", api: "ollama",
    timeoutSeconds: 300, contextWindow: 32768, maxTokens: 8192,
    models: [{ id: "qwen2.5-coder:14b", name: "qwen2.5-coder:14b",
               params: { num_ctx: 32768, keep_alive: "15m" } }]
  }}},
  agents: { defaults: { model: { primary: "ollama/qwen2.5-coder:14b" } } } }
```
Setting `OLLAMA_API_KEY=ollama-local` with no explicit provider block enables auto-discovery from `127.0.0.1:11434` (`/api/tags` + `/api/show`, auto-detects vision/tool support). Non-interactive onboard: `openclaw onboard --non-interactive --auth-choice ollama --custom-base-url http://127.0.0.1:11434 --custom-model-id <id> --accept-risk`. Test: `openclaw infer model run --model ollama/<id> --prompt "Reply with: ok"`.

LM Studio / any OpenAI-compatible server (this covers **OpenVINO Model Server**, vLLM, llama.cpp server):
```json5
{ models: { providers: { lmstudio: {
    baseUrl: "http://127.0.0.1:1234/v1", apiKey: "lmstudio",
    api: "openai-responses",   // use "openai-completions" unless /v1/responses is supported
    models: [{ id: "my-local-model", reasoning: false, contextWindow: 196608, maxTokens: 8192,
               cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } }] }}}}
```
Local-model knobs: `agents.defaults.experimental.localModelLean: true` (drops the 3 heaviest default tools: browser, cron, message — recommended when agent turns fail); per-model `params.extra_body.tool_choice: "required"` to force tool calls; `compat.supportsTools: false` as last resort; `compat.requiresStringContent: true` for message-format errors. Docs recommend >= 64k context for local models (hard floor warning at 8k); `models.mode: "merge"` keeps hosted models as fallbacks.

**Community reliability bar (2025–26 reports):** 7–8B models (Qwen3 8B, Llama 3.x 8B, Mistral 7B) "produce tool-call format errors constantly"; 14B-class (Qwen3 14B, DeepSeek-R1-Distill-14B, Qwen2.5-Coder-14B) work but are "not reliable enough for production agent tasks"; the consensus sweet spot is **24–32B** (current picks: Qwen3.6-27B, Devstral-24B, Qwen3-Coder/Qwen2.5-Coder-32B, Gemma3 27B, Mistral Small 3.1). Official docs are blunter: "≥2 maxed-out Mac Studios or an equivalent GPU rig (~$30k+) for a comfortable agent loop"; a single 24GB GPU = lighter prompts, higher latency; small/heavily-quantized models also "raise prompt-injection risk." Working production example: Mac Studio 32GB + Devstral-24B + LM Studio (stable 2 weeks).

## 3. Offline / air-gapped

Yes, feasible: Gateway + WebChat **Control UI** (browser, served from loopback) + Ollama/local OpenAI-compatible backend + local embeddings = zero external calls. No WhatsApp/Telegram needed. Things that DO phone home and how to kill them:
- **Update checks**: auto-update is off by default, but the gateway logs an update hint at startup → set `update.checkOnStart: false`; belt-and-braces `OPENCLAW_NO_AUTO_UPDATE=1`; pin with `npm i -g openclaw@2026.6.5`.
- **ClawHub telemetry**: sent only when logged into the CLI during `clawhub sync` (hashed root IDs, skill slugs/versions) → `CLAWHUB_DISABLE_TELEMETRY=1`, or simply never log in / never use ClawHub.
- **mDNS/Bonjour discovery broadcast** → `{"discovery":{"mdns":{"mode":"off"}}}` or `OPENCLAW_DISABLE_BONJOUR=1`.
- **Web search tool** (Brave/Ollama cloud-backed) and hosted model providers → don't configure; the Ollama provider's bundled web search requires ollama.com sign-in, skip it.
- Onboarding itself fetches from npm/GitHub, so install online once (or offline via npm cache), then air-gap.

## 4. Security posture (this is the big story of 2026)

OpenClaw went "from viral AI agent to security crisis in three weeks" (Feb–Apr 2026):
- **Exposed gateways**: ~40,000 internet-exposed instances at Feb 3 disclosure, 63% unauthenticated; later scans claimed 135,000+ across 82 countries (numbers vary by scanner — treat the larger figure cautiously).
- **CVE-2026-25253 "ClawBleed"** (CVSS 8.8, actively exploited): one-click RCE — Control UI blindly trusted a `gatewayUrl` query param and leaked the auth token over a cross-site WebSocket. Patched in **2026.1.29**.
- **CVE-2026-32922** (CVSS 9.9, published 2026-03-29): critical privilege escalation.
- Joel Gamblin's public tracker (github.com/jgamblin/OpenClawCVEs) logged **137–138 advisories between 2026-02-02 and 2026-04-04**.
- **ClawHub supply chain**: "ClawHavoc" campaign — 341+ malicious skills dropping Atomic Stealer (AMOS); totals reported 800–1,184 malicious skills; one audit found ~1 in 12 packages malicious as the registry passed ~13,700 skills. Skills/plugins run **in-process with full Gateway access** — official docs say treat them as trusted code.
- Prompt injection is explicitly unsolved per the docs; mitigation = allowlists + sandboxing + tool restriction, not prompts.

Official hardening (docs.openclaw.ai/gateway/security): keep `gateway.bind: "loopback"` (default); auth fails closed — use token mode (`openclaw doctor --generate-gateway-token`) or `OPENCLAW_GATEWAY_PASSWORD`; Tailscale Serve (not Funnel, not LAN binds) for remote access; `dmPolicy: "pairing"`, `groupPolicy: "allowlist"`; tool deny-lists, e.g. `{"tools":{"profile":"messaging","deny":["group:automation","group:runtime","group:fs","sessions_spawn","sessions_send"],"exec":{"security":"deny","ask":"always"}}}`; block `gateway`/`cron` control-plane tools on untrusted surfaces; `chmod 700 ~/.openclaw`, `600 openclaw.json`; `gateway.nodes.browser.mode: "off"`; SSRF guard `browser.ssrfPolicy.dangerouslyAllowPrivateNetwork: false` (default); run `openclaw security audit --fix` regularly. Sandboxing: whole-gateway-in-Docker, or `agents.defaults.sandbox` (`mode:"all"`, `scope:"agent"|"session"`, `workspaceAccess:"none"|"ro"|"rw"`) — **Docker is the default/only first-class sandbox backend**.

## 5. Orchestrating other agents

- **Sub-agents** (docs.openclaw.ai/tools/subagents): `sessions_spawn` spawns background agents in isolated sessions (`agent:<id>:subagent:<uuid>`), non-blocking, per-spawn `model`/`thinking` overrides (cheap model for workers, big model for orchestrator), `maxSpawnDepth: 2` enables orchestrator→worker nesting, `maxChildrenPerAgent` (default 5), `maxConcurrent`, `sessions_yield` to await results, auto-archive after 60 min.
- **ACP agents** (docs.openclaw.ai/tools/acp-agents): runs external coding harnesses — **Claude Code, OpenCode, Gemini CLI, Cursor, Copilot, Droid** — as ACP (Agent Client Protocol) backend sessions, tracked as background tasks, resumable via `sessions_spawn` + `resumeSessionId`. So yes, it can drive OpenCode directly.
- **MCP**: client support via `openclaw mcp add/set/configure/list/probe/login`; transports stdio (with env-injection safety filters blocking NODE_OPTIONS/PYTHONPATH), SSE, streamable-http (mTLS, OAuth, `toolFilter.include/exclude` globs). MCP tools surface in the normal tool profiles. Windows Hub can also act as a local MCP **server** exposing Windows capabilities to Claude Code/Cursor/Claude Desktop.
- Community: **goldmar/openclaw-code-agent** (Claude Code/Codex/experimental OpenCode as managed background coding sessions with plan approval, git-worktree isolation, merge/PR follow-through); **Enderfga/claw-orchestrator** (unified runtime for Claude Code/Codex/Gemini/Cursor/custom CLIs, multi-agent "councils", Planner/Coder/Reviewer loops, first-class OpenClaw plugin); 48-agent OpenClaw fleet demos exist.

## 6. Gateway resource footprint

Node.js process; reports converge on **~150–500MB RAM idle** (some configs 400–800MB), bursting under active sessions; plan ~2GB headroom; runs fine on a Raspberry Pi 5 when models are remote/local-server-hosted. CPU is negligible at idle. The model server is the real cost.

## 7. Home Assistant

- **DevelopmentCats/homeassistant-assist** skill: `clawhub install homeassistant-assist`; uses HA's **Assist (Conversation) API** so HA's own NLU does intent/entity resolution (single API call, token-cheap). Needs `HASS_SERVER` + `HASS_TOKEN` (long-lived access token) in `~/.openclaw/openclaw.json` env. Works fully on-LAN.
- **techartdev/OpenClawHomeAssistant**: HA Add-on running OpenClaw in a supervised container with direct HA config access.
- Generic REST-call skills for Hue/Tuya/MQTT exist on ClawHub; HA community threads confirm both approaches working (community.home-assistant.io/t/990911 and /t/981467).

## RECOMMENDATION
For THIS machine (Lunar Lake, 32GB shared, Arc 140V, no Docker, security-first):

1. **It installs and runs natively** — `npm install -g openclaw@2026.6.5` (pin it; don't track latest blindly given the CVE cadence) with your existing Node 24, `openclaw gateway install` for a Windows service. But for your threat model, prefer running the gateway inside a dedicated WSL2 distro or a Hyper-V VM (you already operate Hyper-V for BlarAI) — skills/plugins run in-process and the tool sandbox's default backend is Docker, which you don't have; VM isolation is the substitute.

2. **Local-model path**: Reinstall Ollama (your 16.8GB of blobs in ~/.ollama/models are reusable — qwen2.5-coder:14b-q6_K is the best of them) and use the native `api: "ollama"` provider at `http://127.0.0.1:11434` (never `/v1`), `num_ctx: 32768`, `localModelLean: true`, `tool_choice: "required"`. Alternative that better exploits your hardware: serve Qwen3-14B INT4 on the Arc 140V via OpenVINO Model Server's OpenAI-compatible endpoint and use `api: "openai-completions"` — but expect worse tool-call fidelity than the native Ollama path (docs explicitly warn OpenAI-compat mode is less reliable for tools).

3. **Set expectations**: the community floor for a *reliable* OpenClaw agent loop is 24–32B; your 32GB shared-memory ceiling means 14B INT4 is your practical max alongside the gateway+OS. That's "works, but flaky tool calls" territory — fine for a lean WebChat-only assistant with a restricted tool set (HA control, cron, sub-agent dispatch), not for autonomous multi-step automation. A 27–32B INT4 (~16–19GB weights) would technically fit in RAM CPU-side but would be painfully slow (~2–4 t/s) and starve the iGPU.

4. **Air-gap config**: WebChat/Control UI channel only, `gateway.bind: "loopback"` + token auth, `update.checkOnStart: false`, `OPENCLAW_NO_AUTO_UPDATE=1`, `OPENCLAW_DISABLE_BONJOUR=1`, `CLAWHUB_DISABLE_TELEMETRY=1`, never log into ClawHub, install zero ClawHub skills (write your own — the homeassistant-assist skill is small enough to vendor and audit by hand), deny `group:runtime`/`group:fs`/exec by default, run `openclaw security audit --fix`.

5. **Honest verdict**: OpenClaw is the right shape for what you want (offline gateway + skills + cron + sub-agents + HA), and the gateway itself is trivial for this machine (~0.5GB). The weak links are (a) local-model agentic reliability at 14B and (b) the project's 2026 security track record (138 advisories in 2 months, in-process skills). Treat it as a sandboxed experiment in a VM with a hand-written skill set, not as a trusted component of BlarAI.

## CAVEATS
- Version 2026.6.5 and feature details were verified June 2026, but OpenClaw ships near-daily date-versioned releases; anything here can drift within weeks. The Foundation handover (post-Steinberger-to-OpenAI, Feb 2026) means governance/velocity may have shifted.
- Exposed-instance counts (40k vs 135k) and malicious-skill counts (341 vs 800 vs 1,184) vary by source/scanner and date; I reported the range rather than one number.
- Tool-calling quality numbers for 14B-class models are community anecdote, not benchmarks; your specific Qwen2.5-Coder-14B q6_K may do better or worse. The q6_K quant (~12GB) + 32k KV cache + gateway + OS will be tight in 32GB — q4_K_M or INT4 OpenVINO is safer.
- Ollama-on-Arc-140V acceleration is still awkward (Vulkan backend experimental; ipex-llm builds lag releases) — the reused blobs may run CPU-only at low t/s. The OVMS/OpenAI-compatible route uses your GPU but is the less-reliable tool-calling path; I could not find community reports specifically pairing OpenClaw with OpenVINO Model Server, so that combination is unverified.
- Native-Windows gateway works but docs steer advanced setups to WSL2; some channels/tools may have Windows-specific rough edges not enumerated in docs.
- Without Docker, `agents.defaults.sandbox` has no backend on this machine — per-tool sandboxing is effectively unavailable unless you run the whole gateway in WSL2/Hyper-V.
- Several cited third-party blogs (clawctl, rentamac, blink.new, etc.) are SEO-adjacent; I cross-checked their claims against official docs where possible, but per-model VRAM figures and Pi RAM figures are approximate.

## SOURCES
https://github.com/openclaw/openclaw
https://en.wikipedia.org/wiki/OpenClaw
https://openclaw.ai/
https://docs.openclaw.ai/gateway/local-models
https://docs.openclaw.ai/providers/ollama
https://docs.openclaw.ai/platforms/windows
https://docs.openclaw.ai/gateway/security
https://docs.openclaw.ai/clawhub/telemetry
https://docs.openclaw.ai/install/updating
https://docs.openclaw.ai/cli/mcp
https://docs.openclaw.ai/tools/subagents
https://docs.openclaw.ai/tools/acp-agents
https://registry.npmjs.org/openclaw/latest
https://techcrunch.com/2026/02/15/openclaw-creator-peter-steinberger-joins-openai/
https://www.proarch.com/blog/threats-vulnerabilities/openclaw-rce-vulnerability-cve-2026-25253
https://www.armosec.io/blog/cve-2026-32922-openclaw-privilege-escalation-cloud-security/
https://github.com/jgamblin/OpenClawCVEs/
https://www.adminbyrequest.com/en/blogs/openclaw-went-from-viral-ai-agent-to-security-crisis-in-just-three-weeks
https://blog.cyberdesserts.com/openclaw-malicious-skills-security/
https://www.clawctl.com/blog/openclaw-local-llm-complete-guide
https://www.clawctl.com/blog/best-local-llm-coding-2026
https://rentamac.io/best-local-llms-openclaw/
https://github.com/goldmar/openclaw-code-agent
https://github.com/Enderfga/claw-orchestrator
https://github.com/DevelopmentCats/homeassistant-assist
https://github.com/techartdev/OpenClawHomeAssistant
https://community.home-assistant.io/t/a-new-home-assistant-skill-for-openclaw/990911
https://insiderllm.com/guides/openclaw-raspberry-pi/
https://sfailabs.com/guides/openclaw-hardware-requirements
https://ollama.com/blog/openclaw-tutorial
