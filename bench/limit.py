"""Run one benchmark command with a deadline and clean up its process group."""

from __future__ import annotations

import os
import select
import signal
import subprocess
import sys
import time
from contextlib import suppress


def ignore_interrupts() -> None:
    for signum in (signal.SIGINT, signal.SIGTERM):
        signal.signal(signum, signal.SIG_IGN)


def supervise(directory: str, argv: list[str], status_fd: int) -> None:
    """Keep the group leader alive after the command reports its exit status."""
    os.setsid()
    for signum in (signal.SIGINT, signal.SIGTERM):
        signal.signal(signum, signal.SIG_DFL)
    signal.pthread_sigmask(signal.SIG_SETMASK, [])
    try:
        # because: the benchmark caller supplies the command being measured
        child = subprocess.Popen(argv, cwd=directory)  # noqa: S603
    except OSError as error:
        print(f"run_limited: {error}", file=sys.stderr)
        result = 127 if isinstance(error, FileNotFoundError) else 126
    else:
        ignore_interrupts()
        result = child.wait()
    ignore_interrupts()
    os.write(status_fd, str(result).encode("ascii"))
    os.close(status_fd)
    while True:
        signal.pause()


def signal_group(pid: int, signum: int) -> None:
    try:
        os.killpg(pid, signum)
    except ProcessLookupError:
        # An interrupt may arrive before the supervisor has called setsid.
        with suppress(ProcessLookupError):
            os.kill(pid, signum)


def wait_status(fd: int, seconds: int) -> bool:
    deadline = time.monotonic() + seconds
    while (remaining := deadline - time.monotonic()) > 0:
        # Keep each native select timeout within its timestamp range.
        if select.select([fd], [], [], min(remaining, 86400))[0]:
            return True
    return False


def run(seconds: int, directory: str, argv: list[str]) -> int:
    """Retain the supervisor PID until the command's entire group is killed."""
    # ponytail: new sessions escape group cleanup; use a sandbox or cgroup for daemonizing commands.
    status_fd, child_fd = os.pipe()
    previous_mask = signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGINT, signal.SIGTERM})
    try:
        pid = os.fork()
    except OSError:
        os.close(status_fd)
        os.close(child_fd)
        signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)
        raise
    if pid == 0:
        os.close(status_fd)
        try:
            supervise(directory, argv, child_fd)
        finally:
            os._exit(1)
    os.close(child_fd)
    expired, interrupted, result = False, 0, b""

    def on_signal(signum: int, _frame: object) -> None:
        raise InterruptedError(signum)

    try:
        signal.signal(signal.SIGINT, on_signal)
        signal.signal(signal.SIGTERM, on_signal)
        signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)
        ready = wait_status(status_fd, seconds)
        if not ready:
            expired = True
            signal_group(pid, signal.SIGTERM)
            ready = wait_status(status_fd, 5)
        if ready:
            result = os.read(status_fd, 16)
    except InterruptedError as error:
        interrupted = error.args[0]
        ignore_interrupts()
        signal_group(pid, interrupted)
        wait_status(status_fd, 5)
    finally:
        ignore_interrupts()
        signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)
        # The supervisor's PID cannot be recycled until this final wait.
        # Kill the group before reaping, even when its command exited early.
        signal_group(pid, signal.SIGKILL)
        os.close(status_fd)
        os.waitpid(pid, 0)
    if interrupted:
        return 128 + interrupted
    if expired:
        return 124
    if not result:
        print("run_limited: supervisor exited without a command status", file=sys.stderr)
        return 1
    code = int(result)
    return code if code >= 0 else 128 - code


def main() -> int:
    if len(sys.argv) < 4 or not sys.argv[1].isascii() or not sys.argv[1].isdecimal():
        print("run_limited: expected positive seconds, directory and command", file=sys.stderr)
        return 2
    try:
        seconds = int(sys.argv[1])
    except ValueError:
        seconds = 0
    if not 1 <= seconds <= sys.maxsize:
        print("run_limited: seconds must be between 1 and the platform integer limit", file=sys.stderr)
        return 2
    return run(seconds, sys.argv[2], sys.argv[3:])


if __name__ == "__main__":
    sys.exit(main())
