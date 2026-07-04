# Qwen3-Coder-30B-A3B on Intel Arc 140V (Lunar Lake) — measured, plus a 10× fix

A first real, reproducible measurement of Qwen3-Coder-30B-A3B (INT4, OpenVINO/OVMS) on a
Core Ultra 7 258V / Arc 140V — and the single setting that makes it usable. Measured
2026-06-17. No published tokens/sec figures existed for this model on this hardware before.

## TL;DR
Out of the box the 30B decodes at **~3.5 t/s** — painfully slow (a 4k-token build ≈ 15 min).
Enabling one driver setting — Intel **"Shared GPU Memory Override" (~87%)** — raises it to
**~35–45 t/s, a ~10× improvement**, *beating* Intel's own published 34 t/s (measured on the
larger 285H). **The override is required, not optional.** Without it the 30B is unusable for
interactive coding; with it, it's the fast, coder-tuned workhorse.

## Hardware / software
- Intel Core Ultra 7 258V (Lunar Lake), Arc 140V (Xe2), 31.3 GB shared LPDDR5X (~136.5 GB/s)
- Qwen3-Coder-30B-A3B-Instruct, INT4 (OpenVINO IR), MoE ~3.3B active params
- OVMS, `--target_device GPU`, `--kv_cache_precision u8`, prefix caching on
- Method: OpenAI `/v3` streaming; TTFT + decode + prefill; warmup excluded; reasoning-aware. `bench.py` (stdlib only).

## The 10× fix
The default Arc shared-GPU window is ~17.9 GB. The 30B's working set (~18 GB: INT4 weights +
KV + runtime) **exceeds** it, so part spills onto the slow path → decode collapses to ~3.5 t/s
(and the GPU shows memory maxed at 17.9/17.9). Raising the window to ~27 GB lets the whole
working set sit in fast GPU-addressable memory → no spill.

| decode | before override | after override |
|---|---|---|
| short context | 3.6 t/s | **45 t/s** |
| ~1k context | 3.6 t/s | **39 t/s** |
| ~4.5k context | 3.5 t/s | **35 t/s** |

**How:** Intel Graphics Software → System → **Shared GPU Memory Override → ~87%** → **reboot**
→ reload the model. (A reboot is required for the window change to take effect.)

## Full results (after override; cold = first run / cache-miss)
| config | prompt tok | TTFT cold | decode t/s | prefill t/s cold |
|---|---|---|---|---|
| short | 43 | 0.4 s | 45 | ~100 |
| medium | 1,143 | 2.5 s | 39 | ~450 |
| large | 4,543 | 6.7 s | 35 | ~680 |

Prefix cache (same prompt re-run): large-prompt TTFT **6.7 s → 0.4 s**.

## Cross-model (both after override)
| model | decode | notes |
|---|---|---|
| Qwen3-Coder-30B (MoE, coder-tuned) | ~35–45 t/s | the choice — faster *and* purpose-built |
| Qwen3-14B (dense, general) | ~12 t/s | usable fallback; "thinking" model adds turn latency |

Counter-intuitively the MoE 30B beats the dense 14B (it reads fewer active params per token) —
*once the override removes the memory bottleneck*.

## Reproduce
```
python bench.py          # model must be loaded on OVMS at 127.0.0.1:8000
```
`bench.py` auto-detects the loaded model and counts reasoning + content tokens (so thinking
models like Qwen3-14B are timed correctly). Raw data: `bench-results.json`.

## Honest caveats
- Single unit, n=2 reps; decode measured over short completions (the summarize prompt returns
  ~20 tokens) — directionally solid and corroborated by real build times.
- `prefill t/s ≈ prompt_tokens / TTFT` (includes queue + first token); the large-prompt cold
  figure is the meaningful one. The per-config summary medians mix cold and cache-warm runs —
  read the cold (first-run) numbers above for true prefill.
- An early version of `bench.py` mis-timed the 14B by ignoring its reasoning tokens (showed a
  bogus 89–100 t/s); the self-test/verify pass caught it and it was fixed before publishing.
