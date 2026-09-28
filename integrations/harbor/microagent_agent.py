"""Harbor agent adapter: run microagent inside a Terminal-Bench / Harbor task.

microagent is a static binary with its own bash/file tools, so it runs *inside*
the task container, where the task's files already are. This adapter uploads the
binary, then runs one non-interactive turn with the task instruction.

    PYTHONPATH=integrations/harbor harbor run -d terminal-bench@2.0 \\
      -i log-summary-date-ranges -a microagent_agent:Microagent \\
      -m deepseek/deepseek-v4-flash

The binary is found at $MICROAGENT_BINARY, else next to this file as
`microagent-<host arch>-linux-musl` (build with `make musl`, which is
`zig build -Dtarget=<host arch>-linux-musl -Doptimize=ReleaseFast` followed by
the copy). The architecture is the host's, because Harbor runs the task
container on the host's architecture: an arm64 host needs the aarch64 binary,
and the x86_64 one does not execute there.

The model provider key comes from the host environment ($MICROAGENT_API_KEY,
else $OPENROUTER_API_KEY, $OPENAI_API_KEY or $DEEPSEEK_API_KEY) and is passed to
the container process only, never baked into the image.
"""

from __future__ import annotations

import json
import os
import platform
import shlex
from pathlib import Path

from harbor.agents.base import BaseAgent
from harbor.environments.base import BaseEnvironment
from harbor.models.agent.context import AgentContext

# The musl asset for the host's own architecture, under the name the release
# publishes. Harbor runs the task container on the host's architecture, so the
# binary has to be the one the host can execute, and a name spelled for the other
# architecture is a file an arm64 container refuses to run. `uname -m` answers
# x86_64 and aarch64 already; the two aliases are what Darwin and some Linux
# images use for the same two.
_ARCH_ALIASES = {"amd64": "x86_64", "arm64": "aarch64"}
HOST_ARCH = _ARCH_ALIASES.get(platform.machine().lower(), platform.machine().lower())
BINARY_NAME = f"microagent-{HOST_ARCH}-linux-musl"
REMOTE_PATH = "/usr/local/bin/microagent"
# Bare images (ubuntu, distroless) ship no CA store, and microagent's TLS then
# fails before its first request. The host's bundle is uploaded and named
# explicitly rather than relying on the image being kind.
REMOTE_CA_PATH = "/usr/local/bin/microagent-ca.crt"
# Probed, not selected by OS name: a host that ships its trust store somewhere
# else is found by asking the filesystem. Debian/Ubuntu, RHEL/Fedora, macOS 12+
# (which has no /etc/ssl/certs at all) and the two Homebrew prefixes, since a
# Homebrew install is where a macOS host most often keeps one.
HOST_CA_CANDIDATES = (
    "/etc/ssl/certs/ca-certificates.crt",
    "/etc/pki/tls/certs/ca-bundle.crt",
    "/etc/ssl/cert.pem",
    "/opt/homebrew/etc/ca-certificates/cert.pem",
    "/usr/local/etc/ca-certificates/cert.pem",
)
DEFAULT_BASE_URL = "https://openrouter.ai/api/v1"
# The turn ceiling, above the binary's own 100. Spelled once because setup
# checks it and run passes it, and a default one of the two no longer knows
# about is a run that is checked for one ceiling and given another.
DEFAULT_MAX_TURNS = "150"
# Keep the agent's own budget under harbor's per-task agent timeout, so
# microagent stops deliberately instead of being killed mid-turn.
DEFAULT_BUDGET_SECONDS = "600"
# The hard cap on the in-container process, and the ceiling the budget is
# derived from. Spelled once for the same reason as the turn ceiling.
DEFAULT_AGENT_TIMEOUT_SEC = "1500"
# The grace the binary allows its forced final push to run past the budget
# (`final_push_grace_s` in src/main.zig). A run that reaches its budget can
# spend this much longer, so a room smaller than it leaves the caller's timeout
# landing in the middle of the last turn, which is the fault the room exists to
# prevent. ROOM_S is that grace plus a minute for the container teardown.
FINAL_PUSH_GRACE_S = 300
FINAL_TURN_ROOM_S = FINAL_PUSH_GRACE_S + 60
# The levels the binary accepts for reasoning.effort, kept beside the defaults
# so a mistyped one is refused before a container is started rather than inside
# one.
REASONING_EFFORTS = ("minimal", "low", "medium", "high", "none")


def binary_path() -> Path:
    override = trimmed_env("MICROAGENT_BINARY")
    if override:
        return Path(override).expanduser().resolve()
    return Path(__file__).resolve().parent / BINARY_NAME


def trimmed_env(name: str) -> str | None:
    """A host variable with surrounding whitespace removed, or None when it is
    unset or holds nothing but whitespace. A wrapper that populates the
    environment from a file exports the newline that file ended with, and a path
    carrying one names a file nothing holds: the adapter would report a binary
    or a bundle that is not there rather than the value it was given."""
    raw = os.environ.get(name)
    if raw is None:
        return None
    value = raw.strip()
    return value or None


def host_ca_bundle() -> Path | None:
    # The binary's own order (net.caBundlePath): the project's variable first,
    # then the one the system trust store tooling uses. An operator who set
    # MICROAGENT_CA_BUNDLE for the run on this host means the same bundle for
    # the run in the container, and reading only SSL_CERT_FILE would upload the
    # system store instead and trust the wrong root for a benchmark.
    candidates = (
        c for c in (trimmed_env("MICROAGENT_CA_BUNDLE"), *HOST_CA_CANDIDATES, trimmed_env("SSL_CERT_FILE")) if c
    )
    for candidate in candidates:
        path = Path(candidate)
        if path.is_file():
            # Resolve first: on most distributions this path is a symlink into
            # ca-certificates/extracted, and docker cp copies the link, leaving
            # the container with a dangling symlink where a PEM should be.
            return path.resolve()
    return None


def api_key() -> str:
    for name in ("MICROAGENT_API_KEY", "OPENROUTER_API_KEY", "OPENAI_API_KEY", "DEEPSEEK_API_KEY"):
        value = trimmed_env(name)
        if value:
            return value
    raise RuntimeError(
        "no model provider key in the host environment: set MICROAGENT_API_KEY, "
        "OPENROUTER_API_KEY, OPENAI_API_KEY or DEEPSEEK_API_KEY before running harbor"
    )


def int_env(name: str, default: str, minimum: int = 1) -> int:
    """A whole-number knob read from the host environment. An empty value is
    not a value, and a bad one names the variable instead of surfacing as a
    ValueError from int() with no indication of which knob it was. A knob the
    binary reads as a ceiling is refused here too, so a mistyped value stops
    the run before a container is started rather than inside one."""
    raw = trimmed_env(name) or default
    try:
        value = int(raw)
    except ValueError:
        raise RuntimeError(f"{name} must be a whole number, got {raw!r}") from None
    if value < minimum:
        raise RuntimeError(f"{name} must be at least {minimum}, got {raw!r}")
    return value


def reasoning_effort() -> str | None:
    """The provider's reasoning.effort, checked here for the reason the numeric
    knobs are: the binary refuses a level it does not have, and refusing it
    there costs a container start and an upload before the reason is printed.
    A level that is not one is named here, while the operator is looking at the
    command line rather than at a container's stderr."""
    value = trimmed_env("MICROAGENT_REASONING_EFFORT")
    if not value:
        return None
    if value not in REASONING_EFFORTS:
        raise RuntimeError(f"MICROAGENT_REASONING_EFFORT must be one of {', '.join(REASONING_EFFORTS)}, got {value!r}")
    return value


def validate_env() -> None:
    """Every knob the binary is handed, read once so a bad one stops the run
    before anything is uploaded or started.

    `run` reads these again, so this is not a second source of truth: it is the
    same readers, called where the failure is cheap. The adapter's own README
    promises a mistyped ceiling or reasoning level stops the run "before the
    container starts", and `setup` is what brings the container up and uploads
    the binary into it, so a value checked only in `run` has already paid for a
    container start and an upload before the reason is printed.
    """
    int_env("MICROAGENT_MAX_TURNS", DEFAULT_MAX_TURNS)
    int_env("MICROAGENT_BUDGET_SECONDS", DEFAULT_BUDGET_SECONDS)
    int_env("MICROAGENT_AGENT_TIMEOUT_SEC", DEFAULT_AGENT_TIMEOUT_SEC)
    reasoning_effort()


def normalize_model(model_name: str | None) -> str:
    """harbor model names carry a provider prefix ('openrouter/x/y'); microagent
    speaks to whatever base URL it is given, so the prefix is dropped."""
    if not model_name:
        return "deepseek/deepseek-v4-flash"
    for prefix in ("openrouter/", "openai/"):
        if model_name.startswith(prefix):
            return model_name[len(prefix) :]
    return model_name


class Microagent(BaseAgent):
    """microagent as a harbor agent: uploaded, run once, output kept."""

    # Set by setup, read by run. Declared here so the attribute has one type and
    # run does not reach for it through getattr, which returns the default and
    # reports no bundle when setup has not run instead of when none was found.
    _ca_uploaded: bool = False

    @staticmethod
    def name() -> str:
        return "microagent"

    def version(self) -> str | None:
        return trimmed_env("MICROAGENT_VERSION")

    async def setup(self, environment: BaseEnvironment) -> None:
        # The knobs are checked before the binary is looked for, so a mistyped
        # one is reported as the mistyped one rather than as a missing binary on
        # a host that has both problems.
        validate_env()
        source = binary_path()
        if not source.is_file():
            raise RuntimeError(
                f"microagent binary not found at {source}; build it with "
                f"`zig build -Dtarget={HOST_ARCH}-linux-musl -Doptimize=ReleaseFast` "
                "(or `make musl`), or set MICROAGENT_BINARY"
            )
        await environment.upload_file(source_path=source, target_path=REMOTE_PATH)
        bundle = host_ca_bundle()
        self._ca_uploaded = False
        if bundle is not None:
            # A verified copy rather than a link: docker cp would land the host
            # symlink itself, and the container would have a dangling path where
            # a PEM should be. The upload lands under /usr/local/bin, which a
            # minimal image has, so no directory has to be created first.
            await environment.upload_file(source_path=bundle, target_path=REMOTE_CA_PATH)
            check = await environment.exec(
                command=f"test -s {REMOTE_CA_PATH} && wc -c < {REMOTE_CA_PATH}",
                timeout_sec=60,
            )
            self._ca_uploaded = check.return_code == 0
            self.logger.info(
                "ca bundle %s -> %s (%s bytes reported)",
                bundle,
                REMOTE_CA_PATH,
                (check.stdout or "").strip() or f"write failed: {check.stderr}",
            )
        else:
            # Named, because the failure it leads to is a TLS error inside a
            # container nobody can reach the filesystem of: a host whose trust
            # store is not at any of the probed paths uploads nothing, and a
            # bare image has none of its own, so the first request dies as
            # TlsInitializationFailed with nothing in the log to connect it to
            # the host that had no bundle to give.
            self.logger.warning(
                "no ca bundle on the host (%s); the container keeps its own trust store, "
                "and a bare image has none. Set MICROAGENT_CA_BUNDLE to the PEM to upload.",
                ", ".join(HOST_CA_CANDIDATES),
            )
        result = await environment.exec(
            command=f"chmod +x {REMOTE_PATH} && {REMOTE_PATH} --version",
            timeout_sec=120,
        )
        if result.return_code != 0:
            raise RuntimeError(f"microagent did not run in the container: {result.stdout or ''}{result.stderr or ''}")
        self.logger.info("microagent ready: %s", (result.stdout or "").strip())

    async def run(
        self,
        instruction: str,
        environment: BaseEnvironment,
        context: AgentContext,
    ) -> None:
        model = normalize_model(self.model_name)
        # The budget and the level are both read by the binary, so both are
        # checked here rather than handed over as strings the container refuses
        # after an upload and a container start.
        # The budget is the agent's working time, so it is as large as the
        # caller's timeout allows, less room for the last turn to land. A
        # budget equal to the timeout is a run killed mid-turn; a budget far
        # below it is working time thrown away.
        agent_timeout = int_env("MICROAGENT_AGENT_TIMEOUT_SEC", DEFAULT_AGENT_TIMEOUT_SEC)
        budget = str(
            min(
                int_env("MICROAGENT_BUDGET_SECONDS", DEFAULT_BUDGET_SECONDS),
                max(60, agent_timeout - FINAL_TURN_ROOM_S),
            )
        )
        reasoning = reasoning_effort()
        command = " ".join(
            shlex.quote(part)
            for part in (
                REMOTE_PATH,
                "--model",
                model,
                "--budget",
                budget,
                "--max-turns",
                str(int_env("MICROAGENT_MAX_TURNS", DEFAULT_MAX_TURNS)),
                instruction,
            )
        )
        env = {
            "MICROAGENT_API_KEY": api_key(),
            "MICROAGENT_BASE_URL": trimmed_env("MICROAGENT_BASE_URL") or DEFAULT_BASE_URL,
        }
        if self._ca_uploaded:
            env["MICROAGENT_CA_BUNDLE"] = REMOTE_CA_PATH
        if reasoning:
            env["MICROAGENT_REASONING_EFFORT"] = reasoning

        started = self.logs_dir / "microagent-stdout.txt"
        try:
            result = await environment.exec(
                command=command,
                env=env,
                timeout_sec=agent_timeout,
            )
        except RuntimeError as error:
            # A timeout is the caller's budget ending, not a broken agent: the
            # tree the agent already changed is what the verifier scores, and
            # raising here records the trial as an exception and scores the
            # work as nothing. Hand over to verification with the tree as it
            # stands.
            if "timed out" not in str(error).lower():
                raise
            self.logger.warning("microagent hit the %ss agent timeout; scoring the tree as it stands", agent_timeout)
            (self.logs_dir / "microagent-timeout.txt").write_text(str(error), encoding="utf-8")
            return
        # UTF-8 named rather than left to the locale: a host running under
        # LANG=C or a legacy code page raises on a non-ASCII byte, and the run's
        # own transcript is the one log that must always land.
        started.write_text(result.stdout or "", encoding="utf-8")
        (self.logs_dir / "microagent-stderr.txt").write_text(result.stderr or "", encoding="utf-8")

        usage = last_usage(result.stdout or "")
        context.n_input_tokens = usage.get("prompt_tokens")
        context.n_output_tokens = usage.get("completion_tokens")
        context.metadata = {"agent": "microagent", "model": model, "return_code": result.return_code}
        self.logger.info(
            "microagent exit=%s tokens in/out=%s/%s log=%s",
            result.return_code,
            context.n_input_tokens,
            context.n_output_tokens,
            started,
        )
        if result.return_code != 0:
            raise RuntimeError(f"microagent exited {result.return_code}: {(result.stderr or '')[-2000:]}")


def last_usage(stdout: str) -> dict[str, int]:
    """microagent prints one cumulative usage JSON line per model response."""
    for raw in reversed(stdout.splitlines()):
        line = raw.strip()
        if line.startswith('{"type":"usage"'):
            try:
                return json.loads(line).get("usage", {})
            except json.JSONDecodeError:
                return {}
    return {}
