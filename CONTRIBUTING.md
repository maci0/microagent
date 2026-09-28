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

`make check`, the gate, also needs `shellcheck`, `ruff`, `yamllint` and `git` on
`PATH`; the last one because every linter reads its file list with `git ls-files`.
`make preflight` names any of the five it wants that is missing, with
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
make test-sanitize          # the same suite under the undefined-behavior sanitizer
make watch                  # the suite again on every source change, until Ctrl-C
make preflight              # name any tool check and lint need that is not on PATH
make lint                   # the pin checks, shellcheck, ruff and yamllint on their own
make instructions CHECK=--check   # retired instructions per unit, and a band it must stay inside
make check-unreleased      # the [Unreleased] entry has the five sections, once each, in order
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
`bench/instructions.baseline` only when the change is meant to move it. A row
above its band is a regression to fix; a row below it retired less work than
the baseline records, so the baseline is what is stale, and the run says which
one it found rather than calling both a regression.

`make check` is the whole gate: it is the same `make fmt-check`, the same
`ruff check`, `ruff format --check` and `yamllint`, the same `zig build test`
and the same `zig build test-sanitize`, the same `make lint-versions` and
`make lint-lock`, and the same `ReleaseSmall`
build whose binary it then runs, that
[.github/workflows/ci.yml](.github/workflows/ci.yml) runs, on the same Zig
version (`make zig-version` is that first step, so a laptop on a different
compiler is told rather than assumed). The second test run is the same tests
compiled with the undefined-behavior sanitizer: the plain run says the
assertions hold, and only the instrumented one says nothing inside them is out
of its bounds or overflows, which is otherwise silent in the `ReleaseFast`
binary the release assets are made of. Two things `check` does not stand in
for: the
release-assets cross-build (`make release-assets` runs that, and
`make check-reproducible` adds a byte-identical rebuild of every published
target on top of it, with the clock, the locale, the timezone, both compiler
caches and the output directory varied, and one of them from a copy of the source
at another path) and the other runners, where the same gate also
runs on macOS. `make help` lists every target.
Source is formatted with `zig fmt`; `make fmt` applies it and `make fmt-check`
is what the gate runs, and `ruff format` does the same for the Harbor adapter.
The three linters cover what `zig fmt` cannot: the bench shell, the Harbor
adapter under `integrations/harbor` (rules in [ruff.toml](ruff.toml)) and the
workflows, the composite toolchain action and
the Dependabot config (rules in [.yamllint](.yamllint)). Each takes its file
list from git, so a Zig, Python or YAML file added outside the paths named above
is linted too. `make lint` is that whole list, and both workflows call it rather
than repeating the targets, so a linter added to the Makefile gates a push and
a tag as well as a laptop.

The three jobs in that workflow are the checks a merge has to be behind:
`test`, `lint` and `release-assets`. The first two are the gate itself, the
third builds the four published targets and refuses one whose rebuild is not
byte-identical, so a merge that leaves the release unreproducible is caught
before the tag rather than at it. Mark all three required on the default
branch, and require them to be up to date rather than merely passing: `test`
runs on two macOS runners as well, and a merge that has not seen them is not
one this project has measured. Branch protection is a repository setting no
file in the tree can declare, so it is written down here instead. Neither
workflow reads a repository secret: the release publishes with the automatic
`GITHUB_TOKEN`, and the token scope is `contents: read` for a push and
`contents: write` for the release job alone, so there is nothing to configure
for CI to run.

## Tests

A `test` block lives in the file it covers, next to the code, named for the
behavior it pins rather than the function it calls: `test "usage counters land
on the result"`. Tests must be hermetic: pass the environment in (the code reads
an `environ_map`, it does not call `getenv`), and use `std.testing.tmpDir` for
files. Nothing in the suite reaches the network, the clock's timezone, or
`$HOME`, so a test that needs any of those must say how it neutralizes them.
The test run itself sets `LC_ALL=C` and `TZ=UTC` in `build.zig`, for the
children the suite spawns: several tests assert on the exact bytes a
`/bin/sh` printed, and a shell started under an `LC_ALL` naming a locale the
host does not have opens with a `setlocale` warning on stderr, which fails them
on a tree that is correct. `make test` exported the same two for that reason;
`zig build test`, which is what this file and `ci.yml` both run, now does it
too.

There is no generated code, and nothing in the Zig build regenerates a lockfile. The two lockfiles
are inputs to the Python around the Zig and are refreshed by hand: `lint-requirements.txt` pins the
gate's linters, and `integrations/harbor/requirements.lock` is uv's output for the Harbor adapter,
with the command that produces it in the comment at the top of
`integrations/harbor/requirements.txt`. `make lint-lock` reads both and refuses
a lock that no longer carries the manifest's pin, that has an entry with no
`sha256`, or that carries a package no pin in the manifest needs, so a lock left
behind by an earlier pin fails the gate instead of quietly benchmarking a Harbor
release the manifest no longer names, and a lock with a package nothing asks for
is not installed into the venv a score is measured in. The only
build output is `zig-out/`, and `make clean` removes it along with
`.zig-cache/`. `make musl` also copies the static binary to
`integrations/harbor/microagent-<arch>-linux-musl`, named for the host's own
architecture, for the Harbor adapter; that one and the `.tmp` it is renamed
from are ignored, so nothing under `integrations/` is ever a build output a
commit picks up. A bench run appends its own line to the committed
`bench/results.jsonl`; that file is results, not code, so leave the appended line
out of a change that did not run a benchmark.

### Fuzz targets

A parser that reads bytes it did not write gets a `std.testing.fuzz` harness and
a corpus beside it, in the same file. The corpus is what the harness asserts on
during an ordinary `zig build test`, and that is where a new seed is written
down. The fuzzer's mutations, from the same seeds and then beyond them, want
`zig build test --fuzz`, and that does not build on the 0.16.0 this repository
pins: the toolchain's own test runner fails to compile under `-ffuzz`
(`compiler/test_runner.zig:566`, an `@errorReturnTrace()` the fuzzer's
instrumentation gives a different type), so the command fails before it reaches
a harness. Nothing in this tree can fix that, and a seed added to a corpus is
still asserted on every `make check` in the meantime. A harness asserts the
invariants, not just the absence of a crash: a turn assembled from a fuzzed
provider stream has to serialize as a valid request body, and a release body has
to earn the verdict that installs it.

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
before and the after in its entry. `make check-unreleased` is in `make check`
and in the push workflow, and asks that shape of the entry while it is still
under `[Unreleased]`: the five sections, each at most once, in that order. It
does not ask whether the change is worth an entry, which is the writer's call.
The 0.y policy and the rules a tag is refused for are `make check-changelog`
and `make check-release`, below.

Releases are tags: the release workflow publishes only when the tag names the
`build.zig.zon` version, that version has a `CHANGELOG.md` entry, and the bump
matches what the entry says. A patch tag whose section carries an `Added`, a
`Changed` or a `Removed` entry is refused, because under `0.y` those are what
the minor carries. Those three rules are `make check-release TAG=vX.Y.Z` and
`make check-changelog`, and release.yml runs those targets rather than its own
copy of the rules. The four published binaries and their asset names are spelled
once, in the [Makefile](Makefile), so a release can be built and checksummed on
a laptop before the tag exists:

```sh
make release-assets TAG=v0.2.0   # the four cross-built assets, in dist/
make checksums                   # the sha256 sidecars `update` verifies
make check-assets                # the host binary's version, and every asset's object format and machine
```

`make check-assets` reads `dist/` back rather than trusting the build that
wrote it: it runs the host binary and compares its `--version` with the tag
being built (the `TAG=` above, or the version `build.zig.zon` declares when
there is none), and reads each of the four assets for the object format its
target name promises and for the machine that format carries, because a cross
build that ignored `-Dtarget` and produced the host's architecture, or an empty
one, publishes green and fails on a user's machine. The magic alone would not
catch that: every Mach-O 64 file starts with `cffaedfe` whatever the CPU, and
every ELF with `7f454c46`, so `e_machine` at offset 18 and `cputype` at offset
4 are what say which. Both are declared per target, so a target added to
`RELEASE_TARGETS` says what it is before it can be published. It is the same
target `ci.yml` runs over the rehearsal build and `release.yml` runs over the
tagged one, so the check a laptop runs before a tag is the check the tag will
run.

The three rules a tag is refused for are commands here rather than shell inside
`release.yml`, so a release note is written against something runnable:

```sh
make check-changelog              # the section for the version build.zig.zon declares, and the 0.y policy on it
make check-changelog VERSION=0.2.1
make check-release TAG=v0.2.1     # what a tag has to satisfy: the version, and nothing left under [Unreleased]
```

`make check-changelog` prints the section it checked, which is what a release
publishes as the notes. `check-release` is the gate as a whole, and it refuses
an entry still parked under `[Unreleased]`, since the tag would drop it from
the published notes and land it in the next release under a version nobody ran.
Run it after the version bump and the entry is written, before the tag is cut.

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

A published release is never replaced: the publish step refuses a tag whose
release exists and is not a draft, because a consumer may already have fetched
it and which bytes they end up with is not this workflow's call. There is no
automated rollback, and the fix ships as the next release, which is what
[CHANGELOG.md](CHANGELOG.md) already states: only the latest release is
supported. A release that has to be withdrawn before that lands is removed in
the GitHub UI, and the tag with it. `microagent update` reads
`releases/latest`, so a withdrawn release stops being the one it resolves to; a
build already ahead of what remains is reported as ahead rather than downgraded
to an older asset. Deleting the tag is what keeps a withdrawn release from
coming back, since recreating the tag and re-running the workflow publishes it
again.

Contributors do not tag or publish.

## Commit messages

Short, imperative subject in lowercase, matching the existing history
(`fix: saturating token totals, codepoint-safe truncation, capped backoff`).
What changed and why, in the body when the subject cannot carry it.
