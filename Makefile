# Zig invocations are spelled out so the same commands work without make.
ZIG ?= zig
OPT ?= ReleaseFast
BIN := zig-out/bin/microagent

# A recipe that fails mid-copy leaves no half-written target behind, so a later
# run cannot install or benchmark a truncated binary.
.DELETE_ON_ERROR:

# A compiler reads the locale and the timezone out of the environment, so two
# builds of one commit on two machines can differ without either being wrong.
# Nothing embeds either today, and pinning them here is what keeps it that way:
# a release built on a laptop is then the same bytes ci.yml publishes, which is
# the claim CONTRIBUTING.md makes about building one before the tag exists.
export LC_ALL := C
export TZ := UTC

.PHONY: default help preflight version build small musl test test-sanitize test-one watch fmt fmt-check fmt-python lint lint-versions lint-lock zig-version required-zig-version release-targets check-targets check-assets check-changelog check-changelog-sections check-unreleased check-readme check-release check-reproducible lint-shell lint-python lint-yaml check bench gauntlet instructions overhead install release-assets checksums clean

# The targets `microagent update` asks for, in the names release.yml publishes.
# ci.yml rehearses the same list on every push and release.yml publishes it, so
# the list and the asset names are spelled once, here.
RELEASE_TARGETS := x86_64-linux-musl aarch64-linux-musl x86_64-macos aarch64-macos
# A rehearsal leaves TAG empty; a release passes TAG=v0.2.0.
ASSET_PREFIX = microagent-$(if $(TAG),$(TAG)-)

# GNU coreutils has sha256sum and macOS ships shasum under another name; both
# print the `<hex>  <name>` line src/update.zig reads. Which host has which is
# decided once, here, so `checksums` and `check-reproducible` cannot disagree.
# The result is used unquoted on purpose: `shasum -a 256` has to arrive as two
# words, and it is empty on a host with neither.
SHA256_CMD = if command -v sha256sum >/dev/null 2>&1; then echo sha256sum; \
	elif command -v shasum >/dev/null 2>&1; then echo "shasum -a 256"; fi

# The scratch root `check-reproducible` builds into. CI passes the runner's temp
# directory; a local run gets the caller's TMPDIR.
REPRO_DIR ?= $${TMPDIR:-/tmp}/microagent-repro

# The linter versions the gate runs. `ruff format` rewrites files and
# `yamllint` changes rules between releases, so a local run on a different
# version is a green run CI disagrees with. Spelled once, here:
# `lint-versions` checks a local install against them, and checks that the
# hashes in lint-requirements.txt still pin them, because the ci.yml lint job
# installs that file. shellcheck rides on the runner image, so it has no
# version to pin here.
RUFF_VERSION := 0.16.4
YAMLLINT_VERSION := 1.38.0

# The default target is the build, so a bare `make` in a fresh clone is the
# first thing in the README and it has to do what the README says.
default: build
.PHONY: default

# A tool the gate needs but the clone does not carry otherwise surfaces where
# it is first reached: `make: ruff: No such file or directory` for the Harbor
# lint, `command not found` for shellcheck, and each only after the format
# check and the test suite have already spent their time. This names every one
# that is absent, with the command that installs it, before any of that runs.
# The versions are the ones the rest of this file pins, so a tool that is
# present but wrong is still `lint-versions` to catch.
PREFLIGHT_TOOLS := $(ZIG) shellcheck ruff yamllint git
preflight:
	@set -eu; bad=0; \
	for tool in $(PREFLIGHT_TOOLS); do \
	  command -v "$$tool" >/dev/null 2>&1 && continue; \
	  bad=1; \
	  case "$$tool" in \
	    zig) \
	      echo "$$tool is not on PATH: install the version build.zig.zon names as .minimum_zig_version, from https://ziglang.org/download/" >&2 ;; \
	    shellcheck) \
	      echo "$$tool is not on PATH: a system package, 'apt-get install -y shellcheck', or 'brew install shellcheck'" >&2 ;; \
	    ruff) \
	      echo "$$tool is not on PATH: 'uv tool install ruff@$(RUFF_VERSION)'" >&2 ;; \
	    yamllint) \
	      echo "$$tool is not on PATH: 'uv tool install yamllint==$(YAMLLINT_VERSION)'" >&2 ;; \
	    git) \
	      echo "$$tool is not on PATH: every linter's file list is read from it with 'git ls-files', so a clone without it lints nothing" >&2 ;; \
	    *) \
	      echo "$$tool is not on PATH" >&2 ;; \
	  esac; \
	done; \
	test "$$bad" -eq 0

# `make check` is what CI runs; run it before pushing.
help:
	@printf '%s\n' \
	  'help                  this list' \
	  'default               the ReleaseFast build, the target bare make runs' \
	  'build                 zig build -Doptimize=$(OPT) -> $(BIN)' \
	  'small                 ReleaseSmall binary' \
	  'musl                  static musl binary for integrations/harbor, for this host ($(MUSL_ARCH))' \
	  'version               the version build.zig.zon declares' \
	  'test                  the whole unit test suite' \
	  'test-sanitize         the same suite under the undefined-behavior sanitizer' \
	  'test-one FILTER=...   only tests whose name contains FILTER' \
	  'watch [FILTER=...]    rerun the suite on every source change, until Ctrl-C' \
	  'preflight             name every tool check and lint need that is not on PATH' \
	  'fmt                   rewrite every tracked .zig and .py file in format style' \
	  'fmt-python            rewrite the tracked .py files, which zig fmt does not reach' \
	  'fmt-check             what check runs over the same files, without rewriting' \
	  'check                 preflight, zig-version, fmt-check, the linters, the tests, an optimized build' \
	  'lint                  the pin checks, then shellcheck, ruff and yamllint' \
	  'lint-shell            shellcheck over every tracked .sh file' \
	  'lint-python           ruff check and ruff format --check over every tracked .py file' \
	  'lint-yaml             yamllint over every tracked .yml and .yaml file' \
	  'lint-versions         check ruff and yamllint against the versions the gate runs, and that every pin is hashed' \
	  'lint-lock             check the Harbor lock carries the manifest pins, a hash each, and nothing else' \
	  'zig-version           check the local zig against the version the release is built with' \
	  'bench AGENTS=...      three coding tasks through each harness' \
	  'gauntlet AGENTS=...   the same gauntlet review on a fresh clone, per harness' \
	  'instructions [CHECK=--check]  retired instructions per unit, against bench/instructions.baseline' \
	  'overhead              startup and first-request cost per harness' \
	  'install               install the binary into ~/.local/bin' \
	  'release-assets        cross-build every published target into dist/' \
	  'release-assets TAG=vX.Y.Z  the same, named as release.yml publishes them' \
	  'release-targets       the published target triples, one per line' \
	  'check-targets         every published target is one `update` asks for' \
	  'check-assets TAG=...  the assets in dist/ are the ones the tag will publish' \
	  'check-changelog [VERSION=...]  the changelog entry a tag would publish, its shape, and the 0.y policy on it' \
	  'check-changelog-sections  the five Keep a Changelog headings, once each, in order' \
	  'check-unreleased      the [Unreleased] entry has the five sections, once each, in order' \
	  'check-changelog-sections SECTION=...  the same five-section shape under one named heading' \
	  'check-readme      the README installs and names the version build.zig.zon declares' \
	  'check-release TAG=vX.Y.Z  the tag names build.zig.zon, nothing is stranded unreleased' \
	  'check-reproducible    every published target rebuilds byte-identical' \
	  'checksums             sha256 sidecars for dist/ (after a tagged build)' \
	  'required-zig-version  the zig version build.zig.zon declares' \
	  'clean                 remove zig-out, .zig-cache, dist and the Harbor musl binary'

# The version build.zig.zon declares. ci.yml and release.yml both refuse a
# release whose tag and whose binary disagree, and both read it through here so
# there is one `sed` for it rather than one per workflow.
version:
	@sed -n 's/^[[:space:]]*\.version = "\([^"]*\)".*/\1/p' build.zig.zon

# The zig version the release assets are built with. setup-zig installs it on
# every runner, and it is read through here for the same reason `version` is:
# a second `sed` over build.zig.zon is a second place to update when the pin
# moves, and the one left behind installs a compiler no release ever used.
required-zig-version:
	@sed -n 's/^[[:space:]]*\.minimum_zig_version = "\([^"]*\)".*/\1/p' build.zig.zon

# The published targets, one per line. ci.yml's reproducibility step builds
# every one of them and a `sed` over this file is a second spelling of the list
# that can disagree with the one `release-assets` builds, which is exactly the
# drift the step is there to catch.
release-targets:
	@for target in $(RELEASE_TARGETS); do echo "$$target"; done

build:
	$(ZIG) build -Doptimize=$(OPT)

# Smallest binary that still runs the same code (~840 KB).
small:
	$(ZIG) build -Doptimize=ReleaseSmall

# The architecture the musl binary is built for, from the host's own. Harbor
# runs the task container on the host's architecture, so an Apple silicon or
# arm64 Linux host needs the aarch64 binary: the x86_64 one is a file that
# container cannot execute, and the adapter would report a missing binary for a
# build that is sitting right there under the other name. `uname -m` answers
# x86_64 and aarch64 already; the two aliases are what Darwin and some Linux
# images use for the same two.
MUSL_ARCH_x86_64 := x86_64
MUSL_ARCH_amd64 := x86_64
MUSL_ARCH_aarch64 := aarch64
MUSL_ARCH_arm64 := aarch64
MUSL_ARCH ?= $(or $(MUSL_ARCH_$(shell uname -m)),$(shell uname -m))
MUSL_BINARY := integrations/harbor/microagent-$(MUSL_ARCH)-linux-musl

# Static musl binary for running inside containers (Harbor benchmarks), named
# for the host's architecture, which is the name the adapter looks for. The copy
# is made beside it and renamed: a copy interrupted halfway leaves a truncated
# binary that the next Harbor run uploads into every container and fails in,
# which reads as a broken agent rather than a broken build.
# The gate `check` runs is not enough on its own, because the two targets here
# are the ones that put a binary on a machine: `zig-version` only reaches them
# through `check`, and both are runnable on their own. A different zig decides
# the bytes, and nothing downstream can see it: the assets still pass
# `check-assets`, and a rebuild of them with the same wrong compiler still
# passes `check-reproducible`, which compares two builds rather than a build
# against a pin. The dependency is what makes a rehearsal on a laptop the same
# bytes the tag publishes, which is the claim CONTRIBUTING.md makes.
musl: zig-version
	$(ZIG) build -Dtarget=$(MUSL_ARCH)-linux-musl -Doptimize=ReleaseFast
	cp $(BIN) $(MUSL_BINARY).tmp
	mv $(MUSL_BINARY).tmp $(MUSL_BINARY)

test:
	$(ZIG) build test --summary all

# The same tests, compiled with the undefined-behavior sanitizer. The suite
# passing tells a reader the assertions hold, not that no load, store or
# integer operation inside them is out of its bounds or overflows: those are
# silent in a ReleaseFast build and are what the release assets carry. This is
# a second run of the same tests rather than a second set, so a failure names
# the test the plain run already knows.
test-sanitize:
	$(ZIG) build test-sanitize --summary all

# The Zig sources the test names are read out of, for `test-one`, and the ones
# `fmt` and `fmt-check` read. Taken from git for the reason lint-shell names: a
# glob names the paths as they stand, so a Zig file added outside src/ is
# formatted by nothing and the gate still passes.
ZIG_SOURCES := $(shell git ls-files '*.zig')
# `zig fmt` formats .zon as well as .zig, and build.zig.zon is where the
# version every release is published from is written down, so it is read by a
# hand edit that nothing checks the shape of. It is listed apart from
# ZIG_SOURCES because that list is also what `test-one` greps for test names,
# and a manifest has none.
ZON_SOURCES := $(shell git ls-files '*.zon')

# The Python and YAML the linters read, for the same reason.
PY_SOURCES := $(shell git ls-files '*.py')
YAML_SOURCES := $(shell git ls-files '*.yml' '*.yaml')

test-one:
	@test -n "$(FILTER)" || { printf 'usage: make test-one FILTER=<test name substring>\n' >&2; exit 2; }
	@grep -h -o -E '^test "[^"]+"' $(ZIG_SOURCES) | grep -F -q -- "$(FILTER)" || { \
	  printf 'no declared test is named like "%s"\n' "$(FILTER)" >&2; \
	  printf 'the run below would report success without running a test; list the names with:\n' >&2; \
	  printf "  grep -h -o -E '^test \"[^\"]+\"' $(ZIG_SOURCES)\n" >&2; \
	  exit 2; }
	$(ZIG) build test -Dtest-filter="$(FILTER)" --summary all

# The edit loop. `zig build test --watch` is the build system's own mode and
# needs nothing here that `test` does not already do, so this wraps the same
# command rather than introducing a second way to run the suite. FILTER narrows
# it the way `test-one` narrows one run, and is checked against the declared
# test names for the same reason: a filter matching nothing reports success
# while running no test, which is worse than a slow loop.
watch:
	@if [ -n "$(FILTER)" ]; then \
	  grep -h -o -E '^test "[^"]+"' $(ZIG_SOURCES) | grep -F -q -- "$(FILTER)" || { \
	    printf 'no declared test is named like "%s"\n' "$(FILTER)" >&2; \
	    printf 'the watch below would report success without running a test; list the names with:\n' >&2; \
	    printf "  grep -h -o -E '^test \"[^\"]+\"' $(ZIG_SOURCES)\n" >&2; \
	    exit 2; }; \
	  $(ZIG) build test -Dtest-filter="$(FILTER)" --watch --summary all; \
	else \
	  $(ZIG) build test --watch --summary all; \
	fi

fmt:
	@test -n "$(ZIG_SOURCES)" || { echo "no tracked .zig file to format" >&2; exit 1; }
	@test -n "$(ZON_SOURCES)" || { echo "no tracked .zon file to format" >&2; exit 1; }
	$(ZIG) fmt $(ZIG_SOURCES) $(ZON_SOURCES)
	$(MAKE) fmt-python

# What `check` runs, and what the workflows run, so the file list the gate
# formats is the Makefile's rather than a second spelling of it in a workflow.
# The guard is fmt-python's: a list that came back empty would leave zig fmt
# reading nothing and the step green.
fmt-check:
	@test -n "$(ZIG_SOURCES)" || { echo "no tracked .zig file to check" >&2; exit 1; }
	@test -n "$(ZON_SOURCES)" || { echo "no tracked .zon file to check" >&2; exit 1; }
	$(ZIG) fmt --check $(ZIG_SOURCES) $(ZON_SOURCES)

fmt-python:
	@test -n "$(PY_SOURCES)" || { echo "no tracked .py file to format" >&2; exit 1; }
	ruff format --config ruff.toml $(PY_SOURCES)

# The Zig sources have no linter beyond zig fmt, which check runs; the shell,
# Python and YAML around them do, and a shell that only fails when a benchmark
# runs is a shell nobody has read. This list is the whole of the gate the
# workflows run: ci.yml and release.yml both call `make lint` rather than
# repeating the targets, so a linter added here reaches a push and a tag.
# .github/dependabot.yml is the other thing to keep in step, since it decides
# what opens a bump for these.
lint: lint-versions lint-lock lint-shell lint-python lint-yaml

HARBOR_DIR := integrations/harbor

# The gate's own checks live in scripts/, not in recipes here, so shellcheck
# reads them: a recipe is shell nothing lints, and these two are the code that
# decides whether the linters are the versions the gate means. The versions and
# the Harbor directory stay here, so this file is still the one place each is
# written down; the scripts take them as arguments.
lint-versions:
	@RUFF_VERSION='$(RUFF_VERSION)' YAMLLINT_VERSION='$(YAMLLINT_VERSION)' sh scripts/lint-versions.sh

# The Harbor lock is compared against its manifest; what the three checks are
# is scripts/lint-lock.sh's to say.
lint-lock:
	@sh scripts/lint-lock.sh $(HARBOR_DIR)/requirements.txt

# A different zig is a different compiler, and a compiler decides the bytes:
# codegen, inlining and linker layout all move between releases. setup-zig
# installs `.minimum_zig_version` on every runner, so CI has always built the
# release assets with that exact version, and a laptop on a newer one compiles
# an asset no checksum ever described. A newer zig is not refused by the build
# (the field is a minimum, and a contributor on one should still be able to
# work), so the gate asks for the release version by name and says which it is.
zig-version:
	@set -eu; \
	want="$$($(MAKE) --no-print-directory required-zig-version)"; \
	test -n "$$want" || { echo "build.zig.zon has no .minimum_zig_version to check against" >&2; exit 1; }; \
	have="$$($(ZIG) version)"; \
	[ "$$have" = "$$want" ] || { \
	  echo "zig $$have, the release assets are built with $$want: a different compiler produces a different binary, so 'make release-assets' here would not be the one the tag publishes" >&2; \
	  exit 1; }

# The file list comes from git rather than from a hand-written glob: a glob
# names the depths the scripts live at today, so a script added one level
# deeper is linted by nothing and the gate still passes. xargs splits the list
# if it grows past one command's argument limit, and exits non-zero either way.
#
# --enable names the optional checks, which are off unless asked for. Every
# one of these finds a defect rather than a spelling, and the tree passes all
# of them today, so turning them on costs nothing and covers real classes the
# default set leaves open:
# check-set-e-suppressed, a `set -e` whose failure is swallowed by a `||` or
# `&&` and never reaches the shell; check-unassigned-uppercase, an uppercase
# variable used on a path that never assigned it; deprecate-which, `which`
# where the script runs under a shell or a PATH that may not carry it;
# avoid-nullary-conditions, a `[ $x ]` that tests a literal "null" the script
# just assigned; check-extra-masked-returns, a command substitution whose
# failure is discarded, which is how an empty command line reached `sh -c` and
# was recorded as a pass; and quote-safe-variables, a bare `return` whose
# value changes meaning if it ever carries one.
#
# The names are spelled exactly as `shellcheck --list-optional` prints them,
# and lint-shell asks that list before it lints, because shellcheck accepts an
# --enable name it does not have and runs the rest without a word. Two names
# here were wrong that way for as long as this list existed:
# `check-unassigned-upper` and `avoid-null-test-override` are not checks in
# any shellcheck, so the uppercase-variable and null-literal classes the
# comment claimed were covered were never evaluated, and the gate was green
# on them. lint-shell now fails on a name the installed shellcheck does not
# list, which is what a rename upstream turns this into otherwise.
#
# Every name here is one shellcheck 0.9, the version the ubuntu-24.04 image
# carries, already has, so this runs on the runner as it runs here. That is
# also the ceiling: avoid-negated-conditions and useless-use-of-cat are
# optional checks a later shellcheck adds and the tree passes, and they are
# left off until the runner carries a shellcheck that has them, because a name
# the installed shellcheck does not know now fails this target rather than
# quietly enabling nothing. require-variable-braces (SC2250) stays off for a
# different reason: it is a spelling rule, and asking thirteen benchmark
# scripts to write `${root}` where `$root` is the same word is a change the
# gate should not ask for. add-default-case (SC2249) stays off for the same
# reason: it wants a `*)` arm on a `case` that is already exhaustive, and the
# one finding it raises is on a `case` in portable.sh that matches every value
# it is given. Enable either per file with a `# shellcheck disable=` carrying
# the reason when one is worth taking.
SHELLCHECK_CHECKS := check-set-e-suppressed,check-unassigned-uppercase,deprecate-which,avoid-nullary-conditions,check-extra-masked-returns,quote-safe-variables
SHELLCHECK_OPTS := -x --enable=$(SHELLCHECK_CHECKS)

lint-shell:
	@set -eu; \
	files="$$(git ls-files '*.sh')"; \
	test -n "$$files" || { echo "no tracked .sh file to lint" >&2; exit 1; }; \
	known="$$(shellcheck --list-optional | sed -n 's/^name:  *//p')"; \
	test -n "$$known" || { echo "shellcheck --list-optional printed nothing, so SHELLCHECK_CHECKS cannot be checked against it" >&2; exit 1; }; \
	for name in $$(printf '%s' '$(SHELLCHECK_CHECKS)' | tr ',' ' '); do \
	  printf '%s\n' "$$known" | grep -qx "$$name" || { \
	    echo "SHELLCHECK_CHECKS enables $$name, which this shellcheck ($$(shellcheck --version | awk '/version:/{print $$2}')) does not list:" >&2; \
	    echo "shellcheck accepts an --enable name it does not have and runs the rest in silence, so the check is never evaluated and the gate still passes" >&2; \
	    echo "the checks this shellcheck has are named by 'shellcheck --list-optional'" >&2; \
	    exit 1; \
	  }; \
	done; \
	git ls-files -z '*.sh' | xargs -0 shellcheck $(SHELLCHECK_OPTS)

lint-python:
	@test -n "$(PY_SOURCES)" || { echo "no tracked .py file to lint" >&2; exit 1; }
	ruff check --config ruff.toml $(PY_SOURCES)
	ruff format --check --config ruff.toml $(PY_SOURCES)

lint-yaml:
	@test -n "$(YAML_SOURCES)" || { echo "no tracked .yml or .yaml file to lint" >&2; exit 1; }
	yamllint -c .yamllint $(YAML_SOURCES)

# The CI gate, so a formatting, lint or test failure shows up here rather than
# after a push. Keep these in step with .github/workflows/ci.yml. The release
# job's cross builds are the one part CI does that this does not: they are
# minutes of work, and `make release-assets` runs them. `check-unreleased` is
# the other direction: ci.yml does not run this target whole, because the
# linters are installed in the lint job's own step, so it names that target in a
# step of its own rather than letting it gate a laptop alone.
check:
	$(MAKE) preflight
	$(MAKE) zig-version
	$(MAKE) check-targets
	$(MAKE) check-unreleased
	$(MAKE) check-readme
	$(MAKE) fmt-check
	$(MAKE) lint
	$(ZIG) build test --summary all
	$(ZIG) build test-sanitize --summary all
	$(ZIG) build -Doptimize=ReleaseSmall
	./$(BIN) --version >/dev/null
	./$(BIN) update --help >/dev/null

# The bench scripts invoke each harness by bare name and skip the ones that are
# not on PATH, so the binary this build just produced has to be findable.
BIN_DIR := $(dir $(abspath $(BIN)))

# Three coding tasks through the selected harnesses; see bench/run.sh.
#   make bench AGENTS="microagent kimi"
bench: build
	PATH="$(BIN_DIR):$$PATH" sh bench/run.sh $(or $(AGENTS),microagent)

# Startup latency and first-request cost per installed harness.
overhead: build
	PATH="$(BIN_DIR):$$PATH" sh bench/overhead.sh

# The same gauntlet review on a pristine clone, once per harness, scored on what
# landed rather than on plumbing; see bench/gauntlet.sh.
#   make gauntlet AGENTS="microagent kimi"
gauntlet: build
	PATH="$(BIN_DIR):$$PATH" sh bench/gauntlet.sh $(or $(AGENTS),microagent)

# Retired instructions per unit of work, per path a run walks. Not in `check`:
# it needs Linux `perf`, and a gate that cannot measure on a macOS laptop or a
# runner with the counters off is a gate that fails for reasons unrelated to
# the code. `CHECK=--check` compares each row against bench/instructions.baseline
# and exits 1 when a row leaves its band, 2 when it cannot be measured.
#
# The script builds its own test binary, but it needs the options.zig a full
# `zig build test` leaves in the cache, so the suite runs first: without it the
# script exits 2 on a measurement it could not take, which reads as a broken
# gate on a tree where nothing is wrong.
instructions: test
	sh bench/instructions.sh $(CHECK)

# `install -D` is GNU coreutils; macOS ships BSD install, so the parent
# directory is created here instead.
install: build
	mkdir -p $(HOME)/.local/bin
	install -m755 $(BIN) $(HOME)/.local/bin/microagent

# Every target here is a target `microagent update` asks for, and every target
# it asks for is published here. The two are separate files that a rename in
# either one would break in the same way: an asset published under a name no
# update asks for is dead weight, and a target update asks for that nothing
# publishes is an update that fails on a user's machine at the moment it runs.
# `zig build test` pins the naming in src/update.zig against literals; this
# pins it against this list, so a target cannot be added to one and not the
# other. Building every target proves the triples still compile; it says
# nothing about the names, so it is not the check for this.
#
# The host's own architecture is the third name, and the same drift reaches it
# a different way. `MUSL_ARCH` is `uname -m` under the alias table above, and
# the Harbor adapter looks the binary up under a name spelled the same way, so
# a host whose `uname -m` is not a published target, or an alias that stops
# spelling one, yields a `microagent` the adapter cannot find. That is a build
# that succeeds and a benchmark that fails, so it is asked here rather than by
# whoever runs Harbor next.
check-targets:
	@set -eu; \
	for target in $(RELEASE_TARGETS); do \
		grep -q -- "$$target" src/update.zig || { \
		  echo "$$target is published here but src/update.zig never asks for it, so no update can install it" >&2; \
		  exit 1; }; \
	done; \
	musl_target="$(MUSL_ARCH)-linux-musl"; \
	for target in $(RELEASE_TARGETS); do \
		if [ "$$target" = "$$musl_target" ]; then musl_published=1; break; fi; \
	done; \
	test "$${musl_published:-0}" -eq 1 || { \
	  echo "this host is $(MUSL_ARCH) and 'make musl' builds $(MUSL_BINARY), which is not one of: $(RELEASE_TARGETS)" >&2; \
	  echo "the release publishes no musl asset for it, so the Harbor adapter has nothing to upload" >&2; \
	  exit 1; \
	}

# The shape of one changelog entry: the Keep a Changelog sections
# CONTRIBUTING.md requires, one of each at most, in their order. SECTION names
# the entry, so the same awk asks the one a change is drafted under and the one
# a tag publishes. A misspelled heading, a second `### Fixed`, or a `### Security`
# above a `### Fixed` renders as a release note that reads wrong, and the person
# who reads it rendered is whoever pulls the release.
#
# Only the structure is asked, never the presence of an entry. Whether a change
# is worth an entry is a judgement the person writing it makes, and a gate that
# refused an empty section would be a gate that fails a commit for a policy
# rather than for a mistake in the entry that is there.
check-changelog-sections:
	@awk -v want="$(SECTION)" ' \
	  BEGIN { \
	    split("Added Changed Removed Fixed Security", order, " "); \
	    for (i = 1; i <= 5; i++) rank[order[i]] = i; \
	  } \
	  index($$0, "## [" want "]") == 1 { inside = 1; next } \
	  /^## / { inside = 0 } \
	  inside && /^### / { \
	    name = $$0; sub(/^### /, "", name); sub(/[ \t]+$$/, "", name); \
	    if (!(name in rank)) { \
	      printf("CHANGELOG.md [" want "] has a \"### %s\" section; the five are Added, Changed, Removed, Fixed, Security\n", name) > "/dev/stderr"; \
	      bad = 1; next; \
	    } \
	    if (++seen[name] > 1) { \
	      printf("CHANGELOG.md [" want "] has a second \"### %s\" section, and each of the five is used at most once\n", name) > "/dev/stderr"; \
	      bad = 1; \
	    } \
	    if (name != previous && rank[name] <= last) { \
	      printf("CHANGELOG.md [" want "] has \"### %s\" after \"### %s\"; the order is Added, Changed, Removed, Fixed, Security\n", name, previous) > "/dev/stderr"; \
	      bad = 1; \
	    } \
	    last = rank[name]; previous = name; \
	  } \
	  END { exit bad } \
	' CHANGELOG.md

# The shape of the entry a change carries, asked while it is still under
# [Unreleased]. `check-changelog` asks the same rules over the section a tag
# names, which by then is a version heading the author no longer sees.
check-unreleased:
	@$(MAKE) --no-print-directory check-changelog-sections SECTION=Unreleased

# The changelog rules release.yml enforces on the tag, and the 0.y policy
# CONTRIBUTING.md states, runnable before the tag exists. They were shell inside
# release.yml, so the policy a contributor writes an entry against could only be
# checked by pushing a tag: a patch carrying an `Added`, a section left under
# [Unreleased] that the tag would drop, and a version with no notes at all were
# all first found by a failed release job rather than by a command. The section
# this target publishes is asked for the same shape `check-unreleased` asks of
# the entry being drafted, since by the time a tag names a version heading the
# author who wrote it no longer sees it. VERSION is
# the version under test and defaults to the one build.zig.zon declares, so the
# check a contributor runs while drafting an entry asks the same question the
# tag will.
check-changelog:
	@set -eu; \
	want="$(VERSION)"; \
	test -n "$$want" || want="$$($(MAKE) --no-print-directory version)"; \
	section() { \
	  awk -v want="$$1" ' \
	    index($$0, "## [" want "]") == 1 { inside = 1; next } \
	    /^## / { inside = 0 } \
	    inside \
	  ' CHANGELOG.md | sed '/./,$$!d'; \
	}; \
	notes="$$(section "$$want")"; \
	test -n "$$notes" || { \
	  echo "CHANGELOG.md has no [$$want] entry, so a tag naming it would publish no release notes" >&2; \
	  echo "add it with the Keep a Changelog sections the file already uses" >&2; \
	  exit 1; \
	}; \
	$(MAKE) --no-print-directory check-changelog-sections SECTION="$$want"; \
	printf '%s\n' "$$notes"; \
	prev="$$(awk -v want="$$want" ' \
	  /^## \[/ { \
	    heading = $$0; sub(/^## \[/, "", heading); sub(/\].*/, "", heading); \
	    if (heading == want) { found = 1; next } \
	    if (found && heading ~ /^[0-9]+\.[0-9]+\.[0-9]+$$/) { print heading; exit } \
	  } \
	' CHANGELOG.md)"; \
	minor_of() { printf '%s\n' "$$1" | awk -F. '{ print $$1 "." $$2 }'; }; \
	if [ -n "$$prev" ] && [ "$$(minor_of "$$prev")" = "$$(minor_of "$$want")" ] && [ "$$prev" != "$$want" ]; then \
	  if printf '%s\n' "$$notes" | grep -q '^### \(Added\|Changed\|Removed\)$$'; then \
	    echo "$$want is a patch over $$prev, and its section has an Added, a Changed or a Removed entry" >&2; \
	    echo "under 0.y the minor carries features, anything that changes what a run does by default," >&2; \
	    echo "and anything taken away: bump the minor in build.zig.zon and CHANGELOG.md, or move those entries out" >&2; \
	    exit 1; \
	  fi; \
	fi

# The version the README names in the two places a reader copies or trusts: the
# install snippet's `v=`, and the Status line's version. build.zig.zon is where
# the version is declared, and `check-release` and release.yml both read it from
# there, so a README left on the previous release is a consumer handed a command
# that fetches the old binary and a status line that is one release stale, with
# nothing refusing either. Both lines are matched whole rather than swept for
# version-shaped text: the README also carries the Zig version, which is its own
# pin and is not the release being cut.
check-readme:
	@set -eu; \
	want="$$($(MAKE) --no-print-directory version)"; \
	grep -q "^v=v$$want t=" README.md || { \
	  echo "the install snippet in README.md does not install v$$want, the version build.zig.zon declares" >&2; \
	  echo "a reader who copies it gets the previous release, so the two are checked in step with the bump" >&2; \
	  exit 1; \
	}; \
	grep -q "^Version $$want\. " README.md || { \
	  echo "the Status section of README.md does not read \"Version $$want.\", the version build.zig.zon declares" >&2; \
	  exit 1; \
	}

# What a tag has to satisfy before release.yml will publish it: it names the
# version build.zig.zon declares, and nothing is left stranded under
# [Unreleased], where the tag would drop those entries from the published notes
# and land them in the next release under a version the consumer never ran. Both
# are properties of the tree a contributor is about to tag, so both are asked
# here rather than in the workflow that would refuse the tag. `check-changelog`
# carries the rest, and this target is the whole of the tag gate.
check-release:
	@test -n "$(TAG)" || { printf 'usage: make check-release TAG=vX.Y.Z\n' >&2; exit 2; }; \
	want="v$$($(MAKE) --no-print-directory version)"; \
	test "$(TAG)" = "$$want" || { \
	  echo "tag $(TAG) does not name build.zig.zon version $$want, and release.yml refuses a tag that does not" >&2; \
	  exit 1; \
	}; \
	stranded="$$(awk ' \
	  index($$0, "## [Unreleased]") == 1 { inside = 1; next } \
	  /^## / { inside = 0 } \
	  inside \
	' CHANGELOG.md | sed '/./,$$!d')"; \
	test -z "$$stranded" || { \
	  echo "CHANGELOG.md still has unreleased entries that tag $(TAG) would drop from the published notes:" >&2; \
	  printf '%s\n' "$$stranded" >&2; \
	  exit 1; \
	}; \
	$(MAKE) --no-print-directory check-changelog VERSION=$(patsubst v%,%,$(TAG))
	$(MAKE) --no-print-directory check-readme

# The assets in dist/ are the ones the tag will publish, read back off the disk
# rather than assumed from the build that wrote them. release.yml did this inline
# over the same files, so a laptop rehearsal of a release checked nothing: only
# the host binary was run and only its three peers were counted, and a check that
# exists only in the workflow is a check the contributor who wrote the release
# note never runs. Every published target is read, because a cross build that
# produced the wrong object, or an empty one, publishes green and fails on a
# consumer's machine. TAG is the tag the assets were built under, empty for the
# rehearsal ci.yml builds on every push; the version each binary reports is the
# one the tag names, or the one build.zig.zon declares when there is no tag.
#
# The version is read by running one asset, and the one it runs is the one this
# host can execute, decided from uname rather than named. The four published
# targets cover two architectures on two systems, so a hardcoded name is a name
# a third of the hosts cannot run: an Apple silicon laptop running the Linux
# asset gets an exec format error and reads the assets as broken when they are
# the ones a tag will publish. Where no published target is this host, the
# object-format loop still runs and the version read is reported as not taken
# rather than passed.
#
# Each asset is read for its object format and its machine, not its name. The
# magic alone is half the answer: every Mach-O 64 file starts with cffaedfe
# whatever the CPU, and every ELF with 7f454c46, so a cross build that ignored
# -Dtarget and produced the host's architecture published under the other
# target's name and read clean. The machine field is the one that says which:
# e_machine at offset 18 in an ELF, cputype at offset 4 in a Mach-O, each
# little-endian. Both are declared per target rather than derived from the
# suffix, so a target added to RELEASE_TARGETS has to say here what it is
# before it can be published.
#
# The version check runs the asset for the host's own platform and architecture,
# found from `uname` rather than named: an ELF is not runnable on Darwin and a
# Mach-O is not runnable on Linux, so naming the Linux one unconditionally made
# this target fail on both macOS runners and on an arm64 Linux host with a
# message about a version that was never read. A host the release publishes no
# asset for runs nothing and says so, and the object-format check below still
# covers all of them.
check-assets:
	@set -eu; \
	test -d dist || { echo "no dist/, run 'make release-assets TAG=v0.2.0' first" >&2; exit 2; }; \
	if [ -z "$(TAG)" ]; then \
	  for tagged in dist/microagent-v*; do \
	    test -e "$$tagged" || continue; \
	    echo "$$tagged is a tagged build, so this run wants the tag it was made with:" >&2; \
	    echo "  make check-assets TAG=$$(printf '%s\n' "$$tagged" | sed -e 's|.*/microagent-\(v[0-9][^-]*\)-.*|\1|')" >&2; \
	    exit 1; \
	  done; \
	fi; \
	prefix="$(ASSET_PREFIX)"; \
	want="$$($(MAKE) --no-print-directory version)"; \
	if [ -n "$(TAG)" ]; then \
	  test "$(TAG)" = "v$$want" || { \
	    echo "dist/ was built for tag $(TAG), which is not the version build.zig.zon declares (v$$want)" >&2; \
	    exit 1; \
	  }; \
	  want="$(patsubst v%,%,$(TAG))"; \
	fi; \
	host_os="$$(uname -s)"; \
	host_target=; \
	case "$$host_os" in \
	Darwin) host_target="$(MUSL_ARCH)-macos" ;; \
	Linux) host_target="$(MUSL_ARCH)-linux-musl" ;; \
	*) host_target= ;; \
	esac; \
	ran=; \
	for target in $(RELEASE_TARGETS); do \
	  if [ "$$target" = "$$host_target" ]; then ran=$$target; break; fi; \
	done; \
	if [ -z "$$ran" ]; then \
	  echo "this host ($$host_os $(MUSL_ARCH)) is not one the release publishes an asset for, so none of them was run here"; \
	else \
	  got="$$(dist/$${prefix}$$ran --version)" || got=; \
	  test -n "$$got" || { \
	    echo "dist/$${prefix}$$ran did not run on this host, so its version was not checked" >&2; \
	    exit 1; \
	  }; \
	  test "$$got" = "microagent $$want" || { \
	    echo "dist/$${prefix}$$ran reports '$got', not 'microagent $$want', so the published asset is not the version this tag names" >&2; \
	    exit 1; \
	  }; \
	fi; \
	for target in $(RELEASE_TARGETS); do \
	  asset="dist/$${prefix}$$target"; \
	  test -f "$$asset" || { \
	    echo "no $$asset: 'make release-assets' builds every published target, and that one is missing" >&2; \
	    exit 1; \
	  }; \
	  magic="$$(od -An -tx1 -N4 "$$asset" | tr -d ' \n')"; \
	  case "$$target" in \
	    x86_64-linux-musl) want_magic=7f454c46; want_machine=3e00 ;; \
	    aarch64-linux-musl) want_magic=7f454c46; want_machine=b700 ;; \
	    x86_64-macos) want_magic=cffaedfe; want_machine=07000001 ;; \
	    aarch64-macos) want_magic=cffaedfe; want_machine=0c000001 ;; \
	    *) echo "no expected object format known for $$target, so its asset cannot be checked here" >&2; exit 1 ;; \
	  esac; \
	  test "$$magic" = "$$want_magic" || { \
	    echo "$$asset starts with $${magic:-nothing}, expected $$want_magic" >&2; \
	    exit 1; \
	  }; \
	  case "$$target" in \
	    *-macos) machine_off=4; machine_len=4 ;; \
	    *) machine_off=18; machine_len=2 ;; \
	  esac; \
	  machine="$$(od -An -tx1 -j "$$machine_off" -N "$$machine_len" "$$asset" | tr -d ' \n')"; \
	  test "$$machine" = "$$want_machine" || { \
	    echo "$$asset names machine $${machine:-nothing}, expected $$want_machine for $$target" >&2; \
	    echo "a cross build that ignored -Dtarget publishes green and fails on a consumer's machine" >&2; \
	    exit 1; \
	  }; \
	done; \
	if [ -n "$$ran" ]; then \
	  echo "$${prefix}* is a $$want build of every published target, and $${prefix}$$ran runs here"; \
	else \
	  echo "$${prefix}* is a $$want build of every published target, none of which runs on this host"; \
	fi

# Every published target, cross-built, under the name release.yml publishes and
# update.zig asks for. Running it without TAG is the rehearsal ci.yml does on
# every push; `make release-assets TAG=v0.2.0` produces the released names, so
# a release can be built on a laptop exactly as the tag builds it.
#
# dist/ is emptied first, so what it holds after this recipe is this run's
# assets and nothing else. Without that, a rehearsal's untagged binaries, or a
# previous tag's, survive into the next run: release.yml publishes the glob
# `dist/microagent-*`, so a second run on a machine that once built another
# version would upload that version's binaries under this tag, and `checksums`
# would sidecar them as if they were the ones just built.
# version a release is published with, for the reason musl names: this is the
# target whose output is published, and a compiler other than the pinned one
# produces an asset no checksum ever described, reproducibly enough to pass
# check-reproducible.
release-assets: zig-version
	rm -rf dist
	mkdir -p dist
	@set -eu; for target in $(RELEASE_TARGETS); do \
		$(ZIG) build -Dtarget="$$target" -Doptimize=ReleaseSmall; \
		install -m755 $(BIN) "dist/$(ASSET_PREFIX)$$target"; \
	done

# The sha256 sidecar `microagent update` verifies before it replaces anything.
# Only a tagged build names its assets after a version, so a rehearsal in dist/
# has nothing to checksum and says so. A host with neither hashing command is
# told so rather than left without the sidecars an update cannot verify. Each
# sidecar is written to a `.tmp` and renamed, the way `musl` stages its binary:
# a sidecar truncated by an interrupted run is a file `update` hashes the asset
# against and fails on, and the leftovers of that run are skipped rather than
# checksummed as if they were an asset.
checksums:
	@test -d dist || { echo "no dist/, run 'make release-assets TAG=v0.2.0' first" >&2; exit 2; }
	@cd dist && set -eu && \
	sum=$$($(SHA256_CMD)); \
	test -n "$$sum" || { \
		echo "neither sha256sum nor shasum is on PATH, so the sidecars update verifies cannot be written" >&2; \
		exit 2; \
	}; \
	written=0; \
	for asset in microagent-v*; do \
		case "$$asset" in *.sha256|*.tmp) continue;; esac; \
		test -e "$$asset" || continue; \
		$$sum "$$asset" > "$$asset.sha256.tmp"; \
		mv "$$asset.sha256.tmp" "$$asset.sha256"; \
		written=$$((written + 1)); \
	done; \
	test "$$written" -gt 0 || { \
		echo "no tagged assets in dist/, so no sidecar was written: run 'make release-assets TAG=v0.2.0' first" >&2; \
		exit 2; \
	}; \
	echo "wrote $$written sidecars in dist/"

# Two independent builds of the same source must be byte-identical, or a
# released checksum describes one binary and a rebuild produces another. Every
# published target is checked, not one: two of the four assets are macOS
# binaries, and a host-specific timestamp or path leaking into a cross build
# would pass a check that only built the Linux one. The target list is the one
# `release-assets` builds, so a new target cannot ship without a reproducibility
# check of its own.
#
# Each build gets a cache and a prefix of its own, and the previous pair is
# removed first, so the second is a real build rather than a cache hit. Both
# caches are moved: `--cache-dir` covers the project's own artifacts, and
# ZIG_GLOBAL_CACHE_DIR covers the compiled toolchain under the runner's
# `$HOME/.cache`, which is otherwise state a previous build on the same machine
# leaves behind and a fresh checkout does not. The scratch is removed on the way
# out by a trap, so a target that fails the comparison leaves nothing behind
# either. The
# clock, timezone and locale are varied between the two, so a timestamp or a
# locale-dependent ordering leaking into the binary fails here rather than on a
# consumer's machine. The first target is then built a third time from a copy
# of the source at another path, because a build path can reach a binary the
# same way a timestamp can: a panic message naming the checkout, an embedded
# file read by absolute name, a link path. The other two builds share this
# tree's path, so they cannot see that, and the bytes a release publishes
# would then depend on where the runner put the checkout. The copy is every
# tracked file rather than a hand-written list of the ones the build reads
# today, for the reason ZIG_SOURCES is: a second spelling of the source set is
# a list that stops naming a file the build has since started reading, and the
# build it checks is then not the one that ships. The copy lives in a
# sibling of REPRO_DIR rather than inside it, because build_once empties
# REPRO_DIR on every call. A working tree with a tracked build input modified
# or a new one untracked is the case where the copy is not this tree at all, so
# the comparison is skipped there and says so: the two builds above it still
# compare the working tree against itself and still mean what they claim.
# ci.yml runs this on every push and release.yml runs
# it on the tag, so a release is never published from a commit that has not
# passed it.
check-reproducible:
	@set -eu; \
	test -n "$(RELEASE_TARGETS)" || { echo "no RELEASE_TARGETS to check" >&2; exit 1; }; \
	sum=$$($(SHA256_CMD)); \
	test -n "$$sum" || { \
	  echo "neither sha256sum nor shasum is on PATH, so a rebuild cannot be compared" >&2; \
	  exit 2; \
	}; \
	REPRO_SRC=$(REPRO_DIR)-src; \
	trap 'rm -rf "$(REPRO_DIR)" "$$REPRO_SRC"' EXIT; \
	build_once() { \
	  rm -rf "$(REPRO_DIR)"; \
	  SOURCE_DATE_EPOCH="$$1" LC_ALL="$$2" TZ="$$3" ZIG_GLOBAL_CACHE_DIR="$(REPRO_DIR)/global" $(ZIG) build \
	    -Dtarget="$$4" -Doptimize=ReleaseSmall \
	    --cache-dir "$(REPRO_DIR)/cache" -p "$(REPRO_DIR)/out"; \
	  $$sum "$(REPRO_DIR)/out/bin/microagent" | cut -d' ' -f1; \
	}; \
	build_from_copy() { \
	  srcdir="$$REPRO_SRC"; \
	  rm -rf "$$srcdir" "$(REPRO_DIR)"; \
	  mkdir -p "$$srcdir"; \
	  git ls-files | { \
	    bad=0; \
	    while IFS= read -r tracked; do \
	      mkdir -p "$$srcdir/$$(dirname "$$tracked")" || { bad=1; break; }; \
	      cp "$$tracked" "$$srcdir/$$tracked" || { bad=1; break; }; \
	    done; \
	    exit $$bad; \
	  } || { \
	    echo "a tracked file could not be copied into $$srcdir, so the build from another directory" >&2; \
	    echo "would compare a partial source tree against this one and say nothing about build paths" >&2; \
	    exit 1; \
	  }; \
	  (cd "$$srcdir" && SOURCE_DATE_EPOCH="$$1" LC_ALL="$$2" TZ="$$3" ZIG_GLOBAL_CACHE_DIR="$(REPRO_DIR)/global" $(ZIG) build \
	    -Dtarget="$$4" -Doptimize=ReleaseSmall \
	    --cache-dir "$(REPRO_DIR)/cache" -p "$(REPRO_DIR)/out2"); \
	  $$sum "$(REPRO_DIR)/out2/bin/microagent" | cut -d' ' -f1; \
	}; \
	for target in $(RELEASE_TARGETS); do \
	  first=$$(build_once 1700000000 C UTC "$$target"); \
	  second=$$(build_once 1800000000 C.UTF-8 Asia/Tokyo "$$target"); \
	  if [ "$$first" != "$$second" ]; then \
	    echo "rebuild of $$target differs: $$first != $$second" >&2; \
	    exit 1; \
	  fi; \
	  if [ "$$target" = "$(firstword $(RELEASE_TARGETS))" ]; then \
	    if [ -n "$$(git status --porcelain -- src build.zig build.zig.zon)" ]; then \
	      echo "skipping the build-directory comparison: a tracked build input is modified or deleted in this"; \
	      echo "working tree, and the copy is made from git, so it would compare two different sources and"; \
	      echo "report a build path reaching the binary when the source is what differs"; \
	    else \
	      elsewhere=$$(build_from_copy 1900000000 C UTC "$$target"); \
	      if [ "$$first" != "$$elsewhere" ]; then \
	        echo "$$target built from another directory differs: $$first != $$elsewhere" >&2; \
	        echo "the build path reaches the binary, so a checksum published from one checkout describes only that checkout" >&2; \
	        exit 1; \
	      fi; \
	      echo "$$target is the same from another build directory"; \
	    fi; \
	  fi; \
	  echo "$$target rebuilds to $$first"; \
	done; \
	rm -rf "$(REPRO_DIR)" "$$REPRO_SRC"

clean:
	rm -rf zig-out .zig-cache dist $(HARBOR_DIR)/microagent-*-linux-musl $(HARBOR_DIR)/microagent-*-linux-musl.tmp
