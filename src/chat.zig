//! The value types one turn of a conversation is made of, the JSON writer every
//! request body and usage line goes through, and the escaping a value quoted
//! into a diagnostic goes through (`safeText` here, and the tool module's
//! `terminalSafe` for a provider error body).
//!
//! A leaf module, under `net` and the rest: it imports nothing from the agent
//! loop, the tools or `update`, so all three can speak the same turn without
//! importing each other. The escaping and the text helpers sit here rather than
//! beside their callers for the same reason: a tool name, a config key, a
//! release tag, a session directory and a path pasted back are all bytes this
//! program did not choose, and they are normalized once.

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

/// The tools a response can name, as a type rather than as the bytes that
/// spell one.
///
/// The name arrives from outside the process: it is whatever the provider put
/// in the stream. Past the boundary that resolves it, though, nothing has any
/// business comparing names as text. A call is dispatched to a handler, named
/// on the tool gutter, quoted back into a credentials refusal, and classified
/// as an edit or a test run, and each of those used to spell its own `mem.eql`
/// against a literal. That made the tool set a stringly-typed reference with
/// no owner: adding a tool meant editing the schema, the dispatch chain, and
/// four more string comparisons, and forgetting any one of them failed at run
/// time rather than at compile time.
///
/// Resolved once at the edge, the rest of the program switches on an enum, so a
/// new tool is a new variant and every `switch` over it that lacks an arm stops
/// the build instead of silently answering `unknown tool` to a model the schema
/// had just advertised the tool to.
pub const Tool = enum {
    bash,
    read,
    write,
    edit,
    multi_edit,
    search,
    ast,
    git,
    todo,

    /// The name as the wire spells it, which is the one the schema advertises
    /// and the one the provider's stream carries.
    pub fn name(tool: Tool) []const u8 {
        return @tagName(tool);
    }

    /// The tool a name is, or null for a name this program does not have. A
    /// name the model invented is the ordinary case here rather than an error
    /// the run stops on: the model may call anything, and the refusal is what
    /// it gets back as a tool result.
    pub fn fromName(text: []const u8) ?Tool {
        return std.meta.stringToEnum(Tool, text);
    }

    /// Whether calling the tool changes a file. `ast` answers false either
    /// way, because a search leaves the tree as it found it and a rewrite does
    /// not; a caller that knows a rewrite happened says so itself, the way
    /// `credentialRefusal` does with its `writes` parameter.
    pub fn writes(tool: Tool) bool {
        return tool == .write or tool == .edit or tool == .multi_edit;
    }
};

/// Every tool, in the order the schema advertises them. One list, so the tools
/// a run offers and the ones a caller iterates cannot be two lists.
pub inline fn tools() []const Tool {
    return &.{ .bash, .read, .write, .edit, .multi_edit, .search, .ast, .git, .todo };
}

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

// The name a tool is spelled by has to survive the round trip, because it is
// the same string on both sides of the wire: the schema advertises it, the
// provider streams it back, and the dispatcher resolves it. A `name` and a
// `fromName` that disagreed on a variant would be a tool the run advertises and
// then refuses by name, and the tag names are the one place the two could
// drift.
test "a tool's wire name and its variant are the same name both ways" {
    for (tools()) |tool| {
        try std.testing.expectEqual(tool, Tool.fromName(tool.name()).?);
    }
    // The whole set, so a variant that is not reachable by the name the schema
    // advertises cannot pass by having a name nothing resolves to.
    try std.testing.expectEqual(@typeInfo(Tool).@"enum".fields.len, tools().len);
    // And the names a model can send that are not tools, which are the ordinary
    // case at this boundary rather than an error.
    for ([_][]const u8{ "", "bash ", "Bash", "delete_everything", "bash\n", "read/write" }) |name| {
        try std.testing.expectEqual(@as(?Tool, null), Tool.fromName(name));
    }
}

test "only the tools that change a file say they write" {
    // The loop and the credential refusal both ask this of the same enum, so a
    // new variant is classified here once rather than in each of them. The
    // expected answers are spelled out in the order `tools()` advertises them
    // rather than recomputed from the rule under test, so a variant added to
    // the enum and to the schema but left out of `writes` fails here.
    const by_schema_order = [_]bool{ false, false, true, true, true, false, false, false, false };
    try std.testing.expectEqual(by_schema_order.len, tools().len);
    for (tools(), by_schema_order) |tool, writes| {
        try std.testing.expectEqual(writes, tool.writes());
    }
}

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
    /// The model the provider says answered, as the last frame that carried it
    /// spells it, or the empty slice when the stream carried none. Not the
    /// model the request named: a gateway routes a name like
    /// `deepseek/deepseek-v4-flash` to whichever snapshot it holds this week,
    /// so the name in the request is what was asked for and this is what ran.
    /// Two runs of one command are only comparable if the record says which of
    /// the two answered, and it is the session log that outlives both.
    served_model: []u8 = &.{},
    /// The provider's own fingerprint for the weights behind this response, or
    /// the empty slice when it sent none. The field that moves when the weights
    /// move behind a served name that does not.
    fingerprint: []u8 = &.{},
    /// What the provider said went wrong in the middle of the stream, in one
    /// line the caller can print, or the empty slice when no frame reported a
    /// failure. A provider that fails after the first tokens has no way to say
    /// so in a status line, so it puts an `error` object in a frame and stops:
    /// the frames around it carry choices, and a turn read on their own is a
    /// turn the provider finished. What it said before it gave up is on stdout
    /// by then, so a stream that reported a failure and one that ran to its end
    /// have to be told apart, and this is the field that tells them apart.
    stream_error: []u8 = &.{},
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
    /// Tool calls the response carried at an index past the ceiling the agent
    /// loop puts on one response's parallel calls, which the caller drops rather
    /// than size the call list to. The count travels on the response for the
    /// reason `dropped` does: the calls are gone from the turn, and a turn that
    /// ran fewer calls than the model asked for with nothing said about it is a
    /// turn whose work is smaller than the work it asked for.
    over_cap: usize = 0,
    /// The index `over_cap` last counted, so a call streamed as one frame per
    /// argument fragment is counted once rather than once per fragment. The
    /// fragments of a call arrive together, and a provider that interleaved two
    /// calls' fragments would break the `tool_call_id` pairing whatever the run
    /// counted, so the last index is the whole of what has to be remembered.
    over_cap_index: ?usize = null,

    /// Releases `finish_reason` only when it has bytes, because a non-empty
    /// field is the one `ownString` copied for this run: the shared empty slice
    /// is not this run's to free, and a copied one is a leak if it is kept.
    pub fn deinitFinish(self: *ChatResult, gpa: std.mem.Allocator) void {
        if (!std.mem.eql(u8, self.finish_reason, &.{})) gpa.free(self.finish_reason);
        self.finish_reason = &.{};
    }

    /// Releases `served_model` and `fingerprint` on the rule
    /// `deinitFinish` follows: a field with no bytes is the shared empty slice,
    /// which is not this run's to free.
    fn deinitServed(self: *ChatResult, gpa: std.mem.Allocator) void {
        if (self.served_model.len != 0) gpa.free(self.served_model);
        if (self.fingerprint.len != 0) gpa.free(self.fingerprint);
        self.served_model = &.{};
        self.fingerprint = &.{};
    }

    /// Releases `stream_error` on the same rule, and the note it carries is
    /// this run's own copy for the same reason: the frame it was read from is
    /// gone by the time the caller prints it.
    fn deinitStreamError(self: *ChatResult, gpa: std.mem.Allocator) void {
        if (self.stream_error.len != 0) gpa.free(self.stream_error);
        self.stream_error = &.{};
    }

    /// The response outlives the turn's arena, so what a turn keeps is
    /// allocated here and released with the turn rather than at process exit.
    /// The name and the id of a call are as much of the response as its
    /// arguments are, so they go with them.
    pub fn deinit(self: *ChatResult, gpa: std.mem.Allocator) void {
        deinitCalls(gpa, &self.calls);
        self.content.deinit(gpa);
        for (&[_]*[]u8{
            &self.finish_reason,
            &self.served_model,
            &self.fingerprint,
            &self.stream_error,
        }) |field| release(gpa, field);
    }
};

/// Releases a string field this run copied, and leaves it pointing at the
/// shared empty slice.
///
/// A field is freed only when it has bytes: the empty slice every field starts
/// at is shared and not this run's to free, and a copied one is a leak if it
/// is kept. A caller that replaces one field mid-stream releases it through
/// this before writing the new value over it; the frame the old copy was read
/// from is gone by then, so the copy is what has to be released.
pub fn release(gpa: std.mem.Allocator, field: *[]u8) void {
    if (field.*.len != 0) gpa.free(field.*);
    field.* = &.{};
}

/// Replaces an owned field with what a frame carried, and copies only when the
/// value changed. The copy is taken before the old one is released, so an
/// allocation that fails leaves the field holding what it held.
pub fn keepChanged(gpa: std.mem.Allocator, current: *[]u8, next: ?[]const u8) !void {
    const value = next orelse return;
    if (std.mem.eql(u8, current.*, value)) return;
    const owned = try ownString(gpa, value);
    if (current.*.len != 0) gpa.free(current.*);
    current.* = owned;
}

/// Records what a frame said answered, in the two fields the session log reads.
/// A field whose value did not change is left alone: a provider repeats `model`
/// and `system_fingerprint` on every chunk of a stream, so a copy per frame is
/// an allocation per chunk to hold bytes that did not move. A frame that
/// carried no value leaves what an earlier one said.
pub fn recordServed(gpa: std.mem.Allocator, result: *ChatResult, served: ?[]const u8, fingerprint: ?[]const u8) !void {
    try keepChanged(gpa, &result.served_model, served);
    try keepChanged(gpa, &result.fingerprint, fingerprint);
}

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

    /// A buffer that already has room for `capacity` bytes. Use it where the
    /// size is known before the first write, so a record of a few hundred
    /// bytes does not walk the whole doubling ladder to get there, reallocating
    /// and copying at every step.
    pub fn initCapacity(allocator: std.mem.Allocator, capacity: usize) JsonBuf {
        var list: std.ArrayList(u8) = .empty;
        list.ensureTotalCapacityPrecise(allocator, capacity) catch return init(allocator);
        return .{ .list = list, .allocating = Io.Writer.Allocating.fromArrayList(allocator, &list) };
    }

    pub fn writer(self: *JsonBuf) *Io.Writer {
        return &self.allocating.writer;
    }

    /// Hands back the buffer and gives up ownership of it: the `Allocating` is
    /// reset, so this is the last call on this `JsonBuf` and any write after it
    /// starts a new buffer.
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

const word_bytes = @sizeOf(u64);
const lane_ones: u64 = 0x0101010101010101;
const lane_highs: u64 = lane_ones * 0x80;

/// Whether all eight bytes of `word` are ones `json_literal_byte` copies as they are: none below
/// 0x20, none at or above 0x80, and no quote or backslash. Each test is the exact "does any byte
/// match" bit trick, so a word with one special byte is refused whole.
fn allLiteral(word: u64) bool {
    const below_space = (word -% lane_ones * 0x20) & ~word;
    const quote = (word ^ lane_ones * '"') -% lane_ones;
    const backslash = (word ^ lane_ones * '\\') -% lane_ones;
    return ((below_space | word | quote | backslash) & lane_highs) == 0;
}

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
            // Text runs long between escapes, so a word at a time is checked once a byte has
            // proved this is one. Mostly-escaped or non-ASCII text never gets here.
            while (i + word_bytes <= s.len and allLiteral(std.mem.readInt(u64, s[i..][0..word_bytes], .little))) i += word_bytes;
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
                // The generic formatter is a lot of machinery to emit six fixed
                // bytes, and this is the per-byte arm of the loop every byte of
                // a turn passes through: a binary file or a control-heavy tool
                // result pays it once per byte. The byte is below 0x20 here, so
                // the high nibble is zero and the escape is always `\u00xx`.
                else => {
                    try w.writeAll("\\u00");
                    try w.writeByte(hex_digits[c >> 4]);
                    try w.writeByte(hex_digits[c & 0x0f]);
                },
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

/// The most bytes one UTF-8 character is made of, which bounds how far back
/// from the end of a string the search for an unfinished character looks.
pub const utf8_max_sequence_bytes = 4;

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

/// How many bytes at the end of `s` are the start of a sequence `s` cuts in
/// half, and 0 when it ends on a character boundary.
///
/// The transport chunks a completion body wherever it likes, which is a byte
/// boundary rather than a character one: `\xe6\x97\xa5` arriving as `\xe6\x97`
/// then `\xa5` is a legal chunking of a legal answer. Writing the first half
/// out as it arrives puts a replacement glyph and then a broken byte on the
/// operator's screen, and a reader validating each write as text sees two
/// fragments where there is one character. A caller that writes `s` as it grows
/// holds this many bytes back until the next chunk completes them.
///
/// Bytes that are not a sequence at all are not half of one: a lead byte
/// nothing follows, and a run of continuation bytes with no lead, are what
/// they are on their own, and holding them back would stall the output behind
/// text that will never be completed.
pub fn partialTailLen(s: []const u8) usize {
    var n: usize = 1;
    while (n <= utf8_max_sequence_bytes and n <= s.len) : (n += 1) {
        const c = s[s.len - n];
        if (c & 0xc0 != 0x80) {
            const want = std.unicode.utf8ByteSequenceLength(c) catch return 0;
            return if (want > n) n else 0;
        }
    }
    return 0;
}

/// The code points that change what a terminal shows without contributing a
/// glyph of their own: the bidi controls that reorder or mirror everything
/// around them, the zero-width characters, and the soft hyphen. Each of them is
/// well-formed UTF-8 and none of them is a C0 or C1 control, so the byte tests
/// every escaper here already has pass them through, and the result is a
/// diagnostic that names a different thing than the one it quotes:
/// `deploy/\u{202e}gnp.exe` reaches the screen as `deploy/exe.png`, so a reader
/// who copies what they were shown types a name that is not the name the tool
/// was asked for. Whether that is a name a filesystem allowed or a trick
/// played on the reader is not this function's question; what belongs to it is
/// that no byte reaches a terminal without being written out first.
///
/// U+200D is deliberately not in the set: it is the joiner an emoji sequence is
/// built from, and escaping it splits `\u{1f469}\u{200d}\u{1f4bb}` into three
/// glyphs where there was one. It has no display effect on its own, so it
/// carries nothing that can be hidden behind it.
pub fn isInvisibleFormat(cp: u21) bool {
    return switch (cp) {
        // SOFT HYPHEN, ZERO WIDTH SPACE, ZERO WIDTH NON-JOINER, LEFT-TO-RIGHT
        // MARK, RIGHT-TO-LEFT MARK, ARABIC LETTER MARK.
        0x00ad, 0x200b, 0x200c, 0x200e, 0x200f, 0x061c => true,
        // LRE, RLE, PDF, LRO, RLO: the embeddings and overrides, which are how
        // a file name is spelled backwards.
        0x202a...0x202e => true,
        // WORD JOINER, then the isolates LRI, RLI, FSI and PDI, then the
        // deprecated format characters the Unicode standard withdrew.
        0x2060, 0x2066...0x206f => true,
        // ZERO WIDTH NO-BREAK SPACE, a byte order mark inside a value rather
        // than ahead of it.
        0xfeff => true,
        else => false,
    };
}

/// The `\uXXXX` spelling of a code point, six bytes. Longer than the `\xNN`
/// escape of a control, and only a codepoint above ASCII needs it.
fn appendCodepointEscape(out: *std.ArrayList(u8), arena: std.mem.Allocator, cp: u21) !void {
    try out.append(arena, '\\');
    try out.append(arena, 'u');
    inline for (.{ 12, 8, 4, 0 }) |shift| {
        try out.append(arena, hex_digits[@intCast((cp >> shift) & 0xf)]);
    }
}

/// A JSON string, and nothing else. A number, a `number_string` or a container
/// is not one, so a call carrying a bare number reads as one that left the
/// argument out; `maybeNum` is the reader that accepts both spellings of a
/// number.
pub fn str(v: ?std.json.Value) ?[]const u8 {
    const value = v orelse return null;
    return switch (value) {
        .string => |s| s,
        else => null,
    };
}

/// A count a JSON value spells, or null when it spells no count at all. This is
/// the one reader of a count the tree shares: `num` answers zero for what it
/// cannot read, the usage folding has to answer null instead, and the model-
/// supplied counts want null as well, and three copies of this switch drifted
/// into disagreeing about whether `" 5 "` is five.
///
/// A number spelled as a string is a number a provider or a model meant, so it
/// is read as one, and the whitespace around it is part of the spelling rather
/// than part of the number. A value of some other JSON type is a count nobody
/// sent.
pub fn countArg(v: ?std.json.Value) ?u64 {
    const value = v orelse return null;
    return switch (value) {
        .integer => |n| if (n > 0) @intCast(n) else 0,
        .float => |f| std.math.lossyCast(u64, f),
        .number_string, .string => |s| std.fmt.parseInt(u64, std.mem.trim(u8, s, " \t\r\n"), 10) catch null,
        else => null,
    };
}

/// A count as a `u64`: an integer, a float (truncated, and clamped at both
/// ends), or a number spelled as a string or `number_string`. A bool, a
/// container, a null and an absent field are all 0, which is the right answer
/// for a counter that starts at zero and the wrong one for folding a frame into
/// a total.
pub fn num(v: ?std.json.Value) u64 {
    return countArg(v) orelse 0;
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
    switch (value) {
        .string, .number_string => {
            if (countArg(value)) |n| return n;
            if (unparsable) |n| n.* += 1;
            return null;
        },
        // A count below zero is a count nobody sent, not a count of zero:
        // `countArg` answers zero for it because a line count that clamps to
        // zero is one line, and folding that zero into a usage total erases
        // what an earlier frame billed. `usage.total` is what
        // `spendCeilingReached` reads, so a run that had already spent its
        // budget read zero and never stopped.
        .integer => |n| return if (n >= 0) @intCast(n) else null,
        // A count spelled as a float is truncated, the way `countArg` reads
        // one, and a negative one is the case the integer arm above names: it
        // clamps to zero, and folding that zero into a total erases what an
        // earlier frame billed. The two spellings of a number have to agree or
        // the guard is a guard on half the input: `{"prompt_tokens": -1.0}`
        // parses as a float and reaches this arm rather than the one above.
        .float => |f| return if (f >= 0) std.math.lossyCast(u64, f) else null,
        // A declared field the provider omitted parses as JSON `null` rather
        // than as an absent optional, so both are null here. So is a boolean,
        // an array or an object: a frame carrying one of those under a count's
        // name carried no count, and reading it as zero is a bill that comes up
        // short with nothing on the operator's screen to say why.
        else => return countArg(value),
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
/// Ownership here is carried by emptiness: `release` and `deinitCalls`
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
/// cannot end the line or move the cursor, every invisible and bidi control
/// written as `\uXXXX` so it cannot reorder or hide what is around it, and
/// every byte that is not part of a valid UTF-8 sequence written as U+FFFD so
/// it does not reach the screen as mojibake.
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
    // Every byte that reaches the output costs at least one, so the input
    // length and the budget bound the result, and one reservation replaces the
    // walk up the growth ladder a diagnostic's worth of bytes otherwise takes.
    out.ensureTotalCapacityPrecise(arena, @min(s.len, max)) catch {};
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        // The printable ASCII a diagnostic is mostly made of, and the only
        // ASCII that reaches either branch below. One table rather than a C0
        // test, a DEL test and an ASCII test per byte, for the reason
        // `json_literal_byte` gives. A run of them is copied whole, the way
        // `writeJsonString` copies one, rather than byte by byte.
        if (c >= 0x20 and c < 0x7f) {
            const room = max -| out.items.len;
            if (room == 0) break;
            var end = i + 1;
            while (end < s.len) : (end += 1) {
                const d = s[end];
                if (d < 0x20 or d >= 0x7f) break;
            }
            const run_end = @min(end, i + room);
            out.appendSlice(arena, s[i..run_end]) catch break;
            // A run the budget cut short ends the value, exactly as the
            // byte-at-a-time budget test did.
            if (run_end < end) break;
            i = end;
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
        // The characters that reorder a line without a glyph of their own are
        // well-formed text, so the byte tests above hand them on, and a
        // diagnostic quoting one names a different thing than the value it
        // quotes. They are written as the code point they are, which is what
        // makes the difference visible: the reader sees the override that was
        // there rather than the file name it reversed.
        const cp = std.unicode.utf8Decode(s[i..][0..len]) catch {
            i += len;
            continue;
        };
        if (isInvisibleFormat(cp)) {
            if (out.items.len + codepoint_escape_bytes > max) break;
            appendCodepointEscape(&out, arena, cp) catch break;
            i += len;
            continue;
        }
        if (out.items.len + len > max) break;
        out.appendSlice(arena, s[i .. i + len]) catch break;
        i += len;
    }
    return out.items;
}

/// How many bytes the `\uXXXX` escape of one code point is.
const codepoint_escape_bytes: usize = 6;

/// The longest `safeText` can be for a byte of input. A C0 control is one byte
/// and becomes four. The shortest code point `isInvisibleFormat` names is two
/// bytes and becomes six, which is three per input byte and so below the four a
/// control costs. A value a reader has
/// to be able to recognize in full (a path they will copy, a url they will
/// paste) is escaped under a budget no escaping can overrun, and this is the
/// multiplier that spells it. The quote budget the other callers pass is for a
/// value quoted inside a sentence, where a truncated tail is still a shorter
/// sentence rather than a path that no longer names anything.
pub const safe_text_widening: usize = 4;

/// `s` escaped whole, for a diagnostic a reader has to be able to use: a
/// directory to look in, a url to paste, a model id to retype. The budget is
/// `safe_text_widening` per input byte, so the escaping cannot be cut short
/// part way through a path.
pub fn safeTextAll(arena: std.mem.Allocator, s: []const u8) []const u8 {
    return safeText(arena, s, s.len *| safe_text_widening);
}

// The whole-value form is what every diagnostic quoting a path, a model id or a
// variable's value now uses, so what it guarantees is pinned here: the escaping
// is complete (nothing past the input is invented, nothing in it is dropped) and
// nothing a terminal acts on survives. The budget is what makes completeness
// possible, so the two are asserted against the same input rather than
// separately.

// What `safeTextAll` quoted, read back: a `\xNN` escape is the byte it names, a
// `\uXXXX` escape is the code point it names, and every other byte is the byte
// it was. The escaper never writes a bare backslash, because `\` is printable
// ASCII and is copied rather than escaped, so the two forms do not collide.
fn unescapeSafeText(gpa: std.mem.Allocator, quoted: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < quoted.len) {
        if (quoted[i] == '\\' and i + 3 < quoted.len and quoted[i + 1] == 'x') {
            const hi = std.fmt.charToDigit(quoted[i + 2], 16) catch return error.MalformedEscape;
            const lo = std.fmt.charToDigit(quoted[i + 3], 16) catch return error.MalformedEscape;
            try out.append(gpa, hi * 16 + lo);
            i += 4;
            continue;
        }
        if (quoted[i] == '\\' and i + 5 < quoted.len and quoted[i + 1] == 'u') {
            var cp: u21 = 0;
            for (quoted[i + 2 ..][0..4]) |d| {
                cp = cp * 16 + (std.fmt.charToDigit(d, 16) catch return error.MalformedEscape);
            }
            var buf: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(cp, &buf) catch unreachable;
            try out.appendSlice(gpa, buf[0..n]);
            i += 6;
            continue;
        }
        try out.append(gpa, quoted[i]);
        i += 1;
    }
    return out.toOwnedSlice(gpa);
}

// The value the escaper was given, written out the way its own documentation
// says it reads: whole characters keep their bytes and a byte that begins none
// is U+FFFD. A quoted value that decodes to this is one that dropped nothing
// and invented nothing. An invisible or bidi character decodes back to the
// code point it was written from, so it is the same reference for the two
// escapers even though only one of them spells it as an escape.
fn safeTextInputAsQuoted(gpa: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < raw.len) {
        const len = std.unicode.utf8ByteSequenceLength(raw[i]) catch {
            try out.appendSlice(gpa, "\u{fffd}");
            i += 1;
            continue;
        };
        const end = i + len;
        if (end > raw.len or !std.unicode.utf8ValidateSlice(raw[i..end])) {
            try out.appendSlice(gpa, "\u{fffd}");
            i += 1;
            continue;
        }
        try out.appendSlice(gpa, raw[i..end]);
        i = end;
    }
    return out.toOwnedSlice(gpa);
}

test "a value quoted whole is escaped whole, and nothing in it is a control" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cases = [_][]const u8{
        "",
        "/home/me/.microagent/sessions",
        "/home/me\x1b[2J",
        "/home/\x9b31m/sessions",
        "/home/me/\xff\xfe",
        "/home/me/\u{00e5}\u{4e2d}\u{6587}/sessions",
        "model-with-a-\u{1f600}-in-it",
        "\x00\x01\x02\x7f",
        "a back\\slash and an \x01 escape",
        "deploy/\u{202e}gnp.exe",
        "\u{200b}\u{200e}\u{202a}hidden\u{202c}\u{2066}isolate",
    };
    inline for (cases) |raw| {
        const quoted = safeTextAll(arena, raw);
        // Every character that reaches a terminal through this value is
        // printable ASCII, a whole character that neither acts on the terminal
        // nor reorders it, or U+FFFD: the C0 controls, DEL, the C1 range and
        // the invisible and bidi characters are all written as escapes, and a
        // byte that is not text is U+FFFD. The C1 range and the invisible
        // characters are checked as characters rather than bytes, because UTF-8
        // spells them `C2 80..9F` and `E2 80..8F` and every one of those bytes
        // passes a per-byte test.
        var i: usize = 0;
        while (i < quoted.len) {
            const len = std.unicode.utf8ByteSequenceLength(quoted[i]) catch unreachable;
            const cp = std.unicode.utf8Decode(quoted[i..][0..len]) catch unreachable;
            const control = cp < 0x20 or cp == 0x7f or (cp >= 0x80 and cp <= 0x9f);
            try std.testing.expect(!control);
            try std.testing.expect(!isInvisibleFormat(cp));
            i += len;
        }
        // Whole: the budget is four bytes per input byte and no escape is
        // longer than that, so nothing was cut, and unquoting what came out
        // gives back the value that went in, with every byte that is not text
        // as the U+FFFD it was quoted for.
        try std.testing.expect(quoted.len <= raw.len *| safe_text_widening);
        const back = try unescapeSafeText(gpa, quoted);
        defer gpa.free(back);
        const want = try safeTextInputAsQuoted(gpa, raw);
        defer gpa.free(want);
        try std.testing.expectEqualStrings(want, back);
    }
    // The two forms differ exactly where the escaping does, so a test that
    // pins one does not silently pass on the other.
    try std.testing.expectEqualStrings("/home/me/.microagent/sessions", safeTextAll(arena, "/home/me/.microagent/sessions"));
    try std.testing.expectEqualStrings("/home/me\\x1b[2J", safeTextAll(arena, "/home/me\x1b[2J"));
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
        // The escaper does not read the table: it asks the rule. Two spellings
        // of one decision drift apart the moment one of them is edited, and the
        // bytes that go wrong are a request body, so the rule is held to the
        // table here rather than restated beside it.
        try std.testing.expectEqual(escaped, jsonNeedsEscape(c));
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

// The word-at-a-time skip must refuse a word holding a special byte at any lane, and accept one
// that holds none, so each special sits at every offset of a string longer than three words. The
// reference is std's own escaper, which spells these bytes the same way.
test "a special byte at any offset escapes the way std.json escapes it" {
    const specials = [_]u8{ 0x00, 0x08, 0x1f, 0x20, '"', '\\', '/', 0x7e, 0x7f };
    var text: [40]u8 = undefined;
    for (specials) |special| {
        for (0..text.len) |at| {
            @memset(&text, 'a');
            text[at] = special;

            var ours = JsonBuf.init(std.testing.allocator);
            defer ours.list.deinit(std.testing.allocator);
            try writeJsonString(ours.writer(), &text);

            var reference: Io.Writer.Allocating = .init(std.testing.allocator);
            defer reference.deinit();
            try std.json.Stringify.value(@as([]const u8, &text), .{}, &reference.writer);

            try std.testing.expectEqualStrings(reference.written(), ours.items());
        }
    }
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
        const gpa = std.testing.allocator;
        var buf = JsonBuf.init(gpa);
        defer buf.list.deinit(gpa);
        try writeJsonString(buf.writer(), raw);

        var parsed = try std.json.parseFromSlice(std.json.Value, gpa, buf.items(), .{});
        defer parsed.deinit();
        try std.testing.expect(std.unicode.utf8ValidateSlice(parsed.value.string));
        // The valid text either side of a bad byte survives unchanged, and a
        // bad byte becomes the one replacement character it is written as, so
        // the value parses to the input with each undecodable byte named.
        const want = try safeTextInputAsQuoted(gpa, raw);
        defer gpa.free(want);
        try std.testing.expectEqualStrings(want, parsed.value.string);
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

// A name carrying a bidi override is well-formed UTF-8 and passes every byte
// test the escaper had, so it reached the terminal as a different name than the
// one the tool was asked for: `deploy/` followed by U+202E and `gnp.exe` reads
// as `deploy/exe.png`. The override is written out as the code point it is, so
// the reader sees it instead of the result of it.
test "a value quoting a bidi override names the override, not the name it reverses" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqualStrings(
        "deploy/\\u202egnp.exe",
        safeTextAll(arena, "deploy/\u{202e}gnp.exe"),
    );
    // The embedding, isolate and zero-width characters are the same rule, and
    // the soft hyphen and a mark inside a value are the two-byte spellings of
    // it, which is the case the widening budget has to cover.
    try std.testing.expectEqualStrings("\\u202a\\u2066", safeText(arena, "\u{202a}\u{2066}", 40));
    try std.testing.expectEqualStrings("\\u00ad\\ufeff", safeText(arena, "\u{00ad}\u{feff}", 40));
    // ZWJ is not one of them: it is how an emoji sequence is spelled, and
    // escaping it would split one glyph into three.
    try std.testing.expectEqualStrings("\u{1f469}\u{200d}\u{1f4bb}", safeText(arena, "\u{1f469}\u{200d}\u{1f4bb}", 40));
    // The two-byte spellings cost six bytes each and the budget bounds what
    // comes out rather than what went in, so a cut lands between the escapes
    // and never inside one.
    for (0.."\u{00ad}\u{00ad}\u{00ad}".len * safe_text_widening + 1) |max| {
        const quoted = safeText(arena, "\u{00ad}\u{00ad}\u{00ad}", max);
        try std.testing.expect(quoted.len <= max);
        try std.testing.expect(std.unicode.utf8ValidateSlice(quoted));
    }
}

test "a leading byte order mark is not part of the value it precedes" {
    // An editor that saves UTF-8 with a BOM writes one ahead of the first byte
    // of the value, and it is invisible in that editor, so nothing on the way
    // here looks like an error to strip.
    try std.testing.expectEqualStrings("skills = []\n", stripBom(bom ++ "skills = []\n"));
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
    // them. The escaped length is not a multiple of anything: it depends on
    // which characters the budget left inside an escape, so a length rule
    // would only be a statement about this fixture.
    const wide = "日本語" ** 10;
    for (0..wide.len + 1) |max| {
        const quoted = safeText(arena, wide, max);
        try std.testing.expect(quoted.len <= max);
        try std.testing.expect(std.mem.startsWith(u8, wide, quoted));
    }
    // A budget that lands inside a run of printable ASCII keeps the part of the
    // run that fits and stops there, which is what copying the run whole has to
    // preserve.
    for (0.."plain".len + 1) |max| {
        try std.testing.expectEqualStrings("plain"[0..max], safeText(arena, "plain", max));
    }
    try std.testing.expectEqualStrings("plain", safeText(arena, "plain", 5));
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
    "deploy/\u{202e}gnp.exe",
    "\u{200b}\u{200c}\u{200e}\u{200f}\u{202a}\u{202e}\u{2066}\u{2069}\u{feff}",
    "\u{200d}",
    "\u{1f469}\u{200d}\u{1f4bb}",
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
        // The invisible and bidi characters are valid sequences too, and they
        // are the ones that pass every byte test above: nothing a terminal acts
        // on survives, and nothing that reorders the line around it either.
        if (c == 0xe2) {
            const len = std.unicode.utf8ByteSequenceLength(c) catch continue;
            const end = @min(i + len, quoted.len);
            const cp = std.unicode.utf8Decode(quoted[i..end]) catch {
                i = end;
                continue;
            };
            try std.testing.expect(!isInvisibleFormat(cp));
            i = end - 1;
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

// A transport splits a body wherever it likes, so the split lands inside a
// character as often as not: a run that writes each chunk as it arrives must be
// able to tell how much of the chunk it cannot write yet. What a writer must
// not do is lose bytes or cut a glyph in half, so the loop asks for the two
// properties that catch a wrong count at every one of the split points; the
// exact count for each is pinned by the test that follows.
test "a body split at any byte still joins into the text it was" {
    const text = "a\u{00e9}\u{65e5}\u{1f600}z";
    for (0..text.len + 1) |at| {
        const head = text[0..at];
        const held = partialTailLen(head);
        // What a writer keeps back is the half of one character and nothing
        // more, and everything it does write is whole text.
        try std.testing.expect(held <= utf8_max_sequence_bytes);
        try std.testing.expect(held <= head.len);
        try std.testing.expect(std.unicode.utf8ValidateSlice(head[0 .. head.len - held]));
        // The character the split fell in can have its lead byte in this chunk
        // and its last bytes in the next, which is the case this is here for: a
        // three-byte head and a one-byte tail of a four-byte character. A count
        // that over-held would swallow whole characters, so what goes on the
        // wire before the tail is put back has to be the text's own prefix and
        // nothing longer.
        try std.testing.expect(std.mem.startsWith(u8, text, head[0 .. head.len - held]));
    }
}

test "only half a character is held back" {
    // Whole characters and ASCII are written as they arrive.
    try std.testing.expectEqual(@as(usize, 0), partialTailLen(""));
    try std.testing.expectEqual(@as(usize, 0), partialTailLen("abc"));
    try std.testing.expectEqual(@as(usize, 0), partialTailLen("caf\u{00e9}"));
    try std.testing.expectEqual(@as(usize, 0), partialTailLen("\u{65e5}\u{1f600}"));
    // And the half that is a lead byte waiting for its tail is not.
    try std.testing.expectEqual(@as(usize, 1), partialTailLen("\u{65e5}"[0..1]));
    try std.testing.expectEqual(@as(usize, 2), partialTailLen("\u{65e5}"[0..2]));
    try std.testing.expectEqual(@as(usize, 1), partialTailLen("\u{1f600}"[0..1]));
    try std.testing.expectEqual(@as(usize, 2), partialTailLen("\u{1f600}"[0..2]));
    try std.testing.expectEqual(@as(usize, 3), partialTailLen("\u{1f600}"[0..3]));
    // Bytes no character is made of are not half of one, and holding them back
    // would stall the output behind text that is never coming.
    try std.testing.expectEqual(@as(usize, 0), partialTailLen("\xff"));
    try std.testing.expectEqual(@as(usize, 0), partialTailLen("\x80\x80\x80\x80"));
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

// `num` is the shared reader for every count a model or a provider supplies:
// the usage counters folded into a run total, the line limits `tool` applies.
// Every arm is pinned with a hand-written value, because the arms disagree
// about what a zero, a negative or a non-number means, and an arm read as zero
// is a run that reports it spent nothing.
test "a count is read from every shape a frame can spell it in" {
    const cases = .{
        .{ std.json.Value{ .null = {} }, 0 },
        .{ std.json.Value{ .integer = 0 }, 0 },
        .{ std.json.Value{ .integer = -5 }, 0 },
        .{ std.json.Value{ .integer = 7 }, 7 },
        .{ std.json.Value{ .float = 2.9 }, 2 },
        .{ std.json.Value{ .float = -1.0 }, 0 },
        .{ std.json.Value{ .float = 1e30 }, std.math.maxInt(u64) },
        .{ std.json.Value{ .number_string = "12" }, 12 },
        .{ std.json.Value{ .number_string = "twelve" }, 0 },
        .{ std.json.Value{ .string = "12" }, 12 },
        .{ std.json.Value{ .string = "twelve" }, 0 },
        .{ std.json.Value{ .bool = true }, 0 },
    };
    inline for (cases) |c| try std.testing.expectEqual(c[1], num(c[0]));
    // A container is not a count, and neither is it a zero to fold in.
    var items: std.json.Array = .init(std.testing.allocator);
    defer items.deinit();
    try std.testing.expectEqual(@as(u64, 0), num(.{ .array = items }));
    // An absent field is the same answer as an explicit null: the frame
    // carried no count either way.
    try std.testing.expectEqual(@as(u64, 0), num(null));
}

// `maybeNum` exists because folding an absent count in as zero would erase the
// count an earlier frame set, so "not a number" has to be distinguishable from
// "zero". The counter is how a run says which of the two it saw.
test "a count that is absent, null or not a number is left to the caller" {
    try std.testing.expectEqual(@as(?u64, null), maybeNum(null, null));
    try std.testing.expectEqual(@as(?u64, null), maybeNum(std.json.Value{ .null = {} }, null));

    // Spelled as a string, because providers quote these; whitespace around a
    // quoted number is still that number.
    try std.testing.expectEqual(@as(?u64, 12), maybeNum(.{ .string = "12" }, null));
    try std.testing.expectEqual(@as(?u64, 12), maybeNum(.{ .string = " 12 \r\n" }, null));

    var unparsable: usize = 0;
    try std.testing.expectEqual(@as(?u64, null), maybeNum(.{ .string = "many" }, &unparsable));
    try std.testing.expectEqual(@as(usize, 1), unparsable);
    // A second refusal adds to the count rather than resetting it.
    try std.testing.expectEqual(@as(?u64, null), maybeNum(.{ .string = "" }, &unparsable));
    try std.testing.expectEqual(@as(usize, 2), unparsable);
    // A real number never touches the counter, whichever arm read it.
    try std.testing.expectEqual(@as(?u64, 3), maybeNum(.{ .integer = 3 }, &unparsable));
    try std.testing.expectEqual(@as(usize, 2), unparsable);
    // A null counter is the "nobody is counting" case, and it must not trap.
    try std.testing.expectEqual(@as(?u64, null), maybeNum(.{ .string = "many" }, null));
}

// A count below zero, and a count spelled as a boolean or a container, are the
// case the whole function exists for: each of them used to read as a real zero
// and be folded over what an earlier frame had already billed, and
// `usage.total` is what the spend ceiling is checked against, so a run that had
// spent its budget read zero and kept going.
test "a usage count that is not a count is absent, not zero" {
    var unparsable: usize = 0;
    var items: std.json.Array = .init(std.testing.allocator);
    defer items.deinit();

    // None of these is a number, so none of them is a count, and none of them
    // is a mis-spelled one either: the counter stays where it was.
    try std.testing.expectEqual(@as(?u64, null), maybeNum(.{ .bool = true }, &unparsable));
    try std.testing.expectEqual(@as(?u64, null), maybeNum(.{ .array = items }, &unparsable));
    try std.testing.expectEqual(@as(?u64, null), maybeNum(.{ .integer = -1 }, &unparsable));
    try std.testing.expectEqual(@as(usize, 0), unparsable);

    // A count of zero is a count, and is folded in like any other.
    try std.testing.expectEqual(@as(?u64, 0), maybeNum(.{ .integer = 0 }, &unparsable));
    // The saturated float `num` is documented to answer stays a real number
    // here, so a provider quoting a huge count does not erase the total.
    try std.testing.expectEqual(@as(?u64, std.math.maxInt(u64)), maybeNum(.{ .float = 1e30 }, &unparsable));
}

// The three readers of a count answer differently on purpose, and agree on
// everything else: each of them had its own copy of the switch, and the copies
// disagreed about whether `" 5 "` was five.
test "every reader of a count reads a quoted number the same way" {
    const quoted: std.json.Value = .{ .string = " 5 \r\n" };
    try std.testing.expectEqual(@as(u64, 5), num(quoted));
    try std.testing.expectEqual(@as(?u64, 5), countArg(quoted));
    try std.testing.expectEqual(@as(?u64, 5), maybeNum(quoted, null));
    // A quoted number that is not one is null for the two that can say so, and
    // zero for the one that answers a total.
    const unquoted: std.json.Value = .{ .string = "many" };
    try std.testing.expectEqual(@as(u64, 0), num(unquoted));
    try std.testing.expectEqual(@as(?u64, null), countArg(unquoted));
    try std.testing.expectEqual(@as(?u64, null), maybeNum(unquoted, null));
}

// `str` backs every tool argument read, and a non-string there is a call that
// is missing the argument it needs, not a call whose argument is the number.
test "a string argument is read only from a string" {
    try std.testing.expectEqualStrings("x", str(.{ .string = "x" }).?);
    // An empty string is still the string the model sent, so a length check
    // that reads it as missing turns `""` into a refusal no path asked for.
    try std.testing.expectEqualStrings("", str(.{ .string = "" }).?);
    // Every other shape the wire can carry, including the two the string arm
    // is not the only candidate for: a number is what a bare `timeout` parses
    // to, and a container is what a nested argument arrives as.
    for ([_]std.json.Value{
        std.json.Value{ .integer = 3 },
        std.json.Value{ .float = 1.5 },
        std.json.Value{ .number_string = "3" },
        std.json.Value{ .bool = false },
        std.json.Value{ .null = {} },
        std.json.Value{ .array = std.json.Array.init(std.testing.allocator) },
        std.json.Value{ .object = .empty },
    }) |value| {
        try std.testing.expect(str(value) == null);
    }
    try std.testing.expect(str(null) == null);
}

// The escaper asks `utf8SequenceLen` what to copy, and 0 is the answer that
// turns a byte into U+FFFD. A bad lead byte, a truncated tail, an overlong
// encoding and a surrogate all have to read as 0 rather than as a length the
// copy would then trust.
test "a UTF-8 sequence is measured, or refused" {
    const cases = .{
        .{ "\x80", 0 },
        .{ "\xbf", 0 },
        .{ "\xc2", 0 },
        .{ "\xc2\x9b", 2 },
        .{ "\xe6\x97", 0 },
        .{ "\xe6\x97\xa5", 3 },
        .{ "\xf0\x9f", 0 },
        .{ "\xf0\x9f\x98", 0 },
        .{ "\xf0\x9f\x98\x80", 4 },
        // A lead byte promising five or six bytes is not a UTF-8 lead byte.
        .{ "\xf8\x88\x80\x80\x80", 0 },
        .{ "\xfc\x84\x80\x80\x80\x80", 0 },
        // Overlong: the same character spelled in more bytes than it needs.
        .{ "\xc0\xaf", 0 },
        .{ "\xe0\x80\xaf", 0 },
        // A surrogate half is not a character.
        .{ "\xed\xa0\x80", 0 },
    };
    inline for (cases) |c| try std.testing.expectEqual(c[1], utf8SequenceLen(c[0], 0));
}

// The usage line is read by name on a bill, so the five counters keep their
// positions: swapping any two of them reports one number under another's name
// and no other test here would notice.
test "the five usage counters are emitted in the order the wire names them" {
    var buf = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer buf.deinit();
    try buf.writer.print(usage_fields, .{ 1, 2, 3, 4, 5 });
    try std.testing.expectEqualStrings(
        "\"prompt_tokens\":1,\"cached_tokens\":2,\"completion_tokens\":3,\"reasoning_tokens\":4,\"total_tokens\":5",
        buf.written(),
    );
}

// The run total is what a session log and a status line report. A provider
// number beyond u64 saturates on the way in, and adding it to a total already
// near the ceiling must saturate too: a plain `+` would wrap to a small number
// and report a run that spent almost nothing.
test "a run total saturates instead of wrapping" {
    // Each counter in turn is taken to the ceiling and added ten more, because
    // a plain `+` on any one of them wraps to a small number and reports a run
    // that spent almost nothing. The four left alone have to come out as an
    // ordinary sum, so a saturating add that clamped every field fails here
    // rather than passing.
    const start = [5]u64{ 1, 10, 20, 30, 40 };
    const near = std.math.maxInt(u64) - 1;
    for (0..start.len) |over| {
        var before = start;
        before[over] = near;
        var usage: Usage = .{
            .prompt = before[0],
            .cached = before[1],
            .completion = before[2],
            .reasoning = before[3],
            .total = before[4],
        };
        var result: ChatResult = .{};
        switch (over) {
            0 => result.prompt_tokens = 10,
            1 => result.cached_tokens = 10,
            2 => result.completion_tokens = 10,
            3 => result.reasoning_tokens = 10,
            4 => result.total_tokens = 10,
            else => unreachable,
        }
        usage.add(&result);
        const got = [5]u64{ usage.prompt, usage.cached, usage.completion, usage.reasoning, usage.total };
        for (got, before) |value, was| {
            const expected: u64 = if (was == near) std.math.maxInt(u64) else was;
            try std.testing.expectEqual(expected, value);
        }
    }
}
