#!/bin/sh
# Both dependency sets here are a manifest and the lock uv compiles from it, and
# both answer the same three questions. A lock left behind from an earlier pin
# still installs, still hashes every artifact, and still runs, so the release a
# benchmark or a gate was measured against stops being the one the manifest
# names and nothing fails until a number is quietly incomparable. A lock is
# generated, so it is read here and never written: the three checks are that
# every pin in the manifest is in the lock at the same version, that no lock
# entry arrives without a valid SHA-256 hash, which is what an artifact installed unverified
# would be, and that every lock entry is reachable from a manifest pin, so a
# lock carrying a package no requirement asks for is refused rather than
# installed into the venv a score or a gate is run in. Regenerating is the
# `uv pip compile` at the top of each manifest.
#
# The Harbor set is a lock nothing else in the tree regenerates, and the linter
# set is the one a contributor can hand-edit: it lives at the root rather than
# in a directory, and a linter bump that needs a package `uv` would not choose
# is a line typed into a file that looks generated. CI installs that file with
# `--require-hashes`, which refuses an unhashed entry there and nowhere else, so
# a laptop running `make check` is the run that catches a hand edit. Same
# questions, same answers, one script.
#
# Both paths arrive as arguments so the Makefile stays the one place each
# dependency set is written down, and so the Harbor directory is spelled once.
set -eu

: "${1:?usage: lint-lock.sh <manifest> <lock>}"
: "${2:?usage: lint-lock.sh <manifest> <lock>}"

manifest="$1"
lock="$2"
for file in "$manifest" "$lock"; do
  test -f "$file" || { echo "no $file, so this dependency set is undeclared" >&2; exit 1; }
done
bad=0
pins="$(sed -n 's/^\([A-Za-z0-9_.-]*==[^ ]*\).*/\1/p' "$manifest")"
test -n "$pins" || { echo "$manifest pins no package, so this dependency set is undeclared" >&2; exit 1; }
# A here-document rather than a pipe: a pipe would run the loop in a subshell
# and throw away the bad=1 it sets.
while read -r pin; do
  awk -v pin="$pin" '
    function norm(s) { s = tolower(s); gsub(/[-._]+/, "-", s); return s }
    BEGIN { split(pin, wanted, "==") }
    split($1, actual, "==") == 2 && norm(actual[1]) == norm(wanted[1]) && actual[2] == wanted[2] { found = 1 }
    END { exit !found }
  ' "$lock" || {
    echo "$manifest pins $pin, which $lock does not: the lock is older than the pin, so a run installs a release the manifest no longer names" >&2;
    echo "regenerate it with the 'uv pip compile' at the top of $manifest" >&2;
    bad=1;
  }
done <<EOF
$pins
EOF
awk -v manifest="$manifest" '
  /^[[:space:]]*#/ {
    line = $0; sub(/^[[:space:]]*#[[:space:]]*/, "", line); sub(/^via[[:space:]]+/, "", line);
    if (line == "-r " manifest) found = 1;
  }
  END { exit !found }
' "$lock" || {
  echo "$lock records no root from $manifest, so it was not generated from it" >&2;
  bad=1;
};
unverified="$(awk '
  function finish() { if (name != "" && (hashes == 0 || malformed)) print name }
  /^[A-Za-z0-9_.-]+==/ { finish(); name = $1; sub(/==.*/, "", name); hashes = 0; malformed = 0 }
  /--hash=/ {
    for (i = 1; i <= NF; i++) if ($i ~ /^--hash=/) {
      digest = $i; sub(/^--hash=sha256:/, "", digest);
      if ($i !~ /^--hash=sha256:/ || length(digest) != 64 || digest ~ /[^0-9a-fA-F]/) malformed = 1;
      else hashes++;
    }
  }
  END { finish() }
' "$lock")"
if [ -n "$unverified" ]; then
  echo "$lock has entries with missing or malformed --hash=sha256 digests:" >&2;
  echo "$unverified" >&2;
  bad=1;
fi
roots="$(printf '%s\n' "$pins" | sed 's/==.*//' | tr '\n' ' ')"
orphans="$(awk -v roots="$roots" 'function norm(s) { s = tolower(s); gsub(/[-._]+/, "-", s); return s } /^[A-Za-z0-9_.-]+==/ { name = $0; sub(/[[:space:]].*/, "", name); sub(/==.*/, "", name); cur = norm(name); names[cur] = 1; seq[++n] = cur; multi = 0; next } /^[[:space:]]*# via[[:space:]]*$/ { multi = 1; next } /^[[:space:]]*# via[[:space:]]+/ { multi = 0; for (i = 2; i <= NF; i++) if ($i != "-r") parents[cur] = parents[cur] " " norm($i); next } /^[[:space:]]*#   [^ ]/ { if (multi) for (i = 1; i <= NF; i++) parents[cur] = parents[cur] " " norm($i); next } END { nr = split(roots, r, " "); for (i = 1; i <= nr; i++) { r[i] = norm(r[i]); if (r[i] in names) { seen[r[i]] = 1; queue[++m] = r[i] } } for (i = 1; i <= n; i++) { c = seq[i]; k = split(parents[c], p, " "); for (j = 1; j <= k; j++) if (p[j] != "" && (p[j] in names)) rev[p[j]] = rev[p[j]] " " c } for (idx = 1; idx <= m; idx++) { c = queue[idx]; k = split(rev[c], ch, " "); for (j = 1; j <= k; j++) if (ch[j] != "" && !(ch[j] in seen)) { seen[ch[j]] = 1; queue[++m] = ch[j] } } for (i = 1; i <= n; i++) if (!(seq[i] in seen)) print seq[i] }' "$lock")"
if [ -n "$orphans" ]; then
  echo "$lock carries packages no pin in $manifest needs, which uv installs into the venv anyway:" >&2;
  echo "$orphans" >&2;
  bad=1;
fi
test "$bad" -eq 0
