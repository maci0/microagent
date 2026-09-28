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
- Stale `path:line` references in `THREAT_MODEL.md` now point at the functions they name; the
  gutter and `terminalSafe` rows had been citing the dispatcher above them.
- `MDEBUG=1` prints the configuration the run resolved: model, base url, the ceilings, the level
  each style key took, and the name of the variable or file the API key came from. The key is never
  printed and a base url is the redacted spelling. Precedence spans three sources per option, and
  there was no way to see which one answered.
- `config.example.toml` is a commented template for the reply-style file, with both keys, their
  levels and their defaults.
- `PERFORMANCE.md`: what a turn costs inside the harness itself, the four changes that bought
  what they bought, and the four that were measured and left out, so the next round reads the
  refusals rather than re-running the experiment. `BENCHMARK.md` still says what the harness
  measures against other harnesses.

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
  benchmark whose results BENCHMARK.md publishes, beside the `make bench` and
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
  time, so the pair that produced a number in `BENCHMARK.md` was not the pair the next run
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

### Removed

- The second copy of the session store in `main.zig`. The run opens, writes and closes its log
  through `src/session.zig`; `main.zig` kept a parallel `Session` type, its own
  `createSessionLog`, `pruneSessions` and `sessionRecord`, and a `sessionDir` no call reached, so
  one file-owning store was spelled twice and only one of them was ever run. The tests beside the
  dead copy were duplicates of the ones in `session.zig`, which keep every assertion.

### Fixed

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

[Unreleased]: https://github.com/maci0/microagent/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/maci0/microagent/compare/v0.1.1...v0.2.0
[0.1.1]: https://github.com/maci0/microagent/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/maci0/microagent/releases/tag/v0.1.0
