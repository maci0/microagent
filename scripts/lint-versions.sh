#!/bin/sh
# The linter versions the gate runs are pinned in the Makefile, and this checks
# that every other record of a pin agrees with them: the installed tools, the
# manifest CI compiles its hashed install from, the version ruff itself reads,
# the interpreter each lock is compiled to resolve for, and the interpreter CI
# builds the venv the gate runs in. A disagreement here is a green run CI
# disagrees with, or a pin that names one version in one file and another in the
# next.
#
# The versions are passed in rather than read from the Makefile, so the Makefile
# stays the one place a version is written down. The Harbor manifest arrives as
# an argument for the same reason scripts/lint-lock.sh takes one: the directory
# is written down in the Makefile, and a second spelling of it in a script is a
# path that goes on disagreeing with the one the rest of the gate passes. The
# linter manifest is read by bare name, as lint-requirements.in and
# lint-requirements.txt already are below, since it lives at the root rather than
# in a directory and the Makefile passes the same bare name to lint-lock.sh.
# A version mismatch is reported by name rather than surfacing later as a
# formatting diff no one can explain, so the message says what to install.
set -eu

: "${1:?usage: lint-versions.sh <path to the Harbor requirements.txt>}"
: "${RUFF_VERSION:?RUFF_VERSION is required}"
: "${YAMLLINT_VERSION:?YAMLLINT_VERSION is required}"

manifest="$1"
test -f "$manifest" || { echo "no $manifest, so the interpreter the Harbor lock resolves for cannot be checked" >&2; exit 1; }
# The README beside that manifest, derived from the path rather than spelled
# again: the Harbor directory is written down in the Makefile and arrives here
# as this one argument, and a second spelling of the same path in this file is
# the spelling that goes on disagreeing with it.
harbor_readme="$(dirname "$manifest")/README.md"
test -f "$harbor_readme" || { echo "no $harbor_readme, so the interpreter the benchmark venv is built for cannot be checked" >&2; exit 1; }

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
# The interpreter each lock resolves for, against the target-version ruff
# checks against. There are two manifests here, and both are checked: ruff
# lints the Python in this tree, and the pin that lints it is ruff in
# lint-requirements.txt, compiled from lint-requirements.in. Reading the floor
# out of the Harbor manifest alone left a bump to the linter manifest's
# --python-version unobserved, so the two locks could resolve for different
# interpreters and the gate stayed green, which is the drift this whole script
# exists to catch. A manifest with no --python-version line is reported rather
# than skipped, so a reworded comment cannot silently turn the check off.
ruff_target="$(sed -n 's/^target-version = "\(py[0-9]*\)"/\1/p' ruff.toml)"
for source in lint-requirements.in "$manifest"; do
  lock_target="$(sed -n 's/.*uv pip compile.*--python-version \([0-9][0-9.]*\).*/\1/p' "$source")"
  lock_py="$(printf '%s' "$lock_target" | tr -d .)"
  { [ -n "$ruff_target" ] && [ -n "$lock_target" ] && [ "$ruff_target" = "py$lock_py" ]; } || {
    echo "ruff.toml checks against $ruff_target and $source resolves its lock for $lock_target: a py target raised here without the floor raised there lints against an interpreter the lock does not resolve for" >&2;
    echo "a bump to either has to bump the other, and the 'uv pip compile' at the top of that manifest with it" >&2; bad=1; }
done
# The interpreter CI builds the venv the gate runs in, which is a fourth record
# of the same floor and the only one a local run cannot see. setup-linters
# creates it with `uv venv --python <version>` and then installs the lock the
# manifests above are compiled for, so a bump to ruff.toml and both manifests
# that missed this line left `lint-versions` green on a runner building a venv
# an interpreter older than the one the linters are checked against: the
# checkout passes and CI runs the gate on something nobody declared. It is read
# by the same `sed` shape as the two manifests, so a reworded line is reported
# rather than skipped.
venv_target="$(sed -n 's/.*uv venv --python \([0-9][0-9.]*\).*/\1/p' .github/actions/setup-linters/action.yml)"
venv_py="$(printf '%s' "$venv_target" | tr -d .)"
{ [ -n "$ruff_target" ] && [ -n "$venv_target" ] && [ "$ruff_target" = "py$venv_py" ]; } || {
  echo "ruff.toml checks against $ruff_target and .github/actions/setup-linters/action.yml builds its venv for $venv_target: the gate runs on an interpreter nobody declared, so a bump to the floor has to bump this venv with it" >&2;
  echo "a bump to any of the three has to bump the other three: ruff.toml, the 'uv pip compile' at the top of each manifest, and the 'uv venv --python' in setup-linters" >&2; bad=1; }
# The interpreter the benchmark's own venv is built for, a fifth record of the
# same floor. setup-linters is the only venv the three above covered, and it is
# the one CI builds; the venv a contributor's score is measured in is created by
# the README's own `uv venv` line and by nothing else, so that line named no
# interpreter at all and this check had no reason to fail on it. `uv venv`
# without `--python` takes whichever interpreter it finds first on PATH, so a
# host whose default is 3.11 builds the Harbor lock -- a lock compiled with
# `--universal --python-version 3.12` -- into an interpreter one release below
# the floor the manifest states, and the adapter's own `from datetime import UTC`
# is a 3.11 name: the run fails at the first summarize, after the containers
# have already been paid for, rather than at the install. Read by the same `sed`
# shape as the venv above, so a reworded line is reported rather than skipped.
harbor_venv_target="$(sed -n 's/.*uv venv --python \([0-9][0-9.]*\).*/\1/p' "$harbor_readme")"
harbor_venv_py="$(printf '%s' "$harbor_venv_target" | tr -d .)"
{ [ -n "$ruff_target" ] && [ -n "$harbor_venv_target" ] && [ "$ruff_target" = "py$harbor_venv_py" ]; } || {
  echo "ruff.toml checks against $ruff_target and $harbor_readme creates its venv for ${harbor_venv_target:-no interpreter at all}: a benchmark is then measured in whatever interpreter uv finds on PATH rather than the one its lock resolves for" >&2;
  echo "a bump to the floor has to bump the 'uv venv --python' there with ruff.toml, the 'uv pip compile' in each manifest, and setup-linters" >&2; bad=1; }
test "$bad" -eq 0
