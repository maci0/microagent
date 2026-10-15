//! Drives the microagent binary. The unit tests cannot supply a real argv to
//! `main`, so this is the check that schema, `-o json`, and a JSON-mode failure
//! go through the entry point.

const std = @import("std");

pub fn main(minimal: std.process.Init.Minimal) !void {
    const gpa = std.heap.smp_allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var threaded: std.Io.Threaded = .init(gpa, .{
        .argv0 = .init(minimal.args),
        .environ = minimal.environ,
    });
    defer threaded.deinit();
    const io = threaded.io();

    var it = minimal.args.iterate();
    _ = it.next();
    const bin = it.next() orelse {
        std.debug.print("clispec_check: missing microagent path\n", .{});
        return error.MissingBinary;
    };

    var env: std.process.Environ.Map = .init(arena);
    try env.put("PATH", "/usr/bin:/bin");

    const schema = try run(gpa, io, bin, &.{"schema"}, &env);
    try expectExit(schema, 0);
    const root = try parseObject(arena, schema.stdout);
    try expectStr(root, "clispec", "0.3");
    try expectStr(root, "name", "microagent");
    const version = try fieldStr(root, "version");
    const output = try fieldObj(root, "output");
    try expectStr(output, "tty", "text");
    try expectStr(output, "piped", "text");
    try expectOutputArg(root);
    const commands = try fieldArr(root, "commands");
    if (commands.items.len == 0) return error.EmptyCommands;
    try expectErrors(root);

    const filtered = try run(gpa, io, bin, &.{ "schema", "update" }, &env);
    try expectExit(filtered, 0);
    const one = try parseObject(arena, filtered.stdout);
    const one_cmds = try fieldArr(one, "commands");
    if (one_cmds.items.len != 1) return error.FilterMissed;
    const update_cmd = switch (one_cmds.items[0]) {
        .object => |o| o,
        else => return error.NotObject,
    };
    try expectStr(update_cmd, "name", "update");

    const missing = try run(gpa, io, bin, &.{ "schema", "nope" }, &env);
    try expectExit(missing, 2);
    if (startsJson(lastLine(missing.stderr))) return error.TextModeWasJson;

    const version_text = try run(gpa, io, bin, &.{ "-o", "text", "--version" }, &env);
    try expectExit(version_text, 0);
    const want = try std.fmt.allocPrint(arena, "microagent {s}\n", .{version});
    if (!std.mem.eql(u8, version_text.stdout, want)) return error.TextVersion;
    if (startsJson(version_text.stdout)) return error.TextModeWasJson;

    const version_json = try run(gpa, io, bin, &.{ "--output=json", "--version" }, &env);
    try expectExit(version_json, 0);
    const ver = try parseObject(arena, version_json.stdout);
    try expectStr(ver, "name", "microagent");
    try expectStr(ver, "version", version);
    if (ver.get("items") != null) return error.VersionWasCollection;

    const bad = try run(gpa, io, bin, &.{ "-o", "json", "--nope" }, &env);
    try expectExit(bad, 2);
    const envelope = try parseObject(arena, lastLine(bad.stderr));
    const err_obj = try fieldObj(envelope, "error");
    try expectStr(err_obj, "kind", "usage");
    const message = try fieldStr(err_obj, "message");
    if (message.len == 0) return error.EmptyMessage;
}

fn run(
    gpa: std.mem.Allocator,
    io: std.Io,
    bin: []const u8,
    args: []const []const u8,
    env: *const std.process.Environ.Map,
) !std.process.RunResult {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(gpa, bin);
    try argv.appendSlice(gpa, args);
    defer argv.deinit(gpa);
    return std.process.run(gpa, io, .{
        .argv = argv.items,
        .environ_map = env,
    });
}

fn expectExit(result: std.process.RunResult, code: u8) !void {
    if (result.term != .exited or result.term.exited != code) {
        std.debug.print("exit {any}, want {d}\nstdout: {s}\nstderr: {s}\n", .{ result.term, code, result.stdout, result.stderr });
        return error.Exit;
    }
}

fn parseObject(arena: std.mem.Allocator, bytes: []const u8) !std.json.ObjectMap {
    const value = std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{}) catch return error.NotJson;
    return switch (value) {
        .object => |o| o,
        else => error.NotObject,
    };
}

fn fieldStr(obj: std.json.ObjectMap, name: []const u8) ![]const u8 {
    return switch (obj.get(name) orelse return error.MissingField) {
        .string => |s| s,
        else => error.NotString,
    };
}

fn expectStr(obj: std.json.ObjectMap, name: []const u8, want: []const u8) !void {
    const got = try fieldStr(obj, name);
    if (!std.mem.eql(u8, got, want)) return error.Field;
}

fn fieldObj(obj: std.json.ObjectMap, name: []const u8) !std.json.ObjectMap {
    return switch (obj.get(name) orelse return error.MissingField) {
        .object => |o| o,
        else => error.NotObject,
    };
}

fn fieldArr(obj: std.json.ObjectMap, name: []const u8) !std.json.Array {
    return switch (obj.get(name) orelse return error.MissingField) {
        .array => |a| a,
        else => error.NotArray,
    };
}

fn expectOutputArg(root: std.json.ObjectMap) !void {
    const args = try fieldArr(root, "global_args");
    for (args.items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const name = fieldStr(obj, "name") catch continue;
        if (!std.mem.eql(u8, name, "--output")) continue;
        try expectStr(obj, "default", "auto");
        const values = try fieldArr(obj, "enum");
        var saw_json = false;
        for (values.items) |value| {
            if (value == .string and std.mem.eql(u8, value.string, "json")) saw_json = true;
        }
        if (!saw_json) return error.OutputEnum;
        return;
    }
    return error.MissingOutput;
}

fn expectErrors(root: std.json.ObjectMap) !void {
    const errs = try fieldArr(root, "errors");
    var usage = false;
    var failure = false;
    for (errs.items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => return error.NotObject,
        };
        const kind = try fieldStr(obj, "kind");
        const code = switch (obj.get("exit_code") orelse return error.MissingField) {
            .integer => |n| n,
            else => return error.NotInteger,
        };
        if (std.mem.eql(u8, kind, "usage")) {
            usage = true;
            if (code != 2) return error.UsageCode;
        }
        if (std.mem.eql(u8, kind, "failure")) {
            failure = true;
            if (code != 1) return error.FailureCode;
        }
    }
    if (!usage or !failure) return error.MissingKind;
}

fn lastLine(s: []const u8) []const u8 {
    var t = s;
    while (t.len > 0 and (t[t.len - 1] == '\n' or t[t.len - 1] == '\r')) t = t[0 .. t.len - 1];
    if (std.mem.lastIndexOfScalar(u8, t, '\n')) |i| return t[i + 1 ..];
    return t;
}

fn startsJson(s: []const u8) bool {
    return s.len > 0 and s[0] == '{';
}
