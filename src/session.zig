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
/// so does a home that is not there. The variable is read rather than trimmed
/// by the caller because an empty one means off here instead of falling through
/// to $HOME, but it is trimmed the same way every other variable is: a wrapper
/// that populates the environment from a file exports the newline that file
/// ended with, and a directory name carrying one is a directory the run creates
/// and the monitor never looks in, so the log it keeps is a log nobody reads.
/// Takes the environment map rather than the whole `Init`, so the precedence is
/// testable without one.
pub fn sessionDir(env: *const std.process.Environ.Map, arena: std.mem.Allocator) []const u8 {
    if (env.get("MICROAGENT_SESSION_DIR")) |v| return std.mem.trim(u8, v, net.env_surrounding);
    const home = net.homeDir(env) orelse return "";
    return std.fs.path.join(arena, &.{ home, ".microagent", "sessions" }) catch "";
}

test "the session directory is trimmed, and an empty one turns the log off" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const arena = state.allocator();

    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();

    try env.put("HOME", "/home/me");
    try std.testing.expectEqualStrings("/home/me/.microagent/sessions", sessionDir(&env, arena));

    // The home itself is trimmed like every other variable, so the newline a
    // wrapper exported from a file does not name a directory the run creates
    // and no monitor looks in. An empty one is no home rather than a path off
    // the root.
    try env.put("HOME", "/home/me\n");
    try std.testing.expectEqualStrings("/home/me/.microagent/sessions", sessionDir(&env, arena));
    try env.put("HOME", "  ");
    try std.testing.expectEqualStrings("", sessionDir(&env, arena));
    try env.put("HOME", "/home/me");

    try env.put("MICROAGENT_SESSION_DIR", "/var/log/ma\n");
    try std.testing.expectEqualStrings("/var/log/ma", sessionDir(&env, arena));

    // Empty is the switch that turns the log off, not a request for the
    // default: a caller who turned it off must not find a log under $HOME.
    try env.put("MICROAGENT_SESSION_DIR", "");
    try std.testing.expectEqualStrings("", sessionDir(&env, arena));

    try env.put("MICROAGENT_SESSION_DIR", "  ");
    try std.testing.expectEqualStrings("", sessionDir(&env, arena));

    // No home and no variable: there is nowhere to put the log, and no error.
    var bare: std.process.Environ.Map = .init(std.testing.allocator);
    defer bare.deinit();
    try std.testing.expectEqualStrings("", sessionDir(&bare, arena));
}

/// One session log per run, one JSONL record per model response, which is what
/// a monitor (toktop) reads to report this run's tokens per second while it is
/// still going. Nothing depends on it, so every failure here is a null rather
/// than an error: a read-only home costs a run nothing. A null is still named
/// on stderr, because a directory the caller named and no log appeared in it
/// is a store a monitor is reading that will stay empty, and the run is the
/// only place that can say so.
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

/// The mode a session log is created with, and the mode its directory is
/// created with when the run is the one that made the directory.
///
/// A log is the run's transcript: the prompts, the tool arguments and every
/// byte a tool read out of the tree, which is exactly the material the tools
/// themselves refuse to hand the provider. The default file mode is
/// 0o666 less the umask, so on the 0o022 an ordinary account carries, a log
/// lands world-readable under `$HOME`, and every other account and every other
/// process on the machine can read the last 200 runs. The directory is the
/// other half of the same question: a 0o755 one exposes the names of the logs
/// even where the logs themselves are not readable, and it is the directory
/// the run creates out of nothing on a fresh account. Neither mode is applied
/// to a directory that already exists, so an operator who pointed
/// MICROAGENT_SESSION_DIR at a shared store keeps the mode they gave it.
const log_file_mode: Io.File.Permissions = @enumFromInt(@as(std.posix.mode_t, 0o600));
const log_dir_mode: Io.File.Permissions = @enumFromInt(@as(std.posix.mode_t, 0o700));

/// This run's log, under a name nothing already holds.
///
/// The wall clock is settable, so its stamp is not a claim on a file: two runs
/// can read the same nanosecond, and one that is re-launched shortly after a
/// previous one can. Creating the file without `exclusive` would truncate the
/// log already sitting there, so a second run would erase the first run's
/// usage records, which is the whole reason the log exists. Every name is
/// opened exclusively and a taken one moves to the next, so a repeat run writes
/// beside the first rather than over it.
///
/// The failure that is not a taken name is said. Running out of the name
/// attempts needs a clock that repeats the same nanosecond
/// `session_name_attempts` times, which the operator can do something about and
/// a silent log cannot show, so it is named here like any other failure to open
/// a log.
fn createSessionLog(io: Io, arena: std.mem.Allocator, session_dir: []const u8, stamp: u128) ?Io.File {
    // The directory the notes below name is `MICROAGENT_SESSION_DIR` or a
    // path under `$HOME`: whatever the shell, a wrapper script or a container
    // image put there. It is escaped once here rather than at every call site,
    // so a value carrying an escape sequence, or a byte that is not text,
    // reaches the operator's terminal as the characters it is.
    const shown = chat.safeTextAll(arena, session_dir);
    var attempt: usize = 0;
    while (attempt < session_name_attempts) : (attempt += 1) {
        var suffix_buf: [4]u8 = undefined;
        // A name this program cannot spell or cannot join is a failure like any
        // other one to open the log, and the doc above promises it is named.
        // The three silent nulls this replaces left a monitor reading a store
        // that stayed empty with nothing on stderr to say why.
        const suffix = if (attempt == 0) "" else std.fmt.bufPrint(&suffix_buf, "-{d}", .{attempt}) catch |err| {
            net.note(io, arena, "microagent: a session log name under {s} could not be built ({s}); this run records no usage\n", .{ shown, @errorName(err) });
            return null;
        };
        const name = std.fmt.allocPrint(arena, "{d}{s}.jsonl", .{ stamp, suffix }) catch |err| {
            net.note(io, arena, "microagent: a session log name under {s} could not be built ({s}); this run records no usage\n", .{ shown, @errorName(err) });
            return null;
        };
        const path = std.fs.path.join(arena, &.{ session_dir, name }) catch |err| {
            net.note(io, arena, "microagent: a session log path under {s} could not be built ({s}); this run records no usage\n", .{ shown, @errorName(err) });
            return null;
        };
        return std.Io.Dir.createFileAbsolute(io, path, .{ .exclusive = true, .permissions = log_file_mode }) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => |e| {
                net.note(io, arena, "microagent: a session log under {s} could not be created ({s}); this run records no usage\n", .{ shown, @errorName(e) });
                return null;
            },
        };
    }
    net.note(io, arena, "microagent: {d} session log names under {s} were already taken; this run records no usage\n", .{ session_name_attempts, shown });
    return null;
}

/// This run's log, or null when the run asked for none. Takes the directory
/// and the model rather than the caller's whole options, so the log's contract
/// with the loop is the two values a record needs and nothing else.
///
/// A null costs the run nothing, but a run whose log is off is a run a monitor
/// cannot follow, and the two ways it goes off look the same from outside: a
/// store the caller turned off, and a store this run could not open. Only the
/// second is said, so an operator whose watch shows nothing learns which of the
/// two it is.
pub fn open(io: Io, arena: std.mem.Allocator, session_dir: []const u8, model: []const u8) ?Session {
    if (session_dir.len == 0) return null;
    // Every record names the directory it ran in. That is what attributes the
    // record to one review: the store is machine-wide, and a monitor skips a
    // record that names no directory rather than billing it to whichever
    // watcher happens to read the store. It comes from the run arena because a
    // directory that is resolved and then not used, by a log that could not be
    // opened, has no owner to free it.
    // Escaped once for the notes below, for the reason `createSessionLog`
    // gives: the directory is a variable or a path under `$HOME`, and a value
    // that is not text is written as the characters it is.
    const shown = chat.safeTextAll(arena, session_dir);
    const cwd = std.Io.Dir.cwd().realPathFileAlloc(io, ".", arena) catch |err| {
        net.note(io, arena, "microagent: the working directory could not be read ({s}), so no session log is kept under {s}\n", .{ @errorName(err), shown });
        return null;
    };
    _ = std.Io.Dir.cwd().createDirPathStatus(io, session_dir, log_dir_mode) catch |err| {
        net.note(io, arena, "microagent: the session directory {s} could not be created ({s}); the rest of this run is not recorded\n", .{ shown, @errorName(err) });
        return null;
    };
    const now_ns = Io.Clock.real.now(io).nanoseconds;
    // A clock set before 1970 reads a negative stamp, and a name that begins
    // with `-` is one `logName` refuses to parse, so the log would be written
    // and never pruned. Zero sorts as the oldest name, which is the order a
    // stamp saying nothing about the time should have.
    const stamp: u128 = if (now_ns < 0) 0 else @intCast(now_ns);
    const file = createSessionLog(io, arena, session_dir, stamp) orelse {
        net.note(io, arena, "microagent: no session log could be opened under {s}; the rest of this run is not recorded\n", .{shown});
        return null;
    };
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

/// The two numbers a log's name is made of: the clock stamp of the run, and
/// the `-N` a run that read the same stamp was given rather than the first
/// one's log.
const LogName = struct {
    stamp: u128,
    attempt: usize,

    /// Whether `self` is the older of the two by the numbers a name carries.
    /// The pruner breaks a tie on the path, which a name alone cannot say, so
    /// a harness holding only names compares keys that may well be equal.
    fn olderThan(self: LogName, other: LogName) bool {
        if (self.stamp != other.stamp) return self.stamp < other.stamp;
        return self.attempt < other.attempt;
    }
};

/// The numbers behind a name `createSessionLog` could have written, or null
/// for anything else. The suffixed names matter as much as the plain ones here:
/// a machine whose clock repeats a stamp is exactly the machine whose store
/// fills with the logs a re-run wrote beside the first, and a retention window
/// that skipped them would bound nothing on it.
///
/// A stamp too wide for the parse is not a name this program wrote, so it is
/// left alone rather than deleted as though it were ours.
fn logName(name: []const u8) ?LogName {
    if (!std.mem.endsWith(u8, name, ".jsonl")) return null;
    const stem = name[0 .. name.len - ".jsonl".len];
    const dash = std.mem.indexOfScalar(u8, stem, '-');
    const stamp_text = if (dash) |at| stem[0..at] else stem;
    const attempt_text = if (dash) |at| stem[at + 1 ..] else "";
    if (!allDigits(stamp_text)) return null;
    // A dash is the start of an attempt number, so it is only a dash this
    // program wrote when a number follows it: `createSessionLog` never writes
    // a trailing dash. Without that, `5-.jsonl` parsed as the plain log for
    // stamp 5 and the retention window deleted it, and a name this program
    // never wrote is not the pruner's to delete however old it looks.
    if (dash != null and !allDigits(attempt_text)) return null;
    return .{
        .stamp = std.fmt.parseInt(u128, stamp_text, 10) catch return null,
        .attempt = if (attempt_text.len == 0) 0 else std.fmt.parseInt(usize, attempt_text, 10) catch return null,
    };
}

/// Deletes the oldest logs past `max_session_logs`. The oldest is read off the
/// numbers the name carries rather than off its bytes: `-` sorts below every
/// digit and a short stamp sorts below a long one, so a lexicographic sort puts
/// a re-run's `<stamp>-1.jsonl` ahead of the `<stamp>.jsonl` that was written
/// before it, and hands the retention window the wrong file of the pair. Only
/// this program's own `<digits>[-<digits>].jsonl` files are touched.
///
/// A walk that fails part way through leaves a list of only the names it
/// reached, and pruning from that list is not a smaller prune: the entries
/// still standing are the ones the walk never saw, so the files deleted are
/// whichever of the seen ones sort lowest rather than the oldest ones in the
/// store. The whole pass is abandoned instead, and the run is told, because a
/// store that keeps growing is a cost while logs this run did not mean to
/// delete are the data.
///
/// A delete that fails is the same failure with no way to see it: the count
/// still drops by one, so the store looks pruned and is not, and it happens
/// again on the next run. The failures are counted and named once.
///
/// Through the cwd, the way `open` creates the directory and `createSessionLog`
/// creates the log: `MICROAGENT_SESSION_DIR=logs/x` is a legal value, and a
/// reader that insists the path is absolute turns it into a panic in a checked
/// build.
fn pruneSessions(io: Io, arena: std.mem.Allocator, session_dir: []const u8) void {
    pruneSessionsTo(io, arena, session_dir, max_session_logs);
}

/// The note for a list the walk could not finish, however far it got: a read
/// that failed, a name that would not copy, an entry that would not fit. All
/// three leave the same thing behind, a partial list, and all three are
/// abandoned the same way, because pruning from a partial list is not a smaller
/// prune: the entries still standing are the ones the walk never saw, so the
/// files deleted would be whichever of the seen ones sort lowest rather than
/// the oldest in the store. The note carries the count so an operator reading
/// it can tell an empty store from one this run walked for a while, and it is
/// one function so the three cannot drift into three different sentences.
/// `shown` is the escaped directory, which every note in the pruner shares.
fn partialList(io: Io, arena: std.mem.Allocator, shown: []const u8, seen: usize, err: anyerror) void {
    net.note(io, arena, "microagent: the session store under {s} could not be listed past {d} of its logs ({s}); nothing is pruned, because pruning from a partial list would delete whichever logs it saw rather than the oldest ones\n", .{
        shown, seen, @errorName(err),
    });
}

/// The pruner, with the window it keeps as an argument rather than a constant,
/// so the fuzz harness can put a handful of names over a window of two and
/// check what the delete loop does with them.
fn pruneSessionsTo(io: Io, arena: std.mem.Allocator, session_dir: []const u8, keep: usize) void {
    // Escaped once for the two notes below, for the reason `createSessionLog`
    // gives: the directory is a variable or a path under `$HOME`.
    const shown = chat.safeTextAll(arena, session_dir);
    var dir = std.Io.Dir.openDir(std.Io.Dir.cwd(), io, session_dir, .{ .iterate = true }) catch |err| {
        net.note(io, arena, "microagent: the session store under {s} could not be read for pruning ({s}); it is not pruned and is left as it stands\n", .{ shown, @errorName(err) });
        return;
    };
    defer dir.close(io);

    const Found = struct { path: []u8, key: LogName };
    var found: std.ArrayList(Found) = .empty;
    defer {
        for (found.items) |f| arena.free(f.path);
        found.deinit(arena);
    }
    // The walk is scoped: the walker holds the directory handle, and deleting
    // through `dir` while it is still open closes that handle under it.
    {
        var walker = dir.walk(arena) catch |err| {
            net.note(io, arena, "microagent: the session store under {s} could not be walked for pruning ({s}); it is not pruned and is left as it stands\n", .{ shown, @errorName(err) });
            return;
        };
        defer walker.deinit();
        while (true) {
            const entry = walker.next(io) catch |err| {
                partialList(io, arena, shown, found.items.len, err);
                return;
            } orelse break;
            if (entry.kind != .file) continue;
            const key = logName(entry.basename) orelse continue;
            // What is kept is the path from the store's root, not the basename.
            // The walker enters every subdirectory it meets, and a basename
            // deleted through the root either removes nothing or removes a
            // different file with the same name, while still counting toward
            // the limit: the store then looks pruned and is not.
            const path_copy = arena.dupe(u8, entry.path) catch |err| {
                partialList(io, arena, shown, found.items.len, err);
                return;
            };
            found.append(arena, .{ .path = path_copy, .key = key }) catch |err| {
                arena.free(path_copy);
                partialList(io, arena, shown, found.items.len, err);
                return;
            };
        }
    }
    if (found.items.len <= keep) return;

    std.mem.sort(Found, found.items, {}, struct {
        fn lessThan(_: void, a: Found, b: Found) bool {
            if (a.key.olderThan(b.key)) return true;
            if (b.key.olderThan(a.key)) return false;
            return std.mem.order(u8, a.path, b.path) == .lt;
        }
    }.lessThan);

    var i: usize = 0;
    var failed: usize = 0;
    var first_err: ?anyerror = null;
    while (i < found.items.len - keep) : (i += 1) {
        dir.deleteFile(io, found.items[i].path) catch |err| {
            failed += 1;
            if (first_err == null) first_err = err;
        };
    }
    if (failed != 0) net.note(io, arena, "microagent: {d} of {d} session logs under {s} could not be deleted ({s}); the store is over its {d}-log limit and stays that way until they can be\n", .{
        failed, found.items.len - keep, shown, @errorName(first_err.?), keep,
    });
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
/// why `open` can stay quiet. A failure to *write* one is different: the
/// log was there, the run is producing records, and a store that has gone quiet
/// (a full disk, a directory removed under the run) would otherwise leave the
/// monitor reporting a run that stopped long before it did. It is named once and
/// the log is dropped, so the run is not left appending to a file nothing reads
/// and saying nothing about the gap.
pub fn writeRecord(io: Io, arena: std.mem.Allocator, session: *?Session, elapsed_ms: u64, result: *const chat.ChatResult) void {
    const s = session.* orelse return;
    // `s.dir` is the directory the run was given, escaped for the reason
    // `createSessionLog` gives.
    const shown = chat.safeTextAll(arena, s.dir);
    const ts_ms: i64 = @intCast(@divTrunc(Io.Clock.real.now(io).nanoseconds, std.time.ns_per_ms));
    const line = sessionRecord(arena, ts_ms, s.cwd, s.model, elapsed_ms, result) catch |err| {
        net.note(io, arena, "microagent: a session record for {s} could not be built ({s}); the rest of this run is not recorded\n", .{ shown, @errorName(err) });
        s.file.close(io);
        session.* = null;
        return;
    };
    s.file.writeStreamingAll(io, line) catch |err| {
        net.note(io, arena, "microagent: the session log under {s} could not be written ({s}); the rest of this run is not recorded\n", .{ shown, @errorName(err) });
        s.file.close(io);
        session.* = null;
    };
}

/// The parts of a session record that do not vary with the strings in it: the
/// keys, the punctuation, and the numbers. Not derived from the format string
/// so it cannot go stale against it; it is a reservation, and the buffer's
/// growth ladder still covers a record that outgrows it.
const session_record_scaffolding_bytes = 512;

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
    // Sized from the three strings the record carries, so it is allocated once
    // rather than doubling up to a few hundred bytes on a ladder of copies.
    // Escape expansion can still push it past this, which the ladder handles.
    var jb = chat.JsonBuf.initCapacity(allocator, session_record_scaffolding_bytes +
        cwd.len + model.len + result.finish_reason.len);
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

test "the session directory is the variable, trimmed, and empty means off" {
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    // The caller's arena: the joined default path is owned by the process
    // init, which outlives every run, so nothing here frees it.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Unset: the store sits beside the other per-run state, and a machine with
    // no HOME keeps no log rather than naming a directory it cannot make.
    try env.put("HOME", "/home/me");
    try std.testing.expectEqualStrings("/home/me/.microagent/sessions", sessionDir(&env, arena));
    var empty: std.process.Environ.Map = .init(std.testing.allocator);
    defer empty.deinit();
    try std.testing.expectEqualStrings("", sessionDir(&empty, arena));

    // Set: the caller's directory, and empty is off rather than a fall through
    // to the default, which is what makes MICROAGENT_SESSION_DIR one of the two
    // variables that do not treat an empty value as unset.
    try env.put("MICROAGENT_SESSION_DIR", "/var/log/agent");
    try std.testing.expectEqualStrings("/var/log/agent", sessionDir(&env, arena));
    try env.put("MICROAGENT_SESSION_DIR", "");
    try std.testing.expectEqualStrings("", sessionDir(&env, arena));

    // A wrapper that populates the environment from a file exports the newline
    // the file ended with, and a path carrying it names no directory this
    // filesystem holds: the log is not written and the run says nothing.
    try env.put("MICROAGENT_SESSION_DIR", "  /var/log/agent \r\n");
    try std.testing.expectEqualStrings("/var/log/agent", sessionDir(&env, arena));
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

// A directory the caller named and that no log lands in is a store a monitor
// reads that stays empty for the whole run, and the run is the only place that
// can say so. Every one of these is a null, and every one of them names itself.
test "a session directory that cannot be used is named, and keeps no log" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // The store sits under the test's own temporary directory, which is under
    // the working directory, so the relative spelling a run is given reaches it
    // and the cleanup takes it with the rest.
    const store = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    // Off is not a failure and says nothing: the caller asked for no log.
    try std.testing.expect(open(io, arena, "", "test/model") == null);

    // A store no filesystem will hold: a name longer than a path component is
    // allowed to be, so the directory cannot be made and no log is kept. The
    // caller named it, so the run says which one rather than losing the log
    // quietly.
    const long_name = try arena.alloc(u8, 300);
    @memset(long_name, 'x');
    const blocked = try std.fs.path.join(arena, &.{ store, long_name });
    try std.testing.expect(open(io, arena, blocked, "test/model") == null);

    // The same path a run can use, so the null above is the directory and not
    // the shape of the call.
    const usable = try std.fs.path.join(arena, &.{ store, "sessions" });
    var session: ?Session = open(io, arena, usable, "test/model") orelse return error.TestUnexpectedResult;
    defer close(io, &session);
    writeRecord(io, arena, &session, 12, &.{});
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

/// A store directory of this program's own, in a temporary directory that
/// cleans itself up, with the arena and the threaded io the store calls need.
/// The setup every store test below shares: what varies between them is what
/// they put in the directory and what they then prune or open.
const StoreFixture = struct {
    arena_state: std.heap.ArenaAllocator,
    threaded: std.Io.Threaded,
    tmp: std.testing.TmpDir,
    path_buf: [std.fs.max_path_bytes]u8 = undefined,

    fn init(gpa: std.mem.Allocator) !StoreFixture {
        return .{
            .arena_state = std.heap.ArenaAllocator.init(gpa),
            .threaded = std.Io.Threaded.init(gpa, .{}),
            .tmp = std.testing.tmpDir(.{}),
        };
    }

    fn deinit(self: *StoreFixture) void {
        self.tmp.cleanup();
        self.threaded.deinit();
        self.arena_state.deinit();
    }

    fn io(self: *StoreFixture) Io {
        return self.threaded.io();
    }

    fn arena(self: *StoreFixture) std.mem.Allocator {
        return self.arena_state.allocator();
    }

    /// The absolute path of the temporary directory, which is where a store
    /// test writes its logs.
    fn path(self: *StoreFixture) ![]const u8 {
        return self.path_buf[0..try self.tmp.dir.realPath(self.io(), &self.path_buf)];
    }
};

// The session store is a per-run directory nothing used to delete from, so a
// long-lived machine accumulated one log per review forever. The bound is the
// behavior: oldest first, only this program's own files, recent runs kept.
test "the session store keeps the most recent logs and drops the rest" {
    var store = try StoreFixture.init(std.testing.allocator);
    defer store.deinit();
    const io = store.io();
    const arena = store.arena();
    const dir_path = try store.path();

    const total = max_session_logs + 25;
    var i: usize = 0;
    while (i < total) : (i += 1) {
        const name = try std.fmt.allocPrint(arena, "{d}.jsonl", .{i + 1});
        try store.tmp.dir.writeFile(io, .{ .sub_path = name, .data = "{}" });
    }
    // A file this program did not write is not ours to delete.
    try store.tmp.dir.writeFile(io, .{ .sub_path = "notes.jsonl", .data = "keep me" });
    // A dash with no attempt number after it is one of those, and it is the
    // case a name-shaped check gets wrong: read as a plain log it sorts into
    // the window as the oldest thing in the store, so a name no run of this
    // program ever wrote is the first one the retention window removes.
    try store.tmp.dir.writeFile(io, .{ .sub_path = "1-.jsonl", .data = "keep me too" });

    pruneSessions(io, arena, dir_path);

    try std.testing.expectEqual(max_session_logs, try countSessionLogs(io, arena, dir_path));
    try store.tmp.dir.access(io, "notes.jsonl", .{});
    try store.tmp.dir.access(io, "1-.jsonl", .{});
    // The survivors are the newest, so a monitor still sees the current run.
    const newest = try std.fmt.allocPrint(arena, "{d}.jsonl", .{total});
    try store.tmp.dir.access(io, newest, .{});
    try std.testing.expectError(error.FileNotFound, store.tmp.dir.access(io, "1.jsonl", .{}));
}

// `MICROAGENT_SESSION_DIR=logs/x` names a store through the working directory,
// and `open` creates it and its log that way, so pruning has to read it the
// same way rather than insist on an absolute path the caller never promised.
test "a store named relative to the working directory is pruned where it is" {
    var store = try StoreFixture.init(std.testing.allocator);
    defer store.deinit();
    const io = store.io();
    const arena = store.arena();

    // The store sits under the test's own temporary directory, which is under
    // the working directory, so the same relative spelling a run would be given
    // reaches it, and the cleanup takes it with the rest.
    const relative = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}/store", .{store.tmp.sub_path});
    try store.tmp.dir.createDirPath(io, "store");
    var i: usize = 0;
    while (i < max_session_logs + 1) : (i += 1) {
        const log = createSessionLog(io, arena, relative, @intCast(i + 1)) orelse return error.TestUnexpectedResult;
        log.close(io);
    }

    pruneSessions(io, arena, relative);

    try std.testing.expectEqual(max_session_logs, try countRelativeSessionLogs(io, arena, relative));
}

// The mode a log and the directory holding it are created with. The log is the
// run's transcript, so what a mode that leaves the file readable to every
// other account on the machine gives away is everything the tools went to the
// trouble of not printing. The mode is asserted through the real `open` and
// `createSessionLog`, because a mode named in a test and not applied is a test
// that passes on a code that never had it.
test "a session log is readable by its owner alone" {
    var store = try StoreFixture.init(std.testing.allocator);
    defer store.deinit();
    const io = store.io();
    const arena = store.arena();
    const relative = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}/modes", .{store.tmp.sub_path});

    var session = open(io, arena, relative, "test/model") orelse return error.TestUnexpectedResult;
    session.file.close(io);
    defer std.Io.Dir.cwd().deleteTree(io, relative) catch {};

    // The store the run made for itself, and the log it wrote in it.
    const dir_stat = try std.Io.Dir.cwd().statFile(io, relative, .{});
    try std.testing.expectEqual(@as(u32, 0), dir_stat.permissions.toMode() & group_other_mode_bits);

    // The log is named after the run's own clock stamp, so it is found by
    // walking the store rather than by spelling a name a test cannot know.
    var store_dir = try std.Io.Dir.openDir(std.Io.Dir.cwd(), io, relative, .{ .iterate = true });
    defer store_dir.close(io);
    var walker = try store_dir.walk(arena);
    defer walker.deinit();
    const entry = (try walker.next(io)) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(Io.File.Kind.file, entry.kind);

    var name_buf: [std.fs.max_path_bytes]u8 = undefined;
    const log_path = try std.fmt.bufPrint(&name_buf, "{s}/{s}", .{ relative, entry.basename });
    const log_stat = try std.Io.Dir.cwd().statFile(io, log_path, .{});
    try std.testing.expectEqual(@as(u32, 0), log_stat.permissions.toMode() & group_other_mode_bits);
    try std.testing.expect(log_stat.permissions.toMode() & owner_mode_bits == owner_mode_bits);
}

/// The group and other permission bits, the ones a shared machine reads
/// through. Named so the assertion above says what it is refusing rather than
/// repeating a mode as a decimal.
const group_other_mode_bits: u32 = 0o077;
/// The owner's read and write, which a log whose owner cannot open is no
/// better than one everybody can.
const owner_mode_bits: u32 = 0o600;

// The directory the notes name and the directory the log is created in are the
// same path spelled two ways, because the first goes through `safeText` and the
// second must not: a store whose name carries an escape sequence (a shell, a
// wrapper script or a container image named it) is written where it was asked
// for, and the escaping is only ever what a diagnostic prints.
test "a store whose name is not plain text is created where it was named" {
    var store = try StoreFixture.init(std.testing.allocator);
    defer store.deinit();
    const io = store.io();
    const arena = store.arena();

    const hostile = try std.fs.path.join(arena, &.{ try store.path(), "s\x1b[2J\xffstore" });
    var live: ?Session = open(io, arena, hostile, "test/model") orelse return error.TestUnexpectedResult;
    defer close(io, &live);

    // The log is under the real name, with the escape sequence and the byte
    // that is not text in it: the escaping a note applies never reached a path
    // the filesystem was asked about.
    var dir = try std.Io.Dir.openDirAbsolute(io, hostile, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(arena);
    defer walker.deinit();
    var logs: usize = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.basename, ".jsonl")) logs += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), logs);

    // And the escaped spelling, which is what a note about that store prints,
    // carries none of it.
    const shown = chat.safeTextAll(arena, hostile);
    for (shown) |c| try std.testing.expect(c >= 0x20 and c != 0x7f);
    try std.testing.expect(std.mem.indexOf(u8, shown, "\\x1b") != null);
    try std.testing.expect(std.mem.indexOf(u8, shown, "\u{fffd}") != null);
}

// A re-run that reads the same clock stamp writes its log beside the first
// one under a `-N` name, and a store that only recognised `<digits>.jsonl`
// would keep every one of those forever while still reporting itself pruned.
// The names are created the way a run creates them, exclusive and in order, so
// the test exercises the real collision path rather than the pattern.
// A stamp is a number, so the window that keeps the newest `max_session_logs`
// reads it as one, and reads the `-N` beside it as the second number it is.
// Sorted as bytes instead, `-` (0x2d) sorts below `.` (0x2e), so the re-run's
// `<stamp>-1.jsonl` looks older than the `<stamp>.jsonl` written before it: the
// window cuts between the pair and deletes the log of the run that happened
// second, keeping the older of the two as the newest.
test "the session store prunes by stamp, not by the bytes of the name" {
    var store = try StoreFixture.init(std.testing.allocator);
    defer store.deinit();
    const io = store.io();
    const arena = store.arena();
    const dir_path = try store.path();

    // Stamps 3 through 202, then a re-run that read the oldest of them again,
    // so the one file over the limit is the second half of that oldest pair.
    var i: usize = 0;
    while (i < max_session_logs) : (i += 1) {
        const log = createSessionLog(io, arena, dir_path, @intCast(i + 3)) orelse return error.TestUnexpectedResult;
        log.close(io);
    }
    const rerun = createSessionLog(io, arena, dir_path, 3) orelse return error.TestUnexpectedResult;
    rerun.close(io);
    try std.testing.expectEqual(max_session_logs + 1, try countSessionLogs(io, arena, dir_path));

    pruneSessions(io, arena, dir_path);

    try std.testing.expectEqual(max_session_logs, try countSessionLogs(io, arena, dir_path));
    // The first of the pair is what goes; the run behind it is still the one a
    // monitor would read if it were the pair's last run.
    try std.testing.expectError(error.FileNotFound, store.tmp.dir.access(io, "3.jsonl", .{}));
    try store.tmp.dir.access(io, "3-1.jsonl", .{});
    // And the newest stamp is untouched.
    try store.tmp.dir.access(io, "202.jsonl", .{});
}

// A clock set before 1970 reads a negative number of nanoseconds, and a name
// spelled from one begins with `-`, which `logName` refuses: the log is written
// and then nothing ever counts it toward the retention window, so a machine
// whose clock is wrong in that direction grows the store without bound while
// still reporting itself pruned. The stamp `open` hands over is the oldest
// stamp there is rather than a negative one, so the log sorts and prunes like
// any other.
test "a log named from a clock before 1970 is still one the pruner counts" {
    var store = try StoreFixture.init(std.testing.allocator);
    defer store.deinit();
    const io = store.io();
    const arena = store.arena();
    const dir_path = try store.path();

    // The stamp `open` computes for a clock reading before the epoch.
    const before_epoch_ns: i128 = -1_000_000_000;
    const stamp: u128 = if (before_epoch_ns < 0) 0 else @intCast(before_epoch_ns);
    const log = createSessionLog(io, arena, dir_path, stamp) orelse return error.TestUnexpectedResult;
    log.close(io);
    try store.tmp.dir.access(io, "0.jsonl", .{});
    // The name a negative stamp would have produced is one the pruner does not
    // recognise, which is the whole reason the stamp is clamped.
    try std.testing.expect(logName("-1000000000.jsonl") == null);

    var i: usize = 0;
    while (i < max_session_logs) : (i += 1) {
        const filler = createSessionLog(io, arena, dir_path, @intCast(i + 3)) orelse return error.TestUnexpectedResult;
        filler.close(io);
    }
    pruneSessions(io, arena, dir_path);

    // The zero-stamped log is the oldest of the store, so it is the one the
    // window takes, and what is left is the limit rather than the limit plus
    // a log nothing was counting.
    try std.testing.expectError(error.FileNotFound, store.tmp.dir.access(io, "0.jsonl", .{}));
    try std.testing.expectEqual(max_session_logs, try countSessionLogs(io, arena, dir_path));
}

test "the session store prunes the logs a re-run wrote beside the first" {
    var store = try StoreFixture.init(std.testing.allocator);
    defer store.deinit();
    const io = store.io();
    const arena = store.arena();
    const dir_path = try store.path();

    var i: usize = 0;
    while (i < max_session_logs) : (i += 1) {
        const log = createSessionLog(io, arena, dir_path, @intCast(i + 1)) orelse return error.TestUnexpectedResult;
        log.close(io);
        // Every run here is a re-run of the one before it: the same stamp, so
        // the log goes beside the first rather than over it.
        const beside = createSessionLog(io, arena, dir_path, @intCast(i + 1)) orelse return error.TestUnexpectedResult;
        beside.close(io);
    }
    try std.testing.expectEqual(max_session_logs * 2, try countSessionLogs(io, arena, dir_path));

    pruneSessions(io, arena, dir_path);

    try std.testing.expectEqual(max_session_logs, try countSessionLogs(io, arena, dir_path));
    // The oldest stamp is gone entirely, the newest is still there in both of
    // its names, so the monitor reading the store still sees this run.
    try std.testing.expectError(error.FileNotFound, store.tmp.dir.access(io, "1.jsonl", .{}));
    try std.testing.expectError(error.FileNotFound, store.tmp.dir.access(io, "1-1.jsonl", .{}));
    const newest = try std.fmt.allocPrint(arena, "{d}.jsonl", .{max_session_logs});
    try store.tmp.dir.access(io, newest, .{});
    const newest_beside = try std.fmt.allocPrint(arena, "{d}-1.jsonl", .{max_session_logs});
    try store.tmp.dir.access(io, newest_beside, .{});
}

/// How many of the store's own logs are there, by the same rule `pruneSessions`
/// prunes by, so the count a test asserts is the count the pruner sees.
fn countSessionLogs(io: Io, arena: std.mem.Allocator, session_dir: []const u8) !usize {
    var dir = try std.Io.Dir.openDirAbsolute(io, session_dir, .{ .iterate = true });
    defer dir.close(io);
    return countLogsIn(dir, io, arena);
}

/// `countSessionLogs` for a store named relative to the working directory,
/// which `open` accepts and an absolute path would not exercise.
fn countRelativeSessionLogs(io: Io, arena: std.mem.Allocator, session_dir: []const u8) !usize {
    var dir = try std.Io.Dir.openDir(std.Io.Dir.cwd(), io, session_dir, .{ .iterate = true });
    defer dir.close(io);
    return countLogsIn(dir, io, arena);
}

fn countLogsIn(dir: Io.Dir, io: Io, arena: std.mem.Allocator) !usize {
    var walker = try dir.walk(arena);
    defer walker.deinit();
    var n: usize = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (logName(entry.basename) != null) n += 1;
    }
    return n;
}

// Pruning walks the store, so a file that only shares a basename with a log is
// the case that decides whether it deletes a directory's contents by accident.
test "a log in a subdirectory is pruned where it is, not by its bare name" {
    var store = try StoreFixture.init(std.testing.allocator);
    defer store.deinit();
    const io = store.io();
    const arena = store.arena();
    const dir_path = try store.path();

    try store.tmp.dir.createDirPath(io, "0archive");
    const total = max_session_logs + 1;
    var i: usize = 0;
    while (i < total) : (i += 1) {
        const nested = i == 0;
        const name = if (nested) "0archive/1.jsonl" else try std.fmt.allocPrint(arena, "{d}.jsonl", .{i});
        try store.tmp.dir.writeFile(io, .{ .sub_path = name, .data = "log" });
    }

    pruneSessions(io, arena, dir_path);

    // The oldest is the nested one, and it goes where it is: counted, deleted,
    // and the root's own `1.jsonl` is still a name the store holds. That root
    // name is the case the pruner can get wrong, a delete addressed by basename
    // alone taking it out along with the nested log, so the root names run from
    // `1` and the nested log is the only one past the limit. Seeded any other
    // way the assertion about it holds whether or not the two were told apart.
    try std.testing.expectError(error.FileNotFound, store.tmp.dir.access(io, "0archive/1.jsonl", .{}));
    try store.tmp.dir.access(io, "1.jsonl", .{});
    try store.tmp.dir.access(io, try std.fmt.allocPrint(arena, "{d}.jsonl", .{total - 1}), .{});
    try std.testing.expectEqual(max_session_logs, try countSessionLogs(io, arena, dir_path));
}

// A store that cannot be opened is a store that is not pruned, and nothing
// else in the run says so: the log this run writes goes on arriving, so the
// monitor sees a live run and a directory that is quietly over its limit, and
// every later run prunes nothing and says nothing. The reason is named instead.
test "a store that cannot be opened is named, and deletes nothing" {
    var store = try StoreFixture.init(std.testing.allocator);
    defer store.deinit();
    const io = store.io();
    const arena = store.arena();

    // A path nothing holds, under a directory that does exist, so the failure
    // is the store's and not a typo in the test's own temporary directory.
    const missing = try std.fs.path.join(arena, &.{ try store.path(), "not-a-store" });

    // The call the run makes. It returns rather than propagating, because a
    // store that cannot be pruned costs the run nothing but its disk; what
    // changed is that the run is told, so an operator watching the directory
    // fill knows to look.
    pruneSessions(io, arena, missing);
    try std.testing.expectError(error.FileNotFound, store.tmp.dir.access(io, "not-a-store", .{}));
}

// A run whose store cannot be created records nothing, and from outside a
// monitor sees the same thing as a run whose log was turned off. Only the
// first is a problem with the machine, so only the first is named.
test "a store that cannot be created gives the run no log rather than a silent one" {
    var store = try StoreFixture.init(std.testing.allocator);
    defer store.deinit();
    const io = store.io();
    const arena = store.arena();

    // A regular file where the store's directory should be. `createDirPath`
    // refuses it, and the run goes on with no log rather than a broken one.
    // The path is the one `open` is given: an absolute one, so nothing is
    // created outside this test's own temporary directory.
    try store.tmp.dir.writeFile(io, .{ .sub_path = "blocked", .data = "not a directory" });
    const blocked = try std.fmt.allocPrint(arena, "{s}{c}blocked{c}sessions", .{ try store.path(), std.fs.path.sep, std.fs.path.sep });

    try std.testing.expectEqual(@as(?Session, null), open(io, arena, blocked, "test/model"));
    // Still not a directory: the refusal left nothing behind for the next run
    // to walk into.
    const still_a_file = try store.tmp.dir.readFileAlloc(io, "blocked", arena, .limited(64));
    try std.testing.expectEqualStrings("not a directory", still_a_file);
}

// The names in a session store arrive on a directory walk rather than out of
// this program: `MICROAGENT_SESSION_DIR` can point the store anywhere, the walk
// enters every subdirectory it meets, and a tool call that ran with the store
// inside its reach leaves a name in it that no run wrote. `pruneSessions`
// deletes files, so the two properties a fuzzer can see are that a name this
// program would never have written is never deleted, and that what is left is
// the newest of the names it did write. Both numbers in a name are read with
// `parseInt`, and which of two names is older is a three-key comparison over
// them, so a seed that carries both spellings of a stamp and both sides of the
// `-N` pair is the shape that decides it.
//
// `std.testing.fuzz` runs this corpus on every `zig build test`, and through
// the fuzzer's mutations when the test binary is built in fuzz mode. One name
// per line, and a space is part of a name rather than a separator: a name with
// a space in it is a file a filesystem holds and a walk reports.
const store_name_corpus = [_][]const u8{
    "",
    "\n",
    "1.jsonl\n2.jsonl\n3.jsonl\n4.jsonl",
    "1.jsonl\n1-1.jsonl\n2.jsonl\n2-1.jsonl",
    "00012.jsonl\n12.jsonl\n12-0.jsonl\n12-1.jsonl\n13.jsonl",
    "1.jsonl\n10.jsonl\n2.jsonl\n9.jsonl",
    "1.jsonl\n1-9.jsonl\n1-10.jsonl\n1-11.jsonl",
    "0.jsonl\n00.jsonl\n0-0.jsonl\n0-1.jsonl",
    "notes.jsonl\n1.jsonl\n2.jsonl\nkeep.jsonl",
    "README\n1.jsonl\n2.jsonl\n3.jsonl",
    ".jsonl\n1.jsonl\n2.jsonl",
    "1.JSONL\n1.jsonl\n2.jsonl",
    "1.jsonl.bak\n1.jsonl\n2.jsonl",
    "1.jsonl\n-1.jsonl\n1-.jsonl\n1-1-.jsonl\n2.jsonl",
    "18446744073709551616.jsonl\n340282366920938463463374607431768211456.jsonl\n1.jsonl\n2.jsonl",
    "99999999999999999999999999999999999999.jsonl\n1.jsonl\n2.jsonl",
    "-1.jsonl\n+1.jsonl\n1 .jsonl\n 1.jsonl\n2.jsonl",
    "1.jsonl\n1.jsonl\n1.jsonl\n1.jsonl",
    "1.jsonl\n../../etc/passwd\n2.jsonl\n3.jsonl",
    "1.jsonl\n\u{65e5}\u{8a00}.jsonl\n2.jsonl\n3.jsonl",
    "1.jsonl\n2.jsonl\n3.jsonl\n4.jsonl\n5.jsonl\n6.jsonl\n7.jsonl\n8.jsonl",
};

test "a fuzzed store name is deleted only when the pruner wrote it" {
    try std.testing.fuzz({}, fuzzStoreNames, .{ .corpus = &store_name_corpus });
}

fn fuzzStoreNames(_: void, smith: *std.testing.Smith) !void {
    const gpa = std.testing.allocator;
    var scratch: [4 * 1024]u8 = undefined;
    const text: []const u8 = if (smith.in) |seed| seed else scratch[0..smith.slice(&scratch)];

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

    // A window small enough that a handful of names reaches past it, so the
    // delete loop runs on every iteration rather than on a rare one.
    const keep: usize = 3;

    const Written = struct { name: []const u8, key: ?LogName };
    var written: std.ArrayList(Written) = .empty;
    defer written.deinit(gpa);

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (written.items.len >= 16) break;
        // A name no filesystem holds never reaches the walk, so seeding one
        // says nothing about what the pruner does with what does.
        if (line.len == 0 or line.len > 255) continue;
        if (std.mem.indexOfAny(u8, line, "/\x00") != null) continue;
        if (std.mem.eql(u8, line, ".") or std.mem.eql(u8, line, "..")) continue;
        // A name written twice is one file, and counting it twice would make
        // the store look larger than it is.
        var seen = false;
        for (written.items) |w| {
            if (std.mem.eql(u8, w.name, line)) seen = true;
        }
        if (seen) continue;
        try tmp.dir.writeFile(io, .{ .sub_path = line, .data = "log" });
        try written.append(gpa, .{ .name = line, .key = logName(line) });
    }

    pruneSessionsTo(io, arena, dir_path, keep);

    // A name no run of this program wrote is not its to delete, whatever the
    // walk found beside it and wherever in the window it would have sorted.
    var survivors: std.ArrayList(Written) = .empty;
    defer survivors.deinit(gpa);
    var deleted: std.ArrayList(Written) = .empty;
    defer deleted.deinit(gpa);
    for (written.items) |w| {
        if (w.key == null) {
            try tmp.dir.access(io, w.name, .{});
            continue;
        }
        if (tmp.dir.access(io, w.name, .{})) |_| {
            try survivors.append(gpa, w);
        } else |_| {
            try deleted.append(gpa, w);
        }
    }

    // The window is on the store's own logs only: what is left is the window,
    // or the whole store when it never reached it.
    try std.testing.expectEqual(@min(keep, survivors.items.len + deleted.items.len), survivors.items.len);
    // And what is left is the newest of them, so no log that survived is older
    // than one that was deleted.
    for (deleted.items) |gone| {
        for (survivors.items) |kept| {
            try std.testing.expect(!keyOlder(kept.key.?, gone.key.?));
        }
    }
}

/// The order `pruneSessions` reads a name's two numbers in: the clock stamp
/// first, and the `-N` a re-run was given as the second. The pruner breaks a
/// tie on the path, which a name alone cannot say, so a harness that only has
/// names compares keys that may well be equal.
fn keyOlder(a: LogName, b: LogName) bool {
    return a.olderThan(b);
}

// A session record is the one thing this module writes for somebody else to
// read: a monitor opens the file mid-run and takes each line as a response. The
// strings in it came from outside the process (the model name off a request the
// program built, the finish reason out of the provider's stream), and the store
// is JSONL, so the property worth asserting is that whatever those strings are
// the record is still exactly one line and that line still reads back as the
// strings that went into it. A record that carried a newline would split into
// two lines the monitor reads as two responses, and a record that lost a
// character would bill a run for tokens it never spent.
//
// `std.testing.fuzz` runs this corpus on every `zig build test`, and through the
// fuzzer's mutations when the test binary is built in fuzz mode. The corpus
// carries the escapes, the controls and the malformed sequences a cut code
// point or a latin-1 file leaves behind, in the three fields together and in
// each on its own.
const session_record_corpus = [_][]const u8{
    "",
    "a",
    "\n",
    "\r\n\r\n",
    "\t\x00",
    "\x1b[2J\x1b[31m\x07",
    "quote\" backslash\\ newline\n tab\t",
    "{\"content\":\"already a record\"}",
    "caf\u{00e9}",
    "\u{65e5}\u{8a00}\u{1f600}",
    "\u{2028}\u{2029}",
    "/home/me/projects/\u{1f600}",
    "openai/gpt-4o\nstop",
    "openrouter/auto\nlength",
    "vendor/model\r\ntool_calls",
    "\xc3\n\xe6\x97\n\xf0\x9f",
    "\xed\xa0\x80\n\xf8\x88\x80\x80\x80",
    "\xff\xfe\n\xc2\n\xc3\x28",
    "ok\xff\ntool\xfe",
    "a\nb\nc\nd",
    "vendor/model-with-a-name-long-enough-to-push-the-record\nstop",
    "\x00" ** 32 ++ "\n" ++ "m" ** 32,
};

test "a fuzzed session record is one line that reads back as itself" {
    try std.testing.fuzz({}, fuzzSessionRecord, .{ .corpus = &session_record_corpus });
}

fn fuzzSessionRecord(_: void, smith: *std.testing.Smith) !void {
    const gpa = std.testing.allocator;
    var scratch: [8 * 1024]u8 = undefined;
    const text: []const u8 = if (smith.in) |seed| seed else scratch[0..smith.slice(&scratch)];

    // The arena is the caller's, the way `writeRecord` builds a record: the
    // line it hands back is the buffer's whole capacity and not a length a
    // caller can free by, so it is owned by the run rather than by the test.
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The three strings, split out of the same bytes so one seed reaches all
    // three at once and a cut one of them.
    const third = text.len / 3;
    const cwd = text[0..third];
    const model = text[third .. 2 * third];
    const finish_reason = try arena.dupe(u8, text[2 * third ..]);

    // The numbers the provider chose, at the ends a count reaches: a stamp and
    // a duration are both read back by a monitor and summed, so a counter that
    // arrives as something other than what was spent is a wrong bill. JSON has
    // no integer wider than i64, and a counter a monitor reads is parsed as
    // one, so the values here stay in the range it can read back.
    var nums: [24]u8 = undefined;
    const got_nums = smith.slice(&nums);
    const ts_ms: i64 = if (got_nums >= 8) std.mem.readInt(i64, nums[0..8], .little) else 0;
    const elapsed_ms: u64 = if (got_nums >= 16) std.math.cast(u64, @as(i64, @bitCast(std.mem.readInt(u64, nums[8..16], .little)))) orelse 0 else 0;
    const total: u64 = if (got_nums >= 24) std.math.cast(u64, @as(i64, @bitCast(std.mem.readInt(u64, nums[16..24], .little)))) orelse 0 else 0;

    const result: chat.ChatResult = .{
        .prompt_tokens = 1,
        .cached_tokens = 2,
        .completion_tokens = 3,
        .reasoning_tokens = 4,
        .total_tokens = total,
        .finish_reason = finish_reason,
    };

    const line = try sessionRecord(arena, ts_ms, cwd, model, elapsed_ms, &result);

    // One record, one line. The store is JSONL and a monitor reads it while the
    // run is still going, so a newline inside any of the three strings splits
    // the record into two responses the monitor will not join back together.
    try std.testing.expect(std.mem.endsWith(u8, line, "\n"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, line, "\n"));

    try std.testing.expect(try std.json.validate(gpa, line[0 .. line.len - 1]));

    const parsed = try std.json.parseFromSlice(std.json.Value, arena, line[0 .. line.len - 1], .{});
    const obj = parsed.value.object;

    // The strings that went in are the strings a monitor reads, and the
    // numbers are the numbers the record was built from.
    try expectSameString(obj, "cwd", cwd);
    try expectSameString(obj, "model", model);
    try expectSameString(obj, "finish_reason", finish_reason);
    const usage = obj.get("usage").?.object;
    try std.testing.expectEqual(@as(i64, 1), usage.get("prompt_tokens").?.integer);
    try std.testing.expectEqual(@as(i64, 2), usage.get("cached_tokens").?.integer);
    try std.testing.expectEqual(@as(i64, 3), usage.get("completion_tokens").?.integer);
    try std.testing.expectEqual(@as(i64, 4), usage.get("reasoning_tokens").?.integer);
    try std.testing.expectEqual(total, @as(u64, @intCast(usage.get("total_tokens").?.integer)));
    try std.testing.expectEqual(elapsed_ms, @as(u64, @intCast(obj.get("elapsed_ms").?.integer)));
    try std.testing.expectEqual(ts_ms, obj.get("ts").?.integer);
}

/// The field reads back as the bytes that went in, for text. A byte that is not
/// part of a valid sequence is written as U+FFFD, so what comes back is still
/// text and never longer than the three bytes each replacement takes.
fn expectSameString(obj: std.json.ObjectMap, key: []const u8, text: []const u8) !void {
    const got = chat.str(obj.get(key)) orelse return error.TestUnexpectedResult;
    if (std.unicode.utf8ValidateSlice(text)) {
        try std.testing.expectEqualStrings(text, got);
    } else {
        try std.testing.expect(std.unicode.utf8ValidateSlice(got));
        try std.testing.expect(got.len <= text.len * 3);
    }
}
