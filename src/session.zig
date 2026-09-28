//! The per-run session log: one JSONL record per model response, written under
//! a name no other run holds, for a monitor (toktop) to read while the run is
//! still going.
//!
//! A leaf module over `net` and `chat`. It knows how long a response took and
//! what it spent, and how to name, prune and append to its own store, and
//! nothing about the conversation, the request or the tools: the loop hands it
//! one finished response at a time, so the log can be read, tested and changed
//! without the loop.

const std = @import("std");
const Io = std.Io;

const chat = @import("chat.zig");
const net = @import("net.zig");

/// Where the session log goes: MICROAGENT_SESSION_DIR, else a directory beside
/// the other per-run state under $HOME. An empty value turns the log off, and
/// so does a home that is not there.
pub fn sessionDir(init: std.process.Init) []const u8 {
    if (init.environ_map.get("MICROAGENT_SESSION_DIR")) |v| return v;
    const home = init.environ_map.get("HOME") orelse return "";
    return std.fs.path.join(init.arena.allocator(), &.{ home, ".microagent", "sessions" }) catch "";
}

/// One session log per run, one JSONL record per model response, which is what
/// a monitor (toktop) reads to report this run's tokens per second while it is
/// still going. Nothing depends on it, so every failure here is a null rather
/// than an error: a read-only home costs a run nothing.
pub const Session = struct {
    file: Io.File,
    cwd: []const u8,
    model: []const u8,
    /// The directory the log is in, so a record that cannot be written says
    /// which store went quiet rather than only why.
    dir: []const u8,
};

/// How many names `createSessionLog` tries before it gives the run no log. The
/// name space only runs out when the clock stamp is degenerate, and losing a
/// log costs the run nothing.
const session_name_attempts = 8;

/// This run's log, under a name nothing already holds.
///
/// The wall clock is settable, so its stamp is not a claim on a file: two runs
/// can read the same nanosecond, and one that is re-launched shortly after a
/// previous one can. Creating the file without `exclusive` would truncate the
/// log already sitting there, so a second run would erase the first run's
/// usage records, which is the whole reason the log exists. Every name is
/// opened exclusively and a taken one moves to the next, so a repeat run writes
/// beside the first rather than over it.
fn createSessionLog(io: Io, arena: std.mem.Allocator, session_dir: []const u8, stamp: i128) ?Io.File {
    var attempt: usize = 0;
    while (attempt < session_name_attempts) : (attempt += 1) {
        var suffix_buf: [4]u8 = undefined;
        const suffix = if (attempt == 0) "" else std.fmt.bufPrint(&suffix_buf, "-{d}", .{attempt}) catch return null;
        const name = std.fmt.allocPrint(arena, "{d}{s}.jsonl", .{ stamp, suffix }) catch return null;
        const path = std.fs.path.join(arena, &.{ session_dir, name }) catch return null;
        return std.Io.Dir.createFileAbsolute(io, path, .{ .exclusive = true }) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => return null,
        };
    }
    return null;
}

/// This run's log, or null when the run asked for none. Takes the directory
/// and the model rather than the caller's whole options, so the log's contract
/// with the loop is the two values a record needs and nothing else.
pub fn open(io: Io, arena: std.mem.Allocator, session_dir: []const u8, model: []const u8) ?Session {
    if (session_dir.len == 0) return null;
    // Every record names the directory it ran in. That is what attributes the
    // record to one review: the store is machine-wide, and a monitor skips a
    // record that names no directory rather than billing it to whichever
    // watcher happens to read the store. It comes from the run arena because a
    // directory that is resolved and then not used, by a log that could not be
    // opened, has no owner to free it.
    const cwd = std.Io.Dir.cwd().realPathFileAlloc(io, ".", arena) catch return null;
    std.Io.Dir.cwd().createDirPath(io, session_dir) catch return null;
    const stamp = Io.Clock.real.now(io).nanoseconds;
    const file = createSessionLog(io, arena, session_dir, stamp) orelse return null;
    pruneSessions(io, arena, session_dir);
    return .{ .file = file, .cwd = cwd, .model = model, .dir = session_dir };
}

/// Session logs kept on disk. The store is a per-run directory that nothing
/// ever deleted from, so a machine running gauntlet loops accumulated one file
/// per review forever; a monitor reads the recent runs, not the whole history.
const max_session_logs = 200;

fn allDigits(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

/// True for a name `createSessionLog` could have written: the unix nanoseconds
/// of a run, and the `-N` a second run with the same stamp was given rather
/// than the first run's log. The suffixed names matter as much as the plain
/// ones here: a machine whose clock repeats a stamp is exactly the machine
/// whose store fills with the logs a re-run wrote beside the first, and a
/// retention window that skipped them would bound nothing on it.
fn isSessionLogName(name: []const u8) bool {
    if (!std.mem.endsWith(u8, name, ".jsonl")) return false;
    const stem = name[0 .. name.len - ".jsonl".len];
    const dash = std.mem.indexOfScalar(u8, stem, '-') orelse return allDigits(stem);
    return allDigits(stem[0..dash]) and allDigits(stem[dash + 1 ..]);
}

/// Deletes the oldest logs past `max_session_logs`. The names are unix
/// nanoseconds, so a plain lexicographic sort is oldest first, and only this
/// program's own `<digits>[-<digits>].jsonl` files are touched. Every failure
/// is ignored: a store that cannot be pruned costs a run nothing.
fn pruneSessions(io: Io, arena: std.mem.Allocator, session_dir: []const u8) void {
    var dir = std.Io.Dir.openDirAbsolute(io, session_dir, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |name| arena.free(name);
        names.deinit(arena);
    }
    // The walk is scoped: the walker holds the directory handle, and deleting
    // through `dir` while it is still open closes that handle under it.
    {
        var walker = dir.walk(arena) catch return;
        defer walker.deinit();
        while (walker.next(io) catch return) |entry| {
            if (entry.kind != .file) continue;
            if (!isSessionLogName(entry.basename)) continue;
            // What is kept is the path from the store's root, not the basename.
            // The walker enters every subdirectory it meets, and a basename
            // deleted through the root either removes nothing or removes a
            // different file with the same name, while still counting toward
            // the limit: the store then looks pruned and is not.
            names.append(arena, arena.dupe(u8, entry.path) catch return) catch return;
        }
    }
    if (names.items.len <= max_session_logs) return;

    std.mem.sort([]u8, names.items, {}, struct {
        fn lessThan(_: void, a: []u8, b: []u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);

    var i: usize = 0;
    while (i < names.items.len - max_session_logs) : (i += 1) {
        dir.deleteFile(io, names.items[i]) catch {};
    }
}

/// Closes the log and clears the slot, so the handle is closed exactly once.
/// `writeRecord` drops a log it cannot write to and closes it there, so
/// a caller that closed a *copy* of the session would close a handle that is
/// already closed: in a debug build that is a panic, and in a release one it
/// closes whatever file descriptor the number has been reused for.
pub fn close(io: Io, session: *?Session) void {
    const s = session.* orelse return;
    session.* = null;
    s.file.close(io);
}

/// How long the model spent on one response. It travels in the record because
/// a monitor's polling gap covers the tools as well: dividing a turn's tokens
/// by that gap reports a rate for a generation that was never continuous.
pub fn elapsedMs(io: Io, since: i96) u64 {
    const delta = Io.Timestamp.now(io, .awake).nanoseconds - since;
    if (delta <= 0) return 0;
    return @intCast(@divTrunc(delta, std.time.ns_per_ms));
}

/// One record per response, into the log this run opened.
///
/// A failure to *open* the log is a null and costs the run nothing, which is
/// why `openSession` can stay quiet. A failure to *write* one is different: the
/// log was there, the run is producing records, and a store that has gone quiet
/// (a full disk, a directory removed under the run) would otherwise leave the
/// monitor reporting a run that stopped long before it did. It is named once and
/// the log is dropped, so the run is not left appending to a file nothing reads
/// and saying nothing about the gap.
pub fn writeRecord(io: Io, arena: std.mem.Allocator, session: *?Session, elapsed_ms: u64, result: *const chat.ChatResult) void {
    const s = session.* orelse return;
    const ts_ms: i64 = @intCast(@divTrunc(Io.Clock.real.now(io).nanoseconds, std.time.ns_per_ms));
    const line = sessionRecord(arena, ts_ms, s.cwd, s.model, elapsed_ms, result) catch |err| {
        net.note(io, arena, "microagent: a session record for {s} could not be built ({s}); the rest of this run is not recorded\n", .{ s.dir, @errorName(err) });
        s.file.close(io);
        session.* = null;
        return;
    };
    s.file.writeStreamingAll(io, line) catch |err| {
        net.note(io, arena, "microagent: the session log under {s} could not be written ({s}); the rest of this run is not recorded\n", .{ s.dir, @errorName(err) });
        s.file.close(io);
        session.* = null;
    };
}

/// One response's line: this response's own counters, not the run's cumulative
/// ones, so a reader sums them; the directory it ran in; and the model time it
/// took. The keys are the OpenAI-shaped ones toktop already reads by name.
fn sessionRecord(
    allocator: std.mem.Allocator,
    ts_ms: i64,
    cwd: []const u8,
    model: []const u8,
    elapsed_ms: u64,
    result: *const chat.ChatResult,
) ![]u8 {
    var jb = chat.JsonBuf.init(allocator);
    const w = jb.writer();
    try w.print("{{\"ts\":{d},\"cwd\":", .{ts_ms});
    try chat.writeJsonString(w, cwd);
    try w.writeAll(",\"model\":");
    try chat.writeJsonString(w, model);
    // Why the provider stopped, so a record that was cut at the generation
    // ceiling is distinguishable from one that ran to its own end. The empty
    // string is a stream that carried no finish_reason at all.
    try w.writeAll(",\"finish_reason\":");
    try chat.writeJsonString(w, result.finish_reason);
    try w.print(",\"elapsed_ms\":{d},\"usage\":{{" ++ chat.usage_fields, .{
        elapsed_ms, result.prompt_tokens, result.cached_tokens, result.completion_tokens, result.reasoning_tokens, result.total_tokens,
    });
    try w.writeAll("}}\n");
    return jb.items();
}

// A record a monitor reads has to be one JSON object with this response's own
// counters, the directory that attributes it, and the model time a rate is
// taken over.
test "session record carries one response's counters, cwd and model time" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const arena = state.allocator();

    var result: chat.ChatResult = .{};
    result.prompt_tokens = 910;
    result.cached_tokens = 832;
    result.completion_tokens = 18;
    result.reasoning_tokens = 0;
    result.total_tokens = 928;
    result.finish_reason = try arena.dupe(u8, "stop");

    const line = try sessionRecord(arena, 1759000000000, "/home/me/proj", "deepseek/deepseek-v4-flash", 1234, &result);
    try std.testing.expectEqualStrings(
        "{\"ts\":1759000000000,\"cwd\":\"/home/me/proj\",\"model\":\"deepseek/deepseek-v4-flash\"," ++
            "\"finish_reason\":\"stop\",\"elapsed_ms\":1234,\"usage\":{\"prompt_tokens\":910,\"cached_tokens\":832," ++
            "\"completion_tokens\":18,\"reasoning_tokens\":0,\"total_tokens\":928}}\n",
        line,
    );
}

test "session record escapes a directory that needs it" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    var result: chat.ChatResult = .{ .completion_tokens = 4 };
    const line = try sessionRecord(state.allocator(), 1, "/tmp/a\"b\\c", "m", 5, &result);
    try std.testing.expectEqualStrings(
        "{\"ts\":1,\"cwd\":\"/tmp/a\\\"b\\\\c\",\"model\":\"m\"," ++
            "\"finish_reason\":\"\"," ++
            "\"elapsed_ms\":5,\"usage\":{\"prompt_tokens\":0,\"cached_tokens\":0," ++
            "\"completion_tokens\":4,\"reasoning_tokens\":0,\"total_tokens\":0}}\n",
        line,
    );
}

// A run that starts twice, or two runs that start together, can read the same
// wall-clock stamp. The second one must write beside the first: truncating it
// would leave the store holding one run's records labelled as another's.
test "a repeated session log writes beside the first and never over it" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", arena);

    const first = createSessionLog(io, arena, dir, 1759000000000000000) orelse return error.TestUnexpectedResult;
    first.writeStreamingAll(io, "first\n") catch return error.TestUnexpectedResult;
    first.close(io);

    const second = createSessionLog(io, arena, dir, 1759000000000000000) orelse return error.TestUnexpectedResult;
    second.writeStreamingAll(io, "second\n") catch return error.TestUnexpectedResult;
    second.close(io);

    const kept = try tmp.dir.readFileAlloc(io, "1759000000000000000.jsonl", alloc, .limited(64));
    defer alloc.free(kept);
    try std.testing.expectEqualStrings("first\n", kept);
    const beside = try tmp.dir.readFileAlloc(io, "1759000000000000000-1.jsonl", alloc, .limited(64));
    defer alloc.free(beside);
    try std.testing.expectEqualStrings("second\n", beside);

    // The name space is finite and running out of it is a null, not a fall
    // back to the truncating open.
    var filled: usize = 2;
    while (filled < session_name_attempts) : (filled += 1) {
        const extra = createSessionLog(io, arena, dir, 1759000000000000000) orelse return error.TestUnexpectedResult;
        extra.close(io);
    }
    try std.testing.expect(createSessionLog(io, arena, dir, 1759000000000000000) == null);
    const survived = try tmp.dir.readFileAlloc(io, "1759000000000000000.jsonl", alloc, .limited(64));
    defer alloc.free(survived);
    try std.testing.expectEqualStrings("first\n", survived);
}

// A log that cannot be written to has stopped recording the run. Kept, it is
// one silent gap per turn in a store a monitor is reading; dropped, the run
// says once that the rest of it is unrecorded and stops writing to it.
test "a session log that cannot be written is dropped, not written to again" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Opened for reading, so every write to it is refused the way a full disk
    // or a removed directory refuses one.
    try tmp.dir.writeFile(io, .{ .sub_path = "read-only.jsonl", .data = "" });
    const file = try tmp.dir.openFile(io, "read-only.jsonl", .{ .mode = .read_only });

    var session: ?Session = .{ .file = file, .cwd = ".", .model = "test/model", .dir = "/sessions" };
    var result: chat.ChatResult = .{};
    result.prompt_tokens = 7;
    writeRecord(io, arena, &session, 1, &result);
    try std.testing.expect(session == null);

    // A second record has nowhere to go: the log was dropped, not retried.
    writeRecord(io, arena, &session, 2, &result);
    const empty = try tmp.dir.readFileAlloc(io, "read-only.jsonl", alloc, .limited(64));
    defer alloc.free(empty);
    try std.testing.expectEqualStrings("", empty);
}

/// The shape `run` has around its log: a mutable session for the turns in
/// between, and a close deferred until the run ends. A turn may drop the log
/// and close it, so the deferred close has to read the slot rather than a copy
/// taken when the defer was written.
fn sessionScope(io: Io, arena: std.mem.Allocator, session: ?Session) void {
    var live = session;
    defer close(io, &live);
    var result: chat.ChatResult = .{ .prompt_tokens = 1 };
    writeRecord(io, arena, &live, 1, &result);
}

// A deferred close that captured the session by value fires after
// `writeRecord` has already closed the handle, so the descriptor number
// is closed twice. In a debug build that trips the runtime's close-after-close
// check, and in a release one it closes whatever took the number next. Opening
// a file afterwards is what makes the second close visible: the kernel hands
// back the number the log held, and the stray close takes it away.
test "a run that drops its session log closes the handle once" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try tmp.dir.writeFile(io, .{ .sub_path = "read-only.jsonl", .data = "" });
    const file = try tmp.dir.openFile(io, "read-only.jsonl", .{ .mode = .read_only });
    const session: ?Session = .{ .file = file, .cwd = ".", .model = "test/model", .dir = "/sessions" };

    sessionScope(io, arena, session);

    const after = try tmp.dir.createFile(io, "after.jsonl", .{ .truncate = true });
    defer after.close(io);
    try after.writeStreamingAll(io, "kept");
    const kept = try tmp.dir.readFileAlloc(io, "after.jsonl", alloc, .limited(64));
    defer alloc.free(kept);
    try std.testing.expectEqualStrings("kept", kept);
}

// The session store is a per-run directory nothing used to delete from, so a
// long-lived machine accumulated one log per review forever. The bound is the
// behavior: oldest first, only this program's own files, recent runs kept.
test "the session store keeps the most recent logs and drops the rest" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = path_buf[0..try tmp.dir.realPath(io, &path_buf)];

    const total = max_session_logs + 25;
    var i: usize = 0;
    while (i < total) : (i += 1) {
        const name = try std.fmt.allocPrint(arena, "{d}.jsonl", .{i + 1});
        try tmp.dir.writeFile(io, .{ .sub_path = name, .data = "{}" });
    }
    // A file this program did not write is not ours to delete.
    try tmp.dir.writeFile(io, .{ .sub_path = "notes.jsonl", .data = "keep me" });

    pruneSessions(io, arena, dir_path);

    var dir = try std.Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(arena);
    defer walker.deinit();
    var left: usize = 0;
    var notes_present = false;
    while (try walker.next(io)) |entry| {
        if (!std.mem.endsWith(u8, entry.basename, ".jsonl")) continue;
        if (std.mem.eql(u8, entry.basename, "notes.jsonl")) {
            notes_present = true;
            continue;
        }
        left += 1;
    }
    try std.testing.expectEqual(max_session_logs, left);
    try std.testing.expect(notes_present);
    // The survivors are the newest, so a monitor still sees the current run.
    const newest = try std.fmt.allocPrint(arena, "{d}.jsonl", .{total});
    try tmp.dir.access(io, newest, .{});
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "1.jsonl", .{}));
}

// A re-run that reads the same clock stamp writes its log beside the first
// one under a `-N` name, and a store that only recognised `<digits>.jsonl`
// would keep every one of those forever while still reporting itself pruned.
// The names are created the way a run creates them, exclusive and in order, so
// the test exercises the real collision path rather than the pattern.
test "the session store prunes the logs a re-run wrote beside the first" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = path_buf[0..try tmp.dir.realPath(io, &path_buf)];

    var i: usize = 0;
    while (i < max_session_logs) : (i += 1) {
        const log = createSessionLog(io, arena, dir_path, @intCast(i + 1)) orelse return error.TestUnexpectedResult;
        log.close(io);
        // Every run here is a re-run of the one before it: the same stamp, so
        // the log goes beside the first rather than over it.
        const beside = createSessionLog(io, arena, dir_path, @intCast(i + 1)) orelse return error.TestUnexpectedResult;
        beside.close(io);
    }
    try std.testing.expectEqual(max_session_logs * 2, countSessionLogs(io, arena, dir_path));

    pruneSessions(io, arena, dir_path);

    try std.testing.expectEqual(max_session_logs, countSessionLogs(io, arena, dir_path));
    // The oldest stamp is gone entirely, the newest is still there in both of
    // its names, so the monitor reading the store still sees this run.
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "1.jsonl", .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "1-1.jsonl", .{}));
    const newest = try std.fmt.allocPrint(arena, "{d}.jsonl", .{max_session_logs});
    try tmp.dir.access(io, newest, .{});
    const newest_beside = try std.fmt.allocPrint(arena, "{d}-1.jsonl", .{max_session_logs});
    try tmp.dir.access(io, newest_beside, .{});
}

/// How many of the store's own logs are there, by the same rule `pruneSessions`
/// prunes by, so the count a test asserts is the count the pruner sees.
fn countSessionLogs(io: Io, arena: std.mem.Allocator, session_dir: []const u8) !usize {
    var dir = try std.Io.Dir.openDirAbsolute(io, session_dir, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(arena);
    defer walker.deinit();
    var n: usize = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (isSessionLogName(entry.basename)) n += 1;
    }
    return n;
}

// Pruning walks the store, so a file that only shares a basename with a log is
// the case that decides whether it deletes a directory's contents by accident.
// This lived beside a second copy of the store in main, attached to code the
// run no longer calls; the live one has the check and had no test for it.
test "a log in a subdirectory is pruned where it is, not by its bare name" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = path_buf[0..try tmp.dir.realPath(io, &path_buf)];

    try tmp.dir.createDirPath(io, "0archive");
    const total = max_session_logs + 1;
    var i: usize = 0;
    while (i < total) : (i += 1) {
        const nested = i == 0;
        const name = if (nested) "0archive/1.jsonl" else try std.fmt.allocPrint(arena, "{d}.jsonl", .{i + 1});
        try tmp.dir.writeFile(io, .{ .sub_path = name, .data = "log" });
    }

    pruneSessions(io, arena, dir_path);

    // The oldest is the nested one, and it goes where it is: counted, deleted,
    // and the root's own `1.jsonl` is still a name the store holds.
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "0archive/1.jsonl", .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "1.jsonl", .{}));
    try tmp.dir.access(io, try std.fmt.allocPrint(arena, "{d}.jsonl", .{total}), .{});
    var left: usize = 0;
    {
        var dir = try std.Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true });
        defer dir.close(io);
        var walker = try dir.walk(arena);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind == .file and isSessionLogName(entry.basename)) left += 1;
        }
    }
    try std.testing.expectEqual(max_session_logs, left);
}
