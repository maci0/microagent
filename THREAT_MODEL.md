# Threat model

What can be attacked in microagent, from where, and what stands in the way. Every entry
below carries a file reference so the next pass can re-verify it against the code rather
than against this document.

Last reviewed: 2026-09-29, against `0.2.0` (`build.zig.zon`) and the `Unreleased` section
of `CHANGELOG.md`.

## Summary, risk-ranked

| # | Threat | Boundary | Exploitability | Impact | Control today |
| --- | --- | --- | --- | --- | --- |
| 1 | Repository content drives shell execution | repo → model → host | high: any content the model reads can carry an instruction | full compromise of the operator's account, its files and its keys | none |
| 2 | The provider's reply drives shell execution | provider → host | medium: needs a hostile, coerced or MITM'd endpoint | same as 1 | redirect refused, privileged auth header, response caps, timeouts |
| 3 | The API key is sent to the host the environment names | agent → provider | medium: any `https` host is accepted | provider account takeover, bill abuse | plaintext `http` refused off loopback (`src/main.zig:461`) |
| 4 | Tools read and write outside the working tree | model → filesystem | high: `read`/`write`/`edit` take any path | read or overwrite `~/.ssh`, `~/.aws`, CI tokens | none |
| 5 | Tool output carries credentials to the model and on to the provider | host → model → provider | high: the shell inherits the whole environment | secret exfiltration through a routine run | none |
| 6 | A compromised release replaces the binary | GitHub → host | low: needs the release account or its token | persistent, silent code execution on every later run | sha256 sidecar, host allowlist (`src/update.zig:152`, `src/update.zig:165`) |
| 7 | The API key is visible in the process table | operator → host | low: needs a local reader | key theft by any other process or user on the box | none |
| 8 | A hostile or malformed provider response exhausts memory or CPU | provider → agent | medium | run killed, machine memory spent | response caps, timeouts, process-group kill |
| 9 | A hostile repository writes escape sequences to the operator's terminal | repo → terminal | high: any file the model echoes | terminal spoofing, clipboard tricks | control bytes escaped in the gutter and scrubbed in error text |

`microagent` is a local CLI with no listener, no server and no database. It holds no user
data of its own: what it exposes is the operator's own machine, and what an attacker wants
is the key, the source tree and the host. The one place it holds something worth stealing
on its own is the API key.

## Attack surface

### Entry points in the code

| Entry point | What arrives | Handled at |
| --- | --- | --- |
| Command line, agent mode | prompt, flags, api key in `argv` | `src/main.zig:527` (`parseArgs`), `src/main.zig:210` (`main`) |
| Command line, `update` | `--check`, `--repo` | `src/update.zig:581` (`parseArgs`), `src/update.zig:607` (`run`), dispatched at `src/main.zig:224` |
| `MICROAGENT_MODEL`, `MICROAGENT_BASE_URL`, `MICROAGENT_REASONING_EFFORT` | endpoint, model, response style | `src/main.zig:411` (`envValue`) |
| `MICROAGENT_MAX_TURNS`, `MICROAGENT_MAX_TOKENS` | loop and response ceilings | `src/main.zig:591`, `src/main.zig:596`, both through `ceiling` at `src/main.zig:444` |
| `MICROAGENT_API_KEY`, `OPENAI_API_KEY`, `OPENROUTER_API_KEY`, `DEEPSEEK_API_KEY` | provider credential | `src/main.zig:653` (`key_vars`), resolved at `src/main.zig:636` |
| `~/.secrets/openrouter` | provider credential, up to 4 KB | `src/main.zig:655` (`readSecret`), cap at `src/main.zig:57` |
| `MICROAGENT_CA_BUNDLE`, `SSL_CERT_FILE` | the trust anchors for the provider host | `src/net.zig:55` (`caBundlePath`), loaded at `src/main.zig:265` |
| `MICROAGENT_CONFIG`, `~/.microagent/config.toml` | reply-style levels, 64 KB cap | `src/main.zig:738` (`styleConfigPath`), `src/main.zig:667` (`loadStyle`), cap at `src/main.zig:49` |
| `MICROAGENT_BUDGET_SECONDS` | wall-clock ceiling on the run | `src/main.zig:506` (`budgetSeconds`), carried by `Budget` at `src/main.zig:792` |
| `MICROAGENT_SESSION_DIR` | where the JSONL run log is written | `src/main.zig:911` (`sessionDir`) |
| `MDEBUG` | writes protocol notes and the resolved configuration to stderr, never the key | `src/main.zig:419` (`debugEnabled`), `src/main.zig:696` (`traceConfig`) |
| `GITHUB_TOKEN` | credential, sent to the API and to the asset host | `src/update.zig:508` (`githubBearer`), used at `src/update.zig:658`, `706`, `710` |
| GitHub release JSON | tag, page URL, asset names, download URLs | `src/update.zig:276` (`parseRelease`) |
| Downloaded asset and `.sha256` sidecar | bytes that become the running executable | fetched at `src/update.zig:706` and `710`, installed at `src/update.zig:731` |
| Streamed provider response (SSE) | model text and tool calls | `src/main.zig:1140` (`streamChat`), `src/main.zig:1528` (`applyFrame`) |
| Tool call arguments | what the model wants done | `src/main.zig:2011` (`runTool`) |
| Files in the working tree | the model's evidence, and its instructions | `src/main.zig:2141` (`toolRead`), system prompt at `src/main.zig:61` |

There is no network listener, no webhook, no message consumer, no scheduled job and no
IPC. The only outbound traffic is to the provider's base URL and to GitHub.

### Surface added by deployment

- The binary runs whatever is on `PATH`: `rg`, `ast-grep`, `git`, and `/bin/sh`
  (`src/main.zig:2201`, `src/main.zig:2217`, `src/main.zig:1780`, `src/main.zig:2110`). A
  hostile `PATH` entry is a hostile tool.
- The Harbor adapter runs the binary inside third-party task containers with the provider
  key in the container environment (`integrations/harbor/README.md`), so the blast
  radius of a poisoned task is the container plus the key.
- CI builds release assets with the workflow's own token and publishes them with
  `gh release create` (`.github/workflows/release.yml`); that account is the trust anchor
  for every future `microagent update`.

## Trust boundaries

1. **Operator → agent.** The prompt is untrusted input, the same as any other. There is
   no validation point: `setPrompt` (`src/main.zig:623`) stores it and
   `openConversation` (`src/main.zig:3171`) appends it to the conversation verbatim.
2. **Repository content → model → host.** The most important boundary in the project.
   The model reads files, source and tests, and issues tool calls from what it read
   (`src/main.zig:61`, the system prompt). Nothing separates "the model's own plan" from
   "an instruction the model found in a file".
3. **Provider → agent.** The streamed reply decides the next action. The validation point
   is `applyFrame` (`src/main.zig:1528`), which bounds the shape, not the intent.
4. **Agent → provider.** The key goes out in an `authorization: Bearer` header
   (`src/main.zig:1151`, sent at `src/main.zig:1159` and `1187`) to whatever host
   `base_url` named, after the scheme check at `src/main.zig:260`.
5. **Model → filesystem and process.** `bash` runs `/bin/sh -c` with the model's string
   (`src/main.zig:2110`); `read`, `write` and `edit` take any path
   (`src/main.zig:2141`, `src/main.zig:2163`, `src/main.zig:2172`).
6. **GitHub → host.** `update` downloads bytes and writes them over the running
   executable (`src/update.zig:442`, `src/update.zig:731`). Validation point: `decide`
   (`src/update.zig:219`).
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
| `~/.secrets/openrouter` | the same key, on disk | read at `src/main.zig:655` |
| Source tree and everything in it | `.env`, keys, unreleased work | read by `read` (`src/main.zig:2141`), sent to the provider in the request body (`src/main.zig:1113`) |
| Host compute and credentials | the shell inherits the environment | `src/main.zig:2110` |
| The binary itself | a replaced copy runs on every later invocation | replaced at `src/update.zig:731` |
| Run logs | working directory, model, token counts, finish reason | `~/.microagent/sessions`, pruned at 200 files (`src/main.zig:977`) |
| Token spend | `--max-turns` bounds turns, not money | `src/main.zig:31`, `src/main.zig:591` |

## Threats per boundary

### Operator → agent (STRIDE: spoofing, tampering, information disclosure)

- A prompt that names a hostile base URL or a hostile `--repo` steers the whole run.
  Both are operator inputs, so this is a threat only where an automated harness passes a
  task's text straight through (`bench/gauntlet.sh`, gauntlet itself).
- A prompt of unbounded length enters the conversation with no size cap
  (`src/main.zig:623` `setPrompt`, appended at `src/main.zig:3171`); the request body grows
  with it.

### Repository content → model → host (elevation of privilege, information disclosure)

- **Prompt injection through source files.** A file, a test fixture, an issue template or
  a `CLAUDE.md`/`AGENTS.md` in the tree can say "run `curl … | sh`". The model reads it
  with the ordinary `read` tool (`src/main.zig:2141`) and there is no instruction
  provenance, so the injected text is as trusted as the operator's prompt. This is the
  project's dominant risk and it is a design property, not a bug.
- The same path exfiltrates: the model can `read` a file and the file's bytes go into the
  next request body (`src/main.zig:1113`).
- A hostile repository can also reach the terminal: bytes a tool echoes reach the gutter
  line (`src/main.zig:2034`) and the provider's text reaches stdout, which is the answer
  the run was asked for and is deliberately left unescaped (`src/main.zig:1923`).

### Provider → agent (spoofing, tampering, denial of service)

- A hostile or coerced endpoint chooses every tool call. A single response can carry up to
  64 calls (`src/main.zig:41`, enforced at `src/main.zig:1500` and `1598`) and they run as
  the operator.
- A stream that never sends `[DONE]` grows the turn until the caps at
  `src/main.zig:47` stop it, and the run ends as truncated (`src/main.zig:1316`).
- An error body from the provider is printed on stderr through `terminalSafe`
  (`src/main.zig:2085`, applied at `src/main.zig:1229`), so control bytes are scrubbed and
  it cannot repaint the terminal.
- Frames that are not JSON are counted and dropped (`src/main.zig:1543`, `1548`); they are
  not fatal, and the run continues on a partial turn, with the count reported at
  `src/main.zig:1310`.

### Agent → provider (information disclosure, spoofing)

- The key is refused to any base URL that would put it on the wire in the clear:
  `baseUrlCarriesKey` (`src/main.zig:461`) requires `https`, or `http` on loopback, and
  `main` fails the run otherwise (`src/main.zig:260`). Loopback is judged by exact match,
  so `127.evil.com` and `localhost.evil.com` do not qualify (`src/main.zig:469`,
  `src/main.zig:478`); the policy is pinned by the test at `src/main.zig:2575`.
- What that check does not do is constrain *which* https host. `MICROAGENT_BASE_URL` or
  `--base-url` may name any host, and the key follows it there.
- `--api-key` puts the credential in `argv` (`src/main.zig:562`), which is
  world-readable in the process table for the life of the run.
- The conversation carries everything the model read, on every turn, by design
  (`src/main.zig:1113`).
- Redirects are not followed: `.redirect_behavior = .unhandled` (`src/main.zig:1186`) makes
  a 3xx an error status, and the key is a privileged header
  (`.privileged_headers`, `src/main.zig:1187`), so the header carrying the key is dropped
  by the client even if a future change lets a redirect through.
- A base URL carrying `user:password@` has that userinfo replaced wherever the URL is
  printed (`displayUrl`, `src/main.zig:494`; test at `src/main.zig:2599`).

### Model → filesystem and process (elevation of privilege, tampering, denial of service)

- `bash` is arbitrary command execution with the operator's identity, environment and
  working directory (`src/main.zig:2110`). The spawned shell inherits the full
  environment, including the API key, so `bash env` reaches it in one call.
- `read`, `write` and `edit` accept absolute paths and do not confine writes to the
  working tree (`src/main.zig:2141`, `src/main.zig:2163`, `src/main.zig:2172`).
- `ast` with `rewrite` set applies `--update-all` to every match (`src/main.zig:2225`), so
  a single model turn can rewrite a whole file set.
- Bounded today: 60 s tool timeout, 120 s default and 600 s ceiling for `bash`
  (`src/main.zig:1629`, `src/main.zig:1637`, `src/main.zig:1635`, applied at
  `src/main.zig:2106`), 96 KB captured output trimmed to 24 KB (`src/main.zig:21`,
  `src/main.zig:2535`), `--max-turns` (`src/main.zig:31`), and a wall-clock budget
  (`src/main.zig:792`).

### GitHub → host (spoofing, tampering, elevation of privilege)

- The release JSON is attacker-shaped: every field in it becomes a tag, an asset name or a
  URL the updater acts on (`src/update.zig:276`). It is fuzzed against exactly that
  (`src/update.zig:1114`, `src/update.zig:1146`).
- A body over the cap is refused while it streams, not after (`src/update.zig:335`,
  `src/update.zig:406`); the API body is capped at 10 MB, the asset at 256 MB, the sidecar
  at 64 KB (`src/update.zig:20-22`).
- The sidecar is fetched from the same release as the asset, so the checksum proves the
  download was not corrupted in transit, not that the release was authorized. The trust
  anchor is the GitHub account and the TLS session, nothing more. There is no signature,
  no attestation and no pinned digest.
- The replacement follows a symlink to the real file (`src/update.zig:242`), so a
  symlinked install under a path the operator does not own writes wherever the link points.
  The behavior is pinned by a test (`src/update.zig:1077`), so it is intended, not an
  accident.

### Classes this tree has already fixed

`CHANGELOG.md` records the same handful recurring: base-URL credentials printed unredacted
into the run's own error lines, a control character in a tool argument repainting the
terminal, a tool result or assistant text breaking the JSON of the next request, and
memory held for the length of a stream. Each has a control named above; a regression in
any of them is the same bug returning.

## Mitigations in the code

| Control | Covers | Where |
| --- | --- | --- |
| `owner/name` validation before a URL exists | URL injection through `--repo` | `src/update.zig:125`, `src/update.zig:135`, `src/update.zig:146` |
| Host allowlist: `https` on `github.com`, `*.github.com`, `*.githubusercontent.com`, no userinfo, checked on the page URL and on both asset URLs | asset and page download from a lookalike host | `src/update.zig:152`, `src/update.zig:165`, `src/update.zig:186`; applied at `src/update.zig:700` and inside `decide` at `src/update.zig:222` |
| sha256 sidecar verification before the verdict is `replaced` | corrupted or substituted download | `src/update.zig:201`, `src/update.zig:219` |
| Version comparison refuses a downgrade | installing an older build over a newer one | `src/update.zig:70`, `src/update.zig:194`; test at `src/update.zig:881` |
| Atomic replace, only on `.replaced` | partial write, write on a refusal | `src/update.zig:234`, `src/update.zig:254` |
| The key is refused on a plaintext `http` base URL off loopback | the key crossing a network path in the clear | `src/main.zig:461`, `src/main.zig:260`; test at `src/main.zig:2575` |
| Userinfo redacted from every printed URL | a password in the base URL copied into stderr | `src/main.zig:494`, `src/main.zig:1154`; test at `src/main.zig:2599` |
| Redirects unhandled, and the `authorization` header marked privileged | the key replayed to a host the provider names | `src/main.zig:1186`, `src/main.zig:1187` |
| Argument vectors instead of a shell for `search`, `ast`, `git` | shell injection through a pattern or a path | `src/main.zig:2201`, `src/main.zig:2217`, `src/main.zig:1780`, `src/main.zig:1758` |
| `--` separator and a `rev` that may not start with `-` | an option smuggled in as a path or a revision | `src/main.zig:1786`, `src/main.zig:1808` |
| Fixed git subcommands | `bash`-strength git, no writes through the `git` tool | `src/main.zig:1791-1806` |
| Every tool subprocess is its own group leader; the group is SIGKILLed | orphaned build trees holding resources, and a Ctrl+C that leaves a build writing files | `src/main.zig:1678`, `src/main.zig:1720`, `src/main.zig:1745` |
| Output, response and config caps | memory exhaustion from a tool, a stream or a file | `src/main.zig:21`, `src/main.zig:47`, `src/main.zig:49` |
| Tool-call index cap | a provider asking for billions of slots | `src/main.zig:41`, `src/main.zig:1500`, `src/main.zig:1598` |
| Control bytes escaped in the gutter, scrubbed in error bodies | terminal escape injection from repo content | `src/main.zig:2054`, `src/main.zig:2085` |
| Non-JSON frames counted and dropped; a stream without `[DONE]` fails the turn | a truncated answer read as a finished one | `src/main.zig:1543`, `src/main.zig:1310`, `src/main.zig:1316` |
| Retry with capped exponential backoff on weather-shaped statuses and on failures before the request is readable; a response head that never arrives is not retried | a dropped connection or a rate limit ending the run; a re-sent turn billed twice | `src/main.zig:2345`, `src/main.zig:2354`, `src/main.zig:2381` |
| Session log created exclusively, both name shapes pruned at 200 records | one run erasing another's log, unbounded growth | `src/main.zig:944`, `src/main.zig:991`, `src/main.zig:1002`, `src/main.zig:977` |
| Values validated where they are set | a mistyped level or ceiling reaching the wire as a 400 | `src/main.zig:432`, `src/main.zig:444` |
| Fuzz corpora for the two parsers that take untrusted bytes, the release body and the completion stream | malformed provider or release input | `src/main.zig:3996`, `src/main.zig:4026`, `src/update.zig:1114`, `src/update.zig:1146` |

### Gaps, ranked by exploitability and impact

1. **No confinement on model-driven execution.** `bash`, `write`, `edit` and `ast
   --rewrite` run with full operator authority, and the instructions that trigger them
   can come from a file the run reads. The model, not the operator, is the last gate.
2. **No secret hygiene in tool output.** A tool that prints an environment variable, a
   config file or a `.env` puts those bytes in the model context, and the model context is
   re-sent to the provider on every turn.
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
6. **No cost ceiling.** `--max-turns` and `--budget` bound time and turns; nothing bounds
   what a single run costs.
7. **No audit trail beyond the gutter line.** Tool calls go to stderr as one line with no
   timestamp, no exit status and no file (`src/main.zig:2034`); the session log records
   token counters, the working directory and the finish reason, never which commands ran
   (`src/main.zig:1078`).
8. **`GITHUB_TOKEN` is sent to the asset host as well as the API** (`src/update.zig:706`,
   `711`). The host allowlist makes that host GitHub's, but the token's reach is wider
   than the release check needs.
9. **A symlinked install can point anywhere.** `replaceVerified` follows the link
   (`src/update.zig:242`); a link planted in a directory on the operator's `PATH`
   redirects the write.
10. **A config file can redirect the system prompt.** `MICROAGENT_CONFIG` prepends a
    reply-style ruleset to the system prompt (`src/main.zig:274`); it is operator-supplied
    and capped at 64 KB, but nothing in it is sandboxed, and it reaches the provider on
    every turn like any other prompt text.

## Abuse cases

Each of these is a scenario, evidenced by the code path that enables it. None has been
attempted.

- **A poisoned test fixture.** A repository contains a fixture whose text tells the agent
  to run a command. The model reads it with `read` (`src/main.zig:2141`) and, with
  `bash` (`src/main.zig:2110`), the command runs as the operator. The agent never
  distinguishes file content from operator instruction.
- **A hostile endpoint.** With `--base-url` pointed at an `https` server the attacker
  controls, the key arrives in the `authorization` header (`src/main.zig:1151`) and the
  reply decides every subsequent tool call. The scheme check passes, because the attacker
  serves `https`.
- **A symlink on the update path.** A link named `microagent` earlier on `PATH` is
  followed at install time (`src/update.zig:242`), so `update` writes a verified binary to
  a location the operator did not intend.
- **Scraping through the harness.** `read` has no path restriction, so a run over a
  directory containing credentials reads them and, through the model, can send them off
  the machine. There is no per-run file budget either, only the 4 MB per read
  (`src/main.zig:53`).
- **A runaway bill.** `--max-turns` at its ceiling of any value, and a conversation that
  grows to 400 KB before compaction (`src/main.zig:26`, `src/main.zig:1858`), cost real
  tokens with no spend check anywhere in the code.

## Response readiness

Note only, and not built here.

- Tool activity is a single stderr line per call with no timestamps and no exit status
  (`src/main.zig:2034`), and the session log keeps no record of it
  (`src/main.zig:1078`). A post-incident reconstruction of what a run did has to come from
  the working tree, not from a log.
- There is no `SECURITY.md`, so no disclosure contact, no supported-versions statement
  (the release policy is in `README.md` under Versioning) and no documented path from a
  reported vulnerability to a shipped fix. This document does not invent one.
- `CHANGELOG.md` records every change that alters what a run does, which is the closest
  thing to a public record of behavior changes.
