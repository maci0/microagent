//! What the four modules that touch the machine share: the CA-bundle escape
//! hatch, the home directory and the variables read out of the environment, a
//! deadline, the two output sinks (stderr for notes and stdout for the
//! answers a caller parses), the path a write through a symlink really lands on,
//! the two budgets a value read out of the environment or off the wire is held
//! to, the line framing a streamed body is cut on, the retry policy both
//! network paths answer with, and the reading of an HTTP date off the wire,
//! which is wire format rather than any one caller's policy.
//!
//! A leaf module over the other leaf: it imports `chat` and nothing else, so
//! the agent run, the session log and `update` can each use it without
//! importing one another. `chat` is imported for the one escaping the notes
//! here need, which is the escaping the rest of the program uses. The argv the
//! two command-line fuzzers take is `fuzzargv`, beside this and not here.

const std = @import("std");
const Io = std.Io;

const chat = @import("chat.zig");

/// What a wrapper that reads its environment out of a file leaves around every
/// value it exported. It is spelled here, in the module every reader imports,
/// so trimming an environment value has one set behind it rather than one per
/// reader.
pub const env_surrounding = " \t\r\n";

/// How much of a value a message quotes back, bounded on the bytes that come
/// out rather than the bytes that went in, so a value of control characters
/// cannot cost a line several times its length. The agent run and `update` both
/// quote untrusted values into a diagnostic, and one budget is what keeps the
/// two from drifting apart.
pub const quoted_value_bytes: usize = 80;

/// Points the TLS client at a PEM file when one was named. Many container
/// images (bare ubuntu, distroless) ship no ca-certificates at all, and the
/// client's own rescan then fails with TlsInitializationFailed before a single
/// request is sent. A path that cannot be read is a warning, not a failure: the
/// client falls back to scanning the system store.
pub fn loadCaBundle(
    client: *std.http.Client,
    io: Io,
    gpa: std.mem.Allocator,
    path: []const u8,
    arena: std.mem.Allocator,
) void {
    if (path.len == 0) return;
    const now = Io.Clock.real.now(io);
    const before = client.ca_bundle.map.count();
    // The bundle is read through the path form that takes the directory, not the
    // one that asserts an absolute path: `std.fs.path.resolve` does not make a
    // path absolute, so `MICROAGENT_CA_BUNDLE=ca.pem` reached an API that
    // asserts and took the process down with a panic.
    const added = if (std.fs.path.isAbsolute(path))
        client.ca_bundle.addCertsFromFilePathAbsolute(gpa, io, now, path)
    else
        client.ca_bundle.addCertsFromFilePath(gpa, io, now, Io.Dir.cwd(), path);
    added catch |err| {
        // The path is a variable the operator set, and both notes below name
        // it: a value that is not text, or one carrying an escape sequence,
        // has to be written as the characters it is rather than acted on.
        note(io, arena, "microagent: cannot read CA bundle {s} ({s}); scanning the system store instead\n", .{ chat.safeTextAll(arena, path), @errorName(err) });
        return;
    };
    // A file that is readable but holds no PEM parses as zero certificates
    // rather than as an error, and marking the bundle populated then leaves the
    // client with an empty trust store: every request fails as if the machine
    // shipped no ca-certificates, and the bundle the operator named is never
    // mentioned. The system store is the documented fallback, so take it.
    if (client.ca_bundle.map.count() == before) {
        note(io, arena, "microagent: CA bundle {s} holds no certificates; scanning the system store instead\n", .{chat.safeTextAll(arena, path)});
        return;
    }
    // Non-null `now` is how the client knows the bundle is already populated.
    client.now = now;
}

/// Bytes on stderr, which is where gauntlet shows harness notes. A closed
/// stream costs the run nothing: the reader left, it is not a fault.
pub fn writeErr(io: Io, bytes: []const u8) void {
    Io.File.stderr().writeStreamingAll(io, bytes) catch {};
}

/// Bytes on stdout: the model's own words and the one line a caller parses.
///
/// The error is the caller's, because a stream that refuses the bytes is a
/// different fault depending on what they were: a full disk or a closed pipe
/// means the answer this run was asked for never arrives, which is a run that
/// failed rather than one that finished. Text nobody is waiting on (the help
/// text, `--version`) may drop it; the model's own words may not.
pub fn writeOut(io: Io, bytes: []const u8) !void {
    try Io.File.stdout().writeStreamingAll(io, bytes);
}

/// A line on stderr, which is where gauntlet shows harness notes; stdout stays
/// the model's own words and the usage line.
pub fn note(io: Io, arena: std.mem.Allocator, comptime fmt: []const u8, args: anytype) void {
    const msg = std.fmt.allocPrint(arena, fmt, args) catch return;
    writeErr(io, msg);
}

/// Where a CA bundle is named, for the agent run and for `update` alike: the
/// project's own variable first, then the one the system trust store tooling
/// already uses. Empty means no bundle was named, and so does a value that is
/// nothing but whitespace, which is not a path any filesystem holds.
pub fn caBundlePath(env: *const std.process.Environ.Map) []const u8 {
    for ([_][]const u8{ "MICROAGENT_CA_BUNDLE", "SSL_CERT_FILE" }) |name| {
        const p = std.mem.trim(u8, env.get(name) orelse continue, env_surrounding);
        if (p.len > 0) return p;
    }
    return "";
}

/// `$HOME`, trimmed, or null when it is not set or holds nothing but
/// whitespace. Every path built under it is a path no filesystem holds when
/// the value carries the newline a wrapper that populates the environment from
/// a file left on it, and that is the same wrapper `envValue` exists for.
/// Empty reads as unset rather than as a root-relative path, so a `HOME=` left
/// behind by a script cannot turn `$HOME/.microagent/config.toml` into
/// `/.microagent/config.toml`.
pub fn homeDir(env: *const std.process.Environ.Map) ?[]const u8 {
    const v = std.mem.trim(u8, env.get("HOME") orelse return null, env_surrounding);
    return if (v.len == 0) null else v;
}

/// The file `path` names once every symlink on it is followed, which is the
/// file opening `path` would have written to and the only one a rename may
/// replace.
///
/// Both callers need it: `write` and `edit` so a rewrite through a link
/// replaces the real file and leaves the link a link, and `update` so the
/// binary is replaced rather than the link pointing at it. It is written once
/// here because the answer is path arithmetic, and path arithmetic spelled
/// inline is where a hardcoded `/` hides: the join goes through
/// `std.fs.path`, so it uses the separator the target actually has.
///
/// The whole chain is followed, not only the first link. A chain is ordinary on
/// both platforms this ships to: a version manager pointing at a per-version
/// binary, a `current`-style symlink pointing at a release symlink. Resolving
/// one link and stopping there replaces the *middle* of the chain with a
/// regular file, so the write lands on a copy while the binary the user runs is
/// the file that was never written, and both links are destroyed doing it.
///
/// `name_buf` receives each link's own bytes, and `cur_buf` and `next_buf` the
/// composed path; the walk alternates between the last two, because the link
/// read at each step overwrites `name_buf` and the path being resolved must
/// survive it. All three belong to the caller, and the returned slice is one of
/// `cur_buf` and `next_buf`, or `path` itself when `path` is not a link.
pub fn resolveSymlinkTarget(
    io: Io,
    dir: Io.Dir,
    path: []const u8,
    name_buf: []u8,
    cur_buf: []u8,
    next_buf: []u8,
) ![]const u8 {
    var spare = cur_buf;
    var into = next_buf;
    var cur: []const u8 = path;
    var depth: usize = 0;
    while (depth < max_symlink_depth) : (depth += 1) {
        const n = dir.readLink(io, cur, name_buf) catch |err| switch (err) {
            error.NotLink, error.FileNotFound => return cur,
            else => |e| return e,
        };
        const link = name_buf[0..n];
        // A relative link is read against the directory holding the link, not
        // against the process's working directory. A bare name has no
        // directory, and the caller handed in the directory that name is
        // already relative to.
        const next = if (std.fs.path.isAbsolute(link))
            try copyInto(into, link)
        else if (std.fs.path.dirname(cur)) |dir_end|
            try joinOnto(into, dir_end, link)
        else
            try copyInto(into, link);
        const written = spare;
        spare = into;
        into = written;
        cur = next;
    }
    return error.SymlinkLoop;
}

/// How many links a path may hold before the answer is a cycle rather than a
/// file. Two links naming each other, or a link into a directory of links, would
/// otherwise spin here; the kernel refuses a chain this long for the same
/// reason, so a path that reaches it is not one any of these platforms opens.
const max_symlink_depth = 32;

fn copyInto(buf: []u8, bytes: []const u8) error{NameTooLong}![]const u8 {
    if (bytes.len > buf.len) return error.NameTooLong;
    @memcpy(buf[0..bytes.len], bytes);
    return buf[0..bytes.len];
}

fn joinOnto(buf: []u8, dir_end: []const u8, link: []const u8) error{NameTooLong}![]const u8 {
    const n = dir_end.len + 1 + link.len;
    if (n > buf.len) return error.NameTooLong;
    @memcpy(buf[0..dir_end.len], dir_end);
    buf[dir_end.len] = std.fs.path.sep;
    @memcpy(buf[dir_end.len + 1 ..][0..link.len], link);
    return buf[0..n];
}

/// The index of the next newline in `pending`, or null while the line it would
/// end is still arriving. `scanned` is how much of `pending` has already been
/// searched, so a record longer than one read is not searched for again from the
/// front each time the next piece of it lands: that made splitting a long
/// record quadratic in its length, once for a completion frame and once for a
/// file line. The caller drops the bytes it consumed and lowers `scanned` by the
/// same amount.
pub fn nextLineEnd(pending: []const u8, scanned: *usize) ?usize {
    const at = std.mem.indexOfScalarPos(u8, pending, scanned.*, '\n') orelse {
        scanned.* = pending.len;
        return null;
    };
    scanned.* = at + 1;
    return at;
}

// The splitter three call sites share, so the `scanned` bookkeeping is pinned
// here rather than only through them. An off-by-one either leaves a caller's
// `pending` growing without bound (a `scanned` that is not lowered past the
// bytes already consumed) or drops a line that has already arrived (a `scanned`
// that runs past it).
test "the line splitter resumes where the last call stopped, and does not skip a line" {
    var scanned: usize = 0;
    // Nothing to return: the whole buffer has been searched, which is the
    // reading a caller appends to without rescanning.
    try std.testing.expectEqual(@as(?usize, null), nextLineEnd("", &scanned));
    try std.testing.expectEqual(@as(usize, 0), scanned);
    try std.testing.expectEqual(@as(?usize, null), nextLineEnd("abc", &scanned));
    try std.testing.expectEqual(@as(usize, 3), scanned);

    // A line ending in the first byte, and one ending in the last, so neither
    // end of the buffer is assumed.
    scanned = 0;
    try std.testing.expectEqual(@as(?usize, 0), nextLineEnd("\nrest", &scanned));
    try std.testing.expectEqual(@as(usize, 1), scanned);
    scanned = 0;
    try std.testing.expectEqual(@as(?usize, 3), nextLineEnd("abc\n", &scanned));
    try std.testing.expectEqual(@as(usize, 4), scanned);

    // Every line of a three-line buffer, in order, with no line skipped and
    // none handed back twice.
    const text = "one\ntwo\nthree\n";
    scanned = 0;
    var lines: [4]usize = undefined;
    var n: usize = 0;
    while (nextLineEnd(text, &scanned)) |at| {
        try std.testing.expect(n < lines.len);
        lines[n] = at;
        n += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqualSlices(usize, &.{ 3, 7, 13 }, lines[0..3]);
    try std.testing.expectEqual(text.len, scanned);

    // The caller's half of the contract: a line consumed and its bytes dropped
    // resumes at the same character of the record, so a line split across two
    // reads is found once it is whole and not before.
    var pending: std.ArrayList(u8) = .empty;
    defer pending.deinit(std.testing.allocator);
    try pending.appendSlice(std.testing.allocator, "data: fir");
    scanned = 0;
    try std.testing.expectEqual(@as(?usize, null), nextLineEnd(pending.items, &scanned));
    try pending.appendSlice(std.testing.allocator, "st\ndata: second\n");
    const at = nextLineEnd(pending.items, &scanned).?;
    try std.testing.expectEqualStrings("data: first", pending.items[0..at]);
    const consumed = at + 1;
    std.mem.copyForwards(u8, pending.items, pending.items[consumed..]);
    pending.items.len -= consumed;
    scanned -= consumed;
    try std.testing.expectEqualStrings("data: second\n", pending.items);
    try std.testing.expectEqual(@as(usize, 0), scanned);
    try std.testing.expectEqual(@as(?usize, 12), nextLineEnd(pending.items, &scanned));
    try std.testing.expectEqual(@as(?usize, null), nextLineEnd(pending.items, &scanned));
}

/// A monotonic duration for `Io.Timeout`, from milliseconds. A tool deadline
/// is named in milliseconds in every tool, so the conversion is spelled once
/// here rather than at each call site.
pub fn durationMs(ms: u64) Io.Timeout {
    return .{ .duration = .{ .raw = .{ .nanoseconds = ms *| std.time.ns_per_ms }, .clock = .awake } };
}

/// The retry schedule both network paths use: the wait before the first retry,
/// doubled per attempt. The doubling count and the base are shared, the cap is
/// the caller's because the two waits are not the same promise (the run's is
/// sixty seconds, `update`'s thirty), and a policy spelled twice is a policy
/// that has already drifted once.
pub const retry_backoff_base_ms: u64 = 1000;
/// Enough doublings to reach any cap in use; the cap is what bounds the wait.
pub const retry_backoff_shift: u32 = 6;

/// The wait before attempt `attempt + 1`. Saturating, because the shift and
/// the multiply both overflow long before a u32 attempt counter does, and a
/// checked build panicking where a release build wraps is not a property to
/// want in a sleep. `attempt` counts attempts already made, so 0 and 1 both
/// wait the base.
pub fn retryBackoffMs(attempt: u32, max_wait_ms: u64) u64 {
    const shift: u6 = @intCast(@min(attempt -| 1, retry_backoff_shift));
    return @min(retry_backoff_base_ms *| (@as(u64, 1) << shift), max_wait_ms);
}

/// Statuses worth another attempt: the server is busy, not the request wrong.
/// A 409 is in the set because that is how the OpenAI-shaped providers spell
/// "this turn is already being worked on"; a GET that draws one is no more
/// wrong than the POST that does. 404 is not: it names something that is not
/// published, and asking again for the same name changes nothing.
pub fn retryableStatus(status: std.http.Status) bool {
    return switch (@intFromEnum(status)) {
        408, 409, 425, 429 => true,
        else => @intFromEnum(status) >= 500,
    };
}

/// Whether a transport failure is worth another attempt. The set is the
/// failures a second connection can answer: the name did not resolve, the
/// route to it is down, the connection was refused, reset or dropped, the TLS
/// handshake did not complete. A failed allocation repeats, and everything
/// else the client can name is a decision it or the URL already made, so three
/// attempts separated by a backoff only delay the same refusal.
///
/// What a request had already put on the wire is the caller's question, not
/// this one's: the run declines to resend a turn the provider may have billed
/// (`worthAnotherAttempt` there), which `update` has no reason to ask since
/// every request here is a GET with no body worth generating from.
pub fn transientTransportError(err: anyerror) bool {
    return switch (err) {
        error.TemporaryNameServerFailure,
        error.NameServerFailure,
        error.UnknownHostName,
        error.HostLacksNetworkAddresses,
        error.NetworkDown,
        error.ConnectionRefused,
        error.ConnectionResetByPeer,
        error.ConnectionAborted,
        error.BrokenPipe,
        error.ConnectionTimedOut,
        error.Timeout,
        error.TlsInitializationFailed,
        => true,
        else => false,
    };
}

/// The month names in the order `daysInMonth` counts them, and the form a
/// `Retry-After` date spells them in. Exported so a header built for a test
/// names its month the way the parser reads one, rather than a second spelling
/// of the twelve that can drift from it.
pub const calendar_months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

/// An IMF-fixdate (`Sun, 06 Nov 1994 08:49:37 GMT`) as seconds since the Unix
/// epoch, or null for anything else.
///
/// It lives here rather than with the retry policy that reads it, because it is
/// a value off the wire and nothing about it is policy: the agent run's
/// `Retry-After` and anything else parsing the same header want the same
/// arithmetic, and a second copy of a calendar is a second set of century rules.
///
/// The day of the week it names is not checked against the day of the month:
/// it is redundant, a server whose clock is a second out from the run's writes
/// it wrong, and a run that refused a deadline over it would refuse a correct
/// one. The obsolete RFC 850 and asctime forms are not read either: RFC 9110
/// has every sender use this one, and a value this does not read falls back to
/// the backoff schedule, which is where every unreadable value goes.
pub fn httpDateEpochSeconds(raw: []const u8) ?i64 {
    const comma = std.mem.indexOfScalar(u8, raw, ',') orelse return null;
    var parts = std.mem.tokenizeScalar(u8, raw[comma + 1 ..], ' ');
    const day_text = parts.next() orelse return null;
    const month = monthFromName(parts.next() orelse return null) orelse return null;
    const year = httpDateYear(parts.next() orelse return null) orelse return null;
    const time_text = parts.next() orelse return null;
    const zone = parts.next() orelse return null;
    if (parts.next() != null) return null;
    // The zone is spelled out and checked rather than assumed: the epoch these
    // seconds are counted from is UTC, and reading a local time as UTC would
    // shift every wait by the reader's offset.
    if (!std.mem.eql(u8, zone, "GMT")) return null;

    var clock = std.mem.splitScalar(u8, time_text, ':');
    const hour = std.fmt.parseInt(i64, clock.next() orelse return null, 10) catch return null;
    const minute = std.fmt.parseInt(i64, clock.next() orelse return null, 10) catch return null;
    const second = std.fmt.parseInt(i64, clock.next() orelse return null, 10) catch return null;
    if (clock.next() != null) return null;

    if (year < 1 or year > http_date_year_max) return null;

    const day = std.fmt.parseInt(u32, day_text, 10) catch return null;
    if (day == 0 or day > daysInMonth(year, month)) return null;
    if (hour < 0 or hour > 23 or minute < 0 or minute > 59 or second < 0 or second > 60) return null;

    return daysFromCivil(year, month, day) * @as(i64, std.time.s_per_day) +
        hour * std.time.s_per_hour + minute * std.time.s_per_min + second;
}

/// The years an IMF-fixdate can spell: its year field is four digits wide, and
/// RFC 9110 has no longer one. The bound is load-bearing rather than pedantic.
/// The count below is days times 86 400, and days grows with the year, so a
/// year a sender has no way of meaning (a gateway that writes the field from a
/// 64-bit counter) puts that multiply past the 64 bits it has: the header then
/// reads as a date in the past or the far future by whatever the wrap left
/// behind, and the wait it asks for is the opposite of the one it named.
const http_date_year_max: i64 = 9999;

/// The year an IMF-fixdate names, or null when it is not the four digits
/// RFC 9110 spells it as.
///
/// The width is the check, and it is the arithmetic's to have: the year is
/// multiplied out into days and then into seconds below, and a year read as
/// an unbounded `i64` reaches those products with nothing to stop it.
/// `Retry-After: Sun, 06 Nov 9223372036854775807 08:49:37 GMT` overflowed the
/// day count, panicking a checked build and wrapping a release one into a
/// deadline the run then sat out for no reason at all. Four digits is what the
/// grammar allows and what every sender sends, so a longer one is not a year
/// this header means and the wait falls back to the backoff schedule, which is
/// where every unreadable value goes.
fn httpDateYear(text: []const u8) ?i64 {
    if (text.len != http_date_year_digits) return null;
    for (text) |c| if (!std.ascii.isDigit(c)) return null;
    return std.fmt.parseInt(i64, text, 10) catch null;
}

/// The digits RFC 9110 gives the year in an IMF-fixdate, so a header naming
/// any other number of them is not one this parser reads.
const http_date_year_digits = 4;

/// The month a header's three-letter name names, 1 through 12, or null.
fn monthFromName(name: []const u8) ?u32 {
    for (calendar_months, 1..) |candidate, number| {
        if (std.ascii.eqlIgnoreCase(name, candidate)) return @intCast(number);
    }
    return null;
}

/// Whether `year` is a leap year under the rule the epoch counts: divisible by
/// four, and not by a hundred that is not by four hundred.
fn isLeapYear(year: i64) bool {
    if (@mod(year, 4) != 0) return false;
    if (@mod(year, 100) != 0) return true;
    return @mod(year, 400) == 0;
}

/// How many days `month` of `year` has, the leap day included. A month the
/// name cannot have is zero, so a day past the end is refused by the caller
/// rather than rolling into the next one.
fn daysInMonth(year: i64, month: u32) u32 {
    const lengths = [_]u32{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    if (month == 0 or month > lengths.len) return 0;
    if (month == 2 and isLeapYear(year)) return 29;
    return lengths[month - 1];
}

/// Days from 1970-01-01 to `year`-`month`-`day`, by the civil-date algorithm
/// that shifts the year to start in March so the leap day lands last.
///
/// Every day the epoch counts is one this gets right, leap years and century
/// years included, with no table of month lengths and no rule of its own to get
/// wrong: `daysFromCivil(1970, 1, 1)` is 0, and the arithmetic never passes
/// through a day it would have to skip.
fn daysFromCivil(year: i64, month: u32, day: u32) i64 {
    const shifted = year -| @as(i64, if (month <= 2) @intCast(1) else 0);
    const era = @divFloor(shifted, 400);
    const year_of_era = shifted - era * 400; // 0 through 399
    const month_of_era = @as(i64, month) + (if (month > 2) @as(i64, -3) else 9); // 0 through 11, March first
    const day_of_year = @divTrunc(153 * month_of_era + 2, 5) + @as(i64, day) - 1; // 0 through 365
    const day_of_era = year_of_era * 365 + @divTrunc(year_of_era, 4) - @divTrunc(year_of_era, 100) + day_of_year;
    return era * 146097 + day_of_era - 719468;
}

test "the CA bundle comes from the project's variable first, then the system one" {
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    try std.testing.expectEqualStrings("", caBundlePath(&env));

    try env.put("SSL_CERT_FILE", "/etc/ssl/certs/ca-certificates.crt");
    try std.testing.expectEqualStrings("/etc/ssl/certs/ca-certificates.crt", caBundlePath(&env));

    try env.put("MICROAGENT_CA_BUNDLE", "/tmp/bundle.pem");
    try std.testing.expectEqualStrings("/tmp/bundle.pem", caBundlePath(&env));

    // An empty value is not a bundle named; the next one in the chain answers.
    try env.put("MICROAGENT_CA_BUNDLE", "");
    try std.testing.expectEqualStrings("/etc/ssl/certs/ca-certificates.crt", caBundlePath(&env));

    // A wrapper that exports a path read from a file carries the newline that
    // file ended with, and a path with one is a file no filesystem holds.
    try env.put("MICROAGENT_CA_BUNDLE", "/tmp/bundle.pem\n");
    try std.testing.expectEqualStrings("/tmp/bundle.pem", caBundlePath(&env));
    try env.put("MICROAGENT_CA_BUNDLE", "  ");
    try std.testing.expectEqualStrings("/etc/ssl/certs/ca-certificates.crt", caBundlePath(&env));
}

test "a CA bundle that names no certificate leaves the client scanning the system store" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    // No bundle named is not a bundle to read, and the client is left exactly
    // as it was.
    loadCaBundle(&client, io, gpa, "", arena);
    try std.testing.expect(client.now == null);
    try std.testing.expectEqual(@as(usize, 0), client.ca_bundle.map.count());

    // A path that is not there: a warning, not a failure, so the run scans the
    // system store rather than dying on the first request.
    loadCaBundle(&client, io, gpa, "/nonexistent/ca-bundle.pem", arena);
    try std.testing.expect(client.now == null);
    try std.testing.expectEqual(@as(usize, 0), client.ca_bundle.map.count());

    // A file that is readable but holds no certificate parses as zero
    // certificates rather than as an error, and this is the case a missing
    // guard lets through: `now` is the flag the client reads to decide the
    // store is already populated, so setting it over an empty bundle skips the
    // system rescan and leaves every request failing on a machine that ships
    // certificates.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "empty.pem", .data = "# not a certificate\n" });

    // The same file named relatively goes through the working directory, which
    // is the form a wrapper exporting a relative path hands over; the guard has
    // to be the same one on that path.
    const relative = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}/empty.pem", .{tmp.sub_path});
    loadCaBundle(&client, io, gpa, relative, arena);
    try std.testing.expect(client.now == null);
    try std.testing.expectEqual(@as(usize, 0), client.ca_bundle.map.count());

    // And named absolutely, which takes the other of the two reads.
    var file_buf: [std.fs.max_path_bytes]u8 = undefined;
    const absolute = file_buf[0..try tmp.dir.realPathFile(io, "empty.pem", &file_buf)];
    loadCaBundle(&client, io, gpa, absolute, arena);
    try std.testing.expect(client.now == null);
    try std.testing.expectEqual(@as(usize, 0), client.ca_bundle.map.count());
}

test "the home directory is trimmed, and an empty one is no home" {
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    try std.testing.expect(homeDir(&env) == null);

    try env.put("HOME", "/home/me");
    try std.testing.expectEqualStrings("/home/me", homeDir(&env).?);

    // The newline a wrapper exports from a file, on the directory every
    // default path is built under.
    try env.put("HOME", "/home/me\n");
    try std.testing.expectEqualStrings("/home/me", homeDir(&env).?);

    // Empty is unset, not a root-relative path: `HOME=` left behind by a
    // script must not turn ~/.microagent/config.toml into /.microagent/...
    try env.put("HOME", "");
    try std.testing.expect(homeDir(&env) == null);
    try env.put("HOME", "  \r\n");
    try std.testing.expect(homeDir(&env) == null);
}

/// `resolveSymlinkTarget` over the three caller-owned buffers the tests below
/// each declare, so a call site reads as the one path under test rather than as
/// its scratch.
fn resolveForTest(dir: std.Io.Dir, path: []const u8, name: []u8, a: []u8, b: []u8) ![]const u8 {
    return resolveSymlinkTarget(std.testing.io, dir, path, name, a, b);
}

test "a write target follows a symlink, relative or absolute" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "real", .data = "old" });
    try tmp.dir.createDirPath(std.testing.io, "sub");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "sub/real2", .data = "old" });

    var name_buf: [std.fs.max_path_bytes]u8 = undefined;
    var cur_buf: [2 * std.fs.max_path_bytes]u8 = undefined;
    var next_buf: [2 * std.fs.max_path_bytes]u8 = undefined;

    // A link whose target is written relative to the link's own directory.
    // Resolving it against the working directory instead would name a file
    // that does not exist, and a rename to it would land beside the tree.
    try tmp.dir.symLink(std.testing.io, "real2", "sub/link", .{});
    const want_rel = try std.fs.path.join(std.testing.allocator, &.{ "sub", "real2" });
    defer std.testing.allocator.free(want_rel);
    try std.testing.expectEqualStrings(
        want_rel,
        try resolveForTest(tmp.dir, "sub/link", &name_buf, &cur_buf, &next_buf),
    );

    // An absolute link needs no join and must not be rewritten as one. The
    // temporary directory is reached through the working directory, so the
    // target is written as the absolute path that resolves to `real`.
    const abs = try std.fs.path.resolve(
        std.testing.allocator,
        &.{ ".zig-cache", "tmp", &tmp.sub_path, "real" },
    );
    defer std.testing.allocator.free(abs);
    try tmp.dir.symLink(std.testing.io, abs, "abs_link", .{});
    try std.testing.expectEqualStrings(
        abs,
        try resolveForTest(tmp.dir, "abs_link", &name_buf, &cur_buf, &next_buf),
    );

    // A path that is not a link is its own target, and a link with no
    // directory part is already relative to the directory the caller opened.
    try std.testing.expectEqualStrings(
        "real",
        try resolveForTest(tmp.dir, "real", &name_buf, &cur_buf, &next_buf),
    );
    try tmp.dir.symLink(std.testing.io, "real", "bare", .{});
    try std.testing.expectEqualStrings(
        "real",
        try resolveForTest(tmp.dir, "bare", &name_buf, &cur_buf, &next_buf),
    );
}

test "a write target follows a whole chain of symlinks, and refuses a cycle" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "real", .data = "old" });
    try tmp.dir.createDirPath(std.testing.io, "sub");

    var name_buf: [std.fs.max_path_bytes]u8 = undefined;
    var cur_buf: [2 * std.fs.max_path_bytes]u8 = undefined;
    var next_buf: [2 * std.fs.max_path_bytes]u8 = undefined;

    // A chain is ordinary: a `microagent` pointing at a per-version binary that
    // is itself a link into the tree the version was unpacked into. Stopping at
    // the first link answers `sub/mid`, and a rename there replaces a symlink
    // with a copy of the file rather than writing the one at the end of it.
    // The answer is the composed path and is not normalized, because the walk
    // does path arithmetic and not a filesystem lookup: `sub/../real` is the
    // name the last link spelled, and the caller opens it as it stands.
    try tmp.dir.symLink(std.testing.io, "../real", "sub/real2", .{});
    try tmp.dir.symLink(std.testing.io, "real2", "sub/mid", .{});
    try tmp.dir.symLink(std.testing.io, "sub/mid", "chain", .{});
    try std.testing.expectEqualStrings(
        "sub/../real",
        try resolveForTest(tmp.dir, "chain", &name_buf, &cur_buf, &next_buf),
    );

    // A chain that closes on itself names no file, and following it for ever
    // would hang the run that asked to write through it. The bound the kernel
    // uses is the one here, so a path that reaches it is one no filesystem on
    // either platform would open.
    try tmp.dir.symLink(std.testing.io, "loop_b", "loop_a", .{});
    try tmp.dir.symLink(std.testing.io, "loop_a", "loop_b", .{});
    try std.testing.expectError(
        error.SymlinkLoop,
        resolveForTest(tmp.dir, "loop_a", &name_buf, &cur_buf, &next_buf),
    );
}

test "a Retry-After date is read as the instant it names" {
    // The dates below are the ones the arithmetic has to be right about: the
    // epoch itself, a leap day, the day after a leap day, a century that is not
    // a leap year and one that is, and the boundary where a year starts at
    // month 13.
    try std.testing.expectEqual(@as(?i64, 0), httpDateEpochSeconds("Thu, 01 Jan 1970 00:00:00 GMT"));
    try std.testing.expectEqual(@as(?i64, 1), httpDateEpochSeconds("Thu, 01 Jan 1970 00:00:01 GMT"));
    try std.testing.expectEqual(@as(?i64, 86_399), httpDateEpochSeconds("Thu, 01 Jan 1970 23:59:59 GMT"));
    try std.testing.expectEqual(@as(?i64, 951_782_400), httpDateEpochSeconds("Tue, 29 Feb 2000 00:00:00 GMT"));
    try std.testing.expectEqual(@as(?i64, 951_955_199), httpDateEpochSeconds("Wed, 01 Mar 2000 23:59:59 GMT"));
    // 1900 is not a leap year under the rule (divisible by four, not by four
    // hundred), so 29 February 1900 is not a date and 28 February is.
    try std.testing.expectEqual(@as(?i64, null), httpDateEpochSeconds("Wed, 29 Feb 1900 00:00:00 GMT"));
    try std.testing.expectEqual(@as(?i64, -2_203_977_600), httpDateEpochSeconds("Wed, 28 Feb 1900 00:00:00 GMT"));
    // A day past the end of its month is refused rather than rolled into the
    // next one, which is a different date and a different wait.
    try std.testing.expectEqual(@as(?i64, null), httpDateEpochSeconds("Wed, 31 Apr 2026 00:00:00 GMT"));
    try std.testing.expectEqual(@as(?i64, null), httpDateEpochSeconds("Wed, 32 Jan 2026 00:00:00 GMT"));
    try std.testing.expectEqual(@as(?i64, null), httpDateEpochSeconds("Wed, 01 Jan 2026 24:00:00 GMT"));
    // The zone is spelled out: a date naming another one is not this run's
    // clock to read, and reading it as UTC would shift the wait by the offset.
    try std.testing.expectEqual(@as(?i64, null), httpDateEpochSeconds("Wed, 21 Oct 2026 07:28:00 CET"));
    try std.testing.expectEqual(@as(?i64, null), httpDateEpochSeconds("Wed, 21 Oct 2026 07:28:00"));
    try std.testing.expectEqual(@as(?i64, null), httpDateEpochSeconds("21 Oct 2026 07:28:00 GMT"));
    // A year the grammar does not spell as four digits is not a date to read.
    // An unbounded one reached the day arithmetic with nothing to stop it and
    // overflowed the epoch, which is a panic in a checked build and a wrapped
    // deadline in a release one.
    try std.testing.expectEqual(@as(?i64, null), httpDateEpochSeconds("Wed, 06 Nov 9223372036854775807 08:49:37 GMT"));
    try std.testing.expectEqual(@as(?i64, null), httpDateEpochSeconds("Wed, 06 Nov 99999999999999 08:49:37 GMT"));
    try std.testing.expectEqual(@as(?i64, null), httpDateEpochSeconds("Sun, 06 Nov 20260 08:49:37 GMT"));
    try std.testing.expectEqual(@as(?i64, null), httpDateEpochSeconds("Sun, 06 Nov 26 08:49:37 GMT"));
    try std.testing.expectEqual(@as(?i64, null), httpDateEpochSeconds("Sun, 06 Nov -197 08:49:37 GMT"));
    try std.testing.expectEqual(@as(?i64, null), httpDateEpochSeconds("Wed, 06 Nov 10000 08:49:37 GMT"));
    try std.testing.expectEqual(@as(?i64, null), httpDateEpochSeconds("Wed, 06 Nov -0001 08:49:37 GMT"));
    // The widest year that does pass is exact, and the widest years that are
    // dates sit at the century rule's own edge: 2400 is divisible by four
    // hundred and 9996 by four, so both have a 29 February.
    try std.testing.expectEqual(@as(?i64, 253_402_300_799), httpDateEpochSeconds("Fri, 31 Dec 9999 23:59:59 GMT"));
    try std.testing.expect(httpDateEpochSeconds("Fri, 29 Feb 2400 00:00:00 GMT") != null);
    try std.testing.expect(httpDateEpochSeconds("Wed, 29 Feb 9996 00:00:00 GMT") != null);
    try std.testing.expectEqual(@as(?i64, null), httpDateEpochSeconds("Wed, 29 Feb 9999 00:00:00 GMT"));
    // A weekday that does not match the date is ignored rather than refused:
    // it is redundant, and a server a second off writes the wrong one.
    try std.testing.expectEqual(@as(?i64, 1_792_567_680), httpDateEpochSeconds("Mon, 21 Oct 2026 07:28:00 GMT"));
}

// The dates above name three months of the twelve, so a table reordered, a
// month dropped or the case-insensitive match narrowed to a byte comparison
// would pass them all and misread the rest. Every name is pinned to the number
// `daysFromCivil` counts it by: the twelfth day of each month, whose epoch is
// the number of days from the epoch to it, so an off-by-one in either the table
// or the arithmetic moves the answer rather than being asserted twice.
test "every month name reads as the month the epoch counts" {
    for (calendar_months, 1..) |name, number| {
        const month: u32 = @intCast(number);
        // A year with no 29 February, so February's own length does not enter.
        const header = try std.fmt.allocPrint(
            std.testing.allocator,
            "Thu, 12 {s} 2021 00:00:00 GMT",
            .{name},
        );
        defer std.testing.allocator.free(header);
        const want = daysFromCivil(2021, month, 12) * @as(i64, std.time.s_per_day);
        try std.testing.expectEqual(@as(?i64, want), httpDateEpochSeconds(header));
        // The name a sender is allowed to spell any other way is still this
        // month, which a byte comparison against the table would refuse.
        for ([_]*const fn (u8) u8{ std.ascii.toLower, std.ascii.toUpper }) |casing| {
            var recased: [3]u8 = undefined;
            for (name, 0..) |c, i| recased[i] = casing(c);
            const recased_header = try std.fmt.allocPrint(
                std.testing.allocator,
                "Thu, 12 {s} 2021 00:00:00 GMT",
                .{recased},
            );
            defer std.testing.allocator.free(recased_header);
            try std.testing.expectEqual(@as(?i64, want), httpDateEpochSeconds(recased_header));
        }
    }
    // A name the table does not carry is not a month, whatever it looks like.
    for ([_][]const u8{ "", "Ju", "Junx", "Jun1", "Sept", "0" }) |name|
        try std.testing.expectEqual(@as(?u32, null), monthFromName(name));
}
