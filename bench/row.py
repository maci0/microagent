"""One benchmark row, as the JSONL file bench/results.jsonl is written in.

    bench/row.py RUN_ID AGENT TASK WALL_S TOKENS LINES RESULT

A tracked Python file rather than a `python3 -c` inside `bench/run.sh`, so ruff
reads it and an editor does too. The caller appends the printed row to the file;
this writes nothing itself, so a write that failed is a failed pipeline rather
than a row the reader believes.

A field the run did not measure is JSON null rather than a 0 a reader would
charge a harness for. The `lines` column is text rather than a number, because
git's numstat answer is `+12/-3 (1 binary)`.
"""

from __future__ import annotations

import json
import sys


def counted(value: str) -> int | None:
    """The count a shell field holds, or None when it holds no count.

    The caller normalizes a harness's own `-` to `null` before this is reached,
    so the only spelling of an absent count here is `null`. Writing 0 for it
    would be a harness charged for no tokens rather than a harness that
    reported none.
    """
    return None if value == "null" else int(value)


def seconds(value: str) -> float | None:
    """A duration the run measured, as a float, or None when it measured none."""
    return None if value == "null" else float(value)


def main() -> None:
    if len(sys.argv) != 8:
        sys.exit("usage: row.py <run-id> <agent> <task> <wall-s> <tokens> <lines> <result>")
    run_id, agent, task, wall, tokens, lines, result = sys.argv[1:]
    row = {
        "run": run_id,
        "agent": agent,
        "task": task,
        "wall_s": seconds(wall),
        "tokens": counted(tokens),
        "lines": lines,
        "result": result,
    }
    # because: a NaN or an infinity is a number JSON cannot spell, and a row the
    # reader's parser refuses costs the whole file rather than the one row
    print(json.dumps(row, allow_nan=False))


if __name__ == "__main__":
    main()
