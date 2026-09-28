# shellcheck shell=sh
# Monotonic nanoseconds, as a sourced shell function. Not meant to be run.
# shellcheck shell=sh
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
#   /proc/uptime      Linux, 10 ms resolution
#   perl Time::HiRes  CLOCK_MONOTONIC (macOS ships perl)
#   date              last resort, and still a wall clock
monotonic_ns() {
	if [ -r /proc/uptime ]; then
		value=$(awk '{ printf "%.0f\n", $1 * 1000000000 }' /proc/uptime 2>/dev/null)
		case "$value" in
		'' | *[!0-9]*) ;;
		*) printf '%s\n' "$value"; return 0 ;;
		esac
	fi
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
	# Padded to nanoseconds: a bare `date +%s` here would be off by a factor
	# of a billion rather than merely unmonotonic.
	printf '%s000000000\n' "$(date +%s)"
}
