# Threat model

What can be attacked in microagent, from where, and what stands in the way. Every entry
below carries a file reference so the next pass can re-verify it against the code rather
than against this document.

Last reviewed: 2026-09-29, against `0.2.0` (`build.zig.zon`) and the `Unreleased` section
of `CHANGELOG.md`. The MCP-server and skills surfaces were added in this pass: the two rows
they add to the summary, the entry points they add to the table, the two trust boundaries
and the outbound-traffic sentence below. Every `file:line` in the document was then
re-resolved against the tree as it stands, by mapping the previous pass's line numbers
through the diff from the tree that pass resolved against and this session's own additions
through the diff from the tree they were written against. One reference moved with a symbol
that changed modules (`fuzzConfig`, from `style.zig` to `config.zig`) and one was renamed
with the function it names (`loadConfig`, was `loadStyle`); every other reference either
names the same line or lands inside the same function as before. The stall timeout
(`--stall-timeout`, `MICROAGENT_STALL_TIMEOUT`) had grown an entry point and a control
without one here, and is now named in all three places. No owner and no review cadence are
named here: neither is decided in this repository, and inventing one would put a name
against a document nobody signed.

## Summary, risk-ranked

| # | Threat | Boundary | Exploitability | Impact | Control today |
| --- | --- | --- | --- | --- | --- |
| 1 | Repository content drives shell execution | repo → model → host | high: any content the model reads can carry an instruction | full compromise of the operator's account, its files and its keys | prompt wording only (`system_prompt`, `src/main.zig:138`); no mechanical control (gap 1) |
| 2 | The provider's reply drives shell execution | provider → host | medium: needs a hostile, coerced or MITM'd endpoint | same as 1 | redirect refused (`streamChat`, `src/main.zig:2157`), response caps, timeouts, `bash` timeout ceiling (`default_bash_timeout_ms`/`max_bash_timeout_ms`, `src/tool.zig:54`/`src/tool.zig:54`) |
| 3 | The API key is sent to the host the environment names | agent → provider | medium: any `https` host is accepted | provider account takeover, bill abuse | plaintext `http` refused off loopback (`baseUrlCarriesKey`, `src/main.zig:742`, enforced at `src/main.zig:334`) |
| 4 | A named CA bundle adds a trust anchor for every TLS connection the run makes | environment/argv → agent, agent → provider and GitHub | medium: needs a write to the environment, or a `--ca-bundle` on the command line | the API key to a machine-in-the-middle, and a release asset that hashes as published | additive to the system store, and a bundle that is unreadable or holds no certificate is refused (`loadCaBundle`, `src/net.zig:39`); no policy on what a bundle may add (gap 3) |
| 5 | Tools read and write outside the working tree | model → filesystem | high: `read`/`write`/`edit` take any path | overwrite `~/.ssh/authorized_keys`, a shell rc file, any file the operator can write | credential paths refused by name (`isCredentialPath`, `src/tool.zig:1057`, applied at `src/tool.zig:1158`, `src/tool.zig:1287`, `src/tool.zig:1361`); no confinement to the tree, so any other path is open (gap 5) |
| 6 | Tool output carries credentials to the model and on to the provider | host → model → provider | low: a credential under a name the rules do not know, or reached through shell indirection | secret exfiltration through a routine run | all six tools refuse or exclude a known credential name (`credential_globs`, `src/tool.zig:1009`; `credentialInCommand`, `src/tool.zig:871`; `gitPathspecs`, `src/tool.zig:615`); the run's own keys are not in a tool's environment to print (`childEnviron`, `src/main.zig:1269`) |
| 7 | A compromised release replaces the binary | GitHub → host | low: needs the release account or its token | persistent, silent code execution on every later run | sha256 sidecar, host allowlist (`checksumMatches`, `src/update.zig:283`; `hostTrusted`, `src/update.zig:218`) |
| 8 | The API key is visible in the process table | operator → host | low: needs a local reader | key theft by any other process or user on the box | none |
| 9 | A hostile or malformed provider response exhausts memory or CPU | provider → agent | medium | run killed, machine memory spent | per-response cap (`max_response_bytes`, `src/main.zig:114`), frame cap (`max_frame_bytes`, `src/main.zig:129`), error-body cap (`max_error_body_bytes`, `src/main.zig:136`), timeouts, process-group kill |
| 10 | A hostile repository writes escape sequences to the operator's terminal | repo → terminal | high: any file the model echoes | terminal spoofing, clipboard tricks | control bytes escaped in the gutter (`toolCallLine` via `chat.safeText`, `src/tool.zig:699`, `src/chat.zig:656`) and scrubbed in error text (`terminalSafe`, `src/tool.zig:750`) |
| 11 | A hostile model result spends the operator's money | model → provider | medium: a runaway or looping run | unbounded bill on the provider account | per-request `max_tokens` (`buildBody`, `src/main.zig:2090`), turn and wall-clock ceilings, and an opt-in run-wide spend ceiling (`--max-spend-tokens`, `spendCeilingReached`, `src/main.zig:1654`); nothing bounds the spend of a run that did not set one (gap 8) |
| 12 | A `[[mcp]]` table chooses a program this run executes | operator config → host | medium: needs a write to the config file, the environment or `--config` | arbitrary code execution as the operator, and every tool result the server returns reaches the model | the servers are read only from the config file (`--config`, `MICROAGENT_CONFIG` or `$HOME/.microagent/config.toml`) and never from the working tree (`config.parse`, `src/config.zig:95`; `connect`, `src/mcp.zig:378`), so a repository under review cannot add one; the server inherits the scrubbed environment, never the provider key (`childEnviron`, `src/main.zig:1269`); it is trusted exactly as far as a `bash` command the operator wrote is, and no further |
| 13 | A skill body is prompt text the model is told to follow | operator config → model | low: needs a write to a skills directory, the config file, or `MICROAGENT_SKILLS` | the run follows instructions the operator did not write, with the conversation re-sent to the provider | skills are read only from the roots the config file or the variable names, else `$HOME/.microagent/skills`, never from the working tree (`roots`, `src/skill.zig:126`; `discover`, `src/skill.zig:172`), so a repository under review cannot install one; the listing escapes control bytes (`Skills.prompt`); a body reaches the conversation only when the model calls the tool, and then as a tool result under the same cap as any other |

`microagent` is a local CLI with no listener, no server and no database. It holds no user
data of its own: what it exposes is the operator's own machine, and what an attacker wants
is the key, the source tree and the host. The one place it holds something worth stealing
on its own is the API key.

## Attack surface

### Entry points in the code

| Entry point | What arrives | Handled at |
| --- | --- | --- |
| Command line, agent mode | prompt, flags, api key in `argv` | `parseArgs`, `src/main.zig:997`; `main`, `src/main.zig:251`; the flag table at `src/main.zig:917`, which is every valued flag the run accepts: `-p/--print`, `-m/--model`, `-b/--base-url`, `-k/--api-key`, `--ca-bundle`, `--config`, `--reasoning-effort`, `--budget`, `--max-spend-tokens`, `--max-turns`, `--max-tokens`, `--stall-timeout` |
| `--ca-bundle <file>` | the PEM file whose certificates vouch for the provider and for GitHub | `net.caBundlePath`, `src/net.zig:105`; `loadCaBundle`, `src/net.zig:39`; applied at `src/main.zig:341` and `src/update.zig:939` |
| `--config <file>`, `MICROAGENT_CONFIG`, `~/.microagent/config.toml` | reply-style levels, skill roots and `[[mcp]]` tables: what the prompt says and what the run starts | `styleConfigPath`, `src/main.zig:1433`; `loadConfig`, `src/main.zig:1309`; `config.parse`, `src/config.zig:95`; cap `max_config_bytes`, `src/main.zig:131` |
| `[[mcp]]` tables in that config | programs this run starts over stdio, and the tools they offer | `connect`, `src/mcp.zig:378`; `handshake`, `src/mcp.zig:448` |
| `skills` in that config, `MICROAGENT_SKILLS`, `~/.microagent/skills` | `SKILL.md` bodies the model may load, as prompt text | `roots`, `src/skill.zig:126`; `discover`, `src/skill.zig:172`; `call`, `src/skill.zig:320`; cap `max_skill_bytes`, `src/skill.zig:40` |
| Command line, `update` | `--check`, `--repo` | `parseArgs`, `src/update.zig:848`; `run`, `src/update.zig:885`; dispatched from `main` at `src/main.zig:251` |
| `MICROAGENT_MODEL`, `MICROAGENT_BASE_URL`, `MICROAGENT_REASONING_EFFORT` | endpoint, model, response style | `envValue`, `src/main.zig:672`; read at `src/main.zig:281-283` |
| `MICROAGENT_MAX_TURNS`, `MICROAGENT_MAX_TOKENS` | loop and response ceilings | `max_turns_default`, `src/main.zig:83`; `default_max_tokens`, `src/main.zig:98`; both through `ceiling`, `src/main.zig:722` |
| `MICROAGENT_API_KEY`, `OPENAI_API_KEY`, `OPENROUTER_API_KEY`, `DEEPSEEK_API_KEY` | provider credential | `key_vars`, `src/main.zig:1180`; resolved at `resolveKey`, `src/main.zig:1126` |
| `~/.secrets/openrouter` | provider credential, up to 4 KB | path built in `resolveKey`, `src/main.zig:1126`; read by `readSecret`, `src/tool.zig:142`; cap `max_secret_bytes`, `src/tool.zig:33` |
| `MICROAGENT_CA_BUNDLE`, `SSL_CERT_FILE` | the trust anchors for the provider host and for GitHub | `caBundlePath`, `src/net.zig:105`, read at `src/main.zig:299`; loaded at `src/main.zig:341` and `src/update.zig:939` |
| `MICROAGENT_CONFIG`, `~/.microagent/config.toml` | reply-style levels, 64 KB cap | `styleConfigPath`, `src/main.zig:1433`; `loadConfig`, `src/main.zig:1309`; cap `max_config_bytes`, `src/main.zig:131` |
| `MICROAGENT_CAVEMAN`, `MICROAGENT_PONYTAIL` | reply-style levels, overriding the config file | `loadConfig`, `src/main.zig:1309`; read at `src/main.zig:1322` |
| `MICROAGENT_BUDGET_SECONDS`, `--budget` | wall-clock ceiling on the run, suspended time included | `optionalCeiling`, `src/main.zig:860`; carried by `Budget`, `src/main.zig:1539` |
| `MICROAGENT_MAX_SPEND_TOKENS`, `--max-spend-tokens <n>` | run-wide token ceiling, counted before each turn | `optionalCeiling`, `src/main.zig:860`; read at `src/main.zig:305`; enforced at `src/main.zig:1752` |
| `MICROAGENT_STALL_TIMEOUT`, `--stall-timeout <s>` | seconds the response socket may stay silent, 120 s by default | `default_stall_timeout_s`, `src/main.zig:103`; read at `src/main.zig:297`; set on the socket at `src/main.zig:2219` |
| `MICROAGENT_SESSION_DIR` | where the JSONL run log is written | `sessionDir`, `src/session.zig:27`; read at `src/main.zig:308` |
| `MDEBUG` | writes protocol notes and the resolved configuration to stderr, never a key | `debugEnabled`, `src/main.zig:680`; `traceConfig`, `src/main.zig:1374` |
| `GITHUB_TOKEN` | credential, presented only to `api.github.com`, and never to a tool subprocess | `githubBearer`, `src/update.zig:759`; narrowed by `bearerFor`, `src/update.zig:256`; applied at `src/update.zig:943` (API), `src/update.zig:1022` (sidecar), `src/update.zig:1024` (asset) |
| GitHub release JSON | tag, page URL, asset names, download URLs | `parseRelease`, `src/update.zig:368` |
| Downloaded asset and `.sha256` sidecar | bytes that become the running executable | `fetchAsset`, `src/update.zig:672`; `fetchBody`, `src/update.zig:634`; installed by `replaceVerified`, `src/update.zig:325` |
| Streamed provider response (SSE) | model text and tool calls | `streamChat`, `src/main.zig:2157`; `applyFrame`, `src/main.zig:3011` |
| Tool call arguments | what the model wants done | `runTool`, `src/tool.zig:648` |
| Files in the working tree | the model's evidence, and its instructions | `toolRead`, `src/tool.zig:1156`; system prompt at `src/main.zig:138` |

There is no network listener, no webhook, no message consumer, no scheduled job and no
IPC. The only outbound traffic microagent itself makes is to the provider's base URL and to
GitHub. An MCP server it starts is a separate program and may talk to whatever its operator
configured it to talk to; that traffic is the server's, not this binary's, and the registry
is the operator's statement that the program is trusted.

### Surface added by deployment

- The binary runs whatever is on `PATH`: `rg`, `ast-grep`, `git` and `/bin/sh`
  (`toolSearch`, `src/tool.zig:1440`; `toolAst`, `src/tool.zig:1474`; `toolGit`, `src/tool.zig:472`; `toolBash`, `src/tool.zig:881`). A hostile `PATH` entry is a
  hostile tool, and `bash` runs whatever name the model typed.
- The Harbor adapter runs the binary inside third-party task containers with the provider
  key in the container environment (`integrations/harbor/microagent_agent.py:482`,
  `api_key()` at `:138`), so the blast radius of a poisoned task is the container plus
  the key. The endpoint is checked at the command line before a container starts
  (`base_url`, `integrations/harbor/microagent_agent.py:220`): a `MICROAGENT_BASE_URL` with
  no scheme, or a plaintext one that is not loopback, is refused there rather than by the
  binary inside the container, where the key has already been handed over.
- CI builds release assets with the workflow's own token and publishes them with
  `gh release create` (.github/workflows/release.yml:139); that account is the trust
  anchor for every future `microagent update`.

## Trust boundaries

1. **Operator → agent.** The prompt is untrusted input, the same as any other. There is
   no validation point: `setPrompt` (`src/main.zig:1103`) stores it and
   `openConversation` (`src/main.zig:5323`) appends it to the conversation verbatim.
2. **Repository content → model → host.** The most important boundary in the project.
   The model reads files, source and tests, and issues tool calls from what it read
   (`system_prompt`, `src/main.zig:138`). Nothing in the program separates "the model's
   own plan" from "an instruction the model found in a file"; the only thing that does is
   an instruction in the prompt itself.
3. **Provider → agent.** The streamed reply decides the next action. The validation point
   is `applyFrame` (`src/main.zig:3008`), which bounds the shape, not the intent.
4. **Agent → provider.** The key goes out in an `authorization` header
   (`authHeaders`, `src/main.zig:2135`) to whatever host `base_url` named, after the
   scheme check at `src/main.zig:334`.
5. **Model → filesystem and process.** `bash` runs `/bin/sh -c` with the model's string
   (`toolBash`, `src/tool.zig:881`); `read`, `write` and `edit` take any path
   (`toolRead`, `src/tool.zig:1156`; `toolWrite`, `src/tool.zig:1280`; `toolEdit`, `src/tool.zig:1355`).
6. **GitHub → host.** `update` downloads bytes and writes them over the running
   executable (`fetchAsset`, `src/update.zig:672`; `replaceVerified`, `src/update.zig:325`). Validation point: `decide` (`src/update.zig:310`).
7. **Secrets → process.** The key enters from `argv`, the environment or a file, lives in
   process memory for the run, and leaves only in the `authorization` header. It is never
   written to the session log or to a tool result.
8. **Operator config → host (MCP).** The `[[mcp]]` tables name programs the run starts as
   children before the first request, and the tools they report are advertised to the model
   and dispatched to them (`config.parse`, `src/config.zig:95`; `connect`, `src/mcp.zig:378`).
   Validation point: the tables are read from the config file resolved by `--config`, the
   variable or `$HOME/.microagent/config.toml`, and from nowhere in the tree
   (`styleConfigPath`, `src/main.zig:1433`); the children inherit the scrubbed environment, so
   the provider key is not among them (`childEnviron`, `src/main.zig:1269`); a server whose
   name or tool name cannot be spelled in a tool name is refused (`validName`,
   `src/mcp.zig:362`). What a configured server does with its own authority is the operator's
   decision, exactly as a `bash` command they write is.
9. **Operator skills → model.** A `SKILL.md` body is instruction text the model is told to
   follow, and it reaches the conversation only when the model calls the `skill` tool
   (`call`, `src/skill.zig:320`). Validation point: the roots are the config file's `skills`
   list, the directories `MICROAGENT_SKILLS` names, or the operator's home directory, never
   the tree (`roots`, `src/skill.zig:126`; `discover`, `src/skill.zig:172`).

Privilege transitions in this program are total rather than gradual: the moment the model
calls `bash`, the run has the operator's full authority, with no intermediate step. There
is no user confirmation between a model decision and a command.

## Assets

| Asset | Why it matters | Where it lives |
| --- | --- | --- |
| Provider API key | bills, model access, provider account | `argv` or environment, then process memory |
| `GITHUB_TOKEN` | releases API access, and repository scope beyond it | environment, then an `Authorization` header on `api.github.com` only (`bearerFor`, `src/update.zig:256`); absent from every tool subprocess (`secret_env_vars`, `src/main.zig:1248`) |
| `~/.secrets/openrouter` | the same key, on disk | read in `resolveKey`, `src/main.zig:1126` |
| Source tree and everything in it | `.env`, keys, unreleased work | read by `toolRead` (`src/tool.zig:1156`), a credential refused at `src/tool.zig:1158`, sent to the provider in the request body |
| Host compute and credentials | the shell inherits the environment less this binary's own credentials | `childEnviron`, `src/main.zig:1269` |
| The binary itself | a replaced copy runs on every later invocation | replaced at `src/update.zig:325` |
| Run logs | working directory, model, token counts, finish reason | `~/.microagent/sessions`, capped at 200 records (`pruneSessions`, `src/session.zig:316`; `max_session_logs` (`src/session.zig:242`) |
| Token spend | `--max-turns` bounds turns and `--max-spend-tokens` bounds money, both only when asked for | `max_turns_default`, `src/main.zig:83`; `default_max_tokens`, `src/main.zig:98`; `spendCeilingReached`, `src/main.zig:1654` |

## Threats per boundary

### Operator → agent (STRIDE: spoofing, tampering, information disclosure)

- A prompt that names a hostile base URL or a hostile `--repo` steers the whole run.
  Both are operator inputs, so this is a threat only where an automated harness passes a
  task's text straight through (`bench/gauntlet.sh`).
- A prompt of unbounded length enters the conversation with no size cap
  (`setPrompt`, `src/main.zig:1106`; appended at `openConversation`, `src/main.zig:5326`; the request body grows with it.

### Repository content → model → host (elevation of privilege, information disclosure)

- **Prompt injection through source files.** A file, a test fixture, an issue template or
  a `CLAUDE.md`/`AGENTS.md` in the tree can say "run `curl … | sh`". The model reads it
  with the ordinary `read` tool (`src/tool.zig:1045`) and there is no instruction
  provenance, so the injected text is as trusted as the operator's prompt. The system
  prompt tells the model to treat tool output as data and to report such a file instead of
  acting on it (`src/main.zig:138`), which is a control a hostile file can argue with. This
  is the project's dominant risk and it is a design property, not a bug.
- The same path exfiltrates: the model can `read` a file and the file's bytes go into the
  next request body (`buildBody`, `src/main.zig:2090`).
- A hostile repository can also reach the terminal: bytes a tool echoes reach the gutter
  line (`toolCallLine`, `src/tool.zig:699`) and the provider's text reaches stdout, which
  is the answer the run was asked for and is deliberately left unescaped.

### Provider → agent (spoofing, tampering, denial of service)

- A hostile or coerced endpoint chooses every tool call. A single response can carry up to
  64 calls (`max_tool_calls`, `src/main.zig:105`, enforced by the index check at
  `src/main.zig:2945` and the index clamp in `applyCallDelta`) and they run as the
  operator.
- A tool call's name and argument object are the provider's own text and are parsed
  from bytes the model read out of the tree. They are fuzzed from the argument JSON
  to the gutter line and the limits it produces: the line stays one line inside its
  buffer with no byte a terminal acts on, and every count the model wrote is inside
  its ceiling before a subprocess starts (`fuzzToolCall`, `src/tool.zig:2334`; test at
  `src/tool.zig:2334`).
- A call the provider never gave an index for, or gave no id or no name for, is
  dropped rather than dispatched, as is one whose arguments are not a JSON object
  (`keepRunnableCalls`, `src/main.zig:2569`; `argumentsAreAnObject`, `src/main.zig:2600`, and the count is reported rather than passing for a turn
  that dispatched everything (`src/main.zig:2597`).
- The same transport is at-least-once: a relay that reconnects replays from the
  last event it saw and a proxy that retries a chunk re-sends it. A call whose
  `id` the response already carries is dropped and the first kept
  (`indexOfCallId`, `src/main.zig:2589`), so a replayed `bash` runs once rather
  than twice.
- A stream that never sends `[DONE]` grows the turn until the caps at
  `src/main.zig:114` and `src/main.zig:129` stop it, and the run ends as truncated
  (`truncatedNotice`, `src/main.zig:2491`).
- A provider that accepts the connection and then never sends a byte is bounded by a
  receive timeout on the response socket, 120 s unless the operator raises it
  (`default_stall_timeout_s`, `src/main.zig:103`; `setStallTimeout`,
  `src/main.zig:2148`, applied at `src/main.zig:2219`). The value is checked only for
  being a positive number (`ceiling`, `src/main.zig:722`), so nothing above it refuses a
  figure larger than any run should wait, and a hostile environment that sets it very
  high turns the stall bound off (gap 12).
- An error body from the provider is printed on stderr through `terminalSafe`, `src/tool.zig:750` and is capped at 16 KB (`max_error_body_bytes`,
  `src/main.zig:136`), so control bytes are scrubbed and it cannot repaint the terminal.
- Frames that are not JSON are counted and dropped (`applyFrame`, `src/main.zig:3011`;
  the counter at `src/main.zig:2410`); they are not fatal, and the run continues on a
  partial turn, with the count reported at `src/main.zig:2410`.

### Agent → provider (information disclosure, spoofing)

- The key is refused to any base URL that would put it on the wire in the clear:
  `baseUrlCarriesKey` (`src/main.zig:739`) requires `https`, or `http` on loopback, and
  `main` fails the run otherwise (`src/main.zig:251`). Loopback is judged by exact match
  in `isLoopbackHost` (`src/main.zig:792`), so `127.evil.com` and `localhost.evil.com`
  do not qualify; the policy is pinned by the test at `src/main.zig:3633`.
- A key taken from `OPENAI_API_KEY` or `DEEPSEEK_API_KEY` while the base URL is still the
  built-in OpenRouter one reaches OpenRouter, and the run says so on stderr before the
  first request (`keyNamesOtherProvider`, `src/main.zig:767`, warned at
  `src/main.zig:337`). It is a warning and not a refusal: the run goes on and sends the
  key, so the whole of the control is that it is no longer silent. A base URL the operator
  named is never asked about, deliberately, because a self-hosted gateway is a legitimate
  destination for any provider's key.
- What that check does not do is constrain *which* https host. `MICROAGENT_BASE_URL` or
  `--base-url` may name any host, and the key follows it there.
- Every diagnostic naming the base URL clips and quotes it (`clip`, `src/main.zig:882`),
  so a value carrying escape sequences cannot repaint the terminal on its way to an error
  message.
- `--api-key` puts the credential in `argv` (`resolveKey`, `src/main.zig:1126`), which is
  world-readable in the process table for the life of the run.
- The conversation carries everything the model read, on every turn, by design
  (`buildBody`, `src/main.zig:2090`).
- Redirects are not followed: `.redirect_behavior = .unhandled` (`src/main.zig:2087`)
  makes a 3xx an error status, so a provider that answers with a `Location` cannot walk
  the API key off to whoever it names. The header carrying the key is the one the request
  writer reads (`authHeaders`, `src/main.zig:2135`); it is not a separately
  privileged field, so the unhandled redirect is the whole of this control.
- A base URL carrying `user:password@` has that userinfo replaced wherever the URL is
  printed (`displayUrl`, `src/main.zig:837`; `redactUserinfo`, `src/main.zig:846`).
- `MICROAGENT_CA_BUNDLE`, `SSL_CERT_FILE` and `--ca-bundle` decide who vouches for that
  host: `loadCaBundle` (`src/net.zig:39`) adds the named file's certificates to the
  client's store, and the system store is still scanned, so a bundle naming one more
  root is enough to terminate the connection that carries the key. The path is
  operator or environment input, and nothing constrains what the file may contain. What
  is refused is a bundle that cannot be read or that holds no certificate: an empty
  trust store is reported and the system store is used instead. The same path governs
  `update` (`src/update.zig:939`), where it covers the release download.

### Model → filesystem and process (elevation of privilege, tampering, denial of service)

- `bash` is arbitrary command execution with the operator's identity and working
  directory (`toolBash`, `src/tool.zig:881`). The spawned shell inherits the environment
  less this binary's own credentials (`childEnviron`, `src/main.zig:1269`, over
  `secret_env_vars`, `src/main.zig:1248`, which is the four provider keys plus
  `GITHUB_TOKEN`), so `bash env` and `bash printenv` cannot put the run's own key in the
  transcript. A command naming a credentials file is refused on the same name rule the
  other tools apply (`credentialInCommand`, `src/tool.zig:871`, applied at
  `src/tool.zig:888`); that rule reads the command's words rather than a parsed shell, so
  a file reached through indirection is not caught.
- `read`, `write` and `edit` accept absolute paths and do not confine writes to the
  working tree (`src/tool.zig:871`, `src/tool.zig:871`, `src/tool.zig:871`). Each refuses
  a path the credential tables name, and nothing else.
- `write` and `edit` write through a temporary file and a rename, following a symlink to
  the real file first and carrying the destination's own permission bits over
  (`writeFileAtomic`, `src/tool.zig:1332`; `permission_bits`, `src/tool.zig:1313`), so a
  symlink planted in the tree redirects a write, and a rewritten file comes back with the
  mode it had rather than with the process umask's.
- `ast` with `rewrite` set applies its replacement to every match
  (`toolAst`, `src/tool.zig:1474`), so a single model turn can rewrite a whole file set.
  A rewrite that would still match the text it produced is refused
  (`astRewriteRefusal`, `src/tool.zig:1565`), which is evidence the run reads back
  and not a sandbox: a replacement that re-matches through a form the pattern's
  literal text does not spell is still applied.
- Bounded today: 60 s tool timeout (`tool_timeout_ms`, `src/tool.zig:49`), 120 s default
  (`default_bash_timeout_ms`, `src/tool.zig:59`) and 600 s ceiling for `bash`
  (`max_bash_timeout_ms`, `src/tool.zig:54`, applied through
  `bashTimeoutMs` at `src/tool.zig:798` and `boundedMs` at `src/tool.zig:70`, and the
  budget's remaining time through `Budget`, `src/main.zig:1539`), captured output held at
  96 KB and cut to the 24 KB the model reads (`max_tool_output`, `src/tool.zig:23`,
  `runCapped`, `src/tool.zig:1638`), `--max-turns`
  (`src/main.zig:88`), and a wall-clock budget (`src/main.zig:1539`).

### GitHub → host (spoofing, tampering, elevation of privilege)

- The release JSON is attacker-shaped: every field in it becomes a tag, an asset name or a
  URL the updater acts on (`parseRelease`, `src/update.zig:368`). It is fuzzed against
  exactly that (`fuzzRelease`, `src/update.zig:2132`; `fuzzSidecar`, `src/update.zig:2226`).
- The `--repo` the updater requests from is the caller's own text, and it is
  fuzzed from the command line to the URL it becomes: a repo no argument carried
  fails, a repo `validRepo` refuses never reaches a request, and one it accepts
  only ever names `api.github.com` (`releaseApiUrl`, `src/update.zig:208`; harness
  `fuzzUpdateArgs`, `src/update.zig:1490`).
- A body over the cap is refused while it streams, not after (`fetchInto`, `src/update.zig:533`, against `Capped` at `src/update.zig:426`); the API body is capped
  at 10 MB, the asset at 256 MB, the sidecar at 64 KB (`src/update.zig:22-24`).
- `GITHUB_TOKEN` is narrowed to the releases API before any request carries it:
  `bearerFor` (`src/update.zig:256`) returns the token only for a URL under
  `https://api.github.com/`, and returns null for the asset and the sidecar, which
  GitHub serves anonymously (`src/update.zig:943`, `src/update.zig:1022`, `src/update.zig:1024`). The grant is therefore as wide
  as the one request that needs it, not as wide as the host allowlist. What remains: a
  repository-scoped token is still presented in full to that one API, so a redirect or
  error on the releases API is the only place it can leak, and the unhandled redirect is
  the control there.
- The sidecar is fetched from the same release as the asset, so the checksum proves the
  download was not corrupted in transit, not that the release was authorized. The trust
  anchor is the GitHub account and the TLS session, nothing more. There is no signature,
  no attestation and no pinned digest.
- A CA bundle named by the environment or `--ca-bundle` is added to the trust store the
  download is verified against (`loadCaBundle`, `src/net.zig:39`, called at
  `src/update.zig:939`), so a bundle carrying one attacker-issued root substitutes the
  asset and the sidecar together and the checksum still matches. The host allowlist does
  not help: both URLs are on a GitHub host, the requests are addressed there, and the
  certificate presented is one the client was told to accept.
- The replacement follows a symlink to the real file (`replaceVerified`, `src/update.zig:325`, through `net.resolveSymlinkTarget`, `src/net.zig:150`), so a
  symlinked install under a path the operator does not own writes wherever the link
  points.

### Classes this tree has already fixed

`CHANGELOG.md` records the same handful recurring: base-URL credentials printed unredacted
into the run's own error lines, a control character in a tool argument repainting the
terminal, a base URL with escape sequences reaching stderr unescaped, a tool result or
assistant text breaking the JSON of the next request, a credential reaching the provider
through a tool result, a committed `.env` printed by a path-scoped `git show`, a
repository-scoped token handed to the asset host, and memory held for the length of a
stream. The `Unreleased` section adds three more of the same kinds: a structural rewrite
that re-applied itself to its own output, a tool call delivered twice by a reconnecting
relay and dispatched twice, and a subprocess that had printed its findings and then failed
having them thrown away. Shipped after that entry was written: a credential named at a
depth in the path rather than at the leaf, which `search` and `git` already excluded and
`read`, `write`, `edit` and `ast` still read (`isCredentialPath`, `src/tool.zig:1057`), an
`ast --rewrite` that wrote a credentials file while the refusal told the model to fetch it
through `bash` (`credentialRefusal`, `src/tool.zig:1127`), and a key file over the secret
cap reported as unreadable rather than as the wrong shape (`resolveKey`, `src/main.zig:1126`).
The `Unreleased` section now also names a key minted for one provider reaching another
without a word about it (`keyNamesOtherProvider`, `src/main.zig:767`) and a tool call that
closed both its pipes and then slept, holding the turn past the deadline the call already
had (`waitBounded`, `src/tool.zig:1741`). Both are the shape the rest of this list has:
a control the code relied on being implied, which turned out to be a separate thing.
Each has a control named above; a regression in any of them is the same bug returning.

## Mitigations in the code

| Control | Covers | Where |
| --- | --- | --- |
| System prompt names tool output, file contents and command output as data, and tells the model to report a file that gives orders | prompt injection through a file, at the model rather than in the program | `system_prompt`, `src/main.zig:138` |
| `owner/name` validation before a URL exists | URL injection through `--repo` | `repoPartOk`, `src/update.zig:181`; `validRepo`, `src/update.zig:191`; `releaseApiUrl`, `src/update.zig:208` |
| Host allowlist: `https` on `github.com`, `*.github.com`, `*.githubusercontent.com`, no userinfo, checked on the page URL and on both asset URLs | asset and page download from a lookalike host | `hostTrusted`, `src/update.zig:218`; `trustedGithubUrl`, `src/update.zig:230`; applied inside `decide` at `src/update.zig:310` |
| `GITHUB_TOKEN` is presented only to `https://api.github.com/`, prefix-compared octet by octet, so a lookalike host, a userinfo URL and a path carrying the API name all get nothing; the asset and the sidecar go out unauthenticated | a repository-scoped token handed to the asset CDN, to `api.github.com.evil.com`, or to a path that merely contains the API name | `bearerFor`, `src/update.zig:256`; applied at `src/update.zig:943`, `src/update.zig:1022`, `src/update.zig:1024` |
| A CA bundle that cannot be read, or that holds no certificate, is refused and the system store is used instead | a bundle silently emptying the trust store, so every request fails as if the machine shipped no certificates | `loadCaBundle`, `src/net.zig:39` |
| sha256 sidecar verification before the verdict is `replaced` | corrupted or substituted download | `checksumMatches`, `src/update.zig:283`; `decide`, `src/update.zig:310` |
| Version comparison refuses a downgrade | installing an older build over a newer one | `compareVersions`, `src/update.zig:99`; `fetchesAsset`, `src/update.zig:276` |
| Atomic replace, only on `.replaced` | partial write, write on a refusal | `decide`, `src/update.zig:310`; `replaceVerified`, `src/update.zig:325`; `replaceExecutable`, `src/update.zig:691` |
| The key is refused on a plaintext `http` base URL off loopback, every octet range-checked | the key crossing a network path in the clear, or to a name spelled like an address | `baseUrlCarriesKey`, `src/main.zig:742`; `isLoopbackHost`, `src/main.zig:795`; enforced at `src/main.zig:334`; test at `src/main.zig:3633` |
| A run whose key came from `OPENAI_API_KEY` or `DEEPSEEK_API_KEY` while the base URL is still the built-in one is told so on stderr before the first request | a key minted for one provider reaching another, which happens with no hostile input at all, only a variable the operator set and a URL nobody set | `keyNamesOtherProvider`, `src/main.zig:767`; `foreign_key_vars`, `src/main.zig:755`; warned at `src/main.zig:337` |
| Userinfo redacted from every printed URL, and every quoted diagnostic clipped and escaped | a password in the base URL copied into stderr, or a base URL carrying escape sequences repainting the terminal | `displayUrl`, `src/main.zig:837`; `redactUserinfo`, `src/main.zig:846`; `clip`, `src/main.zig:882`; `quoteUntrusted`, `src/update.zig:51` |
| Redirects unhandled | the key replayed to a host the provider names | `src/main.zig:2210` |
| Argument vectors instead of a shell for `search`, `ast`, `git` | shell injection through a pattern or a path | `toolSearch`, `src/tool.zig:1440`; `toolAst`, `src/tool.zig:1474`; `toolGit`, `src/tool.zig:472` |
| `--` separator and a `rev` that may not start with `-` | an option smuggled in as a path or a revision | `gitArgv`, `src/tool.zig:562`; `gitPathspecs`, `src/tool.zig:615`; `toolSearch`, `src/tool.zig:1440`; `toolAst`, `src/tool.zig:1474` |
| Fixed git subcommands, no writes through the `git` tool | `bash`-strength git | `gitArgv`, `src/tool.zig:562` |
| Every tool subprocess is its own group leader; the group is SIGKILLed and takes the terminal's interrupt with it | orphaned build trees holding resources, and a Ctrl+C that leaves a build writing files | `signalGroup`, `src/tool.zig:155`; `watchToolGroup`, `src/tool.zig:177`; `forwardInterruptsToToolGroup`, `src/tool.zig:186`; `runCapped`, `src/tool.zig:1638` |
| Output, response, frame, error-body and config caps; the response cap covers the whole response, not each field | memory exhaustion from a tool, a stream, an error body or a file | `max_tool_output`, `src/tool.zig:23`; `max_response_bytes`, `src/main.zig:114`; `max_frame_bytes`, `src/main.zig:129`; `max_error_body_bytes`, `src/main.zig:136`; `max_config_bytes`, `src/main.zig:131` |
| Tool-call index cap and a saturating cast | a provider asking for billions of slots, or a wrapped index on a 32-bit build | `max_tool_calls`, `src/main.zig:105`; check at `src/main.zig:2945` |
| Per-turn cap on what a turn's tool results add to the conversation; every call still answers, with a marker past it | one response asking for 64 full-size results, which is a 1.5 MB request billed before the next turn compacts | `max_turn_tool_output`, `src/main.zig:76`; `carriedToolResult`, `src/main.zig:3438`; check at `src/main.zig:3410` |
| A tool call with no index, no id or no name, or with arguments that are not an object, is dropped rather than dispatched, and the drop is reported | a partial or malformed stream entry becoming a command | `keepRunnableCalls`, `src/main.zig:2569`; `argumentsAreAnObject`, `src/main.zig:2600`; report at `src/main.zig:2482` |
| A call whose `id` the response already carried is dropped and the first kept | a relay or proxy replaying a frame, running `bash` twice or writing a file twice | `indexOfCallId`, `src/main.zig:2589`; test at `src/main.zig:6400`; report at `src/main.zig:2483` |
| All six tools refuse a credentials file by name, extension or directory, and the name rules run on every component of the path rather than on the leaf alone, so `deploy/.env/prod` is refused the way `.env` is: `read` and `write` and `edit` and `search` and `ast` on a named path, `bash` on a command naming one | a `.env`, a private key or a `~/.secrets` file put into the model context, or rewritten; a credential at a depth `search` and `git` already excluded while the tools still read it | `isCredentialPath`, `src/tool.zig:1057`; tables at `src/tool.zig:930-943`; refusals at `src/tool.zig:1158`, `src/tool.zig:1287`, `src/tool.zig:1361`, `src/tool.zig:1448`, `src/tool.zig:1485`, `src/tool.zig:888`, and `git` at `src/tool.zig:489`, `src/tool.zig:506`, `src/tool.zig:509`; test at `src/tool.zig:2814` |
| The credentials refusal distinguishes the call that would have changed the file from the one that would not, so `ast` with `rewrite` refuses a credentials path with the advice that no tool rewrites a key rather than the one that sends the model to `bash` | a `write` through `--update-all` on a key file, and a model walking into the same refusal one turn later | `credentialRefusal`, `src/tool.zig:1127`; applied at `src/tool.zig:1485`; test at `src/tool.zig:2992` |
| `search` and `ast` skip the same files as traversal globs, and `git` excludes them from the diff and the show, including when the call names a path | a credential reaching the provider through a match or a patch | `credential_globs`, `src/tool.zig:1009`; `credential_pathspecs`, `src/tool.zig:1020`; `gitPathspecs`, `src/tool.zig:615` |
| `write` refuses a call with no `content` | a truncated or forgotten argument emptying a file | `toolWrite`, `src/tool.zig:1280` |
| `edit` refuses a replacement equal to, or still containing, the text it replaces | a re-issued call rewriting the same file twice | `toolEdit`, `src/tool.zig:1355` |
| `write` and `edit` write through a rename, following a symlink and keeping the destination's permission bits | a half-written file where a whole one was, a link replaced by a regular file, and a `0600` file coming back `0644` | `writeFileAtomic`, `src/tool.zig:1332`; `permission_bits`, `src/tool.zig:1313`; `resolveSymlinkTarget`, `src/net.zig:150` |
| `bash` timeout is capped at 600 s and clipped to the budget left | model-chosen output running with no deadline at all | `max_bash_timeout_ms`, `src/tool.zig:54`; `bashTimeoutMs`, `src/tool.zig:798`; `Budget`, `src/main.zig:1539` |
| A tool call's deadline covers the wait for the child as well as the drain of its pipes, and the process group is signalled when it passes | a command that closes both pipes and then sleeps holding the turn, the process-group reap never firing and `--budget` not kept | `waitBounded`, `src/tool.zig:1741`; deadline taken at `src/tool.zig:1681` |
| `max_tokens` on every request | one turn generating until the provider's own limit stopped it | `default_max_tokens`, `src/main.zig:98`; request body at `src/main.zig:2100` |
| `--max-spend-tokens` stops starting turns once the run has billed that many tokens, counted before each turn, and announces itself at 80% of the cap | a run whose conversation re-sends itself every turn and bills more with fewer turns than one that does; the run that was started without a ceiling | `optionalCeiling`, `src/main.zig:860`; `spendCeilingReached`, `src/main.zig:1654`; `spend_alarm_percent`, `src/main.zig:1642`; check at `src/main.zig:1752`; test at `src/main.zig:4083` |
| A subprocess that failed keeps what it printed, and only `bash` reports an exit status | a build that printed every error and then timed out reaching the model as a bare error, so the next turn re-ran it | `failedOutput`, `src/tool.zig:419`; `Partial`, `src/tool.zig:1608`; `bash_exit_note`, `src/tool.zig:42` |
| An `ast --rewrite` whose replacement still matches the pattern's own literal text is refused, as is a pattern of metavariables alone | a rewrite that re-applies itself to its own output on the next run | `astRewriteRefusal`, `src/tool.zig:1565`; test at `src/tool.zig:4222` |
| Control bytes escaped in the gutter, scrubbed in error bodies, bounded through one helper | terminal escape injection from repo content, from a command-line argument, and from a config key or a `--repo` value | `toolCallLine`, `src/tool.zig:699`; `terminalSafe`, `src/tool.zig:750`; `chat.safeText`, `src/chat.zig:656`; `clip`, `src/main.zig:882` and `quoteUntrusted`, `src/update.zig:51` |
| Non-JSON frames counted and reported; a stream without `[DONE]` fails the turn | a truncated answer read as a finished one | `applyFrame`, `src/main.zig:3011`, counter reported at `src/main.zig:2410`; `truncatedNotice`, `src/main.zig:2491` |
| Retry with capped exponential backoff on weather-shaped statuses and on failures before the response head is readable; a failure after the head is not retried; a `Retry-After` longer than two minutes is clamped to two, and an out-of-range year is refused | a dropped connection or a rate limit ending the run; a re-sent turn billed twice; a hostile `Retry-After` year overflowing the epoch multiply | retry loop, `src/main.zig:2203`; `net.retryableStatus`, `src/net.zig:314`, `worthAnotherAttempt` (`src/main.zig:3555`), `waitBeforeRetry` (`src/main.zig:3568`), `net.retryBackoffMs` (`src/net.zig:304`), `max_attempts` (`src/main.zig:3525`), `max_retry_after_ms` (`src/net.zig:324`), `httpDateYear` (`src/net.zig:484`); the same narrowing in `src/update.zig:565-570` |
| Session log created exclusively at `0o600`, and the store directory this run creates at `0o700`; the walk counts every log it finds, orders them by the stamp in the name and deletes the oldest past 200 by the path relative to the store root | one run erasing another's log, unbounded growth, a log nested below the root counted toward the cap while nothing is deleted for it, and on a shared account every other account reading the prompts, the tool arguments and the bytes a tool read out of the tree, which is the material the tools themselves refuse to send the provider | `createSessionLog`, `src/session.zig:131`; `log_file_mode` `src/session.zig:113`, `log_dir_mode` `src/session.zig:114`; `pruneSessions`, `src/session.zig:316`; `pruneSessionsTo`, `src/session.zig:339`; `max_session_logs`, `src/session.zig:242` |
| Receive timeout on the response socket, so a provider that accepts the connection and sends nothing does not hold the turn | a silent provider holding a run open until a turn or the wall clock stops it | `default_stall_timeout_s`, `src/main.zig:103`; `setStallTimeout`, `src/main.zig:2148`; applied at `src/main.zig:2219` |
| Values validated where they are set | a mistyped level or ceiling reaching the wire as a 400 | `ceiling`, `src/main.zig:722`; `optionalCeiling`, `src/main.zig:860` |
| Fuzz corpora for the parsers that take untrusted bytes: the release body, the sidecar, the completion stream, the config file, both command lines, a JSON string, a tool call, a quoted value, a provider error body, the session store's names and its record | malformed provider, release, config, command-line, tool-call, session-store or terminal-facing input | `fuzzRelease` (`src/update.zig:2132`), `fuzzSidecar` (`src/update.zig:2226`), `fuzzUpdateArgs` (`src/update.zig:1490`), `fuzzStream` (`src/main.zig:7165`), `fuzzArgs` (`src/main.zig:4309`), `fuzzConfig` `src/config.zig:720`, `fuzzJsonString` `src/chat.zig:1285`, `fuzzToolCall` (`src/tool.zig:2334`), `fuzzSafeText` `src/chat.zig:1122`, `fuzzTerminalSafe` (`src/tool.zig:2742`), `fuzzStoreNames` (`src/session.zig:1248`), `fuzzSessionRecord` (`src/session.zig:1368`) |

### Gaps, ranked by exploitability and impact

1. **No confinement on model-driven execution.** `bash`, `write`, `edit` and an `ast`
   rewrite run with full operator authority, and the instructions that trigger them can
   come from a file the run reads. The system prompt asks the model not to act on such a
   file (`src/main.zig:138`), which is the same trust the operator already placed in the
   prompt. The model, not the operator, is the last gate.
2. **The credential rule is a name rule, and `bash` matches it on words.** All six tools
   refuse a path the tables name, at any depth in the path rather than only at the leaf
   (`isCredentialPath`, `src/tool.zig:1057`), so none of them can put a known `.env` or
   private key in the model context. Two ways around it remain. A credential under a name
   the tables do not carry is still read. And `credentialInCommand`
   (`src/tool.zig:871`) tokenizes the command rather than parsing a shell, so a command
   that assembles a path at run time reaches the file. The run's own keys are the case
   that mattered most, and it is closed structurally rather than textually: no tool
   subprocess inherits them (`secret_env_vars`, `src/main.zig:1248`).
3. **A named CA bundle is trusted without a policy.** `MICROAGENT_CA_BUNDLE`,
   `SSL_CERT_FILE` and `--ca-bundle` add whatever the file holds to the trust store of the
   provider connection and of the release download (`loadCaBundle`, `src/net.zig:39`;
   `src/main.zig:341`; `src/update.zig:939`). A bundle naming one attacker-issued root is a
   machine in the middle for both, and the sha256 sidecar it serves hashes as published, so
   the updater installs what it was handed. The system store is still scanned, which makes
   the added root additional rather than a replacement, and that is the whole of the check.
4. **No host policy on `base_url`, only a scheme policy.** The key never goes out over
   plaintext `http` off loopback, but `MICROAGENT_BASE_URL` or `--base-url` may name any
   `https` host and the key follows it. A poisoned environment variable turns a review run
   into a key handoff to whoever answers on that name.
5. **The tools are not confined to the working tree.** `read`, `write` and `edit` take an
   absolute path and will follow it, `writeFileAtomic` (`src/tool.zig:1332`) follows a
   symlink before writing, and `ast --rewrite` applies its replacement to every match
   (`src/tool.zig:1497`). A file outside the tree that is not a credential by name is
   writable, so an injected instruction can rewrite an rc file, a `PATH` entry or a
   service unit with the operator's own authority. `ast --rewrite` now refuses a
   replacement its own pattern would match again (`astRewriteRefusal`, `src/tool.zig:1565`), which is a check on the call rather than a limit on where
   the writes land.
6. **The api key is accepted on the command line.** It is visible in the process table and
   in shell history; the README's first example uses the environment, and the flag cannot
   be made to match that.
7. **The release checksum is self-attesting.** A compromised release account, or a token
   with write access to the repository, replaces the asset and the sidecar together, and
   `update` installs it. The token is now narrowed to the one API that needs it, so this
   gap is the release account alone.
8. **No cost ceiling unless one is asked for.** `--max-turns`, `--max-tokens` and
   `--budget` bound tokens per turn, turns and time. `--max-spend-tokens`
   (`MICROAGENT_MAX_SPEND_TOKENS`) is the one that bounds money, and it is opt-in:
   leaving it out is what says "no ceiling", the way an unset `--budget` says "no
   deadline" (`optionalCeiling`, `src/main.zig:860`; the check is made before a turn
   starts, at `src/main.zig:1682`, so the provider never sees a request the run has
   already priced itself out of, and the turn that reaches the ceiling is the one that
   finishes). A run started without it, by a prompt or a harness that chose no
   ceilings, is bounded only by what the conversation happens to cost.
9. **No audit trail beyond the gutter line.** Tool calls go to stderr as one line with no
   timestamp, no exit status and no file (`noteToolCall`, `src/tool.zig:694`); the session
   log records token counters, the working directory and the finish reason, never which
   commands ran (`writeRecord`, `src/session.zig:445`).
10. **A symlinked install can point anywhere.** `replaceVerified` follows the link
    (`src/update.zig:325`, through `src/net.zig:150`); a link planted in a directory on the
    operator's `PATH` redirects the write, and `write` and `edit` follow links the same
    way.
11. **A config file can redirect the system prompt.** `MICROAGENT_CONFIG` prepends a
    reply-style ruleset to the system prompt (`loadConfig`, `src/main.zig:1309`); it is
    operator-supplied and capped at 64 KB (`max_config_bytes`, `src/main.zig:131`), but
    nothing in it is sandboxed, and it reaches the provider on every turn like any other
    prompt text.
12. **The stall timeout has a floor and no ceiling.** `MICROAGENT_STALL_TIMEOUT` and
    `--stall-timeout` go through `ceiling` (`src/main.zig:719`), which refuses zero and
    nothing else, so a value of a century is accepted and set on the response socket
    (`setStallTimeout`, `src/main.zig:2148`). The bound that stops a silent provider from
    holding a turn open is then worth nothing, and the run waits on the other timeouts
    (turn count, wall clock) rather than on the one meant to catch this. The value is
    operator input, so this is a misconfiguration that fails open rather than an attack
    path, and `--budget` is the ceiling that still applies.

## Abuse cases

Each of these is a scenario, evidenced by the code path that enables it. None has been
attempted.

- **A poisoned test fixture.** A repository contains a fixture whose text tells the agent
  to run a command. The model reads it with `read` (`src/tool.zig:1045`) and, with `bash`
  (`src/tool.zig:727`), the command runs as the operator. The agent has no way to
  distinguish file content from operator instruction; the prompt tells it to report such a
  file instead, which a sufficiently persuasive file can argue with.
- **A hostile endpoint.** With `--base-url` pointed at an `https` server the attacker
  controls, the key arrives in the `authorization` header (`src/main.zig:131`) and the
  reply decides every subsequent tool call. The scheme check passes, because the attacker
  serves `https`.
- **A symlink on the update path, or in the tree.** A link named `microagent` earlier on
  `PATH` is followed at install time (`src/update.zig:325`), and a link beside a source
  file redirects a `write` or an `edit` through it (`src/tool.zig:1334`), so the run
  changes a file the operator never named.
- **Scraping through the harness.** `read` has no path restriction, so a run over a
  directory containing credentials under names the tables do not carry reads them and,
  through the model, can send them off the machine. There is no per-run file budget
  either, only the 4 MB per read (`max_read_bytes`, `src/tool.zig:28`).
- **A runaway bill.** `--max-turns` at its ceiling and a conversation that grows to 400 KB
  before compaction (`conversation_soft_limit`, `src/main.zig:42`; `compactMessages`, `src/main.zig:3161` cost real tokens, with `max_tokens` bounding each turn. A run
  started without `--max-spend-tokens` has nothing bounding the run: the turn loop asks
  the provider again on its own schedule (`src/main.zig:1744`).
- **A trust anchor from the environment.** A run started with a `MICROAGENT_CA_BUNDLE`
  pointing at a file the attacker supplied terminates both connections the run makes: the
  provider request that carries the key (`src/main.zig:2090`) and the release download
  `update` performs (`src/update.zig:939`). Nothing in the path checks what the file
  certifies, so a certificate naming the attacker's host is enough.
- **A poisoned task container.** The Harbor adapter hands the provider key to every task
  container it starts (`integrations/harbor/microagent_agent.py:482`), so a task written
  by a third party inherits the key for the length of its run.
- **Trust placed in the model's own bookkeeping.** A run that edited the tree and never ran
  a test is asked once, in prose, to go and verify (`verify_push`, `src/main.zig:401`),
  and the detection of "ran a test" is a substring match over the tool call's arguments
  (`isTestRun`, `src/main.zig:1894`). It is a quality prompt, not a control: a command
  that runs a test without naming one of the listed runners is invisible to it, and no
  refusal follows either way. What counts as an edit is read from the call's own
  arguments, so `ast` counts for `--rewrite` and not for a search
  (`isEdit`, `src/main.zig:1934`); a run that changed the tree with a tool the list does not
  carry is asked nothing.

## Response readiness

Note only, and not built here.

- Tool activity is a single stderr line per call with no timestamps and no exit status
  (`noteToolCall`, `src/tool.zig:694`), and the session log keeps no record of it
  (`writeRecord`, `src/session.zig:445`). A post-incident reconstruction of what a run did
  has to come from the working tree, not from a log.
- There is no `SECURITY.md`. The README's `Security` section (`README.md:415`) points here
  and makes no claim this document contradicts, and the two supported-versions statements
  agree with each other and with the release workflow: only the latest release is
  supported, with no backport window (`README.md:317`, `CHANGELOG.md:12`). There is no
  disclosure contact and no documented path from a reported vulnerability to a shipped
  fix, and this document does not invent one.
- `CHANGELOG.md` records every change that alters what a run does, which is the closest
  thing to a public record of behavior changes.
