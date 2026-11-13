# Contributing

## Repository layout

| Path | Contents |
| --- | --- |
| `src/` | Zig modules, each with its tests and fuzz corpora beside the code: `main.zig` (command line, config resolution, the turn loop, the provider request and ACP sessions), `acp.zig` (ACP v1 frames and content blocks), `stream.zig` (folding response frames into a turn), `conversation.zig` (system prompt, message array and compaction), `chat.zig` (value types, the JSON writer and diagnostic escaping), `net.zig` (CA bundle, environment, deadlines and output sinks), `tool.zig` (the built-in tools and their process runner), `mcp.zig` (stdio and HTTP MCP servers), `config.zig` (the config file), `setup.zig` (`microagent setup`), `session.zig` (the session log), `skill.zig` (skills), `sandbox.zig` (Landlock and Seatbelt), `update.zig` (`microagent update`), `clispec.zig` (the `schema` document, `-o` and the JSON error envelope), `clispec_check.zig` (drives the built binary through its entry point), `copy.zig` (the word-at-a-time `memcpy` for ReleaseSmall). |
| `bench/` | Benchmark and gauntlet scripts, task fixtures and sample lists, the stub provider, memory probe, instruction baseline, committed results and Python integration tests. |
| `integrations/harbor/` | The [Harbor adapter](integrations/harbor/README.md) and its pinned Python requirements. |
| `docs/` | [Usage](docs/usage.md), [benchmarks](docs/benchmark.md), [performance](docs/performance.md), [threat model](docs/threat-model.md), [to-do list](docs/todo.md), man page and artwork. |
| `reviews/` | Review prompts for `gauntlet --prompt-dir reviews`, replacing gauntlet's embedded set. |
| `.github/` | CI and release workflows, shared setup actions and Dependabot config. |
| `scripts/` | Gate checks and release inventory generation. |

The root holds the build and version (`build.zig`, `build.zig.zon`),
[Makefile](Makefile), changelog, config template, license and linter configuration.

## Setup

Use Zig 0.17.0 or newer, the minimum declared in [build.zig.zon](build.zig.zon).
The Zig build needs no third-party package installation, service or copied config.
`make zig-version` rejects older compilers and reports newer ones without rejecting them;
that is a version check, not a guarantee of compatibility with future Zig releases.

Release-related targets require exactly the minimum version: `make release-assets`,
`make musl`, `make install`, `make check-asset-run` and `make check-reproducible`
run `make zig-release-version`. CI uses that same compiler.

The build copies the Zig library into its cache and patches the POSIX spawn error path
to close pipes and reap a failed child. It leaves the installed toolchain untouched.
If an upgrade changes that implementation, the build stops for review; remove the
workaround when upstream provides the cleanup.

```sh
make                     # ReleaseSmall binary at zig-out/bin/microagent
make OPT=ReleaseFast     # build used for CPU-counter measurements
```

### Linters

`make check` needs `shellcheck`, `ruff`, `yamllint`, `git` and `python3` on `PATH`.
That Python must import PyYAML to decode workflow `run:` bodies. `make preflight`
reports missing tools and installation commands. It also notes missing `rg` and
`ast-grep`: tests using them skip rather than fail, so install both to cover those paths.

Install the pinned Python tools with:

```sh
uv venv .scratch/lintenv --python 3.12
uv pip install --python .scratch/lintenv/bin/python --require-hashes -r lint-requirements.txt
export PATH="$PWD/.scratch/lintenv/bin:$PATH"
```

CI installs ShellCheck 0.11.0 from an upstream release with a pinned SHA-256.
The optional checks need ShellCheck 0.11.0 or newer (`brew install shellcheck`,
or use the upstream binary). `make lint-versions` checks the Python tool pins
against the Makefile. Ruff targets Python 3.12, the Harbor adapter's floor.

## Before you push

Run `make check`. Use the narrower targets while editing:

```sh
make test FILTER="..."      # matching unit tests; an unknown filter fails
make test                   # unit tests plus the Python CLI/integration suite
make test-sanitize          # optimized unit tests with Zig runtime safety checks
make watch FILTER="..."     # rerun unit tests on source changes; Ctrl-C stops
make preflight              # check installed tools
make lint                   # all lint, lock, inventory and citation checks
make lint-ci                # workflow shell, action pins and runner semantics
make check-asset-run        # cross-build and start this host's published asset
make instructions CHECK=--check   # instruction counts against baseline bands
```

`make help` lists all targets. `make fmt` applies `zig fmt` and `ruff format`;
`make fmt-check` checks formatting without changing files.

### The gate

`make check` runs these targets in order:

1. `preflight` and `zig-version`.
2. `check-unreleased`, `check-changelog-history`, `check-readme`, `check-help`, `check-man`.
3. `fmt-check` and `lint`.
4. `test`, `test-sanitize`, `check-binary OPT=ReleaseSmall`.

`lint` covers version pins and their self-tests, Python locks, the SPDX generator,
ShellCheck over scripts and workflow `run:` bodies, Ruff checks and formatting,
yamllint, Markdown and source citations. File lists include tracked files and
untracked files not excluded by gitignore, so new files are checked before staging.

The Markdown check rejects trailing spaces and hard tabs outside code fences,
repeated blank lines, unclosed fences and missing final newlines. There is no
Markdown formatter. `lint-ci` also requires full commit SHAs with release comments
for external actions, explicit shells in composite actions, job timeouts,
workflow permissions and concurrency groups, no `write-all`, and checkout with
`persist-credentials: false`. ShellCheck directives that suppress nothing fail.

Cite source controls as pairs: `` `symbol`, `src/file.zig:line` ``. `check-refs`
checks the symbol's definition, including qualified names such as `config.parse`.
Bare citations must name existing code lines; ranges must be ordered and in bounds.
Run `make check-refs FIX=1` after moving a definition to repair its paired citations.
Missing symbols and invalid bare citations need manual repair.

The Debug unit run and the ReleaseSafe `test-sanitize` run both enable Zig's
runtime safety checks; ReleaseSmall disables them. Despite its name,
`test-sanitize` does not use a C sanitizer. Passing tests cover exercised paths
and do not prove the absence of unchecked illegal behavior. An unfiltered
`make test` also runs `test-cli`, including a built CLI against a loopback provider.
A green filtered test or watch run does not replace the gate.

`make check` does not run release cross-builds, reproducibility checks, the host's
published-asset smoke test or the macOS matrix. Run the relevant release targets
below; CI runs the platform tests and `check-asset-run` separately.
`make check-asset-run TARGET=...` accepts only the published target for its host.

### What CI requires

Require the `test`, `lint` and `release-assets` jobs in
[ci.yml](.github/workflows/ci.yml) on the default branch, including the test matrix,
and require them to be up to date. Branch protection is a repository setting.
The test matrix includes two macOS runners. The release-assets job builds all
four published targets, inventories and checksums them, checks their format and
architecture, and verifies reproducibility before a tag is cut. The test matrix
starts three published assets on their native platforms; `aarch64-linux-musl` is
cross-built and inspected but is not executed in CI.

Neither workflow reads a repository secret. The release uses the automatic
`GITHUB_TOKEN`: `contents: read` by default, `contents: write` for the release job.

### The instruction gate

Run `make instructions CHECK=--check` before pushing a hot-path change. This gate
is outside `make check` because it needs `perf` counters that shared runners may
disable. It measures retired instructions rather than load-sensitive wall time.
Exit 1 means a row left its band; exit 2 means a row could not be measured.
Fix an increase, or deliberately re-record `bench/instructions.baseline` when
changing the measured work. A decrease also requires reviewing the stale baseline.

Bench scripts put scratch data in gitignored `.scratch/` to avoid benchmarking a
host's temporary filesystem, which may be RAM-backed. Set `BENCH_WORK` to choose
another root, or `GAUNTLET_WORK` for `make gauntlet`.

## Tests

Put a Zig `test` block beside the code it covers and name the behavior it pins,
for example `test "usage counters land on the result"`. Pass the environment
through an `environ_map` and use `std.testing.tmpDir` for files. Neutralize any
external dependency explicitly. CLI integration tests use a loopback provider,
not a live provider account.

The build and Makefile set `LC_ALL=C` and `TZ=UTC` for tests and their children.
This also prevents unavailable host locales from adding shell warnings to stderr.
Tests requiring `rg` or `ast-grep` return `error.SkipZigTest` when unavailable;
a green run then does not cover those tools. A macOS-only session test is covered
by the macOS runners.

### Locks and generated artifacts

There is no generated Zig code or Zig dependency lockfile. Refresh the two Python
locks with the `uv pip compile` commands in their manifest/header, rather than
hand-editing them:

- `lint-requirements.in` → `lint-requirements.txt`.
- `integrations/harbor/requirements.txt` → `integrations/harbor/requirements.lock`.

`make lint-lock` checks exact pins, manifest/lock agreement, valid SHA-256 hashes
and unneeded packages. CI installs with `--require-hashes` into a venv.

`make sbom` writes `dist/microagent-<tag>.spdx.json`, naming asset digests and
Python manifest pins and recording that published binaries carry no third-party
component. Run it before `make checksums` so it gets a sidecar too.
`make check-sbom` exercises the generator with stand-in assets and checks its JSON,
asset digests and declared packages.

Build outputs are `zig-out/` and `dist/`. `make clean` also removes `.zig-cache/`,
cross-build outputs and the Harbor musl binary. `make musl` copies a static binary
to the ignored `integrations/harbor/microagent-<arch>-linux-musl` path.
Benchmark and gauntlet runs append to committed result files (see
[Reproducing](docs/benchmark.md#reproducing)); include only rows from a run the
change actually made.

### Fuzz targets

A parser reading untrusted bytes gets a `std.testing.fuzz` harness and a corpus
beside it. Assert invariants, not just absence of crashes: for example, a turn
assembled from a provider stream must serialize as valid request JSON.
Ordinary unit tests exercise the corpus, so new seeds run in `make check`.

Mutation with `zig build test --fuzz` is currently blocked on the pinned 0.17.0:
its `compiler/test_runner.zig:566` fails to compile under `-ffuzz` because
`@errorReturnTrace()` has a different type under instrumentation. Corpus tests
remain available; mutation coverage must not be claimed from them.

## Version and changelog

The version source is `.version` in `build.zig.zon`.

Every change that lands gets a [CHANGELOG.md](CHANGELOG.md) bullet under
`## [Unreleased]`. Use these sections, each at most once and in this order:
`Added`, `Changed`, `Removed`, `Fixed`, `Security`. For flags, environment variables,
stdout or session-log JSON, describe the before and after.

Use `Security` for prompt or terminal injection fixes, dropped operator controls,
missing refusals and credential-path bypasses. The [changelog](CHANGELOG.md)
preamble states which changes need a minor bump under `0.y`; a `Security` entry
is one of them.

`make check-unreleased` checks section shape, compare links and whether changed
source, build, scripts, benchmarks, integrations, CI or linter manifests have an
Unreleased bullet. The rule is path-based: `docs/`, `reviews/` and top-level
Markdown are exempt, but Markdown under a checked directory, such as
`integrations/harbor/README.md`, still needs a bullet. For another change with
no consumer-visible effect, explain the exception in the pull request.
`make check-changelog-history` applies the bump policy to every released section.

### Releases

Contributors do not tag or publish. For a release rehearsal:

1. Update `build.zig.zon`, the README's version/install examples and the `.TH`
   version in `docs/microagent.1`.
2. Move Unreleased notes to a dated `## [X.Y.Z]` heading and leave an empty
   `## [Unreleased]` heading. Add the release's compare reference and point
   `[Unreleased]` at the new tag.
3. Run the tag gate and build/read-back checks:

```sh
make check-changelog              # current version's section and bump policy
make check-changelog-history      # all released sections
make check-release TAG=vX.Y.Z     # matching version, notes, links, README; no pending notes
make release-assets TAG=vX.Y.Z    # four cross-built assets in dist/
make sbom
make checksums
make check-checksums
make check-assets TAG=vX.Y.Z
make check-reproducible
```

`check-changelog VERSION=X.Y.Z` checks a specific version. The release workflow
uses the same Makefile rules and publishes the checked section as its notes.

`release-assets` empties `dist/` first: the workflow publishes `dist/microagent-*`,
so old rehearsal assets must not remain there. `check-assets` runs the host binary
and checks its version against `TAG` (the build version when unset), then checks
each asset's object format and machine. `check-checksums` requires each asset's
sidecar to name its actual digest.

`check-reproducible` builds every target twice with cold caches and different
clocks, timezones, locales and output directories. It builds the first target
again from another source path to catch embedded checkout paths. Both push and
release workflows run it.

A published release is never replaced: publication refuses an existing non-draft
release. There is no automated rollback, and
[SECURITY.md](SECURITY.md#supported-versions) states which releases get fixes.
To withdraw a release, remove it and its tag in GitHub. `microagent update`
reads `releases/latest` and reports an ahead build rather than downgrading it.
Recreating the tag can publish it again.

## Commit messages

Use a short, lowercase imperative subject matching the existing history, for example
`fix: saturating token totals, codepoint-safe truncation, capped backoff`.
Explain what changed and why in the body when the subject cannot carry it.
