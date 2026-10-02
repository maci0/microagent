"""The failure counter is spent under a lock, so K failures means K refusals.

ThreadingHTTPServer answers each request on its own thread, and the flag's
promise is that the first K requests are refused. This pins that promise
under a burst of concurrent requests, so a future change that moves the
decrement back outside the lock is caught here.

It is a guard, not a reproducer: CPython's GIL does not schedule a switch
inside this particular read-modify-write, so the counter was not observed
going short even without the lock. The lock is there because the invariant
does not hold by accident of a language implementation, and the assertion
belongs to the flag's documented contract rather than to a timing quirk.
"""

from __future__ import annotations

import json
import sys
import threading
import time
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer
from pathlib import Path

# `Path(__file__).resolve().parent` rather than splitting `__file__` on a `/`:
# a path separator is spelled here rather than asked of the platform, and a
# script run as `python3 bench/test_stub_provider.py` from the checkout root
# carries no separator at all to split on, which left the module itself on
# sys.path instead of the directory holding `stub_provider`. Every other Python
# file in the tree resolves its own location this way.
sys.path.insert(0, str(Path(__file__).resolve().parent))

from stub_provider import Handler

BODY = json.dumps({"model": "stub", "messages": []}).encode()


def hammer(port: int, requests: int) -> dict[int, int]:
    """Fire `requests` POSTs at once and count how many answers there were."""
    counts: dict[int, int] = {}
    counts_lock = threading.Lock()
    start = threading.Barrier(requests)

    def one() -> None:
        req = urllib.request.Request(
            f"http://127.0.0.1:{port}/v1/chat/completions",
            data=BODY,
            headers={"content-type": "application/json"},
            method="POST",
        )
        start.wait()
        # The listen backlog is small, so a thread can be turned away before it
        # is answered. That is this test's own load rather than the counter's
        # behavior, so it waits for a real answer rather than counting a refused
        # connection as one.
        for _ in range(200):
            try:
                # because: the URL is a literal loopback address built two
                # lines above, never anything a request body or a header names.
                with urllib.request.urlopen(req) as response:  # noqa: S310
                    status = response.status
                    response.read()
                break
            except urllib.error.HTTPError as err:
                status = err.code
                err.read()
                break
            except OSError:
                time.sleep(0.01)
        else:
            status = -1
        with counts_lock:
            counts[status] = counts.get(status, 0) + 1

    threads = [threading.Thread(target=one) for _ in range(requests)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()
    return counts


def main() -> int:
    Handler.frames = 2
    Handler.failures_left = 3
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    port = server.server_address[1]
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        counts = hammer(port, 24)
    finally:
        server.shutdown()
        server.server_close()

    refused = counts.get(503, 0)
    # The flag promises 3; a lost update shows up as 1 or 2 under contention.
    print(f"statuses: {dict(sorted(counts.items()))}")
    if refused != 3:
        print(f"FAIL: {refused} refusals, expected exactly 3")
        return 1
    print("ok: exactly the 3 owed failures were refused")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
