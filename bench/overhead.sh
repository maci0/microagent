#!/bin/sh
# Startup latency and first-request cost per harness. Answers "how much of a
# loop's time and tokens is the harness itself?".
#
#   bench/overhead.sh [agent ...]     default: every harness found on PATH
set -u

root=$(cd "$(dirname "$0")/.." && pwd)
. "$root/bench/monotonic.sh"
agents=${*:-microagent claude gemini codex crush grok kimi opencode cursor-agent clanker dsh}
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
		&& awk -F'[:,]' '/"mean"/{printf "%.1f", $2*1000; exit}' "$work/startup.json") || startup=-
	[ -z "$startup" ] && startup=-

	work=$(mktemp -d)
	start=$(monotonic_ns)
	( cd "$work" && timeout 180 "$agent" -p "$prompt" ) >"$work/out" 2>&1
	end=$(monotonic_ns)
	wall=$(echo "$end $start" | awk '{printf "%.1f", ($1-$2)/1000000000}')
	# Only microagent prints a machine-readable cumulative total.
	tokens=$(grep -o '"total_tokens":[0-9]*' "$work/out" 2>/dev/null | tail -1 | cut -d: -f2)
	[ -z "$tokens" ] && tokens=-
	rm -rf "$work"

	printf '%-14s %10s %10s %10s\n' "$agent" "$startup" "$wall" "$tokens"
done
