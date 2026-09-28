//! Reply-style modes appended to the system prompt, with the levels set from
//! one TOML config.
//!
//! Two independent knobs, both a level the task asked for and both a prompt
//! fragment rather than a code path:
//!
//! - `caveman` compresses the prose the agent writes back. `lite`, `full`,
//!   `ultra` and the three wenyan variants trade words for output tokens
//!   without losing a command or a path.
//! - `ponytail` biases what the agent builds: reuse before new code, the
//!   standard library before a dependency, the smallest diff that fixes the
//!   root cause.
//!
//! Neither mode touches the tools, the request shape, or the conversation; the
//! text below is the whole feature. The wording is compiled in rather than read
//! from a skill directory, so a run needs nothing on disk but its config: a
//! level the config does not name still gets the compiled-in default.

const std = @import("std");

/// How terse the agent's own prose is. `ultra` is the default: a coding agent
/// is judged on the diff, and every paragraph about it is paid for on each
/// later turn.
pub const CavemanLevel = enum {
    off,
    lite,
    full,
    ultra,
    wenyan_lite,
    wenyan_full,
    wenyan_ultra,

    /// The spelling that goes in the config file and in the injected header,
    /// paired with the level it names. The one place a level's spelling is
    /// written: `name` and `parseCaveman` both read it, so a level cannot be
    /// added to the enum and forgotten by one of them.
    const levels = [_]struct { name: []const u8, level: CavemanLevel }{
        .{ .name = "off", .level = .off },
        .{ .name = "lite", .level = .lite },
        .{ .name = "full", .level = .full },
        .{ .name = "ultra", .level = .ultra },
        .{ .name = "wenyan-lite", .level = .wenyan_lite },
        .{ .name = "wenyan-full", .level = .wenyan_full },
        .{ .name = "wenyan-ultra", .level = .wenyan_ultra },
    };

    // Every level the enum has, spelled, exactly once. A count alone would
    // still let a duplicated level stand in for a missing one.
    comptime {
        if (levels.len != @typeInfo(CavemanLevel).@"enum".fields.len)
            @compileError("every CavemanLevel needs an entry in `levels`");
        for (levels, 0..) |row, i| {
            for (levels, 0..) |other, j| {
                if (i != j and row.level == other.level)
                    @compileError("a CavemanLevel is listed twice in `levels`");
            }
        }
    }

    /// The spelling that goes in the config file and in the injected header.
    pub fn name(self: CavemanLevel) []const u8 {
        for (levels) |row| if (row.level == self) return row.name;
        unreachable; // the comptime check above rules this out
    }
};

/// How lazily the agent builds. `full` by default: the discipline is the point
/// of running this harness, and `off` is one config line away.
pub const PonytailLevel = enum {
    off,
    lite,
    full,
    ultra,

    /// The spelling the config file and the injected header use, paired with
    /// the level it names. One source for both, as `CavemanLevel.levels` is.
    const levels = [_]struct { name: []const u8, level: PonytailLevel }{
        .{ .name = "off", .level = .off },
        .{ .name = "lite", .level = .lite },
        .{ .name = "full", .level = .full },
        .{ .name = "ultra", .level = .ultra },
    };

    comptime {
        if (levels.len != @typeInfo(PonytailLevel).@"enum".fields.len)
            @compileError("every PonytailLevel needs an entry in `levels`");
        for (levels, 0..) |row, i| {
            for (levels, 0..) |other, j| {
                if (i != j and row.level == other.level)
                    @compileError("a PonytailLevel is listed twice in `levels`");
            }
        }
    }

    /// The spelling that goes in the config file and in the injected header.
    pub fn name(self: PonytailLevel) []const u8 {
        for (levels) |row| if (row.level == self) return row.name;
        unreachable; // the comptime check above rules this out
    }
};

/// The two levels in force for a run.
pub const Style = struct {
    caveman: CavemanLevel = .ultra,
    ponytail: PonytailLevel = .full,

    /// The prompt fragment these levels add. Empty when both are off, so an
    /// `off`/`off` run sends exactly the system prompt it sent before styles
    /// existed.
    pub fn ruleset(self: Style, allocator: std.mem.Allocator) ![]u8 {
        var parts: std.ArrayList([]const u8) = .empty;
        // The list borrows the compiled-in fragments, so only its own array is
        // released; `concat` copies them into the returned slice.
        defer parts.deinit(allocator);
        if (self.caveman != .off) {
            try parts.appendSlice(allocator, &.{ "CAVEMAN MODE ACTIVE - level: ", self.caveman.name(), "\n" });
            if (isWenyan(self.caveman)) try parts.append(allocator, wenyan_line);
            try parts.appendSlice(allocator, &.{ cavemanBody(self.caveman), caveman_shared });
        }
        if (self.ponytail != .off) {
            if (parts.items.len > 0) try parts.append(allocator, "\n");
            try parts.appendSlice(allocator, &.{
                "PONYTAIL MODE ACTIVE - level: ", self.ponytail.name(), "\n",
                ponytailBody(self.ponytail),      ponytail_shared,
            });
        }
        return std.mem.concat(allocator, u8, parts.items);
    }

    /// Read the levels out of a TOML document. A missing key keeps the
    /// default, and an unrecognized level keeps the default too: the first
    /// offending key is returned so the caller can say so on stderr rather
    /// than silently running a level the user did not ask for. A key the file
    /// does not define is returned the same way, because a misspelled
    /// `caveman` would otherwise leave the default in force with nothing said.
    /// One bad value does not hide the keys after it, so the scan runs to the
    /// end of the document and every key it does understand still applies.
    ///
    /// Only `key = "value"` is understood, at the top level or under `[style]`.
    /// That is the whole config, so it does not need a TOML parser: the rest of
    /// the format (numbers, arrays, dates, nested tables) has nowhere to go.
    pub fn applyToml(self: *Style, text: []const u8) ?Problem {
        var ours = true;
        var unknown: ?Problem = null;
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            if (line[0] == '[') {
                // `[style]` scopes the keys below it to this config; any other
                // table belongs to something else and is skipped.
                ours = std.mem.eql(u8, std.mem.trim(u8, line, " \t[]"), "style");
                continue;
            }
            if (!ours) continue;
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            const key = std.mem.trim(u8, line[0..eq], " \t");
            // A line with nothing before the `=` names no key, so there is
            // nothing to report: naming the empty one would put a blank key
            // in the line the caller prints.
            if (key.len == 0) continue;
            const value = unquote(std.mem.trim(u8, line[eq + 1 ..], " \t"));
            if (std.mem.eql(u8, key, "caveman")) {
                if (parseCaveman(value)) |level| {
                    self.caveman = level;
                } else if (unknown == null) {
                    unknown = .{ .key = key, .bad_value = true };
                }
            } else if (std.mem.eql(u8, key, "ponytail")) {
                if (parsePonytail(value)) |level| {
                    self.ponytail = level;
                } else if (unknown == null) {
                    unknown = .{ .key = key, .bad_value = true };
                }
            } else if (unknown == null) {
                unknown = .{ .key = key, .bad_value = false };
            }
        }
        return unknown;
    }
};

/// A line of the config the reader could not use, so the caller can name it
/// instead of running with a level the file did not ask for.
pub const Problem = struct {
    /// The key as written in the file.
    key: []const u8,
    /// The key is one this file defines and the value names no level; false
    /// when the key itself is not one of them.
    bad_value: bool,
};

/// A quoted TOML value without its quotes, stopping at the closing quote so a
/// trailing `# comment` is not part of the level. A bare value is taken as
/// written: `caveman = ultra` is not valid TOML, but it is not worth an error
/// either.
fn unquote(raw: []const u8) []const u8 {
    if (raw.len < 2) return raw;
    const quote = raw[0];
    if (quote != '"' and quote != '\'') return raw;
    const end = std.mem.indexOfScalarPos(u8, raw, 1, quote) orelse return raw;
    return raw[1..end];
}

/// Case- and whitespace-insensitive, with a bare `wenyan` shorthand for
/// `wenyan-full`.
pub fn parseCaveman(value: []const u8) ?CavemanLevel {
    const v = std.mem.trim(u8, value, " \t\r\n");
    for (CavemanLevel.levels) |row| {
        if (std.ascii.eqlIgnoreCase(v, row.name)) return row.level;
    }
    if (std.ascii.eqlIgnoreCase(v, "wenyan")) return .wenyan_full;
    return null;
}

pub fn parsePonytail(value: []const u8) ?PonytailLevel {
    const v = std.mem.trim(u8, value, " \t\r\n");
    for (PonytailLevel.levels) |row| {
        if (std.ascii.eqlIgnoreCase(v, row.name)) return row.level;
    }
    return null;
}

fn isWenyan(level: CavemanLevel) bool {
    return switch (level) {
        .wenyan_lite, .wenyan_full, .wenyan_ultra => true,
        else => false,
    };
}

/// What survives every level. The compression is over prose only: a command,
/// a path, or a negation that changes the meaning is not filler, and a style
/// never overrides the output contract.
const caveman_shared =
    "\nTechnical terms, code, commands, file paths and exact error strings are never compressed.\n" ++
    "Never drop not, never, no, only or except when that flips the meaning, and never drop a\n" ++
    "required code or step to save words.\n" ++
    "Security warnings and irreversible-action confirmations are written in complete, plain English.\n" ++
    "Code, commit messages, docs and anything else written for other people stay normal prose.\n";

const wenyan_line = "Write the reply in classical Chinese (\u{6587}\u{8a00}\u{6587}).\n";

fn cavemanBody(level: CavemanLevel) []const u8 {
    return switch (level) {
        .lite, .wenyan_lite => "Drop filler (just, really, basically, simply), pleasantries and hedging. Keep articles and\n" ++
            "whole sentences. One idea per sentence.\n",
        .full, .wenyan_full => "Drop articles, filler, pleasantries and hedging. Fragments are fine. Short synonyms beat\n" ++
            "long ones. One line per tool result, and no line to narrate a tool call. No preamble, no\n" ++
            "restating the request, no closing summary.\n",
        else => "Maximum compression. Drop articles, filler, pleasantries, hedging, and conjunctions whose\n" ++
            "meaning survives without them. One word where one word is enough. Fragments are fine.\n" ++
            "State each fact once. No preamble, no restating the request, no closing summary, no\n" ++
            "tool-call narration, no decorative tables or emoji.\n",
    };
}

fn ponytailBody(level: PonytailLevel) []const u8 {
    return switch (level) {
        .lite => "Prefer reuse over new code: look for a helper, type or pattern the repository already has\n" ++
            "before writing a new one. Use the standard library before adding a dependency.\n",
        .full => "Prefer the laziest correct change. Ask first whether the change needs to exist at all; if it\n" ++
            "does not, say so in one line. Reuse a helper, type or pattern the repository already has\n" ++
            "before writing a new one. Use the standard library and native platform features before\n" ++
            "adding code or a dependency. One line beats fifty. Fix the root cause, not the symptom:\n" ++
            "grep every caller of the function you are about to touch. No unrequested abstractions, no\n" ++
            "scaffolding for later, deletion over addition. Mark a deliberate shortcut that has a real\n" ++
            "ceiling with a comment naming that ceiling and the upgrade path.\n",
        else => "Prefer the laziest correct change, taken as far as it goes. Ask first whether the change\n" ++
            "needs to exist at all; if it does not, say so in one line. Reuse what the repository\n" ++
            "already has, then the standard library, then a native platform feature. Ship the smallest\n" ++
            "diff that fixes the root cause, not the symptom: grep every caller of the function you\n" ++
            "touch. No unrequested abstractions, no scaffolding for later, deletion over addition. Mark\n" ++
            "a deliberate shortcut that has a real ceiling with a comment naming that ceiling and the\n" ++
            "upgrade path. Then question the change in the same reply: what a larger version would\n" ++
            "add, and when it would be worth adding.\n",
    };
}

/// What laziness never buys: the guard rails come before the minimal diff.
const ponytail_shared =
    "Never simplify away input validation at a trust boundary, error handling that prevents data\n" ++
    "loss, security measures, accessibility, or anything the task explicitly asks for. Leave one\n" ++
    "runnable check behind for non-trivial logic.\n";

// A style is prompt text, so the tests assert the exact policy that reaches the
// provider: which levels switch a block on, and that prose limits never
// contradict the output contract.
test "a level off in both knobs adds nothing to the prompt" {
    const gpa = std.testing.allocator;
    const empty = try (Style{ .caveman = .off, .ponytail = .off }).ruleset(gpa);
    defer gpa.free(empty);
    try std.testing.expectEqualStrings("", empty);
}

test "the defaults are caveman ultra and ponytail full" {
    const style: Style = .{};
    try std.testing.expectEqual(CavemanLevel.ultra, style.caveman);
    try std.testing.expectEqual(PonytailLevel.full, style.ponytail);

    const gpa = std.testing.allocator;
    const block = try style.ruleset(gpa);
    defer gpa.free(block);
    try std.testing.expect(std.mem.startsWith(u8, block, "CAVEMAN MODE ACTIVE - level: ultra\n"));
    try std.testing.expect(std.mem.indexOf(u8, block, "PONYTAIL MODE ACTIVE - level: full") != null);
    try std.testing.expect(std.mem.indexOf(u8, block, "Never drop not, never, no, only or except") != null);
    // Both defaults have to agree with the levels the config parser accepts.
    try std.testing.expectEqual(CavemanLevel.ultra, parseCaveman(style.caveman.name()).?);
    try std.testing.expectEqual(PonytailLevel.full, parsePonytail(style.ponytail.name()).?);
}

test "the ponytail block is added only when its level is not off" {
    const gpa = std.testing.allocator;
    const block = try (Style{ .caveman = .off, .ponytail = .full }).ruleset(gpa);
    defer gpa.free(block);
    try std.testing.expect(std.mem.startsWith(u8, block, "PONYTAIL MODE ACTIVE - level: full\n"));
    try std.testing.expect(std.mem.indexOf(u8, block, "CAVEMAN") == null);
    try std.testing.expect(std.mem.indexOf(u8, block, "root cause, not the symptom") != null);
}

test "levels parse from every spelling the config may use" {
    try std.testing.expectEqual(CavemanLevel.ultra, parseCaveman(" Ultra ").?);
    try std.testing.expectEqual(CavemanLevel.wenyan_full, parseCaveman("wenyan").?);
    try std.testing.expectEqual(CavemanLevel.wenyan_ultra, parseCaveman("WENYAN-ULTRA").?);
    try std.testing.expectEqual(CavemanLevel.off, parseCaveman("off").?);
    try std.testing.expect(parseCaveman("brief") == null);
    try std.testing.expectEqual(PonytailLevel.full, parsePonytail("full").?);
    try std.testing.expect(parsePonytail("review") == null);
}

// The spelling a level is written with is the one the config parser has to
// accept and the injected header has to name. Round-tripping every level is
// what keeps the table and the two readers from drifting apart.
test "every level round-trips through the spelling it is written with" {
    for (std.enums.values(CavemanLevel)) |level| {
        try std.testing.expectEqual(level, parseCaveman(level.name()).?);
    }
    for (std.enums.values(PonytailLevel)) |level| {
        try std.testing.expectEqual(level, parsePonytail(level.name()).?);
    }
}

test "the config sets levels and leaves absent or bad keys alone" {
    var style: Style = .{};
    try std.testing.expect(style.applyToml(
        \\# terseness of the reply
        \\caveman = "lite"
        \\
        \\ponytail = "ultra"   # how lazy the code is
        \\
    ) == null);
    try std.testing.expectEqual(CavemanLevel.lite, style.caveman);
    try std.testing.expectEqual(PonytailLevel.ultra, style.ponytail);

    // An absent key keeps the default; a bad one keeps it and is named.
    const bad = style.applyToml("ponytail = 'lazy'").?;
    try std.testing.expectEqualStrings("ponytail", bad.key);
    try std.testing.expect(bad.bad_value);
    try std.testing.expectEqual(PonytailLevel.ultra, style.ponytail);
    try std.testing.expect(style.applyToml("this is not a config") == null);
    try std.testing.expectEqual(CavemanLevel.lite, style.caveman);

    // A key this file does not define is a misspelling until proven otherwise,
    // and staying quiet about it leaves the default in force with the user
    // believing the file set it.
    const typo = style.applyToml("cavmen = \"off\"\n").?;
    try std.testing.expectEqualStrings("cavmen", typo.key);
    try std.testing.expect(!typo.bad_value);
    try std.testing.expectEqual(CavemanLevel.lite, style.caveman);
}

test "the config reads either root or [style] keys, and nothing else" {
    var style: Style = .{};
    try std.testing.expect(style.applyToml("[style]\ncaveman = \"lite\"\nponytail = \"lite\"\n") == null);
    try std.testing.expectEqual(CavemanLevel.lite, style.caveman);
    try std.testing.expectEqual(PonytailLevel.lite, style.ponytail);

    // A table that is not ours is somebody else's keys, not ours to read.
    try std.testing.expect(style.applyToml("[model]\ncaveman = \"off\"\n") == null);
    try std.testing.expectEqual(CavemanLevel.lite, style.caveman);

    // An empty value is a value the levels do not have.
    const empty = style.applyToml("caveman =\n").?;
    try std.testing.expectEqualStrings("caveman", empty.key);
    try std.testing.expect(empty.bad_value);
}

test "the wenyan levels ask for classical Chinese" {
    const gpa = std.testing.allocator;
    const block = try (Style{ .caveman = .wenyan_full, .ponytail = .off }).ruleset(gpa);
    defer gpa.free(block);
    try std.testing.expect(std.mem.indexOf(u8, block, "level: wenyan-full") != null);
    try std.testing.expect(std.mem.indexOf(u8, block, "classical Chinese") != null);
}

// The longest ruleset is wenyan caveman with ponytail both on: the wenyan line
// is the one fragment the caveman block adds conditionally, so this is the
// combination that contributes the most fragments.
test "the longest ruleset carries both blocks in full" {
    const gpa = std.testing.allocator;
    const block = try (Style{ .caveman = .wenyan_ultra, .ponytail = .ultra }).ruleset(gpa);
    defer gpa.free(block);
    // Every fragment each block is assembled from, in the order they are
    // joined. A fragment dropped here, or a wenyan level that stopped adding
    // its one line, leaves a rule the operator asked for that the model never
    // reads, and a level header on its own is the one case that still passes a
    // check for the header.
    const want = try std.mem.concat(gpa, u8, &.{
        "CAVEMAN MODE ACTIVE - level: wenyan-ultra\n",
        wenyan_line,
        cavemanBody(.wenyan_ultra),
        caveman_shared,
        "\nPONYTAIL MODE ACTIVE - level: ultra\n",
        ponytailBody(.ultra),
        ponytail_shared,
    });
    defer gpa.free(want);
    try std.testing.expectEqualStrings(want, block);
}

// The config file is the one input the tree hands the binary that nobody in
// the run wrote: a user edits it, a repository ships one, and it is read
// before the first request. `std.testing.fuzz` runs this corpus through the
// harness on every `zig build test` and through the fuzzer's mutations when
// the test binary is built in fuzz mode. The corpus covers the shapes a real
// config and a wrong one have: keys at the root and under `[style]`, a table
// that belongs to something else, single and double quotes, a value with a
// trailing comment, an unterminated quote, a key with no `=`, a bare value,
// a level spelled in a case or with a space, and the same key twice.
const toml_corpus = [_][]const u8{
    "",
    "\n\n\n",
    "# a comment\ncaveman = \"lite\"\n",
    "caveman = \"off\"\nponytail = \"off\"\n",
    "[style]\ncaveman = \"wenyan-lite\"\n",
    "[ model ]\ncaveman = \"lite\"\n",
    "[style\ncaveman = \"lite\"\n",
    "caveman",
    "caveman =\n",
    "caveman = \"\n",
    "caveman = 'full' # trailing\n",
    "caveman = ultra\n",
    "caveman = \"LITE\"\n",
    "caveman = \" wenyan \"\n",
    "caveman = \"wenyan\"\n",
    "ponytail = \"wenyan\"\n",
    "caveman = \"brief\"\nponytail = \"review\"\n",
    "caveman = \"off\"\ncaveman = \"ultra\"\n",
    "[style]\ncaveman = \"lite\"\n[model]\ncaveman = \"off\"\n",
    "[model]\ncaveman = \"off\"\n[style]\nponytail = \"ultra\"\n",
    "  caveman   =   \"lite\"  \r\n",
    "= \"lite\"\n",
    "[]\ncaveman = \"lite\"\n",
    "key_without_value = \n",
    "\u{0}caveman = \"lite\"\n",
    "[style]\n#caveman = \"off\"\ncaveman = \"wenyan-ultra\"\n",
    "caveman = \"\"\ncaveman = \"\"\n",
};

test "a fuzzed config leaves a style the prompt writer can spell" {
    try std.testing.fuzz({}, fuzzToml, .{ .corpus = &toml_corpus });
}

fn fuzzToml(_: void, smith: *std.testing.Smith) !void {
    const gpa = std.testing.allocator;
    var raw: [8 * 1024]u8 = undefined;
    const text: []const u8 = if (smith.in) |seed| seed else raw[0..smith.slice(&raw)];

    var style: Style = .{};
    const problem = style.applyToml(text);

    // The reader either found nothing to say or named a key that is in the
    // file, which is the whole claim a caller makes about the `Problem` it
    // turns into a line on stderr.
    if (problem) |p| {
        try std.testing.expect(p.key.len > 0);
        try std.testing.expect(std.mem.indexOf(u8, text, p.key) != null);
        // Only the two keys this file defines can hold a value it did not
        // recognize; any other key is somebody else's, and is named as such.
        if (p.bad_value) try std.testing.expect(std.mem.eql(u8, p.key, "caveman") or std.mem.eql(u8, p.key, "ponytail"));
    }

    // Whatever the file said, the levels in force are ones the parser can
    // name, so a level never reaches the prompt as a spelling nothing reads
    // back. The same text read twice says the same thing.
    try std.testing.expectEqual(style.caveman, parseCaveman(style.caveman.name()).?);
    try std.testing.expectEqual(style.ponytail, parsePonytail(style.ponytail.name()).?);
    var again: Style = .{};
    const again_problem = again.applyToml(text);
    try std.testing.expectEqual(style.caveman, again.caveman);
    try std.testing.expectEqual(style.ponytail, again.ponytail);
    try std.testing.expectEqual(problem == null, again_problem == null);

    // The block the run sends is built from the levels, so a fuzzed config can
    // only reach a prompt fragment that names the level it turned on.
    const block = try style.ruleset(gpa);
    defer gpa.free(block);
    if (style.caveman == .off and style.ponytail == .off) {
        try std.testing.expectEqualStrings("", block);
        return;
    }
    if (style.caveman != .off) {
        try std.testing.expect(std.mem.indexOf(u8, block, style.caveman.name()) != null);
        try std.testing.expect(std.mem.indexOf(u8, block, "CAVEMAN MODE ACTIVE") != null);
    }
    if (style.ponytail != .off) {
        const named = try std.fmt.allocPrint(gpa, "PONYTAIL MODE ACTIVE - level: {s}", .{style.ponytail.name()});
        defer gpa.free(named);
        try std.testing.expect(std.mem.indexOf(u8, block, named) != null);
    }
}
