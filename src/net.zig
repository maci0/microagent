//! What the two HTTP clients share: the CA-bundle escape hatch, the two
//! output sinks (stderr for notes, stdout for the answers a caller parses),
//! and the one safe way to shorten text on its way to a log line.
//!
//! A leaf module. It imports nothing from the rest of the program, so the
//! agent run and `update` can both use it without either of them importing
//! the other.

const std = @import("std");
const Io = std.Io;

/// Points the TLS client at a PEM file when one was named. Many container
/// images (bare ubuntu, distroless) ship no ca-certificates at all, and the
/// client's own rescan then fails with TlsInitializationFailed before a single
/// request is sent. A path that cannot be read is a warning, not a failure: the
/// client falls back to scanning the system store.
pub fn loadCaBundle(
    client: *std.http.Client,
    io: Io,
    gpa: std.mem.Allocator,
    path: []const u8,
    arena: std.mem.Allocator,
) void {
    if (path.len == 0) return;
    const abs = std.fs.path.resolve(arena, &.{path}) catch path;
    const now = Io.Clock.real.now(io);
    client.ca_bundle.addCertsFromFilePathAbsolute(gpa, io, now, abs) catch |err| {
        note(io, arena, "microagent: cannot read CA bundle {s}: {s}; scanning the system store instead\n", .{ path, @errorName(err) });
        return;
    };
    // Non-null `now` is how the client knows the bundle is already populated.
    client.now = now;
}

/// Bytes on stderr, which is where gauntlet shows harness notes. A closed
/// stream costs the run nothing: the reader left, it is not a fault.
pub fn writeErr(io: Io, bytes: []const u8) void {
    Io.File.stderr().writeStreamingAll(io, bytes) catch {};
}

/// Bytes on stdout: the model's own words and the one line a caller parses.
pub fn writeOut(io: Io, bytes: []const u8) void {
    Io.File.stdout().writeStreamingAll(io, bytes) catch {};
}

/// A line on stderr, which is where gauntlet shows harness notes; stdout stays
/// the model's own words and the usage line.
pub fn note(io: Io, arena: std.mem.Allocator, comptime fmt: []const u8, args: anytype) void {
    const msg = std.fmt.allocPrint(arena, fmt, args) catch return;
    writeErr(io, msg);
}

/// The first `max` bytes of `s`, cut on a UTF-8 codepoint boundary. Every
/// caller shortens text that came from outside the process (a prompt, a base
/// url, an argv entry) to keep it on one log line, and a cut inside a
/// codepoint leaves a half sequence that renders as a replacement character at
/// best. The limit is in bytes because that is what bounds the line; what it
/// must not do is end mid-character.
pub fn clamp(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    var end = max;
    while (end > 0 and s[end] & 0xc0 == 0x80) end -= 1;
    return s[0..end];
}

/// Where a CA bundle is named, for the agent run and for `update` alike: the
/// project's own variable first, then the one the system trust store tooling
/// already uses. Empty means no bundle was named.
pub fn caBundlePath(env: *const std.process.Environ.Map) []const u8 {
    if (env.get("MICROAGENT_CA_BUNDLE")) |v| if (v.len > 0) return v;
    if (env.get("SSL_CERT_FILE")) |v| if (v.len > 0) return v;
    return "";
}

test "the CA bundle comes from the project's variable first, then the system one" {
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    try std.testing.expectEqualStrings("", caBundlePath(&env));

    try env.put("SSL_CERT_FILE", "/etc/ssl/certs/ca-certificates.crt");
    try std.testing.expectEqualStrings("/etc/ssl/certs/ca-certificates.crt", caBundlePath(&env));

    try env.put("MICROAGENT_CA_BUNDLE", "/tmp/bundle.pem");
    try std.testing.expectEqualStrings("/tmp/bundle.pem", caBundlePath(&env));

    // An empty value is not a bundle named; the next one in the chain answers.
    try env.put("MICROAGENT_CA_BUNDLE", "");
    try std.testing.expectEqualStrings("/etc/ssl/certs/ca-certificates.crt", caBundlePath(&env));
}

test "a cut never leaves half a code point" {
    try std.testing.expectEqualStrings("abc", clamp("abc", 8));
    // A string exactly at the limit is kept whole, not cut to one byte short.
    try std.testing.expectEqualStrings("abc", clamp("abc", 3));
    try std.testing.expectEqualStrings("ab", clamp("abcd", 2));
    try std.testing.expectEqualStrings("", clamp("abc", 0));
    // The bytes go into a log line verbatim, so anything clamp keeps has to be
    // a whole character: prompts and repository names are full of multi-byte
    // text and a cut lands in one often enough to matter.
    const text = "caf\u{00e9} \u{1f600} fin";
    var n: usize = 0;
    while (n <= text.len) : (n += 1) {
        const kept = clamp(text, n);
        try std.testing.expect(kept.len <= n);
        try std.testing.expect(std.unicode.utf8ValidateSlice(kept));
        try std.testing.expect(std.mem.startsWith(u8, text, kept));
    }
    // The cut is at the boundary, not somewhere short of it.
    try std.testing.expectEqualStrings("caf\u{00e9} ", clamp(text, 7));
    try std.testing.expectEqualStrings("caf\u{00e9} \u{1f600}", clamp(text, 10));
    try std.testing.expectEqualStrings("", clamp("\u{1f600}", 2));
}

test "the 80-byte log-line limit holds whole characters" {
    // A doubled prompt and a `--repo` that is not owner/name are both shortened
    // to 80 bytes for a log line, and a run of characters wider than one byte
    // puts that cut inside one.
    var run: [120]u8 = undefined;
    for (0..30) |i| _ = std.unicode.utf8Encode(0x1f600, run[4 * i ..][0..4]) catch unreachable;
    // 80 is a whole number of four-byte characters, so nothing is dropped.
    try std.testing.expectEqualStrings(run[0..80], clamp(&run, 80));
    // One byte further in, the character the cut would split is dropped whole
    // rather than kept as its lead byte and two of its four.
    try std.testing.expectEqualStrings(run[0..80], clamp(&run, 81));
    try std.testing.expect(std.unicode.utf8ValidateSlice(clamp(&run, 81)));
}
