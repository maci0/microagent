//! A `memcpy` that moves a word at a time, for the `ReleaseSmall` build.
//!
//! Zig's compiler runtime copies a byte per iteration in that mode, about four instructions a byte,
//! and the request path copies its body through several writers: a full run spent 36% of its
//! instructions there. This one is under a fifth of that. It replaces the runtime's weak `memcpy`
//! only where the runtime's is the slow one: `ReleaseSmall` on Linux with no libc.
//!
//! The module is compiled with `-fno-builtin` (build.zig). Without it LLVM recognizes the loop below
//! as a copy and replaces it with a call to `memcpy`, which is this function.

const std = @import("std");
const builtin = @import("builtin");

const word = @sizeOf(u64);

/// Copies `len` bytes from `src` to `dest`, which must not overlap. Neither pointer needs alignment.
pub fn memcpyWords(noalias dest: ?[*]u8, noalias src: ?[*]const u8, len: usize) callconv(.c) ?[*]u8 {
    @setRuntimeSafety(false);
    if (len == 0) return dest;
    const d = dest.?;
    const s = src.?;
    var at: usize = 0;
    while (at + 4 * word <= len) : (at += 4 * word) {
        inline for (0..4) |lane| {
            @as(*align(1) u64, @ptrCast(d + at + lane * word)).* = @as(*align(1) const u64, @ptrCast(s + at + lane * word)).*;
        }
    }
    while (at + word <= len) : (at += word) {
        @as(*align(1) u64, @ptrCast(d + at)).* = @as(*align(1) const u64, @ptrCast(s + at)).*;
    }
    while (at < len) : (at += 1) d[at] = s[at];
    return dest;
}

comptime {
    if (builtin.mode == .ReleaseSmall and builtin.os.tag == .linux and !builtin.link_libc and !builtin.is_test) {
        @export(&memcpyWords, .{ .name = "memcpy", .linkage = .strong });
    }
}

test "memcpyWords copies every length between every pair of alignments" {
    var src: [128]u8 = undefined;
    for (&src, 0..) |*byte, i| byte.* = @truncate(i *% 31 +% 7);
    for (0..word + 1) |src_offset| {
        for (0..word + 1) |dest_offset| {
            for (0..100) |len| {
                var dest = [_]u8{0xaa} ** 128;
                const got = memcpyWords(dest[dest_offset..].ptr, src[src_offset..].ptr, len);
                try std.testing.expectEqual(@as(?[*]u8, dest[dest_offset..].ptr), got);
                try std.testing.expectEqualSlices(u8, src[src_offset..][0..len], dest[dest_offset..][0..len]);
                // Nothing before or after the destination range is touched.
                for (dest[0..dest_offset]) |byte| try std.testing.expectEqual(@as(u8, 0xaa), byte);
                for (dest[dest_offset + len ..]) |byte| try std.testing.expectEqual(@as(u8, 0xaa), byte);
            }
        }
    }
}

test "memcpyWords with a zero length accepts null pointers, as the C contract does" {
    try std.testing.expectEqual(@as(?[*]u8, null), memcpyWords(null, null, 0));
}
