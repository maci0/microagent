//! Every tool the model can call, and the process runner they share.
//!
//! The agent loop owns the conversation and the provider request; this owns
//! what runs on the machine for it. That split is the boundary that matters:
//! everything below is reached by a model-supplied name and model-supplied
//! arguments, so it is capped, reaped and reported from one place.

const std = @import("std");
const Io = std.Io;

const chat = @import("chat.zig");
const net = @import("net.zig");

/// How much of one tool's output reaches the model. The whole conversation is
/// re-sent every turn, so what a tool prints is paid for again on each of them;
/// a build log or a broad ripgrep is kilobytes. Each of a child's two streams
/// is captured at four times this, and `clamp` cuts the combined result at a
/// codepoint boundary and appends a marker naming how much was dropped, so a
/// model reading a truncated log knows the tail is missing rather than reading
/// a build failure as the end of the output. `git` is the exception: it is cut
/// by line count instead.
pub const max_tool_output = 24 * 1024;

/// Ceiling on a file `read` returns whole. A source file is kilobytes, so the
/// cap is what keeps one `read` of a multi-gigabyte artifact out of the
/// conversation.
const max_read_bytes: usize = 4 * 1024 * 1024;
/// `edit` reads the file it rewrites, so it holds the larger of the two.
const max_edit_bytes: usize = 8 * 1024 * 1024;
/// A secret file is one key, not a document.
const max_secret_bytes: usize = 4096;

/// The two lines `bash` appends after the output it captured, kept as constants
/// so the buffer it assembles is sized from the same text it writes. Each
/// carries its own leading newline; the newline is emitted separately when
/// there is output for it to separate.
const bash_truncation_note = "\n[output truncated at the tool's cap]";
const bash_exit_note = "\n(exit: )";
/// An exit number is a wait status, so it is three digits at most. Sized here
/// rather than guessed, because it is the one part of the exit line whose
/// width is not fixed by the constant around it.
const exit_status_max_digits = 3;

/// How long a read-only tool subprocess may run: `search`, `ast` and `git`.
/// `bash` has its own default and ceiling below, because it is the one tool
/// that runs what the model wrote. `max_tool_output * 4` is how much of each of
/// a child's streams is kept before `clamp` trims the result to
/// `max_tool_output` for the model.
const tool_timeout_ms: u64 = 60_000;
/// Ceiling on the `timeout_ms` a model may ask `bash` for. The value is model
/// output, so it arrives with the same trust as a path or a command string: an
/// unbounded one leaves a build running with no deadline, and the process-group
/// kill that reaps it never fires. A request past this gets the ceiling.
const max_bash_timeout_ms: u64 = 600_000;
/// What `bash` runs under when the model sends no `timeout_ms`.
const default_bash_timeout_ms: u64 = 120_000;

/// A tool deadline cut down to what is left of the run's time budget.
///
/// Without it the budget is a promise the tools do not keep: a `bash` call
/// with a two-minute timeout starts happily at second 779 of a 780-second
/// budget and the caller kills the run mid-command, which is what the budget
/// exists to prevent. `ceiling_ms` is null when the run set no budget, and the
/// floor is the caller's: it never hands a tool a zero timeout, which would
/// fail before the tool could even start.
fn boundedMs(wanted_ms: u64, ceiling_ms: ?u64) u64 {
    const ceiling = ceiling_ms orelse return wanted_ms;
    return @min(wanted_ms, ceiling);
}

/// A tool subprocess in its own process group, and the reap that every tool
/// owes its call.
///
/// `std.process.run` signals only the process it spawned, so a tool call that
/// timed out, or that hit an output cap, left the rest of its process tree
/// running: the shell died, the build it had launched kept compiling, and the
/// next turn inherited whatever those orphans held. Every tool subprocess is
/// therefore its own group leader, so the group signal stays the caller's to
/// send. One place spells that, because a runner that spawned without it is a
/// runner that leaks a process tree.
const ToolChild = struct {
    child: std.process.Child,
    pgid: std.posix.pid_t,

    pub fn spawn(io: Io, argv: []const []const u8, environ_map: ?*const std.process.Environ.Map) !ToolChild {
        const child = try std.process.spawn(io, .{
            .argv = argv,
            .pgid = 0, // its own group leader, so the group signal stays ours
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .pipe,
            // Null inherits this process's environment, which is how a tool
            // subprocess used to see the provider key. Every call site passes
            // the scrubbed copy the run builds once instead, so the key is
            // never in a child's environment to print.
            .environ_map = environ_map,
        });
        return .{
            .child = child,
            .pgid = @intCast(child.id.?),
        };
    }

    /// Signals the whole group and then reaps the direct child, so a timeout
    /// leaves neither an orphan nor a zombie. A child already reaped by `wait`
    /// is a no-op here, and its group still gets the signal: a command that
    /// backgrounded work and exited must not outlive the call.
    pub fn reap(self: *ToolChild, io: Io) void {
        signalGroup(self.pgid);
        self.child.kill(io);
    }
};

/// A key file, and which of the three things happened to it.
pub const SecretRead = union(enum) {
    /// The file is not there, which is the ordinary case for a run that has
    /// its key somewhere else.
    absent,
    /// The file is there and holds a key.
    found: []const u8,
    /// The file is there and could not be read, with the reason.
    unreadable: struct { reason: anyerror },
};

/// Reads a key file whole and trimmed, under a cap of its own rather than the
/// one `read` uses for source: a secret is one key, not a document.
///
/// The reason comes back with the answer, because "there is no key file" and
/// "the key file is there and this process cannot read it" are different
/// problems with different fixes, and a caller that cannot tell them apart
/// tells its caller there is no key. A file whose permissions or ownership
/// stopped this process reading it is a key that is set and unusable, and
/// `error.StreamTooLong` is the one failure here that is not about access at
/// all: the caller says so rather than reporting a missing key.
///
/// Takes the io and the arena rather than the process init, so the two file
/// boundaries a key arrives through (the mark, then the surrounding
/// whitespace) are testable without standing up an init.
pub fn readSecret(io: Io, arena: std.mem.Allocator, path: []const u8) SecretRead {
    const raw = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_secret_bytes)) catch |err| switch (err) {
        error.FileNotFound => return .absent,
        else => |e| return .{ .unreadable = .{ .reason = e } },
    };
    // The BOM first, then the whitespace: `trim` cuts the ASCII set, and U+FEFF
    // is not in it, so a key file an editor saved with a BOM would otherwise
    // send the BOM to the provider as the first byte of the key.
    return .{ .found = std.mem.trim(u8, chat.stripBom(raw), " \t\r\n") };
}

/// SIGKILL to a whole process group. A group that is already gone is the normal
/// case, not a failure.
fn signalGroup(pgid: std.posix.pid_t) void {
    std.posix.kill(-pgid, .KILL) catch {};
}

/// The group of the tool subprocess in flight, published for the interrupt
/// handler. A tool child leads its own group, so the terminal's Ctrl+C never
/// reaches it: without this the user stops the agent and the build it launched
/// keeps writing files behind it. Zero means no tool call is running.
var tool_group: std.atomic.Value(std.posix.pid_t) = .init(0);

/// A signal that ends the run takes the tool subprocess with it, then leaves by
/// the code the shell reads as an interrupt.
fn onInterrupt(_: std.posix.SIG) callconv(.c) void {
    const group = tool_group.load(.monotonic);
    if (group > 0) signalGroup(group);
    std.process.exit(130);
}

fn watchToolGroup(pgid: std.posix.pid_t) void {
    tool_group.store(pgid, .monotonic);
}

/// Installed once the run starts, so Ctrl+C and `kill` reach the tools. Help,
/// the version and the update subcommand own no subprocess and keep the default
/// disposition. The disposition below is POSIX, which is every platform the
/// release ships: a target without `sigaction` fails to compile here rather
/// than building a binary that quietly leaves a tool's process group behind.
pub fn forwardInterruptsToToolGroup() void {
    var act: std.posix.Sigaction = undefined;
    act.handler = .{ .handler = onInterrupt };
    act.mask = std.posix.sigemptyset();
    act.flags = 0;
    std.posix.sigaction(.INT, &act, null);
    std.posix.sigaction(.TERM, &act, null);
}

/// A tool that delegates to a binary already on PATH: the caller builds the
/// argv, and the failure text, the empty result and the two output streams are
/// handled the same way for each of them.
fn runSearchTool(io: Io, arena: std.mem.Allocator, argv: []const []const u8, what: []const u8, ceiling_ms: ?u64, environ_map: ?*const std.process.Environ.Map) ![]u8 {
    // The cap drains rather than fails, for the reason `runCapped` gives: a
    // broad ripgrep over a large tree passed the capture limit and came back
    // as `error: StreamTooLong` with no output at all, so the model was told
    // the search had failed rather than that it had found too much.
    const res = runCapped(io, arena, argv, max_tool_output * 4, net.durationMs(boundedMs(tool_timeout_ms, ceiling_ms)), environ_map) catch |err|
        return std.fmt.allocPrint(arena, "error: {s} failed: {s}", .{ what, @errorName(err) });
    if (res.stdout.len > 0) return withCaptureNote(arena, res.stdout, res);
    if (res.stderr.len > 0) return res.stderr;
    return std.fmt.allocPrint(arena, "(no matches)", .{});
}

/// The captured stream with a line saying that it is the beginning of a longer
/// output. A half-read match list reads as the whole one otherwise, and the
/// model narrows its next search against what it did not see.
fn withCaptureNote(arena: std.mem.Allocator, text: []u8, res: Captured) ![]u8 {
    if (!atCaptureLimit(res)) return text;
    return std.fmt.allocPrint(arena, "{s}\n[output truncated at the tool's cap]", .{text});
}

/// Lines of git output a call keeps when the model asks for no limit: a raw
/// `git log` in a big repository is thousands of lines of context nobody reads.
const git_default_limit: usize = 400;

/// How many lines of git output the model reads. `limit` is a ceiling, so a
/// limit of zero is one line rather than the whole output, and a limit a 32-bit
/// `usize` cannot hold is every line rather than a trap.
fn gitLineLimit(args: std.json.ObjectMap) usize {
    const v = args.get("limit") orelse return git_default_limit;
    const n = countArg(v) orelse return git_default_limit;
    return @max(1, std.math.cast(usize, n) orelse std.math.maxInt(usize));
}

/// A count the model sent, or null when it sent something that is not one.
///
/// `chat.num` answers 0 for every value it cannot read as a number, which is
/// the right answer for a token counter that starts at zero and the wrong one
/// for a line count: a `limit` of `"3"` became a limit of zero, so the call
/// returned an empty result and the model read it as a file with nothing in
/// it. A number spelled as a string is a number a model meant, so it is read
/// as one; a value that is neither is the model's mistake to be told about by
/// the default rather than answered with the wrong lines.
fn countArg(v: ?std.json.Value) ?u64 {
    const value = v orelse return null;
    return switch (value) {
        .integer => |n| if (n > 0) @intCast(n) else 0,
        .float => |f| std.math.lossyCast(u64, f),
        .number_string, .string => |s| std.fmt.parseInt(u64, s, 10) catch null,
        else => null,
    };
}

/// The largest count handed to `git log -n`. Its own argument parser refuses a
/// number past `INT_MAX` with `fatal: not an integer`, so a model asking for
/// every line in a large repository was answered with an error and no log at
/// all. The ceiling is far above what the capture cap lets through anyway, so
/// a count past it costs nothing to lose.
const git_log_line_ceiling: usize = 1 << 20;

/// The `-n` argument for `git log`: the model's limit, cut to what git parses.
fn gitLogLines(limit: usize) usize {
    return @min(limit, git_log_line_ceiling);
}

/// Read-only git, with the subcommands fixed here rather than assembled by the
/// model. Deterministic, no shell quoting, and the output is capped.
fn toolGit(io: Io, arena: std.mem.Allocator, args: std.json.ObjectMap, ceiling_ms: ?u64, environ_map: ?*const std.process.Environ.Map) ![]u8 {
    const cmd = chat.str(args.get("cmd")) orelse return std.fmt.allocPrint(arena, "error: missing cmd", .{});
    const path = chat.str(args.get("path"));
    const rev = chat.str(args.get("rev"));
    const limit = gitLineLimit(args);
    // A rev such as `--output=FILE` would turn a read into a write.
    if (rev) |r| if (std.mem.startsWith(u8, r, "-"))
        return std.fmt.allocPrint(arena, "error: rev must not start with '-'", .{});
    // A rev that carries a path after a colon (`HEAD:.env`, `main:keys/id`)
    // is a tree-ish plus a file, and git shows that file whatever the
    // `:(exclude)` pathspecs below say: they filter a revision's diff, not an
    // object named on the command line. So the exclusion set this tool relies
    // on does not reach it, and a committed credential comes back as a tool
    // result that is re-sent to the provider on every later turn. A file is
    // what the `path` argument is for, and that one is checked.
    if (rev) |r| if (std.mem.indexOfScalar(u8, r, ':')) |colon| {
        const named = r[colon + 1 ..];
        if (isCredentialPath(named)) return credentialRefusal(arena, "git", named);
        return std.fmt.allocPrint(arena, "error: rev must name a revision, not a file; use the path argument for a file (got '{s}')", .{
            chat.safeText(arena, r, 120),
        });
    };
    // `git show <rev> -- .env` prints a committed credentials file as a patch,
    // so the path gets the refusal `read` gives it rather than a git one.
    if (path) |p| if (isCredentialPath(p)) return credentialRefusal(arena, "git", p);

    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ "git", "--no-pager" });
    if (std.mem.eql(u8, cmd, "status")) {
        try argv.appendSlice(arena, &.{ "status", "--short", "--branch" });
    } else if (std.mem.eql(u8, cmd, "diff")) {
        try argv.appendSlice(arena, &.{ "diff", "--no-color" });
        if (rev) |r| try argv.append(arena, r);
    } else if (std.mem.eql(u8, cmd, "log")) {
        // git counts the lines the model asked for, so a `limit` above the
        // 400-line default is honored, and one past what git parses
        // (`INT_MAX`) is cut to what it will accept rather than turned into
        // `fatal: not an integer`.
        try argv.appendSlice(arena, &.{ "log", "--oneline", "--no-color", "-n" });
        try argv.append(arena, try std.fmt.allocPrint(arena, "{d}", .{gitLogLines(limit)}));
    } else if (std.mem.eql(u8, cmd, "show")) {
        try argv.appendSlice(arena, &.{ "show", "--no-color", "--stat", "--patch" });
        try argv.append(arena, rev orelse "HEAD");
    } else if (std.mem.eql(u8, cmd, "blame")) {
        try argv.append(arena, "blame");
        if (rev) |r| try argv.append(arena, r);
    } else {
        return std.fmt.allocPrint(arena, "error: unknown git cmd '{s}'", .{cmd});
    }
    // `--` keeps a path from being read as an option.
    try argv.append(arena, "--");
    if (path) |p| {
        try argv.append(arena, p);
    } else if (std.mem.eql(u8, cmd, "diff") or std.mem.eql(u8, cmd, "show")) {
        // The refusal above only covers a credential the model named. A
        // `git show HEAD` with no path prints the whole commit, and a `.env`,
        // a `.pem` or a `.secrets/` file that was ever committed comes back in
        // it as a tool result, which is re-sent to the provider on every later
        // turn. The names come from the same tables `search` and `ast` exclude
        // by, so a credential is out of the git tool's results as well as out
        // of the ones it is asked for by name.
        try argv.appendSlice(arena, &credential_pathspecs);
    }

    // The cap drains rather than fails, for the reason `runCapped` gives: the
    // default here is 400 lines, and 400 long diff lines pass the capture cap,
    // so a call the model asked to be trimmed came back as
    // `error: git diff failed: StreamTooLong` with no lines at all.
    const res = runCapped(io, arena, argv.items, max_tool_output * 4, net.durationMs(boundedMs(tool_timeout_ms, ceiling_ms)), environ_map) catch |err|
        return std.fmt.allocPrint(arena, "error: git {s} failed: {s}", .{ cmd, @errorName(err) });
    const text = if (res.stdout.len > 0) res.stdout else res.stderr;
    if (text.len == 0) return std.fmt.allocPrint(arena, "(git {s}: no output)", .{cmd});
    return firstLines(arena, text, limit);
}

/// The first `limit` lines, with a note when lines were dropped.
fn firstLines(arena: std.mem.Allocator, text: []const u8, limit: usize) ![]u8 {
    var lines: usize = 0;
    var end: usize = text.len;
    var at: usize = 0;
    while (std.mem.indexOfScalarPos(u8, text, at, '\n')) |nl| {
        lines += 1;
        if (lines == limit) {
            end = nl + 1;
            break;
        }
        at = nl + 1;
    }
    if (end == text.len) return arena.dupe(u8, text);
    return std.fmt.allocPrint(arena, "{s}... [output truncated at {d} lines]", .{ text[0..end], limit });
}

pub fn runTool(io: Io, arena: std.mem.Allocator, call: chat.ToolCall, ceiling_ms: ?u64, environ_map: ?*const std.process.Environ.Map) ![]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, arena, call.args.items, .{}) catch
        return std.fmt.allocPrint(arena, "error: tool arguments are not valid JSON", .{});
    const args = switch (parsed.value) {
        .object => |o| o,
        else => return std.fmt.allocPrint(arena, "error: tool arguments must be an object", .{}),
    };

    noteToolCall(io, arena, call.name, args);
    if (std.mem.eql(u8, call.name, "bash")) return toolBash(io, arena, args, ceiling_ms, environ_map);
    if (std.mem.eql(u8, call.name, "read")) return toolRead(io, arena, args);
    if (std.mem.eql(u8, call.name, "write")) return toolWrite(io, arena, args);
    if (std.mem.eql(u8, call.name, "edit")) return toolEdit(io, arena, args);
    if (std.mem.eql(u8, call.name, "search")) return toolSearch(io, arena, args, ceiling_ms, environ_map);
    if (std.mem.eql(u8, call.name, "ast")) return toolAst(io, arena, args, ceiling_ms, environ_map);
    if (std.mem.eql(u8, call.name, "git")) return toolGit(io, arena, args, ceiling_ms, environ_map);
    return std.fmt.allocPrint(arena, "error: unknown tool '{s}'", .{call.name});
}

/// The gutter line, without the stream it is written to, so the one-line shape
/// is a value a test can hold rather than a stream it has to capture. Every
/// field is bounded, so the line fits a buffer of this length whatever the
/// model sent: the marker, the name, one space, the detail and the newline.
const gutter_line_max = 5 + 40 + 1 + 120 + 1;

/// A one-line tool gutter on stderr, the shape gauntlet recognizes. The name
/// and the detail are the provider's own text and may carry a newline or an
/// escape sequence, either of which breaks the one-line-per-call shape a reader
/// parses, so control characters are written as their two-character escapes.
fn noteToolCall(io: Io, arena: std.mem.Allocator, name: []const u8, args: std.json.ObjectMap) void {
    var buf: [gutter_line_max]u8 = undefined;
    net.writeErr(io, toolCallLine(arena, &buf, name, args) catch return);
}

fn toolCallLine(arena: std.mem.Allocator, buf: []u8, name: []const u8, args: std.json.ObjectMap) ![]const u8 {
    // The interesting argument is not the same one for every tool: a structural
    // search is identified by its pattern, a bash call by its command.
    const detail = if (std.mem.eql(u8, name, "ast"))
        (chat.str(args.get("pattern")) orelse "")
    else
        (chat.str(args.get("command")) orelse chat.str(args.get("pattern")) orelse chat.str(args.get("path")) orelse "");
    // One spelling of "text the operator can be shown", shared with the
    // diagnostics: cut on a codepoint boundary, controls as `\xNN`, and a byte
    // that is not text as U+FFFD. A tool argument is whatever the model decided
    // to send, and the model decides that from files in the tree, so the gutter
    // line is a boundary like any other.
    return std.fmt.bufPrint(
        buf,
        "\u{23fa} {s} {s}\n",
        .{ chat.safeText(arena, name, 40), chat.safeText(arena, detail, 120) },
    );
}

/// Bytes a terminal acts on rather than prints: the C0 controls, DEL, and the
/// C1 range, which UTF-8 spells as C2 80..9F. A tool argument is whatever the
/// model decided to send, and the model decides that from files in the tree, so
/// a repository can put an escape sequence on the operator's screen through
/// the gutter line. A diagnostic note shows them as `.`; the model's own output
/// on stdout is left alone, because that is the answer the run was asked for.
pub fn terminalSafe(arena: std.mem.Allocator, s: []const u8) []const u8 {
    const out = arena.alloc(u8, s.len) catch return s;
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (c == 0xc2 and i + 1 < s.len and s[i + 1] >= 0x80 and s[i + 1] <= 0x9f) {
            out[i] = '.';
            out[i + 1] = '.';
            i += 2;
            continue;
        }
        out[i] = if (c < 0x20 or c == 0x7f) '.' else c;
        i += 1;
    }
    return out;
}

/// The deadline one `bash` call runs under: what the model asked for, the
/// tool's own default when it asked for nothing, and never past the ceiling.
/// Separated from the tool so the rule is testable without waiting out a
/// timeout that is ten minutes long.
fn bashTimeoutMs(requested: ?u64, ceiling_ms: ?u64) u64 {
    return boundedMs(@min(requested orelse default_bash_timeout_ms, max_bash_timeout_ms), ceiling_ms);
}

/// The timeout the model asked for, or null when it asked for none.
///
/// `countArg` reads a number the model wrote, and null for one it did not, but
/// a timeout it did write can still be a value no command can run under: a
/// zero or a negative one is not "no time", it is a deadline already spent, and
/// the call came back `command timed out after 0ms` without the command ever
/// starting. The documented default is what a request that names no usable
/// timeout gets.
fn requestedTimeoutMs(v: ?std.json.Value) ?u64 {
    const n = countArg(v) orelse return null;
    return if (n > 0) n else null;
}

/// The first path in a shell command that names a credential file, or null.
///
/// `bash` takes a command rather than a path, so `isCredentialPath` has no
/// single argument to read. Splitting the command into words and testing each
/// is the same rule applied per word, and it is deliberately narrow: only a
/// word that looks like a path is tested, meaning it carries a separator or a
/// dot in its last component. A bare `identity` or `credentials` is an ordinary
/// word to grep for, and refusing every command that contains one would break
/// the searches that use them rather than protect anything. `cat .env`,
/// `cat ./.env`, `cat "$PWD"/.env and `cat ~/.ssh/id_rsa` are all refused,
/// because each of those words is a path.
///
/// This is a name check, not a shell parse, and it says so: a command that
/// reaches the same file through indirection (`f=$(printf '.en''v'); cat
/// "$f"`) is not caught here. Catching that needs a shell parser, and the
/// guarantee that matters most, that the run's own key never reaches a child's
/// environment, is structural rather than textual.
fn credentialInCommand(command: []const u8) ?[]const u8 {
    var words = std.mem.tokenizeAny(u8, command, " \t\n\"'`$&;<>|()[]{}*?!#\\");
    while (words.next()) |word| {
        const leaf = std.fs.path.basename(word);
        if (std.mem.indexOfScalar(u8, word, std.fs.path.sep) == null and std.mem.indexOfScalar(u8, leaf, '.') == null) continue;
        if (isCredentialPath(word)) return word;
    }
    return null;
}

fn toolBash(io: Io, arena: std.mem.Allocator, args: std.json.ObjectMap, ceiling_ms: ?u64, environ_map: ?*const std.process.Environ.Map) ![]u8 {
    const command = chat.str(args.get("command")) orelse return std.fmt.allocPrint(arena, "error: missing command", .{});
    // `bash` is the one tool with no path argument to check, and it can read
    // every file the three guarded tools refuse: `cat .env` and
    // `git show HEAD -- .env` both come back whole, and a tool result is
    // re-sent to the provider on every later turn. So the same name check runs
    // over the command's own words.
    if (credentialInCommand(command)) |path| return credentialRefusal(arena, "bash", path);
    const timeout_ms: u64 = bashTimeoutMs(requestedTimeoutMs(args.get("timeout_ms")), ceiling_ms);
    const capture_limit = max_tool_output * 4;
    const res = runCapped(io, arena, &.{ "/bin/sh", "-c", command }, capture_limit, net.durationMs(timeout_ms), environ_map) catch |err| switch (err) {
        error.Timeout => return std.fmt.allocPrint(arena, "error: command timed out after {d}ms", .{timeout_ms}),
        else => return std.fmt.allocPrint(arena, "error: {s}", .{@errorName(err)}),
    };
    // The captured size is known before the first append, so the buffer is
    // sized once rather than doubling its way up to `capture_limit` on each
    // stream, copying everything written so far at every step. The two
    // trailing notes are the only other bytes written to it; they are spelled
    // as constants so the reservation and the writes cannot drift apart.
    var buf: std.ArrayList(u8) = .empty;
    try buf.ensureTotalCapacity(arena, res.stdout.len + res.stderr.len +
        bash_truncation_note.len + bash_exit_note.len + exit_status_max_digits);
    if (res.stdout.len > 0) try buf.appendSlice(arena, res.stdout);
    if (res.stderr.len > 0) {
        if (buf.items.len > 0) try buf.appendSlice(arena, "\n");
        try buf.appendSlice(arena, res.stderr);
    }
    // Output the model acts on is cut at the cap, so say so rather than letting
    // a half-read build log or diff read as the whole one.
    if (atCaptureLimit(res)) {
        if (buf.items.len > 0) try buf.appendSlice(arena, "\n");
        try buf.appendSlice(arena, bash_truncation_note[1..]);
    }
    if (buf.items.len == 0) return std.fmt.allocPrint(arena, "(no output, exit {s})", .{@tagName(res.term)});
    if (res.term != .exited or res.term.exited != 0) {
        try buf.appendSlice(arena, bash_exit_note[0 .. bash_exit_note.len - 1]);
        try buf.appendSlice(arena, @tagName(res.term));
        if (res.term == .exited)
            try buf.appendSlice(arena, try std.fmt.allocPrint(arena, " {d}", .{res.term.exited}));
        try buf.appendSlice(arena, ")");
    }
    return buf.items;
}

/// Directories whose every file is a credential. Matched per path component,
/// so `~/.secrets/openrouter` and `.ssh/id_ed25519` are refused wherever they
/// sit in the tree.
const credential_dirs = [_][]const u8{ ".secrets", ".ssh" };

/// Names that are a credential whatever they sit beside.
const credential_names = [_][]const u8{
    ".netrc",      "_netrc",           ".pgpass",   ".npmrc",
    ".pypirc",     ".git-credentials", ".htpasswd", "credentials",
    "id_rsa",      "id_dsa",           "id_ecdsa",  "id_ed25519",
    "id_ecdsa_sk", "id_ed25519_sk",    "identity",  ".dockercfg",
    ".my.cnf",
};

/// Extensions only a key or a keystore carries. A `.crt` is not one: it is the
/// public half, and refusing it would break reading a bundle someone committed.
const credential_extensions = [_][]const u8{ ".pem", ".key", ".p12", ".pfx", ".jks", ".keystore", ".ppk", ".kdbx", ".asc" };

fn isCredentialName(name: []const u8) bool {
    // Case-insensitively: a macOS or Windows filesystem resolves `.ENV` and
    // `.env` to the same bytes, so a case-sensitive rule is a rule the next
    // platform does not enforce.
    for (credential_names) |c| {
        if (name.len == c.len and std.ascii.eqlIgnoreCase(name, c)) return true;
    }
    for (credential_extensions) |ext| {
        if (std.ascii.endsWithIgnoreCase(name, ext)) return true;
    }
    // `.env`, `.env.local`, `.envrc` and `production.env` are the spellings the
    // same file ships under. `.env.example` and `.env.sample` are refused with
    // them: a template that was committed with a real value in it is exactly
    // the file a name-based rule must not wave through.
    if (name.len >= 4 and std.ascii.eqlIgnoreCase(name[0..4], ".env")) return true;
    if (name.len > 4 and std.ascii.endsWithIgnoreCase(name, ".env")) return true;
    return false;
}

/// The same names, as the ignore globs `search` and `ast` hand their backends
/// and `git` receives as exclusion pathspecs.
///
/// A search that matches a line of `.env` returns it as a tool result, and a
/// tool result is re-sent to the provider on every later turn of the run: the
/// refusal `read` makes is no protection to the operator when the same bytes
/// come back one tool over. The globs are derived from the tables above rather
/// than spelled beside them, so a name added to those is excluded here too.
///
/// The names are case-sensitive globs, which is why `search` also passes
/// `--glob-case-insensitive`; `ast-grep` has no such flag, so a tree searched
/// with `ast` can still match a file whose name is spelled in another case.
const credential_glob_table: [credential_globs_capacity][]const u8 = blk: {
    var list: [credential_globs_capacity][]const u8 = undefined;
    var n: usize = 0;
    for (credential_names) |c| {
        list[n] = "!" ++ c;
        n += 1;
    }
    for (credential_extensions) |ext| {
        list[n] = "!*" ++ ext;
        n += 1;
    }
    // The three spellings `isCredentialName` reads as one family.
    list[n] = "!.env";
    n += 1;
    list[n] = "!.env*";
    n += 1;
    list[n] = "!*.env";
    n += 1;
    for (credential_dirs) |dir| {
        list[n] = "!" ++ dir;
        n += 1;
    }
    break :blk list;
};

/// Every name, extension, directory and `.env` spelling the tables above carry.
const credential_globs_capacity = credential_names.len + credential_extensions.len + credential_dirs.len + 3;

const credential_globs: []const []const u8 = credential_glob_table[0..credential_globs_capacity];

/// The same names as git pathspec exclusions, built at compile time. `git` is
/// handed a pathspec rather than a glob, so the leading `!` comes off and the
/// rest is rewritten, and the result is the same on every call: formatting
/// them per `git diff` and per `git show` was one allocation per name, on
/// the turn arena, for strings the compiler already knows.
const credential_pathspecs = blk: {
    var list: [credential_globs_capacity][]const u8 = undefined;
    for (credential_globs, 0..) |glob, i| list[i] = ":(exclude,icase)" ++ glob[1..];
    break :blk list;
};

test "every credential the name rule refuses is in the exclusion set git carries" {
    // The `git show`/`git diff` exclusions are the globs above rewritten as
    // pathspecs, so a name added to the tables and left out of this check is
    // a credential the name rule refuses and the git tool still prints.
    for (credential_globs) |glob| {
        const pattern = glob[1..];
        const leaf = if (std.mem.startsWith(u8, pattern, "*")) pattern[1..] else pattern;
        if (isCredentialName(leaf)) continue;
        // A directory is a component, not a leaf name, and `.env*` covers a
        // spelling the leaf check reads through its own rules.
        var is_dir = false;
        for (credential_dirs) |dir| {
            if (std.mem.eql(u8, pattern, dir)) is_dir = true;
        }
        try std.testing.expect(is_dir or std.mem.startsWith(u8, pattern, ".env"));
    }
}

/// The target's own path separator, as `std.mem.trimEnd` wants it. The walk
/// below reaches for `std.fs.path.dirname` and `basename`, which know the
/// separator, and the two places that strip or test one by hand read it from
/// here: a literal `/` beside them is a second spelling of the same rule, and
/// it is the spelling that stops matching on a target whose separator is not
/// `/`.
const path_sep = [_]u8{std.fs.path.sep};

/// True when a path names a credential file, so the tools that read, search or
/// name a path refuse it: `read`, `search`, `ast`, `git`, and the word check
/// `bash` runs over its command. The path is
/// model-supplied text and never touches the filesystem before this runs, so
/// the answer is a decision about the name, not about what opened.
fn isCredentialPath(path: []const u8) bool {
    // Every component, not just the leaf: `~/.secrets/openrouter` is named by a
    // directory the path only passes through. dirname and basename are the
    // target's own separator, so the walk is right on the platforms this ships
    // to and needs no second spelling. A trailing separator is trimmed first,
    // or the leaf basename comes back empty and the name goes unchecked.
    var component: ?[]const u8 = std.mem.trimEnd(u8, path, &path_sep);
    while (component) |c| {
        const name = std.fs.path.basename(c);
        if (name.len != 0 and !std.mem.eql(u8, name, ".") and !std.mem.eql(u8, name, "..")) {
            for (credential_dirs) |dir| {
                if (name.len == dir.len and std.ascii.eqlIgnoreCase(name, dir)) return true;
            }
        }
        component = std.fs.path.dirname(c);
    }
    return isCredentialName(std.fs.path.basename(std.mem.trimEnd(u8, path, &path_sep)));
}

/// The tools that change a file rather than report one. The credential refusal
/// names them because the advice a reading tool gets is wrong for them: there
/// is no reading of a key file that should be going on, so the answer is the
/// operator rather than another tool.
fn isWriting(tool: []const u8) bool {
    return std.mem.eql(u8, tool, "write") or std.mem.eql(u8, tool, "edit");
}

/// What a tool returns instead of a credential. It names the file, so a model
/// that asked for it knows which one was refused, and it says what to do
/// instead, because a bare error reads as a broken tool and gets retried.
fn credentialRefusal(arena: std.mem.Allocator, tool: []const u8, path: []const u8) error{OutOfMemory}![]u8 {
    // The advice has to be the one that is true for the tool that was refused.
    // The `bash` branch sends the model to the operator because `bash` runs
    // the same name check over its own words: telling a model that `read` just
    // refused to run the command that fetches the bytes walks it into the same
    // refusal one line later. A tool that would have overwritten the file says
    // the same thing, because there is no reading of it anyone should be doing.
    const advice = if (std.mem.eql(u8, tool, "bash"))
        "`bash` does not read it either. Ask the operator for the value you need rather than printing a key."
    else if (isWriting(tool))
        "No tool rewrites a credentials file. Ask the operator to make that change rather than replacing a key with a guess."
    else
        "Run the command that needs the key through `bash`, and do not print it.";
    return std.fmt.allocPrint(
        arena,
        "refused: {s} is a credentials file. `{s}` does not return one, because the result " ++
            "is re-sent to the provider on every later turn. {s}",
        .{ path, tool, advice },
    );
}

fn toolRead(io: Io, arena: std.mem.Allocator, args: std.json.ObjectMap) ![]u8 {
    const path = chat.str(args.get("path")) orelse return std.fmt.allocPrint(arena, "error: missing path", .{});
    if (isCredentialPath(path)) return try credentialRefusal(arena, "read", path);
    if (!args.contains("offset") and !args.contains("limit"))
        return std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_read_bytes)) catch |err|
            return readFailed(arena, path, err);

    const offset: usize = @max(1, std.math.cast(usize, countArg(args.get("offset")) orelse 1) orelse std.math.maxInt(usize));
    const limit: usize = std.math.cast(usize, countArg(args.get("limit")) orelse std.math.maxInt(u64)) orelse std.math.maxInt(usize);
    return readLines(io, arena, path, offset, limit);
}

/// What a `read` says when the file is not there, is a directory, or cannot be
/// opened: the same words whichever way the bytes were going to be fetched.
fn readFailed(arena: std.mem.Allocator, path: []const u8, err: anyerror) []u8 {
    return std.fmt.allocPrint(arena, "error: cannot read {s}: {s}", .{ path, @errorName(err) }) catch
        @constCast("error: cannot read the file");
}

/// Bytes one read of a streamed file brings in.
const read_chunk = 8 * 1024;

/// The lines of a file in `[offset, offset + limit)`, each with the newline the
/// model reads them back with.
///
/// The file is streamed rather than read whole. A `read` of fifty lines out of
/// a four-megabyte artifact used to pull all four megabytes into the turn's
/// memory, copy fifty lines out of them, and keep reading to the end of the
/// file to find out there was nothing more; this reads up to the last line
/// asked for and stops. A file whose last line has no newline is still a line,
/// and gets the newline the split-based reader gave it.
fn readLines(io: Io, arena: std.mem.Allocator, path: []const u8, offset: usize, limit: usize) ![]u8 {
    var file = std.Io.Dir.cwd().openFile(io, path, .{ .allow_directory = true }) catch |err|
        return readFailed(arena, path, err);
    defer file.close(io);

    var read_buffer: [read_chunk]u8 = undefined;
    var file_reader = file.reader(io, &read_buffer);
    const r = &file_reader.interface;

    var buf: std.ArrayList(u8) = .empty;
    // The bytes of a line the last read cut in half, moved to the front each
    // time a new one lands behind them.
    var rest: std.ArrayList(u8) = .empty;
    var line: usize = 0;
    var taken: usize = 0;
    var start: usize = 0;
    // How much of `rest` has already been searched for a newline. Without this
    // the search restarts at the front of the buffer on every read, so a file
    // whose line is longer than a read is searched once per read: four megabytes
    // with no newline in it costs about a gigabyte of searching. A minified
    // bundle, a JSON blob, a lockfile or a base64 row is an ordinary thing for
    // the model to ask for, and a ranged read cannot stop at the first line it
    // wants because it has to find where that line ends.
    var scanned: usize = 0;
    var consumed: usize = 0;
    while (consumed < max_read_bytes) {
        const want = @min(read_chunk, max_read_bytes - consumed);
        // Straight into the buffer the line is assembled from, rather than into
        // a stack chunk that is copied in after it: a read of a four-megabyte
        // artifact moved every one of those bytes twice to hold them, once for
        // the read and once for the append.
        try rest.ensureUnusedCapacity(arena, want);
        const n = r.readSliceShort(rest.unusedCapacitySlice()[0..want]) catch |err| switch (err) {
            // The generic `ReadFailed` names no cause; the reader kept the one
            // that does, and a directory the model named is worth saying.
            error.ReadFailed => return readFailed(arena, path, file_reader.err orelse error.ReadFailed),
            else => |e| return e,
        };
        if (n == 0) break;
        consumed += n;
        rest.items.len += n;
        // The scan resumes where the last one stopped, not where the buffer
        // starts: the bytes between `start` and there were searched on an
        // earlier read and held no newline, so the line in hand still runs from
        // `start`.
        while (net.nextLineEnd(rest.items, &scanned)) |pos| {
            line += 1;
            if (line >= offset) {
                if (taken >= limit) return buf.items;
                try buf.appendSlice(arena, rest.items[start..pos]);
                try buf.append(arena, '\n');
                taken += 1;
            }
            // Only a found newline ends a line, so this is the only thing that
            // moves the start. Anything else would drop bytes the line is made
            // of, and truncate it.
            start = pos + 1;
        }
        // Nothing was consumed on a read that completed no line, and the
        // move below is a memmove of the whole pending line onto itself when
        // `start` is zero, which on a file of long lines is the other half of
        // that gigabyte.
        if (start > 0) {
            const left = rest.items.len - start;
            std.mem.copyForwards(u8, rest.items[0..left], rest.items[start..]);
            rest.shrinkRetainingCapacity(left);
            scanned -= start;
            start = 0;
        }
    }
    // Out of cap rather than out of file, which is what a whole-file read of
    // the same file reports, so one file over the cap reads the same whichever
    // way the model asked for it. `readFileAlloc` refuses at the cap as well
    // as past it, so a file of exactly `max_read_bytes` is refused on both
    // paths and the boundary is the same one.
    if (consumed == max_read_bytes) return readFailed(arena, path, error.StreamTooLong);
    if (rest.items.len > 0 and line + 1 >= offset and taken < limit) {
        try buf.appendSlice(arena, rest.items);
        try buf.append(arena, '\n');
    }
    return buf.items;
}

fn toolWrite(io: Io, arena: std.mem.Allocator, args: std.json.ObjectMap) ![]u8 {
    const path = chat.str(args.get("path")) orelse return std.fmt.allocPrint(arena, "error: missing path", .{});
    // The same refusal `read` makes. A run that cannot read a key file has no
    // business rewriting one either: `write` replaces the file whole, so a
    // model that gets the path from a file in the tree and the content from a
    // guess replaces the operator's working key with a placeholder, and the
    // next run of the agent cannot authenticate at all.
    if (isCredentialPath(path)) return try credentialRefusal(arena, "write", path);
    // A call that names a path and no content is a call the model got cut
    // short on, not one asking for an empty file: a `write` is the one tool
    // result a run cannot undo, and emptying a source file is worse than
    // reporting the missing argument. A model that means an empty file says
    // so, as `"content": ""`.
    const content = chat.str(args.get("content")) orelse
        return std.fmt.allocPrint(arena, "error: missing content", .{});
    writeFileAtomic(io, std.Io.Dir.cwd(), path, content) catch |err|
        return std.fmt.allocPrint(arena, "error: cannot write {s}: {s}", .{ path, @errorName(err) });
    return std.fmt.allocPrint(arena, "wrote {d} bytes to {s}", .{ content.len, path });
}

/// The permission bits of a mode: the setuid, setgid and sticky bits with the
/// nine `rwx` ones. A rename carries the temporary file's mode to the
/// destination, so this is what decides what a rewritten file comes back as.
pub const permission_bits: std.posix.mode_t = 0o7777;

/// Writes `bytes` over `path` so a write that does not finish cannot leave half
/// a file where a whole one was.
///
/// `Dir.writeFile` opens the destination truncating and then writes into it, so
/// a full disk, a signal or a limit part way through leaves the model reading
/// a source file that is now shorter than it was, with the bytes that were
/// there gone and no copy of them anywhere. The bytes go to a temporary file
/// beside the destination and a rename puts them in place, so a reader sees
/// either the old file whole or the new one whole. `microagent update` already
/// replaces the binary this way; the two tools that edit a user's files were
/// the one place that did not.
///
/// A rename replaces the name it is given, so a symlink would become a regular
/// file and the tree would gain one, so the link is followed first, through the
/// same resolver `update` uses. The mode the destination already has is carried
/// over, because the rename brings the temporary file's mode with it and a
/// 0o600 file that comes back 0o644 is a change the run was never asked to make.
pub fn writeFileAtomic(io: Io, dir: std.Io.Dir, path: []const u8, bytes: []const u8) !void {
    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    var join_buf: [2 * std.fs.max_path_bytes]u8 = undefined;
    const target = try net.resolveSymlinkTarget(io, dir, path, &link_buf, &join_buf);
    // Only the permission bits: the stat also carries the file type, and a
    // create mode is a permission set.
    const permissions: Io.File.Permissions = if (dir.statFile(io, target, .{})) |stat|
        .fromMode(stat.permissions.toMode() & permission_bits)
    else |err| switch (err) {
        error.FileNotFound => .default_file,
        else => |e| return e,
    };
    var af = try dir.createFileAtomic(io, target, .{
        .replace = true,
        .make_path = true,
        .permissions = permissions,
    });
    defer af.deinit(io);
    try af.file.writeStreamingAll(io, bytes);
    try af.replace(io);
}

fn toolEdit(io: Io, arena: std.mem.Allocator, args: std.json.ObjectMap) ![]u8 {
    const path = chat.str(args.get("path")) orelse return std.fmt.allocPrint(arena, "error: missing path", .{});
    // The same refusal `read` makes. An edit reads the whole file to find its
    // match, and the operator's key is the one file in a tree where a match the
    // model guessed at and a rewrite of the value beside it is damage nobody
    // asked for.
    if (isCredentialPath(path)) return try credentialRefusal(arena, "edit", path);
    const old = chat.str(args.get("old_string")) orelse return std.fmt.allocPrint(arena, "error: missing old_string", .{});
    const new = chat.str(args.get("new_string")) orelse return std.fmt.allocPrint(arena, "error: missing new_string", .{});
    const all = if (args.get("replace_all")) |v| v == .bool and v.bool else false;

    const raw = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_edit_bytes)) catch |err|
        return std.fmt.allocPrint(arena, "error: cannot read {s}: {s}", .{ path, @errorName(err) });
    if (old.len == 0) return std.fmt.allocPrint(arena, "error: old_string is empty", .{});
    // An edit is a tool call the model can issue twice: a turn that was cut
    // before the result reached it, a re-read to check the change landed, a
    // retry after a transport fault. Every other shape is already safe, because
    // the first run removes the text the second one looks for and the second is
    // refused. The two shapes below are not, and both are settled before
    // anything is written.
    //
    // A replacement that is the text it replaces changes nothing, so it reports
    // that rather than rewriting the file with its own contents.
    if (std.mem.eql(u8, old, new)) {
        return std.fmt.allocPrint(arena, "no change: new_string is the same text as old_string in {s}", .{path});
    }
    // A replacement that still contains what it replaces cannot be run twice:
    // the second execution matches the same text inside the first execution's
    // own output and nests it again, so `}` -> `},` or `foo` -> `foobar` grows
    // or re-indents the file a little further with every duplicate. Nothing
    // here can tell an already-applied edit from a first one, because the two
    // leave the same bytes, so the shape is refused rather than applied twice
    // under a second run. The model gets the reason and the way out, and reads
    // the file again before asking for the edit with more context in
    // `old_string`, which is also what makes it unambiguous.
    if (std.mem.indexOf(u8, new, old) != null) {
        return std.fmt.allocPrint(arena, "error: new_string contains old_string, so a second run of this edit would match inside the first one's output and apply again; include more context in old_string", .{});
    }

    const count = std.mem.count(u8, raw, old);
    if (count == 0) return std.fmt.allocPrint(arena, "error: old_string not found in {s}", .{path});
    if (count > 1 and !all) return std.fmt.allocPrint(arena, "error: old_string occurs {d} times in {s}; add context or set replace_all", .{ count, path });

    // The checks above leave either every occurrence replaced or, without
    // `all`, exactly one to replace, and one match is the loop below run once.
    // `count` is in hand, so the rewritten file's exact size is too, and the
    // buffer is allocated once rather than doubling up to it: `raw` is a file
    // of up to `max_edit_bytes`, and the arena keeps every intermediate block
    // a doubling leaves behind.
    const replacements = if (all) count else 1;
    var buf: std.ArrayList(u8) = .empty;
    try buf.ensureTotalCapacity(arena, raw.len - replacements * old.len + replacements * new.len);
    var rest = raw;
    while (std.mem.indexOf(u8, rest, old)) |at| {
        try buf.appendSlice(arena, rest[0..at]);
        try buf.appendSlice(arena, new);
        rest = rest[at + old.len ..];
    }
    try buf.appendSlice(arena, rest);
    writeFileAtomic(io, std.Io.Dir.cwd(), path, buf.items) catch |err|
        return std.fmt.allocPrint(arena, "error: cannot write {s}: {s}", .{ path, @errorName(err) });
    return std.fmt.allocPrint(arena, "replaced {d} occurrence(s) in {s}", .{ count, path });
}

fn toolSearch(io: Io, arena: std.mem.Allocator, args: std.json.ObjectMap, ceiling_ms: ?u64, environ_map: ?*const std.process.Environ.Map) ![]u8 {
    const pattern = chat.str(args.get("pattern")) orelse return std.fmt.allocPrint(arena, "error: missing pattern", .{});
    const path = chat.str(args.get("path")) orelse ".";
    // The globs below are traversal rules: ripgrep applies them while it walks,
    // and a file named as the search path is read whatever they say, so
    // `{"path": ".env"}` came back with the key's line in it. The name is
    // checked here instead, which is what the globs and this test between them
    // make true.
    if (isCredentialPath(path)) return try credentialRefusal(arena, "search", path);
    const glob = chat.str(args.get("glob"));
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ "rg", "--line-number", "--no-heading", "--color", "never", "--max-count", "200", "--glob-case-insensitive" });
    if (glob) |g| {
        try argv.appendSlice(arena, &.{ "--glob", g });
    }
    // After the model's own glob, because a later `--glob` is the one ripgrep
    // applies where two match: the exclusions are not a default a `--glob` on
    // the command line can turn off.
    // Reserved once rather than grown through: the loop below pushes two
    // entries per name, and letting the list reallocate under it copies
    // everything appended so far on each step.
    try argv.ensureUnusedCapacity(arena, credential_globs.len * 2);
    for (credential_globs) |g| {
        argv.appendAssumeCapacity("--glob");
        argv.appendAssumeCapacity(g);
    }
    try argv.appendSlice(arena, &.{ "--", pattern, path });
    return runSearchTool(io, arena, argv.items, "ripgrep", ceiling_ms, environ_map);
}

/// Structural search/rewrite through ast-grep. `rewrite` set means the change
/// is applied to every match (`--update-all`), so the next turn reads the
/// result back rather than trusting the tool's summary.
fn toolAst(io: Io, arena: std.mem.Allocator, args: std.json.ObjectMap, ceiling_ms: ?u64, environ_map: ?*const std.process.Environ.Map) ![]u8 {
    const pattern = chat.str(args.get("pattern")) orelse return std.fmt.allocPrint(arena, "error: missing pattern", .{});
    const lang = chat.str(args.get("lang")) orelse return std.fmt.allocPrint(arena, "error: missing lang", .{});
    const path = chat.str(args.get("path")) orelse ".";
    // The same hole `search` has: `--globs` filters the walk, and a file named
    // as the path is rewritten whatever they say, which is a key's line in a
    // match and a keystore in the diff of the turn after.
    if (isCredentialPath(path)) return try credentialRefusal(arena, "ast", path);
    const rewrite = chat.str(args.get("rewrite"));

    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ "ast-grep", "run", "--pattern", pattern, "--lang", lang });
    try argv.ensureUnusedCapacity(arena, credential_globs.len * 2);
    for (credential_globs) |g| {
        argv.appendAssumeCapacity("--globs");
        argv.appendAssumeCapacity(g);
    }
    if (rewrite) |r| try argv.appendSlice(arena, &.{ "--rewrite", r, "--update-all" });
    try argv.appendSlice(arena, &.{ "--", path });

    return runSearchTool(io, arena, argv.items, "ast-grep", ceiling_ms, environ_map);
}

/// Bytes read from a child pipe per operation. Both pipes are drained in one
/// batch, so neither can fill up and wedge the child while the other is read.
const capture_chunk = 8 * 1024;

/// What a capped child produced: the first `limit` bytes of each stream, and the
/// status it exited with.
const Captured = struct {
    stdout: []u8,
    stderr: []u8,
    term: std.process.Child.Term,
    /// Per stream, a byte arrived after the cap was full. A capture that ends
    /// exactly on the cap dropped nothing, and a reader told otherwise reads a
    /// complete log as a cut-off one.
    dropped: [2]bool,
};

/// Runs `argv` and keeps the first `limit` bytes of each stream.
///
/// `std.process.run` answers `error.StreamTooLong` and throws away everything it
/// had read, so a chatty build, a ripgrep over a large tree or a `git show` of a
/// big file reached the model as a bare error with no output at all. Here the
/// bytes past the cap are drained and dropped instead: the child still runs to
/// its own end, so the exit status and the timeout keep meaning what they did.
///
/// The child leads its own process group and the whole group is signalled on the
/// way out: a model-supplied `bash`
/// command that backgrounds work and exits leaves that work holding a port, a
/// build cache or a database lock for every later turn of the run and for
/// whatever starts next, and a timeout that fires while the shell is still there
/// leaves the compiler or test server it launched running without it.
pub fn runCapped(
    io: Io,
    arena: std.mem.Allocator,
    argv: []const []const u8,
    limit: usize,
    timeout: Io.Timeout,
    environ_map: ?*const std.process.Environ.Map,
) !Captured {
    var spawned = try ToolChild.spawn(io, argv, environ_map);
    // The group is published while the call runs, so an interrupt reaches it,
    // and cleared on the way out, so a later signal does not hit a dead group.
    watchToolGroup(spawned.pgid);
    defer {
        watchToolGroup(0);
        spawned.reap(io);
    }
    const child = &spawned.child;

    const files = [2]Io.File{ child.stdout.?, child.stderr.? };
    var chunks: [2][capture_chunk]u8 = undefined;
    var vecs: [2][1][]u8 = .{ .{&chunks[0]}, .{&chunks[1]} };
    var out: [2]std.ArrayList(u8) = .{ .empty, .empty };

    var storage: [2]Io.Operation.Storage = undefined;
    var batch: Io.Batch = .init(&storage);
    defer batch.cancel(io);
    for (0..2) |i| batch.addAt(@intCast(i), .{ .file_read_streaming = .{
        .file = files[i],
        .data = &vecs[i],
    } });

    // One deadline for the whole drain, taken once rather than handed to every
    // wait: a per-wait duration is re-armed by every read that arrives, so a
    // command that never goes quiet for the length of the timeout is never
    // timed out at all. The reap on the way out kills the group either way.
    const deadline = timeout.toDeadline(io);
    var draining: usize = files.len;
    var read_err: ?anyerror = null;
    var dropped: [2]bool = .{ false, false };
    while (draining > 0) {
        try batch.awaitConcurrent(io, deadline);
        while (batch.next()) |completion| {
            const i = completion.index;
            const n = completion.result.file_read_streaming catch |err| {
                // EndOfStream and Canceled are how a pipe finishes, not a fault.
                if (read_err == null and err != error.EndOfStream and err != error.Canceled)
                    read_err = err;
                draining -= 1;
                continue;
            };
            if (n > 0) {
                const taken = @min(n, limit -| out[i].items.len);
                if (taken < n) dropped[i] = true;
                if (taken > 0) try out[i].appendSlice(arena, chunks[i][0..taken]);
            }
            // A read may legitimately return zero bytes without ending the
            // stream, so re-arm either way.
            vecs[i] = .{&chunks[i]};
            batch.addAt(i, .{ .file_read_streaming = .{
                .file = files[i],
                .data = &vecs[i],
            } });
        }
    }

    // Both pipes are at end of stream but the child may still be running, and
    // the wait below takes no timeout of its own.
    if (deadline.toDurationFromNow(io)) |left| if (left.raw.nanoseconds <= 0) return error.Timeout;
    const term = try child.wait(io);
    if (read_err) |err| return err;
    return .{ .stdout = out[0].items, .stderr = out[1].items, .term = term, .dropped = dropped };
}

/// True when a stream filled the cap with bytes still arriving, so the captured
/// bytes are the beginning of the output and not all of it.
pub fn atCaptureLimit(captured: Captured) bool {
    return captured.dropped[0] or captured.dropped[1];
}

/// One tool result as the model reads it: capped, cut on a code point
/// boundary, and marked when bytes were dropped. Without the marker a
/// truncated file or a truncated test log is indistinguishable from a complete
/// one, and the agent reasons about output it never saw.
pub fn toolResult(arena: std.mem.Allocator, output: []const u8) ![]const u8 {
    const kept = chat.clamp(output, max_tool_output);
    if (kept.len == output.len) return kept;
    return std.fmt.allocPrint(arena, "{s}\n... [tool output truncated at {d} of {d} bytes]", .{
        kept, kept.len, output.len,
    });
}

pub fn dispatch(arena: std.mem.Allocator, name: []const u8, args: []const u8) ![]u8 {
    var call: chat.ToolCall = .{
        .id = try arena.dupe(u8, ""),
        .name = try arena.dupe(u8, name),
    };
    try call.args.appendSlice(arena, args);
    return runTool(std.testing.io, arena, call, null, null);
}

/// The line range a `read` with `offset` and `limit` returns: every line in
/// range, each followed by a newline.
///
/// The newline that ends the last line of a file is a terminator, not the
/// start of another line, so it does not add one. The split-based reader this
/// replaced did count it, so `read` of a whole file and `read` of the same file
/// line by line disagreed about whether the file ended in a blank line, and an
/// empty file read as a single blank one.
fn expectedLines(arena: std.mem.Allocator, raw: []const u8, offset: usize, limit: usize) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    if (raw.len == 0) return buf.toOwnedSlice(arena);
    const body = if (raw[raw.len - 1] == '\n') raw[0 .. raw.len - 1] else raw;
    var lines = std.mem.splitScalar(u8, body, '\n');
    var n: usize = 1;
    var taken: usize = 0;
    while (lines.next()) |line| : (n += 1) {
        if (n < offset) continue;
        if (taken >= limit) break;
        try buf.appendSlice(arena, line);
        try buf.append(arena, '\n');
        taken += 1;
    }
    return buf.toOwnedSlice(arena);
}

// A ranged read streams the file rather than pulling it whole, so the lines it
// hands back are assembled across read boundaries instead of split out of one
// buffer. What it must not change is the bytes: the same offset and limit give
// the model the same text, whether the file ends in a newline or not and
// whether the lines straddle a read.
test "a ranged read returns the same lines the whole-file read used to return" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const arena = state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];

    // Short, empty, no trailing newline, and a file whose lines cross the
    // 8 KB read boundary in both directions.
    var long: std.ArrayList(u8) = .empty;
    try long.appendSlice(arena, "head\n");
    var i: usize = 0;
    while (i < 900) : (i += 1)
        try long.appendSlice(arena, try std.fmt.allocPrint(arena, "{d:0>5}\n", .{i}));
    try long.appendSlice(arena, "tail without newline");

    const files = [_]struct { name: []const u8, text: []const u8 }{
        .{ .name = "short.txt", .text = "one\ntwo\nthree\n" },
        .{ .name = "no_newline.txt", .text = "one\ntwo\nthree" },
        .{ .name = "empty.txt", .text = "" },
        .{ .name = "long.txt", .text = long.items },
    };
    const ranges = [_]struct { offset: usize, limit: usize }{
        .{ .offset = 1, .limit = 1 },
        .{ .offset = 2, .limit = 1 },
        .{ .offset = 2, .limit = 2 },
        .{ .offset = 3, .limit = 100 },
        .{ .offset = 1, .limit = 100 },
        .{ .offset = 900, .limit = 2 },
        .{ .offset = 901, .limit = 2 },
        .{ .offset = 902, .limit = 2 },
        .{ .offset = 903, .limit = 2 },
        .{ .offset = 10, .limit = 0 },
        .{ .offset = 1, .limit = 0 },
        .{ .offset = 50_000, .limit = 5 },
    };

    for (files) |f| {
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = f.name, .data = f.text });
        const path = try std.fs.path.join(arena, &.{ dir_path, f.name });
        for (ranges) |r| {
            const got = try readLines(std.testing.io, arena, path, r.offset, r.limit);
            try std.testing.expectEqualStrings(
                try expectedLines(arena, f.text, r.offset, r.limit),
                got,
            );
        }
        // No range asked for: the file comes back exactly as it is on disk,
        // trailing newline and all.
        var args: std.json.ObjectMap = .empty;
        try args.put(arena, "path", .{ .string = path });
        try std.testing.expectEqualStrings(f.text, try toolRead(std.testing.io, arena, args));
    }
}

test "a read of a file that is not there says the same whether or not it is a range" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const arena = state.allocator();

    var args: std.json.ObjectMap = .empty;
    try args.put(arena, "path", .{ .string = "nope.txt" });
    try std.testing.expectEqualStrings("error: cannot read nope.txt: FileNotFound", try toolRead(std.testing.io, arena, args));
    try args.put(arena, "offset", .{ .integer = 5 });
    try std.testing.expectEqualStrings("error: cannot read nope.txt: FileNotFound", try toolRead(std.testing.io, arena, args));
    try args.put(arena, "limit", .{ .integer = 5 });
    try std.testing.expectEqualStrings("error: cannot read nope.txt: FileNotFound", try toolRead(std.testing.io, arena, args));
}

// The cap is what keeps a file over it out of the turn's memory, and it is a
// property of the file rather than of the range asked for: streaming the bytes
// a range needs must not be a way round it.
// The scan has to resume where it left off, and the copy has to move only what
// a newline ended. Both go wrong on the same input: a line longer than the
// 8 KB read, so nothing is consumed until the far end of the file. That is a
// minified bundle or a JSON blob, not a corner case, and a ranged read cannot
// stop early because it has to find where the line ends.
test "a line longer than the read comes back whole, and is searched once" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const arena = state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    const path = try std.fs.path.join(arena, &.{ dir_path, "long-line.txt" });

    const width = read_chunk * 4 + 137;
    var text: std.ArrayList(u8) = .empty;
    try text.appendSlice(arena, "before\n");
    try text.appendNTimes(arena, 'z', width);
    try text.appendSlice(arena, "\nafter\n");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "long-line.txt", .data = text.items });

    var arena2 = std.heap.ArenaAllocator.init(arena);
    defer arena2.deinit();
    const got = try readLines(std.testing.io, arena2.allocator(), path, 2, 1);

    var want: std.ArrayList(u8) = .empty;
    try want.appendNTimes(arena, 'z', width);
    try want.append(arena, '\n');
    try std.testing.expectEqualStrings(want.items, got);
}

test "a ranged read of a file over the cap is refused like a whole-file read" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const arena = state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fs.path.join(arena, &.{ dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)], "big.txt" });

    // A file is refused once it reaches the cap, whole-file read or ranged one:
    // the cap is a property of the file, not of the lines the model asked for.
    // Comfortably over it, and comfortably under.
    var over: std.ArrayList(u8) = .empty;
    try over.appendNTimes(arena, 'x', max_read_bytes + 1);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "big.txt", .data = over.items });
    try std.testing.expectEqualStrings(
        try std.fmt.allocPrint(arena, "error: cannot read {s}: StreamTooLong", .{path}),
        try readLines(std.testing.io, arena, path, 1, 1),
    );

    var under: std.ArrayList(u8) = .empty;
    try under.appendNTimes(arena, 'y', max_read_bytes - 2);
    try under.append(arena, '\n');
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "under.txt", .data = under.items });
    const under_path = try std.fs.path.join(arena, &.{ dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)], "under.txt" });
    try std.testing.expectEqual(max_read_bytes - 1, (try readLines(std.testing.io, arena, under_path, 1, 5)).len);

    // The boundary itself, where the two paths have to agree: the cap is
    // "reached or over", so a file of exactly `max_read_bytes` bytes is
    // refused by the whole-file read and by the ranged one alike. A cap of
    // `max_read_bytes + 1` on one path and `max_read_bytes` on the other would
    // refuse the same file under two names, and the model's next move would be
    // a smaller `limit` that does not help.
    var exact: std.ArrayList(u8) = .empty;
    try exact.appendNTimes(arena, 'x', max_read_bytes);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "exact.txt", .data = exact.items });
    const exact_path = try std.fs.path.join(arena, &.{ dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)], "exact.txt" });
    try std.testing.expectEqualStrings(
        try std.fmt.allocPrint(arena, "error: cannot read {s}: StreamTooLong", .{exact_path}),
        try readLines(std.testing.io, arena, exact_path, 1, 5),
    );

    var exact_args: std.json.ObjectMap = .empty;
    try exact_args.put(arena, "path", .{ .string = exact_path });
    try std.testing.expectEqualStrings(
        try std.fmt.allocPrint(arena, "error: cannot read {s}: StreamTooLong", .{exact_path}),
        try toolRead(std.testing.io, arena, exact_args),
    );
}

// The scan cursor is what keeps a ranged read of a minified bundle or a base64
// blob from re-searching the whole pending line on every read, but a cursor
// that is lowered wrongly drops or repeats a line. The bytes are the property
// worth asserting: lines that straddle a read boundary, several reads long, at
// an offset, come back exactly as `expectedLines` spells them.
test "lines longer than a read come back whole, whatever they straddle" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fs.path.join(arena, &.{ dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)], "long.txt" });

    // One line per read-chunk boundary, one that straddles three of them, and
    // a last line with no newline: the three shapes a cursor can lose.
    const short = "a" ** 16;
    const straddling = "b" ** (read_chunk * 3 + 7);
    const unterminated = "c" ** (read_chunk + 1);
    var raw: std.ArrayList(u8) = .empty;
    try raw.appendSlice(arena, short);
    try raw.append(arena, '\n');
    try raw.appendSlice(arena, straddling);
    try raw.append(arena, '\n');
    try raw.appendSlice(arena, unterminated);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "long.txt", .data = raw.items });

    const want = try expectedLines(arena, raw.items, 1, std.math.maxInt(usize));
    // Past the first line, so the cursor is exercised after a line was already
    // consumed, and the whole file below, so it is exercised past the
    // straddling line and at the unterminated tail.
    const offset: usize = 2;
    const got = try readLines(std.testing.io, arena, path, offset, 2);
    const want_offset = try expectedLines(arena, raw.items, offset, 2);
    try std.testing.expectEqualStrings(want_offset, got);
    // Lines two and three are the ones the range covers: the whole of the
    // straddling line and the unterminated tail, byte for byte, not a read's
    // worth of either.
    try std.testing.expectEqualStrings(
        try std.fmt.allocPrint(arena, "{s}\n{s}\n", .{ straddling, unterminated }),
        got,
    );
    try std.testing.expectEqual(want.len, (try readLines(std.testing.io, arena, path, 1, std.math.maxInt(usize))).len);
}

test "the tool gutter stays one line whatever the model sent" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var buf: [gutter_line_max]u8 = undefined;

    // The line the gutter writes, marker and newline included, with the
    // control characters a command from the model can carry shown as their
    // escapes. A gutter that dropped the marker, or ended without the newline
    // the reader splits on, still read as one line here.
    var args: std.json.ObjectMap = .empty;
    try args.put(arena, "command", .{ .string = "rg -n 'foo'\nnext line\u{1b}[31mred\xff" });
    try std.testing.expectEqualStrings(
        "\u{23fa} bash rg -n 'foo'\\x0anext line\\x1b[31mred\u{fffd}\n",
        try toolCallLine(arena, &buf, "bash", args),
    );

    // The argument named depends on the tool, and an argument that is not text
    // is not printed as one.
    const cases = [_]struct { name: []const u8, key: []const u8, detail: []const u8 }{
        .{ .name = "ast", .key = "pattern", .detail = "fn main" },
        .{ .name = "search", .key = "pattern", .detail = "TODO" },
        .{ .name = "read", .key = "path", .detail = "src/main.zig" },
        .{ .name = "bash", .key = "command", .detail = "ls -la" },
    };
    for (cases) |c| {
        var one: std.json.ObjectMap = .empty;
        try one.put(arena, c.key, .{ .string = c.detail });
        try std.testing.expectEqualStrings(
            try std.fmt.allocPrint(arena, "\u{23fa} {s} {s}\n", .{ c.name, c.detail }),
            try toolCallLine(arena, &buf, c.name, one),
        );

        // A number where the name is would have been read as the detail, and
        // the line says the tool with nothing after it instead.
        var numbered: std.json.ObjectMap = .empty;
        try numbered.put(arena, c.key, .{ .integer = 7 });
        try std.testing.expectEqualStrings(
            try std.fmt.allocPrint(arena, "\u{23fa} {s} \n", .{c.name}),
            try toolCallLine(arena, &buf, c.name, numbered),
        );
    }

    // A name and a detail longer than their budgets are cut, on a code point
    // boundary, and the line still ends exactly once.
    var long_args: std.json.ObjectMap = .empty;
    try long_args.put(arena, "command", .{ .string = "日" ** 300 });
    const long_line = try toolCallLine(arena, &buf, "search" ** 10, long_args);
    try std.testing.expect(long_line.len <= gutter_line_max);
    try std.testing.expect(std.unicode.utf8ValidateSlice(long_line));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, long_line, "\n"));
}

// The tool name and the argument object are the model's, and the model decides
// what to send from files in the tree, so both are untrusted bytes crossing a
// boundary. Three things happen to them before any tool runs: the arguments
// are parsed as JSON, the counts the model wrote become limits and deadlines,
// and one line is written to the gutter for a reader that splits on newlines.
// `std.testing.fuzz` runs this corpus on every `zig build test`, and through
// the fuzzer's mutations when the test binary is built in fuzz mode.
//
// The corpus is what the harness has to be able to read: an empty call, each
// tool's own argument names, the keys that differ per tool, the counts as
// integers, as floats, as strings, negative, past the ceiling and not numbers
// at all, a value that is text where a count belongs and a count where text
// belongs, deeply nested and empty objects, an array or a scalar instead of an
// object, a truncated object, escapes and lone bytes inside a string, and the
// argument names themselves, which is what decides whose key the gutter reads.
const call_corpus = [_][]const u8{
    "",
    "\n",
    " ",
    "{}",
    "[]",
    "null",
    "7",
    "\"text\"",
    "{",
    "{\"command\":\"ls -la\"}",
    "{\"command\":\"rg -n 'x'\\nsecond line\\u001b[31m\\u0000\\xff\"}",
    "{\"command\":\"\",\"timeout_ms\":0}",
    "{\"command\":\"build\",\"timeout_ms\":1}",
    "{\"command\":\"build\",\"timeout_ms\":\"600000\"}",
    "{\"command\":\"build\",\"timeout_ms\":-1}",
    "{\"command\":\"build\",\"timeout_ms\":1.5e300}",
    "{\"command\":\"build\",\"timeout_ms\":99999999999999999999999}",
    "{\"command\":\"build\",\"timeout_ms\":null}",
    "{\"command\":\"build\",\"timeout_ms\":true}",
    "{\"command\":\"build\",\"timeout_ms\":[1]}",
    "{\"command\":\"build\",\"timeout_ms\":{\"ms\":5}}",
    "{\"path\":\"src/main.zig\",\"offset\":0,\"limit\":1}",
    "{\"path\":\"src/main.zig\",\"offset\":-1,\"limit\":\"12\"}",
    "{\"pattern\":\"fn main\",\"lang\":\"zig\"}",
    "{\"pattern\":\"日本\" ** 40}",
    "{\"subcommand\":\"log\",\"limit\":400}",
    "{\"subcommand\":\"log\",\"limit\":0}",
    "{\"subcommand\":\"log\",\"limit\":-5}",
    "{\"subcommand\":\"log\",\"limit\":\"all\"}",
    "{\"subcommand\":\"log\",\"limit\":1e30}",
    "{\"subcommand\":\"log\",\"limit\":null}",
    "{\"limit\":18446744073709551615}",
    "{\"path\":\"a\",\"content\":\"\\u0000\\u001b\\u007f\\ud83d\\ude80\"}",
    "{\"content\":7}",
    "{\"command\":7}",
    "{\"COMMAND\":\"ls\"}",
    "{\"command\":\"ls\",\"command\":\"pwd\"}",
    "{\"nested\":{\"command\":\"ls\",\"path\":\"a\",\"pattern\":\"p\",\"limit\":3}}",
    "{\"a\":{\"b\":{\"c\":{\"command\":\"ls\"}}}}",
    "{\"unknown\":[1,2,3],\"command\":\"ls\"}",
    "{\"command\":\"ls\",\"extra\":\"x\"}",
    "{\"command\":\"ls\"",
    "{\"command\":\"\\xc3\"}",
    "{\"command\":\"\\xff\\xfe\"}",
    "{\"command\":\"\\u0000\"}",
    "{\"command\":\"caf\\u00e9 \\u65e5\\u8a00 \\ud83d\\ude80\"}",
    "{\"command\":\"line1\\nline2\\r\\nline3\"}",
    "{\"command\":\"\\u2028\\u2029\"}",
    "{\"command\":\"a\" ** 500}",
    "{\"command\":\"日\" ** 500}",
};

test "a fuzzed tool call leaves one gutter line and limits inside their ceilings" {
    try std.testing.fuzz({}, fuzzToolCall, .{ .corpus = &call_corpus });
}

fn fuzzToolCall(_: void, smith: *std.testing.Smith) !void {
    const gpa = std.testing.allocator;
    var scratch: [8 * 1024]u8 = undefined;
    const text = if (smith.in) |seed| seed else scratch[0..smith.slice(&scratch)];

    // The name is the first line and the arguments are the rest, so the
    // fuzzer's bytes reach both halves rather than only the JSON.
    const split = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
    const name = text[0..split];
    const raw = if (split == text.len) "" else text[split + 1 ..];

    var state = std.heap.ArenaAllocator.init(gpa);
    defer state.deinit();
    const arena = state.allocator();

    // The same refusal `runTool` makes: a call whose arguments are not an
    // object reaches no tool and names none, whatever the bytes were.
    const parsed = std.json.parseFromSlice(std.json.Value, arena, raw, .{}) catch return;
    const args = switch (parsed.value) {
        .object => |o| o,
        else => return,
    };

    // The gutter line is a fixed-size buffer, and its whole purpose is to be
    // one line a reader splits on: a line over the buffer, or one carrying a
    // second newline, is a call the operator sees twice or not at all.
    var buf: [gutter_line_max]u8 = undefined;
    const line = toolCallLine(arena, &buf, name, args) catch return error.TestUnexpectedResult;
    try std.testing.expect(line.len <= gutter_line_max);
    try std.testing.expect(std.unicode.utf8ValidateSlice(line));
    try std.testing.expect(std.mem.startsWith(u8, line, "\u{23fa} "));
    try std.testing.expect(std.mem.endsWith(u8, line, "\n"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, line, "\n"));

    // Nothing but the line's own newline is a byte a terminal acts on: the
    // name and the detail came from the model, and the model read them out of
    // the tree, so an escape sequence here is a repository repainting the
    // operator's screen.
    for (line) |c| {
        if (c == '\n') continue;
        try std.testing.expect(c >= 0x20 and c != 0x7f);
    }

    // The counts the model wrote are the only numbers a tool acts on, and
    // every one of them is bounded before a subprocess is started. A line
    // count of zero reads as an empty file, and a deadline of zero is a
    // deadline already spent, so neither may come out of a call.
    try std.testing.expect(gitLineLimit(args) >= 1);
    try std.testing.expect(gitLogLines(gitLineLimit(args)) <= git_log_line_ceiling);
    const deadline = bashTimeoutMs(requestedTimeoutMs(args.get("timeout_ms")), null);
    try std.testing.expect(deadline >= 1);
    try std.testing.expect(deadline <= max_bash_timeout_ms);
    // A run's own budget lowers the deadline further rather than raising it.
    try std.testing.expectEqual(
        @min(deadline, @as(u64, 1)),
        bashTimeoutMs(requestedTimeoutMs(args.get("timeout_ms")), 1),
    );
}

test "a capped tool result says how much was dropped" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const whole = try toolResult(arena, "one line");
    try std.testing.expectEqualStrings("one line", whole);

    const big = "x" ** (max_tool_output + 500);
    const cut = try toolResult(arena, big);
    try std.testing.expect(std.mem.startsWith(u8, cut, "x" ** max_tool_output));
    try std.testing.expect(std.mem.endsWith(u8, cut, "truncated at 24576 of 25076 bytes]"));
}

test "a real tool result over the cap stays a string the body can carry" {
    // The whole path, from a command that prints well past the cap to the
    // bytes that would be written into the request body.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var args: std.json.ObjectMap = .empty;
    // Five bytes per line, so the cap does not land on a character boundary: a
    // plain cut here leaves half an e-acute in the string.
    try args.put(arena, "command", .{ .string = "i=0; while [ $i -lt 5000 ]; do printf '\\303\\251a\\303\\251'; i=$((i+1)); done" });
    const output = try toolBash(std.testing.io, arena, args, null, null);
    try std.testing.expect(output.len > max_tool_output);

    const result = try toolResult(arena, output);
    try std.testing.expect(std.unicode.utf8ValidateSlice(result));
    try std.testing.expect(std.mem.indexOf(u8, result, "tool output truncated at") != null);
    // It still parses as the JSON string the body is built from.
    var jb = chat.JsonBuf.init(arena);
    try chat.writeJsonString(jb.writer(), result);
    const parsed = std.json.parseFromSlice(std.json.Value, arena, jb.items(), .{}) catch return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(result, parsed.value.string);
}

test "a model cannot ask bash for a timeout past the ceiling" {
    // `timeout_ms` is model output. Taken as sent, a value past anything a run
    // survives leaves the child with no deadline at all, so the deadline the
    // tool is built on is the ceiling rather than the number asked for.
    try std.testing.expectEqual(max_bash_timeout_ms, bashTimeoutMs(@intCast(std.math.maxInt(u64)), null));
    try std.testing.expectEqual(max_bash_timeout_ms, bashTimeoutMs(max_bash_timeout_ms + 1, null));
    // Inside the ceiling it is what was asked for, and an absent one is the
    // tool's own default rather than the ceiling.
    try std.testing.expectEqual(@as(u64, 1000), bashTimeoutMs(1000, null));
    try std.testing.expectEqual(default_bash_timeout_ms, bashTimeoutMs(null, null));
    // What is left of the run's budget bounds the deadline, so a call that
    // starts near the end cannot outlast it. The ceiling never raises a
    // deadline the tool asked for for itself.
    try std.testing.expectEqual(@as(u64, 30_000), bashTimeoutMs(600_000, 30_000));
    try std.testing.expectEqual(@as(u64, 1000), bashTimeoutMs(1000, 30_000));
    try std.testing.expectEqual(@as(u64, 600_000), bashTimeoutMs(max_bash_timeout_ms, 900_000));
    // A search tool is held to its own 60 s the same way.
    try std.testing.expectEqual(@as(u64, 30_000), boundedMs(tool_timeout_ms, 30_000));
    try std.testing.expectEqual(tool_timeout_ms, boundedMs(tool_timeout_ms, null));
}

test "a bash timeout that is no number is the default, not no time at all" {
    // `timeout_ms` is model output and models write numbers as strings, send
    // a zero for "unlimited", and sign one by accident. Every value that is not
    // a usable count read as 0 ms, and a command under a deadline already spent
    // came back `command timed out after 0ms` without ever starting.
    try std.testing.expectEqual(default_bash_timeout_ms, bashTimeoutMs(requestedTimeoutMs(.{ .integer = 0 }), null));
    try std.testing.expectEqual(default_bash_timeout_ms, bashTimeoutMs(requestedTimeoutMs(.{ .integer = -1 }), null));
    try std.testing.expectEqual(default_bash_timeout_ms, bashTimeoutMs(requestedTimeoutMs(.{ .float = -1.0 }), null));
    try std.testing.expectEqual(default_bash_timeout_ms, bashTimeoutMs(requestedTimeoutMs(.{ .string = "soon" }), null));
    try std.testing.expectEqual(default_bash_timeout_ms, bashTimeoutMs(requestedTimeoutMs(.{ .null = {} }), null));
    try std.testing.expectEqual(default_bash_timeout_ms, bashTimeoutMs(requestedTimeoutMs(null), null));
    // A number is what was asked for, whichever way the model spelled it.
    try std.testing.expectEqual(@as(u64, 60_000), bashTimeoutMs(requestedTimeoutMs(.{ .integer = 60_000 }), null));
    try std.testing.expectEqual(@as(u64, 60_000), bashTimeoutMs(requestedTimeoutMs(.{ .float = 60_000.5 }), null));
    try std.testing.expectEqual(@as(u64, 60_000), bashTimeoutMs(requestedTimeoutMs(.{ .number_string = "60000" }), null));
    try std.testing.expectEqual(@as(u64, 60_000), bashTimeoutMs(requestedTimeoutMs(.{ .string = "60000" }), null));
}

test "a read count that is no number reads the file rather than nothing" {
    // `limit` and `offset` are integers in the schema, and a model that wrote
    // one as a string got zero: a limit of zero returned an empty result, and
    // an offset of zero clamped to the first line, so the model read a file it
    // had asked for a window of, or read nothing at all.
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const arena = state.allocator();
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "lines.txt", .data = "one\ntwo\nthree\n" });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(io, &root_buf)];

    const all = try dispatch(arena, "read", try std.fmt.allocPrint(arena, "{{\"path\":\"{s}/lines.txt\",\"limit\":\"2\"}}", .{root}));
    try std.testing.expectEqualStrings("one\ntwo\n", all);

    const from = try dispatch(arena, "read", try std.fmt.allocPrint(arena, "{{\"path\":\"{s}/lines.txt\",\"offset\":\"2\",\"limit\":1}}", .{root}));
    try std.testing.expectEqualStrings("two\n", from);

    // A number is still a number: the window asked for is the window read.
    const windowed = try dispatch(arena, "read", try std.fmt.allocPrint(arena, "{{\"path\":\"{s}/lines.txt\",\"offset\":2,\"limit\":1}}", .{root}));
    try std.testing.expectEqualStrings("two\n", windowed);

    // A value that is no number at all is the model's mistake, and the default
    // is the whole file rather than an empty one the model reads as no content.
    const malformed = try dispatch(arena, "read", try std.fmt.allocPrint(arena, "{{\"path\":\"{s}/lines.txt\",\"limit\":\"all\"}}", .{root}));
    try std.testing.expectEqualStrings("one\ntwo\nthree\n", malformed);
}

test "read refuses a secret file and says so, and reads the rest" {
    for ([_][]const u8{
        ".env",
        "./.env",
        "config/.env",
        "/home/u/app/.env.production",
        ".secrets/openrouter",
        "/home/u/.secrets/openrouter",
        "deploy/server.pem",
        "id_ed25519",
        ".netrc",
        "certs/tls.key",
        "certs/tls.key/",
        "home/u/.my.cnf",
    }) |path| {
        if (!isCredentialPath(path)) {
            std.debug.print("read would have leaked {s}\n", .{path});
            return error.TestUnexpectedResult;
        }
    }

    // The published half of a key pair is ordinary work, and a file that merely
    // contains the letters "key" is a source file. `.env.example` is not on
    // this list: a template committed with a real value in it is exactly the
    // file the name rule must not wave through, so it is refused with the rest.
    for ([_][]const u8{ "src/main.zig", "README.md", "cert.crt", "id_ed25519.pub", "monkey.zig" }) |path|
        try std.testing.expect(!isCredentialPath(path));
}

test "a read of a secret file returns the refusal, not the key" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = ".env", .data = "API_KEY=sk-do-not-send" });
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    const path = try std.fmt.allocPrint(arena, "{s}/.env", .{path_buf[0..n]});

    var args: std.json.ObjectMap = .empty;
    try args.put(arena, "path", .{ .string = path });
    const out = try toolRead(io, arena, args);
    try std.testing.expect(std.mem.indexOf(u8, out, "sk-do-not-send") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "credentials file") != null);
}

test "a write with no content is refused rather than emptying the file" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "keep me" });
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    const path = try std.fmt.allocPrint(arena, "{s}/a.txt", .{path_buf[0..n]});

    var args: std.json.ObjectMap = .empty;
    try args.put(arena, "path", .{ .string = path });
    try std.testing.expectEqualStrings("error: missing content", try toolWrite(io, arena, args));
    try std.testing.expectEqualStrings("keep me", try tmp.dir.readFileAlloc(io, "a.txt", arena, .limited(64)));

    // A model that means an empty file says so, and gets one.
    try args.put(arena, "content", .{ .string = "" });
    try std.testing.expect(std.mem.startsWith(u8, try toolWrite(io, arena, args), "wrote 0 bytes to "));
    try std.testing.expectEqualStrings("", try tmp.dir.readFileAlloc(io, "a.txt", arena, .limited(64)));
}

test "a key file reads as the key and nothing around it" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const arena = state.allocator();
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    const path = try std.fmt.allocPrint(arena, "{s}/openrouter", .{path_buf[0..n]});

    // The newline a shell heredoc or an editor leaves, which is the case the
    // trim has always covered.
    try tmp.dir.writeFile(io, .{ .sub_path = "openrouter", .data = "sk-or-v1-abc\n" });
    try std.testing.expectEqualStrings("sk-or-v1-abc", readSecret(io, arena, path).found);

    // A mark ahead of it. It is invisible in the editor that wrote the file, so
    // nothing on the way here looks like a mistake, and a request sent with it
    // carries U+FEFF as the first byte of the key and is refused as invalid.
    try tmp.dir.writeFile(io, .{ .sub_path = "openrouter", .data = chat.bom ++ "sk-or-v1-abc\n" });
    try std.testing.expectEqualStrings("sk-or-v1-abc", readSecret(io, arena, path).found);

    // A file that is nothing but a mark is a key file that is empty, which the
    // caller reports rather than sending.
    try tmp.dir.writeFile(io, .{ .sub_path = "openrouter", .data = chat.bom });
    try std.testing.expectEqualStrings("", readSecret(io, arena, path).found);

    // A mark inside the key is the key's own byte, not a header to skip.
    try tmp.dir.writeFile(io, .{ .sub_path = "openrouter", .data = "sk-a" ++ chat.bom ++ "b-c\n" });
    try std.testing.expectEqualStrings("sk-a" ++ chat.bom ++ "b-c", readSecret(io, arena, path).found);

    // A file that is not there is absent, which is the ordinary case for a run
    // whose key came from somewhere else and costs it nothing.
    const gone = try std.fs.path.join(arena, &.{ path_buf[0..n], "no-such-key-file" });
    try std.testing.expectEqual(SecretRead.absent, readSecret(io, arena, gone));
}

test "a tool argument cannot repaint the operator's terminal" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const arena = state.allocator();

    // ESC, the C1 CSI (C2 9B), and BEL are all shown as dots; the rest of the
    // line, including a multibyte character, is untouched.
    const got = terminalSafe(arena, "ls\x1b[2Jrm -rf /\u{009b}31m\x07 caf\u{00e9}");
    try std.testing.expectEqualStrings("ls.[2Jrm -rf /..31m. caf\u{00e9}", got);
    try std.testing.expectEqualStrings("plain text", terminalSafe(arena, "plain text"));
}

// An error body the provider sent is quoted onto the operator's screen, and it
// reached this program over the network, so its bytes are the provider's to
// choose. `terminalSafe` is the whole of what stands between them and a
// terminal, and the provider picks a value the harness cannot guess: an
// escape sequence split across a read boundary, a CSI spelled as C2 9B, a
// lone 0xC2 followed by nothing. `std.testing.fuzz` runs this corpus on every
// `zig build test`, and through the fuzzer's mutations when the test binary is
// built in fuzz mode.
const terminal_corpus = [_][]const u8{
    "",
    "a",
    "plain text",
    " \x1b[2Jrm -rf /",
    "\x07\x08\x0a\x0d\x1b",
    "\x00",
    "\x1f\x7f",
    "\u{009b}31m",
    "\u{0080}\u{009f}\u{00a0}",
    "\xc2",
    "\xc2\x9b",
    "\xc2\x9f",
    "\xc2\xa0",
    "caf\u{00e9} \u{65e5}\u{8a00} \u{1f600}",
    "\xe6\x97",
    "\xf0\x9f",
    "\xed\xa0\x80",
    "\xff\xfe",
    "{\"error\":{\"message\":\"rate limit\"}}",
    "<html>\n<head><title>502</title></head>\n</html>",
    "\x1b[31m" ** 20,
    "\u{009b}" ** 20,
    "mixed \xff caf\u{00e9} \u{009b} \n text" ** 8,
};

test "a fuzzed error body leaves nothing a terminal acts on" {
    try std.testing.fuzz({}, fuzzTerminalSafe, .{ .corpus = &terminal_corpus });
}

fn fuzzTerminalSafe(_: void, smith: *std.testing.Smith) !void {
    const gpa = std.testing.allocator;
    var raw: [4 * 1024]u8 = undefined;
    const text: []const u8 = if (smith.in) |seed| seed else raw[0..smith.slice(&raw)];

    var state = std.heap.ArenaAllocator.init(gpa);
    defer state.deinit();
    const safe = terminalSafe(state.allocator(), text);

    // The escaper replaces bytes rather than dropping them, so a diagnostic
    // still lines its fields up no matter what the body held.
    try std.testing.expectEqual(text.len, safe.len);

    var i: usize = 0;
    while (i < safe.len) : (i += 1) {
        const c = safe[i];
        try std.testing.expect(c >= 0x20 and c != 0x7f);
        if (c == 0xc2) {
            try std.testing.expect(i + 1 >= safe.len or safe[i + 1] > 0x9f);
            i += 1;
        }
    }

    // A byte that was already printable is left exactly as it was, so the
    // provider cannot have text rewritten around a sequence it wanted hidden.
    i = 0;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (c == 0xc2 and i + 1 < text.len and text[i + 1] >= 0x80 and text[i + 1] <= 0x9f) {
            i += 1;
            continue;
        }
        if (c < 0x20 or c == 0x7f) continue;
        try std.testing.expectEqual(c, safe[i]);
    }

    // The result is its own fixed point: a second pass has nothing left to
    // replace, so a value printed twice reads the same both times.
    const again = terminalSafe(state.allocator(), safe);
    try std.testing.expectEqualStrings(safe, again);
}

// `read` is the one tool whose result rides back to the provider on every
// later turn, so a credential it returns is shipped once per turn for the rest
// of the run. The refusal is a decision about the name alone: the path is
// model-supplied text and never reaches the filesystem first.
test "read refuses a credentials file and leaves every other path alone" {
    const refused = [_][]const u8{
        ".env",
        "backend/.env",
        ".env.production",
        "deploy/production.env",
        ".envrc",
        ".env.example",
        "/home/someone/.env",
        "certs/server.pem",
        "certs/server.PEM",
        "keys/id_ed25519",
        "keys/ID_RSA",
        "keys/id_ed25519_sk",
        "sops/store.age.key",
        "/home/someone/.secrets/openrouter",
        "project/.secrets/team/api",
        "/home/someone/.ssh/config",
        "home/user/.netrc",
        "home/user/_netrc",
        "home/user/.pgpass",
        "home/user/.npmrc",
        "home/user/.pypirc",
        "home/user/.git-credentials",
        "home/user/.aws/credentials",
        "vault.keystore",
        // A trailing separator names the same file, and the walk strips it
        // with the target's own separator rather than a literal one, so a
        // target whose separator is not `/` trims it too.
        "backend/.env/",
        "/home/someone/.ssh/config/",
        "certs/server.pem//",
    };
    for (refused) |path| {
        try std.testing.expect(isCredentialPath(path));
    }

    const allowed = [_][]const u8{
        "src/main.zig",
        "README.md",
        ".gitignore",
        "src/environment.zig",
        "docs/keyboard.md",
        "certs/server.crt",
        "certs/chain.pem.example",
        "keys/id_ed25519.pub",
        "src/id.rs",
        "config/identity.zig",
        "README",
    };
    for (allowed) |path| {
        try std.testing.expect(!isCredentialPath(path));
    }
}

// The refusal names the file, so a model that asked for it knows which one was
// turned down, and it says what to do instead rather than leaving a bare error
// that reads as a broken tool.
test "the credentials refusal names the file and the way out" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const refused = try credentialRefusal(arena, "read", "/home/someone/.secrets/openrouter");
    try std.testing.expect(std.mem.indexOf(u8, refused, "/home/someone/.secrets/openrouter") != null);
    try std.testing.expect(std.mem.indexOf(u8, refused, "bash") != null);
    // Not a single byte of a key is in the message, only the path that names it.
    try std.testing.expect(std.mem.indexOf(u8, refused, "sk-") == null);
}

// The guard is on the tool the model calls, not only on the predicate, so a
// refusal cannot be lost by a later refactor of the dispatch table.
test "the read tool refuses a credentials path through dispatch" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const refused = try dispatch(arena, "read", "{\"path\":\".env\"}");
    try std.testing.expect(std.mem.startsWith(u8, refused, "refused: .env is a credentials file"));
    try std.testing.expect(std.mem.indexOf(u8, refused, "SECRET=") == null);
}

// A refusal only `read` carries is a refusal the other two writing tools walk
// around, and the model is the one choosing which tool to call. `write`
// replaces a file whole and `edit` reads it to find its match, so a path the
// run may not read is a path the run must not rewrite either: the operator's
// key is the one file where a guessed replacement is damage nobody asked for.
test "the writing tools refuse a credentials path through dispatch" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const wrote = try dispatch(arena, "write", "{\"path\":\"/home/someone/.secrets/openrouter\",\"content\":\"sk-guess\"}");
    try std.testing.expect(std.mem.startsWith(u8, wrote, "refused: /home/someone/.secrets/openrouter is a credentials file"));
    try std.testing.expect(std.mem.indexOf(u8, wrote, "sk-guess") == null);
    // The advice cannot send the model to `bash` for this one, because `bash`
    // refuses the same file: a refusal that names the way round itself is the
    // hole the check exists to close.
    try std.testing.expect(std.mem.indexOf(u8, wrote, "`bash`") == null);
    try std.testing.expect(std.mem.indexOf(u8, wrote, "operator") != null);

    const edited = try dispatch(arena, "edit", "{\"path\":\".env\",\"old_string\":\"A=1\",\"new_string\":\"A=2\"}");
    try std.testing.expect(std.mem.startsWith(u8, edited, "refused: .env is a credentials file"));
    try std.testing.expect(std.mem.indexOf(u8, edited, "A=2") == null);

    // An ordinary file is still writable and still editable, so the refusal is
    // the name rule and not a broken tool. It goes in a temporary directory
    // rather than the working tree, because a test that leaves a file behind
    // in the repository it runs from is a test that changes what it measures.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(std.testing.io, &root_buf)];
    const plain = try std.fs.path.join(arena, &.{ root, "notes.txt" });
    const ok = try dispatch(arena, "write", try std.fmt.allocPrint(
        arena,
        "{{\"path\":\"{s}\",\"content\":\"x\"}}",
        .{plain},
    ));
    try std.testing.expect(std.mem.startsWith(u8, ok, "wrote "));
    try std.testing.expectEqualStrings("x", try tmp.dir.readFileAlloc(std.testing.io, "notes.txt", arena, .limited(64)));
}

// The refusal `read` makes is no protection to the operator when the same
// bytes come back one tool over: a tool result is re-sent to the provider on
// every later turn, and a search or a `git show` that matched a credentials
// file is a way round it.
test "search and ast skip the files read refuses, and git refuses one by name" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const arena = state.allocator();
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const needle = "sk-do-not-search";
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(io, &root_buf)];
    try tmp.dir.createDirPath(io, "deploy");
    // Visible to both backends: ripgrep and ast-grep skip a dotfile on their
    // own, so the case that has to be excluded here is a plain name beside
    // ordinary source, including the uppercase spelling a case-insensitive
    // filesystem resolves to the same file.
    for ([_][]const u8{ "app.py", "deploy/server.pem", "deploy/KEY.PEM", "deploy/production.env", "notes.txt" }) |name|
        try tmp.dir.writeFile(io, .{
            .sub_path = name,
            .data = try std.fmt.allocPrint(arena, "x = \"{s}\"\n", .{needle}),
        });

    const search = try std.fmt.allocPrint(arena, "{{\"pattern\":\"{s}\",\"path\":\"{s}\"}}", .{ needle, root });
    const found = try dispatch(arena, "search", search);
    try std.testing.expect(std.mem.indexOf(u8, found, "app.py") != null);
    try std.testing.expect(std.mem.indexOf(u8, found, "notes.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, found, "server.pem") == null);
    try std.testing.expect(std.mem.indexOf(u8, found, "KEY.PEM") == null);
    try std.testing.expect(std.mem.indexOf(u8, found, "production.env") == null);

    // The git tool reads a committed file as a patch, so it takes the same
    // refusal `read` gives rather than a git-shaped one.
    const refused = try dispatch(arena, "git", try std.fmt.allocPrint(
        arena,
        "{{\"cmd\":\"show\",\"rev\":\"HEAD\",\"path\":\"{s}/deploy/server.pem\"}}",
        .{root},
    ));
    try std.testing.expect(std.mem.startsWith(u8, refused, "refused: "));
    try std.testing.expect(std.mem.indexOf(u8, refused, needle) == null);

    // A file named as the path is the case the globs cannot cover: both
    // backends read an explicit path whatever their filters say, so the
    // needle came back the moment the model asked for that one file.
    for ([_][]const u8{ "search", "ast" }) |tool| {
        const named = try std.fmt.allocPrint(arena, "{{\"path\":\"{s}/deploy/server.pem\"{s}", .{
            root,
            if (std.mem.eql(u8, tool, "ast")) ",\"pattern\":\"$A\",\"lang\":\"python\"}" else ",\"pattern\":\"sk-do-not-search\"}",
        });
        const result = try dispatch(arena, tool, named);
        try std.testing.expect(std.mem.startsWith(u8, result, "refused: "));
        try std.testing.expect(std.mem.indexOf(u8, result, needle) == null);
    }
}

// A search returns the same bytes a `read` refuses, and the system prompt
// sends the model to `search` first, so a guard that only the `read` tool
// carries is a guard a single well-formed `search` walks around. The globs
// are what closes it, and the test runs the real ripgrep over a real tree
// rather than asserting on the argv, because a pattern ripgrep does not
// match the way `isCredentialPath` refuses is the whole failure.
test "a search returns no credentials file `read` would refuse" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // One file per way `isCredentialPath` refuses a name, each carrying the
    // same marker, plus the case variants a case-insensitive match has to
    // cover and one ordinary file that must survive.
    const secrets = [_]struct { sub: []const u8, data: []const u8 }{
        .{ .sub = ".env", .data = "MARKER=dotenv" },
        .{ .sub = "app.env", .data = "MARKER=suffixed" },
        .{ .sub = "config/.env.production", .data = "MARKER=dotted" },
        .{ .sub = "id_rsa", .data = "MARKER=key" },
        .{ .sub = "ID_RSA", .data = "MARKER=upperkey" },
        .{ .sub = "certs/tls.pem", .data = "MARKER=pem" },
        .{ .sub = "deploy/server.key", .data = "MARKER=keyext" },
        .{ .sub = ".secrets/openrouter", .data = "MARKER=secretsdir" },
        .{ .sub = "sub/.SSH/id_ed25519", .data = "MARKER=sshdir" },
        .{ .sub = "sub/credentials", .data = "MARKER=name" },
        .{ .sub = ".netrc", .data = "MARKER=netrc" },
    };
    for ([_][]const u8{ "config", "certs", "deploy", ".secrets", "sub/.SSH", "sub", "src" }) |dir|
        try tmp.dir.createDirPath(io, dir);
    for (secrets) |s| try tmp.dir.writeFile(io, .{ .sub_path = s.sub, .data = s.data });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/main.zig", .data = "MARKER=source\n" });

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = path_buf[0..try tmp.dir.realPath(io, &path_buf)];

    var args: std.json.ObjectMap = .empty;
    try args.put(arena, "pattern", .{ .string = "MARKER" });
    try args.put(arena, "path", .{ .string = root });
    const out = try toolSearch(io, arena, args, null, null);

    // Every one of the files above holds a distinct value and only that value,
    // so a hit on any of them is a credential handed to the provider. The
    // source file is the control: it holds the marker too, so a guard that
    // emptied every result would fail here rather than pass quietly.
    for (secrets) |s| {
        if (std.mem.indexOf(u8, out, s.data) != null) {
            std.debug.print("search leaked {s}\n", .{s.sub});
            return error.TestUnexpectedResult;
        }
    }
    try std.testing.expect(std.mem.indexOf(u8, out, "src/main.zig") != null);

    // Naming a credentials file as the search root is the other door in, and
    // takes the same refusal `read` gives it.
    var direct: std.json.ObjectMap = .empty;
    try direct.put(arena, "pattern", .{ .string = "MARKER" });
    try direct.put(arena, "path", .{ .string = try std.fs.path.join(arena, &.{ root, ".env" }) });
    const refused = try toolSearch(io, arena, direct, null, null);
    try std.testing.expect(std.mem.startsWith(u8, refused, "refused: "));
    try std.testing.expect(std.mem.indexOf(u8, refused, "MARKER") == null);
}

test "tool output truncation keeps whole lines" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const short = try firstLines(arena, "a\nb\n", 10);
    try std.testing.expectEqualStrings("a\nb\n", short);

    const long = try firstLines(arena, "1\n2\n3\n4\n", 2);
    try std.testing.expectEqualStrings("1\n2\n... [output truncated at 2 lines]", long);

    // A limit equal to the line count keeps every line and adds no marker.
    try std.testing.expectEqualStrings("1\n2\n", try firstLines(arena, "1\n2\n", 2));
    try std.testing.expectEqualStrings("1\n2\n3\n", try firstLines(arena, "1\n2\n3\n", 3));
    // A last line with no newline still counts, so the cut lands on it.
    try std.testing.expectEqualStrings("1\n... [output truncated at 1 lines]", try firstLines(arena, "1\n2", 1));
    try std.testing.expectEqualStrings("1\n2", try firstLines(arena, "1\n2", 2));
    // No newline at all means one line, which a limit of one keeps whole.
    try std.testing.expectEqualStrings("solo", try firstLines(arena, "solo", 1));
    try std.testing.expectEqualStrings("solo\n", try firstLines(arena, "solo\n", 1));
}

test "git tool refuses a rev that git would read as an option" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var args: std.json.ObjectMap = .empty;
    try args.put(arena, "cmd", .{ .string = "diff" });
    try args.put(arena, "rev", .{ .string = "--output=pwned" });
    const out = try toolGit(std.testing.io, arena, args, null, null);
    try std.testing.expectEqualStrings("error: rev must not start with '-'", out);
}

// `git show HEAD:.env` prints the committed file whatever the `:(exclude)`
// pathspecs say, because a tree-ish plus a path names an object rather than
// selecting one out of a diff. The credential comes back as a tool result and
// is re-sent to the provider on every later turn, so the rev is refused and the
// model is sent to the argument that is checked.
test "git tool refuses a rev that names a file through a tree-ish" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var creds: std.json.ObjectMap = .empty;
    try creds.put(arena, "cmd", .{ .string = "show" });
    try creds.put(arena, "rev", .{ .string = "HEAD:.env" });
    const refused = try toolGit(std.testing.io, arena, creds, null, null);
    try std.testing.expect(std.mem.startsWith(u8, refused, "refused: .env is a credentials file"));

    var plain: std.json.ObjectMap = .empty;
    try plain.put(arena, "cmd", .{ .string = "show" });
    try plain.put(arena, "rev", .{ .string = "HEAD:src/main.zig" });
    const directed = try toolGit(std.testing.io, arena, plain, null, null);
    try std.testing.expect(std.mem.startsWith(u8, directed, "error: rev must name a revision, not a file"));
    try std.testing.expect(std.mem.indexOf(u8, directed, "path argument") != null);

    // A rev with no path in it is what the tool is for, and it is not refused.
    var head: std.json.ObjectMap = .empty;
    try head.put(arena, "cmd", .{ .string = "diff" });
    try head.put(arena, "rev", .{ .string = "HEAD" });
    const shown = try toolGit(std.testing.io, arena, head, null, null);
    try std.testing.expect(!std.mem.startsWith(u8, shown, "error: rev"));
}

test "a git line limit is a ceiling, so zero is one line and a huge one is no trap" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqual(git_default_limit, gitLineLimit(.empty));
    var one: std.json.ObjectMap = .empty;
    try one.put(arena, "limit", .{ .integer = 12 });
    try std.testing.expectEqual(@as(usize, 12), gitLineLimit(one));
    var zero: std.json.ObjectMap = .empty;
    try zero.put(arena, "limit", .{ .integer = 0 });
    try std.testing.expectEqual(@as(usize, 1), gitLineLimit(zero));
    var negative: std.json.ObjectMap = .empty;
    try negative.put(arena, "limit", .{ .integer = -5 });
    try std.testing.expectEqual(@as(usize, 1), gitLineLimit(negative));
    // A count a 32-bit `usize` cannot hold is every line, not a trap.
    var huge: std.json.ObjectMap = .empty;
    try huge.put(arena, "limit", .{ .number_string = "18446744073709551615" });
    try std.testing.expectEqual(@as(usize, std.math.maxInt(usize)), gitLineLimit(huge));
    // A count sent as a float saturates the same way rather than truncating.
    try std.testing.expectEqual(@as(usize, std.math.maxInt(usize)), chat.numCount(.{ .float = 1e30 }));

    var lines: std.json.ObjectMap = .empty;
    try lines.put(arena, "limit", .{ .integer = 1 });
    const text = try firstLines(arena, "one\ntwo\nthree\n", gitLineLimit(lines));
    try std.testing.expectEqualStrings("one\n... [output truncated at 1 lines]", text);
}

test "git tool refuses a missing or unknown subcommand" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    {
        const out = try toolGit(std.testing.io, arena, .empty, null, null);
        try std.testing.expectEqualStrings("error: missing cmd", out);
    }
    {
        // The subcommand is what picks the git argv, so an unknown one has to
        // stop here rather than be handed to git.
        var args: std.json.ObjectMap = .empty;
        try args.put(arena, "cmd", .{ .string = "push" });
        try std.testing.expectEqualStrings(
            "error: unknown git cmd 'push'",
            try toolGit(std.testing.io, arena, args, null, null),
        );
    }
}

// The tool arguments are written by the model, so dispatch is the trust
// boundary: malformed JSON, a non-object payload, and an unrecognized name all
// fail before any tool opens a file or spawns a subprocess.
test "the tool dispatcher refuses arguments that are not an object" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectEqualStrings(
        "error: tool arguments are not valid JSON",
        try dispatch(arena, "read", "{"),
    );
    try std.testing.expectEqualStrings(
        "error: tool arguments must be an object",
        try dispatch(arena, "read", "[]"),
    );
    try std.testing.expectEqualStrings(
        "error: unknown tool 'delete_everything'",
        try dispatch(arena, "delete_everything", "{}"),
    );
}

// Every tool's required argument is checked before it opens a file or spawns a
// process, so a model that omits one gets "missing <arg>" rather than a
// confusing error from the kernel.
test "each tool refuses a missing required argument" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cases = [_]struct { tool: []const u8, args: []const u8, want: []const u8 }{
        .{ .tool = "bash", .args = "{}", .want = "error: missing command" },
        .{ .tool = "read", .args = "{}", .want = "error: missing path" },
        .{ .tool = "write", .args = "{}", .want = "error: missing path" },
        .{ .tool = "edit", .args = "{}", .want = "error: missing path" },
        .{ .tool = "edit", .args = "{\"path\":\"a.zig\"}", .want = "error: missing old_string" },
        .{ .tool = "edit", .args = "{\"path\":\"a.zig\",\"old_string\":\"a\"}", .want = "error: missing new_string" },
        .{ .tool = "search", .args = "{}", .want = "error: missing pattern" },
        .{ .tool = "ast", .args = "{}", .want = "error: missing pattern" },
        .{ .tool = "ast", .args = "{\"pattern\":\"a$b\"}", .want = "error: missing lang" },
        .{ .tool = "git", .args = "{}", .want = "error: missing cmd" },
    };
    for (cases) |c| {
        try std.testing.expectEqualStrings(c.want, try dispatch(arena, c.tool, c.args));
    }
    // The same omissions go through dispatch, not only the direct call.
    try std.testing.expectEqualStrings(
        "error: missing pattern",
        try dispatch(arena, "search", "{\"path\":\".\"}"),
    );
}

// A limit the model can type is a number it chose, and git parses the one it is
// given: `git log -n 18446744073709551615` answers `fatal: not an integer` and
// the model gets no log at all. What reaches git is a count it accepts, and
// what reaches the model is still every line the capture cap let through.
test "a git line limit past what git parses is cut, not handed over" {
    try std.testing.expectEqual(@as(usize, 1), gitLogLines(1));
    try std.testing.expectEqual(git_default_limit, gitLogLines(git_default_limit));
    try std.testing.expectEqual(git_log_line_ceiling, gitLogLines(std.math.maxInt(usize)));
    // Nothing past the ceiling is ever spelled for git, on a 32-bit build or
    // a 64-bit one.
    try std.testing.expect(gitLogLines(std.math.maxInt(u32)) <= git_log_line_ceiling);
}

// A missing argument that the model filled with a number is still missing: the
// tools read their arguments through `str`, which refuses every non-string.
test "a tool argument sent as a number is missing, not a value" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectEqualStrings(
        "error: missing path",
        try dispatch(arena, "read", "{\"path\":42}"),
    );
    try std.testing.expectEqualStrings(
        "error: missing command",
        try dispatch(arena, "bash", "{\"command\":null}"),
    );
}

test "a child that outruns the capture cap keeps its first bytes instead of failing" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cap: usize = 4096;
    // `std.process.run` answers this with `error.StreamTooLong` and no output at
    // all, which is what a chatty build or a broad ripgrep used to hand back.
    const noisy = try runCapped(std.testing.io, arena, &.{
        "/bin/sh", "-c", "head -c 200000 /dev/zero | tr '\\0' 'a'",
    }, cap, net.durationMs(30_000), null);
    try std.testing.expectEqual(cap, noisy.stdout.len);
    try std.testing.expect(atCaptureLimit(noisy));
    try std.testing.expectEqualStrings("a" ** 8, noisy.stdout[0..8]);
    // The child still ran to its own end, so the status is the command's.
    switch (noisy.term) {
        .exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
        else => return error.TestUnexpectedResult,
    }

    const quiet = try runCapped(std.testing.io, arena, &.{
        "/bin/sh", "-c", "echo hi; echo bye >&2",
    }, cap, net.durationMs(30_000), null);
    try std.testing.expectEqualStrings("hi\n", quiet.stdout);
    try std.testing.expectEqualStrings("bye\n", quiet.stderr);
    try std.testing.expect(!atCaptureLimit(quiet));
}

// Output that lands exactly on the cap was not cut short, and saying it was
// makes the model reason about a log it actually has in full.
test "output ending exactly on the cap is not reported as truncated" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const cap: usize = 4096;

    const exact = try runCapped(std.testing.io, arena_state.allocator(), &.{
        "/bin/sh", "-c", "head -c 4096 /dev/zero | tr '\\0' 'a'",
    }, cap, net.durationMs(30_000), null);
    try std.testing.expectEqual(cap, exact.stdout.len);
    try std.testing.expect(!atCaptureLimit(exact));
}

test "both pipes past the cap drain together, so the child never wedges" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const cap: usize = 4096;

    const noisy = try runCapped(std.testing.io, arena_state.allocator(), &.{
        "/bin/sh",
        "-c",
        "head -c 200000 /dev/zero | tr '\\0' 'a'; head -c 200000 /dev/zero | tr '\\0' 'b' >&2",
    }, cap, net.durationMs(30_000), null);
    try std.testing.expectEqual(cap, noisy.stdout.len);
    try std.testing.expectEqual(cap, noisy.stderr.len);
    try std.testing.expectEqualStrings("a" ** 8, noisy.stdout[0..8]);
    try std.testing.expectEqualStrings("b" ** 8, noisy.stderr[0..8]);
}

test "a truncated tool result keeps whole codepoints" {
    // "日" is 3 bytes, so a 4- or 5-byte cut lands inside it.
    try std.testing.expectEqualStrings("abc", chat.clamp("abc日本", 4));
    try std.testing.expectEqualStrings("ab", chat.clamp("ab日", 4));
    try std.testing.expectEqualStrings("abc", chat.clamp("abc", 4));
    try std.testing.expect(std.unicode.utf8ValidateSlice(chat.clamp("abc日本語のテキスト", 8)));
}

// The edit tool rewrites a file the model named, and the one-match case has to
// come out the same whether or not `replace_all` was asked for: the count
// checks above refuse an ambiguous match, so both paths have exactly the
// occurrences they are going to replace. The tool resolves paths against the
// process directory, so the test runs from the temp directory it edits.
test "edit replaces one match, or every match when asked" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const arena = state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = cwd_buf[0..try tmp.dir.realPath(std.testing.io, &cwd_buf)];
    const orig = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", arena);
    try std.process.setCurrentPath(std.testing.io, tmp_path);
    defer std.process.setCurrentPath(std.testing.io, orig) catch {};

    var args: std.json.ObjectMap = .empty;
    try args.put(arena, "path", .{ .string = "a.txt" });
    try args.put(arena, "old_string", .{ .string = "x" });
    try args.put(arena, "new_string", .{ .string = "y" });

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "a.txt", .data = "a x b" });
    try std.testing.expectEqualStrings("replaced 1 occurrence(s) in a.txt", try toolEdit(std.testing.io, arena, args));
    try std.testing.expectEqualStrings("a y b", try tmp.dir.readFileAlloc(std.testing.io, "a.txt", arena, .limited(64)));

    // An ambiguous match is refused rather than guessed at, so the file the
    // model was shown is still the file on disk.
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "a.txt", .data = "x and x" });
    try std.testing.expect(std.mem.startsWith(u8, try toolEdit(std.testing.io, arena, args), "error: old_string occurs 2 times"));
    try std.testing.expectEqualStrings("x and x", try tmp.dir.readFileAlloc(std.testing.io, "a.txt", arena, .limited(64)));

    try args.put(arena, "replace_all", .{ .bool = true });
    try std.testing.expectEqualStrings("replaced 2 occurrence(s) in a.txt", try toolEdit(std.testing.io, arena, args));
    try std.testing.expectEqualStrings("y and y", try tmp.dir.readFileAlloc(std.testing.io, "a.txt", arena, .limited(64)));
}

// One edit, issued twice, on a file the two runs cannot tell apart.
//
// The contract is that the second run leaves the file as the first one left
// it: either the same bytes, or the edit is refused. The case that needs a
// rule is the one where the replacement still holds the text it replaces,
// which the first run leaves in the file for the second to match, so the file
// would grow or re-indent once more per duplicate. That shape is refused
// before anything is written, which is the only way to make it re-runnable:
// an applied edit and an already-applied one leave the same bytes, so
// nothing at the tool can tell them apart afterwards.
test "an edit issued twice leaves the file the first run left" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const arena = state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = cwd_buf[0..try tmp.dir.realPath(std.testing.io, &cwd_buf)];
    const orig = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", arena);
    try std.process.setCurrentPath(std.testing.io, tmp_path);
    defer std.process.setCurrentPath(std.testing.io, orig) catch {};

    var args: std.json.ObjectMap = .empty;
    try args.put(arena, "path", .{ .string = "a.txt" });

    // The ordinary edit: the second run finds no text to replace, so it is
    // refused and the file keeps the first run's bytes.
    try args.put(arena, "old_string", .{ .string = "x" });
    try args.put(arena, "new_string", .{ .string = "y" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "a.txt", .data = "a x b" });
    try std.testing.expectEqualStrings("replaced 1 occurrence(s) in a.txt", try toolEdit(std.testing.io, arena, args));
    try std.testing.expect(std.mem.startsWith(u8, try toolEdit(std.testing.io, arena, args), "error: old_string not found"));
    try std.testing.expectEqualStrings("a y b", try tmp.dir.readFileAlloc(std.testing.io, "a.txt", arena, .limited(64)));

    // The nesting shape, refused on the first run rather than applied and
    // nested again on the second.
    try args.put(arena, "old_string", .{ .string = "x" });
    try args.put(arena, "new_string", .{ .string = "xy" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "a.txt", .data = "a x b" });
    try std.testing.expect(std.mem.startsWith(u8, try toolEdit(std.testing.io, arena, args), "error: new_string contains old_string"));
    try std.testing.expectEqualStrings("a x b", try tmp.dir.readFileAlloc(std.testing.io, "a.txt", arena, .limited(64)));

    // Replacing text with itself writes nothing, so a duplicate of it is not a
    // second write either.
    try args.put(arena, "old_string", .{ .string = "x" });
    try args.put(arena, "new_string", .{ .string = "x" });
    try std.testing.expect(std.mem.startsWith(u8, try toolEdit(std.testing.io, arena, args), "no change:"));
    try std.testing.expectEqualStrings("a x b", try tmp.dir.readFileAlloc(std.testing.io, "a.txt", arena, .limited(64)));
}

/// Asserts that a tool call took its whole process tree down with it. The
/// command backgrounds a grandchild that outlives the shell that started it,
/// writes that grandchild's pid, and then leaves the pipe held open: without
/// the group signal the grandchild is still alive when the call returns, and
/// every timed-out call leaked one.
fn expectNoProcessSurvived() !void {
    const pid_name = "grandchild.pid";
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    const pid_path = try std.fs.path.join(arena, &.{ path_buf[0..n], pid_name });
    // The shell exits at once; the grandchild holds the pipe open, so the read
    // only ends at the timeout, which is the path under test. `$!` and not
    // `$$`: inside a nested `sh -c` the latter is still the outer shell's pid,
    // which has already exited, so the check below would pass on a process
    // that was never running.
    const script = try std.fmt.allocPrint(arena, "sh -c 'sleep 30 & echo $! > {s}; wait' & exit 0", .{pid_path});
    try std.testing.expectError(error.Timeout, runCapped(io, arena, &.{ "/bin/sh", "-c", script }, 4096, net.durationMs(300), null));

    const raw = tmp.dir.readFileAlloc(io, pid_name, arena, .limited(64)) catch return error.GrandchildNotReported;
    const pid = try std.fmt.parseInt(std.posix.pid_t, std.mem.trim(u8, raw, " \t\r\n"), 10);
    // The kill is delivered asynchronously and the orphan is reaped by init
    // afterwards, so "gone" is a short poll rather than an instant check.
    var attempt: usize = 0;
    while (attempt < 50) : (attempt += 1) {
        std.posix.kill(pid, .CONT) catch return;
        try io.sleep(.{ .nanoseconds = 20 * std.time.ns_per_ms }, .awake);
    }
    std.debug.print("grandchild {d} survived the timed-out call\n", .{pid});
    return error.GrandchildSurvived;
}

test "an interrupt during a tool call is forwarded to that call's process group" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Read the disposition back rather than raising the signal: a raised
    // SIGINT ends the run, and this run is the test binary. Both dispositions
    // the installer writes are read and both are put back, because
    // `onInterrupt` exits the process: a SIGTERM left aimed at it for the rest
    // of the binary means a cancelled CI job, or a harness that timed out, is
    // answered by the test runner exiting 130 where it should report a failure.
    var before: std.posix.Sigaction = undefined;
    var before_term: std.posix.Sigaction = undefined;
    std.posix.sigaction(.INT, null, &before);
    std.posix.sigaction(.TERM, null, &before_term);
    forwardInterruptsToToolGroup();
    var after: std.posix.Sigaction = undefined;
    var after_term: std.posix.Sigaction = undefined;
    std.posix.sigaction(.INT, null, &after);
    std.posix.sigaction(.TERM, null, &after_term);
    std.posix.sigaction(.INT, &before, null);
    std.posix.sigaction(.TERM, &before_term, null);
    try std.testing.expect(after.handler.handler == onInterrupt);
    try std.testing.expect(after_term.handler.handler == onInterrupt);

    const Thread = std.Thread;
    const Call = struct {
        pub fn go(a: std.mem.Allocator, t: Io) void {
            // The call outlives nothing here: the handler kills its group, so
            // a hung call would hang the suite rather than fail it.
            _ = runCapped(t, a, &.{ "/bin/sh", "-c", "sleep 5" }, 4096, net.durationMs(3000), null) catch {};
        }
    };
    const thread = try Thread.spawn(.{}, Call.go, .{ arena, io });
    // Published for as long as the call runs, which is what the handler reads.
    var attempt: usize = 0;
    while (tool_group.load(.monotonic) == 0 and attempt < 200) : (attempt += 1)
        try io.sleep(.{ .nanoseconds = 5 * std.time.ns_per_ms }, .awake);
    try std.testing.expect(tool_group.load(.monotonic) > 0);
    thread.join();
    try std.testing.expectEqual(@as(std.posix.pid_t, 0), tool_group.load(.monotonic));
}

test "a tool call reports the exit status of the command it ran" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const res = try runCapped(std.testing.io, arena, &.{ "/bin/sh", "-c", "printf out; printf err 1>&2; exit 3" }, 4096, net.durationMs(10_000), null);
    try std.testing.expectEqualStrings("out", res.stdout);
    try std.testing.expectEqualStrings("err", res.stderr);
    try std.testing.expectEqual(@as(u8, 3), res.term.exited);
}

/// How far short of its deadline a timeout is allowed to come back, measured
/// between the timer the wait is armed on and the clock the elapsed time is
/// read off. Well under the smallest budget the assertion below is about, and
/// three orders of magnitude above the skew it covers.
const deadline_slack_ms: u64 = 10;

// A timeout that is re-armed by every read is not a timeout. Both runners
// wait on the child's pipes in a loop, and a command that keeps writing never
// lets one of those waits reach the end of the duration, so the call runs for
// as long as the command keeps talking: a `yes` in a build script outlives a
// ten-minute ceiling, and with it the run's own budget, which is cut from what
// is left of that ceiling.
test "a tool call is timed out by the clock, not by how long it stayed quiet" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // A byte every tenth of a second: fast enough that every wait ends in a
    // read and is re-armed, slow enough that the output cap is nowhere near
    // being reached. What is left to end the call is the deadline.
    // A host whose `sleep` has no fractional form fails the assertion below
    // loudly rather than passing it.
    const script = "while :; do printf x; sleep 0.1; done";
    const budget_ms: u64 = 400;
    const started = Io.Timestamp.now(io, .awake).nanoseconds;
    try std.testing.expectError(error.Timeout, runCapped(io, arena, &.{ "/bin/sh", "-c", script }, 4096, net.durationMs(budget_ms), null));
    const spent = Io.Timestamp.now(io, .awake).nanoseconds - started;
    // The deadline is what ended the call, so it did not return before it: an
    // error raised on the way in is a different fault wearing this one's name,
    // and a lower bound is what tells the two apart. The bound carries
    // `deadline_slack_ms` because the wait is armed on a timer and the elapsed
    // time is read off a clock, and the two are not the same reading: a
    // machine that has been suspended, or one whose timer fires on the first
    // tick of a coarser one, hands back a deadline a hair before it is due.
    try std.testing.expect(spent + deadline_slack_ms * std.time.ns_per_ms >= budget_ms * std.time.ns_per_ms);
}

test "a tool call that times out leaves no process of its own behind" {
    try expectNoProcessSurvived();
}

// `bash` is the tool with no path argument, so it is the one a model reaches a
// credentials file through: `read` refuses the file, `bash: cat` does not, and
// what `cat` returns is a tool result the provider reads again on every later
// turn. The check is over the command's words rather than a parsed AST, so it
// is pinned on the words it does and does not claim.
test "bash refuses a command naming a credentials file" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const refused = [_][]const u8{
        "cat .env",
        "cat ./.env",
        "cat $PWD/.env",
        "head -n 2 .env.production",
        "cat ~/.ssh/id_ed25519",
        "cp ~/.secrets/openrouter /tmp/x",
        "git show HEAD -- .env",
    };
    for (refused) |command| {
        const out = try dispatch(arena, "bash", try std.fmt.allocPrint(arena, "{{\"command\":\"{s}\"}}", .{command}));
        try std.testing.expect(std.mem.startsWith(u8, out, "refused:"));
    }

    // The narrowness is the point: a bare word that happens to be in the
    // credential names table is an ordinary argument to a search, and refusing
    // it would break real work for no protection.
    const allowed = [_][]const u8{
        "rg identity src",
        "rg -w credentials .",
        "zig build test",
        "cat README.md",
    };
    for (allowed) |command| {
        try std.testing.expectEqual(@as(?[]const u8, null), credentialInCommand(command));
    }
}

// The provider key lives in this process's environment, and a tool subprocess
// used to inherit all of it. The result of `printenv` is a tool result, so the
// key would have been in the request body of every remaining turn of the run.
test "a tool subprocess cannot see the provider key" {
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    try env.put("PATH", "/usr/bin");
    try env.put("OPENROUTER_API_KEY", "sk-live-not-a-real-key");
    try env.put("MICROAGENT_API_KEY", "sk-live-not-a-real-key");

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The map the run hands its tools is built by main, which owns the list of
    // key variables. Here the same two names are removed by hand so the
    // assertion is about the runner, not about main's copy loop.
    var clean: std.process.Environ.Map = .init(std.testing.allocator);
    defer clean.deinit();
    try clean.put("PATH", "/usr/bin");

    const res = try runCapped(
        std.testing.io,
        arena,
        &.{ "/bin/sh", "-c", "printenv OPENROUTER_API_KEY; printenv PATH" },
        4096,
        net.durationMs(10_000),
        &clean,
    );
    try std.testing.expect(std.mem.indexOf(u8, res.stdout, "sk-live") == null);
    try std.testing.expect(std.mem.indexOf(u8, res.stdout, "/usr/bin") != null);

    // Under the inherited environment the same command does print it, which is
    // what makes the first assertion mean something.
    const inherited = try runCapped(
        std.testing.io,
        arena,
        &.{ "/bin/sh", "-c", "printenv OPENROUTER_API_KEY" },
        4096,
        net.durationMs(10_000),
        &env,
    );
    try std.testing.expect(std.mem.indexOf(u8, inherited.stdout, "sk-live-not-a-real-key") != null);
}
