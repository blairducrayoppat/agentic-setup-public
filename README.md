# agentic-setup — a fully-local coding-agent stack for one Lunar Lake laptop

This repository is the **operations layer** for a self-contained, offline-capable AI
coding system that runs entirely on a single Intel Lunar Lake laptop — no cloud model,
no API keys, no data leaving the machine. It serves a 30-billion-parameter coder model
from the integrated GPU, drives it with a terminal coding agent, dispatches autonomous
overnight coding runs through a supervised fleet, and exposes every one of those
capabilities behind a single text menu a non-developer can operate.

**&#9654; The BlarAI vision film (66 seconds):**

https://github.com/user-attachments/assets/9ffd473b-93e5-4763-a9ec-e12ac6afa10c

It is deliberately **PowerShell-first, Windows-native, single-operator**. There is no
container runtime, no orchestration cluster, no second machine. Everything below is
tuned to the one hard constraint that governs the whole design.

> **PowerShell 7+ (pwsh) only.** All scripts, the scheduled tasks, and the fleet run
> under PowerShell 7 — the production runtime. Windows PowerShell 5.1 is **not
> supported**: the scripts are UTF-8 without a byte-order mark, which 5.1's ANSI-default
> parser mis-tokenizes.

## Recent enhancements (as of July 2026)

Recent work has focused on making the autonomous overnight coding fleet *fail honestly*,
so an operator waking up to a run report can trust what it says.

- **The fleet fails loud, never silent.** A failed `git` capture — a worktree that would
  not create, an add or commit that errored — is now surfaced as an *errored* task
  carrying git's own message, never silently misreported as "the coder produced no
  output." A capture fault is also no longer terminal for best-of-N sampling, so one bad
  attempt does not sink an otherwise-good run.
- **"No change needed" is a first-class outcome.** The best-of-N retry loop no longer
  demands a diff when the correct answer is to change nothing — it recognizes a genuine
  no-op as success instead of retrying against an impossible expectation.
- **Neutral, lock-verified scaffolding.** New-project scaffolding was made
  language-neutral with a litter filter, backed by a verify suite of more than a hundred
  locked assertions so a regression in the out-of-box template fails loudly rather than
  drifting in unnoticed.
- **Memory-strand containment.** A crash in a run's postlude can no longer strand the
  resident model in memory — the single ~31 GB pool is protected against the failure mode
  that previously left a multi-gigabyte model orphaned after a bad run.

## The one constraint everything follows from

**CPU, integrated GPU, OS, VMs, and build jobs all share ONE \~31.3 GB memory pool** on
this hardware (Core Ultra 7 258V / Arc 140V iGPU / 32 GB soldered LPDDR5X). It is not
upgradable. So exactly **one model is resident at a time**, and every decision — model
choice, concurrency, swap timing, which model is resident when — is a
memory-budget decision first and a quality decision second.

## Architecture — three layers

```
┌─────────────────────────────────────────────────────────────────┐
│  ORCHESTRATION   The fleet (run-fleet.ps1): a serial task queue,  │
│                  one git worktree per task, secret-scan / verify /│
│                  review gates, best-of-N candidate selection,     │
│                  crash-resume, per-command timeouts, watchdog.    │
├─────────────────────────────────────────────────────────────────┤
│  CODING AGENT    OpenCode (terminal TUI + `opencode serve` API)   │
│                  pointed at local models via a repair proxy;      │
│                  custom subagents, plugins, a permission allowlist.│
├─────────────────────────────────────────────────────────────────┤
│  MODEL SERVER    OpenVINO Model Server (ovms.exe, native, on GPU) │
│                  OpenAI-compatible /v3 endpoint, ONE model loaded: │
│                    coder-30b  = deep coding + fleet (~18 GB)       │
│                    qwen3-14b  = everyday/orchestrator (~10.5 GB)   │
│                    qwen3-vl-8b = screenshots   (~6 GB)             │
└─────────────────────────────────────────────────────────────────┘
```

## The model server (OpenVINO Model Server)

OVMS was chosen over Ollama / llama.cpp / LM Studio for this specific machine: it has a
dedicated `qwen3coder` tool-call parser plus XGrammar tool-guided generation (the exact
plumbing agentic tool-calling needs), it uses the oneDNN/OpenCL path with XMX rather than
the Intel Vulkan driver (which has a live TDR/reset bug on the Arc 140V), and it is a
native Windows executable with an OpenAI-compatible API.

- Serves the OpenAI API at `http://127.0.0.1:8000/v3`, **loopback-only** by default
  (`--rest_bind_address 127.0.0.1` — OVMS otherwise binds all interfaces).
- `scripts/start-llm.ps1` is the swapper and a **guided memory assistant**: it measures
  free RAM, and if a model won't fit it lists what is consuming memory (BlarAI VM,
  browser, heavy apps), how much each would free, and offers to close them one at a time
  (graceful, always asks). It remembers what it stopped and offers to restart it on swap
  back. `scripts/stop-llm.ps1` frees the pool.
- Prefix caching is on: a \~2,900-token re-read drops from \~14 s to \~1 s, so multi-turn
  conversations do not re-prefill from scratch.

**The qwen-proxy** (`tools/qwen-proxy.py`, pure stdlib, auto-started by `start-llm.ps1`)
sits at `127.0.0.1:8099/v3` between OpenCode and OVMS and makes multi-turn tool calling
reliable for the 30B coder. On the request side it rewrites prior assistant tool-call
turns into native Qwen XML; on the response side it reconstructs tool calls OVMS strands
in `content` and strips cosmetic trailing markers. It is transparent passthrough for the
14B and VLM, and it never touches, kills, or restarts OVMS.

## Model stack and swap choreography

| Role | Model | Resident | Decode (Arc 140V) |
|---|---|---|---|
| Deep agentic coding + fleet dispatch | Qwen3-Coder-30B-A3B-Instruct INT4 (MoE, \~3.3B active) | \~18 GB | \~35–45 t/s |
| Everyday / orchestrator / critic | Qwen3-14B INT4 (dense) | \~10.5 GB | \~12 t/s |
| Vision (screenshot/UI debugging) | Qwen3-VL-8B-Instruct INT4 | \~6 GB | swap-in only |

Counter-intuitively the MoE 30B **outruns** the dense 14B once memory isn't the
bottleneck — it reads fewer active parameters per token. Model swap latency is real
(\~20–60 s of compile/load), so workflows batch around it rather than ping-pong. **The
fleet codes on the 30B**: BlarAI's dispatch driver loads `coder-30b` via
`start-llm.ps1 -Model coder-30b -Force` and waits for it to serve before any task
runs, so every dispatched run and overnight batch codes on the 30B. The 14B remains
the everyday/orchestrator model.

**The 10× fix (measured, `bench/`).** Out of the box the 30B decodes at \~3.5 t/s: its
\~18 GB working set exceeds the Arc's default \~17.9 GB shared-GPU window and spills onto
the slow path. Setting Intel Graphics Software → **Shared GPU Memory Override → \~87%**
and rebooting raises the window to \~27 GB so the whole model fits, and decode jumps to
\~35–45 t/s — beating Intel's own published 34 t/s figure on the larger 285H. On this
machine the override is required, not optional. No published tokens/sec numbers for this
model on this hardware existed before this measurement.

## OpenCode integration

- A single **local provider** (`configs/opencode.json`) via `@ai-sdk/openai-compatible`
  pointed at the proxy (`127.0.0.1:8099/v3`), defining all three models with correct
  per-model flags (tool-calling on for the coders, image modality + attachments for the
  VLM, per-model context/output limits). `autoupdate: false`, `share: disabled`, web
  search/fetch tools off (offline-first).
- **Custom subagents** (`configs/agents/`): a read-only pre-merge `critic` (temperature
  0.1, edit/bash denied — reports only concrete, test-checkable blockers and defaults to
  MERGE, tuned specifically against small-model over-flagging), plus `debug` and `review`.
- **Plugins** (`configs/opencode-plugins/`): `command-timeout.js` hard-caps every bash
  command so one hung process can't eat the build budget; `path-normalize.js` fixes
  Windows/git-bash path mangling; `qwen-sampling.js` (staged) adds the model card's
  recommended sampling parameters.
- **A deep permission allowlist** in `opencode.json`: destructive bash (`rm`, `git push`,
  `reset --hard`, process kills) prompts; a large set of secret-shaped paths (`.ssh`,
  `.env*`, `*.pem`, `*.key`, cloud-credential dirs, `.git-credentials`) is denied to
  read/grep/glob/edit outright; network-egress commands (`curl`, `Invoke-WebRequest`,
  `nc`, `scp`, download cmdlets) prompt. The global agent rulebook (`configs/AGENTS.md`)
  encodes prompt-injection resistance, real-execution-over-mocks testing, offline build
  discipline, and "never weaken a test to make it pass."

## The autonomous fleet

Queued, supervised, overnight coding — calibrated honestly to \~5–15 completed tasks a
night on this hardware (agent turns are prefill-dominated).

- **Queue a task** with `add-fleet-task.ps1` (or the Control Panel's guided prompt),
  appending to `state/fleet-queue.json`.
- **`run-fleet.ps1`** processes the queue **serially** (matching the one-active-agent
  design). It waits for OVMS to be READY before each task (never starting/stopping models
  itself), stops cleanly at a wall-clock budget, **resumes an interrupted run** with
  `-RunId`, journals every step, and writes a morning `SUMMARY.txt`.
- **One task → one branch → one git worktree → one agent** (`new-agent-task.ps1`).
  Worktrees prevent file collisions; disjoint task boundaries prevent semantic ones. An
  agent never runs in the main checkout.
- **best-of-N candidate generation**: N candidates code against a byte-identical
  spec-derived acceptance oracle, each on a fresh reset (sequential, or concurrent when
  RAM headroom allows — concurrency is capped by a live free-RAM guard). The gate selects
  the winner; if none passes it keeps the best by gate rank.
- **The merge gate is fail-closed** and stacked: a gitleaks secret-scan on staged changes
  (a detected secret never enters history), a `verify-project.ps1` build/typecheck/lint
  pass (Node/Python/.NET, offline and forgiving), property/mutation checks, loop and
  timeout detection, and finally the read-only `critic` verdict. Auto-merge requires all
  of them green; otherwise the task is parked for morning human review.
- **Robustness machinery**: a per-model-call circuit breaker with a hard wall-clock cap
  and an idle-progress killer, per-command timeouts (the plugin above), and a `watchdog`
  that keeps the server healthy without ever fighting a deliberate "Stop AI Models."

## The AI Control Panel — one menu for everything

`scripts/control-panel.ps1` is the single operator entry point (double-click
`AI Control Panel.cmd`). It shows live status — loaded model, free RAM, BlarAI VM state,
last-backup age with a colored freshness indicator — and every capability is a keystroke:
load the 30B / 14B / 8B, stop models, open a coding chat that auto-picks the loaded model,
full status report, live GPU monitor, undo AI changes in a project, quick config backup,
**full-system backup**, update check (report-only, installs nothing), fleet activity
report, quality evals, secret-scanner install, and queue/run overnight tasks. The
launcher `.cmd` files on the Desktop are thin stubs calling these scripts — one source of
truth.

## Benchmarking and evals

- **`bench/`** — a stdlib-only harness (`bench.py`) that measures TTFT, decode t/s, and
  prefill against the live `/v3` endpoint, reasoning-aware so "thinking" models are timed
  correctly (an early version mis-timed the 14B by ignoring reasoning tokens; the
  self-test caught it before publishing). Also holds raw system-telemetry captures
  (SoCWatch / emon / Level-Zero GPU/NPU) for power and utilization profiling. These
  measurements are contributed upstream as local-hardware performance data.
- **`evals/tasks/`** — a small golden-task regression suite covering not just capability
  (`hello-function`, `fix-bug`, `tool-execution`, `constraint-honor`) but **security
  behavior**: destructive-command refusal, prompt-injection refusal, injection-driven
  network/exfil-escape attempts, and supply-chain refusal. Run via `run-evals.ps1`
  (`-Mock` self-tests offline).

## Operations and durability

`backup-system.ps1` (scheduled daily via Task Scheduler, or on demand) does three things
each run: refreshes a rolling branch capturing uncommitted work and pushes all
branches/tags to a private origin (working tree untouched, via a temp index); mirrors
model weights, runtime databases, config, and history to a local cloud-sync folder; and
stages a local copy of secrets that is **never** sent to the cloud. Model-server starts
write dated logs under `state/logs` (newest kept); failures auto-print their last lines.

## Design philosophy

- **Local and private by default.** No cloud model, no telemetry, offline-capable end to
  end. The stack is designed to run in airplane mode after a one-time online seeding.
- **Novice-operable.** The owner is not a developer. Every capability is reachable from
  one text menu, git is handled silently on the operator's behalf, and destructive actions
  always ask.
- **Honest about the hardware.** Rejected models are documented with the reason (memory,
  bandwidth, or an open runtime issue) so decisions aren't relitigated; the fleet's
  throughput is stated as a real number, not a cloud-blog aspiration.
- **Fail-closed security.** Secret-shaped paths are denied to the agent, egress commands
  prompt, secrets never enter git history, and the eval suite actively tests refusal.

## Repository layout

| Path | Contents |
|---|---|
| `BLUEPRINT.md` | The full design document — memory tiers, model decisions and rejected alternatives, serving-layer rationale, use-case playbooks, offline-seeding plan, failure signatures. |
| `scripts/` | All PowerShell operations: `control-panel.ps1`, `start-llm.ps1`/`stop-llm.ps1`, `run-fleet.ps1`, `new-agent-task.ps1`, `fleet-lib.ps1`, `watchdog.ps1`, `backup-system.ps1`, the `verify-*` gate scripts. |
| `configs/` | `opencode.json`, `AGENTS.md`, custom `agents/`, `opencode-plugins/`, gitleaks config. |
| `tools/` | `qwen-proxy.py` and the Qwen tool-call repair library; benchmarking utilities. |
| `bench/` | Benchmark harness, results, and telemetry captures. |
| `evals/tasks/` | Capability + security golden-task suite. |
| `docs/` | `LESSONS-LEARNED.md`, builder briefs, and research docs. |

## License

Licensed under the **PolyForm Noncommercial License 1.0.0** — free for noncommercial use
by anyone (personal, hobby, education, research, evaluation). See [LICENSE.md](LICENSE.md).

**Any commercial use requires a paid commercial license** — see
[COMMERCIAL-LICENSE.md](COMMERCIAL-LICENSE.md). To obtain one, contact Blair DuCray-Oppat
(mr.blair.do@gmail.com).

Copyright (c) 2026 Blair DuCray-Oppat. All rights not expressly granted under the PolyForm
Noncommercial License 1.0.0 are reserved.
