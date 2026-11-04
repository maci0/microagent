# Security policy

## Supported versions

Only the latest release is supported. There is no backport window and no LTS
line: a fix ships in the next release, and `microagent update` moves you to it.
This matches the supported-version statements in
[docs/usage.md](docs/usage.md#versioning) and the preamble of
[CHANGELOG.md](CHANGELOG.md).

The current release is `0.20.0`, as declared in `build.zig.zon`.

## Reporting a vulnerability

Report a suspected vulnerability through a private advisory on the
[GitHub repository](https://github.com/maci0/microagent): **Security →
Report a vulnerability**. Do not open a public issue for a suspected
vulnerability, and do not attach a reproducer that needs a live API key.

Include the version, the command that reproduces it, and the observed
behavior. There is no published response-time commitment and no named
security contact beyond that advisory channel; this file does not invent one.

## Scope

`microagent` is a local CLI with no listener, no server, and no database. It
holds no user data of its own: it exposes the operator's own machine, and the
asset worth stealing on its own is the API key. The full attack surface,
trust boundaries, and mitigations are in
[docs/threat-model.md](docs/threat-model.md). That document is the living
threat model; this file is the reporting path and supported-version statement.
