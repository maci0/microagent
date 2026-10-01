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
# fails the gate rather than the reader. The symbol may be written qualified with
# the module it is reached through, as the threat model writes it (`config.parse`,
# `net.urlCarriesKey`); the module is prose and the name after the dot is what the
# source defines. A citation with no symbol beside it is a line inside a body,
# which nothing in the file names, so the file and the range are asked, a line
# past the end of the file is refused, and a line with no code on it is reported:
# a bare citation is only right until something is inserted above it, and where
# the line lands on a comment is how a drifted one shows. Pair it and the pair is
# checked from then on.
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
  # "checked at `src/a.zig:1`" yields the path alone. The symbol may be
  # qualified with the module it is reached through, as the threat model
  # writes it (`config.parse`, `net.urlCarriesKey`, `update.run`): the module
  # is prose and the name after the dot is what the source defines, so the
  # qualifier is dropped before the name is looked up. Without that the
  # qualified citations were read as bare ones and never checked at all, which
  # is how a control came to cite a line a hundred lines above its own body.
  status=0
  # because: the backticks are literal Markdown code spans, not command substitution
  # shellcheck disable=SC2016
  grep -oE '`[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)?`, `src/[a-z_]+\.zig:[0-9]+(-[0-9]+)?`|`src/[a-z_]+\.zig:[0-9]+(-[0-9]+)?`' \
    "$file" > "$tmp.refs" || status=$?
  [ "$status" -le 1 ] || exit 1
  while read -r ref; do
    [ -n "$ref" ] || continue
    # because: the single quotes are the point, they carry the literal backtick
    # and bracket of the citation rather than a value from the environment
    # shellcheck disable=SC2016
    if printf '%s' "$ref" | grep -q '`, `'; then
      sym="$(printf '%s' "$ref" | sed 's/^`\([^`]*\)`, `.*/\1/')"
      # The module qualifier is prose; the source defines the name after the dot.
      sym="${sym##*.}"
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
          # The citation keeps whatever the prose put in front of the name: the
          # lookup dropped the module, the rewrite matches the name as it is
          # written, qualified or not, so a rewrite leaves `config.parse` alone.
          # Write and rename: portable to GNU and BSD sed.
          sed "s|\`\([A-Za-z_][A-Za-z0-9_]*\.\)\?$sym\`, \`$path:$span\`|\`\1$sym\`, \`$path:$got\`|" \
            "$file" > "$tmp.rewritten"
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
      continue
    fi

    # A citation with no symbol beside it is a line inside a body, and a body
    # line is code. The line a reader lands on being a comment or an empty one
    # means the citation drifted: the control it names moved and the line stayed.
    # The pair above cannot see that, because the pair is rewritten by hand next
    # to the diff, while a bare line is only ever right until something is
    # inserted above it. This is a finding rather than a rewrite, because the
    # gate has nothing to move a bare citation to: only the prose knows which
    # function the line belongs to now. Pair the citation and the check covers
    # it from then on.
    if [ -z "$sym" ]; then
      end="${span##*-}"
      body="$(awk -v a="$want" -v b="$end" 'FNR >= a && FNR <= b { print }' "$path" |
        awk 'BEGIN { code = 0 } { line = $0; sub(/^[ \t]+/, "", line); if (line != "" && line !~ /^\/\//) code = 1 } END { print code }')"
      if [ "$body" != 1 ]; then
        # because: the backticks are literal Markdown in the message, not a command substitution
        # shellcheck disable=SC2016
        printf '%s: cites %s:%s, a line with no code on it; name the symbol with it (`sym`, `%s:<line>`) so the pair is checked\n' \
          "$file" "$path" "$span" "$path" >> "$tmp"
        unfixed=1
      fi
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
  echo "source citations are stale or invalid" >&2
  echo "  'make check-refs FIX=1' rewrites each to the line its symbol is on" >&2
  exit 1
fi
