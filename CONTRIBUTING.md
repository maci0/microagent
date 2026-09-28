# Contributing

## Setup

Zig 0.16.0 or newer, the minimum declared as `.minimum_zig_version` in
[build.zig.zon](build.zig.zon). There is no dependency to install, no service to
start, and no configuration to copy. A clone plus a Zig toolchain builds and
tests. `make check` wants exactly 0.16.0, because that is the version CI installs
and the one the release assets are built with; `make zig-version` is the check on
its own, and a newer Zig still builds the project.

0.16.0 is also the newest stable: [the download index](https://ziglang.org/download/index.json)
lists no 0.16.1, and `master` is 0.17.0-dev, which is not a release to pin a
release asset to. So the version is not a constraint on anything, and there is
no upgrade to take for performance until 0.17 ships. Worth knowing before a
review goes looking for one: measured here, `-mcpu=native` moves the hot paths
by less than the run-to-run noise, so there is no build flag to reach for
either.

```sh
make            # zig-out/bin/microagent
make small      # the ReleaseSmall binary
```

`make check`, the gate, also needs `shellcheck`, `ruff` and `yamllint` on
`PATH`. `make preflight` names any of the four it wants that is missing, with
the command that installs it, and `make check` runs it first, so a clean clone
missing a linter says which one instead of stopping at
`make: ruff: No such file or directory`. `ruff` and `yamllint` are format- and
rule-sensitive, so they are pinned in the [Makefile](Makefile) and
`make lint-versions` says so by name when a local install differs from the one
CI runs:

```sh
uv tool install ruff@0.16.4
uv tool install yamllint==1.38.0
```

`shellcheck` rides on the runner image, so it has no pinned version to
install; it is a system package, and `make check` reaches the bench shell
without it:

```sh
apt-get install -y shellcheck     # or: brew install shellcheck
```

CI installs those two from [lint-requirements.txt](lint-requirements.txt),
which pins them and the packages `yamllint` imports, one sha256 per published
artifact, and installs it with `--require-hashes` into a venv on `PATH`, so the
job never writes into the runner image's externally managed python. `make
lint-versions` fails when a version there and one in the Makefile drift apart.

`zig fmt` covers the Zig and needs nothing else.

`ruff` is pointed at the Python the adapter actually runs on, not at ruff's
own default. [ruff.toml](ruff.toml) sets `target-version = "py312"`, the floor
`integrations/harbor/requirements.txt` records in the `uv pip compile
--python-version 3.12` that generates the lock; without it ruff assumes py39
and never evaluates the rules that only fire from 3.10 on, so a green run says
nothing about the interpreter the adapter is installed into.

## Before you push

```sh
make check                  # the gate: zig fmt --check, the linters, the tests, an optimized build
make test-one FILTER="..."  # one test, while you are mid-edit
make watch                  # the suite again on every source change, until Ctrl-C
make preflight              # name any tool check and lint need that is not on PATH
make lint                   # the pin checks, shellcheck, ruff and yamllint on their own
make instructions CHECK=--check   # retired instructions per unit, and a band it must stay inside
```

`make watch` is `zig build test --watch`, the build system's own mode, so the
edit loop is one command rather than an editor task and a `make test` after it.
`FILTER` narrows it the way `test-one` narrows one run, and is checked against
the declared test names before the watch starts, because a filter that matches
nothing reports success while running no test. Neither mode is what `check`
runs, so a green watch is not a push: `make check` is still the gate.

`make instructions` is the one gate that is not in `make check`, and the reason
is worth stating rather than leaving as an omission. It measures retired
instructions, not time, because wall clock moves with frequency scaling and the
CPU quota and a wall-clock gate fails on a busy runner for reasons that have
nothing to do with the code; retired instructions for a fixed binary and a
fixed input repeat to within 0.001%. It needs `perf`, and a shared CI runner
may have performance counters switched off, so a gate that cannot measure is a
gate that fails for the wrong reason on someone else's machine. It exits 1 when
a row leaves its band and 2 when a row cannot be measured at all, so run it
before a push that touches a hot path and re-record
`bench/instructions.baseline` only when the change is meant to move it.

`make check` is the whole gate: it is the same `zig fmt --check`, the same
`ruff check`, `ruff format --check` and `yamllint`, the same `zig build test`,
the same `make lint-versions` and `make lint-lock`, and the same `ReleaseSmall` build whose binary
it then runs, that
[.github/workflows/ci.yml](.github/workflows/ci.yml) runs, on the same Zig
version (`make zig-version` is that first step, so a laptop on a different
compiler is told rather than assumed). Two things it does not stand in for: the
release-assets cross-build (`make release-assets` runs that, and
`make check-reproducible` adds a byte-identical rebuild of every published
target on top of it, with the clock, the locale, the timezone, both compiler
caches and the output directory varied, and one of them from a copy of the source
at another path) and the other runners, where the same gate also
runs on macOS. `make help` lists every target.
Source is formatted with `zig fmt`; `make fmt` applies it, and `ruff format`
does the same for the Harbor adapter. The three linters cover what `zig fmt`
cannot: the bench
shell, the Harbor adapter under `integrations/harbor` (rules in
[ruff.toml](ruff.toml)) and the workflows, the composite toolchain action and
the Dependabot config (rules in [.yamllint](.yamllint)). Each takes its file
list from git, so a Python or YAML file added outside the paths named above is
linted too.

## Tests

A `test` block lives in the file it covers, next to the code, named for the
behavior it pins rather than the function it calls: `test "usage counters land
on the result"`. Tests must be hermetic: pass the environment in (the code reads
an `environ_map`, it does not call `getenv`), and use `std.testing.tmpDir` for
files. Nothing in the suite reaches the network, the clock's timezone, or
`$HOME`, so a test that needs any of those must say how it neutralizes them.

There is no generated code, and nothing in the Zig build regenerates a lockfile. The two lockfiles
are inputs to the Python around the Zig and are refreshed by hand: `lint-requirements.txt` pins the
gate's linters, and `integrations/harbor/requirements.lock` is uv's output for the Harbor adapter,
with the command that produces it in the comment at the top of
`integrations/harbor/requirements.txt`. `make lint-lock` reads both and refuses
a lock that no longer carries the manifest's pin, or that has an entry with no
`sha256`, so a lock left behind by an earlier pin fails the gate instead of
quietly benchmarking a Harbor release the manifest no longer names. The only build output
is `zig-out/`, and `make clean` removes it along with `.zig-cache/`. `make musl`
also copies the static binary to
`integrations/harbor/microagent-<arch>-linux-musl`, named for the host's own
architecture, for the Harbor adapter; that one and the `.tmp` it is renamed from
are ignored, so nothing under `integrations/` is ever a build output a commit
picks up. A
bench run appends its own line to the committed `bench/results.jsonl`; that file
is results, not code, so leave the appended line out of a change that did not run
a benchmark.

### Fuzz targets

A parser that reads bytes it did not write gets a `std.testing.fuzz` harness and
a corpus beside it, in the same file. The corpus is what the harness asserts on
during an ordinary `zig build test`; build the test binary in fuzz mode to run
the fuzzer's mutations from the same seeds. A harness asserts the invariants,
not just the absence of a crash: a turn assembled from a fuzzed provider stream
has to serialize as a valid request body, and a release body has to earn the
verdict that installs it.

## Version and changelog

The version is `.version` in `build.zig.zon` and nowhere else. Every change that
lands gets a [CHANGELOG.md](CHANGELOG.md) entry under `## [Unreleased]`, in the
Keep a Changelog sections already in use, in their order: `Added`, `Changed`,
`Removed`, `Fixed`, `Security`, one of each at most. A fix that closes a way for
text the model or the tree controls to reach the prompt or the terminal is a
`Security` entry, not a `Fixed` one, so a reader scanning for those finds it.
Under `0.y` the minor carries features, anything that changes what a run does by
default, and anything taken away; the patch carries fixes,
and a patch must not change what an existing invocation does. A change to the
flags, the environment variables, or the stdout and session-log JSON names the
before and the after in its entry.

Releases are tags: the release workflow publishes only when the tag names the
`build.zig.zon` version, that version has a `CHANGELOG.md` entry, and the bump
matches what the entry says. A patch tag whose section carries an `Added`, a
`Changed` or a `Removed` entry is refused, because under `0.y` those are what
the minor carries. The four
published binaries and their asset names are spelled once, in the
[Makefile](Makefile), so a release can be built and checksummed on a laptop
before the tag exists:

```sh
make release-assets TAG=v0.2.0   # the four cross-built assets, in dist/
make checksums                   # the sha256 sidecars `update` verifies
```

`make check-reproducible` rebuilds every published target twice, from a cold
cache and with a different clock, timezone and locale each time, and refuses a
target whose two builds differ: a released checksum has to describe a binary a
rebuild reproduces. The first target is built a third time from a copy of the
source at another path, because the first two share this checkout's path and a
build directory can reach a binary the way a timestamp does. The push workflow
runs it on every push and the release workflow runs it on the tag, so a release
is never published from a commit that has not passed it.

`make release-assets` empties `dist/` first, so what is there afterwards is the
one run's assets: the release workflow publishes the glob `dist/microagent-*`,
and a rehearsal's or a previous tag's binaries left in that directory would go
out under this tag.

Contributors do not tag or publish.

## Commit messages

Short, imperative subject in lowercase, matching the existing history
(`fix: saturating token totals, codepoint-safe truncation, capped backoff`).
What changed and why, in the body when the subject cannot carry it.
