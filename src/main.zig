//! microagent: a tiny OpenAI-compatible coding agent, sized for gauntlet loops.
//!
//! One binary, one loop: stream a chat completion, run whatever tools it asks
//! for, feed the results back, stop when it stops calling tools. Tool work is
//! delegated to the real tools on PATH (ripgrep, ast-grep, git, compilers) --
//! there is no built-in search or patch engine to keep in sync with them.

const std = @import("std");
const Io = std.Io;

const build_options = @import("build_options");
const net = @import("net.zig");
const style_mod = @import("style.zig");
const update_mod = @import("update.zig");

const version = build_options.version;

const default_base_url = "https://openrouter.ai/api/v1";
const default_model = "deepseek/deepseek-v4-flash";
const max_tool_output = 24 * 1024;
/// Above this many bytes of conversation, the oldest tool results are replaced
/// with a marker. Every turn re-sends the whole conversation, so without this a
/// long run pays for every file it has ever read, forever: one Terminal-Bench
/// task reached 1.7M cumulative input tokens that way.
const conversation_soft_limit = 400 * 1024;
const max_turns_default = 100;
/// Parallel tool calls accepted from one response; higher indices are dropped.
const max_tool_calls = 64;
/// The reply-style config is a handful of keys; a bigger file is not one.
const max_config_bytes: usize = 64 * 1024;

const system_prompt =
    "You are microagent, a coding agent working on the repository in the current directory.\n" ++
    "Work in this order: (1) find the relevant code with the `search` tool (ripgrep) and find the " ++
    "tests that cover it; (2) reproduce the failure with `bash` before changing anything, so you " ++
    "know what you are fixing; (3) make the smallest correct change - `edit` for a precise text " ++
    "change, `ast` (ast-grep) when the change is structural; (4) re-run the failing test and any " ++
    "test you touched; (5) check `git diff` and stop with a short summary.\n" ++
    "Prefer these deterministic tools over shelling out: `search` for text, `ast` for syntax, " ++
    "`read` for files, `git` for status/diff/log/show/blame. Use `bash` for running tests, builds " ++
    "and anything the other tools do not cover. Never invent APIs: read the definition first. " ++
    "Do not audit unrelated code and do not read library or standard-library sources to answer a " ++
    "question about this repository. Do not ask questions.";

const tools_json =
    \\[
    \\{"type":"function","function":{"name":"bash","description":"Run a shell command in the working directory. Use for builds, tests, git, ripgrep, ast-grep.","parameters":{"type":"object","properties":{"command":{"type":"string","description":"Shell command"},"timeout_ms":{"type":"integer","description":"Timeout in milliseconds, default 120000"}},"required":["command"]}}},
    \\{"type":"function","function":{"name":"read","description":"Read a file as text.","parameters":{"type":"object","properties":{"path":{"type":"string"},"offset":{"type":"integer","description":"1-based first line"},"limit":{"type":"integer","description":"Max lines"}},"required":["path"]}}},
    \\{"type":"function","function":{"name":"write","description":"Create or overwrite a file. Parent directories are created.","parameters":{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"}},"required":["path","content"]}}},
    \\{"type":"function","function":{"name":"edit","description":"Replace an exact string in a file. old_string must occur exactly once unless replace_all is true.","parameters":{"type":"object","properties":{"path":{"type":"string"},"old_string":{"type":"string"},"new_string":{"type":"string"},"replace_all":{"type":"boolean"}},"required":["path","old_string","new_string"]}}},
    \\{"type":"function","function":{"name":"search","description":"Search file contents with ripgrep. Returns file:line:text matches.","parameters":{"type":"object","properties":{"pattern":{"type":"string","description":"Regular expression"},"path":{"type":"string","description":"Directory or file, default ."},"glob":{"type":"string","description":"Glob filter, e.g. *.zig"}},"required":["pattern"]}}},
    \\{"type":"function","function":{"name":"ast","description":"Structural search or rewrite with ast-grep, matched on syntax rather than text. Set rewrite to apply the change to every match.","parameters":{"type":"object","properties":{"pattern":{"type":"string","description":"ast-grep pattern with metavariables, e.g. $A == $A"},"lang":{"type":"string","description":"Language, e.g. python, javascript, go, rust"},"path":{"type":"string","description":"Directory or file, default ."},"rewrite":{"type":"string","description":"Replacement pattern; when set the matches are rewritten in place"}},"required":["pattern","lang"]}}},
    \\{"type":"function","function":{"name":"git","description":"Read repository state with git: status, diff, log, show, blame. Use this instead of running git through bash.","parameters":{"type":"object","properties":{"cmd":{"type":"string","enum":["status","diff","log","show","blame"],"description":"What to read"},"path":{"type":"string","description":"File or directory to scope to"},"rev":{"type":"string","description":"Revision for show/blame, e.g. HEAD~3"},"limit":{"type":"integer","description":"Max output lines, default 400"}},"required":["cmd"]}}}
    \\]
;

const Options = struct {
    prompt: []const u8 = "",
    model: []const u8 = default_model,
    base_url: []const u8 = default_base_url,
    api_key: []const u8 = "",
    max_turns: usize = max_turns_default,
    /// Passed to the provider as `reasoning.effort`. Unset by default: on a
    /// reasoning model the thinking is usually most of the output tokens, and
    /// in a gauntlet loop with a per-review timeout that is the difference
    /// between finishing a review and being killed at the ceiling.
    reasoning_effort: ?[]const u8 = null,
    /// Stop starting turns once this much time has passed on the monotonic
    /// clock, so a run ends deliberately inside a caller's per-review timeout
    /// instead of being killed in the middle of one. A clock step inside the
    /// run does not consume budget.
    budget_s: ?u64 = null,
    /// PEM file to trust instead of scanning the system store. Set by
    /// --ca-bundle, MICROAGENT_CA_BUNDLE or SSL_CERT_FILE.
    ca_bundle: []const u8 = "",
    /// Directory the session log is written to, one JSONL record per model
    /// response, so a monitor (toktop) can read this run's tokens per second
    /// while it is still going. Set by MICROAGENT_SESSION_DIR, else
    /// $HOME/.microagent/sessions; an empty value writes nothing.
    session_dir: []const u8 = "",
};

const ToolCall = struct {
    id: []u8,
    name: []u8,
    args: []u8,
};

/// Token counters as gauntlet wants to read them: cumulative for the run, so
/// the max it takes from successive usage lines is the final total.
const Usage = struct {
    prompt: u64 = 0,
    completion: u64 = 0,
    reasoning: u64 = 0,
    total: u64 = 0,
    /// Of `prompt`, the part the provider served from its prompt cache. Every
    /// turn re-sends the whole conversation, so this is the counter that says
    /// whether the prefix is still being reused: a prompt-sized `prompt_tokens`
    /// with `cached_tokens` near it is a hit, and near-zero is a full re-read.
    cached: u64 = 0,

    /// Adds one response's counters. Saturating, because a provider number
    /// beyond u64 saturates on the way in (`num`) and a second one in the same
    /// run would otherwise overflow the run total and trap a checked build.
    fn add(self: *Usage, result: *const ChatResult) void {
        self.prompt +|= result.prompt_tokens;
        self.cached +|= result.cached_tokens;
        self.completion +|= result.completion_tokens;
        self.reasoning +|= result.reasoning_tokens;
        self.total +|= result.total_tokens;
    }
};

const ChatResult = struct {
    content: std.ArrayList(u8) = .empty,
    calls: std.ArrayList(ToolCall) = .empty,
    prompt_tokens: u64 = 0,
    completion_tokens: u64 = 0,
    reasoning_tokens: u64 = 0,
    total_tokens: u64 = 0,
    cached_tokens: u64 = 0,
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(gpa);
    var it = init.minimal.args.iterate();
    while (it.next()) |arg| try args.append(gpa, arg);

    debug_enabled = init.environ_map.get("MDEBUG") != null;

    // `microagent update` is a subcommand, not a prompt: it is dispatched
    // before the agent's own flags so it never needs an API key.
    if (args.items.len > 1 and std.mem.eql(u8, args.items[1], "update")) {
        std.process.exit(update_mod.run(io, gpa, init.arena.allocator(), init.environ_map, args.items[2..]));
    }

    var opts: Options = .{};
    if (init.environ_map.get("MICROAGENT_MODEL")) |v| opts.model = v;
    if (init.environ_map.get("MICROAGENT_BASE_URL")) |v| opts.base_url = v;
    if (init.environ_map.get("MICROAGENT_REASONING_EFFORT")) |v| opts.reasoning_effort = v;
    opts.ca_bundle = net.caBundlePath(init.environ_map);
    if (init.environ_map.get("MICROAGENT_BUDGET_SECONDS")) |v|
        opts.budget_s = std.fmt.parseInt(u64, v, 10) catch return usageError(io, "MICROAGENT_BUDGET_SECONDS must be a number");
    opts.session_dir = sessionDir(init);

    var i: usize = 1;
    while (i < args.items.len) : (i += 1) {
        const arg = args.items[i];
        if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--print")) {
            i += 1;
            if (i >= args.items.len) return usageError(io, "missing prompt");
            opts.prompt = args.items[i];
        } else if (std.mem.eql(u8, arg, "-m") or std.mem.eql(u8, arg, "--model")) {
            i += 1;
            if (i >= args.items.len) return usageError(io, "missing model");
            opts.model = args.items[i];
        } else if (std.mem.eql(u8, arg, "-b") or std.mem.eql(u8, arg, "--base-url")) {
            i += 1;
            if (i >= args.items.len) return usageError(io, "missing base url");
            opts.base_url = args.items[i];
        } else if (std.mem.eql(u8, arg, "-k") or std.mem.eql(u8, arg, "--api-key")) {
            i += 1;
            if (i >= args.items.len) return usageError(io, "missing api key");
            opts.api_key = args.items[i];
        } else if (std.mem.eql(u8, arg, "--ca-bundle")) {
            i += 1;
            if (i >= args.items.len) return usageError(io, "missing ca bundle path");
            opts.ca_bundle = args.items[i];
        } else if (std.mem.eql(u8, arg, "--budget")) {
            i += 1;
            if (i >= args.items.len) return usageError(io, "missing budget in seconds");
            opts.budget_s = std.fmt.parseInt(u64, args.items[i], 10) catch
                return usageError(io, "budget must be a number of seconds");
        } else if (std.mem.eql(u8, arg, "--reasoning-effort")) {
            i += 1;
            if (i >= args.items.len) return usageError(io, "missing reasoning effort");
            opts.reasoning_effort = args.items[i];
        } else if (std.mem.eql(u8, arg, "--max-turns")) {
            i += 1;
            if (i >= args.items.len) return usageError(io, "missing max turns");
            opts.max_turns = std.fmt.parseInt(usize, args.items[i], 10) catch
                return usageError(io, "max turns must be a number");
        } else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-V")) {
            std.Io.File.stdout().writeStreamingAll(io, "microagent " ++ version ++ "\n") catch {};
            return;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            std.Io.File.stdout().writeStreamingAll(io, help_text) catch {};
            return;
        } else {
            if (arg.len > 0 and arg[0] != '-') {
                // A bare argument is the prompt. gauntlet's custom-agent
                // definitions insert the model flags before the prompt, so
                // "microagent -p {prompt}" would hand the model flag to -p;
                // taking the prompt positionally makes the order irrelevant.
                if (opts.prompt.len != 0) return usageError(io, arg);
                opts.prompt = arg;
                continue;
            }
            return usageError(io, arg);
        }
    }

    if (opts.prompt.len == 0) {
        std.Io.File.stderr().writeStreamingAll(io, help_text) catch {};
        std.process.exit(2);
    }
    opts.api_key = resolveKey(init, opts.api_key);
    if (opts.api_key.len == 0)
        return usageError(io, "no API key: pass --api-key or set MICROAGENT_API_KEY / OPENAI_API_KEY");

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    net.loadCaBundle(&client, io, gpa, opts.ca_bundle, init.arena.allocator());

    // The conversation is kept as the literal JSON array the API wants, so a
    // message is appended once, in the wire format, with no model in between.
    var msgs: std.ArrayList(u8) = .empty;
    defer msgs.deinit(gpa);
    try msgs.appendSlice(gpa, "[");
    const style = loadStyle(io, init, init.arena.allocator());
    const reply_style = try style.ruleset(init.arena.allocator());
    const prompt = if (reply_style.len == 0)
        system_prompt
    else
        try std.fmt.allocPrint(init.arena.allocator(), "{s}\n\n{s}", .{ system_prompt, reply_style });
    try appendMessage(gpa, &msgs, "system", prompt);
    try appendMessage(gpa, &msgs, "user", opts.prompt);

    const reason = run(&client, io, gpa, init.arena.allocator(), opts, &msgs) catch |err| {
        const msg = try std.fmt.allocPrint(init.arena.allocator(), "microagent: {s}\n", .{@errorName(err)});
        std.Io.File.stderr().writeStreamingAll(io, msg) catch {};
        std.process.exit(1);
    };
    _ = reason;
}

/// Injected when the wall-clock budget runs out: the model has done its
/// reading, so it is asked for the edit rather than another investigation.
const final_push =
    "Your budget is exhausted. Apply the single most important fix now, using what you already " ++
    "know, with one edit or one write. Do not search again. Then stop.";

const help_text =
    \\microagent - tiny OpenAI-compatible coding agent
    \\
    \\usage: microagent -p "<prompt>" [options]
    \\
    \\  -p, --print <prompt>   task to run (also accepted as a bare argument)
    \\  -m, --model <model>    model id (env MICROAGENT_MODEL)
    \\  -b, --base-url <url>   OpenAI-compatible base url (env MICROAGENT_BASE_URL)
    \\  -k, --api-key <key>    api key (env MICROAGENT_API_KEY, OPENAI_API_KEY, OPENROUTER_API_KEY)
    \\      --max-turns <n>    tool-loop turn ceiling (default 100)
    \\      --ca-bundle <file>
    \\                         PEM file to trust instead of the system store
    \\                         (env MICROAGENT_CA_BUNDLE, SSL_CERT_FILE). Needed in
    \\                         images that ship no ca-certificates.
    \\      --budget <seconds>
    \\                         stop starting turns after this long, and say so
    \\                         (env MICROAGENT_BUDGET_SECONDS)
    \\      --reasoning-effort <level>
    \\                         reasoning.effort sent to the provider: minimal, low,
    \\                         medium, high, or none to disable (env MICROAGENT_REASONING_EFFORT)
    \\  -h, --help             this text
    \\  -V, --version          version
    \\
    \\reply style (env, or the TOML config at MICROAGENT_CONFIG, default
    \\~/.microagent/config.toml with the keys "caveman" and "ponytail"):
    \\  MICROAGENT_CAVEMAN     how terse the reply is: off, lite, full, ultra,
    \\                         wenyan-lite, wenyan-full, wenyan-ultra
    \\                         (default ultra)
    \\  MICROAGENT_PONYTAIL    how lazy the code is: off, lite, full, ultra
    \\                         (default full)
    \\
    \\subcommand:
    \\  update [--check] [--repo owner/name]
    \\                         replace this binary with the latest GitHub
    \\                         release after verifying its .sha256 sidecar
    \\                         (--check only reports; GITHUB_TOKEN lifts the
    \\                         API rate limit)
    \\
;

fn usageError(io: Io, arg: []const u8) noreturn {
    const msg = std.fmt.allocPrint(std.heap.page_allocator, "microagent: unknown or incomplete argument '{s}'\n", .{arg}) catch
        "microagent: bad arguments\n";
    std.Io.File.stderr().writeStreamingAll(io, msg) catch {};
    std.Io.File.stderr().writeStreamingAll(io, help_text) catch {};
    std.process.exit(2);
}

fn resolveKey(init: std.process.Init, given: []const u8) []const u8 {
    if (given.len > 0) return given;
    const names = [_][]const u8{ "MICROAGENT_API_KEY", "OPENAI_API_KEY", "OPENROUTER_API_KEY", "DEEPSEEK_API_KEY" };
    for (names) |n| {
        if (init.environ_map.get(n)) |v| if (v.len > 0) return v;
    }
    if (readSecret(init, "openrouter")) |v| return v;
    return "";
}

fn readSecret(init: std.process.Init, name: []const u8) ?[]const u8 {
    const home = init.environ_map.get("HOME") orelse return null;
    const path = std.fmt.allocPrint(init.arena.allocator(), "{s}/.secrets/{s}", .{ home, name }) catch return null;
    const raw = std.Io.Dir.cwd().readFileAlloc(init.io, path, init.arena.allocator(), .limited(4096)) catch return null;
    return std.mem.trim(u8, raw, " \t\r\n");
}

/// The reply-style levels for this run, from the TOML config at
/// MICROAGENT_CONFIG or `$HOME/.microagent/config.toml`, then the
/// MICROAGENT_CAVEMAN / MICROAGENT_PONYTAIL overrides, then the built-in
/// defaults. A missing file, an unreadable one, or an unknown key costs the run
/// nothing: the levels that were understood still apply.
fn loadStyle(io: Io, init: std.process.Init, arena: std.mem.Allocator) style_mod.Style {
    var style: style_mod.Style = .{};
    const path = styleConfigPath(init, arena);
    const text: ?[]const u8 = if (path) |p|
        std.Io.Dir.cwd().readFileAlloc(io, p, arena, .limited(max_config_bytes)) catch null
    else
        null;
    if (resolveStyle(&style, text, init.environ_map.get("MICROAGENT_CAVEMAN"), init.environ_map.get("MICROAGENT_PONYTAIL"))) |unknown| {
        if (unknown.from_config)
            net.note(io, arena, "microagent: config {s}: '{s}' is not a level; keeping the default\n", .{ path.?, unknown.key })
        else
            net.note(io, arena, "microagent: {s} is not a level; keeping the default\n", .{unknown.key});
    }
    return style;
}

/// Where the style config is read from. An empty MICROAGENT_CONFIG turns the
/// file off, as does a home that is not there.
fn styleConfigPath(init: std.process.Init, arena: std.mem.Allocator) ?[]const u8 {
    if (init.environ_map.get("MICROAGENT_CONFIG")) |path| {
        if (path.len == 0) return null;
        return std.fs.path.resolve(arena, &.{path}) catch path;
    }
    const home = init.environ_map.get("HOME") orelse return null;
    const path = std.fmt.allocPrint(arena, "{s}/.microagent/config.toml", .{home}) catch return null;
    return std.fs.path.resolve(arena, &.{path}) catch path;
}

/// A level named by a key or a variable that the parser does not have, so the
/// caller can say so on stderr and keep what it understood.
const UnknownLevel = struct {
    key: []const u8,
    /// The value came from the config file, so the message can name the file.
    from_config: bool,
};

/// The levels, in the order the doc comment names: the config file, then the
/// environment overrides, over the built-in defaults. The first value that is
/// not a level is returned and the levels understood so far stand.
fn resolveStyle(
    style: *style_mod.Style,
    config: ?[]const u8,
    caveman_env: ?[]const u8,
    ponytail_env: ?[]const u8,
) ?UnknownLevel {
    if (config) |text| {
        if (style.applyToml(text)) |key| return .{ .key = key, .from_config = true };
    }
    if (caveman_env) |v| {
        if (style_mod.parseCaveman(v)) |level| style.caveman = level else return .{ .key = "MICROAGENT_CAVEMAN", .from_config = false };
    }
    if (ponytail_env) |v| {
        if (style_mod.parsePonytail(v)) |level| style.ponytail = level else return .{ .key = "MICROAGENT_PONYTAIL", .from_config = false };
    }
    return null;
}

/// The agent loop. Returns the number of chat completions made.
fn run(
    client: *std.http.Client,
    io: Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    opts: Options,
    msgs: *std.ArrayList(u8),
) !usize {
    const started = Io.Timestamp.now(io, .awake).nanoseconds;
    const session = openSession(io, gpa, arena, opts);
    defer closeSession(io, session);
    var turn: usize = 0;
    var usage: Usage = .{};
    while (turn < opts.max_turns) : (turn += 1) {
        if (opts.budget_s) |budget| {
            const spent_s = @divTrunc(Io.Timestamp.now(io, .awake).nanoseconds - started, std.time.ns_per_s);
            if (spent_s >= budget) {
                // Stop in the middle of the work, or stop after one last push
                // that is told to edit? A review that ran out of time with
                // nothing changed is worth less than one that ran out of time
                // with a small diff, and the model has already done the reading.
                net.note(io, arena, "microagent: budget of {d}s reached after {d} turn(s); one final turn\n", .{ budget, turn });
                try appendMessage(gpa, msgs, "user", final_push);
                const body = try buildBody(arena, opts, msgs.items);
                const asked = Io.Timestamp.now(io, .awake).nanoseconds;
                var result = try streamChat(client, io, arena, opts, body);
                try finishTurn(io, arena, gpa, msgs, &result, &usage);
                writeSessionRecord(io, arena, session, elapsedMs(io, asked), &result);
                return turn + 1;
            }
        }
        try compactMessages(gpa, msgs, arena);
        const body = try buildBody(arena, opts, msgs.items);
        const asked = Io.Timestamp.now(io, .awake).nanoseconds;
        var result = try streamChat(client, io, arena, opts, body);
        try finishTurn(io, arena, gpa, msgs, &result, &usage);
        writeSessionRecord(io, arena, session, elapsedMs(io, asked), &result);
        if (result.calls.items.len == 0) return turn + 1;

        // One turn left: say so, rather than ending on a truncated answer that
        // reads like a finished one.
        if (turn + 1 == opts.max_turns - 1)
            net.note(io, arena, "microagent: last turn (--max-turns {d})\n", .{opts.max_turns});
    }
    net.note(io, arena, "microagent: stopped at the --max-turns ceiling ({d})\n", .{opts.max_turns});
    return turn;
}

/// Where the session log goes: MICROAGENT_SESSION_DIR, else a directory beside
/// the other per-run state under $HOME. An empty value turns the log off, and
/// so does a home that is not there.
fn sessionDir(init: std.process.Init) []const u8 {
    if (init.environ_map.get("MICROAGENT_SESSION_DIR")) |v| return v;
    const home = init.environ_map.get("HOME") orelse return "";
    return std.fmt.allocPrint(init.arena.allocator(), "{s}/.microagent/sessions", .{home}) catch "";
}

/// One session log per run, one JSONL record per model response, which is what
/// a monitor (toktop) reads to report this run's tokens per second while it is
/// still going. Nothing depends on it, so every failure here is a null rather
/// than an error: a read-only home costs a run nothing.
const Session = struct {
    file: Io.File,
    cwd: []const u8,
    model: []const u8,
};

fn openSession(io: Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, opts: Options) ?Session {
    if (opts.session_dir.len == 0) return null;
    // Every record names the directory it ran in. That is what attributes the
    // record to one review: the store is machine-wide, and a monitor skips a
    // record that names no directory rather than billing it to whichever
    // watcher happens to read the store.
    const cwd = std.Io.Dir.cwd().realPathFileAlloc(io, ".", gpa) catch return null;
    std.Io.Dir.cwd().createDirPath(io, opts.session_dir) catch return null;
    const stamp = Io.Clock.real.now(io).nanoseconds;
    const path = std.fmt.allocPrint(arena, "{s}/{d}.jsonl", .{ opts.session_dir, stamp }) catch return null;
    const file = std.Io.Dir.createFileAbsolute(io, path, .{}) catch return null;
    return .{ .file = file, .cwd = cwd, .model = opts.model };
}

fn closeSession(io: Io, session: ?Session) void {
    if (session) |s| s.file.close(io);
}

/// How long the model spent on one response. It travels in the record because
/// a monitor's polling gap covers the tools as well: dividing a turn's tokens
/// by that gap reports a rate for a generation that was never continuous.
fn elapsedMs(io: Io, since: i96) u64 {
    const delta = Io.Timestamp.now(io, .awake).nanoseconds - since;
    if (delta <= 0) return 0;
    return @intCast(@divTrunc(delta, std.time.ns_per_ms));
}

fn writeSessionRecord(io: Io, arena: std.mem.Allocator, session: ?Session, elapsed_ms: u64, result: *const ChatResult) void {
    const s = session orelse return;
    const ts_ms: i64 = @intCast(@divTrunc(Io.Clock.real.now(io).nanoseconds, std.time.ns_per_ms));
    const line = sessionRecord(arena, ts_ms, s.cwd, s.model, elapsed_ms, result) catch return;
    s.file.writeStreamingAll(io, line) catch {};
}

/// One response's line: this response's own counters, not the run's cumulative
/// ones, so a reader sums them; the directory it ran in; and the model time it
/// took. The keys are the OpenAI-shaped ones toktop already reads by name.
fn sessionRecord(
    allocator: std.mem.Allocator,
    ts_ms: i64,
    cwd: []const u8,
    model: []const u8,
    elapsed_ms: u64,
    result: *const ChatResult,
) ![]u8 {
    var jb = JsonBuf.init(allocator);
    const w = jb.writer();
    try w.print("{{\"ts\":{d},\"cwd\":", .{ts_ms});
    try writeJsonString(w, cwd);
    try w.writeAll(",\"model\":");
    try writeJsonString(w, model);
    try w.print(",\"elapsed_ms\":{d},\"usage\":{{\"prompt_tokens\":{d},\"cached_tokens\":{d},\"completion_tokens\":{d},\"reasoning_tokens\":{d},\"total_tokens\":{d}", .{
        elapsed_ms, result.prompt_tokens, result.cached_tokens, result.completion_tokens, result.reasoning_tokens, result.total_tokens,
    });
    try w.writeAll("}}\n");
    return jb.items();
}

fn buildBody(arena: std.mem.Allocator, opts: Options, messages: []const u8) ![]u8 {
    var jb = JsonBuf.init(arena);
    const w = jb.writer();
    try w.print("{{\"model\":", .{});
    try writeJsonString(w, opts.model);
    try w.writeAll(",\"messages\":");
    try w.writeAll(messages);
    try w.writeAll("],\"tools\":");
    try w.writeAll(tools_json);
    try w.writeAll(",\"stream\":true,\"stream_options\":{\"include_usage\":true}");
    if (opts.reasoning_effort) |effort| {
        if (std.mem.eql(u8, effort, "none")) {
            try w.writeAll(",\"reasoning\":{\"enabled\":false}");
        } else {
            try w.writeAll(",\"reasoning\":{\"effort\":");
            try writeJsonString(w, effort);
            try w.writeAll("}");
        }
    }
    try w.writeAll("}");
    return jb.items();
}

/// Streams one completion, printing visible text as it arrives and accumulating
/// tool calls and token counters. Text on stderr is tool activity; stdout is
/// the model's own output plus one JSON usage line per response.
fn streamChat(
    client: *std.http.Client,
    io: Io,
    arena: std.mem.Allocator,
    opts: Options,
    body: []const u8,
) !ChatResult {
    const url = try std.fmt.allocPrint(arena, "{s}/chat/completions", .{std.mem.trimEnd(u8, opts.base_url, "/")});
    const uri = std.Uri.parse(url) catch return error.InvalidUrl;
    const auth = try std.fmt.allocPrint(arena, "Bearer {s}", .{opts.api_key});

    // The request lives in a slot so `Response.request` stays valid for the
    // reader handed back out of the retry loop below.
    var req_slot: ?std.http.Client.Request = null;
    defer if (req_slot) |*r| r.deinit();

    var redirect_buffer: [8 * 1024]u8 = undefined;
    var transfer: [16 * 1024]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    var decompress_buffer: [std.compress.flate.max_window_len]u8 = undefined;

    var attempt: u32 = 0;
    // A rate limit or a dropped connection is the provider's weather, not the
    // review's verdict: retry here rather than making gauntlet redo the whole
    // review against a tree the agent has already partly changed.
    const reader = retry: while (true) {
        attempt += 1;
        if (req_slot) |*r| {
            r.deinit();
            req_slot = null;
        }
        const req = client.request(.POST, uri, .{
            .redirect_behavior = .unhandled,
            .extra_headers = &.{
                .{ .name = "authorization", .value = auth },
                .{ .name = "content-type", .value = "application/json" },
                .{ .name = "accept", .value = "text/event-stream" },
            },
        }) catch |err| {
            if (waitBeforeRetry(io, attempt, @errorName(err))) continue;
            return err;
        };
        req_slot = req;
        var open = &req_slot.?;
        open.transfer_encoding = .{ .content_length = body.len };
        open.sendBodyComplete(@constCast(body)) catch |err| {
            if (waitBeforeRetry(io, attempt, @errorName(err))) continue;
            return err;
        };
        if (debugOn()) std.debug.print("[mdebug] request sent, body={d} bytes\n", .{body.len});

        var response = open.receiveHead(&redirect_buffer) catch |err| {
            if (waitBeforeRetry(io, attempt, @errorName(err))) continue;
            return err;
        };
        if (debugOn()) std.debug.print("[mdebug] head status={d} enc={s}\n", .{ @intFromEnum(response.head.status), @tagName(response.head.content_encoding) });
        if (response.head.status != .ok) {
            if (retryableStatus(response.head.status) and attempt < max_attempts) {
                try waitFor(io, attempt);
                continue;
            }
            var err_transfer: [8 * 1024]u8 = undefined;
            const err_reader = response.reader(&err_transfer);
            const err_body = err_reader.allocRemaining(arena, .limited(16 * 1024)) catch "";
            const msg = try std.fmt.allocPrint(arena, "http {d}: {s}\n", .{ @intFromEnum(response.head.status), err_body });
            std.Io.File.stderr().writeStreamingAll(io, msg) catch {};
            return error.ApiError;
        }
        break :retry response.readerDecompressing(&transfer, &decompress, &decompress_buffer);
    };

    var result: ChatResult = .{};
    var calls: std.ArrayList(ToolCall) = .empty;

    // Frames are parsed in a scratch arena reset after each one, so a long
    // stream costs the size of its largest frame, not the sum of all of them.
    var frame_arena_state = std.heap.ArenaAllocator.init(arena);
    const frame_arena = frame_arena_state.allocator();

    // stdout is buffered per read chunk rather than written per token: one
    // write per chunk the provider sent. Tokens that arrived in the same chunk
    // are drawn in the same tick either way, so streaming latency is unchanged
    // while the syscall count per completion drops by orders of magnitude.
    var out_buf: std.ArrayList(u8) = .empty;

    // Chunked reads, split into lines here rather than with the reader's
    // delimiter helpers: those stall on a chunked body reader (they hand back
    // an endless run of empty lines instead of reading on).
    var pending: std.ArrayList(u8) = .empty;
    var chunk: [8 * 1024]u8 = undefined;
    var done = false;
    while (!done) {
        const n = reader.readSliceShort(&chunk) catch return error.StreamFailed;
        if (n == 0) break;
        try pending.appendSlice(arena, chunk[0..n]);

        var start: usize = 0;
        while (std.mem.indexOfScalarPos(u8, pending.items, start, '\n')) |pos| {
            const raw = pending.items[start..pos];
            start = pos + 1;
            const line = std.mem.trimEnd(u8, raw, "\r");
            if (!std.mem.startsWith(u8, line, "data:")) continue;
            const payload = std.mem.trim(u8, line[5..], " ");
            if (payload.len == 0) continue;
            if (std.mem.eql(u8, payload, "[DONE]")) {
                done = true;
                break;
            }
            try applyFrame(frame_arena, arena, payload, &result, &calls, &out_buf);
            _ = frame_arena_state.reset(.retain_capacity);
        }
        // Drop what was consumed, so a long stream does not keep every frame.
        if (start > 0) {
            const rest = pending.items.len - start;
            std.mem.copyForwards(u8, pending.items[0..rest], pending.items[start..]);
            pending.shrinkRetainingCapacity(rest);
        }
        flushOut(io, &out_buf);
    }

    if (result.content.items.len > 0) try out_buf.append(arena, '\n');
    flushOut(io, &out_buf);
    result.calls = calls;
    return result;
}

/// Folds one SSE payload into the response being built.
///
/// `scratch` is reset by the caller after every frame, so nothing parsed out of
/// it may survive: strings that do are copied into `arena`, which lives for the
/// whole run.
fn applyFrame(
    scratch: std.mem.Allocator,
    arena: std.mem.Allocator,
    payload: []const u8,
    result: *ChatResult,
    calls: *std.ArrayList(ToolCall),
    out_buf: *std.ArrayList(u8),
) !void {
    const parsed = std.json.parseFromSlice(std.json.Value, scratch, payload, .{}) catch return;
    const root = parsed.value;
    if (root != .object) return;

    if (root.object.get("usage")) |u| if (u == .object) {
        result.prompt_tokens = num(u.object.get("prompt_tokens"));
        result.completion_tokens = num(u.object.get("completion_tokens"));
        result.total_tokens = num(u.object.get("total_tokens"));
        if (u.object.get("completion_tokens_details")) |d| {
            if (d == .object) result.reasoning_tokens = num(d.object.get("reasoning_tokens"));
        }
        // Cached prompt tokens, in the three spellings providers actually send:
        // the OpenAI/OpenRouter one, DeepSeek's native one, and Anthropic's.
        if (u.object.get("prompt_tokens_details")) |d| {
            if (d == .object) result.cached_tokens = num(d.object.get("cached_tokens"));
        }
        if (result.cached_tokens == 0) result.cached_tokens = num(u.object.get("prompt_cache_hit_tokens"));
        if (result.cached_tokens == 0) result.cached_tokens = num(u.object.get("cache_read_input_tokens"));
    };
    const choices = root.object.get("choices") orelse return;
    if (choices != .array or choices.array.items.len == 0) return;
    const choice = choices.array.items[0];
    if (choice != .object) return;
    const delta = choice.object.get("delta") orelse return;
    if (delta != .object) return;

    if (str(delta.object.get("content"))) |text| {
        try result.content.appendSlice(arena, text);
        try out_buf.appendSlice(arena, text);
    }
    if (delta.object.get("tool_calls")) |tcs| if (tcs == .array) {
        for (tcs.array.items) |tc| {
            if (tc != .object) continue;
            const idx: usize = @intCast(num(tc.object.get("index")));
            // The index sizes `calls`, so a provider-sent index is capped
            // before it can ask for billions of empty slots.
            if (idx >= max_tool_calls) continue;
            while (calls.items.len <= idx) try calls.append(arena, .{
                .id = try arena.dupe(u8, ""),
                .name = try arena.dupe(u8, ""),
                .args = &.{},
            });
            var args_buf: std.ArrayList(u8) = .empty;
            try args_buf.appendSlice(arena, calls.items[idx].args);
            if (str(tc.object.get("id"))) |v| calls.items[idx].id = try arena.dupe(u8, v);
            if (tc.object.get("function")) |f| if (f == .object) {
                if (str(f.object.get("name"))) |v| calls.items[idx].name = try arena.dupe(u8, v);
                if (str(f.object.get("arguments"))) |v| try args_buf.appendSlice(arena, v);
            };
            calls.items[idx].args = args_buf.items;
        }
    };
}

/// Read-only git, with the subcommands fixed here rather than assembled by the
/// model. Deterministic, no shell quoting, and the output is capped: a raw
/// `git log` in a big repository is thousands of lines of context nobody reads.
fn toolGit(io: Io, arena: std.mem.Allocator, args: std.json.ObjectMap) ![]u8 {
    const cmd = str(args.get("cmd")) orelse return std.fmt.allocPrint(arena, "error: missing cmd", .{});
    const path = str(args.get("path"));
    const rev = str(args.get("rev"));
    const limit: usize = if (args.get("limit")) |v| @intCast(num(v)) else 400;
    // A rev such as `--output=FILE` would turn a read into a write.
    if (rev) |r| if (std.mem.startsWith(u8, r, "-"))
        return std.fmt.allocPrint(arena, "error: rev must not start with '-'", .{});

    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ "git", "--no-pager" });
    if (std.mem.eql(u8, cmd, "status")) {
        try argv.appendSlice(arena, &.{ "status", "--short", "--branch" });
    } else if (std.mem.eql(u8, cmd, "diff")) {
        try argv.appendSlice(arena, &.{ "diff", "--no-color" });
        if (rev) |r| try argv.append(arena, r);
    } else if (std.mem.eql(u8, cmd, "log")) {
        try argv.appendSlice(arena, &.{ "log", "--oneline", "--no-color", "-n", "30" });
    } else if (std.mem.eql(u8, cmd, "show")) {
        try argv.appendSlice(arena, &.{ "show", "--no-color", "--stat", "--patch" });
        try argv.append(arena, rev orelse "HEAD");
    } else if (std.mem.eql(u8, cmd, "blame")) {
        try argv.append(arena, "blame");
        if (rev) |r| try argv.append(arena, r);
    } else {
        return std.fmt.allocPrint(arena, "error: unknown git cmd '{s}'", .{cmd});
    }
    // `--` keeps a path from being read as an option.
    try argv.append(arena, "--");
    if (path) |p| try argv.append(arena, p);

    const res = std.process.run(arena, io, .{
        .argv = argv.items,
        .stdout_limit = .limited(max_tool_output * 4),
        .stderr_limit = .limited(4096),
        .timeout = durationMs(60_000),
    }) catch |err| return std.fmt.allocPrint(arena, "error: git {s} failed: {s}", .{ cmd, @errorName(err) });
    const text = if (res.stdout.len > 0) res.stdout else res.stderr;
    if (text.len == 0) return std.fmt.allocPrint(arena, "(git {s}: no output)", .{cmd});
    return firstLines(arena, text, limit);
}

/// The first `limit` lines, with a note when lines were dropped.
fn firstLines(arena: std.mem.Allocator, text: []const u8, limit: usize) ![]u8 {
    var lines: usize = 0;
    var end: usize = text.len;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] != '\n') continue;
        lines += 1;
        if (lines == limit) {
            end = i + 1;
            break;
        }
    }
    if (end == text.len) return arena.dupe(u8, text);
    return std.fmt.allocPrint(arena, "{s}... [output truncated at {d} lines]", .{ text[0..end], limit });
}

/// Replaces the content of the oldest large tool results with a marker once the
/// conversation outgrows `conversation_soft_limit`, down to half of it.
///
/// Tool results are surgical targets: the assistant messages and the task
/// instruction stay verbatim, so the agent keeps its plan and its recent
/// evidence while the pile of file dumps it already acted on stops being
/// re-sent every turn. Messages are never dropped, so `tool_call_id` pairing
/// stays valid.
fn compactMessages(gpa: std.mem.Allocator, msgs: *std.ArrayList(u8), scratch: std.mem.Allocator) !void {
    if (msgs.items.len <= conversation_soft_limit) return;

    var arena_state = std.heap.ArenaAllocator.init(scratch);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parsed = std.json.parseFromSlice(std.json.Value, arena, msgs.items, .{}) catch return;
    const array = switch (parsed.value) {
        .array => |a| a,
        else => return,
    };

    const target = conversation_soft_limit / 2;
    var size = msgs.items.len;
    for (array.items) |*message| {
        if (size <= target) break;
        const object = switch (message.*) {
            .object => |o| o,
            else => continue,
        };
        const role = str(object.get("role")) orelse continue;
        if (!std.mem.eql(u8, role, "tool")) continue;
        const content = object.getPtr("content") orelse continue;
        const text = switch (content.*) {
            .string => |t| t,
            else => continue,
        };
        if (text.len < 4096) continue;
        const marker = try std.fmt.allocPrint(arena, "[earlier tool output elided: {d} bytes]", .{text.len});
        size -= text.len - marker.len;
        content.* = .{ .string = marker };
    }
    if (size == msgs.items.len) return;

    var jb = JsonBuf.init(gpa);
    defer jb.list.deinit(gpa);
    try std.json.Stringify.value(parsed.value, .{}, jb.writer());
    msgs.clearRetainingCapacity();
    try msgs.appendSlice(gpa, jb.items());
}

/// Hands the buffered tokens to stdout. A failed write is ignored: a closed
/// pipe means the reader left, not that the run should be abandoned.
fn flushOut(io: Io, out_buf: *std.ArrayList(u8)) void {
    if (out_buf.items.len == 0) return;
    Io.File.stdout().writeStreamingAll(io, out_buf.items) catch {};
    out_buf.clearRetainingCapacity();
}

/// Appends the assistant message and, for every tool call it requested, runs
/// the tool and appends its result.
fn finishTurn(
    io: Io,
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    msgs: *std.ArrayList(u8),
    result: *ChatResult,
    usage: *Usage,
) !void {
    try msgs.appendSlice(gpa, ",");
    if (result.calls.items.len == 0) {
        try appendMessage(gpa, msgs, "assistant", result.content.items);
    } else {
        var msg = JsonBuf.init(arena);
        try msg.writer().writeAll("{\"role\":\"assistant\",\"content\":");
        if (result.content.items.len == 0) {
            try msg.writer().writeAll("null");
        } else {
            try writeJsonString(msg.writer(), result.content.items);
        }
        try msg.writer().writeAll(",\"tool_calls\":[");
        for (result.calls.items, 0..) |call, idx| {
            if (idx > 0) try msg.writer().writeAll(",");
            try msg.writer().writeAll("{\"id\":");
            try writeJsonString(msg.writer(), call.id);
            try msg.writer().writeAll(",\"type\":\"function\",\"function\":{\"name\":");
            try writeJsonString(msg.writer(), call.name);
            try msg.writer().writeAll(",\"arguments\":");
            try writeJsonString(msg.writer(), call.args);
            try msg.writer().writeAll("}}");
        }
        try msg.writer().writeAll("]}");
        try msgs.appendSlice(gpa, msg.items());

        for (result.calls.items) |call| {
            const output = runTool(io, arena, call) catch |err|
                try std.fmt.allocPrint(arena, "error: {s}", .{@errorName(err)});
            var tool_msg = JsonBuf.init(arena);
            try tool_msg.writer().writeAll(",{\"role\":\"tool\",\"tool_call_id\":");
            try writeJsonString(tool_msg.writer(), call.id);
            try tool_msg.writer().writeAll(",\"content\":");
            try writeJsonString(tool_msg.writer(), clamp(output, max_tool_output));
            try tool_msg.writer().writeAll("}");
            try msgs.appendSlice(gpa, tool_msg.items());
        }
    }

    // One machine-readable line per response: gauntlet reads these for live
    // token rates, and they are the only stdout that is not model output.
    usage.add(result);
    var usage_line = JsonBuf.init(arena);
    const w = usage_line.writer();
    try w.writeAll("{\"type\":\"usage\",\"usage\":{");
    try w.print("\"prompt_tokens\":{d},\"cached_tokens\":{d},\"completion_tokens\":{d},\"reasoning_tokens\":{d},\"total_tokens\":{d}", .{
        usage.prompt, usage.cached, usage.completion, usage.reasoning, usage.total,
    });
    try w.writeAll("}}\n");
    std.Io.File.stdout().writeStreamingAll(io, usage_line.items()) catch {};
}

fn runTool(io: Io, arena: std.mem.Allocator, call: ToolCall) ![]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, arena, call.args, .{}) catch
        return std.fmt.allocPrint(arena, "error: tool arguments are not valid JSON", .{});
    const args = switch (parsed.value) {
        .object => |o| o,
        else => return std.fmt.allocPrint(arena, "error: tool arguments must be an object", .{}),
    };

    noteToolCall(io, arena, call.name, args);
    if (std.mem.eql(u8, call.name, "bash")) return toolBash(io, arena, args);
    if (std.mem.eql(u8, call.name, "read")) return toolRead(io, arena, args);
    if (std.mem.eql(u8, call.name, "write")) return toolWrite(io, arena, args);
    if (std.mem.eql(u8, call.name, "edit")) return toolEdit(io, arena, args);
    if (std.mem.eql(u8, call.name, "search")) return toolSearch(io, arena, args);
    if (std.mem.eql(u8, call.name, "ast")) return toolAst(io, arena, args);
    if (std.mem.eql(u8, call.name, "git")) return toolGit(io, arena, args);
    return std.fmt.allocPrint(arena, "error: unknown tool '{s}'", .{call.name});
}

/// A one-line tool gutter on stderr, the shape gauntlet recognizes.
fn noteToolCall(io: Io, arena: std.mem.Allocator, name: []const u8, args: std.json.ObjectMap) void {
    // The interesting argument is not the same one for every tool: a structural
    // search is identified by its pattern, a bash call by its command.
    const detail = if (std.mem.eql(u8, name, "ast"))
        (str(args.get("pattern")) orelse "")
    else
        (str(args.get("command")) orelse str(args.get("pattern")) orelse str(args.get("path")) orelse "");
    const line = std.fmt.allocPrint(arena, "\u{23fa} {s} {s}\n", .{ name, clamp(detail, 120) }) catch return;
    std.Io.File.stderr().writeStreamingAll(io, line) catch {};
}

fn toolBash(io: Io, arena: std.mem.Allocator, args: std.json.ObjectMap) ![]u8 {
    const command = str(args.get("command")) orelse return std.fmt.allocPrint(arena, "error: missing command", .{});
    const timeout_ms: u64 = if (args.get("timeout_ms")) |v| num(v) else 120_000;
    const res = std.process.run(arena, io, .{
        .argv = &.{ "/bin/sh", "-c", command },
        .stdout_limit = .limited(max_tool_output * 4),
        .stderr_limit = .limited(max_tool_output * 4),
        .timeout = durationMs(timeout_ms),
    }) catch |err| switch (err) {
        error.Timeout => return std.fmt.allocPrint(arena, "error: command timed out after {d}ms", .{timeout_ms}),
        else => return std.fmt.allocPrint(arena, "error: {s}", .{@errorName(err)}),
    };
    var buf: std.ArrayList(u8) = .empty;
    if (res.stdout.len > 0) try buf.appendSlice(arena, res.stdout);
    if (res.stderr.len > 0) {
        if (buf.items.len > 0) try buf.appendSlice(arena, "\n");
        try buf.appendSlice(arena, res.stderr);
    }
    if (buf.items.len == 0) return std.fmt.allocPrint(arena, "(no output, exit {s})", .{@tagName(res.term)});
    if (res.term != .exited or res.term.exited != 0) {
        try buf.appendSlice(arena, "\n(exit: ");
        try buf.appendSlice(arena, @tagName(res.term));
        if (res.term == .exited)
            try buf.appendSlice(arena, try std.fmt.allocPrint(arena, " {d}", .{res.term.exited}));
        try buf.appendSlice(arena, ")");
    }
    return buf.items;
}

fn toolRead(io: Io, arena: std.mem.Allocator, args: std.json.ObjectMap) ![]u8 {
    const path = str(args.get("path")) orelse return std.fmt.allocPrint(arena, "error: missing path", .{});
    const raw = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(4 * 1024 * 1024)) catch |err|
        return std.fmt.allocPrint(arena, "error: cannot read {s}: {s}", .{ path, @errorName(err) });
    if (!args.contains("offset") and !args.contains("limit")) return raw;

    const offset: usize = @intCast(@max(1, num(args.get("offset"))));
    const limit: usize = if (args.get("limit")) |v| @intCast(num(v)) else std.math.maxInt(usize);
    var buf: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, raw, '\n');
    var n: usize = 0;
    var taken: usize = 0;
    while (lines.next()) |line| : (n += 1) {
        if (n + 1 < offset) continue;
        if (taken >= limit) break;
        try buf.appendSlice(arena, line);
        try buf.appendSlice(arena, "\n");
        taken += 1;
    }
    return buf.items;
}

fn toolWrite(io: Io, arena: std.mem.Allocator, args: std.json.ObjectMap) ![]u8 {
    const path = str(args.get("path")) orelse return std.fmt.allocPrint(arena, "error: missing path", .{});
    const content = str(args.get("content")) orelse "";
    if (std.fs.path.dirname(path)) |dir| std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = content }) catch |err|
        return std.fmt.allocPrint(arena, "error: cannot write {s}: {s}", .{ path, @errorName(err) });
    return std.fmt.allocPrint(arena, "wrote {d} bytes to {s}", .{ content.len, path });
}

fn toolEdit(io: Io, arena: std.mem.Allocator, args: std.json.ObjectMap) ![]u8 {
    const path = str(args.get("path")) orelse return std.fmt.allocPrint(arena, "error: missing path", .{});
    const old = str(args.get("old_string")) orelse return std.fmt.allocPrint(arena, "error: missing old_string", .{});
    const new = str(args.get("new_string")) orelse return std.fmt.allocPrint(arena, "error: missing new_string", .{});
    const all = if (args.get("replace_all")) |v| v == .bool and v.bool else false;

    const raw = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(8 * 1024 * 1024)) catch |err|
        return std.fmt.allocPrint(arena, "error: cannot read {s}: {s}", .{ path, @errorName(err) });
    if (old.len == 0) return std.fmt.allocPrint(arena, "error: old_string is empty", .{});

    const count = std.mem.count(u8, raw, old);
    if (count == 0) return std.fmt.allocPrint(arena, "error: old_string not found in {s}", .{path});
    if (count > 1 and !all) return std.fmt.allocPrint(arena, "error: old_string occurs {d} times in {s}; add context or set replace_all", .{ count, path });

    var buf: std.ArrayList(u8) = .empty;
    if (all) {
        var rest = raw;
        while (std.mem.indexOf(u8, rest, old)) |at| {
            try buf.appendSlice(arena, rest[0..at]);
            try buf.appendSlice(arena, new);
            rest = rest[at + old.len ..];
        }
        try buf.appendSlice(arena, rest);
    } else {
        const at = std.mem.indexOf(u8, raw, old).?;
        try buf.appendSlice(arena, raw[0..at]);
        try buf.appendSlice(arena, new);
        try buf.appendSlice(arena, raw[at + old.len ..]);
    }
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = buf.items }) catch |err|
        return std.fmt.allocPrint(arena, "error: cannot write {s}: {s}", .{ path, @errorName(err) });
    return std.fmt.allocPrint(arena, "replaced {d} occurrence(s) in {s}", .{ count, path });
}

fn toolSearch(io: Io, arena: std.mem.Allocator, args: std.json.ObjectMap) ![]u8 {
    const pattern = str(args.get("pattern")) orelse return std.fmt.allocPrint(arena, "error: missing pattern", .{});
    const path = str(args.get("path")) orelse ".";
    const glob = str(args.get("glob"));
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ "rg", "--line-number", "--no-heading", "--color", "never", "--max-count", "200" });
    if (glob) |g| {
        try argv.appendSlice(arena, &.{ "--glob", g });
    }
    try argv.appendSlice(arena, &.{ "--", pattern, path });
    const res = std.process.run(arena, io, .{
        .argv = argv.items,
        .stdout_limit = .limited(max_tool_output * 4),
        .stderr_limit = .limited(4096),
        .timeout = durationMs(60_000),
    }) catch |err| return std.fmt.allocPrint(arena, "error: ripgrep failed: {s}", .{@errorName(err)});
    if (res.stdout.len > 0) return res.stdout;
    if (res.stderr.len > 0) return res.stderr;
    return std.fmt.allocPrint(arena, "(no matches)", .{});
}

/// Structural search/rewrite through ast-grep. `rewrite` set means the change
/// is applied to every match (`--update-all`), so the next turn reads the
/// result back rather than trusting the tool's summary.
fn toolAst(io: Io, arena: std.mem.Allocator, args: std.json.ObjectMap) ![]u8 {
    const pattern = str(args.get("pattern")) orelse return std.fmt.allocPrint(arena, "error: missing pattern", .{});
    const lang = str(args.get("lang")) orelse return std.fmt.allocPrint(arena, "error: missing lang", .{});
    const path = str(args.get("path")) orelse ".";
    const rewrite = str(args.get("rewrite"));

    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ "ast-grep", "run", "--pattern", pattern, "--lang", lang });
    if (rewrite) |r| try argv.appendSlice(arena, &.{ "--rewrite", r, "--update-all" });
    try argv.appendSlice(arena, &.{ "--", path });

    const res = std.process.run(arena, io, .{
        .argv = argv.items,
        .stdout_limit = .limited(max_tool_output * 4),
        .stderr_limit = .limited(4096),
        .timeout = durationMs(60_000),
    }) catch |err| return std.fmt.allocPrint(arena, "error: ast-grep failed: {s}", .{@errorName(err)});
    if (res.stdout.len > 0) return res.stdout;
    if (res.stderr.len > 0) return res.stderr;
    return std.fmt.allocPrint(arena, "(no matches)", .{});
}

fn appendMessage(gpa: std.mem.Allocator, msgs: *std.ArrayList(u8), role: []const u8, content: []const u8) !void {
    if (msgs.items.len > 1) try msgs.append(gpa, ',');
    var buf = JsonBuf.init(gpa);
    try buf.writer().writeAll("{\"role\":");
    try writeJsonString(buf.writer(), role);
    try buf.writer().writeAll(",\"content\":");
    try writeJsonString(buf.writer(), content);
    try buf.writer().writeAll("}");
    try msgs.appendSlice(gpa, buf.items());
    buf.list.deinit(gpa);
}

/// A byte buffer that hands out an `Io.Writer` (the std ArrayList lost its
/// `writer` method in 0.16, so the adapter lives here once).
const JsonBuf = struct {
    list: std.ArrayList(u8) = .empty,
    allocating: Io.Writer.Allocating,

    fn init(allocator: std.mem.Allocator) JsonBuf {
        var list: std.ArrayList(u8) = .empty;
        return .{ .list = list, .allocating = Io.Writer.Allocating.fromArrayList(allocator, &list) };
    }

    fn writer(self: *JsonBuf) *Io.Writer {
        return &self.allocating.writer;
    }

    fn items(self: *JsonBuf) []u8 {
        self.list = self.allocating.toArrayList();
        return self.list.items;
    }
};

fn writeJsonString(w: *Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        0x08 => try w.writeAll("\\b"),
        0x0c => try w.writeAll("\\f"),
        else => if (c < 0x20)
            try w.print("\\u{x:0>4}", .{c})
        else
            try w.writeByte(c),
    };
    try w.writeByte('"');
}

fn str(v: ?std.json.Value) ?[]const u8 {
    const value = v orelse return null;
    return switch (value) {
        .string => |s| s,
        else => null,
    };
}

fn num(v: ?std.json.Value) u64 {
    const value = v orelse return 0;
    return switch (value) {
        .integer => |n| if (n > 0) @intCast(n) else 0,
        .float => |f| std.math.lossyCast(u64, f),
        .number_string => |s| std.fmt.parseInt(u64, s, 10) catch 0,
        else => 0,
    };
}

const max_attempts: u32 = 3;
const retry_backoff_base_ms: u64 = 1000;
const max_backoff_ms: u64 = 60_000;
/// Enough doublings to reach the cap; the cap is what bounds the wait.
const max_backoff_shift: u32 = 6;

/// Statuses worth another attempt: the provider is busy, not the request wrong.
fn retryableStatus(status: std.http.Status) bool {
    return switch (@intFromEnum(status)) {
        408, 409, 425, 429 => true,
        else => @intFromEnum(status) >= 500,
    };
}

/// Logs and sleeps before the next attempt. False means attempts are spent and
/// the caller should surface the error.
fn waitBeforeRetry(io: Io, attempt: u32, what: []const u8) bool {
    if (attempt >= max_attempts) return false;
    std.debug.print("microagent: {s} failed, retrying (attempt {d}/{d})\n", .{ what, attempt + 1, max_attempts });
    waitFor(io, attempt) catch {};
    return true;
}

/// Backoff before the next attempt: 1 s, 2 s, 4 s, capped. Saturating, because
/// the shift and the multiply both overflow long before a u32 attempt counter
/// does, and a checked build panicking where a release build wraps is not a
/// property to want in a sleep.
fn backoffMs(attempt: u32) u64 {
    if (attempt == 0) return retry_backoff_base_ms;
    const shift: u6 = @intCast(@min(attempt - 1, max_backoff_shift));
    return @min(retry_backoff_base_ms *| (@as(u64, 1) << shift), max_backoff_ms);
}

fn waitFor(io: Io, attempt: u32) !void {
    try io.sleep(.{ .nanoseconds = backoffMs(attempt) *| std.time.ns_per_ms }, .awake);
}

/// A monotonic duration for `Io.Timeout`, from milliseconds.
fn durationMs(ms: u64) Io.Timeout {
    return .{ .duration = .{ .raw = .{ .nanoseconds = ms *| std.time.ns_per_ms }, .clock = .awake } };
}

/// The first `max` bytes, cut on a UTF-8 codepoint boundary. Both callers feed
/// text a model will read back, one of them inside a JSON request body, so a
/// cut in the middle of a codepoint would put invalid UTF-8 on the wire.
fn clamp(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    var end = max;
    while (end > 0 and s[end] & 0xc0 == 0x80) end -= 1;
    return s[0..end];
}

// A file's tests are collected only when the root file's test block imports
// it, so the `update` subcommand's tests and the style levels' tests are
// pulled in here.
test {
    _ = style_mod;
    _ = update_mod;
}

test "json string escaping" {
    var buf = JsonBuf.init(std.testing.allocator);
    try writeJsonString(buf.writer(), "a\"b\\c\nd\t\u{7}");
    defer buf.list.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("\"a\\\"b\\\\c\\nd\\t\\u0007\"", buf.items());
}

test "clamp keeps short strings intact" {
    try std.testing.expectEqualStrings("abc", clamp("abc", 8));
    // A string exactly at the limit is kept whole, not cut to one byte short.
    try std.testing.expectEqualStrings("abc", clamp("abc", 3));
    try std.testing.expectEqualStrings("ab", clamp("abcd", 2));
    try std.testing.expectEqualStrings("", clamp("abc", 0));
}

test "conversation and tool schema serialize as one valid request body" {
    // The body's storage belongs to a JsonBuf, not to the caller, so the test
    // hands it an arena instead of trying to free the slice by hand.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const gpa = arena_state.allocator();
    var msgs: std.ArrayList(u8) = .empty;
    try msgs.appendSlice(gpa, "[");
    try appendMessage(gpa, &msgs, "system", system_prompt);
    try appendMessage(gpa, &msgs, "user", "say \"hi\"\nplease");

    const opts: Options = .{ .model = "test/model" };
    const body = try buildBody(gpa, opts, msgs.items);

    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, body, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqualStrings("test/model", root.get("model").?.string);
    try std.testing.expect(root.get("stream").?.bool);

    const messages = root.get("messages").?.array;
    try std.testing.expectEqual(@as(usize, 2), messages.items.len);
    try std.testing.expectEqualStrings("system", messages.items[0].object.get("role").?.string);
    try std.testing.expectEqualStrings("say \"hi\"\nplease", messages.items[1].object.get("content").?.string);

    // The advertised names and the dispatch table are two lists that have to
    // stay the same list: a tool in the schema that `runTool` cannot dispatch
    // is one the model will call and be told does not exist.
    const advertised = [_][]const u8{ "bash", "read", "write", "edit", "search", "ast", "git" };
    const tools = root.get("tools").?.array;
    try std.testing.expectEqual(advertised.len, tools.items.len);
    for (advertised, tools.items) |name, tool| {
        const f = tool.object.get("function").?.object;
        try std.testing.expectEqualStrings(name, f.get("name").?.string);
        // The description is what the model picks the tool by, so an empty one
        // is a tool the model has no reason to call.
        try std.testing.expect(f.get("description").?.string.len > 0);
        try std.testing.expect(f.get("parameters").?.object.get("required") != null);
        const err = try dispatch(arena_state.allocator(), name, "{}");
        // Every tool has a required argument, so `{}` is refused by the tool
        // itself and never reaches "unknown tool".
        try std.testing.expect(!std.mem.startsWith(u8, err, "error: unknown tool"));
    }
}

test "a long stream costs the largest frame, not the sum of frames" {
    const gpa = std.testing.allocator;
    var run_state = std.heap.ArenaAllocator.init(gpa);
    defer run_state.deinit();
    var frame_state = std.heap.ArenaAllocator.init(gpa);
    defer frame_state.deinit();

    var result: ChatResult = .{};
    var calls: std.ArrayList(ToolCall) = .empty;
    var out_buf: std.ArrayList(u8) = .empty;

    const payload = "{\"choices\":[{\"delta\":{\"content\":\"tok\"}}]}";
    const frames: usize = 20_000;

    // Reference point: the scratch capacity one frame needs.
    try applyFrame(frame_state.allocator(), run_state.allocator(), payload, &result, &calls, &out_buf);
    const one_frame_capacity = frame_state.queryCapacity();
    _ = frame_state.reset(.retain_capacity);

    var i: usize = 1;
    while (i < frames) : (i += 1) {
        try applyFrame(frame_state.allocator(), run_state.allocator(), payload, &result, &calls, &out_buf);
        _ = frame_state.reset(.retain_capacity);
    }

    try std.testing.expectEqual(frames * 3, result.content.items.len);
    try std.testing.expectEqual(frames * 3, out_buf.items.len);
    // The work counter this test asserts on: scratch bytes retained after the
    // last frame. It must equal what one frame needed, not grow with the frame
    // count, which is what it did before the per-frame reset (20_000 frames'
    // worth of parse trees were kept alive in the run arena).
    try std.testing.expect(one_frame_capacity > 0);
    try std.testing.expectEqual(one_frame_capacity, frame_state.queryCapacity());
}

test "tool call fragments merge by index across frames" {
    const gpa = std.testing.allocator;
    var run_state = std.heap.ArenaAllocator.init(gpa);
    defer run_state.deinit();
    var frame_state = std.heap.ArenaAllocator.init(gpa);
    defer frame_state.deinit();

    var result: ChatResult = .{};
    var calls: std.ArrayList(ToolCall) = .empty;
    var out_buf: std.ArrayList(u8) = .empty;

    const frames = [_][]const u8{
        "{\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_1\",\"function\":{\"name\":\"read\",\"arguments\":\"{\\\"pa\"}}]}}]}",
        "{\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"th\\\":\\\"a.zig\\\"}\",\"arguments_end\":null}}]}}]}",
    };
    for (frames) |f| {
        try applyFrame(frame_state.allocator(), run_state.allocator(), f, &result, &calls, &out_buf);
        _ = frame_state.reset(.retain_capacity);
    }

    try std.testing.expectEqual(@as(usize, 1), calls.items.len);
    try std.testing.expectEqualStrings("call_1", calls.items[0].id);
    try std.testing.expectEqualStrings("read", calls.items[0].name);
    try std.testing.expectEqualStrings("{\"path\":\"a.zig\"}", calls.items[0].args);
}

test "usage counters land on the result" {
    var run_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer run_state.deinit();
    var result: ChatResult = .{};
    var calls: std.ArrayList(ToolCall) = .empty;
    var out_buf: std.ArrayList(u8) = .empty;
    const payload =
        "{\"choices\":[{\"delta\":{}}],\"usage\":{\"prompt_tokens\":11,\"completion_tokens\":22,\"total_tokens\":33,\"completion_tokens_details\":{\"reasoning_tokens\":7}}}";
    try applyFrame(run_state.allocator(), run_state.allocator(), payload, &result, &calls, &out_buf);
    try std.testing.expectEqual(@as(u64, 11), result.prompt_tokens);
    try std.testing.expectEqual(@as(u64, 22), result.completion_tokens);
    try std.testing.expectEqual(@as(u64, 33), result.total_tokens);
    try std.testing.expectEqual(@as(u64, 7), result.reasoning_tokens);
    // Nothing in this frame says the prompt was cached, so it is a full miss.
    try std.testing.expectEqual(@as(u64, 0), result.cached_tokens);
}

// The cache counter is what turns "we probably reuse the prefix" into a number
// a benchmark can read, so all three provider spellings have to land on it.
test "cached prompt tokens read every provider spelling" {
    const spellings = [_][]const u8{
        "{\"choices\":[{\"delta\":{}}],\"usage\":{\"prompt_tokens\":900,\"prompt_tokens_details\":{\"cached_tokens\":768}}}",
        "{\"choices\":[{\"delta\":{}}],\"usage\":{\"prompt_tokens\":900,\"prompt_cache_hit_tokens\":768}}",
        "{\"choices\":[{\"delta\":{}}],\"usage\":{\"prompt_tokens\":900,\"cache_read_input_tokens\":768}}",
    };
    for (spellings) |payload| {
        var run_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer run_state.deinit();
        var result: ChatResult = .{};
        var calls: std.ArrayList(ToolCall) = .empty;
        var out_buf: std.ArrayList(u8) = .empty;
        try applyFrame(run_state.allocator(), run_state.allocator(), payload, &result, &calls, &out_buf);
        try std.testing.expectEqual(@as(u64, 900), result.prompt_tokens);
        try std.testing.expectEqual(@as(u64, 768), result.cached_tokens);
    }
}

// A record a monitor reads has to be one JSON object with this response's own
// counters, the directory that attributes it, and the model time a rate is
// taken over.
test "session record carries one response's counters, cwd and model time" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const arena = state.allocator();

    var result: ChatResult = .{};
    result.prompt_tokens = 910;
    result.cached_tokens = 832;
    result.completion_tokens = 18;
    result.reasoning_tokens = 0;
    result.total_tokens = 928;

    const line = try sessionRecord(arena, 1759000000000, "/home/me/proj", "deepseek/deepseek-v4-flash", 1234, &result);
    try std.testing.expectEqualStrings(
        "{\"ts\":1759000000000,\"cwd\":\"/home/me/proj\",\"model\":\"deepseek/deepseek-v4-flash\"," ++
            "\"elapsed_ms\":1234,\"usage\":{\"prompt_tokens\":910,\"cached_tokens\":832," ++
            "\"completion_tokens\":18,\"reasoning_tokens\":0,\"total_tokens\":928}}\n",
        line,
    );
}

test "session record escapes a directory that needs it" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    var result: ChatResult = .{ .completion_tokens = 4 };
    const line = try sessionRecord(state.allocator(), 1, "/tmp/a\"b\\c", "m", 5, &result);
    try std.testing.expectEqualStrings(
        "{\"ts\":1,\"cwd\":\"/tmp/a\\\"b\\\\c\",\"model\":\"m\"," ++
            "\"elapsed_ms\":5,\"usage\":{\"prompt_tokens\":0,\"cached_tokens\":0," ++
            "\"completion_tokens\":4,\"reasoning_tokens\":0,\"total_tokens\":0}}\n",
        line,
    );
}

test "tool output truncation keeps whole lines" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const short = try firstLines(arena, "a\nb\n", 10);
    try std.testing.expectEqualStrings("a\nb\n", short);

    const long = try firstLines(arena, "1\n2\n3\n4\n", 2);
    try std.testing.expectEqualStrings("1\n2\n... [output truncated at 2 lines]", long);

    // A limit equal to the line count keeps every line and adds no marker.
    try std.testing.expectEqualStrings("1\n2\n", try firstLines(arena, "1\n2\n", 2));
    try std.testing.expectEqualStrings("1\n2\n3\n", try firstLines(arena, "1\n2\n3\n", 3));
    // A last line with no newline still counts, so the cut lands on it.
    try std.testing.expectEqualStrings("1\n... [output truncated at 1 lines]", try firstLines(arena, "1\n2", 1));
    try std.testing.expectEqualStrings("1\n2", try firstLines(arena, "1\n2", 2));
    // No newline at all means one line, which a limit of one keeps whole.
    try std.testing.expectEqualStrings("solo", try firstLines(arena, "solo", 1));
    try std.testing.expectEqualStrings("solo\n", try firstLines(arena, "solo\n", 1));
}

test "compaction elides old tool output and keeps the recent turns" {
    const gpa = std.testing.allocator;
    var scratch_state = std.heap.ArenaAllocator.init(gpa);
    defer scratch_state.deinit();

    var msgs: std.ArrayList(u8) = .empty;
    defer msgs.deinit(gpa);

    // A conversation well past the limit: 120 tool results of 8 KB each.
    const blob = "x" ** 8192;
    try msgs.appendSlice(gpa, "[");
    try appendMessage(gpa, &msgs, "system", "you are a coding agent");
    try appendMessage(gpa, &msgs, "user", "fix the bug");
    var i: usize = 0;
    while (i < 120) : (i += 1) {
        if (msgs.items.len > 1) try msgs.append(gpa, ',');
        var msg = JsonBuf.init(gpa);
        try msg.writer().writeAll("{\"role\":\"tool\",\"tool_call_id\":\"call_");
        try msg.writer().print("{d}", .{i});
        try msg.writer().writeAll("\",\"content\":");
        try writeJsonString(msg.writer(), blob);
        try msg.writer().writeAll("}");
        try msgs.appendSlice(gpa, msg.items());
        msg.list.deinit(gpa);
    }
    try msgs.append(gpa, ']');
    const before = msgs.items.len;
    try std.testing.expect(before > conversation_soft_limit);

    try compactMessages(gpa, &msgs, scratch_state.allocator());

    try std.testing.expect(msgs.items.len < before / 2);
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, msgs.items, .{});
    defer parsed.deinit();
    const array = parsed.value.array;
    try std.testing.expectEqual(@as(usize, 122), array.items.len);
    // Roles and ids survive; the newest tool result is untouched.
    try std.testing.expectEqualStrings("system", array.items[0].object.get("role").?.string);
    const last = array.items[array.items.len - 1].object;
    try std.testing.expectEqualStrings("call_119", last.get("tool_call_id").?.string);
    try std.testing.expectEqual(@as(usize, 8192), last.get("content").?.string.len);
    try std.testing.expect(std.mem.startsWith(u8, array.items[2].object.get("content").?.string, "[earlier tool output elided"));
}

// Prompt caching keys on the exact bytes of the request prefix. Compaction is
// the one thing that rewrites the conversation, so everything ahead of the
// first elided tool result has to survive it byte for byte: one re-spelled
// escape and every later turn re-reads the whole prompt instead of its tail.
test "compaction leaves the cached prefix byte-identical" {
    const gpa = std.testing.allocator;
    var scratch_state = std.heap.ArenaAllocator.init(gpa);
    defer scratch_state.deinit();

    var msgs: std.ArrayList(u8) = .empty;
    defer msgs.deinit(gpa);

    try msgs.appendSlice(gpa, "[");
    // Characters a JSON round trip could re-spell: quote, backslash, newline,
    // a control byte, and a non-ASCII byte.
    try appendMessage(gpa, &msgs, "system", "you are a coding agent: \"a\\b\"\n\u{7} caf\u{00e9}");
    try appendMessage(gpa, &msgs, "user", "fix the bug");
    const prefix = try gpa.dupe(u8, msgs.items);
    defer gpa.free(prefix);

    const blob = "x" ** 8192;
    var i: usize = 0;
    while (i < 120) : (i += 1) {
        if (msgs.items.len > 1) try msgs.append(gpa, ',');
        var msg = JsonBuf.init(gpa);
        try msg.writer().writeAll("{\"role\":\"tool\",\"tool_call_id\":\"call_");
        try msg.writer().print("{d}", .{i});
        try msg.writer().writeAll("\",\"content\":");
        try writeJsonString(msg.writer(), blob);
        try msg.writer().writeAll("}");
        try msgs.appendSlice(gpa, msg.items());
        msg.list.deinit(gpa);
    }
    try msgs.append(gpa, ']');
    try std.testing.expect(msgs.items.len > conversation_soft_limit);

    try compactMessages(gpa, &msgs, scratch_state.allocator());

    try std.testing.expect(msgs.items.len > prefix.len);
    try std.testing.expectEqualStrings(prefix, msgs.items[0..prefix.len]);
    // The prefix is cached, not just unchanged: the newest turn is still whole.
    try std.testing.expect(std.mem.endsWith(u8, msgs.items, "\"content\":\"" ++ blob ++ "\"}]"));
}

test "a CA bundle path that cannot be read falls back to the system store" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    net.loadCaBundle(&client, io, gpa, "/nonexistent/ca-bundle.pem", arena_state.allocator());
    try std.testing.expect(client.now == null);
}

test "reasoning effort is only sent when asked for" {
    // JsonBuf owns the storage it hands back, so the test gives it an arena
    // rather than trying to free the returned slice.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const gpa = arena_state.allocator();

    var msgs: std.ArrayList(u8) = .empty;
    try msgs.appendSlice(gpa, "[{\"role\":\"user\",\"content\":\"hi\"}]");

    const plain: Options = .{ .model = "m" };
    const body_plain = try buildBody(gpa, plain, msgs.items);
    try std.testing.expect(std.mem.indexOf(u8, body_plain, "\"reasoning\"") == null);

    const low: Options = .{ .model = "m", .reasoning_effort = "low" };
    const body_low = try buildBody(gpa, low, msgs.items);
    try std.testing.expect(std.mem.indexOf(u8, body_low, "\"reasoning\":{\"effort\":\"low\"}") != null);

    const none: Options = .{ .model = "m", .reasoning_effort = "none" };
    const body_none = try buildBody(gpa, none, msgs.items);
    try std.testing.expect(std.mem.indexOf(u8, body_none, "\"reasoning\":{\"enabled\":false}") != null);
}

test "only weather-shaped statuses are retried" {
    try std.testing.expect(retryableStatus(.too_many_requests));
    try std.testing.expect(retryableStatus(.bad_gateway));
    try std.testing.expect(retryableStatus(.service_unavailable));
    try std.testing.expect(!retryableStatus(.bad_request));
    try std.testing.expect(!retryableStatus(.unauthorized));
    try std.testing.expect(!retryableStatus(.not_found));
}

test "token counters read the OpenAI and OpenRouter spellings" {
    try std.testing.expectEqual(@as(u64, 42), num(.{ .integer = 42 }));
    try std.testing.expectEqual(@as(u64, 7), num(.{ .number_string = "7" }));
    try std.testing.expectEqual(@as(u64, 0), num(.{ .integer = -1 }));
    try std.testing.expectEqual(@as(u64, 0), num(null));
}

// A tool argument is a model-controlled string, and a model that sends
// `{"path": 42}` or `{"path": null}` must be told the argument is missing
// rather than having the number read as a path. Only a JSON string is a
// string; every other type, including a number and a bool, is refused.
test "a tool argument is a string or it is refused" {
    try std.testing.expectEqualStrings("a.zig", str(.{ .string = "a.zig" }).?);
    try std.testing.expectEqualStrings("", str(.{ .string = "" }).?);
    try std.testing.expect(str(null) == null);
    try std.testing.expect(str(.{ .integer = 42 }) == null);
    try std.testing.expect(str(.{ .float = 1.5 }) == null);
    try std.testing.expect(str(.{ .bool = true }) == null);
}

var debug_enabled: bool = false;

/// Cheap env-gated trace, for debugging a stuck stream.
fn debugOn() bool {
    return debug_enabled;
}

test "git tool refuses a rev that git would read as an option" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var args: std.json.ObjectMap = .empty;
    try args.put(arena, "cmd", .{ .string = "diff" });
    try args.put(arena, "rev", .{ .string = "--output=pwned" });
    const out = try toolGit(std.testing.io, arena, args);
    try std.testing.expectEqualStrings("error: rev must not start with '-'", out);
}

test "git tool refuses a missing or unknown subcommand" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    {
        const out = try toolGit(std.testing.io, arena, .empty);
        try std.testing.expectEqualStrings("error: missing cmd", out);
    }
    {
        // The subcommand is what picks the git argv, so an unknown one has to
        // stop here rather than be handed to git.
        var args: std.json.ObjectMap = .empty;
        try args.put(arena, "cmd", .{ .string = "push" });
        try std.testing.expectEqualStrings(
            "error: unknown git cmd 'push'",
            try toolGit(std.testing.io, arena, args),
        );
    }
}

// The tool arguments are written by the model, so dispatch is the trust
// boundary: malformed JSON, a non-object payload, and an unrecognized name all
// have to be refused with the tool's own error text instead of reaching a
// subprocess.
test "the tool dispatcher refuses arguments that are not an object" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectEqualStrings(
        "error: tool arguments are not valid JSON",
        try dispatch(arena, "read", "{"),
    );
    try std.testing.expectEqualStrings(
        "error: tool arguments must be an object",
        try dispatch(arena, "read", "[]"),
    );
    try std.testing.expectEqualStrings(
        "error: unknown tool 'delete_everything'",
        try dispatch(arena, "delete_everything", "{}"),
    );
}

// Every tool's required argument is checked before it opens a file or spawns a
// process, so a model that omits one gets "missing <arg>" rather than a
// confusing error from the kernel.
test "each tool refuses a missing required argument" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cases = [_]struct { tool: []const u8, args: []const u8, want: []const u8 }{
        .{ .tool = "bash", .args = "{}", .want = "error: missing command" },
        .{ .tool = "read", .args = "{}", .want = "error: missing path" },
        .{ .tool = "write", .args = "{}", .want = "error: missing path" },
        .{ .tool = "edit", .args = "{}", .want = "error: missing path" },
        .{ .tool = "edit", .args = "{\"path\":\"a.zig\"}", .want = "error: missing old_string" },
        .{ .tool = "edit", .args = "{\"path\":\"a.zig\",\"old_string\":\"a\"}", .want = "error: missing new_string" },
        .{ .tool = "search", .args = "{}", .want = "error: missing pattern" },
        .{ .tool = "ast", .args = "{}", .want = "error: missing pattern" },
        .{ .tool = "ast", .args = "{\"pattern\":\"a$b\"}", .want = "error: missing lang" },
        .{ .tool = "git", .args = "{}", .want = "error: missing cmd" },
    };
    for (cases) |c| {
        try std.testing.expectEqualStrings(c.want, try dispatch(arena, c.tool, c.args));
    }
    // The same omissions go through dispatch, not only the direct call.
    try std.testing.expectEqualStrings(
        "error: missing pattern",
        try dispatch(arena, "search", "{\"path\":\".\"}"),
    );
}

// A missing argument that the model filled with a number is still missing: the
// tools read their arguments through `str`, which refuses every non-string.
test "a tool argument sent as a number is missing, not a value" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectEqualStrings(
        "error: missing path",
        try dispatch(arena, "read", "{\"path\":42}"),
    );
    try std.testing.expectEqualStrings(
        "error: missing command",
        try dispatch(arena, "bash", "{\"command\":null}"),
    );
}

// A tool call as the model produced it: the same mutable slices the frame
// parser fills in, so the dispatcher tests go through the real entry point.
fn dispatch(arena: std.mem.Allocator, name: []const u8, args: []const u8) ![]u8 {
    return runTool(std.testing.io, arena, .{
        .id = try arena.dupe(u8, ""),
        .name = try arena.dupe(u8, name),
        .args = try arena.dupe(u8, args),
    });
}

test "out-of-range numbers from the model saturate instead of trapping" {
    try std.testing.expectEqual(std.math.maxInt(u64), num(.{ .float = 1e30 }));
    try std.testing.expectEqual(@as(u64, 0), num(.{ .float = -5 }));
    try std.testing.expectEqual(@as(u64, 0), num(.{ .float = std.math.nan(f64) }));
    _ = durationMs(std.math.maxInt(u64));
}

test "a saturated token count does not overflow the run total" {
    var usage: Usage = .{};
    const absurd: ChatResult = .{ .prompt_tokens = std.math.maxInt(u64), .total_tokens = std.math.maxInt(u64) };
    usage.add(&absurd);
    const ordinary: ChatResult = .{ .prompt_tokens = 10 };
    usage.add(&ordinary);
    try std.testing.expectEqual(std.math.maxInt(u64), usage.prompt);
    try std.testing.expectEqual(std.math.maxInt(u64), usage.total);
}

test "a truncated tool result keeps whole codepoints" {
    // "日" is 3 bytes, so a 4- or 5-byte cut lands inside it.
    try std.testing.expectEqualStrings("abc", clamp("abc日本", 4));
    try std.testing.expectEqualStrings("ab", clamp("ab日", 4));
    try std.testing.expectEqualStrings("abc", clamp("abc", 4));
    try std.testing.expect(std.unicode.utf8ValidateSlice(clamp("abc日本語のテキスト", 8)));
}

test "backoff doubles, caps, and never overflows an attempt counter" {
    try std.testing.expectEqual(@as(u64, 1000), backoffMs(0));
    try std.testing.expectEqual(@as(u64, 1000), backoffMs(1));
    try std.testing.expectEqual(@as(u64, 2000), backoffMs(2));
    try std.testing.expectEqual(@as(u64, 4000), backoffMs(3));
    try std.testing.expectEqual(max_backoff_ms, backoffMs(1000));
}

test "a tool call index past the cap is dropped, not allocated" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var result: ChatResult = .{};
    var calls: std.ArrayList(ToolCall) = .empty;
    var out_buf: std.ArrayList(u8) = .empty;
    const payload = "{\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":4000000000,\"function\":{\"name\":\"bash\"}}]}}]}";
    try applyFrame(arena, arena, payload, &result, &calls, &out_buf);
    try std.testing.expectEqual(@as(usize, 0), calls.items.len);
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
    try std.testing.expectEqual(style_mod.PonytailLevel.ultra, style.ponytail);
}
