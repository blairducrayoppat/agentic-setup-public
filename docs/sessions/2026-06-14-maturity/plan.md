# Autonomous Maturity Session — Plan

**Branch:** `maturity/autonomous-2026-06-14`
**Worktree:** `C:\Users\mrbla\agentic-setup-maturity` (your live `C:\Users\mrbla\agentic-setup` stays on `main`)
**Operator:** Claude (Opus 4.8), unattended, \~16h window, no human in the loop.

## Goal (your words)
1. **Longer-running agentic sessions** — run unattended coding work reliably for longer.
2. **Guardrails for smaller models** — because small local models make more mistakes, protect the system from them.

## Safety posture (because no one is watching)
- All work is on the branch above, in an **isolated worktree**. Your `main` and the live scripts the launchers run are untouched.
- **Nothing auto-applies.** I edit repo copies only; I do **not** run `sync-harness`, start/stop models, or stop the BlarAI VM. The live OpenCode config (`~/.config/opencode`) is never modified.
- No destructive/irreversible actions; no `0.0.0.0` binds; no AV exclusions; nothing touches `BlarAI`/`.openclaw`/`.ssh`/credentials.
- Every change is a small, labeled commit. Worst case rollback = delete the branch (zero trace on `main`).
- Anything needing the live models to validate is **built + staged**, with a morning smoke-test checklist — I do not fire model swaps blind.

## What already exists (will NOT rebuild)
Prefix caching (on, 4GB pool), guided memory-swap assistant, sentinel-gated watchdog, `ai-status`/`monitor-gpu`, hardened `opencode.json` (deny-reads on secrets, doom_loop ask, compaction prune, tool_output caps), `AGENTS.md` + `debug`/`review` subagents, the `new-agent-task.ps1` serial pipeline (worktree-per-task + auto-merge-on-green + morning report), home-dir-repo git-init guard, backup/restore/undo, offline-toolchain strategy. (Source: maturity-map research, 2026-06-14.)

## The gaps this session closes (verified against current code)
| # | Workstream | Pillar | Why it matters |
|---|-----------|--------|----------------|
| 2 | **Deterministic verify gate** (build/typecheck/lint) in the fleet | Guardrails | `new-agent-task.ps1:62-76` only runs forgiving tests; `:90` auto-merges on tests+review alone, so a no-test project can ship non-compiling code. |
| 3 | **gitleaks secret-scan gate** before any agent commit | Guardrails | Home dir is a git repo with plaintext `.ssh`/`.git-credentials`; `:57-59` commits with no scan. Read-deny ACLs do not stop committing an already-present secret. "Biggest miss" per the project's own audit. |
| 4 | **Circuit breakers** (wall-clock timeout + post-hoc loop/anomaly detection) | Guardrails + Sessions | `:54` runs the agent with no cap; a confused small model can churn for hours. |
| 5 | **Resilient session supervisor** (`run-fleet.ps1`) | Sessions | The serial pipeline has never run unattended; no queue, no resume-after-crash, no server-health waits, no journal. This is the core of "longer-running sessions." |
| 6 | **Inference reliability**: guided-gen on `qwen3-14b` + Qwen sampling (`top_k=20`, `repetition_penalty=1.05`) | Guardrails | `start-llm.ps1:74` (the fleet's default model) lacks the `--enable_tool_guided_generation` flag that `:67` (coder) has; sampling omits two model-card params tied to small-model looping. |
| 7 | **Evidence layer**: golden-task regression eval + run-metrics report | Trust | No way to confirm a change helped vs. silently regressed; the only check is a plumbing smoke test. |
| 8 | **Integration**: control-panel + Start Menu + BLUEPRINT/AGENTS docs | UX | Make the new tools discoverable and novice-usable; record decisions. |
| 9 | **Final adversarial review + `review.md`** | Safety | Full self-review for correctness + constraint compliance; plain-language morning report + apply/rollback instructions. |

## Architecture decisions
- **Single-task logic stays in `new-agent-task.ps1`**: it gains the verify gate (2), the secret-scan gate (3), and a wall-clock breaker + post-run anomaly report (4).
- **A new `run-fleet.ps1` supervisor** (5) owns the queue, resume, server-health waits, and journaling; it calls `new-agent-task.ps1` per task. Clean separation of "run one task safely" vs. "run a night of tasks resiliently."
- **gitleaks** is wired both into the fleet commit step and via `git init.templateDir` so every new agent worktree inherits the hook; plus a retrofit helper for existing repos. Allowlist tuned for the known home-dir plaintext paths.
- **Sampling params** ship as a staged OpenCode **plugin** + install notes (the live config is deny-edit and must not be auto-changed); the guided-gen flag is a one-line `start-llm.ps1` edit flagged for a morning smoke test (reasoning-model interaction risk).
- **All `.ps1` are ASCII-only and normalized to UTF-8-BOM + CRLF** (PowerShell 5.1 compatibility), syntax-checked via the PowerShell AST parser before commit.

## Conventions
- Commit per workstream, message prefix `feat(maturity):` / `fix(maturity):` / `docs(maturity):`.
- New code lives under `scripts/` (PowerShell), `configs/` (configs/plugins), `evals/` (golden tasks), with docs in `BLUEPRINT.md` + this folder.
- Honest reporting: anything unverified-because-no-live-model is labeled as such in `review.md`.

## How to use the result in the morning
See `review.md` (written last). In short: review on the branch, then **keep** with one merge command or **discard** by deleting the branch. Items needing a running model have a short smoke-test checklist.
