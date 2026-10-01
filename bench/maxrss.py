#!/usr/bin/env python3
"""Peak resident memory of one command, in kB.

    bench/maxrss.py COMMAND [ARGS ...]

Runs the command with its output discarded and prints the highest `VmHWM` its process reached.

The number is read at the last moment the process exists: it is started under ptrace with
PTRACE_O_TRACEEXIT, which stops it just before it exits, while /proc still holds its final
high-water mark. Polling /proc instead misses a command that lives a few hundred microseconds, and
the kernel's counter for waited-for children (`getrusage`) includes this interpreter's memory from
before the exec, which is larger than the whole of a small harness. Only exec and exit are traced.

A command that starts other processes is measured by the first one only. Linux only; it needs
permission to ptrace its own child, which the default `kernel.yama.ptrace_scope` gives.
"""

from __future__ import annotations

import ctypes
import os
import shutil
import signal
import sys
from contextlib import suppress
from functools import cache
from pathlib import Path
from typing import NoReturn

PTRACE_TRACEME = 0
PTRACE_CONT = 7
PTRACE_SETOPTIONS = 0x4200
PTRACE_O_TRACEEXEC = 0x10
PTRACE_O_TRACEEXIT = 0x40
PTRACE_EVENT_EXEC = 4
PTRACE_EVENT_EXIT = 6
EXEC_FAILED = 127

libc = ctypes.CDLL(None, use_errno=True)


@cache
def _libc_ptrace() -> object:
    """libc's `ptrace`, or False where libc has no such symbol.

    The lookup is the first call rather than three module-level lines because a
    host whose libc carries no `ptrace` raises `AttributeError` the moment the
    attribute is read, and reading it while the module loads put that traceback
    ahead of the refusal `main` gives on this platform, ahead of the argument
    check, and ahead of `main` itself. macOS is such a host, and `main` is
    written to send a macOS contributor one line saying the measurement is
    Linux's rather than a missing-symbol traceback ending in a name they then
    have to look up. Cached, so libc is asked once.
    """
    try:
        symbol = libc.ptrace
    except AttributeError:
        return False
    symbol.argtypes = [ctypes.c_long, ctypes.c_long, ctypes.c_void_p, ctypes.c_void_p]
    symbol.restype = ctypes.c_long
    return symbol


def hwm_kb(pid: int) -> int:
    for line in Path(f"/proc/{pid}/status").read_text(encoding="utf-8").splitlines():
        if line.startswith("VmHWM:"):
            return int(line.split()[1])
    raise RuntimeError(f"no VmHWM for traced process {pid}")


def ptrace(request: int, pid: int = 0, data: int = 0) -> None:
    call = _libc_ptrace()
    if call is False:
        raise RuntimeError("this host's libc has no ptrace; the measurement is Linux's")
    if call(request, pid, None, ctypes.c_void_p(data)) == -1:
        raise OSError(ctypes.get_errno(), "ptrace")


def exec_traced(exe: str, argv: list[str]) -> NoReturn:
    try:
        ptrace(PTRACE_TRACEME)
        devnull = os.open(os.devnull, os.O_RDWR)
        os.dup2(devnull, 1)
        os.dup2(devnull, 2)
        os.close(devnull)
        # because: running the command under measurement is the whole job of this script
        os.execv(exe, [exe, *argv[1:]])  # noqa: S606
    finally:
        os._exit(EXEC_FAILED)


def kill_traced(pid: int) -> None:
    with suppress(ProcessLookupError):
        os.kill(pid, signal.SIGKILL)
    while True:
        # Even SIGKILL waits for the tracer to resume an exit stop.
        with suppress(OSError):
            ptrace(PTRACE_CONT, pid, signal.SIGKILL)
        _, status = os.waitpid(pid, 0)
        if os.WIFEXITED(status) or os.WIFSIGNALED(status):
            return


def peak_rss_kb(argv: list[str]) -> int:
    exe = shutil.which(argv[0])
    if exe is None:
        raise SystemExit(f"maxrss.py: {argv[0]}: not found")
    pid = os.fork()
    if pid == 0:
        exec_traced(exe, argv)
    reaped = False
    try:
        _, status = os.waitpid(pid, 0)  # the stop the exec delivers
        reaped = os.WIFEXITED(status) or os.WIFSIGNALED(status)
        if reaped or os.WSTOPSIG(status) != signal.SIGTRAP:
            raise RuntimeError(f"{argv[0]} did not reach its exec stop; tracing or exec failed")
        ptrace(PTRACE_SETOPTIONS, pid, PTRACE_O_TRACEEXIT | PTRACE_O_TRACEEXEC)
        ptrace(PTRACE_CONT, pid)
        peak = 0
        while True:
            _, status = os.waitpid(pid, 0)
            if os.WIFEXITED(status) or os.WIFSIGNALED(status):
                reaped = True
                code = os.waitstatus_to_exitcode(status)
                if code != 0 or peak <= 0:
                    raise RuntimeError(f"{argv[0]} exited {code}; no successful measurement")
                return peak
            deliver = os.WSTOPSIG(status)
            if status >> 16 == PTRACE_EVENT_EXIT:
                peak = hwm_kb(pid)
                deliver = 0
            elif status >> 16 == PTRACE_EVENT_EXEC:
                deliver = 0
            ptrace(PTRACE_CONT, pid, deliver)
    finally:
        if not reaped:
            kill_traced(pid)


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
    try:
        peak = peak_rss_kb(sys.argv[1:])
    except (OSError, RuntimeError) as err:
        print(f"maxrss.py: {err}", file=sys.stderr)
        return 1
    print(peak)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
