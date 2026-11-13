Summary: measurement methods, scripts and published figures

# Benchmark accuracy

Your goal is to check published figures in `docs/benchmark.md` and `docs/performance.md` against
`bench/`, committed results, baselines and `integrations/harbor/`.

Read and follow the [shared review protocol](README.md#review-protocol) in
`reviews/README.md` before starting. This file is a
reusable checklist, not a review report.

## Scope and priorities

Preserve recorded measurements and result rows. Distinguish historical runs
from claims about the current tree: a changed writer or default agent list does
not invalidate an older run. Correct its context or report the writer defect.
Do not replace historical figures with measurements from a different setup.

Read scripts and recompute local counts where useful. Do not run networked
benchmarks, install harnesses, or change `src/`. The local instruction gate
(`sh bench/instructions.sh --check`) is optional: exit 2 means it could not
measure, and a comparison is valid only on the baseline's machine and toolchain.

Prioritize unsupported or incomparable figures, stale current-tree counts,
result schemas, task checks, harness mappings, then methodology and wording.

## Checklist

1. **Counts and figures the tree no longer supports.** The size table, and the
   tool-schema byte size and tool count in the harness-prompt-overhead table,
   are measured, and each can be measured again: `ls -l` on a fresh
   `zig build -Doptimize=ReleaseSmall`, and the length of `tools_json` in
   `src/main.zig`, the built-in array the request body's `tools` starts from. That
   constant holds one entry per built-in tool; `extraToolsJson` appends the `skill`
   tool and one `mcp__<server>__<tool>` per tool a server reported, so a body
   measured on a run carrying either is longer than the constant and the figure to
   check is the constant's. A repo-wide count of the `"type":"function"` literal
   also matches a test fixture, so a count taken that way overcounts and reports a
   tool that is never offered. A figure that disagrees with the run is a finding, and so
   is a current-tree claim no run can reproduce. Preserve dated snapshots and
   label their version rather than treating every historical count as current.

2. **Harnesses the document reports that no script runs.** Each row of the
   startup table names one agent. Distinguish the recorded run configuration
   from current script defaults before comparing inventories. The ground truth is the default list
   `bench/overhead.sh` assigns to `agents`, and `bench/run.sh` and
   `bench/gauntlet.sh` each default to their own. A row whose agent neither
   documented command can invoke is a finding for a current-run claim. Historical
   runs may use explicit agent lists; do not infer their participants from today's defaults.

3. **A comparison between rows measured differently.** Wall clock comes from
   `monotonic_ns` in `bench/monotonic.sh`, and that call either answers or
   fails: `date` no longer times anything in these scripts (`date -u` only
   names runs and jobs), so a platform with no monotonic source writes
   `"wall_s":null` beside a `result` of `no-clock` rather than a coarser figure. Such a row has no duration even when the agent
   ran (the second clock read can fail after it), so quoting it, or averaging it
   into a timed row, is this item's finding. The tokens column is
   `-` for every harness
   that does not print `"total_tokens"`, which `run.sh` and `overhead.sh` both
   read with a `grep` on that literal: a row quoting tokens for a harness
   measured by another path, or a size quoted for a build the table does not
   name, compares two setups and is a finding. A range is not a defect; a
   single figure standing in for a spread is.

4. **A field the committed results files carry that no writer produces.**
   `bench/results.jsonl` and `bench/gauntlet-results.jsonl` are appended to by
   the scripts and committed, so they are data the next reader parses. Every
   current-schema claim must match the writer; older rows may predate it. Check
   provenance before calling a historical field invalid. For example, `run.sh` emits `run`, `agent`, `task`, `wall_s`, `tokens`, `lines` and
   `result`, and `gauntlet.sh` emits `run`, `agent`, `passed`, `failed`,
   `changed_files`, `wall_s`, `tokens`, `verify` and `rc`. A field the writer
   stopped emitting needs context when documenting current output. A row with
   no identifiable writer or run provenance needs investigation, not deletion.

5. **Scripts the document's methodology does not account for.** The header
   states which scripts produced the numbers below it. A third committed driver
   writing its own committed results file, and documented only in its own header
   comment, is a finding: a reader told every number came from the named
   scripts is entitled to know which did not.

6. **One measured fact spelled in two documents.** The binary's size lives in
   the `docs/benchmark.md` size table, and `integrations/harbor/README.md` links
   to it rather than quoting it; the tool count is in `docs/benchmark.md` and in the
   `README.md` opening. Two spellings of one measured fact are a defect when
   they disagree, and the fix is the pairing a comment names, never a third
   copy. The tool *names* the help and `docs/usage.md` promise against the `tools` array
   belong to `reviews/cli-contract-review.md`; the count and the byte size are this item's,
   and a figure the tree no longer produces is item 1's finding, not that
   review's.

7. **A benchmark task whose check no longer tests its own prompt.** Each
   directory under `bench/tasks/` is a `setup.sh`, a `prompt.txt` and a
   `check.sh`. Read all three together: a check that passes against the tree
   `setup.sh` builds without the prompt's change being needed, a prompt asking
   for a change the check never looks for, or a check that reads a string the
   setup no longer writes, all report a pass no agent earned, and a `pass` in
   `results.jsonl` produced that way is a wrong number in a committed file.

8. **Command lines the harness mapping has got wrong.** `harness_argv` in
   `bench/portable.sh` maps an agent name to the words that precede the prompt,
   and the default branch spells the rest as `NAME -p`, which a CLI with a
   subcommand refuses. A name the mapping sends to a command line that CLI does
   not accept measures a run that never happened, and so does an agent the
   document spells differently from the name the scripts match on, since the
   match is the bare name.

9. **Methodology and provenance.** For instructions claiming to reproduce current
   scripts, check invocations, run counts, toolchain and clock methods against
   those scripts. Preserve dated methodology for historical measurements; a
   later script change does not invalidate the earlier run. Make the distinction
   explicit when both appear in the same section.

10. **An instruction count `docs/performance.md` publishes that the committed
    baseline does not back.** `docs/performance.md` claims its per-frame, compaction,
    body and ranged-read rows are the rows `bench/instructions.baseline` gates. Read
    the table against that file: the baseline carries a `path` and a tab-separated
    figure for each row (its header labels that column `instructions_per_unit`;
    the figure itself is the net instruction count per unit the script measures,
    and `bench/instructions.sh` compares a fresh measurement against column 2
    inside a `TOLERANCE` band, default 10). A figure the baseline does not
    carry, or one that sits outside the band around the figure it does, is a finding
    even when the document is the newer of the two. Read which is which before
    editing: the baseline's header names the machine and toolchain it was recorded
    on, and re-recording it on that machine is the fix, not a document number
    edited to agree with whatever the baseline happens to say today.
