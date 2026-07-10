# ACP driver spike (#759) — measured results

*Run 2026-07-09 on the BlarAI dev box (Arc 140V). Working evidence doc; the condensed
version is appended to `docs/fleet-builder-brief-acp-driver-spike.md` §Results.*

## Substrate / versions (community-grade reproducibility)

| Component | Value |
|---|---|
| CPU / GPU | Intel Core Ultra 7 258V (Lunar Lake) / Intel Arc 140V (Xe2), 16 GB shared |
| GPU driver | **32.0.101.8826** (2026-05-28) |
| Inference server | OVMS serving `coder-30b` on `127.0.0.1:8000/v3`; opencode → repair proxy `:8099/v3` |
| Model | Qwen3-Coder-30B-A3B INT4, `--tool_parser qwen3coder --enable_tool_guided_generation true --kv_cache_precision u8 --enable_prefix_caching true`, `MOE_USE_MICRO_GEMM_PREFILL=0` |
| opencode | **1.17.8** (`opencode acp`) |
| ACP SDK | `agent-client-protocol` **0.11.0**, Python **3.14.4**, Windows Proactor loop |
| ACP protocol | negotiated **v1** (schema constant `PROTOCOL_VERSION=1`) |
| Task | identical prompt (`state/acp-spike/task-prompt.txt`, 1088 chars): implement `rpn.py` RPN evaluator + `test_rpn.py` pytest + run pytest |
| Config/plugins | global `~/.config/opencode/opencode.json` (SHA256-identical to repo `configs/opencode.json`); plugins `command-timeout.js` + `path-normalize.js` |

## Recon (no GPU) — the parity gate

`opencode acp` handshake succeeded first try:
- `initialize` → `protocolVersion: 1`, agentInfo OpenCode 1.17.8, agentCapabilities:
  loadSession, MCP http/sse (per-session MCP hand-off available), session list/fork/resume/close.
- **Plugin parity CONFIRMED**: opencode's own stderr shows `[command-timeout] loaded` +
  `[path-normalize] loaded`, **0 loader errors** — captured in ACP mode. Both `opencode run`
  and `opencode acp` read the same global config, so the coder behaves identically → the A/B is valid.
- **Model selection**: `session/new` returns a `model` config-option (select; options include
  `local/coder-30b`) + a `mode` option (build/critic/debug/plan/review; default `build` =
  production). Selected coder-30b via `set_config_option` (ACP-native; there is no `-m` CLI flag
  in acp mode). `currentValue` confirmed flipping to `local/coder-30b`.
- **Windows stdio framing**: newline-delimited JSON-RPC over stdio, no CRLF corruption, no
  deadlock (harness redirects opencode stderr to a file to avoid the SDK's undrained-PIPE trap).

Evidence: `recon-20260709T213614Z.json` (+ `.opencode-stderr.log`).

## A/B measurement 1 — event fidelity (the decisive, transport-attributable result)

| | ACP leg (`run-20260709T214405Z`) | Baseline leg (`baseline-20260709T153010Z`) |
|---|---|---|
| Progress signal | **212 typed events** | **7 integers** (regex hit-counts) |
| Breakdown | 34 `tool_call` + 143 `tool_call_update` + 34 `agent_message_chunk` + 1 `available_commands_update` | 5 `"type":"step_finish"` + 2 `"tool":"(write\|edit…)"` |
| Per-tool typing | `kind` ∈ {edit(30), execute(141), read(3), other(3)} + human title/command | none — just a count of write-ish tool markers |
| Status lifecycle | pending(34) → in_progress(109) → completed(30) / **failed(4)** | none |
| Failure visibility | **4 failed tool calls surfaced explicitly** (failed edits) | invisible (a failed edit is just absent) |
| Per-call identity | 34 distinct tool-call IDs | none |
| Token usage | `usage_update` events (cost/size) | none |

**Interpretation.** The ACP stream is categorically richer, and this is 100% transport-attributable:
the production path can only *count regex hits* over a JSON blob (no type, no status, no failure,
no identity), whereas ACP delivers a typed, per-call lifecycle with explicit failure. The raw
count difference is inflated by run length (below), but the *kind* of signal is the point and it is
decisive.

## A/B measurement 4 — overhead / wall-clock (CONFOUNDED — reported honestly)

| | ACP leg | Baseline leg |
|---|---|---|
| Wall clock | 1203 s (hit the harness 1200 s ceiling) | **117 s (completed, exit 0)** |
| Outcome | timed out mid-work, `stop_reason=null` | clean natural finish |
| Tool calls | 34 (spiralled into an F2 "leftover operands" debug loop — ~15 diagnostic `python -c` probes, never converged) | ~4 (2 writes + pytest), converged |

**This is NOT a transport-overhead measurement.** opencode's `build` agent runs at
**temperature 0.7** (`opencode.json` `agent.build`), so the two runs are stochastically different:
the ACP run happened to fall into the F2 coder-capability loop; the baseline happened to converge.
The wall-clock delta is coder non-determinism, not ACP overhead. Transport overhead on a
single-turn task is negligible (both spawn one opencode process). The real overhead question —
does a persistent ACP session amortize the per-turn re-spawn cost across the fleet's multi-turn
review-fix laps — is a multi-turn measurement this single-turn spike did not isolate; flagged for
integration.

**Side finding (F2, not transport):** ACP mode has **no built-in step/spin cap**. Production's
`Invoke-AgentRun -JsonStepCap` bounds runaway loops at `MaxSteps=45` + a spin detector; the ACP
harness needed its own 1200 s ceiling to stop the runaway. An integration must rebuild that bound
on the event stream (which the typed events make *easier*, not harder).

## A/B measurement 2 — stall detection

- **ACP:** idle = "no `session/update` for N s". Empirically, the healthy 30B run's **max
  inter-event gap was 83 s** (the cold-prefill wait before the first token); p90 29.5 s, p99 54 s,
  only 1 gap > 60 s, 0 gaps > 90 s. So a safe ACP idle threshold is ~120 s — and it fires on a
  **direct semantic liveness signal**, distinguishing "model thinking" (message/thought chunks
  still arrive) from "wedged" (nothing at all).
- **Baseline:** production infers liveness *indirectly* — transcript mtime + `step_finish`/edit
  deltas with `IdleTimeoutSec=240 s` (`Invoke-AgentRun`), plus the monitor's file-mtime (7 artifact
  families) + psutil CPU probe with `stall_grace_s=90 s`. The CPU probe famously false-doomed a
  GPU-bound-but-healthy review phase (#687) precisely because CPU idle ≠ wedged — the failure mode
  ACP's semantic signal does not have.
- **Verdict:** ACP detects a true hang meaningfully faster (~120 s vs 240 s transcript-idle) and,
  more importantly, on a signal that cannot confuse "thinking" with "dead." (Measured from the
  natural cold-prefill gap rather than an artificial OVMS suspend — deliberately, to avoid
  substrate risk during the window.)

## A/B measurement 3 — Windows robustness + cooperative cancel

- **Framing:** clean. Newline-delimited JSON-RPC over Windows stdio across 3 full sessions +
  recon; no CRLF corruption, no framing deadlock.
- **Cooperative cancel:** `session/cancel` **works and is prompt**, confirmed on TWO probes:
  - Probe 1 (cancel at 90 s, 1 tool call done): turn ended 92.1 s → **2.1 s latency**.
  - Probe 2 (cancel at 150 s, deep in a 6-tool-call run): turn ended 152.1 s → **2.1 s latency**.
  Both cleanly (prompt future returned, process exited, **no orphans** — orphans occur only on the
  hard-timeout path, below). **BUT both returned StopReason `end_turn`, NOT the spec's `cancelled`**
  (opencode 1.17.8). So cooperative cancellation is real and fast, but a fleet integration **cannot
  rely on the StopReason to distinguish an operator cancel from a natural finish** — it must track
  "did I send cancel?" itself. A genuine StopReason-fidelity gap in opencode's ACP implementation.
- **Orphaned processes — REAL FINDING:** when the ACP run hit the ceiling and the harness closed
  the connection, **9 `node.exe` children (opencode's runtime tree) orphaned** and had to be
  manually reaped. The SDK's connection-close terminates only the *direct* child, not the tree. An
  integration MUST tree-kill (production already has `terminate_process_tree`) — not a blocker, but
  "none tolerated" is not met by the SDK teardown alone.

## Go / No-Go

**Verdict: GO** for a bounded, decision-gated integration follow-up (a new ticket for LA review —
NOT integrated in this spike). The core thesis is proven on Windows against our real config:

**What the spike PROVED (transport-attributable):**
1. **Parity holds.** `opencode acp` loads the same global config + both plugins (0 loader errors);
   model select works via `set_config_option`. The coder behaves identically to production.
2. **Event fidelity is decisively richer** — typed per-call lifecycle (kind + pending→in_progress→
   completed/**failed**) + agent messages + usage, vs the production path's blind regex hit-counts.
   This directly replaces the transcript-regex progress inference and the mtime/CPU doom heuristic
   with protocol primitives.
3. **Cooperative cancel works** (~2.1 s, clean) — a first-resort stop before tree-kill.
4. **Semantic stall signal** — idle on "no event for N s" (safe threshold ~120 s from the measured
   83 s max healthy gap), on a direct liveness signal that can't confuse "thinking" with "wedged"
   (the #687 false-doom class disappears).
5. **Windows stdio framing is clean** across 4 sessions — no CRLF/deadlock issues.

**Integration REQUIREMENTS surfaced (must be built — none is a blocker):**
- **Tree-kill teardown.** The SDK close orphans opencode's node children (9 reaped after the
  timeout run). Reuse the existing `terminate_process_tree`.
- **Rebuild the step/spin cap on the event stream.** ACP mode has no `MaxSteps`/spin bound; the
  runaway (F2 loop) hit only the harness ceiling. The typed events make this bound *easier*.
- **Track own cancels.** StopReason is `end_turn` on cancel, not `cancelled` — don't rely on it.
- **Measure multi-turn overhead.** This single-turn spike did not isolate the persistent-session-vs-
  per-turn-respawn amortization (the fleet's real win, on review-fix laps). Measure in integration.
- **Pin the pre-1.0 SDK** (0.11.0) and watch v2 schema churn (v1 negotiation contains it).

**Cost estimate: MEDIUM.** The ACP client is ~250 lines (this harness is a working proof). The
integration is: a production ACP client beside `tools/dispatch_harness/monitor.py` (Python side,
where monitoring lives) + event→`journal.log`/scorecard mapping + tree-kill wiring + step-cap on
events + StopReason handling + re-expressing the best-of-N / review-fix loop as ACP prompts on a
persistent session + parity/regression tests. A focused multi-day single-builder effort, behind a
flag, A/B'd against the current path before any cutover — a **parallel driver you can switch per
run**, never a rip-and-replace. **This is an LA capability decision** (it changes how the fleet
drives the coder), so it is recommended, not taken.

**Not in scope / unchanged:** the `:8099` proxy + OVMS (ACP sits between harness and opencode,
never opencode↔model); A2A (watchlist-only); the coder-capability bottleneck (F2 — a model problem
no transport fixes; the spike's own runaway is evidence of it).

