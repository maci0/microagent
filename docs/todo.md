# To do

These are candidates, not commitments. Build one only when failed benchmark
trajectories show the need. Move shipped work to the [changelog](../CHANGELOG.md);
record rejected proposals and their reasons under
[Deliberately absent](../README.md#status).

## To evaluate

- **Read-only exploration sub-agent.** Search and read in a separate context,
  returning a summary to keep the main conversation small. Evaluate when trajectories,
  especially long DeepSWE tasks, show exploration filling the context. It requires a
  nested loop with its own budget and turn limit, plus enforced write prevention.
- **Language-server diagnostics and definitions.** Get compiler diagnostics and
  definitions directly. Evaluate when trajectories spend turns searching for symbols
  a definition lookup would find at once. It requires a server and lifecycle per
  language; `semcode` through `bash` already covers part of this for C, C++ and Rust.
