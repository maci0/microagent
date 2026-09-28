# shellcheck shell=sh
# How each agent CLI takes one non-interactive prompt, as the words that come
# before it. Sourced by the two bench scripts that drive those CLIs, because the
# spelling is not the same everywhere and a bare `-p` is a command line three of
# them refuse: `codex` needs `exec` plus the flag that lets it run outside a
# trusted directory, and `crush` and `opencode` need `run`. A harness measured
# through a command line it rejects is a wrong number, not a slow one.
#
#   harness_argv AGENT -> prints the words that precede the prompt
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
