# Threat model

What can be attacked in microagent, from where, and what stands in the way. Every entry
carries a file reference, so the next pass can re-verify it against the code rather than
against this document. Flags, environment variables and the config file are documented in
[usage.md](usage.md).

Last reviewed: 2026-10-01, against `0.12.0` ([build.zig.zon](../build.zig.zon)) and the
`Unreleased` section of [CHANGELOG.md](../CHANGELOG.md).

This pass re-read the document against that `0.12.0` and corrected one claim the code had
already overtaken and two controls the code has that the table did not. Gap 9 said a
tool call leaves "no exit status" behind, and the response-readiness section said "one
stderr line per call"; both predate the outcome line, which names `ok`, `FAILED` or
`not run` and the call's elapsed milliseconds beside every gutter line
(`noteToolOutcome`, `src/main.zig:4087`). The gap is rewritten rather than deleted, because
what that line still does not carry is the part an investigation needs: no wall-clock
timestamp, no call id, and one argument clipped to 120 bytes
(`max_detail_bytes`, `src/tool.zig:989`). Two controls shipping since the last pass are now
rows: a config file that holds an `api_key` and is readable beyond its owner is named on
stderr (`secretInReadableFile`, `src/main.zig:2332`), and a `[sandbox]` list naming roots
while the sandbox is off is said out loud too
(`inertWritableMessage`, `src/main.zig:2361`). The first leaves one hole beside it, entered
as an asset rather than as a control: an `[[mcp]]` `env` value is the second place this file
writes a secret in the clear, it is the one a repository is likelier to commit by accident,
and the mode check fires only for `api_key`, so it is unchecked. The two out-of-order
boundary entries are renumbered so the list reads in order, and `callParams` is now named
on boundary 9, because the model's own argument bytes are spliced into the `tools/call`
frame and a JSON check is the only thing between a model and a third-party server.

Earlier passes: the one before this entered the
surfaces added since the one before it: `--repl` and its stdin channel, `--temperature` and
`MICROAGENT_TEMPERATURE`, `TMPDIR` as a sandbox writable root, the 128 KB `AGENTS.md` ceiling,
and the 1000-turn default. It also corrected citations that had drifted: `make check-refs`
did not recognise a qualified symbol (`config.parse`, `net.urlCarriesKey`), so every citation
written that way was read as a bare one and never checked, and a bare citation on a line that
has since moved onto a comment still passed. The gate now reads the qualified name and reports
a bare citation whose line carries no code, so both classes fail rather than the reader. A bare
citation that drifted onto other code still passes the gate; those were checked by hand
against the function each one names. Earlier passes added the remote MCP transport
and the `[tools.<name>]` presets (summary row 14, two entry points, trust boundary 9, gap
13), then the MCP-server and skills surfaces, and named the stall timeout as an entry point, a
control and a gap. `fuzzConfig` moved to `config.zig`, and `loadStyle` was renamed `loadConfig`.

This pass re-read the document against `0.12.0`. Fifty-five citations had drifted off their
symbols and the gate was failing on every one of them; they are back on the line each symbol is
defined on, and the last bare citation, which no rewrite can name a symbol for, is paired. The
sandbox had no row in the mitigations table at all, although gaps 1 and 5 name it as the control
that stands between a model-driven write and the rest of the filesystem: it is now a row, with the
`applySandbox` false that leaves a run confined by nothing but the in-process path check, and
`bash` outside both halves either way. `HOME` is an entry point the table had missed in its own
right, since every default path is built under it.

This pass re-read the document against the same `0.12.0`. Twelve citations onto
`src/session.zig` had drifted and the gate was failing on every one of them, so the session
rows are back on the lines their symbols moved to. Three surfaces the code has and the document
did not are entered: an MCP server's own stderr, which is inherited into the operator's terminal
with no escaping and no cap where every other untrusted byte this program prints is scrubbed
(entry point, gap 15, and the exception is now named on the escaping control's own row rather
than left for a reader to infer); the `todo` tool, the ninth one and the only one that touches
neither a path nor a subprocess, which the credential-rule rows had counted as six tools and
then as seven; and `NO_COLOR` and `TERM`, which `usage.md` documents and `env_vars` holds and
the entry-point table had left out. The Harbor citations moved onto the lines `api_key` and
`base_url` are defined on, which the gate cannot do for it because it reads Zig sources only:
they were checked by hand, and the next pass should read them by hand too. The escaping control
row now says plainly what it does not cover, which is the form a reader building on it needs.

This pass re-read the document against the same `0.12.0`. Fifteen citations onto
`src/sandbox.zig` and `src/session.zig` had drifted after the session store's create was
routed through one helper, and `make check-refs` was failing on every one of them; they are
back on the line each symbol is defined on. Four claims the code contradicted are corrected.
Summary row 6 and gap 2 both counted the credential rule as applying to "every tool that takes
a path, which is eight of the nine": seven tools take a path and `bash` checks command words
instead, so the count now reads seven plus `bash`, and `todo` is the ninth. The sandbox control
row named only the configured `writable` entries, where `resolveWritableRoots` always adds the
working directory, `/tmp` and the session log directory and then the configured ones, so a
reader could conclude a narrower root set than the code grants; the row says so and cites the
resolver. The summary table numbered the remote-MCP row 14 and the skill row 13, so the
risk-ranked column read out of order; the two are 13 and 14 now. The fuzz row is widened to the
harnesses the tree has and the row did not name: the release URL trust gate and token routing
(`fuzzTrustedUrl`, `fuzzBearerFor`), a base URL, an edit, a credentials path, a deny-list
command, an `ast` rewrite, a `SKILL.md` body, the fences an `AGENTS.md` may try to close, the
Seatbelt profile a writable root is rendered into, and `fuzzCallParams`, the harness the
`Unreleased` section adds over the one request frame this program builds from model-supplied
bytes.

The classes this tree has already fixed list stopped before the `Unreleased` section's own
security entries, so two classes the changelog records as fixed were absent from the history
the next pass aims itself by: a credential exclusion list that git read as ordinary
characters and that therefore excluded nothing, and the same list anchored at the repository
root, so a credential at depth or under a directory stayed in the patch. The first is the
sharpest shape in the whole history: a control that was present, cited, and inert. The
uncapped `write` payload is entered there too.

The Harbor trust boundary the deployment section described was not a boundary: the adapter puts
the provider key into every third-party task container, which the summary table, the assets
table and the numbered boundaries all omitted, so a reader ranking the surface had no row for
the one place a key leaves the process before the first prompt. It is boundary 12, summary row
16, and an asset row names where the key lives in that shape. Two sentences read as a
duplicated symbol and are corrected (`authHeaders` on boundary 4, `installIfVerified` on
boundary 6, `ceiling` in gap 12).

Cite a control as a pair, `` `symbol`, `path:line` ``, qualified or not, so the gate covers it
from then on. No owner and no review cadence are named: neither is decided in this repository,
and inventing one would put a name against a document nobody signed.

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
| 1 | Repository content drives shell execution | repo → model → host | high: any content the model reads can carry an instruction | full compromise of the operator's account, files and keys | prompt wording (`system_prompt`, `src/conversation.zig:61`), a command filter that is empty unless the operator configures it (`deniedInCommand`, `src/tool.zig:1418`), and Landlock LSM confinement when the sandbox is enabled (gap 1) |
| 2 | The provider's reply drives shell execution | provider → host | medium: needs a hostile, coerced or MITM'd endpoint | same as 1 | redirect refused (`streamChat`, `src/main.zig:3428`), response caps, timeouts, `bash` timeout default and ceiling (`default_bash_timeout_ms`, `src/tool.zig:70`; `max_bash_timeout_ms`, `src/tool.zig:65`) |
| 3 | The API key is sent to whatever host the environment names | agent → provider | medium: any `https` host is accepted | provider account takeover, bill abuse | plaintext `http` refused off loopback (`net.urlCarriesKey`, `src/net.zig:695`, enforced at `src/main.zig:575`) |
| 4 | A named CA bundle adds a trust anchor for every TLS connection of the run | environment/argv → agent, agent → provider and GitHub | medium: needs a write to the environment, or `--ca-bundle` on the command line | the API key to a machine in the middle, and a release asset that hashes as published | replaces the system store when the bundle loads; a bundle that is unreadable or holds no certificate is refused (`loadCaBundle`, `src/net.zig:88`); no policy on what a bundle may add (gap 3) |
| 5 | Tools read and write outside the working tree | model → filesystem | high: `read`/`write`/`edit`/`multi_edit` take any path | overwrite `~/.ssh/authorized_keys`, a shell rc file, any file the operator can write | credential paths refused by name (`isCredentialPath`, `src/tool.zig:1908`); configurable sandbox (`[sandbox]` in config) enforces path checks and Landlock LSM rules to confine writes to writable roots (gap 5) |
| 6 | Tool output carries credentials to the model and on to the provider | host → model → provider | low: needs a credential under a name the rules do not know, or one reached through shell indirection | secret exfiltration through a routine run | eight of the nine tools refuse or exclude a known credential name: the seven that take a path (`read`, `write`, `edit`, `multi_edit`, `search`, `ast` and `git`) plus `bash`, which checks its command words; `todo` takes neither (`credential_globs`, `src/tool.zig:1710`; `credentialInCommand`, `src/tool.zig:1222`; `gitPathspecs`, `src/tool.zig:899`; `runTool`, `src/tool.zig:932`); the run's own keys are absent from a tool's environment (`scrubSecrets`, `src/main.zig:2218`) |
| 7 | A compromised release replaces the binary | GitHub → host | low: needs the release account or its token | persistent, silent code execution on every later run | sha256 sidecar, host allowlist (`checksumMatches`, `src/update.zig:162`; `hostTrusted`, `src/update.zig:109`) |
| 8 | The API key is visible in the process table | operator → host | low: needs a local reader | key theft by any other process or user on the box | none |
| 9 | A hostile or malformed provider response exhausts memory or CPU | provider → agent | medium | run killed, machine memory spent | per-response cap (`max_response_bytes`, `src/stream.zig:20`), frame cap (`max_frame_bytes`, `src/main.zig:176`), error-body cap (`max_error_body_bytes`, `src/main.zig:191`), timeouts, process-group kill |
| 10 | A hostile repository writes escape sequences to the operator's terminal | repo → terminal | high: any file the model echoes | terminal spoofing, clipboard tricks | control bytes escaped in the gutter (`toolCallLine`, `src/tool.zig:1020`, through `chat.safeText`, `src/chat.zig:735`) and scrubbed in error text (`terminalSafe`, `src/tool.zig:1071`) |
| 11 | A hostile model result spends the operator's money | model → provider | medium: a runaway or looping run | unbounded bill on the provider account | per-request `max_tokens` (`buildBody`, `src/main.zig:3323`), turn and wall-clock ceilings, and an opt-in run-wide spend ceiling (`--max-spend-tokens`, `spendCeilingReached`, `src/main.zig:2780`); nothing bounds the spend of a run that set none (gap 8) |
| 12 | An `[[mcp]]` table chooses a program the run executes | operator config → host | medium: needs a write to the config file, the environment or `--config` | arbitrary code execution as the operator; every tool result the server returns reaches the model | servers are read only from the config file (`--config`, `MICROAGENT_CONFIG` or `$HOME/.microagent/config.toml`), never from the working tree (`config.parse`, `src/config.zig:275`; `connect`, `src/mcp.zig:1563`), so a repository under review cannot add one; the server inherits the scrubbed environment, never the provider key (`scrubSecrets`, `src/main.zig:2218`); it is trusted exactly as far as a `bash` command the operator wrote, and no further |
| 13 | A remote MCP server, or an enabled preset, returns text the model reads and receives what the model sends it | remote server → model, agent → remote server | medium: needs a hostile or compromised endpoint, or an operator who switched one on; a public endpoint working as intended is the ordinary case | prompt injection through a result (as row 1, by a path that is not the repository), the model's queries and the key seen by a third party | a result is untrusted text like any tool output: the system prompt says so, it is capped at `max_tool_output` (`resultText`, `src/mcp.zig:914`); presets are off until the config enables one (`toolKey`, `src/config.zig:673`); `https`, or `http` on loopback, with no userinfo (`validUrl`, `src/mcp.zig:1441`); no redirect, a 4 MB response ceiling and a per-request timeout that cancels the whole exchange (`exchange`, `src/mcp.zig:487`; `readAnswer`, `src/mcp.zig:577`; `post`, `src/mcp.zig:426`); the key is named in the file by variable, read before the scrub and removed from every child's environment (`withKeys`, `src/mcp.zig:1474`; `scrubSecrets`, `src/main.zig:2218`); the sandbox does not confine this traffic (gap 13) |
| 14 | A skill body is prompt text the model is told to follow | operator config → model | low: needs a write to a skills directory, the config file, or `MICROAGENT_SKILLS` | the run follows instructions the operator did not write, and the conversation is re-sent to the provider | skills are read only from the roots the config file or the variable names, else `$HOME/.microagent/skills`, never from the working tree (`roots`, `src/skill.zig:142`; `discover`, `src/skill.zig:216`), so a repository under review cannot install one; the listing escapes control bytes (`Skills.prompt`, `src/skill.zig:95`); a body reaches the conversation only when the model calls the tool, as a tool result under the same cap as any other |
| 15 | `--repl` resets the money ceiling on every prompt, and one process serves them all | stdin → agent, model → provider | low: needs an operator who left the REPL open on a session nobody is watching | the spend ceiling the operator set bounds one prompt rather than the session, so a long session bills what a short one would have stopped | ceilings are read into `Options`, which `run` takes by value, so turn, time and spend all start again at each prompt (`run`, `src/main.zig:2841`); a prompt over 64 KB ends the run rather than being truncated (`max_repl_prompt_bytes`, `src/main.zig:677`); a prompt past a ceiling ends the session with that run's own exit status (gap 14) |
| 16 | A Harbor task container holds the provider key | task container → host credentials | medium: needs a task image written by a third party, which is the ordinary case for a benchmark run | the provider key read out of the container environment, a bill on the operator's account | the endpoint is checked on the host before a container starts (`base_url`, [microagent_agent.py:254](../integrations/harbor/microagent_agent.py)); nothing else about the task is, because executing a third-party task is what the adapter is for (boundary 12, and the abuse case "a poisoned task container") |

`microagent` is a local CLI with no listener, no server and no database. It holds no user
data of its own: it exposes the operator's own machine, and an attacker wants the key, the
source tree and the host. The one asset worth stealing on its own is the API key.

## Attack surface

### Entry points in the code

| Entry point | What arrives | Handled at |
| --- | --- | --- |
| Command line, agent mode | prompt, flags, API key in `argv` | `parseArgs`, `src/main.zig:1862`; `main`, `src/main.zig:415`; `valued_flags`, `src/main.zig:1766` holds every valued flag the run accepts: `-p/--print`, `-m/--model`, `-b/--base-url`, `-k/--api-key`, `--ca-bundle`, `--config`, `--reasoning-effort`, `--temperature`, `--budget`, `--max-spend-tokens`, `--max-turns`, `--max-tokens`, `--stall-timeout`. `--repl` takes no value and is set in `parseArgs`. `update` is dispatched before the agent flags by `runMain`, `src/main.zig:445` |
| `--repl`, and standard input with it | a second untrusted prompt channel, read a line at a time and kept in one conversation across the whole process, where an `argv` prompt is one prompt in one process | `replPrompt`, `src/main.zig:691`, called from the run loop in `runMain`, `src/main.zig:445`; line cap `max_repl_prompt_bytes`, `src/main.zig:677` |
| `--ca-bundle <file>` | the PEM file whose certificates vouch for the provider and for GitHub | `net.caBundlePath`, `src/net.zig:154`; `loadCaBundle`, `src/net.zig:88`; applied at `src/main.zig:477` and `run`, `src/update.zig:566` |
| `--config <file>`, `MICROAGENT_CONFIG`, `~/.microagent/config.toml` | the provider settings (`model`, `base_url`, `api_key`, the last a credential in the clear), the `system_prompt_extra` text, skill roots, `[[mcp]]` and `[tools.<name>]` tables, denied shell commands, and sandbox settings: what the prompt says, what the run starts or contacts, which tools it offers, what shell execution refuses, and filesystem confinement | `configSource`, `src/main.zig:2589`; `loadConfig`, `src/main.zig:2280`; `config.parse`, `src/config.zig:275`; cap `max_config_bytes`, `src/main.zig:186` (64 KB) |
| `[[mcp]]` tables in that config | programs the run starts over stdio (`command`, `args`, and an `env` map copied onto the scrubbed environment the child would otherwise inherit, whose values are the second place in this file a secret is written in the clear after `api_key`), remote servers it sends POSTs to (`url`), and the tools they offer | `connect`, `src/mcp.zig:1563`; `spawnOne`, `src/mcp.zig:1814`; `handshake`, `src/mcp.zig:1899`; parsed at `src/config.zig:602`, `src/config.zig:607` and `src/config.zig:613` |
| An MCP server's own stderr | its diagnostics, written straight to the operator's terminal, with no escaping and no cap, unlike every other untrusted byte this program prints | `spawnOne`, `src/mcp.zig:1814`, at `src/mcp.zig:1854` |
| `[tools.<name>]` tables in that config | which built-in tools the model is offered, and which of the public remote servers `web_search`, `context7`, `grep_app` and `deepwiki` are enabled (all four are off by default), with their url, key variable name and timeout | `toolKey`, `src/config.zig:673`; `toolConfigError`, `src/main.zig:992`; `builtinToolsJson`, `src/main.zig:3227`; refusal in `dispatchCall`, `src/main.zig:4097` |
| Responses of a remote MCP server (JSON body or event stream) | text that becomes a tool result, and the session id echoed on later requests | `exchange`, `src/mcp.zig:487`; `readAnswer`, `src/mcp.zig:577`; `sseLine`, `src/mcp.zig:646` |
| `skills` in that config, `MICROAGENT_SKILLS`, `~/.microagent/skills` | `SKILL.md` bodies the model may load, as prompt text | `roots`, `src/skill.zig:142`; `discover`, `src/skill.zig:216`; `call`, `src/skill.zig:478`; cap `max_skill_bytes`, `src/skill.zig:40` |
| `AGENTS.md` in the working directory, or the paths `agents_files` names | repository text the run follows as instructions, appended to the system prompt between a begin and an end marker naming the file, with the prompt stating that the block governs the task and cannot widen it, lift the prompt's rules, authorize a credential, or send anything off the machine | `agentsBlock`, `src/main.zig:747`; `readAgentsFile`, `src/main.zig:840`; cap `max_agents_bytes`, `src/main.zig:150` (128 KB, raised from 16 KB in 0.10.0); `agents_files = []` turns the read off |
| Command line, `update` | `--check` | `parseArgs`, `src/update.zig:526`; `run`, `src/update.zig:566`; dispatched from `runMain`, `src/main.zig:445`, at `src/main.zig:460` |
| `MICROAGENT_MODEL`, `MICROAGENT_BASE_URL`, `MICROAGENT_REASONING_EFFORT` | endpoint, model, response style | `envValue`, `src/main.zig:1447`; read in `runMain`, `src/main.zig:445`, through `envValue`, `src/main.zig:1447`; a run left with no endpoint is refused there too, `runMain`, `src/main.zig:445` |
| `MICROAGENT_MAX_TURNS`, `MICROAGENT_MAX_TOKENS` | loop and response ceilings | `max_turns_default`, `src/main.zig:116` (1000 turns); `default_max_tokens`, `src/main.zig:131`; both through `ceiling`, `src/main.zig:1543` |
| `--temperature <n>`, `MICROAGENT_TEMPERATURE` | the sampling the provider draws from, 0 to 2, sent in the request body when one is set | `temperature`, `src/main.zig:1496`; `temperatureFromEnv`, `src/main.zig:1523`; range `min_temperature`, `src/main.zig:139`; written by `bodyPrefix`, `src/main.zig:3263` |
| `MICROAGENT_API_KEY` | provider credential | `key_var`, `src/main.zig:2095`; resolved in `resolveKey`, `src/main.zig:2087` |
| `api_key` in the config file | provider credential, in the clear on disk | read by `config.parse`, `src/config.zig:275`; resolved in `resolveKey`, `src/main.zig:2087`; no key file is read |
| `MICROAGENT_CA_BUNDLE`, `SSL_CERT_FILE` | trust anchors for the provider host and for GitHub | `caBundlePath`, `src/net.zig:154`, read in `runMain` at `src/main.zig:520`; loaded at `src/main.zig:580` and `run`, `src/update.zig:566` |
| `MICROAGENT_BUDGET_SECONDS`, `--budget` | wall-clock ceiling on the run, suspended time included | `optionalCeiling`, `src/main.zig:1708`; carried by `Budget`, `src/main.zig:2650` |
| `MICROAGENT_MAX_SPEND_TOKENS`, `--max-spend-tokens <n>` | run-wide token ceiling, counted before each turn | `optionalCeiling`, `src/main.zig:1708`; read in `runMain` at `src/main.zig:512`; checked by `spendCeilingReached`, `src/main.zig:2780`, in `run`, `src/main.zig:2841` |
| `MICROAGENT_STALL_TIMEOUT`, `--stall-timeout <s>` | connection setup and request write/read deadline, 120 s by default | `default_stall_timeout_s`, `src/main.zig:134`; `openChatRequest`, `src/main.zig:3494`; `withStallTimeout`, `src/main.zig:3381` |
| `MICROAGENT_SESSION_DIR` | where the JSONL run log is written | `sessionDir`, `src/session.zig:27`; read in `runMain` at `src/main.zig:513` |
| `HOME` | the root of every default path: the config file, the session store, the skill roots, and the `~` a config value or `MICROAGENT_SKILLS` expands; it is trimmed, and an empty one is no home rather than a path off the root | `homeDir`, `src/net.zig:313`; `expandHome`, `src/net.zig:332`; held to one list in `env_vars`, `src/main.zig:2138` |
| `TMPDIR` | a directory a sandboxed run may write to, added to the writable roots when the value is absolute and no other root covers it | `resolveWritableRoots`, `src/sandbox.zig:63`; read at `src/sandbox.zig:127`; a value that is not absolute adds no root |
| `MDEBUG` | protocol notes and the resolved configuration on stderr, never a key | `debugEnabled`, `src/main.zig:1455`; `traceConfig`, `src/main.zig:2415` |
| `NO_COLOR`, `TERM` | whether the gutter draws a tool's name in bold; `NO_COLOR` is read for presence and trimmed, so `NO_COLOR=false` still turns colour off, and `TERM=dumb` does | `colorEnabled`, `src/net.zig:174`; consulted once per gutter line by `noteToolCall`, `src/tool.zig:1004`; both held in `env_vars`, `src/main.zig:2138` |
| `GITHUB_TOKEN` | credential, presented only to `api.github.com` and never to a tool subprocess | `githubBearer`, `src/update.zig:144`; narrowed by `bearerFor`, `src/update.zig:155`; applied per request at `exchange`, `src/update.zig:436` |
| GitHub release JSON | tag, page URL, asset names, download URLs | `parseRelease`, `src/update.zig:179` |
| Downloaded asset and `.sha256` sidecar | bytes that become the running executable | `fetch`, `src/update.zig:347`; gated by `installIfVerified`, `src/update.zig:483` |
| Streamed provider response (SSE) | model text and tool calls | `streamChat`, `src/main.zig:3428`; `applyFrame`, `src/stream.zig:560` |
| Tool call arguments | what the model wants done | `runTool`, `src/tool.zig:932` |
| A `todo` call's items | the model's own scratch list, echoed back into the conversation; the ninth tool is the only one that touches neither the filesystem nor a subprocess | `toolTodo`, `src/tool.zig:2593`; bounds `max_todo_items`, `src/tool.zig:2585` and `max_todo_text_bytes`, `src/tool.zig:2586`; the text is escaped by `chat.safeText`, `src/chat.zig:735` |
| Files in the working tree | the model's evidence, and its instructions | `toolRead`, `src/tool.zig:2046`; the instructions block assembled by `agentsBlock`, `src/main.zig:747` between `agents_fence_open`, `src/main.zig:157` and `agents_fence_close` |

There is no network listener, webhook, message consumer, scheduled job or IPC. microagent
itself talks only to the provider's base URL and to GitHub, plus the remote MCP servers the config
names: a `url` table, or a preset. All four presets (web_search, context7, grep_app, deepwiki) are
off by default. `enabled = true` under `[tools.<name>]` offers that preset's tools and a call
sends its arguments to the configured endpoint. Disabled presets receive no requests.
An MCP server it starts is a separate program and
may talk to whatever its operator configured. That traffic is the server's, not this binary's, and
the config entry is the operator's statement that the program is trusted. The traffic to a remote
server is this binary's, and the sandbox does not confine it.

The one input channel that arrived after 0.10.0 is standard input, and it is the only one whose
sender a caller does not already own. An `argv` prompt is read once, before anything else runs;
`--repl` reads lines for the life of the process and keeps one conversation across all of them.
A prompt arriving that way is appended to a conversation the model has already been answering
from, so it arrives with every earlier turn's tool output still in the request body. The line cap
(`max_repl_prompt_bytes`, `src/main.zig:677`, 64 KB) is the only bound on it, and a line over it
ends the run rather than being truncated, so nothing partial is sent.

### Surface added by deployment

- The binary runs whatever is on `PATH`: `rg`, `ast-grep`, `git` and `/bin/sh`
  (`toolSearch`, `src/tool.zig:2625`; `toolAst`, `src/tool.zig:2659`; `toolGit`, `src/tool.zig:624`; `toolBash`, `src/tool.zig:1476`). A hostile `PATH` entry is a hostile
  tool, and `bash` runs whatever name the model typed.
- The Harbor adapter runs the binary inside third-party task containers with the provider
  key in the container environment
  (`api_key`, [microagent_agent.py:143](../integrations/harbor/microagent_agent.py), read into the
  container environment at `:556`), so a poisoned task reaches the container plus the key. The
  endpoint is checked on the host before a container starts (`base_url`,
  [microagent_agent.py:254](../integrations/harbor/microagent_agent.py)): a
  `MICROAGENT_BASE_URL` with no scheme, or a plaintext one off loopback, is refused there
  rather than by the binary inside the container, which already holds the key.
- CI builds release assets with the workflow's own token and publishes them with
  `gh release create` ([release.yml:139](../.github/workflows/release.yml)). That account
  is the trust anchor for every future `microagent update`.

## Trust boundaries

1. **Operator → agent.** The prompt is untrusted input like any other. There is no
   validation point: (`setPrompt`, `src/main.zig:2070`) stores it and (`openConversation`, `src/conversation.zig:417`) appends it to the conversation verbatim.
2. **Repository content → model → host.** The most important boundary in the project. The
   model reads files, source and tests, and issues tool calls from what it read
   (`system_prompt`, `src/conversation.zig:61`). Nothing in the program separates the model's own
   plan from an instruction it found in a file; only an instruction in the prompt does.
3. **Provider → agent.** The streamed reply decides the next action. The validation point
   is (`applyFrame`, `src/stream.zig:560`), which bounds the shape, not the intent.
4. **Agent → provider.** The key goes out in an `authorization` header (`authHeaders`, `src/main.zig:3370`) to whatever host `base_url` names, after the scheme check in
   `runMain`, `src/main.zig:445`, at `src/main.zig:575`. Beside it goes one `User-Agent`
   naming the program and its version (`net.user_agent`, `src/net.zig:40`), the same header
   a remote MCP server and the release API see; it carries no credential, and it is the
   program's own name rather than the client library's, so what a host logs is the client
   and not the toolchain it was built with.
5. **Model → filesystem and process.** `bash` runs `/bin/sh -c` with the model's string
   (`toolBash`, `src/tool.zig:1476`); `read`, `write`, `edit` and `multi_edit` take any path (`toolRead`, `src/tool.zig:2046`; `toolWrite`, `src/tool.zig:2226`; `toolEdit`, `src/tool.zig:2315`).
6. **GitHub → host.** `update` downloads bytes and writes them over the running executable
   (`fetch`, `src/update.zig:347`; `installIfVerified`, `src/update.zig:483`).
   Validation point: `installIfVerified`, `src/update.zig:483`.
7. **Secrets → process.** The key enters from `argv`, the environment or a file, lives in
   process memory for the run, and leaves only in the `authorization` header. It is never
   written to the session log or to a tool result.
8. **Operator config → host (MCP).** The `[[mcp]]` tables name programs the run starts as
   children before the first request; the tools they report are advertised to the model and
   dispatched to them (`config.parse`, `src/config.zig:275`; `connect`, `src/mcp.zig:1563`).
   Validation point: the tables come from the config file named by `--config`, the variable
   or `$HOME/.microagent/config.toml`, and from nowhere in the tree (`configSource`, `src/main.zig:2589`). The children inherit the scrubbed environment, which lacks the
   provider key (`scrubSecrets`, `src/main.zig:2218`). A server whose name or tool name
   cannot be spelled in a tool name is refused (`validName`, `src/mcp.zig:1506`). What a
   configured server does with its own authority is the operator's decision, as with a
   `bash` command they write.
9. **Remote MCP server → model, and agent → remote server.** A `url` table or a preset that is on
    sends each tool call's name and arguments to an HTTPS endpoint the operator named, and the text
    it answers with becomes a tool result, as a file's contents do. Validation points: the url
    must be `https`, or `http` on loopback, with no userinfo (`validUrl`, `src/mcp.zig:1441`); a
    redirect is an error, the body is capped at 4 MB and the request at its timeout (`exchange`, `src/mcp.zig:487`); the key is looked up by a variable name written in the file and sent in one
    header (`withKeys`, `src/mcp.zig:1474`), and that variable is removed from the environment every
    child inherits (`scrubSecrets`, `src/main.zig:2218`). The argument text the model wrote is
    checked as JSON before it is spliced into the `tools/call` frame as the bytes the model sent,
    so a truncated or double-spelled object is refused here rather than handed to a server that
    answers with its own parse error (`callParams`, `src/mcp.zig:890`). Nothing checks what the
    endpoint says: a result can carry instructions, and it is untrusted for the same reason a file
    from a repository under review is.
10. **Standard input → agent (`--repl`).** A prompt read from a terminal becomes a user message
    in a conversation the model has already been answering from, so it arrives with every earlier
    turn's tool output in the request body (`replPrompt`, `src/main.zig:691`, called from the run
    loop in `runMain`, `src/main.zig:445`). Validation point: the line length, and nothing else.
    The read happens after the config, the skills, the `AGENTS.md` block and the MCP children are
    already built, so a prompt on stdin cannot change any of them; it carries the same trust the
    `argv` prompt has, over a channel that stays open. What differs is duration rather than
    authority: one process serves every prompt, and the only wall between them is the operator's
    typing.
11. **Operator skills → model.** A `SKILL.md` body is instruction text the model is told to
    follow. It reaches the conversation only when the model calls the `skill` tool (`call`, `src/skill.zig:478`). Validation point: the roots are the config file's `skills` list,
    the directories `MICROAGENT_SKILLS` names, or the operator's home directory, never the
    tree (`roots`, `src/skill.zig:142`; `discover`, `src/skill.zig:216`).
12. **Task container → host credentials (Harbor).** The Harbor adapter starts each benchmark task
    as a container and puts the provider key in its environment, so whatever the task image runs
    holds the key for the length of the run (`api_key`,
    [microagent_agent.py:143](../integrations/harbor/microagent_agent.py), written into the
    container environment at `:556`). Validation point: the endpoint is checked on the host
    before a container starts, refusing a url with no scheme or a plaintext one off loopback
    (`base_url`, [microagent_agent.py:254](../integrations/harbor/microagent_agent.py)); nothing
    else about the task is checked, because a task is third-party code by design and the run
    exists to execute it.

Privilege transitions are total, not gradual: once the model calls `bash`, the run has the
operator's full authority. No user confirmation sits between a model decision and a
command. The one transition this program does not own is the Harbor one: the key crosses into a
third-party container before the first prompt, so there the transition is total at startup
rather than gradual.

## Assets

| Asset | Why it matters | Where it lives |
| --- | --- | --- |
| Provider API key | bills, model access, provider account | `argv`, the environment or the config file, then process memory; through the Harbor adapter, also the environment of every third-party task container (`api_key`, [microagent_agent.py:143](../integrations/harbor/microagent_agent.py), placed into the container environment at `:556`) |
| `GITHUB_TOKEN` | releases API access, and repository scope beyond it | environment, then an `Authorization` header on `api.github.com` only (`bearerFor`, `src/update.zig:155`); absent from every tool subprocess (`secret_env_vars`, `src/main.zig:2195`) |
| `api_key` in the config file | the same key, on disk and in the clear | read in `resolveKey`, `src/main.zig:2087`; the file is not a credentials path, so the `read` tool can open it: keep it out of a workspace the model is given; a config holding one whose group or other bits are set is named on stderr (`secretInReadableFile`, `src/main.zig:2332`) |
| A secret in an `[[mcp]]` `env` table | the server's own token, written in the clear beside a `command` the same file names | the config file, parsed at `src/config.zig:602`; the value is copied onto the scrubbed environment the child inherits (`spawnOne`, `src/mcp.zig:1814`), so it is a secret on disk and never in the model's context. `chmod 600` is the same rule `api_key` is held to, and the file-mode check fires only for `api_key`, so this one is unchecked |
| Source tree and everything in it | `.env`, keys, unreleased work | read by (`toolRead`, `src/tool.zig:2046`), credentials refused by `isCredentialPath`, `src/tool.zig:1908`, sent to the provider in the request body |
| A remote MCP server's key | access to the operator's account at that service | the environment, named by `api_key_env`; copied once by (`withKeys`, `src/mcp.zig:1474`), sent in one request header, removed from every child's environment (`scrubSecrets`, `src/main.zig:2218`); never in the config file or a log line |
| Host compute and credentials | the shell inherits the environment minus this binary's own credentials | `scrubSecrets`, `src/main.zig:2218` |
| The binary itself | a replaced copy runs on every later invocation | replaced at `replaceBinary`, `src/update.zig:458` |
| Run logs | working directory below the home and no account name, model, token counts, finish reason | `~/.microagent/sessions`, capped at 200 logs, one per run (`pruneSessions`, `src/session.zig:512`; `max_session_logs`, `src/session.zig:400`; the `cwd` a record carries, `recordCwd`, `src/session.zig:287`) |
| Token spend | `--max-turns` bounds turns and `--max-spend-tokens` bounds money, each only when set | `max_turns_default`, `src/main.zig:116`; `default_max_tokens`, `src/main.zig:131`; `spendCeilingReached`, `src/main.zig:2780` |

## Threats per boundary

### Operator → agent (STRIDE: spoofing, tampering, information disclosure)

- A prompt that names a hostile base URL steers the whole run. It is an operator input, so
  this is a threat only where an automated harness passes a task's text straight through
  (`bench/gauntlet.sh`).
- A prompt of any length enters the conversation uncapped (`setPrompt`, `src/main.zig:2070`; appended in `openConversation`, `src/conversation.zig:417`), and the
  request body grows with it. A REPL prompt is bounded at 64 KB
  (`max_repl_prompt_bytes`, `src/main.zig:677`), so the one channel an attacker cannot write
  the operator's shell history into is also the only one with a cap on it.
- A REPL prompt arrives on a conversation that has already run tools, so it is answered with the
  earlier turns' file contents and command output still in the request body (`replPrompt`, `src/main.zig:691`). A line typed after a run that read a credential the name rules missed
  carries that credential's bytes to the provider again, on a run the operator is watching and
  believes has already ended.

### Repository content → model → host (elevation of privilege, information disclosure)

- **Prompt injection through source files.** A file, a test fixture or an issue template in the
  tree can say "run `curl … | sh`". The model reads it with the ordinary `read` tool
  (`toolRead`, `src/tool.zig:2046`). Instructions carry no provenance, so the injected text is as
  trusted as the operator's prompt. The system prompt tells the model to treat tool output as data
  and to report such a file instead of acting on it (`system_prompt`, `src/conversation.zig:61`),
  but a hostile file can argue with that. This is the project's dominant risk, and it is a design
  property, not a bug.
- `AGENTS.md` is the one file in the tree the run follows as instructions rather than as data, and
  that is deliberate: it is the convention every other coding agent reads, and a run whose operator
  wants none sets `agents_files = []`. Its authority is bounded in the prompt rather than in the
  code, because the file's whole purpose is to direct the run: the block is fenced between a begin
  and an end marker, the prompt states that it governs the task and cannot widen it, lift the
  prompt's rules, authorize a credential, or send anything off the machine, and a line asking for
  one of those is reported rather than obeyed (`system_prompt`, `src/conversation.zig:61`;
  `agentsBlock`, `src/main.zig:747`). The fences are the run's, so a line of the file spelling one
  is marked rather than obeyed as a boundary: otherwise a file closes its own block and continues
  in the operator's own voice, where the block's limits do not apply
  (`defuseFences`, `src/main.zig:799`). A hostile `AGENTS.md` is therefore the strongest injection
  this design admits, and it lands in the system role rather than a tool result.
- The same path exfiltrates: the model can `read` a file, and its bytes go into the next
  request body (`buildBody`, `src/main.zig:3323`).
- A hostile repository can also reach the terminal. Bytes a tool echoes reach the gutter
  line (`toolCallLine`, `src/tool.zig:1020`). The provider's text reaches stdout unescaped,
  deliberately: it is the answer the run was asked for.

### Provider → agent (spoofing, tampering, denial of service)

- A hostile or coerced endpoint chooses every tool call. One response can carry up to 64
  calls (`max_tool_calls`, `src/stream.zig:10`, enforced by
  `applyCallDelta`, `src/stream.zig:475`), and
  they run as the operator.
- A tool call's name and argument object are the provider's own text, parsed from bytes
  the model read out of the tree. They are fuzzed from the argument JSON to the gutter line
  and the limits it produces: the line stays one line inside its buffer with no byte a
  terminal acts on, and every count the model wrote is inside its ceiling before a
  subprocess starts (`fuzzToolCall`, `src/tool.zig:3743`; `fuzzToolCall`, `src/tool.zig:3743`).
- A call the provider gave no index, no id or no name, or whose arguments are not a JSON
  object, is dropped rather than dispatched (`keepRunnableCalls`, `src/stream.zig:104`;
  `argumentsAreAnObject`, `src/stream.zig:135`). The drop count is reported, so the turn
  does not pass for one that dispatched everything. The loop asks for replacement calls
  within the remaining ceilings (`runTurn`, `src/main.zig:3093`).
- The transport is at-least-once: a relay that reconnects replays from the last event it
  saw, and a proxy that retries a chunk re-sends it. A call whose `id` the response already
  carries is dropped and the first kept (`indexOfCallId`, `src/stream.zig:124`), so a
  replayed `bash` runs once.
- A stream exceeding the response byte cap stops reading and discards all pending calls,
  even if the provider keeps sending (`max_response_bytes`, `src/stream.zig:20`;
  `streamChatOnce`, `src/main.zig:3568`). An exact-cap answer can finish normally.
  A stream ending without `[DONE]` fails as truncated (`truncatedNotice`, `src/stream.zig:26`).
- Connection setup, including TLS, request writes and each response read have a
  cancellable deadline, 120 s unless the operator raises it
  (`default_stall_timeout_s`, `src/main.zig:134`; `openChatRequest`, `src/main.zig:3494`;
  `withStallTimeout`, `src/main.zig:3381`). A configured time budget also cancels blocked
  network operations (`streamChatWithinBudget`, `src/main.zig:3456`). The stall timeout is checked only for being a positive number
  (`ceiling`, `src/main.zig:1543`). Nothing refuses a figure larger than any run should
  wait, so a hostile environment that sets it very high turns the stall bound off (gap 12).
- An error body from the provider is printed on stderr through (`terminalSafe`, `src/tool.zig:1071`) and capped at 16 KB (`max_error_body_bytes`, `src/main.zig:191`).
  Control bytes are scrubbed, so it cannot repaint the terminal.
- Frames that are not JSON are counted and dropped (`applyFrame`, `src/stream.zig:560`;
  folded by `streamChatOnce`, `src/main.zig:3568`). They are not fatal: the run continues on a partial turn
  and reports the count in `streamChatOnce`, `src/main.zig:3568`.

### Agent → provider (information disclosure, spoofing)

- The key is refused to any base URL that would put it on the wire in the clear:
  (`net.urlCarriesKey`, `src/net.zig:695`) requires `https`, or `http` on loopback, and
  `runMain` fails the run otherwise (`src/main.zig:575`). (`isLoopbackHost`, `src/net.zig:704`)
  accepts `localhost` and any name ending in `.localhost`, both case-insensitive; `::1`
  with or without brackets; and `127.a.b.c` only as exactly four dotted decimal octets of
  one to three digits, each at most 255 (`isIpv4Loopback`, `src/net.zig:716`). So
  `127.evil.com`, `localhost.evil.com`, `127.1`, `127.0.0.256`, `localhost.` with a
  trailing dot, and other IPv6 spellings of loopback do not qualify. The remote MCP transport applies the same
  rule to its urls (`validUrl`, `src/mcp.zig:1441`).
- The key goes to the base URL, which is the built-in OpenRouter one unless the operator
  named another. Only `MICROAGENT_API_KEY` is read, so a key another provider's tools
  export (`OPENAI_API_KEY`, `DEEPSEEK_API_KEY`) is never picked up and sent to the default
  endpoint by accident. A base URL the operator named is deliberately never questioned,
  because a self-hosted gateway is a legitimate destination for any provider's key.
- The check does not constrain *which* `https` host. `MICROAGENT_BASE_URL` or `--base-url`
  may name any host, and the key follows.
- Every diagnostic naming the base URL clips and quotes it (`clip`, `src/main.zig:1730`), so
  a value carrying escape sequences cannot repaint the terminal through an error message.
- `--api-key` puts the credential in `argv` (`resolveKey`, `src/main.zig:2087`), which is
  world-readable in the process table for the life of the run.
- The conversation carries everything the model read, on every turn, by design
  (`buildBody`, `src/main.zig:3323`).
- Redirects are not followed. `.redirect_behavior = .unhandled` (`streamChatOnce`, `src/main.zig:3568`) makes
  a 3xx an error status, so a provider answering with a `Location` cannot walk the key off
  to whoever it names. The header carrying the key is the one the request writer reads
  (`authHeaders`, `src/main.zig:3370`), not a separately privileged field, so the unhandled
  redirect is the whole of this control.
- A base URL carrying `user:password@` has that userinfo replaced wherever the URL is
  printed (`displayUrl`, `src/main.zig:1687`; `redactUserinfo`, `src/main.zig:1694`).
- `MICROAGENT_CA_BUNDLE`, `SSL_CERT_FILE` and `--ca-bundle` decide who vouches for that
  host. (`loadCaBundle`, `src/net.zig:88`) adds the named file's certificates to the
  client's store in place of the system store, so a bundle naming one root
  is enough to terminate the connection that carries the key. The path is operator or
  environment input, and nothing constrains what the file contains. Only a bundle that
  cannot be read or holds no certificate is refused: the empty trust store is reported and
  the system store used instead. The same path governs `update` (`run`, `src/update.zig:566`),
  where it covers the release download.

### Model → filesystem and process (elevation of privilege, tampering, denial of service)

- `bash` is arbitrary command execution with the operator's identity and working directory
  (`toolBash`, `src/tool.zig:1476`). The spawned shell inherits the environment minus this
  binary's own credentials (`scrubSecrets`, `src/main.zig:2218`, over `secret_env_vars`, `src/main.zig:2195`: `MICROAGENT_API_KEY` plus `GITHUB_TOKEN`), so `bash env` and
  `bash printenv` cannot put the run's own key in the transcript. A command naming a
  credentials file is refused on the same name rule the other tools apply
  (`credentialInCommand`, `src/tool.zig:1222`, `toolBash`, `src/tool.zig:1476`). That rule
  reads the command's words, not a parsed shell, so a file reached through indirection is
  not caught. A command matching a configured command filter (`deny_commands` in config) is
  refused before execution (`deniedInCommand`, `src/tool.zig:1418`).
- `read`, `write`, `edit` and `multi_edit` accept absolute paths and do not confine writes to the working
  tree (`toolRead`, `src/tool.zig:2046`; `toolWrite`, `src/tool.zig:2226`; `toolEdit`, `src/tool.zig:2315`). Each refuses a path the credential tables name, and nothing else.
- `write`, `edit` and `multi_edit` write through a temporary file and a rename. They follow a symlink to
  the real file first and carry the destination's permission bits over
  (`writeFileAtomic`, `src/tool.zig:2292`; `permission_bits`, `src/tool.zig:2273`). A
  symlink planted in the tree therefore redirects a write, and a rewritten file keeps its
  mode instead of taking the process umask's.
- `ast` with `rewrite` set applies its replacement to every match (`toolAst`, `src/tool.zig:2659`), so one model turn can rewrite a whole file set. A rewrite that
  would still match its own output is refused (`astRewriteRefusal`, `src/tool.zig:2781`).
  That is evidence the run reads back, not a sandbox: a replacement that re-matches through
  a form the pattern's literal text does not spell is still applied.
- Bounded today: 60 s tool timeout (`tool_timeout_ms`, `src/tool.zig:60`); 120 s default
  (`default_bash_timeout_ms`, `src/tool.zig:70`) and 600 s ceiling for `bash`
  (`max_bash_timeout_ms`, `src/tool.zig:65`, applied through `bashTimeoutMs`, `src/tool.zig:1119`, and `boundedMs`, `src/tool.zig:81`), clipped to the budget's
  remaining time (`Budget`, `src/main.zig:2650`); captured output held at 96 KB and cut to
  the 24 KB the model reads (`max_tool_output`, `src/tool.zig:25`; `runCapped`, `src/tool.zig:2854`); `--max-turns` (`max_turns_default`, `src/main.zig:116`); and the
  wall-clock budget (`Budget`, `src/main.zig:2650`; `canAffordWait`, `src/main.zig:2714`).

### GitHub → host (spoofing, tampering, elevation of privilege)

- The release JSON is attacker-shaped: every field becomes a tag, an asset name or a URL
  the updater acts on (`parseRelease`, `src/update.zig:179`). It is fuzzed against exactly
  that (`fuzzRelease`, `src/update.zig:1600`; `fuzzSidecar`, `src/update.zig:1659`).
- The repository the updater requests is a constant compiled into the binary (`default_repo`, `src/update.zig:12`, read into `release_api_url` at `src/update.zig:14`), not caller text,
  so a command line cannot steer it. The `--repo` flag that once let a caller name one is
  gone, and with it the `owner/name` validation that guarded it: a repository name is no
  longer an input at any boundary, and the release page, the asset and the sidecar are each
  held to the host allowlist before a request carries them (`trustedGithubUrl`, `src/update.zig:120`, applied in `run`, `src/update.zig:566`, at `src/update.zig:591` and `src/update.zig:635`; harness
  `fuzzArgs`, `src/update.zig:1027`).
- A body over the cap is refused while it streams, not after (`Capped`, `src/update.zig:218`, used in `fetchOnce`, `src/update.zig:389`). The API body is capped
  at 10 MB, the asset at 256 MB, the sidecar at 64 KB (`src/update.zig:18-20`).
- `GITHUB_TOKEN` is narrowed to the releases API before any request carries it. `bearerFor`
  (`bearerFor`, `src/update.zig:155`) returns the token only for a URL under `https://api.github.com/`
  and null for the asset and the sidecar, which GitHub serves anonymously
  (`exchange`, `src/update.zig:436`, at `src/update.zig:449`). The grant is as
  wide as the one request that needs it, not as wide as the host allowlist. What remains: a
  repository-scoped token is still presented in full to that one API, so a redirect or
  error on the releases API is the only place it can leak, and the unhandled redirect is
  the control there.
- The sidecar comes from the same release as the asset, so the checksum proves the
  download was not corrupted in transit, not that the release was authorized. The trust
  anchor is the GitHub account and the TLS session. There is no signature, attestation or
  pinned digest.
- A CA bundle named by the environment or `--ca-bundle` replaces the trust store the download
  is verified against (`loadCaBundle`, `src/net.zig:88`, called at `run`, `src/update.zig:566`).
  A bundle carrying one attacker-issued root substitutes the asset and the sidecar
  together, and the checksum still matches. The host allowlist does not help: both URLs
  are on a GitHub host, the requests are addressed there, and the certificate presented is
  one the client was told to accept.
- The replacement follows a symlink to the real file (`replaceBinary`, `src/update.zig:458`, through `net.resolveSymlinkTarget`, `src/net.zig:365`), so a
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
  (`isCredentialPath`, `src/tool.zig:1908`);
- an `ast --rewrite` that wrote a credentials file while the refusal told the model to
  fetch it through `bash` (`credentialRefusal`, `src/tool.zig:2017`);
- a key minted for one provider reaching another without a word (`resolveKey`, `src/main.zig:2087`);
- a tool call that closed both its pipes and then slept, holding the turn past the
  deadline the call already had (`waitBounded`, `src/tool.zig:2965`);
- a credential exclusion list the `git` tool carried but git read differently: the leading
  `!` is a gitignore negation prefix and an ordinary character inside a pathspec, so every
  entry named a file called `!.env` and excluded nothing, and a committed `.env` came back
  whole as a tool result (`credential_pathspecs`, `src/tool.zig:1783`);
- the same exclusion set anchored at the repository root, so `deploy/credentials` and
  `deploy/.secrets/openrouter` stayed in the patch, and a directory entry excluded without
  its contents (`credential_pathspecs`, `src/tool.zig:1783`);
- an arguments tool with no ceiling on the payload it wrote: `write` held the file it left
  behind to nothing at all while `edit` and `multi_edit` held theirs to 64 MB, so a provider
  ignoring its own `max_tokens` could fill a volume (`max_edited_bytes`, `src/tool.zig:44`);
- a lazy preset server whose `initialize` answer was refused, one of the deaths that never
  passed through `request` and so never got the reap every other death is followed by, so it
  held a process group, one of the 64 interrupt slots and a pipe for the rest of a long run
  (`retireIfDead`, `src/mcp.zig:233`).

The last six share the shape of the rest: a control the code assumed was implied turned
out to be a separate thing. Each has a control named above; a regression in any of them is
the same bug returning. The two git entries are the sharpest of them, because the control
was not merely incomplete but inert: it was present, it was cited, and it excluded nothing.

## Mitigations in the code

| Control | Covers | Where |
| --- | --- | --- |
| System prompt names tool output, file contents and command output as data, and tells the model to report a file that gives orders | prompt injection through a file, at the model rather than in the program | `system_prompt`, `src/conversation.zig:61` |
| The repository the updater requests is a compile-time constant, so no caller text reaches a URL | URL injection through a repository name | `default_repo`, `src/update.zig:12`; `release_api_url`, `src/update.zig:14` |
| Host allowlist: `https` on `github.com`, `*.github.com`, `*.githubusercontent.com`, no userinfo, checked on the page URL and both asset URLs | asset and page download from a lookalike host | `hostTrusted`, `src/update.zig:109`; `trustedGithubUrl`, `src/update.zig:120`; applied in `run`, `src/update.zig:566`, at `src/update.zig:591` and `src/update.zig:635` |
| A refusal body is read only to tell the API's rate limit from a permission refusal, and the token is suggested only on the rate limit | a reader sent to set a token they already set, holding a scope that fixes nothing, after a 403 that was a permission refusal | `statusHint`, `src/update.zig:282`; `isRateLimited`, `src/update.zig:296` |
| `GITHUB_TOKEN` is presented only to `https://api.github.com/`, prefix-compared octet by octet, so a lookalike host, a userinfo URL and a path carrying the API name all get nothing; the asset and the sidecar go out unauthenticated | a repository-scoped token handed to the asset CDN, to `api.github.com.evil.com`, or to a path that merely contains the API name | `bearerFor`, `src/update.zig:155`; applied per request at `exchange`, `src/update.zig:436` |
| A CA bundle that cannot be read, or holds no certificate, is refused and the system store used instead | a bundle silently emptying the trust store, so every request fails as if the machine shipped no certificates | `loadCaBundle`, `src/net.zig:88` |
| sha256 sidecar verified before the verdict is `replaced` | corrupted or substituted download | `checksumMatches`, `src/update.zig:162`; `installIfVerified`, `src/update.zig:483` |
| Version comparison refuses a downgrade | installing an older build over a newer one | `compareVersions`, `src/update.zig:89`; `sameRelease`, `src/update.zig:56`; both applied in `run`, `src/update.zig:566`, at `src/update.zig:600-601` |
| Atomic replace, only on `.replaced` | partial write, write on a refusal | `installIfVerified`, `src/update.zig:483`; `replaceBinary`, `src/update.zig:458` |
| The key is refused on a plaintext `http` base URL off loopback; a `127.` host needs exactly four octets, every one range-checked | the key crossing a network path in the clear, or going to a name spelled like an address | `urlCarriesKey`, `src/net.zig:695`; `isLoopbackHost`, `src/net.zig:704`; `isIpv4Loopback`, `src/net.zig:716`; enforced at `src/main.zig:575` |
| A refusal body reaches the model through the same escaping as any other untrusted server text, and a 4xx or 5xx is a refusal where a 2xx is not | a hostile server's text in the operator's terminal unescaped, or a 202 answering a request this client read as a failure and dropped | `exchange`, `src/mcp.zig:487`; `noteRefusal`, `src/mcp.zig:680`; `describeError`, `src/mcp.zig:1019` |
| Remote MCP: `https` (or loopback `http`) urls with no userinfo, no redirect, a 4 MB response ceiling, a per-request timeout, presets off until enabled | a key or a query sent in the clear, a key replayed to a redirect target, an endpoint holding the run or its memory, a network call nobody asked for | `validUrl`, `src/mcp.zig:1441`; `exchange`, `src/mcp.zig:487`; `readAnswer`, `src/mcp.zig:577`; `toolKey`, `src/config.zig:673` |
| The variables named by `api_key_env` are removed from the environment tool subprocesses and local MCP servers inherit, after the key is read | a `bash: env` that prints a remote server's key into the transcript and on to the provider | `withKeys`, `src/mcp.zig:1474`; `scrubSecrets`, `src/main.zig:2218` |
| Only `MICROAGENT_API_KEY` is read as the key | a key minted for one provider reaching another, with no hostile input at all: a variable another tool exported and a URL nobody set | `key_var`, `src/main.zig:2095`; `resolveKey`, `src/main.zig:2087` |
| Userinfo redacted from every printed URL; every quoted diagnostic clipped and escaped | a password in the base URL copied into stderr, or a base URL carrying escape sequences repainting the terminal | `displayUrl`, `src/main.zig:1687`; `redactUserinfo`, `src/main.zig:1694`; `clip`, `src/main.zig:1730`; `quoteUntrusted`, `src/update.zig:40` |
| Redirects unhandled | the key replayed to a host the provider names | `streamChatOnce`, `src/main.zig:3568` |
| Argument vectors instead of a shell for `search`, `ast`, `git` | shell injection through a pattern or a path | `toolSearch`, `src/tool.zig:2625`; `toolAst`, `src/tool.zig:2659`; `toolGit`, `src/tool.zig:624` |
| `--` separator, and a `rev` that may not start with `-` | an option smuggled in as a path or a revision | `gitArgv`, `src/tool.zig:826`; `gitPathspecs`, `src/tool.zig:899`; `toolSearch`, `src/tool.zig:2625`; `toolAst`, `src/tool.zig:2659` |
| Fixed git subcommands, no writes through the `git` tool | `bash`-strength git | `gitArgv`, `src/tool.zig:826` |
| `git show` is given a format carrying the hash, the date and the subject, so the `Author:` and `Commit:` header lines it prints by default never reach the tool result; `log` is `--oneline` and never printed them | a commit author's name and email address re-sent to the provider on every later turn of a run that only wanted the patch | `gitArgv`, `src/tool.zig:826`; test at `src/tool.zig:5388` |
| Every preset tool's description ends with one sentence telling the model that a call leaves the machine and that nothing belonging to the repository under review goes in an argument | a snippet, a path, a repository name or a person's name out of the tree landing in a third party's search or wiki log to answer a coding task | `off_host_note`, `presetDescription`, `src/mcp.zig:1105` |
| Every tool subprocess and every stdio MCP server leads its own process group; the groups are published in one table, SIGKILLed on the way out, and taken with the terminal's interrupt | orphaned build trees and MCP servers holding resources, and a Ctrl+C that leaves a build writing files | `signalGroup`, `src/tool.zig:268`; `publishChildGroup`, `src/tool.zig:297`; `forwardInterruptsToToolGroup`, `src/tool.zig:343`; `runCapped`, `src/tool.zig:2854` |
| Output, response, frame, error-body and config caps; the response cap covers the whole response, not each field | memory exhaustion from a tool, a stream, an error body or a file | `max_tool_output`, `src/tool.zig:25`; `max_response_bytes`, `src/stream.zig:20`; `max_frame_bytes`, `src/main.zig:176`; `max_error_body_bytes`, `src/main.zig:191`; `max_config_bytes`, `src/main.zig:186` |
| A config file that really holds an `api_key` and whose group or other bits are set is named on stderr with the file and the variable to leave the key to; it is a note, not a refusal, and a mode that cannot be read stays silent | the provider key handed to every other account on a shared machine, at the umask's default mode, with the run saying nothing, while the shipped config and docs tell the operator to `chmod 600` and nothing checked | `secretInReadableFile`, `src/main.zig:2332`; called from `loadConfig`, `src/main.zig:2280`, at `src/main.zig:2310` |
| A `[sandbox]` list naming writable roots while the sandbox is off is said on stderr | a caller reading the operator's stderr as a refusal when the confinement it configured is inert | `inertWritableMessage`, `src/main.zig:2361`; called at `src/main.zig:2309` |
| Tool-call index cap and a saturating cast; rejected call arguments still spend the shared response byte allowance | a provider asking for billions of slots, a wrapped index on a 32-bit build, or excessive indices bypassing the response allowance | `max_tool_calls`, `src/stream.zig:10`; `applyCallDelta`, `src/stream.zig:475`; `clampToResponseCap`, `src/stream.zig:451` |
| Per-turn cap on what a turn's tool results add to the conversation; every call still answers, with a marker past the cap | one response asking for 64 full-size results: a 1.5 MB request billed before the next turn compacts | `max_turn_tool_output`, `src/main.zig:109`; `carriedToolResult`, `src/main.zig:4234`; `finishTurn`, `src/main.zig:4131` |
| A tool call with no index, no id or no name, or with arguments that are not an object, is dropped rather than dispatched, and the drop reported | a partial or malformed stream entry becoming a command | `keepRunnableCalls`, `src/stream.zig:104`; `argumentsAreAnObject`, `src/stream.zig:135`; reported by `streamChatOnce`, `src/main.zig:3568` |
| A call whose `id` the response already carried is dropped and the first kept | a relay or proxy replaying a frame, running `bash` twice or writing a file twice | `indexOfCallId`, `src/stream.zig:124`; test at `src/stream.zig:1434`; reported by `streamChatOnce`, `src/main.zig:3568` |
| Credential paths refused by read, write, edit, multi_edit, search, ast and git; bash checks command words for credential names | credential contents sent to the provider or a credential rewritten by the model | `credentialPath`, `src/tool.zig:1992`; `credentialInCommand`, `src/tool.zig:1222`; `credential_globs`, `src/tool.zig:1710`; `toolRead`, `src/tool.zig:2046`; `toolWrite`, `src/tool.zig:2226`; `toolEdit`, `src/tool.zig:2315`; `toolMultiEdit`, `src/tool.zig:2521`; `toolSearch`, `src/tool.zig:2625`; `toolAst`, `src/tool.zig:2659`; `toolGit`, `src/tool.zig:624`; `toolBash`, `src/tool.zig:1476` |
| The credentials refusal tells a call that would change the file from one that would not, so `ast` with `rewrite` on a credentials path gets the advice that no tool rewrites a key, not the one that sends the model to `bash` | a `write` through `--update-all` on a key file, and a model walking into the same refusal one turn later | `credentialRefusal`, `src/tool.zig:2017`; applied by `toolAst`, `src/tool.zig:2659` |
| `search` and `ast` skip the same files as traversal globs; `git` excludes them from the diff and the show, including when the call names a path. The git half rewrites each glob into a pathspec with the leading `!` off, because git reads `!` inside a pathspec as an ordinary character and an exclusion naming `!.env` matched nothing; a directory entry is excluded with its contents, and a bare name carries git's `**/` prefix beside the anchored spelling, because a pathspec holding no `/` and no wildcard is anchored at the repository root and excluded only the top-level copy | a credential reaching the provider through a match or a patch, including a committed `.env` at a path depth, or every file under a `.secrets/` directory | `credential_globs`, `src/tool.zig:1710`; `credential_pathspecs`, `src/tool.zig:1783`; `gitPathspecs`, `src/tool.zig:899` |
| `write` refuses a call with no `content` | a truncated or forgotten argument emptying a file | `toolWrite`, `src/tool.zig:2226` |
| `write` holds `content` to the same 64 MB ceiling `edit` and `multi_edit` hold the file they leave behind to; `git blame` is cut at the `limit` the schema advertises, before the name-redaction walk | a provider that ignores its own `max_tokens` filling the operator's disk, or the whole history of a vendored file in one tool result, re-sent every turn | `max_edited_bytes`, `src/tool.zig:44`; `firstLines`, `src/tool.zig:911`; refused by `toolWrite`, `src/tool.zig:2226` |
| `edit` and `multi_edit` refuse a replacement equal to, or still containing, the text it replaces | a re-issued call rewriting the same file twice | `applyEdit`, `src/tool.zig:2368` |
| `write`, `edit` and `multi_edit` write through a rename, following a symlink and keeping the destination's permission bits | a half-written file where a whole one was, a link replaced by a regular file, a `0600` file coming back `0644` | `writeFileAtomic`, `src/tool.zig:2292`; `permission_bits`, `src/tool.zig:2273`; `resolveSymlinkTarget`, `src/net.zig:365` |
| `bash` timeout capped at 600 s and clipped to the budget left | model-chosen commands running with no deadline | `max_bash_timeout_ms`, `src/tool.zig:65`; `bashTimeoutMs`, `src/tool.zig:1119`; `Budget`, `src/main.zig:2650` |
| Opt-in `[sandbox] enabled = true` confines writes: Landlock on Linux, a Seatbelt profile on macOS, `/` read-only with each writable root granted, binding through `PR_SET_NO_NEW_PRIVS` and `landlock_restrict_self`; in process, `isPathWritable` refuses `write`, `edit`, `multi_edit` and an `ast --rewrite` outside the roots, and an empty roots slice is the only way that restriction lifts. The roots are not only the configured ones: the working directory, `/tmp`, and the session log directory are always added, then each `writable` entry and `$TMPDIR` where it names an absolute directory none of those covers | a model-driven write reaching `~/.ssh/authorized_keys`, a shell rc file, or any path outside the working tree | `applySandbox`, `src/sandbox.zig:424`; `applyLandlock`, `src/sandbox.zig:268`; `resolveWritableRoots`, `src/sandbox.zig:63`; `isPathWritable`, `src/sandbox.zig:164`; applied at `src/main.zig:579`, refused by `toolWrite`, `src/tool.zig:2226`, `toolEdit`, `src/tool.zig:2315` and `toolAst`, `src/tool.zig:2659` |
| A tool call's deadline covers the wait for the child as well as the drain of its pipes, and the process group is signalled when it passes | a command that closes both pipes and then sleeps holding the turn, the process-group reap never firing, and `--budget` not kept | `waitBounded`, `src/tool.zig:2965`; deadline taken by `runCapped`, `src/tool.zig:2854` |
| `max_tokens` on every request | one turn generating until the provider's own limit stops it | `default_max_tokens`, `src/main.zig:131`; `buildBody`, `src/main.zig:3323` |
| `--max-spend-tokens` stops starting turns once the run has billed that many tokens, counted before each turn; before the first turn that starts at or past 80% of the cap it prints `<spent> of the <cap> token ceiling spent after <n> turn(s)` on stderr, once per run; a cap under 2, or a turn that jumps from below 80% to the cap, gets only the stop line | a run whose conversation re-sends itself every turn, billing more with fewer turns; a run started without a ceiling | `optionalCeiling`, `src/main.zig:1708`; `spendCeilingReached`, `src/main.zig:2780`; `spend_alarm_percent`, `src/main.zig:2768`; `spendAlarmDue`, `src/main.zig:2787`; `spendNotice`, `src/main.zig:2810`; printed and checked by `run`, `src/main.zig:2841` |
| A failed subprocess keeps what it printed and reports its failure or nonzero exit status | a build, search or git command that printed useful output before failing reaching the model as a bare error or a clean result | `failedOutput`, `src/tool.zig:571`; `captureResult`, `src/tool.zig:476`; `Partial`, `src/tool.zig:2824` |
| An `ast --rewrite` whose replacement still matches the pattern's own literal text is refused, as is a pattern of metavariables alone | a rewrite that re-applies itself to its own output on the next run | `astRewriteRefusal`, `src/tool.zig:2781`; test at `src/tool.zig:6386` |
| Control bytes escaped in the gutter and scrubbed in error bodies, bounded through one helper. An MCP server's own stderr is not covered by it: that child inherits the terminal (`spawnOne`, `src/mcp.zig:1814`), so whatever it writes is the one unescaped byte path left (gap 15) | terminal escape injection from repo content, a command-line argument, a config key or a value out of the release body | `toolCallLine`, `src/tool.zig:1020`; `terminalSafe`, `src/tool.zig:1071`; `chat.safeText`, `src/chat.zig:735`; `clip`, `src/main.zig:1730`; `quoteUntrusted`, `src/update.zig:40` |
| Non-JSON frames counted and reported; a stream without `[DONE]` fails the turn; provider error fields are parsed as JSON, and null is not an error | a truncated or failed answer read as a finished one | `applyFrame`, `src/stream.zig:560`; `streamChatOnce`, `src/main.zig:3568`; `truncatedNotice`, `src/stream.zig:26`; `noteStreamError`, `src/stream.zig:217` |
| A REPL line over 64 KB ends the run with exit 2 rather than being truncated, a prompt past a ceiling ends the session with that run's own exit status, and `/quit` or EOF exits 0 | a truncated prompt sent as a whole, and a session that keeps spending after a ceiling was reached without the caller being told | `replPrompt`, `src/main.zig:691`; cap `max_repl_prompt_bytes`, `src/main.zig:677`; the loop's exits at `src/main.zig:621-629` and `src/main.zig:653` |
| Capped exponential backoff for retryable statuses and failures before the request body is completely on the wire; a complete POST is not replayed after a stalled flush or missing response head; a provider error frame is retried only with no content, tool calls, reported usage or malformed frames; `Retry-After` seconds or dates are clamped to 120 s, malformed or past dates fall back to backoff, and a wait the time budget cannot cover ends the turn | a dropped connection or rate limit ending the run; a billable response replayed; a malformed date overflowing clock arithmetic; a wait outliving the budget | `sendRequest`, `src/main.zig:3346`; `streamChatOnce`, `src/main.zig:3568`; `reaskWaitMs`, `src/main.zig:3521`; `retryableStatus`, `src/net.zig:798`; `retryBackoffMs`, `src/net.zig:788`; `retryAfterValueMs`, `src/net.zig:852`; `httpDateYear`, `src/net.zig:1014`; `retryWaitMs`, `src/main.zig:4403`; `fetchOnce`, `src/update.zig:389` |
| Session log created exclusively at `0o600`, with new store directories at `0o700`; one prune after creation orders this program's log names by timestamp, suffix and path, applies count and age limits, and leaves the store unchanged if listing fails; working directories under the home are recorded with a home-relative marker | one run erasing another's log; unbounded growth; unrelated accounts reading run metadata or listing log names; the home account name appearing in the recorded working directory | `createSessionLog`, `src/session.zig:162`; `log_file_mode`, `src/session.zig:121`; `log_dir_mode`, `src/session.zig:122`; `recordCwd`, `src/session.zig:287`; `pruneSessionsTo`, `src/session.zig:542`; `logName`, `src/session.zig:462`; `max_session_logs`, `src/session.zig:400`; `max_session_log_age_days`, `src/session.zig:412` |
| Connection setup and request write/read deadlines, and cancellation at the configured run deadline | a silent provider holding a run open during TLS, headers or streaming | `default_stall_timeout_s`, `src/main.zig:134`; `openChatRequest`, `src/main.zig:3494`; `withStallTimeout`, `src/main.zig:3381`; `streamChatWithinBudget`, `src/main.zig:3456` |
| Tool subprocess arguments reject interior NUL bytes before spawn | the OS executing a truncated argument different from the checked model command | `ToolChild`, `src/tool.zig:96` |
| MCP initialization and tool requests share the caller's deadline; stdio writes and reads share that deadline; complete lines and cumulative reply bytes stay within the response allowance; structured results allocate only their capped prefix | a server blocking a tool call past its budget, or replies and retained results growing memory without bound | `handshake`, `src/mcp.zig:1899`; `Servers.call`, `src/mcp.zig:808`; `writeStdio`, `src/mcp.zig:272`; `request`, `src/mcp.zig:330`; `readLine`, `src/mcp.zig:280`; `cappedJson`, `src/mcp.zig:1000` |
| MCP JSON nesting is limited to 256 levels before a parsed tree reaches schema, result or error serialization | a small reply with deeply nested arrays or objects crashing the run despite its byte ceiling | `max_frame_depth`, `src/mcp.zig:54`; `parseFrame`, `src/mcp.zig:384` |
| MCP catalog pages share a 4 MiB JSON allowance and the original handshake deadline; repeated or invalid cursors fail discovery, and only complete catalogs are offered | partial tool discovery and a server expanding retained metadata through unlimited pages | `readTools`, `src/mcp.zig:1967`; `buildTools`, `src/mcp.zig:2013` |
| Non-object MCP errors allocate and retain only their capped diagnostic | repeated large error strings or arrays accumulating full replies in the run allocator | `describeError`, `src/mcp.zig:1019`; `cappedJson`, `src/mcp.zig:1000` |
| Values validated where they are set | a mistyped level or ceiling reaching the wire as a 400 | `ceiling`, `src/main.zig:1543`; `optionalCeiling`, `src/main.zig:1708` |
| Fuzz corpora for the parsers that take untrusted bytes: the release body, the sidecar, the release URL trust gate and the token routing behind it, the completion stream and the fold that reads it, the config file, both command lines, a base URL, a JSON string, a tool call, an edit, a credentials path, a deny-list command, a quoted value, a provider error body, the session store's names and its record, the request body a turn assembles from model text and tool output, a `SKILL.md` body, the fences an `AGENTS.md` may try to close, the Seatbelt profile a writable root is rendered into, the `tools/call` argument frame the model's own bytes are spliced into, and the server, tool, environment and header names an MCP entry is built from | malformed provider, release, config, command-line, tool-call, session-store, conversation or terminal-facing input, and a name that passes the entry checks but cannot be used afterwards | `fuzzRelease`, `src/update.zig:1600`; `fuzzSidecar`, `src/update.zig:1659`; `fuzzTrustedUrl`, `src/update.zig:861`; `fuzzBearerFor`, `src/update.zig:1285`; `fuzzArgs`, `src/update.zig:1027`; `fuzzStream`, `src/main.zig:7057`; `fuzzFrame`, `src/stream.zig:1888`; `fuzzFrameSequence`, `src/stream.zig:2177`; `fuzzArgs`, `src/main.zig:5297`; `fuzzBaseUrl`, `src/main.zig:4598`; `fuzzConfig`, `src/config.zig:1964`; `fuzzJsonString`, `src/chat.zig:1523`; `fuzzToolCall`, `src/tool.zig:3743`; `fuzzEdit`, `src/tool.zig:3832`; `fuzzCredentialPath`, `src/tool.zig:4590`; `fuzzDenyList`, `src/tool.zig:7352`; `fuzzAstRewrite`, `src/tool.zig:6489`; `fuzzSafeText`, `src/chat.zig:1296`; `fuzzTerminalSafe`, `src/tool.zig:4311`; `fuzzStoreNames`, `src/session.zig:1849`; `fuzzSessionRecord`, `src/session.zig:1977`; `fuzzBody`, `src/conversation.zig:888`; `fuzzSkillFile`, `src/skill.zig:573`; `fuzzDefuseFences`, `src/main.zig:7743`; `fuzzSeatbeltProfile`, `src/sandbox.zig:821`; `fuzzCallParams`, `src/mcp.zig:2896`; `fuzzEntryNames`, `src/mcp.zig:3285` |
| The interrupt table is 64 fixed slots, so a run already tracking a full table is refused the next child rather than starting one the handler cannot reach: a tool call fails with the stdlib's "no system resources left" (`runCapped`, `src/tool.zig:2854`, at `src/tool.zig:2871`) and a stdio MCP server is named on stderr and skipped (`spawnOne`, `src/mcp.zig:1814`, at `src/mcp.zig:1878`) | an untracked child that Ctrl+C would leave running | `max_child_groups`, `src/tool.zig:290`; `publishChildGroup`, `src/tool.zig:297` |
| A stdio MCP server that stops answering, or whose `initialize` answer is refused, is reaped on the spot: the child is stopped, its process group SIGKILLed, its interrupt slot retired and its read buffer handed back, and the reap is idempotent so shutdown still lands. Every death is followed by it, including a lazy preset's first handshake, which never passed through `request` | a dead server holding a process group, one of the 64 interrupt slots and a pipe nobody reads for every remaining turn of a long run; the slot it holds is one `onInterrupt` needs to stop a child | `reap`, `src/mcp.zig:214`; `retireIfDead`, `src/mcp.zig:233`; deferred in `request`, `src/mcp.zig:330`, at `src/mcp.zig:338`, and called from `Servers.call`, `src/mcp.zig:808`, at `src/mcp.zig:827` |

## Gaps, ranked by exploitability and impact

1. **No confinement on model-driven execution by default.** `bash`, `write`, `edit`, `multi_edit` and an `ast`
   rewrite run with full operator authority, and the instructions that trigger them can
   come from a file the run reads. The system prompt asks the model not to act on such a
   file (`system_prompt`, `src/conversation.zig:61`), the same trust the operator already placed in the prompt.
   Command filtering is a control only where the operator configured it: `deny_commands` defaults to
   an empty list (`Options`, `src/main.zig:226`), so a run that never set it refuses no
   command at all and `deniedInCommand`, `src/tool.zig:1418`, has nothing to match. The example config
   ships the list commented out ([config.example.toml](../config.example.toml)).
   When sandbox mode is enabled (`[sandbox]` in config), Linux Landlock rules or a macOS Seatbelt profile confine
   all child process writes to designated directory roots, and the in-process path check refuses the
   four tools that write even where the kernel sandbox could not be applied.
   The kernel half fails open: where Landlock is unavailable, a seccomp policy refuses
   `PR_SET_NO_NEW_PRIVS`, or `landlock_restrict_self` is refused, `applySandbox` returns false and
   the run continues (`runMain`, `src/main.zig:445`, at `src/main.zig:579`), naming the mechanism on
   stderr. What is left is the in-process check on `write`, `edit`, `multi_edit` and `ast
   --rewrite`; `bash` and the MCP servers are never confined by either half, and a caller that
   reads the operator's stderr as a refusal rather than as a warning has the protection it did not
   ask for.
2. **The credential rule is a name rule, and `bash` matches it on words.** Seven tools take a
   path, and all seven refuse one the tables name, at any depth rather than only at the leaf
   (`isCredentialPath`, `src/tool.zig:1908`; `runTool`, `src/tool.zig:932`), so none can put a known
   `.env` or private key in the model context; `bash` is the eighth, checks its command words
   instead of a path, and `todo` is the ninth and takes neither. Two ways
   around it remain. A credential under a name the tables do
   not carry is still read. And (`credentialInCommand`, `src/tool.zig:1222`) tokenizes the
   command instead of parsing a shell, so a command that assembles a path at run time
   reaches the file. The run's own keys, the case that mattered most, are closed
   structurally rather than textually: no tool subprocess inherits them
   (`secret_env_vars`, `src/main.zig:2195`).
3. **A named CA bundle is trusted without a policy.** `MICROAGENT_CA_BUNDLE`,
   `SSL_CERT_FILE` and `--ca-bundle` add whatever the file holds to the trust store of the
   provider connection and of the release download (`loadCaBundle`, `src/net.zig:88`;
   `src/main.zig:477`; `run`, `src/update.zig:566`). A bundle naming one attacker-issued root is a
   machine in the middle for both, and the sha256 sidecar it serves hashes as published, so
   the updater installs what it was handed. A successfully loaded bundle replaces the system store; an unreadable or empty bundle
   is reported and falls back to the system store.
4. **No host policy on `base_url`, only a scheme policy.** The key never goes out over
   plaintext `http` off loopback, but `MICROAGENT_BASE_URL` or `--base-url` may name any
   `https` host, and the key follows. A poisoned environment variable turns a review run
   into a key handoff to whoever answers on that name.
5. **The tools are not confined to the working tree by default.** `read`, `write`, `edit` and `multi_edit` take and
   follow an absolute path; (`writeFileAtomic`, `src/tool.zig:2292`) follows a symlink
   before writing; `ast --rewrite` applies its replacement to every match
   (`toolAst`, `src/tool.zig:2659`). When sandbox mode is enabled (`[sandbox] enabled = true` in config),
   in-process path checks refuse `write`, `edit`, `multi_edit` and an `ast --rewrite` outside writable
   roots, and on Linux (kernel 5.13+) Landlock rules, or on macOS a Seatbelt profile, confine
   filesystem modifications for microagent and all
   spawned subprocesses. `bash` is outside both halves: it is confined only by the deny list and by
   whatever the model is asked not to do.
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
   ceiling, as an unset `--budget` means no deadline (`optionalCeiling`, `src/main.zig:1708`). The check runs before a turn starts (`run`, `src/main.zig:2841`), so the
   provider never sees a request the run has already priced itself out of, and the turn
   that reaches the ceiling is the one that finishes. A run started without it, by a prompt
   or a harness that chose no ceilings, is bounded only by what the conversation happens to cost.
   Under `--repl` even a ceiling that was set bounds one prompt rather than the whole session
   (gap 14).
9. **The audit trail is stderr, and it names a call without its arguments.** Every dispatched
   call prints two lines: the gutter line naming the tool and one identifying argument
   (`noteToolCall`, `src/tool.zig:1004`), then the outcome the run read back from the call
   itself and how long it took, on the run's own clock (`noteToolOutcome`, `src/main.zig:4087`;
   the classification is `resultFailed`, `src/tool.zig:3151`). What is still missing is what an
   investigation needs and that line cannot carry: there is no timestamp on it, no full argument
   list, and the session log records token counters, the working directory and the finish reason
   rather than which commands ran (`writeRecord`, `src/session.zig:661`). A reader holding the
   line has the tool's name, one argument clipped to 120 bytes
   (`max_detail_bytes`, `src/tool.zig:989`), `ok`/`FAILED`/`not run`, and a duration.
10. **A symlinked install can point anywhere.** `replaceBinary` follows the link
    (`replaceBinary`, `src/update.zig:458`, through `net.resolveSymlinkTarget`, `src/net.zig:365`). A link planted in a directory on the
    operator's `PATH` redirects the write, and `write`, `edit` and `multi_edit` follow links the same way.
11. **A config file can redirect the system prompt.** `system_prompt_extra` in the config
    file is appended to the system prompt (`loadConfig`, `src/main.zig:2280`; `systemText`, `src/main.zig:959`),
    up to 16 KB (`max_system_prompt_extra_bytes`, `src/config.zig:63`). The file is
    operator-supplied and capped at 64 KB (`max_config_bytes`, `src/main.zig:186`), but
    nothing in it is sandboxed, and it reaches the provider on every turn like any other
    prompt text.
12. **The stall timeout has a floor and no ceiling.** `MICROAGENT_STALL_TIMEOUT` and
    `--stall-timeout` go through `ceiling`, `src/main.zig:1543`, which refuses zero and
    nothing else, so a century is accepted as the request's I/O deadline
    (`withStallTimeout`, `src/main.zig:3381`). The bound meant to stop a silent provider
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
14. **`--repl` makes the ceilings per prompt, and keeps the process alive between them.** The
    spend ceiling, the wall-clock budget and the turn ceiling are read into `Options` once in
    (`runMain`, `src/main.zig:445`) and `run` takes them by value (`run`, `src/main.zig:2841`), so
    a fresh line resets all three, and the loop in `runMain` starts another run on the same
    conversation. `--max-spend-tokens 100000` therefore bounds a prompt, not a session: an
    operator who set it to stop a runaway, and then left the REPL open over a long task, gets a
    run that bills per prompt rather than one that stops. This is gap 8 seen from the other side,
    and it is a property of a mode the operator chose. The control that does hold is that a
    ceiling-cut prompt ends the session rather than silently starting the next one, so the exit
    status a script reads is the one the last prompt earned.
15. **A configured MCP server writes to the operator's terminal unescaped.** Every other
    untrusted byte this program prints goes through `toolCallLine`, `src/tool.zig:1020`, or
    `terminalSafe`, `src/tool.zig:1071`, but a stdio MCP server's stderr is inherited rather
    than piped (`spawnOne`, `src/mcp.zig:1814`, at `src/mcp.zig:1854`), so the escape
    sequences, the terminal queries and the repainting a hostile or compromised server writes
    reach the terminal at whatever length it likes, with nothing between them and the
    operator. A pipe nobody drains is a server that blocks, which is the stated reason for
    inheriting; the cost is that this program's own untrusted-byte discipline stops at the
    child's stderr. The exposure is the operator's own configured server, and a server is a
    program the operator chose to trust with the filesystem already (boundary 8), so this
    carries the same trust a `bash` command does rather than a new one. What it does remove
    is a control this program holds everywhere else: a hostile `[[mcp]]` entry is the only
    way a run of this code can repaint a terminal.
16. **The interrupt table is a fixed 64 slots, and a run that fills it is refused every
    later child.** A stdio MCP server holds its slot for the length of the run rather than
    for one call (`child_groups`, `src/tool.zig:291`), and a tool call holds one only while
    its subprocess runs. A config naming more than 64 `command` servers, or a long run whose
    live children and servers add up past 64, reaches a table with no free slot
    (`max_child_groups`, `src/tool.zig:290`). After that every new `bash` fails with the
    stdlib's "no system resources left" (`runCapped`, `src/tool.zig:2854`, at
    `src/tool.zig:2871`) and every new stdio server is named on stderr and skipped
    (`spawnOne`, `src/mcp.zig:1814`, at `src/mcp.zig:1878`), so the tools the model is
    still offered stop answering. Nothing here is attacker-chosen without a write to the
    config file or the environment, and the table is a correctness choice, not a quota, so
    this is a capacity limit the operator can reach rather than a hostile-input path; it is
    on the list because a run that hits it looks like a provider or a model failure rather
    than what it is, and because the slot it needs to stop a child is the same one a dead
    server used to hold (the reap the mitigation table names is what keeps it free).

## Abuse cases

Each is a scenario, evidenced by the code path that enables it. None has been attempted.

- **A poisoned test fixture.** A repository contains a fixture whose text tells the agent
  to run a command. The model reads it with `read` (`toolRead`, `src/tool.zig:2046`) and,
  through `bash` (`toolBash`, `src/tool.zig:1476`), the command runs as the operator. The
  agent cannot tell file content from operator instruction. The prompt tells it to report
  such a file instead, and a persuasive enough file can argue with that.
- **A hostile endpoint.** With `--base-url` pointed at an `https` server the attacker
  controls, the key arrives in the `authorization` header (`authHeaders`, `src/main.zig:3370`) and the reply decides every later tool call. The scheme check
  passes, because the attacker serves `https`.
- **A symlink on the update path, or in the tree.** A link named `microagent` earlier on
  `PATH` is followed at install time (`replaceBinary`, `src/update.zig:458`). A link beside a source file
  redirects a `write` or an `edit` (`resolveSymlinkTarget` call in `writeFileAtomic`, `src/tool.zig:2292`), so the run changes a file the operator never named.
- **Scraping through the harness.** `read` has no path restriction, so a run over a
  directory holding credentials under names the tables do not carry reads them and,
  through the model, can send them off the machine. There is no per-run file budget
  either, only the 4 MB per read (`max_read_bytes`, `src/tool.zig:37`).
- **A runaway bill.** `--max-turns` at its ceiling and a conversation that grows to 400 KB
  before compaction (`conversation_soft_limit`, `src/conversation.zig:22`; `compactMessages`, `src/conversation.zig:207`) cost real tokens, with `max_tokens` bounding each turn. A run
  started without `--max-spend-tokens` has nothing bounding the whole run: the turn loop
  asks the provider again on its own schedule (`run`, `src/main.zig:2841`). Under `--repl` the same
  holds per prompt rather than per run, so a session of twenty prompts can cost twenty times a
  ceiling the operator set once (`run`, `src/main.zig:2841`; gap 14).
- **A REPL left open on a conversation the model has already read secrets out of.** Every line
  after the first is appended to a conversation whose earlier tool results are still in each
  request body (`replPrompt`, `src/main.zig:691`). Whatever a run read out of the tree is sent
  again on every line typed after it, so the longer the session runs, the more of it is
  re-sent. The line cap bounds a prompt, not the session.
- **A trust anchor from the environment.** A run started with `MICROAGENT_CA_BUNDLE`
  pointing at an attacker's file terminates both connections the run makes: the provider
  request that carries the key (`authHeaders`, `src/main.zig:3370`, `streamChatOnce`, `src/main.zig:3568`) and the release download `update`
  performs (`run`, `src/update.zig:566`). Nothing checks what the file certifies, so a
  certificate naming the attacker's host is enough.
- **A poisoned task container.** The Harbor adapter hands the provider key to every task
  container it starts (`api_key`, [microagent_agent.py:143](../integrations/harbor/microagent_agent.py)),
  so a task written by a third party holds the key for the length of its run.
- **Trust placed in the model's own bookkeeping.** A run that edited the tree and never ran
  a test is asked once, in prose, to verify (`verify_push`, `src/main.zig:1011`). "Ran a
  test" is detected by a substring match over the tool call's arguments (`isTestRun`, `src/main.zig:3026`). It is a quality prompt, not a control: a command that runs a test
  without naming one of the listed runners is invisible to it, and no refusal follows
  either way. What counts as an edit is read from the call's own arguments, so `ast`
  counts for `--rewrite` and not for a search (`isEdit`, `src/main.zig:3066`). A run that
  changed the tree with a tool the list does not carry is asked nothing.

## Response readiness

Note only; not built here.

- Tool activity is two stderr lines per call: the gutter line
  (`noteToolCall`, `src/tool.zig:1004`) and an outcome line naming `ok`, `FAILED` or
  `not run` with the call's elapsed milliseconds
  (`noteToolOutcome`, `src/main.zig:4087`). Neither carries a wall-clock timestamp, the
  call id, or the full argument list, and the session log keeps none of it either
  (`writeRecord`, `src/session.zig:661`): it records token counters, the working directory
  and the finish reason. Reconstructing *which* commands a run issued, and when, still has
  to start from the working tree rather than from a log. The outcome word is read back from
  the call's own answer rather than from a status the tool reports
  (`resultFailed`, `src/tool.zig:3151`), so it names a tool whose output happens to open with
  a refusal string as a failure, which errs toward reporting a call that worked.
- There is no `SECURITY.md`. The README's Status section ([README.md](../README.md#status))
  points here and makes no claim this document contradicts. The two supported-versions
  statements ([usage.md](usage.md#versioning); [CHANGELOG.md:10](../CHANGELOG.md)) agree with each other
  and with the release workflow: only the latest release is supported, with no backport
  window. There is no disclosure contact and no documented path from a reported
  vulnerability to a shipped fix, and this document does not invent one.
- [CHANGELOG.md](../CHANGELOG.md) records every change that alters what a run does: the
  closest thing to a public record of behavior changes.
