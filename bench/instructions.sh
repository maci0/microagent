#!/bin/sh
# Retired instructions per unit of work, for the paths a run actually walks.
#
#   sh bench/instructions.sh            print the table
#   sh bench/instructions.sh --check    the same, and fail on a regression
#
# Why instructions and not time. Wall clock moves with frequency scaling, the
# CPU quota and whatever else the machine is doing, so a wall-clock gate fails
# on a busy runner for reasons that have nothing to do with the code. Retired
# instructions for a fixed binary and a fixed input are a property of the code:
# these rows repeat to within 0.001%. That makes an algorithmic regression
# measurable and a noisy machine irrelevant. `bench/overhead.sh` answers the
# product question, which is how long a run takes; this one answers the code
# question, which is how much work the run is.
#
# Each row is a test whose body is that path and little else. The baseline row
# is the same binary with no test selected, and every other row is reported net
# of it, so what is left is the path rather than process start.
set -u

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root" || exit 2

zig=${ZIG:-zig}
runs=${RUNS:-3}
# 10%: wide enough that a change in codegen does not fail the gate, tight
# enough that doubling a path's work does.
tolerance=${TOLERANCE:-10}

command -v perf >/dev/null 2>&1 || {
	printf '%s\n' "bench/instructions.sh: perf is not installed; nothing to measure" >&2
	exit 2
}

# Row name, test filter, units the row's work is done in. Per-unit numbers stay
# comparable when a test grows.
# The baseline is measured once, before this loop, so it is not a row.
cat >/tmp/.instructions-rows.$$ <<'ROWS'
stream content frame|main.test.a long stream costs|20000
stream tool-arg frame|main.test.streamed argument fragments|2000
compaction of a 1 MB conversation|main.test.compaction elides|1
build the request body 40 times|main.test.one request body|40
ROWS
rows=/tmp/.instructions-rows.$$
trap 'rm -f "$rows"' EXIT

export ZIG_GLOBAL_CACHE_DIR="${ZIG_GLOBAL_CACHE_DIR:-$root/.zig-cache/global}"
opts=$(find "$root/.zig-cache/c" -maxdepth 2 -name options.zig -type f 2>/dev/null | head -n 1)
[ -f "$opts" ] || {
	printf '%s\n' "bench/instructions.sh: run 'zig build test' once first" >&2
	exit 2
}
# `zig env` knows where its own lib is; guessing from the binary path breaks
# the moment zig is installed somewhere else.
zigenv=$("$zig" env)
lib=$(printf '%s' "$zigenv" | sed -n 's/.*\.lib_dir = "\([^"]*\)".*/\1/p' | head -n 1)
[ -n "$lib" ] && [ -d "$lib" ] || lib=$(dirname "$(printf '%s' "$zigenv" | sed -n 's/.*\.std_dir = "\([^"]*\)".*/\1/p' | head -n 1)")

work=$(mktemp -d) || exit 2
trap 'rm -f "$rows"; rm -rf "$work"' EXIT
bin="$work/instructions-test"

# Median of $runs samples of one binary. The median, not the mean, because the
# first run pays for the page faults on a binary that was just written and the
# rest do not.
measure() {
	filter=$1
	# One build, then the same binary sampled $runs times. Rebuilding per
	# sample does not work: zig sees the inputs are unchanged, skips emitting,
	# and leaves no binary to run.
	rm -f "$bin"
	"$zig" test -fno-strip -OReleaseFast \
		--dep build_options -Mroot=src/main.zig -Mbuild_options="$opts" \
		--cache-dir "$root/.zig-cache" --global-cache-dir "$ZIG_GLOBAL_CACHE_DIR" \
		--name test --test-filter "$filter" \
		--zig-lib-dir "$lib" -femit-bin="$bin" >/dev/null 2>&1
	[ -x "$bin" ] || return 0
	i=0
	while [ "$i" -lt "$runs" ]; do
		perf stat -e instructions "$bin" 2>&1 |
			grep -oE '[0-9,]+[[:space:]]+instructions' |
			grep -oE '^[0-9,]+' | tr -d ','
		i=$((i + 1))
	done | sort -n | awk '{ v[NR] = $1 } END { print v[int((NR + 1) / 2)] }'
}

baseline=$(measure zzzz_no_such_test)
printf '%-32s %14s %14s\n' path instructions instr_per_unit
printf '%s\n' "--------------------------------------------------------------------------"
printf '%-32s %14s %14s\n' baseline "$baseline" -

worst=0
while IFS='|' read -r name filter units; do
	[ -n "$name" ] || continue
	value=$(measure "$filter")
	if [ -z "$value" ]; then
		printf '%-32s %14s\n' "$name" "not built"
		continue
	fi
	per=$(((value - baseline) / units))
	printf '%-32s %14s %14s\n' "$name" "$value" "$per"

	if [ "${1:-}" = --check ]; then
		want=$(awk -F'\t' -v n="$name" '$1 == n { print $2 }' "$root/bench/instructions.baseline" 2>/dev/null)
		if [ -n "$want" ] && [ "$want" -gt 0 ]; then
			# Compare in tenths so the ratio is an integer and shell
			# arithmetic does not have to do division on a float.
			now=$((per * 1000 / want))
			if [ "$now" -gt "$((1000 + tolerance * 10))" ] || [ "$now" -lt "$((1000 - tolerance * 10))" ]; then
				printf '  REGRESSION: %s is %s per unit, baseline %s (band +/-%s%%)\n' \
					"$name" "$per" "$want" "$tolerance"
				worst=1
			fi
		fi
	fi
done <"$rows"

if [ "$worst" -ne 0 ]; then
	printf '%s\n' "bench/instructions.sh: a hot path moved outside the band; fix it or re-record bench/instructions.baseline"
	exit 1
fi
exit 0
