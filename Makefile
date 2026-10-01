# Zig invocations are spelled out so the same commands work without make.
ZIG ?= zig
OPT ?= ReleaseSmall
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

.PHONY: test-cli

.PHONY: default help preflight version build musl test watch test-sanitize fmt fmt-check fmt-python lint lint-versions lint-versions-selftest lint-lock lint-ci check-sbom check-refs zig-version required-zig-version release-targets check-assets check-asset-run check-binary check-changelog check-changelog-links check-changelog-sections check-unreleased check-changelog-history check-readme check-help check-man check-release check-reproducible lint-shell lint-python lint-yaml lint-md check bench gauntlet instructions overhead install release-assets checksums check-checksums sbom sha256-of clean

# The Harbor adapter's directory, the one place that path is written down.
# lint-lock.sh and lint-versions.sh both take it as an argument rather than
# spelling it out in a script, so a move is a change here and nowhere else.
# lint-lock.sh also derives nothing from it: each lock is named beside the
# manifest it was compiled from, so the linter set and this one are checked by
# the same code and each path is still written down once.
HARBOR_DIR := integrations/harbor

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

# The same question asked for the SHA1 the SPDX verification code is built from,
# decided here for the same reason: `sbom` and `check-sbom` hash the same assets
# with it, so a host that has one command answers for both rather than one
# script finding the command and the other spelling it out again.
SHA1_CMD = if command -v sha1sum >/dev/null 2>&1; then echo sha1sum; \
	elif command -v shasum >/dev/null 2>&1; then echo "shasum -a 1"; fi

# The scratch root `check-reproducible` builds into. It is a sibling of the
# toolchain cache below, never a child, because every build wipes REPRO_DIR.
#
# It defaults to the tree's own gitignored .scratch/ rather than ${TMPDIR:-/tmp},
# which is what a local run used to get. /tmp is a tmpfs on most Linux hosts, and
# this target makes nine cold builds of four cross targets: the toolchain cache
# alone is a few hundred megabytes, written into RAM by a check, and thrown away
# by a reboot. CI passes the runner's temp directory, which is disk-backed and
# discarded with the runner.
REPRO_DIR ?= $(CURDIR)/.scratch/repro
# The compiled toolchain and standard library `check-reproducible` builds
# against. `check-reproducible` names it as ZIG_GLOBAL_CACHE_DIR for its own
# builds, so the cache the setup-zig action restores is not the one this fills:
# that one serves `release-assets` and `check-asset-run`, and this directory
# survives between the nine builds, which is the whole point of it being
# separate. It lives outside REPRO_DIR because that directory is emptied on
# every one of the nine builds, and a cache emptied with it is a cold build:
# measured here, compiling one published target costs 4m25s into an empty
# toolchain cache and 2m52s into a warm one, and nine of the former is most of
# a job whose ceiling is 40 minutes. It is removed once before the loop so the
# run does not inherit a previous one's, and by the trap so a failed comparison
# leaves nothing behind. Both it and REPRO_DIR are passed from the workflows,
# which put them under the runner's disk-backed temp rather than the checkout.
REPRO_GLOBAL ?= $(CURDIR)/.scratch/repro-global

# The linter versions the gate runs. `ruff format` rewrites files and
# `yamllint` changes rules between releases, so a local run on a different
# version is a green run CI disagrees with. Spelled once, here:
# `lint-versions` checks a local install against them, and checks that
# lint-requirements.in, which lint-requirements.txt is compiled from, names the
# same two, because the ci.yml lint job installs that file. shellcheck rides on
# the runner image, so it has no version to pin here.
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
#
# The `case` reads the basename rather than the word as written, because ZIG is
# an override: `make ZIG=/opt/zig-0.16.0/zig check` is how a contributor runs
# the gate against a compiler that is not on PATH, and a case matching the whole
# word fell through to the bare `*)` arm for it, printing a dead end where the
# one remedy the message exists to give was a line above.
PREFLIGHT_TOOLS := $(ZIG) shellcheck ruff yamllint git python3

# The two programs the `search` and `ast` tools delegate to. A missing one is
# not a failure here: the tests that drive them skip themselves, the runner
# counts a skip as a pass, and a stock macOS ships neither, so a gate that
# refused to run without them would stop working on a published platform. What
# the gate would otherwise do is report a green suite that never ran those
# tests, which is the one thing this target exists to keep off a laptop. So it
# names them, with the command that installs each, and the run continues. The
# remedies are the ones the tool itself prints, which live beside their spawn in
# src/tool.zig as ripgrep_install and ast_grep_install.
PREFLIGHT_SKIPPED_TOOLS := rg ast-grep
preflight:
	@set -eu; bad=0; \
	for tool in $(PREFLIGHT_TOOLS); do \
	  command -v "$$tool" >/dev/null 2>&1 && continue; \
	  bad=1; \
	  case "$$(basename "$$tool")" in \
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
	    python3) \
	      echo "$$tool is not on PATH: check-sbom parses the SBOM with 'python3 -m json.tool'" >&2 ;; \
	    *) \
	      echo "$$tool is not on PATH" >&2 ;; \
	  esac; \
	done; \
	if command -v python3 >/dev/null 2>&1 && ! python3 -c 'import yaml' >/dev/null 2>&1; then \
	  echo "python3 cannot import PyYAML: install lint-requirements.txt into a venv on PATH (see CONTRIBUTING.md)" >&2; \
	  bad=1; \
	fi; \
	for tool in $(PREFLIGHT_SKIPPED_TOOLS); do \
	  command -v "$$tool" >/dev/null 2>&1 && continue; \
	  case "$$tool" in \
	    rg) \
	      echo "note: $$tool is not on PATH: the tests that drive the search tool skip themselves and the runner counts a skip as a pass, so this run says nothing about it; macOS: 'brew install ripgrep'; Debian/Ubuntu: 'apt-get install ripgrep'" >&2 ;; \
	    ast-grep) \
	      echo "note: $$tool is not on PATH: the tests that drive the ast tool skip themselves and the runner counts a skip as a pass, so this run says nothing about it; macOS: 'brew install ast-grep'; or 'cargo install ast-grep'" >&2 ;; \
	  esac; \
	done; \
	test "$$bad" -eq 0

# `make check` is what CI runs; run it before pushing.
help:
	@printf '%s\n' \
	  'help                  this list' \
	  'default               the ReleaseSmall build, the target bare make runs' \
	  'build                 zig build -Doptimize=$(OPT) -> $(BIN)' \
	  'musl                  static musl binary for integrations/harbor, for this host ($(MUSL_ARCH))' \
	  'version               the version build.zig.zon declares' \
	  'test [FILTER=...]     the whole unit test suite, or only the tests FILTER names' \
	  'test-cli              built CLI against a loopback provider (also in unfiltered test)' \
	  'watch [FILTER=...]    the same tests again on every source change, until Ctrl-C' \
	  'test-sanitize         the same suite under the undefined-behavior sanitizer' \
	  'preflight             name every tool check and lint need that is not on PATH, and every one whose absence skips tests' \
	  'fmt                   rewrite every tracked .zig and .py file in format style' \
	  'fmt-python            rewrite the tracked .py files, which zig fmt does not reach' \
	  'fmt-check             what check runs over the same files, without rewriting' \
	  'check                 preflight, zig-version, check-unreleased, check-changelog-history, check-readme, check-help, check-man, fmt-check, the linters, the tests, an optimized build' \
	  'lint                  the version and lock checks, the release inventory, then shellcheck, ruff and yamllint' \
	  'lint-shell            shellcheck over every tracked .sh file' \
	  'lint-ci               shellcheck over the run: steps in the workflows and composite actions' \
	  'lint-python           ruff check and ruff format --check over every tracked .py file' \
	  'lint-yaml             yamllint over every tracked .yml and .yaml file' \
	  'lint-md               the Markdown checks over every tracked .md file, which no other linter reads' \
	  'check-refs            every src/path:line citation in a .md file names the line its symbol is on, and a bare one names a line with code on it' \
	  'check-refs FIX=1      rewrite each stale citation to the line its symbol is on' \
	  'lint-versions         check ruff and yamllint against the versions the gate runs, and that lint-requirements.in names the same' \
	  'lint-versions-selftest check lint-versions refuses each drift it exists to catch, restoring the tree' \
	  'lint-lock             check each lock carries its manifest pins, a hash each, and nothing else' \
	  'check-sbom            run the release inventory over stand-in assets and check what a scanner reads' \
	  'zig-version           check the local zig against the version the release is built with' \
	  'bench AGENTS=...      three coding tasks through each harness' \
	  'gauntlet AGENTS=...   the same gauntlet review on a fresh clone, per harness' \
	  'instructions [CHECK=--check]  retired instructions per unit, against bench/instructions.baseline' \
	  'overhead              startup and first-request cost per harness' \
	  'install               install the binary, man page and license into ~/.local, or PREFIX= and DESTDIR= elsewhere' \
	  'release-assets        cross-build every published target into dist/' \
	  'release-assets TAG=vX.Y.Z  the same, named as release.yml publishes them' \
	  'release-targets       the published target triples, one per line' \
	  'check-assets TAG=...  the assets in dist/ are the ones the tag will publish' \
	  'check-asset-run [TARGET=...]  the published asset for this host, cross-built and started' \
	  'check-binary [OPT=...]  the binary this tree builds, started (what check runs)' \
	  'check-changelog [VERSION=...]  the changelog entry a tag would publish, its shape, and the 0.y policy on it' \
	  'check-changelog-sections  the five Keep a Changelog headings, once each, in order' \
	  'check-changelog-history  the 0.y bump policy over every released section, oldest first' \
	  'check-unreleased      the [Unreleased] entry has the five sections, once each, in order' \
	  'check-changelog-sections SECTION=...  the same five-section shape under one named heading' \
	  'check-changelog-links  every heading has the compare link its version implies' \
	  'check-readme      the README installs and names the version build.zig.zon declares' \
	  'check-help        the usage.md --help block is what --help prints' \
	  'check-man         the man page documents every flag --help lists, as the declared version' \
	  'check-release TAG=vX.Y.Z  the tag names build.zig.zon, nothing is stranded unreleased' \
	  'check-reproducible    every published target rebuilds byte-identical' \
	  'checksums             sha256 sidecars for dist/ (after a tagged build)' \
	  'sbom                  the SPDX inventory of dist/, naming the assets and every declared pin' \
	  'check-checksums      every asset in dist/ has a sidecar naming its own digest' \
	  'sha256-of FILE=<path> the sha256 of one file, through the command checksums wrote with' \
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

# A cross build's own install prefix. Every cross build below names one, because
# they all share zig-out otherwise: zig writes the artifact it just built into
# the one prefix, so the last cross build of a release rehearsal is what is
# sitting in zig-out/bin, and `make install`, `check-binary` and the bench
# scripts read that path as the host build. The binary that survives a
# `make release-assets` there is a macOS Mach-O, and a packager who then ran
# `make install PREFIX=/usr DESTDIR=$pkgdir` would stage a file the machine
# cannot execute. One prefix per target leaves the host build where it belongs.
CROSS_PREFIX ?= .scratch/cross

# The published target that starts on this host, read from uname rather than
# named. The four published targets cover two architectures on two systems, so
# a name written out here is one a third of the hosts cannot run: an Apple
# silicon laptop handed the Linux asset gets an exec format error and reads the
# assets as broken when they are the ones a tag publishes. It is empty on a host
# the release publishes no asset for, which `check-assets` reports as a version
# read that was not taken and `check-asset-run` refuses rather than
# cross-building a binary this machine cannot start.
HOST_OS := $(shell uname -s)
ifeq ($(HOST_OS),Darwin)
HOST_TARGET := $(MUSL_ARCH)-macos
else ifeq ($(HOST_OS),Linux)
HOST_TARGET := $(MUSL_ARCH)-linux-musl
endif

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
	$(ZIG) build -Dtarget=$(MUSL_ARCH)-linux-musl -Doptimize=$(OPT) --prefix $(CROSS_PREFIX)/$(MUSL_ARCH)-linux-musl
	cp $(CROSS_PREFIX)/$(MUSL_ARCH)-linux-musl/bin/microagent $(MUSL_BINARY).tmp
	mv $(MUSL_BINARY).tmp $(MUSL_BINARY)

# A filter that matches no declared test would report success without running one, so it is checked
# against the test names first. Spelled once, because `test` and `watch` take the same filter and a
# filter one of them refuses has to be refused by the other.
REFUSE_UNKNOWN_FILTER = if [ -n "$(FILTER)" ]; then \
	  grep -h -o -E '^test "[^"]+"' $(ZIG_SOURCES) | grep -F -- "$(FILTER)" >/dev/null || { \
	    printf 'no declared test is named like "%s"\n' "$(FILTER)" >&2; \
	    printf "  list the names with: grep -h -o -E '^test \"[^\"]+\"' $(ZIG_SOURCES)\n" >&2; \
	    exit 2; }; \
	fi

test:
	@$(REFUSE_UNKNOWN_FILTER); \
	if [ -n "$(FILTER)" ]; then \
	  $(ZIG) build test -Dtest-filter="$(FILTER)" --summary all; \
	else \
	  $(ZIG) build test --summary all && $(MAKE) test-cli; \
	fi

# Exercise the actual CLI over loopback, without a provider account.
test-cli: build
	python3 scripts/test_cli.py $(BIN)
	python3 bench/test_maxrss.py
	python3 bench/test_limit.py
	python3 bench/test_scripts.py

# The suite again on every source change, until Ctrl-C: the build system's own edit loop, and the
# command a contributor runs all day. It is not what `check` runs, so a green watch is not a push.
# FILTER narrows it to the test being edited, as it does for `test`.
watch:
	@$(REFUSE_UNKNOWN_FILTER); \
	$(ZIG) build test --watch $(if $(FILTER),-Dtest-filter="$(FILTER)") --summary all

# The same tests, compiled with the undefined-behavior sanitizer. The suite
# passing tells a reader the assertions hold, not that no load, store or
# integer operation inside them is out of its bounds or overflows: those are
# silent in a ReleaseSmall build and are what the release assets carry. This is
# a second run of the same tests rather than a second set, so a failure names
# the test the plain run already knows.
test-sanitize:
	$(ZIG) build test-sanitize --summary all

# Every list below is `TRACKED`: the files git has plus the ones it has never
# been told about, minus everything .gitignore excludes. Both halves matter.
# The tracked half is why a glob is not used: a glob names the paths as they
# stand, so a Zig file added outside src/ is formatted by nothing and the gate
# still passes. The untracked half is the same defect one step earlier in the
# life of a change: a file a contributor has written and not yet added is on
# disk and in the build, and `git ls-files` alone names neither it nor its
# formatting, so `make check` is green on the tree that will fail in CI the
# moment the file is committed. `--exclude-standard` keeps every build product
# and scratch tree out of the lists, so a gate run after a build is the same one
# a clean clone gets.
TRACKED = git ls-files --cached --others --exclude-standard

# The Zig sources the test names are read out of, for `test`, and the ones
# `fmt` and `fmt-check` read.
ZIG_SOURCES := $(shell $(TRACKED) '*.zig')
# `zig fmt` formats .zon as well as .zig, and build.zig.zon is where the
# version every release is published from is written down, so it is read by a
# hand edit that nothing checks the shape of. It is listed apart from
# ZIG_SOURCES because that list is also what `test` greps for test names,
# and a manifest has none.
ZON_SOURCES := $(shell $(TRACKED) '*.zon')

# The paths `zig build` reads a compiled artifact out of, named once so
# `check-reproducible` can refuse to compare a build-directory rebuild against a
# working tree that is not what git holds. The tracked half of that question is
# asked over the whole tree, because the copy the comparison builds from is
# every tracked file; the untracked half is asked over these paths, because a
# new file the build reads and git does not name is the one case the tracked
# half cannot see. config.example.toml belongs here rather than under src/
# because build.zig embeds it into the binary, so an edit to it changes the
# bytes of every published asset without changing a line under src/.
BUILD_INPUT_PATHS := src build.zig build.zig.zon config.example.toml integrations

# The Python and YAML the linters read, for the same reason.
PY_SOURCES := $(shell $(TRACKED) '*.py')
YAML_SOURCES := $(shell $(TRACKED) '*.yml' '*.yaml')
# The prose, for the same reason and one more on top of it: it is the only
# tracked file kind nothing else here reads, so a defect in a code fence or a
# trailing space is checked by no target in this file and the gate passes.
MD_SOURCES := $(shell $(TRACKED) '*.md')
# The script's own -f, as a make variable, so the repair a stale citation needs
# is a target a contributor can run: `make check-refs FIX=1` rewrites each to
# the line its symbol is on and prints what it moved. Spelled as `make
# check-refs -f` it would be read as a goal named -f, which is the error make
# reports for a flag where a target belongs.
FIX ?=
# The workflows and composite actions, which `lint-yaml` reads for shape and
# `lint-ci` reads for the shell in their `run:` steps. Listed for the same
# reason as the ones above: a workflow added outside .github/ would be checked
# by nothing and the gate would still pass.
CI_SOURCES := $(shell $(TRACKED) '.github/*.yml' '.github/**/*.yml')

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
# Python, YAML and Markdown around them do, and a shell that only fails when a
# benchmark runs is a shell nobody has read. This list is the whole of the gate
# the workflows run: ci.yml and release.yml both call `make lint` rather than
# repeating the targets, so a linter added here reaches a push and a tag.
# .github/dependabot.yml is the other thing to keep in step, since it decides
# what opens a bump for these.
lint: lint-versions lint-lock check-sbom lint-shell lint-ci lint-python lint-yaml lint-md check-refs

# The gate's own checks live in scripts/, not in recipes here, so shellcheck
# reads them: a recipe is shell nothing lints, and these are the code that
# decides whether the linters are the versions the gate means. The versions and
# the Harbor directory stay here, so this file is still the one place each is
# written down; the scripts take them as arguments. lint-versions.sh is handed
# the Harbor manifest as well as the two versions, because that directory is
# written down here and not a second time inside the script; the linter
# manifest is read by bare name there, like it is below, because it lives at the
# root rather than in a directory. Both are checked against the interpreter
# ruff.toml targets, so a floor raised in one and not the other is a red gate
# rather than two locks resolving for different interpreters.
lint-versions:
	@RUFF_VERSION='$(RUFF_VERSION)' YAMLLINT_VERSION='$(YAMLLINT_VERSION)' sh scripts/lint-versions.sh $(HARBOR_DIR)/requirements.txt

# That lint-versions.sh refuses what it is there to refuse, asked by perturbing
# each file it reads and requiring the gate to go red on it. It is not part of
# lint, because it writes to files lint-versions.sh reads and puts them back,
# and a gate that leaves the tree different from how it found it is one nobody
# trusts. Run it when lint-versions.sh itself changes, which is the only time a
# refusal it was carrying can quietly stop being one: the change that dropped
# the interpreter-floor check left every other check passing, so the gate said
# the same thing about a tree it should have refused.
lint-versions-selftest:
	@RUFF_VERSION='$(RUFF_VERSION)' YAMLLINT_VERSION='$(YAMLLINT_VERSION)' sh scripts/lint-versions-selftest.sh $(HARBOR_DIR)/requirements.txt

# Each dependency set's lock is compared against the manifest it was compiled
# from; what the three checks are is scripts/lint-lock.sh's to say. Both are
# named here rather than derived, so each path is written down once and a lock
# is checked against the manifest it actually came from.
lint-lock:
	@sh scripts/lint-lock.sh lint-requirements.in lint-requirements.txt
	@sh scripts/lint-lock.sh $(HARBOR_DIR)/requirements.txt $(HARBOR_DIR)/requirements.lock

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
# it is given. Enable either per file with a `# shellcheck disable=`, preceded
# by the `# because:` line lint-shell below asks for.
SHELLCHECK_CHECKS := check-set-e-suppressed,check-unassigned-uppercase,deprecate-which,avoid-nullary-conditions,check-extra-masked-returns,quote-safe-variables
SHELLCHECK_OPTS := -x --enable=$(SHELLCHECK_CHECKS)

# A `# because:` line is what stands between a suppression and a finding nobody
# can judge later: it says what the silenced check was protecting, and both
# `lint-shell` and `lint-python` refuse a `# shellcheck disable=` or a `# noqa`
# that no `# because:` line above it covers. Neither linter's directive syntax
# takes a trailing reason (shellcheck parses the rest of the line as more
# checks and fails the directive), and an unmarked comment above a suppression
# is indistinguishable from the comment that explains the code, so the marker
# is what makes the two tellable apart. The scripts carry their suppressions
# today, most of them `# shellcheck disable=SC2086` for a word list that has to
# arrive as several words, and each silences a finding that is still there, so
# this asks a new one to say the same thing the existing ones do. The two in
# release.yml are held to the same rule by lint-ci.
#
# A reason is not what makes a suppression narrow. `# shellcheck disable=` and
# `# shellcheck disable=all` both parse, and a `# because:` line above either
# one satisfies the rule above, so a blanket directive could have arrived with
# its reason written out and the gate would have called it justified. The first
# silences nothing at all; the second silences every check, the six optional
# ones below included, which is a finding nobody can judge later in a much
# worse place. So a directive also has to name what it silences, the way a
# `# noqa` names its rule for ruff's PGH004.
#
# awk, not grep, because the question spans the comment block above a line and
# grep reads a file a line at a time. The marker is matched as three whole
# words after the indentation, so a mention of it in prose does not satisfy it,
# and the scan stops at the first line that is not a comment.

lint-shell:
	@set -eu; \
	files="$$($(TRACKED) '*.sh')"; \
	test -n "$$files" || { echo "no tracked .sh file to lint" >&2; exit 1; }; \
	tmp="$$(mktemp)"; \
	trap 'rm -f "$$tmp"' EXIT; \
	awk 'function why(line,   words) { sub(/^[[:space:]]+/, "", line); return split(line, words, /[[:space:]]+/) >= 3 && words[1] == "#" && words[2] == "because:" && length(words[3]) > 0 } \
	  function unscoped(line,   words, n, i) { sub(/^[[:space:]]*#[[:space:]]*shellcheck[= ]disable=/, "", line); gsub(/[[:space:]]/, "", line); if (line == "") return 1; n = split(line, words, ","); for (i = 1; i <= n; i++) if (words[i] == "" || words[i] == "all") return 1; return 0 } \
	  /^[[:space:]]*#[[:space:]]*shellcheck[= ]disable=/ { if (!marked) print FILENAME ":" FNR ": " $$0; if (unscoped($$0)) print FILENAME ":" FNR ": " $$0 " names no check of its own, and a reason does not make a blanket one narrow"; marked = 0; next } \
	  /^[[:space:]]*#/ { if (why($$0)) marked = 1; next } \
	  { marked = 0 }' $$files > "$$tmp"; \
	test ! -s "$$tmp" || { cat "$$tmp" >&2; \
	  echo "every shellcheck disable is preceded by a '# because:' line saying what it silences, and names the checks it silences:" >&2; \
	  echo "  # because: the include flags hold two words per task and have to arrive as two" >&2; \
	  echo "  # shellcheck disable=SC2086" >&2; \
	  echo "'disable=' and 'disable=all' are refused: the first silences nothing and the second silences every check the gate enables" >&2; \
	  exit 1; }; \
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
	$(TRACKED) -z '*.sh' | xargs -0 shellcheck $(SHELLCHECK_OPTS)

# The shell in the workflows is the same language under the same options, and
# it is where a release is published from, so it is checked rather than
# assumed. The steps are not tracked .sh files, so lint-shell cannot see them;
# this extracts the `run:` bodies and runs the same shellcheck over them. The
# option list is the one above rather than a second spelling, so the two gates
# cannot drift into checking different things.
lint-ci:
	@test -n "$(CI_SOURCES)" || { echo "no tracked workflow to read the run: steps from" >&2; exit 1; }
	SHELLCHECK_OPTS='$(SHELLCHECK_OPTS)' sh scripts/lint-ci-shell.sh $(CI_SOURCES)
	python3 bench/test_scripts.py --workflows

lint-python:
	@test -n "$(PY_SOURCES)" || { echo "no tracked .py file to lint" >&2; exit 1; }
	@set -eu; \
	tmp="$$(mktemp)"; \
	trap 'rm -f "$$tmp"' EXIT; \
	awk 'function why(line,   words) { sub(/^[[:space:]]+/, "", line); return split(line, words, /[[:space:]]+/) >= 3 && words[1] == "#" && words[2] == "because:" && length(words[3]) > 0 } \
	  /# noqa/ { if (!marked) print FILENAME ":" FNR ": " $$0; marked = 0; next } \
	  /^[[:space:]]*#/ { if (why($$0)) marked = 1; next } \
	  { marked = 0 }' $(PY_SOURCES) > "$$tmp"; \
	test ! -s "$$tmp" || { cat "$$tmp" >&2; \
	  echo "every noqa is covered by a '# because:' line saying what it silences:" >&2; \
	  echo "  # because: the name is the one BaseHTTPRequestHandler.log_message declares" >&2; \
	  echo "  def log_message(self, format: str) -> None:  # noqa: A002" >&2; \
	  exit 1; }
	ruff check --config ruff.toml $(PY_SOURCES)
	ruff format --check --config ruff.toml $(PY_SOURCES)

lint-yaml:
	@test -n "$(YAML_SOURCES)" || { echo "no tracked .yml or .yaml file to lint" >&2; exit 1; }
	yamllint -c .yamllint $(YAML_SOURCES)

# The Markdown, which no other target here reads: zig fmt has no opinion on a
# prose file, and the three linters above each cover one language that is not
# this one. It is the largest surface in the tree and carries the install
# command and the configuration surface, so a defect in it is a wrong
# instruction rather than a red test. The gate lives in scripts/ for the reason
# lint-versions above names: a recipe is shell nothing lints.
lint-md:
	@test -n "$(MD_SOURCES)" || { echo "no tracked .md file to lint" >&2; exit 1; }
	sh scripts/lint-md.sh $(MD_SOURCES)

# The `path:line` citations in the Markdown, which name the function behind a
# claim and are the only thing in a prose file that can be wrong without looking
# wrong. They are written by hand beside a diff that moves the function, and
# nothing asked where it ended up: 0.2.0 corrected the ones that were stale then
# and every one of them had drifted again by 0.7.0, a control citing a line
# hundreds above its own body and nine citing updater functions the 0.6.0
# rewrite deleted. A reader following a citation is reading the wrong function,
# so the citation is asked rather than the prose. The gate lives in scripts/ for
# the reason lint-versions names: a recipe is shell nothing lints.
check-refs:
	sh scripts/check-refs-self-test.sh
	sh scripts/check-refs.sh $(if $(FIX),-f) $(MD_SOURCES)

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
	$(MAKE) check-unreleased
	$(MAKE) check-changelog-history
	$(MAKE) check-readme
	$(MAKE) check-help
	$(MAKE) check-man
	$(MAKE) fmt-check
	$(MAKE) lint
	$(MAKE) test
	$(MAKE) test-sanitize
	$(MAKE) check-binary OPT=ReleaseSmall

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

# Where a plain `make install` puts the binary and its man page, and the
# variables a distro or homebrew-style packager needs instead. PREFIX defaults
# to the per-user location the README installs into, so an unpackaged run is
# unchanged, while `make install PREFIX=/usr DESTDIR=$$pkgdir` stages the same
# recipe into a package root. BINDIR, MANDIR and LICENSEDIR default under PREFIX
# and DESTDIR defaults to empty, which is what makes the unprefixed call write to
# the real prefix rather than to a staging directory nobody asked for.
PREFIX ?= $(HOME)/.local
BINDIR ?= $(PREFIX)/bin
MANDIR ?= $(PREFIX)/share/man
LICENSEDIR ?= $(PREFIX)/share/licenses/microagent
DESTDIR ?=

# `install -d -m 755` is one command on GNU coreutils and on BSD install, unlike
# `install -D`, which macOS does not have; the mode is named so a prefix that
# does not exist yet is not created with whatever umask left behind. The man
# page is installed under man1, the section every `man microagent` reaches, and
# it lands next to the binary, because a package that ships an executable with
# no page leaves `man` reading nothing and the reader reading the release notes.
# The license rides with the binary because the formats that carry this recipe
# require it: dpkg and rpm take it as the copyright file, and the per-package
# directory under share/licenses is the FHS place both read. A package built from
# the recipe without it ships a grant the user cannot read.
# The binary is staged beside its destination and renamed into it, the way
# `musl` and `checksums` stage theirs: `install -m755` opens the path it is
# given, so a copy interrupted halfway leaves a truncated executable at the
# name the shell resolves on every later run, and a truncated binary reads as a
# broken install rather than a broken build. A rename is atomic, so the path
# holds the old binary or the new one and never a half of either. The man page
# and the license are copied in place: a truncated page fails to render and a
# truncated grant is still readable text, and a `.tmp` beside them would be a
# file `man` and dpkg's copyright scanner both have to know to skip.
install: build
	install -d -m 755 $(DESTDIR)$(BINDIR)
	install -m755 $(BIN) $(DESTDIR)$(BINDIR)/microagent.tmp
	mv -f $(DESTDIR)$(BINDIR)/microagent.tmp $(DESTDIR)$(BINDIR)/microagent
	install -d -m 755 $(DESTDIR)$(MANDIR)/man1
	install -m644 docs/microagent.1 $(DESTDIR)$(MANDIR)/man1/microagent.1
	install -d -m 755 $(DESTDIR)$(LICENSEDIR)
	install -m644 LICENSE $(DESTDIR)$(LICENSEDIR)/LICENSE

# The man page and `--help` are two renderings of one interface, and the one
# that is wrong is whichever a reader happens to reach first. Every long flag
# the built-in help lists has to be in the page, and the page names the version
# build.zig.zon declares, so a release cannot publish a binary under a man page
# describing the previous one. A flag the page documents that the help does not
# is left alone: a man page may summarize, but a man page that invents an
# option is the failure this cannot catch by reading flags, so the direction
# that can be checked is the one that is checked.
# The block docs/usage.md prints as "microagent --help, verbatim" is a copy of
# the built-in text, and a copy is only worth having if it is the copy. Nothing
# keeps the two together: a flag added to src/main.zig, an exit status added to
# the table, a default that moves, and the page keeps the sentence the last
# release shipped, which is worse than no page because a reader cannot tell
# which of the two the running binary is answering. check-man asks the same
# question of the man page; this asks it of the page most readers open.
check-help: build
	@set -eu; \
	tmp="$$(mktemp -d)"; \
	trap 'rm -rf "$$tmp"' EXIT; \
	awk '/^## Flags and environment$$/{seen=1} seen && /^```$$/{n++; next} n==1' docs/usage.md > "$$tmp/doc" || true; \
	test -s "$$tmp/doc" || { echo "docs/usage.md has no --help block under '## Flags and environment'" >&2; exit 1; }; \
	$(BIN) --help > "$$tmp/help"; \
	if ! cmp -s "$$tmp/doc" "$$tmp/help"; then \
	  echo "docs/usage.md quotes a --help that this build does not print:" >&2; \
	  diff -u "$$tmp/doc" "$$tmp/help" >&2 || true; \
	  echo "the text lives in src/main.zig; copy it into the block rather than editing either side" >&2; \
	  exit 1; \
	fi; \
	echo "docs/usage.md quotes this build's --help verbatim"

check-man: build
	@set -eu; \
	want="$$($(MAKE) --no-print-directory version)"; \
	grep -q '^\.TH MICROAGENT 1 .* "microagent '"$$want"'"' docs/microagent.1 || { \
	  echo "docs/microagent.1 does not name microagent $$want, the version build.zig.zon declares" >&2; \
	  echo "a release would then ship a binary under a man page describing the previous version" >&2; \
	  exit 1; \
	}; \
	for flag in $$($(BIN) --help 2>&1 | sed -n 's/^ *\(-[A-Za-z], \)\{0,1\}--\([a-z0-9-]*\).*/\2/p' | sort -u) \
	             $$($(BIN) update --help 2>&1 | sed -n 's/^ *\(-[A-Za-z], \)\{0,1\}--\([a-z0-9-]*\).*/\2/p' | sort -u); do \
	  tr -d '\\' < docs/microagent.1 | grep -q -e "--$$flag" || { \
	    echo "docs/microagent.1 documents no --$$flag, which 'microagent --help' lists" >&2; \
	    exit 1; \
	  }; \
	done; \
	echo "docs/microagent.1 documents every flag --help lists, as microagent $$want"

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
	@$(MAKE) --no-print-directory check-changelog-links

# The changelog rules release.yml enforces on the tag, and the 0.y policy
# CONTRIBUTING.md states, runnable before the tag exists. They were shell inside
# release.yml, so the policy a contributor writes an entry against could only be
# checked by pushing a tag: a patch carrying an `Added` or a `Security`, a
# section left under [Unreleased] that the tag would drop, and a version with no
# notes at all were all first found by a failed release job rather than by a
# command. The section
# this target publishes is asked for the same shape `check-unreleased` asks of
# the entry being drafted, since by the time a tag names a version heading the
# author who wrote it no longer sees it. VERSION is the version under test and
# defaults to the one build.zig.zon declares, so the
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
	  if printf '%s\n' "$$notes" | grep -q '^### \(Added\|Changed\|Removed\|Security\)$$'; then \
	    echo "$$want is a patch over $$prev, and its section has an Added, a Changed, a Removed or a Security entry" >&2; \
	    echo "under 0.y the minor carries features, anything that changes what a run does by default," >&2; \
	    echo "anything taken away, and anything taken back that was letting text the model or the tree" >&2; \
	    echo "controls through a control: a security fix narrows what an invocation may do as often as it" >&2; \
	    echo "changes an answer, so it is a minor entry too. Bump the minor in build.zig.zon and" >&2; \
	    echo "CHANGELOG.md, or move those entries out" >&2; \
	    exit 1; \
	  fi; \
	fi

# The 0.y rule over every released section, not only the one a tag is about to
# cut. `check-changelog` reads its version from build.zig.zon unless VERSION
# says otherwise, so the moment the next release bumps the minor the section it
# just left is never asked again: an edit that moves an `Added` or a `Security`
# entry into a patch, or drops the `Changed` a minor needs, lands in the
# published history and nothing refuses it. The tag gate cannot catch that one,
# the tag is behind it, and a section that has been published is the one a
# reader has already installed from.
#
# Oldest first, so the failure named is the earliest release a consumer is still
# being pointed at. The section each check prints is dropped: a release
# publishes that text, and here it is eight copies of notes nobody is reading.
# The reason a check fails is on stderr and still shows.
check-changelog-history:
	@set -eu; \
	for v in $$(awk '/^## \[/ { \
	  name = $$0; sub(/^## \[/, "", name); sub(/\].*/, "", name); \
	  if (name ~ /^[0-9]+\.[0-9]+\.[0-9]+$$/) print name \
	}' CHANGELOG.md | sort -V); do \
	  $(MAKE) --no-print-directory check-changelog VERSION=$$v >/dev/null; \
	done

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
	$(MAKE) --no-print-directory check-changelog-links
	$(MAKE) --no-print-directory check-readme

# The link under every heading in CHANGELOG.md is written by hand, and a
# release moves two of them: cutting vX.Y.Z renames the `[Unreleased]` heading
# it was written under and adds the version's own. Nothing else in the file
# carries the repository, so a forgotten line does not fail a build or a tag,
# it publishes notes whose "what changed" link still points at the release
# before the one a reader is reading. The first version has no predecessor to
# compare against, so it is a link naming its own tag instead.
check-changelog-links:
	@awk ' \
	  /^## \[/ { \
	    name = $$0; sub(/^## \[/, "", name); sub(/\].*/, "", name); \
	    order[++n] = name; \
	    if (name ~ /^[0-9]+\.[0-9]+\.[0-9]+$$/ && newest == "") newest = name; \
	    next; \
	  } \
	  /^\[[^]]+\]: / { \
	    name = $$0; sub(/^\[/, "", name); sub(/\].*/, "", name); \
	    link[name] = $$0; sub(/^\[[^]]*\]: /, "", link[name]); \
	    if (base == "" && index(link[name], "/compare/")) { \
	      base = link[name]; sub(/\/compare\/.*$$/, "/compare/", base); \
	    } \
	    next; \
	  } \
	  END { \
	    if (newest == "" || base == "") { \
	      print "CHANGELOG.md has no released version heading or no compare link, so the link references under it cannot be checked" > "/dev/stderr"; \
	      bad = 1; \
	    } \
	    for (i = 1; i <= n; i++) { \
	      name = order[i]; \
	      if (!(name in link)) { \
	        printf("CHANGELOG.md has a \"## [%s]\" heading and no \"[%s]:\" link under it, so the notes a reader opens there are a dead reference\n", name, name) > "/dev/stderr"; \
	        bad = 1; \
	        continue; \
	      } \
	      if (name == "Unreleased") want = base "v" newest "...HEAD"; \
	      else if (order[i + 1] == "Unreleased" || order[i + 1] !~ /^[0-9]+\.[0-9]+\.[0-9]+$$/) { \
	        if (link[name] !~ ("/" "v" name "$$")) { \
	          printf("CHANGELOG.md compares [%s] with %s, which is not a released version, so it links the tag itself instead: [%s]: .../v%s\n", name, order[i + 1], name, name) > "/dev/stderr"; \
	          bad = 1; \
	        } \
	        continue; \
	      } \
	      else want = base "v" order[i + 1] "...v" name; \
	      if (link[name] != want) { \
	        printf("CHANGELOG.md says [%s]: %s, and the next version under it is %s, so it is %s\n", name, link[name], order[i + 1], want) > "/dev/stderr"; \
	        bad = 1; \
	      } \
	    } \
	    exit bad; \
	  } \
	' CHANGELOG.md

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
# host can execute, named by HOST_TARGET. The four published
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
# named by HOST_TARGET rather than written here: an ELF is not runnable on
# Darwin and a Mach-O is not runnable on Linux, so naming the Linux one
# unconditionally made this target fail on both macOS runners and on an arm64
# Linux host with a message about a version that was never read. A host the
# release publishes no
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
	host_os="$(HOST_OS)"; \
	host_target="$(HOST_TARGET)"; \
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

# The binary this tree builds, started. `update` is the one subcommand that
# names the running executable, so both of its paths are worth exercising on a
# real filesystem. It builds at $(OPT) first, so it is runnable on its own from
# a clean tree, and `check-asset-run` asks the same two questions of the
# cross-built asset, so the host build and the published one are never checked
# by different commands.
check-binary: build
	./$(BIN) --version
	./$(BIN) update --help >/dev/null

# The published asset for this host, cross-built and started. ci.yml runs it on
# every push, once per runner that has a published target, and it was the one
# check of that list with no other way to run it: `make check` builds the host's
# own target, which is the same code on the same machine, and `make
# check-assets` reads files `make release-assets` wrote for all four targets,
# which is minutes of work to ask a question about one of them. A Mach-O that
# links but does not start, or an asset that needs a libc its own target does
# not have, fails here rather than on a user's machine.
#
# TARGET names the asset when the caller already knows it, which is how ci.yml
# passes the runner's own row. It is checked against what this host reads
# rather than trusted: a matrix row that drifts from uname would then run one
# asset on a runner meant to check another, and the run would pass on the wrong
# binary.
check-asset-run: zig-version
	@test -n "$(HOST_TARGET)" || { \
	  echo "this host ($(HOST_OS) $(MUSL_ARCH)) is not one the release publishes an asset for:" >&2; \
	  echo "there is no published target to build and run here, so nothing was checked" >&2; \
	  exit 2; \
	}; \
	test -z "$(TARGET)" || test "$(TARGET)" = "$(HOST_TARGET)" || { \
	  echo "TARGET=$(TARGET), but this host ($(HOST_OS) $(MUSL_ARCH)) publishes $(HOST_TARGET)" >&2; \
	  exit 1; \
	}; \
	$(ZIG) build -Dtarget=$(HOST_TARGET) -Doptimize=ReleaseSmall --prefix $(CROSS_PREFIX)/$(HOST_TARGET)
	$(CROSS_PREFIX)/$(HOST_TARGET)/bin/microagent --version
	$(CROSS_PREFIX)/$(HOST_TARGET)/bin/microagent update --help >/dev/null
	@echo "the $(HOST_TARGET) asset builds and starts on this host"

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
#
# A tagged build also carries the LICENSE next to the binaries, under the
# versioned prefix so the glob above and `checksums` both pick it up. The
# release hands a user a bare executable, and the license it is distributed
# under is the one thing about it a user cannot see in the file. A rehearsal
# emits no license asset, because it names nothing by version and the sidecars
# have nothing to describe.
# version a release is published with, for the reason musl names: this is the
# target whose output is published, and a compiler other than the pinned one
# produces an asset no checksum ever described, reproducibly enough to pass
# check-reproducible.
release-assets: zig-version
	rm -rf dist
	mkdir -p dist
	@set -eu; for target in $(RELEASE_TARGETS); do \
		$(ZIG) build -Dtarget="$$target" -Doptimize=ReleaseSmall --prefix "$(CROSS_PREFIX)/$$target"; \
		install -m755 "$(CROSS_PREFIX)/$$target/bin/microagent" "dist/$(ASSET_PREFIX)$$target.tmp"; \
		mv "dist/$(ASSET_PREFIX)$$target.tmp" "dist/$(ASSET_PREFIX)$$target"; \
	done
	@if [ -n "$(TAG)" ]; then \
		install -m644 LICENSE "dist/$(ASSET_PREFIX)LICENSE"; \
	fi

# What the release ships, as an SPDX inventory: the assets with the digest of
# each, and every third-party pin this tree declares with the manifest that
# declares it. Nothing publishes the binaries' contents today, so a consumer who
# wants to know what is in one, and a scanner that wants to know what to match
# a finding against, both have nothing to read but the size of the file. The
# generator is a script rather than a recipe, so shellcheck reads it like the
# rest of the gate, and it takes the manifests as arguments the way
# lint-lock.sh takes the Harbor directory from HARBOR_DIR: the paths are written
# down here and nowhere else.
#
# It runs before `checksums`, so the inventory gets a sidecar like every other
# asset, and it names no version of its own: the version is read out of the
# asset names, because the files in dist/ are what a release publishes. A
# rehearsal emits no inventory, the way it emits no license.
#
# The document carries a creation time, and the generator reads it out of
# SOURCE_DATE_EPOCH when the environment names one and off the wall clock when
# it does not. Nothing named it, so a release published the inventory with the
# minute it was generated in it: the same commit and the same dist/ produce a
# different document on every run, and the sha256 sidecar written beside it
# then describes bytes no second run can produce, which is the property every
# other asset in that directory has and this one did not. The value defaulted
# here is the commit's own author date, so the document is a function of the
# source rather than of when the release was cut, which is what
# reproducible-builds.org means by honoring SOURCE_DATE_EPOCH. A caller that
# sets it, `SOURCE_DATE_EPOCH=... make sbom`, still decides, and an epoch the
# generator cannot convert fails the release rather than falling back to a
# clock.
sbom:
	@test -d dist || { echo "no dist/, run 'make release-assets TAG=v0.2.0' first" >&2; exit 2; }; \
	: "$${SOURCE_DATE_EPOCH:=$$(git log -1 --format=%at)}"; \
	test -n "$$SOURCE_DATE_EPOCH" || { \
	  echo "this tree has no commit, so there is no date to stamp the inventory with" >&2; exit 1; }; \
	SOURCE_DATE_EPOCH="$$SOURCE_DATE_EPOCH" \
	SHA256_CMD="$$($(SHA256_CMD))" SHA1_CMD="$$($(SHA1_CMD))" \
	sh scripts/sbom.sh dist lint-requirements.txt $(HARBOR_DIR)/requirements.lock

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
		line=$$($$sum "$$asset"); \
		digest=$$(printf '%s\n' "$$line" | cut -d' ' -f1); \
		printf '%s  %s\n' "$$digest" "$$asset" > "$$asset.sha256.tmp"; \
		grep -qE '^[0-9a-f]{64}  ' "$$asset.sha256.tmp" || { \
		  echo "$$sum produced no sha256 for $$asset, so the sidecar would name nothing update can verify" >&2; \
		  rm -f "$$asset.sha256.tmp"; \
		  exit 1; \
		}; \
		mv "$$asset.sha256.tmp" "$$asset.sha256"; \
		written=$$((written + 1)); \
	done; \
	test "$$written" -gt 0 || { \
		echo "no tagged assets in dist/, so no sidecar was written: run 'make release-assets TAG=v0.2.0' first" >&2; \
		exit 2; \
	}; \
	echo "wrote $$written sidecars in dist/"

# The digest of one file, hex only, through the same SHA256_CMD `checksums`
# and `check-reproducible` write their lines with. release.yml read back the
# published assets and compared each against the sidecar beside it, and spelled
# `sha256sum` there rather than asking here, which is the second decision about
# which hashing command this host has: on a runner without GNU coreutils the
# sidecars were written by `shasum -a 256` and the comparison beside them by a
# command that does not exist. One line, and the reason SHA256_CMD exists at
# all, applies to the step that checks the sidecars as well as the one that
# writes them.
#
# FILE=, like every other value this Makefile takes (`make check-changelog
# VERSION=`, `make check-asset-run TARGET=`), rather than a bare trailing word:
# a word after the target is a goal to make, so `make sha256-of dist/microagent`
# built a second target and read no file at all.
sha256-of:
	@test -n "$(FILE)" || { printf 'usage: make sha256-of FILE=<path>\n' >&2; exit 2; }; \
	test -f "$(FILE)" || { printf 'no %s, so there is nothing to hash\n' "$(FILE)" >&2; exit 2; }; \
	sum=$$($(SHA256_CMD)); \
	test -n "$$sum" || { \
	  echo "neither sha256sum nor shasum is on PATH, so no digest can be read" >&2; \
	  exit 2; \
	}; \
	digest=$$($$sum "$(FILE)" | cut -d' ' -f1); \
	test -n "$$digest" || { \
	  printf 'no digest could be read from %s\n' "$(FILE)" >&2; \
	  exit 1; \
	}; \
	printf '%s\n' "$$digest"

# The sidecars `checksums` wrote, read back against the assets they sit beside.
# `checksums` counts what it wrote and fails on zero, so a glob, a skip list or a
# hashing command that quietly covers less than dist/ holds passes it: an asset
# shipped with no digest is an asset `microagent update` downloads and cannot
# verify. Nothing else asks. `check-sbom` runs the generator over stand-in
# assets in a temporary directory, so it reads neither dist/ nor the sidecars,
# and the one place the real set is read back is release.yml's last step, which
# runs after the release is public, on a tag whose publish step refuses to
# replace a release a consumer may already have fetched. Both workflows run
# this over their own build instead, before anything is published.
#
# The digest is read through `make sha256-of` rather than a second command
# chosen here, for the reason `SHA256_CMD` exists: on a runner without GNU
# coreutils the sidecar was written by `shasum -a 256` and a comparison beside it
# by a command that does not exist.
#
# `*.tmp` is skipped for the reason `checksums` skips it: an asset or an
# inventory staged beside its final name and renamed into it leaves a `.tmp`
# there when a run is cut short, and the glob below would then read that as an
# asset with no sidecar beside it and refuse a dist/ whose real assets are all
# sidecarred. `make release-assets` empties dist/ first, so the leftover only
# exists within a run that already failed.
check-checksums:
	@set -eu; \
	test -d dist || { echo "no dist/, run 'make release-assets TAG=v0.2.0' first" >&2; exit 2; }; \
	assets=0; \
	for asset in dist/microagent-*; do \
	  test -e "$$asset" || continue; \
	  case "$$asset" in *.sha256 | *.tmp) continue;; esac; \
	  assets=$$((assets + 1)); \
	  if [ ! -f "$$asset.sha256" ]; then \
	    echo "$$asset has no sha256 sidecar beside it, so 'microagent update' cannot verify it" >&2; \
	    exit 1; \
	  fi; \
	  want=$$(cut -d' ' -f1 < "$$asset.sha256"); \
	  got=$$($(MAKE) --no-print-directory sha256-of "FILE=$$asset"); \
	  if [ "$$want" != "$$got" ]; then \
	    echo "$$asset.sha256 names $$want and $$asset hashes to $$got" >&2; \
	    exit 1; \
	  fi; \
	done; \
	test "$$assets" -gt 0 || { \
	  echo "dist/ holds no microagent asset, so there is nothing to have checksummed" >&2; \
	  exit 2; \
	}; \
	echo "all $$assets assets in dist/ carry a sidecar naming the digest of the asset beside it"

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
# leaves behind and a fresh checkout does not. That second cache is the one
# REPRO_GLOBAL names, and it is deliberately a sibling of REPRO_DIR rather than
# a child of it: the two build_once calls between them are what make the second
# build real, and a toolchain cache inside the directory they empty is emptied
# with them, so every one of the nine builds recompiles the standard library
# from cold. The scratch is removed on the way
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
#
# The compiler is checked first, for the reason `musl` names and the three
# targets beside it already carry: this target compares two builds against each
# other, so a laptop on a Zig the release does not use compares that compiler's
# output with itself and every line it prints is true of a binary nothing
# publishes. The runners install the pinned version through setup-zig, so the
# check costs them one `zig version`; on a laptop it is the difference between
# a reproducibility result about the release and one about whatever the host had.
check-reproducible: zig-version
	@set -eu; \
	test -n "$(RELEASE_TARGETS)" || { echo "no RELEASE_TARGETS to check" >&2; exit 1; }; \
	sum=$$($(SHA256_CMD)); \
	test -n "$$sum" || { \
	  echo "neither sha256sum nor shasum is on PATH, so a rebuild cannot be compared" >&2; \
	  exit 2; \
	}; \
	REPRO_SRC=$(REPRO_DIR)-src; \
	trap 'rm -rf "$(REPRO_DIR)" "$$REPRO_SRC" "$(REPRO_GLOBAL)"' EXIT; \
	rm -rf "$(REPRO_GLOBAL)"; \
	build_once() { \
	  rm -rf "$(REPRO_DIR)"; \
	  SOURCE_DATE_EPOCH="$$1" LC_ALL="$$2" TZ="$$3" ZIG_GLOBAL_CACHE_DIR="$(REPRO_GLOBAL)" $(ZIG) build \
	    -Dtarget="$$4" -Doptimize=ReleaseSmall \
	    --cache-dir "$(REPRO_DIR)/cache" -p "$(REPRO_DIR)/out"; \
	  test -f "$(REPRO_DIR)/out/bin/microagent"; \
	  digest=$$($$sum "$(REPRO_DIR)/out/bin/microagent" | cut -d' ' -f1); \
	  test -n "$$digest"; \
	  printf '%s\n' "$$digest"; \
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
	  (cd "$$srcdir" && SOURCE_DATE_EPOCH="$$1" LC_ALL="$$2" TZ="$$3" ZIG_GLOBAL_CACHE_DIR="$(REPRO_GLOBAL)" $(ZIG) build \
	    -Dtarget="$$4" -Doptimize=ReleaseSmall \
	    --cache-dir "$(REPRO_DIR)/cache" -p "$(REPRO_DIR)/out2"); \
	  test -f "$(REPRO_DIR)/out2/bin/microagent"; \
	  digest=$$($$sum "$(REPRO_DIR)/out2/bin/microagent" | cut -d' ' -f1); \
	  test -n "$$digest"; \
	  printf '%s\n' "$$digest"; \
	}; \
	for target in $(RELEASE_TARGETS); do \
	  first=$$(build_once 1700000000 C UTC "$$target"); \
	  second=$$(build_once 1800000000 C.UTF-8 Asia/Tokyo "$$target"); \
	  if [ "$$first" != "$$second" ]; then \
	    echo "rebuild of $$target differs: $$first != $$second" >&2; \
	    exit 1; \
	  fi; \
	  if [ "$$target" = "$(firstword $(RELEASE_TARGETS))" ]; then \
	    dirty="$$(git diff --name-only HEAD --; git ls-files --others --exclude-standard -- $(BUILD_INPUT_PATHS))"; \
	    if [ -n "$$dirty" ]; then \
	      echo "skipping the build-directory comparison: this working tree is not what git holds" >&2; \
	      printf '%s\n' "$$dirty" >&2; \
	      echo "the copy above is made from git, so it would compare two different sources and" >&2; \
	      echo "report a build path reaching the binary when the source is what differs" >&2; \
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
	rm -rf "$(REPRO_DIR)" "$$REPRO_SRC" "$(REPRO_GLOBAL)"

# The release inventory, run over a directory of stand-in assets. Nothing in
# the tree reads the file a release writes, and nothing builds a tagged one
# before the tag, so without this the only thing that would catch a broken
# generator is a consumer scanning a published release. What is asserted is
# what a scanner reads: that the document parses as JSON, that it names the
# assets that are there with the digest of each, and that it carries a package
# for every pin the two manifests declare, so a manifest a release adds is an
# inventory that has to be regenerated rather than one that quietly omits it.
#
# The assets are two files named as a tagged build names them, written into a
# scratch directory the recipe removes, so the real dist/ and the toolchain a
# release needs are not part of it. python3 parses the JSON and nothing else
# needs it: the rest is grep, so the check runs where the linters run.
#
# Two more fields a scanner reads are recomputed rather than read back. The SPDX
# verification code is the SHA1 of the assets' SHA1 digests concatenated in
# file-name order, so a generator that emitted the field with anything in it, or
# with the digests in another order, is caught here. The declared license is
# the one LICENSE's first line names, taken over the package and every file with
# the pins' NOASSERTION left out and sort -u collapsing the rest, so a single
# line is left only when the document and the tree agree on the grant. The role
# each pin carries is the third count: a pin the document records as declared is
# one the manifests record as a root, so the ninety the benchmark harness pulls
# in cannot be described as direct dependencies of the tree.
check-sbom:
	@set -eu; \
	dir="$$(mktemp -d)"; \
	trap 'rm -rf "$$dir"' EXIT; \
	for name in microagent-v0.0.0-x86_64-linux-musl microagent-v0.0.0-LICENSE; do \
	  printf 'a stand-in for %s\n' "$$name" > "$$dir/$$name"; \
	done; \
	SHA256_CMD="$$($(SHA256_CMD))" SHA1_CMD="$$($(SHA1_CMD))" \
	  sh scripts/sbom.sh "$$dir" lint-requirements.txt $(HARBOR_DIR)/requirements.lock >/dev/null; \
	doc="$$dir/microagent-v0.0.0.spdx.json"; \
	test -f "$$doc" || { echo "the generator wrote no $doc" >&2; exit 1; }; \
	python3 -m json.tool "$$doc" >/dev/null || { echo "$doc is not JSON" >&2; exit 1; }; \
	for name in microagent-v0.0.0-x86_64-linux-musl microagent-v0.0.0-LICENSE; do \
	  grep -q "\"fileName\": \"$$name\"" "$$doc" || { echo "$$doc does not name $$name" >&2; exit 1; }; \
	  want="$$($(MAKE) --no-print-directory sha256-of "FILE=$$dir/$$name")"; \
	  grep -q "\"checksumValue\": \"$$want\"" "$$doc" || { echo "$$doc records no digest of $$name" >&2; exit 1; }; \
	done; \
	code="$$(for name in microagent-v0.0.0-LICENSE microagent-v0.0.0-x86_64-linux-musl; do \
		$$($(SHA1_CMD)) "$$dir/$$name" | cut -d' ' -f1; done | tr -d '\n' | $$($(SHA1_CMD)) | cut -d' ' -f1)"; \
	recorded="$$(sed -n 's/.*"packageVerificationCodeValue": "\([0-9a-f]*\)".*/\1/p' "$$doc")"; \
	test "$$recorded" = "$$code" || { \
	  echo "$$doc records the verification code as '$$recorded' and the stand-in assets hash to '$$code'" >&2; \
	  exit 1; \
	}; \
	declared="$$(sed -n 's/.*"licenseDeclared": "\([A-Za-z0-9.-]*\)".*/\1/p' "$$doc" | grep -v '^NOASSERTION$$' | sort -u)"; \
	wanted="$$(sed -n '1{s/[[:space:]]*[Ll]icen[cs]e[[:space:]]*$$//;p;}' LICENSE)"; \
	test "$$declared" = "$$wanted" || { \
	  echo "$$doc declares '$$declared' where LICENSE names '$$wanted'" >&2; \
	  exit 1; \
	}; \
	pins="$$(awk '/^[A-Za-z0-9_.-]+==/ { print $$1 }' lint-requirements.txt $(HARBOR_DIR)/requirements.lock | sort -u | wc -l)"; \
	named="$$(grep -c '"referenceLocator": "pkg:pypi/' "$$doc")"; \
	test "$$pins" -eq "$$named" || { \
	  echo "the manifests pin $$pins packages and $$doc names $$named of them" >&2; \
	  exit 1; \
	}; \
	declared_pins="$$(grep -c '"comment": "Declared in ' "$$doc")"; \
	roots="$$(awk '/^[A-Za-z0-9_.-]+==/ { print $$1 }' lint-requirements.in $(HARBOR_DIR)/requirements.txt | sort -u | wc -l)"; \
	test "$$declared_pins" -eq "$$roots" || { \
	  echo "$$doc records $$declared_pins pins as declared where the manifests record $$roots as their roots: the role each pin carries is read out of the manifests, so a pin described as a direct dependency is one the manifest does not name" >&2; \
	  exit 1; \
	}; \
	echo "$$doc names both stand-in assets with their digests and all $$pins declared pins"

clean:
	rm -rf zig-out .zig-cache dist $(CROSS_PREFIX) $(HARBOR_DIR)/microagent-*-linux-musl $(HARBOR_DIR)/microagent-*-linux-musl.tmp
