#!/bin/sh
# Sourced by the benchmark scripts for the two things GNU coreutils give a
# Linux machine and a BSD one does not: a fractional clock and `timeout`.
# Both are probed for, not selected by OS name, and each falls back to
# something POSIX that costs accuracy, not the run.
#
#   now_s                     -> seconds since the epoch, fractional where the
#                                local date(1) can manage it
#   elapsed_s END START       -> the difference between two now_s readings
#   run_limited SECS DIR CMD.. -> run CMD in DIR, TERM it after SECS

# GNU date prints fractional seconds; BSD date prints a literal "N".
if [ "$(date +%N 2>/dev/null)" != "N" ]; then
	now_s() { date +%s.%N; }
	elapsed_s() { awk -v end="$1" -v start="$2" 'BEGIN{printf "%.1f", end-start}'; }
else
	now_s() { date +%s; }
	elapsed_s() { echo $(( $1 - $2 )); }
fi

# macOS ships neither `timeout` nor `gtimeout` without coreutils installed.
if command -v timeout >/dev/null 2>&1; then
	run_limited() {
		secs=$1 dir=$2
		shift 2
		(cd "$dir" && exec timeout "$secs" "$@")
	}
elif command -v gtimeout >/dev/null 2>&1; then
	run_limited() {
		secs=$1 dir=$2
		shift 2
		(cd "$dir" && exec gtimeout "$secs" "$@")
	}
else
	# A watchdog polls the child and TERMs it at the ceiling. The sleep is one
	# second, so killing the watchdog leaves nothing behind but a moment.
	run_limited() {
		secs=$1 dir=$2
		shift 2
		(cd "$dir" && exec "$@") &
		pid=$!
		(
			ticks=0
			while kill -0 "$pid" 2>/dev/null; do
				ticks=$((ticks + 1))
				[ "$ticks" -ge "$secs" ] && break
				sleep 1
			done
			kill -TERM "$pid" 2>/dev/null
		) &
		watchdog=$!
		wait "$pid"
		rc=$?
		kill "$watchdog" 2>/dev/null
		wait "$watchdog" 2>/dev/null
		return $rc
	}
fi
