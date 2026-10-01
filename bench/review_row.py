"""One review-loop row, as the JSONL file bench/gauntlet-results.jsonl is written in.

    bench/review_row.py RUN_ID AGENT PASSED FAILED CHANGED_FILES WALL_S TOKENS VERIFY RC

A tracked Python file rather than a `python3 -c` inside `bench/gauntlet.sh`, so
ruff reads it and an editor does too. The caller appends the printed row to the
file; this writes nothing itself, so a write that failed is a failed pipeline
rather than a row the reader believes.

`null` and `-` are the two spellings of a count the run did not take: `null` is
what the shell passes for a field it never measured, and `-` is the spelling the
`case` statements above a call use for a value that is absent or not a number.
Neither is 0, and reading either as 0 writes a review that found nothing into a
file readers group and compare. `verify` is text (`ok`, `FAILED` or `-`), because
it is a verdict rather than a count.
"""

from __future__ import annotations

import json
import sys


def counted(value: str) -> int | None:
    """The count a shell field holds, or None when it holds no count.

    `-` is a field the run had no number for: the review loop printed no
    `Passed:` line, the log was truncated, or git's numstat failed. Writing 0
    for any of them is a review that passed nothing, which is a result rather
    than an absence of one.
    """
    return None if value in ("null", "-") else int(value)


def main() -> None:
    if len(sys.argv) != 10:
        sys.exit(
            "usage: review_row.py <run-id> <agent> <passed> <failed> <changed-files> <wall-s> <tokens> <verify> <rc>"
        )
    run_id, agent, passed, failed, changed, wall, tokens, verify, rc = sys.argv[1:]
    row = {
        "run": run_id,
        "agent": agent,
        "passed": counted(passed),
        "failed": counted(failed),
        "changed_files": counted(changed),
        "wall_s": counted(wall),
        "tokens": counted(tokens),
        "verify": None if verify == "null" else verify,
        "rc": counted(rc),
    }
    print(json.dumps(row))


if __name__ == "__main__":
    main()
