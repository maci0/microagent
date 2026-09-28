//! Every tool the model can call, and the process runner they share.
//!
//! The agent loop owns the conversation and the provider request; this owns
//! what runs on the machine for it. That split is the boundary that matters:
//! everything below is reached by a model-supplied name and model-supplied
//! arguments, so it is capped, reaped and reported from one place.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

const chat = @import("chat.zig");
const net = @import("net.zig");

const max_tool_output = 24 * 1024;

/// Ceiling on a file `read` returns whole. A source file is kilobytes, so the
/// cap is what keeps one `read` of a multi-gigabyte artifact out of the
/// conversation.
const max_read_bytes: usize = 4 * 1024 * 1024;
/// `edit` reads the file it rewrites, so it holds the larger of the two.
const max_edit_bytes: usize = 8 * 1024 * 1024;
/// A secret file is one key, not a document.
const max_secret_bytes: usize = 4096;

/// Ceilings shared by every tool that shells out: how long a read-only
/// subprocess may run, and how much of its stderr is worth keeping. stdout gets
/// `max_tool_output * 4` everywhere, and is trimmed to `max_tool_output` by
/// `clamp` before it reaches the model.
const tool_timeout_ms: u64 = 60_000;
const tool_stderr_limit: usize = 4096;
/// Ceiling on the `timeout_ms` a model may ask `bash` for. The value is model
/// output, so it arrives with the same trust as a path or a command string: an
/// unbounded one leaves a build running with no deadline, and the process-group
/// kill that reaps it never fires. A request past this gets the ceiling.
const max_bash_timeout_ms: u64 = 600_000;
/// What `bash` runs under when the model sends no `timeout_ms`.
const default_bash_timeout_ms: u64 = 120_000;

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
    pgid: ?std.posix.pid_t,

    pub fn spawn(io: Io, argv: []const []const u8) !ToolChild {
        const child = try std.process.spawn(io, .{
            .argv = argv,
            .pgid = 0, // its own group leader, so the group signal stays ours
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .pipe,
        });
        return .{
            .child = child,
            .pgid = if (builtin.os.tag == .windows) null else @intCast(child.id.?),
        };
    }

    /// Signals the whole group and then reaps the direct child, so a timeout
    /// leaves neither an orphan nor a zombie. A child already reaped by `wait`
    /// is a no-op here, and its group still gets the signal: a command that
    /// backgrounded work and exited must not outlive the call.
    pub fn reap(self: *ToolChild, io: Io) void {
        if (self.pgid) |group| signalGroup(group);
        self.child.kill(io);
    }
};

/// Runs a tool subprocess and reaps it with everything it started.
/// A key file under `$HOME/.secrets`, read whole and trimmed. A secret is one
/// key, not a document, so it is read under a cap of its own rather than the
/// one `read` uses for source.
pub fn readSecret(init: std.process.Init, name: []const u8) ?[]const u8 {
    const home = init.environ_map.get("HOME") orelse return null;
    const path = std.fmt.allocPrint(init.arena.allocator(), "{s}/.secrets/{s}", .{ home, name }) catch return null;
    const raw = std.Io.Dir.cwd().readFileAlloc(init.io, path, init.arena.allocator(), .limited(max_secret_bytes)) catch return null;
    return std.mem.trim(u8, raw, " \t\r\n");
}

pub fn runToolProcess(
    io: Io,
    arena: std.mem.Allocator,
    argv: []const []const u8,
    stdout_limit: usize,
    stderr_limit: usize,
    timeout: Io.Timeout,
) !std.process.RunResult {
    var spawned = try ToolChild.spawn(io, argv);
    // The group is published while the call runs, so an interrupt reaches it,
    // and cleared on the way out, so a later signal does not hit a dead group.
    watchToolGroup(spawned.pgid);
    defer {
        watchToolGroup(null);
        spawned.reap(io);
    }
    const child = &spawned.child;

    var multi_buffer: Io.File.MultiReader.Buffer(2) = undefined;
    var multi: Io.File.MultiReader = undefined;
    multi.init(arena, io, multi_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi.deinit();

    while (multi.fill(64, timeout)) |_| {
        if (multi.reader(0).bufferedLen() > stdout_limit) return error.StreamTooLong;
        if (multi.reader(1).bufferedLen() > stderr_limit) return error.StreamTooLong;
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => |e| return e,
    }
    try multi.checkAnyError();

    const term = try child.wait(io);
    return .{
        .term = term,
        .stdout = try multi.toOwnedSlice(0),
        .stderr = try multi.toOwnedSlice(1),
    };
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

fn watchToolGroup(pgid: ?std.posix.pid_t) void {
    tool_group.store(if (pgid) |group| group else 0, .monotonic);
}

/// Installed once the run starts, so Ctrl+C and `kill` reach the tools. Help,
/// the version and the update subcommand own no subprocess and keep the default
/// disposition.
pub fn forwardInterruptsToToolGroup() void {
    if (builtin.os.tag == .windows) return;
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
fn runSearchTool(io: Io, arena: std.mem.Allocator, argv: []const []const u8, what: []const u8) ![]u8 {
    const res = runToolProcess(io, arena, argv, max_tool_output * 4, tool_stderr_limit, net.durationMs(tool_timeout_ms)) catch |err|
        return std.fmt.allocPrint(arena, "error: {s} failed: {s}", .{ what, @errorName(err) });
    if (res.stdout.len > 0) return res.stdout;
    if (res.stderr.len > 0) return res.stderr;
    return std.fmt.allocPrint(arena, "(no matches)", .{});
}

/// Lines of git output a call keeps when the model asks for no limit: a raw
/// `git log` in a big repository is thousands of lines of context nobody reads.
const git_default_limit: usize = 400;

/// How many lines of git output the model reads. `limit` is a ceiling, so a
/// limit of zero is one line rather than the whole output, and a limit a 32-bit
/// `usize` cannot hold is every line rather than a trap.
fn gitLineLimit(args: std.json.ObjectMap) usize {
    const v = args.get("limit") orelse return git_default_limit;
    return @max(1, chat.numCount(v));
}

/// Read-only git, with the subcommands fixed here rather than assembled by the
/// model. Deterministic, no shell quoting, and the output is capped.
fn toolGit(io: Io, arena: std.mem.Allocator, args: std.json.ObjectMap) ![]u8 {
    const cmd = chat.str(args.get("cmd")) orelse return std.fmt.allocPrint(arena, "error: missing cmd", .{});
    const path = chat.str(args.get("path"));
    const rev = chat.str(args.get("rev"));
    const limit = gitLineLimit(args);
    // A rev such as `--output=FILE` would turn a read into a write.
    if (rev) |r| if (std.mem.startsWith(u8, r, "-"))
        return std.fmt.allocPrint(arena, "error: rev must not start with '-'", .{});

    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ "git", "--no-pager" });
    if (std.mem.eql(u8, cmd, "status")) {
        try argv.appendSlice(arena, &.{ "status", "--short", "--branch" });
    } else if (std.mem.eql(u8, cmd, "diff")) {
        try argv.appendSlice(arena, &.{ "diff", "--no-color" });
        if (rev) |r| try argv.append(arena, r);
    } else if (std.mem.eql(u8, cmd, "log")) {
        try argv.appendSlice(arena, &.{ "log", "--oneline", "--no-color", "-n", "30" });
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
    if (path) |p| try argv.append(arena, p);

    const res = runToolProcess(io, arena, argv.items, max_tool_output * 4, tool_stderr_limit, net.durationMs(tool_timeout_ms)) catch |err|
        return std.fmt.allocPrint(arena, "error: git {s} failed: {s}", .{ cmd, @errorName(err) });
    const text = if (res.stdout.len > 0) res.stdout else res.stderr;
    if (text.len == 0) return std.fmt.allocPrint(arena, "(git {s}: no output)", .{cmd});
    return firstLines(arena, text, limit);
}

/// The first `limit` lines, with a note when lines were dropped.
fn firstLines(arena: std.mem.Allocator, text: []const u8, limit: usize) ![]u8 {
    var lines: usize = 0;
    var end: usize = text.len;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] != '\n') continue;
        lines += 1;
        if (lines == limit) {
            end = i + 1;
            break;
        }
    }
    if (end == text.len) return arena.dupe(u8, text);
    return std.fmt.allocPrint(arena, "{s}... [output truncated at {d} lines]", .{ text[0..end], limit });
}

pub fn runTool(io: Io, arena: std.mem.Allocator, call: chat.ToolCall) ![]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, arena, call.args.items, .{}) catch
        return std.fmt.allocPrint(arena, "error: tool arguments are not valid JSON", .{});
    const args = switch (parsed.value) {
        .object => |o| o,
        else => return std.fmt.allocPrint(arena, "error: tool arguments must be an object", .{}),
    };

    noteToolCall(io, arena, call.name, args);
    if (std.mem.eql(u8, call.name, "bash")) return toolBash(io, arena, args);
    if (std.mem.eql(u8, call.name, "read")) return toolRead(io, arena, args);
    if (std.mem.eql(u8, call.name, "write")) return toolWrite(io, arena, args);
    if (std.mem.eql(u8, call.name, "edit")) return toolEdit(io, arena, args);
    if (std.mem.eql(u8, call.name, "search")) return toolSearch(io, arena, args);
    if (std.mem.eql(u8, call.name, "ast")) return toolAst(io, arena, args);
    if (std.mem.eql(u8, call.name, "git")) return toolGit(io, arena, args);
    return std.fmt.allocPrint(arena, "error: unknown tool '{s}'", .{call.name});
}

/// A one-line tool gutter on stderr, the shape gauntlet recognizes. The name
/// and the detail are the provider's own text and may carry a newline or an
/// escape sequence, either of which breaks the one-line-per-call shape a reader
/// parses, so control characters are written as their two-character escapes.
fn noteToolCall(io: Io, arena: std.mem.Allocator, name: []const u8, args: std.json.ObjectMap) void {
    // The interesting argument is not the same one for every tool: a structural
    // search is identified by its pattern, a bash call by its command.
    const detail = if (std.mem.eql(u8, name, "ast"))
        (chat.str(args.get("pattern")) orelse "")
    else
        (chat.str(args.get("command")) orelse chat.str(args.get("pattern")) orelse chat.str(args.get("path")) orelse "");
    var buf: std.ArrayList(u8) = .empty;
    buf.appendSlice(arena, "\u{23fa} ") catch return;
    writeGutterText(arena, &buf, chat.clamp(name, 40)) catch return;
    buf.append(arena, ' ') catch return;
    writeGutterText(arena, &buf, chat.clamp(detail, 120)) catch return;
    buf.append(arena, '\n') catch return;
    net.writeErr(io, buf.items);
}

/// Gutter text with every C0 control and DEL written as `\xNN`, and bytes that
/// are not valid UTF-8 written as U+FFFD, so one call stays one line.
const hex_digits = "0123456789abcdef";

fn writeGutterText(gpa: std.mem.Allocator, buf: *std.ArrayList(u8), s: []const u8) !void {
    var i: usize = 0;
    var start: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (c < 0x20 or c == 0x7f) {
            try buf.appendSlice(gpa, s[start..i]);
            try buf.appendSlice(gpa, &.{ '\\', 'x', hex_digits[c >> 4], hex_digits[c & 0x0f] });
            i += 1;
            start = i;
            continue;
        }
        const len: usize = if (c < 0x80) 1 else chat.utf8SequenceLen(s, i);
        if (len == 0) {
            try buf.appendSlice(gpa, s[start..i]);
            try buf.appendSlice(gpa, "\u{fffd}");
            i += 1;
            start = i;
            continue;
        }
        i += len;
    }
    try buf.appendSlice(gpa, s[start..i]);
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
fn bashTimeoutMs(requested: ?u64) u64 {
    return @min(requested orelse default_bash_timeout_ms, max_bash_timeout_ms);
}

fn toolBash(io: Io, arena: std.mem.Allocator, args: std.json.ObjectMap) ![]u8 {
    const command = chat.str(args.get("command")) orelse return std.fmt.allocPrint(arena, "error: missing command", .{});
    const timeout_ms: u64 = bashTimeoutMs(if (args.get("timeout_ms")) |v| chat.num(v) else null);
    const capture_limit = max_tool_output * 4;
    const res = runCapped(io, arena, &.{ "/bin/sh", "-c", command }, capture_limit, net.durationMs(timeout_ms)) catch |err| switch (err) {
        error.Timeout => return std.fmt.allocPrint(arena, "error: command timed out after {d}ms", .{timeout_ms}),
        else => return std.fmt.allocPrint(arena, "error: {s}", .{@errorName(err)}),
    };
    var buf: std.ArrayList(u8) = .empty;
    if (res.stdout.len > 0) try buf.appendSlice(arena, res.stdout);
    if (res.stderr.len > 0) {
        if (buf.items.len > 0) try buf.appendSlice(arena, "\n");
        try buf.appendSlice(arena, res.stderr);
    }
    // Output the model acts on is cut at the cap, so say so rather than letting
    // a half-read build log or diff read as the whole one.
    if (atCaptureLimit(res)) {
        if (buf.items.len > 0) try buf.appendSlice(arena, "\n");
        try buf.appendSlice(arena, "[output truncated at the tool's cap]");
    }
    if (buf.items.len == 0) return std.fmt.allocPrint(arena, "(no output, exit {s})", .{@tagName(res.term)});
    if (res.term != .exited or res.term.exited != 0) {
        try buf.appendSlice(arena, "\n(exit: ");
        try buf.appendSlice(arena, @tagName(res.term));
        if (res.term == .exited)
            try buf.appendSlice(arena, try std.fmt.allocPrint(arena, " {d}", .{res.term.exited}));
        try buf.appendSlice(arena, ")");
    }
    return buf.items;
}

fn toolRead(io: Io, arena: std.mem.Allocator, args: std.json.ObjectMap) ![]u8 {
    const path = chat.str(args.get("path")) orelse return std.fmt.allocPrint(arena, "error: missing path", .{});
    const raw = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_read_bytes)) catch |err|
        return std.fmt.allocPrint(arena, "error: cannot read {s}: {s}", .{ path, @errorName(err) });
    if (!args.contains("offset") and !args.contains("limit")) return raw;

    const offset: usize = @max(1, chat.numCount(args.get("offset")));
    const limit: usize = if (args.get("limit")) |v| chat.numCount(v) else std.math.maxInt(usize);
    var buf: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, raw, '\n');
    var n: usize = 0;
    var taken: usize = 0;
    while (lines.next()) |line| : (n += 1) {
        if (n + 1 < offset) continue;
        if (taken >= limit) break;
        try buf.appendSlice(arena, line);
        try buf.appendSlice(arena, "\n");
        taken += 1;
    }
    return buf.items;
}

fn toolWrite(io: Io, arena: std.mem.Allocator, args: std.json.ObjectMap) ![]u8 {
    const path = chat.str(args.get("path")) orelse return std.fmt.allocPrint(arena, "error: missing path", .{});
    const content = chat.str(args.get("content")) orelse "";
    if (std.fs.path.dirname(path)) |dir| std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = content }) catch |err|
        return std.fmt.allocPrint(arena, "error: cannot write {s}: {s}", .{ path, @errorName(err) });
    return std.fmt.allocPrint(arena, "wrote {d} bytes to {s}", .{ content.len, path });
}

fn toolEdit(io: Io, arena: std.mem.Allocator, args: std.json.ObjectMap) ![]u8 {
    const path = chat.str(args.get("path")) orelse return std.fmt.allocPrint(arena, "error: missing path", .{});
    const old = chat.str(args.get("old_string")) orelse return std.fmt.allocPrint(arena, "error: missing old_string", .{});
    const new = chat.str(args.get("new_string")) orelse return std.fmt.allocPrint(arena, "error: missing new_string", .{});
    const all = if (args.get("replace_all")) |v| v == .bool and v.bool else false;

    const raw = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_edit_bytes)) catch |err|
        return std.fmt.allocPrint(arena, "error: cannot read {s}: {s}", .{ path, @errorName(err) });
    if (old.len == 0) return std.fmt.allocPrint(arena, "error: old_string is empty", .{});

    const count = std.mem.count(u8, raw, old);
    if (count == 0) return std.fmt.allocPrint(arena, "error: old_string not found in {s}", .{path});
    if (count > 1 and !all) return std.fmt.allocPrint(arena, "error: old_string occurs {d} times in {s}; add context or set replace_all", .{ count, path });

    // The checks above leave either every occurrence replaced or, without
    // `all`, exactly one to replace, and one match is the loop below run once.
    var buf: std.ArrayList(u8) = .empty;
    var rest = raw;
    while (std.mem.indexOf(u8, rest, old)) |at| {
        try buf.appendSlice(arena, rest[0..at]);
        try buf.appendSlice(arena, new);
        rest = rest[at + old.len ..];
    }
    try buf.appendSlice(arena, rest);
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = buf.items }) catch |err|
        return std.fmt.allocPrint(arena, "error: cannot write {s}: {s}", .{ path, @errorName(err) });
    return std.fmt.allocPrint(arena, "replaced {d} occurrence(s) in {s}", .{ count, path });
}

fn toolSearch(io: Io, arena: std.mem.Allocator, args: std.json.ObjectMap) ![]u8 {
    const pattern = chat.str(args.get("pattern")) orelse return std.fmt.allocPrint(arena, "error: missing pattern", .{});
    const path = chat.str(args.get("path")) orelse ".";
    const glob = chat.str(args.get("glob"));
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ "rg", "--line-number", "--no-heading", "--color", "never", "--max-count", "200" });
    if (glob) |g| {
        try argv.appendSlice(arena, &.{ "--glob", g });
    }
    try argv.appendSlice(arena, &.{ "--", pattern, path });
    return runSearchTool(io, arena, argv.items, "ripgrep");
}

/// Structural search/rewrite through ast-grep. `rewrite` set means the change
/// is applied to every match (`--update-all`), so the next turn reads the
/// result back rather than trusting the tool's summary.
fn toolAst(io: Io, arena: std.mem.Allocator, args: std.json.ObjectMap) ![]u8 {
    const pattern = chat.str(args.get("pattern")) orelse return std.fmt.allocPrint(arena, "error: missing pattern", .{});
    const lang = chat.str(args.get("lang")) orelse return std.fmt.allocPrint(arena, "error: missing lang", .{});
    const path = chat.str(args.get("path")) orelse ".";
    const rewrite = chat.str(args.get("rewrite"));

    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ "ast-grep", "run", "--pattern", pattern, "--lang", lang });
    if (rewrite) |r| try argv.appendSlice(arena, &.{ "--rewrite", r, "--update-all" });
    try argv.appendSlice(arena, &.{ "--", path });

    return runSearchTool(io, arena, argv.items, "ast-grep");
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
/// way out, for the reason `runToolProcess` gives: a model-supplied `bash`
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
) !Captured {
    var spawned = try ToolChild.spawn(io, argv);
    // The group is published while the call runs, so an interrupt reaches it,
    // and cleared on the way out, so a later signal does not hit a dead group.
    watchToolGroup(spawned.pgid);
    defer {
        watchToolGroup(null);
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

    var draining: usize = files.len;
    var read_err: ?anyerror = null;
    var dropped: [2]bool = .{ false, false };
    while (draining > 0) {
        try batch.awaitConcurrent(io, timeout);
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
    return runTool(std.testing.io, arena, call);
}

test "the tool gutter stays one line whatever the model sent" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var buf: std.ArrayList(u8) = .empty;
    try writeGutterText(arena, &buf, "rg -n 'foo'\nnext line\u{1b}[31mred\xff");
    try std.testing.expectEqualStrings("rg -n 'foo'\\x0anext line\\x1b[31mred\u{fffd}", buf.items);
    try std.testing.expect(std.mem.indexOfScalar(u8, buf.items, '\n') == null);
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
    const output = try toolBash(std.testing.io, arena, args);
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
    try std.testing.expectEqual(max_bash_timeout_ms, bashTimeoutMs(@intCast(std.math.maxInt(u64))));
    try std.testing.expectEqual(max_bash_timeout_ms, bashTimeoutMs(max_bash_timeout_ms + 1));
    // Inside the ceiling it is what was asked for, and an absent one is the
    // tool's own default rather than the ceiling.
    try std.testing.expectEqual(@as(u64, 1000), bashTimeoutMs(1000));
    try std.testing.expectEqual(default_bash_timeout_ms, bashTimeoutMs(null));
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
    const out = try toolGit(std.testing.io, arena, args);
    try std.testing.expectEqualStrings("error: rev must not start with '-'", out);
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
        const out = try toolGit(std.testing.io, arena, .empty);
        try std.testing.expectEqualStrings("error: missing cmd", out);
    }
    {
        // The subcommand is what picks the git argv, so an unknown one has to
        // stop here rather than be handed to git.
        var args: std.json.ObjectMap = .empty;
        try args.put(arena, "cmd", .{ .string = "push" });
        try std.testing.expectEqualStrings(
            "error: unknown git cmd 'push'",
            try toolGit(std.testing.io, arena, args),
        );
    }
}

// The tool arguments are written by the model, so dispatch is the trust
// boundary: malformed JSON, a non-object payload, and an unrecognized name all

// subprocess.
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

// A tool call as the model produced it: the same mutable slices the frame
// parser fills in, so the dispatcher tests go through the real entry point.

test "a child that outruns the capture cap keeps its first bytes instead of failing" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cap: usize = 4096;
    // `std.process.run` answers this with `error.StreamTooLong` and no output at
    // all, which is what a chatty build or a broad ripgrep used to hand back.
    const noisy = try runCapped(std.testing.io, arena, &.{
        "/bin/sh", "-c", "head -c 200000 /dev/zero | tr '\\0' 'a'",
    }, cap, net.durationMs(30_000));
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
    }, cap, net.durationMs(30_000));
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
    }, cap, net.durationMs(30_000));
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
    }, cap, net.durationMs(30_000));
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

test "a capped tool call takes its process tree down with it" {
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
    const pid_path = try std.fs.path.join(arena, &.{ path_buf[0..n], "grandchild.pid" });

    // The shell exits at once; the grandchild holds the pipe open, so the read
    // only ends at the timeout, which is the path under test. `$!` and not
    // `$$`: inside a nested `sh -c` the latter is still the outer shell's pid,
    // which has already exited, so the check below would pass on a process
    // that was never running.
    const script = try std.fmt.allocPrint(arena, "sh -c 'sleep 30 & echo $! > {s}; wait' & exit 0", .{pid_path});
    try std.testing.expectError(error.Timeout, runCapped(io, arena, &.{ "/bin/sh", "-c", script }, 4096, net.durationMs(300)));

    const raw = tmp.dir.readFileAlloc(io, "grandchild.pid", arena, .limited(64)) catch return error.GrandchildNotReported;
    const pid = try std.fmt.parseInt(std.posix.pid_t, std.mem.trim(u8, raw, " \t\r\n"), 10);
    // The kill is delivered asynchronously and the orphan is reaped by init
    // afterwards, so "gone" is a short poll rather than an instant check.
    var attempt: usize = 0;
    while (attempt < 50) : (attempt += 1) {
        std.posix.kill(pid, .CONT) catch return;
        try io.sleep(.{ .nanoseconds = 20 * std.time.ns_per_ms }, .awake);
    }
    std.debug.print("grandchild {d} survived the tool call\n", .{pid});
    return error.GrandchildSurvived;
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

/// The two runners a tool subprocess can go through, named so the reaping
/// check below runs against both with one body.
const ToolRunner = enum {
    /// `runToolProcess`, behind the search and git tools.
    tool_process,
    /// `runCapped`, behind `bash`.
    capped,

    pub fn call(self: ToolRunner, arena: std.mem.Allocator, io: Io, argv: []const []const u8) anyerror!void {
        const timeout = net.durationMs(300);
        switch (self) {
            .tool_process => _ = try runToolProcess(io, arena, argv, 4096, 4096, timeout),
            .capped => _ = try runCapped(io, arena, argv, 4096, timeout),
        }
    }
};

/// Asserts that a runner took its whole process tree down with it. The command
/// backgrounds a grandchild that outlives the shell, writes that grandchild's
/// pid, and then runs past the timeout: without the group signal the grandchild
/// is still alive when the call returns, and every timed-out call leaked one.
/// `pid_name` names the file the grandchild reports itself in, so the two
/// runners leave separate marks and the message says which one leaked.
fn expectNoProcessSurvived(runner: ToolRunner, pid_name: []const u8) !void {
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
    // The grandchild holds the pipe open, so the read only ends when the
    // timeout fires, which is the path under test.
    const script = try std.fmt.allocPrint(arena,
        \\sh -c 'echo $$ > {s}; sleep 30' &
        \\sleep 30
    , .{pid_path});
    try std.testing.expectError(error.Timeout, runner.call(arena, io, &.{ "/bin/sh", "-c", script }));

    const raw = tmp.dir.readFileAlloc(io, pid_name, arena, .limited(64)) catch return error.GrandchildNotReported;
    const pid = try std.fmt.parseInt(std.posix.pid_t, std.mem.trim(u8, raw, " \t\r\n"), 10);
    // The kill is delivered asynchronously and the orphan is reaped by init
    // afterwards, so "gone" is a short poll rather than an instant check.
    var attempt: usize = 0;
    while (attempt < 50) : (attempt += 1) {
        std.posix.kill(pid, .CONT) catch return;
        try io.sleep(.{ .nanoseconds = 20 * std.time.ns_per_ms }, .awake);
    }
    std.debug.print("grandchild {d} survived {s}\n", .{ pid, @tagName(runner) });
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
    // SIGINT ends the run, and this run is the test binary.
    var before: std.posix.Sigaction = undefined;
    std.posix.sigaction(.INT, null, &before);
    forwardInterruptsToToolGroup();
    var after: std.posix.Sigaction = undefined;
    std.posix.sigaction(.INT, null, &after);
    std.posix.sigaction(.INT, &before, null);
    try std.testing.expect(after.handler.handler == onInterrupt);

    const Thread = std.Thread;
    const Call = struct {
        pub fn go(a: std.mem.Allocator, t: Io) void {
            // The call outlives nothing here: the handler kills its group, so
            // a hung call would hang the suite rather than fail it.
            _ = runToolProcess(t, a, &.{ "/bin/sh", "-c", "sleep 5" }, 4096, 4096, net.durationMs(3000)) catch {};
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

// A tool call must take its whole process tree down with it: without the group
// signal the grandchild is still alive when the call returns, and every

// A tool call must take its whole process tree down with it: without the group
// signal the grandchild is still alive when the call returns, and every
// timed-out call leaked one.
test "a tool call that times out leaves no process of its own behind" {
    try expectNoProcessSurvived(.tool_process, "grandchild.pid");
}

test "a tool call reports the exit status of the command it ran" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const res = try runToolProcess(std.testing.io, arena, &.{ "/bin/sh", "-c", "printf out; printf err 1>&2; exit 3" }, 4096, 4096, net.durationMs(10_000));
    try std.testing.expectEqualStrings("out", res.stdout);
    try std.testing.expectEqualStrings("err", res.stderr);
    try std.testing.expectEqual(@as(u8, 3), res.term.exited);
}

// `bash` goes through the capped runner, not the search runner, and it is the
// tool that starts builds, so it carries the same process-group kill: a command
// that backgrounds work and then outruns its deadline took the whole tree with
// it only where the search tools already did.
test "a bash call that times out leaves no process of its own behind" {
    try expectNoProcessSurvived(.capped, "bash_grandchild.pid");
}
