//! microagent: a tiny OpenAI-compatible coding agent, sized for gauntlet loops.
//!
//! One binary, one loop: stream a chat completion, run whatever tools it asks
//! for, feed the results back, stop when it stops calling tools. Tool work is
//! delegated to the real tools on PATH (ripgrep, ast-grep, git, compilers),
//! so there is no built-in search or patch engine here to keep in sync with them.

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

/// What the command line asked the binary to do before it does any work.
const Action = enum { run, help, version };

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
    /// Reply-style config to read. Set by --config or MICROAGENT_CONFIG, else
    /// $HOME/.microagent/config.toml. A missing file is not an error.
    config: []const u8 = "",
    /// What the command line asked for. `--help` and `--version` stop the
    /// parse where they appear, before any option value is needed.
    action: Action = .run,
};

/// `args` grows in place as the provider streams the arguments in fragments.
/// It is a buffer, not a string that is re-spelled per fragment: a large
/// `write` arrives as thousands of deltas, and copying what has accumulated so
/// far on every one of them is quadratic in the size of the call.
const ToolCall = struct {
    id: []u8,
    name: []u8,
    /// Grown by appending each streamed fragment. A provider splits one
    /// call's `arguments` across many frames, so this is the buffer that a
    /// per-frame re-copy made quadratic in the argument length.
    args: std.ArrayList(u8) = .empty,
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

/// The five counters, in the order every JSON usage writer here emits them: a
/// reader takes them by name, so one place spells the key list.
const usage_fields = "\"prompt_tokens\":{d},\"cached_tokens\":{d},\"completion_tokens\":{d},\"reasoning_tokens\":{d},\"total_tokens\":{d}";

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

    debug_enabled = debugEnabled(init.environ_map);

    // `microagent update` is a subcommand, not a prompt: it is dispatched
    // before the agent's own flags so it never needs an API key.
    if (args.items.len > 1 and std.mem.eql(u8, args.items[1], "update")) {
        std.process.exit(update_mod.run(io, gpa, init.arena.allocator(), init.environ_map, args.items[2..]));
    }

    var opts: Options = .{};
    if (envValue(init.environ_map, "MICROAGENT_MODEL")) |v| opts.model = v;
    if (envValue(init.environ_map, "MICROAGENT_BASE_URL")) |v| opts.base_url = v;
    if (envValue(init.environ_map, "MICROAGENT_REASONING_EFFORT")) |v| opts.reasoning_effort = reasoningEffort(io, v);
    if (envValue(init.environ_map, "MICROAGENT_MAX_TURNS")) |v| opts.max_turns = turnCeiling(io, "MICROAGENT_MAX_TURNS", v);
    opts.ca_bundle = net.caBundlePath(init.environ_map);
    if (envValue(init.environ_map, "MICROAGENT_BUDGET_SECONDS")) |v|
        opts.budget_s = std.fmt.parseInt(u64, v, 10) catch
            return configError(io, "MICROAGENT_BUDGET_SECONDS must be a number of seconds, got '{s}'", .{v});
    opts.session_dir = sessionDir(init);

    var err_buf: [512]u8 = undefined;
    if (parseArgs(io, &err_buf, args.items[1..], &opts)) |msg| return usageError(io, "{s}", .{msg});
    switch (opts.action) {
        .help => {
            std.Io.File.stdout().writeStreamingAll(io, help_text) catch {};
            return;
        },
        .version => {
            std.Io.File.stdout().writeStreamingAll(io, "microagent " ++ version ++ "\n") catch {};
            return;
        },
        .run => {},
    }

    if (opts.prompt.len == 0) return usageError(io, "no prompt: pass it as an argument or with --print", .{});
    opts.api_key = resolveKey(init, opts.api_key);
    if (opts.api_key.len == 0) return configError(io, "no API key: pass --api-key or set {s}", .{key_var_names});

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    net.loadCaBundle(&client, io, gpa, opts.ca_bundle, init.arena.allocator());

    // The conversation is kept as the literal JSON array the API wants, so a
    // message is appended once, in the wire format, with no model in between.
    var msgs: std.ArrayList(u8) = .empty;
    defer msgs.deinit(gpa);
    try msgs.appendSlice(gpa, "[");
    const style = loadStyle(io, init, init.arena.allocator(), opts.config);
    const reply_style = try style.ruleset(init.arena.allocator());
    const prompt = if (reply_style.len == 0)
        system_prompt
    else
        try std.fmt.allocPrint(init.arena.allocator(), "{s}\n\n{s}", .{ system_prompt, reply_style });
    try appendMessage(gpa, &msgs, "system", prompt);
    try appendMessage(gpa, &msgs, "user", opts.prompt);

    run(&client, io, gpa, init.arena.allocator(), opts, &msgs) catch |err| {
        const msg = try std.fmt.allocPrint(init.arena.allocator(), "microagent: {s}\n", .{@errorName(err)});
        std.Io.File.stderr().writeStreamingAll(io, msg) catch {};
        std.process.exit(1);
    };
}

/// Injected when the wall-clock budget runs out: the model has done its
/// reading, so it is asked for the edit rather than another investigation.
const final_push =
    "Your budget is exhausted. Apply the single most important fix now, using what you already " ++
    "know, with one edit or one write. Do not search again. Then stop.";

const help_text =
    \\microagent - tiny OpenAI-compatible coding agent
    \\
    \\usage: microagent [options] "<prompt>"
    \\
    \\  -p, --print <prompt>   task to run (also accepted as a bare argument)
    \\  -m, --model <model>    model id (env MICROAGENT_MODEL)
    \\  -b, --base-url <url>   OpenAI-compatible base url (env MICROAGENT_BASE_URL)
    \\  -k, --api-key <key>    api key (env MICROAGENT_API_KEY, OPENAI_API_KEY,
    \\                         OPENROUTER_API_KEY, DEEPSEEK_API_KEY)
    \\      --max-turns <n>    tool-loop turn ceiling, at least 1
    \\                         (env MICROAGENT_MAX_TURNS, default 100)
    \\      --config <file>    reply-style TOML config (env MICROAGENT_CONFIG,
    \\                         default ~/.microagent/config.toml)
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
    \\every long flag also takes --flag=value. A flag wins over the environment
    \\variable for the same option.
    \\
    \\reply style (MICROAGENT_CAVEMAN / MICROAGENT_PONYTAIL, or the same two keys
    \\in the config named above):
    \\  MICROAGENT_CAVEMAN     how terse the reply is: off, lite, full, ultra,
    \\                         wenyan-lite, wenyan-full, wenyan-ultra
    \\                         (default ultra)
    \\  MICROAGENT_PONYTAIL    how lazy the code is: off, lite, full, ultra
    \\                         (default full)
    \\
    \\  MICROAGENT_SESSION_DIR where the per-response JSONL session log goes
    \\                         (default ~/.microagent/sessions; empty writes none)
    \\
    \\subcommand:
    \\  update [-c|--check] [--repo owner/name]
    \\                         replace this binary with the latest GitHub
    \\                         release after verifying its .sha256 sidecar
    \\                         (--check only reports; GITHUB_TOKEN lifts the
    \\                         API rate limit). "microagent update --help" has
    \\                         the details.
    \\
    \\exit status: 0 the run finished, 1 the run failed, 2 the command line was
    \\wrong.
    \\
    \\MDEBUG=1                 trace a stuck stream on stderr. 0, off, no,
    \\                         false and an empty value all leave it off.
    \\
    \\A variable set to an empty string is not a value: MICROAGENT_MODEL,
    \\MICROAGENT_BASE_URL, MICROAGENT_REASONING_EFFORT, MICROAGENT_BUDGET_SECONDS,
    \\MICROAGENT_MAX_TURNS and MDEBUG keep their defaults, and MICROAGENT_CA_BUNDLE
    \\and MICROAGENT_CAVEMAN/PONYTAIL fall through to whatever comes next.
    \\
;

/// A command line that does not parse: one line saying which argument was
/// wrong, then the help text. Both go to stderr, so a script reading stdout
/// gets nothing from a failed invocation. Exit 2, the conventional code for a
/// usage error.
fn usageError(io: Io, comptime fmt: []const u8, args: anytype) noreturn {
    const msg = std.fmt.allocPrint(std.heap.page_allocator, "microagent: " ++ fmt ++ "\n", args) catch
        "microagent: bad arguments\n";
    die(io, msg);
}

/// A configuration value the program cannot use, whether it arrived on a flag
/// or in the environment. Same exit code and the same help text as a bad
/// argument, but the message names the value and the file or variable it came
/// from, because a bad env var is otherwise invisible at the call site.
fn configError(io: Io, comptime fmt: []const u8, args: anytype) noreturn {
    const msg = std.fmt.allocPrint(std.heap.page_allocator, "microagent: " ++ fmt ++ "\n", args) catch
        "microagent: bad configuration\n";
    die(io, msg);
}

fn die(io: Io, msg: []const u8) noreturn {
    std.Io.File.stderr().writeStreamingAll(io, msg) catch {};
    std.Io.File.stderr().writeStreamingAll(io, help_text) catch {};
    std.process.exit(2);
}

/// The value of an environment variable, or null when it is not set or is set
/// to an empty string. A wrapper that builds its own environment exports the
/// name with nothing behind it, and an empty string read as a value sends
/// `"model": ""` to the provider and loses the default; every other variable
/// here already treats empty as unset.
fn envValue(env: *const std.process.Environ.Map, name: []const u8) ?[]const u8 {
    const v = env.get(name) orelse return null;
    return if (v.len == 0) null else v;
}

/// The debugging switch, on unless the variable is set to something that reads
/// as off. Set-at-all was the old reading, which turned the trace on for a
/// wrapper that exports the name to pass a flag it has not set yet.
fn debugEnabled(env: *const std.process.Environ.Map) bool {
    const v = envValue(env, "MDEBUG") orelse return false;
    if (std.ascii.eqlIgnoreCase(v, "0") or std.ascii.eqlIgnoreCase(v, "off") or
        std.ascii.eqlIgnoreCase(v, "no") or std.ascii.eqlIgnoreCase(v, "false")) return false;
    return true;
}

/// The levels the help text names for reasoning.effort, checked where the
/// value is set. An unknown level reaches the provider as a 400 and costs a
/// whole turn to learn that a level was mistyped.
const reasoning_efforts = [_][]const u8{ "minimal", "low", "medium", "high", "none" };
const reasoning_effort_names = "minimal, low, medium, high, none";

fn reasoningEffort(io: Io, value: []const u8) []const u8 {
    const v = std.mem.trim(u8, value, " \t\r\n");
    for (reasoning_efforts) |level| if (std.mem.eql(u8, v, level)) return v;
    return configError(io, "reasoning effort '{s}' is not one of: {s}", .{ value, reasoning_effort_names });
}

/// The tool-loop ceiling from a flag or a variable, checked the same way on
/// both paths. Zero is refused: a run with no turns sends no request, prints no
/// answer and no usage line, and exits 0, which a harness reads as a finished
/// review rather than as a ceiling that was set wrong.
fn turnCeiling(io: Io, from: []const u8, value: []const u8) usize {
    const n = std.fmt.parseInt(usize, std.mem.trim(u8, value, " \t\r\n"), 10) catch
        return configError(io, "{s} must be a number, got '{s}'", .{ from, value });
    if (n == 0) return configError(io, "{s} must be at least 1", .{from});
    return n;
}

const key_var_names = "MICROAGENT_API_KEY, OPENAI_API_KEY, OPENROUTER_API_KEY or DEEPSEEK_API_KEY";

fn clip(s: []const u8) []const u8 {
    return s[0..@min(s.len, 80)];
}

/// Reads the arguments after the program name into `opts`, formatting any
/// message that names a bad argument into `buf`. Returns null when
/// they parse, or a message naming what was wrong, which `usageError` prints
/// with the help text before exiting 2. A reasoning level and a turn ceiling are
/// refused where they are set, through `configError`. Every long flag also takes
/// `--flag=value`, the form `microagent update` already took, so both commands
/// spell an option the same way. `--help` and `--version` win wherever they
/// appear, and stop the parse there.
fn parseArgs(io: Io, buf: []u8, argv: []const []const u8, opts: *Options) ?[]const u8 {
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        // `--flag=value` splits into a name and an joined value; a short flag
        // never does, so `-p=x` stays the unknown argument it is.
        var name = arg;
        var joined: ?[]const u8 = null;
        if (arg.len > 2 and arg[0] == '-' and arg[1] == '-') {
            if (std.mem.indexOfScalar(u8, arg, '=')) |eq| {
                name = arg[0..eq];
                joined = arg[eq + 1 ..];
            }
        }
        if (isFlag(name, "-V", "--version")) {
            opts.action = .version;
            return null;
        } else if (isFlag(name, "-h", "--help")) {
            opts.action = .help;
            return null;
        } else if (isFlag(name, "-p", "--print")) {
            const v = joined orelse flagValue(argv, i) orelse return "--print needs a prompt";
            if (v.len == 0) return "--print needs a prompt";
            if (setPrompt(buf, opts, v)) |m| return m;
            if (joined == null) i += 1;
        } else if (isFlag(name, "-m", "--model")) {
            const v = joined orelse flagValue(argv, i) orelse return "--model needs a model id";
            if (v.len == 0) return "--model needs a model id";
            opts.model = v;
            if (joined == null) i += 1;
        } else if (isFlag(name, "-b", "--base-url")) {
            const v = joined orelse flagValue(argv, i) orelse return "--base-url needs a url";
            if (v.len == 0) return "--base-url needs a url";
            opts.base_url = v;
            if (joined == null) i += 1;
        } else if (isFlag(name, "-k", "--api-key")) {
            const v = joined orelse flagValue(argv, i) orelse return "--api-key needs a key";
            if (v.len == 0) return "--api-key needs a key";
            opts.api_key = v;
            if (joined == null) i += 1;
        } else if (std.mem.eql(u8, name, "--ca-bundle")) {
            const v = joined orelse flagValue(argv, i) orelse return "--ca-bundle needs a file";
            if (v.len == 0) return "--ca-bundle needs a file";
            opts.ca_bundle = v;
            if (joined == null) i += 1;
        } else if (std.mem.eql(u8, name, "--config")) {
            const v = joined orelse flagValue(argv, i) orelse return "--config needs a file";
            if (v.len == 0) return "--config needs a file";
            opts.config = v;
            if (joined == null) i += 1;
        } else if (std.mem.eql(u8, name, "--reasoning-effort")) {
            const v = joined orelse flagValue(argv, i) orelse return "--reasoning-effort needs a level";
            if (v.len == 0) return "--reasoning-effort needs a level";
            opts.reasoning_effort = reasoningEffort(io, v);
            if (joined == null) i += 1;
        } else if (std.mem.eql(u8, name, "--budget")) {
            const v = joined orelse flagValue(argv, i) orelse return "--budget needs a number of seconds";
            if (v.len == 0) return "--budget needs a number of seconds";
            opts.budget_s = std.fmt.parseInt(u64, v, 10) catch
                return std.fmt.bufPrint(buf, "--budget must be a number of seconds, got '{s}'", .{v}) catch "bad --budget";
            if (joined == null) i += 1;
        } else if (std.mem.eql(u8, name, "--max-turns")) {
            const v = joined orelse flagValue(argv, i) orelse return "--max-turns needs a number";
            if (v.len == 0) return "--max-turns needs a number";
            opts.max_turns = turnCeiling(io, "--max-turns", v);
            if (joined == null) i += 1;
        } else if (arg.len > 0 and arg[0] != '-') {
            // A bare argument is the prompt. gauntlet's custom-agent
            // definitions insert the model flags before the prompt, so
            // "microagent -p {prompt}" would hand the model flag to -p;
            // taking the prompt positionally makes the order irrelevant.
            if (setPrompt(buf, opts, arg)) |m| return m;
        } else {
            return std.fmt.bufPrint(buf, "unknown or incomplete argument '{s}'", .{arg}) catch "bad arguments";
        }
    }
    return null;
}

/// The value that follows a flag, or null when the flag ends the command line.
fn flagValue(argv: []const []const u8, i: usize) ?[]const u8 {
    return if (i + 1 < argv.len) argv[i + 1] else null;
}

fn isFlag(name: []const u8, short: []const u8, long: []const u8) bool {
    return std.mem.eql(u8, name, short) or std.mem.eql(u8, name, long);
}

/// The prompt is accepted twice over, as `-p` and as a bare word, so the two
/// spellings can collide. Take the first and say so on the second rather than
/// silently running whichever came last.
fn setPrompt(buf: []u8, opts: *Options, value: []const u8) ?[]const u8 {
    if (opts.prompt.len != 0)
        return std.fmt.bufPrint(buf, "prompt given twice: '{s}' and '{s}'", .{ clip(opts.prompt), clip(value) }) catch
            "prompt given twice";
    opts.prompt = value;
    return null;
}

fn resolveKey(init: std.process.Init, given: []const u8) []const u8 {
    if (given.len > 0) return given;
    for (key_vars) |n| {
        if (envValue(init.environ_map, n)) |v| return v;
    }
    if (readSecret(init, "openrouter")) |v| return v;
    return "";
}

/// In the order they are tried, and the order the help text and README name
/// them: the project's own variable first, then the provider's.
const key_vars = [_][]const u8{ "MICROAGENT_API_KEY", "OPENAI_API_KEY", "OPENROUTER_API_KEY", "DEEPSEEK_API_KEY" };

fn readSecret(init: std.process.Init, name: []const u8) ?[]const u8 {
    const home = init.environ_map.get("HOME") orelse return null;
    const path = std.fmt.allocPrint(init.arena.allocator(), "{s}/.secrets/{s}", .{ home, name }) catch return null;
    const raw = std.Io.Dir.cwd().readFileAlloc(init.io, path, init.arena.allocator(), .limited(4096)) catch return null;
    return std.mem.trim(u8, raw, " \t\r\n");
}

/// The reply-style levels for this run, from the TOML config named by
/// --config, MICROAGENT_CONFIG or `$HOME/.microagent/config.toml`, then the
/// MICROAGENT_CAVEMAN / MICROAGENT_PONYTAIL overrides, then the built-in
/// defaults. A missing file, an unreadable one, or an unknown key costs the run
/// nothing: the levels that were understood still apply.
fn loadStyle(io: Io, init: std.process.Init, arena: std.mem.Allocator, config: []const u8) style_mod.Style {
    var style: style_mod.Style = .{};
    const path = styleConfigPath(init, arena, config);
    const text: ?[]const u8 = if (path) |p|
        std.Io.Dir.cwd().readFileAlloc(io, p, arena, .limited(max_config_bytes)) catch null
    else
        null;
    if (resolveStyle(&style, text, envValue(init.environ_map, "MICROAGENT_CAVEMAN"), envValue(init.environ_map, "MICROAGENT_PONYTAIL"))) |unknown| {
        if (unknown.from_config) {
            if (unknown.bad_value)
                net.note(io, arena, "microagent: config {s}: '{s}' is not a level; keeping the default\n", .{ path.?, unknown.key })
            else
                net.note(io, arena, "microagent: config {s}: '{s}' is not a key this file uses; keeping the default\n", .{ path.?, unknown.key });
        } else {
            net.note(io, arena, "microagent: {s} is not a level; keeping the default\n", .{unknown.key});
        }
    }
    return style;
}

/// Where the style config is read from: --config, else MICROAGENT_CONFIG, else
/// `$HOME/.microagent/config.toml`. An empty MICROAGENT_CONFIG turns the
/// file off, as does a home that is not there.
fn styleConfigPath(init: std.process.Init, arena: std.mem.Allocator, config: []const u8) ?[]const u8 {
    if (config.len > 0) return std.fs.path.resolve(arena, &.{config}) catch config;
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

/// The agent loop: keep asking until the model stops calling tools.
fn run(
    client: *std.http.Client,
    io: Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    opts: Options,
    msgs: *std.ArrayList(u8),
) !void {
    const started = Io.Timestamp.now(io, .awake).nanoseconds;
    const session = openSession(io, arena, opts);
    defer closeSession(io, session);
    // What one turn allocates from the wire down -- the request body (a full
    // copy of the conversation), the streamed content, the tool results --
    // is dead once that turn's messages are appended. The run arena is never
    // freed, so a run arena for all of it would retain one copy of the whole
    // conversation per turn; a per-turn arena reset at the top of the loop
    // holds the peak at one turn's worth.
    var turn_state = std.heap.ArenaAllocator.init(arena);
    defer turn_state.deinit();
    const turn_arena = turn_state.allocator();
    var turn: usize = 0;
    var usage: Usage = .{};
    while (turn < opts.max_turns) : (turn += 1) {
        _ = turn_state.reset(.retain_capacity);
        if (opts.budget_s) |budget| {
            const spent_s = @divTrunc(Io.Timestamp.now(io, .awake).nanoseconds - started, std.time.ns_per_s);
            if (spent_s >= budget) {
                // Stop in the middle of the work, or stop after one last push
                // that is told to edit? A review that ran out of time with
                // nothing changed is worth less than one that ran out of time
                // with a small diff, and the model has already done the reading.
                net.note(io, arena, "microagent: budget of {d}s reached after {d} turn(s); one final turn\n", .{ budget, turn });
                try appendMessage(gpa, msgs, "user", final_push);
                const body = try buildBody(turn_arena, opts, msgs.items);
                const asked = Io.Timestamp.now(io, .awake).nanoseconds;
                var result = try streamChat(client, io, turn_arena, opts, body);
                try finishTurn(io, turn_arena, gpa, msgs, &result, &usage);
                writeSessionRecord(io, turn_arena, session, elapsedMs(io, asked), &result);
                return;
            }
        }
        // The ceiling is announced on the turn it applies to, before it is
        // spent, so a truncated answer is never the last thing on stdout with no
        // word about the ceiling that cut it.
        if (turn + 1 == opts.max_turns)
            net.note(io, arena, "microagent: last turn (--max-turns {d})\n", .{opts.max_turns});
        try compactMessages(gpa, msgs, turn_arena);
        const body = try buildBody(turn_arena, opts, msgs.items);
        const asked = Io.Timestamp.now(io, .awake).nanoseconds;
        var result = try streamChat(client, io, turn_arena, opts, body);
        try finishTurn(io, turn_arena, gpa, msgs, &result, &usage);
        writeSessionRecord(io, turn_arena, session, elapsedMs(io, asked), &result);
        if (result.calls.items.len == 0) return;
    }
    net.note(io, arena, "microagent: stopped at the --max-turns ceiling ({d})\n", .{opts.max_turns});
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

/// How many names `createSessionLog` tries before it gives the run no log. The
/// name space only runs out when the clock stamp is degenerate, and losing a
/// log costs the run nothing.
const session_name_attempts = 8;

/// This run's log, under a name nothing already holds.
///
/// The wall clock is settable, so its stamp is not a claim on a file: two runs
/// can read the same nanosecond, and one that is re-launched shortly after a
/// previous one can. Creating the file without `exclusive` would truncate the
/// log already sitting there, so a second run would erase the first run's
/// usage records, which is the whole reason the log exists. Every name is
/// opened exclusively and a taken one moves to the next, so a repeat run writes
/// beside the first rather than over it.
fn createSessionLog(io: Io, arena: std.mem.Allocator, session_dir: []const u8, stamp: i128) ?Io.File {
    var attempt: usize = 0;
    while (attempt < session_name_attempts) : (attempt += 1) {
        var suffix_buf: [4]u8 = undefined;
        const suffix = if (attempt == 0) "" else std.fmt.bufPrint(&suffix_buf, "-{d}", .{attempt}) catch return null;
        const path = std.fmt.allocPrint(arena, "{s}/{d}{s}.jsonl", .{ session_dir, stamp, suffix }) catch return null;
        return std.Io.Dir.createFileAbsolute(io, path, .{ .exclusive = true }) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => return null,
        };
    }
    return null;
}

fn openSession(io: Io, arena: std.mem.Allocator, opts: Options) ?Session {
    if (opts.session_dir.len == 0) return null;
    // Every record names the directory it ran in. That is what attributes the
    // record to one review: the store is machine-wide, and a monitor skips a
    // record that names no directory rather than billing it to whichever
    // watcher happens to read the store. It comes from the run arena because a
    // directory that is resolved and then not used, by a log that could not be
    // opened, has no owner to free it.
    const cwd = std.Io.Dir.cwd().realPathFileAlloc(io, ".", arena) catch return null;
    std.Io.Dir.cwd().createDirPath(io, opts.session_dir) catch return null;
    const stamp = Io.Clock.real.now(io).nanoseconds;
    const file = createSessionLog(io, arena, opts.session_dir, stamp) orelse return null;
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
    try w.print(",\"elapsed_ms\":{d},\"usage\":{{" ++ usage_fields, .{
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
    var unparsable: usize = 0;
    while (!done) {
        // A read that fails mid-stream is a dropped connection, not an end of
        // response. The cause is named before it propagates, because by the
        // time the run's error line is written the only record of what arrived
        // is this one.
        const n = reader.readSliceShort(&chunk) catch |err| {
            net.note(io, arena, "microagent: reading the completion stream from {s} failed after {d} byte(s) of content and {d} tool call(s): {s}\n", .{ url, result.content.items.len, calls.items.len, @errorName(err) });
            return err;
        };
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
            try applyFrame(frame_arena, arena, payload, &result, &calls, &out_buf, &unparsable);
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

    if (unparsable > 0)
        net.note(io, arena, "microagent: {d} frame(s) of the completion stream from {s} were not JSON and their content is not in this turn\n", .{ unparsable, url });
    // The provider closes a finished stream with a `[DONE]` frame. A stream
    // that ends without one was cut off partway, and the truncated turn below
    // would otherwise be appended as a complete answer: a turn that lost its
    // tail, tool calls and all, reads as one the model finished on purpose.
    if (truncatedNotice(arena, url, done, result.content.items.len, calls.items.len)) |notice| {
        net.note(io, arena, "{s}\n", .{notice});
        return error.StreamTruncated;
    }
    if (result.content.items.len > 0) try out_buf.append(arena, '\n');
    flushOut(io, &out_buf);
    result.calls = calls;
    dropNamelessCalls(&result.calls);
    return result;
}

/// Why a stream that ended without `[DONE]` is not a finished turn, in the
/// words the operator reads. Null once the terminator has arrived, whatever the
/// turn holds. Separated from the stream loop so the rule is testable without
/// a provider on the other end of a socket.
fn truncatedNotice(
    arena: std.mem.Allocator,
    url: []const u8,
    done: bool,
    content_len: usize,
    calls_len: usize,
) ?[]const u8 {
    if (done) return null;
    return std.fmt.allocPrint(
        arena,
        "microagent: the completion stream from {s} ended without [DONE] after {d} byte(s) of " ++
            "content and {d} tool call(s); the turn is not complete",
        .{ url, content_len, calls_len },
    ) catch "microagent: the completion stream ended without [DONE]; the turn is not complete";
}

/// A provider that skips a tool-call index leaves an empty slot where `applyFrame`
/// sized the list by index. A nameless call is not a call: it dispatches as
/// `unknown tool ''` and it goes back to the provider as an assistant message
/// carrying a function with no name, which the next request rejects. The gap is
/// dropped here rather than sent on.
fn dropNamelessCalls(calls: *std.ArrayList(ToolCall)) void {
    var kept: usize = 0;
    for (calls.items) |*call| {
        if (call.name.len == 0) continue;
        calls.items[kept] = call.*;
        kept += 1;
    }
    calls.shrinkRetainingCapacity(kept);
}

/// Folds one SSE payload into the response being built.
///
/// `scratch` is reset by the caller after every frame, so nothing parsed out of
/// it may survive: strings that do are copied into `arena`, which lives for the
/// whole run.
///
/// `unparsable` counts the frames that were not JSON. A frame the parser cannot
/// read holds content and tool-call arguments the turn will not have, so it is
/// counted and the caller says so; dropping it without a count leaves a
/// response that is short and looks complete.
fn applyFrame(
    scratch: std.mem.Allocator,
    arena: std.mem.Allocator,
    payload: []const u8,
    result: *ChatResult,
    calls: *std.ArrayList(ToolCall),
    out_buf: *std.ArrayList(u8),
    unparsable: *usize,
) !void {
    const parsed = std.json.parseFromSlice(std.json.Value, scratch, payload, .{}) catch {
        unparsable.* += 1;
        return;
    };
    const root = parsed.value;
    if (root != .object) {
        unparsable.* += 1;
        return;
    }

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
            });
            if (str(tc.object.get("id"))) |v| {
                if (!std.mem.eql(u8, calls.items[idx].id, v)) calls.items[idx].id = try arena.dupe(u8, v);
            }
            if (tc.object.get("function")) |f| if (f == .object) {
                if (str(f.object.get("name"))) |v| {
                    if (!std.mem.eql(u8, calls.items[idx].name, v)) calls.items[idx].name = try arena.dupe(u8, v);
                }
                if (str(f.object.get("arguments"))) |v| try calls.items[idx].args.appendSlice(arena, v);
            };
        }
    };
}

/// Ceilings shared by every tool that shells out: how long a read-only
/// subprocess may run, and how much of its stderr is worth keeping. stdout gets
/// `max_tool_output * 4` everywhere, and is trimmed to `max_tool_output` by
/// `clamp` before it reaches the model.
const tool_timeout_ms: u64 = 60_000;
const tool_stderr_limit: usize = 4096;

fn runToolProcess(
    io: Io,
    arena: std.mem.Allocator,
    argv: []const []const u8,
    stderr_limit: usize,
) !Captured {
    const res = try runCapped(io, arena, argv, max_tool_output * 4, durationMs(tool_timeout_ms));
    return .{
        .stdout = res.stdout,
        .stderr = @constCast(clamp(res.stderr, stderr_limit)),
        .term = res.term,
    };
}

/// A tool that delegates to a binary already on PATH: the caller builds the
/// argv, and the failure text, the empty result and the two output streams are
/// handled the same way for each of them.
fn runSearchTool(io: Io, arena: std.mem.Allocator, argv: []const []const u8, what: []const u8) ![]u8 {
    const res = runToolProcess(io, arena, argv, tool_stderr_limit) catch |err|
        return std.fmt.allocPrint(arena, "error: {s} failed: {s}", .{ what, @errorName(err) });
    if (res.stdout.len > 0) return res.stdout;
    if (res.stderr.len > 0) return res.stderr;
    return std.fmt.allocPrint(arena, "(no matches)", .{});
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

    const res = runToolProcess(io, arena, argv.items, tool_stderr_limit) catch |err|
        return std.fmt.allocPrint(arena, "error: git {s} failed: {s}", .{ cmd, @errorName(err) });
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
            try writeJsonString(msg.writer(), call.args.items);
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
            try writeJsonString(tool_msg.writer(), try toolResult(arena, output));
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
    try w.print(usage_fields, .{
        usage.prompt, usage.cached, usage.completion, usage.reasoning, usage.total,
    });
    try w.writeAll("}}\n");
    std.Io.File.stdout().writeStreamingAll(io, usage_line.items()) catch {};
}

fn runTool(io: Io, arena: std.mem.Allocator, call: ToolCall) ![]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, arena, call.args.items, .{}) catch
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

/// A one-line tool gutter on stderr, the shape gauntlet recognizes. The name
/// and the detail are the provider's own text and may carry a newline or an
/// escape sequence, either of which breaks the one-line-per-call shape a reader
/// parses, so control characters are written as their two-character escapes.
fn noteToolCall(io: Io, arena: std.mem.Allocator, name: []const u8, args: std.json.ObjectMap) void {
    // The interesting argument is not the same one for every tool: a structural
    // search is identified by its pattern, a bash call by its command.
    const detail = if (std.mem.eql(u8, name, "ast"))
        (str(args.get("pattern")) orelse "")
    else
        (str(args.get("command")) orelse str(args.get("pattern")) orelse str(args.get("path")) orelse "");
    var buf: std.ArrayList(u8) = .empty;
    buf.appendSlice(arena, "\u{23fa} ") catch return;
    writeGutterText(arena, &buf, clamp(name, 40)) catch return;
    buf.append(arena, ' ') catch return;
    writeGutterText(arena, &buf, clamp(detail, 120)) catch return;
    buf.append(arena, '\n') catch return;
    std.Io.File.stderr().writeStreamingAll(io, buf.items) catch {};
}

/// Gutter text with every C0 control and DEL written as `\xNN`, and bytes that
/// are not valid UTF-8 written as U+FFFD, so one call stays one line.
const hex_digits = "0123456789abcdef";

fn writeGutterText(gpa: std.mem.Allocator, buf: *std.ArrayList(u8), s: []const u8) !void {
    var i: usize = 0;
    var start: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (c < 0x20 or c == 0x7f) {
            try buf.appendSlice(gpa, s[start..i]);
            try buf.appendSlice(gpa, &.{ '\\', 'x', hex_digits[c >> 4], hex_digits[c & 0x0f] });
            i += 1;
            start = i;
            continue;
        }
        const len: usize = if (c < 0x80) 1 else utf8SequenceLen(s, i);
        if (len == 0) {
            try buf.appendSlice(gpa, s[start..i]);
            try buf.appendSlice(gpa, "\u{fffd}");
            i += 1;
            start = i;
            continue;
        }
        i += len;
    }
    try buf.appendSlice(gpa, s[start..i]);
}

fn toolBash(io: Io, arena: std.mem.Allocator, args: std.json.ObjectMap) ![]u8 {
    const command = str(args.get("command")) orelse return std.fmt.allocPrint(arena, "error: missing command", .{});
    const timeout_ms: u64 = if (args.get("timeout_ms")) |v| num(v) else 120_000;
    const capture_limit = max_tool_output * 4;
    const res = runCapped(io, arena, &.{ "/bin/sh", "-c", command }, capture_limit, durationMs(timeout_ms)) catch |err| switch (err) {
        error.Timeout => return std.fmt.allocPrint(arena, "error: command timed out after {d}ms", .{timeout_ms}),
        else => return std.fmt.allocPrint(arena, "error: {s}", .{@errorName(err)}),
    };
    var buf: std.ArrayList(u8) = .empty;
    if (res.stdout.len > 0) try buf.appendSlice(arena, res.stdout);
    if (res.stderr.len > 0) {
        if (buf.items.len > 0) try buf.appendSlice(arena, "\n");
        try buf.appendSlice(arena, res.stderr);
    }
    // Output the model acts on is cut at the cap, so say so rather than letting
    // a half-read build log or diff read as the whole one.
    if (atCaptureLimit(res, capture_limit)) {
        if (buf.items.len > 0) try buf.appendSlice(arena, "\n");
        try buf.appendSlice(arena, "[output truncated at the tool's cap]");
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
    return runSearchTool(io, arena, argv.items, "ripgrep");
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

    return runSearchTool(io, arena, argv.items, "ast-grep");
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

/// Writes `s` as a JSON string. Text reaching here came from outside the
/// process: a tool result, a file's bytes, a working directory, an argv entry.
/// Bytes above ASCII are copied when they form a UTF-8 sequence and become
/// U+FFFD when they do not, because a lone byte is not a JSON string and one
/// invalid sequence in a tool result fails the whole request with a 400.
fn writeJsonString(w: *Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    var i: usize = 0;
    var start: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (jsonNeedsEscape(c)) {
            try w.writeAll(s[start..i]);
            switch (c) {
                '"' => try w.writeAll("\\\""),
                '\\' => try w.writeAll("\\\\"),
                '\n' => try w.writeAll("\\n"),
                '\r' => try w.writeAll("\\r"),
                '\t' => try w.writeAll("\\t"),
                0x08 => try w.writeAll("\\b"),
                0x0c => try w.writeAll("\\f"),
                else => try w.print("\\u{x:0>4}", .{c}),
            }
            i += 1;
            start = i;
            continue;
        }
        const len: usize = if (c < 0x80) 1 else utf8SequenceLen(s, i);
        if (len == 0) {
            try w.writeAll(s[start..i]);
            try w.writeAll("\u{fffd}");
            i += 1;
            start = i;
            continue;
        }
        i += len;
    }
    try w.writeAll(s[start..i]);
    try w.writeByte('"');
}

fn jsonNeedsEscape(c: u8) bool {
    return c < 0x20 or c == '"' or c == '\\';
}

/// The length of the UTF-8 sequence starting at `i`, or 0 where the bytes are
/// not one: a bad lead byte, a truncated tail, or an overlong or surrogate
/// encoding all read as a replacement rather than being copied through.
fn utf8SequenceLen(s: []const u8, i: usize) usize {
    const want = std.unicode.utf8ByteSequenceLength(s[i]) catch return 0;
    const end = i + want;
    if (end > s.len) return 0;
    if (!std.unicode.utf8ValidateSlice(s[i..end])) return 0;
    return want;
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

/// Bytes read from a child pipe per operation. Both pipes are drained in one
/// batch, so neither can fill up and wedge the child while the other is read.
const capture_chunk = 8 * 1024;

/// What a capped child produced: the first `limit` bytes of each stream, and the
/// status it exited with.
const Captured = struct {
    stdout: []u8,
    stderr: []u8,
    term: std.process.Child.Term,
};

/// Runs `argv` and keeps the first `limit` bytes of each stream.
///
/// `std.process.run` answers `error.StreamTooLong` and throws away everything it
/// had read, so a chatty build, a ripgrep over a large tree or a `git show` of a
/// big file reached the model as a bare error with no output at all. Here the
/// bytes past the cap are drained and dropped instead: the child still runs to
/// its own end, so the exit status and the timeout keep meaning what they did.
fn runCapped(
    io: Io,
    arena: std.mem.Allocator,
    argv: []const []const u8,
    limit: usize,
    timeout: Io.Timeout,
) !Captured {
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    defer child.kill(io);

    const files = [2]Io.File{ child.stdout.?, child.stderr.? };
    var chunks: [2][capture_chunk]u8 = undefined;
    var vecs: [2][1][]u8 = .{ .{&chunks[0]}, .{&chunks[1]} };
    var out: [2]std.ArrayList(u8) = .{ .empty, .empty };

    var storage: [2]Io.Operation.Storage = undefined;
    var batch: Io.Batch = .init(&storage);
    defer batch.cancel(io);
    for (0..2) |i| batch.addAt(@intCast(i), .{ .file_read_streaming = .{
        .file = files[i],
        .data = &vecs[i],
    } });

    var draining: usize = files.len;
    var read_err: ?anyerror = null;
    while (draining > 0) {
        try batch.awaitConcurrent(io, timeout);
        while (batch.next()) |completion| {
            const i = completion.index;
            const n = completion.result.file_read_streaming catch |err| {
                // EndOfStream and Canceled are how a pipe finishes, not a fault.
                if (read_err == null and err != error.EndOfStream and err != error.Canceled)
                    read_err = err;
                draining -= 1;
                continue;
            };
            if (n > 0) {
                const taken = @min(n, limit -| out[i].items.len);
                if (taken > 0) try out[i].appendSlice(arena, chunks[i][0..taken]);
            }
            // A read may legitimately return zero bytes without ending the
            // stream, so re-arm either way.
            vecs[i] = .{&chunks[i]};
            batch.addAt(i, .{ .file_read_streaming = .{
                .file = files[i],
                .data = &vecs[i],
            } });
        }
    }

    const term = try child.wait(io);
    if (read_err) |err| return err;
    return .{ .stdout = out[0].items, .stderr = out[1].items, .term = term };
}

/// True when a stream filled the cap, so the captured bytes are the beginning of
/// the output and not all of it.
fn atCaptureLimit(captured: Captured, limit: usize) bool {
    return captured.stdout.len == limit or captured.stderr.len == limit;
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

/// One tool result as the model reads it: capped, cut on a code point
/// boundary, and marked when bytes were dropped. Without the marker a
/// truncated file or a truncated test log is indistinguishable from a complete
/// one, and the agent reasons about output it never saw.
fn toolResult(arena: std.mem.Allocator, output: []const u8) ![]const u8 {
    const kept = clamp(output, max_tool_output);
    if (kept.len == output.len) return kept;
    return std.fmt.allocPrint(arena, "{s}\n... [tool output truncated at {d} of {d} bytes]", .{
        kept, kept.len, output.len,
    });
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

// Escaping copies unescaped runs in bulk, so every byte has to survive that
// path: a byte that is neither escaped nor copied comes back short. The
// range is the ASCII one, which is what the escaper is responsible for; bytes
// above it are passed through as written, and a lone one is not valid JSON.
test "every ASCII byte survives escaping" {
    var all: [128]u8 = undefined;
    for (&all, 0..) |*c, i| c.* = @intCast(i);

    var buf = JsonBuf.init(std.testing.allocator);
    defer buf.list.deinit(std.testing.allocator);
    try writeJsonString(buf.writer(), &all);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, buf.items(), .{});
    defer parsed.deinit();
    try std.testing.expectEqualSlices(u8, &all, parsed.value.string);
}

test "the command line parses in either flag form and in any order" {
    var opts: Options = .{};
    var buf: [512]u8 = undefined;
    const argv = [_][]const u8{ "fix it", "--model=some/model", "--budget=90", "--max-turns", "7" };
    try std.testing.expectEqual(@as(?[]const u8, null), parseArgs(std.testing.io, &buf, &argv, &opts));
    try std.testing.expectEqualStrings("fix it", opts.prompt);
    try std.testing.expectEqualStrings("some/model", opts.model);
    try std.testing.expectEqual(@as(?u64, 90), opts.budget_s);
    try std.testing.expectEqual(@as(usize, 7), opts.max_turns);

    var short: Options = .{};
    const short_argv = [_][]const u8{ "-m", "some/model", "-b", "http://localhost:1234/v1", "-p", "fix it" };
    try std.testing.expectEqual(@as(?[]const u8, null), parseArgs(std.testing.io, &buf, &short_argv, &short));
    try std.testing.expectEqualStrings("some/model", short.model);
    try std.testing.expectEqualStrings("http://localhost:1234/v1", short.base_url);
    try std.testing.expectEqualStrings("fix it", short.prompt);
}

test "a wrong command line names the flag and the value it was given" {
    var opts: Options = .{};
    var buf: [512]u8 = undefined;
    try std.testing.expectEqualStrings("unknown or incomplete argument '--nope'", parseArgs(std.testing.io, &buf, &.{"--nope"}, &opts).?);
    try std.testing.expectEqualStrings("--model needs a model id", parseArgs(std.testing.io, &buf, &.{"--model"}, &opts).?);
    try std.testing.expectEqualStrings("--budget must be a number of seconds, got 'soon'", parseArgs(std.testing.io, &buf, &.{ "--budget", "soon" }, &opts).?);
    try std.testing.expectEqualStrings("prompt given twice: 'one' and 'two'", parseArgs(std.testing.io, &buf, &.{ "one", "two" }, &opts).?);
    var joined: Options = .{};
    try std.testing.expectEqualStrings("prompt given twice: 'one' and 'two'", parseArgs(std.testing.io, &buf, &.{ "-p", "one", "--print=two" }, &joined).?);
}

test "help and version win wherever they appear" {
    var opts: Options = .{};
    var buf: [512]u8 = undefined;
    try std.testing.expectEqual(@as(?[]const u8, null), parseArgs(std.testing.io, &buf, &.{ "a prompt", "--help" }, &opts));
    try std.testing.expectEqual(Action.help, opts.action);

    var v: Options = .{};
    try std.testing.expectEqual(@as(?[]const u8, null), parseArgs(std.testing.io, &buf, &.{ "-V", "--model" }, &v));
    try std.testing.expectEqual(Action.version, v.action);
}

// A tool result, a filename or a working directory may hold bytes that are not
// UTF-8: a latin-1 source file, a binary read, a directory named with a stray
// 0xFF. Copied through, one of them makes the request body unparseable and the
// provider refuses the whole turn, so each bad byte becomes U+FFFD and nothing
// else about the string changes.
test "a string that is not UTF-8 still serializes as valid JSON" {
    const cases = [_][]const u8{
        "\xff", // lone lead byte
        "caf\xe9", // latin-1 e-acute
        "\xc3", // truncated two-byte sequence
        "\xe6\x97", // truncated three-byte sequence, the CJK prefix
        "\xed\xa0\x80", // UTF-8 encoding of a surrogate half
        "\xc0\x80", // overlong encoding
        "ok\xff\xe6\x97\xa5ok",
    };
    for (cases) |raw| {
        var buf = JsonBuf.init(std.testing.allocator);
        defer buf.list.deinit(std.testing.allocator);
        try writeJsonString(buf.writer(), raw);

        var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, buf.items(), .{});
        defer parsed.deinit();
        try std.testing.expect(std.unicode.utf8ValidateSlice(parsed.value.string));
        // The valid text either side of a bad byte survives unchanged.
        if (std.mem.indexOf(u8, raw, "ok") != null)
            try std.testing.expect(std.mem.startsWith(u8, parsed.value.string, "ok"));
    }
}

test "valid multibyte text passes through the escaper unchanged" {
    const text = "日本語 \u{1f1e8}\u{1f1ed} \u{1f469}\u{200d}\u{1f4bb}";
    var buf = JsonBuf.init(std.testing.allocator);
    defer buf.list.deinit(std.testing.allocator);
    try writeJsonString(buf.writer(), text);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, buf.items(), .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings(text, parsed.value.string);
}

test "the tool gutter stays one line whatever the model sent" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var buf: std.ArrayList(u8) = .empty;
    try writeGutterText(arena, &buf, "rg -n 'foo'\nnext line\u{1b}[31mred\xff");
    try std.testing.expectEqualStrings("rg -n 'foo'\\x0anext line\\x1b[31mred\u{fffd}", buf.items);
    try std.testing.expect(std.mem.indexOfScalar(u8, buf.items, '\n') == null);
}

test "clamp keeps short strings intact" {
    try std.testing.expectEqualStrings("abc", clamp("abc", 8));
    // A string exactly at the limit is kept whole, not cut to one byte short.
    try std.testing.expectEqualStrings("abc", clamp("abc", 3));
    try std.testing.expectEqualStrings("ab", clamp("abcd", 2));
    try std.testing.expectEqualStrings("", clamp("abc", 0));
}

test "a cut never leaves half a code point in the request body" {
    // The bytes go into the JSON body verbatim, so anything clamp keeps has to
    // be a whole character: source files are full of multi-byte text and a
    // cut lands in one often enough to matter.
    const text = "caf\u{00e9} \u{1f600} fin";
    var n: usize = 0;
    while (n <= text.len) : (n += 1) {
        const kept = clamp(text, n);
        try std.testing.expect(kept.len <= n);
        try std.testing.expect(std.unicode.utf8ValidateSlice(kept));
        try std.testing.expect(std.mem.startsWith(u8, text, kept));
    }
    // The cut is at the boundary, not somewhere short of it.
    try std.testing.expectEqualStrings("caf\u{00e9} ", clamp(text, 7));
    try std.testing.expectEqualStrings("caf\u{00e9} \u{1f600}", clamp(text, 10));
    try std.testing.expectEqualStrings("", clamp("\u{1f600}", 2));
}

test "a capped tool result says how much was dropped" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const whole = try toolResult(arena, "one line");
    try std.testing.expectEqualStrings("one line", whole);

    const big = "x" ** (max_tool_output + 500);
    const cut = try toolResult(arena, big);
    try std.testing.expect(std.mem.startsWith(u8, cut, "x" ** max_tool_output));
    try std.testing.expect(std.mem.endsWith(u8, cut, "truncated at 24576 of 25076 bytes]"));
}

test "a real tool result over the cap stays a string the body can carry" {
    // The whole path, from a command that prints well past the cap to the
    // bytes that would be written into the request body.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var args: std.json.ObjectMap = .empty;
    // Five bytes per line, so the cap does not land on a character boundary: a
    // plain cut here leaves half an e-acute in the string.
    try args.put(arena, "command", .{ .string = "i=0; while [ $i -lt 5000 ]; do printf '\\303\\251a\\303\\251'; i=$((i+1)); done" });
    const output = try toolBash(std.testing.io, arena, args);
    try std.testing.expect(output.len > max_tool_output);

    const result = try toolResult(arena, output);
    try std.testing.expect(std.unicode.utf8ValidateSlice(result));
    try std.testing.expect(std.mem.indexOf(u8, result, "tool output truncated at") != null);
    // It still parses as the JSON string the body is built from.
    var jb = JsonBuf.init(arena);
    try writeJsonString(jb.writer(), result);
    const parsed = std.json.parseFromSlice(std.json.Value, arena, jb.items(), .{}) catch return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(result, parsed.value.string);
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

/// The three sinks `applyFrame` fills, on the two allocators it parses with:
/// one that lives for the whole test and one released after every frame, the
/// arrangement the stream loop uses.
const FrameSink = struct {
    run: std.heap.ArenaAllocator,
    scratch: std.heap.ArenaAllocator,
    result: ChatResult = .{},
    calls: std.ArrayList(ToolCall) = .empty,
    out_buf: std.ArrayList(u8) = .empty,
    unparsable: usize = 0,

    fn init(allocator: std.mem.Allocator) FrameSink {
        return .{
            .run = std.heap.ArenaAllocator.init(allocator),
            .scratch = std.heap.ArenaAllocator.init(allocator),
        };
    }

    fn deinit(self: *FrameSink) void {
        self.scratch.deinit();
        self.run.deinit();
    }

    /// Scratch bytes still held after the last frame fed.
    fn scratchCapacity(self: *FrameSink) usize {
        return self.scratch.queryCapacity();
    }

    fn feed(self: *FrameSink, payload: []const u8) !void {
        try applyFrame(self.scratch.allocator(), self.run.allocator(), payload, &self.result, &self.calls, &self.out_buf, &self.unparsable);
        _ = self.scratch.reset(.retain_capacity);
    }
};

test "a long stream costs the largest frame, not the sum of frames" {
    var sink = FrameSink.init(std.testing.allocator);
    defer sink.deinit();

    const payload = "{\"choices\":[{\"delta\":{\"content\":\"tok\"}}]}";
    const frames: usize = 20_000;

    // Reference point: the scratch capacity one frame needs.
    try sink.feed(payload);
    const one_frame_capacity = sink.scratchCapacity();

    var i: usize = 1;
    while (i < frames) : (i += 1) try sink.feed(payload);

    try std.testing.expectEqual(frames * 3, sink.result.content.items.len);
    try std.testing.expectEqual(frames * 3, sink.out_buf.items.len);
    // The work counter this test asserts on: scratch bytes retained after the
    // last frame. It must equal what one frame needed, not grow with the frame
    // count, which is what it did before the per-frame reset (20_000 frames'
    // worth of parse trees were kept alive in the run arena).
    try std.testing.expect(one_frame_capacity > 0);
    try std.testing.expectEqual(one_frame_capacity, sink.scratchCapacity());
}

test "tool call fragments merge by index across frames" {
    var sink = FrameSink.init(std.testing.allocator);
    defer sink.deinit();

    const frames = [_][]const u8{
        "{\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_1\",\"function\":{\"name\":\"read\",\"arguments\":\"{\\\"pa\"}}]}}]}",
        "{\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"th\\\":\\\"a.zig\\\"}\",\"arguments_end\":null}}]}}]}",
    };
    for (frames) |f| try sink.feed(f);

    try std.testing.expectEqual(@as(usize, 1), sink.calls.items.len);
    try std.testing.expectEqualStrings("call_1", sink.calls.items[0].id);
    try std.testing.expectEqualStrings("read", sink.calls.items[0].name);
    try std.testing.expectEqualStrings("{\"path\":\"a.zig\"}", sink.calls.items[0].args.items);
}

// A provider streams one call's `arguments` as many small fragments. Copying
// the whole accumulated string on every fragment made both the copy count and
// the arena bytes quadratic in the argument length, on the one path that
// cannot be re-sent cheaply. Appending keeps arena growth geometric, so the
// run arena costs a small multiple of the final length rather than a multiple
// of the square of it.
test "streamed argument fragments cost linear arena bytes" {
    const gpa = std.testing.allocator;
    var run_state = std.heap.ArenaAllocator.init(gpa);
    defer run_state.deinit();
    var frame_state = std.heap.ArenaAllocator.init(gpa);
    defer frame_state.deinit();

    var result: ChatResult = .{};
    var calls: std.ArrayList(ToolCall) = .empty;
    var out_buf: std.ArrayList(u8) = .empty;
    var unparsable: usize = 0;

    const fragments: usize = 2000;
    var i: usize = 0;
    while (i < fragments) : (i += 1) {
        const frame = try std.mem.concat(
            frame_state.allocator(),
            u8,
            &.{ "{\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"", "0123456789abcdef", "\"}}]}}]}" },
        );
        try applyFrame(frame_state.allocator(), run_state.allocator(), frame, &result, &calls, &out_buf, &unparsable);
        _ = frame_state.reset(.retain_capacity);
    }
    try std.testing.expectEqual(@as(usize, 0), unparsable);

    const total = fragments * 16;
    try std.testing.expectEqual(total, calls.items[0].args.items.len);
    // Geometric growth retains at most about twice the final length; the
    // per-frame re-copy retained a multiple of the square of it.
    try std.testing.expect(run_state.queryCapacity() < 4 * total);
}

test "usage counters land on the result" {
    var sink = FrameSink.init(std.testing.allocator);
    defer sink.deinit();

    try sink.feed(
        "{\"choices\":[{\"delta\":{}}],\"usage\":{\"prompt_tokens\":11,\"completion_tokens\":22,\"total_tokens\":33,\"completion_tokens_details\":{\"reasoning_tokens\":7}}}",
    );
    try std.testing.expectEqual(@as(u64, 11), sink.result.prompt_tokens);
    try std.testing.expectEqual(@as(u64, 22), sink.result.completion_tokens);
    try std.testing.expectEqual(@as(u64, 33), sink.result.total_tokens);
    try std.testing.expectEqual(@as(u64, 7), sink.result.reasoning_tokens);
    // Nothing in this frame says the prompt was cached, so it is a full miss.
    try std.testing.expectEqual(@as(u64, 0), sink.result.cached_tokens);
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
        var sink = FrameSink.init(std.testing.allocator);
        defer sink.deinit();
        try sink.feed(payload);
        try std.testing.expectEqual(@as(u64, 900), sink.result.prompt_tokens);
        try std.testing.expectEqual(@as(u64, 768), sink.result.cached_tokens);
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

/// A conversation past the compaction limit, in the bytes the agent appends:
/// the system and user messages, then `count` tool results of `blob` each.
fn conversationHeader(gpa: std.mem.Allocator, msgs: *std.ArrayList(u8), system: []const u8) !void {
    try msgs.appendSlice(gpa, "[");
    try appendMessage(gpa, msgs, "system", system);
    try appendMessage(gpa, msgs, "user", "fix the bug");
}

fn appendToolResults(gpa: std.mem.Allocator, msgs: *std.ArrayList(u8), count: usize, blob: []const u8) !void {
    var i: usize = 0;
    while (i < count) : (i += 1) {
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
}

test "compaction elides old tool output and keeps the recent turns" {
    const gpa = std.testing.allocator;
    var scratch_state = std.heap.ArenaAllocator.init(gpa);
    defer scratch_state.deinit();

    var msgs: std.ArrayList(u8) = .empty;
    defer msgs.deinit(gpa);

    const blob = "x" ** 8192;
    try conversationHeader(gpa, &msgs, "you are a coding agent");
    try appendToolResults(gpa, &msgs, 120, blob);
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

    const blob = "x" ** 8192;
    // Characters a JSON round trip could re-spell: quote, backslash, newline,
    // a control byte, and a non-ASCII byte.
    try conversationHeader(gpa, &msgs, "you are a coding agent: \"a\\b\"\n\u{7} caf\u{00e9}");
    const prefix = try gpa.dupe(u8, msgs.items);
    defer gpa.free(prefix);
    try appendToolResults(gpa, &msgs, 120, blob);

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

// A stream that ends without the provider's terminator is a dropped
// connection, not a finished answer. Appending the partial turn as complete is
// how a truncated response silently becomes the run's result, so the notice is
// what the run refuses on, and it has to say what did arrive.
test "a stream that ends without [DONE] is reported, not taken for finished" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expect(truncatedNotice(arena, "http://x/v1/chat/completions", true, 0, 0) == null);

    const cut = truncatedNotice(arena, "http://x/v1/chat/completions", false, 42, 1).?;
    try std.testing.expect(std.mem.indexOf(u8, cut, "http://x/v1/chat/completions") != null);
    try std.testing.expect(std.mem.indexOf(u8, cut, "without [DONE]") != null);
    try std.testing.expect(std.mem.indexOf(u8, cut, "42 byte(s) of content") != null);
    try std.testing.expect(std.mem.indexOf(u8, cut, "1 tool call(s)") != null);

    // Nothing arrived at all: still a cut, and still named.
    const empty = truncatedNotice(arena, "http://x/v1/chat/completions", false, 0, 0).?;
    try std.testing.expect(std.mem.indexOf(u8, empty, "0 byte(s) of content") != null);
}

// A frame the parser cannot read holds text and tool-call arguments the turn
// will not carry. Dropping it silently leaves a short response that looks like
// a complete one, so the count is what the run reports.
test "a frame the parser cannot read is counted, not dropped in silence" {
    var sink = FrameSink.init(std.testing.allocator);
    defer sink.deinit();

    try sink.feed("{\"choices\":[{\"delta\":{\"content\":\"kept\"}}]}");
    try std.testing.expectEqual(@as(usize, 0), sink.unparsable);

    try sink.feed("this is not json");
    try sink.feed("[1,2,3]");
    try sink.feed("{\"choices\":[{\"delta\":{\"content\":\"also kept\"}}]}");

    try std.testing.expectEqual(@as(usize, 2), sink.unparsable);
    // The frames around the bad ones still landed, so the turn is short rather
    // than empty: only the count says how much is missing.
    try std.testing.expectEqualStrings("keptalso kept", sink.result.content.items);
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
    var call: ToolCall = .{
        .id = try arena.dupe(u8, ""),
        .name = try arena.dupe(u8, name),
    };
    try call.args.appendSlice(arena, args);
    return runTool(std.testing.io, arena, call);
}

test "a child that outruns the capture cap keeps its first bytes instead of failing" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cap: usize = 4096;
    // `std.process.run` answers this with `error.StreamTooLong` and no output at
    // all, which is what a chatty build or a broad ripgrep used to hand back.
    const noisy = try runCapped(std.testing.io, arena, &.{
        "/bin/sh", "-c", "head -c 200000 /dev/zero | tr '\\0' 'a'",
    }, cap, durationMs(30_000));
    try std.testing.expectEqual(cap, noisy.stdout.len);
    try std.testing.expect(atCaptureLimit(noisy, cap));
    try std.testing.expectEqualStrings("a" ** 8, noisy.stdout[0..8]);
    // The child still ran to its own end, so the status is the command's.
    switch (noisy.term) {
        .exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
        else => return error.TestUnexpectedResult,
    }

    const quiet = try runCapped(std.testing.io, arena, &.{
        "/bin/sh", "-c", "echo hi; echo bye >&2",
    }, cap, durationMs(30_000));
    try std.testing.expectEqualStrings("hi\n", quiet.stdout);
    try std.testing.expectEqualStrings("bye\n", quiet.stderr);
    try std.testing.expect(!atCaptureLimit(quiet, cap));
}

test "both pipes past the cap drain together, so the child never wedges" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const cap: usize = 4096;

    const noisy = try runCapped(std.testing.io, arena_state.allocator(), &.{
        "/bin/sh",
        "-c",
        "head -c 200000 /dev/zero | tr '\\0' 'a'; head -c 200000 /dev/zero | tr '\\0' 'b' >&2",
    }, cap, durationMs(30_000));
    try std.testing.expectEqual(cap, noisy.stdout.len);
    try std.testing.expectEqual(cap, noisy.stderr.len);
    try std.testing.expectEqualStrings("a" ** 8, noisy.stdout[0..8]);
    try std.testing.expectEqualStrings("b" ** 8, noisy.stderr[0..8]);
}

test "a gap in the tool-call indexes leaves no nameless call behind" {
    const gpa = std.testing.allocator;
    var run_state = std.heap.ArenaAllocator.init(gpa);
    defer run_state.deinit();
    const arena = run_state.allocator();

    var result: ChatResult = .{};
    var calls: std.ArrayList(ToolCall) = .empty;
    var out_buf: std.ArrayList(u8) = .empty;
    var unparsable: usize = 0;
    // Index 2 arrives with no 0 and no 1, so the frame parser has to size the
    // list to index 2 and leave two slots behind it.
    const payload = "{\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":2,\"id\":\"call_1\",\"function\":{\"name\":\"read\",\"arguments\":\"{}\"}}]}}]}";
    try applyFrame(arena, arena, payload, &result, &calls, &out_buf, &unparsable);
    try std.testing.expectEqual(@as(usize, 3), calls.items.len);

    dropNamelessCalls(&calls);
    try std.testing.expectEqual(@as(usize, 1), calls.items.len);
    try std.testing.expectEqualStrings("read", calls.items[0].name);

    // A response whose calls are all named is untouched.
    dropNamelessCalls(&calls);
    try std.testing.expectEqual(@as(usize, 1), calls.items.len);
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

// A run that starts twice, or two runs that start together, can read the same
// wall-clock stamp. The second one must write beside the first: truncating it
// would leave the store holding one run's records labelled as another's.
test "a repeated session log writes beside the first and never over it" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", arena);

    const first = createSessionLog(io, arena, dir, 1759000000000000000) orelse return error.TestUnexpectedResult;
    first.writeStreamingAll(io, "first\n") catch return error.TestUnexpectedResult;
    first.close(io);

    const second = createSessionLog(io, arena, dir, 1759000000000000000) orelse return error.TestUnexpectedResult;
    second.writeStreamingAll(io, "second\n") catch return error.TestUnexpectedResult;
    second.close(io);

    const kept = try tmp.dir.readFileAlloc(io, "1759000000000000000.jsonl", alloc, .limited(64));
    defer alloc.free(kept);
    try std.testing.expectEqualStrings("first\n", kept);
    const beside = try tmp.dir.readFileAlloc(io, "1759000000000000000-1.jsonl", alloc, .limited(64));
    defer alloc.free(beside);
    try std.testing.expectEqualStrings("second\n", beside);

    // The name space is finite and running out of it is a null, not a fall
    // back to the truncating open.
    var filled: usize = 2;
    while (filled < session_name_attempts) : (filled += 1) {
        const extra = createSessionLog(io, arena, dir, 1759000000000000000) orelse return error.TestUnexpectedResult;
        extra.close(io);
    }
    try std.testing.expect(createSessionLog(io, arena, dir, 1759000000000000000) == null);
    const survived = try tmp.dir.readFileAlloc(io, "1759000000000000000.jsonl", alloc, .limited(64));
    defer alloc.free(survived);
    try std.testing.expectEqualStrings("first\n", survived);
}

test "a tool call index past the cap is dropped, not allocated" {
    var sink = FrameSink.init(std.testing.allocator);
    defer sink.deinit();
    try sink.feed("{\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":4000000000,\"function\":{\"name\":\"bash\"}}]}}]}");
    try std.testing.expectEqual(@as(usize, 0), sink.calls.items.len);
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
}

test "an environment variable set to nothing is not a value" {
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();

    try std.testing.expect(envValue(&env, "MICROAGENT_MODEL") == null);
    try env.put("MICROAGENT_MODEL", "");
    try std.testing.expect(envValue(&env, "MICROAGENT_MODEL") == null);

    // A value that is there is the value, and a wrapper that wants "no model"
    // has --model to say so with.
    try env.put("MICROAGENT_MODEL", "gpt-5");
    try std.testing.expectEqualStrings("gpt-5", envValue(&env, "MICROAGENT_MODEL").?);
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
