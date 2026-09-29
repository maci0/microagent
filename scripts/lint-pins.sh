#!/bin/sh
# The gate's linters are pinned in lint-requirements.txt, which installs with
# --require-hashes and so verifies every artifact and resolves nothing. That
# says nothing about whether the pins are the right ones, and this file is
# hand-written: a yamllint bump can leave a pin nothing imports any more, or a
# pin below a bound the new yamllint asks for, and both install cleanly. The
# first is an unverified package in the venv a green lint run came from, and
# the second fails at import inside the lint job rather than here. This asks the
# installed distributions' own metadata, the same two questions
# scripts/lint-lock.sh asks of the Harbor lock, and leaves the roots alone:
# those are what the gate runs, not what another pin pulls in.
#
# The metadata lives in the interpreter the linters are installed for, which is
# not necessarily the one on PATH: a `uv tool install` linter has its own
# environment, and the CI venv is on PATH only because setup-linters puts it
# there. The console script's shebang names that interpreter, so it is read
# from the yamllint this runs rather than assumed, and `python3` is the
# fallback for a linter that is an ELF binary with no script to read.
#
# The requirements file and the root pins arrive as arguments, so the Makefile
# stays the one place the linter set is written down.
set -eu

: "${1:?usage: lint-pins.sh <path to requirements.txt> <root pin>...}"
test "$#" -gt 1 || {
  echo "lint-pins.sh takes the root pins as arguments too, so the check knows which pins are the linters rather than what something else requires" >&2
  exit 1
}

interpreter=""
yamllint_path="$(command -v yamllint || true)"
if [ -n "$yamllint_path" ]; then
  shebang="$(head -n 1 "$yamllint_path" 2>/dev/null || true)"
  case "$shebang" in
    '#!'*)
      interpreter="${shebang#\#!}"
      interpreter="${interpreter%% *}"
      ;;
  esac
fi
if [ -z "$interpreter" ] || ! command -v "$interpreter" >/dev/null 2>&1; then
  interpreter=python3
fi

here="${0%/*}"
if [ "$here" = "$0" ]; then
  here=.
fi

exec "$interpreter" "$here/lint-pins.py" "$@"
