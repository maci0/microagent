"""Exercise successful measurement, child failure and tracer cleanup."""

from __future__ import annotations

import os
import sys
from unittest.mock import patch

import maxrss


def check() -> None:
    if maxrss.peak_rss_kb(["/bin/true"]) <= 0:
        raise AssertionError("a successful child was not measured")
    if maxrss.peak_rss_kb(["/bin/sh", "-c", "exec /bin/true"]) <= 0:
        raise AssertionError("an exec in the measured command was not measured")
    for command in (
        ["/bin/false"],
        ["/bin/sh", "-c", "kill -TERM $$"],
        ["/bin/sh", "-c", "ulimit -c 0; kill -TRAP $$"],
    ):
        try:
            maxrss.peak_rss_kb(command)
        except RuntimeError:
            pass
        else:
            raise AssertionError("a failed child was reported as a valid measurement")
    with patch.object(maxrss, "hwm_kb", side_effect=OSError("unreadable /proc")):
        try:
            maxrss.peak_rss_kb(["/bin/true"])
        except OSError:
            pass
        else:
            raise AssertionError("an unreadable high-water mark was accepted")
    try:
        os.waitpid(-1, os.WNOHANG)
    except ChildProcessError:
        pass
    else:
        raise AssertionError("a traced child was left behind")


def check_tracing_failure() -> None:
    original = maxrss.ptrace
    failed = False

    def fail_once(request: int, pid: int = 0, data: int = 0) -> None:
        nonlocal failed
        if request == maxrss.PTRACE_CONT and not failed:
            failed = True
            raise OSError("cannot resume trace")
        original(request, pid, data)

    with patch.object(maxrss, "ptrace", side_effect=fail_once):
        try:
            maxrss.peak_rss_kb(["/bin/true"])
        except OSError:
            pass
        else:
            raise AssertionError("a ptrace failure was ignored")
    try:
        os.waitpid(-1, os.WNOHANG)
    except ChildProcessError:
        pass
    else:
        raise AssertionError("a child survived a ptrace failure")


if __name__ == "__main__":
    if sys.platform.startswith("linux"):
        check()
        check_tracing_failure()
        print("Memory benchmark checks passed")
    else:
        print("Memory benchmark checks skipped: Linux only")
