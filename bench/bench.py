#!/usr/bin/env python3
"""Local LLM benchmark for OVMS (OpenAI-compatible /v3 endpoint).

Stdlib only (offline-safe). Measures time-to-first-token (TTFT), decode
tokens/sec, and approximate prefill tokens/sec across prompt and output sizes.

  Run:    python bench.py
  Output: prints a median summary table; writes bench-results.json beside this file.

Methodology notes (for honest reporting):
- decode t/s = completion_tokens / (t_last_token - t_first_token)  -> pure generation rate.
- TTFT      = t_first_token - request_start                        -> includes queue + prefill.
- prefill t/s ~= prompt_tokens / TTFT  -> only meaningful for LARGE prompts (small prompts
  are dominated by fixed overhead). Use the large-prompt row for the real prefill number.
- token counts come from the server 'usage' field when present, else a streamed-delta count.
"""
import json, os, time, statistics, urllib.request

BASE = "http://127.0.0.1:8000/v3/chat/completions"

def _detect_model():
    try:
        with urllib.request.urlopen("http://127.0.0.1:8000/v3/models", timeout=10) as r:
            return json.load(r)["data"][0]["id"]
    except Exception:
        return "coder-30b"

MODEL = _detect_model()
REPS = 2

FILLER = ("The system runs entirely on local hardware with no external network access. "
          "Privacy and governance are treated as first-class architectural concerns here. ")

# (label, approx prompt words, max output tokens)
CONFIGS = [
    ("warmup",                       30,   64),
    ("short prompt / short out",     30,   256),
    ("med prompt ~1k / short out",   1000, 256),
    ("large prompt ~4k / short out", 4000, 256),
    ("short prompt / long out",      30,   600),
]

def make_prompt(words):
    unit = len(FILLER.split())
    reps = max(1, words // unit)
    return (FILLER * reps).strip() + "\n\nIn one short sentence, summarize the text above."

def run_once(prompt, max_tokens):
    payload = {"model": MODEL, "messages": [{"role": "user", "content": prompt}],
               "max_tokens": max_tokens, "temperature": 0.2,
               "stream": True, "stream_options": {"include_usage": True}}
    req = urllib.request.Request(BASE, data=json.dumps(payload).encode(),
                                 headers={"Content-Type": "application/json"})
    t0 = time.perf_counter(); t_first = t_last = None; n = 0; usage = None
    with urllib.request.urlopen(req, timeout=600) as resp:
        for raw in resp:
            line = raw.decode("utf-8", "ignore").strip()
            if not line.startswith("data:"):
                continue
            body = line[5:].strip()
            if body == "[DONE]":
                break
            try:
                obj = json.loads(body)
            except Exception:
                continue
            if obj.get("usage"):
                usage = obj["usage"]
            ch = obj.get("choices") or []
            if ch:
                d = ch[0].get("delta") or {}
                # count BOTH content and reasoning_content so thinking models
                # (e.g. Qwen3-14B) are timed correctly, not just their final answer.
                if d.get("content") or d.get("reasoning_content"):
                    now = time.perf_counter()
                    if t_first is None:
                        t_first = now
                    t_last = now; n += 1
    comp = (usage or {}).get("completion_tokens") or n
    ptok = (usage or {}).get("prompt_tokens")
    ttft = (t_first - t0) if t_first else None
    dsec = (t_last - t_first) if (t_first and t_last and t_last > t_first) else None
    return {"prompt_tokens": ptok, "completion_tokens": comp, "ttft_s": ttft,
            "decode_tps": (comp / dsec) if (dsec and comp) else None,
            "prefill_tps": (ptok / ttft) if (ttft and ptok) else None}

def fmt(x, nd=2):
    return f"{x:.{nd}f}" if isinstance(x, (int, float)) else "n/a"
def med(xs):
    xs = [x for x in xs if isinstance(x, (int, float))]
    return statistics.median(xs) if xs else None
def rnd(x, nd):
    return round(x, nd) if isinstance(x, (int, float)) else None

def main():
    print(f"Benchmarking {MODEL} at {BASE}\n")
    results = []
    for label, words, maxtok in CONFIGS:
        prompt = make_prompt(words)
        n_runs = 1 if label == "warmup" else REPS
        runs = []
        for i in range(n_runs):
            r = run_once(prompt, maxtok)
            runs.append(r)
            print(f"  {label} [run {i+1}]: ttft={fmt(r['ttft_s'])}s "
                  f"decode={fmt(r['decode_tps'], 1)} t/s prefill~{fmt(r['prefill_tps'], 0)} t/s "
                  f"(prompt={r['prompt_tokens']} comp={r['completion_tokens']})", flush=True)
        if label == "warmup":
            continue
        results.append({"config": label,
                        "prompt_tokens": runs[0]["prompt_tokens"],
                        "ttft_s": rnd(med([r["ttft_s"] for r in runs]), 2),
                        "decode_tps": rnd(med([r["decode_tps"] for r in runs]), 1),
                        "prefill_tps": rnd(med([r["prefill_tps"] for r in runs]), 0)})
    print(f"\n=== SUMMARY (median of {REPS} reps) ===")
    print(f"{'config':31}{'prompt_tok':>11}{'TTFT_s':>9}{'decode t/s':>12}{'prefill t/s':>13}")
    for a in results:
        print(f"{a['config']:31}{str(a['prompt_tokens']):>11}{str(a['ttft_s']):>9}"
              f"{str(a['decode_tps']):>12}{str(a['prefill_tps']):>13}")
    out_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "bench-results.json")
    with open(out_path, "w") as f:
        json.dump({"model": MODEL, "endpoint": BASE, "reps": REPS, "results": results}, f, indent=2)
    print(f"\nsaved {out_path}")

if __name__ == "__main__":
    main()
