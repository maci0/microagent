#!/usr/bin/env python3
"""Summarize a harbor jobs directory: per-task reward, wall time, tokens.

    summarize.py /tmp/harbor-jobs/2026-09-28__22-26-23

Reads only files harbor already wrote; no network, no Docker.
"""

from __future__ import annotations

import json
import sys
from datetime import UTC, datetime
from pathlib import Path


def instant(value: str) -> datetime:
    """Parse a harbor timestamp into an aware UTC datetime.

    harbor writes UTC, so a timestamp with no offset is read as UTC and not as
    the reader's local time: the same file has to mean the same thing on every
    machine that summarizes it. Both fields then subtract cleanly, where one
    aware and one naive value would raise TypeError.
    """
    text = value.strip()
    if text.endswith(("Z", "z")):
        text = text[:-1] + "+00:00"
    stamp = datetime.fromisoformat(text)
    if stamp.tzinfo is None:
        stamp = stamp.replace(tzinfo=UTC)
    return stamp.astimezone(UTC)


def seconds_between(started: str | None, finished: str | None) -> str:
    if not started or not finished:
        return "-"
    try:
        a = instant(started)
        b = instant(finished)
    except ValueError:
        return "-"
    return f"{(b - a).total_seconds():.0f}s"


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    job = Path(sys.argv[1])
    # UTF-8 named rather than left to the locale: harbor writes the same files
    # on every host, and one that summarizes them under LANG=C or a legacy code
    # page has to read the same bytes the machine that ran them did.
    result = json.loads((job / "result.json").read_text(encoding="utf-8"))
    stats = result.get("stats", {})
    print(f"{job.name}: {stats.get('n_completed_trials', 0)} trials, {stats.get('n_errored_trials', 0)} errored")
    print(f"in={stats.get('n_input_tokens')} out={stats.get('n_output_tokens')} tokens")

    scored = []
    for trial in sorted(job.iterdir()):
        trial_result = trial / "result.json"
        if not trial_result.is_file():
            continue
        data = json.loads(trial_result.read_text(encoding="utf-8"))
        verifier = data.get("verifier_result") or {}
        reward = (verifier.get("rewards") or {}).get("reward")
        agent = data.get("agent_result") or {}
        tokens = f"{agent.get('n_input_tokens', 0)}/{agent.get('n_output_tokens', 0)}"
        wall = seconds_between(data.get("started_at"), data.get("finished_at"))
        print(f"  {reward!s:>5}  in/out {tokens:>14}  {wall:>7}  {data.get('task_name') or trial.name}")
        if reward is not None:
            scored.append(reward)
    if scored:
        print(f"mean reward over {len(scored)} scored: {sum(scored) / len(scored):.3f}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
