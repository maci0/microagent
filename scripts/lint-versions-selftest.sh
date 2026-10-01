#!/bin/sh
# That lint-versions.sh refuses the drift it exists to catch, asked by moving
# each input in turn and requiring the gate to go red.
#
# lint-versions.sh is a set of refusals, and the way a refusal rots is a later
# edit that keeps the passing path and drops one of the failing ones: the gate
# stays green on a tree it should refuse, and nothing in the run says so. That
# happened once already. The interpreter floor was compared against the Harbor
# manifest alone, so ruff.toml's target-version was checked against a lock the
# linters never come from and a floor raised in lint-requirements.in went
# unobserved, and lint-versions was green on it. Nothing failed, because a check
# that never runs cannot fail. The same shape has one more record now: the
# interpreter setup-linters builds the venv the gate runs in, which a local run
# never sees and which every one of the other three would have to be bumped
# with.
#
# So this asks the question the other targets cannot: for each input the script
# reads, does moving it make the gate red? Every file is copied before it is
# touched and restored from that copy afterwards, so a run leaves the tree as it
# found it even when a case fails partway, and the trap restores again if the
# target is interrupted. Nothing is written to the tree: every temporary lives
# under a directory the script removes on the way out.
#
# RUFF_VERSION and YAMLLINT_VERSION arrive the way lint-versions gets them, from
# the Makefile, and the Harbor manifest arrives as an argument for the same
# reason: one spelling of each, in the one file that has it.
set -eu

: "${1:?usage: lint-versions-selftest.sh <path to the Harbor requirements.txt>}"
: "${RUFF_VERSION:?RUFF_VERSION is required}"
: "${YAMLLINT_VERSION:?YAMLLINT_VERSION is required}"

manifest="$1"
# Every file a case below edits, named here once and iterated by the backup, the
# restore and the guard. Each is named by the Makefile and read by
# lint-versions.sh, and the list is spelled out rather than derived, because a
# file derived from the script under test is a list that changes with the bug.
# An earlier version of this held three of them and let the fourth, the lock a
# pin is read back out of, be edited and never restored: the run left the pin
# behind, and the next run failed on a tree it had broken itself.
linter_manifest="lint-requirements.in"
linter_lock="lint-requirements.txt"
ruff_config="ruff.toml"
# The interpreter floor CI builds the lint venv for, a fourth file
# lint-versions.sh reads and this list did not name. It is backed up and
# restored like the rest, because a case that edits it and leaves it behind is
# the defect the list above records having had once already.
linter_action=".github/actions/setup-linters/action.yml"
files="$linter_manifest $linter_lock $ruff_config $manifest $linter_action"
for file in $files; do
  test -f "$file" || { echo "no $file, so there is nothing to perturb" >&2; exit 1; }
done

work="$(mktemp -d)"
# Put every file back where the copy in $work holds it. Split from the cleanup
# below because the cases between them still need $work: a case restores the
# tree so the next one starts from what was found, and only the exit path
# discards the copies.
restore() {
  for file in $files; do
    cp "$work/$(basename "$file")" "$file"
  done
}
# The exit path, on an interrupt as well as a normal finish, so an interrupted
# run leaves no manifest edited for the next one and no temporary behind.
cleanup() {
  restore
  rm -rf "$work"
}
trap cleanup EXIT INT TERM
for file in $files; do
  cp "$file" "$work/$(basename "$file")"
done

# lint-versions.sh as the Makefile runs it, spelled once here because every case
# below asks the same question of it. The answer is left in a variable rather
# than returned, so no case has to call it in a condition: `set -e` is suspended
# for the duration of a function called in an `if`, which would mean a case that
# thought it was checking a failure was running with the exit-on-error off.
# lint-versions.sh is run with its output discarded because the reason it refused
# is what each case prints when it does not.
refused=
lint_versions() {
  if RUFF_VERSION="$RUFF_VERSION" YAMLLINT_VERSION="$YAMLLINT_VERSION" \
    sh scripts/lint-versions.sh "$manifest" >/dev/null 2>&1; then
    refused=no
  else
    refused=yes
  fi
}

bad=0
# The pin the lock currently carries, read before anything is perturbed, for the
# reason the case that uses it says. An empty read is refused rather than matched
# against nothing: a sed matching no line edits nothing, lint-versions passes on
# the unchanged tree, and the case would report a refusal it did not cause.
ruff_pin_seen="$(sed -n 's/^ruff==\([^ ]*\).*/\1/p' "$linter_lock")"
test -n "$ruff_pin_seen" || { echo "no ruff pin in $linter_lock, so there is nothing to perturb" >&2; exit 1; }

# The starting state, asked before anything is perturbed: a check that refuses
# every tree including the correct one is not a check.
lint_versions
if [ "$refused" = yes ]; then
  echo "lint-versions refused the tree as it stands, so nothing below says anything" >&2
  exit 1
fi
echo "the tree as it stands: accepted, as it should"

# One case: the gate must go red with $file edited as the rest is.
expect() {
  label="$1"
  file="$2"
  shift 2
  "$@"
  lint_versions
  if [ "$refused" = yes ]; then
    echo "$label: refused, as it should"
  else
    echo "$label: lint-versions passed on a tree it should have refused" >&2
    echo "  $file carries the edit, and the gate did not notice it" >&2
    bad=1
  fi
  restore
}

# Edit a file in place, POSIX sh and POSIX sed on either platform. `sed -i`
# is a GNU extension: BSD sed reads the backup suffix as its first operand, so
# on macOS `sed -i 's/x/y/' file` rewrites the file named `s/x/y/` and reports
# "can't open s/x/y/", leaving `file` untouched and the case below reading a
# tree the perturbation never reached. The rewrite goes through a file in the
# scratch directory and is renamed over the original. The rename takes the
# mode the redirect gave the new file rather than the one the old one had,
# which is why `restore` puts the backup back rather than this being the last
# write: every case ends with the file as the tree found it.
edit_in_place() {
  target="$1"
  shift
  sed "$@" "$target" > "$work/$(basename "$target").edited" || return 1
  mv -f "$work/$(basename "$target").edited" "$target"
}

# The interpreter floors. Each manifest is moved on its own, because a floor
# raised in one and not the other is exactly the drift the loop over both was
# written to catch: with only one manifest read, one of these two cases passes
# the gate, and which one is the question this target exists to answer.
drop_linter_floor() { edit_in_place "$linter_manifest" 's/--python-version 3\.12/--python-version 3.11/'; }
drop_harbor_floor() { edit_in_place "$manifest" 's/--python-version 3\.12/--python-version 3.11/'; }
drop_ruff_target() { edit_in_place "$ruff_config" 's/^target-version = "py312"/target-version = "py311"/'; }
# The fourth record of the same floor: the interpreter setup-linters builds the
# venv the gate runs in. Nothing else in the tree names it, so a bump to the
# three above that missed this line left the gate green on a runner running it
# on an interpreter the linter was not checked against.
drop_venv_floor() { edit_in_place "$linter_action" 's/uv venv --python 3\.12/uv venv --python 3.11/'; }
expect "the linter manifest's interpreter floor" "$linter_manifest" drop_linter_floor
expect "the Harbor manifest's interpreter floor" "$manifest" drop_harbor_floor
expect "ruff.toml's target-version" "$ruff_config" drop_ruff_target
expect "the lint venv's interpreter" "$linter_action" drop_venv_floor

# The version pins, the other thing the script refuses. RUFF_VERSION names the
# version the gate runs and the four places that have to agree with it are the
# Makefile, lint-requirements.in, lint-requirements.txt and ruff.toml, so the file
# the script reads the compiled pin back out of is what moves here.
drop_ruff_pin() { edit_in_place "$linter_lock" "s/^ruff==$ruff_pin_seen/ruff==0.0.1/"; }
expect "the ruff pin in lint-requirements.txt" "$linter_lock" drop_ruff_pin

test "$bad" -eq 0
echo "lint-versions refuses every tree it is asked to refuse, and accepts the one it should"
