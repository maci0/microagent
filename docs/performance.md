# Performance

What this harness costs, what dominates it, and which levers were pulled and which were not.

Every number here is a counter, not a clock, unless it says otherwise. Retired instructions repeat
to within 0.001% for a fixed binary and a fixed input. Wall clock moves with frequency scaling, the
CPU quota and whatever else the machine is doing, so a wall-clock gate fails on a busy runner for
reasons unrelated to the code. `bench/instructions.sh --check` is the gate that enforces this, and
[CONTRIBUTING.md](../CONTRIBUTING.md#the-instruction-gate) says when to run it.

## The short version

The harness is not the bottleneck. A run is 47 s to 720 s, and the harness's own share is under 1%
per turn: about 83,000 instructions before the first byte reaches the provider, and about 4,160 instructions
per streamed frame. The model and the tool subprocesses are the run.

So the levers worth pulling are not in the CPU. They are in the bytes on the wire, in what the run
waits for, and in what it holds resident, none of which a profiler or an instruction counter shows.

What it holds resident is the headline: 0.6 MB at `--version`, 0.9 MB up to the first request,
1.6 MB after 50,000 streamed frames, on the build that ships. The other agent CLIs hold 25 MB to
326 MB at `--version`; the table, the method and the three build modes are in
[docs/benchmark.md](benchmark.md#memory-footprint). The release build is `ReleaseSmall` because it
holds the least of the three release modes. The CPU rows below are measured on `ReleaseFast`, where
the counters are stable; `ReleaseSmall` retires about 1.3 times as many, which is why the
gate names the mode it counts in.

## Where the work goes

Measured with `perf stat -e instructions`, median of three, net of a baseline binary. The
per-frame, compaction, body and ranged-read rows are the ones `bench/instructions.baseline` gates,
so a row here that moves is a gate that moved with it:

| path | instructions | per unit |
| --- | --- | --- |
| process start, arg parse (`--version`) | 33,030 | n/a |
| everything before the first request is sent | 82,786 | n/a |
| a streamed content frame (47 B) | n/a | 4,160 |
| a streamed tool-argument frame | n/a | 9,253 |
| compaction of a 1 MB conversation | 31,049,215 | one call |
| building the request body (the row measures 40 of them) | 123,841 | 3,096 |
| a ranged read of a 512 KB line | 7,521,158 | one call |
| the session log's share of a run (ReleaseFast) | 332,061 | once per run |
| one more turn of the loop (ReleaseFast) | 47,552 | a tool call that runs nothing |

Against a 284 s review and roughly 20,000 frames, the streaming path is on the order of ten
milliseconds of CPU in total. Changing it is not worth the risk.

Syscalls, which no instruction count carries: 17 for `--version`, 109 for the whole pre-request
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
| the constant half of the request, rebuilt per turn | once per turn | **once per run** | `bodyPrefix` is a pure function of `opts`, and nothing in the loop changes any of it, so every turn walked the tool schema again and copied every MCP tool's `inputSchema` into a fresh turn-arena buffer |
| a repeated call `id` and `name` in a stream | a `dupe` and a `free` per frame | **once per call** | providers repeat both on every argument fragment, so each frame allocated and released two strings that had not moved; the skip is the rule `recordServed` already follows for `model` |
| streamed frame parse | 7,204 instr | **4,101 instr** | declared shapes instead of a `std.json.Value` tree, with the generic parse kept behind them |
| ranged read of a long line | quadratic | **linear** | each 8 KB read copied the whole accumulated buffer onto itself; the self-copy, not the re-scan, was the cost (see below) |
| a retry wait past the budget | up to 6 min asleep | **refused** | `--budget` was defeated by the `Retry-After` path |
| turn arena after a ceiling-sized response | 48 MB resident | **4 MB** | the reset retained without bound |
| MCP server startup, 3 servers | 1.513 s | **0.506 s** | every server is spawned before any is asked to initialize, so their boots overlap: the run waits for the slowest server instead of the sum |
| a 200 x 100 KB skill library | 24.3 MB resident | **4.6 MB** | the listing read every `SKILL.md` whole and kept the text in the run arena, because the name and description it lists are slices of it; it reads the head of the file now, and a `skill` call reads the body |
| the same library, system time to the first request | 9.3 ms | **2.0 ms** | the same change: 21 MB of reads become about 1.6 MB, and kernel time is the half that carries it |
| three MCP servers with 1 MB `tools/list` answers | 12.2 MB resident | **4.5 MB** | a `tools/list` answer was parsed into the run arena, tree and line both, and the buffer it arrived in kept its size; the answer is parsed in a scratch arena now, only the schema bytes are copied out, and that buffer has its own allocator and is handed back |
| one such server | 8.5 MB | **4.5 MB** | the same change |
| worker stacks, a 300-turn run | 36.7 MB address space | **6.7 MB** | std gives each `Io.Threaded` worker a 16 MB stack and allows one per core; this program's batches hold one or two operations, so it asks for sixteen workers of a megabyte -- the fan-out row below is why it is not four, and a 300-turn run at sixteen measures 19.8 MB of `VmPeak` against 16.9 MB at four |
| the same, a 3000-turn run | 91.8 MB address space | **46.8 MB** | the rest is the conversation and the arenas; peak resident on that run fell from 10.9 MB to 9.5 MB |
| a 3000-turn run's client CPU | 211.9 M instr | **177.8 M instr** | `sendBodyComplete` needs the whole body in one buffer, so the conversation was copied into a fresh one every turn; the prefix and the conversation now go to the wire from where they are |
| the same run, peak resident | 13.3 MB | **11.0 MB** | with the body buffer gone, the turn arena crosses its retention ceiling less often |
| an MCP answer read in 8 KB chunks, three servers of 1 MB each | 91.1 M instr | **75.3 M instr** | the newline scan restarted at the front of the buffer on every chunk, so a one megabyte line was searched 128 times over growing prefixes, about 66 MB of the same bytes; it resumes where it stopped now |
| one compaction's closing byte | a 400 KB copy | **appended in place** | the conversation was copied whole to add the `]` `std.json` needs for a complete document, once per compaction; the byte is appended to the buffer and taken back before the rewrite |
| mappings at startup (`--version`) | 86 mmap | **19** | std's start-code allocator maps a 64 KB slab per size class on first use; the run builds its own around a bucket allocator instead. It costs about 1.2% of client instructions on a 3000-turn run, which is the price of the 67 mappings it saves |
| three 4 MB MCP tool results | 19.1 MB resident | **12.8 MB** | the text was built whole and clamped to 24 KB a moment later, so the copy and the clamp both worked over bytes nobody keeps; it stops at the cap while it is built, and the note names the size it would have had |
| a 5,000-frame stream's client CPU | 29.0 M instr | **28.0 M instr** | `std.json.parseFromSlice` wrapped every frame in an arena of its own, on top of the per-frame scratch the caller already resets; `parseFromSliceLeaky` parses into that scratch directly |
| per-thread signal stack | 256 KB zeroed in every thread | **none** | std gives each thread a 256 KB `.tbss` signal stack for its segfault handler whether or not the handler is on, and a release build has it off; the zeroing was 360,541 of 368,781 instructions in `--version` and one more copy per `Io.Threaded` worker |
| `--version` | 477,472 instr | **33,030 instr** | the signal stack above, then the environment map and the string scan below |
| everything before the first request | 1,329,995 instr | **82,786 instr** | the same changes, plus the two below |
| peak resident, a run that never connects | 2,164 kB | **1,304 kB** | the signal stack: each thread touched 256 KB of it |
| syscalls, `--version` | 67 | **17** | the signal stack's `mmap` and `munmap` pairs per thread, and the worker threads' start-up |
| the environment map | two copies, ~100 allocations each, freed at exit | **no copy** | `createMap` regrew its table and allocated twice per variable, and the tool environment was a second copy less the credentials; the map's keys and values are now slices of the process's own environment block, which outlives it, and the credentials are removed from it in place after the key is read. The arena's `free` ignores memory it did not hand out, so nothing frees them |
| the environment's string lengths | a byte loop, 18,408 instr (`ReleaseSmall`) | **a word at a time, 11,800 fewer instr in `--version`** | `std.mem.len` is a byte loop in a `ReleaseSmall` build and the environment is about 8 KB; an aligned word never crosses a page, so the scan reads the word that holds the terminator |
| `--version`, shipped build | 154,657 instr | **43,156 instr** | the two rows above, plus skipping `Map.putMove`'s key validation, which is evaluated even with asserts off (30,000 instr) |
| resident memory while waiting on a model, HTTPS | 1,530 kB (handshake stack stays dirty) | **1,324 kB** | the handshake dirties about 200 kB of stack for milliseconds; `madvise(DONTNEED)` on the `[stack]` mapping below the caller's frame gives it back, and does nothing on any other thread or mapping |
| a full run's copies, shipped build | 92,000 of 255,644 instr in `memcpy` | **8,000 of 171,991** | Zig's compiler runtime copies a byte at a time in `ReleaseSmall`, about four instructions a byte, and the request body goes through several writers; `src/copy.zig` is a word-at-a-time `memcpy`, built with `-fno-builtin` so LLVM cannot turn its loop back into a call to itself, and linked only where the runtime's is the slow one |
| the stream's error check, shipped build | 54.3 M instr for 5,000 frames | **37.8 M** | `std.mem.indexOf` for `"error":` made a call per position, 128,042 calls in a 3,000-frame stream; the needle is one machine word, so each position is a load and a compare. `ReleaseFast` inlined the call and does not change (26.9 M) |
| the stock system prompt | escaped per run (about 12 instr per byte) | **escaped at compile time** | a run with no reply style and no skills sends the same 3 KB every time |
| a JSON string's plain runs | one table lookup per byte | **a word at a time** | after a plain byte, eight bytes are tested at once; compaction of a 1 MB conversation fell 37.2 M to 31.0 M instr, and the byte loop is unchanged for text that is mostly escapes or non-ASCII |
| the sandbox path check | a `realpath` of `.` per `write` and `edit` | **none** | the working directory is `writable_roots[0]`, taken at startup; a `realpath` is an `openat`, a `readlink` and a `close` |
| a connection to a host with several addresses, all four presets on | 4,607 ms before the first request | **2,820 ms** | `std.net.HostName.connect` dials every address a name resolves to as its own async task and keeps the first, and `Io.Threaded` runs a task inline when every async slot is busy -- four slots for four handshakes and their fan-out, so a connection cost the sum of the host's addresses instead of the fastest and the handshakes queued behind each other. Sixteen slots is the measured knee; the wait is per connection and a run opens several |
| the four presets at run start, all four on | 2,820 ms before the first request | **0.6 ms** | none of them is handshaken: their tools and schemas are in this binary, so the model sees them with no request, and the first call to one of their tools is what connects. The row above still governs that call, and every keyed preset, `url` server and provider connection |
| the session store walked per run | two full walks and two sorts | **one walk, one sort** | `session.open` pruned before creating the log and again after, so every run start listed, copied and sorted the whole store twice over a directory of up to 200 names. Pruning once with the run's own log already in place settles on the same size, and it runs on the path where no log could be opened as well, which is the case the pre-open prune was for |

Four of the rows above are one body of work on one run, and they compound. Between `v0.4.0` and the
tree that carries them, client instructions for 3000 turns of the always-calls-a-tool loop fall from
211.2 M to 177.2 M (16%), peak resident from 12.2 MB to 9.8 MB, and peak address space from 110.4 MB
to 46.8 MB. At 100 turns the same changes are inside the noise, which is the shape to expect: they
pay for the conversation's size and the runtime's defaults, not for a turn.

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
- **A stack buffer in front of the per-frame arena.** 1.5% fewer instructions on a 5,000-frame
  stream once the frame parse was leaky, and CPU time inside the noise, for another allocator on
  the one path carrying the model's output. Measured again on a 20,000-frame stream with an 8 KB
  `std.heap.stackFallback` in front of the arena: 1.8% (107.9 M against 109.9 M), so it stays out.
- **A vectorized `reportsError`.** `std.mem.indexOf` for `"error":` is a byte loop and shows as a
  quarter of `streamChat`'s own time in `perf`, so it was rewritten to hop between quotes with
  `indexOfScalarPos`. On a 20,000-frame stream in ReleaseFast it cost 4.5% more instructions
  (114.7 M against 109.8 M): a 47-byte frame holds about ten quotes, and ten hops cost more than
  one short scan.
- **ReleaseFast release assets.** ReleaseSmall retires 1.3 times the instructions of ReleaseFast
  (43,156 against 33,030 for `--version`, 37.8 M against 27.0 M for a 5,000-frame stream), and it
  holds 28% to 41% less resident memory: 540 kB against 788 kB at `--version`, 764 kB against 1,244 kB
  up to the first request, 1,300 kB against 1,812 kB after 50,000 frames. Startup CPU time is 0.13 ms
  against 0.23 ms, because it pages in half the binary. Memory is the headline, and the cycles it
  gives up are under 1% of a turn, so the release assets, `make` and `make musl` build ReleaseSmall.
  ReleaseSafe holds two to three times ReleaseSmall's. Before the fixes above the shipped build
  retired twice ReleaseFast's instructions.
- **Skipping the system CA store rescan.** With no `--ca-bundle`, the HTTP client parses every
  certificate in the system store before the first https request: 121 certificates, 5.9 M
  instructions and 0.7 ms of CPU on this machine, once per run and with no peak-memory cost. There
  is no cheaper source of the same trust decision.

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
| wire bytes | no instruction is spent on them | 4.3 KB of tool schema re-read every turn |
| waiting | the cost is sleep | a 429 sat the run out for six minutes inside `--budget`, and three MCP servers were handshaken one at a time, so a run paid their boot times in series |
| resident memory | instruction counts do not carry it | 48 MB retained after one large response |
| fallback paths | the primary path works | `date +%s` standing in for a monotonic clock |

Each was found by asking what a counter would not see, or by reading a feature end to end rather
than profiling it.

## Open, and deliberately

`conversation_soft_limit` is the one knob left that moves a run's wall time. Its uncached cost does
not depend on the limit: compaction fires once per half-limit of growth and discards a prompt of
about the limit, so the product is the conversation's growth and the limit cancels. Deciding it
needs a live provider, and it is the only thing here that does.

### Compaction is the CPU when tool results are large

The sentence that used to sit here, that compaction is inert at benchmark scale and binds only on
long runs, is true of the benchmark's conversations (72 to 143 KB against a 400 KB limit) and false
of a run whose tool results are near the 24 KB ceiling. A loop that calls `read` on a 200 KB file
every turn, whose result is clamped to 24 KB, costs about 1.7 M client instructions per turn; the
same loop with a 5 KB result costs 315 k. The difference is not the tool. The profile of the first
loop puts 16% of its cycles in `json.Scanner.next`, nearly all of it under `compactMessages`, and a
large share of the arena allocation beside it: each turn adds 24 KB, crosses the 400 KB limit, and
pays for a scan of the whole conversation to elide a few results.

Two fixes are measured and not taken.

- **Throttling it, or raising the limit, trades CPU for prompt tokens.** A slack of a quarter of the
  limit would cut the compactions about fivefold and add up to 100 KB of uncached prompt to every
  turn between them, roughly 25 k tokens a turn. That is money and latency on the wire; the CPU it
  saves is about half a millisecond a turn. This file's whole ordering says the wire comes first,
  and the trade goes the other way.
- **A byte-level rewrite was refused here before**, because it hands the exact bytes the prompt
  cache depends on to a hand-written scanner. The safer shape of the same idea was sized and is
  also not taken: `finishTurn` knows where each tool result's content value starts and ends as it
  writes it, so those byte ranges could be recorded and markers spliced into them without parsing
  the conversation at all. It removes the scan, but it means a second elision path that has to
  reproduce `elideToolResults`' two thresholds, its target and its floor exactly, on the one path
  where a mistake corrupts every request after it. What it buys is about a third of a millisecond a
  turn in the worst case, less than 0.1% of a run measured in minutes. That is under this file's
  bar, which already refuses a change worth ten milliseconds. The design is written down here for a
  run whose shape shows it matters, not built on the chance that one does.

One thing was taken from this path anyway, and it is small and changes no behavior: the closing `]`
the parser needs is appended to the conversation in place and taken back afterwards, rather than the
whole conversation being copied to add one byte. That is 532.7 M instructions to 530.8 M on the
300-turn loop above.

## Are these fixes still guarded?

A fix with no guard gets undone by the next refactor without anyone noticing. Each row below was
re-checked on this tree. The third column is the result of *defeating the fix* and confirming the
guard fails, not merely that the guard exists.

| fix | guard | defeated? |
| --- | --- | --- |
| constant request fields ahead of `messages` | `one request body is the previous one`, `the tool schema sits inside the cacheable prefix` | 5 tests fail |
| the request prefix built once per run | none; the fix is structural, the prefix is a `run` local rather than a per-turn `bodyPrefix` call | not defeated: `runTurn` takes the prefix as an argument, so putting the call back is a signature change rather than a silent regression |
| an unchanged call `id` and `name` not recopied | `a repeated call id and name are copied once, not once a fragment` | defeated: the arena grows by the per-frame copies and the bound fails |
| declared frame shapes | `bench/instructions.sh --check`, `stream content frame` row | 4,101 to 7,431, exit 1 |
| ranged-read cursor and self-copy | `bench/instructions.sh --check`, `ranged read` row | 7,543,604 to 47,965,253, exit 1 |
| retry waits inside the budget | `a wait the budget cannot cover` | present |
| bounded turn-arena retention | `a turn that outgrows the retained size` | present |
| session pruning by path | `a log in a subdirectory is pruned` | present |
| the session store walked once per run | `a run's own log is counted by the retention window, not left past it` | not defeated: both orderings end on the window, so the guard holds the size rather than the count of walks |
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

The allocator row is `strace -f -e trace=mmap -c` on `--version` against the same tree built around
std's own start-code allocator, which is the only way to separate it from the other changes: the two
builds differ in that one thing, and the CPU figure is the same 3000-turn loop measured on both.

The worker-stack rows are peak `VmPeak` and `VmHWM` from `/proc/<pid>/status`, sampled every 10 ms
through a run against the always-calls-a-tool stub at 300 and 3000 turns. The smaller stacks were
stress-checked against the three servers of 1 MB `tools/list` answers, a server answering
`tools/call` with 4 MB, and the whole suite, none of which faults: the work a worker does is a read
or a write for a batch that holds one or two operations.

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

The fan-out row is a product measurement, `hyperfine -N -w 1 -r 20` over one stub run
(`bench/stub_provider.py` on loopback, 20 frames, `--max-turns 1`) with a config that names all four
presets, so all four are handshaken before the first request: median 4,607 ms at four async slots and
2,820 ms at sixteen, and 1 ms either way with `enabled = false` on all four. The four presets are
not four equal parts. One at a time, `mcp.context7.com` answers in 2.8 s and `mcp.deepwiki.com`,
which resolves to five addresses at 0.16 s a connect, takes 4,368 ms at four slots against
1,899 ms at sixteen; `mcp.grep.app` (1.1 s) and `mcp.exa.ai` (0.8 s) do not move. The three
presets that predate `deepwiki` are already at 2.8 s at four slots -- the row above about connecting
them concurrently is what bought that -- so what the fourth preset exposed is contention: four
handshakes, each wanting its own address fan-out, against four slots. `strace -f -e connect` on the
two binaries is the mechanism in one picture: five `connect` calls one after another on one thread
at four, and five on five threads that all finish within 0.0002 s of each other at sixteen. The
memory side is `/proc/<pid>/status` sampled in a loop through a 300-turn run: `VmPeak` 16.9 MB
against 19.8 MB and `VmHWM` 3.4 MB against 3.9 MB, and `bench/maxrss.py --version` unchanged at
788 kB, because a worker exists only while an operation is on it. There is no counter row for this
one: the cost is a wait, which no instruction count carries, so the guard is a test that fails if
the limit drops under the measured knee.

The preset row is the same command and stub, the four presets on, after they stopped being
handshaken at start: median 0.6 ms over fifteen runs (0.7 ms with every preset disabled, so the
table itself costs nothing at start). That is the whole of the run's wait before its provider
request on this machine. A `tools/call` to a preset is where its connection is opened, and that
call pays the fan-out row above.

The instruction gate needs `perf` and exits 1 when a row leaves its band, 2 when a row cannot be
measured. It is not in `make check` because a shared runner may have performance counters switched
off, where a blocking gate fails for a reason unrelated to the code.
