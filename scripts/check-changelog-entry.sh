#!/bin/sh
# CONTRIBUTING.md says every change that lands gets a CHANGELOG.md entry under
# [Unreleased], and nothing asked. `check-unreleased` reads the shape of the
# entry that is there: the five headings, once each, in order. A tree whose
# sources moved and whose changelog did not still passes it, because an empty
# [Unreleased] section is a well-formed one, and the requirement was discovered
# by a reviewer rather than by the command the contributor ran.
#
# The question is whether this tree differs from its base in a file a release
# note describes, and whether [Unreleased] holds an entry for it. The base is
# the upstream of the branch, which is where a pull request is reviewed from,
# and HEAD when there is no upstream to ask: a checkout of the default branch
# is its own base, so the check passes there without an entry that describes
# nothing. A change to the changelog itself, to the prose, or to the review
# notes is not a change a release note describes, and is not what this refuses.
#
# Usage: check-changelog-entry.sh
set -eu

# because: CDPATH= is a per-command environment prefix, not an assignment
# shellcheck disable=SC1007
root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$root"

upstream="$(git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || true)"
if [ -n "$upstream" ]; then
	base="$(git merge-base HEAD "$upstream")"
else
	base="$(git rev-parse HEAD)"
fi

# The files a release note describes. CHANGELOG.md is excluded because it is the
# answer, and the prose and the review notes describe the tree rather than a
# behavior a consumer meets. What is left is the program, the build, the gates
# and the workflows.
changed="$(git diff --name-only "$base" -- \
	src build.zig build.zig.zon Makefile scripts bench integrations .github \
	ruff.toml .yamllint lint-requirements.in lint-requirements.txt)"

if [ -z "$changed" ]; then
	exit 0
fi

# A bullet is the entry. A heading with nothing under it is the shape
# `check-unreleased` already accepts, and it is exactly the tree this refuses:
# the section was edited and still describes no change.
entry="$(awk '
	index($0, "## [Unreleased]") == 1 { inside = 1; next }
	/^## / { inside = 0 }
	inside && /^- / { print "entry"; exit }
' CHANGELOG.md)"

if [ -z "$entry" ]; then
	echo "this tree changes files a release note describes, and CHANGELOG.md has no entry under [Unreleased]:" >&2
	printf '%s\n' "$changed" >&2
	echo "CONTRIBUTING.md asks for one in the Keep a Changelog sections already in use; a change that describes nothing a consumer meets is the exception, and it says so in the pull request" >&2
	exit 1
fi
