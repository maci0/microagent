#!/bin/sh
# The linter versions the gate runs are pinned in the Makefile, and this checks
# that every other record of a pin agrees with them: the installed tools, the
# manifest CI compiles its hashed install from, the version ruff itself reads, and the interpreter the
# Harbor lock resolves for. A disagreement here is a green run CI disagrees
# with, or a pin that names one version in one file and another in the next.
#
# The versions are passed in rather than read from the Makefile, so the Makefile
# stays the one place a version is written down. The Harbor manifest arrives as
# an argument for the same reason scripts/lint-lock.sh takes one: the directory
# is written down in the Makefile, and a second spelling of it in a script is a
# path that goes on disagreeing with the one the rest of the gate passes. A
# version mismatch is reported by name rather than surfacing later as a
# formatting diff no one can explain, so the message says what to install.
set -eu

: "${1:?usage: lint-versions.sh <path to the Harbor requirements.txt>}"
: "${RUFF_VERSION:?RUFF_VERSION is required}"
: "${YAMLLINT_VERSION:?YAMLLINT_VERSION is required}"

manifest="$1"
test -f "$manifest" || { echo "no $manifest, so the interpreter the Harbor lock resolves for cannot be checked" >&2; exit 1; }

have_ruff="$(ruff --version | awk '{print $2}')"
have_yamllint="$(yamllint --version | awk '{print $NF}')"
bad=0
[ "$have_ruff" = "$RUFF_VERSION" ] || {
  echo "ruff $have_ruff, the gate runs $RUFF_VERSION: install it with 'uv tool install ruff@$RUFF_VERSION'" >&2; bad=1; }
[ "$have_yamllint" = "$YAMLLINT_VERSION" ] || {
  echo "yamllint $have_yamllint, the gate runs $YAMLLINT_VERSION: install it with 'uv tool install yamllint==$YAMLLINT_VERSION'" >&2; bad=1; }
ruff_pin="$(sed -n 's/^ruff==\([^ ]*\).*/\1/p' lint-requirements.txt)"
yamllint_pin="$(sed -n 's/^yamllint==\([^ ]*\).*/\1/p' lint-requirements.txt)"
{ [ "$ruff_pin" = "$RUFF_VERSION" ] && [ "$yamllint_pin" = "$YAMLLINT_VERSION" ]; } || {
  echo "lint-requirements.txt pins ruff==$ruff_pin and yamllint==$yamllint_pin, not $RUFF_VERSION and $YAMLLINT_VERSION: CI installs that file, so a bump here has to bump the Makefile too, and the file is recompiled from lint-requirements.in with: uv pip compile --generate-hashes --python-version 3.12 --universal -o lint-requirements.txt lint-requirements.in" >&2; bad=1; }
# The manifest the lock is compiled from is read too. Every other record of a pin
# is checked, and a bump that stops at this file is the one drift left standing:
# the compiled lock still installs the old version, so the gate stays green, and
# the recompile someone runs next month then lands a linter bump nobody reviewed.
# Both files are read by bare name, as the one above is.
for source in lint-requirements.in lint-requirements.txt; do
  test -f "$source" || { echo "no $source, so the linter pins cannot be checked" >&2; exit 1; }
done
ruff_source="$(sed -n 's/^ruff==\([^ ]*\).*/\1/p' lint-requirements.in)"
yamllint_source="$(sed -n 's/^yamllint==\([^ ]*\).*/\1/p' lint-requirements.in)"
{ [ -n "$ruff_source" ] && [ -n "$yamllint_source" ] && [ "$ruff_source" = "$ruff_pin" ] && [ "$yamllint_source" = "$yamllint_pin" ] && [ "$ruff_source" = "$RUFF_VERSION" ] && [ "$yamllint_source" = "$YAMLLINT_VERSION" ]; } || {
  echo "lint-requirements.in names ruff==$ruff_source and yamllint==$yamllint_source, where lint-requirements.txt names ruff==$ruff_pin and yamllint==$yamllint_pin, and the gate runs $RUFF_VERSION and $YAMLLINT_VERSION: the manifest uv compiles from has to name the versions CI installs, or the next recompile lands a linter bump no run gated" >&2;
  echo "a bump to either has to bump RUFF_VERSION or YAMLLINT_VERSION, lint-requirements.in, and lint-requirements.txt, in the same change" >&2; bad=1; }
ruff_required="$(sed -n 's/^required-version = "\(.*\)"/\1/p' ruff.toml)"
[ "$ruff_required" = "$RUFF_VERSION" ] || {
  echo "ruff.toml requires ruff $ruff_required, not $RUFF_VERSION: a contributor running 'ruff check --config ruff.toml' directly is told nothing by the gate, and 'required-version' is the one pin ruff reads there" >&2;
  echo "a bump to RUFF_VERSION has to bump required-version, and lint-requirements.txt, in the same change" >&2; bad=1; }
ruff_target="$(sed -n 's/^target-version = "\(py[0-9]*\)"/\1/p' ruff.toml)"
lock_target="$(sed -n 's/.*uv pip compile.*--python-version \([0-9][0-9.]*\).*/\1/p' "$manifest")"
lock_py="$(printf '%s' "$lock_target" | tr -d .)"
{ [ -n "$ruff_target" ] && [ -n "$lock_target" ] && [ "$ruff_target" = "py$lock_py" ]; } || {
  echo "ruff.toml checks against $ruff_target and $manifest resolves its lock for $lock_target: a py target raised here without the floor raised there lints against an interpreter the lock does not resolve for" >&2;
  echo "a bump to either has to bump the other, and the 'uv pip compile' at the top of that manifest with it" >&2; bad=1; }
test "$bad" -eq 0
