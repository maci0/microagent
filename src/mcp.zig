//! MCP servers: tools the run reaches over a server's stdin and stdout.
//!
//! A Model Context Protocol server is a child process speaking JSON-RPC 2.0,
//! one JSON object per line. This connects to the ones a config file names,
//! asks each for its tool list, and exposes every tool to the provider under
//! `mcp__<server>__<tool>`. A call is a `tools/call` request; the text the
//! server returns is the tool result, exactly as a built-in's output is.
//!
//! Where the servers come from is `config.zig`: one `[[mcp]]` table in the run's
//! TOML config, read into an `Entry` per server, so this module only speaks the
//! protocol and never reads a config file.
//!
//! A server that cannot be started, or that fails the handshake, is reported on
//! stderr and skipped: one broken entry costs the run that entry, not the run.
//! The same is true of a tool whose name cannot be spelled in the schema, and
//! of a call that times out -- the answer is an error string the model reads,
//! which is how every other tool failure reaches it.
//!
//! The server's own stderr is inherited rather than captured: it is where an
//! MCP server writes its diagnostics, and a pipe nobody drains is a server
//! that blocks once it has logged a few kilobytes. Nothing here reads it, so
//! there is no capture for it to fill.

const std = @import("std");
const Io = std.Io;

const chat = @import("chat.zig");
const net = @import("net.zig");
const tool_mod = @import("tool.zig");

/// Every exposed tool name starts with this, so dispatch can tell a remote
/// name from a built-in one without consulting a table. The double underscore
/// is the separator because a server name and a tool name may each hold one,
/// while neither may hold the pair as a whole: a name is checked at connect
/// time for exactly that.
pub const tool_prefix = "mcp__";

/// Ceiling on one protocol line. A `tools/list` answer for a large server is
/// the biggest frame there is; past this the connection is not one this run
/// can follow, and the server is skipped rather than grown for.
const max_frame_bytes: usize = 4 * 1024 * 1024;
/// The buffer a line is split out of is grown to hold the largest line a
/// server sends, and it keeps that capacity for the run. A `tools/list` answer
/// is the one line that is ever large, so the excess is handed back once the
/// line is out and the remainder is small.
const pending_keep_bytes: usize = 64 * 1024;

/// That buffer's own allocator, rather than the run arena: an arena cannot
/// hand memory back, so the ladder of buffers a megabyte line is read through
/// would stay in the run for its whole life. This one frees as it grows past
/// each step and when the line is out.
const pending_allocator = std.heap.page_allocator;
/// How long a server has to answer `initialize` and `tools/list`. A process
/// that starts and then says nothing is the ordinary way a server is broken,
/// and a run that waits on it forever is worse than one that skips it.
const handshake_timeout_ms: u64 = 20_000;
/// The protocol revision this client speaks. A server that answers with its
/// own is taken at its word: the revision is negotiated, not asserted.
const protocol_version = "2025-06-18";
/// The longest server or tool name this run spells into a tool name. The
/// provider sees the whole of it, and the model types it back.
const max_name_bytes: usize = 64;
/// The longest server description kept. A description is what the model picks
/// a tool by, and every later turn pays for it.
const max_description_bytes: usize = 1024;

/// One tool a server offers.
pub const Tool = struct {
    /// The server's own name for it, which is what a `tools/call` sends.
    name: []const u8,
    /// What the model calls: `mcp__<server>__<tool>`.
    exposed: []const u8,
    /// The server's description, or a line saying where the tool came from.
    description: []const u8,
    /// The tool's `inputSchema`, as JSON, or an empty object schema. Kept as
    /// the bytes the server sent rather than as a parsed value, because the
    /// schema is copied into the request whole and nothing here reads it.
    schema: []const u8,
};

/// A connected server, and what it offers.
pub const Server = struct {
    name: []const u8,
    child: std.process.Child,
    /// The group the child leads, so the whole tree is signalled on the way
    /// out the way every other child this program spawns is.
    pgid: std.posix.pid_t,
    to_server: Io.File,
    from_server: Io.File,
    /// Bytes read ahead of the line being assembled: a server may write two
    /// frames between one read and the next, and dropping the second would
    /// desynchronize every request after it.
    pending: std.ArrayList(u8) = .empty,
    next_id: u64 = 1,
    tools: []const Tool,
    /// Why the last request failed, when it did. Set and read by `request`
    /// and the caller that formats the error, which is why it is a field and
    /// not a returned union: a JSON-RPC error is a message, not a variant.
    last_error: []const u8 = "",
    /// A server that exited or timed out is not asked again. The first failure
    /// already cost the call its deadline; the second would cost another.
    dead: bool = false,

    fn reap(self: *Server, io: Io) void {
        std.posix.kill(-self.pgid, .KILL) catch {};
        self.child.kill(io);
        // The buffer is this allocator's, not the arena's, so it is handed
        // back here rather than with the run.
        self.pending.deinit(pending_allocator);
    }

    fn send(self: *Server, io: Io, arena: std.mem.Allocator, id: ?u64, method: []const u8, params_json: []const u8) !void {
        var jb = chat.JsonBuf.init(arena);
        const w = jb.writer();
        try w.writeAll("{\"jsonrpc\":\"2.0\"");
        if (id) |n| try w.print(",\"id\":{d}", .{n});
        try w.writeAll(",\"method\":");
        try chat.writeJsonString(w, method);
        if (params_json.len != 0) {
            try w.writeAll(",\"params\":");
            try w.writeAll(params_json);
        }
        try w.writeAll("}\n");
        try self.to_server.writeStreamingAll(io, jb.items());
    }

    /// The next line the server wrote, held across reads. `error.Timeout` from
    /// the deadline and `error.ServerGone` from its end of the pipe are the
    /// two ways this fails, and both leave the server marked dead by the
    /// caller's error path.
    fn readLine(self: *Server, io: Io, line_arena: std.mem.Allocator, deadline: Io.Timeout) ![]u8 {
        // Only the bytes appended since the last look can hold the newline, so
        // the scan resumes where it stopped. Restarting it at the front re-reads
        // the whole buffer once per chunk, which is quadratic in a line that
        // arrives in many chunks: a one megabyte `tools/list` answer is 128
        // reads, and the scans before this add up to about 66 megabytes of the
        // same bytes. `net.nextLineEnd` is the cursor the streaming reader and
        // the ranged read keep.
        var scanned: usize = 0;
        while (true) {
            if (net.nextLineEnd(self.pending.items, &scanned)) |at| {
                const line = try line_arena.dupe(u8, self.pending.items[0..at]);
                const rest = self.pending.items.len - (at + 1);
                std.mem.copyForwards(u8, self.pending.items[0..rest], self.pending.items[at + 1 ..]);
                self.pending.shrinkRetainingCapacity(rest);
                if (self.pending.capacity > pending_keep_bytes and rest <= pending_keep_bytes)
                    self.pending.shrinkAndFree(pending_allocator, rest);
                return line;
            }
            if (self.pending.items.len > max_frame_bytes) return error.FrameTooLong;
            var chunk: [8 * 1024]u8 = undefined;
            var vec: [1][]u8 = .{&chunk};
            var storage: [1]Io.Operation.Storage = undefined;
            var batch: Io.Batch = .init(&storage);
            defer batch.cancel(io);
            batch.addAt(0, .{ .file_read_streaming = .{ .file = self.from_server, .data = &vec } });
            try batch.awaitConcurrent(io, deadline);
            while (batch.next()) |completion| {
                const n = completion.result.file_read_streaming catch |err| switch (err) {
                    // The pipe ending is how a server exits, not a fault.
                    error.EndOfStream => return error.ServerGone,
                    else => return err,
                };
                // A read may return zero bytes without ending the stream, so
                // the loop re-reads either way; a positive read is appended
                // and the scan above runs again.
                if (n > 0) try self.pending.appendSlice(pending_allocator, chunk[0..n]);
            }
        }
    }

    /// One request and its answer, with the notifications and server requests
    /// in between skipped. The answer's line and parsed tree are allocated
    /// from `scratch`, which the caller may drop as soon as it has copied what
    /// it keeps: a `tools/list` answer is the largest document this program
    /// reads, and its parsed tree is several times the size of its text.
    /// `arena` holds the request, the buffer the answer arrives in, and every
    /// note about it, all of which outlive the scratch.
    fn request(
        self: *Server,
        io: Io,
        arena: std.mem.Allocator,
        scratch: std.mem.Allocator,
        method: []const u8,
        params_json: []const u8,
        timeout: Io.Timeout,
    ) !std.json.Value {
        const deadline = timeout.toDeadline(io);
        const id = self.next_id;
        self.next_id += 1;
        try self.send(io, arena, id, method, params_json);
        while (true) {
            const line = self.readLine(io, scratch, deadline) catch |err| {
                self.last_error = @errorName(err);
                self.dead = true;
                return err;
            };
            const value = std.json.parseFromSliceLeaky(std.json.Value, scratch, line, .{}) catch |err| {
                self.last_error = try std.fmt.allocPrint(arena, "not JSON ({s})", .{@errorName(err)});
                continue;
            };
            const object = switch (value) {
                .object => |o| o,
                else => continue,
            };
            const answer = object.get("id") orelse continue;
            const answer_id: u64 = switch (answer) {
                .integer => |n| std.math.cast(u64, n) orelse continue,
                else => continue,
            };
            if (answer_id != id) continue;
            if (object.get("error")) |err_value| {
                self.last_error = try describeError(arena, err_value);
                return error.ServerRefused;
            }
            return object.get("result") orelse {
                self.last_error = "response carried no result";
                return error.ServerRefused;
            };
        }
    }
};

/// The servers one run connected to, in config order.
pub const Servers = struct {
    items: []Server = &.{},

    /// The server and tool an exposed name resolves to, or null. Resolved by
    /// prefix rather than by a table, because the name the model sends and
    /// the name the schema advertised are built from the same three parts.
    pub const Call = struct { server: *Server, tool: *const Tool };

    pub fn resolve(self: *Servers, exposed: []const u8) ?Call {
        for (self.items) |*server| {
            for (server.tools) |*tool| {
                if (std.mem.eql(u8, tool.exposed, exposed)) return .{ .server = server, .tool = tool };
            }
        }
        return null;
    }

    /// How many tools the servers offer, which is what the schema adds.
    pub fn toolCount(self: Servers) usize {
        var n: usize = 0;
        for (self.items) |server| n += server.tools.len;
        return n;
    }

    /// The schema entries for every remote tool, comma-separated and without
    /// the surrounding brackets, ready to append to the built-in entries.
    /// `schema` is copied verbatim, so an inputSchema this client never
    /// understood still reaches the model as the server wrote it.
    pub fn toolsJson(self: Servers, arena: std.mem.Allocator) ![]const u8 {
        var buf: std.ArrayList(u8) = .empty;
        for (self.items) |server| {
            for (server.tools) |tool| {
                if (buf.items.len != 0) try buf.append(arena, ',');
                var jb = chat.JsonBuf.init(arena);
                const w = jb.writer();
                try w.writeAll("{\"type\":\"function\",\"function\":{\"name\":");
                try chat.writeJsonString(w, tool.exposed);
                try w.writeAll(",\"description\":");
                try chat.writeJsonString(w, tool.description);
                try w.writeAll(",\"parameters\":");
                try w.writeAll(tool.schema);
                try w.writeAll("}}");
                try buf.appendSlice(arena, jb.items());
            }
        }
        return buf.items;
    }

    /// One remote call: the model's argument text is sent as the tool's
    /// `arguments`, and the text the server returns becomes the tool result.
    /// The argument text is checked as JSON before it is embedded, so a model
    /// that streamed a truncated object gets an error string rather than a
    /// server-side parse failure reported as the server's fault.
    pub fn call(io: Io, arena: std.mem.Allocator, call_: Call, args_text: []const u8, timeout: Io.Timeout) ![]const u8 {
        const server = call_.server;
        if (server.dead) return std.fmt.allocPrint(arena, "error: MCP server {s} is no longer running ({s})", .{ server.name, server.last_error });
        const args = std.mem.trim(u8, args_text, " \t\r\n");
        if (args.len != 0) {
            _ = std.json.parseFromSliceLeaky(std.json.Value, arena, args, .{}) catch
                return "error: tool arguments are not valid JSON";
        }
        var pb = chat.JsonBuf.init(arena);
        try pb.writer().writeAll("{\"name\":");
        try chat.writeJsonString(pb.writer(), call_.tool.name);
        try pb.writer().writeAll(",\"arguments\":");
        try pb.writer().writeAll(if (args.len == 0) "{}" else args);
        try pb.writer().writeAll("}");

        net.writeErr(io, try std.fmt.allocPrint(arena, "\u{23fa} {s}\n", .{chat.safeText(arena, call_.tool.exposed, 120)}));
        // The answer is parsed in a scratch arena and only the text built from
        // it is kept, for the reason the handshake gives.
        var scratch_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer scratch_state.deinit();
        const result = server.request(io, arena, scratch_state.allocator(), "tools/call", pb.items(), timeout) catch |err| {
            if (err == error.ServerRefused)
                return std.fmt.allocPrint(arena, "error: MCP server {s} refused {s}: {s}", .{ server.name, call_.tool.exposed, server.last_error });
            return std.fmt.allocPrint(arena, "error: MCP server {s} did not answer {s} ({s})", .{ server.name, call_.tool.exposed, @errorName(err) });
        };
        return resultText(arena, server.name, result);
    }

    /// Closes every connection: stdin first, so a server that is waiting for
    /// more input sees end of stream and can exit on its own, then the whole
    /// process group, so one that does not is not left behind.
    pub fn shutdown(self: *Servers, io: Io) void {
        for (self.items) |*server| {
            // The child's own cleanup closes stdin as well, so the handle is
            // handed over by clearing the field rather than closed twice: a
            // second close of the same descriptor is a use-after-free the
            // runtime traps on. `to_server` keeps the dead handle, and nothing
            // sends on it after this.
            if (server.child.stdin) |stdin| {
                stdin.close(io);
                server.child.stdin = null;
            }
            server.reap(io);
        }
    }
};

/// What a `tools/call` result says, as the model reads it: the text blocks in
/// order, and a note for a block that is not text. An `isError` result keeps
/// its text and says the server called it an error, because the model decides
/// what to do next and a server's own failure often quotes the reason.
fn resultText(arena: std.mem.Allocator, server_name: []const u8, result: std.json.Value) ![]const u8 {
    const object = switch (result) {
        .object => |o| o,
        else => return std.fmt.allocPrint(arena, "error: MCP server {s} answered with {s}, not a result object", .{ server_name, @tagName(result) }),
    };
    var buf: std.ArrayList(u8) = .empty;
    const content = object.get("content") orelse {
        if (object.get("structuredContent")) |value| return std.json.Stringify.valueAlloc(arena, value, .{});
        return "error: MCP result carried no content";
    };
    const items = switch (content) {
        .array => |a| a.items,
        else => &[_]std.json.Value{},
    };
    // The text stops at the ceiling the caller clamps a tool result to, while
    // it is built rather than after it: a server that answers with a megabyte
    // was otherwise copied into the turn whole and clamped a moment later, so
    // the copy, the clamp and the bytes in between were all work over text
    // nobody keeps. The note below is the caller's own wording, written here
    // because this is the side that knows the size the whole text would have.
    const cap = tool_mod.max_tool_output;
    const note_room = 128;
    var total: usize = 0;
    var started = false;
    for (items) |item| {
        const entry = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const kind = chat.str(entry.get("type")) orelse "";
        const piece = if (std.mem.eql(u8, kind, "text"))
            (chat.str(entry.get("text")) orelse continue)
        else
            try std.fmt.allocPrint(arena, "[{s} content from MCP server {s}, not shown]", .{ kind, server_name });
        total += piece.len + @intFromBool(started);
        if (buf.items.len < cap) {
            if (started) try buf.append(arena, '\n');
            const room = cap - buf.items.len;
            try buf.appendSlice(arena, piece[0..@min(piece.len, room)]);
        }
        started = true;
    }
    if (object.get("isError")) |flag| switch (flag) {
        .bool => |is_error| if (is_error) {
            const suffix = "\n(the MCP server marked this result an error)";
            total += suffix.len;
            const room = cap -| buf.items.len;
            try buf.appendSlice(arena, suffix[0..@min(suffix.len, room)]);
        },
        else => {},
    };
    if (total == 0) return "(the MCP server returned no text)";
    if (total > cap) {
        // `note_room` bytes short of the cap, so the note survives the caller's
        // own clamp with the cap and the true size it names.
        const kept = chat.clamp(buf.items, cap - note_room);
        return std.fmt.allocPrint(arena, "{s}\n... [tool output truncated at {d} of {d} bytes]", .{ kept, cap, total });
    }
    return buf.items;
}

/// A JSON-RPC error value as a line: its message, with the code when there is
/// one, and the whole value when it is not an object. A server's error text is
/// untrusted too, so it is escaped before it reaches a tool result the model
/// reads and a gutter line the operator reads.
fn describeError(arena: std.mem.Allocator, value: std.json.Value) ![]const u8 {
    const object = switch (value) {
        .object => |o| o,
        else => return chat.safeTextAll(arena, try std.json.Stringify.valueAlloc(arena, value, .{})),
    };
    const message = chat.str(object.get("message")) orelse "no message";
    if (object.get("code")) |code| switch (code) {
        .integer => |n| return std.fmt.allocPrint(arena, "{s} (code {d})", .{ chat.safeText(arena, message, max_description_bytes), n }),
        else => {},
    };
    return chat.safeText(arena, message, max_description_bytes);
}

/// One server out of the config file: one `[[mcp]]` table.
pub const Entry = struct {
    name: []const u8,
    command: []const u8,
    args: []const []const u8 = &.{},
    env: []const [2][]const u8 = &.{},
};

/// Whether a name can be half of an exposed tool name: the letters, digits,
/// dot, dash and underscore a tool name may hold, with no `__` in it, because
/// that pair is what separates the three parts of an exposed name. The config
/// reader holds a server's name to the same rule, since it is half of every
/// name that server's tools are offered under.
pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > max_name_bytes) return false;
    if (std.mem.indexOf(u8, name, "__") != null) return false;
    for (name) |c| {
        const ok = std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.';
        if (!ok) return false;
    }
    return true;
}

/// Connects to every server the config declared, in the order the tables
/// appeared. An entry that cannot run, or that fails its handshake, is said on
/// stderr and skipped, because a server the operator wrote down and this run
/// does not connect to is a silent no-op otherwise.
pub fn connect(
    io: Io,
    arena: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
    entries: []const Entry,
    client_version: []const u8,
) Servers {
    // Every server is started before any of them is asked to initialize. What
    // a handshake mostly waits for is the server's own boot -- `npx` resolving
    // a package, a node or python interpreter coming up -- and that is the
    // server's work, not a message the client is waiting on. Started one at a
    // time, N servers cost the sum of their boot times before the run can send
    // its first request; started together, they cost the slowest one. The
    // handshakes then run in order, so the tool list, the notes and which
    // server answers for a name all keep the order the file wrote.
    var spawned: std.ArrayList(Server) = .empty;
    for (entries) |entry| spawnOne(io, arena, environ_map, entry, &spawned);

    var connected: std.ArrayList(Server) = .empty;
    for (spawned.items) |*server| {
        if (!handshake(io, arena, server, client_version)) {
            net.note(io, arena, "microagent: MCP server {s}: {s}; it is skipped\n", .{
                chat.safeTextAll(arena, server.name),
                server.last_error,
            });
            server.reap(io);
            continue;
        }
        connected.append(arena, server.*) catch server.reap(io);
    }
    return .{ .items = connected.items };
}

/// Starts one server and records it, whether or not it will answer: the
/// handshake runs later, over the whole list, so one server's boot overlaps
/// the next one's. A server that cannot be spawned is named and left out.
fn spawnOne(
    io: Io,
    arena: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
    entry: Entry,
    out: *std.ArrayList(Server),
) void {
    const shown = chat.safeTextAll(arena, entry.name);
    var argv: std.ArrayList([]const u8) = .empty;
    argv.append(arena, entry.command) catch return;
    argv.appendSlice(arena, entry.args) catch return;

    // The server inherits the scrubbed environment the tool children get --
    // the provider key is not in it -- plus whatever the entry names, which is
    // how a server is handed its own configuration.
    var env: std.process.Environ.Map = .init(arena);
    var it = environ_map.iterator();
    while (it.next()) |pair| env.put(pair.key_ptr.*, pair.value_ptr.*) catch return;
    for (entry.env) |pair| env.put(pair[0], pair[1]) catch return;

    const child = std.process.spawn(io, .{
        .argv = argv.items,
        // Its own group, so the whole tree is signalled on the way out the way
        // every other child this program spawns is.
        .pgid = 0,
        .stdin = .pipe,
        .stdout = .pipe,
        // Inherited on purpose: it is where an MCP server writes its own
        // diagnostics, and a pipe nobody drains is a server that blocks.
        .stderr = .inherit,
        .environ_map = &env,
    }) catch |err| {
        net.note(io, arena, "microagent: MCP server {s}: cannot run {s}: {s}; it is skipped\n", .{ shown, chat.safeTextAll(arena, entry.command), @errorName(err) });
        return;
    };

    var server: Server = .{
        .name = entry.name,
        .child = child,
        .pgid = @intCast(child.id.?),
        .to_server = child.stdin.?,
        .from_server = child.stdout.?,
        .tools = &.{},
    };
    out.append(arena, server) catch server.reap(io);
}

/// The three frames a usable connection is made of: `initialize`, the
/// initialized notification, and `tools/list`. False with `server.last_error`
/// set when any of them fails.
fn handshake(io: Io, arena: std.mem.Allocator, server: *Server, client_version: []const u8) bool {
    const timeout = net.durationMs(handshake_timeout_ms);
    // Both answers are parsed here and nothing but the tool table survives
    // them, so they are parsed in an arena that is handed back at the end of
    // the handshake rather than in the run's. A megabyte of schema text turns
    // into several megabytes of parsed values, and the run does not read any
    // of them: it copies the schema bytes into the request as they came.
    var scratch_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();
    // The version is this build's own, from build.zig.zon: it holds no byte
    // that needs escaping in a JSON string, so it is written as it is.
    var params_buf: [256]u8 = undefined;
    const init_params = std.fmt.bufPrint(&params_buf, "{{\"protocolVersion\":\"{s}\",\"capabilities\":{{}},\"clientInfo\":{{\"name\":\"microagent\",\"version\":\"{s}\"}}}}", .{
        protocol_version,
        client_version,
    }) catch "{\"protocolVersion\":\"" ++ protocol_version ++ "\",\"capabilities\":{},\"clientInfo\":{\"name\":\"microagent\"}}";
    const initialized = server.request(io, arena, scratch, "initialize", init_params, timeout) catch return false;
    if (initialized != .object) {
        server.last_error = "initialize answered with no result object";
        return false;
    }
    server.send(io, arena, null, "notifications/initialized", "") catch |err| {
        server.last_error = @errorName(err);
        return false;
    };
    const listed = server.request(io, arena, scratch, "tools/list", "", timeout) catch return false;
    const object = switch (listed) {
        .object => |o| o,
        else => {
            server.last_error = "tools/list answered with no result object";
            return false;
        },
    };
    const tools: []std.json.Value = if (object.get("tools")) |value| switch (value) {
        .array => |a| a.items,
        else => &.{},
    } else &.{};
    var found: std.ArrayList(Tool) = .empty;
    for (tools) |item| {
        const entry = switch (item) {
            .object => |o| o,
            else => continue,
        };
        // The name is the one slice of the answer the tool table keeps, so it
        // is copied out of the arena the answer is parsed in.
        const name = chat.str(entry.get("name")) orelse continue;
        const kept_name = arena.dupe(u8, name) catch return false;
        if (!validName(name)) {
            net.note(io, arena, "microagent: MCP server {s} offers a tool named {s}, which cannot be spelled in a tool name; it is skipped\n", .{ chat.safeTextAll(arena, server.name), chat.safeText(arena, name, 120) });
            continue;
        }
        const description = chat.str(entry.get("description")) orelse "";
        // Stringify grows through a ladder of buffers and only the last one is
        // the schema the request carries, so it is built in the scratch arena
        // and copied once into the run's.
        const schema_text = schemaJson(scratch, entry.get("inputSchema")) catch return false;
        const schema = arena.dupe(u8, schema_text) catch return false;
        const exposed = std.fmt.allocPrint(arena, "{s}{s}__{s}", .{ tool_prefix, server.name, kept_name }) catch return false;
        found.append(arena, .{
            .name = kept_name,
            .exposed = exposed,
            .description = if (description.len == 0)
                std.fmt.allocPrint(arena, "MCP tool '{s}' from server '{s}'", .{ name, server.name }) catch return false
            else
                chat.safeText(arena, description, max_description_bytes),
            .schema = schema,
        }) catch return false;
    }
    server.tools = found.items;
    return true;
}

/// A tool's `inputSchema` as the request carries it: the server's own bytes
/// when they are an object, and an empty object schema when they are not.
/// A tool with no schema still has to be callable, and a provider refuses an
/// entry whose `parameters` is not an object.
fn schemaJson(arena: std.mem.Allocator, value: ?std.json.Value) ![]const u8 {
    const v = value orelse return "{\"type\":\"object\"}";
    if (v != .object) return "{\"type\":\"object\"}";
    return std.json.Stringify.valueAlloc(arena, v, .{});
}

// The fake server the connection tests drive. It answers the three calls a
// handshake and one tool call make, with the ids this client assigns them in
// that order, and it reads its stdin the way a real server does: one line at a
// time until end of stream. `sed` and `jq` are not assumed, so the frame is a
// fixed line rather than an echo of the request.
const fake_server =
    \\while IFS= read -r line; do
    \\  case "$line" in
    \\    *'"method":"initialize"'*)
    \\      printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18","capabilities":{"tools":{}},"serverInfo":{"name":"fake","version":"1"}}}' ;;
    \\    *'"method":"tools/list"'*)
    \\      printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"echo","description":"Echo text back","inputSchema":{"type":"object","properties":{"text":{"type":"string"}},"required":["text"]}}]}}' ;;
    \\    *'"method":"tools/call"'*)
    \\      printf '%s\n' '{"jsonrpc":"2.0","id":3,"result":{"content":[{"type":"text","text":"pong"}]}}' ;;
    \\  esac
    \\done
;

// The handshake is skipped when it is only half-checked: the schema entry, the
// resolved call and the text that comes back are the three things a connected
// server owes the run, so one test drives all of them through a real child.
test "a configured server is connected, listed and called" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const arena = state.allocator();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "server.sh", .data = fake_server });
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = path_buf[0..try tmp.dir.realPath(io, &path_buf)];
    const script = try std.fs.path.join(arena, &.{ base, "server.sh" });

    var env: std.process.Environ.Map = .init(arena);
    const entries = [_]Entry{.{ .name = "fake", .command = "/bin/sh", .args = &.{script} }};
    var servers = connect(io, arena, &env, &entries, "test");
    defer servers.shutdown(io);

    try std.testing.expectEqual(@as(usize, 1), servers.items.len);
    try std.testing.expectEqual(@as(usize, 1), servers.toolCount());
    try std.testing.expectEqualStrings("mcp__fake__echo", servers.items[0].tools[0].exposed);

    const schema = try servers.toolsJson(arena);
    try std.testing.expect(std.mem.indexOf(u8, schema, "\"name\":\"mcp__fake__echo\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "\"description\":\"Echo text back\"") != null);
    // The server's own inputSchema reaches the request verbatim.
    try std.testing.expect(std.mem.indexOf(u8, schema, "\"required\":[\"text\"]") != null);

    const resolved = servers.resolve("mcp__fake__echo").?;
    try std.testing.expectEqualStrings("echo", resolved.tool.name);
    try std.testing.expect(servers.resolve("mcp__fake__nope") == null);
    try std.testing.expectEqualStrings("pong", try Servers.call(io, arena, resolved, "{\"text\":\"hi\"}", net.durationMs(10_000)));

    // An argument payload that is not JSON is refused here, before it reaches
    // the server as a malformed frame.
    try std.testing.expectEqualStrings("error: tool arguments are not valid JSON", try Servers.call(io, arena, resolved, "{", net.durationMs(10_000)));
}

// A handshake mostly waits for the server's own boot, so the run starts every
// server before it asks any of them to initialize. This pins that property
// without a clock: `waiter` refuses to answer until `starter` has run, and the
// starter is only spawned once the waiter's handshake is over unless the two
// boots overlap. Sequential connects skip the waiter (its bounded wait runs
// out and it exits), so the test asserts two servers rather than one.
test "every server is started before any of them is asked to initialize" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const arena = state.allocator();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = path_buf[0..try tmp.dir.realPath(io, &path_buf)];

    try tmp.dir.writeFile(io, .{ .sub_path = "responder.sh", .data = fake_server });
    const waiter = try std.fmt.allocPrint(arena,
        \\i=0
        \\while [ ! -f "{s}/started" ] && [ "$i" -lt 40 ]; do i=$((i+1)); sleep 0.05; done
        \\[ -f "{s}/started" ] || exit 1
        \\exec /bin/sh "{s}/responder.sh"
        \\
    , .{ base, base, base });
    const starter = try std.fmt.allocPrint(arena,
        \\touch "{s}/started"
        \\exec /bin/sh "{s}/responder.sh"
        \\
    , .{ base, base });
    try tmp.dir.writeFile(io, .{ .sub_path = "waiter.sh", .data = waiter });
    try tmp.dir.writeFile(io, .{ .sub_path = "starter.sh", .data = starter });

    const waiter_path = try std.fs.path.join(arena, &.{ base, "waiter.sh" });
    const starter_path = try std.fs.path.join(arena, &.{ base, "starter.sh" });
    const entries = [_]Entry{
        .{ .name = "waiter", .command = "/bin/sh", .args = &.{waiter_path} },
        .{ .name = "starter", .command = "/bin/sh", .args = &.{starter_path} },
    };
    var env: std.process.Environ.Map = .init(arena);
    var servers = connect(io, arena, &env, &entries, "test");
    defer servers.shutdown(io);

    try std.testing.expectEqual(@as(usize, 2), servers.items.len);
    try std.testing.expect(servers.resolve("mcp__waiter__echo") != null);
    try std.testing.expect(servers.resolve("mcp__starter__echo") != null);
}

// A tools/call answer is built up to the cap the caller clamps a tool result
// to, not whole: the text past it is discarded a moment later, so copying it
// into the turn and clamping it there is work over bytes nobody keeps. The
// note carries the size the whole text would have had, which is why the build
// counts instead of appending.
test "a tools/call answer is built up to the result cap, not whole" {
    const gpa = std.testing.allocator;
    var scratch_state = std.heap.ArenaAllocator.init(gpa);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();
    var run_state = std.heap.ArenaAllocator.init(gpa);
    defer run_state.deinit();
    const run = run_state.allocator();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = path_buf[0..try tmp.dir.realPath(io, &path_buf)];

    const pad = try scratch.alloc(u8, 400 * 1024);
    @memset(pad, 'x');
    const script = try std.fmt.allocPrint(scratch,
        \\while IFS= read -r line; do
        \\  case "$line" in
        \\    *'"method":"initialize"'*) printf '%s\n' '{{"jsonrpc":"2.0","id":1,"result":{{"protocolVersion":"{s}","capabilities":{{}},"serverInfo":{{"name":"big","version":"1"}}}}}}' ;;
        \\    *'"method":"tools/list"'*) printf '%s\n' '{{"jsonrpc":"2.0","id":2,"result":{{"tools":[{{"name":"echo","inputSchema":{{"type":"object"}}}}]}}}}' ;;
        \\    *'"method":"tools/call"'*) printf '{{"jsonrpc":"2.0","id":3,"result":{{"content":[{{"type":"text","text":"{s}"}}]}}}}\n' ;;
        \\  esac
        \\done
        \\
    , .{ protocol_version, pad });
    try tmp.dir.writeFile(io, .{ .sub_path = "big.sh", .data = script });
    const path = try std.fs.path.join(scratch, &.{ base, "big.sh" });

    const entries = [_]Entry{.{ .name = "big", .command = "/bin/sh", .args = &.{path} }};
    var env: std.process.Environ.Map = .init(scratch);
    var servers = connect(io, run, &env, &entries, "test");
    defer servers.shutdown(io);
    const remote = servers.resolve("mcp__big__echo") orelse return error.TestUnexpectedResult;

    const text = try Servers.call(io, run, remote, "{}", net.durationMs(10_000));
    try std.testing.expect(text.len <= tool_mod.max_tool_output);
    try std.testing.expect(std.mem.indexOf(u8, text, "... [tool output truncated at") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, try std.fmt.allocPrint(scratch, "of {d} bytes]", .{pad.len})) != null);
    // The run keeps the capped text, not the answer it was cut from.
    // Half a megabyte is the bound: the capped text plus the arena's own
    // granularity comes to about 264 KB, and building the whole 400 KB answer
    // first came to about 1 MB.
    try std.testing.expect(run_state.queryCapacity() < 512 * 1024);
}

// A tools/list answer is the largest document this program reads, and its
// parsed tree is several times the size of its text. What the run keeps is the
// schema bytes the request carries, copied out of the answer; the line the
// answer arrived in and the tree it was parsed into are handed back. The two
// counters below fail if either comes back: the run arena would hold the tree,
// and the pending buffer would keep the answer's size for the whole run.
test "a tools/list answer is parsed in a scratch arena and its buffer is handed back" {
    const gpa = std.testing.allocator;
    var scratch_state = std.heap.ArenaAllocator.init(gpa);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();
    var run_state = std.heap.ArenaAllocator.init(gpa);
    defer run_state.deinit();
    const run = run_state.allocator();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = path_buf[0..try tmp.dir.realPath(io, &path_buf)];

    const pad = try scratch.alloc(u8, 400 * 1024);
    @memset(pad, 'x');
    const script = try std.fmt.allocPrint(scratch,
        \\while IFS= read -r line; do
        \\  case "$line" in
        \\    *'"method":"initialize"'*) printf '%s\n' '{{"jsonrpc":"2.0","id":1,"result":{{"protocolVersion":"{s}","capabilities":{{}},"serverInfo":{{"name":"big","version":"1"}}}}}}' ;;
        \\    *'"method":"tools/list"'*) printf '{{"jsonrpc":"2.0","id":2,"result":{{"tools":[{{"name":"echo","inputSchema":{{"type":"object","description":"{s}"}}}}]}}}}\n' ;;
        \\  esac
        \\done
        \\
    , .{ protocol_version, pad });
    try tmp.dir.writeFile(io, .{ .sub_path = "big.sh", .data = script });
    const path = try std.fs.path.join(scratch, &.{ base, "big.sh" });

    const entries = [_]Entry{.{ .name = "big", .command = "/bin/sh", .args = &.{path} }};
    var env: std.process.Environ.Map = .init(scratch);
    var servers = connect(io, run, &env, &entries, "test");
    defer servers.shutdown(io);

    try std.testing.expectEqual(@as(usize, 1), servers.items.len);
    try std.testing.expect(servers.resolve("mcp__big__echo") != null);
    try std.testing.expectEqual(@as(usize, 0), servers.items[0].pending.capacity);
    try std.testing.expect(run_state.queryCapacity() < 1024 * 1024);
}

test "a server that cannot be started, or that exits, is skipped" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const arena = state.allocator();
    const io = std.testing.io;

    var env: std.process.Environ.Map = .init(arena);
    const missing = [_]Entry{.{ .name = "gone", .command = "definitely-not-a-real-command-xyz" }};
    var none = connect(io, arena, &env, &missing, "test");
    defer none.shutdown(io);
    try std.testing.expectEqual(@as(usize, 0), none.items.len);

    // A child that exits before answering leaves nothing to resolve, and the
    // run keeps the servers it did connect.
    const exits = [_]Entry{.{ .name = "exit", .command = "/bin/sh", .args = &.{ "-c", "exit 0" } }};
    var gone = connect(io, arena, &env, &exits, "test");
    defer gone.shutdown(io);
    try std.testing.expectEqual(@as(usize, 0), gone.items.len);
}

// The frames below are the answers an MCP server writes on its stdout, in the
// shape the model context protocol publishes: an `initialize` result, a
// `tools/list` result, a `tools/call` result with text and with structured
// content, a protocol error, and the malformed ones a broken server writes
// instead. `std.testing.fuzz` runs them through the harness on every
// `zig build test`, and through the fuzzer's mutations when the test binary is
// built in fuzz mode.
const frame_corpus = [_][]const u8{
    "{}",
    "[]",
    "null",
    "42",
    "\"text\"",
    "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}",
    "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{\"tools\":{}},\"serverInfo\":{\"name\":\"fake\",\"version\":\"1\"}}}",
    "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"tools\":[{\"name\":\"echo\",\"description\":\"Echo text back\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"text\":{\"type\":\"string\"}},\"required\":[\"text\"]}}]}}",
    "{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"pong\"}]}}",
    "{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"one\"},{\"type\":\"image\",\"data\":\"x\"}],\"isError\":true}}",
    "{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"structuredContent\":{\"n\":1}}}",
    "{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"content\":[]}}",
    "{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"content\":{}}}",
    "{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"content\":[{},\"x\",null,{\"type\":\"text\"}]}}",
    "{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"\"}],\"isError\":false}}",
    "{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"a\"}],\"isError\":\"yes\"}}",
    "{\"jsonrpc\":\"2.0\",\"id\":4,\"error\":{\"code\":-32601,\"message\":\"Method not found\"}}",
    "{\"jsonrpc\":\"2.0\",\"id\":4,\"error\":{\"message\":\"line\\n\\u001b[2Jignored\"}}",
    "{\"jsonrpc\":\"2.0\",\"id\":4,\"error\":{\"code\":\"-32601\"}}",
    "{\"jsonrpc\":\"2.0\",\"id\":4,\"error\":\"plain refusal\"}",
    "{\"jsonrpc\":\"2.0\",\"id\":4,\"error\":[1,2]}",
    "{\"jsonrpc\":\"2.0\",\"id\":4,\"error\":{}}",
    "{\"jsonrpc\":\"2.0\",\"id\":9223372036854775807,\"result\":{}}",
    "{\"jsonrpc\":\"2.0\",\"id\":1.5,\"result\":{}}",
    "{\"result\":{}}",
    "not json at all",
    "{\"content\":[{\"type\":\"text\",\"text\":\"a\\ud83d\\ude00b\"}]}",
    "{\"content\":[{\"type\":\"text\",\"text\":\"\\u0000\\u001b[31mred\\u001b[0m\"}]}",
};

// What a server writes is read by the same two steps a live connection takes:
// the line is parsed as JSON, and the object it holds is read for its `result`
// and its `error`. `std.testing.fuzz` runs this corpus on every
// `zig build test`, and through the fuzzer's mutations when the test binary is
// built in fuzz mode. A server is a child process the operator configured, so
// its stdout is as untrusted as anything off the network: the text it carries
// is built up to the result cap, escaped into a tool result, and read by the
// model and the operator.
test "a fuzzed MCP frame becomes a tool result inside the cap the caller clamps to" {
    try std.testing.fuzz({}, fuzzFrame, .{ .corpus = &frame_corpus });
}

fn fuzzFrame(_: void, smith: *std.testing.Smith) !void {
    var raw: [16 * 1024]u8 = undefined;
    const bytes: []const u8 = if (smith.in) |seed| seed else raw[0..smith.slice(&raw)];

    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const arena = state.allocator();

    // Bytes that are not a frame are what a server writes when it is broken,
    // and a live connection skips them and reads the next line. A fuzzer that
    // only ever produced valid JSON would never reach the text arithmetic with
    // a piece of a length nobody chose, so unparseable bytes are carried as the
    // text of a result frame and the same reader runs over them.
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{}) catch
        try std.json.parseFromSliceLeaky(std.json.Value, arena, try carriedFrame(arena, bytes), .{});
    const object = switch (parsed) {
        .object => |o| o,
        else => return,
    };

    if (object.get("error")) |value| {
        const described = try describeError(arena, value);
        // A server's refusal is read by the model and by the operator's
        // terminal, and nothing a terminal acts on survives the escaper.
        try std.testing.expect(described.len > 0);
        try std.testing.expect(std.mem.indexOf(u8, described, "\x1b") == null);
        // A refusal with a message is bounded at the description ceiling, and
        // the code is added to it rather than displacing it.
        if (value == .object and value.object.get("message") != null)
            try std.testing.expect(described.len <= max_description_bytes + 32);
    }

    const result = object.get("result") orelse return;
    // A result with no content is the structured one, and it is copied out as
    // the server wrote it rather than under the cap, so the cap is asked of
    // the text path only.
    if (result != .object or result.object.get("content") == null) return;
    const text = try resultText(arena, "srv", result);
    try std.testing.expect(text.len <= tool_mod.max_tool_output);
    // Where the text was cut, the note names the cap the caller clamps with and
    // the size the whole text would have had, and the second is past the first
    // or the cut happened for nothing.
    const marker = "... [tool output truncated at ";
    if (std.mem.indexOf(u8, text, marker)) |at| {
        const rest = text[at + marker.len ..];
        const of_at = std.mem.indexOf(u8, rest, " of ") orelse return error.TestUnexpectedResult;
        const cap_at = std.fmt.parseInt(u64, rest[0..of_at], 10) catch return error.TestUnexpectedResult;
        const after = rest[of_at + " of ".len ..];
        const bytes_at = std.mem.indexOfScalar(u8, after, ' ') orelse return error.TestUnexpectedResult;
        const total = std.fmt.parseInt(u64, after[0..bytes_at], 10) catch return error.TestUnexpectedResult;
        try std.testing.expectEqual(tool_mod.max_tool_output, cap_at);
        try std.testing.expect(total > cap_at);
        try std.testing.expect(std.mem.endsWith(u8, text, "bytes]"));
    }
}

/// A result frame carrying `bytes` as its text, escaped as JSON. A piece of
/// text of any shape then reaches the reader that builds the tool result.
fn carriedFrame(arena: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    var jb = chat.JsonBuf.init(arena);
    const w = jb.writer();
    try w.writeAll("{\"result\":{\"content\":[{\"type\":\"text\",\"text\":");
    try chat.writeJsonString(w, bytes);
    try w.writeAll("}]}}");
    return jb.items();
}

test "a non-text result block is named rather than dropped" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const arena = state.allocator();

    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\{"content":[{"type":"text","text":"one"},{"type":"image","data":"x"}],"isError":true}
    , .{});
    const text = try resultText(arena, "srv", parsed);
    try std.testing.expect(std.mem.indexOf(u8, text, "one") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "[image content from MCP server srv, not shown]") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "marked this result an error") != null);

    const structured = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"structuredContent\":{\"n\":1}}", .{});
    try std.testing.expectEqualStrings("{\"n\":1}", try resultText(arena, "srv", structured));
}
