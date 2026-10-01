# shellcheck shell=sh
# Monotonic nanoseconds, as a sourced shell function. Not meant to be run.
#
# POSIX sh has no monotonic clock, so these scripts reached for `date +%s`,
# which reads a clock NTP and an admin can step. A step inside a run makes
# end-start negative or an hour long, and that number is appended to
# results.jsonl as if it had been measured. (BSD date also has no %N, so the
# sub-second form silently measured the literal string "1756...N" on the machine
# that wrote it.)
#
# The sources below are tried in order. Reading another process is the only way
# to reach a monotonic clock from sh, hence the awk and perl calls. Each source
# is used only if it prints a number, and every source answers in nanoseconds: a
# source that fails has to fall through rather than poison the difference with a
# wrong unit.
#
# Both sources answer the same question, and the order is what makes that so.
# `/proc/uptime` is not a monotonic clock in the CLOCK_MONOTONIC sense: its man
# page says it is "the uptime of the system (including time spent in suspend)",
# which is CLOCK_BOOTTIME. perl's CLOCK_MONOTONIC stops while the machine is
# suspended. Asking two sources for one function name and letting the order pick
# meant a Linux laptop that suspended in the middle of a benchmark booked the
# suspend as harness time, and a macOS laptop on the same workload did not, so
# the two hosts' numbers answered different questions and `docs/benchmark.md`
# compared them anyway. perl answers CLOCK_MONOTONIC on Linux as well, so it is
# asked first and the suspend-free clock wins wherever perl is installed; the
# /proc/uptime reading is the fallback for a Linux host without it, and is
# labelled below as the quantity it is rather than passed off as the other one.
#
#   perl Time::HiRes  CLOCK_MONOTONIC, stops during suspend (macOS ships perl)
#   /proc/uptime      Linux, 10 ms resolution, includes suspend
#
# There is no third source. `date` was one and is gone: a wall clock is not a
# fallback for a measurement, it is a different quantity, so a host with neither
# source above is told no duration was measured rather than handed one.
monotonic_ns() {
	if command -v perl >/dev/null 2>&1; then
		# The constant has to be Time::HiRes's own: a bare CLOCK_MONOTONIC in
		# the main package is not defined and reads CLOCK_REALTIME instead.
		# clock_gettime answers in seconds, not nanoseconds.
		value=$(perl -MTime::HiRes -e \
			'printf "%.0f\n", Time::HiRes::clock_gettime(Time::HiRes::CLOCK_MONOTONIC()) * 1000000000' 2>/dev/null)
		case "$value" in
		'' | *[!0-9]*) ;;
		*) printf '%s\n' "$value"; return 0 ;;
		esac
	fi
	if [ -r /proc/uptime ]; then
		# $1 is system uptime in seconds, suspend included. See the header:
		# this is the same quantity on every run that reaches it, but not the
		# same quantity as the perl reading above, and the difference is every
		# second the machine spent asleep inside the measured window.
		value=$(awk '{ printf "%.0f\n", $1 * 1000000000 }' /proc/uptime 2>/dev/null)
		case "$value" in
		'' | *[!0-9]*) ;;
		*) printf '%s\n' "$value"; return 0 ;;
		esac
	fi
	# A wall clock is not a fallback for a measurement, it is a different
	# quantity: an NTP step inside a run makes the difference negative or an
	# hour long, and one-second resolution records a 17.7 s task as 17.0. So
	# rather than answer and let the number be recorded as if it were measured,
	# this refuses, and says which machines get here.
	printf 'bench/monotonic.sh: no monotonic clock: perl is not installed and /proc/uptime is unreadable, so no duration measured here can be trusted\n' >&2
	return 1
}
