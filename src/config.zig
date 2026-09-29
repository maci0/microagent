//! The one config file: the provider settings, the system prompt addendum,
//! skills, MCP servers, and the tool set.
//!
//! Each is a section of the same document, because a second file for the
//! servers would be a second answer to "where is this run configured":
//!
//! ```toml
//! model               = "deepseek/deepseek-v4-flash"
//! base_url            = "https://api.openai.com/v1"
//! api_key             = "sk-..."
//! system_prompt_extra = "Answer in one short paragraph."
//! deny_commands       = ["sudo"]
//! skills              = ["./skills", "~/.microagent/skills"]
//!
//! [sandbox]
//! enabled  = true
//! writable = ["."]
//!
//! [[mcp]]
//! name    = "fs"
//! command = "npx"
//! args    = ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"]
//! env     = { LOG = "debug" }
//!
//! [tools.ast]
//! enabled = false
//!
//! [tools.context7]
//! enabled = true
//! ```
//!
//! Only the subset of TOML those need is read: `key = value`, a quoted or bare
//! string, `true` or `false`, an integer for a timeout, an array of strings, a
//! `[[mcp]]` array of tables, `[tools.<name>]` tables, and an inline table of
//! strings for `env`. `system_prompt_extra` alone also takes a multi-line string.
//! Dates, floats, nested tables and other dotted keys have nowhere to go, so
//! they are not parsed and not missed.
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

/// One MCP server as the file declares it: the same fields `mcp_mod.Entry`
/// carries, built up a line at a time while a `[[mcp]]` table is open.
/// The largest `system_prompt_extra` the reader takes. The text rides on every
/// request, so a value past this is a pasted file and not an addendum.
pub const max_system_prompt_extra_bytes: usize = 16 * 1024;

/// The file the run reads repository instructions from when the config named
/// none. Every other coding agent reads this name, so a repository that carries
/// one carries it for this run too.
pub const agents_file_default = "AGENTS.md";

/// The longest path `agents_file` may be. A path past this is not a path.
pub const max_agents_path_bytes: usize = 1024;

const Lines = std.mem.SplitIterator(u8, .scalar);

const Server = struct {
    name: []const u8 = "",
    command: []const u8 = "",
    args: []const []const u8 = &.{},
    env: []const [2][]const u8 = &.{},
    url: []const u8 = "",
    api_key_env: []const u8 = "",
    api_key_header: []const u8 = mcp_mod.default_key_header,
    timeout_s: u32 = mcp_mod.default_timeout_s,
    /// A key that is only meaningful for a remote server was set, so a table
    /// that also has a `command` is one that mixes the two forms.
    remote_key_set: bool = false,
    /// `args` or `env` was set, which only a `command` server has.
    local_key_set: bool = false,
    /// A value of one of the remote keys was not usable. The server is dropped
    /// rather than connected without the key or the limit the file asked for.
    invalid: bool = false,
};

/// What the file said, with the defaults for everything it did not say.
pub const Config = struct {
    /// Text appended to the system prompt after a blank line, empty for none.
    system_prompt_extra: []const u8 = "",
    /// The repository's own instructions, read from the working directory when
    /// the run starts. `AGENTS.md` is the name every other coding agent uses;
    /// an empty value turns the read off, which is the operator's way of not
    /// following a file the repository supplies.
    agents_file: []const u8 = agents_file_default,
    /// Whether `agents_file` above was written in the file or is the default. A
    /// named path that is not there is said on stderr; the default is not,
    /// because most repositories have no such file and a note per run about it
    /// would be noise.
    agents_file_named: bool = false,
    /// The provider settings the file named, empty when it named none. Each is
    /// one of the sources a run draws from, and the weakest: a `--flag` beats
    /// the environment variable, which beats the file. `api_key` is a secret
    /// written in the clear, so a file inside a workspace the model can read is
    /// not a place to put one.
    model: []const u8 = "",
    base_url: []const u8 = "",
    api_key: []const u8 = "",
    /// The skill directories the file named, or null when it named none and
    /// the default root applies. An empty list is a file that turned skills
    /// off, which is not the same statement as a file that did not mention
    /// them.
    skills: ?[]const []const u8 = null,
    /// The MCP servers the file declared, in the order the tables appear, then
    /// the remote presets it switched on.
    mcp: []const mcp_mod.Entry = &.{},
    /// The built-in tools the file switched off.
    disabled_tools: std.EnumSet(chat.Tool) = .initEmpty(),
    /// The first `[tools.*]` mistake, which the run stops on: a tool left on
    /// or off by a misspelling is not a default anyone chose.
    tool_problem: ?ToolProblem = null,
    /// Commands denied from running via the bash tool.
    deny_commands: []const []const u8 = &.{},
    /// Sandbox configuration restricting writes outside the workspace.
    sandbox: Sandbox = .{},
    /// The first line the reader could not use, if any.
    problem: ?Problem = null,

    /// Records a problem unless one was already recorded: the first line that
    /// could not be used is the one named, and the scan still runs to the end
    /// of the document so every line after it still applies.
    pub fn note(self: *Config, problem: Problem) void {
        if (self.problem == null) self.problem = problem;
    }
};

/// Workspace isolation / sandbox configuration.
pub const Sandbox = struct {
    enabled: bool = false,
    writable: []const []const u8 = &.{},
};

/// A `[tools.*]` line that stops the run. `name` is the section as written,
/// and `key` the key in it when it was the value that was wrong.
pub const ToolProblem = struct {
    name: []const u8,
    key: []const u8 = "",
    kind: enum { unknown_tool, bad_value },
};

/// Every name `[tools.<name>]` takes, spelled for the message that names them.
pub const tool_names = blk: {
    var text: []const u8 = "";
    for (@typeInfo(chat.Tool).@"enum".fields) |f| text = text ++ (if (text.len == 0) "" else ", ") ++ f.name;
    for (@typeInfo(mcp_mod.Preset).@"enum".fields) |f| text = text ++ ", " ++ f.name;
    break :blk text;
};

/// What a `[tools.<name>]` table configures: a built-in, which has an `enabled`
/// switch and nothing else, or a remote preset, which has options.
const ToolTarget = union(enum) { builtin: chat.Tool, preset: mcp_mod.Preset };

fn toolTarget(name: []const u8) ?ToolTarget {
    if (chat.Tool.fromName(name)) |tool| return .{ .builtin = tool };
    if (std.meta.stringToEnum(mcp_mod.Preset, name)) |preset| return .{ .preset = preset };
    return null;
}

/// The options a preset table set. Presets are on until the file says otherwise: a preset whose
/// server cannot be reached is named on stderr at start and skipped.
const PresetSetting = struct {
    enabled: bool = true,
    url: []const u8 = "",
    api_key_env: []const u8 = "",
    api_key_header: []const u8 = mcp_mod.default_key_header,
    timeout_s: u32 = mcp_mod.default_timeout_s,
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
        /// A list this file declares more than once, whose values could not be
        /// joined, so the key holds only the values declared before the one
        /// that was lost.
        list_truncated,
    };
};

/// The section the lines after a header belong to.
const Section = enum { top, sandbox, mcp, tool, other };

/// Reads the document. Never fails: a document this reader cannot follow
/// whole is read as far as it can be, and the first line it could not use is
/// returned as `problem`.
pub fn parse(arena: std.mem.Allocator, text: []const u8) Config {
    var config: Config = .{};
    var section: Section = .top;
    var servers: std.ArrayList(Server) = .empty;
    var open: ?*Server = null;
    var presets: std.EnumArray(mcp_mod.Preset, PresetSetting) = .initFill(.{});
    var open_tool: ?ToolTarget = null;

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
                open_tool = null;
                continue;
            };
            open_tool = null;
            if (std.mem.eql(u8, header.name, "sandbox")) {
                section = .sandbox;
            } else if (std.mem.eql(u8, header.name, "mcp") and header.array) {
                servers.append(arena, .{}) catch {
                    section = .other;
                    open = null;
                    continue;
                };
                open = &servers.items[servers.items.len - 1];
                section = .mcp;
            } else if (std.mem.eql(u8, header.name, "tools") or std.mem.startsWith(u8, header.name, "tools.")) {
                // Every name here is one the run acts on, so a name this build
                // does not have stops it rather than leaving a tool as it was.
                const name = if (header.name.len > "tools.".len) header.name["tools.".len..] else "";
                section = .other;
                open = null;
                if (header.array) {
                    config.note(.{ .key = line, .kind = .unknown_key });
                } else if (toolTarget(name)) |target| {
                    section = .tool;
                    open_tool = target;
                } else if (config.tool_problem == null) {
                    config.tool_problem = .{ .name = name, .kind = .unknown_tool };
                }
            } else if (std.mem.eql(u8, header.name, "style") or std.mem.eql(u8, header.name, "commands") or std.mem.eql(u8, header.name, "command_filter")) {
                // Tables this file no longer reads. Passed over as somebody
                // else's, they would leave a setting the file asked for, a deny
                // list among them, silently unapplied, so they are named.
                config.note(.{ .key = line, .kind = .unknown_key });
                section = .other;
                open = null;
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
            .top => topKey(&config, arena, &lines, key, value_text),
            .sandbox => sandboxOnly(&config, arena, key, value_text),
            .mcp => if (open) |server| serverKey(&config, arena, server, key, value_text),
            .tool => if (open_tool) |target| toolKey(&config, target, &presets, key, value_text),
            .other => {},
        }
    }

    for (std.enums.values(mcp_mod.Preset)) |preset| {
        const setting = presets.get(preset);
        if (!setting.enabled) continue;
        servers.append(arena, .{
            .name = @tagName(preset),
            .url = if (setting.url.len != 0) setting.url else preset.url(),
            .api_key_env = setting.api_key_env,
            .api_key_header = setting.api_key_header,
            .timeout_s = setting.timeout_s,
        }) catch break;
    }

    var entries: std.ArrayList(mcp_mod.Entry) = .empty;
    for (servers.items) |server| {
        // The name is half of every exposed tool name, so it is held to the
        // rule the server's own tool names are held to: `mcp__<server>__<tool>`
        // is what the model is offered, and a space or a `__` in the server
        // half makes a name no provider accepts and no model can spell.
        // One form or the other, whole: a `command` with a `url`, or with the
        // options only a `url` takes, is a table that says two things.
        const local = server.command.len != 0;
        const remote = server.url.len != 0;
        const whole = if (remote) !local and !server.local_key_set and mcp_mod.validUrl(server.url) else !server.remote_key_set;
        if (server.invalid or !(local or remote) or !whole or !mcp_mod.validName(server.name)) {
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
            .url = server.url,
            .api_key_env = server.api_key_env,
            .api_key_header = server.api_key_header,
            .timeout_s = server.timeout_s,
        }) catch break;
    }
    config.mcp = entries.items;
    return config;
}

/// A key at the top of the file, outside any table: `system_prompt_extra`,
/// `agents_file`, `model`, `base_url`, `api_key`, `skills` and `deny_commands`.
/// `lines` is what
/// follows this one, for the value that runs over several.
fn topKey(config: *Config, arena: std.mem.Allocator, lines: *Lines, key: []const u8, value_text: []const u8) void {
    if (std.mem.eql(u8, key, "system_prompt_extra")) {
        const text = promptString(arena, lines, value_text) orelse
            return config.note(.{ .key = key, .kind = .bad_value });
        if (text.len > max_system_prompt_extra_bytes) return config.note(.{ .key = key, .kind = .bad_value });
        config.system_prompt_extra = text;
        return;
    }
    if (std.mem.eql(u8, key, "agents_file")) {
        topString(config, key, value_text, &config.agents_file);
        if (config.agents_file.len > max_agents_path_bytes)
            return config.note(.{ .key = key, .kind = .bad_value });
        // Named, so a path that is not there is the operator's own spelling of
        // a setting that did nothing, and the run says so.
        config.agents_file_named = true;
        return;
    }
    if (std.mem.eql(u8, key, "model")) return topString(config, key, value_text, &config.model);
    if (std.mem.eql(u8, key, "base_url")) return topString(config, key, value_text, &config.base_url);
    if (std.mem.eql(u8, key, "api_key")) return topString(config, key, value_text, &config.api_key);
    if (std.mem.eql(u8, key, "skills")) {
        const dirs = stringArray(arena, value_text) orelse
            return config.note(.{ .key = key, .kind = .bad_value });
        config.skills = dirs;
        return;
    }
    if (std.mem.eql(u8, key, "deny_commands")) {
        const list = stringArray(arena, value_text) orelse
            return config.note(.{ .key = key, .kind = .bad_value });
        addDenyCommands(config, arena, list);
        return;
    }
    config.note(.{ .key = key, .kind = .unknown_key });
}

/// A top-level key whose value is one string: `model`, `base_url` and
/// `api_key`. Quoted or not is not the point; a value this reader cannot see
/// the end of is, because none of the three has a useful default to fall back
/// to silently.
fn topString(config: *Config, key: []const u8, value_text: []const u8, out: *[]const u8) void {
    const value = stringValue(value_text) orelse
        return config.note(.{ .key = key, .kind = .bad_value });
    out.* = value;
}

/// One quoted string, or null when the text is not one: empty, bare, a number,
/// or a quote with no closing quote. `unquote` returns an unterminated value as
/// written, so the length is what tells the two apart.
fn stringValue(raw: []const u8) ?[]const u8 {
    const text = std.mem.trim(u8, raw, " \t");
    if (text.len < 2) return null;
    if (text[0] != '"' and text[0] != '\'') return null;
    const value = unquote(text);
    if (value.len == text.len) return null;
    return value;
}

/// A key under `[sandbox]`.
fn sandboxOnly(config: *Config, arena: std.mem.Allocator, key: []const u8, value_text: []const u8) void {
    if (std.mem.eql(u8, key, "enabled")) {
        if (parseBool(value_text)) |b| {
            config.sandbox.enabled = b;
            return;
        }
        return config.note(.{ .key = key, .kind = .bad_value });
    }
    if (std.mem.eql(u8, key, "writable")) {
        const list = stringArray(arena, value_text) orelse
            return config.note(.{ .key = key, .kind = .bad_value });
        addSandboxWritable(config, arena, list);
        return;
    }
    config.note(.{ .key = key, .kind = .unknown_key });
}

fn addSandboxWritable(config: *Config, arena: std.mem.Allocator, list: []const []const u8) void {
    if (list.len == 0) return;
    config.sandbox.writable = addToList(config, arena, "writable", config.sandbox.writable, list);
}

/// A list this file may declare more than once, joined rather than replaced.
///
/// The join is a copy, so it can fail where the file itself did not, and a
/// failure here used to leave the key holding the values declared before it
/// with nothing said. That is the quiet kind of wrong this reader is for
/// everywhere else: `deny_commands` short by one entry is a command the
/// operator denied and the run then allows, and a `writable` list short by one
/// is a directory the run refuses to write to. The earlier values stay, and
/// the key is named, so the run says which list is short rather than behaving
/// as if the file had not declared it.
fn addToList(
    config: *Config,
    arena: std.mem.Allocator,
    key: []const u8,
    existing: []const []const u8,
    list: []const []const u8,
) []const []const u8 {
    if (existing.len == 0) return list;
    var merged: std.ArrayList([]const u8) = .empty;
    merged.appendSlice(arena, existing) catch {
        config.note(.{ .key = key, .kind = .list_truncated });
        return existing;
    };
    merged.appendSlice(arena, list) catch {
        config.note(.{ .key = key, .kind = .list_truncated });
        return existing;
    };
    return merged.items;
}

/// The TOML booleans, `true` and `false`, and nothing else.
fn parseBool(raw: []const u8) ?bool {
    const text = std.mem.trim(u8, stripComment(raw), " \t\r\n");
    if (std.mem.eql(u8, text, "true")) return true;
    if (std.mem.eql(u8, text, "false")) return false;
    return null;
}

fn addDenyCommands(config: *Config, arena: std.mem.Allocator, list: []const []const u8) void {
    if (list.len == 0) return;
    config.deny_commands = addToList(config, arena, "deny_commands", config.deny_commands, list);
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
        server.local_key_set = true;
        server.args = stringArray(arena, value_text) orelse
            return config.note(.{ .key = key, .kind = .bad_value });
        return;
    }
    if (std.mem.eql(u8, key, "env")) {
        server.local_key_set = true;
        // A table the reader cannot turn into an environment the child process
        // can hold drops the server, the way a remote option it cannot use
        // does: a spawn carrying a name with a `=` or a NUL in it either
        // asserts the run down or hands the server a variable it never asked
        // for, and neither is a server this configuration declared.
        server.env = inlineTable(arena, value_text) orelse {
            server.invalid = true;
            return config.note(.{ .key = key, .kind = .bad_value });
        };
        return;
    }
    if (std.mem.eql(u8, key, "url")) {
        server.url = unquote(value_text);
        return;
    }
    // The options a remote server takes are checked as they are read. A
    // server given a key it cannot use is dropped, not connected without one.
    if (remoteOption(&server.api_key_env, &server.api_key_header, &server.timeout_s, key, value_text)) |usable| {
        server.remote_key_set = true;
        if (!usable) server.invalid = true;
        return;
    }
    config.note(.{ .key = key, .kind = .unknown_key });
}

/// The three options a remote server takes, in a `[[mcp]]` table or a preset
/// table. Null when `key` is not one of them, false when the value is not
/// usable. A named key variable is a name, never a key: what is stored is the
/// variable to read.
fn remoteOption(api_key_env: *[]const u8, api_key_header: *[]const u8, timeout_s: *u32, key: []const u8, value_text: []const u8) ?bool {
    const value = std.mem.trim(u8, unquote(value_text), " \t");
    if (std.mem.eql(u8, key, "api_key_env")) {
        if (value.len != 0 and !mcp_mod.validEnvName(value)) return false;
        api_key_env.* = value;
        return true;
    }
    if (std.mem.eql(u8, key, "api_key_header")) {
        if (!mcp_mod.validHeaderName(value)) return false;
        api_key_header.* = value;
        return true;
    }
    if (std.mem.eql(u8, key, "timeout")) {
        const seconds = std.fmt.parseInt(u32, value, 10) catch return false;
        if (seconds == 0 or seconds > mcp_mod.max_timeout_s) return false;
        timeout_s.* = seconds;
        return true;
    }
    return null;
}

/// One line inside an open `[tools.<name>]` table. Every problem here is one
/// the run stops on except a key the table does not have, which is noted like
/// any other unknown key.
fn toolKey(config: *Config, target: ToolTarget, presets: *std.EnumArray(mcp_mod.Preset, PresetSetting), key: []const u8, value_text: []const u8) void {
    const name = switch (target) {
        .builtin => |tool| tool.name(),
        .preset => |preset| @tagName(preset),
    };
    const usable: bool = ok: {
        if (std.mem.eql(u8, key, "enabled")) {
            const on = parseBool(value_text) orelse break :ok false;
            switch (target) {
                .builtin => |tool| config.disabled_tools.setPresent(tool, !on),
                .preset => |preset| presets.getPtr(preset).enabled = on,
            }
            break :ok true;
        }
        const preset = switch (target) {
            .preset => |p| p,
            .builtin => return config.note(.{ .key = key, .kind = .unknown_key }),
        };
        const setting = presets.getPtr(preset);
        if (std.mem.eql(u8, key, "url")) {
            const url = unquote(value_text);
            if (!mcp_mod.validUrl(url)) break :ok false;
            setting.url = url;
            break :ok true;
        }
        break :ok remoteOption(&setting.api_key_env, &setting.api_key_header, &setting.timeout_s, key, value_text) orelse
            return config.note(.{ .key = key, .kind = .unknown_key });
    };
    if (usable or config.tool_problem != null) return;
    config.tool_problem = .{ .name = name, .key = key, .kind = .bad_value };
}

/// The name and shape of a table header line, which the caller has already
/// found opens with `[`. `[[mcp]]` is an array of tables and `[tools.x]` is a
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

/// The value of `system_prompt_extra`: a basic string (`"..."`, with the
/// escapes `\n`, `\t`, `\r`, `\"` and `\\`), a literal string (`'...'`, no
/// escapes), or either kind as a multi-line string (`"""` or `'''`, a newline
/// right after the opening quotes dropped), which reads on through `lines`
/// until the closing quotes. Null when the value is none of these.
fn promptString(arena: std.mem.Allocator, lines: *Lines, value_text: []const u8) ?[]const u8 {
    for ([_][]const u8{ "\"\"\"", "'''" }) |delim| {
        if (!std.mem.startsWith(u8, value_text, delim)) continue;
        var body: std.ArrayList(u8) = .empty;
        var segment = value_text[delim.len..];
        while (true) {
            if (std.mem.indexOf(u8, segment, delim)) |end| {
                body.appendSlice(arena, segment[0..end]) catch return null;
                break;
            }
            body.appendSlice(arena, segment) catch return null;
            body.append(arena, '\n') catch return null;
            if (body.items.len > max_system_prompt_extra_bytes) return null;
            segment = std.mem.trimEnd(u8, lines.next() orelse return null, "\r");
        }
        const text = if (std.mem.startsWith(u8, body.items, "\n")) body.items[1..] else body.items;
        return if (delim[0] == '"') unescape(arena, text) else text;
    }
    if (value_text.len >= 2 and value_text[0] == '"') {
        var i: usize = 1;
        while (i < value_text.len) : (i += 1) {
            if (value_text[i] == '\\') {
                i += 1;
            } else if (value_text[i] == '"') {
                return unescape(arena, value_text[1..i]);
            }
        }
        return null;
    }
    if (value_text.len >= 2 and value_text[0] == '\'') {
        const end = std.mem.indexOfScalarPos(u8, value_text, 1, '\'') orelse return null;
        return value_text[1..end];
    }
    return null;
}

/// The text with its TOML escapes resolved, or null on one this reader does not
/// have.
fn unescape(arena: std.mem.Allocator, text: []const u8) ?[]const u8 {
    if (std.mem.indexOfScalar(u8, text, '\\') == null) return text;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] != '\\') {
            out.append(arena, text[i]) catch return null;
            continue;
        }
        i += 1;
        if (i == text.len) return null;
        const c: u8 = switch (text[i]) {
            'n' => '\n',
            't' => '\t',
            'r' => '\r',
            '"' => '"',
            '\\' => '\\',
            else => return null,
        };
        out.append(arena, c) catch return null;
    }
    return out.items;
}

/// A quoted TOML value without its quotes, stopping at the closing quote so a
/// trailing `# comment` is not part of the value. A bare value stops at a `#`
/// for the same reason; it is otherwise taken as written, because
/// `skills = [a]` is not valid TOML but is not worth an error either.
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
///
/// A key is unquoted like a value, because a file may spell one `"LOG"` and
/// the quotes are the file's, not the name of the variable. It is then held to
/// `validEnvName`, the same rule `api_key_env` is held to: a name carrying a
/// `=`, a NUL or a control character is a name the child process's environment
/// block cannot carry, so passing it on reaches `Environ.Map.put`, which
/// asserts on exactly those bytes and takes the whole run down with it.
fn inlineTable(arena: std.mem.Allocator, raw: []const u8) ?[]const [2][]const u8 {
    const text = std.mem.trim(u8, stripComment(raw), " \t");
    if (text.len < 2 or text[0] != '{' or text[text.len - 1] != '}') return null;
    const parts = splitQuoted(arena, text[1 .. text.len - 1], ',') orelse return null;
    var out: std.ArrayList([2][]const u8) = .empty;
    for (parts) |pair| {
        if (pair.len == 0) continue;
        const eq = indexOutsideQuotes(pair, '=') orelse return null;
        const key = unquote(std.mem.trim(u8, pair[0..eq], " \t"));
        const value_text = std.mem.trim(u8, pair[eq + 1 ..], " \t");
        const value = unquote(value_text);
        // A bare value may not carry the separator: `{ A = B = "v" }` is one
        // pair written three times over, and reading the first `=` as the
        // separator would hand the child `A` and the value `B = "v"`, which is
        // a table nobody wrote. A quoted value may, because the separator is
        // inside the quotes and `indexOutsideQuotes` already stepped over it.
        if (value.len == value_text.len and std.mem.indexOfScalar(u8, value_text, '=') != null) return null;
        if (!mcp_mod.validEnvName(key)) return null;
        if (std.mem.indexOfScalar(u8, value, 0) != null) return null;
        out.append(arena, .{ key, value }) catch return null;
    }
    return out.items;
}

/// The first `sep` that is not inside a quote, so a separator inside a quoted
/// value is text. Null when the text holds an unclosed quote, which is a pair
/// that cannot be read whole.
fn indexOutsideQuotes(raw: []const u8, sep: u8) ?usize {
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
        if (c == sep) return i;
    }
    return null;
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

test "the config sets system_prompt_extra and leaves absent or bad keys alone" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const arena = state.allocator();

    const set = parse(arena,
        \\# what the reply looks like
        \\system_prompt_extra = "Answer in one line."   # kept short
        \\
    );
    try std.testing.expect(set.problem == null);
    try std.testing.expectEqualStrings("Answer in one line.", set.system_prompt_extra);

    // An absent key is empty, which is the stock prompt.
    try std.testing.expectEqualStrings("", parse(arena, "skills = []\n").system_prompt_extra);
    try std.testing.expectEqualStrings("", parse(arena, "system_prompt_extra = \"\"\n").system_prompt_extra);

    // A value that is not a string is named and leaves the default.
    for ([_][]const u8{ "system_prompt_extra = 5\n", "system_prompt_extra = bare\n", "system_prompt_extra =\n", "system_prompt_extra = \"open\n", "system_prompt_extra = \"bad \\q escape\"\n" }) |text| {
        const bad = parse(arena, text);
        try std.testing.expectEqualStrings("system_prompt_extra", bad.problem.?.key);
        try std.testing.expectEqual(Problem.Kind.bad_value, bad.problem.?.kind);
        try std.testing.expectEqualStrings("", bad.system_prompt_extra);
    }

    // A key this file does not define is a misspelling until proven otherwise,
    // and staying quiet about it leaves the default in force with the user
    // believing the file set it. The two reply-style keys this file once had
    // are among them.
    for ([_][]const u8{ "cavmen = \"off\"\n", "caveman = \"ultra\"\n", "ponytail = \"full\"\n", "[style]\ncaveman = \"lite\"\n" }) |text| {
        const typo = parse(arena, text);
        try std.testing.expectEqual(Problem.Kind.unknown_key, typo.problem.?.kind);
        try std.testing.expectEqualStrings("", typo.system_prompt_extra);
    }

    // A bad key or a bad value does not stop the scan: the document is read to
    // the end and every key after the problem still applies, so one typo above
    // a real setting does not leave the whole file inert. The first problem is
    // the one named.
    const after = parse(arena, "caveman = \"ultra\"\nsystem_prompt_extra = 5\nsystem_prompt_extra = 'ok'\n");
    try std.testing.expectEqualStrings("caveman", after.problem.?.key);
    try std.testing.expectEqualStrings("ok", after.system_prompt_extra);

    // A line with nothing before the `=` names no key, so it is not a problem
    // to report, and the key after it still applies.
    const blank = parse(arena, "= \"lite\"\nsystem_prompt_extra = \"x\"\n");
    try std.testing.expect(blank.problem == null);
    try std.testing.expectEqualStrings("x", blank.system_prompt_extra);

    // Only the top of the file takes it.
    const tabled = parse(arena, "[sandbox]\nsystem_prompt_extra = \"x\"\n");
    try std.testing.expectEqual(Problem.Kind.unknown_key, tabled.problem.?.kind);
    try std.testing.expectEqualStrings("", tabled.system_prompt_extra);
}

test "system_prompt_extra takes escapes, literal strings and multi-line strings" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const arena = state.allocator();

    const escaped = parse(arena, "system_prompt_extra = \"a\\nb\\t\\\"q\\\" \\\\ c\" # comment\n");
    try std.testing.expect(escaped.problem == null);
    try std.testing.expectEqualStrings("a\nb\t\"q\" \\ c", escaped.system_prompt_extra);

    const literal = parse(arena, "system_prompt_extra = 'a\\nb # kept'\n");
    try std.testing.expectEqualStrings("a\\nb # kept", literal.system_prompt_extra);

    // The newline after the opening quotes is dropped, every other one kept,
    // and a `#` or a `[table]` line inside is text.
    const multi = parse(arena, "system_prompt_extra = \"\"\"\nfirst\n\n# not a comment\n[not a table]\nlast \\\"x\\\" end\"\"\"\nskills = []\n");
    try std.testing.expect(multi.problem == null);
    try std.testing.expectEqualStrings("first\n\n# not a comment\n[not a table]\nlast \"x\" end", multi.system_prompt_extra);
    try std.testing.expect(multi.skills != null);

    const literal_multi = parse(arena, "system_prompt_extra = '''one\r\ntwo\\n'''\n");
    try std.testing.expectEqualStrings("one\ntwo\\n", literal_multi.system_prompt_extra);

    // No closing quotes is a bad value, not the rest of the file swallowed
    // quietly.
    const open = parse(arena, "system_prompt_extra = \"\"\"\nnever closed\n");
    try std.testing.expectEqual(Problem.Kind.bad_value, open.problem.?.kind);
    try std.testing.expectEqualStrings("", open.system_prompt_extra);
}

test "system_prompt_extra past its bound is refused" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const arena = state.allocator();

    const fits = try std.fmt.allocPrint(arena, "system_prompt_extra = \"{s}\"\n", .{"a" ** max_system_prompt_extra_bytes});
    const at_limit = parse(arena, fits);
    try std.testing.expect(at_limit.problem == null);
    try std.testing.expectEqual(max_system_prompt_extra_bytes, at_limit.system_prompt_extra.len);

    const over = try std.fmt.allocPrint(arena, "system_prompt_extra = \"{s}\"\n", .{"a" ** (max_system_prompt_extra_bytes + 1)});
    const refused = parse(arena, over);
    try std.testing.expectEqual(Problem.Kind.bad_value, refused.problem.?.kind);
    try std.testing.expectEqualStrings("", refused.system_prompt_extra);

    const multi = try std.fmt.allocPrint(arena, "system_prompt_extra = \"\"\"\n{s}\"\"\"\n", .{"a" ** (max_system_prompt_extra_bytes + 1)});
    try std.testing.expectEqual(Problem.Kind.bad_value, parse(arena, multi).problem.?.kind);
}

test "model, base_url and api_key are quoted strings, and a bad one keeps the default" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const arena = state.allocator();

    const set = parse(arena, "model = \"deepseek/deepseek-v4-flash\"\nbase_url = 'https://api.example.com/v1'\napi_key = \"sk-test\" # a secret in the clear\n");
    try std.testing.expect(set.problem == null);
    try std.testing.expectEqualStrings("deepseek/deepseek-v4-flash", set.model);
    try std.testing.expectEqualStrings("https://api.example.com/v1", set.base_url);
    try std.testing.expectEqualStrings("sk-test", set.api_key);

    // Absent is empty, which is what says the environment or the flag is next.
    const absent = parse(arena, "skills = []\n");
    try std.testing.expectEqualStrings("", absent.model);
    try std.testing.expectEqualStrings("", absent.base_url);
    try std.testing.expectEqualStrings("", absent.api_key);

    // A bare value, a number, an empty value and an unterminated quote are all
    // named and leave the key empty rather than half-read.
    for ([_][]const u8{
        "model = bare\n",
        "model =\n",
        "model = 5\n",
        "model = \"open\n",
        "base_url = https://api.example.com/v1\n",
        "api_key = 'sk-test\n",
    }) |text| {
        const bad = parse(arena, text);
        try std.testing.expectEqual(Problem.Kind.bad_value, bad.problem.?.kind);
        try std.testing.expectEqualStrings("", bad.model);
        try std.testing.expectEqualStrings("", bad.base_url);
        try std.testing.expectEqualStrings("", bad.api_key);
    }

    // An empty string is a value the file wrote, and it means no more than an
    // absent key does: the run falls through to the next source.
    const empty = parse(arena, "model = \"\"\n");
    try std.testing.expect(empty.problem == null);
    try std.testing.expectEqualStrings("", empty.model);
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
        "# the sandbox.\n" ++
            "[sandbox] # where writes may go\n" ++
            "enabled = true # on\n" ++
            "writable = [\"/tmp\"] # scratch\n",
    );
    try std.testing.expect(commented.problem == null);
    try std.testing.expect(commented.sandbox.enabled);
    try std.testing.expectEqualStrings("/tmp", commented.sandbox.writable[0]);

    // A table that is not ours stays not ours with a comment on it too, and
    // something after the closing bracket that is neither is not a header at
    // all.
    const labelled = parse(arena, "[model] # somebody else's\nskills = [\"x\"]\n");
    try std.testing.expect(labelled.problem == null);
    try std.testing.expect(labelled.skills == null);
}

// A `#` between the quotes is text, so the closing quote is found before any
// comment is cut. Cutting at the first `#` instead left the opening quote glued
// to the front of the value.
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

    const first = parse(arena, chat.bom ++ "system_prompt_extra = \"x\"\n");
    try std.testing.expect(first.problem == null);
    try std.testing.expectEqualStrings("x", first.system_prompt_extra);

    const tabled = parse(arena, chat.bom ++ "[sandbox]\nenabled = true\n");
    try std.testing.expect(tabled.problem == null);
    try std.testing.expect(tabled.sandbox.enabled);

    // A mark on a later line belongs to that line's key, not to the file, so
    // the key ahead of it is still read and the one it hides is still an
    // unknown key, reported as one.
    const later = parse(arena, "system_prompt_extra = \"x\"\n" ++ chat.bom ++ "skills = []\n");
    try std.testing.expectEqualStrings("x", later.system_prompt_extra);
    try std.testing.expect(later.skills == null);
    try std.testing.expectEqualStrings(chat.bom ++ "skills", later.problem.?.key);
}

test "skills are a list of directories, and absent is not the same as empty" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const arena = state.allocator();

    // Absent: the default root applies, which the caller is told by the null.
    try std.testing.expect((parse(arena, "system_prompt_extra = \"x\"\n")).skills == null);

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

test "deny_commands is one top-level list, and no other spelling is read" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const arena = state.allocator();

    const top = parse(arena, "deny_commands = [\"sudo\", \"su\"]\n");
    try std.testing.expect(top.problem == null);
    try std.testing.expectEqual(@as(usize, 2), top.deny_commands.len);
    try std.testing.expectEqualStrings("sudo", top.deny_commands[0]);
    try std.testing.expectEqualStrings("su", top.deny_commands[1]);

    const removed = [_][]const u8{
        "command_filter = [\"sudo\"]\n",
        "denied_commands = [\"sudo\"]\n",
        "[commands]\ndeny = [\"sudo\"]\n",
        "[command_filter]\ndeny_commands = [\"sudo\"]\n",
    };
    for (removed) |text| {
        const config = parse(arena, text);
        try std.testing.expectEqual(Problem.Kind.unknown_key, config.problem.?.kind);
        try std.testing.expectEqual(@as(usize, 0), config.deny_commands.len);
    }

    // A bare string is not a list.
    const single = parse(arena, "deny_commands = \"sudo\"\n");
    try std.testing.expectEqualStrings("deny_commands", single.problem.?.key);
    try std.testing.expectEqual(Problem.Kind.bad_value, single.problem.?.kind);
    try std.testing.expectEqual(@as(usize, 0), single.deny_commands.len);
}

// A list declared twice is joined, so a denied command or a writable root from
// either declaration is in force. The join is a copy, and a copy that could not
// be made used to leave the key holding the first declaration with nothing
// said: a denied command the run then allows, read from outside as a run whose
// deny list was short by one entry. The values already read stay, and the key
// is named.
test "a list declared twice is joined, and a join that fails names the key" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const arena = state.allocator();

    const both = parse(arena,
        \\[sandbox]
        \\writable = ["build"]
        \\writable = ["dist", "out"]
        \\
    );
    try std.testing.expect(both.problem == null);
    try std.testing.expectEqual(@as(usize, 3), both.sandbox.writable.len);
    try std.testing.expectEqualStrings("build", both.sandbox.writable[0]);
    try std.testing.expectEqualStrings("dist", both.sandbox.writable[1]);
    try std.testing.expectEqualStrings("out", both.sandbox.writable[2]);

    // The join that cannot be made keeps what the file already declared, and
    // names the key rather than leaving a deny list short by an entry the
    // operator wrote down. The first allocation is the copy, so failing it is
    // the whole of that failure.
    var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{ .fail_index = 0 });
    var config = Config{};
    const first = [_][]const u8{"sudo"};
    const second = [_][]const u8{"su"};
    const joined = addToList(&config, failing.allocator(), "deny_commands", &first, &second);
    try std.testing.expectEqualSlices([]const u8, &first, joined);
    try std.testing.expectEqual(Problem.Kind.list_truncated, config.problem.?.kind);
    try std.testing.expectEqualStrings("deny_commands", config.problem.?.key);
}

test "the sandbox is the [sandbox] table with enabled and writable, and only true or false" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const arena = state.allocator();

    const tabled = parse(arena, "[sandbox]\nenabled = true\nwritable = [\".\", \"/tmp\", \"/var/log\"]\n");
    try std.testing.expect(tabled.problem == null);
    try std.testing.expect(tabled.sandbox.enabled);
    try std.testing.expectEqual(@as(usize, 3), tabled.sandbox.writable.len);
    try std.testing.expectEqualStrings(".", tabled.sandbox.writable[0]);
    try std.testing.expectEqualStrings("/tmp", tabled.sandbox.writable[1]);
    try std.testing.expectEqualStrings("/var/log", tabled.sandbox.writable[2]);

    const removed = [_][]const u8{
        "sandbox = true\n",
        "[sandbox]\nenable = true\n",
        "[sandbox]\nallow_write = [\"/tmp\"]\n",
        "[sandbox]\nwriteable = [\"/tmp\"]\n",
    };
    for (removed) |text| {
        const config = parse(arena, text);
        try std.testing.expectEqual(Problem.Kind.unknown_key, config.problem.?.kind);
        try std.testing.expect(!config.sandbox.enabled);
        try std.testing.expectEqual(@as(usize, 0), config.sandbox.writable.len);
    }

    const single = parse(arena, "[sandbox]\nwritable = \"/var/tmp\"\n");
    try std.testing.expectEqual(Problem.Kind.bad_value, single.problem.?.kind);

    // Only the TOML spellings are booleans, quoted or not.
    const not_bool = [_][]const u8{ "1", "yes", "on", "True", "TRUE", "\"true\"", "0", "off", "" };
    for (not_bool) |value| {
        const text = try std.fmt.allocPrint(arena, "[sandbox]\nenabled = {s}\n", .{value});
        const config = parse(arena, text);
        try std.testing.expectEqualStrings("enabled", config.problem.?.key);
        try std.testing.expectEqual(Problem.Kind.bad_value, config.problem.?.kind);
        try std.testing.expect(!config.sandbox.enabled);
    }
    const commented = parse(arena, "[sandbox]\nenabled = true # on\n");
    try std.testing.expect(commented.problem == null);
    try std.testing.expect(commented.sandbox.enabled);
}

const preset_count = @typeInfo(mcp_mod.Preset).@"enum".fields.len;

/// `parse` with every preset switched off, for tests that count the servers the file itself declared.
fn parseBare(arena: std.mem.Allocator, text: []const u8) Config {
    const off = comptime blk: {
        var t: []const u8 = "";
        for (@typeInfo(mcp_mod.Preset).@"enum".fields) |f| t = t ++ "[tools." ++ f.name ++ "]\nenabled = false\n";
        break :blk t;
    };
    return parse(arena, std.fmt.allocPrint(arena, "{s}{s}", .{ off, text }) catch @panic("out of memory"));
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
    const config = parseBare(arena, text);
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
    const commented = parseBare(arena, "[[mcp]]\nname = \"a\"\ncommand = \"b\"\nargs = [\"-y\", \"x\"] # flags\nenv = { K = \"v\" } # one\n");
    try std.testing.expect(commented.problem == null);
    try std.testing.expectEqual(@as(usize, 2), commented.mcp[0].args.len);
    try std.testing.expectEqualStrings("x", commented.mcp[0].args[1]);
    try std.testing.expectEqual(@as(usize, 1), commented.mcp[0].env.len);
    try std.testing.expectEqualStrings("v", commented.mcp[0].env[0][1]);

    // A quoted key is the same name as a bare one: the quotes are how the file
    // spells it, not part of what the variable is called. Before this the
    // quotes reached the child, and the server saw a variable named `"LOG"`.
    const quoted_key = parseBare(arena, "[[mcp]]\nname = \"a\"\ncommand = \"b\"\nenv = { \"LOG\" = \"debug\" }\n");
    try std.testing.expect(quoted_key.problem == null);
    try std.testing.expectEqual(@as(usize, 1), quoted_key.mcp[0].env.len);
    try std.testing.expectEqualStrings("LOG", quoted_key.mcp[0].env[0][0]);
    try std.testing.expectEqualStrings("debug", quoted_key.mcp[0].env[0][1]);

    // A key this reader does not have inside a table is a problem like any
    // other, and the entry still applies.
    const extra = parseBare(arena, "[[mcp]]\nname = \"a\"\ncommand = \"b\"\ncwd = \"/tmp\"\n");
    try std.testing.expectEqualStrings("cwd", extra.problem.?.key);
    try std.testing.expectEqual(@as(usize, 1), extra.mcp.len);

    // A server name is half of every exposed tool name, so a name that cannot
    // be spelled is refused here rather than offered to a provider inside
    // `mcp__bad name__tool`.
    const bad_name = parseBare(arena, "[[mcp]]\nname = \"bad name\"\ncommand = \"b\"\n");
    try std.testing.expectEqual(Problem.Kind.bad_server, bad_name.problem.?.kind);
    try std.testing.expectEqual(@as(usize, 0), bad_name.mcp.len);
    const double = parseBare(arena, "[[mcp]]\nname = \"a__b\"\ncommand = \"b\"\n");
    try std.testing.expectEqual(Problem.Kind.bad_server, double.problem.?.kind);

    // Two tables with one name would collide on one exposed name, so the
    // second is skipped and named.
    const twice = parseBare(arena, "[[mcp]]\nname = \"a\"\ncommand = \"b\"\n[[mcp]]\nname = \"a\"\ncommand = \"c\"\n");
    try std.testing.expectEqual(Problem.Kind.duplicate_server, twice.problem.?.kind);
    try std.testing.expectEqual(@as(usize, 1), twice.mcp.len);
    try std.testing.expectEqualStrings("b", twice.mcp[0].command);

    // Args that are not a list, and an env that is not an inline table, are
    // refused rather than read as empty.
    const bad_args = parseBare(arena, "[[mcp]]\nname = \"a\"\ncommand = \"b\"\nargs = \"-y\"\n");
    try std.testing.expectEqualStrings("args", bad_args.problem.?.key);
    const bad_env = parseBare(arena, "[[mcp]]\nname = \"a\"\ncommand = \"b\"\nenv = [\"K\"]\n");
    try std.testing.expectEqualStrings("env", bad_env.problem.?.key);
}

// `config.example.toml` is the only template the project ships, and a key
// renamed or removed leaves it naming something the reader does not have: the
// file still copies cleanly, and every run a user makes from it prints a
// complaint about a key that was correct when the template was written. Nothing else in the tree would notice, so the
// template is read here and applied.
test "the shipped config template applies" {
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

    // Every example in the template is a comment, so a user who copies the
    // file gets the stock prompt and nothing that spawns a process, reads a
    // directory they did not write or denies a command they did not name.
    try std.testing.expectEqualStrings("", config.system_prompt_extra);
    try std.testing.expect(config.skills == null);
    try std.testing.expectEqual(@as(usize, 0), config.deny_commands.len);
    try std.testing.expect(!config.sandbox.enabled);
    try std.testing.expectEqual(preset_count, config.mcp.len);
}

/// The template is a handful of commented lines; a bigger file is not one.
const max_template_bytes: usize = 64 * 1024;

// The corpus covers the shapes a real config and a wrong one have: keys at the
// root, a table that belongs to something else, single and double quotes, a
// value with a trailing comment, an unterminated quote, a key with no `=`, a
// bare value, multi-line strings open and closed, a skills list, an `[[mcp]]` table with every field and with none, and the same
// key twice.
const config_corpus = [_][]const u8{
    "",
    "\n\n\n",
    "# a comment\nsystem_prompt_extra = \"lite\"\n",
    "system_prompt_extra = 'x'\nsystem_prompt_extra = \"y\"\n",
    "system_prompt_extra",
    "system_prompt_extra =\n",
    "system_prompt_extra = \"\n",
    "system_prompt_extra = \"a\\nb\\\"\"\n",
    "system_prompt_extra = \"a\\",
    "system_prompt_extra = \"a\\q\"\n",
    "system_prompt_extra = \"\"\"\nline\nline\"\"\"\n",
    "system_prompt_extra = \"\"\"\nnever closed\n",
    "system_prompt_extra = '''\r\nx\r\n'''\nskills = []\n",
    "system_prompt_extra = \"\"\"\"\"\"\n",
    "system_prompt_extra = bare # trailing\n",
    "caveman = \"lite\"\nponytail = \"full\"\n",
    "[style]\ncaveman = \"lite\"\n",
    "[commands]\ndeny = [\"sudo\"]\n",
    "[ model ]\nsystem_prompt_extra = \"x\"\n",
    "[]\nkey = 1\n",
    "  system_prompt_extra   =   \"x\"  \r\n",
    "= \"x\"\n",
    "key_without_value = \n",
    "\u{0}system_prompt_extra = \"x\"\n",
    "deny_commands = [\"sudo\", \"rm -rf\"]\n",
    "deny_commands = \"sudo\"\n",
    "[sandbox]\nenabled = true\nwritable = [\".\"]\n",
    "[sandbox]\nenabled = yes\n",
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
    "[[mcp]]\nname = \"a\"\ncommand = \"b\"\nenv = { \"LOG\" = \"d\" }\n",
    "[[mcp]]\nname = \"a\"\ncommand = \"b\"\nenv = { A=B = \"v\" }\n",
    "[[mcp]]\nname = \"a\"\ncommand = \"b\"\nenv = { A\x00B = \"v\" }\n",
    "[[mcp]]\nname = \"a\"\ncommand = \"b\"\nenv = { K = \"a\x00b\" }\n",
    "[[mcp]]\nname = \"a\"\ncommand = \"b\"\nenv = { K\r = \"v\" }\n",
    "[[mcp]]\nname = \"a\"\ncommand = \"b\"\nenv = { K = \"v\rInjected: x\" }\n",
    "[mcp]\nname = \"a\"\ncommand = \"b\"\n",
    "[[mcp]\nname = \"a\"\n",
    "[[  mcp  ]]\nname = \"a\"\ncommand = \"b\"\n",
    "[[mcp]] # a server\nname = \"a\"\ncommand = \"b\"\n",
    "[[mcp]]\nname = \"a b\"\ncommand = \"c\"\n",
    "[[mcp]]\nname = \"a\"\ncommand = \"b\"\n[[mcp]]\nname = \"a\"\ncommand = \"c\"\n",
    "system_prompt_extra = \"x\"\n[[mcp]]\nname = \"a\"\ncommand = \"b\"\nponytail = \"off\"\n",
    "[[mcp]]\nname = \"r\"\nurl = \"https://x.example/mcp\"\napi_key_env = \"K\"\ntimeout = 5\n",
    "[[mcp]]\nname = \"r\"\nurl = \"https://x.example/mcp\"\ncommand = \"b\"\n",
    "[[mcp]]\nname = \"r\"\nurl = \"http://x.example/mcp\"\n",
    "[[mcp]]\nname = \"r\"\ncommand = \"b\"\ntimeout = 5\n",
    "[tools.ast]\nenabled = false\n[tools.git]\nenabled = off\n",
    "[tools.context7]\nenabled = true\nurl = \"https://c.example/mcp\"\napi_key_env = \"C7\"\napi_key_header = \"X-Key\"\ntimeout = 9\n",
    "[tools.web_search]\nenabled = true\ntimeout = 0\n",
    "[tools.nope]\nenabled = false\n",
    "[tools]\nenabled = false\n",
    "[[tools.bash]]\n",
    "[tools.bash]\nurl = \"https://x\"\n",
    "[tools.grep_app]\nenabled = maybe\n",
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

    // Whatever the file said, the addendum is within its bound.
    try std.testing.expect(config.system_prompt_extra.len <= max_system_prompt_extra_bytes);

    // A server the run will connect to is a whole one: a command or a url, never
    // both or neither, and a url it will actually POST to.
    for (config.mcp) |entry| {
        try std.testing.expect((entry.command.len == 0) != (entry.url.len == 0));
        if (entry.url.len != 0) try std.testing.expect(mcp_mod.validUrl(entry.url));
        try std.testing.expect(entry.timeout_s >= 1 and entry.timeout_s <= mcp_mod.max_timeout_s);
        try std.testing.expect(entry.api_key_env.len == 0 or mcp_mod.validEnvName(entry.api_key_env));
        try std.testing.expect(mcp_mod.validHeaderName(entry.api_key_header));
        // Every name here goes into the child process's environment block, and
        // `Environ.Map.put` asserts on a name carrying a NUL or a `=`: a config
        // the reader accepts must be one the spawn can carry.
        for (entry.env) |pair| try std.testing.expect(mcp_mod.validEnvName(pair[0]));
    }
    if (config.tool_problem) |p| try std.testing.expect(p.kind != .bad_value or p.key.len > 0);

    // The same text read twice says the same thing: the reader holds no state
    // across calls, and the fuzzer would find it if it did.
    const again = parse(arena, text);
    try std.testing.expectEqualStrings(config.system_prompt_extra, again.system_prompt_extra);
    try std.testing.expectEqual(config.problem == null, again.problem == null);
    try std.testing.expectEqual(config.tool_problem == null, again.tool_problem == null);
    try std.testing.expectEqual(config.disabled_tools.count(), again.disabled_tools.count());
    try std.testing.expectEqual(config.mcp.len, again.mcp.len);
    try std.testing.expectEqual(config.skills == null, again.skills == null);
    if (config.skills) |dirs| {
        try std.testing.expectEqual(dirs.len, again.skills.?.len);
        for (dirs, again.skills.?) |a, b| try std.testing.expectEqualStrings(a, b);
    }
}

test "every built-in tool and every preset is on until the file says otherwise" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const arena = state.allocator();

    const empty = parse(arena, "");
    try std.testing.expectEqual(@as(usize, 0), empty.disabled_tools.count());
    try std.testing.expectEqual(preset_count, empty.mcp.len);
    try std.testing.expect(empty.tool_problem == null);

    // A table with no `enabled` key changes nothing.
    const bare = parse(arena, "[tools.bash]\n[tools.web_search]\ntimeout = 10\n");
    try std.testing.expect(bare.problem == null and bare.tool_problem == null);
    try std.testing.expectEqual(@as(usize, 0), bare.disabled_tools.count());
    try std.testing.expectEqual(preset_count, bare.mcp.len);
}

test "a built-in tool is switched off by enabled = false, and only that spelling of a boolean" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const arena = state.allocator();

    const config = parseBare(arena,
        \\[tools.ast]
        \\enabled = false
        \\
        \\[tools.git]   # only reads
        \\enabled = false
        \\
        \\[tools.todo]
        \\enabled = false
        \\
        \\[tools.search]
        \\enabled = false
        \\enabled = true    # the last line wins
        \\
        \\[tools.bash]
        \\enabled = true
    );
    try std.testing.expect(config.problem == null and config.tool_problem == null);
    try std.testing.expectEqual(@as(usize, 3), config.disabled_tools.count());
    try std.testing.expect(config.disabled_tools.contains(.ast));
    try std.testing.expect(config.disabled_tools.contains(.git));
    try std.testing.expect(config.disabled_tools.contains(.todo));
    try std.testing.expect(!config.disabled_tools.contains(.search));
    try std.testing.expect(!config.disabled_tools.contains(.bash));
    // A built-in is not a remote server, whatever its table says.
    try std.testing.expectEqual(@as(usize, 0), config.mcp.len);

    const junk = parseBare(arena, "[tools.ast]\nenabled = maybe\n[tools.git]\nenabled = false\n");
    try std.testing.expectEqualStrings("ast", junk.tool_problem.?.name);
    try std.testing.expectEqualStrings("enabled", junk.tool_problem.?.key);
    try std.testing.expectEqual(@as(@TypeOf(junk.tool_problem.?.kind), .bad_value), junk.tool_problem.?.kind);
    // The scan goes on, so the rest of the file still applies.
    try std.testing.expect(junk.disabled_tools.contains(.git));

    // `yes`, `0` and a quoted boolean are not booleans.
    for ([_][]const u8{ "yes", "0", "\"off\"", "False" }) |value| {
        const text = try std.fmt.allocPrint(arena, "[tools.ast]\nenabled = {s}\n", .{value});
        const bad = parseBare(arena, text);
        try std.testing.expectEqualStrings("ast", bad.tool_problem.?.name);
        try std.testing.expectEqual(@as(usize, 0), bad.disabled_tools.count());
    }
}

test "a preset is one more remote server once it is enabled, with its options validated" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const arena = state.allocator();

    const config = parseBare(arena,
        \\[[mcp]]
        \\name = "fs"
        \\command = "npx"
        \\
        \\[tools.context7]
        \\enabled = true
        \\
        \\[tools.web_search]
        \\enabled = true
        \\url = "https://search.example/mcp"
        \\api_key_env = "EXA_API_KEY"
        \\api_key_header = "x-api-key"
        \\timeout = 45
        \\
        \\[tools.grep_app]
        \\enabled = false
    );
    try std.testing.expect(config.problem == null and config.tool_problem == null);
    // The file's own servers first, then the presets in the order the build lists them.
    try std.testing.expectEqual(@as(usize, 3), config.mcp.len);
    try std.testing.expectEqualStrings("fs", config.mcp[0].name);
    const web = config.mcp[1];
    try std.testing.expectEqualStrings("web_search", web.name);
    try std.testing.expectEqualStrings("https://search.example/mcp", web.url);
    try std.testing.expectEqualStrings("EXA_API_KEY", web.api_key_env);
    try std.testing.expectEqualStrings("x-api-key", web.api_key_header);
    try std.testing.expectEqual(@as(u32, 45), web.timeout_s);
    try std.testing.expectEqualStrings("", web.command);
    // The defaults: the preset's own endpoint, no key, Authorization, 30 s.
    const docs = config.mcp[2];
    try std.testing.expectEqualStrings("context7", docs.name);
    try std.testing.expectEqualStrings("https://mcp.context7.com/mcp", docs.url);
    try std.testing.expectEqualStrings("", docs.api_key_env);
    try std.testing.expectEqualStrings("Authorization", docs.api_key_header);
    try std.testing.expectEqual(@as(u32, 30), docs.timeout_s);

    // Plain http is for this machine only, and a loopback one is allowed.
    const local = parseBare(arena, "[tools.grep_app]\nenabled = true\nurl = \"http://127.0.0.1:9000/mcp\"\n");
    try std.testing.expect(local.tool_problem == null);
    try std.testing.expectEqualStrings("http://127.0.0.1:9000/mcp", local.mcp[0].url);

    // Each of these is a value the run cannot honor, and names the key.
    const bad = [_][]const u8{
        "url = \"http://search.example/mcp\"",
        "url = \"https://u:p@search.example/mcp\"",
        "url = \"nonsense\"",
        "timeout = 0",
        "timeout = 601",
        "timeout = 30s",
        "timeout = -1",
        "api_key_env = \"A=B\"",
        "api_key_env = \"MY KEY\"",
        "api_key_header = \"X Key\"",
        "api_key_header = \"\"",
        "enabled = sure",
    };
    for (bad) |line| {
        const text = try std.fmt.allocPrint(arena, "[tools.web_search]\nenabled = true\n{s}\n", .{line});
        const parsed = parseBare(arena, text);
        try std.testing.expectEqualStrings("web_search", parsed.tool_problem.?.name);
        try std.testing.expect(std.mem.startsWith(u8, line, parsed.tool_problem.?.key));
    }
    // An empty variable name is no key, not an error.
    const unset = parseBare(arena, "[tools.web_search]\nenabled = true\napi_key_env = \"\"\n");
    try std.testing.expect(unset.tool_problem == null);
    try std.testing.expectEqualStrings("", unset.mcp[0].api_key_env);
}

test "a tool name this build does not have is a problem the run stops on" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const arena = state.allocator();

    const typo = parse(arena, "[tools.serach]\nenabled = false\n[tools.ast]\nenabled = false\n");
    try std.testing.expectEqualStrings("serach", typo.tool_problem.?.name);
    try std.testing.expectEqual(@as(@TypeOf(typo.tool_problem.?.kind), .unknown_tool), typo.tool_problem.?.kind);
    // Nothing else is skipped on the way: the misspelling is reported, not fatal to the scan.
    try std.testing.expect(typo.disabled_tools.contains(.ast));
    // It is a tool problem and not a note, so the run cannot carry on with it.
    try std.testing.expect(typo.problem == null);

    // A name is exact: case, a prefix and a missing name are all unknown.
    for ([_][]const u8{ "[tools.Bash]", "[tools.bas]", "[tools]", "[tools.]", "[tools.bash.x]", "[tools.mcp__fs__x]" }) |header| {
        const parsed = parse(arena, try std.fmt.allocPrint(arena, "{s}\nenabled = false\n", .{header}));
        try std.testing.expect(parsed.tool_problem != null);
        try std.testing.expectEqual(@as(usize, 0), parsed.disabled_tools.count());
    }
    // The first one is the one named.
    const two = parse(arena, "[tools.one]\n[tools.two]\n");
    try std.testing.expectEqualStrings("one", two.tool_problem.?.name);
    // An array of tables is not a tool table.
    const array = parse(arena, "[[tools.bash]]\nenabled = false\n");
    try std.testing.expect(array.problem != null);
    try std.testing.expectEqual(@as(usize, 0), array.disabled_tools.count());
}

test "a key a tool table does not have is noted and the default kept" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const arena = state.allocator();

    // A built-in takes only `enabled`.
    const builtin = parseBare(arena, "[tools.bash]\nurl = \"https://x.example\"\n");
    try std.testing.expectEqualStrings("url", builtin.problem.?.key);
    try std.testing.expectEqual(Problem.Kind.unknown_key, builtin.problem.?.kind);
    try std.testing.expect(builtin.tool_problem == null);

    const preset = parseBare(arena, "[tools.context7]\nenabled = true\nretries = 3\n");
    try std.testing.expectEqualStrings("retries", preset.problem.?.key);
    try std.testing.expectEqual(Problem.Kind.unknown_key, preset.problem.?.kind);
    try std.testing.expectEqual(@as(usize, 1), preset.mcp.len);
    try std.testing.expectEqual(@as(u32, 30), preset.mcp[0].timeout_s);
}

test "an [[mcp]] table is a command or a url, and a url server takes the remote options" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const arena = state.allocator();

    const config = parseBare(arena,
        \\[[mcp]]
        \\name = "docs"
        \\url = "https://docs.example/mcp"
        \\api_key_env = "DOCS_KEY"
        \\api_key_header = "X-Docs-Key"
        \\timeout = 12
        \\
        \\[[mcp]]
        \\name = "local"
        \\url = "http://localhost:8931/mcp"
    );
    try std.testing.expect(config.problem == null);
    try std.testing.expectEqual(@as(usize, 2), config.mcp.len);
    try std.testing.expectEqualStrings("https://docs.example/mcp", config.mcp[0].url);
    try std.testing.expectEqualStrings("", config.mcp[0].command);
    try std.testing.expectEqualStrings("DOCS_KEY", config.mcp[0].api_key_env);
    try std.testing.expectEqualStrings("X-Docs-Key", config.mcp[0].api_key_header);
    try std.testing.expectEqual(@as(u32, 12), config.mcp[0].timeout_s);
    try std.testing.expectEqual(@as(u32, 30), config.mcp[1].timeout_s);

    // Both forms, neither form, a url that leaks, and the options of one form on
    // the other are each a server nothing can honestly start.
    const broken = [_][]const u8{
        "name = \"a\"\ncommand = \"c\"\nurl = \"https://x.example/mcp\"\n",
        "name = \"a\"\n",
        "name = \"a\"\nurl = \"http://x.example/mcp\"\n",
        "name = \"a\"\nurl = \"https://u:p@x.example/mcp\"\n",
        "name = \"a\"\nurl = \"\"\n",
        "name = \"a\"\ncommand = \"c\"\napi_key_env = \"K\"\n",
        "name = \"a\"\ncommand = \"c\"\ntimeout = 5\n",
        "name = \"a\"\nurl = \"https://x.example/mcp\"\nargs = [\"x\"]\n",
        "name = \"a\"\nurl = \"https://x.example/mcp\"\nenv = { K = \"v\" }\n",
        "name = \"a\"\nurl = \"https://x.example/mcp\"\ntimeout = 0\n",
        "name = \"a\"\nurl = \"https://x.example/mcp\"\napi_key_env = \"not a name\"\n",
        "name = \"a\"\nurl = \"https://x.example/mcp\"\napi_key_header = \"bad header\"\n",
        "name = \"a\"\ncommand = \"c\"\nenv = { A=B = \"v\" }\n",
        "name = \"a\"\ncommand = \"c\"\nenv = { A\x00B = \"v\" }\n",
        "name = \"a\"\ncommand = \"c\"\nenv = { K = \"a\x00b\" }\n",
    };
    for (broken) |body| {
        const parsed = parseBare(arena, try std.fmt.allocPrint(arena, "[[mcp]]\n{s}", .{body}));
        try std.testing.expectEqual(@as(usize, 0), parsed.mcp.len);
        try std.testing.expect(parsed.problem != null);
    }

    // A preset and a table of the same name would collide on one tool name.
    const twice = parseBare(arena, "[[mcp]]\nname = \"context7\"\ncommand = \"c\"\n[tools.context7]\nenabled = true\n");
    try std.testing.expectEqual(@as(usize, 1), twice.mcp.len);
    try std.testing.expectEqual(Problem.Kind.duplicate_server, twice.problem.?.kind);
    try std.testing.expectEqualStrings("c", twice.mcp[0].command);
}
