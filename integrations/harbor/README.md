# Running microagent on Harbor benchmarks

[Harbor](https://github.com/laude-institute/harbor) runs containerized agent
benchmarks such as Terminal-Bench 4.0, DeepSWE, SWE-bench Verified and aider-polyglot.
This directory holds the adapter that lets Harbor drive microagent.

microagent is a static binary with its own shell and file tools, so it runs
*inside* the task container, where the task's files already are. The adapter
uploads it, then runs one non-interactive turn with the task instruction.

## Build the binary

```sh
make musl
```

The [Makefile](../../Makefile) runs `zig build -Dtarget=<host arch>-linux-musl
-Doptimize=ReleaseSmall` and copies the binary to
`microagent-<host arch>-linux-musl` next to the adapter, the name the adapter's
`binary_path()` looks for. The architecture is the host's own, read with
`uname -m`: Harbor runs the task container on the host's architecture, so
Apple silicon and arm64 Linux hosts need `aarch64`, and an `x86_64` binary does
not execute in their containers. Pick another with `make musl
MUSL_ARCH=<arch>`, or pass a binary of any architecture through
`MICROAGENT_BINARY`. Neither file is committed.

The binary is statically linked, about 1.6 MB, with no runtime dependencies:
it runs in `python:slim`, bare `ubuntu` and distroless images alike.

## Run

```sh
uv venv ~/harbor-venv && uv pip install --require-hashes --python ~/harbor-venv/bin/python \
  -r integrations/harbor/requirements.lock

export MICROAGENT_API_KEY=...
export MICROAGENT_REASONING_EFFORT=none  # see "Reasoning" below
export MICROAGENT_BUDGET_SECONDS=1140    # working time; see the cap below

PYTHONPATH=$PWD/integrations/harbor ~/harbor-venv/bin/harbor run \
  -d terminal-bench/terminal-bench@4.0.0 -i terminal-bench/html-js-filter \
  -a microagent_agent:Microagent \
  -m deepseek/deepseek-v4-flash \
  --jobs-dir ~/harbor-jobs -n 2
```

`aider/aider-polyglot`, `datacurve/deep-swe-1-1`, `terminal-bench@2.0`, `swebench-verified@1.0`, `swebenchpro@1.0`,
and the rest of Harbor's registry work the same way; only the dataset name
changes. The registry's newer datasets prefix their task ids with the dataset's namespace
(`terminal-bench/<task>`, `datacurve/<task>`), and `-i <task>` alone matches none of them.
`bench/harbor.sh tb4` and `bench/harbor.sh deepswe` run the fixed samples of the first two, against
opencode as well; see [docs/benchmark.md](../../docs/benchmark.md#terminal-bench-40).

DeepSWE tasks give the agent no network, so a run has to let the provider through with
`--allow-agent-host <provider host>`; `bench/harbor.sh` does that from `MICROAGENT_BASE_URL`.

Harbor itself is pinned in [requirements.txt](requirements.txt), because the
adapter subclasses its agent API, and a score is comparable only against the
Harbor release that produced it. The install above reads
[requirements.lock](requirements.lock): that pin plus Harbor's whole dependency
tree, with a sha256 per published artifact, so the next run installs the venv a
number in [docs/benchmark.md](../../docs/benchmark.md) was measured in. The
command that regenerates the lock is in the comment at the top of
`requirements.txt`.

## Environment

| variable | effect |
| --- | --- |
| `MICROAGENT_API_KEY` | provider key, passed to the container process only. It is required, and a host without it is told so before the container starts |
| `MICROAGENT_BASE_URL` | OpenAI-compatible endpoint (default OpenRouter); https, or http on loopback, because the key goes to it in the clear, and a url the binary refuses stops the run here |
| `MICROAGENT_CONFIG` | set by the adapter, not read from the host: the container gets a config that turns the four remote tool presets off, so a scored run has no web access beyond the provider |
| `MICROAGENT_BUDGET_SECONDS` | elapsed-time budget inside the container, read from the monotonic clock (default 600), capped at `MICROAGENT_AGENT_TIMEOUT_SEC` less 360 s |
| `MICROAGENT_MAX_TURNS` | `--max-turns` passed to the binary (default 150, above the binary's own 100) |
| `MICROAGENT_REASONING_EFFORT` | `minimal`, `low`, `medium`, `high` or `none`; reasoning models otherwise spend the whole budget thinking. A level the binary does not have stops the run here |
| `MICROAGENT_MAX_TOKENS` | generation ceiling passed to the binary (its own default when unset); a low account balance is answered with `402 ... you can only afford N`, and asking for less is the only lever |
| `MICROAGENT_STALL_TIMEOUT` | seconds the response socket may stay silent before the read fails, passed to the binary (its own 120 s default when unset). Raise it for a provider slow to a first token on a large prompt: NVIDIA NIM took over two minutes on one, and the run died of the default rather than of its own answer |
| `MICROAGENT_CA_BUNDLE` | PEM file to upload as the container's trust store, else `SSL_CERT_FILE`, else the host's system store |
| `MICROAGENT_AGENT_TIMEOUT_SEC` | hard cap on the in-container process (default 1500), and the ceiling the budget is derived from |
| `MICROAGENT_BINARY` | path to the static binary, if not next to this file |
| `MICROAGENT_VERSION` | version string reported to harbor, if not the binary's own |

An empty value counts as unset for every variable here, and each value is
trimmed before it is read, so a wrapper that exports one from a file leaves no
newline on a path or a key. These stop the run before the container starts,
naming the variable:

- a non-numeric or zero `MICROAGENT_MAX_TURNS`, `MICROAGENT_BUDGET_SECONDS`,
  `MICROAGENT_AGENT_TIMEOUT_SEC`, `MICROAGENT_MAX_TOKENS` or
  `MICROAGENT_STALL_TIMEOUT`;
- a `MICROAGENT_REASONING_EFFORT` that is not one of `minimal`, `low`,
  `medium`, `high`, `none`;
- a `MICROAGENT_BASE_URL` the binary would refuse (no scheme, or http to
  anything but loopback).

`MICROAGENT_MAX_TURNS` is passed as `--max-turns`, and the binary reads the
same name itself, so either route ends at the same ceiling.

### The budget cap

The budget is the agent's working time, so the adapter takes the smaller of
`MICROAGENT_BUDGET_SECONDS` and `MICROAGENT_AGENT_TIMEOUT_SEC` less 360 s,
floored at one second. A run whose budget was cut says so on the job log with
both numbers, because a score is read from that log.

The 360 s is the binary's own 300 s grace on the forced final push plus a
minute for teardown. A run that reaches its budget keeps going for that grace,
so less room puts the caller's timeout in the middle of the last turn. At the
defaults the budget stays 600 against the 1500 s timeout, since 600 is the
smaller. A task timeout of 900 s runs a 540 s budget, and
`MICROAGENT_BUDGET_SECONDS=1200` under the default timeout is capped to 1140.

The floor is one second, not a minute, because a floor larger than the timeout
allows hands a 60 s budget to a 30 s timeout: the container is killed 30 s in
and the run is recorded as an exception rather than scored on the tree it left.
A timeout that leaves no room after the grace is refused before the container
starts, rather than answered with a budget the caller's timeout expires inside.

A run that still reaches the caller's timeout is scored on the tree it left
rather than raised, since the trial would otherwise be recorded as an exception
and the work counted as nothing. The timeout is written to
`microagent-timeout.txt` in the job's log directory and a warning names it, so
a trial scored on a partial tree is visible in the log.

### The CA bundle

The adapter reads the CA bundle in the order the binary does,
`MICROAGENT_CA_BUNDLE` first and `SSL_CERT_FILE` after it, so the bundle a host
names for its own runs is the one uploaded for the container's. With neither
set, it probes the host's trust store at the usual distribution and Homebrew
paths, and warns at setup when none of those holds a PEM. The container then
keeps its own trust store; a bare image has none, so the first request dies as
`TlsInitializationFailed` with nothing in the job log connecting it to the
host.

## Two things the containers forced

### CA store

Bare images have no CA store, and microagent's TLS then fails before its first
request with `TlsInitializationFailed`. The adapter uploads the host's CA bundle
and passes `MICROAGENT_CA_BUNDLE`; the host path is usually a symlink into
`ca-certificates/extracted`, which `docker cp` would copy as a dangling link, so
the adapter resolves it first.

### Reasoning

Reasoning models burn the entire per-task timeout thinking. Measured on
Terminal-Bench 2 `log-summary-date-ranges` with deepseek-v4-flash: with reasoning
on, 12-minute gauntlet reviews timed out with zero files changed; with
`MICROAGENT_REASONING_EFFORT=none`, the same work landed in minutes.

## Results

See [docs/benchmark.md](../../docs/benchmark.md#terminal-bench-2) for the scores and the
machine they were produced on.
