# Harness benchmark

What is measured here is the harness, not the model: how long the binary takes to exist, how many
tokens it spends before the model says anything, and whether the loop it drives can actually finish
a task. Model latency dominates wall time in any loop, so the harness numbers are the ones worth
comparing.

Machine: x86_64 Linux, Zig 0.16.0, `bench/overhead.sh` and `bench/run.sh` as committed. Every number
below was produced by those scripts, not by hand.

## Size

| build | binary |
| --- | --- |
| `-Doptimize=ReleaseSmall` (stripped) | 605 KB |
| `-Doptimize=ReleaseFast` (stripped) | 1.08 MB |
| `-Doptimize=ReleaseSafe` (stripped) | 1.34 MB |
| `Debug` (unstripped) | 31 MB |

No runtime, no package manager, no node_modules, no python. One file, 713 lines.

## Startup

`--version`, hyperfine, 20-50 runs, no shell (`-N`):

| harness | mean |
| --- | --- |
| **microagent** | **1.4 - 2.5 ms** |
| claude | 22.1 ms |
| grok | 38.1 ms |
| codex | 49.6 ms |
| kimi 2.1.1 | 1.0 - 1.2 s |
| opencode 1.18.31 | 1.0 - 1.9 s |

Startup for the node-based harnesses moves by hundreds of milliseconds between runs on a loaded
machine, so a range is reported rather than a single figure.

A gauntlet loop starts an agent once per review, so this is per-review overhead. On a 60 s review,
2 ms is 0.003% of the loop; on the node-based harnesses it is still under 0.1%. The number
matters for the tight loops people actually run (`--retries`, short timeouts, hundreds of reviews),
not for one review.

## Harness prompt overhead

First request of a run, from the usage line microagent prints:

| | tokens |
| --- | --- |
| system prompt + 6 tool schemas + one-line user prompt | **933** |

That is the entire fixed cost of the harness, measured rather than estimated. Competitor CLIs in
one-shot mode did not report a comparable number on this machine, so none is claimed for them.

## One trivial request

`Reply with exactly: pong`, one-shot, no repository involved. This is harness overhead plus one
round trip, and the floor for any loop.

| harness | model | wall | run tokens |
| --- | --- | --- | --- |
| microagent | deepseek/deepseek-v4-flash | 3.9 s | 972 |
| opencode | build · big-pickle | 4.2 s | n/a |
| kimi | kimi CLI default | 8.2 s | n/a |

Only microagent prints machine-readable counters, so the token column is not a comparison.

## Task benchmark

Three small tasks with their own checks (`bench/tasks/*`, each `setup.sh` + `prompt.txt` +
`check.sh`). A task passes only if the check exits 0; the check is never visible to the agent as a
tool, and the prompt says not to touch the test.

`sh bench/run.sh microagent kimi opencode`:

| harness | model | task | wall | tokens | diff | result |
| --- | --- | --- | --- | --- | --- | --- |
| microagent | deepseek/deepseek-v4-flash (OpenRouter) | cli-flag | 17.7 s | 7284 | +4/-1 | pass |
| microagent | " | empty-mean | 10.6 s | 5228 | +2/-0 | pass |
| microagent | " | parse-bug | 18.0 s | 5853 | +2/-2 | pass |
| kimi 2.1.1 | CLI default | cli-flag | 31.3 s | n/a | +5/-1 | pass |
| kimi | " | empty-mean | 23.7 s | n/a | +2/-0 | pass |
| kimi | " | parse-bug | 20.5 s | n/a | +2/-2 | pass |
| opencode 1.18.31 | build · big-pickle | cli-flag | 34.3 s | n/a | +4/-1 | pass |
| opencode | " | empty-mean | 22.3 s | n/a | +2/-0 | pass |
| opencode | " | parse-bug | 42.4 s | n/a | +2/-2 | pass |

All three harnesses solved 3/3, each with the minimal correct diff. microagent was fastest on every
task on this machine, but the models differ (a stealth model behind opencode, an unspecified Kimi
default, deepseek-v4-flash behind microagent), so wall time here compares *stacks*, not harness
overheads; the startup, size and prompt-overhead sections are the harness-only numbers. Tokens are
run-cumulative for microagent and unavailable for the other two, which print no machine-readable
counters in one-shot mode.

Other installed harnesses could not be compared cleanly on this machine: `claude` is rate-limited
until the weekly reset, `grok` returns HTTP 402 (balance exhausted), `codex` refuses to run outside
a trusted directory without an extra flag, `crush` reports its model unavailable. A benchmark that
silently recorded those as failures would be worse than one that names them.

## gauntlet loop

The point of the harness. Registered as a custom agent in `~/.gauntlet/agents.json`, then:

```sh
gauntlet -a microagent -r code-review --max-reviews 1 --once -C <scratch repo> -t 8m -y
```

Two independent runs on scratch repositories:

| run | reviews | result | wall | tokens | diff |
| --- | --- | --- | --- | --- | --- |
| `calc.py` (empty-iterable crash) | code-review | passed | 2m41s | 1,833 reported | +5/-1 |
| `duration.py` (wrong unit math) | code-review | passed | 1m00s | 3,173 reported | +2/-2 |
| `calc.py` (empty-iterable crash) | code-review | passed | 1m04s | 3,012 reported | +2/-0 |
| `wc.py` (missing CLI flag) | code-review | passed | 47s | 2,151 reported | +7/-1 |

Both diffs were the correct fix, and gauntlet read the token counts out of microagent's stdout
usage lines with no `usage.roots` session-store entry configured.

## Fault injection

A local OpenAI-compatible endpoint that answers 503 twice and then streams a valid completion
(`/tmp/flaky.py`, not committed) confirms the retry path rather than assuming it:

| request | server | client |
| --- | --- | --- |
| 1 | 503 | waits 1 s |
| 2 | 503 | waits 2 s |
| 3 | 200 SSE | parses `pong`, prints usage, exits 0 |

Total 3.0 s, dominated by the backoff. A 400 (invalid model) is not retried: it fails immediately
with the provider's message on stderr and exit code 1. The same run also proves plain-HTTP base
URLs work, so a local vLLM or LiteLLM endpoint needs no TLS.

## Reproducing

```sh
zig build -Doptimize=ReleaseFast && make install
export MICROAGENT_API_KEY=...      # or leave unset to read ~/.secrets/openrouter
export MICROAGENT_MODEL=deepseek/deepseek-v4-flash
sh bench/run.sh microagent kimi opencode
sh bench/overhead.sh
```

Raw rows land in `bench/results.jsonl`.
