# Fixing Qwen3-Coder-30B multi-turn tool calling on OVMS (qwen-proxy)

**Status:** SOLVED + verified in the real OpenCode client (2026-06-20/21). The 30B builds a
multi-file app end-to-end through the fix. The 14B (hermes) extension is implemented + unit-tested;
its live multi-turn check is pending (model not loaded; see §9).

---

## 1. TL;DR

OVMS's `qwen3coder` tool-call parser is **string-marker-only** (`<tool_call>` / `<function=`) with
**no JSON fallback**. In a multi-turn agentic loop the INT4 model intermittently emits its tool call
as an **OpenAI JSON envelope** (or a stray `<tool_call>`) in the **`content`** field; the parser
can't see it, returns `tool_calls=[]`, and the agent loop stalls — then spirals into `name=read`
garbage once the bad turn is echoed back into history.

Fix = **`tools/qwen-proxy.py`**, a tiny stdlib/offline loopback proxy on **:8099** between the
client and OVMS that (a) rewrites tool-call history into the model's *native* format so it never
drifts (prevention), and (b) reconstructs any leaked call back into a real `tool_calls` array
(recovery). OpenCode points at `:8099`; OVMS on `:8000` is never touched.

---

## 2. Symptom

First real OpenCode session against the 30B ("build a calculator app"): tool calls printed as raw
`{"tool_calls": ...}` JSON in the chat, then degraded to malformed `name=read` / `name=write`. The
agent never actually wrote the files past the first one or two.

---

## 3. Root cause (proven, not assumed)

### 3.1 The parser is marker-only
`src/llm/io_processing/qwen3coder/qwen3coder_tool_parser.cpp` detects a tool call **only** by
`find("<tool_call>")` / `find("<function=")`. If neither marker is present, the entire model output
is left as plain `content` and **no** `tool_calls` are emitted. An OpenAI JSON envelope
(`{"tool_calls":[...],"content":""}`) contains neither marker, so it is never extracted. This is a
known cross-engine fragility of the qwen3coder format (cf. vLLM #22975, #29192) — there is no
upstream parser fix as of OVMS 2026.2 / 2026.2.1.

### 3.2 The trigger
Isolated by ablation (and independently reproduced by a research workflow's own live ablations):
the leak needs the **combination** of (several prior assistant tool-call turns) **AND** (a next task
that makes the model synthesise earlier tool *results*). In that state the INT4 model drifts out of
its native XML format and emits the OpenAI JSON envelope it also saw in pre-training.

### 3.3 The spiral
When the client echoes that malformed `content` back into history as a plain assistant message, the
model imitates it and degrades further (INT4 token corruption → `name=read`). One bad turn poisons
the rest of the session.

### 3.4 What it is NOT (each eliminated by experiment, against raw OVMS, non-streaming)
| Hypothesis | Test | Result |
|---|---|---|
| Temperature | re-ran at 0.1 and 0.7 | fails both |
| Argument size | tiny args and huge file-content writes | fails both |
| Streaming parser bug | non-streaming requests | fails (so not streaming-only) |
| Bad chat template | diffed active vs original `chat_template.jinja` | template is correct* |
| Promptable | `AGENTS.md` already forbids text tool calls | ignored (native format, wrong place) |
| Accumulated assistant prose | stripped prose from echoed history | turn-3 leak persists (prose echo only worsens the spiral) |

\* the only delta from the stock Qwen template is a **needed** `arguments | from_json` so OpenAI
string-args render — i.e. someone already fixed the one real template issue. History renders as
correct qwen3coder XML.

Two research-recommended "high-confidence" fixes were **falsified live** on this stack: the
`@ai-sdk` empty-content fix (vercel/ai #12389) and `tool_choice=required`. Both still leaked.

---

## 4. The three tool-call formats (why the fix is format-specific)

| Format | Used by | Shape |
|---|---|---|
| **OpenAI wire** | the API contract (what clients send/expect) | `tool_calls:[{id,function:{name,arguments(JSON string)}}]` |
| **qwen3coder XML** | coder-30b (`--tool_parser qwen3coder`) | `<tool_call><function=NAME><parameter=K>\nV\n</parameter></function></tool_call>` |
| **Hermes** | qwen3-14b (`--tool_parser hermes3`) | `<tool_call>\n{"name":NAME,"arguments":{...}}\n</tool_call>` |

The model is trained to **emit** its native format; the parser turns that back into the OpenAI wire
format for the client. The fix operates in the model's native format, so it **must** match the model
(qwen3coder for the 30B, hermes for the 14B) — applying the wrong one would corrupt history.

---

## 5. The solution — three mechanisms (`tools/qwen_toolcall_fix.py`)

### 5.1 `xmlify_history(messages, fmt)` — PREVENTION (the primary fix)
Before every request, rewrite each **prior** assistant tool-call turn so the call appears as the
model's native format **as plain text in `content`**, dropping the structured `tool_calls` field for
history turns. This keeps the model "in native-format mode" and stops the drift. Proven the decisive
lever (see §8).

History turn `{"role":"assistant","tool_calls":[{"function":{"name":"write","arguments":"{\"filePath\":\"a.txt\"}"}}]}`
becomes, for `fmt="qwen3coder"`:
```
<tool_call>
<function=write>
<parameter=filePath>
a.txt
</parameter>
</function>
</tool_call>
```
and for `fmt="hermes3"`:
```
<tool_call>
{"name": "write", "arguments": {"filePath": "a.txt"}}
</tool_call>
```
Tool-result (`role:"tool"`) turns are left as-is. Malformed entries are skipped, never dropped
silently; arguments that fail to parse fall back to the raw string rather than vanishing.

### 5.2 `salvage_tool_calls(content)` — RECOVERY (the safety net)
If a response still comes back with `tool_calls=[]` and `finish_reason=stop`, reconstruct a real
tool call from `content`. Tries, in order: **OpenAI JSON envelope** → **Hermes `<tool_call>{json}`**
→ **qwen3coder `<function=>`** → **bare marker**. Returns `(kind, calls)` or `(None, None)`.
Hardened per adversarial review: it **never raises** (the original reference impl crashed on
`{"tool_calls":["a","b"]}`), tolerates the literal-newline malformation the model emits
(`json.loads(strict=False)` + brace-substring fallback), and is conservative on plain prose to avoid
false positives. The caller fires it only when `tool_calls` is empty AND `finish_reason=stop`.

### 5.3 `strip_trailing_tool_marker(content)` — COSMETIC
The model often appends a dangling `<tool_call>` to its *final* answer after the work is done (the
"bare marker" case). This strips an incomplete trailing marker while leaving a COMPLETE call for
salvage. So the user sees a clean "done" message instead of a stray `<tool_call>`.

A built-in 23-case self-test battery guards all three (`python tools/qwen_toolcall_fix.py`).

---

## 6. Delivery — the proxy (`tools/qwen-proxy.py`)

A stdlib `ThreadingHTTPServer` on `127.0.0.1:8099` that forwards to OVMS `:8000`:

- **GET** and non-chat **POST**: transparent passthrough.
- **POST `/v3/chat/completions`**:
  1. Look up the model's format in `MODEL_FORMATS` (`coder-30b:qwen3coder`, `qwen3-14b:hermes3`).
     Models not listed (e.g. vision) pass through untouched.
  2. If fixing: `xmlify_history(messages, fmt)` on the request.
  3. **Remove `stream_options`** and force `stream:false` upstream (see §6.1), so it gets a full
     response it can repair.
  4. `salvage_tool_calls` + `strip_trailing_tool_marker` on the response.
  5. If the client asked to stream, re-emit the (repaired) message as spec-compliant SSE chunks,
     including a final `usage` chunk when `stream_options.include_usage` was requested.
- **Robustness:** any exception in the fix path falls back to a transparent forward of the original
  request — the proxy can never make things worse than raw OVMS.
- It never kills/restarts/binds OVMS; it only sends it requests. Stateless → survives model swaps.

### 6.1 The `stream_options` gotcha (found only when the real client hit the proxy)
OpenCode sends `stream:true` **and** `stream_options:{include_usage:true}`. The proxy forces
`stream:false` upstream to repair the full response — but OVMS **400s** if `stream_options` is
present without `stream:true` (`"stream_options provided, but stream not set to true"`). Fix: the
proxy strips `stream_options` before the upstream call and re-emits usage itself. **Lesson:** real
client wire-quirks surface only when the actual client hits the proxy, not in synthetic repros —
always validate end-to-end in the real client.

---

## 7. Wiring (all reversible)

- **`~/.config/opencode/opencode.json`** (the LIVE config OpenCode reads) → `baseURL` = `http://127.0.0.1:8099/v3`.
  (`sync-harness.ps1` copies live→repo, so the repo copy is kept matching; editing only the repo
  copy would NOT take effect and would be overwritten by sync.)
- **`scripts/start-llm.ps1`** → after a model reports READY, auto-starts the proxy if `:8099` is free
  (guarded; stateless proxy survives swaps; uses `pythonw` so there's no window).
- **`tools/start-coding-proxy.cmd`** → manual double-click launcher (idempotent).
- **Revert:** set `baseURL` back to `:8000/v3`. That's the whole revert.

---

## 8. Verification evidence

A **naive** client (no client-side fixes) run against raw OVMS vs the proxy:

| | calculator-build | project-investigate | streaming |
|---|---|---|---|
| raw OVMS `:8000` | 2 clean, 1 leak, **2/3 files** ❌ | 2 clean, 1 leak ❌ | valid SSE |
| via proxy `:8099` | **4 clean, 0 leaks, 3/3 files** ✅ | **6–9 clean, 0 leaks** ✅ | valid SSE + usage ✅ |

- `coder-30b` calculator completes **3/3 runs** (`tools/diag_calculator.py`).
- 23/23 unit tests pass (`tools/qwen_toolcall_fix.py`).
- OpenCode-shaped request (`stream:true`+`stream_options`+tools) → HTTP 200, SSE with tool_call +
  usage + `[DONE]`.
- **Real-client confirmation:** the 30B built a working calculator in an actual OpenCode session.

Repro/verify harness: `tools/verify_via_proxy.py <endpoint>` (naive client), `tools/diag_calculator.py`
(per-turn detail), `state/repro-*.ps1` (raw-OVMS reproductions). NB: the existing
`scripts/test-guided-gen.ps1` only tests **single-turn** calls — it passed while the real multi-turn
loop died. Health checks must exercise the multi-turn loop.

---

## 9. The 14B (hermes) extension — implemented + unit-tested; NOT enabled by default

`xmlify_history(..., "hermes3")` + a hermes branch in `salvage_tool_calls` are implemented and
unit-tested (incl. qwen3coder-vs-hermes disambiguation), so the fix *can* be applied to the 14B.
Single-turn is provably unaffected (turn 1 has no tool-call history to rewrite).

**But it is OFF by default** (`MODEL_FORMATS` ships `coder-30b:qwen3coder` only), because a live A/B
on the loaded 14B (2026-06-21) gave no reason to turn it on and one reason not to:

- **The 14B does PARALLEL tool calls.** Raw `:8000` calculator finished in **1 turn** (all three
  writes in a single assistant turn), 0 leaks — it never enters the multi-turn drift state that
  breaks the 30B. So there is **no evidence the 14B has the leak** the fix targets.
- **The fix has a cost on this model.** The proxy forces `stream:false` to repair the full response;
  the 14B is a *dense* 14B + reasoning model (much slower than the 3B-active 30B), so buffering its
  whole reasoning-heavy response adds real latency / timeout risk and removes live streaming. The
  A/B's other scenarios even hit the test's 180s timeout — a speed limit, not a leak.

Applying an unverified, latency-adding rewrite to a model not shown to need it fails the
verify-don't-assert bar, so it stays off. **To evaluate properly later:** load the 14B, run a
*sequential* multi-turn probe (the calculator is useless here since it batches) with a long timeout,
e.g. `MAXTOK=1500 TIMEOUT=600 python tools/verify_via_proxy.py http://127.0.0.1:8099/v3` after adding
`qwen3-14b:hermes3` to `FIX_MODELS`. **To enable:** set env `FIX_MODELS="coder-30b:qwen3coder,qwen3-14b:hermes3"`
or add the entry to `MODEL_FORMATS`. The hermes code is ready the moment evidence justifies it.

---

## 10. The durable upstream fix

The proxy is the right local fix, but the permanent one is upstream: add a JSON-envelope fallback to
OVMS `qwen3coder_tool_parser.cpp` (in the `Content` branch, detect a stranded `{"tool_calls":...}`
and lift it). The user is an OVMS/OpenVINO contributor — a natural PR that would fix this for
everyone and make the proxy optional.

---

## 11. File map

| File | Role |
|---|---|
| `tools/qwen_toolcall_fix.py` | the three fix functions + 23-case self-test (importable) |
| `tools/qwen-proxy.py` | the :8099 repair proxy |
| `tools/start-coding-proxy.cmd` | manual launcher |
| `tools/verify_via_proxy.py` | naive-client A/B verifier |
| `tools/diag_calculator.py` | per-turn leak diagnostic |
| `tools/qwen-toolcall-fix-reference.py` | original (pre-hardening) reference from the research workflow |
| `state/repro-*.ps1` | raw-OVMS reproductions of the bug |
| `~/.config/opencode/opencode.json` | baseURL → :8099 |
| `scripts/start-llm.ps1` | auto-starts the proxy on model load |
