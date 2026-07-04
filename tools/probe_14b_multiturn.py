#!/usr/bin/env python3
"""Provoke (or rule out) the multi-turn tool-call drift on the qwen3-14b.
Forces a SEQUENTIAL dependency chain (so the 14B can't batch like it does for the
calculator) ending in a SYNTHESIS step -- the exact combination that broke the 30B.
Logs each turn and prints leaked content verbatim. Long timeout for the slow model.

Usage: TIMEOUT=600 MAXTOK=1500 RUNS=2 python probe_14b_multiturn.py [endpoint]
"""
import json, os, sys, urllib.request

EP = (sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:8000/v3").rstrip("/")
TIMEOUT = int(os.environ.get("TIMEOUT", "600"))
MAXTOK = int(os.environ.get("MAXTOK", "1500"))
RUNS = int(os.environ.get("RUNS", "2"))
MODEL = json.load(urllib.request.urlopen(EP.rsplit("/", 1)[0] + "/v3/models", timeout=5))["data"][0]["id"]

TOOLS = [
    {"type": "function", "function": {"name": "glob", "description": "List files matching a glob.",
        "parameters": {"type": "object", "properties": {"pattern": {"type": "string"}}, "required": ["pattern"]}}},
    {"type": "function", "function": {"name": "read", "description": "Read one file.",
        "parameters": {"type": "object", "properties": {"filePath": {"type": "string"}}, "required": ["filePath"]}}},
    {"type": "function", "function": {"name": "bash", "description": "Run one shell command.",
        "parameters": {"type": "object", "properties": {"command": {"type": "string"}}, "required": ["command"]}}},
    {"type": "function", "function": {"name": "write", "description": "Write one file.",
        "parameters": {"type": "object", "properties": {"filePath": {"type": "string"}, "content": {"type": "string"}}, "required": ["filePath", "content"]}}},
]
LEAK = ('"tool_calls"', "<tool_call", "<function=", '"arguments"', "name=")

SYS = ("You are a coding agent. Make EXACTLY ONE tool call per message, then wait for its result "
       "before the next step. Each step depends on the previous result.")
TASK = ("Audit this repo step by step, ONE tool call per message, using earlier results to decide the next:\n"
        "1) glob '*' to see the files.\n"
        "2) read the package.json you found.\n"
        "3) bash 'git log --oneline -5'.\n"
        "4) read the README.md.\n"
        "5) bash 'ls src'.\n"
        "6) read the main source file you saw in src.\n"
        "7) Finally, WRITE audit.md that SYNTHESIZES everything you learned from steps 1-6 "
        "(files present, dependencies, recent commits, what the project does).")

# canned, dependency-shaped results so the model must keep using prior context
RESULTS = {
    "glob": "package.json  README.md  src/  .gitignore",
    "read": "{ \"name\": \"acme-api\", \"version\": \"2.1.0\", \"dependencies\": { \"express\": \"^4\" } }",
    "bash": "a1b2c3 fix auth\n d4e5f6 add cache\n 778899 init",
    "write": "File written successfully.",
}

def post(messages):
    body = json.dumps({"model": MODEL, "messages": messages, "tools": TOOLS, "tool_choice": "auto",
                       "temperature": 0.7, "top_p": 0.8, "max_tokens": MAXTOK}).encode()
    req = urllib.request.Request(EP + "/chat/completions", body, {"Content-Type": "application/json"})
    return json.load(urllib.request.urlopen(req, timeout=TIMEOUT))["choices"][0]

def run(n):
    hist = [{"role": "system", "content": SYS}, {"role": "user", "content": TASK}]
    leaks = clean = 0
    print(f"\n----- RUN {n} ({EP}) -----")
    for turn in range(1, 12):
        try:
            ch = post(hist)
        except Exception as e:
            print(f"  T{turn}: REQUEST ERROR: {e}"); break
        m = ch["message"]; tcs = m.get("tool_calls") or []; content = m.get("content") or ""; fr = ch.get("finish_reason")
        is_leak = (not tcs) and fr == "stop" and any(k in content for k in LEAK)
        names = ",".join(t["function"]["name"] for t in tcs) if tcs else "(none)"
        if is_leak:
            leaks += 1
            print(f"  T{turn}: <<< LEAK (finish={fr}) >>> content[:300]={content[:300]!r}")
            break
        if tcs:
            clean += 1
            print(f"  T{turn}: tool_calls=[{names}] ({len(tcs)} call(s))")
            hist.append({"role": "assistant", "content": content, "tool_calls": tcs})
            for tc in tcs:
                hist.append({"role": "tool", "tool_call_id": tc.get("id") or "x",
                             "content": RESULTS.get(tc["function"]["name"], "ok")})
        else:
            print(f"  T{turn}: no tool call, finish={fr} -> model is done/talking. content[:200]={content[:200]!r}")
            break
    print(f"  => clean_tool_turns={clean}  leaks={leaks}")
    return leaks

if __name__ == "__main__":
    print(f"MODEL={MODEL}  EP={EP}  TIMEOUT={TIMEOUT}s  MAXTOK={MAXTOK}  RUNS={RUNS}")
    total = sum(run(i + 1) for i in range(RUNS))
    print(f"\n=== TOTAL LEAKS across {RUNS} runs: {total} ===")
    print("VERDICT:", "14B DRIFTS multi-turn -> the fix is justified" if total else
          "14B stayed CLEAN multi-turn -> no drift; leaving the fix OFF is correct")
