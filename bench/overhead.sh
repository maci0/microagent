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
# A "reply with one word" turn is seconds of provider time, not minutes, so the
# ceiling is well above what a live harness needs and well below the point where
# a hung one would hold the sweep.
timeout_s=180
prompt="Reply with exactly: pong"

printf '%-14s %10s %10s %10s\n' agent startup_ms wall_s tokens
printf '%s\n' "----------------------------------------------"

for agent in $agents; do
	command -v "$agent" >/dev/null 2>&1 || continue
	# One work directory per agent, and hyperfine's export inside it: a fixed
	# machine-wide path is written by two runs at once and read by the other,
	# so each row's startup number is the other row's measurement.
	work=$(mktemp -d)
	startup=$(hyperfine -w 3 -r 20 -N --export-json "$work/startup.json" "$agent --version" >/dev/null 2>&1 \
		&& awk -F'[:,]' '/"mean"/{printf "%.1f", $2*1000; exit}' "$work/startup.json")
	[ -z "$startup" ] && startup=-

	start=$(monotonic_ns)
	# The words are left unquoted so the prompt lands as its own argument after
	# a subcommand `harness_argv` may have named; a quoted expansion would hand
	# the CLI a single argument it refuses.
	# shellcheck disable=SC2046
	run_limited "$timeout_s" "$work" $(harness_argv "$agent") "$prompt" >"$work/out" 2>&1
	end=$(monotonic_ns)
	wall=$(echo "$end $start" | awk '{printf "%.1f", ($1-$2)/1000000000}')
	# Only microagent prints a machine-readable cumulative total.
	tokens=$(grep -o '"total_tokens":[0-9]*' "$work/out" 2>/dev/null | tail -1 | cut -d: -f2)
	[ -z "$tokens" ] && tokens=-
	rm -rf "$work"

	printf '%-14s %10s %10s %10s\n' "$agent" "$startup" "$wall" "$tokens"
done
