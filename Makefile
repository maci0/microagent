# Zig invocations are spelled out so the same commands work without make.
ZIG ?= zig
OPT ?= ReleaseFast
BIN := zig-out/bin/microagent

.PHONY: help build small musl test test-one fmt check bench overhead install clean

# `make check` is what CI runs; run it before pushing.
help:
	@printf '%s\n' \
	  'build                 zig build -Doptimize=$(OPT) -> $(BIN)' \
	  'small                 ReleaseSmall binary' \
	  'musl                  static musl binary for integrations/harbor' \
	  'test                  the whole unit test suite' \
	  'test-one FILTER=...   only tests whose name contains FILTER' \
	  'fmt                   rewrite src and build.zig in zig fmt style' \
	  'check                 fmt --check plus the tests, the CI gate' \
	  'bench AGENTS=...      three coding tasks through each harness' \
	  'overhead              startup and first-request cost per harness' \
	  'install               install the binary into ~/.local/bin' \
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

# The CI gate, so a formatting or test failure shows up here rather than after
# a push. Keep these in step with .github/workflows/ci.yml.
check:
	$(ZIG) fmt --check src build.zig
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

clean:
	rm -rf zig-out .zig-cache
