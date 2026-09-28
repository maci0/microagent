#!/bin/sh
# Harness benchmark: run the same tasks through different agent CLIs and report
# elapsed time, token cost and whether the task's own check passes. Elapsed time
# is monotonic (bench/monotonic.sh), so an NTP step cannot make a run's cost
# negative.
#
#   bench/run.sh [agent ...]        default: microagent
#   bench/run.sh microagent kimi
#
# Results are appended to bench/results.jsonl (one JSON object per run) and a
# table is printed. A fresh work directory per (task, agent) keeps runs from
# reading each other's tree.
set -u

root=$(cd "$(dirname "$0")/.." && pwd)
. "$root/bench/monotonic.sh"
# shellcheck source=bench/portable.sh
. "$root/bench/portable.sh"
# shellcheck source=bench/harness.sh
. "$root/bench/harness.sh"
tasks_dir="$root/bench/tasks"
work_root="${BENCH_WORK:-${TMPDIR:-/tmp}/microagent-bench}"
results="$root/bench/results.jsonl"
timeout_s="${BENCH_TIMEOUT:-600}"

agents=${*:-microagent}

# argvFor AGENT -> prints the command line to run, with the prompt left to the
# shell that runs it: the inner shell reads PROMPT from the environment, so the
# expansion is escaped here and quoted there.
argv_for() {
	printf '%s "%s"' "$(harness_argv "$1")" "\$PROMPT"
}

printf '%-10s %-14s %8s %10s %8s  %s\n' agent task wall_s tokens lines result
printf '%s\n' "--------------------------------------------------------------------------"

for agent in $agents; do
	# A harness that is not on PATH is not measured, it is failed: the task runs
	# against an empty tree and every row reads fail(rc=127), appended to a
	# committed results file. Skipped here, before the work directory is made,
	# so the run says which harness is missing and writes no row for it.
	if ! command -v "$agent" >/dev/null 2>&1; then
		printf '%s: %s is not on PATH, skipping it (make bench builds microagent into zig-out/bin)\n' \
			"$0" "$agent" >&2
		continue
	fi
	for task_dir in "$tasks_dir"/*; do
		task=$(basename "$task_dir")
		work="$work_root/$task/$agent"
		rm -rf "$work"
		mkdir -p "$work"
		# A setup that fails, on the first run or on any later one, leaves a
		# tree the task never defined. Running the agent against it and
		# recording the outcome would charge the agent for a broken task
		# setup, and append that as a real measurement to results.jsonl, so
		# the row is written as an error instead.
		if ! ( cd "$work" && sh "$task_dir/setup.sh" ) >"$work_root/$task.setup.log" 2>&1; then
			printf '%-10s %-14s %8s %10s %8s  %s\n' "$agent" "$task" - - - setup-error
			printf '{"agent":"%s","task":"%s","wall_s":null,"tokens":null,"lines":"n/a","result":"setup-error"}\n' \
				"$agent" "$task" >>"$results"
			continue
		fi
		if ! ( cd "$work" && git init -q && git add -A && git -c user.email=b@b -c user.name=b commit -qm base ) >/dev/null 2>&1; then
			printf '%-10s %-14s %8s %10s %8s  %s\n' "$agent" "$task" - - - commit-error
			printf '{"agent":"%s","task":"%s","wall_s":null,"tokens":null,"lines":"n/a","result":"commit-error"}\n' \
				"$agent" "$task" >>"$results"
			continue
		fi

		prompt=$(cat "$task_dir/prompt.txt")
		# Exported rather than prefixed to the call: a `VAR=x func` prefix
		# persists after the function in a POSIX shell.
		PROMPT=$prompt
		export PROMPT
		# No clock, no number. A duration measured off a wall clock is
		# recorded in results.jsonl beside durations that were not, and nothing
		# downstream can tell them apart.
		if ! start=$(monotonic_ns); then
			printf '%-10s %-14s %8s %10s %8s  %s\n' "$agent" "$task" - - - no-clock
			printf '{"agent":"%s","task":"%s","wall_s":null,"tokens":null,"lines":"n/a","result":"no-clock"}\n' \
				"$agent" "$task" >>"$results"
			continue
		fi
		run_limited "$timeout_s" "$work" sh -c "$(argv_for "$agent")" >"$work/.out" 2>"$work/.err"
		rc=$?
		# The clock is read at both ends and both readings have to answer. A
		# source that reads for the first one can still fail for the second, and
		# an empty `end` is not an error awk reports: it reads as a missing field
		# worth 0, so the subtraction below divided one raw nanosecond count by a
		# billion and appended a wall_s nobody measured.
		if ! end=$(monotonic_ns); then
			printf '%-10s %-14s %8s %10s %8s  %s\n' "$agent" "$task" - - - no-clock
			printf '{"agent":"%s","task":"%s","wall_s":null,"tokens":null,"lines":"n/a","result":"no-clock"}\n' \
				"$agent" "$task" >>"$results"
			continue
		fi
		wall=$(echo "$end $start" | awk '{printf "%.1f", ($1-$2)/1000000000}')

		# `git add -A` first, because a bare `git diff` compares the worktree
		# with the index and an untracked file is in neither, so a task whose
		# answer is a new file reported +0/-0: the row charged a harness for
		# writing nothing. Staging puts every file the run left behind into the
		# index, and the diff against the base commit is then the whole change.
		# .gitignore is honoured, so build products the run left are not counted.
		lines=$(cd "$work" && git add -A && git diff --cached --numstat | awk '{a+=$1; d+=$2} END {printf "+%d/-%d", a, d}')
		[ -z "$lines" ] && lines=+0/-0
		# microagent prints cumulative usage per response; the last line is the run total.
		tokens=$(grep -o '"total_tokens":[0-9]*' "$work/.out" 2>/dev/null | tail -1 | cut -d: -f2)
		[ -z "$tokens" ] && tokens=-

		# The row is about the check, so it reports the check's own exit code.
		# The harness's rc answers a different question, and a row reading
		# "fail(rc=0)" said a harness exited 0 having produced a tree that does
		# not pass, which is the run the reader most needs the shape of.
		( cd "$work" && sh "$task_dir/check.sh" ) >"$work/.check" 2>&1
		check_rc=$?
		if [ "$check_rc" -eq 0 ]; then
			result=pass
		else
			result="fail(check=$check_rc,agent=$rc)"
		fi

		printf '%-10s %-14s %8s %10s %8s  %s\n' "$agent" "$task" "$wall" "$tokens" "$lines" "$result"
		printf '{"agent":"%s","task":"%s","wall_s":%s,"tokens":%s,"lines":"%s","result":"%s"}\n' \
			"$agent" "$task" "$wall" "$( [ "$tokens" = - ] && echo null || echo "$tokens" )" "$lines" "$result" >>"$results"
	done
done
