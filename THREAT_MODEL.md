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
| 2 | The provider's reply drives shell execution | provider → host | medium: needs a hostile, coerced or MITM'd endpoint | same as 1 | none |
| 3 | API key travels in cleartext or to the wrong host | agent → provider | medium: `--base-url` accepts any scheme and any host | provider account takeover, bill abuse | none |
| 4 | Tools read and write outside the working tree | model → filesystem | high: `read`/`write`/`edit` take any path | read or overwrite `~/.ssh`, `~/.aws`, CI tokens | none |
| 5 | Tool output carries credentials to the model and on to the provider | host → model → provider | high: the shell inherits the whole environment | secret exfiltration through a routine run | none |
| 6 | A compromised release replaces the binary | GitHub → host | low: needs the release account or its token | persistent, silent code execution on every later run | sha256 sidecar, host allowlist (`src/update.zig:150-228`) |
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
| Command line, agent mode | prompt, flags, api key in `argv` | `src/main.zig:381` (`parseArgs`), `src/main.zig:201` |
| Command line, `update` | `--check`, `--repo` | `src/update.zig:558` (`run`) |
| `MICROAGENT_API_KEY`, `OPENAI_API_KEY`, `OPENROUTER_API_KEY`, `DEEPSEEK_API_KEY` | provider credential | `src/main.zig:480` (`resolveKey`) |
| `~/.secrets/openrouter` | provider credential, up to 4 KB | `src/main.zig:493` (`readSecret`) |
| `MICROAGENT_BASE_URL` | the host the key is sent to | `src/main.zig:178`, used at `src/main.zig:840` |
| `MICROAGENT_CA_BUNDLE`, `SSL_CERT_FILE` | the trust anchors for that host | `src/net.zig:55` (`caBundlePath`), `src/net.zig:16` |
| `MICROAGENT_CONFIG`, `~/.microagent/config.toml` | reply-style levels, 64 KB cap | `src/main.zig:528` (`styleConfigPath`), `src/main.zig:505` |
| `MICROAGENT_SESSION_DIR` | where the JSONL run log is written | `src/main.zig:651` |
| `MICROAGENT_MAX_TURNS`, `MICROAGENT_BUDGET_SECONDS`, `MICROAGENT_REASONING_EFFORT` | loop limits | `src/main.zig:180`, `src/main.zig:182` |
| `MDEBUG` | writes protocol notes to stderr | `src/main.zig:337` |
| `GITHUB_TOKEN` | credential, sent to the API and to the asset host | `src/update.zig:540` |
| GitHub release JSON | tag, page URL, asset names, download URLs | `src/update.zig:274` (`parseRelease`) |
| Downloaded asset and `.sha256` sidecar | bytes that become the running executable | `src/update.zig:654`, `src/update.zig:656` |
| Streamed provider response (SSE) | model text and tool calls | `src/main.zig:832` (`streamChat`), `src/main.zig:1034` (`applyFrame`) |
| Tool call arguments | what the model wants done | `src/main.zig:1376` (`runTool`) |
| Files in the working tree | the model's evidence, and its instructions | `src/main.zig:1498` (`toolRead`) |

There is no network listener, no webhook, no message consumer, no scheduled job and no
IPC. The only outbound traffic is to the provider's base URL and to GitHub.

### Surface added by deployment

- The binary runs whatever is on `PATH`: `rg`, `ast-grep`, `git`, and `/bin/sh`
  (`src/main.zig:1181`, `src/main.zig:1467`). A hostile `PATH` entry is a hostile tool.
- The Harbor adapter runs the binary inside third-party task containers with the provider
  key in the container environment (`integrations/harbor/README.md:44`), so the blast
  radius of a poisoned task is the container plus the key.
- CI builds release assets with the workflow's own token and publishes them with
  `gh release create` (`.github/workflows/release.yml`); that account is the trust anchor
  for every future `microagent update`.

## Trust boundaries

1. **Operator → agent.** The prompt is untrusted input, the same as any other. There is
   no validation point: `src/main.zig:221` appends it to the conversation verbatim.
2. **Repository content → model → host.** The most important boundary in the project.
   The model reads files, source and tests, and issues tool calls from what it read
   (`src/main.zig:39`, the system prompt). Nothing separates "the model's own plan" from
   "an instruction the model found in a file".
3. **Provider → agent.** The streamed reply decides the next action. The validation point
   is `applyFrame` (`src/main.zig:1034`), which bounds the shape, not the intent.
4. **Agent → provider.** The key goes out in an `Authorization: Bearer` header
   (`src/main.zig:842`, `src/main.zig:866`) to whatever host `base_url` named.
5. **Model → filesystem and process.** `bash` runs `/bin/sh -c` with the model's string
   (`src/main.zig:1467`); `read`, `write` and `edit` take any path
   (`src/main.zig:1498`, `src/main.zig:1520`, `src/main.zig:1529`).
6. **GitHub → host.** `update` downloads bytes and writes them over the running
   executable (`src/update.zig:492`). Validation point: `decide` (`src/update.zig:217`).
7. **Secrets → process.** The key enters from `argv`, the environment or a file, lives in
   process memory for the run, and leaves only in the `Authorization` header. It is never
   written to the session log or to a tool result.

Privilege transitions in this program are total rather than gradual: the moment the model
calls `bash`, the run has the operator's full authority, with no intermediate step. There
is no user confirmation between a model decision and a command.

## Assets

| Asset | Why it matters | Where it lives |
| --- | --- | --- |
| Provider API key | bills, model access, provider account | `argv` or environment, then process memory |
| `GITHUB_TOKEN` | release and API access | environment, then request headers |
| `~/.secrets/openrouter` | the same key, on disk | read at `src/main.zig:493` |
| Source tree and everything in it | `.env`, keys, unreleased work | read by the `read` tool, sent to the provider |
| Host compute and credentials | the shell inherits the environment | `src/main.zig:1768` |
| The binary itself | a replaced copy runs on every later invocation | replaced at `src/update.zig:252` |
| Run logs | working directory, model, token counts | `~/.microagent/sessions`, capped at 200 files |
| Token spend | `--max-turns` bounds turns, not money | `src/main.zig:27`, `src/main.zig:599` |

## Threats per boundary

### Operator → agent (STRIDE: spoofing, tampering, information disclosure)

- A prompt that names a hostile base URL or a hostile `--repo` steers the whole run.
  Both are operator inputs, so this is a threat only where an automated harness passes a
  task's text straight through (`bench/gauntlet.sh`, gauntlet itself).
- A prompt of unbounded length enters the conversation with no size cap
  (`src/main.zig:221`); the request body grows with it.

### Repository content → model → host (elevation of privilege, information disclosure)

- **Prompt injection through source files.** A file, a test fixture, an issue template or
  a `CLAUDE.md`/`AGENTS.md` in the tree can say "run `curl … | sh`". The model reads it
  with the ordinary `read` tool (`src/main.zig:1498`) and there is no instruction
  provenance, so the injected text is as trusted as the operator's prompt. This is the
  project's dominant risk and it is a design property, not a bug.
- The same path exfiltrates: the model can `read` a file and the file's bytes go into the
  next request body (`src/main.zig:806`).
- A hostile repository can also reach the terminal: bytes a tool echoes reach the gutter
  line (`src/main.zig:1399`) and the provider's text reaches stdout, which is the answer
  the run was asked for and is deliberately left unescaped (`src/main.zig:1450`).

### Provider → agent (spoofing, tampering, denial of service)

- A hostile or coerced endpoint chooses every tool call. A single response can carry up to
  64 calls (`src/main.zig:29`, `src/main.zig:1087`) and they run as the operator.
- A stream that never sends `[DONE]` grows the turn until the caps at
  `src/main.zig:35` stop it, and the run ends as truncated (`src/main.zig:978`).
- An error body from the provider is printed on stderr; control bytes are scrubbed
  (`src/main.zig:899`, `src/main.zig:1450`), so it cannot repaint the terminal.
- Frames that are not JSON are counted and dropped (`src/main.zig:1043`); they are not
  fatal, and the run continues on a partial turn.

### Agent → provider (information disclosure, spoofing)

- `base_url` is used as given (`src/main.zig:840`). `http://` is accepted, and the test at
  `src/main.zig:1895` pins that a plain-http localhost endpoint is a valid value, so a
  typo or a poisoned environment sends the key in cleartext.
- `--api-key` puts the credential in `argv`, which is world-readable in the process table
  for the life of the run (`src/main.zig:416`).
- The conversation carries everything the model read, on every turn, by design
  (`src/main.zig:806`).

### Model → filesystem and process (elevation of privilege, tampering, denial of service)

- `bash` is arbitrary command execution with the operator's identity, environment and
  working directory (`src/main.zig:1467`). The spawned shell inherits the full
  environment, including the API key, so `bash env` reaches it in one call.
- `read`, `write` and `edit` accept absolute paths and do not confine writes to the
  working tree (`src/main.zig:1500`, `src/main.zig:1523`, `src/main.zig:1558`).
- `ast` with `rewrite` set applies `--update-all` to every match (`src/main.zig:1587`), so
  a single model turn can rewrite a whole file set.
- Bounded today: 120 s default and 60 s hard tool timeout (`src/main.zig:1115`), 96 KB
  captured output (`src/main.zig:21`, `src/main.zig:1470`), `--max-turns` (`src/main.zig:27`),
  and a wall-clock budget (`src/main.zig:601`).

### GitHub → host (spoofing, tampering, elevation of privilege)

- The release JSON is attacker-shaped: every field in it becomes a tag, an asset name or a
  URL the updater acts on (`src/update.zig:274`). It is fuzzed against exactly that
  (`src/update.zig:1086`).
- A body over the cap is refused while it streams, not after (`src/update.zig:401`,
  `src/update.zig:328`); the API body is capped at 10 MB, the asset at 256 MB, the sidecar
  at 64 KB (`src/update.zig:20-22`).
- The sidecar is fetched from the same release as the asset, so the checksum proves the
  download was not corrupted in transit, not that the release was authorized. The trust
  anchor is the GitHub account and the TLS session, nothing more. There is no signature,
  no attestation and no pinned digest.
- The replacement follows a symlink to the real file (`src/update.zig:242`), so a
  symlinked install under a path the operator does not own writes wherever the link points.

## Mitigations in the code

| Control | Covers | Where |
| --- | --- | --- |
| `owner/name` validation before a URL exists | URL injection through `--repo` | `src/update.zig:133`, `src/update.zig:144` |
| Host allowlist: `https` on `github.com`, `*.github.com`, `*.githubusercontent.com`, no userinfo | asset and page download from a lookalike host | `src/update.zig:150-180` |
| sha256 sidecar verification before the verdict is `replaced` | corrupted or substituted download | `src/update.zig:199`, `src/update.zig:217` |
| Version comparison refuses a downgrade | installing an older build over a newer one | `src/update.zig:68`, `src/update.zig:192` |
| Atomic replace, only on `.replaced` | partial write, write on a refusal | `src/update.zig:232` |
| Argument vectors instead of a shell for `search`, `ast`, `git` | shell injection through a pattern or a path | `src/main.zig:1181`, `src/main.zig:1579`, `src/main.zig:1201` |
| `--` separator and a `rev` that may not start with `-` | an option smuggled in as a path or a revision | `src/main.zig:1198`, `src/main.zig:1220` |
| Fixed git subcommands | `bash`-strength git, no writes through the `git` tool | `src/main.zig:1203-1218` |
| Process-group kill on timeout or cap | orphaned build trees holding resources | `src/main.zig:1125-1176` |
| Output, response and config caps | memory exhaustion from a tool, a stream or a file | `src/main.zig:21`, `src/main.zig:35`, `src/main.zig:37` |
| Tool-call index cap | a provider asking for billions of slots | `src/main.zig:1087` |
| Control bytes escaped in the gutter, scrubbed in error bodies | terminal escape injection from repo content | `src/main.zig:1419`, `src/main.zig:1450` |
| Non-JSON frames counted and dropped; a stream without `[DONE]` fails the turn | a truncated answer read as a finished one | `src/main.zig:1043`, `src/main.zig:993` |
| Session log created exclusively, capped at 200 records | one run erasing another's log, unbounded growth | `src/main.zig:681`, `src/main.zig:714` |
| Values validated where they are set | a mistyped level or ceiling reaching the wire as a 400 | `src/main.zig:350`, `src/main.zig:360` |
| Fuzz corpora for the two parsers that take untrusted bytes, the release body and the completion stream | malformed provider or release input | `src/update.zig:1032`, `src/main.zig:2798` |

### Gaps, ranked by exploitability and impact

1. **No confinement on model-driven execution.** `bash`, `write`, `edit` and `ast
   --rewrite` run with full operator authority, and the instructions that trigger them
   can come from a file the run reads. The model, not the operator, is the last gate.
2. **No secret hygiene in tool output.** A tool that prints an environment variable, a
   config file or a `.env` puts those bytes in the model context, and the model context is
   re-sent to the provider on every turn.
3. **No scheme or host policy on `base_url`.** The key is sent to whatever endpoint is
   named, in cleartext if the scheme says so.
4. **The api key is accepted on the command line.** It is visible in the process table and
   in shell history; the README's first example uses the environment, and the flag
   cannot be made to match that.
5. **The release checksum is self-attesting.** A compromised release account, or a token
   with write access to the repository, replaces the asset and the sidecar together, and
   `update` installs it.
6. **No cost ceiling.** `--max-turns` and `--budget` bound time and turns; nothing bounds
   what a single run costs.
7. **No audit trail beyond the gutter line.** Tool calls go to stderr as one line with no
   timestamp, no exit status and no file (`src/main.zig:1399`); the session log records
   token counters and the working directory, never which commands ran
   (`src/main.zig:785`).
8. **`GITHUB_TOKEN` is sent to the asset host as well as the API** (`src/update.zig:654`).
   The host allowlist makes that host GitHub's, but the token's reach is wider than the
   release check needs.
9. **A symlinked install can point anywhere.** `replaceVerified` follows the link
   (`src/update.zig:242`); a link planted in a directory on the operator's `PATH` redirects
   the write.

## Abuse cases

Each of these is a scenario, evidenced by the code path that enables it. None has been
attempted.

- **A poisoned test fixture.** A repository contains a fixture whose text tells the agent
  to run a command. The model reads it with `read` (`src/main.zig:1498`) and, with
  `bash` (`src/main.zig:1467`), the command runs as the operator. The agent never
  distinguishes file content from operator instruction.
- **A hostile endpoint.** With `--base-url` pointed at a server the attacker controls, the
  key arrives in the `Authorization` header (`src/main.zig:866`), and the reply decides
  every subsequent tool call.
- **A symlink on the update path.** A link named `microagent` earlier on `PATH` is
  followed at install time (`src/update.zig:242`), so `update` writes a verified binary to
  a location the operator did not intend.
- **Scraping through the harness.** `read` has no path restriction, so a run over a
  directory containing credentials reads them and, through the model, can send them off
  the machine. There is no per-run file budget either, only the 4 MB per read
  (`src/main.zig:1500`).
- **A runaway bill.** `--max-turns` at its ceiling of any value, and a conversation that
  grows to 400 KB before compaction (`src/main.zig:26`), cost real tokens with no spend
  check anywhere in the code.

## Response readiness

Note only, and not built here.

- Tool activity is a single stderr line per call with no timestamps and no exit status
  (`src/main.zig:1399`), and the session log keeps no record of it
  (`src/main.zig:785`). A post-incident reconstruction of what a run did has to come from
  the working tree, not from a log.
- There is no `SECURITY.md`, so no disclosure contact, no supported-versions statement
  (the release policy is in `README.md` under Versioning) and no documented path from a
  reported vulnerability to a shipped fix. This document does not invent one.
- `CHANGELOG.md` records every change that alters what a run does, which is the closest
  thing to a public record of behavior changes.
