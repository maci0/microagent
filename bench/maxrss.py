#!/usr/bin/env python3
"""Peak resident memory of one command, in kB.

    bench/maxrss.py COMMAND [ARGS ...]

Runs the command with its output discarded and prints the highest `VmHWM` its process reached.

The number is read at the last moment the process exists: it is started under ptrace with
PTRACE_O_TRACEEXIT, which stops it just before it exits, while /proc still holds its final
high-water mark. Polling /proc instead misses a command that lives a few hundred microseconds, and
the kernel's counter for waited-for children (`getrusage`) includes this interpreter's memory from
before the exec, which is larger than the whole of a small harness. Nothing is traced but the exit.

A command that starts other processes is measured by the first one only. Linux only; it needs
permission to ptrace its own child, which the default `kernel.yama.ptrace_scope` gives.
"""

from __future__ import annotations

import ctypes
import os
import shutil
import signal
import sys
from pathlib import Path

PTRACE_TRACEME = 0
PTRACE_CONT = 7
PTRACE_SETOPTIONS = 0x4200
PTRACE_O_TRACEEXIT = 0x40
PTRACE_EVENT_EXIT = 6
EXEC_FAILED = 127

libc = ctypes.CDLL(None, use_errno=True)
libc.ptrace.argtypes = [ctypes.c_long, ctypes.c_long, ctypes.c_void_p, ctypes.c_void_p]
libc.ptrace.restype = ctypes.c_long


def hwm_kb(pid: int) -> int:
    for line in Path(f"/proc/{pid}/status").read_text(encoding="utf-8").splitlines():
        if line.startswith("VmHWM:"):
            return int(line.split()[1])
    return 0


def peak_rss_kb(argv: list[str]) -> int:
    exe = shutil.which(argv[0])
    if exe is None:
        raise SystemExit(f"maxrss.py: {argv[0]}: not found")
    pid = os.fork()
    if pid == 0:
        libc.ptrace(PTRACE_TRACEME, 0, None, None)
        devnull = os.open(os.devnull, os.O_RDWR)
        os.dup2(devnull, 1)
        os.dup2(devnull, 2)
        try:
            # because: running the command under measurement is the whole job of this script
            os.execv(exe, [exe, *argv[1:]])  # noqa: S606
        finally:
            os._exit(EXEC_FAILED)
    os.waitpid(pid, 0)  # the stop the exec delivers
    libc.ptrace(PTRACE_SETOPTIONS, pid, None, ctypes.c_void_p(PTRACE_O_TRACEEXIT))
    libc.ptrace(PTRACE_CONT, pid, None, None)
    peak = 0
    while True:
        _, status = os.waitpid(pid, 0)
        if os.WIFEXITED(status) or os.WIFSIGNALED(status):
            return peak
        deliver = os.WSTOPSIG(status)
        if status >> 16 == PTRACE_EVENT_EXIT:
            peak = hwm_kb(pid)
            deliver = 0
        elif deliver == signal.SIGTRAP:
            deliver = 0
        libc.ptrace(PTRACE_CONT, pid, None, ctypes.c_void_p(deliver))


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    # Refused before the fork, not after it. `/proc` and the ptrace constants
    # this measures with are Linux's, and on a host without them the read at
    # the exit stop raises, so the traced child is never continued and is left
    # stopped in the process table holding whatever it was launched with. The
    # caller turns a nonzero exit into a `-` for the column; it cannot reap a
    # process this script no longer knows about.
    if not sys.platform.startswith("linux"):
        print("maxrss.py: /proc is Linux only; no number to report", file=sys.stderr)
        return 1
    print(peak_rss_kb(sys.argv[1:]))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
