# opencode-harness

## VERIFIED FACTS
VERIFIED (method in parens):

1. GLOBAL INSTRUCTIONS: Global rules file is C:\Users\mrbla\.config\opencode\AGENTS.md (\~/.config/opencode/AGENTS.md) — verified via opencode.ai/docs/rules. Precedence: project AGENTS.md (walking up from cwd) → global \~/.config/opencode/AGENTS.md → fallback \~/.claude/CLAUDE.md. Neither global file currently exists on this machine (verified by ls: no C:\Users\mrbla\.config\opencode\AGENTS.md, no C:\Users\mrbla\.claude\CLAUDE.md — so no Claude-instruction leakage either). The `instructions` config key exists in the live schema (fetched https://opencode.ai/config.json, parsed with python): array of strings, supports globs and remote URLs; merges with AGENTS.md, does not replace it.

2. CLI: Verified by running `opencode --help` on the installed v1.17.3 (C:\Users\mrbla\AppData\Roaming\npm\opencode.ps1): default command is `opencode [project]` with positional `project: path to start opencode in`, and options `-m, --model` ("model to use in the format of provider/model"), `--agent`, `--prompt`, `-c/--continue`, `-s/--session`, `--pure` (run without external plugins), `--print-logs`, `--log-level`. So `opencode "C:\path\to\project" -m local/coder-30b` is valid.

3. small_model: Exists in live schema: "Small model to use for tasks like title generation in the format of provider/model". Docs (opencode.ai/docs/config): used for lightweight tasks like title generation; default = "tries to use a cheaper model if one is available from your provider, otherwise falls back to your main model". With 3 models declared but only ONE resident in OVMS, an unset small_model can route title-gen to a non-loaded model (404 from OVMS). Config files MERGE in order: remote → global \~/.config/opencode/opencode.json → OPENCODE_CONFIG env path → project opencode.json → .opencode dirs → OPENCODE_CONFIG_CONTENT (docs/config). {env:VAR} and {file:path} substitution supported.

4. PERMISSIONS: Schema-verified ($defs.PermissionConfig): keys read/edit/glob/grep/list/bash/task/external_directory/lsp/skill take either "ask"|"allow"|"deny" or an object of glob-pattern→action; todowrite/question/webfetch/websearch/doom_loop take action strings only. AgentConfig has a `permission` field (per-agent override, e.g. agent.build.permission). Docs (docs/permissions): wildcards * and ?, "last rule wins", \~ expansion. AgentConfig also has temperature, top_p, model, prompt, options, disable (schema-verified). Agent-level `tools` is marked "@deprecated Use 'permission' field instead" in the schema.

5. USABILITY: Keybinds moved OUT of opencode.json into \~/.config/opencode/tui.json ($schema https://opencode.ai/tui.json); legacy theme/keybinds/tui keys in opencode.json are deprecated/auto-migrated (docs/config; `keybinds` confirmed absent from live config.json schema). Default model-switch keys (docs/keybinds): model_list = <leader>m (leader = ctrl+x), model_cycle_recent = f2, model_cycle_recent_reverse = shift+f2; agent cycle = tab; session_compact = <leader>c. Context-burn levers verified in live schema: top-level `tools` (map tool-id→boolean; built-in ids per docs/tools: bash, edit, write, read, grep, glob, lsp, apply_patch, skill, todowrite, webfetch, websearch, question), `compaction` {auto (default true), prune (default false), tail_turns (default 2), preserve_recent_tokens, reserved}, `tool_output` {max_lines default 2000, max_bytes default 51200}, `lsp` (false, or per-server {"disabled": true}), `snapshot` (boolean). Temperature: agents docs state if unset opencode defaults to \~0 for most models, 0.55 for Qwen models; agent-level "temperature"/"top_p" are schema-verified numbers; per-model `options` is a free-form object passed to the provider (schema "type":"object"; docs/models shows options example) — model-level temperature key is a BOOLEAN capability flag, not a value.

6. PLUGINS: opencode-image-comprehension (github.com/aosama/opencode-image-comprehension, MIT, npm) is hardcoded to Ollama at localhost (no baseURL option; visionModel default moondream:1.8b, autoPullModel option). It cannot point at OVMS qwen3-vl-8b. Alternatives exist (DavidEasden/opencode-vision, BernardYan2357/opencode-image-vision) but all are third-party code. `--pure` flag disables external plugins (CLI help).

7. RELEASES (May–June 2026, github.com/anomalyco/opencode/releases): latest is v1.17.3 (Jun 10, 2026) — the installed version, already current. v1.17.1: deprecated `reference` key now loads under `references` (not used in this setup). v1.17.2: subagent permission fixes. No provider npm package rename — @ai-sdk/openai-compatible is still the documented package for OpenAI-compatible/local servers (docs/providers shows llama.cpp/Ollama/LM Studio examples with it, including a Qwen3-Coder a3b example). No keybind/permission breaking changes in this window beyond the tui.json migration already noted.

Local config read (C:\Users\mrbla\.config\opencode\opencode.json): currently has provider local + 3 models, model=local/qwen3-14b, autoupdate=false, share=disabled; NO permission block, NO instructions/AGENTS.md, NO small_model, NO tools/compaction/tool_output tuning.

## IMPROVEMENTS

### [P0/small] Novice safety net: permission block for dangerous bash
No permission config exists today, so the build agent runs every bash command silently. Add glob-based ask rules for destructive commands (both POSIX and PowerShell/cmd forms, since opencode's bash tool on Windows can hit either) while leaving edits and normal commands free. 'Last rule wins', so the broad allow goes first. doom_loop=ask also catches small-model retry loops.
```text
Add to C:\Users\mrbla\.config\opencode\opencode.json (top level):
"permission": {
  "edit": "allow",
  "doom_loop": "ask",
  "bash": {
    "*": "allow",
    "rm *": "ask",
    "rmdir *": "ask",
    "del *": "ask",
    "rd /s*": "ask",
    "Remove-Item *": "ask",
    "git push*": "ask",
    "git reset --hard*": "ask",
    "git clean*": "ask",
    "git checkout -- *": "ask",
    "format *": "deny"
  }
}
```
RISK: Low. Worst case: an extra confirmation prompt. Patterns match the command string only — a creative model could evade with e.g. 'bash -c'; this is a guardrail, not a sandbox.

### [P0/small] Create global AGENTS.md tuned for local small models
C:\Users\mrbla\.config\opencode\AGENTS.md does not exist (verified). It is injected into every session in every project — the right place for short, directive small-model discipline. Keep it under \~15 lines; long rules burn the 32–64k context these models have.
```text
Create C:\Users\mrbla\.config\opencode\AGENTS.md with:

# Rules (local model — stay lean)
- Make the smallest diff that solves the task. No drive-by refactors or reformatting.
- Work on one file at a time. Re-read a file before editing it a second time.
- Never invent paths, APIs, or flags — confirm with read/grep/glob first.
- Prefer edit over rewriting whole files.
- After changes: run the project's tests (or at least the changed file) and report the command + result.
- If the same command fails twice, stop and ask the user — do not keep retrying.
- Keep replies short: what changed, where, how it was verified. No recaps of unchanged code.
- Ask before anything destructive (delete, push, reset).
```
RISK: Negligible. Adds \~200 tokens per session; trims far more by suppressing verbose small-model behavior.

### [P0/small] Launchers preselect the loaded model: -m flag + project positional
Verified from `opencode --help` (v1.17.3): the TUI accepts a project directory positional and -m/--model. open-coding.ps1 can launch directly into the picked project with the currently-loaded OVMS model preselected, removing the manual model-pick step that mismatches the resident model.
```text
In C:\Users\mrbla\agentic-setup\scripts\open-coding.ps1, launch with:
opencode "$projectDir" -m "local/$loadedModel"
where $loadedModel is coder-30b|qwen3-14b|qwen3-vl-8b, ideally detected from OVMS (e.g. probe http://127.0.0.1:8000/v1/config or read a flag file written by the model-starter scripts, which already know which model they started).
```
RISK: Low. If -m names a model not resident in OVMS, requests 404 — same failure mode as today's manual mispick; flag-file detection removes it.

### [P0/medium] Pin small_model per loaded model via OPENCODE_CONFIG overlay
small_model drives title generation. Unset, opencode 'tries to use a cheaper model if one is available from your provider' — with 3 declared models but one resident, title-gen can silently call a non-loaded model and 404 against OVMS. Config files merge in order global → OPENCODE_CONFIG → project (docs/config), so a tiny per-model overlay set by each starter script pins both model and small_model to the resident model. There is no CLI flag for small_model, hence the overlay.
```text
Create three files in C:\Users\mrbla\agentic-setup\overlays\, e.g. coder-30b.json:
{
  "$schema": "https://opencode.ai/config.json",
  "model": "local/coder-30b",
  "small_model": "local/coder-30b"
}
(same pattern for qwen3-14b.json, qwen3-vl-8b.json).
In each model-starter .ps1 add:
[Environment]::SetEnvironmentVariable('OPENCODE_CONFIG', 'C:\Users\mrbla\agentic-setup\overlays\coder-30b.json', 'User')
and have open-coding.ps1 also set $env:OPENCODE_CONFIG for the session it spawns. Simpler fallback if overlays feel heavy: hard-set "small_model": "local/qwen3-14b" in the global config and accept failed titles when another model is loaded.
```
RISK: Medium-low. Relies on documented merge order (changed in v1.15.13); verify once that titles generate. A stale overlay after a crashed starter mispins the model — open-coding.ps1 setting it at launch time avoids that.

### [P1/small] Cut context burn: disable web tools, enable compaction pruning, cap tool output
Machine is offline-first and loopback-bound: websearch/webfetch tools waste prompt tokens on schemas and invite hanging network calls. compaction.prune drops old tool outputs at compaction time (default false); tool_output.max_lines (default 2000) caps single-output floods that previously triggered the compaction loop. All keys schema-verified.
```text
Add to C:\Users\mrbla\.config\opencode\opencode.json (top level):
"tools": {
  "websearch": false,
  "webfetch": false
},
"compaction": {
  "auto": true,
  "prune": true,
  "tail_turns": 2
},
"tool_output": {
  "max_lines": 800,
  "max_bytes": 32768
}
```
RISK: Low. prune=true means very old tool results vanish from context (full text still saved to disk); if the model 'forgets' earlier file contents it must re-read them — usually cheaper than a compaction loop.

### [P1/small] Qwen-correct sampling via agent-level temperature/top_p
Unset, opencode defaults to \~0.55 for Qwen models (docs/agents) vs Qwen's recommended 0.7/0.8 for Qwen3-Coder-Instruct and 0.6/0.95 for Qwen3 thinking. Agent-level temperature/top_p are schema-verified numbers and apply to whatever model is loaded; 0.7/0.8 is the right compromise since coder-30b is the primary coding model. Per-model values can go in provider.local.models.<id>.options (free-form object passed to the provider) but that pass-through is less certain — verify in OVMS request logs before trusting it.
```text
Add to opencode.json:
"agent": {
  "build": { "temperature": 0.7, "top_p": 0.8 },
  "plan":  { "temperature": 0.7, "top_p": 0.8 }
}
Optional per-model attempt (verify in OVMS logs that temperature arrives):
"qwen3-14b": { ... "options": { "temperature": 0.6, "topP": 0.95 } }
```
RISK: Low for agent-level (schema-verified). Model-level options pass-through unverified against source — could be silently ignored; hence the log check.

### [P2/small] Document the model-switch keybinds; do not add keybinds to opencode.json
Defaults already cover quick switching: f2 cycles recent models, shift+f2 reverse, ctrl+x then m opens the model list, tab cycles build/plan agents, ctrl+x then c compacts the session. Important schema change: keybinds/theme/tui keys are deprecated in opencode.json and now live in \~/.config/opencode/tui.json ($schema https://opencode.ai/tui.json) — relevant if customizing later.
```text
Add a 'Keys cheat-sheet' section to C:\Users\mrbla\agentic-setup\BLUEPRINT.md:
f2 = cycle recent models | ctrl+x m = model list | tab = build/plan | ctrl+x c = compact session.
If custom keybinds are ever wanted, create C:\Users\mrbla\.config\opencode\tui.json — NOT keybinds in opencode.json.
```
RISK: None — documentation only.

### [P2/small] Optional RAM lever: disable LSP servers
On a 31.3GB shared-RAM machine idling at \~15GB with an 18GB model target, language servers spawned per project add RAM pressure and inject diagnostics into context. Trade-off: diagnostics catch small-model edit mistakes. Keep on by default; flip off if coder-30b sessions hit memory pressure (start-llm.ps1 already surfaces RAM consumers).
```text
If needed, add to opencode.json: "lsp": false
(or selectively, e.g. "lsp": { "typescript": { "disabled": true } })
```
RISK: Medium usefulness loss: without LSP the model loses post-edit diagnostics, so broken edits surface later (at test time). Reversible one-liner.

### [P2/small] Skip vision plugins; keep the native vl-model swap workflow
opencode-image-comprehension (MIT, localhost-only) is hardcoded to Ollama — no baseURL option — so it cannot use OVMS qwen3-vl-8b, and running Ollama alongside OVMS doubles model RAM on a machine that can hold one model. The native path already works: qwen3-vl-8b is declared with attachment:true; the Qwen3-VL starter + f2/ctrl+x-m switch covers screenshot analysis with zero third-party code. If a plugin is ever adopted, vendor-pin it and test with --pure as the rollback (runs without external plugins, verified in CLI help).
```text
No config change. Note in BLUEPRINT.md: 'Vision workflow = Start Qwen3-VL launcher, then f2 in opencode to select local/qwen3-vl-8b, drag image in. No vision plugins installed by policy (Ollama-hardcoded, third-party code, RAM doubling).'
```
RISK: None (inaction). Cost: model swap takes a minute vs a plugin's inline description.

### [P2/small] Release-note hygiene: already current, one rename to know
Installed v1.17.3 IS the latest release (Jun 10, 2026) — no upgrade needed, autoupdate:false stays correct. @ai-sdk/openai-compatible remains the documented npm package for local OpenAI-compatible servers (docs/providers still uses it for llama.cpp/Ollama/LM Studio, including a Qwen3-Coder example), so no provider config change. Only rename in the window: 'reference' → 'references' (v1.17.1), unused here. v1.17.2 fixed subagent permission handling, which makes the P0 permission block more reliable.
```text
No change. When manually upgrading later: opencode upgrade, then re-check https://opencode.ai/config.json against the config (the schema URL in $schema gives editor validation automatically).
```
RISK: None.

