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


def invoke(directory: Path, argv: list[str], *, env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
    root = Path(__file__).resolve().parent.parent
    # because: source the actual local shell wrapper and run only fixture commands
    return subprocess.run(  # noqa: S603
        ["/bin/sh", "-c", 'root=$1; shift; . "$root/bench/portable.sh"; run_limited "$@"', "fixture", str(root), *argv],
        cwd=directory,
        env=env,
        capture_output=True,
        text=True,
        timeout=9,
        check=False,
    )


def check() -> None:
    with tempfile.TemporaryDirectory() as temp:
        directory = Path(temp)
        unexpected = directory / "unexpected"
        result = invoke(directory, ["1", temp, "/bin/touch", str(unexpected)], env=dict(os.environ, PATH=""))
        expect(result.returncode == 2 and "python3 is required" in result.stderr, result.stderr)
        expect(not unexpected.exists(), "a measurement ran without its deadline runner")
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
            "if sys.argv[1] == 'flush':\n"
            " def stop(signum, frame):\n"
            "  time.sleep(0.1)\n"
            "  pathlib.Path('flushed').write_text(str(signum))\n"
            "  sys.exit(0)\n"
            " for signum in (signal.SIGINT, signal.SIGTERM): signal.signal(signum, stop)\n"
            "pathlib.Path('leader.ready').touch()\n"
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
        helper = Path(__file__).with_name("limit.py")
        ready = directory / "leader.ready"
        flushed = directory / "flushed"
        for mode, signum in (("ignore", signal.SIGTERM), ("flush", signal.SIGTERM), ("flush", signal.SIGINT)):
            marker.unlink(missing_ok=True)
            ready.unlink(missing_ok=True)
            flushed.unlink(missing_ok=True)
            # because: the local runner and a synthetic Python fixture
            with subprocess.Popen(  # noqa: S603
                [sys.executable, str(helper), "30", temp, sys.executable, str(leader), mode],
                cwd=directory,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            ) as process:
                try:
                    deadline = time.monotonic() + 3
                    while not ready.exists() and time.monotonic() < deadline:
                        time.sleep(0.01)
                    expect(ready.exists(), "the interrupt fixture did not start")
                    process.send_signal(signum)
                    _, errors = process.communicate(timeout=9)
                    expect(process.returncode == 128 + signum, errors)
                    expect(
                        mode != "flush" or (flushed.exists() and flushed.read_text() == str(signum)),
                        "the command could not flush on interruption",
                    )
                except BaseException:
                    cleanup_descendant(marker)
                    raise
                finally:
                    if process.poll() is None:
                        process.kill()


if __name__ == "__main__":
    check()
    print("Benchmark deadline and descendant cleanup checks passed")
