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
    /// Whether the provider ever sent a `total_tokens` of its own. Until it
    /// does, the total is the sum of the parts, and a stream that spreads its
    /// usage over several frames re-sums it as each part lands rather than
    /// keeping the first frame's partial sum.
    total_from_provider: bool = false,
    /// Why the provider stopped generating, as the last frame spells it, or the
    /// empty slice when the stream carried none. `length` is the one that
    /// matters: it means the response was cut at `max_tokens`, so the turn is a
    /// prefix of what the model meant to say.
    finish_reason: []u8 = &.{},
    /// Bytes this one response has added to the run: the visible text and every
    /// call's arguments together. `max_response_bytes` bounds a response, not
    /// each stream in it, and the streams are not one: a provider that streams
    /// the full allowance of arguments for each of `max_tool_calls` calls holds
    /// a gigabyte of a single turn in memory, which is why the ceiling is one
    /// budget for the whole response rather than one per stream.
    streamed: usize = 0,
    /// Whether a fragment arrived that `clamp` would not take, because the
    /// response ceiling had no room left for a whole character of it.
    ///
    /// The counter alone cannot say so. `clamp` cuts on a codepoint boundary,
    /// so a response that arrives with one, two or three bytes of room under
    /// the ceiling and a character of two, three or four bytes to add keeps
    /// none of it and leaves `streamed` short of the ceiling by exactly that
    /// residue. A turn that lost its tail that way is as incomplete as one cut
    /// mid-character, and the run's notice is what says the turn is not the
    /// whole of what the model meant to send.
    dropped: bool = false,

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

/// The bytes that are copied through a JSON string exactly as they are, or
/// the inverse: a byte false here is one the escaper can step over without
/// looking at anything but itself.
///
/// It is one table rather than the pair of tests it replaces, because this is
/// the loop every byte of a turn passes through: a tool result, a file's
/// contents and up to `max_response_bytes` of the model's own text are all
/// written through here once per turn, and each byte was costing a C0
/// comparison, a quote test, a backslash test and an ASCII test before the
/// answer it already had in a table. Measured on ordinary source text that is
/// 2.1x the instructions per byte.
///
/// The rule the table encodes is the two tests it replaces, exactly: a C0
/// control, a quote and a backslash need an escape, a byte at or above 0x80
/// needs the UTF-8 check, and every other ASCII byte is copied. DEL (0x7f) is
/// one of those others, as it was before: JSON does not require it escaped.
const json_literal_byte = blk: {
    var table = [_]bool{false} ** 256;
    for (0x20..0x80) |c| table[c] = true;
    table['"'] = false;
    table['\\'] = false;
    break :blk table;
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
        if (json_literal_byte[c]) {
            i += 1;
            continue;
        }
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
        // Only a byte at or above 0x80 reaches here, so every one of them is
        // measured rather than most of them being ruled out first.
        const len = utf8SequenceLen(s, i);
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

/// A count a frame carried, or null when the frame left it out. `num` answers 0
/// for both, which is the right answer for a counter that starts at zero and
/// the wrong one for folding one frame into a total another frame already set:
/// a frame that carries `cached_tokens` alone must not read as a run that spent
/// no prompt tokens. A declared field the provider omitted parses as JSON
/// `null` rather than as an absent optional, so both are null here.
///
/// A count the frame spelled as a string is read as the number it spells, the
/// way the model-supplied counts in `tool` are: a provider that quotes
/// `prompt_tokens` meant a prompt-token count, and reading the quotes as zero
/// is a run whose usage line reports it spent nothing.
///
/// A string that is not a number is the same case as an omitted field rather
/// than the case of a zero count: the frame carried no count, and folding `0`
/// in would erase the count an earlier frame set. It is counted in
/// `unparsable` rather than folded in, because a counter the run read as zero
/// is a bill that comes up short with nothing on the operator's screen to say
/// why.
pub fn maybeNum(v: ?std.json.Value, unparsable: ?*usize) ?u64 {
    const value = v orelse return null;
    if (value == .null) return null;
    switch (value) {
        .string, .number_string => |s| {
            return std.fmt.parseInt(u64, std.mem.trim(u8, s, " \t\r\n"), 10) catch {
                if (unparsable) |n| n.* += 1;
                return null;
            };
        },
        else => return num(v),
    }
}

/// A count the model sent, as a `usize`. `num` saturates at the `u64` ceiling,
/// which a 32-bit build cannot hold, so the cast clamps instead of trapping:
/// a number too large to be a line count is a number that means "all of them".
pub fn numCount(v: ?std.json.Value) usize {
    return std.math.cast(usize, num(v)) orelse std.math.maxInt(usize);
}

/// A provider string this run will own, or the shared empty slice when the
/// provider sent nothing.
///
/// Ownership here is carried by emptiness: `deinitFinish` and `deinitCalls`
/// free a field only when it has bytes, because that is the test for a copy
/// this run made. Duping an empty string anyway breaks the test in the middle of
/// a stream: the field keeps its length of zero, so the next frame overwrites
/// it without releasing it, and the result's own deinit skips it as well. One
/// allocation per empty field, for every field the stream empties.
pub fn ownString(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    if (text.len == 0) return &.{};
    return try gpa.dupe(u8, text);
}

/// The first `max` bytes, cut on a UTF-8 codepoint boundary. Every caller feeds
/// text a model will read back: the two streams of one response in `main` and a
/// tool's output in `tool`, all of which reach a JSON request body, so a cut in
/// the middle of a codepoint would put invalid UTF-8 on the wire.
pub fn clamp(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    var end = max;
    while (end > 0 and s[end] & 0xc0 == 0x80) end -= 1;
    return s[0..end];
}

const hex_digits = "0123456789abcdef";

/// The UTF-8 byte order mark, which is not text: it says what the encoding is
/// and belongs to no value. Editors on Windows, and older ones elsewhere, write
/// it at the head of a file they save as UTF-8, so a config or a key file
/// arrives with it whether or not anybody asked for one.
pub const bom = "\u{feff}";

/// `text` without a leading byte order mark, and unchanged when there is none.
/// Every text file this program reads on the operator's behalf goes through
/// here: the mark is invisible in an editor, so a key file carrying one sent a
/// U+FEFF ahead of the key to the provider, and a config carrying one put the
/// mark inside its first key, which then matched no key this program knows.
pub fn stripBom(text: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, text, bom)) text[bom.len..] else text;
}

/// Text from outside the process, as an operator reads it on one line: at most
/// `max` bytes, every C0 control, DEL and C1 control written as `\xNN` so it
/// cannot end the line or move the cursor, and every byte that is not part of a
/// valid UTF-8 sequence written as U+FFFD so it does not reach the screen as
/// mojibake.
///
/// The C1 range is escaped as well as C0 because UTF-8 spells it `C2 80..9F`,
/// which is above the `c < 0x20` test below, and a terminal acts on U+009B
/// (CSI) exactly as it does on ESC `[`. The tool module's `terminalSafe` has
/// always escaped it for that reason; a value quoted through here reached the
/// same screen with the escape sequence intact.
///
/// What the value quotes is not this program's to choose: a config key is a
/// line a reviewed repository committed and a flag is whatever the caller
/// typed, so neither is guaranteed to be text. The other untrusted-byte paths
/// normalize in their own way, the request body by `writeJsonString` and an
/// error body by the tool module's `terminalSafe`; this is the one every value
/// on its way to a diagnostic passes through: a tool name and detail, a config
/// key and path, a release tag and an asset name.
///
/// The result is a prefix of the escaped text, never cut inside a character or
/// inside an escape, and the budget bounds what comes out rather than what
/// goes in: a control character costs four bytes, so the same `max` holds fewer
/// of them.
pub fn safeText(arena: std.mem.Allocator, s: []const u8, max: usize) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        // The printable ASCII a diagnostic is mostly made of, and the only
        // ASCII that reaches either branch below. One table rather than a C0
        // test, a DEL test and an ASCII test per byte, for the reason
        // `json_literal_byte` gives.
        if (c >= 0x20 and c < 0x7f) {
            if (out.items.len + 1 > max) break;
            out.append(arena, c) catch break;
            i += 1;
            continue;
        }
        if (c < 0x20 or c == 0x7f) {
            if (out.items.len + 4 > max) break;
            out.appendSlice(arena, &.{ '\\', 'x', hex_digits[c >> 4], hex_digits[c & 0x0f] }) catch break;
            i += 1;
            continue;
        }
        const len = utf8SequenceLen(s, i);
        if (len == 0) {
            if (out.items.len + 3 > max) break;
            out.appendSlice(arena, "\u{fffd}") catch break;
            i += 1;
            continue;
        }
        // A C1 control is a valid two-byte sequence, so it arrives here rather
        // than on the invalid-byte path above, and it is written as the escape
        // of the code point rather than of the two bytes UTF-8 spells it with.
        // The lead byte alone does not say C1: C2 80..9F is the range, and C2
        // A0..BF is U+00A0..U+00BF, which is text and passes through below.
        if (len == 2 and c == 0xc2 and s[i + 1] <= 0x9f) {
            if (out.items.len + 4 > max) break;
            out.appendSlice(arena, &.{ '\\', 'x', hex_digits[s[i + 1] >> 4], hex_digits[s[i + 1] & 0x0f] }) catch break;
            i += len;
            continue;
        }
        if (out.items.len + len > max) break;
        out.appendSlice(arena, s[i .. i + len]) catch break;
        i += len;
    }
    return out.items;
}

// The escaper decides per byte between three outcomes, and the table it reads
// is the decision. Every one of the 256 values is pinned to the rule the table
// claims to encode, because a byte on the wrong side of it is either escaped
// as text or dropped from the request body, and neither shows up in the round
// trip the other tests assert.
test "the literal-byte table is the escape and ASCII rules it replaces" {
    for (0..256) |n| {
        const c: u8 = @intCast(n);
        const escaped = c < 0x20 or c == '"' or c == '\\';
        // Above ASCII a byte is never copied without the UTF-8 check, and
        // below it a byte is copied when nothing else sends it elsewhere.
        const needs_check = c >= 0x80;
        try std.testing.expectEqual(!escaped and !needs_check, json_literal_byte[c]);
    }
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

test "an empty provider string is the shared slice, not a copy this run owns" {
    const gpa = std.testing.allocator;
    // A field's length is what tells the deinit that it owns the bytes behind
    // it, so an empty value has to stay the shared slice: a zero-length copy
    // reads as unowned and is never released.
    try std.testing.expectEqualStrings("", try ownString(gpa, ""));
    const owned = try ownString(gpa, "stop");
    defer gpa.free(owned);
    try std.testing.expectEqualStrings("stop", owned);
}

test "a value quoted back is text the terminal can be shown" {
    // A config key is whatever bytes the line held, a flag whatever the caller
    // typed. Both reach a diagnostic, so both are bounded and made printable
    // here rather than by each caller.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqualStrings("caf\u{00e9} \u{1f600}", safeText(arena, "caf\u{00e9} \u{1f600}", 40));
    // The C0 controls a config line or an argument can carry, and an invalid
    // byte, are neither printed nor dropped.
    try std.testing.expectEqualStrings("bad\\x00key\\x1b[31m\u{fffd}", safeText(arena, "bad\x00key\x1b[31m\xff", 40));
    // A backslash is the one printable byte the escapes are built from, so one
    // the value already carries is left alone rather than made ambiguous.
    try std.testing.expectEqualStrings("a\\b", safeText(arena, "a\\b", 40));
    // The C1 controls UTF-8 spells as C2 80..9F. A terminal acts on U+009B (CSI)
    // as it does on ESC `[`, so the sequence is shown as the escape of the code
    // point rather than passed through. U+00A0 is the first code point above the
    // range and is ordinary text, so it passes through as its own two bytes.
    try std.testing.expectEqualStrings("ls\\x9b31m caf\u{00a0}", safeText(arena, "ls\u{009b}31m caf\u{00a0}", 40));
}

test "a leading byte order mark is not part of the value it precedes" {
    // An editor that saves UTF-8 with a BOM writes one ahead of the first byte
    // of the value, and it is invisible in that editor, so nothing on the way
    // here looks like an error to strip.
    try std.testing.expectEqualStrings("caveman = \"lite\"\n", stripBom(bom ++ "caveman = \"lite\"\n"));
    // A mark anywhere else is content: a file whose second line opens with one
    // has a first line that is genuinely empty.
    try std.testing.expectEqualStrings("a\n" ++ bom ++ "b\n", stripBom("a\n" ++ bom ++ "b\n"));
    try std.testing.expectEqualStrings("", stripBom(""));
    try std.testing.expectEqualStrings("", stripBom(bom));
    // A truncated mark is not a mark, and a lone lead byte is still invalid.
    try std.testing.expectEqualStrings("\xef", stripBom("\xef"));
    try std.testing.expectEqualStrings("\xff\xfe", stripBom("\xff\xfe"));
}

test "a quoted value never exceeds its budget" {
    // The budget bounds the bytes that come out, so a line of control
    // characters cannot be four times the length it was given.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    for ([_][]const u8{ "a\nb\nc\nd\ne\nf\n", "\x01\x02\x03\x04\x05", "日本語" ** 10, "ok\xff\xff\xff" }) |raw| {
        for (0..raw.len + 1) |max| {
            const quoted = safeText(arena, raw, max);
            try std.testing.expect(quoted.len <= max);
            try std.testing.expect(std.unicode.utf8ValidateSlice(quoted));
        }
    }
    // A character the value did not carry is never cut in half, whatever the
    // budget: each of these is three or four bytes and the cuts land between
    // them.
    const wide = "日本語" ** 10;
    for (0..wide.len + 1) |max| {
        const quoted = safeText(arena, wide, max);
        try std.testing.expect(quoted.len <= max);
        try std.testing.expect(std.mem.startsWith(u8, wide, quoted));
        try std.testing.expect(quoted.len % 3 == 0);
    }
}

// Every value a diagnostic quotes back came from outside the process: an
// `argv` entry, a config key, a config path. `safeText` is what makes those
// bytes printable, so it is the last thing between a repository's bytes and the
// operator's screen, and both halves of its job are properties a fuzzer can
// see. Nothing a terminal acts on survives it, and a budget cuts whole
// characters and whole escapes rather than the bytes of either.
const safe_text_corpus = [_][]const u8{
    "",
    "a",
    "plain text",
    "\n",
    "\r\n",
    "\t\x00",
    "\x01\x02\x03\x1f\x7f",
    "\x1b[2J\x1b[31m\x07",
    "ls\u{009b}31m",
    "\u{00a0}\u{00a1}\u{00bf}",
    "caf\u{00e9}",
    "\u{65e5}\u{8a00}\u{1f600}",
    "\u{2028}\u{2029}\u{fffd}",
    "a\\b\\x41",
    "\xc2",
    "\xc2\x9b",
    "\xc3",
    "\xe6\x97",
    "\xf0\x9f",
    "\xed\xa0\x80",
    "\xc0\xaf",
    "\xf8\x88\x80\x80\x80",
    "\xff\xfe",
    "\xc3\x28",
    "ok\xff",
    "{\"key\":\"value\"}",
    "\x00" ** 64,
    "\x1b[31m" ** 20,
    "\u{1f600}" ** 20,
    "mixed \xff caf\u{00e9} \u{009b} \n text" ** 8,
};

test "a fuzzed quoted value is printable, whole, and inside its budget" {
    try std.testing.fuzz({}, fuzzSafeText, .{ .corpus = &safe_text_corpus });
}

fn fuzzSafeText(_: void, smith: *std.testing.Smith) !void {
    const gpa = std.testing.allocator;
    var raw: [4 * 1024]u8 = undefined;
    const text: []const u8 = if (smith.in) |seed| seed else raw[0..smith.slice(&raw)];
    // A budget the fuzzer picks, so the cuts land inside a character, inside
    // an escape and between them rather than only at the comfortable sizes a
    // fixed table would try.
    var budget_buf: [2]u8 = undefined;
    const max = smith.slice(&budget_buf);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const quoted = safeText(arena_state.allocator(), text, max);

    try std.testing.expect(quoted.len <= max);
    try std.testing.expect(std.unicode.utf8ValidateSlice(quoted));

    var i: usize = 0;
    while (i < quoted.len) : (i += 1) {
        const c = quoted[i];
        // A C0 control or DEL would move the cursor, clear the line or end it.
        try std.testing.expect(c >= 0x20 and c != 0x7f);
        // A C1 control is a valid two-byte sequence, so it passes a byte test
        // that only knows about C0.
        if (c == 0xc2) {
            try std.testing.expect(i + 1 >= quoted.len or quoted[i + 1] > 0x9f);
            i += 1;
        }
    }

    // A larger budget can only add to what a smaller one wrote, so the shorter
    // quote is a prefix of the longer: a budget that cut a character or an
    // escape in half, or dropped one that fitted, shows up here.
    const roomier = safeText(arena_state.allocator(), text, max + 64);
    try std.testing.expect(roomier.len >= quoted.len);
    try std.testing.expect(std.mem.startsWith(u8, roomier, quoted));
    try std.testing.expect(std.unicode.utf8ValidateSlice(roomier));
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

// Every byte the process holds that came from outside it goes out again
// through this escaper: a tool result, a file's bytes, a streamed fragment, an
// argv entry. A byte it does not cover is a request body the provider answers
// with a 400, and a byte it mangles is text the model reads back wrong, so the
// round trip is the property worth asserting on. `std.testing.fuzz` runs this
// corpus on every `zig build test`, and through the fuzzer's mutations when the
// test binary is built in fuzz mode. The corpus carries the shapes a file and a
// terminal carry: the escapes, DEL, NUL, text in several scripts, and the
// malformed sequences a latin-1 file or a cut codepoint leaves behind.
const json_string_corpus = [_][]const u8{
    "",
    "a",
    "\"",
    "\\",
    "\n",
    "\r\n",
    "\t",
    "\x08\x0c",
    "\u{0}\u{1}\u{1f}\u{7f}",
    "quote\" backslash\\ newline\n tab\t",
    "{\"content\":\"already a json string\"}",
    "caf\u{00e9}",
    "\u{65e5}\u{8a00}\u{1f600}",
    "\u{fffd}",
    "\u{2028}\u{2029}",
    "\xc3",
    "\xe6\x97",
    "\xf0\x9f",
    "\xed\xa0\x80",
    "\xc0\xaf",
    "\xf8\x88\x80\x80\x80",
    "\xc2",
    "\xff\xfe",
    "\xc3\x28",
    "ok\xff",
};

test "a fuzzed byte string leaves a JSON string that reads back as itself" {
    try std.testing.fuzz({}, fuzzJsonString, .{ .corpus = &json_string_corpus });
}

fn fuzzJsonString(_: void, smith: *std.testing.Smith) !void {
    const gpa = std.testing.allocator;
    var scratch: [8 * 1024]u8 = undefined;
    const text: []const u8 = if (smith.in) |seed| seed else scratch[0..smith.slice(&scratch)];

    var buf = JsonBuf.init(gpa);
    defer buf.list.deinit(gpa);
    try writeJsonString(buf.writer(), text);
    const quoted = buf.items();

    // What the escaper wrote has to be a JSON string on its own, or the body
    // built around it is a request the provider rejects.
    try std.testing.expect(try std.json.validate(gpa, quoted));

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const parsed = try std.json.parseFromSlice(std.json.Value, arena_state.allocator(), quoted, .{});
    const got = str(parsed.value) orelse return error.TestUnexpectedResult;
    if (std.unicode.utf8ValidateSlice(text)) {
        // Text that went in whole comes back whole: an escape the parser reads
        // as something else, or a character the escaper dropped, is text the
        // model never said.
        try std.testing.expectEqualStrings(text, got);
    } else {
        // A byte that is not a valid sequence became U+FFFD, so what comes
        // back is still text, and never longer than the three bytes each of
        // those replacements takes.
        try std.testing.expect(std.unicode.utf8ValidateSlice(got));
        try std.testing.expect(got.len <= text.len * 3);
    }
}
