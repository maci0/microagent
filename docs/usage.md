# Usage reference

Everything a run reads and everything it writes. The [README](../README.md) is the short version.

- [Quick start](#quick-start)
- [Flags and environment](#flags-and-environment)
- [How values resolve](#how-values-resolve)
- [Providers and keys](#providers-and-keys)
- [Config file](#config-file): [reply style](#reply-style), [skills](#skills), [MCP servers](#mcp-servers)
- [Tools](#tools)
- [Output](#output): [stdout](#stdout), [exit status](#exit-status), [session log](#session-log)
- [Failure handling](#failure-handling)
- [Driving it from gauntlet](#driving-it-from-gauntlet)
- [Update](#update)
- [Versioning](#versioning)

## Quick start

```sh
export MICROAGENT_API_KEY=sk-or-...             # or OPENAI_API_KEY / OPENROUTER_API_KEY / DEEPSEEK_API_KEY
export MICROAGENT_BASE_URL=https://openrouter.ai/api/v1
export MICROAGENT_MODEL=deepseek/deepseek-v4-flash

microagent -p "fix the failing test and run it"
```

The prompt may also be the last bare argument, so `microagent "fix the failing test"` is the same run.

## Flags and environment

`microagent --help`, verbatim:

```
microagent - tiny OpenAI-compatible coding agent

usage: microagent [options] "<prompt>"

  -p, --print <prompt>   task to run (also accepted as a bare argument)
  -m, --model <model>    model id (env MICROAGENT_MODEL, default
                         deepseek/deepseek-v4-flash)
  -b, --base-url <url>   OpenAI-compatible base url (env
                         MICROAGENT_BASE_URL, default https://openrouter.ai/api/v1);
                         https, or http on loopback, because the api
                         key goes to it in the clear otherwise
  -k, --api-key <key>    api key (env MICROAGENT_API_KEY, OPENAI_API_KEY,
                         OPENROUTER_API_KEY, DEEPSEEK_API_KEY). The key
                         goes to the base url, so name a base url from
                         the same provider as the key: the default is
                         openrouter.ai, and a run that leaves it there
                         sends an OPENAI_API_KEY or DEEPSEEK_API_KEY to
                         openrouter and says so on stderr
      --max-turns <n>    tool-loop turn ceiling, at least 1
                         (env MICROAGENT_MAX_TURNS, default 100)
      --stall-timeout <s>  seconds the response socket may stay silent
                         before the read fails
                         (env MICROAGENT_STALL_TIMEOUT, default 120)
      --max-tokens <n>   max_tokens sent to the provider: the ceiling on
                         one response's generated tokens, at least 1
                         (env MICROAGENT_MAX_TOKENS, default 65536)
      --config <file>    TOML config: reply style, skills and MCP
                         servers (env MICROAGENT_CONFIG, default
                         ~/.microagent/config.toml)
      --ca-bundle <file>
                         PEM file to trust instead of the system store
                         (env MICROAGENT_CA_BUNDLE, SSL_CERT_FILE). Needed in
                         images that ship no ca-certificates.
      --budget <seconds>
                         stop starting turns after this long, and say so.
                         At least 1; leaving it out is what says "no
                         budget". The last turn it takes may run
                         5 minutes past it; a turn cut off there is
                         discarded, not half-applied
                         (env MICROAGENT_BUDGET_SECONDS)
      --max-spend-tokens <n>
                         stop starting turns once the run has billed
                         this many tokens, prompt and completion
                         together. At least 1; leaving it out is what
                         says "no ceiling", the way an unset --budget
                         says "no deadline". The turn that reaches the
                         ceiling is the one that finishes, and the run
                         says on stderr once 80% of it is spent
                         (env MICROAGENT_MAX_SPEND_TOKENS)
      --reasoning-effort <level>
                         reasoning.effort sent to the provider: minimal,
                         low, medium, high, or none to disable (env
                         MICROAGENT_REASONING_EFFORT)
  -h, --help             this text ("help" as the only argument too)
  -V, --version          version

every long flag also takes --flag=value. A flag wins over the environment
variable for the same option. A bare -- ends the flags, so a task that
begins with a dash is passed after it. A bare "help" asks for this text
when the prompt is still empty, the way "microagent update help" does; any
other bare word, or a value of --print, is a task. A second bare word is
the one thing this does not read as a task: two prompts are a usage error.

reply style (MICROAGENT_CAVEMAN / MICROAGENT_PONYTAIL, or the same two keys
in the config named above):
  MICROAGENT_CAVEMAN     how terse the reply is: off, lite, full, ultra,
                         wenyan-lite, wenyan-full, wenyan-ultra
                         (default ultra)
  MICROAGENT_PONYTAIL    how lazy the code is: off, lite, full, ultra
                         (default full)

session log:
  MICROAGENT_SESSION_DIR where the per-response JSONL session log goes
                         (default ~/.microagent/sessions; empty writes none)

skills (the `skills` list in the config, or MICROAGENT_SKILLS as a
colon-separated list that wins over it; default $HOME/.microagent/skills):
  a skill is a directory holding SKILL.md, with an optional frontmatter
  block naming it and saying when it applies. The run lists what it found
  in the system prompt, and the model loads one body at a time with the
  `skill` tool, so a skill the task never needs costs the listing alone.
  Skills are instructions the operator installed: nothing under the
  working directory is read unless the config or the variable names it.

MCP servers (`[[mcp]]` tables in the config):
  each table names one server, with `name` and `command` required and
  `args` (a list of strings) and `env` (an inline table) optional, e.g.
  [[mcp]] name = "fs" command = "npx" args = ["-y", "server-fs", "/tmp"].
  Every server is run over stdio and its tools are offered to the model as
  mcp__<server>__<tool>, on the same deadline as any other tool. A server
  that cannot start or answer is reported on stderr and skipped.

subcommand:
  update [--check] [--repo owner/name]
                         replace this binary with the latest GitHub
                         release after verifying its .sha256 sidecar
                         (--check only reports; GITHUB_TOKEN lifts the
                         API rate limit). "microagent update --help" has
                         the details.

examples:
  microagent "fix the failing test in src/net.zig and run it"
  microagent --max-turns 20 "review the diff and stop"
  microagent --print "$(cat task.txt)"
  microagent -- "explain why -Werror is failing in src/net.zig"

exit status: 0 the run finished, 1 the run failed, 2 the command line was
wrong, 3 the run stopped without an answer (--max-turns, --max-spend-tokens,
or a budget that ran out, or a last response that carried no text, was cut
at --max-tokens, or the provider stopped generating it) so the answer on
stdout is a prefix of the work rather than an answer, 130 interrupted
(Ctrl+C or kill), which takes the tool subprocess with it.

output: stdout carries the model's text and one JSON line per response,
{"type":"usage","usage":{...}}, and nothing else. stderr carries the tool
gutter, the notes and every error, so a script reading stdout gets the
answer and the token counters.

MDEBUG=1                 trace a stuck stream on stderr, and print the
                         configuration this run resolved: model, base
                         url, ceilings, style levels, the style config
                         file that was read, and the name of the source
                         the api key came from, never the key.
                         0, off, no, false and an empty value all leave
                         it off.

A variable set to an empty string is not a value: MICROAGENT_MODEL,
MICROAGENT_BASE_URL, MICROAGENT_REASONING_EFFORT, MICROAGENT_BUDGET_SECONDS,
MICROAGENT_MAX_SPEND_TOKENS, MICROAGENT_MAX_TURNS, MICROAGENT_MAX_TOKENS,
MICROAGENT_STALL_TIMEOUT and MDEBUG keep their defaults, and
MICROAGENT_CA_BUNDLE, the four api key variables and
MICROAGENT_CAVEMAN/PONYTAIL fall through to whatever comes next.
MICROAGENT_CONFIG, MICROAGENT_SESSION_DIR and MICROAGENT_SKILLS are the
three where empty means off: no style file, no session log, no skills. HOME is trimmed like the rest, and an
empty one is no home rather than a path off the root.
```

## How values resolve

A flag wins over its environment variable, and the environment wins over the config file. Every
value is checked where it is set, so a mistyped level, a ceiling of zero or a non-numeric budget is
refused before the first request rather than becoming a 400 or an empty run.

A variable set to an empty string is not a value:
`MICROAGENT_MODEL`, `MICROAGENT_BASE_URL`, `MICROAGENT_REASONING_EFFORT`,
`MICROAGENT_BUDGET_SECONDS`, `MICROAGENT_MAX_SPEND_TOKENS`, `MICROAGENT_MAX_TURNS`,
`MICROAGENT_MAX_TOKENS`, `MICROAGENT_STALL_TIMEOUT` and `MDEBUG` keep their defaults, the four api
key variables fall through to whatever comes next, `MICROAGENT_CA_BUNDLE` falls through to
`SSL_CERT_FILE`, and `MICROAGENT_CAVEMAN`/`MICROAGENT_PONYTAIL` fall through to the config file.
Three variables are the exception: `MICROAGENT_CONFIG`, `MICROAGENT_SESSION_DIR` and
`MICROAGENT_SKILLS` read empty as off, so no style file, no session log and no skills.

Every variable is trimmed before it is read, `HOME` included, and one holding only whitespace reads
as empty. A wrapper that fills the environment from a file exports that file's trailing newline, and
untrimmed it would break each option differently: an api key becomes an `Authorization` header with
a byte a header may not hold, a base url stops parsing, a session directory names a directory no
monitor looks in, and a `HOME` ending in a newline moves every default path
(`~/.microagent/config.toml`, the session store, the key file) somewhere that does not exist. An
empty `HOME` is no home rather than a path off the root.

`MDEBUG=1` prints the configuration the run resolved: model, base url (credentials in it redacted),
the ceilings, the level each style key took, the config file that was read, and the name of the
variable or file the api key came from. The key itself is never printed. Each option has up to three
sources, and this is how you tell which one answered.

## Providers and keys

Any OpenAI-compatible endpoint works: OpenRouter, DeepSeek, OpenAI, vLLM, LiteLLM, Z.AI.
`deepseek/deepseek-v4-flash` and `stealth/space-bunny-alpha` (OpenRouter) were used to verify it end
to end; see [benchmark.md](benchmark.md).

The key is looked up in `--api-key`, then `MICROAGENT_API_KEY`, `OPENAI_API_KEY`,
`OPENROUTER_API_KEY` and `DEEPSEEK_API_KEY`. With none of them set, `~/.secrets/openrouter` is read
as a last resort; an empty file there is named on stderr rather than passed off as no key.

The key goes to the base url in an `Authorization` header on every request. Two consequences:

- A run that sets no base url talks to `https://openrouter.ai/api/v1` with
  `deepseek/deepseek-v4-flash`, so a key read from `OPENAI_API_KEY` or `DEEPSEEK_API_KEY` goes to
  OpenRouter. The run says so on stderr before the first request. A base url named with `--base-url`
  or `MICROAGENT_BASE_URL` is where the key goes, including a self-hosted gateway that accepts a key
  from any provider.
- A plain `http://` base url is refused unless the host is loopback (`localhost`, `127.0.0.0/8`,
  `::1`): a local gateway is the one plaintext case with no network path to intercept. A base url
  that does not parse is refused as a typo before that check runs.

`--ca-bundle` (or `MICROAGENT_CA_BUNDLE`, else `SSL_CERT_FILE`) names a PEM file to trust instead of
the system store, for container images that ship no `ca-certificates`.

## Config file

One TOML file carries the reply style, the skill roots and the MCP servers. It is `--config`, else
`MICROAGENT_CONFIG`, else `~/.microagent/config.toml`. [`config.example.toml`](../config.example.toml)
is a commented template.

A missing file means the defaults. A file that cannot be read, is a directory, or is over the 64 KB
cap is named on stderr and the run continues on the defaults. An unrecognized level, and a key the
file format does not define, are reported on stderr with that key's default kept, so a misspelled
`caveman` cannot leave the default in force quietly.

### Reply style

Two prompt-level knobs. Neither touches the tools or the request shape: both are text appended to
the system prompt, and the conversation stays the plain OpenAI message array.

```toml
caveman  = "ultra"   # how terse the reply is
ponytail = "full"    # how lazy the code is
```

The keys may also sit under a `[style]` table, and `#` comments are fine. That is the whole style
surface, so these lines are read as `key = "value"` rather than through a full TOML parser.

- **`caveman`** compresses the prose the agent writes back: `off`, `lite`, `full`, `ultra`, plus
  `wenyan-lite`, `wenyan-full` and `wenyan-ultra`, which reply in classical Chinese (a bare `wenyan`
  is `wenyan-full`). Default `ultra`: a coding agent is judged on the diff, and every paragraph about
  it is re-sent on every later turn. Technical terms, code, commands, paths and exact error strings
  are never compressed, a negation is never dropped, and security warnings stay in plain English.
- **`ponytail`** biases what the agent builds: `off`, `lite`, `full`, `ultra`. Reuse a helper the
  repository already has before writing a new one, prefer the standard library and the platform over
  a dependency, and make the smallest diff that fixes the root cause. Default `full`. Never at the
  cost of input validation at a trust boundary, error handling that prevents data loss, security,
  accessibility, or anything the task asks for.

`MICROAGENT_CAVEMAN` and `MICROAGENT_PONYTAIL` set a level for one run and win over the file. With
both at `off`, the system prompt is exactly the one the harness sent before styles existed.

### Skills

A skill is a directory holding a `SKILL.md`: an optional frontmatter block naming it and saying when
it applies, then the instructions.

```
~/.microagent/skills/pdf/SKILL.md
---
name: pdf
description: Fill, split and extract text from PDF files
---
Use `pdftotext` for extraction and `qpdf` for splitting...
```

The run lists every skill it found in the system prompt and offers a `skill` tool; the model loads
one body at a time when a task matches. A body is kilobytes and the conversation is re-sent every
turn, so a skill the task never needs costs only its one listing line. The listing is bounded, and
skills past the bound are counted rather than named.

The name defaults to the directory name and the description to the body's first non-empty line. A
name may hold only letters, digits, dot, dash and underscore, since the model spells it back in a
tool call. A file without frontmatter still works, and other keys in the block are ignored.

The roots are the config's `skills` list, else `$HOME/.microagent/skills`:

```toml
skills = ["./skills", "~/.microagent/skills"]   # [] turns skills off
```

`MICROAGENT_SKILLS` (colon-separated) names the roots for one run and wins over the file; an empty
value turns skills off. A relative path resolves against the working directory. The working
directory is deliberately not a default root: a `SKILL.md` in a repository under review was written
by whoever wrote that repository, and a skill body is text the model is told to follow. Naming a
repository's directory is the operator saying those bytes are instructions.

### MCP servers

An MCP server is a child process speaking JSON-RPC over stdio. One `[[mcp]]` table declares one:

```toml
[[mcp]]
name    = "fs"
command = "npx"
args    = ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"]
env     = { LOG = "debug" }
```

`name` and `command` are required; a table missing either is named on stderr and skipped. Every
server is started before the first request and asked for its tool list, and each tool is offered to
the model as `mcp__<server>__<tool>` with the server's own `inputSchema`. A call is a `tools/call`,
and the text the server returns is the tool result, on the same deadline as any other tool.

A server that cannot start, exits during the handshake, or refuses a call is reported on stderr and
skipped: one broken entry costs that entry, not the run. The server's stderr is inherited, since
that is where MCP servers write diagnostics. Its environment is the scrubbed one tool subprocesses
get plus the entry's `env`, so it never sees a provider key.

Server and tool names may hold only letters, digits, dot, dash and underscore, and a name holding
`__` is refused: the double underscore separates the three parts of an exposed name.

## Tools

Seven built-in tools, each a thin wrapper over a program you already have:

| tool | what it does |
| --- | --- |
| `bash` | `/bin/sh -c`, 120 s default timeout (the model may ask for up to 600 s), output capped at 24 KB. A command naming a credentials file is refused, and the child inherits no provider credential. |
| `read` | read a file, with optional line offset and limit. Refuses credentials (`.env`, key and keystore files, anything under `.secrets` or `.ssh`), including a symlink to one. |
| `write` | create or overwrite a file, creating parents. Refuses a credentials path, and a call with no `content`. |
| `edit` | exact string replacement. Refuses a credentials path, an ambiguous match unless `replace_all`, and an edit that would leave `old_string` matchable in the result, so a repeated call cannot apply the change twice. |
| `search` | `rg --line-number --no-heading`, optional glob; credentials files excluded. |
| `ast` | `ast-grep run` for a structural match, or `--rewrite --update-all` to apply one; credentials files excluded. |
| `git` | read-only `status`, `diff`, `log`, `show`, `blame`, capped at 400 lines; a credentials path is refused. |

A config can add two more kinds: the `skill` tool when a skills root held something, and one
`mcp__<server>__<tool>` per tool an MCP server reported.

`search` needs `rg`, `ast` needs `ast-grep`, and `git` needs `git` on `PATH`. A stock macOS ships
only the last, so a machine missing the others is told which program is missing and how to install
it. The system prompt tells the model to search with ripgrep and rewrite with `ast-grep` rather than
by hand, and to use the machine's other deterministic tools through `bash` where they fit, such as
[semcode](https://github.com/facebookexperimental/semcode) for semantic queries over an indexed
C/C++/Rust tree (`semcode-index -s .` first, then `semcode -q "callers parse_config"`).

**Tool output is untrusted.** Everything a tool returns (a file, a diff, a build log) goes back into
the prompt as a `tool` message, and the system prompt says it is data. A repository that ships a
file telling the model to run something is data the run reports, not an instruction it follows.

**Credentials stay out of the conversation.** The conversation is re-sent to the provider every
turn, so a `read` of `.env`, a `.pem`, an `id_ed25519` or `$HOME/.secrets/openrouter` would ship a
key to a third party and keep shipping it. `read` refuses those names, `search` and `ast` leave them
out of results, `git` refuses one named as a path, `bash` refuses a command whose words name one,
and `write` and `edit` refuse to replace one. The name is checked twice, on the path the model sent
and on the path a symlink resolves to, so a link committed under an ordinary name does not leak the
file it points at. The run's own keys are removed structurally: every tool subprocess gets the
environment minus the variables this binary sends in an `Authorization` header, so `bash: env` has
nothing to print. What remains open is the name rule itself: a credential the tables do not
recognize, and a path a command assembles at run time, are still read. See
[threat-model.md](threat-model.md).

**Tool calls run once.** The stream is delivered at least once, so a turn's tool calls are
deduplicated by the id the provider gave them before anything runs: a relay that reconnects replays
frames, and a replayed call is a `bash` run twice. The first delivery runs, the repeat is named on
stderr, and two identical calls with different ids are two calls.

## Output

### stdout

stdout carries the model's own text, one JSON usage line per response, and nothing else:

```json
{"type":"usage","usage":{"prompt_tokens":910,"cached_tokens":832,"completion_tokens":18,"reasoning_tokens":0,"total_tokens":928}}
```

Counters are cumulative for the run, which is the shape gauntlet's usage reader takes its maximum
from. Tool activity goes to stderr as a one-line gutter (`⏺ read src/main.zig`), with control
characters in a path or command written as `\xNN` so a line stays one line.

`cached_tokens` is the part of the prompt the provider served from its cache, read from whichever of
`prompt_tokens_details.cached_tokens`, `prompt_cache_hit_tokens` or `cache_read_input_tokens` the
endpoint sends. The conversation is re-sent every turn byte for byte (no message dropped, reordered
or re-spelled, system prompt and tool schema fixed), so the prefix stays cacheable and a turn pays
full price only for what it added. On a multi-turn run the counter should climb with the
conversation.

Two bounds keep a long run from re-sending without limit:

- **Compaction.** Past 400 KB of conversation, the content of the oldest large tool results is
  replaced with `[earlier tool output elided: N bytes]`, leaving everything ahead of the first one
  untouched. The system prompt names the marker as the harness's own and tells the model to rerun
  the tool if it needs the output. `cached_tokens` dips on the turn a compaction lands on.
- **Per-turn cap.** One turn's tool results stop at 256 KB (64 calls at the 24 KB per-result cap
  would pass it four times over). Past it a result is replaced with `[tool output not carried: ...]`:
  the call still ran, and the model is told the output is gone rather than left to read an empty
  result as a tool that found nothing.

### Exit status

| status | meaning |
| --- | --- |
| 0 | the run finished |
| 1 | the run failed |
| 2 | wrong command line |
| 3 | stopped without an answer: `--max-turns`, `--max-spend-tokens` or `--budget` reached, or the last response carried no text, was cut at `--max-tokens`, or the provider stopped generating it. stdout is a prefix of the work, not an answer. |
| 130 | interrupted (Ctrl+C or kill), taking the tool subprocess with it |

A wrong flag prints the reason and the full help on stderr, so a script reading stdout gets nothing
from a failed invocation.

### Session log

Each run appends one JSONL record per model response to `~/.microagent/sessions/<unix-ns>.jsonl`, so
a monitor can follow a run while it is going. `MICROAGENT_SESSION_DIR` moves the store and an empty
value turns it off. A run that finds its name taken writes `-1`, `-2`, ... beside it rather than over
it. The store keeps the 200 most recent runs and prunes older ones, and it drops any log older than 30
days whatever the count says, so a machine that runs rarely does not keep every run it has ever done.

```json
{"ts":1790608347342,"cwd":"/home/you/Desktop/Projects/microagent","model":"deepseek/deepseek-v4-flash","finish_reason":"stop","served_model":"deepseek/deepseek-v4-flash-0726","fingerprint":"fp_9c1e","elapsed_ms":1448,"usage":{"prompt_tokens":998,"cached_tokens":896,"completion_tokens":19,"reasoning_tokens":16,"total_tokens":1017}}
```

| key | meaning |
| --- | --- |
| `usage` | this response's own counters, not the run's cumulative ones |
| `cwd` | the directory the run works in |
| `finish_reason` | why the provider stopped. `length` means the response was cut at `--max-tokens` and the run says so on stderr; the empty string is a stream that carried no reason. |
| `model` / `served_model` / `fingerprint` | what the run asked for, what the provider says answered, and the weights fingerprint it reported. A gateway routes a name to whichever snapshot it holds that week, so two runs are comparable only when these match. Empty when the stream named none. |
| `elapsed_ms` | the model's time on this response, for tokens per second without tool time mixed in. Measured on a clock that stops while the machine is suspended (`--budget`, by contrast, counts suspend: it bounds wall time). |

A directory that cannot be created, or a log that cannot be opened or written, is named on stderr
and the rest of the run goes unrecorded. Nothing in the log is prompt or output text.
[toktop](https://github.com/maci0/toktop) reads this store by default, and the keys are the ordinary
OpenAI ones plus `cwd`, so any reader of agent transcripts works.

## Failure handling

- **Transient failures retry.** A 408, 409, 425, 429, any 5xx, or a connection that dies before the
  request reached the provider is retried twice, with 1 s and 2 s of backoff (or the provider's
  `Retry-After`, capped at 120 s), before the run exits non-zero. Any other rejection (401, 404) fails
  at once. A 400 does too, with one exception: when `--reasoning-effort` is set, the request is sent
  once more without the `reasoning` field, since some providers refuse that field rather than the
  request.
- **A sent turn is never re-sent.** When the whole turn was sent and no response arrives, the
  provider may already have generated and billed the completion, so the run ends with the connection
  error on stderr rather than paying twice. A failure the provider reports part way through a stream
  is named in its own words and ends the run for the same reason: whatever reached stdout is a
  prefix of an answer it abandoned.
- **Every request carries `max_tokens`**, so a model that fails to stop is not billed until something
  else stops it. `--max-turns` counts turns, not tokens, and a turn re-sends the whole conversation,
  so `--max-spend-tokens` is the ceiling on what a run spends.
- **`--budget`** stops starting turns after the given seconds, then takes one last turn to land an
  edit, which may run up to 5 minutes past it. A turn cut off there is discarded, not half-applied.
- **No session resume.** gauntlet's `--retries` covers a whole review, and a missing feature is
  cheaper than a half-working one.

## Driving it from gauntlet

Recent [gauntlet](https://github.com/maci0/gauntlet) builds know microagent as a built-in agent:
`gauntlet doctor` lists it and `gauntlet -a microagent -r quick --once` needs no configuration. An
older release that refuses it as an unknown tool needs one entry in `~/.gauntlet/agents.json`:

```json
{
  "microagent": {
    "argv": ["microagent", "{prompt}"],
    "model": ["--model", "{model}"],
    "note": "microagent: tiny zig OpenAI-compatible coding agent"
  }
}
```

Delete it once gauntlet ships the built-in: a definition file naming a built-in agent is refused at
startup. Define the prompt as the bare last argument, not `["microagent", "-p", "{prompt}"]`: a
custom-agent definition inserts the model flags right after `-p`, which would hand `--model` to
`-p`.

```sh
gauntlet doctor                       # microagent should show as installed
gauntlet -a microagent -r quick --once
gauntlet -a microagent:deepseek/deepseek-v4-flash -j 4
MICROAGENT_BUDGET_SECONDS=600 gauntlet -a microagent -r quick --once
```

Set a budget below gauntlet's `-t` timeout: a review killed at the ceiling with an untouched tree is
worth nothing, and one that stops deliberately still has the model's diff. A review gauntlet scores
"Passed" has not necessarily landed a diff; score with `git diff --numstat` and a real check, the way
`bench/gauntlet.sh` does. Per-model outcomes are in [benchmark.md](benchmark.md#usefulness).

Usage is always machine-readable, so no `stream` flags are needed, and no `usage.roots` entry is
required.

## Update

```sh
microagent update                         # replace this binary with the latest release
microagent update --check                 # report the latest release, install nothing
microagent update --repo you/microagent   # track a fork
```

Each release publishes `microagent-<tag>-<triple>` for `x86_64-linux-musl`, `aarch64-linux-musl`,
`x86_64-macos` and `aarch64-macos`, each with a `.sha256` sidecar. Linux has one static musl asset
per architecture, which also runs on glibc, so a `-gnu` build updates to it. The download is checked
against its sidecar, and the running binary is replaced atomically (following a symlink to the real
file) only when the digest matches. A mismatch, a missing asset, or a release page that is not a
GitHub https URL leaves the binary untouched. `GITHUB_TOKEN` lifts the anonymous API rate limit.
Exit 1 means the check or the install failed, 2 is a usage error; `microagent update --help` has the
rest.

## Versioning

The version is `build.zig.zon` and nothing else, and [CHANGELOG.md](../CHANGELOG.md) records what
changed in each. Under `0.y`, the minor takes features, any change to what a run does by default,
and anything removed; the patch takes fixes, and upgrading a patch must not change an existing
invocation. The release workflow refuses a patch tag whose changelog section has an `Added`,
`Changed` or `Removed` entry, a section that is not the five Keep a Changelog headings once each in
order, and any tag while `## [Unreleased]` still holds entries. A breaking change to the flags, the
environment variables, or the stdout and session-log JSON gets a changelog entry naming the before
and the after. Only the latest release is supported: a fix ships in the next release, with no
backports.
