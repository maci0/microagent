<p align="center">
  <img src="docs/logo.svg" width="128" height="128" alt="microagent logo: a mu glyph after a shell prompt">
</p>

<h1 align="center">microagent</h1>

<p align="center">
  A coding agent in one 0.9 MB static binary, built to run unattended in review loops and benchmarks.
</p>

---

microagent takes a task, talks to any OpenAI-compatible model, and edits the tree in front of it
with seven tools: `bash`, `read`, `write`, `edit`, `search`, `ast`, `git`. It was written to be the
agent a [gauntlet](https://github.com/maci0/gauntlet) review loop or a
[Harbor](https://github.com/laude-institute/harbor) benchmark container calls hundreds of times.

## Why

Agent CLIs are built for a person at a terminal: a TUI, a node or python runtime, an install step,
plugins, session state. None of that helps when a script calls the agent in a loop or drops it into
a container that has nothing installed. microagent is the other shape:

- **Nothing to install.** One Zig binary with no runtime. The Linux build is static musl, so it runs
  in any Linux container of its architecture.
- **Starts in milliseconds.** The harness is under 1% of a turn; the model and the tools are the
  run. Kimi and opencode take a second or more just to print their version.
- **Script-shaped output.** stdout is the answer plus one JSON usage line per response. Everything
  else goes to stderr. Exit codes separate "finished", "failed", "bad invocation" and "stopped at a
  ceiling".
- **Bounded by default.** Turn, token, spend and wall-clock ceilings, a request that is never
  re-sent once the provider has it, and a prompt prefix that stays byte-identical so the provider's
  cache keeps hitting.
- **Nothing you did not ask for.** No subagents, no plugins, no TUI. Skills and MCP servers exist
  and stay off until a config names them.

## What it looks like

A fresh build on this machine (x86_64 Linux, Zig 0.16.0):

```console
$ zig build -Doptimize=ReleaseSmall && ls -l zig-out/bin/microagent
-rwxr-xr-x 1 maci maci 902840 Sep 29 11:06 zig-out/bin/microagent
$ hyperfine -N -w 5 -r 30 './zig-out/bin/microagent --version'
  Time (mean ± σ):     570.2 µs ± 306.1 µs    [User: 283.1 µs, System: 161.8 µs]
```

A run prints the model's answer to stdout and a usage line after each response; tool calls show on
stderr as a one-line gutter such as `⏺ read src/main.zig`:

```json
{"type":"usage","usage":{"prompt_tokens":910,"cached_tokens":832,"completion_tokens":18,"reasoning_tokens":0,"total_tokens":928}}
```

On a 23-task stride sample of Terminal-Bench 2, same model and containers, microagent solved 11
against opencode's 7, and finished every trial where opencode hit 12 setup or timeout exceptions.
It also spent about 1.9x the input tokens. Details, caveats and error bars are in
[docs/benchmark.md](docs/benchmark.md).

## Install

Prebuilt binaries for `x86_64-linux-musl`, `aarch64-linux-musl`, `x86_64-macos` and `aarch64-macos`
are on the [releases page](https://github.com/maci0/microagent/releases), each with a `.sha256`
sidecar:

```sh
v=v0.3.0 t=x86_64-linux-musl
curl -fLO https://github.com/maci0/microagent/releases/download/$v/microagent-$v-$t
curl -fLO https://github.com/maci0/microagent/releases/download/$v/microagent-$v-$t.sha256
sha256sum -c microagent-$v-$t.sha256 && install -m 755 microagent-$v-$t ~/.local/bin/microagent
```

`microagent update` replaces an installed binary with the latest release after checking its digest.

Or build it. Zig 0.16.0 or newer is the only requirement:

```sh
zig build -Doptimize=ReleaseSmall     # zig-out/bin/microagent
```

The `search`, `ast` and `git` tools call `rg`, `ast-grep` and `git`, so put those on `PATH` too.

## First run

```sh
export MICROAGENT_API_KEY=sk-or-...                    # any OpenAI-compatible provider's key
export MICROAGENT_BASE_URL=https://openrouter.ai/api/v1 # the default
export MICROAGENT_MODEL=deepseek/deepseek-v4-flash     # the default

microagent "fix the failing test and run it"
```

`microagent --help` lists every flag. [docs/usage.md](docs/usage.md) is the full reference: flags and
environment variables, the config file (reply style, skills, MCP servers), the tools and their
credential guards, the stdout and session-log formats, exit codes, retries, gauntlet setup, and
self-update.

## Status

Version 0.3.0. What works: the tool loop against OpenRouter, DeepSeek, OpenAI and any other
OpenAI-compatible endpoint; skills; MCP servers over stdio; the session log; verified self-update;
reproducible release builds for Linux and macOS.

Deliberately absent: session resume (gauntlet's `--retries` reruns a whole review), parallel tool
calls, subagents, a TUI, Windows builds. What the harness costs and which optimizations were
measured and rejected is in [docs/performance.md](docs/performance.md).

Known limits: credential protection is a filename rule, so a key file with an unrecognized name, or
a path a command builds at run time, is still readable. [docs/threat-model.md](docs/threat-model.md)
lists this and the other gaps, ranked.

## Documentation

| | |
| --- | --- |
| [docs/usage.md](docs/usage.md) | every flag, variable, config key, tool and output format |
| [docs/benchmark.md](docs/benchmark.md) | size, startup, token overhead, Terminal-Bench 2, SWE-bench Verified, head to head with opencode |
| [docs/performance.md](docs/performance.md) | where the CPU goes, what was optimized, what was measured and left alone |
| [docs/threat-model.md](docs/threat-model.md) | entry points, trust boundaries, controls and open gaps |
| [integrations/harbor](integrations/harbor/README.md) | running microagent inside Harbor benchmark containers |
| [CONTRIBUTING.md](CONTRIBUTING.md) | repository layout, the `make check` gate, tests, releases |
| [CHANGELOG.md](CHANGELOG.md) | every change, by version |

## Development

```sh
make            # ReleaseFast build
make test       # the whole suite
make check      # the CI gate: format, linters, tests, sanitizer run, ReleaseSmall build
make help       # every target
```

## License

MIT, in [LICENSE](LICENSE).
