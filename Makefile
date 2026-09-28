# Zig invocations are spelled out so the same commands work without make.
ZIG ?= zig
OPT ?= ReleaseFast
BIN := zig-out/bin/microagent

.PHONY: build small test fmt bench install clean

build:
	$(ZIG) build -Doptimize=$(OPT)

# Smallest binary that still runs the same code (~600 KB).
small:
	$(ZIG) build -Doptimize=ReleaseSmall

test:
	$(ZIG) build test --summary all

fmt:
	$(ZIG) fmt src build.zig

# Three coding tasks through the selected harnesses; see bench/run.sh.
bench: build
	sh bench/run.sh microagent

# Startup latency and first-request cost per installed harness.
overhead:
	sh bench/overhead.sh

install: build
	install -Dm755 $(BIN) $(HOME)/.local/bin/microagent

clean:
	rm -rf zig-out .zig-cache
