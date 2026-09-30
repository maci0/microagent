#!/bin/sh
# docs/threat-model.md names the function behind every control and cites it as
# `symbol`, `path:line`. The symbol is what a reader searches for; the line is
# what a reader jumps to, and it was written by hand next to a diff that moved
# the function. Nothing asked where it ended up, so a control could cite a line
# a hundred lines above its own body and a reader following the citation would
# be reading the wrong function. 0.2.0 fixed the references that were stale then
# and nothing has asked since.
#
# What is checked is the pair, not the prose: a citation that names a symbol and
# a file has to name the line that symbol is defined on, so a moved function
# fails the gate rather than the reader. A citation with no symbol beside it is
# a line inside a body, which nothing in the file names, so only the file and
# the range are asked, and a line past the end of the file is refused.
#
# The definitions are read from the sources, so a symbol the source no longer
# has is a finding as well: a control citing a function that was deleted is a
# control describing nothing.
#
# Usage: check-refs.sh [-f] <file.md> [file.md ...]
#   -f  rewrite each stale citation to the line its symbol is defined on
set -eu

fix=0
if [ "${1:-}" = "-f" ]; then
  fix=1
  shift
fi

test "${1:-}" != "" || { echo "usage: check-refs.sh [-f] <file.md> [file.md ...]" >&2; exit 1; }

# because: CDPATH= is a per-command environment prefix, not an assignment
# shellcheck disable=SC1007
root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$root"

tmp="$(mktemp)"
trap 'rm -f "$tmp" "$tmp.refs" "$tmp.rewritten"' EXIT
unfixed=0

# Where each function and constant is defined, per file: the line whose last
# word is the name, and which is a declaration rather than a call. A Zig
# declaration opens with `fn name`, `pub fn name`, `const name`, `pub const
# name` or `pub var name`, indented or not, because a declaration inside a
# struct is the same declaration written inside one, and nothing else in the
# tree spells a name that way. So a line is a definition when it matches one of
# those and the name is a word on it.
defs() {
  awk '
    match($0, /^[ \t]*(pub )?(fn|const|var) +[A-Za-z_][A-Za-z0-9_]*/) {
      rest = substr($0, RSTART, RLENGTH)
      if (match(rest, /[A-Za-z_][A-Za-z0-9_]*[ \t]*$/)) {
        name = substr(rest, RSTART, RLENGTH)
        sub(/[ \t]+$/, "", name)
        if (!(name in seen)) print name, FNR
        seen[name] = 1
      }
    }
  ' "$1"
}

for file in "$@"; do
  # Every `path:line` or `path:a-b` in the file, with the symbol in the
  # backticks immediately before it when there is one. The symbol is captured
  # from the same backtick run, so `foo`, `src/a.zig:1` yields the pair and
  # "checked at `src/a.zig:1`" yields the path alone.
  status=0
  # because: the backticks are literal Markdown code spans, not command substitution
  # shellcheck disable=SC2016
  grep -oE '`[A-Za-z_][A-Za-z0-9_]*`, `src/[a-z_]+\.zig:[0-9]+(-[0-9]+)?`|`src/[a-z_]+\.zig:[0-9]+(-[0-9]+)?`' \
    "$file" > "$tmp.refs" || status=$?
  [ "$status" -le 1 ] || exit 1
  while read -r ref; do
    [ -n "$ref" ] || continue
    # because: the single quotes are the point, they carry the literal backtick
    # and bracket of the citation rather than a value from the environment
    # shellcheck disable=SC2016
    if printf '%s' "$ref" | grep -q '`, `'; then
      sym="$(printf '%s' "$ref" | sed 's/^`\([^`]*\)`, `.*/\1/')"
      loc="$(printf '%s' "$ref" | sed 's/^.*`, `\([^`]*\)`$/\1/')"
    else
      sym=""
      loc="$(printf '%s' "$ref" | sed 's/^.*`\([^`]*\)`$/\1/')"
    fi
    path="${loc%%:*}"
    span="${loc#"$path":}"
    want="${span%%-*}"

    if [ ! -f "$path" ]; then
      printf '%s: cites %s, which is not in the tree\n' "$file" "$path" >> "$tmp"
      unfixed=1
      continue
    fi

    if [ -n "$sym" ]; then
      # Read the whole definitions stream so no producer is cut off by SIGPIPE.
      got="$(defs "$path" | awk -v s="$sym" '$1 == s { print $2 }')"
      if [ -z "$got" ]; then
        printf '%s: cites %s, which %s does not define\n' "$file" "$sym" "$path" >> "$tmp"
        unfixed=1
        continue
      fi
      if [ "$got" != "$want" ]; then
        if [ "$fix" = 1 ]; then
          # Write and rename: portable to GNU and BSD sed.
          sed "s|\`$sym\`, \`$path:$span\`|\`$sym\`, \`$path:$got\`|" "$file" > "$tmp.rewritten"
          mv "$tmp.rewritten" "$file"
          printf '%s: moved %s from %s:%s to %s:%s\n' "$file" "$sym" "$path" "$want" "$path" "$got" >> "$tmp"
        else
          printf '%s: cites %s at %s:%s, where it is defined on line %s\n' \
            "$file" "$sym" "$path" "$want" "$got" >> "$tmp"
          unfixed=1
        fi
        continue
      fi
    fi

    lines="$(awk 'END { print NR }' "$path")"
    # Numeric coercion also rejects enormous references without shell integer overflow.
    if ! awk -v first="$want" -v last="${span##*-}" -v lines="$lines" \
      'BEGIN { exit !((first + 0) >= 1 && (last + 0) >= (first + 0) && (last + 0) <= (lines + 0)) }'; then
      printf '%s: cites %s:%s and the file has %s lines\n' "$file" "$path" "$span" "$lines" >> "$tmp"
      unfixed=1
    fi
  done < "$tmp.refs"
  rm -f "$tmp.refs"
done

if [ -s "$tmp" ]; then
  sort -u "$tmp" >&2
  if [ "$fix" = 1 ] && [ "$unfixed" = 0 ]; then
    echo "citations rewritten; run the check again to see what is left" >&2
    exit 0
  fi
  echo "every source citation in the tree is checked against the source:" >&2
  echo "  docs/threat-model.md: cites toolCallLine at src/tool.zig:709, where it is defined on line 698" >&2
  echo "  'make check-refs FIX=1' rewrites each to the line its symbol is on" >&2
  exit 1
fi
