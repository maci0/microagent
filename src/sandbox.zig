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

/// Resolves the absolute canonical directory roots that the sandbox permits writing to.
/// Always includes the current working directory and `/tmp`. If `session_dir` is provided,
/// it is also included so the run can append its session log.
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
    try roots.append(arena, "/tmp");

    // 3. session_dir if set
    if (session_dir) |sdir| {
        if (sdir.len > 0) {
            const sdir_exp = if (environ_map) |env| net.expandHome(env, arena, sdir) else sdir;
            const resolved_sdir = if (std.fs.path.isAbsolute(sdir_exp))
                try std.fs.path.resolve(arena, &.{sdir_exp})
            else
                try std.fs.path.resolve(arena, &.{ cwd, sdir_exp });
            _ = std.Io.Dir.cwd().createDirPath(io, resolved_sdir) catch {};
            try roots.append(arena, std.mem.trimEnd(u8, resolved_sdir, "/\\"));
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
        try roots.append(arena, std.mem.trimEnd(u8, resolved, "/\\"));
    }

    return roots.items;
}

/// Checks whether `path` is within any allowed root in `writable_roots`.
/// An empty `writable_roots` slice means no sandbox restriction is active.
pub fn isPathWritable(io: Io, arena: std.mem.Allocator, path: []const u8, writable_roots: []const []const u8) bool {
    if (writable_roots.len == 0) return true;
    const trimmed = std.mem.trim(u8, path, " \t\r\n");
    if (trimmed.len == 0) return false;

    // First resolve lexical path (resolving .. and .)
    const abs_path = if (std.fs.path.isAbsolute(trimmed))
        std.fs.path.resolve(arena, &.{trimmed}) catch return false
    else blk: {
        const cwd = std.Io.Dir.cwd().realPathFileAlloc(io, ".", arena) catch {
            const res = std.fs.path.resolve(arena, &.{ ".", trimmed }) catch return false;
            break :blk res;
        };
        const res = std.fs.path.resolve(arena, &.{ cwd, trimmed }) catch return false;
        break :blk res;
    };

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

/// Applies Linux Landlock LSM rules to restrict filesystem write access.
/// Root `/` is set to read-only, while entries in `writable_roots` are set to read-write.
/// Returns true if Landlock was successfully enforced, false otherwise.
pub fn applyLandlock(arena: std.mem.Allocator, writable_roots: []const []const u8) bool {
    if (builtin.os.tag != .linux) return false;

    // 1. Query Landlock ABI version
    const abi_res = std.os.linux.syscall3(
        std.os.linux.SYS.landlock_create_ruleset,
        0,
        0,
        1, // LANDLOCK_CREATE_RULESET_VERSION
    );
    const abi_signed: isize = @bitCast(abi_res);
    if (abi_signed < 1) return false;
    const abi: usize = @intCast(abi_signed);

    const supported_mask: u64 = if (abi >= 5)
        0xffff
    else if (abi >= 3)
        0x7fff
    else if (abi >= 2)
        0x3fff
    else
        0x1fff;

    const ro_mask: u64 = 0xd & supported_mask;
    const rw_mask: u64 = supported_mask;

    const attr = LandlockRulesetAttr{
        .handled_access_fs = supported_mask,
    };
    const ruleset_res = std.os.linux.syscall3(
        std.os.linux.SYS.landlock_create_ruleset,
        @intFromPtr(&attr),
        @sizeOf(LandlockRulesetAttr),
        0,
    );
    const ruleset_signed: isize = @bitCast(ruleset_res);
    if (ruleset_signed < 0) return false;
    const ruleset_fd: i32 = @intCast(ruleset_signed);
    defer _ = std.os.linux.close(ruleset_fd);

    const open_flags = std.os.linux.O{
        .PATH = true,
        .DIRECTORY = true,
        .CLOEXEC = true,
    };

    // Add read-only rule for root /
    const root_fd_res = std.os.linux.open(
        "/",
        open_flags,
        0,
    );
    const root_fd_signed: isize = @bitCast(root_fd_res);
    if (root_fd_signed >= 0) {
        const root_fd: i32 = @intCast(root_fd_signed);
        defer _ = std.os.linux.close(root_fd);
        const pb = LandlockPathBeneathAttr{
            .allowed_access = ro_mask,
            .parent_fd = root_fd,
        };
        _ = std.os.linux.syscall4(
            std.os.linux.SYS.landlock_add_rule,
            @intCast(ruleset_fd),
            1, // LANDLOCK_RULE_PATH_BENEATH
            @intFromPtr(&pb),
            0,
        );
    }

    // Add read-write rules for writable roots
    for (writable_roots) |root_path| {
        if (root_path.len == 0) continue;
        const c_path = arena.dupeZ(u8, root_path) catch continue;
        const dir_fd_res = std.os.linux.open(
            c_path.ptr,
            open_flags,
            0,
        );
        const dir_fd_signed: isize = @bitCast(dir_fd_res);
        if (dir_fd_signed >= 0) {
            const dir_fd: i32 = @intCast(dir_fd_signed);
            defer _ = std.os.linux.close(dir_fd);
            const pb = LandlockPathBeneathAttr{
                .allowed_access = rw_mask,
                .parent_fd = dir_fd,
            };
            _ = std.os.linux.syscall4(
                std.os.linux.SYS.landlock_add_rule,
                @intCast(ruleset_fd),
                1,
                @intFromPtr(&pb),
                0,
            );
        }
    }

    const prctl_res = std.os.linux.syscall5(
        std.os.linux.SYS.prctl,
        38, // PR_SET_NO_NEW_PRIVS
        1,
        0,
        0,
        0,
    );
    if (@as(isize, @bitCast(prctl_res)) < 0) return false;

    const restrict_res = std.os.linux.syscall2(
        std.os.linux.SYS.landlock_restrict_self,
        @intCast(ruleset_fd),
        0,
    );
    if (@as(isize, @bitCast(restrict_res)) < 0) return false;
    return true;
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
