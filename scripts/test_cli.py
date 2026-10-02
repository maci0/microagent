"""Check the built CLI against a loopback provider: python3 scripts/test_cli.py BINARY."""

from __future__ import annotations

import importlib.util
import json
import os
import pty
import select
import shutil
import subprocess
import sys
import tempfile
import termios
import tomllib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from socketserver import BaseRequestHandler, ThreadingTCPServer
from threading import Thread
from types import ModuleType
from typing import Any, ClassVar
from unittest.mock import patch


class Provider(BaseHTTPRequestHandler):
    """The loopback provider. Every switch is a class attribute a case sets
    before the `invoke` that reads it and clears again before the next one: a
    switch left on is shared mutable state the case after it silently inherits,
    so an added or reordered case is a different run with no diff saying so.
    `reset` runs once per check function, so a check starts from the ordinary
    response whatever the one before it left behind.
    """

    seen: ClassVar[list[dict[str, Any]]] = []
    paths: ClassVar[list[str]] = []
    empty = False
    trailing_newline = True
    bad_call = False
    hang = False
    hang_body = False
    billed_error = False
    invalid_usage = False
    response_bytes = 0
    response_calls = False
    # The one tool call the ordinary response makes, when it makes one at all.
    # "" is the ordinary response: a case sets it to the arguments of a call
    # it wants to see dispatched, and clears it again after its own assertions.
    tool_call_args = ""

    @classmethod
    def reset(cls) -> None:
        """Put every switch back to the ordinary response, so a check starts
        from the one shape every case falls back to.
        """
        cls.empty = False
        cls.trailing_newline = True
        cls.bad_call = False
        cls.hang = False
        cls.hang_body = False
        cls.billed_error = False
        cls.invalid_usage = False
        cls.response_bytes = 0
        cls.response_calls = False
        cls.tool_call_args = ""

    @staticmethod
    def tool_call_frame() -> dict[str, Any]:
        """The one tool call a case asks for, as the choice that carries it.

        Its own method because the switch it reads is one more thing `do_POST`
        decides, and that method is already at the limit this project lints to.
        """
        call = {"index": 0, "id": "call", "function": {"name": "bash", "arguments": Provider.tool_call_args}}
        return {"delta": {"content": "working", "tool_calls": [call]}, "finish_reason": "tool_calls"}

    def do_POST(self) -> None:
        Provider.paths.append(self.path)
        Provider.seen.append(json.loads(self.rfile.read(int(self.headers["content-length"]))))
        if Provider.response_bytes:
            self.send_response(200)
            self.send_header("content-type", "text/event-stream")
            self.end_headers()
            cap = 16 * 1024 * 1024
            try:
                if Provider.response_bytes > cap:
                    call = {
                        "index": 0,
                        "id": "pending",
                        "function": {"name": "bash", "arguments": '{"command":"touch ceiling-marker"}'},
                    }
                    self.wfile.write(
                        ("data: " + json.dumps({"choices": [{"delta": {"tool_calls": [call]}}]}) + "\n\n").encode()
                    )
                delta = (
                    {"tool_calls": [{"index": 64, "function": {"arguments": "x" * 65536}}]}
                    if Provider.response_calls
                    else {"content": "x" * 65536}
                )
                chunk = ("data: " + json.dumps({"choices": [{"delta": delta}]}) + "\n\n").encode()
                for _ in range(Provider.response_bytes // 65536):
                    self.wfile.write(chunk)
                if Provider.response_bytes > cap:
                    self.rfile.read(1)  # No terminator: the byte ceiling must close the stream.
                else:
                    self.wfile.write(b'data: {"choices":[{"delta":{},"finish_reason":"stop"}]}\n\ndata: [DONE]\n\n')
            except (BrokenPipeError, ConnectionResetError):
                pass  # The client has enforced its ceiling.
            return
        if Provider.hang:
            if Provider.hang_body:
                self.send_response(200)
                self.send_header("content-type", "text/event-stream")
                self.send_header("content-length", "100")
                self.end_headers()
            self.rfile.read(1)  # Wait for the client to enforce its deadline and close.
            return
        choice = (
            self.tool_call_frame()
            if Provider.tool_call_args
            else ({"delta": {"content": "" if Provider.empty else "answer"}, "finish_reason": "stop"})
        )
        frame = {
            "choices": [choice],
            "usage": {"prompt_tokens": 10, "completion_tokens": 1, "total_tokens": 11},
        }
        if Provider.bad_call:
            Provider.bad_call = False
            frame["choices"] = [
                {
                    "delta": {
                        "content": "working",
                        "tool_calls": [
                            {"index": 0, "id": "bad", "function": {"name": "read", "arguments": '{"path":'}}
                        ],
                    },
                    "finish_reason": "tool_calls",
                }
            ]
        ending = "\n\n" if Provider.trailing_newline else ""
        body = ("data: " + json.dumps(frame) + "\n\ndata: [DONE]" + ending).encode()
        if Provider.billed_error:
            usage = (
                '{"total_tokens":"unknown"}'
                if Provider.invalid_usage
                else '{"prompt_tokens":10,"completion_tokens":1,"total_tokens":11}'
            )
            body = (
                'data: {"usage":' + usage + '}\n\ndata: {"error":{"message":"generation failed"}}\n\ndata: [DONE]\n\n'
            ).encode()
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    # because: BaseHTTPRequestHandler declares this parameter name
    def log_message(self, format: str, *args: object) -> None:  # noqa: A002
        """Keep the check's output free of access logs."""


def expect(condition: object, detail: object) -> None:
    if not condition:
        raise AssertionError(detail)


def invoke(
    binary: Path, root: Path, url: str, args: list[str], prompts: str, **extra_env: str
) -> subprocess.CompletedProcess[str]:
    Provider.seen.clear()
    Provider.paths.clear()
    # A wholly synthetic environment keeps user credentials and settings out.
    env = {
        "PATH": os.environ.get("PATH", ""),
        "MICROAGENT_API_KEY": "test",
        "MICROAGENT_BASE_URL": url,
        "MICROAGENT_CONFIG": "",
        "MICROAGENT_SKILLS": "",
        "MICROAGENT_SESSION_DIR": str(root / "sessions"),
    }
    env.update(extra_env)
    # because: the explicitly supplied local binary is the program under test
    result = subprocess.run(  # noqa: S603
        [str(binary), *args],
        input=prompts,
        capture_output=True,
        text=True,
        encoding="utf-8",
        env=env,
        cwd=root,
        timeout=10,
        check=False,
    )
    expect("error(gpa)" not in result.stderr, result.stderr)
    return result


def check_refs(root: Path) -> None:
    fixture = root / "refs"
    (fixture / "scripts").mkdir(parents=True)
    (fixture / "src").mkdir()
    script = fixture / "scripts" / "check-refs.sh"
    shutil.copyfile(Path(__file__).with_name("check-refs.sh"), script)
    (fixture / "src" / "example.zig").write_text("pub fn first() void {}\npub fn second() void {}\n", encoding="utf-8")
    doc = fixture / "references.md"
    for text, status in (
        ("`first`, `src/example.zig:1`", 0),
        ("at `src/example.zig:2`", 0),
        ("`src/example.zig:1-2`", 0),
        ("at `src/example.zig:99`", 1),
        ("`src/example.zig:1-99`", 1),
        ("`src/example.zig:2-1`", 1),
        ("`src/example.zig:0`", 1),
        ("`src/example.zig:" + "9" * 50 + "`", 1),
        ("`first`, `src/example.zig:1-99`", 1),
        ("`second`, `src/example.zig:1`", 1),
    ):
        doc.write_text(text + "\n", encoding="utf-8")
        # because: the repository's own validation script, copied into an isolated fixture
        result = subprocess.run(["/bin/sh", str(script), str(doc)], capture_output=True, text=True, check=False)  # noqa: S603
        expect(result.returncode == status, (text, result.stderr))
    # A fix must report references it cannot repair, and missing input cannot pass.
    for text, status in (("`second`, `src/example.zig:1`", 0), ("at `src/example.zig:99`", 1)):
        doc.write_text(text + "\n", encoding="utf-8")
        # because: the same local script with its documented repair switch
        result = subprocess.run(["/bin/sh", str(script), "-f", str(doc)], capture_output=True, text=True, check=False)  # noqa: S603
        expect(result.returncode == status, result.stderr)
        if status == 0:
            expect(doc.read_text(encoding="utf-8") == "`second`, `src/example.zig:2`\n", result.stderr)
    doc.unlink()
    # because: a missing file is deliberately passed to the validator
    result = subprocess.run(["/bin/sh", str(script), str(doc)], capture_output=True, text=True, check=False)  # noqa: S603
    expect(result.returncode != 0, result.stderr)


def check_setup(binary: Path, root: Path, url: str) -> None:
    home = root / "setup-home"
    path = home / ".microagent" / "config.toml"
    # No config or provider is needed to print either spelling of setup help.
    for args in (["setup", "--help"], ["help", "setup"]):
        result = invoke(binary, root, url, args, "", HOME=str(home))
        expect(result.returncode == 0 and "usage: microagent setup" in result.stdout, result)
        expect(not path.exists() and not Provider.seen, result)
    result = invoke(binary, root, url, ["setup"], "", HOME=str(home), MICROAGENT_CONFIG=" ")
    expect(result.returncode == 2 and not path.exists(), result)
    # EOF leaves the freshly initialized template; every default then keeps it byte-for-byte.
    result = invoke(binary, root, url, ["setup"], "", HOME=str(home), MICROAGENT_CONFIG=str(path))
    expect(result.returncode == 1 and "SetupCancelled" in result.stderr, result)
    template = path.read_text(encoding="utf-8")
    expect(
        template == Path(__file__).resolve().parents[1].joinpath("config.example.toml").read_text(encoding="utf-8"),
        template,
    )
    result = invoke(binary, root, url, ["setup"], "\n" * 20, HOME=str(home), MICROAGENT_CONFIG="\t" + str(path))
    expect(result.returncode == 0 and path.read_text(encoding="utf-8") == template, result)
    # Provider escaping, toggles, invalid input retries, and a custom remote endpoint.
    answers = ["bad-url", url, 'model"with\\escapes', "secret", "n", "n", "n", "n"]
    answers += ["maybe", "n"] + [""] * 8
    answers += ["y", "http://example.com/mcp", url + "/mcp", "BAD NAME", "REMOTE_KEY", "", "", ""]
    result = invoke(binary, root, url, ["setup", "--config=" + str(path)], "\n".join(answers) + "\n")
    expect(result.returncode == 0 and not Provider.seen, result)
    saved = path.read_text(encoding="utf-8")
    cfg = tomllib.loads(saved)
    expect(cfg["base_url"] == url and cfg["model"] == 'model"with\\escapes' and cfg["api_key"] == "secret", cfg)
    expect(cfg["system_prompt_extra"] == "" and cfg["agents_files"] == [] and cfg["skills"] == [], cfg)
    expect(cfg["tools"]["bash"]["enabled"] is False, cfg)
    expect(cfg["tools"]["web_search"] == {"enabled": True, "url": url + "/mcp", "api_key_env": "REMOTE_KEY"}, cfg)
    expect(path.stat().st_mode & 0o777 == 0o600 and "secret" not in result.stderr, result)
    # Existing custom settings survive; cancellation never writes partial answers.
    existing = saved + '\n[[mcp]]\nname = "custom"\nurl = "https://example.com/mcp"\n'
    path.write_text(existing, encoding="utf-8")
    result = invoke(binary, root, url, ["setup", "--config", str(path)], "https://changed.example/v1\n")
    expect(result.returncode == 1 and path.read_text(encoding="utf-8") == existing, result)
    result = invoke(binary, root, url, ["setup", "--config", str(path)], "\n" * 22)
    expect(result.returncode == 0 and path.read_text(encoding="utf-8") == existing, result)
    # An endpoint configured while a preset is off remains its default when enabled again.
    path.write_text(existing.replace("\nenabled = true\n", "\nenabled = false\n"), encoding="utf-8")
    result = invoke(binary, root, url, ["setup", "--config", str(path)], "\n" * 16 + "y\n" + "\n" * 5)
    expect(result.returncode == 0 and path.read_text(encoding="utf-8") == existing, result)
    # Reject disabling the last tool and allow a corrected answer to finish setup.
    result = invoke(binary, root, url, ["setup", "--config", str(path)], "\n" * 7 + "n\n" * 9 + "y\n" + "\n" * 6)
    expect(result.returncode == 0 and "At least one built-in tool" in result.stderr, result)
    cfg = tomllib.loads(path.read_text(encoding="utf-8"))
    expect(not any(settings["enabled"] for name, settings in cfg["tools"].items() if name != "web_search"), cfg)
    expect("todo" not in cfg["tools"], cfg)  # The remaining tool keeps its enabled default.
    result = invoke(binary, root, url, ["setup", "--unknown"], "")
    expect(result.returncode == 2 and not Provider.seen, result)


def check_setup_terminal(binary: Path, root: Path) -> None:
    path = root / "terminal-config.toml"
    for cancel in (False, True):
        master, slave = pty.openpty()
        try:
            # because: the explicitly supplied local binary is the program under test
            with subprocess.Popen(  # noqa: S603
                [str(binary), "setup", "--config", str(path)],
                stdin=slave,
                stdout=slave,
                stderr=slave,
                env={"PATH": os.environ.get("PATH", "")},
            ) as process:
                try:
                    os.write(master, b"\n\n")
                    output = b""
                    while b"API key [" not in output:
                        expect(select.select([master], [], [], 5)[0], "setup did not ask for API key")
                        output += os.read(master, 4096)
                    expect(not termios.tcgetattr(slave)[3] & termios.ECHO, "API key input was echoed")
                    if not cancel:
                        os.write(master, b"test-terminal-key\n")
                        while b"Enable the system prompt" not in output:
                            expect(select.select([master], [], [], 5)[0], "setup did not finish key input")
                            output += os.read(master, 4096)
                        expect(b"test-terminal-key" not in output, output)
                        expect(termios.tcgetattr(slave)[3] & termios.ECHO, "terminal echo was not restored")
                    else:
                        # Interrupt hidden input and verify the terminal survives.
                        process.terminate()
                        process.wait(timeout=5)
                        expect(process.returncode == 130, process.returncode)
                        expect(termios.tcgetattr(slave)[3] & termios.ECHO, "interrupt left terminal echo disabled")
                finally:
                    if process.poll() is None:
                        process.terminate()
                    process.wait(timeout=5)
        finally:
            os.close(master)
            os.close(slave)


def check(binary: Path, root: Path, url: str) -> None:
    Provider.reset()
    result = invoke(
        binary,
        root,
        url,
        ["--repl", "--max-turns", "1", "--max-spend-tokens", "1"],
        " \r\nfirst\r\nsecond\n/quit\nignored\n",
    )
    expect(result.returncode == 0, result.stderr)
    expect(len(Provider.seen) == 2, Provider.seen)
    messages = Provider.seen[-1]["messages"]
    expect([m["role"] for m in messages] == ["system", "user", "assistant", "user"], messages)
    expect([m["content"] for m in messages[1:]] == ["first", "answer", "second"], messages)
    usage = [
        json.loads(line)["usage"]["total_tokens"]
        for line in result.stdout.splitlines()
        if line.startswith('{"type":"usage"')
    ]
    expect(usage == [11, 22], result.stdout)
    logs = list((root / "sessions").glob("*.jsonl"))
    expect(len(logs) == 1 and len(logs[0].read_text(encoding="utf-8").splitlines()) == 2, logs)

    result = invoke(binary, root, url, ["--repl", "initial"], "last")
    expect(result.returncode == 0 and len(Provider.seen) == 2, result.stderr)
    expect(Provider.seen[-1]["messages"][-1]["content"] == "last", Provider.seen)

    result = invoke(binary, root, url, ["--repl"], "/quit\n")
    expect(result.returncode == 0 and not Provider.seen and not result.stdout, result.stderr)
    result = invoke(binary, root, url, ["--repl"], "x" * (64 * 1024) + "\n")
    expect(result.returncode == 2 and "REPL prompt" in result.stderr and not Provider.seen, result.stderr)

    result = invoke(binary, root, url, ["one task"], "ignored\n")
    expect(result.returncode == 0 and len(Provider.seen) == 1 and "> " not in result.stderr, result.stderr)
    # Each switch below is set immediately before the one `invoke` that reads it
    # and cleared immediately after its assertions, so no case inherits the
    # shape of the one above it. The billed-error pair at the end of this
    # function is the reason the clears have to exist at all: those two are the
    # last cases, and a switch left on there is a provider that answers every
    # turn `check_timeouts` runs with a failure instead of an answer.
    Provider.trailing_newline = False
    result = invoke(binary, root, url, ["unterminated DONE"], "")
    expect(result.returncode == 0, result.stderr)
    Provider.trailing_newline = True
    Provider.bad_call = True
    result = invoke(binary, root, url, ["recover invalid tool call"], "")
    expect(result.returncode == 0 and len(Provider.seen) == 2, result.stderr)
    expect(Provider.seen[-1]["messages"][-1]["role"] == "user", Provider.seen)
    Provider.empty = True
    result = invoke(binary, root, url, ["--repl"], "first\nsecond\n")
    expect(result.returncode == 3 and len(Provider.seen) == 1, result.stderr)
    Provider.empty = False
    Provider.billed_error = True
    for invalid in (False, True):
        Provider.invalid_usage = invalid
        result = invoke(binary, root, url, ["billed stream failure"], "")
        expect(result.returncode == 1 and len(Provider.seen) == 1 and "not retried" in result.stderr, result.stderr)


class SilentTLS(BaseRequestHandler):
    def handle(self) -> None:
        # Consume ClientHello but never answer it. Exit when cancellation closes the socket.
        while self.request.recv(4096):
            pass


def check_timeouts(binary: Path, root: Path, url: str) -> None:
    Provider.reset()
    # `hang` stays on across the three cases here because all three need a
    # provider that never answers; `hang_body` is what tells a response with no
    # body from a response with one, and is set per case. The reset above is
    # also what puts both back, because the last case below hangs on `hang`
    # alone and the function returns with the provider still silent.
    Provider.hang = True
    result = invoke(binary, root, url, ["--budget", "1", "--stall-timeout", "120", "silent response"], "")
    expect(result.returncode == 3 and len(Provider.seen) == 1 and "budget" in result.stderr, result.stderr)
    result = invoke(binary, root, url, ["--stall-timeout", "1", "silent response without budget"], "")
    expect(result.returncode == 1 and len(Provider.seen) == 1, result.stderr)
    Provider.hang_body = True
    result = invoke(binary, root, url, ["--stall-timeout", "1", "silent stream"], "")
    expect(result.returncode == 1 and len(Provider.seen) == 1 and "Timeout" in result.stderr, result.stderr)
    Provider.hang_body = False
    Provider.hang = False
    with ThreadingTCPServer(("127.0.0.1", 0), SilentTLS) as server:
        thread = Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            tls_url = f"https://127.0.0.1:{server.server_address[1]}/v1"
            result = invoke(binary, root, tls_url, ["--budget", "1", "TLS deadline"], "")
            expect(result.returncode == 3 and "budget" in result.stderr, result.stderr)
            result = invoke(binary, root, tls_url, ["--stall-timeout", "1", "TLS stall"], "")
            expect(result.returncode == 1 and "Timeout" in result.stderr, result.stderr)
        finally:
            server.shutdown()
            thread.join()


def check_response_cap(binary: Path, root: Path, url: str) -> None:
    Provider.reset()
    Provider.response_bytes = 16 * 1024 * 1024
    result = invoke(binary, root, url, ["exact response ceiling"], "")
    expect(result.returncode == 0 and len(Provider.seen) == 1, result.stderr)
    Provider.response_bytes += 65536
    result = invoke(binary, root, url, ["oversized unfinished response"], "")
    expect(result.returncode == 3 and len(Provider.seen) == 1 and "byte ceiling" in result.stderr, result.stderr)
    expect(not (root / "ceiling-marker").exists(), "a tool from the oversized response was executed")
    Provider.response_calls = True
    result = invoke(binary, root, url, ["--stall-timeout", "1", "oversized rejected tool arguments"], "")
    expect(result.returncode == 3 and len(Provider.seen) == 1 and "byte ceiling" in result.stderr, result.stderr)
    expect(not (root / "ceiling-marker").exists(), "a tool from the oversized rejected-call response was executed")
    Provider.reset()


def check_tool_outcomes(binary: Path, root: Path, url: str) -> None:
    Provider.reset()
    # A call the model makes that fails is the case nothing used to record:
    # the gutter line names the command, and whether it worked lived only in
    # the conversation, which goes to the provider. One run read from stderr
    # alone could not say which of its tools failed or which were slow, so
    # each outcome here is pinned to the line it draws.
    for command, word in (("exit 0", "ok"), ("exit 7", "FAILED")):
        Provider.tool_call_args = json.dumps({"command": command})
        result = invoke(binary, root, url, ["--max-turns", "1", "run it"], "")
        expect(result.returncode == 3, (command, result.stderr))
        outcomes = [line for line in result.stderr.splitlines() if line.startswith("  ")]
        expect(len(outcomes) == 1, (command, result.stderr))
        expect(word in outcomes[0], (command, result.stderr))
        # The duration is a number rather than a placeholder, so the line
        # answers how long the call took and not only whether it worked.
        expect(outcomes[0].endswith("ms"), (command, result.stderr))
    Provider.tool_call_args = ""


def check_endpoint_paths(binary: Path, root: Path, url: str) -> None:
    Provider.reset()
    for suffix, expected in (
        ("", "/chat/completions"),
        ("/v1/", "/v1/chat/completions"),
        ("/v1?api-version=fixture", "/v1/chat/completions?api-version=fixture"),
        ("/v1/?api-version=fixture/", "/v1/chat/completions?api-version=fixture/"),
        ("/v1#fixture", "/v1/chat/completions"),
        ("/gateway%2Fv1?key=a%26b#fixture", "/gateway%2Fv1/chat/completions?key=a%26b"),
    ):
        result = invoke(binary, root, url.removesuffix("/v1") + suffix, ["endpoint path check"], "")
        expect(result.returncode == 0 and Provider.paths == [expected], (result.stderr, Provider.paths))


def load_harbor() -> ModuleType:
    # Exercise the actual readers without installing Harbor or starting a container.
    base = ModuleType("harbor.agents.base")
    base.__dict__["BaseAgent"] = object
    spec = importlib.util.spec_from_file_location(
        "adapter_check", Path(__file__).resolve().parent.parent / "integrations/harbor/microagent_agent.py"
    )
    if spec is None or spec.loader is None:
        raise AssertionError("the Harbor adapter could not be loaded")
    adapter = importlib.util.module_from_spec(spec)
    with patch.dict(sys.modules, {"harbor.agents.base": base}):
        spec.loader.exec_module(adapter)
    return adapter


def check_harbor_numbers(binary: Path, root: Path, url: str) -> None:
    Provider.reset()
    adapter = load_harbor()
    widths = (
        ("MICROAGENT_MAX_TOKENS", 32),
        ("MICROAGENT_STALL_TIMEOUT", 32),
        ("MICROAGENT_MAX_TURNS", 64),
        ("MICROAGENT_BUDGET_SECONDS", 64),
        ("MICROAGENT_MAX_SPEND_TOKENS", 64),
    )
    for name, bits in widths:
        value = str(1 << bits)
        with patch.dict(
            os.environ, {"MICROAGENT_API_KEY": "test", "MICROAGENT_BASE_URL": url, name: value}, clear=True
        ):
            try:
                adapter.validate_env()
            except RuntimeError as error:
                expect(name in str(error), error)
            else:
                raise AssertionError(f"Harbor accepted invalid {name}={value}")
        result = invoke(binary, root, url, ["number check"], "", **{name: value})
        expect(result.returncode == 2 and name in result.stderr.splitlines()[0] and not Provider.seen, result.stderr)
        maximum = str((1 << bits) - 1)
        with patch.dict(
            os.environ, {"MICROAGENT_API_KEY": "test", "MICROAGENT_BASE_URL": url, name: maximum}, clear=True
        ):
            adapter.validate_env()
        result = invoke(binary, root, url, ["number boundary"], "", **{name: maximum})
        expect(result.returncode == 0 and len(Provider.seen) == 1, result.stderr)
        if name == "MICROAGENT_BUDGET_SECONDS":
            result = invoke(binary, root, url, ["--budget", maximum, "budget boundary"], "")
            expect(result.returncode == 0 and len(Provider.seen) == 1, result.stderr)
    for name in ("MICROAGENT_MAX_TOKENS", "MICROAGENT_STALL_TIMEOUT", "MICROAGENT_MAX_SPEND_TOKENS"):
        for value in ("١٢", "+12", "1_2"):
            with patch.dict(os.environ, {name: value}, clear=True):
                forwarded = adapter.optional_ceiling(name)
            expect(forwarded == "12", (name, value, forwarded))
            result = invoke(binary, root, url, ["canonical number"], "", **{name: forwarded})
            expect(result.returncode == 0 and len(Provider.seen) == 1, result.stderr)
            if name == "MICROAGENT_MAX_TOKENS":
                expect(Provider.seen[0]["max_tokens"] == 12, Provider.seen)
    expect(
        adapter.checked_int("MICROAGENT_AGENT_TIMEOUT_SEC", str(1 << 64)) == 1 << 64, "Harbor's own timeout was capped"
    )


def check_harbor_connection_values(binary: Path, root: Path, url: str) -> None:
    Provider.reset()
    adapter = load_harbor()
    invalid = (
        ("MICROAGENT_BASE_URL", "https://"),
        ("MICROAGENT_BASE_URL", "https://localhost:65536/v1"),
        ("MICROAGENT_BASE_URL", "https://localhost:invalid/v1"),
        ("MICROAGENT_BASE_URL", "https://localhost:/v1"),
        ("MICROAGENT_BASE_URL", "https://[::1]:/v1"),
        ("MICROAGENT_BASE_URL", "http://fixtureuser:fixturesecret@192.0.2.1/v1"),
        ("MICROAGENT_BASE_URL", "https://fixtureuser:fixturesecret@localhost:invalid/v1"),
        ("MICROAGENT_BASE_URL", "fixtureuser:fixturesecret@host/v1"),
        ("MICROAGENT_BASE_URL", "https://localhost/v1\nheader"),
        ("MICROAGENT_API_KEY", "fixture\nheader"),
        ("MICROAGENT_API_KEY", "fixture\x7f"),
    )
    for name, value in invalid:
        with patch.dict(
            os.environ, {"MICROAGENT_API_KEY": "test", "MICROAGENT_BASE_URL": url, name: value}, clear=True
        ):
            try:
                adapter.validate_env()
            except RuntimeError as error:
                expect(name in str(error), error)
                expect("fixture" not in str(error), error)
            else:
                raise AssertionError(f"Harbor accepted invalid {name}")
        result = invoke(binary, root, url, ["connection setting check"], "", **{name: value})
        expect(result.returncode in (1, 2) and not Provider.seen, result.stderr)
        expect("fixturesecret" not in result.stderr and "fixtureuser" not in result.stderr, result.stderr)
    for value in (url, "https://localhost:65535/v1", "https://[::1]:443/v1"):
        with patch.dict(os.environ, {"MICROAGENT_API_KEY": "fixture", "MICROAGENT_BASE_URL": value}, clear=True):
            adapter.validate_env()
            expect(adapter.base_url() == value and adapter.api_key() == "fixture", value)


if __name__ == "__main__":
    binary = Path(sys.argv[1]).resolve(strict=True)
    with tempfile.TemporaryDirectory() as temp, ThreadingHTTPServer(("127.0.0.1", 0), Provider) as server:
        thread = Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            check_refs(Path(temp))
            check_setup(binary, Path(temp), f"http://127.0.0.1:{server.server_port}/v1")
            check_setup_terminal(binary, Path(temp))
            check(binary, Path(temp), f"http://127.0.0.1:{server.server_port}/v1")
            check_timeouts(binary, Path(temp), f"http://127.0.0.1:{server.server_port}/v1")
            check_response_cap(binary, Path(temp), f"http://127.0.0.1:{server.server_port}/v1")
            check_tool_outcomes(binary, Path(temp), f"http://127.0.0.1:{server.server_port}/v1")
            check_endpoint_paths(binary, Path(temp), f"http://127.0.0.1:{server.server_port}/v1")
            check_harbor_numbers(binary, Path(temp), f"http://127.0.0.1:{server.server_port}/v1")
            check_harbor_connection_values(binary, Path(temp), f"http://127.0.0.1:{server.server_port}/v1")
        finally:
            server.shutdown()
            thread.join()
    print(
        "CLI checks passed: REPL, ceilings, usage, sessions, tool outcomes, "
        "input, deadlines, exit statuses and citations"
    )
