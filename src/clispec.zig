//! CLI Spec 0.3 for this binary: the `schema` document, `-o`/`--output`, and the
//! JSON error envelope. The unflagged pipe contract is the model's text, so
//! `auto` stays text and only an explicit `json` selects the envelope.
//! `schema` itself is always the document.

const std = @import("std");
const chat = @import("chat.zig");
const net = @import("net.zig");

const version = @import("build_options").version;

pub const OutputMode = enum { auto, text, json };

/// Explicit `-o json` only. `auto` is text on a pipe because the tool declares
/// `piped: text`.
pub var json_mode: bool = false;

pub fn select(mode: OutputMode) void {
    json_mode = mode == .json;
}

pub fn parseMode(value: []const u8) ?OutputMode {
    if (std.mem.eql(u8, value, "auto")) return .auto;
    if (std.mem.eql(u8, value, "text")) return .text;
    if (std.mem.eql(u8, value, "json")) return .json;
    return null;
}

pub const schema_usage =
    \\usage: microagent schema [command]
    \\
    \\Print the CLI Spec 0.3 document for this program on stdout and exit 0.
    \\No config, no credentials, and no network. A command path keeps that
    \\command and any command whose path starts with it.
    \\
    \\  -h, --help     this text ("microagent help schema" too)
    \\  -V, --version  version
    \\  -o, --output   accepted; the document is JSON either way
    \\
;

const CommandKind = enum { schema, help, setup, update, acp };

/// The invocable commands. `schema` walks this table, so a command added only
/// in the writer or only here cannot drift from the other.
const commands = [_]struct { name: []const u8, kind: CommandKind }{
    .{ .name = "schema", .kind = .schema },
    .{ .name = "help", .kind = .help },
    .{ .name = "setup", .kind = .setup },
    .{ .name = "update", .kind = .update },
    .{ .name = "acp", .kind = .acp },
};

pub fn commandName(kind: CommandKind) []const u8 {
    for (commands) |command| if (command.kind == kind) return command.name;
    unreachable;
}

fn wanted(filter: []const u8, name: []const u8) bool {
    if (filter.len == 0) return true;
    if (std.mem.eql(u8, name, filter)) return true;
    return name.len > filter.len and std.mem.startsWith(u8, name, filter) and name[filter.len] == ' ';
}

pub fn matchesAny(filter: []const u8) bool {
    if (filter.len == 0) return true;
    for (commands) |command| if (wanted(filter, command.name)) return true;
    return false;
}

const Doc = struct {
    w: *std.Io.Writer,
    pretty: bool,
    first: [12]bool = @splat(true),
    depth: usize = 0,

    fn indent(self: *Doc) !void {
        if (!self.pretty) return;
        try self.w.writeByte('\n');
        var n: usize = 0;
        while (n < self.depth) : (n += 1) try self.w.writeAll("  ");
    }

    fn sep(self: *Doc) !void {
        if (self.first[self.depth]) {
            self.first[self.depth] = false;
        } else {
            try self.w.writeByte(',');
        }
        try self.indent();
    }

    fn beginRoot(self: *Doc) !void {
        try self.w.writeByte('{');
        self.depth = 1;
        self.first[1] = true;
    }

    fn endRoot(self: *Doc) !void {
        const empty = self.first[self.depth];
        self.depth = 0;
        if (self.pretty and !empty) try self.w.writeByte('\n');
        try self.w.writeAll("}\n");
    }

    fn field(self: *Doc, name: []const u8) !void {
        try self.sep();
        try chat.writeJsonString(self.w, name);
        try self.w.writeAll(if (self.pretty) ": " else ":");
    }

    fn fieldStr(self: *Doc, name: []const u8, value: []const u8) !void {
        try self.field(name);
        try chat.writeJsonString(self.w, value);
    }

    fn fieldBool(self: *Doc, name: []const u8, value: bool) !void {
        try self.field(name);
        try self.w.writeAll(if (value) "true" else "false");
    }

    fn fieldInt(self: *Doc, name: []const u8, value: i64) !void {
        try self.field(name);
        try self.w.print("{d}", .{value});
    }

    fn beginObj(self: *Doc) !void {
        try self.w.writeByte('{');
        self.depth += 1;
        self.first[self.depth] = true;
    }

    fn endObj(self: *Doc) !void {
        const empty = self.first[self.depth];
        self.depth -= 1;
        if (self.pretty and !empty) try self.indent();
        try self.w.writeByte('}');
    }

    fn beginArr(self: *Doc) !void {
        try self.w.writeByte('[');
        self.depth += 1;
        self.first[self.depth] = true;
    }

    fn endArr(self: *Doc) !void {
        const empty = self.first[self.depth];
        self.depth -= 1;
        if (self.pretty and !empty) try self.indent();
        try self.w.writeByte(']');
    }

    fn elemStr(self: *Doc, value: []const u8) !void {
        try self.sep();
        try chat.writeJsonString(self.w, value);
    }

    fn beginElemObj(self: *Doc) !void {
        try self.sep();
        try self.beginObj();
    }
};

fn stdoutPretty(io: std.Io) bool {
    return std.Io.File.stdout().isTty(io) catch false;
}

pub fn writeError(io: std.Io, kind: []const u8, message: []const u8, hint: []const u8) void {
    var storage: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&storage);
    w.writeAll("{\"error\":{\"kind\":") catch return;
    chat.writeJsonString(&w, kind) catch return;
    w.writeAll(",\"message\":") catch return;
    chat.writeJsonString(&w, if (message.len > 800) message[0..800] else message) catch return;
    w.writeAll(",\"hint\":") catch return;
    chat.writeJsonString(&w, if (hint.len > 400) hint[0..400] else hint) catch return;
    w.writeAll("}}\n") catch return;
    net.writeErr(io, w.buffered());
}

pub fn writeVersion(io: std.Io) !void {
    var storage: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&storage);
    var doc: Doc = .{ .w = &w, .pretty = stdoutPretty(io) };
    try doc.beginRoot();
    try doc.fieldStr("name", "microagent");
    try doc.fieldStr("version", version);
    try doc.endRoot();
    try net.writeOut(io, w.buffered());
}

pub fn setupJson(arena: std.mem.Allocator, changed: bool, path: []const u8, pretty: bool) ![]u8 {
    // The arguments travel with the call rather than through fields of a
    // function-scoped struct. Such a struct is one per compilation, so a field
    // written by one call and read by its body is one slot every caller
    // shares: two setups writing at once would each print the other's path.
    const Body = struct {
        changed_bit: bool,
        path_text: []const u8,
        fn body(ctx: *const anyopaque, doc: *Doc) !void {
            const self: *const @This() = @ptrCast(@alignCast(ctx));
            try doc.beginRoot();
            try doc.fieldBool("changed", self.changed_bit);
            try doc.fieldStr("path", self.path_text);
            try doc.endRoot();
        }
    };
    const body: Body = .{ .changed_bit = changed, .path_text = path };
    var aw: std.Io.Writer.Allocating = .init(arena);
    var doc: Doc = .{ .w = &aw.writer, .pretty = pretty };
    try Body.body(&body, &doc);
    return aw.written();
}

pub fn writeSetup(io: std.Io, arena: std.mem.Allocator, changed: bool, path: []const u8) !void {
    try net.writeOut(io, try setupJson(arena, changed, path, stdoutPretty(io)));
}

pub const UpdateStatus = struct {
    tag: []const u8,
    page: []const u8,
    running: []const u8,
    relation: []const u8,
    current: bool,
    changed: bool,
    path: ?[]const u8,
};

pub fn updateStatusJson(arena: std.mem.Allocator, status: UpdateStatus, pretty: bool) ![]u8 {
    // The status travels with the call, for the same reason `setupJson` keeps
    // its arguments off a function-scoped struct: a field of one is a single
    // slot shared by every caller, and two status lines writing at once would
    // each report the other's tag.
    const Body = struct {
        held: UpdateStatus,
        fn body(ctx: *const anyopaque, doc: *Doc) !void {
            const self: *const @This() = @ptrCast(@alignCast(ctx));
            try doc.beginRoot();
            try doc.fieldStr("tag", self.held.tag);
            try doc.fieldStr("page", self.held.page);
            try doc.fieldStr("running", self.held.running);
            try doc.fieldStr("relation", self.held.relation);
            try doc.fieldBool("current", self.held.current);
            try doc.fieldBool("changed", self.held.changed);
            if (self.held.path) |path| try doc.fieldStr("path", path) else try doc.field("path");
            if (self.held.path == null) try doc.w.writeAll("null");
            try doc.endRoot();
        }
    };
    const body: Body = .{ .held = status };
    var aw: std.Io.Writer.Allocating = .init(arena);
    var doc: Doc = .{ .w = &aw.writer, .pretty = pretty };
    try Body.body(&body, &doc);
    return aw.written();
}

pub fn writeUpdateStatus(io: std.Io, arena: std.mem.Allocator, status: UpdateStatus) !void {
    try net.writeOut(io, try updateStatusJson(arena, status, stdoutPretty(io)));
}

test "concurrent status lines each carry the call that wrote them" {
    const io = std.testing.io;
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const arena = state.allocator();
    var setup_out: ?[]u8 = null;
    var status_out: ?[]u8 = null;
    var gate: std.Io.Event = .unset;
    const Pair = struct {
        fn setup(io_: std.Io, gate_: *std.Io.Event, allocator: std.mem.Allocator, out: *?[]u8) void {
            gate_.wait(io_) catch return;
            out.* = setupJson(allocator, true, "/tmp/one", false) catch null;
        }
        fn status(io_: std.Io, gate_: *std.Io.Event, allocator: std.mem.Allocator, out: *?[]u8) void {
            gate_.wait(io_) catch return;
            out.* = updateStatusJson(allocator, .{
                .tag = "v9",
                .page = "https://example.test/v9",
                .running = "v1",
                .relation = "behind",
                .current = false,
                .changed = true,
                .path = "/bin/microagent",
            }, false) catch null;
        }
    };
    var tasks: std.Io.Group = .init;
    defer tasks.cancel(io);
    try tasks.concurrent(io, Pair.setup, .{ io, &gate, arena, &setup_out });
    try tasks.concurrent(io, Pair.status, .{ io, &gate, arena, &status_out });
    gate.set(io);
    try tasks.await(io);
    const setup_line = setup_out orelse return error.TestUnexpectedResult;
    const status_line = status_out orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, setup_line, "\"path\":\"/tmp/one\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, setup_line, "v9") == null);
    try std.testing.expect(std.mem.indexOf(u8, status_line, "\"tag\":\"v9\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, status_line, "/tmp/one") == null);
}

pub fn schemaJson(arena: std.mem.Allocator, filter: []const u8, pretty: bool) ![]u8 {
    if (!matchesAny(filter)) return error.NoMatch;
    var aw: std.Io.Writer.Allocating = .init(arena);
    var doc: Doc = .{ .w = &aw.writer, .pretty = pretty };
    try writeDocument(&doc, filter);
    return aw.written();
}

pub fn writeSchema(io: std.Io, arena: std.mem.Allocator, filter: []const u8) !void {
    const bytes = try schemaJson(arena, filter, stdoutPretty(io));
    try net.writeOut(io, bytes);
}

fn writeDocument(doc: *Doc, filter: []const u8) !void {
    try doc.beginRoot();
    try doc.fieldStr("clispec", "0.3");
    try doc.fieldStr("name", "microagent");
    try doc.fieldStr("version", version);
    try doc.fieldStr("description", "Tiny OpenAI-compatible coding agent. The default invocation is microagent [flags] \"<prompt>\" and is not a named subcommand: a bare word other than help, schema, setup, update, or acp is the task. That run's stdout is the model's text plus one {\"type\":\"usage\"} line per response, and -o does not re-encode it. A retry is not safe, because the run edits the tree and calls tools, and there is no idempotency key.");
    try doc.field("output");
    try doc.beginObj();
    try doc.fieldStr("tty", "text");
    try doc.fieldStr("piped", "text");
    try doc.endObj();
    try doc.field("global_args");
    try doc.beginArr();
    try writeOutputArg(doc);
    try doc.endArr();
    try doc.field("commands");
    try doc.beginArr();
    for (commands) |command| {
        if (!wanted(filter, command.name)) continue;
        switch (command.kind) {
            .schema => try writeSchemaCommand(doc),
            .help => try writeHelpCommand(doc),
            .setup => try writeSetupCommand(doc),
            .update => try writeUpdateCommand(doc),
            .acp => try writeAcpCommand(doc),
        }
    }
    try doc.endArr();
    try doc.field("errors");
    try doc.beginArr();
    try writeErr(doc, "usage", 2, false, "The command line was wrong. Nothing was attempted.");
    try writeErr(doc, "config", 2, false, "The command line parsed, but a configuration value or credential could not be used. The API key comes from --api-key, MICROAGENT_API_KEY, or api_key in the config file, and is never printed.");
    try writeErr(doc, "failure", 1, false, "The command failed. A retry of an agent run is not safe when it already edited the tree or called tools.");
    try writeErr(doc, "incomplete", 3, false, "The run stopped without an answer. Stdout is a prefix of the work.");
    try writeErr(doc, "interrupted", 130, false, "Interrupted (Ctrl+C or kill). The signal handler exits 130 and does not write the envelope.");
    try doc.endArr();
    try doc.endRoot();
}

fn writeOutputArg(doc: *Doc) !void {
    try doc.beginElemObj();
    try doc.fieldStr("name", "--output");
    try doc.fieldStr("short", "-o");
    try doc.fieldStr("type", "string");
    try doc.field("enum");
    try doc.beginArr();
    try doc.elemStr("auto");
    try doc.elemStr("text");
    try doc.elemStr("json");
    try doc.endArr();
    try doc.fieldStr("default", "auto");
    try doc.fieldStr("description", "auto and text keep the text a command already prints, including when stdout is not a terminal. json asks schema, --version, setup, and update for one JSON document. The model's own stdout is unchanged. Accepted before the subcommand.");
    try doc.endObj();
}

fn writeErr(doc: *Doc, kind: []const u8, code: i64, retryable: bool, description: []const u8) !void {
    try doc.beginElemObj();
    try doc.fieldStr("kind", kind);
    try doc.fieldInt("exit_code", code);
    try doc.fieldBool("retryable", retryable);
    try doc.fieldStr("description", description);
    try doc.endObj();
}

fn writeKinds(doc: *Doc, kinds: []const []const u8) !void {
    try doc.field("errors");
    try doc.beginArr();
    for (kinds) |kind| try doc.elemStr(kind);
    try doc.endArr();
}

const Field = struct {
    name: []const u8,
    typ: []const u8,
    nullable: bool = false,
    desc: []const u8 = "",
    items: ?[]const u8 = null,
    enum_vals: ?[]const []const u8 = null,
};

fn writeFields(doc: *Doc, fields: []const Field) !void {
    try doc.field("output_fields");
    try doc.beginArr();
    for (fields) |field| {
        try doc.beginElemObj();
        try doc.fieldStr("name", field.name);
        try doc.fieldStr("type", field.typ);
        if (field.nullable) try doc.fieldBool("nullable", true);
        if (field.desc.len != 0) try doc.fieldStr("description", field.desc);
        if (field.enum_vals) |vals| {
            try doc.field("enum");
            try doc.beginArr();
            for (vals) |value| try doc.elemStr(value);
            try doc.endArr();
        }
        if (std.mem.eql(u8, field.typ, "array")) {
            try doc.field("items");
            try doc.beginObj();
            try doc.fieldStr("type", field.items orelse "object");
            try doc.endObj();
        }
        try doc.endObj();
    }
    try doc.endArr();
}

fn writeSchemaCommand(doc: *Doc) !void {
    try doc.beginElemObj();
    try doc.fieldStr("name", "schema");
    try doc.fieldStr("description", "Print this document and exit 0. Reads no config, no credentials, and no network. A command path keeps that command and any command whose path starts with it. -o does not change the document.");
    try doc.fieldStr("effects", "read_only");
    try doc.fieldStr("cardinality", "single");
    try doc.field("args");
    try doc.beginArr();
    try doc.beginElemObj();
    try doc.fieldStr("name", "command");
    try doc.fieldStr("type", "string");
    try doc.fieldStr("description", "Command path to keep. Omitted, every command is listed.");
    try doc.endObj();
    try doc.endArr();
    try writeFields(doc, &.{
        .{ .name = "clispec", .typ = "string" },
        .{ .name = "name", .typ = "string" },
        .{ .name = "version", .typ = "string" },
        .{ .name = "output", .typ = "object", .desc = "tty and piped default formats." },
        .{ .name = "global_args", .typ = "array", .items = "object" },
        .{ .name = "commands", .typ = "array", .items = "object" },
        .{ .name = "errors", .typ = "array", .items = "object" },
    });
    try writeKinds(doc, &.{ "usage", "failure" });
    try doc.endObj();
}

fn writeHelpCommand(doc: *Doc) !void {
    try doc.beginElemObj();
    try doc.fieldStr("name", "help");
    try doc.fieldStr("description", "Print the usage text. With a subcommand name, print that command's usage text. -o json does not change these bytes.");
    try doc.fieldStr("effects", "read_only");
    try doc.fieldStr("output_kind", "opaque");
    try doc.fieldStr("media_type", "text/plain");
    try doc.field("args");
    try doc.beginArr();
    try doc.beginElemObj();
    try doc.fieldStr("name", "command");
    try doc.fieldStr("type", "string");
    try doc.fieldStr("description", "setup, update, schema, or acp. Omitted, the top-level usage text.");
    try doc.endObj();
    try doc.endArr();
    try writeKinds(doc, &.{"usage"});
    try doc.endObj();
}

fn writeSetupCommand(doc: *Doc) !void {
    try doc.beginElemObj();
    try doc.fieldStr("name", "setup");
    try doc.fieldStr("description", "Write the config the answers describe. The same answers leave the file unchanged and exit 0. A retry is safe. Answers come from stdin and a terminal is not required.");
    try doc.fieldStr("effects", "idempotent");
    try doc.fieldStr("cardinality", "single");
    try doc.field("args");
    try doc.beginArr();
    try doc.beginElemObj();
    try doc.fieldStr("name", "--config");
    try doc.fieldStr("type", "path");
    try doc.fieldStr("description", "Config file. Else MICROAGENT_CONFIG, else ~/.microagent/config.toml.");
    try doc.endObj();
    try doc.endArr();
    try writeFields(doc, &.{
        .{ .name = "changed", .typ = "boolean", .desc = "False when the answers matched the file already on disk." },
        .{ .name = "path", .typ = "string" },
    });
    try writeKinds(doc, &.{ "usage", "config", "failure", "interrupted" });
    try doc.endObj();
}

fn writeUpdateCommand(doc: *Doc) !void {
    try doc.beginElemObj();
    try doc.fieldStr("name", "update");
    try doc.fieldStr("description", "Install the latest GitHub release when this build is older, and exit 0 when it is already current. --check reports and installs nothing. A retry is safe: the binary is replaced only after the checksum matches, and a current build is left in place.");
    try doc.fieldStr("effects", "idempotent");
    try doc.fieldStr("cardinality", "single");
    try doc.field("args");
    try doc.beginArr();
    try doc.beginElemObj();
    try doc.fieldStr("name", "--check");
    try doc.fieldStr("short", "-c");
    try doc.fieldStr("type", "boolean");
    try doc.fieldStr("description", "Report the latest release and install nothing.");
    try doc.endObj();
    try doc.endArr();
    try writeFields(doc, &.{
        .{ .name = "tag", .typ = "string", .desc = "Latest release tag." },
        .{ .name = "page", .typ = "string", .desc = "Release page URL." },
        .{ .name = "running", .typ = "string", .desc = "This build's version." },
        .{ .name = "relation", .typ = "string", .enum_vals = &.{ "current", "older", "newer", "incomparable" }, .desc = "current: this build is the release. older: a newer release exists. newer: this build is ahead. incomparable: the tag is not a version triple." },
        .{ .name = "current", .typ = "boolean" },
        .{ .name = "changed", .typ = "boolean", .desc = "True only when this run replaced the binary." },
        .{ .name = "path", .typ = "string", .nullable = true, .desc = "Installed path, or null when nothing was replaced." },
    });
    try writeKinds(doc, &.{ "usage", "failure" });
    try doc.endObj();
}

fn writeAcpCommand(doc: *Doc) !void {
    try doc.beginElemObj();
    try doc.fieldStr("name", "acp");
    try doc.fieldStr("description", "Serve the Agent Client Protocol v1 on stdin and stdout until the client closes stdin, then exit 0. Frames are JSON-RPC, not this program's -o envelope, and -o does not change them. A terminal is not required. A retry is not safe: a session edits the tree and calls tools, and there is no idempotency key.");
    try doc.fieldStr("effects", "non_idempotent");
    try doc.fieldStr("output_kind", "opaque");
    try doc.fieldStr("media_type", "application/json");
    try doc.field("args");
    try doc.beginArr();
    try doc.endArr();
    try writeKinds(doc, &.{ "usage", "config", "failure", "interrupted" });
    try doc.endObj();
}

pub const Stripped = struct {
    mode: OutputMode,
    argv: []const []const u8,
    /// Set when `-o` was present and the value was missing or not a format.
    failure: ?[]const u8 = null,
};

fn outputSpec(arg: []const u8) ?union(enum) { joined: []const u8, separate } {
    if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) return .separate;
    const prefix = "--output=";
    if (std.mem.startsWith(u8, arg, prefix)) return .{ .joined = arg[prefix.len..] };
    return null;
}

fn flagName(arg: []const u8) []const u8 {
    if (std.mem.startsWith(u8, arg, "--")) {
        if (std.mem.indexOfScalar(u8, arg, '=')) |eq| return arg[0..eq];
    }
    return arg;
}

fn valueJoined(arg: []const u8) bool {
    return std.mem.startsWith(u8, arg, "--") and std.mem.indexOfScalar(u8, arg, '=') != null;
}

fn safeToken(value: []const u8) bool {
    if (value.len == 0 or value.len > 32) return false;
    for (value) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return false;
    }
    return true;
}

/// Remove `-o`/`--output` from `argv`, stopping at a bare `--`. A valued flag's
/// own value is left alone, so `--model -o` keeps `-o` as the model name.
/// The returned pointer array is owned by `gpa`; the argument strings are not.
pub fn stripOutput(
    gpa: std.mem.Allocator,
    argv: []const []const u8,
    takes_value: *const fn ([]const u8) bool,
) !Stripped {
    var mode: OutputMode = .auto;
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(gpa);
    if (argv.len == 0) return .{ .mode = mode, .argv = argv };
    try out.append(gpa, argv[0]);
    var i: usize = 1;
    var ended = false;
    while (i < argv.len) {
        const arg = argv[i];
        if (!ended and std.mem.eql(u8, arg, "--")) {
            ended = true;
            try out.append(gpa, arg);
            i += 1;
            continue;
        }
        if (ended) {
            try out.append(gpa, arg);
            i += 1;
            continue;
        }
        if (outputSpec(arg)) |spec| {
            const value = switch (spec) {
                .joined => |joined| joined,
                .separate => blk: {
                    if (i + 1 >= argv.len) {
                        out.deinit(gpa);
                        return .{ .mode = .auto, .argv = argv, .failure = "-o needs a format: auto, text, or json" };
                    }
                    i += 1;
                    break :blk argv[i];
                },
            };
            mode = parseMode(value) orelse {
                out.deinit(gpa);
                if (!safeToken(value)) return .{ .mode = .auto, .argv = argv, .failure = "unknown output format; -o takes auto, text, or json" };
                const msg = std.fmt.allocPrint(gpa, "unknown output format '{s}'; -o takes auto, text, or json", .{value}) catch
                    "unknown output format; -o takes auto, text, or json";
                return .{ .mode = .auto, .argv = argv, .failure = msg };
            };
            i += 1;
            continue;
        }
        const name = flagName(arg);
        if (takes_value(name) and !valueJoined(arg)) {
            try out.append(gpa, arg);
            i += 1;
            if (i < argv.len) {
                try out.append(gpa, argv[i]);
                i += 1;
            }
            continue;
        }
        try out.append(gpa, arg);
        i += 1;
    }
    return .{ .mode = mode, .argv = try out.toOwnedSlice(gpa) };
}

test "schema is one document and a command path filters it" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const bytes = try schemaJson(arena, "", false);
    const root = try std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{});
    const obj = switch (root) {
        .object => |o| o,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("0.3", switch (obj.get("clispec").?) {
        .string => |s| s,
        else => return error.TestUnexpectedResult,
    });
    try std.testing.expectEqualStrings("microagent", switch (obj.get("name").?) {
        .string => |s| s,
        else => return error.TestUnexpectedResult,
    });
    try std.testing.expectEqualStrings(version, switch (obj.get("version").?) {
        .string => |s| s,
        else => return error.TestUnexpectedResult,
    });
    const piped = switch (obj.get("output").?) {
        .object => |o| o.get("piped").?,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("text", switch (piped) {
        .string => |s| s,
        else => return error.TestUnexpectedResult,
    });
    const listed = switch (obj.get("commands").?) {
        .array => |a| a,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(usize, commands.len), listed.items.len);
    const errs = switch (obj.get("errors").?) {
        .array => |a| a,
        else => return error.TestUnexpectedResult,
    };
    var saw_usage = false;
    var saw_failure = false;
    for (errs.items) |item| {
        const err_obj = switch (item) {
            .object => |o| o,
            else => return error.TestUnexpectedResult,
        };
        const kind = switch (err_obj.get("kind").?) {
            .string => |s| s,
            else => return error.TestUnexpectedResult,
        };
        const code = switch (err_obj.get("exit_code").?) {
            .integer => |n| n,
            else => return error.TestUnexpectedResult,
        };
        if (std.mem.eql(u8, kind, "usage")) {
            saw_usage = true;
            try std.testing.expectEqual(@as(i64, 2), code);
        }
        if (std.mem.eql(u8, kind, "failure")) {
            saw_failure = true;
            try std.testing.expectEqual(@as(i64, 1), code);
        }
    }
    try std.testing.expect(saw_usage and saw_failure);

    const only = try schemaJson(arena, "update", false);
    const one = try std.json.parseFromSliceLeaky(std.json.Value, arena, only, .{});
    const one_cmds = switch (one) {
        .object => |o| switch (o.get("commands").?) {
            .array => |a| a,
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(usize, 1), one_cmds.items.len);
    try std.testing.expectError(error.NoMatch, schemaJson(arena, "nope", false));

    var saw_acp = false;
    for (listed.items) |item| {
        const cmd = switch (item) {
            .object => |o| o,
            else => return error.TestUnexpectedResult,
        };
        const name = switch (cmd.get("name") orelse return error.TestUnexpectedResult) {
            .string => |s| s,
            else => return error.TestUnexpectedResult,
        };
        if (!std.mem.eql(u8, name, "acp")) continue;
        saw_acp = true;
        const effects = switch (cmd.get("effects") orelse return error.TestUnexpectedResult) {
            .string => |s| s,
            else => return error.TestUnexpectedResult,
        };
        try std.testing.expectEqualStrings("non_idempotent", effects);
    }
    try std.testing.expect(saw_acp);
}

test "-o is stripped before a subcommand and stops at --" {
    const gpa = std.testing.allocator;
    const takes = struct {
        fn takes(name: []const u8) bool {
            return std.mem.eql(u8, name, "--model") or std.mem.eql(u8, name, "-p");
        }
    }.takes;
    const cases = [_]struct {
        argv: []const []const u8,
        mode: OutputMode,
        len: usize,
        fail: bool = false,
    }{
        .{ .argv = &.{ "bin", "-o", "json", "schema" }, .mode = .json, .len = 2 },
        .{ .argv = &.{ "bin", "--output=text", "update", "--check" }, .mode = .text, .len = 3 },
        .{ .argv = &.{ "bin", "--", "-o", "json" }, .mode = .auto, .len = 4 },
        .{ .argv = &.{ "bin", "--model", "-o", "task" }, .mode = .auto, .len = 4 },
        .{ .argv = &.{ "bin", "-o" }, .mode = .auto, .len = 2, .fail = true },
        .{ .argv = &.{ "bin", "-o", "yaml" }, .mode = .auto, .len = 3, .fail = true },
    };
    for (cases) |case| {
        const stripped = try stripOutput(gpa, case.argv, takes);
        defer if (stripped.failure == null) gpa.free(stripped.argv);
        defer if (stripped.failure) |msg| {
            if (std.mem.indexOf(u8, msg, "unknown output format '") != null) gpa.free(msg);
        };
        if (case.fail) {
            try std.testing.expect(stripped.failure != null);
            continue;
        }
        try std.testing.expect(stripped.failure == null);
        try std.testing.expectEqual(case.mode, stripped.mode);
        try std.testing.expectEqual(case.len, stripped.argv.len);
    }
}

const strip_output_corpus = [_][]const u8{
    "",
    "bin",
    "bin\x00-o\x00json\x00schema",
    "bin\x00--output=json\x00schema",
    "bin\x00--output=yaml\x00schema",
    "bin\x00--output=\x00schema",
    "bin\x00-o\x00json\x00--\x00-o\x00json",
    "bin\x00--model\x00-o\x00task",
    "bin\x00--\x00-o\x00json",
    "bin\x00-o",
    "bin\x00-o\x00\x00schema",
    "bin\x00-o\x00json\x00update\x00--check",
    "bin\x00--output=text\x00update\x00--check",
    "bin\x00-o\x00JSON",
    "bin\x00-o\x00auto\x00schema",
    "bin\x00-o\x00json\x00schema\x00extra",
    "bin\x00--model=x\x00--output=json\x00help",
    "bin\x00-o\x00jso\x00n",
    "bin\x00-o\x00json\x00schema\x00",
    "\x00",
    "bin\x00\xff\xfe\x00-o\x00json",
    "bin\x00-o\x00\xc3\xa9",
    "bin\x00--output=json\x00--\x00--output=text",
    "bin\x00--model\x00--output=json\x00task",
    "bin\x00--output=json\x00--model\x00-o\x00task",
};

test "a fuzzed argv is stripped the way its entries spell it" {
    try std.testing.fuzz({}, fuzzStripOutput, .{ .corpus = &strip_output_corpus });
}

fn takesValue(name: []const u8) bool {
    return std.mem.eql(u8, name, "--model") or std.mem.eql(u8, name, "-p");
}

fn fuzzStripOutput(_: void, smith: *std.testing.Smith) !void {
    const gpa = std.testing.allocator;
    var raw: [4 * 1024]u8 = undefined;
    const bytes: []const u8 = if (smith.in) |seed| seed else raw[0..smith.slice(&raw)];

    var state = std.heap.ArenaAllocator.init(gpa);
    defer state.deinit();
    const arena = state.allocator();

    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(arena, "bin");
    var rest = bytes;
    while (std.mem.indexOfScalar(u8, rest, 0)) |at| {
        try argv.append(arena, rest[0..at]);
        rest = rest[at + 1 ..];
        if (rest.len == 0) break;
    }
    if (rest.len != 0) try argv.append(arena, rest);

    const stripped = try stripOutput(arena, argv.items, takesValue);

    try std.testing.expect(stripped.argv.len >= 1);
    try std.testing.expectEqualStrings(argv.items[0], stripped.argv[0]);
    try std.testing.expect(stripped.argv.len <= argv.items.len);

    if (stripped.failure != null) {
        const msg = stripped.failure.?;
        try std.testing.expect(std.mem.indexOf(u8, msg, "unknown output format") != null or std.mem.indexOf(u8, msg, "-o needs a format") != null);
        if (std.mem.indexOf(u8, msg, "unknown output format '")) |at| {
            const start = at + "unknown output format '".len;
            const end = std.mem.indexOfScalarPos(u8, msg, start, '\'') orelse msg.len;
            const value = msg[start..end];
            try std.testing.expect(parseMode(value) == null);
        }
        return;
    }

    const mode_name: []const u8 = switch (stripped.mode) {
        .auto => "auto",
        .text => "text",
        .json => "json",
    };
    try std.testing.expect(parseMode(mode_name) == stripped.mode);

    var ended = false;
    var i: usize = 1;
    while (i < stripped.argv.len) {
        const arg = stripped.argv[i];
        if (!ended and std.mem.eql(u8, arg, "--")) {
            ended = true;
            i += 1;
            continue;
        }
        if (ended) {
            i += 1;
            continue;
        }
        if (i > 1) {
            const prev = stripped.argv[i - 1];
            const prev_name = flagName(prev);
            if (takesValue(prev_name) and !valueJoined(prev)) {
                i += 1;
                continue;
            }
        }
        try std.testing.expect(outputSpec(arg) == null);
        const name = flagName(arg);
        if (takesValue(name) and !valueJoined(arg)) {
            i += 2;
            continue;
        }
        i += 1;
    }

    const again = try stripOutput(arena, argv.items, takesValue);
    try std.testing.expectEqual(stripped.mode, again.mode);
    try std.testing.expectEqual(stripped.argv.len, again.argv.len);
    try std.testing.expect((stripped.failure == null) == (again.failure == null));
}
