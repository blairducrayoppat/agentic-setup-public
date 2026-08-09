# Handoff Brief — Arc 140V repro for openvino.genai issue #3968

**For:** the agent that will *plan and run* this reproduction and *draft* the GitHub comment.
**Owner:** Blair (OpenVINO upstream contributor). **Created:** 2026-06-21.
**Status:** PLANNING. Nothing posted upstream until the human approves the drafted comment.

---

## 1. Mission

Produce a clean, quantified, **Arc 140V (Lunar Lake, shared-memory iGPU)** data point for
[`openvinotoolkit/openvino.genai#3968` "High memory usage on Qwen3.5"](https://github.com/openvinotoolkit/openvino.genai/issues/3968),
measuring the linear-attention prefix-cache memory blow-up on **Qwen3.6-35B-A3B at 32k context, with vs without the
new `cache_interval_multiplier` mitigation**, and draft a maintainer-ready comment.

Why this is worth doing: every existing data point on this issue is from discrete GPUs / unified-memory Macs. A
**Core Ultra 7 258V / Arc 140V with a 31.3 GB shared pool** is a distinct and under-reported regime (the GPU draws KV/cache
from the same pool as the OS), and it's the regime Intel's own client users hit. A rigorous repro here is a genuinely
useful contribution and directly informs whether/when Blair's stack can adopt a better coder.

**Deliverable = a drafted GitHub comment (markdown) for human review. Do NOT post it yourself.** Posting to a public
Intel repo is an outward-facing action gated on Blair's explicit approval (and uses his authenticated `gh`/account).

---

## 2. Background (verified facts — re-verify the live ones at run time)

- **The issue (#3968):** OPEN, filed 2026-06-10. Reporter's repro: `Qwen3.5-0.8B-int8_asym-ov` consumed **18.4 GB for
  110k tokens** even with `KV_CACHE_PRECISION i4`, vs `OpenVINO/Qwen3-4B-int4-ov` using **9.3 GB** for the same task —
  i.e. a linear-attention model using \~2× the memory of a comparable standard-attention model. As of last check: no
  maintainer reply, no linked PR, no milestone. **Re-read the thread before drafting** — it is evolving.
- **The mitigation:** OVMS **2026.2.1 (2026-06-19)** added a `cache_interval_multiplier` parameter for LLM/VLM models
  with linear attention; release guidance recommends **\~64 for long prompts (>20k tokens)** to curb the blow-up. The
  prior **2026.2 (2026-05-28)** added **Xe-GPU support for MoE models** (the path we test on) and is where the known
  limitation was first documented. **The exact flag name, value range, and where it is set (OVMS CLI vs per-model
  graph/config) MUST be confirmed from the 2026.2.1 release notes/docs before running** — do not assume.
- **Root cause class:** Qwen3.6-35B-A3B is the **Qwen3-Next hybrid architecture** — \~3:1 Gated DeltaNet (linear,
  recurrent state, stores *no* per-token KV) to full Gated Attention. Only \~25% of layers contribute to a growing KV
  cache; the blow-up is in how prefix caching handles the recurrent state, not raw KV size. This is a known-hard,
  cross-runtime problem (mlx-lm #980 has the same hybrid prefix-cache bug).

---

## 3. Environment (the machine this runs on)

- **HW:** ASUS ExpertBook P5405CSA · Core Ultra 7 258V (Lunar Lake) · **Arc 140V iGPU** · **31.3 GB shared LPDDR5X**
  (\~136 GB/s, not upgradable) · Windows 11 Pro. Idles \~15 GB used with the BlarAI VM up.
- **Serving:** OVMS native Windows on GPU, OpenAI API at `127.0.0.1:8000/v3`. Launcher: `scripts\start-llm.ps1`
  (one model resident at a time). Models live under `C:\models\`. Pinned flags include
  `--model_path`, `--rest_bind_address 127.0.0.1`, `--enable_prefix_caching true`, and `--kv_cache_precision u8`
  for the coder. **`--enable_prefix_caching true` MUST stay ON — it is the feature under test.**
- **GPU memory override is REQUIRED** for anything \~18 GB+: Intel Graphics Software → System →
  Shared GPU Memory Override → \~87% **+ reboot** raises the iGPU window from \~18 GB to \~27 GB. Without it, large models
  spill to the slow path and collapse to \~3.5 t/s. Confirm it is enabled before measuring (see `bench/`).
- **Lean profile** needed for a 35B: BlarAI VM stopped, browser closed, and enough free RAM to clear the
  per-model floor `start-llm.ps1` enforces (`$needGB`; ≥19 GB for the 30B as of 2026-08-07 — read the
  script, not this line). **Never operate inside `C:\Users\mrbla\BlarAI`.** Respect the OpenCode deny-edit configs.
- **Gotcha:** Bitdefender Advanced Threat Defense blocks pwsh command lines that pattern-match recon
  (Bypass + web request + process listing in one line). If a scripted step dies with `EPERM`, check BD notifications;
  split the command or route through cmd/curl. **No broad AV exclusions.**
- **OVMS version:** the BLUEPRINT references 2026.2. **The `cache_interval_multiplier` test requires 2026.2.1+** —
  verify the installed version (`C:\ovms\ovms.exe --version`) and plan an update step if needed.

---

## 4. Experiment design (the agent refines, but hold this spine)

**Primary comparison (isolates the variable):** same model, prefix caching ON, vary only the mitigation.

| Arm | Model | `cache_interval_multiplier` | Purpose |
|---|---|---|---|
| A | Qwen3.6-35B-A3B int4-ov | **off / default** | reproduce the blow-up |
| B | Qwen3.6-35B-A3B int4-ov | **64** (per release guidance) | measure the mitigation |
| C (control) | **Qwen3-Coder-30B-A3B-Instruct-int4-ov** (already at `C:\models\coder-30b`) | n/a (standard attention) | show the blow-up is linear-attention-specific, apples-to-apples (\~same size/quant/machine) |

The control (C) is the strongest part of the repro: it's a standard-attention `Qwen3MoeForCausalLM` of nearly the same
size and INT4 on the *same* box, mirroring how the issue compared Qwen3.5-0.8B vs Qwen3-4B.

**Hold constant across all arms:** the exact prompt, context length (**32k**, ≥ the >20k threshold the mitigation
targets), `KV_CACHE_PRECISION` (default to **u8** — the stack's setting; optionally also run **i4** to match the
issue's exact config for comparability), prefix-caching ON, generation length, OVMS version, GPU override state,
and idle baseline conditions (lean profile, same background load).

**Prompt design — exercise prefix-cache *reuse*, not just a long prompt.** The bug is about the prefix cache. Use a
fixed, reproducible \~32k-token prefix, then issue **two requests that share that prefix** (e.g. same 32k context,
different final question) so the second request hits the cache. Measure peak memory across both. (A single long
prompt is the weaker version; the issue's scenario is cache reuse.) Commit the exact prompt file to the repro so it's
reproducible.

**Runs:** ≥3 per arm; report median + spread, not a single number (Blair demands mutation-resistant numbers — one
green run is not evidence). A thin laptop thermally throttles on multi-minute inference; note it.

**Expected-but-confirm:** Arm A may **OOM at 32k on the 27 GB window** — that is a *valid, headline result*
("Qwen3.6-35B-A3B OOMs at 32k without the flag on a 31.3 GB Arc 140V; fits at <X> GB with `cache_interval_multiplier=64`"),
not a failed run. Capture the OOM cleanly (error + memory at point of failure); do not let it wedge the machine.

---

## 5. Measurement methodology

- **Reuse the existing harness:** `agentic-setup/bench/` (`bench.py`, `bench-results.json`, `README.md`) already
  measures pp/tg and **resident RAM at target ctx on this exact machine** for the 30B. Extend it — do not reinvent
  measurement, and keep the methodology identical to the prior 30B numbers so they're comparable.
- **Metric:** on a shared-memory iGPU the meaningful quantity is **peak system RAM "In use"** and/or the **GPU
  "Shared GPU memory"** counter during 32k prefill + decode, reported as **absolute peak** and **delta over idle
  baseline**. Cross-check the programmatic number against Task Manager → Performance (GPU shared / Memory in use).
- **Capture points:** idle baseline → after model load → after 32k prefill → during decode → after the 2nd
  (prefix-reuse) request. The shape of the curve (where it balloons) is as useful to maintainers as the peak.
- **Sanity / anti-false-pass checks:** (a) confirm prefix caching is actually engaged — TTFT on the cache-hit 2nd
  request should drop sharply; if it doesn't, the cache isn't being exercised and the memory comparison is invalid.
  (b) Confirm the control (C) and test (A) differ *because of* attention type, not a confound (same quant, ctx,
  precision, override state). (c) Confirm `cache_interval_multiplier` actually took effect (it changes A→B and
  nothing else).

---

## 6. Prerequisites to resolve BEFORE running (likely blockers)

1. **Model availability.** There may be **no prebuilt `OpenVINO/Qwen3.6-35B-A3B-*-int4-ov`** (only GGUF + a GPTQ-Int4
   exist; OV lists the *architecture* as supported). First check the OpenVINO HF org; if absent, convert via
   `optimum-cli export openvino --model Qwen/Qwen3.6-35B-A3B --weight-format int4 --group-size 128 ...` — which needs
   (a) an **optimum-intel new enough to support the Qwen3-Next/Qwen3.6 hybrid arch** (verify), (b) \~70 GB FP16 download
   + \~21 GB output (disk OK: \~230 GB free), (c) significant time. Record the exact source/conversion command for the comment.
2. **OVMS 2026.2.1+ installed**, and the **exact `cache_interval_multiplier` syntax/placement** confirmed from its docs.
3. **GPU memory override enabled + rebooted**; lean profile achievable (BlarAI VM off, browser closed).
4. **Fallback if the 35B won't run at 32k even with the flag** on 31.3 GB: fall back to a **smaller linear-attention
   model** (e.g. a Qwen3.6-8B / Qwen3.5 small int4-ov) and/or a shorter context, and say so explicitly. The issue's own
   repro used a 0.8B model — a smaller Arc 140V data point is still a valid contribution. Do not silently drop scope.

---

## 7. Deliverable — the drafted GitHub comment

Structure it for a maintainer to act on, concise and factual (no marketing):
- **Environment block:** HW (Arc 140V / Lunar Lake / 31.3 GB shared), OS, OVMS version, OpenVINO/optimum versions,
  model + exact int4-ov source or conversion command, GPU-override state.
- **Method:** prompt (linked/attached), 32k ctx, KV precision, prefix-caching ON, prefix-reuse pattern, run count.
- **Results table:** peak + delta memory (or OOM) for arms A / B / C; the memory-vs-stage curve if captured.
- **Finding:** does `cache_interval_multiplier=64` resolve it on a shared-memory iGPU? Any residual gap? One honest
  paragraph — no overclaiming.
- **Offer:** logs / further configs on request. Reference OVMS 2026.2.1 and link the relevant release notes.
- **Etiquette:** re-read the thread first (avoid duplicating a maintainer update); confirm it adds signal not noise;
  courteous tone.

---

## 8. Definition of done / acceptance criteria

- [ ] Prereqs resolved (model obtained/converted, OVMS 2026.2.1+, flag syntax confirmed, override on).
- [ ] Arms A/B/C measured ≥3× each with the existing `bench/` methodology; medians + spread recorded.
- [ ] Anti-false-pass checks passed (prefix cache engaged; A↔C differ only by attention type; flag verifiably applied).
- [ ] A reproducible prompt + run script committed under `bench/` (or a sibling dir); no machine left wedged/OOM-stuck.
- [ ] A maintainer-ready comment **drafted** and handed to Blair for review. **Not posted** without his go-ahead.
- [ ] Scope honestly stated if a fallback model/context was used.

## 9. What NOT to do

- Don't post upstream without Blair's approval. Don't invent the `cache_interval_multiplier` syntax — confirm it.
- Don't report single-run numbers. Don't disable prefix caching (that's the feature under test).
- Don't touch `C:\Users\mrbla\BlarAI`, the OpenClaw config, or deny-listed agentic-setup configs.
- Don't add AV exclusions. Don't leave the BlarAI VM stopped without offering to restart it (`start-llm.ps1` handles this).

## 10. Pointers

- Issue: https://github.com/openvinotoolkit/openvino.genai/issues/3968
- OVMS releases (2026.2.1 / 2026.2): https://github.com/openvinotoolkit/model_server/releases
- This repo: `BLUEPRINT.md` (§1 GPU override, §3 serving), `bench/` (measurement harness), `scripts\start-llm.ps1`
  (launcher + lean-profile assistant), `scripts\02-install-ovms-and-models.ps1` (model pull pattern).

## 11. Open questions for Blair (confirm before executing)

1. Do you already have a Qwen3.6-35B-A3B int4-ov, or should the agent convert it (\~70 GB download + time)?
2. Is OVMS updated to 2026.2.1, and is updating it OK?
3. KV precision for the runs — **u8** (your stack default), **i4** (matches the issue), or both?
4. OK to attempt the 35B at 32k given the OOM risk + required GPU-override reboot, or start with the smaller-model fallback?
5. You post the final comment yourself (agent drafts), correct? Or authorize the agent to post via your `gh`?
