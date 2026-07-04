#!/usr/bin/env python3
"""Pinpoint the residual calculator-build leak: WHICH turn leaks, whether all 3
files actually get written, and whether a one-shot RETRY recovers an
unsalvageable big-blob leak. xmlify always on. Read-only inference vs OVMS :8000."""
import json, urllib.request, sys
from qwen_toolcall_fix import xmlify_history, salvage_tool_calls

EP = "http://127.0.0.1:8000/v3/chat/completions"
MODEL = json.load(urllib.request.urlopen("http://127.0.0.1:8000/v3/models", timeout=5))["data"][0]["id"]
TOOLS = [
    {"type": "function", "function": {"name": "write", "description": "Write text to a file.",
        "parameters": {"type": "object", "properties": {"filePath": {"type": "string"}, "content": {"type": "string"}}, "required": ["filePath", "content"]}}},
    {"type": "function", "function": {"name": "glob", "description": "Find files by glob.",
        "parameters": {"type": "object", "properties": {"pattern": {"type": "string"}}, "required": ["pattern"]}}},
]
USER = 'Build a calculator web app here: write index.html, then style.css, then script.js, then glob "*" to confirm. One tool call per step.'

def post(messages, force_tool=False):
    payload = {"model": MODEL, "messages": messages, "tools": TOOLS,
               "tool_choice": "required" if force_tool else "auto",
               "temperature": 0.7, "top_p": 0.8, "max_tokens": 1200}
    req = urllib.request.Request(EP, json.dumps(payload).encode(), {"Content-Type": "application/json"})
    return json.load(urllib.request.urlopen(req, timeout=180))["choices"][0]

def run(use_retry):
    hist = [{"role": "system", "content": "You are a coding agent. Act through the provided tools, one step at a time."},
            {"role": "user", "content": USER}]
    files_written, ok_turns, leak_turns, retried_ok = [], 0, 0, 0
    for turn in range(1, 9):
        ch = post(xmlify_history(hist))
        m = ch["message"]; fr = ch.get("finish_reason"); tcs = m.get("tool_calls") or []; content = m.get("content") or ""
        if not tcs and fr == "stop":
            kind, calls = salvage_tool_calls(content)
            if calls:
                tcs = [{"id": c.get("id") or "s", "type": "function", "function": {"name": c["name"], "arguments": c["arguments"]}} for c in calls]
                print(f"  T{turn}: LEAK({kind}) -> SALVAGED {[c['function']['name'] for c in tcs]}")
            elif kind:  # unrecoverable leak (big-blob envelope or bare marker)
                head = content.replace(chr(10), " ")[:140]
                print(f"  T{turn}: LEAK({kind}) UNRECOVERABLE | head={head!r}")
                if use_retry:
                    rch = post(xmlify_history(hist), force_tool=True)  # one-shot retry, force a tool call
                    rm = rch["message"]; rtcs = rm.get("tool_calls") or []
                    if rtcs:
                        retried_ok += 1; tcs = rtcs
                        print(f"       RETRY(tool_choice=required) -> {[t['function']['name'] for t in rtcs]}")
                    else:
                        rk, rc = salvage_tool_calls(rm.get("content") or "")
                        print(f"       RETRY still no structured call (kind={rk})")
                if not tcs:
                    leak_turns += 1
        if tcs:
            ok_turns += 1
            for tc in tcs:
                nm = tc["function"]["name"]
                if nm == "write":
                    try: fp = json.loads(tc["function"]["arguments"]).get("filePath", "?")
                    except Exception: fp = "?(unparsed args)"
                    files_written.append(fp)
                print(f"  T{turn}: {nm}" + (f" -> {fp}" if nm == "write" else ""))
            hist.append({"role": "assistant", "content": "", "tool_calls": tcs})
            for tc in tcs:
                hist.append({"role": "tool", "tool_call_id": tc.get("id") or "x",
                             "content": ("index.html style.css script.js" if tc["function"]["name"] == "glob" else "File written successfully.")})
        else:
            print(f"  T{turn}: no tool call, finish={fr} -> loop ends")
            break
    need = {"index.html", "style.css", "script.js"}
    got = {f.split("/")[-1].split("\\")[-1] for f in files_written}
    complete = need.issubset(got)
    print(f"  => files_written={files_written} | ALL 3 FILES={'YES' if complete else 'NO'} | ok_turns={ok_turns} leak_turns={leak_turns} retries_ok={retried_ok}\n")
    return complete

if __name__ == "__main__":
    retry = "--retry" in sys.argv
    runs = 3
    print(f"calculator-build | xmlify=ON | retry={'ON' if retry else 'OFF'} | {runs} runs\n")
    completes = sum(run(retry) for _ in range(runs))
    print(f"TASK COMPLETED (all 3 files written): {completes}/{runs}")
