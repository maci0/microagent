//! What the two HTTP clients share: the CA-bundle escape hatch and the stderr
//! note line.
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

/// A line on stderr, which is where gauntlet shows harness notes; stdout stays
/// the model's own words and the usage line.
pub fn note(io: Io, arena: std.mem.Allocator, comptime fmt: []const u8, args: anytype) void {
    const msg = std.fmt.allocPrint(arena, fmt, args) catch return;
    Io.File.stderr().writeStreamingAll(io, msg) catch {};
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
