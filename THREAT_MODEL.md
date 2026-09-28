# Threat model

What can be attacked in microagent, from where, and what stands in the way. Every entry
below carries a file reference so the next pass can re-verify it against the code rather
than against this document.

Last reviewed: 2026-09-29, against `0.2.0` (`build.zig.zon`) and the `Unreleased` section
of `CHANGELOG.md`.

## Summary, risk-ranked

| # | Threat | Boundary | Exploitability | Impact | Control today |
| --- | --- | --- | --- | --- | --- |
| 1 | Repository content drives shell execution | repo → model → host | high: any content the model reads can carry an instruction | full compromise of the operator's account, its files and its keys | prompt wording only (`src/main.zig:88`); no mechanical control (gap 1) |
| 2 | The provider's reply drives shell execution | provider → host | medium: needs a hostile, coerced or MITM'd endpoint | same as 1 | redirect refused (`src/main.zig:1299`), response caps, timeouts, `bash` timeout ceiling (`src/tool.zig:41`) |
| 3 | The API key is sent to the host the environment names | agent → provider | medium: any `https` host is accepted | provider account takeover, bill abuse | plaintext `http` refused off loopback (`src/main.zig:446`, enforced at `src/main.zig:207`) |
| 4 | Tools read and write outside the working tree | model → filesystem | high: `read`/`write`/`edit` take any path | read or overwrite `~/.ssh`, `~/.aws`, CI tokens | `read` refuses a credentials file (`src/tool.zig:529`); `write`/`edit` still take any path |
| 5 | Tool output carries credentials to the model and on to the provider | host → model → provider | low: a credential under a name the rules do not know, or reached through shell indirection | secret exfiltration through a routine run | `read` refuses, `search` and `ast` skip, `git` refuses by path, `bash` refuses a command naming one (`src/tool.zig:562`, `src/tool.zig:247`, `src/tool.zig:411`); the run's own key is not in a tool's environment to print (`src/main.zig:692`) |
| 6 | A compromised release replaces the binary | GitHub → host | low: needs the release account or its token | persistent, silent code execution on every later run | sha256 sidecar, host allowlist (`src/update.zig:211`, `src/update.zig:175`) |
| 7 | The API key is visible in the process table | operator → host | low: needs a local reader | key theft by any other process or user on the box | none |
| 8 | A hostile or malformed provider response exhausts memory or CPU | provider → agent | medium | run killed, machine memory spent | per-response cap (`src/main.zig:58`), frame cap (`src/main.zig:67`), timeouts, process-group kill |
| 9 | A hostile repository writes escape sequences to the operator's terminal | repo → terminal | high: any file the model echoes | terminal spoofing, clipboard tricks | control bytes escaped in the gutter (`src/tool.zig:72`) and scrubbed in error text (`src/tool.zig:359`) |
| 10 | A hostile model result spends the operator's money | model → provider | medium: a runaway or looping run | unbounded bill on the provider account | per-request `max_tokens` (`src/main.zig:48`), turn and wall-clock ceilings; no spend limit (gap 6) |

`microagent` is a local CLI with no listener, no server and no database. It holds no user
data of its own: what it exposes is the operator's own machine, and what an attacker wants
is the key, the source tree and the host. The one place it holds something worth stealing
on its own is the API key.

## Attack surface

### Entry points in the code

| Entry point | What arrives | Handled at |
| --- | --- | --- |
| Command line, agent mode | prompt, flags, api key in `argv` | `src/main.zig:605` (`parseArgs`), `src/main.zig:145` (`main`) |
| Command line, `update` | `--check`, `--repo` | `src/update.zig:590` (`parseArgs`), `src/update.zig:620` (`run`), dispatched at `src/main.zig:158` |
| `MICROAGENT_MODEL`, `MICROAGENT_BASE_URL`, `MICROAGENT_REASONING_EFFORT` | endpoint, model, response style | `src/main.zig:381` (`envValue`) |
| `MICROAGENT_MAX_TURNS`, `MICROAGENT_MAX_TOKENS` | loop and response ceilings | `src/main.zig:40`, `src/main.zig:48`, both through `ceiling` at `src/main.zig:426` |
| `MICROAGENT_API_KEY`, `OPENAI_API_KEY`, `OPENROUTER_API_KEY`, `DEEPSEEK_API_KEY` | provider credential | `src/main.zig:694` (`key_vars`), resolved at `src/main.zig:676` (`resolveKey`) |
| `~/.secrets/openrouter` | provider credential, up to 4 KB | `src/main.zig:680` (path), read by `src/tool.zig:105` (`readSecret`), cap at `src/tool.zig:29` |
| `MICROAGENT_CA_BUNDLE`, `SSL_CERT_FILE` | the trust anchors for the provider host and for GitHub | `src/net.zig:64` (`caBundlePath`), loaded at `src/main.zig:212` and `src/update.zig:669` |
| `MICROAGENT_CONFIG`, `~/.microagent/config.toml` | reply-style levels, 64 KB cap | `src/main.zig:818` (`styleConfigPath`), `src/main.zig:736` (`loadStyle`), cap at `src/main.zig:69` |
| `MICROAGENT_BUDGET_SECONDS` | wall-clock ceiling on the run | `src/main.zig:500` (`budgetSeconds`), carried by `Budget` at `src/main.zig:873` |
| `MICROAGENT_SESSION_DIR` | where the JSONL run log is written | `src/main.zig:1015` (`sessionDir`) |
| `MDEBUG` | writes protocol notes and the resolved configuration to stderr, never the key | `src/main.zig:392` (`debugEnabled`), `src/main.zig:773` (`traceConfig`) |
| `GITHUB_TOKEN` | credential, sent to the API and to the asset host | `src/update.zig:512` (`githubBearer`), used at `src/update.zig:671`, `src/update.zig:726`, `src/update.zig:729` |
| GitHub release JSON | tag, page URL, asset names, download URLs | `src/update.zig:278` (`parseRelease`) |
| Downloaded asset and `.sha256` sidecar | bytes that become the running executable | fetched at `src/update.zig:726` and `729`, installed at `src/update.zig:444` |
| Streamed provider response (SSE) | model text and tool calls | `src/main.zig:1252` (`streamChat`), `src/main.zig:1731` (`applyFrame`) |
| Tool call arguments | what the model wants done | `src/tool.zig:300` (`runTool`) |
| Files in the working tree | the model's evidence, and its instructions | `src/tool.zig:601` (`toolRead`), system prompt at `src/main.zig:76` |

There is no network listener, no webhook, no message consumer, no scheduled job and no
IPC. The only outbound traffic is to the provider's base URL and to GitHub.

### Surface added by deployment

- The binary runs whatever is on `PATH`: `rg`, `ast-grep`, `git` and `/bin/sh`
  (`src/tool.zig:790`, `src/tool.zig:814`, `src/tool.zig:250`, `src/tool.zig:387`). A
  hostile `PATH` entry is a hostile tool, and `bash` runs whatever name the model typed.
- The Harbor adapter runs the binary inside third-party task containers with the provider
  key in the container environment (`integrations/harbor/microagent_agent.py:100`), so the
  blast radius of a poisoned task is the container plus the key.
- CI builds release assets with the workflow's own token and publishes them with
  `gh release create` (`.github/workflows/release.yml:184`); that account is the trust
  anchor for every future `microagent update`.

## Trust boundaries

1. **Operator → agent.** The prompt is untrusted input, the same as any other. There is
   no validation point: `setPrompt` (`src/main.zig:662`) stores it and
   `openConversation` (`src/main.zig:3047`) appends it to the conversation verbatim.
2. **Repository content → model → host.** The most important boundary in the project.
   The model reads files, source and tests, and issues tool calls from what it read
   (`src/main.zig:76`, the system prompt). Nothing in the program separates "the model's
   own plan" from "an instruction the model found in a file"; the only thing that does is
   an instruction in the prompt itself (`src/main.zig:88`).
3. **Provider → agent.** The streamed reply decides the next action. The validation point
   is `applyFrame` (`src/main.zig:1731`), which bounds the shape, not the intent.
4. **Agent → provider.** The key goes out in an `authorization` header
   (`src/main.zig:1271`, request built at `src/main.zig:1297`, body sent at
   `src/main.zig:1312`) to whatever host `base_url` named, after the scheme check at
   `src/main.zig:207`.
5. **Model → filesystem and process.** `bash` runs `/bin/sh -c` with the model's string
   (`src/tool.zig:387`); `read`, `write` and `edit` take any path
   (`src/tool.zig:601`, `src/tool.zig:703`, `src/tool.zig:761`).
6. **GitHub → host.** `update` downloads bytes and writes them over the running
   executable (`src/update.zig:726`, `src/update.zig:444`). Validation point: `decide`
   (`src/update.zig:229`).
7. **Secrets → process.** The key enters from `argv`, the environment or a file, lives in
   process memory for the run, and leaves only in the `authorization` header. It is never
   written to the session log or to a tool result.

Privilege transitions in this program are total rather than gradual: the moment the model
calls `bash`, the run has the operator's full authority, with no intermediate step. There
is no user confirmation between a model decision and a command.

## Assets

| Asset | Why it matters | Where it lives |
| --- | --- | --- |
| Provider API key | bills, model access, provider account | `argv` or environment, then process memory |
| `GITHUB_TOKEN` | release and API access | environment, then request headers |
| `~/.secrets/openrouter` | the same key, on disk | read at `src/main.zig:680` |
| Source tree and everything in it | `.env`, keys, unreleased work | read by `read` (`src/tool.zig:601`, a credential refused at `src/tool.zig:529`), sent to the provider in the request body |
| Host compute and credentials | the shell inherits the environment less the provider key | `src/tool.zig:72` (scrubbed at `src/main.zig:692`) |
| The binary itself | a replaced copy runs on every later invocation | replaced at `src/update.zig:444` |
| Run logs | working directory, model, token counts, finish reason | `~/.microagent/sessions`, pruned at 200 files (`src/main.zig:1083`, `src/main.zig:1107`) |
| Token spend | `--max-turns` bounds turns, not money | `src/main.zig:40`, `src/main.zig:48` |

## Threats per boundary

### Operator → agent (STRIDE: spoofing, tampering, information disclosure)

- A prompt that names a hostile base URL or a hostile `--repo` steers the whole run.
  Both are operator inputs, so this is a threat only where an automated harness passes a
  task's text straight through (`bench/gauntlet.sh`).
- A prompt of unbounded length enters the conversation with no size cap
  (`src/main.zig:662` `setPrompt`, appended at `src/main.zig:3047`); the request body
  grows with it.

### Repository content → model → host (elevation of privilege, information disclosure)

- **Prompt injection through source files.** A file, a test fixture, an issue template or
  a `CLAUDE.md`/`AGENTS.md` in the tree can say "run `curl … | sh`". The model reads it
  with the ordinary `read` tool (`src/tool.zig:601`) and there is no instruction
  provenance, so the injected text is as trusted as the operator's prompt. The system
  prompt tells the model to treat tool output as data and to report such a file instead of
  acting on it (`src/main.zig:88`), which is a control a hostile file can argue with. This
  is the project's dominant risk and it is a design property, not a bug.
- The same path exfiltrates: the model can `read` a file and the file's bytes go into the
  next request body (`src/main.zig:990`).
- A hostile repository can also reach the terminal: bytes a tool echoes reach the gutter
  line (`src/tool.zig:72`) and the provider's text reaches stdout, which is the answer
  the run was asked for and is deliberately left unescaped (`src/main.zig:1902`).

### Provider → agent (spoofing, tampering, denial of service)

- A hostile or coerced endpoint chooses every tool call. A single response can carry up to
  64 calls (`src/main.zig:50`, enforced by the index check at `src/main.zig:1695` and
  the index clamp in `applyCallDelta`) and they run as the operator.
- A tool call's name and argument object are the provider's own text and are parsed
  from bytes the model read out of the tree. They are fuzzed from the argument JSON
  to the gutter line and the limits it produces: the line stays one line inside its
  buffer with no byte a terminal acts on, and every count the model wrote is inside
  its ceiling before a subprocess starts (`src/tool.zig:1282`).
- A stream that never sends `[DONE]` grows the turn until the caps at
  `src/main.zig:58` stop it, and the run ends as truncated (`src/main.zig:1452`).
- An error body from the provider is printed on stderr through `terminalSafe`
  (`src/tool.zig:359`, applied at `src/main.zig:1356`), so control bytes are scrubbed and
  it cannot repaint the terminal.
- Frames that are not JSON are counted and dropped (`src/main.zig:1746`); they are not
  fatal, and the run continues on a partial turn, with the count reported at
  `src/main.zig:1446`.

### Agent → provider (information disclosure, spoofing)

- The key is refused to any base URL that would put it on the wire in the clear:
  `baseUrlCarriesKey` (`src/main.zig:446`) requires `https`, or `http` on loopback, and
  `main` fails the run otherwise (`src/main.zig:207`). Loopback is judged by exact match,
  so `127.evil.com` and `localhost.evil.com` do not qualify (`src/main.zig:455`,
  `src/main.zig:466`, every octet range-checked against `max_ipv4_octet`
  (`src/main.zig:462`)); the policy is pinned by the test at `src/main.zig:2126`.
- What that check does not do is constrain *which* https host. `MICROAGENT_BASE_URL` or
  `--base-url` may name any host, and the key follows it there.
- `--api-key` puts the credential in `argv` (`src/main.zig:676`), which is
  world-readable in the process table for the life of the run.
- The conversation carries everything the model read, on every turn, by design
  (`src/main.zig:990`).
- Redirects are not followed: `.redirect_behavior = .unhandled` (`src/main.zig:1299`)
  makes a 3xx an error status, so a provider that answers with a `Location` cannot walk
  the API key off to whoever it names. The header carrying the key is the one the request
  writer reads, pinned by the test at `src/main.zig:3242`; it is not a separately
  privileged field, so the unhandled redirect is the whole of this control.
- A base URL carrying `user:password@` has that userinfo replaced wherever the URL is
  printed (`displayUrl`, `src/main.zig:486`; test at `src/main.zig:2154`).

### Model → filesystem and process (elevation of privilege, tampering, denial of service)

- `bash` is arbitrary command execution with the operator's identity and working
  directory (`src/tool.zig:444`). The spawned shell inherits the environment less the
  four variables `resolveKey` reads (`childEnviron`, `src/main.zig:692`), so `bash env`
  and `bash printenv` cannot put the run's own key in the transcript. A command naming a
  credentials file is refused on the same name rule `read` applies
  (`credentialInCommand`, `src/tool.zig:411`); that rule reads the command's words rather
  than a parsed shell, so a file reached through indirection is not caught.
- `read`, `write` and `edit` accept absolute paths and do not confine writes to the
  working tree (`src/tool.zig:601`, `src/tool.zig:703`, `src/tool.zig:761`).
- `ast` with `rewrite` set applies its replacement to every match
  (`src/tool.zig:814`), so a single model turn can rewrite a whole file set.
- Bounded today: 60 s tool timeout, 120 s default and 600 s ceiling for `bash`
  (`src/tool.zig:35`, `src/tool.zig:43`, `src/tool.zig:41`, applied through
  `boundedMs` at `src/tool.zig:53` and the budget's remaining time at
  `src/main.zig:1928`), captured output held at 96 KB and cut to the 24 KB the model
  reads (`src/tool.zig:387`, `src/tool.zig:20`, `src/tool.zig:944`), `--max-turns`
  (`src/main.zig:40`), and a wall-clock budget (`src/main.zig:873`).

### GitHub → host (spoofing, tampering, elevation of privilege)

- The release JSON is attacker-shaped: every field in it becomes a tag, an asset name or a
  URL the updater acts on (`src/update.zig:278`). It is fuzzed against exactly that
  (`src/update.zig:1214`, `src/update.zig:1301`).
- The `--repo` the updater requests from is the caller's own text, and it is
  fuzzed from the command line to the URL it becomes: a repo no argument carried
  fails, a repo `validRepo` refuses never reaches a request, and one it accepts
  only ever names `api.github.com` (`src/update.zig:997`).
- A body over the cap is refused while it streams, not after (`src/update.zig:337`,
  `src/update.zig:408`); the API body is capped at 10 MB, the asset at 256 MB, the sidecar
  at 64 KB (`src/update.zig:21-23`).
- The sidecar is fetched from the same release as the asset, so the checksum proves the
  download was not corrupted in transit, not that the release was authorized. The trust
  anchor is the GitHub account and the TLS session, nothing more. There is no signature,
  no attestation and no pinned digest.
- The replacement follows a symlink to the real file (`src/update.zig:244`,
  `net.zig:89`), so a symlinked install under a path the operator does not own writes
  wherever the link points. The behavior is pinned by a test (`src/update.zig:1159`), so
  it is intended, not an accident.

### Classes this tree has already fixed

`CHANGELOG.md` records the same handful recurring: base-URL credentials printed unredacted
into the run's own error lines, a control character in a tool argument repainting the
terminal, a tool result or assistant text breaking the JSON of the next request, a
credential reaching the provider through a tool result, and memory held for the length of
a stream. Each has a control named above; a regression in any of them is the same bug
returning.

## Mitigations in the code

| Control | Covers | Where |
| --- | --- | --- |
| System prompt names tool output, file contents and command output as data, and tells the model to report a file that gives orders | prompt injection through a file, at the model rather than in the program | `src/main.zig:88` |
| `owner/name` validation before a URL exists | URL injection through `--repo` | `src/update.zig:135`, `src/update.zig:145`, `src/update.zig:156` |
| Host allowlist: `https` on `github.com`, `*.github.com`, `*.githubusercontent.com`, no userinfo, checked on the page URL and on both asset URLs | asset and page download from a lookalike host | `src/update.zig:162`, `src/update.zig:175`; applied at `src/update.zig:197`, `src/update.zig:719` and inside `decide` at `src/update.zig:232` |
| sha256 sidecar verification before the verdict is `replaced` | corrupted or substituted download | `src/update.zig:211`, `src/update.zig:229` |
| Version comparison refuses a downgrade | installing an older build over a newer one | `src/update.zig:80`, `src/update.zig:204`; test at `src/update.zig:913` |
| Atomic replace, only on `.replaced` | partial write, write on a refusal | `src/update.zig:229`, `src/update.zig:244` |
| The key is refused on a plaintext `http` base URL off loopback, every octet range-checked | the key crossing a network path in the clear, or to a name spelled like an address | `src/main.zig:446`, `src/main.zig:207`; test at `src/main.zig:2126` |
| Userinfo redacted from every printed URL | a password in the base URL copied into stderr | `src/main.zig:486`, `src/main.zig:1266`; test at `src/main.zig:2154` |
| Redirects unhandled | the key replayed to a host the provider names | `src/main.zig:1299`; test at `src/main.zig:3242` |
| Argument vectors instead of a shell for `search`, `ast`, `git` | shell injection through a pattern or a path | `src/tool.zig:790`, `src/tool.zig:814`, `src/tool.zig:250` |
| `--` separator and a `rev` that may not start with `-` | an option smuggled in as a path or a revision | `src/tool.zig:273`, `src/tool.zig:241` |
| Fixed git subcommands | `bash`-strength git, no writes through the `git` tool | `src/tool.zig:250-264` |
| Every tool subprocess is its own group leader; the group is SIGKILLed and takes the terminal's interrupt with it | orphaned build trees holding resources, and a Ctrl+C that leaves a build writing files | `src/tool.zig:165`, `src/tool.zig:183`, `src/tool.zig:190`, `src/tool.zig:110` |
| Output, response, frame and config caps; the response cap covers the whole response, not each field | memory exhaustion from a tool, a stream or a file | `src/tool.zig:20`, `src/main.zig:58`, `src/main.zig:67`, `src/main.zig:69` |
| Tool-call index cap and a saturating cast | a provider asking for billions of slots, or a wrapped index on a 32-bit build | `src/main.zig:50`, `src/main.zig:1695` |
| `read` refuses a credentials file by name, extension or directory | a `.env`, a private key or a `~/.secrets` file put into the model context | `src/tool.zig:529`, tables at `src/tool.zig:445-425`, refusal text at `src/tool.zig:578` |
| `search` and `ast` skip the same files, `git` refuses one named as a path | a credential reaching the provider through a match or a patch | `src/tool.zig:562`, `src/tool.zig:247`; test at `src/tool.zig:1459` |
| `write` refuses a call with no `content` | a truncated or forgotten argument emptying a file | `src/tool.zig:703`; test at `src/tool.zig:1338` |
| `bash` timeout is capped at 600 s and clipped to the budget left | model-chosen output running with no deadline at all | `src/tool.zig:41`, `src/tool.zig:380`, `src/main.zig:1928`; test at `src/tool.zig:1265` |
| `max_tokens` on every request | one turn generating until the provider's own limit stopped it | `src/main.zig:48`, `src/main.zig:1232` |
| Control bytes escaped in the gutter, scrubbed in error bodies, bounded through one helper | terminal escape injection from repo content and from a config key or a `--repo` value | `src/tool.zig:72`, `src/tool.zig:359`, `src/chat.zig:262` |
| Non-JSON frames counted and reported; a stream without `[DONE]` fails the turn | a truncated answer read as a finished one | `src/main.zig:1746`, `src/main.zig:1446`, `src/main.zig:1452` |
| Retry with capped exponential backoff on weather-shaped statuses and on failures before the request is readable; a response head that never arrives is not retried; a `Retry-After` longer than two minutes is not waited out | a dropped connection or a rate limit ending the run; a re-sent turn billed twice | `src/main.zig:2025`, `src/main.zig:2052`, `src/main.zig:2064`, `src/main.zig:2095` |
| Session log created exclusively, both name shapes pruned at 200 records | one run erasing another's log, unbounded growth | `src/main.zig:1048`, `src/main.zig:1083`, `src/main.zig:1107` |
| Values validated where they are set | a mistyped level or ceiling reaching the wire as a 400 | `src/main.zig:408`, `src/main.zig:426`, `src/main.zig:500` |
| Fuzz corpora for the parsers that take untrusted bytes: the release body, the sidecar, the completion stream, the config file, both command lines, a JSON string and a tool call | malformed provider, release, config, command-line or tool-call input | `src/update.zig:1214`, `src/update.zig:1301`, `src/main.zig:3802`, `src/main.zig:2299`, `src/style.zig:459`, `src/chat.zig:469`, `src/tool.zig:1282` |

### Gaps, ranked by exploitability and impact

1. **No confinement on model-driven execution.** `bash`, `write`, `edit` and an `ast`
   rewrite run with full operator authority, and the instructions that trigger them can
   come from a file the run reads. The system prompt asks the model not to act on such a
   file (`src/main.zig:88`), which is the same trust the operator already placed in the
   prompt. The model, not the operator, is the last gate.
2. **The credential rule is a name rule, and `bash` matches it on words.** `read`
   refuses a credentials file, `search` and `ast` skip them, `git` refuses one as a path
   and `bash` refuses a command whose words name one, so none of the five can put a
   known `.env` or private key in the model context. Two ways around it remain. A
   credential under a name the tables do not carry is still read. And `credentialInCommand`
   (`src/tool.zig:411`) tokenizes the command rather than parsing a shell, so a command
   that assembles a path at run time reaches the file. The run's own key is the case
   that mattered most, and it is closed structurally rather than textually: no tool
   subprocess inherits it (`src/main.zig:692`).
3. **No host policy on `base_url`, only a scheme policy.** The key never goes out over
   plaintext `http` off loopback, but `MICROAGENT_BASE_URL` or `--base-url` may name any
   `https` host and the key follows it. A poisoned environment variable turns a review run
   into a key handoff to whoever answers on that name.
4. **The api key is accepted on the command line.** It is visible in the process table and
   in shell history; the README's first example uses the environment, and the flag cannot
   be made to match that.
5. **The release checksum is self-attesting.** A compromised release account, or a token
   with write access to the repository, replaces the asset and the sidecar together, and
   `update` installs it.
6. **No cost ceiling.** `--max-turns`, `--max-tokens` and `--budget` bound tokens per
   turn, turns and time; nothing bounds what a whole run costs.
7. **No audit trail beyond the gutter line.** Tool calls go to stderr as one line with no
   timestamp, no exit status and no file (`src/tool.zig:349`); the session log records
   token counters, the working directory and the finish reason, never which commands ran
   (`src/main.zig:1190`).
8. **`GITHUB_TOKEN` is sent to the asset host as well as the API** (`src/update.zig:726`,
   `729`). The host allowlist makes that host GitHub's, but the token's reach is wider
   than the release check needs.
9. **A symlinked install can point anywhere.** `replaceVerified` follows the link
   (`src/update.zig:244`, `net.zig:89`); a link planted in a directory on the operator's
   `PATH` redirects the write.
10. **A config file can redirect the system prompt.** `MICROAGENT_CONFIG` prepends a
    reply-style ruleset to the system prompt (`src/main.zig:224`); it is operator-supplied
    and capped at 64 KB, but nothing in it is sandboxed, and it reaches the provider on
    every turn like any other prompt text.

## Abuse cases

Each of these is a scenario, evidenced by the code path that enables it. None has been
attempted.

- **A poisoned test fixture.** A repository contains a fixture whose text tells the agent
  to run a command. The model reads it with `read` (`src/tool.zig:601`) and, with `bash`
  (`src/tool.zig:387`), the command runs as the operator. The agent has no way to
  distinguish file content from operator instruction; the prompt tells it to report such a
  file instead, which a sufficiently persuasive file can argue with.
- **A hostile endpoint.** With `--base-url` pointed at an `https` server the attacker
  controls, the key arrives in the `authorization` header (`src/main.zig:1271`) and the
  reply decides every subsequent tool call. The scheme check passes, because the attacker
  serves `https`.
- **A symlink on the update path.** A link named `microagent` earlier on `PATH` is
  followed at install time (`src/update.zig:244`), so `update` writes a verified binary to
  a location the operator did not intend.
- **Scraping through the harness.** `read` has no path restriction, so a run over a
  directory containing credentials reads them and, through the model, can send them off the
  machine. There is no per-run file budget either, only the 4 MB per read
  (`src/tool.zig:25`).
- **A runaway bill.** `--max-turns` at its ceiling and a conversation that grows to 400 KB
  before compaction (`src/main.zig:35`, `src/main.zig:1834`) cost real tokens, with
  `max_tokens` bounding each turn but nothing bounding the run.
- **A poisoned task container.** The Harbor adapter hands the provider key to every task
  container it starts (`integrations/harbor/microagent_agent.py:100`), so a task written
  by a third party inherits the key for the length of its run.

## Response readiness

Note only, and not built here.

- Tool activity is a single stderr line per call with no timestamps and no exit status
  (`src/tool.zig:349`), and the session log keeps no record of it
  (`src/main.zig:1190`). A post-incident reconstruction of what a run did has to come from
  the working tree, not from a log.
- There is no `SECURITY.md`, so no disclosure contact, no supported-versions statement
  (the policy is one line in `README.md` under Versioning and one in `CHANGELOG.md`) and
  no documented path from a reported vulnerability to a shipped fix. This document does
  not invent one.
- `CHANGELOG.md` records every change that alters what a run does, which is the closest
  thing to a public record of behavior changes.
