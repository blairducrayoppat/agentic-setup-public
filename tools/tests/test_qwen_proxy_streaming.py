"""#1507 — the passthrough streaming path of tools/qwen-proxy.py.

THE DEFECT THESE LOCK. The proxy forced ``stream=False`` on every request so it could repair
Qwen3-Coder's tool-call format. For a model with no registered repair that bought nothing and
cost the whole generation's latency. The first attempt at streaming through sent a 200 with no
body framing at all under HTTP/1.1 keep-alive, so the client hung at the END of the generation
instead of the start — the same idle breaker, later — and it caught upstream death in the same
handler as client hangup, delivering a truncated answer as a successful one.

WHY CHUNKED AND NOT ``Connection: close``. Measured with undici and http.client: under
``Connection: close`` a truncated stream and a complete stream are byte-identical at the
transport layer, because EOF is the legitimate terminator — so "upstream died" and "generation
finished" are the same event. Under chunked, truncation is a protocol error the client cannot
ignore. These tests assert exactly that difference: a cut stream must NOT read as a clean one.

Drives a REAL proxy process against a REAL fake upstream over loopback on ephemeral ports.
Never touches the live proxy on 8099; never needs OVMS.

  <blarai>/.venv/Scripts/python -m pytest tools/tests/test_qwen_proxy_streaming.py
"""

from __future__ import annotations

import http.client
import json
import os
import select
import socket
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import pytest

_TOOLS = Path(__file__).resolve().parents[1]
_PROXY = _TOOLS / "qwen-proxy.py"

CRLF = b"\r\n"


def _free_port() -> int:
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


def _frame(i: int, model: str) -> bytes:
    return b"data: " + json.dumps({
        "id": "chatcmpl-fake", "object": "chat.completion.chunk", "model": model,
        "choices": [{"index": 0, "delta": {"content": f"tok{i}"}, "finish_reason": None}],
    }).encode() + b"\n\n"


def _chunk(payload: bytes) -> bytes:
    return b"%x" % len(payload) + CRLF + payload + CRLF


def _content_frame(text: str, model: str) -> bytes:
    return b"data: " + json.dumps({
        "id": "chatcmpl-fake", "object": "chat.completion.chunk", "model": model,
        "choices": [{"index": 0, "delta": {"content": text}, "finish_reason": None}],
    }).encode() + b"\n\n"


# The exact byte-form locked by tools/test_qwen_toolcall_severance.py: a real leaked tool call
# that salvage_tool_calls reconstructs into name="read" with score_tracker.py in its arguments.
SEVERED_TOOL_CALL = (
    "<tool_call>\n"
    "<function=read>\n"
    "<parameter=filePath>\n"
    "score_tracker.py\n"
    "</parameter>\n"
    "</function>\n"
    "</tool_call>"
)


class _Upstream(BaseHTTPRequestHandler):
    """Streams 5 SSE frames; for model 'cut' it streams 2 and then stops without the terminator.

    Truncation is expressed by returning with close_connection set and no terminating 0-chunk —
    NOT by closing wfile, which makes socketserver raise on its own flush. That would be a
    fixture artefact rather than the failure being modelled.
    """

    protocol_version = "HTTP/1.1"

    def log_message(self, *a):  # keep pytest output clean
        pass

    def _read_body(self) -> dict:
        n = int(self.headers.get("Content-Length", 0) or 0)
        raw = self.rfile.read(n) if n else b""
        try:
            return json.loads(raw.decode() or "{}")
        except Exception:
            return {}

    def do_GET(self):
        body = json.dumps({"data": [{"id": "qwen3-14b"}]}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        model = self._read_body().get("model", "")
        cut = model in ("cut", "donetrap")
        slow = model == "slow"
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        if model == "malformed-chunk":
            # Review finding #1: a chunk that fails to parse must not silently vanish from
            # the answer. "BBB" here must never reach the client, and the transfer must
            # report as incomplete -- not a clean 200 missing a slice of its own content.
            self.wfile.write(_chunk(_content_frame("AAA", model)))
            self.wfile.flush()
            self.wfile.write(_chunk(b"data: {not valid json\n\n"))
            self.wfile.flush()
            time.sleep(0.01)
            self.wfile.write(_chunk(_content_frame("CCC", model)))
            self.wfile.flush()
            self.wfile.write(_chunk(b"data: [DONE]\n\n"))
            self.wfile.write(b"0" + CRLF + CRLF)
            self.wfile.flush()
            self.close_connection = True
            return
        if model == "native-toolcall-split":
            # Review finding #3: `arguments` was already accumulated correctly; `name` was
            # overwritten by each fragment instead of concatenated. A real provider is not
            # expected to fragment a tool call's name, but nothing here should assume it
            # can't -- this proves BOTH fields survive a split the same way.
            frames = [
                {"index": 0, "delta": {"tool_calls": [{"index": 0, "id": "call_1",
                    "function": {"name": "get_"}}]}, "finish_reason": None},
                {"index": 0, "delta": {"tool_calls": [{"index": 0,
                    "function": {"name": "weather", "arguments": '{"city":'}}]}, "finish_reason": None},
                {"index": 0, "delta": {"tool_calls": [{"index": 0,
                    "function": {"arguments": '"nyc"}'}}]}, "finish_reason": "tool_calls"},
            ]
            for f in frames:
                self.wfile.write(_chunk(b"data: " + json.dumps({
                    "id": "chatcmpl-fake", "object": "chat.completion.chunk", "model": model,
                    "choices": [f]}).encode() + b"\n\n"))
                self.wfile.flush()
                time.sleep(0.01)
            self.wfile.write(_chunk(b"data: [DONE]\n\n"))
            self.wfile.write(b"0" + CRLF + CRLF)
            self.wfile.flush()
            self.close_connection = True
            return
        if model == "multi-choice":
            # Review finding #4: choice 0 and choice 1 interleaved must NOT be spliced into
            # one accumulator -- each choice is its own candidate answer.
            pairs = [("Ax", "By"), ("Az", "Bw")]
            for c0, c1 in pairs:
                for idx, text in ((0, c0), (1, c1)):
                    self.wfile.write(_chunk(b"data: " + json.dumps({
                        "id": "chatcmpl-fake", "object": "chat.completion.chunk", "model": model,
                        "choices": [{"index": idx, "delta": {"content": text}, "finish_reason": None}],
                    }).encode() + b"\n\n"))
                    self.wfile.flush()
                    time.sleep(0.01)
            for idx in (0, 1):
                self.wfile.write(_chunk(b"data: " + json.dumps({
                    "id": "chatcmpl-fake", "object": "chat.completion.chunk", "model": model,
                    "choices": [{"index": idx, "delta": {}, "finish_reason": "stop"}],
                }).encode() + b"\n\n"))
                self.wfile.flush()
            self.wfile.write(_chunk(b"data: [DONE]\n\n"))
            self.wfile.write(b"0" + CRLF + CRLF)
            self.wfile.flush()
            self.close_connection = True
            return
        if model == "leaky":
            # #1507: the leaked tool call arrives the way a real generation delivers it — one
            # small piece at a time, never as a single frame — so the accumulate-then-repair
            # path is proven against a realistic split, not a convenient one.
            pieces = [SEVERED_TOOL_CALL[i:i + 9] for i in range(0, len(SEVERED_TOOL_CALL), 9)]
            for piece in pieces:
                self.wfile.write(_chunk(_content_frame(piece, model)))
                self.wfile.flush()
                time.sleep(0.01)
            self.wfile.write(_chunk(b"data: [DONE]\n\n"))
            self.wfile.write(b"0" + CRLF + CRLF)
            self.wfile.flush()
            self.close_connection = True
            return
        n = 2 if cut else (2 if model == "short" else (40 if slow else (15 if model == "coder-slow" else 5)))
        for i in range(n):
            if model == "donetrap" and i == 1:
                # A CONTENT frame that merely CONTAINS the sentinel text — the sort of thing a
                # coding model writes in a checklist. It is a `data:` line like every other content
                # frame, so a detector matching on containment is fooled by it. Then upstream dies.
                self.wfile.write(_chunk(
                    b"data: " + json.dumps({
                        "id": "chatcmpl-fake", "object": "chat.completion.chunk", "model": model,
                        "choices": [{"index": 0, "delta": {
                            "content": "  - build the wheel ... [DONE]"}, "finish_reason": None}],
                    }).encode() + b"\n\n"))
                self.wfile.flush()
                time.sleep(0.01)
                continue
            self.wfile.write(_chunk(_frame(i, model)))
            self.wfile.flush()
            time.sleep(0.25 if slow else (0.2 if model == "coder-slow" else 0.01))
        if cut:
            # Stop here: no [DONE], no terminating chunk, and drop the connection on return.
            self.close_connection = True
            return
        self.wfile.write(_chunk(b"data: [DONE]\n\n"))
        self.wfile.write(b"0" + CRLF + CRLF)
        self.wfile.flush()
        self.close_connection = True


@pytest.fixture(scope="module")
def proxy_and_log():
    up_port = _free_port()
    srv = ThreadingHTTPServer(("127.0.0.1", up_port), _Upstream)
    threading.Thread(target=srv.serve_forever, daemon=True).start()

    px_port = _free_port()
    env = dict(os.environ)
    env["OVMS_BASE"] = f"http://127.0.0.1:{up_port}"
    env["PROXY_PORT"] = str(px_port)
    # 'qwen3-14b' and 'cut' have NO entry here, so both take the passthrough streaming path.
    # 'leaky' and 'coder-slow' ARE registered (#1507 fixtures below) so they exercise the
    # repair-through-streaming path exactly as coder-30b does in production.
    env["FIX_MODELS"] = ("coder-30b:qwen3coder,leaky:qwen3coder,coder-slow:qwen3coder,"
                          "malformed-chunk:qwen3coder,native-toolcall-split:qwen3coder,"
                          "multi-choice:qwen3coder")
    # stderr to a FILE, not a pipe: the tests read it while the proxy is still running, and a
    # pipe would block. The proxy's stderr is the ONLY place the client-gone / upstream-died
    # discrimination is observable, and an unobservable behaviour cannot be locked -- which is
    # exactly why two mutants reverting it survived an earlier version of this suite.
    err_path = Path(os.environ.get("TEMP", ".")) / f"qwen-proxy-stderr-{px_port}.log"
    err_fh = open(err_path, "wb")
    proc = subprocess.Popen(
        [sys.executable, str(_PROXY)], env=env, cwd=str(_TOOLS),
        stdout=subprocess.DEVNULL, stderr=err_fh,
    )
    for _ in range(100):
        try:
            socket.create_connection(("127.0.0.1", px_port), timeout=0.2).close()
            break
        except OSError:
            time.sleep(0.1)
    else:
        proc.kill()
        srv.shutdown()
        pytest.fail("the proxy under test never bound its port")

    yield px_port, err_path

    proc.terminate()
    try:
        proc.wait(timeout=10)
    except Exception:
        proc.kill()
    srv.shutdown()
    srv.server_close()
    try:
        err_fh.close()
        err_path.unlink()
    except Exception:
        pass


@pytest.fixture(scope="module")
def proxy(proxy_and_log):
    return proxy_and_log[0]


def _post_stream(port: int, model: str, timeout: float = 20.0):
    """POST a streaming completion and read the body. Returns (status, headers, body, err_name)."""
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=timeout)
    conn.request(
        "POST", "/v3/chat/completions",
        body=json.dumps({"model": model, "stream": True,
                         "messages": [{"role": "user", "content": "hi"}]}),
        headers={"Content-Type": "application/json"},
    )
    resp = conn.getresponse()
    hdrs = {k.lower(): v for k, v in resp.getheaders()}
    err, data = "", b""
    try:
        data = resp.read()
    except Exception as exc:
        err = type(exc).__name__
        data = getattr(exc, "partial", b"") or b""
    finally:
        conn.close()
    return resp.status, hdrs, data, err


def test_complete_stream_is_framed_and_reads_cleanly(proxy):
    status, hdrs, data, err = _post_stream(proxy, "qwen3-14b")
    assert status == 200
    assert hdrs.get("transfer-encoding") == "chunked", (
        "the streaming response must be explicitly framed; without it the client hangs at the "
        "END of the generation under HTTP/1.1 keep-alive — the same idle breaker, later"
    )
    assert not err, f"a complete stream must read cleanly, got {err}"
    assert b"[DONE]" in data
    assert data.count(b"data: ") >= 5


def test_a_truncated_stream_is_NOT_readable_as_a_clean_one(proxy):
    """The whole reason for chunked. Under Connection: close this test could not exist —
    a cut stream and a complete one are byte-identical at the transport layer."""
    status, hdrs, data, err = _post_stream(proxy, "cut")
    assert status == 200
    assert err == "IncompleteRead", (
        f"a stream cut mid-generation must surface as a transport error; got err={err!r} with "
        f"{len(data)} bytes. That is the 'truncated answer delivered as a complete one' defect."
    )


def test_the_truncation_also_carries_an_explicit_error_frame(proxy):
    """Two independent signals for one failure: the transport error for a client that does not
    parse SSE, and this frame for one that does. Neither alone obliges the client to notice."""
    _s, _h, data, _e = _post_stream(proxy, "cut")
    assert b"INCOMPLETE" in data.upper(), (
        f"the client should be TOLD the answer is incomplete, not left to infer it; got {data[-300:]!r}"
    )


def test_coder30b_now_streams_through_instead_of_buffering_silently(proxy):
    """#1507: coder-30b HAS a MODEL_FORMATS entry, and used to force the buffered path even when
    the client asked for stream:true -- so nothing reached the client until the ENTIRE generation
    finished, which is exactly what let a >600s turn get killed by the client's own idle watchdog
    while the model was working correctly. It must now take a chunked, live-framed response like
    every other streaming request; correctness of what eventually arrives is proven separately
    below, this only locks the transport shape."""
    status, hdrs, data, err = _post_stream(proxy, "coder-30b")
    assert status == 200
    assert hdrs.get("transfer-encoding") == "chunked", (
        "coder-30b must now stream -- a silent buffered response IS the #1507 defect"
    )
    assert not err
    assert b"[DONE]" in data


# --------------------------------------------------------------------------------------------
# #1507 — the repair-through-streaming path: silence is broken without breaking correctness.


def _sse_content_deltas(data: bytes):
    """Yield the `content` string of every real (non-keepalive) delta frame in an SSE body."""
    for line in data.split(b"\n"):
        s = line.strip()
        if not s.startswith(b"data:"):
            continue
        payload = s[5:].strip()
        if payload == b"[DONE]":
            continue
        try:
            ev = json.loads(payload)
        except Exception:
            continue
        for ch in ev.get("choices", []):
            content = (ch.get("delta") or {}).get("content")
            if content:
                yield content


def test_a_leaked_tool_call_split_across_chunks_is_still_correctly_repaired(proxy):
    """The whole point of accumulating before repair: salvage_tool_calls needs the COMPLETE
    text, and a real generation delivers it a few characters at a time, not as one convenient
    frame. This proves the new streaming-repair path reconstructs the SAME real tool call
    tools/test_qwen_toolcall_severance.py locks for the buffered path, from fragments -- and
    that the raw, still-leaked text never reaches the client along the way."""
    status, hdrs, data, err = _post_stream(proxy, "leaky")
    assert status == 200
    assert not err
    for content in _sse_content_deltas(data):
        assert "<tool_call>" not in content and "<function=" not in content, (
            f"raw/unrepaired leaked text must never reach the client mid-stream: {content!r}"
        )
    assert b'"name": "read"' in data, (
        f"the leaked tool call must be reconstructed into a real tool_calls entry: {data[-500:]!r}"
    )
    assert b"score_tracker.py" in data


def test_plain_content_through_the_new_path_still_arrives_intact(proxy):
    """The counterpart to the leak test: content that needed NO repair must still arrive
    complete and unmangled, not just the corrupted case."""
    status, hdrs, data, err = _post_stream(proxy, "coder-30b")
    assert status == 200
    assert not err
    joined = "".join(_sse_content_deltas(data))
    assert joined == "tok0tok1tok2tok3tok4", f"content must survive accumulation intact: {joined!r}"


def test_the_client_receives_real_activity_before_the_final_answer(proxy):
    """THE ACTUAL FIX. Silence is what got a healthy generation killed -- proves the client sees
    genuine SSE data: frames WHILE the upstream generation is still in progress, not just a
    burst of everything at the very end. Uses 'coder-slow' (15 frames, ~0.2s apart, ~3s total)
    so there is a real window in which a keepalive-but-not-final frame must exist."""
    status, hdrs, data, err = _post_stream(proxy, "coder-slow")
    assert status == 200
    assert not err
    frames = [ln.strip() for ln in data.split(b"\n") if ln.strip().startswith(b"data:")]
    non_done = [f for f in frames if f[5:].strip() != b"[DONE]"]
    assert len(non_done) >= 15, (
        f"expected at least one frame per upstream chunk (15) plus final content frames, got "
        f"{len(non_done)}"
    )
    # At least one frame must be a genuine liveness ping (reasoning_content, carrying no
    # `content` and no `tool_calls`) -- not the final answer. Verified end to end against the
    # real opencode.exe + acp_coder.py driver (ticket #1507): this shape arrives as its own
    # agent_thought_chunk ACP event and resets the idle clock without polluting the stored
    # answer; a bare comment (not even a data: line) and an empty delta were both measured to
    # reset nothing, and a plain `content` delta resets the clock but corrupts the answer.
    pings = 0
    for f in non_done:
        try:
            ev = json.loads(f[5:].strip())
        except Exception:
            continue
        for ch in ev.get("choices", []):
            d = ch.get("delta") or {}
            if d.get("reasoning_content") and not d.get("content") and not d.get("tool_calls"):
                pings += 1
    assert pings >= 5, (
        f"expected multiple genuine liveness frames while upstream was still generating, got "
        f"{pings} across {len(non_done)} frames"
    )


class _LeakyThenDieUpstream(BaseHTTPRequestHandler):
    """Streams two fragments of a leaked tool call, then dies without [DONE] -- the do_fix-path
    analogue of the 'cut' fixture above, which only a passthrough model exercises."""

    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0) or 0)
        if n:
            self.rfile.read(n)
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        for piece in ("<tool_call>", "<function=read>"):
            self.wfile.write(_chunk(_content_frame(piece, "coder-30b")))
            self.wfile.flush()
            time.sleep(0.02)
        self.close_connection = True   # no [DONE]: upstream simply vanished


def test_a_truncated_upstream_through_the_repair_path_is_reported_incomplete():
    up_port = _free_port()
    srv = ThreadingHTTPServer(("127.0.0.1", up_port), _LeakyThenDieUpstream)
    threading.Thread(target=srv.serve_forever, daemon=True).start()

    px_port = _free_port()
    env = dict(os.environ)
    env["OVMS_BASE"] = f"http://127.0.0.1:{up_port}"
    env["PROXY_PORT"] = str(px_port)
    env["FIX_MODELS"] = "coder-30b:qwen3coder"

    proc = subprocess.Popen(
        [sys.executable, str(_PROXY)], env=env, cwd=str(_TOOLS),
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    try:
        for _ in range(100):
            try:
                socket.create_connection(("127.0.0.1", px_port), timeout=0.2).close()
                break
            except OSError:
                time.sleep(0.1)
        else:
            pytest.fail("the proxy under test never bound its port")

        status, hdrs, data, err = _post_stream(px_port, "coder-30b")
        assert status == 200
        assert err == "IncompleteRead", (
            f"an upstream that dies mid-generation through the repair path must surface as a "
            f"transport error, not a clean (and wrong) answer; got err={err!r} data={data[-300:]!r}"
        )
        assert b"INCOMPLETE" in data.upper()
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=10)
        except Exception:
            proc.kill()
        srv.shutdown()
        srv.server_close()


def test_client_disconnect_during_the_new_streaming_repair_path_still_tears_down_upstream():
    """#1519's guarantee, extended: this new path must not reintroduce the starvation #1519
    fixed for the buffered shape. Uses stream:true (this test's whole reason to exist -- every
    #1519 test pins stream:false, which never reaches this branch at all) against a headers-
    early, trickling upstream so the abort has a live connection to actually tear down."""
    report = Path(os.environ.get("TEMP", ".")) / f"streaming-abort-report-{_free_port()}.txt"
    if report.exists():
        report.unlink()

    class _Reporting(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *a):
            pass

        def do_POST(self):
            n = int(self.headers.get("Content-Length", 0) or 0)
            if n:
                self.rfile.read(n)
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            outcome = "COMPLETED"
            try:
                for i in range(600):
                    self.wfile.write(_chunk(_frame(i, "coder-30b")))
                    self.wfile.flush()
                    time.sleep(0.1)
            except Exception:
                outcome = "ABORTED-BY-CLIENT"
            try:
                with open(str(report), "a", encoding="utf-8") as fh:
                    fh.write(outcome + "\n")
            except Exception:
                pass

    up_port = _free_port()
    srv = ThreadingHTTPServer(("127.0.0.1", up_port), _Reporting)
    threading.Thread(target=srv.serve_forever, daemon=True).start()

    px_port = _free_port()
    env = dict(os.environ)
    env["OVMS_BASE"] = f"http://127.0.0.1:{up_port}"
    env["PROXY_PORT"] = str(px_port)
    env["FIX_MODELS"] = "coder-30b:qwen3coder"
    env["UPSTREAM_TIMEOUT"] = "600"   # long: the ABORT must end this, not the timeout

    proc = subprocess.Popen(
        [sys.executable, str(_PROXY)], env=env, cwd=str(_TOOLS),
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    try:
        for _ in range(100):
            try:
                socket.create_connection(("127.0.0.1", px_port), timeout=0.2).close()
                break
            except OSError:
                time.sleep(0.1)
        else:
            pytest.fail("the proxy under test never bound its port")

        body = json.dumps({"model": "coder-30b", "stream": True,
                           "messages": [{"role": "user", "content": "hi"}]}).encode()
        req = (
            b"POST /v3/chat/completions HTTP/1.1" + CRLF
            + b"Host: 127.0.0.1" + CRLF
            + b"Content-Type: application/json" + CRLF
            + b"Content-Length: " + str(len(body)).encode() + CRLF + CRLF
            + body
        )
        s = socket.create_connection(("127.0.0.1", px_port), timeout=5)
        s.sendall(req)
        s.recv(4096)          # block until at least the response headers + first relayed frame
        time.sleep(0.4)
        s.close()             # the candidate is killed, mid-stream

        deadline = time.time() + 40
        seen = ""
        while time.time() < deadline:
            time.sleep(0.5)
            if report.exists():
                seen = report.read_text(errors="replace")
                if seen.strip():
                    break

        assert "ABORTED-BY-CLIENT" in seen, (
            "upstream was NOT torn down when the client left mid-STREAM -- the generation would "
            "keep running and hold the model server's slot, reintroducing #1519. Report: " + repr(seen)
        )
        assert "COMPLETED" not in seen, f"upstream ran to completion despite the client leaving: {seen!r}"
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=10)
        except Exception:
            proc.kill()
        srv.shutdown()
        srv.server_close()
        try:
            report.unlink()
        except Exception:
            pass


def test_content_containing_the_sentinel_does_not_silence_the_detector(proxy):
    """The detector must match the sentinel LINE, not its content.

    Every SSE content frame is a `data:` line, so `startswith(b"data:")` constrains nothing and a
    containment test fires on any model output holding the literal `[DONE]` — a coding model
    writing a build checklist, in the case that found this. Upstream then dies and the clean
    terminator is written over a truncated answer, silencing BOTH signals at once because both
    hang off the same flag. This is the defect reintroduced through its own detector, so it gets
    its own case rather than being folded into the plain truncation test."""
    status, hdrs, data, err = _post_stream(proxy, "donetrap")
    assert status == 200
    assert err == "IncompleteRead", (
        "a stream whose CONTENT merely mentions [DONE] must still be detected as truncated when "
        f"upstream dies; got err={err!r} with {len(data)} bytes"
    )
    assert b"INCOMPLETE" in data.upper(), "and the explicit error frame must still be sent"


def test_a_SHORT_complete_stream_still_reads_as_complete(proxy):
    """Separates the real sentinel from anything keyed to the fixture's shape.

    A detector matching, say, the last content frame's text behaves correctly on a 5-frame stream
    and on a 2-frame truncation — it only diverges on a stream that is COMPLETE but short. Without
    this case, `if b"tok4" in line` passes the whole suite while being obvious nonsense; review
    demonstrated exactly that. A complete generation of any length must terminate cleanly."""
    status, hdrs, data, err = _post_stream(proxy, "short")
    assert status == 200
    assert not err, f"a complete 2-frame stream must read cleanly, got {err}"
    assert b"[DONE]" in data
    assert b"INCOMPLETE" not in data.upper(), "a complete stream must not be reported as truncated"


def test_a_CLIENT_hangup_is_not_reported_as_upstream_death(proxy_and_log):
    """The client-gone / upstream-died discrimination, locked.

    Review reverted this fix two different ways — dropping the `client_gone` guard, and dropping
    the inner try so a client write escapes to the outer handler — and the suite stayed fully
    green both times, because from a departed client's point of view every outcome looks the
    same. An unobservable behaviour cannot be locked. So the proxy now SAYS which side failed,
    and this asserts on that: a client that hangs up mid-stream must be recorded as a client
    hangup and must NOT be recorded as an upstream failure."""
    port, err_path = proxy_and_log
    before = err_path.read_bytes() if err_path.exists() else b""

    # Raw socket so the hangup is abrupt and mid-stream, not a polite close after a full read.
    s = socket.create_connection(("127.0.0.1", port), timeout=20)
    body = json.dumps({"model": "slow", "stream": True,
                       "messages": [{"role": "user", "content": "hi"}]}).encode()
    s.sendall(
        b"POST /v3/chat/completions HTTP/1.1\r\nHost: 127.0.0.1\r\n"
        b"Content-Type: application/json\r\n"
        b"Content-Length: " + str(len(body)).encode() + b"\r\n\r\n" + body
    )
    # THIS recv IS LOAD-BEARING, not a convenience. It blocks until the response headers and
    # the first relayed frame have actually arrived, which guarantees the hangup lands
    # MID-RELAY. Replace it with a bare sleep and the client can vanish before the proxy
    # flushes headers -- end_headers() then raises outside every try in do_POST, no
    # CLIENT DISCONNECTED line is written, and this test fails intermittently for a reason
    # that has nothing to do with the discrimination it is meant to check.
    s.recv(4096)
    time.sleep(0.4)
    s.close()             # vanish mid-stream

    deadline = time.time() + 15
    fresh = b""
    while time.time() < deadline:
        fresh = (err_path.read_bytes() if err_path.exists() else b"")[len(before):]
        if b"CLIENT DISCONNECTED" in fresh or b"UPSTREAM FAILED" in fresh:
            break
        time.sleep(0.2)

    assert b"CLIENT DISCONNECTED" in fresh, (
        f"a client hangup must be recorded as such; proxy stderr said: {fresh[-400:]!r}"
    )
    assert b"UPSTREAM FAILED" not in fresh, (
        "a client hangup must NOT be reported as an upstream failure — that is the "
        f"discrimination under test; proxy stderr said: {fresh[-400:]!r}"
    )


# --------------------------------------------------------------------------------------------
# #1495 — _send must tolerate a client that left before the reply.
#
# THE DEFECT. UPSTREAM_TIMEOUT is 1800s while the ACP idle breaker kills a candidate at 600s, so
# by the time the proxy gives up on OVMS and tries to send its 504 the client is usually gone.
# Unguarded, end_headers() raised ConnectionResetError and printed a full traceback per
# occurrence: 819, 984 and 1679 stderr lines across three of 2026-09-02's live proxy logs. The
# harm was not the crash -- the handler thread was finished anyway -- but that a real signal, 38
# upstream timeouts in a day, was buried in stack traces nobody read.
#
# The assertion that matters is the ABSENCE of a traceback; before the fix this test fails on it.


class _HangingUpstream(BaseHTTPRequestHandler):
    """Accepts the request and never answers, so the proxy must hit UPSTREAM_TIMEOUT."""

    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0) or 0)
        if n:
            self.rfile.read(n)
        time.sleep(60)


def test_client_leaving_mid_generation_is_REPORTED():
    up_port = _free_port()
    srv = ThreadingHTTPServer(("127.0.0.1", up_port), _HangingUpstream)
    threading.Thread(target=srv.serve_forever, daemon=True).start()

    px_port = _free_port()
    env = dict(os.environ)
    env["OVMS_BASE"] = f"http://127.0.0.1:{up_port}"
    env["PROXY_PORT"] = str(px_port)
    env["FIX_MODELS"] = "coder-30b:qwen3coder"
    # 600s, NOT a short value. This case is about what the proxy REPORTS when the client leaves,
    # and setting the upstream timeout anywhere near the 2.0s poll interval makes the two race:
    # whichever fires first decides whether the abort path or the 504 path runs, so the test
    # passed alone and failed inside the full suite where timing shifts under load. A test whose
    # outcome depends on which of two timers wins is not testing what its name says.
    env["UPSTREAM_TIMEOUT"] = "600"

    err_path = Path(os.environ.get("TEMP", ".")) / f"qwen-proxy-hangup-{px_port}.log"
    err_fh = open(err_path, "wb")
    proc = subprocess.Popen(
        [sys.executable, str(_PROXY)], env=env, cwd=str(_TOOLS),
        stdout=subprocess.DEVNULL, stderr=err_fh,
    )
    try:
        for _ in range(100):
            try:
                socket.create_connection(("127.0.0.1", px_port), timeout=0.2).close()
                break
            except OSError:
                time.sleep(0.1)
        else:
            pytest.fail("the proxy under test never bound its port")

        body = json.dumps({
            "model": "coder-30b",
            "messages": [{"role": "user", "content": "hi"}],
            "stream": False,
        }).encode()
        req = (
            b"POST /v3/chat/completions HTTP/1.1" + CRLF
            + b"Host: 127.0.0.1" + CRLF
            + b"Content-Type: application/json" + CRLF
            + b"Content-Length: " + str(len(body)).encode() + CRLF + CRLF
            + body
        )
        # Send, then LEAVE -- exactly what an idle-killed candidate does.
        s = socket.create_connection(("127.0.0.1", px_port), timeout=5)
        s.sendall(req)
        s.close()

        # Give the proxy time to hit its 2s upstream timeout and try to answer a dead socket.
        deadline = time.time() + 25
        text = ""
        while time.time() < deadline:
            time.sleep(0.5)
            try:
                text = err_path.read_text(errors="replace")
            except OSError:
                continue
            if "CLIENT GONE MID-GENERATION" in text:
                break

        assert "CLIENT GONE MID-GENERATION" in text, (
            "the proxy did not ABORT the upstream request for a departed client; stderr:\n" + text[-2000:])
        assert "Traceback" not in text, (
            "the 504 to a departed client still raised; stderr was:\n" + text[-3000:])
        # The harm was VOLUME, not the exception: a real signal buried under stack traces. So
        # assert brevity, not the absence of the exception's NAME -- the report deliberately
        # names the type, and an earlier version of this assertion forbade its own fix's output.
        lines = [ln for ln in text.splitlines() if ln.strip()]
        assert len(lines) <= 3, (
            f"one departed client should cost about one line of stderr, got {len(lines)}:\n"
            + text[-3000:])
        assert sum("CLIENT GONE MID-GENERATION" in ln for ln in lines) == 1, (
            "the departed client should be reported exactly once:\n" + text[-2000:])
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=10)
        except Exception:
            proc.kill()
        srv.shutdown()
        srv.server_close()
        try:
            err_fh.close()
            err_path.unlink()
        except Exception:
            pass


# --------------------------------------------------------------------------------------------
# #1519 — the abort must actually TEAR DOWN the upstream connection, not merely log about it.
#
# The stderr line above proves the proxy noticed. It does not prove OVMS was released, which is
# the entire point: an orphaned generation holds the scheduler slot and starves every candidate
# behind it. So this fixture reports, from the SERVER side, whether its connection died while it
# was still generating.


class _ReportingUpstream(BaseHTTPRequestHandler):
    """Sends headers, then trickles. Records whether the client (the proxy) vanished mid-body."""

    protocol_version = "HTTP/1.1"
    report_path = None          # set by the test before the server starts

    def log_message(self, *a):
        pass

    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0) or 0)
        if n:
            self.rfile.read(n)
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", "100000")
        self.end_headers()
        outcome = "COMPLETED"
        try:
            for _ in range(600):        # 60s of trickle; the test never waits that long
                self.wfile.write(b" ")
                self.wfile.flush()
                time.sleep(0.1)
        except Exception:
            outcome = "ABORTED-BY-CLIENT"
        try:
            with open(type(self).report_path, "a", encoding="utf-8") as fh:
                fh.write(outcome + "\n")
        except Exception:
            pass


def test_the_abort_actually_tears_down_the_upstream_connection():
    report = Path(os.environ.get("TEMP", ".")) / f"upstream-report-{_free_port()}.txt"
    if report.exists():
        report.unlink()
    _ReportingUpstream.report_path = str(report)

    up_port = _free_port()
    srv = ThreadingHTTPServer(("127.0.0.1", up_port), _ReportingUpstream)
    threading.Thread(target=srv.serve_forever, daemon=True).start()

    px_port = _free_port()
    env = dict(os.environ)
    env["OVMS_BASE"] = f"http://127.0.0.1:{up_port}"
    env["PROXY_PORT"] = str(px_port)
    env["FIX_MODELS"] = "coder-30b:qwen3coder"     # the buffered/repair path, as in production
    env["UPSTREAM_TIMEOUT"] = "600"                # long: the ABORT must end this, not the timeout

    err_path = Path(os.environ.get("TEMP", ".")) / f"qwen-proxy-abort-{px_port}.log"
    err_fh = open(err_path, "wb")
    proc = subprocess.Popen(
        [sys.executable, str(_PROXY)], env=env, cwd=str(_TOOLS),
        stdout=subprocess.DEVNULL, stderr=err_fh,
    )
    try:
        for _ in range(100):
            try:
                socket.create_connection(("127.0.0.1", px_port), timeout=0.2).close()
                break
            except OSError:
                time.sleep(0.1)
        else:
            pytest.fail("the proxy under test never bound its port")

        body = json.dumps({
            "model": "coder-30b",
            "messages": [{"role": "user", "content": "hi"}],
            "stream": False,
        }).encode()
        req = (
            b"POST /v3/chat/completions HTTP/1.1" + CRLF
            + b"Host: 127.0.0.1" + CRLF
            + b"Content-Type: application/json" + CRLF
            + b"Content-Length: " + str(len(body)).encode() + CRLF + CRLF
            + body
        )
        s = socket.create_connection(("127.0.0.1", px_port), timeout=5)
        s.sendall(req)
        time.sleep(2)      # let the generation genuinely start upstream
        s.close()          # the candidate is killed

        deadline = time.time() + 40
        seen = ""
        while time.time() < deadline:
            time.sleep(0.5)
            if report.exists():
                seen = report.read_text(errors="replace")
                if seen.strip():
                    break

        assert "ABORTED-BY-CLIENT" in seen, (
            "upstream was NOT torn down when the client left -- the generation would keep running "
            "and hold the model server's slot, which is the whole defect. Report was: "
            + repr(seen))
        assert "COMPLETED" not in seen, (
            "upstream ran to completion despite the client leaving: " + repr(seen))
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=10)
        except Exception:
            proc.kill()
        srv.shutdown()
        srv.server_close()
        try:
            err_fh.close()
            err_path.unlink()
            report.unlink()
        except Exception:
            pass


# --------------------------------------------------------------------------------------------
# #1519 — the abort must work in the BUFFERED shape, which is the only shape that takes this path.
#
# WHY THE FIXTURE ABOVE WAS NOT ENOUGH. _ReportingUpstream sends headers and THEN trickles, which
# is the streaming shape. The fix is wired into the buffered path only (stream:false, forced by
# the proxy so the repair can see a complete response), and a buffered response's defining
# property is that NOTHING is sent until the generation finishes. Measured against the live OVMS
# on 2026-09-02 16:56:
#
#     300 tokens   first byte 38.686290s   complete 38.686546s   (gap 0.26 ms)
#       4 tokens   first byte  1.873875s   complete  1.874190s   (gap 0.32 ms)
#     framing: content-length, not chunked
#
# So a headers-early fixture exercises the one case where the first implementation's abort could
# fire, and structurally could not reach the case that ships. It reported 9 passed while the
# shipped path aborted nothing at all.


class _BufferedUpstream(BaseHTTPRequestHandler):
    """Sends NOTHING until it is done, like OVMS with stream:false.

    While "generating" it watches its own socket, so it can report -- from the server side --
    whether the client (the proxy) tore the connection down mid-generation. That is the claim
    under test: not that the proxy logged something, but that the model server was released.
    """

    protocol_version = "HTTP/1.1"
    report_path = None
    generate_secs = 30

    def log_message(self, *a):
        pass

    def _client_vanished(self):
        try:
            r, _, _ = select.select([self.connection], [], [], 0)
            if not r:
                return False
            return len(self.connection.recv(1, socket.MSG_PEEK)) == 0
        except OSError:
            return True

    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0) or 0)
        if n:
            self.rfile.read(n)
        outcome = "COMPLETED"
        deadline = time.time() + type(self).generate_secs
        while time.time() < deadline:            # the "generation" -- nothing is sent yet
            if self._client_vanished():
                outcome = "ABORTED-BY-CLIENT"
                break
            time.sleep(0.2)
        try:
            with open(type(self).report_path, "a", encoding="utf-8") as fh:
                fh.write(outcome + "\n")
        except Exception:
            pass
        if outcome == "COMPLETED":
            payload = json.dumps({"choices": [{"message": {"role": "assistant", "content": "done"}}]}).encode()
            try:
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)
            except Exception:
                pass
        self.close_connection = True


def test_the_abort_works_in_the_buffered_shape_that_actually_ships():
    report = Path(os.environ.get("TEMP", ".")) / f"buffered-report-{_free_port()}.txt"
    if report.exists():
        report.unlink()
    _BufferedUpstream.report_path = str(report)

    up_port = _free_port()
    srv = ThreadingHTTPServer(("127.0.0.1", up_port), _BufferedUpstream)
    threading.Thread(target=srv.serve_forever, daemon=True).start()

    px_port = _free_port()
    env = dict(os.environ)
    env["OVMS_BASE"] = f"http://127.0.0.1:{up_port}"
    env["PROXY_PORT"] = str(px_port)
    env["FIX_MODELS"] = "coder-30b:qwen3coder"     # the repair path -> stream:false -> buffered
    env["UPSTREAM_TIMEOUT"] = "600"                # long: the ABORT must end this, not the timeout

    err_path = Path(os.environ.get("TEMP", ".")) / f"qwen-proxy-buffered-{px_port}.log"
    err_fh = open(err_path, "wb")
    proc = subprocess.Popen(
        [sys.executable, str(_PROXY)], env=env, cwd=str(_TOOLS),
        stdout=subprocess.DEVNULL, stderr=err_fh,
    )
    try:
        for _ in range(100):
            try:
                socket.create_connection(("127.0.0.1", px_port), timeout=0.2).close()
                break
            except OSError:
                time.sleep(0.1)
        else:
            pytest.fail("the proxy under test never bound its port")

        body = json.dumps({
            "model": "coder-30b",
            "messages": [{"role": "user", "content": "hi"}],
            "stream": False,
        }).encode()
        req = (
            b"POST /v3/chat/completions HTTP/1.1" + CRLF
            + b"Host: 127.0.0.1" + CRLF
            + b"Content-Type: application/json" + CRLF
            + b"Content-Length: " + str(len(body)).encode() + CRLF + CRLF
            + body
        )
        s = socket.create_connection(("127.0.0.1", px_port), timeout=5)
        s.sendall(req)
        time.sleep(2)      # let the "generation" genuinely start upstream
        s.close()          # the candidate is killed by the idle breaker

        deadline = time.time() + 40
        seen = ""
        while time.time() < deadline:
            time.sleep(0.5)
            if report.exists():
                seen = report.read_text(errors="replace")
                if seen.strip():
                    break

        assert "ABORTED-BY-CLIENT" in seen, (
            "upstream was NOT released in the buffered shape -- the generation kept running for a "
            "client that had gone, holding the model server's slot, which is the entire defect. "
            "Report was: " + repr(seen))
        assert "COMPLETED" not in seen, (
            "upstream ran to completion despite the client leaving: " + repr(seen))
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=10)
        except Exception:
            proc.kill()
        srv.shutdown()
        srv.server_close()
        try:
            err_fh.close()
            err_path.unlink()
            report.unlink()
        except Exception:
            pass


# --------------------------------------------------------------------------------------------
# #1519 — A LIVE CLIENT MUST NOT BE ABORTED. This is the direction the suite was blind to.
#
# Review proved the blindness structurally: `gone()` is only consulted after `done.wait(poll)`
# TIMES OUT, and every other fixture in this file answers well inside one poll interval, so no
# other test calls `gone()` even once. A mutant with `_peer_gone` returning True unconditionally
# -- which aborts every buffered request and would kill every live coder generation on the box --
# passed the whole suite 9/9.
#
# "Does it abort when it should" and "does it leave alone what it should" are two claims, and
# only the first was tested. A false positive here is WORSE than the defect being fixed: the
# defect wastes a slot, a false positive destroys work that was going fine.


class _SlowButHealthyUpstream(BaseHTTPRequestHandler):
    """Buffered shape, deliberately slower than one poll interval, then answers normally."""

    protocol_version = "HTTP/1.1"
    delay_secs = 7.0

    def log_message(self, *a):
        pass

    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0) or 0)
        if n:
            self.rfile.read(n)
        time.sleep(type(self).delay_secs)      # the "generation" -- several poll intervals long
        payload = json.dumps({
            "choices": [{"message": {"role": "assistant", "content": "the answer survived"}}]
        }).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)
        self.close_connection = True


def test_a_live_client_waiting_longer_than_the_poll_interval_still_gets_its_answer():
    up_port = _free_port()
    srv = ThreadingHTTPServer(("127.0.0.1", up_port), _SlowButHealthyUpstream)
    threading.Thread(target=srv.serve_forever, daemon=True).start()

    px_port = _free_port()
    env = dict(os.environ)
    env["OVMS_BASE"] = f"http://127.0.0.1:{up_port}"
    env["PROXY_PORT"] = str(px_port)
    env["FIX_MODELS"] = "coder-30b:qwen3coder"     # buffered path, as in production
    env["UPSTREAM_TIMEOUT"] = "600"

    err_path = Path(os.environ.get("TEMP", ".")) / f"qwen-proxy-live-{px_port}.log"
    err_fh = open(err_path, "wb")
    proc = subprocess.Popen(
        [sys.executable, str(_PROXY)], env=env, cwd=str(_TOOLS),
        stdout=subprocess.DEVNULL, stderr=err_fh,
    )
    try:
        for _ in range(100):
            try:
                socket.create_connection(("127.0.0.1", px_port), timeout=0.2).close()
                break
            except OSError:
                time.sleep(0.1)
        else:
            pytest.fail("the proxy under test never bound its port")

        started = time.time()
        conn = http.client.HTTPConnection("127.0.0.1", px_port, timeout=60)
        conn.request(
            "POST", "/v3/chat/completions",
            body=json.dumps({
                "model": "coder-30b",
                "messages": [{"role": "user", "content": "hi"}],
                "stream": False,
            }),
            headers={"Content-Type": "application/json"},
        )
        resp = conn.getresponse()
        raw = resp.read()
        elapsed = time.time() - started
        conn.close()

        assert resp.status == 200, f"a live client got HTTP {resp.status}: {raw[:300]!r}"
        assert b"the answer survived" in raw, (
            "the live client's answer was lost -- the proxy aborted a generation for a client that "
            f"was still there. Body: {raw[:300]!r}")
        # The point of the case: it outlived several poll intervals, so gone() was actually
        # consulted. Without this the test would pass on a proxy that never polls at all.
        assert elapsed >= _SlowButHealthyUpstream.delay_secs - 1, (
            f"returned in {elapsed:.1f}s, faster than the {_SlowButHealthyUpstream.delay_secs}s "
            "upstream -- this case did not exercise the polling loop and proves nothing")

        err_fh.flush()
        text = err_path.read_text(errors="replace")
        assert "CLIENT GONE" not in text, (
            "the proxy reported a departed client for one that never left:\n" + text[-1000:])
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=10)
        except Exception:
            proc.kill()
        srv.shutdown()
        srv.server_close()
        try:
            err_fh.close()
            err_path.unlink()
        except Exception:
            pass


# --------------------------------------------------------------------------------------------
# #1519 — CHARACTERISATION, not approval: a half-closing client is currently treated as gone.
#
# EOF means "the client will send nothing more", NOT "the client has left". A client that calls
# shutdown(SHUT_WR) after its request is doing something legal and is still reading, and TCP
# offers no way to tell it from a departure without writing to the socket, which we cannot do
# before the response exists. Measured against the real proxy:
#
#     full-close   aborted=True   answer_delivered=False   (correct)
#     half-close   aborted=True   answer_delivered=False   (WRONG -- live work destroyed)
#     stay-open    aborted=False  answer_delivered=True    (correct)
#
# It is theoretical for THIS fleet rather than assumed to be: node/undici via opencode was
# measured not to half-close -- a server withholding its response for 6s saw no EOF, and the
# answer was delivered. This test pins the behaviour so that a change to it is deliberate and
# visible, and so nobody has to rediscover the limitation from first principles. If someone makes
# the proxy handle half-close correctly, THIS TEST SHOULD FAIL and be rewritten to assert the fix.


def _drive_client(px_port, mode, err_path, delay):
    """Send a request, then behave per `mode`. Returns (proxy_said_gone, answer_delivered)."""
    before = err_path.stat().st_size if err_path.exists() else 0
    body = json.dumps({"model": "coder-30b", "messages": [{"role": "user", "content": "hi"}],
                       "stream": False}).encode()
    req = (b"POST /v3/chat/completions HTTP/1.1" + CRLF + b"Host: 127.0.0.1" + CRLF
           + b"Content-Type: application/json" + CRLF
           + b"Content-Length: " + str(len(body)).encode() + CRLF + CRLF + body)
    s = socket.create_connection(("127.0.0.1", px_port), timeout=delay + 25)
    s.sendall(req)
    time.sleep(1.0)
    got = b""
    if mode == "full-close":
        s.close()
        time.sleep(delay + 4)
    else:
        if mode == "half-close":
            s.shutdown(socket.SHUT_WR)
        try:
            s.settimeout(delay + 20)
            while b"answer" not in got:
                chunk = s.recv(65536)
                if not chunk:
                    break
                got += chunk
        except Exception:
            pass
        finally:
            try:
                s.close()
            except Exception:
                pass
    with open(err_path, "rb") as fh:
        fh.seek(before)
        new = fh.read().decode(errors="replace")
    # MID-GENERATION specifically: with cancellation off a departed client still trips _send's
    # #1495 guard ("CLIENT GONE BEFORE REPLY"), which is correct and must not read as an abort.
    return ("CLIENT GONE MID-GENERATION" in new), (b"answer" in got)


def _proxy_against_slow_upstream(env_extra=None, delay=7.0):
    """Spawn a proxy over an upstream that withholds its response for `delay` seconds."""
    _SlowButHealthyUpstream.delay_secs = delay
    up_port = _free_port()
    srv = ThreadingHTTPServer(("127.0.0.1", up_port), _SlowButHealthyUpstream)
    threading.Thread(target=srv.serve_forever, daemon=True).start()

    px_port = _free_port()
    env = dict(os.environ)
    env["OVMS_BASE"] = f"http://127.0.0.1:{up_port}"
    env["PROXY_PORT"] = str(px_port)
    env["FIX_MODELS"] = "coder-30b:qwen3coder"
    env["UPSTREAM_TIMEOUT"] = "600"
    env.update(env_extra or {})
    err_path = Path(os.environ.get("TEMP", ".")) / f"qwen-proxy-char-{px_port}.log"
    err_fh = open(err_path, "wb")
    proc = subprocess.Popen(
        [sys.executable, str(_PROXY)], env=env, cwd=str(_TOOLS),
        stdout=subprocess.DEVNULL, stderr=err_fh,
    )
    for _ in range(100):
        try:
            socket.create_connection(("127.0.0.1", px_port), timeout=0.2).close()
            break
        except OSError:
            time.sleep(0.1)
    else:
        proc.kill(); srv.shutdown()
        pytest.fail("the proxy under test never bound its port")
    return proc, srv, px_port, err_path, err_fh


def _teardown(proc, srv, err_path, err_fh):
    proc.terminate()
    try:
        proc.wait(timeout=10)
    except Exception:
        proc.kill()
    srv.shutdown()
    srv.server_close()
    try:
        err_fh.close()
        err_path.unlink()
    except Exception:
        pass


def test_half_close_is_currently_treated_as_departure_KNOWN_LIMITATION():
    proc, srv, px, err_path, err_fh = _proxy_against_slow_upstream()
    try:
        gone_full, got_full = _drive_client(px, "full-close", err_path, 7.0)
        gone_half, got_half = _drive_client(px, "half-close", err_path, 7.0)
        gone_open, got_open = _drive_client(px, "stay-open", err_path, 7.0)
    finally:
        _teardown(proc, srv, err_path, err_fh)

    assert gone_full and not got_full, "a client that fully left must be treated as gone"
    assert not gone_open and got_open, "a client that stayed must NOT be treated as gone"
    # The limitation itself. Pinned, not endorsed.
    assert gone_half and not got_half, (
        "half-close is no longer treated as departure -- if that is a deliberate FIX, rewrite this "
        "test to assert the fix and update _peer_gone's docstring; if it is accidental, the "
        "cancellation may have stopped working")


def test_cancellation_can_be_switched_off_without_a_code_change():
    """PROXY_CANCEL_ON_DISCONNECT=0 is the emergency lever if a client ever half-closes."""
    proc, srv, px, err_path, err_fh = _proxy_against_slow_upstream(
        env_extra={"PROXY_CANCEL_ON_DISCONNECT": "0"})
    try:
        gone_full, _ = _drive_client(px, "full-close", err_path, 7.0)
        gone_half, got_half = _drive_client(px, "half-close", err_path, 7.0)
    finally:
        _teardown(proc, srv, err_path, err_fh)

    assert not gone_full, (
        "with cancellation off the proxy must not abort even a client that truly left -- that is "
        "the point of the lever, and it reinstates the #1519 starvation deliberately")
    assert not gone_half and got_half, (
        "with cancellation off a half-closing client must get its answer -- this is what the lever "
        "buys if a client is ever found to half-close")


# --------------------------------------------------------------------------------------------
# #1519 — the emergency lever must honour the words a person actually types.
#
# The first version matched exactly ("0", "false", "no"), case-sensitively, so off / Off / OFF /
# False / disabled were all silently IGNORED and cancellation stayed on. That fires in precisely
# the situation the lever exists for: a client starts half-closing, live candidate work dies,
# someone reaches for the documented switch, types the word most people type first, sees a normal
# startup banner, and the destruction continues. It was tested on the single string that worked.


def _proxy_banner(value):
    """Start the proxy with PROXY_CANCEL_ON_DISCONNECT=value; return (stdout, stderr)."""
    up_port = _free_port()
    srv = ThreadingHTTPServer(("127.0.0.1", up_port), _SlowButHealthyUpstream)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    px_port = _free_port()
    env = dict(os.environ)
    env["OVMS_BASE"] = f"http://127.0.0.1:{up_port}"
    env["PROXY_PORT"] = str(px_port)
    env.pop("PROXY_CANCEL_ON_DISCONNECT", None)
    if value is not None:
        env["PROXY_CANCEL_ON_DISCONNECT"] = value
    proc = subprocess.Popen([sys.executable, str(_PROXY)], env=env, cwd=str(_TOOLS),
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        for _ in range(100):
            try:
                socket.create_connection(("127.0.0.1", px_port), timeout=0.2).close()
                break
            except OSError:
                time.sleep(0.1)
        time.sleep(0.3)
    finally:
        proc.terminate()
        try:
            out, err = proc.communicate(timeout=10)
        except Exception:
            proc.kill()
            out, err = proc.communicate()
        srv.shutdown()
        srv.server_close()
    return out or "", err or ""


@pytest.mark.parametrize("value", ["0", "false", "no", "off", "Off", "OFF", "False", "FALSE",
                                   "disabled", " off "])
def test_the_lever_switches_cancellation_off_for_every_word_a_person_would_type(value):
    out, _err = _proxy_banner(value)
    assert "cancellation: OFF" in out, (
        f"PROXY_CANCEL_ON_DISCONNECT={value!r} did NOT switch cancellation off. Banner was:\n{out}")


@pytest.mark.parametrize("value", [None, "1", "true", "on", "yes"])
def test_the_lever_leaves_cancellation_on_by_default(value):
    out, _err = _proxy_banner(value)
    assert "cancellation: ON" in out, (
        f"PROXY_CANCEL_ON_DISCONNECT={value!r} should leave cancellation ON. Banner was:\n{out}")


def test_an_unrecognised_lever_value_is_announced_rather_than_guessed():
    out, err = _proxy_banner("banana")
    assert "cancellation: ON" in out, "an unrecognised value must fail safe, leaving cancellation on"
    assert "not a value I recognise" in err, (
        "an unrecognised value must SAY so -- silently doing nothing is the defect this closes:\n"
        + err[-500:])


# --------------------------------------------------------------------------------------------
# #1495 — the _send guard, which thirteen green tests never touched.
#
# Review deleted the except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError)
# handler entirely and the suite still reported 13 passed: every case matched on "CLIENT GONE
# MID-GENERATION", and "CLIENT GONE BEFORE REPLY" appeared in the suite only inside a comment.
# It is live traffic -- review's 40-way concurrency probe tripped it 5 times in one run.
#
# Reaching it needs cancellation OFF (otherwise the abort fires first) and an upstream fast
# enough to answer before anyone notices the client has gone.


class _InstantUpstream(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0) or 0)
        if n:
            self.rfile.read(n)
        payload = json.dumps({"choices": [{"message": {"role": "assistant",
                                                       "content": "answer"}}]}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)
        self.close_connection = True


def test_send_tolerates_a_client_that_left_before_the_answer_was_ready():
    up_port = _free_port()
    srv = ThreadingHTTPServer(("127.0.0.1", up_port), _InstantUpstream)
    threading.Thread(target=srv.serve_forever, daemon=True).start()

    px_port = _free_port()
    env = dict(os.environ)
    env["OVMS_BASE"] = f"http://127.0.0.1:{up_port}"
    env["PROXY_PORT"] = str(px_port)
    env["FIX_MODELS"] = "coder-30b:qwen3coder"
    env["UPSTREAM_TIMEOUT"] = "600"
    env["PROXY_CANCEL_ON_DISCONNECT"] = "0"     # so the abort cannot pre-empt the _send path

    err_path = Path(os.environ.get("TEMP", ".")) / f"qwen-proxy-sendguard-{px_port}.log"
    err_fh = open(err_path, "wb")
    proc = subprocess.Popen([sys.executable, str(_PROXY)], env=env, cwd=str(_TOOLS),
                            stdout=subprocess.DEVNULL, stderr=err_fh)
    try:
        for _ in range(100):
            try:
                socket.create_connection(("127.0.0.1", px_port), timeout=0.2).close()
                break
            except OSError:
                time.sleep(0.1)
        else:
            pytest.fail("the proxy under test never bound its port")

        body = json.dumps({"model": "coder-30b", "stream": False,
                           "messages": [{"role": "user", "content": "hi"}]}).encode()
        req = (b"POST /v3/chat/completions HTTP/1.1" + CRLF + b"Host: 127.0.0.1" + CRLF
               + b"Content-Type: application/json" + CRLF
               + b"Content-Length: " + str(len(body)).encode() + CRLF + CRLF + body)
        # Send and leave AT ONCE, so the answer is ready before anything notices.
        s = socket.create_connection(("127.0.0.1", px_port), timeout=5)
        s.sendall(req)
        s.close()

        deadline = time.time() + 30
        text = ""
        while time.time() < deadline:
            time.sleep(0.5)
            text = err_path.read_text(errors="replace")
            if "CLIENT GONE BEFORE REPLY" in text or "Traceback" in text:
                break

        assert "Traceback" not in text, (
            "_send raised on a departed client instead of reporting it -- that buried 38 real "
            f"upstream timeouts under stack traces on 2026-09-02:\n{text[-2000:]}")
        assert "CLIENT GONE BEFORE REPLY" in text, (
            "the _send guard did not report a client that left before the answer was ready; this "
            f"is the path review deleted with the suite still green:\n{text[-2000:]}")
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=10)
        except Exception:
            proc.kill()
        srv.shutdown()
        srv.server_close()
        try:
            err_fh.close()
            err_path.unlink()
        except Exception:
            pass


# --------------------------------------------------------------------------------------------
# #1507 — independent-review findings, locked.


def test_a_malformed_upstream_chunk_fails_loud_instead_of_silently_dropping_content(proxy):
    """Finding #1. Before the fix, an unparseable data: line was silently skipped -- the
    answer shipped as a confident 200 missing a slice of its own content, with nothing in
    proxy stderr. That is exactly the failure class _fix_response's own SEVERANCE guard
    exists to prevent for a different trigger; this locks the same discipline here."""
    status, hdrs, data, err = _post_stream(proxy, "malformed-chunk")
    assert status == 200
    assert err == "IncompleteRead", (
        f"an unparseable upstream chunk must surface as a transport error, not a clean (and "
        f"silently wrong) answer; got err={err!r} data={data[-300:]!r}"
    )
    assert b"INCOMPLETE" in data.upper()
    # "CCC" must never appear either: once the transfer is marked failed, nothing after the
    # bad chunk should reach the client framed as more real content.
    for content in _sse_content_deltas(data):
        assert content not in ("AAA", "CCC"), (
            f"content must not ship framed as real deltas once the transfer has failed: {content!r}"
        )


def test_a_split_native_tool_call_name_is_accumulated_not_overwritten(proxy):
    """Finding #3. `arguments` was already accumulated (appended); `name` was being
    OVERWRITTEN by each fragment instead. 'get_' + 'weather' must survive as 'get_weather',
    not collapse to just the last piece received."""
    status, hdrs, data, err = _post_stream(proxy, "native-toolcall-split")
    assert status == 200
    assert not err
    names, arguments = [], []
    for line in data.split(b"\n"):
        s = line.strip()
        if not s.startswith(b"data:") or s[5:].strip() == b"[DONE]":
            continue
        try:
            ev = json.loads(s[5:].strip())
        except Exception:
            continue
        for ch in ev.get("choices", []):
            for tc in (ch.get("delta") or {}).get("tool_calls") or []:
                fn = tc.get("function") or {}
                if fn.get("name"):
                    names.append(fn["name"])
                if fn.get("arguments"):
                    arguments.append(fn["arguments"])
    assert "".join(names) == "get_weather", (
        f"a tool call name split across chunks must be concatenated, not overwritten: {names!r}"
    )
    assert json.loads("".join(arguments)) == {"city": "nyc"}, (
        f"arguments must still accumulate correctly alongside the name fix: {arguments!r}"
    )


def test_multiple_choices_are_not_spliced_into_one_answer(proxy):
    """Finding #4. Interleaved choice 0 / choice 1 deltas must produce two separate
    candidates, not one accumulator holding both spliced together."""
    status, hdrs, data, err = _post_stream(proxy, "multi-choice")
    assert status == 200
    assert not err
    by_index: dict[int, list[str]] = {}
    for line in data.split(b"\n"):
        s = line.strip()
        if not s.startswith(b"data:"):
            continue
        payload = s[5:].strip()
        if payload == b"[DONE]":
            continue
        try:
            ev = json.loads(payload)
        except Exception:
            continue
        for ch in ev.get("choices", []):
            content = (ch.get("delta") or {}).get("content")
            if content:
                by_index.setdefault(ch.get("index", 0), []).append(content)
    assert "".join(by_index.get(0, [])) == "AxAz", f"choice 0 corrupted: {by_index.get(0)!r}"
    assert "".join(by_index.get(1, [])) == "ByBw", f"choice 1 corrupted: {by_index.get(1)!r}"


def test_a_gap_before_the_first_upstream_chunk_still_gets_pinged():
    """Finding #2. The worker's own ping only fires reactively, once per upstream chunk it
    receives -- so a pause BEFORE the first chunk (prefill on a large prompt, or upstream
    stalling mid-generation) was silent for as long as upstream was, unmitigated by the fix.
    Proves the main thread's independent timer closes that gap: upstream here sends nothing
    for ~5s (more than two poll intervals) before its first (and only) real chunk."""

    class _SlowStart(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *a):
            pass

        def do_POST(self):
            n = int(self.headers.get("Content-Length", 0) or 0)
            if n:
                self.rfile.read(n)
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            time.sleep(5.0)   # the gap under test -- more than two 2.0s poll intervals
            self.wfile.write(_chunk(_frame(0, "coder-30b")))
            self.wfile.flush()
            self.wfile.write(_chunk(b"data: [DONE]\n\n"))
            self.wfile.write(b"0" + CRLF + CRLF)
            self.wfile.flush()
            self.close_connection = True

    up_port = _free_port()
    srv = ThreadingHTTPServer(("127.0.0.1", up_port), _SlowStart)
    threading.Thread(target=srv.serve_forever, daemon=True).start()

    px_port = _free_port()
    env = dict(os.environ)
    env["OVMS_BASE"] = f"http://127.0.0.1:{up_port}"
    env["PROXY_PORT"] = str(px_port)
    env["FIX_MODELS"] = "coder-30b:qwen3coder"

    proc = subprocess.Popen(
        [sys.executable, str(_PROXY)], env=env, cwd=str(_TOOLS),
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    try:
        for _ in range(100):
            try:
                socket.create_connection(("127.0.0.1", px_port), timeout=0.2).close()
                break
            except OSError:
                time.sleep(0.1)
        else:
            pytest.fail("the proxy under test never bound its port")

        status, hdrs, data, err = _post_stream(px_port, "coder-30b", timeout=20.0)
        assert status == 200
        assert not err, f"the stream must complete cleanly despite the pre-first-chunk gap: {err}"
        assert b"[DONE]" in data
        pings = 0
        for line in data.split(b"\n"):
            s = line.strip()
            if not s.startswith(b"data:") or s[5:].strip() == b"[DONE]":
                continue
            try:
                ev = json.loads(s[5:].strip())
            except Exception:
                continue
            for ch in ev.get("choices", []):
                d = ch.get("delta") or {}
                if d.get("reasoning_content") and not d.get("content"):
                    pings += 1
        assert pings >= 2, (
            f"a ~5s gap before the first upstream chunk (more than two 2.0s poll intervals) "
            f"must produce at least 2 independent liveness pings from the main thread's own "
            f"timer, got {pings}"
        )
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=10)
        except Exception:
            proc.kill()
        srv.shutdown()
        srv.server_close()
