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

## Usefulness

The three-task benchmark above measures plumbing: can the loop drive tools and land a diff. It says
nothing about whether the harness is *useful* on real work. The standard external measures for that
are SWE-bench Verified, SWE-bench Pro and Terminal-Bench 2 (harbor), and none of them is wired up
here — see "Not measured" below for why. What is wired up is `bench/gauntlet.sh`: the same gauntlet
reviews, on the same repository clone, run once per agent, scored on what actually landed.

`sh bench/gauntlet.sh microagent kimi` clones the repo per agent, runs `-r quick --max-reviews 2`
against it, and reports passes, files changed and wall time:

| agent | passed | failed | files changed | wall | tokens |
| --- | --- | --- | --- | --- | --- |
| microagent (deepseek-v4-flash) | 0 | 2 | 0 | 720 s | 25 803 |
| kimi 2.1.1 | 2 | 0 | 2 | 462 s | n/a |

Both microagent reviews hit the 6-minute per-review timeout; the tree was untouched at the end
(`git status` clean). gauntlet reported the agent's reasoning as 93% of its output — deepseek-v4-flash
spent the budget thinking at ~36 tok/s and never got to editing, having also burned turns looking for
the repository in a path it invented. kimi finished both reviews inside the budget.

This is the number that matters and it is worse than the toy tasks suggested, so it is left in the
document rather than buried: a harness that cannot finish a review inside a normal timeout is not
useful no matter how small it is. Attribution (model speed vs harness behaviour) is an open item,
not a claim.

### Not measured

- **SWE-bench Verified / SWE-bench Pro** — the user's `benchmark-harnesses` checkout runs these
  through Strands SSA, which *is* the agent (a Python loop with its own tool calling). A CLI harness
  cannot be substituted for it; comparing microagent would need those datasets driven by a
  microagent-specific runner.
- **Terminal-Bench 2** — harbor accepts an agent as `--agent-import-path`, i.e. a Python adapter
  class, so microagent is pluggable in principle: one adapter that shells out to
  `microagent -p <instruction>` inside the task container. It was not built here because it needs the
  `terminal-bench@2.0` dataset, the per-task docker images (`TB2_ECR_MAP`) and roughly a gigabyte of
  pulls, none of which are cached on this machine.
- **DSH's own `benchmarks/`** (terminal-io, session-open, active-stream-reconnect, ...) measure that
  harness's internals, not a coding agent's usefulness.

## Streaming profile

The harness's only real hot loop is the SSE reader: every token delta is parsed and printed. It was
profiled against a local OpenAI-compatible endpoint emitting a fixed 5000-frame stream
(`/tmp/sse_bench.py`, loopback, no model, identical work every run), so nothing but the reader is
being measured.

Host: AMD Ryzen 9 9950X, Zig 0.16.0, `perf stat`, `strace -c`, 5000 frames, median of one run each
(the counters were stable to <1% across repeats):

| metric | before | after | delta |
| --- | --- | --- | --- |
| `write` syscalls | 5002 | 58 | 86x fewer |
| total syscalls | 5048 | 96 | 53x fewer |
| CPU user+sys | 0.021 s | 0.006 s | 3.5x faster |
| cycles | 31.5 M | 21.2 M | -33% |
| branch misses | 22 557 | 10 567 | -53% |
| instructions | 42.90 M | 42.60 M | -0.7% |
| peak RSS, 40 000 frames | 155.7 MB | 26.0 MB | 6x less |

Two changes, both in `streamChat`:

1. **Output is buffered per read chunk instead of written per token.** One `write(2)` per delta
   became one per chunk the provider actually sent. Tokens that arrived in the same chunk were
   always drawn in the same tick, so streaming latency is unchanged — the syscall count was pure
   overhead.
2. **Frames are parsed in a scratch arena reset after each frame.** Before, every frame's
   `std.json.Value` tree lived until process exit, so a long completion grew the heap without
   bound: 40 000 frames cost 155 MB. Text that must survive the reset is copied into the run arena;
   the rest is reclaimed.

What the profile refused to change: instructions barely moved, because the remaining 8.5k
instructions per frame are the dynamic JSON parse itself (~4 us of CPU per frame). Against a model
that takes seconds to produce those frames, hand-rolling a scanner for `delta.content` would be
complexity bought with no user-visible millisecond — so it stays.

Deterministic regression test (`zig build test`): `a long stream costs the largest frame, not the
sum of frames` folds 20 000 frames through `applyFrame` with the per-frame reset and asserts the
scratch arena's `queryCapacity()` is *exactly* what one frame needed. It asserts a byte counter, not
wall clock, so a loaded CI box cannot move it. `tool call fragments merge by index across frames`
and `usage counters land on the result` pin the frame-parsing behaviour the refactor touched.

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
