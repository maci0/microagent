# Threat model

What can be attacked in microagent, from where, and what stands in the way. Every entry
below carries a file reference so the next pass can re-verify it against the code rather
than against this document.

Last reviewed: 2026-09-29, against `0.2.0` (`build.zig.zon`) and the `Unreleased` section
of `CHANGELOG.md`.

## Summary, risk-ranked

| # | Threat | Boundary | Exploitability | Impact | Control today |
| --- | --- | --- | --- | --- | --- |
| 1 | Repository content drives shell execution | repo → model → host | high: any content the model reads can carry an instruction | full compromise of the operator's account, its files and its keys | prompt wording only (`system_prompt`, `src/main.zig:92`); no mechanical control (gap 1) |
| 2 | The provider's reply drives shell execution | provider → host | medium: needs a hostile, coerced or MITM'd endpoint | same as 1 | redirect refused (`streamChat`, `src/main.zig:1158`), response caps, timeouts, `bash` timeout ceiling (`default_bash_timeout_ms`/`max_bash_timeout_ms`, `src/tool.zig:39`/`41`) |
| 3 | The API key is sent to the host the environment names | agent → provider | medium: any `https` host is accepted | provider account takeover, bill abuse | plaintext `http` refused off loopback (`baseUrlCarriesKey`, `src/main.zig:487`, enforced at `src/main.zig:246`) |
| 4 | Tools read and write outside the working tree | model → filesystem | high: `read`/`write`/`edit` take any path | read or overwrite `~/.ssh`, `~/.aws`, CI tokens | `read` refuses a credentials file (`isCredentialPath`, `src/tool.zig:607`); `write`/`edit` still take any path |
| 5 | Tool output carries credentials to the model and on to the provider | host → model → provider | low: a credential under a name the rules do not know, or reached through shell indirection | secret exfiltration through a routine run | `read` refuses, `search` and `ast` skip, `git` refuses by path, `bash` refuses a command naming one (`toolSearch`/`toolAst` globs, `src/tool.zig:847`/`873`; `toolGit`, `src/tool.zig:276`; `credentialInCommand`, `src/tool.zig:461`); the run's own key is not in a tool's environment to print (`childEnviron`, `src/main.zig:776`) |
| 6 | A compromised release replaces the binary | GitHub → host | low: needs the release account or its token | persistent, silent code execution on every later run | sha256 sidecar, host allowlist (`checksumMatches`, `src/update.zig:236`; `hostTrusted`, `src/update.zig:168`) |
| 7 | The API key is visible in the process table | operator → host | low: needs a local reader | key theft by any other process or user on the box | none |
| 8 | A hostile or malformed provider response exhausts memory or CPU | provider → agent | medium | run killed, machine memory spent | per-response cap (`max_response_bytes`, `src/main.zig:69`), frame cap (`max_frame_bytes`, `src/main.zig:84`), timeouts, process-group kill |
| 9 | A hostile repository writes escape sequences to the operator's terminal | repo → terminal | high: any file the model echoes | terminal spoofing, clipboard tricks | control bytes escaped in the gutter (`toolCallLine` via `chat.safeText`, `src/tool.zig:381`/`396`, `src/chat.zig:262`) and scrubbed in error text (`terminalSafe`, `src/tool.zig:406`) |
| 10 | A hostile model result spends the operator's money | model → provider | medium: a runaway or looping run | unbounded bill on the provider account | per-request `max_tokens` (`src/main.zig:48`), turn and wall-clock ceilings; no spend limit (gap 6) |

`microagent` is a local CLI with no listener, no server and no database. It holds no user
data of its own: what it exposes is the operator's own machine, and what an attacker wants
is the key, the source tree and the host. The one place it holds something worth stealing
on its own is the API key.

## Attack surface

### Entry points in the code

| Entry point | What arrives | Handled at |
| --- | --- | --- |
| Command line, agent mode | prompt, flags, api key in `argv` | `parseArgs`, `src/main.zig:646`; `main`, `src/main.zig:161` |
| Command line, `update` | `--check`, `--repo` | `parseArgs`, `src/update.zig:667`; `run`, `src/update.zig:697`; dispatched from `main` |
| `MICROAGENT_MODEL`, `MICROAGENT_BASE_URL`, `MICROAGENT_REASONING_EFFORT` | endpoint, model, response style | `envValue`, `src/main.zig:420` |
| `MICROAGENT_MAX_TURNS`, `MICROAGENT_MAX_TOKENS` | loop and response ceilings | `max_turns_default`, `src/main.zig:50`; `default_max_tokens`, `src/main.zig:58`; both through `ceiling`, `src/main.zig:467` |
| `MICROAGENT_API_KEY`, `OPENAI_API_KEY`, `OPENROUTER_API_KEY`, `DEEPSEEK_API_KEY` | provider credential | `key_vars`, `src/main.zig:760`; resolved at `resolveKey`, `src/main.zig:741` |
| `~/.secrets/openrouter` | provider credential, up to 4 KB | path built in `resolveKey`, `src/main.zig:748`; read by `readSecret`, `src/tool.zig:103`; cap `max_secret_bytes`, `src/tool.zig:29` |
| `MICROAGENT_CA_BUNDLE`, `SSL_CERT_FILE` | the trust anchors for the provider host and for GitHub | `caBundlePath`, `src/net.zig:87`; loaded at `src/main.zig:251` and `src/update.zig:748` |
| `MICROAGENT_CONFIG`, `~/.microagent/config.toml` | reply-style levels, 64 KB cap | `styleConfigPath`, `src/main.zig:884`; `loadStyle`, `src/main.zig:802`; cap `max_config_bytes`, `src/main.zig:86` |
| `MICROAGENT_BUDGET_SECONDS` | wall-clock ceiling on the run | `budgetSeconds`, `src/main.zig:541`; carried by `Budget`, `src/main.zig:939` |
| `MICROAGENT_SESSION_DIR` | where the JSONL run log is written | `sessionDir`, `src/session.zig:27`; read at `src/main.zig:215` |
| `MDEBUG` | writes protocol notes and the resolved configuration to stderr, never the key | `debugEnabled`, `src/main.zig:433`; `traceConfig`, `src/main.zig:839` |
| `GITHUB_TOKEN` | credential, sent to the API and to the asset host | `githubBearer`, `src/update.zig:589`; used at `src/update.zig:751` (API), `813` (asset), `818` (sidecar) |
| GitHub release JSON | tag, page URL, asset names, download URLs | `parseRelease`, `src/update.zig:311` |
| Downloaded asset and `.sha256` sidecar | bytes that become the running executable | fetched by `fetchAsset`/`fetchBody`, `src/update.zig:504`/`471`; installed by `replaceVerified`, `src/update.zig:269` |
| Streamed provider response (SSE) | model text and tool calls | `streamChat`, `src/main.zig:1111`; `applyFrame`, `src/main.zig:1599` |
| Tool call arguments | what the model wants done | `runTool`, `src/tool.zig:347` |
| Files in the working tree | the model's evidence, and its instructions | `toolRead`, `src/tool.zig:646`; system prompt at `src/main.zig:92` |

There is no network listener, no webhook, no message consumer, no scheduled job and no
IPC. The only outbound traffic is to the provider's base URL and to GitHub.

### Surface added by deployment

- The binary runs whatever is on `PATH`: `rg`, `ast-grep`, `git` and `/bin/sh`
  (`toolSearch`, `src/tool.zig:847`; `toolAst`, `src/tool.zig:873`; `toolGit`,
  `src/tool.zig:267`; `toolBash`, `src/tool.zig:471`). A hostile `PATH` entry is a
  hostile tool, and `bash` runs whatever name the model typed.
- The Harbor adapter runs the binary inside third-party task containers with the provider
  key in the container environment (`integrations/harbor/microagent_agent.py:255`,
  `api_key()` at `:116`), so the blast radius of a poisoned task is the container plus
  the key.
- CI builds release assets with the workflow's own token and publishes them with
  `gh release create` (`.github/workflows/release.yml:184`); that account is the trust
  anchor for every future `microagent update`.

## Trust boundaries

1. **Operator → agent.** The prompt is untrusted input, the same as any other. There is
   no validation point: `setPrompt` (`src/main.zig:728`) stores it and
   `openConversation` (`src/main.zig:3031`) appends it to the conversation verbatim.
2. **Repository content → model → host.** The most important boundary in the project.
   The model reads files, source and tests, and issues tool calls from what it read
   (`system_prompt`, `src/main.zig:92`). Nothing in the program separates "the model's
   own plan" from "an instruction the model found in a file"; the only thing that does is
   an instruction in the prompt itself.
3. **Provider → agent.** The streamed reply decides the next action. The validation point
   is `applyFrame` (`src/main.zig:1599`), which bounds the shape, not the intent.
4. **Agent → provider.** The key goes out in an `authorization` header
   (`src/main.zig:1131`) to whatever host `base_url` named, after the scheme check at
   `src/main.zig:246`.
5. **Model → filesystem and process.** `bash` runs `/bin/sh -c` with the model's string
   (`toolBash`, `src/tool.zig:471`); `read`, `write` and `edit` take any path
   (`toolRead` `src/tool.zig:646`, `toolWrite` `src/tool.zig:760`, `toolEdit`
   `src/tool.zig:818`).
6. **GitHub → host.** `update` downloads bytes and writes them over the running
   executable (`fetchAsset` `src/update.zig:504`, `replaceVerified` `src/update.zig:269`).
   Validation point: `decide` (`src/update.zig:254`).
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
| `~/.secrets/openrouter` | the same key, on disk | read in `resolveKey`, `src/main.zig:748` |
| Source tree and everything in it | `.env`, keys, unreleased work | read by `toolRead` (`src/tool.zig:646`, a credential refused at `src/tool.zig:607`), sent to the provider in the request body |
| Host compute and credentials | the shell inherits the environment less the provider key | `childEnviron`, `src/main.zig:776` |
| The binary itself | a replaced copy runs on every later invocation | replaced at `src/update.zig:269` |
| Run logs | working directory, model, token counts, finish reason | `~/.microagent/sessions`, capped at 200 records (`pruneSessions`, `src/session.zig:155`, `max_session_logs` `src/session.zig:125`) |
| Token spend | `--max-turns` bounds turns, not money | `max_turns_default`, `src/main.zig:50`; `default_max_tokens`, `src/main.zig:58` |

## Threats per boundary

### Operator → agent (STRIDE: spoofing, tampering, information disclosure)

- A prompt that names a hostile base URL or a hostile `--repo` steers the whole run.
  Both are operator inputs, so this is a threat only where an automated harness passes a
  task's text straight through (`bench/gauntlet.sh`).
- A prompt of unbounded length enters the conversation with no size cap
  (`setPrompt`, `src/main.zig:728`; appended at `openConversation`,
  `src/main.zig:3031`); the request body grows with it.

### Repository content → model → host (elevation of privilege, information disclosure)

- **Prompt injection through source files.** A file, a test fixture, an issue template or
  a `CLAUDE.md`/`AGENTS.md` in the tree can say "run `curl … | sh`". The model reads it
  with the ordinary `read` tool (`src/tool.zig:646`) and there is no instruction
  provenance, so the injected text is as trusted as the operator's prompt. The system
  prompt tells the model to treat tool output as data and to report such a file instead of
  acting on it (`src/main.zig:92`), which is a control a hostile file can argue with. This
  is the project's dominant risk and it is a design property, not a bug.
- The same path exfiltrates: the model can `read` a file and the file's bytes go into the
  next request body (`buildBody`, `src/main.zig:1084`).
- A hostile repository can also reach the terminal: bytes a tool echoes reach the gutter
  line (`toolCallLine`, `src/tool.zig:381`) and the provider's text reaches stdout, which
  is the answer the run was asked for and is deliberately left unescaped.

### Provider → agent (spoofing, tampering, denial of service)

- A hostile or coerced endpoint chooses every tool call. A single response can carry up to
  64 calls (`max_tool_calls`, `src/main.zig:60`, enforced by the index check at
  `src/main.zig:1563` and the index clamp in `applyCallDelta`) and they run as the
  operator.
- A tool call's name and argument object are the provider's own text and are parsed
  from bytes the model read out of the tree. They are fuzzed from the argument JSON
  to the gutter line and the limits it produces: the line stays one line inside its
  buffer with no byte a terminal acts on, and every count the model wrote is inside
  its ceiling before a subprocess starts (test at `src/tool.zig:1378`).
- A stream that never sends `[DONE]` grows the turn until the caps at
  `src/main.zig:69` and `:84` stop it, and the run ends as truncated
  (`truncatedNotice`, `src/main.zig:1345`, applied at `src/main.zig:1320`).
- An error body from the provider is printed on stderr through `terminalSafe`
  (`src/tool.zig:406`), so control bytes are scrubbed and it cannot repaint the
  terminal.
- Frames that are not JSON are counted and dropped (`applyFrame`, `src/main.zig:1620`);
  they are not fatal, and the run continues on a partial turn, with the count reported at
  `src/main.zig:1305`.

### Agent → provider (information disclosure, spoofing)

- The key is refused to any base URL that would put it on the wire in the clear:
  `baseUrlCarriesKey` (`src/main.zig:487`) requires `https`, or `http` on loopback, and
  `main` fails the run otherwise (`src/main.zig:246`). Loopback is judged by exact match
  in `isLoopbackHost` (`src/main.zig:495`), so `127.evil.com` and `localhost.evil.com`
  do not qualify; the policy is pinned by the test at `src/main.zig:2036`.
- What that check does not do is constrain *which* https host. `MICROAGENT_BASE_URL` or
  `--base-url` may name any host, and the key follows it there.
- `--api-key` puts the credential in `argv` (`resolveKey`, `src/main.zig:741`), which is
  world-readable in the process table for the life of the run.
- The conversation carries everything the model read, on every turn, by design
  (`buildBody`, `src/main.zig:1084`).
- Redirects are not followed: `.redirect_behavior = .unhandled` (`src/main.zig:1158`)
  makes a 3xx an error status, so a provider that answers with a `Location` cannot walk
  the API key off to whoever it names. The header carrying the key is the one the request
  writer reads, pinned by the test at `src/main.zig:3270`; it is not a separately
  privileged field, so the unhandled redirect is the whole of this control.
- A base URL carrying `user:password@` has that userinfo replaced wherever the URL is
  printed (`displayUrl`, `src/main.zig:527`; test at `src/main.zig:2064`).

### Model → filesystem and process (elevation of privilege, tampering, denial of service)

- `bash` is arbitrary command execution with the operator's identity and working
  directory (`toolBash`, `src/tool.zig:471`). The spawned shell inherits the environment
  less the four variables `resolveKey` reads (`childEnviron`, `src/main.zig:776`), so
  `bash env` and `bash printenv` cannot put the run's own key in the transcript. A
  command naming a credentials file is refused on the same name rule `read` applies
  (`credentialInCommand`, `src/tool.zig:461`, applied at `src/tool.zig:477`); that rule
  reads the command's words rather than a parsed shell, so a file reached through
  indirection is not caught.
- `read`, `write` and `edit` accept absolute paths and do not confine writes to the
  working tree (`src/tool.zig:646`, `src/tool.zig:760`, `src/tool.zig:818`).
- `ast` with `rewrite` set applies its replacement to every match
  (`toolAst`, `src/tool.zig:873`), so a single model turn can rewrite a whole file set.
- Bounded today: 60 s tool timeout (`tool_timeout_ms`, `src/tool.zig:34`), 120 s default
  and 600 s ceiling for `bash` (`src/tool.zig:41`, `src/tool.zig:39`, applied through
  `bashTimeoutMs` at `src/tool.zig:428` and `boundedMs` at `src/tool.zig:51`, and the
  budget's remaining time through `Budget.toolCeilingMs`, `src/main.zig:966`), captured
  output held at 96 KB and cut to the 24 KB the model reads (`max_tool_output`,
  `src/tool.zig:20`, `runCapped`, `src/tool.zig:922`), `--max-turns`
  (`src/main.zig:50`), and a wall-clock budget (`src/main.zig:939`).

### GitHub → host (spoofing, tampering, elevation of privilege)

- The release JSON is attacker-shaped: every field in it becomes a tag, an asset name or a
  URL the updater acts on (`parseRelease`, `src/update.zig:311`). It is fuzzed against
  exactly that (`fuzzRelease`, `src/update.zig:1520`; `fuzzSidecar`, `src/update.zig:1604`).
- The `--repo` the updater requests from is the caller's own text, and it is
  fuzzed from the command line to the URL it becomes: a repo no argument carried
  fails, a repo `validRepo` refuses never reaches a request, and one it accepts
  only ever names `api.github.com` (`releaseApiUrl`, `src/update.zig:162`; harness
  `fuzzUpdateArgs`, `src/update.zig:1081`).
- A body over the cap is refused while it streams, not after (`fetchInto`,
  `src/update.zig:437`, `Capped`); the API body is capped at 10 MB, the asset at 256 MB,
  the sidecar at 64 KB (`src/update.zig:21-23`).
- The sidecar is fetched from the same release as the asset, so the checksum proves the
  download was not corrupted in transit, not that the release was authorized. The trust
  anchor is the GitHub account and the TLS session, nothing more. There is no signature,
  no attestation and no pinned digest.
- The replacement follows a symlink to the real file (`replaceVerified`,
  `src/update.zig:269`), so a symlinked install under a path the operator does not own
  writes wherever the link points. The behavior is pinned by a test
  (`src/update.zig:1451`), so it is intended, not an accident.

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
| System prompt names tool output, file contents and command output as data, and tells the model to report a file that gives orders | prompt injection through a file, at the model rather than in the program | `system_prompt`, `src/main.zig:92` |
| `owner/name` validation before a URL exists | URL injection through `--repo` | `repoPartOk`, `src/update.zig:135`; `validRepo`, `src/update.zig:145`; `releaseApiUrl`, `src/update.zig:162` |
| Host allowlist: `https` on `github.com`, `*.github.com`, `*.githubusercontent.com`, no userinfo, checked on the page URL and on both asset URLs | asset and page download from a lookalike host | `hostTrusted`, `src/update.zig:168`; `trustedGithubUrl`, `src/update.zig:181`; applied at `src/update.zig:806` and inside `decide` at `src/update.zig:256` |
| `GITHUB_TOKEN` is presented only to `api.github.com`, and its prefix match is exact, so a lookalike host gets nothing | the token handed to the asset CDN or to `api.github.com.evil.com` | `bearerFor`, `src/update.zig:210`; applied at `src/update.zig:753` and `818`; tests at `src/update.zig:1220-1241` |
| sha256 sidecar verification before the verdict is `replaced` | corrupted or substituted download | `checksumMatches`, `src/update.zig:236`; `decide`, `src/update.zig:254` |
| Version comparison refuses a downgrade | installing an older build over a newer one | `compareVersions`, `src/update.zig:80`; `fetchesAsset`, `src/update.zig:229` |
| Atomic replace, only on `.replaced` | partial write, write on a refusal | `decide`, `src/update.zig:254`; `replaceVerified`, `src/update.zig:269` |
| The key is refused on a plaintext `http` base URL off loopback, every octet range-checked | the key crossing a network path in the clear, or to a name spelled like an address | `baseUrlCarriesKey`, `src/main.zig:487`; `isLoopbackHost`, `src/main.zig:495`; enforced at `src/main.zig:246`; test at `src/main.zig:2036` |
| Userinfo redacted from every printed URL | a password in the base URL copied into stderr | `displayUrl`, `src/main.zig:527`; test at `src/main.zig:2064` |
| Redirects unhandled | the key replayed to a host the provider names | `src/main.zig:1158`; test at `src/main.zig:3270` |
| Argument vectors instead of a shell for `search`, `ast`, `git` | shell injection through a pattern or a path | `toolSearch`, `src/tool.zig:847`; `toolAst`, `src/tool.zig:873`; `toolGit`, `src/tool.zig:267` |
| `--` separator and a `rev` that may not start with `-` | an option smuggled in as a path or a revision | `toolGit`, `src/tool.zig:273`, `src/tool.zig:303`; `toolSearch`, `src/tool.zig:866`; `toolAst`, `src/tool.zig:887` |
| Fixed git subcommands | `bash`-strength git, no writes through the `git` tool | `toolGit`, `src/tool.zig:280-300` |
| Every tool subprocess is its own group leader; the group is SIGKILLed and takes the terminal's interrupt with it | orphaned build trees holding resources, and a Ctrl+C that leaves a build writing files | `signalGroup`, `src/tool.zig:163`; `watchToolGroup`, `src/tool.zig:181`; `forwardInterruptsToToolGroup`, `src/tool.zig:188`; `runToolProcess`, `src/tool.zig:108` |
| Output, response, frame and config caps; the response cap covers the whole response, not each field | memory exhaustion from a tool, a stream or a file | `max_tool_output`, `src/tool.zig:20`; `max_response_bytes`, `src/main.zig:69`; `max_frame_bytes`, `src/main.zig:84`; `max_config_bytes`, `src/main.zig:86` |
| Tool-call index cap and a saturating cast | a provider asking for billions of slots, or a wrapped index on a 32-bit build | `max_tool_calls`, `src/main.zig:60`; check at `src/main.zig:1563` |
| `read` refuses a credentials file by name, extension or directory | a `.env`, a private key or a `~/.secrets` file put into the model context | `isCredentialPath`, `src/tool.zig:607`; tables at `src/tool.zig:511-524`; refusal text at `src/tool.zig:629` |
| `search` and `ast` skip the same files as traversal globs, `git` refuses one named as a path and excludes them from patches | a credential reaching the provider through a match or a patch | `credential_globs`, `src/tool.zig:584`; `toolGit`, `src/tool.zig:277` and `314`; test at `src/tool.zig:586` |
| `write` refuses a call with no `content` | a truncated or forgotten argument emptying a file | `toolWrite`, `src/tool.zig:760`; test at `src/tool.zig:1604` |
| `bash` timeout is capped at 600 s and clipped to the budget left | model-chosen output running with no deadline at all | `max_bash_timeout_ms`, `src/tool.zig:39`; `bashTimeoutMs`, `src/tool.zig:427`; `Budget.toolCeilingMs`, `src/main.zig:966`; test at `src/tool.zig:1479` |
| `max_tokens` on every request | one turn generating until the provider's own limit stopped it | `default_max_tokens`, `src/main.zig:58`; request body at `src/main.zig:1092` |
| Control bytes escaped in the gutter, scrubbed in error bodies, bounded through one helper | terminal escape injection from repo content and from a config key or a `--repo` value | `toolCallLine`, `src/tool.zig:381`; `terminalSafe`, `src/tool.zig:406`; `chat.safeText`, `src/chat.zig:262` |
| Non-JSON frames counted and reported; a stream without `[DONE]` fails the turn | a truncated answer read as a finished one | `applyFrame`, `src/main.zig:1620`; report at `src/main.zig:1305`; `truncatedNotice`, `src/main.zig:1345` |
| Retry with capped exponential backoff on weather-shaped statuses and on failures before the response head is readable; a failure after the head is not retried; a `Retry-After` longer than two minutes is clamped to two | a dropped connection or a rate limit ending the run; a re-sent turn billed twice | `streamChat` retry loop, `src/main.zig:1144-1201`; `retryableStatus` `src/main.zig:1931`, `worthAnotherAttempt` `src/main.zig:1966`, `waitBeforeRetry` `src/main.zig:1973`, `backoffMs` `src/main.zig:1986`, `max_attempts` `src/main.zig:1925`, `max_retry_after_ms` `src/main.zig:2003` |
| Session log created exclusively, both name shapes pruned at 200 records | one run erasing another's log, unbounded growth | `createSessionLog`, `src/session.zig:88`; `pruneSessions`, `src/session.zig:155`; `max_session_logs`, `src/session.zig:125` |
| Values validated where they are set | a mistyped level or ceiling reaching the wire as a 400 | `ceiling`, `src/main.zig:467`; `budgetSeconds`, `src/main.zig:541` |
| Fuzz corpora for the parsers that take untrusted bytes: the release body, the sidecar, the completion stream, the config file, both command lines, a JSON string and a tool call | malformed provider, release, config, command-line or tool-call input | `fuzzRelease` `src/update.zig:1520`, `fuzzSidecar` `src/update.zig:1604`, `fuzzUpdateArgs` `src/update.zig:1081`, `fuzzStream` `src/main.zig:3714`, `fuzzArgs` `src/main.zig:2242`, `fuzzToml` `src/style.zig:424`, `fuzzJsonString` `src/chat.zig:473`, tool-call fuzz at `src/tool.zig:1378` |

### Gaps, ranked by exploitability and impact

1. **No confinement on model-driven execution.** `bash`, `write`, `edit` and an `ast`
   rewrite run with full operator authority, and the instructions that trigger them can
   come from a file the run reads. The system prompt asks the model not to act on such a
   file (`src/main.zig:92`), which is the same trust the operator already placed in the
   prompt. The model, not the operator, is the last gate.
2. **The credential rule is a name rule, and `bash` matches it on words.** `read`
   refuses a credentials file, `search` and `ast` skip them, `git` refuses one as a path
   and `bash` refuses a command whose words name one, so none of the five can put a
   known `.env` or private key in the model context. Two ways around it remain. A
   credential under a name the tables do not carry is still read. And `credentialInCommand`
   (`src/tool.zig:461`) tokenizes the command rather than parsing a shell, so a command
   that assembles a path at run time reaches the file. The run's own key is the case
   that mattered most, and it is closed structurally rather than textually: no tool
   subprocess inherits it (`src/main.zig:776`).
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
   timestamp, no exit status and no file (`noteToolCall`, `src/tool.zig:376`); the session
   log records token counters, the working directory and the finish reason, never which
   commands ran (`writeRecord`, `src/session.zig:223`).
8. **`GITHUB_TOKEN` still reaches the asset host.** `bearerFor` narrows the token to
   `api.github.com` for the API and the sidecar, but the asset fetch is handed the raw
   bearer (`src/update.zig:813`). The host allowlist makes that host GitHub's, but the
   token's reach is wider than the release check needs.
9. **A symlinked install can point anywhere.** `replaceVerified` follows the link
   (`src/update.zig:269`); a link planted in a directory on the operator's `PATH`
   redirects the write.
10. **A config file can redirect the system prompt.** `MICROAGENT_CONFIG` prepends a
    reply-style ruleset to the system prompt (`loadStyle`, `src/main.zig:802`); it is
    operator-supplied and capped at 64 KB (`max_config_bytes`, `src/main.zig:86`), but
    nothing in it is sandboxed, and it reaches the provider on every turn like any other
    prompt text.

## Abuse cases

Each of these is a scenario, evidenced by the code path that enables it. None has been
attempted.

- **A poisoned test fixture.** A repository contains a fixture whose text tells the agent
  to run a command. The model reads it with `read` (`src/tool.zig:646`) and, with `bash`
  (`src/tool.zig:471`), the command runs as the operator. The agent has no way to
  distinguish file content from operator instruction; the prompt tells it to report such a
  file instead, which a sufficiently persuasive file can argue with.
- **A hostile endpoint.** With `--base-url` pointed at an `https` server the attacker
  controls, the key arrives in the `authorization` header (`src/main.zig:1131`) and the
  reply decides every subsequent tool call. The scheme check passes, because the attacker
  serves `https`.
- **A symlink on the update path.** A link named `microagent` earlier on `PATH` is
  followed at install time (`src/update.zig:269`), so `update` writes a verified binary to
  a location the operator did not intend.
- **Scraping through the harness.** `read` has no path restriction, so a run over a
  directory containing credentials reads them and, through the model, can send them off the
  machine. There is no per-run file budget either, only the 4 MB per read
  (`max_read_bytes`, `src/tool.zig:25`).
- **A runaway bill.** `--max-turns` at its ceiling and a conversation that grows to 400 KB
  before compaction (`conversation_soft_limit`, `src/main.zig:36`; `compactMessages`,
  `src/main.zig:1744`) cost real tokens, with `max_tokens` bounding each turn but nothing
  bounding the run.
- **A poisoned task container.** The Harbor adapter hands the provider key to every task
  container it starts (`integrations/harbor/microagent_agent.py:255`), so a task written
  by a third party inherits the key for the length of its run.

## Response readiness

Note only, and not built here.

- Tool activity is a single stderr line per call with no timestamps and no exit status
  (`noteToolCall`, `src/tool.zig:376`), and the session log keeps no record of it
  (`writeRecord`, `src/session.zig:223`). A post-incident reconstruction of what a run did
  has to come from the working tree, not from a log.
- There is no `SECURITY.md`, so no disclosure contact, no supported-versions statement
  (the policy is one line in `README.md` under Versioning and one in `CHANGELOG.md`) and
  no documented path from a reported vulnerability to a shipped fix. This document does
  not invent one.
- `CHANGELOG.md` records every change that alters what a run does, which is the closest
  thing to a public record of behavior changes.
