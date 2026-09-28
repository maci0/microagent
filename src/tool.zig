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
/// by line count instead, and says so only when the line count is what cut it.
pub const max_tool_output = 24 * 1024;

/// Ceiling on a file `read` returns whole. A source file is kilobytes, so the
/// cap is what keeps one `read` of a multi-gigabyte artifact out of the
/// conversation.
const max_read_bytes: usize = 4 * 1024 * 1024;
/// `edit` reads the file it rewrites, so it holds the larger of the two.
const max_edit_bytes: usize = 8 * 1024 * 1024;
/// A secret file is one key, not a document. Public because the diagnostic
/// `main` writes when a key file trips this cap names the ceiling.
pub const max_secret_bytes: usize = 4096;

/// The lines a tool appends after the output it captured, kept as constants so
/// the buffer it assembles is sized from the same text it writes. Each carries
/// its own leading newline; the newline is emitted separately when there is
/// output for it to separate. The truncation note is shared by every tool that
/// captures a subprocess, the exit note by `bash` alone, which is the only one
/// that reports an exit status.
const truncation_note = "\n[output truncated at the tool's cap]";
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
pub const max_bash_timeout_ms: u64 = 600_000;
/// What `bash` runs under when the model sends no `timeout_ms`. The two are
/// public because the tool schema in `main` states them to the model: a default
/// the schema spells as a literal is a second copy of this number, and the copy
/// on the wire is the one the model acts on.
pub const default_bash_timeout_ms: u64 = 120_000;

/// A tool deadline cut down to what is left of the run's time budget.
///
/// Without it the budget is a promise the tools do not keep: a `bash` call
/// with a two-minute timeout starts happily at second 779 of a 780-second
/// budget and the caller kills the run mid-command, which is what the budget
/// exists to prevent. `ceiling_ms` is null when the run set no budget, and the
/// floor is the caller's: nothing here stops a zero `wanted_ms`, and keeping one
/// out is what `requestedTimeoutMs` answering null for a zero, and a constant
/// timeout, do, because a zero would fail before the tool could even start.
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
            // Null inherits this process's environment, so every call site
            // passes the scrubbed copy the run builds once instead: a child
            // that inherited it has the provider key to print.
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
    return .{ .found = std.mem.trim(u8, chat.stripBom(raw), net.env_surrounding) };
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

/// How each delegated program is installed, per the platform that ships it.
/// A macOS machine has git and none of the other two: ripgrep and ast-grep are
/// not in the base system, so on a platform this release publishes for, the
/// binary is simply not there. The message names a way to install it rather
/// than leaving the operator to work out which of the names on their machine
/// is the one the tool wanted.
const ripgrep_install = "macOS: 'brew install ripgrep'; Debian/Ubuntu: 'apt-get install ripgrep'";
const ast_grep_install = "macOS: 'brew install ast-grep'; or 'cargo install ast-grep'";
const git_install = "macOS: 'brew install git' or the Xcode command line tools; Debian/Ubuntu: 'apt-get install git'";

/// A delegated binary this machine does not have, named as that rather than as
/// an error code.
///
/// The spawn failure for a program that is not on PATH is `FileNotFound`, and
/// formatted as an error name it reaches the model and the operator as
/// `error: ripgrep failed: FileNotFound`: no program to install, no way to
/// install it, and on a stock macOS nothing at all that tells the two apart
/// from a broken install. Every other failure keeps the shape the call site
/// already had, so a timeout is still a timeout.
fn missingProgram(
    arena: std.mem.Allocator,
    what: []const u8,
    install: []const u8,
    err: anyerror,
) ![]const u8 {
    return if (err == error.FileNotFound)
        std.fmt.allocPrint(arena, "error: {s} is not on PATH, so this tool cannot run: install it ({s})", .{ what, install })
    else
        std.fmt.allocPrint(arena, "error: {s} failed: {s}", .{ what, @errorName(err) });
}

/// A tool that delegates to a binary already on PATH: the caller builds the
/// argv, and the failure text, the empty result and the two output streams are
/// handled the same way for each of them.
fn runSearchTool(
    io: Io,
    arena: std.mem.Allocator,
    argv: []const []const u8,
    what: []const u8,
    install: []const u8,
    ceiling_ms: ?u64,
    environ_map: ?*const std.process.Environ.Map,
) ![]const u8 {
    // The cap drains rather than fails, for the reason `runCapped` gives: a
    // broad ripgrep over a large tree passed the capture limit and came back
    // as `error: StreamTooLong` with no output at all, so the model was told
    // the search had failed rather than that it had found too much.
    // Empty rather than undefined: a spawn that fails on its own never reaches
    // the drain, so it leaves the out-param untouched, and the failure below
    // reads it to say what the child printed before it did.
    var got: Partial = .{ .stdout = &.{}, .stderr = &.{}, .dropped = .{ false, false } };
    const res = runCapped(io, arena, argv, max_tool_output * 4, net.durationMs(boundedMs(tool_timeout_ms, ceiling_ms)), environ_map, &got) catch |err|
        return failedOutput(arena, got, try missingProgram(arena, what, install, err));
    if (res.stdout.len > 0) return withCaptureNote(arena, res.stdout, res.partial());
    // The cap drains either stream, so a stderr cut short is as much a prefix
    // of the warning as a stdout one is of the matches, and the marker is what
    // says so. Marking only the stream that usually wins leaves a tool that
    // writes its findings nowhere and its warnings to stderr unmarked.
    if (res.stderr.len > 0) return withCaptureNote(arena, res.stderr, res.partial());
    return std.fmt.allocPrint(arena, "(no matches)", .{});
}

/// The captured stream with a line saying that it is the beginning of a longer
/// output. A half-read match list reads as the whole one otherwise, and the
/// model narrows its next search against what it did not see.
fn withCaptureNote(arena: std.mem.Allocator, text: []const u8, got: Partial) ![]const u8 {
    if (!got.atCaptureLimit()) return text;
    return std.fmt.allocPrint(arena, "{s}{s}", .{ text, truncation_note });
}

/// What a tool says when its subprocess failed: everything the child wrote
/// before it did, then the failure under it.
///
/// The output is the point. A `git log` that timed out after printing the last
/// hundred commits, or a `bash` build that printed every error it had found and
/// then hung, reached the model as the error name alone, so the next turn read
/// that the command had produced nothing and re-ran it from scratch. The same
/// three tools, which disagree about this, all say it here now.
///
/// `reason` is already the whole line, so a caller that has a name and a number
/// to put in it formats both before the call.
fn failedOutput(
    arena: std.mem.Allocator,
    got: Partial,
    reason: []const u8,
) ![]const u8 {
    if (got.stdout.len == 0 and got.stderr.len == 0) return reason;
    var buf: std.ArrayList(u8) = .empty;
    try buf.ensureTotalCapacity(arena, got.stdout.len + got.stderr.len +
        truncation_note.len + reason.len + 2);
    if (got.stdout.len > 0) try buf.appendSlice(arena, got.stdout);
    if (got.stderr.len > 0) {
        if (buf.items.len > 0) try buf.appendSlice(arena, "\n");
        try buf.appendSlice(arena, got.stderr);
    }
    if (got.atCaptureLimit()) {
        if (buf.items.len > 0) try buf.appendSlice(arena, "\n");
        try buf.appendSlice(arena, truncation_note[1..]);
    }
    try buf.appendSlice(arena, "\n");
    try buf.appendSlice(arena, reason);
    return buf.items;
}

/// Lines of git output a call keeps when the model asks for no limit: a raw
/// `git log` in a big repository is thousands of lines of context nobody reads.
/// Public because the tool schema in `main` states it to the model, for the
/// reason `default_bash_timeout_ms` gives.
pub const git_default_limit: usize = 400;

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
fn toolGit(io: Io, arena: std.mem.Allocator, args: std.json.ObjectMap, ceiling_ms: ?u64, environ_map: ?*const std.process.Environ.Map) ![]const u8 {
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
        if (isCredentialPath(named)) return credentialRefusal(arena, .git, named, false);
        return std.fmt.allocPrint(arena, "error: rev must name a revision, not a file; use the path argument for a file (got '{s}')", .{
            chat.safeText(arena, r, 120),
        });
    };
    // The same hole without the colon. `git blame .env` and `git diff .env`
    // take the name as their single revision argument and print the file's
    // contents: blame one line at a time with its hash and author, diff as
    // the committed and working-tree text of every hunk. The `:(exclude)`
    // pathspecs below are arguments after the `--`, so they scope a revision
    // the model named and never a name it did not: the exclusion set this tool
    // relies on does not reach a rev that is a bare file, and the key came
    // back as a tool result either way.
    if (rev) |r| if (isCredentialPath(r)) return credentialRefusal(arena, .git, r, false);
    // `git show <rev> -- .env` prints a committed credentials file as a patch,
    // so the path gets the refusal `read` gives it rather than a git one.
    if (path) |p| if (isCredentialPath(p)) return credentialRefusal(arena, .git, p, false);

    const argv = gitArgv(arena, cmd, rev, path, limit) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.UnknownCmd => return std.fmt.allocPrint(arena, "error: unknown git cmd '{s}'", .{cmd}),
    };

    // The cap drains rather than fails, for the reason `runCapped` gives: the
    // default here is 400 lines, and 400 long diff lines pass the capture cap,
    // so a call the model asked to be trimmed came back as
    // `error: git diff failed: StreamTooLong` with no lines at all.
    // Empty rather than undefined, for the reason `runSearchTool` says: a spawn
    // that fails on its own never writes the out-param.
    var got: Partial = .{ .stdout = &.{}, .stderr = &.{}, .dropped = .{ false, false } };
    const res = runCapped(io, arena, argv, max_tool_output * 4, net.durationMs(boundedMs(tool_timeout_ms, ceiling_ms)), environ_map, &got) catch |err|
        return failedOutput(arena, got, try missingProgram(arena, try std.fmt.allocPrint(arena, "git {s}", .{cmd}), git_install, err));
    const text = if (res.stdout.len > 0) res.stdout else res.stderr;
    if (text.len == 0) return std.fmt.allocPrint(arena, "(git {s}: no output)", .{cmd});
    // The line cap below is the one git is cut by, and it only says so when it
    // is the one that cut. A capture the byte cap ended short of the line cap
    // is marked here for the reason `runSearchTool` marks one: a half-read
    // commit reads as the whole one otherwise, and the model narrows its next
    // `git log` against a history it never saw.
    return withCaptureNote(arena, try firstLines(arena, text, limit), res.partial());
}

/// The command line one `git` call runs, with the subcommand and every flag
/// fixed here rather than assembled by the model. Its own function because the
/// pathspecs below are the security property of the tool, and the only way to
/// hold one to that is to run its output against a repository with a committed
/// credential in it, which a test cannot do through the tool itself: the tool
/// spawns `git` in this process's working directory.
fn gitArgv(
    arena: std.mem.Allocator,
    cmd: []const u8,
    rev: ?[]const u8,
    path: ?[]const u8,
    limit: usize,
) error{ OutOfMemory, UnknownCmd }![]const []const u8 {
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
        return error.UnknownCmd;
    }
    try gitPathspecs(arena, &argv, cmd, path);
    return argv.items;
}

/// The `--` that ends the options and the pathspecs that follow it.
///
/// The refusal `toolGit` makes only covers a credential the model named. A
/// `git show HEAD` with no path prints the whole commit, and a `.env`, a `.pem`
/// or a `.secrets/` file that was ever committed comes back in it as a tool
/// result, which is re-sent to the provider on every later turn. The names come
/// from the same tables `search` and `ast` exclude by, so a credential is out of
/// the git tool's results as well as out of the ones it is asked for by name.
///
/// A `path` narrows that output, so for the two commands that print a file's
/// contents it joins the exclusion set rather than replacing it: a scoped call
/// is the ordinary one, and `{"cmd":"show","path":"."}` was getting the whole
/// tree, committed credentials and all. The two are a conjunction, so both are
/// appended.
///
/// `status`, `log` and `blame` get the model's path alone. `status` and `log`
/// print no file contents, and `git blame` takes exactly one file argument, so
/// an exclusion set beside it is `usage: git blame ... <file>` rather than a
/// filtered blame.
fn gitPathspecs(arena: std.mem.Allocator, argv: *std.ArrayList([]const u8), cmd: []const u8, path: ?[]const u8) !void {
    try argv.append(arena, "--");
    if (std.mem.eql(u8, cmd, "diff") or std.mem.eql(u8, cmd, "show")) {
        try argv.appendSlice(arena, &credential_pathspecs);
    }
    if (path) |p| try argv.append(arena, p);
}

/// The first `limit` lines, with a note when lines were dropped. A call that
/// kept every line hands back the capture itself: it is arena-owned, the caller
/// only reads it, and copying a cap's worth of git output per call bought
/// nothing.
fn firstLines(arena: std.mem.Allocator, text: []const u8, limit: usize) ![]const u8 {
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
    if (end == text.len) return text;
    return std.fmt.allocPrint(arena, "{s}... [output truncated at {d} lines]", .{ text[0..end], limit });
}

/// The one way into the tools below: the name and the arguments are the
/// model's, so the payload is parsed and checked for an object before any name
/// is compared, the gutter line is written, and only then is a name matched. A
/// payload that is not an object, or a name that is not one of the seven,
/// answers with an error string and no tool runs.
pub fn runTool(io: Io, arena: std.mem.Allocator, call: chat.ToolCall, ceiling_ms: ?u64, environ_map: ?*const std.process.Environ.Map) ![]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, arena, call.args.items, .{}) catch
        return std.fmt.allocPrint(arena, "error: tool arguments are not valid JSON", .{});
    const args = switch (parsed.value) {
        .object => |o| o,
        else => return std.fmt.allocPrint(arena, "error: tool arguments must be an object", .{}),
    };

    // The one place a tool name is a string. Past it the call is a variant, so
    // the switch below is exhaustive by the compiler: a tool added without a
    // handler here fails the build rather than answering `unknown tool` to a
    // model the schema had just advertised it to.
    const tool = chat.Tool.fromName(call.name) orelse return unknownTool(arena, call.name);
    noteToolCall(io, arena, tool, args);
    return switch (tool) {
        .bash => toolBash(io, arena, args, ceiling_ms, environ_map),
        .read => toolRead(io, arena, args),
        .write => toolWrite(io, arena, args),
        .edit => toolEdit(io, arena, args),
        .search => toolSearch(io, arena, args, ceiling_ms, environ_map),
        .ast => toolAst(io, arena, args, ceiling_ms, environ_map),
        .git => toolGit(io, arena, args, ceiling_ms, environ_map),
    };
}

/// What a name this program has no tool for gets back. The name is the model's
/// own bytes and reaches the prompt and a stderr gutter, so it is escaped here
/// the way every other untrusted value reaching a diagnostic is.
fn unknownTool(arena: std.mem.Allocator, name: []const u8) error{OutOfMemory}![]const u8 {
    return std.fmt.allocPrint(arena, "error: unknown tool '{s}'", .{chat.safeText(arena, name, 40)});
}

/// The gutter line, without the stream it is written to, so the one-line shape
/// is a value a test can hold rather than a stream it has to capture. Every
/// field is bounded, so the line fits a buffer of this length whatever the
/// model sent: the marker, the name, one space, the detail and the newline.
/// The name is a variant, so its budget is the widest tag rather than a number
/// a caller could pass past; the detail is the model's own bytes and is what
/// the second bound is for.
const gutter_line_max = 5 + 40 + 1 + 120 + 1;

/// A one-line tool gutter on stderr, the shape gauntlet recognizes. The detail
/// is the provider's own text and may carry a newline or an escape sequence,
/// either of which breaks the one-line-per-call shape a reader parses, so
/// control characters are written as their two-character escapes.
fn noteToolCall(io: Io, arena: std.mem.Allocator, tool: chat.Tool, args: std.json.ObjectMap) void {
    var buf: [gutter_line_max]u8 = undefined;
    net.writeErr(io, toolCallLine(arena, &buf, tool, args) catch return);
}

fn toolCallLine(arena: std.mem.Allocator, buf: []u8, tool: chat.Tool, args: std.json.ObjectMap) ![]const u8 {
    // The interesting argument is not the same one for every tool: a structural
    // search is identified by its pattern, a bash call by its command.
    const detail = if (tool == .ast)
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
        .{ tool.name(), chat.safeText(arena, detail, 120) },
    );
}

/// Bytes a terminal acts on rather than prints: the C0 controls, DEL, the C1
/// range, which UTF-8 spells as C2 80..9F, and every byte that is not part of a
/// valid UTF-8 sequence. A tool argument is whatever the model decided to send,
/// and the model decides that from files in the tree, so a repository can put
/// an escape sequence on the operator's screen through the gutter line, and a
/// provider can put a broken byte in an error body. A diagnostic note replaces
/// each control with a `.`, one byte for one byte, so a two-byte C1 sequence
/// becomes two dots; the model's own output on stdout is left alone, because
/// that is the answer the run was asked for. An allocation that fails yields no
/// text rather than the text unescaped, which is the input this exists to
/// remove.
///
/// A byte that is not text is shown as a dot rather than written through. The
/// body is the provider's own bytes, so a lone `0xff`, a continuation byte with
/// no lead, or the `\xe6\x97` half of a character the cap cut in two reach this
/// verbatim under a byte-at-a-time pass, and the terminal shows the run's
/// diagnostic as mojibake. `chat.safeText` writes U+FFFD for the same bytes and
/// `chat.writeJsonString` does the same in a request body; this keeps the
/// length the rest of the caller's assertions are written against, and a dot
/// is what this function already shows for a byte it cannot render. A whole
/// sequence is copied byte for byte, so the pass is a fixed point: what comes
/// out has no control and no invalid byte left in it for a second pass to find.
pub fn terminalSafe(arena: std.mem.Allocator, s: []const u8) []const u8 {
    const out = arena.alloc(u8, s.len) catch return s[0..0];
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (c < 0x80) {
            out[i] = if (c < 0x20 or c == 0x7f) '.' else c;
            i += 1;
            continue;
        }
        const len = chat.utf8SequenceLen(s, i);
        if (len == 0) {
            out[i] = '.';
            i += 1;
            continue;
        }
        @memcpy(out[i .. i + len], s[i .. i + len]);
        // A C1 control is a valid two-byte sequence, so the test above cannot
        // see it, and the lead byte alone does not say C1: C2 80..9F is the
        // range, and C2 A0..BF is U+00A0..U+00BF, which is text.
        if (len == 2 and c == 0xc2 and s[i + 1] <= 0x9f) {
            out[i] = '.';
            out[i + 1] = '.';
        }
        i += len;
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

fn toolBash(io: Io, arena: std.mem.Allocator, args: std.json.ObjectMap, ceiling_ms: ?u64, environ_map: ?*const std.process.Environ.Map) ![]const u8 {
    const command = chat.str(args.get("command")) orelse return std.fmt.allocPrint(arena, "error: missing command", .{});
    // `bash` is the one tool with no path argument to check, and it can read
    // every file the three guarded tools refuse: `cat .env` and
    // `git show HEAD -- .env` both come back whole, and a tool result is
    // re-sent to the provider on every later turn. So the same name check runs
    // over the command's own words.
    if (credentialInCommand(command)) |path| return credentialRefusal(arena, .bash, path, false);
    const timeout_ms: u64 = bashTimeoutMs(requestedTimeoutMs(args.get("timeout_ms")), ceiling_ms);
    const capture_limit = max_tool_output * 4;
    // A command that runs to its own timeout has usually already said what is
    // wrong: a build that printed every error before it hung is the case this
    // is for. Its output comes back with the reason, and a command that printed
    // nothing is the bare reason it always was.
    // Empty rather than undefined, for the reason `runSearchTool` gives: a
    // spawn that fails on its own never writes the out-param, and the failure
    // below reads it to say what the child printed before it did.
    var got: Partial = .{ .stdout = &.{}, .stderr = &.{}, .dropped = .{ false, false } };
    const res = runCapped(io, arena, &.{ "/bin/sh", "-c", command }, capture_limit, net.durationMs(timeout_ms), environ_map, &got) catch |err| switch (err) {
        error.Timeout => return failedOutput(arena, got, try std.fmt.allocPrint(arena, "error: command timed out after {d}ms", .{timeout_ms})),
        else => return failedOutput(arena, got, try std.fmt.allocPrint(arena, "error: {s}", .{@errorName(err)})),
    };
    // The captured size is known before the first append, so the buffer is
    // sized once rather than doubling its way up to `capture_limit` on each
    // stream, copying everything written so far at every step. The two
    // trailing notes are the only other bytes written to it; they are spelled
    // as constants so the reservation and the writes cannot drift apart.
    var buf: std.ArrayList(u8) = .empty;
    try buf.ensureTotalCapacity(arena, res.stdout.len + res.stderr.len +
        truncation_note.len + bash_exit_note.len + exit_status_max_digits);
    if (res.stdout.len > 0) try buf.appendSlice(arena, res.stdout);
    if (res.stderr.len > 0) {
        if (buf.items.len > 0) try buf.appendSlice(arena, "\n");
        try buf.appendSlice(arena, res.stderr);
    }
    // Output the model acts on is cut at the cap, so say so rather than letting
    // a half-read build log or diff read as the whole one.
    if (atCaptureLimit(res)) {
        if (buf.items.len > 0) try buf.appendSlice(arena, "\n");
        try buf.appendSlice(arena, truncation_note[1..]);
    }
    if (buf.items.len == 0) {
        var line: std.ArrayList(u8) = .empty;
        try line.appendSlice(arena, "(no output, exit ");
        try appendExitStatus(arena, &line, res.term);
        try line.appendSlice(arena, ")");
        return line.items;
    }
    if (res.term != .exited or res.term.exited != 0) {
        try buf.appendSlice(arena, bash_exit_note[0 .. bash_exit_note.len - 1]);
        try appendExitStatus(arena, &buf, res.term);
        try buf.appendSlice(arena, ")");
    }
    return buf.items;
}

/// The tag and, for a normal exit, the number: the tag alone says `exited`
/// without saying which code, so a model reading it cannot tell a failure from
/// a success. The no-output line and the trailing note are the same sentence,
/// so both are spelled here rather than in one of them.
fn appendExitStatus(arena: std.mem.Allocator, buf: *std.ArrayList(u8), term: std.process.Child.Term) !void {
    try buf.appendSlice(arena, @tagName(term));
    if (term == .exited) try buf.appendSlice(arena, try std.fmt.allocPrint(arena, " {d}", .{term.exited}));
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

/// The matches `search` takes from one file, as `--max-count`. A file with more
/// than this is cut at the count, and the cut is not marked in the result.
const search_max_matches_per_file: usize = 200;

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
    // directory the path only passes through, and `deploy/.env/prod` by a
    // directory the same exclusion set already hides from `search` and `git`.
    // dirname and basename are the target's own separator, so the walk is right
    // on the platforms this ships to and needs no second spelling. A trailing
    // separator is trimmed first, or the leaf basename comes back empty and the
    // name goes unchecked.
    //
    // The name rules run on every component too, and not only the leaf. None of
    // the globs in `credential_glob_table` carries a separator, so the backend
    // that applies them matches a basename at any depth: `!.env` covers
    // `deploy/.env/prod`, and `!*.pem` covers `deploy/prod.pem/notes`. The
    // directories are the same walk's other half, and applying one without the
    // other is a hole in the middle of it.
    var component: ?[]const u8 = std.mem.trimEnd(u8, path, &path_sep);
    while (component) |c| {
        const name = std.fs.path.basename(c);
        if (name.len != 0 and !std.mem.eql(u8, name, ".") and !std.mem.eql(u8, name, "..")) {
            for (credential_dirs) |dir| {
                if (name.len == dir.len and std.ascii.eqlIgnoreCase(name, dir)) return true;
            }
            if (isCredentialName(name)) return true;
        }
        component = std.fs.path.dirname(c);
    }
    return false;
}

/// The tools that change a file rather than report one, whatever else they can
/// do. The credential refusal names them because the advice a reading tool
/// gets is wrong for them: there is no reading of a key file that should be
/// going on, so the answer is the operator rather than another tool. `ast` is
/// in neither list on its own, because a search leaves the tree as it found it
/// and a rewrite does not; the caller says which it was.
fn isWriting(tool: chat.Tool) bool {
    return tool == .write or tool == .edit;
}

/// What a tool returns instead of a credential. It names the file, so a model
/// that asked for it knows which one was refused, and it says what to do
/// instead, because a bare error reads as a broken tool and gets retried.
/// `writes` is the caller's answer to "would this call have changed the file",
/// which the tool's name alone does not always carry.
fn credentialRefusal(arena: std.mem.Allocator, tool: chat.Tool, path: []const u8, writes: bool) error{OutOfMemory}![]const u8 {
    // The advice has to be the one that is true for the tool that was refused.
    // The `bash` branch sends the model to the operator because `bash` runs
    // the same name check over its own words: telling a model that `read` just
    // refused to run the command that fetches the bytes walks it into the same
    // refusal one line later. A tool that would have overwritten the file says
    // the same thing, because there is no reading of it anyone should be doing.
    // `writes` covers `ast --rewrite`, which passes the path to `--update-all`
    // whatever the globs exclude, and is a write by the only test that matters.
    const advice = if (tool == .bash)
        "`bash` does not read it either. Ask the operator for the value you need rather than printing a key."
    else if (writes or isWriting(tool))
        "No tool rewrites a credentials file. Ask the operator to make that change rather than replacing a key with a guess."
    else
        "Run the command that needs the key through `bash`, and do not print it.";
    return std.fmt.allocPrint(
        arena,
        "refused: {s} is a credentials file. `{s}` does not return one, because the result " ++
            "is re-sent to the provider on every later turn. {s}",
        .{ path, tool.name(), advice },
    );
}

fn toolRead(io: Io, arena: std.mem.Allocator, args: std.json.ObjectMap) ![]const u8 {
    const path = chat.str(args.get("path")) orelse return std.fmt.allocPrint(arena, "error: missing path", .{});
    if (isCredentialPath(path)) return try credentialRefusal(arena, .read, path, false);
    if (!args.contains("offset") and !args.contains("limit"))
        return std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_read_bytes)) catch |err|
            return readFailed(arena, path, err);

    // Both counts are ceilings, so zero is one line rather than no lines, for
    // the reason `gitLineLimit` gives: a `limit` of `"3"` read as a limit of
    // zero once, and the call came back empty and the model read that as a file
    // with nothing in it. The same rule on the read side, the same answer. An
    // offset past the end of the file is a count too, and the cap the cast can
    // reach is a line no file here has.
    const offset: usize = @max(1, std.math.cast(usize, countArg(args.get("offset")) orelse 1) orelse std.math.maxInt(usize));
    const limit: usize = @max(1, std.math.cast(usize, countArg(args.get("limit")) orelse std.math.maxInt(u64)) orelse std.math.maxInt(usize));
    return readLines(io, arena, path, offset, limit);
}

/// What a `read` says when the file is not there, is a directory, or cannot be
/// opened: the same words whichever way the bytes were going to be fetched.
fn readFailed(arena: std.mem.Allocator, path: []const u8, err: anyerror) []const u8 {
    return std.fmt.allocPrint(arena, "error: cannot read {s}: {s}", .{ path, @errorName(err) }) catch
        "error: cannot read the file";
}

/// Bytes one read of a streamed file brings in.
const read_chunk = 8 * 1024;

/// The lines of a file in `[offset, offset + limit)`, each with the newline the
/// model reads them back with.
///
/// The file is streamed rather than read whole: a `read` of fifty lines out of
/// a four-megabyte artifact would otherwise pull all four megabytes into the
/// turn's memory, copy fifty lines out of them, and keep reading to the end
/// of the file to find out there was nothing more. This reads up to the last
/// line asked for and stops. A file whose last line has no newline is still a
/// line, and gets the newline the split-based reader gave it.
fn readLines(io: Io, arena: std.mem.Allocator, path: []const u8, offset: usize, limit: usize) ![]const u8 {
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

fn toolWrite(io: Io, arena: std.mem.Allocator, args: std.json.ObjectMap) ![]const u8 {
    const path = chat.str(args.get("path")) orelse return std.fmt.allocPrint(arena, "error: missing path", .{});
    // The same refusal `read` makes. A run that cannot read a key file has no
    // business rewriting one either: `write` replaces the file whole, so a
    // model that gets the path from a file in the tree and the content from a
    // guess replaces the operator's working key with a placeholder, and the
    // next run of the agent cannot authenticate at all.
    if (isCredentialPath(path)) return try credentialRefusal(arena, .write, path, true);
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
    var cur_buf: [2 * std.fs.max_path_bytes]u8 = undefined;
    var next_buf: [2 * std.fs.max_path_bytes]u8 = undefined;
    const target = try net.resolveSymlinkTarget(io, dir, path, &link_buf, &cur_buf, &next_buf);
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

fn toolEdit(io: Io, arena: std.mem.Allocator, args: std.json.ObjectMap) ![]const u8 {
    const path = chat.str(args.get("path")) orelse return std.fmt.allocPrint(arena, "error: missing path", .{});
    // The same refusal `read` makes. An edit reads the whole file to find its
    // match, and the operator's key is the one file in a tree where a match the
    // model guessed at and a rewrite of the value beside it is damage nobody
    // asked for.
    if (isCredentialPath(path)) return try credentialRefusal(arena, .edit, path, true);
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
    // A match the check above cannot see: it proves `new` cannot re-create
    // `old` inside itself, and not that `old` is gone from the file. The
    // rewrite is `P ++ new ++ S`, so the bytes before the span are still there
    // and `new` can match against them: `aab` with `ab` -> `b` is the small
    // case, where the first run leaves `ab`, which matches again and takes a
    // byte off the file with every duplicate. A dedent is the same shape with
    // real code, where a line of five spaces replaced by four re-matches on the
    // space in front of it and walks one column left per duplicate.
    //
    // The rewritten buffer is the only place the question can be asked of, and
    // asking it of anything else is what left the hole: both branches of the
    // loop above replace every occurrence they reach, so a match still in here
    // is one this rewrite created, and the next run of this call would find it
    // and apply again.
    if (std.mem.indexOf(u8, buf.items, old) != null) {
        return std.fmt.allocPrint(arena, "error: replacing old_string with new_string would leave old_string matchable in {s}, so a second run of this edit would apply again; include more context in old_string", .{path});
    }
    writeFileAtomic(io, std.Io.Dir.cwd(), path, buf.items) catch |err|
        return std.fmt.allocPrint(arena, "error: cannot write {s}: {s}", .{ path, @errorName(err) });
    return std.fmt.allocPrint(arena, "replaced {d} occurrence(s) in {s}", .{ count, path });
}

/// Text search through ripgrep. `--max-count` bounds the matches per file, and
/// nothing marks a result cut by it: `withCaptureNote` reports only the byte
/// cap, so this is a bound that makes an unbounded answer unlikely rather than
/// one the run announces.
fn toolSearch(io: Io, arena: std.mem.Allocator, args: std.json.ObjectMap, ceiling_ms: ?u64, environ_map: ?*const std.process.Environ.Map) ![]const u8 {
    const pattern = chat.str(args.get("pattern")) orelse return std.fmt.allocPrint(arena, "error: missing pattern", .{});
    const path = chat.str(args.get("path")) orelse ".";
    // The globs below are traversal rules: ripgrep applies them while it walks,
    // and a file named as the search path is read whatever they say, so
    // `{"path": ".env"}` came back with the key's line in it. The name is
    // checked here instead, which is what the globs and this test between them
    // make true.
    if (isCredentialPath(path)) return try credentialRefusal(arena, .search, path, false);
    const glob = chat.str(args.get("glob"));
    var max_count: [16]u8 = undefined;
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ "rg", "--line-number", "--no-heading", "--color", "never", "--max-count", std.fmt.bufPrint(&max_count, "{d}", .{search_max_matches_per_file}) catch unreachable, "--glob-case-insensitive" });
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
    return runSearchTool(io, arena, argv.items, "ripgrep", ripgrep_install, ceiling_ms, environ_map);
}

/// Structural search/rewrite through ast-grep. `rewrite` set means the change
/// is applied to every match (`--update-all`), so the next turn reads the
/// result back rather than trusting the tool's summary.
fn toolAst(io: Io, arena: std.mem.Allocator, args: std.json.ObjectMap, ceiling_ms: ?u64, environ_map: ?*const std.process.Environ.Map) ![]const u8 {
    const pattern = chat.str(args.get("pattern")) orelse return std.fmt.allocPrint(arena, "error: missing pattern", .{});
    const lang = chat.str(args.get("lang")) orelse return std.fmt.allocPrint(arena, "error: missing lang", .{});
    const path = chat.str(args.get("path")) orelse ".";
    // The same hole `search` has: `--globs` filters the walk, and a file named
    // as the path is rewritten whatever they say, which is a key's line in a
    // match and a keystore in the diff of the turn after. `rewrite` is read
    // first because it is what separates the two: a search leaves the file as
    // it found it, and a rewrite passes it to `--update-all`, so the refusal
    // for the second is the one that says no tool rewrites a key.
    const rewrite = chat.str(args.get("rewrite"));
    if (isCredentialPath(path)) return try credentialRefusal(arena, .ast, path, rewrite != null);
    if (rewrite) |r| {
        if (try astRewriteRefusal(arena, pattern, r)) |why| return why;
    }

    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ "ast-grep", "run", "--pattern", pattern, "--lang", lang });
    try argv.ensureUnusedCapacity(arena, credential_globs.len * 2);
    for (credential_globs) |g| {
        argv.appendAssumeCapacity("--globs");
        argv.appendAssumeCapacity(g);
    }
    if (rewrite) |r| try argv.appendSlice(arena, &.{ "--rewrite", r, "--update-all" });
    try argv.appendSlice(arena, &.{ "--", path });

    return runSearchTool(io, arena, argv.items, "ast-grep", ast_grep_install, ceiling_ms, environ_map);
}

/// The fewest characters of literal text a pattern must carry for its
/// replacement to be read against it. `=` and `(` are punctuation every
/// replacement is full of, so a skeleton that short says nothing about whether
/// the pattern can match its own output; `return` and `foo()` are the text the
/// match is anchored on, so a replacement carrying one is a replacement the
/// pattern can match again.
const ast_skeleton_min = 3;

/// The literal text of `pattern`: every byte that is not part of a
/// metavariable, with the whitespace at either end trimmed away. Null when
/// the pattern carries no literal text, which is a pattern of metavariables
/// alone and matches every node there is.
///
/// A metavariable is `$` followed by a name, `$A` / `$_` / `$A1`. A `$` with
/// nothing name-shaped after it is punctuation the language spelled, and is
/// literal text like any other.
fn patternSkeleton(arena: std.mem.Allocator, pattern: []const u8) !?[]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < pattern.len) {
        const name_at = i + 1;
        if (pattern[i] == '$' and name_at < pattern.len and
            (std.ascii.isAlphabetic(pattern[name_at]) or pattern[name_at] == '_'))
        {
            i = name_at;
            while (i < pattern.len and (std.ascii.isAlphanumeric(pattern[i]) or pattern[i] == '_')) i += 1;
            continue;
        }
        try out.append(arena, pattern[i]);
        i += 1;
    }
    const literal = std.mem.trim(u8, out.items, " \t\r\n");
    if (literal.len == 0) return null;
    return literal;
}

/// Why a rewrite of `pattern` to `rewrite` is refused, or null when it is
/// applied. A message the model reads, in the shape `toolEdit` refuses in.
///
/// A rewrite is a call the model can issue twice, exactly as an edit is: a
/// turn cut before its result reached the model, a re-read to check the change
/// landed, a retry after a transport fault. A `write` and an `edit` are safe on
/// the second run because the first removed the text the second looks for. An
/// ast-grep rewrite has no such guarantee, because the pattern is matched on
/// syntax and the replacement is written back as source: a replacement that
/// still matches its own pattern matches it again, and `return $X` rewritten to
/// `return [$X]` gives `return [[1]]`, then `return [[[1]]]]`, one wrapper
/// deeper per duplicate, on every match in the tree. Nothing in the second run
/// can tell an applied rewrite from a first one, because the two leave the same
/// bytes.
///
/// Three shapes are settled here. A replacement spelled as the pattern is a
/// no-op. A pattern of metavariables alone matches every node, so it matches
/// whatever its own replacement produced. A replacement that still carries the
/// pattern's literal text is a replacement the pattern is anchored on, so the
/// next run finds the first run's output and rewrites it again.
///
/// The last is evidence, not a proof: a replacement that re-matches through a
/// form the pattern's literal text does not spell is still applied, and a
/// skeleton too short to anchor a match is not read against the replacement at
/// all. The model reads the tree back on the next turn rather than taking the
/// tool's word, which is what a rewrite has always asked of it.
fn astRewriteRefusal(arena: std.mem.Allocator, pattern: []const u8, rewrite: []const u8) !?[]const u8 {
    if (std.mem.eql(u8, pattern, rewrite))
        return try std.fmt.allocPrint(arena, "no change: rewrite is the pattern itself ({s})", .{rewrite});
    const skeleton = (try patternSkeleton(arena, pattern)) orelse
        return try std.fmt.allocPrint(arena, "error: the pattern {s} is metavariables alone, so it matches whatever its own rewrite produced and a second run of this rewrite would apply again; match on the literal text around the metavariable, or use `edit`", .{pattern});
    if (skeleton.len >= ast_skeleton_min and std.mem.indexOf(u8, rewrite, skeleton) != null)
        return try std.fmt.allocPrint(arena, "error: rewriting {s} to {s} leaves the text the pattern is anchored on ({s}) in the output, so a second run of this rewrite would match the first one's own result and apply again; rewrite to text the pattern no longer matches, or use `edit`", .{ pattern, rewrite, skeleton });
    return null;
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

    fn partial(self: Captured) Partial {
        return .{ .stdout = self.stdout, .stderr = self.stderr, .dropped = self.dropped };
    }
};

/// What a child had written by the time `runCapped` failed, for a caller that
/// reports the failure together with whatever the command managed to print.
///
/// It is the same bytes a finished call returns, and the same note about the cap
/// having been reached, so a timeout does not cost the model the output that
/// led to it: a build that ran for the whole timeout and printed every error
/// it had found reaches the model whole, because those errors are the reason
/// the next command is worth running.
///
/// The exit status is deliberately absent. A call that failed never learned one:
/// a child killed on the deadline has a signal this program sent, and a child
/// that closed its pipes and was still running has nothing at all, so a
/// `.{ .exited = 0 }` standing in here would read as a command that succeeded.
pub const Partial = struct {
    stdout: []u8,
    stderr: []u8,
    dropped: [2]bool,

    /// Whether either stream carries a byte the cap cut off.
    pub fn atCaptureLimit(self: Partial) bool {
        return self.dropped[0] or self.dropped[1];
    }
};

/// Runs `argv` and keeps the first `limit` bytes of each stream.
///
/// `std.process.run` answers `error.StreamTooLong` and throws away everything it
/// had read, so a chatty build, a ripgrep over a large tree or a `git show` of a
/// big file reached the model as a bare error with no output at all. Here the
/// bytes past the cap are drained and dropped instead: the child still runs to
/// its own end, so the exit status and the timeout keep meaning what they did.
///
/// `partial` receives those same bytes when the call fails, which is the one
/// case the drain above read them for: a timeout, a read that failed, a child
/// that could not be waited for. It is written only on the error paths, and a
/// caller that passes null loses nothing but the ability to show them.
///
/// The child leads its own process group and the whole group is signalled on the
/// way out: a model-supplied `bash`
/// command that backgrounds work and exits leaves that work holding a port, a
/// build cache or a database lock for every later turn of the run and for
/// whatever starts next, and a timeout that fires while the shell is still there
/// leaves the compiler or test server it launched running without it.
fn runCapped(
    io: Io,
    arena: std.mem.Allocator,
    argv: []const []const u8,
    limit: usize,
    timeout: Io.Timeout,
    environ_map: ?*const std.process.Environ.Map,
    partial: ?*Partial,
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
    var dropped: [2]bool = .{ false, false };
    // The arena owns the bytes, so handing them to the caller on the way out of
    // a failure is a copy of two slice headers rather than a move, and the
    // caller's arena is the one that outlives this call either way.
    errdefer if (partial) |p| {
        p.* = .{ .stdout = out[0].items, .stderr = out[1].items, .dropped = dropped };
    };

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

    const term = try waitBounded(io, child, spawned.pgid, deadline);
    if (read_err) |err| return err;
    return .{ .stdout = out[0].items, .stderr = out[1].items, .term = term, .dropped = dropped };
}

/// How often the waiter re-reads the clock while it waits for a child. The
/// deadline is checked this often rather than slept through, because the two
/// things racing here are the child's exit and the deadline, and only the
/// second one is a sleep: a child that exits on its own must not have to wait
/// out the rest of its timeout before the turn carries on.
const wait_poll_interval: Io.Clock.Duration = .{
    .raw = .{ .nanoseconds = 5 * std.time.ns_per_ms },
    .clock = .awake,
};

/// The child's exit status, or `error.Timeout` once `deadline` passes.
///
/// Both pipes are at end of stream by the time this runs, and that says
/// nothing about the child: `sh -c 'exec 1>&- 2>&-; sleep 600'` closes them
/// immediately and keeps running, so the drain above finishes in milliseconds
/// and a bare `child.wait` then blocks for however long the command decides,
/// with the tool timeout this call was given never consulted again. The whole
/// run hangs behind one tool call, and the group reap on the way out of
/// `runCapped` never fires because the call has not returned.
///
/// So the wait is raced against the deadline. The wait itself has no timeout
/// in this API, so it runs as a task and a second task signals the group when
/// the deadline passes; the signal is what unblocks the wait, and the caller
/// reports the timeout the same way a timeout during the drain does. A child
/// that exits first sets `exited` and the signalling task stops, so an ordinary
/// command is not held to the poll interval or to its own timeout.
fn waitBounded(
    io: Io,
    child: *std.process.Child,
    pgid: std.posix.pid_t,
    deadline: Io.Timeout,
) !std.process.Child.Term {
    // No deadline means an unbounded wait is what was asked for, and there is
    // nothing to race it against.
    const opening = deadline.toDurationFromNow(io) orelse return child.wait(io);
    // A deadline already spent is answered before anything is spawned: the
    // drain uses the whole of the timeout, so reaching here with none left is
    // the drain's own timeout, and the child is about to be reaped either way.
    if (opening.raw.nanoseconds <= 0) return error.Timeout;

    const Waiting = struct {
        child: *std.process.Child,
        io: Io,
        pgid: std.posix.pid_t,
        deadline: Io.Timeout,
        term: std.process.Child.Term = .{ .exited = 0 },
        wait_err: ?anyerror = null,
        exited: std.atomic.Value(bool) = .init(false),
        /// Set by the signalling task, and only when it actually signals. The
        /// wait returns either way, and the two answers are different: a child
        /// that exited on its own has a status worth reporting, and a child the
        /// deadline killed has the signal this program sent it.
        timed_out: std.atomic.Value(bool) = .init(false),

        fn waitForExit(self: *@This()) void {
            if (self.child.wait(self.io)) |t| {
                self.term = t;
            } else |err| {
                self.wait_err = err;
            }
            self.exited.store(true, .release);
        }

        fn signalAtDeadline(self: *@This()) void {
            while (!self.exited.load(.acquire)) {
                const left = self.deadline.toDurationFromNow(self.io) orelse return;
                if (left.raw.nanoseconds <= 0) break;
                const slice: Io.Clock.Duration = .{
                    .raw = .{ .nanoseconds = @min(left.raw.nanoseconds, wait_poll_interval.raw.nanoseconds) },
                    .clock = .awake,
                };
                // A poll that cannot sleep falls out to the signal below rather
                // than back out of this task. Returning here left the wait task
                // blocked in `child.wait` for as long as the child chose to run,
                // which is the unbounded wait the deadline exists to remove: a
                // command that closed its pipes and slept would have held the
                // whole run past its tool timeout, and the reap in `runCapped`
                // never fired because this call had not returned.
                slice.sleep(self.io) catch break;
            }
            // A child that already exited needs no signal, and one that has
            // not is what this task exists to bound. The group goes rather than
            // the single process: a command that closed its pipes may have
            // backgrounded the work it was asked to do, and that work is what
            // the timeout was for.
            if (self.exited.load(.acquire)) return;
            self.timed_out.store(true, .release);
            signalGroup(self.pgid);
        }
    };

    var waiting: Waiting = .{ .child = child, .io = io, .pgid = pgid, .deadline = deadline };
    var group: Io.Group = .init;
    // Both tasks are joined before this returns, so the child is reaped and
    // nothing is left holding its process group.
    defer group.cancel(io);
    group.concurrent(io, Waiting.waitForExit, .{&waiting}) catch |err| switch (err) {
        // Without concurrency there is no way to race the two, and a bare wait
        // is the hang this exists to remove, so the call fails loudly rather
        // than blocking on a child the timeout was meant to bound.
        error.ConcurrencyUnavailable => return error.NoConcurrency,
        else => |e| return e,
    };
    group.concurrent(io, Waiting.signalAtDeadline, .{&waiting}) catch |err| switch (err) {
        error.ConcurrencyUnavailable => return error.NoConcurrency,
        else => |e| return e,
    };
    // The join is allowed to be cancelled, and the two answers the tasks set
    // are asked for first: a task that did run has something to say, and a
    // cancelation delivered to this wait is also delivered to the drain above,
    // which propagates it rather than swallowing it.
    var join_err: ?anyerror = null;
    group.await(io) catch |err| {
        join_err = err;
    };
    if (waiting.wait_err) |err| return err;
    // The kill is this program's own, so it is reported as the timeout it is
    // rather than as a signal the command did not choose for itself.
    if (waiting.timed_out.load(.acquire)) return error.Timeout;
    // A join that failed leaves `term` at the `.{ .exited = 0 }` it was
    // initialised to, which reads as a command that exited cleanly. Swallowing
    // the error here reported a cancelled, killed or never-finished child as
    // the success its zero status spells. The child is signalled and reaped by
    // the caller on the way out of `runCapped` either way, so failing here costs
    // the run nothing.
    if (join_err) |err| return err;
    return waiting.term;
}

/// True when a stream filled the cap with bytes still arriving, so the captured
/// bytes are the beginning of the output and not all of it.
pub fn atCaptureLimit(captured: Captured) bool {
    return captured.partial().atCaptureLimit();
}

/// One tool result as the model reads it: capped, cut on a code point
/// boundary, and marked when bytes were dropped. Without the marker a
/// truncated file or a truncated test log is indistinguishable from a complete
/// one, and the agent reasons about output it never saw.
///
/// The first number in the marker is the cap, not the length that survived the
/// cut: `clamp` backs up to the last whole character, so a result whose
/// `max_tool_output`-th byte lands inside one keeps up to three bytes fewer, and
/// naming the shorter length told the model the cut was at a place it was not.
pub fn toolResult(arena: std.mem.Allocator, output: []const u8) ![]const u8 {
    const kept = chat.clamp(output, max_tool_output);
    if (kept.len == output.len) return kept;
    return std.fmt.allocPrint(arena, "{s}\n... [tool output truncated at {d} of {d} bytes]", .{
        kept, max_tool_output, output.len,
    });
}

/// A tool call through the argument text the model sends, on the test io, with
/// no run budget and this process's environment. It is the entry point the
/// tests drive, so a tool's real dispatch path is the one under test.
pub fn dispatch(arena: std.mem.Allocator, name: []const u8, args: []const u8) ![]const u8 {
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

// A ranged read frames arbitrary file bytes into lines, and the file is
// whatever the model reached for: a minified bundle with no newline in four
// megabytes, a lockfile, a binary blob with NULs, a file whose last line has
// no newline. The framing is a cursor moved by hand across 8 KB reads, so the
// properties a fuzzer can see are that a range comes back as the same bytes the
// whole-file split gives, and that every line it hands back ends in a newline
// whatever the file held. `expectedLines` is the oracle: it is the split-based
// reader this replaced, written out in full above, and the two disagreeing is
// the bug the fuzzer is here to find.
//
// `std.testing.fuzz` runs this corpus on every `zig build test`, and through
// the fuzzer's mutations when the test binary is built in fuzz mode.
const read_lines_corpus = [_][]const u8{
    "",
    "\n",
    "\n\n\n",
    "a",
    "one\ntwo\nthree\n",
    "one\ntwo\nthree",
    "one\r\ntwo\r\n",
    "\r\n",
    "a\n\nb\n",
    "no newline anywhere",
    "\x00\n\x00\x00",
    "head\n" ++ "z" ** (read_chunk - 5) ++ "\ntail",
    "head\n" ++ "z" ** (read_chunk - 4) ++ "\ntail",
    "head\n" ++ "z" ** (read_chunk - 3) ++ "\ntail",
    "head\n" ++ "z" ** (read_chunk * 2 + 1) ++ "\ntail\n",
    "head\n" ++ "z" ** (read_chunk - 1) ++ "\n" ++ "y" ** (read_chunk - 1) ++ "\n",
    ("line\n" ** 2000),
    "caf\u{00e9}\n\u{65e5}\u{672c}\u{8a9e}\n\u{1f680}\n",
    "\xff\xfe\n\xc3\n",
    " {\"a\":1}\n {\"b\":2}\n",
    "\n\n\n\n\n\n\n\n\n\nleading blanks",
    "trailing\n\n\n\n\n\n\n",
};

test "a fuzzed ranged read frames the file the same way the split-based reader did" {
    try std.testing.fuzz({}, fuzzReadLines, .{ .corpus = &read_lines_corpus });
}

/// The ranges one fuzzed file is read over. The cursor arithmetic goes wrong at
/// the edges of a range rather than in the middle of one, so every read covers
/// the first line, a limit that stops inside the file, a limit of zero, a range
/// that starts past the last line, and one that reaches for everything left.
const read_lines_ranges = [_][2]usize{
    .{ 1, 1 },
    .{ 1, 3 },
    .{ 2, 2 },
    .{ 3, 1 },
    .{ 1, 0 },
    .{ 0, 5 },
    .{ 9, 4 },
    .{ 1, 1_000 },
};

fn fuzzReadLines(_: void, smith: *std.testing.Smith) !void {
    const gpa = std.testing.allocator;
    // Wide enough that a line can straddle the read boundary in both
    // directions, and well under `max_read_bytes`, so the cap the loop checks
    // is never the reason a range comes back short.
    var scratch: [16 * 1024]u8 = undefined;
    const text: []const u8 = if (smith.in) |seed| seed else scratch[0..smith.slice(&scratch)];

    var state = std.heap.ArenaAllocator.init(gpa);
    defer state.deinit();
    const arena = state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    const path = try std.fs.path.join(arena, &.{ dir_path, "fuzz.txt" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "fuzz.txt", .data = text });

    for (read_lines_ranges) |range| {
        const offset = range[0];
        const limit = range[1];
        var range_arena = std.heap.ArenaAllocator.init(arena);
        defer range_arena.deinit();
        const got = try readLines(std.testing.io, range_arena.allocator(), path, offset, limit);
        const want = try expectedLines(arena, text, offset, limit);
        try std.testing.expectEqualStrings(want, got);

        // Whatever the file held, the range is whole lines: a last line with
        // no newline of its own comes back with one, because that newline is
        // what ends it for the model.
        if (got.len > 0) try std.testing.expect(std.mem.endsWith(u8, got, "\n"));
    }
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
        try toolCallLine(arena, &buf, .bash, args),
    );

    // The argument named depends on the tool, and an argument that is not text
    // is not printed as one.
    const cases = [_]struct { tool: chat.Tool, key: []const u8, detail: []const u8 }{
        .{ .tool = .ast, .key = "pattern", .detail = "fn main" },
        .{ .tool = .search, .key = "pattern", .detail = "TODO" },
        .{ .tool = .read, .key = "path", .detail = "src/main.zig" },
        .{ .tool = .bash, .key = "command", .detail = "ls -la" },
    };
    for (cases) |c| {
        var one: std.json.ObjectMap = .empty;
        try one.put(arena, c.key, .{ .string = c.detail });
        try std.testing.expectEqualStrings(
            try std.fmt.allocPrint(arena, "\u{23fa} {s} {s}\n", .{ c.tool.name(), c.detail }),
            try toolCallLine(arena, &buf, c.tool, one),
        );

        // A number where the name is would have been read as the detail, and
        // the line says the tool with nothing after it instead.
        var numbered: std.json.ObjectMap = .empty;
        try numbered.put(arena, c.key, .{ .integer = 7 });
        try std.testing.expectEqualStrings(
            try std.fmt.allocPrint(arena, "\u{23fa} {s} \n", .{c.tool.name()}),
            try toolCallLine(arena, &buf, c.tool, numbered),
        );
    }

    // A name is a variant, so it is bounded by construction: the longest tag
    // has to fit the budget the line is sized for, and every tool has to fit
    // beside a full-budget detail. Only the detail is the model's own bytes,
    // so only the detail is cut, and the line still ends exactly once.
    var long_args: std.json.ObjectMap = .empty;
    try long_args.put(arena, "command", .{ .string = "日" ** 300 });
    for (chat.tools()) |tool| {
        try std.testing.expect(tool.name().len <= 40);
        const long_line = try toolCallLine(arena, &buf, tool, long_args);
        try std.testing.expect(long_line.len <= gutter_line_max);
        try std.testing.expect(std.unicode.utf8ValidateSlice(long_line));
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, long_line, "\n"));
    }
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
    //
    // A name the run has no tool for never reaches the gutter: it is refused
    // before anything is dispatched, and the refusal is the line that has to
    // stay one printable line, since it quotes the name back at the model and
    // on stderr.
    const line = if (chat.Tool.fromName(name)) |tool| blk: {
        var buf: [gutter_line_max]u8 = undefined;
        break :blk try toolCallLine(arena, &buf, tool, args);
    } else try unknownTool(arena, name);
    try std.testing.expect(line.len <= gutter_line_max + 32);
    try std.testing.expect(std.unicode.utf8ValidateSlice(line));
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

test "a cut inside a character still names the cap it was cut at" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Filler to put a three-byte character across the cap, so the cut has to
    // back up past it and the kept length is below the cap it applied.
    var raw: [max_tool_output + 8]u8 = undefined;
    @memset(raw[0 .. max_tool_output - 1], 'x');
    @memcpy(raw[max_tool_output - 1 ..][0..3], "\u{20ac}");
    raw[max_tool_output + 2] = 'z';

    const cut = try toolResult(arena, &raw);
    try std.testing.expectEqual(max_tool_output - 1, chat.clamp(&raw, max_tool_output).len);
    const want = try std.fmt.allocPrint(arena, "truncated at {d} of {d} bytes]", .{ max_tool_output, raw.len });
    try std.testing.expect(std.mem.endsWith(u8, cut, want));
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

    // Bytes that are not text are dots rather than written through, so an
    // error body the provider spelled with a broken sequence reaches the
    // screen as a mark and not as mojibake. Every one of these is a byte a
    // provider or a cap can really produce: a body that is not UTF-8 at all,
    // a continuation byte with no lead, the two-byte half of a character the
    // response cap cut, and the lone lead byte a body ends on.
    const cases = [_]struct { raw: []const u8, want: []const u8 }{
        .{ .raw = "\xff\xfe", .want = ".." },
        .{ .raw = "a\x80b", .want = "a.b" },
        .{ .raw = "\xe6\x97", .want = ".." },
        .{ .raw = "\xf0\x9f", .want = ".." },
        .{ .raw = "rate \xff limit", .want = "rate . limit" },
        // A whole character is copied, however wide, and the text around an
        // invalid byte is not moved: the pass is byte for byte.
        .{ .raw = "caf\u{00e9} \u{65e5}\u{8a00} \u{1f600}", .want = "caf\u{00e9} \u{65e5}\u{8a00} \u{1f600}" },
        // C2 A0 is U+00A0, which is text, where C2 9B is a control.
        .{ .raw = "\u{00a0}\u{009b}", .want = "\u{00a0}.." },
    };
    inline for (cases) |c| try std.testing.expectEqualStrings(c.want, terminalSafe(arena, c.raw));
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
    while (i < safe.len) {
        const c = safe[i];
        try std.testing.expect(c >= 0x20 and c != 0x7f);
        if (c < 0x80) {
            i += 1;
            continue;
        }
        // Every byte above ASCII left in the result is the whole of a valid
        // sequence, and none of it is a C1 control, so a body the provider
        // spelled with a broken sequence has no mojibake on the screen.
        const len = chat.utf8SequenceLen(safe, i);
        try std.testing.expect(len > 0);
        try std.testing.expect(!(len == 2 and c == 0xc2 and safe[i + 1] <= 0x9f));
        i += len;
    }

    // A byte that was already text is left exactly as it was, so the provider
    // cannot have text rewritten around a sequence it wanted hidden. A byte
    // that was not text is the one thing this pass does replace, and it is
    // replaced by a dot rather than dropped, so the fields still line up.
    i = 0;
    while (i < text.len) {
        const c = text[i];
        if (c < 0x80) {
            if (c >= 0x20 and c != 0x7f) try std.testing.expectEqual(c, safe[i]);
            i += 1;
            continue;
        }
        const len = chat.utf8SequenceLen(text, i);
        if (len == 0) {
            try std.testing.expectEqual('.', safe[i]);
            i += 1;
            continue;
        }
        if (len == 2 and c == 0xc2 and text[i + 1] <= 0x9f) {
            try std.testing.expectEqualStrings("..", safe[i..][0..2]);
            i += len;
            continue;
        }
        try std.testing.expectEqualStrings(text[i..][0..len], safe[i..][0..len]);
        i += len;
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
        // A name at any depth, not only at the leaf. None of the globs in
        // `credential_globs` carries a separator, so the backend that applies
        // them matches a basename wherever it sits, and a path the walk
        // answered about the leaf alone let these through while `search` and
        // `git` were already refusing them.
        "deploy/.env/prod",
        "deploy/.ssh/config",
        "home/user/.netrc/config",
        "home/user/.aws/credentials/db.ini",
        "certs/server.pem/notes",
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

    const refused = try credentialRefusal(arena, .read, "/home/someone/.secrets/openrouter", false);
    try std.testing.expect(std.mem.indexOf(u8, refused, "/home/someone/.secrets/openrouter") != null);
    try std.testing.expect(std.mem.indexOf(u8, refused, "bash") != null);
    // Not a single byte of a key is in the message, only the path that names it.
    try std.testing.expect(std.mem.indexOf(u8, refused, "sk-") == null);

    // The same tool name, one argument apart: a search leaves the file alone
    // and a rewrite passes it to `--update-all`, so the advice cannot be the
    // one that sends the model to another tool.
    const search = try credentialRefusal(arena, .ast, "/home/someone/.env", false);
    const rewritten = try credentialRefusal(arena, .ast, "/home/someone/.env", true);
    try std.testing.expect(std.mem.indexOf(u8, search, "bash") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "rewrites a credentials file") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "bash") == null);
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

test "output cut by the capture cap is marked even when no line was dropped" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const whole: Partial = .{ .stdout = "", .stderr = "", .dropped = .{ false, false } };
    // Fewer lines than the limit, so the line count cut nothing, and nothing
    // was dropped, so the bytes are the whole output.
    try std.testing.expectEqualStrings("1\n2\n", try withCaptureNote(arena, try firstLines(arena, "1\n2\n", 400), whole));

    const cut: Partial = .{ .stdout = "", .stderr = "", .dropped = .{ true, false } };
    try std.testing.expectEqualStrings("1\n2\n\n[output truncated at the tool's cap]", try withCaptureNote(arena, try firstLines(arena, "1\n2\n", 400), cut));
    // Both caps can land on one result, and each says which one it was.
    const both: Partial = .{ .stdout = "", .stderr = "", .dropped = .{ false, true } };
    try std.testing.expectEqualStrings("1\n... [output truncated at 1 lines]\n[output truncated at the tool's cap]", try withCaptureNote(arena, try firstLines(arena, "1\n2\n", 1), both));
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

// The same hole with no colon in it. `git blame .env` and `git diff .env` take
// the name as their one revision argument and print the file: blame line by
// line with its hash and author, diff as the committed and working-tree text
// of every hunk. The `:(exclude)` pathspecs are arguments after the `--`, so
// they scope a revision the model named and never a name it did not, and a
// committed `.env` came back whole as a tool result.
test "git tool refuses a rev that is a bare credentials filename" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    for ([_][]const u8{ "blame", "diff", "show" }) |cmd| {
        var args: std.json.ObjectMap = .empty;
        try args.put(arena, "cmd", .{ .string = cmd });
        try args.put(arena, "rev", .{ .string = ".env" });
        const out = try toolGit(std.testing.io, arena, args, null, null);
        try std.testing.expect(std.mem.startsWith(u8, out, "refused: .env is a credentials file"));
    }
    // A directory is the same argument, and `git blame ~/.ssh` lists its files.
    for ([_][]const u8{ ".secrets/openrouter", ".ssh/id_ed25519" }) |named| {
        var args: std.json.ObjectMap = .empty;
        try args.put(arena, "cmd", .{ .string = "blame" });
        try args.put(arena, "rev", .{ .string = named });
        const out = try toolGit(std.testing.io, arena, args, null, null);
        try std.testing.expect(std.mem.startsWith(u8, out, "refused: "));
    }
    // A revision is not a file, and the tool has to keep answering for those.
    var head: std.json.ObjectMap = .empty;
    try head.put(arena, "cmd", .{ .string = "diff" });
    try head.put(arena, "rev", .{ .string = "HEAD~3" });
    const shown = try toolGit(std.testing.io, arena, head, null, null);
    try std.testing.expect(!std.mem.startsWith(u8, shown, "refused:"));
    try std.testing.expect(!std.mem.startsWith(u8, shown, "error: rev"));
}

// The credential exclusions and the model's `path` are a conjunction, not a
// choice: a scoped call is the ordinary one, so `{"cmd":"show","path":"."}`
// must not hand back a committed `.env` line by line. The repo is real and
// the assertion is on git's own output, because the shape of the pathspec is
// only worth anything if git honors it.
test "a scoped git call still leaves the committed credentials out" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const marker = "sk-live-do-not-ship";
    const committed = try std.fmt.allocPrint(arena, "API_KEY={s}\n", .{marker});
    const edited = try std.fmt.allocPrint(arena, "API_KEY={s}\nROTATED=1\n", .{marker});
    try tmp.dir.createDirPath(io, "src");
    try tmp.dir.createDirPath(io, "deploy");
    try tmp.dir.writeFile(io, .{ .sub_path = ".env", .data = committed });
    try tmp.dir.writeFile(io, .{ .sub_path = "deploy/server.pem", .data = try std.fmt.allocPrint(arena, "KEY={s}\n", .{marker}) });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/main.zig", .data = "pub const x = 1;\n" });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(io, &root_buf)];

    // `git -C` keeps the test out of whatever directory the runner started in.
    for ([_][]const []const u8{
        &.{ "git", "-C", root, "init", "-q" },
        &.{ "git", "-C", root, "config", "user.email", "a@b.c" },
        &.{ "git", "-C", root, "config", "user.name", "test" },
        &.{ "git", "-C", root, "add", "-A" },
        &.{ "git", "-C", root, "commit", "-qm", "x" },
    }) |argv| {
        const res = try runCapped(io, arena, argv, 1 << 20, net.durationMs(30_000), null, null);
        if (res.term != .exited or res.term.exited != 0) {
            std.debug.print("git setup failed: {s}\n", .{res.stderr});
            return error.TestUnexpectedResult;
        }
    }
    // A credential committed and then rotated, so both `show` (the commit) and
    // `diff` (the working tree against it) have the marker to leak.
    try tmp.dir.writeFile(io, .{ .sub_path = ".env", .data = edited });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/main.zig", .data = "pub const x = 2;\n" });

    // The same argv `toolGit` builds, so the test fails if the pathspec set
    // and the caller's `path` stop being both passed.
    for ([_][]const u8{ "show", "diff" }) |cmd| {
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(arena, &.{ "git", "-C", root, "--no-pager" });
        try argv.appendSlice(arena, &.{ cmd, "--no-color" });
        try argv.append(arena, "HEAD");
        try gitPathspecs(arena, &argv, cmd, ".");
        const res = try runCapped(io, arena, argv.items, 1 << 20, net.durationMs(30_000), null, null);
        if (std.mem.indexOf(u8, res.stdout, marker) != null) {
            std.debug.print("git {s} with a path leaked a committed credential\n", .{cmd});
            return error.TestUnexpectedResult;
        }
        // The control: the ordinary source file is still in the patch, so a
        // guard that emptied every result would fail here instead of passing.
        if (std.mem.indexOf(u8, res.stdout, "pub const x") == null) {
            std.debug.print("git {s} with a path returned nothing for src/main.zig\n", .{cmd});
            return error.TestUnexpectedResult;
        }
    }
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

// The exclusions the git tool appends are the only thing between a committed
// credential and the provider, because a tool result is re-sent on every later
// turn. `git show HEAD -- .` prints the whole commit exactly as the pathless
// call does, so the exclusions have to travel with a path rather than replace
// it, and asserting on the argv would not say whether git honors them there.
// The argv the tool builds is run against a repository holding one committed
// credential and one ordinary file: the credential must not come back, and the
// ordinary file must, or the pathspec has narrowed the call into silence.
test "a git path does not switch the credential exclusions off" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, ".secrets");
    try tmp.dir.createDirPath(io, "src");
    const needle = "sk-committed-do-not-print";
    try tmp.dir.writeFile(io, .{ .sub_path = ".secrets/openrouter", .data = needle });
    try tmp.dir.writeFile(io, .{ .sub_path = ".env", .data = needle });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/main.zig", .data = "marker\n" });

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = path_buf[0..try tmp.dir.realPath(io, &path_buf)];

    // A real repository, so git's own pathspec handling is what is under test.
    // The tool spawns `git` in this process's working directory, so the fixture
    // is built through the same runner and every call below carries `-C root`
    // where the tool would have inherited the directory instead.
    const script = try std.fmt.allocPrint(arena,
        \\git -C '{s}' init -q && git -C '{s}' add -A && git -C '{s}' -c user.email=t@t -c user.name=t commit -qm base
    , .{ root, root, root });
    const setup = [_][]const u8{ "/bin/sh", "-c", script };
    const made = try runCapped(io, arena, &setup, 1 << 20, net.durationMs(60_000), null, null);
    if (made.term != .exited or made.term.exited != 0) {
        std.debug.print("could not build the fixture repository: {s}\n", .{made.stderr});
        return error.TestUnexpectedResult;
    }
    // `git diff` with no rev is the working tree against the index, and a
    // freshly committed tree has nothing in it. The ordinary file is changed
    // after the commit so `diff` has a patch to print and cannot pass here by
    // returning nothing at all.
    try tmp.dir.writeFile(io, .{ .sub_path = "src/main.zig", .data = "marker\nchanged\n" });

    for ([_][]const u8{ "show", "diff" }) |cmd| {
        for ([_]?[]const u8{ null, ".", root }) |path| {
            const res = try runCapped(io, arena, try gitIn(arena, root, cmd, null, path), 1 << 20, net.durationMs(60_000), null, null);
            const text = try arena.dupe(u8, res.stdout);
            if (std.mem.indexOf(u8, text, needle) != null) {
                std.debug.print("git {s} with path '{s}' leaked the committed key\n", .{ cmd, path orelse "<none>" });
                return error.TestUnexpectedResult;
            }
            // The control: the ordinary file is in the same tree and the same
            // patch, so exclusions that emptied the result would fail here.
            if (path != null and std.mem.indexOf(u8, text, "main.zig") == null) {
                std.debug.print("git {s} with path '{s}' lost the ordinary file\n", .{ cmd, path orelse "<none>" });
                return error.TestUnexpectedResult;
            }
        }
    }

    // The three that print no file contents keep the command lines they were
    // given. A credential named as `blame`'s path is refused by `toolGit`
    // before it gets here, and the other two print a name or a subject rather
    // than a byte of one, so an exclusion on them buys nothing.
    for ([_][]const u8{ "status", "log", "blame" }) |cmd| {
        const argv = try gitArgv(arena, cmd, null, "src/main.zig", git_default_limit);
        for (argv) |word| {
            if (std.mem.startsWith(u8, word, ":(exclude)")) {
                std.debug.print("git {s} was given credential exclusions it does not need\n", .{cmd});
                return error.TestUnexpectedResult;
            }
        }
    }
}

/// The argv `gitArgv` builds, pointed at `root` the way the tool's own
/// subprocess would have been by its working directory. The tool runs `git`
/// where the process is, and a test cannot move the process, so the one
/// difference is a `-C` ahead of everything the tool chose.
fn gitIn(
    arena: std.mem.Allocator,
    root: []const u8,
    cmd: []const u8,
    rev: ?[]const u8,
    path: ?[]const u8,
) error{ OutOfMemory, UnknownCmd }![]const []const u8 {
    const inner = try gitArgv(arena, cmd, rev, path, git_default_limit);
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ "git", "-C" });
    try argv.append(arena, root);
    try argv.appendSlice(arena, inner[1..]);
    return argv.items;
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
    // `std.process.run` answers this with `error.StreamTooLong` and no output
    // at all, which is what a chatty build or a broad ripgrep would hand back.
    const noisy = try runCapped(std.testing.io, arena, &.{
        "/bin/sh", "-c", "head -c 200000 /dev/zero | tr '\\0' 'a'",
    }, cap, net.durationMs(30_000), null, null);
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
    }, cap, net.durationMs(30_000), null, null);
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
    }, cap, net.durationMs(30_000), null, null);
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
    }, cap, net.durationMs(30_000), null, null);
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

/// A temporary directory the process is standing in, so a tool that resolves
/// paths against the working directory edits the file the test wrote. The
/// directory is removed and the previous directory restored on deinit.
const CwdFixture = struct {
    state: std.heap.ArenaAllocator,
    tmp: std.testing.TmpDir,
    cwd_buf: [std.fs.max_path_bytes]u8 = undefined,
    previous: []const u8,

    fn init() !CwdFixture {
        var self: CwdFixture = .{
            .state = std.heap.ArenaAllocator.init(std.testing.allocator),
            .tmp = std.testing.tmpDir(.{}),
            .previous = undefined,
        };
        errdefer self.state.deinit();
        self.previous = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", self.state.allocator());
        const here = self.cwd_buf[0..try self.tmp.dir.realPath(std.testing.io, &self.cwd_buf)];
        try std.process.setCurrentPath(std.testing.io, here);
        return self;
    }

    fn deinit(self: *CwdFixture) void {
        std.process.setCurrentPath(std.testing.io, self.previous) catch {};
        self.tmp.cleanup();
        self.state.deinit();
    }

    fn arena(self: *CwdFixture) std.mem.Allocator {
        return self.state.allocator();
    }
};

// The edit tool rewrites a file the model named, and the one-match case has to
// come out the same whether or not `replace_all` was asked for: the count
// checks above refuse an ambiguous match, so both paths have exactly the
// occurrences they are going to replace. The tool resolves paths against the
// process directory, so the test runs from the temp directory it edits.
test "edit replaces one match, or every match when asked" {
    var cwd = try CwdFixture.init();
    defer cwd.deinit();
    const arena = cwd.arena();

    var args: std.json.ObjectMap = .empty;
    try args.put(arena, "path", .{ .string = "a.txt" });
    try args.put(arena, "old_string", .{ .string = "x" });
    try args.put(arena, "new_string", .{ .string = "y" });

    try cwd.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "a.txt", .data = "a x b" });
    try std.testing.expectEqualStrings("replaced 1 occurrence(s) in a.txt", try toolEdit(std.testing.io, arena, args));
    try std.testing.expectEqualStrings("a y b", try cwd.tmp.dir.readFileAlloc(std.testing.io, "a.txt", arena, .limited(64)));

    // An ambiguous match is refused rather than guessed at, so the file the
    // model was shown is still the file on disk.
    try cwd.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "a.txt", .data = "x and x" });
    try std.testing.expect(std.mem.startsWith(u8, try toolEdit(std.testing.io, arena, args), "error: old_string occurs 2 times"));
    try std.testing.expectEqualStrings("x and x", try cwd.tmp.dir.readFileAlloc(std.testing.io, "a.txt", arena, .limited(64)));

    try args.put(arena, "replace_all", .{ .bool = true });
    try std.testing.expectEqualStrings("replaced 2 occurrence(s) in a.txt", try toolEdit(std.testing.io, arena, args));
    try std.testing.expectEqualStrings("y and y", try cwd.tmp.dir.readFileAlloc(std.testing.io, "a.txt", arena, .limited(64)));
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
    var cwd = try CwdFixture.init();
    defer cwd.deinit();
    const arena = cwd.arena();

    var args: std.json.ObjectMap = .empty;
    try args.put(arena, "path", .{ .string = "a.txt" });

    // The ordinary edit: the second run finds no text to replace, so it is
    // refused and the file keeps the first run's bytes.
    try args.put(arena, "old_string", .{ .string = "x" });
    try args.put(arena, "new_string", .{ .string = "y" });
    try cwd.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "a.txt", .data = "a x b" });
    try std.testing.expectEqualStrings("replaced 1 occurrence(s) in a.txt", try toolEdit(std.testing.io, arena, args));
    try std.testing.expect(std.mem.startsWith(u8, try toolEdit(std.testing.io, arena, args), "error: old_string not found"));
    try std.testing.expectEqualStrings("a y b", try cwd.tmp.dir.readFileAlloc(std.testing.io, "a.txt", arena, .limited(64)));

    // The nesting shape, refused on the first run rather than applied and
    // nested again on the second.
    try args.put(arena, "old_string", .{ .string = "x" });
    try args.put(arena, "new_string", .{ .string = "xy" });
    try cwd.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "a.txt", .data = "a x b" });
    try std.testing.expect(std.mem.startsWith(u8, try toolEdit(std.testing.io, arena, args), "error: new_string contains old_string"));
    try std.testing.expectEqualStrings("a x b", try cwd.tmp.dir.readFileAlloc(std.testing.io, "a.txt", arena, .limited(64)));

    // Replacing text with itself writes nothing, so a duplicate of it is not a
    // second write either.
    try args.put(arena, "old_string", .{ .string = "x" });
    try args.put(arena, "new_string", .{ .string = "x" });
    try std.testing.expect(std.mem.startsWith(u8, try toolEdit(std.testing.io, arena, args), "no change:"));
    try std.testing.expectEqualStrings("a x b", try cwd.tmp.dir.readFileAlloc(std.testing.io, "a.txt", arena, .limited(64)));

    // The boundary shape: the replacement holds no copy of the text it
    // replaces, so the check above passes it, and the match re-forms against
    // the byte in front of the span instead. `aab` with `ab` -> `b` leaves `ab`,
    // which the second run matches and shortens to `b`. Refused on the first
    // run, so a duplicate of this call is refused with it.
    try args.put(arena, "old_string", .{ .string = "ab" });
    try args.put(arena, "new_string", .{ .string = "b" });
    try cwd.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "a.txt", .data = "aab" });
    try std.testing.expect(std.mem.startsWith(u8, try toolEdit(std.testing.io, arena, args), "error: replacing old_string"));
    try std.testing.expectEqualStrings("aab", try cwd.tmp.dir.readFileAlloc(std.testing.io, "a.txt", arena, .limited(64)));

    // The same shape on a line, which is the one a dedent arrives in: the
    // match reaches into the space in front of the statement, so the first run
    // leaves a line that still matches and every duplicate takes one more space
    // off it.
    try args.put(arena, "old_string", .{ .string = "  f();" });
    try args.put(arena, "new_string", .{ .string = " f();" });
    try args.put(arena, "replace_all", .{ .bool = true });
    try cwd.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "a.txt", .data = "if x:\n   f();\n" });
    try std.testing.expect(std.mem.startsWith(u8, try toolEdit(std.testing.io, arena, args), "error: replacing old_string"));
    try std.testing.expectEqualStrings("if x:\n   f();\n", try cwd.tmp.dir.readFileAlloc(std.testing.io, "a.txt", arena, .limited(64)));
}

// An ast-grep rewrite has the same re-run question an edit does and the same
// answer, refused before anything is written rather than settled afterwards,
// because an applied rewrite and an already-applied one leave the same bytes.
// The wrapper shape is the one that does damage: `return $X` to `return [$X]`
// rewrites the same line again on the second run and gives `return [[1]]`,
// then a third bracket per run after that.
test "an ast rewrite whose output still matches its pattern is refused" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The replacement carries the text the pattern is anchored on, so the
    // pattern can match the first run's own output.
    const wrapped = (try astRewriteRefusal(arena, "return $X", "return [$X]")).?;
    try std.testing.expect(std.mem.indexOf(u8, wrapped, "would match the first one's own result") != null);
    try std.testing.expect((try astRewriteRefusal(arena, "return $X", "raise ValueError($X)")) == null);
    // A pattern with a keyword in it and a replacement with a different one:
    // the second run finds nothing, which is the shape that is allowed.
    try std.testing.expect((try astRewriteRefusal(arena, "print($A)", "log($A)")) == null);
    // The rename of a call, and a swap of two names inside a call.
    try std.testing.expect((try astRewriteRefusal(arena, "foo($A)", "bar($A)")) == null);
    try std.testing.expect((try astRewriteRefusal(arena, "kw($A, $B)", "kw($B, $A)")) == null);
    // A replacement spelled as the pattern writes the file with its own bytes.
    try std.testing.expect((try astRewriteRefusal(arena, "foo($A)", "foo($A)")).?.len > 0);
    // Metavariables alone match every node, so they match whatever they were
    // rewritten to, and there is no literal text to read the replacement
    // against either.
    try std.testing.expect((try astRewriteRefusal(arena, "$A", "[$A]")).?.len > 0);
    // A skeleton too short to anchor a match says nothing about whether the
    // replacement re-matches, so it is not read against it.
    try std.testing.expect((try astRewriteRefusal(arena, "($A)", "($A) == ($A)")) == null);
    // Punctuation the language spelled, rather than the start of a
    // metavariable, is literal text and is kept; a `$` with a name after it is
    // a metavariable, and is the one that leaves nothing behind.
    try std.testing.expectEqualStrings("a$", (try patternSkeleton(arena, "a$")).?);
    try std.testing.expectEqualStrings("a", (try patternSkeleton(arena, "a$b")).?);
    try std.testing.expectEqualStrings("()", (try patternSkeleton(arena, "($A)")).?);
    try std.testing.expect((try patternSkeleton(arena, "$A $B")) == null);
}

// The refusal above, through the tool the model actually calls, and before the
// backend is spawned: the file the run would have grown is left as it was.
test "ast refuses the rewrite through the tool, not after it ran" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const arena = state.allocator();
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const source = "def f():\n    return 1\n";
    try tmp.dir.writeFile(io, .{ .sub_path = "a.py", .data = source });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(io, &root_buf)];

    const refused = try dispatch(arena, "ast", try std.fmt.allocPrint(
        arena,
        "{{\"pattern\":\"return $X\",\"lang\":\"python\",\"path\":\"{s}\",\"rewrite\":\"return [$X]\"}}",
        .{root},
    ));
    try std.testing.expect(std.mem.startsWith(u8, refused, "error: rewriting return $X to return [$X]"));
    try std.testing.expectEqualStrings(source, try tmp.dir.readFileAlloc(io, "a.py", arena, .limited(256)));

    // The rename goes through, and the second run of it finds nothing to
    // rename, so the bytes are the first run's.
    const rename = try std.fmt.allocPrint(
        arena,
        "{{\"pattern\":\"return $X\",\"lang\":\"python\",\"path\":\"{s}\",\"rewrite\":\"raise $X\"}}",
        .{root},
    );
    _ = try dispatch(arena, "ast", rename);
    const once = try tmp.dir.readFileAlloc(io, "a.py", arena, .limited(256));
    try std.testing.expectEqualStrings("def f():\n    raise 1\n", once);
    _ = try dispatch(arena, "ast", rename);
    try std.testing.expectEqualStrings(once, try tmp.dir.readFileAlloc(io, "a.py", arena, .limited(256)));
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
    try std.testing.expectError(error.Timeout, runCapped(io, arena, &.{ "/bin/sh", "-c", script }, 4096, net.durationMs(300), null, null));

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
            _ = runCapped(t, a, &.{ "/bin/sh", "-c", "sleep 5" }, 4096, net.durationMs(3000), null, null) catch {};
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
    const res = try runCapped(std.testing.io, arena, &.{ "/bin/sh", "-c", "printf out; printf err 1>&2; exit 3" }, 4096, net.durationMs(10_000), null, null);
    try std.testing.expectEqualStrings("out", res.stdout);
    try std.testing.expectEqualStrings("err", res.stderr);
    try std.testing.expectEqual(@as(u8, 3), res.term.exited);
}

/// How far short of its deadline a timeout is allowed to come back, measured
/// between the timer the wait is armed on and the clock the elapsed time is
/// read off. Well under the smallest budget the assertion below is about, and
/// three orders of magnitude above the skew it covers.
const deadline_slack_ms: u64 = 10;

/// How far past its budget a timed-out call may still be running. Several
/// budgets wide, so a loaded host passes, and far below the seconds a wait that
/// answers on something other than the clock would take.
const deadline_overshoot_ms: u64 = 5_000;

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
    try std.testing.expectError(error.Timeout, runCapped(io, arena, &.{ "/bin/sh", "-c", script }, 4096, net.durationMs(budget_ms), null, null));
    const spent = Io.Timestamp.now(io, .awake).nanoseconds - started;
    // The deadline is what ended the call, so it did not return before it: an
    // error raised on the way in is a different fault wearing this one's name,
    // and a lower bound is what tells the two apart. The bound carries
    // `deadline_slack_ms` because the wait is armed on a timer and the elapsed
    // time is read off a clock, and the two are not the same reading: a
    // machine that has been suspended, or one whose timer fires on the first
    // tick of a coarser one, hands back a deadline a hair before it is due.
    try std.testing.expect(spent + deadline_slack_ms * std.time.ns_per_ms >= budget_ms * std.time.ns_per_ms);
    // And the other side of the same claim: the wait is bounded by the clock,
    // so a signalling task that fires long past the deadline spends the run's
    // budget on a call the budget had already given up on. The margin is
    // several budgets wide because a loaded host is slow rather than wrong,
    // but a task that comes back seconds late is not a host being loaded.
    try std.testing.expect(spent < deadline_overshoot_ms * std.time.ns_per_ms);
}

test "a tool call that times out leaves no process of its own behind" {
    try expectNoProcessSurvived();
}

// The bytes a command printed before the deadline are the reason the next
// command is worth running, and the error path has to carry them: a build that
// printed every error and then hung must not reach the model as one line
// naming a timeout, which reads as a turn that produced nothing at all.
test "a command that times out keeps what it printed before the deadline" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const script = "printf 'compiling a.c\\n'; printf 'a.c:1: error: nope\\n' 1>&2; sleep 30";
    var got: Partial = undefined;
    try std.testing.expectError(
        error.Timeout,
        runCapped(io, arena, &.{ "/bin/sh", "-c", script }, 4096, net.durationMs(300), null, &got),
    );
    try std.testing.expectEqualStrings("compiling a.c\n", got.stdout);
    try std.testing.expectEqualStrings("a.c:1: error: nope\n", got.stderr);
    try std.testing.expect(!got.atCaptureLimit());

    // The tool result carries both streams and names the failure under them.
    const out = try bashCall(arena, script, 300);
    try std.testing.expect(std.mem.indexOf(u8, out, "compiling a.c") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "a.c:1: error: nope") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "command timed out after 300ms") != null);

    // A command that printed nothing before the deadline is still the bare
    // failure line, with no empty body in front of it.
    try std.testing.expectEqualStrings(
        "error: command timed out after 300ms",
        try bashCall(arena, "sleep 30", 300),
    );
}

/// The tool result for one `bash` call, through the argument object the model
/// sends rather than through the struct the tool reads.
fn bashCall(arena: std.mem.Allocator, command: []const u8, timeout_ms: i64) ![]const u8 {
    const keys = [_][]const u8{ "command", "timeout_ms" };
    const values = [_]std.json.Value{ .{ .string = command }, .{ .integer = timeout_ms } };
    const args = std.json.ObjectMap.init(arena, &keys, &values) catch return error.TestUnexpectedResult;
    return toolBash(std.testing.io, arena, args, null, null);
}

// `bash` is the tool with no path argument, so it is the one a model reaches a
// credentials file through: `read` refuses the file, `bash: cat` does not, and
// what `cat` returns is a tool result the provider reads again on every later
// turn. The check is over the command's words rather than a parsed AST, so it
// is pinned on the words it does and does not claim.
// The exit status is the only thing a silent command leaves behind, so the
// no-output line has to carry the number the trailing note carries. Spelling it
// from the tag alone reports `exited` for a command that failed and one that
// succeeded alike, which is the one distinction the model cannot get anywhere
// else.
test "a bash command with no output still says which exit it was" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqualStrings(
        "(no output, exit exited 3)",
        try dispatch(arena, "bash", "{\"command\":\"exit 3\"}"),
    );
    try std.testing.expectEqualStrings(
        "(no output, exit exited 0)",
        try dispatch(arena, "bash", "{\"command\":\"exit 0\"}"),
    );
    // The same number reaches the line when there was output to append it to,
    // so the two spellings cannot drift apart again.
    try std.testing.expectEqualStrings(
        "hi\n\n(exit: exited 3)",
        try dispatch(arena, "bash", "{\"command\":\"echo hi; exit 3\"}"),
    );
}

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
// must not inherit it. The result of `printenv` is a tool result, so an
// inherited key would be in the request body of every remaining turn of a run.
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
        null,
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
        null,
    );
    try std.testing.expect(std.mem.indexOf(u8, inherited.stdout, "sk-live-not-a-real-key") != null);
}

// A delegated program that is not installed is the ordinary case on a stock
// macOS, which ships git and neither ripgrep nor ast-grep. The spawn reports
// that as `FileNotFound`, which must not reach the model and the operator as
// `error: ripgrep failed: FileNotFound`: no program to install and no way to
// install it, on a platform this release publishes for.
test "a delegated program this machine does not have is named, with a way to install it" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The spawn resolves argv[0] against the parent's PATH whatever the child
    // environment says, so the program that is missing is named here rather
    // than engineered with a scrubbed PATH: this is the same spawn, failing
    // the way it fails on a stock macOS with no ripgrep installed.
    const got = try runSearchTool(
        std.testing.io,
        arena,
        &.{"microagent-no-such-program"},
        "ripgrep",
        ripgrep_install,
        10_000,
        null,
    );
    try std.testing.expect(std.mem.indexOf(u8, got, "ripgrep is not on PATH") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "brew install ripgrep") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "apt-get install ripgrep") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "FileNotFound") == null);

    // Every other failure keeps the shape the call site already had, so a
    // timeout is still a timeout and a message change cannot be mistaken for
    // one.
    const timed_out = try missingProgram(arena, "ripgrep", ripgrep_install, error.Timeout);
    try std.testing.expectEqualStrings("error: ripgrep failed: Timeout", timed_out);
    const git_missing = try missingProgram(arena, "git diff", git_install, error.FileNotFound);
    try std.testing.expect(std.mem.indexOf(u8, git_missing, "git diff is not on PATH") != null);
    try std.testing.expect(std.mem.indexOf(u8, git_missing, "brew install git") != null);
}

// A child that closes its own output streams and keeps running would hang the
// whole run: the drain finishes on the closed pipes, and a bare `child.wait`
// after it takes no timeout, so the tool call blocks for as long as the
// command decides and the group reap on the way out never fires. The timeout
// the call was given has to bound the wait as well as the drain.
test "a command that closes its pipes and keeps running is bounded by the tool timeout" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    const start = Io.Timestamp.now(io, .awake).nanoseconds;
    // The timeout really is waited out here, so the ceiling below has to cover
    // a second of it plus whatever a loaded runner adds. It is still three
    // orders of magnitude under the ten minutes the command would otherwise
    // hold the suite for.
    try std.testing.expectError(error.Timeout, runCapped(
        io,
        arena,
        &.{ "/bin/sh", "-c", "exec 1>&- 2>&-; sleep 600" },
        4096,
        net.durationMs(1000),
        null,
        null,
    ));
    const elapsed_ms = @divTrunc(Io.Timestamp.now(io, .awake).nanoseconds - start, std.time.ns_per_ms);
    try std.testing.expect(elapsed_ms < 30_000);

    // The child the deadline killed is not left holding its process group: the
    // reap is what keeps a timed-out command's background work from outliving
    // the turn, and it only runs because the wait returned.
    try std.testing.expectEqual(@as(std.posix.pid_t, 0), tool_group.load(.monotonic));
}
