# Usage reference

Everything a run reads and everything it writes. The [README](../README.md) is the short version.

- [Quick start](#quick-start)
- [Flags and environment](#flags-and-environment)
- [How values resolve](#how-values-resolve)
- [Providers and keys](#providers-and-keys): [OpenCode Zen and Go](#opencode-zen-and-go)
- [What leaves the machine](#what-leaves-the-machine)
- [Prompt cache](#prompt-cache)
- [Config file](#config-file): [provider settings](#provider-settings), [repository instructions](#repository-instructions), [system prompt addendum](#system-prompt-addendum), [skills](#skills), [MCP servers](#mcp-servers), [tool set](#tool-set), [command filter](#command-filter), [sandbox](#sandbox)
- [Tools](#tools): [tool environment](#tool-environment)
- [Output](#output): [stdout](#stdout), [exit status](#exit-status), [session log](#session-log), [what survives](#what-survives-and-how-to-get-it-back)
- [Failure handling](#failure-handling)
- [Driving it from gauntlet](#driving-it-from-gauntlet)
- [Agent Client Protocol](#agent-client-protocol)
- [Setup](#setup)
- [Update](#update)
- [Versioning](#versioning)

## Quick start

```sh
export MICROAGENT_API_KEY=sk-...
export MICROAGENT_BASE_URL=https://api.openai.com/v1
export MICROAGENT_MODEL=gpt-4o-mini

microagent -p "fix the failing test and run it"
```

The prompt may also be the last bare argument, so `microagent "fix the failing test"` is the same run.

`microagent --repl` reads one prompt per line, keeping conversation history. An optional argument
runs as the first prompt. Blank lines are skipped; `/quit`, `/exit` or EOF exits, and `/help`
repeats the session's commands. Each input line, including
its newline, must fit in 64 KiB. Turn, time and token spending ceilings reset for each prompt;
stdout usage counters stay cumulative, and all responses share one session log. A failed or
incomplete prompt ends the REPL with the usual exit status.

## Flags and environment

`microagent --help`, verbatim:

```
microagent - tiny OpenAI-compatible coding agent

usage: microagent [options] "<prompt>"
       microagent --repl [options] ["<prompt>"]
       microagent update [-c | --check]
       microagent setup [--config <file>]
       microagent schema [command]
       microagent acp
       microagent help [setup | update | schema | acp]

      --repl             read one prompt per line; /quit or /exit or EOF
                         exits, /help lists the session's commands.
                         History is kept; ceilings reset per prompt
  -p, --print <prompt>   task to run (also accepted as a bare argument)
  -m, --model <model>    model id (env MICROAGENT_MODEL, config key
                         model, default deepseek/deepseek-v4-flash)
  -b, --base-url <url>   OpenAI-compatible base url (env
                         MICROAGENT_BASE_URL, config key base_url). One of
                         the three has to name an endpoint: there is no
                         default provider. https, or http on loopback,
                         because the api key goes to it in the clear
                         otherwise
  -k, --api-key <key>    api key (env MICROAGENT_API_KEY, config key
                         api_key; no key file is read). The key goes to
                         the base url, so name a base url from the same
                         provider as the key. A key on the
                         command line is in the process table, where any
                         user of this machine can read it; a variable or
                         a file mode 600 is not
      --max-turns <n>    tool-loop turn ceiling, at least 1
                         (env MICROAGENT_MAX_TURNS, default 1000)
      --stall-timeout <s>  seconds connection setup or a request
                         write/read may block before cancellation
                         (env MICROAGENT_STALL_TIMEOUT, default 120)
      --max-tokens <n>   max_tokens sent to the provider: the ceiling on
                         one response's generated tokens, at least 1
                         (env MICROAGENT_MAX_TOKENS, default 65536)
      --config <file>    TOML config: system prompt addendum, skills, MCP servers
                         and tools (env MICROAGENT_CONFIG, default
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
                         reasoning level sent to the provider: minimal,
                         low, medium, high, or none to disable (env
                         MICROAGENT_REASONING_EFFORT, config key reasoning_effort)
      --temperature <n>   temperature sent to the provider, 0 to 2. Left
                         out, the provider samples at its own default, so
                         two runs of one conversation are two answers;
                         0 is the one setting that repeats
                         (env MICROAGENT_TEMPERATURE)
  -o, --output <format> auto, text, or json (default auto). Before the
                         subcommand. auto stays text when stdout is not a
                         terminal, because the pipe contract is the model's
                         text. json asks schema, --version, setup and update
                         for one JSON document, and a failure's last stderr
                         line is an error envelope with the same exit
                         status. The API key is never printed
  -h, --help             this text ("help" as the only argument too)
  -V, --version          version. With -o json, one document of name and
                         version

every long flag taking a value also takes --flag=value. A flag wins over the environment
variable for the same option, and wins over one the run could not use:
MICROAGENT_MAX_TURNS=0 with --max-turns 5 is a run with five turns, and the
variable is named on stderr rather than stopping it. A bare -- ends the
flags, so a task that begins with a dash is passed after it. A bare "help"
asks for this text while the prompt is still empty; any other bare word, or
a value of --print, is a task, and so is the word "update" anywhere but
first: as the first argument it is the subcommand below, and a task of
that name is written after a flag or a --. "help update" is that
subcommand's own text, and a word after "help" that names no subcommand
is a usage error rather than this text; a second word is a usage error
too, and it names the word that names no subcommand rather than only
counting what arrived, so help update --check says --check is the one
that is wrong. A
second bare word is the one thing this does not read as a task: two prompts
are a usage error. A word that names no flag is answered with the one it
is closest to, so --modl says did you mean --model?; a word close to none
of them is reported plainly, because naming the least bad of a dozen is
worse than naming none.

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
  each table names one server, with `name` and one of `command` (a local
  server over stdio, with optional `args`, a list of strings, and `env`, an
  inline table) or `url` (a remote streamable-HTTP server, with optional
  `api_key_env`, `api_key_header` and `timeout`), e.g.
  [[mcp]] name = "fs" command = "npx" args = ["-y", "server-fs", "/tmp"].
  Its tools are offered to the model as mcp__<server>__<tool>, on the same
  deadline as any other tool. A server that cannot start, be reached or
  answer is reported on stderr and skipped.

Tools (`[tools.<name>]` tables in the config):
  `enabled = false` removes a built-in tool (bash, read, write, edit,
  multi_edit, search, ast, git, todo) from the schema and refuses its calls;
  at least one must stay on. The presets web_search, context7, grep_app and deepwiki
  are public remote MCP servers, off until a [tools.<name>] table sets `enabled = true`, and
  take `url`, `api_key_env` (the NAME of a variable holding the key), `api_key_header`
  and `timeout` (seconds). A name that is not a tool stops the run with exit
  status 2.

"setup" and "schema" are subcommands only as the first argument; "help
setup" and "help schema" print their own text. Use --print or -- for a
task of either name. schema prints the CLI Spec document and reads no
config.

subcommands:
  setup [--config <file>]
                         create a missing config from the template, then
                         ask about features and API endpoints. Enter keeps
                         current values; EOF cancels edits.
  update [-c | --check]
                         replace this binary with the latest GitHub
                         release after verifying its .sha256 sidecar
                         (--check only reports; GITHUB_TOKEN lifts the
                         API rate limit). "microagent update --help" has
                         the details.
  schema [command]       print the CLI Spec 0.3 document. No config, no
                         credentials, no network. A command path keeps
                         that command and paths that start with it.
  acp                    serve the Agent Client Protocol v1 on stdin and
                         stdout for an editor or harness client.

examples:
  microagent "fix the failing test in src/net.zig and run it"
  microagent --max-turns 20 "review the diff and stop"
  microagent --print "$(cat task.txt)"
  microagent -- "explain why -Werror is failing in src/net.zig"

exit status: 0 the run finished, 1 the run failed, 2 the command line was
wrong, 3 the run stopped without an answer (--max-turns, --max-spend-tokens,
or a budget that ran out, or a last response that carried no text, was cut
at --max-tokens or the response byte ceiling, or the provider stopped
generating it) so the answer on
stdout is a prefix of the work rather than an answer, 130 interrupted
(Ctrl+C or kill), which takes the tool subprocess with it.

output: stdout carries the model's text and one JSON line per response,
{"type":"usage","usage":{...}}, and nothing else. stderr carries the tool
gutter, the notes and every error, so a script reading stdout gets the
answer and the token counters. -o json does not re-encode this stdout.

MDEBUG=1                 trace a stuck stream on stderr, and print the
                         configuration this run resolved: model, base
                         url, ceilings, the config file that was
                         read, the skill roots, the sandbox and
                         the tools it turned off, and the
                         name of the source the api key came from, never
                         the key.
                         0, off, no, false and an empty value all leave
                         it off.

NO_COLOR, TERM=dumb     the tool gutter draws its name in bold on a
                         terminal, and in plain text everywhere else, so
                         NO_COLOR set to anything but an empty string (the
                         value is not read, only the name) or TERM=dumb
                         leaves the bold out even at a terminal

TMPDIR                   added to the sandbox writable roots whenever
                         [sandbox] enabled is true and it names an
                         absolute directory none of the roots above
                         already covers. On macOS that is where the
                         system keeps per-user scratch space; a Linux
                         host exporting it elsewhere gets the same root,
                         and one exporting it at /tmp gains nothing.

A variable set to an empty string is not a value: MICROAGENT_MODEL,
MICROAGENT_BASE_URL, MICROAGENT_REASONING_EFFORT, MICROAGENT_TEMPERATURE,
MICROAGENT_BUDGET_SECONDS,
MICROAGENT_MAX_SPEND_TOKENS, MICROAGENT_MAX_TURNS, MICROAGENT_MAX_TOKENS,
MICROAGENT_STALL_TIMEOUT, MDEBUG and NO_COLOR keep their defaults, and
MICROAGENT_CA_BUNDLE and MICROAGENT_API_KEY fall through to whatever
comes next.
MICROAGENT_CONFIG, MICROAGENT_SESSION_DIR and MICROAGENT_SKILLS are the
three where empty means off: no config file, no session log, no skills. HOME
is trimmed like the rest, and an empty one is no home rather than a path
off the root.
```

## How values resolve

A flag wins over its environment variable, and the environment wins over the config file. Every
value is checked where it is set, so a mistyped level, a ceiling of zero or a non-numeric budget is
refused before the first request rather than becoming a 400 or an empty run.

A flag also wins over a variable the run could not use, because the flag is read after the
environment. `MICROAGENT_MAX_TURNS=0 microagent --max-turns 5` is a run with five turns; the
variable is named on stderr and the run goes on. With no such flag the bad variable stops the run
as a bad argument would. The base url follows the same rule, since it is checked where the run
uses it.

A variable set to an empty string is not a value:
`MICROAGENT_MODEL`, `MICROAGENT_BASE_URL`, `MICROAGENT_REASONING_EFFORT`,
`MICROAGENT_TEMPERATURE`, `MICROAGENT_BUDGET_SECONDS`, `MICROAGENT_MAX_SPEND_TOKENS`, `MICROAGENT_MAX_TURNS`,
`MICROAGENT_MAX_TOKENS`, `MICROAGENT_STALL_TIMEOUT`, `MDEBUG` and `NO_COLOR` keep their defaults,
`MICROAGENT_API_KEY` falls through to the config file's `api_key`, and `MICROAGENT_CA_BUNDLE` falls
through to `SSL_CERT_FILE`.
Three variables are the exception: `MICROAGENT_CONFIG`, `MICROAGENT_SESSION_DIR` and
`MICROAGENT_SKILLS` read empty as off, so no config file, no session log and no skills.

Every variable is trimmed before it is read, `HOME` included, and one holding only whitespace reads
as empty, so a trailing newline a wrapper exported from a file does not end up in a header, a url
or a default path. An empty `HOME` is no home rather than a path off the root.

`MDEBUG=1` prints the configuration the run resolved, which is how you tell which of the up to three
sources answered for each option: model, base url (credentials in it redacted), the ceilings, the
config file that was read and the size of its prompt addendum, the skill roots, whether the sandbox
is on and how many roots it has, how many tools are off and how many commands are denied, and the
name of the variable or file the api key came from. The key itself is never printed.

## Providers and keys

Any OpenAI-compatible endpoint works: OpenRouter, DeepSeek, OpenAI, vLLM, LiteLLM, Z.AI.
`deepseek/deepseek-v4-flash` and `stealth/space-bunny-alpha` (OpenRouter) were used to verify it end
to end; see [benchmark.md](benchmark.md).

The key is looked up in `--api-key`, then `MICROAGENT_API_KEY`, then `api_key` in the config file.
No key file is read.

`--api-key` is the one source that is not private to this process: the command line is in the
process table for as long as the run lasts, so any user on the machine can read the key there. Use
a variable or a config file only its owner can read (`chmod 600`). A key in the config file is in
the clear on disk, in a file the `read` tool can open: keep the file out of any workspace the model
is given, or use a variable.

The key goes to the base url in an `Authorization` header on every request. Two consequences:

- A run that names no base url is refused: there is no default provider, because an endpoint decides
  whose account the tokens are billed to and the key goes there. `--base-url`, `MICROAGENT_BASE_URL`
  or `base_url` in the config file names it, including a self-hosted gateway that accepts a key from
  any provider. The model defaults to `deepseek/deepseek-v4-flash`, which most gateways accept.
- A plain `http://` base url is refused unless the host is loopback (`localhost`, `127.0.0.0/8`,
  `::1`): a local gateway is the one plaintext case with no network path to intercept. A base url
  that does not parse is refused as a typo before that check runs.

`--ca-bundle` (or `MICROAGENT_CA_BUNDLE`, else `SSL_CERT_FILE`) names a PEM file to trust instead of
the system store, for container images that ship no `ca-certificates`.

### OpenCode Zen and Go

Both gateways work with the existing Chat Completions client:

| Provider | `MICROAGENT_BASE_URL` |
| --- | --- |
| OpenCode Zen | `https://opencode.ai/zen/v1` |
| OpenCode Go | `https://opencode.ai/zen/go/v1` |

```sh
export MICROAGENT_API_KEY=your-opencode-api-key
export MICROAGENT_BASE_URL=https://opencode.ai/zen/go/v1
export MICROAGENT_MODEL=kimi-k2.6
microagent "fix the failing test and run it"
```

Use your OpenCode API key with access to the selected plan. The same settings can be entered
with `microagent setup` or written as `api_key`, `base_url` and `model` in the config file.
The client appends `/chat/completions` to the base URL. Send the bare model ID (`kimi-k2.6`),
without the `opencode/` or `opencode-go/` prefix used by the OpenCode CLI, and select it explicitly:
microagent's default model name is an OpenRouter ID.

The client automatically sends a random `x-opencode-session` ID to `opencode.ai`, stable across
every tool turn, retry and REPL prompt in one process. Go requires this header for routing and
prompt caching; see its [client requirements](https://opencode.ai/docs/go/#where-can-i-use-it).
Zen may return `FreeTierError` for free-tier models used outside OpenCode; use a model your
account permits for external clients.

Choose a model listed with a `/chat/completions` endpoint in the official
[Zen](https://opencode.ai/docs/zen/#endpoints) or [Go](https://opencode.ai/docs/go/#endpoints)
tables. Models served through other API formats, such as `/responses` or `/messages`, are
not supported by this client. Availability and API format can differ between Zen and Go.

Streamed `reasoning_content` is preserved on assistant messages, including tool calls and REPL
history, so models that require their thinking on follow-up requests receive it unchanged.
It shares the 16 MiB response allowance with visible text and tool arguments and is not printed
to stdout or written to the session log. Local CLI checks cover both gateway paths and tool
follow-ups; authenticated calls require your OpenCode API key.

## What leaves the machine

This is the whole list of places one run reaches, and of what it writes down.

**The provider.** Every turn re-sends the whole conversation to the base url: the task as typed, the
system prompt, the text of every skill the model loaded, and every tool result so far. A tool result
is whatever the tree held, so file contents, build logs and `bash` output all go to the host the base
url names, and are re-sent on every later turn. The request body also carries the model name, tool
schemas, `max_tokens`, optional reasoning and temperature settings, and retained assistant
reasoning. Headers are authorization, content type, accepted response type, the user agent and
every entry of the config's `headers` table; OpenCode also receives a random `x-opencode-session`
ID shared by the turns in one process, which holds no machine name, account name or other local
identifier. Under ACP with `discover_models = true`, the first session also sends one
`GET <base_url>/models` with the same key and `headers` ([provider settings](#provider-settings)).

The credential guards under [Tools](#tools) keep key material out of a tool result, and the `git`
tool keeps names and email addresses out: `log` is `--oneline` (hash and subject), `show` asks for
the hash, date and subject instead of the `Author:` and `Commit:` lines, and `blame` keeps the hash,
date and line number with the name cut out.

**GitHub.** `microagent update` and `microagent update --check` ask
`https://api.github.com/repos/<owner>/<repo>/releases/latest` and the release page for the asset, so
GitHub sees this machine's IP address and, in the `User-Agent`, the version. Nothing else in a run
contacts GitHub: there is no telemetry, no analytics, no crash report, and no update check on a run
that was not asked to update. See [Update](#update).

**MCP servers.** A configured local server is a child process on this machine. One call sends it the
tool name and the model's arguments for that call, and nothing else: no conversation, no system
prompt, no token counts, no credential. What it returns is the tool result, so that goes to the
provider in turn. See [MCP servers](#mcp-servers).

**Remote MCP servers.** A `url` server, and each preset in the [tool set](#tool-set) that is
switched on, is an HTTPS endpoint somebody else runs. A call sends it the same tool name and
arguments, and the handshake sends the client name and version (`microagent`, this build's
version); the operator of the endpoint sees this machine's IP address, the query the model built and
the key the entry names, when it names one. Nothing else of the run is sent, and the sandbox does
not confine this traffic.

A preset is off unless the config enables it, so a run with no config reaches none of the four
preset endpoints. Which remote servers are contacted at startup and which on the first tool call is
set out under [tool set](#tool-set). Each preset tool tells the model to put nothing from the
repository under review in an argument; that guidance is the whole of the control once a preset is
on.

**On disk.** The [session log](#session-log) is the only file a run keeps of itself, apart from the
files its tools were asked to write and the commented config template a run writes when it finds
no file at the default path ([config file](#config-file)). The log holds counters and the working
directory, never prompt or output text.

## Prompt cache

The client sends constant request fields and the tool schema before `messages`, and keeps
conversation messages in their existing order when appending a turn. The built-in system prompt
also stays ahead of the working-directory line and configuration additions. This keeps unchanged
prompt content stable between turns and invocations with the same directory and configuration.

Caching depends on the provider and model. JSON member order alone does not guarantee a cache hit:
the provider decides how to turn the request into model tokens, whether to cache them, and how long
to retain them. The client sends neither `prompt_cache_key` nor `cache_control`.

Changing the model, tool set, working directory, system prompt addendum, repository instructions,
or skills can change the reusable prefix. Conversation compaction also changes earlier messages.
`cached_tokens` in the [usage line](#stdout) and [session log](#session-log) reports the provider's
cache usage when it supplies that field; a missing field is reported as zero.

## Config file

One TOML file carries the provider settings, the system prompt addendum, the skill roots, the MCP
servers, the tool set, denied shell commands, and workspace sandbox settings. It is `--config`, else
`MICROAGENT_CONFIG`, else `~/.microagent/config.toml`. A named path may start with `~` or `~/`, which
is the home directory: a shell expands the tilde in a command line before the flag is read, but a
value that came out of `MICROAGENT_CONFIG` never went through one, so microagent expands it here.
[`config.example.toml`](../config.example.toml) is a commented template.

A missing file means the defaults, and a run that finds nothing at the default path writes the
commented template there (mode 600, under `~/.microagent` at mode 700) and names the path on
stderr, so the next edit has a file to make. A path named by `--config` or `MICROAGENT_CONFIG` is
never created, and a file that is already there is never touched. A file that cannot be read, is a
directory, or is over the 64 KB cap is named on stderr and the run continues on the defaults. A
value a key does not take, or a key the file format does not define, keeps that key's default, and
the first such line is reported on stderr, so a misspelled `system_prompt_extra` cannot leave the
default in force quietly. One spelling exists per setting: a key or table this file once accepted
under another name (`caveman`, `ponytail`, `[style]`, `[commands]`, `command_filter`,
`sandbox = true`) is reported the same way. Some mistakes stop the run instead, before the first
request: a [`[tools.<name>]`](#tool-set) table the run cannot honor, and the
[provider settings](#provider-settings) it refuses (a `model` outside `models`, a `reasoning_effort`
that names no level, a `base_url` or `api_key` that fails its check).

### Provider settings

Three top-level keys name where a run talks and with what key, and each is overridden by the
environment variable and then by the flag of the same option. They are the weakest of the three
sources on purpose: a file that is committed for a team states the house endpoint, while the shell a
run starts from states the account.

```toml
model    = "deepseek/deepseek-v4-flash"
base_url = "https://api.openai.com/v1"
api_key  = "sk-..."   # in the clear: chmod 600, and keep it out of a workspace
reasoning_effort = "high" # optional, for models that support it
```

`reasoning_effort` accepts `minimal`, `low`, `medium`, `high`, or `none` to disable thinking.
Only set it for a model that supports the chosen value. `--reasoning-effort` overrides
`MICROAGENT_REASONING_EFFORT`, which overrides the config; omitted or empty uses the provider's
default. Invalid level names stop the run before a request. OpenCode receives `reasoning_effort`
for a level, or `thinking.type = "disabled"` for `none`; other endpoints receive `reasoning.effort`
or `reasoning.enabled = false`. If the provider rejects optional reasoning or temperature fields
with HTTP 400, the existing fallback reports the rejection and retries without those settings.

`headers` is an inline table of extra headers sent on every provider request, for an upstream
that needs one the client would otherwise not send, such as a Grok CLI proxy that refuses a
request without `x-grok-client-version`, or a router such as fastrouter's Grok preset, which forwards
`x-grok-client-version` only when the client supplies it:

```toml
headers = { "x-grok-client-version" = "1.0.77" }
```

It exists only in the file: there is no flag or variable. Names are HTTP tokens and values hold no
control character other than tab. A name the client already sends (`Authorization`, `User-Agent`,
`Content-Type`, `Accept`, `Content-Length`, `Transfer-Encoding`, `Host`, `Connection`,
`Accept-Encoding`, `x-opencode-session`) or one repeated in any case refuses the whole table: the
problem is named on stderr and the run goes on with no extra headers, so the key cannot be replaced
or sent twice. The headers go only to `base_url`, never to an MCP server.

`models` is an array of model ids an ACP client may switch a session among, all served by the one
`base_url`:

```toml
model  = "grok/grok-4.7"
models = ["grok/grok-4.7", "grok/grok-4.6"]
```

`model` is the default and must be in the list; a file naming one outside it stops the run before
a request. With no `model`, the first entry is the default. A `--model` or `MICROAGENT_MODEL`
outside the list joins its front, because the operator chose it for this run. An empty id or one
repeated refuses the list, which is named on stderr. ACP sessions advertise every entry in the
`model` config option and `session/set_config_option` accepts only those; a terminal run uses the
default. Per-model `base_url`, `api_key` or `headers` are not built: every listed model goes to the
one provider.

`discover_models = true` adds the provider's own list. When an ACP client opens its first session,
microagent sends one `GET <base_url>/models` with the key and the `headers` table and adds each
`data[].id` the configured list (or `model` alone) does not already name, sorted, after it. The
default stays `model`, first among its own list. The answer is the provider's: an id longer than
256 bytes or holding a space or control byte is dropped, a repeat is named once, at most 512 are
added, and a body over 4 MiB or nested past 64 levels is refused. Discovery is given 10 seconds;
a failure, a status other than 200 or a missing base url or key leaves the configured list and
names the reason once on stderr. A terminal run does not ask, since it only uses the default.

`model` defaults to `deepseek/deepseek-v4-flash` when no source names one. `base_url` and `api_key`
have no default: a run that names neither is refused before the first request, with the message
naming the flag, the variable and the config key. `base_url` is checked the way the flag is, so a
value that is not a url, or a plain `http://` url that is not loopback, is refused. `api_key` is
checked the same way from whichever source it came from: one carrying a control character (a
newline a wrapper exported, a carriage return in a hand-edited config) is refused before the first
request rather than splitting the `Authorization` header line. A config file that names a key and
is readable by any account beyond its owner is named on stderr; the run goes on with the key. See
[Providers and keys](#providers-and-keys) for where a key is safest.

### Repository instructions

`AGENTS.md` in the working directory is read when the run starts and appended to the system prompt,
after the working-directory line and anything `system_prompt_extra` adds, and before the skills listing, between a `--- begin
repository instructions: <path> ---` marker and a `--- end repository instructions ---` one. It is
the convention every other coding agent reads, so a repository that carries one carries it for this
run too: a run whose operator wants none sets `agents_files = []`, and a list names other paths, in
order.

The block is the one piece of repository text the run follows as instructions, and the system prompt
says so along with what the block cannot do: it governs the task and cannot widen it, lift the
prompt's rules, authorize reading or printing a credential, send anything off the machine, or stand
in for the operator. A line in the file asking for one of those is reported in the run's summary
rather than obeyed. Text from the tree arriving anywhere else, through `read` or `search` or
quoted in a tool result, stays data.

The fences belong to the run, not to the file, so a line of the file that spells either one is
marked with a backslash before its dashes and stays inside the block. A file that closed its own
block would hand the model the rest of its text in the operator's own voice, where the limits above
do not apply, and the mark is what stops it. The file's words are not edited or dropped, a `---`
horizontal rule and a YAML frontmatter fence are ordinary text and are left whole, and the number
of lines marked is reported on stderr. The model is told what a mark means, so a marked line
answers to the block's limits like any other line of the file.

```toml
agents_files = ["AGENTS.md", "docs/HOUSE.md"]
```

A path is at most 1024 bytes, and a longer one is reported as a bad value. The default name that is
not there is silent, because most repositories carry none; a path a list names that is not there is
named on stderr, because a setting that did nothing is the operator's own spelling. A file that is
there and cannot be read is named either way.

The text is at most 128 KB. A larger file is followed up to the cap, cut at a character boundary, and
the note on stderr names the size it was cut from. Unlike a skill, whose roots the operator names,
this file is repository content the run treats as instructions. It is read once, before the first
request, so a file changed during the run reaches the next run and not this one, and it never becomes
the whole prompt. The [threat model](threat-model.md) ranks what a file in a repository under review
can reach.

### System prompt addendum

`system_prompt_extra` is text appended to the system prompt after a blank line, for a house rule such
as the reply length or the language. It is the only prompt-level setting: the tools and the request
shape are untouched, and the conversation stays the plain OpenAI message array. With the key absent
or empty the system prompt is the built-in one plus one generated line naming the absolute working
directory the run starts in, ahead of the addendum; a model given no path answers with one it
invented, and then treats that invented path as the tree it is working in.

```toml
system_prompt_extra = "Answer in at most three sentences."

# or over several lines
system_prompt_extra = """
Keep replies short.
Name the file and the line when you cite code.
"""
```

The value is a TOML string: `"..."` with the escapes `\b`, `\t`, `\n`, `\f`, `\r`, `"`, `\\`, `\uXXXX` and `\UXXXXXXXX`, a
literal `'...'` in which nothing is an escape, or either kind as a multi-line string. A `\uXXXX` naming a
lone surrogate, or a code point past the last one, is reported as a bad value rather than sent as bytes
that are not a character. It is at most 16 KB, because it is re-sent
on every turn; a longer value is reported as a bad value and the prompt stays the built-in one.

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
value turns skills off. A relative path resolves against the working directory, and a leading `~` or
`~/` is the home directory: nothing expands it on the way in, because these are values in a file or a
variable rather than words a shell reads. `~user` names another account and is left alone. The
working directory is deliberately not a default root: a `SKILL.md` in a repository under review was
written by whoever wrote that repository, and a skill body is text the model is told to follow. Naming
a repository's directory is the operator saying those bytes are instructions.

### MCP servers

An MCP server speaks JSON-RPC, either as a child process over stdio or as a remote streamable-HTTP
endpoint. One `[[mcp]]` table declares one:

```toml
[[mcp]]
name    = "fs"
command = "npx"
args    = ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"]
env     = { LOG = "debug" }
```

`name` and one of `command` or `url` are required; a table missing both, or carrying both, is
skipped and named on stderr by the server it declared, so a file with several tables says which one
was dropped. Every local server is started before the first request and asked for its tool list,
the remote ones the [tool set](#tool-set) does not defer are asked at the same time rather than one
after another, and each tool is offered to the model as `mcp__<server>__<tool>` with the server's
own `inputSchema`. The complete exposed name must fit the
[Chat Completions API's 64-character limit](https://developers.openai.com/api/reference/resources/chat/subresources/completions/methods/create);
oversized names are reported and skipped. Commands and arguments containing NUL bytes are rejected
before spawning. A schema over 16 KB is replaced with an empty object schema that says so in its `description`, because a schema sits in the
constant prefix of every request the run makes: a server that embeds a large `description`,
`examples` or `enum` in one would write those megabytes into every turn of the run, for the whole
run. A tool under the ceiling keeps the server's bytes exactly, in the order the server wrote them.
A call is a `tools/call`, and the text the server returns is the tool result, on the same deadline
as any other tool. A result with no `content` is the structured one: it is carried as the server
serialized it, capped at the same 24 KB a built-in tool's output is, with the note naming the size
it was cut from.

A server that cannot start, exits during the handshake, or refuses a call is reported on stderr and
skipped: one broken entry costs that entry, not the run. An `env` key is a variable name, letters,
digits and underscores, quoted or not. A key outside that form, or a value containing a NUL, skips
that server with the line named rather than spawning it.

An `env` value holding a token is a secret in the clear, the second place the file can hold one
after `api_key`, and the easier one to commit by accident (`env = { GITHUB_TOKEN = "ghp_..." }`).
Keep the file mode 600 and out of any workspace the model is given. Prefer handing a server a
variable from the run's environment; the credential variables a terminal run removes from it
([tool environment](#tool-environment)) are the exception, and a server that needs one must be
given it in `env`.

The server inherits stderr, bypassing diagnostic escaping and output caps; terminal escape
sequences can repaint the terminal. A call carries the tool name and model arguments, not the
conversation.

Server and tool names may hold only letters, digits, dash and underscore, and a name holding
`__` is refused: the double underscore separates the three parts of an exposed name.

A remote server is a table with a `url` in place of `command`:

```toml
[[mcp]]
name           = "docs"
url            = "https://mcp.example.com/mcp"
api_key_env    = "DOCS_MCP_KEY"      # the NAME of a variable, never the key
api_key_header = "Authorization"     # the default
timeout        = 30                  # seconds, 1 to 600, the default
```

Every request is a `POST` to the url with `Content-Type: application/json` and
`Accept: application/json, text/event-stream`, and the answer is read as a JSON body or as an event
stream, whichever the server sends; notifications and server requests in a stream are ignored, and a
stream that ends without the answer is an error. Every request carries `User-Agent: microagent/<version>`,
the same one the provider call and `microagent update` send. `initialize` offers `2025-03-26` over HTTP and `2025-06-18` over stdio. An HTTP server
must answer `2025-03-26` or `2025-06-18`; later HTTP requests send that revision as
`MCP-Protocol-Version` and echo an `Mcp-Session-Id` the server assigned. A stdio server may also
answer `2024-11-05` or `2025-11-25`, and stdio sends no version header. Any other revision, or
none, fails initialization. Between
requests the client keeps the tool table and that session id, and no connection of its own.

Tool discovery follows opaque `nextCursor` values through every page, using the same handshake
deadline and a 4 MiB allowance for the complete catalog's JSON. A repeated or invalid cursor, an
oversized catalog, or a failed page skips the server rather than offering a partial table. Duplicate
tool names keep their first listing.

| key | meaning |
| --- | --- |
| `url` | `https`, or `http` to this machine (`localhost`, `127.0.0.0/8`, `::1`). No `user:password@`. No redirect is followed. |
| `api_key_env` | name of the environment variable holding the key. Unset or empty means no header, not an error. The key is never in the file, and a terminal run removes the variable from the environment tool subprocesses and local MCP servers get ([tool environment](#tool-environment)). |
| `api_key_header` | header the key travels in, default `Authorization`. In `Authorization` the value is `Bearer <key>`; in any other header it is the key as it is. |
| `timeout` | seconds one request may take, from connecting to the last byte, 1 to 600, default 30. Also bounded by the run's own budget. |

Not spoken: OAuth (a key is a static header), the standalone `GET` event stream for server-initiated
messages, and ending the session with a `DELETE`. A response over 4 MiB is an error rather than a
cut. A server that does not answer in time is not asked again for the rest of the run. The keys of
one form are refused on the other (`args` on a `url` table, `timeout` on a `command` table), and a
bad value drops the entry with a line on stderr, so a server never runs without the key or the
limit the file asked for. What a remote server returns is untrusted text like any tool result: see the
[threat model](threat-model.md).

### Tool set

`[tools.<name>]` switches a tool on or off and sets what a remote tool takes. The names are the
built-ins (`bash`, `read`, `write`, `edit`, `multi_edit`, `search`, `ast`, `git`, `todo`) and the
four presets (`web_search`, `context7`, `grep_app`, `deepwiki`).

```toml
[tools.ast]
enabled = false

[tools.context7]
enabled = true
```

`enabled` takes the TOML booleans `true` and `false` and nothing else, like every boolean in this file.

**Built-ins** are on unless the table says `enabled = false`, and they take no other key. A
**preset** is off unless the table says `enabled = true`: a preset is somebody else's endpoint, and a
call to one carries the query the model built, so a run ships nothing to those four hosts until the
config names one. A disabled
built-in is left out of the tool schema sent to the model, its calls are answered with
`error: the tool 'x' is disabled by configuration`, and the system prompt ends with one line,
`Disabled tools: ast, git.`. A run that disables nothing sends the same schema and system prompt, byte
for byte, as one with no `[tools]` table, so the provider's prompt cache is unaffected. At least one
built-in must stay on.

**Presets** are public MCP servers. Each is served by the same transport as a `url` table of the
same name, so its tools reach the model as `mcp__<preset>__<tool>`:

| preset | endpoint | tools |
| --- | --- | --- |
| `web_search` | `https://mcp.exa.ai/mcp` | `mcp__web_search__web_search_exa`, `mcp__web_search__web_fetch_exa` |
| `context7` | `https://mcp.context7.com/mcp` | `mcp__context7__resolve-library-id`, `mcp__context7__query-docs` |
| `grep_app` | `https://mcp.grep.app` | `mcp__grep_app__searchGitHub` |
| `deepwiki` | `https://mcp.deepwiki.com/mcp` | `mcp__deepwiki__read_wiki_structure`, `mcp__deepwiki__read_wiki_contents`, `mcp__deepwiki__ask_wiki_question` |

When a remote server is first contacted depends on its key and its host, not on whether a preset
or an `[[mcp]]` table declared it:

- A `url` server with no resolved key whose host is one of the four above is offered from the tools
  and schemas shipped in this binary. Its endpoint is first contacted when the model calls one of
  them: that call connects, initializes and fetches the server's own tool list, and a tool the
  server no longer offers is reported then.
- Every other `url` server is connected and asked for its tool list at startup. That covers a
  preset whose `api_key_env` resolves to a key, because a key can unlock tools the table does not
  name, and a preset or table on any other host, since only that server's `tools/list` says what it
  offers.

An unreachable server is reported by name; the other tools remain available.

A preset takes the same `url`, `api_key_env`, `api_key_header` and `timeout` as a `url` table (see
[MCP servers](#mcp-servers)), all optional: none of the four needs a key today, and `api_key_env`
is for a plan that has one. A preset and an `[[mcp]]` table of the same name would collide on tool
names, so the second is skipped and named on stderr.

A tool is described to the model by the compact form in this binary, not by the server's own
description, so what the model is told to send is decided here. Exa's `web_search_exa` also answers
profile searches, and its own description tells the model to put `category:people` or
`category:company` in the query to get one. Those two are not carried: the other three presets search
code and documentation, and a query naming an individual would put that name in a third party's
search log to answer a coding task. The categories still work, so a task that is a profile search
gets one when the profile search is the task the operator asked for.

`grep_app`'s own schema offers a `repo` filter and a `path` filter beside its `query`. Neither is
carried, for the same reason: each exists to name a repository or a place inside one, and the run is
working on a tree the operator did not offer to publish, so both put data about that tree in a third
party's log. grep.app indexes public code, so neither narrows the answer the tool is here for. A task
that is about one repository's own code says so in the task text.

Every one of the eight descriptions ends with the same sentence, and it is the whole of the control:
the arguments are the model's own words, so the model is told that a call leaves the machine and that
nothing belonging to the repository under review goes in one. A public repository the task itself names is a
different thing from the tree under review and is what the DeepWiki tools are for: a repository name
is how that wiki is addressed.

**Mistakes.** A table name that is not one of the thirteen above, a value a key cannot take, and a
config that disables every built-in stop the run before any request, with exit status 2 and a message
naming the config path and the bad name or key; the message for a bad name lists the valid ones. A
misspelled name never leaves a tool in a state the file did not ask for. A key the table does not
have is noted on stderr and ignored, like any unknown key in this file, and the note names the table
it was written in: `url`, `api_key_env`, `api_key_header` and `timeout` configure the endpoint a
preset reaches, so one of them under `[tools.bash]` is named as a preset key with nothing left to set.

### Command filter

Denied commands for the `bash` tool. Any command containing one of the configured words or sequences is refused before execution, returning `refused: command contains '...', which is denied by configuration` to the model.

```toml
deny_commands = ["sudo", "su", "shutdown", "reboot"]
```

`deny_commands` is a top-level list of strings; a bare string is refused as a bad value.

Matching inspects command words and basenames (for example, denying `sudo` matches both `sudo apt install` and `/usr/bin/sudo ls` without false-positiving on safe names like `run_sudoku.py`), as well as multi-word sequences (such as `rm -rf`). Quoting inside a word is read out before the comparison, so `s'udo'`, `su"do"` and `su\do` are matched as the `sudo` a shell would run.

The check is a word match over the command text, not a shell parse, so it is a guard against a
model running a denied command by naming it, not a sandbox. A command that reaches the same program
without spelling its name (a copy of it renamed on `PATH`, or `sudo` assembled in a variable) is not
caught. `[sandbox] enabled = true` is what confines `bash` to writable roots, and it is off by
default.

### Sandbox

Workspace confinement to restrict file modifications to designated directory roots:

```toml
[sandbox]
enabled = true
writable = [".", "/tmp"]
```

The writable roots are always `.` (the working directory), `/tmp`, and the session log directory, plus each `writable` entry, plus `$TMPDIR` where it names an absolute directory none of those already covers (on macOS that is where per-user scratch space lives; on Linux it is usually `/tmp` already, so it adds nothing). The value is trimmed like every other variable this program reads, and a relative one adds no root.

`writable` entries are read the way this program reads its own paths: a leading `~` or `~/` is the home directory, and a relative path is resolved against the working directory, so `writable = ["build"]` names the working directory's `build` rather than the one the process was started in. Every root is canonicalized, so a path through a symlink names the directory the link resolves to.

`writable` on its own confines nothing: a file that declares it without `enabled = true` prints `microagent: config ...: [sandbox] writable names N path(s) the sandbox is not in force for, because enabled is not true` and runs unconfined.

When enabled, writes outside those roots are blocked:
- **Landlock (Linux 5.13+):** rules applied to microagent before the first task mark `/` read-only and the writable roots read-write. Every child process inherits them across `execve`: `bash`, MCP servers and the build tools they start.
- **Seatbelt (macOS):** On macOS, a Seatbelt profile (`sandbox_init`, the call behind `sandbox-exec`) denies file writes everywhere except the same roots (on this system `$TMPDIR` is under `/var/folders`, behind a symlink into `/private`, and is not covered by `/tmp`) and the devices `/dev/null`, `/dev/tty` and `/dev/dtracehelper`. Reads, the network and process creation stay allowed. Children inherit the profile as they inherit Landlock's rules. Apple deprecates the call but still uses it, and it is not in the tests that run on Linux: the profile text is, the enforcement on a Mac is not.
- **When the kernel does not enforce it:** in ordinary CLI runs, an older Linux kernel or a Seatbelt refusal prints `microagent: sandbox: the kernel sandbox could not be applied ...` at startup, and only the in-process check below applies. That check covers the tools that write, not `bash` or MCP servers. ACP currently discards the kernel-sandbox result and emits no equivalent fallback warning.
- **When one root is refused:** a root the kernel will not open or will not grant prints `microagent: sandbox: <root> was not made writable (<errno>); writes under it are refused`, and the rest of the roots are applied as usual. A root the kernel refuses the read-only rule for `/` is not one of these: nothing is enforced at all and the run prints the "could not be applied" line above.
- **In-process path checking:** The `write`, `edit` and `multi_edit` tools, and `ast` when it carries a `rewrite`, canonicalize their path and verify it resolves strictly within allowed roots before writing, returning `refused: path '...' is outside the sandbox writable roots`.

## Tools

Nine built-in tools, each a thin wrapper over a program you already have. `[tools.<name>]` turns any of
them off ([tool set](#tool-set)).

| tool | what it does |
| --- | --- |
| `bash` | `/bin/sh -c`, so write POSIX sh: bash-only syntax (`[[ ]]`, arrays, `$'...'`, process substitution) works only where the host's `/bin/sh` happens to accept it. 120 s default timeout (the model may ask for up to 600 s), output capped at 24 KB. A command naming a credentials file or matching the command filter is refused, and in a terminal run the child inherits no provider credential ([tool environment](#tool-environment)). |
| `read` | read a file, with optional line offset and limit. Refuses credentials (`.env`, key and keystore files, anything under `.secrets` or `.ssh`), including a symlink to one, and refuses any path under `/proc/` whose last component is `environ` or `cmdline`. |
| `write` | create or overwrite a file, creating parents. Refuses a credentials path, a path outside sandbox roots when enabled, a call with no `content`, and `content` past the 64 MB ceiling `edit` holds the file it leaves behind to. |
| `edit` | exact string replacement. Refuses a credentials path, a path outside sandbox roots when enabled, an ambiguous match unless `replace_all`, and an edit that would leave `old_string` matchable in the result, so a repeated call cannot apply the change twice. |
| `multi_edit` | a list of `{path, old_string, new_string, replace_all}` replacements, in one file or across files, applied in order on the text the earlier ones left. Every edit is judged as `edit` judges it, and no file is written unless all are accepted, so a refusal names the edit and changes nothing; up to 64 edits per call. A file written part way says how many files had already landed. Sending the same batch again is safe and finishes the work: an edit already on disk is skipped and the rest are applied, and a file whose every edit was already applied is not rewritten. The summary says how much of the batch an earlier run had done. |
| `search` | `rg --line-number --no-heading`, optional glob; credentials files excluded. |
| `ast` | `ast-grep run` for a structural match, or `--rewrite --update-all` to apply one; credentials files excluded, and a `rewrite` refuses a path outside the sandbox roots when enabled. |
| `git` | read-only `status`, `diff`, `log`, `show`, `blame`, capped at 400 lines; a credentials path is refused, `show` is asked for the hash, date and subject rather than the author and committer header lines, and the name on a `blame` line is cut out of it. |
| `todo` | keeps the steps of a long task: the whole list, each `pending`, `doing` or `done`, replaces the last one and is returned. |

A config can add two more kinds: the `skill` tool when a skills root held something, and one
`mcp__<server>__<tool>` per tool an MCP server reported, local, `url` or preset.

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
file it points at. The two `/proc` files that report a process's own environment and argument
vector are refused by name as well, since `read /proc/self/environ` returned the run's own key
under a path no name table could have caught. A terminal run also removes its own keys from every
tool subprocess's environment, so `bash: env` has none to print; under ACP it does not
([tool environment](#tool-environment)). What remains open is the name rule itself: a credential
the tables do not recognize, and a path a command assembles at run time, are still read. See
[threat-model.md](threat-model.md).

**Tool calls run once.** The stream is delivered at least once, so a turn's tool calls are
deduplicated by the id the provider gave them before anything runs: a relay that reconnects replays
frames, and a replayed call is a `bash` run twice. The first delivery runs, the repeat is named on
stderr, and two identical calls with different ids are two calls.

### Tool environment

Every tool subprocess and every local MCP server inherits the run's environment. A terminal run,
one-shot or `--repl`, first removes the variables this binary sends as credentials:
`MICROAGENT_API_KEY`, `GITHUB_TOKEN`, and each variable a remote server's `api_key_env` names. A
local MCP server gets that environment plus its own `env` entries, so a server that needs one of
those values must be given it there.

`microagent acp` removes nothing: tools and MCP servers see the environment the client launched it
with, so a `MICROAGENT_API_KEY` or `GITHUB_TOKEN` set there reaches them, and `bash: env` prints it
into the conversation. The [threat model](threat-model.md) lists this as a known gap.

## Output

### stdout

stdout carries the model's own text, one JSON usage line per response, and nothing else:

```json
{"type":"usage","usage":{"prompt_tokens":910,"cached_tokens":832,"completion_tokens":18,"reasoning_tokens":0,"total_tokens":928}}
```

Counters are cumulative for the run, which is the shape gauntlet's usage reader takes its maximum
from. The model's text is written as the provider sent it, unescaped, so an escape sequence in it
reaches a terminal. Tool activity goes to stderr as a one-line gutter (`⏺ read: src/main.zig`, the name in bold
when stderr is a terminal and plain when it is a pipe or a file), with control
characters in a path or command written as `\xNN` so a line stays one line.
`NO_COLOR` set to anything but an empty string, or `TERM=dumb`, leaves the bold out even at a
terminal.

Each tool call also reports how it ended, on the line below its own gutter line: `ok` when it ran
and its answer is its result, `FAILED` when it was refused, errored, or its subprocess exited
nonzero or was signalled, and `not run` when the time budget was already spent. The call's own time
follows, so a run read from stderr alone answers which calls failed and which were slow:

```text
⏺ bash: cargo test
  FAILED bash in 1834ms
```

Those outcomes otherwise live only in the conversation, which goes to the provider and nowhere an
operator reads.

`cached_tokens` is the part of the prompt the provider served from its cache, read from whichever of
`prompt_tokens_details.cached_tokens`, `prompt_cache_hit_tokens` or `cache_read_input_tokens` the
endpoint sends. Until a compaction (below), earlier messages are re-sent unchanged, so on a
multi-turn run the counter should climb with the conversation; see [Prompt cache](#prompt-cache).

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
| 2 | wrong command line, or a config the run cannot start with: a bad value, a `[tools.<name>]` that names no tool, every built-in disabled |
| 3 | stopped without an answer: `--max-turns`, `--max-spend-tokens` or `--budget` reached, three [repeat rounds](#failure-handling) in a row of the same non-writing tool calls, or the last response carried no text, was cut at `--max-tokens` or the response byte ceiling, or the provider stopped generating it. stdout is a prefix of the work, not an answer. |
| 130 | interrupted (Ctrl+C or kill), taking the tool subprocess with it |

A wrong flag prints the reason and the full help on stderr, so a script reading stdout gets nothing
from a failed invocation.

### Session log

Each run appends one JSONL record per model response to `~/.microagent/sessions/<unix-ns>.jsonl`, so
a monitor can follow a run while it is going. A turn whose provider call never answered gets a record
of the same shape carrying the reason, so the log ends where the run ended rather than at the last
response that arrived. `MICROAGENT_SESSION_DIR` moves the store and an empty
value turns it off. A run that finds its name taken writes `-1`, `-2`, ... beside it rather than over
it. The store keeps the 200 most recent runs and drops any log older than 30 days
([pruning](#what-survives-and-how-to-get-it-back)).

```json
{"ts":1790608347342,"cwd":"~/Desktop/Projects/microagent","model":"deepseek/deepseek-v4-flash","finish_reason":"stop","served_model":"deepseek/deepseek-v4-flash-0726","fingerprint":"fp_9c1e","stream_error":"","elapsed_ms":1448,"usage":{"prompt_tokens":998,"cached_tokens":896,"completion_tokens":19,"reasoning_tokens":16,"total_tokens":1017}}
```

```json
{"ts":1790608351204,"cwd":"~/Desktop/Projects/microagent","model":"deepseek/deepseek-v4-flash","finish_reason":"","served_model":"","fingerprint":"","stream_error":"","error":"ConnectionRefused","elapsed_ms":902,"usage":{"prompt_tokens":0,"cached_tokens":0,"completion_tokens":0,"reasoning_tokens":0,"total_tokens":0}}
```

| key | meaning |
| --- | --- |
| `usage` | this response's own counters, not the run's cumulative ones. Zero on a record carrying `error`, because no response arrived to report usage; a request sent in full may still have been billed. |
| `cwd` | the directory the run works in, behind a `~` and relative to the home when it is under it, so the record carries no account name: `/home/you/Desktop/Projects/microagent` records as `~/Desktop/Projects/microagent`. A directory outside the home, or any directory when `HOME` is unset, is recorded whole. |
| `finish_reason` | why the provider stopped. `length` means the response was cut at `--max-tokens` and the run says so on stderr; the empty string is a stream that carried no reason, and every value on a record carrying `error`. |
| `model` / `served_model` / `fingerprint` | what the run asked for, what the provider says answered, and the weights fingerprint it reported. A gateway routes a name to whichever snapshot it holds that week, so two runs are comparable only when these match. Empty when the stream named none. |
| `stream_error` | what the provider said went wrong in the middle of the stream, in the one line the run prints on stderr. The frames around it still carry choices, so this is the field that tells a stream the provider abandoned from one that ran to its end. The empty string is a stream that reported no failure, and every value on a record carrying `error`. |
| `error` | why the provider call never answered, on a record for a turn that failed rather than a turn that returned. Absent from a record for a turn that returned. |
| `elapsed_ms` | the model's time on this response, for tokens per second without tool time mixed in. Measured on a clock that stops while the machine is suspended (`--budget`, by contrast, counts suspend: it bounds wall time). |

A directory that cannot be created, or a log that cannot be opened or written, is named on stderr
and the rest of the run goes unrecorded. Nothing in the log is prompt or output text.
[toktop](https://github.com/maci0/toktop) reads this store by default, and the keys are the ordinary
OpenAI ones plus `cwd`, so any reader of agent transcripts works.

A log is created mode 600 and a store directory this run creates is mode 700, so on a shared
machine only the account that made the runs can read them. Neither mode is applied to a directory
that already exists, so a store `MICROAGENT_SESSION_DIR` points at keeps the mode it has.

Deleting the store is `rm -r ~/.microagent/sessions`: nothing outside it holds anything from the
run, and the binary never reads a log back.

### What survives, and how to get it back

The session log is the only durable artifact this program keeps of itself. There is no database,
no queue and no object storage: the working tree a run edits and the config file under
`~/.microagent` are the operator's to back up, not this program's.

**Each record is flushed to disk before the run carries on.** A record is written, the file is
synced, and then the directory that holds the log is synced, so a new log's name is durable along
with its bytes. Only then does the run move to the next turn, so a record a monitor
([toktop](https://github.com/maci0/toktop)) has already counted survives an unclean stop; the
price is two disk round trips per response, against seconds of provider time. A flush that fails
is named on stderr and the run keeps appending: what is at risk is the guarantee, not the data.

**There is no backup and no restore procedure, because there is nothing to restore from.** The
log is an append-only record of counters, a working directory and a model name, never prompt or
output text. No reader replays it, so a lost or deleted log loses an accounting trail, not work.
The RPO for that trail is whatever the operator backs up themselves: to keep the store across a
machine loss, copy `~/.microagent/sessions`, and the config file beside it because it may hold an
`api_key`, to your own backup. The RTO for restoring such a copy is a file copy: the store is
JSONL a monitor reads directly, so putting the files back under `MICROAGENT_SESSION_DIR` is the
whole restore, with no binary, no version match and no migration involved.

**The store prunes itself, under two windows.** It keeps the 200 most recent logs and drops
anything older than 30 days, on every run and without confirmation, oldest first. Both windows
are measured against the machine's own clock, so a clock set forward ages the whole store out at
once and a single run deletes all of it; back the store up before correcting a clock that jumped,
and know that `MICROAGENT_SESSION_DIR` decides which directory is pruned, so copy one before
changing the variable.

## Failure handling

- **Transient failures retry.** Any 5xx, or a connection that dies before the
  request reached the provider, is retried twice, with 1 s and 2 s of backoff (or the provider's
  `Retry-After`, capped at 120 s), before the run exits non-zero. A 408, 425, 429 or 409 is not:
  each of those is the provider answering a request it has already accepted, and sending the turn
  again would be a second billable completion of the same turn. Any other rejection (401, 404) fails
  at once. A 400 does too, with one exception: when reasoning effort or temperature is set,
  the request is sent once more without the optional reasoning and temperature fields, since some
  providers refuse those fields rather than the request.
- **A sent turn is never re-sent.** When the whole turn was sent and no response arrives, the
  provider may already have generated and billed the completion, so the run ends with the connection
  error on stderr rather than paying twice. A failure the provider reports is named in its own words;
  one that arrives before any content, with no tool call half assembled, is asked again on the same
  1 s and 2 s schedule, since nothing was generated to pay for. One that arrives part way through a
  stream ends the run: whatever reached stdout is a prefix of an answer it abandoned.
- **Every request carries `max_tokens`**, so a model that fails to stop is not billed until something
  else stops it. `--max-turns` counts turns, not tokens, and a turn re-sends the whole conversation,
  so `--max-spend-tokens` is the ceiling on what a run spends.
- **Repeated non-writing calls stop a run.** Three consecutive repeat rounds end with exit 3.
  A round repeats when every built-in non-writing call's name and arguments appeared in the
  preceding turn; the first occurrence is not a repeat. A new non-writing call resets the count.
  Writing calls and unknown tools are excluded. Write-only turns do not increment the count and
  clear the saved call set.
- **`--budget`** stops starting turns after the given seconds, then takes one last turn to land an
  edit, which may run up to 5 minutes past it. A turn cut off there is discarded, not half-applied.
  The deadline also cancels blocked DNS, TLS, request writes, response headers and stream reads.
  `--stall-timeout` bounds connection setup, request writes and silent response reads even with no budget.
- **No restoration across process restarts.** ACP can resume sessions retained by the current
  connection. gauntlet's `--retries` reruns a whole review.

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

## Agent Client Protocol

`microagent acp` serves the Agent Client Protocol (ACP) v1 on stdin and stdout. A client
launches it as a subprocess, sends JSON-RPC 2.0 frames, and receives streamed
`session/update` notifications and one result per prompt. Configuration, provider
credentials, skills, tools and the session log resolve as they do for a terminal
run, with two differences: tools and MCP servers inherit the environment
unscrubbed ([tool environment](#tool-environment)), and a kernel sandbox that
could not be applied is not reported ([sandbox](#sandbox)). The example below
needs the same `MICROAGENT_API_KEY`, `MICROAGENT_BASE_URL` and `MICROAGENT_MODEL`.

```json
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1,"clientCapabilities":{}}}
{"jsonrpc":"2.0","id":2,"method":"session/new","params":{"cwd":"/workspace","mcpServers":[]}}
{"jsonrpc":"2.0","id":3,"method":"session/prompt","params":{"sessionId":"sess_...","prompt":[{"type":"text","text":"fix the failing test"}]}}
```

The agent advertises `close`, `delete`, `list` and `resume` session
capabilities, text, resource-link and embedded-text prompts, and both stdio and
HTTP MCP servers. `session/load` also replays user and assistant text for a
session held by this connection, although `loadSession` is advertised as false.
Model text arrives as `agent_message_chunk`, each tool call as `tool_call`
followed by `tool_call_update` statuses (`in_progress`, then `completed` or
`failed` with its output). A `session/cancel` notification stops the provider
request and any tool call that has not started, and the outstanding
`session/prompt` answers `{"stopReason":"cancelled"}`. Prompts answer
`end_turn`, `max_turn_requests`, `max_tokens`, `refusal` or `cancelled`.

A session's `cwd` is the directory the tools run in, and every file path the
client sends must be absolute. The client-supplied MCP `env` and header values
are used to launch or reach those servers and are never echoed in a session
update. Image and audio prompt blocks are refused because this agent advertises
neither capability.

## Setup

Run `microagent setup` for interactive configuration, or
`microagent setup --config path/to/config.toml` to select another file.
The path follows the same order as a run: `--config`, `MICROAGENT_CONFIG`, then
`~/.microagent/config.toml`. An empty `MICROAGENT_CONFIG` turns config off;
pass `--config` explicitly to set up a file in that case.

A missing file is created from the embedded `config.example.toml` template
with mode 600. Questions cover the provider API base URL, model, optional API
key, system prompt addendum, repository instructions, skills, workspace
sandbox, the nine built-in tools and the four remote tool presets. Enabling a
remote preset also asks for its endpoint and optional API key environment
variable. URLs must use HTTPS or HTTP on loopback, without embedded credentials.

Enter keeps each current value; `-` clears a text setting. API key input is
hidden and its current value is never printed. At least one built-in tool
must stay enabled. EOF cancels edits; a newly initialized template remains.
Existing comments, custom paths, sandbox writable roots and custom MCP entries
are preserved. Edits are saved atomically with mode 600 after all questions
finish. Setup makes no API requests. Run flags and environment variables still
override these file settings.

`microagent setup --help` and `microagent help setup` print usage without
reading or creating a config.

## Update

```sh
microagent update                         # replace this binary with the latest release
microagent update --check                 # report the latest release, install nothing
microagent help update                    # the subcommand's own flags, environment and exits
```

The repository it installs from is the one this binary was built for, named by `default_repo` in
`src/update.zig`; a fork builds its own. There is no flag for it.

Each release publishes `microagent-<tag>-<triple>` for `x86_64-linux-musl`, `aarch64-linux-musl`,
`x86_64-macos` and `aarch64-macos`, each with a `.sha256` sidecar. Linux has one static asset per
architecture that links no C library (`musl` in the name is only the target triple), so it runs on
glibc and musl hosts alike and a `-gnu` build updates to it. The download is checked
against its sidecar, and the running binary is replaced atomically (following a symlink to the real
file) only when the digest matches. A mismatch, a missing asset, or a release page that is not a
GitHub https URL leaves the binary untouched. `GITHUB_TOKEN` lifts the anonymous API rate limit.
A download that fails the way a later one could answer differently is attempted up to three times:
a `408`, `425`, `429`, any `5xx`, or a connection that dies before the answer. A `409` is not
retried. `Retry-After` is honored up to 30 s; without it, the request uses the agent run's backoff
under the same cap.
Exit 1 means the check or the install failed, 2 is a usage error; `microagent update --help`, or
`microagent help update`, has the rest.

## Versioning

The version is `build.zig.zon` and nothing else. [CHANGELOG.md](../CHANGELOG.md) records what
changed in each release, and its preamble states what a minor and a patch may change under `0.y`.
The gates that hold a tag to that policy are in
[CONTRIBUTING.md](../CONTRIBUTING.md#version-and-changelog), and
[SECURITY.md](../SECURITY.md#supported-versions) says which releases are supported.
