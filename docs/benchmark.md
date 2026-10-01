# Harness benchmark

This file measures the harness, not the model: how long the binary takes to start, how many bytes it
spends before the model says anything, and whether the loop it drives finishes a task. Model latency
dominates wall time in any loop, so the harness numbers are the ones worth comparing.

Machine: x86_64 Linux, Zig 0.16.0 (the streaming profile names its CPU, an AMD Ryzen 9 9950X). Each
section names the script, test or tool its numbers came from; none was produced by hand. The startup
and task numbers come from `bench/overhead.sh` and `bench/run.sh` as committed. Those scripts also run
on macOS: elapsed time is read from `perl`'s `Time::HiRes` `CLOCK_MONOTONIC` wherever perl is
installed, on both platforms, and only a Linux host without perl falls back to `/proc/uptime`. The two
are not the same quantity — `/proc/uptime` counts time spent in suspend and `CLOCK_MONOTONIC` does
not — so a number read from the fallback on a laptop that suspended mid-run includes the suspend,
and it is not comparable with one read from `CLOCK_MONOTONIC`. A host with neither source reports
no-clock rather than a wall-clock figure, and the run
ceiling, process-group cleanup and JSON result records require Python 3. Cleanup uses the same
standard-library runner on both
platforms. An interrupted command receives the signal and has up to five seconds to flush its logs
before group cleanup. Overhead rows whose prompt failed report the exit status instead of a timing.
Task and gauntlet runs keep their logs in separate directories, printed on stderr at startup.

## Contents

- [Harness costs](#harness-costs)
  - [Memory footprint](#memory-footprint)
  - [Binary size and source](#binary-size-and-source)
  - [Startup](#startup)
  - [Un-cacheable request bytes](#un-cacheable-request-bytes)
  - [Harness prompt overhead](#harness-prompt-overhead)
  - [Prompt cache](#prompt-cache)
  - [Streaming profile](#streaming-profile)
  - [Fault injection](#fault-injection)
- [Task results](#task-results)
  - [One trivial request](#one-trivial-request)
  - [Task benchmark](#task-benchmark)
  - [gauntlet loop](#gauntlet-loop)
  - [Usefulness](#usefulness)
  - [Terminal-Bench 4.0](#terminal-bench-40)
  - [Aider polyglot](#aider-polyglot)
  - [DeepSWE](#deepswe)
  - [Terminal-Bench 2](#terminal-bench-2)
  - [SWE-bench Verified](#swe-bench-verified)
  - [Head to head with opencode](#head-to-head-with-opencode)
- [Harness faults the benchmarks found](#harness-faults-the-benchmarks-found)
- [Method notes](#method-notes)
- [Not measured / open](#not-measured--open)
- [Reproducing](#reproducing)

## Harness costs

### Memory footprint

The number that matters for an agent that runs unattended is how much memory it holds while it
runs, because that is what every copy left running costs, and it is the one figure that neither a
startup time nor a binary size carries. It is measured with [bench/maxrss.py](../bench/maxrss.py),
which starts the command under ptrace and reads the process's `VmHWM` at the last moment it exists
(`PTRACE_O_TRACEEXIT`), so a command that lives a few hundred microseconds is not missed. Median of
five runs, x86_64 Linux, one session on 2026-09-29. The machine was busy with a benchmark job, which
moves timings and barely moves resident memory: the five runs behind each `--version` row below differ by under 12%.

`--version`, peak resident memory:

| harness | peak resident |
| --- | --- |
| **microagent, measured 2026-09-29 (ReleaseSmall)** | **0.6 MB** |
| grok 1.0.41 | 24.7 MB |
| codex-cli 0.158.0 | 27.7 MB |
| claude 2.1.284 | 36.7 MB |
| crush v0.96.1 | 57.6 MB |
| opencode 1.18.31 | 198 MB |
| kimi 2.1.1 | 326 MB |

That is 38 times less than the smallest of the others and 500 times less than the largest, at
start. `--version` is all that was measured for them: a real run adds each harness's own working
set, and only microagent's is measured below.

microagent's own footprint, by build mode and by what the run does, in kB. A stub provider on
loopback answers the frames runs (`bench/stub_provider.py`); the second column is a run whose
connection is refused, which is everything up to the first request:

| build | `--version` | refused | 1 frame | 5,000 frames | 50,000 frames |
| --- | --- | --- | --- | --- | --- |
| **ReleaseSmall** | **540** | **764** | **768** | **868** | **1,300** |
| ReleaseFast | 788 | 1,244 | 1,300 | 1,320 | 1,812 |
| ReleaseSafe | 1,120 | 2,156 | 1,884 | 1,884 | 3,164 |

`ReleaseSmall` is smallest in every column, 28% to 41% below `ReleaseFast`, and under half of
`ReleaseSafe`'s. It is the build the release assets, `make` and `make musl` produce, so the numbers
here are the numbers of what ships. The price is some CPU, not memory: `--version` retires 43,156
instructions against 33,030 for `ReleaseFast`, and a 5,000-frame stream 37.8 million against 27.0
million, about 1.3 times. The shipped build carries its own word-at-a-time `memcpy` (`src/copy.zig`),
because the compiler runtime's is a byte loop in this mode and a run spent a third of its instructions
in it. The harness is under 1% of a turn either way, so
[docs/performance.md](performance.md) measures its CPU on `ReleaseFast` and this file measures its
memory on what ships. The last column is dominated by the model's own text, which a run holds once
as the response and once as the output buffer.

After the cancellable provider deadlines were added, a 2026-10-01 check of `ReleaseSmall`
measured medians of 612 kB at `--version`, 892 kB for one frame, 916 kB for 5,000 frames and
1,604 kB for 50,000 frames. Each is three runs through the same ptrace reader and loopback stub;
the long-stream samples ranged from 1,348 to 2,116 kB. The older build-mode comparison above
remains the 2026-09-29 measurement; the README uses the updated `ReleaseSmall` medians.

### Binary size and source

`ls -l zig-out/bin/microagent` after each build of this tree. Each build overwrites `zig-out`, so
the four were built and measured one after another. `build.zig` sets `.strip = optimize != .Debug`:
release builds are stripped, Debug keeps its symbols.

| build | binary |
| --- | --- |
| `zig build -Doptimize=ReleaseSmall` (stripped) | 931,368 B (0.89 MiB) |
| `zig build -Doptimize=ReleaseFast` (stripped) | 1,897,944 B (1.81 MiB) |
| `zig build -Doptimize=ReleaseSafe` (stripped) | 1,718,976 B (1.64 MiB) |
| `zig build` (Debug, unstripped) | 45,730,040 B (43.61 MiB) |

The file size and the resident set are related and not the same: the release modes differ by up to 1.8x
in file size and by 1.3x to 2.7x in memory, and a large file that is never touched costs no memory.
No runtime, no package manager, no node_modules, no Python. Thirteen files under `src/`, 34 037 lines
(`wc -l src/*.zig`):

| file | role |
| --- | --- |
| `main.zig` | the agent loop and its wiring |
| `stream.zig` | folding one provider stream frame into the response, under the response and tool-call ceilings |
| `conversation.zig` | the system prompt, the message array a run appends to, and its compaction |
| `tool.zig` | every tool the model can call, and the process runner they share |
| `chat.zig` | the value types a turn is made of, and the JSON writer request bodies and usage lines go through |
| `session.zig` | the per-run JSONL session log |
| `config.zig` | the config file: reply-style levels, skills and MCP servers |
| `mcp.zig` | MCP servers: tools reached over a child process's stdin and stdout |
| `skill.zig` | skills: instruction documents the model may load while it works |
| `update.zig` | `microagent update`, the checksum-verified self-update |
| `net.zig` | what the machine-facing modules share: CA bundle, deadlines, output sinks, retry policy |
| `sandbox.zig` | the configurable workspace sandbox: Landlock and path confinement |
| `copy.zig` | a word-at-a-time `memcpy` for the ReleaseSmall build, whose compiler runtime copies a byte at a time |

### Startup

`--version`, `perf stat -r 10 -e instructions:u,task-clock`, one session on 2026-09-29. Retired
instructions repeat to within 1% run to run whatever else the machine is doing; CPU time moves more,
so its spread is given:

| harness | instructions | CPU time |
| --- | --- | --- |
| microagent, ReleaseFast (not shipped) | 33,030 | 0.23 ms (+-2%) |
| **microagent, ReleaseSmall (the release asset)** | **43,156** | **0.13 ms** (+-2%) |
| claude 2.1.284 | 12.2 M | 7.6 ms (+-4%) |
| codex 0.157.1 | 8.3 M | 13.1 ms (+-7%) |
| grok 1.0.41 | 138 M | 27.4 ms (+-1%) |
| opencode 1.18.31 | 3.59 G | 738 ms (+-2%) |
| kimi 2.1.1 | 4.14 G | 772 ms (+-4%) |

This table replaces a wall-clock one (hyperfine means, 1.4-2.5 ms for microagent). Wall clock at
this scale measures the machine more than the binary: the same `--version` on the same binary took
442 us and 1.7 ms in one earlier session, and this table was taken with a load average above 40, when
no wall-clock figure would have been fair to any row. The microagent instruction counts are this
tree, re-measured with the same `perf` on the machine the header names; the ReleaseSmall build spends 1.3x the
instructions of ReleaseFast before it prints a byte; both are under a millisecond of CPU.

A gauntlet loop starts an agent once per review, so startup is per-review overhead. On a 60 s review,
a millisecond is 0.002% of the loop; claude, codex and grok (8-28 ms of CPU) stay under 0.05%, and
kimi and opencode (0.74-0.77 s) are about 1.3%. It matters for tight loops (`--retries`, short
timeouts, hundreds of reviews), not for one review.

Turns after the first reuse the TLS session instead of paying a handshake: `keep_alive` defaults to
true in `std.http.Client`, so every turn's request joins the client's connection pool, and the
request's `deinit` drains an unread response tail before handing the connection back. A fresh
handshake per turn would be tens of milliseconds of CPU and two or three round trips, more per turn
than every other cost in this file combined.

### Un-cacheable request bytes

Prompt caching keys on the exact byte prefix of a request, so a turn's body must be the previous
turn's body plus the new messages. That holds only while nothing constant sits *behind* the growing
array.

The tool schemas used to be written after `messages`. They are 4,306 bytes for the nine built-in
tools (the length of `tools_json` in `src/main.zig`), and behind the conversation they fell outside
the cacheable prefix on every turn of every run, so the provider re-read them each time:

| | un-cacheable tail per turn |
| --- | --- |
| tool schemas written after `messages` | 4,306 bytes (~1,077 tokens) |
| written before, as now | **2 bytes** |

Over a 100-turn review that was 0.43 MB of repeated prefill, invisible to every counter in this file,
because `cached_tokens` counts what was reused and never what was not.

JSON member order is not significant, so the constant fields go first and `messages` ends the body.
Two tests hold it there: consecutive bodies must share a prefix of header plus all messages so far,
and the schema must appear before the conversation.

### Harness prompt overhead

The first request of a run, in bytes. Every row is derived from the tree (the prompt and schema
constants), so it can be re-derived without paying for a
run:

| | bytes |
| --- | --- |
| system prompt, as the `{"role":"system","content":"..."}` object | 3,784 |
| the nine tool schemas (`tools_json` in `src/main.zig`) | 4,306 |
| the rest of the body: model, stream flags, `max_tokens`, JSON scaffolding | 123 |
| **everything a request carries besides the conversation** | **8,213** |

That 8,213 is the entire fixed cost of a request, and the schemas are just over half of it. A
`--reasoning-effort` adds the `reasoning` member to the last row, nothing else. The block is re-sent
every turn and cached from the second turn on, so it is a prefix cost, not a per-turn one (see
[Un-cacheable request bytes](#un-cacheable-request-bytes) for the part that is not).

With the remote presets on, the eight preset tools (`terse_tools` in `src/mcp.zig`, used only for a
preset's own host) ship compact descriptions and schemas. What they add to the body is a
configuration rather than a constant of the tree: each is offered under `mcp__<server>__<tool>`, so
its entry's length depends on the server names the config gives the presets.

An earlier figure of 933 tokens, read from a run's usage line, covered six of the nine tools; the
bytes above replace it because they can be re-derived from the tree. Competitor CLIs in one-shot mode
reported no comparable number on this machine, so none is claimed for them.

### Prompt cache

Every turn re-sends the whole conversation, which suits a prefix cache: the prefix is byte-identical
from one turn to the next, and a turn adds only its own messages. OpenAI, DeepSeek and Gemini cache
automatically above their block size, and microagent puts nothing volatile (a timestamp, a shuffled
tool list) ahead of the conversation.

`applyFrame` reads the cached-prompt counter in the three spellings endpoints send
(`prompt_tokens_details.cached_tokens`, DeepSeek's `prompt_cache_hit_tokens`, Anthropic's
`cache_read_input_tokens`) and reports it in the stdout usage line and every session-log record. The
spellings are pinned by the test `cached prompt tokens read every provider spelling`.

**Measured reuse.** `deepseek/deepseek-v4-flash` through OpenRouter, one run of seven turns, one
`bash` call per turn. The usage line is cumulative, so both columns are run totals and the share is
cumulative:

| turn | prompt tokens | cached | cached share |
| --- | --- | --- | --- |
| 1 | 1,290 | 1,024 | 79% |
| 2 | 2,638 | 2,048 | 78% |
| 3 | 4,043 | 3,072 | 76% |
| 4 | 5,506 | 4,352 | 79% |
| 5 | 7,027 | 5,632 | 80% |
| 6 | 8,606 | 6,656 | 77% |
| 7 | 10,243 | 7,936 | 78% |

The cached count climbs by roughly one turn's worth of tokens per turn: the prefix is reused, not
re-read. Turn 1's 1,024 cached tokens are the system prompt and tool schema, byte-identical in every
run, so even a cold run starts with most of its fixed overhead cached at the provider.

**Compaction.** Compaction (`compactMessages`) is the one thing that rewrites the conversation. It
replaces the *content* of old large tool results, never drops or reorders a message, and leaves
everything ahead of the first elided result byte-identical, so those bytes stay the same cached
blocks. It fires only above `conversation_soft_limit` (400 KB), so short runs never pay for it. The
test `compaction leaves the cached prefix byte-identical` builds a conversation whose prefix holds a
quote, a backslash, a newline, a control byte and a non-ASCII byte, compacts it, and asserts the
prefix bytes survive unchanged (a round trip that re-spelled one escape would turn every later turn
into a full re-read).

**Conversation growth.** Measured by `zig build test -Dtest-filter="a long run keeps the
conversation bounded"` over a 120-turn run whose turns each read two 8 KB files, the shape of a real
review (v0.3.0; the per-turn figures are the test's own sums over 120, printed by a temporary
`std.debug.print`):

| | bytes per turn |
| --- | --- |
| conversation sent | 278,587 |
| of which the provider could reuse | 250,694 (90%) |

Eight of those 120 turns compacted the conversation (one in fifteen): the first at turn 25, when the
conversation first passed the 400 KB limit, then every thirteenth turn (38, 51, 64, 77, 90, 103 and 116), each time it
grew back by about half the limit. On those turns the reusable prefix is next to nothing: elision
rewrites the message array oldest first, so the first changed byte is early and everything after it
is re-read. That keeps the evidence the model is acting on, at the price of a full re-prefill.

The prefix does grow, because the walk skips messages it already elided and resumes where the last
compaction stopped, about 3 KB per compaction: from 2,626 bytes at the first to 23,966 at the
eighth, under 6% of the limit. Over a run this size it never recovers; each compaction turn costs
close to a full re-prefill.

`conversation_soft_limit` trades the two directly: raising it means a larger prompt every turn and
fewer full re-prefills; lowering it is the reverse. Only a live provider can say which side wins, so
look at it before a run dies on a provider timeout, not blind.

One consequence is arithmetic, not a measurement: **the uncached bytes a run spends do not depend on
the limit.** Compaction fires each time the conversation grows by half the limit and discards a
prompt of about the limit, so the product is the conversation's growth whatever the limit is. Raising
the limit buys back no uncached prefill; it only buys a larger cached prompt every turn. Eight
compactions over roughly two megabytes of growth is about 1.6 times that growth, the figure the
formula gives. The limit is therefore not a latency knob: it sets how much evidence the model keeps
per token spent.

On the 23-task Terminal-Bench 2 sample ([below](#terminal-bench-2-23-task-sample)) the limit never
fires: 16.5 M input tokens is about 66 MB of prompt, which spread over the turns those tasks took is
72-143 KB per request (a range because the benchmark does not keep the turn count), against a 400 KB
limit. The fixed 8,213 bytes is 6-11% of one request. That prompt is evidence the agent
accumulated, not fixed harness cost and not compaction; the limit is inert at benchmark scale and
binds only on long runs.

### Streaming profile

The harness's only hot loop is the SSE reader: every token delta is parsed and printed. It is
profiled against [`bench/stub_provider.py`](../bench/stub_provider.py), a loopback
OpenAI-compatible endpoint that sends the same fixed stream every run, so only the reader is
measured. Three ReleaseFast builds: the parent of `4d17882` (before), `4d17882` (the commit that
changed the reader) and `1528a2e` (v0.3.0). Host: AMD Ryzen 9 9950X, Zig 0.16.0, 2026-09-29.

| metric | before | `4d17882` | v0.3.0 |
| --- | --- | --- | --- |
| `write` and `writev` calls, 5,000 frames | 5,002 | 38 | 26 |
| all syscalls, 5,000 frames, threads included | 5,369 | 724 | 1,161 |
| instructions, 5,000 frames (three runs) | 42.9-43.3 M | 42.9-43.0 M | 29.1-29.3 M |
| peak RSS, 40,000 frames | 155.4 MB | 2.6 MB | 5.0 MB |

Instructions and syscalls are `perf stat -e instructions:u` and `strace -f -c`; peak RSS is zsh's
`time` `%M`, the kernel's `ru_maxrss` for the process. Instructions, `write` calls and RSS do not
move with machine load. The syscall total does: `readv` follows how the stream's chunks land in each
read, and the same v0.3.0 build made 379 in one run and 836 in another. Wall time, cycles and CPU
time move with load too, and the machine was under load when this table was taken, so none is
reported here.

`4d17882` made two changes, both in `streamChat`:

1. **Output is buffered per read chunk instead of written per token.** One `write(2)` per delta
   became one per chunk the provider sent. Tokens in the same chunk were always drawn in the same
   tick, so streaming latency is unchanged; the syscall count was pure overhead.
2. **Frames are parsed in a scratch arena reset after each frame.** Before, every frame's
   `std.json.Value` tree lived until process exit, so a long completion grew the heap without bound:
   40,000 frames cost 155 MB. Text that must survive the reset is copied into the run arena.

The instruction drop from `4d17882` to v0.3.0 is the later switch from a `std.json.Value` tree to
declared frame shapes ([performance.md](performance.md#what-was-changed-and-what-it-bought)).
v0.3.0's peak RSS is about twice `4d17882`'s on the same stream; that is not yet explained.

Regression tests (`zig build test`): `a long stream costs the largest frame, not the sum of frames`
folds 20 000 frames through `applyFrame` with the per-frame reset and asserts the scratch arena's
`queryCapacity()` is *exactly* what one frame needed; it checks a byte counter, not wall clock, so a
loaded CI box cannot move it. `tool call fragments merge by index across frames` and `usage counters
land on the result` pin the frame-parsing behaviour the change touched.

To reproduce one column:

```sh
uv run --no-project bench/stub_provider.py 18901 --frames 5000 &
export MICROAGENT_API_KEY=stub MICROAGENT_BASE_URL=http://127.0.0.1:18901/v1 \
  MICROAGENT_CONFIG= MICROAGENT_SKILLS= MICROAGENT_SESSION_DIR=
strace -f -c microagent -p "say words" >/dev/null
perf stat -e instructions:u microagent -p "say words" >/dev/null
zsh -c 'TIMEFMT=%M; time microagent -p "say words" >/dev/null'   # peak RSS, KB
```

### Fault injection

`bench/stub_provider.py --fail-first 2` answers 503 twice and then streams a valid completion, which
exercises the retry path (v0.3.0, 2026-09-29):

| request | server | client |
| --- | --- | --- |
| 1 | 503 | waits 1 s |
| 2 | 503 | waits 2 s |
| 3 | 200 SSE | prints the text and the usage line, exits 0 |

Total 3.02 s, dominated by the backoff. The same run shows plain-HTTP base URLs work on loopback, so
a local vLLM or LiteLLM endpoint needs no TLS. A 400 (invalid model) fails at once, unless
`--reasoning-effort` was set, which earns one retry without the `reasoning` field ([usage.md](usage.md#failure-handling)); a 400 that stands ends the run with the provider's message on stderr and exit code 1.

```sh
uv run --no-project bench/stub_provider.py 18731 --frames 1 --fail-first 2 &
MICROAGENT_API_KEY=stub MICROAGENT_BASE_URL=http://127.0.0.1:18731/v1 microagent "say pong"
```

## Task results

### One trivial request

`Reply with exactly: pong`, one-shot, no repository. Harness overhead plus one round trip, the floor
for any loop.

| harness | model | wall | run tokens |
| --- | --- | --- | --- |
| microagent | deepseek/deepseek-v4-flash | 3.9 s | 972 |
| opencode | build · big-pickle | 4.2 s | n/a |
| kimi | kimi CLI default | 8.2 s | n/a |

Only microagent prints machine-readable counters, so the token column is not a comparison.

### Task benchmark

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

The diff column is `git diff --numstat` over the staged tree. A binary file has no lines to count and
git spells its two columns as `-`, so a run that added one reads `+0/-0 (1 binary)`, not the `+0/-0`
of a run that changed nothing.

All three harnesses solved 3/3, each with the minimal correct diff. microagent was fastest on every
task, but the models differ (a stealth model behind opencode, an unspecified Kimi default,
deepseek-v4-flash behind microagent), so wall time here compares *stacks*, not harness overheads; the
[harness costs](#harness-costs) are the harness-only numbers. Tokens are run-cumulative for
microagent and unavailable for the other two, which print no machine-readable counters in one-shot
mode.

### gauntlet loop

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

Both diffs were the correct fix, and gauntlet read the token counts from microagent's stdout usage
lines with no `usage.roots` session-store entry configured.

### Usefulness

The task benchmark measures plumbing: can the loop drive tools and land a diff. `bench/gauntlet.sh`
measures usefulness on real work: the same gauntlet review, on the same repository clone, once per
agent, scored on the review's own verdict, whether a diff landed, whether the patched tree still
passes `zig build test`, and how long it took.

Scenario: one review at a time against a clone of this repository, 12 minutes per review, gauntlet
1.25.0. Model names are the router ids microagent was given; kimi runs its own default.

| agent | model | budget | review | gauntlet | files | verify | wall |
| --- | --- | --- | --- | --- | --- | --- | --- |
| microagent | deepseek/deepseek-v4-flash | n/a | error-review | fail (timeout) | 0 | n/a | 720 s |
| microagent | deepseek/deepseek-v4-flash | n/a | error-review, `--reasoning-effort low` | fail (timeout) | 0 | n/a | 720 s |
| microagent | stealth/space-bunny-alpha | n/a | error-review | fail (timeout) | 0 | n/a | 721 s |
| **microagent** | stealth/space-bunny-alpha | n/a | error-review | **pass** | 1 | ok | 284 s |
| **microagent** | stealth/space-bunny-alpha | n/a | error-review | **pass** | 1 | ok | 334 s / 335 s |
| **microagent** | stealth/space-bunny-alpha | n/a | cli-review | **pass** | 1 | ok | 372 s |
| microagent | deepseek/deepseek-v4-flash | 480 s | error-review | pass | **0** | n/a | 594 s |
| kimi 2.1.1 | CLI default | n/a | error-review | pass | 1 | not run | 185 s |
| kimi 2.1.1 | CLI default | n/a | cli-review | pass | 2 | ok | 144 s |

Bold rows are one configuration; the three timeout rows ran *before* the system prompt was hardened.

- **gauntlet's "Passed" does not mean a diff landed.** deepseek's budgeted run passed with an
  untouched tree: the budget cut the loop, the model answered with prose, gauntlet saw a completed
  review. Hence the benchmark counts files with `git diff --numstat` and runs the project's own
  check; without those columns a usefulness benchmark flatters every agent equally.
- **The diffs are real work.** microagent's cli-review run added per-flag error messages in
  `src/main.zig` (+53/-13); kimi's did the same kind of thing across `src/main.zig` and `README.md`
  (+54/-21). Both patched trees build and pass 9/9 tests.
- **Model choice dominates.** The same harness on the same review timed out three times on two
  deepseek configurations and passed on bunny-alpha.

Three defects and one behaviour problem came out of these runs, most important first:

1. **A model-qualified agent spec never ran.** gauntlet's custom-agent definitions insert the model
   flags right after `-p`, so `["microagent", "-p", "{prompt}"]` produced
   `microagent -p --model stealth/... <prompt>`; microagent took `--model` as the prompt and exited
   2. Fixed by accepting the prompt as a bare argument: the definition is now
   `["microagent", "{prompt}"]` and flags work in any order.
2. **The agent wandered instead of editing.** On the pre-hardening prompt, the bunny run spent its
   twelve minutes grepping `/home/maci/.zvm/0.16.0/lib/std` (dozens of calls inside the Zig standard
   library to answer a question about this repository) and changed nothing. The system prompt now
   says to budget its steps, not to audit unrelated code, and not to read library or standard-library
   sources. The next runs made ~50 tool calls, never opened `lib/std`, and landed diffs.
3. **Nothing forced convergence inside the caller's timeout.** Added `--budget <seconds>`
   (`MICROAGENT_BUDGET_SECONDS`), which stops starting turns at the budget and spends one final turn
   telling the model to make the edit it already knows about, plus a last-turn notice at the
   `--max-turns` boundary.
4. **`--reasoning-effort low` did not help.** deepseek-v4-flash still burned its full budget without
   editing. The flag stays because it passes through cleanly, but it is not claimed as a fix; the
   budgeted deepseek row shows a clean stop, not a fix.

Attribution caveat: the passing runs differ from the timeout runs in both the system prompt and the
budget knob, and in the passing runs the budget never fired (`--max-turns` did, at 60 turns). These
are single runs against a stealth model behind a router that may re-route. The direction is clear
(three timeouts with zero files changed, then three passes with diffs), but this is evidence, not a
controlled experiment.

### Terminal-Bench 4.0

The current release of Terminal-Bench (v4.0.0, 26 August 2026): 66 containerized tasks, a
maintenance release on 3.0 that removed eight tasks and revised eighteen. It is the dataset
`terminal-bench/terminal-bench@4.0.0` in Harbor's registry, run through the same adapter as
Terminal-Bench 2, and `bench/harbor.sh tb4` drives it. Every task has an 8 hour agent timeout, which
the script scales to 3600 s for both harnesses (`--agent-timeout-multiplier 0.125`) so that a task
neither harness can solve does not run for hours; the in-container cap is 3480 s and the working
budget 3100 s.

The sample is every third of the 66 tasks, sorted by name, fixed before any run:
[bench/tb4-sample.txt](../bench/tb4-sample.txt), 22 tasks. Two of them, `fp8-rmsnorm-gemm` and
`jax-speedrun-gpu`, ask for a GPU. A host without one cannot run them, so on such a host they are
reported as not run and are not scored 0.

Task ids in this dataset carry the dataset's name (`terminal-bench/<task>`), and `-i <task>` alone
matches nothing, so the script adds the prefix.

Checked so far, and not more: Harbor 0.23.0, the version the adapter pins, downloads all 66 tasks and
runs `html-js-filter` with its oracle solution to reward 1.0 and no exception; a microagent trial on
the same task starts, uploads the binary and reaches the provider (with a deliberately invalid key, so
it ends at `http 401`). **There is no microagent score on this dataset yet.** It needs a provider key
and a run, and the Terminal-Bench 2 numbers below are not comparable to it.

### Aider polyglot

The quick one. [aider-polyglot](https://aider.chat/docs/leaderboards/) is 225 small exercises, each a
2 KB instruction and a unit-test suite, in six languages (C++, Go, Java, JavaScript, Python, Rust). It
is the dataset `aider/aider-polyglot` in Harbor's registry, and `bench/harbor.sh polyglot` drives it
through the same adapter. Where a Terminal-Bench 4.0 task can use a whole hour, a polyglot trial is
minutes: one CPU, 4 GB, and an image that builds in about a minute. Every task allows 1800 s, which
the script halves for both harnesses (`--agent-timeout-multiplier 0.5`); the in-container cap is 870 s
and the working budget 500 s. Published aider results exist for the full set, which the other Harbor
benchmarks here lack, but a sample is not the leaderboard: compare harnesses on the same sample.

The sample is every 11th of the 225 tasks, sorted by name, fixed before any run:
[bench/polyglot-sample.txt](../bench/polyglot-sample.txt), 21 tasks (3 C++, 3 Go, 5 Java, 4
JavaScript, 3 Python, 3 Rust). Task ids carry the prefix `aider/`, which the script adds.

Checked so far, and not more: Harbor 0.23.0 downloads all 225 tasks and runs the reference solution of
`polyglot_go_octal`, `polyglot_python_bowling` and `polyglot_rust_two-bucket` to reward 1.0 with no
exception, 69 to 120 s per trial including the image build and the verifier, three at a time in 2
minutes. **There is no microagent score on this dataset yet.**

### DeepSWE

[DeepSWE](https://deepswe.datacurve.ai/blog/deepswe) (Datacurve) measures coding agents on original,
long-horizon engineering tasks written for the benchmark, across five languages and 91 open
source repositories. Harbor's registry carries it as `datacurve/deep-swe-1-1`, 113 tasks, and
`bench/harbor.sh deepswe` drives it. Each task gives the agent 5400 s and no network, so the script
lets the provider's host through (`--allow-agent-host`, taken from `MICROAGENT_BASE_URL`, OpenRouter
by default) and nothing else. The in-container cap is 5000 s and the working budget 4600 s. The
verifier is separate from the agent's container and reports fail-to-pass and pass-to-pass counts
beside the reward, which `integrations/harbor/summarize.py` reads as `reward`.

The sample is every ninth of the 113 tasks, sorted by name, fixed before any run:
[bench/deepswe-sample.txt](../bench/deepswe-sample.txt), 13 tasks. Task ids carry the prefix
`datacurve/`, added by the script.

The DeepSWE repository documents its own runner, Pier, and its published numbers use
`mini-swe-agent`. This run uses Harbor and microagent's own loop, so its numbers compare harnesses
here and are not entries for that leaderboard.

Checked so far, and not more: Harbor 0.23.0 downloads the 113 tasks and runs `expr-try-catch-errors`
with its oracle solution to reward 1.0 (79 of 79 fail-to-pass, 66,265 of 66,265 pass-to-pass), and a
microagent trial in the no-network container reaches OpenRouter through the allowlist (with an invalid
key, so it ends at `http 401`). Harbor warns that the task's artifact path overlaps another; that is
in the dataset. **There is no microagent score on this dataset yet.**

### Terminal-Bench 2

Superseded by [Terminal-Bench 4.0](#terminal-bench-40) as the current release; the numbers here are
Terminal-Bench 2 numbers and stay as the record of what was run.

The external benchmark for a coding harness: 89 containerized tasks with their own verifiers, driven
through Harbor. microagent runs inside the task container as a static binary with no C library (`make musl`), so
its own shell and file tools operate on the task's real files. Adapter and instructions:
[integrations/harbor/README.md](../integrations/harbor/README.md). Comparisons with opencode are in
[Head to head with opencode](#head-to-head-with-opencode).

#### Five-task set

Model `deepseek/deepseek-v4-flash` (OpenRouter), reasoning off, 600 s agent budget, `-n 2`:

| task | reward | wall |
| --- | --- | --- |
| log-summary-date-ranges | 1.0 | 47 s |
| fix-git | 1.0 | n/a |
| cobol-modernization | 1.0 | n/a |
| overfull-hbox | 0.0 | 600 s budget |
| adaptive-rejection-sampler | 0.0 | 600 s budget |
| **batch mean** | **0.600** (3/5) | 5m10s |

Both zeros first failed with `TlsInitializationFailed`: bare `ubuntu:24.04` images ship no CA store.
That harness defect produced `--ca-bundle`; with the host bundle written into the container (resolved
through its symlink, which `docker cp` would otherwise copy as a dangling link) both tasks run to
completion. They still score 0.0 because the model does not solve them inside the budget.

After the fixes in [Harness faults the benchmarks found](#harness-faults-the-benchmarks-found), the
same five tasks: **5/5 trials completed, 0 exceptions, 3/5 solved, 10m55s**. Before them the same set
lost a task to `RuntimeError: Command timed out after 880 seconds` and another to the agent timeout.

#### 23-task sample

Five hand-picked tasks cannot separate two harnesses, so the comparison uses a stride sample of the
real benchmark: every fourth task of the 89, sorted by name, chosen before the run. Results are in
[Head to head with opencode](#terminal-bench-2-23-task-sample).

### SWE-bench Verified

Harbor's `swebench-verified@1.0` registry dataset (500 instances), same adapter and binary as
Terminal-Bench 2, `deepseek/deepseek-v4-flash`. Instances are a deterministic stride sample (every
40th of the 500, sorted by name) chosen before the run.

#### Baseline run

Reasoning off, 1200 s budget, `-n 4`:

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

Zero exceptions. An earlier sample of four instances scored 0.750 (pytest-5809, sphinx-8593,
xarray-3095 resolved; sympy-13852 not); four instances is noise, as the larger sample shows.

- **The input token column is the harness's own doing.** Every turn re-sends the whole conversation,
  so the 1.78M-token instance is not a hard task but the same files paid for repeatedly. That is what
  led to `compactMessages`, which elides the content of the oldest large tool results once the
  conversation passes 400 KB, keeping assistant messages, the task instruction and every
  `tool_call_id` intact. The table above is the before side.
- **Repos beat prompts.** The failures spread across django, matplotlib and pylint, not one
  review-shaped weakness. microagent has no repo-specific tooling and no language server, so its
  SWE-bench score comes from the model plus search and edit.

#### After conversation compaction

Same 13 instances, model and budget, with `compactMessages` in the binary:

| | before | after |
| --- | --- | --- |
| resolved | 5/13 (0.385) | 7/13 (0.538) |
| input tokens | 6.10 M | 5.44 M (-11%) |
| output tokens | 84 k | 80 k |
| wall | 11m45s | 13m15s |

Read this as noise, not a win. Instances moved both ways (`sympy-13877` fell from 610k to 122k input
tokens while `django-12308` rose from 157k to 343k) and flipped between resolved and not in both
directions, because the model is sampled and loop length is not fixed. Thirteen instances carry
roughly +/-13% standard error at this rate, so 5/13 and 7/13 are the same result. Compaction stays
because it bounds how large one conversation can grow and the bound is unit-tested, not because this
table shows a saving.

#### Turn ceiling and budget

The baseline run was partly clipped by the harness: two instances stopped at exactly 60 turns (the
`--max-turns` default then), and one stopped at 54 with the 1200 s budget gone. Re-run with the
ceiling at 150 turns and the budget at 2700 s (inside the task's own 3000 s agent timeout):

| instance | before | after | turns used |
| --- | --- | --- | --- |
| matplotlib__matplotlib-25775 | 0.0 | **1.0** | 99 |
| pylint-dev__pylint-4551 | 0.0 | 0.0 | 97 |
| sympy__sympy-21379 | 0.0 | 0.0 | 75 |

The default ceiling is now 100 (`max_turns_default` in `src/main.zig`), and the harbor adapter passes
`MICROAGENT_MAX_TURNS` (150). The system prompt was rewritten to the order a bug fix needs: find the
code and its tests, reproduce the failure, make the smallest change, re-run the test, check
`git diff`. Deterministic tools behind that prompt: `search` (ripgrep), `ast` (ast-grep), `git`
(status, diff, log, show, blame: fixed subcommands, capped output) and `read`/`edit`/`write`.
`patchwork` on this machine is graphviz's binary, not the AST rewriter, and `semcode` is a dangling
symlink into a never-built cargo target, so neither is wired up.

#### Verification gate

The failure mode behind it: a SWE-bench instance ended after 20 turns with **zero** test commands,
while every instance that passed ran five to fifteen. The loop now tracks, per tool call, whether the
run has edited the tree and whether it has run a test runner; if it edited without verifying, it is
asked once to run the tests before it may finish.

Across the 13-instance run that followed, the gate fired on one instance (`sympy__sympy-13877`), which
still failed. It stays as a cheap safety net for a real failure mode, not as a measured improvement.

#### Every run of the 13

Every run of the same 13 instances, same model, same containers, in the order they ran. Picking the
best row would be picking noise, so all are listed. The run name is the Harbor job directory, and
each row is read from that job's `result.json`:

| run | config | solved | exceptions |
| --- | --- | --- | --- |
| `2026-09-28__22-33-12` | baseline harness | 5/13 | 0 |
| `compacted` | conversation compaction | 7/13 | 0 |
| `microagent-reasoning` | compaction, reasoning on, 1200 s task timeout | 7/13 | 0 |
| `microagent-full` | git tool, workflow prompt, 150 turns, 2700 s | 8/13 | 0 |
| `microagent-full-2` | same | 7/13 | 0 |
| `microagent-r3` | same | 6/13 | 0 |
| `microagent-r5` | same | 5/13 | 0 |
| `microagent-r6`, `microagent-r7` | the loop regression ([faults](#harness-faults-the-benchmarks-found)) | 0/13 each | 13 each |
| `microagent-r8` | verification gate, reasoning off | 6/13 | 0 |
| `microagent-r9` | stronger completion rule, reasoning on | 7/13 | 2 |
| **pooled** | every run except r6 and r7 | **58/117 = 0.496** | |

r6 and r7 are left out of the pool because every trial is the same harness fault (`RuntimeError:
microagent exited 3`), not a model outcome.

Published full-set (500-instance) results are what to compare against, not this sample.

### Head to head with opencode

Common to every run below: the same machine, the same model (`openrouter/deepseek/deepseek-v4-flash`,
one OpenRouter key), the same task containers, harbor 0.23.0, opencode 1.18.31. opencode runs through
harbor's built-in adapter (installs node and the CLI into each task container); microagent runs
through [integrations/harbor/microagent_agent.py](../integrations/harbor/microagent_agent.py).

#### SWE-bench Verified, 13 instances

At a 1200 s per-task timeout, `-n 4`, one run each (jobs `microagent-reasoning` and `opencode`; the TB2 rows are a separate five-task pair):

| | microagent | opencode |
| --- | --- | --- |
| SWE-bench Verified, 13 instances | 7/13 = **0.538** | 9/13 = **0.692** |
| Terminal-Bench 2, same 5 tasks | 3/5 = **0.600** | 3/5 = **0.600** |
| input tokens, SWE run | 4.46 M | 8.19 M |
| output tokens, SWE run | 224.7 k | 54.7 k |
| wall, SWE run | 18m07s | 30m25s |
| wall, TB2 run | 5m10s | 23m26s |
| exceptions | 0 | 1 (`AgentTimeoutError` on TB2) |

- **The SWE-bench gap is two tasks and is not established.** At roughly +/-13% standard error, 0.538
  against 0.692 is directional. A 50-instance run would be needed before quoting these numbers.
- **microagent is the smaller engine.** About half the input tokens, 1.7x less wall time on
  SWE-bench and 4.5x less on TB2; most of the TB2 difference is opencode installing a node runtime in
  every task container before it can start. microagent produced four times the output tokens because
  reasoning was on for that run; the reasoning-off baseline used 84 k output for the same 13.
- **Terminal-Bench 2 is level at 3/5**, and opencode lost one task to an agent timeout that
  microagent's `--budget` prevents by stopping deliberately.

At the benchmark's own timeout, `-n 4`, two runs each. microagent is the current build (git tool,
bug-fix workflow prompt, 150-turn ceiling, 2700 s budget); opencode runs its own defaults (its task
timeout is the benchmark's 3000 s):

| run | microagent | opencode |
| --- | --- | --- |
| SWE-bench Verified, run 1 | 8/13 = 0.615 | 6/13 = 0.462 |
| SWE-bench Verified, run 2 | 7/13 = 0.538 | 7/13 = 0.538 |
| **pooled** | **15/26 = 0.577** | **13/26 = 0.500** |
| wall, 13 instances | 16m25s / 18m29s | 24m34s / 30m09s |
| input tokens, 13 instances | ~4.5 M | ~8.2 M |
| exceptions | 0 | 0 |

Pooled over 26 paired trials microagent leads by two. opencode's own SWE scores span 0.23 (0.462 here
to 0.692 at the 1200 s timeout above), wider than the 0.077 between the two harnesses pooled. Across
its three runs opencode is 6/13, 7/13 and 9/13, 22/39 = 0.564 pooled, against microagent's 0.496
over [every run of the 13](#every-run-of-the-13). The two are inside each other's noise: 13
instances cannot resolve a difference below about 0.25 without hundreds of runs.

#### Terminal-Bench 2, five tasks

The same five tasks, each harness at the benchmark's own timeout:

| run | microagent | opencode |
| --- | --- | --- |
| run 1 | 3/5 = 0.600 | 3/5 = 0.600 |
| run 2 | 3/5 = 0.600 | 4/5 = 0.800 |

microagent's run-2 losses were `overfull-hbox` (a genuine 0.0) and `adaptive-rejection-sampler`,
which the adapter killed at its 880 s process timeout: the agent's `--budget` was checked only
between turns, so one long tool call could overrun it. The fix (clamping every tool timeout to the
time left) is in [Harness faults the benchmarks found](#harness-faults-the-benchmarks-found). The
two runs split; nothing here is a decisive win.

#### Terminal-Bench 2, 23-task sample

Every fourth of the 89 tasks, sorted by name, chosen before the run. Same per-task timeouts, one run
each, one harness at a time:

| | microagent | opencode 1.18.31 |
| --- | --- | --- |
| solved | **11/23 = 0.478** | 7/23 = 0.304 |
| exceptions | **0** | 12 |
| wall | 55m31s | 1h17m46s |
| input tokens | 16.5 M | 8.7 M |
| output tokens | 377 k | 87 k |

Where the two disagree, both directions exist: microagent solves `largest-eigenval`,
`password-recovery`, `regex-log`, `git-leak-recovery`, `sanitize-git-repo` and `sqlite-with-gcov`,
which opencode does not, and opencode solves `pypi-server`, `feal-differential-cryptanalysis` and
`build-pmars`, which microagent does not. The categorical difference is the exception column:
opencode's twelve are nine `AgentSetupTimeoutError` (its own install step timing out in those
containers), two `AgentTimeoutError` and one non-zero exit; microagent finished every trial, because
its budget ends the loop deliberately instead of the caller killing it.

11/23 against 7/23, with a standard error near 0.10 each, is a difference of about 1.7 standard
errors: suggestive, not proof. The exception count is not noise. With 23 tasks and a categorical
difference in finished trials, this is the sample where a claim can be made.

microagent spends about 1.9x the input tokens and 4.3x the output, which is 1.2x and 2.8x per task
solved. A harness that keeps more evidence in front of the model spends more; [Prompt
cache](#prompt-cache) shows those bytes are accumulated evidence, not fixed cost or compaction.

A second pass of the same sample ran both harnesses **in parallel** and is not a valid comparison:
two 23-task jobs competed for the same four cores and the same rate limit, and the adapter in that
process was the one loaded before the fix that scores an incomplete (exit 3) run's tree instead of
raising, so every unfinished microagent trial was recorded as an exception and discarded, including
trials whose fix was on disk.

| pass | conditions | microagent | opencode |
| --- | --- | --- | --- |
| 1 | sequential, one harness at a time | **11/23**, 0 exceptions | 7/23, 12 exceptions |
| 2 | both in parallel, pre-fix adapter | 5/23, 9 exceptions (all `RuntimeError`) | 4/23, 19 exceptions (5 setup timeouts, 14 `RuntimeError`) |

Pooled, microagent is 16/46 against 11/46, but only pass 1 is valid: pass 2 measured machine load and
an adapter bug. A third pass is listed under [Not measured / open](#not-measured--open).

Neither harness was tuned for the other's benchmark. opencode ships repo-aware tooling and a much
larger prompt; microagent ships eight tools and a prompt of a few thousand bytes. That trade
is visible in the token columns.

## Harness faults the benchmarks found

None of these was visible without a real benchmark run, and two cost whole tasks before they were
fixed:

| fault | symptom | fix |
| --- | --- | --- |
| The API key was passed as a *privileged header* | every provider answered `401 No cookie auth credentials found`; the key was never on the wire | send it as the request's `authorization` header (`Headers.authorization = .override`), with a regression test |
| A tool's timeout ignored the budget | a two-minute `bash` call started at second 779 of a 780 s budget; the caller killed the task mid-command (Terminal-Bench 2 `adaptive-rejection-sampler`) | clamp every tool timeout to the time left, floor 5 s |
| The budget did not fit the caller's timeout | microagent's final push may run 300 s past its budget, so a 780 s budget inside a 900 s task timeout was still killed | the adapter derives the budget from the timeout it is given, leaving the grace plus margin |
| A turn that asked for tools ended the run | two SWE-bench runs came back 13/13 `RuntimeError: microagent exited 3` in 87 seconds | continue the loop on `.wants_tools` |

The last row came from a refactor of the agent loop that made a turn asking for tools end the run
instead of looping, so every run stopped after its first tool call. Exit 3 ("stopped at a ceiling
with the answer unfinished") was correct for what the loop did. It reproduced in the task container
and locally with `microagent --budget 300 --max-turns 12 "list the files, then say done"`, and after
the fix the same command exits 0 after two turns. A benchmark that reports only a mean hides this:
thirteen identical exceptions in 87 seconds would have read as "the model scored 0.000" without the
exception column.

## Method notes

- **Harness versus stack.** Wall time and solve rate compare a harness plus its model. Only the
  [harness costs](#harness-costs) isolate the harness; task tables compare stacks unless the model
  is the same.
- **Counters over clocks.** Where a number is small enough for the machine to outweigh it (startup,
  the streaming reader), the gate measures instructions or bytes, not time.
- **Samples are chosen before the run.** SWE-bench uses every 40th of 500 instances, Terminal-Bench 2
  every fourth of 89 tasks, Terminal-Bench 4.0 every third of 66, Aider polyglot every 11th of 225, DeepSWE every ninth of 113, all
  sorted by name. Thirteen instances carry roughly +/-13% standard error at the observed rate.
- **Every run is recorded.** Picking the best of several runs of a sampled model picks noise, so
  repeated runs are listed in full and pooled.
- **Exceptions are printed beside scores.** A mean hides a broken loop or a failed setup.
- **One job at a time.** Running two benchmark jobs at once on one machine measured load, not the
  harnesses (see the 23-task second pass).
- **A failed setup is not a zero.** A harness that could not run is named under
  [Not measured / open](#not-measured--open), not scored.

## Not measured / open

- **Other installed harnesses on the task benchmark.** `claude` was rate-limited until the weekly
  reset, `grok` returned HTTP 402 (balance exhausted), `codex` refuses to run outside a trusted
  directory without an extra flag, `crush` reported its model unavailable.
- **The harnesses `bench/overhead.sh` drives that no table here carries.** Its default `agents` list
  also names `gemini`, `cursor-agent`, `clanker` and `dsh`. The script measures whichever of its
  list is on `PATH` and skips the rest, so those four are measured on a host that has them and write
  no row in this file. Nothing above claims a figure for any of them.
- **kimi on Harbor.** Harbor's `kimi-cli` agent refuses to run ("kimi-cli is no longer maintained.
  Please use the new Kimi Code CLI"), and `kimi-code` reaches the provider but every credential in
  `~/.secrets` returns `401 The API Key appears to be invalid or may have expired` against
  `https://api.kimi.com/coding/v1`. There is no kimi column rather than a zero column.
- **Third Terminal-Bench 2 pass (sequential, fixed adapter).** Invalid: the OpenRouter balance behind
  the shared key was exhausted (200.17 USD used that month), and its first trials answered
  `http 402 ... "You requested up to 65536 tokens, but can only afford N ... lower max_tokens"`. Its
  numbers (3/23, 14 `RuntimeError`) are not a score. With `MICROAGENT_MAX_TOKENS=2048` the same
  request succeeds, with the default 65536 it is refused, and the harbor adapter now forwards
  `MICROAGENT_MAX_TOKENS`, so a run can be pointed at a low balance. The pass result would replace
  pass 2, not be averaged with it.
- **Terminal-Bench 4.0 and DeepSWE scores.** The plumbing is checked for both (see their sections);
  no model run has been made, because it needs a provider key and hours of wall time per harness.
  The two GPU tasks in the Terminal-Bench 4.0 sample cannot run on a host without a GPU.
- **A full SWE-bench Verified set.** 500 instances at this rate is roughly 8 hours of wall time and a
  few hundred GB of image pulls; the 13 above are a sample, not a substitute.
- **DSH's own `benchmarks/`** (terminal-io, session-open, active-stream-reconnect and others) measure
  that harness's internals, not a coding agent's usefulness.

## Reproducing

```sh
zig build -Doptimize=ReleaseFast && make install
export MICROAGENT_API_KEY=...      # or leave unset to read ~/.secrets/openrouter
export MICROAGENT_MODEL=deepseek/deepseek-v4-flash
sh bench/run.sh microagent kimi opencode
sh bench/overhead.sh
sh bench/gauntlet.sh microagent kimi
```

`make bench`, `make overhead` and `make gauntlet` wrap those three, each building the binary and
putting it on PATH first. `make instructions` checks retired instructions against
`bench/instructions.baseline`. Harbor runs are driven by `bench/harbor.sh`; see
[integrations/harbor/README.md](../integrations/harbor/README.md).

Raw rows land in `bench/results.jsonl`.
