"""Check benchmark and release gate failures with local command stand-ins."""

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
        if sys.argv[1:] == ["--workflows"]:
            check_workflows(directory, env)
            return

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
        ceilings = directory / "harbor-env.json"
        executable(
            commands / "harbor",
            "import json,os,pathlib,sys\n"
            "pathlib.Path(os.environ['RECORD']).write_text(json.dumps(sys.argv[1:]))\n"
            "pathlib.Path(os.environ['RECORD_ENV']).write_text(json.dumps({\n"
            "    name: os.environ[name]\n"
            "    for name in (\n"
            "        'MICROAGENT_AGENT_TIMEOUT_SEC',\n"
            "        'MICROAGENT_BUDGET_SECONDS',\n"
            "        'MICROAGENT_MAX_TURNS',\n"
            "    )\n"
            "    if name in os.environ\n"
            "}))\n"
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
            RECORD_ENV=str(ceilings),
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

        # The three ceilings the microagent arm fixes are defaults, so an
        # operator who exported one of them gets theirs: a value written in
        # front of the command won over the environment silently, and the trial
        # ran under a ceiling nobody chose.
        check_harbor_ceilings(ROOT, env, record, ceilings)
        check_sbom(directory, env)
        check_rows(directory, env)
        check_locks(directory, env)
        check_changelog_order(directory, env)


def check_harbor_ceilings(root: Path, env: dict[str, str], record: Path, ceilings: Path) -> None:
    """A ceiling the operator exported reaches the harness run unchanged.

    The microagent arm of `bench/harbor.sh` fills in the agent timeout, the
    working budget and the turn ceiling for a benchmark, because a run without
    them inherits the adapter's own defaults and a benchmark is scored against
    the figure in `docs/benchmark.md`. They are defaults and not overrides:
    written in front of the command they beat the environment, so an operator
    who raised the turn ceiling for a trial set of their own got the script's
    number instead, and nothing said so.
    """
    names = ("MICROAGENT_AGENT_TIMEOUT_SEC", "MICROAGENT_BUDGET_SECONDS", "MICROAGENT_MAX_TURNS")
    result = run(root / "bench/harbor.sh", "deepswe", "microagent", env=env)
    expect(result.returncode == 0, result)
    chosen = json.loads(ceilings.read_text())
    for name in names:
        # A benchmark number, so this run is the one docs/benchmark.md reports.
        expect(int(chosen.get(name, "0")) > 0, f"{name} is not set by the benchmark: {chosen}")
    record.unlink(missing_ok=True)

    asked = {name: str(number) for name, number in zip(names, ("7", "300", "40"), strict=True)}
    result = run(root / "bench/harbor.sh", "deepswe", "microagent", env=env, **asked)
    expect(result.returncode == 0, result)
    given = json.loads(ceilings.read_text())
    for name, value in asked.items():
        expect(given.get(name) == value, f"{name} exported by the operator was replaced: {given}")
    record.unlink(missing_ok=True)


def check_changelog_order(directory: Path, env: dict[str, str]) -> None:
    """The changelog history target must not depend on a GNU-only sort.

    `sort -V` is a GNU extension BSD sort has no spelling of, so the macOS
    runners this repository publishes binaries for answered it with an
    "illegal option", the version list came back empty, and the target
    reported success over a CHANGELOG it had never opened. `set -e` does
    not catch that: the pipeline is the last command of a substitution read
    as a for-list, which the shell evaluates before the loop and ignores the
    status of. A BSD-style `sort` on PATH reproduces it exactly, and a
    CHANGELOG with no released version proves the empty list is refused
    rather than passed over.
    """
    fixture = directory / "changelog"
    fixture.mkdir()
    shutil.copy2(ROOT / "Makefile", fixture / "Makefile")
    shutil.copy2(ROOT / "build.zig.zon", fixture / "build.zig.zon")
    git = shutil.which("git")
    expect(git is not None, "Git is required for the changelog fixture")
    # because: the Makefile reads its file lists through git, in a private temporary checkout
    subprocess.run([git, "init", "-q", str(fixture)], check=True)  # noqa: S603
    # The 0.y rule is not what this checks, so the copy carries one section
    # per shape the ordering has to get right: a double-digit minor is the
    # whole reason `sort -V` was reached for in the first place.
    (fixture / "CHANGELOG.md").write_text(
        "## [Unreleased]\n\n### Added\n\n- nothing yet\n\n"
        + "".join(
            f"## [0.{minor}.0] - 2026-01-0{index + 1}\n\n### Added\n\n- note\n\n"
            for index, minor in enumerate((1, 2, 9, 10, 11))
        ),
        encoding="utf-8",
    )
    system_sort = shutil.which("sort")
    expect(system_sort is not None, "sort is required to build the BSD stand-in")
    bsd_sort = directory / "bin" / "sort"
    bsd_sort.write_text(
        "#!/bin/sh\n"
        "# A BSD sort(1) stand-in: -V, --version-sort and --parallel have no\n"
        "# spelling there, and a flag it has no spelling for is answered the\n"
        "# way it is answered there.\n"
        'for argument in "$@"; do\n'
        '  case "$argument" in\n'
        "    -V|--version-sort|--parallel) echo 'sort: illegal option' >&2; exit 2;;\n"
        "  esac\n"
        "done\n"
        f'exec {system_sort} "$@"\n',
        encoding="utf-8",
    )
    bsd_sort.chmod(0o700)
    make = shutil.which("make")
    expect(make is not None, "make is required to run the changelog target")
    made = dict(env, PATH=f"{directory / 'bin'}{os.pathsep}{env['PATH']}")
    # because: this repository's own target, over a synthetic changelog in a temporary directory
    result = subprocess.run(  # noqa: S603
        [make, "--no-print-directory", "check-changelog-history"],
        cwd=fixture,
        env=made,
        capture_output=True,
        text=True,
        timeout=60,
        check=False,
    )
    expect(result.returncode == 0, result)
    # The empty list is a finding, not a green run over nothing.
    (fixture / "CHANGELOG.md").write_text("## [Unreleased]\n\n### Added\n\n- nothing yet\n", encoding="utf-8")
    # because: this repository's own target, over a changelog the empty-list case wrote
    result = subprocess.run(  # noqa: S603
        [make, "--no-print-directory", "check-changelog-history"],
        cwd=fixture,
        env=made,
        capture_output=True,
        text=True,
        timeout=60,
        check=False,
    )
    expect(result.returncode != 0 and "names no released version" in result.stderr, result)


def check_locks(directory: Path, env: dict[str, str]) -> None:
    manifest = directory / "manifest.txt"
    lock = directory / "lock.txt"
    # A requirement the manifest does not pin to one exact version, and the
    # lock that resolves it, which is what the range's install-time resolution
    # writes. A range reads the same three answers as an exact pin from the
    # checks already here, so only the exactness rule can refuse it: `>=`
    # resolves to the newest release the index offers at install time, so the
    # hash the lock carries and the version the gate checked are the pair a run
    # installs on the next machine that no reviewed artifact describes.
    lock.write_text(f"ruff==0.16.4 \\\n    --hash=sha256:{'a' * 64}\n    # via -r {manifest}\n", encoding="utf-8")
    for requirement in (
        "ruff>=0.16.4",
        "ruff~=0.16.4",
        "ruff!=0.16.4",
        "ruff==0.16.*",
        "ruff",
        "ruff==0.16.4 ; sys_platform == 'linux' ",
    ):
        manifest.write_text(requirement + "\n", encoding="utf-8")
        result = run(ROOT / "scripts/lint-lock.sh", str(manifest), str(lock), env=env)
        expect(result.returncode != 0 and "does not pin every requirement" in result.stderr, result)
    # The comment header is not a requirement, so a manifest that names a pin in
    # its prose and pins one package exactly is accepted: the rule asks what the
    # manifest requires, not what it says.
    manifest.write_text("# ruff>=0.16.4 is what an earlier tree asked for\nruff==0.16.4\n", encoding="utf-8")
    result = run(ROOT / "scripts/lint-lock.sh", str(manifest), str(lock), env=env)
    expect(result.returncode == 0, result)

    manifest.write_text("ruff==0.16.4\n", encoding="utf-8")
    for version, hashes, passed in (
        ("0.16.4", ["a" * 64], True),
        ("0.16.4", ["A" * 64, "b" * 64], True),
        ("0.16+4", ["a" * 64], False),
        ("0.16.40", ["a" * 64], False),
        ("0.16.4", [], False),
        ("0.16.4", [""], False),
        ("0.16.4", ["a" * 63], False),
        ("0.16.4", ["a" * 65], False),
        ("0.16.4", ["z" * 64], False),
        ("0.16.4", ["a" * 64, "garbage"], False),
    ):
        lock.write_text(
            f"ruff=={version} \\\n"
            + "".join(f"    --hash=sha256:{digest} \\\n" for digest in hashes)
            + f"    # via -r {manifest}\n",
            encoding="utf-8",
        )
        result = run(ROOT / "scripts/lint-lock.sh", str(manifest), str(lock), env=env)
        expect((result.returncode == 0) == passed, result)
    for pin, entry in (("Ruff==0.16.4", "ruff==0.16.4"), ("Foo__Bar==1.0", "foo-bar==1.0")):
        manifest.write_text(pin + "\n", encoding="utf-8")
        for suffix in ("", ".old"):
            lock.write_text(
                f"{entry} \\\n    --hash=sha256:{'a' * 64}\n    # via -r {manifest}{suffix}\n", encoding="utf-8"
            )
            result = run(ROOT / "scripts/lint-lock.sh", str(manifest), str(lock), env=env)
            expect((result.returncode == 0) == (not suffix), result)


def check_workflows(directory: Path, env: dict[str, str]) -> None:
    # The workflow-level invariants lint-actions.sh enforces, so a fixture built
    # to test one rule is not refused by one of the others: every fixture built
    # to test something else carries a permissions block, a concurrency group
    # and a timeout. The block at the end of this function takes exactly one
    # invariant out of a fixture at a time, which is what those two lines are
    # for.
    header = "permissions:\n  contents: read\nconcurrency:\n  group: ci-${{ github.ref }}\n  cancel-in-progress: true\n"
    job = "  lint:\n    runs-on: ubuntu-24.04\n    timeout-minutes: 5\n    steps:\n"
    workflow = directory / "workflow.yml"
    composite = directory / "action.yml"
    record = directory / "shell-bodies.json"
    checker = directory / "bin/shellcheck"
    executable(
        checker,
        "import json,os,pathlib,sys\n"
        "bodies = [pathlib.Path(arg).read_text() for arg in sys.argv[1:] if arg.endswith('.sh')]\n"
        "pathlib.Path(os.environ['SHELL_BODIES']).write_text(json.dumps(bodies))\n",
    )
    values = (
        ("'printf \"%s\\n\" ok'", 'printf "%s\\n" ok'),
        ('"printf \\"%s\\\\n\\" ok"', 'printf "%s\\n" ok'),
        ("|+\n          echo ok\n", "echo ok\n\n"),
        ("|2-\n          echo ok", "echo ok"),
        (">-\n          printf '%s\\n'\n          ok", "printf '%s\\n' ok"),
        ("|\n          cat <<EOF\n          run: hello\n          EOF", "cat <<EOF\nrun: hello\nEOF\n"),
        ("|\n\n          echo ok", "\necho ok\n"),
        ("echo \"${{ format('{0}', 'ok') }}\"", 'echo "github_expr"'),
        ("echo \"${{ 'it''s }} quoted' }}\"", 'echo "github_expr"'),
        (
            "|-\n          echo \"${{\n            format('{0}', 'ok')\n          }}\"\n          echo ok",
            'echo "github_expr\\\n\\\n"\necho ok',
        ),
    )
    workflow.write_text(
        header + "jobs:\n" + job + "".join(f"      - run: {scalar}\n" for scalar, _ in values), encoding="utf-8"
    )
    composite.write_text(
        "runs:\n  using: composite\n  steps:\n    - run: echo action\n      shell: bash\n", encoding="utf-8"
    )
    try:
        result = run(
            ROOT / "scripts/lint-ci-shell.sh", str(workflow), str(composite), env=env, SHELL_BODIES=str(record)
        )
        expect(result.returncode == 0, result)
        bodies = json.loads(record.read_text(encoding="utf-8"))
        expect(len(bodies) == len(values) + 1, bodies)
        for body, expected in zip(bodies, [*(value for _, value in values), "echo action"], strict=True):
            expect(body.endswith(expected + "\n"), body)
    finally:
        checker.unlink()
    # Use the actual checker for diagnostics and original source locations.
    for scalar, line in (
        ("'echo \"$missing\"'", 4),
        ('|+\n          echo "$missing"', 5),
        (
            "|-\n          echo \"${{\n            format('{0}', 'ok')\n          }}\"\n          echo \"$missing\"",
            8,
        ),
    ):
        workflow.write_text(header + "jobs:\n" + job + f"      - run: {scalar}\n", encoding="utf-8")
        result = run(ROOT / "scripts/lint-ci-shell.sh", str(workflow), env=env)
        expect(result.returncode != 0 and "SC2154" in result.stdout, result)
        expect(f"In {workflow} line {line + header.count(chr(10)) + 2}:" in result.stdout, result)
    for ref, passed in (
        ("'owner/action@" + "a" * 40 + "' # v7.0.1", True),
        ("./.github/actions/local", True),
        ("owner/action@v7", False),
        ("owner/action@" + "a" * 40 + " # v", False),
    ):
        workflow.write_text(
            header + "jobs:\n" + job + f"      - uses: {ref}\n"
            "      - run: |\n          cat <<EOF\n          - uses: fake/action@v1\n          EOF\n",
            encoding="utf-8",
        )
        result = run(ROOT / "scripts/lint-actions.sh", str(workflow), env=env)
        expect((result.returncode == 0) == passed, result)
    pin = "owner/action@" + "a" * 40
    for prefix, indent in (
        (header + "jobs:\n" + job + "      - uses: ", "          "),
        (header + "jobs:\n  lint:\n    timeout-minutes: 5\n    uses: ", "      "),
        ("runs:\n  using: composite\n  steps:\n    - uses: ", "        "),
    ):
        for ref, passed in (
            (pin, True),
            ("owner/action@v7", False),
            (f">-\n{indent}{pin}", True),
            (f"|-\n{indent}{pin}", True),
            (f">- # v\n{indent}{pin}", False),
        ):
            workflow.write_text(prefix + ref + "\n", encoding="utf-8")
            result = run(ROOT / "scripts/lint-actions.sh", str(workflow), env=env)
            expect((result.returncode == 0) == passed, result)
            expect("Traceback" not in result.stderr, result)
    workflow.write_text(
        header + "jobs:\n" + job + f"      - uses: >-\n          {pin}\n      - run: echo ok # v\n",
        encoding="utf-8",
    )
    result = run(ROOT / "scripts/lint-actions.sh", str(workflow), env=env)
    expect(result.returncode == 0, result)
    workflow.write_text("jobs: [\n", encoding="utf-8")
    result = run(ROOT / "scripts/lint-ci-shell.sh", str(workflow), env=env)
    expect(result.returncode != 0 and str(workflow) in result.stderr, result)

    # The runner semantics lint-ci-shell.sh cannot see, one at a time: each
    # fixture below is the whole invariants-carrying workflow with exactly one
    # of them taken out, and each is refused for the reason it names.
    for name, body, said in (
        (
            "no concurrency group",
            "permissions:\n  contents: read\njobs:\n" + job + "      - run: echo ok\n",
            "concurrency:",
        ),
        (
            "no permissions",
            "jobs:\n" + job + "      - run: echo ok\n",
            "permissions:",
        ),
        (
            "no ceiling",
            "jobs:\n  lint:\n    runs-on: ubuntu-24.04\n    steps:\n      - run: echo ok\n",
            "timeout-minutes",
        ),
        (
            "write-all at the workflow",
            "permissions: write-all\nconcurrency:\n  group: g\n" + "jobs:\n" + job + "      - run: echo ok\n",
            "write-all",
        ),
        (
            "write-all in a job",
            (
                "permissions:\n  contents: read\nconcurrency:\n  group: g\n"
                "jobs:\n  lint:\n    runs-on: ubuntu-24.04\n    timeout-minutes: 5\n"
                "    permissions: write-all\n    steps:\n      - run: echo ok\n"
            ),
            "write-all",
        ),
        (
            "a checkout that keeps its credentials",
            header + "jobs:\n" + job + "      - uses: actions/checkout@" + "a" * 40 + " # v7.0.1\n",
            "persist-credentials",
        ),
        (
            "a composite step with no shell",
            "runs:\n  using: composite\n  steps:\n    - run: echo ok\n",
            "no shell:",
        ),
    ):
        workflow.write_text(body, encoding="utf-8")
        result = run(ROOT / "scripts/lint-actions.sh", str(workflow), env=env)
        expect(result.returncode != 0 and said in result.stderr, f"{name}: {result}")
        expect("Traceback" not in result.stderr, f"{name}: {result}")

    # The workflow the gate accepts is the one the tree ships: every file
    # `make lint-ci` hands the checker passes, and a rule that fired on one of
    # them would be a rule the gate itself cannot satisfy.
    for name in ("ci.yml", "release.yml"):
        result = run(
            ROOT / "scripts/lint-actions.sh",
            str(ROOT / ".github/workflows" / name),
            env=env,
        )
        expect(result.returncode == 0, f"{name}: {result}")
    for name in ("setup-zig", "setup-linters"):
        result = run(
            ROOT / "scripts/lint-actions.sh",
            str(ROOT / ".github/actions" / name / "action.yml"),
            env=env,
        )
        expect(result.returncode == 0, f"{name}: {result}")


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
    env.update(
        SHA1_CMD=str(commands / "sha1"),
        SHA256_CMD=str(commands / "sha256"),
        SOURCE_DATE_EPOCH="1720000000",
        ZIG_VERSION="0.16.0",
    )
    result = run(ROOT / "scripts/sbom.sh", str(dist), "lint-requirements.txt", env=env)
    expect(result.returncode == 0, result)
    report = dist / "microagent-v0.10.1.spdx.json"
    original = report.read_bytes()
    parsed = json.loads(original)
    # because: SPDX package verification mandates SHA1; this is a format check, not authentication
    expected = hashlib.sha1(hashlib.sha1(content).hexdigest().encode()).hexdigest()  # noqa: S324
    expect(parsed["packages"][0]["packageVerificationCode"]["packageVerificationCodeValue"] == expected, parsed)
    expect(parsed["files"][0]["checksums"][0]["checksumValue"] == hashlib.sha256(content).hexdigest(), parsed)
    # The compiler is the one input to these assets that nothing else records,
    # so an inventory that dropped it describes binaries nobody can rebuild.
    expect("Tool: zig 0.16.0" in parsed["creationInfo"]["creators"], parsed)
    # An empty or unreadable toolchain fails rather than writing a document that
    # names none: a Creator list with no compiler in it is no record of anything.
    for bad in ("", "not-a-version"):
        result = run(ROOT / "scripts/sbom.sh", str(dist), "lint-requirements.txt", env=env, ZIG_VERSION=bad)
        expect(result.returncode != 0 and report.read_bytes() == original, result)
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
    for name in (
        "run.sh",
        "gauntlet.sh",
        "monotonic.sh",
        "portable.sh",
        "rows.sh",
        "limit.py",
        "row.py",
        "review_row.py",
    ):
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
        # One run id per variant, because a run records each measurement once: the
        # error row below is a second measurement of the same (agent, task) under
        # the same run as the success row above, so sharing one run id would have
        # the success suppress it rather than the file carrying both.
        for fail in ("", "1"):
            variant = f"{run_id}-{fail or 'ok'}"
            variant_env = dict(env, BENCH_RUN_ID=variant, GAUNTLET_RUN_ID=variant)
            result = run(bench / name, agent, env=variant_env, GIT_FAIL=fail)
            expect(result.returncode == 0, result)
            row = json.loads((bench / results).read_text().splitlines()[-1])
            expect(row["run"] == variant and row["agent"] == agent, row)
            if fail:
                expect(row.get("lines") == "n/a" if name == "run.sh" else row["changed_files"] is None, row)
        check_rows_rewritten_once(bench / name, bench / results, env, variant, agent)
    for name, results, agent in (
        ("run.sh", "results.jsonl", "row-agent"),
        ("gauntlet.sh", "gauntlet-results.jsonl", 'row-agent:model"\\tag'),
    ):
        check_rows_distinct_runs_kept(bench / name, bench / results, env, agent)
    check_parallel(fixture, env)


def check_rows_rewritten_once(bench_script: Path, results: Path, env: dict[str, str], run_id: str, agent: str) -> None:
    """A second run of one measurement under one run id leaves the file alone.

    The results files are append-only and every row of an invocation carries the
    same `run` so a reader can take that invocation's rows as a group. That group
    is a set of measurements only while a run contributes one row each: a retry,
    a crash and a restart, or a second shell running the same script, each
    appended a second row under that run, so a mean over the group was a mean
    over a number of samples nobody chose. The row already in the file is this
    run's answer, so a repeat is skipped rather than appended or overwritten.
    """
    before = results.read_text().splitlines()
    variable = "BENCH_RUN_ID" if bench_script.name == "run.sh" else "GAUNTLET_RUN_ID"
    result = run(bench_script, agent, env=dict(env, **{variable: run_id}))
    expect(result.returncode == 0, result)
    expect(results.read_text().splitlines() == before, f"{bench_script.name} appended a duplicate row on a re-run")


def check_rows_distinct_runs_kept(bench_script: Path, results: Path, env: dict[str, str], agent: str) -> None:
    """Two runs of one measurement are two rows: the dedup is per run, not global."""
    variable = "BENCH_RUN_ID" if bench_script.name == "run.sh" else "GAUNTLET_RUN_ID"
    for run_id in ("rows-first", "rows-second"):
        result = run(bench_script, agent, env=dict(env, **{variable: run_id}))
        expect(result.returncode == 0, result)
    rows = [json.loads(line) for line in results.read_text().splitlines() if line.strip()]
    for run_id in ("rows-first", "rows-second"):
        matching = [row for row in rows if row.get("run") == run_id and row.get("agent") == agent]
        expect(len(matching) == 1, f"{run_id} recorded {agent} {len(matching)} times: {matching}")


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
    if sys.argv[1:] not in ([], ["--workflows"]):
        sys.exit("usage: test_scripts.py [--workflows]")
    check()
    print("Workflow shell checks passed" if sys.argv[1:] else "Benchmark and release gate failure checks passed")
