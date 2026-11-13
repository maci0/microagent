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
`microagent-<host arch>-linux-musl` next to the adapter, the name `binary_path()`
looks for. The architecture is the host's own (`uname -m`, with `amd64` and
`arm64` folded to `x86_64` and `aarch64`). Harbor runs the task container on
that architecture, so an `x86_64` binary does not execute in an arm64
container. Pick another with `make musl MUSL_ARCH=<arch>`, or pass any binary
through `MICROAGENT_BINARY`. Neither file is committed.

The binary is statically linked and links no libc (sizes by build mode are in
[docs/benchmark.md](../../docs/benchmark.md#binary-size-and-source)). The
adapter's setup runs `test`, `wc` and `chmod` through the image's shell. Inside
the run, the `bash` tool needs `/bin/sh`, `search` needs `rg`, `ast` needs
`ast-grep` and `git` needs `git`; a missing program fails only its own tool,
with an install hint.

## Run

```sh
uv venv --python 3.12 ~/harbor-venv && uv pip install --require-hashes --python ~/harbor-venv/bin/python \
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

`aider/aider-polyglot`, `datacurve/deep-swe-1-1`, `terminal-bench@2.0` and
`swebench-verified@1.0` work the same way; only the dataset name changes.
`swebenchpro@1.0` is in Harbor's registry and is not a `bench/harbor.sh` target.
Newer datasets prefix task ids (`terminal-bench/<task>`, `datacurve/<task>`,
`aider/<task>`), and `-i <task>` alone matches none of them. `bench/harbor.sh`
runs the fixed samples (`tb4`, `polyglot`, `deepswe`, `tb2`, `swebench`),
microagent then opencode; see
[docs/benchmark.md](../../docs/benchmark.md#terminal-bench-40).

DeepSWE tasks give the agent no network, so a run has to let the provider
through with `--allow-agent-host <provider host>`. `bench/harbor.sh` does that
from `MICROAGENT_BASE_URL` (OpenRouter unless `PROVIDER` or that variable says
otherwise). The script's per-benchmark caps, which override the adapter
defaults below when those variables are unset:

| `bench/harbor.sh` | in-container cap | requested budget | timeout multiplier |
| --- | --- | --- | --- |
| `tb2` | 880 s | 790 s | none |
| `tb4` | 3480 s | 3100 s | 0.125 (3600 s of the 8 h task limit) |
| `polyglot` | 870 s | 500 s | 0.5 (of 1800 s) |
| `deepswe` | 5000 s | 4600 s | none |
| `swebench` | 2900 s | 2700 s | none |

The adapter caps each requested budget at the in-container cap minus 360 s.
At these defaults, the effective TB2 budget is 520 s and SWE-bench is 2540 s;
the other requested budgets fit without reduction.

A kimi arm exists and needs `PROVIDER=deepseek` or `PROVIDER=nvidia`.

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
| `MICROAGENT_CONFIG` | set by the adapter, not read from the host: the container gets a config that turns the four remote tool presets off, disabling those remote tools; other network access depends on the task environment |
| `MICROAGENT_BUDGET_SECONDS` | elapsed-time budget inside the container, read from the monotonic clock (default 600), capped at `MICROAGENT_AGENT_TIMEOUT_SEC` less 360 s |
| `MICROAGENT_MAX_TURNS` | `--max-turns` passed to the binary (default 1200; the binary's own default is 1000) |
| `MICROAGENT_REASONING_EFFORT` | `minimal`, `low`, `medium`, `high` or `none`; reasoning models otherwise spend the whole budget thinking. A level the binary does not have stops the run here |
| `MICROAGENT_MAX_TOKENS` | generation ceiling passed to the binary (its own default when unset); a low account balance is answered with `402 ... you can only afford N`, and asking for less is the only lever |
| `MICROAGENT_MAX_SPEND_TOKENS` | billed-token ceiling passed to the binary (no ceiling when unset), which warns on stderr once 80% of it is spent. Applies independently to each trial; it does not impose an aggregate sweep budget |
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
  `MICROAGENT_AGENT_TIMEOUT_SEC`, `MICROAGENT_MAX_TOKENS`,
  `MICROAGENT_MAX_SPEND_TOKENS` or `MICROAGENT_STALL_TIMEOUT`;
- generation and stall ceilings above `4294967295`, or turn, budget and spend
  ceilings above `18446744073709551615`;
- a `MICROAGENT_REASONING_EFFORT` that is not one of `minimal`, `low`,
  `medium`, `high`, `none`;
- a `MICROAGENT_BASE_URL` with no scheme or host, an invalid port, or http to
  anything but loopback;
- control characters inside `MICROAGENT_API_KEY` or `MICROAGENT_BASE_URL`.

Accepted numbers are forwarded as decimal digits, including when Python reads
an underscore, a leading plus or non-ASCII digits in the host value. The
adapter passes the host value as `--max-turns`; it does not export
`MICROAGENT_MAX_TURNS` into the container.

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
host. The host path is usually a symlink into `ca-certificates/extracted`,
which `docker cp` would copy as a dangling link, so the adapter uploads the
file it resolves to.

## What the containers forced

### Reasoning

Reasoning models burn the entire per-task timeout thinking. In the
[gauntlet reviews](../../docs/benchmark.md#usefulness), deepseek-v4-flash
without `--reasoning-effort` and with `--reasoning-effort low` used its whole
12 minutes and changed no files. With reasoning off, the
[five-task Terminal-Bench 2 set](../../docs/benchmark.md#five-task-set) solved
`log-summary-date-ranges` in 47 s. These are different tasks, so they are the
reason the Run example sets `none`, not a controlled comparison.

## Results

See [docs/benchmark.md](../../docs/benchmark.md#terminal-bench-2) for the scores and the
machine they were produced on.
