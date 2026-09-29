<p align="center">
  <img src="docs/logo.svg" width="128" height="128" alt="microagent logo: a mu glyph after a shell prompt">
</p>

<h1 align="center">microagent</h1>

<p align="center">
  A coding agent that runs in under 1 MB of memory: one static binary, built to run unattended in review loops and benchmarks.
</p>

---

microagent takes a task, talks to any OpenAI-compatible model, and edits the tree in front of it
with nine tools: `bash`, `read`, `write`, `edit`, `multi_edit`, `search`, `ast`, `git`, `todo`. It was written to be the
agent a [gauntlet](https://github.com/maci0/gauntlet) review loop or a
[Harbor](https://github.com/laude-institute/harbor) benchmark container calls hundreds of times.

## Why

Agent CLIs are built for a person at a terminal: a TUI, a node or python runtime, an install step,
plugins, session state. None of that helps when a script calls the agent in a loop or drops it into
a container that has nothing installed. microagent is the other shape:

- **A memory footprint you can ignore.** About 0.6 MB resident at start, 0.8 MB up to the first
  request, 1.3 MB after 50,000 streamed frames. At `--version`, `grok` holds 25 MB,
  `codex` 28 MB, `claude` 37 MB, `opencode` 198 MB and `kimi` 326 MB. A hundred idle copies are
  60 MB of microagent and 2.5 GB of `grok`.
- **Nothing to install.** One Zig binary of about 0.9 MB with no runtime. On Linux it links no C
  library at all, so the one static file runs in any Linux container of its architecture.
- **Starts in microseconds.** The harness is under 1% of a turn; the model and the tools are the
  run. Kimi and opencode burn three quarters of a second of CPU just to print their version.
- **Script-shaped output.** stdout is the answer plus one JSON usage line per response. Everything
  else goes to stderr. Exit codes separate "finished", "failed", "bad invocation" and "stopped at a
  ceiling".
- **Bounded by default.** Turn, token, spend and wall-clock ceilings, a request that is never
  re-sent once the provider has it, and a prompt prefix that stays byte-identical so the provider's
  cache keeps hitting.
- **Small on purpose.** No subagents, no plugins, no TUI. Skills and MCP servers are yours to add. Four public remote
  tools (web search, library docs, GitHub code search, repository wikis) are on by default, described by
  this binary rather than by a start-up handshake, so they cost nothing until one is called.

## What it looks like

A fresh build on this machine (x86_64 Linux, Zig 0.16.0):

```console
$ zig build -Doptimize=ReleaseSmall
$ python3 bench/maxrss.py ./zig-out/bin/microagent --version    # peak resident kB
632
$ hyperfine -N -w 5 -r 30 './zig-out/bin/microagent --version'
  Time (mean ± σ):     130.0 µs ±  64.5 µs    [User: 87.1 µs, System: 4.4 µs]
```

`ReleaseSmall` is the build the release assets and `make` use, because it holds the least of the three
release modes; the three, their memory and their instruction counts are in
[docs/benchmark.md](docs/benchmark.md#memory-footprint).

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
sidecar. Pick the target your machine runs:

```sh
v=v0.6.0 t=x86_64-linux-musl
curl -fLO https://github.com/maci0/microagent/releases/download/$v/microagent-$v-$t
curl -fLO https://github.com/maci0/microagent/releases/download/$v/microagent-$v-$t.sha256
# GNU coreutils spells it sha256sum, macOS ships shasum; both read the same
# `<digest>  <name>` line. Which one a host has is probed, not read off its name.
if command -v sha256sum >/dev/null 2>&1; then sum=sha256sum; else sum="shasum -a 256"; fi
$sum -c microagent-$v-$t.sha256 && mkdir -p ~/.local/bin && install -m 755 microagent-$v-$t ~/.local/bin/microagent
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
environment variables, the config file (system prompt addendum, skills, MCP servers), the tools and their
credential guards, the stdout and session-log formats, exit codes, retries, gauntlet setup, and
self-update.

## Status

Version 0.6.0. What works: the tool loop against OpenRouter, DeepSeek, OpenAI and any other
OpenAI-compatible endpoint; skills; MCP servers over stdio; the session log; verified self-update;
reproducible release builds for Linux and macOS.

Deliberately absent: session resume (gauntlet's `--retries` reruns a whole review), parallel tool
calls, a TUI, Windows builds. Not built yet, with what would settle each on
[docs/todo.md](docs/todo.md): subagents and language-server tools. What the harness costs and which optimizations were
measured and rejected is in [docs/performance.md](docs/performance.md).

Known limits: credential protection is a filename rule, so a key file with an unrecognized name, or
a path a command builds at run time, is still readable. [docs/threat-model.md](docs/threat-model.md)
lists this and the other gaps, ranked.

## Documentation

| | |
| --- | --- |
| [docs/usage.md](docs/usage.md) | every flag, variable, config key, tool and output format |
| [docs/benchmark.md](docs/benchmark.md) | memory footprint, startup, token overhead, Terminal-Bench 4.0 and 2, Aider polyglot, DeepSWE, SWE-bench Verified, head to head with opencode |
| [docs/performance.md](docs/performance.md) | where the CPU goes, what was optimized, what was measured and left alone |
| [docs/todo.md](docs/todo.md) | what is not built yet, and what would settle each item |
| [docs/threat-model.md](docs/threat-model.md) | entry points, trust boundaries, controls and open gaps |
| [integrations/harbor](integrations/harbor/README.md) | running microagent inside Harbor benchmark containers |
| [CONTRIBUTING.md](CONTRIBUTING.md) | repository layout, the `make check` gate, tests, releases |
| [CHANGELOG.md](CHANGELOG.md) | every change, by version |

## Development

```sh
make            # ReleaseSmall build, the smallest resident memory
make test       # the whole suite
make check      # the CI gate: format, linters, tests, sanitizer run, ReleaseSmall build
make help       # every target
```

## License

MIT, in [LICENSE](LICENSE).
