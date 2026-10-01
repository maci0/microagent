#!/bin/sh
# Sourced by the benchmark scripts, whose root names this checkout.
# Python already supplies their memory probe; one POSIX process-group runner
# also bounds commands on Linux and macOS without a shell watchdog.
#
#   run_limited SECS DIR CMD.. -> run CMD in DIR, TERM it after SECS, KILL any
#                               remaining processes before returning
command -v python3 >/dev/null 2>&1 || {
	printf '%s\n' 'bench/portable.sh: python3 is required for benchmark deadlines; no measurement was run' >&2
	exit 2
}

run_limited() {
	python3 "${root:?benchmark checkout root is required}/bench/limit.py" "$@"
}

# How each agent CLI takes one non-interactive prompt, as the words that come
# before it. The spelling is not the same everywhere and a bare `-p` is a
# command line three of them refuse: `codex` needs `exec` plus the flag that
# lets it run outside a trusted directory, and `crush` and `opencode` need
# `run`. A harness measured through a command line it rejects is a wrong
# number, not a slow one.
#
#   harness_argv AGENT -> the words that precede the prompt
harness_argv() {
	case "$1" in
	microagent) printf '%s' "microagent --print" ;;
	claude) printf '%s' "claude -p" ;;
	kimi) printf '%s' "kimi -p" ;;
	codex) printf '%s' "codex exec --skip-git-repo-check" ;;
	crush) printf '%s' "crush run" ;;
	opencode) printf '%s' "opencode run" ;;
	*) printf '%s' "$1 -p" ;;
	esac
}
