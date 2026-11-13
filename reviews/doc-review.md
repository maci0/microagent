Summary: commands, paths, links, pins and workflow claims

# Documentation accuracy

Your goal is to check commands, paths, links, pins and workflow claims in the README, contributor guide,
usage and performance guides, man page, and config template.

Read and follow the [shared review protocol](README.md#review-protocol) in
`reviews/README.md` before starting. This file is a
reusable checklist, not a review report.

## Scope and priorities

Correct the documentation when it disagrees with the implementation. Report missing
capabilities separately; do not add Makefile targets or change runtime behavior to
satisfy prose. Contract details, measurements and security claims belong to the
specialist checklists linked in the [review guide](README.md).

Prioritize unusable commands, broken paths and links, incorrect gate or release
claims, then stale pins and wording.

## Checklist

1. **Make commands.** Check every documented target against Makefile rules and
   `.PHONY`, including rules with prerequisites such as `default: build`. Check
   inline commands and fenced examples; help text alone does not prove a target
   exists. Use `make -n <target>` where needed.
2. **Make help.** Compare the help recipe with the implemented targets and with
   any documentation promising a complete list. Flag missing, obsolete or
   misleading entries.
3. **Paths and setup commands.** Check named files, install destinations, options
   and regeneration commands against their owning files. Include the config
   template's header and precedence claims. Read install commands without
   executing them; do not install dependencies or run benchmarks.
4. **Links.** Resolve relative Markdown links and heading fragments throughout
   the repository. A linked file must exist in the tree or be added by the same
   change, and fragments must match rendered heading slugs, including
   duplicate-heading suffixes.
   Report external links that could not be verified.
5. **Local and CI gates.** Compare the documented `make check` sequence with its
   recipe, then compare the CI jobs and their documented exceptions. Verify
   compiler requirements, platform coverage, asset smoke tests and separate
   release/reproducibility checks. Also check `make clean` and `make musl`
   against their documented effects.
6. **Tool pins.** Check any versions printed in setup instructions against
   Makefile constants, Python manifests and locks, and CI installation steps.
   `lint-versions` and `lint-lock` check declared inputs, not prose; avoid adding
   another version copy when a link to the owning file suffices.
7. **Release claims.** Compare published targets and asset names with
   `RELEASE_TARGETS`, and documented tag, version, changelog, checksum and
   reproducibility rules with the release workflow and its Makefile targets.
   Check packaging paths, permissions and required external executables too.
8. **Man page and examples.** Check `docs/microagent.1` paths, file-creation
   conditions, examples and references against the binary. `check-man` verifies
   the version and presence of help flags; it does not validate every statement.
   Read the unit tests before claiming other sections are unchecked. Trace stdout
   claims separately for normal runs, REPL, ACP, setup, schema and update;
   contract details belong to the CLI review.
