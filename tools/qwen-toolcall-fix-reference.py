#!/usr/bin/env python3
"""
Reference helpers for making Qwen3-Coder-30B reliable for multi-turn agentic
tool calling on OVMS 2026.2 (model "coder-30b"), proven live against
http://127.0.0.1:8000/v3 on 2026-06-20.

ROOT CAUSE (proven live): the failure is NOT empty content:"" in history,
NOT temperature, NOT tool_choice, NOT raw turn depth. It is the model's
intrinsic format drift that fires when history contains several prior
assistant turns carrying tool calls in the OpenAI `tool_calls` FIELD
(rendered as Qwen XML by the chat template) AND the next task forces the
model to synthesize earlier tool RESULTS. In that state the model emits an
OpenAI-style JSON envelope as plain `content`; OVMS's qwen3coder parser is
XML-marker-only and leaves it in content with tool_calls=[] / finish=stop.

TWO PROVEN MITIGATIONS:
  1) xmlify_history(): re-serialize every prior assistant tool-call turn as
     native Qwen <tool_call><function=..><parameter=..> text in `content`
     (drop the structured tool_calls field for HISTORY turns only). Proven
     4/4 to stop the leak in the exact failing case.
  2) salvage_tool_calls(): client-side recovery net. When a response has
     empty tool_calls, lift a leaked JSON envelope OR native XML out of
     content into a real tool_calls array. Tolerates the literal-newline
     malformation the model actually emits (json.loads strict=False).
Use BOTH (1 prevents, 2 recovers + stops re-contamination of history).
"""
import json
import re


def xmlify_history(messages):
    """Rewrite OpenAI messages so prior assistant tool calls become native
    Qwen XML text in content. Apply to the messages array on EVERY request
    in a multi-turn loop. Leaves the final/non-tool messages untouched."""
    out = []
    for msg in messages:
        if msg.get("role") == "assistant" and msg.get("tool_calls"):
            blocks = []
            for tc in msg["tool_calls"]:
                fn = tc["function"]["name"]
                try:
                    args = json.loads(tc["function"]["arguments"])
                except Exception:
                    args = {}
                params = "".join(
                    f"<parameter={k}>\n{v}\n</parameter>\n" for k, v in args.items()
                )
                blocks.append(f"<tool_call>\n<function={fn}>\n{params}</function>\n</tool_call>")
            prose = (msg.get("content") or "").strip()
            new = {"role": "assistant", "content": (prose + "\n" + "\n".join(blocks)).strip()}
            out.append(new)
        else:
            out.append(msg)
    return out


def salvage_tool_calls(content):
    """If `content` is a leaked tool call, return ('json-envelope'|'xml', [calls]),
    else (None, None). Each call: {id?, name, arguments(JSON string)}.
    Conservative: returns None on plain prose to avoid false positives."""
    if not content:
        return (None, None)
    s = content.strip()

    # 1) OpenAI JSON envelope (model often emits LITERAL newlines -> strict=False)
    obj = None
    for parser in (lambda x: json.loads(x), lambda x: json.loads(x, strict=False)):
        try:
            obj = parser(s)
            break
        except Exception:
            obj = None
    # also try the first {...} block if there is a prose prefix
    if obj is None:
        brace = s.find("{")
        if brace != -1:
            for parser in (lambda x: json.loads(x), lambda x: json.loads(x, strict=False)):
                try:
                    obj = parser(s[brace:])
                    break
                except Exception:
                    obj = None
    if isinstance(obj, dict) and isinstance(obj.get("tool_calls"), list) and obj["tool_calls"]:
        calls = []
        for tc in obj["tool_calls"]:
            fn = tc["function"] if isinstance(tc.get("function"), dict) else tc
            name = fn.get("name")
            args = fn.get("arguments")
            if isinstance(args, (dict, list)):
                args = json.dumps(args)
            if name:
                calls.append({"id": tc.get("id"), "name": name, "arguments": args or "{}"})
        if calls:
            return ("json-envelope", calls)

    # 2) Native Qwen XML left in content
    blocks = re.findall(r"<function=([^>\s]+)>(.*?)</function>", content, re.S)
    if blocks:
        calls = []
        for name, body in blocks:
            params = dict(re.findall(r"<parameter=([^>\s]+)>\s*(.*?)\s*</parameter>", body, re.S))
            calls.append({"name": name, "arguments": json.dumps(params)})
        if calls:
            return ("xml", calls)

    return (None, None)
