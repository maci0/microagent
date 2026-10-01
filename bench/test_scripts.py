"""Check benchmark and SBOM failure reporting with local command stand-ins."""

from __future__ import annotations

import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def expect(condition: object, detail: object) -> None:
    if not condition:
        raise AssertionError(detail)


def executable(path: Path, body: str) -> None:
    path.write_text(f"#!{sys.executable}\n{body}", encoding="utf-8")
    path.chmod(0o700)


def run(script: Path, *args: str, env: dict[str, str], **changes: str) -> subprocess.CompletedProcess[str]:
    # because: actual local scripts, with synthetic commands and no provider requests
    return subprocess.run(  # noqa: S603
        ["/bin/sh", str(script), *args],
        cwd=ROOT,
        env=dict(env, **changes),
        capture_output=True,
        text=True,
        timeout=15,
        check=False,
    )


def check() -> None:
    with tempfile.TemporaryDirectory() as temp:
        directory = Path(temp)
        commands = directory / "bin"
        commands.mkdir()
        env = dict(os.environ, PATH=f"{commands}{os.pathsep}{os.environ['PATH']}", BENCH_WORK=str(directory / "work"))

        executable(commands / "broken-bench-agent", "import sys\nsys.exit(0 if sys.argv[1] == '--version' else 7)\n")
        executable(
            commands / "hyperfine",
            "import pathlib,sys\n"
            "destination = pathlib.Path(sys.argv[sys.argv.index('--export-json') + 1])\n"
            'destination.write_text(\'{"results":[{"mean":0.001}]}\')\n',
        )
        result = run(ROOT / "bench/overhead.sh", "broken-bench-agent", env=env)
        expect(result.returncode == 1 and "fail(7)" in result.stdout, result)

        check_instructions(directory, env)

        record = directory / "harbor.json"
        executable(
            commands / "harbor",
            "import json,os,pathlib,sys\n"
            "pathlib.Path(os.environ['RECORD']).write_text(json.dumps(sys.argv[1:]))\n"
            "sys.exit(int(os.environ.get('HARBOR_EXIT', '0')))\n",
        )
        executable(
            commands / "summary-python",
            "import os,sys\n"
            "if sys.argv[1].endswith('summarize.py'): sys.exit(int(os.environ.get('SUMMARY_EXIT', '0')))\n"
            f"os.execv({sys.executable!r}, [{sys.executable!r}, *sys.argv[1:]])\n",
        )
        env.update(
            HARBOR=str(commands / "harbor"),
            PYTHON=str(commands / "summary-python"),
            RECORD=str(record),
            PROVIDER="deepseek",
            MICROAGENT_API_KEY="synthetic-fixture",
            TASKS="fixture",
            JOBS_DIR=str(directory / "jobs"),
        )
        for url, host in (
            ("https://proxy.example.test/v1", "proxy.example.test"),
            ('https://proxy.example.test/v1?x="quoted"', "proxy.example.test"),
            ("http://[::1]:8123/v1", "::1"),
        ):
            result = run(ROOT / "bench/harbor.sh", "deepswe", "opencode", env=env, MICROAGENT_BASE_URL=url)
            expect(result.returncode == 0, result)
            argv = json.loads(record.read_text())
            expect(argv[argv.index("--allow-agent-host") + 1] == host, argv)
            config = next(value.split("=", 1)[1] for value in argv if value.startswith("opencode_config="))
            expect(json.loads(config)["provider"]["deepseek"]["options"]["baseURL"] == url, config)
        for changes, status in (({"HARBOR_EXIT": "7"}, 7), ({"SUMMARY_EXIT": "9"}, 9)):
            result = run(
                ROOT / "bench/harbor.sh",
                "deepswe",
                "microagent",
                env=env,
                MICROAGENT_BASE_URL="https://proxy.example.test/v1",
                **changes,
            )
            expect(result.returncode == status, result)
        record.unlink()
        result = run(
            ROOT / "bench/harbor.sh",
            "deepswe",
            "microagent",
            env=env,
            MICROAGENT_BASE_URL="https://proxy.example.test:bad/v1",
        )
        expect(result.returncode == 2 and not record.exists(), result)
        expect(not list((directory / "jobs").glob(".harbor-log-*")), "Harbor output logs were left behind")

        check_sbom(directory, env)
        check_rows(directory, env)


def check_instructions(directory: Path, env: dict[str, str]) -> None:
    commands = directory / "bin"
    # Isolate the instruction script's cached build options; its fake
    # compiler emits the same test-count/status interface as a Zig test.
    fixture = directory / "checkout"
    (fixture / "bench").mkdir(parents=True)
    (fixture / ".zig-cache/c/options").mkdir(parents=True)
    (fixture / ".zig-cache/c/options/options.zig").touch()
    instructions = fixture / "bench/instructions.sh"
    instructions.write_bytes((ROOT / "bench/instructions.sh").read_bytes())
    (fixture / "bench/instructions.baseline").write_bytes((ROOT / "bench/instructions.baseline").read_bytes())
    executable(
        commands / "zig",
        "import os,pathlib,sys\n"
        f"if sys.argv[1] == 'env': print('.lib_dir = \"{fixture}\",'); sys.exit(0)\n"
        "args = sys.argv[1:]\n"
        "output = pathlib.Path(next(a.split('=', 1)[1] for a in args if a.startswith('-femit-bin=')))\n"
        "count = 1 if args[args.index('--test-filter') + 1] == 'zzzz_no_such_test' else 2\n"
        "code = os.environ.get('TEST_EXIT', '0') if count == 2 else '0'\n"
        "line = '' if os.environ.get('NO_COUNT') else f'All {count} tests passed.'\n"
        'output.write_text(f\'#!/bin/sh\\nprintf \\"%s\\\\n\\" \\"{line}\\"\\nexit {code}\\n\')\n'
        "output.chmod(0o700)\n",
    )
    executable(
        commands / "perf",
        "import os,pathlib,sys\n"
        "count = 20000 if 'All 2' in pathlib.Path(sys.argv[-1]).read_text() else 10000\n"
        "if count == 20000 and os.environ.get('LOW_COUNT'): count = 9999\n"
        "print(f'{count} instructions', file=sys.stderr)\n"
        "sys.exit(int(os.environ.get('PERF_EXIT', '0')))\n",
    )
    env.update(ZIG=str(commands / "zig"), RUNS="2", TOLERANCE="10")
    result = run(instructions, env=env)
    expect(result.returncode == 0, result)
    for changes in (
        {"TEST_EXIT": "7"},
        {"PERF_EXIT": "7"},
        {"NO_COUNT": "1"},
        {"RUNS": "0"},
        {"RUNS": "invalid"},
        {"TOLERANCE": "-1"},
    ):
        result = run(instructions, env=env, **changes)
        expect(result.returncode == 2, result)
    result = run(instructions, "--check", env=env, TOLERANCE=str(sys.maxsize))
    expect(result.returncode == 0, result)
    result = run(instructions, "--check", env=env, LOW_COUNT="1")
    expect(result.returncode == 2, result)
    baseline = fixture / "bench/instructions.baseline"
    original_baseline = baseline.read_bytes()
    try:
        baseline.unlink()
        result = run(instructions, "--check", env=env)
        expect(result.returncode == 2, result)
    finally:
        baseline.write_bytes(original_baseline)


def check_sbom(directory: Path, env: dict[str, str]) -> None:
    commands = directory / "bin"
    # A hash command can print a plausible digest and still fail. Both
    # status and digest shape matter, and a failure preserves the old SBOM.
    hash_body = (
        "import hashlib,os,pathlib,sys\n"
        "name = pathlib.Path(sys.argv[0]).name\n"
        "data = pathlib.Path(sys.argv[1]).read_bytes() if len(sys.argv) > 1 else sys.stdin.buffer.read()\n"
        "value = getattr(hashlib, name)(data).hexdigest()\n"
        "mode = os.environ.get('HASH_MODE', 'good') if os.environ.get('HASH_NAME') == name else 'good'\n"
        "if mode != 'empty': print(('x' if mode == 'invalid' else value) + '  -')\n"
        "sys.exit(7 if mode == 'fail' else 0)\n"
    )
    for name in ("sha1", "sha256"):
        executable(commands / name, hash_body)
    dist = directory / "dist"
    dist.mkdir()
    content = b"synthetic release asset"
    (dist / "microagent-v0.10.1-x86_64-linux-musl").write_bytes(content)
    env.update(SHA1_CMD=str(commands / "sha1"), SHA256_CMD=str(commands / "sha256"), SOURCE_DATE_EPOCH="1720000000")
    result = run(ROOT / "scripts/sbom.sh", str(dist), "lint-requirements.txt", env=env)
    expect(result.returncode == 0, result)
    report = dist / "microagent-v0.10.1.spdx.json"
    original = report.read_bytes()
    parsed = json.loads(original)
    # because: SPDX package verification mandates SHA1; this is a format check, not authentication
    expected = hashlib.sha1(hashlib.sha1(content).hexdigest().encode()).hexdigest()  # noqa: S324
    expect(parsed["packages"][0]["packageVerificationCode"]["packageVerificationCodeValue"] == expected, parsed)
    expect(parsed["files"][0]["checksums"][0]["checksumValue"] == hashlib.sha256(content).hexdigest(), parsed)
    for name in ("sha1", "sha256"):
        for mode in ("fail", "empty", "invalid"):
            result = run(
                ROOT / "scripts/sbom.sh", str(dist), "lint-requirements.txt", env=env, HASH_NAME=name, HASH_MODE=mode
            )
            expect(result.returncode != 0 and report.read_bytes() == original, result)


def check_rows(directory: Path, env: dict[str, str]) -> None:
    fixture = directory / "rows"
    bench = fixture / "bench"
    task = bench / "tasks/fixture"
    task.mkdir(parents=True)
    for name in ("run.sh", "gauntlet.sh", "monotonic.sh", "portable.sh", "limit.py"):
        (bench / name).write_bytes((ROOT / "bench" / name).read_bytes())
    (task / "setup.sh").write_text("printf '%s\\n' fixture > answer.txt\n")
    (task / "check.sh").write_text("exit 0\n")
    (task / "prompt.txt").write_text("Synthetic fixture\n")
    git = shutil.which("git")
    expect(git is not None, "Git is required for the benchmark fixture")
    # because: initialize only this private temporary checkout for the real benchmark clone
    subprocess.run([git, "init", "-q", str(fixture)], check=True)  # noqa: S603
    # because: stage the synthetic checkout, without touching this project's index
    subprocess.run([git, "-C", str(fixture), "add", "-A"], check=True)  # noqa: S603
    # because: record the fixture commit that gauntlet.sh checks out
    subprocess.run(  # noqa: S603
        [
            git,
            "-C",
            str(fixture),
            "-c",
            "user.email=fixture@example.test",
            "-c",
            "user.name=fixture",
            "commit",
            "-qm",
            "fixture",
        ],
        check=True,
    )
    body = (
        "import os,shutil\n"
        "if os.environ.get('GIT_FAIL'): shutil.rmtree('.git')\n"
        "print('  Passed: 1')\nprint('  Failed: 0')\nprint('Tokens: 12,345')\n"
        "print('{\"total_tokens\":123}')\n"
    )
    for name in ("row-agent", "gauntlet"):
        executable(directory / "bin" / name, body)
    run_id = 'fixture"\\\nrun'
    env = dict(env, BENCH_RUN_ID=run_id, GAUNTLET_RUN_ID=run_id, GAUNTLET_WORK=str(directory / "reviews"))
    for name, results, agent in (
        ("run.sh", "results.jsonl", "row-agent"),
        ("gauntlet.sh", "gauntlet-results.jsonl", 'row-agent:model"\\tag'),
    ):
        for fail in ("", "1"):
            result = run(bench / name, agent, env=env, GIT_FAIL=fail)
            expect(result.returncode == 0, result)
            row = json.loads((bench / results).read_text().splitlines()[-1])
            expect(row["run"] == run_id and row["agent"] == agent, row)
            if fail:
                expect(row.get("lines") == "n/a" if name == "run.sh" else row["changed_files"] is None, row)
    check_parallel(fixture, env)


def check_parallel(fixture: Path, env: dict[str, str]) -> None:
    commands = Path(env["PATH"].split(os.pathsep)[0])
    body = (
        "import os,pathlib,time\n"
        "fd = os.open(os.environ['CALLS'], os.O_CREAT | os.O_WRONLY | os.O_APPEND, 0o600)\n"
        "os.write(fd, (str(pathlib.Path.cwd()) + '\\n').encode()); os.close(fd)\n"
        "while not pathlib.Path(os.environ['RELEASE']).exists(): time.sleep(0.01)\n"
        "print('  Passed: 1')\nprint('  Failed: 0')\nprint('Tokens: 123')\n"
    )
    for name in ("row-agent", "gauntlet"):
        executable(commands / name, body)
    for name in ("run.sh", "gauntlet.sh"):
        calls = fixture / "calls"
        release = fixture / "release"
        calls.unlink(missing_ok=True)
        release.unlink(missing_ok=True)
        processes = []
        try:
            for count in (1, 2):
                processes.append(
                    # because: overlapping actual scripts run only the local waiting fixture
                    subprocess.Popen(  # noqa: S603
                        ["/bin/sh", str(fixture / "bench" / name), "row-agent"],
                        env=dict(env, CALLS=str(calls), RELEASE=str(release)),
                        stdout=subprocess.PIPE,
                        stderr=subprocess.PIPE,
                    )
                )
                deadline = time.monotonic() + 5
                while (
                    not calls.exists() or len(calls.read_text().splitlines()) < count
                ) and time.monotonic() < deadline:
                    time.sleep(0.01)
                expect(
                    calls.exists() and len(calls.read_text().splitlines()) == count,
                    "a parallel benchmark did not start",
                )
            directories = calls.read_text().splitlines()
            release.touch()
            for process in processes:
                _, errors = process.communicate(timeout=15)
                expect(process.returncode == 0, errors)
            expect(len(set(directories)) == 2, f"{name} reused a live work directory: {directories}")
        finally:
            release.touch()
            for process in processes:
                process.communicate(timeout=15)


if __name__ == "__main__":
    check()
    print("Benchmark and SBOM command failure checks passed")
