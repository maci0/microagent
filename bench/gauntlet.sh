#!/bin/sh
# Usefulness benchmark: run the SAME gauntlet reviews on the SAME repository
# copy with each named agent, and compare what actually landed.
#
#   bench/gauntlet.sh [agent ...]        default: microagent
#
# Measures outcome, not plumbing: reviews passed, files changed, tokens gauntlet
# read from the agent, elapsed time, and whether the patched tree still passes the
# project's own check. Each agent gets a pristine clone, and the working tree is
# diffed afterwards: gauntlet reports "Passed" for a review that landed no diff
# at all, so passes alone would flatter every agent. Set GAUNTLET_VERIFY to the
# project's check (e.g. "zig build test") to record that too.
# The external equivalents (SWE-bench Verified, Terminal-Bench 2) are not driven
# from here; they go through the harbor adapter, see integrations/harbor/README.md
# and docs/benchmark.md.
set -u

root=$(cd "$(dirname "$0")/.." && pwd)
. "$root/bench/monotonic.sh"
source_repo="${GAUNTLET_REPO:-$root}"
reviews="${GAUNTLET_REVIEWS:-quick}"
max_reviews="${GAUNTLET_MAX_REVIEWS:-3}"
timeout_per_review="${GAUNTLET_TIMEOUT:-8m}"
verify_cmd="${GAUNTLET_VERIFY:-}"
# TMPDIR first, as bench/run.sh does: macOS points it at a per-user scratch
# directory, and /tmp is a world-writable sticky shared by every account on the
# machine, so two gauntlet runs on one host collide there.
work_root="${GAUNTLET_WORK:-${TMPDIR:-/tmp}/microagent-gauntlet}"
# Every row of this invocation carries the same `run`, because the file is
# appended to and a second run of this script writes its rows beside the ones
# already there: a reader cannot otherwise tell a re-measurement of an agent
# from a row this run wrote twice. A row with no `run` predates the field.
run_id="${GAUNTLET_RUN_ID:-$(date +%Y%m%dT%H%M%S)-$$}"
agents=${*:-microagent}

# The tool that runs the review is named here rather than left to the shell: a
# `gauntlet` that is not on PATH exits 127 into the log, every count below stays
# at its default of zero, and the row lands in gauntlet-results.jsonl as a
# review that ran and found nothing. That is worse than an error, because it is
# indistinguishable from a real zero. Exit 2 is the same code bench/instructions.sh
# uses for a measurement it could not take.
if ! command -v gauntlet >/dev/null 2>&1; then
	printf '%s: gauntlet is not on PATH, so no review below can run and no row is written\n' "$0" >&2
	exit 2
fi

printf '%-40s %6s %6s %7s %8s %8s %8s  %s\n' agent passed failed files wall_s tokens verify rc
printf '%s\n' "-------------------------------------------------------------------------------------------------------"

for agent in $agents; do
	# The harness is the spec's first field: everything after the first colon is
	# the model and provider gauntlet appends. A harness that is not on PATH
	# makes every review below it fail with no diff and no log to read, and
	# records that as a run, so it is named and skipped before the clone.
	harness=${agent%%:*}
	if ! command -v "$harness" >/dev/null 2>&1; then
		printf '%s: %s is not on PATH, skipping it (make install puts microagent in ~/.local/bin)\n' \
			"$0" "$harness" >&2
		continue
	fi

	# Agent specs can carry a model ("microagent:stealth/space-bunny-alpha"),
	# which is not a legal directory name.
	dir="$work_root/$(printf '%s' "$agent" | tr '/:@' '___')"
	rm -rf "$dir"
	git clone -q --no-hardlinks "$source_repo" "$dir" || exit 1
	# Checked, not run and ignored. A commit the clone did not fetch leaves the
	# clone on the default branch, and the review below then runs against that
	# tree and records its numbers as if they described this one: the shape of
	# failure this script refuses everywhere else, reached through the one
	# command here that had no answer.
	head_sha=$(git -C "$source_repo" rev-parse HEAD) || exit 2
	( cd "$dir" && git checkout -q "$head_sha" ) || {
		printf '%s: the clone has no %s, so the review would run against a different tree and every number below would be wrong\n' \
			"$0" "$head_sha" >&2
		exit 2
	}

	# No clock, no wall time. A review measured off a wall clock would be
	# recorded beside reviews that were not, and the row would look like a
	# review that finished instantly.
	if ! start=$(monotonic_ns); then
		printf '%-40s %6s %6s %7s %8s %8s %8s  %s\n' "$agent" - - - no-clock - - -
		printf '{"run":"%s","agent":"%s","passed":null,"failed":null,"changed_files":null,"wall_s":null,"tokens":null,"verify":null,"rc":null}\n' \
			"$run_id" "$agent" >>"$root/bench/gauntlet-results.jsonl"
		continue
	fi

	( cd "$dir" && gauntlet -a "$agent" -r "$reviews" --max-reviews "$max_reviews" --once \
		-C "$dir" -t "$timeout_per_review" -y --no-color ) >"$dir/.gauntlet.log" 2>&1
	rc=$?
	# Both ends of the clock are checked, not just the first. A second reading
	# that fails leaves `end` empty, and the shell arithmetic below reads an
	# empty variable as 0, so the row was written with a wall time derived from
	# the start reading alone rather than one that was refused.
	if ! end=$(monotonic_ns); then
		printf '%-40s %6s %6s %7s %8s %8s %8s  %s\n' "$agent" - - - no-clock - - -
		printf '{"run":"%s","agent":"%s","passed":null,"failed":null,"changed_files":null,"wall_s":null,"tokens":null,"verify":null,"rc":null}\n' \
			"$run_id" "$agent" >>"$root/bench/gauntlet-results.jsonl"
		continue
	fi
	# Subtracted in awk rather than in `$(( ))`, which is what bench/run.sh and
	# bench/overhead.sh do for the same measurement. Shell arithmetic is only
	# required to be as wide as `long`, so a 32-bit shell wraps a nanosecond
	# reading of a long-uptime host and records a nonsense elapsed time; awk's
	# double carries the value and the two scripts cannot disagree about how a
	# duration is turned into seconds.
	elapsed=$(echo "$end $start" | awk '{printf "%.0f", ($1-$2+500000000)/1000000000}')

	passed=$(awk '/^  Passed:/{print $2}' "$dir/.gauntlet.log" | tail -1)
	failed=$(awk '/^  Failed:/{print $2}' "$dir/.gauntlet.log" | tail -1)
	tokens=$(awk '/^Tokens:/{print $2}' "$dir/.gauntlet.log" | tail -1 | tr -d ,)
	# The two logs above are this script's, not the review's, and are excluded
	# from the count for that reason. Everything else is staged first, because
	# `git diff HEAD` leaves an untracked file out of the diff entirely: a
	# review whose whole fix is a new file reported zero files changed, and
	# this column is the one that says a review landed something at all.
	changed=$(git -C "$dir" add -A -- . ':!.gauntlet.log' ':!.verify.log' &&
		git -C "$dir" diff --cached --numstat | wc -l)
	[ -z "${passed:-}" ] && passed=0
	[ -z "${failed:-}" ] && failed=0
	[ -z "${changed:-}" ] && changed=0
	[ -z "${tokens:-}" ] && tokens=-
	# The JSONL column is a number or null, and `-` is this script's spelling
	# of a harness that reported none. Deciding it here rather than inside a
	# command substitution on the printf line is what makes a substitution that
	# failed say so, instead of reading as a harness that reported no tokens.
	if [ "$tokens" = - ]; then tokens_json=null; else tokens_json=$tokens; fi

	# A diff is not the same as a working diff: run the project's own check.
	verify=-
	if [ -n "$verify_cmd" ]; then
		if ( cd "$dir" && sh -c "$verify_cmd" ) >"$dir/.verify.log" 2>&1; then verify=ok; else verify=FAILED; fi
	fi

	printf '%-40s %6s %6s %7s %8s %8s %8s  %s\n' "$agent" "$passed" "$failed" "$changed" "$elapsed" "$tokens" "$verify" "$rc"
	printf '{"run":"%s","agent":"%s","passed":%s,"failed":%s,"changed_files":%s,"wall_s":%s,"tokens":%s,"verify":"%s","rc":%s}\n' \
		"$run_id" "$agent" "$passed" "$failed" "$changed" "$elapsed" "$tokens_json" "$verify" "$rc" \
		>>"$root/bench/gauntlet-results.jsonl"
done
