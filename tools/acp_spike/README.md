# ACP driver spike harness (Vikunja #759)

A **bounded, side-by-side experiment** — NOT an integration. It drives one real
opencode coder build through opencode's native **Agent Client Protocol** (ACP:
JSON-RPC 2.0 over stdio, persistent session, typed event stream) and A/Bs it
against the production `opencode run` + transcript-regex path
(`scripts/fleet-lib.ps1` `Invoke-AgentRun`).

**Zero production fleet scripts are modified.** This directory + `state/acp-spike/`
(evidence) are the entire footprint. The baseline leg *uses* the real
`Invoke-AgentRun` by dot-sourcing `fleet-lib.ps1` — it never edits it.

## Files

| File | What it is |
|---|---|
| `acp_spike.py` | The ACP client harness. `recon` (handshake only, no GPU) + `run` (full prompt with NDJSON event capture, StopReason, optional cooperative-cancel probe). |
| `run_baseline.ps1` | Baseline leg: calls the REAL `Invoke-AgentRun -JsonStepCap` on the same prompt, then re-derives the production progress signals (`step_finish` / tool-write regex counts) from the transcript for the fidelity A/B. |
| `analyze_events.py` | Post-hoc analysis of an events NDJSON: event histogram, tool-call kinds, status transitions, inter-event gap distribution (the empirical basis for an ACP idle detector). |

## Environment

- Python **3.14** + `agent-client-protocol==0.11.0` in a **throwaway venv** (never
  the blarai runtime `.venv`).
- Windows Proactor asyncio loop (the win32 default on 3.14 — required for subprocess
  pipes; do NOT switch to Selector).
- opencode **1.17.8** (`opencode acp`). The harness spawns the REAL compiled
  `opencode.exe` (not the `.cmd`/`.ps1` npm shim — asyncio's `create_subprocess_exec`
  does not resolve the shim), with the env pinned identically to `Invoke-AgentRun`
  (`OPENCODE_GIT_BASH_PATH`, `SHELL`, `PYTHONPATH`). Config + plugins come from the
  global `~/.config/opencode/` that BOTH modes read.

## Usage

```powershell
# venv python
$py = "<throwaway-venv>\Scripts\python.exe"

# Recon — no GPU; the parity gate. Confirms protocolVersion, plugin load, model select.
& $py acp_spike.py recon --cwd C:/Users/mrbla/projects/<throwaway-repo>

# ACP leg — needs OVMS + coder-30b up (start-llm -Model coder-30b -Force).
& $py acp_spike.py run --cwd <repo> --model local/coder-30b --prompt-file <task.txt> --timeout 1200

# Cooperative-cancel probe: send session/cancel after N seconds.
& $py acp_spike.py run --cwd <repo> --model local/coder-30b --prompt-file <task.txt> --cancel-after 120

# Baseline leg (production path) — same prompt, same model.
pwsh -File run_baseline.ps1 -WorkDir <repo> -PromptFile <task.txt> -Model local/coder-30b -OutDir <state/acp-spike>

# Analyze an events NDJSON.
& $py analyze_events.py <state/acp-spike/run-*.events.ndjson>
```

## Safety / scope

- One model at a time: the 30B cannot co-reside with the 14B (31.323 GB ceiling).
  The AO must be DOWN before `start-llm` loads the 30B. Whatever the spike brings up
  it tears down: OVMS stopped, AO restored on :5001 via
  `blarai tools.dispatch_harness.battery.boot_launcher_detached`.
- Throwaway git repos under `C:/Users/mrbla/projects/acp-spike-*` only.
- **`opencode acp` teardown must tree-kill.** The SDK's connection close only
  terminates the DIRECT child; opencode's node runtime children orphan. A real
  integration must reuse the existing `terminate_process_tree`.
