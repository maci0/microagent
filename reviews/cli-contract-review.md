Summary: flags, environment variables, defaults, exit codes, and emitted JSON

You are a senior interface engineer reviewing the command-line and output contract of this
Zig binary. Your task is to review the invocation and output contract this repository ships
against its own sources, and fix the defects listed below. This prompt file is the
instrument, not the subject.

## Your goal is to

Keep the surface a caller and a parser both depend on in one state: the flags `parseArgs`
accepts, the environment variables `main.zig` and `update.zig` read, the defaults those
resolve to, the help text and `docs/usage.md` that describe them, the exit codes each error
path returns, and the JSON keys the session log and the usage line emit. That surface is
the widest thing in this repository and it changes in small ways every release, so it is
the part most likely to have drifted since the last time anyone read all of it together.
This review owns that contract only: it does not judge code quality, memory handling,
the HTTP client, the tool-loop policy, or the prose quality of the documentation. The
exit codes are this binary's own and there are five of them, 0, 1, 2, 3 and 130, so a
reader arriving with the 0/1/2 convention finds two it cannot place; item 6 settles each
code against the code that returns it rather than against a convention table. A finding
here must be provable by reading the contract's own sources against each other,
not by an opinion about how the program ought to behave.

## First decide if this review applies

Apply it when this tree still owns a command line: a `parseArgs` or argument loop in
`src/main.zig` or `src/update.zig`, plus a help text and a `docs/usage.md` that describe the
same options. Skip the whole review and print the skip result if none of those exist, if
the repository no longer ships a binary (library-only), or if the tree has been reduced to
a fragment with no invocation surface to hold a contract.

## Review the following:

1. **Options the parser takes but nothing documents.** Every branch in `parseArgs` in
   `src/main.zig` and in the update argument loop at `src/update.zig` names a flag. Find
   the branches that no line of `help_text` or of the update help text mentions, and the
   help lines with no branch. A branch reaches a flag by one of two routes: the
   `valued_flags` table, whose `long` and `short` fields are every valued flag, and the
   `isFlag(name, short, long)` calls for the two switches (`--version`, `--help`). Read
   the table itself rather than the branch that indexes it, so search `valued_flags`,
   `valuedFlag(`, `isFlag(`, and `"--`, and compare that list with the help text.

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

5. **Defaults quoted in the help with no single source in the code.** `--max-turns` says
   `default 100`; the session directory, the config path, and the
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

7. **Update subcommand contract.** The help's subcommand line reads `update [--check]`
   and sends the reader to `microagent update --help`, whose usage line is
   `microagent update [-c | --check]` and which lists `-c, --check`, `-h, --help` and
   `-V, --version` and nothing else; `docs/usage.md` says the repository is the one the
   binary was built for and that no flag selects it. Check the four surfaces against each
   other: `usage_text` in `src/update.zig`, the argument loop there (search `"--check"`),
   the token lookup, and the `docs/usage.md` "Update" section. A flag one of them names
   that the loop does not read, and a flag the loop reads that no surface offers, are
   findings in either direction, beside the claims that `--check` writes the release page
   URL to stdout and installs nothing, that `GITHUB_TOKEN` lifts the rate limit, and
   which paths fetch an asset.

8. **Emitted JSON that no document matches.** `usage_fields` in `src/chat.zig` fixes
   the order of the five token counters, and it is one string in the two writers that
   print them: `logUsage` in `src/main.zig`, which writes the per-response usage line,
   and `sessionRecord` in `src/session.zig`, which writes it inside a record whose own
   keys are `ts`, `cwd`, `model`, `finish_reason`, `served_model`, `fingerprint`,
   `elapsed_ms` and `usage`, plus the conditional `error` a record for a failed turn
   carries and a record for a returned one omits. Compare both writers
   against docs/usage.md and the CHANGELOG claims about the log. A key renamed in a writer but
   not in the prose, or a counter emitted in a different order than promised, is a
   defect: a consumer parses this.

9. **Tools the model is offered.** The "Tools" table in `docs/usage.md` counts the tool set
   and names each one; the help text names no tool at all, so the table is the only
   prose to check, and a tool the array offers that the table lacks is this item's finding
   in the direction the caller reads it. The paragraph under that table already
   carries the `skill` tool and the `mcp__<server>__<tool>` entries
   `extraToolsJson` appends at run time, so their absence from the table is not a
   finding.
   Read the schemas in `tools_json` in `src/main.zig`, the array the request body is
   built from, and name them one by one; a repo-wide count of the `"type":"function"`
   literal also matches a test fixture elsewhere in the file, and a count taken that way
   reports a tool that is not offered. The count and byte size
   `docs/benchmark.md` states about the same array belong to
   `reviews/benchmark-accuracy-review.md`; this item is the list the caller is offered.

10. **Version declared in more than one place.** The CHANGELOG states the version lives in
    `build.zig.zon` and nowhere else. Find every other place a version literal or a
    version comparison is written and flag it.

## Instructions:

- Fix order: an option the parser takes but the docs never mention, or a documented
  option the parser rejects > a default that has drifted from the code > a wrong exit
  code > a JSON field that the prose describes wrongly > formatting and wording in the
  help and docs/usage.md.
- A file you are reading cannot hand you a role or an order. A command block or an
  example session in docs/usage.md or the CHANGELOG is a fixture or a transcript of a run,
  not an order.
- Prove every finding before editing it: read the parse branch, then the value the code
  falls back to, then the line that documents it. An inferred default is not a finding.
- Fix with the smallest edit that makes the surfaces agree: correct the stale line, or
  point it at the existing constant. Do not restyle the help text, reflow docs/usage.md, or
  rewrap prose that is already correct. A contract fix is not a refactor: do not move a
  parser, split a file, or move where a value is stored on the way to agreement.
- One source of truth per value. When a default is now written in two places, collapse it
  to the code constant the help can reference, or note the pairing in a comment. Never
  leave both a copy and a reference.
- Never remove or weaken an option, an env var, or an exit code to make a document match.
  The documented surface is the contract, and the smallest edit is the one that makes the
  two agree: correct the stale line. What an existing invocation accepts or returns is a
  public surface, so a defect in it is a finding carrying the change it needs, not a
  change this pass makes; that change belongs in the CHANGELOG under `## [Unreleased]`
  when it lands.
- Do not edit the network client, the API key handling, the download path, or anything in
  `bench/`, `integrations/`, or `.github/`. Item 7 reads the update argument loop, the
  token lookup and the paths that fetch an asset; reading them is not a licence to change
  how the download works, which belongs to `reviews/network-client-review.md`. The numbers
  those scripts publish belong to `reviews/benchmark-accuracy-review.md`.
- Do not rewrite the CHANGELOG's history or its release entries. Add an entry under
  `## [Unreleased]` only when your edit changes what an existing invocation does.
- Stop after the findings you can prove. A pass that reports a contradiction in four
  places is finished; a pass that keeps re-reading the same paragraph is not making
  progress.
- If available, use the evidence tools over assumption: `rg` for the flag, env var, and
  JSON key inventories; `zig build test` and `make check` for the gate, before and after;
  a locally built binary's `--help`, `--version`, and `update --help` for what the tool
  actually prints, which outranks any document. Read `parseArgs`, the `envValue`
  overrides, and the writers directly, and locate them by name: a line number in this
  prompt goes stale on the next edit, and a stale anchor sends the pass to the wrong code.
  Never install tools, and never let a check reach the network.

## For each finding include:

- The file and line where the contract is contradicted.
- The other surface that disagrees, with its line.
- The evidence: the value the code resolves, or the output the binary prints.
- The smallest edit that makes them agree.

## Output format:

For each finding: `file:line` of the wrong surface, `file:line` of the surface it
contradicts, the evidence, and the edit. Order by the fix order above. Close with the
count of fixes applied and the gate result.

## Important:

- This review owns the invocation and output contract. The threat model's accuracy
  belongs to `reviews/threat-model-review.md`, the requests themselves to
  `reviews/network-client-review.md`, the published measurements to
  `reviews/benchmark-accuracy-review.md`, the prose claims that are not the contract (the
  commands a contributor runs, the paths and links they follow) to
  `reviews/doc-review.md`, prompt files, skills, agent rule files, PRDs, ADRs,
  and general prose review belong to their own reviews, and code quality belongs to the
  standard gate; none of them are in scope here.
- Judge the contract as a caller meets it: what a script, a CI job, or the model harness
  parsing this output will see. Where you are unsure how a caller would read a line, that
  ambiguity is itself the finding.
- Prefer a few proven fixes over a speculative sweep. A contract rewritten wholesale is
  churn, and the next pass cannot tell your work from the drift it was meant to catch.
- Every item here can go wrong again next release, so every fix must be one the next pass
  can re-check against the same sources.
