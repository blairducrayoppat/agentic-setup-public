#!/usr/bin/env python3
"""
Hardened helpers that make Qwen3-Coder-30B reliable for MULTI-TURN agentic tool
calling on OVMS 2026.2 (model "coder-30b"). Pure stdlib, fully offline.

ROOT CAUSE (proven live against http://127.0.0.1:8000/v3, 2026-06-20):
  Not temperature, not arg size, not streaming, not the chat template, not
  prompting. After several prior assistant turns that carry tool calls AND a
  task that forces the model to synthesize earlier tool RESULTS, the INT4 model
  drifts and emits an OpenAI-style JSON envelope (or a stray <tool_call> marker)
  as plain `content`. OVMS's qwen3coder parser is XML-marker-only with no JSON
  fallback, so it leaves the call in content with tool_calls=[] / finish=stop,
  and the agentic loop stalls (then spirals to `name=read` once echoed back).

TWO PROVEN MITIGATIONS (use both: 1 prevents, 2 recovers + stops re-contamination):
  1) xmlify_history(): re-serialise every PRIOR assistant tool-call turn as
     native Qwen <tool_call><function=..><parameter=..> text in `content`
     (dropping the structured tool_calls field for history turns). Keeps the
     model in its native format. Proven 4/4 to stop the leak.
  2) salvage_tool_calls(): recovery net. Lift a leaked JSON envelope OR native
     XML out of content into a real tool_calls array. NEVER raises.

Hardened vs the reference impl per adversarial review:
  - salvage NEVER raises (wraps everything; tolerates {"tool_calls":["a","b"]}).
  - detects a bare <tool_call> marker (no <function> body) -> ('bare-marker', None)
    so the caller can trigger a one-shot retry instead of passing prose through.
  - xmlify no longer silently drops params when arguments fail json.loads;
    it falls back to emitting the raw arguments string.
"""
import json
import re

__all__ = ["xmlify_history", "salvage_tool_calls", "strip_trailing_tool_marker"]


def _loads(x):
    """json.loads tolerant of the literal-newline malformation the model emits."""
    for fn in (lambda s: json.loads(s), lambda s: json.loads(s, strict=False)):
        try:
            return fn(x)
        except Exception:
            continue
    return None


def _block_qwen3coder(name, args, raw):
    """Native Qwen3-Coder XML: <tool_call><function=NAME><parameter=K>V</parameter></function></tool_call>"""
    if isinstance(args, dict):
        params = "".join(f"<parameter={k}>\n{v}\n</parameter>\n" for k, v in args.items())
    else:  # fallback: emit raw args rather than dropping params
        raw_str = raw if isinstance(raw, str) else json.dumps(raw)
        params = raw_str + ("" if raw_str.endswith("\n") else "\n")
    return f"<tool_call>\n<function={name}>\n{params}</function>\n</tool_call>"


def _block_hermes(name, args, raw):
    """Hermes/Qwen format (qwen3-14b, --tool_parser hermes3): <tool_call>{json}</tool_call>
    where json = {"name": ..., "arguments": {...}}."""
    arguments = args if isinstance(args, (dict, list)) else (raw if isinstance(raw, str) else {})
    payload = json.dumps({"name": name, "arguments": arguments}, ensure_ascii=False)
    return f"<tool_call>\n{payload}\n</tool_call>"


def xmlify_history(messages, fmt="qwen3coder"):
    """Rewrite OpenAI `messages` so prior assistant tool-call turns become the model's
    NATIVE tool-call format as plain text in `content` (dropping the structured tool_calls
    field for history turns). This is the proven fix that keeps the model emitting its
    native format instead of drifting to an OpenAI JSON envelope. Apply on EVERY request.

    fmt selects the serialisation and MUST match the served model's parser:
      'qwen3coder' -> coder-30b   |   'hermes3' -> qwen3-14b (and other Hermes models).
    Non-assistant / non-tool-call messages pass through untouched. Never raises; a
    malformed tool_call entry is skipped, not dropped silently."""
    builder = _block_hermes if fmt == "hermes3" else _block_qwen3coder
    out = []
    for msg in messages:
        try:
            if msg.get("role") == "assistant" and msg.get("tool_calls"):
                blocks = []
                for tc in msg["tool_calls"]:
                    if not isinstance(tc, dict):
                        continue
                    fn_obj = tc.get("function") if isinstance(tc.get("function"), dict) else tc
                    name = fn_obj.get("name") if isinstance(fn_obj, dict) else None
                    if not name:
                        continue
                    raw = fn_obj.get("arguments", "")
                    args = _loads(raw) if isinstance(raw, str) else raw
                    blocks.append(builder(name, args, raw))
                if not blocks:
                    out.append(msg)
                    continue
                prose = (msg.get("content") or "").strip()
                content = (prose + "\n" + "\n".join(blocks)).strip()
                out.append({"role": "assistant", "content": content})
            else:
                out.append(msg)
        except Exception:
            out.append(msg)  # never lose a message to a bug here
    return out


def salvage_tool_calls(content):
    """If `content` is a leaked tool call, return (kind, calls); else (None, None).
    kind in {'json-envelope','xml','bare-marker'}. 'bare-marker' => no recoverable
    call, caller should retry. Each call: {id?, name, arguments(JSON string)}.
    NEVER raises and is conservative on plain prose to avoid false positives.
    Caller MUST also gate on (tool_calls empty AND finish_reason == 'stop')."""
    try:
        if not content or not isinstance(content, str):
            return (None, None)
        s = content.strip()

        # 1) OpenAI JSON envelope (whole string, or first {...} after a prose prefix)
        obj = _loads(s)
        if obj is None:
            brace = s.find("{")
            if brace != -1:
                obj = _loads(s[brace:])
        if isinstance(obj, dict) and isinstance(obj.get("tool_calls"), list) and obj["tool_calls"]:
            calls = []
            for tc in obj["tool_calls"]:
                if not isinstance(tc, dict):
                    continue  # e.g. {"tool_calls":["a","b"]} -> skip, never raise
                fn = tc["function"] if isinstance(tc.get("function"), dict) else tc
                if not isinstance(fn, dict):
                    continue
                name = fn.get("name")
                args = fn.get("arguments")
                if isinstance(args, (dict, list)):
                    args = json.dumps(args)
                if name:
                    calls.append({"id": tc.get("id"), "name": name, "arguments": args or "{}"})
            if calls:
                return ("json-envelope", calls)

        # 2) Hermes tool calls left in content: <tool_call>{"name":..,"arguments":{..}}</tool_call>
        hblocks = re.findall(r"<tool_call>\s*(\{.*?\})\s*</tool_call>", content, re.S)
        if hblocks:
            calls = []
            for blk in hblocks:
                o = _loads(blk)
                if isinstance(o, dict) and o.get("name"):
                    a = o.get("arguments", {})
                    if not isinstance(a, str):
                        a = json.dumps(a)
                    calls.append({"name": o["name"], "arguments": a or "{}"})
            if calls:
                return ("hermes", calls)

        # 3) Native Qwen3-Coder XML left in content
        blocks = re.findall(r"<function=([^>\s]+)>(.*?)</function>", content, re.S)
        if blocks:
            calls = []
            for name, body in blocks:
                params = dict(re.findall(r"<parameter=([^>\s]+)>\s*(.*?)\s*</parameter>", body, re.S))
                calls.append({"name": name, "arguments": json.dumps(params)})
            if calls:
                return ("xml", calls)

        # 4) Bare marker with no recoverable function body -> retry signal
        if "<tool_call>" in content or re.search(r"<function=", content):
            return ("bare-marker", None)

        return (None, None)
    except Exception:
        return (None, None)


def strip_trailing_tool_marker(content):
    """Remove a DANGLING/incomplete <tool_call> or <function=...> fragment the model
    sometimes appends AFTER a complete final answer (the cosmetic 'bare-marker' case
    proven on the calculator build: work done, then a stray '<tool_call>' tacked on).
    A COMPLETE tool block is left untouched (salvage_tool_calls handles real calls).
    Never raises."""
    try:
        if not content or not isinstance(content, str):
            return content
        # A complete call exists -> not a dangling marker; leave it for salvage.
        if "</tool_call>" in content or re.search(r"<function=[^>]+>.*?</function>", content, re.S):
            return content
        idx = content.rfind("<tool_call>")
        if idx == -1:
            idx = content.rfind("<function=")
        if idx == -1:
            return content
        return content[:idx].rstrip()
    except Exception:
        return content


if __name__ == "__main__":
    # Adversarial self-test battery (must all pass; salvage must NEVER raise).
    import sys
    fails = []

    def expect(label, got, want):
        ok = got == want
        print(f"  [{'OK ' if ok else 'XX '}] {label}: got={got!r}")
        if not ok:
            fails.append(f"{label}: got {got!r}, want {want!r}")

    print("salvage_tool_calls:")
    k, c = salvage_tool_calls(
        '{"tool_calls":[{"function":{"name":"write","arguments":"{\\"filePath\\":\\"x\\"}"}},"id":"c5"}],"content":""}'
        if False else
        '{"tool_calls":[{"function":{"name":"write","arguments":"{\\"filePath\\":\\"x\\"}"},"id":"c5"}],"content":""}'
    )
    expect("C1 exact envelope -> json-envelope", (k, c[0]["name"] if c else None), ("json-envelope", "write"))

    k, c = salvage_tool_calls('{"tool_calls":[{"function":{"name":"write","arguments":{"content":"a\nb"}}}]}')
    expect("C2 dict-args literal newline -> json-envelope", k, "json-envelope")

    k, c = salvage_tool_calls("Reasoning first.\n<tool_call>\n<function=read>\n<parameter=filePath>\nx.txt\n</parameter>\n</function>\n</tool_call>")
    expect("C3 native XML in content -> xml", (k, c[0]["name"] if c else None), ("xml", "read"))

    k, c = salvage_tool_calls("I will use the tool_calls feature to read the file for you.")
    expect("C5 plain prose mentioning tool_calls -> None", (k, c), (None, None))

    k, c = salvage_tool_calls('Let me do that.\n{"tool_calls":[{"function":{"name":"glob","arguments":"{\\"pattern\\":\\"*\\"}"}}]}')
    expect("C7 prose-prefixed envelope -> json-envelope", (k, c[0]["name"] if c else None), ("json-envelope", "glob"))

    k, c = salvage_tool_calls('{"tool_calls":["read the file","write output"]}')
    expect("KILLER list-of-strings -> None (no raise)", (k, c), (None, None))

    k, c = salvage_tool_calls("I'm done with the task.\n<tool_call>")
    expect("BARE marker -> bare-marker", (k, c), ("bare-marker", None))

    k, c = salvage_tool_calls('{"result": 42, "status": "ok"}')
    expect("legit JSON answer -> None", (k, c), (None, None))

    k, c = salvage_tool_calls(None)
    expect("None input -> None", (k, c), (None, None))

    print("\nxmlify_history:")
    hist = [
        {"role": "system", "content": "sys"},
        {"role": "user", "content": "do it"},
        {"role": "assistant", "content": "Writing now.",
         "tool_calls": [{"id": "a1", "type": "function",
                         "function": {"name": "write", "arguments": '{"filePath":"a.txt","content":"hi"}'}}]},
        {"role": "tool", "tool_call_id": "a1", "content": "ok"},
        {"role": "assistant", "content": None,
         "tool_calls": [{"id": "a2", "type": "function",
                         "function": {"name": "read", "arguments": "NOT-JSON"}}]},
    ]
    rew = xmlify_history(hist)
    asst1 = rew[2]
    expect("xmlify turn1 has no tool_calls field", "tool_calls" in asst1, False)
    expect("xmlify turn1 renders XML", "<function=write>" in asst1["content"] and "<parameter=filePath>" in asst1["content"], True)
    expect("xmlify preserves prose", asst1["content"].startswith("Writing now."), True)
    asst2 = rew[4]
    expect("xmlify bad-args does NOT drop (emits raw)", "NOT-JSON" in asst2["content"], True)
    expect("xmlify leaves tool role untouched", rew[3]["role"] == "tool", True)

    print("\nhermes3 (qwen3-14b) format:")
    hh = xmlify_history([
        {"role": "user", "content": "go"},
        {"role": "assistant", "content": "Calling.",
         "tool_calls": [{"id": "h1", "type": "function",
                         "function": {"name": "write", "arguments": '{"filePath":"a.txt","content":"hi"}'}}]},
    ], fmt="hermes3")
    hc = hh[1]["content"]
    expect("hermes xmlify emits <tool_call> JSON", "<tool_call>" in hc and '"name": "write"' in hc and '"arguments"' in hc, True)
    expect("hermes xmlify has NO qwen3coder <function=", "<function=" not in hc, True)
    expect("hermes xmlify drops tool_calls field", "tool_calls" in hh[1], False)
    k, c = salvage_tool_calls('<tool_call>\n{"name":"read","arguments":{"filePath":"x"}}\n</tool_call>')
    expect("hermes salvage -> hermes", (k, c[0]["name"] if c else None), ("hermes", "read"))
    # qwen3coder block must still NOT be misread as hermes
    k, c = salvage_tool_calls("<tool_call>\n<function=glob>\n<parameter=pattern>\n*\n</parameter>\n</function>\n</tool_call>")
    expect("qwen3coder block still -> xml (not hermes)", (k, c[0]["name"] if c else None), ("xml", "glob"))

    print("\nstrip_trailing_tool_marker:")
    expect("strip bare <tool_call> after answer",
           strip_trailing_tool_marker("I've created the app.\n<tool_call>"), "I've created the app.")
    expect("strip incomplete <tool_call><function=",
           strip_trailing_tool_marker("Done.\n<tool_call>\n<function=write>"), "Done.")
    full = "Reasoning\n<tool_call>\n<function=read>\n<parameter=f>\nx\n</parameter>\n</function>\n</tool_call>"
    expect("leave COMPLETE call untouched", strip_trailing_tool_marker(full), full)
    expect("leave plain prose untouched",
           strip_trailing_tool_marker("Just a normal answer."), "Just a normal answer.")

    print()
    if fails:
        print(f"FAILED {len(fails)}:")
        for f in fails:
            print("  -", f)
        sys.exit(1)
    print("ALL SELF-TESTS PASSED")
