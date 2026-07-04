# Telemetry & Profiling Plan — agentic-setup + BlarAI

**Source of the approach:** Build 2026 session DEMSP384, "Profile and optimize agentic AI on
Windows" (Intel — Freddy Chiu + Vasanth Tovinkere). Tool: **Intel Unified Telemetry** (preview)
+ **ITT** instrumentation, with **OpenVINO already fully ITT-instrumented**. See memory
`intel-unified-telemetry` and BLUEPRINT §3/§10/§12.

**Why this plan exists:** "You cannot optimize what you cannot see." Our whole stack lives on a
31.3 GB shared pool with one model resident at a time; the biggest open questions (NPU offload,
the BlarAI VM-vs-host RAM blocker, the GPU-override 10×) are all *measurement* questions. This
plan turns them into numbers.

## Principles (non-negotiable)
- **Offline / loopback only.** No cloud observability SaaS (Langfuse cloud, Arize, Datadog) — they
  exfiltrate. Local tools only.
- **Measure-don't-guess + mutation-resistant.** Every run has a "what good looks like" *and* a
  proof step that the capture actually detects the bad state (not just shows green).
- **Scope to the agent layer.** Per-exe outbound firewall rules if needed; never system-wide OS/AV
  changes. Never kill/rebind OVMS `:8000`; swaps go through `start-llm.ps1 -Force`. Any helper
  server uses port 8081+.
- **Record everything** under `bench/` with date, driver version, override on/off, model, tier — so
  it's reproducible and comparable across driver updates (inference here is driver-bound).

## Prerequisites & [VERIFY] before trusting Tier 2
1. **[VERIFY] Lunar Lake support.** The demo ran on **Core Ultra Series 3 (Panther Lake, NPU 5)**.
   This machine is **258V = Core Ultra Series 2 (Lunar Lake, NPU 4)**. Confirm Intel Unified
   Telemetry supports Lunar Lake's NPU/drivers before assuming the NPU timeline works here.
2. **Seed online, verify offline.** Install the Unified Telemetry preview + ITT while online, then
   confirm the capture runs in airplane mode and **does not phone home** (watch with a per-exe
   outbound rule / Resource Monitor). Required before any BlarAI use.
3. **ITT is safe to leave in permanently** — static lib, zero overhead until a tool attaches.

## Telemetry tiers (use the lowest tier that answers the question)
- **Tier 0 — today, zero new tools:** Task Manager → Performance (NPU, GPU "Shared GPU memory",
  Memory "In use"/"Available"); the existing `bench/` t/s harness; OpenVINO `benchmark_app`
  (`-d GPU|NPU|CPU`, `-hint latency`, `-pc` for per-op) and `ov::enable_profiling`.
- **Tier 1 — Windows-native ETW:** Windows Performance Recorder **Neural Processing** profile
  (run `wpr -profiles` to confirm the exact profile name [VERIFY]) → analyze in WPA. Adds NPU/GPU
  ETW timeline without Intel-specific tooling.
- **Tier 2 — the talk's tool:** Intel Unified Telemetry (JSON, time-correlated CPU/GPU/NPU/power/
  bandwidth) + ITT markers at agent-phase boundaries. Gives the single correlated timeline and the
  agent-queryable JSON. Exact invocation = [VERIFY] against the preview docs (do not guess flags).

---

## RUN 1 — Baseline: one real 30B coding turn
**Goal:** establish the engine-placement + memory + speed picture for a normal OpenCode task on
coder-30b, and confirm the GPU override is doing its job.

**Captures**
| What | Tier 0 source | Tier 2 source |
|---|---|---|
| Engine active during prefill vs decode (CPU/GPU/NPU) | Task Manager graphs | unified timeline |
| TTFT, decode tokens/s | `bench/` harness / OVMS logs | OV-phases JSON query |
| GPU "Shared GPU memory" used vs window | Task Manager GPU | mem counters |
| Host RAM In-use / Available | Task Manager Memory | mem counters |
| DRAM read/write + IP-block bandwidth | — | unified timeline |
| Power (package / per-engine) | HWiNFO (pkg only) | unified timeline |
| NPU utilization | Task Manager NPU | unified timeline |
| t/s decay + clocks over a long run (throttle) | HWiNFO logging | unified timeline |

**What good looks like**
- Decode ≈ **35–45 t/s** (matches the post-override bench). **Red flag: <\~10 t/s** ⇒ memory spill /
  override off / driver regression.
- GPU shared memory **not pinned at the window max** (\~27 GB window after the 87% override) ⇒ the
  \~18 GB working set fits, override effective.
- **NPU ≈ idle** during a pure coding turn ⇒ confirmed offload opportunity (feeds Run 2).
- No thermal throttling in the first minutes; note any t/s decay over a long run.

**Mutation-resistant proof:** deliberately run with the override OFF (or before reboot) and confirm
the capture *shows* the spill (GPU mem maxed) and the t/s collapse to \~3.5. If it can't see the
known-bad state, the capture is worthless — fix it before trusting green.

---

## RUN 2 — NPU offload opportunity (the demo's headline)
**Goal:** confirm the NPU is idle during LLM work, then prove that offloading an *auxiliary* tool
to the NPU lets the main LLM keep generating (no pause) at equal-or-lower power.

**Method**
1. From Run 1, confirm NPU idle during coding.
2. Pick one offloadable tool (RapidOCR, a RAG **embedding** model, or a small vision/diffuser model
   — **NOT** the 30B/14B main decode). Run it on **GPU** then on **NPU** (`benchmark_app -d NPU`)
   while a model decode is in flight.
3. Capture: tool latency, power, and **whether the concurrent LLM decode keeps flowing** vs pauses.

**What good looks like**
- NPU path **frees the GPU so LLM decode does not pause** (the demo's win), at equal-or-lower power.
- A slower-but-non-blocking NPU run is still a win for a *background* task (e.g. summarize/memory).

**Decision gate:** if confirmed, the offload roadmap = OCR (done) → embeddings (RAG) → vision/diffuser
tools → speculative-decode draft model → BlarAI's summarize/memory step. Big-LLM decode stays on GPU.

**Mutation-resistant proof:** verify the "no pause" claim from the *timeline*, not by feel — show the
GPU LLM-kernel stream staying continuous across the offload, not a hidden stall.

---

## RUN 3 — BlarAI VM-vs-host RAM blocker  ← highest leverage
**The #1 [DISCOVER] item.** Option-A swap assumes: release BlarAI's in-VM 14B → enough **host** RAM
frees → OVMS loads the 30B → fleet runs → reload 14B. If the VM holds RAM statically, releasing the
14B frees memory *inside the guest* but **not on the host**, and the swap silently pages.

> Note: BLUEPRINT lists "BlarAI VM (2 GB)" yet the 14B is \~10.5 GB — that apparent inconsistency is
> exactly why this is unknown. **Do not assume BlarAI's internal memory layout; measure it.**
> Host-side measurement only; **do not inspect BlarAI source** (in-VM steps are for the
> BlarAI-session agent).

**Method (host-side)**
1. **VM memory config:** `Get-VM BlarAI-Orchestrator | Get-VMMemory` — is Dynamic Memory on?
   Startup/Min/Max/assigned? **Static + large = the likely blocker.**
2. **Baseline:** with BlarAI fully up + 14B loaded, record host Available
   (`Get-Counter '\Memory\Available MBytes'`) + Task Manager "In use".
3. **Release** the in-VM 14B (BlarAI-session agent does this its own way). Re-record host Available.
4. **ΔAvailable** = how much **host** RAM the release actually freed.
5. **Attempt the swap:** `scripts\start-llm.ps1 -Model coder-30b -Force` (`-Force` mandatory — without
   it the assistant offers to Stop-VM BlarAI-Orchestrator). Observe: does it reach READY and run, or
   page/OOM?

**What good looks like**
- ΔAvailable ≈ the 14B's footprint (host reclaims it), host Available **≥ 21 GB**, 30B reaches READY
  and hits **\~35–45 t/s with no paging** ⇒ **Option A is viable.**

**What bad looks like**
- ΔAvailable ≈ 0 (static VM holds the RAM) → host Available < 21 GB → 30B fails/pages ⇒ Option A needs
  a fix: enable Dynamic Memory, shrink the VM's assigned RAM during the swap, or stop the VM (which
  conflicts with keeping the AO/PA alive — escalate that trade-off, don't paper over it).

**Mutation-resistant proof:** RAM numbers alone can false-pass — KV growth can page mid-task. Confirm
by running a real **multi-turn** 30B task post-swap and watching for t/s collapse / compaction loops.
Then reload the 14B and smoke-check the AO/PA (never end at zero models).

---

## RUN 4 — (optional) Override + swap validation
- Re-confirm the 87% Shared-GPU-Memory Override still yields the \~27 GB window + \~10× decode **after
  any driver update** (driver-bound). Capture window size + t/s with override on vs off.
- Measure model-swap latency (14B↔30B) and ov_cache rebuild cost; expect \~20–60 s.

---

## Decision gates (what the numbers buy you)
- **Run 1 green** → baseline locked; future regressions are now detectable.
- **Run 2 green** → start the NPU-offload roadmap (relieves the memory-bound iGPU + cuts power).
- **Run 3 green** → Option-A swap is real; proceed with the BlarAI headless-coding-dispatch build.
- **Run 3 red** → resolve the VM memory model *before* writing dispatch code (it's the make-or-break).

## Where results live
`agentic-setup/bench/<date>-<topic>.md` (or extend the existing bench notes). Always stamp: date,
driver version, override on/off, model, telemetry tier, and the pass/fail verdict per run.
