Summary: action pins, permissions, gates and release artifacts

# CI and release workflows

Your goal is to check `.github/workflows/`, `.github/actions/` and `.github/dependabot.yml` for
pinning, permissions, shell failures, release gates and artifact publication.

Read and follow the [shared review protocol](README.md#review-protocol) in
`reviews/README.md` before starting. This file is a
reusable checklist, not a review report.

## Scope and priorities

Edit `.github/` only. Preserve the gate's existing work: report missing gate
steps or broader build coverage rather than adding them during this review.
Replace an inline command with its existing Makefile target when equivalent.
Do not push, tag, publish or invoke remote `gh` operations.

Use file reads, `make -n <target>`, shell syntax checks and installed workflow
linters. Verify runner and action support against official documentation only
when network lookup is authorized; otherwise mark current support unverified.

Prioritize unpinned installs and unsafe token or trigger combinations, bypassed
gates, shell failures and injection, then duplication, caches and comment drift.

## Checklist

1. **An action or toolchain fetched by anything but a full commit sha.** Every external
   `uses:` in the workflows and in the actions under `.github/actions/` must name a
   40-character hex sha with the release it stands for in a trailing comment, because a
   mutable tag lets a new upstream release decide what this repository executes. Read
   the whole set with `rg -n 'uses:'`, the composite actions included: a tag, a branch,
   or a bare `actions/checkout` is a finding. Local `./.github/actions/...`
   references use the checked-out tree and do not need a SHA. The `github-actions` ecosystem in
   `.github/dependabot.yml` is what moves these pins, so read the `directory:` it
   declares against the directories the `uses:` lines actually sit in: a pin outside
   every declared directory is one nothing bumps.

2. **A credential or a token scope wider than the job's work.** Read the top-level
   `permissions:` of each workflow and the job-level block of each job. The least
   privilege follows the job's work: read-only jobs may inherit `contents: read`,
   while `contents: write` belongs only on the publishing job. Flag broader
   grants, unnecessary secrets, extra tokens and untrusted code running with
   write access. Check `pull_request_target`, `workflow_run`, checkout refs and
   `persist-credentials` together; a trigger name alone does not prove exposure.

3. **An untrusted string interpolated into a `run:` block.** `${{ github.event.* }}`,
   a head ref, a tag name, a branch name, a commit message and a workflow input are
   attacker-writable text. Find every `${{ }}` that lands inside a `run:` body rather
   than in an `env:` block the script quotes. `release.yml` has both safe spellings:
   one step sets `TAG: ${{ github.ref_name }}` in its `env:` block for the `make`
   recipe to read, and other steps quote the runner's own `"$GITHUB_REF_NAME"`. A value the workflow file itself declares,
   such as `matrix.release_target` from a literal `include:` list, is not untrusted and
   is not a finding, but a matrix row that is ever filled from an event value makes it
   one.

4. **Shell failures hidden by successful steps.** Read each `run:` block with its
   effective shell, including inherited defaults. Confirm command failures and
   failed pipeline producers propagate to the step's status. Use `set -euo pipefail`
   or equivalent shell options where needed; absence of an explicit line is not
   a defect if the effective shell already supplies it. Composite `run:` steps
   must declare a shell.

5. **A step that re-spells a command the Makefile owns.** The gate's steps are
   `make` targets so that a target added to the Makefile gates a push without a
   second edit here. A `run:` line that inlines a build, lint, test, target-list or
   version command instead of calling the target that owns it is a second source: two
   spellings drift, and the one that drifts is the one the prose still promises. A
   `zig build test` line, a literal list of published targets, or a literal tool version
   in a `run:` body is a finding; name the target it should call.

6. **A job or trigger that can publish without the gate.** The release workflow runs on
   `push` tags matching a glob. Read the glob against the conditions
   `make check-release` enforces (the tag it matches against `build.zig.zon`, the
   stranded `[Unreleased]` entries it refuses, and the `check-changelog`,
   `check-changelog-links` and `check-readme` it calls; `check-changelog`
   enforces the 0.y bump rule) and against the tag `build.zig.zon` declares: a
   valid release tag excluded by the trigger publishes nothing. A broad trigger
   is acceptable when the gate rejects invalid tags before publication. A release
   job omitting a required gate is a finding. The first publish step must
   refuse to replace a published release and must finish a draft an earlier run left,
   and the read-back step after it must compare the published assets against `dist/`
   rather than trusting the upload's return.

7. **A runner label or matrix row the fleet no longer answers to.** Every `os:` in the
   `test` matrix names a live image; GitHub retires labels, and a retired one leaves
   the job red with a scheduling error rather than a test failure, which is the failure
   this tree already recorded once. The matrix's second dimension is the published
   asset each row runs, so read the rows against `RELEASE_TARGETS` in the `Makefile`:
   a row whose `release_target` is not in that list, a published target no row runs
   where the row's comment says one does, and a duplicate target on two rows are all
   findings. `aarch64-linux-musl` is build-only by design; the finding is the comment
   claiming otherwise, not the coverage.

8. **A job with no ceiling, or a ceiling no longer covering its work.** Every job needs
   a `timeout-minutes`, and the jobs that cross-build and run the reproducibility
   step (`release-assets` in `ci.yml`, `release` in `release.yml`) need one that
   covers four published targets, the two independent builds each of them makes, and
   the toolchain's cold compile. A missing `timeout-minutes` is a finding; a value
   shorter than the job's own comment describes is a finding, and the fix is the
   number, not the comment.

9. **Concurrency that cancels the wrong run.** Confirm CI supersedes obsolete runs
   for the same ref or pull request, and the release workflow does not cancel an
   in-flight publication. Push and pull-request events may use separate groups:
   push payloads do not supply a pull-request number. Document duplicate work
   accurately rather than claiming the key deduplicates both events.

10. **A cache whose key cannot separate what shares it.** The two `actions/cache`
    steps in `setup-zig` are keyed on `runner.os` and `runner.arch`; the linter
    action caches through `setup-uv`'s own cache, which this file cannot key, so
    what it can be judged on is the `cache-dependency-glob` it declares.
    `runner.arch` answers `X64` and `ARM64` while `runner.os` answers `macOS` for
    both macOS images, so the two rows the `test` matrix runs must differ on arch
    or the key has two jobs racing to save one entry; read the labels off the
    `include:` list rather than off a name a retired image used to carry. A
    cache path that is this tree's own build products must hash the sources and
    the toolchain; a `restore-keys` prefix that
    falls back across an architecture, an operating system or a toolchain version lets a
    job restore a tree it cannot use. `actions/cache` and a cache save on an untrusted
    ref is worth a note only when the restore is shared across trigger levels, which
    for these keys it is not.

11. **A composite action that hands a job more than it needs.** The two actions exist
    so the Zig version and the linter pins are read once, from
    `build.zig.zon` and `lint-requirements.txt`. Read what each exports: a value written
    to `$GITHUB_OUTPUT` from a command that can succeed with empty output, a cache
    directory placed under `RUNNER_TEMP` whose path one job assumes and another does
    not, or a `GITHUB_PATH` entry that shadows the runner's own `python3` or `ruff`, is
    a finding. The install itself must stay `--require-hashes`; an unpinned or
    hash-free install step is a finding dependabot cannot catch for you: only the
    `github-actions` ecosystem is declared, so nothing moves a pip pin.

12. **A claim in a workflow comment that the file no longer carries.** These files are
    commented at length, and the comments name the reason for a step, a key component
    and a target. A comment naming a step, a version, a target or a failure that the
    file below it no longer has is a finding, because the comment is what the next
    editor trusts instead of reading the file.
