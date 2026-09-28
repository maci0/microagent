# Contributing

## Setup

Zig 0.16.0 or newer, the minimum declared as `.minimum_zig_version` in
[build.zig.zon](build.zig.zon). There is no dependency to install, no service to
start, and no configuration to copy. A clone plus a Zig toolchain builds and
tests. `make check` wants exactly 0.16.0, because that is the version CI installs
and the one the release assets are built with; `make zig-version` is the check on
its own, and a newer Zig still builds the project.

```sh
make            # zig-out/bin/microagent
make small      # the ReleaseSmall binary
```

`make check`, the gate, also needs `shellcheck`, `ruff` and `yamllint` on
`PATH`. `ruff` and `yamllint` are format- and rule-sensitive, so they are
pinned in the [Makefile](Makefile) and `make lint-versions` says so by name
when a local install differs from the one CI runs:

```sh
uv tool install ruff@0.16.4
uv tool install yamllint==1.38.0
```

CI installs those two from [lint-requirements.txt](lint-requirements.txt),
which pins them and the packages `yamllint` imports, one sha256 per published
artifact, and installs it with `--require-hashes` into a venv on `PATH`, so the
job never writes into the runner image's externally managed python. `make
lint-versions` fails when a version there and one in the Makefile drift apart.

`zig fmt` covers the Zig and needs nothing else.

## Before you push

```sh
make check                  # the gate: zig fmt --check, the linters, the tests, an optimized build
make test-one FILTER="..."  # one test, while you are mid-edit
make lint                   # shellcheck, ruff and yamllint on their own
```

`make check` is the whole gate: it is the same `zig fmt --check`, the same
`ruff check`, `ruff format --check` and `yamllint`, the same `zig build test`,
the same `make lint-versions`, and the same `ReleaseSmall` build whose binary
it then runs, that
[.github/workflows/ci.yml](.github/workflows/ci.yml) runs, on the same Zig
version (`make zig-version` is that first step, so a laptop on a different
compiler is told rather than assumed). Two things it does not stand in for: the
release-assets cross-build (`make release-assets` runs that, and CI adds a
byte-identical rebuild of every published target on top of it) and the second
runner, where the same gate also
runs on macOS. `make help` lists every target.
Source is formatted with `zig fmt`; `make fmt` applies it, and `ruff format`
does the same for the Harbor adapter. The three linters cover what `zig fmt`
cannot: the bench
shell, the Harbor adapter under `integrations/harbor` (rules in
[ruff.toml](ruff.toml)) and the workflows and the composite toolchain action
(rules in [.yamllint](.yamllint)).

## Tests

A `test` block lives in the file it covers, next to the code, named for the
behavior it pins rather than the function it calls: `test "usage counters land
on the result"`. Tests must be hermetic: pass the environment in (the code reads
an `environ_map`, it does not call `getenv`), and use `std.testing.tmpDir` for
files. Nothing in the suite reaches the network, the clock's timezone, or
`$HOME`, so a test that needs any of those must say how it neutralizes them.

There is no generated code and no lockfile to regenerate. The only build output
is `zig-out/`, and `make clean` removes it along with `.zig-cache/`. A bench run
appends its own line to the committed `bench/results.jsonl`; that file is
results, not code, so leave the appended line out of a change that did not run a
benchmark.

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
`Fixed`, `Security`, one of each at most. A fix that closes a way for text the
model or the tree controls to reach the prompt or the terminal is a `Security`
entry, not a `Fixed` one, so a reader scanning for those finds it. Under `0.y`
the minor carries features and anything that changes what a run does by
default; the patch carries fixes,
and a patch must not change what an existing invocation does. A change to the
flags, the environment variables, or the stdout and session-log JSON names the
before and the after in its entry.

Releases are tags: the release workflow publishes only when the tag names the
`build.zig.zon` version and that version has a `CHANGELOG.md` entry. The four
published binaries and their asset names are spelled once, in the
[Makefile](Makefile), so a release can be built and checksummed on a laptop
before the tag exists:

```sh
make release-assets TAG=v0.2.0   # the four cross-built assets, in dist/
make checksums                   # the sha256 sidecars `update` verifies
```

`make release-assets` empties `dist/` first, so what is there afterwards is the
one run's assets: the release workflow publishes the glob `dist/microagent-*`,
and a rehearsal's or a previous tag's binaries left in that directory would go
out under this tag.

Contributors do not tag or publish.

## Commit messages

Short, imperative subject in lowercase, matching the existing history
(`fix: saturating token totals, codepoint-safe truncation, capped backoff`).
What changed and why, in the body when the subject cannot carry it.
