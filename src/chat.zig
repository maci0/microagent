//! The value types one turn of a conversation is made of, and the JSON writer
//! every request body and usage line goes through.
//!
//! A leaf module, like `net`: it imports nothing from the agent loop, the tools
//! or `update`, so all three can speak the same turn without importing each
//! other.

const std = @import("std");
const Io = std.Io;

/// `args` grows in place as the provider streams the arguments in fragments.
/// It is a buffer, not a string that is re-spelled per fragment: a large
/// `write` arrives as thousands of deltas, and copying what has accumulated so
/// far on every one of them is quadratic in the size of the call.
pub const ToolCall = struct {
    id: []u8,
    name: []u8,
    /// Grown by appending each streamed fragment. A provider splits one
    /// call's `arguments` across many frames, so this is the buffer that a
    /// per-frame re-copy made quadratic in the argument length.
    args: std.ArrayList(u8) = .empty,
};

/// Token counters as gauntlet wants to read them: cumulative for the run, so
/// the max it takes from successive usage lines is the final total.
pub const Usage = struct {
    prompt: u64 = 0,
    completion: u64 = 0,
    reasoning: u64 = 0,
    total: u64 = 0,
    /// Of `prompt`, the part the provider served from its prompt cache. Every
    /// turn re-sends the whole conversation, so this is the counter that says
    /// whether the prefix is still being reused: a prompt-sized `prompt_tokens`
    /// with `cached_tokens` near it is a hit, and near-zero is a full re-read.
    cached: u64 = 0,

    /// Adds one response's counters. Saturating, because a provider number
    /// beyond u64 saturates on the way in (`num`) and a second one in the same
    /// run would otherwise overflow the run total and trap a checked build.
    pub fn add(self: *Usage, result: *const ChatResult) void {
        self.prompt +|= result.prompt_tokens;
        self.cached +|= result.cached_tokens;
        self.completion +|= result.completion_tokens;
        self.reasoning +|= result.reasoning_tokens;
        self.total +|= result.total_tokens;
    }
};

/// The five counters, in the order every JSON usage writer here emits them: a
/// reader takes them by name, so one place spells the key list.
pub const usage_fields = "\"prompt_tokens\":{d},\"cached_tokens\":{d},\"completion_tokens\":{d},\"reasoning_tokens\":{d},\"total_tokens\":{d}";

pub const ChatResult = struct {
    content: std.ArrayList(u8) = .empty,
    calls: std.ArrayList(ToolCall) = .empty,
    prompt_tokens: u64 = 0,
    completion_tokens: u64 = 0,
    reasoning_tokens: u64 = 0,
    total_tokens: u64 = 0,
    cached_tokens: u64 = 0,
    /// Why the provider stopped generating, as the last frame spells it, or the
    /// empty slice when the stream carried none. `length` is the one that
    /// matters: it means the response was cut at `max_tokens`, so the turn is a
    /// prefix of what the model meant to say.
    finish_reason: []u8 = &.{},
    /// Bytes this one response has added to the run: the visible text and every
    /// call's arguments together. `max_response_bytes` bounds a response, not
    /// each stream in it, and the streams are not one: a provider that streams
    /// the full allowance of arguments for each of `max_tool_calls` calls holds
    /// a gigabyte of a single turn in memory, which is a ceiling the run
    /// documented and did not have.
    streamed: usize = 0,

    pub fn deinitFinish(self: *ChatResult, gpa: std.mem.Allocator) void {
        if (!std.mem.eql(u8, self.finish_reason, &.{})) gpa.free(self.finish_reason);
        self.finish_reason = &.{};
    }

    /// The response outlives the turn's arena, so what a turn keeps is
    /// allocated here and released with the turn rather than at process exit.
    /// The name and the id of a call are as much of the response as its
    /// arguments are, so they go with them.
    pub fn deinit(self: *ChatResult, gpa: std.mem.Allocator) void {
        deinitCalls(gpa, &self.calls);
        self.content.deinit(gpa);
        self.deinitFinish(gpa);
    }
};

/// Releases the strings and the argument buffers a list of calls owns. A slot
/// the frame parser filled to reach a later index holds nothing to release.
pub fn deinitCalls(gpa: std.mem.Allocator, calls: *std.ArrayList(ToolCall)) void {
    for (calls.items) |*call| {
        if (call.id.len != 0) gpa.free(call.id);
        if (call.name.len != 0) gpa.free(call.name);
        call.args.deinit(gpa);
    }
    calls.deinit(gpa);
}

/// A byte buffer that hands out an `Io.Writer` (the std ArrayList lost its
/// `writer` method in 0.16, so the adapter lives here once).
pub const JsonBuf = struct {
    list: std.ArrayList(u8) = .empty,
    allocating: Io.Writer.Allocating,

    pub fn init(allocator: std.mem.Allocator) JsonBuf {
        var list: std.ArrayList(u8) = .empty;
        return .{ .list = list, .allocating = Io.Writer.Allocating.fromArrayList(allocator, &list) };
    }

    pub fn writer(self: *JsonBuf) *Io.Writer {
        return &self.allocating.writer;
    }

    pub fn items(self: *JsonBuf) []u8 {
        self.list = self.allocating.toArrayList();
        return self.list.items;
    }
};

/// Writes `s` as a JSON string. Text reaching here came from outside the
/// process: a tool result, a file's bytes, a working directory, an argv entry.
/// Bytes above ASCII are copied when they form a UTF-8 sequence and become
/// U+FFFD when they do not, because a lone byte is not a JSON string and one
/// invalid sequence in a tool result fails the whole request with a 400.
pub fn writeJsonString(w: *Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    var i: usize = 0;
    var start: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (jsonNeedsEscape(c)) {
            try w.writeAll(s[start..i]);
            switch (c) {
                '"' => try w.writeAll("\\\""),
                '\\' => try w.writeAll("\\\\"),
                '\n' => try w.writeAll("\\n"),
                '\r' => try w.writeAll("\\r"),
                '\t' => try w.writeAll("\\t"),
                0x08 => try w.writeAll("\\b"),
                0x0c => try w.writeAll("\\f"),
                else => try w.print("\\u{x:0>4}", .{c}),
            }
            i += 1;
            start = i;
            continue;
        }
        const len: usize = if (c < 0x80) 1 else utf8SequenceLen(s, i);
        if (len == 0) {
            try w.writeAll(s[start..i]);
            try w.writeAll("\u{fffd}");
            i += 1;
            start = i;
            continue;
        }
        i += len;
    }
    try w.writeAll(s[start..i]);
    try w.writeByte('"');
}

fn jsonNeedsEscape(c: u8) bool {
    return c < 0x20 or c == '"' or c == '\\';
}

/// The length of the UTF-8 sequence starting at `i`, or 0 where the bytes are
/// not one: a bad lead byte, a truncated tail, or an overlong or surrogate
/// encoding all read as a replacement rather than being copied through.
pub fn utf8SequenceLen(s: []const u8, i: usize) usize {
    const want = std.unicode.utf8ByteSequenceLength(s[i]) catch return 0;
    const end = i + want;
    if (end > s.len) return 0;
    if (!std.unicode.utf8ValidateSlice(s[i..end])) return 0;
    return want;
}

pub fn str(v: ?std.json.Value) ?[]const u8 {
    const value = v orelse return null;
    return switch (value) {
        .string => |s| s,
        else => null,
    };
}

pub fn num(v: ?std.json.Value) u64 {
    const value = v orelse return 0;
    return switch (value) {
        .integer => |n| if (n > 0) @intCast(n) else 0,
        .float => |f| std.math.lossyCast(u64, f),
        .number_string => |s| std.fmt.parseInt(u64, s, 10) catch 0,
        else => 0,
    };
}

/// A count the model sent, as a `usize`. `num` saturates at the `u64` ceiling,
/// which a 32-bit build cannot hold, so the cast clamps instead of trapping:
/// a number too large to be a line count is a number that means "all of them".
pub fn numCount(v: ?std.json.Value) usize {
    return std.math.cast(usize, num(v)) orelse std.math.maxInt(usize);
}

/// The first `max` bytes, cut on a UTF-8 codepoint boundary. Both callers feed
/// text a model will read back, one of them inside a JSON request body, so a
/// cut in the middle of a codepoint would put invalid UTF-8 on the wire.
pub fn clamp(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    var end = max;
    while (end > 0 and s[end] & 0xc0 == 0x80) end -= 1;
    return s[0..end];
}

test "json string escaping" {
    var buf = JsonBuf.init(std.testing.allocator);
    try writeJsonString(buf.writer(), "a\"b\\c\nd\t\u{7}");
    defer buf.list.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("\"a\\\"b\\\\c\\nd\\t\\u0007\"", buf.items());
}

// Escaping copies unescaped runs in bulk, so every byte has to survive that
// path: a byte that is neither escaped nor copied comes back short. The
// range is the ASCII one, which is what the escaper is responsible for; bytes
// above it are passed through as written, and a lone one is not valid JSON.
test "every ASCII byte survives escaping" {
    var all: [128]u8 = undefined;
    for (&all, 0..) |*c, i| c.* = @intCast(i);

    var buf = JsonBuf.init(std.testing.allocator);
    defer buf.list.deinit(std.testing.allocator);
    try writeJsonString(buf.writer(), &all);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, buf.items(), .{});
    defer parsed.deinit();
    try std.testing.expectEqualSlices(u8, &all, parsed.value.string);
}

test "a string that is not UTF-8 still serializes as valid JSON" {
    const cases = [_][]const u8{
        "\xff", // lone lead byte
        "caf\xe9", // latin-1 e-acute
        "\xc3", // truncated two-byte sequence
        "\xe6\x97", // truncated three-byte sequence, the CJK prefix
        "\xed\xa0\x80", // UTF-8 encoding of a surrogate half
        "\xc0\x80", // overlong encoding
        "ok\xff\xe6\x97\xa5ok",
    };
    for (cases) |raw| {
        var buf = JsonBuf.init(std.testing.allocator);
        defer buf.list.deinit(std.testing.allocator);
        try writeJsonString(buf.writer(), raw);

        var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, buf.items(), .{});
        defer parsed.deinit();
        try std.testing.expect(std.unicode.utf8ValidateSlice(parsed.value.string));
        // The valid text either side of a bad byte survives unchanged.
        if (std.mem.indexOf(u8, raw, "ok") != null)
            try std.testing.expect(std.mem.startsWith(u8, parsed.value.string, "ok"));
    }
}

test "valid multibyte text passes through the escaper unchanged" {
    const text = "日本語 \u{1f1e8}\u{1f1ed} \u{1f469}\u{200d}\u{1f4bb}";
    var buf = JsonBuf.init(std.testing.allocator);
    defer buf.list.deinit(std.testing.allocator);
    try writeJsonString(buf.writer(), text);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, buf.items(), .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings(text, parsed.value.string);
}

test "clamp keeps short strings intact" {
    try std.testing.expectEqualStrings("abc", clamp("abc", 8));
    // A string exactly at the limit is kept whole, not cut to one byte short.
    try std.testing.expectEqualStrings("abc", clamp("abc", 3));
    try std.testing.expectEqualStrings("ab", clamp("abcd", 2));
    try std.testing.expectEqualStrings("", clamp("abc", 0));
}

test "a cut never leaves half a code point in the request body" {
    // The bytes go into the JSON body verbatim, so anything clamp keeps has to
    // be a whole character: source files are full of multi-byte text and a
    // cut lands in one often enough to matter.
    const text = "caf\u{00e9} \u{1f600} fin";
    var n: usize = 0;
    while (n <= text.len) : (n += 1) {
        const kept = clamp(text, n);
        try std.testing.expect(kept.len <= n);
        try std.testing.expect(std.unicode.utf8ValidateSlice(kept));
        try std.testing.expect(std.mem.startsWith(u8, text, kept));
    }
    // The cut is at the boundary, not somewhere short of it.
    try std.testing.expectEqualStrings("caf\u{00e9} ", clamp(text, 7));
    try std.testing.expectEqualStrings("caf\u{00e9} \u{1f600}", clamp(text, 10));
    try std.testing.expectEqualStrings("", clamp("\u{1f600}", 2));
}
