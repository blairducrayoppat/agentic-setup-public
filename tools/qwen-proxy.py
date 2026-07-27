#!/usr/bin/env python3
"""
qwen-proxy.py - local tool-call REPAIR proxy for Qwen3-Coder-30B on OVMS.

Sits between any OpenAI-compatible client (OpenCode, OpenClaw workers, etc.) and
OVMS, on 127.0.0.1:8099, and makes MULTI-TURN agentic tool calling reliable:

  REQUEST  : rewrites prior assistant tool-call turns into native Qwen XML
             (xmlify_history) -- the PROVEN fix that prevents the format drift
             that otherwise makes the model leak tool calls into plain content.
  RESPONSE : if OVMS leaves a tool call stranded in content (tool_calls empty,
             finish=stop), reconstructs it into a real tool_calls array
             (salvage_tool_calls); strips a cosmetic trailing <tool_call> marker
             off a completed final answer (strip_trailing_tool_marker).

Pure stdlib, fully offline. Does NOT touch/kill/restart OVMS (port 8000) -- it
only forwards requests to it. Listens on 8099 (>=8081 per the agent-layer rule).

Run:   python qwen-proxy.py        # then point the client baseURL at :8099/v3
Env:   OVMS_BASE (default http://127.0.0.1:8000)   PROXY_PORT (default 8099)
"""
import json, os, sys, re, time, urllib.request, urllib.error
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from qwen_toolcall_fix import xmlify_history, salvage_tool_calls, strip_trailing_tool_marker

OVMS = os.environ.get("OVMS_BASE", "http://127.0.0.1:8000").rstrip("/")
PORT = int(os.environ.get("PROXY_PORT", "8099"))
# Upstream read timeout. A large coding generation on this iGPU can take many minutes; the old
# hardcoded 600s cap fired MID-TURN on a big file and dropped into an UNREPAIRED fallback, so a
# leaked tool-call envelope reached OpenCode as plain text (the cart.html incident, 2026-06-21).
# 1800s gives generous headroom; override via env if a single turn legitimately needs longer.
UPSTREAM_TIMEOUT = int(os.environ.get("UPSTREAM_TIMEOUT", "1800"))
# Per-model history-rewrite format. The format MUST match the served model's parser:
# coder-30b uses --tool_parser qwen3coder; qwen3-14b uses --tool_parser hermes3. Any model
# not listed here passes through untouched (e.g. vision). Override via FIX_MODELS env:
# "coder-30b:qwen3coder,qwen3-14b:hermes3".
def _parse_fix_models(spec):
    out = {}
    for item in spec.split(","):
        item = item.strip()
        if not item:
            continue
        if ":" in item:
            name, fmt = item.split(":", 1)
            out[name.strip()] = fmt.strip()
        else:  # bare name defaults to qwen3coder (back-compat)
            out[item] = "qwen3coder"
    return out

# Default: only the 30B is fixed. The 14B (hermes) rewrite is IMPLEMENTED + unit-tested but OFF by
# default — a live A/B gave no evidence the 14B has the multi-turn leak (it does parallel tool calls,
# so it finishes the calculator in one turn) and forcing stream:false buffers the slow dense 14B at a
# real latency cost. To enable once justified: FIX_MODELS="coder-30b:qwen3coder,qwen3-14b:hermes3".
MODEL_FORMATS = _parse_fix_models(os.environ.get("FIX_MODELS", "coder-30b:qwen3coder"))
_HOP = {"host", "content-length", "connection", "accept-encoding", "transfer-encoding"}


def _upstream(path, method, headers, body):
    req = urllib.request.Request(OVMS + path, data=body, method=method)
    for k, v in headers.items():
        if k.lower() not in _HOP:
            req.add_header(k, v)
    try:
        r = urllib.request.urlopen(req, timeout=UPSTREAM_TIMEOUT)
        return r.status, dict(r.getheaders()), r.read()
    except urllib.error.HTTPError as e:
        return e.code, dict(e.headers), e.read()


def _fix_response(obj):
    """Apply salvage + marker-strip to a full chat.completion object (in place)."""
    for ch in obj.get("choices", []):
        msg = ch.get("message") or {}
        tcs = msg.get("tool_calls") or []
        content = msg.get("content") or ""
        if not tcs and ch.get("finish_reason") == "stop" and content:
            kind, calls = salvage_tool_calls(content)
            if calls:
                msg["tool_calls"] = [{
                    "id": c.get("id") or f"call_{i}", "type": "function",
                    "function": {"name": c["name"], "arguments": c["arguments"]},
                } for i, c in enumerate(calls)]
                msg["content"] = ""
                ch["finish_reason"] = "tool_calls"
            else:
                # FAIL-LOUD on a probable SEVERANCE (#991). salvage found no call, yet the
                # content still carries a tool-call marker -> the model was TRYING to call a
                # tool in a form we cannot reconstruct. Before this, that shipped silently as
                # prose and the agent loop read it as "the model chose to stop" - which is how
                # a one-character `<function/read>` corruption voided a whole battery night
                # without leaving an error. We cannot rescue an unknown form, but it must
                # never be silent again: emit a distinctive stderr line so a severed run is
                # visible in the log rather than scored as a clean finish. New corruption
                # forms surface HERE instead of as an unexplained no-op.
                if _SEVERANCE_MARKER.search(content):
                    sys.stderr.write(
                        "[qwen-proxy] SEVERANCE: finish=stop with an unreconstructable "
                        "tool-call marker in content (kind=%r, %d chars) - the model was "
                        "calling a tool in a form salvage could not parse; shipping as prose. "
                        "First 200 chars: %r\n" % (kind, len(content), content[:200])
                    )
                    sys.stderr.flush()
                msg["content"] = strip_trailing_tool_marker(content)
        ch["message"] = msg
    return obj


#: A tool-call attempt the salvager could not turn into a call. Deliberately BROADER than
#: the salvager's own patterns: it must catch corruption forms salvage cannot parse yet
#: (that is the whole point of a fail-loud), so it matches the tag STEMS, any separator.
_SEVERANCE_MARKER = re.compile(r"<tool_call>|<function[=/\s>]|<parameter[=/\s>]")


def _sse(obj, include_usage=False):
    """Re-emit a full chat.completion as OpenAI streaming chunks (SSE bytes).
    If include_usage (client sent stream_options.include_usage), regular chunks carry
    usage:null and a final chunk carries the real usage, per the OpenAI streaming spec."""
    base = {"id": obj.get("id", "chatcmpl-proxy"), "object": "chat.completion.chunk",
            "created": obj.get("created", int(time.time())), "model": obj.get("model", "")}

    def mk(choices):
        c = {**base, "choices": choices}
        if include_usage:
            c["usage"] = None
        return c

    chunks = []
    for ch in obj.get("choices", []):
        idx = ch.get("index", 0)
        msg = ch.get("message") or {}
        chunks.append(mk([{"index": idx, "delta": {"role": "assistant"}, "finish_reason": None}]))
        if msg.get("content"):
            chunks.append(mk([{"index": idx, "delta": {"content": msg["content"]}, "finish_reason": None}]))
        for ti, tc in enumerate(msg.get("tool_calls") or []):
            chunks.append(mk([{"index": idx, "delta": {"tool_calls": [{
                "index": ti, "id": tc.get("id"), "type": "function",
                "function": {"name": tc["function"]["name"], "arguments": tc["function"]["arguments"]},
            }]}, "finish_reason": None}]))
        chunks.append(mk([{"index": idx, "delta": {}, "finish_reason": ch.get("finish_reason", "stop")}]))
    if include_usage and obj.get("usage"):
        chunks.append({**base, "choices": [], "usage": obj["usage"]})
    return ("".join("data: " + json.dumps(c) + "\n\n" for c in chunks) + "data: [DONE]\n\n").encode()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def _send(self, status, body, content_type="application/json"):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        status, _h, body = _upstream(self.path, "GET", dict(self.headers), None)
        self._send(status, body)

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length) if length else b""
        if "/chat/completions" not in self.path:
            status, _h, body = _upstream(self.path, "POST", dict(self.headers), raw)
            return self._send(status, body)
        # Parse the request. If it isn't a JSON object we can't repair it -> transparent forward.
        try:
            req = json.loads(raw)
            if not isinstance(req, dict):
                raise ValueError("request body is not a JSON object")
        except Exception:
            status, _h, body = _upstream(self.path, "POST", dict(self.headers), raw)
            return self._send(status, body)

        wants_stream = bool(req.get("stream"))
        # stream_options is only valid when stream=true; we force stream=false upstream so we can
        # repair the full response, so we must REMOVE stream_options or OVMS 400s. We re-emit usage.
        stream_opts = req.pop("stream_options", None)
        want_usage = bool(isinstance(stream_opts, dict) and stream_opts.get("include_usage"))
        fmt = MODEL_FORMATS.get(req.get("model"))
        do_fix = fmt is not None
        if do_fix and isinstance(req.get("messages"), list):
            try:
                req["messages"] = xmlify_history(req["messages"], fmt)
            except Exception:
                pass  # history rewrite is best-effort; the response-side salvage still backstops
        req["stream"] = False  # force full response upstream so we can repair/re-emit it

        # Call upstream. A timeout/connection failure here must NOT fall back to an UNREPAIRED
        # passthrough of the original request -- that is exactly how a leaked tool-call envelope
        # reached OpenCode as plain text. Return an explicit error so the client can retry.
        try:
            status, _h, body = _upstream("/v3/chat/completions", "POST", dict(self.headers), json.dumps(req).encode())
        except Exception as e:
            return self._send(504, json.dumps({"error": {"message":
                f"proxy: upstream did not respond within {UPSTREAM_TIMEOUT}s ({e}). The turn may be "
                "too large or the model overloaded -- retry, or /compact to shrink the context."}}).encode())
        if status != 200:
            return self._send(status, body)

        # Every 200 is repaired before it reaches the client: salvage reconstructs a leaked envelope
        # into a real tool_calls array (incl. the flattened {"tool_calls":[{"name","arguments","id"}],
        # "content":...} shape that leaked here). This block must always run on a successful response.
        try:
            obj = json.loads(body)
            if do_fix:
                obj = _fix_response(obj)
            if wants_stream:
                return self._send(200, _sse(obj, want_usage), "text/event-stream")
            return self._send(200, json.dumps(obj).encode())
        except Exception:
            return self._send(200, body)  # last resort: upstream's own non-streaming JSON


def main():
    print(f"qwen-proxy: http://127.0.0.1:{PORT}  ->  {OVMS}   (xmlify + salvage + marker-strip)")
    print(f"Point your client baseURL at: http://127.0.0.1:{PORT}/v3")
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
