# Threat model

What can be attacked in microagent, from where, and what stands in the way. Every entry
below carries a file reference so the next pass can re-verify it against the code rather
than against this document.

Last reviewed: 2026-09-29, against `0.2.0` (`build.zig.zon`) and the `Unreleased` section
of `CHANGELOG.md`. Every line reference below was re-resolved against the current tree on
that date.

## Summary, risk-ranked

| # | Threat | Boundary | Exploitability | Impact | Control today |
| --- | --- | --- | --- | --- | --- |
| 1 | Repository content drives shell execution | repo → model → host | high: any content the model reads can carry an instruction | full compromise of the operator's account, its files and its keys | prompt wording only (`system_prompt`, `src/main.zig:98`); no mechanical control (gap 1) |
| 2 | The provider's reply drives shell execution | provider → host | medium: needs a hostile, coerced or MITM'd endpoint | same as 1 | redirect refused (`streamChat`, `src/main.zig:1410`), response caps, timeouts, `bash` timeout ceiling (`default_bash_timeout_ms`/`max_bash_timeout_ms`, `src/tool.zig:45`/`43`) |
| 3 | The API key is sent to the host the environment names | agent → provider | medium: any `https` host is accepted | provider account takeover, bill abuse | plaintext `http` refused off loopback (`baseUrlCarriesKey`, `src/main.zig:545`, enforced at `src/main.zig:252`) |
| 4 | A named CA bundle adds a trust anchor for every TLS connection the run makes | environment/argv → agent, agent → provider and GitHub | medium: needs a write to the environment, or a `--ca-bundle` on the command line | the API key to a machine-in-the-middle, and a release asset that hashes as published | additive to the system store, and a bundle that is unreadable or holds no certificate is refused (`loadCaBundle`, `src/net.zig:32`); no policy on what a bundle may add (gap 3) |
| 5 | Tools read and write outside the working tree | model → filesystem | high: `read`/`write`/`edit` take any path | read or overwrite `~/.ssh`, `~/.aws`, CI tokens | `read` refuses a credentials file (`isCredentialPath`, `src/tool.zig:660`); `write`/`edit` still take any path |
| 6 | Tool output carries credentials to the model and on to the provider | host → model → provider | low: a credential under a name the rules do not know, or reached through shell indirection | secret exfiltration through a routine run | `read` refuses, `search` and `ast` skip, `git` refuses by path, `bash` refuses a command naming one (`credential_globs`, `src/tool.zig:635`; the `ast` glob loop, `src/tool.zig:962`; `toolGit`, `src/tool.zig:320`; `credentialInCommand`, `src/tool.zig:511`); the run's own key is not in a tool's environment to print (`childEnviron`, `src/main.zig:856`) |
| 7 | A compromised release replaces the binary | GitHub → host | low: needs the release account or its token | persistent, silent code execution on every later run | sha256 sidecar, host allowlist (`checksumMatches`, `src/update.zig:246`; `hostTrusted`, `src/update.zig:178`) |
| 8 | The API key is visible in the process table | operator → host | low: needs a local reader | key theft by any other process or user on the box | none |
| 9 | A hostile or malformed provider response exhausts memory or CPU | provider → agent | medium | run killed, machine memory spent | per-response cap (`max_response_bytes`, `src/main.zig:75`), frame cap (`max_frame_bytes`, `src/main.zig:90`), timeouts, process-group kill |
| 10 | A hostile repository writes escape sequences to the operator's terminal | repo → terminal | high: any file the model echoes | terminal spoofing, clipboard tricks | control bytes escaped in the gutter (`toolCallLine` via `chat.safeText`, `src/tool.zig:431`/`446`, `src/chat.zig:347`) and scrubbed in error text (`terminalSafe`, `src/tool.zig:456`) |
| 11 | A hostile model result spends the operator's money | model → provider | medium: a runaway or looping run | unbounded bill on the provider account | per-request `max_tokens` (`src/main.zig:1338`), turn and wall-clock ceilings; no spend limit (gap 7) |

`microagent` is a local CLI with no listener, no server and no database. It holds no user
data of its own: what it exposes is the operator's own machine, and what an attacker wants
is the key, the source tree and the host. The one place it holds something worth stealing
on its own is the API key.

## Attack surface

### Entry points in the code

| Entry point | What arrives | Handled at |
| --- | --- | --- |
| Command line, agent mode | prompt, flags, api key in `argv` | `parseArgs`, `src/main.zig:733`; `main`, `src/main.zig:167`; the flag table at `src/main.zig:659` |
| `--ca-bundle <file>` | the PEM file whose certificates vouch for the provider and for GitHub | `net.caBundlePath`, `src/net.zig:95`; `loadCaBundle`, `src/net.zig:32`; applied at `src/main.zig:257` and `src/update.zig:873` |
| `--config <file>` | a TOML ruleset prepended to the system prompt | `styleConfigPath`, `src/main.zig:964`; `loadStyle`, `src/main.zig:882`; cap `max_config_bytes`, `src/main.zig:92` |
| Command line, `update` | `--check`, `--repo` | `parseArgs`, `src/update.zig:791`; `run`, `src/update.zig:821`; dispatched from `main` |
| `MICROAGENT_MODEL`, `MICROAGENT_BASE_URL`, `MICROAGENT_REASONING_EFFORT` | endpoint, model, response style | `envValue`, `src/main.zig:478` |
| `MICROAGENT_MAX_TURNS`, `MICROAGENT_MAX_TOKENS` | loop and response ceilings | `max_turns_default`, `src/main.zig:50`; `default_max_tokens`, `src/main.zig:64`; both through `ceiling`, `src/main.zig:525` |
| `MICROAGENT_API_KEY`, `OPENAI_API_KEY`, `OPENROUTER_API_KEY`, `DEEPSEEK_API_KEY` | provider credential | `key_vars`, `src/main.zig:840`; resolved at `resolveKey`, `src/main.zig:813` |
| `~/.secrets/openrouter` | provider credential, up to 4 KB | path built in `resolveKey`, `src/main.zig:821`; read by `readSecret`, `src/tool.zig:128`; cap `max_secret_bytes`, `src/tool.zig:31` |
| `MICROAGENT_CA_BUNDLE`, `SSL_CERT_FILE` | the trust anchors for the provider host and for GitHub | `caBundlePath`, `src/net.zig:95`, read at `src/main.zig:216`; loaded at `src/main.zig:257` and `src/update.zig:873` |
| `MICROAGENT_CONFIG`, `~/.microagent/config.toml` | reply-style levels, 64 KB cap | `styleConfigPath`, `src/main.zig:964`; `loadStyle`, `src/main.zig:882`; cap `max_config_bytes`, `src/main.zig:92` |
| `MICROAGENT_CAVEMAN`, `MICROAGENT_PONYTAIL` | reply-style levels, overriding the config file | `loadStyle`, `src/main.zig:882`; usage at `src/main.zig:352` |
| `MICROAGENT_BUDGET_SECONDS` | wall-clock ceiling on the run | `budgetSeconds`, `src/main.zig:599`; carried by `Budget`, `src/main.zig:1019` |
| `MICROAGENT_SESSION_DIR` | where the JSONL run log is written | `sessionDir`, `src/session.zig:27`; read at `src/main.zig:221` |
| `MDEBUG` | writes protocol notes and the resolved configuration to stderr, never the key | `debugEnabled`, `src/main.zig:491`; `traceConfig`, `src/main.zig:919` |
| `GITHUB_TOKEN` | credential, presented only to `api.github.com` | `githubBearer`, `src/update.zig:702`; narrowed by `bearerFor`, `src/update.zig:220`; applied at `src/update.zig:877` (API), `947` (asset), `952` (sidecar) |
| GitHub release JSON | tag, page URL, asset names, download URLs | `parseRelease`, `src/update.zig:325` |
| Downloaded asset and `.sha256` sidecar | bytes that become the running executable | fetched by `fetchAsset`/`fetchBody`, `src/update.zig:615`/`581`; installed by `replaceVerified`, `src/update.zig:283` |
| Streamed provider response (SSE) | model text and tool calls | `streamChat`, `src/main.zig:1366`; `applyFrame`, `src/main.zig:1908` |
| Tool call arguments | what the model wants done | `runTool`, `src/tool.zig:397` |
| Files in the working tree | the model's evidence, and its instructions | `toolRead`, `src/tool.zig:700`; system prompt at `src/main.zig:98` |

There is no network listener, no webhook, no message consumer, no scheduled job and no
IPC. The only outbound traffic is to the provider's base URL and to GitHub.

### Surface added by deployment

- The binary runs whatever is on `PATH`: `rg`, `ast-grep`, `git` and `/bin/sh`
  (`toolSearch`, `src/tool.zig:924`; `toolAst`, `src/tool.zig:950`; `toolGit`,
  `src/tool.zig:303`; `toolBash`, `src/tool.zig:521`). A hostile `PATH` entry is a
  hostile tool, and `bash` runs whatever name the model typed.
- The Harbor adapter runs the binary inside third-party task containers with the provider
  key in the container environment (`integrations/harbor/microagent_agent.py:295`,
  `api_key()` at `:123`), so the blast radius of a poisoned task is the container plus
  the key.
- CI builds release assets with the workflow's own token and publishes them with
  `gh release create` (`.github/workflows/release.yml:222`); that account is the trust
  anchor for every future `microagent update`.

## Trust boundaries

1. **Operator → agent.** The prompt is untrusted input, the same as any other. There is
   no validation point: `setPrompt` (`src/main.zig:800`) stores it and
   `openConversation` (`src/main.zig:3552`) appends it to the conversation verbatim.
2. **Repository content → model → host.** The most important boundary in the project.
   The model reads files, source and tests, and issues tool calls from what it read
   (`system_prompt`, `src/main.zig:98`). Nothing in the program separates "the model's
   own plan" from "an instruction the model found in a file"; the only thing that does is
   an instruction in the prompt itself.
3. **Provider → agent.** The streamed reply decides the next action. The validation point
   is `applyFrame` (`src/main.zig:1908`), which bounds the shape, not the intent.
4. **Agent → provider.** The key goes out in an `authorization` header
   (`src/main.zig:1359`) to whatever host `base_url` named, after the scheme check at
   `src/main.zig:252`.
5. **Model → filesystem and process.** `bash` runs `/bin/sh -c` with the model's string
   (`toolBash`, `src/tool.zig:521`); `read`, `write` and `edit` take any path
   (`toolRead` `src/tool.zig:700`, `toolWrite` `src/tool.zig:813`, `toolEdit`
   `src/tool.zig:871`).
6. **GitHub → host.** `update` downloads bytes and writes them over the running
   executable (`fetchAsset` `src/update.zig:615`, `replaceVerified` `src/update.zig:283`).
   Validation point: `decide` (`src/update.zig:268`).
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
| `GITHUB_TOKEN` | releases API access, and repository scope beyond it | environment, then an `Authorization` header on `api.github.com` only (`bearerFor`, `src/update.zig:220`) |
| `~/.secrets/openrouter` | the same key, on disk | read in `resolveKey`, `src/main.zig:813` |
| Source tree and everything in it | `.env`, keys, unreleased work | read by `toolRead` (`src/tool.zig:700`, a credential refused at `src/tool.zig:702`), sent to the provider in the request body |
| Host compute and credentials | the shell inherits the environment less the provider key | `childEnviron`, `src/main.zig:856` |
| The binary itself | a replaced copy runs on every later invocation | replaced at `src/update.zig:283` |
| Run logs | working directory, model, token counts, finish reason | `~/.microagent/sessions`, capped at 200 records (`pruneSessions`, `src/session.zig:228`, `max_session_logs` `src/session.zig:163`) |
| Token spend | `--max-turns` bounds turns, not money | `max_turns_default`, `src/main.zig:50`; `default_max_tokens`, `src/main.zig:64` |

## Threats per boundary

### Operator → agent (STRIDE: spoofing, tampering, information disclosure)

- A prompt that names a hostile base URL or a hostile `--repo` steers the whole run.
  Both are operator inputs, so this is a threat only where an automated harness passes a
  task's text straight through (`bench/gauntlet.sh`).
- A prompt of unbounded length enters the conversation with no size cap
  (`setPrompt`, `src/main.zig:800`; appended at `openConversation`,
  `src/main.zig:3552`); the request body grows with it.

### Repository content → model → host (elevation of privilege, information disclosure)

- **Prompt injection through source files.** A file, a test fixture, an issue template or
  a `CLAUDE.md`/`AGENTS.md` in the tree can say "run `curl … | sh`". The model reads it
  with the ordinary `read` tool (`src/tool.zig:700`) and there is no instruction
  provenance, so the injected text is as trusted as the operator's prompt. The system
  prompt tells the model to treat tool output as data and to report such a file instead of
  acting on it (`src/main.zig:98`), which is a control a hostile file can argue with. This
  is the project's dominant risk and it is a design property, not a bug.
- The same path exfiltrates: the model can `read` a file and the file's bytes go into the
  next request body (`buildBody`, `src/main.zig:1330`).
- A hostile repository can also reach the terminal: bytes a tool echoes reach the gutter
  line (`toolCallLine`, `src/tool.zig:431`) and the provider's text reaches stdout, which
  is the answer the run was asked for and is deliberately left unescaped.

### Provider → agent (spoofing, tampering, denial of service)

- A hostile or coerced endpoint chooses every tool call. A single response can carry up to
  64 calls (`max_tool_calls`, `src/main.zig:66`, enforced by the index check at
  `src/main.zig:1869` and the index clamp in `applyCallDelta`) and they run as the
  operator.
- A tool call's name and argument object are the provider's own text and are parsed
  from bytes the model read out of the tree. They are fuzzed from the argument JSON
  to the gutter line and the limits it produces: the line stays one line inside its
  buffer with no byte a terminal acts on, and every count the model wrote is inside
  its ceiling before a subprocess starts (`fuzzToolCall`, `src/tool.zig:1459`; test at
  `src/tool.zig:1334`).
- A stream that never sends `[DONE]` grows the turn until the caps at
  `src/main.zig:75` and `:90` stop it, and the run ends as truncated
  (`truncatedNotice`, `src/main.zig:1630`, applied at `src/main.zig:1603`).
- An error body from the provider is printed on stderr through `terminalSafe`
  (`src/tool.zig:456`), so control bytes are scrubbed and it cannot repaint the
  terminal.
- Frames that are not JSON are counted and dropped (`applyFrame`, `src/main.zig:1908`;
  the counter at `src/main.zig:1929`); they are not fatal, and the run continues on a
  partial turn, with the count reported at `src/main.zig:1580`.

### Agent → provider (information disclosure, spoofing)

- The key is refused to any base URL that would put it on the wire in the clear:
  `baseUrlCarriesKey` (`src/main.zig:545`) requires `https`, or `http` on loopback, and
  `main` fails the run otherwise (`src/main.zig:252`). Loopback is judged by exact match
  in `isLoopbackHost` (`src/main.zig:553`), so `127.evil.com` and `localhost.evil.com`
  do not qualify; the policy is pinned by the test at `src/main.zig:2464`.
- What that check does not do is constrain *which* https host. `MICROAGENT_BASE_URL` or
  `--base-url` may name any host, and the key follows it there.
- `--api-key` puts the credential in `argv` (`resolveKey`, `src/main.zig:813`), which is
  world-readable in the process table for the life of the run.
- The conversation carries everything the model read, on every turn, by design
  (`buildBody`, `src/main.zig:1330`).
- Redirects are not followed: `.redirect_behavior = .unhandled` (`src/main.zig:1410`)
  makes a 3xx an error status, so a provider that answers with a `Location` cannot walk
  the API key off to whoever it names. The header carrying the key is the one the request
  writer reads, pinned by the test at `src/main.zig:3791`; it is not a separately
  privileged field, so the unhandled redirect is the whole of this control.
- A base URL carrying `user:password@` has that userinfo replaced wherever the URL is
  printed (`displayUrl`, `src/main.zig:585`; test at `src/main.zig:2492`).
- `MICROAGENT_CA_BUNDLE`, `SSL_CERT_FILE` and `--ca-bundle` decide who vouches for that
  host: `loadCaBundle` (`src/net.zig:32`) adds the named file's certificates to the
  client's store, and the system store is still scanned, so a bundle naming one more
  root is enough to terminate the connection that carries the key. The path is
  operator or environment input, and nothing constrains what the file may contain. What
  is refused is a bundle that cannot be read or that holds no certificate: an empty
  trust store is reported and the system store is used instead. The same path governs
  `update` (`src/update.zig:873`), where it covers the release download.

### Model → filesystem and process (elevation of privilege, tampering, denial of service)

- `bash` is arbitrary command execution with the operator's identity and working
  directory (`toolBash`, `src/tool.zig:521`). The spawned shell inherits the environment
  less the four variables `resolveKey` reads (`childEnviron`, `src/main.zig:856`), so
  `bash env` and `bash printenv` cannot put the run's own key in the transcript. A
  command naming a credentials file is refused on the same name rule `read` applies
  (`credentialInCommand`, `src/tool.zig:511`, applied at `src/tool.zig:528`); that rule
  reads the command's words rather than a parsed shell, so a file reached through
  indirection is not caught.
- `read`, `write` and `edit` accept absolute paths and do not confine writes to the
  working tree (`src/tool.zig:700`, `src/tool.zig:813`, `src/tool.zig:871`).
- `ast` with `rewrite` set applies its replacement to every match
  (`toolAst`, `src/tool.zig:950`), so a single model turn can rewrite a whole file set.
- Bounded today: 60 s tool timeout (`tool_timeout_ms`, `src/tool.zig:38`), 120 s default
  and 600 s ceiling for `bash` (`src/tool.zig:45`, `src/tool.zig:43`, applied through
  `bashTimeoutMs` at `src/tool.zig:477` and `boundedMs` at `src/tool.zig:55`, and the
  budget's remaining time through `Budget.toolCeilingMs`, `src/main.zig:1053`), captured
  output held at 96 KB and cut to the 24 KB the model reads (`max_tool_output`,
  `src/tool.zig:22`, `runCapped`, `src/tool.zig:999`), `--max-turns`
  (`src/main.zig:50`), and a wall-clock budget (`src/main.zig:1019`).

### GitHub → host (spoofing, tampering, elevation of privilege)

- The release JSON is attacker-shaped: every field in it becomes a tag, an asset name or a
  URL the updater acts on (`parseRelease`, `src/update.zig:325`). It is fuzzed against
  exactly that (`fuzzRelease`, `src/update.zig:1744`; `fuzzSidecar`, `src/update.zig:1838`).
- The `--repo` the updater requests from is the caller's own text, and it is
  fuzzed from the command line to the URL it becomes: a repo no argument carried
  fails, a repo `validRepo` refuses never reaches a request, and one it accepts
  only ever names `api.github.com` (`releaseApiUrl`, `src/update.zig:168`; harness
  `fuzzUpdateArgs`, `src/update.zig:1278`).
- A body over the cap is refused while it streams, not after (`fetchInto`,
  `src/update.zig:469`, against `Capped` at `src/update.zig:384`); the API body is capped
  at 10 MB, the asset at 256 MB, the sidecar at 64 KB (`src/update.zig:21-23`).
- `GITHUB_TOKEN` is narrowed to the releases API before any request carries it:
  `bearerFor` (`src/update.zig:220`) returns the token only for a URL under
  `https://api.github.com/`, and returns null for the asset and the sidecar, which
  GitHub serves anonymously (`src/update.zig:947`, `952`). The grant is therefore as wide
  as the one request that needs it, not as wide as the host allowlist. What remains: a
  repository-scoped token is still presented in full to that one API, so a redirect or
  error on the releases API is the only place it can leak, and the unhandled redirect is
  the control there.
- The sidecar is fetched from the same release as the asset, so the checksum proves the
  download was not corrupted in transit, not that the release was authorized. The trust
  anchor is the GitHub account and the TLS session, nothing more. There is no signature,
  no attestation and no pinned digest.
- A CA bundle named by the environment or `--ca-bundle` is added to the trust store the
  download is verified against (`loadCaBundle`, `src/net.zig:32`, called at
  `src/update.zig:873`), so a bundle carrying one attacker-issued root substitutes the
  asset and the sidecar together and the checksum still matches. The host allowlist does
  not help: both URLs are on a GitHub host, the requests are addressed there, and the
  certificate presented is one the client was told to accept.
- The replacement follows a symlink to the real file (`replaceVerified`,
  `src/update.zig:283`), so a symlinked install under a path the operator does not own
  writes wherever the link points. The behavior is pinned by a test
  (`src/update.zig:1674`), so it is intended, not an accident.

### Classes this tree has already fixed

`CHANGELOG.md` records the same handful recurring: base-URL credentials printed unredacted
into the run's own error lines, a control character in a tool argument repainting the
terminal, a tool result or assistant text breaking the JSON of the next request, a
credential reaching the provider through a tool result, a repository-scoped token handed
to the asset host, and memory held for the length of a stream. Each has a control named
above; a regression in any of them is the same bug returning.

## Mitigations in the code

| Control | Covers | Where |
| --- | --- | --- |
| System prompt names tool output, file contents and command output as data, and tells the model to report a file that gives orders | prompt injection through a file, at the model rather than in the program | `system_prompt`, `src/main.zig:98` |
| `owner/name` validation before a URL exists | URL injection through `--repo` | `repoPartOk`, `src/update.zig:141`; `validRepo`, `src/update.zig:151`; `releaseApiUrl`, `src/update.zig:168` |
| Host allowlist: `https` on `github.com`, `*.github.com`, `*.githubusercontent.com`, no userinfo, checked on the page URL and on both asset URLs | asset and page download from a lookalike host | `hostTrusted`, `src/update.zig:178`; `trustedGithubUrl`, `src/update.zig:191`; applied at `src/update.zig:940` and inside `decide` at `src/update.zig:271` |
| `GITHUB_TOKEN` is presented only to `https://api.github.com/`, prefix-compared octet by octet, so a lookalike host, a userinfo URL and a path carrying the API name all get nothing; the asset and the sidecar go out unauthenticated | a repository-scoped token handed to the asset CDN, to `api.github.com.evil.com`, or to a path that merely contains the API name | `bearerFor`, `src/update.zig:220`; applied at `src/update.zig:877`, `947`, `952`; tests at `src/update.zig:1403` |
| A CA bundle that cannot be read, or that holds no certificate, is refused and the system store is used instead | a bundle silently emptying the trust store, so every request fails as if the machine shipped no certificates | `loadCaBundle`, `src/net.zig:32` |
| sha256 sidecar verification before the verdict is `replaced` | corrupted or substituted download | `checksumMatches`, `src/update.zig:246`; `decide`, `src/update.zig:268` |
| Version comparison refuses a downgrade | installing an older build over a newer one | `compareVersions`, `src/update.zig:86`; `fetchesAsset`, `src/update.zig:239` |
| Atomic replace, only on `.replaced` | partial write, write on a refusal | `decide`, `src/update.zig:268`; `replaceVerified`, `src/update.zig:283` |
| The key is refused on a plaintext `http` base URL off loopback, every octet range-checked | the key crossing a network path in the clear, or to a name spelled like an address | `baseUrlCarriesKey`, `src/main.zig:545`; `isLoopbackHost`, `src/main.zig:553`; enforced at `src/main.zig:252`; test at `src/main.zig:2464` |
| Userinfo redacted from every printed URL | a password in the base URL copied into stderr | `displayUrl`, `src/main.zig:585`; test at `src/main.zig:2492` |
| Redirects unhandled | the key replayed to a host the provider names | `src/main.zig:1410`; test at `src/main.zig:3791` |
| Argument vectors instead of a shell for `search`, `ast`, `git` | shell injection through a pattern or a path | `toolSearch`, `src/tool.zig:924`; `toolAst`, `src/tool.zig:950`; `toolGit`, `src/tool.zig:303` |
| `--` separator and a `rev` that may not start with `-` | an option smuggled in as a path or a revision | `toolGit`, `src/tool.zig:309`, `src/tool.zig:353`; `toolSearch`, `src/tool.zig:943`; `toolAst`, `src/tool.zig:964` |
| Fixed git subcommands | `bash`-strength git, no writes through the `git` tool | `toolGit`, `src/tool.zig:331-350` |
| Every tool subprocess is its own group leader; the group is SIGKILLed and takes the terminal's interrupt with it | orphaned build trees holding resources, and a Ctrl+C that leaves a build writing files | `signalGroup`, `src/tool.zig:198`; `watchToolGroup`, `src/tool.zig:216`; `forwardInterruptsToToolGroup`, `src/tool.zig:225`; `runToolProcess`, `src/tool.zig:143` |
| Output, response, frame and config caps; the response cap covers the whole response, not each field | memory exhaustion from a tool, a stream or a file | `max_tool_output`, `src/tool.zig:22`; `max_response_bytes`, `src/main.zig:75`; `max_frame_bytes`, `src/main.zig:90`; `max_config_bytes`, `src/main.zig:92` |
| Tool-call index cap and a saturating cast | a provider asking for billions of slots, or a wrapped index on a 32-bit build | `max_tool_calls`, `src/main.zig:66`; check at `src/main.zig:1869` |
| `read` refuses a credentials file by name, extension or directory | a `.env`, a private key or a `~/.secrets` file put into the model context | `isCredentialPath`, `src/tool.zig:660`; tables at `src/tool.zig:561-574`; refusal text at `src/tool.zig:682` |
| `search` and `ast` skip the same files as traversal globs, `git` refuses one named as a path and excludes them from patches | a credential reaching the provider through a match or a patch | `credential_globs`, `src/tool.zig:635`; `toolGit`, `src/tool.zig:320` and `327`; test at `src/tool.zig:637` |
| `write` refuses a call with no `content` | a truncated or forgotten argument emptying a file | `toolWrite`, `src/tool.zig:813`; test at `src/tool.zig:1681` |
| `bash` timeout is capped at 600 s and clipped to the budget left | model-chosen output running with no deadline at all | `max_bash_timeout_ms`, `src/tool.zig:43`; `bashTimeoutMs`, `src/tool.zig:477`; `Budget.toolCeilingMs`, `src/main.zig:1053`; test at `src/tool.zig:1556` |
| `max_tokens` on every request | one turn generating until the provider's own limit stopped it | `default_max_tokens`, `src/main.zig:64`; request body at `src/main.zig:1338` |
| Control bytes escaped in the gutter, scrubbed in error bodies, bounded through one helper | terminal escape injection from repo content, from a command-line argument, and from a config key or a `--repo` value | `toolCallLine`, `src/tool.zig:431`; `terminalSafe`, `src/tool.zig:456`; `chat.safeText`, `src/chat.zig:347`; `clip`, `src/main.zig:626` and `quoteUntrusted`, `src/update.zig:38` |
| Non-JSON frames counted and reported; a stream without `[DONE]` fails the turn | a truncated answer read as a finished one | `applyFrame`, `src/main.zig:1908`, counter at `src/main.zig:1929`; report at `src/main.zig:1580`; `truncatedNotice`, `src/main.zig:1630` |
| Retry with capped exponential backoff on weather-shaped statuses and on failures before the response head is readable; a failure after the head is not retried; a `Retry-After` longer than two minutes is clamped to two | a dropped connection or a rate limit ending the run; a re-sent turn billed twice | `streamChat` retry loop, `src/main.zig:1396-1478`; `retryableStatus` `src/main.zig:2246`, `worthAnotherAttempt` `src/main.zig:2273`, `waitBeforeRetry` `src/main.zig:2285`, `backoffMs` `src/main.zig:2313`, `max_attempts` `src/main.zig:2237`, `max_retry_after_ms` `src/main.zig:2326` |
| Session log created exclusively; the walk counts every log it finds, orders them by the stamp in the name and deletes the oldest past 200 by the path relative to the store root | one run erasing another's log, unbounded growth, and a log nested below the root counted toward the cap while nothing is deleted for it | `createSessionLog`, `src/session.zig:107`; `pruneSessions`, `src/session.zig:228`; `max_session_logs`, `src/session.zig:163` |
| Values validated where they are set | a mistyped level or ceiling reaching the wire as a 400 | `ceiling`, `src/main.zig:525`; `budgetSeconds`, `src/main.zig:599` |
| Fuzz corpora for the parsers that take untrusted bytes: the release body, the sidecar, the completion stream, the config file, both command lines, a JSON string, a tool call, a quoted value and a provider error body | malformed provider, release, config, command-line, tool-call or terminal-facing input | `fuzzRelease` `src/update.zig:1744`, `fuzzSidecar` `src/update.zig:1838`, `fuzzUpdateArgs` `src/update.zig:1278`, `fuzzStream` `src/main.zig:4461`, `fuzzArgs` `src/main.zig:2711`, `fuzzToml` `src/style.zig:460`, `fuzzJsonString` `src/chat.zig:691`, tool-call fuzz at `src/tool.zig:1459`, `fuzzSafeText` `src/chat.zig:585`, `fuzzTerminalSafe` `src/tool.zig:1797` |

### Gaps, ranked by exploitability and impact

1. **No confinement on model-driven execution.** `bash`, `write`, `edit` and an `ast`
   rewrite run with full operator authority, and the instructions that trigger them can
   come from a file the run reads. The system prompt asks the model not to act on such a
   file (`src/main.zig:98`), which is the same trust the operator already placed in the
   prompt. The model, not the operator, is the last gate.
2. **The credential rule is a name rule, and `bash` matches it on words.** `read`
   refuses a credentials file, `search` and `ast` skip them, `git` refuses one as a path
   and `bash` refuses a command whose words name one, so none of the five can put a
   known `.env` or private key in the model context. Two ways around it remain. A
   credential under a name the tables do not carry is still read. And `credentialInCommand`
   (`src/tool.zig:511`) tokenizes the command rather than parsing a shell, so a command
   that assembles a path at run time reaches the file. The run's own key is the case
   that mattered most, and it is closed structurally rather than textually: no tool
   subprocess inherits it (`src/main.zig:856`).
3. **A named CA bundle is trusted without a policy.** `MICROAGENT_CA_BUNDLE`,
   `SSL_CERT_FILE` and `--ca-bundle` add whatever the file holds to the trust store of the
   provider connection and of the release download (`loadCaBundle`, `src/net.zig:32`;
   `src/main.zig:257`; `src/update.zig:873`). A bundle naming one attacker-issued root is a
   machine in the middle for both, and the sha256 sidecar it serves hashes as published, so
   the updater installs what it was handed. The system store is still scanned, which makes
   the added root additional rather than a replacement, and that is the whole of the check.
4. **No host policy on `base_url`, only a scheme policy.** The key never goes out over
   plaintext `http` off loopback, but `MICROAGENT_BASE_URL` or `--base-url` may name any
   `https` host and the key follows it. A poisoned environment variable turns a review run
   into a key handoff to whoever answers on that name.
5. **The api key is accepted on the command line.** It is visible in the process table and
   in shell history; the README's first example uses the environment, and the flag cannot
   be made to match that.
6. **The release checksum is self-attesting.** A compromised release account, or a token
   with write access to the repository, replaces the asset and the sidecar together, and
   `update` installs it. The token is now narrowed to the one API that needs it, so this
   gap is the release account alone.
7. **No cost ceiling.** `--max-turns`, `--max-tokens` and `--budget` bound tokens per
   turn, turns and time; nothing bounds what a whole run costs.
8. **No audit trail beyond the gutter line.** Tool calls go to stderr as one line with no
   timestamp, no exit status and no file (`noteToolCall`, `src/tool.zig:426`); the session
   log records token counters, the working directory and the finish reason, never which
   commands ran (`writeRecord`, `src/session.zig:319`).
9. **A symlinked install can point anywhere.** `replaceVerified` follows the link
   (`src/update.zig:283`); a link planted in a directory on the operator's `PATH`
   redirects the write.
10. **A config file can redirect the system prompt.** `MICROAGENT_CONFIG` prepends a
   reply-style ruleset to the system prompt (`loadStyle`, `src/main.zig:882`); it is
   operator-supplied and capped at 64 KB (`max_config_bytes`, `src/main.zig:92`), but
   nothing in it is sandboxed, and it reaches the provider on every turn like any other
   prompt text.

## Abuse cases

Each of these is a scenario, evidenced by the code path that enables it. None has been
attempted.

- **A poisoned test fixture.** A repository contains a fixture whose text tells the agent
  to run a command. The model reads it with `read` (`src/tool.zig:700`) and, with `bash`
  (`src/tool.zig:521`), the command runs as the operator. The agent has no way to
  distinguish file content from operator instruction; the prompt tells it to report such a
  file instead, which a sufficiently persuasive file can argue with.
- **A hostile endpoint.** With `--base-url` pointed at an `https` server the attacker
  controls, the key arrives in the `authorization` header (`src/main.zig:1359`) and the
  reply decides every subsequent tool call. The scheme check passes, because the attacker
  serves `https`.
- **A symlink on the update path.** A link named `microagent` earlier on `PATH` is
  followed at install time (`src/update.zig:283`), so `update` writes a verified binary to
  a location the operator did not intend.
- **Scraping through the harness.** `read` has no path restriction, so a run over a
  directory containing credentials reads them and, through the model, can send them off the
  machine. There is no per-run file budget either, only the 4 MB per read
  (`max_read_bytes`, `src/tool.zig:27`).
- **A runaway bill.** `--max-turns` at its ceiling and a conversation that grows to 400 KB
  before compaction (`conversation_soft_limit`, `src/main.zig:36`; `compactMessages`,
  `src/main.zig:2053`) cost real tokens, with `max_tokens` bounding each turn but nothing
  bounding the run.
- **A trust anchor from the environment.** A run started with a `MICROAGENT_CA_BUNDLE`
  pointing at a file the attacker supplied terminates both connections the run makes: the
  provider request that carries the key (`src/main.zig:257`) and the release download
  `update` performs (`src/update.zig:873`). Nothing in the path checks what the file
  certifies, so a certificate naming the attacker's host is enough.
- **A poisoned task container.** The Harbor adapter hands the provider key to every task
  container it starts (`integrations/harbor/microagent_agent.py:295`), so a task written
  by a third party inherits the key for the length of its run.

## Response readiness

Note only, and not built here.

- Tool activity is a single stderr line per call with no timestamps and no exit status
  (`noteToolCall`, `src/tool.zig:426`), and the session log keeps no record of it
  (`writeRecord`, `src/session.zig:319`). A post-incident reconstruction of what a run did
  has to come from the working tree, not from a log.
- There is no `SECURITY.md`. The README's `Security` section (`README.md:360`) points here
  and makes no claim this document contradicts, and the two supported-versions statements
  agree with each other and with the release workflow: only the latest release is
  supported, with no backport window (`README.md:275`, `CHANGELOG.md:11`). There is no
  disclosure contact and no documented path from a reported vulnerability to a shipped
  fix, and this document does not invent one.
- `CHANGELOG.md` records every change that alters what a run does, which is the closest
  thing to a public record of behavior changes.
