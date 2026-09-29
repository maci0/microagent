# microagent

A tiny coding agent in Zig, built to be driven by [gauntlet](https://github.com/maci0/gauntlet)
loops. One binary, one loop, OpenAI-compatible APIs only.

- **Small.** ~840 KB stripped (`-Doptimize=ReleaseSmall`), no runtime, no node, no python.
- **Fast.** ~2.5 ms to start, so a gauntlet loop spends its time in the model, not the harness.
- **No features you did not ask for.** No subagents, no plugins, no MCP, no TUI. Streaming chat
  completions, seven tools, done.

## Build

Zig 0.16.0 or newer, the minimum declared in `build.zig.zon`, which is the version
the release binaries are built with. Nothing else: no dependencies, no services,
no runtime.

```sh
zig build -Doptimize=ReleaseFast      # zig-out/bin/microagent
zig build -Doptimize=ReleaseSmall     # smallest binary, ~840 KB
zig build test --summary all          # unit tests
```

`--summary all` is what prints the pass count. Without it the build system
prints only failures, so a green run says nothing at all under the transcript
the suite writes to stderr, and `make test` and both workflows pass the flag
for that reason.

Every target is also a make target, and `make help` lists them:

```sh
make                                   # ReleaseFast build, the default target
make help                              # every target
make test                              # the whole suite
make test-sanitize                     # the same suite under the undefined-behavior sanitizer
make test-one FILTER="usage counters"  # one test, by name substring
make watch                             # rerun the suite on every source change, Ctrl-C to stop
make watch FILTER="usage counters"     # the same, narrowed to one test
make check                             # the CI gate: fmt --check, linters, tests, ReleaseSmall build
make preflight                         # name any tool the gate needs that is not on PATH
```

`make check` runs what [CI](.github/workflows/ci.yml) runs on a push, on
the Zig version `build.zig.zon` names, so run it before pushing. CI names the
targets one by one rather than calling it whole, because the linters are
installed in their own job. Besides Zig it
needs `shellcheck`, `ruff`, `yamllint` and `git` on `PATH` for the bench, Harbor
and `.github` sources; `make preflight` names whichever is missing, and
`make lint-versions` names the pinned `ruff` and `yamllint` the gate runs.
`zig fmt` covers the Zig and needs nothing else.

## Use

```sh
export MICROAGENT_API_KEY=sk-or-...             # or OPENAI_API_KEY / OPENROUTER_API_KEY / DEEPSEEK_API_KEY
export MICROAGENT_BASE_URL=https://openrouter.ai/api/v1
export MICROAGENT_MODEL=deepseek/deepseek-v4-flash

microagent -p "fix the failing test and run it"
```

The flags, abridged; `microagent --help` is the full text.

```
-p, --print <prompt>   task to run (also accepted as a bare argument)
-m, --model <model>    model id        (env MICROAGENT_MODEL,
                       default deepseek/deepseek-v4-flash)
-b, --base-url <url>   OpenAI-compatible base url (env MICROAGENT_BASE_URL,
                       default https://openrouter.ai/api/v1);
                       https, or http on loopback
-k, --api-key <key>    api key         (env MICROAGENT_API_KEY, OPENAI_API_KEY,
                       OPENROUTER_API_KEY, DEEPSEEK_API_KEY); sent to the base
                       url, so name a base url from the same provider as the key
    --max-turns <n>    tool-loop turn ceiling, at least 1
                       (env MICROAGENT_MAX_TURNS, default 100)
    --stall-timeout <s>
                       seconds the response socket may stay silent before
                       the read fails (env MICROAGENT_STALL_TIMEOUT, default 120)
    --max-tokens <n>   max_tokens sent to the provider: the ceiling on one
                       response's generated tokens, at least 1
                       (env MICROAGENT_MAX_TOKENS, default 65536)
    --config <file>    reply-style TOML config (env MICROAGENT_CONFIG)
    --ca-bundle <file>
                       PEM file to trust instead of the system store
                       (env MICROAGENT_CA_BUNDLE, SSL_CERT_FILE). Needed in
                       images that ship no ca-certificates.
    --budget <seconds> stop starting turns after this long, then take one last
                       turn to make the edit, which may run 5 minutes past it; a
                       turn cut off there is discarded, not half-applied. At
                       least 1, and leaving it out is what says "no budget"
                       (env MICROAGENT_BUDGET_SECONDS)
    --max-spend-tokens <n>
                       stop starting turns once the run has billed this many
                       tokens, prompt and completion together. Neither turn
                       count nor --max-tokens bounds what a run spends, since a
                       turn re-sends the whole conversation. At least 1, and
                       leaving it out is what says "no ceiling"; the run says
                       on stderr when it passes 80% of it
                       (env MICROAGENT_MAX_SPEND_TOKENS)
    --reasoning-effort <level>
                       reasoning.effort sent to the provider: minimal, low,
                       medium, high, or none to disable (env MICROAGENT_REASONING_EFFORT)
-h, --help             the full usage text ("help" as the only argument too)
-V, --version          version

A bare -- ends the flags, so a task that begins with a dash goes after it:
microagent -- "explain why -Werror fails in src/net.zig"

reply style (env, or the TOML config at MICROAGENT_CONFIG, default
~/.microagent/config.toml with the keys "caveman" and "ponytail"):
  MICROAGENT_CAVEMAN     how terse the reply is: off, lite, full, ultra,
                         wenyan-lite, wenyan-full, wenyan-ultra
                         (default ultra)
  MICROAGENT_PONYTAIL    how lazy the code is: off, lite, full, ultra
                         (default full)

session log:
  MICROAGENT_SESSION_DIR where the per-response JSONL session log goes
                         (default ~/.microagent/sessions; empty writes none)

subcommand:
  update [--check] [--repo owner/name]
                         replace this binary with the latest GitHub
                         release after verifying its .sha256 sidecar
                         (--check only reports; GITHUB_TOKEN lifts the
                         API rate limit)

output: stdout carries the model's text and one JSON line per response,
{"type":"usage","usage":{...}}, and nothing else. stderr carries the tool
gutter, the notes and every error, so a script reading stdout gets the
answer and the token counters.

MDEBUG=1                trace a stuck stream on stderr, and print the
                        configuration this run resolved (never the key). 0,
                        off, no, false and an empty value all leave it off.
```

Every long flag also takes `--flag=value`, and a flag wins over the environment variable for the
same option. The exit status is 0 for a finished run, 1 for a
failed one, 2 for a wrong command line, 3 for a run that stopped without an answer (a ceiling
reached: `--max-turns`, `--max-spend-tokens`, a budget that ran out, or a last response that
carried no text, was cut at `--max-tokens`, or that the provider stopped generating) so the text
on stdout is a prefix of the work rather than an answer, and 130
for an interrupt, which takes the tool subprocess with it. A wrong flag prints the reason
and the full help on stderr, so a script reading stdout gets nothing from a failed invocation.

Every value is checked where it is set, so a mistyped level, a ceiling of zero
or a non-numeric budget is refused before the first request rather than becoming
a 400 or an empty run. The key is sent to the base url, and a run that sets
neither ends up at `https://openrouter.ai/api/v1` with `deepseek/deepseek-v4-flash`,
so a key read from `OPENAI_API_KEY` or `DEEPSEEK_API_KEY` and left there goes to
OpenRouter; the run says so on stderr before the first request. A base url named
on the command line or in `MICROAGENT_BASE_URL` is where the key goes, including a
self-hosted gateway that takes a key from any provider. A variable set to an empty
string is not a value:
`MICROAGENT_MODEL`, `MICROAGENT_BASE_URL`, `MICROAGENT_REASONING_EFFORT`,
`MICROAGENT_BUDGET_SECONDS`, `MICROAGENT_MAX_SPEND_TOKENS`, `MICROAGENT_MAX_TURNS`,
`MICROAGENT_MAX_TOKENS`, `MICROAGENT_STALL_TIMEOUT` and `MDEBUG` keep their defaults, the four
api key variables fall through to whatever comes next, `MICROAGENT_CA_BUNDLE` falls through to
`SSL_CERT_FILE`, and
`MICROAGENT_CAVEMAN`/`MICROAGENT_PONYTAIL` fall through to the config file.
Two variables are the exception: `MICROAGENT_CONFIG` and `MICROAGENT_SESSION_DIR`
read empty as off, so no style file and no session log.

Every variable is trimmed before it is read, `HOME` included, and one holding
nothing but whitespace reads as the empty case above. A wrapper that populates the
environment from a file exports the newline that file ended with, and that
newline is a different failure per option: an api key reaches the provider as an
`Authorization` header carrying a byte a header may not hold, so every request
is refused, a base url stops parsing, and a session directory names a directory
the run creates and no monitor ever looks in. The same newline on `HOME` would
put every default path (`~/.microagent/config.toml`, the session store, the key
file) one directory that does not exist, and an empty `HOME` is no home rather
than a path off the root. A base url that does not parse
anyway is refused as the typo it is, before the plaintext check that would
report it as a key about to go out in the clear.

The prompt may also be the last bare argument. That matters for gauntlet: a custom-agent
definition inserts the model flags immediately after `-p`, so an agent defined as
`["microagent", "-p", "{prompt}"]` would hand `--model` to `-p`. Define it as
`["microagent", "{prompt}"]` instead, and any flag order works.

With no key in the environment, `~/.secrets/openrouter` is read as a last resort; a file there that
is empty is named on stderr rather than passed off as no key at all.

Any OpenAI-compatible endpoint works: OpenRouter, DeepSeek, OpenAI, vLLM, LiteLLM, Z.AI. Both
`deepseek/deepseek-v4-flash` and `stealth/space-bunny-alpha` (OpenRouter) were used to verify it
end to end; see [BENCHMARK.md](BENCHMARK.md). What the harness itself costs per turn, which
levers were pulled and which were deliberately not, is in
[PERFORMANCE.md](PERFORMANCE.md).

The api key goes to the base url in an `Authorization` header on every request, so a plain `http://`
base url is refused before the first one unless the host is loopback (`localhost`, `127.0.0.0/8`,
`::1`): a local gateway is the one plaintext case with no network path to intercept.

### Reply style

Two prompt-level knobs, set in one TOML file so a gauntlet loop, a container run and a laptop all
start the same way. Neither touches the tools or the request shape: both are text appended to the
system prompt, and the conversation is still the plain OpenAI message array.

```toml
caveman  = "ultra"   # how terse the reply is
ponytail = "full"    # how lazy the code is
```

The keys may also sit under a `[style]` table, and `#` comments are fine. That is the whole
configuration surface, so the file is read as `key = "value"` lines rather than with a full TOML
parser.

- **`caveman`** compresses the prose the agent writes back: `off`, `lite`, `full`, `ultra`, plus the
  three `wenyan-*` levels that write the reply in classical Chinese (a bare `wenyan` is
  `wenyan-full`). Default `ultra` — a coding
  agent is judged on the diff, and every paragraph about it is re-sent on every later turn.
  Technical terms, code, commands, paths and exact error strings are never compressed, a negation is
  never dropped, and security warnings stay in plain English.
- **`ponytail`** biases what the agent builds rather than how it talks: `off`, `lite`, `full`,
  `ultra`. Reuse a helper the repository already has before writing a new one, the standard library
  and native platform features before a dependency, and the smallest diff that fixes the root cause
  rather than the symptom. Default `full`: a harness that writes fifty lines where five would do is
  the thing this project exists to avoid. Never at the cost of input validation at a trust boundary,
  error handling that prevents data loss, security, accessibility, or anything the task asks for.

The file is `MICROAGENT_CONFIG`, else `~/.microagent/config.toml`; a missing file means the defaults, and
one that is there but cannot be read, is a directory, or is over the 64 KB cap says so on stderr before
the run continues on the defaults. [`config.example.toml`](config.example.toml) is a commented template
with both keys and their defaults. `MICROAGENT_CAVEMAN` and `MICROAGENT_PONYTAIL` set a level for one run
without touching the file and win over it, since naming a level in the environment is the more explicit
statement. A level that is not recognized is reported on stderr with that key's default kept, and so
is a key this file does not define, so a misspelled `caveman` cannot leave the default in force
quietly. With `caveman = "off"` and `ponytail = "off"`, the system prompt is exactly the one the
harness sent before styles existed.

`MDEBUG=1` prints the configuration the run resolved: model, base url (credentials in it redacted),
the ceilings, the level each style key took, the style config file that was read, and the name of
the variable or file the API key came from. The key itself is never printed. Precedence spans three
sources per option, so this is how you tell which one answered.

### Output contract

stdout carries the model's own text, one JSON usage line per response, and nothing else:

```json
{"type":"usage","usage":{"prompt_tokens":910,"cached_tokens":832,"completion_tokens":18,"reasoning_tokens":0,"total_tokens":928}}
```

Token counters are cumulative for the run, which is the shape gauntlet's usage reader takes its
maximum from. Tool activity goes to stderr as a one-line gutter (`⏺ read src/main.zig`) so it never
pollutes the agent's answer. Control characters in a path or command are written as `\xNN`, so a line
stays one line whatever the model sent.

`cached_tokens` is the part of the prompt the provider served from its prompt cache. The whole
conversation is re-sent every turn, byte for byte: no message is ever dropped, reordered or
re-spelled, and the system prompt and tool schema never change, so the prefix stays cacheable and a
turn pays full price only for what it just added. The one exception is compaction, which past 400 KB
of conversation replaces the content of the oldest large tool results with a
`[earlier tool output elided: N bytes]` marker and leaves everything ahead of the first one
untouched, so a long run stops re-sending files it has already acted on. The marker is this program
writing into a tool message, so the system prompt names it as such and tells the model to run the
tool again if it needs what the result said, rather than reading it as output the tool produced.
One turn's tool results stop at 256 KB, which 64 calls at the 24 KB per-result cap would
pass four times over: past it a result is replaced with a `[tool output not carried: ...]`
marker, the call itself still ran, and the model is told the output is gone rather than
left to read an empty result as a tool that found nothing. Watch the counter on a
multi-turn run — it should climb with the conversation, and dip at the turn a compaction lands on.
It is read from whichever of `prompt_tokens_details.cached_tokens`, `prompt_cache_hit_tokens` or
`cache_read_input_tokens` the endpoint sends.

### Session log

Each run appends one JSONL record per model response to `~/.microagent/sessions/<unix-ns>.jsonl`
(`MICROAGENT_SESSION_DIR` moves it, an empty value turns it off), so a monitor can follow the run
while it is still going. A directory that cannot be created, or a log that cannot be opened or
written, is named on stderr and the rest of the run goes unrecorded: a store a monitor reads that
stays empty is worth one line. A run that finds its name taken takes the next one (`-1`, `-2`, ...),
so a re-launched run writes beside the earlier log rather than over it:

```json
{"ts":1790608347342,"cwd":"/home/maci/Desktop/Projects/microagent","model":"deepseek/deepseek-v4-flash","finish_reason":"stop","served_model":"deepseek/deepseek-v4-flash-0726","fingerprint":"fp_9c1e","elapsed_ms":1448,"usage":{"prompt_tokens":998,"cached_tokens":896,"completion_tokens":19,"reasoning_tokens":16,"total_tokens":1017}}
```

One response's own counters, not the run's cumulative ones, plus the directory the run works in and
how long the model spent on that response. `finish_reason` is why the provider stopped: `length`
means the response was cut at `--max-tokens`, so the turn is a prefix of what the model meant to
say, and the run says so on stderr rather than reporting it as a finished answer. The empty string
is a stream that carried no reason at all. `model` is what the run asked for and `served_model` is
what the provider says answered, beside the `fingerprint` it reports for the weights: a gateway
routes a model name to whichever snapshot it holds this week, so two runs of one command are only
comparable when the record says which of them produced each response. Both are empty strings when
the provider's stream named neither. The store keeps the 200 most recent runs and prunes the
older ones, so a machine that runs this in a loop does not accumulate a log per review forever.
`elapsed_ms` is the model's time, so a reader computes
tokens per second the model actually generated instead of over a gap that includes tool calls. It is
measured on a clock that stops while the machine is suspended, so a laptop closed mid-response does
not report the sleep as generation time. (`--budget` deliberately does count the suspend: it is a
ceiling on wall time, not on work done.)
[toktop](https://github.com/maci0/toktop) reads this store by default; the counters and the
directory are the ordinary OpenAI keys and `cwd`, so any reader of agent transcripts works. Nothing
in the log is prompt or output text.

## Update

```sh
microagent update                         # replace this binary with the latest release
microagent update --check                 # report the latest release, install nothing
microagent update --repo you/microagent   # track a fork
```

The release publishes `microagent-<tag>-<triple>` for `x86_64-linux-musl`, `aarch64-linux-musl`,
`x86_64-macos` and `aarch64-macos`, each with a `.sha256` sidecar. Linux has one asset per arch and
not one per libc: the static musl binary runs on a glibc host, so a `-gnu` build updates to it. The
download is verified against that sidecar and the running binary is replaced
(atomically, following a symlink to the real file)
only when the digest matches: a mismatch, a missing asset, or a release page that is not a GitHub
https URL leaves the binary untouched. `GITHUB_TOKEN` lifts the anonymous API rate limit. Exit 1
means the check or the install failed, 2 is a usage error.

## Versioning

The version is `build.zig.zon` and nothing else, and [CHANGELOG.md](CHANGELOG.md) is the record of
what changed in it. The project is under `0.y`, so the minor takes features, any change to what a
run does by default, and anything taken away, and the patch takes fixes: upgrading a patch must not
change an existing invocation. The release workflow refuses a patch tag whose changelog section
carries an `Added`, a `Changed` or a `Removed` entry, refuses a tag whose section is not the five
Keep a Changelog headings once each in order, and refuses any tag while `## [Unreleased]`
still holds entries. Breaking changes to the flags, the environment variables or the stdout and
session-log JSON come with a changelog entry naming the before and the after, before the tag. Only
the latest release is supported, with no backport window: a fix ships in the next release.

## Tools

Seven tools, all of them thin wrappers over tools you already have:

| tool | what it does |
| --- | --- |
| `bash` | `/bin/sh -c`, 120 s default timeout (600 s ceiling on what the model may ask for), output capped at 24 KB; a command naming a credentials file is refused, and the child inherits no provider credential |
| `read` | read a file, optional line offset/limit; refuses credentials (`.env`, key and keystore files, anything under `.secrets` or `.ssh`), including a path that is a symlink to one |
| `write` | create or overwrite a file, parents created; refuses a credentials path, and a call with no `content` |
| `edit` | exact string replacement, refuses a credentials path, refuses an ambiguous match unless `replace_all`, and refuses an edit that would leave `old_string` matchable in the rewritten file, so a repeated call cannot apply the change again |
| `search` | `rg --line-number --no-heading`, optional glob; credentials files excluded |
| `ast` | `ast-grep run` for structural match, or `--rewrite --update-all` to apply one; credentials files excluded |
| `git` | read-only `status`, `diff`, `log`, `show`, `blame`, capped at 400 lines; a credentials path is refused |

The system prompt tells the model to search with ripgrep and rewrite structurally with `ast-grep`
rather than reimplementing either in the harness. `bash` is there for builds and tests; git state
has its own tool, with the subcommands fixed here instead of assembled by the model. Those three
programs have to be on `PATH`: `search` needs `rg`, `ast` needs `ast-grep`, `git` needs `git`. A
stock macOS ships only the last of them, so a machine without the other two is told which program
is missing and how to install it rather than handed an error code.

The stream is delivered at least once, so a turn's tool calls are deduplicated by the id the
provider gave them before anything is dispatched: a relay that reconnects replays frames, and a
replayed call is a `bash` run twice or a `write` over a file the first pass already changed. The
first delivery is what runs, the repeat is named on stderr, and two calls that are identical but
carry different ids are two calls.

Everything a tool returns is untrusted text on its way back into the prompt: a file, a diff, a
build log. The system prompt says so, and tool results ride back as `tool` messages, so a
repository that ships a file telling the model to run something is data the run reports rather
than an instruction it follows. The other bound on the same loop is `max_tokens` on every
request: without it a model that fails to stop is billed until something else stops it, and
`--max-turns` is a turn count, not a token count.

A credential is the one thing a `read` refuses. Its result goes into the conversation, and the
conversation is re-sent to the provider on every turn after it, so a `read` of `.env`, a `.pem`,
an `id_ed25519` or `$HOME/.secrets/openrouter` would ship a key to a third party and keep
shipping it. `search` and `ast` leave the same files out of their results, `git` refuses one
named as a path, and `bash` refuses a command whose words name one, because a match, a patch
and a `cat` are all tool results. `write` and `edit` refuse the same names, because a run that
may not read a key file has no business replacing one with a guess. The run's own credentials
are the other half, and it is closed structurally: every tool subprocess gets the environment
minus the variables this binary sends in an `Authorization` header, so `bash: env` and
`bash: printenv` have nothing to print. The name is read twice, once over the bytes the model
sent and once over the path a symlink on it resolves to, so a link committed in a repository
under an ordinary name does not carry a key out through the file it points at. What is left is
the name rule itself: a credential the tables do not recognize, and a path a command assembles
at run time, are still read.

A transient failure — 429, any 5xx, a connection that dies before the request reached the provider —
is retried twice with 1 s and 2 s of backoff before the run exits non-zero, so a provider's bad
minute does not make gauntlet redo a review against a tree the agent has already half-changed. A
rejected request (400/401/404) fails immediately instead. One failure is not retried at all: a
response that never arrives after the whole turn was sent. The provider had the request, so the
completion may already have been generated and billed, and a second POST of the same turn is a
second billable completion, so that run ends with the connection error named on stderr rather than
paying twice for one turn. A failure the provider reports part way through a
stream is named in its own words on stderr and ends the run, because the response head was 200
long before it and whatever reached stdout is a prefix of an answer it abandoned; the turn is not
re-sent, for the same reason the missing response is not. Session resume is deliberately absent; gauntlet's `--retries` covers a
whole review, and a missing feature is cheaper than a half-working one.

## gauntlet

Recent gauntlet builds know microagent as a built-in agent: `gauntlet doctor` lists it, and
`gauntlet -a microagent -r quick --once` works with no configuration. On an older release that
refuses it as an unknown tool, register it once in `~/.gauntlet/agents.json`:

```json
{
  "microagent": {
    "argv": ["microagent", "{prompt}"],
    "model": ["--model", "{model}"],
    "note": "microagent: tiny zig OpenAI-compatible coding agent"
  }
}
```

Delete that entry once gauntlet ships the built-in: a definition file naming a built-in agent is
refused at startup rather than ignored.

Then:

```sh
gauntlet doctor                       # microagent should show as installed
gauntlet -a microagent -r quick --once
gauntlet -a microagent:deepseek/deepseek-v4-flash -j 4
MICROAGENT_BUDGET_SECONDS=600 gauntlet -a microagent -r quick --once
```

Set a budget below gauntlet's `-t` timeout. A review the harness kills at the ceiling with an
untouched tree is worth nothing; one that stops deliberately still has the model's diff. Note that
gauntlet scoring a review "Passed" does not mean a diff landed — score with `git diff --numstat` and
a real check, the way `bench/gauntlet.sh` does. Review outcomes per harness, including which models
converged and which burned the budget, are in [BENCHMARK.md](BENCHMARK.md#usefulness).

No `stream` flags are needed: usage is always machine-readable. No session transcripts are written,
so no `usage.roots` entry is required either.

## Security

The agent runs shell commands as you do, on files it reads, so the repository it works in and
the endpoint it talks to are both part of the surface. [THREAT_MODEL.md](THREAT_MODEL.md) has the
entry points, the boundaries, the controls that exist and the gaps, each with a file reference.

## External benchmarks

microagent runs on [Harbor](https://github.com/laude-institute/harbor) benchmarks — Terminal-Bench 2
and SWE-bench Verified — as a static musl binary inside the task container:

```sh
make musl
PYTHONPATH=$PWD/integrations/harbor ~/harbor-venv/bin/harbor run \
  -d swebench-verified@1.0 -i pytest-dev__pytest-5809 \
  -a microagent_agent:Microagent -m deepseek/deepseek-v4-flash
```

See [integrations/harbor/README.md](integrations/harbor/README.md) and
[BENCHMARK.md](BENCHMARK.md#swe-bench-verified).

## License

MIT, in [LICENSE](LICENSE). The file ships in the package `build.zig.zon`
describes, so the grant travels with the source a consumer fetches.

## Benchmarks

```sh
make bench AGENTS="microagent kimi"     # three coding tasks, pass/fail + wall time + tokens
make overhead                           # startup latency and no-op request cost per harness
```

Each builds `zig-out/bin/microagent` first and puts it on `PATH` for the run, so
the harness under measurement is the tree you just edited rather than whichever
copy happens to be installed. The scripts take the same arguments and work
against any harness already on `PATH`:

```sh
sh bench/run.sh microagent kimi opencode
sh bench/gauntlet.sh microagent kimi    # gauntlet reviews, scored on pass + diff + verify
sh bench/overhead.sh
```

Run against a fresh clone without a `make bench` first, every harness is skipped
by name, so the run reports nothing and appends nothing.

Results from this machine are in [BENCHMARK.md](BENCHMARK.md).

## Deterministic tools the agent can drive

Beyond the built-in tool set, the agent runs the machine's own tools through `bash`, and the
system prompt tells it to prefer them over ad-hoc work: `rg` for text, `ast-grep` for syntax,
`semcode` for semantic queries over an indexed C/C++/Rust database, `git` for history and diffs.

semcode needs a git repository and an index before it can answer:

```sh
semcode-index -s . --extensions c,h,rs   # writes ./.semcode.db
semcode -q "callers parse_config"        # callers, callees, types, macros
```
