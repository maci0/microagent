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

.PHONY: default help preflight version build small musl test test-one watch fmt fmt-python lint lint-versions lint-lock zig-version required-zig-version release-targets check-targets check-reproducible lint-shell lint-python lint-yaml check bench instructions overhead install release-assets checksums clean

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
PREFLIGHT_TOOLS := $(ZIG) shellcheck ruff yamllint
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
	    *) \
	      echo "$$tool is not on PATH" >&2 ;; \
	  esac; \
	done; \
	test "$$bad" -eq 0

# `make check` is what CI runs; run it before pushing.
help:
	@printf '%s\n' \
	  'help                  this list' \
	  'build                 zig build -Doptimize=$(OPT) -> $(BIN)' \
	  'small                 ReleaseSmall binary' \
	  'musl                  static musl binary for integrations/harbor, for this host ($(MUSL_ARCH))' \
	  'version               the version build.zig.zon declares' \
	  'test                  the whole unit test suite' \
	  'test-one FILTER=...   only tests whose name contains FILTER' \
	  'watch [FILTER=...]    rerun the suite on every source change, until Ctrl-C' \
	  'preflight             name every tool check and lint need that is not on PATH' \
	  'fmt                   rewrite src, build.zig and the Harbor adapter in format style' \
	  'check                 preflight, zig-version, fmt --check, the linters, the tests, an optimized build' \
	  'lint                  the pin checks, then shellcheck, ruff and yamllint' \
	  'lint-versions         check ruff and yamllint against the versions the gate runs' \
	  'lint-lock             check the Harbor requirements.txt pins are the ones requirements.lock has' \
	  'zig-version           check the local zig against the version the release is built with' \
	  'bench AGENTS=...      three coding tasks through each harness' \
	  'instructions [CHECK=--check]  retired instructions per unit of work, per path' \
	  'overhead              startup and first-request cost per harness' \
	  'install               install the binary into ~/.local/bin' \
	  'release-assets        cross-build every published target into dist/' \
	  'release-assets TAG=vX.Y.Z  the same, named as release.yml publishes them' \
	  'release-targets       the published target triples, one per line' \
	  'check-targets         every published target is one `update` asks for' \
	  'check-reproducible    every published target rebuilds byte-identical' \
	  'checksums             sha256 sidecars for dist/ (after a tagged build)' \
	  'required-zig-version  the zig version build.zig.zon declares' \
	  'clean                 remove zig-out and .zig-cache'

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

# Smallest binary that still runs the same code (~760 KB).
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
musl:
	$(ZIG) build -Dtarget=$(MUSL_ARCH)-linux-musl -Doptimize=ReleaseFast
	cp $(BIN) $(MUSL_BINARY).tmp
	mv $(MUSL_BINARY).tmp $(MUSL_BINARY)

test:
	$(ZIG) build test --summary all

# The Zig sources the test names are read out of, for `test-one`.
ZIG_SOURCES := $(wildcard src/*.zig)

test-one:
	@test -n "$(FILTER)" || { printf 'usage: make test-one FILTER=<test name substring>\n' >&2; exit 2; }
	@grep -h -o -E '^test "[^"]+"' $(ZIG_SOURCES) | grep -F -q -- "$(FILTER)" || { \
	  printf 'no test declared in src/ is named like "%s"\n' "$(FILTER)" >&2; \
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
	    printf 'no test declared in src/ is named like "%s"\n' "$(FILTER)" >&2; \
	    printf 'the watch below would report success without running a test; list the names with:\n' >&2; \
	    printf "  grep -h -o -E '^test \"[^\"]+\"' $(ZIG_SOURCES)\n" >&2; \
	    exit 2; }; \
	  $(ZIG) build test -Dtest-filter="$(FILTER)" --watch --summary all; \
	else \
	  $(ZIG) build test --watch --summary all; \
	fi

fmt:
	$(ZIG) fmt src build.zig
	$(MAKE) fmt-python

fmt-python:
	ruff format --config ruff.toml integrations/harbor

# The Zig sources have no linter beyond zig fmt, which check runs; the shell,
# Python and YAML around them do, and a shell that only fails when a benchmark
# runs is a shell nobody has read. Keep these in step with
# .github/workflows/ci.yml.
lint: lint-versions lint-lock lint-shell lint-python lint-yaml

# A version mismatch is reported by name rather than surfacing later as a
# formatting diff no one can explain, so the message says what to install.
lint-versions:
	@set -eu; \
	have_ruff="$$(ruff --version | awk '{print $$2}')"; \
	have_yamllint="$$(yamllint --version | awk '{print $$NF}')"; \
	bad=0; \
	[ "$$have_ruff" = "$(RUFF_VERSION)" ] || { \
	  echo "ruff $$have_ruff, the gate runs $(RUFF_VERSION): install it with 'uv tool install ruff@$(RUFF_VERSION)'" >&2; bad=1; }; \
	[ "$$have_yamllint" = "$(YAMLLINT_VERSION)" ] || { \
	  echo "yamllint $$have_yamllint, the gate runs $(YAMLLINT_VERSION): install it with 'uv tool install yamllint==$(YAMLLINT_VERSION)'" >&2; bad=1; }; \
	ruff_pin="$$(sed -n 's/^ruff==\([^ ]*\).*/\1/p' lint-requirements.txt)"; \
	yamllint_pin="$$(sed -n 's/^yamllint==\([^ ]*\).*/\1/p' lint-requirements.txt)"; \
	{ [ "$$ruff_pin" = "$(RUFF_VERSION)" ] && [ "$$yamllint_pin" = "$(YAMLLINT_VERSION)" ]; } || { \
	  echo "lint-requirements.txt pins ruff==$$ruff_pin and yamllint==$$yamllint_pin, not $(RUFF_VERSION) and $(YAMLLINT_VERSION): CI installs that file, so a bump here has to bump the Makefile too" >&2; bad=1; }; \
	test "$$bad" -eq 0

# The Harbor adapter is the one dependency set here with a manifest and a lock
# that no check compares. requirements.txt is one pin; requirements.lock is uv's
# output from it. A lock left behind from an earlier pin still installs, still
# hashes every artifact, and still runs the adapter, so the Harbor release a
# score in BENCHMARK.md was measured against stops being the one the pin names
# and nothing fails until a number is quietly incomparable. The lock is
# generated, so it is read here and never written: the two checks are that every
# pin in the manifest is in the lock at the same version, and that no lock entry
# arrives without a hash, which is what an artifact installed unverified would
# be. Regenerating is the `uv pip compile` at the top of requirements.txt.
HARBOR_DIR := integrations/harbor
lint-lock:
	@set -eu; \
	manifest="$(HARBOR_DIR)/requirements.txt"; \
	lock="$(HARBOR_DIR)/requirements.lock"; \
	for file in "$$manifest" "$$lock"; do \
	  test -f "$$file" || { echo "no $$file, so the Harbor adapter's dependency set is undeclared" >&2; exit 1; }; \
	done; \
	bad=0; \
	for pin in $$(sed -n 's/^\([A-Za-z0-9_.-]*==[^ ]*\).*/\1/p' "$$manifest"); do \
	  grep -q "^$$pin " "$$lock" || { \
	    echo "$$manifest pins $$pin, which $$lock does not: the lock is older than the pin, so a benchmark would run against a Harbor the manifest no longer names" >&2; \
	    echo "regenerate it with the 'uv pip compile' at the top of $$manifest" >&2; \
	    bad=1; \
	  }; \
	done; \
	grep -q -- '-r integrations/harbor/requirements.txt' "$$lock" || { \
	  echo "$$lock records no root from $$manifest, so it was not generated from it" >&2; \
	  bad=1; \
	}; \
	unhashed="$$(awk '/^[A-Za-z0-9_.-]+==/ { if (name != "" && hashes == 0) print name; name = $$1; sub(/==.*/, "", name); hashes = 0; next } /--hash=sha256:/ { hashes++ } END { if (name != "" && hashes == 0) print name }' "$$lock")"; \
	if [ -n "$$unhashed" ]; then \
	  echo "$$lock has entries with no --hash=sha256, which uv installs without verifying them:" >&2; \
	  echo "$$unhashed" >&2; \
	  bad=1; \
	fi; \
	test "$$bad" -eq 0

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
lint-shell:
	@set -eu; \
	git ls-files -z '*.sh' | xargs -0 shellcheck -x

lint-python:
	ruff check --config ruff.toml integrations/harbor
	ruff format --check --config ruff.toml integrations/harbor

lint-yaml:
	yamllint -c .yamllint .github/workflows/ .github/actions/

# The CI gate, so a formatting, lint or test failure shows up here rather than
# after a push. Keep these in step with .github/workflows/ci.yml. The release
# job's cross builds are the one part CI does that this does not: they are
# minutes of work, and `make release-assets` runs them.
check:
	$(MAKE) preflight
	$(MAKE) zig-version
	$(MAKE) check-targets
	$(ZIG) fmt --check src build.zig
	$(MAKE) lint
	$(ZIG) build test --summary all
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

# Retired instructions per unit of work, per path a run walks. Not in `check`:
# it needs Linux `perf`, and a gate that cannot measure on a macOS laptop or a
# runner with the counters off is a gate that fails for reasons unrelated to
# the code. `CHECK=--check` compares each row against bench/instructions.baseline
# and exits 1 when a row leaves its band, 2 when it cannot be measured. The
# script builds its own test binaries, so the build a fresh clone owes it is
# here rather than as a reminder in the error it would otherwise print.
instructions: build
	sh bench/instructions.sh $(CHECK)

# Startup latency and first-request cost per installed harness.
overhead: build
	PATH="$(BIN_DIR):$$PATH" sh bench/overhead.sh

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
check-targets:
	@set -eu; \
	for target in $(RELEASE_TARGETS); do \
		grep -q -- "$$target" src/update.zig || { \
		  echo "$$target is published here but src/update.zig never asks for it, so no update can install it" >&2; \
		  exit 1; }; \
	done

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
release-assets:
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
	cd dist && set -eu && \
	sum=$$($(SHA256_CMD)); \
	test -n "$$sum" || { \
		echo "neither sha256sum nor shasum is on PATH, so the sidecars update verifies cannot be written" >&2; \
		exit 2; \
	}; \
	for asset in microagent-v*; do \
		case "$$asset" in *.sha256|*.tmp) continue;; esac; \
		test -e "$$asset" || { \
			echo "no tagged assets in dist/, run 'make release-assets TAG=v0.2.0' first" >&2; \
			exit 2; \
		}; \
		$$sum "$$asset" > "$$asset.sha256.tmp"; \
		mv "$$asset.sha256.tmp" "$$asset.sha256"; \
	done

# Two independent builds of the same source must be byte-identical, or a
# released checksum describes one binary and a rebuild produces another. Every
# published target is checked, not one: two of the four assets are macOS
# binaries, and a host-specific timestamp or path leaking into a cross build
# would pass a check that only built the Linux one. The target list is the one
# `release-assets` builds, so a new target cannot ship without a reproducibility
# check of its own.
#
# Each build gets a cache and a prefix of its own, and the previous pair is
# removed first, so the second is a real build rather than a cache hit. The
# clock, timezone and locale are varied between the two, so a timestamp or a
# locale-dependent ordering leaking into the binary fails here rather than on a
# consumer's machine. ci.yml runs it on every push and release.yml runs it on
# the tag, so a release is never published from a commit that has not passed it.
check-reproducible:
	@set -eu; \
	test -n "$(RELEASE_TARGETS)" || { echo "no RELEASE_TARGETS to check" >&2; exit 1; }; \
	sum=$$($(SHA256_CMD)); \
	test -n "$$sum" || { \
	  echo "neither sha256sum nor shasum is on PATH, so a rebuild cannot be compared" >&2; \
	  exit 2; \
	}; \
	build_once() { \
	  rm -rf "$(REPRO_DIR)"; \
	  SOURCE_DATE_EPOCH="$$1" LC_ALL="$$2" TZ="$$3" $(ZIG) build \
	    -Dtarget="$$4" -Doptimize=ReleaseSmall \
	    --cache-dir "$(REPRO_DIR)/cache" -p "$(REPRO_DIR)/out"; \
	  $$sum "$(REPRO_DIR)/out/bin/microagent" | cut -d' ' -f1; \
	}; \
	for target in $(RELEASE_TARGETS); do \
	  first=$$(build_once 1700000000 C UTC "$$target"); \
	  second=$$(build_once 1800000000 C.UTF-8 Asia/Tokyo "$$target"); \
	  if [ "$$first" != "$$second" ]; then \
	    echo "rebuild of $$target differs: $$first != $$second" >&2; \
	    exit 1; \
	  fi; \
	  echo "$$target rebuilds to $$first"; \
	done; \
	rm -rf "$(REPRO_DIR)"

clean:
	rm -rf zig-out .zig-cache
