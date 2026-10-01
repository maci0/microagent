"""Check benchmark statuses, deadlines and descendant cleanup through POSIX sh."""

from __future__ import annotations

import os
import signal
import subprocess
import sys
import tempfile
import time
from contextlib import suppress
from pathlib import Path


def expect(condition: object, detail: object) -> None:
    if not condition:
        raise AssertionError(detail)


def cleanup_descendant(marker: Path) -> None:
    if marker.exists():
        with suppress(ProcessLookupError):
            pid = int(marker.read_text())
            group = os.getpgid(pid)
            if group != os.getpgrp():
                os.killpg(group, signal.SIGKILL)
            else:
                os.kill(pid, signal.SIGKILL)


def invoke(directory: Path, argv: list[str]) -> subprocess.CompletedProcess[str]:
    root = Path(__file__).resolve().parent.parent
    # because: source the actual local shell wrapper and run only fixture commands
    return subprocess.run(  # noqa: S603
        ["/bin/sh", "-c", 'root=$1; shift; . "$root/bench/portable.sh"; run_limited "$@"', "fixture", str(root), *argv],
        cwd=directory,
        capture_output=True,
        text=True,
        timeout=9,
        check=False,
    )


def check() -> None:
    with tempfile.TemporaryDirectory() as temp:
        directory = Path(temp)
        for seconds in ("0", "-1", "1.5", "\uff11", str(sys.maxsize + 1)):
            result = invoke(directory, [seconds, temp, "/bin/true"])
            expect(result.returncode == 2, result.stderr)
        result = invoke(directory, [str(sys.maxsize), temp, "/bin/true"])
        expect(result.returncode == 0, result.stderr)
        for command, expected in (
            (["/bin/sh", "-c", "exit 7"], 7),
            ([str(directory / "missing")], 127),
            (["/bin/sh", "-c", "kill -TERM $$"], 143),
        ):
            result = invoke(directory, ["1", temp, *command])
            expect(result.returncode == expected, result.stderr)
        leader = directory / "leader.py"
        leader.write_text(
            "import os, pathlib, signal, subprocess, sys, time\n"
            "child = subprocess.Popen([sys.executable, '-c', "
            "'import os, pathlib, signal; signal.signal(signal.SIGTERM, signal.SIG_IGN); "
            'pathlib.Path("descendant.pid").write_text(str(os.getpid())); signal.pause()' + "'])\n"
            "while not pathlib.Path('descendant.pid').exists(): time.sleep(0.01)\n"
            "if sys.argv[1] == 'normal': sys.exit(0)\n"
            "if sys.argv[1] == 'ignore': signal.signal(signal.SIGTERM, signal.SIG_IGN)\n"
            "signal.pause()\n",
            encoding="utf-8",
        )
        marker = directory / "descendant.pid"
        for mode, expected in (("normal", 0), ("term", 124), ("ignore", 124)):
            try:
                result = invoke(directory, ["1", temp, sys.executable, str(leader), mode])
                expect(marker.exists(), result.stderr)
                expect(result.returncode == expected, result.stderr)
                # The descendant holds stdout open while paused. communicate
                # returning proves it was killed, even if the OS has a zombie.
            except BaseException:
                cleanup_descendant(marker)
                raise
            finally:
                marker.unlink(missing_ok=True)
        # Interrupt the actual runner while its command and descendant ignore
        # TERM; its own handler must still kill the group and return promptly.
        helper = Path(__file__).with_name("limit.py")
        # because: the local deadline runner and synthetic Python fixture
        with subprocess.Popen(  # noqa: S603
            [sys.executable, str(helper), "30", temp, sys.executable, str(leader), "ignore"],
            cwd=directory,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        ) as process:
            try:
                deadline = time.monotonic() + 3
                while not marker.exists() and time.monotonic() < deadline:
                    time.sleep(0.01)
                expect(marker.exists(), "the interrupt fixture did not start")
                process.send_signal(signal.SIGTERM)
                _, errors = process.communicate(timeout=3)
                expect(process.returncode == 143, errors)
            except BaseException:
                cleanup_descendant(marker)
                raise
            finally:
                if process.poll() is None:
                    process.kill()


if __name__ == "__main__":
    check()
    print("Benchmark deadline and descendant cleanup checks passed")
