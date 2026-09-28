# microagent

A tiny coding agent in Zig, built to be driven by [gauntlet](https://github.com/maci0/gauntlet)
loops. One binary, one loop, OpenAI-compatible APIs only.

- **Small.** ~600 KB stripped (`-Doptimize=ReleaseSmall`), no runtime, no node, no python.
- **Fast.** ~2.5 ms to start, so a gauntlet loop spends its time in the model, not the harness.
- **No features you did not ask for.** No subagents, no plugins, no MCP, no TUI. Streaming chat
  completions, six tools, done.

## Build

```sh
zig build -Doptimize=ReleaseFast      # zig-out/bin/microagent
zig build -Doptimize=ReleaseSmall     # smallest binary, ~600 KB
zig build test                        # unit tests
```

## Use

```sh
export MICROAGENT_API_KEY=sk-or-...             # or OPENAI_API_KEY / OPENROUTER_API_KEY
export MICROAGENT_BASE_URL=https://openrouter.ai/api/v1
export MICROAGENT_MODEL=deepseek/deepseek-v4-flash

microagent -p "fix the failing test and run it"
```

```
-p, --print <prompt>   task to run (also accepted as a bare argument)
-m, --model <model>    model id        (env MICROAGENT_MODEL)
-b, --base-url <url>   OpenAI-compatible base url (env MICROAGENT_BASE_URL)
-k, --api-key <key>    api key         (env MICROAGENT_API_KEY, OPENAI_API_KEY, OPENROUTER_API_KEY)
    --max-turns <n>    tool-loop ceiling (default 60)
    --budget <seconds> stop starting turns after this long, then take one last
                       turn to make the edit (env MICROAGENT_BUDGET_SECONDS)
    --reasoning-effort <level>
                       reasoning.effort sent to the provider: minimal, low,
                       medium, high, or none to disable (env MICROAGENT_REASONING_EFFORT)
```

The prompt may also be the last bare argument. That matters for gauntlet: a custom-agent
definition inserts the model flags immediately after `-p`, so an agent defined as
`["microagent", "-p", "{prompt}"]` would hand `--model` to `-p`. Define it as
`["microagent", "{prompt}"]` instead, and any flag order works.

With no key in the environment, `~/.secrets/openrouter` is read as a last resort.

Any OpenAI-compatible endpoint works: OpenRouter, DeepSeek, OpenAI, vLLM, LiteLLM, Z.AI. Both
`deepseek/deepseek-v4-flash` and `stealth/space-bunny-alpha` (OpenRouter) were used to verify it
end to end; see [BENCHMARK.md](BENCHMARK.md).

### Output contract

stdout carries the model's own text, one JSON usage line per response, and nothing else:

```json
{"type":"usage","usage":{"prompt_tokens":910,"completion_tokens":18,"reasoning_tokens":0,"total_tokens":928}}
```

Token counters are cumulative for the run, which is the shape gauntlet's usage reader takes its
maximum from. Tool activity goes to stderr as a one-line gutter (`⏺ read src/main.zig`) so it never
pollutes the agent's answer.

## Tools

Six tools, all of them thin wrappers over tools you already have:

| tool | what it does |
| --- | --- |
| `bash` | `/bin/sh -c`, 120 s default timeout, output capped at 24 KB |
| `read` | read a file, optional line offset/limit |
| `write` | create or overwrite a file, parents created |
| `edit` | exact string replacement, refuses an ambiguous match unless `replace_all` |
| `search` | `rg --line-number --no-heading`, optional glob |
| `ast` | `ast-grep run` for structural match, or `--rewrite --update-all` to apply one |

The system prompt tells the model to search with ripgrep and rewrite structurally with `ast-grep`
rather than reimplementing either in the harness. `bash` is there for builds, tests and git.

A transient failure — 429, any 5xx, a dropped connection — is retried twice with 1 s and 2 s of
backoff before the run exits non-zero, so a provider's bad minute does not make gauntlet redo a
review against a tree the agent has already half-changed. A rejected request (400/401/404) fails
immediately instead. Session resume is deliberately absent; gauntlet's `--retries` covers a whole
review, and a missing feature is cheaper than a half-working one.

## gauntlet

Register it once in `~/.gauntlet/agents.json`:

```json
{
  "microagent": {
    "argv": ["microagent", "{prompt}"],
    "model": ["--model", "{model}"],
    "note": "microagent: tiny zig OpenAI-compatible coding agent"
  }
}
```

Then:

```sh
gauntlet doctor                       # microagent should show as installed
gauntlet -a microagent -r quick --once
gauntlet -a microagent:deepseek/deepseek-v4-flash -j 4
MICROAGENT_BUDGET_SECONDS=600 gauntlet -a microagent -r quick --once
```

Set a budget below gauntlet's `-t` timeout. A review the harness kills at the ceiling with an
untouched tree is worth nothing; one that stops deliberately still has the model's diff. Review
outcomes per harness are in [BENCHMARK.md](BENCHMARK.md#usefulness).

No `stream` flags are needed: usage is always machine-readable. No session transcripts are written,
so no `usage.roots` entry is required either.

## Benchmarks

```sh
bench/run.sh microagent kimi opencode   # three coding tasks, pass/fail + wall time + tokens
bench/gauntlet.sh microagent kimi       # the same gauntlet reviews per agent, scored on the diff
bench/overhead.sh                       # startup latency and no-op request cost per harness
```

Results from this machine are in [BENCHMARK.md](BENCHMARK.md).
