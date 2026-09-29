# Changelog

All notable changes to microagent, in the order a consumer meets them. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project follows [SemVer](https://semver.org)
from `0.1.0`: under `0.y` the minor carries features and changes that alter a run's default behavior, the
patch carries fixes, and a patch never changes what an existing invocation does. The version lives in
`build.zig.zon`, and the README is the one place that repeats it, in the install snippet and the status
line; `make check-readme` refuses a bump that moves the former and leaves the latter behind, and both
`make check` and the push workflow run it. `microagent --version` prints it, and the release workflow
refuses to publish a tag that does not name it.

Only the latest release is supported. There is no backport window and no LTS line: a fix ships in the next
release, and `microagent update` moves you to it.

## [Unreleased]

### Added

- A first run with no config file writes the commented template to the default path,
  `~/.microagent/config.toml`, at mode 0600 and names the path on stderr. A path named by `--config`
  or `MICROAGENT_CONFIG` is never created, and an existing file is never touched.

### Changed

- The `web_search` preset's `web_search_exa` is described to the model without exa's
  `category:people` and `category:company` hints. Nothing in a run needs a profile index, and a query
  naming an individual puts that name in a third party's search log to answer a coding task. Both
  categories still work, so a task that asks for a profile search gets one.

### Fixed

- The harbor adapter's run logs, and the work trees and transcripts under `.scratch/` that
  `bench/run.sh` and `bench/gauntlet.sh` leave, are created at mode 0600 and 0700 rather than at the
  default 0666 less the umask, which on a shared host left a run's whole account of the tree it was
  pointed at readable by every other account.

## [0.7.0] - 2026-09-30

### Added

- `model`, `base_url` and `api_key` are config-file keys. Each is overridden by its environment
  variable and then by its flag, so a file states the house endpoint and a shell states the account.

### Changed

- A run that names no base url is refused before the first request, with the message naming the flag,
  the variable and the config key. There is no default provider: the endpoint decides whose account
  the tokens are billed to and the key goes there.

### Removed

- The `$HOME/.secrets/openrouter` key-file fallback. A key comes from `--api-key`,
  `MICROAGENT_API_KEY` or `api_key` in the config file.

## [0.6.0] - 2026-09-29

### Added

- `deepwiki` preset (`https://mcp.deepwiki.com/mcp`): `read_wiki_structure`, `read_wiki_contents`, `ask_wiki_question`.
- The four presets are on by default, with or without a config file. Their tools and schemas come from
  this binary, so a run with no key for one makes no request to it until the model calls one of its
  tools. `enabled = false` in `[tools.<name>]` turns one off.

- `[tools.<name>]` config tables switch the nine built-in tools on or off (`enabled = false` removes a tool
  from the schema and refuses its calls; an unknown tool name stops the run with exit 2) and enable three
  public remote MCP presets (`web_search`, `context7`, `grep_app`, off by default). `[[mcp]]` tables take
  a `url` for a remote streamable-HTTP server, with optional `api_key_env` (a variable name, never the key;
  scrubbed from tool subprocesses), `api_key_header` and `timeout`. When something is disabled the system
  prompt says which tools, in one line; with nothing disabled the request is byte-identical.
- `system_prompt_extra`: a top-level config string appended to the system prompt, up to 16 KB.
- `todo`: the model sends the whole step list of a long task, each item `pending`, `doing` or `done`, and
  gets it back numbered with a count. The latest result in the conversation is the current list, so the
  harness keeps no state. Up to 32 items, 200 bytes each. It costs 416 bytes of tool schema.
- `bench/maxrss.py` prints a command's peak resident memory, read from `/proc` at the moment the
  process exits (ptrace `PTRACE_O_TRACEEXIT`), and `bench/overhead.sh` gains a `peak_kb` column from it.
- `multi_edit`: several exact-string replacements, in one file or across files, in one call. Each is judged
  as `edit` judges it (ambiguous, no-op and re-matching replacements are refused) on the text the earlier
  ones left, and nothing is written unless every edit is accepted, so a refusal names the edit and changes
  nothing. Two spellings of one path share one file. Up to 64 edits per call. It costs 621 bytes of tool
  schema in the fixed part of every request. `docs/todo.md` lists what is planned or under evaluation next.
- macOS enforces the sandbox with a Seatbelt profile (`sandbox_init`): file writes are denied except under
  the writable roots, `$TMPDIR` and three device files, and `bash` and MCP servers inherit it, as they
  inherit Landlock on Linux. A run whose kernel cannot apply the sandbox, an older Linux or a Seatbelt
  refusal, now says so at startup, where `sandbox = true` used to read as protection it did not give.
  The roots are resolved through symlinks, which fixes the in-process check refusing an existing file
  under `/tmp` on macOS. The macOS build compiles and the profile text is tested; the enforcement itself
  has not been run on a Mac.
- `bench/harbor.sh polyglot` runs Aider polyglot (`aider/aider-polyglot`, 225 small exercises in six
  languages) on a fixed 21-task stride sample (`bench/polyglot-sample.txt`), the quick benchmark: a
  trial is minutes where a Terminal-Bench 4.0 task can take an hour. The reference solutions score 1.0
  on three sampled tasks under Harbor 0.23.0; no microagent score is recorded yet.
- `bench/harbor.sh tb4` and `bench/harbor.sh deepswe` run Terminal-Bench 4.0
  (`terminal-bench/terminal-bench@4.0.0`, 66 tasks) and DeepSWE (`datacurve/deep-swe-1-1`, 113 tasks) on
  Harbor, each on a fixed stride sample (`bench/tb4-sample.txt`, 22 tasks; `bench/deepswe-sample.txt`, 13
  tasks). The script prefixes the namespaced task ids, scales Terminal-Bench 4.0's 8 hour agent timeout
  to 3600 s for both harnesses, and lets the provider's host through for DeepSWE's no-network agent.
  `PROVIDER=deepseek` runs every arm against DeepSeek's own API (`deepseek-flash`), and a `kimi` arm runs
  Kimi Code beside microagent and opencode. No scores are recorded yet; `docs/benchmark.md` says what was
  checked.
- Command filter in configuration: `deny_commands = [...]` (or `[commands] deny = [...]`)
  in `config.toml` configures a list of command names or sequences to deny. Any `bash`
  command containing one of the denied commands (e.g. `sudo`, `/usr/bin/sudo`, `su`,
  `rm -rf`) is refused before execution, returning `refused: command contains '...', which is denied by configuration`.
- Configurable workspace sandbox: `[sandbox]` table (or top-level `sandbox = true`) in `config.toml`
  confines filesystem modifications to designated roots (by default: current working directory, `/tmp`,
  and session log directory; optionally customized with `writable = [...]`). On Linux (kernel 5.13+), applies
  Landlock LSM rules to restrict microagent and all spawned child processes (`bash`, MCP servers, build tools),
  marking `/` read-only and designated roots read-write. In-process canonical path verification additionally
  refuses `write` and `edit` tool calls targeting paths outside writable roots.

### Changed

The figures behind the changes below, with the method and the guard for each, are in
[docs/performance.md](docs/performance.md). This section keeps what changed and why.

- A preset with no key is no longer handshaken when the run starts. Its tool list and schemas are in
  this binary (`ask_wiki_question` and the other deepwiki tools were added to that table), so the model
  sees them with no request made; the first call to one of those tools is what connects and initializes,
  and a tool the server no longer offers is reported then. Time to the first request with the default
  config drops from about 2.8 s to under a millisecond on the test machine. A preset with a key, and any
  `url` server the config wrote, are still connected at start: a key can unlock tools the table cannot
  name, and only a server's own `tools/list` can say what a `[[mcp]]` url offers.
- The release binary is not position-independent and carries no unwind tables, which takes 62 KB off
  the file and keeps the pages they landed in out of its resident set.
- The main thread's stack pages below the frame are returned to the kernel once the TLS handshake is
  done (`net.releaseDeadStack`, Linux), so a streaming HTTPS run holds less resident memory for the
  rest of its life. The peak is unchanged.

- `make` and `make musl` build `ReleaseSmall`, as the release assets already did, because it holds the
  least resident memory of the three release modes and retires about 1.4 times the instructions of
  `ReleaseFast`, which is under 1% of a turn either way. `make small` is gone (it was this build);
  `make OPT=ReleaseFast` builds the other. The Harbor benchmark binary is now the shipped build, where
  it was `ReleaseFast`.
- The documentation leads with memory footprint, not file size: the README, `docs/benchmark.md` and
  `docs/performance.md` give peak resident memory for microagent and for `grok`, `codex`, `claude`,
  `crush`, `opencode` and `kimi` at `--version` (0.6 MB against 25 MB to 326 MB).
- The instructions the model is sent are shorter with the same rules: the system prompt, the tool
  descriptions and the skills listing say each thing once, and the credential list lives in `read`'s
  description, which the other tools point to. The fixed part of every request is smaller, the
  reply-style block is gone, and the remote presets ship compact descriptions and schemas, applied only
  to the preset's own host and to tools it knows. It changes the prompt the model sees, so a benchmark
  run before and one after are not the same experiment.
- Release builds no longer give every thread a 256 KB signal stack, which std zeroed at thread start
  whether or not the segfault handler was on.
- The environment map is built without copying: its keys and values are slices of the process's own
  environment block, and the credentials are removed from it in place
  after the key is read, where it was copied twice and freed at exit.
- The stock system prompt is escaped at compile time, and the JSON string writer skips plain text a
  word at a time.
- The sandbox path check resolves a relative path against the working directory it recorded at startup,
  saving one `realpath` (open, readlink, close) per `write` or `edit` call.
- The shipped `ReleaseSmall` build is faster where its code generation was weakest: the environment map
  needs no copy and no key validation, and its string lengths are found a word at a time; a
  word-at-a-time `memcpy` (`src/copy.zig`, built with `-fno-builtin`, Linux `ReleaseSmall` only)
  replaces the compiler runtime's byte loop; and the stream's `"error":` check compares a machine word
  per position. `ReleaseFast` is unchanged apart from the environment map.
- Remote MCP servers (`url` entries and the `web_search`, `context7` and `grep_app` presets) are connected
  concurrently at startup instead of one after another. Server and tool order still follow the config,
  and a server that fails is still reported and skipped; peak resident memory of that startup rises by
  about 0.45 MB, because three TLS handshakes are alive at once.
- The async-slot limit is sixteen, not four. `Io.Threaded` runs an operation inline once every slot is
  busy, and a connection dials every address its host resolves to at once, so at four the four default
  remote presets cost about 4.6 s before the first request: the `deepwiki` preset's five addresses were
  serialized against the three handshakes already there. At sixteen the same run is about 2.8 s, which is
  the slowest server's own answer time. Every connection pays this, not just MCP: a provider reached over
  a name with several addresses was serialized the same way. Address space and peak resident rise a
  little while an operation is on the extra workers; `--version` resident is unchanged. No instruction
  row carries a wait, so the guard is a test.
- The API key is read from one variable, `MICROAGENT_API_KEY` (or `--api-key`, or `~/.secrets/openrouter`).
  `OPENAI_API_KEY`, `OPENROUTER_API_KEY` and `DEEPSEEK_API_KEY` are no longer read, and the "key is for
  another provider" warning is gone. If you exported one of those, export `MICROAGENT_API_KEY` instead.
  `bench/harbor.sh` and the Harbor adapter read only that variable.
- The config file has one spelling per setting. Booleans are `true` and `false` only, and `deny_commands`
  and `writable` must be arrays.
- `microagent update` is a third of its size (2,264 to 956 lines) with the same guarantees: GitHub hosts
  only, the digest checked against the sidecar before the binary is replaced, an atomic replace that follows
  symlinks, no downgrade. The digest check and the replace are one function with its own test. `--repo`,
  `update help` and the fetch retry with backoff are gone; a failed download prints one line and exits 1.
- The linters' hashed install is compiled by `uv` from `lint-requirements.in`, as the Harbor lock is, so its
  transitive pins are correct by construction. `make lint-pins` and its scripts are gone, with `make
  test-one`, `make watch` and `make check-targets`: `make test FILTER=...` refuses a filter that matches no
  test, and `zig build test --watch` is the edit loop.

### Removed

- The reply-style module. `caveman`, `ponytail`, `[style]`, `MICROAGENT_CAVEMAN` and `MICROAGENT_PONYTAIL`
  are gone; a config still holding them prints "'caveman' is not a key this file uses" and runs.
  Migration: paste the level text you were using into the new top-level `system_prompt_extra = "..."` (or a
  `"""` multi-line string), which is appended to the system prompt after a blank line, up to 16 KB.
- Config aliases: the `[commands]` and `[command_filter]` tables, the keys `command_filter`,
  `denied_commands`, `deny`, `denied` and `filter`, top-level `sandbox = true`, and the `[sandbox]` keys
  `enable`, `allow_write` and `writeable`. Use top-level `deny_commands = [...]` and `[sandbox] enabled`,
  `writable`. Boolean spellings `1`, `0`, `yes`, `no`, `on`, `off`, any case variant and the quoted form.

## [0.5.0] - 2026-09-29

### Added

- `make lint-pins` checks lint-requirements.txt against the metadata of the
  installed linters, and `make lint` runs it. That file is hashed and installed
  with `--require-hashes` like the Harbor lock, and is the one dependency set
  here that is hand-written rather than generated, so a yamllint bump could
  leave a pin nothing imports, or a pin below a bound the new yamllint asks for,
  and both install cleanly: the first is a package in the lint venv that no
  linter loads, the second fails at import inside the lint job. The check asks
  the same two questions `make lint-lock` asks of the Harbor lock, from the
  linters' own package metadata rather than a generated file.
- `make check-asset-run` builds the published release asset for the host it runs
  on and starts it, and `make check-binary` builds and starts the host binary.
  Both were inline steps in the push workflow with no local command behind them,
  so a change that only broke the shipped binary surfaced as a red push rather
  than as a command a contributor could run. The workflow calls these targets
  now, and `check-asset-run` refuses a `TARGET=` that is not the one the host
  publishes.
- `docs/usage.md` has a "What leaves the machine" section naming every host a
  run reaches and every file it writes: the conversation and every tool result
  go to the configured provider, the update check tells GitHub the IP and the
  version, an MCP server sees the tool name and its arguments and nothing
  else, and the session log holds counters and the working directory at
  `0o600`. The session log section now says the same about the modes, about
  what `cwd` reveals, and about how to delete the store.
- `make check-changelog-links` holds the `[Unreleased]:` and `[X.Y.Z]:`
  references under the changelog to the versions the headings above them name,
  and `make check-unreleased` and `make check-release` both run it. Cutting a
  release renames the `[Unreleased]` heading and adds the version's own, and
  those two lines are written by hand: a release that skipped them published
  notes whose diff still pointed at the release before the one being read, and
  nothing downstream of a green gate read the link to notice.
- `make test FILTER=...` runs the tests whose names contain `FILTER`, the same
  run `make test-one` makes. `make test FILTER=...` was accepted and ignored, so
  the obvious spelling of the one-test loop ran the whole suite, and the filter
  that named nothing was never the one that said so.

### Changed

- A Linux build that links libc now fails to compile. The Linux binaries have
  never linked a C library (the `musl` in `x86_64-linux-musl` is the target
  triple, not a linked libc), and nothing held them to it: a `linkLibC` or a
  dependency that turned it on would have shipped a binary that needs one.
- A streamed frame is parsed straight into the per-frame scratch allocator.
  `std.json.parseFromSlice` built an arena of its own around that scratch for
  every frame, which the caller resets anyway: 29.0 M to 28.0 M instructions
  on a 5,000-frame stream.
- The constant half of every request, the one that carries the tool schemas, is
  built once per run rather than once per turn. It is a pure function of the
  options, and nothing the loop does changes any of them, so each turn was
  walking the built-in schema again and copying every MCP tool's `inputSchema`
  into a fresh turn-arena buffer to produce bytes identical to the previous
  turn's. A run with servers carrying large schemas paid that once per turn, and
  it grew with the number of servers rather than with the work.
- A tool call's `id` and `name` are copied once instead of once per streamed
  frame. Providers repeat both on every argument fragment that follows them, so
  a call whose arguments arrived in a few hundred frames allocated and released
  the same two strings a few hundred times on the path that cannot be re-sent
  cheaply. A value that did change still replaces the one it follows, and a
  provider that empties a field still clears it.
- An MCP tool whose `inputSchema` is over 16 KB is advertised with an empty
  object schema that names the omission, rather than with the server's bytes. A
  schema is whatever the server chose to serialize, and it sits in the constant
  prefix of every request the run makes, so a server that embeds a large
  `description`, `examples` or `enum` in one wrote megabytes into every turn of
  the run, for the whole run. Before: a run with such a server billed the schema
  on every request and the model saw the arguments. After: the tool is still
  callable, under a schema whose `description` tells the model the arguments are
  not described here and to ask the operator. A schema under the ceiling is the
  server's own bytes, in the order the server wrote them, so the cacheable
  prefix a provider hashes is unchanged for every server already in bounds.

### Fixed

- The four analyzer suppressions in the tree said what rule they silenced and
  nothing else, so nothing recorded why each was there. `lint-shell` and
  `lint-python` now refuse a `# shellcheck disable=` or a `# noqa` that no
  `# because:` comment above it covers, so a suppression that outlives its
  reason, or arrives without one, fails the gate rather than the next reader.

- A `~` at the front of a path in the config file, in `MICROAGENT_CONFIG` or in
  `MICROAGENT_SKILLS` named a directory called `~` under the working directory,
  which is a path no machine holds. Nothing expands a tilde on the way in: a
  shell does it for a word on a command line, and these are values in a file
  and in a variable, read by a program with no shell in it. The spelling both
  the docs and `config.example.toml` print now resolves to the home directory,
  and the same expansion answers `--config ~/x.toml` for a caller whose shell
  did not get to it first. `~user` is left alone: another account's home is not
  this program's to look up.
- The Harbor README named nine of the ten variables its adapter reads. The one
  it left out, `MICROAGENT_STALL_TIMEOUT`, is the one a slow provider needs: the
  adapter checked it, forwarded it and never wrote it down, so an operator
  setting it was working from the source. A test now holds the README to the
  names the adapter quotes, the way the other two tests hold `--help` and
  `docs/usage.md` to the names this binary reads.
- `--help` and the usage reference said a key on the command line goes to the
  base url and stop there. It is in the process table for the length of the
  run, where any user of the machine can read it, which is the reason a
  variable or the key file is the source to reach for.
- A test skipped for want of a program the host does not have said nothing. The
  `search` and `ast` tests delegate to `rg` and `ast-grep`, which a stock macOS
  ships neither of, and one session test is macOS-only; each returned
  `error.SkipZigTest`, which the runner counts as a pass, so a laptop without
  ripgrep reported a green suite that had never run the search tool and named
  no reason. Each now prints what it skipped and why.

- The session store kept its 200 newest logs and nothing else, which is a size
  and not a period. On a machine that runs a few times a week, two hundred
  logs is four years, and every record names the directory the run worked in,
  which is under `$HOME` and carries the account name. A log older than 30 days
  is now dropped whatever the count says. A clock at or before the epoch, or one
  set back between two runs, expires nothing: both are a machine whose clock is
  wrong rather than one whose logs are old.
- The README named version 0.3.0 after 0.4.0 shipped, in both the install
  snippet and the status line. A reader who copied the snippet installed 0.3.0,
  and the status line was a release behind. `make check-readme` now refuses a
  bump that moves `build.zig.zon` and the changelog and leaves either README
  line behind; it runs in `make check` and in the push workflow, and
  `make check-release` asks it before a tag is cut.
- Compaction no longer copies the whole conversation to add the closing bracket
  the JSON parser needs. The byte is appended to the conversation buffer and
  taken back before the rewrite, which is about 0.4% of a run whose tool results
  keep crossing the conversation limit.
- The Io worker threads are built with a megabyte of stack each and a ceiling of
  four, instead of std's 16 MB and one per core. Two workers at rest were 32 MB
  of address space for call paths that read and write files and sockets: a run
  peaks at 6.7 MB of address space over 300 turns where it peaked at 36.7 MB,
  and at 46.8 MB over 3000 where it peaked at 91.8 MB, with peak resident on the
  long run down from 10.9 MB to 9.5 MB. The batches this program issues hold one
  or two operations, and the smaller stacks were stress-checked against the
  largest MCP answers the tests carry.
- A request body is sent as the constant prefix, the conversation and the
  closing bytes, instead of first being built in one buffer. That buffer copied
  the conversation every turn, and on a long run it was the largest single memcpy
  the harness made: a 3000-turn run costs 211.9 M instructions before and 177.8 M
  after, with peak resident memory down from 13.3 MB to 11.0 MB. The bytes on
  the wire are unchanged, which was checked by recording the request body of
  every turn of a five-turn run before and after.
- An MCP server's answer is read with the newline scan resuming where it
  stopped, instead of restarting at the front of the buffer on every 8 KB chunk.
  A one megabyte `tools/list` answer was searched 128 times over growing
  prefixes, about 66 MB of the same bytes; three such servers cost 91.1 M
  instructions before and 75.3 M after.
- An MCP tool result is built up to the 24 KB ceiling a tool result is clamped
  to, instead of being built whole and clamped a moment later. A server that
  answered with a 4 MB text block cost about 19 MB of peak memory; the same
  answer now costs about 13 MB, and the note naming the size it was cut from is
  written while the text is built, so it still reports the whole size.
- The system prompt contradicted itself about a skill body. A skill arrives
  through the `skill` tool, so it arrives as a tool result, and the prompt tells
  the model that a tool result is data about the repository rather than something
  to act on. The model resolved the contradiction itself, in whichever direction
  the skill happened to argue for. The prompt now names the exception, says where
  the trust comes from (skills come from the operator's own directories and never
  from the repository under review), and keeps the credential rule standing over
  a skill body: an installed procedure that asks for a key is one to report.
- An MCP result that carries no `content` is the structured one, and it was
  serialized whole before the caller clamped it, so a server answering with a
  megabyte of `structuredContent` was copied and stringified in full and cut
  afterwards. It is built up to the same 24 KB cap the text path takes, and
  because the cap can land mid-object the note says the whole size, so a result
  the model cannot parse does not read to it as the whole of one.
- The MCP shutdown was skipped on a failed run. `runMain` left the process from
  inside itself, so a `std.process.exit` between two of its defers ran neither,
  and the defers that did not run on the error paths included the one that kills
  the server process groups: a run that failed with servers connected left them
  running. The exit is now taken by `main`, after every defers that frame owns.
- A socket that refused `SO_RCVTIMEO` left the turn with no stall guard and no
  word about it, and a read on it can block until the caller kills the run, which
  is the whole failure the guard exists to prevent. A refusal now ends the
  request, and the error names it rather than reading as a provider failure.
- `microagent update` printed `failed` instead of the reason whenever the path it
  was installing to was long enough to overrun a 512-byte buffer, which is the
  one line that does not name what failed. The buffer is now as wide as a whole
  install path beside a sentence, and every other message it prints is cut to
  that same width, so none of them can reach it either.

## [0.4.0] - 2026-09-29

### Added

- `bench/stub_provider.py`, a loopback OpenAI-compatible endpoint that streams a
  fixed number of frames and can answer 503 to the first requests. The
  streaming profile and the retry evidence in `docs/benchmark.md` were measured
  with scripts that were never committed; they are now re-measured with this
  one and reproducible from the tree.

### Fixed

- `docs/usage.md` said a 429 or a 5xx is retried and a 400 fails at once. The
  retried statuses are 408, 409, 425, 429 and every 5xx, and a 400 is retried
  once without the `reasoning` field when `--reasoning-effort` is set.
- `docs/benchmark.md` re-measured where its figures had drifted or could not be
  traced: startup is now retired instructions and CPU time per harness, the
  every-run SWE-bench table lists the three runs it had left out, and the
  conversation-growth figures match the current prompt.
- A skills directory no longer keeps every `SKILL.md` resident for the whole
  run. The listing read each file whole to find the name and description in its
  frontmatter and held that text in the run arena, so 200 skills of 100 KB were
  24.3 MB of peak memory and 21 MB of reads before the first request left; it
  reads the head of each file now, and a `skill` call reads the body it needs.
  Measured: 24.3 MB to 4.6 MB peak resident, and 9.3 ms to 2.0 ms of system
  time to the first request. A library of ordinary size pays nothing either
  way.
- An MCP server's `tools/list` answer is no longer kept twice over. The answer
  was parsed into the run's arena and the buffer it arrived in kept the size of
  the largest line for the rest of the run, so a server with a 1 MB schema cost
  about 8.5 MB resident and three of them about 12 MB. The answer is parsed in
  a scratch arena now, only the schema bytes the request carries are copied
  out, and the buffer is freed when the line is out: 4.5 MB for one server and
  for three.

## [0.3.0] - 2026-09-29

### Changed

- The documentation moved under `docs/`: `BENCHMARK.md` is `docs/benchmark.md`,
  `PERFORMANCE.md` is `docs/performance.md`, and `THREAT_MODEL.md` is
  `docs/threat-model.md`. The README is now a short front page with a logo,
  and its reference sections (flags, environment variables, config, skills,
  MCP servers, tools, output formats, exit codes, update, versioning) are
  `docs/usage.md`, which the test holding the documents to the variables the
  program reads now checks in place of the README. The project's own gauntlet
  review prompts moved from the root to `reviews/`, run with
  `gauntlet --prompt-dir reviews`.

### Fixed

- MCP servers are started before any of them is asked to initialize, so their
  own boot times overlap instead of adding up. A server's handshake mostly waits
  for that boot (`npx` resolving a package, a node or python interpreter
  coming up), and a run with `[[mcp]]` tables paid for each one in series
  before it could send its first request. Measured against a stub provider with
  three servers that each take 0.5 s to answer: 1.51 s before, 0.51 s after.
  With six servers it is still 0.51 s, because the run now waits for the
  slowest server rather than the sum of them.
- An `[[mcp]]` table whose `name` holds a character outside letters, digits,
  dot, dash and underscore is refused and named on stderr. Before, the config
  reader accepted `name = "bad name"` and the run offered the provider
  `mcp__bad name__echo`, a tool name no provider accepts and no model can spell
  back. Two tables with the same `name` were both connected and their tools
  collided on one exposed name; the second is now skipped and named.

## [0.2.0] - 2026-09-29

### Added

- `make check-reproducible` builds the first published target a third time, from a copy of the
  source at another path, and refuses a release when those bytes differ. The other two builds vary
  the clock, the locale, the timezone and the cache but share the checkout's path, so a build
  directory reaching a binary (a panic message naming it, an embedded file read by absolute name)
  passed a check that was looking for timestamps.
- An MIT `LICENSE`, listed in the README and in the package `build.zig.zon`
  ships. A consumer reading the README or fetching the package had no file that
  said what the grant was.
- `make instructions`, wrapping `bench/instructions.sh`, so the retired-instructions
  gate CONTRIBUTING.md documents is a target rather than a line in the prose:
  `make instructions` prints the table and `make instructions CHECK=--check`
  compares each row against `bench/instructions.baseline`. It runs the test suite
  first, since the script reads that build's `options.zig` and stops with a
  reminder when there is none.
- The release workflow reads the published release back after publishing it and
  compares it with `dist/`: the release is no longer a draft, it carries exactly
  the assets this tag built and nothing else, each one byte-identical to the file
  that was uploaded, and each `.sha256` sidecar names the digest of the asset
  beside it. `gh release upload` reporting success said the call was accepted,
  not that a consumer's `update` would find the asset it asks for; a skipped
  asset or a stale one left on a resumed draft published green and failed on the
  machine that downloaded it.
- `.github/dependabot.yml` for the actions ecosystem. Every action in the
  workflows and the shared toolchain action is pinned to a commit sha, so a new
  upstream release cannot turn a green run red on its own, and a sha that stops
  naming a supported runner is found on a push rather than in review. The linter
  pins in `lint-requirements.txt` are deliberately left out: `make lint-versions`
  refuses a bump to that file that forgets the version named in the Makefile, so
  a bot opening that pull request would produce a red pipeline by construction.
- `make watch` reruns the unit test suite on every source change, and
  `make watch FILTER=...` narrows it to the tests whose name contains the
  substring, the way `make test-one` narrows one run. It wraps
  `zig build test --watch`, the build system's own mode, so the edit loop is a
  declared command rather than something a contributor has to know. A `FILTER`
  that matches no declared test name is refused before the watch starts,
  because the build system reports success for a filter that ran nothing.
- The bench shell, the Harbor adapter and the workflows are linted. `make check` now runs
  `shellcheck` over `bench/*.sh` and `bench/tasks/*/*.sh`, `ruff check` over
  `integrations/harbor` (rules in `ruff.toml`) and `yamllint` over `.github`
  (rules in `.yamllint`), and CI runs all three as their own blocking job. A defect in
  the bench scripts or the adapter is a wrong benchmark result rather than a failing
  test, so nothing caught it before.
- The Harbor adapter is formatter-checked: `make lint-python` and CI now run
  `ruff format --check` beside `ruff check`, and the two files are formatted to match.
  `ruff` also runs the security, naming, builtin-shadowing, logging and import
  convention groups, which the tree already passed. `yamllint` covers
  `.github/actions/setup-zig/action.yml` as well as the workflows.
- `ruff` also runs the annotation and boolean-argument groups, so a new Harbor
  function without annotations or a boolean positional argument is caught rather than
  shipped, and `C901` is measured against a `max-complexity` written down in `ruff.toml`
  instead of the default. The adapter already passed all three.
- The lint job runs `make lint-versions`, the check that keeps the version pinned in
  `lint-requirements.txt` and the one named in the Makefile from drifting. It was in
  `make check` but not in CI, so a bump that forgot one of the two files only failed for
  whoever ran the gate locally.
- `make check-targets`: the check that every published target is one `microagent update` asks
  for. `ci.yml` claimed its release rehearsal caught an asset name drifting from the ones
  `update.zig` asks for, and it did not: the job built the list and ran `ls`. The unit tests pin
  the naming in `src/update.zig` against literals, and this pins it against the Makefile's
  `RELEASE_TARGETS`, so a target cannot be added to one and not the other. It runs in `make check`
  and in that CI job.
- `make required-zig-version` and `make release-targets`. `setup-zig` and ci.yml's reproducibility
  step each `sed`-parsed the Makefile and `build.zig.zon` themselves, so the toolchain pin and the
  published target list were each spelled twice, and a rename had to land in both to be a rename.
  Both read the Makefile now.
- `docs/threat-model.md`: the attack surface as a whole, entry points, trust boundaries, assets,
  the threats on each boundary, the controls the code implements and the gaps it does not
  cover, each with a file reference.
- Every request now carries `max_tokens`, and `--max-tokens` / `MICROAGENT_MAX_TOKENS` set it
  (default 65536, at least 1). Without it the provider's own limit was the only bound on what one
  turn could generate, so a model that failed to stop was billed until something else stopped it;
  `--max-turns` counts turns, not tokens.
- `MICROAGENT_MAX_TURNS` is read by the binary itself, so the variable works for a plain container
  run and not only through the harbor adapter. The flag still wins where both are given.
- `MDEBUG` is documented in `--help` and in the README, with the values that count as on.
- Fuzz harnesses for the two parsers that take untrusted bytes: the provider's streamed response, frame
  by frame, and the GitHub release body the updater acts on. Both run their seed corpus on every
  `zig build test` through `std.testing.fuzz`, and both assert the invariants a crash-only harness
  misses: the turn a stream produces still serializes as a valid request body, and a release body only
  reaches `.replaced` when both download URLs are trusted and the published checksum matches the bytes.
- Fuzz harnesses for the two other untrusted parsers: the reply-style config file and the command
  line. The config harness asserts that a line the file cannot use is named by a key that is in the
  file, that every level in force is one the parser can name back, and that the prompt block built
  from a fuzzed config names the level it turned on. The command-line harness asserts that no option
  holds a value no argument carried, that `--help` and `--version` stop the parse, that a ceiling is
  never zero and a reasoning level is always one the provider knows, and that the same line parsed
  twice says the same thing. A bad `--max-turns`, `--max-tokens` or `--reasoning-effort` value is a
  message the parser returns rather than a call that exits the process, which is what let the
  command line be read at all outside a subprocess.
- Fuzz harnesses for the two untrusted inputs that had none: a model tool call and the `update`
  subcommand's own command line. The tool-call harness parses a fuzzed argument object and
  asserts the gutter line stays one line inside its fixed buffer with no byte a terminal acts
  on, and that every count the model wrote (`limit`, `timeout_ms`) lands inside its ceiling
  before a subprocess is started. The `update` harness asserts a `--repo` is always bytes some
  argument carried, that a repo `validRepo` refuses never becomes a request, and that one it
  accepts only ever names `api.github.com`. Both run their corpus on every `zig build test`
  through `std.testing.fuzz`.
- Fuzz harnesses for the two terminal-facing escapers, which had unit tests but no corpus: the
  quoted value every diagnostic prints (`chat.safeText`) and the provider error body
  (`tool.terminalSafe`). The first asserts that a fuzzed value quoted under a fuzzed budget
  carries no C0, DEL or C1 byte, stays valid UTF-8 inside its budget, and is a prefix of the same
  value quoted with more room, so a cut cannot land inside a character or inside an escape. The
  second asserts that a fuzzed body leaves the same length, keeps every byte that was already
  printable, and is its own fixed point. Both run their corpus on every `zig build test` through
  `std.testing.fuzz`.
- Stale `path:line` references in `docs/threat-model.md` now point at the functions they name; the
  gutter and `terminalSafe` rows had been citing the dispatcher above them.
- `MDEBUG=1` prints the configuration the run resolved: model, base url, the ceilings, the level
  each style key took, and the name of the variable or file the API key came from. The key is never
  printed and a base url is the redacted spelling. Precedence spans three sources per option, and
  there was no way to see which one answered.
- `config.example.toml` is a commented template for the reply-style file, with both keys, their
  levels and their defaults.
- `docs/performance.md`: what a turn costs inside the harness itself, the four changes that bought
  what they bought, and the four that were measured and left out, so the next round reads the
  refusals rather than re-running the experiment. `docs/benchmark.md` still says what the harness
  measures against other harnesses.

- `git` tool: read-only `status`, `diff`, `log`, `show` and `blame` with a fixed subcommand list and a
  400-line cap, so git state no longer has to be assembled by the model through `bash`.
- Reply styles. `caveman` sets how terse the agent's own prose is (`off`, `lite`, `full`, `ultra`, and the
  three `wenyan-*` levels) and `ponytail` sets how lazy the code is (`off`, `lite`, `full`, `ultra`). Both
  are read from `$MICROAGENT_CONFIG`, else `~/.microagent/config.toml`, and both have an env override
  (`MICROAGENT_CAVEMAN`, `MICROAGENT_PONYTAIL`). Neither touches the tools, the request shape or the
  conversation: each appends text to the system prompt, and with `caveman = "off"` and
  `ponytail = "off"` it appends nothing at all, so a run that turns both off sends the system prompt
  this release writes, unlengthened.
- `cached_tokens` on the stdout usage line and in each session-log record: the part of the prompt the
  provider served from its prompt cache, read from `prompt_tokens_details.cached_tokens`,
  `prompt_cache_hit_tokens` or `cache_read_input_tokens`. Both are additive JSON keys, so a reader that
  looks up the counters it already knows is unaffected.

### Changed

- The README's first test command is `zig build test --summary all`. Without the
  flag the build system prints failures only, so a green run says nothing at all
  under the transcript the suite writes to stderr, and a contributor reading the
  front page could not tell a passing suite from a hung one. `make test` and both
  workflows already passed the flag.
- `make help` lists `check-changelog-sections`, the target it is what
  CONTRIBUTING.md means by "every target". It was the one `.PHONY` entry missing
  from the list, and it is the shape check over any named heading, so
  `SECTION=0.2.0` asks of a version entry what `check-unreleased` asks of a
  draft.
- A bare `help` is a request for the usage text, the way `microagent update help`
  already was. `microagent help` used to be a coding run whose task was the word
  "help", billed to the caller, and printed no usage at all, while the one
  subcommand that accepted the word printed its help. Only a bare word answers: a
  prompt already set, a value of `--print`, and anything after `--` are still a
  task, by the rules that were already there, so `microagent -- "help"` and
  `microagent -p help` run. A script whose prompt was the word `help` now gets
  the usage text and no model output.
- A provider that refuses an optional request field is asked once more without
  it. `reasoning` is this program's field and not the provider's, and one that
  answers it with `400 Validation: Unsupported parameter(s): reasoning` ended
  the run there. A 400 on a run that set `reasoning_effort` is retried once
  with the field dropped and a note on stderr naming the endpoint; a run that
  set nothing never sends the field, so it is not retried and its 400 is the
  one it would have got before.
- The system prompt names `semcode` in the tool guidance, beside the four tools
  it already prefers over shelling out. The prompt told the model to use
  `bash` for anything the others do not cover and said nothing about the
  semantic queries the tree is indexed for, so callers and callees were
  answered with `rg` or by a whole-file read.
- The x86_64 macOS row of the push workflow runs on `macos-15-intel`. The
  `macos-13` image it named is out of the runner fleet, and a matrix row naming
  a label no runner answers to does not start, so the job failed to schedule on
  every push. The row is still the only one that runs the `x86_64-macos` asset
  the release publishes, which macos-14, being Apple silicon, cannot.
- `make lint-shell` runs shellcheck with six of its optional checks on, the
  ones that report a masked `set -e` failure, an uppercase variable read on a
  path that never assigned it, a `which` the shell may not carry, a null test
  against a literal the script just wrote, a discarded command substitution
  and an unquoted `return` value. The tree passes all six. Two of the names
  were misspelled and named no check in any shellcheck, so the uppercase
  variable and null literal checks the list claimed to cover were never
  evaluated and the gate passed on them: shellcheck accepts an `--enable` name
  it does not have and runs the rest in silence. `lint-shell` now asks
  `shellcheck --list-optional` first and fails on a name the installed
  shellcheck does not list, which is what a rename upstream would otherwise
  turn this into again.

- The Harbor adapter keeps `BaseEnvironment` and `AgentContext` in a
  type-checking block, so importing it does not import Harbor's environment and
  context models, and `ruff.toml` selects `TC` so the next one lands the same
  way.

- The system prompt explains the `[earlier tool output elided: N bytes]` marker
  that compaction writes into a tool message. Nothing in the turn said the
  marker was this program rather than a tool that printed it, so a result the
  model read as one line of output was a result it reported as the whole of what
  a search found, and the way back to the bytes was to run the tool again.

- `microagent --help` lists `MICROAGENT_SESSION_DIR` under its own heading rather
  than under "reply style", where a session directory read as a third style
  level, and says that a `--max-spend-tokens` run warns on stderr once 80% of
  the ceiling is spent, which the README already said and the flag did not.

- A `bash` call that succeeded with its whole output on one stream is handed to
  the model as the capture itself rather than as a second copy of it. The bytes
  are the ones the assembling path produced, so the answer does not change; a
  command that exited non-zero, was cut at the cap, or wrote to both streams
  still has its note appended exactly as before. Every other tool already
  returned its capture this way, and `bash` was the one that paid a copy of up
  to 96 KB of output per call to produce bytes it was already holding.

- The verification-turn check no longer rescans a tool call's arguments once per
  test-runner name. The name is now matched against a window of the last few
  words as the arguments are walked, so a multi-kilobyte `bash` command is read
  once rather than 25 times over. Which calls count as a test run and which as
  an edit does not change: a name inside a longer word, a name split across
  JSON punctuation, and a name in the issue text are all still refused, and a
  test asserts the two answers agree over each of those shapes.

- `search`, `ast` and `git` name the program they delegate to when that program
  is not installed, and how to install it. `rg` and `ast-grep` are not part of a
  stock macOS, where this binary ships and runs, so `error: ripgrep failed:
  FileNotFound` was a code with no program to install and no way to install it.
  Every other failure, a timeout among them, keeps the wording it had.

- A structural search is no longer counted as an edit. The loop asks for one
  verification turn when the model changed the tree without running a test, and
  `ast` was in the set of tools that could have changed it whether or not the
  call carried a `--rewrite`, so a run that only looked was asked to verify
  changes it had never made. The key is read now, and a search that printed its
  matches is a read.

- The harbor adapter checks `MICROAGENT_BASE_URL` before the container starts, the way it
  already checks the ceilings and the reasoning level. A url with no scheme, or an http one
  that is not loopback, is refused by the binary because the api key rides in a header that
  host reads, and it was refused there: after a container start and a binary upload, in a
  log the operator was not watching. It is now named at the command line.

- A host CA bundle that does not land in the container is a warning naming the bundle and
  the reason, rather than an info line with "write failed" inside a message about a byte
  count. The run still continues on the container's own trust store, which a bare image
  does not have, so the first request dies as `TlsInitializationFailed` with nothing in
  the log to connect it to the host that had a bundle to give.

- A bare `--` ends the flags. A task is model output and starts with a dash as
  often as not ("-Werror", "--fix"), and `microagent -- "..."` was an unknown
  argument and exit 2 before a request was sent; the only spelling that took
  one was `--print`. `microagent -- --help` is a run whose task is the words
  `--help`, which is what `-p --help` already was, and `microagent update`
  reads the same marker.
- The reproducibility gate isolates the compiler's global cache as well as the project one.
  `--cache-dir` moves the project's artifacts, but the compiled toolchain stayed in the
  runner's `$HOME/.cache/zig`, so a warm cache left by a previous build on the same machine
  fed the next one and the check was not measuring the cold build it claimed to. Each
  build now sets `ZIG_GLOBAL_CACHE_DIR` to a scratch of its own, and the scratch is removed
  by a trap, so a target that fails the comparison leaves nothing behind either.
- The push workflow runs the `x86_64-macos` asset instead of only building it. The two
  macOS runners are an Apple silicon one and, now, an x86_64 one, so three of the four
  published binaries are started on a push rather than cross-compiled and left. The fourth,
  `aarch64-linux-musl`, still needs a machine of its own and is covered by the build alone.

- `make gauntlet AGENTS=...` wraps `bench/gauntlet.sh`, the usefulness
  benchmark whose results docs/benchmark.md publishes, beside the `make bench` and
  `make overhead` targets that already wrap its two siblings, and the
  `Reproducing` block names the command. Each of the three scripts invoked the
  harnesses by bare name and skipped the ones missing from PATH, so running one
  without the target on it recorded a skipped row rather than a measured one.

- CONTRIBUTING.md no longer sends a contributor to `zig build test --fuzz` as if
  it ran. It does not build on the pinned 0.16.0: the toolchain's own test
  runner fails to compile under `-ffuzz`, so the command ends in eight
  compiler errors before a harness is reached. The corpus is still asserted on
  by every `zig build test`, which is where a new seed has to be written down.

- A run that stops at a ceiling exits 3 instead of 0. `--max-turns`, and a budget
  that ended the last turn, both leave a prefix of an answer on stdout while
  reporting success, so a script reading the text read a truncated review as a
  finished one. 0 is now only a run the model finished: 1 is a failure, 2 a bad
  command line, 3 a run stopped at a ceiling. A script that wants the prefix
  regardless of the status reads stdout as it did; one that acts on the status
  now has the fact it needed. `microagent --help` and the README carry the code.

- A `read` with `offset` or `limit` streams the file instead of reading all of it and
  copying the lines out. Reading fifty lines of a 3.9 MB file took 0.90 ms and left the
  whole file in the turn's memory beside the response it shared that memory with; it takes
  0.48 ms and leaves about one read's worth. The cap is unchanged, and still a property of
  the file rather than of the range, so a file that reaches 4 MB is refused either way.

  Two consequences the old reader had as bugs. The newline ending a file's last line
  terminates it rather than starting another one, so `read` of a whole file and `read` of
  the same file line by line no longer disagree about whether it ends in a blank line, and
  an empty file no longer reads back as a single blank line.

- The agent loop, the tools and the shared value types are three modules instead of one file.
  `main.zig` held the command line, the config, the session log, the provider request, the frame
  parser, the tools and every subprocess it started, which is a 4 400-line file where a change to
  the tool runner cannot be read without reading the retry policy. `tool.zig` now owns the tools
  and the capped process runner, `chat.zig` the value types a turn is made of and the JSON writer,
  and `net.zig` the deadline the two of them share. No behavior changes.

- A turn whose response never arrives is not sent again. A connection that died while the
  response head was being read left the request whole on the wire, so the provider may have
  generated and billed the completion with no response to show for it, and the retry bought a
  second billable completion for one turn. That failure now ends the run with the connection
  error named on stderr. A 429, a 5xx and a connection that dies before the request reached the
  provider are still retried twice.
- The linters CI installs come from `lint-requirements.txt`, which pins `ruff`, `yamllint` and
  the two packages `yamllint` imports to one sha256 per published artifact, and the lint job
  installs it with `--require-hashes`. A version range was a resolved-at-install-time choice of
  whatever the index served that day; a hash is the file a person looked at. `make lint-versions`
  fails when a version there and the one in the Makefile drift apart.
- The Harbor adapter's own dependency is declared. `integrations/harbor/requirements.txt` pins
  `harbor` exactly, because the adapter subclasses its agent API and a benchmark score is only
  the same score against the Harbor release that produced it.
- The benchmark venv installs from `integrations/harbor/requirements.lock`, which pins Harbor's
  whole dependency tree to one sha256 per published artifact, and is `uv pip compile` output
  from `requirements.txt`. A pinned `harbor` alone still left 89 packages resolved at install
  time, so the pair that produced a number in `docs/benchmark.md` was not the pair the next run
  installed.
- A style config that is present but unreadable, is a directory, or is over the 64 KB cap says so on
  stderr, not only one a flag or `MICROAGENT_CONFIG` named. A file that is simply absent stays quiet.
- `GITHUB_TOKEN` is trimmed before it becomes an `Authorization` header, like the provider key file
  is. A token a wrapper read from a file arrived carrying that file's trailing newline, and GitHub
  refused it as an invalid credential rather than as a whitespace mistake. `microagent update --help`
  now names the two CA-bundle variables it already read.
- The Harbor adapter validates every knob it hands the binary in `setup`, so a mistyped
  `MICROAGENT_MAX_TURNS`, `MICROAGENT_BUDGET_SECONDS`, `MICROAGENT_AGENT_TIMEOUT_SEC` or
  `MICROAGENT_REASONING_EFFORT` is named before the binary is looked for and uploaded, rather than
  after a container start and an upload have already been paid for.
- The Harbor adapter validates `MICROAGENT_BUDGET_SECONDS` before the container starts, and refuses
  a zero value for every ceiling it reads, which is what its README already promised.
- CI restores the Zig build caches between runs, from the shared toolchain action, so a push no
  longer pays for compiling the compiler cache and `std` from scratch on a cold runner. The
  global cache is moved under `RUNNER_TEMP`, whose default path differs per runner OS.
- The published targets and their asset names are spelled once, in the Makefile, as
  `make release-assets TAG=v0.2.0`. `ci.yml` rehearses the release with that target and
  `release.yml` publishes what it builds, so a release can be built on a laptop the way the tag
  builds it, and a renamed target no longer has to be renamed in two workflows.
- The Harbor adapter's budget follows the timeout it is given, and a run that still reaches it is
  scored on the tree it left. `MICROAGENT_BUDGET_SECONDS` went to the container as sent, so a budget
  at or above harbor's per-task timeout had its last turn killed by the caller mid-write: the binary
  allows its forced final push 300 s past the budget, and a 780 s budget inside a 900 s timeout lost
  Terminal-Bench 2's `adaptive-rejection-sampler` that way. The budget is now the smaller of
  `MICROAGENT_BUDGET_SECONDS` and `MICROAGENT_AGENT_TIMEOUT_SEC` less 360 s, the grace plus a minute
  for teardown, floored at 60 s. At the defaults, 600 against a 1500 s timeout, the budget is
  unchanged; a caller that names both gets the cap, so a 900 s task timeout runs a 540 s budget where
  it ran 600. A timeout the room does not cover no longer raises out of `run`, which recorded the
  trial as an exception and scored the work as nothing: the tree the agent changed goes to
  verification, the timeout lands in `microagent-timeout.txt` in the job's log directory, and a
  warning names it, so a trial scored on a partial tree is visible rather than silent.
- `release.yml` refuses a patch tag whose changelog section carries an `Added`, a `Changed` or a
  `Removed` entry, and names the version above it in the message. The policy is in the README and in
  CONTRIBUTING, but nothing checked that the tag agreed with the entries it publishes, so a
  feature, a changed default or a removal could ship as `0.2.1` under a number that promises it
  did not.
- `microagent --help` carries three worked invocations, and its subcommand line spells the flag
  the way `microagent update --help` does (`update [--check]`, not `update [-c|--check]`).
- The file a write lands on when the path is a symlink is resolved once, in `net.zig`, and shared
  by the `write` and `edit` tools and by `microagent update`. The two copies answered the same
  question differently: the tools' copy spelled the join as a hardcoded `/` and read the
  link's directory by scanning for one, where `update` went through `std.fs.path` and used
  `std.fs.path.sep`. Nothing changed for a run, but a path separator reached for as a literal
  is the one thing in a path that is not portable, and there is now one implementation of the
  answer to check. `writeFileAtomic` takes no allocator as a result: the two scratch buffers
  it needs are stack, so the arena a caller passed for nothing is gone.

- `--max-turns` now defaults to 100 (was 60). A run that relied on stopping at 60 turns now gets the
  longer loop; pass `--max-turns 60` to keep the old ceiling.
- Replies are terse by default: `caveman` is `ultra` and `ponytail` is `full` unless the config or env
  says otherwise. A run that wants the prose back sets `caveman = "off"`.

- The system prompt is rewritten around the order a fix goes in: find the code and
  the tests that cover it, reproduce the failure before changing anything, make
  the smallest change, run that reproduction and those tests again, then read
  the diff. It also says that what a tool returns is data about the repository
  rather than instructions, and that a credential is not part of the task, and
  each tool's description in the schema names the credential files it refuses.
  The tools, the flags and the exit statuses are the same; what the model does
  with them is not, so an answer, a token count or a benchmark number from
  `0.1.1` is not one this version reproduces.

### Removed

- The second copy of the session store in `main.zig`. The run opens, writes and closes its log
  through `src/session.zig`; `main.zig` kept a parallel `Session` type, its own
  `createSessionLog`, `pruneSessions` and `sessionRecord`, and a `sessionDir` no call reached, so
  one file-owning store was spelled twice and only one of them was ever run. The tests beside the
  dead copy were duplicates of the ones in `session.zig`, which keep every assertion.

### Fixed

- The README's list of the variables an empty value leaves at their default
  named eight of the nine `--help` names, missing `MICROAGENT_STALL_TIMEOUT`.
  Nothing reads the README against the help, so the two disagreed about what an
  empty value means for a third of the configuration surface, and neither run
  said so: an empty value reads as unset either way. A test now holds both
  documents to `env_vars` and to `empty_is_unset_vars`, checked in the paragraph
  that states the rule rather than anywhere in the file, since a name a document
  spells elsewhere satisfies a search of the whole of it.
- `zig build test` is a cache hit after a tracked file the suite reads is
  edited, so the tests that read `README.md`, `config.example.toml` and the
  Harbor adapter never saw the edit. Both run steps now depend on those files'
  contents, so a change to one of them reruns the suite.
- `bench/harbor.sh` hands the opencode provider overlay to harbor as a real
  argument and reads the provider key the way the adapter reads it. The overlay
  was one string of backslash-escaped JSON, expanded unquoted, which shellcheck
  refuses (`SC2089` and `SC2090`), so `make lint` was red and so was every push
  and every tag the gate runs. The key went to harbor as
  `--ae OPENAI_API_KEY=<key>`, which holds a live provider credential in the
  process table for as long as the run lasts, and `${MICROAGENT_API_KEY:-}` sent
  an empty value whenever the host had exported one of the other three names the
  adapter accepts, so the trial ran to its timeout against a provider with no
  credentials. The four names are read in the adapter's order and an empty one
  stops the run before it starts, naming them.
- A Harbor run's job directory defaults to `~/harbor-jobs` rather than
  `/tmp/harbor-jobs`, which is what the adapter's own README already passes to
  `--jobs-dir`. A job directory holds every container log and agent transcript
  the run produced and the scores in docs/benchmark.md are read out of it, so a
  tmpfs that a reboot empties is the wrong place for it, and the default
  disagreed with the documented command. `JOBS_DIR` still overrides it.
- A pre-release tag carrying dots of its own no longer reads as no version at
  all. `v0.2.0-rc.1` was split on `.` and came out as four components, so it was
  refused as an unorderable tag and compared equal to whatever build was
  running: a build on `0.3.0` installed `0.2.0-rc.1` over itself, silently. The
  suffix is now taken off the whole tag before the components are split, which
  is what the parser has always documented. The same change makes build
  metadata (`v1.2.3+build.1`) read as the triple it describes.
- The `Retry-After` reading used to cross-check the one the fetches use now
  reads a head the sender stopped writing short. It walked only to a `\r\n`, so
  a header on an unterminated last line was invisible to it and present to the
  fetches, and the check comparing the two failed on a value both had read.
- `zig build test-sanitize` pinned neither `LC_ALL` nor `TZ` while `zig build
  test` pinned both, so on a host whose locale is not `C` the sanitized run
  failed a child-environment test the plain run passed. Both runs now take the
  pair from one place in `build.zig`.
- A failure the provider reported part way through a completion stream is named
  and ends the turn. A provider that fails after the first tokens cannot say so
  in a status line, because the response head was 200: it puts an `error` object
  in a frame and stops, and the frames around it carry choices, so the turn read
  as one the model finished. A stream that then closed with `[DONE]` put a
  prefix of an abandoned answer on stdout and exited 0, and one that closed
  without it said only that the terminator was missing. The turn now reports the
  provider's own code and message on stderr, says that stdout holds a prefix,
  and is not retried, because the request is not a resumption and a second one
  is a second billable completion.
- Two git tests no longer pass on a revision git could not resolve. The control
  asked only that the output not start with this tool's own `error: rev`, so on
  a depth-1 checkout, where `HEAD~3` does not exist, git's `fatal:` line
  satisfied it. One control now names a revision every checkout has, and both
  reject any error rather than one spelling of it.
- The two git fixtures that commit set `commit.gpgsign=false` and an empty
  `core.hooksPath` on the repository they build. A developer whose own git
  signs commits has no key the runner holds, and the fixture commit was then
  the only thing in the test that failed, for a reason unrelated to what it
  tests.
- A `Retry-After` that names no wait no longer spends the backoff's place. The
  date form is the one a CDN or gateway computes against its own clock sends, so
  a run whose clock runs a minute ahead of the provider's read every one of those
  headers as a deadline already past, and a literal `retry-after: 0` reaches the
  same value. The zero was taken as the wait, so all three attempts went out
  within milliseconds of each other: three billable refusals from a provider that
  had asked for a pause, with the backoff that exists for exactly that never
  running. A header naming a real wait still wins over the schedule; a header
  naming none, and a header absent, both fall back to it.
- `MICROAGENT_STALL_TIMEOUT` is checked by the Harbor adapter before the
  container starts, like every other knob it hands the binary. A mistyped value
  was forwarded verbatim and refused inside the container, after a container
  start and a binary upload.
- A session record's `elapsed_ms` no longer counts a suspend as model time. The
  stamp and the reading were both taken on the clock `--budget` is measured on,
  which keeps counting while the machine is off, so a laptop closed for eight
  hours mid-response wrote `elapsed_ms: 28800000` and a monitor dividing a
  turn's tokens by it reported a model generating four tokens an hour. The
  budget keeps that clock, because it is a ceiling on wall time; the record does
  not, because a machine that was asleep was not generating.
- Compaction runs again. The conversation a turn builds is the open JSON array
  `buildBody` closes into a request, and the read-back parsed the buffer as a
  closed one, so every pass failed with a syntax error, said so on stderr, and
  elided nothing: a run past 400 KB re-sent the whole pile on every turn until
  the provider refused it. The `]` the run never writes is added for the parse
  and dropped from the rewrite, so the buffer is left the shape the request
  builder expects.
- A usage count spelled as a negative JSON float is absent rather than zero. The
  integer spelling was read that way and the float fell through to the clamping
  reader, so `-1.0` folded a zero over what an earlier frame had billed and a
  run that had already spent its `--max-spend-tokens` ceiling never stopped.
- The 80% spend alarm is exact. The percentage was applied to the two halves of
  the cap separately, which floored the remainder after the multiply and put
  the threshold of a cap of three at one token instead of two, so the alarm
  could not fire before the ceiling it precedes. The product is taken widened.
- The session store keeps 200 logs rather than 201. The prune ran before this
  run's own log was opened, so every run left the store one over the window.
- `bench/run.sh` counts a binary file a run added as a file rather than as zero
  lines. `git diff --numstat` spells a binary file's two columns as `-`, and the
  sum read each as a number worth zero, so a task whose answer is a new image or
  archive reported `+0/-0` for it: the same false zero an untracked file used to
  cause, reached through a file git did see. The row reads `+1/-0 (1 binary)`.
- The Harbor adapter refuses a host with no provider key before the container
  starts. The key is the one value it has no default for, and it was read in
  `run` alone, so a host that exported none of the four names brought the
  container up, uploaded the binary, and only then reported the missing key,
  where every other unusable value is reported at the command line. A run whose
  `MICROAGENT_BUDGET_SECONDS` was cut to the room the agent timeout leaves now
  says so on the job log, with both numbers, so a score read from that log is
  not a score measured under working time nobody chose.
- A benchmark harness whose command line could not be spelled is recorded as an
  `argv-error` row instead of a pass. `bench/run.sh` and `bench/overhead.sh`
  built it inside the call that ran it, so a substitution that failed left
  `sh -c ''` to exit 0 with no output and no tokens, and the check then read an
  empty tree and passed. The command line is read on its own line and checked
  now, and the gate runs the two shellcheck checks that name the class
  (`check-extra-masked-returns` and `quote-safe-variables`), which the tree
  passes.
- `bench/instructions.sh` says which `zig env` line read wrong when there is no
  lib directory to build against. The fallback was a command substitution
  inside an `||` chain, and `dirname` of an empty word is `.`, a directory, so
  the run went on to ask the compiler for `--zig-lib-dir .`. The std_dir reading
  is checked before it is used and the script exits 2 naming the path.
- One turn's tool results stop adding to the conversation at 256 KB. `max_tool_output`
  bounds a single result and `max_tool_calls` bounds how many one response may ask for,
  and nothing bounded the product: 64 calls at 24 KB each is a 1.5 MB request, nearly
  four times the 400 KB compaction exists to hold the conversation down, and it was
  billed before the next turn elided any of it. Compaction runs at the top of a turn,
  so the turn that filled the conversation was the one with no bound. Every call still
  runs and still gets a tool message, so the next request pairs them as before; past
  the ceiling a result is replaced with a `[tool output not carried: ...]` marker, and
  the system prompt names it the way it names the elision marker's.
- `microagent update` no longer installs a pre-release over a newer build. A tag
  with a `-rc1` suffix was not a version the ordering could read, so it ordered
  as equal to everything and past the guard that stops a downgrade: a build on
  `0.3.0` installed `v0.2.0-rc1` over itself, silently, and the run it left
  behind was the older code. A pre-release is the version released before its
  triple, so it now orders below it. A tag naming no version at all (a fork's
  tag, a branch name) still orders as equal and is installed, as before.
- The numbers the help text states are the numbers the run uses. `--max-turns`
  and `--max-tokens` wrote their defaults, and `--budget` wrote the grace its
  last turn may run past, as prose beside the constants that hold them, so
  changing a default left the help describing the old one. Each sentence is
  built from its constant now, and a test asks that it is there. The
  `--budget` grace is stated in whole minutes, which is the unit a reader
  deciding whether the budget leaves room for a last edit counts in, and a
  compile error refuses a grace that is not a whole number of one.
- `microagent update --repo` is spelled `owner/name` in its flag list, the way
  every synopsis of it and every message about it already spelled it.
- `make check-assets` runs the asset for the host's own platform and
  architecture, found from `uname`, instead of always the Linux one. An ELF
  does not run on Darwin and a Mach-O does not run on Linux, so the check a
  laptop is asked to rehearse a release with failed on both macOS runners and on
  an arm64 Linux host, and reported a version the run never read. A host the
  release publishes no asset for now runs nothing, says so, and still gets the
  object-format check over all four.
- The band comparison in `bench/instructions.sh` computes its ratio in awk
  rather than in shell arithmetic, which is only as wide as `long`. The 512 KB
  read row multiplies a per-unit count of 7.5 million by a thousand, which is
  past 2^32, so a shell with a 32-bit long wrapped it and the gate called a
  regression that was only arithmetic. The same convention
  `bench/gauntlet.sh` already follows for a nanosecond reading.
- Comments and docs that had drifted from the code they sit on. `net.zig` named
  a `daysInMonth` deleted two commits ago, claimed two callers where the
  symlink resolver has three (the one behind the credential check was the one
  missing), and said "either network path" for a `Retry-After` cap only the agent
  run can reach. `main.zig` cited an 80k output-token total as if it were one
  response, counted the test-runner table at 33 names when it holds 25, described
  the JSON separators as gluing a key to the first word when they split it, and
  named a `tool_mod` constant that is not exported. `update.zig` listed two of
  the four published triples, and `tool.zig` listed six of the seven tools that
  refuse a credential path. `docs/performance.md` presented a 40-build instruction
  total as a per-build figure, and `docs/benchmark.md` still carried the line count
  from before the last four thousand lines landed. No behavior changed except one
  prompt string: `ponytail` said "Ask first whether the change needs to exist"
  in the same request as a system prompt that says "Do not ask questions", so it
  now says "Settle first".
- A tool that printed more than a result's cap kept its exit status and its
  failure reason out of what the model read. Each of a child's streams is
  captured at four times `max_tool_output`, and the notes are written after the
  output, so the cut that brought the result back to the cap took them first: a
  `bash` call that printed a 100 KB build log and exited 1 reached the model as
  24 KB of log under the generic truncation marker, with `(exit: 1)` gone, and
  the same call that timed out lost the timeout with it. What the model read
  about a failing command depended on how much the command had printed, which
  is the guessing the status and the reason exist to stop. The output is now
  cut first, on a codepoint boundary, and the notes are written into what is
  left, so a tool's result never exceeds the cap and no note is the thing the
  cap takes.
- `make check-reproducible` built its third binary from a copy of the source it
  made with `git ls-files | while ... done`, and a `cp` that failed partway
  through ended the loop's subshell rather than the loop: a later iteration that
  succeeded decided the exit status, so the build ran against a partial tree and
  the digest it compared described something other than this checkout. The copy
  now fails the check by name.
- The bidi controls and zero-width characters are written out in every value
  quoted for the operator. They are well-formed UTF-8 carrying no C0 or C1
  control, so the escaping every diagnostic already went through passed them,
  and `deploy/‮gnp.exe` reached the terminal as `deploy/exe.png`: a reader who
  copied what they were shown named a file the tool was never asked for. The
  embeddings, overrides, isolates, the marks and the soft hyphen are now spelled
  as the code points they are, in `chat.safeText` and in the tool module's
  `terminalSafe` alike. U+200D is left alone, because it is how an emoji
  sequence is spelled and escaping it would split one glyph into three. The
  values themselves are unchanged: what reaches a model is the bytes it was
  given.
- A run that takes its key from `OPENAI_API_KEY` or `DEEPSEEK_API_KEY` and leaves
  the base url at the built-in `https://openrouter.ai/api/v1` says so on stderr
  before the first request. Every request carries the key in an `Authorization`
  header, so a key minted for one provider reached a third party, and only
  `MDEBUG=1` said which url the run had resolved. A base url named on the
  command line or in `MICROAGENT_BASE_URL` is the operator's statement of where
  the key goes, including a self-hosted gateway, and is not asked about.
- `--model` and `--base-url` name their defaults in the usage text. They were
  the two values a run reached without anybody setting them, and the two a
  reader learns what a run talks to from, so `microagent --help` did not say
  what a run does before it is asked anything.
- Every tool call in a turn is held to the budget as it stands when that call
  starts, rather than as it stood when the turn began. A turn's calls run one
  after another, and the ceiling that cuts a tool's timeout was read once for
  the whole turn, so a reading taken before the first call was already stale by
  the time the second one started: three `bash` calls against a two-minute
  budget were each given the full two minutes, and the run only noticed on the
  next turn. A call that runs long is exactly what shortens the one after it.

- A tool call whose subprocess failed keeps what the subprocess printed. A
  `git log` that timed out after the last hundred commits, a `bash` build that
  printed every error it had found and then hung, and a `git` command refused
  by a timeout all reached the model as the error name alone, so the next turn
  read that the command had produced nothing and ran it again from the start.
  `bash`, `search`, `ast` and `git` now return both streams, the truncation
  marker if a cap cut either of them, and the failure under them. A child that
  was signalled, cancelled, or never finished is no longer reported as a
  command that exited 0: the wait on the process group swallowed its own error
  and left the status it had been initialised with, so a killed `bash` call
  read as a successful one.

- An `ast` rewrite whose result its own pattern still matches is refused,
  rather than applied once per call the model repeats. `return $X` rewritten to
  `return [$X]` gives `return [[1]]`, then `return [[[1]]]]`, on every match in
  the tree, and the second run cannot tell an applied rewrite from a first one
  because the two leave the same bytes. A replacement spelled as the pattern, a
  pattern of metavariables alone, and a replacement carrying the pattern's
  literal text are each refused, in the shape `edit` refuses in, and the
  refusal names `edit` as the alternative. A replacement that re-matches
  through a form the pattern's literal text does not spell is still applied, so
  the model still reads the tree back.

- A byte that is not part of a valid UTF-8 sequence is written as a dot in the
  tool gutter and in a provider's error body, the way a control byte already
  was. A tool argument is whatever the model sent and an error body is the
  provider's own bytes, so a lone `0xff` or the `\xe6\x97` half of a character
  reached the operator's screen as mojibake inside a run's diagnostic. A whole
  sequence is copied byte for byte, so the pass is a fixed point.

- `microagent update` quotes the asset url in its retry notes and the install
  path in the failure it reports. `trustedGithubUrl` has read the scheme and the
  host by the time a fetch retries, and everything after the host is the
  release body's own bytes, so a path carrying an escape sequence reached the
  screen as written; the install line on stdout keeps the path as it was
  spelled, because that is the line a script reads the path out of. A url the
  run cannot quote now says the retry is being taken without naming the url,
  rather than printing it unquoted.

- A mistyped `MICROAGENT_MAX_TOKENS` stops a Harbor run at the command line. The
  adapter forwards it to the container so a low provider balance is a setting
  rather than a wall of 402s, and forwards it unchecked: the binary reads it as
  a ceiling and refuses a value that is not a whole number of at least 1, which
  it did after a container start and a binary upload, in a log the operator was
  not watching. It is checked with the ceilings already checked there.

- `-p task help` is the usage error the parser already refused, not the usage text. The
  walk that answers `--help` and `--version` before the environment is read stepped over
  the value `--print` takes and counted no prompt there, so `microagent -p task help`
  printed the help text and exited 0 while `microagent task help` named two prompts and
  exited 2. The walk counts `--print`, in the `--print=value` spelling as well as the
  separate one, so both answer the same on every command line.

- `--budget` is a ceiling in wall time, including the time the machine spends asleep. It
  was measured on the monotonic clock, which stops for a suspend, so a laptop closed for
  the night woke with the whole budget still in hand and spent all of it on a fresh
  provider bill, which is the outcome the ceiling exists to prevent. The budget and the
  backoff waits it bounds are now measured on the boot clock, which keeps counting
  through a suspend on both Linux and macOS and is just as monotonic, so an NTP step
  still cannot move a deadline. A tool's own timeout stays on the monotonic clock: a
  child that was not running has spent none of its own.

- A session record written on a machine whose clock reads before 1970 carries the epoch
  rather than a negative timestamp. `logStamp` already clamped the reading for the log's
  own name; the record's `ts` did not, so a monitor ordered the store by a stamp that
  sorts below every record it holds and read as a run fifty-six years old.

- A session log on a machine whose clock reads before 1970 is pruned like any other. The
  log's name is the wall clock's nanosecond stamp, and a negative one spelled a name
  beginning with `-`, which the pruner does not parse as a name it wrote: the log was
  written and then never counted toward the retention window, so the store grew past its
  limit on that machine while reporting itself pruned. The stamp is clamped to the oldest
  one instead, so a clock that says nothing about the time sorts as the oldest log.

- The harbor adapter's own logs cannot end a run the verifier has to score. Writing
  `microagent-stdout.txt`, `microagent-stderr.txt` or `microagent-timeout.txt` raised on a
  filesystem that refused it, and a `FileNotFoundError` out of a log write was recorded as
  a trial exception: the tree the agent changed was on disk and was scored as nothing,
  which is the outcome the timeout and exit-3 branches both exist to avoid. The parent
  directory is created, the write is attempted, and a failure is reported on the host
  where an operator is looking.

- The tool-call index test called `dropUnusableCalls`, which the unusable-call sweep was
  renamed away from, so the suite did not compile.

- A write through a chain of symlinks writes the file at the end of the chain
  rather than replacing the link in the middle of it. Only the first link was
  resolved, and the rename landed on whatever it named: where a path is a link
  to a link, as a version manager's `microagent` -> per-version binary is, the
  write went to a new regular file and both links were gone, so the file the
  user runs was the one never written. `write`, `edit` and `microagent update`
  all resolve the whole chain now, and a cycle is refused instead of followed
  for ever.
- A tool call the completion stream delivers twice is dispatched once. The
  stream is delivered at least once, and a relay that reconnects replays from
  the last event it saw, so one response can carry the same call under two
  indexes. The id is the only thing that says so, and every call was
  dispatched: `bash` ran the command twice, `write` and `edit` rewrote a file
  the first pass had already changed. The first is kept, the repeat is dropped
  and named on stderr, and the assistant message goes back naming each call
  once, so the tool results still pair one to one. Two calls that happen to be
  identical but carry different ids are still two calls.
- Tool calls a response carried and the run did not dispatch are now named on
  stderr. A call with no id, no name, or arguments cut mid-object, and a call
  at an index past the parallel-call ceiling, were all dropped: the first
  because it cannot go back to the provider inside the assistant message, the
  second because the call list is sized by index and an index past the ceiling
  would size it to billions. Neither was reported. The turn went on and finished
  as one that had run everything it was asked to, and the assistant message the
  provider reads next names only the calls that were kept, so the work was
  smaller than the work the model asked for with nothing on the operator's
  screen to connect the two. Both counts now travel with the turn and are said
  on one line, the way the duplicate above already was.
- A tool call is bounded by its timeout while it waits for the child, not only while it
  drains the child's pipes. Both pipes reach end of stream long before the command does,
  and the wait that followed took no deadline of its own, so
  `sh -c 'exec 1>&- 2>&-; sleep 600'` closed them at once and the call then blocked for
  the ten minutes the command asked for. The turn hung behind one tool call, the
  process-group reap on the way out never fired, and `--budget` was a promise the tools did
  not keep. The wait is now raced against the deadline the call was already given, and the
  group is signalled when it passes, so the call reports the same timeout a timeout during
  the drain reports. A command that exits first is not held to the poll interval or to its
  own timeout, and a single-threaded runtime, where the two cannot be raced, is refused
  loudly rather than blocking on the child the timeout was meant to bound.
- A session log this run could not name, and a key file whose path could not be built, now
  say so on stderr. The name, the allocation and the path join in the log's own open each
  returned a null the run could afford, which left a monitor reading a store that stayed
  empty with nothing to explain it, and a `~/.secrets/openrouter` this process could not
  even name was reported as no key at all rather than as a key out of reach. Each names
  the path that failed and the reason, the way every other way of losing the log already
  did.
- A character the transport split across two reads is no longer written to
  stdout in halves. The stream loop flushed each chunk as it arrived, and a
  chunk boundary is a byte boundary rather than a character one: a `日` split
  as `\xe6\x97` and `\xa5` reached the terminal as a replacement glyph followed
  by a broken byte, and a reader validating each write as text saw two
  fragments where there is one character. The loop now holds back the trailing
  bytes of an unfinished character, at most three of them, and writes them with
  the next chunk.
- The base url is escaped on its way to a stderr note. `--base-url` and
  `MICROAGENT_BASE_URL` are the operator's own bytes and every failure message
  names the url, so `MICROAGENT_BASE_URL=$'\e[2J...'` cleared the screen on the
  way to an error, and a base url that is not UTF-8 reached it as mojibake. The
  escaping is the one every other diagnostic quoting a value already uses, and
  the budget is wide enough that a url is never cut short of its endpoint.

- The `git` tool keeps its credential exclusions when the call names a path. It
  appended them only to a pathless `git show` or `git diff`, so `{"cmd":"show",
  "path":"."}` printed a committed `.env`, `.pem` or `.secrets/` file as a patch
  and handed the key to the provider. A path selects out of the diff; it does
  not narrow the commit, so the exclusions now travel with the path.
- A turn is no longer retried when the request never opened or never sent, unless the failure is
  one a second connection can answer. `OutOfMemory`, a refused `--ca-bundle` and a URL the client
  already refused were each attempted three times with a backoff, so a mistake this run made cost
  three seconds of sleeping before the same answer. `update` drew the line the same way.
- A session log record is written as soon as the model response lands, not after that turn's tool
  calls finish. A turn that builds or tests held the log for as long as the tools did, so a monitor
  following the run read a response minutes stale. The counters and the model time are unchanged.
- The session store pruner no longer deletes a name ending in a bare dash (`5-.jsonl`). Read as a
  plain log it sorted into the retention window as the oldest thing in the store, so a file this
  program never wrote was the first one the window removed.
- A `bash` call that printed nothing says which exit it was. The no-output line
  was `(no output, exit exited)`, and the note a call with output gets spells
  the number out, so a silent command that failed and one that succeeded
  returned the same line and the model had nothing to tell them apart by. It
  reads `(no output, exit exited 3)`, written by the same helper as the note, so
  the two spellings cannot drift apart again.
- A truncated tool result names the cap it was cut at, not the length that
  survived the cut. The cut backs up to the last whole character, so a result
  whose `max_tool_output`-th byte landed inside one kept up to three bytes fewer
  and the marker read `... [tool output truncated at 24573 of 25076 bytes]`,
  which puts the cut at a place it was not. It reads
  `... [tool output truncated at 24576 of 25076 bytes]`.
- A `git` result the byte cap cut short is marked. `git` is cut by a line count,
  and that count's marker was the only one it carried: a `show` or a `diff` the
  24 KB cap ended before the 400-line cap came back unmarked, and the model
  narrowed its next `git log` against a history it had never seen. A result the
  byte cap cut now carries the same `[output truncated at the tool's cap]` the
  other tools carry, and a result nothing cut says nothing.
- A `search` or `ast` result whose stderr the cap cut short is marked, the way
  one whose stdout was cut already was. The cap drains either stream, so a tool
  that wrote its findings nowhere and its warnings to stderr returned a list cut
  off mid-line with nothing on it to say so.
- A tool call past the parallel-call ceiling is counted once, not once per
  argument fragment. A provider streams a call as an id and a name and then as
  many argument fragments as its arguments need, every one repeating the same
  index, so a single call with long arguments past the ceiling was reported on
  stderr as a response asking for as many parallel calls as its arguments had
  bytes. The notice now names the calls.
- A `#` comment trails a key, a value and a table header in the reply-style
  config. The name of a `[style]` table was read off the whole header line, so a
  header labelled the way a person writes one, `[style] # how terse the replies
  are`, named no table at all: every key under it was reported as an unknown one
  and the level it asked for stayed at the default, which is a config that looks
  right and changes nothing. A bare value stops at the `#` for the same reason a
  quoted one does, and a `#` inside the quotes is still text.

- A subprocess tool that prints output and then fails reports its stderr and
  exit status alongside the output. The tool picked one stream and dropped the
  other, so a `search` that hit a permission error halfway returned only the
  matches it had found with nothing to say the search was partial, and a
  `git log` that failed halfway looked like a whole history. The exit status
  and stderr are now returned with the partial output.

- A `Retry-After` year too wide to be a date is refused, and a `Retry-After`
  count too wide to be milliseconds is the ceiling. Both were read anyway, and
  both are arithmetic on a header value the run has no control over. The date
  form counts days from 1970 and multiplies by 86 400, so a gateway that wrote
  the year field from a 64-bit counter put that multiply past the 64 bits it
  has: the instant it named then read as whatever the wrap left, which is a
  wait the opposite of the one the provider asked for. The count form scaled to
  milliseconds the same way, and a count it could not hold was treated as an
  unreadable header, dropping the run onto the 1 s, 2 s, 4 s backoff and back
  into the provider while the provider was still refusing. IMF-fixdate's year
  field is four digits wide and is now read as such, and a count that fits is
  clamped rather than discarded.
- `bench/gauntlet.sh` names a missing `gauntlet` and exits 2 instead of running
  the whole comparison. The tool was invoked by bare name, so on a host without
  it each review exited 127 into a log nothing reads, every count kept its
  default of zero, and the row was appended to `bench/gauntlet-results.jsonl` as
  a review that had run and found nothing, beside real rows in the same file.
- `GITHUB_TOKEN` no longer reaches a tool subprocess. The environment every
  tool runs under was scrubbed of the four variables the provider key is read
  from and nothing else, so an operator who had exported the token
  `microagent update` authenticates with, which this binary sends as an
  `Authorization` header, handed it to every child: `bash: printenv` put it in
  the tool result, and a tool result is re-sent to the provider on every turn
  after it. The scrub is now one list of every variable this binary reads a
  credential out of.
- `write` and `edit` refuse a credentials path, the way `read`, `search`,
  `ast`, `git` and `bash` already did. A run that cannot read `.env` or
  `$HOME/.secrets/openrouter` could still overwrite one, and the model chooses
  which tool to call: `write` replaces a file whole and `edit` reads it to find
  its match, so a path guessed from a file in the tree replaced the operator's
  working key with a placeholder and the next run could not authenticate. The
  refusal text for a writing tool names the operator rather than sending the
  model to `bash`, which refuses the same file.
- A `Retry-After` sent as an HTTP date is read, not ignored. RFC 9110 lets a
  server answer with either a count of seconds or an instant, and the run only
  read the first: a provider or a gateway that computed a deadline against its
  own clock had its header fall back to the 1 s, 2 s, 4 s backoff, so the run
  came back while the provider was still refusing, once per step, and each of
  those refusals was a billable one. The date is now turned into the wait it
  names, measured against the clock, clamped to the two minutes the run will sit
  out, and a date already past is a wait of zero rather than the backoff.
- The binary builds. `isTestRun` was handed a tool call's `args` where it reads
  a `[]const u8`, and `args` is the `ArrayList` the streamed fragments are
  appended to, so every optimized build failed to compile. The unit tests did
  not catch it because they pass string literals; `make check` and the release
  workflow both build the executable.
- A command-line argument quoted back in a usage error is quoted as text. The
  message used to cut it on a codepoint boundary and nothing else, so
  `microagent $'\e[2J'` cleared the terminal and `microagent update $'\e]0;x\a'`
  retitled the window, and a byte that is not text at all reached the screen as
  mojibake. Every such message now goes through the same escaping the gutter
  line and the config diagnostics already used, and the unknown-argument message,
  which quoted its argument directly, does too.
- A turn that could not fit the last character of a response says it is short. The
  16 MB ceiling is counted in bytes and cut on a codepoint boundary, so a response
  arriving with a byte or two of room and a character too wide for it kept none of
  it and the counter stopped short of the ceiling rather than reaching it. The
  notice read the counter, so that turn was reported as a whole one whose answer
  was missing a character nobody had been told about.
- A session directory that cannot be created, and a session log that cannot be
  opened, are named on stderr the way a log that cannot be written already was.
  `MICROAGENT_SESSION_DIR` a monitor is pointed at and the run cannot use (a
  read-only parent, a name no filesystem holds) left the store empty for the
  whole run and said nothing, so the monitor reported a run that never started.
- The Harbor adapter warns when the host has no CA bundle to upload, instead of
  letting the first request in a bare image die as `TlsInitializationFailed`
  with nothing in the job log naming the host that had none. The turn-ceiling
  and agent-timeout defaults it checks in `setup` and passes in `run` are
  spelled once each, so the two cannot drift apart.
- `HOME` is trimmed like every other variable, and an empty one is no home
  rather than a path off the root. The style config, the session store and the
  key file are all looked for under it, so the newline a wrapper exported from
  a file put every one of those a directory away, silently: a missing default
  config is not a fault worth reporting, and a missing key file is reported as
  no key.
- A turn that reaches the 16 MB per-response ceiling says so on stderr. Past it
  the streamed content and the streamed tool-call arguments are dropped rather
  than held, so a call whose arguments were cut arrived as
  `error: tool arguments are not valid JSON` and the run blamed the model for a
  truncation nothing had reported.
- A UTF-8 byte order mark ahead of a file's content is dropped where this program
  reads a file on the operator's behalf: the style config and the key file. The
  mark is invisible in the editor that writes it, so nothing on the way in looked
  like a mistake. A config carrying one named a key spelled `﻿caveman`, matched
  nothing, and left the level at its default while reporting an unknown key the
  operator never wrote; a key file carrying one sent U+FEFF to the provider as the
  first byte of the key.
- Text quoted back in a diagnostic escapes the C1 control range (U+0080..U+009F)
  as well as C0 and DEL. A terminal acts on U+009B (CSI) exactly as it does on
  ESC `[`, and UTF-8 spells that range as `C2 80..9F`, which is above the test
  that caught C0. The tool module's `terminalSafe` already escaped it; a config
  key, a flag or a repo name quoted through `chat.safeText` reached the same
  screen with the sequence intact.
- The README's benchmark commands lead with `make bench` and `make overhead`, the
  two targets that build `zig-out/bin/microagent` and put it on `PATH` for the run.
  The bare `bench/*.sh` form it documented first is the one that skips every
  harness by name on a fresh clone, so the documented command measured nothing.
  `make help` also described `lint` as the three linters, dropping the version and
  lock pin checks the target runs.
- A conversation of small tool results is still bounded. Compaction replaced a tool result with a
  marker only once it passed 4 KB, so a run whose tools answered in a kilobyte or two had nothing
  for it to replace: the conversation grew a turn at a time with no ceiling, and the run eventually
  asked for a context the provider refuses, which is a 400 nothing retries. A pass that elided
  nothing is now followed by one that replaces any result longer than its own marker, and both
  passes share the one size budget, so the conversation lands where the first pass alone would have
  put it. A conversation with no tool output at all to elide, which is the one case left, is now
  said on stderr rather than left growing silently.
- A base url that is not a url is refused as one. `--base-url api.openai.com/v1` and
  `MICROAGENT_BASE_URL` set the same way were reported as "the API key would go to ... in the
  clear", a security warning about a value that never reaches the network; the plaintext check
  still says what it says about a url that does parse.
- `MICROAGENT_SESSION_DIR` is trimmed before it is read, like every other environment value. A
  wrapper that populates the environment from a file exports the newline that file ended with, and
  a session directory carrying one is a directory the run created and the monitor never looks in,
  so the log it kept was a log nothing read. The reader now takes the environment map rather than
  the whole `Init`, so the trimming, the empty-means-off reading and the `$HOME` default are
  covered by a test rather than by the run that reads them.
- The session log is written in one place. `main.zig` carried a second, unused copy of the whole
  module, its own `MICROAGENT_SESSION_DIR` reader and its own copy of every session test, while the
  run itself used `session.zig`. The dead copy is removed, which is what let the live reader go
  untrimmed while a trimmed one sat beside it looking tested.
- The Harbor binary is the one the host can execute. `make musl` built
  `microagent-x86_64-linux-musl` and the adapter looked for that one name on
  every host, while Harbor runs the task container on the host's architecture:
  on Apple silicon or an arm64 Linux box the adapter reported a missing binary
  for a build that was sitting right there, and the x86_64 one would not have
  run in that container anyway. Both now name the host's architecture, read
  with `uname -m` (`arm64` and `amd64` mapped onto the release's spellings),
  and `make musl MUSL_ARCH=<arch>` builds another one. An x86_64 host is
  unaffected. The binary and the `.tmp` it is renamed from are now ignored, as
  `CONTRIBUTING.md` said they were.
- `bench/overhead.sh` takes its work directory away on a signal. The `rm -rf` was the last
  statement of the per-agent loop body, so an interrupted run, or one a harness made fail
  partway, left one `mktemp -d` directory per agent in the system temp directory and the next
  run started with the pile still there. A trap covers the ways out the last line does not
  reach, the way `bench/instructions.sh` already does.
- A release can no longer be published from a commit whose assets a rebuild would not reproduce.
  The byte-identical rebuild of every published target ran only in the push workflow, and a tag
  push matches no branch filter, so a tag cut on a commit no push had covered published binaries
  nothing had checked for reproducibility. The rebuild is a Makefile target
  (`make check-reproducible`) that the push workflow and the release workflow both run, and the
  release workflow's object-format check now reads the published target list from the Makefile
  instead of naming the four triples a second time, so a target added to the release is checked
  without a second edit to the workflow.
- `integrations/harbor/microagent_agent.py` is formatted the way `ruff format` writes it, so the
  `ruff format --check` step that `make lint-python` and CI both run passes. The file had drifted
  from the formatter after the log-formatting change above it, which left `make check` red on a
  clean checkout of this version.
- Text quoted back to the operator is now cut, bounded and printable through one helper,
  `chat.safeText`. A config key is whatever bytes a committed `config.toml` line held and a
  `--repo` is whatever the caller typed, and both went to stderr raw: a control character in
  either moved the operator's cursor and a byte that is not text reached the screen as
  mojibake, while a key could be the whole 64 KB config cap on one line. The tool gutter keeps
  the `\xNN` and U+FFFD spelling it had, through the shared helper.
- `search` and `ast` refuse a credentials file named as their `path`. The exclusion globs are
  traversal rules, and both backends read a file passed as the path whatever the globs say, so
  `{"pattern": "...", "path": ".env"}` returned the line with the key in it, and a tool result is
  re-sent to the provider on every later turn. The name is refused the way `read` and `git`
  refuse one, and the refusal names the tool that turned it down.
- A number the model wrote as something else is read as the number rather than as zero. `read`
  answered a `limit` of `"3"` with an empty result and an `offset` of `"5"` with the file from the
  top, `git log` a `limit` of `"12"` with one line, and `bash` a `timeout_ms` of `0`, a negative
  one or a `"60000"` with `command timed out after 0ms` without the command ever starting. A value
  that is no number at all falls back to the documented default.
- A session log in a subdirectory of the store is pruned where it is. The walker entered every
  subdirectory and reported a basename, which was then deleted through the store's root: a log
  under `archive/` left a newer root log deleted in its place while the run still writing to that
  name carried on into an unlinked file.
- A session directory that cannot be created is reported on stderr instead of silently leaving the
  run unrecorded, and a relative `MICROAGENT_SESSION_DIR` is opened the way the log file in it is
  rather than through an API that asserts the path is absolute and tripped that assert in a debug
  build.
- `microagent update --repo` accepts the longest `owner/name` its own validator allows. The URL
  buffer was six bytes short of it, so a legal repo was refused with the message a typo gets.
- `make preflight` names every tool the gate needs that a clean clone does not carry, with the
  command that installs it, and `make check` runs it before the format check and the suite. A
  clone without `shellcheck`, `ruff` or `yamllint` otherwise stopped at `make: ruff: No such
  file or directory` or `shellcheck: command not found`, after spending the gate's time on
  everything that did work.
- `make test-one` refuses a filter that matches no declared test name instead of running zero
  tests. `zig build test -Dtest-filter=...` reports `1/1 tests passed` for a filter that matches
  nothing, so a mistyped filter was a green run of no tests; the recipe now names the filter
  that matched nothing and prints the command that lists the names.
- `bench/instructions.sh` is the one bench script that cannot run on macOS at all, since
  `perf stat` is what reports the counter, and its refusal to run now says that rather
  than reporting a missing tool on a platform that will never ship one.
- `bench/instructions.sh` fails when a row cannot be measured instead of printing `not built` and
  passing. A test build that failed, a test renamed away and a `perf` that counted nothing all left
  no output, the row printed `not built`, and `--check` exited 0: the retired-instruction gate was
  green on a tree that did not compile. Each names itself and exits 2. Its rows also moved out of
  `/tmp/.instructions-rows.$$`, a predictable name in a world-writable directory, into the
  `mktemp -d` work directory the script already makes, so `TMPDIR` is honoured and two runs cannot
  collide.
- `make musl` copies the Harbor binary to a `.tmp` beside it and renames, so an interrupted copy
  cannot leave a truncated binary for the adapter to upload into every container. The `.tmp` is
  ignored with the binary it becomes, and `integrations/harbor/README.md` now says `make musl`
  instead of spelling the same two commands a second time.
- `bench/run.sh` and `bench/gauntlet.sh` skip a harness that is not on `PATH`, naming it on
  stderr, as `bench/overhead.sh` already did. They invoked each harness by bare name, so a first
  run on a machine without the binary built every task against an empty tree and appended a
  `fail(rc=127)` row per task to the committed `results.jsonl` and `gauntlet-results.jsonl`. A
  harness named with a model (`microagent:model`) is matched on the harness alone.
- `microagent update --repo` says what the flag wants. A value that is not `owner/name` was reported
  as `want owner/repo, not a URL`, which described one guess at the mistake: an empty value, a second
  slash and a pasted URL are three typos with one answer, and only the last is a URL. The message is
  `--repo must be owner/name, got '<value>'`, the way every other flag here names itself and the
  value it was given. An empty value (`--repo=` or `--repo ""`) is now refused where it is parsed, the
  same as a `--repo` that ends the command line, instead of being sent to the API first.
- An empty word on the command line (`microagent ""`) is reported as an empty prompt rather than as
  `unknown or incomplete argument ''`, which described a flag nobody wrote. Still exit 2, still with
  the reason and the help on stderr.
- `microagent --help` states the output contract: stdout carries the model's text and one
  `{"type":"usage",...}` line per response and nothing else, stderr carries the tool gutter, the notes
  and every error. The README said it; the help a script author reads first did not.
- The exit status for an interrupt, 130, is in `--help` and in the README beside the 0, 1 and 2
  they already named. The run has exited 130 since Ctrl+C and `kill` took the tool subprocess
  with it, and a script that reads the exit status could only find the code in the source.
- The session-close test helper named `ChatResult` without the module it lives in, so no build
  compiled: `zig build` and `make build` failed on the whole program, not only on a test.
- A tool call is now cut off by its deadline rather than by how long it stayed quiet. Both runners
  wait on the child's pipes in a loop, and the timeout was handed to each wait as a fresh duration,
  so every read that arrived re-armed it: a command that keeps writing (a verbose build, a `yes` in
  a test) never reached the end of the timeout and ran until the run's own budget or the harness
  killed it, which also made `--budget` a promise the tools did not keep. The timeout is now an
  instant taken once, and a child that closed its pipes and kept running is caught by the same
  deadline. A tool call that times out says the same thing and leaves the same processes killed as
  before.
- `--budget 0` and `MICROAGENT_BUDGET_SECONDS=0` are refused the way a ceiling of zero is. The
  deadline zero builds has already passed when the loop first asks, so the run took one final push
  turn, paid for it, and stopped, which reads as a provider that went quiet rather than the zero
  that was asked for.
- `write` refuses a call with no `content` instead of writing an empty file. The tool schema names
  `content` as required, but the argument was read as an empty string when it was missing, so a call
  that arrived naming only a path (a model that forgot it, or arguments cut short in the stream)
  opened the file for writing and emptied what was there, and a `write` is the one tool call a run
  cannot undo. A model that means an empty file says so, as `"content": ""`. The result changes from
  `wrote 0 bytes to <path>` to `error: missing content` in that one case.
- A config line with nothing before its `=` names no key, and the style reader no longer reports
  one. `= "lite"` was read as a key of zero length, so the run reported an unreadable config with
  a blank key on stderr.
- `read` refuses a credentials file. Its result goes into the conversation, and the conversation is
  re-sent to the provider on every turn after it, so a `read` of `.env`, a `.pem`, an `id_ed25519`
  or `$HOME/.secrets/openrouter` shipped a live key to a third party and kept shipping it for the
  rest of the run. The rule is one on the name: any path component that is `.secrets` or `.ssh`, and
  any file named `.env*` or `*env`, a private key (`id_rsa`, `id_ed25519`, `identity`), a key or
  keystore extension (`.pem`, `.key`, `.p12`, `.jks`, ...), or a dotfile credential (`.netrc`,
  `.pgpass`, `.npmrc`, `.git-credentials`, `credentials`). It matches case-insensitively, because a
  macOS or Windows filesystem resolves `.ENV` to the same bytes as `.env`. The refusal names the file
  and says what to do instead; the system prompt tells the model not to ask for one. `bash` still
  reaches any file.
- `write` and `edit` replace the file they change instead of truncating it. `Dir.writeFile`
  opens the destination with `O_TRUNC` and writes into it, so a full disk, a signal or a limit
  part way through left the model reading a source file shorter than it was, with the bytes
  that were there gone. The bytes now go to a temporary file beside the destination and a
  rename puts them in place, the way `update` already replaced the binary. A symlink is
  followed to the file it names, so writing through one does not turn the link into a regular
  file, and the destination's own mode is carried over rather than reset by the rename.
- The `max_response_bytes` ceiling is per response rather than per stream. It was applied to
  the visible text and to each call's arguments separately, so a provider that streamed the
  full allowance for each of `max_tool_calls` calls could hold a gigabyte in one turn. One
  counter now covers the whole response.
- `make overhead` drives each harness through the command line it accepts. It passed a bare
  `-p` to every CLI on PATH, which `codex`, `crush` and `opencode` refuse, so their rows measured
  a failed invocation rather than a first request. The per-harness spelling now lives in
  `bench/harness.sh` and both bench scripts read it, where `bench/run.sh` already had it.
- The session store prunes the logs a re-run wrote beside the first. A run that read the same
  clock stamp opened its log under a `<unix-ns>-N.jsonl` name rather than truncating the one
  already there, and the pruner only recognised `<unix-ns>.jsonl`, so on a machine whose clock
  repeats a stamp every one of those logs stayed forever while the store reported itself
  pruned. Both names count now, and the old are dropped by the same bound.
- A stream frame's `finish_reason` is no longer dropped. The declared-shape parse, the fast
  path every OpenAI-style frame takes, did not carry the field, so a response the provider cut
  at `max_tokens` arrived with no reason at all and the turn ended looking like a finished
  answer. The generic parse still reads it; the fast path reads it now too.
- Ctrl+C and `kill` now take the tool subprocess with them. A tool child leads its own process
  group so its tree can be reaped, which is also where the terminal's interrupt does not reach: the
  agent died and the build it had launched kept running and writing files. The run now forwards
  SIGINT and SIGTERM to the group in flight and exits 130.
- A config file named by `--config` or `MICROAGENT_CONFIG` that cannot be read says so on stderr.
  A flag naming a file that is not there was read as a run with the built-in reply style and no
  word about it. The default `~/.microagent/config.toml`, missing on most machines, stays quiet.
- A `~/.secrets/openrouter` that is present and empty now says so. It was read as no key at all, so
  the file being there, which is the reason a user believes a key is set, went unreported. The
  no-key error names that file alongside the four variables.
- `microagent update --repo` with a value that is not `owner/name` now prints the usage text with
  its reason, as every other update usage error does. It exited 2 with one line and broke the
  promise the update help makes.
- A session log that cannot be written to is named and dropped, instead of failing silently once
  per turn. Opening the log was already a null the run could afford to lose; writing to it was not:
  a full disk or a session directory removed under a running review left the monitor reading a run
  that had stopped, with nothing on the operator's screen to say so. The run says once that the rest
  of it is unrecorded and stops writing.
- `microagent update` names the HTTP status when an asset or sidecar download is refused. The
  release lookup has always reported the code and its hint, so a rate-limited download read as
  `could not download microagent-... (HttpStatus)`; the asset and the sidecar now report what the
  lookup reports. A failed replacement names the binary path it would have replaced.
- Every retried provider request says which endpoint and which step failed, and a retryable status
  says it is being retried. The lines went out through `std.debug.print` with no URL and no status,
  so a provider that dropped three connections and answered the fourth looked like a run that merely
  took longer.
- The exit-1 line names the base url the run failed against, with any credentials in it redacted.
  A DNS failure, a refused connection and a truncated stream all reached it as a bare error name.
- A conversation that cannot be read back for compaction says so. The buffer is one the program
  wrote, and the silent skip meant a run whose prompt kept growing turn after turn with no sign of
  why.
- A tool result reading `error: OutOfMemory` names the tool that ran out.
- `elapsed_ms` in a session record is the model's time again. It was measured after the turn's tool
  calls had run, so it reported a gap that included them, and a monitor dividing a response's tokens
  by it got a rate for a generation that was never continuous. It is now taken when the completion
  stream ends, before the tools run.
- A tool call now takes its whole process tree down with it. The subprocess tools spawned their
  child in the caller's process group, so the signal sent on a timeout, on a capture cap or on a
  normal exit reached only the shell: a command that backgrounded work, or ran past its deadline
  holding the pipes open, left the build, test server or compiler it had started running on, holding
  a port, a build cache or a lock for every later turn of the run and for whatever started next.
  Each child now leads its own process group, and the group is signalled on every exit path, through
  the one `ToolProcess` the `bash`, `search`, `ast` and `git` tools share.
- A streamed tool call's name and id are released with the rest of the response. They are copies
  the run allocator owns, and only the argument buffer was handed back, so a long run leaked two
  small strings per call.
- A `bash` call the model gave a `timeout_ms` of zero, a negative, or something unparsable is no
  longer killed before it starts. Those all read as 0, and a zero duration is a deadline that has
  already passed, so every such command returned `command timed out after 0ms`. A value that is not
  a positive count of milliseconds is now no request at all, and takes the tool's own default.
- A streamed tool call's index is clamped the way every other provider-sent number already was. The
  declared-shape fast path narrowed the `u64` `num` returns straight to `usize` before the cap was
  applied, so an index past a 32-bit `usize` trapped a checked build and wrapped a release one onto
  a live call slot; the read offsets and the git line limit went through the clamping helper for
  exactly this reason.
- The loopback exemption for a plaintext base url checks that every octet is in range. `127.256.0.1`
  is not an address, so a resolver is what answers a name spelled that way, and the exemption sent
  the API key to whatever it named.
- `--budget` and `MICROAGENT_BUDGET_SECONDS` take a value with surrounding whitespace, as
  `--max-turns` and `MICROAGENT_MAX_TURNS` already did. `export MICROAGENT_BUDGET_SECONDS="$(cat f)"`
  kept a trailing newline and was refused where the other ceilings were not.
- The time budget is now a deadline the turn is held to, not a check between turns. `--budget` was
  only read at the top of the tool loop, so a provider that was slow rather than broken handed the
  run one long turn, the budget was never asked again, and the run was killed in the middle of the
  turn the budget exists to avoid. It is now checked between stream reads and before each tool call:
  a turn cut off that way is discarded rather than half-appended, tool calls the budget will not pay
  for get a tool result saying so, and the one final push is allowed 5 minutes past the budget so it
  is bounded too.
- A response cut at `--max-tokens` is no longer reported as a finished answer. The provider sends
  `finish_reason: "length"` with a clean terminator, so nothing in the run could tell a complete
  turn from the prefix of one, and a tool call whose arguments were cut mid-JSON looked like one the
  model had finished sending. The reason is read from the stream, noted on stderr, and recorded per
  response in the session log as `finish_reason`.
- A `bash` call can no longer run without a deadline. `timeout_ms` is model output and was taken as
  sent, so a value past anything a run survives left the child with no timeout at all and the
  process-group kill that reaps it never fired. It is now capped at 600 s, with the 120 s default
  unchanged, and the schema says so.
- Bytes that are not UTF-8 no longer corrupt a request. Text from a tool result, a file, the working
  directory or `argv` is written into JSON as-is, so one latin-1 source file or stray `0xFF` byte made
  the whole request body unparseable and the provider answered 400, failing the turn over output the
  agent had already collected. Each bad byte is now written as U+FFFD and the rest of the string is
  unchanged.
- A configuration value that is set to an empty string is no longer read as a value. `MICROAGENT_MODEL`,
  `MICROAGENT_BASE_URL`, `MICROAGENT_REASONING_EFFORT`, `MICROAGENT_BUDGET_SECONDS` and `MDEBUG` keep
  their defaults, and `MICROAGENT_CAVEMAN`/`MICROAGENT_PONYTAIL` fall through to the config file
  instead of reporting a level that is not one. `MICROAGENT_CA_BUNDLE` and the api-key variables
  already worked this way. Before, an exported-but-empty `MICROAGENT_MODEL` sent `"model": ""`.
- `--reasoning-effort` and `MICROAGENT_REASONING_EFFORT` are checked against the documented levels
  where they are set. An unknown level used to reach the provider and come back as a 400 after a turn
  had been spent.
- `--max-turns 0` and `MICROAGENT_MAX_TURNS=0` are refused. A ceiling of zero started no turn at all:
  no request, no answer, no usage line, exit 0, which a harness reads as a finished review.
- The numbers a flag and a variable share are read through one check, and the message names the
  offending value: `--budget`, `--max-turns`, `MICROAGENT_BUDGET_SECONDS`, `MICROAGENT_MAX_TURNS`.
- A key the reply-style config does not define is reported on stderr, the way a value that is not a
  level already was. A misspelled `caveman` used to leave the default in force with nothing said.
- `MDEBUG=0` (also `off`, `no`, `false`, and empty) no longer turns the stream trace on. The variable
  was set-at-all, so a wrapper that exports the name to pass a flag it has not set got the trace.
- The missing-api-key message named two of the four variables that satisfy it, and the harbor adapter
  read three of the four; both now name the same list, `DEEPSEEK_API_KEY` included. The adapter's
  own `RuntimeError` named only two of the four it reads, so it says the same list as the binary.
- The harbor adapter treats an empty `MICROAGENT_BASE_URL`, `MICROAGENT_BUDGET_SECONDS` or
  `MICROAGENT_MAX_TURNS` as unset, and a non-numeric one names the variable instead of raising a
  `ValueError` out of `int()`.
- `bash`, `search`, `ast` and `git` kept their output only while it stayed under the capture cap.
  Past it, the run aborted with `StreamTooLong` and handed the model a bare error instead of the text, so
  a chatty build, a `rg` over a large tree and a `git show` of a big file all came back as nothing found.
  The output past the cap is now drained and dropped, the child still runs to its own end so its exit
  status and timeout mean what they did, and `bash` says when its output was cut.
- The `--max-turns` ceiling note said "last turn" on the second-to-last turn, one turn before the turn
  it describes.
- A reply-style level the parser does not recognize no longer costs the run the levels it did
  understand: a bad `MICROAGENT_CAVEMAN` left `MICROAGENT_PONYTAIL` unapplied, and a bad key in the
  config file hid every key after it.
- A streamed tool call whose `index` skipped a slot left a nameless call in the list, which was sent
  back as an assistant tool call with no function name and rejected by the next request. The gap is
  dropped.
- `microagent update` compares the running version and the published tag with one leading `v` ignored on
  both sides. It ignored the prefix on the tag only, so a `v`-prefixed running version never matched a
  `v`-prefixed tag.
- `--budget` and `MICROAGENT_BUDGET_SECONDS` trim the value, as `--max-turns`, `--max-tokens` and the
  reasoning level already did. A number quoted with a space around it was reported as not a number.
- A `git` `limit` of 0 returned the whole output rather than no lines: the loop that stops at the limit
  never reaches a limit of zero, so the cap fell open. It is one line now, and a count a 32-bit build
  cannot hold (`read`'s `offset` and `limit` too) is clamped rather than trapping the cast.
- The loop kept going after a turn that asked for a tool. `.wants_tools` returned out of the run
  the way `.cut_off` does, so the run ended on the first turn that called a tool, which is every
  turn of a run that does any work: the tool results were appended to the conversation and then
  nothing ever sent the request that would have read them. The next iteration asks again, and the
  turn ceiling and the budget are the two things that still end a run.
- A backoff that could not be taken is no longer reported as one. Both the retry path and the
  `Retry-After` wait caught the sleep failure and carried on, so the attempt after a 429 went out
  immediately, which is the one thing the header asked the run not to do, and the line above it had
  already promised a delay. The attempt is abandoned instead, and the reason is named on stderr.
- A token count the provider spelled as something other than a number is counted rather than folded
  in as a zero. `maybeNum` dropped such a field silently, so a stream that carried `900` and then
  `"many"` reported the total the provider never sent, and a monitor billing from the usage line
  read it as a run that spent nothing. The count the provider really sent stays, the frame is
  counted as unreadable, and the existing note now says a frame can be unreadable in its counts as
  well as its JSON.
- A key file this process cannot read is named, rather than read as no key. `readSecret` answered
  only found-or-absent, so a file whose permissions or ownership stopped the run reading it was
  reported as absent and the run went on to print the missing-api-key message naming a key to go
  and find. It now answers unreadable as well, with the reason, and the run says the file may hold
  a key it cannot reach.
- The session store's quiet failures are named. A store that could not be opened for pruning, a
  walk that failed part way, a delete that failed and a run that used up its eight log names each
  returned as nothing: the store stayed over its limit while every later run pruned nothing and
  said nothing, and the log going missing looked the same as a log the operator turned off. The
  pruning pass is abandoned whole when the walk fails, because pruning from a partial list deletes
  whichever logs it saw rather than the oldest ones, and the failures that leave the store over
  its limit are counted and named once.

- A `rev` beginning with `-` in a `git` tool call (`git show -3`) was read as an option instead of a
  revision.
- Tool results and assistant text are JSON-escaped, so a diff containing quotes, backslashes or control
  characters no longer corrupts the request body.
- A streamed tool call whose `index` is past the cap is dropped instead of growing the pending-call list
  to that index, which a hostile or broken provider could turn into a multi-gigabyte allocation.
- `microagent update` compares versions instead of testing string equality, so a build ahead of the
  latest published tag (a branch after a version bump, before the release) reports that there is
  nothing to install rather than downgrading itself to the older release. A tag that is not a dotted
  `major.minor.patch` still installs, so tracking a fork whose tags are not versions keeps working.

### Security

- A credentials file named as the `git` tool's `rev` is refused, the way one
  named as its `path` already was. The `:(exclude)` pathspecs the tool carries
  are arguments after the `--`, so they scope a revision the model named and
  never a name it did not: `git blame .env` took the name as its one revision
  argument and printed the file line by line with its hash and author, and
  `git diff .env` printed the committed and working-tree text of every hunk. A
  tool result is re-sent to the provider on every later turn. The tool's own
  description now says the `rev` is refused too, so the model is not asked for
  one.

- A session log is created readable by its owner alone, and the directory a run makes for
  its own store with it. A log took the default file mode, `0o666` less the umask, so on the
  `0o022` an ordinary account carries it landed world-readable under `$HOME`, and the store
  directory it was made in took `0o755` and exposed the names of the logs even where the logs
  themselves could not be read. A log is the run's transcript: the prompts, the tool
  arguments, and every byte a tool read out of the tree, which is the material the tools
  themselves refuse to hand the provider. The modes are now `0o600` and `0o700`, and only on
  what this run creates: an operator who pointed `MICROAGENT_SESSION_DIR` at a store that
  already exists keeps the mode they gave it. `docs/threat-model.md` records the two modes as
  controls, and its `src/session.zig` references point at the declarations they name again.

- A path whose symlink lands on a credentials file is refused, by the same rule and
  the same message as one named outright. The name rule reads the bytes the model sent,
  and a repository can commit a link whose own name is ordinary and whose target is a
  credential: `docs/setup.md -> /home/someone/.aws/credentials` passed every check
  `read`, `write`, `edit`, `search` and `ast` make, and each of them follows the link
  when it opens the path. So the key came back as a tool result that is re-sent to the
  provider on every later turn, and a `write` through the same link replaced the
  operator's key with the model's guess. `read`, `write`, `edit`, `search` and `ast` now
  ask the name rule of the path the link resolves to as well, and name that file in the
  refusal. A link to an ordinary file is still followed and still read, so the cost is
  one readlink per call and the tools are otherwise unchanged.

- The published binaries are linked position-independent. A fixed-address executable is mapped at
  the same place on every run, so an address an attacker learns once is an address every run
  uses; PIE moves the image to wherever this run's layout puts it. Full RELRO and a
  non-executable stack were already the linker's defaults here, so this is the last of the three
  the linker can give without a libc. There is still no stack canary: Zig's
  `-fstack-protector` needs a libc to reach `__stack_chk_fail` through, and nothing links one.
- `search` and `ast` skip the credential files `read` refuses, and `git` refuses one named as a
  path. A tool result is re-sent to the provider on every later turn, so a `search` that matched a
  line of `.env`, a `server.pem` or `$HOME/.secrets/openrouter`, or a `git show` that printed one
  as a patch, shipped a key exactly as a `read` of it would have. The exclusions are built from
  the same name, extension and directory tables the refusal reads, and `search` matches them
  case-insensitively, the way the refusal does.
- The two stderr notes that end a turn early now print the redacted endpoint. The time-budget note
  and the generation-ceiling note named the raw base url, so a `user:password@` credential a user
  put in one reached the terminal on those two paths, while every other note went through the
  redacting helper.
- The system prompt now says that tool results, file contents and command output are data about the
  repository rather than instructions. They are untrusted text on their way back into the prompt, and
  a file in the tree could otherwise instruct the model through the tool that read it.
- The stderr tool gutter stays one line. A model that puts a newline or an escape sequence in a path,
  pattern or command broke the `⏺ tool detail` shape a reader parses, and could drive the reader's
  terminal with an escape sequence; control characters are now written as `\xNN`.
- `microagent update` sends `GITHUB_TOKEN` to the releases API only. The token exists to lift the
  anonymous rate limit, and the release asset and its `.sha256` sidecar are public files that GitHub's
  asset host serves unauthenticated, so a token carrying repository scope was being presented to a
  host the download never needed to authenticate to. Both URLs already passed the GitHub host
  allowlist, so this narrows the grant rather than the hosts it is allowed to reach.
- The release tag and asset name reach stderr through the same quoting a `--repo` argument gets. Both
  are the release body's own bytes, and a tag carrying ESC, BEL or a C1 control put an escape sequence
  on the operator's terminal through the version line, the missing-asset message, the sidecar note and
  both download failures. The decision still reads the bytes the body carried, so a release is neither
  refused nor matched on a name this quoting changed.

## [0.1.1] - 2026-09-28

### Fixed

- `microagent update` on a glibc build asked for an `x86_64-linux-gnu` asset the release never
  publishes, so the install failed. Linux now asks for the static musl asset, which runs on a glibc host
  as well. macOS asset names are unchanged.

## [0.1.0] - 2026-09-28

First release.

### Added

- The agent loop: streaming chat completions against any OpenAI-compatible endpoint, with a tool loop and
  a turn ceiling.
- Six tools: `bash`, `read`, `write`, `edit`, `search` (ripgrep) and `ast` (ast-grep structural search
  and rewrite). The `git` tool arrived in 0.2.0.
- A positional prompt, so a gauntlet agent definition of `["microagent", "{prompt}"]` works in any flag
  order.
- `--budget`, `--reasoning-effort`, `--ca-bundle`, and `MICROAGENT_BUDGET_SECONDS`,
  `MICROAGENT_REASONING_EFFORT`, `MICROAGENT_CA_BUNDLE`, `SSL_CERT_FILE`.
- Retries: a 429, any 5xx or a dropped connection is retried twice with 1 s and 2 s of backoff; a
  rejected request fails immediately.
- Old tool output is elided once the conversation grows, so a long run's prompt stays inside the
  provider's window instead of re-sending every earlier result.
- A session log at `~/.microagent/sessions/<unix-ns>.jsonl` (`MICROAGENT_SESSION_DIR` moves it, an
  empty value turns it off), carrying one record per model response so a monitor can read tokens per
  second while the run is going.
- `microagent update`, which replaces the running binary from the latest GitHub release after checking the
  asset against its `.sha256` sidecar.
- A release workflow that publishes `x86_64-linux-musl`, `aarch64-linux-musl`, `x86_64-macos` and
  `aarch64-macos` with a checksum sidecar each, and refuses a tag that does not name the version in
  `build.zig.zon`.

[Unreleased]: https://github.com/maci0/microagent/compare/v0.7.0...HEAD
[0.7.0]: https://github.com/maci0/microagent/compare/v0.6.0...v0.7.0
[0.6.0]: https://github.com/maci0/microagent/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/maci0/microagent/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/maci0/microagent/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/maci0/microagent/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/maci0/microagent/compare/v0.1.1...v0.2.0
[0.1.1]: https://github.com/maci0/microagent/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/maci0/microagent/releases/tag/v0.1.0
