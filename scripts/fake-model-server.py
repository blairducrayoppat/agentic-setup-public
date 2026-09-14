"""Fake OVMS-shaped endpoints for verify-model-server-wedge.ps1 (#1495).

One process, one behaviour, chosen by argv[1]; binds an ephemeral port and prints it on
stdout so the caller never has to guess a free port or race a fixed one.

  healthy   answers /v3/models AND a completion
  wedged    answers /v3/models INSTANTLY, hangs every completion forever
            -- the shape all three observed wedges had, and the reason a GET-based
            liveness check cannot see them
  empty200  answers a completion with HTTP 200 and no choices (an error object under a 200)
  error500  answers a completion with HTTP 500
  slow      hangs the FIRST completion, answers every later one (a slow server, NOT a wedge:
            the case the confirmation re-probe exists to protect)
  truncate  sends status + headers promising 5000 bytes, writes 6, then closes
  trickle   sends status + headers promising 100000 bytes, then one byte per 500ms

The last two exist because PowerShell's Invoke-WebRequest reads with
HttpCompletionOption.ResponseHeadersRead: -TimeoutSec covers the request only up to the
RESPONSE HEADERS, and the body read afterwards is unbounded. A server that answers and
then stalls therefore hangs the caller forever rather than timing out. Review demonstrated
both shapes running past 180s against a 12s timeout.
"""
import json, sys, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MODE = sys.argv[1]
_seen = {"completions": 0}
_lock = threading.Lock()


class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def _json(self, code, obj):
        b = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        if self.path.rstrip("/").endswith("/v3/models"):
            # Answered in EVERY mode, wedged included. That is the point of the fixture.
            self._json(200, {"data": [{"id": "coder-30b"}]})
        else:
            self._json(404, {"error": "no"})

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        self.rfile.read(n)
        with _lock:
            _seen["completions"] += 1
            first = _seen["completions"] == 1
        if MODE == "wedged" or (MODE == "slow" and first):
            time.sleep(3600)          # never answers; the client must time out
            return
        if MODE in ("truncate", "trickle"):
            # Headers first, and a Content-Length we will not honour. Everything after this
            # point is body, which is exactly the region the caller's timeout must still cover.
            total = 5000 if MODE == "truncate" else 100000
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(total))
            self.end_headers()
            try:
                if MODE == "truncate":
                    self.wfile.write(b'{"cho')
                    self.wfile.flush()
                    self.close_connection = True
                    return
                while True:
                    self.wfile.write(b" ")
                    self.wfile.flush()
                    time.sleep(0.5)
            except Exception:
                return
        if MODE == "empty200":
            self._json(200, {"error": {"message": "upstream refused"}})
            return
        if MODE == "emptystr":
            # A well-formed completion whose content is the EMPTY STRING. '' is not None, so a
            # null-only check reported this as a successful generation.
            self._json(200, {"choices": [{"message": {"role": "assistant", "content": ""}}]})
            return
        if MODE == "whitespace":
            self._json(200, {"choices": [{"message": {"role": "assistant", "content": "   \n"}}]})
            return
        if MODE == "error500":
            self._json(500, {"error": "boom"})
            return
        self._json(200, {"choices": [{"message": {"role": "assistant", "content": "pong"}}]})


srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
srv.daemon_threads = True
print(srv.server_address[1], flush=True)
srv.serve_forever()
