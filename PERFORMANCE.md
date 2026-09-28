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
| a ranged read of a 512 KB line | 7,543,588 | one call |

Against a 284 s review and roughly 20,000 frames, the streaming path is on the order of ten
milliseconds of CPU in total. Changing it is not worth risk.

Syscalls, which no instruction count carries: 180 for `--version`, 277 for the whole pre-request
path, and nothing per turn beyond one session-log write and one stdout write per chunk.

## What was changed, and what it bought

| | before | after | why |
| --- | --- | --- | --- |
| un-cacheable request bytes | 3,775 B/turn | **2 B/turn** | the tool schemas were written after `messages`, so they fell outside the cacheable prefix every turn |
| streamed frame parse | 7,204 instr | **4,101 instr** | declared shapes instead of a `std.json.Value` tree, with the generic parse kept behind them |
| ranged read of a long line | quadratic | **linear** | each 8 KB read re-searched and re-copied the whole accumulated buffer |
| a retry wait past the budget | up to 6 min asleep | **refused** | `--budget` was defeated by the `Retry-After` path |
| turn arena after a ceiling-sized response | 48 MB resident | **4 MB** | the reset retained without bound |

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

The escaper tests that came out of the second attempt were kept, because they cover a real edge:
the escaper takes a byte's width from its lead byte, and an escapable byte or a multi-byte character
landing at an arbitrary offset is a body that stops being valid JSON when it is wrong.

## Four classes a profiler cannot see

The defects that were worth finding were none of them CPU. They are worth listing because the
categories generalise past this repository:

| class | why a profiler misses it | example |
| --- | --- | --- |
| wire bytes | no instruction is spent on them | 3.8 KB of tool schema re-read every turn |
| waiting | the cost is sleep | a 429 sat the run out for six minutes inside `--budget` |
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

## Reproducing any of this

```sh
make instructions CHECK=--check     # the table above, gated
make overhead                       # startup and first-request cost per harness
zig build test -Dtest-filter="a long run keeps the conversation bounded"
```

The instruction gate needs `perf` and exits 1 when a row leaves its band, 2 when a row cannot be
measured at all. It is not in `make check` because a shared runner may have performance counters
switched off, where a blocking gate fails for a reason that has nothing to do with the code.
