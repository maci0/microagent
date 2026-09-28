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

# A ceiling that is not a count of seconds is not a ceiling. GNU `timeout`
# reads a zero as "no limit at all", and the watchdog below compares with
# `test -ge`, which errors rather than compares on anything else and so never
# fires: a typo in BENCH_TIMEOUT either runs a task for ever or runs it with
# no ceiling. Both branches refuse it here instead, where the caller can see.
check_secs() {
	case "$1" in
	'' | *[!0-9]*)
		printf 'run_limited: %s is not a number of seconds\n' "$1" >&2
		return 1
		;;
	esac
	[ "$1" -ge 1 ] || {
		printf 'run_limited: a zero-second ceiling is no ceiling\n' >&2
		return 1
	}
	return 0
}

if [ -n "$limiter" ]; then
	# `-k` is the escalation: without it GNU timeout TERMs and then waits for
	# the child however long it takes, which is the same hang the watchdog
	# branch above is written to avoid.
	run_limited() {
		secs=$1 dir=$2
		shift 2
		check_secs "$secs" || return 2
		(cd "$dir" && exec "$limiter" -k "$run_limited_grace" "$secs" "$@")
	}
else
	# A watchdog polls the child and TERMs its group at the ceiling, then
	# KILLs the group if the grace passes. The sleep is one second, so killing
	# the watchdog leaves nothing behind but a moment. Each signal is sent only
	# while the child is still there: a pid the kernel has already recycled
	# belongs to somebody else by the time a poll says so, and a benchmark that
	# TERMs a stranger's process is worse than one that overran by a second.
	#
	# The group, not the pid, is what the signals below address, and that is
	# the same thing GNU `timeout` does above. Signalling only the process it
	# spawned left the rest of the tree running: a harness that outlived the
	# ceiling went on writing into the work tree the next task copies and the
	# check then diffs, and a build or test server it had launched held a port
	# and a directory the following runs fought over. One benchmark run leaked
	# one process tree per task that overran, and the next run started with
	# every one of them still there.
	#
	# The child is made a group leader by `set -m` around the launch, because
	# a non-interactive shell runs a background job in its own process group
	# only when job control is on, and without it `-$pid` would name this
	# script's group: the watchdog would signal the benchmark, and the
	# measurement of one task would end the measurement of the rest. The
	# setting is restored immediately because this is a sourced function and
	# the caller's shell outlives the call, and the job notification job
	# control prints is dropped rather than written into the task's output,
	# which is read back for the numbers below.
	run_limited() {
		secs=$1 dir=$2
		shift 2
		check_secs "$secs" || return 2
		{ set -m; (cd "$dir" && exec "$@") & } 2>/dev/null
		pid=$!
		set +m
		(
			# The tick is counted after the sleep, so `secs` sleeps have passed
			# by the time the ceiling is read. Counting it first read the
			# ceiling one second early, which cut a one-second budget to no
			# budget at all.
			ticks=0
			while kill -0 "$pid" 2>/dev/null; do
				sleep 1
				ticks=$((ticks + 1))
				[ "$ticks" -ge "$secs" ] && break
			done
			if kill -0 "$pid" 2>/dev/null; then
				kill -TERM -"$pid" 2>/dev/null
				grace=0
				while [ "$grace" -lt "$run_limited_grace" ]; do
					kill -0 "$pid" 2>/dev/null || break
					grace=$((grace + 1))
					sleep 1
				done
				# The group rather than the leader, and not only while the
				# leader answers: a leader that took the TERM and left is
				# exactly the case the ceiling exists to end, and the children
				# are the part that was never asked to die with it.
				kill -KILL -"$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null
			fi
		) &
		watchdog=$!
		wait "$pid"
		rc=$?
		kill "$watchdog" 2>/dev/null
		wait "$watchdog" 2>/dev/null
		return "$rc"
	}
fi
