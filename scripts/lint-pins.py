"""Check a hashed requirements file against what the tools it pins declare.

The gate installs lint-requirements.txt with --require-hashes, so every package
in it is pinned exactly and verified, and pip resolves nothing at install time.
What that does not say is whether the pins are the right ones: the file is
hand-written, so a yamllint bump can leave a pin nothing imports any more, or a
pin below a bound the new yamllint asks for, and both install cleanly. The
second fails at import inside the lint job, and the first is an unverified
package in the venv a green lint run came from.

This reads the metadata of the installed distributions and asks the two
questions the Harbor lock is asked in scripts/lint-lock.sh: is every pin
something one of the other pins requires, and is every requirement of one of
the other pins in the file. It asks a third that a generated lock cannot be
asked, because nothing generates this file: is each pin high enough for the
bound it is required at. Requirements carrying an extra marker are not part of
a runtime resolution, so they ask for nothing.

Usage: lint-pins.py <requirements file> <root pin>...

A root is a package the gate runs as a command rather than something another
pin pulls in, named on the command line as name==version so the check reads
the version the Makefile pins rather than a second spelling of it.
"""

from __future__ import annotations

import re
import sys
from importlib import metadata
from pathlib import Path

PIN = re.compile(r"^([A-Za-z0-9._-]+)==([^\s\\]+)")
REQUIREMENT_NAME = re.compile(r"^([A-Za-z0-9._-]+)")
LOWER_BOUND = re.compile(r"^>=?\s*([0-9][0-9A-Za-z.]*)")
EXTRA = re.compile(r"extra\s*==")
LEADING_NUMBER = re.compile(r"[0-9]+")


def normalize(name: str) -> str:
    """Fold a distribution name to the form pip compares it by."""
    return re.sub(r"[-_.]+", "-", name).lower()


def release(version: str) -> tuple[int, ...]:
    """Read the dotted numbers at the front of a version, dropping any suffix."""
    numbers: list[int] = []
    for part in version.split("."):
        match = LEADING_NUMBER.match(part)
        if match is None:
            break
        numbers.append(int(match.group()))
    return tuple(numbers)


def read_pins(path: Path) -> dict[str, str]:
    """Every name==version in a requirements file, comments and continuations aside."""
    pins: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        match = PIN.match(line)
        if match is not None:
            pins[normalize(match.group(1))] = match.group(2)
    return pins


def parse_root(pin: str) -> tuple[str, str]:
    """Split a name==version argument, refusing anything that is not one."""
    name, separator, version = pin.partition("==")
    if not separator or not name or not version:
        message = f"{pin} is not a name==version pin, so this check cannot tell which packages it may exempt"
        raise ValueError(message)
    return normalize(name), version


def installed_version(distribution: str) -> str | None:
    """The version of a distribution installed for this interpreter, if any."""
    try:
        return metadata.version(distribution)
    except metadata.PackageNotFoundError:
        return None


def runtime_requirements(distribution: str) -> list[str]:
    """What a distribution needs to run, which is its requirements minus the extras."""
    declared = metadata.requires(distribution) or []
    return [requirement for requirement in declared if EXTRA.search(requirement) is None]


def parsed_requirement(requirement: str) -> tuple[str, str | None] | None:
    """The package name a requirement names and its lower bound, if it has one."""
    specifier = requirement.partition(";")[0].strip()
    name = REQUIREMENT_NAME.match(specifier)
    if name is None:
        return None
    bound = LOWER_BOUND.match(specifier, name.end())
    return normalize(name.group(1)), bound.group(1) if bound is not None else None


def unsatisfied_pins(pins: dict[str, str], declared: dict[str, list[str]]) -> list[str]:
    """Pins that some other pin requires and no pin is high enough to satisfy."""
    problems: list[str] = []
    for parent, requirements in declared.items():
        for requirement in requirements:
            parsed = parsed_requirement(requirement)
            if parsed is None or parsed[1] is None:
                continue
            name, bound = parsed
            pinned = pins.get(name)
            if pinned is not None and release(pinned) < release(bound):
                problems.append(f"{parent} needs {name}>={bound}, and the pin is {pinned}")
    return problems


def required_names(declared: dict[str, list[str]]) -> set[str]:
    """The package names the installed metadata asks for."""
    names: set[str] = set()
    for requirements in declared.values():
        for requirement in requirements:
            parsed = parsed_requirement(requirement)
            if parsed is not None:
                names.add(parsed[0])
    return names


def unrequired_pins(pins: dict[str, str], declared: dict[str, list[str]], roots: set[str]) -> list[str]:
    """Pins no other pin asks for, which is a package nothing imports."""
    required = required_names(declared)
    return [
        f"{name} is pinned and nothing in the file requires it: it installs for nothing to import"
        for name in pins
        if name not in roots and name not in required
    ]


def unlisted_requirements(pins: dict[str, str], declared: dict[str, list[str]]) -> list[str]:
    """Requirements of a pin that the file does not pin, which --require-hashes then refuses."""
    return [
        f"{parent} needs {parsed[0]}, which the file does not pin"
        for parent, requirements in declared.items()
        for parsed in (parsed_requirement(requirement) for requirement in requirements)
        if parsed is not None and parsed[0] not in pins
    ]


def drift_problems(pins: dict[str, str]) -> list[str]:
    """Pins whose installed version is not the pinned one, whose metadata says nothing here."""
    problems: list[str] = []
    for name, pinned in pins.items():
        version = installed_version(name)
        if version is not None and version != pinned:
            problems.append(f"{name} {version} is installed for this interpreter and the file pins {pinned}")
    return problems


def check(requirements: Path, root_pins: list[str]) -> list[str]:
    """Every problem the pins in a requirements file have against the installed metadata."""
    pins = read_pins(requirements)
    if not pins:
        return [f"{requirements} pins no package, so the gate's linter set is undeclared"]
    roots = {name for name, _ in (parse_root(pin) for pin in root_pins)}
    unlisted = [pin for pin in root_pins if parse_root(pin)[0] not in pins]
    if unlisted:
        return [f"{requirements} does not pin {unlisted[0].partition('=')[0]}, so it is not installed here"]
    declared = {
        name: runtime_requirements(name) for name, version in pins.items() if version == installed_version(name)
    }
    if not declared:
        return [
            (
                f"no pin in {requirements} is installed for this interpreter, so none of them can be checked: "
                "run this with the interpreter the linters are installed for"
            )
        ]
    problems = drift_problems(pins)
    problems += unrequired_pins(pins, declared, roots)
    problems += unlisted_requirements(pins, declared)
    problems += unsatisfied_pins(pins, declared)
    return problems


def main(argv: list[str]) -> int:
    """Report every problem there is and fail when there was one."""
    if len(argv) < 3:
        print(f"usage: {Path(argv[0]).name} <requirements file> <root pin>...", file=sys.stderr)
        return 2
    try:
        problems = check(Path(argv[1]), argv[2:])
    except OSError as error:
        print(f"{argv[1]}: {error.strerror or error}, so there is nothing to check", file=sys.stderr)
        return 2
    except ValueError as error:
        print(error, file=sys.stderr)
        return 2
    for problem in problems:
        print(f"{argv[1]}: {problem}", file=sys.stderr)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
