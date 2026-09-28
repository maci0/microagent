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
| 1 | Repository content drives shell execution | repo → model → host | high: any content the model reads can carry an instruction | full compromise of the operator's account, its files and its keys | prompt wording only (`system_prompt`, `src/main.zig:110`); no mechanical control (gap 1) |
| 2 | The provider's reply drives shell execution | provider → host | medium: needs a hostile, coerced or MITM'd endpoint | same as 1 | redirect refused (`streamChat`, `src/main.zig:1609`), response caps, timeouts, `bash` timeout ceiling (`default_bash_timeout_ms`/`max_bash_timeout_ms`, `src/tool.zig:56`/`54`) |
| 3 | The API key is sent to the host the environment names | agent → provider | medium: any `https` host is accepted | provider account takeover, bill abuse | plaintext `http` refused off loopback (`baseUrlCarriesKey`, `src/main.zig:579`, enforced at `src/main.zig:275`) |
| 4 | A named CA bundle adds a trust anchor for every TLS connection the run makes | environment/argv → agent, agent → provider and GitHub | medium: needs a write to the environment, or a `--ca-bundle` on the command line | the API key to a machine-in-the-middle, and a release asset that hashes as published | additive to the system store, and a bundle that is unreadable or holds no certificate is refused (`loadCaBundle`, `src/net.zig:38`); no policy on what a bundle may add (gap 3) |
| 5 | Tools read and write outside the working tree | model → filesystem | high: `read`/`write`/`edit` take any path | overwrite `~/.ssh/authorized_keys`, a shell rc file, any file the operator can write | credential paths refused by name (`isCredentialPath`, `src/tool.zig:742`, applied at `742`, `861`, `924`); no confinement to the tree, so any other path is open (gap 5) |
| 6 | Tool output carries credentials to the model and on to the provider | host → model → provider | low: a credential under a name the rules do not know, or reached through shell indirection | secret exfiltration through a routine run | all six tools refuse or exclude a known credential name (`credential_globs`, `src/tool.zig:698`; `credentialInCommand`, `src/tool.zig:549`; `gitPathspecs`, `src/tool.zig:405`); the run's own keys are not in a tool's environment to print (`childEnviron`, `src/main.zig:972`) |
| 7 | A compromised release replaces the binary | GitHub → host | low: needs the release account or its token | persistent, silent code execution on every later run | sha256 sidecar, host allowlist (`checksumMatches`, `src/update.zig:247`; `hostTrusted`, `src/update.zig:179`) |
| 8 | The API key is visible in the process table | operator → host | low: needs a local reader | key theft by any other process or user on the box | none |
| 9 | A hostile or malformed provider response exhausts memory or CPU | provider → agent | medium | run killed, machine memory spent | per-response cap (`max_response_bytes`, `src/main.zig:87`), frame cap (`max_frame_bytes`, `src/main.zig:102`), error-body cap (`max_error_body_bytes`, `src/main.zig:108`), timeouts, process-group kill |
| 10 | A hostile repository writes escape sequences to the operator's terminal | repo → terminal | high: any file the model echoes | terminal spoofing, clipboard tricks | control bytes escaped in the gutter (`toolCallLine` via `chat.safeText`, `src/tool.zig:467`, `src/chat.zig:414`) and scrubbed in error text (`terminalSafe`, `src/tool.zig:494`) |
| 11 | A hostile model result spends the operator's money | model → provider | medium: a runaway or looping run | unbounded bill on the provider account | per-request `max_tokens` (`buildBody`, `src/main.zig:1568`), turn and wall-clock ceilings, and an opt-in run-wide spend ceiling (`--max-spend-tokens`, `spendCeilingReached`, `src/main.zig:1270`); nothing bounds the spend of a run that did not set one (gap 8) |

`microagent` is a local CLI with no listener, no server and no database. It holds no user
data of its own: what it exposes is the operator's own machine, and what an attacker wants
is the key, the source tree and the host. The one place it holds something worth stealing
on its own is the API key.

## Attack surface

### Entry points in the code

| Entry point | What arrives | Handled at |
| --- | --- | --- |
| Command line, agent mode | prompt, flags, api key in `argv` | `parseArgs`, `src/main.zig:785`; `main`, `src/main.zig:186`; the flag table at `src/main.zig:707` |
| `--ca-bundle <file>` | the PEM file whose certificates vouch for the provider and for GitHub | `net.caBundlePath`, `src/net.zig:103`; `loadCaBundle`, `src/net.zig:38`; applied at `src/main.zig:280` and `src/update.zig:903` |
| `--config <file>` | a TOML ruleset prepended to the system prompt | `styleConfigPath`, `src/main.zig:1108`; `loadStyle`, `src/main.zig:1003`; cap `max_config_bytes`, `src/main.zig:104` |
| Command line, `update` | `--check`, `--repo` | `parseArgs`, `src/update.zig:819`; `run`, `src/update.zig:856`; dispatched from `main` at `src/main.zig:186` |
| `MICROAGENT_MODEL`, `MICROAGENT_BASE_URL`, `MICROAGENT_REASONING_EFFORT` | endpoint, model, response style | `envValue`, `src/main.zig:512`; read at `src/main.zig:221-233` |
| `MICROAGENT_MAX_TURNS`, `MICROAGENT_MAX_TOKENS` | loop and response ceilings | `max_turns_default`, `src/main.zig:62`; `default_max_tokens`, `src/main.zig:76`; both through `ceiling`, `src/main.zig:559` |
| `MICROAGENT_API_KEY`, `OPENAI_API_KEY`, `OPENROUTER_API_KEY`, `DEEPSEEK_API_KEY` | provider credential | `key_vars`, `src/main.zig:943`; resolved at `resolveKey`, `src/main.zig:900` |
| `~/.secrets/openrouter` | provider credential, up to 4 KB | path built in `resolveKey`, `src/main.zig:900`; read by `readSecret`, `src/tool.zig:141`; cap `max_secret_bytes`, `src/tool.zig:31` |
| `MICROAGENT_CA_BUNDLE`, `SSL_CERT_FILE` | the trust anchors for the provider host and for GitHub | `caBundlePath`, `src/net.zig:104`, read at `src/main.zig:235`; loaded at `src/main.zig:280` and `src/update.zig:903` |
| `MICROAGENT_CONFIG`, `~/.microagent/config.toml` | reply-style levels, 64 KB cap | `styleConfigPath`, `src/main.zig:1108`; `loadStyle`, `src/main.zig:1003`; cap `max_config_bytes`, `src/main.zig:104` |
| `MICROAGENT_CAVEMAN`, `MICROAGENT_PONYTAIL` | reply-style levels, overriding the config file | `loadStyle`, `src/main.zig:1003`; read at `src/main.zig:1003` |
| `MICROAGENT_BUDGET_SECONDS`, `--budget` | wall-clock ceiling on the run, suspended time included | `optionalCeiling`, `src/main.zig:648`; carried by `Budget`, `src/main.zig:1163` |
| `MICROAGENT_MAX_SPEND_TOKENS`, `--max-spend-tokens <n>` | run-wide token ceiling, counted before each turn | `optionalCeiling`, `src/main.zig:648`; read at `src/main.zig:242`; enforced at `src/main.zig:1352` |
| `MICROAGENT_SESSION_DIR` | where the JSONL run log is written | `sessionDir`, `src/session.zig:27`; read at `src/main.zig:244` |
| `MDEBUG` | writes protocol notes and the resolved configuration to stderr, never a key | `debugEnabled`, `src/main.zig:525`; `traceConfig`, `src/main.zig:1054` |
| `GITHUB_TOKEN` | credential, presented only to `api.github.com`, and never to a tool subprocess | `githubBearer`, `src/update.zig:730`; narrowed by `bearerFor`, `src/update.zig:221`; applied at `src/update.zig:912` (API), `990` (sidecar), `992` (asset) |
| GitHub release JSON | tag, page URL, asset names, download URLs | `parseRelease`, `src/update.zig:327` |
| Downloaded asset and `.sha256` sidecar | bytes that become the running executable | fetched by `fetchAsset`/`fetchBody`, `src/update.zig:639`/`605`; installed by `replaceVerified`, `src/update.zig:284` |
| Streamed provider response (SSE) | model text and tool calls | `streamChat`, `src/main.zig:1609`; `applyFrame`, `src/main.zig:2314` |
| Tool call arguments | what the model wants done | `runTool`, `src/tool.zig:433` |
| Files in the working tree | the model's evidence, and its instructions | `toolRead`, `src/tool.zig:793`; system prompt at `src/main.zig:110` |

There is no network listener, no webhook, no message consumer, no scheduled job and no
IPC. The only outbound traffic is to the provider's base URL and to GitHub.

### Surface added by deployment

- The binary runs whatever is on `PATH`: `rg`, `ast-grep`, `git` and `/bin/sh`
  (`toolSearch`, `src/tool.zig:1036`; `toolAst`, `src/tool.zig:1069`; `toolGit`,
  `src/tool.zig:298`; `toolBash`, `src/tool.zig:559`). A hostile `PATH` entry is a
  hostile tool, and `bash` runs whatever name the model typed.
- The Harbor adapter runs the binary inside third-party task containers with the provider
  key in the container environment (`integrations/harbor/microagent_agent.py:410`,
  `api_key()` at `:136`), so the blast radius of a poisoned task is the container plus
  the key. The endpoint is checked at the command line before a container starts
  (`base_url`, `integrations/harbor/microagent_agent.py:190`): a `MICROAGENT_BASE_URL` with
  no scheme, or a plaintext one that is not loopback, is refused there rather than by the
  binary inside the container, where the key has already been handed over.
- CI builds release assets with the workflow's own token and publishes them with
  `gh release create` (`.github/workflows/release.yml:222`); that account is the trust
  anchor for every future `microagent update`.

## Trust boundaries

1. **Operator → agent.** The prompt is untrusted input, the same as any other. There is
   no validation point: `setPrompt` (`src/main.zig:887`) stores it and
   `openConversation` (`src/main.zig:4246`) appends it to the conversation verbatim.
2. **Repository content → model → host.** The most important boundary in the project.
   The model reads files, source and tests, and issues tool calls from what it read
   (`system_prompt`, `src/main.zig:110`). Nothing in the program separates "the model's
   own plan" from "an instruction the model found in a file"; the only thing that does is
   an instruction in the prompt itself.
3. **Provider → agent.** The streamed reply decides the next action. The validation point
   is `applyFrame` (`src/main.zig:2314`), which bounds the shape, not the intent.
4. **Agent → provider.** The key goes out in an `authorization` header
   (`authHeaders`, `src/main.zig:1600`) to whatever host `base_url` named, after the
   scheme check at `src/main.zig:275`.
5. **Model → filesystem and process.** `bash` runs `/bin/sh -c` with the model's string
   (`toolBash`, `src/tool.zig:559`); `read`, `write` and `edit` take any path
   (`toolRead` `src/tool.zig:793`, `toolWrite` `src/tool.zig:907`, `toolEdit`
   `src/tool.zig:972`).
6. **GitHub → host.** `update` downloads bytes and writes them over the running
   executable (`fetchAsset` `src/update.zig:639`, `replaceVerified`
   `src/update.zig:269`). Validation point: `decide` (`src/update.zig:269`).
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
| `GITHUB_TOKEN` | releases API access, and repository scope beyond it | environment, then an `Authorization` header on `api.github.com` only (`bearerFor`, `src/update.zig:221`); absent from every tool subprocess (`secret_env_vars`, `src/main.zig:951`) |
| `~/.secrets/openrouter` | the same key, on disk | read in `resolveKey`, `src/main.zig:900` |
| Source tree and everything in it | `.env`, keys, unreleased work | read by `toolRead` (`src/tool.zig:793`, a credential refused at `src/tool.zig:793`), sent to the provider in the request body |
| Host compute and credentials | the shell inherits the environment less this binary's own credentials | `childEnviron`, `src/main.zig:972` |
| The binary itself | a replaced copy runs on every later invocation | replaced at `src/update.zig:284` |
| Run logs | working directory, model, token counts, finish reason | `~/.microagent/sessions`, capped at 200 records (`pruneSessions`, `src/session.zig:282`; `max_session_logs` `src/session.zig:208`) |
| Token spend | `--max-turns` bounds turns and `--max-spend-tokens` bounds money, both only when asked for | `max_turns_default`, `src/main.zig:62`; `default_max_tokens`, `src/main.zig:76`; `spendCeilingReached`, `src/main.zig:1270` |

## Threats per boundary

### Operator → agent (STRIDE: spoofing, tampering, information disclosure)

- A prompt that names a hostile base URL or a hostile `--repo` steers the whole run.
  Both are operator inputs, so this is a threat only where an automated harness passes a
  task's text straight through (`bench/gauntlet.sh`).
- A prompt of unbounded length enters the conversation with no size cap
  (`setPrompt`, `src/main.zig:887`; appended at `openConversation`,
  `src/main.zig:4246`); the request body grows with it.

### Repository content → model → host (elevation of privilege, information disclosure)

- **Prompt injection through source files.** A file, a test fixture, an issue template or
  a `CLAUDE.md`/`AGENTS.md` in the tree can say "run `curl … | sh`". The model reads it
  with the ordinary `read` tool (`src/tool.zig:793`) and there is no instruction
  provenance, so the injected text is as trusted as the operator's prompt. The system
  prompt tells the model to treat tool output as data and to report such a file instead of
  acting on it (`src/main.zig:110`), which is a control a hostile file can argue with. This
  is the project's dominant risk and it is a design property, not a bug.
- The same path exfiltrates: the model can `read` a file and the file's bytes go into the
  next request body (`buildBody`, `src/main.zig:1568`).
- A hostile repository can also reach the terminal: bytes a tool echoes reach the gutter
  line (`toolCallLine`, `src/tool.zig:467`) and the provider's text reaches stdout, which
  is the answer the run was asked for and is deliberately left unescaped.

### Provider → agent (spoofing, tampering, denial of service)

- A hostile or coerced endpoint chooses every tool call. A single response can carry up to
  64 calls (`max_tool_calls`, `src/main.zig:78`, enforced by the index check at
  `src/main.zig:2193` and the index clamp in `applyCallDelta`) and they run as the
  operator.
- A tool call's name and argument object are the provider's own text and are parsed
  from bytes the model read out of the tree. They are fuzzed from the argument JSON
  to the gutter line and the limits it produces: the line stays one line inside its
  buffer with no byte a terminal acts on, and every count the model wrote is inside
  its ceiling before a subprocess starts (`fuzzToolCall`, `src/tool.zig:1919`; test at
  `src/tool.zig:1919`).
- A call the provider never gave an index for, or gave no id or no name for, is
  dropped rather than dispatched, as is one whose arguments are not a JSON object
  (`keepRunnableCalls`, `src/main.zig:1959`; `argumentsAreAnObject`,
  `src/main.zig:1990`), and the count is reported rather than passing for a turn
  that dispatched everything (`src/main.zig:1925`).
- The same transport is at-least-once: a relay that reconnects replays from the
  last event it saw and a proxy that retries a chunk re-sends it. A call whose
  `id` the response already carries is dropped and the first kept
  (`indexOfCallId`, `src/main.zig:1979`), so a replayed `bash` runs once rather
  than twice.
- A stream that never sends `[DONE]` grows the turn until the caps at
  `src/main.zig:87` and `:98` stop it, and the run ends as truncated
  (`truncatedNotice`, `src/main.zig:1881`).
- An error body from the provider is printed on stderr through `terminalSafe`
  (`src/tool.zig:494`) and is capped at 16 KB (`max_error_body_bytes`,
  `src/main.zig:108`), so control bytes are scrubbed and it cannot repaint the terminal.
- Frames that are not JSON are counted and dropped (`applyFrame`, `src/main.zig:2314`;
  the counter at `src/main.zig:1797`); they are not fatal, and the run continues on a
  partial turn, with the count reported at `src/main.zig:1797`.

### Agent → provider (information disclosure, spoofing)

- The key is refused to any base URL that would put it on the wire in the clear:
  `baseUrlCarriesKey` (`src/main.zig:579`) requires `https`, or `http` on loopback, and
  `main` fails the run otherwise (`src/main.zig:275`). Loopback is judged by exact match
  in `isLoopbackHost` (`src/main.zig:587`), so `127.evil.com` and `localhost.evil.com`
  do not qualify; the policy is pinned by the test at `src/main.zig:2916`.
- What that check does not do is constrain *which* https host. `MICROAGENT_BASE_URL` or
  `--base-url` may name any host, and the key follows it there.
- Every diagnostic naming the base URL clips and quotes it (`clip`, `src/main.zig:675`),
  so a value carrying escape sequences cannot repaint the terminal on its way to an error
  message.
- `--api-key` puts the credential in `argv` (`resolveKey`, `src/main.zig:900`), which is
  world-readable in the process table for the life of the run.
- The conversation carries everything the model read, on every turn, by design
  (`buildBody`, `src/main.zig:1568`).
- Redirects are not followed: `.redirect_behavior = .unhandled` (`src/main.zig:1627`)
  makes a 3xx an error status, so a provider that answers with a `Location` cannot walk
  the API key off to whoever it names. The header carrying the key is the one the request
  writer reads (`authHeaders`, `src/main.zig:1600`); it is not a separately
  privileged field, so the unhandled redirect is the whole of this control.
- A base URL carrying `user:password@` has that userinfo replaced wherever the URL is
  printed (`displayUrl`, `src/main.zig:629`; `redactUserinfo`, `src/main.zig:634`).
- `MICROAGENT_CA_BUNDLE`, `SSL_CERT_FILE` and `--ca-bundle` decide who vouches for that
  host: `loadCaBundle` (`src/net.zig:38`) adds the named file's certificates to the
  client's store, and the system store is still scanned, so a bundle naming one more
  root is enough to terminate the connection that carries the key. The path is
  operator or environment input, and nothing constrains what the file may contain. What
  is refused is a bundle that cannot be read or that holds no certificate: an empty
  trust store is reported and the system store is used instead. The same path governs
  `update` (`src/update.zig:903`), where it covers the release download.

### Model → filesystem and process (elevation of privilege, tampering, denial of service)

- `bash` is arbitrary command execution with the operator's identity and working
  directory (`toolBash`, `src/tool.zig:559`). The spawned shell inherits the environment
  less this binary's own credentials (`childEnviron`, `src/main.zig:972`, over
  `secret_env_vars`, `src/main.zig:951`, which is the four provider keys plus
  `GITHUB_TOKEN`), so `bash env` and `bash printenv` cannot put the run's own key in the
  transcript. A command naming a credentials file is refused on the same name rule the
  other tools apply (`credentialInCommand`, `src/tool.zig:549`, applied at
  `src/tool.zig:566`); that rule reads the command's words rather than a parsed shell, so
  a file reached through indirection is not caught.
- `read`, `write` and `edit` accept absolute paths and do not confine writes to the
  working tree (`src/tool.zig:793`, `src/tool.zig:907`, `src/tool.zig:972`). Each refuses
  a path the credential tables name, and nothing else.
- `write` and `edit` write through a temporary file and a rename, following a symlink to
  the real file first and carrying the destination's own permission bits over
  (`writeFileAtomic`, `src/tool.zig:949`; `permission_bits`, `src/tool.zig:930`), so a
  symlink planted in the tree redirects a write, and a rewritten file comes back with the
  mode it had rather than with the process umask's.
- `ast` with `rewrite` set applies its replacement to every match
  (`toolAst`, `src/tool.zig:1069`), so a single model turn can rewrite a whole file set.
  A rewrite that would still match the text it produced is refused
  (`astRewriteRefusal`, `src/tool.zig:1157`), which is evidence the run reads back
  and not a sandbox: a replacement that re-matches through a form the pattern's
  literal text does not spell is still applied.
- Bounded today: 60 s tool timeout (`tool_timeout_ms`, `src/tool.zig:51`), 120 s default
  and 600 s ceiling for `bash` (`src/tool.zig:51`, `src/tool.zig:51`, applied through
  `bashTimeoutMs` at `src/tool.zig:515` and `boundedMs` at `src/tool.zig:68`, and the
  budget's remaining time through `Budget`, `src/main.zig:1163`), captured output held at
  96 KB and cut to the 24 KB the model reads (`max_tool_output`, `src/tool.zig:22`,
  `runCapped`, `src/tool.zig:1230`), `--max-turns`
  (`src/main.zig:62`), and a wall-clock budget (`src/main.zig:1137`).

### GitHub → host (spoofing, tampering, elevation of privilege)

- The release JSON is attacker-shaped: every field in it becomes a tag, an asset name or a
  URL the updater acts on (`parseRelease`, `src/update.zig:327`). It is fuzzed against
  exactly that (`fuzzRelease`, `src/update.zig:1895`; `fuzzSidecar`, `src/update.zig:1989`).
- The `--repo` the updater requests from is the caller's own text, and it is
  fuzzed from the command line to the URL it becomes: a repo no argument carried
  fails, a repo `validRepo` refuses never reaches a request, and one it accepts
  only ever names `api.github.com` (`releaseApiUrl`, `src/update.zig:169`; harness
  `fuzzUpdateArgs`, `src/update.zig:1401`).
- A body over the cap is refused while it streams, not after (`fetchInto`,
  `src/update.zig:493`, against `Capped` at `src/update.zig:386`); the API body is capped
  at 10 MB, the asset at 256 MB, the sidecar at 64 KB (`src/update.zig:22-24`).
- `GITHUB_TOKEN` is narrowed to the releases API before any request carries it:
  `bearerFor` (`src/update.zig:221`) returns the token only for a URL under
  `https://api.github.com/`, and returns null for the asset and the sidecar, which
  GitHub serves anonymously (`src/update.zig:973`, `980`). The grant is therefore as wide
  as the one request that needs it, not as wide as the host allowlist. What remains: a
  repository-scoped token is still presented in full to that one API, so a redirect or
  error on the releases API is the only place it can leak, and the unhandled redirect is
  the control there.
- The sidecar is fetched from the same release as the asset, so the checksum proves the
  download was not corrupted in transit, not that the release was authorized. The trust
  anchor is the GitHub account and the TLS session, nothing more. There is no signature,
  no attestation and no pinned digest.
- A CA bundle named by the environment or `--ca-bundle` is added to the trust store the
  download is verified against (`loadCaBundle`, `src/net.zig:38`, called at
  `src/update.zig:903`), so a bundle carrying one attacker-issued root substitutes the
  asset and the sidecar together and the checksum still matches. The host allowlist does
  not help: both URLs are on a GitHub host, the requests are addressed there, and the
  certificate presented is one the client was told to accept.
- The replacement follows a symlink to the real file (`replaceVerified`,
  `src/update.zig:284`, through `net.resolveSymlinkTarget`, `src/net.zig:147`), so a
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
having them thrown away. Each has a control named above; a regression in any of them is
the same bug returning.

## Mitigations in the code

| Control | Covers | Where |
| --- | --- | --- |
| System prompt names tool output, file contents and command output as data, and tells the model to report a file that gives orders | prompt injection through a file, at the model rather than in the program | `system_prompt`, `src/main.zig:110` |
| `owner/name` validation before a URL exists | URL injection through `--repo` | `repoPartOk`, `src/update.zig:142`; `validRepo`, `src/update.zig:152`; `releaseApiUrl`, `src/update.zig:169` |
| Host allowlist: `https` on `github.com`, `*.github.com`, `*.githubusercontent.com`, no userinfo, checked on the page URL and on both asset URLs | asset and page download from a lookalike host | `hostTrusted`, `src/update.zig:179`; `trustedGithubUrl`, `src/update.zig:192`; applied inside `decide` at `src/update.zig:269` |
| `GITHUB_TOKEN` is presented only to `https://api.github.com/`, prefix-compared octet by octet, so a lookalike host, a userinfo URL and a path carrying the API name all get nothing; the asset and the sidecar go out unauthenticated | a repository-scoped token handed to the asset CDN, to `api.github.com.evil.com`, or to a path that merely contains the API name | `bearerFor`, `src/update.zig:221`; applied at `src/update.zig:912`, `990`, `992` |
| A CA bundle that cannot be read, or that holds no certificate, is refused and the system store is used instead | a bundle silently emptying the trust store, so every request fails as if the machine shipped no certificates | `loadCaBundle`, `src/net.zig:38` |
| sha256 sidecar verification before the verdict is `replaced` | corrupted or substituted download | `checksumMatches`, `src/update.zig:247`; `decide`, `src/update.zig:269` |
| Version comparison refuses a downgrade | installing an older build over a newer one | `compareVersions`, `src/update.zig:87`; `fetchesAsset`, `src/update.zig:240` |
| Atomic replace, only on `.replaced` | partial write, write on a refusal | `decide`, `src/update.zig:269`; `replaceVerified`, `src/update.zig:284`; `replaceExecutable`, `src/update.zig:658` |
| The key is refused on a plaintext `http` base URL off loopback, every octet range-checked | the key crossing a network path in the clear, or to a name spelled like an address | `baseUrlCarriesKey`, `src/main.zig:579`; `isLoopbackHost`, `src/main.zig:587`; enforced at `src/main.zig:275`; test at `src/main.zig:2916` |
| Userinfo redacted from every printed URL, and every quoted diagnostic clipped and escaped | a password in the base URL copied into stderr, or a base URL carrying escape sequences repainting the terminal | `displayUrl`, `src/main.zig:629`; `redactUserinfo`, `src/main.zig:634`; `clip`, `src/main.zig:675`; `quoteUntrusted`, `src/update.zig:39` |
| Redirects unhandled | the key replayed to a host the provider names | `src/main.zig:1627` |
| Argument vectors instead of a shell for `search`, `ast`, `git` | shell injection through a pattern or a path | `toolSearch`, `src/tool.zig:1036`; `toolAst`, `src/tool.zig:1069`; `toolGit`, `src/tool.zig:298` |
| `--` separator and a `rev` that may not start with `-` | an option smuggled in as a path or a revision | `gitArgv`, `src/tool.zig:352`; `gitPathspecs`, `src/tool.zig:405`; `toolSearch`, `src/tool.zig:1036`; `toolAst`, `src/tool.zig:1069` |
| Fixed git subcommands, no writes through the `git` tool | `bash`-strength git | `gitArgv`, `src/tool.zig:352-380` |
| Every tool subprocess is its own group leader; the group is SIGKILLed and takes the terminal's interrupt with it | orphaned build trees holding resources, and a Ctrl+C that leaves a build writing files | `signalGroup`, `src/tool.zig:154`; `watchToolGroup`, `src/tool.zig:172`; `forwardInterruptsToToolGroup`, `src/tool.zig:181`; `runCapped`, `src/tool.zig:1230` |
| Output, response, frame, error-body and config caps; the response cap covers the whole response, not each field | memory exhaustion from a tool, a stream, an error body or a file | `max_tool_output`, `src/tool.zig:22`; `max_response_bytes`, `src/main.zig:87`; `max_frame_bytes`, `src/main.zig:102`; `max_error_body_bytes`, `src/main.zig:108`; `max_config_bytes`, `src/main.zig:104` |
| Tool-call index cap and a saturating cast | a provider asking for billions of slots, or a wrapped index on a 32-bit build | `max_tool_calls`, `src/main.zig:78`; check at `src/main.zig:2193` |
| A tool call with no index, no id or no name, or with arguments that are not an object, is dropped rather than dispatched, and the drop is reported | a partial or malformed stream entry becoming a command | `keepRunnableCalls`, `src/main.zig:1959`; `argumentsAreAnObject`, `src/main.zig:1990`; report at `src/main.zig:1925` |
| A call whose `id` the response already carried is dropped and the first kept | a relay or proxy replaying a frame, running `bash` twice or writing a file twice | `indexOfCallId`, `src/main.zig:1979`; test at `src/main.zig:4869`; report at `src/main.zig:1873` |
| All six tools refuse a credentials file by name, extension or directory: `read` and `write` and `edit` and `search` and `ast` on a named path, `bash` on a command naming one | a `.env`, a private key or a `~/.secrets` file put into the model context, or rewritten | `isCredentialPath`, `src/tool.zig:742`; tables at `src/tool.zig:624-637`; refusals at `src/tool.zig:795`, `861`, `924`, `990`, `1022`, `518` |
| `search` and `ast` skip the same files as traversal globs, and `git` excludes them from the diff and the show, including when the call names a path | a credential reaching the provider through a match or a patch | `credential_globs`, `src/tool.zig:698`; `credential_pathspecs`, `src/tool.zig:705`; `gitPathspecs`, `src/tool.zig:405` |
| `write` refuses a call with no `content` | a truncated or forgotten argument emptying a file | `toolWrite`, `src/tool.zig:907` |
| `edit` refuses a replacement equal to, or still containing, the text it replaces | a re-issued call rewriting the same file twice | `toolEdit`, `src/tool.zig:972` |
| `write` and `edit` write through a rename, following a symlink and keeping the destination's permission bits | a half-written file where a whole one was, a link replaced by a regular file, and a `0600` file coming back `0644` | `writeFileAtomic`, `src/tool.zig:949`; `permission_bits`, `src/tool.zig:930`; `resolveSymlinkTarget`, `src/net.zig:147` |
| `bash` timeout is capped at 600 s and clipped to the budget left | model-chosen output running with no deadline at all | `max_bash_timeout_ms`, `src/tool.zig:56`; `bashTimeoutMs`, `src/tool.zig:515`; `Budget`, `src/main.zig:1163` |
| `max_tokens` on every request | one turn generating until the provider's own limit stopped it | `default_max_tokens`, `src/main.zig:76`; request body at `src/main.zig:1555` |
| `--max-spend-tokens` stops starting turns once the run has billed that many tokens, counted before each turn, and announces itself at 80% of the cap | a run whose conversation re-sends itself every turn and bills more with fewer turns than one that does; the run that was started without a ceiling | `optionalCeiling`, `src/main.zig:648`; `spendCeilingReached`, `src/main.zig:1270`; `spend_alarm_percent`, `src/main.zig:1258`; check at `src/main.zig:1352`; test at `src/main.zig:3179` |
| A subprocess that failed keeps what it printed, and only `bash` reports an exit status | a build that printed every error and then timed out reaching the model as a bare error, so the next turn re-ran it | `failedOutput`, `src/tool.zig:229`; `Partial`, `src/tool.zig:1200`; `bash_exit_note`, `src/tool.zig:40` |
| An `ast --rewrite` whose replacement still matches the pattern's own literal text is refused, as is a pattern of metavariables alone | a rewrite that re-applies itself to its own output on the next run | `astRewriteRefusal`, `src/tool.zig:1157`; test at `src/tool.zig:3133` |
| Control bytes escaped in the gutter, scrubbed in error bodies, bounded through one helper | terminal escape injection from repo content, from a command-line argument, and from a config key or a `--repo` value | `toolCallLine`, `src/tool.zig:467`; `terminalSafe`, `src/tool.zig:494`; `chat.safeText`, `src/chat.zig:414`; `clip`, `src/main.zig:675` and `quoteUntrusted`, `src/update.zig:39` |
| Non-JSON frames counted and reported; a stream without `[DONE]` fails the turn | a truncated answer read as a finished one | `applyFrame`, `src/main.zig:2314`, counter reported at `src/main.zig:1797`; `truncatedNotice`, `src/main.zig:1881` |
| Retry with capped exponential backoff on weather-shaped statuses and on failures before the response head is readable; a failure after the head is not retried; a `Retry-After` longer than two minutes is clamped to two, and an out-of-range year is refused | a dropped connection or a rate limit ending the run; a re-sent turn billed twice; a hostile `Retry-After` year overflowing the epoch multiply | retry loop, `src/main.zig:1583`; `retryableStatus` `src/main.zig:2751`, `worthAnotherAttempt` `src/main.zig:2785`, `waitBeforeRetry` `src/main.zig:2813`, `backoffMs` `src/main.zig:2841`, `max_attempts` `src/main.zig:2742`, `max_retry_after_ms` `src/main.zig:2854`, `httpDateYear` `src/net.zig:298`; the same narrowing in `src/update.zig:532-603` |
| Session log created exclusively at `0o600`, and the store directory this run creates at `0o700`; the walk counts every log it finds, orders them by the stamp in the name and deletes the oldest past 200 by the path relative to the store root | one run erasing another's log, unbounded growth, a log nested below the root counted toward the cap while nothing is deleted for it, and on a shared account every other account reading the prompts, the tool arguments and the bytes a tool read out of the tree, which is the material the tools themselves refuse to send the provider | `createSessionLog`, `src/session.zig:124`; `log_file_mode` `src/session.zig:106`, `log_dir_mode` `src/session.zig:107`; `pruneSessions`, `src/session.zig:282`; `pruneSessionsTo`, `src/session.zig:305`; `max_session_logs`, `src/session.zig:208` |
| Values validated where they are set | a mistyped level or ceiling reaching the wire as a 400 | `ceiling`, `src/main.zig:559`; `budgetSeconds`, `src/main.zig:646` |
| Fuzz corpora for the parsers that take untrusted bytes: the release body, the sidecar, the completion stream, the config file, both command lines, a JSON string, a tool call, a quoted value, a provider error body, the session store's names and its record | malformed provider, release, config, command-line, tool-call, session-store or terminal-facing input | `fuzzRelease` `src/update.zig:1895`, `fuzzSidecar` `src/update.zig:1989`, `fuzzUpdateArgs` `src/update.zig:1401`, `fuzzStream` `src/main.zig:5372`, `fuzzArgs` `src/main.zig:3397`, `fuzzToml` `src/style.zig:586`, `fuzzJsonString` `src/chat.zig:886`, `fuzzToolCall` `src/tool.zig:1919`, `fuzzSafeText` `src/chat.zig:736`, `fuzzTerminalSafe` `src/tool.zig:2275`, `fuzzStoreNames` `src/session.zig:1125`, `fuzzSessionRecord` `src/session.zig:1253` |

### Gaps, ranked by exploitability and impact

1. **No confinement on model-driven execution.** `bash`, `write`, `edit` and an `ast`
   rewrite run with full operator authority, and the instructions that trigger them can
   come from a file the run reads. The system prompt asks the model not to act on such a
   file (`src/main.zig:110`), which is the same trust the operator already placed in the
   prompt. The model, not the operator, is the last gate.
2. **The credential rule is a name rule, and `bash` matches it on words.** All six tools
   refuse a path the tables name, so none of them can put a known `.env` or private key in
   the model context. Two ways around it remain. A credential under a name the tables do
   not carry is still read. And `credentialInCommand` (`src/tool.zig:549`) tokenizes the
   command rather than parsing a shell, so a command that assembles a path at run time
   reaches the file. The run's own keys are the case that mattered most, and it is closed
   structurally rather than textually: no tool subprocess inherits them
   (`src/main.zig:946`).
3. **A named CA bundle is trusted without a policy.** `MICROAGENT_CA_BUNDLE`,
   `SSL_CERT_FILE` and `--ca-bundle` add whatever the file holds to the trust store of the
   provider connection and of the release download (`loadCaBundle`, `src/net.zig:38`;
   `src/main.zig:280`; `src/update.zig:903`). A bundle naming one attacker-issued root is a
   machine in the middle for both, and the sha256 sidecar it serves hashes as published, so
   the updater installs what it was handed. The system store is still scanned, which makes
   the added root additional rather than a replacement, and that is the whole of the check.
4. **No host policy on `base_url`, only a scheme policy.** The key never goes out over
   plaintext `http` off loopback, but `MICROAGENT_BASE_URL` or `--base-url` may name any
   `https` host and the key follows it. A poisoned environment variable turns a review run
   into a key handoff to whoever answers on that name.
5. **The tools are not confined to the working tree.** `read`, `write` and `edit` take an
   absolute path and will follow it, `writeFileAtomic` (`src/tool.zig:949`) follows a
   symlink before writing, and `ast --rewrite` applies its replacement to every match
   (`src/tool.zig:1069`). A file outside the tree that is not a credential by name is
   writable, so an injected instruction can rewrite an rc file, a `PATH` entry or a
   service unit with the operator's own authority. `ast --rewrite` now refuses a
   replacement its own pattern would match again (`astRewriteRefusal`,
   `src/tool.zig:1157`), which is a check on the call rather than a limit on where
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
   deadline" (`optionalCeiling`, `src/main.zig:648`; the check is made before a turn
   starts, at `src/main.zig:1352`, so the provider never sees a request the run has
   already priced itself out of, and the turn that reaches the ceiling is the one that
   finishes). A run started without it, by a prompt or a harness that chose no
   ceilings, is bounded only by what the conversation happens to cost.
9. **No audit trail beyond the gutter line.** Tool calls go to stderr as one line with no
   timestamp, no exit status and no file (`noteToolCall`, `src/tool.zig:462`); the session
   log records token counters, the working directory and the finish reason, never which
   commands ran (`writeRecord`, `src/session.zig:405`).
10. **A symlinked install can point anywhere.** `replaceVerified` follows the link
    (`src/update.zig:284`, through `src/net.zig:147`); a link planted in a directory on the
    operator's `PATH` redirects the write, and `write` and `edit` follow links the same
    way.
11. **A config file can redirect the system prompt.** `MICROAGENT_CONFIG` prepends a
    reply-style ruleset to the system prompt (`loadStyle`, `src/main.zig:1003`); it is
    operator-supplied and capped at 64 KB (`max_config_bytes`, `src/main.zig:104`), but
    nothing in it is sandboxed, and it reaches the provider on every turn like any other
    prompt text.

## Abuse cases

Each of these is a scenario, evidenced by the code path that enables it. None has been
attempted.

- **A poisoned test fixture.** A repository contains a fixture whose text tells the agent
  to run a command. The model reads it with `read` (`src/tool.zig:793`) and, with `bash`
  (`src/tool.zig:559`), the command runs as the operator. The agent has no way to
  distinguish file content from operator instruction; the prompt tells it to report such a
  file instead, which a sufficiently persuasive file can argue with.
- **A hostile endpoint.** With `--base-url` pointed at an `https` server the attacker
  controls, the key arrives in the `authorization` header (`src/main.zig:1574`) and the
  reply decides every subsequent tool call. The scheme check passes, because the attacker
  serves `https`.
- **A symlink on the update path, or in the tree.** A link named `microagent` earlier on
  `PATH` is followed at install time (`src/update.zig:284`), and a link beside a source
  file redirects a `write` or an `edit` through it (`src/tool.zig:949`), so the run
  changes a file the operator never named.
- **Scraping through the harness.** `read` has no path restriction, so a run over a
  directory containing credentials under names the tables do not carry reads them and,
  through the model, can send them off the machine. There is no per-run file budget
  either, only the 4 MB per read (`max_read_bytes`, `src/tool.zig:27`).
- **A runaway bill.** `--max-turns` at its ceiling and a conversation that grows to 400 KB
  before compaction (`conversation_soft_limit`, `src/main.zig:39`; `compactMessages`,
  `src/main.zig:2459`) cost real tokens, with `max_tokens` bounding each turn. A run
  started without `--max-spend-tokens` has nothing bounding the run: the turn loop asks
  the provider again on its own schedule (`src/main.zig:1352`).
- **A trust anchor from the environment.** A run started with a `MICROAGENT_CA_BUNDLE`
  pointing at a file the attacker supplied terminates both connections the run makes: the
  provider request that carries the key (`src/main.zig:280`) and the release download
  `update` performs (`src/update.zig:903`). Nothing in the path checks what the file
  certifies, so a certificate naming the attacker's host is enough.
- **A poisoned task container.** The Harbor adapter hands the provider key to every task
  container it starts (`integrations/harbor/microagent_agent.py:410`), so a task written
  by a third party inherits the key for the length of its run.
- **Trust placed in the model's own bookkeeping.** A run that edited the tree and never ran
  a test is asked once, in prose, to go and verify (`verify_push`, `src/main.zig:325`),
  and the detection of "ran a test" is a substring match over the tool call's arguments
  (`isTestRun`, `src/main.zig:1424`). It is a quality prompt, not a control: a command
  that runs a test without naming one of the listed runners is invisible to it, and no
  refusal follows either way. What counts as an edit is read from the call's own
  arguments, so `ast` counts for `--rewrite` and not for a search
  (`isEdit`, `src/main.zig:1443`); a run that changed the tree with a tool the list does not
  carry is asked nothing.

## Response readiness

Note only, and not built here.

- Tool activity is a single stderr line per call with no timestamps and no exit status
  (`noteToolCall`, `src/tool.zig:462`), and the session log keeps no record of it
  (`writeRecord`, `src/session.zig:405`). A post-incident reconstruction of what a run did
  has to come from the working tree, not from a log.
- There is no `SECURITY.md`. The README's `Security` section (`README.md:381`) points here
  and makes no claim this document contradicts, and the two supported-versions statements
  agree with each other and with the release workflow: only the latest release is
  supported, with no backport window (`README.md:289`, `CHANGELOG.md:10`). There is no
  disclosure contact and no documented path from a reported vulnerability to a shipped
  fix, and this document does not invent one.
- `CHANGELOG.md` records every change that alters what a run does, which is the closest
  thing to a public record of behavior changes.
