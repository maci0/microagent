# Running microagent on Harbor benchmarks

[Harbor](https://github.com/laude-institute/harbor) runs containerized agent
benchmarks (Terminal-Bench 2, SWE-bench Verified, aider-polyglot, ...). This
directory holds the adapter that lets Harbor drive microagent.

microagent is a static binary with its own shell and file tools, so it runs
*inside* the task container, where the task's files already are. The adapter
uploads it, then runs one non-interactive turn with the task instruction.

## Build the binary

```sh
zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseFast
cp zig-out/bin/microagent integrations/harbor/microagent-x86_64-linux-musl
```

Statically linked, ~1.25 MB, no runtime dependencies — it runs in `python:slim`,
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
| `MICROAGENT_BUDGET_SECONDS` | elapsed-time budget inside the container, read from the monotonic clock (default 600) |
| `MICROAGENT_MAX_TURNS` | `--max-turns` passed to the binary (default 150, above the binary's own 100) |
| `MICROAGENT_REASONING_EFFORT` | `none`/`low`/... — reasoning models otherwise spend the whole budget thinking |
| `MICROAGENT_AGENT_TIMEOUT_SEC` | hard cap on the in-container process (default 1500) |
| `MICROAGENT_BINARY` | path to the static binary, if not next to this file |
| `MICROAGENT_VERSION` | version string reported to harbor, if not the binary's own |

An empty value is the same as an unset one for every variable here, and a
non-numeric or zero `MICROAGENT_MAX_TURNS`, `MICROAGENT_BUDGET_SECONDS` or
`MICROAGENT_AGENT_TIMEOUT_SEC` stops the run before the container starts, naming
the variable. `MICROAGENT_MAX_TURNS` is passed as `--max-turns` and the binary
reads the same name itself, so either route ends at the same ceiling.

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
