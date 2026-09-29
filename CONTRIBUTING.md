# Contributing

## Repository layout

| path | what lives there |
| --- | --- |
| `src/` | the agent, one Zig file per concern, each with its tests and fuzz corpora beside the code: `main.zig` (command line, config resolution, the turn loop and the request), `stream.zig` (folding response frames into a turn), `conversation.zig` (the system prompt, message array and compaction), `chat.zig` (value types and the JSON writer), `net.zig`, `tool.zig`, `sandbox.zig`, `session.zig`, `skill.zig`, `copy.zig`, `config.zig`, `mcp.zig`, `update.zig` |
| `bench/` | the benchmark and gauntlet scripts, a loopback stub provider for profiling the harness alone (`stub_provider.py`), the peak-memory probe (`maxrss.py`), the task fixtures under `bench/tasks/`, the fixed stride-sample task lists (`tb4-sample.txt`, `polyglot-sample.txt`, `deepswe-sample.txt`, `tb2-sample.txt`, `swe-sample.txt`), the instruction gate's baseline, and the committed results (`results.jsonl`, `gauntlet-results.jsonl`) |
| `integrations/harbor/` | the adapter that runs microagent on [Harbor](integrations/harbor/README.md) benchmarks, and its pinned Python requirements |
| `docs/` | reference and design docs: [usage](docs/usage.md), [benchmark](docs/benchmark.md), [performance](docs/performance.md), [threat model](docs/threat-model.md), the [to-do list](docs/todo.md), and the logo |
| `reviews/` | this project's own [gauntlet](https://github.com/maci0/gauntlet) review prompts; run them with `gauntlet --prompt-dir reviews`, which replaces gauntlet's embedded set |
| `.github/` | the `ci` and `release` workflows, the shared `setup-zig` and `setup-linters` actions, and the Dependabot config |
| `scripts/` | the gate's own checks: the linter version pins (`lint-versions.sh`), the Harbor lock against its manifest (`lint-lock.sh`). The linters' hashed install is compiled from `lint-requirements.in` |

At the root: `build.zig` and `build.zig.zon` (the build and the version), the
[Makefile](Makefile) (every command below), `README.md`, `CHANGELOG.md`, this
file, `LICENSE`, `config.example.toml` (the config template), and the linter
setup: `lint-requirements.txt`, `ruff.toml`, `.yamllint`. `.gitignore` and
`.gitattributes` complete the list.

## Setup

Zig 0.16.0 or newer, the minimum declared as `.minimum_zig_version` in
[build.zig.zon](build.zig.zon). There is no dependency to install, no service to
start and no configuration to copy: a clone plus a Zig toolchain builds and
tests. A newer Zig builds the project, but `make check` wants exactly 0.16.0,
the version CI installs and the release assets are built with. `make
zig-version` runs that check alone. 0.16.0 is also the newest stable release;
[docs/performance.md](docs/performance.md#the-toolchain) says why there is no
compiler upgrade or build flag to take for speed.

```sh
make                     # zig-out/bin/microagent, built ReleaseSmall: the smallest resident memory
make OPT=ReleaseFast     # the build the CPU counters are read on
```

### Linters

`make check` also needs `shellcheck`, `ruff`, `yamllint`, `git` and `python3` on
`PATH` (git because every linter reads its file list with `git ls-files`;
python3 because CI builds the linters' venv with it).
`make preflight` names each missing tool with the command that installs it, and
`make check` runs it first, so a clean clone missing a linter says which one
instead of stopping at `make: ruff: No such file or directory`.

`ruff` and `yamllint` are format- and rule-sensitive, so the [Makefile](Makefile)
pins them, and `make lint-versions` names a local install that differs from the
one CI runs:

```sh
uv tool install ruff@0.16.4
uv tool install yamllint==1.38.0
```

`shellcheck` comes with the runner image, so it has no pinned version. It is a
system package, and `make check` needs it for the bench shell:

```sh
apt-get install -y shellcheck     # or: brew install shellcheck
```

CI installs `ruff` and `yamllint` from [lint-requirements.txt](lint-requirements.txt),
which pins them and the packages `yamllint` imports with one sha256 per
published artifact. It installs with `--require-hashes` into a venv on `PATH`,
so the job never writes into the runner image's externally managed Python.
`make lint-versions` fails when that file and the Makefile disagree on a
version. The file is compiled by `uv` from `lint-requirements.in` (the command is in that
file's header), so its transitive pins are whatever `yamllint` asks for and nothing is
checked by hand.

`zig fmt` covers the Zig and `build.zig.zon`, and needs nothing else.

`ruff` targets the Python the adapter runs on, not ruff's default.
[ruff.toml](ruff.toml) sets `target-version = "py312"`, the floor
`integrations/harbor/requirements.txt` records in the `uv pip compile
--python-version 3.12` that generates the lock. Without it ruff assumes py39
and never evaluates the rules that fire only from 3.10 on, so a green run would
say nothing about the interpreter the adapter is installed into.

## Before you push

```sh
make check                  # the gate: zig fmt --check, the linters, the tests, an optimized build
make test FILTER="..."      # one test, while you are mid-edit; a filter matching no test is refused
make test-sanitize          # the same suite under the undefined-behavior sanitizer
zig build test --watch    # the suite again on every source change, until Ctrl-C
make preflight              # name any tool check and lint need that is not on PATH
make lint                   # the pin checks, shellcheck, ruff and yamllint on their own
make check-asset-run        # the published asset for this host, cross-built and started
make instructions CHECK=--check   # retired instructions per unit, and a band it must stay inside
make check-unreleased       # the [Unreleased] entry has the five sections, once each, in order
```

`make help` lists every target.

### The gate

`make check` runs, in order: `preflight`, `zig-version`,
`check-unreleased`, `check-readme`, `fmt-check`, `lint` (`lint-versions`,
`lint-lock`, `check-sbom`, shellcheck, `ruff check`, `ruff format --check`,
yamllint), `zig build test`,
`zig build test-sanitize`, and `check-binary` (a `ReleaseSmall` build whose
binary it then starts). These are the checks
[.github/workflows/ci.yml](.github/workflows/ci.yml) runs in its test and lint
jobs, on the same Zig version: the shared setup-zig action installs the version
`make required-zig-version` prints, and `make zig-version` tells a laptop on a
different compiler so rather than assuming. The workflow calls the same targets
rather than repeating their commands, so a step added to `check` is a step CI
runs.

The second test run compiles the same tests with the undefined-behavior
sanitizer. The plain run says the assertions hold; only the instrumented one
says nothing inside them goes out of bounds or overflows, which is silent in
the `ReleaseSmall` binary the release assets are made of.

`make test FILTER=...` checks the filter against the declared test names first, because a filter that
matches nothing reports success while running no test. `zig build test --watch` is the build system's own
edit loop and is not what `check` runs: a green watch is not a push.

`make fmt` applies `zig fmt` and `ruff format`; `make fmt-check` is what the
gate runs. The three linters cover what `zig fmt` cannot: the bench shell, the
Harbor adapter under `integrations/harbor` (rules in [ruff.toml](ruff.toml)),
and the workflows, the composite actions and the Dependabot config (rules in
[.yamllint](.yamllint)). Each takes its file list from git, so a shell, Python
or YAML file added anywhere is linted too. Both workflows call `make lint`
rather than repeating its targets, so a linter added to the Makefile gates a
push and a tag as well as a laptop.

`check` does not cover three things. One is the release cross-build: `make
release-assets` runs it, and `make check-reproducible` rebuilds it byte for
byte (see
[Version and changelog](#version-and-changelog)). The second is the asset
check, which `make check-asset-run` runs on its own: it cross-builds the
published target for this host and starts it, so a change that only breaks the
shipped binary (a Mach-O that links but does not start, a Linux asset that needs
a libc the host build never saw) is caught on a laptop rather than on a runner
or a user's machine. `make check-asset-run TARGET=...` is the form CI uses, and
it refuses a target that is not the one this host publishes. The third is the
macOS runners, where CI runs the same tests again.

### What CI requires

The three jobs in `ci.yml` are the checks a merge has to pass: `test`, `lint`
and `release-assets`. The first two are the gate. The third builds the four
published targets and refuses one whose rebuild is not byte-identical, so a
merge that leaves the release unreproducible is caught before the tag.

Mark all three required on the default branch, and require them to be up to
date, not merely passing: `test` also runs on two macOS runners, and a merge
that has not seen them is unmeasured. Branch protection is a repository
setting no file in the tree can declare, which is why it is written here.

Neither workflow reads a repository secret. The release publishes with the
automatic `GITHUB_TOKEN`; the token scope is `contents: read` for a push and
`contents: write` for the release job alone. CI needs no configuration.

### The instruction gate

`make instructions` is the one gate outside `make check`. It measures retired
instructions, not time: wall clock moves with frequency scaling and the CPU
quota, so a wall-clock gate fails on a busy runner for reasons unrelated to the
code, while retired instructions for a fixed binary and input repeat to within
0.001%. It needs `perf`, and a shared CI runner may have performance counters
switched off, so as a blocking gate it would fail for the wrong reason on
someone else's machine.

It exits 1 when a row leaves its band and 2 when a row cannot be measured. Run
it before a push that touches a hot path, and re-record
`bench/instructions.baseline` only when the change is meant to move it. A row
above its band is a regression to fix. A row below it retired less work than
the baseline records, so the baseline is stale; the run says which of the two
it found.

## Tests

A `test` block lives in the file it covers, next to the code, named for the
behavior it pins rather than the function it calls: `test "usage counters land
on the result"`. Tests are hermetic: pass the environment in (the code reads an
`environ_map`, it does not call `getenv`) and use `std.testing.tmpDir` for
files. Nothing in the suite reaches the network, the clock's timezone or
`$HOME`, so a test that needs any of those says how it neutralizes them.

`build.zig` sets `LC_ALL=C` and `TZ=UTC` for the test run and the children it
spawns, and the Makefile exports the same two. Several tests assert on the
exact bytes a `/bin/sh` printed, and a shell started under an `LC_ALL` naming a
locale the host lacks opens with a `setlocale` warning on stderr, which fails
them on a correct tree.

A handful of tests need a program the host may not have: the `search` and `ast`
tests delegate to `rg` and `ast-grep`, which a stock macOS ships neither of, and
one session test is macOS-only. Each of those prints `skipped: ...` on stderr and
returns `error.SkipZigTest`, which the test runner counts as a pass, so a green
run on a machine without `rg` says nothing about the search tool. A local run
with both programs on `PATH` is the run that covers them, and the macOS runners
are what cover the session one.

There is no generated code, and the Zig build regenerates no lockfile. The two
lockfiles are inputs to the Python around the Zig, refreshed by hand:
`lint-requirements.txt` pins the gate's linters, and
`integrations/harbor/requirements.lock` is uv's output for the Harbor adapter,
with the command that produces it in the comment at the top of
`integrations/harbor/requirements.txt`. `make lint-lock` refuses a lock that no
longer carries the manifest's pin, has an entry with no `sha256`, or carries a
package no pin in the manifest needs. A lock left behind by an earlier pin
therefore fails the gate instead of benchmarking a Harbor release the manifest
no longer names, and a package nothing asks for never reaches the venv a score
is measured in.

A release publishes an SPDX inventory beside its binaries: `make sbom` writes
`dist/microagent-<tag>.spdx.json` from the assets in `dist/`, and the release
runs it before `make checksums` so the inventory gets a sidecar like every other
asset. It names each asset with its digest, and every pin the two Python
manifests declare with the manifest that declares it, and says in one annotation
that no published asset carries a third-party component. Nothing in the tree
reads the file a release writes, and nothing builds a tagged one before the tag,
so `make check-sbom` runs the generator over two stand-in assets in a scratch
directory and checks what a scanner reads: that the document parses, names those
assets with their digests, and carries a package for every pin the manifests
declare. A manifest a change adds a pin to is then a `check-sbom` failure until
the inventory is regenerated, rather than a package a published document
silently omits.

The build outputs are `zig-out/` and `dist/`. `make clean` removes them, along
with `.zig-cache/` and the Harbor musl binary. `make musl` copies the static
binary to `integrations/harbor/microagent-<arch>-linux-musl`, named for the
host's architecture; that file and the `.tmp` it is renamed from are ignored,
so a commit never picks up a build output under `integrations/`. A bench run
appends a line to the committed `bench/results.jsonl`. That file is results,
not code: leave the appended line out of a change that did not run a benchmark.

### Fuzz targets

A parser that reads bytes it did not write gets a `std.testing.fuzz` harness and
a corpus beside it, in the same file. An ordinary `zig build test` asserts the
harness on the corpus, so a new seed goes there. Mutating beyond the seeds
needs `zig build test --fuzz`, which does not build on the pinned 0.16.0: the
toolchain's own test runner fails to compile under `-ffuzz`
(`compiler/test_runner.zig:566`, an `@errorReturnTrace()` the fuzzer's
instrumentation gives a different type), so the command fails before reaching a
harness. Nothing in this tree can fix that; a seed added to a corpus is still
asserted on every `make check`. A harness asserts invariants, not only the
absence of a crash: a turn assembled from a fuzzed provider stream has to
serialize as a valid request body, and a release body has to earn the verdict
that installs it.

## Version and changelog

The version is `.version` in `build.zig.zon` and nowhere else.

Every change that lands gets a [CHANGELOG.md](CHANGELOG.md) entry under
`## [Unreleased]`, in the Keep a Changelog sections already in use, in order
and at most once each: `Added`, `Changed`, `Removed`, `Fixed`, `Security`. A fix
that closes a way for text the model or the tree controls to reach the prompt
or the terminal is a `Security` entry, not `Fixed`, so a reader scanning for
those finds it. A change to the flags, the environment variables, or the stdout
and session-log JSON names the before and the after in its entry.

Under `0.y` the minor carries features, anything that changes what a run does
by default, and anything taken away. The patch carries fixes and must not
change what an existing invocation does.

`make check-unreleased` runs in `make check` and in the push workflow, and
checks the entry's shape while it is under `[Unreleased]`: the five sections,
each at most once, in that order. Whether a change is worth an entry is the
writer's call. `make check-changelog` checks the same shape on the entry a tag
names, after the heading has become a version and the author no longer sees
it. Both run `make check-changelog-links`, which holds the `[Unreleased]:` and
`[X.Y.Z]:` references at the bottom of the file to the versions the headings
above them say: a release renames the `[Unreleased]` heading and adds the
version's own, and the two links under them are written by hand, so a release
that forgets them publishes notes whose diff still points at the release
before.

### Releases

Releases are tags. The release workflow publishes only when the tag names the
`build.zig.zon` version, that version has a `CHANGELOG.md` entry, and the bump
matches the entry: a patch tag whose section carries an `Added`, `Changed` or
`Removed` entry is refused, because under `0.y` those belong to the minor.
Those three rules are `make check-release TAG=vX.Y.Z` and `make
check-changelog`, and `release.yml` runs those targets rather than its own copy
of the rules, so a release note is written against something runnable:

```sh
make check-changelog              # the section for the version build.zig.zon declares, its shape, and the 0.y policy on it
make check-changelog VERSION=0.2.1
make check-readme                 # the README installs and names the version this tree declares
make check-release TAG=v0.2.1     # what a tag has to satisfy: the version, nothing left under [Unreleased], the README
```

`make check-changelog` prints the section it checked, which a release publishes
as its notes, and refuses it on the same five headings `check-unreleased` asks
of a draft. `check-release` is the whole tag gate. It refuses an entry still
under `[Unreleased]`, since the tag would drop it from the published notes and
land it in the next release under a version nobody ran, and it refuses a README
still naming the previous release, since the install snippet a reader copies
would fetch the older binary under the new tag. Run it after the
version bump, the entry and the README line are written, before the tag is cut.

Cutting a release moves two of those three by hand, and the third moves with
them: rename `## [Unreleased]` to `## [X.Y.Z]` with the release date, write the
version's own compare reference, and point `[Unreleased]` at the new tag. The
step the `X.Y.Z` naming gives away is the one that gets skipped, because
nothing downstream of a green `make check` reads those links.

The four published binaries and their asset names are spelled once, in the
[Makefile](Makefile), so a release can be built and checksummed on a laptop
before the tag exists:

```sh
make release-assets TAG=v0.2.0   # the four cross-built assets, in dist/
make checksums                   # the sha256 sidecars `update` verifies
make check-assets                # the host binary's version, and every asset's object format and machine
```

`make release-assets` empties `dist/` first, so it holds only this run's
assets: the release workflow publishes the glob `dist/microagent-*`, and a
rehearsal's or an earlier tag's binaries left there would go out under this
tag.

`make check-assets` reads `dist/` back rather than trusting the build that
wrote it. It runs the host binary and compares its `--version` with the tag
being built (`TAG=`, or the `build.zig.zon` version when unset). It reads each
of the four assets for the object format its target name promises and the
machine that format carries, because a cross build that ignored `-Dtarget` and
produced the host's architecture, or an empty file, publishes green and fails
on a user's machine. The magic alone would not catch that: every Mach-O 64
file starts with `cffaedfe` whatever the CPU, and every ELF with `7f454c46`, so
`e_machine` at offset 18 and `cputype` at offset 4 say which. Both are declared
per target, so a target added to `RELEASE_TARGETS` states what it is before it
can be published. `ci.yml` runs the same target over the rehearsal build and
`release.yml` over the tagged one, so the check a laptop runs before a tag is
the check the tag runs.

`make check-reproducible` rebuilds every published target twice, from cold
compiler caches and with a different clock, timezone, locale and output
directory each time, and refuses a
target whose two builds differ: a released checksum has to describe a binary a
rebuild reproduces. The first target is built a third time from a copy of the
source at another path, because the first two share this checkout's path and a
build directory can leak into a binary the way a timestamp does. The push
workflow runs it on every push and the release workflow on the tag, so a
release is never published from a commit that has not passed it.

A published release is never replaced: the publish step refuses a tag whose
release exists and is not a draft, because a consumer may already have fetched
it. There is no automated rollback; the fix ships as the next release, and
[CHANGELOG.md](CHANGELOG.md) states that only the latest release is supported.
A release that has to be withdrawn before then is removed in the GitHub UI,
with its tag. `microagent update` reads `releases/latest`, so it stops
resolving to a withdrawn release, and a build ahead of what remains is reported
as ahead rather than downgraded. Deleting the tag keeps the release from coming
back, since recreating the tag and re-running the workflow publishes it again.

Contributors do not tag or publish.

## Commit messages

Short, imperative subject in lowercase, matching the existing history
(`fix: saturating token totals, codepoint-safe truncation, capped backoff`).
What changed and why goes in the body when the subject cannot carry it.
