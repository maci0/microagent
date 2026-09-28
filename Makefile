# Zig invocations are spelled out so the same commands work without make.
ZIG ?= zig
OPT ?= ReleaseFast
BIN := zig-out/bin/microagent

# A recipe that fails mid-copy leaves no half-written target behind, so a later
# run cannot install or benchmark a truncated binary.
.DELETE_ON_ERROR:

.PHONY: help build small musl test test-one fmt fmt-python lint lint-shell lint-python lint-yaml check bench overhead install release-assets checksums clean

# The targets `microagent update` asks for, in the names release.yml publishes.
# ci.yml rehearses the same list on every push and release.yml publishes it, so
# the list and the asset names are spelled once, here.
RELEASE_TARGETS := x86_64-linux-musl aarch64-linux-musl x86_64-macos aarch64-macos
# A rehearsal leaves TAG empty; a release passes TAG=v0.2.0.
ASSET_PREFIX = microagent-$(if $(TAG),$(TAG)-)

# `make check` is what CI runs; run it before pushing.
help:
	@printf '%s\n' \
	  'build                 zig build -Doptimize=$(OPT) -> $(BIN)' \
	  'small                 ReleaseSmall binary' \
	  'musl                  static musl binary for integrations/harbor' \
	  'test                  the whole unit test suite' \
	  'test-one FILTER=...   only tests whose name contains FILTER' \
	  'fmt                   rewrite src, build.zig and the Harbor adapter in format style' \
	  'check                 fmt --check, the linters, and the tests, the CI gate' \
	  'lint                  shellcheck, ruff, and yamllint over the non-Zig sources' \
	  'bench AGENTS=...      three coding tasks through each harness' \
	  'overhead              startup and first-request cost per harness' \
	  'install               install the binary into ~/.local/bin' \
	  'release-assets        cross-build every published target into dist/' \
	  'release-assets TAG=vX.Y.Z  the same, named as release.yml publishes them' \
	  'checksums             sha256 sidecars for dist/ (after a tagged build)' \
	  'clean                 remove zig-out and .zig-cache'

build:
	$(ZIG) build -Doptimize=$(OPT)

# Smallest binary that still runs the same code (~600 KB).
small:
	$(ZIG) build -Doptimize=ReleaseSmall

# Static musl binary for running inside containers (Harbor benchmarks).
musl:
	$(ZIG) build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseFast
	cp $(BIN) integrations/harbor/microagent-x86_64-linux-musl

test:
	$(ZIG) build test --summary all

test-one:
	@test -n "$(FILTER)" || { printf 'usage: make test-one FILTER=<test name substring>\n' >&2; exit 2; }
	$(ZIG) build test -Dtest-filter="$(FILTER)" --summary all

fmt:
	$(ZIG) fmt src build.zig
	$(MAKE) fmt-python

fmt-python:
	ruff format --config ruff.toml integrations/harbor

# The Zig sources have no linter beyond zig fmt, which check runs; the shell,
# Python and YAML around them do, and a shell that only fails when a benchmark
# runs is a shell nobody has read. Keep these in step with
# .github/workflows/ci.yml.
lint: lint-shell lint-python lint-yaml

lint-shell:
	shellcheck -x bench/*.sh bench/tasks/*/*.sh

lint-python:
	ruff check --config ruff.toml integrations/harbor
	ruff format --check --config ruff.toml integrations/harbor

lint-yaml:
	yamllint -c .yamllint .github/workflows/ .github/actions/

# The CI gate, so a formatting, lint or test failure shows up here rather than
# after a push. Keep these in step with .github/workflows/ci.yml.
check:
	$(ZIG) fmt --check src build.zig
	$(MAKE) lint
	$(ZIG) build test --summary all

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

# `install -D` is GNU coreutils; macOS ships BSD install, so the parent
# directory is created here instead.
install: build
	mkdir -p $(HOME)/.local/bin
	install -m755 $(BIN) $(HOME)/.local/bin/microagent

# Every published target, cross-built, under the name release.yml publishes and
# update.zig asks for. Running it without TAG is the rehearsal ci.yml does on
# every push; `make release-assets TAG=v0.2.0` produces the released names, so
# a release can be built on a laptop exactly as the tag builds it.
release-assets:
	mkdir -p dist
	@set -e; for target in $(RELEASE_TARGETS); do \
		$(ZIG) build -Dtarget="$$target" -Doptimize=ReleaseSmall; \
		install -m755 $(BIN) "dist/$(ASSET_PREFIX)$$target"; \
	done

# The sha256 sidecar `microagent update` verifies before it replaces anything.
# Only a tagged build names its assets after a version, so a rehearsal in dist/
# has nothing to checksum and says so.
checksums:
	@test -d dist || { echo "no dist/, run 'make release-assets TAG=v0.2.0' first" >&2; exit 2; }
	cd dist && set -e && for asset in microagent-v*; do \
		case "$$asset" in *.sha256) continue;; esac; \
		test -e "$$asset" || { \
			echo "no tagged assets in dist/, run 'make release-assets TAG=v0.2.0' first" >&2; \
			exit 2; \
		}; \
		sha256sum "$$asset" > "$$asset.sha256"; \
	done

clean:
	rm -rf zig-out .zig-cache
