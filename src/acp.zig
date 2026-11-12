//! Agent Client Protocol (ACP) v1: the JSON-RPC frames a client sends an
//! agent, the content blocks a prompt carries, and the updates an agent sends
//! back while it works.
//!
//! This module is the protocol boundary only. The agent loop that answers a
//! prompt lives in `main.zig`, where the model, the tools and the MCP servers
//! already are; keeping the wire shapes here lets the protocol be tested
//! without a provider or a child process.

const std = @import("std");
const mcp = @import("mcp.zig");
const chat = @import("chat.zig");

/// The only ACP major version this agent speaks. The field is an integer, not
/// a date: ACP increments it only for breaking changes.
pub const protocol_version: i64 = 1;

/// The implementation name and version reported by `initialize`.
pub const agent_name = "microagent";

pub const ErrorCode = struct {
    pub const parse_error: i32 = -32700;
    pub const invalid_request: i32 = -32600;
    pub const method_not_found: i32 = -32601;
    pub const invalid_params: i32 = -32602;
    pub const internal_error: i32 = -32603;
    pub const request_cancelled: i32 = -32800;
    pub const auth_required: i32 = -32000;
    pub const resource_not_found: i32 = -32002;
};

/// The JSON-RPC envelope of one client frame. `id` is null for a
/// notification; an explicit JSON `null` id is kept as a value because it is
/// still a request that expects a response.
pub const Request = struct {
    id: ?std.json.Value,
    method: []const u8,
    params: ?std.json.Value,

    pub fn isNotification(self: Request) bool {
        return self.id == null;
    }
};

pub fn stringField(value: std.json.Value, key: []const u8) ![]const u8 {
    if (value != .object) return error.InvalidParams;
    const field = value.object.get(key) orelse return error.InvalidParams;
    if (field != .string or std.mem.indexOfScalar(u8, field.string, 0) != null) return error.InvalidParams;
    return field.string;
}

fn optionalStringField(value: std.json.Value, key: []const u8) !?[]const u8 {
    if (value != .object) return error.InvalidParams;
    const field = value.object.get(key) orelse return null;
    if (field == .null) return null;
    if (field != .string or std.mem.indexOfScalar(u8, field.string, 0) != null) return error.InvalidParams;
    return field.string;
}

fn absolutePath(path: []const u8) bool {
    return path.len != 0 and std.fs.path.isAbsolute(path) and std.mem.indexOfScalar(u8, path, 0) == null;
}

/// One MCP server from `session/new`, `session/load` or `session/resume`.
/// Transport is kept so a client's `http` or `sse` entry is refused by a
/// build that advertises neither rather than silently treated as stdio.
pub const Transport = enum { stdio, http, sse };

pub const McpServer = struct {
    entry: mcp.Entry,
    transport: Transport,
};

pub const NewSession = struct {
    cwd: []const u8,
    servers: []mcp.Entry,
    transports: []const Transport = &.{},
    additional_directories: []const []const u8 = &.{},
    /// The original entries, for a caller that needs to reject a transport
    /// this build does not speak.
    mcp_servers: []const McpServer = &.{},
};

fn parseMcpServer(allocator: std.mem.Allocator, item: std.json.Value) !McpServer {
    if (item != .object) return error.InvalidParams;
    const name = try stringField(item, "name");
    if (name.len == 0) return error.InvalidParams;
    const kind = try optionalStringField(item, "type");
    const transport: Transport = if (kind) |k| blk: {
        if (std.mem.eql(u8, k, "stdio")) break :blk .stdio;
        if (std.mem.eql(u8, k, "http")) break :blk .http;
        if (std.mem.eql(u8, k, "sse")) break :blk .sse;
        return error.InvalidParams;
    } else .stdio;

    switch (transport) {
        .stdio => {
            const command = try stringField(item, "command");
            if (command.len == 0) return error.InvalidParams;
            const args_value = item.object.get("args") orelse return error.InvalidParams;
            if (args_value != .array) return error.InvalidParams;
            const args = try allocator.alloc([]const u8, args_value.array.items.len);
            for (args_value.array.items, args) |arg, *out| {
                if (arg != .string or std.mem.indexOfScalar(u8, arg.string, 0) != null) return error.InvalidParams;
                out.* = arg.string;
            }
            var env_list: std.ArrayList([2][]const u8) = .empty;
            if (item.object.get("env")) |env_value| {
                if (env_value != .array) return error.InvalidParams;
                for (env_value.array.items) |pair| {
                    const key = try stringField(pair, "name");
                    const value = try stringField(pair, "value");
                    if (key.len == 0 or std.mem.indexOfScalar(u8, key, '=') != null) return error.InvalidParams;
                    try env_list.append(allocator, .{ key, value });
                }
            }
            return .{
                .entry = .{ .name = name, .command = command, .args = args, .env = try env_list.toOwnedSlice(allocator) },
                .transport = .stdio,
            };
        },
        .http, .sse => {
            const url = try stringField(item, "url");
            if (url.len == 0) return error.InvalidParams;
            var headers: std.ArrayList([2][]const u8) = .empty;
            if (item.object.get("headers")) |header_value| {
                if (header_value != .array) return error.InvalidParams;
                for (header_value.array.items) |pair| {
                    const key = try stringField(pair, "name");
                    const value = try stringField(pair, "value");
                    if (key.len == 0 or std.mem.indexOfScalar(u8, key, ':') != null or
                        std.mem.indexOfAny(u8, key, "\r\n\x00") != null or
                        std.mem.indexOfAny(u8, value, "\r\n\x00") != null)
                        return error.InvalidParams;
                    try headers.append(allocator, .{ key, value });
                }
            }
            // The existing MCP client carries one credential header. Keep the
            // first Authorization-like header there and the whole list for the
            // transport once it can send more than one.
            var key_name: []const u8 = "";
            var key_value: []const u8 = "";
            // A bearer token can use the MCP client's one-key path. Any other
            // Authorization scheme is sent verbatim from the header list,
            // because that path would prepend "Bearer " to it.
            var direct_authorization = false;
            for (headers.items) |header| {
                if (!std.ascii.eqlIgnoreCase(header[0], "authorization")) continue;
                if (std.ascii.startsWithIgnoreCase(header[1], "Bearer ")) {
                    key_name = header[0];
                    key_value = header[1]["Bearer ".len..];
                } else {
                    direct_authorization = true;
                }
                break;
            }
            if (key_name.len == 0 and !direct_authorization) {
                for (headers.items) |header| {
                    if (std.ascii.eqlIgnoreCase(header[0], "content-type") or std.ascii.eqlIgnoreCase(header[0], "accept")) continue;
                    key_name = header[0];
                    key_value = header[1];
                    break;
                }
            }
            return .{
                .entry = .{
                    .name = name,
                    .url = url,
                    .api_key_header = if (key_name.len == 0) mcp.default_key_header else key_name,
                    .api_key = key_value,
                    .headers = try headers.toOwnedSlice(allocator),
                },
                .transport = transport,
            };
        },
    }
}

/// Parses the params of `session/new`. `mcpServers` is required by the ACP
/// schema but an omitted list is read as the empty list: a client that has no
/// servers to offer should not have to send a field it does not use, and the
/// agent connects none either way.
pub fn parseNewSession(allocator: std.mem.Allocator, params: std.json.Value) !NewSession {
    if (params != .object) return error.InvalidParams;
    const cwd = try stringField(params, "cwd");
    if (!absolutePath(cwd)) return error.InvalidParams;

    var servers: std.ArrayList(mcp.Entry) = .empty;
    var full: std.ArrayList(McpServer) = .empty;
    const list = params.object.get("mcpServers") orelse return error.InvalidParams;
    if (list != .array) return error.InvalidParams;
    for (list.array.items) |item| {
        const server = try parseMcpServer(allocator, item);
        try servers.append(allocator, server.entry);
        try full.append(allocator, server);
    }

    var dirs: std.ArrayList([]const u8) = .empty;
    if (params.object.get("additionalDirectories")) |dirs_value| {
        if (dirs_value != .array) return error.InvalidParams;
        for (dirs_value.array.items) |item| {
            if (item != .string or !absolutePath(item.string)) return error.InvalidParams;
            try dirs.append(allocator, item.string);
        }
    }

    const transports = try allocator.alloc(Transport, full.items.len);
    for (full.items, transports) |server, *out| out.* = server.transport;

    return .{
        .cwd = cwd,
        .servers = try servers.toOwnedSlice(allocator),
        .transports = transports,
        .additional_directories = try dirs.toOwnedSlice(allocator),
        .mcp_servers = try full.toOwnedSlice(allocator),
    };
}

/// One prompt, flattened to the text this agent's OpenAI-shaped model receives.
/// ACP requires text and resource_link; embedded text resources are supported
/// too, and image/audio blocks are refused because this agent advertises
/// neither capability.
pub const Prompt = struct {
    text: []const u8,
};

pub fn parsePrompt(allocator: std.mem.Allocator, params: std.json.Value) !Prompt {
    if (params != .object) return error.InvalidParams;
    _ = try stringField(params, "sessionId");
    const blocks = params.object.get("prompt") orelse return error.InvalidParams;
    if (blocks != .array) return error.InvalidParams;
    var out: std.ArrayList(u8) = .empty;
    for (blocks.array.items) |block| {
        if (block != .object) return error.InvalidParams;
        const kind = try stringField(block, "type");
        if (std.mem.eql(u8, kind, "text")) {
            const text = try stringField(block, "text");
            try out.appendSlice(allocator, text);
            continue;
        }
        if (std.mem.eql(u8, kind, "resource_link")) {
            const uri = try stringField(block, "uri");
            const name = try optionalStringField(block, "name") orelse uri;
            // A local file link reaches the model as the path its tools can
            // open, not only as a URI it would have to translate itself.
            const shown = if (std.mem.startsWith(u8, uri, "file:///")) uri["file://".len..] else uri;
            try out.appendSlice(allocator, "\n[resource: ");
            try out.appendSlice(allocator, name);
            try out.appendSlice(allocator, " (");
            try out.appendSlice(allocator, shown);
            if (!std.mem.eql(u8, shown, uri)) {
                try out.appendSlice(allocator, " from ");
                try out.appendSlice(allocator, uri);
            }
            try out.appendSlice(allocator, ")]\n");
            continue;
        }
        if (std.mem.eql(u8, kind, "resource")) {
            const resource = block.object.get("resource") orelse return error.InvalidParams;
            if (resource != .object) return error.InvalidParams;
            const uri = try stringField(resource, "uri");
            if (resource.object.get("text")) |text_value| {
                if (text_value != .string) return error.InvalidParams;
                try out.appendSlice(allocator, "\n[resource: ");
                try out.appendSlice(allocator, uri);
                try out.appendSlice(allocator, "]\n");
                try out.appendSlice(allocator, text_value.string);
                try out.appendSlice(allocator, "\n");
                continue;
            }
            // A blob is not text this model can read. Keep the fact that the
            // client attached it, with its URI and size, rather than spending
            // the context on base64 bytes the model cannot use.
            const blob = resource.object.get("blob") orelse return error.InvalidParams;
            if (blob != .string) return error.InvalidParams;
            try out.appendSlice(allocator, "\n[resource: ");
            try out.appendSlice(allocator, uri);
            try out.appendSlice(allocator, " (binary resource attached; base64 bytes omitted)]\n");
            continue;
        }
        return error.InvalidParams;
    }
    return .{ .text = try out.toOwnedSlice(allocator) };
}

/// The stop reasons ACP defines.
pub const StopReason = enum {
    end_turn,
    max_tokens,
    max_turn_requests,
    refusal,
    cancelled,

    pub fn wire(self: StopReason) []const u8 {
        return @tagName(self);
    }
};

/// The session capabilities this agent advertises. `load` is false because a
/// conversation lives in memory for the connection; `close` is true and
/// idempotent, as the specification asks.
pub const session_capabilities_json =
    \\{"close":{},"delete":{},"list":{},"resume":{}}
;

/// The operating modes this agent answers to. `auto` is the default Paseo and
/// other clients send when they have no preference; it is the same behavior as
/// `code`, which is kept as an explicit name. Neither is a permission mode:
/// the agent always runs the tools the operator enabled, and the ACP client
/// does not gate them.
pub const mode_ids_json =
    \\[{"id":"auto","name":"Auto","description":"Read, edit and run commands with the configured tools"},{"id":"code","name":"Code","description":"Read, edit and run commands with the configured tools"}]
;

/// `mode` is the session's current mode. Both `auto` and `code` are accepted;
/// anything else is reported as `auto`, which is what a new session starts in.
pub fn modesJson(allocator: std.mem.Allocator, mode: []const u8) ![]u8 {
    const current = if (std.mem.eql(u8, mode, "code")) "code" else "auto";
    return std.fmt.allocPrint(allocator, "{{\"currentModeId\":\"{s}\",\"availableModes\":{s}}}", .{ current, mode_ids_json });
}

/// The `configOptions` a session advertises. The model option is what makes an
/// ACP client's model selector show the model this session will actually call;
/// without it a client that only reads `configOptions` reports no models.
/// `models` is every id the session may switch to, empty for `model` alone.
/// `mode` is that session's current mode, so a client that set it and then
/// reads `configOptions` sees the value it set rather than the default.
pub fn configOptionsJson(allocator: std.mem.Allocator, model: []const u8, models: []const []const u8, mode: []const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    const w = &aw.writer;
    const current = if (std.mem.eql(u8, mode, "code")) "code" else "auto";
    // `auto` and `code` are the modes `session/set_mode` accepts. Omitting
    // either leaves a client that reads only `configOptions` disagreeing
    // with the session's own mode.
    try w.writeAll("[{\"id\":\"mode\",\"name\":\"Session Mode\",\"description\":\"Controls whether the agent may edit and run tools\",\"category\":\"mode\",\"type\":\"select\",\"currentValue\":\"");
    try w.writeAll(current);
    try w.writeAll("\",\"options\":[{\"value\":\"auto\",\"name\":\"Auto\",\"description\":\"Read, edit and run commands with the configured tools\"},{\"value\":\"code\",\"name\":\"Code\",\"description\":\"Read, edit and run commands with the configured tools\"}]},{\"id\":\"model\",\"name\":\"Model\",\"description\":\"The model this session sends to the provider\",\"category\":\"model\",\"type\":\"select\",\"currentValue\":");
    try chat.writeJsonString(w, model);
    try w.writeAll(",\"options\":[");
    const ids: []const []const u8 = if (models.len == 0) &.{model} else models;
    for (ids, 0..) |id, i| {
        if (i != 0) try w.writeAll(",");
        try w.writeAll("{\"value\":");
        try chat.writeJsonString(w, id);
        try w.writeAll(",\"name\":");
        try chat.writeJsonString(w, id);
        try w.writeAll(",\"description\":\"A model named by the operator configuration\"}");
    }
    try w.writeAll("]}]");
    return aw.toOwnedSlice();
}

pub fn configOptionsResultJson(allocator: std.mem.Allocator, model: []const u8, models: []const []const u8, mode: []const u8) ![]u8 {
    const options = try configOptionsJson(allocator, model, models, mode);
    return std.fmt.allocPrint(allocator, "{{\"configOptions\":{s}}}", .{options});
}

pub fn sessionStateJson(allocator: std.mem.Allocator, model: []const u8, models: []const []const u8, mode: []const u8) ![]u8 {
    const modes = try modesJson(allocator, mode);
    const options = try configOptionsJson(allocator, model, models, mode);
    return std.fmt.allocPrint(allocator, "{{\"modes\":{s},\"configOptions\":{s}}}", .{ modes, options });
}

/// The prompt capabilities: text, resource_link and embedded text resources.
pub const prompt_capabilities_json =
    \\{"image":false,"audio":false,"embeddedContext":true}
;

/// A sink the agent loop writes through when it is serving ACP instead of a
/// terminal. The methods append complete JSON-RPC notifications or return
/// silently; a client that has gone away cannot make the agent loop fail a
/// tool or a turn.
pub const Sink = struct {
    ctx: *anyopaque,
    /// Visible model text, streamed as it arrives.
    content: *const fn (ctx: *anyopaque, bytes: []const u8) void,
    /// One tool call's lifecycle. `status` is ACP's pending/in_progress/
    /// completed/failed; `output` is the tool result for a terminal status.
    tool_call: *const fn (ctx: *anyopaque, id: []const u8, name: []const u8, args: []const u8, status: []const u8, output: []const u8) void,
    /// Whether the client has cancelled the active prompt.
    cancelled: *const fn (ctx: *anyopaque) bool,

    pub fn emitContent(self: Sink, bytes: []const u8) void {
        if (bytes.len == 0) return;
        self.content(self.ctx, bytes);
    }

    pub fn emitTool(self: Sink, id: []const u8, name: []const u8, args: []const u8, status: []const u8, output: []const u8) void {
        self.tool_call(self.ctx, id, name, args, status, output);
    }

    pub fn isCancelled(self: Sink) bool {
        return self.cancelled(self.ctx);
    }
};

/// Writes a JSON-RPC result line. `result_json` is a complete JSON value.
pub fn writeResult(w: *std.Io.Writer, id: std.json.Value, result_json: []const u8) !void {
    try w.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try writeId(w, id);
    try w.writeAll(",\"result\":");
    try w.writeAll(result_json);
    try w.writeAll("}\n");
}

/// Writes a JSON-RPC error line.
pub fn writeErrorResponse(w: *std.Io.Writer, id: ?std.json.Value, code: i32, message: []const u8) !void {
    try writeErrorDataResponse(w, id, code, message, null);
}

/// Writes a JSON-RPC error line with ACP's optional `data` object. Unknown
/// sessions carry `data.sessionId`; every other error carries none.
pub fn writeErrorDataResponse(w: *std.Io.Writer, id: ?std.json.Value, code: i32, message: []const u8, data_json: ?[]const u8) !void {
    try w.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    if (id) |value| try writeId(w, value) else try w.writeAll("null");
    try w.print(",\"error\":{{\"code\":{d},\"message\":", .{code});
    try chat.writeJsonString(w, message);
    if (data_json) |data| {
        try w.writeAll(",\"data\":");
        try w.writeAll(data);
    }
    try w.writeAll("}}\n");
}

/// Writes an ACP notification line. `session_id` and `update_json` are the
/// `params` fields; `update_json` is a complete JSON object.
pub fn writeNotification(w: *std.Io.Writer, method: []const u8, params_json: []const u8) !void {
    try w.writeAll("{\"jsonrpc\":\"2.0\",\"method\":");
    try chat.writeJsonString(w, method);
    try w.writeAll(",\"params\":");
    try w.writeAll(params_json);
    try w.writeAll("}\n");
}

fn writeId(w: *std.Io.Writer, id: std.json.Value) !void {
    switch (id) {
        .string => |s| try chat.writeJsonString(w, s),
        .integer => |n| try w.print("{d}", .{n}),
        .null => try w.writeAll("null"),
        // The parser only admits these three, but a caller building an id by
        // hand gets the same fallback rather than invalid JSON.
        else => try w.writeAll("null"),
    }
}

/// Builds the `session/update` params for a message chunk. `kind` is
/// `agent_message_chunk`, `agent_thought_chunk` or `user_message_chunk`.
pub fn messageUpdateJson(allocator: std.mem.Allocator, session_id: []const u8, kind: []const u8, text: []const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    const w = &aw.writer;
    try w.writeAll("{\"sessionId\":");
    try chat.writeJsonString(w, session_id);
    try w.writeAll(",\"update\":{\"sessionUpdate\":");
    try chat.writeJsonString(w, kind);
    try w.writeAll(",\"content\":{\"type\":\"text\",\"text\":");
    try chat.writeJsonString(w, text);
    try w.writeAll("}}}");
    return aw.toOwnedSlice();
}

/// Builds the `session/update` params for a tool call or update.
pub fn toolUpdateJson(
    allocator: std.mem.Allocator,
    session_id: []const u8,
    id: []const u8,
    name: []const u8,
    args_json: []const u8,
    status: []const u8,
    output: []const u8,
) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    const w = &aw.writer;
    try w.writeAll("{\"sessionId\":");
    try chat.writeJsonString(w, session_id);
    const initial = std.mem.eql(u8, status, "pending");
    try w.writeAll(",\"update\":{\"sessionUpdate\":");
    try w.writeAll(if (initial) "\"tool_call\"" else "\"tool_call_update\"");
    try w.writeAll(",\"toolCallId\":");
    try chat.writeJsonString(w, id);
    if (initial) {
        try w.writeAll(",\"title\":");
        try chat.writeJsonString(w, name);
        try w.writeAll(",\"name\":");
        try chat.writeJsonString(w, name);
        try w.writeAll(",\"kind\":");
        try chat.writeJsonString(w, toolKind(name));
    }
    try w.writeAll(",\"status\":");
    try chat.writeJsonString(w, status);
    if (args_json.len != 0 and (std.json.validate(allocator, args_json) catch false)) {
        try w.writeAll(",\"rawInput\":");
        try w.writeAll(args_json);
    }
    if (output.len != 0) {
        try w.writeAll(",\"content\":[{\"type\":\"content\",\"content\":{\"type\":\"text\",\"text\":");
        try chat.writeJsonString(w, output);
        try w.writeAll("}}]");
    }
    try w.writeAll("}}");
    return aw.toOwnedSlice();
}

fn toolKind(name: []const u8) []const u8 {
    if (std.mem.eql(u8, name, "bash")) return "execute";
    if (std.mem.eql(u8, name, "read")) return "read";
    if (std.mem.eql(u8, name, "write") or std.mem.eql(u8, name, "edit") or std.mem.eql(u8, name, "multi_edit")) return "edit";
    if (std.mem.eql(u8, name, "search") or std.mem.eql(u8, name, "ast") or std.mem.eql(u8, name, "git")) return "search";
    return "other";
}

/// Builds the `initialize` result. Protocol version negotiation is the
/// client's version when this agent supports it, and this agent only supports
/// version 1, so the answer is 1 either way.
pub fn initializeResultJson(allocator: std.mem.Allocator, version: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\{{"protocolVersion":{d},"agentCapabilities":{{"loadSession":false,"promptCapabilities":{s},"mcpCapabilities":{{"http":true,"sse":false}},"sessionCapabilities":{s}}},"agentInfo":{{"name":"{s}","title":"microagent","version":"{s}"}},"authMethods":[]}}
    , .{ protocol_version, prompt_capabilities_json, session_capabilities_json, agent_name, version });
}

test "JSON-RPC requests preserve IDs and reject invalid envelopes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const request = try parseRequest(a, "{\"jsonrpc\":\"2.0\",\"id\":\"abc\",\"method\":\"initialize\",\"params\":{}}");
    try std.testing.expectEqualStrings("abc", request.id.?.string);
    try std.testing.expectEqualStrings("initialize", request.method);
    const notification = try parseRequest(a, "{\"jsonrpc\":\"2.0\",\"method\":\"session/cancel\"}");
    try std.testing.expect(notification.id == null);
    try std.testing.expectError(error.InvalidRequest, parseRequest(a, "{\"jsonrpc\":\"1.0\",\"method\":\"x\"}"));
    try std.testing.expectError(error.InvalidRequest, parseRequest(a, "{\"jsonrpc\":\"2.0\",\"id\":true,\"method\":\"x\"}"));
    try std.testing.expectError(error.InvalidRequest, parseRequest(a, "{\"jsonrpc\":\"2.0\",\"method\":\"x\",\"params\":false}"));
}

// A client frame is the one input on this connection that arrives from a
// process this run did not start, and `parseRequest` is the first thing that
// reads it. The corpus covers the envelopes a client actually sends and the
// ones a truncated or wrong one spells: a request, a notification, a null id,
// an array of params, a version that is not 2.0, a method carrying a NUL, an
// id or a params member of a type the envelope does not allow, a frame that is
// not an object, and one that stops mid-token. `std.testing.fuzz` runs this
// corpus on every `zig build test`, and through the fuzzer's mutations when
// the test binary is built in fuzz mode.
const request_corpus = [_][]const u8{
    "",
    "{",
    "[]",
    "null",
    "\"initialize\"",
    "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}",
    "{\"jsonrpc\":\"2.0\",\"id\":\"abc\",\"method\":\"session/prompt\",\"params\":{\"sessionId\":\"s\",\"prompt\":[]}}",
    "{\"jsonrpc\":\"2.0\",\"method\":\"session/cancel\",\"params\":{\"sessionId\":\"s\"}}",
    "{\"jsonrpc\":\"2.0\",\"id\":null,\"method\":\"session/new\",\"params\":null}",
    "{\"jsonrpc\":\"2.0\",\"id\":0,\"method\":\"x\",\"params\":[]}",
    "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"x\"}",
    "{\"jsonrpc\":\"2.0\",\"id\":true,\"method\":\"x\"}",
    "{\"jsonrpc\":\"2.0\",\"method\":\"x\",\"params\":false}",
    "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"has\\u0000nul\"}",
    "{\"jsonrpc\":\"2.0\",\"id\":1}",
    "{\"method\":\"x\"}",
    "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"x\",\"params\":{\"a\":[1,{\"b\":[]}]}}",
    "{\"jsonrpc\":\"2.0\",\"id\":-7,\"method\":\"session/set_mode\",\"params\":{\"modeId\":\"code\"}}",
    "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"x\"}{\"jsonrpc\":\"2.0\"}",
};

test "a fuzzed client frame is a request only when its envelope says so" {
    try std.testing.fuzz({}, fuzzRequest, .{ .corpus = &request_corpus });
}

fn fuzzRequest(_: void, smith: *std.testing.Smith) !void {
    var scratch: [4 * 1024]u8 = undefined;
    const frame: []const u8 = if (smith.in) |seed| seed else scratch[0..smith.slice(&scratch)];

    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const arena = state.allocator();

    const parsed = parseRequest(arena, frame) catch |err| switch (err) {
        // Both are a frame this run declines to answer, and a crash is what
        // the fuzzer is here to see: an out-of-memory is the arena failing,
        // which is not a property of the frame.
        error.InvalidRequest, error.SyntaxError, error.UnexpectedEndOfInput, error.FrameTooDeep => return,
        else => return err,
    };

    // A frame the parser accepts is one object whose version, method, id and
    // params are exactly the members it read, so a second reading of the same
    // bytes has to name the same request. The two readings share no scanner:
    // `parseRequest` walks the document once for depth and once to build the
    // value, and this walks the object the second build returned.
    const again = try std.json.parseFromSliceLeaky(std.json.Value, arena, frame, .{});
    const object = switch (again) {
        .object => |o| o,
        else => return error.TestUnexpectedResult,
    };
    const version = object.get("jsonrpc") orelse return error.TestUnexpectedResult;
    try std.testing.expect(version == .string and std.mem.eql(u8, version.string, "2.0"));
    const method = object.get("method") orelse return error.TestUnexpectedResult;
    try std.testing.expect(method == .string and std.mem.indexOfScalar(u8, method.string, 0) == null);
    try std.testing.expectEqualStrings(method.string, parsed.method);
    if (object.get("id")) |id| switch (id) {
        .string, .integer, .null => try std.testing.expect(parsed.id != null),
        else => return error.TestUnexpectedResult,
    } else try std.testing.expect(parsed.id == null);
    if (object.get("params")) |params| switch (params) {
        .object, .array, .null => try std.testing.expect(parsed.params != null),
        else => return error.TestUnexpectedResult,
    } else try std.testing.expect(parsed.params == null);

    // The same bytes read twice name the same request: the parser holds no
    // state across calls, and a frame it accepted once is one it accepts again.
    const twice = try parseRequest(arena, frame);
    try std.testing.expectEqualStrings(parsed.method, twice.method);
    try std.testing.expectEqual(parsed.id == null, twice.id == null);
    try std.testing.expectEqual(parsed.params == null, twice.params == null);
}

test "ACP session accepts stdio MCP servers and rejects invalid input" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const good = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"cwd":"/tmp","mcpServers":[{"name":"tools","command":"/bin/server","args":["--stdio"],"env":[{"name":"KEY","value":"secret"}]}]}
    , .{});
    const session = try parseNewSession(a, good);
    try std.testing.expectEqualStrings("/tmp", session.cwd);
    try std.testing.expectEqualStrings("--stdio", session.servers[0].args[0]);
    try std.testing.expectEqualStrings("secret", session.servers[0].env[0][1]);
    const bad = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"cwd":"relative","mcpServers":[]}
    , .{});
    try std.testing.expectError(error.InvalidParams, parseNewSession(a, bad));
}

test "ACP session accepts http MCP servers and optional directories" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const value = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"cwd":"/workspace","additionalDirectories":["/tmp/shared"],"mcpServers":[{"type":"http","name":"remote","url":"https://example.test/mcp","headers":[{"name":"Authorization","value":"Bearer token"}]}]}
    , .{});
    const session = try parseNewSession(a, value);
    try std.testing.expectEqual(@as(usize, 1), session.additional_directories.len);
    try std.testing.expectEqualStrings("/tmp/shared", session.additional_directories[0]);
    try std.testing.expectEqualStrings("https://example.test/mcp", session.servers[0].url);
    try std.testing.expectEqualStrings("token", session.servers[0].api_key);
    try std.testing.expectEqualStrings("Authorization", session.servers[0].api_key_header);
    try std.testing.expectEqual(session.transports[0], .http);
}

test "ACP prompts flatten text and resources, and refuse media this agent cannot use" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const value = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"sessionId":"s","prompt":[{"type":"text","text":"hello"},{"type":"resource_link","uri":"file:///tmp/a","name":"a"},{"type":"resource","resource":{"uri":"file:///tmp/b","text":"body"}}]}
    , .{});
    const prompt = try parsePrompt(a, value);
    try std.testing.expect(std.mem.indexOf(u8, prompt.text, "hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt.text, "file:///tmp/a") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt.text, "body") != null);
    const image = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"sessionId":"s","prompt":[{"type":"image","mimeType":"image/png","data":"AA=="}]}
    , .{});
    try std.testing.expectError(error.InvalidParams, parsePrompt(a, image));
}

test "ACP results and errors keep the request id" {
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const id = std.json.Value{ .integer = 7 };
    try writeResult(&w, id, "{\"sessionId\":\"s\"}");
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{\"sessionId\":\"s\"}}\n", w.buffered());
    var ebuf: [256]u8 = undefined;
    var ew: std.Io.Writer = .fixed(&ebuf);
    try writeErrorResponse(&ew, std.json.Value{ .string = "x" }, ErrorCode.invalid_params, "bad");
    try std.testing.expect(std.mem.indexOf(u8, ew.buffered(), "\"id\":\"x\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ew.buffered(), "-32602") != null);
}

test "ACP initialize advertises version, capabilities and the binary's own version" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const bytes = try initializeResultJson(arena.allocator(), "9.9.9");
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"protocolVersion\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"loadSession\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"version\":\"9.9.9\"") != null);
}

test "ACP config options name the same modes the session advertises" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const bytes = try configOptionsJson(arena.allocator(), "model-x", &.{}, "auto");
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"currentValue\":\"auto\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"value\":\"auto\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"value\":\"code\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"currentValue\":\"model-x\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"value\":\"model-x\"") != null);
    const code = try configOptionsJson(arena.allocator(), "model-x", &.{}, "code");
    try std.testing.expect(std.mem.indexOf(u8, code, "\"currentValue\":\"code\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "\"currentValue\":\"auto\"") == null);
    const state = try sessionStateJson(arena.allocator(), "model-x", &.{}, "code");
    try std.testing.expect(std.mem.indexOf(u8, state, "\"currentModeId\":\"code\"") != null);
    const fallback = try modesJson(arena.allocator(), "other");
    try std.testing.expect(std.mem.indexOf(u8, fallback, "\"currentModeId\":\"auto\"") != null);
}

test "ACP model option lists every configured model with the current one selected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const bytes = try configOptionsJson(arena.allocator(), "b", &.{ "a", "b", "c" }, "auto");
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), bytes, .{});
    const model = parsed.array.items[1].object;
    try std.testing.expectEqualStrings("model", model.get("id").?.string);
    try std.testing.expectEqualStrings("b", model.get("currentValue").?.string);
    const options = model.get("options").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), options.len);
    for (options, [_][]const u8{ "a", "b", "c" }) |option, want| {
        try std.testing.expectEqualStrings(want, option.object.get("value").?.string);
        try std.testing.expectEqualStrings(want, option.object.get("name").?.string);
    }
}

pub fn parseRequest(allocator: std.mem.Allocator, frame: []const u8) !Request {
    var scanner = std.json.Scanner.initCompleteInput(allocator, frame);
    defer scanner.deinit();
    while (try scanner.next() != .end_of_document) {
        if (scanner.stackHeight() > 256) return error.FrameTooDeep;
    }
    const value = try std.json.parseFromSliceLeaky(std.json.Value, allocator, frame, .{});
    if (value != .object) return error.InvalidRequest;
    const object = value.object;
    const version = object.get("jsonrpc") orelse return error.InvalidRequest;
    if (version != .string or !std.mem.eql(u8, version.string, "2.0")) return error.InvalidRequest;
    const method = object.get("method") orelse return error.InvalidRequest;
    if (method != .string or std.mem.indexOfScalar(u8, method.string, 0) != null) return error.InvalidRequest;
    const id = object.get("id");
    if (id) |v| switch (v) {
        .string, .integer, .null => {},
        else => return error.InvalidRequest,
    };
    const params = object.get("params");
    if (params) |v| switch (v) {
        .object, .array, .null => {},
        else => return error.InvalidRequest,
    };
    return .{ .id = id, .method = method.string, .params = params };
}
