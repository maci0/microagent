//! `microagent update`: compare this build with the latest GitHub release and,
//! when asked to install, replace the running executable only after its bytes
//! match the `.sha256` sidecar the release publishes.
//!
//! The decision (repo shape, exact version, asset name, checksum, trusted URL)
//! is pure; `run` is the only function that talks to GitHub or names the
//! running executable, and tests never execute it.

const std = @import("std");
const builtin = @import("builtin");
const main_mod = @import("main.zig");

const version = @import("build_options").version;

pub const default_repo = "maci0/microagent";
pub const tool_name = "microagent";

const exec_mode: std.Io.File.Permissions = @enumFromInt(@as(std.posix.mode_t, 0o755));

const max_api_bytes: usize = 10 * 1024 * 1024;
const max_sidecar_bytes: usize = 64 * 1024;
const max_asset_bytes: usize = 256 * 1024 * 1024;

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

/// One leading `v` on the tag, then exact equality. `v0.1.0` is `0.1.0`.
pub fn sameRelease(running: []const u8, tag: []const u8) bool {
    const bare = if (std.mem.startsWith(u8, tag, "v")) tag[1..] else tag;
    return std.mem.eql(u8, running, bare);
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

pub fn thisTarget(buf: []u8) []const u8 {
    return targetTriple(buf, @tagName(builtin.cpu.arch), @tagName(builtin.os.tag), @tagName(builtin.abi));
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

/// Stdout of `--check` is this URL, or nothing when the page is not a GitHub
/// https URL.
pub fn releasePageLine(url: []const u8) error{UntrustedUrl}![]const u8 {
    if (!trustedGithubUrl(url)) return error.UntrustedUrl;
    return url;
}

/// `--check` never downloads an asset. An equal version never does either.
pub fn fetchesAsset(check_only: bool, running: []const u8, tag: []const u8) bool {
    if (check_only) return false;
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
    var link_buf: [4096]u8 = undefined;
    var joined_buf: [4096]u8 = undefined;
    const target: []const u8 = if (dir.readLink(io, dest_name, &link_buf)) |n| blk: {
        const link = link_buf[0..n];
        if (link.len > 0 and link[0] == '/') break :blk link;
        const dir_end = std.mem.findScalarLast(u8, dest_name, '/') orelse break :blk link;
        break :blk std.fmt.bufPrint(&joined_buf, "{s}/{s}", .{ dest_name[0..dir_end], link }) catch break :blk link;
    } else |err| switch (err) {
        error.NotLink, error.FileNotFound => dest_name,
        else => return err,
    };

    var af = try dir.createFileAtomic(io, target, .{ .replace = true, .make_path = true, .permissions = exec_mode });
    defer af.deinit(io);
    try af.file.writeStreamingAll(io, asset);
    try af.replace(io);
}

pub fn formatCurrent(buf: []u8, tool: []const u8, running: []const u8, tag: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "{s} {s} is current (latest release: {s})", .{ tool, running, tag });
}

pub fn formatNewRelease(buf: []u8, tag: []const u8, running: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "New release: {s} (running {s})", .{ tag, running });
}

pub fn formatInstalled(buf: []u8, tag: []const u8, path: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "Installed {s} to {s}", .{ tag, path });
}

pub fn parseRelease(arena: std.mem.Allocator, body: []const u8) !Release {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch return error.MalformedRelease;
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

fn writeErr(io: std.Io, bytes: []const u8) void {
    std.Io.File.stderr().writeStreamingAll(io, bytes) catch {};
}

fn writeOut(io: std.Io, bytes: []const u8) void {
    std.Io.File.stdout().writeStreamingAll(io, bytes) catch {};
}

fn fail(io: std.Io, comptime fmt: []const u8, args: anytype) u8 {
    var buf: [512]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "microagent update: " ++ fmt ++ "\n", args) catch
        "microagent update: failed\n";
    writeErr(io, line);
    return 1;
}

/// One GET, body capped. `client` is shared across the three fetches a run
/// makes so the CA store is loaded once. On an HTTP error `status_out` carries
/// the code, which is the difference between "no release yet" and "rate limit".
fn fetchBody(
    client: *std.http.Client,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    url: []const u8,
    bearer: ?[]const u8,
    max_size: usize,
    status_out: *std.http.Status,
) ![]const u8 {
    var priv_buf: [1]std.http.Header = undefined;
    const priv_headers: []const std.http.Header = if (bearer) |b| blk: {
        priv_buf[0] = .{ .name = "Authorization", .value = b };
        break :blk priv_buf[0..1];
    } else &.{};

    var writer = try std.Io.Writer.Allocating.initCapacity(gpa, @min(max_size, 64 * 1024));
    defer writer.deinit();

    const result = try client.fetch(.{
        .location = .{ .url = url },
        .headers = .{ .user_agent = .{ .override = "microagent/" ++ version } },
        .privileged_headers = priv_headers,
        .response_writer = &writer.writer,
    });
    status_out.* = result.status;
    if (@intFromEnum(result.status) >= 400) return error.HttpStatus;

    const data = writer.written();
    if (data.len > max_size) return error.PayloadTooLarge;
    return try arena.dupe(u8, data);
}

fn replaceExecutable(io: std.Io, gpa: std.mem.Allocator, asset: []const u8) ![]const u8 {
    const exe = try std.process.executablePathAlloc(io, gpa);
    const base = std.fs.path.basename(exe);
    if (std.fs.path.dirname(exe)) |dir_path| {
        var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{});
        defer dir.close(io);
        try replaceVerified(io, dir, base, .replaced, asset);
    } else {
        try replaceVerified(io, std.Io.Dir.cwd(), base, .replaced, asset);
    }
    return exe;
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
    \\      --repo OWNER/NAME  GitHub repository to track (default maci0/microagent)
    \\  -h, --help             this text
    \\  -V, --version          version
    \\
    \\environment:
    \\  GITHUB_TOKEN           GitHub token, to get past the anonymous rate limit
    \\
    \\With --check, stdout is the release page URL and the version comparison
    \\goes to stderr; nothing is downloaded. Exit 0 means the check ran;
    \\exit 1 means it did not, exit 2 is a usage error.
    \\
;

pub fn printUsage(io: std.Io) void {
    writeOut(io, usage_text);
}

fn githubBearer(gpa: std.mem.Allocator, env: *std.process.Environ.Map) ?[]const u8 {
    const tok = env.get("GITHUB_TOKEN") orelse return null;
    if (tok.len == 0) return null;
    return std.fmt.allocPrint(gpa, "Bearer {s}", .{tok}) catch null;
}

/// The two HTTP codes whose cause is worth naming: no release is published for
/// the repo yet, and the anonymous API rate limit.
fn statusHint(status: std.http.Status) []const u8 {
    return switch (status) {
        .not_found => " (no published release)",
        .forbidden, .too_many_requests => " (rate limited; set GITHUB_TOKEN)",
        else => "",
    };
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
    var check_only = false;
    var repo_arg: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "help")) {
            printUsage(io);
            return 0;
        } else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-V")) {
            writeOut(io, "microagent " ++ version ++ "\n");
            return 0;
        } else if (std.mem.eql(u8, arg, "--check") or std.mem.eql(u8, arg, "-c")) {
            check_only = true;
        } else if (std.mem.eql(u8, arg, "--repo")) {
            i += 1;
            if (i >= args.len) return updateUsageError(io, "--repo needs a value (owner/name)");
            repo_arg = args[i];
        } else if (std.mem.startsWith(u8, arg, "--repo=")) {
            repo_arg = arg["--repo=".len..];
        } else {
            return updateUsageError(io, arg);
        }
    }

    const repo = repo_arg orelse default_repo;
    var api_buf: [240]u8 = undefined;
    const api = releaseApiUrl(&api_buf, repo) catch {
        var msg: [192]u8 = undefined;
        const line = std.fmt.bufPrint(&msg, "microagent update: want owner/repo, not a URL (got '{s}')\n", .{
            repo[0..@min(repo.len, 80)],
        }) catch "microagent update: want owner/repo, not a URL\n";
        writeErr(io, line);
        return 2;
    };

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    loadCaBundle(&client, io, gpa, arena, env);

    const bearer = githubBearer(arena, env);
    var status: std.http.Status = .ok;
    const body = fetchBody(&client, gpa, arena, api, bearer, max_api_bytes, &status) catch |err| {
        if (err == error.HttpStatus) return fail(io, "GitHub returned HTTP {d} for {s}{s}", .{
            @intFromEnum(status), repo, statusHint(status),
        });
        return fail(io, "could not reach GitHub ({s})", .{@errorName(err)});
    };
    const rel = parseRelease(arena, body) catch return fail(io, "the latest release could not be read", .{});
    const page = releasePageLine(rel.page) catch
        return fail(io, "refusing to install unverified binary", .{});

    var line_buf: [256]u8 = undefined;
    if (sameRelease(version, rel.tag)) {
        const line = formatCurrent(&line_buf, tool_name, version, rel.tag) catch
            return fail(io, "could not format the version comparison", .{});
        writeErr(io, line);
        writeErr(io, "\n");
    } else {
        const line = formatNewRelease(&line_buf, rel.tag, version) catch
            return fail(io, "could not format the version comparison", .{});
        writeErr(io, line);
        writeErr(io, "\n");
    }

    if (!fetchesAsset(check_only, version, rel.tag)) {
        if (check_only) {
            writeOut(io, page);
            writeOut(io, "\n");
        }
        return 0;
    }

    var target_buf: [64]u8 = undefined;
    const target = thisTarget(&target_buf);
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

    const asset = fetchBody(&client, gpa, arena, a_url, bearer, max_asset_bytes, &status) catch |err|
        return fail(io, "could not download {s} ({s}); the binary was not replaced", .{ asset_name, @errorName(err) });
    const sidecar = fetchBody(&client, gpa, arena, s_url, bearer, max_sidecar_bytes, &status) catch |err|
        return fail(io, "could not download the checksum sidecar ({s}); the binary was not replaced", .{@errorName(err)});

    const decision = decide(.{
        .running = version,
        .tag = rel.tag,
        .asset_url = a_url,
        .asset = asset,
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

    const exe = replaceExecutable(io, gpa, asset) catch |err|
        return fail(io, "could not replace the binary ({s})", .{@errorName(err)});
    const installed = formatInstalled(&line_buf, rel.tag, exe) catch
        return fail(io, "could not format the install line", .{});
    writeOut(io, installed);
    writeOut(io, "\n");
    return 0;
}

fn updateUsageError(io: std.Io, arg: []const u8) u8 {
    var buf: [224]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "microagent update: unknown or incomplete argument '{s}'\n", .{arg}) catch
        "microagent update: bad arguments\n";
    writeErr(io, line);
    printUsage(io);
    return 2;
}

/// The same CA-bundle escape hatch the agent run has: an image that ships no
/// ca-certificates can still reach GitHub by naming a PEM file.
fn loadCaBundle(
    client: *std.http.Client,
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    env: *std.process.Environ.Map,
) void {
    var path: []const u8 = env.get("MICROAGENT_CA_BUNDLE") orelse "";
    if (path.len == 0) path = env.get("SSL_CERT_FILE") orelse "";
    if (path.len == 0) return;
    main_mod.loadCaBundle(client, io, gpa, path, arena);
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
    try std.testing.expect(!sameRelease("v0.1.0", "v0.1.0"));
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
    var live_buf: [64]u8 = undefined;
    var via_buf: [64]u8 = undefined;
    const want = targetTriple(&via_buf, @tagName(builtin.cpu.arch), @tagName(builtin.os.tag), @tagName(builtin.abi));
    const got = thisTarget(&live_buf);
    try std.testing.expectEqualStrings(want, got);
    try std.testing.expect(!std.mem.endsWith(u8, got, "-none"));
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

test "update: --check and an equal version do not fetch an asset" {
    try std.testing.expect(!fetchesAsset(true, "0.1.0", "v0.2.0"));
    try std.testing.expect(!fetchesAsset(false, "0.1.0", "v0.1.0"));
    try std.testing.expect(fetchesAsset(false, "0.1.0", "v0.2.0"));
}

test "update: checksum line is the published hex, two spaces, and the basename" {
    const sidecar = abc_sha ++ "  " ++ asset_base ++ "\n";
    try std.testing.expect(checksumMatches("abc", sidecar, asset_base));
    try std.testing.expect(!checksumMatches("abd", sidecar, asset_base));
    try std.testing.expect(!checksumMatches("abc", sidecar, "other"));
    const one_space = abc_sha ++ " " ++ asset_base;
    try std.testing.expect(!checksumMatches("abc", one_space, asset_base));
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

    const current = decide(.{
        .running = "0.1.0",
        .tag = "v0.1.0",
        .asset_url = good_url,
        .asset = "abc",
        .sidecar_url = good_side_url,
        .sidecar = good_side,
        .basename = asset_base,
    });
    try std.testing.expectEqual(Verdict.current, current);
    try std.testing.expectError(error.Refused, replaceVerified(io, tmp.dir, "microagent", current, "abc"));

    const mismatch = decide(.{
        .running = "0.1.0",
        .tag = "v0.2.0",
        .asset_url = good_url,
        .asset = "abc",
        .sidecar_url = good_side_url,
        .sidecar = bad_side,
        .basename = asset_base,
    });
    try std.testing.expectEqual(Verdict.checksum_mismatch, mismatch);
    try std.testing.expectError(error.Refused, replaceVerified(io, tmp.dir, "microagent", mismatch, "abc"));

    const missing = decide(.{
        .running = "0.1.0",
        .tag = "v0.2.0",
        .asset_url = good_url,
        .asset = "abc",
        .sidecar_url = null,
        .basename = asset_base,
    });
    try std.testing.expectEqual(Verdict.missing_sidecar, missing);
    try std.testing.expectError(error.Refused, replaceVerified(io, tmp.dir, "microagent", missing, "abc"));

    const untrusted = decide(.{
        .running = "0.1.0",
        .tag = "v0.2.0",
        .asset_url = "http://github.com/maci0/microagent/releases/download/v0.2.0/" ++ asset_base,
        .asset = "abc",
        .sidecar_url = good_side_url,
        .sidecar = good_side,
        .basename = asset_base,
    });
    try std.testing.expectEqual(Verdict.untrusted_url, untrusted);
    try std.testing.expectError(error.Refused, replaceVerified(io, tmp.dir, "microagent", untrusted, "abc"));

    const off_host = decide(.{
        .running = "0.1.0",
        .tag = "v0.2.0",
        .asset_url = "https://example.com/microagent",
        .asset = "abc",
        .sidecar_url = good_side_url,
        .sidecar = good_side,
        .basename = asset_base,
    });
    try std.testing.expectEqual(Verdict.untrusted_url, off_host);
    try std.testing.expectError(error.Refused, replaceVerified(io, tmp.dir, "microagent", off_host, "abc"));

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
