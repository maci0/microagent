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
nothing about whether the harness is *useful* on real work. `bench/gauntlet.sh` is the measure that
does: the same gauntlet review, on the same repository clone, once per agent, scored on four things
— the review's own verdict, whether a diff landed, whether the patched tree still passes
`zig build test`, and how long it took.

Scenario: one review at a time against a clone of this repository, 12 minutes per review, gauntlet
1.25.0. Model names are the router ids microagent was given; kimi runs its own default.

| agent | model | budget | review | gauntlet | files | verify | wall |
| --- | --- | --- | --- | --- | --- | --- | --- |
| microagent | deepseek/deepseek-v4-flash | – | error-review | fail (timeout) | 0 | – | 720 s |
| microagent | deepseek/deepseek-v4-flash | – | error-review, `--reasoning-effort low` | fail (timeout) | 0 | – | 720 s |
| microagent | stealth/space-bunny-alpha | – | error-review | fail (timeout) | 0 | – | 721 s |
| **microagent** | stealth/space-bunny-alpha | – | error-review | **pass** | 1 | ok | 284 s |
| **microagent** | stealth/space-bunny-alpha | – | error-review | **pass** | 1 | ok | 334 s / 335 s |
| **microagent** | stealth/space-bunny-alpha | – | cli-review | **pass** | 1 | ok | 372 s |
| microagent | deepseek/deepseek-v4-flash | 480 s | error-review | pass | **0** | – | 594 s |
| kimi 2.1.1 | CLI default | – | error-review | pass | 1 | not run | 185 s |
| kimi 2.1.1 | CLI default | – | cli-review | pass | 2 | ok | 144 s |

Rows in bold are the same configuration; the three timeout rows are the same configuration *before*
the prompt was hardened. Read the table with these three things in mind:

- **gauntlet's "Passed" does not mean a diff landed.** deepseek's budgeted run was scored as passed
  with an untouched tree: the budget cut the loop, the model answered with prose, gauntlet saw a
  completed review. This is why the benchmark counts files with `git diff --numstat` and runs the
  project's own check. A usefulness benchmark without those columns flatters every agent equally.
- **The diffs are real work.** microagent's cli-review run grew specific per-flag error messages in
  `src/main.zig` (+53/-13); kimi's added the same kind of thing across `src/main.zig` and
  `README.md` (+54/-21). Both patched trees build and pass 9/9 tests. microagent reviewed its own
  code and left it better.
- **Model choice dominates.** The identical harness, running the identical review, timed out three
  times on two deepseek configurations and passed on bunny-alpha.

Three defects and one behaviour problem came out of this, in order of how much they mattered:

1. **A model-qualified agent spec never ran at all.** gauntlet's custom-agent definitions insert the
   model flags immediately after `-p`, so `["microagent", "-p", "{prompt}"]` produced
   `microagent -p --model stealth/... <prompt>` — microagent took `--model` as the prompt and exited
   2. Fixed by accepting the prompt as a bare argument; the definition is now
   `["microagent", "{prompt}"]` and flagged runs work in any order.
2. **The agent wandered instead of editing.** On the pre-hardening prompt, the bunny run spent its
   twelve minutes grepping `/home/maci/.zvm/0.16.0/lib/std` — dozens of calls inside the Zig
   standard library to answer a question about this repository — and changed nothing. The system
   prompt now says to budget its steps, not to audit unrelated code, and not to read library or
   standard-library sources. The next runs made ~50 tool calls, never opened `lib/std`, and landed
   diffs.
3. **Nothing forced convergence inside the caller's timeout.** Added `--budget <seconds>`
   (`MICROAGENT_BUDGET_SECONDS`), which stops starting turns at the budget and spends one final turn
   telling the model to make the edit it already knows about, plus a last-turn notice at the
   `--max-turns` boundary.
4. **`--reasoning-effort low` did not help.** deepseek-v4-flash still burned its full budget without
   editing. The flag stays because it passes through cleanly, but it is not claimed as a fix, and the
   budgeted deepseek row shows the honest outcome: a clean stop, not a fix.

Caveat on attribution: the passing runs differ from the timeout runs in both the system prompt and
the budget knob, and in the passing runs the budget never fired (`--max-turns` did, at 60 turns).
Single runs against a stealth model behind a router that may re-route. The direction is not in
doubt — three timeouts with zero files changed, then three passes with diffs — but this is evidence,
not a controlled experiment.

### Not measured

- **SWE-bench Verified / SWE-bench Pro** — driven by Strands SSA in the local `benchmark-harnesses`
  checkout, and SSA *is* the agent (a Python loop with its own tool calling). A CLI harness cannot be
  substituted for it; these datasets would need a microagent-specific runner.
- **Terminal-Bench 2** — harbor takes an agent as `--agent-import-path`, i.e. a Python adapter class,
  so microagent is pluggable in principle with one adapter that shells out to `microagent {prompt}`
  inside the task container. Not built here: it needs the `terminal-bench@2.0` dataset, per-task
  docker images (`TB2_ECR_MAP`) and a large image pull that is not cached locally.
- **DSH's own `benchmarks/`** (terminal-io, session-open, active-stream-reconnect, ...) measure that
  harness's internals, not a coding agent's usefulness.

## Terminal-Bench 2

The external benchmark for a coding harness: 89 containerized tasks with their own verifiers,
driven through Harbor. microagent runs inside the task container as a static musl binary
(`make musl`), so its own shell and file tools operate on the task's real files. Adapter and
instructions: [integrations/harbor/README.md](integrations/harbor/README.md).

Model `deepseek/deepseek-v4-flash` (OpenRouter), reasoning off, 600 s agent budget, `-n 2`.

| task | reward | wall |
| --- | --- | --- |
| log-summary-date-ranges | 1.0 | 47 s |
| fix-git | 1.0 | — |
| cobol-modernization | 1.0 | — |
| overfull-hbox | 0.0 | 600 s budget |
| adaptive-rejection-sampler | 0.0 | 600 s budget |
| **batch mean** | **0.600** (3/5) | 5m10s |

Both zeros first failed with `TlsInitializationFailed` — bare `ubuntu:24.04` images ship no CA
store. That is a harness defect, not a model defect, and it is what produced `--ca-bundle`: with the
host bundle written into the container (resolved through its symlink, which `docker cp` would
otherwise copy as a dangling link) both tasks run to completion. They still score 0.0 — the model
does not solve them inside the budget — which is the honest result and is left as one.

## SWE-bench Verified

The canonical measure for a coding agent. Harbor's `swebench-verified@1.0` registry dataset (500
instances), same adapter and binary as above, `deepseek/deepseek-v4-flash`, reasoning off, 1200 s
budget, `-n 4`. Instances are a deterministic stride sample — every 40th of the 500, sorted by name
— chosen before the run, not after it.

| instance | resolved | in/out tokens | wall |
| --- | --- | --- | --- |
| astropy__astropy-12907 | 1.0 | 341k / 5.8k | 465 s |
| django__django-11211 | 0.0 | 615k / 7.9k | 167 s |
| django__django-12308 | 0.0 | 157k / 3.2k | 176 s |
| django__django-13568 | 0.0 | 280k / 4.4k | 159 s |
| django__django-14559 | 1.0 | 123k / 3.0k | 106 s |
| django__django-15572 | 0.0 | 41k / 1.5k | 98 s |
| django__django-16667 | 0.0 | 82k / 2.4k | 90 s |
| matplotlib__matplotlib-25775 | 0.0 | 1784k / 10.6k | 296 s |
| pylint-dev__pylint-4551 | 0.0 | 925k / 9.2k | 246 s |
| scikit-learn__scikit-learn-13328 | 1.0 | 121k / 2.1k | 85 s |
| sphinx-doc__sphinx-8120 | 1.0 | 234k / 3.3k | 104 s |
| sympy__sympy-13877 | 1.0 | 610k / 17.7k | 228 s |
| sympy__sympy-21379 | 0.0 | 789k / 13.4k | 229 s |
| **stride sample of 13** | **0.385** | 6.10M / 84k total | 11m45s |

Zero exceptions. A separate first sample of four instances scored 0.750 (pytest-5809,
sphinx-8593, xarray-3095 resolved; sympy-13852 not); four instances is noise, which is exactly
what the larger sample shows.

### Same thirteen, after conversation compaction

The same 13 instances, same model and budget, with `compactMessages` in the binary:

| | before | after |
| --- | --- | --- |
| resolved | 5/13 (0.385) | 7/13 (0.538) |
| input tokens | 6.10 M | 5.44 M (-11%) |
| output tokens | 84 k | 80 k |
| wall | 11m45s | 13m15s |

Read this as noise, not as a win. Individual instances moved both ways — `sympy-13877` fell from
610k to 122k input tokens while `django-12308` rose from 157k to 343k — and instances flipped
between resolved and not in both directions, because the model is sampled and the loop length is
not fixed. Thirteen instances carry roughly +/-13% standard error at this rate, so 5/13 and 7/13
are the same result. The change is kept because it bounds how large a single conversation can grow
and because the bound is unit-tested, not because the table proves a saving.

### What a full run would take

500 instances at this rate is roughly 8 hours of wall time and a few hundred GB of image pulls;
the 13 above are the honest sample this machine was given, not a substitute for the full set.

Two things the run says beyond the score:

- **The input token column is the harness's own doing.** Every turn re-sends the whole
  conversation, so the 1.78M-token instance is not a hard task, it is the same files being paid for
  over and over. `compactMessages` now elides the content of the oldest large tool results once the
  conversation passes 400 KB, keeping assistant messages, the task instruction and every
  `tool_call_id` intact. The column above is the before side of that change.
- **Repos beat prompts.** The failures are spread across django/matplotlib/pylint, not concentrated
  in one review-shaped weakness, which is what a small harness should expect: microagent has no
  repo-specific tooling and no language server, so SWE-bench scores come from the model plus search
  and edit.

The numbers a reader should compare against are published full-set (500-instance) results, not this
sample; 13 instances carry roughly +/-13% standard error at this rate.

## Head to head with opencode

The same machine, the same 13 SWE-bench instances, the same model
(`openrouter/deepseek/deepseek-v4-flash`, one OpenRouter key), the same 1200 s per-task timeout,
harbor 0.23.0, `-n 4`. opencode runs through harbor's built-in adapter (installs node and the CLI
into each task container); microagent runs through
[integrations/harbor/microagent_agent.py](integrations/harbor/microagent_agent.py).

| | microagent | opencode 1.18.31 |
| --- | --- | --- |
| SWE-bench Verified, 13 instances | 7/13 = **0.538** | 9/13 = **0.692** |
| Terminal-Bench 2, same 5 tasks | 3/5 = **0.600** | 3/5 = **0.600** |
| input tokens, SWE run | 4.46 M | 8.19 M |
| output tokens, SWE run | 224.7 k | 54.7 k |
| wall, SWE run | 18m07s | 30m25s |
| wall, TB2 run | 5m10s | 23m26s |
| exceptions | 0 | 1 (`AgentTimeoutError` on TB2) |

What this does and does not say:

- **The SWE-bench gap is two tasks and is not established.** Thirteen instances carry roughly +/-13%
  standard error at this rate, so 0.538 against 0.692 is directional, not a result. The same 13
  instances are also the only sample that exists here; a 50-instance run would be needed before
  anyone should quote these numbers.
- **microagent is the smaller engine, measurably.** About half the input tokens, 1.7x less wall time
  on SWE-bench and 4.5x less on TB2 — most of the TB2 difference is opencode installing a node
  runtime inside every task container before it can start. It also produced four times the output
  tokens, because reasoning was on for that run; the reasoning-off run used 84 k output for the same
  13 instances.
- **Terminal-Bench 2 is level at 3/5**, and opencode's run lost one task to an agent timeout that
  microagent's own `--budget` prevents by stopping deliberately.

Neither harness was tuned for the other's benchmark. opencode ships repo-aware tooling and a much
larger prompt; microagent ships six tools and a 933-token prompt. That trade is the whole point of
the harness and it is visible in the token columns.

## Streaming profile## Streaming profile

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
