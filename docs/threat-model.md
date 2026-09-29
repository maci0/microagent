# Threat model

What can be attacked in microagent, from where, and what stands in the way. Every entry
carries a file reference, so the next pass can re-verify it against the code rather than
against this document. Flags, environment variables and the config file are documented in
[usage.md](usage.md).

Last reviewed: 2026-09-29, against `0.2.0` ([build.zig.zon](../build.zig.zon)) and the
`Unreleased` section of [CHANGELOG.md](../CHANGELOG.md). A later pass added the remote MCP
transport and the `[tools.<name>]` presets (summary row 14, two entry points, trust boundary 10, gap
13); the `file:line` references it touches were refreshed by symbol, the rest of the file was not
re-checked. The earlier pass added the MCP-server and
skills surfaces (two summary rows, their entry points, two trust boundaries and the
outbound-traffic note), and named the stall timeout (`--stall-timeout`,
`MICROAGENT_STALL_TIMEOUT`) as an entry point, a control and a gap. Every `file:line` was
then checked against the tree as it stands. `fuzzConfig` moved to
`config.zig`, and `loadStyle` was renamed `loadConfig`. No owner and no review cadence are
named: neither is decided in this repository, and inventing one would put a name against a
document nobody signed.

## Contents

- [Summary, risk-ranked](#summary-risk-ranked)
- [Attack surface](#attack-surface)
- [Trust boundaries](#trust-boundaries)
- [Assets](#assets)
- [Threats per boundary](#threats-per-boundary)
- [Mitigations in the code](#mitigations-in-the-code)
- [Gaps, ranked by exploitability and impact](#gaps-ranked-by-exploitability-and-impact)
- [Abuse cases](#abuse-cases)
- [Response readiness](#response-readiness)

## Summary, risk-ranked

| # | Threat | Boundary | Exploitability | Impact | Control today |
| --- | --- | --- | --- | --- | --- |
| 1 | Repository content drives shell execution | repo → model → host | high: any content the model reads can carry an instruction | full compromise of the operator's account, files and keys | prompt wording (`system_prompt`, `src/conversation.zig:55`), command filter (`deny_commands`), and Landlock LSM confinement when sandbox enabled (gap 1) |
| 2 | The provider's reply drives shell execution | provider → host | medium: needs a hostile, coerced or MITM'd endpoint | same as 1 | redirect refused (`streamChat`, `src/main.zig:3079`), response caps, timeouts, `bash` timeout default and ceiling (`default_bash_timeout_ms`, `src/tool.zig:70`; `max_bash_timeout_ms`, `src/tool.zig:65`) |
| 3 | The API key is sent to whatever host the environment names | agent → provider | medium: any `https` host is accepted | provider account takeover, bill abuse | plaintext `http` refused off loopback (`net.urlCarriesKey`, `src/net.zig:312`, enforced at `src/main.zig:393`) |
| 4 | A named CA bundle adds a trust anchor for every TLS connection of the run | environment/argv → agent, agent → provider and GitHub | medium: needs a write to the environment, or `--ca-bundle` on the command line | the API key to a machine in the middle, and a release asset that hashes as published | additive to the system store; a bundle that is unreadable or holds no certificate is refused (`loadCaBundle`, `src/net.zig:64`); no policy on what a bundle may add (gap 3) |
| 5 | Tools read and write outside the working tree | model → filesystem | high: `read`/`write`/`edit`/`multi_edit` take any path | overwrite `~/.ssh/authorized_keys`, a shell rc file, any file the operator can write | credential paths refused by name (`isCredentialPath`, `src/tool.zig:1726`); configurable sandbox (`[sandbox]` in config) enforces path checks and Landlock LSM rules to confine writes to writable roots (gap 5) |
| 6 | Tool output carries credentials to the model and on to the provider | host → model → provider | low: needs a credential under a name the rules do not know, or one reached through shell indirection | secret exfiltration through a routine run | all six tools refuse or exclude a known credential name (`credential_globs`, `src/tool.zig:1667`; `credentialInCommand`, `src/tool.zig:1177`; `gitPathspecs`, `src/tool.zig:854`); the run's own keys are absent from a tool's environment (`scrubSecrets`, `src/main.zig:1969`) |
| 7 | A compromised release replaces the binary | GitHub → host | low: needs the release account or its token | persistent, silent code execution on every later run | sha256 sidecar, host allowlist (`checksumMatches`, `src/update.zig:162`; `hostTrusted`, `src/update.zig:109`) |
| 8 | The API key is visible in the process table | operator → host | low: needs a local reader | key theft by any other process or user on the box | none |
| 9 | A hostile or malformed provider response exhausts memory or CPU | provider → agent | medium | run killed, machine memory spent | per-response cap (`max_response_bytes`, `src/stream.zig:20`), frame cap (`max_frame_bytes`, `src/main.zig:160`), error-body cap (`max_error_body_bytes`, `src/main.zig:175`), timeouts, process-group kill |
| 10 | A hostile repository writes escape sequences to the operator's terminal | repo → terminal | high: any file the model echoes | terminal spoofing, clipboard tricks | control bytes escaped in the gutter (`toolCallLine` via `chat.safeText`, `src/chat.zig:690`, `src/chat.zig:656`) and scrubbed in error text (`terminalSafe`, `src/tool.zig:1026`) |
| 11 | A hostile model result spends the operator's money | model → provider | medium: a runaway or looping run | unbounded bill on the provider account | per-request `max_tokens` (`buildBody`, `src/main.zig:2990`), turn and wall-clock ceilings, and an opt-in run-wide spend ceiling (`--max-spend-tokens`, `spendCeilingReached`, `src/main.zig:2447`); nothing bounds the spend of a run that set none (gap 8) |
| 12 | An `[[mcp]]` table chooses a program the run executes | operator config → host | medium: needs a write to the config file, the environment or `--config` | arbitrary code execution as the operator; every tool result the server returns reaches the model | servers are read only from the config file (`--config`, `MICROAGENT_CONFIG` or `$HOME/.microagent/config.toml`), never from the working tree (`config.parse`, `src/config.zig:163`; `connect`, `src/mcp.zig:1311`), so a repository under review cannot add one; the server inherits the scrubbed environment, never the provider key (`scrubSecrets`, `src/main.zig:1969`); it is trusted exactly as far as a `bash` command the operator wrote, and no further |
| 14 | A remote MCP server, or an enabled preset, returns text the model reads and receives what the model sends it | remote server → model, agent → remote server | medium: needs a hostile or compromised endpoint, or an operator who switched one on; a public endpoint working as intended is the ordinary case | prompt injection through a result (as row 1, by a path that is not the repository), the model's queries and the key seen by a third party | a result is untrusted text like any tool output: the system prompt says so, it is capped at `max_tool_output` (`resultText`, `src/mcp.zig:785`); presets are off until the config enables one (`toolKey`, `src/config.zig:665`); `https`, or `http` on loopback, with no userinfo (`validUrl`, `src/mcp.zig:1220`); no redirect, a 4 MB response ceiling and a per-request timeout that cancels the whole exchange (`exchange`, `src/mcp.zig:427`; `readAnswer`, `src/mcp.zig:511`; `post`, `src/mcp.zig:356`); the key is named in the file by variable, read before the scrub and removed from every child's environment (`withKeys`, `src/mcp.zig:1253`; `scrubSecrets`, `src/main.zig:1969`); the sandbox does not confine this traffic (gap 13) |
| 13 | A skill body is prompt text the model is told to follow | operator config → model | low: needs a write to a skills directory, the config file, or `MICROAGENT_SKILLS` | the run follows instructions the operator did not write, and the conversation is re-sent to the provider | skills are read only from the roots the config file or the variable names, else `$HOME/.microagent/skills`, never from the working tree (`roots`, `src/skill.zig:142`; `discover`, `src/skill.zig:216`), so a repository under review cannot install one; the listing escapes control bytes (`Skills.prompt`, `src/skill.zig:95`); a body reaches the conversation only when the model calls the tool, as a tool result under the same cap as any other |

`microagent` is a local CLI with no listener, no server and no database. It holds no user
data of its own: it exposes the operator's own machine, and an attacker wants the key, the
source tree and the host. The one asset worth stealing on its own is the API key.

## Attack surface

### Entry points in the code

| Entry point | What arrives | Handled at |
| --- | --- | --- |
| Command line, agent mode | prompt, flags, API key in `argv` | `parseArgs`, `src/main.zig:1647`; `main`, `src/main.zig:398`; the flag table at `src/main.zig:917` holds every valued flag the run accepts: `-p/--print`, `-m/--model`, `-b/--base-url`, `-k/--api-key`, `--ca-bundle`, `--config`, `--reasoning-effort`, `--budget`, `--max-spend-tokens`, `--max-turns`, `--max-tokens`, `--stall-timeout` |
| `--ca-bundle <file>` | the PEM file whose certificates vouch for the provider and for GitHub | `net.caBundlePath`, `src/net.zig:125`; `loadCaBundle`, `src/net.zig:64`; applied at `src/main.zig:477` and `src/update.zig:544` |
| `--config <file>`, `MICROAGENT_CONFIG`, `~/.microagent/config.toml` | the provider settings (`model`, `base_url`, `api_key`, the last a credential in the clear), the `system_prompt_extra` text, skill roots, `[[mcp]]` and `[tools.<name>]` tables, denied shell commands, and sandbox settings: what the prompt says, what the run starts or contacts, which tools it offers, what shell execution refuses, and filesystem confinement | `configSource`, `src/main.zig`; `loadConfig`, `src/main.zig:2031`; `config.parse`, `src/config.zig:163`; cap `max_config_bytes` (64 KB), `src/main.zig:128` |
| `[[mcp]]` tables in that config | programs the run starts over stdio, remote servers it sends POSTs to (`url`), and the tools they offer | `connect`, `src/mcp.zig:1311`; `handshake`, `src/mcp.zig:1559` |
| `[tools.<name>]` tables in that config | which built-in tools the model is offered, and which of the public remote servers `web_search`, `context7`, `grep_app` and `deepwiki` are switched off (all four are on by default), with their url, key variable name and timeout | `toolKey`, `src/config.zig:665`; `toolConfigError`, `src/main.zig:848`; `builtinToolsJson`, `src/main.zig:2894`; refusal in `dispatchCall`, `src/main.zig:3655` |
| Responses of a remote MCP server (JSON body or event stream) | text that becomes a tool result, and the session id echoed on later requests | `exchange`, `src/mcp.zig:427`; `readAnswer`, `src/mcp.zig:511`; `sseLine`, `src/mcp.zig:583` |
| `skills` in that config, `MICROAGENT_SKILLS`, `~/.microagent/skills` | `SKILL.md` bodies the model may load, as prompt text | `roots`, `src/skill.zig:142`; `discover`, `src/skill.zig:216`; `call`, `src/skill.zig:471`; cap `max_skill_bytes`, `src/skill.zig:40` |
| `AGENTS.md` in the working directory, or the paths `agents_files` names | repository text the run follows as instructions, appended to the system prompt between a begin and an end marker naming the file, with the prompt stating that the block governs the task and cannot widen it, lift the prompt's rules, authorize a credential, or send anything off the machine | `agentsBlock`, `src/main.zig:621`; `readAgentsFile`, `src/main.zig:714`; cap `max_agents_bytes`, `src/main.zig:134`; `agents_files = []` turns the read off |
| Command line, `update` | `--check` | `parseArgs`, `src/update.zig:497`; `run`, `src/update.zig:537`; dispatched from `main` at `src/main.zig:400` |
| `MICROAGENT_MODEL`, `MICROAGENT_BASE_URL`, `MICROAGENT_REASONING_EFFORT` | endpoint, model, response style | `envValue`, `src/main.zig:1245`; read at `src/main.zig:281-283` |
| `MICROAGENT_MAX_TURNS`, `MICROAGENT_MAX_TOKENS` | loop and response ceilings | `max_turns_default`, `src/main.zig:98`; `default_max_tokens`, `src/main.zig:113`; both through `ceiling`, `src/main.zig:1336` |
| `MICROAGENT_API_KEY` | provider credential | `key_var`; resolved in `resolveKey` |
| `api_key` in the config file | provider credential, in the clear on disk | read by `config.parse`, `src/config.zig`; resolved in `resolveKey`; no key file is read |
| `MICROAGENT_CA_BUNDLE`, `SSL_CERT_FILE` | trust anchors for the provider host and for GitHub | `caBundlePath`, `src/net.zig:130`, read at `src/main.zig:430`; loaded at `src/main.zig:477` and `src/update.zig:544` |
| `MICROAGENT_BUDGET_SECONDS`, `--budget` | wall-clock ceiling on the run, suspended time included | `optionalCeiling`, `src/main.zig:1503`; carried by `Budget`, `src/main.zig:2332` |
| `MICROAGENT_MAX_SPEND_TOKENS`, `--max-spend-tokens <n>` | run-wide token ceiling, counted before each turn | `optionalCeiling`, `src/main.zig:1503`; read at `src/main.zig:304`; enforced at `src/main.zig:1752` |
| `MICROAGENT_STALL_TIMEOUT`, `--stall-timeout <s>` | seconds the response socket may stay silent, 120 s by default | `default_stall_timeout_s`, `src/main.zig:118`; read at `src/main.zig:297`; set on the socket at `src/main.zig:2222` |
| `MICROAGENT_SESSION_DIR` | where the JSONL run log is written | `sessionDir`, `src/session.zig:27`; read at `src/main.zig:308` |
| `MDEBUG` | protocol notes and the resolved configuration on stderr, never a key | `debugEnabled`, `src/main.zig:1253`; `traceConfig`, `src/main.zig:2132` |
| `GITHUB_TOKEN` | credential, presented only to `api.github.com` and never to a tool subprocess | `githubBearer`, `src/update.zig:144`; narrowed by `bearerFor`, `src/update.zig:155`; read once at `src/update.zig:545` and narrowed per request at `src/update.zig:414` |
| GitHub release JSON | tag, page URL, asset names, download URLs | `parseRelease`, `src/update.zig:179` |
| Downloaded asset and `.sha256` sidecar | bytes that become the running executable | `fetch`, `src/update.zig:319`; gated by `installIfVerified`, `src/update.zig:454` |
| Streamed provider response (SSE) | model text and tool calls | `streamChat`, `src/main.zig:3079`; `applyFrame`, `src/stream.zig:593` |
| Tool call arguments | what the model wants done | `runTool`, `src/tool.zig:887` |
| Files in the working tree | the model's evidence, and its instructions | `toolRead`, `src/tool.zig:1861`; system prompt at `src/main.zig:138` |

There is no network listener, webhook, message consumer, scheduled job or IPC. microagent
itself talks only to the provider's base URL and to GitHub, plus the remote MCP servers the config
names: a `url` table, or a preset. All four presets (web_search, context7, grep_app, deepwiki) are
on by default, so a run that calls none of their tools makes no request to them, and a run that
does sends the tool call there. `enabled = false` under `[tools.<name>]` makes no request to one at
all. An MCP server it starts is a separate program and
may talk to whatever its operator configured. That traffic is the server's, not this binary's, and
the config entry is the operator's statement that the program is trusted. The traffic to a remote
server is this binary's, and the sandbox does not confine it.

### Surface added by deployment

- The binary runs whatever is on `PATH`: `rg`, `ast-grep`, `git` and `/bin/sh`
  (`toolSearch`, `src/tool.zig:2365`; `toolAst`, `src/tool.zig:2399`; `toolGit`,
  `src/tool.zig:472`; `toolBash`, `src/tool.zig:1433`). A hostile `PATH` entry is a hostile
  tool, and `bash` runs whatever name the model typed.
- The Harbor adapter runs the binary inside third-party task containers with the provider
  key in the container environment
  ([microagent_agent.py:482](../integrations/harbor/microagent_agent.py), `api_key()` at
  `:138`), so a poisoned task reaches the container plus the key. The endpoint is checked
  on the host before a container starts (`base_url`, `microagent_agent.py:220`): a
  `MICROAGENT_BASE_URL` with no scheme, or a plaintext one off loopback, is refused there
  rather than by the binary inside the container, which already holds the key.
- CI builds release assets with the workflow's own token and publishes them with
  `gh release create` ([release.yml:139](../.github/workflows/release.yml)). That account
  is the trust anchor for every future `microagent update`.

## Trust boundaries

1. **Operator → agent.** The prompt is untrusted input like any other. There is no
   validation point: `setPrompt` (`src/main.zig:1300`) stores it and `openConversation`
   (`src/main.zig:5326`) appends it to the conversation verbatim.
2. **Repository content → model → host.** The most important boundary in the project. The
   model reads files, source and tests, and issues tool calls from what it read
   (`system_prompt`, `src/conversation.zig:55`). Nothing in the program separates the model's own
   plan from an instruction it found in a file; only an instruction in the prompt does.
3. **Provider → agent.** The streamed reply decides the next action. The validation point
   is `applyFrame` (`src/stream.zig:559`), which bounds the shape, not the intent.
4. **Agent → provider.** The key goes out in an `authorization` header (`authHeaders`,
   `src/main.zig:2135`) to whatever host `base_url` names, after the scheme check at
   `src/main.zig:334`.
5. **Model → filesystem and process.** `bash` runs `/bin/sh -c` with the model's string
   (`toolBash`, `src/tool.zig:1433`); `read`, `write`, `edit` and `multi_edit` take any path (`toolRead`,
   `src/tool.zig:1156`; `toolWrite`, `src/tool.zig:2013`; `toolEdit`, `src/tool.zig:2091`).
6. **GitHub → host.** `update` downloads bytes and writes them over the running executable
   (`fetch`, `src/update.zig:319`; `installIfVerified`, `src/update.zig:454`).
   Validation point: `installIfVerified` (`src/update.zig:445`).
7. **Secrets → process.** The key enters from `argv`, the environment or a file, lives in
   process memory for the run, and leaves only in the `authorization` header. It is never
   written to the session log or to a tool result.
8. **Operator config → host (MCP).** The `[[mcp]]` tables name programs the run starts as
   children before the first request; the tools they report are advertised to the model and
   dispatched to them (`config.parse`, `src/config.zig:163`; `connect`, `src/mcp.zig:1311`).
   Validation point: the tables come from the config file named by `--config`, the variable
   or `$HOME/.microagent/config.toml`, and from nowhere in the tree (`configSource`,
   `src/main.zig`). The children inherit the scrubbed environment, which lacks the
   provider key (`scrubSecrets`, `src/main.zig:1969`). A server whose name or tool name
   cannot be spelled in a tool name is refused (`validName`, `src/mcp.zig:1285`). What a
   configured server does with its own authority is the operator's decision, as with a
   `bash` command they write.
10. **Remote MCP server → model, and agent → remote server.** A `url` table or a preset that is on
    sends each tool call's name and arguments to an HTTPS endpoint the operator named, and the text
    it answers with becomes a tool result, as a file's contents do. Validation points: the url
    must be `https`, or `http` on loopback, with no userinfo (`validUrl`, `src/mcp.zig:1220`); a
    redirect is an error, the body is capped at 4 MB and the request at its timeout (`exchange`,
    `src/mcp.zig:405`); the key is looked up by a variable name written in the file and sent in one
    header (`withKeys`, `src/mcp.zig:1253`), and that variable is removed from the environment every
    child inherits (`scrubSecrets`, `src/main.zig:1969`). Nothing checks what the endpoint says: a
    child inherits (`scrubSecrets`, `src/main.zig:1969`). Nothing checks what the endpoint says: a
    result can carry instructions, and it is untrusted for the same reason a file from a
    repository under review is.
9. **Operator skills → model.** A `SKILL.md` body is instruction text the model is told to
    follow. It reaches the conversation only when the model calls the `skill` tool (`call`,
    `src/skill.zig:363`). Validation point: the roots are the config file's `skills` list,
    the directories `MICROAGENT_SKILLS` names, or the operator's home directory, never the
    tree (`roots`, `src/skill.zig:142`; `discover`, `src/skill.zig:216`).

Privilege transitions are total, not gradual: once the model calls `bash`, the run has the
operator's full authority. No user confirmation sits between a model decision and a
command.

## Assets

| Asset | Why it matters | Where it lives |
| --- | --- | --- |
| Provider API key | bills, model access, provider account | `argv`, the environment or the config file, then process memory |
| `GITHUB_TOKEN` | releases API access, and repository scope beyond it | environment, then an `Authorization` header on `api.github.com` only (`bearerFor`, `src/update.zig:155`); absent from every tool subprocess (`secret_env_vars`, `src/main.zig:1946`) |
| `api_key` in the config file | the same key, on disk and in the clear | read in `resolveKey`; the file is not a credentials path, so the `read` tool can open it: keep it out of a workspace the model is given |
| Source tree and everything in it | `.env`, keys, unreleased work | read by `toolRead` (`src/tool.zig:1239`), credentials refused at `src/tool.zig:1158`, sent to the provider in the request body |
| A remote MCP server's key | access to the operator's account at that service | the environment, named by `api_key_env`; copied once by `withKeys` (`src/mcp.zig:895`), sent in one request header, removed from every child's environment (`scrubSecrets`, `src/main.zig:1969`); never in the config file or a log line |
| Host compute and credentials | the shell inherits the environment minus this binary's own credentials | `scrubSecrets`, `src/main.zig:1969` |
| The binary itself | a replaced copy runs on every later invocation | replaced at `replaceBinary`, `src/update.zig:438` |
| Run logs | working directory, model, token counts, finish reason | `~/.microagent/sessions`, capped at 200 logs, one per run (`pruneSessions`, `src/session.zig:363`; `max_session_logs`, `src/session.zig:251`) |
| Token spend | `--max-turns` bounds turns and `--max-spend-tokens` bounds money, each only when set | `max_turns_default`, `src/main.zig:98`; `default_max_tokens`, `src/main.zig:113`; `spendCeilingReached`, `src/main.zig:2447` |

## Threats per boundary

### Operator → agent (STRIDE: spoofing, tampering, information disclosure)

- A prompt that names a hostile base URL steers the whole run. It is an operator input, so
  this is a threat only where an automated harness passes a task's text straight through
  (`bench/gauntlet.sh`).
- A prompt of any length enters the conversation uncapped (`setPrompt`,
  `src/main.zig:1106`; appended in `openConversation`, `src/conversation.zig:413`), and the
  request body grows with it.

### Repository content → model → host (elevation of privilege, information disclosure)

- **Prompt injection through source files.** A file, a test fixture or an issue template in the
  tree can say "run `curl … | sh`". The model reads it with the ordinary `read` tool
  (`toolRead`, `src/tool.zig:1861`). Instructions carry no provenance, so the injected text is as
  trusted as the operator's prompt. The system prompt tells the model to treat tool output as data
  and to report such a file instead of acting on it (`system_prompt`, `src/conversation.zig:55`),
  but a hostile file can argue with that. This is the project's dominant risk, and it is a design
  property, not a bug.
- `AGENTS.md` is the one file in the tree the run follows as instructions rather than as data, and
  that is deliberate: it is the convention every other coding agent reads, and a run whose operator
  wants none sets `agents_files = []`. Its authority is bounded in the prompt rather than in the
  code, because the file's whole purpose is to direct the run: the block is fenced between a begin
  and an end marker, the prompt states that it governs the task and cannot widen it, lift the
  prompt's rules, authorize a credential, or send anything off the machine, and a line asking for
  one of those is reported rather than obeyed (`system_prompt`, `src/conversation.zig:55`;
  `agentsBlock`, `src/main.zig:621`). The fences are the run's, so a line of the file spelling one
  is marked rather than obeyed as a boundary: otherwise a file closes its own block and continues
  in the operator's own voice, where the block's limits do not apply
  (`defuseFences`, `src/main.zig:673`). A hostile `AGENTS.md` is therefore the strongest injection
  this design admits, and it lands in the system role rather than a tool result.
- The same path exfiltrates: the model can `read` a file, and its bytes go into the next
  request body (`buildBody`, `src/main.zig:2990`).
- A hostile repository can also reach the terminal. Bytes a tool echoes reach the gutter
  line (`toolCallLine`, `src/tool.zig:975`). The provider's text reaches stdout unescaped,
  deliberately: it is the answer the run was asked for.

### Provider → agent (spoofing, tampering, denial of service)

- A hostile or coerced endpoint chooses every tool call. One response can carry up to 64
  calls (`max_tool_calls`, `src/stream.zig:10`, enforced by the index check at
  `src/main.zig:2948` and the index clamp in `applyCallDelta`, `src/stream.zig:503`), and
  they run as the operator.
- A tool call's name and argument object are the provider's own text, parsed from bytes
  the model read out of the tree. They are fuzzed from the argument JSON to the gutter line
  and the limits it produces: the line stays one line inside its buffer with no byte a
  terminal acts on, and every count the model wrote is inside its ceiling before a
  subprocess starts (`fuzzToolCall`, `src/tool.zig:3360`; test at `src/tool.zig:2330`).
- A call the provider gave no index, no id or no name, or whose arguments are not a JSON
  object, is dropped rather than dispatched (`keepRunnableCalls`, `src/stream.zig:104`;
  `argumentsAreAnObject`, `src/stream.zig:135`). The drop count is reported, so the turn
  does not pass for one that dispatched everything (`src/main.zig:2482`).
- The transport is at-least-once: a relay that reconnects replays from the last event it
  saw, and a proxy that retries a chunk re-sends it. A call whose `id` the response already
  carries is dropped and the first kept (`indexOfCallId`, `src/stream.zig:124`), so a
  replayed `bash` runs once.
- A stream that never sends `[DONE]` grows the turn until the caps at `src/main.zig:114`
  and `src/main.zig:129` stop it, and the run ends as truncated (`truncatedNotice`,
  `src/stream.zig:26`).
- A provider that accepts the connection and never sends a byte is bounded by a receive
  timeout on the response socket, 120 s unless the operator raises it
  (`default_stall_timeout_s`, `src/main.zig:118`; `setStallTimeout`, `src/main.zig:3036`,
  applied at `src/main.zig:2222`). The value is checked only for being a positive number
  (`ceiling`, `src/main.zig:1336`). Nothing refuses a figure larger than any run should
  wait, so a hostile environment that sets it very high turns the stall bound off (gap 12).
- An error body from the provider is printed on stderr through `terminalSafe`
  (`src/tool.zig:750`) and capped at 16 KB (`max_error_body_bytes`, `src/main.zig:175`).
  Control bytes are scrubbed, so it cannot repaint the terminal.
- Frames that are not JSON are counted and dropped (`applyFrame`, `src/stream.zig:593`;
  counter at `src/main.zig:2344`). They are not fatal: the run continues on a partial turn
  and reports the count at `src/main.zig:2412`.

### Agent → provider (information disclosure, spoofing)

- The key is refused to any base URL that would put it on the wire in the clear:
  `net.urlCarriesKey` (`src/net.zig:312`) requires `https`, or `http` on loopback, and
  `main` fails the run otherwise (`src/main.zig:393`). `isLoopbackHost` (`src/net.zig:321`)
  accepts `localhost` and any name ending in `.localhost`, both case-insensitive; `::1`
  with or without brackets; and `127.a.b.c` only as exactly four dotted decimal octets of
  one to three digits, each at most 255 (`isIpv4Loopback`, `src/net.zig:653`). So
  `127.evil.com`, `localhost.evil.com`, `127.1`, `127.0.0.256`, `localhost.` with a
  trailing dot, and other IPv6 spellings of loopback do not qualify. The test at `src/main.zig:3205` pins the policy. The remote MCP transport applies the same
  rule to its urls (`validUrl`, `src/mcp.zig:1220`).
- The key goes to the base URL, which is the built-in OpenRouter one unless the operator
  named another. Only `MICROAGENT_API_KEY` is read, so a key another provider's tools
  export (`OPENAI_API_KEY`, `DEEPSEEK_API_KEY`) is never picked up and sent to the default
  endpoint by accident. A base URL the operator named is deliberately never questioned,
  because a self-hosted gateway is a legitimate destination for any provider's key.
- The check does not constrain *which* `https` host. `MICROAGENT_BASE_URL` or `--base-url`
  may name any host, and the key follows.
- Every diagnostic naming the base URL clips and quotes it (`clip`, `src/main.zig:1525`), so
  a value carrying escape sequences cannot repaint the terminal through an error message.
- `--api-key` puts the credential in `argv` (`resolveKey`, `src/main.zig:1838`), which is
  world-readable in the process table for the life of the run.
- The conversation carries everything the model read, on every turn, by design
  (`buildBody`, `src/main.zig:2990`).
- Redirects are not followed. `.redirect_behavior = .unhandled` (`src/main.zig:2210`) makes
  a 3xx an error status, so a provider answering with a `Location` cannot walk the key off
  to whoever it names. The header carrying the key is the one the request writer reads
  (`authHeaders`, `src/main.zig:3018`), not a separately privileged field, so the unhandled
  redirect is the whole of this control.
- A base URL carrying `user:password@` has that userinfo replaced wherever the URL is
  printed (`displayUrl`, `src/main.zig:1480`; `redactUserinfo`, `src/main.zig:1489`).
- `MICROAGENT_CA_BUNDLE`, `SSL_CERT_FILE` and `--ca-bundle` decide who vouches for that
  host. `loadCaBundle` (`src/net.zig:39`) adds the named file's certificates to the
  client's store, and the system store is still scanned, so a bundle naming one more root
  is enough to terminate the connection that carries the key. The path is operator or
  environment input, and nothing constrains what the file contains. Only a bundle that
  cannot be read or holds no certificate is refused: the empty trust store is reported and
  the system store used instead. The same path governs `update` (`src/update.zig:544`),
  where it covers the release download.

### Model → filesystem and process (elevation of privilege, tampering, denial of service)

- `bash` is arbitrary command execution with the operator's identity and working directory
  (`toolBash`, `src/tool.zig:1433`). The spawned shell inherits the environment minus this
  binary's own credentials (`scrubSecrets`, `src/main.zig:1969`, over `secret_env_vars`,
  `src/main.zig:1457`: `MICROAGENT_API_KEY` plus `GITHUB_TOKEN`), so `bash env` and
  `bash printenv` cannot put the run's own key in the transcript. A command naming a
  credentials file is refused on the same name rule the other tools apply
  (`credentialInCommand`, `src/tool.zig:1177`, applied at `src/tool.zig:888`). That rule
  reads the command's words, not a parsed shell, so a file reached through indirection is
  not caught. A command matching a configured command filter (`deny_commands` in config) is
  refused before execution (`deniedInCommand`, `src/tool.zig:1375`).
- `read`, `write`, `edit` and `multi_edit` accept absolute paths and do not confine writes to the working
  tree (`toolRead`, `src/tool.zig:1861`; `toolWrite`, `src/tool.zig:2013`; `toolEdit`,
  `src/tool.zig:1355`). Each refuses a path the credential tables name, and nothing else.
- `write`, `edit` and `multi_edit` write through a temporary file and a rename. They follow a symlink to
  the real file first and carry the destination's permission bits over
  (`writeFileAtomic`, `src/tool.zig:2068`; `permission_bits`, `src/tool.zig:2049`). A
  symlink planted in the tree therefore redirects a write, and a rewritten file keeps its
  mode instead of taking the process umask's.
- `ast` with `rewrite` set applies its replacement to every match (`toolAst`,
  `src/tool.zig:1474`), so one model turn can rewrite a whole file set. A rewrite that
  would still match its own output is refused (`astRewriteRefusal`, `src/tool.zig:2521`).
  That is evidence the run reads back, not a sandbox: a replacement that re-matches through
  a form the pattern's literal text does not spell is still applied.
- Bounded today: 60 s tool timeout (`tool_timeout_ms`, `src/tool.zig:60`); 120 s default
  (`default_bash_timeout_ms`, `src/tool.zig:70`) and 600 s ceiling for `bash`
  (`max_bash_timeout_ms`, `src/tool.zig:65`, applied through `bashTimeoutMs` at
  `src/tool.zig:798` and `boundedMs` at `src/tool.zig:70`), clipped to the budget's
  remaining time (`Budget`, `src/main.zig:2332`); captured output held at 96 KB and cut to
  the 24 KB the model reads (`max_tool_output`, `src/tool.zig:25`; `runCapped`,
  `src/tool.zig:1638`); `--max-turns` (`max_turns_default`, `src/main.zig:98`); and the
  wall-clock budget (`src/main.zig:1539`).

### GitHub → host (spoofing, tampering, elevation of privilege)

- The release JSON is attacker-shaped: every field becomes a tag, an asset name or a URL
  the updater acts on (`parseRelease`, `src/update.zig:179`). It is fuzzed against exactly
  that (`fuzzRelease`, `src/update.zig:1289`; `fuzzSidecar`, `src/update.zig:1348`).
- The repository the updater requests is a constant compiled into the binary (`default_repo`,
  `src/update.zig:12`, read into `release_api_url` at `src/update.zig:14`), not caller text,
  so a command line cannot steer it. The `--repo` flag that once let a caller name one is
  gone, and with it the `owner/name` validation that guarded it: a repository name is no
  longer an input at any boundary, and the release page, the asset and the sidecar are each
  held to the host allowlist before a request carries them (`trustedGithubUrl`,
  `src/update.zig:116`, applied at `src/update.zig:551` and `src/update.zig:595`; harness
  `fuzzArgs`, `src/update.zig:839`).
- A body over the cap is refused while it streams, not after (`Capped`,
  `src/update.zig:210`, used at `src/update.zig:354`). The API body is capped
  at 10 MB, the asset at 256 MB, the sidecar at 64 KB (`src/update.zig:18-20`).
- `GITHUB_TOKEN` is narrowed to the releases API before any request carries it. `bearerFor`
  (`src/update.zig:147`) returns the token only for a URL under `https://api.github.com/`
  and null for the asset and the sidecar, which GitHub serves anonymously
  (`src/update.zig:545`, `src/update.zig:414`). The grant is as
  wide as the one request that needs it, not as wide as the host allowlist. What remains: a
  repository-scoped token is still presented in full to that one API, so a redirect or
  error on the releases API is the only place it can leak, and the unhandled redirect is
  the control there.
- The sidecar comes from the same release as the asset, so the checksum proves the
  download was not corrupted in transit, not that the release was authorized. The trust
  anchor is the GitHub account and the TLS session. There is no signature, attestation or
  pinned digest.
- A CA bundle named by the environment or `--ca-bundle` joins the trust store the download
  is verified against (`loadCaBundle`, `src/net.zig:64`, called at `src/update.zig:544`).
  A bundle carrying one attacker-issued root substitutes the asset and the sidecar
  together, and the checksum still matches. The host allowlist does not help: both URLs
  are on a GitHub host, the requests are addressed there, and the certificate presented is
  one the client was told to accept.
- The replacement follows a symlink to the real file (`replaceBinary`,
  `src/update.zig:429`, through `net.resolveSymlinkTarget`, `src/net.zig:288`), so a
  symlinked install under a path the operator does not own writes wherever the link points.

### Classes this tree has already fixed

[CHANGELOG.md](../CHANGELOG.md) records the same few classes recurring: base-URL
credentials printed unredacted into the run's own error lines, a control character in a
tool argument repainting the terminal, a base URL with escape sequences reaching stderr
unescaped, a tool result or assistant text breaking the JSON of the next request, a
credential reaching the provider through a tool result, a committed `.env` printed by a
path-scoped `git show`, a repository-scoped token handed to the asset host, and memory
held for the length of a stream.

The `Unreleased` section adds more of the same kinds:

- a structural rewrite that re-applied itself to its own output;
- a tool call delivered twice by a reconnecting relay and dispatched twice;
- a subprocess that printed its findings and then failed, having them thrown away;
- a credential named at a depth in the path rather than at the leaf, which `search` and
  `git` already excluded while `read`, `write`, `edit` and `ast` still read it
  (`isCredentialPath`, `src/tool.zig:1726`);
- an `ast --rewrite` that wrote a credentials file while the refusal told the model to
  fetch it through `bash` (`credentialRefusal`, `src/tool.zig:1832`);
- a key minted for one provider reaching another without a word (`keyNamesOtherProvider`,
  `src/main.zig:767`);
- a tool call that closed both its pipes and then slept, holding the turn past the
  deadline the call already had (`waitBounded`, `src/tool.zig:2705`).

The last two share the shape of the rest: a control the code assumed was implied turned
out to be a separate thing. Each has a control named above; a regression in any of them is
the same bug returning.

## Mitigations in the code

| Control | Covers | Where |
| --- | --- | --- |
| System prompt names tool output, file contents and command output as data, and tells the model to report a file that gives orders | prompt injection through a file, at the model rather than in the program | `system_prompt`, `src/conversation.zig:55` |
| The repository the updater requests is a compile-time constant, so no caller text reaches a URL | URL injection through a repository name | `default_repo`, `src/update.zig:12`; `release_api_url`, `src/update.zig:14` |
| Host allowlist: `https` on `github.com`, `*.github.com`, `*.githubusercontent.com`, no userinfo, checked on the page URL and both asset URLs | asset and page download from a lookalike host | `hostTrusted`, `src/update.zig:109`; `trustedGithubUrl`, `src/update.zig:120`; applied at `src/update.zig:551` and `src/update.zig:595` |
| `GITHUB_TOKEN` is presented only to `https://api.github.com/`, prefix-compared octet by octet, so a lookalike host, a userinfo URL and a path carrying the API name all get nothing; the asset and the sidecar go out unauthenticated | a repository-scoped token handed to the asset CDN, to `api.github.com.evil.com`, or to a path that merely contains the API name | `bearerFor`, `src/update.zig:155`; read once at `src/update.zig:545` and applied per request at `src/update.zig:414` |
| A CA bundle that cannot be read, or holds no certificate, is refused and the system store used instead | a bundle silently emptying the trust store, so every request fails as if the machine shipped no certificates | `loadCaBundle`, `src/net.zig:64` |
| sha256 sidecar verified before the verdict is `replaced` | corrupted or substituted download | `checksumMatches`, `src/update.zig:162`; `installIfVerified`, `src/update.zig:454` |
| Version comparison refuses a downgrade | installing an older build over a newer one | `compareVersions`, `src/update.zig:89`; `sameRelease`, `src/update.zig:56`; both applied at `src/update.zig:554` |
| Atomic replace, only on `.replaced` | partial write, write on a refusal | `installIfVerified`, `src/update.zig:454`; `replaceBinary`, `src/update.zig:438` |
| The key is refused on a plaintext `http` base URL off loopback; a `127.` host needs exactly four octets, every one range-checked | the key crossing a network path in the clear, or going to a name spelled like an address | `urlCarriesKey`, `src/net.zig:632`; `isLoopbackHost`, `src/net.zig:641`; `isIpv4Loopback`, `src/net.zig:653`; enforced at `src/main.zig:393`; test at `src/main.zig:3205` |
| Remote MCP: `https` (or loopback `http`) urls with no userinfo, no redirect, a 4 MB response ceiling, a per-request timeout, presets off until enabled | a key or a query sent in the clear, a key replayed to a redirect target, an endpoint holding the run or its memory, a network call nobody asked for | `validUrl`, `src/mcp.zig:1220`; `exchange`, `src/mcp.zig:427`; `readAnswer`, `src/mcp.zig:511`; `toolKey`, `src/config.zig:665` |
| The variables named by `api_key_env` are removed from the environment tool subprocesses and local MCP servers inherit, after the key is read | a `bash: env` that prints a remote server's key into the transcript and on to the provider | `withKeys`, `src/mcp.zig:1253`; `scrubSecrets`, `src/main.zig:1969` |
| Only `MICROAGENT_API_KEY` is read as the key | a key minted for one provider reaching another, with no hostile input at all: a variable another tool exported and a URL nobody set | `key_var`, `resolveKey` in `src/main.zig` |
| Userinfo redacted from every printed URL; every quoted diagnostic clipped and escaped | a password in the base URL copied into stderr, or a base URL carrying escape sequences repainting the terminal | `displayUrl`, `src/main.zig:1480`; `redactUserinfo`, `src/main.zig:1489`; `clip`, `src/main.zig:1525`; `quoteUntrusted`, `src/update.zig:40` |
| Redirects unhandled | the key replayed to a host the provider names | `src/main.zig:2210` |
| Argument vectors instead of a shell for `search`, `ast`, `git` | shell injection through a pattern or a path | `toolSearch`, `src/tool.zig:2365`; `toolAst`, `src/tool.zig:2399`; `toolGit`, `src/tool.zig:595` |
| `--` separator, and a `rev` that may not start with `-` | an option smuggled in as a path or a revision | `gitArgv`, `src/tool.zig:781`; `gitPathspecs`, `src/tool.zig:854`; `toolSearch`, `src/tool.zig:2365`; `toolAst`, `src/tool.zig:2399` |
| Fixed git subcommands, no writes through the `git` tool | `bash`-strength git | `gitArgv`, `src/tool.zig:781` |
| `git show` is given a format carrying the hash, the date and the subject, so the `Author:` and `Commit:` header lines it prints by default never reach the tool result; `log` is `--oneline` and never printed them | a commit author's name and email address re-sent to the provider on every later turn of a run that only wanted the patch | `gitArgv`, `src/tool.zig:781`; test at `src/tool.zig:4146` |
| Every preset tool's description ends with one sentence telling the model that a call leaves the machine and that nothing belonging to the repository under review goes in an argument | a snippet, a path, a repository name or a person's name out of the tree landing in a third party's search or wiki log to answer a coding task | `off_host_note`, `presetDescription`, `src/mcp.zig:986`; test at `src/mcp.zig:1062` |
| Every tool subprocess and every stdio MCP server leads its own process group; the groups are published in one table, SIGKILLed on the way out, and taken with the terminal's interrupt | orphaned build trees and MCP servers holding resources, and a Ctrl+C that leaves a build writing files | `signalGroup`, `src/tool.zig:243`; `publishChildGroup`, `src/tool.zig:267`; `forwardInterruptsToToolGroup`, `src/tool.zig:314`; `runCapped`, `src/tool.zig:2594` |
| Output, response, frame, error-body and config caps; the response cap covers the whole response, not each field | memory exhaustion from a tool, a stream, an error body or a file | `max_tool_output`, `src/tool.zig:25`; `max_response_bytes`, `src/stream.zig:20`; `max_frame_bytes`, `src/main.zig:160`; `max_error_body_bytes`, `src/main.zig:175`; `max_config_bytes`, `src/main.zig:170` |
| Tool-call index cap and a saturating cast | a provider asking for billions of slots, or a wrapped index on a 32-bit build | `max_tool_calls`, `src/stream.zig:10`; check at `src/main.zig:2948` |
| Per-turn cap on what a turn's tool results add to the conversation; every call still answers, with a marker past the cap | one response asking for 64 full-size results: a 1.5 MB request billed before the next turn compacts | `max_turn_tool_output`, `src/main.zig:91`; `carriedToolResult`, `src/main.zig:3785`; check at `src/main.zig:3443` |
| A tool call with no index, no id or no name, or with arguments that are not an object, is dropped rather than dispatched, and the drop reported | a partial or malformed stream entry becoming a command | `keepRunnableCalls`, `src/stream.zig:104`; `argumentsAreAnObject`, `src/stream.zig:135`; report at `src/main.zig:2482` |
| A call whose `id` the response already carried is dropped and the first kept | a relay or proxy replaying a frame, running `bash` twice or writing a file twice | `indexOfCallId`, `src/stream.zig:124`; test at `src/tool.zig:1361`; report at `src/main.zig:2768` |
| All seven tools refuse a credentials file by name, extension or directory, on every component of the path rather than the leaf alone, so `deploy/.env/prod` is refused like `.env`: `read`, `write`, `edit`, `multi_edit`, `search` and `ast` on a named path, `bash` on a command naming one | a `.env`, a private key or a `~/.secrets` file put into the model context or rewritten; a credential at a depth `search` and `git` already excluded while the other tools still read it | `isCredentialPath`, `src/tool.zig:1726`; tables at `src/tool.zig:930-943`; refusals at `src/tool.zig:1158`, `src/tool.zig:1287`, `src/tool.zig:1361`, `src/tool.zig:1448`, `src/tool.zig:1485`, `src/tool.zig:888`, and `git` at `src/tool.zig:489`, `src/tool.zig:506`, `src/tool.zig:509`; test at `src/tool.zig:2814` |
| The credentials refusal tells a call that would change the file from one that would not, so `ast` with `rewrite` on a credentials path gets the advice that no tool rewrites a key, not the one that sends the model to `bash` | a `write` through `--update-all` on a key file, and a model walking into the same refusal one turn later | `credentialRefusal`, `src/tool.zig:1832`; applied at `src/tool.zig:1485`; test at `src/tool.zig:2992` |
| `search` and `ast` skip the same files as traversal globs; `git` excludes them from the diff and the show, including when the call names a path | a credential reaching the provider through a match or a patch | `credential_globs`, `src/tool.zig:1667`; `credential_pathspecs`, `src/tool.zig:1678`; `gitPathspecs`, `src/tool.zig:854` |
| `write` refuses a call with no `content` | a truncated or forgotten argument emptying a file | `toolWrite`, `src/tool.zig:2013` |
| `edit` and `multi_edit` refuse a replacement equal to, or still containing, the text it replaces | a re-issued call rewriting the same file twice | `applyEdit`, `src/tool.zig:2128` |
| `write`, `edit` and `multi_edit` write through a rename, following a symlink and keeping the destination's permission bits | a half-written file where a whole one was, a link replaced by a regular file, a `0600` file coming back `0644` | `writeFileAtomic`, `src/tool.zig:2068`; `permission_bits`, `src/tool.zig:2049`; `resolveSymlinkTarget`, `src/net.zig:332` |
| `bash` timeout capped at 600 s and clipped to the budget left | model-chosen commands running with no deadline | `max_bash_timeout_ms`, `src/tool.zig:65`; `bashTimeoutMs`, `src/tool.zig:1074`; `Budget`, `src/main.zig:2332` |
| A tool call's deadline covers the wait for the child as well as the drain of its pipes, and the process group is signalled when it passes | a command that closes both pipes and then sleeps holding the turn, the process-group reap never firing, and `--budget` not kept | `waitBounded`, `src/tool.zig:2705`; deadline taken at `src/tool.zig:1681` |
| `max_tokens` on every request | one turn generating until the provider's own limit stops it | `default_max_tokens`, `src/main.zig:113`; request body at `src/main.zig:2116` |
| `--max-spend-tokens` stops starting turns once the run has billed that many tokens, counted before each turn; before the first turn that starts at or past 80% of the cap it prints `<spent> of the <cap> token ceiling spent after <n> turn(s)` on stderr, once per run; a cap under 2, or a turn that jumps from below 80% to the cap, gets only the stop line | a run whose conversation re-sends itself every turn, billing more with fewer turns; a run started without a ceiling | `optionalCeiling`, `src/main.zig:1503`; `spendCeilingReached`, `src/main.zig:2447`; `spend_alarm_percent`, `src/main.zig:2435`; `spendAlarmDue`, `src/main.zig:2454`; printed once at `src/main.zig:1756`; check at `src/main.zig:1752`; test at `src/main.zig:4083` |
| A failed subprocess keeps what it printed; only `bash` reports an exit status | a build that printed every error and then timed out reaching the model as a bare error, so the next turn re-ran it | `failedOutput`, `src/tool.zig:542`; `Partial`, `src/tool.zig:2564`; `bash_exit_note`, `src/tool.zig:53` |
| An `ast --rewrite` whose replacement still matches the pattern's own literal text is refused, as is a pattern of metavariables alone | a rewrite that re-applies itself to its own output on the next run | `astRewriteRefusal`, `src/tool.zig:2521`; test at `src/tool.zig:4226` |
| Control bytes escaped in the gutter and scrubbed in error bodies, bounded through one helper | terminal escape injection from repo content, a command-line argument, a config key or a value out of the release body | `toolCallLine`, `src/tool.zig:975`; `terminalSafe`, `src/tool.zig:1026`; `chat.safeText`, `src/chat.zig:691`; `clip`, `src/main.zig:1525`; `quoteUntrusted`, `src/update.zig:40` |
| Non-JSON frames counted and reported; a stream without `[DONE]` fails the turn | a truncated answer read as a finished one | `applyFrame`, `src/stream.zig:593`; count reported at `src/main.zig:2412`; `truncatedNotice`, `src/stream.zig:26` |
| Retry with capped exponential backoff on weather-shaped statuses and on failures before the response head is readable; no retry after the head, except a provider error frame with no content and no tool call behind it, which is the provider saying it generated nothing and is asked again on the same schedule; a `Retry-After` in seconds or as a date is clamped to 120 s; a date whose year is not four digits, or is `0000`, is not read, and the wait falls back to the backoff (a past date or `0` does too); a wait the `--budget` left cannot cover gives up the turn instead of retrying | a dropped connection or a rate limit ending the run; a re-sent turn billed twice; a hostile `Retry-After` year overflowing the epoch multiply; a provider's wait outliving the caller's timeout | retry loop, `src/main.zig:2203`; `net.retryableStatus`, `src/net.zig:336`; `worthAnotherAttempt`, `src/main.zig:3890`; `waitBeforeRetry`, `src/main.zig:3903`; `streamChatOnce`, `src/main.zig:3155`; `reaskWaitMs`, `src/main.zig:3108`; `net.retryBackoffMs`, `src/net.zig:326`; `max_attempts`, `src/main.zig:3860`; `max_retry_after_ms`, `src/net.zig:710`; `retryAfterValueMs`, `src/net.zig:754`; `httpDateYear`, `src/net.zig:871`; year 0 at `src/net.zig:462`; `retryWaitMs`, `src/main.zig:3945`; budget check at `src/main.zig:2272`; the same narrowing in `fetchOnce`, `src/update.zig:369`, which reads no `Retry-After` |
| Session log created exclusively at `0o600`, and a store directory this run creates at `0o700` whichever of the two creates it got there first, the sandbox making it a writable root on an `enabled = true` run and the store opening it after; before and after the run's log is created, the walk counts every file named `<digits>[-<digits>].jsonl` at any depth, orders them by the stamp in the name, then the `-N` suffix, then the path, keeps the newest 200 and deletes the rest by path relative to the store root; a walk that fails part way prunes nothing | one run erasing another's log; unbounded growth; a log nested below the root counted toward the cap while nothing is deleted for it; on a shared account, every other account reading the prompts, the tool arguments and the bytes a tool read out of the tree, which the tools themselves refuse to send the provider; the names of the last 200 logs listed by every other account where the sandbox made the store directory first | `createSessionLog`, `src/session.zig:138`; `log_file_mode`, `src/session.zig:120`; `log_dir_mode`, `src/session.zig:121`; the other creator, `src/sandbox.zig:69`; `pruneSessions`, `src/session.zig:363`, called at `src/session.zig:219`; `pruneSessionsTo`, `src/session.zig:393`; `logName`, `src/session.zig:313`; sort at `src/session.zig:439`; `max_session_logs`, `src/session.zig:251` |
| Receive timeout on the response socket, so a provider that accepts the connection and sends nothing does not hold the turn | a silent provider holding a run open until a turn or the wall clock stops it | `default_stall_timeout_s`, `src/main.zig:118`; `setStallTimeout`, `src/main.zig:3036`; applied at `src/main.zig:2222` |
| Values validated where they are set | a mistyped level or ceiling reaching the wire as a 400 | `ceiling`, `src/main.zig:1336`; `optionalCeiling`, `src/main.zig:1503` |
| Fuzz corpora for the parsers that take untrusted bytes: the release body, the sidecar, the completion stream and the fold that reads it, the config file, both command lines, a JSON string, a tool call, a quoted value, a provider error body, the session store's names and its record, the request body a turn assembles from model text and tool output, and the server, tool, environment and header names an MCP entry is built from | malformed provider, release, config, command-line, tool-call, session-store, conversation or terminal-facing input, and a name that passes the entry checks but cannot be used afterwards | `fuzzRelease`, `src/update.zig:1289`; `fuzzSidecar`, `src/update.zig:1348`; `fuzzArgs`, `src/update.zig:839`; `fuzzStream`, `src/main.zig:6379`; `fuzzFrame`, `src/stream.zig:1918`; `fuzzFrameSequence`, `src/stream.zig:2209`; `fuzzArgs`, `src/main.zig:4773`; `fuzzConfig`, `src/config.zig:1955`; `fuzzJsonString`, `src/chat.zig:1389`; `fuzzToolCall`, `src/tool.zig:3360`; `fuzzSafeText`, `src/chat.zig:1221`; `fuzzTerminalSafe`, `src/tool.zig:3865`; `fuzzStoreNames`, `src/session.zig:1544`; `fuzzSessionRecord`, `src/session.zig:1672`; `fuzzBody`, `src/conversation.zig:863`; `fuzzEntryNames`, `src/mcp.zig:2498` |

## Gaps, ranked by exploitability and impact

1. **No confinement on model-driven execution by default.** `bash`, `write`, `edit`, `multi_edit` and an `ast`
   rewrite run with full operator authority, and the instructions that trigger them can
   come from a file the run reads. The system prompt asks the model not to act on such a
   file (`src/main.zig:138`), the same trust the operator already placed in the prompt.
   Command filtering (`deny_commands`) blocks dangerous command words before execution.
   When sandbox mode is enabled (`[sandbox]` in config), Linux Landlock rules or a macOS Seatbelt profile confine
   all child process writes to designated directory roots.
2. **The credential rule is a name rule, and `bash` matches it on words.** All seven tools
   refuse a path the tables name, at any depth rather than only at the leaf
   (`isCredentialPath`, `src/tool.zig:1726`), so none can put a known `.env` or private key
   in the model context. Two ways around it remain. A credential under a name the tables do
   not carry is still read. And `credentialInCommand` (`src/tool.zig:883`) tokenizes the
   command instead of parsing a shell, so a command that assembles a path at run time
   reaches the file. The run's own keys, the case that mattered most, are closed
   structurally rather than textually: no tool subprocess inherits them
   (`secret_env_vars`, `src/main.zig:1946`).
3. **A named CA bundle is trusted without a policy.** `MICROAGENT_CA_BUNDLE`,
   `SSL_CERT_FILE` and `--ca-bundle` add whatever the file holds to the trust store of the
   provider connection and of the release download (`loadCaBundle`, `src/net.zig:64`;
   `src/main.zig:477`; `src/update.zig:544`). A bundle naming one attacker-issued root is a
   machine in the middle for both, and the sha256 sidecar it serves hashes as published, so
   the updater installs what it was handed. The system store is still scanned, which makes
   the added root additional rather than a replacement. That is the whole check.
4. **No host policy on `base_url`, only a scheme policy.** The key never goes out over
   plaintext `http` off loopback, but `MICROAGENT_BASE_URL` or `--base-url` may name any
   `https` host, and the key follows. A poisoned environment variable turns a review run
   into a key handoff to whoever answers on that name.
5. **The tools are not confined to the working tree by default.** `read`, `write`, `edit` and `multi_edit` take and
   follow an absolute path; `writeFileAtomic` (`src/tool.zig:1418`) follows a symlink
   before writing; `ast --rewrite` applies its replacement to every match
   (`src/tool.zig:1497`). When sandbox mode is enabled (`[sandbox] enabled = true` in config),
   in-process path checks refuse `write`, `edit` and `multi_edit` calls outside writable roots, and on Linux
   (kernel 5.13+) Landlock rules, or on macOS a Seatbelt profile, confine filesystem modifications for microagent and all
   spawned subprocesses.
6. **The API key is accepted on the command line.** It is visible in the process table and
   in shell history. The README's first example uses the environment, and the flag cannot
   be made to match that.
7. **The release checksum is self-attesting.** A compromised release account, or a token
   with write access to the repository, replaces the asset and the sidecar together, and
   `update` installs it. The token is narrowed to the one API that needs it, so this gap is
   the release account alone.
8. **No cost ceiling unless one is asked for.** `--max-turns`, `--max-tokens` and
   `--budget` bound turns, tokens per turn and time. `--max-spend-tokens`
   (`MICROAGENT_MAX_SPEND_TOKENS`) bounds money, and it is opt-in: leaving it out means no
   ceiling, as an unset `--budget` means no deadline (`optionalCeiling`,
   `src/main.zig:860`). The check runs before a turn starts (`src/main.zig:1752`), so the
   provider never sees a request the run has already priced itself out of, and the turn
   that reaches the ceiling is the one that finishes. A run started without it, by a prompt
   or a harness that chose no ceilings, is bounded only by what the conversation happens
   to cost.
9. **No audit trail beyond the gutter line.** Tool calls go to stderr as one line with no
   timestamp, no exit status and no file (`noteToolCall`, `src/tool.zig:959`). The session
   log records token counters, the working directory and the finish reason, never which
   commands ran (`writeRecord`, `src/session.zig:512`).
10. **A symlinked install can point anywhere.** `replaceBinary` follows the link
    (`src/update.zig:429`, through `src/net.zig:288`). A link planted in a directory on the
    operator's `PATH` redirects the write, and `write`, `edit` and `multi_edit` follow links the same way.
11. **A config file can redirect the system prompt.** `system_prompt_extra` in the config
    file is appended to the system prompt (`loadConfig`, `systemText`, `src/main.zig`),
    up to 16 KB (`max_system_prompt_extra_bytes`, `src/config.zig`). The file is
    operator-supplied and capped at 64 KB (`max_config_bytes`, `src/main.zig:170`), but
    nothing in it is sandboxed, and it reaches the provider on every turn like any other
    prompt text.
12. **The stall timeout has a floor and no ceiling.** `MICROAGENT_STALL_TIMEOUT` and
    `--stall-timeout` go through `ceiling` (`src/main.zig:799`), which refuses zero and
    nothing else, so a century is accepted and set on the response socket
    (`setStallTimeout`, `src/main.zig:3036`). The bound meant to stop a silent provider
    holding a turn open is then worthless, and the run waits on the other bounds (turn
    count, wall clock). The value is operator input, so this is a misconfiguration that
    fails open rather than an attack path, and `--budget` still applies.
13. **Network egress to remote MCP servers is not confined, and their content is not vetted.** The
    sandbox confines writes, not connections, so a `url` server or a preset reaches its endpoint
    whatever `[sandbox]` says, and the model's queries (search terms, library names, code
    fragments it pastes into `searchGitHub`) go to a third party that keeps whatever it likes. The
    only policy on the endpoint is the scheme: any `https` host is accepted, as gap 4 says of
    `base_url`. A result is untrusted text with no provenance, so an endpoint that answers with
    instructions reaches the model through a channel the operator chose, and the defence is the
    one in gap 1. The timeout races the whole exchange and cancels it; the tests cover a server that
    never answers, not a connect that never completes. Presets are off by default, so the exposure is the operator's
    choice, per run.

## Abuse cases

Each is a scenario, evidenced by the code path that enables it. None has been attempted.

- **A poisoned test fixture.** A repository contains a fixture whose text tells the agent
  to run a command. The model reads it with `read` (`toolRead`, `src/tool.zig:1861`) and,
  through `bash` (`toolBash`, `src/tool.zig:1433`), the command runs as the operator. The
  agent cannot tell file content from operator instruction. The prompt tells it to report
  such a file instead, and a persuasive enough file can argue with that.
- **A hostile endpoint.** With `--base-url` pointed at an `https` server the attacker
  controls, the key arrives in the `authorization` header (`authHeaders`,
  `src/main.zig:2135`) and the reply decides every later tool call. The scheme check
  passes, because the attacker serves `https`.
- **A symlink on the update path, or in the tree.** A link named `microagent` earlier on
  `PATH` is followed at install time (`replaceBinary`, `src/update.zig:438`). A link beside a source file
  redirects a `write` or an `edit` (`resolveSymlinkTarget` call in `writeFileAtomic`,
  `src/tool.zig:1336`), so the run changes a file the operator never named.
- **Scraping through the harness.** `read` has no path restriction, so a run over a
  directory holding credentials under names the tables do not carry reads them and,
  through the model, can send them off the machine. There is no per-run file budget
  either, only the 4 MB per read (`max_read_bytes`, `src/tool.zig:37`).
- **A runaway bill.** `--max-turns` at its ceiling and a conversation that grows to 400 KB
  before compaction (`conversation_soft_limit`, `src/conversation.zig:16`; `compactMessages`,
  `src/conversation.zig:168`) cost real tokens, with `max_tokens` bounding each turn. A run
  started without `--max-spend-tokens` has nothing bounding the whole run: the turn loop
  asks the provider again on its own schedule (`src/main.zig:1744`).
- **A trust anchor from the environment.** A run started with `MICROAGENT_CA_BUNDLE`
  pointing at an attacker's file terminates both connections the run makes: the provider
  request that carries the key (`authHeaders`, `src/main.zig:3018`, applied at `src/main.zig:2745`) and the release download `update`
  performs (`src/update.zig:544`). Nothing checks what the file certifies, so a
  certificate naming the attacker's host is enough.
- **A poisoned task container.** The Harbor adapter hands the provider key to every task
  container it starts ([microagent_agent.py:482](../integrations/harbor/microagent_agent.py)),
  so a task written by a third party holds the key for the length of its run.
- **Trust placed in the model's own bookkeeping.** A run that edited the tree and never ran
  a test is asked once, in prose, to verify (`verify_push`, `src/main.zig:867`). "Ran a
  test" is detected by a substring match over the tool call's arguments (`isTestRun`,
  `src/main.zig:1894`). It is a quality prompt, not a control: a command that runs a test
  without naming one of the listed runners is invisible to it, and no refusal follows
  either way. What counts as an edit is read from the call's own arguments, so `ast`
  counts for `--rewrite` and not for a search (`isEdit`, `src/main.zig:2744`). A run that
  changed the tree with a tool the list does not carry is asked nothing.

## Response readiness

Note only; not built here.

- Tool activity is one stderr line per call with no timestamp and no exit status
  (`noteToolCall`, `src/tool.zig:959`), and the session log keeps no record of it
  (`writeRecord`, `src/session.zig:512`). Reconstructing what a run did after an incident
  has to start from the working tree, not from a log.
- There is no `SECURITY.md`. The README's Status section ([README.md](../README.md#status))
  points here and makes no claim this document contradicts. The two supported-versions
  statements ([usage.md](usage.md#versioning); [CHANGELOG.md:10](../CHANGELOG.md)) agree with each other
  and with the release workflow: only the latest release is supported, with no backport
  window. There is no disclosure contact and no documented path from a reported
  vulnerability to a shipped fix, and this document does not invent one.
- [CHANGELOG.md](../CHANGELOG.md) records every change that alters what a run does: the
  closest thing to a public record of behavior changes.
