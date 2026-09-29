//! MCP servers: tools the run reaches over a child process's stdin and stdout,
//! or over HTTP.
//!
//! A Model Context Protocol server speaks JSON-RPC 2.0. A local one is a child
//! process, one JSON object per line on its pipes; a remote one is a
//! streamable-HTTP endpoint, one POST per object, answered as a JSON body or as
//! an event stream. This connects to the ones a config file names, asks each for
//! its tool list, and exposes every tool to the provider under
//! `mcp__<server>__<tool>`. A call is a `tools/call` request; the text the
//! server returns is the tool result, exactly as a built-in's output is. The
//! two transports differ only in how a frame travels: ids, the handshake, the
//! tool table and the reading of a result are the same code.
//!
//! Where the servers come from is `config.zig`: one `[[mcp]]` table in the run's
//! TOML config, or one `[tools.<preset>]` switched on, read into an `Entry` per
//! server, so this module only speaks the protocol and never reads a config
//! file. A remote entry's key is looked up by `withKeys`, from the environment
//! as it came.
//!
//! A server that cannot be started or reached, or that fails the handshake, is
//! reported on stderr and skipped: one broken entry costs the run that entry,
//! not the run. The same is true of a tool whose name cannot be spelled in the
//! schema, and of a call that times out -- the answer is an error string the
//! model reads, which is how every other tool failure reaches it. What a remote
//! server sends is as untrusted as what a local one does, and passes through the
//! same readers and caps.
//!
//! A local server's own stderr is inherited rather than captured: it is where an
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
/// The revision spoken over HTTP, which is the one the public streamable-HTTP
/// servers are known to accept, and the one named in `MCP-Protocol-Version`
/// after `initialize`.
const http_protocol_version = "2025-03-26";
/// One read of a response body, and the transfer buffer the body reader is
/// given. Both are small because the body is consumed as it arrives.
const http_read_chunk_bytes: usize = 8 * 1024;
const http_transfer_bytes: usize = 4 * 1024;
/// The longest `Mcp-Session-Id` echoed back. A server's own is a UUID or a
/// JWT; past this it is not a value this run sends on every request.
const max_session_id_bytes: usize = 512;
/// The longest server or tool name this run spells into a tool name. The
/// provider sees the whole of it, and the model types it back.
const max_name_bytes: usize = 64;
/// The longest server description kept. A description is what the model picks
/// a tool by, and every later turn pays for it.
const max_mcp_description_bytes: usize = 1024;
/// The bytes an untrusted name is escaped to before it reaches a gutter line
/// the operator reads or a note on stderr. Long enough for a name to be
/// recognized, short enough that a name chosen to be long cannot fill the
/// terminal.
const max_shown_name_bytes: usize = 120;
/// The most bytes one tool's `inputSchema` contributes to the request. A
/// description is bounded because it is a sentence; a schema is whatever the
/// server chose to serialize, and a server that embeds a large `description`,
/// `examples` or `enum` in it wrote megabytes into the constant prefix of every
/// request this run makes, for the whole run. Past this the tool is advertised
/// with the empty object schema rather than the server's own, which is the
/// shape a tool with no schema already gets: the model sees a tool whose
/// arguments it has to infer, rather than a run billed for a schema nobody
/// reads.
const max_schema_bytes: usize = 16 * 1024;
/// What a schema past the ceiling above is replaced with, and the shape a tool
/// with no schema is already advertised under. The `description` is the model's
/// warning that the server's own schema is not here, so a tool it finds no
/// arguments for is one this run cut rather than one the server described
/// badly.
const omitted_schema_json =
    \\{"type":"object","description":"The MCP server sent a schema too large to send (over 16 KB), so the arguments are not described here. Ask the operator what this tool takes."}
;

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
    transport: Transport,
    next_id: u64 = 1,
    tools: []const Tool,
    /// Why the last request failed, when it did. Set and read by `request`
    /// and the caller that formats the error, which is why it is a field and
    /// not a returned union: a JSON-RPC error is a message, not a variant.
    last_error: []const u8 = "",
    /// A server that exited or timed out is not asked again. The first failure
    /// already cost the call its deadline; the second would cost another.
    dead: bool = false,
    /// A preset this run has not spoken to: its tools came from the table in
    /// this binary, so the first request carries them without a handshake, and
    /// the server is asked for its own list the first time one is called.
    lazy: bool = false,
    /// This build's version, kept for a handshake that happens after `connect`.
    client_version: []const u8 = "",

    /// How the server is reached. Both carry the same JSON-RPC frames, and
    /// everything above the transport (ids, the handshake, the tool table,
    /// reading a result) is shared.
    pub const Transport = union(enum) {
        stdio: Stdio,
        http: Http,
    };

    /// A child process, one JSON object per line on its pipes.
    pub const Stdio = struct {
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
    };

    /// A streamable-HTTP endpoint: one POST per frame, the answer in the
    /// response body. The connection is the client's, pooled and shared with
    /// the provider path, so nothing here holds a socket between requests.
    pub const Http = struct {
        client: *std.http.Client,
        /// Borrows from the config entry's url, which lives as long as the run.
        uri: std.Uri,
        /// The header the key travels in and its whole value, both empty when
        /// the server needs no key.
        key_header: []const u8 = "",
        key_value: []const u8 = "",
        /// The longest one request may take, from the first byte sent to the
        /// last one read.
        timeout_ms: u64,
        /// The `Mcp-Session-Id` the server assigned on `initialize`, sent back
        /// on every later request. Empty for a server that assigns none.
        session_id: []const u8 = "",
        /// Set once `initialize` is answered: from then on every request
        /// names the protocol revision in use.
        negotiated: bool = false,
    };

    fn reap(self: *Server, io: Io) void {
        const stdio = switch (self.transport) {
            .stdio => |*s| s,
            .http => return,
        };
        tool_mod.retireChildGroup(stdio.pgid);
        std.posix.kill(-stdio.pgid, .KILL) catch {};
        stdio.child.kill(io);
        // The buffer is this allocator's, not the arena's, so it is handed
        // back here rather than with the run.
        stdio.pending.deinit(pending_allocator);
    }

    /// One JSON-RPC frame without its terminator: a request when `id` is set,
    /// a notification when it is not.
    fn writeFrame(w: *Io.Writer, id: ?u64, method: []const u8, params_json: []const u8) !void {
        try w.writeAll("{\"jsonrpc\":\"2.0\"");
        if (id) |n| try w.print(",\"id\":{d}", .{n});
        try w.writeAll(",\"method\":");
        try chat.writeJsonString(w, method);
        if (params_json.len != 0) {
            try w.writeAll(",\"params\":");
            try w.writeAll(params_json);
        }
        try w.writeAll("}");
    }

    /// Sends one frame. Over stdio that is the write; over HTTP it is the
    /// whole POST, so an id-less frame is a notification the server has
    /// accepted by the time this returns.
    fn send(self: *Server, io: Io, arena: std.mem.Allocator, id: ?u64, method: []const u8, params_json: []const u8) !void {
        switch (self.transport) {
            .stdio => |*stdio| {
                var jb = chat.JsonBuf.init(arena);
                const w = jb.writer();
                try writeFrame(w, id, method, params_json);
                try w.writeAll("\n");
                stdio.to_server.writeStreamingAll(io, jb.items()) catch |err| {
                    self.last_error = @errorName(err);
                    return err;
                };
            },
            .http => |*http| _ = try self.post(io, arena, arena, http, id, method, params_json, net.durationMs(http.timeout_ms)),
        }
    }

    /// The next line the server wrote, held across reads. `error.Timeout` from
    /// the deadline and `error.ServerGone` from its end of the pipe are the
    /// two ways this fails, and both leave the server marked dead by the
    /// caller's error path.
    fn readLine(stdio: *Stdio, io: Io, line_arena: std.mem.Allocator, deadline: Io.Timeout) ![]u8 {
        // Only the bytes appended since the last look can hold the newline, so
        // the scan resumes where it stopped. Restarting it at the front re-reads
        // the whole buffer once per chunk, which is quadratic in a line that
        // arrives in many chunks: a one megabyte `tools/list` answer is 128
        // reads, and the scans before this add up to about 66 megabytes of the
        // same bytes. `net.nextLineEnd` is the cursor the streaming reader and
        // the ranged read keep.
        var scanned: usize = 0;
        while (true) {
            if (net.nextLineEnd(stdio.pending.items, &scanned)) |at| {
                const line = try line_arena.dupe(u8, stdio.pending.items[0..at]);
                const rest = stdio.pending.items.len - (at + 1);
                std.mem.copyForwards(u8, stdio.pending.items[0..rest], stdio.pending.items[at + 1 ..]);
                stdio.pending.shrinkRetainingCapacity(rest);
                if (stdio.pending.capacity > pending_keep_bytes and rest <= pending_keep_bytes)
                    stdio.pending.shrinkAndFree(pending_allocator, rest);
                return line;
            }
            if (stdio.pending.items.len > max_frame_bytes) return error.FrameTooLong;
            var chunk: [http_read_chunk_bytes]u8 = undefined;
            var vec: [1][]u8 = .{&chunk};
            var storage: [1]Io.Operation.Storage = undefined;
            var batch: Io.Batch = .init(&storage);
            defer batch.cancel(io);
            batch.addAt(0, .{ .file_read_streaming = .{ .file = stdio.from_server, .data = &vec } });
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
                if (n > 0) try stdio.pending.appendSlice(pending_allocator, chunk[0..n]);
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
        const id = self.next_id;
        self.next_id += 1;
        switch (self.transport) {
            .http => |*http| return (try self.post(io, arena, scratch, http, id, method, params_json, timeout)).?,
            .stdio => {},
        }
        const deadline = timeout.toDeadline(io);
        try self.send(io, arena, id, method, params_json);
        while (true) {
            const line = readLine(&self.transport.stdio, io, scratch, deadline) catch |err| {
                self.last_error = @errorName(err);
                self.dead = true;
                return err;
            };
            if (try self.answerFor(arena, scratch, line, id)) |result| return result;
        }
    }

    /// What one frame says about request `id`: its result, or null when the
    /// frame is anything else (a notification, a server request, another id,
    /// bytes that are not JSON). `error.ServerRefused`, with `last_error` set,
    /// when it is the server's error answer.
    fn answerFor(self: *Server, arena: std.mem.Allocator, scratch: std.mem.Allocator, frame: []const u8, id: u64) !?std.json.Value {
        const value = std.json.parseFromSliceLeaky(std.json.Value, scratch, frame, .{}) catch |err| {
            self.last_error = try std.fmt.allocPrint(arena, "not JSON ({s})", .{@errorName(err)});
            return null;
        };
        return self.answerIn(arena, value, id);
    }

    fn answerIn(self: *Server, arena: std.mem.Allocator, value: std.json.Value, id: u64) !?std.json.Value {
        const object = switch (value) {
            .object => |o| o,
            else => return null,
        };
        const answer = object.get("id") orelse return null;
        const answer_id: u64 = switch (answer) {
            .integer => |n| std.math.cast(u64, n) orelse return null,
            else => return null,
        };
        if (answer_id != id) return null;
        if (object.get("error")) |err_value| {
            self.last_error = try describeError(arena, err_value);
            return error.ServerRefused;
        }
        return object.get("result") orelse {
            self.last_error = "response carried no result";
            return error.ServerRefused;
        };
    }

    /// One POST, raced against the clock, with the failure recorded the way the
    /// stdio path records it: `last_error` says why, and a server that ran out
    /// the clock is dead.
    ///
    /// The timeout is the smaller of the server's own and the caller's. The
    /// clock winning cancels the exchange, which is what interrupts a read
    /// blocked on a server that went quiet, and a connect or a TLS handshake
    /// that never finishes: `std.http` takes no deadline of its own.
    fn post(
        self: *Server,
        io: Io,
        arena: std.mem.Allocator,
        scratch: std.mem.Allocator,
        http: *Http,
        id: ?u64,
        method: []const u8,
        params_json: []const u8,
        timeout: Io.Timeout,
    ) !?std.json.Value {
        var timeout_ms = http.timeout_ms;
        if (timeout.toDurationFromNow(io)) |left| {
            const left_ms = std.math.cast(u64, @divTrunc(left.raw.nanoseconds, std.time.ns_per_ms)) orelse 0;
            timeout_ms = @min(timeout_ms, left_ms);
        }
        return self.race(io, arena, scratch, http, id, method, params_json, timeout_ms) catch |err| {
            switch (err) {
                // These two say why themselves.
                error.ServerRefused, error.HttpStatus => {},
                else => self.last_error = @errorName(err),
            }
            // A server that did not answer in time is not asked again, as a
            // stdio one that went quiet is not.
            if (err == error.Timeout) self.dead = true;
            return err;
        };
    }

    fn race(
        self: *Server,
        io: Io,
        arena: std.mem.Allocator,
        scratch: std.mem.Allocator,
        http: *Http,
        id: ?u64,
        method: []const u8,
        params_json: []const u8,
        timeout_ms: u64,
    ) !?std.json.Value {
        if (timeout_ms == 0) return error.Timeout;
        const Outcome = union(enum) {
            answered: anyerror!?std.json.Value,
            expired: Io.Cancelable!void,
        };
        var slots: [2]Outcome = undefined;
        var select: Io.Select(Outcome) = .init(io, &slots);
        // Both tasks are joined before this returns, so nothing is left
        // writing into `self` or the arenas.
        defer select.cancelDiscard();
        try select.concurrent(.answered, exchange, .{ self, arena, scratch, http, id, method, params_json });
        try select.concurrent(.expired, Io.Timeout.sleep, .{ net.durationMs(timeout_ms), io });
        return switch (try select.await()) {
            .answered => |answer| answer,
            .expired => error.Timeout,
        };
    }

    /// One POST. A request (`id` set) returns its answer, read from a JSON
    /// body or from an event stream; a notification returns null once the
    /// server has accepted it. Everything the answer is built from is in
    /// `scratch`, and what is kept (the session id, the note on a failure) is in
    /// `arena`. It has no deadline of its own: `post` cancels it.
    fn exchange(
        self: *Server,
        arena: std.mem.Allocator,
        scratch: std.mem.Allocator,
        http: *Http,
        id: ?u64,
        method: []const u8,
        params_json: []const u8,
    ) anyerror!?std.json.Value {
        var jb = chat.JsonBuf.init(scratch);
        try writeFrame(jb.writer(), id, method, params_json);
        const body = jb.items();

        var extra: [5]std.http.Header = undefined;
        var extra_len: usize = 0;
        extra[extra_len] = .{ .name = "content-type", .value = "application/json" };
        extra_len += 1;
        extra[extra_len] = .{ .name = "accept", .value = "application/json, text/event-stream" };
        extra_len += 1;
        if (http.negotiated) {
            extra[extra_len] = .{ .name = "mcp-protocol-version", .value = http_protocol_version };
            extra_len += 1;
        }
        if (http.session_id.len != 0) {
            extra[extra_len] = .{ .name = "mcp-session-id", .value = http.session_id };
            extra_len += 1;
        }
        // Not a `privileged` header: this client never writes those. Nothing
        // is redirected, so the key goes to the one host the entry names.
        if (http.key_value.len != 0) {
            extra[extra_len] = .{ .name = http.key_header, .value = http.key_value };
            extra_len += 1;
        }

        var req = try http.client.request(.POST, http.uri, .{
            // A redirect is an error rather than a second request: this
            // request may carry a key, and the answer to it is not a page.
            .redirect_behavior = .unhandled,
            // A body cannot be inflated without a window buffer, and a
            // JSON-RPC answer is small text: ask for it as it is.
            .headers = .{ .accept_encoding = .omit },
            .extra_headers = extra[0..extra_len],
        });
        defer req.deinit();
        const connection = req.connection.?;

        try req.sendBodyComplete(body);
        var no_redirect: [0]u8 = .{};
        var response = try req.receiveHead(&no_redirect);

        const status = response.head.status;
        if ((id != null and status != .ok) or (id == null and status.class() != .success)) {
            self.last_error = try std.fmt.allocPrint(arena, "HTTP {d}", .{@intFromEnum(status)});
            connection.closing = true;
            return error.HttpStatus;
        }
        if (http.session_id.len == 0) http.session_id = try sessionId(arena, response.head);
        const content_type = response.head.content_type orelse "";
        const is_sse = std.ascii.startsWithIgnoreCase(content_type, "text/event-stream");
        const is_json = std.ascii.startsWithIgnoreCase(content_type, "application/json");

        const want = id orelse {
            // A notification's answer is an empty 202. Anything else may be a
            // stream nobody reads, which would be drained on the way out.
            if (status != .accepted) connection.closing = true;
            return null;
        };
        if (!is_sse and !is_json) {
            // The body is still on the wire, and a connection handed back to
            // the client with bytes unread behind it hands the next request
            // this body as its response head.
            connection.closing = true;
            return error.UnexpectedContentType;
        }

        var transfer: [http_transfer_bytes]u8 = undefined;
        const reader = response.reader(&transfer);
        var stopped_early = false;
        defer connection.closing = connection.closing or stopped_early;
        return try self.readAnswer(arena, scratch, reader, is_sse, want, &stopped_early);
    }

    /// Reads the response body until `id` is answered, as a whole JSON value
    /// or event by event. A body past the frame ceiling is an error rather
    /// than a cut, because a cut result is half a JSON document.
    fn readAnswer(
        self: *Server,
        arena: std.mem.Allocator,
        scratch: std.mem.Allocator,
        reader: *Io.Reader,
        is_sse: bool,
        id: u64,
        stopped_early: *bool,
    ) !std.json.Value {
        var pending: std.ArrayList(u8) = .empty;
        var event: std.ArrayList(u8) = .empty;
        var scanned: usize = 0;
        var total: usize = 0;
        // Every way out of this function that is not the answer leaves the
        // body part-read, and the caller's `closing` flag only carries the
        // stream that ended early on purpose. An error is the other way to
        // stop mid-body, so it counts the same way.
        errdefer stopped_early.* = true;
        while (true) {
            try pending.ensureUnusedCapacity(scratch, http_read_chunk_bytes);
            var vec: [1][]u8 = .{pending.unusedCapacitySlice()};
            const n = reader.readVec(&vec) catch |err| switch (err) {
                error.EndOfStream => break,
                error.ReadFailed => return error.ReadFailed,
            };
            pending.items.len += n;
            total += n;
            if (total > max_frame_bytes) return error.ResponseTooLarge;
            if (!is_sse) continue;

            var start: usize = 0;
            while (net.nextLineEnd(pending.items, &scanned)) |at| {
                const line = std.mem.trimEnd(u8, pending.items[start..at], "\r");
                start = at + 1;
                if (try self.sseLine(arena, scratch, &event, line, id)) |result| {
                    // The stream may stay open past its answer, and the rest of
                    // it is not read, so the connection is not reused.
                    stopped_early.* = true;
                    return result;
                }
            }
            if (start > 0) {
                std.mem.copyForwards(u8, pending.items[0..], pending.items[start..]);
                pending.items.len -= start;
                scanned -|= start;
            }
        }
        if (!is_sse) {
            const value = std.json.parseFromSliceLeaky(std.json.Value, scratch, pending.items, .{}) catch |err| {
                self.last_error = try std.fmt.allocPrint(arena, "not JSON ({s})", .{@errorName(err)});
                return error.ServerRefused;
            };
            switch (value) {
                // A batch answers a request with an array of frames.
                .array => |frames| for (frames.items) |frame| {
                    if (try self.answerIn(arena, frame, id)) |result| return result;
                },
                else => if (try self.answerIn(arena, value, id)) |result| return result,
            }
            return error.StreamEndedWithoutAnswer;
        }
        // A last line with no newline, and a last event with no blank line
        // after it, are still what the server said.
        const tail = std.mem.trimEnd(u8, pending.items, "\r");
        if (tail.len != 0) if (try self.sseLine(arena, scratch, &event, tail, id)) |result| return result;
        if (try self.sseLine(arena, scratch, &event, "", id)) |result| return result;
        return error.StreamEndedWithoutAnswer;
    }

    /// One line of an event stream. `data` lines are joined into the event,
    /// which ends at a blank line; comments and the other fields are not
    /// needed. Returns the result when the finished event answers `id`.
    fn sseLine(self: *Server, arena: std.mem.Allocator, scratch: std.mem.Allocator, event: *std.ArrayList(u8), line: []const u8, id: u64) !?std.json.Value {
        if (line.len != 0) {
            const data = std.mem.cutPrefix(u8, line, "data:") orelse return null;
            if (event.items.len != 0) try event.append(scratch, '\n');
            try event.appendSlice(scratch, std.mem.trimStart(u8, data, " "));
            return null;
        }
        if (event.items.len == 0) return null;
        defer event.clearRetainingCapacity();
        return self.answerFor(arena, scratch, event.items, id);
    }
};

/// The `Mcp-Session-Id` a response carries, copied out of the head, or empty.
/// The value goes back out as a header, so anything but visible ASCII is
/// dropped rather than echoed.
fn sessionId(arena: std.mem.Allocator, head: std.http.Client.Response.Head) ![]const u8 {
    var headers = head.iterateHeaders();
    while (headers.next()) |header| {
        if (!std.ascii.eqlIgnoreCase(header.name, "mcp-session-id")) continue;
        if (header.value.len == 0 or header.value.len > max_session_id_bytes) return "";
        for (header.value) |c| if (c < 0x21 or c > 0x7e) return "";
        return arena.dupe(u8, header.value);
    }
    return "";
}

/// The tool `exposed` names on this server, or null. A lazy preset's table is
/// replaced by the server's own answer at its first call, so the tool the model
/// named is looked up again there rather than trusted from the table it was
/// advertised out of.
fn findTool(server: *const Server, exposed: []const u8) ?*const Tool {
    for (server.tools) |*tool| {
        if (std.mem.eql(u8, tool.exposed, exposed)) return tool;
    }
    return null;
}

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
        // Every byte an entry needs is one of its own strings or a fixed number
        // of bytes of punctuation, so the whole is known before the first
        // write. Reserving it replaces the walk up the doubling ladder, and on
        // the arena that walk leaves every intermediate block behind: a
        // server whose `inputSchema` runs to a megabyte made the buffer walk
        // that ladder twenty times and keep all twenty copies.
        var size: usize = 0;
        for (self.items) |server| {
            for (server.tools) |tool| {
                size += tool.exposed.len + tool.description.len + tool.schema.len + mcp_tool_entry_bytes;
            }
        }
        try buf.ensureTotalCapacity(arena, size);
        for (self.items) |server| {
            for (server.tools) |tool| {
                if (buf.items.len != 0) try buf.append(arena, ',');
                var jb = chat.JsonBuf.initCapacity(
                    arena,
                    tool.exposed.len + tool.description.len + tool.schema.len + mcp_tool_entry_bytes,
                );
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

    /// Everything in one entry that is not one of the three strings: the
    /// wrapper, the two member names, the commas, the quotes around the
    /// escaped name and description, and the closing braces. Escaping can make
    /// the two strings longer than they arrived, so this is headroom rather
    /// than a bound, and the buffer still grows when a name or description
    /// needs it to.
    const mcp_tool_entry_bytes = 64;

    /// One remote call: the model's argument text is sent as the tool's
    /// `arguments`, and the text the server returns becomes the tool result.
    /// The argument text is checked as JSON before it is embedded, so a model
    /// that streamed a truncated object gets an error string rather than a
    /// server-side parse failure reported as the server's fault.
    pub fn call(io: Io, arena: std.mem.Allocator, call_: Call, args_text: []const u8, timeout: Io.Timeout) ![]const u8 {
        var tool_call = call_;
        const server = tool_call.server;
        // A preset's tools were advertised from this binary's table without a
        // handshake, so this is the first thing it is asked. The tool is looked
        // up again in what it answers: a server that renamed or dropped it gets
        // a sentence saying so rather than a `tools/call` for a name it no
        // longer has.
        if (server.lazy) {
            if (!handshake(io, arena, server, server.client_version)) {
                server.dead = true;
                return std.fmt.allocPrint(arena, "error: MCP server {s} did not answer ({s})", .{
                    server.name,
                    if (server.last_error.len != 0) server.last_error else "no answer",
                });
            }
            server.lazy = false;
            tool_call.tool = findTool(server, tool_call.tool.exposed) orelse
                return std.fmt.allocPrint(arena, "error: MCP server {s} no longer offers {s}", .{ server.name, tool_call.tool.exposed });
        }
        if (server.dead) return std.fmt.allocPrint(arena, "error: MCP server {s} is no longer running ({s})", .{ server.name, server.last_error });
        const args = std.mem.trim(u8, args_text, " \t\r\n");
        if (args.len != 0) {
            // The parse is here only to decide whether the request can be sent,
            // so the tree it builds is dropped before the round trip rather than
            // kept in the run's arena, for the reason the handshake gives.
            var args_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer args_state.deinit();
            _ = std.json.parseFromSliceLeaky(std.json.Value, args_state.allocator(), args, .{}) catch
                return "error: tool arguments are not valid JSON";
        }
        var pb = chat.JsonBuf.init(arena);
        try pb.writer().writeAll("{\"name\":");
        try chat.writeJsonString(pb.writer(), tool_call.tool.name);
        try pb.writer().writeAll(",\"arguments\":");
        try pb.writer().writeAll(if (args.len == 0) "{}" else args);
        try pb.writer().writeAll("}");

        net.writeErr(io, try std.fmt.allocPrint(arena, "\u{23fa} {s}\n", .{chat.safeText(arena, tool_call.tool.exposed, max_shown_name_bytes)}));
        // The answer is parsed in a scratch arena and only the text built from
        // it is kept, for the reason the handshake gives.
        var scratch_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer scratch_state.deinit();
        const result = server.request(io, arena, scratch_state.allocator(), "tools/call", pb.items(), timeout) catch |err| {
            if (err == error.ServerRefused or err == error.HttpStatus)
                return std.fmt.allocPrint(arena, "error: MCP server {s} refused {s}: {s}", .{ server.name, tool_call.tool.exposed, server.last_error });
            return std.fmt.allocPrint(arena, "error: MCP server {s} did not answer {s} ({s})", .{ server.name, tool_call.tool.exposed, @errorName(err) });
        };
        return resultText(arena, server.name, result);
    }

    /// Closes every connection: stdin first, so a server that is waiting for
    /// more input sees end of stream and can exit on its own, then the whole
    /// process group, so one that does not is not left behind. A remote server
    /// holds nothing between requests, so there is nothing to close.
    pub fn shutdown(self: *Servers, io: Io) void {
        for (self.items) |*server| {
            // The child's own cleanup closes stdin as well, so the handle is
            // handed over by clearing the field rather than closed twice: a
            // second close of the same descriptor is a use-after-free the
            // runtime traps on. `to_server` keeps the dead handle, and nothing
            // sends on it after this.
            switch (server.transport) {
                .stdio => |*stdio| if (stdio.child.stdin) |stdin| {
                    stdin.close(io);
                    stdio.child.stdin = null;
                },
                .http => {},
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
        // The same bound the text path below builds to, for the same reason. A
        // server that answers with a structured payload of a megabyte was
        // stringified whole and clamped a moment later by the caller, so the
        // copy, the clamp and the bytes in between were all work over text
        // nobody keeps, on a value this run cannot bound before the stringify
        // allocates it.
        if (object.get("structuredContent")) |value|
            return cappedJson(arena, value, tool_mod.max_tool_output);
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
    const note_room = truncation_note_room;
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
            // The cut here is a byte count and lands wherever it lands, and it
            // needs no care of its own: a result this cut shortened is over the
            // cap, so the whole of what it left is clamped again on a codepoint
            // boundary below, which is what the model is handed.
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
        const kept = chat.clamp(buf.items, cap - note_room);
        return truncationNote(arena, kept, cap, total);
    }
    return buf.items;
}

/// A structured MCP result as the model reads it: the value as the server
/// wrote it, under `cap`, with the same note the text path uses when it cut.
///
/// The value is one this run did not write, so it is bounded on the way out
/// rather than trusted to be small. `chat.clamp` cuts on a code point boundary,
/// so the result is JSON no longer; a structured result the cap reached is
/// reported as such instead, because a tool result that is half an object reads
/// to the model as the whole of one.
///
/// The size is measured with the same writer the value is built with, into the
/// same arena, so what is measured is what would have been returned: a
/// stringify that fails on the cap's own memory is an allocation failure, which
/// is this machine's and not the server's.
fn cappedJson(arena: std.mem.Allocator, value: std.json.Value, cap: usize) ![]const u8 {
    var jb = chat.JsonBuf.init(arena);
    try std.json.Stringify.value(value, .{}, jb.writer());
    const text = jb.items();
    if (text.len <= cap) return text;
    const kept = chat.clamp(text, cap - truncation_note_room);
    return truncationNote(arena, kept, cap, text.len);
}

/// The room a truncation note is written into, held back from the cap before
/// the cut rather than measured after it, so the note survives the caller's own
/// clamp with the cap and the true size it names. Two paths cut a server's
/// answer, so this is the one number both of them holds back.
const truncation_note_room: usize = 128;

/// The note both cut paths append, spelled once because a parser reads it: a
/// tool result that was cut says how much of it is here, and a test parses
/// that sentence to learn the sizes rather than the bytes.
fn truncationNote(arena: std.mem.Allocator, kept: []const u8, cap: usize, total: usize) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}\n... [tool output truncated at {d} of {d} bytes]", .{ kept, cap, total });
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
        .integer => |n| return std.fmt.allocPrint(arena, "{s} (code {d})", .{ chat.safeText(arena, message, max_mcp_description_bytes), n }),
        else => {},
    };
    return chat.safeText(arena, message, max_mcp_description_bytes);
}

/// The header a remote server's key is sent in unless the entry names another,
/// and the only one whose value is a `Bearer` credential.
pub const default_key_header = "Authorization";
/// Seconds one remote request may take unless the entry says otherwise, and the
/// most it may be told to take: the same ceiling a tool call answers to.
pub const default_timeout_s: u32 = 30;
pub const max_timeout_s: u32 = 600;

/// One server out of the config file: one `[[mcp]]` table, or one enabled
/// `[tools.<preset>]`. A local server has a `command`, a remote one a `url`
/// and the options after it; the config reader refuses an entry with both or
/// with neither.
pub const Entry = struct {
    name: []const u8,
    command: []const u8 = "",
    args: []const []const u8 = &.{},
    env: []const [2][]const u8 = &.{},
    url: []const u8 = "",
    /// The NAME of the environment variable that holds the key, never the key.
    api_key_env: []const u8 = "",
    api_key_header: []const u8 = default_key_header,
    timeout_s: u32 = default_timeout_s,
    /// The key itself, read out of the environment by `withKeys`. Empty when
    /// the entry names no variable or the variable is unset or empty.
    api_key: []const u8 = "",
};

/// The public remote servers `[tools.<name>]` can switch on. They are served
/// through the same machinery as a configured server named the same, so their
/// tools reach the model as `mcp__<preset>__<tool>`.
pub const Preset = enum {
    web_search,
    context7,
    grep_app,
    deepwiki,

    pub fn url(preset: Preset) []const u8 {
        return switch (preset) {
            .web_search => "https://mcp.exa.ai/mcp",
            .context7 => "https://mcp.context7.com/mcp",
            .grep_app => "https://mcp.grep.app",
            .deepwiki => "https://mcp.deepwiki.com/mcp",
        };
    }
};

/// What a preset's server sends about one of its tools, replaced by a compact
/// form. The servers' own descriptions and schemas run to a kilobyte or more
/// each of examples and emphasis, and every request carries them. These say
/// what the tool does and what each argument is. An entry applies to the
/// preset's own url and to a tool named here, so a server that changes its
/// tools, or another server that happens to share a name, is shown as it sent
/// them.
const Terse = struct { preset: Preset, tool: []const u8, description: []const u8, schema: []const u8 };

/// Appended to every preset tool's description, so it reaches the model with
/// the tool rather than as a note the description could leave out.
///
/// A call to one of these four is a copy leaving the machine into a third
/// party's log, and its arguments are the model's own bytes, chosen from the
/// files in the tree. The tree is what the run was asked about and its operator
/// did not offer to publish it, so a snippet, a path, a file name or a name
/// belonging to somebody in it does not go to a search index or a wiki to answer
/// a coding task. The four presets are on by default, which is why the guidance
/// is theirs to carry: a server an operator configured is a server they chose
/// and can describe themselves.
const off_host_note =
    " A call here leaves the machine, so put nothing in an argument that belongs to the repository under review: no code, no path, no file content, no repository name, and nothing that names a person in it.";

/// What the model is told one preset tool is, which is the table's own line
/// and `off_host_note`. The note is added here rather than written into the
/// eight lines so it cannot be left off one of them, and so the test that bounds
/// the description bounds the bytes that are actually sent.
fn presetDescription(arena: std.mem.Allocator, entry: Terse) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}{s}", .{ entry.description, off_host_note });
}

const terse_tools = [_]Terse{
    // Exa's own description for this tool also carries `category:people` and
    // `category:company`, which turn a query into a search of a person's or a
    // company's profiles, and neither is carried here. Nothing in this run
    // needs a profile index: the tool is here to find documentation and code,
    // and a query naming an individual would put that name in a third party's
    // search log to answer a coding task. The categories stay usable, an
    // operator whose task is a profile search can say so in the task text.
    .{
        .preset = .web_search,
        .tool = "web_search_exa",
        .description = "Search the web; returns clean text from the top results. Describe the ideal page instead of using keywords. " ++
            "If highlights are not enough, read the best URLs with web_fetch_exa.",
        .schema =
        \\{"type":"object","properties":{"query":{"type":"string","description":"The ideal page, described in natural language"},"numResults":{"type":"number","description":"Results to return, default 10"},"objective":{"type":"string","description":"What this search is for: which documents should rank first or be excluded, and which facts to pull out"}},"required":["query","objective"]}
        ,
    },
    .{
        .preset = .web_search,
        .tool = "web_fetch_exa",
        .description = "Read webpages as clean markdown. Use after web_search_exa when highlights are not enough, or for any URL; batch URLs in one call.",
        .schema =
        \\{"type":"object","properties":{"urls":{"type":"array","items":{"type":"string"},"description":"URLs to read"},"maxCharacters":{"type":"number","description":"Characters to extract per page, default 3000"}},"required":["urls"]}
        ,
    },
    .{
        .preset = .context7,
        .tool = "resolve-library-id",
        .description = "Resolve a library name to a Context7 library ID (/org/project or /org/project/version), with each match's reputation, benchmark score, snippet count and versions. " ++
            "Call it before query-docs unless the user gave an ID. Choose by name match, reputation and snippet coverage.",
        .schema =
        \\{"type":"object","properties":{"query":{"type":"string","description":"What you want to do with the library, to rank the matches; never include secrets or code"},"libraryName":{"type":"string","description":"The official name with its punctuation, e.g. Next.js not nextjs"}},"required":["query","libraryName"]}
        ,
    },
    .{
        .preset = .context7,
        .tool = "query-docs",
        .description = "Fetch current documentation and code examples for a library by its Context7 ID from resolve-library-id, or one the user gave. At most 3 calls per question.",
        .schema =
        \\{"type":"object","properties":{"libraryId":{"type":"string","description":"Context7 ID such as /vercel/next.js or /vercel/next.js/v14.3.0"},"query":{"type":"string","description":"One specific concept per call, e.g. 'JWT authentication in Express.js', not 'auth'; never include secrets or code"}},"required":["libraryId","query"]}
        ,
    },
    .{
        .preset = .grep_app,
        .tool = "searchGitHub",
        .description = "Search public GitHub code for literal patterns, like grep, not keywords: 'useState(' or '(?s)try {.*await', not 'react tutorial'. " ++
            "Use it to see real usage of an unfamiliar API, syntax or configuration.",
        .schema =
        \\{"type":"object","properties":{"query":{"type":"string","description":"Literal code as it would appear in a file"},"matchCase":{"type":"boolean"},"matchWholeWords":{"type":"boolean"},"useRegexp":{"type":"boolean","description":"Treat the query as a regular expression"},"repo":{"type":"string","description":"Repository filter, partial match: 'vercel/' for an org"},"path":{"type":"string","description":"File path filter, partial match: '/route.ts'"},"language":{"type":"array","items":{"type":"string"},"description":"Languages, e.g. ['TypeScript','TSX']"}},"required":["query"]}
        ,
    },
    .{
        .preset = .deepwiki,
        .tool = "read_wiki_structure",
        .description = "List the documentation topics DeepWiki holds for a GitHub repository. Use it to see what a repository's wiki covers before reading one page or asking a question.",
        .schema =
        \\{"type":"object","properties":{"repoName":{"type":"string","description":"GitHub repository in owner/repo format, e.g. facebook/react"}},"required":["repoName"]}
        ,
    },
    .{
        .preset = .deepwiki,
        .tool = "read_wiki_contents",
        .description = "Read a GitHub repository's DeepWiki documentation whole. Use read_wiki_structure first when only one topic is wanted, or ask_wiki_question for one answer.",
        .schema =
        \\{"type":"object","properties":{"repoName":{"type":"string","description":"GitHub repository in owner/repo format, e.g. facebook/react"}},"required":["repoName"]}
        ,
    },
    .{
        .preset = .deepwiki,
        .tool = "ask_wiki_question",
        .description = "Ask a question about a GitHub repository and get an answer grounded in its DeepWiki. Ask one question per call; repoName may name up to ten repositories.",
        .schema =
        \\{"type":"object","properties":{"repoName":{"anyOf":[{"type":"string"},{"type":"array","items":{"type":"string"}}],"description":"A GitHub repository in owner/repo format, or a list of up to 10 of them"},"question":{"type":"string","description":"The question about the repository"}},"required":["repoName","question"]}
        ,
    },
};

/// The host a preset's url names: the authority between the scheme and the
/// first path separator. These urls are this binary's own, so that is all the
/// grammar needed.
fn presetHost(url: []const u8) []const u8 {
    const after_scheme = (std.mem.indexOf(u8, url, "://") orelse return "") + 3;
    const rest = url[after_scheme..];
    return rest[0..(std.mem.indexOfScalar(u8, rest, '/') orelse rest.len)];
}

/// The preset a host belongs to, or null for an endpoint a config wrote.
fn presetForHost(host: []const u8) ?Preset {
    for (std.enums.values(Preset)) |preset| {
        if (std.ascii.eqlIgnoreCase(presetHost(preset.url()), host)) return preset;
    }
    return null;
}

/// The compact form of `tool` on the host of `preset`, or null when the table
/// does not know the pair.
fn terseFor(host: []const u8, tool: []const u8) ?Terse {
    const preset = presetForHost(host) orelse return null;
    for (terse_tools) |t| {
        if (t.preset == preset and std.mem.eql(u8, t.tool, tool)) return t;
    }
    return null;
}

/// `terseFor` for a connected server: only a remote one has a host to match.
fn terseForServer(server: *const Server, tool: []const u8) ?Terse {
    const http = switch (server.transport) {
        .http => |h| h,
        .stdio => return null,
    };
    const host = http.uri.host orelse return null;
    return terseFor(switch (host) {
        .raw, .percent_encoded => |text| text,
    }, tool);
}

test "the compact preset tools are valid schemas for exactly the tools they name" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const arena = state.allocator();
    // Every preset has at least one tool and `url` knows every member, so a
    // preset added to the enum without a table entry is caught here rather
    // than offered to the model with no tools.
    try std.testing.expectEqual(@as(usize, 8), terse_tools.len);
    for (std.enums.values(Preset)) |preset| {
        try std.testing.expect(presetHost(preset.url()).len > 0);
        var offered: usize = 0;
        for (terse_tools) |t| {
            if (t.preset == preset) offered += 1;
        }
        try std.testing.expect(offered > 0);
    }
    for (terse_tools) |t| {
        try std.testing.expect(t.description.len > 0 and t.description.len < 400);
        const description = try presetDescription(arena, t);
        try std.testing.expect(description.len < 700);
        try std.testing.expect(std.mem.endsWith(u8, description, off_host_note));
        const schema = try std.json.parseFromSliceLeaky(std.json.Value, arena, t.schema, .{});
        const object = schema.object;
        try std.testing.expectEqualStrings("object", object.get("type").?.string);
        // Every required argument is a declared property, and the compact schema is far smaller
        // than the 1.4 KB to 2.5 KB the servers send.
        const properties = object.get("properties").?.object;
        for (object.get("required").?.array.items) |name| try std.testing.expect(properties.contains(name.string));
        try std.testing.expect(t.schema.len < 900);
    }
    // Only the preset's own host and a tool the table names get the compact form.
    try std.testing.expect(terseFor("mcp.grep.app", "searchGitHub") != null);
    try std.testing.expect(terseFor("MCP.GREP.APP", "searchGitHub") != null);
    try std.testing.expect(terseFor("mcp.grep.app", "somethingNew") == null);
    try std.testing.expect(terseFor("127.0.0.1", "searchGitHub") == null);
    try std.testing.expect(terseFor("mcp.exa.ai", "query-docs") == null);
    try std.testing.expect(terseFor("mcp.deepwiki.com", "ask_wiki_question") != null);
}

test "a preset with no key is offered without a handshake, and one with a key is not" {
    const gpa = std.testing.allocator;
    var state = std.heap.ArenaAllocator.init(gpa);
    defer state.deinit();
    const arena = state.allocator();
    const io = std.testing.io;
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    // No key: the tools come from the table in this binary and the endpoint is
    // not spoken to. Defeating this -- handshaking at start-up -- sends a real
    // request here, and a machine with no route to the server answers with no
    // servers at all, which is the failure this asserts against.
    var env: std.process.Environ.Map = .init(arena);
    var servers = connect(io, arena, &env, &client, &.{
        .{ .name = "docs", .url = "https://mcp.context7.com/mcp" },
    }, "test");
    defer servers.shutdown(io);
    try std.testing.expectEqual(@as(usize, 1), servers.items.len);
    try std.testing.expect(servers.items[0].lazy);
    try std.testing.expectEqual(@as(usize, 2), servers.items[0].tools.len);
    const resolved = servers.resolve("mcp__docs__query-docs") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("query-docs", resolved.tool.name);

    // A key unlocks tools this table has never seen, so a keyed preset is
    // still handshaken. `openRemote` alone records it, without a request.
    var keyed: std.ArrayList(Server) = .empty;
    openRemote(io, arena, &client, .{
        .name = "docs",
        .url = "https://mcp.context7.com/mcp",
        .api_key = "s3cret",
        .api_key_env = "K",
    }, "test", &keyed);
    try std.testing.expectEqual(@as(usize, 1), keyed.items.len);
    try std.testing.expect(!keyed.items[0].lazy);
    try std.testing.expectEqual(@as(usize, 0), keyed.items[0].tools.len);
}

/// Fills a preset's tool table from the table above, so its tools can be
/// offered without the run talking to it. True when the host is one the table
/// knows, which is the four presets and nothing a config wrote: a `[[mcp]]` url
/// is a server whose tools only its own `tools/list` can name.
///
/// A preset with a key is not filled here. A key unlocks tools this binary has
/// never seen -- exa's company and people search, deepwiki's private mode -- and
/// a table that named only the public ones would hide them from the model until
/// one of them was called, which it cannot do if it cannot see one.
fn fillPresetTools(arena: std.mem.Allocator, server: *Server, client_version: []const u8) !bool {
    const http = switch (server.transport) {
        .http => |h| h,
        .stdio => return false,
    };
    const host = switch (http.uri.host orelse return false) {
        .raw, .percent_encoded => |text| text,
    };
    const preset = presetForHost(host) orelse return false;
    var tools: std.ArrayList(Tool) = .empty;
    for (terse_tools) |entry| {
        if (entry.preset != preset) continue;
        tools.append(arena, .{
            .name = entry.tool,
            .exposed = try std.fmt.allocPrint(arena, "{s}{s}__{s}", .{ tool_prefix, server.name, entry.tool }),
            .description = try presetDescription(arena, entry),
            .schema = entry.schema,
        }) catch return false;
    }
    server.tools = tools.items;
    server.lazy = true;
    server.client_version = client_version;
    return true;
}

/// Whether a remote url is one this run will POST to: https, or http to this
/// machine, with a host and no `user:password@` in front of it (the client
/// would send that as basic authorization, beside the entry's own key).
pub fn validUrl(url: []const u8) bool {
    const uri = std.Uri.parse(url) catch return false;
    if (uri.host == null or uri.user != null or uri.password != null) return false;
    return net.urlCarriesKey(url);
}

/// Whether text can name an environment variable. The key is looked up by
/// this name and the name is what the tool environment is scrubbed of, so a
/// name with an `=` in it could not be either.
pub fn validEnvName(name: []const u8) bool {
    if (name.len == 0 or name.len > max_name_bytes) return false;
    for (name) |c| if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    return true;
}

/// Whether text is an HTTP header field name: a token, which holds no colon,
/// space or control character a header line could be split on.
pub fn validHeaderName(name: []const u8) bool {
    if (name.len == 0 or name.len > max_name_bytes) return false;
    for (name) |c| {
        const ok = std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "!#$%&'*+-.^_`|~", c) != null;
        if (!ok) return false;
    }
    return true;
}

/// The entries with each `api_key_env` looked up in `environ_map`. Called
/// before the tool environment is scrubbed of those names, so the keys are
/// read from the run's real environment and only the copy here survives.
pub fn withKeys(arena: std.mem.Allocator, environ_map: *const std.process.Environ.Map, entries: []const Entry) ![]Entry {
    const out = try arena.dupe(Entry, entries);
    for (out) |*entry| {
        if (entry.api_key_env.len == 0) continue;
        const value = std.mem.trim(u8, environ_map.get(entry.api_key_env) orelse continue, net.env_surrounding);
        entry.api_key = try arena.dupe(u8, value);
    }
    return out;
}

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

/// Whether a tool table already holds `name`, which is what makes a second
/// `tools/list` entry under a name already on the table the same tool. The
/// scan is linear because a server's table is the length of its answer, and
/// the table is built once per connection.
fn indexOfToolName(table: []const Tool, name: []const u8) ?usize {
    for (table, 0..) |tool, i| {
        if (std.mem.eql(u8, tool.name, name)) return i;
    }
    return null;
}

/// Connects to every server the config declared, in the order the tables
/// appeared. An entry that cannot run, or that fails its handshake, is said on
/// stderr and skipped, because a server the operator wrote down and this run
/// does not connect to is a silent no-op otherwise. A remote entry is spoken to
/// through `client`, the run's own, which already trusts the CA bundle.
pub fn connect(
    io: Io,
    arena: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
    client: *std.http.Client,
    entries: []const Entry,
    client_version: []const u8,
) Servers {
    // Every local server is started before any of them is asked to initialize.
    // What a handshake mostly waits for is the server's own boot -- `npx`
    // resolving a package, a node or python interpreter coming up -- and that
    // is the server's work, not a message the client is waiting on. Started
    // one at a time, N servers cost the sum of their boot times before the run
    // can send its first request; started together, they cost the slowest one.
    var spawned: std.ArrayList(Server) = .empty;
    for (entries) |entry| {
        if (entry.url.len != 0) openRemote(io, arena, client, entry, client_version, &spawned) else spawnOne(io, arena, environ_map, entry, &spawned);
    }

    // The remote handshakes are round trips over the network, so each runs as
    // its own task and they cost the slowest one, not the sum. The local ones
    // are handshaken on this thread while those are in flight. Each task owns
    // one server and one slot of `ready`; the tool list, the notes and which
    // server answers for a name still follow the order the file wrote, because
    // the results are read back in that order once every task has finished.
    // Every server is reaped and the run carries on with none, which is the
    // same thing this function does with a server it cannot start. The line
    // says so, because a run with no MCP tools at all and nothing on stderr is
    // a run whose operator cannot tell from a missing config.
    const ready = arena.alloc(bool, spawned.items.len) catch |err| {
        for (spawned.items) |*server| server.reap(io);
        net.note(io, arena, "microagent: the {d} configured MCP server(s) could not be connected ({s}); none of them is in this run\n", .{ spawned.items.len, @errorName(err) });
        return .{ .items = &.{} };
    };
    @memset(ready, false);
    var remote: Io.Group = .init;
    defer remote.cancel(io);
    for (spawned.items, ready) |*server, *ok| {
        if (server.transport != .http) continue;
        // A preset with no key was already given its tools from the table in
        // this binary, so there is nothing to ask it yet: the first call to one
        // of them runs the handshake. Every other remote server is unknown
        // until it answers.
        if (server.lazy) {
            ok.* = true;
            continue;
        }
        // Without a thread to run it on, the handshake runs here instead.
        remote.concurrent(io, handshakeInto, .{ io, arena, server, client_version, ok }) catch handshakeInto(io, arena, server, client_version, ok);
    }
    for (spawned.items, ready) |*server, *ok| {
        if (server.transport == .http) continue;
        handshakeInto(io, arena, server, client_version, ok);
    }
    // A cancelation here ends the tasks, and a task that did not finish left
    // its slot false, so its server is skipped below.
    remote.await(io) catch {};

    var connected: std.ArrayList(Server) = .empty;
    for (spawned.items, ready) |*server, ok| {
        if (!ok) {
            // A handshake that gave up before it could record why leaves the
            // field empty, and a line reading "server X: ; it is skipped"
            // names the server without saying one word about what stopped it.
            // The wording is the one the lazy handshake's own refusal uses.
            net.note(io, arena, "microagent: MCP server {s}: {s}; it is skipped\n", .{
                chat.safeTextAll(arena, server.name),
                if (server.last_error.len != 0) server.last_error else "no answer",
            });
            server.reap(io);
            continue;
        }
        connected.append(arena, server.*) catch |err| {
            net.note(io, arena, "microagent: MCP server {s}: it could not be recorded ({s}); it is stopped and skipped\n", .{
                chat.safeTextAll(arena, server.name), @errorName(err),
            });
            server.reap(io);
        };
    }
    return .{ .items = connected.items };
}

/// `handshake`, with the answer stored where a task can leave it.
fn handshakeInto(io: Io, arena: std.mem.Allocator, server: *Server, client_version: []const u8, ok: *bool) void {
    ok.* = handshake(io, arena, server, client_version);
}

/// Records a remote server. Nothing is sent yet: the handshake runs later,
/// over the whole list. An entry whose url or key cannot be used is named and
/// left out, the reasons never quoting the url, which may carry a token in its
/// query, or the key.
fn openRemote(
    io: Io,
    arena: std.mem.Allocator,
    client: *std.http.Client,
    entry: Entry,
    client_version: []const u8,
    out: *std.ArrayList(Server),
) void {
    const shown = chat.safeTextAll(arena, entry.name);
    const uri = std.Uri.parse(entry.url) catch null;
    if (uri == null or !validUrl(entry.url)) {
        net.note(io, arena, "microagent: MCP server {s}: the url is not https, or http on this machine; it is skipped\n", .{shown});
        return;
    }
    // The key is written into a header line, so a byte that ends the line would
    // split the request.
    if (net.hasHeaderControlBytes(entry.api_key)) {
        net.note(io, arena, "microagent: MCP server {s}: the key in {s} holds a control character; it is skipped\n", .{ shown, chat.safeTextAll(arena, entry.api_key_env) });
        return;
    }
    // Every way this can leave an entry out says so, the way the two above do:
    // an entry the operator wrote down and this run drops without a line reads
    // from outside as a server that was never configured.
    const key_value = if (entry.api_key.len == 0)
        ""
    else if (std.ascii.eqlIgnoreCase(entry.api_key_header, default_key_header))
        std.fmt.allocPrint(arena, "Bearer {s}", .{entry.api_key}) catch |err| {
            net.note(io, arena, "microagent: MCP server {s}: the key in {s} could not be prepared for the request ({s}); it is skipped\n", .{
                shown, chat.safeTextAll(arena, entry.api_key_env), @errorName(err),
            });
            return;
        }
    else
        entry.api_key;
    var server: Server = .{
        .name = entry.name,
        .transport = .{ .http = .{
            .client = client,
            .uri = uri.?,
            .key_header = entry.api_key_header,
            .key_value = key_value,
            .timeout_ms = @as(u64, entry.timeout_s) * std.time.ms_per_s,
        } },
        .tools = &.{},
    };
    // A keyless preset is offered from the table this binary carries: no
    // request is made for it now, and the first call to one of its tools is
    // where it is asked to initialize. That is what keeps four public servers
    // off the path between the process and its first provider request. False
    // is the ordinary answer for a host this binary carries no table for, and
    // such a server is handshaken before its first use instead; an error is
    // not ordinary, so it is named rather than read as the same thing.
    if (entry.api_key.len == 0) {
        _ = fillPresetTools(arena, &server, client_version) catch |err| blk: {
            net.note(io, arena, "microagent: MCP server {s}: its tools could not be prepared ({s}); it is connected, and the handshake is made before its first use\n", .{
                shown, @errorName(err),
            });
            break :blk false;
        };
    }
    out.append(arena, server) catch |err| {
        net.note(io, arena, "microagent: MCP server {s}: it could not be recorded ({s}); it is skipped\n", .{ shown, @errorName(err) });
    };
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
    argv.append(arena, entry.command) catch |err| return skipped(io, arena, shown, "its command line could not be built", err);
    argv.appendSlice(arena, entry.args) catch |err| return skipped(io, arena, shown, "its command line could not be built", err);

    // The server inherits the scrubbed environment the tool children get --
    // the provider key is not in it -- plus whatever the entry names, which is
    // how a server is handed its own configuration. A server started with a
    // partly built environment is one whose own configuration silently is not
    // the one the config file declared, so an entry that cannot be copied is
    // named and the server is not started at all.
    var env: std.process.Environ.Map = .init(arena);
    var it = environ_map.iterator();
    while (it.next()) |pair| env.put(pair.key_ptr.*, pair.value_ptr.*) catch |err|
        return skipped(io, arena, shown, "the environment it would inherit could not be built", err);
    for (entry.env) |pair| env.put(pair[0], pair[1]) catch |err|
        return skipped(io, arena, shown, "the environment it names could not be built", err);

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

    const pgid: std.posix.pid_t = @intCast(child.id.?);
    var server: Server = .{
        .name = entry.name,
        .transport = .{ .stdio = .{
            .child = child,
            .pgid = pgid,
            .to_server = child.stdin.?,
            .from_server = child.stdout.?,
        } },
        .tools = &.{},
    };
    // Published for the interrupt handler, for the same reason a tool call's
    // child is: a server leads its own process group, so the terminal's Ctrl+C
    // never reaches it, and the `std.process.exit` the handler runs skips the
    // `shutdown` that would have stopped it. A server the table cannot hold is
    // stopped here rather than left outside the handler.
    if (!tool_mod.publishChildGroup(pgid)) {
        net.note(io, arena, "microagent: MCP server {s}: this run already tracks as many child process groups as it can; it is stopped and skipped\n", .{shown});
        server.reap(io);
        return;
    }
    out.append(arena, server) catch |err| {
        net.note(io, arena, "microagent: MCP server {s}: it could not be recorded ({s}); it is stopped and skipped\n", .{ shown, @errorName(err) });
        server.reap(io);
    };
}

/// Why a server was not started, named the way every other skipped server is:
/// a line on stderr, so an entry the operator wrote down does not read from
/// outside as one that was never configured.
fn skipped(io: Io, arena: std.mem.Allocator, shown: []const u8, what: []const u8, err: anyerror) void {
    net.note(io, arena, "microagent: MCP server {s}: {s} ({s}); it is skipped\n", .{ shown, what, @errorName(err) });
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
    const wire_version = switch (server.transport) {
        .stdio => protocol_version,
        .http => http_protocol_version,
    };
    var params_buf: [256]u8 = undefined;
    const init_params = std.fmt.bufPrint(&params_buf, "{{\"protocolVersion\":\"{s}\",\"capabilities\":{{}},\"clientInfo\":{{\"name\":\"microagent\",\"version\":\"{s}\"}}}}", .{
        wire_version,
        client_version,
    }) catch "{\"protocolVersion\":\"" ++ protocol_version ++ "\",\"capabilities\":{},\"clientInfo\":{\"name\":\"microagent\"}}";
    const initialized = server.request(io, arena, scratch, "initialize", init_params, timeout) catch return false;
    if (initialized != .object) {
        server.last_error = "initialize answered with no result object";
        return false;
    }
    switch (server.transport) {
        .http => |*http| http.negotiated = true,
        .stdio => {},
    }
    server.send(io, arena, null, "notifications/initialized", "") catch return false;
    const listed = server.request(io, arena, scratch, "tools/list", "", timeout) catch return false;
    server.tools = buildTools(io, arena, scratch, server, listed) orelse {
        server.last_error = "tools/list answered with no result object";
        return false;
    };
    return true;
}

/// The tool table a `tools/list` result turns into, in the order the server
/// listed them. Null when the answer is not a result object or an allocation
/// failed, which the caller cannot tell apart and reports the same way.
///
/// Split out of `handshake` because it is the one step of the connection that
/// turns bytes the server chose into names, descriptions and schemas this run
/// offers the model and sends back on every later turn, and it is the only
/// step that can be handed an answer without a server on the other end.
fn buildTools(io: Io, arena: std.mem.Allocator, scratch: std.mem.Allocator, server: *const Server, listed: std.json.Value) ?[]const Tool {
    const object = switch (listed) {
        .object => |o| o,
        else => return null,
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
        if (!validName(name)) {
            net.note(io, arena, "microagent: MCP server {s} offers a tool named {s}, which cannot be spelled in a tool name; it is skipped\n", .{ chat.safeTextAll(arena, server.name), chat.safeText(arena, name, max_shown_name_bytes) });
            continue;
        }
        // The exposed name is the server's name behind the prefix, so two
        // entries the server listed under one name are one tool offered twice:
        // the request would carry two `function.name` values the model cannot
        // tell apart, and `resolve` would answer only the first for the whole
        // run. The first listing wins, as it does for a name the server
        // spells twice under different schemas.
        if (indexOfToolName(found.items, name) != null) continue;
        const kept_name = arena.dupe(u8, name) catch return null;
        const exposed = std.fmt.allocPrint(arena, "{s}{s}__{s}", .{ tool_prefix, server.name, kept_name }) catch return null;
        if (terseForServer(server, name)) |terse| {
            const terse_description = presetDescription(arena, terse) catch return null;
            found.append(arena, .{ .name = kept_name, .exposed = exposed, .description = terse_description, .schema = terse.schema }) catch return null;
            continue;
        }
        const description = chat.str(entry.get("description")) orelse "";
        // Stringify grows through a ladder of buffers and only the last one is
        // the schema the request carries, so it is built in the scratch arena
        // and copied once into the run's.
        const schema_text = schemaJson(scratch, entry.get("inputSchema")) catch return null;
        const schema = arena.dupe(u8, schema_text) catch return null;
        found.append(arena, .{
            .name = kept_name,
            .exposed = exposed,
            .description = if (description.len == 0)
                std.fmt.allocPrint(arena, "MCP tool '{s}' from server '{s}'", .{ name, server.name }) catch return null
            else
                chat.safeText(arena, description, max_mcp_description_bytes),
            .schema = schema,
        }) catch return null;
    }
    return found.items;
}

// The shapes a `tools/list` answer really takes: the empty list, one tool, a
// name the model cannot be handed, a name that is not a string, a schema that
// is not an object, a schema over the ceiling, and an answer that is not the
// shape at all. `std.testing.fuzz` runs this corpus on every `zig build test`,
// and through the fuzzer's mutations when the test binary is built in fuzz
// mode.
const tools_corpus = [_][]const u8{
    \\{"tools":[]}
    \\{"tools":[{"name":"search","description":"Search the web","inputSchema":{"type":"object","properties":{"q":{"type":"string"}},"required":["q"]}}]}
    \\{"tools":[{"name":"read_file","description":"Read a file","inputSchema":{"type":"object"}}]}
    \\{"tools":[{"name":"bad name with spaces","description":"skipped"},{"name":"good","inputSchema":{"type":"object"}}]}
    \\{"tools":[{"name":"has__separator"},{"name":"UPPER.case-ok_1"}]}
    \\{"tools":[{"name":123},{"name":null},{"description":"no name at all"},{"name":"kept","description":42,"inputSchema":"not an object"}]}
    \\{"tools":[{"name":"a","inputSchema":{"type":"object"}},{"name":"b","inputSchema":{"type":"object"}},{"name":"c","inputSchema":{"type":"object"}}]}
    \\{"tools":[{"name":"","description":"empty name"},{"name":"kept2","inputSchema":{"type":"object"}}]}
    \\{"tools":"not an array"}
    \\{"tools":[1,2,3,{"name":"after the scalars"}]}
    \\{"result":{"tools":[{"name":"wrapped","description":"inside a result","inputSchema":{"type":"object"}}]}}
    \\{"tools":[{"name":"nul\u0000name"},{"name":"esc\u001b[31mname","description":"ansi"},{"name":"cjk-名前","description":"日本語の説明"}]}
    \\{"tools":[{"name":"dup"},{"name":"dup"}]}
    \\{}
    \\[],
    \\null,
    \\"",
    \\{"tools":[{"name":"schema_far_too_large","inputSchema":{"type":"object","description":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}]},
};

test "a fuzzed tools/list answer offers only tools the request can name and carry" {
    try std.testing.fuzz({}, fuzzTools, .{ .corpus = &tools_corpus });
}

/// A server's own list, read into the table every later turn sends. The
/// assertions are what a crash-only harness cannot say: the answer decides the
/// names, descriptions and schemas the model is offered, so a table that names
/// a tool twice, offers one whose name cannot be spelled, or carries a schema
/// that is not an object the provider accepts is wrong whether or not it
/// crashed.
fn fuzzTools(_: void, smith: *std.testing.Smith) !void {
    var raw: [32 * 1024]u8 = undefined;
    const bytes: []const u8 = if (smith.in) |seed| seed else raw[0..smith.slice(&raw)];

    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const arena = state.allocator();
    var scratch_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();

    // An answer is a result object, and a fuzzer that only ever produced valid
    // ones would never reach the object/array/string arms below it, so bytes
    // that are not an object are carried as the one member a real answer can
    // hold them in.
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{}) catch blk: {
        var jb = chat.JsonBuf.init(arena);
        const w = jb.writer();
        try w.writeAll("{\"tools\":");
        try chat.writeJsonString(w, bytes);
        try w.writeAll("}");
        break :blk try std.json.parseFromSliceLeaky(std.json.Value, arena, jb.items(), .{});
    };

    const server: Server = .{ .name = "srv", .transport = .{ .stdio = undefined }, .tools = &.{} };
    const built = buildTools(std.testing.io, arena, scratch, &server, parsed) orelse {
        // A non-object answer is refused, and a refusal leaves the table empty
        // rather than holding what a previous connection offered.
        try std.testing.expect(parsed != .object);
        return;
    };

    // Count what the answer offered, so the table can be held to it: a build
    // that drops an entry it should keep loses a tool the server has. A name
    // the answer listed twice is one tool, so it is counted once, as
    // `buildTools` keeps it once.
    var offered_names: std.StringHashMap(void) = .init(arena);
    if (parsed == .object) {
        if (parsed.object.get("tools")) |value| {
            if (value == .array) {
                for (value.array.items) |item| {
                    const entry = switch (item) {
                        .object => |o| o,
                        else => continue,
                    };
                    const name = chat.str(entry.get("name")) orelse continue;
                    if (!validName(name)) continue;
                    try offered_names.put(name, {});
                }
            }
        }
    }
    try std.testing.expectEqual(offered_names.count(), built.len);

    for (built, 0..) |tool, i| {
        // The half of the exposed name the model calls with, so a `tools/call`
        // built from it reaches the tool the server listed.
        try std.testing.expect(validName(tool.name));
        try std.testing.expect(tool.name.len <= max_name_bytes);
        var want: [512]u8 = undefined;
        const exposed = try std.fmt.bufPrint(&want, tool_prefix ++ "{s}__{s}", .{ server.name, tool.name });
        try std.testing.expectEqualStrings(exposed, tool.exposed);

        // Every schema on the table is copied into the request whole, and a
        // provider refuses an entry whose `parameters` is not an object, so the
        // ceiling and the object-ness are the two things asserted here.
        try std.testing.expect(tool.schema.len > 0);
        try std.testing.expect(tool.schema.len <= max_schema_bytes);
        const schema = try std.json.parseFromSliceLeaky(std.json.Value, scratch, tool.schema, .{});
        try std.testing.expect(schema == .object);

        // A description is read by the model and printed on the operator's
        // terminal, so it is bounded and carries no byte a terminal acts on.
        try std.testing.expect(tool.description.len > 0);
        try std.testing.expectEqual(@as(?usize, null), std.mem.indexOfScalar(u8, tool.description, 0x1b));

        // Two entries the model cannot tell apart are one tool called two
        // ways, and the second call lands on whichever the table kept.
        for (built[0..i]) |earlier| try std.testing.expect(!std.mem.eql(u8, earlier.name, tool.name));
    }
}

/// A tool's `inputSchema` as the request carries it: the server's own bytes
/// when they are an object and fit the ceiling, and an object schema that
/// names the omission when they are not. A tool with no schema still has to be
/// callable, and a provider refuses an entry whose `parameters` is not an
/// object, so both replacements are objects.
/// The size is checked on the stringified bytes rather than on the value,
/// because the value is what the server sent and the string is what every
/// later turn of the run pays for.
fn schemaJson(arena: std.mem.Allocator, value: ?std.json.Value) ![]const u8 {
    const v = value orelse return "{\"type\":\"object\"}";
    if (v != .object) return "{\"type\":\"object\"}";
    const text = try std.json.Stringify.valueAlloc(arena, v, .{});
    if (text.len > max_schema_bytes) return omitted_schema_json;
    return text;
}

// Every schema the request can carry is bounded, and a server's own bytes
// reach the request whole below that bound. Both ends are here because a cap
// that only rejects leaves the size it accepts untested, and a reader that cut
// too early would pass a test that only checks the cut.
test "a schema over the ceiling is replaced, and one under it is the server's own" {
    const gpa = std.testing.allocator;
    var state = std.heap.ArenaAllocator.init(gpa);
    defer state.deinit();
    const arena = state.allocator();

    // No schema, and one that is not an object, are the empty object schema
    // they were: a tool with nothing to say still has to be callable, and a
    // provider refuses an entry whose `parameters` is not an object.
    try std.testing.expectEqualStrings("{\"type\":\"object\"}", try schemaJson(arena, null));
    try std.testing.expectEqualStrings("{\"type\":\"object\"}", try schemaJson(arena, .null));
    try std.testing.expectEqualStrings("{\"type\":\"object\"}", try schemaJson(arena, .{ .integer = 1 }));

    // A schema the model can use reaches the request as the server wrote it,
    // members in the order the server wrote them: a rewrite that reordered them
    // would be a change to the byte prefix the provider caches on.
    const small = try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\{"type":"object","properties":{"text":{"type":"string"}},"required":["text"]}
    , .{});
    const kept = try schemaJson(arena, small);
    try std.testing.expectEqualStrings(
        \\{"type":"object","properties":{"text":{"type":"string"}},"required":["text"]}
    , kept);

    // And one past the ceiling is the replacement, which is short, is an
    // object a provider accepts, and says the arguments are not described
    // rather than leaving the model to infer them from a tool with no schema.
    var big_state = std.heap.ArenaAllocator.init(gpa);
    defer big_state.deinit();
    const big_arena = big_state.allocator();
    const big = try std.fmt.allocPrint(big_arena,
        \\{{"type":"object","properties":{{"s":{{"type":"string","description":"{s}"}}}}}}
    , .{"x" ** (max_schema_bytes + 1024)});
    const omitted = try schemaJson(arena, try std.json.parseFromSliceLeaky(std.json.Value, big_arena, big, .{}));
    try std.testing.expectEqualStrings(omitted_schema_json, omitted);
    try std.testing.expect(omitted.len < max_schema_bytes);
    // A provider parses `parameters` as an object, so the replacement is one.
    try std.testing.expect(try std.json.parseFromSliceLeaky(std.json.Value, arena, omitted, .{}) == .object);
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
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = io };
    defer client.deinit();
    var servers = connect(io, arena, &env, &client, &entries, "test");
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
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = io };
    defer client.deinit();
    var servers = connect(io, arena, &env, &client, &entries, "test");
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
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = io };
    defer client.deinit();
    var servers = connect(io, run, &env, &client, &entries, "test");
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
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = io };
    defer client.deinit();
    var servers = connect(io, run, &env, &client, &entries, "test");
    defer servers.shutdown(io);

    try std.testing.expectEqual(@as(usize, 1), servers.items.len);
    try std.testing.expect(servers.resolve("mcp__big__echo") != null);
    try std.testing.expectEqual(@as(usize, 0), servers.items[0].transport.stdio.pending.capacity);
    try std.testing.expect(run_state.queryCapacity() < 1024 * 1024);
}

// The rule `validName` holds a server and a tool name to, asked directly
// rather than through a config file: the length bound is a property of the
// function, and a config table can only say it about one name at a time.
test "a name is half of an exposed tool name only when it can be spelled" {
    try std.testing.expect(validName("fs"));
    try std.testing.expect(validName("a-b_c.d9"));
    try std.testing.expect(!validName(""));
    // The pair that separates the three parts of an exposed name, so a name
    // holding it is refused however else it is spelled.
    try std.testing.expect(!validName("a__b"));
    try std.testing.expect(!validName("bad name"));
    try std.testing.expect(!validName("a/b"));
    try std.testing.expect(!validName("a\u{1b}[31m"));

    // The bound is on the bytes, not the characters: the name is written into
    // the schema and read back off the wire, and a 65-byte name that was 33
    // characters is still past what a tool name may hold.
    try std.testing.expect(validName("a" ** 64));
    try std.testing.expect(!validName("a" ** 65));
}

test "a server that cannot be started, or that exits, is skipped" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const arena = state.allocator();
    const io = std.testing.io;

    var env: std.process.Environ.Map = .init(arena);
    const missing = [_]Entry{.{ .name = "gone", .command = "definitely-not-a-real-command-xyz" }};
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = io };
    defer client.deinit();
    var none = connect(io, arena, &env, &client, &missing, "test");
    defer none.shutdown(io);
    try std.testing.expectEqual(@as(usize, 0), none.items.len);

    // A child that exits before answering leaves nothing to resolve, and the
    // run keeps the servers it did connect.
    const exits = [_]Entry{.{ .name = "exit", .command = "/bin/sh", .args = &.{ "-c", "exit 0" } }};
    var gone = connect(io, arena, &env, &client, &exits, "test");
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
            try std.testing.expect(described.len <= max_mcp_description_bytes + 32);
    }

    const result = object.get("result") orelse return;
    if (result != .object) return;
    // Both paths are held to the cap the caller clamps with, so a frame that
    // reaches either of them is bounded before it becomes a tool result. A
    // result with no content at all is one neither path reads.
    if (result.object.get("content") == null and result.object.get("structuredContent") == null) return;
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

// A server that answers the handshake and then goes away is the ordinary way
// one dies mid-run: the model has the tool in its schema and calls it again
// after the child is gone. The first call says the server did not answer and
// names why, the second says it is no longer running rather than spending the
// whole call budget on a second wait for a pipe that has already ended, and
// the run keeps the servers it did connect.
test "a server that dies after the handshake is named once and then left" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const arena = state.allocator();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = path_buf[0..try tmp.dir.realPath(io, &path_buf)];
    // The two handshake answers, then the call ends the process without
    // answering it. A `read` that sees end of stream is how a server that
    // exited is told from one that is slow: a server that ignored the call and
    // kept reading would time out instead, which is a different fault.
    const script = try std.fmt.allocPrint(arena,
        \\while IFS= read -r line; do
        \\  case "$line" in
        \\    *'"method":"initialize"'*) printf '%s\n' '{{"jsonrpc":"2.0","id":1,"result":{{"protocolVersion":"{s}","capabilities":{{"tools":{{}}}}}}}}' ;;
        \\    *'"method":"tools/list"'*) printf '%s\n' '{{"jsonrpc":"2.0","id":2,"result":{{"tools":[{{"name":"echo","inputSchema":{{"type":"object"}}}}]}}}}' ;;
        \\    *'"method":"tools/call"'*) exit 0 ;;
        \\  esac
        \\done
    , .{protocol_version});
    try tmp.dir.writeFile(io, .{ .sub_path = "dying.sh", .data = script });
    const path = try std.fs.path.join(arena, &.{ base, "dying.sh" });

    var env: std.process.Environ.Map = .init(arena);
    const entries = [_]Entry{.{ .name = "dying", .command = "/bin/sh", .args = &.{path} }};
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = io };
    defer client.deinit();
    var servers = connect(io, arena, &env, &client, &entries, "test");
    defer servers.shutdown(io);
    const resolved = servers.resolve("mcp__dying__echo") orelse return error.TestUnexpectedResult;
    try std.testing.expect(!resolved.server.dead);

    const first = try Servers.call(io, arena, resolved, "{}", net.durationMs(10_000));
    try std.testing.expect(std.mem.indexOf(u8, first, "did not answer mcp__dying__echo") != null);
    try std.testing.expect(resolved.server.dead);

    const second = try Servers.call(io, arena, resolved, "{}", net.durationMs(10_000));
    try std.testing.expectEqualStrings("error: MCP server dying is no longer running (ServerGone)", second);
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

    // The shapes that are not a result object, and the one that is an object
    // with nothing in it, are each said rather than handed to the model as
    // empty text it cannot act on.
    const not_object = try std.json.parseFromSliceLeaky(std.json.Value, arena, "\"pong\"", .{});
    try std.testing.expectEqualStrings("error: MCP server srv answered with string, not a result object", try resultText(arena, "srv", not_object));
    const no_content = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"isError\":false}", .{});
    try std.testing.expectEqualStrings("error: MCP result carried no content", try resultText(arena, "srv", no_content));

    // A result whose blocks are all unusable names each of them rather than
    // adding up to nothing, so the model is told the server answered.
    const unnamed = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"content\":[{\"type\":\"image\"}]}", .{});
    try std.testing.expectEqualStrings("[image content from MCP server srv, not shown]", try resultText(arena, "srv", unnamed));

    // And a result with no blocks at all says so, rather than returning the
    // empty string a call clamps and hands on as a tool result.
    const empty = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"content\":[]}", .{});
    try std.testing.expectEqualStrings("(the MCP server returned no text)", try resultText(arena, "srv", empty));
}

// A server's own text is read by the model like any other tool result, and the
// cap that bounds it cuts on a codepoint boundary like every other one. This
// pins that: the text arriving whole is the text the model is handed, and a
// result the cap reached is whole too rather than ending in the first byte of a
// character the server sent. Both are the property, whatever the cut does on
// the way there.
test "a text result cut at the cap keeps whole characters" {
    const gpa = std.testing.allocator;
    var state = std.heap.ArenaAllocator.init(gpa);
    defer state.deinit();
    const arena = state.allocator();

    // One character wider than the room the cap leaves after the note the
    // result over the cap is given, so the cut lands inside it whichever way
    // the two ends of the cap fall.
    const filler = "a" ** (tool_mod.max_tool_output - 1);
    const body = try std.fmt.allocPrint(arena,
        \\{{"content":[{{"type":"text","text":"{s}"}}]}}
    , .{filler ++ "\u{65e5}\u{65e5}\u{65e5}"});

    const cut = try resultText(arena, "srv", try std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}));
    try std.testing.expect(cut.len <= tool_mod.max_tool_output);
    try std.testing.expect(std.mem.indexOf(u8, cut, "tool output truncated") != null);
    // The property, spelled directly: what the model is handed is text.
    try std.testing.expect(std.unicode.utf8ValidateSlice(cut));

    // An astral character, which is four bytes and the widest the request body
    // will carry, cut the same way.
    var emoji_state = std.heap.ArenaAllocator.init(gpa);
    defer emoji_state.deinit();
    const emoji_arena = emoji_state.allocator();
    const emoji = try std.fmt.allocPrint(emoji_arena,
        \\{{"content":[{{"type":"text","text":"{s}"}}]}}
    , .{"b" ** (tool_mod.max_tool_output - 2) ++ "\u{1f600}\u{1f600}"});
    const cut_emoji = try resultText(arena, "srv", try std.json.parseFromSliceLeaky(std.json.Value, emoji_arena, emoji, .{}));
    try std.testing.expect(cut_emoji.len <= tool_mod.max_tool_output);
    try std.testing.expect(std.unicode.utf8ValidateSlice(cut_emoji));
}

// A server's structured result is server output the model reads, so it is
// bounded like the text path rather than trusted to be small. The two ends of
// the cap are both here: a payload under it arrives whole, and one over it
// arrives under the cap with a note naming the size the whole would have had,
// because a result the model cannot parse reads to it as the whole of one.
test "a structured result over the cap is cut, marked, and named for its size" {
    const gpa = std.testing.allocator;
    var state = std.heap.ArenaAllocator.init(gpa);
    defer state.deinit();
    const arena = state.allocator();

    // Under the cap, whole and unannotated: nothing was dropped, so a note
    // saying so would be the run lying about a result it kept.
    const small = try std.fmt.allocPrint(arena,
        \\{{"structuredContent":{{"n":1,"s":"{s}"}}}}
    , .{"x" ** 1024});
    const kept = try resultText(arena, "srv", try std.json.parseFromSliceLeaky(std.json.Value, arena, small, .{}));
    try std.testing.expect(kept.len <= tool_mod.max_tool_output);
    try std.testing.expect(std.mem.indexOf(u8, kept, "tool output truncated") == null);
    try std.testing.expect(std.mem.indexOf(u8, kept, "x" ** 1024) != null);

    // Over it, and the value is built here rather than spelled out, so the
    // test says which size it wrote rather than carrying it.
    var big_state = std.heap.ArenaAllocator.init(gpa);
    defer big_state.deinit();
    const big_arena = big_state.allocator();
    const big = try std.fmt.allocPrint(big_arena,
        \\{{"structuredContent":{{"s":"{s}"}}}}
    , .{"y" ** (tool_mod.max_tool_output * 2)});
    const cut = try resultText(arena, "srv", try std.json.parseFromSliceLeaky(std.json.Value, big_arena, big, .{}));
    try std.testing.expect(cut.len <= tool_mod.max_tool_output);
    const marker = "... [tool output truncated at ";
    const at = std.mem.indexOf(u8, cut, marker) orelse return error.TestUnexpectedResult;
    const rest = cut[at + marker.len ..];
    const of_at = std.mem.indexOf(u8, rest, " of ") orelse return error.TestUnexpectedResult;
    const cap_at = std.fmt.parseInt(u64, rest[0..of_at], 10) catch return error.TestUnexpectedResult;
    const after = rest[of_at + " of ".len ..];
    const bytes_at = std.mem.indexOfScalar(u8, after, ' ') orelse return error.TestUnexpectedResult;
    const total = std.fmt.parseInt(u64, after[0..bytes_at], 10) catch return error.TestUnexpectedResult;
    try std.testing.expectEqual(tool_mod.max_tool_output, cap_at);
    try std.testing.expect(total > cap_at);
    try std.testing.expect(std.mem.endsWith(u8, cut, "bytes]"));
}

// The pure checks a remote entry passes before anything is sent: what a url,
// a variable name and a header name may be. Each accepts the ordinary spelling
// and refuses the one that would be a leak or a split request.
test "a remote entry's url, key variable and key header are held to what they can safely be" {
    try std.testing.expect(validUrl("https://mcp.exa.ai/mcp"));
    try std.testing.expect(validUrl("http://127.0.0.1:8080/mcp"));
    try std.testing.expect(validUrl("http://localhost/mcp"));
    // The key would cross the network in the clear, or the url would carry
    // its own credentials next to the entry's.
    try std.testing.expect(!validUrl("http://mcp.example.com/mcp"));
    try std.testing.expect(!validUrl("https://user:pw@mcp.example.com/mcp"));
    try std.testing.expect(!validUrl("ftp://mcp.example.com/mcp"));
    try std.testing.expect(!validUrl("not a url"));
    try std.testing.expect(!validUrl(""));

    try std.testing.expect(validEnvName("EXA_API_KEY"));
    try std.testing.expect(!validEnvName(""));
    try std.testing.expect(!validEnvName("A=B"));
    try std.testing.expect(!validEnvName("KEY NAME"));
    try std.testing.expect(!validEnvName("$KEY"));

    try std.testing.expect(validHeaderName("Authorization"));
    try std.testing.expect(validHeaderName("X-Api-Key"));
    try std.testing.expect(!validHeaderName(""));
    try std.testing.expect(!validHeaderName("X Api Key"));
    try std.testing.expect(!validHeaderName("X-Key:"));
    try std.testing.expect(!validHeaderName("X-Key\r\nHost"));

    // The bound is the same one `validName` carries, on the two names that
    // reach the wire beside the entry's url. A name past it is refused rather
    // than truncated, so a server that answers nothing names the entry's own
    // field instead of an arbitrary prefix of it.
    try std.testing.expect(validEnvName("A" ** 64));
    try std.testing.expect(!validEnvName("A" ** 65));
    try std.testing.expect(validHeaderName("A" ** 64));
    try std.testing.expect(!validHeaderName("A" ** 65));
}

test "a key is read from the environment by the name the entry gives" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const arena = state.allocator();

    var env: std.process.Environ.Map = .init(arena);
    try env.put("SET_KEY", " sk-live\n");
    try env.put("EMPTY_KEY", "");
    const entries = [_]Entry{
        .{ .name = "a", .url = "https://a.example/mcp", .api_key_env = "SET_KEY" },
        .{ .name = "b", .url = "https://b.example/mcp", .api_key_env = "EMPTY_KEY" },
        .{ .name = "c", .url = "https://c.example/mcp", .api_key_env = "UNSET_KEY" },
        .{ .name = "d", .url = "https://d.example/mcp" },
    };
    const keyed = try withKeys(arena, &env, &entries);
    try std.testing.expectEqualStrings("sk-live", keyed[0].api_key);
    // Unset, empty and unnamed are all no key, not an error.
    try std.testing.expectEqualStrings("", keyed[1].api_key);
    try std.testing.expectEqualStrings("", keyed[2].api_key);
    try std.testing.expectEqualStrings("", keyed[3].api_key);
    try std.testing.expectEqualStrings("SET_KEY", keyed[0].api_key_env);
}

// A streamable-HTTP MCP server on 127.0.0.1, answering from a thread. Every
// reply closes its connection, so each request is one accept, and the raw text
// of each request is kept for the test to read once the server is stopped.
const FakeMcp = struct {
    io: Io,
    gpa: std.mem.Allocator,
    listener: Io.net.Server,
    port: u16,
    flavor: Flavor,
    thread: std.Thread = undefined,
    stopping: std.atomic.Value(bool) = .init(false),
    seen: std.ArrayList([]u8) = .empty,

    /// What the server does at a `tools/call`, or to everything.
    const Flavor = enum {
        /// SSE with a notification first, plain JSON for the list, an echo of
        /// the session id it hands out.
        normal,
        /// 401 to every request.
        unauthorized,
        /// 500 to the call.
        call_status,
        /// An event stream that carries no answer to the call.
        no_answer,
        /// A body past the frame ceiling.
        oversize,
        /// Reads the call and never answers.
        hang,
        /// A JSON-RPC error for the call.
        call_error,
    };

    const init_frame = "{\"result\":{\"protocolVersion\":\"2025-03-26\",\"capabilities\":{\"tools\":{}},\"serverInfo\":{\"name\":\"fake\",\"version\":\"1\"}},\"jsonrpc\":\"2.0\",\"id\":1}";
    const list_frame = "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"tools\":[{\"name\":\"echo\",\"description\":\"Echo text back\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"text\":{\"type\":\"string\"}}}}]}}";
    const call_frame = "{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"pong\"}]}}";
    const note_event = "event: message\ndata: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/message\",\"params\":{\"level\":\"info\"}}\n\n";
    const session_id = "sess-7f3a";

    fn start(gpa: std.mem.Allocator, io: Io, flavor: Flavor) !*FakeMcp {
        const self = try gpa.create(FakeMcp);
        errdefer gpa.destroy(self);
        const address = try Io.net.IpAddress.parseIp4("127.0.0.1", 0);
        var listener = try address.listen(io, .{});
        errdefer listener.deinit(io);
        self.* = .{ .io = io, .gpa = gpa, .listener = listener, .port = listener.socket.address.getPort(), .flavor = flavor };
        self.thread = try std.Thread.spawn(.{}, serve, .{self});
        return self;
    }

    /// Stops the thread by handing its blocked `accept` one last connection.
    fn finish(self: *FakeMcp) void {
        self.stopping.store(true, .release);
        if (self.listener.socket.address.connect(self.io, .{ .mode = .stream })) |wake| wake.close(self.io) else |_| {}
        self.thread.join();
        self.listener.deinit(self.io);
        for (self.seen.items) |raw| self.gpa.free(raw);
        self.seen.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    fn url(self: *FakeMcp, arena: std.mem.Allocator) ![]const u8 {
        return std.fmt.allocPrint(arena, "http://127.0.0.1:{d}/mcp", .{self.port});
    }

    fn serve(self: *FakeMcp) void {
        while (true) {
            const stream = self.listener.accept(self.io) catch return;
            defer stream.close(self.io);
            if (self.stopping.load(.acquire)) return;
            self.handle(stream) catch {};
        }
    }

    fn handle(self: *FakeMcp, stream: Io.net.Stream) !void {
        var read_buf: [4096]u8 = undefined;
        var reader = stream.reader(self.io, &read_buf);
        var write_buf: [1024]u8 = undefined;
        var writer = stream.writer(self.io, &write_buf);

        var request: std.ArrayList(u8) = .empty;
        defer request.deinit(self.gpa);
        var body_len: usize = 0;
        while (true) {
            const line = try reader.interface.takeDelimiterInclusive('\n');
            try request.appendSlice(self.gpa, line);
            if (std.ascii.startsWithIgnoreCase(line, "content-length:"))
                body_len = try std.fmt.parseInt(usize, std.mem.trim(u8, line["content-length:".len..], " \r\n"), 10);
            if (line.len <= 2) break;
        }
        const body = try request.addManyAsSlice(self.gpa, body_len);
        try reader.interface.readSliceAll(body);
        try self.seen.append(self.gpa, try self.gpa.dupe(u8, request.items));

        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.gpa);
        if (!try self.answer(request.items, &out)) {
            // Never answered: wait for the client to give up and hang up.
            while (true) _ = reader.interface.takeByte() catch return;
        }
        try writer.interface.writeAll(out.items);
        try writer.interface.flush();
    }

    /// The response to one request, or false for none.
    fn answer(self: *FakeMcp, request: []const u8, out: *std.ArrayList(u8)) !bool {
        const has = struct {
            fn in(text: []const u8, needle: []const u8) bool {
                return std.mem.indexOf(u8, text, needle) != null;
            }
        }.in;
        if (self.flavor == .unauthorized) {
            try self.reply(out, "401 Unauthorized", "", "no");
            return true;
        }
        if (has(request, "\"method\":\"initialize\"")) {
            try self.reply(out, "200 OK", "Content-Type: text/event-stream\r\nMcp-Session-Id: " ++ session_id ++ "\r\n", note_event ++ "event: message\ndata: " ++ init_frame ++ "\n\n");
        } else if (has(request, "\"method\":\"notifications/initialized\"")) {
            try self.reply(out, "202 Accepted", "", "");
        } else if (has(request, "\"method\":\"tools/list\"")) {
            try self.reply(out, "200 OK", "Content-Type: application/json\r\n", list_frame);
        } else switch (self.flavor) {
            .normal => try self.reply(out, "200 OK", "Content-Type: text/event-stream\r\n", note_event ++ "event: message\ndata: " ++ call_frame ++ "\n\n"),
            .call_status => try self.reply(out, "500 Internal Server Error", "", "boom"),
            .no_answer => try self.reply(out, "200 OK", "Content-Type: text/event-stream\r\n", note_event),
            .oversize => {
                const pad = max_frame_bytes + 1024;
                try out.print(self.gpa, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{pad});
                try out.appendNTimes(self.gpa, 'x', pad);
            },
            .hang => return false,
            .call_error => try self.reply(out, "200 OK", "Content-Type: application/json\r\n", "{\"jsonrpc\":\"2.0\",\"id\":3,\"error\":{\"code\":-32602,\"message\":\"bad args\"}}"),
            .unauthorized => unreachable,
        }
        return true;
    }

    fn reply(self: *FakeMcp, out: *std.ArrayList(u8), status: []const u8, headers: []const u8, body: []const u8) !void {
        try out.print(self.gpa, "HTTP/1.1 {s}\r\nContent-Length: {d}\r\nConnection: close\r\n{s}\r\n", .{ status, body.len, headers });
        try out.appendSlice(self.gpa, body);
    }
};

/// One connected fake server: the handshake done over loopback HTTP.
fn connectFake(io: Io, arena: std.mem.Allocator, client: *std.http.Client, fake: *FakeMcp, entry: Entry) !Servers {
    var keyed = entry;
    keyed.url = try fake.url(arena);
    var env: std.process.Environ.Map = .init(arena);
    return connect(io, arena, &env, client, &.{keyed}, "test");
}

// The whole client against a real socket: an event stream with a notification
// ahead of the answer, a plain JSON answer, a 202 to the notification, and the
// session id the first answer hands out coming back on every later request
// along with the protocol revision.
test "a streamable-HTTP server is connected, listed and called over loopback" {
    const gpa = std.testing.allocator;
    var state = std.heap.ArenaAllocator.init(gpa);
    defer state.deinit();
    const arena = state.allocator();
    const io = std.testing.io;

    const fake = try FakeMcp.start(gpa, io, .normal);
    defer fake.finish();
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    var servers = try connectFake(io, arena, &client, fake, .{ .name = "fake" });
    defer servers.shutdown(io);

    try std.testing.expectEqual(@as(usize, 1), servers.items.len);
    const resolved = servers.resolve("mcp__fake__echo") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("pong", try Servers.call(io, arena, resolved, "{\"text\":\"hi\"}", net.durationMs(10_000)));
    try std.testing.expect(std.mem.indexOf(u8, try servers.toolsJson(arena), "\"description\":\"Echo text back\"") != null);

    // initialize, the notification, tools/list, tools/call.
    try std.testing.expectEqual(@as(usize, 4), fake.seen.items.len);
    const first = fake.seen.items[0];
    try std.testing.expect(std.mem.startsWith(u8, first, "POST /mcp HTTP/1.1\r\n"));
    try std.testing.expect(std.ascii.indexOfIgnoreCase(first, "content-type: application/json\r\n") != null);
    try std.testing.expect(std.ascii.indexOfIgnoreCase(first, "accept: application/json, text/event-stream\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "\"protocolVersion\":\"2025-03-26\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "\"clientInfo\":{\"name\":\"microagent\",\"version\":\"test\"}") != null);
    // Nothing to echo before the server has said anything.
    try std.testing.expect(std.ascii.indexOfIgnoreCase(first, "mcp-session-id") == null);
    try std.testing.expect(std.ascii.indexOfIgnoreCase(first, "mcp-protocol-version") == null);
    for (fake.seen.items[1..]) |later| {
        try std.testing.expect(std.ascii.indexOfIgnoreCase(later, "mcp-session-id: " ++ FakeMcp.session_id ++ "\r\n") != null);
        try std.testing.expect(std.ascii.indexOfIgnoreCase(later, "mcp-protocol-version: 2025-03-26\r\n") != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, fake.seen.items[1], "\"method\":\"notifications/initialized\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, fake.seen.items[1], "\"id\"") == null);
}

// A preset's shape against a real socket: the tool table exists before
// anything is sent, so the server is asked for nothing until the model calls a
// tool, and the handshake rides along with that call. The tool the model named
// is looked up again in the answer, which is what makes a server that renamed
// it a sentence rather than a `tools/call` for a name it does not have.
test "a lazy server is handshaken by its first call, not before it" {
    const gpa = std.testing.allocator;
    var state = std.heap.ArenaAllocator.init(gpa);
    defer state.deinit();
    const arena = state.allocator();
    const io = std.testing.io;

    const fake = try FakeMcp.start(gpa, io, .normal);
    defer fake.finish();
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    const advertised = [_]Tool{.{
        .name = "echo",
        .exposed = "mcp__fake__echo",
        .description = "from the table in this binary",
        .schema = "{\"type\":\"object\"}",
    }};
    var storage: [1]Server = .{.{
        .name = "fake",
        .transport = .{ .http = .{
            .client = &client,
            .uri = try std.Uri.parse(try fake.url(arena)),
            .timeout_ms = 10_000,
        } },
        .tools = &advertised,
        .lazy = true,
        .client_version = "test",
    }};
    var servers: Servers = .{ .items = &storage };
    defer servers.shutdown(io);

    // Nothing has been sent: the schema the model sees came from this binary.
    try std.testing.expectEqual(@as(usize, 0), fake.seen.items.len);
    const resolved = servers.resolve("mcp__fake__echo") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("pong", try Servers.call(io, arena, resolved, "{\"text\":\"hi\"}", net.durationMs(10_000)));
    try std.testing.expect(!storage[0].lazy);
    // initialize, the notification, tools/list, tools/call.
    try std.testing.expectEqual(@as(usize, 4), fake.seen.items.len);
    try std.testing.expect(std.mem.indexOf(u8, fake.seen.items[2], "\"method\":\"tools/list\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, fake.seen.items[3], "\"method\":\"tools/call\"") != null);
}

test "the key is sent as a bearer token in Authorization and raw in any other header" {
    const gpa = std.testing.allocator;
    var state = std.heap.ArenaAllocator.init(gpa);
    defer state.deinit();
    const arena = state.allocator();
    const io = std.testing.io;

    const fake = try FakeMcp.start(gpa, io, .normal);
    defer fake.finish();
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    var bearer = try connectFake(io, arena, &client, fake, .{ .name = "one", .api_key = "s3cret", .api_key_env = "K" });
    defer bearer.shutdown(io);
    var custom = try connectFake(io, arena, &client, fake, .{ .name = "two", .api_key = "s3cret", .api_key_header = "X-Api-Key" });
    defer custom.shutdown(io);
    var keyless = try connectFake(io, arena, &client, fake, .{ .name = "three" });
    defer keyless.shutdown(io);
    try std.testing.expectEqual(@as(usize, 1), bearer.items.len);
    try std.testing.expectEqual(@as(usize, 1), custom.items.len);
    try std.testing.expectEqual(@as(usize, 1), keyless.items.len);

    // Three handshakes of three requests, in order.
    try std.testing.expectEqual(@as(usize, 9), fake.seen.items.len);
    for (fake.seen.items[0..3]) |raw| {
        try std.testing.expect(std.ascii.indexOfIgnoreCase(raw, "authorization: Bearer s3cret\r\n") != null);
        try std.testing.expect(std.ascii.indexOfIgnoreCase(raw, "x-api-key") == null);
    }
    for (fake.seen.items[3..6]) |raw| {
        try std.testing.expect(std.ascii.indexOfIgnoreCase(raw, "x-api-key: s3cret\r\n") != null);
        try std.testing.expect(std.ascii.indexOfIgnoreCase(raw, "authorization") == null);
        try std.testing.expect(std.mem.indexOf(u8, raw, "Bearer") == null);
    }
    for (fake.seen.items[6..9]) |raw| {
        try std.testing.expect(std.ascii.indexOfIgnoreCase(raw, "authorization") == null);
        try std.testing.expect(std.ascii.indexOfIgnoreCase(raw, "s3cret") == null);
    }
}

test "a remote server that refuses the handshake is skipped, and one that fails a call says why" {
    const gpa = std.testing.allocator;
    var state = std.heap.ArenaAllocator.init(gpa);
    defer state.deinit();
    const arena = state.allocator();
    const io = std.testing.io;
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    const closed = try FakeMcp.start(gpa, io, .unauthorized);
    defer closed.finish();
    var none = try connectFake(io, arena, &client, closed, .{ .name = "closed" });
    defer none.shutdown(io);
    try std.testing.expectEqual(@as(usize, 0), none.items.len);

    // A url nothing listens on is the same skip, not a failed run.
    const gone = try FakeMcp.start(gpa, io, .normal);
    const dead_url = try gone.url(arena);
    gone.finish();
    var env: std.process.Environ.Map = .init(arena);
    var refused = connect(io, arena, &env, &client, &.{.{ .name = "gone", .url = dead_url }}, "test");
    defer refused.shutdown(io);
    try std.testing.expectEqual(@as(usize, 0), refused.items.len);

    // A url that is not https, and not this machine, is never contacted.
    var clear = connect(io, arena, &env, &client, &.{.{ .name = "clear", .url = "http://mcp.example.com/mcp" }}, "test");
    defer clear.shutdown(io);
    try std.testing.expectEqual(@as(usize, 0), clear.items.len);

    const status = try FakeMcp.start(gpa, io, .call_status);
    defer status.finish();
    var failing = try connectFake(io, arena, &client, status, .{ .name = "fail" });
    defer failing.shutdown(io);
    const call = failing.resolve("mcp__fail__echo") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("error: MCP server fail refused mcp__fail__echo: HTTP 500", try Servers.call(io, arena, call, "{}", net.durationMs(10_000)));
    // A refusal is the server's answer, not the end of it: the next call is made.
    try std.testing.expect(!call.server.dead);

    const refusing = try FakeMcp.start(gpa, io, .call_error);
    defer refusing.finish();
    var erroring = try connectFake(io, arena, &client, refusing, .{ .name = "err" });
    defer erroring.shutdown(io);
    const errored = erroring.resolve("mcp__err__echo") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("error: MCP server err refused mcp__err__echo: bad args (code -32602)", try Servers.call(io, arena, errored, "{}", net.durationMs(10_000)));
}

test "remote servers connect together, keep the config order, and one that fails is skipped" {
    const gpa = std.testing.allocator;
    var state = std.heap.ArenaAllocator.init(gpa);
    defer state.deinit();
    const arena = state.allocator();
    const io = std.testing.io;
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    const first = try FakeMcp.start(gpa, io, .normal);
    defer first.finish();
    const refusing = try FakeMcp.start(gpa, io, .unauthorized);
    defer refusing.finish();
    const last = try FakeMcp.start(gpa, io, .normal);
    defer last.finish();

    var env: std.process.Environ.Map = .init(arena);
    const entries = [_]Entry{
        .{ .name = "one", .url = try first.url(arena) },
        .{ .name = "two", .url = try refusing.url(arena) },
        .{ .name = "three", .url = try last.url(arena) },
    };
    var servers = connect(io, arena, &env, &client, &entries, "test");
    defer servers.shutdown(io);

    try std.testing.expectEqual(@as(usize, 2), servers.items.len);
    try std.testing.expectEqualStrings("one", servers.items[0].name);
    try std.testing.expectEqualStrings("three", servers.items[1].name);
    const json = try servers.toolsJson(arena);
    try std.testing.expect(std.mem.indexOf(u8, json, "mcp__one__echo").? < std.mem.indexOf(u8, json, "mcp__three__echo").?);
}

test "a stream that ends without the answer, and a body past the ceiling, are errors" {
    const gpa = std.testing.allocator;
    var state = std.heap.ArenaAllocator.init(gpa);
    defer state.deinit();
    const arena = state.allocator();
    const io = std.testing.io;
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    const silent = try FakeMcp.start(gpa, io, .no_answer);
    defer silent.finish();
    var quiet = try connectFake(io, arena, &client, silent, .{ .name = "quiet" });
    defer quiet.shutdown(io);
    const asked = quiet.resolve("mcp__quiet__echo") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("error: MCP server quiet did not answer mcp__quiet__echo (StreamEndedWithoutAnswer)", try Servers.call(io, arena, asked, "{}", net.durationMs(10_000)));

    const big = try FakeMcp.start(gpa, io, .oversize);
    defer big.finish();
    var flood = try connectFake(io, arena, &client, big, .{ .name = "flood" });
    defer flood.shutdown(io);
    const flooded = flood.resolve("mcp__flood__echo") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("error: MCP server flood did not answer mcp__flood__echo (ResponseTooLarge)", try Servers.call(io, arena, flooded, "{}", net.durationMs(10_000)));
}

// A server that reads the call and says nothing costs the call its deadline and
// nothing more: the test would hang on a client that waited for it, so the
// bound is asserted on the clock as well as on the answer.
test "a remote server that never answers a call times out and is not asked again" {
    const gpa = std.testing.allocator;
    var state = std.heap.ArenaAllocator.init(gpa);
    defer state.deinit();
    const arena = state.allocator();
    const io = std.testing.io;
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    const fake = try FakeMcp.start(gpa, io, .hang);
    defer fake.finish();
    var servers = try connectFake(io, arena, &client, fake, .{ .name = "slow" });
    defer servers.shutdown(io);
    const resolved = servers.resolve("mcp__slow__echo") orelse return error.TestUnexpectedResult;

    const started = Io.Timestamp.now(io, .awake);
    const first = try Servers.call(io, arena, resolved, "{}", net.durationMs(400));
    const took_ms = @divTrunc(started.durationTo(Io.Timestamp.now(io, .awake)).nanoseconds, std.time.ns_per_ms);
    try std.testing.expectEqualStrings("error: MCP server slow did not answer mcp__slow__echo (Timeout)", first);
    try std.testing.expect(took_ms < 5_000);
    try std.testing.expect(resolved.server.dead);
    try std.testing.expectEqualStrings("error: MCP server slow is no longer running (Timeout)", try Servers.call(io, arena, resolved, "{}", net.durationMs(400)));
}

// The reader every remote answer goes through, fed bytes the way a server
// broken or hostile would send them. Whatever the body, it ends in an answer or
// an error inside the ceiling, and a result it returns is one the frame reader
// then turns into a bounded tool result.
test "a fuzzed remote body is an answer or an error, never a crash" {
    try std.testing.fuzz({}, fuzzBody, .{ .corpus = &body_corpus });
}

const body_corpus = [_][]const u8{
    "",
    "\n\n",
    "data: {\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}\n\n",
    "data: {\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}",
    "event: message\r\ndata: {\"jsonrpc\":\"2.0\",\"id\":1,\r\ndata: \"result\":{}}\r\n\r\n",
    ": comment\ndata:\n\ndata: [1]\n\ndata: {\"id\":2}\n\n",
    "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"a\"}]}}",
    "[{\"jsonrpc\":\"2.0\",\"method\":\"n\"},{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}]",
    "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":1,\"message\":\"no\"}}",
    "not json",
};

fn fuzzBody(_: void, smith: *std.testing.Smith) !void {
    var raw: [16 * 1024]u8 = undefined;
    const bytes: []const u8 = if (smith.in) |seed| seed else raw[0..smith.slice(&raw)];
    for ([_]bool{ true, false }) |is_sse| {
        var state = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer state.deinit();
        const arena = state.allocator();
        var server: Server = .{ .name = "fuzz", .transport = undefined, .tools = &.{} };
        var reader: Io.Reader = .fixed(bytes);
        var stopped_early = false;
        const answer = server.readAnswer(arena, arena, &reader, is_sse, 1, &stopped_early) catch continue;
        if (answer == .object) _ = try resultText(arena, "fuzz", answer);
    }
}
