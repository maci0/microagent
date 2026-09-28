#!/bin/sh
# Sourced by the benchmark scripts for the one thing GNU coreutils gives a
# Linux machine and a BSD one does not: `timeout`. It is probed for, not
# selected by OS name, and falls back to something POSIX that costs accuracy,
# not the run. The clock lives in monotonic.sh, which is sourced alongside.
#
#   run_limited SECS DIR CMD.. -> run CMD in DIR, TERM it after SECS, KILL it
#                                   if it is still there after the grace

# A TERM a process can ignore is not a ceiling. A harness that traps SIGTERM
# (a Node CLI installing its own handler, anything run under a wrapper that
# forwards signals) outlives the timeout, and the caller is left in `wait` on a
# ceiling that will never arrive: the whole benchmark stops and no row is
# written. Both limiters below therefore escalate, and the grace is what decides
# how long a process gets to exit on its own before it is killed. It is
# deliberately short: nothing a benchmark runs is meant to take ten seconds to
# notice a signal.
run_limited_grace=5

# macOS ships neither `timeout` nor `gtimeout` without coreutils installed.
limiter=
if command -v timeout >/dev/null 2>&1; then
	limiter=timeout
elif command -v gtimeout >/dev/null 2>&1; then
	limiter=gtimeout
fi

if [ -n "$limiter" ]; then
	# `-k` is the escalation: without it GNU timeout TERMs and then waits for
	# the child however long it takes, which is the same hang the watchdog
	# branch above is written to avoid.
	run_limited() {
		secs=$1 dir=$2
		shift 2
		(cd "$dir" && exec "$limiter" -k "$run_limited_grace" "$secs" "$@")
	}
else
	# A watchdog polls the child and TERMs it at the ceiling, then KILLs it if
	# the grace passes. The sleep is one second, so killing the watchdog leaves
	# nothing behind but a moment. Each signal is sent only while the child is
	# still there: a pid the kernel has already recycled belongs to somebody
	# else by the time a poll says so, and a benchmark that TERMs a stranger's
	# process is worse than one that overran by a second.
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
			if kill -0 "$pid" 2>/dev/null; then
				kill -TERM "$pid" 2>/dev/null
				grace=0
				while [ "$grace" -lt "$run_limited_grace" ]; do
					kill -0 "$pid" 2>/dev/null || break
					grace=$((grace + 1))
					sleep 1
				done
				kill -KILL "$pid" 2>/dev/null
			fi
		) &
		watchdog=$!
		wait "$pid"
		rc=$?
		kill "$watchdog" 2>/dev/null
		wait "$watchdog" 2>/dev/null
		return $rc
	}
fi
