# Harness benchmark

What is measured here is the harness, not the model: how long the binary takes to exist, how many
tokens it spends before the model says anything, and whether the loop it drives can actually finish
a task. Model latency dominates wall time in any loop, so the harness numbers are the ones worth
comparing.

Machine: x86_64 Linux, Zig 0.16.0, `bench/overhead.sh` and `bench/run.sh` as committed. Every number
below was produced by those scripts, not by hand. The scripts run on macOS too: the wall clock
falls back to whole seconds there, because BSD `date` has no `%N`, and the run ceiling is a watchdog
where `timeout` is not installed.

## Size

| build | binary |
| --- | --- |
| `-Doptimize=ReleaseSmall` (stripped) | 0.84 MB |
| `-Doptimize=ReleaseFast` (stripped) | 1.54 MB |
| `-Doptimize=ReleaseSafe` (stripped) | 1.49 MB |
| `Debug` (unstripped) | 33.75 MB |

No runtime, no package manager, no node_modules, no python. Eight files under `src/`
(`main.zig` the agent loop and its wiring, `tool.zig` the tools and the process runner, `chat.zig`
the value types a turn is made of, `session.zig` the per-run log, `style.zig` the reply styles,
`update.zig` the self-update, `net.zig` the sinks, deadlines and CA bundle the rest share, and
`fuzzargv.zig` the argv both command-line fuzzers feed a parser),
14 458 lines.
The sizes in this table are `ls -l` on a fresh build of this tree; every other number below comes
from the two bench scripts.

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

microagent's own row needs the same caveat more than the others, because at half
a millisecond it is the one measurement here that the harness around it can
outweigh. The same `--version` on the same binary measured 442 us and 1.7 ms in
one session, on a machine that was not doing anything different between them.
The table above is a comparison and stays as one; microagent's own startup is
better read from a counter that does not move:

| | |
| --- | --- |
| retired instructions | **477,511** |
| CPU time (`perf stat -e task-clock`) | **0.58 - 0.61 ms** |

Both repeat to within 0.001% across runs and are unaffected by what else the
machine is doing, which is why the gate measures work rather than time.

Turns after the first reuse the TLS session rather than paying a handshake:
`keep_alive` defaults to true in `std.http.Client`, so every turn's request
participates in the client's connection pool, and the request's `deinit` drains
an unread response tail before handing the connection back. This is worth
stating because a fresh handshake per turn would be tens of milliseconds of CPU
and two or three round trips, which is a larger per-turn cost than everything
else in this file added together.

A gauntlet loop starts an agent once per review, so this is per-review overhead. On a 60 s review,
2 ms is 0.003% of the loop; on the node-based harnesses it is still under 0.1%. The number
matters for the tight loops people actually run (`--retries`, short timeouts, hundreds of reviews),
not for one review.

## Un-cacheable request bytes

Prompt caching keys on the exact byte prefix of a request, so a turn's body has
to be the previous turn's body plus the new messages. That only holds while
nothing constant sits *behind* the growing array.

The tool schemas used to be written after `messages`. They are 3,590 bytes for
the seven tools this binary advertises, and behind the conversation they fell
outside the cacheable prefix on every turn of every run, so the provider
re-read them each time:

| | un-cacheable tail per turn |
| --- | --- |
| tool schemas written after `messages` | 3,592 bytes (~900 tokens) |
| written before, as now | **2 bytes** |

Three and a half kilobytes per turn, for the whole conversation. Over a
100-turn review that is 0.36 MB of prefill the provider was being asked to do
again for no reason, and it was invisible to every counter in this file, because
`cached_tokens` counts what was reused and never says what was not.

JSON member order is not significant, so the constant fields go first and
`messages` ends the body. Two tests hold it there: consecutive bodies must share
a prefix of header-plus-all-messages-so-far, and the schema must appear before
the conversation.

## Harness prompt overhead

The first request of a run, in bytes, which is what the request is made of.
Every row is derived from the tree (the prompt and schema constants, and the
style block the defaults produce), so it can be re-derived without paying for a
run:

| | bytes |
| --- | --- |
| system prompt | 1,685 |
| reply style (caveman ultra, ponytail full) | 1,616 |
| the seven tool schemas | 3,590 |
| the rest of the body: model, stream flags, `max_tokens`, JSON scaffolding | 133 |
| **everything a request carries besides the conversation** | **7,024** |

That 7,024 is the entire fixed cost of a request, and the schemas are just over
half of it: the price of seven tools plus a system prompt and a style block,
which is the price of the harness being a harness. A `--reasoning-effort` adds
the `reasoning` member to the last row, nothing here. It is re-sent every turn
and cached from the second turn on, so it is a prefix cost rather than a
per-turn one -- see
[Un-cacheable request bytes](#un-cacheable-request-bytes) for the part that is
not.

An earlier figure here was 933 tokens for six of the seven tools, measured from
a run's usage line. It was honest when written and is now two tools out of date;
the bytes above replace it because they can be re-derived from the tree rather
than from a run that has to be paid for. Competitor CLIs in one-shot mode did
not report a comparable number on this machine, so none is claimed for them.

## Conversation growth and the prompt cache

Every turn re-sends the whole conversation, so what the provider can reuse is
however many leading bytes this turn shares with the last one. Measured by
`zig build test -Dtest-filter="a long run keeps the conversation bounded"` over
a 120-turn run whose turns each read two 8 KB files, the shape of a real review:

| | bytes per turn |
| --- | --- |
| conversation sent | 293,766 |
| of which the provider could reuse | 251,400 (86%) |

Eight of those 120 turns compacted the conversation. On those the reusable
prefix is next to nothing: elision rewrites the message array and runs oldest
first, so the first changed byte is early and everything after it is re-read.
That is the price of keeping the evidence the model is acting on, and it is the
right trade, but it is a real cost: one turn in fifteen pays a full re-prefill.

The prefix does grow, because the walk skips messages it has already elided
and picks up where the last compaction stopped, about 3 KB per compaction. It
grows from 1,704 bytes at the first to 22,956 at the eighth, which is 5% of a
418 KB prompt, so over a run this size it never recovers. The cost is close to
a full re-prefill on every one of those turns and the schedule is steady at one
every thirteen turns.

`conversation_soft_limit` is the knob, and it trades the two directly. Raising
it means a larger prompt on every turn and fewer full re-prefills; lowering it
is the reverse. The table above is the argument for looking at it before a run
dies on a provider timeout, not a reason to change it blind: only a live
provider can say which side wins.

One consequence is worth knowing before moving it, because it is arithmetic and
not a measurement: **the uncached bytes a run spends do not depend on the
limit.** Compaction fires every time the conversation grows by half of the
limit, and each time it throws away a prompt of about the limit, so the product
is the growth of the conversation, whatever the limit is. Raising the limit
therefore buys back no uncached prefill at all; it only buys a larger cached
prompt every turn. Eight compactions over roughly two megabytes of growth is
about 1.6 times that growth, which is the same figure the formula gives.

So the limit is not a latency knob. It sets how much evidence the model keeps
per token spent, and every token past it is one the limit bought on purpose.

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

- **DSH's own `benchmarks/`** (terminal-io, session-open, active-stream-reconnect, ...) measure that
  harness's internals, not a coding agent's usefulness.
- **SWE-bench Pro** — only the Verified stride sample above was run here.
- **A full SWE-bench Verified set** — the 13 instances below are a sample; see "What a full run would
  take".

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

## What actually moved the SWE-bench number

The first 13-instance run was not only a model result; the harness was clipping it. Two instances
stopped at exactly 60 turns, which was the `--max-turns` default, and one stopped at 54 with the
1200 s budget gone. Re-running those three with the ceiling raised to 150 turns and the budget to
2700 s (still inside the task's own 3000 s agent timeout):

| instance | before | after | turns used |
| --- | --- | --- | --- |
| matplotlib__matplotlib-25775 | 0.0 | **1.0** | 99 |
| pylint-dev__pylint-4551 | 0.0 | 0.0 | 97 |
| sympy__sympy-21379 | 0.0 | 0.0 | 75 |

The ceiling is now 100 by default, the harbor adapter passes `MICROAGENT_MAX_TURNS` (150), and the
system prompt was rewritten to work in the order a bug fix actually needs: find the code and its
tests, reproduce the failure, make the smallest change, re-run the test, check `git diff`. New
deterministic tools behind that prompt: `search` (ripgrep), `ast` (ast-grep), `git` (status, diff,
log, show, blame - fixed subcommands, capped output) and `read`/`edit`/`write`. `patchwork` on this
machine is graphviz's binary, not the AST rewriter, and `semcode` is a dangling symlink into a
never-built cargo target, so neither is wired up.

## Terminal-Bench 2, 23-task sample

Five hand-picked tasks cannot separate two harnesses, so the comparison moved to a stride sample of
the real benchmark: every fourth task of Terminal-Bench 2's 89, sorted by name, chosen before the
run. Same model (`openrouter/deepseek/deepseek-v4-flash`, one OpenRouter key), same task
containers, same per-task timeouts, harbor 0.23.0, one run each.

| | microagent | opencode 1.18.31 |
| --- | --- | --- |
| solved | **11/23 = 0.478** | 7/23 = 0.304 |
| exceptions | **0** | 12 |
| wall | 55m31s | 1h17m46s |
| input tokens | 16.5 M | 8.7 M |
| output tokens | 377 k | 87 k |

Where the two disagree, both directions exist: microagent solves `largest-eigenval`,
`password-recovery`, `regex-log`, `git-leak-recovery`, `sanitize-git-repo` and `sqlite-with-gcov`
that opencode does not, and opencode solves `pypi-server`, `feal-differential-cryptanalysis` and
`build-pmars` that microagent does not. The categorical difference is the exception column:
opencode's twelve are nine `AgentSetupTimeoutError` (its own install step timing out inside those
containers), two `AgentTimeoutError` and one non-zero exit; microagent finished every trial, because
its budget ends the loop deliberately instead of being killed by the caller.

Statistics, honestly: 11/23 against 7/23 with a standard error near 0.10 each is a difference of
about 1.7 standard errors — suggestive, not proof. The exception count is not a matter of noise.

The token columns say more about cost than the solve rate does. microagent wins
on tasks solved and spends about 1.9x the input tokens and 4.3x the output to
do it, which is 1.2x and 2.8x per task solved. Neither is waste on its face --
a harness that keeps more evidence in front of the model spends more -- but it
is worth knowing what those bytes are.

16.5 M input tokens is about 66 MB of prompt. Spread over the turns those tasks
took, that is 72-143 KB per request (the range is the turn count, which the
benchmark does not keep), against a `conversation_soft_limit` of 400 KB. So on
a benchmark of this shape the limit does not fire: the conversation never gets
near it, and the fixed 7,024 bytes a request carries is under 6% of one. The
prompt is evidence the agent accumulated, not the fixed harness cost and not
compaction.

That settles the limit's practical reach, which was the open question in this
file: it is inert at benchmark scale and only binds on long runs. Tuning it
would have changed nothing here.

## Matched comparison: microagent vs opencode

Same 13 SWE-bench Verified instances, same model (`openrouter/deepseek/deepseek-v4-flash`, one
OpenRouter key), same task container, harbor 0.23.0, `-n 4`. microagent is the current build (git
tool, bug-fix workflow prompt, 150-turn ceiling, 2700 s budget); opencode 1.18.31 runs its own
defaults (its task timeout is the benchmark's 3000 s). Two runs each, because one run is not a
measurement here.

| run | microagent | opencode |
| --- | --- | --- |
| SWE-bench Verified, run 1 | 8/13 = 0.615 | 6/13 = 0.462 |
| SWE-bench Verified, run 2 | 7/13 = 0.538 | 7/13 = 0.538 |
| **pooled** | **15/26 = 0.577** | **13/26 = 0.500** |
| wall, 13 instances | 16m25s / 18m29s | 24m34s / 30m09s |
| input tokens, 13 instances | ~4.5 M | ~8.2 M |
| exceptions | 0 | 0 |

Terminal-Bench 2, the same five tasks, each harness at the benchmark's own timeout:

| run | microagent | opencode |
| --- | --- | --- |
| run 1 | 3/5 = 0.600 | 3/5 = 0.600 |
| run 2 | 3/5 = 0.600 | 4/5 = 0.800 |

Microagent's run-2 losses were `overfull-hbox` (genuine 0.0) and `adaptive-rejection-sampler`, which
the adapter killed at its 880 s process timeout: the agent's own `--budget` is checked between turns,
so one long tool call can overrun it. That is a harness defect, not a model one, and it is the next
thing to fix.

Read honestly: pooled over 26 paired trials microagent is ahead by two trials, and on Terminal-Bench
the two runs split. Nothing here is a decisive win; 13 instances cannot decide a two-task gap, and
opencode's own two SWE runs differ by 0.23 (0.462 to 0.692) — larger than the gap between harnesses.

### kimi

Not measured. Harbor's `kimi-cli` agent refuses to run ("kimi-cli is no longer maintained. Please use
the new Kimi Code CLI"), and `kimi-code` reaches the provider but every credential in `~/.secrets`
returns `401 The API Key appears to be invalid or may have expired` against
`https://api.kimi.com/coding/v1`. A zero recorded from a failed setup would be a lie, so there is no
kimi column rather than a zero column.

## Terminal-Bench 2, second pass, and what it says about method

A repeat of the same 23-task sample, run for both harnesses **in parallel**, came back much worse
for both: microagent 5/23 with 9 exceptions (all `RuntimeError`), opencode 4/23 with 19 (5 setup
timeouts, 14 `RuntimeError`). Two things were wrong with that run, and neither was the agent:

- It ran two 23-task jobs at once on one machine, so every trial competed for the same four cores
  and the same rate limit.
- The adapter in that process was the one loaded at start-up, before the fix that scores an
  incomplete (exit 3) run's tree instead of raising. Every unfinished microagent trial was therefore
  recorded as an exception and thrown away, including trials whose fix was on disk.

| pass | conditions | microagent | opencode |
| --- | --- | --- | --- |
| 1 | sequential, one harness at a time | **11/23**, 0 exceptions | 7/23, 12 exceptions |
| 2 | both in parallel, pre-fix adapter | 5/23, 9 exceptions | 4/23, 19 exceptions |

Pooled across both passes microagent is 16/46 against opencode 11/46, but the honest reading is
that only pass 1 is a valid comparison: pass 2 measured machine load and an adapter bug. A third
pass runs sequentially with the fixed adapter; its result replaces this row when it lands, rather
than being averaged into a contaminated one.

## Where the 13-instance SWE-bench sample stands

Every run of the same 13 instances, same model, same containers. This is the whole record, because
picking the best row would be picking noise:

| run | config | solved | exceptions |
| --- | --- | --- | --- |
| first | baseline harness | 5/13 | 0 |
| `compacted` | conversation compaction | 7/13 | 0 |
| `microagent-full` | git tool, workflow prompt, 150 turns, 2700 s | 8/13 | 0 |
| `microagent-full-2` | same | 7/13 | 0 |
| `microagent-r3` | same | 6/13 | 0 |
| `microagent-r5` | same | 5/13 | 0 |
| `microagent-r8` | verification gate, reasoning off | 6/13 | 0 |
| `microagent-r9` | stronger completion rule, reasoning on | 7/13 | 2 |
| **pooled** | | **46/91 = 0.505** | |

opencode's three runs on the same instances: 6/13, 7/13, 9/13 (the 9 at a 1200 s timeout) —
22/39 = 0.564 pooled. The two harnesses are inside each other's noise on this sample, and 13
instances cannot resolve a difference below about 0.25 without hundreds of runs. Terminal-Bench 2,
with 23 tasks and a categorical difference in finished trials, is where a claim can be made.

## A regression the benchmarks caught immediately

Two SWE-bench runs this round came back 13/13 `RuntimeError: microagent exited 3`. Exit 3 is
"stopped at a ceiling with the answer unfinished", and it was correct: a refactor of the agent loop
had made a turn that asked for tools end the run instead of looping, so every run stopped after its
first tool call. Reproduced in the task container and locally in one command
(`microagent --budget 300 --max-turns 12 "list the files, then say done"`), fixed by continuing the
loop on `.wants_tools`, and verified: the same command now exits 0 after two turns.

The point for this document: a benchmark that only reports a mean hides this. thirteen identical
exceptions in 87 seconds is what a broken loop looks like, and it would have been read as "the model
scored 0.000" if the exception column were not printed.

## Verification gate

The measured failure mode behind it: a SWE-bench instance that ended after 20 turns with **zero**
test commands, while every instance that passed ran five to fifteen. The loop now tracks, per tool
call, whether the run has edited the tree and whether it has run a test runner; if it edited without
ever verifying, it is asked once to run the tests before the run is allowed to finish.

Honest accounting: across the 13-instance run that followed, the gate fired on one instance
(`sympy__sympy-13877`) and that instance still failed. It is kept as a safety net for a failure mode
that is real and cheap to catch, not as a measured improvement.

## Harness faults found by running the benchmarks

Two of these cost whole tasks before they were fixed, and neither was visible without a real
benchmark run:

| fault | symptom | fix |
| --- | --- | --- |
| The API key was passed as a *privileged header* | every provider answered `401 No cookie auth credentials found`; the key was never on the wire | send it as the request's `authorization` header (`Headers.authorization = .override`), with a regression test |
| A tool's timeout ignored the budget | a two-minute `bash` call started at second 779 of a 780 s budget; the caller killed the task mid-command (Terminal-Bench 2 `adaptive-rejection-sampler`) | clamp every tool timeout to the time left, floor 5 s |
| The budget did not fit the caller's timeout | microagent's final push may run 300 s past its budget, so a 780 s budget inside a 900 s task timeout was still killed | the adapter derives the budget from the timeout it is given, leaving the grace plus margin |

Terminal-Bench 2, same five tasks, after the fixes: **5/5 trials completed, 0 exceptions, 3/5 solved,
10m55s**. Before them the same set lost a task to `RuntimeError: Command timed out after 880 seconds`
and another to the agent timeout.

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
larger prompt; microagent ships seven tools and a prompt in the same hundreds-of-tokens range. That
trade is the whole point of the harness and it is visible in the token columns.

## Prompt cache reuse

Every turn re-sends the whole conversation, which is the shape a prefix cache wants: the prefix is
byte-identical from one turn to the next, and a turn adds only its own messages. Nothing has to be
opted into — OpenAI, DeepSeek and Gemini cache automatically above their block size, and microagent
does not put anything volatile (a timestamp, a shuffled tool list) ahead of the conversation. What
was missing was the counter: the usage lines reported `prompt_tokens` but not how much of it came
from cache, so reuse could only be assumed.

`applyFrame` now reads the cached-prompt counter in the three spellings endpoints send —
`prompt_tokens_details.cached_tokens`, DeepSeek's `prompt_cache_hit_tokens`, Anthropic's
`cache_read_input_tokens` — and it rides in the stdout usage line and in every session-log record.

Measured on `deepseek/deepseek-v4-flash` through OpenRouter, one run of seven turns, one `bash` call
per turn. The usage line is cumulative, so both columns are run totals and the share is cumulative:

| turn | prompt tokens | cached | cached share |
| --- | --- | --- | --- |
| 1 | 1,290 | 1,024 | 79% |
| 2 | 2,638 | 2,048 | 78% |
| 3 | 4,043 | 3,072 | 76% |
| 4 | 5,506 | 4,352 | 79% |
| 5 | 7,027 | 5,632 | 80% |
| 6 | 8,606 | 6,656 | 77% |
| 7 | 10,243 | 7,936 | 78% |

The cached count climbs by roughly one turn's worth of tokens every turn: the prefix is being
reused, not re-read. Turn 1's 1,024 cached tokens are the system prompt and the tool schema, which
are byte-identical in every run, so even a cold run starts with most of its fixed overhead already
cached at the provider.

Conversation compaction is the one thing that rewrites the conversation, and it is written so it
cannot cost more cache than it has to: it replaces the *content* of old large tool results, never
drops a message, never reorders one, and leaves everything ahead of the first elided result byte for
byte — the same bytes are the same cached blocks. It also only fires above 400 KB, so short runs
never pay for it at all. `zig build test` pins the property with `compaction leaves the cached
prefix byte-identical`: the test builds a conversation whose prefix contains a quote, a backslash, a
newline, a control byte and a non-ASCII byte, compacts it, and asserts the prefix bytes survive
unchanged (a round trip that re-spelled one escape would turn every later turn into a full
re-read). The cached-counter spellings are pinned by `cached prompt tokens read every provider
spelling`.

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
sh bench/gauntlet.sh microagent kimi
```

`make bench`, `make overhead` and `make gauntlet` wrap those three, each
building the binary and putting it on PATH first.

Raw rows land in `bench/results.jsonl`.
