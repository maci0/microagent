"""Harbor agent adapter: run microagent inside a Terminal-Bench / Harbor task.

microagent is a static binary with its own bash/file tools, so it runs *inside*
the task container, where the task's files already are. This adapter uploads the
binary, then runs one non-interactive turn with the task instruction.

    PYTHONPATH=integrations/harbor harbor run -d terminal-bench@2.0 \\
      -i log-summary-date-ranges -a microagent_agent:Microagent \\
      -m deepseek/deepseek-v4-flash

The binary is found at $MICROAGENT_BINARY, else next to this file as
`microagent-<arch>-linux-musl` (build with:
`zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseFast`).

The model provider key comes from the host environment ($MICROAGENT_API_KEY,
else $OPENROUTER_API_KEY) and is passed to the container process only, never
baked into the image.
"""

from __future__ import annotations

import json
import os
import shlex
from pathlib import Path

from harbor.agents.base import BaseAgent
from harbor.environments.base import BaseEnvironment
from harbor.models.agent.context import AgentContext

BINARY_NAME = "microagent-x86_64-linux-musl"
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
# Keep the agent's own budget under harbor's per-task agent timeout, so
# microagent stops deliberately instead of being killed mid-turn.
DEFAULT_BUDGET_SECONDS = "600"


def binary_path() -> Path:
    override = os.environ.get("MICROAGENT_BINARY")
    if override:
        return Path(override).expanduser().resolve()
    return Path(__file__).resolve().parent / BINARY_NAME


def host_ca_bundle() -> Path | None:
    override = os.environ.get("SSL_CERT_FILE")
    candidates = (override, *HOST_CA_CANDIDATES) if override else HOST_CA_CANDIDATES
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
        value = os.environ.get(name)
        if value:
            return value
    raise RuntimeError(
        "no model provider key in the host environment: set MICROAGENT_API_KEY "
        "or OPENROUTER_API_KEY before running harbor"
    )


def int_env(name: str, default: str) -> int:
    """A whole-number knob read from the host environment. An empty value is
    not a value, and a bad one names the variable instead of surfacing as a
    ValueError from int() with no indication of which knob it was."""
    raw = os.environ.get(name) or default
    try:
        return int(raw)
    except ValueError:
        raise RuntimeError(f"{name} must be a whole number, got {raw!r}") from None


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

    @staticmethod
    def name() -> str:
        return "microagent"

    def version(self) -> str | None:
        return os.environ.get("MICROAGENT_VERSION")

    async def setup(self, environment: BaseEnvironment) -> None:
        source = binary_path()
        if not source.is_file():
            raise RuntimeError(
                f"microagent binary not found at {source}; build it with "
                "`zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseFast` "
                "or set MICROAGENT_BINARY"
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
        budget = os.environ.get("MICROAGENT_BUDGET_SECONDS") or DEFAULT_BUDGET_SECONDS
        command = " ".join(
            shlex.quote(part)
            for part in (
                REMOTE_PATH,
                "--model",
                model,
                "--budget",
                budget,
                "--max-turns",
                str(int_env("MICROAGENT_MAX_TURNS", "150")),
                instruction,
            )
        )
        env = {
            "MICROAGENT_API_KEY": api_key(),
            "MICROAGENT_BASE_URL": os.environ.get("MICROAGENT_BASE_URL") or DEFAULT_BASE_URL,
        }
        if getattr(self, "_ca_uploaded", False):
            env["MICROAGENT_CA_BUNDLE"] = REMOTE_CA_PATH
        reasoning = os.environ.get("MICROAGENT_REASONING_EFFORT")
        if reasoning:
            env["MICROAGENT_REASONING_EFFORT"] = reasoning

        started = self.logs_dir / "microagent-stdout.txt"
        result = await environment.exec(
            command=command,
            env=env,
            timeout_sec=int_env("MICROAGENT_AGENT_TIMEOUT_SEC", "1500"),
        )
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


def last_usage(stdout: str) -> dict:
    """microagent prints one cumulative usage JSON line per model response."""
    for raw in reversed(stdout.splitlines()):
        line = raw.strip()
        if line.startswith('{"type":"usage"'):
            try:
                return json.loads(line).get("usage", {})
            except json.JSONDecodeError:
                return {}
    return {}
