//! `microagent update`: compare this build with the latest GitHub release and,
//! unless `--check`, replace the running executable once the downloaded asset
//! matches the `.sha256` sidecar the release publishes.

const std = @import("std");
const builtin = @import("builtin");
const net = @import("net.zig");
const chat = @import("chat.zig");

const version = @import("build_options").version;

const default_repo = "maci0/microagent";
const tool_name = "microagent";
const release_api_url = "https://api.github.com/repos/" ++ default_repo ++ "/releases/latest";

const exec_mode: std.Io.File.Permissions = @enumFromInt(@as(std.posix.mode_t, 0o755));

const max_api_bytes: usize = 10 * 1024 * 1024;
const max_sidecar_bytes: usize = 64 * 1024;
const max_asset_bytes: usize = 256 * 1024 * 1024;

/// The room a response buffer is given up front. A body larger than this grows
/// into it, and one smaller never allocates more than it read.
const initial_body_capacity: usize = 64 * 1024;

/// The longest DNS name, so the buffer that lowercases a host has a fixed size.
const max_host_len: usize = 253;

/// One printed line: a whole install path (unquoted) beside a sentence. The
/// path is quoted by `safeTextAll`, which spends up to `chat.safe_text_widening`
/// bytes on an input byte, so a path of every possible length still fits beside
/// the sentence naming it: a buffer sized for the raw path turned every
/// diagnostic about a long one into "message too long", which is the one line
/// that says nothing about what went wrong.
const line_bytes: usize = std.fs.max_path_bytes * chat.safe_text_widening + 256;

/// Release-body text (tag, asset name, argument) as safe to print: cut on a
/// codepoint boundary, control and invisible characters escaped, invalid UTF-8
/// replaced.
fn quoteUntrusted(arena: std.mem.Allocator, text: []const u8) []const u8 {
    return chat.safeText(arena, text, net.quoted_value_bytes);
}

const ListedAsset = struct {
    name: []const u8,
    url: []const u8,
};

const Release = struct {
    tag: []const u8,
    page: []const u8,
    assets: []const ListedAsset,
};

/// Equal after dropping one leading `v` from each side.
fn sameRelease(running: []const u8, tag: []const u8) bool {
    return std.mem.eql(u8, bareVersion(running), bareVersion(tag));
}

fn bareVersion(release: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, release, "v")) release[1..] else release;
}

const Version = struct {
    triple: [3]u64,
    prerelease: bool,
};

/// `major.minor.patch` (missing components are 0) with an optional `-pre` or
/// `+build` suffix; null for anything else. A `-` suffix marks a pre-release,
/// `+` does not.
fn parseVersion(release: []const u8) ?Version {
    const v = bareVersion(release);
    const cut = std.mem.indexOfAny(u8, v, "-+") orelse v.len;
    var out: Version = .{ .triple = .{ 0, 0, 0 }, .prerelease = cut != v.len and v[cut] == '-' };
    var it = std.mem.splitScalar(u8, v[0..cut], '.');
    var n: usize = 0;
    while (it.next()) |c| {
        if (n == out.triple.len or c.len == 0) return null;
        out.triple[n] = std.fmt.parseInt(u64, c, 10) catch return null;
        n += 1;
    }
    return out;
}

/// Where the running build sits against a tag. A pre-release sorts below its
/// own triple. Either side that is not a version is `.eq`, which leaves the
/// caller on `sameRelease`.
fn compareVersions(running: []const u8, tag: []const u8) std.math.Order {
    const a = parseVersion(running) orelse return .eq;
    const b = parseVersion(tag) orelse return .eq;
    for (a.triple, b.triple) |an, bn| {
        if (an != bn) return if (an < bn) .lt else .gt;
    }
    // Two pre-releases of the same triple are the same release, so neither
    // sorts below the other; only a pre-release against its own final build is
    // an ordering.
    if (a.prerelease != b.prerelease) return if (a.prerelease) .lt else .gt;
    return .eq;
}

/// The release asset for a target: Linux is always the static musl build,
/// other systems carry no abi.
fn assetName(arena: std.mem.Allocator, tag: []const u8, arch: std.Target.Cpu.Arch, os: std.Target.Os.Tag) ![]const u8 {
    const abi = if (os == .linux) "-musl" else "";
    return std.fmt.allocPrint(arena, tool_name ++ "-{s}-{t}-{t}{s}", .{ tag, arch, os, abi });
}

fn hostTrusted(host: []const u8) bool {
    var lower: [max_host_len]u8 = undefined;
    if (host.len == 0 or host.len > lower.len) return false;
    const h = std.ascii.lowerString(&lower, host);
    return std.mem.eql(u8, h, "github.com") or
        std.mem.endsWith(u8, h, ".github.com") or
        std.mem.endsWith(u8, h, ".githubusercontent.com");
}

/// https, no userinfo, whitespace or backslash, an optional numeric port, and a
/// host that is `github.com`, `*.github.com` or `*.githubusercontent.com`.
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

/// The `GITHUB_TOKEN` as a bearer value, or null when unset or blank. Lives in
/// the run arena.
///
/// The outer error is the allocation the header is built with. It is not
/// folded into the null: a token that is simply absent is an anonymous
/// request, and one that was set and could not be copied is the same
/// anonymous request with nothing on stderr, which arrives as the rate-limit
/// refusal the token was there to avoid.
fn githubBearer(arena: std.mem.Allocator, env: *std.process.Environ.Map) (std.mem.Allocator.Error!?[]const u8) {
    const tok = std.mem.trim(u8, env.get("GITHUB_TOKEN") orelse return null, net.env_surrounding);
    if (tok.len == 0) return null;
    // The token rides in an `Authorization` line, so a byte below 0x20 ends
    // that line and the rest of the value is a header of the environment's own
    // making. The API key and the MCP key are both held to this rule.
    if (net.hasHeaderControlBytes(tok)) return null;
    return try std.fmt.allocPrint(arena, "Bearer {s}", .{tok});
}

/// The bearer only for api.github.com; the public asset hosts never see it.
fn bearerFor(url: []const u8, bearer: ?[]const u8) ?[]const u8 {
    if (!std.ascii.startsWithIgnoreCase(url, "https://api.github.com/")) return null;
    return bearer;
}

/// Sidecar first line as `sha256sum` writes it: `<hex>  <basename>`, matching
/// the SHA-256 of `asset`.
fn checksumMatches(asset: []const u8, sidecar: []const u8, basename: []const u8) bool {
    const line_end = std.mem.findScalar(u8, sidecar, '\n') orelse sidecar.len;
    var line = sidecar[0..line_end];
    if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
    const hex_len = std.crypto.hash.sha2.Sha256.digest_length * 2;
    const name_at = hex_len + 2;
    if (line.len < name_at) return false;
    if (!std.mem.eql(u8, line[hex_len..name_at], "  ")) return false;
    if (!std.mem.eql(u8, line[name_at..], basename)) return false;
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(asset, &digest, .{});
    const got = std.fmt.bytesToHex(digest, .lower);
    return std.ascii.eqlIgnoreCase(line[0..hex_len], &got);
}

/// Errors: `MalformedRelease` for a body that is not a release object,
/// `OutOfMemory` for the machine. Strings live in `arena`.
fn parseRelease(arena: std.mem.Allocator, body: []const u8) !Release {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.MalformedRelease,
    };
    const obj = switch (parsed) {
        .object => |o| o,
        else => return error.MalformedRelease,
    };
    const tag = chat.str(obj.get("tag_name")) orelse return error.MalformedRelease;
    const page = chat.str(obj.get("html_url")) orelse return error.MalformedRelease;
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
        const name = chat.str(asset_obj.get("name")) orelse continue;
        const url = chat.str(asset_obj.get("browser_download_url")) orelse continue;
        try list.append(arena, .{ .name = name, .url = url });
    }
    return .{ .tag = tag, .page = page, .assets = try list.toOwnedSlice(arena) };
}

fn assetUrl(rel: Release, name: []const u8) ?[]const u8 {
    for (rel.assets) |asset| {
        if (std.mem.eql(u8, asset.name, name)) return asset.url;
    }
    return null;
}

/// A response body buffer that refuses bytes past `limit`: the write that would
/// cross it is not stored and fails with `over` set, so memory stays within
/// `limit` however large the response is. Set up in place with `start`, since
/// `writer` points into the struct.
const Capped = struct {
    body: std.Io.Writer.Allocating,
    writer: std.Io.Writer,
    limit: usize,
    over: bool = false,
    vtable: std.Io.Writer.VTable = .{ .drain = drain, .rebase = rebase },

    fn start(self: *Capped, allocator: std.mem.Allocator, limit: usize) !void {
        self.* = .{
            .body = try std.Io.Writer.Allocating.initCapacity(allocator, @min(limit, initial_body_capacity)),
            .writer = undefined,
            .limit = limit,
        };
        self.writer = .{ .vtable = &self.vtable, .buffer = &.{} };
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *Capped = @fieldParentPtr("writer", w);
        const n = std.Io.Writer.countSplat(data, splat);
        if (n > self.limit - self.body.written().len) {
            self.over = true;
            return error.WriteFailed;
        }
        for (data[0 .. data.len - 1]) |part| try self.body.writer.writeAll(part);
        try self.body.writer.splatBytesAll(data[data.len - 1], splat);
        return n;
    }

    /// There is no buffer of its own to make room in.
    fn rebase(_: *std.Io.Writer, _: usize, _: usize) std.Io.Writer.Error!void {}
};

fn say(io: std.Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [line_bytes]u8 = undefined;
    net.writeErr(io, std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch "microagent update: message too long\n");
}

fn fail(io: std.Io, comptime fmt: []const u8, args: anytype) u8 {
    say(io, "microagent update: " ++ fmt, args);
    return 1;
}

/// The outcome of a download that could not be started, waited for, or read.
/// These are the failures of this process rather than of the network, so the
/// line says which and the caller is not asked to retry: the run has no body to
/// give and no other endpoint to try, and a second attempt would print the same
/// line.
fn giveUp(io: std.Io, what: []const u8, err: anyerror) Outcome {
    _ = fail(io, "could not download {s} ({s})", .{ what, @errorName(err) });
    return .{ .body = null, .retry = false };
}

/// The reason a status is worth reading past the number. `not_found` is
/// answered differently for each of the three downloads, so the sentence names
/// what is not there rather than the release, which the caller already named:
/// a release that does not exist, an asset a release forgot, and a sidecar an
/// asset came without are three different mistakes.
///
/// A `429` is the API saying it is out of quota, so the token is what fixes it.
/// A `403` is not one thing: it is also the answer to a token without the
/// scope, or to a repository nobody may read, and telling a reader to set a
/// token there sends them after a fix that changes nothing. GitHub says which
/// of the two it is in the body, so `body` is read and the sentence is only
/// added when the refusal really is the rate limit.
fn statusHint(status: std.http.Status, body: []const u8) []const u8 {
    return switch (status) {
        .not_found => " (nothing published at that url)",
        .too_many_requests => " (rate limited; set GITHUB_TOKEN)",
        .forbidden => if (isRateLimited(body)) " (rate limited; set GITHUB_TOKEN)" else "",
        else => "",
    };
}

/// Whether a refusal body is the API's rate limit rather than a permission
/// refusal. GitHub words the first one "rate limit" in every spelling it uses,
/// and a body too short to hold a word or an empty one is not it: an empty
/// refusal is a server that said no, and a reader told to set a token they
/// already have set is worse than one told nothing.
fn isRateLimited(body: []const u8) bool {
    if (body.len == 0) return false;
    return std.ascii.indexOfIgnoreCase(body, "rate limit") != null;
}

/// How many times one download is attempted before it is given up on, and the
/// ceiling on the wait between two of them. The base and the doubling count
/// are the shared ones in `net`; only the cap is this path's, and it is
/// shorter than the agent run's because nobody is waiting on a turn here: a
/// person watching `microagent update` should be asked again while they are
/// still there.
const max_attempts: u32 = 3;
const max_backoff_ms: u64 = 30_000;

/// The shortest a download may take, and the rate a body has to arrive at for
/// the clock to be consulted at all.
///
/// `std.http` takes no deadline of its own, so a host that accepts the
/// connection and then stops answering holds this process open for as long as
/// it likes: the release page is a few kilobytes, so a floor is what it is
/// held to, and the asset's size is known before the request goes out, so the
/// rest of the budget is an allowance for a slow link. A link that slow is a
/// long download rather than a dead one, and a dead one is what the floor and
/// the rate together catch.
const fetch_timeout_floor_ms: u64 = 30_000;
const fetch_timeout_bytes_per_s: u64 = 2 * 1024 * 1024;

/// The deadline one download of at most `limit` bytes is given.
fn fetchTimeoutMs(limit: usize) u64 {
    // Saturating, because a `limit` the caller sets is a size and the product
    // below is in milliseconds of it: a `usize` near its own top times 1000
    // does not fit a `u64`, and the wrap lands the other side of the floor
    // below and gives a 512 MB body a thirty-second deadline. Every `limit` in
    // this file today is a constant no larger than `max_asset_bytes`, so the
    // saturating add is a promise rather than a behavior, and the promise is
    // what keeps it one when the next caller passes a size it read off the
    // wire.
    const for_the_body = (@as(u64, @intCast(limit)) *| std.time.ms_per_s) / fetch_timeout_bytes_per_s;
    return @max(fetch_timeout_floor_ms, for_the_body);
}

/// What one attempt made of a download: the body, or null with whether another
/// attempt could answer differently. Every failure has already been said by
/// the time this returns, so the loop above only decides and waits.
const Outcome = struct { body: ?[]u8, retry: bool };

/// One GET of `url`, body capped at `limit`, owned by `allocator`. The attempt
/// loop: a download whose failure is the network's rather than the request's
/// is tried again on the shared backoff, up to `max_attempts`, and every reason
/// is printed as it happens rather than only for the last one, so an operator
/// watching a slow network sees why each attempt was made.
fn fetch(
    io: std.Io,
    client: *std.http.Client,
    allocator: std.mem.Allocator,
    what: []const u8,
    url: []const u8,
    bearer: ?[]const u8,
    limit: usize,
) ?[]u8 {
    var attempt: u32 = 0;
    while (true) {
        attempt += 1;
        const outcome = fetchOnce(io, client, allocator, what, url, bearer, limit);
        if (outcome.body) |body| return body;
        if (!outcome.retry or attempt >= max_attempts) return null;
        const wait = net.retryBackoffMs(attempt, max_backoff_ms);
        say(io, "could not download {s}, trying again in {d}ms (attempt {d}/{d})", .{
            what, wait, attempt + 1, max_attempts,
        });
        // A wait that could not be taken is not a wait. Answering the same URL
        // the instant the sleep failed is the one thing the backoff exists to
        // prevent, and the line above has already promised a delay, so a sleep
        // that failed ends the download instead.
        std.Io.sleep(io, .{ .nanoseconds = wait *| std.time.ns_per_ms }, sleep_clock) catch |err| {
            _ = fail(io, "could not download {s}; the {d}ms wait before another attempt could not be taken ({s}), and it is not tried again at once", .{
                what, wait, @errorName(err),
            });
            return null;
        };
    }
}

/// The clock the waits between attempts are taken on. `.awake` rather than the
/// run's `.boot`: this path has no budget clock to keep in step with, and a
/// machine that suspended mid-wait is a machine whose operator is not watching.
const sleep_clock: std.Io.Clock = .awake;

/// One GET, raced against its own deadline. `client.fetch` has no timeout
/// option, so the clock is a task of its own and the exchange is the other:
/// whichever finishes first ends this, and the one that did not is cancelled
/// and joined before the body is read, so nothing writes into `capped` after
/// it is deinitialized.
fn fetchOnce(
    io: std.Io,
    client: *std.http.Client,
    allocator: std.mem.Allocator,
    what: []const u8,
    url: []const u8,
    bearer: ?[]const u8,
    limit: usize,
) Outcome {
    var capped: Capped = undefined;
    capped.start(allocator, limit) catch |err| return giveUp(io, what, err);
    defer capped.body.deinit();

    const Timed = union(enum) {
        answered: anyerror!std.http.Client.FetchResult,
        expired: std.Io.Cancelable!void,
    };
    var slots: [2]Timed = undefined;
    var select: std.Io.Select(Timed) = .init(io, &slots);
    defer select.cancelDiscard();
    const timeout_ms = fetchTimeoutMs(limit);
    select.concurrent(.answered, exchange, .{ client, &capped, url, bearer }) catch |err| return giveUp(io, what, err);
    select.concurrent(.expired, std.Io.Timeout.sleep, .{ net.durationMs(timeout_ms), io }) catch |err| return giveUp(io, what, err);
    const answer = select.await() catch |err| return giveUp(io, what, err);
    switch (answer) {
        .answered => |result| {
            const received = result catch |err| {
                const reason = if (capped.over) "PayloadTooLarge" else @errorName(err);
                _ = fail(io, "could not download {s} ({s})", .{ what, reason });
                return .{ .body = null, .retry = net.transientTransportError(err) };
            };
            if (@intFromEnum(received.status) >= 400) {
                _ = fail(io, "GitHub returned HTTP {d} for {s}{s}", .{ @intFromEnum(received.status), what, statusHint(received.status, capped.body.written()) });
                return .{ .body = null, .retry = net.retryableStatus(received.status) };
            }
        },
        .expired => {
            _ = fail(io, "could not download {s} (no answer within {d}ms)", .{ what, timeout_ms });
            return .{ .body = null, .retry = true };
        },
    }
    const body = capped.body.toOwnedSlice() catch |err| return giveUp(io, what, err);
    return .{ .body = body, .retry = false };
}

/// The one request, as a task the clock can race. The key travels in a
/// privileged header, so a redirect to another host never carries it.
fn exchange(
    client: *std.http.Client,
    capped: *Capped,
    url: []const u8,
    bearer: ?[]const u8,
) anyerror!std.http.Client.FetchResult {
    var auth: [1]std.http.Header = undefined;
    const auth_headers: []const std.http.Header = if (bearerFor(url, bearer)) |b| blk: {
        auth[0] = .{ .name = "Authorization", .value = b };
        break :blk &auth;
    } else &.{};
    return client.fetch(.{
        .location = .{ .url = url },
        .headers = .{ .user_agent = .{ .override = net.user_agent } },
        .privileged_headers = auth_headers,
        .response_writer = &capped.writer,
    });
}

/// Replaces the file at `exe` with `bytes`, mode 0755, through an atomic
/// rename. A symlink (or chain) is followed so the real binary changes and the
/// links stay. On error the file is unchanged.
fn replaceBinary(io: std.Io, exe: []const u8, bytes: []const u8) !void {
    var dir = try std.Io.Dir.cwd().openDir(io, std.fs.path.dirname(exe) orelse ".", .{});
    defer dir.close(io);
    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    var cur_buf: [2 * std.fs.max_path_bytes]u8 = undefined;
    var next_buf: [2 * std.fs.max_path_bytes]u8 = undefined;
    const target = try net.resolveSymlinkTarget(io, dir, std.fs.path.basename(exe), &link_buf, &cur_buf, &next_buf);

    var af = try dir.createFileAtomic(io, target, .{ .replace = true, .make_path = true, .permissions = exec_mode });
    defer af.deinit(io);
    try af.file.writeStreamingAll(io, bytes);
    try af.replace(io);
}

/// The one gate between a download and the running binary: `exe` is replaced only when `sidecar`
/// vouches for `asset` under `asset_name`. A refusal touches nothing.
fn installIfVerified(io: std.Io, exe: []const u8, asset: []const u8, sidecar: []const u8, asset_name: []const u8) !void {
    if (!checksumMatches(asset, sidecar, asset_name)) return error.ChecksumMismatch;
    try replaceBinary(io, exe, asset);
}

const usage_text =
    \\usage: microagent update [-c | --check]
    \\       microagent update -h | -V
    \\
    \\Downloads microagent-<tag>-<target> and its .sha256 sidecar from the latest
    \\GitHub release and replaces this binary only when the digest matches.
    \\
    \\  -c, --check    report the latest release, install nothing
    \\  -h, --help     this text ("microagent help update" too)
    \\  -V, --version  version
    \\
    \\environment:
    \\  GITHUB_TOKEN          bearer for api.github.com, past the anonymous rate limit
    \\  MICROAGENT_CA_BUNDLE  PEM file to trust instead of the system store,
    \\                        else SSL_CERT_FILE
    \\
    \\stdout is the release page URL with --check, else one "Installed <tag> to
    \\<path>" line (nothing when already current); notes go to stderr. Exit 0:
    \\checked, installed or current. Exit 1: failed. Exit 2: usage error, with the
    \\reason and this text on stderr. A misspelled flag is answered with the one
    \\it is closest to, so --chek says did you mean --check?
    \\
    \\examples:
    \\  microagent update --check       report the latest release, install nothing
    \\  GITHUB_TOKEN=... microagent update
    \\                                 install it, past the anonymous rate limit
    \\
;

const Parsed = union(enum) {
    install,
    check,
    help,
    version,
    unknown: []const u8,
};

/// `-h` and `-V` end the parse where they appear; any other word is unknown.
fn parseArgs(args: []const []const u8) Parsed {
    var parsed: Parsed = .install;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) return .help;
        if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-V")) return .version;
        if (std.mem.eql(u8, arg, "--check") or std.mem.eql(u8, arg, "-c")) {
            parsed = .check;
        } else {
            return .{ .unknown = arg };
        }
    }
    return parsed;
}

/// The three words this subcommand reads, and the two spellings of each, so a
/// misspelling is answered with the flag rather than left to the reader to find.
/// The list is written out rather than built from `parseArgs` for the reason the
/// agent's is: this is the one line a reader sees when they typed a flag wrong,
/// and a name spelled here has to be the name they should type. The test below
/// holds the two together.
const known_words = [_][]const u8{ "--check", "-c", "--help", "-h", "--version", "-V" };

/// A word this subcommand has no flag for, naming the one it is closest to when
/// there is one. Same rule and same wording as the agent's, so a reader who has
/// mistyped one flag does not have to learn two error messages.
fn unknownArgument(arena: std.mem.Allocator, arg: []const u8) []const u8 {
    const shown = quoteUntrusted(arena, arg);
    const near = net.nearestFlag(shown, &known_words) orelse
        return std.fmt.allocPrint(arena, "unknown argument '{s}'", .{shown}) catch "unknown argument";
    return std.fmt.allocPrint(arena, "unknown argument '{s}'; did you mean {s}?", .{ shown, near }) catch "unknown argument";
}

/// The subcommand's usage text on stdout, for `microagent update --help` and
/// for `microagent help update`, so both spellings print one text.
pub fn printUsage(io: std.Io) void {
    net.writeOut(io, usage_text) catch {};
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
    const check_only = switch (parseArgs(args)) {
        .help => {
            printUsage(io);
            return 0;
        },
        .version => {
            net.writeOut(io, tool_name ++ " " ++ version ++ "\n") catch {};
            return 0;
        },
        .unknown => |arg| {
            say(io, "microagent update: {s}", .{unknownArgument(arena, arg)});
            net.writeErr(io, usage_text);
            return 2;
        },
        .check => true,
        .install => false,
    };

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    net.loadCaBundle(&client, io, gpa, net.caBundlePath(env), arena);
    const bearer = githubBearer(arena, env) catch
        return fail(io, "the GITHUB_TOKEN could not be held for the request; the release is fetched anonymously", .{});

    const body = fetch(io, &client, arena, "the latest release of " ++ default_repo, release_api_url, bearer, max_api_bytes) orelse return 1;
    const rel = parseRelease(arena, body) catch |err|
        return fail(io, "the latest release of " ++ default_repo ++ " could not be read ({s})", .{@errorName(err)});
    if (!trustedGithubUrl(rel.page)) return fail(io, "refusing to install unverified binary", .{});

    const tag = quoteUntrusted(arena, rel.tag);
    const order = compareVersions(version, rel.tag);
    const current = sameRelease(version, rel.tag);
    // A tag that is not a version triple cannot be ordered against the running
    // build, so the message above says so and nothing is installed from it: an
    // unversioned asset published under such a tag is not a release, and a run
    // that replaced the binary with it said the running build was older.
    const tag_is_version = parseVersion(rel.tag) != null;
    // `compareVersions` reads a missing component as 0, so `0.1` and `v0.1.0`
    // are the same release spelled two ways and a build suffix a tag does not
    // carry compares equal to the triple. Installing over either would download
    // the bytes already running, so those end here with the equal spelling does.
    // It is separate from `current` because that one compares the two names
    // themselves, and a name `parseVersion` cannot read reaches `.eq` without
    // anything to say about the release but that it could not be compared.
    const same_version = order == .eq and parseVersion(version) != null and parseVersion(rel.tag) != null;
    switch (order) {
        .eq => if (current or same_version)
            say(io, "{s} {s} is current (latest release: {s})", .{ tool_name, version, tag })
        else
            say(io, "{s} {s} is not the latest release ({s}), which is not a version this run can compare against", .{ tool_name, version, tag }),
        .gt => say(io, "{s} is newer than the latest release ({s}); nothing to install", .{ version, tag }),
        .lt => say(io, "New release: {s} (running {s})", .{ tag, version }),
    }

    if (check_only or current or same_version or order == .gt) {
        if (check_only) writeLine(io, arena, quoteUntrusted(arena, rel.page)) catch |err|
            return fail(io, "could not write the release page to stdout ({s})", .{@errorName(err)});
        return 0;
    }
    if (!tag_is_version) return 0;

    const asset_name = assetName(arena, rel.tag, builtin.cpu.arch, builtin.os.tag) catch
        return fail(io, "out of memory", .{});
    const side_name = std.fmt.allocPrint(arena, "{s}.sha256", .{asset_name}) catch
        return fail(io, "out of memory", .{});
    const shown_asset = quoteUntrusted(arena, asset_name);

    const asset_url = assetUrl(rel, asset_name) orelse
        return fail(io, "missing release asset {s}; the binary was not replaced", .{shown_asset});
    const side_url = assetUrl(rel, side_name) orelse
        return fail(io, "missing checksum sidecar for {s}; the binary was not replaced", .{shown_asset});
    if (!trustedGithubUrl(asset_url) or !trustedGithubUrl(side_url))
        return fail(io, "refusing to install unverified binary", .{});

    // The small sidecar first: a release without a usable one costs no asset download.
    const side_what = std.fmt.allocPrint(arena, "the checksum sidecar for {s}", .{shown_asset}) catch
        return fail(io, "out of memory", .{});
    const sidecar = fetch(io, &client, arena, side_what, side_url, bearer, max_sidecar_bytes) orelse return 1;
    const asset = fetch(io, &client, gpa, shown_asset, asset_url, bearer, max_asset_bytes) orelse return 1;
    defer gpa.free(asset);

    const exe = std.process.executablePathAlloc(io, arena) catch |err|
        return fail(io, "could not locate the running binary ({s})", .{@errorName(err)});
    const shown_exe = chat.safeTextAll(arena, exe);
    installIfVerified(io, exe, asset, sidecar, asset_name) catch |err| return switch (err) {
        error.ChecksumMismatch => fail(io, "checksum mismatch; refusing to install unverified binary", .{}),
        else => fail(io, "could not replace {s} ({s}); the binary was not replaced", .{ shown_exe, @errorName(err) }),
    };
    const line = std.fmt.allocPrint(arena, "Installed {s} to {s}", .{ tag, shown_exe }) catch
        return fail(io, "{s} was installed", .{shown_exe});
    writeLine(io, arena, line) catch |err|
        return fail(io, "{s} was installed, but the install line could not be written to stdout ({s})", .{ shown_exe, @errorName(err) });
    return 0;
}

fn writeLine(io: std.Io, arena: std.mem.Allocator, line: []const u8) !void {
    try net.writeOut(io, try std.fmt.allocPrint(arena, "{s}\n", .{line}));
}

// ── Tests ───────────────────────────────────────────────────────────────────

const abc_sha = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";
const asset_base = "microagent-v0.1.0-x86_64-linux-musl";

test "update: a v-prefixed tag equals the running version exactly" {
    try std.testing.expect(sameRelease("0.1.0", "v0.1.0"));
    try std.testing.expect(sameRelease("v0.1.0", "0.1.0"));
    try std.testing.expect(sameRelease("0.1.10", "v0.1.10"));
    try std.testing.expect(!sameRelease("0.1.0", "v0.1.0.1"));
    try std.testing.expect(!sameRelease("0.1.1", "v0.1.10"));
    try std.testing.expect(!sameRelease("0.1.0", "vv0.1.0"));
}

test "update: asset names are the four the release matrix publishes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectEqualStrings("microagent-v0.1.0-x86_64-linux-musl", try assetName(arena, "v0.1.0", .x86_64, .linux));
    try std.testing.expectEqualStrings("microagent-v0.1.0-aarch64-linux-musl", try assetName(arena, "v0.1.0", .aarch64, .linux));
    try std.testing.expectEqualStrings("microagent-v0.1.0-x86_64-macos", try assetName(arena, "v0.1.0", .x86_64, .macos));
    try std.testing.expectEqualStrings("microagent-v0.1.0-aarch64-macos", try assetName(arena, "v0.1.0", .aarch64, .macos));
}

test "update: only a github host is fetched from, however the url spells it" {
    try std.testing.expect(trustedGithubUrl("https://github.com/maci0/microagent/releases/tag/v0.1.0"));
    try std.testing.expect(trustedGithubUrl("https://api.github.com/repos/maci0/microagent/releases/latest"));
    try std.testing.expect(trustedGithubUrl("https://release-assets.githubusercontent.com/microagent"));
    try std.testing.expect(trustedGithubUrl("HTTPS://GITHUB.COM/maci0/microagent"));
    try std.testing.expect(trustedGithubUrl("https://Release-Assets.GitHubUserContent.com/x"));
    try std.testing.expect(trustedGithubUrl("https://codeload.github.com/x"));
    try std.testing.expect(trustedGithubUrl("https://github.com:443/maci0/microagent"));
    try std.testing.expect(trustedGithubUrl("https://api.github.com:8443/x"));

    // The bare githubusercontent.com is not trusted, only its subdomains.
    for ([_][]const u8{
        "https://githubusercontent.com/x",
        "https://evil.githubusercontent.com.evil.com/x",
        "https://github.com.evil.com/maci0/microagent",
        "https://objects.githubusercontent.com.evil.com/x",
        "https://notgithub.com/x",
        "https://github.co/x",
        "https://example.com/microagent",
        "http://github.com/x",
        "//github.com/x",
        "github.com/x",
        "",
        "https://",
        "https:///maci0/microagent",
        "https://github.com:/x",
        "https://github.com:443abc/x",
        "https://github.com:443@evil.com/x",
        "https://user@github.com/x",
        "https://user:pass@github.com/x",
        "https://github.com\\@evil.com/x",
        "https://github.com x",
        "https://github.com\tx",
        "https://github.com\n/x",
        "https://github.com/x\r\nHost: evil.example",
        "https://github.com/x\nHost: evil.example",
    }) |url| {
        if (trustedGithubUrl(url)) {
            std.debug.print("trusted an untrusted url: {s}\n", .{url});
            return error.TestUnexpectedResult;
        }
    }

    // A host at the DNS ceiling is read, one byte past it is refused.
    const suffix = ".github.com";
    var host: [max_host_len + 1]u8 = undefined;
    @memset(host[0 .. max_host_len - suffix.len], 'a');
    @memcpy(host[max_host_len - suffix.len .. max_host_len], suffix);
    var url_buf: [max_host_len + 16]u8 = undefined;
    try std.testing.expect(trustedGithubUrl(try std.fmt.bufPrint(&url_buf, "https://{s}/x", .{host[0..max_host_len]})));
    host[max_host_len] = 'a';
    try std.testing.expect(!trustedGithubUrl(try std.fmt.bufPrint(&url_buf, "https://{s}/x", .{host[0 .. max_host_len + 1]})));
}

// The trailing labels of a host, read one at a time rather than matched as a
// suffix, so the oracle the harness below uses is a second reading of "a github
// host" and not the one `hostTrusted` happens to implement. A host the install
// accepts is `github.com` itself, or a name in front of `github.com` or
// `githubusercontent.com`: the bare `githubusercontent.com` is not one of
// them, which is the case a suffix match is most likely to lose.
fn githubHostByLabels(host: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(host, "github.com")) return true;
    // `*.github.com`: at least one label in front of `github` `com`.
    // `*.githubusercontent.com`: at least one in front of `githubusercontent` `com`.
    var labels = std.mem.splitBackwardsScalar(u8, host, '.');
    const last = labels.next() orelse return false;
    if (!std.ascii.eqlIgnoreCase(last, "com")) return false;
    const owner = labels.next() orelse return false;
    if (std.ascii.eqlIgnoreCase(owner, "github")) return labels.next() != null;
    if (!std.ascii.eqlIgnoreCase(owner, "githubusercontent")) return false;
    return labels.next() != null;
}

// The url a release body spells is the second half of the trust chain:
// `parseRelease` reads `browser_download_url` and `html_url` out of a body from
// the API, and what those bytes say is what decides whether a binary is
// downloaded and installed over the running one. A host check that answers
// true for a url the HTTP client would send somewhere else is the one bug in
// this file that ends with somebody else's binary running as this one, so the
// check is fuzzed rather than left to the table above: that table can only hold
// the spellings somebody already thought of, and this reads a host out of a
// string, where a string has more spellings than a list of them.
//
// The assertions are the properties the install path relies on, and each is one
// a crash would not show. `std.testing.fuzz` runs this corpus on every `zig
// build test`, and through the fuzzer's mutations when the test binary is built
// in fuzz mode.
const trusted_url_corpus = [_][]const u8{
    "",
    "https://github.com/maci0/microagent/releases/tag/v0.1.0",
    "https://api.github.com/repos/maci0/microagent/releases/latest",
    "https://release-assets.githubusercontent.com/microagent",
    "https://objects.githubusercontent.com/x",
    "https://codeload.github.com/x",
    "HTTPS://GITHUB.COM/maci0/microagent",
    "HttPs://GitHub.CoM/x",
    "https://github.com:443/maci0/microagent",
    "https://api.github.com:8443/x",
    "https://github.com:/x",
    "https://github.com:443abc/x",
    "https://github.com:0/x",
    "https://github.com:65535/x",
    "https://github.com:65536/x",
    "https://github.com:99999999999999999999/x",
    "https://github.com.evil.com/x",
    "https://evil.githubusercontent.com.evil.com/x",
    "https://githubusercontent.com/x",
    "https://notgithub.com/x",
    "https://github.co/x",
    "https://github.commmm/x",
    "https://xgithub.com/x",
    "https://github.com\\@evil.com/x",
    "https://github.com\\.evil.com/x",
    "https://user@github.com/x",
    "https://user:pass@github.com/x",
    "https://user@api.github.com/x",
    "https://user@release-assets.githubusercontent.com/x",
    "https://x@github.com:443@evil.com/x",
    "https://@github.com/x",
    "https://github.com@evil.com/x",
    "https://github.com x",
    "https://github.com\tx",
    "https://github.com\n/x",
    "https://github.com/x\r\nHost: evil.example",
    "https://github.com/x\nHost: evil.example",
    "https://\ngithub.com/x",
    "https://github.com\r/x",
    "http://github.com/x",
    "//github.com/x",
    "github.com/x",
    "/github.com/x",
    "https:/github.com/x",
    "https:github.com/x",
    "https//github.com/x",
    "httpsx://github.com/x",
    "://github.com/x",
    "https://",
    "https:///maci0/microagent",
    "https://github.com",
    "https://github.com/",
    "https://github.com?x=1",
    "https://github.com#f",
    "https://github.com:443?x=1",
    "https://.github.com/x",
    "https://github.com./x",
    "https://GITHUB.COM/x",
    "https://github.com/%2e%2e/x",
    "https://github.com/../x",
    "https://\x00github.com/x",
    "https://github.com\x00/x",
    "https://github.com/日/x",
    "https://xn--github.com/x",
    "https://github.com." ++ "a" ** 300,
    "https://" ++ "a" ** 300 ++ ".github.com/x",
};

test "update: fuzz: a url is trusted only for the host and the scheme it names" {
    try std.testing.fuzz({}, fuzzTrustedUrl, .{ .corpus = &trusted_url_corpus });

    // Both answers are reachable, or every assertion below is vacuous: a
    // harness whose seeds all take one branch proves nothing about the other.
    try std.testing.expect(trustedGithubUrl("https://github.com/maci0/microagent/releases/tag/v0.1.0"));
    try std.testing.expect(!trustedGithubUrl("https://github.com.evil.com/x"));
}

fn fuzzTrustedUrl(_: void, smith: *std.testing.Smith) !void {
    var raw: [2 * 1024]u8 = undefined;
    const url: []const u8 = if (smith.in) |seed| seed else raw[0..smith.slice(&raw)];

    const trusted = trustedGithubUrl(url);

    // The answer is the same every time, because the check reads only its
    // argument: one run asks about three urls out of one release body, and a
    // check that answered differently for two of them would be one holding
    // state between them.
    try std.testing.expectEqual(trusted, trustedGithubUrl(url));

    if (!trusted) return;

    // A trusted url is sent as a request line and as header values, so no byte
    // of one ends a line: the same rule the API key and an MCP server's key are
    // held to, on the one url an attacker writes.
    try std.testing.expect(!net.hasHeaderControlBytes(url));
    try std.testing.expect(std.ascii.startsWithIgnoreCase(url, "https://"));

    // The host the check read is the host the request will name, and it has to
    // be a host the answer is allowed to name. This is the assertion a bypass
    // breaks, and its oracle is `githubHostByLabels` above rather than
    // `hostTrusted`, so two copies of the same mistake cannot agree.
    const rest = url["https://".len..];
    const slash = std.mem.findScalar(u8, rest, '/') orelse rest.len;
    const authority = rest[0..slash];
    var host = authority;
    if (std.mem.findScalar(u8, host, ':')) |colon| host = host[0..colon];
    if (!githubHostByLabels(host)) {
        std.debug.print("\ntrusted a url whose host is '{s}': {s}\n", .{ host, url });
        return error.TestUnexpectedResult;
    }

    // The userinfo and the backslash are the two ways a url names one host and
    // reaches another, so what is left before the host is `https://` and
    // nothing else.
    try std.testing.expect(std.mem.indexOfAny(u8, authority, "@\\ \t\r\n") == null);
    // A port is digits, and the request names it after the host: a trusted url
    // whose port is not a number is one this check and the HTTP client read
    // differently.
    if (std.mem.findScalar(u8, authority, ':')) |colon| {
        const port = authority[colon + 1 ..];
        try std.testing.expect(port.len > 0);
        for (port) |c| try std.testing.expect(std.ascii.isDigit(c));
    }
}

test "update: the command line reads --check, -h and -V, and refuses the rest" {
    try std.testing.expect(parseArgs(&.{}) == .install);
    try std.testing.expect(parseArgs(&.{"--check"}) == .check);
    try std.testing.expect(parseArgs(&.{ "-c", "--check" }) == .check);
    try std.testing.expect(parseArgs(&.{ "--check", "--help" }) == .help);
    try std.testing.expect(parseArgs(&.{"-h"}) == .help);
    try std.testing.expect(parseArgs(&.{"-V"}) == .version);
    try std.testing.expect(parseArgs(&.{"--version"}) == .version);
    for ([_][]const []const u8{ &.{"--nope"}, &.{"help"}, &.{"--repo=you/x"}, &.{"--"}, &.{ "--check", "extra" } }) |args| {
        try std.testing.expect(parseArgs(args) == .unknown);
    }
    try std.testing.expectEqualStrings("--nope", parseArgs(&.{ "--check", "--nope" }).unknown);
}

test "update: a misspelled flag names the one it is closest to" {
    // The same rule and the same wording as the agent's, so a reader who has
    // mistyped one flag does not have to learn two error messages. A word far
    // from every flag is left without a suggestion: `--nope` is three
    // substitutions from `--check` and naming it sends a reader nowhere.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqualStrings("unknown argument '--chek'; did you mean --check?", unknownArgument(arena, "--chek"));
    try std.testing.expectEqualStrings("unknown argument '--hep'; did you mean --help?", unknownArgument(arena, "--hep"));
    // A short flag is one or two letters, so there is no misspelling of one far
    // enough from it to be worth naming, and `-chek` gets no suggestion rather
    // than the `--check` whose letters it is missing.
    try std.testing.expectEqualStrings("unknown argument '-chek'", unknownArgument(arena, "-chek"));
    try std.testing.expectEqualStrings("unknown argument '--nope'", unknownArgument(arena, "--nope"));
    try std.testing.expectEqualStrings("unknown argument 'x'", unknownArgument(arena, "x"));
}

// The drift this names is a flag added to `parseArgs` and not to `known_words`,
// so the check is driven from the parser rather than from the list: iterating
// `known_words` against a hand copy of itself can only fail if the list is
// edited, and passes untouched for the edit it exists to catch. The parser's
// own flag literals are read out of its source at compile time, so a seventh
// flag is compared against a list that did not grow.
test "update: every flag the parser reads is one a misspelling can be answered from" {
    const source = @embedFile("update.zig");
    const start = std.mem.indexOf(u8, source, "fn parseArgs(") orelse return error.TestUnexpectedResult;
    const body = source[start..];
    const end = std.mem.indexOf(u8, body, "\n}\n") orelse return error.TestUnexpectedResult;
    const parser = body[0..end];

    var read: usize = 0;
    var flags_read: usize = 0;
    while (std.mem.indexOfPos(u8, parser, read, "\"")) |open| {
        const close = std.mem.indexOfPos(u8, parser, open + 1, "\"") orelse break;
        const word = parser[open + 1 .. close];
        read = close + 1;
        if (word.len < 2 or word[0] != '-') continue;
        var listed = false;
        for (known_words) |known| {
            if (std.mem.eql(u8, known, word)) listed = true;
        }
        if (!listed) {
            std.debug.print("\n{s} is a flag parseArgs reads and known_words does not carry\n", .{word});
            return error.TestUnexpectedResult;
        }
        flags_read += 1;
    }
    // The scan found something, or it found nothing and the guard is vacuous:
    // the parser's body is six literals and this count is what proves the
    // window above is the parser's and not an empty slice of the file.
    try std.testing.expectEqual(@as(usize, 6), flags_read);

    // The other direction: a word the parser answers for that a reader would
    // never be told about is a word `known_words` invented.
    for (known_words) |word| {
        const parsed = parseArgs(&.{word});
        if (parsed == .unknown) {
            std.debug.print("\n{s} is in known_words and no flag of parseArgs reads it\n", .{word});
            return error.TestUnexpectedResult;
        }
    }
}

const args_corpus = [_][]const u8{
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
    "--check extra",
    "--repo you/microagent",
    "--nope",
    "\u{0}\u{1}\u{7f}",
    "--\u{65e5}\u{8a00}",
    "\xff\xfe",
    "a" ** 200,
};

/// Whether the first word that is not a check flag is one of the two spellings
/// of the flag asked for. `parseArgs` returns at that word, so a run that
/// answers `.help` or `.version` has one, and it is the one that decided it.
fn isFirstNonCheck(words: []const []const u8, short: []const u8, long: []const u8) bool {
    for (words) |w| {
        if (std.mem.eql(u8, w, "--check") or std.mem.eql(u8, w, "-c")) continue;
        return std.mem.eql(u8, w, short) or std.mem.eql(u8, w, long);
    }
    return false;
}

test "update: fuzz: a fuzzed command line is read as flags or quoted as unknown" {
    try std.testing.fuzz({}, fuzzArgs, .{ .corpus = &args_corpus });
}

fn fuzzArgs(_: void, smith: *std.testing.Smith) !void {
    var raw: [8 * 1024]u8 = undefined;
    const text = if (smith.in) |seed| seed else raw[0..smith.slice(&raw)];
    // One word per run of blanks, up to the array: a parser is handed arguments
    // rather than one opaque word.
    var argv: [64][]const u8 = undefined;
    var split = std.mem.tokenizeAny(u8, text, " \t\n");
    var n: usize = 0;
    while (n < argv.len) : (n += 1) argv[n] = split.next() orelse break;
    const words = argv[0..n];

    switch (parseArgs(words)) {
        .install => try std.testing.expectEqual(@as(usize, 0), words.len),
        .check => for (words) |w| {
            try std.testing.expect(std.mem.eql(u8, w, "-c") or std.mem.eql(u8, w, "--check"));
        },
        // A help or a version is reached only by the exact word that asks for
        // it: the parser returns at the first word that is not a check flag,
        // and that word has to be the one asking. A parser answering either to
        // arbitrary bytes would pass without these.
        .help => try std.testing.expect(isFirstNonCheck(words, "-h", "--help")),
        .version => try std.testing.expect(isFirstNonCheck(words, "-V", "--version")),
        .unknown => |arg| {
            var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena_state.deinit();
            const quoted = quoteUntrusted(arena_state.allocator(), arg);
            try std.testing.expect(quoted.len <= net.quoted_value_bytes);
            try std.testing.expect(std.unicode.utf8ValidateSlice(quoted));
            for (quoted) |c| try std.testing.expect(c >= 0x20 and c != 0x7f);
        },
    }
}

test "update: a build ahead of the latest release is not downgraded" {
    try std.testing.expectEqual(std.math.Order.lt, compareVersions("0.1.0", "v0.2.0"));
    try std.testing.expectEqual(std.math.Order.gt, compareVersions("0.2.0", "v0.1.1"));
    try std.testing.expectEqual(std.math.Order.gt, compareVersions("1.0.0", "v0.9.9"));
    try std.testing.expectEqual(std.math.Order.eq, compareVersions("0.1.0", "v0.1.0"));
    try std.testing.expectEqual(std.math.Order.eq, compareVersions("0.1", "v0.1.0"));
    // A pre-release sorts below its own triple, dotted suffixes included.
    try std.testing.expectEqual(std.math.Order.gt, compareVersions("0.2.0-rc1", "v0.1.1"));
    try std.testing.expectEqual(std.math.Order.lt, compareVersions("0.1.0", "v0.2.0-rc1"));
    try std.testing.expectEqual(std.math.Order.gt, compareVersions("0.2.0", "v0.2.0-rc1"));
    try std.testing.expectEqual(std.math.Order.lt, compareVersions("v0.2.0-rc1", "0.2.0"));
    try std.testing.expectEqual(std.math.Order.gt, compareVersions("0.3.0", "v0.2.0-rc.1"));
    try std.testing.expectEqual(std.math.Order.gt, compareVersions("0.2.0", "v0.2.0-rc.1"));
    try std.testing.expectEqual(std.math.Order.eq, compareVersions("0.2.0", "v0.2.0+build.1"));
    // A tag that is not a version carries no order.
    try std.testing.expectEqual(std.math.Order.eq, compareVersions("0.2.0", "nightly"));
    try std.testing.expectEqual(std.math.Order.eq, compareVersions("0.2.0", "v0.1.x"));
    try std.testing.expectEqual(std.math.Order.eq, compareVersions("0.2.0", "v1.2.3.4"));
}

// The spellings a GitHub tag really carries, plus the ones that are not a
// version at all: the `v` prefix, a missing component, a `-pre` and a `+build`
// suffix, four components, a component too large for `u64`, and the names a
// release is tagged with instead. `std.testing.fuzz` runs this corpus on every
// `zig build test`, and through the fuzzer's mutations when the test binary is
// built in fuzz mode.
const version_corpus = [_][]const u8{
    "0.1.0\x00v0.2.0",
    "1.0.0\x00v0.9.9",
    "0.2.0-rc1\x00v0.1.1",
    "0.2.0\x00v0.2.0-rc1",
    "0.2.0\x00v0.2.0+build.1",
    "0.1\x00v0.1.0",
    "0.2.0\x00nightly",
    "0.2.0\x00v1.2.3.4",
    "0.2.0\x00v0.1.x",
    "0.2.0\x00v-",
    "0.2.0\x00v..",
    "0.2.0\x00v1.2.99999999999999999999999",
    "0.2.0\x00v99999999999999999999999999999.0.0",
    "0.2.0\x00v18446744073709551616.0.0",
    "0.2.0\x00v18446744073709551615.0.0",
    "0.2.0\x00v1.2.3-",
    "0.2.0\x00v+",
    "0.2.0\x00v1.2.3+",
    "vv1.2.3\x00v1.2.3",
    "\x00",
    "v1.0.0\x00v1.0.0-rc",
    "1.2.3\x00v2.0.0-alpha.1+build.7",
};

test "update: fuzz: a tag and a running version order the way their triples read" {
    try std.testing.fuzz({}, fuzzVersion, .{ .corpus = &version_corpus });
}

fn flip(o: std.math.Order) std.math.Order {
    return switch (o) {
        .lt => .gt,
        .eq => .eq,
        .gt => .lt,
    };
}

/// The running build against a tag the GitHub API chose, which is the one
/// decision that decides whether a binary is replaced. The assertions are the
/// order the caller relies on rather than a crash: a comparison that is not
/// antisymmetric, or that reports a version as below itself, would replace a
/// good binary with an old one or hold one forever, and neither shows up as a
/// failure anywhere else.
fn fuzzVersion(_: void, smith: *std.testing.Smith) !void {
    var raw: [512]u8 = undefined;
    const bytes: []const u8 = if (smith.in) |seed| seed else raw[0..smith.slice(&raw)];
    // Two versions from one seed, so a mutation reaches either side. A nul
    // separates them because no version reads it and it cannot appear inside
    // one; a seed with none is one version against itself.
    const nul = std.mem.indexOfScalar(u8, bytes, 0) orelse bytes.len;
    const running = bytes[0..nul];
    const tag = bytes[@min(nul + 1, bytes.len)..];

    const order = compareVersions(running, tag);
    // Antisymmetry: the same pair read the other way round is the other order,
    // and the same pair read the same way is the same answer.
    const flipped = compareVersions(tag, running);
    try std.testing.expectEqual(order, flip(flipped));
    try std.testing.expectEqual(order, compareVersions(running, tag));
    // Nothing is below itself, whatever it spells. This is the one that a
    // pre-release flag read off the wrong byte of the tag would break.
    try std.testing.expectEqual(std.math.Order.eq, compareVersions(running, running));
    try std.testing.expectEqual(std.math.Order.eq, compareVersions(tag, tag));

    const a = parseVersion(running) orelse return;
    const b = parseVersion(tag) orelse return;
    // Two versions that agree on every component and on whether they are a
    // pre-release are the same release, so the dotted suffixes and the build
    // metadata cannot decide anything.
    if (std.mem.eql(u64, &a.triple, &b.triple) and a.prerelease == b.prerelease)
        try std.testing.expectEqual(std.math.Order.eq, order);
    // The order follows the first component that differs and nothing after it,
    // which is what keeps a long suffix from reordering a pair the triple
    // already decided.
    for (a.triple, b.triple) |an, bn| {
        if (an == bn) continue;
        try std.testing.expectEqual(if (an < bn) std.math.Order.lt else std.math.Order.gt, order);
        break;
    }
    // The pre-release flag is read off the spelling and not off a second
    // parse of the same bytes, which is the only way a wrong `-`/`+` cut, or a
    // flag that never got set, shows up here rather than as a release that
    // replaces itself forever.
    try std.testing.expectEqual(spelledPrerelease(running), a.prerelease);
    try std.testing.expectEqual(spelledPrerelease(tag), b.prerelease);
    // And a pre-release sorts below the final build carrying the same triple.
    if (a.prerelease) {
        var buf: [64]u8 = undefined;
        const final = try std.fmt.bufPrint(&buf, "{d}.{d}.{d}", .{ a.triple[0], a.triple[1], a.triple[2] });
        try std.testing.expectEqual(std.math.Order.lt, compareVersions(running, final));
    }
    // A `+build` suffix is not a pre-release, so a build tagged with one is the
    // same release as the same triple without it, and the suffix cannot demote a
    // final build the way a `-` suffix does.
    const plus_at = std.mem.indexOfScalar(u8, bareVersion(running), '+') orelse return;
    const without = bareVersion(running)[0..plus_at];
    const stripped = parseVersion(without) orelse return;
    try std.testing.expectEqual(stripped.prerelease, a.prerelease);
    try std.testing.expectEqual(std.math.Order.eq, compareVersions(running, without));
}

/// The spelling that marks a pre-release: a `-` that ends the triple, before
/// any `+`. Whether `parseVersion` agrees is the caller's reading of the same
/// bytes, so the harness checks it against this and not against itself.
fn spelledPrerelease(v: []const u8) bool {
    const bare = bareVersion(v);
    const dash = std.mem.indexOfScalar(u8, bare, '-') orelse return false;
    const plus = std.mem.indexOfScalar(u8, bare, '+') orelse return true;
    return dash < plus;
}

test "update: the GitHub token is trimmed, and an empty one is no token" {
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const arena = state.allocator();

    try std.testing.expect(try githubBearer(arena, &env) == null);
    try env.put("GITHUB_TOKEN", "ghp_abc123\n");
    try std.testing.expectEqualStrings("Bearer ghp_abc123", (try githubBearer(arena, &env)).?);
    try env.put("GITHUB_TOKEN", "  ");
    try std.testing.expect(try githubBearer(arena, &env) == null);
}

test "update: only the releases API carries the GitHub token" {
    const bearer: ?[]const u8 = "Bearer ghp_abc123";
    try std.testing.expectEqualStrings("Bearer ghp_abc123", bearerFor(release_api_url, bearer).?);
    try std.testing.expectEqualStrings("Bearer ghp_abc123", bearerFor("HTTPS://API.GITHUB.COM/repos/o/r", bearer).?);
    try std.testing.expect(bearerFor("https://github.com/maci0/microagent/releases/download/v0.2.0/" ++ asset_base, bearer) == null);
    try std.testing.expect(bearerFor("https://release-assets.githubusercontent.com/x", bearer) == null);
    try std.testing.expect(bearerFor("https://api.github.com.evil.com/repos/o/r", bearer) == null);
    try std.testing.expect(bearerFor("https://user@api.github.com/repos/o/r", bearer) == null);
    try std.testing.expect(bearerFor("https://api.github.com", bearer) == null);
    try std.testing.expect(bearerFor(release_api_url, null) == null);
}

// The second half of the same trust chain, and the one that costs a secret
// rather than a binary: `bearerFor` decides whether a request carries the
// `GITHUB_TOKEN`, and the url it reads is the one a release body or a redirect
// wrote. A prefix check that answers true for a host the request will not go
// to is a token handed to whoever asked for it, so the check is fuzzed for the
// same reason `trustedGithubUrl` is and against the same oracle: the answer has
// to be the one a reader of the url would give, and not the one this check's
// own prefix literal happens to produce.
//
// The oracle is spelled out here rather than taken from the check. A url that
// is `https` and whose host is exactly `api.github.com` is the only one that
// may carry the token, so the harness reads the host out of the url the way the
// install does and compares. `std.testing.fuzz` runs this corpus on every `zig
// build test`, and through the fuzzer's mutations when the test binary is built
// in fuzz mode.
const bearer_url_corpus = [_][]const u8{
    "",
    "https://api.github.com/repos/o/r/releases/latest",
    "https://api.github.com/",
    "https://api.github.com",
    "HTTPS://API.GITHUB.COM/repos/o/r",
    "HttPs://Api.GitHub.Com/x",
    "https://API.GITHUB.COM/x",
    "https://api.github.com:443/x",
    "https://api.github.com:8443/x",
    "https://api.github.com./x",
    "https://api.github.com.evil.com/x",
    "https://api.github.com@evil.com/x",
    "https://user@api.github.com/x",
    "https://api.github.com\\@evil.com/x",
    "https://api.github.comevil.com/x",
    "https://evilapi.github.com/x",
    "https://x.api.github.com/x",
    "https://api.github.com\n/x",
    "https://api.github.com x",
    "https://api.github.com\t/x",
    "https://api.github.com\x00/x",
    "https://api.github.com/%0d%0aHost:evil",
    "http://api.github.com/x",
    "//api.github.com/x",
    "api.github.com/x",
    "https:/api.github.com/x",
    "https://github.com/maci0/microagent/releases/download/v0.2.0/x",
    "https://release-assets.githubusercontent.com/x",
    "https://codeload.github.com/x",
    "https://objects.githubusercontent.com/x",
    "https://api.github.com",
    "xhttps://api.github.com/x",
    " https://api.github.com/x",
    "https://api.github.com//x",
    "https://api.github.com/../x",
    "https://api.github.com/日",
};

test "update: fuzz: the token rides only to the api host, whatever the url spells" {
    try std.testing.fuzz({}, fuzzBearerFor, .{ .corpus = &bearer_url_corpus });

    // Both answers are reachable, or the assertions below prove nothing.
    try std.testing.expectEqualStrings("Bearer t", bearerFor("https://api.github.com/x", "Bearer t").?);
    try std.testing.expect(bearerFor("https://github.com/x", "Bearer t") == null);
}

fn fuzzBearerFor(_: void, smith: *std.testing.Smith) !void {
    var raw: [2 * 1024]u8 = undefined;
    const url: []const u8 = if (smith.in) |seed| seed else raw[0..smith.slice(&raw)];
    const bearer: ?[]const u8 = "Bearer ghp_example";

    const got = bearerFor(url, bearer);

    // The answer reads only its arguments, so the same call twice is the same
    // answer, and no token is the answer however the url is spelled.
    try std.testing.expectEqual(got != null, bearerFor(url, bearer) != null);
    try std.testing.expect(bearerFor(url, null) == null);

    // The oracle: a url is the API's only when it is `https`, when the host
    // before the first `/` is exactly `api.github.com`, and when there is a `/`
    // at all. Read here from the bytes rather than from the check's own
    // literal, so the two cannot be the same reading of the same bug.
    const rest = if (std.ascii.startsWithIgnoreCase(url, "https://")) url["https://".len..] else "";
    const slash = std.mem.indexOfScalar(u8, rest, '/');
    const host = if (slash) |at| rest[0..at] else "";
    const is_api = std.ascii.eqlIgnoreCase(host, "api.github.com") and slash != null;
    const want = if (is_api) bearer else null;
    if (got != null or want != null) {
        try std.testing.expectEqual(want, got);
    }

    // Whatever it decided, the value it handed over is the caller's own token
    // and not a copy, an extension, or a url spliced into it: a bearer that is
    // not the one that went in is a token this path invented.
    if (got) |b| try std.testing.expectEqualStrings("Bearer ghp_example", b);
}

test "update: checksum line is the published hex, two spaces, and the basename" {
    const sidecar = abc_sha ++ "  " ++ asset_base ++ "\n";
    try std.testing.expect(checksumMatches("abc", sidecar, asset_base));
    try std.testing.expect(!checksumMatches("abd", sidecar, asset_base));
    try std.testing.expect(!checksumMatches("abc", sidecar, "other"));
    try std.testing.expect(!checksumMatches("abc", abc_sha ++ " " ++ asset_base, asset_base));

    // CRLF, no line ending and upper-case hex still match.
    try std.testing.expect(checksumMatches("abc", abc_sha ++ "  " ++ asset_base ++ "\r\n", asset_base));
    try std.testing.expect(checksumMatches("abc", abc_sha ++ "  " ++ asset_base, asset_base));
    var upper: [abc_sha.len]u8 = undefined;
    for (abc_sha, 0..) |c, i| upper[i] = std.ascii.toUpper(c);
    try std.testing.expect(checksumMatches("abc", upper ++ "  " ++ asset_base ++ "\n", asset_base));

    // An empty sidecar, a trailing word, a missing separator and a name that
    // is a prefix or extension of the asset's do not match.
    try std.testing.expect(!checksumMatches("abc", "", asset_base));
    try std.testing.expect(!checksumMatches("abc", abc_sha ++ "  " ++ asset_base ++ " extra\n", asset_base));
    try std.testing.expect(!checksumMatches("abc", abc_sha ++ asset_base ++ "\n", asset_base));
    try std.testing.expect(!checksumMatches("abc", sidecar, asset_base[0 .. asset_base.len - 1]));
    try std.testing.expect(!checksumMatches("abc", sidecar, "x" ++ asset_base));
}

test "update: a release lists its assets by name, and their urls are checked" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const body =
        \\{"tag_name":"v0.1.0","html_url":"https://github.com/maci0/microagent/releases/tag/v0.1.0","assets":[
        \\{"name":"microagent-v0.1.0-aarch64-macos","browser_download_url":"https://example.com/nope"},
        \\{"name":"microagent-v0.1.0-x86_64-linux-musl","browser_download_url":"https://github.com/maci0/microagent/releases/download/v0.1.0/microagent-v0.1.0-x86_64-linux-musl"}
        \\]}
    ;
    const rel = try parseRelease(arena, body);
    try std.testing.expectEqualStrings("v0.1.0", rel.tag);
    const name = try assetName(arena, rel.tag, .x86_64, .linux);
    try std.testing.expect(trustedGithubUrl(assetUrl(rel, name).?));
    try std.testing.expect(assetUrl(rel, "microagent-v0.1.0-no-such") == null);
    try std.testing.expect(!trustedGithubUrl(assetUrl(rel, "microagent-v0.1.0-aarch64-macos").?));
}

test "update: a malformed body and a failed allocation are not the same error" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectError(error.MalformedRelease, parseRelease(arena, "not json at all"));
    try std.testing.expectError(error.MalformedRelease, parseRelease(arena, "[]"));
    try std.testing.expectError(error.MalformedRelease, parseRelease(arena, "{\"tag_name\":\"v1\",\"html_url\":\"x\",\"assets\":3}"));

    var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, parseRelease(failing.allocator(), "{\"tag_name\":\"v1\"}"));
}

test "update: text from the network is quoted before it is printed" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A tag with ESC, BEL and a C1 control, read from a real release body.
    const hostile = "{\"tag_name\":\"v0.1.0\\u001b[2J\\u0007\\u009b31m\",\"html_url\":\"https://github.com/o/r\",\"assets\":[]}";
    const rel = try parseRelease(arena, hostile);
    try std.testing.expectEqualStrings("v0.1.0\x1b[2J\x07\u{009b}31m", rel.tag);
    try std.testing.expectEqualStrings("v0.1.0\\x1b[2J\\x07\\x9b31m", quoteUntrusted(arena, rel.tag));

    // Invalid UTF-8 becomes U+FFFD, and the cut lands on a whole character.
    try std.testing.expectEqualStrings("bad\\x1b[31m\u{fffd}", quoteUntrusted(arena, "bad\x1b[31m\xff"));
    try std.testing.expectEqualStrings("日" ** 26, quoteUntrusted(arena, "日" ** 40));
    try std.testing.expectEqualStrings("microagent", quoteUntrusted(arena, "microagent"));
}

test "update: a body over the cap is refused while it arrives" {
    var capped: Capped = undefined;
    try capped.start(std.testing.allocator, 8);
    defer capped.body.deinit();

    try capped.writer.writeAll("short");
    try std.testing.expect(!capped.over);
    // A zero splat writes no copy of the pattern; one repetition writes one.
    try capped.writer.splatBytesAll("xy", 0);
    try std.testing.expectEqualStrings("short", capped.body.written());

    // The write that would cross the cap is not stored, so memory stays under it.
    try std.testing.expectError(error.WriteFailed, capped.writer.writeAll("abcd"));
    try std.testing.expect(capped.over);
    try std.testing.expectEqualStrings("short", capped.body.written());
    try std.testing.expectError(error.WriteFailed, capped.writer.splatBytesAll("ab", 2));

    // Exactly the cap is accepted.
    capped.over = false;
    try capped.writer.writeAll("abc");
    try std.testing.expectEqualStrings("shortabc", capped.body.written());
}

// A download has no deadline of its own in `std.http`, so the one this path
// imposes is the only thing between a host that stops answering and an
// operator whose terminal never comes back. The floor holds the small requests
// to it, and the rate is what keeps a slow link a slow download rather than a
// failed one: the asset is up to `max_asset_bytes`, and cutting that off at the
// floor would refuse an install over a link that is working.
test "update: a download's deadline is its floor until the body needs more" {
    try std.testing.expectEqual(fetch_timeout_floor_ms, fetchTimeoutMs(1024));
    try std.testing.expectEqual(fetch_timeout_floor_ms, fetchTimeoutMs(max_sidecar_bytes));
    // The largest published asset is allowed the time its size buys at the
    // named rate, which is well past the floor.
    try std.testing.expect(fetchTimeoutMs(max_asset_bytes) > fetch_timeout_floor_ms);
    // Monotone in the cap, so a bigger download is never given less time than
    // a smaller one.
    try std.testing.expect(fetchTimeoutMs(2 * max_asset_bytes) >= fetchTimeoutMs(max_asset_bytes));
}

// The sentence a status is read with. Three statuses carry one and the rest
// carry none, and the two that share a sentence are the two a token fixes, so
// a hint that moved between them sends a reader after the wrong thing.
//
// The 403 is read out of the body rather than taken from the status, because a
// 403 is also a permission refusal and one told to set a token goes after a fix
// that changes nothing. A 429 needs no body to say which of the two it is.
test "update: a status names what a person has to do about it" {
    try std.testing.expectEqualStrings(" (nothing published at that url)", statusHint(.not_found, ""));
    try std.testing.expectEqualStrings(" (rate limited; set GITHUB_TOKEN)", statusHint(.too_many_requests, ""));
    try std.testing.expectEqualStrings(" (rate limited; set GITHUB_TOKEN)", statusHint(.forbidden, rate_limit_body));
    // The two 403s that are not the rate limit, so the number is all there is.
    try std.testing.expectEqualStrings("", statusHint(.forbidden, ""));
    try std.testing.expectEqualStrings("", statusHint(.forbidden, permission_body));
    // Nothing to do about these, so nothing is said past the number.
    for ([_]std.http.Status{ .ok, .internal_server_error, .bad_gateway, .unauthorized }) |status| {
        try std.testing.expectEqualStrings("", statusHint(status, rate_limit_body));
    }
}

// The two bodies the 403 is told apart by, spelled the way GitHub writes them.
const rate_limit_body =
    \\{"message":"API rate limit exceeded for 1.2.3.4. (But here's the good news: Authenticated requests get a higher rate limit.)","documentation_url":"https://docs.github.com/rest/overview/resources-in-the-rest-api#rate-limiting"}
;
const permission_body =
    \\{"message":"Resource not accessible by personal access token","documentation_url":"https://docs.github.com/rest"}
;

// Which of the two a refusal body is, which is the whole of what separates the
// 403 that a token fixes from the 403 that no token fixes.
test "update: a 403 is a rate limit only when the body says so" {
    try std.testing.expect(isRateLimited(rate_limit_body));
    // Either spelling, because the limit is announced as both across the
    // endpoints that answer with one.
    try std.testing.expect(isRateLimited("secondary rate limit; please wait"));
    try std.testing.expect(!isRateLimited(permission_body));
    // A body too short to carry a word is not the rate limit, and neither is
    // one that never arrived: a reader told to set a token they already set is
    // worse off than one told nothing.
    try std.testing.expect(!isRateLimited(""));
    try std.testing.expect(!isRateLimited("denied"));
}

// The two waits the loop can take are the shared schedule under this path's
// own, shorter cap: three attempts means two waits, and neither is longer than
// what `net` was written to be given here.
test "update: a retried download waits on the shared backoff under its own cap" {
    try std.testing.expectEqual(@as(u32, 3), max_attempts);
    try std.testing.expectEqual(@as(u64, 1000), net.retryBackoffMs(1, max_backoff_ms));
    try std.testing.expectEqual(@as(u64, 2000), net.retryBackoffMs(2, max_backoff_ms));
    try std.testing.expectEqual(@as(u64, 4000), net.retryBackoffMs(3, max_backoff_ms));
    // The cap is this path's and not the run's, which is what `net` says the
    // two waits are not the same promise about.
    try std.testing.expect(max_backoff_ms < 60_000);
}

// Which failures another attempt could answer differently, and which could not.
// A 404 names something that is not published and asking again changes nothing;
// a 503 is the server being busy, and the same set the agent run retries on.
test "update: a download retries the statuses and errors the run retries on" {
    try std.testing.expect(net.retryableStatus(.service_unavailable));
    try std.testing.expect(net.retryableStatus(.too_many_requests));
    try std.testing.expect(!net.retryableStatus(.not_found));
    try std.testing.expect(!net.retryableStatus(.forbidden));
    try std.testing.expect(net.transientTransportError(error.ConnectionResetByPeer));
    try std.testing.expect(!net.transientTransportError(error.InvalidUrl));
}

/// A tmp-dir file as a path `replaceBinary` opens from the working directory.
fn tmpFile(tmp: std.testing.TmpDir, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/{s}", .{ tmp.sub_path, name });
}

fn expectFile(dir: std.Io.Dir, name: []const u8, want: []const u8) !void {
    const got = try dir.readFileAlloc(std.testing.io, name, std.testing.allocator, .limited(64));
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings(want, got);
}

test "update: replacing the binary writes the bytes with mode 0755" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const exe = try tmpFile(tmp, "microagent");
    defer std.testing.allocator.free(exe);

    try tmp.dir.writeFile(io, .{ .sub_path = "microagent", .data = "old-binary" });
    try replaceBinary(io, exe, "abc");
    try expectFile(tmp.dir, "microagent", "abc");
    const mode = (try tmp.dir.statFile(io, "microagent", .{})).permissions.toMode();
    try std.testing.expectEqual(exec_mode.toMode(), mode & 0o7777);
}

test "update: replacing follows a symlinked destination" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const exe = try tmpFile(tmp, "microagent");
    defer std.testing.allocator.free(exe);

    try tmp.dir.writeFile(io, .{ .sub_path = "real_bin", .data = "old-content" });
    try tmp.dir.symLink(io, "real_bin", "microagent", .{});
    try replaceBinary(io, exe, "new-content");

    var link_buf: [256]u8 = undefined;
    const n = try tmp.dir.readLink(io, "microagent", &link_buf);
    try std.testing.expectEqualStrings("real_bin", link_buf[0..n]);
    try expectFile(tmp.dir, "real_bin", "new-content");
}

test "update: replacing follows a chain of symlinked destinations" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const exe = try tmpFile(tmp, "microagent");
    defer std.testing.allocator.free(exe);

    try tmp.dir.writeFile(io, .{ .sub_path = "real_bin", .data = "old-content" });
    try tmp.dir.symLink(io, "real_bin", "versioned_bin", .{});
    try tmp.dir.symLink(io, "versioned_bin", "microagent", .{});
    try replaceBinary(io, exe, "new-content");

    // Both links survive: stopping at the first would replace it with a copy.
    var link_buf: [256]u8 = undefined;
    const outer = try tmp.dir.readLink(io, "microagent", &link_buf);
    try std.testing.expectEqualStrings("versioned_bin", link_buf[0..outer]);
    const inner = try tmp.dir.readLink(io, "versioned_bin", &link_buf);
    try std.testing.expectEqualStrings("real_bin", link_buf[0..inner]);
    try expectFile(tmp.dir, "real_bin", "new-content");
}

test "update: replacing the binary twice leaves the one install" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const exe = try tmpFile(tmp, "microagent");
    defer std.testing.allocator.free(exe);

    try tmp.dir.writeFile(io, .{ .sub_path = "real_bin", .data = "old-content" });
    try tmp.dir.symLink(io, "real_bin", "microagent", .{});
    try replaceBinary(io, exe, "new-content");
    try replaceBinary(io, exe, "new-content");

    var link_buf: [256]u8 = undefined;
    const n = try tmp.dir.readLink(io, "microagent", &link_buf);
    try std.testing.expectEqualStrings("real_bin", link_buf[0..n]);
    try expectFile(tmp.dir, "real_bin", "new-content");
}

const asset_fixture = "{\"name\":\"" ++ asset_base ++
    "\",\"browser_download_url\":\"https://github.com/maci0/microagent/releases/download/v0.1.0/" ++ asset_base ++ "\"}";

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
    "{\"tag_name\":\"v0.1.0\",\"html_url\":\"https://github.com/o/r\",\"assets\":[{\"name\":\"a\"},{\"name\":1,\"browser_download_url\":\"https://github.com/o/r/a\"}]}",
    "{\"tag_name\":\"v0.1.0\",\"html_url\":\"https://github.com/maci0/microagent/releases/tag/v0.1.0\",\"assets\":[" ++ asset_fixture ++ "]}",
    "{\"tag_name\":\"v0.1.0\",\"html_url\":\"https://github.com/o/r\",\"assets\":[{\"name\":\"a\",\"browser_download_url\":\"https://github.com.evil.com/a\"},{\"name\":\"c\",\"browser_download_url\":\"http://github.com/c\"},{\"name\":\"d\",\"browser_download_url\":\"https://user@github.com/d\"}]}",
    "{\"tag_name\":\"\\u0000\\ud83d\\ude80\",\"html_url\":\"https://github.com/o/r\",\"assets\":[{\"name\":\"\\u0000\",\"browser_download_url\":\"https://github.com/o/r/\\u0000\"}]}",
    "{\"tag_name\":\"v0.1.0\\u001b[2J\\u0007\",\"html_url\":\"https://github.com/o/r\",\"assets\":[{\"name\":\"microagent-v0.1.0\\u001b[2J-x86_64-linux-musl\",\"browser_download_url\":\"https://github.com/o/r/a\"}]}",
};

test "update: fuzz: a release body parses to values that print safely" {
    try std.testing.fuzz({}, fuzzRelease, .{ .corpus = &release_corpus });
}

fn fuzzRelease(_: void, smith: *std.testing.Smith) !void {
    var buf: [16 * 1024]u8 = undefined;
    const body = if (smith.in) |seed| seed else buf[0..smith.slice(&buf)];
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const rel = parseRelease(arena, body) catch return;
    for (rel.assets) |asset| try std.testing.expect(assetUrl(rel, asset.name) != null);

    // Whatever the tag says, it is the same release as itself with or without
    // the `v`, and as nothing that differs by a byte.
    const bare = bareVersion(rel.tag);
    try std.testing.expect(sameRelease(rel.tag, rel.tag));
    try std.testing.expect(sameRelease(bare, rel.tag));
    try std.testing.expect(!sameRelease(bare, try std.fmt.allocPrint(arena, "{s}x", .{bare})));

    for ([_][]const u8{ quoteUntrusted(arena, rel.tag), quoteUntrusted(arena, if (rel.assets.len > 0) rel.assets[0].name else rel.page) }) |shown| {
        try std.testing.expect(shown.len <= net.quoted_value_bytes);
        try std.testing.expect(std.unicode.utf8ValidateSlice(shown));
        for (shown) |c| try std.testing.expect(c >= 0x20 and c != 0x7f);
    }
}

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

    // Both sides of the harness's assertions are reachable.
    try std.testing.expect(checksumMatches("abc", abc_sha ++ "  " ++ asset_base, asset_base));
    try std.testing.expect(!checksumMatches("abd", abc_sha ++ "  " ++ asset_base, asset_base));
}

fn fuzzSidecar(_: void, smith: *std.testing.Smith) !void {
    var scratch: [16 * 1024]u8 = undefined;
    const sidecar: []const u8 = if (smith.in) |seed| seed else scratch[0..smith.slice(&scratch)];
    const asset: []const u8 = if (smith.in) |_|
        "abc"
    else
        scratch[sidecar.len..][0..smith.slice(scratch[sidecar.len..])];

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    if (checksumMatches(asset, sidecar, asset_base)) {
        // A match is the whole first line: the asset's digest, two spaces, the name.
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

    // One changed hex digit describes different bytes and must not match.
    const tampered = try arena_state.allocator().dupe(u8, sidecar);
    if (tampered.len > 0 and std.ascii.isHex(tampered[0])) {
        tampered[0] = if (std.ascii.toLower(tampered[0]) == '0') '1' else '0';
        try std.testing.expect(!checksumMatches(asset, tampered, asset_base));
    }
}

test "update: the binary is replaced only when the sidecar vouches for the download" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const exe = try tmpFile(tmp, "microagent");
    defer std.testing.allocator.free(exe);
    try tmp.dir.writeFile(io, .{ .sub_path = "microagent", .data = "old-content" });

    const good = abc_sha ++ "  " ++ asset_base ++ "\n";
    const wrong_digest = "0" ** 64 ++ "  " ++ asset_base ++ "\n";
    const other_file = abc_sha ++ "  microagent-v0.1.0-aarch64-linux-musl\n";
    for ([_][]const u8{ wrong_digest, other_file, "", "not a sidecar" }) |sidecar| {
        try std.testing.expectError(error.ChecksumMismatch, installIfVerified(io, exe, "abc", sidecar, asset_base));
        try expectFile(tmp.dir, "microagent", "old-content");
    }
    // The digest is over the bytes downloaded, not over the sidecar's say-so about another file.
    try std.testing.expectError(error.ChecksumMismatch, installIfVerified(io, exe, "abd", good, asset_base));
    try expectFile(tmp.dir, "microagent", "old-content");

    try installIfVerified(io, exe, "abc", good, asset_base);
    try expectFile(tmp.dir, "microagent", "abc");
}
