#!/bin/sh
# The shell in a GitHub Actions workflow is the one place a defect is published
# rather than reported: a step that does what it means is what gates a release
# and what writes its assets, and a typo in one is a red or a green run nobody
# reads. None of it is a tracked .sh file, so `make lint-shell` never sees it.
#
# This reads the `run:` bodies out of the workflows and the composite actions
# and runs shellcheck over them with the same options `make lint-shell` runs
# over the scripts, so the two gates cannot drift into checking different
# things. Both body forms are covered, because both are shell: the block
# scalars in the release and setup steps, and the one-line `run: make ...`
# steps, which is where a `${{ ... }}` expression or an unbalanced quote is
# easiest to leave behind.
#
# A body is written to a temporary file so the checker can be given a path at
# all, and a manifest records where each of those files came from, because the
# report names a temporary path and a temporary line and neither is something
# an author can act on. It is rewritten back to the workflow and the line the
# line is on before it is printed.
#
# Every disable in a body has to be preceded by a `# because:` line saying what
# it silences, the same rule `make lint-shell` enforces in the scripts: a
# reason written beside the scripts does not travel with a step copied out of
# them.
#
# Usage: lint-ci-shell.sh <workflow.yaml> [workflow.yaml ...]
set -eu

# The options are read from the environment rather than from the argument list
# so the Makefile's SHELLCHECK_OPTS reaches them whole, and the file list stays
# a plain list of paths.
: "${SHELLCHECK_OPTS:=-x}"
: "${1:?usage: lint-ci-shell.sh <yaml> [yaml ...]}"

# The variables the Actions runner exports into every step. A `run:` body has
# no assignment for any of them for a checker to find, so SC2154 reads each as
# a typo of a variable the step never meant. They are declared, one no-op
# default per name, at the top of every extracted body: a name outside this
# list is still reported, which is the half of the rule that catches a typo.
RUNNER_VARS="CI GITHUB_ACTION GITHUB_ACTION_PATH GITHUB_ACTION_REPOSITORY
GITHUB_ACTIONS GITHUB_ACTOR GITHUB_ACTOR_ID GITHUB_API_URL GITHUB_BASE_REF
GITHUB_ENV GITHUB_EVENT_NAME GITHUB_EVENT_PATH GITHUB_GRAPHQL_URL
GITHUB_HEAD_REF GITHUB_JOB GITHUB_OUTPUT GITHUB_PATH GITHUB_REF
GITHUB_REF_NAME GITHUB_REF_PROTECTED GITHUB_REF_TYPE GITHUB_REPOSITORY
GITHUB_REPOSITORY_ID GITHUB_REPOSITORY_OWNER GITHUB_REPOSITORY_OWNER_ID
GITHUB_RETENTION_DAYS GITHUB_RUN_ATTEMPT GITHUB_RUN_ID GITHUB_RUN_NUMBER
GITHUB_SERVER_URL GITHUB_SHA GITHUB_STEP_SUMMARY GITHUB_TRIGGERING_ACTOR
GITHUB_WORKFLOW GITHUB_WORKFLOW_REF GITHUB_WORKFLOW_SHA GITHUB_WORKSPACE
RUNNER_ARCH RUNNER_DEBUG RUNNER_NAME RUNNER_OS RUNNER_TEMP RUNNER_TOOL_CACHE"
# because: the single quotes are the point, the prelude is the literal text a
# checked body starts with, and the split is the point, one word per name
# shellcheck disable=SC2016,SC2086
prelude="$(printf ': "${%s:=}"\n' $RUNNER_VARS)"
# The lines every extracted file spends before its first line of body: the
# shell declaration and the prelude. The report is translated back to the
# workflow by adding this to the number shellcheck prints, so it has to be the
# same number the extractor wrote.
prelude_lines="$(printf '%s\n' "$prelude" | wc -l | tr -d ' ')"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Every file gets a number of its own rather than a name of its own, so the
# blocks of one workflow cannot overwrite another's and a manifest row is keyed
# by something with no dot in it to misparse.
: > "$tmp/manifest"
index=0
for yaml in "$@"; do
  test -f "$yaml" || { echo "no $yaml" >&2; exit 1; }
  index="$((index + 1))"
  awk -v dir="$tmp" -v src="$yaml" -v first="$index" -v prelude="$prelude" -v head="$((prelude_lines + 1))" '
    function emit(start) {
      n = first - 1 + (++blocks);
      out = sprintf("%s/%06d.sh", dir, n);
      printf "# shellcheck shell=bash\n%s", prelude > out;
      # The line a body line has to be shifted by to name the workflow line it
      # came from: the key line it follows, less the lines the file spends
      # above that.
      printf "%06d\t%s\t%d\n", n, src, start - head > (dir "/manifest");
    }
    # A one-line body: the value after `run: ` with no block indicator.
    /^[[:space:]]*(- )?run: [^|>[:space:]]/ {
      body = $0;
      sub(/^[[:space:]]*(- )?run: /, "", body);
      emit(FNR);
      gsub(/\$\{\{[^}]*\}\}/, "github_expr", body);
      print body > out;
      close(out);
      next;
    }
    # A block scalar. Its body is every following line indented past the key,
    # which is what a YAML block is, and stops at the first line that is not.
    /^[[:space:]]*(- )?run: [|>][[:space:]]*(-?[0-9]*|[-+]?[[:space:]]*#.*)?[[:space:]]*$/ {
      prefix = match($0, /[^ ]/) - 1;
      emit(FNR);
      inblock = 1;
      started = 0;
      next;
    }
    inblock {
      line = $0;
      indent = match(line, /[^ ]/) - 1;
      if (line !~ /^[[:space:]]*$/ && indent <= prefix) {
        inblock = 0;
        next;
      }
      if (!started) {
        if (line ~ /^[[:space:]]*$/) next;
        strip = indent;
        started = 1;
      }
      if (line ~ /^[[:space:]]*$/) { print "" > out; next; }
      print substr(line, strip + 1) > out;
      next;
    }
    { inblock = 0 }
  ' "$yaml"
done

# A workflow with no `run:` step is not an error: dependabot.yml is a schedule.
# A tree with no shell at all is, because then the extraction is broken and the
# gate would pass on having checked nothing.
test -s "$tmp/manifest" || { echo "no run: body was extracted, so the workflows carry no shell to check" >&2; exit 1; }

# The reason rule, over the extracted bodies rather than the scripts.
awk -F'\t' '
  FNR == NR { where[$1] = $2; shift_of[$1] = $3; next }
  function why(line,   words) { sub(/^[[:space:]]+/, "", line); return split(line, words, /[[:space:]]+/) >= 3 && words[1] == "#" && words[2] == "because:" && length(words[3]) > 0 }
  function origin(   name) {
    name = FILENAME;
    sub("^.*/", "", name);
    sub("[.]sh$", "", name);
    return where[name];
  }
  /^[[:space:]]*#[[:space:]]*shellcheck[= ]disable=/ { if (!marked) print origin() ": " $0; next }
  /^[[:space:]]*#/ { if (why($0)) marked = 1; next }
  { marked = 0 }
' "$tmp/manifest" "$tmp"/*.sh > "$tmp/reasons"
if [ -s "$tmp/reasons" ]; then
  cat "$tmp/reasons" >&2
  echo "every shellcheck disable in a workflow run: body is preceded by a '# because:' line saying what it silences:" >&2
  exit 1
fi

# The whole set goes in one invocation so one report covers every body, and
# `-s bash` because a `run:` body carries no shebang of its own: the step's
# `shell:` key, or its bash default, is what the runner hands to /bin/bash.
# The status is held because the report still has to be translated and printed
# when there are findings, and a script that stopped at the checker would show
# a temp path and no line an author can act on.
status=0
# because: the options arrive as one Makefile variable and shellcheck takes
# them as separate words, so the split is the point
# shellcheck disable=SC2086
shellcheck $SHELLCHECK_OPTS -s bash "$tmp"/*.sh > "$tmp/report" || status=$?

# The report, named back to the workflow it came from: shellcheck opens each
# finding with `In <file> line <n>:`, and both halves are a temporary path and
# a line counted from a header this script wrote.
awk -v base="$tmp/" '
  FNR == NR { shift_of[$1] = $3; where[$1] = $2; next }
  /^In / {
    name = $0;
    sub("^In " base, "", name);
    sub(" line [0-9]+:$", "", name);
    sub("[.]sh$", "", name);
    line = $0;
    sub("^.* line ", "", line);
    sub(":$", "", line);
    if (name in shift_of) {
      printf "In %s line %d:\n", where[name], line + shift_of[name];
      next;
    }
    print $0;
    next;
  }
  { print }
' "$tmp/manifest" "$tmp/report"

rm -rf "$tmp"
trap - EXIT
exit "$status"
