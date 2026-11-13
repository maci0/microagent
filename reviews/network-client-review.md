Summary: credentials, requests, response limits and update integrity

# Network client

Your goal is to trace outbound requests and responses through `src/net.zig`, `src/main.zig`,
`src/mcp.zig`, `src/update.zig` and the stream parser.

Read and follow the [shared review protocol](README.md#review-protocol) in
`reviews/README.md` before starting. This file is a
reusable checklist, not a review report.

## Scope and priorities

Keep changes within the request, transport and download paths. Preserve checks,
ceilings and validation; raising a limit needs a reason and a test. Do not
restructure the HTTP layer or change flags, the config schema or the help text;
report a defect in what an option accepts for the
[CLI-contract review](cli-contract-review.md). Report threat model updates for
the threat-model review.

Only use loopback servers you control, such as `bench/stub_provider.py`; do not
send real credentials. Test each nontrivial fix and run the relevant gate.

Prioritize credential leaks and redirects, missing limits and deadlines, parser
failures, update integrity, then terminal and log output.

## Checklist

1. **A key attached where the code says it is not.** `net.urlCarriesKey` in
   `src/net.zig` is the rule that a plaintext URL sends the key in the clear,
   with loopback hosts excepted. Find every call that attaches a credential: the
   `authHeaders` builder in `src/main.zig` (the chat request and `fetchModels`),
   `bearerFor` and `githubBearer` in `src/update.zig`, and the header assembly
   in `src/mcp.zig` where `default_key_header` is applied. For each one, trace
   the URL it is attached to back to where that URL came from (the `--base-url`
   flag, the config file, the environment, an ACP client's `session/new`, the
   release API) and confirm the check is on the path that
   value actually takes. A builder that checks the scheme and a caller that
   supplies a different URL is the defect this item looks for.

2. **A redirect, or a scheme change, that carries the key to a new host.** Read
   the redirect handling in each of the four callers, which do not spell it the
   same way: the chat request, the ACP model list (`fetchModels` in
   `src/main.zig`) and the remote MCP request (`exchange` in `src/mcp.zig`) each
   set `.redirect_behavior = .unhandled`, while the
   download's `exchange` in `src/update.zig` opens the request itself and passes
   `.redirect_behavior = @fromBackingInt(@intCast(default_redirects))`, the allowance a
   payload-less GET gets by default: an asset is answered by a `302` to the
   release CDN, so following one is a requirement of the download. The download
   therefore relies on `privileged_headers` instead: std strips those on a
   redirect that changes scheme or leaves the host's parent domain, and keeps them on
   `api.github.com` → `api.github.com`. A caller that passes the key as an
   ordinary `headers` entry rather than a privileged one, a scheme downgrade,
   or an unhandled redirect that turns into a followed one, is a finding.
   `trustedGithubUrl` and `hostTrusted` in `src/update.zig` are the code's own
   statement of which hosts may carry the token; a path that reaches a host
   they exclude is a finding whichever direction it fails in.

3. **A certificate trust decision that silently degrades.** `net.caBundlePath`
   resolves the path the operator named and `net.loadCaBundle` installs it. Read
   what happens when the variable is unset, when the path is empty, when it is
   relative, and when the file does not exist: a bundle that fails to load and a
   bundle that is silently dropped both leave the client on the platform's own
   roots, and only one of them tells the operator. A path the code expands
   (`expandHome`, `resolveSymlinkTarget`) that can leave the tree it was meant
   to stay in is the same item.

4. **A response read with no ceiling.** Every read of a remote body needs a
   named bound. Check each one against the constants already in the tree:
   `stream.max_response_bytes` for a chat response, `max_frame_bytes` in
   `src/main.zig` for one frame, `max_error_body_bytes` for an error body,
   `max_models_body_bytes` for the ACP model list, `max_api_bytes`, `max_sidecar_bytes` and `max_asset_bytes` in
   `src/update.zig`, and the read sizes in `src/mcp.zig`. A read that trusts a
   `Content-Length` header, that appends into an `ArrayList` sized from the
   response, or that has no bound at all is a finding, and so is a ceiling a
   later edit can raise without a test pinning it.

5. **A request with no deadline, or a retry that outruns its caller.**
   `net.durationMs` turns a configured number into a timeout, and every call
   site has to carry one: a connect or a read that inherits the client's
   default leaves a hung server able to hold the turn open. Read
   `fetchTimeoutMs` in `src/update.zig` against the size it scales with, the
   chat retry loop in `src/main.zig` against `net.retryablePostStatus`, and the
   download's retry in `fetch` and `fetchOnce` in `src/update.zig` against
   `net.retryableStatus` and `waitMs`, both against `net.retryAfterMs` and
   `net.max_retry_after_ms`: an attempt count with no
   ceiling, a `Retry-After` a server chose taken without its cap, and a retry
   that re-sends an accepted or partially streamed completion are findings. A
   replayable body alone does not make a billable POST safe to retry.

6. **An untrusted value spliced into a header or a request line.** Header
   names and values arrive from the config file, from the environment and from
   an MCP server's own metadata. `net.hasHeaderControlBytes`,
   `net.quoted_value_bytes` and the MCP header validation are the code's own
   defence; find a path that adds a header without passing through them, and a
   URL assembled by string concatenation rather than parsed, since a URL with a
   newline in it is two requests.

7. **A parser the response can drive out of bounds.** The response body is
   untrusted whatever authenticated it. Read the frame folding in
   `src/stream.zig` against a partial line, a frame that never terminates, a
   JSON depth a server chooses, and a tool-call argument stream that grows
   without a bound; read `net.nextLineEnd` and the stdio line reader in
   `src/mcp.zig` against a line with no terminator at all. The existing fuzz
   targets (`fuzzLineSplit`, the stream and sidecar corpora) tell you which
   parsers the tree already believes it can drive; a parser with no such target
   and no ceiling is a finding.

8. **An environment a spawned process inherits.** An MCP server over stdio is a
   program this binary starts, and it must not inherit the provider key.
   `scrubSecrets` in `src/main.zig` is the code's own scrubber, called in
   `runMain` and `runAcp`. Find every path that hands an environment to a child
   (every `std.process.spawn` in the tree: `ToolChild` in `src/tool.zig` and
   `spawnOne` in `src/mcp.zig`) and every caller that supplies that
   environment, including `runAcp`, which passes its own to `acpStartSession`
   and `acpRunPrompt`, and confirm it has been through the same function. A new
   spawn path that builds its own environment map is a finding.

9. **The update path's integrity chain, read end to end.** `parseRelease` in
   `src/update.zig` reads the API document, `assetUrl` turns a `browser_download_url`
   into a full URL, `checksumMatches` compares the sidecar, and
   `installIfVerified` and `replaceBinary` put the bytes in the PATH. Read those
   four in order and check what each one accepts from the previous: a hostname
   the document can move, an asset name that is not the one the running binary
   asked for, a sidecar whose first line names a different file, and a parse
   that accepts more of the body than the one line it reads. A temp file
   written beside the target with permissions wider than the target's is a
   finding, and so is a write that replaces the running binary without the
   rename the previous path needs.

10. **A remote value printed or logged verbatim.** A provider error body, an MCP
    server name, a release description and an asset name are all text this
    binary writes to a terminal and to the session log. Read the writers:
    `net.writeErr` and `net.note`, the session record in `src/session.zig`, and
    `quoteUntrusted` in `src/update.zig`. A response body echoed without a cap,
    without quoting, or into a record the next run replays is a finding, and so
    is any path that can put the key itself into one of them.
