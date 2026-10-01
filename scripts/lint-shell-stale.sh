#!/bin/sh
# Every shellcheck directive that silences nothing, named and refused.
#
# A directive silencing nothing is not a suppression, it is a comment shaped
# like one. It hides no finding today, because the finding it names is gone,
# and the `# because:` line above it reads to the next person as an answer to a
# question nobody is asking any more. The worse case is a directive left behind
# by the fix for the finding it silenced: that fix cannot come back on its own,
# so the directive outlives it, and a later edit that reintroduces the class is
# silenced by a line whose own reason says the code here is safe.
#
# Two were carrying exactly that in release.yml, and the step they sat in is
# why the rule is worth having: it runs `set -o pipefail`, which shellcheck
# reads itself, so SC2312 was never raised and both directives silenced
# nothing. Nothing about that step depended on them. A step that later dropped
# pipefail would have had its masked return value silenced by a directive whose
# reason said pipefail was what made it safe there.
#
# The question is asked by stripping every directive and running the checker
# over the tree again: a code the stripped tree never raises is what a directive
# naming it is silencing nothing over. One run answers it for the whole tree,
# which is what makes it cheap enough to be permanent. The answer it gives is
# "this check fires nowhere in these files", not "this check fires nowhere in
# this one file", so a check that fires elsewhere keeps its directives
# everywhere. That is the coarse side of the question, and it is the side that
# errs towards reporting nothing, which is the side a gate should err on when
# what it reports is a suppression rather than a defect.
#
# ruff answers the same question for the Python in this tree itself, through
# RUF100, which is why this script is only ever handed shell.
#
# SHELLCHECK_OPTS arrives the way the Makefile passes it, so the run that asks
# the question is the run the gate makes: a different option list would ask a
# different question of every check it did not enable and answer it wrongly.
#
# A first argument of `-s NAME` sets the shellcheck dialect and is not a file,
# which is how lint-ci-shell.sh hands over the `run:` bodies it extracted: those
# carry no shebang, so the dialect is the step's own `shell:` key, and the same
# option the checker there is given is the one the question is asked under.
#
# Usage: lint-shell-stale.sh [-s NAME] <file.sh> [file.sh ...]
set -eu

: "${SHELLCHECK_OPTS:?SHELLCHECK_OPTS is required}"

dialect=
if [ "${1:-}" = -s ]; then
  dialect="-s $2"
  shift 2
fi

: "${1:?usage: lint-shell-stale.sh [-s NAME] <file.sh> [file.sh ...]}"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# The sources are copied with every directive line gone, under their own paths,
# so the run sees the same file names: a script that sources another is
# resolved by path, and a set flattened into one directory would check each file
# as though it were the only one. Every directive in this tree is a whole line,
# and one trailing a command the line still needs is not a directive at all.
for file in "$@"; do
  mkdir -p "$tmp/$(dirname "$file")"
  sed '/^[[:space:]]*#[[:space:]]*shellcheck[= ]disable=/d' "$file" > "$tmp/$file"
done

# The checks the tree raises with nothing silenced. The status is dropped on
# purpose: the question is which checks fire, not whether the tree is clean,
# and the gate itself is what decides that over the undirectived originals.
find "$tmp" -type f -name '*.sh' | sort > "$tmp/copies"
# because: the options arrive as one Makefile variable and shellcheck takes
# them as separate words, so the split is the point, and the copied paths have
# to arrive as separate words for the same reason
# shellcheck disable=SC2086,SC2046
shellcheck $SHELLCHECK_OPTS $dialect -f gcc $(cat "$tmp/copies") > "$tmp/report" 2>/dev/null || true
: > "$tmp/raised"
grep -o 'SC[0-9][0-9]*' "$tmp/report" | sort -u > "$tmp/raised" || true

stale=0
for file in "$@"; do
  awk -v raised="$tmp/raised" '
    function fires(code,   line, found) {
      while ((getline line < raised) > 0) if (line == code) { found = 1; break }
      close(raised)
      return found
    }
    /^[[:space:]]*#[[:space:]]*shellcheck[= ]disable=/ {
      line = $0
      sub(/^[[:space:]]*#[[:space:]]*shellcheck[= ]disable=/, "", line)
      gsub(/[[:space:]]/, "", line)
      n = split(line, codes, ",")
      for (i = 1; i <= n; i++)
        if (codes[i] != "" && !fires(codes[i])) {
          printf "%s:%d: %s silences nothing: shellcheck raises no %s anywhere over this tree, so the directive hides no finding and covers one only if it comes back\n", FILENAME, FNR, codes[i], codes[i]
          stale = 1
        }
    }
    END { exit stale ? 1 : 0 }
  ' "$file" || stale=1
done

test "$stale" -eq 0