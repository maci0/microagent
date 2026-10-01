#!/bin/sh
# Check actual workflow and composite-action references and the runner
# semantics the workflows depend on, using the same YAML parser as
# lint-ci-shell.sh so quoted refs and shell heredocs are unambiguous.
#
# Two passes over the same documents, both reporting against the file and line
# the reader can act on:
#
#   1. Every `uses:` outside this repository names a full 40-character commit
#      sha with the release it stands for in a trailing comment. A tag lets a
#      new upstream release decide what this repository executes, and the sha
#      is what stops it; the comment is what tells a reader which release the
#      sha is, so a bump is a diff rather than an opaque hash change.
#
#   2. The runner semantics lint-ci-shell.sh cannot see, because they are not
#      in a `run:` body. Each is one a runner enforces or defaults in a way
#      that turns a green run into the wrong work rather than into a red one,
#      so nothing here asks a step to be written a second way:
#
#      - a composite action's `run:` step must name a `shell:`. Actions runs
#        such a step with no default and fails the job with a message about
#        the missing key, so the cost is a failed run rather than a wrong
#        check; this is the one rule with no runner default at all.
#      - every job needs a `timeout-minutes`. Without one a job that hangs runs
#        until the workflow's six-hour ceiling and reports no failure: a stuck
#        install, a wedged test, a network call with no timeout.
#      - every workflow needs `permissions:`. The runner's default is the
#        repository setting, which for a repository created after this one is
#        read/write, so a job that never asks for `contents: read` silently
#        holds a token that can push to a branch. `write-all` and a bare
#        `permissions: write-all` are the same thing written out.
#      - every workflow needs `concurrency:`, because a commit that is pushed
#        and then superseded runs the whole gate again against a checkout that
#        is no longer the branch tip, and the two runs race to report. A group
#        with no `cancel-in-progress` still serializes them, which is the
#        property that matters; whether the older run is cancelled is a policy
#        decision the release workflow deliberately answers the other way,
#        because a cancelled publish leaves a half-written release.
#      - every `actions/checkout` step must set `persist-credentials: false`.
#        The default writes the job's token into `.git/config`, where a later
#        step that runs a build script, a test, or a fetched dependency has it
#        in its environment and in its git remote helpers.
#
# The rules are asked of the workflows and composite actions alike, and a
# document with no `jobs:` (a Dependabot schedule, a composite action) is
# skipped rather than reported against: the checks that need a job list have
# nothing to say about one.
set -eu
: "${1:?usage: lint-actions.sh <yaml> [yaml ...]}"
python3 - "$@" <<'PYTHON'
import re
import sys
from pathlib import Path

import yaml


def fields(node):
    return {key.value: value for key, value in node.value} if isinstance(node, yaml.MappingNode) else {}


def line_of(node):
    """The line a reader acts on: the start of a block scalar, the end of
    whatever the scalar is otherwise. Reported against a job's name, a `uses:`
    or a `permissions:`, so an error names the key rather than the first line
    of a long explanation comment above it."""
    if node is None:
        return 0
    if isinstance(node, yaml.ScalarNode):
        mark = node.start_mark if node.style in ("|", ">") else node.end_mark
        return mark.line + 1
    return node.start_mark.line + 1


def text_of(node):
    """The scalar's own text, or the empty string for a key with no value: a
    `permissions:` that is present but empty names every scope, so it reads
    as a grant rather than as an absence."""
    return node.value.strip() if isinstance(node, yaml.ScalarNode) else ""


bad = False
for filename in sys.argv[1:]:
    try:
        text = Path(filename).read_text(encoding="utf-8")
        document = yaml.compose(text, Loader=yaml.BaseLoader)
    except (OSError, UnicodeError, yaml.YAMLError) as error:
        sys.exit(f"{filename}: {error}")
    root = fields(document)
    owners = [*fields(root.get("jobs")).values(), root.get("runs")]
    refs = [fields(owner).get("uses") for owner in owners]
    for owner in owners:
        steps = fields(owner).get("steps")
        if isinstance(steps, yaml.SequenceNode):
            refs.extend(fields(step).get("uses") for step in steps.value)
    for node in refs:
        if node is None:
            continue
        ref = node.value if isinstance(node, yaml.ScalarNode) else ""
        if ref.startswith("./"):
            continue
        name, separator, pin = ref.rpartition("@")
        message = ""
        if not name or not separator or not re.fullmatch(r"[0-9a-f]{40}", pin):
            message = f"uses: must pin an external action or workflow to a full commit SHA: {ref}"
        else:
            mark = node.start_mark if node.style in ("|", ">") else node.end_mark
            comment = text.splitlines()[mark.line][mark.column:]
            if re.search(r"#[ \t]*v[ \t]*$", comment):
                message = "uses: version comment names no release"
        if message:
            print(f"{filename}:{node.start_mark.line + 1}: {message}", file=sys.stderr)
            bad = True

    # The runner semantics below: workflow documents only. A composite action
    # has no jobs to time out and no token of its own; a Dependabot schedule
    # runs nothing. Both carry `jobs:` absent and are skipped for the workflow
    # rules, while the composite `shell:` rule is asked of them alone.
    composite_runs = root.get("runs")
    if isinstance(composite_runs, yaml.MappingNode):
        steps = fields(composite_runs).get("steps")
        if isinstance(steps, yaml.SequenceNode):
            for step in steps.value:
                step_fields = fields(step)
                if "run" in step_fields and "shell" not in step_fields:
                    print(
                        f"{filename}:{line_of(step_fields['run'])}: "
                        "a composite action's run: step names no shell:, and Actions runs no default "
                        "for one: the job fails with a message about the missing key",
                        file=sys.stderr,
                    )
                    bad = True

    jobs_node = root.get("jobs")
    if not isinstance(jobs_node, yaml.MappingNode):
        continue

    def workflow_message(node, message):
        global bad
        print(f"{filename}:{line_of(node)}: {message}", file=sys.stderr)
        bad = True

    if "concurrency" not in root:
        workflow_message(jobs_node, "the workflow declares no concurrency:, so a superseded push runs this gate again against a checkout that is no longer the branch tip")
    workflow_permissions = root.get("permissions")
    if workflow_permissions is None:
        workflow_message(jobs_node, "the workflow declares no permissions:, so every job holds the repository's default token scope rather than contents: read")
    elif text_of(workflow_permissions) == "write-all":
        workflow_message(workflow_permissions, "permissions: write-all grants every scope; name the ones the workflow needs")

    for job_key, job_node in jobs_node.value:
        job = fields(job_node)
        label = text_of(job_key)
        if "timeout-minutes" not in job:
            workflow_message(job_key, f"job {label} declares no timeout-minutes:, so a step that hangs runs until the workflow's ceiling and reports no failure")
        job_permissions = job.get("permissions")
        if text_of(job_permissions) == "write-all":
            workflow_message(job_permissions, f"job {label} requests permissions: write-all; name the scopes it needs")
        steps = job.get("steps")
        if not isinstance(steps, yaml.SequenceNode):
            continue
        for step in steps.value:
            step_fields = fields(step)
            uses = step_fields.get("uses")
            if not isinstance(uses, yaml.ScalarNode) or not uses.value.startswith("actions/checkout@"):
                continue
            options = step_fields.get("with")
            option_fields = fields(options) if isinstance(options, yaml.MappingNode) else {}
            persisted = option_fields.get("persist-credentials")
            if text_of(persisted).lower() not in ("false", "no", "off"):
                workflow_message(uses, f"job {label} checks out without persist-credentials: false, so the job's token is left in .git/config where a later build or test step can use it")

sys.exit(int(bad))
PYTHON
