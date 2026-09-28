//! Whether a failed attempt is worth making again, and how long to wait first.
//!
//! The policy the completion loop leans on, kept out of it: a request the
//! provider cannot have read is its weather and goes out again, a request it
//! can have read does not, and a wait the run's budget cannot cover is not
//! taken at all. `budget` answers the last question, so this imports it and
//! nothing above either.

const std = @import("std");
const Io = std.Io;

const net = @import("net.zig");
const budget_mod = @import("budget.zig");

pub const max_attempts: u32 = 3;
const retry_backoff_base_ms: u64 = 1000;
pub const max_backoff_ms: u64 = 60_000;
/// Enough doublings to reach the cap; the cap is what bounds the wait.
const max_backoff_shift: u32 = 6;

/// Statuses worth another attempt: the provider is busy, not the request wrong.
/// A provider that answered has not generated the completion, so the turn
/// behind this request is unbilled and sending it again costs nothing twice.
pub fn retryableStatus(status: std.http.Status) bool {
    return switch (@intFromEnum(status)) {
        408, 409, 425, 429 => true,
        else => @intFromEnum(status) >= 500,
    };
}

/// How far one attempt got with the request before it failed.
pub const request_stage = enum {
    /// Nothing of the request reached the wire.
    opened,
    /// The body is partly on the wire, so the provider cannot have parsed a
    /// turn out of it yet.
    sending,
    /// Every byte of the turn is on the wire and the provider has had it since.
    head,
};

/// Whether a failure at this stage is worth sending the turn again.
///
/// Only the head is not. The provider read the whole request, so a connection
/// that died before the response arrived may have generated and billed the
/// completion anyway, and a second POST of the same conversation is a second
/// billable completion for one turn. Losing that turn is the cheaper failure,
/// so the run ends on the error and the operator is told it was not resent.
/// An idempotency key would settle it, and the OpenAI-shaped completions API
/// this speaks takes none, so the request cannot be made safe to send twice.
pub fn worthAnotherAttempt(stage: request_stage) bool {
    return stage != .head;
}

/// Names the endpoint and the step that failed, then sleeps before the next
/// attempt. False means attempts are spent and the caller should surface the
/// error. A retried request says so: without this line a provider that refuses
/// two requests in a row and answers the third is a run that merely took
/// longer, and nothing on the operator's screen explains the gap. Only the
/// steps that fail before the request is on the wire come through here; one
/// that fails after is not retried at all, for the reason `worthAnotherAttempt`
/// gives.
pub fn waitBeforeRetry(
    io: Io,
    arena: std.mem.Allocator,
    url: []const u8,
    attempt: u32,
    what: []const u8,
    err: anyerror,
    budget: budget_mod.Budget,
) bool {
    if (attempt >= max_attempts) return false;
    const wait = budget.affordableWaitMs(io, backoffMs(attempt)) orelse {
        net.note(io, arena, "microagent: {s} {s} failed ({s}), and the {d}ms before another attempt would pass the run's budget; this one is the last\n", .{
            what, url, @errorName(err), backoffMs(attempt),
        });
        return false;
    };
    net.note(io, arena, "microagent: {s} {s} failed ({s}), retrying (attempt {d}/{d})\n", .{
        what, url, @errorName(err), attempt + 1, max_attempts,
    });
    waitMs(io, wait) catch {};
    return true;
}

/// Backoff before the next attempt: 1 s, 2 s, 4 s, capped. Saturating, because
/// the shift and the multiply both overflow long before a u32 attempt counter
/// does, and a checked build panicking where a release build wraps is not a
/// property to want in a sleep.
pub fn backoffMs(attempt: u32) u64 {
    if (attempt == 0) return retry_backoff_base_ms;
    const shift: u6 = @intCast(@min(attempt - 1, max_backoff_shift));
    return @min(retry_backoff_base_ms *| (@as(u64, 1) << shift), max_backoff_ms);
}

pub fn waitFor(io: Io, attempt: u32) !void {
    try waitMs(io, backoffMs(attempt));
}

pub fn waitMs(io: Io, ms: u64) !void {
    try io.sleep(.{ .nanoseconds = ms *| std.time.ns_per_ms }, .awake);
}

/// The longest `Retry-After` this run will sit out. A provider asking for an
/// hour is not a provider to wait an hour for, and the schedule behind it
/// bounds the wait instead.
pub const max_retry_after_ms: u64 = 120_000;

/// The wait a 429 or 503 asks for, in milliseconds, or null when the header is
/// absent or is not one this run will wait.
///
/// Only the delta-seconds form is read. The HTTP-date form is what a provider
/// sends when it computes a deadline against a clock, and the run has no
/// second clock to check it against; a header this cannot read falls back to
/// the backoff schedule rather than being guessed at.
pub fn retryAfterMs(head_bytes: []const u8) ?u64 {
    var lines = std.mem.splitSequence(u8, head_bytes, "\r\n");
    _ = lines.next(); // the status line
    while (lines.next()) |line| {
        if (line.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " \t"), "retry-after")) continue;
        const raw = std.mem.trim(u8, line[colon + 1 ..], " \t");
        const seconds = std.fmt.parseInt(u64, raw, 10) catch return null;
        const ms = std.math.mul(u64, seconds, std.time.ms_per_s) catch return null;
        return @min(ms, max_retry_after_ms);
    }
    return null;
}

test "only weather-shaped statuses are retried" {
    try std.testing.expect(retryableStatus(.too_many_requests));
    try std.testing.expect(retryableStatus(.bad_gateway));
    try std.testing.expect(retryableStatus(.service_unavailable));
    try std.testing.expect(!retryableStatus(.bad_request));
    try std.testing.expect(!retryableStatus(.unauthorized));
    try std.testing.expect(!retryableStatus(.not_found));
}

// The provider reading a whole request is the point at which the turn behind
// it may already have been generated and billed. Resending it buys a second
// billable completion for one turn, so a lost head ends the run instead, while
// the two failures that happen before the request is readable on the far end
// are the provider's weather and are still retried.
test "a turn is resent only while the provider cannot have read it" {
    try std.testing.expect(worthAnotherAttempt(.opened));
    try std.testing.expect(worthAnotherAttempt(.sending));
    try std.testing.expect(!worthAnotherAttempt(.head));
}

test "backoff doubles, caps, and never overflows an attempt counter" {
    try std.testing.expectEqual(@as(u64, 1000), backoffMs(0));
    try std.testing.expectEqual(@as(u64, 1000), backoffMs(1));
    try std.testing.expectEqual(@as(u64, 2000), backoffMs(2));
    try std.testing.expectEqual(@as(u64, 4000), backoffMs(3));
    try std.testing.expectEqual(max_backoff_ms, backoffMs(1000));
}

// A rate limit names the wait it wants. Retrying on this run's own 1 s/2 s/4 s
// schedule instead is a second, third and fourth refusal from a provider that
// asked for thirty seconds, and every one of them is billed as a request.
// A provider that asks for longer than the run has left is weather the run
// cannot wait out: sleeping the full ask puts it to bed inside the caller's
// timeout, which is what --budget exists to stop, and retrying early is the
// second billable refusal the header was there to prevent. So the decision is
// the budget's.
//
// The two ends only, because std.testing.io's clock does not advance and a
// deadline between them is arithmetic that needs a real one.
test "a wait the budget cannot cover is not taken" {
    // No budget: every wait is affordable, which is the behaviour for a run
    // nobody put a ceiling on. This is the two-minute ask and the run's own
    // schedule, and both are taken exactly as before.
    const unbounded: budget_mod.Budget = .{};
    try std.testing.expectEqual(@as(?u64, max_retry_after_ms), unbounded.affordableWaitMs(std.testing.io, max_retry_after_ms));
    try std.testing.expectEqual(@as(?u64, backoffMs(2)), unbounded.affordableWaitMs(std.testing.io, backoffMs(2)));

    // Spent: nothing is affordable, not even a millisecond, so no attempt is
    // made and the run ends with the reason already on stderr.
    const spent: budget_mod.Budget = .{ .deadline_ns = 0 };
    try std.testing.expectEqual(@as(?u64, null), spent.affordableWaitMs(std.testing.io, 1));
    try std.testing.expectEqual(@as(?u64, null), spent.affordableWaitMs(std.testing.io, backoffMs(0)));
    try std.testing.expectEqual(@as(?u64, null), spent.affordableWaitMs(std.testing.io, max_retry_after_ms));
}

test "a Retry-After header sets the wait, and only a wait worth taking" {
    const head =
        "HTTP/1.1 429 Too Many Requests\r\n" ++
        "content-type: application/json\r\n" ++
        "retry-after: 30\r\n" ++
        "content-length: 0\r\n\r\n";
    try std.testing.expectEqual(@as(?u64, 30_000), retryAfterMs(head));

    // The header's name is case-insensitive, and the value carries the spaces
    // a real server puts around it.
    const sloppy = "HTTP/1.1 503 Service Unavailable\r\nRetry-After:   7  \r\n\r\n";
    try std.testing.expectEqual(@as(u64, 7000), retryAfterMs(sloppy));

    // A wait longer than this run will sit out falls back to the schedule
    // rather than stalling the turn for an hour.
    const forever = "HTTP/1.1 429 Too Many Requests\r\nretry-after: 3600\r\n\r\n";
    try std.testing.expectEqual(@as(?u64, max_retry_after_ms), retryAfterMs(forever));

    // Absent, and the forms this run cannot read, are all the backoff's
    // business rather than a guess.
    try std.testing.expectEqual(@as(?u64, null), retryAfterMs("HTTP/1.1 429 Too Many Requests\r\ncontent-length: 0\r\n\r\n"));
    try std.testing.expectEqual(@as(?u64, null), retryAfterMs("HTTP/1.1 429 Too Many Requests\r\nretry-after: Wed, 21 Oct 2026 07:28:00 GMT\r\n\r\n"));
    try std.testing.expectEqual(@as(?u64, null), retryAfterMs("HTTP/1.1 429 Too Many Requests\r\nretry-after: soon\r\n\r\n"));
    // A count past what the multiply holds is a header this cannot read, not a
    // wrap into a short wait.
    try std.testing.expectEqual(@as(?u64, null), retryAfterMs("HTTP/1.1 429 Too Many Requests\r\nretry-after: 99999999999999999999\r\n\r\n"));
}
