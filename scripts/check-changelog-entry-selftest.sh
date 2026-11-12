#!/bin/sh
# That check-changelog-entry.sh refuses a source change with no [Unreleased]
# entry, and accepts one that has one, asked over a synthetic repository rather
# than over this tree.
#
# The script under test reads `git diff` against the upstream of the branch, so
# the only way to know what it refuses is to hand it a repository whose upstream
# and working tree are both known. Perturbing this checkout would mean editing a
# tracked file and restoring it afterwards, and an interrupted run would leave
# the tree holding the perturbation. The repository here is created under a
# temporary directory the trap removes, with its own git identity, so nothing
# about the checkout this runs in decides the answer.
#
# The cases are the four the gate can give a wrong answer to: a source change
# with no entry, the same change with an entry, a change to prose alone, and a
# checkout of the base itself. Each one is the whole of what the script reads,
# so a later edit that keeps the passing path and drops a failing one goes red
# here rather than in a review.
set -eu

# because: CDPATH= is a per-command environment prefix, not an assignment
# shellcheck disable=SC1007
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
gate="$repo/scripts/check-changelog-entry.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT INT TERM

fail() { echo "check-changelog-entry-selftest: $1" >&2; exit 1; }

git -C "$work" init -q
git -C "$work" config user.email a@b.c
git -C "$work" config user.name test
git -C "$work" config commit.gpgsign false
mkdir -p "$work/src" "$work/scripts"
printf 'const x = 1;\n' >"$work/src/main.zig"
printf '# Changelog\n\n## [Unreleased]\n\n## [0.1.0]\n\n- the first\n' >"$work/CHANGELOG.md"
cp "$gate" "$work/scripts/check-changelog-entry.sh"
git -C "$work" add -A
git -C "$work" commit -qm base

# The upstream the gate asks for. A branch with none falls back to HEAD, which
# is the case this is not testing.
git -C "$work" checkout -q -b trunk
git -C "$work" checkout -q -b topic
git -C "$work" branch --set-upstream-to=trunk

run() { sh "$work/scripts/check-changelog-entry.sh" 2>&1 || true; }

# 1. a checkout of the base changes nothing, so it passes with no entry.
out="$(run)"
if [ -n "$out" ]; then
	fail "a tree that matches its base was refused: $out"
fi

# 2. a source change with no entry is the case the gate exists for.
printf 'const x = 2;\n' >"$work/src/main.zig"
out="$(run)"
printf '%s' "$out" | grep -q 'no entry under \[Unreleased\]' ||
	fail "a source change with no changelog entry was not refused: $out"
printf '%s' "$out" | grep -q 'src/main.zig' ||
	fail "the refusal did not name the file that changed: $out"

# 3. the same change with an entry passes.
printf '# Changelog\n\n## [Unreleased]\n\n### Fixed\n\n- the value\n\n## [0.1.0]\n\n- the first\n' >"$work/CHANGELOG.md"
out="$(run)"
if [ -n "$out" ]; then
	fail "a source change that has an entry was refused: $out"
fi

# 4. prose alone is not a change a release note describes.
git -C "$work" checkout -q -- src CHANGELOG.md
printf 'the notes\n' >"$work/README.md"
out="$(run)"
if [ -n "$out" ]; then
	fail "a change to prose alone was refused: $out"
fi

echo "check-changelog-entry-selftest: 4 cases passed"
