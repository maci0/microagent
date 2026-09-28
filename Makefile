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

.PHONY: default help build small musl test test-one fmt fmt-python lint lint-versions print-lint-versions lint-shell lint-python lint-yaml check bench overhead install release-assets checksums clean
.PHONY: default help build small musl test test-one fmt fmt-python lint lint-versions print-lint-versions lint-shell lint-python lint-yaml check bench overhead install release-assets checksums clean

# The targets `microagent update` asks for, in the names release.yml publishes.
# ci.yml rehearses the same list on every push and release.yml publishes it, so
# the list and the asset names are spelled once, here.
RELEASE_TARGETS := x86_64-linux-musl aarch64-linux-musl x86_64-macos aarch64-macos
# A rehearsal leaves TAG empty; a release passes TAG=v0.2.0.
ASSET_PREFIX = microagent-$(if $(TAG),$(TAG)-)

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

# `make check` is what CI runs; run it before pushing.
help:
	@printf '%s\n' \
	  'help                  this list' \
	  'build                 zig build -Doptimize=$(OPT) -> $(BIN)' \
	  'small                 ReleaseSmall binary' \
	  'musl                  static musl binary for integrations/harbor' \
	  'test                  the whole unit test suite' \
	  'test-one FILTER=...   only tests whose name contains FILTER' \
	  'fmt                   rewrite src, build.zig and the Harbor adapter in format style' \
	  'check                 fmt --check, the linters, the tests, an optimized build' \
	  'lint                  shellcheck, ruff, and yamllint over the non-Zig sources' \
	  'lint-versions         check ruff and yamllint against the versions the gate runs' \
	  'bench AGENTS=...      three coding tasks through each harness' \
	  'overhead              startup and first-request cost per harness' \
	  'install               install the binary into ~/.local/bin' \
	  'release-assets        cross-build every published target into dist/' \
	  'release-assets TAG=vX.Y.Z  the same, named as release.yml publishes them' \
	  'checksums             sha256 sidecars for dist/ (after a tagged build)' \
	  'clean                 remove zig-out and .zig-cache'

build:
	$(ZIG) build -Doptimize=$(OPT)

# Smallest binary that still runs the same code (~720 KB).
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
lint: lint-versions lint-shell lint-python lint-yaml

# A version mismatch is reported by name rather than surfacing later as a
# formatting diff no one can explain, so the message says what to install.
lint-versions:
	@set -e; \
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

lint-shell:
	shellcheck -x bench/*.sh bench/tasks/*/*.sh

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
# has nothing to checksum and says so. GNU coreutils has sha256sum and macOS
# ships shasum under another name; both print the `<hex>  <name>` line
# src/update.zig reads, and a host with neither is told so rather than left
# without the sidecars an update cannot verify. The chosen spelling is unquoted
# so `shasum -a 256` arrives as two words.
checksums:
	@test -d dist || { echo "no dist/, run 'make release-assets TAG=v0.2.0' first" >&2; exit 2; }
	cd dist && set -e && \
	if command -v sha256sum >/dev/null 2>&1; then sum=sha256sum; \
	elif command -v shasum >/dev/null 2>&1; then sum="shasum -a 256"; \
	else \
		echo "neither sha256sum nor shasum is on PATH, so the sidecars update verifies cannot be written" >&2; \
		exit 2; \
	fi; \
	for asset in microagent-v*; do \
		case "$$asset" in *.sha256) continue;; esac; \
		test -e "$$asset" || { \
			echo "no tagged assets in dist/, run 'make release-assets TAG=v0.2.0' first" >&2; \
			exit 2; \
		}; \
		$$sum "$$asset" > "$$asset.sha256"; \
	done

clean:
	rm -rf zig-out .zig-cache
