#!/bin/sh
# Sourced by the benchmark scripts for the one thing GNU coreutils gives a
# Linux machine and a BSD one does not: `timeout`. It is probed for, not
# selected by OS name, and falls back to something POSIX that costs accuracy,
# not the run. The clock lives in monotonic.sh, which is sourced alongside.
#
#   run_limited SECS DIR CMD.. -> run CMD in DIR, TERM it after SECS

# macOS ships neither `timeout` nor `gtimeout` without coreutils installed.
limiter=
if command -v timeout >/dev/null 2>&1; then
	limiter=timeout
elif command -v gtimeout >/dev/null 2>&1; then
	limiter=gtimeout
fi

if [ -n "$limiter" ]; then
	run_limited() {
		secs=$1 dir=$2
		shift 2
		(cd "$dir" && exec "$limiter" "$secs" "$@")
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
