//! Reply-style modes appended to the system prompt, with the levels set from a
//! TOML config and from `MICROAGENT_CAVEMAN` / `MICROAGENT_PONYTAIL`, which win
//! over the file.
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

    /// The spelling that goes in the config file and in the injected header: the
    /// tag name, with `_` written as the `-` the header names. Reading it off
    /// the enum rather than off a second table means a level added above is
    /// spelled by the header and accepted by the parser without either being
    /// told about it.
    pub fn name(self: CavemanLevel) []const u8 {
        return switch (self) {
            .wenyan_lite => "wenyan-lite",
            .wenyan_full => "wenyan-full",
            .wenyan_ultra => "wenyan-ultra",
            else => @tagName(self),
        };
    }
};

/// How lazily the agent builds. `full` by default: the discipline is the point
/// of running this harness, and `off` is one config line away.
pub const PonytailLevel = enum {
    off,
    lite,
    full,
    ultra,

    /// The spelling the config file and the injected header use, the tag name
    /// again: every level here is spelled the same way in the enum.
    pub fn name(self: PonytailLevel) []const u8 {
        return @tagName(self);
    }
};

/// The two levels in force for a run.
pub const Style = struct {
    caveman: CavemanLevel = .ultra,
    ponytail: PonytailLevel = .full,

    /// The most fragments a pair of levels contributes: three strings per knob's
    /// header, a wenyan line, one body and one shared block per knob, and the
    /// newline that separates the two blocks. 3 + 3 + 1 + 2 + 2 + 1 = 12.
    const ruleset_max_parts: usize = 12;

    /// The prompt fragment these levels add. Empty when both are off, so an
    /// `off`/`off` run sends exactly the system prompt it sent before styles
    /// existed.
    ///
    /// The fragments are a fixed handful of compiled-in strings, so the list of
    /// them is a stack array of the exact size rather than a list that grows:
    /// one allocation for the text, and none for the bookkeeping. The returned
    /// text is const, because nothing writes to it after it is joined.
    pub fn ruleset(self: Style, allocator: std.mem.Allocator) ![]const u8 {
        var parts: [ruleset_max_parts][]const u8 = undefined;
        var len: usize = 0;
        if (self.caveman != .off) {
            parts[len] = "CAVEMAN MODE ACTIVE - level: ";
            len += 1;
            parts[len] = self.caveman.name();
            len += 1;
            parts[len] = "\n";
            len += 1;
            if (isWenyan(self.caveman)) {
                parts[len] = wenyan_line;
                len += 1;
            }
            parts[len] = cavemanBody(self.caveman);
            len += 1;
            parts[len] = caveman_shared;
            len += 1;
        }
        if (self.ponytail != .off) {
            if (len > 0) {
                parts[len] = "\n";
                len += 1;
            }
            parts[len] = "PONYTAIL MODE ACTIVE - level: ";
            len += 1;
            parts[len] = self.ponytail.name();
            len += 1;
            parts[len] = "\n";
            len += 1;
            parts[len] = ponytailBody(self.ponytail);
            len += 1;
            parts[len] = ponytail_shared;
            len += 1;
        }
        return std.mem.concat(allocator, u8, parts[0..len]);
    }
};

/// A level named case- and whitespace-insensitively, or null when the value is
/// not one of the enum's names. Both levels are read this way, so a spelling one
/// of them accepts and the other does not is a drift this makes impossible.
fn parseLevel(comptime Level: type, value: []const u8) ?Level {
    const v = std.mem.trim(u8, value, " \t\r\n");
    for (std.enums.values(Level)) |level| {
        if (std.ascii.eqlIgnoreCase(v, level.name())) return level;
    }
    return null;
}

/// As `parseLevel`, with a bare `wenyan` shorthand for `wenyan-full`.
pub fn parseCaveman(value: []const u8) ?CavemanLevel {
    if (parseLevel(CavemanLevel, value)) |level| return level;
    if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, value, " \t\r\n"), "wenyan")) return .wenyan_full;
    return null;
}

pub fn parsePonytail(value: []const u8) ?PonytailLevel {
    return parseLevel(PonytailLevel, value);
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
        // A level off contributes nothing, for the reason `ruleset` gives: the
        // switch answers for the level it is given, and `.off` is a level like
        // any other here. The arm is spelled out rather than left to a default
        // so that a level added to the enum cannot land in the prose of the
        // strongest one by being forgotten.
        .off => "",
        .ultra, .wenyan_ultra => "Maximum compression. Drop articles, filler, pleasantries, hedging, and conjunctions whose\n" ++
            "meaning survives without them. One word where one word is enough. Fragments are fine.\n" ++
            "State each fact once. No preamble, no restating the request, no closing summary, no\n" ++
            "tool-call narration, no decorative tables or emoji.\n",
    };
}

fn ponytailBody(level: PonytailLevel) []const u8 {
    return switch (level) {
        .lite => "Prefer reuse over new code: look for a helper, type or pattern the repository already has\n" ++
            "before writing a new one. Use the standard library before adding a dependency.\n",
        .full => "Prefer the laziest correct change. Settle first whether the change needs to exist at all; if\n" ++
            "it does not, say so in one line. Reuse a helper, type or pattern the repository already has\n" ++
            "before writing a new one. Use the standard library and native platform features before\n" ++
            "adding code or a dependency. One line beats fifty. Fix the root cause, not the symptom:\n" ++
            "grep every caller of the function you are about to touch. No unrequested abstractions, no\n" ++
            "scaffolding for later, deletion over addition. Mark a deliberate shortcut that has a real\n" ++
            "ceiling with a comment naming that ceiling and the upgrade path.\n",
        // The arms are spelled out for the reason `cavemanBody` gives: a level
        // added to the enum cannot land in the prose of the strongest one by
        // being forgotten, and `.off` answers nothing here as it does there.
        .off => "",
        .ultra => "Prefer the laziest correct change, taken as far as it goes. Settle first whether the\n" ++
            "change needs to exist at all; if it does not, say so in one line. Reuse what the repository\n" ++
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

test "the wenyan levels ask for classical Chinese" {
    const gpa = std.testing.allocator;
    // All three, not one: a level left out of the switch that names them reads
    // the block without the one line the model writes its replies from.
    for ([_]CavemanLevel{ .wenyan_lite, .wenyan_full, .wenyan_ultra }) |level| {
        const block = try (Style{ .caveman = level, .ponytail = .off }).ruleset(gpa);
        defer gpa.free(block);
        try std.testing.expect(std.mem.indexOf(u8, block, level.name()) != null);
        try std.testing.expect(std.mem.indexOf(u8, block, wenyan_line) != null);
    }
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
