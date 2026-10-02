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
    return std.fs.path.join(arena, &.{ home, net.config_dir, "sessions" }) catch "";
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

/// The buffer `createSessionLog` spells the `-<attempt>` suffix into, sized
/// from the attempt count rather than chosen beside it. The widest suffix the
/// loop can reach is `-` and the last attempt below, and a count wide enough to
/// need one more digit than this holds is a compile error rather than a run
/// that reports "a session log name could not be built" and records no usage.
const max_session_suffix_bytes = std.fmt.count("{d}", .{session_name_attempts - 1}) + 1;

/// The mode a session log is created with, and the mode its directory is
/// created with when the run is the one that made the directory.
///
/// A log is a run's own account of itself: the directory it worked in, the
/// model it was charged to, and what every response cost, which on a shared
/// machine is not the business of every other account. The default file mode is
/// 0o666 less the umask, so on the 0o022 an ordinary account carries, a log
/// lands world-readable under `$HOME`, and every other account and every other
/// process on the machine can read the last 200 runs. The directory is the
/// other half of the same question: a 0o755 one exposes the names of the logs
/// even where the logs themselves are not readable, and it is the directory
/// the run creates out of nothing on a fresh account. Neither mode is applied
/// to a directory that already exists, so an operator who pointed
/// MICROAGENT_SESSION_DIR at a shared store keeps the mode they gave it.
///
/// The directory mode reaches the sandbox through `ensureDir` below rather
/// than by being exported: the sandbox creates the same directory earlier than
/// this module does, on a run with `enabled = true`, and a mode applied to a
/// directory that already exists is not applied at all, so whoever creates it
/// first decides it for both. Handing out the mode let the sandbox spell its own
/// create beside it, and the two copies agreed only until one of them was
/// edited. `log_file_mode` is read by this module alone.
pub const log_file_mode: Io.File.Permissions = @enumFromInt(@as(std.posix.mode_t, 0o600));
const log_dir_mode: Io.File.Permissions = @enumFromInt(@as(std.posix.mode_t, 0o700));

/// Creates the session store directory if it is not there, with this module's
/// mode, and reports a failure through `fmt` rather than to stderr itself.
///
/// Two callers make this directory and both must apply the same mode, because a
/// mode is not applied to a directory that already exists: whoever runs first
/// decides it for both. The sandbox makes it before the writable roots are
/// resolved, on a run with `enabled = true`, and the store opens it after. A
/// mode constant exported for the sandbox to spell beside its own call would be
/// the same creator written twice, and the two copies answer to one constant
/// only until one of them is edited; this is the single call instead, so the
/// sandbox holds no copy of the mode and cannot drift from it.
///
/// The message is the caller's, with `{s}` for the directory and `{s}` for the
/// error, because the two failures are different facts: a sandbox-enabled run
/// that could not make its own writable root keeps going, while a run whose
/// store is missing records nothing.
pub fn ensureDir(io: Io, arena: std.mem.Allocator, session_dir: []const u8, comptime fmt: []const u8) !void {
    _ = std.Io.Dir.cwd().createDirPathStatus(io, session_dir, log_dir_mode) catch |err| {
        net.note(io, arena, fmt, .{ chat.safeTextAll(arena, session_dir), @errorName(err) });
        return err;
    };
}

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
        var suffix_buf: [max_session_suffix_bytes]u8 = undefined;
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
pub fn open(io: Io, arena: std.mem.Allocator, env: *const std.process.Environ.Map, session_dir: []const u8, model: []const u8) ?Session {
    // The reading that names the log and measures the store's age windows.
    // `openAt` is the spelling that lets a caller supply that instant itself.
    return openAt(io, arena, env, session_dir, model, Io.Clock.real.now(io).nanoseconds);
}

/// `open` with the wall-clock reading passed in rather than taken, so the name
/// of the log a run opens and the age windows pruning measures against it are
/// a function of a value the caller chose. A production run hands it the real
/// clock; a test or a simulated run hands it a fixed instant and gets a store
/// it can spell out in advance. The records written into that log are stamped
/// from the clock at each write instead: `ts` says when a response landed, so
/// it is not a value a caller can pin for the whole run.
pub fn openAt(io: Io, arena: std.mem.Allocator, env: *const std.process.Environ.Map, session_dir: []const u8, model: []const u8, now_ns: i128) ?Session {
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
    const resolved = std.Io.Dir.cwd().realPathFileAlloc(io, ".", arena) catch |err| {
        net.note(io, arena, "microagent: the working directory could not be read ({s}), so no session log is kept under {s}\n", .{ @errorName(err), shown });
        return null;
    };
    const cwd = recordCwd(arena, env, resolved);
    ensureDir(io, arena, session_dir, "microagent: the session directory {s} could not be created ({s}); the rest of this run is not recorded\n") catch {
        return null;
    };
    const stamp = logStamp(now_ns);
    // The store is pruned once, with this run's own log already in place, so
    // the count window counts the log the run is writing rather than leaving the
    // store one past it. Pruning before the open as well cost a second full
    // walk and a second sort of the whole store on every run start, over a
    // directory of a couple of hundred names.
    //
    // A run whose stamp is a name the store already holds is the case the
    // ordering was for, and it is the one that returns here without a log: a
    // clock set before 1970 reads zero, so every later run collides on the same
    // names. The prune below runs on that path too, so the retention window is
    // applied whether or not a log was opened.
    const file = createSessionLog(io, arena, session_dir, stamp);
    _ = pruneSessions(io, arena, session_dir, now_ns);
    const opened = file orelse {
        net.note(io, arena, "microagent: no session log could be opened under {s}; the rest of this run is not recorded\n", .{shown});
        return null;
    };
    return .{ .file = opened, .cwd = cwd, .model = model, .dir = session_dir };
}

/// The `cwd` a record carries, which is the resolved working directory with
/// the account's own home cut off its front.
///
/// A working directory under a home directory carries the account name in it:
/// `/home/alice/Desktop/Projects/microagent` says who was working, and the
/// store keeps 200 of those records in the clear under that same home. So the
/// name is dropped and the part under it kept, which is what a monitor reads
/// the field for: two runs in `~/src/a` and `~/src/b` are still two
/// directories, and a run from `~/src/a` and one from `~/work/a` are still told
/// apart. The prefix a record gets is spelled rather than implicit, so a reader
/// can tell a home-relative directory from an absolute one without asking the
/// machine that wrote it.
///
/// A directory that is not under the home keeps its whole path, because the
/// components under the home are the only part that identifies a tree there: a
/// benchmark container runs in `/workspace/repo` and `/workspace` alone would
/// not tell two of its trials apart. `$HOME` itself records as the one marker
/// below, the directory under the home with nothing after it.
///
/// The home is cut only on a real boundary. A home spelled `/home/alice` does
/// not make `/home/alice2/secret` a child of it, so the tail is only taken
/// when the home is a whole path prefix of the directory, and a directory
/// equal to the home is the marker rather than a `.` a reader would have to
/// recognize.
fn recordCwd(arena: std.mem.Allocator, env: *const std.process.Environ.Map, resolved: []const u8) []const u8 {
    const home = net.homeDir(env) orelse return resolved;
    const root = std.mem.trim(u8, home, net.env_surrounding);
    if (root.len == 0 or !std.fs.path.isAbsolute(root)) return resolved;
    if (std.mem.eql(u8, resolved, root)) return home_marker;
    // Check the prefix before slicing: shorter and unrelated paths are outside the home.
    if (!std.mem.startsWith(u8, resolved, root)) return resolved;
    const tail = resolved[root.len..];
    if (tail[0] != std.fs.path.sep) return resolved;
    return std.fmt.allocPrint(arena, "{s}{s}{s}", .{ home_marker, std.fs.path.sep_str, tail[1..] }) catch resolved;
}

/// The marker a `cwd` carries in front of the part under the home, so a reader
/// tells a home-relative directory from an absolute one. Not a path: no
/// directory is named this, and a reader that resolved it would find nothing.
const home_marker = "~";

test "a record's cwd is the part of the working directory under the home" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const arena = state.allocator();
    const sep = std.fs.path.sep_str;

    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    try env.put("HOME", "/home/alice");

    // The case this is for: the account name is in the path and is not in the
    // record, while the directory still reads as the one the run worked in.
    try std.testing.expectEqualStrings(
        "~" ++ sep ++ "Desktop" ++ sep ++ "Projects" ++ sep ++ "microagent",
        recordCwd(arena, &env, "/home/alice/Desktop/Projects/microagent"),
    );
    try std.testing.expectEqualStrings("~", recordCwd(arena, &env, "/home/alice"));
    try std.testing.expectEqualStrings("~" ++ sep ++ "a", recordCwd(arena, &env, "/home/alice/a"));

    // A sibling whose name merely starts with the home's is not under it, and
    // cutting it would write `/home/alice2/secret` as `~2/secret`.
    try std.testing.expectEqualStrings("/home/alice2/secret", recordCwd(arena, &env, "/home/alice2/secret"));
    // Outside the home the whole path is kept: a benchmark container runs in
    // `/workspace/repo`, and dropping the prefix would leave one directory for
    // every trial in it.
    try std.testing.expectEqualStrings("/workspace/repo", recordCwd(arena, &env, "/workspace/repo"));
    try std.testing.expectEqualStrings("/tmp", recordCwd(arena, &env, "/tmp"));
    try std.testing.expectEqualStrings("/var/qwerty/data", recordCwd(arena, &env, "/var/qwerty/data"));

    // No home to cut against leaves the path as it is, and so does a home that
    // is not an absolute path: neither is a prefix of the directory, so
    // nothing is cut that was not a boundary.
    var bare: std.process.Environ.Map = .init(std.testing.allocator);
    defer bare.deinit();
    try std.testing.expectEqualStrings("/home/alice/x", recordCwd(arena, &bare, "/home/alice/x"));
    try env.put("HOME", "relative");
    try std.testing.expectEqualStrings("/home/alice/x", recordCwd(arena, &env, "/home/alice/x"));
    try env.put("HOME", "  ");
    try std.testing.expectEqualStrings("/home/alice/x", recordCwd(arena, &env, "/home/alice/x"));

    // A directory shorter than the home, and one sharing a leading component
    // but not the whole prefix. Both used to slice past the end of the
    // directory and abort the run before its first request.
    try env.put("HOME", "/home/alice/long/home/path");
    try std.testing.expectEqualStrings("/home/alice/src", recordCwd(arena, &env, "/home/alice/src"));
    try env.put("HOME", "/workspace/repository");
    try std.testing.expectEqualStrings("/workspace/src", recordCwd(arena, &env, "/workspace/src"));
    try std.testing.expectEqualStrings("/workspace", recordCwd(arena, &env, "/workspace"));
    // Still under the home on a real boundary, with the home merely longer
    // than the directory that replaced its tail.
    try std.testing.expectEqualStrings(
        "~" ++ sep ++ "src",
        recordCwd(arena, &env, "/workspace/repository/src"),
    );
}

/// The stamp a run's log is named from, from a clock reading in nanoseconds. A
/// clock set before 1970 reads negative, and a name that begins with `-` is one
/// `logName` refuses to parse, so the log would be written and never pruned.
/// Zero sorts as the oldest name, which is the order a stamp saying nothing
/// about the time should have.
fn logStamp(now_ns: i128) u128 {
    return if (now_ns < 0) 0 else @intCast(now_ns);
}

/// The stamp a record's `ts` field carries, in milliseconds since the epoch,
/// from a clock reading in nanoseconds.
///
/// The same clamp `logStamp` applies, for the same machine: a clock set before
/// 1970 reads negative, and a negative epoch is not an instant a monitor can
/// order against the positive ones the rest of the store holds. Zero is the
/// reading that says nothing about the time, which is all a clock before the
/// epoch says.
///
/// The far end is held too, and for the reason the near end is. The clock is
/// a signed `i96`, and divided into milliseconds it still reaches past what
/// an `i64` holds, so a machine whose wall clock is set far ahead reaches the
/// same narrowing the other way: `@intCast` traps a checked build. Both ends
/// saturate rather than wrap, because a record that carries a stamp no reader
/// can order is worth less than one carrying the largest stamp there is.
///
/// The width is `i128` rather than the clock's own `i96` so one reading can
/// serve both stamps of a run: `logStamp` names the log from it and this
/// writes the record, and `openAt` hands the same value to both. A reading is
/// at most `i96` wide, so the wider parameter accepts everything a clock can
/// hand it.
fn recordStampMs(now_ns: i128) i64 {
    if (now_ns < 0) return 0;
    const ms = @divTrunc(now_ns, std.time.ns_per_ms);
    if (ms > std.math.maxInt(i64)) return std.math.maxInt(i64);
    return @intCast(ms);
}

/// Session logs kept on disk. The store is a per-run directory that nothing
/// ever deleted from, so a machine running gauntlet loops accumulated one file
/// per review forever; a monitor reads the recent runs, not the whole history.
const max_session_logs = 200;

/// How long a log is kept whatever the count says, in days. The count alone is
/// not a retention period: it bounds the store on a machine that runs often and
/// bounds nothing at all on one that runs a few times a week, where two hundred
/// logs is four years of the working directory each record names. Thirty days
/// is well past the gap a monitor polling a running session has, and a log
/// older than it describes a run no reader is following.
///
/// Stated in days rather than in nanoseconds because the window is a policy
/// read back to the operator in days, and a day count derived by dividing the
/// nanosecond constant is one edit away from naming a window nobody chose.
const max_session_log_age_days: u64 = 30;
const ns_per_day: u128 = 24 * 60 * 60 * std.time.ns_per_s;
const max_session_log_age_ns: u128 = max_session_log_age_days * ns_per_day;

/// Whether a log's name is further in the past than the age window allows,
/// against the clock reading the run that is pruning.
///
/// A clock at or before the epoch expires nothing: `logStamp` clamps a stamp
/// written by such a machine to zero, and a store of zero-stamped logs is a
/// machine whose clock is wrong rather than one whose logs are old. A stamp
/// past the reading is a clock that was set back between two runs, not a log
/// from the future, so it is not expired either: a wrong clock in that
/// direction must not empty a store that is under the count window.
fn stampExpired(stamp: u128, now_ns: i128) bool {
    if (now_ns <= 0) return false;
    const now: u128 = @intCast(now_ns);
    if (stamp > now) return false;
    return now - stamp > max_session_log_age_ns;
}

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

/// Deletes the oldest logs past `max_session_logs`, and every log older than
/// `max_session_log_age_ns` whatever the count says. The oldest is read off the
/// numbers the name carries rather than off its bytes: `-` sorts below every
/// digit and a short stamp sorts below a long one, so a lexicographic sort puts
/// a re-run's `<stamp>-1.jsonl` ahead of the `<stamp>.jsonl` that was written
/// before it, and hands the retention window the wrong file of the pair. Only
/// this program's own `<digits>[-<digits>].jsonl` files are touched.
///
/// `now_ns` is the run's own clock reading, taken by the caller so the two
/// prunes `open` makes and the name this run writes all read one instant. The
/// age window is the half that is a retention period rather than a size: the
/// count is a bound on a busy machine and nothing at all on an idle one, and
/// what a log names is the directory the run worked in, which carries the
/// account name of whoever ran it.
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
/// creates the log: `createFileAbsolute` is a `cwd`-relative create, not a
/// checked one, so `MICROAGENT_SESSION_DIR=logs/x` names a store the run really
/// opens where it was asked for.
fn pruneSessions(io: Io, arena: std.mem.Allocator, session_dir: []const u8, now_ns: i128) usize {
    return pruneSessionsTo(io, arena, session_dir, max_session_logs, now_ns);
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

/// The pruner, with the window it keeps and the clock it measures the age
/// window against as arguments rather than constants, so the fuzz harness can
/// put a handful of names over a window of two and check what the delete loop
/// does with them, and a test can name a store a hundred days old without
/// waiting for it.
/// Returns how many logs it deleted, which is zero for every path that gives
/// up and the number the delete loop removed otherwise. The count is what the
/// tests read: a run that reports a delete it did not make, and one that makes
/// a delete it cannot report, both leave the same directory behind, so the
/// note text cannot tell them apart.
fn pruneSessionsTo(io: Io, arena: std.mem.Allocator, session_dir: []const u8, keep: usize, now_ns: i128) usize {
    // Escaped once for the two notes below, for the reason `createSessionLog`
    // gives: the directory is a variable or a path under `$HOME`.
    const shown = chat.safeTextAll(arena, session_dir);
    var dir = std.Io.Dir.openDir(std.Io.Dir.cwd(), io, session_dir, .{ .iterate = true }) catch |err| {
        net.note(io, arena, "microagent: the session store under {s} could not be read for pruning ({s}); it is not pruned and is left as it stands\n", .{ shown, @errorName(err) });
        return 0;
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
            return 0;
        };
        defer net.drainWalk(io, &walker);
        while (true) {
            const entry = walker.next(io) catch |err| {
                partialList(io, arena, shown, found.items.len, err);
                return 0;
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
                return 0;
            };
            found.append(arena, .{ .path = path_copy, .key = key }) catch |err| {
                arena.free(path_copy);
                partialList(io, arena, shown, found.items.len, err);
                return 0;
            };
        }
    }
    // Sorted oldest first, so the count window and the age window are both
    // monotone along the list and the logs to delete are one prefix of it: the
    // first entry that is neither over the count nor past the age ends the
    // walk, and nothing after it is deletable.
    std.mem.sort(Found, found.items, {}, struct {
        fn lessThan(_: void, a: Found, b: Found) bool {
            if (a.key.olderThan(b.key)) return true;
            if (b.key.olderThan(a.key)) return false;
            return std.mem.order(u8, a.path, b.path) == .lt;
        }
    }.lessThan);

    var deleting: usize = 0;
    var i: usize = 0;
    while (i < found.items.len) : (i += 1) {
        // `i + keep` rather than `found.items.len - keep`, so a `keep` past the
        // size of the store underflows into a window that deletes all of it.
        const over_count = i + keep < found.items.len;
        if (!over_count and !stampExpired(found.items[i].key.stamp, now_ns)) break;
        deleting += 1;
    }
    if (deleting == 0) return 0;

    var failed: usize = 0;
    var first_err: ?anyerror = null;
    for (found.items[0..deleting]) |f| {
        dir.deleteFile(io, f.path) catch |err| {
            failed += 1;
            if (first_err == null) first_err = err;
        };
    }
    if (failed != 0) net.note(io, arena, "microagent: {d} of {d} session logs under {s} could not be deleted ({s}); the store stays over its {d}-log limit and holds logs past the {d}-day age window until they can be\n", .{
        failed, deleting, shown, @errorName(first_err.?), keep, max_session_log_age_days,
    });
    return deleting - failed;
}

// A walk that returns before it has finished leaves every directory below the
// point it stopped at open: `SelectiveWalker.deinit` frees the two lists it
// owns and closes nothing, and only the popping half of `next` closes a
// directory as it goes. `pruneSessionsTo` is the one walk in this program with
// early returns inside its loop, and it runs once per run, so each of them
// leaked a handle per level of depth still under it. The walk is drained before
// it is deinited, so the count is the same whatever the loop gave up on.
test "a walk that gives up mid-tree leaves no descriptor behind" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var f = try StoreFixture.init(gpa);
    defer f.deinit();
    const io = f.io();
    const store = try storeRelative(f.arena(), io, f.tmp);

    // Deep enough that a walk holding the stack has several handles open, with a
    // log at the bottom so the loop is still inside a subdirectory when it
    // gives up. The store a run creates is one level deep; a monitor that
    // reorganised it is what makes it deeper, and the walk does not care.
    const deep = try std.fs.path.join(f.arena(), &.{ store, "a", "b", "c", "d", "e" });
    try f.tmp.dir.createDirPath(io, deep);
    const deep_log = try std.fs.path.join(f.arena(), &.{ store, "a", "b", "c", "d", "e", "1.jsonl" });
    try f.tmp.dir.writeFile(io, .{ .sub_path = deep_log, .data = "" });

    const baseline = try net.openDescriptors(io, f.arena());

    var dir = try std.Io.Dir.cwd().openDir(io, store, .{ .iterate = true });
    defer dir.close(io);
    {
        var walker = try dir.walk(f.arena());
        defer net.drainWalk(io, &walker);
        // The shape `pruneSessionsTo` has: give up as soon as the first file is
        // met, which is while every directory above it is still on the stack.
        while (walker.next(io) catch null) |entry| {
            if (entry.kind == .file) break;
        }
    }
    // The point of the test: whatever the loop did above, and however deep the
    // store was, the drain returned every handle the walk had taken, so the
    // only descriptor still open is the store handle the caller owns.
    try std.testing.expectEqual(baseline + 1, try net.openDescriptors(io, f.arena()));
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
///
/// `clock` is the one `since` was read on, and it is an argument because the
/// two are not interchangeable: an instant on one clock subtracted from a
/// reading of another is the difference between two unrelated origins, so the
/// clock the caller took its stamp on is the clock this subtracts it from.
pub fn elapsedMs(io: Io, clock: Io.Clock, since: i96) u64 {
    const delta = Io.Timestamp.now(io, clock).nanoseconds - since;
    if (delta <= 0) return 0;
    return @intCast(@divTrunc(delta, std.time.ns_per_ms));
}

/// One record per response, into the log this run opened.
///
/// A failure to *open* the log is a null and costs the run nothing, so `open`
/// names it on stderr and the run continues. A failure to *write* one is
/// different: the
/// log was there, the run is producing records, and a store that has gone quiet
/// (a full disk, a directory removed under the run) would otherwise leave the
/// monitor reporting a run that stopped long before it did. It is named once and
/// the log is dropped, so the run is not left appending to a file nothing reads
/// and saying nothing about the gap.
pub fn writeRecord(io: Io, arena: std.mem.Allocator, session: *?Session, elapsed_ms: u64, result: *const chat.ChatResult) void {
    write(io, arena, session, .{ .elapsed_ms = elapsed_ms, .response = result });
}

/// One turn whose provider call never answered, as a line of the same shape a
/// response is.
///
/// A record per response is not a record per turn: a run that dies on an HTTP
/// 500, a transport error or a stall on its third request leaves a log whose
/// last line is the second response, and a reader counting records finds a run
/// that ended where it was last heard from rather than one that failed there.
/// The reason is this program's own `@errorName` text, and the counters are
/// zero because no response was billed and none arrived; a monitor summing
/// `usage` is unaffected, and one looking for the end of a run finds it.
pub fn writeFailure(io: Io, arena: std.mem.Allocator, session: *?Session, elapsed_ms: u64, failure: []const u8) void {
    write(io, arena, session, .{ .elapsed_ms = elapsed_ms, .failure = failure });
}

/// What one line says about one turn. A turn the provider answered carries the
/// response; a turn it did not carries the reason and no response. One shape
/// rather than two, so a reader does not have to know which of the two a line
/// is before it can read the line.
pub const Record = struct {
    /// The turn's model time, on the run's own clock and taken the same way
    /// `writeRecord`'s caller takes it, so a failed turn's time and a
    /// successful one's are the same measure.
    elapsed_ms: u64,
    /// The response, or null for a call that never answered.
    response: ?*const chat.ChatResult = null,
    /// The `@errorName` for a call that never answered, and empty for one that
    /// did. It is this program's own vocabulary rather than a provider's
    /// message, so it carries no provider bytes and needs nothing but the
    /// escaper every other string in the line gets.
    failure: []const u8 = "",
};

fn write(io: Io, arena: std.mem.Allocator, session: *?Session, record: Record) void {
    const s = session.* orelse return;
    // `s.dir` is the directory the run was given, escaped for the reason
    // `createSessionLog` gives.
    const shown = chat.safeTextAll(arena, s.dir);
    // Read here, at the write, rather than from the reading `open` captured:
    // `ts` says when this response landed, and a log whose every line carries
    // the instant the file was opened says it about none of them. A monitor
    // following a run while it is going deltas these against each other to
    // place a response, and `elapsed_ms` is only readable beside a `ts` that
    // moves with it. The log's *name* is the one reading `open` took, which is
    // right there: a name is written once, so one instant is all it can carry.
    const ts_ms = recordStampMs(Io.Clock.real.now(io).nanoseconds);
    const line = sessionRecord(arena, ts_ms, s.cwd, s.model, record) catch |err| {
        net.note(io, arena, "microagent: a session record for {s} could not be built ({s}); the rest of this run is not recorded\n", .{ shown, @errorName(err) });
        close(io, session);
        return;
    };
    s.file.writeStreamingAll(io, line) catch |err| {
        net.note(io, arena, "microagent: the session log under {s} could not be written ({s}); the rest of this run is not recorded\n", .{ shown, @errorName(err) });
        close(io, session);
        return;
    };
    // The record is on its way to the monitor the moment the write returns, and
    // this run then keeps going as though the turn were recorded. Without a
    // flush below that promise does not survive a power loss or a kernel panic:
    // the bytes sit in the page cache, a monitor that already read them counts
    // them, and a machine that comes back has a log whose tail is truncated to
    // whatever the last flush happened to cover. A record that has been
    // acknowledged must be readable after an unclean stop, so the file is
    // synced here, once per record, before `write` returns.
    //
    // This is the one place a session write blocks on the disk. A response is
    // already seconds of provider time, so the flush is a rounding error against
    // the cost of losing the tail of every run on a busy machine, and the record
    // is a handful of hundred bytes.
    s.file.sync(io) catch |err| {
        // The bytes themselves reached the file: the write above returned, and
        // a monitor reading through the same page cache sees this record. Only
        // the durability guarantee failed, so this is named and the run goes on
        // appending rather than dropping a log whose contents are already on
        // disk. It is the one failure here that does not close the store: what
        // would be lost is the guarantee, not the data, and dropping the file
        // would turn "this record may not survive a power cut" into "this record
        // and every record after it are gone".
        net.note(io, arena, "microagent: the session log under {s} could not be flushed to disk ({s}); records in it may be lost if this machine stops uncleanly\n", .{ shown, @errorName(err) });
    };
}

/// The parts of a session record that do not vary with the strings in it: the
/// keys, the punctuation, and the numbers. Not derived from the format string
/// so it cannot go stale against it; it is a reservation, and the buffer's
/// growth ladder still covers a record that outgrows it.
const session_record_scaffolding_bytes = 512;

/// One turn's line: this turn's own counters, not the run's cumulative ones, so
/// a reader sums them; the directory it ran in; the model the provider said
/// answered, beside the one the run asked for; and the model time it took. The
/// keys are the OpenAI-shaped ones toktop already reads by name.
///
/// A turn that has no `Record.response` writes the empty string for the three
/// fields a stream fills and an `error` beside them, so the line is the same
/// object a monitor already parses rather than a second shape it has to learn.
fn sessionRecord(
    allocator: std.mem.Allocator,
    ts_ms: i64,
    cwd: []const u8,
    model: []const u8,
    record: Record,
) ![]u8 {
    // Sized from the strings the record carries, so it is allocated once
    // rather than doubling up to a few hundred bytes on a ladder of copies.
    // Escape expansion can still push it past this, which the ladder handles.
    var jb = chat.JsonBuf.initCapacity(allocator, session_record_scaffolding_bytes +
        cwd.len + model.len + record.failure.len + streamStringBytes(record.response));
    const w = jb.writer();
    try w.print("{{\"ts\":{d},\"cwd\":", .{ts_ms});
    try chat.writeJsonString(w, cwd);
    try w.writeAll(",\"model\":");
    try chat.writeJsonString(w, model);
    // A turn with no response is a call that never answered, so the three fields
    // a stream fills are the empty strings and the reason sits beside them.
    const result = record.response;
    if (result) |r| {
        // Why the provider stopped, so a record that was cut at the generation
        // ceiling is distinguishable from one that ran to its own end. The empty
        // string is a stream that carried no finish_reason at all.
        try w.writeAll(",\"finish_reason\":");
        try chat.writeJsonString(w, r.finish_reason);
        // The model that answered, next to the one the run asked for. A gateway
        // routes a name to whichever snapshot it holds this week, so the request's
        // `model` is what was asked for and this is what produced the record: a
        // reader comparing two runs needs both, and `system_fingerprint` is the
        // half that moves when the weights do behind a served name that did not.
        // Both are empty strings when the provider's stream named neither.
        try w.writeAll(",\"served_model\":");
        try chat.writeJsonString(w, r.served_model);
        try w.writeAll(",\"fingerprint\":");
        try chat.writeJsonString(w, r.fingerprint);
    } else {
        try w.writeAll(",\"finish_reason\":\"\",\"served_model\":\"\",\"fingerprint\":\"\"");
    }
    if (record.failure.len != 0) {
        try w.writeAll(",\"error\":");
        try chat.writeJsonString(w, record.failure);
    }
    // A turn with no response was never billed, so it reports the zero every
    // counter starts at rather than a field spelled separately here.
    const usage: chat.Usage = if (result) |r| .{
        .prompt = r.prompt_tokens,
        .cached = r.cached_tokens,
        .completion = r.completion_tokens,
        .reasoning = r.reasoning_tokens,
        .total = r.total_tokens,
    } else .{};
    try w.print(",\"elapsed_ms\":{d},\"usage\":{{" ++ chat.usage_fields, .{
        record.elapsed_ms, usage.prompt, usage.cached, usage.completion, usage.reasoning, usage.total,
    });
    try w.writeAll("}}\n");
    return jb.items();
}

/// The bytes the three stream strings add to the reservation above, or zero
/// for a turn that never got one.
fn streamStringBytes(result: ?*const chat.ChatResult) usize {
    const r = result orelse return 0;
    return r.finish_reason.len + r.served_model.len + r.fingerprint.len;
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
    result.served_model = try arena.dupe(u8, "deepseek/deepseek-v4-flash-0726");
    result.fingerprint = try arena.dupe(u8, "fp_9c1e");

    const line = try sessionRecord(arena, 1759000000000, "/home/me/proj", "deepseek/deepseek-v4-flash", .{ .elapsed_ms = 1234, .response = &result });
    try std.testing.expectEqualStrings(
        "{\"ts\":1759000000000,\"cwd\":\"/home/me/proj\",\"model\":\"deepseek/deepseek-v4-flash\"," ++
            "\"finish_reason\":\"stop\"," ++
            "\"served_model\":\"deepseek/deepseek-v4-flash-0726\",\"fingerprint\":\"fp_9c1e\"," ++
            "\"elapsed_ms\":1234,\"usage\":{\"prompt_tokens\":910,\"cached_tokens\":832," ++
            "\"completion_tokens\":18,\"reasoning_tokens\":0,\"total_tokens\":928}}\n",
        line,
    );
}

// A turn the provider never answered is a line of the same shape, because a
// monitor walks one store and parses one object per line. The three fields a
// stream fills are the empty strings a stream that carried none would write, so
// only `error` says what happened, and the counters are the zeros the run was
// never charged for.
test "a turn that never got a response is a record with the reason and no counters" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const arena = state.allocator();

    const line = try sessionRecord(arena, 1759000000000, "/home/me/proj", "deepseek/deepseek-v4-flash", .{
        .elapsed_ms = 900,
        .failure = "ConnectionRefused",
    });
    try std.testing.expectEqualStrings(
        "{\"ts\":1759000000000,\"cwd\":\"/home/me/proj\",\"model\":\"deepseek/deepseek-v4-flash\"," ++
            "\"finish_reason\":\"\",\"served_model\":\"\",\"fingerprint\":\"\"," ++
            "\"error\":\"ConnectionRefused\"," ++
            "\"elapsed_ms\":900,\"usage\":{\"prompt_tokens\":0,\"cached_tokens\":0," ++
            "\"completion_tokens\":0,\"reasoning_tokens\":0,\"total_tokens\":0}}\n",
        line,
    );

    // The reason is this program's own vocabulary, but a caller that names its
    // own error is one `writeFailure` call away, and a newline in it would split
    // the record into two the monitor will not join back together.
    const split = try sessionRecord(arena, 2, "/tmp", "m", .{ .elapsed_ms = 1, .failure = "a\"b\\c\nd" });
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, split, "\n"));

    // And a line a monitor already parses: the whole record is one JSON object,
    // so the failure branch did not fall back to a second shape.
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{});
    try std.testing.expect(parsed == .object);
    try std.testing.expectEqualStrings("ConnectionRefused", parsed.object.get("error").?.string);
    try std.testing.expectEqual(@as(i64, 0), parsed.object.get("usage").?.object.get("total_tokens").?.integer);
}

test "session record escapes a directory that needs it" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    var result: chat.ChatResult = .{ .completion_tokens = 4 };
    const line = try sessionRecord(state.allocator(), 1, "/tmp/a\"b\\c", "m", .{ .elapsed_ms = 5, .response = &result });
    try std.testing.expectEqualStrings(
        "{\"ts\":1,\"cwd\":\"/tmp/a\\\"b\\\\c\",\"model\":\"m\"," ++
            "\"finish_reason\":\"\"," ++
            "\"served_model\":\"\",\"fingerprint\":\"\"," ++
            "\"elapsed_ms\":5,\"usage\":{\"prompt_tokens\":0,\"cached_tokens\":0," ++
            "\"completion_tokens\":4,\"reasoning_tokens\":0,\"total_tokens\":0}}\n",
        line,
    );
}

// The model time a record carries is the gap between the stamp the caller took
// and the one this reads, on the same clock. Two things make it wrong without
// any test noticing: a stamp from another clock, which the caller passing one
// in rules out, and a clock that went backwards underneath it, which the clamp
// at zero answers rather than writing a negative number into a record a rate is
// taken from.
test "model time is the gap on the clock it was stamped from, and never negative" {
    const io = std.testing.io;
    const now = Io.Clock.real.now(io).nanoseconds;

    // A stamp an hour in the future is a clock that moved backwards, or a
    // caller that stamped a different one. The record says the run took no
    // time rather than a length no reader can divide by.
    try std.testing.expectEqual(@as(u64, 0), elapsedMs(io, .real, now + 3600 * std.time.ns_per_s));

    // A stamp read a few statements above is not pinned to a zero gap: whether
    // the wall clock moved under the test in that time is a property of the
    // machine, not of the code, and a loaded runner would fail a suite whose
    // behavior is right. The clamp above carries the "never negative" half; the
    // band below carries the rest.

    // A stamp from the past is the ordinary case. The band is wide on purpose:
    // the lower bound is what proves the difference was taken, and an upper
    // bound tight enough to fail would be a timing dependency.
    const since = now - 1500 * std.time.ns_per_ms;
    const took = elapsedMs(io, .real, since);
    try std.testing.expect(took >= 1500);
    try std.testing.expect(took < 60_000);
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

// The log is named after the reading `openAt` was handed, so a store is a
// value a test can spell out in advance. Its records are not: `ts` is when
// each response landed, so it moves with the clock while the name stands
// still. A log whose every line carried the opening instant would put every
// response at one moment, and a monitor deltas `ts` to place them.
test "the store is named from the reading it was opened with, and each record carries its own" {
    const alloc = std.testing.allocator;
    var f = try StoreFixture.init(alloc);
    defer f.deinit();
    const io = f.io();
    const arena = f.arena();

    // A pinned instant, away from the epoch and not a round number a real run
    // would never land on, so a name that came from anywhere but this argument
    // is visibly a different one rather than coincidentally equal.
    const pinned: i128 = 1_700_000_000_123_456_789;
    const store = try storeRelative(arena, io, f.tmp);

    // An environment with no home, so `recordCwd` keeps the directory whole.
    var no_env: std.process.Environ.Map = .init(std.testing.allocator);
    defer no_env.deinit();

    var session: ?Session = openAt(io, arena, &no_env, store, "test/model", pinned) orelse return error.TestUnexpectedResult;

    const expected_name = try std.fmt.allocPrint(arena, "{d}.jsonl", .{@as(u128, @intCast(pinned))});

    var result: chat.ChatResult = .{ .completion_tokens = 1 };
    writeRecord(io, arena, &session, 5, &result);
    writeRecord(io, arena, &session, 6, &result);
    close(io, &session);

    // Read through the working directory rather than the fixture's own handle:
    // `store` is relative to the cwd, which is how a run is given a store, so
    // the path is the one the run itself would use to find what it wrote.
    const line = try std.Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(arena, &.{ store, expected_name }), alloc, .unlimited);
    defer alloc.free(line);

    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, line, "\n"));
    const pinned_ms: i64 = @intCast(@divTrunc(pinned, std.time.ns_per_ms));
    var lines = std.mem.splitScalar(u8, line, '\n');
    var checked: usize = 0;
    while (lines.next()) |entry| {
        if (entry.len == 0) continue;
        checked += 1;
        const parsed = std.json.parseFromSlice(std.json.Value, arena, entry, .{}) catch return error.TestUnexpectedResult;
        try std.testing.expectEqual(@as(i64, 4 + @as(i64, @intCast(checked))), parsed.value.object.get("elapsed_ms").?.integer);
        // Stamped at the write, so it is a real clock reading rather than the
        // instant the file was named: at or after the run's own opening, and
        // after the pinned name it sits beside. The clock cannot be pinned
        // here without a seam the production path does not have, so the check
        // is the two-sided one that holds whichever way it is read.
        const ts = parsed.value.object.get("ts").?.integer;
        try std.testing.expect(ts >= pinned_ms);
        try std.testing.expect(ts > pinned_ms);
    }
    try std.testing.expectEqual(@as(usize, 2), checked);
}

/// The directory a store is named in, spelled the way a run is given one:
/// relative to the working directory. `std.testing.tmpDir` puts its directory
/// under a scratch root whose name belongs to the standard library, so
/// spelling that root here would tie these tests to a layout they do not own and
/// to the directory the test binary happened to be started in. The path is asked
/// for and made relative instead.
fn storeRelative(arena: std.mem.Allocator, io: Io, tmp: std.testing.TmpDir) ![]const u8 {
    const cwd = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", arena);
    const absolute = try tmp.dir.realPathFileAlloc(io, ".", arena);
    return std.fs.path.relative(arena, cwd, null, cwd, absolute);
}

// A directory the caller named and that no log lands in is a store a monitor
// reads that stays empty for the whole run, and the run is the only place that
// can say so. Every one of these is a null, and every one of them names itself.
test "a session directory that cannot be used is named, and keeps no log" {
    const alloc = std.testing.allocator;
    var f = try StoreFixture.init(alloc);
    defer f.deinit();
    const io = f.io();
    const arena = f.arena();
    // The store sits under the test's own temporary directory, so the relative
    // spelling a run is given reaches it and the cleanup takes it with the rest.
    const store = try storeRelative(arena, io, f.tmp);

    // An environment with no home, so `recordCwd` keeps the directory whole.
    var no_env: std.process.Environ.Map = .init(std.testing.allocator);
    defer no_env.deinit();

    // Off is not a failure and says nothing: the caller asked for no log.
    try std.testing.expect(open(io, arena, &no_env, "", "test/model") == null);

    // A store no filesystem will hold: a name longer than a path component is
    // allowed to be, so the directory cannot be made and no log is kept. The
    // caller named it, so the run says which one rather than losing the log
    // quietly.
    const long_name = try arena.alloc(u8, 300);
    @memset(long_name, 'x');
    const blocked = try std.fs.path.join(arena, &.{ store, long_name });
    try std.testing.expect(open(io, arena, &no_env, blocked, "test/model") == null);

    // The same path a run can use, so the null above is the directory and not
    // the shape of the call.
    const usable = try std.fs.path.join(arena, &.{ store, "sessions" });
    var session: ?Session = open(io, arena, &no_env, usable, "test/model") orelse return error.TestUnexpectedResult;
    defer close(io, &session);

    // And the store that opened is one a monitor can read: the record is on
    // disk, it is the one line the record is built from, and it carries the
    // model and the model time the run measured. `writeRecord` is the only
    // thing that puts a line in a log, so a writer that dropped it, wrote it
    // to the wrong file or carried the wrong counters passes every other test
    // in this file.
    var result: chat.ChatResult = .{ .completion_tokens = 3 };
    writeRecord(io, arena, &session, 12, &result);
    close(io, &session);
    session = null;

    var logs = try f.tmp.dir.openDir(io, "sessions", .{ .iterate = true });
    defer logs.close(io);
    var it = logs.iterate();
    var lines: std.ArrayList([]const u8) = .empty;
    while (try it.next(io)) |entry| {
        const text = try logs.readFileAlloc(io, entry.name, arena, .unlimited);
        try lines.append(arena, text);
    }
    try std.testing.expectEqual(@as(usize, 1), lines.items.len);
    const line = lines.items[0];
    try std.testing.expect(std.mem.endsWith(u8, line, "\n"));
    // One line, not a record concatenated onto a previous one.
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, line, "\n"));
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, line, .{});
    defer parsed.deinit();
    const record = parsed.value.object;
    try std.testing.expectEqualStrings("test/model", record.get("model").?.string);
    try std.testing.expectEqual(@as(i64, 12), record.get("elapsed_ms").?.integer);
    try std.testing.expectEqual(@as(i64, 3), record.get("usage").?.object.get("completion_tokens").?.integer);
    try std.testing.expect(record.get("ts").?.integer >= 0);
    // The directory the run was in, resolved, which is what a monitor reading
    // the store needs; the session directory the log sits in is not it.
    const cwd = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", arena);
    try std.testing.expectEqualStrings(cwd, record.get("cwd").?.string);
}

// A log that cannot be written to has stopped recording the run. Kept, it is
// one silent gap per turn in a store a monitor is reading; dropped, the run
// says once that the rest of it is unrecorded and stops writing to it.
test "a session log that cannot be written is dropped, not written to again" {
    const alloc = std.testing.allocator;
    var f = try StoreFixture.init(alloc);
    defer f.deinit();
    const io = f.io();
    const arena = f.arena();

    // Opened for reading, so every write to it is refused the way a full disk
    // or a removed directory refuses one.
    try f.tmp.dir.writeFile(io, .{ .sub_path = "read-only.jsonl", .data = "" });
    const file = try f.tmp.dir.openFile(io, "read-only.jsonl", .{ .mode = .read_only });

    var session: ?Session = .{ .file = file, .cwd = ".", .model = "test/model", .dir = "/sessions" };
    var result: chat.ChatResult = .{};
    result.prompt_tokens = 7;
    writeRecord(io, arena, &session, 1, &result);
    try std.testing.expect(session == null);

    // A second record has nowhere to go: the log was dropped, not retried.
    writeRecord(io, arena, &session, 2, &result);
    const empty = try f.tmp.dir.readFileAlloc(io, "read-only.jsonl", alloc, .limited(64));
    defer alloc.free(empty);
    try std.testing.expectEqualStrings("", empty);
}

// A record `writeRecord` returned from is one the run and every monitor reading
// the store have already been told about, so it has to be on disk before that
// call returns rather than at some later flush or at close: a machine that stops
// between the two loses a tail a monitor has already counted. The check reads
// the store through the working directory while the session's own handle is
// still open, so what it sees is what the filesystem holds for the write that
// just returned and not a buffer waiting on a close that has not happened.
test "a written record is on disk before the write returns" {
    const alloc = std.testing.allocator;
    var f = try StoreFixture.init(alloc);
    defer f.deinit();
    const io = f.io();
    const arena = f.arena();

    const pinned: i128 = 1_700_000_000_123_456_789;
    const store = try storeRelative(arena, io, f.tmp);

    // An environment with no home, so `recordCwd` keeps the directory whole.
    var no_env: std.process.Environ.Map = .init(std.testing.allocator);
    defer no_env.deinit();

    var session: ?Session = openAt(io, arena, &no_env, store, "test/model", pinned) orelse return error.TestUnexpectedResult;
    defer close(io, &session);

    var result: chat.ChatResult = .{ .completion_tokens = 3 };
    writeRecord(io, arena, &session, 1, &result);
    // Still open: the run carries on after a record, and a store that dropped
    // itself here would fail the next write rather than this one.
    try std.testing.expect(session != null);

    // Read through the working directory, the way a run is given its store,
    // while the session's own handle is still open.
    const name = try std.fmt.allocPrint(arena, "{d}.jsonl", .{@as(u128, @intCast(pinned))});
    const path = try std.fs.path.join(arena, &.{ store, name });
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .unlimited);
    defer alloc.free(bytes);

    // One whole record, newline included: a truncated line is what a write that
    // did not finish leaves behind, and a reader could not tell it from a
    // record that was never written.
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, bytes, "\n"));
    try std.testing.expect(std.mem.endsWith(u8, bytes, "\n"));
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
    var f = try StoreFixture.init(alloc);
    defer f.deinit();
    const io = f.io();
    const arena = f.arena();

    try f.tmp.dir.writeFile(io, .{ .sub_path = "read-only.jsonl", .data = "" });
    const file = try f.tmp.dir.openFile(io, "read-only.jsonl", .{ .mode = .read_only });
    const session: ?Session = .{ .file = file, .cwd = ".", .model = "test/model", .dir = "/sessions" };

    sessionScope(io, arena, session);

    const after = try f.tmp.dir.createFile(io, "after.jsonl", .{ .truncate = true });
    defer after.close(io);
    try after.writeStreamingAll(io, "kept");
    const kept = try f.tmp.dir.readFileAlloc(io, "after.jsonl", alloc, .limited(64));
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

    // Twenty-five logs are past the window, so twenty-five deletes are the
    // ones reported: a run that removed them and said nothing, or said more
    // than it removed, is the failure this count is read for.
    try std.testing.expectEqual(@as(usize, 25), pruneSessions(io, arena, dir_path, test_now_ns));

    try std.testing.expectEqual(max_session_logs, try countSessionLogs(io, arena, dir_path));
    try store.tmp.dir.access(io, "notes.jsonl", .{});
    try store.tmp.dir.access(io, "1-.jsonl", .{});
    // The survivors are the newest, so a monitor still sees the current run.
    const newest = try std.fmt.allocPrint(arena, "{d}.jsonl", .{total});
    try store.tmp.dir.access(io, newest, .{});
    try std.testing.expectError(error.FileNotFound, store.tmp.dir.access(io, "1.jsonl", .{}));
}

// The store `open` leaves behind is the window, not one past it. The prune runs
// after the log is created, so the run's own log is one of the names the count
// window sees. This holds the size the run settles on rather than the order the
// two prunes ran in: either ordering ends on the window, and what the single
// prune buys is that the store is walked and sorted once per run rather than
// twice.
test "a run's own log is counted by the retention window, not left past it" {
    var store = try StoreFixture.init(std.testing.allocator);
    defer store.deinit();
    const io = store.io();
    const arena = store.arena();
    const dir_path = try store.path();

    // A store already at the window, so this run's log is the one that has to
    // push it over for the ordering to show anything. The stamps are a
    // nanosecond apart ending just before the real clock `open` reads, because
    // a store seeded with 1970 stamps is one the age window empties before the
    // count window is ever asked.
    const now_ns = Io.Clock.real.now(io).nanoseconds;
    var i: usize = 0;
    while (i < max_session_logs) : (i += 1) {
        const name = try std.fmt.allocPrint(arena, "{d}.jsonl", .{@as(u128, @intCast(now_ns)) - (max_session_logs - i)});
        try store.tmp.dir.writeFile(io, .{ .sub_path = name, .data = "{}" });
    }

    // An environment with no home, so `recordCwd` keeps the directory whole.
    var no_env: std.process.Environ.Map = .init(std.testing.allocator);
    defer no_env.deinit();
    var session: ?Session = open(io, arena, &no_env, dir_path, "test/model") orelse return error.TestUnexpectedResult;
    defer close(io, &session);

    // The window, with the log this run opened among them: not the window plus
    // one, and not the window minus one either.
    try std.testing.expectEqual(max_session_logs, try countSessionLogs(io, arena, dir_path));
}

// A record's `cwd` is the directory the run worked in, which on most machines
// is under `$HOME` and names the account that ran it. The count window is a
// size, not a period: two hundred logs is a fortnight on a machine in a
// review loop and four years on one that runs a few times a week, so a store
// nobody prunes holds the working directory of every run the machine has ever
// done. This is the age half of the window, on a store well under the count.
test "the session store drops a log the age window has passed" {
    var store = try StoreFixture.init(std.testing.allocator);
    defer store.deinit();
    const io = store.io();
    const arena = store.arena();
    const dir_path = try store.path();

    // Three logs a fortnight apart, so the oldest is past the window, the
    // middle is not, and the newest is this run.
    const day_ns = ns_per_day;
    const now_ns: i128 = @intCast(40 * day_ns);
    const ages = [_]u128{ 39, 20, 1 };
    for (ages) |age| {
        const name = try std.fmt.allocPrint(arena, "{d}.jsonl", .{now_ns - @as(i128, @intCast(age * day_ns))});
        try store.tmp.dir.writeFile(io, .{ .sub_path = name, .data = "{}" });
    }
    try std.testing.expectEqual(@as(usize, 3), try countSessionLogs(io, arena, dir_path));

    // The age window took one log, and the report says one.
    try std.testing.expectEqual(@as(usize, 1), pruneSessions(io, arena, dir_path, now_ns));

    // The count was never the thing at issue: the store held three logs against
    // a limit of two hundred, and the one that went is the one past the age.
    try std.testing.expectEqual(@as(usize, 2), try countSessionLogs(io, arena, dir_path));
    try std.testing.expectError(error.FileNotFound, store.tmp.dir.access(io, try std.fmt.allocPrint(arena, "{d}.jsonl", .{now_ns - @as(i128, @intCast(ages[0] * day_ns))}), .{}));
    try store.tmp.dir.access(io, try std.fmt.allocPrint(arena, "{d}.jsonl", .{now_ns - @as(i128, @intCast(ages[2] * day_ns))}), .{});
}

// The window is a period a run measures against its own clock, and the two
// wrong clocks are the ones a machine reaches it with. Both leave the store
// as they found it.
test "a wrong clock expires nothing and a log on the window's edge is kept" {
    const day_ns = ns_per_day;
    // On the window's edge, and one day inside it, so the window in
    // nanoseconds holds the same edge the days constant names.
    try std.testing.expect(!stampExpired(max_session_log_age_ns, @intCast(60 * day_ns)));
    try std.testing.expect(stampExpired(max_session_log_age_ns - day_ns, @intCast(60 * day_ns)));
    // A clock before the epoch is a machine whose stamp is clamped to zero,
    // not one whose logs are old.
    try std.testing.expect(!stampExpired(0, -1_000_000_000));
    // A clock set back between two runs leaves a stamp past the reading, and
    // that is a wrong clock rather than a log from the future.
    try std.testing.expect(!stampExpired(90 * day_ns, @intCast(60 * day_ns)));
}

// `MICROAGENT_SESSION_DIR=logs/x` names a store through the working directory,
// and `open` creates it and its log that way, so pruning has to read it the
// same way rather than insist on an absolute path the caller never promised.
test "a store named relative to the working directory is pruned where it is" {
    var store = try StoreFixture.init(std.testing.allocator);
    defer store.deinit();
    const io = store.io();
    const arena = store.arena();

    // The store sits under the test's own temporary directory, so the same
    // relative spelling a run would be given reaches it, and the cleanup takes
    // it with the rest.
    const relative = try std.fs.path.join(arena, &.{ try storeRelative(arena, io, store.tmp), "store" });
    try store.tmp.dir.createDirPath(io, "store");
    var i: usize = 0;
    while (i < max_session_logs + 1) : (i += 1) {
        const log = createSessionLog(io, arena, relative, @intCast(i + 1)) orelse return error.TestUnexpectedResult;
        log.close(io);
    }

    // One log over the window is one delete, addressed through the relative
    // path the operator's `session_dir` can be written as.
    try std.testing.expectEqual(@as(usize, 1), pruneSessions(io, arena, relative, test_now_ns));

    try std.testing.expectEqual(max_session_logs, try countSessionLogs(io, arena, relative));
}

// The mode a log and the directory holding it are created with. What a mode
// that leaves the file readable to every other account on the machine gives
// away is the whole account of the last 200 runs: where each worked and what
// each was charged for. The mode is asserted through the real `open` and
// `createSessionLog`, because a mode named in a test and not applied is a test
// that passes on a code that never had it.
test "a session log is readable by its owner alone" {
    var store = try StoreFixture.init(std.testing.allocator);
    defer store.deinit();
    const io = store.io();
    const arena = store.arena();
    const relative = try std.fs.path.join(arena, &.{ try storeRelative(arena, io, store.tmp), "modes" });

    // An environment with no home, so `recordCwd` keeps the directory whole.
    var no_env: std.process.Environ.Map = .init(std.testing.allocator);
    defer no_env.deinit();
    var session = open(io, arena, &no_env, relative, "test/model") orelse return error.TestUnexpectedResult;
    session.file.close(io);
    defer std.Io.Dir.cwd().deleteTree(io, relative) catch {};

    // The store the run made for itself, and the log it wrote in it.
    const dir_stat = try std.Io.Dir.cwd().statFile(io, relative, .{});
    try std.testing.expectEqual(@as(u32, 0), dir_stat.permissions.toMode() & group_other_mode_bits);

    // The log is named after the run's own clock stamp, so it is found by
    // walking the store rather than by spelling a name a test cannot know.
    // Every file the walk turns up is checked, not the first one: a store
    // holding a second log nobody else can read is a claim the test would
    // otherwise have stopped short of making.
    var store_dir = try std.Io.Dir.openDir(std.Io.Dir.cwd(), io, relative, .{ .iterate = true });
    defer store_dir.close(io);
    var walker = try store_dir.walk(arena);
    defer net.drainWalk(io, &walker);
    var checked: usize = 0;
    var name_buf: [std.fs.max_path_bytes]u8 = undefined;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        checked += 1;
        const log_path = try std.fmt.bufPrint(&name_buf, "{s}/{s}", .{ relative, entry.basename });
        const log_stat = try std.Io.Dir.cwd().statFile(io, log_path, .{});
        try std.testing.expectEqual(@as(u32, 0), log_stat.permissions.toMode() & group_other_mode_bits);
        try std.testing.expect(log_stat.permissions.toMode() & owner_mode_bits == owner_mode_bits);
    }
    // Exactly the one log `open` wrote: a walk that turned up a second file, a
    // stray temp beside it, would have had its mode checked and passed anyway.
    try std.testing.expectEqual(@as(usize, 1), checked);
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
    // A skipped test is counted as passed, so a macOS run is green without it
    // and the summary names nothing; the reason is printed so the green is
    // readable as what the suite measured there.
    if (@import("builtin").os.tag.isDarwin()) {
        std.debug.print("\nskipped: macOS, where a directory name carrying an escape sequence is normalized before it is created\n", .{});
        return error.SkipZigTest;
    }
    var store = try StoreFixture.init(std.testing.allocator);
    defer store.deinit();
    const io = store.io();
    const arena = store.arena();

    const hostile = try std.fs.path.join(arena, &.{ try store.path(), "s\x1b[2J\xffstore" });
    // An environment with no home, so `recordCwd` keeps the directory whole.
    var no_env: std.process.Environ.Map = .init(std.testing.allocator);
    defer no_env.deinit();
    var live: ?Session = open(io, arena, &no_env, hostile, "test/model") orelse return error.TestUnexpectedResult;
    defer close(io, &live);

    // The log is under the real name, with the escape sequence and the byte
    // that is not text in it: the escaping a note applies never reached a path
    // the filesystem was asked about.
    var dir = try std.Io.Dir.openDirAbsolute(io, hostile, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(arena);
    defer net.drainWalk(io, &walker);
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

    try std.testing.expectEqual(@as(usize, 1), pruneSessions(io, arena, dir_path, test_now_ns));

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
// A record's `ts` is the same machine's clock read a second time, and a
// monitor orders the store by it. A negative epoch is not an instant: it sorts
// below every record the store has ever held and reads as a run fifty-six years
// old, so the same clamp the log's own name gets is the one the record gets.
test "a record stamped from a clock before 1970 carries the epoch, not a negative" {
    const before_epoch_ns: i96 = -1_000_000_000;
    try std.testing.expectEqual(@as(i64, 0), recordStampMs(before_epoch_ns));
    // And the far side of the epoch is the reading itself, so the clamp is not
    // quietly taking every time before some other line.
    try std.testing.expectEqual(@as(i64, 1_000), recordStampMs(1_000_000_000));
    try std.testing.expectEqual(@as(i64, 1_759_000_000_000), recordStampMs(1_759_000_000_000_000_000));
    // The zero the clamp gives is the value a reader of the store can still
    // compare, which is the whole reason it is zero rather than the negative.
    try std.testing.expect(recordStampMs(before_epoch_ns) >= 0);
    // A clock set far ahead is the same narrowing from the other end. The
    // reading is an `i96`, and in milliseconds it still reaches past what an
    // `i64` holds, so a host whose clock is set past what the machine has
    // reached is a machine this record cannot be written for. The last stamp
    // there is, which a monitor can still order.
    try std.testing.expectEqual(std.math.maxInt(i64), recordStampMs(std.math.maxInt(i96)));
}

test "a log named from a clock before 1970 is still one the pruner counts" {
    var store = try StoreFixture.init(std.testing.allocator);
    defer store.deinit();
    const io = store.io();
    const arena = store.arena();
    const dir_path = try store.path();

    // The stamp `open` computes for a clock reading before the epoch.
    const before_epoch_ns: i128 = -1_000_000_000;
    const stamp = logStamp(before_epoch_ns);
    try std.testing.expectEqual(@as(u128, 0), stamp);
    // The same reading on the far side of the epoch is the stamp itself, so the
    // clamp is not quietly taking every time before some other line.
    try std.testing.expectEqual(@as(u128, 1_000_000_000), logStamp(1_000_000_000));
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
    try std.testing.expectEqual(@as(usize, 1), pruneSessions(io, arena, dir_path, test_now_ns));

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

    // A window of this width takes one of each pair, and the report counts
    // only the logs it removed: the `1` stamp twice, the rest once.
    try std.testing.expectEqual(@as(usize, max_session_logs), pruneSessions(io, arena, dir_path, test_now_ns));

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
/// prunes by, so the count a test asserts is the count the pruner sees. The
/// store may be named absolute, or relative to the working directory, which
/// `open` accepts and an absolute path alone would not exercise.
fn countSessionLogs(io: Io, arena: std.mem.Allocator, session_dir: []const u8) !usize {
    var dir = try std.Io.Dir.openDir(std.Io.Dir.cwd(), io, session_dir, .{ .iterate = true });
    defer dir.close(io);
    return countLogsIn(dir, io, arena);
}

/// The clock the store tests prune against. The tests write stamps of a few
/// hundred nanoseconds, so a reading a few hundred seconds past the epoch
/// leaves every one of them well inside the age window, and the count window
/// stays the thing each of those tests is about. The age window has its own.
const test_now_ns: i128 = @as(i128, max_session_logs + 1) * std.time.ns_per_s;

fn countLogsIn(dir: Io.Dir, io: Io, arena: std.mem.Allocator) !usize {
    var walker = try dir.walk(arena);
    defer net.drainWalk(io, &walker);
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

    // One log is past the limit, so exactly one delete is reported as well as
    // made: a pruner that took the nested log and also counted the root's own
    // name toward its report would leave the directory looking right.
    try std.testing.expectEqual(@as(usize, 1), pruneSessions(io, arena, dir_path, test_now_ns));

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
    // The count is the part a monitor can be held to, and a store that could
    // not be walked has no window to prune against.
    try std.testing.expectEqual(@as(usize, 0), pruneSessions(io, arena, missing, test_now_ns));
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

    // An environment with no home, so `recordCwd` keeps the directory whole.
    var no_env: std.process.Environ.Map = .init(std.testing.allocator);
    defer no_env.deinit();
    try std.testing.expectEqual(@as(?Session, null), open(io, arena, &no_env, blocked, "test/model"));
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

    // A clock at the epoch expires nothing, so the two properties this fuzzer
    // reads are the count window's alone. The age window prunes the same
    // prefix, and `the session store drops a log the age window has passed`
    // is the test on it.
    const removed = pruneSessionsTo(io, arena, dir_path, keep, 0);

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
    // And the report is the same set the directory holds: a pruner that
    // removed a name the walk never saw, or left one out of its own count,
    // is wrong whichever of the two it did.
    try std.testing.expectEqual(deleted.items.len, removed);
    // And what is left is the newest of them, so no log that survived is older
    // than one that was deleted.
    for (deleted.items) |gone| {
        for (survivors.items) |kept| {
            try std.testing.expect(!kept.key.?.olderThan(gone.key.?));
        }
    }
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

    // The five strings, split out of the same bytes so one seed reaches all of
    // them at once, and a cut inside any one of them.
    const third = text.len / 3;
    const cwd = text[0..third];
    const model = text[third .. 2 * third];
    const tail = text[2 * third ..];
    const finish_reason = try arena.dupe(u8, tail[0 .. tail.len / 3]);
    const served_model = try arena.dupe(u8, tail[tail.len / 3 .. 2 * tail.len / 3]);
    const fingerprint = try arena.dupe(u8, tail[2 * tail.len / 3 ..]);

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
        .served_model = served_model,
        .fingerprint = fingerprint,
    };

    const line = try sessionRecord(arena, ts_ms, cwd, model, .{ .elapsed_ms = elapsed_ms, .response = &result });

    // One record, one line. The store is JSONL and a monitor reads it while the
    // run is still going, so a newline inside any of the strings splits the
    // record into two responses the monitor will not join back together.
    try std.testing.expect(std.mem.endsWith(u8, line, "\n"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, line, "\n"));

    try std.testing.expect(try std.json.validate(gpa, line[0 .. line.len - 1]));

    const parsed = try std.json.parseFromSlice(std.json.Value, arena, line[0 .. line.len - 1], .{});
    const obj = parsed.value.object;

    // The strings that went in are the strings a monitor reads, and the
    // numbers are the numbers the record was built from.
    try expectSameString(obj, "cwd", cwd);
    try expectSameString(obj, "model", model);
    // The model that answered beside the one the run asked for: the record is
    // what outlives the run, so it is the only place a reader can find which
    // snapshot behind a routed name produced it.
    try expectSameString(obj, "served_model", served_model);
    try expectSameString(obj, "fingerprint", fingerprint);
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
