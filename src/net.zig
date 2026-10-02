//! What the four modules that touch the machine share: the CA-bundle escape
//! hatch, the home directory and the variables read out of the environment, a
//! deadline, the two output sinks (stderr for notes and stdout for the
//! answers a caller parses), the path a write through a symlink really lands on,
//! which urls a credential may be sent to, the two budgets a value read out of
//! the environment or off the wire is held to, the line framing a streamed body
//! is cut on, the retry policy both network paths answer with, and the reading
//! of an HTTP date off the wire, which is wire format rather than any one
//! caller's policy.
//!
//! A leaf module over the other leaf: it imports `chat` and nothing else, so
//! the agent run, the session log and `update` can each use it without
//! importing one another. `chat` is imported for the one escaping the notes
//! here need, which is the escaping the rest of the program uses.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

const chat = @import("chat.zig");

/// What a wrapper that reads its environment out of a file leaves around every
/// value it exported. It is spelled here, in the module every reader imports,
/// so trimming an environment value has one set behind it rather than one per
/// reader.
pub const env_surrounding = " \t\r\n";

/// The `User-Agent` every request this program sends carries, and the one
/// place it is spelled.
///
/// There are three HTTP surfaces here -- the provider completions call, a
/// remote MCP server, and `update` against the release API -- and a client
/// library that is not told otherwise sends `user-agent: zig/<version>
/// (std.http)` on every one of them. That names the toolchain a run happens to
/// be built with rather than the program that made the request, so a provider
/// or an operator reading a log cannot tell which client is calling, and the
/// three surfaces answered three different identities for the same binary.
/// `update` already sent `microagent/<version>` on its own; this is that
/// spelling, shared.
pub const user_agent = "microagent/" ++ @import("build_options").version;

/// The bytes that cannot appear in a header value: every C0 control and DEL.
/// A CR or an LF ends the header line, so a value carrying one is not a value
/// the request writer can carry, and the rest of the line becomes headers the
/// caller did not ask for. A credential is the value that matters, and there
/// are now three places a run reads one: the provider key, and a remote MCP
/// server's `api_key_env` name and its value.
const header_control_bytes = blk: {
    var b: [0x21]u8 = undefined;
    for (b[0..0x20], 0..) |*x, c| x.* = @intCast(c);
    b[0x20] = 0x7f;
    break :blk b;
};

/// Whether a value carries a byte that cannot go in a header: every C0
/// control and DEL.
pub fn hasHeaderControlBytes(value: []const u8) bool {
    return std.mem.indexOfAny(u8, value, &header_control_bytes) != null;
}

test "every HTTP surface names the program rather than the toolchain" {
    // The library's own default is what a request sent without this header
    // carries, so the guard is against drifting back to it by leaving a surface
    // alone rather than against a particular spelling.
    try std.testing.expect(!std.mem.startsWith(u8, user_agent, "zig/"));
    try std.testing.expect(std.mem.startsWith(u8, user_agent, "microagent/"));
    // A header value has to be writable as one: no byte here may end the line.
    try std.testing.expect(!hasHeaderControlBytes(user_agent));
}

/// How much of a value a message quotes back, bounded on the bytes that come
/// out rather than the bytes that went in, so a value of control characters
/// cannot cost a line several times its length. The agent run and `update` both
/// quote untrusted values into a diagnostic, and one budget is what keeps the
/// two from drifting apart.
pub const quoted_value_bytes: usize = 80;

/// How much of an untrusted name a diagnostic quotes: a skill name the model
/// spells back and an MCP tool name a server offers, bounded as
/// `quoted_value_bytes` bounds a value so the two cannot drift apart.
pub const shown_name_bytes: usize = 120;

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

/// Whether this program may draw escape sequences for a reader. False for a
/// pipe, a file, `TERM=dumb`, and `NO_COLOR` set to anything but an empty
/// string, which is the opt-out every other tool honors: a terminal is where
/// bold is emphasis, and everywhere else the two bytes are text.
///
/// `NO_COLOR` is read for its presence and not for its value, so `NO_COLOR=0`
/// and `NO_COLOR=false` still turn color off. That is the convention the
/// variable's own site documents, and it is the reading that cannot surprise a
/// user who set the name in a terminal profile expecting it to work. The
/// exception is an empty value, which a wrapper that populates the environment
/// from a file leaves behind with the name set and nothing behind it; an empty
/// value is not a setting, the same rule every other variable here follows.
pub fn colorEnabled(env: *const std.process.Environ.Map) bool {
    if (env.get("NO_COLOR")) |v| {
        if (std.mem.trim(u8, v, env_surrounding).len > 0) return false;
    }
    if (env.get("TERM")) |t| {
        if (std.mem.eql(u8, t, "dumb")) return false;
    }
    return true;
}

/// The candidate closest to `word`, or null when nothing is close enough to be
/// worth naming to a reader. The threshold scales with the length of the word,
/// so a dropped letter in a long flag is a suggestion and a two-letter word is
/// not: at one fixed distance `--m` would be "close" to every flag in a table,
/// and naming the least bad of them is worse than naming none.
///
/// Both commands answer a misspelling the same way, and the candidates are the
/// caller's because each command has its own flags: naming `--reasoning-effort`
/// to `microagent update` would send a reader looking for a flag that subcommand
/// does not have.
pub fn nearestFlag(word: []const u8, candidates: []const []const u8) ?[]const u8 {
    if (word.len < 3) return null;
    var best: ?[]const u8 = null;
    var best_distance: usize = 0;
    for (candidates) |candidate| {
        const d = flagDistance(word, candidate) orelse continue;
        if (best == null or d < best_distance) {
            best_distance = d;
            best = candidate;
        }
    }
    return best;
}

/// The edits that separate a mistyped word from a flag, or null when they are
/// too far apart for a suggestion to be worth anything. Two rules, both needed:
///
/// At most two edits, because a word that differs from every flag by three
/// letters is not a misspelling of any of them. `nope` is three substitutions
/// from `model` and four from `print`, and answering either sends a reader
/// toward a flag they did not half-type.
///
/// At most a third of the longer of the two, so the rule scales with the name:
/// `--api-ke` is two edits from `--api-key` and a third of its length, and is
/// suggested, while two edits in a five-letter name is most of the name and is
/// not. A short flag and a long one are both measured this way, so `-m` is
/// suggested for `--m` and `--m` is suggested for `-m`, and neither is suggested
/// for a word three letters away.
fn flagDistance(word: []const u8, candidate: []const u8) ?usize {
    const c = if (std.mem.startsWith(u8, candidate, "--")) candidate[2..] else candidate;
    const w = if (std.mem.startsWith(u8, word, "--")) word[2..] else word;
    if (c.len == 0 or w.len == 0) return null;
    // A word that starts a candidate and stops is a truncated flag, and costs
    // one edit whatever tail is missing: `--reasoning` is a prefix of exactly
    // one flag, and measuring the missing half would put it level with
    // `--config`, which is what it is not.
    if (std.mem.startsWith(u8, c, w)) return 1;
    const d = editDistance(w, c) orelse return null;
    const longer = @max(codepointCount(w), codepointCount(c));
    if (d > 2 or d * 3 > longer) return null;
    return d;
}

/// How many codepoints `s` spells, which is the unit an edit is counted in.
///
/// The word being matched is whatever the user typed, and a keyboard with a
/// CJK or a Cyrillic layout puts a multi-byte character where a flag has an
/// ASCII letter. Counting bytes made one wrong character cost two, three or
/// four edits, so the nearest flag fell outside the two-edit budget and the
/// suggestion the user typed a flag for was the one thing they did not get.
fn codepointCount(s: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        i += codepointLen(s, i);
        n += 1;
    }
    return n;
}

/// The bytes the character starting at `i` is made of, treating bytes that are
/// not a valid sequence as one byte each. A word a user half-typed can hold
/// anything a terminal's paste delivers, and a run of bytes that is not text
/// still has to be walked to the end rather than trusted to decode.
fn codepointLen(s: []const u8, i: usize) usize {
    const want = chat.utf8SequenceLen(s, i);
    return if (want == 0) 1 else want;
}

/// Levenshtein distance over two rows of codepoints, so a long word costs two
/// allocations of its own length rather than a square of it. Null when a word
/// is too long for a row of `u8` distances, which no flag this suggests is.
///
/// Both ends are measured before anything is allocated. The row a distance
/// lands in is a `u8`, and a row holds a distance, so a word of more than 255
/// characters has a distance that does not fit one whichever side it is on. The
/// flag side is a handful of characters and was never at risk; the word side is
/// whatever a person typed or a paste delivered, and `at` and the row values
/// grew past 255 with it until a long word overflowed the row and took the run
/// down. Refusing is the answer the row cannot give, and it is the answer a
/// word that long already deserves: it is further from every flag than the two
/// edits a suggestion is worth.
fn editDistance(a: []const u8, b: []const u8) ?usize {
    if (a.len == 0) return codepointCount(b);
    if (b.len == 0) return codepointCount(a);
    const a_len = codepointCount(a);
    if (a_len >= std.math.maxInt(u8)) return null;
    const b_len = codepointCount(b);
    if (b_len >= std.math.maxInt(u8)) return null;
    const gpa = std.heap.page_allocator;
    const prev = gpa.alloc(u8, b_len + 1) catch return null;
    defer gpa.free(prev);
    const cur = gpa.alloc(u8, b_len + 1) catch return null;
    defer gpa.free(cur);
    for (0..b_len + 1) |j| prev[j] = @intCast(j);
    var i: usize = 0;
    var at: usize = 0;
    while (i < a.len) {
        const ca = a[i .. i + codepointLen(a, i)];
        i += ca.len;
        at += 1;
        cur[0] = @intCast(at);
        var j: usize = 0;
        var bj: usize = 0;
        while (bj < b.len) {
            const cb = b[bj .. bj + codepointLen(b, bj)];
            bj += cb.len;
            j += 1;
            const cost: u8 = if (std.mem.eql(u8, ca, cb)) 0 else 1;
            cur[j] = @min(@min(cur[j - 1] + 1, prev[j] + 1), prev[j - 1] + cost);
        }
        @memcpy(prev, cur);
    }
    return prev[b_len];
}

/// The directory every default path this program builds lives under, below the
/// home: the config file, the session store and the skill roots each join it
/// with a leaf of their own, from three modules. The segment is written here
/// once so a run building one default and a reader of `--help`, which spells
/// all three paths out, cannot disagree about the directory in the middle of
/// them.
pub const config_dir = ".microagent";

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

/// `path` with a leading `~` or `~/` replaced by the home directory, for a
/// path this program reads itself rather than one a shell hands it.
///
/// Nothing expands `~` on the way in: the config file, `MICROAGENT_CONFIG` and
/// `MICROAGENT_SKILLS` are values in a file or a variable, and a program with
/// no shell in it has to do what the shell would have done. Left alone, the
/// `~` is an ordinary character, so `~/.microagent/skills` names a directory
/// called `~` under the working directory, which is a path no machine holds and
/// a silent no-op rather than an error.
///
/// `~user` is another account's home and is not looked up here, and a `~`
/// that is not the first character is an ordinary character in a directory
/// name, so both come back unchanged. A home that is not set is no expansion
/// either, for the same reason an empty `HOME` is: nothing is invented.
pub fn expandHome(env: *const std.process.Environ.Map, arena: std.mem.Allocator, path: []const u8) []const u8 {
    if (path.len == 0 or path[0] != '~') return path;
    if (path.len != 1 and path[1] != '/' and path[1] != std.fs.path.sep) return path;
    const home = homeDir(env) orelse return path;
    if (path.len == 1) return home;
    return std.fs.path.join(arena, &.{ home, path[2..] }) catch path;
}

/// The file `path` names once every symlink on it is followed, which is the
/// file opening `path` would have written to and the only one a rename may
/// replace.
///
/// Three callers need it: `writeFileAtomic` (which `write` and `edit` share)
/// so a rewrite through a link replaces the real file and leaves the link a
/// link, `update` so the binary is replaced rather than the link pointing at
/// it, and `credentialPath` in the tool module so a credential behind a link
/// is recognized by the file it resolves to rather than by the name the model
/// chose. It is written once here because the answer is path arithmetic, and
/// path arithmetic spelled inline is where a hardcoded `/` hides: the join goes
/// through `std.fs.path`, so it uses the separator the target actually has.
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
        std.mem.swap([]u8, &spare, &into);
        cur = next;
    }
    return error.SymlinkLoop;
}

/// How many links a path may hold before the answer is a cycle rather than a
/// file. Two links naming each other, or a link into a directory of links, would
/// otherwise spin here. The bound is this module's own and the pruning and the
/// tests are written against it. Forty matches Linux's maximum; macOS may
/// refuse a shorter chain. Credential checks also refuse resolution errors.
const max_symlink_depth = 40;

/// The file `path` names once every symlink on it is followed, including a link
/// in a directory component rather than only one on the last name. This is the
/// order the kernel opens a path in, so it is the order a check that asks "what
/// file would opening this reach" has to walk.
///
/// `resolveSymlinkTarget` settles the chain the last component holds, which is
/// what a rename through a link needs. It answers a path whose middle is a link
/// with the path itself, because `readLink` on `docs/keys/openrouter` says
/// `NotLink` and stops: the link is `docs/keys`, and the kernel follows it on
/// the way to the file. So a directory committed as an ordinary name and
/// pointing at `~/.secrets` walked straight past every name check, and the
/// credential behind it opened under a name the checks had already cleared.
///
/// The buffers are the caller's and each has one job, so no step ever writes
/// over bytes another step is still reading: `cur_buf` holds the prefix the
/// components read so far resolved to, `next_buf` is split in half into the
/// path currently under test and the path a link names, and `name_buf` holds
/// each link's own bytes as it does in `resolveSymlinkTarget`. Every one of them
/// is `max_path_bytes` or more, which is what the old two-buffer walk needed for
/// a composed path to fit.
pub fn resolveEveryComponent(
    io: Io,
    dir: Io.Dir,
    path: []const u8,
    name_buf: []u8,
    cur_buf: []u8,
    next_buf: []u8,
) ![]const u8 {
    const half = next_buf.len / 2;
    const under_test = next_buf[0..half];
    const link_store = next_buf[half..];
    // A rooted path stays rooted: the leading separator is a component the
    // kernel reads as the root, and a walk that dropped it would read every
    // component after it against the working directory instead.
    const rooted = path.len != 0 and path[0] == path_sep;
    var prefix: []const u8 = if (rooted) try copyInto(cur_buf, path[0..1]) else &.{};
    var rest: []const u8 = if (rooted) path[1..] else path;
    var links: usize = 0;
    var components: usize = 0;
    while (true) {
        if (rest.len == 0) return prefix;
        components += 1;
        if (components > max_path_components) return error.NameTooLong;
        const sep_at = std.mem.indexOfScalar(u8, rest, path_sep) orelse rest.len;
        const part = rest[0..sep_at];
        const after = if (sep_at < rest.len) rest[sep_at + 1 ..] else rest[sep_at..];
        if (part.len == 0 or std.mem.eql(u8, part, ".")) {
            // A separator and a `.` are components the kernel skips, so the
            // prefix keeps the shape it had.
            rest = after;
            continue;
        }
        if (std.mem.eql(u8, part, "..")) {
            // A `..` drops the component under it, and a link still ahead of the
            // path is resolved against what is left.
            if (prefix.len == 0 or std.mem.eql(u8, std.fs.path.basename(prefix), "..")) {
                const parents = if (prefix.len == 0) part else try joinOnto(under_test, prefix, part);
                prefix = try copyInto(cur_buf, parents);
            } else {
                prefix = popComponent(prefix);
            }
            rest = after;
            continue;
        }
        const whole = if (prefix.len == 0)
            try copyInto(under_test, part)
        else
            try joinOnto(under_test, prefix, part);
        const n = dir.readLink(io, whole, name_buf) catch |err| switch (err) {
            // `NotDir` is a component ahead of this one that is an ordinary
            // file, so the name is not a link for the same reason a name that is
            // not there is not one. Answering the error instead would hand the
            // caller no path at all, and the check the walk exists for never
            // runs on it.
            error.NotLink, error.FileNotFound, error.NotDir => {
                prefix = try copyInto(cur_buf, whole);
                rest = after;
                continue;
            },
            else => |e| return e,
        };
        // A link is replaced by what it names, and what it names is a path of
        // its own, so the walk continues there with the rest of the original
        // path behind it, which is the order the kernel reads components in. A
        // relative target is read against the directory holding the link, which
        // is the prefix; a bare name has no prefix of its own and one in the
        // working directory.
        const target = name_buf[0..n];
        // Only a link makes the walk start over on a path it has not read, so
        // only a link is counted: a path of forty ordinary components is a path
        // the kernel opens, and the bound is here for a cycle between two links
        // rather than for depth.
        links += 1;
        if (links > max_symlink_depth) return error.SymlinkLoop;
        if (std.fs.path.isAbsolute(target)) {
            prefix = try copyInto(cur_buf, target[0..1]);
            rest = try linkRest(link_store, &.{}, target[1..], after);
        } else {
            rest = try linkRest(link_store, &.{}, target, after);
        }
    }
}

/// The separator a path is split on. `std.fs.path.sep` is the host's, and a
/// config path, a tool path and a link target on these platforms all spell it
/// the host's way, so the walk splits on the same one the join writes.
const path_sep: u8 = std.fs.path.sep;

/// How many components a path may hold before the walk gives up on it. The
/// component count is not the link bound: an ordinary path of a hundred names
/// is one the kernel opens, and it is counted here rather than against
/// `max_symlink_depth`. Every component spends a byte of the path and a
/// separator around it, so a path that fits in a buffer cannot outrun this.
const max_path_components: usize = 2 * std.fs.max_path_bytes;

/// The prefix a `..` leaves behind: the one under it dropped. `dirname` answers
/// null both for the rooted prefix, which keeps its separator, and for a
/// relative prefix holding a single name, which the kernel drops rather than
/// keeps, so the root is told apart here before the lookup. Dropping the root
/// would read every component after it against the working directory, and
/// keeping a name that is not there would answer for a file the kernel does not
/// open.
fn popComponent(prefix: []const u8) []const u8 {
    if (prefix.len == 0) return prefix;
    if (prefix.len == 1 and prefix[0] == path_sep) return prefix;
    return std.fs.path.dirname(prefix) orelse &.{};
}

/// The path a link is replaced with: the directory holding it, then what the
/// link names, then the components of the original path that followed the link.
/// The tail is what a walk that stopped at the target lost, so `sub/link/leaf`
/// with `link` naming `real2` answers `sub/real2/leaf` and not `sub/real2`.
/// `after` is a slice of `buf` itself on every walk but the first, so it moves
/// up to the end first: writing the head and the tail in place would have the
/// second copy overwrite the first.
fn linkRest(buf: []u8, dir_end: []const u8, target: []const u8, after: []const u8) error{NameTooLong}![]const u8 {
    const head_empty = dir_end.len == 0 and target.len == 0;
    // The same rule `joinOnto` states: a prefix that already ends in the
    // separator is not given a second one. The rooted prefix is the separator
    // on its own, and a doubled leading separator names something a host may
    // resolve differently from the single one.
    const lead_sep: usize = if (dir_end.len == 0 or dir_end[dir_end.len - 1] == path_sep) 0 else if (target.len == 0 and after.len == 0) 0 else 1;
    const tail_sep: usize = if (after.len == 0 or head_empty) 0 else 1;
    const n = dir_end.len + lead_sep + target.len + tail_sep + after.len;
    if (n > buf.len) return error.NameTooLong;
    if (after.len != 0) {
        const tail = buf[n - after.len .. n];
        if (@intFromPtr(tail.ptr) <= @intFromPtr(after.ptr)) {
            std.mem.copyForwards(u8, tail, after);
        } else {
            std.mem.copyBackwards(u8, tail, after);
        }
    }
    @memcpy(buf[0..dir_end.len], dir_end);
    if (lead_sep != 0) buf[dir_end.len] = path_sep;
    @memcpy(buf[dir_end.len + lead_sep ..][0..target.len], target);
    if (tail_sep != 0) buf[dir_end.len + lead_sep + target.len] = path_sep;
    return buf[0..n];
}

fn copyInto(buf: []u8, bytes: []const u8) error{NameTooLong}![]const u8 {
    if (bytes.len > buf.len) return error.NameTooLong;
    @memcpy(buf[0..bytes.len], bytes);
    return buf[0..bytes.len];
}

fn joinOnto(buf: []u8, dir_end: []const u8, link: []const u8) error{NameTooLong}![]const u8 {
    // A prefix that already ends in the separator is not given a second one.
    // The rooted prefix is the separator on its own, and a path spelled with a
    // doubled leading separator names something the answer has to compare
    // against literally, so `/../b` came back as `//b` rather than `/b`.
    const sep_bytes: usize = if (dir_end.len != 0 and dir_end[dir_end.len - 1] == path_sep) 0 else 1;
    const n = dir_end.len + sep_bytes + link.len;
    if (n > buf.len) return error.NameTooLong;
    @memcpy(buf[0..dir_end.len], dir_end);
    if (sep_bytes != 0) buf[dir_end.len] = path_sep;
    @memcpy(buf[dir_end.len + sep_bytes ..][0..link.len], link);
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

/// Drops the `consumed` leading bytes of a pending buffer a caller has finished
/// with, and lowers `scanned` past them so the next `nextLineEnd` resumes where
/// the last one stopped. `scanned` is null for a caller that keeps no such
/// cursor. A zero count is a no-op: the shift would be a move of the whole
/// buffer onto itself, which on a record of long lines is the second half of
/// the copy the cap exists to avoid.
pub fn dropPending(pending: *std.ArrayList(u8), scanned: ?*usize, consumed: usize) void {
    if (consumed == 0) return;
    const kept = pending.items.len - consumed;
    std.mem.copyForwards(u8, pending.items[0..kept], pending.items[consumed..]);
    pending.shrinkRetainingCapacity(kept);
    if (scanned) |cursor| cursor.* -|= consumed;
}

/// Releases a walk in full: every directory handle it still holds, then the
/// memory it owns. This is the release for a walk whose loop gave up early, and
/// the one a walk that ran to completion can use as well, since a drained walk
/// has nothing left to close.
///
/// A `SelectiveWalker` owns two lists and no handles: it closes a directory as
/// it pops the stack, and `deinit` frees the lists and stops. A walk that runs
/// to exhaustion pops the stack down to the root it was handed and leaves
/// nothing for this to close, but a walk that returns early -- on an entry it
/// does not want, on a read that failed, on an allocation that would not be
/// made -- leaves every directory under the point it stopped at open, and
/// `deinit` on its own hands them back to nobody. That is one descriptor per
/// level of depth for the life of the process, from a walk that ran once.
///
/// The root is the caller's and is not closed, which is the rule the walker's
/// own popping half keeps: it only closes a directory that had a parent left
/// above it.
pub fn drainWalk(io: Io, walker: *std.Io.Dir.Walker) void {
    defer walker.deinit();
    // Each `next` that finds nothing pops the stack by one, closing the
    // directory it leaves. Bounded by the depth the walk reached, so this
    // terminates, and it is the same close the walk's own loop performs, so a
    // directory the loop already popped is not closed twice.
    while (walker.next(io) catch null) |_| {}
}

/// How many descriptors this process holds, counted by walking `/proc/self/fd`.
/// Linux only, and only a test uses it: what it measures has no portable
/// equivalent, and a platform that has none is not the platform the leak it
/// reaches the limit on.
///
/// Here rather than in either module that wants it, so the tests that count a
/// descriptor hold a number taken the same way. The walk is drained by the same
/// rule every other walk follows, so the count does not include the handles the
/// count itself took.
pub fn openDescriptors(io: Io, arena: std.mem.Allocator) !usize {
    var dir = try std.Io.Dir.cwd().openDir(io, "/proc/self/fd", .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(arena);
    defer drainWalk(io, &walker);
    var n: usize = 0;
    while (try walker.next(io)) |_| n += 1;
    // The descriptor this walk holds open, which the listing names along with
    // the ones being counted.
    return n -| 1;
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
    dropPending(&pending, &scanned, at + 1);
    try std.testing.expectEqualStrings("data: second\n", pending.items);
    try std.testing.expectEqual(@as(usize, 0), scanned);
    try std.testing.expectEqual(@as(?usize, 12), nextLineEnd(pending.items, &scanned));
    try std.testing.expectEqual(@as(?usize, null), nextLineEnd(pending.items, &scanned));
}

test "dropping nothing moves nothing, and a caller with no cursor needs no one" {
    var pending: std.ArrayList(u8) = .empty;
    defer pending.deinit(std.testing.allocator);
    try pending.appendSlice(std.testing.allocator, "one line, unterminated");

    // The zero case: a read that completed no line leaves `start` at zero, and
    // the shift would be a copy of the whole buffer onto itself.
    var scanned: usize = 3;
    dropPending(&pending, &scanned, 0);
    try std.testing.expectEqualStrings("one line, unterminated", pending.items);
    try std.testing.expectEqual(@as(usize, 3), scanned);

    dropPending(&pending, null, 4);
    try std.testing.expectEqualStrings("line, unterminated", pending.items);
    try std.testing.expectEqual(@as(usize, 3), scanned);
}

/// Whether a credential may be sent to this url. The API key rides in an
/// Authorization header on every request, so a plaintext url hands it to
/// whatever is on the path, and a typo that drops the `s` is the way that
/// happens by accident. Loopback is exempt: there is no network path there to
/// intercept, and `http://localhost:1234/v1` is how a gateway running on this
/// machine is named.
pub fn urlCarriesKey(url: []const u8) bool {
    const uri = std.Uri.parse(url) catch return false;
    if (std.ascii.eqlIgnoreCase(uri.scheme, "https")) return true;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "http")) return false;
    var host_buf: [Io.net.HostName.max_len]u8 = undefined;
    return isLoopbackHost((uri.getHost(&host_buf) catch return false).bytes);
}

/// Whether a host names this machine and no other.
pub fn isLoopbackHost(host: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(host, "localhost")) return true;
    if (std.ascii.endsWithIgnoreCase(host, ".localhost")) return true;
    if (isIpv4Loopback(host)) return true;
    return std.mem.eql(u8, std.mem.trim(u8, host, "[]"), "::1");
}

const max_ipv4_octet: u16 = 255;

/// `127.x.y.z`, and only when every octet is a number in range: a name that
/// merely begins `127.` is a host somebody else can point anywhere, and
/// `127.256.0.1` is not an address at all, so a resolver is what answers it.
fn isIpv4Loopback(host: []const u8) bool {
    if (!std.mem.startsWith(u8, host, "127.")) return false;
    var octets: usize = 0;
    var it = std.mem.splitScalar(u8, host, '.');
    while (it.next()) |part| {
        if (part.len == 0 or part.len > 3) return false;
        for (part) |c| if (!std.ascii.isDigit(c)) return false;
        // Parsed wide enough that the comparison is the range check, rather
        // than a parse that has already refused what it cannot hold.
        const octet = std.fmt.parseInt(u16, part, 10) catch return false;
        if (octet > max_ipv4_octet) return false;
        octets += 1;
    }
    return octets == 4;
}

/// A monotonic duration for `Io.Timeout`, from milliseconds. A tool deadline
/// is named in milliseconds in every tool, so the conversion is spelled once
/// here rather than at each call site.
pub fn durationMs(ms: u64) Io.Timeout {
    return .{ .duration = .{ .raw = .{ .nanoseconds = ms *| std.time.ns_per_ms }, .clock = .awake } };
}

/// Runs `operation(args)` as a task raced against the clock, and returns its
/// payload, `error.Timeout` when the clock won, or whatever the operation
/// failed with. Both tasks are joined before this returns, so nothing writes
/// into the caller's buffers after they move. A caller whose operation hands
/// back ownership when the clock wins needs its own race rather than this one.
pub fn withDeadline(
    io: Io,
    timeout: Io.Timeout,
    comptime operation: anytype,
    args: anytype,
) !payloadOf(@typeInfo(@TypeOf(operation)).@"fn".return_type.?) {
    const Outcome = union(enum) {
        answered: @typeInfo(@TypeOf(operation)).@"fn".return_type.?,
        expired: Io.Cancelable!void,
    };
    var slots: [2]Outcome = undefined;
    var select: Io.Select(Outcome) = .init(io, &slots);
    defer select.cancelDiscard();
    try select.concurrent(.answered, operation, args);
    try select.concurrent(.expired, Io.Timeout.sleep, .{ timeout, io });
    return switch (try select.await()) {
        .answered => |answer| answer,
        .expired => error.Timeout,
    };
}

/// What `withDeadline` returns for an operation returning `R`: the payload of
/// its error union, however many layers of `anyerror` the caller wrapped it in.
fn payloadOf(comptime R: type) type {
    return switch (@typeInfo(R)) {
        .error_union => |info| payloadOf(info.payload),
        else => R,
    };
}

/// The retry schedule both network paths use: the wait before the first retry,
/// doubled per attempt. The doubling count and the base are shared, the cap is
/// the caller's because the two waits are not the same promise (the run's is
/// sixty seconds, `update`'s thirty), and a policy spelled twice is a policy
/// that has already drifted once.
const retry_backoff_base_ms: u64 = 1000;
/// Enough doublings to reach any cap in use; the cap is what bounds the wait.
const retry_backoff_shift: u32 = 6;

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

/// The longest `Retry-After` the agent run will sit out. A provider asking for
/// an hour is not a provider to wait an hour for, and the backoff schedule
/// behind it bounds the wait instead.
pub const max_retry_after_ms: u64 = 120_000;

/// The wait a `Retry-After` asks for, in milliseconds, or null when the header
/// is absent or is not one that can be read. A value past
/// `max_retry_after_ms` is clamped to it rather than refused, so the caller sits
/// out the cap instead of falling back to a schedule shorter than the one that
/// was asked for.
///
/// Both forms RFC 9110 defines are read, because a server chooses which to send
/// and the caller has a clock to check the second one against. `now_seconds` is
/// the caller's own reading, passed in rather than taken from a clock here, so
/// the date form is checked against the same time the caller's deadline is.
///
/// This lives here rather than beside the agent run's retry loop, because it is
/// a value off the wire and nothing about it is policy: the agent run and
/// `microagent update` retry the same statuses on the same schedule, and a
/// second copy of the calendar is a second set of century rules. `update`
/// reaches it only once its fetch is moved off `Client.fetch`, which returns
/// the status and not the head; `update`'s own comment says so.
pub fn retryAfterMs(head_bytes: []const u8, now_seconds: i64) ?u64 {
    var lines = std.mem.splitSequence(u8, head_bytes, "\r\n");
    _ = lines.next(); // the status line
    while (lines.next()) |line| {
        if (line.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " \t"), "retry-after")) continue;
        return retryAfterValueMs(std.mem.trim(u8, line[colon + 1 ..], " \t"), now_seconds);
    }
    return null;
}

/// One `Retry-After` value, in milliseconds: either a count of seconds or an
/// instant the count is measured to.
///
/// The date form is not the exotic one. A CDN or gateway computing a deadline
/// against its own clock sends it, and reading it as a number fails: the value
/// is not a count at all, so the caller falls back to a 1 s, 2 s, 4 s schedule
/// and comes back while the server is still refusing, once per step.
///
/// A date already past is zero rather than null: the wait it names has elapsed,
/// so the value off the wire is a wait of none rather than an absent one. What
/// the caller does with a none is its own policy and not this header's: the
/// agent run spends its backoff there, so a gateway whose clock runs ahead of
/// the run's does not talk it into three refusals in a row.
fn retryAfterValueMs(raw: []const u8, now_seconds: i64) ?u64 {
    if (std.fmt.parseInt(u64, raw, 10)) |seconds| {
        // Saturating, so a count too large for milliseconds is the ceiling
        // rather than an unreadable header. The count is unbounded in RFC 9110
        // and a sender's is not always sane (`retry-after: 99999999999` is a
        // gateway that divided milliseconds by the wrong constant); reading
        // that as unreadable drops the caller onto the 1 s, 2 s, 4 s backoff, so
        // it comes back while the server is still refusing, which is the
        // failure the header exists to prevent.
        return @min(seconds *| std.time.ms_per_s, max_retry_after_ms);
    } else |_| {}
    const target = httpDateEpochSeconds(raw) orelse return null;
    // A date already past is a wait of none, and a date so far ahead that the
    // gap is not representable is a wait past the cap, which is what comes
    // back. Both ends of that subtraction are off a wire or off the wall clock
    // and neither is bounded: the date is capped by the four-digit year the
    // grammar spells, so `target` is at most the year 9999, but a clock is
    // bounded by nothing at all, and a machine whose wall clock is set before
    // 1970 -- a container with no RTC, a host restored from a snapshot, a
    // machine with a flat RTC battery -- reads below 1970 as an ordinary
    // negative number. `maxInt(i64)` of those two is past what an `i64`
    // subtraction holds, and the subtraction was the last unchecked one on
    // this path: it trapped a checked build on the first 429 of such a run,
    // where the header had carried everything it needed to answer.
    if (target <= now_seconds) return 0;
    const left = @as(u64, @intCast(target -| now_seconds));
    return @min(left *| std.time.ms_per_s, max_retry_after_ms);
}

/// The caller's own clock in seconds, the form `retryAfterMs` reads a date
/// against.
///
/// The reading is checked against the range before it is narrowed, rather than
/// narrowed straight out of it, because a wall clock before 1970 is ordinary
/// rather than exotic: a container with no RTC, a machine restored from a
/// snapshot, and a host whose RTC battery is flat all boot into one, and the
/// clock's own reading is a signed `i96` wide enough to hold such a date.
/// `@intCast` out of it trapped a checked build on the first request of such a
/// run. The `i96` also reaches past `i64` on its own, so a far-future clock is
/// the same narrowing from the other side, and both ends saturate: this feeds a
/// subtraction against a `Retry-After` date, and a wrong answer there is a wait
/// of the wrong length, so a value at the end of the range is worth more than a
/// crash.
///
/// The bottom of the range is the epoch, and that is the clamp `session.logStamp`
/// and `session.recordStampMs` already apply: a negative epoch is not an
/// instant a date can be measured against. The subtraction in
/// `retryAfterValueMs` is `target - now_seconds`, so a negative reading made
/// every `left` larger than it is and a date that had already passed was read as
/// still in the future — the run then sat out up to `max_retry_after_ms` on a
/// wait for a deadline that was behind it, which is the refusal the header
/// exists to prevent. Zero is the reading that says nothing about the time,
/// which is all a clock before the epoch says.
pub fn nowSeconds(io: Io) i64 {
    return nowSecondsFromNs(Io.Clock.real.now(io).nanoseconds);
}

/// The same reading with the nanoseconds passed in, so both sides of the epoch
/// and both ends of the range are reachable from a test without a machine whose
/// clock is set to them. The division is saturating rather than an `@intCast`,
/// so a clock set far enough ahead to push the seconds past what an `i64` holds
/// is the ceiling instead of a trap that ends the run at the point it was about
/// to wait out a rate limit.
fn nowSecondsFromNs(now_ns: i128) i64 {
    const seconds = @divTrunc(now_ns, std.time.ns_per_s);
    if (seconds < 0) return 0;
    return @intCast(@min(seconds, std.math.maxInt(i64)));
}

/// Whether a transport failure is worth another attempt. The set is the
/// failures a second connection can answer: the name did not resolve, the
/// route to it is down, the connection was refused, reset or dropped, the TLS
/// handshake did not complete. Everything else the client can name is a
/// decision it or the URL already made, so three attempts separated by a
/// backoff only delay the same refusal. A failed allocation is the run's own
/// memory rather than the path to the server, and is not among them: a second
/// attempt has to be handed the same buffer, which is what ran out.
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

/// The month names in the order `std.time.epoch.getDaysInMonth` counts them,
/// and the form a `Retry-After` date spells them in. One table for the reader
/// and the writer, so a month cannot be spelled two ways and drift.
const calendar_months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

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
fn httpDateEpochSeconds(raw: []const u8) ?i64 {
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

    if (year < 1) return null;

    const day = std.fmt.parseInt(u32, day_text, 10) catch return null;
    if (day == 0 or day > std.time.epoch.getDaysInMonth(@intCast(year), @enumFromInt(month))) return null;
    if (hour < 0 or hour > 23 or minute < 0 or minute > 59 or second < 0 or second > 60) return null;

    return daysFromCivil(year, month, day) * @as(i64, std.time.s_per_day) +
        hour * std.time.s_per_hour + minute * std.time.s_per_min + second;
}

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

// The key rides in an Authorization header on every request, so the rule is
// the one that decides whether it crosses the network in the clear. It is
// asserted case by case rather than left to the callers that ask it: a
// hostname check that widened to "ends with localhost" or a prefix check that
// stopped before the fourth octet would still let the providers below resolve,
// and nothing else in the file would notice.
test "a key is only sent over a scheme that keeps it off the wire" {
    const cases = [_]struct { url: []const u8, carries: bool }{
        .{ .url = "https://api.example.com/v1/chat", .carries = true },
        .{ .url = "HTTPS://api.example.com/v1", .carries = true },
        // A gateway on this machine is named in the clear, and there is no
        // path out of loopback to intercept.
        .{ .url = "http://localhost:1234/v1", .carries = true },
        .{ .url = "http://gateway.localhost:1234/v1", .carries = true },
        .{ .url = "http://LOCALHOST/v1", .carries = true },
        .{ .url = "http://127.0.0.1:8080/v1", .carries = true },
        .{ .url = "http://127.1.2.3/v1", .carries = true },
        .{ .url = "http://[::1]:8080/v1", .carries = true },
        // Everything else on a plaintext url hands the key to the path.
        .{ .url = "http://api.example.com/v1", .carries = false },
        .{ .url = "http://127.0.0.1.evil.com/v1", .carries = false },
        // The host is read past the userinfo, so a name that looks like
        // loopback on the left of an `@` names whoever is on the right.
        .{ .url = "http://127.0.0.1@evil.com/v1", .carries = false },
        // A name that only begins 127. is a host somebody else can point
        // anywhere, and an out-of-range octet is not an address at all.
        .{ .url = "http://127.256.0.1/v1", .carries = false },
        .{ .url = "http://127.0.0.1.1/v1", .carries = false },
        .{ .url = "http://127x.0.0.1/v1", .carries = false },
        .{ .url = "http://127.0.0/v1", .carries = false },
        .{ .url = "http://[::2]/v1", .carries = false },
        // A scheme that is not one of the two is not a url this sends to, and
        // an unparsable one is refused rather than assumed safe.
        .{ .url = "ftp://127.0.0.1/v1", .carries = false },
        .{ .url = "not a url", .carries = false },
        .{ .url = "", .carries = false },
    };
    for (cases) |case| {
        std.testing.expectEqual(case.carries, urlCarriesKey(case.url)) catch |err| {
            std.debug.print("url {s}\n", .{case.url});
            return err;
        };
    }
}

// The statuses and the transport errors decide whether a turn is asked again,
// and a set that grows by accident retries a request the server has already
// answered and refuses. 404 is the one exclusion, and it is pinned here
// because it is deliberate rather than an oversight.
test "only a busy or a broken server is asked again" {
    for ([_]std.http.Status{ .request_timeout, .conflict, .too_early, .too_many_requests, .internal_server_error, .bad_gateway, .service_unavailable, .gateway_timeout }) |status| {
        std.testing.expect(retryableStatus(status)) catch |err| {
            std.debug.print("status {d}\n", .{@intFromEnum(status)});
            return err;
        };
    }
    for ([_]std.http.Status{ .ok, .created, .bad_request, .unauthorized, .payment_required, .forbidden, .not_found, .method_not_allowed, .not_acceptable, .upgrade_required, .unprocessable_entity }) |status| {
        std.testing.expect(!retryableStatus(status)) catch |err| {
            std.debug.print("status {d}\n", .{@intFromEnum(status)});
            return err;
        };
    }
    // The 5xx block is a range rather than a list, so the ends of it are named
    // as well as the statuses inside it.
    try std.testing.expect(retryableStatus(@enumFromInt(500)));
    try std.testing.expect(retryableStatus(@enumFromInt(599)));
    try std.testing.expect(retryableStatus(@enumFromInt(600)));
    try std.testing.expect(!retryableStatus(@enumFromInt(499)));
}

// The schedule the two network paths share. Saturating at both ends, because
// the shift and the multiply overflow long before a u32 attempt counter does
// and a checked build panicking where a release one wraps is not a property to
// want in a sleep.
test "the backoff doubles from the base and stops at the caller's cap" {
    // 0 and 1 both wait the base: the counter names attempts already made.
    try std.testing.expectEqual(@as(u64, 1000), retryBackoffMs(0, 60_000));
    try std.testing.expectEqual(@as(u64, 1000), retryBackoffMs(1, 60_000));
    try std.testing.expectEqual(@as(u64, 2000), retryBackoffMs(2, 60_000));
    try std.testing.expectEqual(@as(u64, 4000), retryBackoffMs(3, 60_000));
    try std.testing.expectEqual(@as(u64, 32_000), retryBackoffMs(6, 60_000));
    // Past the last shift the cap is the only thing left to bound it.
    try std.testing.expectEqual(@as(u64, 60_000), retryBackoffMs(7, 60_000));
    try std.testing.expectEqual(@as(u64, 60_000), retryBackoffMs(64, 60_000));
    try std.testing.expectEqual(@as(u64, 30_000), retryBackoffMs(7, 30_000));
    // A counter that would overflow the shift, and one that would overflow the
    // multiply, both come back as the cap rather than as a wrapped number.
    try std.testing.expectEqual(@as(u64, 60_000), retryBackoffMs(std.math.maxInt(u32), 60_000));
    try std.testing.expectEqual(@as(u64, 1000), retryBackoffMs(std.math.maxInt(u32), 1000));
    // A cap below the base is the cap, not a negative or a wrapped wait.
    try std.testing.expectEqual(@as(u64, 250), retryBackoffMs(0, 250));
}

// Both commands answer a misspelling the same way, from their own flag lists.
// The rules are the edit budget, the third-of-the-longer budget, and the
// prefix rule; none of them is visible in a caller's own tests, and a
// threshold that widened to three edits would suggest a flag for every word.
test "a mistyped flag is answered from the nearest one that command has" {
    const flags = [_][]const u8{ "--model", "--print", "--api-key", "--check", "--help", "-m" };
    // A truncation is one edit whatever tail is missing, so it is suggested:
    // `--mode` and `--api-ke` are prefixes of exactly one flag each.
    try std.testing.expectEqualStrings("--model", nearestFlag("--mode", &flags).?);
    try std.testing.expectEqualStrings("--api-key", nearestFlag("--api-ke", &flags).?);
    try std.testing.expectEqualStrings("--model", nearestFlag("mod", &flags).?);
    // A substitution is one edit, and the shorter the name the more of it one
    // edit is: `--model` and `--print` are five letters, so a single letter
    // swapped is inside the third of the longer that the rule allows.
    try std.testing.expectEqualStrings("--print", nearestFlag("--pront", &.{"--print"}).?);
    try std.testing.expectEqual(@as(?[]const u8, null), nearestFlag("--pirnt", &.{"--print"}));
    // Two swaps is two edits, which is past a third of a five-letter name.
    try std.testing.expectEqual(@as(?[]const u8, null), nearestFlag("--modle", &flags));
    // Three edits, or an edit in a name this short, are further than a
    // suggestion worth: `nope` is three from `model` and four from `print`.
    try std.testing.expectEqual(@as(?[]const u8, null), nearestFlag("nope", &flags));
    try std.testing.expectEqual(@as(?[]const u8, null), nearestFlag("-modl", &flags));
    // A word shorter than three characters has no budget to spend an edit in.
    try std.testing.expectEqual(@as(?[]const u8, null), nearestFlag("mo", &flags));
    // A list of nothing suggests nothing, however well the word is spelled.
    try std.testing.expectEqual(@as(?[]const u8, null), nearestFlag("--model", &.{}));
    // An edit is counted in characters, so the character a keyboard with a
    // non-ASCII layout put where a letter belongs costs one edit and not the
    // two, three or four its bytes are. `--pri字t` is `--print` with one
    // character swapped, and is suggested as such; measured in bytes it was
    // three edits from a five-character name, which is past what a suggestion
    // is worth.
    try std.testing.expectEqualStrings("--print", nearestFlag("--pri字t", &.{"--print"}).?);
    try std.testing.expectEqualStrings("--print", nearestFlag("--priнt", &.{"--print"}).?);
    // Two of them are still two edits, and a name this short has no room for
    // two, so the rule is unchanged where the counting was already right.
    try std.testing.expectEqualStrings("--model", nearestFlag("--mоdel", &flags).?);
    try std.testing.expectEqual(@as(?[]const u8, null), nearestFlag("--моdel", &flags));
    // Bytes that are not a character at all are walked one by one rather than
    // trusted to decode, so a word a terminal's paste delivered still gets a
    // distance: the byte it cannot read is one character of the five, and
    // dropping it is the one edit that makes the word the flag.
    try std.testing.expectEqualStrings("--print", nearestFlag("--pri\xfft", &.{"--print"}).?);
}

// The words both command lines answer a misspelling from, and the shapes of a
// word a person half-typed: a truncation, a transposition, a flag with its
// leading dashes, a short flag, a word whose letters came from a non-ASCII
// keyboard layout, one cut off from a paste, and a word past what the edit
// budget can reach. `std.testing.fuzz` runs this corpus through the harness on
// every `zig build test`, and through the fuzzer's mutations when the test
// binary is built in fuzz mode.
const nearest_flag_corpus = [_][]const u8{
    "",
    "-",
    "--",
    "mo",
    "-m",
    "--m",
    "--mode",
    "--model",
    "mod",
    "modle",
    "--modle",
    "--api-ke",
    "--api-key",
    "--pront",
    "--pirnt",
    "--pront",
    "nope",
    "--check",
    "-c",
    "--help",
    "-h",
    "--version",
    "-V",
    "--reasoning",
    "--reasoning-effort",
    "--print",
    "--max-tokens",
    "-p",
    "--pri字t",
    "--принт",
    "--pri\xfft",
    "\u{65e5}\u{8a00}",
    "日本語",
    "--модель",
    "\u{0301}",
    "\u{feff}--model",
    "-\x00model",
    "--model\x00",
    "--model\n",
    "\t--model",
    "--" ++ "a" ** 3,
    "--" ++ "a" ** 255,
    "--model" ++ "x" ** 100,
    "\xff\xfe--print",
    "--model=deepseek",
    "--Model",
};

test "a fuzzed misspelling is answered from the list, or from nothing" {
    try std.testing.fuzz({}, fuzzNearestFlag, .{ .corpus = &nearest_flag_corpus });
}

fn fuzzNearestFlag(_: void, smith: *std.testing.Smith) !void {
    var scratch: [512]u8 = undefined;
    const text: []const u8 = if (smith.in) |seed| seed else scratch[0..smith.slice(&scratch)];
    const word = if (text.len == 0) "" else text;

    const flags = [_][]const u8{ "--model", "--print", "--api-key", "--check", "--help", "--version", "-m", "-c", "-h", "-V" };
    const near = nearestFlag(word, &flags);

    // A suggestion is one of the caller's own names, never a name it invented
    // and never a fragment: the whole word is echoed back with "did you mean",
    // so a suggestion that is not on the list tells the reader to type a flag
    // this program does not have.
    if (near) |name| {
        var on_the_list = false;
        for (flags) |flag| if (std.mem.eql(u8, flag, name)) {
            on_the_list = true;
        };
        if (!on_the_list) {
            std.debug.print("\nnearestFlag: '{s}' suggests '{s}', which is not a flag\n", .{ word, name });
            return error.TestUnexpectedResult;
        }
    }

    // A word under three characters has no budget to spend an edit in, so it is
    // answered with nothing however well it is spelled. The measurement here is
    // in bytes where the rule is in characters, so a word of three or more
    // bytes that spells fewer than three characters is held to the rule too.
    if (word.len < 3 or codepointCount(word) < 3) {
        if (near != null) {
            std.debug.print("\nnearestFlag: '{s}' suggests '{s}' with no budget for it\n", .{ word, near.? });
            return error.TestUnexpectedResult;
        }
    }

    // An empty list suggests nothing, however close the word is, and the same
    // answer comes back on every call: the suggestion reads no state.
    try std.testing.expectEqual(@as(?[]const u8, null), nearestFlag(word, &.{}));
    try std.testing.expectEqual(@as(?[]const u8, null), nearestFlag(word, &.{}));
    try std.testing.expectEqualStrings(nearestFlag(word, &flags) orelse "", nearestFlag(word, &flags) orelse "");

    // A flag spelled exactly is either a one-edit truncation of itself or one
    // substitution away from nothing, so it answers itself rather than a
    // neighbour. This is the pair a suggestion is measured against: the same
    // word against a list holding only itself can only name that one.
    if (near) |name| {
        const alone = [_][]const u8{name};
        try std.testing.expectEqualStrings(name, nearestFlag(word, &alone) orelse name);
    }
}

test "a header value is refused for every control byte and accepted for the rest" {
    try std.testing.expect(!hasHeaderControlBytes("sk-a-key"));
    try std.testing.expect(!hasHeaderControlBytes(""));
    // A space is a header value byte, and 0x20 is the first one the set stops
    // at, so the boundary is checked from both sides.
    try std.testing.expect(!hasHeaderControlBytes("a b"));
    try std.testing.expect(hasHeaderControlBytes("a\x1fb"));
    try std.testing.expect(hasHeaderControlBytes("a\x7fb"));
    try std.testing.expect(hasHeaderControlBytes("a\rb"));
    try std.testing.expect(hasHeaderControlBytes("a\nb"));
    try std.testing.expect(hasHeaderControlBytes("a\x00b"));
    // The set is exactly the 32 C0 controls plus DEL: 0x1e and 0x21 bracket the
    // range it claims, and a 0x80 leads nothing is mistaken for a control.
    for (0..0x20) |c| try std.testing.expect(hasHeaderControlBytes(&.{@intCast(c)}));
    try std.testing.expect(!hasHeaderControlBytes(&.{0x20}));
    try std.testing.expect(!hasHeaderControlBytes(&.{0x21}));
    try std.testing.expect(!hasHeaderControlBytes(&.{0x7e}));
    try std.testing.expect(!hasHeaderControlBytes(&.{0x80}));
    try std.testing.expect(!hasHeaderControlBytes(&.{0xff}));
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

test "color is on until NO_COLOR or a dumb TERM says otherwise" {
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    try std.testing.expect(colorEnabled(&env));

    // NO_COLOR is read for its presence, so a value that reads as false in any
    // other tool still turns color off here. A user who set the name in a
    // terminal profile meant it to work, whatever they put behind it.
    try env.put("NO_COLOR", "1");
    try std.testing.expect(!colorEnabled(&env));
    try env.put("NO_COLOR", "0");
    try std.testing.expect(!colorEnabled(&env));
    try env.put("NO_COLOR", "false");
    try std.testing.expect(!colorEnabled(&env));

    // An empty value is the name with nothing behind it, which is what a
    // wrapper that populates the environment from a file leaves behind, and it
    // is not a setting.
    try env.put("NO_COLOR", "");
    try std.testing.expect(colorEnabled(&env));
    try env.put("NO_COLOR", "  ");
    try std.testing.expect(colorEnabled(&env));

    // A dumb terminal renders no escapes, so the two bytes would be text, and
    // it answers whether or not NO_COLOR is set.
    try env.put("TERM", "dumb");
    try std.testing.expect(!colorEnabled(&env));
    try env.put("TERM", "xterm-256color");
    try std.testing.expect(colorEnabled(&env));
    try env.put("NO_COLOR", "1");
    try std.testing.expect(!colorEnabled(&env));
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

test "a CA bundle that holds a certificate is the store the client stops rescanning" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A self-signed root no network ever vouched for, generated once and
    // written into the test rather than read from the machine's trust store:
    // a fixture that is the host's certificates changes with the host, and a
    // test that reads one does not say what it is checking.
    const certificate =
        \\-----BEGIN CERTIFICATE-----
        \\MIIBlTCCATugAwIBAgIUNG7GKLlqcw1fZt2YvLoGAojuugAwCgYIKoZIzj0EAwIw
        \\HzEdMBsGA1UEAwwUbWljcm9hZ2VudCB0ZXN0IHJvb3QwIBcNMjYwOTI4MjIzMDI1
        \\WhgPMjEyNjA5MDQyMjMwMjVaMB8xHTAbBgNVBAMMFG1pY3JvYWdlbnQgdGVzdCBy
        \\b290MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAErNLrBW9YMnlOVZ2hKtLbXURc
        \\ztMorJURg3SgsyPQHOUApmmSF47ignAD3rwbWrIxZYxSCmAwjhfsvI9pR9RLsqNT
        \\MFEwHQYDVR0OBBYEFKuOW97bpN34Tbatk8IbY8ATFW7kMB8GA1UdIwQYMBaAFKuO
        \\W97bpN34Tbatk8IbY8ATFW7kMA8GA1UdEwEB/wQFMAMBAf8wCgYIKoZIzj0EAwID
        \\SAAwRQIgK9AoYB8EF4qzeAH9v3UuKgfGT0gDXk9KPV4REvVrmCkCIQDBQ4oityRN
        \\oVNsATZtOW1jph7igNwlFELmJLHKtwVySQ==
        \\-----END CERTIFICATE-----
        \\
    ;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "bundle.pem", .data = certificate });

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    try std.testing.expect(client.now == null);

    var file_buf: [std.fs.max_path_bytes]u8 = undefined;
    const absolute = file_buf[0..try tmp.dir.realPathFile(io, "bundle.pem", &file_buf)];
    loadCaBundle(&client, io, gpa, absolute, arena);
    // The two things a bundle that loaded is for: the trust store holds what
    // the file named, and `now` is set so the client does not rescan the system
    // store over the top of it.
    try std.testing.expectEqual(@as(usize, 1), client.ca_bundle.map.count());
    try std.testing.expect(client.now != null);

    // The relative form reaches the same store, so a wrapper exporting a path
    // relative to the working directory is not left with an empty one.
    var relative_client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer relative_client.deinit();
    const relative = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}/bundle.pem", .{tmp.sub_path});
    loadCaBundle(&relative_client, io, gpa, relative, arena);
    try std.testing.expectEqual(@as(usize, 1), relative_client.ca_bundle.map.count());
    try std.testing.expect(relative_client.now != null);
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

test "a leading tilde is the home directory, and nothing else is" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const arena = state.allocator();
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    try env.put("HOME", "/home/me");

    try std.testing.expectEqualStrings("/home/me", expandHome(&env, arena, "~"));
    try std.testing.expectEqualStrings("/home/me/x", expandHome(&env, arena, "~/x"));
    try std.testing.expectEqualStrings("/home/me/x", expandHome(&env, arena, &[_]u8{ '~', std.fs.path.sep, 'x' }));

    // Every other tilde is an ordinary character: another account's home is not
    // this program's to look up, and a tilde inside a name is a tilde.
    try std.testing.expectEqualStrings("~other/x", expandHome(&env, arena, "~other/x"));
    try std.testing.expectEqualStrings("/abs", expandHome(&env, arena, "/abs"));
    try std.testing.expectEqualStrings("a/~b", expandHome(&env, arena, "a/~b"));
    try std.testing.expectEqualStrings("", expandHome(&env, arena, ""));

    // A home that is not set is no expansion, rather than a path under the root
    // directory built from nothing.
    var bare: std.process.Environ.Map = .init(std.testing.allocator);
    defer bare.deinit();
    try std.testing.expectEqualStrings("~/x", expandHome(&bare, arena, "~/x"));
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

    // An absolute link needs no join and must not be rewritten as one: the
    // directory holding the link is not part of its target, so joining the
    // link's own path onto it would name a file that does not exist. The
    // target need not exist for the walk, which reads the link and does path
    // arithmetic rather than looking the file up, so a path no filesystem
    // carries is the one that says this.
    const abs = "/nonexistent/absolute/target";
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
    try std.testing.expectEqual(@as(?i64, 13_574_563_200), httpDateEpochSeconds("Fri, 29 Feb 2400 00:00:00 GMT"));
    try std.testing.expectEqual(@as(?i64, 253_281_168_000), httpDateEpochSeconds("Wed, 29 Feb 9996 00:00:00 GMT"));
    try std.testing.expectEqual(@as(?i64, null), httpDateEpochSeconds("Wed, 29 Feb 9999 00:00:00 GMT"));
    // A weekday that does not match the date is ignored rather than refused:
    // it is redundant, and a server a second off writes the wrong one.
    try std.testing.expectEqual(@as(?i64, 1_792_567_680), httpDateEpochSeconds("Mon, 21 Oct 2026 07:28:00 GMT"));
}

// The clock a `Retry-After` date is measured against comes from the machine, and
// a machine whose clock is set before 1970 reads negative. `retryAfterValueMs`
// subtracts that reading from the date, so a negative one made every wait larger
// than it is: a date that had already passed was read as still in the future and
// the run sat out up to `max_retry_after_ms` on a deadline that was behind it,
// which is the refusal the header exists to prevent. `nowSeconds` clamps the way
// `session.logStamp` and `session.recordStampMs` already do, and this pins the
// two together.
test "a clock before 1970 reads as the epoch, so a past Retry-After has passed" {
    // The clamp itself, on both sides of the epoch it divides.
    try std.testing.expectEqual(@as(i64, 0), nowSecondsFromNs(-1));
    try std.testing.expectEqual(@as(i64, 0), nowSecondsFromNs(0));
    try std.testing.expectEqual(@as(i64, 0), nowSecondsFromNs(-1_000_000_000));
    try std.testing.expectEqual(@as(i64, 1), nowSecondsFromNs(1_000_000_000));
    // A clock far enough ahead that the seconds would not fit an i64 is the
    // ceiling rather than a trap: the run is about to wait out a rate limit, and
    // an unchecked `@intCast` here ended it at the point it was meant to keep
    // running. The second reading is the one that reaches the clamp at all,
    // since dividing `maxInt(i128)` by a billion still fits.
    try std.testing.expectEqual(
        std.math.maxInt(i64),
        nowSecondsFromNs(@as(i128, std.math.maxInt(i64)) * std.time.ns_per_s),
    );
    try std.testing.expectEqual(std.math.maxInt(i64), nowSecondsFromNs(std.math.maxInt(i128)));

    // And the wait that depends on it: the same header read against a clamped
    // clock and against the negative reading an unchecked cast produced, which
    // is the comparison the caller actually makes.
    const head = "HTTP/1.1 429 Too Many Requests\r\nRetry-After: Thu, 01 Jan 1970 00:00:00 GMT\r\n\r\n";
    // The epoch is at or before the clamped clock, so the wait has already run
    // out: zero, not the cap.
    try std.testing.expectEqual(@as(?u64, 0), retryAfterMs(head, nowSecondsFromNs(-1_000_000_000)));
    // Under a clock one second before the epoch the same header is a date in the
    // future, and a wait of one second rather than the 120 second cap the
    // negative reading gave a header with nothing left to wait for.
    try std.testing.expectEqual(@as(?u64, 1_000), retryAfterMs(head, -1));
    // A date further ahead of the clamped clock is still a real wait, and it is
    // the difference rather than the cap: the clamp moved the bottom of the
    // range, not the top of it. Ninety seconds is inside `max_retry_after_ms`,
    // so what the wait is is the arithmetic's and not the ceiling's.
    try std.testing.expectEqual(@as(?u64, 90_000), retryAfterMs(head, -90));
    // Past the cap the ceiling stands, which is the bound a date a long way off
    // gets rather than the two minutes it would otherwise be.
    try std.testing.expectEqual(max_retry_after_ms, retryAfterMs(head, -1_000));
}

// The dates above name three months of the twelve, so a table reordered, a
// month dropped or the case-insensitive match narrowed to a byte comparison
// would pass them all and misread the rest. Every name is pinned to a literal
// epoch second: the twelfth day of each month of 2021, counted from the Unix
// epoch by something other than the arithmetic under test. A `daysFromCivil`
// call is the same code the parser runs, so a leap rule or an off-by-one
// inside it moves both sides of the comparison together and the test holds for
// a reader that gets every date of the year wrong.
test "every month name reads as the month its epoch names" {
    // Spelled out here rather than walked out of `calendar_months`, because
    // the point is that the two agree: reading the name back out of the table
    // the name came from cannot fail when the table is reordered.
    const months = [_]struct { name: []const u8, number: u32, epoch: i64 }{
        .{ .name = "Jan", .number = 1, .epoch = 1_610_409_600 },
        .{ .name = "Feb", .number = 2, .epoch = 1_613_088_000 },
        .{ .name = "Mar", .number = 3, .epoch = 1_615_507_200 },
        .{ .name = "Apr", .number = 4, .epoch = 1_618_185_600 },
        .{ .name = "May", .number = 5, .epoch = 1_620_777_600 },
        .{ .name = "Jun", .number = 6, .epoch = 1_623_456_000 },
        .{ .name = "Jul", .number = 7, .epoch = 1_626_048_000 },
        .{ .name = "Aug", .number = 8, .epoch = 1_628_726_400 },
        .{ .name = "Sep", .number = 9, .epoch = 1_631_404_800 },
        .{ .name = "Oct", .number = 10, .epoch = 1_633_996_800 },
        .{ .name = "Nov", .number = 11, .epoch = 1_636_675_200 },
        .{ .name = "Dec", .number = 12, .epoch = 1_639_267_200 },
    };
    try std.testing.expectEqual(calendar_months.len, months.len);
    for (months) |entry| {
        const name = entry.name;
        const month = entry.number;
        // A year with no 29 February, so February's own length does not enter.
        const header = try std.fmt.allocPrint(
            std.testing.allocator,
            "Thu, 12 {s} 2021 00:00:00 GMT",
            .{name},
        );
        defer std.testing.allocator.free(header);
        const want = entry.epoch;
        try std.testing.expectEqual(@as(?i64, want), httpDateEpochSeconds(header));
        try std.testing.expectEqual(@as(?u32, month), monthFromName(name));
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

// The header a server or a gateway in front of it wrote, whole and as the
// grammar leaves it. `std.testing.fuzz` runs this corpus through the harness on
// every `zig build test`, and through the fuzzer's mutations when the test
// binary is built in fuzz mode. The date a real origin sends, the two obsolete
// forms RFC 9110 no longer requires, the epoch and a leap day at the century
// rule's edge, the widest year the grammar spells, and the shapes that reach
// the day arithmetic with something it cannot use: a year of the wrong width, a
// zone that is not GMT, a clock field out of range, a day past the end of its
// month, a trailing field the grammar does not carry, and a header cut short.
const http_date_corpus = [_][]const u8{
    "",
    ",",
    "GMT",
    "Sun, 06 Nov 1994 08:49:37 GMT",
    "Sun, 06 Nov 1994 08:49:37 GMT ",
    "Sun, 06 Nov 1994 08:49:37 GMT extra",
    "Sun, 06 Nov 1994 08:49:37 UTC",
    "Sunday, 06-Nov-94 08:49:37 GMT",
    "Sun Nov  6 08:49:37 1994",
    "Thu, 01 Jan 1970 00:00:00 GMT",
    "Thu, 01 Jan 1970 00:00:01 GMT",
    "Fri, 31 Dec 9999 23:59:59 GMT",
    "Fri, 31 Dec 9999 23:59:60 GMT",
    "Wed, 29 Feb 2024 12:00:00 GMT",
    "Thu, 29 Feb 2400 00:00:00 GMT",
    "Wed, 29 Feb 9996 00:00:00 GMT",
    "Sun, 06 Nov 0 08:49:37 GMT",
    "Sun, 06 Nov 10000 08:49:37 GMT",
    "Sun, 06 Nov 9223372036854775807 08:49:37 GMT",
    "Sun, 06 Nov 99999999999999 08:49:37 GMT",
    "Sun, 06 Nov -197 08:49:37 GMT",
    "Sun, 06 Nov 20260 08:49:37 GMT",
    "Sun, 06 Nov 1970 -1:00:00 GMT",
    "Sun, 06 Nov 1970 08:49:37:00 GMT",
    "Sun, 00 Nov 1970 08:49:37 GMT",
    "Sun, 31 Nov 1970 08:49:37 GMT",
    "Sun, 31 Apr 1970 08:49:37 GMT",
    "Sun, 29 Feb 1900 08:49:37 GMT",
    "Sun, 32 Jan 1970 08:49:37 GMT",
    "Sun, 06 Xxx 1970 08:49:37 GMT",
    "Sun, 06 Nov 1970 24:00:00 GMT",
    "Sun, 06 Nov 1970 08:60:00 GMT",
    "Sun, 06 Nov 1970 08:49:61 GMT",
    "Sun, 06 Nov 1970 08:49:-1 GMT",
    "Sun,\t06\tNov\t1970\t08:49:37\tGMT",
    "Sun, 06 Nov 1970 08:49:37 GMT\x00",
    "Sun, 06 Nov 1970 08:49:37 G\x00MT",
    ",,,,,,,,,,,,,,,,",
    "Sun, 06 Nov 1970 08:49:37 GMT,",
};

test "a fuzzed Retry-After date names the instant it spells, and never one outside it" {
    try std.testing.fuzz({}, fuzzHttpDate, .{ .corpus = &http_date_corpus });
}

fn fuzzHttpDate(_: void, smith: *std.testing.Smith) !void {
    var scratch: [128]u8 = undefined;
    const raw: []const u8 = if (smith.in) |seed| seed else scratch[0..smith.slice(&scratch)];

    const got = httpDateEpochSeconds(raw) orelse return;

    // The first instant and the last the grammar can spell, so a value the
    // parser returned is inside the range the header could have named. The
    // year a sender has no way of meaning multiplied the day count past the 64
    // bits it has, and what came back was a date at the opposite end of the
    // calendar: a header that overflows is a run that waits for years, or one
    // that stops waiting at all.
    const first = daysFromCivil(1, 1, 1) * @as(i64, std.time.s_per_day);
    // The widest year the digit count above can spell, so the bound moves with
    // the width rather than restating it.
    const widest_year = std.math.pow(i64, 10, http_date_year_digits) - 1;
    const last = daysFromCivil(widest_year, 12, 31) * @as(i64, std.time.s_per_day) +
        23 * @as(i64, std.time.s_per_hour) + 59 * @as(i64, std.time.s_per_min) + 60;
    if (got < first or got > last) {
        std.debug.print("\nhttp_date: '{s}' reads as {d}, outside {d}..{d}\n", .{ raw, got, first, last });
        return error.TestUnexpectedResult;
    }

    // The day count the header's own fields name, counted by the calendar
    // below, against the one the parser's arithmetic arrived at. The two come
    // out of different code over the same bytes, so a leap rule, a month length
    // or an off-by-one either of them has is a disagreement rather than a value
    // that is wrong in both halves at once. The lookups behind the fields are
    // the module's own, which the unit test above pins month by month; what is
    // compared here is the arithmetic they feed. The clock is carried across
    // whole, so a leap second (23:59:60) counts as the day it belongs to
    // rather than rolling into the one after it.
    const after_comma = raw[std.mem.indexOfScalar(u8, raw, ',').? + 1 ..];
    var fields = std.mem.tokenizeScalar(u8, after_comma, ' ');
    const spelled_day = std.fmt.parseInt(u32, fields.next().?, 10) catch return;
    const spelled_month = monthFromName(fields.next().?) orelse return;
    const spelled_year = httpDateYear(fields.next().?) orelse return;
    var clock = std.mem.splitScalar(u8, fields.next().?, ':');
    const spelled_hour = std.fmt.parseInt(i64, clock.next().?, 10) catch return;
    const spelled_minute = std.fmt.parseInt(i64, clock.next().?, 10) catch return;
    const spelled_second = std.fmt.parseInt(i64, clock.next().?, 10) catch return;
    const want = stdDaysFromCivil(spelled_year, spelled_month, spelled_day) * @as(i64, std.time.s_per_day) +
        spelled_hour * @as(i64, std.time.s_per_hour) +
        spelled_minute * @as(i64, std.time.s_per_min) + spelled_second;
    if (got != want) {
        std.debug.print("\nhttp_date: '{s}' reads as {d}, the calendar says {d}\n", .{ raw, got, want });
        return error.TestUnexpectedResult;
    }

    // The instant written back the way a server would spell it reads as itself.
    // The date is rebuilt from the epoch by the standard library's own calendar
    // rather than by `daysFromCivil`, so a century rule or a month length the
    // forward path gets wrong is caught here rather than being asserted against
    // itself. The library counts days forward from 1970, so a date before the
    // epoch is held to the range above and nothing else.
    //
    // The leap second at 23:59:60 on the last day the grammar can spell is the
    // one value the parser hands back that it does not read back: it names an
    // instant one second past the last the four-digit year field can carry.
    // Nothing downstream cares (a caller only ever subtracts it from a clock),
    // so it is held to the range above and the round trip starts after it.
    if (got < 0 or got >= last) return;
    var header: [64]u8 = undefined;
    const written = writeHttpDate(got, &header) catch |err| {
        std.debug.print("\nhttp_date: {d} does not fit an IMF-fixdate: {t}\n", .{ got, err });
        return err;
    };
    const again = httpDateEpochSeconds(written) orelse {
        std.debug.print("\nhttp_date: '{s}' does not read back from {d}\n", .{ written, got });
        return error.TestUnexpectedResult;
    };
    if (again != got) {
        std.debug.print("\nhttp_date: '{s}' reads as {d} and again as {d}\n", .{ written, got, again });
        return error.TestUnexpectedResult;
    }
}

/// `seconds` as the IMF-fixdate a server would have sent it, into `buf`.
///
/// A caller building a `Retry-After` date writes the header with this rather
/// than spelling the calendar a second time, so the header it hands its own
/// parser is one the two agree on by construction.
///
/// The weekday is named from the day count with 1970-01-01 (a Thursday) as the
/// zero, and the parser is documented not to check that field, so it is the one
/// part of the round trip left unverified.
///
/// `error.OutOfRange` for a `seconds` the calendar below cannot name, rather
/// than a date produced by a narrowing nobody checked. Two ends are refused,
/// and each of them used to be something worse than a refusal.
///
/// The low end is 1970-01-01T00:00:00Z. Below it the day count is negative,
/// and `@intCast` into the standard library's unsigned `EpochDay` trapped a
/// checked build and wrapped a release one into a date at the far end of the
/// calendar. The library's calendar counts days from the epoch and cannot name
/// a day before it, so a pre-epoch `seconds` has no spelling here at all.
///
/// The high end is 9999-12-31T23:59:59Z, the last year a four-digit IMF-fixdate
/// field can spell and the last one `httpDateYear` reads. Past it the year
/// `calculateYearDay` walks out to is past its own `u16`, and it reaches that
/// year one year at a time from 1970, so a value at the top of an `i64` was a
/// walk of billions of iterations before the arithmetic wrapped or trapped.
///
/// The range is a return rather than a clamp: a `Retry-After` a provider sent
/// before 1970 is not a wait this run can honour, and the caller falls back to
/// the backoff schedule, which is where every unreadable header goes.
pub fn writeHttpDate(seconds: i64, buf: []u8) ![]const u8 {
    if (seconds < first_http_date_seconds or seconds > last_http_date_seconds) return error.OutOfRange;
    // A floor and not a truncation, so a leap second (23:59:60) lands on the
    // day it belongs to rather than on the one before it. Both casts are exact
    // inside the range above, which is what makes them casts rather than a
    // narrowing nobody checked.
    const days: u47 = @intCast(@divFloor(seconds, std.time.s_per_day));
    const into_day: u17 = @intCast(@mod(seconds, std.time.s_per_day));
    const date: std.time.epoch.EpochDay = .{ .day = days };
    const year_and_day = date.calculateYearDay();
    const month_and_day = year_and_day.calculateMonthDay();
    const clock: std.time.epoch.DaySeconds = .{ .secs = into_day };
    return std.fmt.bufPrint(
        buf,
        "{s}, {d:0>2} {s} {d:0>4} {d:0>2}:{d:0>2}:{d:0>2} GMT",
        .{
            weekdays[@mod(days + weekday_epoch_offset, weekdays.len)],
            @as(u16, month_and_day.day_index) + 1,
            calendar_months[month_and_day.month.numeric() - 1],
            year_and_day.year,
            clock.getHoursIntoDay(),
            clock.getMinutesIntoHour(),
            clock.getSecondsIntoMinute(),
        },
    );
}

/// The weekday names in the order the epoch's own day falls in.
const weekdays = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };

/// How far the epoch's own day sits into `weekdays`: 1970-01-01 was a Thursday,
/// which is `weekdays[4]`: the fifth name, at index 4.
const weekday_epoch_offset: u47 = 4;

// The first and last second `writeHttpDate` will name: the epoch itself, and
// the last second of the last year a four-digit IMF-fixdate field can spell.
// The low end is the epoch rather than the grammar's own 0001-01-01 because
// the calendar below counts days from the epoch and has no day before it to
// name; the high end is the grammar's, worked out with the same civil-date
// arithmetic `httpDateEpochSeconds` uses, so both halves of a round trip are
// bounded by one rule rather than each naming its own.
const first_http_date_seconds: i64 = 0;
const last_http_date_seconds: i64 = daysFromCivil(10000, 1, 1) * std.time.s_per_day - 1;

// The body a streamed response arrives as, and the shapes that break a reader
// splitting it a line at a time. `std.testing.fuzz` runs this corpus through
// the harness on every `zig build test`, and through the fuzzer's mutations when
// the test binary is built in fuzz mode. A completion frame and a file's lines,
// the two byte orders a line ending arrives in, a line longer than one read, and
// the records that arrive with nothing between them.
const line_split_corpus = [_][]const u8{
    "",
    "\n",
    "\n\n\n",
    "\r\n",
    "data: [DONE]\n",
    "data: {\"choices\":[]}\ndata: [DONE]\n",
    "data: {\"choices\":[]}\r\ndata: [DONE]\r\n",
    "data: a\ndata: b\ndata: c\n",
    "one\ntwo\nthree\n",
    "a\n\nb\n",
    "\na\n\n",
    "data: fir",
    "st\ndata: second\n",
    "no trailing newline",
    "\r\r\n",
    "\n\r",
    "line\n\n\n\nline\n",
    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n",
    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\nb\ncccccccccccccccccccccccccccccccc\n",
};

test "a fuzzed body cut into lines loses no byte and searches none of them twice" {
    try std.testing.fuzz({}, fuzzLineSplit, .{ .corpus = &line_split_corpus });
}

fn fuzzLineSplit(_: void, smith: *std.testing.Smith) !void {
    const gpa = std.testing.allocator;
    var scratch: [256]u8 = undefined;
    const wire: []const u8 = if (smith.in) |seed| seed else scratch[0..smith.slice(&scratch)];

    // A read hands over whatever the network had, so the same bytes arrive
    // under a different split on every run. The size comes out of the input
    // itself, which keeps one byte arriving at a time in the corpus.
    const chunk: usize = if (wire.len == 0) 1 else 1 + @as(usize, wire[0]) % 8;

    var line_arena_state = std.heap.ArenaAllocator.init(gpa);
    defer line_arena_state.deinit();
    const lines = line_arena_state.allocator();

    var seen: std.ArrayList([]u8) = .empty;
    defer seen.deinit(gpa);

    // The stream loop's own shape: append what a read brought, drain the lines
    // it completed, drop what was consumed. The counter is what makes the scan
    // cost visible, so a `scanned` that is not lowered past the bytes already
    // consumed is a body searched again from the front on every read.
    var pending: std.ArrayList(u8) = .empty;
    defer pending.deinit(gpa);
    var scanned: usize = 0;
    var searched: usize = 0;

    var carried = wire;
    while (true) {
        const piece = carried[0..@min(chunk, carried.len)];
        carried = carried[piece.len..];
        try pending.appendSlice(gpa, piece);

        var start: usize = 0;
        while (true) {
            // Each call looks at exactly the bytes between the old cursor and
            // the new one, whether it found a newline or ran off the end.
            const was = scanned;
            const found = nextLineEnd(pending.items, &scanned);
            searched += scanned - was;
            const at = found orelse break;
            try seen.append(gpa, try lines.dupe(u8, pending.items[start..at]));
            start = at + 1;
        }
        dropPending(&pending, &scanned, start);
        if (carried.len == 0) break;
    }

    // Every byte of the body was looked at, and each of them once: the split is
    // linear in the size of what arrived, whatever the read boundaries were.
    try std.testing.expectEqual(wire.len, searched);

    // The lines the run would have carried are the ones a whole-body split
    // gives, in the same order and spelled the same way. A cursor that runs
    // past a line that has already arrived drops it; one that does not move
    // leaves it in the buffer and hands the next read a body that starts
    // halfway through a record. The count is the newlines, because a record
    // the body ends without ending is still in the buffer, held for the read
    // that would finish it.
    var newlines: usize = 0;
    for (wire) |byte| {
        if (byte == '\n') newlines += 1;
    }
    try std.testing.expectEqual(newlines, seen.items.len);

    var want = std.mem.splitScalar(u8, wire, '\n');
    for (seen.items) |line| {
        const expected = want.next() orelse {
            std.debug.print("\nline_split: no line left for {d} bytes\n", .{line.len});
            return error.TestUnexpectedResult;
        };
        try std.testing.expectEqualStrings(expected, line);
    }
}

// The response head a `Retry-After` is read out of, and the shapes that decide
// which line of it is the header. `std.testing.fuzz` runs this corpus through
// the harness on every `zig build test`, and through the fuzzer's mutations when
// the test binary is built in fuzz mode. The head both network paths read: the
// two header forms RFC 9110 defines, the spellings a gateway sends them in, a
// header name carrying its own whitespace, the same name twice, the name
// arriving after the blank line that ends the head, and a value that is neither
// a count nor a date.
const retry_after_corpus = [_][]const u8{
    "",
    "\r\n",
    "\r\n\r\n",
    "HTTP/1.1 429 Too Many Requests\r\n\r\n",
    "HTTP/1.1 429 Too Many Requests\r\nretry-after: 30\r\n\r\n",
    "HTTP/1.1 429 Too Many Requests\r\nRetry-After: 30\r\n\r\n",
    "HTTP/1.1 429 Too Many Requests\r\nRETRY-AFTER:30\r\n\r\n",
    "HTTP/1.1 429 Too Many Requests\r\nretry-after:0\r\n\r\n",
    "HTTP/1.1 429 Too Many Requests\r\nretry-after : 30\r\n\r\n",
    "HTTP/1.1 429 Too Many Requests\r\nretry-after:\t30\t\r\n\r\n",
    // The first one is the one read, so a gateway that sends two does not get
    // the second one's wait.
    "HTTP/1.1 429 Too Many Requests\r\nretry-after: 5\r\nretry-after: 900\r\n\r\n",
    // A name that only contains the header, and one it is a prefix of.
    "HTTP/1.1 429 Too Many Requests\r\nx-retry-after: 30\r\n\r\n",
    "HTTP/1.1 429 Too Many Requests\r\nretry-after-extended: 30\r\n\r\n",
    // The blank line ends the head, so a body carrying the name is not a header.
    "HTTP/1.1 429 Too Many Requests\r\ncontent-length: 2\r\n\r\nretry-after: 30",
    "HTTP/1.1 429 Too Many Requests\r\n\r\nretry-after: 0",
    "retry-after: 30",
    "retry-after: 30\r\n",
    "HTTP/1.1 429 Too Many Requests\r\nretry-after: Wed, 21 Oct 2026 07:28:00 GMT\r\n\r\n",
    "HTTP/1.1 429 Too Many Requests\r\nretry-after: Sun, 06 Nov 1994 08:49:37 GMT\r\n\r\n",
    "HTTP/1.1 429 Too Many Requests\r\nretry-after: 99999999999\r\n\r\n",
    "HTTP/1.1 429 Too Many Requests\r\nretry-after: 99999999999999999999999\r\n\r\n",
    "HTTP/1.1 429 Too Many Requests\r\nretry-after: -1\r\n\r\n",
    "HTTP/1.1 429 Too Many Requests\r\nretry-after: +30\r\n\r\n",
    "HTTP/1.1 429 Too Many Requests\r\nretry-after: 1.5\r\n\r\n",
    "HTTP/1.1 429 Too Many Requests\r\nretry-after: soon\r\n\r\n",
    "HTTP/1.1 429 Too Many Requests\r\nretry-after:\r\n\r\n",
    "HTTP/1.1 429 Too Many Requests\r\nretry-after:   \r\n\r\n",
    "HTTP/1.1 429 Too Many Requests\r\nnocolon\r\nretry-after: 30\r\n\r\n",
    "HTTP/1.1 429 Too Many Requests\r\n: 30\r\n\r\n",
    "HTTP/1.1 429 Too Many Requests\r\nRetry-After: 30\r\nContent-Type: text/html\r\n\r\n",
    // A lone LF between the lines is not the framing RFC 9110 spells, so the
    // head is one line and there is no header on it.
    "HTTP/1.1 429 Too Many Requests\nretry-after: 30\n\n",
    "HTTP/1.1 429 Too Many Requests\rretry-after: 30\r\r",
    "HTTP/1.1 429 Too Many Requests\r\nretry-after: \x00\x001\r\n\r\n",
    "HTTP/1.1 429 Too Many Requests\r\nretry-after: 30\x00\r\n\r\n",
    "HTTP/1.1 429 Too Many Requests\r\nretry-after: 30\r\n\n\r\n",
    "HTTP/1.1 429 Too Many Requests\r\nretry-after: Wed, 21 Oct 2026 07:28:00 GMT\r\nretry-after: 5\r\n\r\n",
    // The ends of the year range the four-digit year field spells, which are
    // the widest gaps a date can ask to be measured against a clock. The clock
    // the fuzz harness builds out of its own bytes reaches either side of the
    // epoch, so these are the pairs whose difference was never representable.
    "HTTP/1.1 429 Too Many Requests\r\nretry-after: Mon, 01 Jan 0001 00:00:00 GMT\r\n\r\n",
    "HTTP/1.1 429 Too Many Requests\r\nretry-after: Fri, 31 Dec 9999 23:59:59 GMT\r\n\r\n",
};

test "a fuzzed Retry-After head waits for the header it names, and never past the cap" {
    try std.testing.fuzz({}, fuzzRetryAfter, .{ .corpus = &retry_after_corpus });

    // The corpus has to reach both answers, or the assertions below never fire:
    // a counted wait and a head with no header on it.
    try std.testing.expectEqual(@as(?u64, 30_000), retryAfterMs("HTTP/1.1 429\r\nretry-after: 30\r\n\r\n", 0));
    try std.testing.expectEqual(@as(?u64, null), retryAfterMs("HTTP/1.1 429\r\ncontent-length: 0\r\n\r\n", 0));
}

fn fuzzRetryAfter(_: void, smith: *std.testing.Smith) !void {
    var scratch: [4 * 1024]u8 = undefined;
    const head: []const u8 = if (smith.in) |seed| seed else scratch[0..smith.slice(&scratch)];
    // The clock is the caller's, and both forms of the header are measured
    // against it, so it is a second set of the fuzzer's bytes rather than a
    // constant: a date and a clock either side of each other is the pair that
    // decides whether the wait is the difference or the ceiling.
    const now: i64 = if (smith.in) |_|
        1_700_000_000
    else clock: {
        var now_bytes: [8]u8 = undefined;
        if (smith.slice(&now_bytes) < 8) break :clock 0;
        break :clock @bitCast(std.mem.readInt(u64, &now_bytes, .little));
    };

    const got = retryAfterMs(head, now);

    // A value off the wire sets a deadline, so it is bounded by the same cap
    // every caller's own ceiling is: a header naming a wait past it is the cap,
    // and one naming a wait before the clock is zero rather than a wrap.
    if (got) |ms| try std.testing.expect(ms <= max_retry_after_ms);

    // The blank line ends the head. Whatever a body spells after it is not a
    // header, so a response that names the wait in its body alone is a head with
    // no header on it: reading one there is a deadline a server's error page
    // chose, which is the one input here that arrives without being asked for.
    if (std.mem.indexOf(u8, head, "\r\n\r\n")) |end| {
        try std.testing.expectEqual(
            retryAfterMs(head[0..end], now),
            got,
        );
    }

    // A header with no colon is a line and not a header, and the name is
    // compared whole, so a line that merely ends in the name is not this one.
    // Both are decided by finding the header the same way the reader does, and
    // a reader that disagreed with its own rule about where a header ends is a
    // reader that reads a body or a different name.
    if (firstRetryAfterLine(head)) |value| {
        // What the first header names is what the caller waits for, and no
        // later header changes it.
        if (std.fmt.parseInt(u64, value, 10)) |seconds| {
            try std.testing.expectEqual(@min(seconds *| std.time.ms_per_s, max_retry_after_ms), got);
        } else |_| {}
    } else {
        try std.testing.expectEqual(@as(?u64, null), got);
    }
}

/// The value of the first `Retry-After` header on the head, read by a scan that
/// does not share the reader's shape: the reader splits the head on its line
/// endings and drops the first segment, and this one walks the bytes to the
/// first blank line and reads the name off each line. Two readings of one
/// header block, so a framing rule either of them gets wrong is a disagreement
/// rather than a value that is wrong in both halves at once.
fn firstRetryAfterLine(head: []const u8) ?[]const u8 {
    var rest = head;
    // The status line is the first line and names no header, so the scan starts
    // after it and a head that is nothing but one line has no header on it.
    const status_end = std.mem.indexOf(u8, rest, "\r\n") orelse return null;
    rest = rest[status_end + 2 ..];
    while (true) {
        const at = std.mem.indexOf(u8, rest, "\r\n");
        // A head the sender stopped writing short ends on a line carrying no
        // terminator of its own, and the reader splits on the sequence rather
        // than on the terminator, so it reads that line. Skipping it here made
        // the two readings disagree on a truncated response, and the fuzz check
        // that compares them would have failed on a header the reader found.
        const line = if (at) |i| rest[0..i] else rest;
        if (line.len == 0) return null;
        if (std.mem.indexOfScalar(u8, line, ':')) |colon| {
            if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " \t"), "retry-after")) {
                return std.mem.trim(u8, line[colon + 1 ..], " \t");
            }
        }
        // The line just read had no terminator of its own, so there is no line
        // after it to read.
        const at_index = at orelse return null;
        rest = rest[at_index + 2 ..];
    }
}

/// Days from 1970-01-01 to the date the header spells, counted the long way.
///
/// `daysFromCivil` reaches the number through the closed form that shifts the
/// year to start in March; this walks the same days one year and one month at a
/// time, off the standard library's own year length. Two implementations of one
/// count, so a leap rule, a month length or an off-by-one either of them has is
/// a disagreement a fuzzer can see, where a value checked against itself stays
/// wrong in both halves at once.
fn stdDaysFromCivil(year: i64, month: u32, day: u32) i64 {
    var total: i64 = 0;
    var y: i64 = 1970;
    while (y < year) : (y += 1) total += std.time.epoch.getDaysInYear(@intCast(y));
    while (y > year) : (y -= 1) total -= std.time.epoch.getDaysInYear(@intCast(y - 1));
    var m: u32 = 1;
    while (m < month) : (m += 1)
        total += std.time.epoch.getDaysInMonth(@intCast(year), @enumFromInt(m));
    return total + @as(i64, day) - 1;
}

/// The most /proc/self/maps text `releaseDeadStack` reads. The `[stack]` line is near the end of a
/// listing this process keeps to a few kilobytes; a listing that outgrows the buffer loses that
/// line, and the function then releases nothing.
const maps_bytes = 16 * 1024;

/// Room kept between the caller's frame and the range handed back: the red zone below the stack
/// pointer, and a frame or a signal delivered while this runs.
const stack_slack_bytes = 8 * 1024;

/// Returns the pages of the main thread's stack below the caller's frame to the kernel.
///
/// A TLS handshake dirties a couple of hundred kilobytes of stack for a few milliseconds of work,
/// and the pages stay resident for the rest of the run, which is spent waiting on a model. The range
/// is clamped to the `[stack]` mapping that /proc/self/maps names and that holds the caller's frame,
/// because `MADV_DONTNEED` on any other private mapping discards live data: a caller on another
/// thread, or a listing with no such line, releases nothing. Best effort, so a failure is ignored.
pub fn releaseDeadStack() void {
    if (builtin.os.tag != .linux) return;
    var marker: u8 = 0;
    const sp = @intFromPtr(&marker);
    var buf: [maps_bytes]u8 = undefined;
    const linux = std.os.linux;
    const opened = linux.openat(linux.AT.FDCWD, "/proc/self/maps", .{ .CLOEXEC = true }, 0);
    if (linux.errno(opened) != .SUCCESS) return;
    const fd: i32 = @intCast(opened);
    defer _ = linux.close(fd);
    const got = linux.read(fd, &buf, buf.len);
    if (linux.errno(got) != .SUCCESS) return;
    var lines = std.mem.splitScalar(u8, buf[0..got], '\n');
    while (lines.next()) |line| {
        if (!std.mem.endsWith(u8, line, "[stack]")) continue;
        const dash = std.mem.findScalar(u8, line, '-') orelse return;
        const space = std.mem.findScalar(u8, line, ' ') orelse return;
        const start = std.fmt.parseUnsigned(usize, line[0..dash], 16) catch return;
        const end = std.fmt.parseUnsigned(usize, line[dash + 1 .. space], 16) catch return;
        if (sp < start or sp >= end) return;
        const top = std.mem.alignBackward(usize, sp -| stack_slack_bytes, std.heap.pageSize());
        if (top <= start) return;
        _ = linux.madvise(@ptrFromInt(start), top - start, linux.MADV.DONTNEED);
        return;
    }
}

/// Anonymous resident memory of this process in kB, from /proc/self/status.
fn rssAnonKb() !usize {
    const linux = std.os.linux;
    const opened = linux.openat(linux.AT.FDCWD, "/proc/self/status", .{ .CLOEXEC = true }, 0);
    if (linux.errno(opened) != .SUCCESS) return error.OpenFailed;
    const fd: i32 = @intCast(opened);
    defer _ = linux.close(fd);
    var buf: [8192]u8 = undefined;
    const got = linux.read(fd, &buf, buf.len);
    if (linux.errno(got) != .SUCCESS) return error.ReadFailed;
    const text = buf[0..got];
    const at = std.mem.find(u8, text, "RssAnon:") orelse return error.MissingField;
    var it = std.mem.tokenizeAny(u8, text[at + "RssAnon:".len ..], " \tkB\n");
    return std.fmt.parseUnsigned(usize, it.next() orelse return error.MissingField, 10);
}

/// Writes every page of a large stack array, then returns, leaving them dirty and dead.
fn dirtyStack() void {
    var pages: [512 * 1024]u8 = undefined;
    @memset(&pages, 0x5a);
    std.mem.doNotOptimizeAway(&pages);
}

test "releaseDeadStack gives back stack pages the caller no longer uses" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    // A stack the test runner already grew is not this test's to release, so the helper's pages are
    // measured as the difference, and only a drop of most of them counts.
    const before = try rssAnonKb();
    @call(.never_inline, dirtyStack, .{});
    const dirty = try rssAnonKb();
    releaseDeadStack();
    const after = try rssAnonKb();
    try std.testing.expect(dirty >= before + 384);
    try std.testing.expect(after + 384 <= dirty);
    // What the caller still uses is intact: a live array on this frame survives a release.
    const live = [_]u8{0xa5} ** 4096;
    releaseDeadStack();
    for (live) |byte| try std.testing.expectEqual(@as(u8, 0xa5), byte);
}

// A `..` that the walk could not carry out left the component under it in the
// answer, so `a/../b` resolved to `a/b`: the path the kernel opens and the one
// the credential check read were two different files. The relative prefix of a
// single name is the case, because `dirname` answers null for it and for the
// rooted prefix alike, and only the second of the two has to be kept.
test "a dot dot drops the component under it, and the root keeps its separator" {
    var name_buf: [std.fs.max_path_bytes]u8 = undefined;
    var cur_buf: [2 * std.fs.max_path_bytes]u8 = undefined;
    var next_buf: [2 * std.fs.max_path_bytes]u8 = undefined;
    const resolve = struct {
        fn call(path: []const u8, n: []u8, a: []u8, b: []u8) ![]const u8 {
            return resolveEveryComponent(std.testing.io, Io.Dir.cwd(), path, n, a, b);
        }
    }.call;

    try std.testing.expectEqualStrings("b", try resolve("a/../b", &name_buf, &cur_buf, &next_buf));
    try std.testing.expectEqualStrings("b", try resolve("a/b/../../b", &name_buf, &cur_buf, &next_buf));
    // Dropping the root instead of keeping it would read every component after
    // it against the working directory.
    try std.testing.expectEqualStrings("/b", try resolve("/../b", &name_buf, &cur_buf, &next_buf));
    try std.testing.expectEqualStrings("/a/b", try resolve("/a/./b", &name_buf, &cur_buf, &next_buf));
}

// A link in a directory component was replaced by what it names and the
// components behind it were dropped, so `sub/link/leaf` answered `sub/real2`
// and the credential check cleared a path whose last name the walk had never
// read. The tail is what the kernel opens after the target, so it belongs in
// the answer; each of the four spellings below names the same file.
test "a link in a directory component keeps the components behind it" {
    const io = std.testing.io;
    var name_buf: [std.fs.max_path_bytes]u8 = undefined;
    var cur_buf: [2 * std.fs.max_path_bytes]u8 = undefined;
    var next_buf: [2 * std.fs.max_path_bytes]u8 = undefined;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = tmp.dir;
    try dir.createDirPath(io, "sub");
    try dir.writeFile(io, .{ .sub_path = "sub/real2", .data = "" });
    try dir.symLink(io, "real2", "sub/link", .{});
    try dir.symLink(io, "sub/link", "chain", .{});
    try dir.symLink(io, "../real2", "sub/rel", .{});
    try dir.symLink(io, "/nonexistent/absolute/target", "link_to_abs", .{});

    const resolve = struct {
        fn call(d: Io.Dir, path: []const u8, n: []u8, a: []u8, b: []u8) ![]const u8 {
            return resolveEveryComponent(io, d, path, n, a, b);
        }
    }.call;
    try std.testing.expectEqualStrings("sub/real2/leaf", try resolve(dir, "sub/link/leaf", &name_buf, &cur_buf, &next_buf));
    // Two links in a row, the second spelled against the working directory.
    try std.testing.expectEqualStrings("sub/real2/leaf", try resolve(dir, "chain/leaf", &name_buf, &cur_buf, &next_buf));
    // A relative target is read against the directory holding the link, and the
    // `..` in it is walked like any other component.
    try std.testing.expectEqualStrings("real2/leaf", try resolve(dir, "sub/rel/leaf", &name_buf, &cur_buf, &next_buf));
    // An absolute target replaces the prefix outright, tail included.
    try std.testing.expectEqualStrings("/nonexistent/absolute/target/leaf", try resolve(dir, "link_to_abs/leaf", &name_buf, &cur_buf, &next_buf));
    // A link at the end of the path has no tail to carry.
    try std.testing.expectEqualStrings("sub/real2", try resolve(dir, "sub/link", &name_buf, &cur_buf, &next_buf));
}

// The bound the walk carries is on links, because only a link makes the walk
// start over on a path it has not read. Counting ordinary components against it
// answered a cycle for a deep path the kernel opens, and the caller skipped the
// credential check the answer was for.
test "a path of ordinary components is resolved, however deep" {
    var name_buf: [std.fs.max_path_bytes]u8 = undefined;
    var cur_buf: [2 * std.fs.max_path_bytes]u8 = undefined;
    var next_buf: [2 * std.fs.max_path_bytes]u8 = undefined;

    // Four times the link bound, so the count cannot pass under either bound.
    var want: std.ArrayList(u8) = .empty;
    defer want.deinit(std.testing.allocator);
    var i: usize = 0;
    while (i < 4 * max_symlink_depth) : (i += 1) try want.appendSlice(std.testing.allocator, "d/");
    try want.appendSlice(std.testing.allocator, "leaf");

    try std.testing.expectEqualStrings(
        want.items,
        try resolveEveryComponent(std.testing.io, Io.Dir.cwd(), want.items, &name_buf, &cur_buf, &next_buf),
    );
}

// The path a tool is handed is the model's, and the model picked it out of a
// tree, so the walk that settles it reads untrusted text: the separators, the
// `.` and `..` components, the names, and every spelling of a link a
// repository can commit. It is also the one decision whose failure sends a
// credential to the provider, and the walk is byte arithmetic over three
// fixed buffers, so a path that overflows one of them is a write past it rather
// than a refusal. The harness builds the links a tree really holds and runs
// the text over them. `std.testing.fuzz` runs this corpus on every
// `zig build test`, and through the fuzzer's mutations when the test binary is
// built in fuzz mode.
const resolve_path_corpus = [_][]const u8{
    "",
    ".",
    "..",
    "../..",
    "/",
    "//",
    "real",
    "sub",
    "sub/real2",
    "sub/link",
    "sub/link/leaf",
    "chain",
    "chain/leaf",
    "sub/mid/deep/leaf",
    "loop_a",
    "loop_b/leaf",
    "sub/../real",
    "../real",
    "a/../../real",
    "/../real",
    "sub/./real2",
    "sub//link",
    "sub/link/",
    "sub/rel",
    "rel_chain/leaf",
    "link_to_abs",
    "a" ** 200,
    ("sub/" ** 40) ++ "leaf",
    ("../" ** 40) ++ "real",
    ("../" ** 40) ++ "loop_a",
    ("a" ** 4095) ++ "/real",
    ("a" ** 4096),
    // A path whose composed bytes outgrow the walk's own buffers. The walk has
    // to refuse one of these rather than write past the buffer holding it.
    ("d/" ** 2100) ++ "leaf",
    ("d/" ** 2100) ++ "chain",
    ("a" ** 100 ++ "/") ** 45 ++ "leaf",
    ("a" ** 100 ++ "/") ** 45 ++ "sub/link",
    ("\u{202e}gnp/.env"),
    ".env",
    "sub/../.env",
};

test "a fuzzed path resolves to a path the walk can name, and names nothing else" {
    try std.testing.fuzz({}, fuzzResolvePath, .{ .corpus = &resolve_path_corpus });
}

fn fuzzResolvePath(_: void, smith: *std.testing.Smith) !void {
    var scratch: [8 * 1024]u8 = undefined;
    const text: []const u8 = if (smith.in) |seed| seed else scratch[0..smith.slice(&scratch)];

    // The links are the ones a tree holds: a chain of two, a pair that closes
    // on itself, one written relative to its own directory, another chain
    // behind that, and one absolute, whose target names a file no filesystem
    // carries because the walk does arithmetic and not a lookup.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = tmp.dir;
    try dir.writeFile(std.testing.io, .{ .sub_path = "real", .data = "" });
    try dir.createDirPath(std.testing.io, "sub");
    try dir.writeFile(std.testing.io, .{ .sub_path = "sub/real2", .data = "" });
    try dir.symLink(std.testing.io, "real2", "sub/link", .{});
    try dir.symLink(std.testing.io, "sub/link", "chain", .{});
    try dir.symLink(std.testing.io, "loop_b", "loop_a", .{});
    try dir.symLink(std.testing.io, "loop_a", "loop_b", .{});
    try dir.symLink(std.testing.io, "../real", "sub/rel", .{});
    try dir.symLink(std.testing.io, "sub/rel", "rel_chain", .{});
    // The target need not exist, because the walk reads the link and does
    // path arithmetic rather than looking the file up.
    const abs = "/nonexistent/absolute/target";
    try dir.symLink(std.testing.io, abs, "link_to_abs", .{});

    var name_buf: [std.fs.max_path_bytes]u8 = undefined;
    var cur_buf: [2 * std.fs.max_path_bytes]u8 = undefined;
    var next_buf: [2 * std.fs.max_path_bytes]u8 = undefined;

    const answer = resolveEveryComponent(std.testing.io, dir, text, &name_buf, &cur_buf, &next_buf) catch |err| switch (err) {
        // The two refusals the walk spells out, and nothing else: a name the
        // platform will not take is a bug in the harness or in the walk, and
        // a crash-only harness would say nothing about which it was.
        error.NameTooLong, error.SymlinkLoop => return,
        else => |e| return e,
    };

    // The answer is the walker's own bytes, not a slice that outlived the frame
    // and not one into a buffer the next component overwrites while the caller
    // still holds it. The empty slice the walk answers a path of only `.` and
    // `..` components with is the one answer that is in neither buffer.
    const start = @intFromPtr(answer.ptr);
    const owned = answer.len == 0 or
        (start >= @intFromPtr(&cur_buf) and start + answer.len <= @intFromPtr(&cur_buf) + cur_buf.len) or
        (start >= @intFromPtr(&next_buf) and start + answer.len <= @intFromPtr(&next_buf) + next_buf.len);
    try std.testing.expect(owned);

    // Only leading parents of a relative path remain: they cannot be
    // consumed without changing the directory the kernel starts from.
    const rest = if (std.mem.startsWith(u8, answer, &.{path_sep})) answer[1..] else answer;
    var words = std.mem.splitScalar(u8, rest, path_sep);
    var parents_allowed = !std.fs.path.isAbsolute(answer);
    while (words.next()) |word| {
        try std.testing.expect(!std.mem.eql(u8, word, "."));
        if (std.mem.eql(u8, word, "..")) {
            try std.testing.expect(parents_allowed);
        } else if (word.len != 0) parents_allowed = false;
    }

    // The same text over the same links answers the same bytes: a walk that
    // depended on what the buffers happened to hold would not.
    var name_again: [std.fs.max_path_bytes]u8 = undefined;
    var cur_again: [2 * std.fs.max_path_bytes]u8 = undefined;
    var next_again: [2 * std.fs.max_path_bytes]u8 = undefined;
    const again = resolveEveryComponent(std.testing.io, dir, text, &name_again, &cur_again, &next_again) catch |err| switch (err) {
        error.NameTooLong, error.SymlinkLoop => return,
        else => |e| return e,
    };
    try std.testing.expectEqualStrings(answer, again);
}

test "relative parent components reach links in the parent directory" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "child");
    try tmp.dir.createDirPath(io, ".secrets");
    try tmp.dir.symLink(io, ".secrets", "alias", .{});
    var child = try tmp.dir.openDir(io, "child", .{});
    defer child.close(io);
    var name_buf: [std.fs.max_path_bytes]u8 = undefined;
    var cur_buf: [2 * std.fs.max_path_bytes]u8 = undefined;
    var next_buf: [2 * std.fs.max_path_bytes]u8 = undefined;
    try std.testing.expectEqualStrings("../.secrets/token", try resolveEveryComponent(io, child, "../alias/token", &name_buf, &cur_buf, &next_buf));
    try std.testing.expectEqualStrings("../../leaf", try resolveEveryComponent(io, child, "../../leaf", &name_buf, &cur_buf, &next_buf));
}

// The instant a `Retry-After` date is written from has to be one the same
// parser can read back, and both ends of the `i64` it is spelled with are past
// the calendar's own range. Neither end was refused: a negative day count was
// narrowed into the library's unsigned `EpochDay`, which trapped a checked
// build and wrapped a release one into a date at the far end of the calendar,
// and a year past the four-digit field was reached by a walk of one year at a
// time out of 1970, which for the top of an `i64` is billions of iterations
// before it wraps. The round trip above covers what is inside; this holds the
// refusal, because a refusal is the only answer that is right at both ends.
test "a date past the calendar's own range is refused rather than narrowed into it" {
    var header: [64]u8 = undefined;
    // Below the epoch: the day count is negative, and the calendar counts days
    // from 1970 and has no day before it to name.
    try std.testing.expectError(error.OutOfRange, writeHttpDate(-1, &header));
    try std.testing.expectError(error.OutOfRange, writeHttpDate(std.math.minInt(i64), &header));
    // Above the last year a four-digit year field can spell, which is the last
    // year `httpDateYear` reads.
    try std.testing.expectError(error.OutOfRange, writeHttpDate(last_http_date_seconds + 1, &header));
    try std.testing.expectError(error.OutOfRange, writeHttpDate(std.math.maxInt(i64), &header));

    // The ends themselves are inside the range, and both are read back as
    // themselves: the range check is on the value, not on the calendar's edge.
    const first = try writeHttpDate(first_http_date_seconds, &header);
    try std.testing.expectEqualStrings("Thu, 01 Jan 1970 00:00:00 GMT", first);
    try std.testing.expectEqual(@as(?i64, first_http_date_seconds), httpDateEpochSeconds(first));
    const last = try writeHttpDate(last_http_date_seconds, &header);
    try std.testing.expectEqualStrings("Fri, 31 Dec 9999 23:59:59 GMT", last);
    try std.testing.expectEqual(@as(?i64, last_http_date_seconds), httpDateEpochSeconds(last));
}

// The clock a `Retry-After` date is read against, and the narrowing it used to
// do. The clock is a signed `i96` and this is an `i64`, so a machine whose
// wall clock is set before 1970 -- a container with no RTC, a host restored
// from a snapshot, a machine with a flat RTC battery -- reached the narrowing
// from below and the run ended on the first request that asked for the time.
// The same reading reaches past an `i64` on its own at the far end. Both ends
// saturate here, because what this feeds is a subtraction against a date a
// server sent, and a wrong answer to that is a wait of the wrong length.
test "the clock read for a Retry-After date is an i64 at both ends" {
    // The reading on this machine is inside the range, which is the ordinary
    // case and the one every other reading is measured against.
    const now = nowSeconds(std.testing.io);
    try std.testing.expect(now > 0);
    // A clock at either end of the range, against a date at either end of the
    // one the grammar spells. Neither pair of ends is a wait the run can take,
    // so both are answered rather than one of them overflowing the subtraction
    // that measures them: the widest gap is the cap, and a date already past
    // is zero. Before the subtraction was saturating the first of these four
    // trapped a checked build, on a machine whose clock reads what this spells.
    const past = "HTTP/1.1 429\r\nretry-after: Thu, 01 Jan 1970 00:00:00 GMT\r\n\r\n";
    const future = "HTTP/1.1 429\r\nretry-after: Fri, 31 Dec 9999 23:59:59 GMT\r\n\r\n";
    try std.testing.expectEqual(@as(?u64, max_retry_after_ms), retryAfterMs(past, std.math.minInt(i64)));
    try std.testing.expectEqual(@as(?u64, 0), retryAfterMs(past, std.math.maxInt(i64)));
    try std.testing.expectEqual(@as(?u64, max_retry_after_ms), retryAfterMs(future, std.math.minInt(i64)));
    try std.testing.expectEqual(@as(?u64, 0), retryAfterMs(future, std.math.maxInt(i64)));
    // And the same date against a clock in the ordinary range, which is the
    // case every other reading here is measured against.
    try std.testing.expectEqual(@as(?u64, 0), retryAfterMs(past, now));
    try std.testing.expectEqual(@as(?u64, max_retry_after_ms), retryAfterMs(future, now));
}
