#!/bin/sh
# The Harbor adapter is the one dependency set here with a manifest and a lock
# that no other check compares. requirements.txt is one pin; requirements.lock
# is uv's output from it. A lock left behind from an earlier pin still installs,
# still hashes every artifact, and still runs the adapter, so the Harbor release
# a score in docs/benchmark.md was measured against stops being the one the pin
# names and nothing fails until a number is quietly incomparable. The lock is
# generated, so it is read here and never written: the three checks are that
# every pin in the manifest is in the lock at the same version, that no lock
# entry arrives without a hash, which is what an artifact installed unverified
# would be, and that every lock entry is reachable from a manifest pin, so a
# lock carrying a package no requirement asks for is refused rather than
# installed into the venv a score is measured in. Regenerating is the
# `uv pip compile` at the top of requirements.txt.
#
# The manifest path arrives as an argument so the Makefile stays the one place
# the Harbor directory is written down.
set -eu

: "${1:?usage: lint-lock.sh <path to requirements.txt>}"

manifest="$1"
lock="$(dirname "$manifest")/requirements.lock"
for file in "$manifest" "$lock"; do
  test -f "$file" || { echo "no $file, so the Harbor adapter's dependency set is undeclared" >&2; exit 1; }
done
bad=0
pins="$(sed -n 's/^\([A-Za-z0-9_.-]*==[^ ]*\).*/\1/p' "$manifest")"
test -n "$pins" || { echo "$manifest pins no package, so the adapter's dependency set is undeclared" >&2; exit 1; }
# A here-document rather than a pipe: a pipe would run the loop in a subshell
# and throw away the bad=1 it sets.
while read -r pin; do
  grep -q "^$pin " "$lock" || {
    echo "$manifest pins $pin, which $lock does not: the lock is older than the pin, so a benchmark would run against a Harbor the manifest no longer names" >&2;
    echo "regenerate it with the 'uv pip compile' at the top of $manifest" >&2;
    bad=1;
  }
done <<EOF
$pins
EOF
grep -q -- '-r integrations/harbor/requirements.txt' "$lock" || {
  echo "$lock records no root from $manifest, so it was not generated from it" >&2;
  bad=1;
};
unhashed="$(awk '/^[A-Za-z0-9_.-]+==/ { if (name != "" && hashes == 0) print name; name = $1; sub(/==.*/, "", name); hashes = 0; next } /--hash=sha256:/ { hashes++ } END { if (name != "" && hashes == 0) print name }' "$lock")"
if [ -n "$unhashed" ]; then
  echo "$lock has entries with no --hash=sha256, which uv installs without verifying them:" >&2;
  echo "$unhashed" >&2;
  bad=1;
fi
roots="$(printf '%s\n' "$pins" | sed 's/==.*//' | tr '\n' ' ')"
orphans="$(awk -v roots="$roots" 'function norm(s) { s = tolower(s); gsub(/[._]/, "-", s); return s } /^[A-Za-z0-9_.-]+==/ { name = $0; sub(/[[:space:]].*/, "", name); sub(/==.*/, "", name); cur = norm(name); names[cur] = 1; seq[++n] = cur; multi = 0; next } /^[[:space:]]*# via[[:space:]]*$/ { multi = 1; next } /^[[:space:]]*# via[[:space:]]+/ { multi = 0; for (i = 2; i <= NF; i++) if ($i != "-r") parents[cur] = parents[cur] " " norm($i); next } /^[[:space:]]*#   [^ ]/ { if (multi) for (i = 1; i <= NF; i++) parents[cur] = parents[cur] " " norm($i); next } END { nr = split(roots, r, " "); for (i = 1; i <= nr; i++) if (r[i] in names) { seen[r[i]] = 1; queue[++m] = r[i] } for (i = 1; i <= n; i++) { c = seq[i]; k = split(parents[c], p, " "); for (j = 1; j <= k; j++) if (p[j] != "" && (p[j] in names)) rev[p[j]] = rev[p[j]] " " c } for (idx = 1; idx <= m; idx++) { c = queue[idx]; k = split(rev[c], ch, " "); for (j = 1; j <= k; j++) if (ch[j] != "" && !(ch[j] in seen)) { seen[ch[j]] = 1; queue[++m] = ch[j] } } for (i = 1; i <= n; i++) if (!(seq[i] in seen)) print seq[i] }' "$lock")"
if [ -n "$orphans" ]; then
  echo "$lock carries packages no pin in $manifest needs, which uv installs into the venv anyway:" >&2;
  echo "$orphans" >&2;
  bad=1;
fi
test "$bad" -eq 0
