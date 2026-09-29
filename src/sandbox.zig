const std = @import("std");
const builtin = @import("builtin");
const net = @import("net.zig");
const chat = @import("chat.zig");

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
/// Always includes the current working directory and `/tmp`, and `$TMPDIR` where it names an
/// absolute directory no root above already covers, which is where macOS keeps per-user scratch
/// space and where a Linux host that exports it keeps it. If `session_dir` is provided, it is
/// also included so the run can append its session log.
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

    // 5. $TMPDIR, last so the coverage test below reads every root added before
    // it. macOS keeps per-user scratch space under /var/folders, nowhere near
    // /tmp, and a Linux host that exports it somewhere else needs the same root
    // for the same reason: a tool that writes to the directory the environment
    // named is refused by the sandbox otherwise, and the refusal names a path
    // the operator never wrote. So the value decides, not the system it was set
    // on. A value that is not absolute names no directory, and one already
    // covered by a root above is not added a second time, which is what the
    // unset and the `/tmp` cases are.
    if (environ_map) |env| {
        if (env.get("TMPDIR")) |raw| {
            const tmpdir = std.mem.trim(u8, raw, net.env_surrounding);
            if (std.fs.path.isAbsolute(tmpdir)) {
                const resolved = canonical(io, arena, tmpdir);
                if (!withinAnyRoot(resolved, roots.items)) try roots.append(arena, resolved);
            }
        }
    }

    return roots.items;
}

/// True when `path` is `root` itself or sits under it. The separator test is what keeps a
/// sibling whose name merely starts with the root's, `/writable-roots-other` against
/// `/writable-roots`, from reading as inside it.
fn isUnderRoot(path: []const u8, root: []const u8) bool {
    if (root.len == 0) return true;
    if (!std.mem.startsWith(u8, path, root)) return false;
    return path.len == root.len or path[root.len] == std.fs.path.sep;
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

    // If the file exists on disk (or is a symlink), also check the real path target. A file that is
    // not there yet resolves only as far as the deepest ancestor of it that is, and that ancestor
    // is what the check reads: a tree carrying `link -> /etc` and a call for `link/passwd` is a
    // path that begins inside a root and leaves it, which the lexical check cannot see because it
    // never looks at what a link points at. Both halves have to hold: the resolved path names
    // where the bytes land, and the lexical one is the path the call named.
    const real = resolvedPrefix(io, arena, abs_path) orelse return false;
    if (!withinAnyRoot(real, writable_roots)) return false;
    return withinAnyRoot(abs_path, writable_roots);
}

/// Whether `path` is under any of `writable_roots`, reading a root as covering a whole path
/// component and nothing more: a root that is a prefix of a longer name is not a parent of it, so
/// `/tmp` does not cover `/tmpd`.
fn withinAnyRoot(path: []const u8, writable_roots: []const []const u8) bool {
    for (writable_roots) |raw_root| {
        if (isUnderRoot(path, std.mem.trimEnd(u8, raw_root, "/\\"))) return true;
    }
    return false;
}

/// The resolved path of `abs_path` where it stops being one: the deepest ancestor that exists,
/// with every symlink on the way to it followed. A path whose own name resolves is itself, and a
/// path with no existing ancestor (every one of its components missing) is null, which the caller
/// reads as unwritable rather than as permitted.
///
/// `abs_path` is the lexically resolved form, so the components walked back over carry no `.` or
/// `..` and the tail that is dropped is exactly the part that does not exist yet. That tail cannot
/// change which root the path is under, so answering for the prefix answers for the path.
fn resolvedPrefix(io: Io, arena: std.mem.Allocator, abs_path: []const u8) ?[]const u8 {
    var probe = abs_path;
    while (std.Io.Dir.cwd().realPathFileAlloc(io, probe, arena)) |real| return real else |_| {}
    const parent = std.fs.path.dirname(probe) orelse return null;
    if (parent.len == 0 or std.mem.eql(u8, parent, probe)) return null;
    probe = parent;
    return resolvedPrefix(io, arena, probe);
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

/// Grants `access` beneath the directory at `path` to the ruleset, and answers whether the
/// kernel took the rule. A caller that ignores the answer confines a run by a ruleset that is
/// missing a rule it was built to hold, so the errno comes back rather than the outcome being
/// dropped: what a missing rule means differs by rule, and the difference is the caller's to
/// make.
fn allowBeneath(ruleset_fd: i32, path: [*:0]const u8, access: u64) ?std.posix.E {
    const opened = linux.open(path, .{ .PATH = true, .DIRECTORY = true, .CLOEXEC = true }, 0);
    if (linux.errno(opened) != .SUCCESS) return linux.errno(opened);
    const dir_fd: i32 = @intCast(opened);
    defer _ = linux.close(dir_fd);
    const rule: LandlockPathBeneathAttr = .{ .allowed_access = access, .parent_fd = dir_fd };
    const added = linux.syscall4(.landlock_add_rule, @intCast(ruleset_fd), rule_path_beneath, @intFromPtr(&rule), 0);
    return if (linux.errno(added) == .SUCCESS) null else linux.errno(added);
}

/// Applies Linux Landlock LSM rules to restrict filesystem write access.
/// Root `/` is set to read-only, while entries in `writable_roots` are set to read-write.
/// Returns true if Landlock was successfully enforced, false otherwise.
///
/// The read-only grant on `/` is what every other rule is written against: a ruleset that
/// handled the filesystem accesses but granted no path at all denies all of them, so a run
/// confined by it cannot read the model, the tool, or its own source. It is therefore a whole
/// answer rather than one rule's: when the kernel will not take it, nothing is enforced and the
/// answer is false, which the caller says out loud.
///
/// A writable root is a grant the run is promised, not the confinement itself. One the kernel
/// will not grant leaves the run unable to write there, which is the safe side and no reason to
/// hand back a run with no confinement at all, so the root is named and the rest are applied.
pub fn applyLandlock(io: Io, arena: std.mem.Allocator, writable_roots: []const []const u8) bool {
    if (builtin.os.tag != .linux) return false;

    const abi = checked(linux.syscall3(.landlock_create_ruleset, 0, 0, create_ruleset_version)) orelse return false;
    const handled = handledAccess(abi);

    const attr: LandlockRulesetAttr = .{ .handled_access_fs = handled };
    const ruleset_fd: i32 = @intCast(checked(linux.syscall3(.landlock_create_ruleset, @intFromPtr(&attr), @sizeOf(LandlockRulesetAttr), 0)) orelse return false);
    defer _ = linux.close(ruleset_fd);

    if (allowBeneath(ruleset_fd, "/", access_read_only & handled)) |err| {
        net.note(io, arena, "microagent: sandbox: the kernel refused a read-only rule on / ({s}), so no filesystem rule was enforced at all\n", .{@tagName(err)});
        return false;
    }
    for (writable_roots) |root_path| {
        if (root_path.len == 0) continue;
        // A root whose name cannot be made a C string is named with the same refusal the
        // allocation failure below gets: it stays read-only, and the operator is told which
        // writable root is not one.
        const c_path = arena.dupeZ(u8, root_path) catch {
            rootRefused(io, arena, root_path, "OutOfMemory");
            continue;
        };
        if (allowBeneath(ruleset_fd, c_path.ptr, handled)) |err| rootRefused(io, arena, root_path, @tagName(err));
    }

    if (checked(linux.prctl(@intFromEnum(linux.PR.SET_NO_NEW_PRIVS), 1, 0, 0, 0)) == null) return false;
    return checked(linux.syscall2(.landlock_restrict_self, @intCast(ruleset_fd), 0)) != null;
}

/// A writable root the kernel did not grant. The run goes on confined without it, so the line
/// says which root is not writable and why rather than leaving a tool that fails on a write the
/// operator asked for with nothing to read.
fn rootRefused(io: Io, arena: std.mem.Allocator, root_path: []const u8, why: []const u8) void {
    // Escaped once here, the reason the session log escapes a directory: the root comes from the
    // working directory, the environment, or the config, and each can carry bytes a terminal acts
    // on.
    const shown = chat.safeTextAll(arena, root_path);
    net.writeErr(io, std.fmt.allocPrint(arena, root_refusal_text, .{ shown, why }) catch return);
}

/// The line a refused writable root prints. A constant so the test asserts the wording the
/// operator reads rather than a copy of it, and so the two refusals in `applyLandlock` can only
/// ever print the one.
const root_refusal_text = "microagent: sandbox: {s} was not made writable ({s}); writes under it are refused\n";

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
pub fn applySandbox(io: Io, arena: std.mem.Allocator, writable_roots: []const []const u8) bool {
    return switch (builtin.os.tag) {
        .linux => applyLandlock(io, arena, writable_roots),
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

    // The second root is a real directory of its own rather than the literal
    // `/tmp`, which is `/private/tmp` on a host that resolves the link, so a
    // root spelled that way asserts a false on every machine but this one.
    var second = std.testing.tmpDir(.{});
    defer second.cleanup();
    var second_buf: [std.fs.max_path_bytes]u8 = undefined;
    const second_root = second_buf[0..try second.dir.realPath(io, &second_buf)];

    const writable_roots = [_][]const u8{ root, second_root };

    // Path inside tmp root
    const inside = try std.fs.path.join(arena, &.{ root, "file.txt" });
    try std.testing.expect(isPathWritable(io, arena, inside, &writable_roots));

    // Nested inside
    const nested = try std.fs.path.join(arena, &.{ root, "sub", "dir", "file.txt" });
    try std.testing.expect(isPathWritable(io, arena, nested, &writable_roots));

    // Under the second root
    try std.testing.expect(isPathWritable(io, arena, try std.fs.path.join(arena, &.{ second_root, "test.txt" }), &writable_roots));

    // Outside path: /etc/passwd
    try std.testing.expect(!isPathWritable(io, arena, "/etc/passwd", &writable_roots));

    // Traversal attempting to escape
    const escaped = try std.fs.path.join(arena, &.{ root, "..", "outside.txt" });
    try std.testing.expect(!isPathWritable(io, arena, escaped, &writable_roots));

    // Prefix collision: root + "-other" is not under root
    const collision = try std.fmt.allocPrint(arena, "{s}-other/file.txt", .{root});
    try std.testing.expect(!isPathWritable(io, arena, collision, &writable_roots));

    // A path that is nothing but whitespace is not a path, and a run with no
    // roots at all has no sandbox, so both answers are refusals of different
    // kinds and neither is reached by the six cases above.
    try std.testing.expect(!isPathWritable(io, arena, "  \t\r\n", &writable_roots));
    try std.testing.expect(!isPathWritable(io, arena, "", &writable_roots));
    try std.testing.expect(isPathWritable(io, arena, "/etc/passwd", &.{}));
}

// A ruleset may only name bits the running kernel knows, so the mask is the
// ABI's. A dropped bit is not a build failure, it is a right quietly left off:
// `access_truncate` missing turns TRUNCATE enforcement off on every kernel
// that has it, and nothing at run time says so.
test "handledAccess names only the rights the running ABI has" {
    try std.testing.expectEqual(access_abi1, handledAccess(1));
    try std.testing.expectEqual(access_abi1, handledAccess(0));
    try std.testing.expectEqual(access_abi1 | access_refer, handledAccess(2));
    try std.testing.expectEqual(access_abi1 | access_refer | access_truncate, handledAccess(3));
    try std.testing.expectEqual(access_abi1 | access_refer | access_truncate, handledAccess(4));
    try std.testing.expectEqual(
        access_abi1 | access_refer | access_truncate | access_ioctl_dev,
        handledAccess(5),
    );
    try std.testing.expectEqual(
        access_abi1 | access_refer | access_truncate | access_ioctl_dev,
        handledAccess(6),
    );
}

test "isPathWritable follows a symlinked parent of a file that does not exist yet" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const arena = state.allocator();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var other = std.testing.tmpDir(.{});
    defer other.cleanup();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(io, &buf)];
    var other_buf: [std.fs.max_path_bytes]u8 = undefined;
    const elsewhere = other_buf[0..try other.dir.realPath(io, &other_buf)];
    try tmp.dir.createDirPath(io, "inside");
    try tmp.dir.symLink(io, elsewhere, "inside/link", .{});

    const writable_roots = [_][]const u8{root};

    // The file is not there, so the only thing that can answer is the directory
    // that will hold it, and the directory is a link out of the root.
    try std.testing.expect(!isPathWritable(io, arena, try std.fs.path.join(arena, &.{ root, "inside", "link", "new.txt" }), &writable_roots));
    // The same call one component short of the link is inside the root.
    try std.testing.expect(isPathWritable(io, arena, try std.fs.path.join(arena, &.{ root, "inside", "new.txt" }), &writable_roots));
    // And through the link to something that does exist is refused on the target.
    try std.testing.expect(!isPathWritable(io, arena, try std.fs.path.join(arena, &.{ root, "inside", "link" }), &writable_roots));
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
    // The roots are canonical, and on macOS /tmp and /var are symlinks into
    // /private, so the expectation is resolved the same way the root is rather
    // than spelled: `/private/tmp` on that system, `/tmp` here.
    try std.testing.expectEqualStrings(canonical(io, arena, "/tmp"), roots[1]);
    try std.testing.expectEqualStrings(sdir, roots[2]);
    try std.testing.expectEqualStrings(canonical(io, arena, "/var/log"), roots[3]);
}

test "resolveWritableRoots adds $TMPDIR where a root does not already cover it" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const arena = state.allocator();
    const io = std.testing.io;

    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    // A directory no machine holds, so the root it becomes is spelled the way
    // it was given rather than resolved: the same expectation answers on every
    // platform, and what is under test is whether the root is added at all.
    const tmpdir = "/nonexistent-tmpdir-for-the-sandbox-test";
    try env.put("TMPDIR", tmpdir);

    // macOS keeps per-user scratch space in $TMPDIR, under /var/folders and
    // nowhere near /tmp, and a Linux host that exports it somewhere else keeps
    // it there for the same reason: a tool writing to the directory the
    // environment named is refused by the sandbox otherwise. What decides is
    // the value, so the answer is the same on every claimed platform.
    const roots = try resolveWritableRoots(io, arena, &env, &.{}, null);
    var found = false;
    for (roots) |root| {
        if (std.mem.eql(u8, root, tmpdir)) found = true;
    }
    try std.testing.expect(found);

    // The ordinary Linux value names the root that is already there, so it is
    // not added a second time: the same grant twice is a longer ruleset and a
    // profile listing one subpath per line for nothing.
    try env.put("TMPDIR", "/tmp");
    const from_tmp = try resolveWritableRoots(io, arena, &env, &.{}, null);
    var tmp_roots: usize = 0;
    for (from_tmp) |root| {
        if (std.mem.eql(u8, root, canonical(io, arena, "/tmp"))) tmp_roots += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), tmp_roots);

    // A value that names no directory adds no root, and the newline a wrapper
    // exported from a file is trimmed off one that does rather than appended to
    // the path it names.
    var relative: std.process.Environ.Map = .init(std.testing.allocator);
    defer relative.deinit();
    try relative.put("TMPDIR", "relative/scratch");
    for (try resolveWritableRoots(io, arena, &relative, &.{}, null)) |root| {
        try std.testing.expect(!std.mem.eql(u8, root, "relative/scratch"));
    }
    try relative.put("TMPDIR", tmpdir ++ "\n");
    var found_trimmed = false;
    for (try resolveWritableRoots(io, arena, &relative, &.{}, null)) |root| {
        try std.testing.expect(!std.mem.endsWith(u8, root, "\n"));
        if (std.mem.eql(u8, root, tmpdir)) found_trimmed = true;
    }
    try std.testing.expect(found_trimmed);
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

test "a writable root the kernel refuses is named, escaped, with the reason" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const arena = state.allocator();

    // The line is what an operator reads when a tool refuses a write the run promised, so it
    // carries the root and the errno, and a root carrying a terminal's own bytes prints as the
    // characters it is rather than acting on them.
    try std.testing.expectEqualStrings(
        "microagent: sandbox: /work/project was not made writable (ENOENT); writes under it are refused\n",
        try std.fmt.allocPrint(arena, root_refusal_text, .{ "/work/project", "ENOENT" }),
    );
    const shown = chat.safeTextAll(arena, "/work\nproject\x1b[2J");
    const line = try std.fmt.allocPrint(arena, root_refusal_text, .{ shown, "EACCES" });
    try std.testing.expect(std.mem.indexOf(u8, line, "\n") == null or std.mem.indexOfScalar(u8, line, '\n').? == line.len - 1);
    for (line) |c| try std.testing.expect(c != 0x1b);
}
