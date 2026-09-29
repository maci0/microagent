//! Provider stream frames: the shapes a completion stream's `data:` payloads take, and the
//! folding of each one into the response a turn is built from, under the response and
//! tool-call ceilings. The network read loop that feeds it lives in `main.zig`.

const std = @import("std");

const chat_mod = @import("chat.zig");
const net = @import("net.zig");

/// Parallel tool calls accepted from one response; higher indices are dropped.
pub const max_tool_calls = 64;

/// Ceiling on what one response may add to the run: visible text, and the
/// arguments of its tool calls streamed in fragments. A provider that never
/// sends `[DONE]` would otherwise grow the run's memory for as long as it keeps
/// sending, and the caller chose the base url, not the server on the other end
/// of it. Well past any real completion. The argument half is one budget for
/// the whole response, not one per call: `max_tool_calls` calls at the ceiling
/// each is a gigabyte the run never asked for. A turn that reaches it is
/// reported on stderr, because the bytes past it are dropped rather than held.
pub const max_response_bytes = 16 * 1024 * 1024;

/// Why a stream that ended without `[DONE]` is not a finished turn, in the
/// words the operator reads. Null once the terminator has arrived, whatever the
/// turn holds. Separated from the stream loop so the rule is testable without
/// a provider on the other end of a socket.
pub fn truncatedNotice(
    arena: std.mem.Allocator,
    url: []const u8,
    done: bool,
    content_len: usize,
    calls_len: usize,
) ?[]const u8 {
    if (done) return null;
    return std.fmt.allocPrint(
        arena,
        "microagent: the completion stream from {s} ended without [DONE] after {d} byte(s) of " ++
            "content and {d} tool call(s); the turn is not complete",
        .{ url, content_len, calls_len },
    ) catch "microagent: the completion stream ended without [DONE]; the turn is not complete";
}

/// What the filter below took out of one response, so the caller can say which
/// of the two reasons applied rather than reporting one number for both.
const DroppedCalls = struct {
    /// A call the run cannot carry: no id, no name, or arguments that are not a
    /// JSON object. The caller names this count, because a call that vanished is
    /// a call the operator watching the run cannot otherwise account for.
    unusable: usize = 0,
    /// A call carrying an id the response already delivered under another index.
    duplicate: usize = 0,
};

/// Why a response's tool calls were not all dispatched, in the words the
/// operator reads. Null when every call the stream carried can be run.
///
/// The count is what a reader needs: the turn still completes and the model is
/// asked again, so a run that dropped a call and said nothing is a run whose
/// work is smaller than the work it asked for, with nothing on the screen to
/// connect the two. Both reasons are on one line rather than two because they
/// are the same fact about the same turn, and a turn that lost calls to each of
/// them is one line that names both.
pub fn droppedCallNotice(arena: std.mem.Allocator, url: []const u8, dropped: DroppedCalls, over_cap: usize) ?[]const u8 {
    if (dropped.unusable == 0 and over_cap == 0) return null;
    if (dropped.unusable == 0) return std.fmt.allocPrint(arena, "microagent: the completion stream from {s} asked for {d} tool call(s) past the {d} this run dispatches at once; they are not dispatched, and the model is asked again without them", .{
        url, over_cap, max_tool_calls,
    }) catch "microagent: some tool calls from the completion stream were past the parallel-call ceiling; they are not dispatched";
    if (over_cap == 0) return std.fmt.allocPrint(arena, "microagent: {d} tool call(s) from {s} carried no id or no name, or arguments that are not a JSON object; they are not dispatched, and the model is asked again without them", .{
        dropped.unusable, url,
    }) catch "microagent: some tool calls from the completion stream could not be dispatched; the model is asked again without them";
    return std.fmt.allocPrint(arena, "microagent: {d} tool call(s) from {s} could not be dispatched ({d} carried no id or no name, or arguments that are not a JSON object; {d} were past the {d} this run dispatches at once); the model is asked again without them", .{
        dropped.unusable + over_cap, url, dropped.unusable, over_cap, max_tool_calls,
    }) catch "microagent: some tool calls from the completion stream could not be dispatched; the model is asked again without them";
}

/// A provider that skips a tool-call index leaves an empty slot where `applyFrame`
/// sized the list by index, and a response cut at `max_tokens` or at the turn's
/// byte ceiling leaves a call whose arguments stop mid-object, and a stream whose
/// id never arrived leaves a call the tool results cannot be paired to. None is a
/// call the run can carry, and each goes back to the provider inside the assistant
/// message: a `tool_calls` entry with no `id`, a function with no name, or
/// `arguments` that are not a JSON object, and the next request is rejected with a
/// 400 that ends the run. They are dropped here instead, so a truncated turn
/// costs that turn and not the rest of the run. The ceiling notice above has
/// already said the arguments were cut.
///
/// A second call carrying an id the response already carried is dropped for the
/// other reason. The stream is the transport this program does not control: a
/// relay that reconnects replays from the last event it saw, a proxy that retries
/// a chunk re-sends it, and a provider that restarts a call after a dropped
/// connection delivers it again under the next index. Every such delivery is
/// at-least-once, and the id is the only thing in it that says the call is one
/// the run has already got. Dispatching both runs the tool twice over the same
/// arguments, which for `bash` is the command twice and for `write` and `edit` a
/// second pass over a file the first pass already changed. The first is kept, so
/// the assistant message names each call once and the tool results still pair
/// one to one, which is what the next request needs anyway.
///
/// Two calls with the same id and the same index are not this case: they are one
/// call whose fragments arrived twice, which `applyCallDelta` folds into the one
/// slot that index names. What lands here is the same id under two indexes.
///
/// Returns what it took out, one reason at a time: a call the run cannot carry
/// outright, and a second delivery of one it already has.
pub fn keepRunnableCalls(gpa: std.mem.Allocator, calls: *std.ArrayList(chat_mod.ToolCall)) DroppedCalls {
    var dropped: DroppedCalls = .{};
    var kept: usize = 0;
    for (calls.items) |*call| {
        const usable = call.id.len != 0 and call.name.len != 0 and
            argumentsAreAnObject(gpa, call.args.items);
        if (usable and indexOfCallId(calls.items[0..kept], call.id) == null) {
            calls.items[kept] = call.*;
            kept += 1;
            continue;
        }
        if (usable) dropped.duplicate += 1 else dropped.unusable += 1;
        if (call.id.len != 0) gpa.free(call.id);
        if (call.name.len != 0) gpa.free(call.name);
        call.args.deinit(gpa);
    }
    calls.shrinkRetainingCapacity(kept);
    return dropped;
}

fn indexOfCallId(calls: []const chat_mod.ToolCall, id: []const u8) ?usize {
    for (calls, 0..) |call, i| {
        if (std.mem.eql(u8, call.id, id)) return i;
    }
    return null;
}

/// Whether a call's streamed arguments are an object, which is the only thing
/// the OpenAI-shaped completions API accepts in `arguments` and the only thing
/// `runTool` dispatches. A stream that was cut mid-argument is a prefix such as
/// `{"command": "ls -`, and sending it on turns every later request into a 400.
fn argumentsAreAnObject(gpa: std.mem.Allocator, args: []const u8) bool {
    const trimmed = std.mem.trim(u8, args, " \t\r\n");
    if (trimmed.len == 0 or trimmed[0] != '{') return false;
    return std.json.validate(gpa, trimmed) catch false;
}

/// The frame shapes `applyFrame` reads, declared so the common frame parses
/// without building a `std.json.Value` tree.
///
/// A stream sends one frame per token, and the tree measured ~7,200 retired
/// instructions a frame against ~4,100 for this. Every field the generic path
/// reads is named here, all three cached-token spellings included, and the
/// counters stay `Value` so `chat_mod.num` reads them exactly as it did before.
const StreamFrame = struct {
    usage: ?UsageFrame = null,
    choices: []const Choice = &.{},
    // What the provider says answered. Absent on a frame that omits them, which
    // is the rule `recordServed` follows: an earlier frame's value
    // stands rather than a later frame's absence emptying the field.
    model: ?[]const u8 = null,
    system_fingerprint: ?[]const u8 = null,

    const Choice = struct {
        // Read as a Value so a reason that is not a string leaves the last one
        // standing here, exactly as `chat_mod.str` leaves it on the generic path,
        // rather than failing the parse and taking the slow one.
        finish_reason: std.json.Value = .null,
        delta: ?Delta = null,
    };
    const Delta = struct {
        content: ?[]const u8 = null,
        tool_calls: ?[]const CallDelta = null,
    };
    const CallDelta = struct {
        index: std.json.Value = .null,
        id: ?[]const u8 = null,
        function: ?CallFunction = null,
    };
    const CallFunction = struct {
        name: ?[]const u8 = null,
        arguments: ?[]const u8 = null,
    };
    const UsageFrame = struct {
        prompt_tokens: std.json.Value = .null,
        completion_tokens: std.json.Value = .null,
        total_tokens: std.json.Value = .null,
        prompt_cache_hit_tokens: std.json.Value = .null,
        cache_read_input_tokens: std.json.Value = .null,
        completion_tokens_details: ?Details = null,
        prompt_tokens_details: ?Details = null,
        const Details = struct {
            reasoning_tokens: std.json.Value = .null,
            cached_tokens: std.json.Value = .null,
        };
    };
};

/// Why the provider stopped, on the last frame that carries it. `length` means
/// the response was cut at `max_tokens`; the caller says so rather than
/// appending a prefix of an answer as if it were the whole one.
///
/// Both parse paths land it before the delta, because a frame may carry the
/// reason with no delta beside it.
///
/// A gateway repeats the reason on every chunk, and the field is owned, so
/// copying it unconditionally is a dupe and a free per frame to hold bytes that
/// did not move. `keepChanged` is the same rule `recordServed` follows for the
/// two fields above it.
fn applyFinishReason(gpa: std.mem.Allocator, result: *chat_mod.ChatResult, value: ?std.json.Value) !void {
    try chat_mod.keepChanged(gpa, &result.finish_reason, chat_mod.str(value));
}

/// The member a provider reports a mid-stream failure in, spelled as the bytes
/// that key arrives as.
const error_member = "\"error\":";

/// Whether a frame carries a report of a failure rather than a chunk.
///
/// This is a byte test and it is exact. A model that writes `{"error": ...}`
/// into its own answer has it escaped, so the bytes that spell a key never
/// appear inside a string, and the only other way to reach them is a member of
/// the frame itself. `"error":null` is not a report of anything, and a gateway
/// that sends it on every chunk would otherwise put every chunk on the slow
/// parse for no gain.
///
/// The declared shapes have no field for a member named `error`, since a struct
/// field cannot be spelled that one, so a frame that reports a failure is read
/// by the generic parse instead. That is where a frame that is nothing but a
/// failure report lands anyway, and the shapes would have found nothing in it.
fn reportsError(payload: []const u8) bool {
    const pos = std.mem.indexOf(u8, payload, error_member) orelse return false;
    const value = std.mem.trim(u8, payload[pos + error_member.len ..], " \t");
    return !std.mem.startsWith(u8, value, "null");
}

/// What a frame said went wrong, as the one line a note carries: the code the
/// provider gave and the message under it, or whichever of the two it sent, and
/// a placeholder for a frame that reported a failure and named no reason. The
/// first report is the one kept: a provider that reports the same failure in
/// every frame after it says it once, and the first is the cause.
///
/// The bytes are the provider's, so they are copied into this run rather than
/// read out of the frame's own arena, and the caller prints them through the
/// same escaping as any other provider text.
fn noteStreamError(gpa: std.mem.Allocator, result: *chat_mod.ChatResult, value: ?std.json.Value) !void {
    const v = value orelse return;
    if (result.stream_error.len != 0) return;
    var code: ?[]const u8 = null;
    var message: ?[]const u8 = null;
    if (v == .object) {
        code = chat_mod.str(v.object.get("code"));
        message = chat_mod.str(v.object.get("message"));
    } else if (chat_mod.str(v)) |text| {
        // Some gateways send the failure as the member's own value rather than
        // as an object under it.
        message = text;
    }
    const text: []const u8 = message orelse code orelse "the provider reported an error and named no reason";
    result.stream_error = if (message != null and code != null)
        try std.fmt.allocPrint(gpa, "{s}: {s}", .{ code.?, message.? })
    else
        try chat_mod.ownString(gpa, text);
}

/// Folds one frame through the declared shapes. False means the frame did not
/// fit them and nothing was applied, so the caller parses it the long way.
fn applyDeclared(
    scratch: std.mem.Allocator,
    gpa: std.mem.Allocator,
    payload: []const u8,
    result: *chat_mod.ChatResult,
    calls: *std.ArrayList(chat_mod.ToolCall),
    out_buf: *std.ArrayList(u8),
    unparsable: *usize,
) !bool {
    // A frame the shapes cannot hold is the slow path's job. An allocation that
    // failed is not a frame that would not parse, so it is not answered with
    // "that is not JSON": the run cannot pay for another parse, and the two
    // failures leave the run in very different states. Leaky, because the
    // caller resets `scratch` after every frame: the arena `parseFromSlice`
    // wraps around it was one more allocator per frame and nothing freed it.
    const frame = std.json.parseFromSliceLeaky(StreamFrame, scratch, payload, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };

    try chat_mod.recordServed(gpa, result, frame.model, frame.system_fingerprint);

    if (frame.usage) |u| {
        applyUsage(result, .{
            .prompt = u.prompt_tokens,
            .completion = u.completion_tokens,
            .total = u.total_tokens,
            .reasoning = if (u.completion_tokens_details) |d| d.reasoning_tokens else null,
            .cached = if (u.prompt_tokens_details) |d| d.cached_tokens else null,
            .cache_hit = u.prompt_cache_hit_tokens,
            .cache_read = u.cache_read_input_tokens,
        }, unparsable);
    }
    if (frame.choices.len == 0) return true;
    const choice = frame.choices[0];
    try applyFinishReason(gpa, result, choice.finish_reason);
    const delta = choice.delta orelse return true;

    if (delta.content) |text| try appendStreamed(gpa, text, result, out_buf);
    if (delta.tool_calls) |tcs| {
        for (tcs) |tc| {
            const f = tc.function;
            const name = if (f) |v| v.name else null;
            const args = if (f) |v| v.arguments else null;
            try applyCallDelta(gpa, tc.index, tc.id, name, args, result, calls);
        }
    }
    return true;
}

/// One frame's usage block, read the same way whichever parse produced it. A
/// counter a frame did not carry stays absent, so a later frame that omits it
/// leaves the count an earlier one set rather than reading as zero tokens.
const UsageFields = struct {
    prompt: ?std.json.Value = null,
    completion: ?std.json.Value = null,
    total: ?std.json.Value = null,
    reasoning: ?std.json.Value = null,
    cached: ?std.json.Value = null,
    cache_hit: ?std.json.Value = null,
    cache_read: ?std.json.Value = null,
};

// The seven counters above are spelled out once per parse: `applyDeclared`
// reads them off `StreamFrame.UsageFrame`, `applyFrame` off the generic parse.
// A spelling added to one and not the other is a counter a provider's own
// field is counted under on the fast path and not on the slow one, and a frame
// only takes the slow path when the fast one refused it wholesale, so no
// existing test sees both spellings of the same frame.
test "the declared and generic parses count usage the same way" {
    const gpa = std.testing.allocator;
    var state = std.heap.ArenaAllocator.init(gpa);
    defer state.deinit();
    const arena = state.allocator();

    const Counters = struct {
        prompt: u64,
        completion: u64,
        total: u64,
        reasoning: u64,
        cached: u64,
    };
    const counters = struct {
        fn of(result: *const chat_mod.ChatResult) Counters {
            return .{
                .prompt = result.prompt_tokens,
                .completion = result.completion_tokens,
                .total = result.total_tokens,
                .reasoning = result.reasoning_tokens,
                .cached = result.cached_tokens,
            };
        }
    }.of;

    // Every spelling of a cached count the three providers send, so the one
    // field with three names is the one under test.
    const usages = [_][]const u8{
        \\{"prompt_tokens":11,"completion_tokens":22,"total_tokens":33,"completion_tokens_details":{"reasoning_tokens":44},"prompt_tokens_details":{"cached_tokens":55}}
        ,
        \\{"prompt_tokens":11,"completion_tokens":22,"prompt_cache_hit_tokens":66}
        ,
        \\{"prompt_tokens":11,"completion_tokens":22,"cache_read_input_tokens":77}
        ,
        // A total of 0 is not a total the provider stands behind, so the sum
        // of the parts stands in for it on both paths.
        \\{"prompt_tokens":11,"completion_tokens":22,"total_tokens":0}
        ,
    };

    for (usages) |usage| {
        var results: [2]chat_mod.ChatResult = .{ .{}, .{} };
        // `choices` spelled as something the declared shapes refuse is what
        // sends the second frame down the generic parse; the usage block
        // beside it is the same object both paths read.
        var declared_buf: [512]u8 = undefined;
        var generic_buf: [512]u8 = undefined;
        const declared = try std.fmt.bufPrint(&declared_buf, "{{\"usage\":{s},\"choices\":[]}}", .{usage});
        const generic = try std.fmt.bufPrint(&generic_buf, "{{\"usage\":{s},\"choices\":\"none\"}}", .{usage});
        for ([_][]const u8{ declared, generic }, 0..) |payload, which| {
            var calls: std.ArrayList(chat_mod.ToolCall) = .empty;
            defer chat_mod.deinitCalls(gpa, &calls);
            var out_buf: std.ArrayList(u8) = .empty;
            defer out_buf.deinit(gpa);
            var unparsable: usize = 0;
            try applyFrame(arena, arena, payload, &results[which], &calls, &out_buf, &unparsable);
            try std.testing.expectEqual(@as(usize, 0), unparsable);
        }
        try std.testing.expectEqual(counters(&results[0]), counters(&results[1]));
    }
}

/// Folds one frame's usage block into the run's counters. Cached prompt tokens
/// arrive in the three spellings providers actually send: the OpenAI and
/// OpenRouter one, DeepSeek's native one, and Anthropic's.
///
/// A provider that sends no total has it summed from the parts, because a
/// reader that divides tokens by elapsed time reads a missing field as a run
/// that cost nothing. The same reason keeps a frame that carries one counter
/// from reading as a run of zero for the rest: a stream that spreads its usage
/// over several frames, or spells a total in one and the parts in another, is
/// folded counter by counter rather than replaced field by field.
///
/// A counter the frame spelled as a string and that is not a number is counted
/// in `unparsable` and left where it was, rather than folded in as a zero: the
/// count the run then reports is the one the provider really sent, and the
/// frames whose counters it could not read are named on stderr.
fn applyUsage(result: *chat_mod.ChatResult, u: UsageFields, unparsable: *usize) void {
    if (chat_mod.maybeNum(u.prompt, unparsable)) |v| result.prompt_tokens = v;
    if (chat_mod.maybeNum(u.completion, unparsable)) |v| result.completion_tokens = v;
    if (chat_mod.maybeNum(u.total, unparsable)) |v| {
        result.total_tokens = v;
        // A zero is not a total the provider stands behind: it is the field
        // left where it started, and the sum below is what stands in for it.
        if (v != 0) result.total_from_provider = true;
    }
    if (chat_mod.maybeNum(u.reasoning, unparsable)) |v| result.reasoning_tokens = v;
    // The three spellings are ranked within the frame, not against the folded
    // total, so a frame carrying none of them leaves what the earlier frames
    // billed. A zero is the field left where it started rather than a count
    // the provider stands behind, the same reason a zero total is summed from
    // the parts above: a stream that spreads its usage over frames and closes
    // with the counter at its default reported no cached prompt for a run the
    // provider served out of its cache.
    var frame_cached: ?u64 = null;
    for ([_]?std.json.Value{ u.cached, u.cache_hit, u.cache_read }) |spelling| {
        if (frame_cached != null) break;
        if (chat_mod.maybeNum(spelling, unparsable)) |v| {
            if (v != 0) frame_cached = v;
        }
    }
    if (frame_cached) |v| result.cached_tokens = v;
    // A provider that has sent no total of its own gets the sum of the parts
    // recomputed on every frame, so a stream that splits the parts across
    // frames reports what all of them add up to rather than the first frame's
    // half of it.
    if (!result.total_from_provider)
        result.total_tokens = result.prompt_tokens +| result.completion_tokens;
}

/// The one response cap, applied to whichever stream a fragment arrived on.
/// `max_response_bytes` bounds a whole response rather than each stream in it,
/// so the answer text and every call's arguments share one budget; two copies
/// of this arithmetic is two places for the ceiling to be read at half of.
fn clampToResponseCap(result: *chat_mod.ChatResult, text: []const u8) []const u8 {
    const kept = chat_mod.clamp(text, max_response_bytes -| result.streamed);
    if (kept.len != text.len) result.dropped = true;
    result.streamed += kept.len;
    return kept;
}

/// Appends streamed answer text to the result and to the buffer the caller
/// prints, under the one response cap.
fn appendStreamed(
    gpa: std.mem.Allocator,
    text: []const u8,
    result: *chat_mod.ChatResult,
    out_buf: *std.ArrayList(u8),
) !void {
    const kept = clampToResponseCap(result, text);
    try result.content.appendSlice(gpa, kept);
    try out_buf.appendSlice(gpa, kept);
}

/// Folds one streamed fragment of a tool call into `calls`, growing it to the
/// fragment's index. `index` is read as a Value, so an index a frame spelled
/// unusually is read as a count rather than failing the parse and taking the
/// whole frame down the generic path.
fn applyCallDelta(
    gpa: std.mem.Allocator,
    index: std.json.Value,
    id: ?[]const u8,
    name: ?[]const u8,
    args: ?[]const u8,
    result: *chat_mod.ChatResult,
    calls: *std.ArrayList(chat_mod.ToolCall),
) !void {
    // `numCount` clamps rather than casting: a provider index beyond what a
    // `usize` holds saturates, so the cap below sees it and drops the call
    // instead of the cast trapping or wrapping. The index sizes `calls`, so it
    // is capped before it can ask for billions of empty slots. The cap is
    // counted rather than applied quietly: a response asking for more parallel
    // calls than the run dispatches has the rest dropped, and the assistant
    // message the provider reads next names only the ones that were kept, so
    // the count is what says what happened to them.
    const idx = chat_mod.numCount(index);
    if (idx >= max_tool_calls) {
        // Counted per call rather than per fragment: a provider streams one
        // call as an id and a name, then as many argument fragments as the
        // arguments need, every one of them repeating this index. Counting each
        // of those as a call is what made a single long-argument call past the
        // ceiling read as a response asking for dozens of parallel calls.
        if (result.over_cap_index == null or result.over_cap_index.? != idx) {
            result.over_cap += 1;
            result.over_cap_index = idx;
        }
        return;
    }
    while (calls.items.len <= idx) try calls.append(gpa, .{ .id = "", .name = "" });
    const call = &calls.items[idx];
    // A provider may resend the id or the name on a later fragment, so the
    // previous copy is released rather than left behind. A slot this frame's
    // index walk filled holds the placeholder rather than a copy, and the
    // placeholder is not the allocator's to hand back. An id or name the
    // provider emptied is the shared empty slice, so releasing the previous
    // copy is the whole of what that frame has to do.
    //
    // A value that did not change is not copied at all, for the reason
    // `chat.recordServed` gives: a provider repeats the id and the name on
    // every fragment of the arguments that follow them, so a stream that
    // announces a call once and then streams a few thousand bytes of arguments
    // arrives here with the same two strings a few thousand times. Copying each
    // one to hold bytes that did not move is a `dupe` and a `free` per frame
    // on the run's hottest path, and the id is the very thing the duplicate
    // check below reads to tell a redelivery from a fragment.
    if (id) |v| if (!std.mem.eql(u8, call.id, v)) {
        const owned = try chat_mod.ownString(gpa, v);
        if (call.id.len != 0) gpa.free(call.id);
        call.id = owned;
    };
    if (name) |v| if (!std.mem.eql(u8, call.name, v)) {
        const owned = try chat_mod.ownString(gpa, v);
        if (call.name.len != 0) gpa.free(call.name);
        call.name = owned;
    };
    if (args) |v| {
        const piece = clampToResponseCap(result, v);
        // A relay that reconnects replays the frames it already sent, so one
        // slot can be announced twice: the second delivery repeats the id and
        // the name and carries the whole argument string again, and appending
        // it to the first delivery's leaves two objects glued together, which
        // is not an object, so the call is dropped as unreadable and the work
        // it asked for is never done. The id is what tells the two apart: a
        // continuation of a call never re-announces it, so a frame carrying
        // the id and an argument string that is an object on its own is a
        // delivery rather than a fragment, and it is the whole of what the
        // slot holds.
        if (id != null and id.?.len != 0 and
            call.args.items.len > 0 and argumentsAreAnObject(gpa, piece))
        {
            call.args.clearRetainingCapacity();
        }
        try call.args.appendSlice(gpa, piece);
    }
}

/// Folds one SSE payload into the response being built.
///
/// `scratch` is reset by the caller after every frame, so nothing parsed out of
/// it may survive: strings that do are copied into `gpa`, which lives as long
/// as the response they belong to.
///
/// `unparsable` counts the frames that were not JSON, and the token counts
/// inside the frames that were. A frame the parser cannot read holds content
/// and tool-call arguments the turn will not have, and a count it cannot read
/// is a number this run did not bill, so both are counted and the caller says
/// so; dropping either without a count leaves a response that is short and a
/// bill that looks complete.
pub fn applyFrame(
    scratch: std.mem.Allocator,
    gpa: std.mem.Allocator,
    payload: []const u8,
    result: *chat_mod.ChatResult,
    calls: *std.ArrayList(chat_mod.ToolCall),
    out_buf: *std.ArrayList(u8),
    unparsable: *usize,
) !void {
    // The declared shapes cover every frame a provider sends in practice. The
    // generic parse behind them still runs for anything that does not fit, so
    // this is a speedup and not a narrowing of what is accepted. A frame that
    // reports a failure never takes it: the shapes have no member for an `error`
    // to land in, because a struct field cannot be spelled that one.
    if (!reportsError(payload) and try applyDeclared(scratch, gpa, payload, result, calls, out_buf, unparsable)) return;

    const root = std.json.parseFromSliceLeaky(std.json.Value, scratch, payload, .{}) catch |err| switch (err) {
        // Counted as unreadable only when it really was: a frame that would not
        // parse is the provider's, and an allocation that failed is this
        // machine's, and telling the operator to look at the provider for the
        // second one sends them the wrong way.
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            unparsable.* += 1;
            return;
        },
    };
    if (root != .object) {
        unparsable.* += 1;
        return;
    }

    try chat_mod.recordServed(gpa, result, chat_mod.str(root.object.get("model")), chat_mod.str(root.object.get("system_fingerprint")));
    try noteStreamError(gpa, result, root.object.get("error"));

    if (root.object.get("usage")) |u| if (u == .object) {
        var reasoning: ?std.json.Value = null;
        var cached: ?std.json.Value = null;
        if (u.object.get("completion_tokens_details")) |d| {
            if (d == .object) reasoning = d.object.get("reasoning_tokens");
        }
        if (u.object.get("prompt_tokens_details")) |d| {
            if (d == .object) cached = d.object.get("cached_tokens");
        }
        applyUsage(result, .{
            .prompt = u.object.get("prompt_tokens"),
            .completion = u.object.get("completion_tokens"),
            .total = u.object.get("total_tokens"),
            .reasoning = reasoning,
            .cached = cached,
            .cache_hit = u.object.get("prompt_cache_hit_tokens"),
            .cache_read = u.object.get("cache_read_input_tokens"),
        }, unparsable);
    };
    const choices = root.object.get("choices") orelse return;
    if (choices != .array or choices.array.items.len == 0) return;
    const choice = choices.array.items[0];
    if (choice != .object) return;
    try applyFinishReason(gpa, result, choice.object.get("finish_reason"));
    const delta = choice.object.get("delta") orelse return;
    if (delta != .object) return;

    if (chat_mod.str(delta.object.get("content"))) |text| try appendStreamed(gpa, text, result, out_buf);
    if (delta.object.get("tool_calls")) |tcs| if (tcs == .array) {
        for (tcs.array.items) |tc| {
            if (tc != .object) continue;
            var name: ?[]const u8 = null;
            var args: ?[]const u8 = null;
            if (tc.object.get("function")) |f| if (f == .object) {
                name = chat_mod.str(f.object.get("name"));
                args = chat_mod.str(f.object.get("arguments"));
            };
            try applyCallDelta(gpa, tc.object.get("index") orelse .null, chat_mod.str(tc.object.get("id")), name, args, result, calls);
        }
    };
}

/// The three sinks `applyFrame` fills, on the two allocators it parses with:
/// one that lives for the whole test and one released after every frame, the
/// arrangement the stream loop uses.
pub const FrameSink = struct {
    run: std.heap.ArenaAllocator,
    scratch: std.heap.ArenaAllocator,
    result: chat_mod.ChatResult = .{},
    calls: std.ArrayList(chat_mod.ToolCall) = .empty,
    out_buf: std.ArrayList(u8) = .empty,
    unparsable: usize = 0,

    pub fn init(allocator: std.mem.Allocator) FrameSink {
        return .{
            .run = std.heap.ArenaAllocator.init(allocator),
            .scratch = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *FrameSink) void {
        self.scratch.deinit();
        self.run.deinit();
    }

    /// Scratch bytes still held after the last frame fed.
    fn scratchCapacity(self: *FrameSink) usize {
        return self.scratch.queryCapacity();
    }

    pub fn feed(self: *FrameSink, payload: []const u8) !void {
        try applyFrame(self.scratch.allocator(), self.run.allocator(), payload, &self.result, &self.calls, &self.out_buf, &self.unparsable);
        _ = self.scratch.reset(.retain_capacity);
    }
};

test "a long stream costs the largest frame, not the sum of frames" {
    var sink = FrameSink.init(std.testing.allocator);
    defer sink.deinit();

    const payload = "{\"choices\":[{\"delta\":{\"content\":\"tok\"}}]}";
    const frames: usize = 20_000;

    // Reference point: the scratch capacity one frame needs.
    try sink.feed(payload);
    const one_frame_capacity = sink.scratchCapacity();

    var i: usize = 1;
    while (i < frames) : (i += 1) try sink.feed(payload);

    try std.testing.expectEqual(frames * 3, sink.result.content.items.len);
    try std.testing.expectEqual(frames * 3, sink.out_buf.items.len);
    // The work counter this test asserts on: scratch bytes retained after the
    // last frame. It must equal what one frame needed, not grow with the frame
    // count, which is what it did before the per-frame reset (20_000 frames'
    // worth of parse trees were kept alive in the run arena).
    try std.testing.expect(one_frame_capacity > 0);
    try std.testing.expectEqual(one_frame_capacity, sink.scratchCapacity());
}

test "tool call fragments merge by index across frames" {
    var sink = FrameSink.init(std.testing.allocator);
    defer sink.deinit();

    const frames = [_][]const u8{
        "{\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_1\",\"function\":{\"name\":\"read\",\"arguments\":\"{\\\"pa\"}}]}}]}",
        "{\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"th\\\":\\\"a.zig\\\"}\",\"arguments_end\":null}}]}}]}",
    };
    for (frames) |f| try sink.feed(f);

    try std.testing.expectEqual(@as(usize, 1), sink.calls.items.len);
    try std.testing.expectEqualStrings("call_1", sink.calls.items[0].id);
    try std.testing.expectEqualStrings("read", sink.calls.items[0].name);
    try std.testing.expectEqualStrings("{\"path\":\"a.zig\"}", sink.calls.items[0].args.items);
}

// A frame can empty a field an earlier frame filled: a provider that sends a
// finish reason and then `""`, or a call id and name and then blanks. The copy
// behind the first value is released on the way, and the empty one is the shared
// slice rather than a fresh allocation, so the fields a long stream empties
// cost the stream nothing. Fed with the process allocator, this is also the
// test that notices when one of them does: a copy left behind is the run's, and
// `std.testing.allocator` reports it at the end of the test.
test "a frame that empties a field releases the one before it" {
    const gpa = std.testing.allocator;
    var scratch_state = std.heap.ArenaAllocator.init(gpa);
    defer scratch_state.deinit();
    var result: chat_mod.ChatResult = .{};
    defer result.deinit(gpa);
    var calls: std.ArrayList(chat_mod.ToolCall) = .empty;
    defer chat_mod.deinitCalls(gpa, &calls);
    var out_buf: std.ArrayList(u8) = .empty;
    defer out_buf.deinit(gpa);
    var unparsable: usize = 0;

    const frames = [_][]const u8{
        \\{"choices":[{"finish_reason":"stop","delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"read","arguments":"{}"}}]}}]}
        ,
        \\{"choices":[{"finish_reason":"","delta":{"tool_calls":[{"index":0,"id":"","function":{"name":""}}]}}]}
    };
    for (frames) |f| {
        try applyFrame(scratch_state.allocator(), gpa, f, &result, &calls, &out_buf, &unparsable);
        _ = scratch_state.reset(.retain_capacity);
    }

    try std.testing.expectEqual(@as(usize, 0), unparsable);
    try std.testing.expectEqual(@as(usize, 1), calls.items.len);
    try std.testing.expectEqualStrings("", result.finish_reason);
    try std.testing.expectEqualStrings("", calls.items[0].id);
    try std.testing.expectEqualStrings("", calls.items[0].name);
    try std.testing.expectEqualStrings("{}", calls.items[0].args.items);
}

// A provider streams one call's `arguments` as many small fragments. Copying
// the whole accumulated string on every fragment made both the copy count and
// the arena bytes quadratic in the argument length, on the one path that
// cannot be re-sent cheaply. Appending keeps arena growth geometric, so the
// run arena costs a small multiple of the final length rather than a multiple
// of the square of it.
test "streamed argument fragments cost linear arena bytes" {
    const gpa = std.testing.allocator;
    var run_state = std.heap.ArenaAllocator.init(gpa);
    defer run_state.deinit();
    var frame_state = std.heap.ArenaAllocator.init(gpa);
    defer frame_state.deinit();

    var result: chat_mod.ChatResult = .{};
    var calls: std.ArrayList(chat_mod.ToolCall) = .empty;
    var out_buf: std.ArrayList(u8) = .empty;
    var unparsable: usize = 0;

    const fragments: usize = 2000;
    var i: usize = 0;
    while (i < fragments) : (i += 1) {
        const frame = try std.mem.concat(
            frame_state.allocator(),
            u8,
            &.{ "{\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"", "0123456789abcdef", "\"}}]}}]}" },
        );
        try applyFrame(frame_state.allocator(), run_state.allocator(), frame, &result, &calls, &out_buf, &unparsable);
        _ = frame_state.reset(.retain_capacity);
    }
    try std.testing.expectEqual(@as(usize, 0), unparsable);

    const total = fragments * 16;
    try std.testing.expectEqual(total, calls.items[0].args.items.len);
    // Geometric growth retains at most about twice the final length; the
    // per-frame re-copy retained a multiple of the square of it.
    try std.testing.expect(run_state.queryCapacity() < 4 * total);
}

// A provider that repeats a call's `id` and `name` on every argument fragment
// arrives here once per frame with two strings that did not change. Copying
// each was a `dupe` and a `free` per fragment, on the path that cannot be
// re-sent cheaply, and it is the id the duplicate-delivery check below reads
// to tell a redelivery from a fragment. An unchanged value is left alone, so
// the run arena pays for the id and the name once rather than once a fragment.
test "a repeated call id and name are copied once, not once a fragment" {
    const gpa = std.testing.allocator;
    var run_state = std.heap.ArenaAllocator.init(gpa);
    defer run_state.deinit();
    const arena = run_state.allocator();

    var result: chat_mod.ChatResult = .{};
    var calls: std.ArrayList(chat_mod.ToolCall) = .empty;
    defer chat_mod.deinitCalls(arena, &calls);

    try applyCallDelta(arena, .{ .integer = 0 }, "call_1", "read", "", &result, &calls);
    try std.testing.expectEqualStrings("call_1", calls.items[0].id);
    try std.testing.expectEqualStrings("read", calls.items[0].name);
    const after_first = run_state.queryCapacity();

    const fragments: usize = 500;
    var i: usize = 0;
    while (i < fragments) : (i += 1) {
        try applyCallDelta(arena, .{ .integer = 0 }, "call_1", "read", "{\"pa", &result, &calls);
    }

    // The values are the same strings, held in the same buffers: nothing about
    // the call changed, so the run arena grew by the argument fragments alone.
    try std.testing.expectEqualStrings("call_1", calls.items[0].id);
    try std.testing.expectEqualStrings("read", calls.items[0].name);
    try std.testing.expectEqual(fragments * 4, calls.items[0].args.items.len);
    const growth = run_state.queryCapacity() - after_first;
    // Geometric growth over `fragments * 4` argument bytes, with nothing else
    // allocated per frame. Copying the id and the name every time would add
    // roughly `fragments * (7 + 4)` bytes of freed-then-reallocated space on
    // top, and the freed blocks are the ones the arena cannot hand back.
    try std.testing.expect(growth < 8 * fragments * 4);
}

// The guard above is a skip on an unchanged value, and the case it must not
// skip is a value that did change: a second call announced into the same slot
// replaces the first one's id and name, and the first copy is handed back
// rather than left behind.
test "a changed call id replaces the one it follows" {
    const gpa = std.testing.allocator;
    var run_state = std.heap.ArenaAllocator.init(gpa);
    defer run_state.deinit();
    const arena = run_state.allocator();

    var result: chat_mod.ChatResult = .{};
    var calls: std.ArrayList(chat_mod.ToolCall) = .empty;
    defer chat_mod.deinitCalls(arena, &calls);

    try applyCallDelta(arena, .{ .integer = 0 }, "call_1", "read", "", &result, &calls);
    try applyCallDelta(arena, .{ .integer = 0 }, "call_2", "write", "", &result, &calls);
    try std.testing.expectEqualStrings("call_2", calls.items[0].id);
    try std.testing.expectEqualStrings("write", calls.items[0].name);
}

test "a response that never stops sending cannot grow the run without bound" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const gpa = state.allocator();

    var result: chat_mod.ChatResult = .{};
    var full: std.ArrayList(u8) = .empty;
    try full.appendNTimes(gpa, 'x', max_response_bytes);
    result.content = full;
    // The response has already spent its allowance, which is what a full
    // content buffer means: the counter and the bytes are one state, not two.
    result.streamed = max_response_bytes;
    var calls: std.ArrayList(chat_mod.ToolCall) = .empty;
    var out_buf: std.ArrayList(u8) = .empty;
    var unparsable: usize = 0;

    const payload = "{\"choices\":[{\"delta\":{\"content\":\"more\",\"tool_calls\":[{\"index\":0,\"function\":{\"name\":\"bash\",\"arguments\":\"{}\"}}]}}]}";
    try applyFrame(gpa, gpa, payload, &result, &calls, &out_buf, &unparsable);
    try std.testing.expectEqual(max_response_bytes, result.content.items.len);
    try std.testing.expectEqual(@as(usize, 0), out_buf.items.len);
    try std.testing.expectEqualStrings("bash", calls.items[0].name);
    // The response has nothing left for arguments, so the call the provider
    // named arrives without them rather than on top of a full allowance.
    try std.testing.expectEqual(@as(usize, 0), calls.items[0].args.items.len);
    try std.testing.expectEqual(max_response_bytes, result.streamed);
}

// The ceiling is on the response, not on each of the streams in it. A provider
// that spends the whole allowance on one call's arguments must not be able to
// spend it again on the next of the `max_tool_calls` calls, which is a gigabyte
// held for a single turn.
test "the response ceiling covers the calls as well as the text" {
    var sink = FrameSink.init(std.testing.allocator);
    defer sink.deinit();

    // Text that takes the response to the ceiling, then a tool call whose
    // arguments arrive after it.
    sink.result.streamed = max_response_bytes - "kept".len;
    try sink.feed("{\"choices\":[{\"delta\":{\"content\":\"kept\"}}]}");
    try std.testing.expectEqualStrings("kept", sink.result.content.items);
    try std.testing.expectEqual(max_response_bytes, sink.result.streamed);

    // What arrived after the ceiling is dropped, and the frame's other fields
    // still land: the model is told the call was made, not that it was not.
    try sink.feed("{\"choices\":[{\"delta\":{\"content\":\"dropped\"}}]}");
    try std.testing.expectEqualStrings("kept", sink.result.content.items);
    try std.testing.expectEqual(max_response_bytes, sink.result.streamed);

    try sink.feed("{\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"name\":\"bash\",\"arguments\":\"xxxxxxxx\"}}]}}]}");
    try std.testing.expectEqual(@as(usize, 1), sink.calls.items.len);
    try std.testing.expectEqualStrings("bash", sink.calls.items[0].name);
    try std.testing.expectEqual(@as(usize, 0), sink.calls.items[0].args.items.len);
    try std.testing.expectEqual(max_response_bytes, sink.result.streamed);
}

// The ceiling is counted in bytes and cut on a codepoint boundary, so the two
// do not have to agree about where the turn ends: a response that arrives with
// a byte or two of room and a character too wide for it keeps none of it, and
// the counter stops short of the ceiling by that residue rather than reaching
// it. The run's notice reads `dropped` for this reason, because a turn whose
// answer lost its last character and never reached the number is as incomplete
// as one that was cut mid-character at it, and reporting it as whole is how a
// truncated answer gets read as the whole of what the model said.
test "a turn that cannot fit the last character still says the turn is short" {
    var sink = FrameSink.init(std.testing.allocator);
    defer sink.deinit();

    // Two bytes of room, and a three-byte character to add. Nothing fits, so
    // nothing is appended, and `streamed` stays where it was.
    sink.result.streamed = max_response_bytes - 2;
    try sink.feed("{\"choices\":[{\"delta\":{\"content\":\"\u{65e5}\"}}]}");
    try std.testing.expectEqualStrings("", sink.result.content.items);
    try std.testing.expectEqual(max_response_bytes - 2, sink.result.streamed);
    try std.testing.expect(sink.result.dropped);

    // An ASCII character of the same width does fit, which is what makes the
    // residue the only thing that decides the turn's end.
    var roomy = FrameSink.init(std.testing.allocator);
    defer roomy.deinit();
    roomy.result.streamed = max_response_bytes - 2;
    try roomy.feed("{\"choices\":[{\"delta\":{\"content\":\"ab\"}}]}");
    try std.testing.expectEqualStrings("ab", roomy.result.content.items);
    try std.testing.expectEqual(max_response_bytes, roomy.result.streamed);
    try std.testing.expect(!roomy.result.dropped);

    // The same residue on a tool call's arguments, where the call arrives whole
    // but its arguments do not, and cannot be dispatched next turn.
    var call = FrameSink.init(std.testing.allocator);
    defer call.deinit();
    call.result.streamed = max_response_bytes - 1;
    try call.feed("{\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"name\":\"bash\",\"arguments\":\"\u{65e5}\"}}]}}]}");
    try std.testing.expectEqualStrings("bash", call.calls.items[0].name);
    try std.testing.expectEqual(@as(usize, 0), call.calls.items[0].args.items.len);
    try std.testing.expect(call.result.dropped);
}

// The ceiling is a limit on what a turn holds, so the last delta that crosses
// it is cut at the boundary rather than appended whole. Appended whole it
// overshoots the number the constant states, and the cut it needs happens
// wherever the frame happens to end: mid-character, in the text the model
// reads and in the arguments it dispatches.
test "the response ceiling is exact, and lands on a code point boundary" {
    const gpa = std.testing.allocator;
    // Three characters, nine bytes: the room left for them is what decides
    // where the cut lands.
    const cjk = "\\u65e5\\u672c\\u8a9e";

    var sink = FrameSink.init(gpa);
    defer sink.deinit();
    const arena = sink.run.allocator();
    // A first delta that leaves one byte of room, then one that does not fit.
    try sink.feed(try contentFrame(arena, "x" ** (max_response_bytes - 1)));
    try std.testing.expectEqual(max_response_bytes - 1, sink.result.content.items.len);

    try sink.feed(try contentFrame(arena, cjk));
    // "日" is three bytes, so one byte of room takes none of it.
    try std.testing.expectEqual(max_response_bytes - 1, sink.result.content.items.len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(sink.result.content.items));
    // What the terminal got is the same bytes the turn carries.
    try std.testing.expectEqualSlices(u8, sink.result.content.items, sink.out_buf.items);

    // Enough room for two of the three: the cut is at the boundary, not short
    // of it, and never inside a character.
    var roomy = FrameSink.init(gpa);
    defer roomy.deinit();
    const roomy_arena = roomy.run.allocator();
    try roomy.feed(try contentFrame(roomy_arena, "x" ** (max_response_bytes - 6)));
    try roomy.feed(try contentFrame(roomy_arena, cjk));
    try std.testing.expectEqual(max_response_bytes, roomy.result.content.items.len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(roomy.result.content.items));
    // The two that fit, and not the head of the third the cut gave back.
    try std.testing.expectEqualStrings("\u{65e5}\u{672c}", roomy.result.content.items[max_response_bytes - 6 ..]);
}

// The same boundary on the other side of a frame: arguments are JSON the next
// turn dispatches, and half a character in them is a parse error the model is
// told about as its own mistake.
test "streamed arguments stop at the ceiling on a code point boundary" {
    const gpa = std.testing.allocator;
    var sink = FrameSink.init(gpa);
    defer sink.deinit();
    const arena = sink.run.allocator();

    // A run one byte short of a three-byte character, so the ceiling falls
    // where a plain byte count would take half of one.
    const text = try std.mem.concat(arena, u8, &.{ "x" ** (max_response_bytes - 1), "\\u672c" });

    try sink.feed(try argsFrame(arena, text));
    try std.testing.expectEqual(max_response_bytes - 1, sink.calls.items[0].args.items.len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(sink.calls.items[0].args.items));
}

/// A frame whose delta carries `text`, which the tests above build out of ASCII
/// and `\uXXXX` escapes so it needs no escaping of its own.
fn contentFrame(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "{{\"choices\":[{{\"delta\":{{\"content\":\"{s}\"}}}}]}}", .{text});
}

fn argsFrame(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "{{\"choices\":[{{\"delta\":{{\"tool_calls\":[{{\"index\":0,\"function\":{{\"arguments\":\"{s}\"}}}}]}}}}]}}", .{text});
}

// The arguments ceiling is one budget for the response, not one per call: a
// provider naming `max_tool_calls` calls and streaming each one to the ceiling
// would otherwise cost the run that many times over.
test "the argument ceiling is spent across the response, not handed to each call" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const gpa = state.allocator();

    var result: chat_mod.ChatResult = .{};
    var calls: std.ArrayList(chat_mod.ToolCall) = .empty;
    var out_buf: std.ArrayList(u8) = .empty;
    var unparsable: usize = 0;

    // Fill the budget with one call, exactly as a stream of fragments would.
    var full: std.ArrayList(u8) = .empty;
    try full.appendSlice(gpa, "{\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"");
    try full.appendNTimes(gpa, 'x', max_response_bytes);
    try full.appendSlice(gpa, "\"}}]}}]}");
    try applyFrame(gpa, gpa, full.items, &result, &calls, &out_buf, &unparsable);
    try std.testing.expectEqual(max_response_bytes, calls.items[0].args.items.len);

    // A second call in the same response gets nothing: the budget is gone.
    const next = "{\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":1,\"function\":{\"name\":\"bash\",\"arguments\":\"{}\"}}]}}]}";
    try applyFrame(gpa, gpa, next, &result, &calls, &out_buf, &unparsable);
    try std.testing.expectEqual(@as(usize, 2), calls.items.len);
    try std.testing.expectEqualStrings("bash", calls.items[1].name);
    try std.testing.expectEqual(@as(usize, 0), calls.items[1].args.items.len);
    try std.testing.expectEqual(max_response_bytes, result.streamed);
}

test "usage counters land on the result" {
    var sink = FrameSink.init(std.testing.allocator);
    defer sink.deinit();

    try sink.feed(
        "{\"choices\":[{\"delta\":{}}],\"usage\":{\"prompt_tokens\":11,\"completion_tokens\":22,\"total_tokens\":33,\"completion_tokens_details\":{\"reasoning_tokens\":7}}}",
    );
    try std.testing.expectEqual(@as(u64, 11), sink.result.prompt_tokens);
    try std.testing.expectEqual(@as(u64, 22), sink.result.completion_tokens);
    try std.testing.expectEqual(@as(u64, 33), sink.result.total_tokens);
    try std.testing.expectEqual(@as(u64, 7), sink.result.reasoning_tokens);
    // Nothing in this frame says the prompt was cached, so it is a full miss.
    try std.testing.expectEqual(@as(u64, 0), sink.result.cached_tokens);
}

// The declared shapes are a speedup, not a narrowing: a frame they refuse is
// parsed into a value tree and read there, and it has to land the same way. A
// provider that sends `choices` as something other than an array, or `usage`
// as something other than an object, is what takes that path.
test "a frame the declared shapes refuse is read the long way" {
    {
        var sink = FrameSink.init(std.testing.allocator);
        defer sink.deinit();

        try sink.feed("{\"choices\":\"none\",\"usage\":{\"prompt_tokens\":900,\"completion_tokens\":24,\"prompt_tokens_details\":{\"cached_tokens\":768},\"completion_tokens_details\":{\"reasoning_tokens\":5}}}");
        try std.testing.expectEqual(@as(u64, 900), sink.result.prompt_tokens);
        // No total in the frame, so it is summed from the two that are there.
        try std.testing.expectEqual(@as(u64, 924), sink.result.total_tokens);
        try std.testing.expectEqual(@as(u64, 768), sink.result.cached_tokens);
        try std.testing.expectEqual(@as(u64, 5), sink.result.reasoning_tokens);
    }
    {
        var sink = FrameSink.init(std.testing.allocator);
        defer sink.deinit();

        try sink.feed("{\"choices\":[{\"delta\":{\"content\":\"hi\",\"tool_calls\":[{\"index\":0,\"id\":\"call_1\",\"function\":{\"name\":\"bash\",\"arguments\":\"{\\\"a\\\":1}\"}}]}}],\"usage\":5}");
        try std.testing.expectEqualStrings("hi", sink.result.content.items);
        try std.testing.expectEqual(@as(usize, 1), sink.calls.items.len);
        try std.testing.expectEqualStrings("call_1", sink.calls.items[0].id);
        try std.testing.expectEqualStrings("bash", sink.calls.items[0].name);
        try std.testing.expectEqualStrings("{\"a\":1}", sink.calls.items[0].args.items);
    }
}

// A provider that sends prompt and completion but no total leaves the run
// total at zero, and the max a reader takes over successive usage lines stays
// zero for the whole run.
test "a missing total is added up from the two counters that are there" {
    var sink = FrameSink.init(std.testing.allocator);
    defer sink.deinit();

    try sink.feed("{\"choices\":[{\"delta\":{}}],\"usage\":{\"prompt_tokens\":910,\"completion_tokens\":18}}");
    try std.testing.expectEqual(@as(u64, 910), sink.result.prompt_tokens);
    try std.testing.expectEqual(@as(u64, 928), sink.result.total_tokens);
}

// A total the provider did send is its own number and is not overwritten.
test "a sent total is left as it is" {
    var sink = FrameSink.init(std.testing.allocator);
    defer sink.deinit();

    try sink.feed("{\"choices\":[{\"delta\":{}}],\"usage\":{\"prompt_tokens\":11,\"completion_tokens\":22,\"total_tokens\":99}}");
    try std.testing.expectEqual(@as(u64, 99), sink.result.total_tokens);
}

// The cache counter is what turns "we probably reuse the prefix" into a number
// a benchmark can read, so all three provider spellings have to land on it.
test "cached prompt tokens read every provider spelling" {
    const spellings = [_][]const u8{
        "{\"choices\":[{\"delta\":{}}],\"usage\":{\"prompt_tokens\":900,\"prompt_tokens_details\":{\"cached_tokens\":768}}}",
        "{\"choices\":[{\"delta\":{}}],\"usage\":{\"prompt_tokens\":900,\"prompt_cache_hit_tokens\":768}}",
        "{\"choices\":[{\"delta\":{}}],\"usage\":{\"prompt_tokens\":900,\"cache_read_input_tokens\":768}}",
    };
    for (spellings) |payload| {
        var sink = FrameSink.init(std.testing.allocator);
        defer sink.deinit();
        try sink.feed(payload);
        try std.testing.expectEqual(@as(u64, 900), sink.result.prompt_tokens);
        try std.testing.expectEqual(@as(u64, 768), sink.result.cached_tokens);
    }
}

// A stream may spread its usage over several frames, and a frame that carries
// one counter says nothing about the others. Folding field by field is what
// keeps a second frame's silence from reading as a run that spent no prompt
// tokens: a run whose usage lines then report a token rate near zero.
test "a later usage frame does not zero the counters an earlier one set" {
    var sink = FrameSink.init(std.testing.allocator);
    defer sink.deinit();

    try sink.feed("{\"choices\":[{\"delta\":{}}],\"usage\":{\"prompt_tokens\":900,\"completion_tokens\":18,\"prompt_tokens_details\":{\"cached_tokens\":768}}}");
    try std.testing.expectEqual(@as(u64, 900), sink.result.prompt_tokens);
    try std.testing.expectEqual(@as(u64, 768), sink.result.cached_tokens);

    // The tail frame a provider sends carries the cache spelling alone.
    try sink.feed("{\"choices\":[{\"delta\":{}}],\"usage\":{\"cache_read_input_tokens\":768}}");
    try std.testing.expectEqual(@as(u64, 900), sink.result.prompt_tokens);
    try std.testing.expectEqual(@as(u64, 18), sink.result.completion_tokens);
    try std.testing.expectEqual(@as(u64, 768), sink.result.cached_tokens);
    try std.testing.expectEqual(@as(u64, 918), sink.result.total_tokens);
}

// A frame that spells the cache counter as a plain zero carries no count, the
// same way a frame that leaves the field out does. The three spellings are
// ranked within the frame, so reading them against the folded total let a
// later zero erase what the frame before it billed: the usage line then
// reported no cached prompt for a run that was served almost entirely from
// the provider's cache.
test "a later frame spelling the cache counter zero keeps the count folded in" {
    var sink = FrameSink.init(std.testing.allocator);
    defer sink.deinit();

    try sink.feed("{\"choices\":[{\"delta\":{}}],\"usage\":{\"prompt_tokens\":900,\"cache_read_input_tokens\":768}}");
    try std.testing.expectEqual(@as(u64, 768), sink.result.cached_tokens);

    try sink.feed("{\"choices\":[{\"delta\":{}}],\"usage\":{\"prompt_tokens\":900,\"prompt_tokens_details\":{\"cached_tokens\":0}}}");
    try std.testing.expectEqual(@as(u64, 768), sink.result.cached_tokens);
}

// A stream that splits the parts across frames is the same stream: the total
// is what all of them add up to. Summing once, on the frame that carried the
// first part, reported that frame's half and left the rest of the response out
// of the usage line a monitor reads tokens out of.
test "a total summed from parts counts the parts a later frame brings" {
    var sink = FrameSink.init(std.testing.allocator);
    defer sink.deinit();

    try sink.feed("{\"choices\":[{\"delta\":{}}],\"usage\":{\"prompt_tokens\":900}}");
    try std.testing.expectEqual(@as(u64, 900), sink.result.total_tokens);

    try sink.feed("{\"choices\":[{\"delta\":{}}],\"usage\":{\"completion_tokens\":18}}");
    try std.testing.expectEqual(@as(u64, 918), sink.result.total_tokens);

    // A total the provider does send is its own number, and it still wins.
    try sink.feed("{\"choices\":[{\"delta\":{}}],\"usage\":{\"total_tokens\":999}}");
    try std.testing.expectEqual(@as(u64, 999), sink.result.total_tokens);
}

// A count the provider spelled as a string and that is not a number is a frame
// that carried no count. Folding it in as a zero replaced the count an earlier
// frame really sent, and the usage line a monitor bills from then reports a
// run that spent nothing, with nothing on the operator's screen to say why.
test "a token count that is not a number is counted, not folded in as zero" {
    var sink = FrameSink.init(std.testing.allocator);
    defer sink.deinit();

    try sink.feed("{\"choices\":[{\"delta\":{}}],\"usage\":{\"prompt_tokens\":900,\"completion_tokens\":18}}");
    try std.testing.expectEqual(@as(usize, 0), sink.unparsable);
    try std.testing.expectEqual(@as(u64, 918), sink.result.total_tokens);

    // A number too large for the parse is still a number, so it folds.
    try sink.feed("{\"choices\":[{\"delta\":{}}],\"usage\":{\"total_tokens\":\"1234\"}}");
    try std.testing.expectEqual(@as(usize, 0), sink.unparsable);
    try std.testing.expectEqual(@as(u64, 1234), sink.result.total_tokens);

    // One that is not a number at all leaves the count where the provider put
    // it and is counted, so the stream loop names it on stderr.
    try sink.feed("{\"choices\":[{\"delta\":{}}],\"usage\":{\"total_tokens\":\"many\"}}");
    try std.testing.expectEqual(@as(usize, 1), sink.unparsable);
    try std.testing.expectEqual(@as(u64, 1234), sink.result.total_tokens);

    // The generic path, behind the declared shapes, is the same rule.
    try sink.feed("{\"choices\":[{\"delta\":{}}],\"usage\":{\"prompt_tokens\":\"lots\"}}");
    try std.testing.expectEqual(@as(usize, 2), sink.unparsable);
    try std.testing.expectEqual(@as(u64, 900), sink.result.prompt_tokens);
}

// A stream that ends without the provider's terminator is a dropped
// connection, not a finished answer. Appending the partial turn as complete is
// how a truncated response silently becomes the run's result, so the notice is
// what the run refuses on, and it has to say what did arrive.
test "a stream that ends without [DONE] is reported, not taken for finished" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expect(truncatedNotice(arena, "http://x/v1/chat/completions", true, 0, 0) == null);

    const cut = truncatedNotice(arena, "http://x/v1/chat/completions", false, 42, 1).?;
    try std.testing.expect(std.mem.indexOf(u8, cut, "http://x/v1/chat/completions") != null);
    try std.testing.expect(std.mem.indexOf(u8, cut, "without [DONE]") != null);
    try std.testing.expect(std.mem.indexOf(u8, cut, "42 byte(s) of content") != null);
    try std.testing.expect(std.mem.indexOf(u8, cut, "1 tool call(s)") != null);

    // Nothing arrived at all: still a cut, and still named.
    const empty = truncatedNotice(arena, "http://x/v1/chat/completions", false, 0, 0).?;
    try std.testing.expect(std.mem.indexOf(u8, empty, "0 byte(s) of content") != null);
}

// A frame the parser cannot read holds text and tool-call arguments the turn
// will not carry. Dropping it silently leaves a short response that looks like
// a complete one, so the count is what the run reports.
test "a frame the parser cannot read is counted, not dropped in silence" {
    var sink = FrameSink.init(std.testing.allocator);
    defer sink.deinit();

    try sink.feed("{\"choices\":[{\"delta\":{\"content\":\"kept\"}}]}");
    try std.testing.expectEqual(@as(usize, 0), sink.unparsable);

    try sink.feed("this is not json");
    try sink.feed("[1,2,3]");
    try sink.feed("{\"choices\":[{\"delta\":{\"content\":\"also kept\"}}]}");

    try std.testing.expectEqual(@as(usize, 2), sink.unparsable);
    // The frames around the bad ones still landed, so the turn is short rather
    // than empty: only the count says how much is missing.
    try std.testing.expectEqualStrings("keptalso kept", sink.result.content.items);
}

// A frame the parser cannot read is the provider's; an allocation that failed
// is this machine's. Counting the second as the first tells the operator to go
// and look at a provider that was answering correctly, and it hides the one
// failure the run cannot get past.
test "a frame that cannot be parsed for want of memory is not counted as bad JSON" {
    const gpa = std.testing.allocator;
    var state = std.heap.ArenaAllocator.init(gpa);
    defer state.deinit();
    const arena = state.allocator();

    var result: chat_mod.ChatResult = .{};
    var calls: std.ArrayList(chat_mod.ToolCall) = .empty;
    var out_buf: std.ArrayList(u8) = .empty;
    var unparsable: usize = 0;

    var failing: std.testing.FailingAllocator = .init(arena, .{ .fail_index = 0 });
    try std.testing.expectError(
        error.OutOfMemory,
        applyFrame(failing.allocator(), arena, "{\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}", &result, &calls, &out_buf, &unparsable),
    );
    try std.testing.expectEqual(@as(usize, 0), unparsable);
    try std.testing.expectEqual(@as(usize, 0), result.content.items.len);
}

test "a gap in the tool-call indexes leaves no nameless call behind" {
    const gpa = std.testing.allocator;
    var run_state = std.heap.ArenaAllocator.init(gpa);
    defer run_state.deinit();
    const arena = run_state.allocator();

    var result: chat_mod.ChatResult = .{};
    var calls: std.ArrayList(chat_mod.ToolCall) = .empty;
    var out_buf: std.ArrayList(u8) = .empty;
    var unparsable: usize = 0;
    // Index 2 arrives with no 0 and no 1, so the frame parser has to size the
    // list to index 2 and leave two slots behind it.
    const payload = "{\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":2,\"id\":\"call_1\",\"function\":{\"name\":\"read\",\"arguments\":\"{}\"}}]}}]}";
    try applyFrame(arena, arena, payload, &result, &calls, &out_buf, &unparsable);
    try std.testing.expectEqual(@as(usize, 3), calls.items.len);

    _ = keepRunnableCalls(arena, &calls);
    try std.testing.expectEqual(@as(usize, 1), calls.items.len);
    try std.testing.expectEqualStrings("read", calls.items[0].name);

    // A response whose calls are all named is untouched.
    _ = keepRunnableCalls(arena, &calls);
    try std.testing.expectEqual(@as(usize, 1), calls.items.len);
}

/// The ids a two-call frame carries before the drop, and the ones left after
/// it, so the cases that drop a call on a missing name, arguments or id assert
/// the same shape over the same fold rather than repeating it.
const KeptCallIds = struct { before: [][]const u8, after: [][]const u8 };

fn foldCallIds(arena: std.mem.Allocator, payload: []const u8) !KeptCallIds {
    var result: chat_mod.ChatResult = .{};
    var calls: std.ArrayList(chat_mod.ToolCall) = .empty;
    var out_buf: std.ArrayList(u8) = .empty;
    var unparsable: usize = 0;
    try applyFrame(arena, arena, payload, &result, &calls, &out_buf, &unparsable);
    try std.testing.expectEqual(@as(usize, 2), calls.items.len);
    const before = try arena.alloc([]const u8, calls.items.len);
    for (calls.items, before) |call, *id| id.* = call.id;
    _ = keepRunnableCalls(arena, &calls);
    const after = try arena.alloc([]const u8, calls.items.len);
    for (calls.items, after) |call, *id| id.* = call.id;
    return .{ .before = before, .after = after };
}

// A call whose arguments stopped mid-object is a prefix of a call, and the
// assistant message carries the arguments back to the provider as they are. A
// provider that reads them rejects the next request, so one truncated turn ends
// the run instead of only costing that turn.
test "a tool call cut mid-argument is dropped rather than sent on" {
    const gpa = std.testing.allocator;
    var run_state = std.heap.ArenaAllocator.init(gpa);
    defer run_state.deinit();
    const arena = run_state.allocator();

    try std.testing.expect(argumentsAreAnObject(arena, "{}"));
    try std.testing.expect(argumentsAreAnObject(arena, " {\"path\":\"a.zig\"} "));
    try std.testing.expect(!argumentsAreAnObject(arena, ""));
    try std.testing.expect(!argumentsAreAnObject(arena, "{\"command\": \"ls -"));
    try std.testing.expect(!argumentsAreAnObject(arena, "\"a string\""));

    const cut = "{\"choices\":[{\"delta\":{\"tool_calls\":[" ++
        "{\"index\":0,\"id\":\"call_cut\",\"function\":{\"name\":\"bash\",\"arguments\":\"{\\\"command\\\": \\\"ls -\"}}," ++
        "{\"index\":1,\"id\":\"call_ok\",\"function\":{\"name\":\"bash\",\"arguments\":\"{\\\"command\\\": \\\"ls\\\"}\"}}" ++
        "]}}]}";
    const kept = try foldCallIds(arena, cut);
    try std.testing.expectEqual(@as(usize, 1), kept.after.len);
    try std.testing.expectEqualStrings("call_ok", kept.after[0]);
}

// The id is what a tool message is paired to, and it is the third member of the
// same triple the two cases above already drop on. A stream that carries a name
// and a whole argument object but no `id` would otherwise go back to the
// provider as a `tool_calls` entry it has nothing to match, and every tool
// result for it would name an empty `tool_call_id`.
test "a tool call with no id is dropped rather than sent on" {
    const gpa = std.testing.allocator;
    var run_state = std.heap.ArenaAllocator.init(gpa);
    defer run_state.deinit();
    const arena = run_state.allocator();

    const payload = "{\"choices\":[{\"delta\":{\"tool_calls\":[" ++
        "{\"index\":0,\"function\":{\"name\":\"bash\",\"arguments\":\"{\\\"command\\\": \\\"ls\\\"}\"}}," ++
        "{\"index\":1,\"id\":\"call_ok\",\"function\":{\"name\":\"bash\",\"arguments\":\"{\\\"command\\\": \\\"ls\\\"}\"}}" ++
        "]}}]}";
    const kept = try foldCallIds(arena, payload);
    try std.testing.expectEqual(@as(usize, 0), kept.before[0].len);
    try std.testing.expectEqual(@as(usize, 1), kept.after.len);
    try std.testing.expectEqualStrings("call_ok", kept.after[0]);
}

// A stream is delivered at least once. A relay that reconnects replays from the
// last event it saw, and a provider that restarts a call after a dropped
// connection delivers it again under the next index, so one response can carry
// the same call twice. The id is the only thing that says so, and the tools are
// exactly the ones where a second dispatch is damage: `bash` runs the command
// twice, `write` and `edit` rewrite a file the first pass already changed. The
// first is kept, so the assistant message names each call once and the tool
// results still pair one to one.
test "a tool call the stream delivered twice is dispatched once" {
    const gpa = std.testing.allocator;
    var run_state = std.heap.ArenaAllocator.init(gpa);
    defer run_state.deinit();
    const arena = run_state.allocator();

    // Indexes 0 and 1 under one id: the second delivery of one call, which is
    // what a restart looks like on the wire.
    const payload = "{\"choices\":[{\"delta\":{\"tool_calls\":[" ++
        "{\"index\":0,\"id\":\"call_1\",\"function\":{\"name\":\"bash\",\"arguments\":\"{\\\"command\\\": \\\"ls\\\"}\"}}," ++
        "{\"index\":1,\"id\":\"call_1\",\"function\":{\"name\":\"bash\",\"arguments\":\"{\\\"command\\\": \\\"ls\\\"}\"}}," ++
        "{\"index\":2,\"id\":\"call_2\",\"function\":{\"name\":\"read\",\"arguments\":\"{\\\"path\\\":\\\"a.zig\\\"}\"}}" ++
        "]}}]}";
    var result: chat_mod.ChatResult = .{};
    var calls: std.ArrayList(chat_mod.ToolCall) = .empty;
    var out_buf: std.ArrayList(u8) = .empty;
    var unparsable: usize = 0;
    try applyFrame(arena, arena, payload, &result, &calls, &out_buf, &unparsable);
    try std.testing.expectEqual(@as(usize, 3), calls.items.len);

    const dropped = keepRunnableCalls(arena, &calls);
    try std.testing.expectEqual(@as(usize, 1), dropped.duplicate);
    try std.testing.expectEqual(@as(usize, 2), calls.items.len);
    try std.testing.expectEqualStrings("call_1", calls.items[0].id);
    try std.testing.expectEqualStrings("call_2", calls.items[1].id);

    // Two distinct calls that happen to be identical are two calls, and the run
    // is the one that asked for both.
    const twice = "{\"choices\":[{\"delta\":{\"tool_calls\":[" ++
        "{\"index\":0,\"id\":\"call_a\",\"function\":{\"name\":\"read\",\"arguments\":\"{\\\"path\\\":\\\"a.zig\\\"}\"}}," ++
        "{\"index\":1,\"id\":\"call_b\",\"function\":{\"name\":\"read\",\"arguments\":\"{\\\"path\\\":\\\"a.zig\\\"}\"}}" ++
        "]}}]}";
    var second: std.ArrayList(chat_mod.ToolCall) = .empty;
    try applyFrame(arena, arena, twice, &result, &second, &out_buf, &unparsable);
    const kept = keepRunnableCalls(arena, &second);
    try std.testing.expectEqual(@as(usize, 0), kept.duplicate);
    try std.testing.expectEqual(@as(usize, 2), second.items.len);
}

// A call the filter took out is work the run did not do, and the turn carrying
// it goes on as a finished one. So the count is said, and the notice is null
// exactly when nothing was dropped: a turn that dispatched everything it was
// given has nothing to report, and a line on every turn would be one an
// operator learns to skip.
test "a dropped tool call is reported, and a turn that dropped none is not" {
    const gpa = std.testing.allocator;
    var run_state = std.heap.ArenaAllocator.init(gpa);
    defer run_state.deinit();
    const arena = run_state.allocator();

    // Two slots the index walk left behind are dropped as unusable.
    const gapped = "{\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":2,\"id\":\"call_1\",\"function\":{\"name\":\"read\",\"arguments\":\"{}\"}}]}}]}";
    var result: chat_mod.ChatResult = .{};
    var calls: std.ArrayList(chat_mod.ToolCall) = .empty;
    var out_buf: std.ArrayList(u8) = .empty;
    var unparsable: usize = 0;
    try applyFrame(arena, arena, gapped, &result, &calls, &out_buf, &unparsable);
    try std.testing.expectEqual(@as(usize, 3), calls.items.len);

    const dropped = keepRunnableCalls(arena, &calls);
    try std.testing.expectEqual(@as(usize, 2), dropped.unusable);
    try std.testing.expectEqual(@as(usize, 0), dropped.duplicate);
    try std.testing.expectEqual(@as(usize, 1), calls.items.len);

    const notice = droppedCallNotice(arena, "http://x/v1/chat/completions", dropped, 0).?;
    try std.testing.expect(std.mem.indexOf(u8, notice, "http://x/v1/chat/completions") != null);
    try std.testing.expect(std.mem.indexOf(u8, notice, "2 tool call(s)") != null);
    try std.testing.expect(std.mem.indexOf(u8, notice, "not dispatched") != null);

    // A second delivery of one call is the other reason, and it is named where
    // it happens, so the notice stays null for it.
    const twice = "{\"choices\":[{\"delta\":{\"tool_calls\":[" ++
        "{\"index\":0,\"id\":\"call_1\",\"function\":{\"name\":\"read\",\"arguments\":\"{\\\"path\\\":\\\"a.zig\\\"}\"}}," ++
        "{\"index\":1,\"id\":\"call_1\",\"function\":{\"name\":\"read\",\"arguments\":\"{\\\"path\\\":\\\"a.zig\\\"}\"}}" ++
        "]}}]}";
    var second: std.ArrayList(chat_mod.ToolCall) = .empty;
    try applyFrame(arena, arena, twice, &result, &second, &out_buf, &unparsable);
    const kept = keepRunnableCalls(arena, &second);
    try std.testing.expectEqual(@as(usize, 0), kept.unusable);
    try std.testing.expect(droppedCallNotice(arena, "http://x/v1/chat/completions", kept, 0) == null);
    try std.testing.expect(droppedCallNotice(arena, "http://x", .{}, 0) == null);
}

// A relay that reconnects replays the frames it already sent, so the same slot
// is announced twice with the whole argument string both times. Appending the
// second delivery to the first glued two objects together, the call was dropped
// as unreadable, and the work it asked for was never done.
test "a slot the stream announced twice keeps the arguments the provider sent" {
    const gpa = std.testing.allocator;
    var run_state = std.heap.ArenaAllocator.init(gpa);
    defer run_state.deinit();
    const arena = run_state.allocator();

    const one = "{\"choices\":[{\"delta\":{\"tool_calls\":[" ++
        "{\"index\":0,\"id\":\"call_1\",\"function\":{\"name\":\"read\",\"arguments\":\"{\\\"path\\\":\\\"a.zig\\\"}\"}}" ++
        "]}}]}";
    const framed = [_][]const u8{ one, one, one };
    var result: chat_mod.ChatResult = .{};
    var calls: std.ArrayList(chat_mod.ToolCall) = .empty;
    var out_buf: std.ArrayList(u8) = .empty;
    var unparsable: usize = 0;
    for (framed) |payload| try applyFrame(arena, arena, payload, &result, &calls, &out_buf, &unparsable);

    const dropped = keepRunnableCalls(arena, &calls);
    try std.testing.expectEqual(@as(usize, 0), dropped.unusable);
    try std.testing.expectEqual(@as(usize, 0), dropped.duplicate);
    try std.testing.expectEqual(@as(usize, 1), calls.items.len);
    try std.testing.expectEqualStrings("call_1", calls.items[0].id);
    try std.testing.expectEqualStrings("read", calls.items[0].name);
    try std.testing.expectEqualStrings("{\"path\":\"a.zig\"}", calls.items[0].args.items);
}

// A call streamed one argument at a time is the ordinary shape and is not a
// replay: no fragment re-announces the id, so the pieces still concatenate.
test "a call streamed in fragments still reads as one argument object" {
    const gpa = std.testing.allocator;
    var run_state = std.heap.ArenaAllocator.init(gpa);
    defer run_state.deinit();
    const arena = run_state.allocator();

    const head = "{\"choices\":[{\"delta\":{\"tool_calls\":[" ++
        "{\"index\":0,\"id\":\"call_1\",\"function\":{\"name\":\"bash\",\"arguments\":\"{\\\"command\\\": \\\"ls\"}}" ++
        "]}}]}";
    const tail = "{\"choices\":[{\"delta\":{\"tool_calls\":[" ++
        "{\"index\":0,\"function\":{\"arguments\":\" -l\\\"}\"}}" ++
        "]}}]}";
    var result: chat_mod.ChatResult = .{};
    var calls: std.ArrayList(chat_mod.ToolCall) = .empty;
    var out_buf: std.ArrayList(u8) = .empty;
    var unparsable: usize = 0;
    try applyFrame(arena, arena, head, &result, &calls, &out_buf, &unparsable);
    try applyFrame(arena, arena, tail, &result, &calls, &out_buf, &unparsable);

    const dropped = keepRunnableCalls(arena, &calls);
    try std.testing.expectEqual(@as(usize, 0), dropped.unusable);
    try std.testing.expectEqualStrings("{\"command\": \"ls -l\"}", calls.items[0].args.items);
}

// The parallel-call ceiling drops a call the model asked for, and the assistant
// message the provider reads next names only the calls that were kept. So the
// ceiling counts what it turned away, and a turn that stayed under it says
// nothing.
test "a tool call past the parallel-call ceiling is counted and reported" {
    const gpa = std.testing.allocator;
    var run_state = std.heap.ArenaAllocator.init(gpa);
    defer run_state.deinit();
    const arena = run_state.allocator();

    var buf: [512]u8 = undefined;
    const past = std.fmt.bufPrint(&buf, "{{\"choices\":[{{\"delta\":{{\"tool_calls\":[" ++
        "{{\"index\":0,\"id\":\"call_0\",\"function\":{{\"name\":\"read\",\"arguments\":\"{{}}\"}}}}," ++
        "{{\"index\":{d},\"id\":\"call_past\",\"function\":{{\"name\":\"read\",\"arguments\":\"{{}}\"}}}}" ++
        "]}}}}]}}", .{max_tool_calls}) catch unreachable;
    var result: chat_mod.ChatResult = .{};
    var calls: std.ArrayList(chat_mod.ToolCall) = .empty;
    var out_buf: std.ArrayList(u8) = .empty;
    var unparsable: usize = 0;
    try applyFrame(arena, arena, past, &result, &calls, &out_buf, &unparsable);
    // The call past the cap is not in the list at all, so it cannot be sized
    // into it: this is the same count the notice reports.
    try std.testing.expectEqual(@as(usize, 1), calls.items.len);
    try std.testing.expectEqual(@as(usize, 1), result.over_cap);

    const notice = droppedCallNotice(arena, "http://x", .{}, result.over_cap).?;
    try std.testing.expect(std.mem.indexOf(u8, notice, "1 tool call(s)") != null);
    try std.testing.expect(std.mem.indexOf(u8, notice, "not dispatched") != null);

    // The same call streamed as the fragments a long argument arrives in is
    // one call past the ceiling, not one per fragment.
    result.over_cap = 0;
    result.over_cap_index = null;
    for (0..4) |_| {
        const part = std.fmt.bufPrint(&buf, "{{\"choices\":[{{\"delta\":{{\"tool_calls\":[" ++
            "{{\"index\":{d},\"function\":{{\"arguments\":\"[1, 2\"}}}}" ++
            "]}}}}]}}", .{max_tool_calls}) catch unreachable;
        try applyFrame(arena, arena, part, &result, &calls, &out_buf, &unparsable);
    }
    try std.testing.expectEqual(@as(usize, 1), result.over_cap);

    // Both reasons at once is one line naming both, and the counts add.
    const joined = droppedCallNotice(arena, "http://x", .{ .unusable = 3 }, 2).?;
    try std.testing.expect(std.mem.indexOf(u8, joined, "5 tool call(s)") != null);
    try std.testing.expect(std.mem.indexOf(u8, joined, "3 carried no id") != null);

    // An index that saturates rather than wrapping is the same case: the cap is
    // what catches it, and it is counted.
    result.over_cap = 0;
    try applyCallDelta(arena, .{ .number_string = "not a number" }, null, null, null, &result, &calls);
    try std.testing.expectEqual(@as(usize, 0), result.over_cap);
    try applyCallDelta(arena, .{ .float = 1e30 }, null, null, null, &result, &calls);
    try std.testing.expectEqual(@as(usize, 1), result.over_cap);
    try std.testing.expectEqual(@as(usize, 1), calls.items.len);
}

// The declared shapes are a speedup, not a filter: a provider is free to send
// fields neither shape names, and nested junk inside a delta must not cost the
// frame. Anything the declared shapes cannot hold at all lands on the generic
// parse behind them, which is still there and still correct.
test "a frame with fields the shapes do not name still lands" {
    var sink = FrameSink.init(std.testing.allocator);
    defer sink.deinit();

    try sink.feed(
        \\{"id":"gen-1","object":"chat.completion.chunk","created":1,"model":"m","system_fingerprint":"fp","service_tier":"scale",
        \\ "choices":[{"index":0,"logprobs":null,"finish_reason":null,
        \\ "delta":{"role":"assistant","content":"caf\u00e9","vendor_extra":{"nested":[1,2,{"deep":null}]}},"extra":true}]}
    );
    // The escape is resolved, so the model sees the character and not the
    // six bytes it was sent as.
    try std.testing.expectEqualStrings("caf\u{00e9}", sink.result.content.items);

    // A frame the declared shapes cannot hold falls through to the generic
    // parse, which still reads the content and the tool call out of it.
    sink.result.content.clearRetainingCapacity();
    try sink.feed(
        \\{"choices":[{"delta":{"content":"fallback","tool_calls":[{"index":0,"id":"c1","type":"function",
        \\ "function":{"name":"read","arguments":"{}"}}]}}],"unknown_top":{"a":[1,2]}}
    );
    try std.testing.expectEqualStrings("fallback", sink.result.content.items);
    try std.testing.expectEqual(@as(usize, 1), sink.calls.items.len);
    try std.testing.expectEqualStrings("read", sink.calls.items[0].name);
}

// The model the provider says answered, not the one the run asked for. A
// gateway routes a name to whichever snapshot it holds, so a record carrying
// only the request's name cannot say which model produced a run, and two runs
// of one command compare as equal when the weights behind them were not.
test "what answered a response is kept, and a later frame that omits it does not erase it" {
    var sink = FrameSink.init(std.testing.allocator);
    defer sink.deinit();

    try sink.feed(
        \\{"id":"gen-1","model":"deepseek/deepseek-v4-flash-0726","system_fingerprint":"fp_aaa","choices":[{"delta":{"content":"a"}}]}
    );
    try std.testing.expectEqualStrings("deepseek/deepseek-v4-flash-0726", sink.result.served_model);
    try std.testing.expectEqualStrings("fp_aaa", sink.result.fingerprint);

    // Repeated on every chunk of a stream, which is why the fields are not
    // re-copied, and a frame that omits them leaves what the first one said.
    try sink.feed(
        \\{"id":"gen-2","model":"deepseek/deepseek-v4-flash-0726","system_fingerprint":"fp_aaa","choices":[{"delta":{"content":"b"}}]}
    );
    try sink.feed(
        \\{"id":"gen-3","choices":[{"delta":{"content":"c"}}]}
    );
    try std.testing.expectEqualStrings("deepseek/deepseek-v4-flash-0726", sink.result.served_model);
    try std.testing.expectEqualStrings("fp_aaa", sink.result.fingerprint);

    // The generic path, which is where a frame the declared shapes cannot hold
    // lands, reads the same two fields.
    try sink.feed(
        \\{"model":"other/other-0731","system_fingerprint":"fp_bbb","unknown_top":{"a":[1,2]},"choices":[{"delta":{"content":"d"}}]}
    );
    try std.testing.expectEqualStrings("other/other-0731", sink.result.served_model);
    try std.testing.expectEqualStrings("fp_bbb", sink.result.fingerprint);

    // A frame whose `model` is a number rather than a string carries no name to
    // record, so it leaves the one that is standing rather than blanking it.
    try sink.feed(
        \\{"model":7,"choices":[{"delta":{"content":"e"}}]}
    );
    try std.testing.expectEqualStrings("other/other-0731", sink.result.served_model);
}

// The strings `served_model` and `fingerprint` hold are this run's own, so a
// turn that ends releases them with the rest of the response.
test "the served model and fingerprint are released with the response" {
    const gpa = std.testing.allocator;
    var result: chat_mod.ChatResult = .{};
    try chat_mod.recordServed(gpa, &result, "served/one", "fp_one");
    // The same values again change nothing and leave nothing to release twice.
    try chat_mod.recordServed(gpa, &result, "served/one", "fp_one");
    try chat_mod.recordServed(gpa, &result, "served/two", null);
    try std.testing.expectEqualStrings("served/two", result.served_model);
    try std.testing.expectEqualStrings("fp_one", result.fingerprint);
    result.deinit(gpa);
}

// A provider that fails after the first tokens cannot say so in a status line:
// the response head was 200 and the failure arrives as a frame. Nothing about
// the frames around it marks the turn, so a stream read on its own is a stream
// the provider finished, and a turn that had already said something is put on
// stdout as a whole answer. The report has to survive into the turn's notice.
test "a failure the provider reported in the stream is kept, in its own words" {
    var sink = FrameSink.init(std.testing.allocator);
    defer sink.deinit();

    try sink.feed(
        \\{"id":"gen-1","model":"m","choices":[{"delta":{"content":"partial answer"}}]}
    );
    try std.testing.expectEqual(@as(usize, 0), sink.result.stream_error.len);

    try sink.feed(
        \\{"error":{"code":"provider_error","message":"upstream timed out mid-generation"}}
    );
    try std.testing.expectEqualStrings("provider_error: upstream timed out mid-generation", sink.result.stream_error);
    // The text that arrived before the failure is untouched, so the notice can
    // say what is on stdout is a prefix of what the provider meant to send.
    try std.testing.expectEqualStrings("partial answer", sink.result.content.items);

    // A gateway that reports the same failure in every frame after it says it
    // once: the first is the cause, and the rest are it repeated.
    try sink.feed(
        \\{"error":{"message":"second report"}}
    );
    try std.testing.expectEqualStrings("provider_error: upstream timed out mid-generation", sink.result.stream_error);

    // The shapes that carry the rest of a frame do not mistake the report for
    // one: an `error` member is what sends a frame to the generic parse, and a
    // frame without one still takes the declared one.
    try std.testing.expect(!reportsError("{\"model\":\"m\",\"choices\":[]}"));
    try std.testing.expect(!reportsError("{\"error\":null,\"model\":\"m\"}"));
    try std.testing.expect(reportsError("{\"error\":{\"message\":\"boom\"}}"));
    try std.testing.expect(reportsError("{\"error\": \"boom\"}"));
    // A model that writes the member into its own answer has it escaped, so the
    // bytes that spell a key cannot appear inside the string.
    try std.testing.expect(!reportsError("{\"choices\":[{\"delta\":{\"content\":\"look at {\\\"error\\\": 1} here\"}}]}"));

    // A frame reporting a failure the provider sent no reason for still ends the
    // turn: the notice needs words, not silence.
    const gpa = std.testing.allocator;
    var bare: chat_mod.ChatResult = .{};
    try noteStreamError(gpa, &bare, null);
    try std.testing.expect(bare.stream_error.len == 0);
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, "{\"error\":{}}", .{});
    defer parsed.deinit();
    try noteStreamError(gpa, &bare, parsed.value.object.get("error"));
    try std.testing.expectEqualStrings("the provider reported an error and named no reason", bare.stream_error);
    bare.deinit(gpa);
}

// A generation the provider cut at `max_tokens` arrives with a clean
// terminator, so nothing else in the run knows the answer is a prefix of what
// the model meant to say. The reason has to survive the frame that carries it.
test "a response cut at the generation ceiling says so" {
    var sink = FrameSink.init(std.testing.allocator);
    defer sink.deinit();

    try sink.feed("{\"choices\":[{\"delta\":{\"content\":\"half a sen\"}}]}");
    try std.testing.expectEqualStrings("", sink.result.finish_reason);

    try sink.feed("{\"choices\":[{\"delta\":{},\"finish_reason\":\"length\"}]}");
    try std.testing.expectEqualStrings("length", sink.result.finish_reason);

    // A later frame's reason replaces the earlier one, and the string is
    // copied out of the frame arena, which the caller resets after every frame.
    try sink.feed("{\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}");
    try std.testing.expectEqualStrings("stop", sink.result.finish_reason);

    // A reason that is not a string, or is null, leaves the last one standing.
    try sink.feed("{\"choices\":[{\"delta\":{},\"finish_reason\":7}]}");
    try sink.feed("{\"choices\":[{\"delta\":{},\"finish_reason\":null}]}");
    try std.testing.expectEqualStrings("stop", sink.result.finish_reason);
}

test "a tool call index past the cap is dropped, not allocated" {
    // The cap is 64 calls, so index 63 is the last one the run keeps and 64 is
    // the first it drops. A far index would pass under a cap placed anywhere in
    // four orders of magnitude; the pair either side of the number is what pins
    // it, and a cap one too high or one too low keeps the wrong one of them.
    // Every call carries an id and an object argument, so the run's own
    // unusable-call sweep cannot empty the list and hide which side of the cap
    // the call fell.
    for ([_]struct { index: u32, slots: usize }{
        .{ .index = 0, .slots = 1 },
        .{ .index = 63, .slots = 64 },
        .{ .index = 64, .slots = 0 },
        .{ .index = 1000, .slots = 0 },
        .{ .index = 4000000000, .slots = 0 },
    }) |case| {
        var sink = FrameSink.init(std.testing.allocator);
        defer sink.deinit();
        const frame = try std.fmt.allocPrint(
            std.testing.allocator,
            "{{\"choices\":[{{\"delta\":{{\"tool_calls\":[{{\"index\":{d},\"id\":\"call_1\",\"function\":{{\"name\":\"bash\",\"arguments\":\"{{}}\"}}}}]}}}}]}}",
            .{case.index},
        );
        defer std.testing.allocator.free(frame);
        try sink.feed(frame);
        // An index sizes the list, so the last call kept sits at its own index
        // and the slots below it are the placeholders the sweep drops.
        try std.testing.expectEqual(case.slots, sink.calls.items.len);
        _ = keepRunnableCalls(sink.run.allocator(), &sink.calls);
        try std.testing.expectEqual(@as(usize, if (case.index >= max_tool_calls) 0 else 1), sink.calls.items.len);
        if (case.slots != 0) try std.testing.expectEqualStrings("call_1", sink.calls.items[0].id);
    }

    // An index past the cap is dropped before the slots below it are filled, so
    // it allocates nothing: the list a four-billion index would otherwise size
    // is never built. The run arena is the counter, because a list that grew
    // would grow it.
    var sink = FrameSink.init(std.testing.allocator);
    defer sink.deinit();
    try sink.feed("{\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":4000000000,\"function\":{\"name\":\"bash\"}}]}}]}");
    try std.testing.expectEqual(@as(usize, 0), sink.calls.items.len);
    try std.testing.expectEqual(@as(usize, 0), sink.run.queryCapacity());
}

// The name and the id of a streamed tool call are copies the run allocator
// owns, so releasing the response has to release them with its other buffers.
test "a response releases the copies it made of a tool call" {
    const gpa = std.testing.allocator;
    // The scratch arena is the one the stream loop resets after every frame;
    // the run allocator is the one the copies outlive.
    var scratch_state = std.heap.ArenaAllocator.init(gpa);
    defer scratch_state.deinit();

    var result: chat_mod.ChatResult = .{};
    var calls: std.ArrayList(chat_mod.ToolCall) = .empty;
    var out_buf: std.ArrayList(u8) = .empty;
    var unparsable: usize = 0;
    const payload = "{\"choices\":[{\"delta\":{\"tool_calls\":[" ++
        "{\"index\":0,\"id\":\"call_1\",\"function\":{\"name\":\"read\",\"arguments\":\"{\\\"path\\\":\\\"a\\\"}\"}}" ++
        "]}}]}";
    try applyFrame(scratch_state.allocator(), gpa, payload, &result, &calls, &out_buf, &unparsable);
    result.calls = calls;
    try std.testing.expectEqualStrings("call_1", result.calls.items[0].id);
    try std.testing.expectEqualStrings("read", result.calls.items[0].name);

    // The testing allocator reports the copies the response kept past deinit.
    result.deinit(gpa);
}
