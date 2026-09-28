#!/bin/sh
# Usefulness benchmark: run the SAME gauntlet reviews on the SAME repository
# copy with each named agent, and compare what actually landed.
#
#   bench/gauntlet.sh [agent ...]        default: microagent
#
# Measures outcome, not plumbing: reviews passed, lines changed, tokens gauntlet
# read from the agent, wall time. Each agent gets a pristine clone, and the
# working tree is diffed afterwards so a "pass" with an empty diff is visible.
# The external equivalents (SWE-bench Verified/Pro, Terminal-Bench 2) are not
# wired up here; see BENCHMARK.md for why and what it would take.
set -u

root=$(cd "$(dirname "$0")/.." && pwd)
source_repo="${GAUNTLET_REPO:-$root}"
reviews="${GAUNTLET_REVIEWS:-quick}"
max_reviews="${GAUNTLET_MAX_REVIEWS:-3}"
timeout_per_review="${GAUNTLET_TIMEOUT:-8m}"
work_root="${GAUNTLET_WORK:-/tmp/microagent-gauntlet}"
agents=${*:-microagent}

printf '%-12s %8s %8s %8s %10s %8s  %s\n' agent passed failed changed wall_s tokens result
printf '%s\n' "--------------------------------------------------------------------------------"

for agent in $agents; do
	# Agent specs can carry a model ("microagent:stealth/space-bunny-alpha"),
	# which is not a legal directory name.
	dir="$work_root/$(printf '%s' "$agent" | tr '/:@' '___')"
	rm -rf "$dir"
	git clone -q --no-hardlinks "$source_repo" "$dir" || exit 1
	( cd "$dir" && git checkout -q "$(git -C "$source_repo" rev-parse HEAD)" )

	start=$(date +%s)
	( cd "$dir" && gauntlet -a "$agent" -r "$reviews" --max-reviews "$max_reviews" --once \
		-C "$dir" -t "$timeout_per_review" -y --no-color ) >"$dir/.gauntlet.log" 2>&1
	rc=$?
	end=$(date +%s)

	passed=$(awk '/^  Passed:/{print $2}' "$dir/.gauntlet.log" | tail -1)
	failed=$(awk '/^  Failed:/{print $2}' "$dir/.gauntlet.log" | tail -1)
	tokens=$(awk '/^Tokens:/{print $2}' "$dir/.gauntlet.log" | tail -1 | tr -d ,)
	changed=$(git -C "$dir" diff HEAD --shortstat | awk '{print $1}')
	[ -z "${passed:-}" ] && passed=0
	[ -z "${failed:-}" ] && failed=0
	[ -z "${changed:-}" ] && changed=0
	[ -z "${tokens:-}" ] && tokens=-

	printf '%-40s %6s %6s %7s %8s %8s  %s\n' "$agent" "$passed" "$failed" "$changed" "$((end - start))" "$tokens" "$rc"
	printf '{"agent":"%s","passed":%s,"failed":%s,"changed_files":%s,"wall_s":%s,"tokens":%s,"rc":%s}\n' \
		"$agent" "$passed" "$failed" "$changed" "$((end - start))" "$( [ "$tokens" = - ] && echo null || echo "$tokens" )" "$rc" \
		>>"$root/bench/gauntlet-results.jsonl"
done
