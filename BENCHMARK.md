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
| **microagent** | **2.5 ms** |
| claude | 22.1 ms |
| grok | 38.1 ms |
| codex | 49.6 ms |
| opencode | 1022 ms |
| kimi | 1236 ms |

A gauntlet loop starts an agent once per review, so this is per-review overhead. On a 60 s review,
2.3 ms is 0.004% of the loop; on the node-based harnesses it is still under 0.1%. The number
matters for the tight loops people actually run (`--retries`, short timeouts, hundreds of reviews),
not for one review.

## Harness prompt overhead

First request of a run, from the usage line microagent prints:

| | tokens |
| --- | --- |
| system prompt + 6 tool schemas + one-line user prompt | **933** |

That is the entire fixed cost of the harness, measured rather than estimated. Competitor CLIs in
one-shot mode did not report a comparable number on this machine, so none is claimed for them.

## Task benchmark

Three small tasks with their own checks (`bench/tasks/*`, each `setup.sh` + `prompt.txt` +
`check.sh`). A task passes only if the check exits 0; the check is never visible to the agent as a
tool, and the prompt says not to touch the test.

`sh bench/run.sh microagent kimi`:

| harness | model | task | wall | tokens | diff | result |
| --- | --- | --- | --- | --- | --- | --- |
| microagent | deepseek/deepseek-v4-flash (OpenRouter) | cli-flag | 12.0 s | 5835 | +4/-1 | pass |
| microagent | " | empty-mean | 9.3 s | 5212 | +2/-0 | pass |
| microagent | " | parse-bug | 9.3 s | 6566 | +2/-2 | pass |
| kimi | kimi default | cli-flag | 12.7 s | n/a | +4/-1 | pass |
| kimi | " | empty-mean | 14.3 s | n/a | +2/-0 | pass |
| kimi | " | parse-bug | 12.2 s | n/a | +3/-8 | pass |

Both harnesses solved 3/3; wall time tracks the model behind each harness, not the harness. Tokens
are run-cumulative for microagent (summed over every turn) and unavailable for kimi, which prints no
machine-readable counters. Repeated runs vary by several seconds and a few thousand tokens because
the provider routes `deepseek-v4-flash` to different upstreams; pass/fail is the stable column.

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

Both diffs were the correct fix, and gauntlet read the token counts out of microagent's stdout
usage lines with no `usage.roots` session-store entry configured.

## Reproducing

```sh
zig build -Doptimize=ReleaseFast && make install
export MICROAGENT_API_KEY=...      # or leave unset to read ~/.secrets/openrouter
export MICROAGENT_MODEL=deepseek/deepseek-v4-flash
sh bench/run.sh microagent kimi
sh bench/overhead.sh
```

Raw rows land in `bench/results.jsonl`.
