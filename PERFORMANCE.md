# Performance

What this harness costs, what dominates it, and which levers were pulled and which were not.

Every number here is a counter, not a clock. Retired instructions repeat to within 0.001% for a
fixed binary and a fixed input; wall clock moves with frequency scaling, the CPU quota and whatever
else the machine is doing, and a wall-clock gate fails on a busy runner for reasons that have
nothing to do with the code. `bench/instructions.sh --check` is the gate that enforces this, and
[CONTRIBUTING.md](CONTRIBUTING.md#before-you-push) says when to run it.

## The short version

The harness is not the bottleneck. A run is 47 s to 720 s and the harness's own share of that is
under 1% per turn: 1.3 ms of CPU before the first byte reaches the provider, and about 4,100
instructions per streamed frame. The model and the tool subprocesses are the run.

What that means is that the levers worth pulling are not in the CPU. They are in the bytes on the
wire, in what the run waits for, and in what it holds resident — none of which a profiler or an
instruction counter will show you.

## Where the work goes

Measured with `perf stat -e instructions`, median of three, net of a baseline binary. The per-frame,
compaction, body and ranged-read rows are the ones `bench/instructions.baseline` gates, so a row here
that moves is a gate that moved with it:

| path | instructions | per unit |
| --- | --- | --- |
| process start, arg parse (`--version`) | 476,025 | — |
| everything before the first request is sent | 1,303,779 | — |
| a streamed content frame (47 B) | — | 4,101 |
| a streamed tool-argument frame | — | 9,253 |
| compaction of a 1 MB conversation | 37,153,055 | one call |
| building the request body (the row measures 40 of them) | 113,946 | 2,849 |
| a ranged read of a 512 KB line | 7,543,604 | one call |
| the session log's share of a run (ReleaseFast) | 332,061 | once per run |
| one more turn of the loop (ReleaseFast) | 47,552 | a tool call that runs nothing |

Against a 284 s review and roughly 20,000 frames, the streaming path is on the order of ten
milliseconds of CPU in total. Changing it is not worth risk.

Syscalls, which no instruction count carries: 180 for `--version`, 277 for the whole pre-request
path, and nothing per turn beyond one session-log write and one stdout write per chunk.

The turn and session rows are measured the same way -- `perf stat -e instructions`, median of three,
against a stub provider on loopback that always asks for a tool that does not exist -- but on the
shipped `-Doptimize=ReleaseFast` binary rather than the Debug test binary the frame, compaction and
ranged-read rows come from. Debug's checked arithmetic and debug allocator make these two about four
times larger, so the two sets are not comparable: 194,762 and 1,290,450 were the Debug figures and
are not what a release build pays. The turn row is `--max-turns 101` minus `--max-turns 1` over the
hundred turns between them; the session row is a one-turn run with and without
`MICROAGENT_SESSION_DIR=`.

A thousand turns on the same binary is 53.1 M instructions, 427 ms of wall (most of that the stub,
which is Python), and peak RSS flat at 12.6 MB. The marginal turn barely moves as the conversation
grows -- 47,552 instructions between the first and hundredth, 51,479 between the hundredth and
thousandth -- so the re-sent conversation costs about 4 k instructions a turn more at 200 KB than at
2 KB. That copy is the same bytes the provider bills for on every turn; a chunked send would save
our copy and leave the bill, so it is left as it is. The loop does not open a connection per turn
either: ten turns against a keep-alive stub opened one TCP connection, because the client's pool
returns the socket after each response is read.

## What was changed, and what it bought

| | before | after | why |
| --- | --- | --- | --- |
| un-cacheable request bytes | 3,775 B/turn | **2 B/turn** | the tool schemas were written after `messages`, so they fell outside the cacheable prefix every turn |
| streamed frame parse | 7,204 instr | **4,101 instr** | declared shapes instead of a `std.json.Value` tree, with the generic parse kept behind them |
| ranged read of a long line | quadratic | **linear** | each 8 KB read copied the whole accumulated buffer onto itself; the self-copy, not the re-scan, was the cost (see below) |
| a retry wait past the budget | up to 6 min asleep | **refused** | `--budget` was defeated by the `Retry-After` path |
| turn arena after a ceiling-sized response | 48 MB resident | **4 MB** | the reset retained without bound |
| MCP server startup, 3 servers | 1.513 s | **0.506 s** | every server is spawned before any is asked to initialize, so their boots overlap: the run waits for the slowest server instead of the sum |

The two largest wins are not CPU at all. The request-bytes one is the single most valuable change in
the file and it is invisible to every counter the harness prints: `cached_tokens` reports what was
reused and never what was not.

## What was tried and not kept

Kept out on the numbers, not on taste:

- **A hand-rolled SSE scanner.** 8.8x fewer instructions than the declared-shape parse, saving
  about 0.56 us a frame. Against a 284 s run that is 0.005% of wall clock, in exchange for 120 lines
  of hand-written JSON scanning on the one path carrying the model's own output.
- **A word-at-a-time escape scan.** 0.4% on a 1 MB write, because the copy into the writer is the
  cost and the scan never was.
- **Parallel tool calls.** `rg` costs 6.1 ms and `git log` 1.7 ms on this repository, so a
  parallel batch saves about 5 ms — and the tools that are actually slow are the ones unsafe to
  run concurrently.
- **A byte-level compaction rewrite.** Compaction is 4.7 ms per megabyte, about 0.02% of a run, and
  the replacement would hand-rewrite the exact bytes the prompt cache depends on.
- **A prefix read for skill discovery.** The listing reads each `SKILL.md` whole and keeps it in the
  run arena, because the name and description it lists are slices of that text. Measured with
  `hyperfine -w 3 -r 15` against the stub provider: 20 skills of 4 KB are inside the noise of no
  skills at all (p50 1.28 against 1.36 ms), 200 of them add 0.7 ms, and 200 of 100 KB add 5 ms and
  about 20 MB resident. A head-only read helps only the last case, since a file smaller than the cap
  is read whole either way, so it is not worth the open-and-read-to-a-limit loop it needs. Revisit if
  a skill library that size turns up.

The escaper tests that came out of the second attempt were kept, because they cover a real edge:
the escaper takes a byte's width from its lead byte, and an escapable byte or a multi-byte character
landing at an arbitrary offset is a body that stops being valid JSON when it is wrong.

### Which half of that quadratic mattered

I attributed it to "a full re-scan and a full self-copy per read". Measured
afterwards by defeating one half at a time and running the gate:

| defeated | gate row | result |
| --- | --- | --- |
| the search cursor | 7,515,139 | **inside the band** — 0.4% |
| the self-copy guard | 47,965,253 | **6.4x, reported, exit 1** |

So the copy was the quadratic and the re-scan was not. The cursor is still
right to keep -- it removes a real second pass and the scan is O(n) rather than
O(n^2) once the copy is gone -- but it was never the expensive half, and the
original description credited both equally.

That check also proves the gate row is not decorative: the fix it guards cannot
be reverted without the row failing.

## Four classes a profiler cannot see

The defects that were worth finding were none of them CPU. They are worth listing because the
categories generalise past this repository:

| class | why a profiler misses it | example |
| --- | --- | --- |
| wire bytes | no instruction is spent on them | 3.8 KB of tool schema re-read every turn |
| waiting | the cost is sleep | a 429 sat the run out for six minutes inside `--budget`, and three MCP servers were handshaken one at a time, so a run paid their boot times in series |
| resident memory | instruction counts do not carry it | 48 MB retained after one large response |
| fallback paths | the primary path works | `date +%s` standing in for a monotonic clock |

Each was found by asking what a counter would not see, or by reading a feature end to end rather
than profiling it.

## Open, and deliberately

`conversation_soft_limit` is the one knob left that moves a run's wall time. It is inert at
benchmark scale — the stride sample's conversations average 72-143 KB against a 400 KB limit, so it
never fires — and it only binds on long runs. Its uncached cost does not depend on the limit at
all: compaction fires once per half-limit of growth and discards a prompt of about the limit, so
the product is the conversation's growth and the limit cancels. Deciding it needs a live provider,
and it is the only thing here that does.

## Are these fixes still guarded?

A fix with no guard is a fix that will be undone by the next refactor and
nobody will notice. Each row below was re-checked on this tree; the third column
is the result of *defeating the fix* and confirming the guard fails, not just
the guard's existence.

| fix | guard | defeated? |
| --- | --- | --- |
| constant request fields ahead of `messages` | `one request body is the previous one`, `the tool schema sits inside the cacheable prefix` | 5 tests fail |
| declared frame shapes | `bench/instructions.sh --check`, `stream content frame` row | 4,101 to 7,431, exit 1 |
| ranged-read cursor and self-copy | `bench/instructions.sh --check`, `ranged read` row | 7,543,604 to 47,965,253, exit 1 |
| retry waits inside the budget | `a wait the budget cannot cover` | present |
| bounded turn-arena retention | `a turn that outgrows the retained size` | present |
| session pruning by path | `a log in a subdirectory is pruned` | present |
| escaper correctness | `a fuzzed byte string leaves a JSON string that reads back as itself` | fuzzer |
| MCP servers started before any handshake | `every server is started before any of them is asked to initialize` | defeated: two servers connected to one, test fails |

Re-checking one of these takes a minute and is worth doing after any refactor
that touches a test file, because guards move. Three things have to be told
apart, and confusing the first two is how a broken guard gets reported as a
sound one:

1. the build **failed** — nothing ran, so nothing was proven either way;
2. the test ran and **passed**;
3. the test ran and **failed** — the guard fired.

Only the third proves anything, and a check that greps for a failure string
reports 1 and 2 identically.

**A guard that disappears is not automatically lost coverage.** Two escaper
tests here were removed by a refactor and looked like a regression twice. They
had been replaced by a fuzzer over arbitrary byte strings, which subsumes the
fixed cases they covered — so putting them back would have duplicated a better
check. Check what replaced a guard before rebuilding it.

## Reproducing any of this

```sh
make instructions CHECK=--check     # the table above, gated
make overhead                       # startup and first-request cost per harness
zig build test -Dtest-filter="a long run keeps the conversation bounded"
```

The MCP startup row is a wall-clock figure, so it was measured the way a product number is, with
`hyperfine -w 2 -r 10` against a stub provider on loopback and three servers whose command sleeps
0.5 s before it starts answering: mean 1.513 s before, 0.506 s after, with the same numbers for six
servers after the change (0.505 s), which is the point of it — the run waits for the slowest boot,
not the sum. Its guard is a test, not a clock: the waiter server refuses to answer until the starter
server has run, so a sequential connect drops it and the test sees one server where it expects two.
On a machine where `/bin/sh` has no fractional `sleep` the waiter's bounded wait spins instead of
sleeping and the guard still works, only faster to give up.

The skill-discovery row is the same shape of measurement: `MICROAGENT_SKILLS` pointed at a directory
of N generated `SKILL.md` files, `hyperfine -w 3 -r 15`, and the numbers above are the medians.
`hyperfine -w 3 -r 20` over an instant-answer server put the whole MCP path — spawn, two round
trips, and the reap at the end — at 0.7 ms for one server, 1.2 ms for three and 3.2 ms for ten,
against 1.5 ms for a run with none, which is why nothing after the boot overlap was worth touching.

The instruction gate needs `perf` and exits 1 when a row leaves its band, 2 when a row cannot be
measured at all. It is not in `make check` because a shared runner may have performance counters
switched off, where a blocking gate fails for a reason that has nothing to do with the code.
