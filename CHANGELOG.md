# Changelog

All notable changes to microagent, in the order a consumer meets them. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project follows [SemVer](https://semver.org)
from `0.1.0`: under `0.y` the minor carries features and changes that alter a run's default behavior, the
patch carries fixes, and a patch never changes what an existing invocation does. The version lives in
`build.zig.zon` and nothing else declares it; `microagent --version` prints it, and the release workflow
refuses to publish a tag that does not name it.

Only the latest release is supported. There is no backport window and no LTS line: a fix ships in the next
release, and `microagent update` moves you to it.

## [Unreleased]

### Added

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
- `THREAT_MODEL.md`: the attack surface as a whole, entry points, trust boundaries, assets,
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
- `MDEBUG=1` prints the configuration the run resolved: model, base url, the ceilings, the level
  each style key took, and the name of the variable or file the API key came from. The key is never
  printed and a base url is the redacted spelling. Precedence spans three sources per option, and
  there was no way to see which one answered.
- `config.example.toml` is a commented template for the reply-style file, with both keys, their
  levels and their defaults.

### Changed

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
  time, so the pair that produced a number in `BENCHMARK.md` was not the pair the next run
  installed.
- A style config that is present but unreadable, is a directory, or is over the 64 KB cap says so on
  stderr, not only one a flag or `MICROAGENT_CONFIG` named. A file that is simply absent stays quiet.
- `GITHUB_TOKEN` is trimmed before it becomes an `Authorization` header, like the provider key file
  is. A token a wrapper read from a file arrived carrying that file's trailing newline, and GitHub
  refused it as an invalid credential rather than as a whitespace mistake. `microagent update --help`
  now names the two CA-bundle variables it already read.
- The Harbor adapter validates `MICROAGENT_BUDGET_SECONDS` before the container starts, and refuses
  a zero value for every ceiling it reads, which is what its README already promised.
- CI restores the Zig build caches between runs, from the shared toolchain action, so a push no
  longer pays for compiling the compiler cache and `std` from scratch on a cold runner. The
  global cache is moved under `RUNNER_TEMP`, whose default path differs per runner OS.
- The published targets and their asset names are spelled once, in the Makefile, as
  `make release-assets TAG=v0.2.0`. `ci.yml` rehearses the release with that target and
  `release.yml` publishes what it builds, so a release can be built on a laptop the way the tag
  builds it, and a renamed target no longer has to be renamed in two workflows.
- `microagent --help` carries three worked invocations, and its subcommand line spells the flag
  the way `microagent update --help` does (`update [--check]`, not `update [-c|--check]`).

### Fixed

- `read` refuses a credentials file. Its result goes into the conversation, and the conversation is
  re-sent to the provider on every turn after it, so a `read` of `.env`, a `.pem`, an `id_ed25519`
  or `$HOME/.secrets/openrouter` shipped a live key to a third party and kept shipping it for the
  rest of the run. The refusal names the file and says what to do instead; the system prompt tells
  the model not to ask for one. `bash` still reaches any file.
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

### Security

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

## [0.2.0] - 2026-09-29

### Added

- `git` tool: read-only `status`, `diff`, `log`, `show` and `blame` with a fixed subcommand list and a
  400-line cap, so git state no longer has to be assembled by the model through `bash`.
- Reply styles. `caveman` sets how terse the agent's own prose is (`off`, `lite`, `full`, `ultra`, and the
  three `wenyan-*` levels) and `ponytail` sets how lazy the code is (`off`, `lite`, `full`, `ultra`). Both
  are read from `$MICROAGENT_CONFIG`, else `~/.microagent/config.toml`, and both have an env override
  (`MICROAGENT_CAVEMAN`, `MICROAGENT_PONYTAIL`). Neither touches the tools, the request shape or the
  conversation: each appends text to the system prompt. With `caveman = "off"` and `ponytail = "off"` the
  system prompt is byte for byte the one `0.1.1` sent.
- `cached_tokens` on the stdout usage line and in each session-log record: the part of the prompt the
  provider served from its prompt cache, read from `prompt_tokens_details.cached_tokens`,
  `prompt_cache_hit_tokens` or `cache_read_input_tokens`. Both are additive JSON keys, so a reader that
  looks up the counters it already knows is unaffected.

### Changed

- `--max-turns` now defaults to 100 (was 60). A run that relied on stopping at 60 turns now gets the
  longer loop; pass `--max-turns 60` to keep the old ceiling.
- Replies are terse by default: `caveman` is `ultra` and `ponytail` is `full` unless the config or env
  says otherwise. A run that wants the prose back sets `caveman = "off"`.

### Fixed

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

[Unreleased]: https://github.com/maci0/microagent/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/maci0/microagent/compare/v0.1.1...v0.2.0
[0.1.1]: https://github.com/maci0/microagent/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/maci0/microagent/releases/tag/v0.1.0
