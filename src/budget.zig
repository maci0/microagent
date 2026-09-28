//! The run's time budget, as an instant on the monotonic clock the loop reads.
//!
//! A leaf module, like `net` and `chat`: it imports nothing from the rest of
//! the program, so the agent loop and the retry policy can both hold a budget
//! without either of them importing the other.

const std = @import("std");
const Io = std.Io;

/// The run's time budget as an instant on the monotonic clock the loop already
/// reads. Every part of a turn asks this, not just the top of the loop: a
/// provider that is slow rather than broken hands the loop one long turn, and a
/// budget only checked between turns is a budget that provider ignores, which
/// is the run being killed in the middle of the turn the budget exists to avoid.
pub const Budget = struct {
    /// Nanoseconds on the awake clock, or null when no budget was set.
    deadline_ns: ?i96 = null,

    pub fn of(started_ns: i96, seconds: ?u64) Budget {
        const s = seconds orelse return .{};
        return .{ .deadline_ns = started_ns + @as(i96, s) * std.time.ns_per_s };
    }

    pub fn expired(self: Budget, io: Io) bool {
        const d = self.deadline_ns orelse return false;
        return Io.Timestamp.now(io, .awake).nanoseconds >= d;
    }

    /// Milliseconds left on the budget, or null when there is no budget. Zero
    /// means expired; callers that only care about that use `expired`.
    pub fn remainingMs(self: Budget, io: Io) ?u64 {
        const d = self.deadline_ns orelse return null;
        const now = Io.Timestamp.now(io, .awake).nanoseconds;
        if (now >= d) return 0;
        return @intCast(@divTrunc(d - now, std.time.ns_per_ms));
    }

    /// The ceiling a tool's own deadline may not pass, or null when the run
    /// set no budget. The floor stops a nearly-spent budget from handing a tool
    /// a zero timeout, which fails instantly and reads as a broken tool rather
    /// than a spent budget.
    pub fn toolCeilingMs(self: Budget, io: Io) ?u64 {
        const left = self.remainingMs(io) orelse return null;
        return @max(left, tool_timeout_floor_ms);
    }

    /// Whether this run can afford to wait `want_ms` before its next attempt,
    /// and how long it may wait. Null means it cannot, and the caller must not
    /// make the attempt: a retry taken after a refusal the provider is still
    /// refusing is a second billable refusal, and one taken by sitting out the
    /// wait is a turn that never arrives.
    ///
    /// A provider asking for two minutes is weather and sitting it out is the
    /// right answer to it. Sitting it out inside a caller's per-review timeout
    /// is not: the run is killed mid-sleep with nothing to show for it, which
    /// is the one thing the budget exists to prevent. So the wait is taken only
    /// when the budget covers it.
    pub fn affordableWaitMs(self: Budget, io: Io, want_ms: u64) ?u64 {
        const left = self.remainingMs(io) orelse return want_ms;
        if (want_ms >= left) return null;
        return want_ms;
    }

    /// The same budget with `seconds` more to run. The final push is the one
    /// turn that is allowed past the budget, and the grace is what keeps that
    /// turn bounded too: it lands or it is cut off with a reason, never left
    /// waiting on a provider that stopped answering.
    pub fn withGraceNs(self: Budget, seconds: u64) Budget {
        const d = self.deadline_ns orelse return self;
        return .{ .deadline_ns = d + @as(i96, seconds) * std.time.ns_per_s };
    }
};

/// How long the final turn may run past the budget. It exists to turn what the
/// model has already read into one edit, which is a few tool calls, not a
/// fresh investigation.
pub const final_push_grace_s: u64 = 300;

/// The shortest a tool timeout may be cut to, even with the budget spent: a
/// zero timeout would fail before the tool could even start.
pub const tool_timeout_floor_ms: u64 = 5_000;

test "a tool timeout is cut to what is left of the budget" {
    const io = std.testing.io;
    const now = Io.Timestamp.now(io, .awake).nanoseconds;

    // No budget: every tool keeps the timeout it asked for, so there is no
    // ceiling to hand one.
    try std.testing.expectEqual(@as(?u64, null), (Budget{}).remainingMs(io));
    try std.testing.expectEqual(@as(?u64, null), (Budget{}).toolCeilingMs(io));

    // Ten minutes of budget left: a shorter request is untouched, a longer one
    // is cut, because it cannot finish before the deadline it would cross. The
    // ceiling is the only thing a tool's own timeout is measured against, so it
    // is the only thing asserted here; the min is `boundedMs`'s, and that it
    // does the min is the tool's own test.
    const fresh = Budget.of(now, 600);
    const left = fresh.toolCeilingMs(io).?;
    try std.testing.expect(left <= 600_000 and left > 599_000);

    // Nearly spent: the floor, but never zero, which would fail before the tool
    // started and read as a broken tool rather than a spent budget.
    const nearly = Budget{ .deadline_ns = now + 2 * std.time.ns_per_s };
    try std.testing.expectEqual(tool_timeout_floor_ms, nearly.toolCeilingMs(io).?);

    // Spent: remaining is zero, and the ceiling still leaves the floor.
    const spent = Budget{ .deadline_ns = now - 1 };
    try std.testing.expectEqual(@as(u64, 0), spent.remainingMs(io).?);
    try std.testing.expectEqual(tool_timeout_floor_ms, spent.toolCeilingMs(io).?);
    try std.testing.expect(spent.expired(io));
}

// The budget is a deadline, not a turn counter. Checked only at the top of the
// loop, a provider that is slow rather than broken hands the run one long turn
// and the budget is never asked again, which is the run being killed in the
// middle of the turn the budget exists to avoid.
test "the time budget is a deadline the turn itself is held to" {
    const io = std.testing.io;
    const now = Io.Timestamp.now(io, .awake).nanoseconds;

    // No budget set is a budget that never runs out, at any point in a turn.
    const none = Budget.of(now, null);
    try std.testing.expect(!none.expired(io));

    const short = Budget.of(now, 1);
    try std.testing.expect(!short.expired(io));

    // A deadline already in the past is spent, wherever it is read.
    const spent = Budget.of(now, 0);
    try std.testing.expect(spent.expired(io));
    const long_gone = Budget.of(now - std.time.ns_per_s * 10, 1);
    try std.testing.expect(long_gone.expired(io));

    // The final push is the one turn allowed past the budget, and the grace is
    // what keeps that turn bounded too: the grace moves the deadline later, so
    // the push is not already over before it starts.
    const push = short.withGraceNs(final_push_grace_s);
    try std.testing.expect(!push.expired(io));
    const push_later = spent.withGraceNs(final_push_grace_s);
    try std.testing.expect(!push_later.expired(io));
    // Grace on a run with no budget is still no budget.
    try std.testing.expect(!none.withGraceNs(final_push_grace_s).expired(io));
}
