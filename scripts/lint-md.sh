#!/bin/sh
# The Markdown is the largest surface in the tree and the only one no linter
# reads: zig fmt has no opinion on a prose file, and ruff, shellcheck and
# yamllint each cover one language that is not this one. Fourteen files carry
# the install command, the configuration surface, the threat model and every
# claim a contributor checks a change against, and a defect in one of them is
# a wrong instruction rather than a red test.
#
# What is checked here is the set of facts a renderer and a diff both care
# about and no reader can see: a hard tab or a trailing space is invisible in
# a paragraph and shows up as a changed line in every edit that touches it, an
# unclosed fence swallows the rest of the file into a code block, and a file
# with no final newline makes the next diff report the last line as changed.
# None of it is a style preference, and none of it is checked anywhere else, so
# this is the whole of the Markdown gate rather than a proxy for one.
#
# The file list is the Makefile's, taken from git, so a Markdown file added
# outside the paths there is checked and a deleted one is not.
#
# Usage: lint-md.sh <file.md> [file.md ...]
set -eu

test "${1:-}" != "" || { echo "usage: lint-md.sh <file.md> [file.md ...]" >&2; exit 1; }

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

# One pass over every file, and one finding per line, so a file with three
# problems is reported three times rather than stopping at the first. A fence
# is a line whose first non-space characters are three backticks; the state it
# toggles is what tells a code block from prose, and a hard tab inside a shell
# transcript is content the author chose while one in a paragraph is a tab stop
# nobody asked for.
awk '
  function say(what) { printf "%s:%d: %s\n", FILENAME, FNR, what }
  function unbalanced(name) { printf "%s: an odd number of ``` lines, so the last fence is never closed and the rest of the file renders as code\n", name }
  # The fence state belongs to one file. Left to run from the file before, an
  # unclosed fence in one file is cancelled by the first fence in the next, and
  # a tree where two files each have one passes with both of them unbalanced:
  # the rest of each file renders as a code block and the gate says nothing.
  # So the file that is ending is named, and the one starting is reset. The
  # last file is the one END still has, and the same line closes it.
  FNR == 1 { if (NR > 1 && infence) unbalanced(name); name = FILENAME; infence = 0; blanks = 0 }
  {
    if (/\r$/) say("a CRLF line ending; .gitattributes writes LF, and git hands a script one that dies on set -u")
    is_fence = $0 ~ /^[[:space:]]*```/
    if (is_fence) {
      infence = !infence
      blanks = 0
    }
    if (!infence || is_fence) {
      if ($0 ~ /[ \t]+$/) say("trailing whitespace; it is invisible in the rendered page and rewrites the line in every diff")
      if (index($0, "\t") > 0) say("a hard tab outside a code fence; use spaces, which is what the rest of the file is")
    }
    if (is_fence) next
    if ($0 ~ /^[[:space:]]*$/) {
      blanks++
      if (blanks > 1) say("two blank lines in a row; one is a paragraph break, two is a paragraph and a half")
    } else {
      blanks = 0
    }
  }
  END {
    if (infence) unbalanced(FILENAME)
  }
' "$@" > "$tmp"

# The last line and the newline after it, which awk cannot see: a file whose
# last line is blank carries a trailing blank line, and one whose last byte is
# not a newline makes every later diff report that line as rewritten.
for file in "$@"; do
  last_byte="$(tail -c 1 "$file")"
  last_line="$(tail -n 1 "$file")"
  if [ -n "$last_byte" ]; then
    printf '%s: no newline at the end of the file; the next diff reports the last line as changed\n' "$file" >> "$tmp"
  fi
  if [ -z "$last_line" ]; then
    printf '%s: a blank line at the end of the file\n' "$file" >> "$tmp"
  fi
done

if [ -s "$tmp" ]; then
  sort "$tmp" >&2
  echo "every markdown file is checked for tabs, trailing whitespace, unclosed fences and a final newline:" >&2
  echo "  README.md:42: trailing whitespace; it is invisible in the rendered page" >&2
  exit 1
fi
