#!/bin/sh
# Check actual workflow and composite-action references, using the same YAML
# parser as lint-ci-shell.sh so quoted refs and shell heredocs are unambiguous.
set -eu
: "${1:?usage: lint-actions.sh <yaml> [yaml ...]}"
python3 - "$@" <<'PYTHON'
import re
import sys
from pathlib import Path

import yaml


def fields(node):
    return {key.value: value for key, value in node.value} if isinstance(node, yaml.MappingNode) else {}


bad = False
for filename in sys.argv[1:]:
    try:
        text = Path(filename).read_text(encoding="utf-8")
        root = fields(yaml.compose(text, Loader=yaml.BaseLoader))
    except (OSError, UnicodeError, yaml.YAMLError) as error:
        sys.exit(f"{filename}: {error}")
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
            comment = text.splitlines()[node.end_mark.line][node.end_mark.column:]
            if re.search(r"#[ \t]*v[ \t]*$", comment):
                message = "uses: version comment names no release"
        if message:
            print(f"{filename}:{node.start_mark.line + 1}: {message}", file=sys.stderr)
            bad = True
sys.exit(int(bad))
PYTHON
