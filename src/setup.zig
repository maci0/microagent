//! Interactive configuration using the same template and parser as an agent run.
const std = @import("std");
const chat = @import("chat.zig");
const config = @import("config.zig");
const mcp = @import("mcp.zig");
const net = @import("net.zig");
const tool = @import("tool.zig");

pub const usage =
    "usage: microagent setup [--config <file>]\n" ++
    "Create a missing config from the embedded template, then configure it interactively.\n" ++
    "Uses --config, MICROAGENT_CONFIG, or ~/.microagent/config.toml.\n" ++
    "Enter keeps the current value; '-' clears a text setting. EOF cancels edits.\n" ++
    "Questions cover the provider, tools, remote endpoints, instructions, skills and sandbox.\n";

pub fn configArg(argv: []const []const u8) ![]const u8 {
    if (argv.len == 0) return "";
    if (argv.len == 2 and std.mem.eql(u8, argv[0], "--config") and argv[1].len != 0) return argv[1];
    if (argv.len == 1 and std.mem.startsWith(u8, argv[0], "--config=") and argv[0].len > "--config=".len)
        return argv[0]["--config=".len..];
    return error.InvalidArguments;
}

var key_terminal: ?std.posix.termios = null;

fn cancelKeyInput(_: std.posix.SIG) callconv(.c) void {
    if (key_terminal) |saved| std.posix.tcsetattr(std.Io.File.stdin().handle, .NOW, saved) catch {};
    std.process.exit(130);
}

const Wizard = struct {
    io: std.Io,
    arena: std.mem.Allocator,
    reader: *std.Io.Reader,
    text: []const u8,

    fn answer(self: *Wizard, label: []const u8, current: []const u8, secret: bool) ![]const u8 {
        // Never echo a key at a terminal. Pipes need no terminal settings.
        const terminal = if (secret) std.posix.tcgetattr(std.Io.File.stdin().handle) catch |err| switch (err) {
            error.NotATerminal => null,
            else => return err,
        } else null;
        var old_int: std.posix.Sigaction = undefined;
        var old_term: std.posix.Sigaction = undefined;
        if (terminal) |saved| {
            key_terminal = saved;
            const action: std.posix.Sigaction = .{ .handler = .{ .handler = cancelKeyInput }, .mask = std.posix.sigemptyset(), .flags = 0 };
            std.posix.sigaction(.INT, &action, &old_int);
            std.posix.sigaction(.TERM, &action, &old_term);
        }
        defer if (terminal) |saved| {
            std.posix.tcsetattr(std.Io.File.stdin().handle, .NOW, saved) catch {};
            std.posix.sigaction(.INT, &old_int, null);
            std.posix.sigaction(.TERM, &old_term, null);
            key_terminal = null;
            net.writeErr(self.io, "\n");
        };
        if (terminal) |saved| {
            var hidden = saved;
            hidden.lflag.ECHO = false;
            try std.posix.tcsetattr(std.Io.File.stdin().handle, .NOW, hidden);
        }
        net.note(self.io, self.arena, "{s} [{s}]: ", .{ label, if (secret) (if (current.len == 0) "unset" else "set; hidden") else chat.safeTextAll(self.arena, current) });
        const line = (try self.reader.takeDelimiter('\n')) orelse return error.SetupCancelled;
        const value = std.mem.trim(u8, line, " \t\r");
        if (!std.unicode.utf8ValidateSlice(value) or net.hasHeaderControlBytes(value)) return error.InvalidInput;
        return try self.arena.dupe(u8, value);
    }

    fn yes(self: *Wizard, label: []const u8, current: bool) !bool {
        while (true) {
            const value = try self.answer(label, if (current) "Y/n" else "y/N", false);
            if (value.len == 0) return current;
            if (std.ascii.eqlIgnoreCase(value, "y") or std.ascii.eqlIgnoreCase(value, "yes")) return true;
            if (std.ascii.eqlIgnoreCase(value, "n") or std.ascii.eqlIgnoreCase(value, "no")) return false;
            net.writeErr(self.io, "Answer yes or no.\n");
        }
    }

    fn set(self: *Wizard, table: []const u8, key: []const u8, value: ?[]const u8) !void {
        self.text = try config.setValue(self.arena, self.text, table, key, value);
    }

    fn string(self: *Wizard, table: []const u8, key: []const u8, label: []const u8, current: []const u8, url: bool, secret: bool) !void {
        while (true) {
            var value = try self.answer(label, current, secret);
            if (value.len == 0) return;
            if (std.mem.eql(u8, value, "-")) value = "";
            if (url and value.len != 0 and !mcp.validUrl(value)) {
                net.writeErr(self.io, "Use an HTTPS URL or HTTP on loopback, without embedded credentials.\n");
                continue;
            }
            if (std.mem.eql(u8, key, "api_key_env") and value.len != 0 and !mcp.validEnvName(value)) {
                net.writeErr(self.io, "Use an environment variable name containing letters, digits and underscores.\n");
                continue;
            }
            // JSON basic-string escapes are also accepted by the config reader.
            var quoted: std.Io.Writer.Allocating = .init(self.arena);
            try chat.writeJsonString(&quoted.writer, value);
            try self.set(table, key, quoted.written());
            return;
        }
    }

    fn listFeature(self: *Wizard, key: []const u8, label: []const u8, current: ?[]const []const u8) !void {
        const enabled = current == null or current.?.len != 0;
        const wanted = try self.yes(label, enabled);
        if (wanted != enabled) try self.set("", key, if (wanted) null else "[]");
    }

    fn questions(self: *Wizard, default_model: []const u8) !void {
        const cfg = config.parse(self.arena, self.text);
        try self.string("", "base_url", "Provider API base URL", cfg.base_url, true, false);
        try self.string("", "model", "Model", if (cfg.model.len == 0) default_model else cfg.model, false, false);
        net.writeErr(self.io, "API key is stored in this file; leave blank to keep it or use MICROAGENT_API_KEY.\n");
        try self.string("", "api_key", "API key", cfg.api_key, false, true);
        const style = cfg.system_prompt_extra.len != 0;
        if (try self.yes("Enable the system prompt addendum (template: terse prose, minimal code)?", style) != style) {
            const extra = config.parse(self.arena, @import("build_options").config_template).system_prompt_extra;
            var quoted: std.Io.Writer.Allocating = .init(self.arena);
            try chat.writeJsonString(&quoted.writer, if (style) "" else extra);
            try self.set("", "system_prompt_extra", quoted.written());
        }
        try self.listFeature("agents_files", "Read repository instructions?", cfg.agents_files);
        try self.listFeature("skills", "Enable skills?", cfg.skills);
        const sandbox = try self.yes("Enable workspace sandbox?", cfg.sandbox.enabled);
        if (sandbox != cfg.sandbox.enabled) try self.set("sandbox", "enabled", if (sandbox) "true" else "false");

        var disabled = cfg.disabled_tools;
        for (std.enums.values(chat.Tool)) |builtin_tool| {
            const label = try std.fmt.allocPrint(self.arena, "Enable {s} tool?", .{@tagName(builtin_tool)});
            const enabled = enabled: while (true) {
                const wanted = try self.yes(label, !disabled.contains(builtin_tool));
                if (!wanted and !disabled.contains(builtin_tool) and disabled.count() + 1 == std.enums.values(chat.Tool).len) {
                    net.writeErr(self.io, "At least one built-in tool must stay enabled.\n");
                    continue;
                }
                break :enabled wanted;
            };
            if (enabled == disabled.contains(builtin_tool)) {
                try self.set(try std.fmt.allocPrint(self.arena, "tools.{s}", .{@tagName(builtin_tool)}), "enabled", if (enabled) "true" else "false");
                disabled.setPresent(builtin_tool, !enabled);
            }
        }
        if (disabled.count() == std.enums.values(chat.Tool).len) return error.AllToolsDisabled;
        net.writeErr(self.io, "Remote tools send queries to their configured endpoints when called.\n");
        for (std.enums.values(mcp.Preset)) |preset| {
            const setting = cfg.presets.get(preset);
            const table = try std.fmt.allocPrint(self.arena, "tools.{s}", .{@tagName(preset)});
            const label = try std.fmt.allocPrint(self.arena, "Enable {s} remote tools?", .{@tagName(preset)});
            const enabled = try self.yes(label, setting.enabled);
            if (enabled != setting.enabled) try self.set(table, "enabled", if (enabled) "true" else "false");
            if (enabled) {
                try self.string(table, "url", "  API endpoint", if (setting.url.len != 0) setting.url else preset.url(), true, false);
                try self.string(table, "api_key_env", "  API key environment variable (optional)", setting.api_key_env, false, false);
            }
        }
    }
};

pub fn run(io: std.Io, arena: std.mem.Allocator, path: []const u8, default_model: []const u8, max_bytes: usize) !void {
    const original = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_bytes));
    const cfg = config.parse(arena, original);
    if (cfg.problem != null or cfg.tool_problem != null) return error.InvalidConfig;
    net.note(io, arena, "Config: {s}\nEnter keeps current values; '-' clears text. EOF cancels edits.\n", .{chat.safeTextAll(arena, path)});
    var buffer: [4096]u8 = undefined;
    var input = std.Io.File.stdin().readerStreaming(io, &buffer);
    var wizard: Wizard = .{ .io = io, .arena = arena, .reader = &input.interface, .text = original };
    try wizard.questions(default_model);
    const result = config.parse(arena, wizard.text);
    if (result.problem != null or result.tool_problem != null or wizard.text.len > max_bytes) return error.InvalidConfig;
    const latest = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_bytes));
    if (!std.mem.eql(u8, latest, original)) return error.ConfigChangedDuringSetup;
    if (!std.mem.eql(u8, wizard.text, original)) {
        try std.Io.Dir.cwd().setFilePermissions(io, path, .fromMode(0o600), .{});
        try tool.writeFileAtomic(io, std.Io.Dir.cwd(), path, wizard.text);
    }
    net.note(io, arena, "Saved config: {s}\n", .{chat.safeTextAll(arena, path)});
}
