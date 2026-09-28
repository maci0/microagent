# microagent

A tiny coding agent in Zig, built to be driven by [gauntlet](https://github.com/maci0/gauntlet)
loops. One binary, one loop, OpenAI-compatible APIs only.

- **Small.** ~720 KB stripped (`-Doptimize=ReleaseSmall`), no runtime, no node, no python.
- **Fast.** ~2.5 ms to start, so a gauntlet loop spends its time in the model, not the harness.
- **No features you did not ask for.** No subagents, no plugins, no MCP, no TUI. Streaming chat
  completions, seven tools, done.

## Build

Zig 0.16.0 or newer, the minimum declared in `build.zig.zon`. Nothing else: no
dependencies, no services, no runtime.

```sh
zig build -Doptimize=ReleaseFast      # zig-out/bin/microagent
zig build -Doptimize=ReleaseSmall     # smallest binary, ~720 KB
zig build test                        # unit tests
```

Every target is also a make target, and `make help` lists them:

```sh
make                                   # ReleaseFast build, the default target
make help                              # every target
make test                              # the whole suite
make test-one FILTER="usage counters"  # one test, by name substring
make check                             # the CI gate: fmt --check, linters, tests, ReleaseSmall build
```

`make check` is what [CI](.github/workflows/ci.yml) runs on a push, on
the Zig version `build.zig.zon` names, so run it before pushing. Besides Zig it
needs `shellcheck`, `ruff` and `yamllint` on `PATH` for the bench, Harbor and
`.github` sources; `make lint-versions` names the pinned `ruff` and `yamllint`
the gate runs. `zig fmt` covers the Zig and needs nothing else.

## Use

```sh
export MICROAGENT_API_KEY=sk-or-...             # or OPENAI_API_KEY / OPENROUTER_API_KEY / DEEPSEEK_API_KEY
export MICROAGENT_BASE_URL=https://openrouter.ai/api/v1
export MICROAGENT_MODEL=deepseek/deepseek-v4-flash

microagent -p "fix the failing test and run it"
```

```
-p, --print <prompt>   task to run (also accepted as a bare argument)
-m, --model <model>    model id        (env MICROAGENT_MODEL)
-b, --base-url <url>   OpenAI-compatible base url (env MICROAGENT_BASE_URL);
                       https, or http on loopback
-k, --api-key <key>    api key         (env MICROAGENT_API_KEY, OPENAI_API_KEY,
                       OPENROUTER_API_KEY, DEEPSEEK_API_KEY)
    --max-turns <n>    tool-loop turn ceiling, at least 1
                       (env MICROAGENT_MAX_TURNS, default 100)
    --max-tokens <n>   max_tokens sent to the provider: the ceiling on one
                       response's generated tokens, at least 1
                       (env MICROAGENT_MAX_TOKENS, default 65536)
    --config <file>    reply-style TOML config (env MICROAGENT_CONFIG)
    --ca-bundle <file>
                       PEM file to trust instead of the system store
                       (env MICROAGENT_CA_BUNDLE, SSL_CERT_FILE). Needed in
                       images that ship no ca-certificates.
    --budget <seconds> stop starting turns after this long, then take one last
                       turn to make the edit, which may run 5 minutes past it.
                       A tool call still running is cut at the budget
                       (env MICROAGENT_BUDGET_SECONDS)
    --reasoning-effort <level>
                       reasoning.effort sent to the provider: minimal, low,
                       medium, high, or none to disable (env MICROAGENT_REASONING_EFFORT)
-h, --help             the full usage text
-V, --version          version

reply style (env, or the TOML config at MICROAGENT_CONFIG, default
~/.microagent/config.toml with the keys "caveman" and "ponytail"):
  MICROAGENT_CAVEMAN     how terse the reply is: off, lite, full, ultra,
                         wenyan-lite, wenyan-full, wenyan-ultra
                         (default ultra)
  MICROAGENT_PONYTAIL    how lazy the code is: off, lite, full, ultra
                         (default full)

subcommand:
  update [--check] [--repo owner/name]
                         replace this binary with the latest GitHub
                         release after verifying its .sha256 sidecar
                         (--check only reports; GITHUB_TOKEN lifts the
                         API rate limit)

MDEBUG=1                trace a stuck stream on stderr. 0, off, no, false and
                        an empty value all leave it off.
```

Every long flag also takes `--flag=value`, a flag wins over the environment variable for the same
option, and the exit status is 0 for a finished run, 1 for a failed one and 2 for a wrong command
line. `microagent --help` and `microagent update --help` are the full text; a wrong flag prints the
reason and that help on stderr, so a script reading stdout gets nothing from a failed invocation.

Every value is checked where it is set, so a mistyped level, a ceiling of zero
or a non-numeric budget is refused before the first request rather than becoming
a 400 or an empty run. A variable set to an empty string is not a value:
`MICROAGENT_MODEL`, `MICROAGENT_BASE_URL`, `MICROAGENT_REASONING_EFFORT`,
`MICROAGENT_BUDGET_SECONDS`, `MICROAGENT_MAX_TURNS`, `MICROAGENT_MAX_TOKENS`
and `MDEBUG` keep their
defaults, `MICROAGENT_CA_BUNDLE` falls through to `SSL_CERT_FILE`, and
`MICROAGENT_CAVEMAN`/`MICROAGENT_PONYTAIL` fall through to the config file.
`MICROAGENT_SESSION_DIR` is the one variable where empty means something else:
it turns the session log off.

The prompt may also be the last bare argument. That matters for gauntlet: a custom-agent
definition inserts the model flags immediately after `-p`, so an agent defined as
`["microagent", "-p", "{prompt}"]` would hand `--model` to `-p`. Define it as
`["microagent", "{prompt}"]` instead, and any flag order works.

With no key in the environment, `~/.secrets/openrouter` is read as a last resort.

Any OpenAI-compatible endpoint works: OpenRouter, DeepSeek, OpenAI, vLLM, LiteLLM, Z.AI. Both
`deepseek/deepseek-v4-flash` and `stealth/space-bunny-alpha` (OpenRouter) were used to verify it
end to end; see [BENCHMARK.md](BENCHMARK.md).

The api key goes to the base url in an `Authorization` header on every request, so a plain `http://`
base url is refused before the first one unless the host is loopback (`localhost`, `127.0.0.0/8`,
`::1`): a local gateway is the one plaintext case with no network path to intercept.

### Reply style

Two prompt-level knobs, set in one TOML file so a gauntlet loop, a container run and a laptop all
start the same way. Neither touches the tools or the request shape: both are text appended to the
system prompt, and the conversation is still the plain OpenAI message array.

```toml
caveman  = "ultra"   # how terse the reply is
ponytail = "full"    # how lazy the code is
```

The keys may also sit under a `[style]` table, and `#` comments are fine. That is the whole
configuration surface, so the file is read as `key = "value"` lines rather than with a full TOML
parser.

- **`caveman`** compresses the prose the agent writes back: `off`, `lite`, `full`, `ultra`, plus the
  three `wenyan-*` levels that write the reply in classical Chinese. Default `ultra` — a coding
  agent is judged on the diff, and every paragraph about it is re-sent on every later turn.
  Technical terms, code, commands, paths and exact error strings are never compressed, a negation is
  never dropped, and security warnings stay in plain English.
- **`ponytail`** biases what the agent builds rather than how it talks: `off`, `lite`, `full`,
  `ultra`. Reuse a helper the repository already has before writing a new one, the standard library
  and native platform features before a dependency, and the smallest diff that fixes the root cause
  rather than the symptom. Default `full`: a harness that writes fifty lines where five would do is
  the thing this project exists to avoid. Never at the cost of input validation at a trust boundary,
  error handling that prevents data loss, security, accessibility, or anything the task asks for.

The file is `MICROAGENT_CONFIG`, else `~/.microagent/config.toml`; a missing or unreadable file just
means the defaults. `MICROAGENT_CAVEMAN` and `MICROAGENT_PONYTAIL` set a level for one run without
touching the file and win over it, since naming a level in the environment is the more explicit
statement. A level that is not recognized is reported on stderr with that key's default kept, and so
is a key this file does not define, so a misspelled `caveman` cannot leave the default in force
quietly. With `caveman = "off"` and `ponytail = "off"`, the system prompt is exactly the one the
harness sent before styles existed.

### Output contract

stdout carries the model's own text, one JSON usage line per response, and nothing else:

```json
{"type":"usage","usage":{"prompt_tokens":910,"cached_tokens":832,"completion_tokens":18,"reasoning_tokens":0,"total_tokens":928}}
```

Token counters are cumulative for the run, which is the shape gauntlet's usage reader takes its
maximum from. Tool activity goes to stderr as a one-line gutter (`⏺ read src/main.zig`) so it never
pollutes the agent's answer. Control characters in a path or command are written as `\xNN`, so a line
stays one line whatever the model sent.

`cached_tokens` is the part of the prompt the provider served from its prompt cache. The whole
conversation is re-sent every turn, byte for byte: messages are only ever appended, and the system
prompt and tool schema never change, so the prefix stays cacheable and a turn pays full price only
for what it just added. Watch the counter on a multi-turn run — it should climb with the
conversation. It is read from whichever of `prompt_tokens_details.cached_tokens`,
`prompt_cache_hit_tokens` or `cache_read_input_tokens` the endpoint sends.

### Session log

Each run appends one JSONL record per model response to `~/.microagent/sessions/<unix-ns>.jsonl`
(`MICROAGENT_SESSION_DIR` moves it, an empty value turns it off), so a monitor can follow the run
while it is still going. A run that finds its name taken takes the next one (`-1`, `-2`, ...), so a
re-launched run writes beside the earlier log rather than over it:

```json
{"ts":1790608347342,"cwd":"/home/maci/Desktop/Projects/microagent","model":"deepseek/deepseek-v4-flash","finish_reason":"stop","elapsed_ms":1448,"usage":{"prompt_tokens":998,"cached_tokens":896,"completion_tokens":19,"reasoning_tokens":16,"total_tokens":1017}}
```

One response's own counters, not the run's cumulative ones, plus the directory the run works in and
how long the model spent on that response. `finish_reason` is why the provider stopped: `length`
means the response was cut at `--max-tokens`, so the turn is a prefix of what the model meant to
say, and the run says so on stderr rather than reporting it as a finished answer. The empty string
is a stream that carried no reason at all. The store keeps the 200 most recent runs and prunes the
older ones, so a machine that runs this in a loop does not accumulate a log per review forever.
`elapsed_ms` is the model's time, so a reader computes
tokens per second the model actually generated instead of over a gap that includes tool calls.
[toktop](https://github.com/maci0/toktop) reads this store by default; the counters and the
directory are the ordinary OpenAI keys and `cwd`, so any reader of agent transcripts works. Nothing
in the log is prompt or output text.

## Update

```sh
microagent update                         # replace this binary with the latest release
microagent update --check                 # report the latest release, install nothing
microagent update --repo you/microagent   # track a fork
```

The release publishes `microagent-<tag>-<triple>` for `x86_64-linux-musl`, `aarch64-linux-musl`,
`x86_64-macos` and `aarch64-macos`, each with a `.sha256` sidecar. Linux has one asset per arch and
not one per libc: the static musl binary runs on a glibc host, so a `-gnu` build updates to it. The
download is verified against
that sidecar and the running binary is replaced (atomically, following a symlink to the real file)
only when the digest matches: a mismatch, a missing asset, or a release page that is not a GitHub
https URL leaves the binary untouched. `GITHUB_TOKEN` lifts the anonymous API rate limit. Exit 1
means the check or the install failed, 2 is a usage error.

## Versioning

The version is `build.zig.zon` and nothing else, and [CHANGELOG.md](CHANGELOG.md) is the record of
what changed in it. The project is under `0.y`, so the minor takes features and any change to what a
run does by default, and the patch takes fixes: upgrading a patch must not change an existing
invocation. Breaking changes to the flags, the environment variables or the stdout and session-log
JSON come with a changelog entry naming the before and the after, before the tag. Only the latest
release is supported, with no backport window: a fix ships in the next release.

## Tools

Seven tools, all of them thin wrappers over tools you already have:

| tool | what it does |
| --- | --- |
| `bash` | `/bin/sh -c`, 120 s default timeout (600 s ceiling on what the model may ask for), output capped at 24 KB |
| `read` | read a file, optional line offset/limit |
| `write` | create or overwrite a file, parents created |
| `edit` | exact string replacement, refuses an ambiguous match unless `replace_all` |
| `search` | `rg --line-number --no-heading`, optional glob |
| `ast` | `ast-grep run` for structural match, or `--rewrite --update-all` to apply one |
| `git` | read-only `status`, `diff`, `log`, `show`, `blame`, capped at 400 lines |

The system prompt tells the model to search with ripgrep and rewrite structurally with `ast-grep`
rather than reimplementing either in the harness. `bash` is there for builds and tests; git state
has its own tool, with the subcommands fixed here instead of assembled by the model.

Everything a tool returns is untrusted text on its way back into the prompt: a file, a diff, a
build log. The system prompt says so, and tool results ride back as `tool` messages, so a
repository that ships a file telling the model to run something is data the run reports rather
than an instruction it follows. The other bound on the same loop is `max_tokens` on every
request: without it a model that fails to stop is billed until something else stops it, and
`--max-turns` is a turn count, not a token count.

A transient failure — 429, any 5xx, a dropped connection — is retried twice with 1 s and 2 s of
backoff before the run exits non-zero, so a provider's bad minute does not make gauntlet redo a
review against a tree the agent has already half-changed. A rejected request (400/401/404) fails
immediately instead. Session resume is deliberately absent; gauntlet's `--retries` covers a whole
review, and a missing feature is cheaper than a half-working one.

## gauntlet

Recent gauntlet builds know microagent as a built-in agent: `gauntlet doctor` lists it, and
`gauntlet -a microagent -r quick --once` works with no configuration. On an older release that
refuses it as an unknown tool, register it once in `~/.gauntlet/agents.json`:

```json
{
  "microagent": {
    "argv": ["microagent", "{prompt}"],
    "model": ["--model", "{model}"],
    "note": "microagent: tiny zig OpenAI-compatible coding agent"
  }
}
```

Delete that entry once gauntlet ships the built-in: a definition file naming a built-in agent is
refused at startup rather than ignored.

Then:

```sh
gauntlet doctor                       # microagent should show as installed
gauntlet -a microagent -r quick --once
gauntlet -a microagent:deepseek/deepseek-v4-flash -j 4
MICROAGENT_BUDGET_SECONDS=600 gauntlet -a microagent -r quick --once
```

Set a budget below gauntlet's `-t` timeout. A review the harness kills at the ceiling with an
untouched tree is worth nothing; one that stops deliberately still has the model's diff. Note that
gauntlet scoring a review "Passed" does not mean a diff landed — score with `git diff --numstat` and
a real check, the way `bench/gauntlet.sh` does. Review outcomes per harness, including which models
converged and which burned the budget, are in [BENCHMARK.md](BENCHMARK.md#usefulness).

No `stream` flags are needed: usage is always machine-readable. No session transcripts are written,
so no `usage.roots` entry is required either.

## Security

The agent runs shell commands as you do, on files it reads, so the repository it works in and
the endpoint it talks to are both part of the surface. [THREAT_MODEL.md](THREAT_MODEL.md) has the
entry points, the boundaries, the controls that exist and the gaps, each with a file reference.

## External benchmarks

microagent runs on [Harbor](https://github.com/laude-institute/harbor) benchmarks — Terminal-Bench 2
and SWE-bench Verified — as a static musl binary inside the task container:

```sh
make musl
PYTHONPATH=$PWD/integrations/harbor ~/harbor-venv/bin/harbor run \
  -d swebench-verified@1.0 -i pytest-dev__pytest-5809 \
  -a microagent_agent:Microagent -m deepseek/deepseek-v4-flash
```

See [integrations/harbor/README.md](integrations/harbor/README.md) and
[BENCHMARK.md](BENCHMARK.md#swe-bench-verified).

## Benchmarks

```sh
bench/run.sh microagent kimi opencode   # three coding tasks, pass/fail + wall time + tokens
bench/gauntlet.sh microagent kimi       # the same gauntlet reviews per agent, scored on pass + diff + verify
bench/overhead.sh                       # startup latency and no-op request cost per harness
```

Results from this machine are in [BENCHMARK.md](BENCHMARK.md).
