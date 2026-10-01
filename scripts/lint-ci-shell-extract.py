"""Every `run:` body a workflow or composite action carries, as shellcheck sees it.

    lint-ci-shell-extract.py DIRECTORY PRELUDE HEAD [YAML ...]

Writes one `<NNNNNN.NNNNNN>.sh` per body into DIRECTORY and a `manifest` of
where each came from, so the report shellcheck prints over temporary paths and
lines can be rewritten back to the workflow and the line an author can act on.

The scalar is parsed through PyYAML rather than read as text, which is what gives
the checker exactly what Actions runs: YAML quotes, folded lines, chomping
indicators, aliases, and text that resembles a key inside a heredoc.

PRELUDE is the declaration block written at the head of every body, and HEAD is
how many lines that block occupies including the shebang comment, so the
manifest's line shift is the header this script writes rather than any of the
body's own lines.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    sys.exit("lint-ci-shell.sh: Python needs PyYAML; install lint-requirements.txt into a venv on PATH")

# A `${{ ... }}` expression is not shell, and shellcheck reads it as a syntax
# error whatever it says. It is replaced rather than left, because the point of
# the extraction is to check the shell around it, and the replacement keeps one
# `\`+newline per line the expression spanned so a folded expression does not
# move the line a finding is reported on.
# ponytail: the inner quote forms cover the two YAML scalar styles; an
# expression holding a brace inside a string is not covered.
GITHUB_EXPR = re.compile(r"\$\{\{(?:'[^']*'|[^'}])*\}\}")


def fields(node: object) -> dict[str, object]:
    """The keys of a YAML mapping node, or nothing for any other node."""
    if not isinstance(node, yaml.MappingNode):
        return {}
    return {key.value: value for key, value in node.value}


def extract(directory: Path, prelude: str, head: int, filenames: list[str]) -> None:
    with (directory / "manifest").open("w", encoding="utf-8") as manifest:
        for index, filename in enumerate(filenames, 1):
            try:
                root = fields(yaml.compose(Path(filename).read_text(encoding="utf-8"), Loader=yaml.BaseLoader))
            except (OSError, UnicodeError, yaml.YAMLError) as error:
                sys.exit(f"{filename}: {error}")
            owners = [*fields(root.get("jobs")).values(), root.get("runs")]
            count = 0
            for owner in owners:
                steps = fields(owner).get("steps")
                if not isinstance(steps, yaml.SequenceNode):
                    continue
                for step in steps.value:
                    body = fields(step).get("run")
                    if body is None:
                        continue
                    if not isinstance(body, yaml.ScalarNode):
                        sys.exit(f"{filename}:{body.start_mark.line + 1}: run must be a YAML scalar")
                    count += 1
                    name = f"{index:06d}.{count:06d}"
                    value = GITHUB_EXPR.sub(
                        lambda match: "github_expr" + "\\\n" * match.group().count("\n"),
                        body.value,
                    )
                    (directory / f"{name}.sh").write_text(
                        f"# shellcheck shell=bash\n{prelude}\n{value}\n", encoding="utf-8"
                    )
                    base = body.start_mark.line + (2 if body.style in ("|", ">") else 1)
                    # ponytail: folded/quoted scalars map to their start line;
                    # per-character source maps only if precise multiline locations are needed.
                    anchor = 0 if body.style == "|" else base
                    manifest.write(f"{name}\t{filename}\t{base - head}\t{anchor}\n")


def main() -> None:
    if len(sys.argv) < 4:
        sys.exit("usage: lint-ci-shell-extract.py <directory> <prelude> <head> [yaml ...]")
    extract(Path(sys.argv[1]), sys.argv[2], int(sys.argv[3]), sys.argv[4:])


if __name__ == "__main__":
    main()
