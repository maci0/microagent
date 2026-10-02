#!/bin/sh
# Harness benchmark: run the same tasks through different agent CLIs and report
# elapsed time, token cost and whether the task's own check passes. Elapsed time
# is monotonic (bench/monotonic.sh), so an NTP step cannot make a run's cost
# negative.
#
#   bench/run.sh [agent ...]        default: microagent
#   bench/run.sh microagent kimi
#
# Results are appended to bench/results.jsonl (one JSON object per run, each
# carrying the `run` that wrote it, so a re-measurement is not a duplicate row)
# and a table is printed. A fresh work directory per (task, agent) keeps runs
# from reading each other's tree.
set -u

# Everything below is one run's account of a tree: the work directory is a
# checkout of the task, and .out/.err hold the harness's whole stdout and
# stderr, so whatever those files hold of the tree is in them. The default mode
# is 0o666 less the umask, so on the 0o022 a host carries, a run's transcript
# under .scratch/ lands readable by every other account on a shared machine.
# Git records 644 for a non-executable file whatever the umask, so the rows
# appended to the committed results file are unaffected.
umask 077

root=$(cd "$(dirname "$0")/.." && pwd)
. "$root/bench/monotonic.sh"
# shellcheck source=bench/portable.sh
. "$root/bench/portable.sh"
# shellcheck source=bench/rows.sh
. "$root/bench/rows.sh"
tasks_dir="$root/bench/tasks"
# The tree's own gitignored .scratch/, for the reason the Makefile builds
# `check-reproducible` there rather than under ${TMPDIR:-/tmp}: /tmp is a
# tmpfs on most Linux hosts, and a run writes a whole task tree per
# (task, agent), with the harness's build products beside it, so the
# measurement's disk is the host's RAM. It is inside the tree rather than
# beside it so `rm -rf` in a harness leaves nothing to sweep up by hand, and
# it is still the tree's, not a path two accounts on a shared machine share.
# BENCH_WORK overrides it for a contributor who names a scratch disk.
work_root="${BENCH_WORK:-$root/.scratch/bench}"
mkdir -p "$work_root" || exit 2
work_root=$(mktemp -d "$work_root/run-XXXXXX") || exit 2
printf '%s: work saved in %s\n' "$0" "$work_root" >&2
results="$root/bench/results.jsonl"
timeout_s="${BENCH_TIMEOUT:-600}"
# Every row of this invocation carries the same `run`, because the file is
# appended to and a re-run of the same script writes rows beside the ones it
# wrote before: a second row for one (agent, task) is a re-measurement nobody
# can tell from a row this run wrote twice. The reader groups by `run` and
# takes the rows of one invocation; a row with no `run` is from before this
# field existed and reads as a run of its own.
#
# Naming the run is half of that; `record_run_row` is the other half, and it
# keeps one run to one row per (agent, task), so the group a reader takes is a
# set of measurements rather than a count of how many times each was taken.
run_id="${BENCH_RUN_ID:-$(date +%Y%m%dT%H%M%S)-$$}"

# Keep row strings escaped and numeric columns typed, including error rows, and
# write the row once per (run, agent, task): `bench/rows.sh` says why a repeat
# is skipped rather than appended.
record_row() {
	row=$(python3 "$(dirname "$0")/row.py" "$run_id" "$@") || return 1
	record_run_row "$results" "$row" agent task
}

agents=${*:-microagent}

# argvFor AGENT -> prints the command line to run, with the prompt left to the
# shell that runs it: the inner shell reads PROMPT from the environment, so the
# expansion is escaped here and quoted there.
argv_for() {
	words=$(harness_argv "$1") || return 1
	printf '%s "%s"' "$words" "\$PROMPT"
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
			record_row "$agent" "$task" null null "n/a" "setup-error" || exit 2
			continue
		fi
		if ! ( cd "$work" && git init -q && git add -A && git -c user.email=b@b -c user.name=b commit -qm base ) >/dev/null 2>&1; then
			printf '%-10s %-14s %8s %10s %8s  %s\n' "$agent" "$task" - - - commit-error
			record_row "$agent" "$task" null null "n/a" "commit-error" || exit 2
			continue
		fi

		prompt=$(cat "$task_dir/prompt.txt")
		# Exported rather than prefixed to the call: a `VAR=x func` prefix
		# persists after the function in a POSIX shell.
		PROMPT=$prompt
		export PROMPT
		# The command line is spelled once, here, and checked, because a
		# substitution inside the call to run_limited would leave an empty
		# command line when it failed and `sh -c ''` exits 0: a harness whose
		# invocation could not be spelled would be recorded as a run that
		# passed, with no output and no tokens, and the check would read an
		# empty tree.
		if ! cmd=$(argv_for "$agent"); then
			printf '%-10s %-14s %8s %10s %8s  %s\n' "$agent" "$task" - - - argv-error
			record_row "$agent" "$task" null null "n/a" "argv-error" || exit 2
			continue
		fi
		# No clock, no number. A duration measured off a wall clock is
		# recorded in results.jsonl beside durations that were not, and nothing
		# downstream can tell them apart.
		if ! start=$(monotonic_ns); then
			printf '%-10s %-14s %8s %10s %8s  %s\n' "$agent" "$task" - - - no-clock
			record_row "$agent" "$task" null null "n/a" "no-clock" || exit 2
			continue
		fi
		run_limited "$timeout_s" "$work" sh -c "$cmd" >"$work/.out" 2>"$work/.err"
		rc=$?
		# The clock is read at both ends and both readings have to answer. A
		# source that reads for the first one can still fail for the second, and
		# an empty `end` is not an error awk reports: it reads as a missing field
		# worth 0, so the subtraction below divided one raw nanosecond count by a
		# billion and appended a wall_s nobody measured.
		if ! end=$(monotonic_ns); then
			printf '%-10s %-14s %8s %10s %8s  %s\n' "$agent" "$task" - - - no-clock
			record_row "$agent" "$task" null null "n/a" "no-clock" || exit 2
			continue
		fi
		wall=$(echo "$end $start" | awk '{printf "%.1f", ($1-$2)/1000000000}')

		# `git add -A` first, because a bare `git diff` compares the worktree
		# with the index and an untracked file is in neither, so a task whose
		# answer is a new file reported +0/-0: the row charged a harness for
		# writing nothing. Staging puts every file the run left behind into the
		# index, and the diff against the base commit is then the whole change.
		# .gitignore is honoured, so build products the run left are not counted.
		#
		# A binary file gets a `-` in each of the first two numstat columns,
		# because it has no lines to count. Summing those as numbers is awk
		# reading an unparseable field as zero, so a task whose answer is a new
		# image or archive reported +0/-0: the same false zero the untracked
		# file above caused, reached through a file git did see. They are
		# counted as files instead, which is the number git can still answer.
		if numstat=$(cd "$work" && git add -A && git diff --cached --numstat); then
			lines=$(printf '%s\n' "$numstat" | awk '$1 == "-" { b += 1; next } { a += $1; d += $2 }
			    END { printf "+%d/-%d", a, d; if (b > 0) printf " (%d binary)", b }')
		else
			lines=n/a
		fi
		# microagent prints cumulative usage per response; the last line is the run total.
		tokens=$(grep -o '"total_tokens":[0-9]*' "$work/.out" 2>/dev/null | tail -1 | cut -d: -f2)
		[ -z "$tokens" ] && tokens=-
		# The JSONL column is a number or null, and `-` is this script's spelling
		# of a harness that reported none. Deciding it here rather than inside a
		# command substitution on the printf line is what makes a substitution
		# that failed say so, instead of reading as a harness that reported no
		# tokens.
		if [ "$tokens" = - ]; then tokens_json=null; else tokens_json=$tokens; fi

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
		record_row "$agent" "$task" "$wall" "$tokens_json" "$lines" "$result" || exit 2
	done
done
