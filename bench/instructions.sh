#!/bin/sh
# Retired instructions per unit of work, for the paths a run actually walks.
#
#   sh bench/instructions.sh            print the table
#   sh bench/instructions.sh --check    the same, and fail on a row that left
#                                       the band in either direction
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

for value in "$runs" "$tolerance"; do
	case "$value" in
	'' | *[!0-9]*) echo 'bench/instructions.sh: RUNS and TOLERANCE must be decimal integers' >&2; exit 2 ;;
	esac
done
[ "$runs" -gt 0 ] 2>/dev/null || {
	echo 'bench/instructions.sh: RUNS must be a positive platform integer' >&2
	exit 2
}

command -v perf >/dev/null 2>&1 || {
	# Say which platform rather than leaving a macOS contributor to install
	# something that will never be there.
	printf '%s\n' "bench/instructions.sh: this measurement needs Linux perf, which macOS does not ship; nothing to measure" >&2
	exit 2
}

# Row name, test filter, units the row's work is done in. Per-unit numbers stay
# comparable when a test grows.
# The baseline is measured once, before this loop, so it is not a row.
# The tree's own gitignored .scratch/, for the reason bench/run.sh and
# bench/gauntlet.sh build theirs there rather than under ${TMPDIR:-/tmp}: /tmp is
# a tmpfs on most Linux hosts, and a run writes a test binary and a perf report
# per row into it, so the measurement's disk is the host's RAM. It is inside the
# tree so `rm -rf` in the harness leaves nothing to sweep up by hand, and it is
# still the tree's, not a path two accounts on a shared machine share.
# BENCH_WORK overrides it for a contributor who names a scratch disk.
work_root="${BENCH_WORK:-$root/.scratch/instructions}"
# mktemp inside that root rather than at a fixed name: two runs on one host
# would otherwise share one directory, and each would delete the other's binary.
mkdir -p "$work_root" || exit 2
work=$(mktemp -d "$work_root/run-XXXXXX") || exit 2
# The signal traps are `bench/overhead.sh`'s, for its reason: an EXIT trap is
# not run when the shell is killed, and a `perf` run over five rows takes
# minutes, so Ctrl-C is the ordinary way to stop one and the work directory
# holding its binary was left behind.
trap 'rm -rf "$work"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
bin="$work/instructions-test"

# The rows live in $work rather than beside this script: a predictable path in a
# world-writable directory is another account's file to write through.
cat >"$work/rows" <<'ROWS'
stream content frame|stream.test.a long stream costs|20000
stream tool-arg frame|stream.test.streamed argument fragments|2000
compaction of a 1 MB conversation|conversation.test.compaction elides|1
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
if [ -z "$lib" ] || [ ! -d "$lib" ]; then
	std=$(printf '%s' "$zigenv" | sed -n 's/.*\.std_dir = "\([^"]*\)".*/\1/p' | head -n 1)
	# `dirname` of an empty word is `.`, a directory this script is standing
	# in, so the empty reading is refused here. Left to the build it is
	# `--zig-lib-dir .`, and the compiler's message about a lib_dir says
	# nothing about the `zig env` line that read it wrong.
	[ -n "$std" ] || {
		printf 'bench/instructions.sh: %s env reports no std_dir, so there is no lib directory to build against\n' "$zig" >&2
		exit 2
	}
	lib=$(dirname "$std")
fi

# Median of $runs samples of one binary. The median, not the mean, because the
# first run pays for the page faults on a binary that was just written and the
# rest do not. An even count takes the mean of the two middle samples, since one
# of them alone is not the median: `RUNS=4` on samples 100 200 300 400 answered
# 200, a whole sample below the middle, and that sample lands in
# `instr_per_unit` and in the band check below. The mean is floored rather than
# rounded, because the row is compared in shell integer arithmetic.
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
		--dep build_options --dep copy -Mroot=src/main.zig -Mbuild_options="$opts" \
		-fno-builtin -Mcopy=src/copy.zig \
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
	if ! "$bin" >"$work/test.log" 2>&1; then
		printf 'bench/instructions.sh: the selected test failed for filter %s\n' "$filter" >&2
		sed -n '1,20p' "$work/test.log" >&2
		return 3
	fi
	matched=$(sed -n 's/^All \([0-9][0-9]*\) tests\{0,1\} passed\..*/\1/p' "$work/test.log" | tail -n 1)
	expected=2
	[ "${2:-}" = baseline ] && expected=1
	if [ "$matched" != "$expected" ]; then
		printf 'bench/instructions.sh: filter %s must select %s tests including the reference block, found %s\n' "$filter" "$expected" "${matched:-no count}" >&2
		return 3
	fi
	i=0
	samples="$work/samples"
	: >"$samples"
	while [ "$i" -lt "$runs" ]; do
		if ! perf stat -e instructions "$bin" </dev/null >"$work/perf.log" 2>&1; then
			printf 'bench/instructions.sh: perf failed for filter %s\n' "$filter" >&2
			sed -n '1,20p' "$work/perf.log" >&2
			return 3
		fi
		sample=$(grep -oE '[0-9,]+[[:space:]]+instructions' "$work/perf.log" | grep -oE '^[0-9,]+' | tr -d ',')
		case "$sample" in
		'' | *[!0-9]*)
			printf 'bench/instructions.sh: perf reported no single instruction count for filter %s\n' "$filter" >&2
			return 3
			;;
		esac
		printf '%s\n' "$sample" >>"$samples"
		i=$((i + 1))
	done
	[ -s "$samples" ] || {
		printf 'bench/instructions.sh: perf counted no instructions for filter %s, so the row has no number to compare\n' "$filter" >&2
		return 3
	}
	sort -n "$samples" | awk '{ v[NR] = $1 } END {
		if (NR % 2) print v[(NR + 1) / 2]
		else print int((v[NR / 2] + v[NR / 2 + 1]) / 2)
	}'
}

# The baseline is meant to select no test: it is the same binary with nothing
# run, which is what every other row is measured net of.
baseline=$(measure zzzz_no_such_test baseline) || exit 2
printf '%-32s %14s %14s\n' path instructions instr_per_unit
printf '%s\n' "--------------------------------------------------------------------------"
printf '%-32s %14s %14s\n' baseline "$baseline" -

regressed=0
improved=0
while IFS='|' read -r name filter units; do
	[ -n "$name" ] || continue
	value=$(measure "$filter") || exit 2
	# A row that retires fewer instructions than the binary that ran no test at
	# all has measured less than process start, so the difference is noise
	# rather than a count of work, and the column has no number to print for
	# it. Dividing it anyway put a negative in a table of instructions per unit
	# and, below, a ratio far outside the band that read as a large
	# improvement. Such a row is reported as unmeasured and the band check has
	# nothing to compare.
	if [ "$value" -ge "$baseline" ]; then
		per=$(((value - baseline) / units))
	else
		per=-
	fi
	printf '%-32s %14s %14s\n' "$name" "$value" "$per"

	if [ "${1:-}" = --check ]; then
		[ "$per" != - ] || {
			printf 'bench/instructions.sh: no measurement for %s, so its band cannot be checked\n' "$name" >&2
			exit 2
		}
		want=$(awk -F'\t' -v n="$name" '$1 == n { print $2 }' "$root/bench/instructions.baseline") || exit 2
		[ "$want" -gt 0 ] 2>/dev/null || {
			printf 'bench/instructions.sh: no positive baseline for %s\n' "$name" >&2
			exit 2
		}

		# Keep ratios and tolerance arithmetic in awk so a large count
		# or percentage cannot wrap a shell integer.
		direction=$(awk -v per="$per" -v want="$want" -v tol="$tolerance" 'BEGIN {
			ratio = per * 100 / want
			if (ratio > 100 + tol) print "regressed"
			else if (ratio < 100 - tol) print "improved"
		}') || exit 2
		if [ "$direction" = regressed ]; then
			printf '  REGRESSION: %s is %s per unit, baseline %s (band +/-%s%%): fix the code that retired more\n' \
				"$name" "$per" "$want" "$tolerance"
			regressed=1
		elif [ "$direction" = improved ]; then
			printf '  IMPROVED: %s is %s per unit, baseline %s (band +/-%s%%): re-record bench/instructions.baseline\n' \
				"$name" "$per" "$want" "$tolerance"
			improved=1
		fi
	fi
done <"$rows"

if [ "${regressed:-0}" -ne 0 ]; then
	printf '%s\n' "bench/instructions.sh: a hot path retired more instructions than the baseline records: fix it, or re-record bench/instructions.baseline"
	exit 1
fi
if [ "${improved:-0}" -ne 0 ]; then
	printf '%s\n' "bench/instructions.sh: a hot path retired fewer instructions than the baseline records, so the baseline is stale: re-record it with 'sh bench/instructions.sh' and commit the result"
	exit 1
fi
exit 0
