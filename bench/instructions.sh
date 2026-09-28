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
#
# One worry this had to answer: a test allocates through std.testing.allocator,
# which is a DebugAllocator, and the shipped binary does not. It links no libc,
# so its init.gpa is std.heap.smp_allocator. Measured on the frame path, the
# DebugAllocator charges 1.00x what the product pays (3,899 against 3,885
# instructions a frame), because the frame arena is reset keeping its capacity
# and so allocates nothing once it is warm. The counters here describe the
# binary that ships, not a slower instrument around it.
#
# Linux only, unlike the other bench scripts: the counter it reports is read
# from `perf stat`, and macOS has no equivalent that counts instructions.
set -u

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root" || exit 2

zig=${ZIG:-zig}
runs=${RUNS:-3}
# 10%: wide enough that a change in codegen does not fail the gate, tight
# enough that doubling a path's work does.
tolerance=${TOLERANCE:-10}

command -v perf >/dev/null 2>&1 || {
	# Unlike the other bench scripts, this one is Linux only: retired
	# instructions are read from `perf stat`, and no BSD or macOS equivalent
	# reports a hardware event counter. Say which platform rather than leaving
	# a macOS contributor to install something that will never be there.
	printf '%s\n' "bench/instructions.sh: this measurement needs Linux perf, which macOS does not ship; nothing to measure" >&2
	exit 2
}

# Row name, test filter, units the row's work is done in. Per-unit numbers stay
# comparable when a test grows.
# The baseline is measured once, before this loop, so it is not a row.
work=$(mktemp -d) || exit 2
trap 'rm -rf "$work"' EXIT
bin="$work/instructions-test"

# The rows live in $work rather than a fixed name under /tmp: a predictable path
# in a world-writable directory is another account's file to write through, and
# TMPDIR is where bench/run.sh puts its scratch anyway.
cat >"$work/rows" <<'ROWS'
stream content frame|main.test.a long stream costs|20000
stream tool-arg frame|main.test.streamed argument fragments|2000
compaction of a 1 MB conversation|main.test.compaction elides|1
build the request body 40 times|main.test.one request body|40
ranged read of a 512 KB line|main.test.a ranged read of a long line|1
ROWS
rows="$work/rows"

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

# Median of $runs samples of one binary. The median, not the mean, because the
# first run pays for the page faults on a binary that was just written and the
# rest do not.
#
# A build that fails, a test that no longer exists and a perf that measures
# nothing all used to leave no output, which the row printed as "not built" and
# `--check` counted as a pass: a renamed test or a compile error turned the
# gate green. Each is a broken measurement now, named and non-zero.
measure() {
	filter=$1
	# One build, then the same binary sampled $runs times. Rebuilding per
	# sample does not work: zig sees the inputs are unchanged, skips emitting,
	# and leaves no binary to run.
	rm -f "$bin"
	if ! "$zig" test -fno-strip -OReleaseFast \
		--dep build_options -Mroot=src/main.zig -Mbuild_options="$opts" \
		--cache-dir "$root/.zig-cache" --global-cache-dir "$ZIG_GLOBAL_CACHE_DIR" \
		--name test --test-filter "$filter" \
		--zig-lib-dir "$lib" -femit-bin="$bin" >"$work/build.log" 2>&1; then
		printf 'bench/instructions.sh: the test build failed for filter %s\n' "$filter" >&2
		sed -n '1,20p' "$work/build.log" >&2
		return 3
	fi
	[ -x "$bin" ] || {
		printf 'bench/instructions.sh: no test binary was emitted for filter %s\n' "$filter" >&2
		return 3
	}
	# A filter that matches nothing still builds, still runs, and reports the
	# cost of the process and nothing else, so the row looks like a real number
	# and measures an empty binary. `main.test_0` is the reference block: it
	# runs whatever the filter is, so one test means the filter selected none.
	# This is not hypothetical: --test-filter does not reach tests declared in
	# an imported module, so a row naming one reads as a passing measurement of
	# nothing at all.
	matched=$("$bin" 2>&1 | sed -n 's/^All \([0-9][0-9]*\) tests\? passed\..*/\1/p' | tail -n 1)
	if [ "${2:-}" != baseline ] && [ -n "$matched" ] && [ "$matched" -le 1 ]; then
		printf 'bench/instructions.sh: the filter %s selected no test, so the row would measure an empty binary\n' "$filter" >&2
		return 3
	fi
	i=0
	samples="$work/samples"
	: >"$samples"
	while [ "$i" -lt "$runs" ]; do
		perf stat -e instructions "$bin" </dev/null 2>&1 |
			grep -oE '[0-9,]+[[:space:]]+instructions' |
			grep -oE '^[0-9,]+' | tr -d ',' >>"$samples"
		i=$((i + 1))
	done
	[ -s "$samples" ] || {
		printf 'bench/instructions.sh: perf counted no instructions for filter %s, so the row has no number to compare\n' "$filter" >&2
		return 3
	}
	sort -n "$samples" | awk '{ v[NR] = $1 } END { print v[int((NR + 1) / 2)] }'
}

# The baseline is meant to select no test: it is the same binary with nothing
# run, which is what every other row is measured net of.
baseline=$(measure zzzz_no_such_test baseline) || exit 2
printf '%-32s %14s %14s\n' path instructions instr_per_unit
printf '%s\n' "--------------------------------------------------------------------------"
printf '%-32s %14s %14s\n' baseline "$baseline" -

worst=0
while IFS='|' read -r name filter units; do
	[ -n "$name" ] || continue
	value=$(measure "$filter") || exit 2
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
