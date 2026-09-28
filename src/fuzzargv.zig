//! The shape both command-line parsers are fuzzed through.
//!
//! A leaf module, and the only one nothing but a test imports: `net` is what
//! the modules that touch the machine share, and an argv is neither, so the
//! shaper that builds one lives here rather than in a module a reader of `net`
//! would not expect to find it in.

const std = @import("std");

/// The fuzzer's bytes as an `argv`, one word per space-separated run, so they
/// reach a command-line parser as arguments rather than as a single opaque
/// word. The agent's flags and `update`'s are parsed by two different parsers
/// that both need the same shape. The words borrow `text`, so the caller's
/// buffer (or the corpus seed) must outlive the returned slice.
pub fn argv(text: []const u8, words: *[64][]const u8) []const []const u8 {
    var n: usize = 0;
    var split = std.mem.tokenizeAny(u8, text, " \t\n");
    while (split.next()) |word| {
        if (n == words.len) break;
        words[n] = word;
        n += 1;
    }
    return words[0..n];
}

test "fuzzed bytes reach a parser as one argument per word, up to the array it was given" {
    var words: [64][]const u8 = undefined;

    try std.testing.expectEqual(@as(usize, 0), argv("", &words).len);
    try std.testing.expectEqual(@as(usize, 0), argv(" \t\n", &words).len);

    const split = argv("-p\ttwo words\n-p three", &words);
    try std.testing.expectEqual(@as(usize, 5), split.len);
    try std.testing.expectEqualStrings("-p", split[0]);
    try std.testing.expectEqualStrings("two", split[1]);
    try std.testing.expectEqualStrings("words", split[2]);
    try std.testing.expectEqualStrings("-p", split[3]);
    try std.testing.expectEqualStrings("three", split[4]);

    // More words than the array holds are dropped, not written past it: the
    // array is the caller's, and a fuzzer feeds it bytes of any size.
    var long: [512]u8 = undefined;
    var n: usize = 0;
    for (0..65) |i| {
        if (i > 0) {
            long[n] = ' ';
            n += 1;
        }
        n += (try std.fmt.bufPrint(long[n..], "w{d}", .{i})).len;
    }
    const capped = argv(long[0..n], &words);
    try std.testing.expectEqual(@as(usize, 64), capped.len);
    try std.testing.expectEqualStrings("w63", capped[63]);
}
