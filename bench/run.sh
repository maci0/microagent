#!/bin/sh
# Harness benchmark: run the same tasks through different agent CLIs and report
# wall time, token cost and whether the task's own check passes.
#
#   bench/run.sh [agent ...]        default: microagent
#   bench/run.sh microagent kimi
#
# Results are appended to bench/results.jsonl (one JSON object per run) and a
# table is printed. A fresh work directory per (task, agent) keeps runs from
# reading each other's tree.
set -u

root=$(cd "$(dirname "$0")/.." && pwd)
tasks_dir="$root/bench/tasks"
work_root="${BENCH_WORK:-/tmp/microagent-bench}"
results="$root/bench/results.jsonl"
timeout_s="${BENCH_TIMEOUT:-600}"

agents=${*:-microagent}

# argvFor AGENT PROMPT -> prints the command line to run
argv_for() {
	case "$1" in
	microagent) printf '%s' "microagent -p \"\$PROMPT\"" ;;
	claude) printf '%s' "claude -p \"\$PROMPT\"" ;;
	kimi) printf '%s' "kimi -p \"\$PROMPT\"" ;;
	codex) printf '%s' "codex exec --skip-git-repo-check \"\$PROMPT\"" ;;
	crush) printf '%s' "crush run \"\$PROMPT\"" ;;
	*) printf '%s' "$1 -p \"\$PROMPT\"" ;;
	esac
}

printf '%-10s %-14s %8s %10s %8s  %s\n' agent task wall_s tokens lines result
printf '%s\n' "--------------------------------------------------------------------------"

for agent in $agents; do
	for task_dir in "$tasks_dir"/*; do
		task=$(basename "$task_dir")
		work="$work_root/$task/$agent"
		rm -rf "$work"
		mkdir -p "$work"
		( cd "$work" && sh "$task_dir/setup.sh" >/dev/null 2>&1 )
		( cd "$work" && git init -q && git add -A && git -c user.email=b@b -c user.name=b commit -qm base ) >/dev/null 2>&1

		prompt=$(cat "$task_dir/prompt.txt")
		start=$(date +%s.%N)
		( cd "$work" && PROMPT="$prompt" timeout "$timeout_s" sh -c "$(argv_for "$agent")" ) >"$work/.out" 2>"$work/.err"
		rc=$?
		end=$(date +%s.%N)
		wall=$(echo "$end $start" | awk '{printf "%.1f", $1-$2}')

		lines=$(cd "$work" && git diff --numstat | awk '{a+=$1; d+=$2} END {printf "+%d/-%d", a, d}')
		[ -z "$lines" ] && lines=+0/-0
		# microagent prints cumulative usage per response; the last line is the run total.
		tokens=$(grep -o '"total_tokens":[0-9]*' "$work/.out" 2>/dev/null | tail -1 | cut -d: -f2)
		[ -z "$tokens" ] && tokens=-

		if ( cd "$work" && sh "$task_dir/check.sh" ) >"$work/.check" 2>&1; then
			result=pass
		else
			result="fail(rc=$rc)"
		fi

		printf '%-10s %-14s %8s %10s %8s  %s\n' "$agent" "$task" "$wall" "$tokens" "$lines" "$result"
		printf '{"agent":"%s","task":"%s","wall_s":%s,"tokens":%s,"lines":"%s","result":"%s"}\n' \
			"$agent" "$task" "$wall" "$( [ "$tokens" = - ] && echo null || echo "$tokens" )" "$lines" "$result" >>"$results"
	done
done
