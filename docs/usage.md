# Usage reference

Everything a run reads and everything it writes. The [README](../README.md) is the short version.

- [Quick start](#quick-start)
- [Flags and environment](#flags-and-environment)
- [How values resolve](#how-values-resolve)
- [Providers and keys](#providers-and-keys)
- [Config file](#config-file): [provider settings](#provider-settings), [system prompt addendum](#system-prompt-addendum), [repository instructions](#repository-instructions), [skills](#skills), [MCP servers](#mcp-servers), [tool set](#tool-set), [command filter](#command-filter)
- [Tools](#tools)
- [Output](#output): [stdout](#stdout), [exit status](#exit-status), [session log](#session-log)
- [Failure handling](#failure-handling)
- [Driving it from gauntlet](#driving-it-from-gauntlet)
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

## Flags and environment

`microagent --help`, verbatim:

```
microagent - tiny OpenAI-compatible coding agent

usage: microagent [options] "<prompt>"
       microagent update [-c | --check]
       microagent help [update]

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
                         (env MICROAGENT_MAX_TURNS, default 100)
      --stall-timeout <s>  seconds the response socket may stay silent
                         before the read fails
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
                         reasoning.effort sent to the provider: minimal,
                         low, medium, high, or none to disable (env
                         MICROAGENT_REASONING_EFFORT)
      --temperature <n>   temperature sent to the provider, 0 to 2. Left
                         out, the provider samples at its own default, so
                         two runs of one conversation are two answers;
                         0 is the one setting that repeats
                         (env MICROAGENT_TEMPERATURE)
  -h, --help             this text ("help" as the only argument too)
  -V, --version          version

every long flag also takes --flag=value. A flag wins over the environment
variable for the same option, and wins over one the run could not use:
MICROAGENT_MAX_TURNS=0 with --max-turns 5 is a run with five turns, and the
variable is named on stderr rather than stopping it. A bare -- ends the
flags, so a task that begins with a dash is passed after it. A bare "help"
asks for this text while the prompt is still empty; any other bare word, or
a value of --print, is a task, and so is the word "update" anywhere but
first: as the first argument it is the subcommand below, and a task of
that name is written after a flag or a --. "help update" is that
subcommand's own text, and a word after "help" that names no subcommand
is a usage error rather than this text. A
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

subcommand:
  update [-c | --check]
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

A flag wins over a variable the run could not use, because the flag is read after the environment
and the value it sets is the one in force. `MICROAGENT_MAX_TURNS=0 microagent --max-turns 5` is a
run with five turns; the variable is named on stderr and the run goes on. With no such flag the
variable is the run's, and the message stops the run as a bad argument would. `--base-url` and
`MICROAGENT_BASE_URL` have always worked this way: the url is checked where the run uses it.

A variable set to an empty string is not a value:
`MICROAGENT_MODEL`, `MICROAGENT_BASE_URL`, `MICROAGENT_REASONING_EFFORT`,
`MICROAGENT_TEMPERATURE`, `MICROAGENT_BUDGET_SECONDS`, `MICROAGENT_MAX_SPEND_TOKENS`, `MICROAGENT_MAX_TURNS`,
`MICROAGENT_MAX_TOKENS`, `MICROAGENT_STALL_TIMEOUT` and `MDEBUG` keep their defaults,
`MICROAGENT_API_KEY` falls through to the config file's `api_key`, and `MICROAGENT_CA_BUNDLE` falls
through to `SSL_CERT_FILE`.
Three variables are the exception: `MICROAGENT_CONFIG`, `MICROAGENT_SESSION_DIR` and
`MICROAGENT_SKILLS` read empty as off, so no config file, no session log and no skills.

Every variable is trimmed before it is read, `HOME` included, and one holding only whitespace reads
as empty. A wrapper that fills the environment from a file exports that file's trailing newline, and
untrimmed it would break each option differently: an api key becomes an `Authorization` header with
a byte a header may not hold, a base url stops parsing, a session directory names a directory no
monitor looks in, and a `HOME` ending in a newline moves every default path
(`~/.microagent/config.toml`, the session store) somewhere that does not exist. An
empty `HOME` is no home rather than a path off the root.

`MDEBUG=1` prints the configuration the run resolved: model, base url (credentials in it redacted),
the ceilings, the config file that was read and the size of its prompt addendum, the skill roots, whether
the sandbox is on and how many roots it has, how many tools are off and how many commands are denied, and
the name of the variable or file the api key came from. The key itself is never printed. Each option has
up to three sources, and this is how you tell which one answered. The skill roots are named because
`skills=0` on its own is the same line for a machine with no skills installed and one reading the
wrong directories, and the sandbox line is the only place a run says whether `[sandbox] enabled` was in
force: a machine refusing a write the config said was allowed is otherwise indistinguishable from one
where it was refused for its own reasons.

## Providers and keys

Any OpenAI-compatible endpoint works: OpenRouter, DeepSeek, OpenAI, vLLM, LiteLLM, Z.AI.
`deepseek/deepseek-v4-flash` and `stealth/space-bunny-alpha` (OpenRouter) were used to verify it end
to end; see [benchmark.md](benchmark.md).

The key is looked up in `--api-key`, then `MICROAGENT_API_KEY`, then `api_key` in the config file.
There is no key file: the path the binary used to fall back to was one provider's, and a key belongs
to the account that pays for the run.

`--api-key` is the one source that is not private to this process: the whole command line is in the
process table for as long as the run lasts, so any user on the machine can read the key out of it
there. A variable, or a config file only its owner can read (`chmod 600`), is not, which is why those
are the sources to reach for. A key in the config file is in the clear on disk, and it is in a file
the `read` tool can open: keep the file out of any workspace the model is given, or use a variable.

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

## What leaves the machine

One run reaches the places below, and writes one thing down. This is the whole list; a reader who wants
to know what their data does does not have to infer it from the code.

**The provider.** Every turn re-sends the whole conversation to the base url: the task as typed, the
system prompt, the text of every skill the config named, and every tool result so far. A tool result
is whatever the tree held, so file contents, build logs, and whatever a `bash` command printed all go
to whichever host the base url names, and they are re-sent on every later turn. The `git` tool is
the one that reads what other people wrote, and it is held to what a coding task reads a commit for:
`log` is `--oneline`, so a subject and a hash and no author; `show` asks git for the hash, the date
and the subject rather than the `Author:` and `Commit:` header lines, so no name and no email address
reaches the provider; `blame` keeps the hash, the date and the line number and has the name of
whoever last touched the line cut out of every line, since the hash on the same line already answers
that and `show` will read it. The credential guards under
[Tools](#tools) keep key material out of a tool result, and the `git` format choices keep a person's
name out of one. The request itself carries no identifier of this run: the body is the
model name, the tool schemas, `max_tokens`, the optional `reasoning` block and the conversation, and
the headers are `Authorization`, `content-type` and `accept`. No user id, no session id, no machine
name, no account name, no timestamp, no run counter.

**GitHub.** `microagent update` and `microagent update --check` ask
`https://api.github.com/repos/<owner>/<repo>/releases/latest` and the release page for the asset, so
GitHub sees this machine's IP address and, in the `User-Agent`, the version. Nothing else in a run
makes an outbound request: there is no telemetry, no analytics, no crash report, and no update check
on a run that was not asked to update. See [Update](#update).

**MCP servers.** A configured local server is a child process on this machine. One call sends it the
tool name and the model's arguments for that call, and nothing else: no conversation, no system
prompt, no token counts, no credential. What it returns is the tool result, so that goes to the
provider in turn. See [MCP servers](#mcp-servers).

**Remote MCP servers.** A `url` server, and each preset in the [tool set](#tool-set) that is
switched on, is an HTTPS endpoint somebody else runs. A call sends it the same tool name and
arguments, and the handshake sends the client name and version (`microagent`, this build's
version); the operator of the endpoint sees this machine's IP address, the query the model built and
the key the entry names, when it names one. Nothing else of the run is sent. The sandbox does not
confine this traffic. A preset is off unless the config names it, so a run with no config reaches
none of those four endpoints; a query the model built out of the task is the operator's to send, and
naming a preset is the one line that says it may go. The tools of a preset the config did name come
from a table in this binary, so the run reaches its endpoint only when the model calls one of those
tools, and
every one of those tools is described to the model with the same sentence: put nothing in an argument
that belongs to the repository under review, no code, no path, no file content, no repository name and
nothing that names a person in it. The guidance is the whole of the control once a preset is on, since
the arguments are the model's own words; a server the operator configured is a server they chose and
describe
themselves. The
first call is what connects, initializes and asks for the server's own tool list, and a tool the
server no longer offers is reported then. Set `enabled = false` in a `[tools.<name>]` table to make
no request at all, and give a preset an `api_key_env` to have it connected at start instead, because
a key can unlock tools the table does not name. A `url` server the config wrote is always connected
at start: only its own `tools/list` can say what it offers. An endpoint that cannot be reached is
named on stderr and its tools are left out of that call.

**On disk.** The [session log](#session-log) is the only file a run keeps of itself, apart from the
files its tools were asked to write. It holds counters and the working directory, never prompt or
output text.

## Config file

One TOML file carries the provider settings, the system prompt addendum, the skill roots, the MCP servers, the tool set, denied shell commands, and workspace sandbox settings. It is `--config`, else
`MICROAGENT_CONFIG`, else `~/.microagent/config.toml`. A named path may start with `~` or `~/`, which
is the home directory: a shell expands the tilde in a command line before the flag is read, but a
value that came out of `MICROAGENT_CONFIG` never went through one, so microagent expands it here.
[`config.example.toml`](../config.example.toml) is a commented template.

A missing file means the defaults, and a run that finds nothing at the default path writes the
commented template there (mode 0600, under `~/.microagent` at 0700) and names the path on stderr, so
the next edit has a file to make. A path named by `--config` or `MICROAGENT_CONFIG` is never created,
and a file that is already there is never touched. A file that cannot be read, is a directory, or is
over the 64 KB
cap is named on stderr and the run continues on the defaults. A value a key does not take, and a key the
file format does not define, are reported on stderr with that key's default kept, so a misspelled
`system_prompt_extra` cannot leave the default in force quietly. One spelling exists per setting:
a key or table this file once accepted under another name (`caveman`, `ponytail`, `[style]`,
`[commands]`, `command_filter`, `sandbox = true`) is reported the same way. A [`[tools.<name>]`](#tool-set) table the run
cannot honor is the exception: it stops the run.

### Provider settings

Three top-level keys name where a run talks and with what key, and each is overridden by the
environment variable and then by the flag of the same option. They are the weakest of the three
sources on purpose: a file that is committed for a team states the house endpoint, while the shell a
run starts from states the account.

```toml
model    = "deepseek/deepseek-v4-flash"
base_url = "https://api.openai.com/v1"
api_key  = "sk-..."   # in the clear: chmod 600, and keep it out of a workspace
```

`model` defaults to `deepseek/deepseek-v4-flash` when no source names one. `base_url` and `api_key`
have no default: a run that names neither is refused before the first request, with the message
naming the flag, the variable and the config key. `base_url` is checked the way the flag is, so a
value that is not a url, or a plain `http://` url that is not loopback, is refused. `api_key` is
checked the same way from whichever of the three sources it came from: the key is written into an
`Authorization` header, so one carrying a control character (a newline a wrapper exported from a file,
a carriage return in a hand-edited config) is refused before the first request rather than splitting
the header line.
`api_key` is a secret written in the clear, and the `read` tool can open the file: a variable or
`--api-key` keeps it out of a file a model can read.

### Repository instructions

`AGENTS.md` in the working directory is read when the run starts and appended to the system prompt,
after anything `system_prompt_extra` adds and before the skills listing, between a `--- begin
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

The text is at most 16 KB. A larger file is followed up to the cap, cut at a character boundary, and
the note on stderr names the size it was cut from. Unlike a skill, whose roots the operator names,
this file is repository content the run treats as instructions. It is read once, before the first
request, so a file changed during the run reaches the next run and not this one, and it never becomes
the whole prompt. The [threat model](threat-model.md) ranks what a file in a repository under review
can reach.

### System prompt addendum

`system_prompt_extra` is text appended to the system prompt after a blank line, for a house rule such
as the reply length or the language. It is the only prompt-level setting: the tools and the request
shape are untouched, and the conversation stays the plain OpenAI message array. With the key absent
or empty the system prompt is the built-in one, byte for byte.

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
was dropped. Every local server is started before the first request and asked for its tool list, the remote ones are asked at the same time
rather than one after another, and each tool is offered to
the model as `mcp__<server>__<tool>` with the server's own `inputSchema`. A schema over 16 KB is
replaced with an empty object schema that says so in its `description`, because a schema sits in the
constant prefix of every request the run makes: a server that embeds a large `description`,
`examples` or `enum` in one would write those megabytes into every turn of the run, for the whole
run. A tool under the ceiling keeps the server's bytes exactly, in the order the server wrote them.
A call is a `tools/call`, and the text the server returns is the tool result, on the same deadline
as any other tool. A result with no `content` is the structured one: it is carried as the server
serialized it, capped at the same 24 KB a built-in tool's output is, with the note naming the size
it was cut from.

A server that cannot start, exits during the handshake, or refuses a call is reported on stderr and
skipped: one broken entry costs that entry, not the run. An `env` key is a variable name, letters,
digits and underscores, quoted or not; a key or a value carrying a `=`, a NUL or a control character
is one the child's environment block cannot hold, so that server is skipped and the line named rather
than spawned. The server's stderr is inherited, since
that is where MCP servers write diagnostics. Its environment is the scrubbed one tool subprocesses
get plus the entry's `env`, so it never sees a provider key. Nor does it see the conversation: a
call carries the tool name and the model's arguments for it and nothing else. [What leaves the
machine](#what-leaves-the-machine) has the whole list.

Server and tool names may hold only letters, digits, dot, dash and underscore, and a name holding
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
stream that ends without the answer is an error. After `initialize` the client sends
`MCP-Protocol-Version: 2025-03-26`, and echoes an `Mcp-Session-Id` the server assigned. Between
requests the client keeps the tool table and that session id, and no connection of its own.

| key | meaning |
| --- | --- |
| `url` | `https`, or `http` to this machine (`localhost`, `127.0.0.0/8`, `::1`). No `user:password@`. No redirect is followed. |
| `api_key_env` | name of the environment variable holding the key. Unset or empty means no header, not an error. The key is never in the file, and the variable is removed from the environment tool subprocesses and local MCP servers get. |
| `api_key_header` | header the key travels in, default `Authorization`. In `Authorization` the value is `Bearer <key>`; in any other header it is the key as it is. |
| `timeout` | seconds one request may take, from connecting to the last byte, 1 to 600, default 30. Also bounded by the run's own budget. |

Not spoken: OAuth (a key is a static header), the standalone `GET` event stream for server-initiated
messages, and ending the session with a `DELETE`. A response over 4 MB is an error rather than a cut. A server that does not answer in time is not
asked again for the rest of the run. The keys of one form are refused on the other (`args` on a `url` table,
`timeout` on a `command` table), and a bad value drops the entry with a line on stderr, so a server never runs without the key or the limit the
file asked for. What a remote server returns is untrusted text like any tool result: see the
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

**Presets** are public MCP servers, and are off until the table says `enabled = true`. Their tools
and schemas are in
this binary, so a run that names one reaches it only when the model calls a tool from it; a call
to a server that cannot be reached is answered with an error naming it, so a run with no network still
works. Each is served by the same transport as a `url` table of the same name, so its tools reach the
model as `mcp__<preset>__<tool>`:

| preset | endpoint | tools |
| --- | --- | --- |
| `web_search` | `https://mcp.exa.ai/mcp` | `mcp__web_search__web_search_exa`, `mcp__web_search__web_fetch_exa` |
| `context7` | `https://mcp.context7.com/mcp` | `mcp__context7__resolve-library-id`, `mcp__context7__query-docs` |
| `grep_app` | `https://mcp.grep.app` | `mcp__grep_app__searchGitHub` |
| `deepwiki` | `https://mcp.deepwiki.com/mcp` | `mcp__deepwiki__read_wiki_structure`, `mcp__deepwiki__read_wiki_contents`, `mcp__deepwiki__ask_wiki_question` |

The tools are the ones each server lists, so a server that changes its list changes this one. A
preset takes the same `url`, `api_key_env`, `api_key_header` and `timeout` as a `url` table (see
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
nothing belonging to the repository under review goes in one. That covers the three that take text,
where a snippet out of the tree would otherwise become a search term in somebody else's log, and
`grep_app`, whose only argument is a literal pattern. A public repository the task itself names is a
different thing from the tree under review and is what the DeepWiki tools are for: a repository name
is how that wiki is addressed.

**Mistakes.** A table name that is not one of the thirteen above, a value a key cannot take, and a
config that disables every built-in stop the run before any request, with exit status 2 and a message
naming the config path and the bad name or key; the message for a bad name lists the valid ones. A
misspelled name never leaves a tool in a state the file did not ask for. A key the table does not
have (`url` under `[tools.bash]`) is noted on stderr and ignored, like any unknown key in this file.

### Command filter

Denied commands for the `bash` tool. Any command containing one of the configured words or sequences is refused before execution, returning `refused: command contains '...', which is denied by configuration` to the model.

```toml
deny_commands = ["sudo", "su", "shutdown", "reboot"]
```

`deny_commands` is a top-level list of strings; a bare string is refused as a bad value.

Matching inspects command words and basenames (for example, denying `sudo` matches both `sudo apt install` and `/usr/bin/sudo ls` without false-positiving on safe names like `run_sudoku.py`), as well as multi-word sequences (such as `rm -rf`). Quoting inside a word is read out before the comparison, so `s'udo'`, `su"do"` and `su\do` are matched as the `sudo` a shell would run.

The check is a word match over the command text, not a shell parse, so it is a guard against a model running a denied command by naming it, not a sandbox. A command that reaches the same program without spelling its name (`$(command -v sudo)`, `busybox sudo`, a copy of it renamed on `PATH`, or `sudo` reached through a variable) is not caught. `[sandbox] enabled = true` is what confines `bash` to writable roots, and it is off by default.

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

When enabled, writes outside the designated roots are blocked:
- **Kernel-level Landlock enforcement:** On Linux (kernels 5.13+), Landlock LSM rules are applied to microagent before executing tasks. The root `/` is marked read-only, while designated roots (current working directory, `/tmp`, the session directory, `$TMPDIR` where it names a directory none of the others covers, and any configured `writable` paths) remain read-write. Landlock restrictions are inherited across `execve` by all child processes (including `bash`, MCP servers, and child build tools).
- **Kernel-level Seatbelt enforcement:** On macOS, a Seatbelt profile (`sandbox_init`, the call behind `sandbox-exec`) denies file writes everywhere except the same roots (on this system `$TMPDIR` is under `/var/folders`, behind a symlink into `/private`, and is not covered by `/tmp`) and the devices `/dev/null`, `/dev/tty` and `/dev/dtracehelper`. Reads, the network and process creation stay allowed. Children inherit the profile as they inherit Landlock's rules. Apple deprecates the call but still uses it, and it is not in the tests that run on Linux: the profile text is, the enforcement on a Mac is not.
- **When the kernel does not enforce it:** an older Linux kernel, or a Seatbelt refusal, prints `microagent: sandbox: the kernel sandbox could not be applied ...` at startup, and only the in-process check below applies. That check covers the tools that write, not `bash` or MCP servers.
- **When one root is refused:** a root the kernel will not open or will not grant prints `microagent: sandbox: <root> was not made writable (<errno>); writes under it are refused`, and the rest of the roots are applied as usual. A root the kernel refuses the read-only rule for `/` is not one of these: nothing is enforced at all and the run prints the "could not be applied" line above.
- **In-process path checking:** The `write`, `edit` and `multi_edit` tools, and `ast` when it carries a `rewrite`, canonicalize their path and verify it resolves strictly within allowed roots before writing, returning `refused: path '...' is outside the sandbox writable roots`.

## Tools

Nine built-in tools, each a thin wrapper over a program you already have. `[tools.<name>]` turns any of
them off ([tool set](#tool-set)).

| tool | what it does |
| --- | --- |
| `bash` | `/bin/sh -c`, 120 s default timeout (the model may ask for up to 600 s), output capped at 24 KB. A command naming a credentials file or matching the command filter is refused, and the child inherits no provider credential. |
| `read` | read a file, with optional line offset and limit. Refuses credentials (`.env`, key and keystore files, anything under `.secrets` or `.ssh`), including a symlink to one, and refuses `/proc/*/environ` and `/proc/*/cmdline`. |
| `write` | create or overwrite a file, creating parents. Refuses a credentials path, a path outside sandbox roots when enabled, and a call with no `content`. |
| `edit` | exact string replacement. Refuses a credentials path, a path outside sandbox roots when enabled, an ambiguous match unless `replace_all`, and an edit that would leave `old_string` matchable in the result, so a repeated call cannot apply the change twice. |
| `multi_edit` | a list of `{path, old_string, new_string, replace_all}` replacements, in one file or across files, applied in order on the text the earlier ones left. Every edit is judged as `edit` judges it, and no file is written unless all are accepted, so a refusal names the edit and changes nothing; up to 64 edits per call. A file written part way says how many files had already landed. |
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
under a path no name table could have caught. The run's own keys are removed structurally: every
tool subprocess gets the environment minus the variables this binary sends in an `Authorization`
header, so `bash: env` has nothing to print. What remains open is the name rule itself: a
credential the tables do not recognize, and a path a command assembles at run time, are still read.
See [threat-model.md](threat-model.md).

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
from. Tool activity goes to stderr as a one-line gutter (`⏺ read: src/main.zig`, the name in bold
when stderr is a terminal and plain when it is a pipe or a file), with control
characters in a path or command written as `\xNN` so a line stays one line.
`NO_COLOR` set to anything but an empty string, or `TERM=dumb`, leaves the bold out even at a
terminal.

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
| 2 | wrong command line, or a config the run cannot start with: a bad value, a `[tools.<name>]` that names no tool, every built-in disabled |
| 3 | stopped without an answer: `--max-turns`, `--max-spend-tokens` or `--budget` reached, or the last response carried no text, was cut at `--max-tokens`, or the provider stopped generating it. stdout is a prefix of the work, not an answer. |
| 130 | interrupted (Ctrl+C or kill), taking the tool subprocess with it |

A wrong flag prints the reason and the full help on stderr, so a script reading stdout gets nothing
from a failed invocation.

### Session log

Each run appends one JSONL record per model response to `~/.microagent/sessions/<unix-ns>.jsonl`, so
a monitor can follow a run while it is going. A turn whose provider call never answered gets a record
of the same shape carrying the reason, so the log ends where the run ended rather than at the last
response that arrived. `MICROAGENT_SESSION_DIR` moves the store and an empty
value turns it off. A run that finds its name taken writes `-1`, `-2`, ... beside it rather than over
it. The store keeps the 200 most recent runs and prunes older ones, and it drops any log older than 30
days whatever the count says, so a machine that runs rarely does not keep every run it has ever done.

```json
{"ts":1790608347342,"cwd":"/home/you/Desktop/Projects/microagent","model":"deepseek/deepseek-v4-flash","finish_reason":"stop","served_model":"deepseek/deepseek-v4-flash-0726","fingerprint":"fp_9c1e","elapsed_ms":1448,"usage":{"prompt_tokens":998,"cached_tokens":896,"completion_tokens":19,"reasoning_tokens":16,"total_tokens":1017}}
```

```json
{"ts":1790608351204,"cwd":"/home/you/Desktop/Projects/microagent","model":"deepseek/deepseek-v4-flash","finish_reason":"","served_model":"","fingerprint":"","error":"ConnectionRefused","elapsed_ms":902,"usage":{"prompt_tokens":0,"cached_tokens":0,"completion_tokens":0,"reasoning_tokens":0,"total_tokens":0}}
```

| key | meaning |
| --- | --- |
| `usage` | this response's own counters, not the run's cumulative ones. Zero on a record carrying `error`, because no response was billed and none arrived. |
| `cwd` | the directory the run works in |
| `finish_reason` | why the provider stopped. `length` means the response was cut at `--max-tokens` and the run says so on stderr; the empty string is a stream that carried no reason, and every value on a record carrying `error`. |
| `model` / `served_model` / `fingerprint` | what the run asked for, what the provider says answered, and the weights fingerprint it reported. A gateway routes a name to whichever snapshot it holds that week, so two runs are comparable only when these match. Empty when the stream named none. |
| `error` | why the provider call never answered, on a record for a turn that failed rather than a turn that returned. Absent from a record for a turn that returned. |
| `elapsed_ms` | the model's time on this response, for tokens per second without tool time mixed in. Measured on a clock that stops while the machine is suspended (`--budget`, by contrast, counts suspend: it bounds wall time). |

A directory that cannot be created, or a log that cannot be opened or written, is named on stderr
and the rest of the run goes unrecorded. Nothing in the log is prompt or output text.
[toktop](https://github.com/maci0/toktop) reads this store by default, and the keys are the ordinary
OpenAI ones plus `cwd`, so any reader of agent transcripts works.

A log is created `0o600` and a store directory this run creates is `0o700`, so on a shared account
the last 200 runs are readable by the account that made them alone. Neither mode is applied to a
directory that already exists, so a store an operator pointed `MICROAGENT_SESSION_DIR` at keeps the
mode they gave it. `cwd` is the one field that names a person indirectly, since a working directory
under a home directory carries the account name in it; it is there because a monitor reports the run
by where it was, and it is the reason the modes above matter. Deleting the store is
`rm -r ~/.microagent/sessions`: nothing outside it holds anything from the run, and the binary never
reads a log back.

## Failure handling

- **Transient failures retry.** A 408, 409, 425, 429, any 5xx, or a connection that dies before the
  request reached the provider is retried twice, with 1 s and 2 s of backoff (or the provider's
  `Retry-After`, capped at 120 s), before the run exits non-zero. Any other rejection (401, 404) fails
  at once. A 400 does too, with one exception: when `--reasoning-effort` or `--temperature` is set,
  the request is sent once more without the `reasoning` and `temperature` fields, since some
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
microagent help update                    # the subcommand's own flags, environment and exits
```

The repository it installs from is the one this binary was built for, named by `default_repo` in
`src/update.zig`; a fork builds its own. There is no flag for it.

Each release publishes `microagent-<tag>-<triple>` for `x86_64-linux-musl`, `aarch64-linux-musl`,
`x86_64-macos` and `aarch64-macos`, each with a `.sha256` sidecar. Linux has one static asset per
architecture that links no C library (`musl` in the name is only the target triple), so it runs on
glibc and musl hosts alike and a `-gnu` build updates to it. Three of the four are started by CI
on a runner of their own platform; `aarch64-linux-musl` is the exception, because GitHub publishes
no arm64 Linux runner, so it is cross-compiled and its object format and rebuild are checked but it
is never executed there. The download is checked
against its sidecar, and the running binary is replaced atomically (following a symlink to the real
file) only when the digest matches. A mismatch, a missing asset, or a release page that is not a
GitHub https URL leaves the binary untouched. `GITHUB_TOKEN` lifts the anonymous API rate limit.
Exit 1 means the check or the install failed, 2 is a usage error; `microagent update --help`, or
`microagent help update`, has the rest.

## Versioning

The version is `build.zig.zon` and nothing else, and [CHANGELOG.md](../CHANGELOG.md) records what
changed in each. Under `0.y`, the minor takes features, any change to what a run does by default,
and anything removed; the patch takes fixes, and upgrading a patch must not change an existing
invocation. The release workflow refuses a patch tag whose changelog section has an `Added`,
`Changed`, `Removed` or `Security` entry, a section that is not the five Keep a Changelog headings
once each in order, a compare link under a heading that does not match the versions around it, and any tag while
`## [Unreleased]` still holds entries. A breaking change to the flags, the environment variables, or
the stdout and session-log JSON gets a changelog entry naming the before and the after. Only the
latest release is supported: a fix ships in the next release, with no backports.
