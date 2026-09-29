//! The one config file: reply-style levels, skills, and MCP servers.
//!
//! Three things are configured here, and each is a section of the same
//! document, because a second file for the servers would be a second answer to
//! "where is this run configured":
//!
//! ```toml
//! caveman  = "ultra"
//! ponytail = "full"
//! skills   = ["./skills", "~/.microagent/skills"]
//!
//! [[mcp]]
//! name    = "fs"
//! command = "npx"
//! args    = ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"]
//! env     = { LOG = "debug" }
//! ```
//!
//! Only the subset of TOML those three need is read: `key = value`, a quoted
//! or bare string, an array of strings, a `[[mcp]]` array of tables, and an
//! inline table of strings for `env`. Numbers, dates, nested tables and
//! dotted keys have nowhere to go, so they are not parsed and not missed.
//!
//! A line this reader cannot use is reported once, by `Problem`, and the rest
//! of the document still applies: one typo above a real setting does not leave
//! the whole file inert. A `#` comment trails a key, a value and a table
//! header, because the file the README hands out is written that way. A
//! leading byte order mark is dropped, so a file an editor saved with one
//! reads by its first key rather than by a key spelled with U+FEFF.

const std = @import("std");

const chat = @import("chat.zig");
const mcp_mod = @import("mcp.zig");
const style_mod = @import("style.zig");

/// One MCP server as the file declares it: the same fields `mcp_mod.Entry`
/// carries, built up a line at a time while a `[[mcp]]` table is open.
const Server = struct {
    name: []const u8 = "",
    command: []const u8 = "",
    args: []const []const u8 = &.{},
    env: []const [2][]const u8 = &.{},
};

/// What the file said, with the defaults for everything it did not say.
pub const Config = struct {
    style: style_mod.Style = .{},
    /// The skill directories the file named, or null when it named none and
    /// the default root applies. An empty list is a file that turned skills
    /// off, which is not the same statement as a file that did not mention
    /// them.
    skills: ?[]const []const u8 = null,
    /// The MCP servers the file declared, in the order the tables appear.
    mcp: []const mcp_mod.Entry = &.{},
    /// Commands denied from running via the bash tool.
    deny_commands: []const []const u8 = &.{},
    /// The first line the reader could not use, if any.
    problem: ?Problem = null,

    /// Records a problem unless one was already recorded: the first line that
    /// could not be used is the one named, and the scan still runs to the end
    /// of the document so every line after it still applies.
    pub fn note(self: *Config, problem: Problem) void {
        if (self.problem == null) self.problem = problem;
    }
};

/// A line of the config the reader could not use, so the caller can name it
/// instead of running with a setting the file did not ask for.
pub const Problem = struct {
    /// The key, table or entry as written in the file.
    key: []const u8,
    kind: Kind,

    pub const Kind = enum {
        /// A key this file defines whose value names nothing it accepts.
        bad_value,
        /// A key this file does not define: a misspelling until proven
        /// otherwise.
        unknown_key,
        /// A `[[mcp]]` table with no usable name or command, which is a
        /// server nothing can start.
        bad_server,
        /// Two `[[mcp]]` tables with the same name: their tools would collide
        /// on one exposed name.
        duplicate_server,
    };
};

/// The section the lines after a header belong to.
const Section = enum { top, style, commands, mcp, other };

/// Reads the document. Never fails: a document this reader cannot follow
/// whole is read as far as it can be, and the first line it could not use is
/// returned as `problem`.
pub fn parse(arena: std.mem.Allocator, text: []const u8) Config {
    var config: Config = .{};
    var section: Section = .top;
    var servers: std.ArrayList(Server) = .empty;
    var open: ?*Server = null;

    var lines = std.mem.splitScalar(u8, chat.stripBom(text), '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '[') {
            const header = tableName(line) orelse {
                // The line itself is what is named: it is a header this reader
                // cannot follow, and a reader told only "a table" would have to
                // search the file for which one.
                config.note(.{ .key = line, .kind = .unknown_key });
                section = .other;
                open = null;
                continue;
            };
            if (std.mem.eql(u8, header.name, "style")) {
                section = .style;
            } else if (std.mem.eql(u8, header.name, "commands") or std.mem.eql(u8, header.name, "command_filter")) {
                section = .commands;
            } else if (std.mem.eql(u8, header.name, "mcp") and header.array) {
                servers.append(arena, .{}) catch {
                    section = .other;
                    open = null;
                    continue;
                };
                open = &servers.items[servers.items.len - 1];
                section = .mcp;
            } else {
                // A table that is not ours is somebody else's keys: the file
                // may hold sections this build knows nothing about, and
                // naming every key under them would make a newer config
                // unusable on an older binary.
                section = .other;
                open = null;
            }
            continue;
        }
        if (section == .other) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse {
            config.note(.{ .key = line, .kind = .unknown_key });
            continue;
        };
        const key = std.mem.trim(u8, line[0..eq], " \t");
        if (key.len == 0) continue;
        const value_text = std.mem.trim(u8, line[eq + 1 ..], " \t");

        switch (section) {
            .style => styleOnly(&config, key, value_text),
            .top => topKey(&config, arena, key, value_text),
            .commands => commandsOnly(&config, arena, key, value_text),
            .mcp => if (open) |server| serverKey(&config, arena, server, key, value_text),
            .other => {},
        }
    }

    var entries: std.ArrayList(mcp_mod.Entry) = .empty;
    for (servers.items) |server| {
        // The name is half of every exposed tool name, so it is held to the
        // rule the server's own tool names are held to: `mcp__<server>__<tool>`
        // is what the model is offered, and a space or a `__` in the server
        // half makes a name no provider accepts and no model can spell.
        if (server.command.len == 0 or !mcp_mod.validName(server.name)) {
            config.note(.{ .key = "mcp", .kind = .bad_server });
            continue;
        }
        var duplicate = false;
        for (entries.items) |kept| {
            if (std.mem.eql(u8, kept.name, server.name)) {
                duplicate = true;
                break;
            }
        }
        if (duplicate) {
            config.note(.{ .key = server.name, .kind = .duplicate_server });
            continue;
        }
        entries.append(arena, .{
            .name = server.name,
            .command = server.command,
            .args = server.args,
            .env = server.env,
        }) catch break;
    }
    config.mcp = entries.items;
    return config;
}

/// A key at the top of the file, outside any table: the style levels may sit
/// here, and so may `skills` and `deny_commands` (or `command_filter`).
fn topKey(config: *Config, arena: std.mem.Allocator, key: []const u8, value_text: []const u8) void {
    if (levelKey(config, key, value_text)) return;
    if (std.mem.eql(u8, key, "skills")) {
        const dirs = stringArray(arena, value_text) orelse
            return config.note(.{ .key = key, .kind = .bad_value });
        config.skills = dirs;
        return;
    }
    if (std.mem.eql(u8, key, "deny_commands") or std.mem.eql(u8, key, "command_filter") or std.mem.eql(u8, key, "denied_commands")) {
        const list = parseCommandList(arena, value_text) orelse
            return config.note(.{ .key = key, .kind = .bad_value });
        addDenyCommands(config, arena, list);
        return;
    }
    config.note(.{ .key = key, .kind = .unknown_key });
}

/// A key under `[commands]` or `[command_filter]`.
fn commandsOnly(config: *Config, arena: std.mem.Allocator, key: []const u8, value_text: []const u8) void {
    if (std.mem.eql(u8, key, "deny") or std.mem.eql(u8, key, "deny_commands") or std.mem.eql(u8, key, "denied") or std.mem.eql(u8, key, "filter") or std.mem.eql(u8, key, "command_filter")) {
        const list = parseCommandList(arena, value_text) orelse
            return config.note(.{ .key = key, .kind = .bad_value });
        addDenyCommands(config, arena, list);
        return;
    }
    config.note(.{ .key = key, .kind = .unknown_key });
}

fn parseCommandList(arena: std.mem.Allocator, raw: []const u8) ?[]const []const u8 {
    if (stringArray(arena, raw)) |arr| return arr;
    const single = unquote(raw);
    const trimmed = std.mem.trim(u8, single, " \t\r\n");
    if (trimmed.len > 0 and trimmed[0] != '[' and trimmed[0] != '{') {
        const items = arena.alloc([]const u8, 1) catch return null;
        items[0] = trimmed;
        return items;
    }
    return null;
}

fn addDenyCommands(config: *Config, arena: std.mem.Allocator, list: []const []const u8) void {
    if (list.len == 0) return;
    if (config.deny_commands.len == 0) {
        config.deny_commands = list;
    } else {
        var merged: std.ArrayList([]const u8) = .empty;
        merged.appendSlice(arena, config.deny_commands) catch return;
        merged.appendSlice(arena, list) catch return;
        config.deny_commands = merged.items;
    }
}

/// A key under `[style]`: the same two levels the top of the file takes, and
/// nothing else, so `skills` there is a misspelling rather than a second way
/// to name the directories.
fn styleOnly(config: *Config, key: []const u8, value_text: []const u8) void {
    if (levelKey(config, key, value_text)) return;
    config.note(.{ .key = key, .kind = .unknown_key });
}

/// The two level keys, which the top of the file and `[style]` both accept.
/// True when the key was one of them, so the caller knows whether to read on.
fn levelKey(config: *Config, key: []const u8, value_text: []const u8) bool {
    if (std.mem.eql(u8, key, "caveman")) {
        if (style_mod.parseCaveman(unquote(value_text))) |level| config.style.caveman = level else config.note(.{ .key = key, .kind = .bad_value });
        return true;
    }
    if (std.mem.eql(u8, key, "ponytail")) {
        if (style_mod.parsePonytail(unquote(value_text))) |level| config.style.ponytail = level else config.note(.{ .key = key, .kind = .bad_value });
        return true;
    }
    return false;
}

/// One line inside an open `[[mcp]]` table.
fn serverKey(config: *Config, arena: std.mem.Allocator, server: *Server, key: []const u8, value_text: []const u8) void {
    if (std.mem.eql(u8, key, "name")) {
        server.name = unquote(value_text);
        return;
    }
    if (std.mem.eql(u8, key, "command")) {
        server.command = unquote(value_text);
        return;
    }
    if (std.mem.eql(u8, key, "args")) {
        server.args = stringArray(arena, value_text) orelse
            return config.note(.{ .key = key, .kind = .bad_value });
        return;
    }
    if (std.mem.eql(u8, key, "env")) {
        server.env = inlineTable(arena, value_text) orelse
            return config.note(.{ .key = key, .kind = .bad_value });
        return;
    }
    config.note(.{ .key = key, .kind = .unknown_key });
}

/// The name and shape of a table header line, which the caller has already
/// found opens with `[`. `[[mcp]]` is an array of tables and `[style]` is a
/// single one, so which brackets were written is part of what is read.
const Header = struct { name: []const u8, array: bool };

fn tableName(line: []const u8) ?Header {
    const array = std.mem.startsWith(u8, line, "[[");
    const open_at: usize = if (array) 2 else 1;
    const close = std.mem.lastIndexOfScalar(u8, line, ']') orelse return null;
    // The name ends before the bracket that closes it: one for a single table,
    // and two for an array, whose inner bracket is part of the header and not
    // of the name.
    const name_end = if (array) blk: {
        if (close == 0 or line[close - 1] != ']') return null;
        break :blk close - 1;
    } else close;
    if (name_end < open_at) return null;
    const rest = std.mem.trim(u8, line[close + 1 ..], " \t");
    if (rest.len != 0 and rest[0] != '#') return null;
    const name = std.mem.trim(u8, line[open_at..name_end], " \t");
    if (name.len == 0) return null;
    return .{ .name = name, .array = array };
}

/// A quoted TOML value without its quotes, stopping at the closing quote so a
/// trailing `# comment` is not part of the value. A bare value stops at a `#`
/// for the same reason; it is otherwise taken as written, because
/// `caveman = ultra` is not valid TOML but is not worth an error either.
///
/// The closing quote is looked for before any `#` is, so a `#` between the
/// quotes is text. A quoted value with no closing quote is returned as written
/// rather than cut at a `#` it may legitimately carry.
fn unquote(raw: []const u8) []const u8 {
    if (raw.len < 2) return raw;
    const quote = raw[0];
    if (quote == '"' or quote == '\'') {
        const end = std.mem.indexOfScalarPos(u8, raw, 1, quote) orelse return raw;
        return raw[1..end];
    }
    return raw[0 .. std.mem.indexOfScalar(u8, raw, '#') orelse raw.len];
}

/// An array of strings, or null when the text is not one. A bare `[]` is an
/// empty list, which is a statement the caller can tell from a missing key.
/// Elements may be quoted or bare, and a trailing comma is accepted, because
/// the file is written by hand.
fn stringArray(arena: std.mem.Allocator, raw: []const u8) ?[]const []const u8 {
    const text = std.mem.trim(u8, stripComment(raw), " \t");
    if (text.len < 2 or text[0] != '[' or text[text.len - 1] != ']') return null;
    const parts = splitQuoted(arena, text[1 .. text.len - 1], ',') orelse return null;
    var out: std.ArrayList([]const u8) = .empty;
    for (parts) |part| {
        const item = unquote(part);
        if (item.len == 0) continue;
        out.append(arena, item) catch return null;
    }
    return out.items;
}

/// An inline table of strings: `{ K = "v", J = "w" }`. Null when the text is
/// not one, which is how `env` is refused rather than silently dropped.
fn inlineTable(arena: std.mem.Allocator, raw: []const u8) ?[]const [2][]const u8 {
    const text = std.mem.trim(u8, stripComment(raw), " \t");
    if (text.len < 2 or text[0] != '{' or text[text.len - 1] != '}') return null;
    const parts = splitQuoted(arena, text[1 .. text.len - 1], ',') orelse return null;
    var out: std.ArrayList([2][]const u8) = .empty;
    for (parts) |pair| {
        if (pair.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse return null;
        const key = std.mem.trim(u8, pair[0..eq], " \t");
        const value = unquote(std.mem.trim(u8, pair[eq + 1 ..], " \t"));
        if (key.len == 0) return null;
        out.append(arena, .{ key, value }) catch return null;
    }
    return out.items;
}

/// A line without its trailing `#` comment, for the values that are lists
/// rather than single strings. `unquote` already does this for one value by
/// looking for the closing quote first; a list has several, so the cut is made
/// here, on a `#` that is not inside quotes.
fn stripComment(raw: []const u8) []const u8 {
    var quote: u8 = 0;
    for (raw, 0..) |c, i| {
        if (quote != 0) {
            if (c == quote) quote = 0;
            continue;
        }
        if (c == '"' or c == '\'') {
            quote = c;
            continue;
        }
        if (c == '#') return raw[0..i];
    }
    return raw;
}

/// The pieces of a bracketed value, split on `sep` outside quotes, so a comma
/// inside a quoted element is text rather than a separator. Null when a quote
/// is never closed, which is a line that cannot be read whole.
fn splitQuoted(arena: std.mem.Allocator, inner: []const u8, sep: u8) ?[]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var start: usize = 0;
    var quote: u8 = 0;
    for (inner, 0..) |c, i| {
        if (quote != 0) {
            if (c == quote) quote = 0;
            continue;
        }
        if (c == '"' or c == '\'') {
            quote = c;
            continue;
        }
        if (c == sep) {
            out.append(arena, std.mem.trim(u8, inner[start..i], " \t")) catch return null;
            start = i + 1;
        }
    }
    if (quote != 0) return null;
    out.append(arena, std.mem.trim(u8, inner[start..], " \t")) catch return null;
    return out.items;
}

// The config file is the one input the tree hands the binary that nobody in
// the run wrote: a user edits it, a repository ships one, and it is read before
// the first request. These tests drive the reader the way the shipped template
// and the fuzz corpus do, so the syntax the README documents and the syntax
// this file accepts cannot drift apart.

test "the config sets levels and leaves absent or bad keys alone" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const arena = state.allocator();

    const set = parse(arena,
        \\# terseness of the reply
        \\caveman = "lite"
        \\
        \\ponytail = "ultra"   # how lazy the code is
        \\
    );
    try std.testing.expect(set.problem == null);
    try std.testing.expectEqual(style_mod.CavemanLevel.lite, set.style.caveman);
    try std.testing.expectEqual(style_mod.PonytailLevel.ultra, set.style.ponytail);

    // An absent key keeps the default; a bad one keeps it and is named.
    const bad = parse(arena, "ponytail = 'lazy'");
    try std.testing.expectEqualStrings("ponytail", bad.problem.?.key);
    try std.testing.expectEqual(Problem.Kind.bad_value, bad.problem.?.kind);
    try std.testing.expectEqual(style_mod.PonytailLevel.full, bad.style.ponytail);

    // A key this file does not define is a misspelling until proven otherwise,
    // and staying quiet about it leaves the default in force with the user
    // believing the file set it.
    const typo = parse(arena, "cavmen = \"off\"\n");
    try std.testing.expectEqualStrings("cavmen", typo.problem.?.key);
    try std.testing.expectEqual(Problem.Kind.unknown_key, typo.problem.?.kind);

    // A bad key or a bad value does not stop the scan: the document is read to
    // the end and every key after the problem still applies, so one typo above
    // a real setting does not leave the whole file inert. The first problem is
    // the one named, whichever it came first.
    const after = parse(arena, "cavmen = \"off\"\nponytail = 'lazy'\ncaveman = \"ultra\"\n");
    try std.testing.expectEqualStrings("cavmen", after.problem.?.key);
    try std.testing.expectEqual(style_mod.CavemanLevel.ultra, after.style.caveman);
    try std.testing.expectEqual(style_mod.PonytailLevel.full, after.style.ponytail);

    // A line with nothing before the `=` names no key, so it is not a problem
    // to report, and the key after it still applies.
    const blank = parse(arena, "= \"lite\"\ncaveman = \"off\"\n");
    try std.testing.expect(blank.problem == null);
    try std.testing.expectEqual(style_mod.CavemanLevel.off, blank.style.caveman);
}

test "the config reads either root or [style] keys, and nothing else" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const arena = state.allocator();

    const tabled = parse(arena, "[style]\ncaveman = \"lite\"\nponytail = \"lite\"\n");
    try std.testing.expect(tabled.problem == null);
    try std.testing.expectEqual(style_mod.CavemanLevel.lite, tabled.style.caveman);
    try std.testing.expectEqual(style_mod.PonytailLevel.lite, tabled.style.ponytail);

    // A table that is not ours is somebody else's keys, not ours to read.
    const other = parse(arena, "[model]\ncaveman = \"off\"\n");
    try std.testing.expect(other.problem == null);
    try std.testing.expectEqual(style_mod.CavemanLevel.ultra, other.style.caveman);

    // An empty value is a value the levels do not have.
    const empty = parse(arena, "caveman =\n");
    try std.testing.expectEqualStrings("caveman", empty.problem.?.key);
    try std.testing.expectEqual(Problem.Kind.bad_value, empty.problem.?.kind);

    // [style] is the two levels and nothing else, so the skills key does not
    // work there: one spelling per setting.
    const skills_tabled = parse(arena, "[style]\nskills = [\"a\"]\n");
    try std.testing.expectEqualStrings("skills", skills_tabled.problem.?.key);
    try std.testing.expect(skills_tabled.skills == null);
}

// A `#` comment trails a key, a value and a table header alike, and the README
// says so. Reading the name off the whole header line made a labelled table
// name no table at all, so every key under it was reported as an unknown key.
test "a comment trails a key, a value and a table header" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const arena = state.allocator();

    const commented = parse(
        arena,
        "# the reply style.\n" ++
            "[style] # how terse the agent writes\n" ++
            "caveman = \"lite\" # not as terse as ultra\n" ++
            "ponytail = ultra # not valid TOML, and read anyway\n",
    );
    try std.testing.expect(commented.problem == null);
    try std.testing.expectEqual(style_mod.CavemanLevel.lite, commented.style.caveman);
    try std.testing.expectEqual(style_mod.PonytailLevel.ultra, commented.style.ponytail);

    // A table that is not ours stays not ours with a comment on it too, and
    // something after the closing bracket that is neither is not a header at
    // all.
    const labelled = parse(arena, "[model] # somebody else's\ncaveman = \"off\"\n");
    try std.testing.expect(labelled.problem == null);
    try std.testing.expectEqual(style_mod.CavemanLevel.ultra, labelled.style.caveman);
}

// A `#` between the quotes is text, so the closing quote is found before any
// comment is cut. Cutting at the first `#` instead left the opening quote glued
// to the front of the value, which named no level.
test "a hash inside a quoted value is text, not a comment" {
    try std.testing.expectEqualStrings("lite # off", unquote("\"lite # off\""));
    try std.testing.expectEqualStrings("lite", unquote("\"lite\" # a comment"));
    try std.testing.expectEqualStrings("lite # off", unquote("'lite # off'"));
    try std.testing.expectEqualStrings("lite ", unquote("lite # a comment"));
    try std.testing.expectEqualStrings("\"lite # off", unquote("\"lite # off"));
    try std.testing.expectEqualStrings("l", unquote("l"));
    try std.testing.expectEqualStrings("", unquote(""));
}

test "a config an editor saved with a byte order mark reads the same" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const arena = state.allocator();

    const first = parse(arena, chat.bom ++ "caveman = \"lite\"\n");
    try std.testing.expect(first.problem == null);
    try std.testing.expectEqual(style_mod.CavemanLevel.lite, first.style.caveman);

    const tabled = parse(arena, chat.bom ++ "[style]\nponytail = \"off\"\n");
    try std.testing.expect(tabled.problem == null);
    try std.testing.expectEqual(style_mod.PonytailLevel.off, tabled.style.ponytail);

    // A mark on a later line belongs to that line's value, not to the file, so
    // the key ahead of it is still read and the one it hides is still an
    // unknown key, reported as one.
    const later = parse(arena, "caveman = \"off\"\n" ++ chat.bom ++ "ponytail = \"off\"\n");
    try std.testing.expectEqual(style_mod.CavemanLevel.off, later.style.caveman);
    try std.testing.expectEqual(style_mod.PonytailLevel.full, later.style.ponytail);
    try std.testing.expectEqualStrings(chat.bom ++ "ponytail", later.problem.?.key);
}

test "skills are a list of directories, and absent is not the same as empty" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const arena = state.allocator();

    // Absent: the default root applies, which the caller is told by the null.
    try std.testing.expect((parse(arena, "caveman = \"off\"\n")).skills == null);

    const listed = parse(arena, "skills = [\"./one\", '~/.microagent/skills', \"./two\"]\n");
    try std.testing.expect(listed.problem == null);
    try std.testing.expectEqual(@as(usize, 3), listed.skills.?.len);
    try std.testing.expectEqualStrings("./one", listed.skills.?[0]);
    try std.testing.expectEqualStrings("~/.microagent/skills", listed.skills.?[1]);
    try std.testing.expectEqualStrings("./two", listed.skills.?[2]);

    // An empty list turns skills off, and is a statement the caller can tell
    // from a file that never mentioned them.
    const none = parse(arena, "skills = []\n");
    try std.testing.expect(none.problem == null);
    try std.testing.expectEqual(@as(usize, 0), none.skills.?.len);

    // A value that is not a list of strings is refused rather than read as an
    // empty list, which would silently turn skills off.
    const bad = parse(arena, "skills = \"~/skills\"\n");
    try std.testing.expectEqualStrings("skills", bad.problem.?.key);
    try std.testing.expect(bad.skills == null);

    // A comment trails a list the way it trails a scalar, and a comma inside a
    // quoted element is text: cutting the line at the first `#` or the first
    // `,` would read a directory nobody named.
    const commented = parse(arena, "skills = [\"./one\", \"./two\"] # where they are\n");
    try std.testing.expect(commented.problem == null);
    try std.testing.expectEqual(@as(usize, 2), commented.skills.?.len);
    const comma = parse(arena, "skills = [\"./a,b\", \"./c\"]\n");
    try std.testing.expectEqual(@as(usize, 2), comma.skills.?.len);
    try std.testing.expectEqualStrings("./a,b", comma.skills.?[0]);
    try std.testing.expectEqualStrings("./c", comma.skills.?[1]);
}

test "command filter parses from deny_commands, command_filter, or [commands] deny" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const arena = state.allocator();

    const top = parse(arena, "deny_commands = [\"sudo\", \"su\"]\n");
    try std.testing.expect(top.problem == null);
    try std.testing.expectEqual(@as(usize, 2), top.deny_commands.len);
    try std.testing.expectEqualStrings("sudo", top.deny_commands[0]);
    try std.testing.expectEqualStrings("su", top.deny_commands[1]);

    const alias = parse(arena, "command_filter = [\"shutdown\", \"reboot\"]\n");
    try std.testing.expect(alias.problem == null);
    try std.testing.expectEqual(@as(usize, 2), alias.deny_commands.len);
    try std.testing.expectEqualStrings("shutdown", alias.deny_commands[0]);
    try std.testing.expectEqualStrings("reboot", alias.deny_commands[1]);

    const single = parse(arena, "deny_commands = \"sudo\"\n");
    try std.testing.expect(single.problem == null);
    try std.testing.expectEqual(@as(usize, 1), single.deny_commands.len);
    try std.testing.expectEqualStrings("sudo", single.deny_commands[0]);

    const tabled = parse(arena, "[commands]\ndeny = [\"sudo\", \"rm -rf\"]\n");
    try std.testing.expect(tabled.problem == null);
    try std.testing.expectEqual(@as(usize, 2), tabled.deny_commands.len);
    try std.testing.expectEqualStrings("sudo", tabled.deny_commands[0]);
    try std.testing.expectEqualStrings("rm -rf", tabled.deny_commands[1]);
}

test "an MCP server is one [[mcp]] table, and a broken one is named and skipped" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const arena = state.allocator();

    const text =
        \\[[mcp]]
        \\name = "fs"
        \\command = "npx"
        \\args = ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"]
        \\env = { LOG = "debug", MODE = "ro" }
        \\
        \\[[mcp]]
        \\name = "git"
        \\command = "mcp-git"
        \\
        \\[[mcp]]
        \\name = "no-command"
        \\
    ;
    const config = parse(arena, text);
    // The third table has no command, so it is skipped with the file named
    // first rather than reaching a spawn with an empty argv.
    try std.testing.expectEqualStrings("mcp", config.problem.?.key);
    try std.testing.expectEqual(Problem.Kind.bad_server, config.problem.?.kind);
    try std.testing.expectEqual(@as(usize, 2), config.mcp.len);
    try std.testing.expectEqualStrings("fs", config.mcp[0].name);
    try std.testing.expectEqualStrings("npx", config.mcp[0].command);
    try std.testing.expectEqual(@as(usize, 3), config.mcp[0].args.len);
    try std.testing.expectEqualStrings("/tmp", config.mcp[0].args[2]);
    try std.testing.expectEqual(@as(usize, 2), config.mcp[0].env.len);
    try std.testing.expectEqualStrings("LOG", config.mcp[0].env[0][0]);
    try std.testing.expectEqualStrings("debug", config.mcp[0].env[0][1]);
    // A table with no args or env carries empty lists, not nulls.
    try std.testing.expectEqualStrings("git", config.mcp[1].name);
    try std.testing.expectEqual(@as(usize, 0), config.mcp[1].args.len);
    try std.testing.expectEqual(@as(usize, 0), config.mcp[1].env.len);

    // A comment trails `args` and `env` the way it trails any other value.
    const commented = parse(arena, "[[mcp]]\nname = \"a\"\ncommand = \"b\"\nargs = [\"-y\", \"x\"] # flags\nenv = { K = \"v\" } # one\n");
    try std.testing.expect(commented.problem == null);
    try std.testing.expectEqual(@as(usize, 2), commented.mcp[0].args.len);
    try std.testing.expectEqualStrings("x", commented.mcp[0].args[1]);
    try std.testing.expectEqual(@as(usize, 1), commented.mcp[0].env.len);
    try std.testing.expectEqualStrings("v", commented.mcp[0].env[0][1]);

    // A key this reader does not have inside a table is a problem like any
    // other, and the entry still applies.
    const extra = parse(arena, "[[mcp]]\nname = \"a\"\ncommand = \"b\"\ncwd = \"/tmp\"\n");
    try std.testing.expectEqualStrings("cwd", extra.problem.?.key);
    try std.testing.expectEqual(@as(usize, 1), extra.mcp.len);

    // A server name is half of every exposed tool name, so a name that cannot
    // be spelled is refused here rather than offered to a provider inside
    // `mcp__bad name__tool`.
    const bad_name = parse(arena, "[[mcp]]\nname = \"bad name\"\ncommand = \"b\"\n");
    try std.testing.expectEqual(Problem.Kind.bad_server, bad_name.problem.?.kind);
    try std.testing.expectEqual(@as(usize, 0), bad_name.mcp.len);
    const double = parse(arena, "[[mcp]]\nname = \"a__b\"\ncommand = \"b\"\n");
    try std.testing.expectEqual(Problem.Kind.bad_server, double.problem.?.kind);

    // Two tables with one name would collide on one exposed name, so the
    // second is skipped and named.
    const twice = parse(arena, "[[mcp]]\nname = \"a\"\ncommand = \"b\"\n[[mcp]]\nname = \"a\"\ncommand = \"c\"\n");
    try std.testing.expectEqual(Problem.Kind.duplicate_server, twice.problem.?.kind);
    try std.testing.expectEqual(@as(usize, 1), twice.mcp.len);
    try std.testing.expectEqualStrings("b", twice.mcp[0].command);

    // Args that are not a list, and an env that is not an inline table, are
    // refused rather than read as empty.
    const bad_args = parse(arena, "[[mcp]]\nname = \"a\"\ncommand = \"b\"\nargs = \"-y\"\n");
    try std.testing.expectEqualStrings("args", bad_args.problem.?.key);
    const bad_env = parse(arena, "[[mcp]]\nname = \"a\"\ncommand = \"b\"\nenv = [\"K\"]\n");
    try std.testing.expectEqualStrings("env", bad_env.problem.?.key);
}

// `config.example.toml` is the only template the project ships, and a key
// renamed or a level removed leaves it naming something the reader does not
// have: the file still copies cleanly, still sets its lines, and every run a
// user makes from it prints a complaint about a key or level that was correct
// when the template was written. Nothing else in the tree would notice, so the
// template is read here and applied.
test "the shipped config template applies, and names levels the reader has" {
    const gpa = std.testing.allocator;
    // The test runs with the build root as its working directory, which is
    // where the template is tracked.
    const text = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "config.example.toml", gpa, .limited(max_template_bytes));
    defer gpa.free(text);

    var state = std.heap.ArenaAllocator.init(gpa);
    defer state.deinit();
    const config = parse(state.allocator(), text);
    if (config.problem) |p| {
        std.debug.print("\nconfig.example.toml: '{s}' is {s}\n", .{ p.key, @tagName(p.kind) });
        return error.TestUnexpectedResult;
    }

    // The template ships both level keys live, so both are the level the file
    // names, and each round-trips through the spelling the reader accepts.
    try std.testing.expectEqualStrings("ultra", config.style.caveman.name());
    try std.testing.expectEqualStrings("full", config.style.ponytail.name());
    try std.testing.expectEqual(config.style.caveman, style_mod.parseCaveman(config.style.caveman.name()).?);
    try std.testing.expectEqual(config.style.ponytail, style_mod.parsePonytail(config.style.ponytail.name()).?);

    // The skills and MCP examples in the template are comments, so a user who
    // copies the file gets the two levels and nothing that spawns a process
    // or reads a directory they did not write.
    try std.testing.expect(config.skills == null);
    try std.testing.expectEqual(@as(usize, 0), config.mcp.len);
}

/// The template is a handful of commented lines; a bigger file is not one.
const max_template_bytes: usize = 64 * 1024;

// The corpus covers the shapes a real config and a wrong one have: keys at the
// root and under `[style]`, a table that belongs to something else, single and
// double quotes, a value with a trailing comment, an unterminated quote, a key
// with no `=`, a bare value, a level spelled in a case or with a space, a
// skills list, an `[[mcp]]` table with every field and with none, and the same
// key twice.
const config_corpus = [_][]const u8{
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
    "skills = []\n",
    "skills = [\"a\"]\n",
    "skills = [\"a\",]\n",
    "skills = [a, b]\n",
    "skills = \"a\"\n",
    "skills = [\n",
    "skills = [\"a\"] # a comment\n",
    "skills = [\"a,b\", \"c\"]\n",
    "skills = [\"a\" # a comment inside\n",
    "[[mcp]]\n",
    "[[mcp]]\nname = \"a\"\n",
    "[[mcp]]\nname = \"a\"\ncommand = \"b\"\n",
    "[[mcp]]\nname = \"a\"\ncommand = \"b\"\nargs = [\"-y\"]\nenv = { K = \"v\" }\n",
    "[[mcp]]\nname = \"a\"\ncommand = \"b\"\nargs = []\nenv = {}\n",
    "[[mcp]]\nname = \"a\"\ncommand = \"b\"\nargs = [\"x\"] # flags\nenv = { K = \"v\" } # one\n",
    "[[mcp]]\nname = \"a\"\ncommand = \"b\"\nargs = \"x\"\n",
    "[[mcp]]\nname = \"a\"\ncommand = \"b\"\nenv = { K = }\n",
    "[mcp]\nname = \"a\"\ncommand = \"b\"\n",
    "[[mcp]\nname = \"a\"\n",
    "[[  mcp  ]]\nname = \"a\"\ncommand = \"b\"\n",
    "[[mcp]] # a server\nname = \"a\"\ncommand = \"b\"\n",
    "[[mcp]]\nname = \"a b\"\ncommand = \"c\"\n",
    "[[mcp]]\nname = \"a\"\ncommand = \"b\"\n[[mcp]]\nname = \"a\"\ncommand = \"c\"\n",
    "caveman = \"lite\"\n[[mcp]]\nname = \"a\"\ncommand = \"b\"\nponytail = \"off\"\n",
};

test "a fuzzed config leaves a config the run can act on" {
    try std.testing.fuzz({}, fuzzConfig, .{ .corpus = &config_corpus });
}

fn fuzzConfig(_: void, smith: *std.testing.Smith) !void {
    var raw: [8 * 1024]u8 = undefined;
    const text: []const u8 = if (smith.in) |seed| seed else raw[0..smith.slice(&raw)];

    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const arena = state.allocator();
    const config = parse(arena, text);

    // The reader either found nothing to say or named something that is in the
    // file, which is the whole claim a caller makes about the `Problem` it
    // turns into a line on stderr. A bad server names the table, not a line.
    if (config.problem) |p| {
        try std.testing.expect(p.key.len > 0);
        if (p.kind != .bad_server) try std.testing.expect(std.mem.indexOf(u8, text, p.key) != null);
    }

    // Whatever the file said, the levels in force are ones the parser can name,
    // so a level never reaches the prompt as a spelling nothing reads back.
    try std.testing.expectEqual(config.style.caveman, style_mod.parseCaveman(config.style.caveman.name()).?);
    try std.testing.expectEqual(config.style.ponytail, style_mod.parsePonytail(config.style.ponytail.name()).?);

    // The same text read twice says the same thing: the reader holds no state
    // across calls, and the fuzzer would find it if it did.
    const again = parse(arena, text);
    try std.testing.expectEqual(config.style.caveman, again.style.caveman);
    try std.testing.expectEqual(config.style.ponytail, again.style.ponytail);
    try std.testing.expectEqual(config.problem == null, again.problem == null);
    try std.testing.expectEqual(config.mcp.len, again.mcp.len);
    try std.testing.expectEqual(config.skills == null, again.skills == null);
    if (config.skills) |dirs| {
        try std.testing.expectEqual(dirs.len, again.skills.?.len);
        for (dirs, again.skills.?) |a, b| try std.testing.expectEqualStrings(a, b);
    }
}
