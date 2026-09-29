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
| 1 | Repository content drives shell execution | repo → model → host | high: any content the model reads can carry an instruction | full compromise of the operator's account, files and keys | prompt wording (`system_prompt`, `src/conversation.zig:34`), command filter (`deny_commands`), and Landlock LSM confinement when sandbox enabled (gap 1) |
| 13 | A skill body is prompt text the model is told to follow | operator config → model | low: needs a write to a skills directory, the config file, or `MICROAGENT_SKILLS` | the run follows instructions the operator did not write, and the conversation is re-sent to the provider | skills are read only from the roots the config file or the variable names, else `$HOME/.microagent/skills`, never from the working tree (`roots`, `src/skill.zig:144`; `discover`, `src/skill.zig:218`), so a repository under review cannot install one; the listing escapes control bytes (`Skills.prompt`, `src/skill.zig:95`); a body reaches the conversation only when the model calls the tool, as a tool result under the same cap as any other |

`microagent` is a local CLI with no listener, no server and no database. It holds no user
data of its own: it exposes the operator's own machine, and an attacker wants the key, the
source tree and the host. The one asset worth stealing on its own is the API key.

## Attack surface

### Entry points in the code

| Entry point | What arrives | Handled at |
| --- | --- | --- |

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
   (`system_prompt`, `src/conversation.zig:34`). Nothing in the program separates the model's own
   plan from an instruction it found in a file; only an instruction in the prompt does.
3. **Provider → agent.** The streamed reply decides the next action. The validation point
   is `applyFrame` (`src/stream.zig:559`), which bounds the shape, not the intent.
4. **Agent → provider.** The key goes out in an `authorization` header (`authHeaders`,
   `src/main.zig:2135`) to whatever host `base_url` names, after the scheme check at
   `src/main.zig:334`.
5. **Model → filesystem and process.** `bash` runs `/bin/sh -c` with the model's string
6. **GitHub → host.** `update` downloads bytes and writes them over the running executable
   (`fetch`, `src/update.zig:303`; `installIfVerified`, `src/update.zig:445`).
   Validation point: `installIfVerified` (`src/update.zig:445`).
7. **Secrets → process.** The key enters from `argv`, the environment or a file, lives in
   process memory for the run, and leaves only in the `authorization` header. It is never
   written to the session log or to a tool result.
8. **Operator config → host (MCP).** The `[[mcp]]` tables name programs the run starts as
   children before the first request; the tools they report are advertised to the model and
   dispatched to them (`config.parse`, `src/config.zig:163`; `connect`, `src/mcp.zig:1261`).
   Validation point: the tables come from the config file named by `--config`, the variable
   or `$HOME/.microagent/config.toml`, and from nowhere in the tree (`configSource`,
   `src/main.zig`). The children inherit the scrubbed environment, which lacks the
   configured server does with its own authority is the operator's decision, as with a
   `bash` command they write.
10. **Remote MCP server → model, and agent → remote server.** A `url` table or a preset that is on
   sends each tool call's name and arguments to an HTTPS endpoint the operator named, and the text
   it answers with becomes a tool result, as a file's contents do. Validation points: the url
   must be `https`, or `http` on loopback, with no userinfo (`validUrl`, `src/mcp.zig:1191`); a
   redirect is an error, the body is capped at 4 MB and the request at its timeout (`exchange`,
   `src/mcp.zig:405`); the key is looked up by a variable name written in the file and sent in one
   result can carry instructions, and it is untrusted for the same reason a file from a
   repository under review is.
9. **Operator skills → model.** A `SKILL.md` body is instruction text the model is told to
   follow. It reaches the conversation only when the model calls the `skill` tool (`call`,
   `src/skill.zig:363`). Validation point: the roots are the config file's `skills` list,
   the directories `MICROAGENT_SKILLS` names, or the operator's home directory, never the
   tree (`roots`, `src/skill.zig:144`; `discover`, `src/skill.zig:218`).

Privilege transitions are total, not gradual: once the model calls `bash`, the run has the
operator's full authority. No user confirmation sits between a model decision and a
command.

## Assets

| Asset | Why it matters | Where it lives |
| --- | --- | --- |
| Provider API key | bills, model access, provider account | `argv`, the environment or the config file, then process memory |

## Threats per boundary

### Operator → agent (STRIDE: spoofing, tampering, information disclosure)

- A prompt that names a hostile base URL steers the whole run. It is an operator input, so
  this is a threat only where an automated harness passes a task's text straight through
  (`bench/gauntlet.sh`).
- A prompt of any length enters the conversation uncapped (`setPrompt`,
  `src/main.zig:1106`; appended in `openConversation`, `src/conversation.zig:383`), and the
  request body grows with it.

### Repository content → model → host (elevation of privilege, information disclosure)

- **Prompt injection through source files.** A file, a test fixture or an issue template in the
  tree can say "run `curl … | sh`". The model reads it with the ordinary `read` tool
  trusted as the operator's prompt. The system prompt tells the model to treat tool output as data
  and to report such a file instead of acting on it (`system_prompt`, `src/conversation.zig:34`),
  but a hostile file can argue with that. This is the project's dominant risk, and it is a design
  property, not a bug.
- `AGENTS.md` is the one file in the tree the run follows as instructions rather than as data, and
  that is deliberate: it is the convention every other coding agent reads, and a run whose operator
  wants none sets `agents_files = []`. Its authority is bounded in the prompt rather than in the
  code, because the file's whole purpose is to direct the run: the block is fenced between a begin
  and an end marker, the prompt states that it governs the task and cannot widen it, lift the
  prompt's rules, authorize a credential, or send anything off the machine, and a line asking for
  one of those is reported rather than obeyed (`system_prompt`, `src/conversation.zig:34`;
- A hostile repository can also reach the terminal. Bytes a tool echoes reach the gutter
  line (`toolCallLine`, `src/tool.zig:715`). The provider's text reaches stdout unescaped,
  deliberately: it is the answer the run was asked for.

### Provider → agent (spoofing, tampering, denial of service)

- A hostile or coerced endpoint chooses every tool call. One response can carry up to 64
  calls (`max_tool_calls`, `src/stream.zig:11`, enforced by the index check at
  `src/main.zig:2948` and the index clamp in `applyCallDelta`, `src/stream.zig:498`), and
  they run as the operator.
- A tool call's name and argument object are the provider's own text, parsed from bytes
  the model read out of the tree. They are fuzzed from the argument JSON to the gutter line
  and the limits it produces: the line stays one line inside its buffer with no byte a
  terminal acts on, and every count the model wrote is inside its ceiling before a
- A call the provider gave no index, no id or no name, or whose arguments are not a JSON
  object, is dropped rather than dispatched (`keepRunnableCalls`, `src/stream.zig:105`;
  `argumentsAreAnObject`, `src/stream.zig:136`). The drop count is reported, so the turn
  does not pass for one that dispatched everything (`src/main.zig:2482`).
- The transport is at-least-once: a relay that reconnects replays from the last event it
  saw, and a proxy that retries a chunk re-sends it. A call whose `id` the response already
  carries is dropped and the first kept (`indexOfCallId`, `src/stream.zig:125`), so a
  replayed `bash` runs once.
- A stream that never sends `[DONE]` grows the turn until the caps at `src/main.zig:114`
  and `src/main.zig:129` stop it, and the run ends as truncated (`truncatedNotice`,
  `src/stream.zig:27`).
- A provider that accepts the connection and never sends a byte is bounded by a receive
  timeout on the response socket, 120 s unless the operator raises it
  wait, so a hostile environment that sets it very high turns the stall bound off (gap 12).
- An error body from the provider is printed on stderr through `terminalSafe`
  (`src/tool.zig:750`) and capped at 16 KB (`max_error_body_bytes`, `src/main.zig:159`).
  Control bytes are scrubbed, so it cannot repaint the terminal.
- Frames that are not JSON are counted and dropped (`applyFrame`, `src/stream.zig:588`;
  counter at `src/main.zig:2344`). They are not fatal: the run continues on a partial turn
  and reports the count at `src/main.zig:2412`.

### Agent → provider (information disclosure, spoofing)

- The key is refused to any base URL that would put it on the wire in the clear:
  `net.urlCarriesKey` (`src/net.zig:312`) requires `https`, or `http` on loopback, and
  `main` fails the run otherwise (`src/main.zig:393`). `isLoopbackHost` (`src/net.zig:321`)
  accepts `localhost` and any name ending in `.localhost`, both case-insensitive; `::1`
  with or without brackets; and `127.a.b.c` only as exactly four dotted decimal octets of
  one to three digits, each at most 255 (`isIpv4Loopback`, `src/net.zig:448`). So
  `127.evil.com`, `localhost.evil.com`, `127.1`, `127.0.0.256`, `localhost.` with a
  trailing dot, and other IPv6 spellings of loopback do not qualify. The test at `src/main.zig:3205` pins the policy. The remote MCP transport applies the same
  rule to its urls (`validUrl`, `src/mcp.zig:1191`).
- The key goes to the base URL, which is the built-in OpenRouter one unless the operator
  named another. Only `MICROAGENT_API_KEY` is read, so a key another provider's tools
  export (`OPENAI_API_KEY`, `DEEPSEEK_API_KEY`) is never picked up and sent to the default
  endpoint by accident. A base URL the operator named is deliberately never questioned,
  because a self-hosted gateway is a legitimate destination for any provider's key.
- The check does not constrain *which* `https` host. `MICROAGENT_BASE_URL` or `--base-url`
  may name any host, and the key follows.
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
  `src/main.zig:1457`: `MICROAGENT_API_KEY` plus `GITHUB_TOKEN`), so `bash env` and
  `bash printenv` cannot put the run's own key in the transcript. A command naming a
  credentials file is refused on the same name rule the other tools apply
  (`credentialInCommand`, `src/tool.zig:900`, applied at `src/tool.zig:888`). That rule
  reads the command's words, not a parsed shell, so a file reached through indirection is
  not caught. A command matching a configured command filter (`deny_commands` in config) is
  refused before execution (`deniedInCommand`, `src/tool.zig:925`).
- `read`, `write`, `edit` and `multi_edit` accept absolute paths and do not confine writes to the working
  symlink planted in the tree therefore redirects a write, and a rewritten file keeps its
  mode instead of taking the process umask's.
- `ast` with `rewrite` set applies its replacement to every match (`toolAst`,
  `src/tool.zig:1474`), so one model turn can rewrite a whole file set. A rewrite that
  That is evidence the run reads back, not a sandbox: a replacement that re-matches through
  a form the pattern's literal text does not spell is still applied.
- Bounded today: 60 s tool timeout (`tool_timeout_ms`, `src/tool.zig:54`); 120 s default
  (`default_bash_timeout_ms`, `src/tool.zig:64`) and 600 s ceiling for `bash`
  (`max_bash_timeout_ms`, `src/tool.zig:59`, applied through `bashTimeoutMs` at
  `src/tool.zig:798` and `boundedMs` at `src/tool.zig:70`), clipped to the budget's
  the 24 KB the model reads (`max_tool_output`, `src/tool.zig:24`; `runCapped`,
  `src/tool.zig:1638`); `--max-turns` (`max_turns_default`, `src/main.zig:98`); and the
  wall-clock budget (`src/main.zig:1539`).

### GitHub → host (spoofing, tampering, elevation of privilege)

- The release JSON is attacker-shaped: every field becomes a tag, an asset name or a URL
  the updater acts on (`parseRelease`, `src/update.zig:171`). It is fuzzed against exactly
  that (`fuzzRelease`, `src/update.zig:1256`; `fuzzSidecar`, `src/update.zig:1315`).
- The repository the updater requests is a constant compiled into the binary (`default_repo`,
  `src/update.zig:12`, read into `release_api_url` at `src/update.zig:14`), not caller text,
  so a command line cannot steer it. The `--repo` flag that once let a caller name one is
  gone, and with it the `owner/name` validation that guarded it: a repository name is no
  longer an input at any boundary, and the release page, the asset and the sidecar are each
  held to the host allowlist before a request carries them (`trustedGithubUrl`,
  `src/update.zig:116`, applied at `src/update.zig:551` and `src/update.zig:595`; harness
  `fuzzArgs`, `src/update.zig:819`).
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
  is verified against (`loadCaBundle`, `src/net.zig:59`, called at `src/update.zig:544`).
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

The last two share the shape of the rest: a control the code assumed was implied turned
out to be a separate thing. Each has a control named above; a regression in any of them is
the same bug returning.

## Mitigations in the code

| Control | Covers | Where |
| --- | --- | --- |
| System prompt names tool output, file contents and command output as data, and tells the model to report a file that gives orders | prompt injection through a file, at the model rather than in the program | `system_prompt`, `src/conversation.zig:34` |
| The repository the updater requests is a compile-time constant, so no caller text reaches a URL | URL injection through a repository name | `default_repo`, `src/update.zig:12`; `release_api_url`, `src/update.zig:14` |
| Host allowlist: `https` on `github.com`, `*.github.com`, `*.githubusercontent.com`, no userinfo, checked on the page URL and both asset URLs | asset and page download from a lookalike host | `hostTrusted`, `src/update.zig:105`; `trustedGithubUrl`, `src/update.zig:116`; applied at `src/update.zig:551` and `src/update.zig:595` |
| `GITHUB_TOKEN` is presented only to `https://api.github.com/`, prefix-compared octet by octet, so a lookalike host, a userinfo URL and a path carrying the API name all get nothing; the asset and the sidecar go out unauthenticated | a repository-scoped token handed to the asset CDN, to `api.github.com.evil.com`, or to a path that merely contains the API name | `bearerFor`, `src/update.zig:147`; read once at `src/update.zig:545` and applied per request at `src/update.zig:414` |
| A CA bundle that cannot be read, or holds no certificate, is refused and the system store used instead | a bundle silently emptying the trust store, so every request fails as if the machine shipped no certificates | `loadCaBundle`, `src/net.zig:59` |
| sha256 sidecar verified before the verdict is `replaced` | corrupted or substituted download | `checksumMatches`, `src/update.zig:154`; `installIfVerified`, `src/update.zig:445` |
| Version comparison refuses a downgrade | installing an older build over a newer one | `compareVersions`, `src/update.zig:85`; `sameRelease`, `src/update.zig:52`; both applied at `src/update.zig:554` |
| Atomic replace, only on `.replaced` | partial write, write on a refusal | `installIfVerified`, `src/update.zig:445`; `replaceBinary`, `src/update.zig:429` |
| The key is refused on a plaintext `http` base URL off loopback; a `127.` host needs exactly four octets, every one range-checked | the key crossing a network path in the clear, or going to a name spelled like an address | `urlCarriesKey`, `src/net.zig:427`; `isLoopbackHost`, `src/net.zig:436`; `isIpv4Loopback`, `src/net.zig:448`; enforced at `src/main.zig:393`; test at `src/main.zig:3205` |

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
   in the model context. Two ways around it remain. A credential under a name the tables do
   not carry is still read. And `credentialInCommand` (`src/tool.zig:883`) tokenizes the
   command instead of parsing a shell, so a command that assembles a path at run time
   reaches the file. The run's own keys, the case that mattered most, are closed
   structurally rather than textually: no tool subprocess inherits them
3. **A named CA bundle is trusted without a policy.** `MICROAGENT_CA_BUNDLE`,
   `SSL_CERT_FILE` and `--ca-bundle` add whatever the file holds to the trust store of the
   provider connection and of the release download (`loadCaBundle`, `src/net.zig:59`;
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
   timestamp, no exit status and no file (`noteToolCall`, `src/tool.zig:699`). The session
   log records token counters, the working directory and the finish reason, never which
   commands ran (`writeRecord`, `src/session.zig:499`).
10. **A symlinked install can point anywhere.** `replaceBinary` follows the link
    (`src/update.zig:429`, through `src/net.zig:288`). A link planted in a directory on the
    operator's `PATH` redirects the write, and `write`, `edit` and `multi_edit` follow links the same way.
11. **A config file can redirect the system prompt.** `system_prompt_extra` in the config
    file is appended to the system prompt (`loadConfig`, `systemText`, `src/main.zig`),
    up to 16 KB (`max_system_prompt_extra_bytes`, `src/config.zig`). The file is
    operator-supplied and capped at 64 KB (`max_config_bytes`, `src/main.zig:154`), but
    nothing in it is sandboxed, and it reaches the provider on every turn like any other
    prompt text.
12. **The stall timeout has a floor and no ceiling.** `MICROAGENT_STALL_TIMEOUT` and
    `--stall-timeout` go through `ceiling` (`src/main.zig:799`), which refuses zero and
    nothing else, so a century is accepted and set on the response socket
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
  agent cannot tell file content from operator instruction. The prompt tells it to report
  such a file instead, and a persuasive enough file can argue with that.
- **A hostile endpoint.** With `--base-url` pointed at an `https` server the attacker
  controls, the key arrives in the `authorization` header (`authHeaders`,
  `src/main.zig:2135`) and the reply decides every later tool call. The scheme check
  passes, because the attacker serves `https`.
- **A symlink on the update path, or in the tree.** A link named `microagent` earlier on
  `PATH` is followed at install time (`replaceBinary`, `src/update.zig:429`). A link beside a source file
  redirects a `write` or an `edit` (`resolveSymlinkTarget` call in `writeFileAtomic`,
  `src/tool.zig:1336`), so the run changes a file the operator never named.
- **Scraping through the harness.** `read` has no path restriction, so a run over a
  directory holding credentials under names the tables do not carry reads them and,
  through the model, can send them off the machine. There is no per-run file budget
  either, only the 4 MB per read (`max_read_bytes`, `src/tool.zig:36`).
- **A runaway bill.** `--max-turns` at its ceiling and a conversation that grows to 400 KB
  before compaction (`conversation_soft_limit`, `src/conversation.zig:16`; `compactMessages`,
  `src/conversation.zig:168`) cost real tokens, with `max_tokens` bounding each turn. A run
  started without `--max-spend-tokens` has nothing bounding the whole run: the turn loop
  asks the provider again on its own schedule (`src/main.zig:1744`).
- **A trust anchor from the environment.** A run started with `MICROAGENT_CA_BUNDLE`
  pointing at an attacker's file terminates both connections the run makes: the provider
  performs (`src/update.zig:544`). Nothing checks what the file certifies, so a
  certificate naming the attacker's host is enough.
- **A poisoned task container.** The Harbor adapter hands the provider key to every task
  container it starts ([microagent_agent.py:482](../integrations/harbor/microagent_agent.py)),
  so a task written by a third party holds the key for the length of its run.
- **Trust placed in the model's own bookkeeping.** A run that edited the tree and never ran
  test" is detected by a substring match over the tool call's arguments (`isTestRun`,
  `src/main.zig:1894`). It is a quality prompt, not a control: a command that runs a test
  without naming one of the listed runners is invisible to it, and no refusal follows
  either way. What counts as an edit is read from the call's own arguments, so `ast`
  changed the tree with a tool the list does not carry is asked nothing.

## Response readiness

Note only; not built here.

- Tool activity is one stderr line per call with no timestamp and no exit status
  (`noteToolCall`, `src/tool.zig:699`), and the session log keeps no record of it
  (`writeRecord`, `src/session.zig:499`). Reconstructing what a run did after an incident
  has to start from the working tree, not from a log.
- There is no `SECURITY.md`. The README's Status section ([README.md](../README.md#status))
  points here and makes no claim this document contradicts. The two supported-versions
  statements ([usage.md](usage.md#versioning); [CHANGELOG.md:10](../CHANGELOG.md)) agree with each other
  and with the release workflow: only the latest release is supported, with no backport
  window. There is no disclosure contact and no documented path from a reported
  vulnerability to a shipped fix, and this document does not invent one.
- [CHANGELOG.md](../CHANGELOG.md) records every change that alters what a run does: the
  closest thing to a public record of behavior changes.
