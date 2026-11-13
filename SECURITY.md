# Security policy

## Supported versions

Only the latest release is supported. There is no backport window and no LTS
line: a fix ships in the next release, and `microagent update` moves you to it.
See [CHANGELOG.md](CHANGELOG.md) for release history and
[build.zig.zon](build.zig.zon) for the version in this checkout.

## Reporting a vulnerability

Report a suspected vulnerability through a private advisory on the
[GitHub repository](https://github.com/maci0/microagent): **Security →
Report a vulnerability**. Do not open a public issue for a suspected
vulnerability, and do not attach a reproducer that needs a live API key.

Include the version, the command that reproduces it, and the observed
behavior, with secrets removed. There is no published response-time commitment.

## Scope

`microagent` is a local CLI that can read files, run commands and send repository
content to a provider or configured remote tools. It stores configuration and session
logs on disk. The API keys, source tree and operator's host are assets at risk.
ACP clients can also supply prompts and MCP servers over standard input.

See the [threat model](docs/threat-model.md) for trust boundaries, controls and
known gaps.
