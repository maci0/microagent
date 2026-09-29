# To do

What is not built yet, why, and what would settle it. An item that ships moves out of this file and
into the [CHANGELOG](../CHANGELOG.md); an item that is decided against moves to
[Deliberately absent](../README.md#status) with its reason.

## To evaluate

Each of these is a maybe. The decision is made from the failed tasks in the benchmark runs, not
before: build one only if the trajectories show the problem it solves.

- **A sub-agent for exploration.** A read-only nested loop that reads and searches in a fresh context
  and returns only a summary, so the main conversation stays small. It could matter most on DeepSWE's
  long-horizon tasks, where the model reads a great deal of code before it changes anything, and it is
  the largest build here: a nested loop, its own budget and turn limit, and a guarantee that it cannot
  write. Build it if trajectories show the context filling with exploration that the summary would
  have replaced.
- **Language-server diagnostics and definitions.** Compiler errors and go-to-definition without
  searching for them, which is stronger than `search` on typed languages. It needs a language server
  per language and a lifecycle for each, and `semcode` reached through `bash` already covers part of
  it for C, C++ and Rust. Build it if trajectories show turns spent finding a symbol that a
  definition lookup would have returned in one.
