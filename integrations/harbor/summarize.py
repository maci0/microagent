#!/usr/bin/env python3
"""Summarize a harbor jobs directory: per-task reward, wall time, tokens.

    summarize.py /tmp/harbor-jobs/2026-09-28__22-26-23

Reads only files harbor already wrote; no network, no Docker.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path


def seconds_between(started: str | None, finished: str | None) -> str:
    if not started or not finished:
        return "-"
    from datetime import datetime
    try:
        a = datetime.fromisoformat(started.replace("Z", "+00:00"))
        b = datetime.fromisoformat(finished.replace("Z", "+00:00"))
    except ValueError:
        return "-"
    return f"{(b - a).total_seconds():.0f}s"


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    job = Path(sys.argv[1])
    result = json.loads((job / "result.json").read_text())
    stats = result.get("stats", {})
    print(f"{job.name}: {stats.get('n_completed_trials', 0)} trials, "
          f"{stats.get('n_errored_trials', 0)} errored")
    print(f"in={stats.get('n_input_tokens')} out={stats.get('n_output_tokens')} tokens")

    rows = []
    for trial in sorted(job.iterdir()):
        trial_result = trial / "result.json"
        if not trial_result.is_file():
            continue
        data = json.loads(trial_result.read_text())
        reward = (data.get("verifier_result") or {}).get("rewards", {}).get("reward")
        agent = data.get("agent_result") or {}
        started, finished = data.get("started_at"), data.get("finished_at")
        rows.append((data.get("task_name") or trial.name, reward, agent, started, finished))
    if not rows:
        return 0
    for name, reward, agent, started, finished in rows:
        tokens = f"{agent.get('n_input_tokens', 0)}/{agent.get('n_output_tokens', 0)}"
        wall = seconds_between(started, finished)
        print(f"  {str(reward):>5}  in/out {tokens:>14}  {wall:>7}  {name}")
    scored = [r for _, r, *_ in rows if r is not None]
    if scored:
        print(f"mean reward over {len(scored)} scored: {sum(scored) / len(scored):.3f}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
