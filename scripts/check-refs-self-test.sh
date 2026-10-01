#!/bin/sh
# check-refs.sh's own behaviour, pinned.
#
# The gate reads a citation out of prose, so the two ways it used to read that
# prose wrongly are silent when they regress. A qualified symbol was not read as
# a pair at all, and a bare citation landing on a line with no code on it was
# accepted. Both let a control name a line that is not the code it claims, and
# the real citation list passed while a third of its entries had drifted onto
# comments: the gate agreed with the drift. Running the gate over docs/ alone
# would have reported green then, because the gate is the thing that was wrong.
#
# Each case asserts a finding and a non-finding against the real tree, so the
# expectation is about the gate's reading and not about a fixture that would
# have to be kept in step with the sources. The symbols are real and are the
# ones the threat model cites, so a rename shows up here as a failure rather
# than as a gate that quietly stops matching.
set -eu

# because: CDPATH= is a per-command environment prefix, not an assignment
# shellcheck disable=SC1007
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
gate="$repo/scripts/check-refs.sh"
tmp="$repo/.check-refs-self-test.$$"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp"

fail() { echo "check-refs-self-test: $1" >&2; exit 1; }
run() { sh "$gate" "$1" 2>&1 || true; }
line_of() { grep -n "$1" "$repo/$2" | head -1 | cut -d: -f1; }

alpha_at="$(line_of '^pub fn safeText' src/chat.zig)"
beta_at="$(line_of '^pub const max_tool_output' src/tool.zig)"
[ -n "$alpha_at" ] && [ -n "$beta_at" ] ||
  fail "could not find the symbols this test pins; a rename means these lines need updating"

# 1. a qualified symbol is read as a pair: a wrong line for it is a finding.
#    The threat model writes `config.parse` and `net.urlCarriesKey`, which the
#    gate used to take for a bare citation and never check.
cat > "$tmp/qualified.md" <<EOF
The control lives in \`config.parse\`, \`src/config.zig:1\`, and nowhere else.
EOF
out="$(run "$tmp/qualified.md")"
printf '%s' "$out" | grep -q 'cites parse at src/config.zig:1' ||
  fail "a qualified symbol was not read as a pair, so its line was never checked: $out"

# 2. the repair moves it onto the definition and keeps the qualifier the prose
#    used, so the sentence still reads as it was written
parse_at="$(line_of '^pub fn parse' src/config.zig)"
sh "$gate" -f "$tmp/qualified.md" >/dev/null
moved="$(cat "$tmp/qualified.md")"
grep -q "\`config.parse\`, \`src/config.zig:$parse_at\`" "$tmp/qualified.md" ||
  fail "the repair did not move a qualified citation onto its definition: $moved"

# 3. a bare citation on a line with no code on it is a finding. The line here
#    is a doc comment in the source, which is where a drifted bare citation
#    lands: the control moved and the line stayed, pointing at prose.
doc_line="$(line_of '^/// What a finished .git. call assembles' src/tool.zig)"
cat > "$tmp/bare.md" <<EOF
A control is enforced at \`src/tool.zig:$doc_line\`, which is a comment.
EOF
out="$(run "$tmp/bare.md")"
printf '%s' "$out" | grep -q 'no code on it' ||
  fail "a bare citation on a comment was accepted, which is how a drift hides: $out"

# 4. a bare citation on real code is not a finding, so the check above is not
#    just refusing every bare citation
cat > "$tmp/ok.md" <<EOF
A control is enforced at \`src/tool.zig:$beta_at\`, which is a real definition.
EOF
out="$(run "$tmp/ok.md")"
printf '%s' "$out" | grep -q 'no code on it' &&
  fail "a bare citation on real code was refused: $out"

# 5. a pair that is correct says nothing
cat > "$tmp/good.md" <<EOF
The control lives in \`safeText\`, \`src/chat.zig:$alpha_at\`, and nowhere else.
EOF
out="$(run "$tmp/good.md")"
printf '%s' "$out" | grep -q "$tmp/good.md: cites" &&
  fail "a correct pair was reported as a finding: $out"

echo "check-refs-self-test: 5 cases passed"
