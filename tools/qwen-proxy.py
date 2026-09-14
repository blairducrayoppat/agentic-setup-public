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
import json, os, select, socket, sys, re, threading, time, urllib.request, urllib.error, urllib.parse
import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from qwen_toolcall_fix import xmlify_history, salvage_tool_calls, strip_trailing_tool_marker

OVMS = os.environ.get("OVMS_BASE", "http://127.0.0.1:8000").rstrip("/")
PORT = int(os.environ.get("PROXY_PORT", "8099"))
# Upstream read timeout. A large coding generation on this iGPU can take many minutes; the old
# hardcoded 600s cap fired MID-TURN on a big file and dropped into an UNREPAIRED fallback, so a
# leaked tool-call envelope reached OpenCode as plain text (the cart.html incident, 2026-06-21).
# 1800s gives generous headroom; override via env if a single turn legitimately needs longer.
#
# #1519 -- ITS RELATIONSHIP TO THE CLIENT'S IDLE BOUND, which is the thing to understand before
# changing either. The ACP idle breaker kills a candidate at 600s (configs/fleet-driver.json
# acp.idle_sec; BlarAI shared/timeout_registry.py ACP_IDLE_TIMEOUT_S). This value is three times
# that, and for a long time the gap was silently harmful: the buffered path sat blocked in a
# synchronous read, never learned its client had gone, and OVMS kept generating for a client that
# no longer existed -- holding the scheduler slot and starving every candidate behind it. 38
# requests ran the full 1800s on 2026-09-02 alone.
#
# The gap is no longer harmful ON THE BUFFERED PATH, and LOWERING THIS IS NOT THE FIX.
# _upstream_cancellable detects a departed client and aborts within about one poll interval.
#
# THE STREAMING PATH IS NOT THE SAME, and an earlier version of this comment claimed it was
# ("within about one poll interval, whichever path is in use"). That path only notices a
# departed client when a chunk WRITE fails, so it needs a token to write first. Measured: with
# upstream silent, a client that left at t=2.0s still had its slot held for the full 25s of the
# probe. In practice a streaming generation emits tokens continuously, so the write fails
# quickly -- but a silent or stalled upstream is exactly when it does not, and that is the case
# worth knowing about rather than papering over.
#
# So the 1800s ceiling applies while a client is still waiting, which is when a long generation
# is legitimate: a streaming client sees tokens, so its idle timer never fires, and cutting it
# to the breaker's 600s would kill work someone is still reading.
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
# #1519 emergency lever for the client-disconnect cancellation. Default ON: without it a killed
# candidate keeps generating on the model server and starves everything behind it, which cost
# the fleet three days. Set to 0 only if a client is ever found to half-close after sending its
# request -- see _peer_gone -- since cancellation would then abort live work. Off reinstates the
# starvation, so it buys time to fix a client, nothing more.
_CANCEL_OFF = ("0", "false", "no", "off", "disabled", "none", "n", "f")
_CANCEL_ON = ("1", "true", "yes", "on", "enabled", "y", "t", "")
_cancel_raw = os.environ.get("PROXY_CANCEL_ON_DISCONNECT", "1").strip().lower()
# CASE-INSENSITIVE, AND A WIDER SET THAN THE THREE THAT HAPPENED TO BE TESTED. The first
# version matched exactly ("0", "false", "no"), so off / Off / OFF / False / disabled were
# all silently IGNORED and cancellation stayed on. That fires in precisely the situation the
# lever exists for: a client starts half-closing, live work dies, someone reaches for the
# documented switch, types the word almost everyone types first, sees a normal startup, and
# the destruction continues. A control that degrades silently is worse than none.
if _cancel_raw in _CANCEL_OFF:
    CANCEL_ON_DISCONNECT = False
elif _cancel_raw in _CANCEL_ON:
    CANCEL_ON_DISCONNECT = True
else:
    # Refuse to guess. Defaulting ON is the safer of the two -- off reinstates the #1519
    # starvation for every candidate -- but it is announced, because the whole failure above
    # was a value that did nothing without saying so.
    CANCEL_ON_DISCONNECT = True
    print(f"WARNING: PROXY_CANCEL_ON_DISCONNECT={_cancel_raw!r} is not a value I recognise; "
          f"client-disconnect cancellation stays ON. Use one of {_CANCEL_OFF} to switch it off.",
          file=sys.stderr, flush=True)
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



class _ClientGone(Exception):
    """The requesting client disconnected before upstream answered."""


def _peer_gone(conn):
    """True when the client's socket is at EOF. Never raises.

    select() says "readable"; MSG_PEEK then separates EOF (recv returns 0 bytes) from a client
    that has genuinely sent something. A socket at EOF reports readable forever, which is the
    signal we want and the reason polling is cheap.

    A SECOND LIMITATION, IN THE LENIENT DIRECTION. select() reports readable for unread DATA
    as well as for EOF, and the MSG_PEEK check then returns False. So a client that pipelines
    anything after its request leaves a byte sitting in the receive buffer and disables
    detection for that request permanently -- measured to hold for the full UPSTREAM_TIMEOUT.
    Nothing complains when this fires, because failing to cancel looks exactly like a healthy
    long generation. Incidence is believed zero (undici does not pipeline) and it fails SAFE,
    which is why it is documented rather than coded around: the cost is one orphaned
    generation, where the strict direction below costs live work.

    KNOWN LIMITATION, MEASURED. EOF means "the client will send nothing more" -- it does NOT
    mean the client has gone. A client that calls shutdown(SHUT_WR) after its request is doing
    something legal and is still waiting for the answer, and TCP gives us no way to tell the
    two apart without writing to the socket, which we cannot do before the response exists.
    Driven against the real proxy:

        full-close   aborted=True   answer_delivered=False   (correct)
        half-close   aborted=True   answer_delivered=False   (WRONG -- work destroyed)
        stay-open    aborted=False  answer_delivered=True    (correct)

    It is theoretical for THIS fleet rather than merely assumed to be: the real client is
    node/undici via opencode, and it was measured not to half-close -- a server withholding the
    response for 6s saw no EOF at all, and the answer was delivered. The risk is that this is a
    THIRD PARTY's behaviour and could change under us, so PROXY_CANCEL_ON_DISCONNECT=0 turns
    cancellation off without a code change. Turning it off reinstates the #1519 starvation, so
    it is an emergency lever, not a tuning knob.
    """
    try:
        r, _, _ = select.select([conn], [], [], 0)
        if not r:
            return False
        return len(conn.recv(1, socket.MSG_PEEK)) == 0
    except OSError:
        return True          # an unusable socket is, for our purposes, a departed client


# poll=2.0s is a deliberate choice, not a default left where it fell. What it buys is detection
# latency: measured end to end, the client closed at 3.3s and upstream saw the disconnect at
# 4.4s, so the slot comes back about one interval after the client goes. What it costs is one
# select() with a zero timeout per interval per in-flight request -- negligible even across a
# forty-minute generation. It does NOT affect the false-positive surface, because EOF is
# persistent once seen, so polling faster would not make _peer_gone any more wrong. Anything
# from 1s to 10s is defensible against a 600s idle bound; what is NOT defensible is a value
# near UPSTREAM_TIMEOUT or near any other timer it could race -- that is exactly the mistake
# that made test_client_leaving_mid_generation_is_REPORTED pass alone and fail under load.
def _upstream_cancellable(path, method, headers, body, gone, poll=2.0):
    """_upstream, abandoned the moment the requesting client goes away.

    THE DEFECT THIS CLOSES (#1519). UPSTREAM_TIMEOUT is 1800s while the ACP idle breaker kills a
    candidate at 600s. The handler sat blocked in a synchronous read and never learned its client
    had left, so OVMS still believed someone was waiting and kept generating for up to another
    twenty minutes -- holding the single scheduler slot and starving every candidate behind it.
    Each kill made the next attempt more likely to be killed. Measured 2026-09-02: 38 requests ran
    the full 1800s, and the fleet lost candidates to this for three days while the server itself
    was healthy.

    WHY NOT urlopen, WHICH IS WHAT THE FIRST VERSION USED AND WHY IT DID NOT WORK. urlopen does
    not return until the response HEADERS arrive, and for stream:false OVMS sends nothing at all
    until the generation is finished. Measured on the live server, 2026-09-02 16:56:

        300 tokens   first byte 38.686290s   complete 38.686546s   (gap 0.26 ms)
          4 tokens   first byte  1.873875s   complete  1.874190s   (gap 0.32 ms)
        response framing: content-length, not chunked

    So there was no response object to abort for the ENTIRE generation -- exactly the window that
    matters -- and the first version's abort could only ever fire in the streaming shape, which
    does not take this path. Owning the connection removes that window rather than narrowing it:
    HTTPConnection exists BEFORE the request is sent, so it can be closed at any stage, including
    while still waiting for the first header byte.

    Releasing the slot is what matters, and it works: on 2026-09-02 at 12:40:16, killing an
    orphaned client by hand dropped OVMS's request count from 1 to 0 within about a second. OVMS
    honours the disconnect -- we simply never delivered one.

    A BOUNDED RESIDUAL, MEASURED RATHER THAN ASSUMED (#1521). The abort sends a FIN, which is
    what releases the model -- upstream sees the disconnect about a second later, measured. But
    the worker's own recv stays blocked on Windows despite the shutdown, so ONE thread and its
    socket linger until UPSTREAM_TIMEOUT. Driven at 25 aborts against a blackhole upstream:

        UPSTREAM_TIMEOUT=1800   threads 4 -> 29, tcp 1 -> 51, no settle in 30s
        UPSTREAM_TIMEOUT=20     threads 4 -> 11 -> 4, tcp 1 -> 17 -> 11  (clears at the timeout)

    So it is self-limiting at one timeout's worth of aborts rather than unbounded, and it is
    identical in the previous urlopen implementation (threads 4 -> 30), so this rewrite neither
    caused nor cured it. Review and I both predicted that owning the connection would cure it;
    the measurement says otherwise, which is why it is written down here instead of believed.
    Waking the worker promptly needs a cooperative read loop with a short socket timeout --
    a restructure with its own risks, and #1521 rather than a same-change patch.

    `gone` is injected rather than read from self.connection so the tests can drive every branch
    without sockets. Returns _upstream's (status, headers, body); raises _ClientGone if the client
    left first.
    """
    parsed = urllib.parse.urlsplit(OVMS)
    conn = http.client.HTTPConnection(parsed.hostname, parsed.port or 80, timeout=UPSTREAM_TIMEOUT)
    holder = {}
    done = threading.Event()

    def work():
        try:
            hdrs = {k: v for k, v in headers.items() if k.lower() not in _HOP}
            conn.request(method, path, body=body, headers=hdrs)
            r = conn.getresponse()
            holder["result"] = (r.status, dict(r.getheaders()), r.read())
        except Exception as e:
            # Includes the abort we cause ourselves, which is the point: closing the socket under
            # a blocked getresponse()/read() is how the generation is actually stopped.
            holder["error"] = e
        finally:
            done.set()

    t = threading.Thread(target=work, name="upstream", daemon=True)
    t.start()

    while not done.wait(poll):
        if not gone():
            continue
        what = _abort_connection(conn)
        # Do NOT wait for the worker. Closing the connection above is what actually frees the
        # model; the worker is a daemon whose blocked call now fails on the closed socket.
        raise _ClientGone(what)

    if "error" in holder:
        raise holder["error"]
    return holder["result"]


def _abort_connection(conn):
    """Tear down an in-flight upstream connection from another thread. Best-effort, each step
    independent. RETURNS what actually happened.

    The return value exists because the caller logs the only line anybody will ever see about
    this, and an earlier version printed "aborted the upstream request" unconditionally --
    including, as review demonstrated, 25 times out of 25 while aborting nothing at all. A
    report that cannot distinguish success from failure is not evidence, and this one was
    being cited in the code as "the only evidence that a slot was released".

    Closing the HTTPConnection alone does not reliably wake a thread already blocked inside
    recv(); the socket has to be shut down under it. conn.sock is None until connect() has run,
    which is a real window at the very start of the request, so the shutdown is guarded rather
    than assumed.
    """
    did = []
    sock = getattr(conn, "sock", None)
    if sock is None:
        did.append("no upstream socket yet")
    else:
        try:
            sock.shutdown(socket.SHUT_RDWR)
            did.append("socket shut down")
        except Exception as e:
            did.append("shutdown failed (%s)" % type(e).__name__)
    try:
        conn.close()
        did.append("connection closed")
    except Exception as e:
        did.append("close failed (%s)" % type(e).__name__)
    return "; ".join(did)

def _upstream_stream(path, headers, body):
    """#1495: open an upstream SSE response and hand back the live file object.

    The repair path must buffer -- salvage_tool_calls pattern-matches a COMPLETE content string.
    A request we are NOT repairing has nothing to wait for, and buffering it bought nothing while
    costing latency: measured 2026-08-31, the proxy emitted nothing for 22s then 4 chunks in 0.13s
    where OVMS direct streamed 655 chunks from +1.43s.

    WHO THIS ACTUALLY HELPS, stated precisely because the first version of this docstring cited
    the coder incident and the code does not reach it. MODEL_FORMATS defaults to
    "coder-30b:qwen3coder", so do_fix is TRUE for coder-30b and the coder still buffers -- its
    version of this problem is open on #1507, not fixed here. What takes this path is every model
    with no registered repair: qwen3-14b (the default in configs/opencode.json and
    configs/fleet-queue.sample.json, so the everyday tier) and the vision model.
    """
    hdrs = {k: v for k, v in headers.items() if k.lower() not in _HOP}
    req = urllib.request.Request(OVMS + path, data=body, headers=hdrs, method="POST")
    return urllib.request.urlopen(req, timeout=UPSTREAM_TIMEOUT)

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
        # The explicit Connection: close is deliberate and load-bearing -- CPython special-cases
        # that header to set close_connection, and every error path here depends on it.
        #
        # TOLERATE A CLIENT THAT HAS ALREADY GONE. The commonest caller is the 504 raised after
        # UPSTREAM_TIMEOUT, and by then the client is usually gone: the ACP idle breaker kills a
        # candidate at 600s while UPSTREAM_TIMEOUT is 1800s, so the reply is written to a socket
        # nobody is holding. Unguarded, that raised ConnectionResetError out of end_headers and
        # printed a full traceback per occurrence -- measured 819, 984 and 1679 lines across three
        # of 2026-09-02's proxy logs, which is how a real signal (38 upstream timeouts that day)
        # ended up buried in stack traces nobody read.
        #
        # There is nothing to report to a departed client, so this is not swallowing an error: it
        # is declining to shout down a hung-up phone. One line, so the COUNT stays visible.
        try:
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError) as e:
            self.close_connection = True
            print(f"CLIENT GONE BEFORE REPLY: status={status} ({type(e).__name__}); "
                  f"nothing delivered", file=sys.stderr, flush=True)

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
        # #1495: force stream:false ONLY when a repair is actually attempted. This used to be
        # unconditional -- even for models with no fix registered -- so EVERY request was buffered
        # and every generation longer than the client's 600s idle bound was killed while the model
        # was working perfectly. The repair genuinely needs the whole response; a passthrough does
        # not, and paying the repair's cost without doing the repair is pure loss.
        # #1507: coder-30b (do_fix=True) forced stream:false upstream and sent nothing to the
        # client until the ENTIRE generation and repair were done -- regardless of what the
        # client asked for. OpenCode's own idle watchdog only resets on real ACP session/update
        # events, which only fire when the client sees genuine stream activity, so any coder
        # turn over ~600s was killed while the model was working correctly. Measured live
        # 2026-09-03: an entire nightly battery (5/5 tasks) lost to exactly this.
        #
        # THE FIX DOES NOT TOUCH REPAIR CORRECTNESS. It separates "stream to the client" from
        # "buffer for repair": request stream:true from OVMS (it supports this natively -- the
        # buffering was a proxy choice, not an OVMS limitation), accumulate the real content
        # server-side exactly as before, and run the SAME _fix_response untouched once the
        # upstream stream ends. The only change is the wire stays alive during the wait instead
        # of silent -- via a genuine reasoning_content SSE delta sent once per upstream chunk
        # received, which the real opencode.exe + acp_coder.py driver reads as its own "thought"
        # liveness signal (agent_thought_chunk) WITHOUT it ever becoming part of the stored
        # answer. Two other shapes were tried and measured wrong end to end before this one (see
        # the liveness-frame comment inside the relay loop below for the full measurement): a
        # bare SSE comment or an empty delta resets nothing (opencode's stream parser reacts only
        # to real data: content, and an empty one carries none), and a plain content delta DOES
        # reset the idle clock but gets concatenated into the real answer, corrupting it.
        #
        # BUILT ON #1519, NOT AROUND IT. #1519's own docstring warns that a streaming relay only
        # notices a departed client when it has a chunk to WRITE -- during a silent/stalled
        # upstream there is nothing to write, so a naive streaming rewrite would silently
        # reintroduce the exact starvation #1519 exists to prevent. So this reuses #1519's
        # poll-and-abort primitive directly (_peer_gone + _abort_connection) in TWO phases:
        # phase 1 covers connecting and waiting for upstream's response headers (the previous
        # buffered path's own abort window), phase 2 covers the relay loop itself. Either phase
        # aborts the SAME way #1519 already proved: shut down the socket out from under the
        # worker thread's blocked read.
        if do_fix and wants_stream:
            if stream_opts is not None:
                req["stream_options"] = stream_opts   # restore: only stripped for the old buffer
            req["stream"] = True

            parsed = urllib.parse.urlsplit(OVMS)
            conn = http.client.HTTPConnection(parsed.hostname, parsed.port or 80, timeout=UPSTREAM_TIMEOUT)
            gone = (lambda: _peer_gone(self.connection)) if CANCEL_ON_DISCONNECT else (lambda: False)
            poll = 2.0

            # Phase 1: connect and obtain upstream's response headers. Abortable for the same
            # reason #1519 made the buffered path's connect abortable -- a wedged/stalled OVMS
            # can hang here just as easily as mid-body.
            resp_holder: dict = {}
            resp_ready = threading.Event()

            def _connect():
                try:
                    hdrs = {k: v for k, v in dict(self.headers).items() if k.lower() not in _HOP}
                    conn.request("POST", "/v3/chat/completions", body=json.dumps(req).encode(), headers=hdrs)
                    resp_holder["response"] = conn.getresponse()
                except Exception as e:
                    resp_holder["error"] = e
                finally:
                    resp_ready.set()

            threading.Thread(target=_connect, name="upstream-connect", daemon=True).start()

            while not resp_ready.wait(poll):
                if gone():
                    what = _abort_connection(conn)
                    print("CLIENT GONE MID-GENERATION: %s" % what, file=sys.stderr, flush=True)
                    self.close_connection = True
                    return

            if "error" in resp_holder:
                e = resp_holder["error"]
                return self._send(504, json.dumps({"error": {"message":
                    f"proxy: upstream did not respond within {UPSTREAM_TIMEOUT}s ({e}). The turn may "
                    "be too large or the model overloaded -- retry, or /compact to shrink the context."}}).encode())

            r = resp_holder["response"]

            # Commit to a streaming response. Same chunked-framing rationale as the passthrough
            # path below: truncation must be a protocol error the client cannot ignore.
            self.send_response(r.status)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache")
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()

            # Shared because two threads write frames now (review finding #2): the relay
            # worker pings once per upstream chunk it receives, and the main thread below
            # ALSO pings on its own timer so a gap BEFORE the first chunk -- prefill, or a
            # mid-generation stall -- is not silent just because the worker has nothing to
            # relay yet. Unsynchronized interleaved writes to the same socket would corrupt
            # the chunked framing.
            wfile_lock = threading.Lock()

            def _chunk(payload: bytes) -> None:
                with wfile_lock:
                    self.wfile.write(b"%x\r\n" % len(payload) + payload + b"\r\n")
                    self.wfile.flush()

            def _ping() -> None:
                ping = {"id": state["id"] or "chatcmpl-proxy", "object": "chat.completion.chunk",
                        "created": int(time.time()), "model": req.get("model", ""),
                        "choices": [{"index": 0, "delta": {"reasoning_content": " "}, "finish_reason": None}]}
                _chunk(b"data: " + json.dumps(ping).encode() + b"\n\n")

            acc: dict = {}   # choice index -> {"content": [str], "tool_calls": {idx: slot}, "finish": str}

            def _choice(idx: int) -> dict:
                return acc.setdefault(idx, {"content": [], "tool_calls": {}, "finish": "stop"})

            state = {"id": None, "usage": None,
                     "saw_end": False, "failed": "", "client_gone": False}

            # Phase 2: relay + accumulate. Runs on a worker thread so the main thread can keep
            # polling `gone()` even while blocked reading the next upstream line -- the exact
            # gap #1519's docstring names as the streaming path's weakness if left unaddressed.
            relay_done = threading.Event()

            def _relay():
                try:
                    for line in r:
                        _s = line.strip()
                        if not _s.startswith(b"data:"):
                            continue
                        payload = _s[5:].strip()
                        if payload == b"[DONE]":
                            state["saw_end"] = True
                            continue
                        try:
                            ev = json.loads(payload)
                        except Exception as exc:
                            # FAIL-LOUD (review finding #1; the same doctrine _fix_response's
                            # own SEVERANCE guard states explicitly: an unreconstructable
                            # signal must never ship silently). A chunk that cannot be parsed
                            # is a piece of the answer we cannot account for -- treating it as
                            # "nothing happened" would let a partial answer ship as a
                            # confident, complete-looking 200. Stop and report incomplete,
                            # exactly like an upstream connection failure.
                            state["failed"] = f"unparseable upstream chunk: {type(exc).__name__}: {exc}"
                            break
                        if ev.get("id"):
                            state["id"] = ev["id"]
                        if ev.get("usage"):
                            state["usage"] = ev["usage"]
                        for ch in ev.get("choices", []):
                            slot = _choice(ch.get("index", 0))
                            delta = ch.get("delta") or {}
                            if delta.get("content"):
                                slot["content"].append(delta["content"])
                            for tc in delta.get("tool_calls") or []:
                                tcidx = tc.get("index", 0)
                                tcs = slot["tool_calls"].setdefault(
                                    tcidx, {"id": None, "name": "", "args": []})
                                if tc.get("id"):
                                    tcs["id"] = tc["id"]
                                fn = tc.get("function") or {}
                                if fn.get("name"):
                                    tcs["name"] += fn["name"]      # accumulate, mirroring args --
                                if fn.get("arguments"):             # a provider MAY fragment it too
                                    tcs["args"].append(fn["arguments"])
                            if ch.get("finish_reason"):
                                slot["finish"] = ch["finish_reason"]
                        # THE LIVENESS FRAME. reasoning_content, NOT content and NOT an empty
                        # delta -- both were tried and measured wrong, end to end, against the
                        # REAL opencode.exe + acp_coder.py driver (not just this proxy in
                        # isolation):
                        #   delta:{}                    -> opencode emits NOTHING at all;
                        #                                   acp_coder's idle timer never resets
                        #                                   (TimedOut=true at the idle bound,
                        #                                   confirmed at 6.0s against --idle-sec 4)
                        #   delta:{"content":" "}        -> DOES reset the idle timer, but every
                        #                                   ping shares the real answer's
                        #                                   messageId and opencode concatenates
                        #                                   them -- the stored message becomes
                        #                                   N leading placeholder characters
                        #                                   glued onto the real content, which
                        #                                   then re-enters history on every
                        #                                   later turn via xmlify_history
                        #   delta:{"reasoning_content":" "} -> resets the idle timer AND arrives
                        #                                   as its own ACP event
                        #                                   (agent_thought_chunk, a distinct
                        #                                   sessionUpdate type acp_coder.py
                        #                                   already treats as a liveness-only
                        #                                   signal) -- the real answer still
                        #                                   arrives as exactly one clean
                        #                                   agent_message_chunk, byte-identical
                        #                                   to what the old buffered path sent
                        # Verified 2026-09-03: a fake OVMS streaming 28 words over ~11s through
                        # this exact proxy, into the real opencode.exe + acp_coder.py with
                        # --idle-sec 4, completed with TimedOut=false and a message log carrying
                        # 30 agent_thought_chunk events plus exactly one unpolluted
                        # agent_message_chunk. Full transcript on ticket #1507.
                        #
                        # One ping per upstream chunk received, deliberately unthrottled: real
                        # generations tick roughly once per token (measured live, ~1/s), far more
                        # often than needed against a 600s bound. This alone only covers gaps
                        # BETWEEN chunks the worker actually sees -- the main thread's own timer
                        # below covers the gap before the FIRST one (review finding #2).
                        try:
                            _ping()
                        except Exception:
                            state["client_gone"] = True
                            break
                    if not state["saw_end"] and not state["client_gone"]:
                        state["failed"] = "upstream closed before sending [DONE]"
                except Exception as exc:
                    state["failed"] = f"{type(exc).__name__}: {exc}"
                finally:
                    relay_done.set()

            threading.Thread(target=_relay, name="upstream-relay", daemon=True).start()

            # KNOWN RESIDUAL (#1521, second instance): on abort this returns without joining
            # _relay's thread. _abort_connection frees the model server promptly (the FIN is
            # what matters), but on Windows the worker's own blocked read does not always wake
            # on the shutdown -- the same limitation #1521 already names and measures for
            # _upstream_cancellable, now also here. Bounded by UPSTREAM_TIMEOUT, self-clearing,
            # not fixed separately -- see #1521 for why and what closing it looks like.
            aborted = False
            while not relay_done.wait(poll):
                if gone():
                    aborted = True
                    what = _abort_connection(conn)
                    print("CLIENT GONE MID-GENERATION: %s" % what, file=sys.stderr, flush=True)
                    break
                # Review finding #2: the worker above only pings AFTER it has an upstream
                # chunk in hand, so a gap before the first one -- prefill on a large prompt,
                # or upstream pausing mid-generation -- was silent for exactly as long as
                # upstream was, the same failure this fix exists to close. This timer pings
                # independently of the worker, every `poll` seconds, so no gap can exceed it
                # regardless of what upstream is doing.
                try:
                    _ping()
                except Exception:
                    aborted = True
                    what = _abort_connection(conn)
                    print("CLIENT GONE MID-GENERATION: %s" % what, file=sys.stderr, flush=True)
                    break

            if aborted or state["client_gone"]:
                self.close_connection = True
                return

            if state["failed"]:
                try:
                    print(f"qwen-proxy: UPSTREAM FAILED mid-stream: {state['failed']}",
                          file=sys.stderr, flush=True)
                    err = json.dumps({"error": {"message":
                        f"proxy: upstream stopped mid-stream ({state['failed']}). The answer above "
                        f"is INCOMPLETE."}})
                    _chunk(b"data: " + err.encode() + b"\n\n")
                except Exception:
                    pass
                self.close_connection = True
                return

            # The full text is in hand -- run the SAME repair logic the buffered path uses,
            # byte-for-byte unchanged, then deliver the real answer as the terminal frames.
            # Built per CHOICE INDEX (review finding #4): a naive single accumulator splices
            # an n>1 completion's separate candidates into one corrupted answer. This proxy's
            # only production caller never sends n>1 (best-of-N here is separate processes,
            # not multi-choice completions), but the module docstring advertises it as a
            # generic OpenAI-compatible proxy for any client, so it must not silently assume
            # n=1.
            choices_out = []
            for idx in sorted(acc):
                slot = acc[idx]
                message = {"role": "assistant", "content": "".join(slot["content"])}
                if slot["tool_calls"]:
                    message["tool_calls"] = [{
                        "id": tcs["id"] or f"call_{idx}_{tcidx}", "type": "function",
                        "function": {"name": tcs["name"], "arguments": "".join(tcs["args"])},
                    } for tcidx, tcs in sorted(slot["tool_calls"].items())]
                choices_out.append({"index": idx, "message": message, "finish_reason": slot["finish"]})
            if not choices_out:
                choices_out = [{"index": 0, "message": {"role": "assistant", "content": ""},
                                "finish_reason": "stop"}]
            full_obj = {
                "id": state["id"] or "chatcmpl-proxy", "object": "chat.completion",
                "created": int(time.time()), "model": req.get("model", ""),
                "choices": choices_out,
            }
            if state["usage"]:
                full_obj["usage"] = state["usage"]
            full_obj = _fix_response(full_obj)
            try:
                _chunk(_sse(full_obj, want_usage))
                with wfile_lock:
                    self.wfile.write(b"0\r\n\r\n")
                    self.wfile.flush()
            except Exception:
                pass
            try:
                conn.close()
            except Exception:
                pass
            self.close_connection = True
            return

        if not do_fix and wants_stream:
            if stream_opts is not None:
                req["stream_options"] = stream_opts   # restore: we only stripped it to buffer
            req["stream"] = True
            try:
                up = _upstream_stream("/v3/chat/completions", dict(self.headers), json.dumps(req).encode())
            except Exception as e:
                return self._send(504, json.dumps({"error": {"message":
                    f"proxy: upstream did not respond within {UPSTREAM_TIMEOUT}s ({e})."}}).encode())
            # CHUNKED, and the framing is the error detector -- this is not a style choice.
            #
            # With no framing header at all (the first version of this) protocol_version is
            # HTTP/1.1, so the socket stays open for a next request that never comes and the
            # client hangs at the END of the generation: the same idle breaker fires, just later.
            # With Connection: close, a truncated stream and a complete one are BYTE-IDENTICAL at
            # the transport layer -- EOF is the legitimate terminator, so "upstream died" and
            # "generation finished" become the same event. Measured, undici and http.client:
            #     close-ok   frames=5 DONE=true  -> CLEAN END
            #     close-cut  frames=2 DONE=false -> CLEAN END      <- indistinguishable
            #     chunked-ok  frames=5 DONE=true  -> CLEAN END
            #     chunked-cut frames=2 DONE=false -> TRANSPORT ERROR ("terminated")
            # So chunked gives truncation-detection away for free, from the framing, in a form no
            # client can ignore. The one way to get it wrong is failing to write the terminating
            # 0-length chunk -- and on the error path that is exactly the behaviour wanted, so the
            # mistake and the requirement coincide. BaseHTTPRequestHandler does NOT chunk for us.
            self.send_response(up.status)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache")
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()

            def _chunk(payload: bytes) -> None:
                self.wfile.write(b"%x\r\n" % len(payload) + payload + b"\r\n")
                self.wfile.flush()

            upstream_failed = ""
            saw_stream_end = False
            client_gone = False
            try:
                # Relay line by line and FLUSH each one. Buffering here would recreate the very
                # defect this path exists to remove.
                for line in up:
                    # MATCH THE SENTINEL LINE, NOT ITS CONTENT. `startswith(b"data:")` looks like a
                    # constraint and is not one -- EVERY SSE content frame is a data: line -- so
                    # `b"[DONE]" in line` fired on any model output containing that literal. A coding
                    # model writing "- build the wheel ... [DONE]" in a checklist set the sentinel,
                    # and upstream could then die with the clean terminator written over a truncated
                    # answer: the defect this path exists to remove, reintroduced through its own
                    # detector, silencing BOTH signals at once because both hang off saw_done.
                    # NAMED FOR WHAT IT MEANS. OVMS emits `data: [DONE]` from handleGenerationError too
                    # (http_llm_calculator.cc:101), so this flag says "upstream ENDED the SSE stream", NOT
                    # "the generation succeeded". That is exactly the question this detector must ask -- a
                    # relayed error event is still a complete transfer -- but `saw_done` read as success.
                    _s = line.strip()
                    if _s.startswith(b"data:") and _s[5:].strip() == b"[DONE]":
                        saw_stream_end = True
                    try:
                        _chunk(line)
                    except Exception:
                        # OUR write failed => the CLIENT is gone. Nothing to report and nobody to
                        # report it to. Distinguished by WHICH side raised, not by inspecting the
                        # socket: self.wfile is a socketserver._SocketWriter whose .closed comes from
                        # io.IOBase and is only True after an explicit .close(), so a broken pipe
                        # leaves it False -- measured. A closed-check here is dead code that would
                        # classify every client hangup as an upstream death.
                        client_gone = True
                        print("qwen-proxy: CLIENT DISCONNECTED mid-stream; relay stopped",
                              file=sys.stderr, flush=True)
                        break
                # ITERATION ENDING IS NOT PROOF OF COMPLETION. Measured: when upstream drops a
                # chunked body mid-stream, iterating the urllib response simply STOPS -- no
                # exception -- so relying on the except below would write a clean terminator over
                # a truncated answer, which is the exact defect being fixed. The SSE sentinel is
                # what actually distinguishes "generation finished" from "upstream vanished".
                if not saw_stream_end and not client_gone:
                    upstream_failed = "upstream closed before sending [DONE]"
            except Exception as exc:
                # Reaching HERE means the UPSTREAM iterator raised: a client-side write failure is
                # caught at its own try above and sets client_gone instead. That is the real
                # discriminator -- which side raised -- rather than asking the socket, which cannot
                # answer (see the note on _SocketWriter.closed above).
                upstream_failed = f"{type(exc).__name__}: {exc}"
            finally:
                try: up.close()
                except Exception: pass

            try:
                if upstream_failed:
                    # TWO independent signals, deliberately. The error frame reaches a reader that
                    # parses SSE; omitting the terminator makes it a transport error for one that
                    # does not. Neither alone is enough -- a client is not obliged to check either.
                    print(f"qwen-proxy: UPSTREAM FAILED mid-stream: {upstream_failed}",
                          file=sys.stderr, flush=True)
                    err = json.dumps({"error": {"message":
                        f"proxy: upstream stopped mid-stream ({upstream_failed}). The answer above "
                        f"is INCOMPLETE."}})
                    _chunk(b"data: " + err.encode() + b"\n\n")
                    # NO terminating chunk: the client must see this as a broken transfer.
                else:
                    self.wfile.write(b"0\r\n\r\n")   # clean end of a complete stream
                    self.wfile.flush()
            except Exception:
                pass  # the client is gone; there is no one left to inform
            self.close_connection = True
            return
        req["stream"] = False  # repair path only: full response upstream so we can repair/re-emit

        # Call upstream. A timeout/connection failure here must NOT fall back to an UNREPAIRED
        # passthrough of the original request -- that is exactly how a leaked tool-call envelope
        # reached OpenCode as plain text. Return an explicit error so the client can retry.
        try:
            # #1519 CANCELLABLE. This is the BUFFERED path -- the repair needs a complete
            # response, so nothing reaches the client until upstream finishes, and a client
            # that leaves mid-generation used to be invisible here for up to 1800s while OVMS
            # kept generating for it and starved every candidate behind it.
            status, _h, body = _upstream_cancellable(
                "/v3/chat/completions", "POST", dict(self.headers), json.dumps(req).encode(),
                gone=(lambda: _peer_gone(self.connection)) if CANCEL_ON_DISCONNECT
                     else (lambda: False))
        except _ClientGone as gone_exc:
            # Nothing to send and no one to send it to. This line is the only trace anybody
            # will see, so it states what was DONE rather than asserting a result -- review
            # found the previous wording claiming the slot was released 25 times out of 25
            # while nothing had been aborted at all.
            print("CLIENT GONE MID-GENERATION: %s" % (gone_exc or "nothing to abort"),
                  file=sys.stderr, flush=True)
            self.close_connection = True
            return
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
    # flush=True on every banner line. Python block-buffers stdout when it is not a terminal, and
    # this proxy is ALWAYS started with its output redirected to a log -- so without the flush the
    # banner sat in a buffer and was lost entirely if the process was stopped before it filled.
    # A startup banner that only appears when nobody is reading it is not a banner.
    print(f"qwen-proxy: http://127.0.0.1:{PORT}  ->  {OVMS}   (xmlify + salvage + marker-strip)",
          flush=True)
    print(f"Point your client baseURL at: http://127.0.0.1:{PORT}/v3", flush=True)
    # Print the RESOLVED mode, not the raw value. The lever's whole failure mode is being set to
    # something that does nothing, and until this line there was no way to tell from the outside
    # which way it had landed -- the banner looked identical either way.
    print(f"client-disconnect cancellation: "
          f"{'ON' if CANCEL_ON_DISCONNECT else 'OFF (upstream generations will NOT be aborted)'}"
          f"   [PROXY_CANCEL_ON_DISCONNECT={_cancel_raw!r}]", flush=True)
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
