#!/bin/sh
# Startup latency and first-request cost per harness. Answers "how much of a
# loop's time and tokens is the harness itself?".
#
#   bench/overhead.sh [agent ...]     default: every harness found on PATH
set -u

root=$(cd "$(dirname "$0")/.." && pwd)
. "$root/bench/monotonic.sh"
# shellcheck source=bench/portable.sh
. "$root/bench/portable.sh"
# shellcheck source=bench/harness.sh
. "$root/bench/harness.sh"
agents=${*:-microagent claude gemini codex crush grok kimi opencode cursor-agent clanker dsh}
prompt="Reply with exactly: pong"

# The work directory of the agent in flight, and the trap that takes it away on
# every way out, including a signal. `bench/instructions.sh` has one for the same
# reason: `rm -rf` on the last line of a loop body is reached only when the body
# runs to its end, so an interrupt or a failed command left one directory per
# agent behind in the system temp directory, and the next run started with the
# pile still there.
work=
trap '[ -n "$work" ] && rm -rf "$work"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

printf '%-14s %10s %10s %10s\n' agent startup_ms wall_s tokens
printf '%s\n' "----------------------------------------------"

for agent in $agents; do
	command -v "$agent" >/dev/null 2>&1 || continue
	# One work directory per agent, and hyperfine's export inside it: a fixed
	# machine-wide path is written by two runs at once and read by the other,
	# so each row's startup number is the other row's measurement.
	work=$(mktemp -d)
	# The mean is read by the key it is written under, not by its column: a
	# field position is only right for one layout, and hyperfine's export is
	# pretty-printed on some releases and a single line on others. Read as a
	# column, the compact form put the command string where the number is and
	# every harness answered 0.0 ms as though it started in no time at all. A
	# key no line carries leaves the column `-`, which is what an unreadable
	# export already is elsewhere in this script.
	startup=$(hyperfine -w 3 -r 20 -N --export-json "$work/startup.json" "$agent --version" >/dev/null 2>&1 \
		&& awk 'match($0, /"mean"[[:space:]]*:[[:space:]]*[0-9.eE+-]+/) {
			seconds = substr($0, RSTART, RLENGTH)
			sub(/^[^:]*:[[:space:]]*/, "", seconds)
			printf "%.1f", seconds * 1000
			exit
		}' "$work/startup.json")
	[ -z "$startup" ] && startup=-

	# The startup column above comes from hyperfine, which has the resolution
	# for a sub-millisecond figure. This clock does not: two back-to-back
	# readings of /proc/uptime differ by 0 ns, because it has 10 ms
	# granularity. It is right for the one-shot wall time below and wrong for
	# anything shorter, which is why nothing short is measured with it.
	if ! start=$(monotonic_ns); then
		printf '%-14s %10s %10s %10s\n' "$agent" "$startup" no-clock -
		rm -rf "$work"
		continue
	fi

	# The harness's own spelling of a one-shot prompt, so a CLI that needs a
	# subcommand is measured through it instead of through a `-p` it refuses.
	# Splitting the words apart is the point: the name and its subcommand are
	# one command line and the prompt is the last of them. Read on its own line
	# and checked, so an invocation that could not be spelled is a named error
	# rather than a run of the harness's name alone.
	if ! words=$(harness_argv "$agent"); then
		printf '%s: %s has no known invocation, skipping it\n' "$0" "$agent" >&2
		rm -rf "$work"
		continue
	fi
	# because: $words is the name and subcommand harness_argv prints, and
	# quoted it arrives as one argument and runs the name alone
	# shellcheck disable=SC2086
	run_limited 180 "$work" $words "$prompt" >"$work/out" 2>&1
	# Both ends of the clock are checked, not just the first. An empty reading
	# is not an error awk reports, it reads as a field worth 0, so a second
	# reading that failed divided one raw nanosecond count by a billion and
	# printed that as the run's wall time.
	if ! end=$(monotonic_ns); then
		printf '%-14s %10s %10s %10s\n' "$agent" "$startup" no-clock -
		rm -rf "$work"
		continue
	fi
	wall=$(echo "$end $start" | awk '{printf "%.1f", ($1-$2)/1000000000}')
	# Only microagent prints a machine-readable cumulative total.
	tokens=$(grep -o '"total_tokens":[0-9]*' "$work/out" 2>/dev/null | tail -1 | cut -d: -f2)
	[ -z "$tokens" ] && tokens=-
	rm -rf "$work"

	printf '%-14s %10s %10s %10s\n' "$agent" "$startup" "$wall" "$tokens"
done
