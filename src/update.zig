//! `microagent update`: compare this build with the latest GitHub release and,
//! when asked to install, replace the running executable only after its bytes
//! match the `.sha256` sidecar the release publishes.
//!
//! The decision (repo shape, exact version, asset name, checksum, trusted URL)
//! is pure; `runChecked` drives the one network path and names the running
//! executable, and tests never execute either.

const std = @import("std");
const builtin = @import("builtin");
const fuzzargv = @import("fuzzargv.zig");
const net = @import("net.zig");
const chat = @import("chat.zig");

const version = @import("build_options").version;

const default_repo = "maci0/microagent";
const tool_name = "microagent";

const exec_mode: std.Io.File.Permissions = @enumFromInt(@as(std.posix.mode_t, 0o755));

const max_api_bytes: usize = 10 * 1024 * 1024;
const max_sidecar_bytes: usize = 64 * 1024;
const max_asset_bytes: usize = 256 * 1024 * 1024;

// The install line carries the one value the run does not bound itself: the
// path the OS reports for the executable. The line is formatted after the
// binary has already been replaced, so a line that did not fit is a run that
// reports a failure for an install that happened, and the buffer is sized to
// hold one rather than to look tidy.
const install_line_bytes: usize = net.quoted_value_bytes + std.fs.max_path_bytes + 32;

/// A value this program does not spell, as the operator can be shown it: cut on
/// a codepoint boundary (a partial codepoint in a diagnostic reads as a
/// replacement character in the middle of the name), with every control
/// character, DEL and C1 control written as its `\xNN` escape, every invisible
/// and bidi character as its `\uXXXX` escape, and every byte that is not part of
/// a valid UTF-8 sequence written as U+FFFD.
///
/// Three kinds of value reach it. A `--repo` is whatever the user typed. A tag,
/// an asset name and a release page are the release body's own bytes: GitHub
/// publishes them, but this program treats that body as untrusted everywhere
/// else (the release and sidecar harnesses read it as exactly that), and a tag
/// carrying ESC, BEL or a C1 control puts an escape sequence on the operator's
/// terminal through every line that prints it as written. The tag decides
/// which version line is printed, and the asset name reaches three messages
/// about a download that failed. An asset url is the same: `trustedGithubUrl`
/// reads the host and refuses a userinfo and a separator, but everything after
/// the host is the release body's own bytes, and a path carrying an escape
/// sequence reached the retry notes as written before it was quoted here.
fn quoteUntrusted(arena: std.mem.Allocator, text: []const u8) []const u8 {
    return chat.safeText(arena, text, net.quoted_value_bytes);
}

const Verdict = enum {
    current,
    missing_asset,
    untrusted_url,
    missing_sidecar,
    checksum_mismatch,
    replaced,
};

const Inputs = struct {
    running: []const u8,
    tag: []const u8,
    asset_url: ?[]const u8 = null,
    asset: ?[]const u8 = null,
    sidecar_url: ?[]const u8 = null,
    sidecar: ?[]const u8 = null,
    basename: []const u8 = "",
};

const ListedAsset = struct {
    name: []const u8,
    url: []const u8,
};

const Release = struct {
    tag: []const u8,
    page: []const u8,
    assets: []const ListedAsset,
};

/// One leading `v` on either side, then exact equality. `v0.1.0` is `0.1.0`,
/// and so is a running build labelled the same way as the tag it matches.
fn sameRelease(running: []const u8, tag: []const u8) bool {
    return std.mem.eql(u8, bareVersion(running), bareVersion(tag));
}

fn bareVersion(release: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, release, "v")) release[1..] else release;
}

/// Where the running build sits against a published tag, ignoring one leading
/// `v` on either side. Components are `major.minor.patch`, a missing one is 0.
/// A tag carrying no order at all (a fork's tag, a branch name) is `.eq`, which
/// leaves the caller on exact equality rather than guessing an order.
fn compareVersions(running: []const u8, tag: []const u8) std.math.Order {
    const a = parseVersion(running) orelse return .eq;
    const b = parseVersion(tag) orelse return .eq;
    for (a.triple, b.triple) |an, bn| {
        if (an != bn) return if (an < bn) .lt else .gt;
    }
    // Same triple. A pre-release is a version of that triple, and it is the one
    // released before it, so it sorts below the release rather than equal to
    // it. Reading it as equal let the tag order past the `fetchesAsset` guard,
    // which is the guard that stops a newer binary being replaced by an older
    // one: a build on `0.3.0` installed `0.2.0-rc1` over itself, silently, and
    // the run it left behind was the older code.
    if (a.prerelease) return .lt;
    if (b.prerelease) return .gt;
    return .eq;
}

/// A `major.minor.patch` with a missing component read as 0, and whether what
/// followed the patch was a pre-release suffix (`-rc1`, `-beta.2`).
const Version = struct {
    triple: [3]u64,
    prerelease: bool,
};

/// The version a tag names, or null when it names no version at all: a
/// component that is not a plain number, or a fourth one. A pre-release
/// suffix is a version, so it parses; only what carries no order does not.
fn parseVersion(release: []const u8) ?Version {
    const v = bareVersion(release);
    // The suffix is taken off the whole tag before the components are split,
    // because a semver pre-release may carry dots of its own: `0.2.0-rc.1`
    // split on `.` alone is four components, and reading that as a fourth one
    // returned no version at all, so `compareVersions` answered `.eq` and a
    // build on `0.3.0` installed `0.2.0-rc.1` over itself. A `+` is build
    // metadata and orders before nothing, so it marks no pre-release.
    const cut = std.mem.indexOfAny(u8, v, "-+") orelse v.len;
    // The suffix is read as present or absent rather than compared, so no order
    // between two pre-releases of one triple is claimed here.
    var out: Version = .{ .triple = .{ 0, 0, 0 }, .prerelease = cut != v.len and v[cut] == '-' };
    var it = std.mem.splitScalar(u8, v[0..cut], '.');
    var n: usize = 0;
    while (it.next()) |c| {
        if (n == out.triple.len) return null;
        if (c.len == 0) return null;
        out.triple[n] = std.fmt.parseInt(u64, c, 10) catch return null;
        n += 1;
    }
    return out;
}

/// The release matrix publishes four triples: `x86_64-linux-musl`,
/// `aarch64-linux-musl`, `x86_64-macos` and `aarch64-macos`. Zig's abi tag for
/// those two macOS targets is `none`; appending it asks for an asset the release
/// does not publish.
fn targetTriple(buf: []u8, arch: []const u8, os_name: []const u8, abi: []const u8) error{NameTooLong}![]const u8 {
    if (std.mem.eql(u8, abi, "none")) {
        return std.fmt.bufPrint(buf, "{s}-{s}", .{ arch, os_name }) catch error.NameTooLong;
    }
    return std.fmt.bufPrint(buf, "{s}-{s}-{s}", .{ arch, os_name, abi }) catch error.NameTooLong;
}

/// The asset to ask for. Linux ships one static musl binary per arch, and a
/// static musl binary runs on a glibc host, so a `-gnu` build asks for the
/// musl asset instead of one the release does not publish. macOS has no abi
/// tag in its asset name.
fn assetTriple(buf: []u8, arch: []const u8, os_name: []const u8, abi: []const u8) error{NameTooLong}![]const u8 {
    if (std.mem.eql(u8, os_name, "linux")) return targetTriple(buf, arch, "linux", "musl");
    return targetTriple(buf, arch, os_name, abi);
}

fn thisAssetTriple(buf: []u8) error{NameTooLong}![]const u8 {
    return assetTriple(buf, @tagName(builtin.cpu.arch), @tagName(builtin.os.tag), @tagName(builtin.abi));
}

fn writeAssetName(buf: []u8, tag: []const u8, target: []const u8) error{NameTooLong}![]const u8 {
    return std.fmt.bufPrint(buf, "microagent-{s}-{s}", .{ tag, target }) catch return error.NameTooLong;
}

fn writeSidecarName(buf: []u8, asset_name: []const u8) error{NameTooLong}![]const u8 {
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
fn validRepo(text: []const u8) bool {
    if (std.mem.indexOf(u8, text, "://") != null) return false;
    const slash = std.mem.findScalar(u8, text, '/') orelse return false;
    const owner = text[0..slash];
    const name = text[slash + 1 ..];
    if (std.mem.findScalar(u8, name, '/') != null) return false;
    return repoPartOk(owner) and repoPartOk(name);
}

/// The release API URL, spelled twice: once with the repo in it, and once with
/// it left empty so the fuzz harness can measure the fixed part against its
/// buffer instead of repeating the prefix and suffix.
const release_api_url_fmt = "https://api.github.com/repos/{s}/releases/latest";
const release_api_url_fixed = "https://api.github.com/repos//releases/latest";

/// The release API URL. A repo that is not `owner/name` fails here, before
/// any bytes are requested.
fn releaseApiUrl(buf: []u8, repo: []const u8) error{ BadRepo, NameTooLong }![]const u8 {
    if (!validRepo(repo)) return error.BadRepo;
    return std.fmt.bufPrint(buf, release_api_url_fmt, .{repo}) catch
        return error.NameTooLong;
}

/// The longest a DNS name may be, so the buffer that lowercases one cannot be
/// sized by a guess. Anything longer is not a host a url names.
const max_host_len: usize = 253;

fn hostTrusted(host: []const u8) bool {
    var lower: [max_host_len]u8 = undefined;
    if (host.len == 0 or host.len > lower.len) return false;
    const h = std.ascii.lowerString(&lower, host);
    if (std.mem.eql(u8, h, "github.com")) return true;
    if (std.mem.endsWith(u8, h, ".github.com")) return true;
    if (std.mem.endsWith(u8, h, ".githubusercontent.com")) return true;
    return false;
}

/// https, and the host is `github.com`, `*.github.com`, or `*.githubusercontent.com`.
/// Userinfo and lookalikes such as `github.com.evil.com` are refused.
fn trustedGithubUrl(url: []const u8) bool {
    const prefix = "https://";
    if (!std.ascii.startsWithIgnoreCase(url, prefix)) return false;
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
fn bearerFor(url: []const u8, bearer: ?[]const u8) ?[]const u8 {
    const api = "https://api.github.com/";
    if (bearer == null) return null;
    if (!std.ascii.startsWithIgnoreCase(url, api)) return null;
    return bearer;
}

/// Stdout of `--check` is this URL, or nothing when the page is not a GitHub
/// https URL.
fn releasePageLine(url: []const u8) error{UntrustedUrl}![]const u8 {
    if (!trustedGithubUrl(url)) return error.UntrustedUrl;
    return url;
}

/// `--check` never downloads an asset. An equal version never does either,
/// and neither does a tag that orders as older than the running build:
/// installing it would replace a newer binary with an older one. A pre-release
/// is older than the release it precedes, so it is refused on both counts. A
/// tag that names no version at all (a fork's tag, a branch name) orders as
/// equal, so it is installed like any other release this build is not already.
fn fetchesAsset(check_only: bool, running: []const u8, tag: []const u8) bool {
    if (check_only) return false;
    if (compareVersions(running, tag) == .gt) return false;
    return !sameRelease(running, tag);
}

/// Sidecar line as `sha256sum` writes it: `<hex>  <basename>`.
fn checksumMatches(asset: []const u8, sidecar: []const u8, basename: []const u8) bool {
    const line_end = std.mem.findScalar(u8, sidecar, '\n') orelse sidecar.len;
    var line = sidecar[0..line_end];
    if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
    const hex_len = std.crypto.hash.sha2.Sha256.digest_length * 2;
    // Two spaces separate the digest from the name, so the name starts two
    // past the digest's two hex digits per byte.
    const name_at = hex_len + 2;
    if (line.len < name_at) return false;
    const hex = line[0..hex_len];
    if (!std.mem.eql(u8, line[hex_len..name_at], "  ")) return false;
    if (!std.mem.eql(u8, line[name_at..], basename)) return false;
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(asset, &digest, .{});
    const got = std.fmt.bytesToHex(digest, .lower);
    // A byte that is not a hex digit cannot fold onto one of `got`'s, so the
    // comparison is the whole of the check.
    return std.ascii.eqlIgnoreCase(hex, &got);
}

/// The one decision, from the release lookup's inputs to the verdict every
/// message in the run is keyed on. The checks come in the order a caller
/// reports them: an equal release is `current` whatever else is missing, then
/// the asset URL, then the sidecar URL, then the bytes, then the digest. So
/// `.current` says nothing about whether an asset was published, and a
/// release with no asset and no sidecar is `missing_asset` rather than
/// `missing_sidecar`.
fn decide(in: Inputs) Verdict {
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
fn replaceVerified(
    io: std.Io,
    dir: std.Io.Dir,
    dest_name: []const u8,
    decision: Verdict,
    asset: []const u8,
) !void {
    if (decision != .replaced) return error.Refused;
    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    var cur_buf: [2 * std.fs.max_path_bytes]u8 = undefined;
    var next_buf: [2 * std.fs.max_path_bytes]u8 = undefined;
    const target = try net.resolveSymlinkTarget(io, dir, dest_name, &link_buf, &cur_buf, &next_buf);

    var af = try dir.createFileAtomic(io, target, .{ .replace = true, .make_path = true, .permissions = exec_mode });
    defer af.deinit(io);
    try af.file.writeStreamingAll(io, asset);
    try af.replace(io);
}

fn formatCurrent(buf: []u8, tool: []const u8, running: []const u8, tag: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "{s} {s} is current (latest release: {s})", .{ tool, running, tag });
}

/// A tag that is not a plain triple, so no order can be claimed for it. It is
/// installed all the same, because `sameRelease` did not match and the caller
/// cannot prove the running build is newer; the line only says that the
/// comparison was not made, which "is current" would not.
fn formatUncompared(buf: []u8, tool: []const u8, running: []const u8, tag: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "{s} {s} is not the latest release ({s}), which is not a version triple to compare against", .{ tool, running, tag });
}

fn formatNewRelease(buf: []u8, tag: []const u8, running: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "New release: {s} (running {s})", .{ tag, running });
}

fn formatAhead(buf: []u8, running: []const u8, tag: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "{s} is newer than the latest release ({s}); nothing to install", .{ running, tag });
}

fn formatInstalled(buf: []u8, tag: []const u8, path: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "Installed {s} to {s}", .{ tag, path });
}

fn parseRelease(arena: std.mem.Allocator, body: []const u8) !Release {
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
    const tag = stringMember(obj, "tag_name") orelse return error.MalformedRelease;
    const page = stringMember(obj, "html_url") orelse return error.MalformedRelease;
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
        const name = stringMember(asset_obj, "name") orelse continue;
        const url = stringMember(asset_obj, "browser_download_url") orelse continue;
        try list.append(arena, .{ .name = name, .url = url });
    }
    return .{
        .tag = tag,
        .page = page,
        .assets = try list.toOwnedSlice(arena),
    };
}

/// A member of a decoded object, or null when it is absent or is not a string.
/// A member of any other type is a payload GitHub did not write, and every
/// caller treats one exactly as it treats a member that is not there.
fn stringMember(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .string => |s| s,
        else => null,
    };
}

fn assetUrl(rel: Release, name: []const u8) ?[]const u8 {
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

    /// Empties the buffer and clears the cap flag, so a fetch that is tried
    /// again writes into a body that is empty rather than one that still holds
    /// the bytes the failed attempt read: two attempts' bodies concatenated are
    /// a body no release ever published, and the checksum that gates the
    /// install is computed over exactly those bytes.
    fn reset(self: *Capped) void {
        self.body.writer.end = 0;
        self.over = false;
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
        // `splat` is how many times the pattern is written and it may be zero,
        // so a zero writes nothing at all rather than one copy of the pattern
        // the caller asked for no copies of.
        if (data.len != 0 and splat != 0) {
            const part = data[data.len - 1];
            var one = [_][]const u8{part};
            try self.body.writer.writeSplatAll(&one, splat);
            total +|= part.len *| splat;
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

// A drain is handed the pattern and the number of times to write it, and that
// number may be zero. Writing one copy anyway puts a byte in a release body
// that the caller never asked for, and the sidecar is a sha256 over exactly
// the bytes that were downloaded, so a body the drain padded is one whose
// checksum cannot match.
test "a zero splat writes no copy of the pattern" {
    const gpa = std.testing.allocator;
    var c: Capped = undefined;
    try c.start(gpa, 1024);
    defer c.body.deinit();

    try c.writer.splatBytesAll("xy", 0);
    try c.writer.writeAll("done");
    try std.testing.expectEqualStrings("done", c.body.written());

    // One repetition is still one copy, so the zero is honoured rather than
    // every splat being refused.
    try c.writer.splatBytesAll("ab", 2);
    try std.testing.expectEqualStrings("doneabab", c.body.written());
}

fn fail(io: std.Io, comptime fmt: []const u8, args: anytype) u8 {
    var buf: [512]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "microagent update: " ++ fmt ++ "\n", args) catch
        "microagent update: failed\n";
    net.writeErr(io, line);
    return 1;
}

/// One GET into `capped`, whose `limit` is the cap the body is refused past,
/// with the headers and the two status cases every caller wants the same answer
/// to. `client` is shared across the three fetches a run makes
/// so the CA store is loaded once. On an HTTP error `status_out` carries the
/// code, which is the difference between "no release yet" and "rate limit".
///
/// A connection that failed before the response started, and a status the
/// provider is using to say it is busy rather than that the request was wrong,
/// are retried: an update is a GET, so a second request is free of every effect
/// the first one had beyond bytes nobody acted on. What is not retried is a
/// status that names the request as the problem, a body past the cap, and an
/// allocation that failed, since none of them is a transient condition.
fn fetchInto(
    io: std.Io,
    arena: std.mem.Allocator,
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

    var attempt: u32 = 1;
    while (true) : (attempt += 1) {
        const result = client.fetch(.{
            .location = .{ .url = url },
            .headers = .{ .user_agent = .{ .override = "microagent/" ++ version } },
            .privileged_headers = priv_headers,
            .response_writer = &capped.writer,
        }) catch |err| {
            if (capped.over) return error.PayloadTooLarge;
            if (!net.transientTransportError(err) or attempt >= max_fetch_attempts) return err;
            if (!waitBeforeFetchRetry(io, arena, url, attempt, err)) return err;
            capped.reset();
            continue;
        };
        status_out.* = result.status;
        if (@intFromEnum(result.status) < 400) return;
        if (!net.retryableStatus(result.status) or attempt >= max_fetch_attempts) return error.HttpStatus;
        if (!waitBeforeFetchRetry(io, arena, url, attempt, error.HttpStatus)) return error.HttpStatus;
        capped.reset();
    }
}

/// Attempts one fetch makes before the error is the caller's. Three, with the
/// schedule below, is the same budget the agent's own request loop spends.
const max_fetch_attempts: u32 = 3;
/// The ceiling on the wait between attempts: 30 s, half the run's own cap. A
/// provider that is briefly busy is the case this covers, and a person waiting
/// on `microagent update` has less patience for it than a run already in
/// progress. The base and the doubling count behind it are the shared ones in
/// `net`, with the agent run, so the two schedules can only differ where they
/// are meant to.
const fetch_retry_max_ms: u64 = 30_000;

/// Says the retry is coming and waits for it. False means the wait could not be
/// taken, and the caller must surface its error rather than send the next
/// request at once: a wait that did not happen is not a backoff.
///
/// The wait is the shared schedule, and there is no `Retry-After` on it: this
/// fetches through `Client.fetch`, which hands back the status and nothing of
/// the head, so the header is not reachable from here. Reading it means moving
/// this loop onto `Client.request`, which is a change to the fetch and the
/// capped writer under it, not a change to this wait. `net.retryAfterMs` is
/// the reader to use when that happens, so the arithmetic is not written a
/// second time then.
fn waitBeforeFetchRetry(io: std.Io, arena: std.mem.Allocator, url: []const u8, attempt: u32, err: anyerror) bool {
    const wait = net.retryBackoffMs(attempt, fetch_retry_max_ms);
    net.writeErr(io, retryLine(arena, url, err, wait, attempt));
    io.sleep(.{ .nanoseconds = wait *| std.time.ns_per_ms }, .awake) catch |sleep_err| {
        net.writeErr(io, waitLine(arena, url, wait, sleep_err));
        return false;
    };
    return true;
}

/// The line a fetch that is about to be tried again prints, as the bytes
/// themselves rather than through `net.note`, so the escaping is something a
/// test can read rather than something only a terminal can see.
///
/// The url is quoted because every url but the API one is a field of the
/// release body: `trustedGithubUrl` has read the scheme and the host by the time
/// a fetch retries, and everything after the host is bytes this program has not
/// looked at. A path carrying ESC or a byte that is not text puts an escape
/// sequence or a replacement glyph on the operator's screen otherwise. The
/// fetch itself wants the url as written, so the line quotes rather than the
/// request changing.
fn retryLine(arena: std.mem.Allocator, url: []const u8, err: anyerror, wait: u64, attempt: u32) []const u8 {
    return std.fmt.allocPrint(arena, "microagent update: {s} failed ({s}), retrying in {d}ms (attempt {d}/{d})\n", .{
        quoteUntrusted(arena, url), @errorName(err), wait, attempt + 1, max_fetch_attempts,
    }) catch "microagent update: a fetch failed and is being retried\n";
}

/// The same line for a wait that could not be taken, which is the half of the
/// retry that has to be said when the retry itself does not happen.
fn waitLine(arena: std.mem.Allocator, url: []const u8, wait: u64, err: anyerror) []const u8 {
    return std.fmt.allocPrint(arena, "microagent update: the {d}ms wait before that attempt to {s} could not be taken ({s}); the update is abandoned rather than retried at once\n", .{
        wait, quoteUntrusted(arena, url), @errorName(err),
    }) catch "microagent update: the wait before the next attempt could not be taken; the update is abandoned\n";
}

/// One GET, body capped at `max_size` while it streams, copied into `arena`.
/// The body is copied and the buffer it arrived in is released on the way out.
/// The arena copy is the one that has to outlive this call, and an arena frees
/// its most recent allocation, so the buffer cannot be the arena's own and then
/// released. For the two small bodies (the release lookup and the sidecar) that
/// copy is a few kilobytes; the asset goes through `fetchAsset` instead, which keeps
/// the buffer it arrived in rather than paying for a second copy of a binary.
fn fetchBody(
    io: std.Io,
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
    try fetchInto(io, arena, client, &capped, url, bearer, status_out);
    return try arena.dupe(u8, capped.body.written());
}

/// A body the caller owns and releases, for a body too large to copy.
///
/// The asset is the whole released binary, up to `max_asset_bytes` of it, and
/// `fetchBody` copies every byte of that into the arena before the buffer it
/// arrived in is freed: two copies of a megabyte-scale binary resident at once,
/// and a second pass over the bytes for nothing. This hands the buffer over
/// instead, so the fetch writes each byte into the allocation the caller frees.
const Fetched = struct {
    bytes: []u8,
    gpa: std.mem.Allocator,

    pub fn deinit(self: *Fetched) void {
        if (self.bytes.len != 0) self.gpa.free(self.bytes);
        self.* = undefined;
    }
};

/// `fetchBody` without the second copy: the body lands in an allocation the
/// caller owns, so a release-sized asset is resident once rather than twice.
/// `max_size` is the cap `fetchInto` refuses to exceed, and the status is
/// reported back the same way so the caller reads one response either way.
fn fetchAsset(
    io: std.Io,
    arena: std.mem.Allocator,
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
    try fetchInto(io, arena, client, &capped, url, bearer, status_out);
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
    \\      --repo owner/name  GitHub repository to track (default
++ " " ++ default_repo ++ ");\n" ++
    \\                         --repo=owner/name also works
    \\  -h, --help             this text ("update help" too)
    \\  -V, --version          version
    \\
    \\environment:
    \\  GITHUB_TOKEN           GitHub token, to get past the anonymous rate
    \\                         limit. An empty value is not a token.
    \\  MICROAGENT_CA_BUNDLE   PEM file to trust instead of the system store,
    \\                         else SSL_CERT_FILE (needed in images that ship
    \\                         no ca-certificates). An empty value is not one.
    \\
    \\With --check, stdout is the release page URL and the version comparison
    \\goes to stderr; nothing is downloaded. Without --check, stdout is the one
    \\line naming the version installed and the path it was installed to, and
    \\nothing at all when this build is already the latest release, so a script
    \\reads the outcome from the exit status and the stderr notes either way.
    \\Exit 0 means the check ran or the binary was replaced; exit 1 means it
    \\did not, exit 2 is a usage error, and a usage error writes both its
    \\reason and this text to stderr so stdout stays clean.
    \\
;

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
    /// The tag as a line may quote it: the value the run's diagnostics name,
    /// rather than the one the decision reads.
    shown_tag: []const u8,
    /// The asset name the same way, since the tag is inside it.
    shown_asset: []const u8,
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
    return .{
        .rel = rel,
        .in = in,
        .verdict = decide(in),
        .shown_tag = quoteUntrusted(arena, tag),
        .shown_asset = quoteUntrusted(arena, name),
    };
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
        } else if (std.mem.eql(u8, arg, "--")) {
            // A bare `--` ends the flags, the way the agent's own command line
            // reads it. This subcommand takes no positional, so a trailing one
            // is nothing to say, and a word after it is the argument it does
            // not have, which is the answer it already gives to any other word.
            if (i + 1 >= args.len) break;
            return .{ .unknown = args[i + 1] };
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
            // Text the caller may have piped at something that read a few lines
            // and left; a closed stream costs it nothing.
            net.writeOut(io, usage_text) catch {};
            return 0;
        },
        .version => {
            net.writeOut(io, "microagent " ++ version ++ "\n") catch {};
            return 0;
        },
        .bad_flag => |msg| return updateUsageError(io, "{s}", .{msg}),
        .unknown => |arg| return updateUsageError(io, "unknown or incomplete argument '{s}'", .{quoteUntrusted(arena, arg)}),
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
    // around it is 45 more, so a buffer under that reported a legal repo as a
    // malformed one before a single byte was requested.
    var api_buf: [256]u8 = undefined;
    // A value the flag cannot carry is a usage error, so it prints the reason
    // and the usage text together like every other one. The message names the
    // flag and the rule rather than guessing at the mistake: a URL, a second
    // slash and an empty value are three different typos with one answer.
    const api = releaseApiUrl(&api_buf, repo) catch
        return updateUsageError(io, "--repo must be owner/name, got '{s}'", .{quoteUntrusted(arena, repo)});

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    // The agent run's CA-bundle escape hatch: an image that ships no
    // ca-certificates can still reach GitHub by naming a PEM file.
    const ca_path = net.caBundlePath(env);
    net.loadCaBundle(&client, io, gpa, ca_path, arena);

    const bearer = githubBearer(arena, env);
    var status: std.http.Status = .ok;
    const body = fetchBody(io, &client, gpa, arena, api, bearerFor(api, bearer), max_api_bytes, &status) catch |err| {
        if (err == error.HttpStatus) return fail(io, "GitHub returned HTTP {d} for {s}{s}", .{
            @intFromEnum(status), quoteUntrusted(arena, repo), statusHint(status),
        });
        return fail(io, "could not reach {s} ({s})", .{ api, @errorName(err) });
    };
    const rel = parseRelease(arena, body) catch |err|
        return fail(io, "the latest release from {s} could not be read ({s})", .{ api, @errorName(err) });
    const page = releasePageLine(rel.page) catch
        return fail(io, "refusing to install unverified binary", .{});
    // The tag is the release body's own bytes, and every line below quotes one,
    // so what is printed is the quoted spelling. The comparison and the lookup
    // below read `rel.tag` itself: what a tag says is what decides, and what a
    // line says is only what a reader is shown.
    const tag = quoteUntrusted(arena, rel.tag);

    var line_buf: [256]u8 = undefined;
    const order = compareVersions(version, rel.tag);
    const line = switch (order) {
        // `.eq` is exact equality only when the two really are the same
        // release. A tag that is not a triple compares as `.eq` too, and
        // `sameRelease` is what says whether it is the same build or a
        // pre-release the run goes on to install: calling that "is current"
        // printed one thing and did the other.
        .eq => if (sameRelease(version, rel.tag))
            formatCurrent(&line_buf, tool_name, version, tag)
        else
            formatUncompared(&line_buf, tool_name, version, tag),
        .gt => formatAhead(&line_buf, version, tag),
        .lt => formatNewRelease(&line_buf, tag, version),
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
    const target = thisAssetTriple(&target_buf) catch
        return fail(io, "release target name does not fit", .{});
    var name_buf: [192]u8 = undefined;
    const asset_name = writeAssetName(&name_buf, rel.tag, target) catch
        return fail(io, "release asset name does not fit", .{});
    var side_name_buf: [208]u8 = undefined;
    const side_name = writeSidecarName(&side_name_buf, asset_name) catch
        return fail(io, "release asset name does not fit", .{});
    // What the three messages below name the download with. The lookup, the
    // sidecar's basename and the verdict all read `asset_name` itself: what the
    // release published is the name to match against, not the one to print.
    const asset_name_text = quoteUntrusted(arena, asset_name);

    const a_url = assetUrl(rel, asset_name) orelse
        return fail(io, "missing release asset {s}; the binary was not replaced", .{asset_name_text});
    const s_url = assetUrl(rel, side_name) orelse
        return fail(io, "missing checksum sidecar; the binary was not replaced", .{});
    if (!trustedGithubUrl(a_url) or !trustedGithubUrl(s_url)) {
        return fail(io, "refusing to install unverified binary", .{});
    }

    // The URL the response named is unbounded, and these lines print into a
    // fixed buffer, so the asset name is what identifies the download. The name
    // is the tag inside it, so it is quoted for a reader the way the tag is.
    //
    // The sidecar is fetched first on purpose. It is a digest line of about a
    // hundred bytes and the asset is up to `max_asset_bytes`, and a release
    // that published the binary without publishing its checksum is exactly the
    // case `decide` refuses, so fetching the binary first spends the whole
    // download to find out the install was never going to happen.
    var side_what_buf: [320]u8 = undefined;
    const side_what = std.fmt.bufPrint(&side_what_buf, "the checksum sidecar for {s}", .{asset_name_text}) catch asset_name_text;
    const sidecar = fetchBody(io, &client, gpa, arena, s_url, bearerFor(s_url, bearer), max_sidecar_bytes, &status) catch |err|
        return downloadFailure(io, side_what, status, err);
    var asset = fetchAsset(io, arena, &client, gpa, a_url, bearerFor(a_url, bearer), max_asset_bytes, &status) catch |err|
        return downloadFailure(io, asset_name_text, status, err);
    defer asset.deinit();

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

    var install_buf: [install_line_bytes]u8 = undefined;
    const exe = std.process.executablePathAlloc(io, arena) catch |err|
        return fail(io, "could not locate the running binary ({s})", .{@errorName(err)});
    // The two notes below name the path, and a path is whatever the machine's
    // own bytes spell: an install directory a shell set with a non-ASCII name
    // reaches stderr as mojibake, and one carrying a control byte acts on the
    // terminal. The install line on stdout keeps the path as written, because
    // that is the line a script reads the path out of.
    const shown_exe = chat.safeTextAll(arena, exe);
    replaceExecutable(io, exe, asset.bytes) catch |err|
        return fail(io, "could not replace {s} ({s}); the binary was not replaced", .{ shown_exe, @errorName(err) });
    const installed = formatInstalled(&install_buf, tag, exe) catch
        return fail(io, "{s} was installed, but the install line did not fit", .{shown_exe});
    net.writeOut(io, installed) catch |err|
        return fail(io, "{s} was installed, but the install line could not be written to stdout ({s})", .{ shown_exe, @errorName(err) });
    net.writeOut(io, "\n") catch |err|
        return fail(io, "{s} was installed, but the install line could not be written to stdout ({s})", .{ shown_exe, @errorName(err) });
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

test "the usage text names the repository a run without --repo tracks" {
    // `--repo` is the one flag here with a default, and the default is a
    // repository name a user types into a URL bar. Written out in this text
    // and held in `default_repo`, it is two facts that can drift, and the
    // one that drifts is the one a user only finds out about when the update
    // they asked for comes from somewhere they did not name. The sentence is
    // built from the constant, so a fork the release moves to takes the help
    // with it.
    const said = "(default " ++ default_repo ++ ")";
    try std.testing.expect(std.mem.indexOf(u8, usage_text, said) != null);
    try std.testing.expect(std.mem.indexOf(u8, usage_text, "microagent update [--check] [--repo owner/name]") != null);
}

const abc_sha = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";
const asset_base = "microagent-v0.1.0-x86_64-linux-musl";

fn copyOf(io: std.Io, dir: std.Io.Dir) ![]u8 {
    return dir.readFileAlloc(io, "microagent", std.testing.allocator, .limited(64));
}

// A retried fetch is only correct if what it retries is a condition a second
// request can answer. A DNS failure, a refused or reset connection and a busy
// provider are; a 404 names a release or asset that is not published, a body
// past the cap is the same body however many times it is asked for, and an
// allocation that failed fails again. Retrying any of those spends the
// operator's time to arrive at the same answer.
test "update: only a transient failure or a busy provider is retried" {
    try std.testing.expect(net.transientTransportError(error.UnknownHostName));
    try std.testing.expect(net.transientTransportError(error.ConnectionRefused));
    try std.testing.expect(net.transientTransportError(error.ConnectionResetByPeer));
    try std.testing.expect(net.transientTransportError(error.TemporaryNameServerFailure));
    try std.testing.expect(net.transientTransportError(error.TlsInitializationFailed));

    try std.testing.expect(!net.transientTransportError(error.OutOfMemory));
    try std.testing.expect(!net.transientTransportError(error.PayloadTooLarge));
    try std.testing.expect(!net.transientTransportError(error.HttpStatus));
    try std.testing.expect(!net.transientTransportError(error.UntrustedUrl));
    try std.testing.expect(!net.transientTransportError(error.ChecksumMismatch));

    try std.testing.expect(net.retryableStatus(.internal_server_error));
    try std.testing.expect(net.retryableStatus(.service_unavailable));
    try std.testing.expect(net.retryableStatus(.too_many_requests));
    try std.testing.expect(net.retryableStatus(.request_timeout));
    // The other two the run's own set names: a 409 and a 425 are a provider
    // saying the request conflicts or arrived too early, and both are answered
    // by sending it again.
    try std.testing.expect(net.retryableStatus(.conflict));
    try std.testing.expect(net.retryableStatus(.too_early));
    // The 4xx the set does not name, either side of the ones it does: a
    // `>= 500` rule that started at 4xx would retry every 4xx, and one that
    // started at 501 would stop retrying a 500.
    try std.testing.expect(!net.retryableStatus(.bad_request));
    try std.testing.expect(!net.retryableStatus(.precondition_failed));
    try std.testing.expect(!net.retryableStatus(.locked));
    try std.testing.expect(!net.retryableStatus(.failed_dependency));
    try std.testing.expect(!net.retryableStatus(.upgrade_required));
    try std.testing.expect(!net.retryableStatus(.unavailable_for_legal_reasons));
    // Every status from 500 up is retried, including the ones with no name
    // here, so a gateway that answers 599 is answered again.
    try std.testing.expect(net.retryableStatus(.bad_gateway));
    try std.testing.expect(net.retryableStatus(.gateway_timeout));
    try std.testing.expect(net.retryableStatus(@enumFromInt(599)));
    try std.testing.expect(net.retryableStatus(@enumFromInt(500)));

    // A name that is not published is a 404 whichever way it is asked for.
    try std.testing.expect(!net.retryableStatus(.not_found));
    try std.testing.expect(!net.retryableStatus(.unauthorized));
    try std.testing.expect(!net.retryableStatus(.forbidden));
}

// The body a retry writes into still holds the bytes the failed attempt read.
// Concatenating the two is a body no release published, and the checksum that
// gates the install is computed over exactly those bytes, so the failure would
// read as a tampering refusal rather than as a retried fetch.
test "update: a retried fetch starts from an empty body" {
    var capped: Capped = undefined;
    try capped.start(std.testing.allocator, 1024);
    defer capped.body.deinit();
    try capped.writer.writeAll("first attempt");
    try std.testing.expectEqualStrings("first attempt", capped.body.written());
    try std.testing.expect(!capped.over);

    capped.reset();
    try std.testing.expectEqualStrings("", capped.body.written());
    try std.testing.expect(!capped.over);

    // The cap flag is cleared with it, so a body that stopped the first attempt
    // for being too long does not stop the second for the same reason.
    capped.over = true;
    capped.reset();
    try std.testing.expect(!capped.over);
}

// The schedule is 1s, 2s, 4s, capped, and it does not overflow on an attempt
// counter that has run away.
test "update: the fetch backoff doubles, caps, and never overflows" {
    try std.testing.expectEqual(@as(u64, 1000), net.retryBackoffMs(1, fetch_retry_max_ms));
    try std.testing.expectEqual(@as(u64, 2000), net.retryBackoffMs(2, fetch_retry_max_ms));
    try std.testing.expectEqual(@as(u64, 4000), net.retryBackoffMs(3, fetch_retry_max_ms));
    try std.testing.expectEqual(fetch_retry_max_ms, net.retryBackoffMs(30, fetch_retry_max_ms));
    try std.testing.expectEqual(fetch_retry_max_ms, net.retryBackoffMs(std.math.maxInt(u32), fetch_retry_max_ms));
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
        const triple = try targetTriple(&triple_buf, row[0], row[1], row[2]);
        try std.testing.expectEqualStrings(row[3], triple);
        var name_buf: [112]u8 = undefined;
        const asset = try writeAssetName(&name_buf, "v0.1.0", triple);
        try std.testing.expectEqualStrings("microagent-v0.1.0-" ++ row[3], asset);
    }
    // A glibc build asks for the static musl asset; macOS keeps its own name.
    var gnu_buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("x86_64-linux-musl", try assetTriple(&gnu_buf, "x86_64", "linux", "gnu"));
    try std.testing.expectEqualStrings("aarch64-linux-musl", try assetTriple(&gnu_buf, "aarch64", "linux", "gnu"));
    try std.testing.expectEqualStrings("x86_64-macos", try assetTriple(&gnu_buf, "x86_64", "macos", "none"));

    // The name the running binary asks for is pinned to the table above by the
    // target it builds for, not by asking the same function twice: a
    // comparison between two calls of the wrapper under test is true whatever
    // the wrapper returns.
    //
    // The name is compared to the whole string the release matrix publishes for
    // the host, not to a shape. `!endsWith(got, "-none")` is true for
    // `aarch64-macos` and for `aarch64-macos-macos` alike, so on the two macOS
    // runners it was a guard that passed whatever the function returned: a
    // stray abi, or a dropped arch, shipped an asset name no release publishes
    // and the update asked for nothing. The expected value is the row above,
    // chosen by the host's own os tag.
    var live_buf: [64]u8 = undefined;
    const got = try thisAssetTriple(&live_buf);
    const arch = @tagName(builtin.cpu.arch);
    const want_live = switch (builtin.os.tag) {
        .linux => arch ++ "-linux-musl",
        // Zig's abi tag for a macOS build is `none` (checked against every
        // published target's own `-Dtarget` triple), and the release names
        // macOS with no abi at all.
        .macos => arch ++ "-macos",
        else => arch ++ "-" ++ @tagName(builtin.os.tag),
    };
    try std.testing.expectEqualStrings(want_live, got);
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

// The allowlist is the one gate between a name this run built and a host the
// bytes come from, so each of its refusals is pinned here rather than left to
// the release page that happens to exercise it. The three ways a url names a
// host besides the host itself are a userinfo, a port and a case, and the two
// suffix rules differ over whether the bare domain counts.
test "update: only a github host is fetched from, however the url spells it" {
    // The scheme is compared case-insensitively, and a host is a DNS name
    // where case is not significant, so both spellings name the same host.
    try std.testing.expect(trustedGithubUrl("HTTPS://GITHUB.COM/maci0/microagent"));
    try std.testing.expect(trustedGithubUrl("https://Release-Assets.GitHubUserContent.com/x"));

    // A subdomain of a trusted domain is trusted; the bare second-level domain
    // is not, because `githubusercontent.com` itself serves nothing this run
    // should fetch from, and the rule is a suffix with the dot in it.
    try std.testing.expect(trustedGithubUrl("https://codeload.github.com/x"));
    try std.testing.expect(!trustedGithubUrl("https://githubusercontent.com/x"));
    try std.testing.expect(!trustedGithubUrl("https://evil.githubusercontent.com.evil.com/x"));
    try std.testing.expect(!trustedGithubUrl("https://notgithub.com/x"));
    try std.testing.expect(!trustedGithubUrl("https://github.co/x"));

    // A port is part of the host field and a non-empty one of digits leaves
    // the host it names; an empty or non-numeric one is a url no parser reads
    // the way this one would have to.
    try std.testing.expect(trustedGithubUrl("https://github.com:443/maci0/microagent"));
    try std.testing.expect(trustedGithubUrl("https://api.github.com:8443/x"));
    try std.testing.expect(!trustedGithubUrl("https://github.com:/x"));
    try std.testing.expect(!trustedGithubUrl("https://github.com:443abc/x"));
    try std.testing.expect(!trustedGithubUrl("https://github.com:443@evil.com/x"));

    // Userinfo is refused outright, and so is a host carrying the byte that
    // separates a path from a query, which is where a parser that disagreed
    // with this one would read the trusted name from.
    for ([_][]const u8{
        "https://user@github.com/x",
        "https://user:pass@github.com/x",
        "https://github.com\\@evil.com/x",
        "https://github.com x",
        "https://github.com\tx",
        "https://github.com\n/x",
        // A line ending past the host is the one a host comparison cannot see:
        // the host field still reads `github.com`, and the header the request
        // is built from carries whatever followed it.
        "https://github.com/x\r\nHost: evil.example",
        "https://github.com/x\nHost: evil.example",
    }) |url| {
        if (trustedGithubUrl(url)) {
            std.debug.print("trusted a url carrying userinfo or a separator: {s}\n", .{url});
            return error.TestUnexpectedResult;
        }
    }

    // A url with no scheme, an empty one, and one that is only the scheme.
    try std.testing.expect(!trustedGithubUrl(""));
    try std.testing.expect(!trustedGithubUrl("https://"));
    try std.testing.expect(!trustedGithubUrl("https:///maci0/microagent"));
    try std.testing.expect(!trustedGithubUrl("http://github.com/x"));
    try std.testing.expect(!trustedGithubUrl("//github.com/x"));
    try std.testing.expect(!trustedGithubUrl("github.com/x"));

    // A host past the DNS name's own 253-byte ceiling is refused rather than
    // compared out of bounds, and one exactly at it is still read.
    var long_host: [max_host_len + 1]u8 = undefined;
    const suffix = ".github.com";
    @memset(long_host[0 .. max_host_len - suffix.len], 'a');
    @memcpy(long_host[max_host_len - suffix.len .. max_host_len], suffix);
    var long_url: [max_host_len + 16]u8 = undefined;
    const at_max = try std.fmt.bufPrint(&long_url, "https://{s}/x", .{long_host[0..max_host_len]});
    try std.testing.expect(trustedGithubUrl(at_max));
    const over_max = try std.fmt.bufPrint(&long_url, "https://{s}/x", .{long_host[0 .. max_host_len + 1]});
    try std.testing.expect(!trustedGithubUrl(over_max));
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
    // A bare `--` is read the way the agent's own command line reads it. This
    // subcommand takes no positional, so a trailing one is nothing to say, and
    // a word after it is the argument that does not exist here.
    const ended = parseArgs(&.{ "--check", "--" }).run;
    try std.testing.expect(ended.check_only);
    try std.testing.expect(ended.repo == null);
    switch (parseArgs(&.{ "--", "extra" })) {
        .unknown => |arg| try std.testing.expectEqualStrings("extra", arg),
        else => return error.TestUnexpectedResult,
    }
}

// The `update` command line is untrusted in the same way the agent's own is: a
// wrapper script, a CI job and a human all spell it, and every one of them can
// put a value where a flag belongs. What makes it worth a harness of its own
// is the sink: whatever `--repo` ends up holding is formatted into the URL the
// updater requests, so a parser that composes a repo out of arguments, or that
// keeps one after refusing it, aims a request at a host nobody named.
// `std.testing.fuzz` runs this corpus on every `zig build test`, and through
// the fuzzer's mutations when the test binary is built in fuzz mode. The corpus
// is the shapes a caller reaches for: both spellings of a valued flag, a value
// joined with `=`, an empty value, a flag that ends the line, a value that
// looks like a flag, a second `--repo`, the words that stop the parse, and the
// repo shapes `validRepo` accepts and refuses.
const update_args_corpus = [_][]const u8{
    "",
    " ",
    "-",
    "--",
    "-h",
    "--help",
    "help",
    "-V",
    "--version",
    "-c",
    "--check",
    "--check --help",
    "-c -V",
    "--check --check",
    "--repo",
    "--repo=",
    "--repo you/microagent",
    "--repo=you/microagent",
    "-c --repo you/microagent",
    "--repo --check",
    "--repo -c",
    "--repo --help",
    "--repo https://evil.example/x",
    "--repo /etc/passwd",
    "--repo a/b/c",
    "--repo owner/",
    "--repo /name",
    "--repo ..",
    "--repo ../..",
    "--repo %2e%2e%2f",
    "--repo owner/na me",
    "--repo ow ner/name",
    "--repo owner/name?x=1",
    "--repo owner/name#frag",
    "--repo owner/name/../../etc",
    "--repo you/microagent --repo evil/repo",
    "--repo you/microagent extra",
    "extra --repo you/microagent",
    "--nope",
    "-x",
    "--repo=--check",
    "--repo=-h",
    "\u{0}\u{1}\u{7f}",
    "--repo \u{65e5}\u{8a00}/\u{65e5}\u{8a00}",
    "--repo \u{fffd}/x",
    "--repo \xff\xfe/x",
    "--repo a\u{0}b/c",
    "microagent-" ** 40 ++ "/x",
    "a" ** 200 ++ "/b",
    "owner/" ++ "n" ** 200,
};

test "update: fuzz: a fuzzed update command line aims at the repo it was given" {
    try std.testing.fuzz({}, fuzzUpdateArgs, .{ .corpus = &update_args_corpus });
}

fn fuzzUpdateArgs(_: void, smith: *std.testing.Smith) !void {
    var raw: [8 * 1024]u8 = undefined;
    const text = if (smith.in) |seed| seed else raw[0..smith.slice(&raw)];

    var argv: [64][]const u8 = undefined;
    const words = fuzzargv.argv(text, &argv);

    const parsed = parseArgs(words);
    const repo = switch (parsed) {
        .run => |r| r.repo orelse return,
        // Every other outcome refuses the line, so no repo is set. A parser
        // that set one anyway would send it on to a URL nobody named.
        else => {
            for (words) |arg| try std.testing.expect(!std.mem.eql(u8, arg, default_repo));
            return;
        },
    };

    // The repo is bytes the caller typed, never ones the parser composed: a
    // value out of no word is a value nobody named. The joined `--repo=value`
    // is the one spelling where the repo is a slice of a word rather than a
    // word of its own, which is why the test is containment.
    var named = false;
    for (words) |arg| {
        if (std.mem.indexOf(u8, arg, repo) != null) named = true;
    }
    if (!named) {
        std.debug.print("a repo no argument carried: {s}\n", .{repo});
        return error.TestUnexpectedResult;
    }

    // And the URL it reaches is the one that repo earns, or none at all. A
    // repo shape `validRepo` refuses must not become a request to a host the
    // caller did not name.
    var buf: [1024]u8 = undefined;
    if (!validRepo(repo)) {
        try std.testing.expectError(error.BadRepo, releaseApiUrl(&buf, repo));
    } else {
        const url = releaseApiUrl(&buf, repo) catch |err| switch (err) {
            // A repo too long for the buffer is refused rather than truncated
            // into a URL naming a different repository.
            error.NameTooLong => {
                try std.testing.expect(repo.len + release_api_url_fixed.len > buf.len);
                return;
            },
            error.BadRepo => return error.TestUnexpectedResult,
        };
        try std.testing.expect(std.mem.startsWith(u8, url, "https://api.github.com/repos/"));
        try std.testing.expect(std.mem.endsWith(u8, url, "/releases/latest"));
        // Whatever the caller typed is inside the URL verbatim, so a repo with
        // a query, a fragment or an escape in it is still the one host, and
        // never one the value could redirect the request to.
        try std.testing.expect(std.mem.indexOf(u8, url, repo) != null);
        try std.testing.expect(trustedGithubUrl(url));
    }

    // A repo is quoted into an error message with a terminal-safe escaper, so
    // the quoted form is a prefix of what the whole repo escapes to, cut on a
    // codepoint boundary, and it is itself a string a reader can be shown: one
    // line, valid UTF-8, and never a byte a terminal acts on.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const quoted = quoteUntrusted(arena, repo);
    try std.testing.expect(quoted.len <= net.quoted_value_bytes);
    try std.testing.expect(std.unicode.utf8ValidateSlice(quoted));
    for (quoted) |c| try std.testing.expect(c >= 0x20 and c != 0x7f);
    // The budget cuts the escaped text, never the repo, so what is quoted is
    // the start of the whole thing: a cut that dropped or reordered a byte
    // would name a repository the caller never typed.
    const whole = chat.safeText(arena, repo, std.math.maxInt(usize));
    try std.testing.expect(std.mem.startsWith(u8, whole, quoted));
    // And a short repo is quoted whole, escapes and all.
    if (repo.len <= net.quoted_value_bytes) try std.testing.expectEqualStrings(whole, quoted);
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
    // A pre-release is a version, and it is the one released before its triple,
    // so it orders against every other tag rather than past the guard as an
    // unorderable one did.
    try std.testing.expectEqual(std.math.Order.gt, compareVersions("0.2.0-rc1", "v0.1.1"));
    try std.testing.expectEqual(std.math.Order.lt, compareVersions("0.1.0", "v0.2.0-rc1"));
    // Same triple: the release is newer than the pre-release of itself.
    try std.testing.expectEqual(std.math.Order.gt, compareVersions("0.2.0", "v0.2.0-rc1"));
    // And the other way, so a pre-release build takes the release it precedes.
    try std.testing.expectEqual(std.math.Order.lt, compareVersions("v0.2.0-rc1", "0.2.0"));
    // A pre-release may carry dots of its own, and one that does is still the
    // same triple: reading the suffix's dots as a fourth component made the tag
    // parse as no version at all, which ordered it as `.eq` and let it past the
    // guard.
    try std.testing.expectEqual(std.math.Order.gt, compareVersions("0.3.0", "v0.2.0-rc.1"));
    try std.testing.expectEqual(std.math.Order.gt, compareVersions("0.2.0", "v0.2.0-rc.1"));
    try std.testing.expectEqual(std.math.Order.eq, compareVersions("0.2.0", "v0.2.0+build.1"));
    try std.testing.expect(!fetchesAsset(false, "0.3.0", "v0.2.0-rc.1"));
    // A tag that is not a dotted triple at all carries no order to claim, so it
    // stays on the caller's explicit request rather than being blocked.
    try std.testing.expectEqual(std.math.Order.eq, compareVersions("0.2.0", "nightly"));
    try std.testing.expectEqual(std.math.Order.eq, compareVersions("0.2.0", "v0.1.x"));

    try std.testing.expect(!fetchesAsset(false, "0.2.0", "v0.1.1"));
    // The downgrade the pre-release ordering closes: a build on a release is
    // not replaced by that triple's own pre-release, nor by an older one.
    try std.testing.expect(!fetchesAsset(false, "0.2.0", "v0.2.0-rc1"));
    try std.testing.expect(!fetchesAsset(false, "0.3.0", "v0.2.0-rc1"));
    // Upgrading onto a pre-release is still an install, which is the case an
    // operator asks for by naming one.
    try std.testing.expect(fetchesAsset(false, "0.1.0", "v0.2.0-rc1"));
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
    try std.testing.expectEqualStrings("maci0/microagent", quoteUntrusted(gpa, "maci0/microagent"));
    const long = "日本語/" ++ "x" ** 200;
    const quoted = quoteUntrusted(gpa, long);
    try std.testing.expect(quoted.len <= net.quoted_value_bytes);
    try std.testing.expect(std.unicode.utf8ValidateSlice(quoted));
    try std.testing.expect(std.mem.startsWith(u8, long, quoted));
    // Three-byte characters throughout: the cut is on one of them, so the
    // quote holds whole ones and no more than the byte budget allows.
    try std.testing.expectEqualStrings("日" ** 26, quoteUntrusted(gpa, "日" ** 40));
    // A byte that is not text, and a control character, reach the line as
    // text rather than as mojibake or as a cursor the operator did not ask for.
    try std.testing.expectEqualStrings("bad\\x1b[31m\u{fffd}", quoteUntrusted(gpa, "bad\x1b[31m\xff"));
}

// The release body's tag and asset name reach every line this run prints
// about a version, a missing asset or a failed download. They are the only
// values in the update path this program did not spell, and a tag carrying
// ESC, BEL or a C1 control would otherwise put an escape sequence on the
// operator's terminal through a line that looks like the four this run writes
// on an ordinary day.
test "update: a tag and an asset name from the release body are quoted before a line prints them" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const hostile = "{\"tag_name\":\"v0.1.0\\u001b[2J\\u0007\\u009b31m\",\"html_url\":\"https://github.com/o/r\",\"assets\":[" ++
        "{\"name\":\"microagent-v0.1.0\\u001b[2J-x86_64-linux-musl\",\"browser_download_url\":\"https://github.com/o/r/a\"}]}";
    const d = try decideFromBody(arena, hostile);

    // The decision reads the bytes the body carried: a control character in a
    // tag is not a reason to refuse a release, and the name to match is the one
    // published.
    try std.testing.expectEqualStrings("v0.1.0\x1b[2J\x07\u{009b}31m", d.in.tag);
    try std.testing.expectEqualStrings("microagent-v0.1.0\x1b[2J-x86_64-linux-musl", d.in.basename);
    try std.testing.expectEqualStrings("v0.1.0\\x1b[2J\\x07\\x9b31m", d.shown_tag);
    for (d.shown_tag) |c| try std.testing.expect(c >= 0x20 and c != 0x7f);

    // And the install line carries the quoted tag, so an operator reading what
    // the update installed is not shown what the response said.
    var line_buf: [256]u8 = undefined;
    const line = try formatInstalled(&line_buf, d.shown_tag, "/usr/local/bin/microagent");
    try std.testing.expectEqualStrings(
        "Installed v0.1.0\\x1b[2J\\x07\\x9b31m to /usr/local/bin/microagent",
        line,
    );
    for (line) |c| try std.testing.expect(c >= 0x20 and c != 0x7f);
}

// Every url this program fetches except the API one is a field of the release
// body, and `trustedGithubUrl` reads only the scheme, the host and the port: a
// path carrying an escape sequence or a byte that is not text passes it. The
// request needs the url as written, so the line that names it is the one that
// has to quote, and these are the two lines a retry prints.
test "update: a retry line quotes the url off the wire" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const url = "https://github.com/o/r/download/\x1b[2J\xff";
    const retry = retryLine(arena, url, error.ConnectionRefused, 1000, 1);
    try std.testing.expect(std.mem.indexOf(u8, retry, "https://github.com/o/r/download/\\x1b[2J") != null);
    try expectNoControl(retry);

    const waited = waitLine(arena, url, 1000, error.ClockRemoved);
    try std.testing.expect(std.mem.indexOf(u8, waited, "https://github.com/o/r/download/\\x1b[2J") != null);
    try expectNoControl(waited);

    // A url of plain ASCII is unchanged, so an operator reading a normal retry
    // sees the endpoint rather than a spelling of it.
    try std.testing.expect(std.mem.indexOf(u8, retryLine(arena, "https://api.github.com/repos/o/r/releases/latest", error.Timeout, 1000, 1), "https://api.github.com/repos/o/r/releases/latest") != null);
}

/// Nothing on the line acts on a terminal, and the line is text, which is what
/// the quoting exists to guarantee. The terminating newline is the line's own
/// and is the one control it is allowed.
fn expectNoControl(line: []const u8) !void {
    try std.testing.expect(std.mem.endsWith(u8, line, "\n"));
    for (line[0 .. line.len - 1]) |c| try std.testing.expect(c >= 0x20 and c != 0x7f);
    try std.testing.expect(std.unicode.utf8ValidateSlice(line));
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
    // A tag that is not a triple still installs, and says the comparison was
    // not made rather than calling the build current. Its arguments are the
    // tool, the running version and the tag in that order, the same order
    // `formatCurrent` takes them.
    try std.testing.expectEqualStrings(
        "microagent 0.1.0 is not the latest release (nightly), which is not a version triple to compare against",
        try formatUncompared(&buf, "microagent", "0.1.0", "nightly"),
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
        // An up-to-date build is `current` on the two versions alone: the asset
        // and the sidecar are never fetched, so a release that published
        // neither is not a reason to fail an update. Filling the row in would
        // let the same-release check move to the end of the function and leave
        // every case below answering the same.
        .{
            .want = .current,
            .in = .{ .running = "0.1.0", .tag = "v0.1.0" },
        },
        .{
            .want = .checksum_mismatch,
            .in = .{ .running = "0.1.0", .tag = "v0.2.0", .asset_url = good_url, .asset = "abc", .sidecar_url = good_side_url, .sidecar = bad_side, .basename = asset_base },
        },
        .{
            .want = .missing_sidecar,
            .in = .{ .running = "0.1.0", .tag = "v0.2.0", .asset_url = good_url, .asset = "abc", .sidecar_url = null, .basename = asset_base },
        },
        // A sidecar the body carried with nothing in it: the URL was there and
        // the body was empty, which is a 200 with a zero-length reply and not
        // a digest that failed to match.
        .{
            .want = .missing_sidecar,
            .in = .{ .running = "0.1.0", .tag = "v0.2.0", .asset_url = good_url, .asset = "abc", .sidecar_url = good_side_url, .sidecar = "", .basename = asset_base },
        },
        .{
            .want = .missing_asset,
            .in = .{ .running = "0.1.0", .tag = "v0.2.0", .asset_url = null, .asset = "abc", .sidecar_url = good_side_url, .sidecar = good_side, .basename = asset_base },
        },
        // A release with neither is reported as the asset it is missing first,
        // so the message names the asset rather than a sidecar of a download
        // that never happened.
        .{
            .want = .missing_asset,
            .in = .{ .running = "0.1.0", .tag = "v0.2.0" },
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
        // The digest has to come from the same host as the bytes it is checked
        // against: a release that points the binary at github.com and the
        // sidecar at a lookalike would otherwise install unverified bytes
        // through a check the two hosts never shared.
        .{
            .want = .untrusted_url,
            .in = .{ .running = "0.1.0", .tag = "v0.2.0", .asset_url = good_url, .asset = "abc", .sidecar_url = "https://example.com/microagent.sha256", .sidecar = good_side, .basename = asset_base },
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
    // The replacement is a program the next run execs, so the mode is part of
    // what was installed: a copy of the right bytes no shell can run is not an
    // update, and a test that reads only the contents would pass on it.
    const mode = (try tmp.dir.statFile(io, "microagent", .{})).permissions.toMode();
    try std.testing.expectEqual(exec_mode.toMode(), mode & 0o7777);
    try std.testing.expect(mode & 0o111 != 0);
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

    // Over it: the chunk is written whole and the cap is checked against what
    // arrived, so the body holds the crossing chunk rather than a prefix of it
    // and the caller is told with an error it cannot mistake for a short read.
    // The cost of the overshoot is one chunk, which is why the chunk a fetch
    // reads at a time bounds it, and `reset` is what takes the body back to
    // empty before a second attempt.
    try std.testing.expectError(error.WriteFailed, capped.writer.writeAll("y" ** 1024));
    try std.testing.expect(capped.over);
    try std.testing.expectEqual(@as(usize, 5 + 1024), capped.body.written().len);
    // What the body holds is the bytes that crossed it, nothing dropped and
    // nothing invented, because the checksum is computed over exactly these.
    try std.testing.expectEqualStrings("short" ++ "y" ** 1024, capped.body.written());
    capped.reset();
    try std.testing.expect(!capped.over);
    try std.testing.expectEqualStrings("", capped.body.written());
    // And the reader answers the next fetch from an empty body, so two
    // attempts never concatenate into a body no release published.
    try capped.writer.writeAll("second");
    try std.testing.expectEqualStrings("second", capped.body.written());
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

test "update: replaceVerified follows a chain of symlinked destinations" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "real_bin", .data = "old-content" });
    try tmp.dir.symLink(io, "real_bin", "versioned_bin", .{});
    try tmp.dir.symLink(io, "versioned_bin", "microagent", .{});

    try replaceVerified(io, tmp.dir, "microagent", .replaced, "new-content");

    // Both links are still links: a resolution that stopped at the first one
    // replaced `versioned_bin` with a regular file, so the update landed on a
    // copy and the binary the user runs never changed.
    var link_buf: [256]u8 = undefined;
    const outer = try tmp.dir.readLink(io, "microagent", &link_buf);
    try std.testing.expectEqualStrings("versioned_bin", link_buf[0..outer]);
    const inner = try tmp.dir.readLink(io, "versioned_bin", &link_buf);
    try std.testing.expectEqualStrings("real_bin", link_buf[0..inner]);

    const got = try tmp.dir.readFileAlloc(io, "real_bin", alloc, .limited(64));
    defer alloc.free(got);
    try std.testing.expectEqualStrings("new-content", got);
}

// The install is the one write in this tree with the largest blast radius, and
// the one a duplicate is hardest to see: the same bytes over the same path is
// what a second `update` does by design, so nothing in the output says it ran
// twice. The contract is that a second execution reaches the state the first
// one left, and it is checked over a symlinked destination because that is the
// shape a packaged install actually has: the link must still be a link, and the
// file it names must still hold the asset, or the second run resolved the path
// differently and left the user's link pointing at a copy it never wrote.
test "update: replacing the binary twice leaves the one install" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "real_bin", .data = "old-content" });
    try tmp.dir.symLink(io, "real_bin", "microagent", .{});

    try replaceVerified(io, tmp.dir, "microagent", .replaced, "new-content");
    // The second execution carries the same asset, which is what a re-run after
    // a completed install, a retry of a command whose output was lost, and a
    // wrapper that runs it twice a day all hand it.
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

/// A release the updater may install: a published asset on a GitHub URL.
const published_release = "{\"tag_name\":\"v0.1.0\",\"html_url\":\"https://github.com/maci0/microagent/releases/tag/v0.1.0\",\"assets\":[" ++ asset_base_fixture ++ "]}";
/// A release whose assets name the hosts `trustedGithubUrl` refuses: a
/// lookalike domain, a trusted name in the path, http, a userinfo, and a
/// raw.githubusercontent.com asset.
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
    "{\"tag_name\":\"v0.1.0\\u001b[2J\\u0007\",\"html_url\":\"https://github.com/o/r\",\"assets\":[{\"name\":\"microagent-v0.1.0\\u001b[2J-x86_64-linux-musl\",\"browser_download_url\":\"https://github.com/o/r/a\"}]}",
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
    const bare = bareVersion(tag);
    try std.testing.expect(sameRelease(tag, tag));
    try std.testing.expect(sameRelease(bare, tag));
    try std.testing.expect(sameRelease(tag, bare));
    try std.testing.expect(!sameRelease(bare, try std.fmt.allocPrint(arena, "{s}x", .{bare})));

    // What a diagnostic quotes is the quoted form, and nothing in it is a byte
    // a terminal acts on. The tag and the asset name are the release body's own
    // bytes, and every line this run prints about a version, a missing asset or
    // a failed download names one of them.
    for ([_][]const u8{ d.shown_tag, d.shown_asset }) |shown| {
        try std.testing.expect(shown.len <= net.quoted_value_bytes);
        try std.testing.expect(std.unicode.utf8ValidateSlice(shown));
        for (shown) |c| try std.testing.expect(c >= 0x20 and c != 0x7f);
    }
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
