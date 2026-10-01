#!/usr/bin/env python3
"""A local OpenAI-compatible chat endpoint for measuring the harness alone.

    uv run --no-project bench/stub_provider.py PORT [--frames N] [--fail-first K]

Every POST is answered with N content deltas ("word0 ", "word1 ", ...), one
chunked-encoding chunk per SSE frame, then a stop frame carrying usage and
`[DONE]`. With --fail-first K the first K requests get a 503 instead, which is
what exercises the client's retry path. Loopback only, no model: the same
bytes every run, so what a profiler sees is the client.
"""

from __future__ import annotations

import argparse
import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DEFAULT_FRAMES = 5000

# ThreadingHTTPServer serves every request on its own thread, and this counter
# is the only mutable state here, so the read-modify-write that spends a
# failure takes a lock. CPython's GIL happens not to switch inside this
# sequence, so no run was observed going short; the lock is here because the
# flag promises the first K requests are refused and that promise should hold
# by construction rather than by accident of a language implementation.
_failure_lock = threading.Lock()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    frames = DEFAULT_FRAMES
    failures_left = 0

    def do_POST(self) -> None:
        self.rfile.read(int(self.headers.get("content-length", "0")))
        # Spend a failure under the lock and carry the answer out of it, so the
        # check and the decrement are one step: a request is refused exactly
        # while a failure is still owed, no matter how many arrive at once.
        with _failure_lock:
            refuse = Handler.failures_left > 0
            if refuse:
                Handler.failures_left -= 1
        if refuse:
            body = json.dumps({"error": "busy"}).encode()
            self.send_response(503)
            self.send_header("content-type", "application/json")
            self.send_header("content-length", str(len(body)))
            # The client drops the socket after an error answer, so a
            # kept-alive read for the next request would only fail.
            self.send_header("connection", "close")
            self.close_connection = True
            self.end_headers()
            self.wfile.write(body)
            return
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.send_header("transfer-encoding", "chunked")
        self.end_headers()
        for i in range(self.frames):
            self.chunk({"choices": [{"delta": {"content": f"word{i} "}}]})
        self.chunk(
            {
                "choices": [{"delta": {}, "finish_reason": "stop"}],
                "usage": {
                    "prompt_tokens": 10,
                    "completion_tokens": self.frames,
                    "total_tokens": self.frames + 10,
                },
            }
        )
        self.write_chunk(b"data: [DONE]\n\n")
        self.wfile.write(b"0\r\n\r\n")
        self.wfile.flush()

    def chunk(self, frame: dict[str, object]) -> None:
        self.write_chunk(b"data: " + json.dumps(frame).encode() + b"\n\n")

    def write_chunk(self, payload: bytes) -> None:
        self.wfile.write(b"%x\r\n" % len(payload) + payload + b"\r\n")

    # because: the name is the one BaseHTTPRequestHandler.log_message declares
    def log_message(self, format: str, *args: object) -> None:  # noqa: A002
        """Silence the per-request access log; stderr stays for errors."""


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("port", type=int)
    parser.add_argument("--frames", type=int, default=DEFAULT_FRAMES)
    parser.add_argument("--fail-first", type=int, default=0)
    args = parser.parse_args()
    if args.frames < 0 or args.fail_first < 0:
        parser.error("--frames and --fail-first take a count of 0 or more")
    Handler.frames = args.frames
    Handler.failures_left = args.fail_first
    ThreadingHTTPServer(("127.0.0.1", args.port), Handler).serve_forever()


if __name__ == "__main__":
    main()
