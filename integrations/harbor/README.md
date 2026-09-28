# Running microagent on Harbor benchmarks

[Harbor](https://github.com/laude-institute/harbor) runs containerized agent
benchmarks (Terminal-Bench 2, SWE-bench Verified, aider-polyglot, ...). This
directory holds the adapter that lets Harbor drive microagent.

microagent is a static binary with its own shell and file tools, so it runs
*inside* the task container, where the task's files already are. The adapter
uploads it, then runs one non-interactive turn with the task instruction.

## Build the binary

```sh
make musl
```

That is the same two commands spelled in the
[Makefile](../../Makefile): `zig build -Dtarget=<host arch>-linux-musl
-Doptimize=ReleaseFast`, then the binary copied to
`microagent-<host arch>-linux-musl` next to the adapter, which is the name
`binary_path()` below looks for. The architecture is the host's own, read with
`uname -m`: Harbor runs the task container on the host's architecture, so
Apple silicon and arm64 Linux hosts need `aarch64` and the `x86_64` binary does
not execute in their containers. Pass a different one with `make musl
MUSL_ARCH=<arch>`, or a binary of any other architecture through
`MICROAGENT_BINARY`. Neither file is committed.

Statically linked, ~1.31 MB, no runtime dependencies — it runs in `python:slim`,
bare `ubuntu`, and distroless images alike.

## Run

```sh
uv venv ~/harbor-venv && uv pip install --python ~/harbor-venv/bin/python \
  -r integrations/harbor/requirements.lock

export MICROAGENT_API_KEY=...            # or OPENROUTER_API_KEY
export MICROAGENT_REASONING_EFFORT=none  # see "Reasoning" below
export MICROAGENT_BUDGET_SECONDS=1200    # stop below harbor's per-task timeout

PYTHONPATH=$PWD/integrations/harbor ~/harbor-venv/bin/harbor run \
  -d terminal-bench@2.0 -i log-summary-date-ranges \
  -a microagent_agent:Microagent \
  -m deepseek/deepseek-v4-flash \
  --jobs-dir ~/harbor-jobs -n 2
```

`swebench-verified@1.0`, `swebenchpro@1.0`, `aider-polyglot@1.0` and the rest of
Harbor's registry work the same way; only the dataset name changes.

Harbor itself is pinned in [requirements.txt](requirements.txt), because the
adapter subclasses its agent API and a score is only the same score against the
Harbor release that produced it. The install above reads
[requirements.lock](requirements.lock), which is that pin plus Harbor's whole
dependency tree with a sha256 per published artifact, so the venv a number in
[BENCHMARK.md](../../BENCHMARK.md) was measured in is the one the next run
installs. The command that regenerates it is in the comment at the top of
`requirements.txt`.

## Environment

| variable | effect |
| --- | --- |
| `MICROAGENT_API_KEY` / `OPENROUTER_API_KEY` / `OPENAI_API_KEY` / `DEEPSEEK_API_KEY` | provider key, passed to the container process only |
| `MICROAGENT_BASE_URL` | OpenAI-compatible endpoint (default OpenRouter) |
| `MICROAGENT_BUDGET_SECONDS` | elapsed-time budget inside the container, read from the monotonic clock (default 600, never above the agent timeout less its final-turn room) |
| `MICROAGENT_MAX_TURNS` | `--max-turns` passed to the binary (default 150, above the binary's own 100) |
| `MICROAGENT_REASONING_EFFORT` | `none`/`low`/... — reasoning models otherwise spend the whole budget thinking; a level the binary does not have stops the run here |
| `MICROAGENT_CA_BUNDLE` | PEM file to upload as the container's trust store, else `SSL_CERT_FILE`, else the host's system store |
| `MICROAGENT_AGENT_TIMEOUT_SEC` | hard cap on the in-container process (default 1500, minimum 331: the binary's final push may run 300 s past its budget, and a budget that leaves less is a run killed mid-turn) |
| `MICROAGENT_BINARY` | path to the static binary, if not next to this file |
| `MICROAGENT_VERSION` | version string reported to harbor, if not the binary's own |

An empty value is the same as an unset one for every variable here, and a value
is trimmed before it is read, so a wrapper that exports one from a file leaves
no newline on a path or a key. A non-numeric or zero `MICROAGENT_MAX_TURNS`,
`MICROAGENT_BUDGET_SECONDS` or `MICROAGENT_AGENT_TIMEOUT_SEC`, a
`MICROAGENT_AGENT_TIMEOUT_SEC` too small to hold the final-turn room, and a
`MICROAGENT_REASONING_EFFORT` that is not one of `minimal`, `low`, `medium`,
`high`, `none`, stop the run before the container starts, naming the variable.
`MICROAGENT_MAX_TURNS` is passed as `--max-turns` and the binary reads the same
name itself, so either route ends at the same ceiling.

`MICROAGENT_CA_BUNDLE` is read here in the order the binary reads it, the
project's own variable first and `SSL_CERT_FILE` after it, so the bundle a host
names for its own runs is the one uploaded for the container's. With neither
set, the host's trust store is probed at the usual distribution and Homebrew
paths.

## Two things the containers forced

Bare images have no CA store, and microagent's TLS then fails before its first
request with `TlsInitializationFailed`. The adapter uploads the host's CA bundle
and passes `MICROAGENT_CA_BUNDLE`; the host path is usually a symlink into
`ca-certificates/extracted`, which `docker cp` would copy as a dangling link, so
the adapter resolves it first.

Reasoning models burn the entire per-task timeout thinking. Measured on
Terminal-Bench 2 `log-summary-date-ranges` with deepseek-v4-flash: with reasoning
on, 12-minute gauntlet reviews timed out with zero files changed; with
`MICROAGENT_REASONING_EFFORT=none`, the same work lands in minutes.

## Results

See [BENCHMARK.md](../../BENCHMARK.md#terminal-bench-2) for the scores and the
machine they were produced on.
