Summary: documented boundaries, controls, references and gaps

# Threat-model accuracy

Your goal is to check `docs/threat-model.md` against the code implementing each entry point,
boundary, mitigation and remaining gap.

Read and follow the [shared review protocol](README.md#review-protocol) in
`reviews/README.md` before starting. This file is a
reusable checklist, not a review report.

## Scope and priorities

Edit the threat model only. Report missing controls rather than adding them
in `src/`. Do not soften a weakness or close a gap without tracing the full
path. Keep rankings consistent when controls or entry points change. Update
review metadata only for the scope actually verified.

Prioritize nonexistent controls and wrong references, missing entry points,
closed gaps still listed as open, inconsistent rankings, then review metadata.

## Checklist

1. **References that no longer resolve.** Every `` `src/file.zig:NNN` `` in the document
   must name a line that still exists and still holds the thing the row claims. The
   symbol paired before the line (`` `symbol`, `src/file.zig:NNN` ``) is the anchor:
   search for that name (`parseArgs`, `caBundlePath`, `envValue`, `runTool`,
   `parseRelease`) and correct the line, because a line number moves on every edit and a
   function name does not. `make check-refs` verifies each pair against the symbol's
   definition; a bare line is outside it. Repair a row that names only a line by finding
   the enclosing `fn` and writing `` `fn`, `src/file.zig:<definition>`, at `src/file.zig:NNN` ``,
   so the next pass has an anchor that a line move cannot invalidate.

2. **Controls claimed where the code has none.** The "Mitigations in the code" table is
   the load-bearing part of the document. For each row, read the named function and
   confirm the check is really there: a host allowlist that accepts every host, a
   checksum that is compared after the write, a `--` separator that the code does not
   pass. A row whose control is gone moves to "Gaps"; a control that moved out of the
   named function is a new row.

3. **Entry points the document misses.** Walk the whole surface, not the one the last pass
   saw: every `envValue` or `environ_map.get` read, every file opened for write, every
   process spawned, every place a URL is built from user input, every byte printed to a
   terminal. Search `spawn`, `createFile`, `envValue(`, `environ_map`, `base_url`, and
   `print`, then compare the list with the "Entry points in the code" table. An entry
   point with no row is a new threat, not a new sentence.

4. **Gaps that have been closed.** "Gaps, ranked by exploitability and impact" and the
   abuse cases are claims about what the binary does not stop. For each, read the code
   path the abuse case names and confirm the gap is still open. One now closed moves to
   the mitigations table with its evidence, and the ranking below it closes up.

5. **Rankings that no longer follow from the table.** Exploitability and impact are
   ordered claims. A new entry point, a widened default or a control that disappeared
   changes the order, so check that the top of the summary is still what the table
   supports, and that the "risk-ranked" table and the ranked gap list agree with each
   other.

6. **Trust boundaries drawn where the code does not have one.** Each "Trust boundaries"
   and "Assets" entry must name the code that creates it: a value crossing from the
   model into a subprocess, a key crossing into a header, a byte crossing into a
   terminal. A boundary asserted in prose with no code behind it is a finding.

7. **Response readiness claiming something that does not exist.** The closing section
   records what the project does not provide. A `SECURITY.md`, a disclosure contact or a
   documented reporting path that has since been added makes the note stale, and the note
   is the one place that would send a reader looking for help that is not there.

8. **Review metadata.** Verify the stated date, version and review scope against
   the work actually performed. Preserve historical review versions. Update
   metadata only for checks completed; a limited documentation pass must not
   claim a complete security audit.
