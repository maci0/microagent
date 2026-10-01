#!/bin/sh
# That lint-shell-stale.sh refuses each stale directive it exists to catch, and
# accepts each live one, asked over synthetic files rather than over the tree.
#
# The script under test is a set of refusals, and the way a refusal rots is a
# later edit that keeps the passing path and drops one of the failing ones: the
# gate stays green on a tree it should refuse, and nothing in the run says so.
# lint-versions has the same shape and the same self-test for it, and the
# reason it needed one is on record there: a check that stopped running reads
# exactly like a check that passes.
#
# The tree itself is not perturbed. Every file here is written into a temporary
# directory that the trap removes, because the question is what the script says
# about a directive, not what a directive does to this checkout: perturbing a
# real script to make the gate go red would mean editing a file the gate reads
# and restoring it afterwards, and an interrupted run would leave the tree
# holding the perturbation. Two files are written instead of one, because the
# answer the script gives is about the whole set it is handed: a directive that
# silences something in one file is live even when the file it sits in no longer
# trips it, and a case that only ever wrote one file could not tell those two
# apart.
#
# SHELLCHECK_OPTS arrives the way lint-shell-stale.sh gets it, from the Makefile,
# so the options asked here are the ones the gate asks with.
set -eu

: "${SHELLCHECK_OPTS:?SHELLCHECK_OPTS is required}"

here="$(dirname "$0")"
stale="$here/lint-shell-stale.sh"
test -f "$stale" || { echo "no $stale, so there is nothing to perturb" >&2; exit 1; }

work="$(mktemp -d)"
cleanup() {
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

# A script that trips one check the gate can see, so the file below has
# something for a directive to silence. SC2086 fires on an unquoted expansion,
# and the gate enables the checks that report it in default severity.
# because: the expansion is the finding this fixture has to carry, so it stays
# literal here: written in double quotes it would expand to this script's own
# empty positional parameters and the file would trip nothing
# shellcheck disable=SC2016
printf '%s\n' '#!/bin/sh' 'set -eu' 'words=$*' 'printf "%s\n" $words' > "$work/live.sh"

# The script under test as the Makefile runs it. The answer is left in a
# variable rather than returned, so no case calls it in a condition: `set -e` is
# suspended for the duration of a function called in an `if`, which would mean a
# case that thought it was checking a failure was running with the exit-on-error
# off.
refused=
run_stale() {
  # because: the script under test reads its file list as arguments, so the
  # split is the point
  if SHELLCHECK_OPTS="$SHELLCHECK_OPTS" sh "$stale" "$@" >/dev/null 2>&1; then
    refused=no
  else
    refused=yes
  fi
}

bad=0

# The starting state: a script whose directive does silence a finding is
# accepted. A check that refused every tree including the correct one is not a
# check.
run_stale "$work/live.sh"
if [ "$refused" = yes ]; then
  echo "lint-shell-stale refused a tree whose directive silences a live finding, so nothing below says anything" >&2
  exit 1
fi
echo "a directive over a finding the tree still raises: accepted, as it should"

# One case: the gate must refuse with the directive as described.
expect() {
  label="$1"
  file="$2"
  shift 2
  "$@"
  run_stale "$work/live.sh" "$work/case.sh"
  if [ "$refused" = yes ]; then
    echo "$label: refused, as it should"
  else
    echo "$label: lint-shell-stale accepted a tree it should have refused" >&2
    echo "  $file carries the edit, and the gate did not notice it" >&2
    bad=1
  fi
  rm -f "$work/case.sh"
}

# A code the tree raises nowhere, which is what a directive naming it is
# silencing nothing over. SC2154 reads an unassigned variable as a typo of one
# the script never meant, and no script written here trips it.
plant_stale() {
  printf '%s\n' '#!/bin/sh' 'set -eu' '# because: planted' '# shellcheck disable=SC2154' 'printf "%s\n" hi' > "$work/case.sh"
}
expect "a directive naming a check the tree never raises" "$work/case.sh" plant_stale

# The same directive as a second entry on a line with a live one. The gate
# refuses the file for the dead name without dropping the live one, which is
# what makes reporting one name rather than the whole directive the useful
# behaviour: a contributor who added a real suppression to a file carrying an
# old one still learns about the old one.
plant_mixed() {
  printf '%s\n' '#!/bin/sh' 'set -eu' '# because: planted' '# shellcheck disable=SC2086,SC2154' 'printf "%s\n" hi' > "$work/case.sh"
}
expect "a live and a dead name on one directive" "$work/case.sh" plant_mixed

test "$bad" -eq 0
echo "lint-shell-stale refuses every stale directive it is asked to refuse, and accepts the live ones"