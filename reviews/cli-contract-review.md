Summary: flags, defaults, precedence, exit codes and JSON

# CLI and output contract

Your goal is to check argument parsing, configuration precedence, help, usage reference, man page,
CLI schema, exit codes and emitted JSON against each other.

Read and follow the [shared review protocol](README.md#review-protocol) in
`reviews/README.md` before starting. This file is a
reusable checklist, not a review report.

## Scope and priorities

Correct stale documentation with the smallest edit. Report any required change
to accepted options, defaults, exit codes or emitted JSON as a behavior change;
do not remove or weaken the contract to make the surfaces agree. Network and
benchmark implementation changes belong to their specialist reviews.

Prioritize missing or rejected options, incorrect defaults, wrong exit codes,
then JSON drift and wording.

## Checklist

1. **Options the parser takes but nothing documents.** Every branch in `parseArgs` in
   `src/main.zig` and in the update argument loop at `src/update.zig` names a flag. Find
   the branches that no line of `help_text` or of the update help text mentions, and the
   help lines with no branch. A branch reaches a flag by one of two routes: the
   `valued_flags` table for valued flags, and the
   `isFlag(name, short, long)` calls and other switch branches. Read
   the table and switch branches themselves, including mode and subcommand dispatch.
   Compare their complete inventory with the help, `microagent schema`, usage
   reference and man page; do not assume only two switches exist.

2. **Documented options that the binary does not take.** The `docs/usage.md` "Flags and environment" block
   reproduces the flag list, and the `OPTIONS` and `ENVIRONMENT` sections of `docs/microagent.1`
   are a second copy of it: `make check-man` proves only that every flag `--help` lists
   appears somewhere in the man page, never that the man page adds none, so a flag or env
   var named in either document that `parseArgs` and the env lookups in `main.zig` do not
   accept is a defect; so is an option the usage reference omits that the help text offers.

3. **Precedence that the code and the docs disagree about.** The help states that a flag
   wins over the environment variable for the same option. Trace one option end to end
   (for example `--max-turns` with `MICROAGENT_MAX_TURNS`, `--reasoning-effort` with
   `MICROAGENT_REASONING_EFFORT`) from the parse loop through the run of `envValue`
   overrides in `main` and the config resolution, and confirm the order in the code is the
   order the docs promise. Find those overrides by searching `envValue(`, not by line
   number: they move whenever a variable is added. One option does not come from that
   run: `--ca-bundle` is filled by `net.caBundlePath`, so a trace that reads only
   `envValue(` skips the variable the help names beside it.

4. **Empty-string semantics drift.** `help_text` names a specific set of variables that
   keep their default when set to the empty string, and a second set that falls through to
   the next source. `empty_is_unset_vars` in `src/main.zig` is the code's own list of the
   first set, so check each variable the help names against that list and against
   `envValue`. A new variable that reads the environment but is missing from
   the empty-string paragraph in the help is the common form of this defect.

5. **Defaults quoted in the help with no single source in the code.** Read the figures
   the help text carries at face value and check each against the constant the
   `comptimePrint` beside it prints: `--max-turns`, `--stall-timeout` and
   `--max-tokens` each name a default the help builds from
   `max_turns_default`, `default_stall_timeout_s` and `default_max_tokens` in
   `src/main.zig`, so a figure that moved is a number in one of those, never a
   literal to copy into this prompt. The session directory, the config path, and the
   update repository each carry a literal in the help text. Find the value the code
   actually falls back to and flag any literal that has drifted. A default that appears
   only in the help and only in the code is a defect even when the two agree today: it is
   the next edit that breaks them apart.

6. **Exit codes that the error paths do not return.** The help's "exit status" paragraph
   promises five: 0 for a finished run, 1 for a failed run, 2 for a wrong command line,
   3 for a run stopped at a ceiling, and 130 for an interrupted one. Check all five.
   `usageError`, `configError`, and every other `noreturn` error
   printer in the two files must exit with the code its class of failure implies, and a
   code the help names with no path that returns it is a finding the other direction.
   The update subcommand returns codes rather than printing them, so its `run` function
   is where a wrong one shows: `.unknown` carries 2 today, and the parse arms and the
   install path are where a code the update help names with no return is a finding.

7. **Subcommand and mode contracts.** Compare setup, update, schema, ACP and REPL
   dispatch with their help and documented examples. For update, check `--check`,
   help, version and JSON output against `parseArgs` and `usage_text` in
   `src/update.zig`. Trace repository selection, `GITHUB_TOKEN`, stdout output and
   which paths download or install an asset. For JSON-capable subcommands,
   verify `-o json` replaces the text output as documented; `schema` prints its
   document whatever `-o` says. For REPL and ACP,
   check per-prompt limits, session state and model-switching claims.

8. **Emitted JSON that no document matches.** `usage_fields` in `src/chat.zig` fixes
   the order of the five token counters, and it is one string in the two writers that
   print them: `logUsage` in `src/main.zig`, which writes the per-response usage line,
   and `sessionRecord` in `src/session.zig`, which writes it inside a record whose own
   keys are `ts`, `cwd`, `model`, `finish_reason`, `served_model`, `fingerprint`,
   `stream_error`, `elapsed_ms` and `usage`, plus the conditional `error` a record for a failed turn
   carries and a record for a returned one omits. Compare both writers
   against docs/usage.md and the CHANGELOG claims about the log. A key renamed in a writer but
   not in the prose, or a counter emitted in a different order than promised, is a
   defect: a consumer parses this.

9. **Tools the model is offered.** The "Tools" table in `docs/usage.md` counts the tool set
   and names each one, and the help text's `[tools.<name>]` paragraph lists the
   built-ins too. Compare both lists with the schemas; a tool the array offers that
   either lacks is this item's finding in the direction the caller reads it. The paragraph under that table already
   carries the `skill` tool and the `mcp__<server>__<tool>` entries
   `extraToolsJson` appends at run time, so their absence from the table is not a
   finding.
   Read the schemas in `tools_json` in `src/main.zig`, the array the request body is
   built from, and name them one by one; a repo-wide count of the `"type":"function"`
   literal also matches a test fixture elsewhere in the file, and a count taken that way
   reports a tool that is not offered. The count and byte size
   `docs/benchmark.md` states about the same array belong to
   `reviews/benchmark-accuracy-review.md`; this item is the list the caller is offered.

10. **Version copies that drift.** `build.zig.zon` owns the version. Check current
    release references in the README, man page and security policy against it,
    and check the built binary's version. Historical versions, example tags and
    parser fixtures are intentional literals, not duplicate sources of truth.
