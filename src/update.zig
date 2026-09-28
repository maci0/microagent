//! `microagent update`: compare this build with the latest GitHub release and,
//! when asked to install, replace the running executable only after its bytes
//! match the `.sha256` sidecar the release publishes.
//!
//! The decision (repo shape, exact version, asset name, checksum, trusted URL)
//! is pure; `runChecked` is the only function that talks to GitHub or names the
//! running executable, and tests never execute it.

const std = @import("std");
const builtin = @import("builtin");
const net = @import("net.zig");
const chat = @import("chat.zig");

const version = @import("build_options").version;

pub const default_repo = "maci0/microagent";
pub const tool_name = "microagent";

const exec_mode: std.Io.File.Permissions = @enumFromInt(@as(std.posix.mode_t, 0o755));

const max_api_bytes: usize = 10 * 1024 * 1024;
const max_sidecar_bytes: usize = 64 * 1024;
const max_asset_bytes: usize = 256 * 1024 * 1024;
/// How much of a `--repo` argument an error message quotes back.
const repo_in_error_bytes: usize = 80;

/// A `--repo` short of the quote: the value is whatever the user typed, so it
/// is cut on a codepoint boundary (a partial codepoint in a diagnostic reads
/// as a replacement character in the middle of the flag they got wrong) and
/// the bytes a terminal cannot be shown are escaped. One spelling of it, with
/// the one the agent's own diagnostics use.
fn quoteRepo(arena: std.mem.Allocator, repo: []const u8) []const u8 {
    return chat.safeText(arena, repo, repo_in_error_bytes);
}

pub const Verdict = enum {
    current,
    missing_asset,
    untrusted_url,
    missing_sidecar,
    checksum_mismatch,
    replaced,
};

pub const Inputs = struct {
    running: []const u8,
    tag: []const u8,
    asset_url: ?[]const u8 = null,
    asset: ?[]const u8 = null,
    sidecar_url: ?[]const u8 = null,
    sidecar: ?[]const u8 = null,
    basename: []const u8 = "",
};

pub const ListedAsset = struct {
    name: []const u8,
    url: []const u8,
};

pub const Release = struct {
    tag: []const u8,
    page: []const u8,
    assets: []const ListedAsset,
};

/// One leading `v` on either side, then exact equality. `v0.1.0` is `0.1.0`,
/// and so is a running build labelled the same way as the tag it matches.
pub fn sameRelease(running: []const u8, tag: []const u8) bool {
    return std.mem.eql(u8, bareVersion(running), bareVersion(tag));
}

fn bareVersion(release: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, release, "v")) release[1..] else release;
}

/// Where the running build sits against a published tag, ignoring one leading
/// `v` on either side. Components are `major.minor.patch`, a missing one is 0.
/// Anything else (a pre-release suffix, a fork's tag) is `.eq`, which leaves
/// the caller on exact equality rather than guessing an order.
pub fn compareVersions(running: []const u8, tag: []const u8) std.math.Order {
    const a = parseTriple(running) orelse return .eq;
    const b = parseTriple(tag) orelse return .eq;
    for (a, b) |an, bn| {
        if (an != bn) return if (an < bn) .lt else .gt;
    }
    return .eq;
}

/// `major.minor.patch` with a missing component read as 0, or null when a
/// component is not a plain number.
fn parseTriple(release: []const u8) ?[3]u64 {
    const v = bareVersion(release);
    var out = [3]u64{ 0, 0, 0 };
    var it = std.mem.splitScalar(u8, v, '.');
    var n: usize = 0;
    while (it.next()) |c| {
        if (n == out.len) return null;
        out[n] = std.fmt.parseInt(u64, c, 10) catch return null;
        n += 1;
    }
    return out;
}

/// The release matrix names macOS `aarch64-macos` and `x86_64-macos` (no abi)
/// and Linux `arch-linux-musl`. Zig's abi tag for those macOS targets is
/// `none`; appending it asks for an asset the release does not publish.
pub fn targetTriple(buf: []u8, arch: []const u8, os_name: []const u8, abi: []const u8) []const u8 {
    if (std.mem.eql(u8, abi, "none")) {
        return std.fmt.bufPrint(buf, "{s}-{s}", .{ arch, os_name }) catch buf[0..0];
    }
    return std.fmt.bufPrint(buf, "{s}-{s}-{s}", .{ arch, os_name, abi }) catch buf[0..0];
}

/// The asset to ask for. Linux ships one static musl binary per arch, and a
/// static musl binary runs on a glibc host, so a `-gnu` build asks for the
/// musl asset instead of one the release does not publish. macOS has no abi
/// tag in its asset name.
pub fn assetTriple(buf: []u8, arch: []const u8, os_name: []const u8, abi: []const u8) []const u8 {
    if (std.mem.eql(u8, os_name, "linux")) return targetTriple(buf, arch, "linux", "musl");
    return targetTriple(buf, arch, os_name, abi);
}

pub fn thisAssetTriple(buf: []u8) []const u8 {
    return assetTriple(buf, @tagName(builtin.cpu.arch), @tagName(builtin.os.tag), @tagName(builtin.abi));
}

pub fn writeAssetName(buf: []u8, tag: []const u8, target: []const u8) error{NameTooLong}![]const u8 {
    return std.fmt.bufPrint(buf, "microagent-{s}-{s}", .{ tag, target }) catch return error.NameTooLong;
}

pub fn writeSidecarName(buf: []u8, asset_name: []const u8) error{NameTooLong}![]const u8 {
    return std.fmt.bufPrint(buf, "{s}.sha256", .{asset_name}) catch return error.NameTooLong;
}

fn repoPartOk(part: []const u8) bool {
    if (part.len == 0 or part.len > 100) return false;
    if (std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
    for (part) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '.' or c == '-')) return false;
    }
    return true;
}

/// `owner/name` only. A URL, a second slash, or an empty side is not a repo.
pub fn validRepo(text: []const u8) bool {
    if (std.mem.indexOf(u8, text, "://") != null) return false;
    const slash = std.mem.findScalar(u8, text, '/') orelse return false;
    const owner = text[0..slash];
    const name = text[slash + 1 ..];
    if (std.mem.findScalar(u8, name, '/') != null) return false;
    return repoPartOk(owner) and repoPartOk(name);
}

/// The release API URL. A repo that is not `owner/name` fails here, before
/// any bytes are requested.
pub fn releaseApiUrl(buf: []u8, repo: []const u8) error{ BadRepo, NameTooLong }![]const u8 {
    if (!validRepo(repo)) return error.BadRepo;
    return std.fmt.bufPrint(buf, "https://api.github.com/repos/{s}/releases/latest", .{repo}) catch
        return error.NameTooLong;
}

fn hostTrusted(host: []const u8) bool {
    var lower: [253]u8 = undefined;
    if (host.len == 0 or host.len > lower.len) return false;
    for (host, 0..) |c, i| lower[i] = std.ascii.toLower(c);
    const h = lower[0..host.len];
    if (std.mem.eql(u8, h, "github.com")) return true;
    if (std.mem.endsWith(u8, h, ".github.com")) return true;
    if (std.mem.endsWith(u8, h, ".githubusercontent.com")) return true;
    return false;
}

/// https, and the host is `github.com`, `*.github.com`, or `*.githubusercontent.com`.
/// Userinfo and lookalikes such as `github.com.evil.com` are refused.
pub fn trustedGithubUrl(url: []const u8) bool {
    const prefix = "https://";
    if (url.len < prefix.len) return false;
    for (prefix, 0..) |c, i| {
        if (std.ascii.toLower(url[i]) != c) return false;
    }
    const rest = url[prefix.len..];
    if (std.mem.indexOfAny(u8, rest, "@\\ \t\r\n") != null) return false;
    const slash = std.mem.findScalar(u8, rest, '/') orelse rest.len;
    var host = rest[0..slash];
    if (std.mem.findScalar(u8, host, ':')) |colon| {
        const port = host[colon + 1 ..];
        if (port.len == 0) return false;
        for (port) |c| if (!std.ascii.isDigit(c)) return false;
        host = host[0..colon];
    }
    return hostTrusted(host);
}

/// The `Authorization` value for a request to `url`, or null when that request
/// goes without one.
///
/// The token lifts the anonymous rate limit on the releases API, and that API is
/// the only request here that needs it. The asset and its sidecar are public
/// release files, and GitHub's asset host serves them without authentication, so
/// a token carrying repository scope is never presented to a host that had no
/// reason to see it. The host allowlist already makes every host here GitHub's;
/// narrowing it to the one API that authenticates keeps the grant as wide as the
/// check that uses it rather than as wide as the allowlist.
pub fn bearerFor(url: []const u8, bearer: ?[]const u8) ?[]const u8 {
    const api = "https://api.github.com/";
    if (bearer == null or url.len < api.len) return null;
    for (api, 0..) |c, i| {
        if (std.ascii.toLower(url[i]) != c) return null;
    }
    return bearer;
}

/// Stdout of `--check` is this URL, or nothing when the page is not a GitHub
/// https URL.
pub fn releasePageLine(url: []const u8) error{UntrustedUrl}![]const u8 {
    if (!trustedGithubUrl(url)) return error.UntrustedUrl;
    return url;
}

/// `--check` never downloads an asset. An equal version never does either,
/// and neither does a published tag older than the running build: installing it
/// would replace a newer binary with an older one.
pub fn fetchesAsset(check_only: bool, running: []const u8, tag: []const u8) bool {
    if (check_only) return false;
    if (compareVersions(running, tag) == .gt) return false;
    return !sameRelease(running, tag);
}

/// Sidecar line as `sha256sum` writes it: `<hex>  <basename>`.
pub fn checksumMatches(asset: []const u8, sidecar: []const u8, basename: []const u8) bool {
    const line_end = std.mem.findScalar(u8, sidecar, '\n') orelse sidecar.len;
    var line = sidecar[0..line_end];
    if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
    if (line.len < 66) return false;
    const hex = line[0..64];
    if (!std.mem.eql(u8, line[64..66], "  ")) return false;
    if (!std.mem.eql(u8, line[66..], basename)) return false;
    for (hex) |c| if (!std.ascii.isHex(c)) return false;
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(asset, &digest, .{});
    const got = std.fmt.bytesToHex(digest, .lower);
    for (hex, 0..) |c, i| {
        if (std.ascii.toLower(c) != got[i]) return false;
    }
    return true;
}

pub fn decide(in: Inputs) Verdict {
    if (sameRelease(in.running, in.tag)) return .current;
    const url = in.asset_url orelse return .missing_asset;
    if (!trustedGithubUrl(url)) return .untrusted_url;
    const side_url = in.sidecar_url orelse return .missing_sidecar;
    if (!trustedGithubUrl(side_url)) return .untrusted_url;
    const bytes = in.asset orelse return .missing_asset;
    const side = in.sidecar orelse return .missing_sidecar;
    if (side.len == 0) return .missing_sidecar;
    if (!checksumMatches(bytes, side, in.basename)) return .checksum_mismatch;
    return .replaced;
}

/// Writes `asset` over `dest_name` only when the verdict is `replaced`.
/// A symlink is followed so the real binary changes, not the link.
pub fn replaceVerified(
    io: std.Io,
    dir: std.Io.Dir,
    dest_name: []const u8,
    decision: Verdict,
    asset: []const u8,
) !void {
    if (decision != .replaced) return error.Refused;
    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    var joined_buf: [2 * std.fs.max_path_bytes]u8 = undefined;
    const target = try net.resolveSymlinkTarget(io, dir, dest_name, &link_buf, &joined_buf);

    var af = try dir.createFileAtomic(io, target, .{ .replace = true, .make_path = true, .permissions = exec_mode });
    defer af.deinit(io);
    try af.file.writeStreamingAll(io, asset);
    try af.replace(io);
}

pub fn formatCurrent(buf: []u8, tool: []const u8, running: []const u8, tag: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "{s} {s} is current (latest release: {s})", .{ tool, running, tag });
}

/// A tag that is not a plain triple, so no order can be claimed for it. It is
/// installed all the same, because `sameRelease` did not match and the caller
/// cannot prove the running build is newer; the line only says that the
/// comparison was not made, which "is current" would not.
pub fn formatUncompared(buf: []u8, tool: []const u8, running: []const u8, tag: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "{s} {s} is not the latest release ({s}), which is not a version triple to compare against", .{ tool, running, tag });
}

pub fn formatNewRelease(buf: []u8, tag: []const u8, running: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "New release: {s} (running {s})", .{ tag, running });
}

pub fn formatAhead(buf: []u8, running: []const u8, tag: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "{s} is newer than the latest release ({s}); nothing to install", .{ running, tag });
}

pub fn formatInstalled(buf: []u8, tag: []const u8, path: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "Installed {s} to {s}", .{ tag, path });
}

pub fn parseRelease(arena: std.mem.Allocator, body: []const u8) !Release {
    // Only a body that is not the documented shape is a malformed release.
    // Running out of memory is the machine, not the payload, and reporting it
    // as a bad response sends the operator to GitHub for the wrong thing.
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.MalformedRelease,
    };
    const obj = switch (parsed) {
        .object => |o| o,
        else => return error.MalformedRelease,
    };
    const tag = switch (obj.get("tag_name") orelse return error.MalformedRelease) {
        .string => |s| s,
        else => return error.MalformedRelease,
    };
    const page = switch (obj.get("html_url") orelse return error.MalformedRelease) {
        .string => |s| s,
        else => return error.MalformedRelease,
    };
    const arr = switch (obj.get("assets") orelse return error.MalformedRelease) {
        .array => |a| a,
        else => return error.MalformedRelease,
    };
    var list: std.ArrayList(ListedAsset) = .empty;
    for (arr.items) |item| {
        const asset_obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const name = switch (asset_obj.get("name") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        const url = switch (asset_obj.get("browser_download_url") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        try list.append(arena, .{ .name = name, .url = url });
    }
    return .{
        .tag = tag,
        .page = page,
        .assets = try list.toOwnedSlice(arena),
    };
}

pub fn assetUrl(rel: Release, name: []const u8) ?[]const u8 {
    for (rel.assets) |asset| {
        if (std.mem.eql(u8, asset.name, name)) return asset.url;
    }
    return null;
}

/// A response body that stops at a cap while the bytes are arriving. Testing
/// the length after the fetch bounds what is accepted, not what is allocated:
/// the body is buffered whole first, so a response past the cap costs its full
/// size in memory before anything notices. The overshoot is at most the chunk
/// the reader hands over, which is what the cap has to allow for.
const Capped = struct {
    body: std.Io.Writer.Allocating,
    writer: std.Io.Writer,
    limit: usize,
    over: bool = false,
    vtable: std.Io.Writer.VTable = .{ .drain = drain, .rebase = rebase },

    /// `writer` recovers `self` by field name and points at `self.vtable`, so
    /// both have to be wired up in the final address, not in a copy that gets
    /// returned: `var c: Capped = undefined; try c.start(...)`.
    fn start(self: *Capped, allocator: std.mem.Allocator, limit: usize) !void {
        self.* = .{
            .body = try std.Io.Writer.Allocating.initCapacity(allocator, @min(limit, 64 * 1024)),
            .writer = undefined,
            .limit = limit,
        };
        self.writer = .{ .vtable = &self.vtable, .buffer = &.{} };
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *Capped = @fieldParentPtr("writer", w);
        var total: usize = 0;
        // The last slice of `data` is the one `splat` repeats, so it is not
        // also written in the loop below.
        // A run-length expanded slice can ask for more bytes than a usize
        // holds, and `total` is only a report of what drain wrote. Saturating
        // keeps a hostile body from turning the cap check into a panic.
        for (data[0..data.len -| 1]) |part| {
            try self.body.writer.writeAll(part);
            total +|= part.len;
        }
        if (data.len != 0) {
            const part = data[data.len - 1];
            const reps = @max(splat, 1);
            var one = [_][]const u8{part};
            try self.body.writer.writeSplatAll(&one, reps);
            total +|= part.len *| reps;
        }
        if (self.body.written().len > self.limit) {
            self.over = true;
            return error.WriteFailed;
        }
        return total;
    }

    /// Nothing is buffered here: every byte is on its way to `body` by the time
    /// `drain` is asked for room, so there is nothing to rebase.
    fn rebase(w: *std.Io.Writer, preserve: usize, capacity: usize) std.Io.Writer.Error!void {
        _ = w;
        _ = preserve;
        _ = capacity;
    }
};

fn fail(io: std.Io, comptime fmt: []const u8, args: anytype) u8 {
    var buf: [512]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "microagent update: " ++ fmt ++ "\n", args) catch
        "microagent update: failed\n";
    net.writeErr(io, line);
    return 1;
}

/// One GET, body capped at `max_size` while it streams, into `capped`. The
/// fetch itself, with the headers and the two status cases every caller wants
/// the same answer to. `client` is shared across the three fetches a run makes
/// so the CA store is loaded once. On an HTTP error `status_out` carries the
/// code, which is the difference between "no release yet" and "rate limit".
fn fetchInto(
    client: *std.http.Client,
    capped: *Capped,
    url: []const u8,
    bearer: ?[]const u8,
    status_out: *std.http.Status,
) !void {
    var priv_buf: [1]std.http.Header = undefined;
    const priv_headers: []const std.http.Header = if (bearer) |b| blk: {
        priv_buf[0] = .{ .name = "Authorization", .value = b };
        break :blk priv_buf[0..1];
    } else &.{};

    const result = client.fetch(.{
        .location = .{ .url = url },
        .headers = .{ .user_agent = .{ .override = "microagent/" ++ version } },
        .privileged_headers = priv_headers,
        .response_writer = &capped.writer,
    }) catch |err| {
        if (capped.over) return error.PayloadTooLarge;
        return err;
    };
    status_out.* = result.status;
    if (@intFromEnum(result.status) >= 400) return error.HttpStatus;
}

/// One GET, body capped at `max_size` while it streams, copied into `arena`.
///
/// The body is copied and the buffer it arrived in is released on the way out.
/// The arena copy is the one that has to outlive this call, and an arena frees
/// its most recent allocation, so the buffer cannot be the arena's own and then
/// released. For the two small bodies (`fetchAsset` is the exception) that copy
/// is a few kilobytes; the asset goes through `fetchAsset` instead, which keeps
/// the buffer it arrived in rather than paying for a second copy of a binary.
fn fetchBody(
    client: *std.http.Client,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    url: []const u8,
    bearer: ?[]const u8,
    max_size: usize,
    status_out: *std.http.Status,
) ![]const u8 {
    var capped: Capped = undefined;
    try capped.start(gpa, max_size);
    defer capped.body.deinit();
    try fetchInto(client, &capped, url, bearer, status_out);
    return try arena.dupe(u8, capped.body.written());
}

/// A body the caller owns and releases, for a body too large to copy.
///
/// The asset is the whole released binary, up to `max_asset_bytes` of it, and
/// `fetchBody` copies every byte of that into the arena before the buffer it
/// arrived in is freed: two copies of a megabyte-scale binary resident at once,
/// and a second pass over the bytes for nothing. This hands the buffer over
/// instead, so the fetch writes each byte into the allocation the caller frees.
pub const Fetched = struct {
    bytes: []u8,
    gpa: std.mem.Allocator,

    pub fn deinit(self: *Fetched) void {
        if (self.bytes.len != 0) self.gpa.free(self.bytes);
        self.* = undefined;
    }
};

fn fetchAsset(
    client: *std.http.Client,
    gpa: std.mem.Allocator,
    url: []const u8,
    bearer: ?[]const u8,
    max_size: usize,
    status_out: *std.http.Status,
) !Fetched {
    var capped: Capped = undefined;
    try capped.start(gpa, max_size);
    errdefer capped.body.deinit();
    try fetchInto(client, &capped, url, bearer, status_out);
    return .{ .bytes = try capped.body.toOwnedSlice(), .gpa = gpa };
}

/// The path is resolved by the caller so a failure to replace it can name the
/// file that would have changed; from here down it is already known to exist.
fn replaceExecutable(io: std.Io, exe: []const u8, asset: []const u8) !void {
    const base = std.fs.path.basename(exe);
    if (std.fs.path.dirname(exe)) |dir_path| {
        var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{});
        defer dir.close(io);
        try replaceVerified(io, dir, base, .replaced, asset);
    } else {
        try replaceVerified(io, std.Io.Dir.cwd(), base, .replaced, asset);
    }
}

/// A download that failed, reported the way the release lookup is: the code
/// itself when GitHub sent one, plus the hint for the statuses whose cause is
/// worth naming. The URL the response named is unbounded, so the caller passes
/// what it already holds: the asset name, or the sidecar described through it.
fn downloadFailure(
    io: std.Io,
    what: []const u8,
    status: std.http.Status,
    err: anyerror,
) u8 {
    if (err == error.HttpStatus)
        return fail(io, "GitHub returned HTTP {d} for {s}{s}; the binary was not replaced", .{
            @intFromEnum(status), what, statusHint(status),
        });
    return fail(io, "could not download {s} ({s}); the binary was not replaced", .{ what, @errorName(err) });
}

const usage_text =
    \\microagent update - replace this binary with the latest GitHub release
    \\
    \\usage:
    \\  microagent update [--check] [--repo owner/name]
    \\  microagent update --help
    \\  microagent update --version
    \\
    \\The release asset named microagent-<tag>-<target> is downloaded with its
    \\.sha256 sidecar, and the running binary is replaced only when the digest
    \\matches. A build that is already the latest release is left alone.
    \\
    \\flags:
    \\  -c, --check            report the latest release and install nothing
    \\      --repo OWNER/NAME  GitHub repository to track (default maci0/microagent);
    \\                         --repo=OWNER/NAME also works
    \\  -h, --help             this text ("update help" too)
    \\  -V, --version          version
    \\
    \\environment:
    \\  GITHUB_TOKEN           GitHub token, to get past the anonymous rate limit
    \\  MICROAGENT_CA_BUNDLE   PEM file to trust instead of the system store,
    \\                         else SSL_CERT_FILE (needed in images that ship
    \\                         no ca-certificates). An empty value is not one.
    \\
    \\With --check, stdout is the release page URL and the version comparison
    \\goes to stderr; nothing is downloaded. Exit 0 means the check ran;
    \\exit 1 means it did not, exit 2 is a usage error, and a usage error
    \\writes both its reason and this text to stderr so stdout stays clean.
    \\
;

pub fn printUsage(io: std.Io) void {
    // Text the caller may have piped at something that read a few lines and
    // left; a closed stream costs it nothing.
    net.writeOut(io, usage_text) catch {};
}

/// The run arena, not `gpa`: the header outlives every fetch and nothing here
/// owns the copy, so there is nothing to hand back.
fn githubBearer(arena: std.mem.Allocator, env: *std.process.Environ.Map) ?[]const u8 {
    // Trimmed the way the provider key file is: a token read from a file by a
    // wrapper arrives with the newline that file ended with, and a header
    // carrying one is refused as an invalid credential rather than as a
    // whitespace mistake.
    const tok = std.mem.trim(u8, env.get("GITHUB_TOKEN") orelse return null, net.env_surrounding);
    if (tok.len == 0) return null;
    return std.fmt.allocPrint(arena, "Bearer {s}", .{tok}) catch null;
}

/// The HTTP statuses whose cause is worth naming, and there are two causes
/// behind three codes: no release is published for the repo yet (404), and the
/// anonymous API rate limit, which GitHub answers as either 403 or 429.
fn statusHint(status: std.http.Status) []const u8 {
    return switch (status) {
        .not_found => " (no published release)",
        .forbidden, .too_many_requests => " (rate limited; set GITHUB_TOKEN)",
        else => "",
    };
}

/// What one release body decided: the parsed release when it had one, the
/// inputs `decide` was given, and the verdict those inputs produced.
const Decision = struct {
    rel: ?Release,
    in: Inputs,
    verdict: Verdict,
};

/// The first listed asset, paired with a sidecar that matches the bytes, so the
/// verdict turns on the tag and URL checks rather than stopping at the
/// checksum. A body that does not parse still has to produce an input, since
/// what the updater does with a malformed body is part of the same surface.
fn decideFromBody(arena: std.mem.Allocator, body: []const u8) !Decision {
    const rel = parseRelease(arena, body) catch null;
    const first: ?ListedAsset = if (rel) |r| (if (r.assets.len > 0) r.assets[0] else null) else null;
    const tag = if (rel) |r| r.tag else body;
    const name = if (first) |a| a.name else body;
    const url = if (first) |a| a.url else body;
    // The sidecar sits beside the asset in the same release, so its URL is the
    // asset's with the checksum suffix the updater already looks for.
    const sidecar_url = if (first != null) try std.fmt.allocPrint(arena, "{s}.sha256", .{url}) else null;

    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(body, &digest, .{});
    const sidecar = try std.fmt.allocPrint(arena, "{s}  {s}\n", .{ std.fmt.bytesToHex(digest, .lower), name });

    const in: Inputs = .{
        .running = "0.0.1",
        .tag = tag,
        .asset_url = url,
        .asset = body,
        .sidecar_url = sidecar_url,
        .sidecar = sidecar,
        .basename = name,
    };
    return .{ .rel = rel, .in = in, .verdict = decide(in) };
}

/// One sentence for the two ways `--repo` can arrive without a value, so the
/// flag at the end of the command line and `--repo=` say the same thing.
const repo_needs_value = "--repo needs an owner/name value";

/// What the subcommand's command line asked for. `--help` and `--version`
/// stop the parse where they appear, the way the agent's own parse does, and a
/// bad argument is a result of its own rather than an error the caller has to
/// tell apart from one.
const Parsed = union(enum) {
    run: struct { check_only: bool, repo: ?[]const u8 },
    help,
    version,
    /// A flag that needs a value it did not get, with the sentence to print.
    bad_flag: []const u8,
    /// An argument this subcommand does not take, which the message quotes.
    /// The slice is the caller's, so the message is formatted at the call site.
    unknown: []const u8,
};

fn parseArgs(args: []const []const u8) Parsed {
    var parsed: Parsed = .{ .run = .{ .check_only = false, .repo = null } };
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "help")) {
            return .help;
        } else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-V")) {
            return .version;
        } else if (std.mem.eql(u8, arg, "--check") or std.mem.eql(u8, arg, "-c")) {
            parsed.run.check_only = true;
        } else if (std.mem.eql(u8, arg, "--repo")) {
            i += 1;
            if (i >= args.len) return .{ .bad_flag = repo_needs_value };
            const v = args[i];
            if (v.len == 0) return .{ .bad_flag = repo_needs_value };
            parsed.run.repo = v;
        } else if (std.mem.startsWith(u8, arg, "--repo=")) {
            const v = arg["--repo=".len..];
            if (v.len == 0) return .{ .bad_flag = repo_needs_value };
            parsed.run.repo = v;
        } else {
            return .{ .unknown = arg };
        }
    }
    return parsed;
}

/// Subcommand entry, called by main with the arguments after `update`.
/// Returns the process exit code.
pub fn run(
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    env: *std.process.Environ.Map,
    args: []const []const u8,
) u8 {
    const parsed = parseArgs(args);
    switch (parsed) {
        .help => {
            printUsage(io);
            return 0;
        },
        .version => {
            net.writeOut(io, "microagent " ++ version ++ "\n") catch {};
            return 0;
        },
        .bad_flag => |msg| return updateUsageError(io, "{s}", .{msg}),
        .unknown => |arg| return updateUsageError(io, "unknown or incomplete argument '{s}'", .{arg}),
        .run => |opts| {
            return runChecked(io, gpa, arena, env, opts.check_only, opts.repo orelse default_repo);
        },
    }
}

/// The update itself, with a command line already read: fetch the release,
/// report where this build stands against it, and replace the binary only when
/// the asset it names earns it.
fn runChecked(
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    env: *std.process.Environ.Map,
    check_only: bool,
    repo: []const u8,
) u8 {
    // The longest `owner/name` `validRepo` accepts is 201 bytes, and the URL
    // around it is 46 more, so a buffer under that reported a legal repo as a
    // malformed one before a single byte was requested.
    var api_buf: [256]u8 = undefined;
    // A value the flag cannot carry is a usage error, so it prints the reason
    // and the usage text together like every other one. The message names the
    // flag and the rule rather than guessing at the mistake: a URL, a second
    // slash and an empty value are three different typos with one answer.
    const api = releaseApiUrl(&api_buf, repo) catch
        return updateUsageError(io, "--repo must be owner/name, got '{s}'", .{quoteRepo(arena, repo)});

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    // The agent run's CA-bundle escape hatch: an image that ships no
    // ca-certificates can still reach GitHub by naming a PEM file.
    const ca_path = net.caBundlePath(env);
    if (ca_path.len != 0) net.loadCaBundle(&client, io, gpa, ca_path, arena);

    const bearer = githubBearer(arena, env);
    var status: std.http.Status = .ok;
    const body = fetchBody(&client, gpa, arena, api, bearerFor(api, bearer), max_api_bytes, &status) catch |err| {
        if (err == error.HttpStatus) return fail(io, "GitHub returned HTTP {d} for {s}{s}", .{
            @intFromEnum(status), repo, statusHint(status),
        });
        return fail(io, "could not reach {s} ({s})", .{ api, @errorName(err) });
    };
    const rel = parseRelease(arena, body) catch |err|
        return fail(io, "the latest release from {s} could not be read ({s})", .{ api, @errorName(err) });
    const page = releasePageLine(rel.page) catch
        return fail(io, "refusing to install unverified binary", .{});

    var line_buf: [256]u8 = undefined;
    const order = compareVersions(version, rel.tag);
    const line = switch (order) {
        // `.eq` is exact equality only when the two really are the same
        // release. A tag that is not a triple compares as `.eq` too, and
        // `sameRelease` is what says whether it is the same build or a
        // pre-release the run goes on to install: calling that "is current"
        // printed one thing and did the other.
        .eq => if (sameRelease(version, rel.tag))
            formatCurrent(&line_buf, tool_name, version, rel.tag)
        else
            formatUncompared(&line_buf, tool_name, version, rel.tag),
        .gt => formatAhead(&line_buf, version, rel.tag),
        .lt => formatNewRelease(&line_buf, rel.tag, version),
    } catch |err| return fail(io, "could not format the version comparison ({s})", .{@errorName(err)});
    net.writeErr(io, line);
    net.writeErr(io, "\n");

    if (!fetchesAsset(check_only, version, rel.tag)) {
        if (check_only) {
            // The one line a script reads, so a stdout that refuses it is a
            // failed check rather than an empty answer and exit 0.
            net.writeOut(io, page) catch |err|
                return fail(io, "could not write the release page to stdout ({s})", .{@errorName(err)});
            net.writeOut(io, "\n") catch |err|
                return fail(io, "could not write the release page to stdout ({s})", .{@errorName(err)});
        }
        return 0;
    }

    var target_buf: [64]u8 = undefined;
    const target = thisAssetTriple(&target_buf);
    var name_buf: [192]u8 = undefined;
    const asset_name = writeAssetName(&name_buf, rel.tag, target) catch
        return fail(io, "release asset name does not fit", .{});
    var side_name_buf: [208]u8 = undefined;
    const side_name = writeSidecarName(&side_name_buf, asset_name) catch
        return fail(io, "release asset name does not fit", .{});

    const a_url = assetUrl(rel, asset_name) orelse
        return fail(io, "missing release asset {s}; the binary was not replaced", .{asset_name});
    const s_url = assetUrl(rel, side_name) orelse
        return fail(io, "missing checksum sidecar; the binary was not replaced", .{});
    if (!trustedGithubUrl(a_url) or !trustedGithubUrl(s_url)) {
        return fail(io, "refusing to install unverified binary", .{});
    }

    // The URL the response named is unbounded, and these lines print into a
    // fixed buffer, so the asset name is what identifies the download.
    var asset = fetchAsset(&client, gpa, a_url, bearer, max_asset_bytes, &status) catch |err|
        return downloadFailure(io, asset_name, status, err);
    defer asset.deinit();
    var side_what_buf: [320]u8 = undefined;
    const side_what = std.fmt.bufPrint(&side_what_buf, "the checksum sidecar for {s}", .{asset_name}) catch asset_name;
    const sidecar = fetchBody(&client, gpa, arena, s_url, bearerFor(s_url, bearer), max_sidecar_bytes, &status) catch |err|
        return downloadFailure(io, side_what, status, err);

    const decision = decide(.{
        .running = version,
        .tag = rel.tag,
        .asset_url = a_url,
        .asset = asset.bytes,
        .sidecar_url = s_url,
        .sidecar = sidecar,
        .basename = asset_name,
    });
    switch (decision) {
        .replaced => {},
        .current => return 0,
        .checksum_mismatch => return fail(io, "checksum mismatch; refusing to install unverified binary", .{}),
        .missing_sidecar => return fail(io, "missing checksum sidecar; the binary was not replaced", .{}),
        .missing_asset => return fail(io, "missing release asset; the binary was not replaced", .{}),
        .untrusted_url => return fail(io, "refusing to install unverified binary", .{}),
    }

    const exe = std.process.executablePathAlloc(io, arena) catch |err|
        return fail(io, "could not locate the running binary ({s})", .{@errorName(err)});
    replaceExecutable(io, exe, asset.bytes) catch |err|
        return fail(io, "could not replace {s} ({s}); the binary was not replaced", .{ exe, @errorName(err) });
    const installed = formatInstalled(&line_buf, rel.tag, exe) catch
        return fail(io, "could not format the install line", .{});
    net.writeOut(io, installed) catch |err|
        return fail(io, "{s} was installed, but the install line could not be written to stdout ({s})", .{ exe, @errorName(err) });
    net.writeOut(io, "\n") catch |err|
        return fail(io, "{s} was installed, but the install line could not be written to stdout ({s})", .{ exe, @errorName(err) });
    return 0;
}

/// A command line that does not parse. The message and the usage text both go
/// to stderr, so a failed invocation leaves stdout empty for whatever reads it.
fn updateUsageError(io: std.Io, comptime fmt: []const u8, args: anytype) u8 {
    var buf: [512]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "microagent update: " ++ fmt ++ "\n", args) catch
        "microagent update: bad arguments\n";
    net.writeErr(io, line);
    net.writeErr(io, usage_text);
    return 2;
}

// ── Tests ───────────────────────────────────────────────────────────────────

const abc_sha = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";
const asset_base = "microagent-v0.1.0-x86_64-linux-musl";

fn copyOf(io: std.Io, dir: std.Io.Dir) ![]u8 {
    return dir.readFileAlloc(io, "microagent", std.testing.allocator, .limited(64));
}

test "update: a v-prefixed tag equals the running version exactly" {
    try std.testing.expect(sameRelease("0.1.0", "v0.1.0"));
    try std.testing.expect(sameRelease("0.1.0", "0.1.0"));
    try std.testing.expect(!sameRelease("0.1.0", "v0.1.0.1"));
    try std.testing.expect(!sameRelease("0.1.1", "v0.1.10"));
    try std.testing.expect(!sameRelease("0.1.10", "v0.1.1"));
    try std.testing.expect(sameRelease("0.1.10", "v0.1.10"));
    // One leading `v` is the prefix, on either side; two is part of the name.
    try std.testing.expect(sameRelease("v0.1.0", "v0.1.0"));
    try std.testing.expect(sameRelease("v0.1.0", "0.1.0"));
    try std.testing.expect(!sameRelease("0.1.0", "vv0.1.0"));
}

test "update: asset name is microagent-tag-target" {
    var buf: [96]u8 = undefined;
    const name = try writeAssetName(&buf, "v0.1.0", "x86_64-linux-musl");
    try std.testing.expectEqualStrings("microagent-v0.1.0-x86_64-linux-musl", name);
    var side: [112]u8 = undefined;
    try std.testing.expectEqualStrings("microagent-v0.1.0-x86_64-linux-musl.sha256", try writeSidecarName(&side, name));
}

test "update: this target is the name the release matrix publishes" {
    const rows = .{
        .{ "x86_64", "linux", "musl", "x86_64-linux-musl" },
        .{ "aarch64", "linux", "musl", "aarch64-linux-musl" },
        .{ "x86_64", "linux", "gnu", "x86_64-linux-gnu" },
        .{ "aarch64", "macos", "none", "aarch64-macos" },
        .{ "x86_64", "macos", "none", "x86_64-macos" },
    };
    inline for (rows) |row| {
        var triple_buf: [64]u8 = undefined;
        const triple = targetTriple(&triple_buf, row[0], row[1], row[2]);
        try std.testing.expectEqualStrings(row[3], triple);
        var name_buf: [112]u8 = undefined;
        const asset = try writeAssetName(&name_buf, "v0.1.0", triple);
        try std.testing.expectEqualStrings("microagent-v0.1.0-" ++ row[3], asset);
    }
    // A glibc build asks for the static musl asset; macOS keeps its own name.
    var gnu_buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("x86_64-linux-musl", assetTriple(&gnu_buf, "x86_64", "linux", "gnu"));
    try std.testing.expectEqualStrings("aarch64-linux-musl", assetTriple(&gnu_buf, "aarch64", "linux", "gnu"));
    try std.testing.expectEqualStrings("x86_64-macos", assetTriple(&gnu_buf, "x86_64", "macos", "none"));

    var live_buf: [64]u8 = undefined;
    var via_buf: [64]u8 = undefined;
    const want = assetTriple(&via_buf, @tagName(builtin.cpu.arch), @tagName(builtin.os.tag), @tagName(builtin.abi));
    const got = thisAssetTriple(&live_buf);
    try std.testing.expectEqualStrings(want, got);
    try std.testing.expect(!std.mem.endsWith(u8, got, "-none"));
    if (builtin.os.tag == .linux) try std.testing.expect(std.mem.endsWith(u8, got, "-linux-musl"));
}

test "update: a repo that is not owner/name is refused before a release url exists" {
    var buf: [160]u8 = undefined;
    try std.testing.expectError(error.BadRepo, releaseApiUrl(&buf, "https://github.com/maci0/microagent"));
    try std.testing.expectError(error.BadRepo, releaseApiUrl(&buf, "maci0/microagent/extra"));
    try std.testing.expectError(error.BadRepo, releaseApiUrl(&buf, "maci0"));
    try std.testing.expectError(error.BadRepo, releaseApiUrl(&buf, "/microagent"));
    try std.testing.expect(!validRepo("maci0/microagent/"));
    const url = try releaseApiUrl(&buf, default_repo);
    try std.testing.expectEqualStrings("https://api.github.com/repos/maci0/microagent/releases/latest", url);
}

test "update: the longest repo validRepo accepts still has a url" {
    // The buffer `runChecked` hands the builder has to hold the url around the
    // longest repo the validator lets through, or a legal one is refused with
    // the message that a typo gets.
    var long: [201]u8 = undefined;
    @memset(long[0..100], 'a');
    @memset(long[100..201], 'b');
    long[100] = '/';
    const repo = long[0..];
    try std.testing.expect(validRepo(repo));
    var buf: [256]u8 = undefined;
    const url = try releaseApiUrl(&buf, repo);
    try std.testing.expect(std.mem.startsWith(u8, url, "https://api.github.com/repos/"));
    try std.testing.expect(std.mem.endsWith(u8, url, "/releases/latest"));
}

test "update: a release page that is not https on a GitHub host is not printed" {
    try std.testing.expectError(error.UntrustedUrl, releasePageLine("http://github.com/maci0/microagent/releases/tag/v0.1.0"));
    try std.testing.expectError(error.UntrustedUrl, releasePageLine("https://github.com.evil.com/maci0/microagent"));
    try std.testing.expectError(error.UntrustedUrl, releasePageLine("https://user@github.com/maci0/microagent"));
    try std.testing.expectError(error.UntrustedUrl, releasePageLine("https://example.com/microagent"));
    const page = "https://github.com/maci0/microagent/releases/tag/v0.1.0";
    try std.testing.expectEqualStrings(page, try releasePageLine(page));
    try std.testing.expect(trustedGithubUrl("https://api.github.com/repos/maci0/microagent/releases/latest"));
    try std.testing.expect(trustedGithubUrl("https://release-assets.githubusercontent.com/microagent"));
    try std.testing.expect(!trustedGithubUrl("https://objects.githubusercontent.com.evil.com/x"));
}

// The subcommand's command line is the one thing about `run` that can be read
// without a socket, and it decides whether the run fetches an asset at all.
test "update: the command line reads in either flag form, and help and version win" {
    const plain = parseArgs(&.{});
    try std.testing.expect(!plain.run.check_only);
    try std.testing.expect(plain.run.repo == null);

    const checked = parseArgs(&.{ "--check", "--repo=you/microagent" }).run;
    try std.testing.expect(checked.check_only);
    try std.testing.expectEqualStrings("you/microagent", checked.repo.?);

    const split = parseArgs(&.{ "-c", "--repo", "you/microagent" }).run;
    try std.testing.expect(split.check_only);
    try std.testing.expectEqualStrings("you/microagent", split.repo.?);

    switch (parseArgs(&.{ "--check", "--help" })) {
        .help => {},
        else => return error.TestUnexpectedResult,
    }
    switch (parseArgs(&.{"-V"})) {
        .version => {},
        else => return error.TestUnexpectedResult,
    }
    // A bare `help` is a word a script reaches for, and the flag is not.
    switch (parseArgs(&.{"help"})) {
        .help => {},
        else => return error.TestUnexpectedResult,
    }
    switch (parseArgs(&.{"--repo"})) {
        .bad_flag => |msg| try std.testing.expectEqualStrings("--repo needs an owner/name value", msg),
        else => return error.TestUnexpectedResult,
    }
    // An empty value is the same mistake as a missing one, in either spelling,
    // so both are caught here rather than sent on to be told a name is not a
    // name.
    switch (parseArgs(&.{"--repo="})) {
        .bad_flag => |msg| try std.testing.expectEqualStrings("--repo needs an owner/name value", msg),
        else => return error.TestUnexpectedResult,
    }
    switch (parseArgs(&.{ "--repo", "" })) {
        .bad_flag => |msg| try std.testing.expectEqualStrings("--repo needs an owner/name value", msg),
        else => return error.TestUnexpectedResult,
    }
    switch (parseArgs(&.{"--nope"})) {
        .unknown => |arg| try std.testing.expectEqualStrings("--nope", arg),
        else => return error.TestUnexpectedResult,
    }
}

test "update: --check and an equal version do not fetch an asset" {
    try std.testing.expect(!fetchesAsset(true, "0.1.0", "v0.2.0"));
    try std.testing.expect(!fetchesAsset(false, "0.1.0", "v0.1.0"));
    try std.testing.expect(fetchesAsset(false, "0.1.0", "v0.2.0"));
}

test "update: a build ahead of the latest release is not downgraded" {
    try std.testing.expectEqual(std.math.Order.lt, compareVersions("0.1.0", "v0.2.0"));
    try std.testing.expectEqual(std.math.Order.gt, compareVersions("0.2.0", "v0.1.1"));
    try std.testing.expectEqual(std.math.Order.gt, compareVersions("1.0.0", "v0.9.9"));
    try std.testing.expectEqual(std.math.Order.eq, compareVersions("0.1.0", "v0.1.0"));
    try std.testing.expectEqual(std.math.Order.eq, compareVersions("0.1", "v0.1.0"));
    // A tag that is not a dotted triple carries no order to claim, so it stays
    // on the caller's explicit request rather than being blocked.
    try std.testing.expectEqual(std.math.Order.eq, compareVersions("0.2.0-rc1", "v0.1.1"));

    try std.testing.expect(!fetchesAsset(false, "0.2.0", "v0.1.1"));
    try std.testing.expect(fetchesAsset(false, "0.2.0", "v0.2.0-rc1"));
    try std.testing.expect(fetchesAsset(false, "0.1.0", "v0.2.0"));
    try std.testing.expect(fetchesAsset(false, "0.1.0", "nightly"));

    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings(
        "0.2.0 is newer than the latest release (v0.1.1); nothing to install",
        try formatAhead(&buf, "0.2.0", "v0.1.1"),
    );
}

test "update: the GitHub token is trimmed, and an empty one is no token" {
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const arena = state.allocator();

    try std.testing.expect(githubBearer(arena, &env) == null);
    // A token a wrapper read from a file arrives with the newline it ended
    // with, and a header carrying one is refused as a bad credential.
    try env.put("GITHUB_TOKEN", "ghp_abc123\n");
    try std.testing.expectEqualStrings("Bearer ghp_abc123", githubBearer(arena, &env).?);
    try env.put("GITHUB_TOKEN", "  ");
    try std.testing.expect(githubBearer(arena, &env) == null);
}

// The token exists to lift the anonymous rate limit on the releases API. The
// asset and its sidecar are public files the asset host serves unauthenticated,
// so they are fetched without it: a token with repository scope has no business
// being presented to a host the check never needed to authenticate to. Both URLs
// pass the host allowlist either way, so the allowlist is not what this narrows.
test "update: only the releases API carries the GitHub token" {
    const bearer: ?[]const u8 = "Bearer ghp_abc123";
    const api = "https://api.github.com/repos/maci0/microagent/releases/latest";
    const asset = "https://github.com/maci0/microagent/releases/download/v0.2.0/" ++ asset_base;
    const cdn = "https://release-assets.githubusercontent.com/github-production-release-asset/1";

    try std.testing.expectEqualStrings("Bearer ghp_abc123", bearerFor(api, bearer).?);

    // A public release download, on GitHub's web host and on its asset host
    // alike: both are trusted enough to install from and neither authenticates.
    try std.testing.expect(bearerFor(asset, bearer) == null);
    try std.testing.expect(bearerFor(cdn, bearer) == null);
    try std.testing.expect(bearerFor(asset ++ ".sha256", bearer) == null);

    // A lookalike host is not the API, and an API reached by another name is not
    // the API: the prefix has to be the whole scheme, host and path root.
    try std.testing.expect(bearerFor("https://api.github.com.evil.com/repos/o/r", bearer) == null);
    try std.testing.expect(bearerFor("https://user@api.github.com/repos/o/r", bearer) == null);
    try std.testing.expect(bearerFor("https://evil.com/https://api.github.com/", bearer) == null);
    try std.testing.expect(bearerFor("https://api.github.com", bearer) == null);
    // The scheme and host are compared the way `trustedGithubUrl` compares them,
    // so a caller that spells the API in upper case still authenticates rather
    // than being silently sent unauthenticated.
    try std.testing.expectEqualStrings("Bearer ghp_abc123", bearerFor("HTTPS://API.GITHUB.COM/repos/o/r", bearer).?);

    // No token is no token on either side of the rule.
    try std.testing.expect(bearerFor(api, null) == null);
    try std.testing.expect(bearerFor(asset, null) == null);
}

test "update: checksum line is the published hex, two spaces, and the basename" {
    const sidecar = abc_sha ++ "  " ++ asset_base ++ "\n";
    try std.testing.expect(checksumMatches("abc", sidecar, asset_base));
    try std.testing.expect(!checksumMatches("abd", sidecar, asset_base));
    try std.testing.expect(!checksumMatches("abc", sidecar, "other"));
    const one_space = abc_sha ++ " " ++ asset_base;
    try std.testing.expect(!checksumMatches("abc", one_space, asset_base));

    // A sidecar written on a host that ends its lines in CRLF still names the
    // file, and so does one with no line ending at all.
    try std.testing.expect(checksumMatches("abc", abc_sha ++ "  " ++ asset_base ++ "\r\n", asset_base));
    try std.testing.expect(checksumMatches("abc", abc_sha ++ "  " ++ asset_base, asset_base));

    // The digest is read as hex, so a file written by a tool that uppercases it
    // is still the digest the bytes hash to.
    var upper: [abc_sha.len]u8 = undefined;
    for (abc_sha, 0..) |c, i| upper[i] = std.ascii.toUpper(c);
    try std.testing.expect(checksumMatches("abc", upper ++ "  " ++ asset_base ++ "\n", asset_base));

    // Anything after the basename is not the name this run asked for, and a
    // line too short to hold a digest and a name is not a line at all.
    try std.testing.expect(!checksumMatches("abc", abc_sha ++ "  " ++ asset_base ++ " extra\n", asset_base));
    try std.testing.expect(!checksumMatches("abc", abc_sha ++ asset_base ++ "\n", asset_base));
    try std.testing.expect(!checksumMatches("abc", "", asset_base));
    // A name that is a prefix of the one published is a different file.
    try std.testing.expect(!checksumMatches("abc", sidecar, asset_base[0 .. asset_base.len - 1]));
    try std.testing.expect(!checksumMatches("abc", sidecar, "x" ++ asset_base));
}

test "update: fixture release picks the named asset" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const body =
        \\{"tag_name":"v0.1.0","html_url":"https://github.com/maci0/microagent/releases/tag/v0.1.0","assets":[
        \\{"name":"microagent-v0.1.0-aarch64-macos","browser_download_url":"https://example.com/nope"},
        \\{"name":"microagent-v0.1.0-x86_64-linux-musl","browser_download_url":"https://github.com/maci0/microagent/releases/download/v0.1.0/microagent-v0.1.0-x86_64-linux-musl"},
        \\{"name":"microagent-v0.1.0-x86_64-linux-musl.sha256","browser_download_url":"https://github.com/maci0/microagent/releases/download/v0.1.0/microagent-v0.1.0-x86_64-linux-musl.sha256"}
        \\]}
    ;
    const rel = try parseRelease(arena_state.allocator(), body);
    try std.testing.expectEqualStrings("v0.1.0", rel.tag);
    var name_buf: [96]u8 = undefined;
    const name = try writeAssetName(&name_buf, rel.tag, "x86_64-linux-musl");
    const url = assetUrl(rel, name) orelse return error.TestUnexpectedResult;
    try std.testing.expect(trustedGithubUrl(url));
    try std.testing.expect(assetUrl(rel, "microagent-v0.1.0-no-such") == null);
    try std.testing.expect(!trustedGithubUrl(assetUrl(rel, "microagent-v0.1.0-aarch64-macos").?));
}

// The two ways a release body can fail to parse are told apart, because the
// operator sent to fix them are different: a body that is not the documented
// shape is GitHub's or a proxy's, and running out of memory is this machine's.
test "update: a malformed body and a failed allocation are not the same error" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();

    try std.testing.expectError(
        error.MalformedRelease,
        parseRelease(arena_state.allocator(), "not json at all"),
    );
    try std.testing.expectError(
        error.MalformedRelease,
        parseRelease(arena_state.allocator(), "[]"),
    );
    try std.testing.expectError(
        error.MalformedRelease,
        parseRelease(arena_state.allocator(), "{\"tag_name\":\"v1\",\"html_url\":\"x\",\"assets\":3}"),
    );

    var failing: std.testing.FailingAllocator = .init(alloc, .{ .fail_index = 0 });
    try std.testing.expectError(
        error.OutOfMemory,
        parseRelease(failing.allocator(), "{\"tag_name\":\"v1\"}"),
    );
}

test "update: a repo quoted back in an error keeps whole characters" {
    // A `--repo` is whatever the user typed, and the quote is cut at a fixed
    // length, so a cut that lands inside a multi-byte character would put a
    // replacement character in the middle of the flag they got wrong.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const gpa = arena_state.allocator();
    try std.testing.expectEqualStrings("maci0/microagent", quoteRepo(gpa, "maci0/microagent"));
    const long = "日本語/" ++ "x" ** 200;
    const quoted = quoteRepo(gpa, long);
    try std.testing.expect(quoted.len <= repo_in_error_bytes);
    try std.testing.expect(std.unicode.utf8ValidateSlice(quoted));
    try std.testing.expect(std.mem.startsWith(u8, long, quoted));
    // Three-byte characters throughout: the cut is on one of them, so the
    // quote holds whole ones and no more than the byte budget allows.
    try std.testing.expectEqualStrings("日" ** 26, quoteRepo(gpa, "日" ** 40));
    // A byte that is not text, and a control character, reach the line as
    // text rather than as mojibake or as a cursor the operator did not ask for.
    try std.testing.expectEqualStrings("bad\\x1b[31m\u{fffd}", quoteRepo(gpa, "bad\x1b[31m\xff"));
}

test "update: comparison and install lines use the release wording" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings(
        "microagent 0.1.0 is current (latest release: v0.1.0)",
        try formatCurrent(&buf, "microagent", "0.1.0", "v0.1.0"),
    );
    try std.testing.expectEqualStrings(
        "New release: v0.2.0 (running 0.1.0)",
        try formatNewRelease(&buf, "v0.2.0", "0.1.0"),
    );
    try std.testing.expectEqualStrings(
        "Installed v0.2.0 to /usr/local/bin/microagent",
        try formatInstalled(&buf, "v0.2.0", "/usr/local/bin/microagent"),
    );
}

test "update: checksum match replaces a copy; mismatch, missing sidecar, and a bad url do not" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const good_url = "https://github.com/maci0/microagent/releases/download/v0.2.0/" ++ asset_base;
    const good_side_url = good_url ++ ".sha256";
    const good_side = abc_sha ++ "  " ++ asset_base ++ "\n";
    const bad_side = "0000000000000000000000000000000000000000000000000000000000000000  " ++ asset_base ++ "\n";

    try tmp.dir.writeFile(io, .{ .sub_path = "microagent", .data = "old-binary" });

    // Every verdict but `replaced` refuses the write, so each case also checks
    // that the binary on disk is untouched.
    const refusals = [_]struct { want: Verdict, in: Inputs }{
        .{
            .want = .current,
            .in = .{ .running = "0.1.0", .tag = "v0.1.0", .asset_url = good_url, .asset = "abc", .sidecar_url = good_side_url, .sidecar = good_side, .basename = asset_base },
        },
        .{
            .want = .checksum_mismatch,
            .in = .{ .running = "0.1.0", .tag = "v0.2.0", .asset_url = good_url, .asset = "abc", .sidecar_url = good_side_url, .sidecar = bad_side, .basename = asset_base },
        },
        .{
            .want = .missing_sidecar,
            .in = .{ .running = "0.1.0", .tag = "v0.2.0", .asset_url = good_url, .asset = "abc", .sidecar_url = null, .basename = asset_base },
        },
        .{
            .want = .missing_asset,
            .in = .{ .running = "0.1.0", .tag = "v0.2.0", .asset_url = null, .asset = "abc", .sidecar_url = good_side_url, .sidecar = good_side, .basename = asset_base },
        },
        .{
            .want = .missing_asset,
            .in = .{ .running = "0.1.0", .tag = "v0.2.0", .asset_url = good_url, .asset = null, .sidecar_url = good_side_url, .sidecar = good_side, .basename = asset_base },
        },
        .{
            .want = .untrusted_url,
            .in = .{ .running = "0.1.0", .tag = "v0.2.0", .asset_url = "http://github.com/maci0/microagent/releases/download/v0.2.0/" ++ asset_base, .asset = "abc", .sidecar_url = good_side_url, .sidecar = good_side, .basename = asset_base },
        },
        .{
            .want = .untrusted_url,
            .in = .{ .running = "0.1.0", .tag = "v0.2.0", .asset_url = "https://example.com/microagent", .asset = "abc", .sidecar_url = good_side_url, .sidecar = good_side, .basename = asset_base },
        },
    };
    for (refusals) |c| {
        try std.testing.expectEqual(c.want, decide(c.in));
        try std.testing.expectError(error.Refused, replaceVerified(io, tmp.dir, "microagent", c.want, "abc"));
    }

    {
        const got = try copyOf(io, tmp.dir);
        defer alloc.free(got);
        try std.testing.expectEqualStrings("old-binary", got);
    }

    const replaced = decide(.{
        .running = "0.1.0",
        .tag = "v0.2.0",
        .asset_url = good_url,
        .asset = "abc",
        .sidecar_url = good_side_url,
        .sidecar = good_side,
        .basename = asset_base,
    });
    try std.testing.expectEqual(Verdict.replaced, replaced);
    try replaceVerified(io, tmp.dir, "microagent", replaced, "abc");
    const got = try copyOf(io, tmp.dir);
    defer alloc.free(got);
    try std.testing.expectEqualStrings("abc", got);
}

test "update: a body over the cap is refused while it arrives" {
    const gpa = std.testing.allocator;
    var capped: Capped = undefined;
    try capped.start(gpa, 64);
    defer capped.body.deinit();

    // Under the cap: the body comes through whole.
    try capped.writer.writeAll("short");
    try std.testing.expect(!capped.over);
    try std.testing.expectEqualStrings("short", capped.body.written());

    // Over it: the write fails on the chunk that crosses the line, so the cost
    // is the cap plus that chunk rather than the whole body.
    try std.testing.expectError(error.WriteFailed, capped.writer.writeAll("y" ** 1024));
    try std.testing.expect(capped.over);
    try std.testing.expect(capped.body.written().len <= 64 + 1024);
}

test "update: replaceVerified follows a symlinked destination" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "real_bin", .data = "old-content" });
    try tmp.dir.symLink(io, "real_bin", "microagent", .{});

    try replaceVerified(io, tmp.dir, "microagent", .replaced, "new-content");

    var link_buf: [256]u8 = undefined;
    const n = try tmp.dir.readLink(io, "microagent", &link_buf);
    try std.testing.expectEqualStrings("real_bin", link_buf[0..n]);

    const got = try tmp.dir.readFileAlloc(io, "real_bin", alloc, .limited(64));
    defer alloc.free(got);
    try std.testing.expectEqualStrings("new-content", got);
}

// The release body is attacker-shaped input too: it is whatever the API served
// for the repo, and every field in it becomes a tag, a name or a URL the
// updater acts on. `std.testing.fuzz` runs this corpus through the harness on
// every `zig build test`, and through the fuzzer's mutations when the test
// binary is built in fuzz mode. A real `releases/latest` body, the same body
// with one field of the wrong type or missing, an asset with a name but no
// URL, and the empty, truncated and non-object shapes.
const asset_base_fixture = "{\"name\":\"" ++ asset_base ++
    "\",\"browser_download_url\":\"https://github.com/maci0/microagent/releases/download/v0.1.0/" ++ asset_base ++ "\"}";

/// A release the updater may install: a published asset on a GitHub URL, and
/// one whose URLs are the lookalikes `trustedGithubUrl` has to refuse.
const published_release = "{\"tag_name\":\"v0.1.0\",\"html_url\":\"https://github.com/maci0/microagent/releases/tag/v0.1.0\",\"assets\":[" ++ asset_base_fixture ++ "]}";
const lookalike_release = "{\"tag_name\":\"v0.1.0\",\"html_url\":\"https://github.com/o/r\",\"assets\":[{\"name\":\"a\",\"browser_download_url\":\"https://github.com.evil.com/a\"},{\"name\":\"b\",\"browser_download_url\":\"https://evil.com/github.com/b\"},{\"name\":\"c\",\"browser_download_url\":\"http://github.com/c\"},{\"name\":\"d\",\"browser_download_url\":\"https://user@github.com/d\"},{\"name\":\"e\",\"browser_download_url\":\"https://raw.githubusercontent.com/e\"}]}";

const release_corpus = [_][]const u8{
    "",
    "null",
    "[]",
    "{}",
    "{",
    "{\"tag_name\":\"v0.1.0\"}",
    "{\"tag_name\":7,\"html_url\":\"https://github.com/o/r\",\"assets\":[]}",
    "{\"tag_name\":\"v0.1.0\",\"html_url\":null,\"assets\":[]}",
    "{\"tag_name\":\"v0.1.0\",\"html_url\":\"https://github.com/o/r\",\"assets\":{}}",
    "{\"tag_name\":\"v0.1.0\",\"html_url\":\"https://github.com/o/r\",\"assets\":[null,1,\"x\",[],{}]}",
    "{\"tag_name\":\"v0.1.0\",\"html_url\":\"https://github.com/o/r\",\"assets\":[{\"name\":\"a\"},{\"name\":1,\"browser_download_url\":\"https://github.com/o/r/a\"},{\"browser_download_url\":\"https://github.com/o/r/a\"}]}",
    published_release,
    "{\"tag_name\":\"v0.1.0\",\"html_url\":\"https://github.com/o/r\",\"assets\":[" ++ asset_base_fixture ++ "," ++ abc_sha ++ "]}",
    lookalike_release,
    "{\"tag_name\":\"\\u0000\\ud83d\\ude80\",\"html_url\":\"https://github.com/o/r\",\"assets\":[{\"name\":\"\\u0000\",\"browser_download_url\":\"https://github.com/o/r/\\u0000\"}]}",
};

test "update: fuzz: a release body only reaches a replacement it earns" {
    const gpa = std.testing.allocator;
    try std.testing.fuzz({}, fuzzRelease, .{ .corpus = &release_corpus });

    // The corpus has to reach the branch the harness asserts about, or the
    // assertion never fires: a published asset with a matching sidecar and two
    // trusted URLs is a replacement, and a lookalike host is not.
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectEqual(Verdict.replaced, (try decideFromBody(arena, published_release)).verdict);
    try std.testing.expectEqual(Verdict.untrusted_url, (try decideFromBody(arena, lookalike_release)).verdict);
}

fn fuzzRelease(_: void, smith: *std.testing.Smith) !void {
    const gpa = std.testing.allocator;
    var buf: [16 * 1024]u8 = undefined;
    const body = if (smith.in) |seed| seed else buf[0..smith.slice(&buf)];

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const d = try decideFromBody(arena, body);

    if (d.rel) |r| {
        for (r.assets) |asset| {
            try std.testing.expect(assetUrl(r, asset.name) != null);
        }
    }

    if (d.verdict == .replaced) {
        try std.testing.expect(trustedGithubUrl(d.in.asset_url.?));
        try std.testing.expect(trustedGithubUrl(d.in.sidecar_url.?));
        try std.testing.expect(checksumMatches(d.in.asset.?, d.in.sidecar.?, d.in.basename));
        try std.testing.expect(!sameRelease(d.in.running, d.in.tag));
    }

    // Whatever the tag said, the running build is the same release as itself
    // with or without the `v` on either side, and as nothing else.
    const tag = d.in.tag;
    const bare = if (std.mem.startsWith(u8, tag, "v")) tag[1..] else tag;
    try std.testing.expect(sameRelease(tag, tag));
    try std.testing.expect(sameRelease(bare, tag));
    try std.testing.expect(sameRelease(tag, bare));
    try std.testing.expect(!sameRelease(bare, try std.fmt.allocPrint(arena, "{s}x", .{bare})));
}

// The sidecar is the last untrusted input the updater reads and the only thing
// that decides whether the bytes it just downloaded are installed, so it
// deserves the same harness as the release body: a mirror that answers the
// sidecar URL with a body where the checksum was expected, a capture cut short
// by a proxy, a line with a second name on it, and a digest in a spelling this
// updater never wrote all arrive here as ordinary bytes.
// `std.testing.fuzz` runs this corpus on every `zig build test`, and through
// the fuzzer's mutations when the test binary is built in fuzz mode. The
// corpus is what the harness must be able to read: the line `sha256sum`
// writes, that line under CRLF and with a second line after it, the same hex
// in upper case, the binary-mode `*` separator, a `sha256:` prefix, a name
// that is not the asset's, a 64-byte line with no name, and the empty and
// truncated shapes. The published digest here is the one for `abc`, the asset
// the corpus-mode runs hash.
const sidecar_corpus = [_][]const u8{
    "",
    "\n",
    "\r\n",
    " ",
    abc_sha,
    abc_sha ++ " ",
    abc_sha ++ "  ",
    abc_sha ++ "  " ++ asset_base,
    abc_sha ++ "  " ++ asset_base ++ "\n",
    abc_sha ++ "  " ++ asset_base ++ "\r\n",
    abc_sha ++ "  " ++ asset_base ++ "\nsecond line\n",
    abc_sha ++ " " ++ asset_base,
    abc_sha ++ " *" ++ asset_base,
    "BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD  " ++ asset_base,
    "sha256:" ++ abc_sha ++ "  " ++ asset_base,
    abc_sha ++ "  other",
    abc_sha[0..63],
    abc_sha[0..63] ++ "  " ++ asset_base,
    abc_sha ++ "\t " ++ asset_base,
    "g" ** 64 ++ "  " ++ asset_base,
    "0" ** 64 ++ "  " ++ asset_base,
    "\x00" ** 64 ++ "  " ++ asset_base,
    "  " ++ asset_base,
    "\u{fffd} microagent\n",
};

test "update: fuzz: a sidecar matches only the bytes whose digest it publishes" {
    try std.testing.fuzz({}, fuzzSidecar, .{ .corpus = &sidecar_corpus });

    // The corpus has to reach both sides of the harness's assertions, or
    // neither fires: a line that spells out the digest of `abc` beside this
    // asset's name is a match, and one hex digit of it changed is not.
    try std.testing.expect(checksumMatches("abc", abc_sha ++ "  " ++ asset_base, asset_base));
    try std.testing.expect(!checksumMatches("abd", abc_sha ++ "  " ++ asset_base, asset_base));
}

fn fuzzSidecar(_: void, smith: *std.testing.Smith) !void {
    const gpa = std.testing.allocator;
    var scratch: [16 * 1024]u8 = undefined;
    // The sidecar is the whole fuzzed input, the asset the bytes it is checked
    // against, and the name the line has to end in is the one this build asks
    // the release for, so a match can only come from the digest agreeing.
    const sidecar: []const u8 = if (smith.in) |seed| seed else scratch[0..smith.slice(&scratch)];
    const asset: []const u8 = if (smith.in) |_|
        "abc"
    else
        scratch[sidecar.len..][0..smith.slice(scratch[sidecar.len..])];

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    if (checksumMatches(asset, sidecar, asset_base)) {
        // A match is the whole first line and nothing past it: the digest of
        // these bytes, the two-space separator, and the name the asset was
        // asked for. A match on a line that says anything else would install
        // bytes nobody published a digest for. The digest is folded to lower
        // case first, because that is the case the comparison is in.
        const end = std.mem.indexOfScalar(u8, sidecar, '\n') orelse sidecar.len;
        var line = sidecar[0..end];
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(asset, &digest, .{});
        const hex = std.fmt.bytesToHex(digest, .lower);
        for (line[0..64], hex) |got, want| {
            try std.testing.expectEqual(want, std.ascii.toLower(got));
        }
        try std.testing.expectEqualStrings(asset_base, line[66..]);
    }

    // One hex digit changed describes different bytes, so the same line must
    // stop being a match: without this the check could pass on anything and
    // every refusal below it would be untested.
    const tampered = try arena.dupe(u8, sidecar);
    if (tampered.len > 0 and std.ascii.isHex(tampered[0])) {
        tampered[0] = if (std.ascii.toLower(tampered[0]) == '0') '1' else '0';
        try std.testing.expect(!checksumMatches(asset, tampered, asset_base));
    }
}
