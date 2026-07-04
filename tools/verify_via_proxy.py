#!/usr/bin/env python3
"""Naive OpenAI client (NO client-side fixes) to prove the PROXY does the repair.
Run the same loop against :8000 (raw OVMS -> should fail) and :8099 (proxy -> should
pass). Usage: python verify_via_proxy.py http://127.0.0.1:8099/v3"""
import json, os, sys, urllib.request

EP = (sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:8099/v3").rstrip("/")
MAXTOK = int(os.environ.get("MAXTOK", "1200"))    # reasoning models (14B) need more headroom
TIMEOUT = int(os.environ.get("TIMEOUT", "180"))   # slow dense models (14B) need a longer budget
MODEL = json.load(urllib.request.urlopen(EP.rsplit("/", 1)[0] + "/v3/models", timeout=5))["data"][0]["id"]

TOOLS = [
    {"type": "function", "function": {"name": "write", "description": "Write text to a file.",
        "parameters": {"type": "object", "properties": {"filePath": {"type": "string"}, "content": {"type": "string"}}, "required": ["filePath", "content"]}}},
    {"type": "function", "function": {"name": "read", "description": "Read a file.",
        "parameters": {"type": "object", "properties": {"filePath": {"type": "string"}}, "required": ["filePath"]}}},
    {"type": "function", "function": {"name": "glob", "description": "Find files by glob.",
        "parameters": {"type": "object", "properties": {"pattern": {"type": "string"}}, "required": ["pattern"]}}},
    {"type": "function", "function": {"name": "bash", "description": "Run a shell command.",
        "parameters": {"type": "object", "properties": {"command": {"type": "string"}}, "required": ["command"]}}},
]
LEAK_MARKERS = ('"tool_calls"', "<tool_call", "<function=", '"arguments"')


def post(messages, stream=False):
    payload = {"model": MODEL, "messages": messages, "tools": TOOLS, "tool_choice": "auto",
               "temperature": 0.7, "top_p": 0.8, "max_tokens": MAXTOK, "stream": stream}
    req = urllib.request.Request(EP + "/chat/completions", json.dumps(payload).encode(), {"Content-Type": "application/json"})
    return urllib.request.urlopen(req, timeout=TIMEOUT)


def fake(name):
    return {"write": "File written successfully.", "read": "(contents)", "glob": "index.html style.css script.js", "bash": "(output)"}.get(name, "ok")


def run(user, need_files=None, max_turns=9):
    hist = [{"role": "system", "content": "You are a coding agent. Act through the provided tools, one step at a time."},
            {"role": "user", "content": user}]
    clean = leaks = 0
    written = []
    for _ in range(max_turns):
        ch = json.load(post(hist))["choices"][0]
        m = ch["message"]; tcs = m.get("tool_calls") or []; content = m.get("content") or ""
        if not tcs:
            if ch.get("finish_reason") == "stop" and any(k in content for k in LEAK_MARKERS):
                leaks += 1
            break
        clean += 1
        for tc in tcs:
            if tc["function"]["name"] == "write":
                try: written.append(json.loads(tc["function"]["arguments"]).get("filePath", "?"))
                except Exception: written.append("?")
        hist.append({"role": "assistant", "content": content, "tool_calls": tcs})
        for tc in tcs:
            hist.append({"role": "tool", "tool_call_id": tc.get("id") or "x", "content": fake(tc["function"]["name"])})
    complete = None
    if need_files:
        got = {f.split("/")[-1].split("\\")[-1] for f in written}
        complete = need_files.issubset(got)
    return clean, leaks, complete, written


def stream_smoke():
    """Confirm the proxy emits valid SSE that reconstructs a tool_call."""
    msgs = [{"role": "system", "content": "Use tools, one step at a time."},
            {"role": "user", "content": 'Write a file hello.txt with "hi" using the write tool.'}]
    resp = post(msgs, stream=True)
    saw_tool, saw_done, name = False, False, None
    for line in resp:
        line = line.decode("utf-8", "replace").strip()
        if not line.startswith("data:"):
            continue
        data = line[5:].strip()
        if data == "[DONE]":
            saw_done = True; break
        try:
            d = json.loads(data)
            delta = d["choices"][0].get("delta", {})
            for tc in delta.get("tool_calls") or []:
                saw_tool = True; name = tc["function"]["name"]
        except Exception:
            pass
    return saw_tool, saw_done, name


if __name__ == "__main__":
    print(f"ENDPOINT={EP}  MODEL={MODEL}\n")
    c, l, comp, w = run('Build a calculator web app here: write index.html, then style.css, then script.js, then glob "*" to confirm. One tool call per step.',
                        need_files={"index.html", "style.css", "script.js"})
    print(f"calculator-build : clean_turns={c} leaks={l} ALL_3_FILES={'YES' if comp else 'NO'}  files={w}")
    c, l, comp, w = run('Investigate this project ONE tool call per step: glob "*", read package.json, bash "node --version", glob "src/**", read README.md, bash "git status".')
    print(f"project-investig.: clean_turns={c} leaks={l}")
    st, dn, nm = stream_smoke()
    print(f"streaming-smoke  : tool_call_in_SSE={'YES' if st else 'NO'} ({nm})  [DONE]_seen={'YES' if dn else 'NO'}")
