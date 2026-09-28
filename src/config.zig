//! What the environment and the config file add on top of the command line:
//! the API key and where it came from, the reply-style levels, and the trace
//! that prints the configuration a run resolved.
//!
//! Sits on `cli` (the parsed `Options` it fills in and the truncations it
//! quotes values through) and on the leaves, so the agent loop is the only
//! thing above it. `main` calls each of these once, before the first turn.

const std = @import("std");
const Io = std.Io;

const chat = @import("chat.zig");
const cli = @import("cli.zig");
const net = @import("net.zig");
const style_mod = @import("style.zig");
const tool_mod = @import("tool.zig");

/// The reply-style config is a handful of keys; a bigger file is not one.
const max_config_bytes: usize = 64 * 1024;

/// Cheap env-gated trace, for debugging a stuck stream. Set once from MDEBUG
/// before any turn runs.
pub var debug_enabled: bool = false;

/// The debugging switch, on unless the variable is set to something that reads
/// as off. Set-at-all was the old reading, which turned the trace on for a
/// wrapper that exports the name to pass a flag it has not set yet.
pub fn debugEnabled(env: *const std.process.Environ.Map) bool {
    const v = cli.envValue(env, "MDEBUG") orelse return false;
    if (std.ascii.eqlIgnoreCase(v, "0") or std.ascii.eqlIgnoreCase(v, "off") or
        std.ascii.eqlIgnoreCase(v, "no") or std.ascii.eqlIgnoreCase(v, "false")) return false;
    return true;
}

/// In the order they are tried, and the order the help text and README name
/// them: the project's own variable first, then the provider's.
const key_vars = [_][]const u8{ "MICROAGENT_API_KEY", "OPENAI_API_KEY", "OPENROUTER_API_KEY", "DEEPSEEK_API_KEY" };

/// The same list spelled as the sentence an error needs, so adding a provider
/// touches one place.
pub const key_var_names = std.fmt.comptimePrint("{s}, {s}, {s} or {s}", .{ key_vars[0], key_vars[1], key_vars[2], key_vars[3] });

/// The key this run will use, and where it came from. A secret file that is
/// there and holds nothing is named rather than passed off as no key at all:
/// the file being present is exactly why a reader believes a key is set.
pub const Key = struct { value: []const u8, source: []const u8 };

pub fn resolveKey(io: Io, init: std.process.Init, given: []const u8) Key {
    if (given.len > 0) return .{ .value = given, .source = "--api-key" };
    for (key_vars) |n| {
        if (cli.envValue(init.environ_map, n)) |v| return .{ .value = v, .source = n };
    }
    const fallback = std.fs.path.join(init.arena.allocator(), &.{
        init.environ_map.get("HOME") orelse return .{ .value = "", .source = "none" },
        ".secrets",
        "openrouter",
    }) catch return .{ .value = "", .source = "none" };
    if (tool_mod.readSecret(init, fallback)) |v| {
        if (v.len != 0) return .{ .value = v, .source = fallback };
        net.note(io, init.arena.allocator(), "microagent: {s} is empty; no key in it\n", .{fallback});
    }
    return .{ .value = "", .source = "none" };
}

/// The reply-style levels for this run and the file they were read from, the
/// latter for the trace: precedence here spans three sources, so a level on its
/// own cannot say whether a file, a variable or a built-in default set it.
pub const LoadedStyle = struct { style: style_mod.Style, source: ?[]const u8 };

/// The reply-style levels for this run, from the TOML config named by
/// --config, MICROAGENT_CONFIG or `$HOME/.microagent/config.toml`, then the
/// MICROAGENT_CAVEMAN / MICROAGENT_PONYTAIL overrides, then the built-in
/// defaults. A missing file, an unreadable one, or an unknown key costs the run
/// nothing: the levels that were understood still apply. The source is the file
/// that was looked for, readable or not, because the question the trace answers
/// is which one was consulted.
pub fn loadStyle(io: Io, init: std.process.Init, arena: std.mem.Allocator, config: []const u8) LoadedStyle {
    var style: style_mod.Style = .{};
    const source = styleConfigPath(init.environ_map, arena, config);
    // Both a path and a key out of this file are quoted through `safeText`
    // rather than `clip`: a config is a file a reviewed repository can
    // commit, so its lines carry whatever bytes the commit did, and the same
    // is true of a path a directory name was spelled with. The two untrusted
    // byte paths this program already has normalize what they print, and a
    // diagnostic is the third.
    const path_text = chat.safeText(arena, source.path orelse "", cli.quoted_value_bytes);
    var text: ?[]const u8 = null;
    if (source.path) |p| {
        text = std.Io.Dir.cwd().readFileAlloc(io, p, arena, .limited(max_config_bytes)) catch |err| blk: {
            if (configReadWorthReporting(source.named, err))
                net.note(io, arena, "microagent: config {s}: {s}; using the built-in levels\n", .{ path_text, @errorName(err) });
            break :blk null;
        };
    }
    if (resolveStyle(&style, text, cli.envValue(init.environ_map, "MICROAGENT_CAVEMAN"), cli.envValue(init.environ_map, "MICROAGENT_PONYTAIL"))) |unknown| {
        const key = chat.safeText(arena, unknown.key, cli.quoted_value_bytes);
        if (unknown.from_config) {
            if (unknown.bad_value)
                net.note(io, arena, "microagent: config {s}: '{s}' is not a level; keeping the default\n", .{ path_text, key })
            else
                net.note(io, arena, "microagent: config {s}: '{s}' is not a key this file uses; keeping the default\n", .{ path_text, key });
        } else {
            net.note(io, arena, "microagent: {s} is not a level; keeping the default\n", .{key});
        }
    }
    return .{ .style = style, .source = source.path };
}

/// The configuration this run resolved, on stderr when MDEBUG is on. Precedence
/// spans three sources per option, so the only way to tell which one answered
/// is to be told; the key is named by the source it came from and never
/// printed, and a base url is the redacted spelling so credentials in one do
/// not reach a log either.
pub fn traceConfig(io: Io, arena: std.mem.Allocator, opts: cli.Options, style: LoadedStyle, key_source: []const u8) void {
    if (!debug_enabled) return;
    net.note(io, arena,
        \\[mdebug] model={s} base_url={s}
        \\[mdebug] max_turns={d} max_tokens={d} budget_s={s} reasoning_effort={s}
        \\[mdebug] ca_bundle={s} session_dir={s}
        \\[mdebug] style_config={s}
        \\[mdebug] caveman={s} ponytail={s}
        \\[mdebug] api key from {s}
        \\
    , .{
        opts.model,
        cli.displayUrl(arena, opts.base_url),
        opts.max_turns,
        opts.max_tokens,
        if (opts.budget_s) |b| std.fmt.allocPrint(arena, "{d}", .{b}) catch "?" else "unset",
        opts.reasoning_effort orelse "unset",
        if (opts.ca_bundle.len == 0) "unset" else opts.ca_bundle,
        if (opts.session_dir.len == 0) "off" else opts.session_dir,
        style.source orelse "none",
        style.style.caveman.name(),
        style.style.ponytail.name(),
        key_source,
    });
}

/// Whether a style config that could not be read is worth a line on stderr. A
/// config somebody named is one the caller believes is there, so any failure
/// is said out loud. The default path is missing on most machines and that is
/// not a fault, but a file that is there and is a directory, is unreadable,
/// or is over the cap is: the run continues on the built-in levels, and
/// silence there is a misconfiguration nothing reports.
fn configReadWorthReporting(named: bool, err: anyerror) bool {
    return named or err != error.FileNotFound;
}

/// The file the style config is read from, and whether anything named it. A
/// flag or a variable naming a file that cannot be read is a caller's mistake
/// worth reporting; the default path is absent on most machines.
const StyleSource = struct { path: ?[]const u8, named: bool };

/// Where the style config is read from: --config, else MICROAGENT_CONFIG, else
/// `$HOME/.microagent/config.toml`. An empty MICROAGENT_CONFIG turns the
/// file off, as does a home that is not there. Takes the environment map
/// rather than the whole `Init`, so the precedence is testable without one.
fn styleConfigPath(env: *const std.process.Environ.Map, arena: std.mem.Allocator, config: []const u8) StyleSource {
    if (config.len > 0) return .{ .path = std.fs.path.resolve(arena, &.{config}) catch config, .named = true };
    if (env.get("MICROAGENT_CONFIG")) |raw| {
        const path = std.mem.trim(u8, raw, net.env_surrounding);
        if (path.len == 0) return .{ .path = null, .named = false };
        return .{ .path = std.fs.path.resolve(arena, &.{path}) catch path, .named = true };
    }
    const home = env.get("HOME") orelse return .{ .path = null, .named = false };
    const path = std.fs.path.join(arena, &.{ home, ".microagent", "config.toml" }) catch
        return .{ .path = null, .named = false };
    return .{ .path = std.fs.path.resolve(arena, &.{path}) catch path, .named = false };
}

/// A level named by a key or a variable that the parser does not have, so the
const UnknownLevel = struct {
    key: []const u8,
    /// The value came from the config file, so the message can name the file.
    from_config: bool,
    /// The value is what names no level, rather than the key naming no
    /// setting; a variable can only be the former.
    bad_value: bool,
};

/// The levels, in the order the doc comment names: the config file, then the
/// environment overrides, over the built-in defaults. One value that is not a
/// level does not cost the run the others, so every source is read to the end
/// and the first offending value is the one named on stderr.
fn resolveStyle(
    style: *style_mod.Style,
    config: ?[]const u8,
    caveman_env: ?[]const u8,
    ponytail_env: ?[]const u8,
) ?UnknownLevel {
    var unknown: ?UnknownLevel = null;
    if (config) |text| {
        if (style.applyToml(text)) |problem| {
            if (unknown == null)
                unknown = .{ .key = problem.key, .from_config = true, .bad_value = problem.bad_value };
        }
    }
    if (caveman_env) |v| {
        if (style_mod.parseCaveman(v)) |level| style.caveman = level else if (unknown == null) unknown = .{ .key = "MICROAGENT_CAVEMAN", .from_config = false, .bad_value = true };
    }
    if (ponytail_env) |v| {
        if (style_mod.parsePonytail(v)) |level| style.ponytail = level else if (unknown == null) unknown = .{ .key = "MICROAGENT_PONYTAIL", .from_config = false, .bad_value = true };
    }
    return unknown;
}

// A level the parser does not have is reported, not fatal: the other knob and
// the rest of the file still apply, because a typo in one variable is not a
// reason to silently run the run the user did not ask for.
test "one bad style value does not cost the run the levels it did understand" {
    var style: style_mod.Style = .{};

    const bad_env = resolveStyle(&style, null, "brief", "off").?;
    try std.testing.expectEqualStrings("MICROAGENT_CAVEMAN", bad_env.key);
    try std.testing.expectEqual(style_mod.CavemanLevel.ultra, style.caveman);
    try std.testing.expectEqual(style_mod.PonytailLevel.off, style.ponytail);

    var from_file: style_mod.Style = .{};
    const bad_file = resolveStyle(&from_file, "ponytail = \"lazy\"\ncaveman = \"lite\"\n", null, null).?;
    try std.testing.expectEqualStrings("ponytail", bad_file.key);
    try std.testing.expectEqual(style_mod.PonytailLevel.full, from_file.ponytail);
    // The key after the bad one is still read.
    try std.testing.expectEqual(style_mod.CavemanLevel.lite, from_file.caveman);
}

test "the env levels override the config file's, and a bad one is named" {
    var style: style_mod.Style = .{};
    try std.testing.expect(resolveStyle(&style, "caveman = \"off\"\nponytail = \"lite\"\n", "wenyan-ultra", "ultra") == null);
    try std.testing.expectEqual(style_mod.CavemanLevel.wenyan_ultra, style.caveman);
    try std.testing.expectEqual(style_mod.PonytailLevel.ultra, style.ponytail);

    // The file still decides the knob the environment says nothing about.
    try std.testing.expect(resolveStyle(&style, "caveman = \"lite\"\n", null, null) == null);
    try std.testing.expectEqual(style_mod.CavemanLevel.lite, style.caveman);

    // A value that is not a level is reported, and the level that would have
    // been replaced stands, whichever source it came from.
    const bad_env = resolveStyle(&style, null, "brief", null).?;
    try std.testing.expectEqualStrings("MICROAGENT_CAVEMAN", bad_env.key);
    try std.testing.expect(!bad_env.from_config);
    try std.testing.expectEqual(style_mod.CavemanLevel.lite, style.caveman);

    const bad_file = resolveStyle(&style, "ponytail = \"lazy\"\n", "lite", null).?;
    try std.testing.expectEqualStrings("ponytail", bad_file.key);
    try std.testing.expect(bad_file.from_config);
    try std.testing.expect(bad_file.bad_value);
    try std.testing.expectEqual(style_mod.PonytailLevel.ultra, style.ponytail);

    // A misspelled key is named as a key, not as a level, and the default it
    // would have replaced stands.
    const typo = resolveStyle(&style, "cavmen = \"off\"\n", "lite", null).?;
    try std.testing.expectEqualStrings("cavmen", typo.key);
    try std.testing.expect(typo.from_config);
    try std.testing.expect(!typo.bad_value);
    try std.testing.expectEqual(style_mod.CavemanLevel.lite, style.caveman);

    // Every level a config key may name, a variable may name too, because both
    // are read by the same parser. A level that reached one and not the other
    // is a spelling a wrapper exporting the variable cannot set, and the two
    // disagreeing is only visible where both paths are, which is here.
    for (std.enums.values(style_mod.CavemanLevel)) |level| {
        var from_env: style_mod.Style = .{};
        try std.testing.expect(resolveStyle(&from_env, null, level.name(), null) == null);
        try std.testing.expectEqual(level, from_env.caveman);

        var cfg_buf: [96]u8 = undefined;
        const cfg = try std.fmt.bufPrint(&cfg_buf, "caveman = \"{s}\"\n", .{level.name()});
        var from_file: style_mod.Style = .{};
        try std.testing.expect(resolveStyle(&from_file, cfg, null, null) == null);
        try std.testing.expectEqual(level, from_file.caveman);
    }
    for (std.enums.values(style_mod.PonytailLevel)) |level| {
        var from_env: style_mod.Style = .{};
        try std.testing.expect(resolveStyle(&from_env, null, null, level.name()) == null);
        try std.testing.expectEqual(level, from_env.ponytail);

        var cfg_buf: [96]u8 = undefined;
        const cfg = try std.fmt.bufPrint(&cfg_buf, "ponytail = \"{s}\"\n", .{level.name()});
        var from_file: style_mod.Style = .{};
        try std.testing.expect(resolveStyle(&from_file, cfg, null, null) == null);
        try std.testing.expectEqual(level, from_file.ponytail);
    }
    // The bare `wenyan` shorthand is a config spelling, and the environment
    // reads the same table, so it answers there too.
    var shorthand: style_mod.Style = .{};
    try std.testing.expect(resolveStyle(&shorthand, null, "wenyan", null) == null);
    try std.testing.expectEqual(style_mod.CavemanLevel.wenyan_full, shorthand.caveman);
}

test "an environment variable set to nothing is not a value" {
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();

    try std.testing.expect(cli.envValue(&env, "MICROAGENT_MODEL") == null);
    try env.put("MICROAGENT_MODEL", "");
    try std.testing.expect(cli.envValue(&env, "MICROAGENT_MODEL") == null);

    // A value that is there is the value, and a wrapper that wants "no model"
    // has --model to say so with.
    try env.put("MICROAGENT_MODEL", "gpt-5");
    try std.testing.expectEqualStrings("gpt-5", cli.envValue(&env, "MICROAGENT_MODEL").?);

    // A wrapper that populates the environment from a file leaves the newline
    // that file ended with, and each option fails differently on it: an api
    // key becomes a header carrying a byte a header may not hold, a base url
    // stops parsing and the run claims the key would go out in the clear.
    try env.put("MICROAGENT_MODEL", " gpt-5\n");
    try std.testing.expectEqualStrings("gpt-5", cli.envValue(&env, "MICROAGENT_MODEL").?);
    try env.put("MICROAGENT_BASE_URL", "\thttps://example.test/v1\r\n");
    try std.testing.expectEqualStrings("https://example.test/v1", cli.envValue(&env, "MICROAGENT_BASE_URL").?);

    // Whitespace alone is the empty case, not a value.
    try env.put("MICROAGENT_MODEL", " \t\r\n");
    try std.testing.expect(cli.envValue(&env, "MICROAGENT_MODEL") == null);
}

test "a style config that cannot be read is reported, a missing one is not" {
    // The default path is absent on most machines and that is not a fault, but
    // a file that is there and is a directory, is unreadable, or is over the
    // cap is: running on the built-in levels with nothing said is the silent
    // misconfiguration, and only absence is the normal case.
    try std.testing.expect(!configReadWorthReporting(false, error.FileNotFound));
    try std.testing.expect(configReadWorthReporting(true, error.FileNotFound));
    try std.testing.expect(configReadWorthReporting(false, error.IsDir));
    try std.testing.expect(configReadWorthReporting(false, error.AccessDenied));
    try std.testing.expect(configReadWorthReporting(false, error.StreamTooLong));
}

test "the trace switch is on only for a value that says so" {
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();

    try std.testing.expect(!debugEnabled(&env));
    try env.put("MDEBUG", "");
    try std.testing.expect(!debugEnabled(&env));
    try env.put("MDEBUG", "0");
    try std.testing.expect(!debugEnabled(&env));
    try env.put("MDEBUG", "false");
    try std.testing.expect(!debugEnabled(&env));
    try env.put("MDEBUG", "1");
    try std.testing.expect(debugEnabled(&env));
    try env.put("MDEBUG", "on");
    try std.testing.expect(debugEnabled(&env));
}

test "the style config path follows flag, then variable, then home" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();

    // A flag names the file outright, and it wins over the variable below it.
    try env.put("MICROAGENT_CONFIG", "/from/env.toml");
    try env.put("HOME", "/home/one");
    try std.testing.expectEqualStrings("/from/flag.toml", styleConfigPath(&env, arena, "/from/flag.toml").path.?);
    try std.testing.expect(styleConfigPath(&env, arena, "/from/flag.toml").named);

    // The variable is next, and the flag does not name one when it is absent.
    try std.testing.expectEqualStrings("/from/env.toml", styleConfigPath(&env, arena, "").path.?);
    try std.testing.expect(styleConfigPath(&env, arena, "").named);

    // An empty variable is the documented way to turn the file off, and the
    // home below it must not answer it.
    try env.put("MICROAGENT_CONFIG", "");
    try std.testing.expect(styleConfigPath(&env, arena, "").path == null);

    // A path exported from a file carries that file's newline, and a path with
    // one is a file nothing holds: the run would report on a config the caller
    // never wrote and fall back to the built-in levels.
    try env.put("MICROAGENT_CONFIG", "/from/env.toml\n");
    try std.testing.expectEqualStrings("/from/env.toml", styleConfigPath(&env, arena, "").path.?);

    // Whitespace alone is the empty case: the file is off, as it is for "".
    try env.put("MICROAGENT_CONFIG", "  \n");
    try std.testing.expect(styleConfigPath(&env, arena, "").path == null);

    // With neither, the home is where the file is looked for, and it is not
    // something the caller named, so its absence stays quiet.
    var home_only: std.process.Environ.Map = .init(std.testing.allocator);
    defer home_only.deinit();
    try home_only.put("HOME", "/home/one");
    const home = styleConfigPath(&home_only, arena, "");
    try std.testing.expect(std.mem.endsWith(u8, home.path.?, "/home/one/.microagent/config.toml"));
    try std.testing.expect(!home.named);

    // No home at all is no file.
    var bare: std.process.Environ.Map = .init(std.testing.allocator);
    defer bare.deinit();
    try std.testing.expect(styleConfigPath(&bare, arena, "").path == null);
}
