//! What the two programs over one machine share: the CA-bundle escape hatch, a
//! deadline, the two output sinks (stderr for notes and stdout for the answers
//! a caller parses), and the path a write through a symlink really lands on.
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
///
/// The error is the caller's, because a stream that refuses the bytes is a
/// different fault depending on what they were: a full disk or a closed pipe
/// means the answer this run was asked for never arrives, which is a run that
/// failed rather than one that finished. Text nobody is waiting on (the help
/// text, `--version`) may drop it; the model's own words may not.
pub fn writeOut(io: Io, bytes: []const u8) !void {
    try Io.File.stdout().writeStreamingAll(io, bytes);
}

/// A line on stderr, which is where gauntlet shows harness notes; stdout stays
/// the model's own words and the usage line.
pub fn note(io: Io, arena: std.mem.Allocator, comptime fmt: []const u8, args: anytype) void {
    const msg = std.fmt.allocPrint(arena, fmt, args) catch return;
    writeErr(io, msg);
}

/// Where a CA bundle is named, for the agent run and for `update` alike: the
/// project's own variable first, then the one the system trust store tooling
/// already uses. Empty means no bundle was named, and so does a value that is
/// nothing but whitespace, which is not a path any filesystem holds.
pub fn caBundlePath(env: *const std.process.Environ.Map) []const u8 {
    if (env.get("MICROAGENT_CA_BUNDLE")) |v| {
        const p = std.mem.trim(u8, v, " \t\r\n");
        if (p.len > 0) return p;
    }
    if (env.get("SSL_CERT_FILE")) |v| {
        const p = std.mem.trim(u8, v, " \t\r\n");
        if (p.len > 0) return p;
    }
    return "";
}

/// The file `path` names once a symlink is followed, which is the file opening
/// `path` would have written to and the only one a rename may replace.
///
/// Both callers need it: `write` and `edit` so a rewrite through a link
/// replaces the real file and leaves the link a link, and `update` so the
/// binary is replaced rather than the link pointing at it. It is written once
/// here because the answer is path arithmetic, and path arithmetic spelled
/// inline is where a hardcoded `/` hides: the join goes through
/// `std.fs.path`, so it uses the separator the target actually has.
///
/// `name_buf` receives the link's own bytes and `join_buf` the answer when the
/// link is relative; both belong to the caller, and the returned slice is one
/// of them, or `path` itself when `path` is not a link.
pub fn resolveSymlinkTarget(
    io: Io,
    dir: Io.Dir,
    path: []const u8,
    name_buf: []u8,
    join_buf: []u8,
) ![]const u8 {
    const n = dir.readLink(io, path, name_buf) catch |err| switch (err) {
        error.NotLink, error.FileNotFound => return path,
        else => |e| return e,
    };
    const link = name_buf[0..n];
    if (std.fs.path.isAbsolute(link)) return link;
    // A relative link is read against the directory holding the link, not
    // against the process's working directory. A bare name has no directory,
    // and the caller handed in the directory that name is already relative to.
    const dir_end = std.fs.path.dirname(path) orelse return link;
    return std.fmt.bufPrint(join_buf, "{s}{c}{s}", .{ dir_end, std.fs.path.sep, link }) catch link;
}

/// A monotonic duration for `Io.Timeout`, from milliseconds. A tool deadline
/// and a provider read both name one, so the conversion is spelled once here
/// rather than at each call site.
pub fn durationMs(ms: u64) Io.Timeout {
    return .{ .duration = .{ .raw = .{ .nanoseconds = ms *| std.time.ns_per_ms }, .clock = .awake } };
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

    // A wrapper that exports a path read from a file carries the newline that
    // file ended with, and a path with one is a file no filesystem holds.
    try env.put("MICROAGENT_CA_BUNDLE", "/tmp/bundle.pem\n");
    try std.testing.expectEqualStrings("/tmp/bundle.pem", caBundlePath(&env));
    try env.put("MICROAGENT_CA_BUNDLE", "  ");
    try std.testing.expectEqualStrings("/etc/ssl/certs/ca-certificates.crt", caBundlePath(&env));
}

test "a write target follows a symlink, relative or absolute" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "real", .data = "old" });
    try tmp.dir.createDirPath(std.testing.io, "sub");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "sub/real2", .data = "old" });

    var name_buf: [std.fs.max_path_bytes]u8 = undefined;
    var join_buf: [2 * std.fs.max_path_bytes]u8 = undefined;

    // A link whose target is written relative to the link's own directory.
    // Resolving it against the working directory instead would name a file
    // that does not exist, and a rename to it would land beside the tree.
    try tmp.dir.symLink(std.testing.io, "real2", "sub/link", .{});
    const want_rel = try std.fs.path.join(std.testing.allocator, &.{ "sub", "real2" });
    defer std.testing.allocator.free(want_rel);
    try std.testing.expectEqualStrings(
        want_rel,
        try resolveSymlinkTarget(std.testing.io, tmp.dir, "sub/link", &name_buf, &join_buf),
    );

    // An absolute link needs no join and must not be rewritten as one. The
    // temporary directory is reached through the working directory, so the
    // target is written as the absolute path that resolves to `real`.
    const abs = try std.fs.path.resolve(
        std.testing.allocator,
        &.{ ".zig-cache", "tmp", &tmp.sub_path, "real" },
    );
    defer std.testing.allocator.free(abs);
    try tmp.dir.symLink(std.testing.io, abs, "abs_link", .{});
    try std.testing.expectEqualStrings(
        abs,
        try resolveSymlinkTarget(std.testing.io, tmp.dir, "abs_link", &name_buf, &join_buf),
    );

    // A path that is not a link is its own target, and a link with no
    // directory part is already relative to the directory the caller opened.
    try std.testing.expectEqualStrings(
        "real",
        try resolveSymlinkTarget(std.testing.io, tmp.dir, "real", &name_buf, &join_buf),
    );
    try tmp.dir.symLink(std.testing.io, "real", "bare", .{});
    try std.testing.expectEqualStrings(
        "real",
        try resolveSymlinkTarget(std.testing.io, tmp.dir, "bare", &name_buf, &join_buf),
    );
}
