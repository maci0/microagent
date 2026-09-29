# Performance

What this harness costs, what dominates it, and which levers were pulled and which were not.

Every number here is a counter, not a clock, unless it says otherwise. Retired instructions repeat
to within 0.001% for a fixed binary and a fixed input. Wall clock moves with frequency scaling, the
CPU quota and whatever else the machine is doing, so a wall-clock gate fails on a busy runner for
reasons unrelated to the code. `bench/instructions.sh --check` is the gate that enforces this, and
[CONTRIBUTING.md](../CONTRIBUTING.md#the-instruction-gate) says when to run it.

## The short version

The harness is not the bottleneck. A run is 47 s to 720 s, and the harness's own share is under 1%
per turn: 1.3 ms of CPU before the first byte reaches the provider, and about 4,100 instructions
per streamed frame. The model and the tool subprocesses are the run.

So the levers worth pulling are not in the CPU. They are in the bytes on the wire, in what the run
waits for, and in what it holds resident, none of which a profiler or an instruction counter shows.

## Where the work goes

Measured with `perf stat -e instructions`, median of three, net of a baseline binary. The
per-frame, compaction, body and ranged-read rows are the ones `bench/instructions.baseline` gates,
so a row here that moves is a gate that moved with it:

| path | instructions | per unit |
| --- | --- | --- |
| process start, arg parse (`--version`) | 476,025 | n/a |
| everything before the first request is sent | 1,303,779 | n/a |
| a streamed content frame (47 B) | n/a | 4,101 |
| a streamed tool-argument frame | n/a | 9,253 |
| compaction of a 1 MB conversation | 37,153,055 | one call |
| building the request body (the row measures 40 of them) | 113,946 | 2,849 |
| a ranged read of a 512 KB line | 7,543,604 | one call |
| the session log's share of a run (ReleaseFast) | 332,061 | once per run |
| one more turn of the loop (ReleaseFast) | 47,552 | a tool call that runs nothing |

Against a 284 s review and roughly 20,000 frames, the streaming path is on the order of ten
milliseconds of CPU in total. Changing it is not worth the risk.

Syscalls, which no instruction count carries: 180 for `--version`, 277 for the whole pre-request
path, and nothing per turn beyond one session-log write and one stdout write per chunk.

The turn and session rows use the same method (`perf stat -e instructions`, median of three,
against a stub provider on loopback that always asks for a tool that does not exist) but on the
shipped `-Doptimize=ReleaseFast` binary, not the Debug test binary the frame, compaction and
ranged-read rows come from. Debug's checked arithmetic and debug allocator make these two about
four times larger (194,762 and 1,290,450), so the two sets are not comparable and the Debug figures
are not what a release build pays. The turn row is `--max-turns 101` minus `--max-turns 1`, divided
over the hundred turns between them. The session row is a one-turn run with and without
`MICROAGENT_SESSION_DIR=`.

A thousand turns on the same binary is 53.1 M instructions, 427 ms of wall (mostly the stub, which
is Python), and peak RSS flat at 12.6 MB. The marginal turn barely moves as the conversation grows:
47,552 instructions between the first and hundredth turn, 51,479 between the hundredth and
thousandth. The re-sent conversation therefore costs about 4 k instructions a turn more at 200 KB
than at 2 KB. That copy is the same bytes the provider bills for on every turn; a chunked send would
save our copy and leave the bill, so it stays. The loop does not open a connection per turn either:
ten turns against a keep-alive stub opened one TCP connection, because the client's pool returns the
socket after each response is read.

## The toolchain

The project pins Zig 0.16.0, the newest stable release: [the download
index](https://ziglang.org/download/index.json) lists no 0.16.1, and `master` is 0.17.0-dev, which
is not a release to build a release asset with. There is no compiler upgrade to take for
performance until 0.17 ships. Measured here, `-mcpu=native` moves the hot paths by less than the
run-to-run noise, so there is no build flag to reach for either.

## What was changed, and what it bought

| | before | after | why |
| --- | --- | --- | --- |
| un-cacheable request bytes | 3,775 B/turn | **2 B/turn** | the tool schemas were written after `messages`, so they fell outside the cacheable prefix every turn |
| streamed frame parse | 7,204 instr | **4,101 instr** | declared shapes instead of a `std.json.Value` tree, with the generic parse kept behind them |
| ranged read of a long line | quadratic | **linear** | each 8 KB read copied the whole accumulated buffer onto itself; the self-copy, not the re-scan, was the cost (see below) |
| a retry wait past the budget | up to 6 min asleep | **refused** | `--budget` was defeated by the `Retry-After` path |
| turn arena after a ceiling-sized response | 48 MB resident | **4 MB** | the reset retained without bound |
| MCP server startup, 3 servers | 1.513 s | **0.506 s** | every server is spawned before any is asked to initialize, so their boots overlap: the run waits for the slowest server instead of the sum |
| a 200 x 100 KB skill library | 24.3 MB resident | **4.6 MB** | the listing read every `SKILL.md` whole and kept the text in the run arena, because the name and description it lists are slices of it; it reads the head of the file now, and a `skill` call reads the body |
| the same library, system time to the first request | 9.3 ms | **2.0 ms** | the same change: 21 MB of reads become about 1.6 MB, and kernel time is the half that carries it |
| three MCP servers with 1 MB `tools/list` answers | 12.2 MB resident | **4.5 MB** | a `tools/list` answer was parsed into the run arena, tree and line both, and the buffer it arrived in kept its size; the answer is parsed in a scratch arena now, only the schema bytes are copied out, and that buffer has its own allocator and is handed back |
| one such server | 8.5 MB | **4.5 MB** | the same change |
| a 3000-turn run's client CPU | 211.9 M instr | **177.8 M instr** | `sendBodyComplete` needs the whole body in one buffer, so the conversation was copied into a fresh one every turn; the prefix and the conversation now go to the wire from where they are |
| the same run, peak resident | 13.3 MB | **11.0 MB** | with the body buffer gone, the turn arena crosses its retention ceiling less often |
| an MCP answer read in 8 KB chunks, three servers of 1 MB each | 91.1 M instr | **75.3 M instr** | the newline scan restarted at the front of the buffer on every chunk, so a one megabyte line was searched 128 times over growing prefixes, about 66 MB of the same bytes; it resumes where it stopped now |
| three 4 MB MCP tool results | 19.1 MB resident | **12.8 MB** | the text was built whole and clamped to 24 KB a moment later, so the copy and the clamp both worked over bytes nobody keeps; it stops at the cap while it is built, and the note names the size it would have had |

The two largest wins are not CPU at all. The request-bytes fix is the most valuable change in this
file, and every counter the harness prints misses it: `cached_tokens` reports what was reused, never
what was not.

## What was tried and not kept

Kept out on the numbers, not on taste:

- **A hand-rolled SSE scanner.** 8.8x fewer instructions than the declared-shape parse, saving
  about 0.56 us a frame. Against a 284 s run that is 0.005% of wall clock, in exchange for 120 lines
  of hand-written JSON scanning on the one path carrying the model's own output.
- **A word-at-a-time escape scan.** 0.4% on a 1 MB write, because the copy into the writer is the
  cost and the scan never was.
- **Parallel tool calls.** `rg` costs 6.1 ms and `git log` 1.7 ms on this repository, so a
  parallel batch saves about 5 ms, and the tools that are actually slow are the ones unsafe to run
  concurrently.
- **A byte-level compaction rewrite.** Compaction is 4.7 ms per megabyte, about 0.02% of a run, and
  the replacement would hand-rewrite the exact bytes the prompt cache depends on.
The escaper tests written for the word-at-a-time attempt were kept, because they cover a real edge:
the escaper takes a byte's width from its lead byte, and an escapable byte or a multi-byte character
landing at an arbitrary offset produces invalid JSON when that is wrong.

### Which half of that quadratic mattered

The ranged read did a full re-scan and a full self-copy per read. Defeating one half at a time and
running the gate shows which one was quadratic:

| defeated | gate row | result |
| --- | --- | --- |
| the search cursor | 7,515,139 | **inside the band**, 0.4% |
| the self-copy guard | 47,965,253 | **6.4x, reported, exit 1** |

The copy was the quadratic; the re-scan was not. The cursor is still worth keeping: it removes a
real second pass, and with the copy gone the scan is O(n) rather than O(n^2). But it was never the
expensive half.

The same check proves the gate row is not decorative: the fix it guards cannot be reverted without
the row failing.

## Four classes a profiler cannot see

None of the defects worth finding were CPU. The categories generalize past this repository:

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
benchmark scale (the stride sample's conversations average 72 to 143 KB against a 400 KB limit, so
it never fires) and binds only on long runs. Its uncached cost does not depend on the limit:
compaction fires once per half-limit of growth and discards a prompt of about the limit, so the
product is the conversation's growth and the limit cancels. Deciding it needs a live provider, and
it is the only thing here that does.

## Are these fixes still guarded?

A fix with no guard gets undone by the next refactor without anyone noticing. Each row below was
re-checked on this tree. The third column is the result of *defeating the fix* and confirming the
guard fails, not merely that the guard exists.

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
| a large skill listed from its head | `a large skill is listed from its head, and loads whole` | defeated: the run arena holds the file, and the 64 KB bound fails by 3x |
| a `tools/list` answer parsed in a scratch arena | `a tools/list answer is parsed in a scratch arena and its buffer is handed back` | defeated: run arena 3.4 MB against a 1 MB bound, pending capacity one answer's size |
| an MCP result built up to the cap | `a tools/call answer is built up to the result cap, not whole` | defeated: the whole answer is built, and the 512 KB bound on the run arena fails |

Re-checking one takes a minute and is worth doing after any refactor that touches a test file,
because guards move. Tell three outcomes apart; confusing the first two reports a broken guard as a
sound one:

1. the build **failed**: nothing ran, so nothing was proven either way;
2. the test ran and **passed**;
3. the test ran and **failed**: the guard fired.

Only the third proves anything, and a check that greps for a failure string reports 1 and 2
identically.

**A guard that disappears is not automatically lost coverage.** Two escaper tests were removed by a
refactor because a fuzzer over arbitrary byte strings replaced them, and it covers the fixed cases
they did. Putting them back would duplicate a better check. Find what replaced a guard before
rebuilding it.

## Reproducing any of this

```sh
make instructions CHECK=--check     # the table above, gated
make overhead                       # startup and first-request cost per harness
zig build test -Dtest-filter="a long run keeps the conversation bounded"
```

The MCP startup row is a wall-clock figure, measured like a product number: `hyperfine -w 2 -r 10`
against a stub provider on loopback and three servers whose command sleeps 0.5 s before answering.
Mean 1.513 s before, 0.506 s after, and 0.505 s for six servers after the change, which is the
point: the run waits for the slowest boot, not the sum. Its guard is a test, not a clock: the waiter
server refuses to answer until the starter server has run, so a sequential connect drops it and the
test sees one server where it expects two. Where `/bin/sh` has no fractional `sleep`, the waiter's
bounded wait spins instead of sleeping; the guard still works and gives up sooner.

The skill rows are measured with `MICROAGENT_SKILLS` pointed at a directory of generated `SKILL.md`
files, the same directory before and after the change. The resident figures are peak `VmHWM` from
`/proc/<pid>/status`, sampled every 20 ms through a 400-turn run against the stub. That is the only
method that agreed with `smaps`: `getrusage`'s `ru_maxrss` answered 10.8 MB for a 5 KB hello-world on
this machine, the same figure it gave the harness, so it is not usable for small processes here. The
wall figure is `hyperfine -w 3 -r 20` and it moves with the page cache (11.1 ms against 10.9 ms per
run warm, 27.2 against 12.9 loaded and cold); the system time does not, 9.3 ms against 2.0 ms, which
is the read volume. A library of ordinary size pays nothing either way: 2.9 MB against 2.9 MB with
none, 5.5 against 5.9 for 200 skills of 4 KB.

The request-body rows are `perf stat --no-inherit -e instructions`, median of three, at
`--max-turns 3000` against a stub that always calls a tool that does not exist, so the conversation
grows to the compaction plateau and the per-turn copy is at its largest. They were kept on the
strength of the bytes as much as the numbers: a stub that writes each request body to a file was run
for a five-turn turn with the old and the new binary, and all five bodies were identical, byte for
byte. The same test is what a provider's prompt cache sees, so it is the gate for a change to the
send path even though it is a shell comparison rather than a test in the suite.

The MCP line row is `perf stat -e instructions`, median of three, on the release binary against three
fake servers whose `tools/list` answer carries 1 MB, with `--max-turns 1`. It is measured with
`--no-inherit`, and that flag is the whole of the method: without it the same run reads 567 M
instructions, because `perf stat` counts the servers too and a shell script padding a megabyte with
`printf` costs far more than the client that reads it. Any row here whose workload spawns something
needs the flag. No gated row was added for this one: `bench/instructions.sh` drives its rows through
`--test-filter`, which does not reach tests declared in an imported module, so the number is recorded
here with the command that produces it rather than in `bench/instructions.baseline`.

The MCP result row is a fake server that answers `tools/call` with a 4 MB text block, three calls in
one run, peak `VmHWM` sampled the same way: the median of three runs is 19.1 MB before and 12.8 MB
after. What stays is the answer's line and the values parsed from it, which is what reading a 4 MB
document costs; what went is the second copy of its text. The cap leaves 128 bytes under the ceiling
for the note, so the note survives the caller's own clamp and the prefix is that much shorter than
the 24 KB a whole-file clamp would have kept.

The MCP rows are the same shape: a fake server whose `tools/list` carries 1 MB of padding in its
`inputSchema`, one and three servers, peak `VmHWM` sampled the same way. One server went from 8.5 MB
to 4.5 MB and three from 12.2 MB to 4.5 MB, because three schemas stay resident (the request carries
them) while the parsed answer no longer does. `hyperfine -w 3 -r 20` over an instant-answer server
put the whole MCP path (spawn, two round trips, and the reap at the end) at 0.7 ms for one server,
1.2 ms for three and 3.2 ms for ten, against 1.5 ms for a run with none, which is why nothing after
the boot overlap was worth touching.

The instruction gate needs `perf` and exits 1 when a row leaves its band, 2 when a row cannot be
measured. It is not in `make check` because a shared runner may have performance counters switched
off, where a blocking gate fails for a reason unrelated to the code.
