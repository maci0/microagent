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
# and BENCHMARK.md.
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
agents=${*:-microagent}

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
	( cd "$dir" && git checkout -q "$(git -C "$source_repo" rev-parse HEAD)" )

	start=$(monotonic_ns)
	( cd "$dir" && gauntlet -a "$agent" -r "$reviews" --max-reviews "$max_reviews" --once \
		-C "$dir" -t "$timeout_per_review" -y --no-color ) >"$dir/.gauntlet.log" 2>&1
	rc=$?
	end=$(monotonic_ns)
	elapsed=$(( (end - start + 500000000) / 1000000000 ))

	passed=$(awk '/^  Passed:/{print $2}' "$dir/.gauntlet.log" | tail -1)
	failed=$(awk '/^  Failed:/{print $2}' "$dir/.gauntlet.log" | tail -1)
	tokens=$(awk '/^Tokens:/{print $2}' "$dir/.gauntlet.log" | tail -1 | tr -d ,)
	changed=$(git -C "$dir" diff HEAD --numstat | wc -l)
	[ -z "${passed:-}" ] && passed=0
	[ -z "${failed:-}" ] && failed=0
	[ -z "${tokens:-}" ] && tokens=-

	# A diff is not the same as a working diff: run the project's own check.
	verify=-
	if [ -n "$verify_cmd" ]; then
		if ( cd "$dir" && sh -c "$verify_cmd" ) >"$dir/.verify.log" 2>&1; then verify=ok; else verify=FAILED; fi
	fi

	printf '%-40s %6s %6s %7s %8s %8s %8s  %s\n' "$agent" "$passed" "$failed" "$changed" "$elapsed" "$tokens" "$verify" "$rc"
	printf '{"agent":"%s","passed":%s,"failed":%s,"changed_files":%s,"wall_s":%s,"tokens":%s,"verify":"%s","rc":%s}\n' \
		"$agent" "$passed" "$failed" "$changed" "$elapsed" "$( [ "$tokens" = - ] && echo null || echo "$tokens" )" "$verify" "$rc" \
		>>"$root/bench/gauntlet-results.jsonl"
done
