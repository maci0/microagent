//! The command line: what `microagent` was asked to do, and the help text that
//! answers a bad one.
//!
//! Everything here is pure over its arguments. Nothing reads the environment,
//! the clock or the machine, and nothing in the agent loop reaches back into
//! it: `main` parses once, resolves the config on top of the result, and hands
//! an `Options` to the loop. So the whole input surface, including its fuzz
//! corpus, is testable without a process around it.
//!
//! Imports only the leaves, so it sits under `config` and the loop.

const std = @import("std");
const Io = std.Io;

const chat = @import("chat.zig");
const net = @import("net.zig");

pub const default_base_url = "https://openrouter.ai/api/v1";
pub const default_model = "deepseek/deepseek-v4-flash";

pub const max_turns_default = 100;
/// Ceiling on what one response may generate, sent as `max_tokens`. Without it
/// the provider's own limit is the only bound: a model that fails to stop
/// streams until something else stops it, and the run pays for every token of
/// it, up to `max_response_bytes` per turn and `max_turns_default` turns deep.
/// Well past the largest single tool call a coding turn needs (the whole SWE
/// run in BENCHMARK.md is 80k output tokens across every instance), and low
/// enough that one runaway turn cannot run up a real bill.
pub const default_max_tokens: u32 = 65_536;

pub const Action = enum { run, help, version };

pub const Options = struct {
    prompt: []const u8 = "",
    model: []const u8 = default_model,
    base_url: []const u8 = default_base_url,
    api_key: []const u8 = "",
    max_turns: usize = max_turns_default,
    /// Sent as `max_tokens`, the ceiling on one response's generated tokens.
    max_tokens: u32 = default_max_tokens,
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

pub const help_text =
    \\microagent - tiny OpenAI-compatible coding agent
    \\
    \\usage: microagent [options] "<prompt>"
    \\
    \\  -p, --print <prompt>   task to run (also accepted as a bare argument)
    \\  -m, --model <model>    model id (env MICROAGENT_MODEL)
    \\  -b, --base-url <url>   OpenAI-compatible base url (env MICROAGENT_BASE_URL);
    \\                         https, or http on loopback, because the api key
    \\                         goes to it in the clear otherwise
    \\  -k, --api-key <key>    api key (env MICROAGENT_API_KEY, OPENAI_API_KEY,
    \\                         OPENROUTER_API_KEY, DEEPSEEK_API_KEY)
    \\      --max-turns <n>    tool-loop turn ceiling, at least 1
    \\                         (env MICROAGENT_MAX_TURNS, default 100)
    \\      --max-tokens <n>   max_tokens sent to the provider: the ceiling on
    \\                         one response's generated tokens, at least 1
    \\                         (env MICROAGENT_MAX_TOKENS, default 65536)
    \\      --config <file>    reply-style TOML config (env MICROAGENT_CONFIG,
    \\                         default ~/.microagent/config.toml)
    \\      --ca-bundle <file>
    \\                         PEM file to trust instead of the system store
    \\                         (env MICROAGENT_CA_BUNDLE, SSL_CERT_FILE). Needed in
    \\                         images that ship no ca-certificates.
    \\      --budget <seconds>
    \\                         stop starting turns after this long, and say so.
    \\                         At least 1; leaving it out is what says "no
    \\                         budget". The last turn it takes may run 5 minutes
    \\                         past it; a turn cut off there is discarded, not
    \\                         half-applied
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
    \\  update [--check] [--repo owner/name]
    \\                         replace this binary with the latest GitHub
    \\                         release after verifying its .sha256 sidecar
    \\                         (--check only reports; GITHUB_TOKEN lifts the
    \\                         API rate limit). "microagent update --help" has
    \\                         the details.
    \\
    \\examples:
    \\  microagent "fix the failing test in src/net.zig and run it"
    \\  microagent --max-turns 20 "review the diff and stop"
    \\  microagent --print "$(cat task.txt)"
    \\
    \\exit status: 0 the run finished, 1 the run failed, 2 the command line was
    \\wrong, 130 interrupted (Ctrl+C or kill), which takes the tool subprocess
    \\with it.
    \\
    \\output: stdout carries the model's text and one JSON line per response,
    \\{"type":"usage","usage":{...}}, and nothing else. stderr carries the tool
    \\gutter, the notes and every error, so a script reading stdout gets the
    \\answer and the token counters.
    \\
    \\MDEBUG=1                 trace a stuck stream on stderr, and print the
    \\                         configuration this run resolved: model, base
    \\                         url, ceilings, style levels, the style config
    \\                         file that was read, and the name of the source
    \\                         the api key came from, never the key.
    \\                         0, off, no, false and an empty value all leave
    \\                         it off.
    \\
    \\A variable set to an empty string is not a value: MICROAGENT_MODEL,
    \\MICROAGENT_BASE_URL, MICROAGENT_REASONING_EFFORT, MICROAGENT_BUDGET_SECONDS,
    \\MICROAGENT_MAX_TURNS, MICROAGENT_MAX_TOKENS and MDEBUG keep their defaults,
    \\and MICROAGENT_CA_BUNDLE and MICROAGENT_CAVEMAN/PONYTAIL fall through to
    \\whatever comes next. MICROAGENT_CONFIG and MICROAGENT_SESSION_DIR are the
    \\two where empty means off: no style file, no session log.
    \\
;

/// A command line that does not parse: one line saying which argument was
/// wrong, then the help text. Both go to stderr, so a script reading stdout
/// gets nothing from a failed invocation. Exit 2, the conventional code for a
pub fn usageError(io: Io, comptime fmt: []const u8, args: anytype) noreturn {
    die(io, "bad arguments", fmt, args);
}

/// A configuration value the program cannot use, whether it arrived on a flag
/// or in the environment. Same exit code and the same help text as a bad
/// argument, but the message names the value and the file or variable it came
/// from, because a bad env var is otherwise invisible at the call site.
pub fn configError(io: Io, comptime fmt: []const u8, args: anytype) noreturn {
    die(io, "bad configuration", fmt, args);
}

fn die(io: Io, comptime fallback: []const u8, comptime fmt: []const u8, args: anytype) noreturn {
    const msg = std.fmt.allocPrint(std.heap.page_allocator, "microagent: " ++ fmt ++ "\n", args) catch
        "microagent: " ++ fallback ++ "\n";
    net.writeErr(io, msg);
    net.writeErr(io, help_text);
    std.process.exit(2);
}

/// The value of an environment variable, or null when it is not set or is set
/// to nothing but whitespace. A wrapper that builds its own environment exports
/// the name with nothing behind it, and an empty string read as a value sends
/// `"model": ""` to the provider and loses the default; every other variable
/// here already treats empty as unset.
///
/// Surrounding whitespace is trimmed here rather than in each reader, because
/// a wrapper that populates the environment from a file carries the newline the
/// file ended with, and that newline is a different failure per option: an API
/// key arrives as an `Authorization` header carrying a byte a header may not
/// hold, so every request is refused; a base url fails to parse, so the run
/// stops claiming the key would go out in the clear, which is a security
/// warning about a value that is otherwise fine. The ceilings and the levels
/// trim for themselves at the point of parsing, `githubBearer` trims for the
/// same reason, and a key file is read trimmed; this makes the environment
/// itself the one place the whitespace is removed.
pub fn envValue(env: *const std.process.Environ.Map, name: []const u8) ?[]const u8 {
    const v = std.mem.trim(u8, env.get(name) orelse return null, net.env_surrounding);
    return if (v.len == 0) null else v;
}
/// The levels the help text names for reasoning.effort, checked where the
/// value is set. An unknown level reaches the provider as a 400 and costs a
/// whole turn to learn that a level was mistyped.
const reasoning_efforts = [_][]const u8{ "minimal", "low", "medium", "high", "none" };
const reasoning_effort_names = "minimal, low, medium, high, none";

/// The level, written through `out`, or the message saying it is not one.
/// The caller decides what a message does with it, because the flag path
/// hands it back as a usage error while the environment path exits on it.
pub fn reasoningEffort(buf: []u8, value: []const u8, out: *?[]const u8) ?[]const u8 {
    const v = std.mem.trim(u8, value, " \t\r\n");
    for (reasoning_efforts) |level| if (std.mem.eql(u8, v, level)) {
        out.* = v;
        return null;
    };
    return std.fmt.bufPrint(buf, "reasoning effort '{s}' is not one of: {s}", .{ clip(value), reasoning_effort_names }) catch
        "reasoning effort is not one of: " ++ reasoning_effort_names;
}

/// A ceiling from a flag or a variable, checked the same way on both paths:
/// a number, and at least one. Zero is refused because a run with no turns
/// sends no request, prints no answer and no usage line, and exits 0, which a
/// harness reads as a finished review rather than as a ceiling that was set
/// wrong; the same number sent as `max_tokens` is one the provider rejects, and
/// learning that costs a whole turn. `T` is the wire type of the option. The
/// number is written through `out` and a bad value is a message, for the same
/// reason `reasoningEffort` returns one.
pub fn ceiling(comptime T: type, buf: []u8, from: []const u8, value: []const u8, out: *T) ?[]const u8 {
    const n = std.fmt.parseInt(T, std.mem.trim(u8, value, " \t\r\n"), 10) catch
        return std.fmt.bufPrint(buf, "{s} must be a number, got '{s}'", .{ from, clip(value) }) catch
            "must be a number";
    if (n == 0) return std.fmt.bufPrint(buf, "{s} must be at least 1", .{from}) catch
        "must be at least 1";
    out.* = n;
    return null;
}

/// The same list spelled as the sentence an error needs, so adding a provider
/// Whether the API key may be sent to this base url. The key rides in an
/// Authorization header on every request, so a plaintext url hands it to
/// whatever is on the path, and a typo that drops the `s` is the way that
/// happens by accident. Loopback is exempt: there is no network path there to
/// intercept, and `http://localhost:1234/v1` is how a gateway running on this
/// machine is named.
pub fn baseUrlCarriesKey(base_url: []const u8) bool {
    const uri = std.Uri.parse(base_url) catch return false;
    if (std.ascii.eqlIgnoreCase(uri.scheme, "https")) return true;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "http")) return false;
    var host_buf: [Io.net.HostName.max_len]u8 = undefined;
    return isLoopbackHost((uri.getHost(&host_buf) catch return false).bytes);
}

fn isLoopbackHost(host: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(host, "localhost")) return true;
    if (std.mem.endsWith(u8, host, ".localhost")) return true;
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

/// The url as the stderr notes name it, with any `user:password@` in front of
/// the host replaced. Credentials belong in the environment, but an operator
/// who put them in the base url should not find them copied into every line
/// the run writes when the stream fails.
pub fn displayUrl(arena: std.mem.Allocator, url: []const u8) []const u8 {
    const scheme_end = std.mem.indexOf(u8, url, "://") orelse return url;
    const rest = url[scheme_end + "://".len ..];
    const authority_end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    const at = std.mem.lastIndexOfScalar(u8, rest[0..authority_end], '@') orelse return url;
    return std.fmt.allocPrint(arena, "{s}[redacted]@{s}", .{ url[0 .. scheme_end + "://".len], rest[at + 1 ..] }) catch url;
}

/// The wall-clock budget in seconds, from a flag or a variable, or the message
/// saying it is not one. It goes through `ceiling` like the turn and token
/// limits, so a zero budget is refused the same way: zero is not "no limit" to
/// the loop, it is a deadline that has already passed, so the first turn the run
/// would take is the forced final push and then it stops. A caller that meant
/// no ceiling has to say so by leaving the option out.
pub fn budgetSeconds(buf: []u8, from: []const u8, value: []const u8, out: *?u64) ?[]const u8 {
    var seconds: u64 = undefined;
    if (ceiling(u64, buf, from, value, &seconds)) |m| return m;
    out.* = seconds;
    return null;
}

/// How much of a value an error message quotes back, cut on a codepoint
/// boundary like every other truncation here: a partial codepoint is a
/// replacement character in the middle of a diagnostic, and the value being
/// quoted is whatever the user typed. Text that came out of a file rather than
/// off the command line is quoted through `chat.safeText` instead, which makes
/// the bytes printable as well as cutting them.
pub const quoted_value_bytes = 80;

pub fn clip(s: []const u8) []const u8 {
    return chat.clamp(s, quoted_value_bytes);
}

const ValuedOption = enum {
    prompt,
    model,
    base_url,
    api_key,
    ca_bundle,
    config,
    reasoning_effort,
    budget,
    max_turns,
    max_tokens,
};

const ValuedFlag = struct {
    /// The short spelling, when the flag has one.
    short: ?[]const u8,
    long: []const u8,
    /// What the missing-value message asks for, so the message names the flag
    /// and what it wanted rather than one of them alone.
    noun: []const u8,
    option: ValuedOption,
};

/// Every flag that takes a value. The table is what the parse reads and the
/// switch in `setValued` is what writes, so a flag cannot name one option and
/// set another: the copy that had drifted is the pair `--ca-bundle` and
/// `--config`, which were two branches of identical text, and the ceilings,
/// which differed only in the option they set.
const valued_flags = [_]ValuedFlag{
    .{ .short = "-p", .long = "--print", .noun = "a prompt", .option = .prompt },
    .{ .short = "-m", .long = "--model", .noun = "a model id", .option = .model },
    .{ .short = "-b", .long = "--base-url", .noun = "a url", .option = .base_url },
    .{ .short = "-k", .long = "--api-key", .noun = "a key", .option = .api_key },
    .{ .short = null, .long = "--ca-bundle", .noun = "a file", .option = .ca_bundle },
    .{ .short = null, .long = "--config", .noun = "a file", .option = .config },
    .{ .short = null, .long = "--reasoning-effort", .noun = "a level", .option = .reasoning_effort },
    .{ .short = null, .long = "--budget", .noun = "a number of seconds", .option = .budget },
    .{ .short = null, .long = "--max-turns", .noun = "a number", .option = .max_turns },
    .{ .short = null, .long = "--max-tokens", .noun = "a number", .option = .max_tokens },
};

/// The flag `name` spells, in either form, or null when it is not one.
fn valuedFlag(name: []const u8) ?ValuedFlag {
    for (valued_flags) |flag| {
        if (std.mem.eql(u8, name, flag.long)) return flag;
        if (flag.short) |short| if (std.mem.eql(u8, name, short)) return flag;
    }
    return null;
}

fn flagNeeds(buf: []u8, flag: ValuedFlag, fallback: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "{s} needs {s}", .{ flag.long, flag.noun }) catch fallback;
}

/// The option one valued flag sets. A value the option refuses says so and
/// returns the message; null means it was taken.
fn setValued(
    buf: []u8,
    opts: *Options,
    option: ValuedOption,
    value: []const u8,
) ?[]const u8 {
    switch (option) {
        .prompt => return setPrompt(buf, opts, value),
        .model => opts.model = value,
        .base_url => opts.base_url = value,
        .api_key => opts.api_key = value,
        .ca_bundle => opts.ca_bundle = value,
        .config => opts.config = value,
        .reasoning_effort => return reasoningEffort(buf, value, &opts.reasoning_effort),
        .budget => return budgetSeconds(buf, "--budget", value, &opts.budget_s),
        .max_turns => return ceiling(usize, buf, "--max-turns", value, &opts.max_turns),
        .max_tokens => return ceiling(u32, buf, "--max-tokens", value, &opts.max_tokens),
    }
    return null;
}

/// Reads the arguments after the program name into `opts`, formatting any
/// message that names a bad argument into `buf`. Returns null when
/// they parse, or a message naming what was wrong, which `usageError` prints
/// with the help text before exiting 2. A reasoning level and a turn ceiling are
/// refused where they are set, through `configError`. Every long flag also takes
/// `--flag=value`, the form `microagent update` already took, so both commands
/// spell an option the same way. `--help` and `--version` win wherever they
/// appear, and stop the parse there.
pub fn parseArgs(buf: []u8, argv: []const []const u8, opts: *Options) ?[]const u8 {
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
        } else if (valuedFlag(name)) |flag| {
            // A flag that ends the command line and one handed an empty value
            // are the same mistake, so both say the same thing.
            const v = joined orelse flagValue(argv, i) orelse return flagNeeds(buf, flag, "bad arguments");
            if (v.len == 0) return flagNeeds(buf, flag, "bad arguments");
            if (setValued(buf, opts, flag.option, v)) |m| return m;
            if (joined == null) i += 1;
        } else if (arg.len > 0 and arg[0] != '-') {
            // A bare argument is the prompt. gauntlet's custom-agent
            // definitions insert the model flags before the prompt, so
            // "microagent -p {prompt}" would hand the model flag to -p;
            // taking the prompt positionally makes the order irrelevant.
            if (setPrompt(buf, opts, arg)) |m| return m;
        } else if (arg.len == 0) {
            // An empty word is a prompt with nothing in it, which is the same
            // mistake as `--print=`, and saying it is an unknown argument
            // describes a flag nobody wrote.
            return "the prompt is empty: pass the task as an argument or with --print";
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

test "the api key is only sent over https, or to a loopback gateway" {
    try std.testing.expect(baseUrlCarriesKey(default_base_url));
    try std.testing.expect(baseUrlCarriesKey("https://gateway.internal:8443/v1"));

    // The loopback exemption is what makes a local gateway usable at all.
    try std.testing.expect(baseUrlCarriesKey("http://localhost:1234/v1"));
    try std.testing.expect(baseUrlCarriesKey("http://LocalHost:1234/v1"));
    try std.testing.expect(baseUrlCarriesKey("http://127.0.0.1:1234/v1"));
    try std.testing.expect(baseUrlCarriesKey("http://127.1.2.3/v1"));
    try std.testing.expect(baseUrlCarriesKey("http://[::1]:1234/v1"));

    // Anywhere else, plaintext would put the key on the wire in the clear.
    try std.testing.expect(!baseUrlCarriesKey("http://openrouter.ai/api/v1"));
    try std.testing.expect(!baseUrlCarriesKey("http://gateway.internal:1234/v1"));
    // A name that merely starts with the loopback prefix is somebody else's.
    try std.testing.expect(!baseUrlCarriesKey("http://127.evil.com/api/v1"));
    try std.testing.expect(!baseUrlCarriesKey("http://localhost.evil.com/api/v1"));
    try std.testing.expect(!baseUrlCarriesKey("http://127.0.0/v1"));
    // Octets past 255 are not addresses, so a resolver is what answers a name
    // spelled that way, and the resolver is not this machine.
    try std.testing.expect(!baseUrlCarriesKey("http://127.256.0.1/v1"));
    try std.testing.expect(!baseUrlCarriesKey("http://127.0.0.999:1234/v1"));
    try std.testing.expect(!baseUrlCarriesKey("http://[::2]:1234/v1"));
    // Anything that is not a url at all carries nothing.
    try std.testing.expect(!baseUrlCarriesKey("not a url"));
    try std.testing.expect(!baseUrlCarriesKey(""));
}

test "a base url that carries credentials does not print them" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqualStrings(
        "https://[redacted]@openrouter.ai/api/v1/chat/completions",
        displayUrl(arena, "https://user:sk-secret@openrouter.ai/api/v1/chat/completions"),
    );
    // Nothing to redact: the common case comes back as it went in.
    try std.testing.expectEqualStrings(default_base_url, displayUrl(arena, default_base_url));
    try std.testing.expectEqualStrings(
        "https://openrouter.ai/api/v1?x=1",
        displayUrl(arena, "https://openrouter.ai/api/v1?x=1"),
    );
    // Not a url at all, so there is no authority to look in.
    try std.testing.expectEqualStrings("openrouter.ai", displayUrl(arena, "openrouter.ai"));
}

test "the command line parses in either flag form and in any order" {
    var opts: Options = .{};
    var buf: [512]u8 = undefined;
    const argv = [_][]const u8{ "fix it", "--model=some/model", "--budget=90", "--max-turns", "7" };
    try std.testing.expectEqual(@as(?[]const u8, null), parseArgs(&buf, &argv, &opts));
    try std.testing.expectEqualStrings("fix it", opts.prompt);
    try std.testing.expectEqualStrings("some/model", opts.model);
    try std.testing.expectEqual(@as(?u64, 90), opts.budget_s);
    try std.testing.expectEqual(@as(usize, 7), opts.max_turns);

    var short: Options = .{};
    const short_argv = [_][]const u8{ "-m", "some/model", "-b", "http://localhost:1234/v1", "-p", "fix it" };
    try std.testing.expectEqual(@as(?[]const u8, null), parseArgs(&buf, &short_argv, &short));
    try std.testing.expectEqualStrings("some/model", short.model);
    try std.testing.expectEqualStrings("http://localhost:1234/v1", short.base_url);
    try std.testing.expectEqualStrings("fix it", short.prompt);

    // A value quoted with a space around it is a number the shell left in.
    var padded: Options = .{};
    const padded_argv = [_][]const u8{ "--budget", " 90 ", "--max-turns", " 7 " };
    try std.testing.expectEqual(@as(?[]const u8, null), parseArgs(&buf, &padded_argv, &padded));
    try std.testing.expectEqual(@as(?u64, 90), padded.budget_s);
    try std.testing.expectEqual(@as(usize, 7), padded.max_turns);
}

test "a wrong command line names the flag and the value it was given" {
    var opts: Options = .{};
    var buf: [512]u8 = undefined;
    try std.testing.expectEqualStrings("unknown or incomplete argument '--nope'", parseArgs(&buf, &.{"--nope"}, &opts).?);
    try std.testing.expectEqualStrings("--model needs a model id", parseArgs(&buf, &.{"--model"}, &opts).?);
    try std.testing.expectEqualStrings("--budget must be a number, got 'soon'", parseArgs(&buf, &.{ "--budget", "soon" }, &opts).?);
    try std.testing.expectEqualStrings("prompt given twice: 'one' and 'two'", parseArgs(&buf, &.{ "one", "two" }, &opts).?);
    var joined: Options = .{};
    try std.testing.expectEqualStrings("prompt given twice: 'one' and 'two'", parseArgs(&buf, &.{ "-p", "one", "--print=two" }, &joined).?);
    // An empty word is an empty prompt, not an argument nobody knows.
    try std.testing.expectEqualStrings("the prompt is empty: pass the task as an argument or with --print", parseArgs(&buf, &.{""}, &opts).?);
}

// A zero budget is a deadline that has already passed, not the absence of one:
// the run takes the forced final push as its only turn and stops, having
// changed nothing. Every numeric option refuses zero for the same reason, and
// the ceilings say so already; the budget is the one that used to accept it.
test "a budget of zero is refused like every other zero ceiling" {
    var opts: Options = .{};
    var buf: [512]u8 = undefined;
    try std.testing.expectEqualStrings("--budget must be at least 1", parseArgs(&buf, &.{ "--budget", "0" }, &opts).?);
    try std.testing.expectEqual(@as(?u64, null), opts.budget_s);

    // The same rule on the environment path, where a harness that computed a
    // per-review budget sets it from a template that may be empty of seconds.
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    try env.put("MICROAGENT_BUDGET_SECONDS", "0");
    try std.testing.expectEqualStrings("MICROAGENT_BUDGET_SECONDS must be at least 1", budgetSeconds(&buf, "MICROAGENT_BUDGET_SECONDS", env.get("MICROAGENT_BUDGET_SECONDS").?, &opts.budget_s).?);
    try std.testing.expectEqual(@as(?u64, null), opts.budget_s);

    // A real budget still takes, trimmed the way a shell leaves it.
    try std.testing.expectEqual(@as(?[]const u8, null), budgetSeconds(&buf, "--budget", " 90 ", &opts.budget_s));
    try std.testing.expectEqual(@as(?u64, 90), opts.budget_s);
}

test "help and version win wherever they appear" {
    var opts: Options = .{};
    var buf: [512]u8 = undefined;
    try std.testing.expectEqual(@as(?[]const u8, null), parseArgs(&buf, &.{ "a prompt", "--help" }, &opts));
    try std.testing.expectEqual(Action.help, opts.action);

    var v: Options = .{};
    try std.testing.expectEqual(@as(?[]const u8, null), parseArgs(&buf, &.{ "-V", "--model" }, &v));
    try std.testing.expectEqual(Action.version, v.action);
}

// The command line is the one input surface that is always untrusted: a
// wrapper script, a CI job and a human all spell it, and every one of them can
// put a value where a flag belongs. `std.testing.fuzz` runs this corpus on
// every `zig build test` and through the fuzzer's mutations when the test
// binary is built in fuzz mode. The corpus is what the harness must be able to
// read: an unknown flag, both spellings of a valued flag, a value joined with
// `=`, an empty value, a flag that ends the line, a prompt given twice, a
// ceiling that is not a number, a ceiling of zero, a budget that is not a
// number or is zero, an unknown reasoning level, and a bare `-`.
const args_corpus = [_][]const u8{
    "",
    " ",
    "-",
    "--",
    "-p hi",
    "--print=hi",
    "hi",
    "-h",
    "--help",
    "-V",
    "--version",
    "hi --help",
    "--model",
    "-m",
    "--model=",
    "-m=some/model",
    "--model some/model --budget 90 --max-turns 7 --max-tokens 4096",
    "-m some/model -b http://localhost:1234/v1 -p hi -k secret",
    "--ca-bundle /etc/ca.pem --config ~/.microagent/config.toml",
    "--reasoning-effort high --reasoning-effort=none",
    "--reasoning-effort shout",
    "--budget 0",
    "--budget -1",
    "--budget soon",
    "--budget 99999999999999999999999",
    "--max-turns 0",
    "--max-turns x",
    "--max-turns -3",
    "--max-tokens 0",
    "--max-tokens 1e30",
    "one two",
    "-p one --print two",
    "--nope",
    "-x",
    "--print=--help",
    "--print=-p",
    "\u{0}\u{1}\u{7f}",
    "--print \u{65e5}\u{8a00}",
    "--",
    "-m --budget",
    "-m",
    "--print",
};

test "a fuzzed command line sets an option only from an argument it was given" {
    try std.testing.fuzz({}, fuzzArgs, .{ .corpus = &args_corpus });
}

fn fuzzArgs(_: void, smith: *std.testing.Smith) !void {
    var raw: [8 * 1024]u8 = undefined;
    const text: []const u8 = if (smith.in) |seed| seed else raw[0..smith.slice(&raw)];

    // One word per space-separated run, so the fuzzer's bytes reach the parser
    // as arguments rather than as a single opaque one.
    var argv: [64][]const u8 = undefined;
    var n: usize = 0;
    var words = std.mem.tokenizeAny(u8, text, " \t\n");
    while (words.next()) |word| {
        if (n == argv.len) break;
        argv[n] = word;
        n += 1;
    }

    var buf: [512]u8 = undefined;
    var opts: Options = .{};
    const msg = parseArgs(&buf, argv[0..n], &opts);
    if (msg) |m| try std.testing.expect(m.len > 0);

    // `--help` and `--version` stop the parse where they are, so an argument
    // after one of them sets nothing, whatever it says.
    const stops = blk: {
        for (argv[0..n]) |arg| {
            if (isFlag(arg, "-h", "--help")) break :blk Action.help;
            if (isFlag(arg, "-V", "--version")) break :blk Action.version;
        }
        break :blk Action.run;
    };
    if (stops != .run) {
        try std.testing.expectEqual(stops, opts.action);
        try std.testing.expectEqualStrings(default_model, opts.model);
        try std.testing.expectEqual(max_turns_default, opts.max_turns);
        return;
    }

    // Every option is either the default or a word from the command line: a
    // parser that composes a value out of an argument, or that keeps one after
    // refusing it, hands a run a model id or a key nobody typed.
    for ([_][]const u8{ opts.model, opts.base_url, opts.api_key, opts.ca_bundle, opts.config, opts.prompt }) |value| {
        if (isDefault(value)) continue;
        try std.testing.expect(inArgv(argv[0..n], value));
    }
    if (opts.reasoning_effort) |level| try std.testing.expect(inArgv(argv[0..n], level));
    try std.testing.expect(opts.max_turns >= 1);
    try std.testing.expect(opts.max_tokens >= 1);
    if (opts.reasoning_effort) |level| {
        var known_level = false;
        for (reasoning_efforts) |known| {
            if (std.mem.eql(u8, level, known)) known_level = true;
        }
        try std.testing.expect(known_level);
    }
    if (msg == null and opts.budget_s == null) return;
    // A budget is a number a word on the line spells, not a number the parser
    // invented from one.
    if (opts.budget_s) |seconds| {
        var on_the_line = false;
        for (argv[0..n]) |arg| {
            const n_ = std.fmt.parseInt(u64, std.mem.trim(u8, arg, " \t\r\n"), 10) catch continue;
            if (n_ == seconds) on_the_line = true;
        }
        try std.testing.expect(on_the_line);
    }

    // The same line parsed twice says the same thing, so an operator who
    // reruns the failing invocation sees the failure again.
    var again: Options = .{};
    var again_buf: [512]u8 = undefined;
    const again_msg = parseArgs(&again_buf, argv[0..n], &again);
    try std.testing.expectEqualStrings(opts.prompt, again.prompt);
    try std.testing.expectEqual(opts.max_turns, again.max_turns);
    try std.testing.expectEqual(opts.max_tokens, again.max_tokens);
    try std.testing.expectEqual(again_msg == null, msg == null);
}

/// Whether a value is the default that `Options` starts with, which is what an
/// argument that never arrived leaves behind.
fn isDefault(value: []const u8) bool {
    return std.mem.eql(u8, value, default_model) or
        std.mem.eql(u8, value, default_base_url) or
        value.len == 0;
}

/// Whether `value` came out of a word on the command line, whole or cut at the
/// `=` of a joined `--flag=value`. An option the parser did not take keeps the
/// default, so a value that is in no word was written by the parser itself.
fn inArgv(argv: []const []const u8, value: []const u8) bool {
    for (argv) |arg| if (std.mem.indexOf(u8, arg, value) != null) return true;
    return false;
}
