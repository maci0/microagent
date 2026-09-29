const std = @import("std");
const builtin = @import("builtin");
const chat = @import("chat.zig");
const net = @import("net.zig");

const Io = std.Io;

const LandlockRulesetAttr = extern struct {
    handled_access_fs: u64,
};

const LandlockPathBeneathAttr = extern struct {
    allowed_access: u64,
    parent_fd: i32,
};

/// `path` with symlinks resolved, or as given when it does not exist yet (a root that is not there
/// grants nothing in the kernel either). macOS keeps `/tmp` and `$TMPDIR` behind symlinks into
/// `/private`, and both the in-process check and a Seatbelt `subpath` compare resolved paths.
fn canonical(io: Io, arena: std.mem.Allocator, path: []const u8) []const u8 {
    const real = std.Io.Dir.cwd().realPathFileAlloc(io, path, arena) catch return path;
    return std.mem.trimEnd(u8, real, "/\\");
}

/// Resolves the absolute canonical directory roots that the sandbox permits writing to.
/// Always includes the current working directory and `/tmp`, and on macOS `$TMPDIR`, which is
/// where that system keeps per-user scratch space. If `session_dir` is provided, it is also
/// included so the run can append its session log.
pub fn resolveWritableRoots(
    io: Io,
    arena: std.mem.Allocator,
    environ_map: ?*const std.process.Environ.Map,
    custom_writable: []const []const u8,
    session_dir: ?[]const u8,
) ![]const []const u8 {
    var roots: std.ArrayList([]const u8) = .empty;

    // 1. Current working directory
    const cwd = std.Io.Dir.cwd().realPathFileAlloc(io, ".", arena) catch blk: {
        break :blk try std.fs.path.resolve(arena, &.{"."});
    };
    try roots.append(arena, std.mem.trimEnd(u8, cwd, "/\\"));

    // 2. /tmp
    try roots.append(arena, canonical(io, arena, "/tmp"));
    if (builtin.os.tag == .macos) {
        if (environ_map) |env| {
            if (env.get("TMPDIR")) |tmpdir| {
                if (std.fs.path.isAbsolute(tmpdir)) try roots.append(arena, canonical(io, arena, tmpdir));
            }
        }
    }

    // 3. session_dir if set
    if (session_dir) |sdir| {
        if (sdir.len > 0) {
            const sdir_exp = if (environ_map) |env| net.expandHome(env, arena, sdir) else sdir;
            const resolved_sdir = if (std.fs.path.isAbsolute(sdir_exp))
                try std.fs.path.resolve(arena, &.{sdir_exp})
            else
                try std.fs.path.resolve(arena, &.{ cwd, sdir_exp });
            _ = std.Io.Dir.cwd().createDirPath(io, resolved_sdir) catch {};
            try roots.append(arena, canonical(io, arena, std.mem.trimEnd(u8, resolved_sdir, "/\\")));
        }
    }

    // 4. Custom writable paths from config
    for (custom_writable) |w| {
        const trimmed = std.mem.trim(u8, w, " \t\r\n");
        if (trimmed.len == 0) continue;
        const expanded = if (environ_map) |env| net.expandHome(env, arena, trimmed) else trimmed;
        const resolved = if (std.fs.path.isAbsolute(expanded))
            try std.fs.path.resolve(arena, &.{expanded})
        else
            try std.fs.path.resolve(arena, &.{ cwd, expanded });
        try roots.append(arena, canonical(io, arena, std.mem.trimEnd(u8, resolved, "/\\")));
    }

    return roots.items;
}

/// Checks whether `path` is within any allowed root in `writable_roots`.
/// An empty `writable_roots` slice means no sandbox restriction is active. A relative `path` is
/// taken relative to `writable_roots[0]`, which must be the working directory.
pub fn isPathWritable(io: Io, arena: std.mem.Allocator, path: []const u8, writable_roots: []const []const u8) bool {
    if (writable_roots.len == 0) return true;
    const trimmed = std.mem.trim(u8, path, " \t\r\n");
    if (trimmed.len == 0) return false;

    // First resolve lexical path (resolving .. and .)
    const abs_path = if (std.fs.path.isAbsolute(trimmed))
        std.fs.path.resolve(arena, &.{trimmed}) catch return false
    else
        // `writable_roots[0]` is the canonical cwd `resolveWritableRoots` took at startup, and
        // nothing changes directory, so it saves a realpath per call.
        std.fs.path.resolve(arena, &.{ writable_roots[0], trimmed }) catch return false;

    // If file exists on disk (or is a symlink), also check the real path target
    if (std.Io.Dir.cwd().realPathFileAlloc(io, trimmed, arena)) |real| {
        var real_ok = false;
        for (writable_roots) |raw_root| {
            const root = std.mem.trimEnd(u8, raw_root, "/\\");
            if (root.len == 0) {
                real_ok = true;
                break;
            }
            if (std.mem.startsWith(u8, real, root)) {
                if (real.len == root.len or real[root.len] == std.fs.path.sep) {
                    real_ok = true;
                    break;
                }
            }
        }
        if (!real_ok) return false;
    } else |_| {}

    for (writable_roots) |raw_root| {
        const root = std.mem.trimEnd(u8, raw_root, "/\\");
        if (root.len == 0) return true;
        if (std.mem.startsWith(u8, abs_path, root)) {
            if (abs_path.len == root.len or abs_path[root.len] == std.fs.path.sep) {
                return true;
            }
        }
    }
    return false;
}

const linux = std.os.linux;

/// `LANDLOCK_ACCESS_FS_*` bits, by the ABI version that introduced them: thirteen in v1, `REFER`
/// in v2, `TRUNCATE` in v3 and `IOCTL_DEV` in v5. A ruleset may only name bits the running
/// kernel knows.
const access_execute: u64 = 1 << 0;
const access_read_file: u64 = 1 << 2;
const access_read_dir: u64 = 1 << 3;
const access_abi1: u64 = (1 << 13) - 1;
const access_refer: u64 = 1 << 13;
const access_truncate: u64 = 1 << 14;
const access_ioctl_dev: u64 = 1 << 15;
/// What `/` is granted: reading and running, never writing.
const access_read_only: u64 = access_execute | access_read_file | access_read_dir;

const create_ruleset_version: usize = 1 << 0;
const rule_path_beneath: usize = 1;

fn handledAccess(abi: usize) u64 {
    var mask = access_abi1;
    if (abi >= 2) mask |= access_refer;
    if (abi >= 3) mask |= access_truncate;
    if (abi >= 5) mask |= access_ioctl_dev;
    return mask;
}

/// A syscall's result as the value or the errno, so a caller tests one thing.
fn checked(rc: usize) ?usize {
    return if (linux.errno(rc) == .SUCCESS) rc else null;
}

/// Grants `access` beneath the directory at `path` to the ruleset. A directory that cannot be
/// opened or a rule the kernel refuses leaves that path with no grant, which is the safe side.
fn allowBeneath(ruleset_fd: i32, path: [*:0]const u8, access: u64) void {
    const dir_fd: i32 = @intCast(checked(linux.open(path, .{ .PATH = true, .DIRECTORY = true, .CLOEXEC = true }, 0)) orelse return);
    defer _ = linux.close(dir_fd);
    const rule: LandlockPathBeneathAttr = .{ .allowed_access = access, .parent_fd = dir_fd };
    _ = linux.syscall4(.landlock_add_rule, @intCast(ruleset_fd), rule_path_beneath, @intFromPtr(&rule), 0);
}

/// Applies Linux Landlock LSM rules to restrict filesystem write access.
/// Root `/` is set to read-only, while entries in `writable_roots` are set to read-write.
/// Returns true if Landlock was successfully enforced, false otherwise.
pub fn applyLandlock(arena: std.mem.Allocator, writable_roots: []const []const u8) bool {
    if (builtin.os.tag != .linux) return false;

    const abi = checked(linux.syscall3(.landlock_create_ruleset, 0, 0, create_ruleset_version)) orelse return false;
    const handled = handledAccess(abi);

    const attr: LandlockRulesetAttr = .{ .handled_access_fs = handled };
    const ruleset_fd: i32 = @intCast(checked(linux.syscall3(.landlock_create_ruleset, @intFromPtr(&attr), @sizeOf(LandlockRulesetAttr), 0)) orelse return false);
    defer _ = linux.close(ruleset_fd);

    allowBeneath(ruleset_fd, "/", access_read_only & handled);
    for (writable_roots) |root_path| {
        if (root_path.len == 0) continue;
        const c_path = arena.dupeZ(u8, root_path) catch continue;
        allowBeneath(ruleset_fd, c_path.ptr, handled);
    }

    if (checked(linux.prctl(@intFromEnum(linux.PR.SET_NO_NEW_PRIVS), 1, 0, 0, 0)) == null) return false;
    return checked(linux.syscall2(.landlock_restrict_self, @intCast(ruleset_fd), 0)) != null;
}

/// The device files a child opens for writing whatever the roots are: `/dev/null` for a stdio it
/// discards, `/dev/tty` for a tool that prompts, `/dev/dtracehelper` for the system libraries.
const seatbelt_devices = [_][]const u8{ "/dev/null", "/dev/tty", "/dev/dtracehelper" };

/// The Seatbelt profile (SBPL) that confines writes to `roots`: every other operation stays
/// allowed, file writes are denied, and the roots and a few device files are allowed back in.
/// Later rules win in SBPL, so the allow follows the deny. A `subpath` names a resolved path, so
/// the roots must already be canonical. A root with a control byte in it is left out, which is the
/// safe side: no grant, and no way to end the string early.
pub fn seatbeltProfile(arena: std.mem.Allocator, roots: []const []const u8) std.mem.Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "(version 1)\n(allow default)\n(deny file-write*)\n(allow file-write*\n");
    for (seatbelt_devices) |device| {
        try out.print(arena, "  (literal \"{s}\")\n", .{device});
    }
    for (roots) |root| {
        if (root.len == 0) continue;
        if (std.mem.indexOfAny(u8, root, &control_bytes) != null) continue;
        try out.appendSlice(arena, "  (subpath \"");
        for (root) |c| {
            if (c == '"' or c == '\\') try out.append(arena, '\\');
            try out.append(arena, c);
        }
        try out.appendSlice(arena, "\")\n");
    }
    try out.appendSlice(arena, ")\n");
    return out.items;
}

const control_bytes = blk: {
    var bytes: [0x20 + 1]u8 = undefined;
    for (0..0x20) |c| bytes[c] = @intCast(c);
    bytes[0x20] = 0x7f;
    break :blk bytes;
};

// libSystem, which every macOS binary links: the sandbox calls live there. Deprecated by Apple in
// name, used by the system itself, and the same call `sandbox-exec` makes.
extern "c" fn sandbox_init(profile: [*:0]const u8, flags: u64, errorbuf: *?[*:0]u8) c_int;
extern "c" fn sandbox_free_error(errorbuf: ?[*:0]u8) void;

/// Applies the Seatbelt profile to this process. Children inherit it across `exec`, as Landlock's
/// rules are, so `bash` and the MCP servers are confined too. Returns whether it took effect.
fn applySeatbelt(arena: std.mem.Allocator, writable_roots: []const []const u8) bool {
    const profile = seatbeltProfile(arena, writable_roots) catch return false;
    const profile_z = arena.dupeZ(u8, profile) catch return false;
    var message: ?[*:0]u8 = null;
    if (sandbox_init(profile_z.ptr, 0, &message) != 0) {
        sandbox_free_error(message);
        return false;
    }
    return true;
}

/// Confines this process and everything it starts to writes under `writable_roots`, with the
/// kernel's own mechanism: Landlock on Linux, Seatbelt on macOS. Returns false where the kernel
/// does not enforce it, and the caller says so.
pub fn applySandbox(arena: std.mem.Allocator, writable_roots: []const []const u8) bool {
    return switch (builtin.os.tag) {
        .linux => applyLandlock(arena, writable_roots),
        .macos => applySeatbelt(arena, writable_roots),
        else => false,
    };
}

test "isPathWritable allows paths within writable roots and denies paths outside" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const arena = state.allocator();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(io, &buf)];

    const writable_roots = [_][]const u8{ root, "/tmp" };

    // Path inside tmp root
    const inside = try std.fs.path.join(arena, &.{ root, "file.txt" });
    try std.testing.expect(isPathWritable(io, arena, inside, &writable_roots));

    // Nested inside
    const nested = try std.fs.path.join(arena, &.{ root, "sub", "dir", "file.txt" });
    try std.testing.expect(isPathWritable(io, arena, nested, &writable_roots));

    // Under /tmp
    try std.testing.expect(isPathWritable(io, arena, "/tmp/test.txt", &writable_roots));

    // Outside path: /etc/passwd
    try std.testing.expect(!isPathWritable(io, arena, "/etc/passwd", &writable_roots));

    // Traversal attempting to escape
    const escaped = try std.fs.path.join(arena, &.{ root, "..", "outside.txt" });
    try std.testing.expect(!isPathWritable(io, arena, escaped, &writable_roots));

    // Prefix collision: root + "-other" is not under root
    const collision = try std.fmt.allocPrint(arena, "{s}-other/file.txt", .{root});
    try std.testing.expect(!isPathWritable(io, arena, collision, &writable_roots));
}

test "resolveWritableRoots resolves cwd, tmp, session_dir, and custom roots" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const arena = state.allocator();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const sdir = buf[0..try tmp.dir.realPath(io, &buf)];

    const custom = [_][]const u8{ "/var/log", "relative/dir" };
    const roots = try resolveWritableRoots(io, arena, null, &custom, sdir);

    try std.testing.expect(roots.len >= 5);
    try std.testing.expectEqualStrings("/tmp", roots[1]);
    try std.testing.expectEqualStrings(sdir, roots[2]);
    try std.testing.expectEqualStrings("/var/log", roots[3]);
}

test "isPathWritable resolves a relative path against the first root" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const arena = state.allocator();
    const io = std.testing.io;

    const cwd = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", arena);
    const writable_roots = [_][]const u8{cwd};

    try std.testing.expect(isPathWritable(io, arena, "sub/new-file.txt", &writable_roots));
    try std.testing.expect(!isPathWritable(io, arena, "../outside.txt", &writable_roots));
}

test "seatbeltProfile denies writes, then allows the devices and each root" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const arena = state.allocator();

    const roots = [_][]const u8{
        "/work/project",
        "/private/tmp",
        "",
        "/has\"quote/and\\slash",
        "/new\nline",
        "/del\x7f",
    };
    const profile = try seatbeltProfile(arena, &roots);
    try std.testing.expectEqualStrings(
        \\(version 1)
        \\(allow default)
        \\(deny file-write*)
        \\(allow file-write*
        \\  (literal "/dev/null")
        \\  (literal "/dev/tty")
        \\  (literal "/dev/dtracehelper")
        \\  (subpath "/work/project")
        \\  (subpath "/private/tmp")
        \\  (subpath "/has\"quote/and\\slash")
        \\)
        \\
    , profile);
}
