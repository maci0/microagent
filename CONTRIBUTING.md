# Contributing

## Setup

Zig 0.16.0 or newer, the minimum declared as `.minimum_zig_version` in
[build.zig.zon](build.zig.zon). There is no dependency to install, no service to
start, and no configuration to copy. A clone plus a Zig toolchain is a working
checkout.

```sh
make            # zig-out/bin/microagent
make small      # the ReleaseSmall binary
```

## Before you push

```sh
make check                  # zig fmt --check plus the whole test suite
make test-one FILTER="..."  # one test, while you are mid-edit
```

`make check` is the whole gate: it is the same `zig fmt --check` and
`zig build test` that [.github/workflows/ci.yml](.github/workflows/ci.yml) runs,
on the same Zig version. `make help` lists every target. Source is formatted
with `zig fmt`; `make fmt` applies it.

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

## Version and changelog

The version is `.version` in `build.zig.zon` and nowhere else. Every change that
lands gets a [CHANGELOG.md](CHANGELOG.md) entry under `## [Unreleased]`, in the
Keep a Changelog sections already in use. Under `0.y` the minor carries features
and anything that changes what a run does by default; the patch carries fixes,
and a patch must not change what an existing invocation does. A change to the
flags, the environment variables, or the stdout and session-log JSON names the
before and the after in its entry.

Releases are tags: the release workflow publishes only when the tag names the
`build.zig.zon` version and that version has a `CHANGELOG.md` entry. Contributors
do not tag or publish.

## Commit messages

Short, imperative subject in lowercase, matching the existing history
(`fix: saturating token totals, codepoint-safe truncation, capped backoff`).
What changed and why, in the body when the subject cannot carry it.
