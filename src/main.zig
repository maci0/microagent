//! microagent: a tiny OpenAI-compatible coding agent, sized for gauntlet loops.
//!
//! One binary, one loop: stream a chat completion, run whatever tools it asks
//! for, feed the results back, stop when it stops calling tools. Tool work is
//! delegated to the real tools on PATH (ripgrep, ast-grep, git, compilers),
//! so there is no built-in search or patch engine here to keep in sync with them.
//!
//! This file is the loop and the wiring around it: the command line, the config
//! it resolves, the provider request and the frames that come back. The parts it
//! leans on are named modules, imported in one direction: `chat` (the value types
//! a turn is made of and its JSON writer) is the leaf, `net` (sinks, deadlines,
//! the CA bundle, which urls may carry a credential) sits on it, `tool` and
//! `session` sit on
//! `net` (every tool call is reached by model-supplied text, and the per-run log
//! is written from a finished response), `mcp` (the MCP servers, over a child's
//! pipes or over HTTP) sits on `tool` and `net`, `config` (the one config file:
//! the prompt addendum, skills, MCP servers, the tool set) on `mcp`, `stream`
//! (folding one provider frame into the response) and `conversation` (the system
//! prompt, the message array and its compaction) sit on `chat` and `net`, and
//! `update` (the one subcommand, `microagent update`) sits on `net` and `chat`.

const std = @import("std");
const builtin = @import("builtin");

// A Linux build links no C library, so the published binary is one static
// file with no loader and no libc to match on the host. A build that turns
// `link_libc` on fails here rather than shipping a binary that needs one.
// macOS is exempt: every program there links libSystem, since Apple keeps its
// syscall ABI private.
comptime {
    if (builtin.os.tag == .linux and builtin.link_libc)
        @compileError("microagent links no libc on Linux; drop whatever turned link_libc on");
}

const Io = std.Io;

const build_options = @import("build_options");
const chat_mod = @import("chat.zig");
const config_mod = @import("config.zig");
const conversation_mod = @import("conversation.zig");
const mcp_mod = @import("mcp.zig");
const net = @import("net.zig");
const session_mod = @import("session.zig");
const sandbox_mod = @import("sandbox.zig");
const skill_mod = @import("skill.zig");
const stream_mod = @import("stream.zig");
const tool_mod = @import("tool.zig");
const update_mod = @import("update.zig");

/// std gives every thread a 256 KB `.tbss` signal stack for its segfault handler, zeroed at thread
/// start, whether or not the handler is on. Release builds turn the handler off, so they skip it.
pub const std_options: std.Options = .{
    .signal_stack_size = if (std.debug.default_enable_segfault_handler) 1 << 18 else null,
};

const version = build_options.version;

// Referenced so its `memcpy` is linked: the module exports it and nothing calls it by name.
comptime {
    _ = @import("copy");
}

/// The model a run uses when neither the command line, the environment nor the
/// config file named one. The base url has no such default: an endpoint is a
/// choice about whose account the tokens are billed to, so one of the three
/// sources has to say it.
const default_model = "deepseek/deepseek-v4-flash";
/// The one variable the base url is read from. It is also the one the Harbor
/// adapter sets, so a run it starts always names an endpoint.
const base_url_var = "MICROAGENT_BASE_URL";
/// Room for one whole tool message: the capped result plus the keys, the id
/// and the JSON punctuation around it. The result arrives unescaped, and a
/// result at the cap also carries the truncation note `toolResult` appends, so
/// this is a reservation rather than a bound; the buffer still grows when a
/// result needs more, which is what a control byte in the output does.
const tool_result_message_bytes = tool_mod.max_tool_output + tool_result_message_scaffolding_bytes;
/// Everything in a tool message that is not the result: the role, the
/// tool_call_id, the content key and the braces. An id is a provider-assigned
/// string of no stated width, so this is headroom rather than a bound.
const tool_result_message_scaffolding_bytes = 512;
/// Ceiling on what one turn's tool results may add to the conversation.
/// `max_tool_output` bounds one result and `max_tool_calls` bounds how many one
/// response may ask for, and their product is 1.5 MB, nearly four times
/// `conversation_soft_limit`: a response asking for 64 large reads sends a
/// request four times the size the compaction above exists to hold down, and
/// that request is billed before the turn after it elides anything. Compaction
/// runs at the top of a turn, so nothing bounds the turn that filled it. The
/// calls still run and still get a tool message, so the pairing the next
/// request needs is intact and no call is silently unanswered; what stops is
/// the output being carried forward, past the first result that does not fit.
const max_turn_tool_output: usize = 256 * 1024;
/// The marker that replaces a tool result past the ceiling above. It is the
/// run's own doing, not the tool's, and says so: a tool that printed nothing
/// and a tool whose output the run declined to carry are different facts, and
/// the model is the one deciding what to do next. The system prompt names it,
/// the way it names the marker compaction writes.
const turn_output_capped_marker = "[tool output not carried: this turn's tool results reached their ceiling]";
const max_turns_default = 100;
/// The exit status for a run that stopped at a ceiling rather than finishing:
/// `--max-turns`, or a budget that ended the last turn. Distinct from 0 (the
/// model answered) and from 1 (the run failed), because neither of those
/// describes it, and a script that reads stdout has no other way to tell a
/// prefix of an answer from an answer.
const exit_incomplete: u8 = 3;
/// Ceiling on what one response may generate, sent as `max_tokens`. Without it
/// the provider's own limit is the only bound: a model that fails to stop
/// streams until something else stops it, and the run pays for every token of
/// it, up to `max_response_bytes` per turn and `max_turns_default` turns deep.
/// Well past the largest single response a coding turn needs (the 13-instance
/// SWE run in docs/benchmark.md bills 80k output tokens in total, so no one
/// response in it came near this), and low enough that one runaway turn cannot
/// run up a real bill.
const default_max_tokens: u32 = 65_536;
/// How long the response socket may stay silent before its read fails rather
/// than blocking forever. The budget is checked between reads, and a read that
/// never returns never reaches that check: a host that accepted the connection
/// and then said nothing hung a benchmark trial for twenty-five minutes.
const default_stall_timeout_s: u32 = 120;
/// Bytes one read of the completion stream asks for. A read lands straight in
/// the pending buffer, so this is the growth step of that buffer, not a separate
/// buffer: every byte of every response passed through one copy fewer because of
/// it, and the frames are split out of `pending` in place.
const stream_read_chunk: usize = 8 * 1024;

/// The most of a repository's instructions this run follows. They ride on every
/// request of the run, so a file past this is read up to the cap and the note
/// names the size it was cut from.
const max_agents_bytes: usize = 16 * 1024;

/// Ceiling on one line of the completion stream, the bytes between newlines
/// that `pending` holds for a frame that has not finished arriving.
/// `max_response_bytes` bounds what a finished frame may add to the turn, so it
/// never sees a line that never ends: nothing is consumed, the buffer grows by
/// a read chunk at a time, and a provider that sends `data: ` and no newline
/// costs the run the whole stream. One line is a frame, and a frame is a
/// token-sized delta or a fragment of one call's arguments, so this is far
/// past anything a real completion sends.
const max_frame_bytes: usize = 1024 * 1024;

/// Whether what the line split left is a line that has outgrown the turn.
/// The input is the residual after `net.nextLineEnd` has consumed the whole
/// lines, which is what makes the boundary the ceiling itself: a line of
/// exactly `max_frame_bytes` has not overrun, one byte more has.
fn frameOverran(pending: []const u8) bool {
    return pending.len > max_frame_bytes;
}
/// The config file is a handful of keys; a bigger file is not one.
const max_config_bytes: usize = 64 * 1024;
/// A provider's error body is a diagnostic, not a payload, so it is bounded
/// tight: the text goes on stderr and nothing reads it as a tool result. The
/// `read` tool's own ceiling, `max_read_bytes` in the tool module, is two and a
/// half orders of magnitude above it.
const max_error_body_bytes: usize = 16 * 1024;

const tools_json =
    \\[
    \\{"type":"function","function":{"name":"bash","description":"Run a shell command in the current directory, which is where every call starts: no shell and no `cd` carries over, so do not prefix one.","parameters":{"type":"object","properties":{"command":{"type":"string","description":"Shell command"},"timeout_ms":{"type":"integer","description":"Timeout in milliseconds, default 120000, at most 600000"}},"required":["command"]}}},
    \\{"type":"function","function":{"name":"read","description":"Read a file as text. Refuses credentials files (.env, private keys, keystores, anything under .secrets or .ssh).","parameters":{"type":"object","properties":{"path":{"type":"string"},"offset":{"type":"integer","description":"1-based first line"},"limit":{"type":"integer","description":"Max lines"}},"required":["path"]}}},
    \\{"type":"function","function":{"name":"write","description":"Create or overwrite a file, creating parent directories. Refuses credentials files, as `read` does.","parameters":{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"}},"required":["path","content"]}}},
    \\{"type":"function","function":{"name":"edit","description":"Replace an exact string in a file. old_string must occur once unless replace_all is set; new_string must not contain old_string. Refuses credentials files.","parameters":{"type":"object","properties":{"path":{"type":"string"},"old_string":{"type":"string"},"new_string":{"type":"string"},"replace_all":{"type":"boolean"}},"required":["path","old_string","new_string"]}}},
    \\{"type":"function","function":{"name":"multi_edit","description":"Several `edit`s, in one file or across files, applied in order on the text the earlier ones left; nothing is written unless all are accepted. Prefer it to repeated `edit` calls.","parameters":{"type":"object","properties":{"edits":{"type":"array","items":{"type":"object","properties":{"path":{"type":"string"},"old_string":{"type":"string"},"new_string":{"type":"string"},"replace_all":{"type":"boolean"}},"required":["path","old_string","new_string"]}}},"required":["edits"]}}},
    \\{"type":"function","function":{"name":"search","description":"Search file contents with ripgrep; returns file:line:text matches. Skips credentials files.","parameters":{"type":"object","properties":{"pattern":{"type":"string","description":"Regular expression"},"path":{"type":"string","description":"Directory or file, default ."},"glob":{"type":"string","description":"Glob filter, e.g. *.zig"}},"required":["pattern"]}}},
    \\{"type":"function","function":{"name":"ast","description":"Structural search or rewrite with ast-grep, matching syntax, not text. `lang` is one ast-grep supports, and Zig is not among them, so use `search` on a Zig tree. Skips credentials files. Set rewrite to apply it to every match; a rewrite whose result the pattern still matches is refused.","parameters":{"type":"object","properties":{"pattern":{"type":"string","description":"ast-grep pattern with metavariables, e.g. $A == $A"},"lang":{"type":"string","description":"Language, e.g. python, javascript, go, rust"},"path":{"type":"string","description":"Directory or file, default ."},"rewrite":{"type":"string","description":"Replacement pattern; when set the matches are rewritten in place"}},"required":["pattern","lang"]}}},
    \\{"type":"function","function":{"name":"git","description":"Read repository state: status, diff, log, show, blame. Refuses a credentials file as path or rev. Use it instead of git through bash.","parameters":{"type":"object","properties":{"cmd":{"type":"string","enum":["status","diff","log","show","blame"],"description":"What to read"},"path":{"type":"string","description":"File or directory to scope to"},"rev":{"type":"string","description":"Revision for diff/show/blame, e.g. HEAD~3"},"limit":{"type":"integer","description":"Max output lines, default 400"}},"required":["cmd"]}}},
    \\{"type":"function","function":{"name":"todo","description":"Keep the steps of a long task. Send the whole list each time: it replaces the last one and is returned.","parameters":{"type":"object","properties":{"items":{"type":"array","items":{"type":"object","properties":{"text":{"type":"string"},"status":{"type":"string","enum":["pending","doing","done"]}},"required":["text","status"]}}},"required":["items"]}}}
    \\]
;

/// What the command line asked the binary to do before it does any work.
const Action = enum { run, help, version };

/// Answers the action a parse settled on. `--help` and `--version` stop the
/// parse where they appear, before any option value is needed, so the same two
/// lines are printed here whether the action was found by the early scan or by
/// the full parse.
///
/// The text a caller may have piped at something that read a few lines and
/// left: nothing is waiting on the rest, so a closed stream costs the caller
/// nothing.
fn writeAction(io: Io, action: Action) void {
    switch (action) {
        .help => net.writeOut(io, help_text) catch {},
        .version => net.writeOut(io, "microagent " ++ version ++ "\n") catch {},
        .run => {},
    }
}

const Options = struct {
    prompt: []const u8 = "",
    model: []const u8 = default_model,
    /// The OpenAI-compatible endpoint. Empty until the config file, the
    /// environment or the command line names one, and a run with none is
    /// refused rather than sent to an endpoint nobody chose.
    base_url: []const u8 = "",
    api_key: []const u8 = "",
    max_turns: usize = max_turns_default,
    /// Sent as `max_tokens`, the ceiling on one response's generated tokens.
    max_tokens: u32 = default_max_tokens,
    /// Seconds the response socket may stay silent before a read fails.
    stall_timeout_s: u32 = default_stall_timeout_s,
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
    /// Stop starting turns once the run has billed this many tokens in total,
    /// prompt and completion together, cached prompt tokens included. Null is
    /// no ceiling, the way an unset `budget_s` is no deadline.
    max_spend_tokens: ?u64 = null,
    /// PEM file to trust instead of scanning the system store. Set by
    /// --ca-bundle, MICROAGENT_CA_BUNDLE or SSL_CERT_FILE.
    ca_bundle: []const u8 = "",
    /// Directory the session log is written to, one JSONL record per model
    /// response, so a monitor (toktop) can read this run's tokens per second
    /// while it is still going. Set by MICROAGENT_SESSION_DIR, else
    /// $HOME/.microagent/sessions; an empty value writes nothing.
    session_dir: []const u8 = "",
    /// Config file to read. Set by --config or MICROAGENT_CONFIG, else
    /// $HOME/.microagent/config.toml. A missing file is not an error.
    config: []const u8 = "",
    /// The skills this run found, discovered once before the first request:
    /// the listing in the system prompt and the `skill` tool's schema entry
    /// both come from here, so the model is offered exactly the skills the run
    /// can load. Empty means the tool is not advertised at all.
    skills: skill_mod.Skills = .{},
    /// The servers this run connected to, each a child process whose tools are
    /// in the request schema. Declared by the `[[mcp]]` tables of the config
    /// file, connected once before the first request, and shut down when the
    /// run ends.
    mcp: mcp_mod.Servers = .{},
    /// Commands denied from running via the bash tool.
    deny_commands: []const []const u8 = &.{},
    /// The built-in tools the config file switched off. They are left out of
    /// the schema and their calls are refused.
    disabled_tools: std.EnumSet(chat_mod.Tool) = .initEmpty(),
    /// Sandbox settings to confine filesystem writes.
    sandbox: config_mod.Sandbox = .{},
    /// Absolute directory roots where writes are allowed when sandboxed.
    writable_roots: []const []const u8 = &.{},
    /// What the command line asked for. `--help` and `--version` stop the
    /// parse where they appear, before any option value is needed.
    action: Action = .run,
    /// The options the command line set, so a variable the same option's flag
    /// overrode is not the run's misconfiguration. The help states that a flag
    /// wins over the environment variable for the same option, and this is
    /// what makes that true of a value the environment got wrong.
    from_flag: std.EnumSet(ValuedOption) = .{},
};

/// The allocator behind `init.gpa`. std's start code picks `SmpAllocator` for
/// a multi-threaded build with no libc, and that allocator hops to another
/// CPU's slot and maps a fresh 64 KB slab whenever the current slot has none
/// for a size class. A process that allocates from one thread at a time pays
/// that on nearly every first use of a class: `--version` alone mapped 89
/// slabs. The bucket allocator maps a page per size class instead. Debug
/// builds keep the checked one, so a leak still fails the run that has it.
var gpa_state: std.heap.DebugAllocator(if (builtin.mode == .Debug) .{} else .{
    .safety = false,
    .stack_trace_frames = 0,
}) = .init;

/// Builds what std's start code would hand `main`, around `gpa_state` rather
/// than the allocator start code would choose.
/// The worker threads behind `Io.Threaded` are the only threads this program
/// starts. std gives each one a 16 MB stack and allows one per core, which on
/// this 16-core machine is 240 MB of stacks for call paths that read and write
/// files and sockets, and two of them at rest was 32 MB of address space. A
/// megabyte is ten times what a read or a write behind one has ever used.
///
/// The limit is not four. `std.net.HostName.connect` dials every address a
/// name resolves to as its own async task and keeps the first to connect,
/// which is what makes a name with a dead address still connect. Past the
/// limit those dials do not queue: `Io.Threaded` runs an operation inline on
/// the calling thread when every slot is busy, so one connection costs the sum
/// of the host's addresses instead of the fastest one, and the handshakes that
/// overlap -- one per remote MCP server, before the first request -- contend
/// with each other for the same slots. At four the four default presets cost
/// 4,607 ms before the first request, and the same run is 2,820 ms at sixteen,
/// which is the slowest server's own answer time and the floor until a provider
/// answers faster than `mcp.context7.com` does. A host with five addresses
/// alone (`mcp.deepwiki.com`, the new preset) is 4,368 ms at four against
/// 1,899 ms at sixteen. Sixteen is the knee: 3,705 ms at eight, 2,814 ms at
/// thirty-two. The price is address space, not resident memory -- 16.9 MB
/// against 19.8 MB of `VmPeak` on a 300-turn run, 0.5 MB of `VmHWM` -- and only
/// when that run asks for the threads. Nothing counts instructions for this
/// one because the cost is a wait, so the guard is the limit itself.
const io_worker_stack_bytes = 1024 * 1024;
const io_worker_limit = 16;
/// The measured knee, and what the guard below asserts: a limit under it is the
/// regression that put four back.
const io_worker_limit_floor = 16;

test "the async limit covers the handshakes and their address fan-out" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{
        .stack_size = io_worker_stack_bytes,
        .async_limit = .limited(io_worker_limit),
    });
    defer threaded.deinit();
    // Defeating the fix -- putting four back -- fails here, and no row of
    // bench/instructions.sh moves either way: the regression is a wait, not
    // work, so the guard is the configuration rather than a counter.
    try std.testing.expect(@intFromEnum(threaded.async_limit) >= io_worker_limit_floor);
}

const word_bytes = @sizeOf(usize);
const lane_ones: usize = std.math.maxInt(usize) / 0xff;
const lane_highs: usize = lane_ones * 0x80;

/// The length of a C string, a word at a time: `std.mem.len` is a byte loop in a `ReleaseSmall`
/// build, and the environment is about 8 KB of strings. An aligned word never crosses a page, so
/// reading the whole word that holds the terminator cannot fault. Little-endian only, which every
/// release target is.
fn cstrlen(s: [*:0]const u8) usize {
    comptime std.debug.assert(builtin.cpu.arch.endian() == .little);
    const start = @intFromPtr(s);
    var at = start;
    while (at % word_bytes != 0) : (at += 1) {
        if (@as(*const u8, @ptrFromInt(at)).* == 0) return at - start;
    }
    while (true) : (at += word_bytes) {
        const word = @as(*const usize, @ptrFromInt(at)).*;
        const zeros = (word -% lane_ones) & ~word & lane_highs;
        if (zeros != 0) return at - start + @ctz(zeros) / 8;
    }
}

/// `Environ.createMap` for an arena, without copying: every key and value is a slice of the
/// process's own environment block, which outlives the map, and the table is sized before the first
/// entry. Nothing frees them one by one: `Map.deinit` and `swapRemove` free through the arena, which
/// ignores memory it did not hand out. A key is the text before the first `=`, so `validateKeyForPut`
/// has nothing to reject and is not run. Only POSIX hands over a block to walk.
fn environMap(arena: std.mem.Allocator, environ: std.process.Environ) !std.process.Environ.Map {
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) return environ.createMap(arena);
    const entries = environ.block.view().slice;
    var map: std.process.Environ.Map = .init(arena);
    try map.array_hash_map.ensureTotalCapacity(arena, entries.len);
    for (entries) |entry| {
        const line = entry[0..cstrlen(entry)];
        const eq = std.mem.findScalar(u8, line, '=') orelse line.len;
        const slot = map.array_hash_map.getOrPutAssumeCapacity(line[0..eq]);
        slot.value_ptr.* = if (eq < line.len) line[eq + 1 ..] else "";
    }
    return map;
}

pub fn main(minimal: std.process.Init.Minimal) !void {
    defer if (builtin.mode == .Debug) {
        _ = gpa_state.deinit();
    };
    const gpa = gpa_state.allocator();
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    var threaded: std.Io.Threaded = .init(gpa, .{
        .argv0 = .init(minimal.args),
        .environ = minimal.environ,
        .stack_size = io_worker_stack_bytes,
        .async_limit = .limited(io_worker_limit),
    });
    defer threaded.deinit();
    // In the run arena: the map lives as long as the process, so its ~100 strings are bumps that
    // one `arena.deinit` releases, not an allocation and a free apiece.
    var environ_map = try environMap(arena.allocator(), minimal.environ);
    // `runMain` reports the exit status rather than leaving the process from
    // inside itself: a `std.process.exit` between two of its defers skips
    // them, and the one it skips on a failed run is the MCP shutdown, which is
    // what kills the server process groups. The exit is here instead, after
    // every defers this frame owns has run.
    const status = try runMain(.{
        .minimal = minimal,
        .arena = &arena,
        .gpa = gpa,
        .io = threaded.io(),
        .environ_map = &environ_map,
        .preopens = .empty,
    });
    if (status != 0) std.process.exit(status);
}

fn runMain(init: std.process.Init) !u8 {
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
        return update_mod.run(io, gpa, init.arena.allocator(), init.environ_map, args.items[2..]);
    }

    // `--help` and `--version` before the environment is read, so a variable
    // this machine cannot use cannot take away the one command line that
    // explains the rest. `MICROAGENT_MAX_TURNS=0 microagent --help` is the
    // case: it is the one command whose text names the exit status table
    // forbids printing help on stderr, so a user whose variable was wrong had
    // no way left to read that variable's own documentation. `microagent
    // update`, dispatched above, answers the same way.
    if (earlyAction(args.items[1..])) |action| {
        writeAction(io, action);
        return 0;
    }

    var opts: Options = .{};
    // A value the environment named that this run could not use, held until the
    // command line says whether it is still in force.
    var env_problem: ?EnvProblem = null;
    // Held rather than assigned, because the config file sits under the
    // environment: a variable that named one wins over the file, and only a
    // source that stayed silent lets the file answer.
    const env_model = envValue(init.environ_map, "MICROAGENT_MODEL");
    if (env_model) |v| opts.model = v;
    const env_base_url = envValue(init.environ_map, base_url_var);
    if (env_base_url) |v| opts.base_url = v;
    reasoningEffortFromEnv(init.environ_map, "MICROAGENT_REASONING_EFFORT", &opts.reasoning_effort, &env_problem);
    ceilingFromEnv(usize, init.environ_map, "MICROAGENT_MAX_TURNS", .max_turns, &opts.max_turns, &env_problem);
    ceilingFromEnv(u32, init.environ_map, "MICROAGENT_MAX_TOKENS", .max_tokens, &opts.max_tokens, &env_problem);
    ceilingFromEnv(u32, init.environ_map, "MICROAGENT_STALL_TIMEOUT", .stall_timeout, &opts.stall_timeout_s, &env_problem);
    opts.ca_bundle = net.caBundlePath(init.environ_map);
    optionalCeilingFromEnv(init.environ_map, "MICROAGENT_BUDGET_SECONDS", .budget, &opts.budget_s, &env_problem);
    optionalCeilingFromEnv(init.environ_map, "MICROAGENT_MAX_SPEND_TOKENS", .max_spend_tokens, &opts.max_spend_tokens, &env_problem);
    opts.session_dir = session_mod.sessionDir(init.environ_map, init.arena.allocator());

    var err_buf: [512]u8 = undefined;
    if (parseArgs(&err_buf, args.items[1..], &opts)) |msg| return usageError(io, "{s}", .{msg});
    writeAction(io, opts.action);
    if (opts.action != .run) return 0;
    if (env_problem) |problem| reportEnvProblem(io, init.arena.allocator(), problem, opts.from_flag, &err_buf);

    if (opts.prompt.len == 0) return usageError(io, "no prompt: pass it as an argument or with --print", .{});
    tool_mod.forwardInterruptsToToolGroup();
    // Read before the key and the endpoint are resolved, because the file is
    // one of the sources they are resolved from.
    const arena = init.arena.allocator();
    const loaded = loadConfig(io, init, arena, opts.config);
    if (toolConfigError(arena, loaded)) |msg| return configError(io, "{s}", .{msg});
    // The file is the weakest of the three sources, so it answers only where
    // neither the flag nor a variable did.
    if (!opts.from_flag.contains(.model) and env_model == null and loaded.model.len != 0) opts.model = loaded.model;
    if (!opts.from_flag.contains(.base_url) and env_base_url == null and loaded.base_url.len != 0) opts.base_url = loaded.base_url;
    var key = resolveKey(init.environ_map, opts.api_key, loaded.api_key);
    // The value can be a slice of the environment map, which loses the credentials below.
    key.value = try init.arena.allocator().dupe(u8, key.value);
    opts.api_key = key.value;
    // The message names every source a key may come from, because the one the
    // user wrote is the one they are looking at.
    if (opts.api_key.len == 0) return configError(io, "no API key: pass --api-key, set {s}, or set api_key in the config file", .{key_var});
    // The key is written into an `Authorization` header line, so a byte below
    // 0x20 or DEL ends that line and everything after it is a header of the
    // caller's own making. A file edited by hand or an `export` fed a stray
    // newline is the ordinary way one arrives, and the rule is the one a remote
    // MCP key is already held to.
    if (net.hasHeaderControlBytes(opts.api_key))
        return configError(io, "the API key from {s} holds a control character, which cannot go in a header", .{key.source});
    if (opts.base_url.len == 0) return configError(io, "no base url: pass --base-url, set MICROAGENT_BASE_URL, or set base_url in the config file", .{});
    // Refused as a url before it is refused as a leak, because that is what it
    // is: a caller who left the scheme off is told their key was about to go
    // out in the clear, which is a security warning about a value that never
    // reaches the network.
    if (std.Uri.parse(opts.base_url)) |_| {} else |_| return configError(io, "{s} is not a url", .{clip(opts.base_url)});
    if (!net.urlCarriesKey(opts.base_url))
        return configError(io, "the API key would go to {s} in the clear; use an https base url, or http on loopback", .{clip(opts.base_url)});

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    net.loadCaBundle(&client, io, gpa, opts.ca_bundle, init.arena.allocator());

    // The conversation is kept as the literal JSON array the API wants, so a
    // message is appended once, in the wire format, with no model in between.
    var msgs: std.ArrayList(u8) = .empty;
    defer msgs.deinit(gpa);
    opts.deny_commands = loaded.deny_commands;
    opts.disabled_tools = loaded.disabled_tools;
    opts.sandbox = loaded.sandbox;
    if (opts.sandbox.enabled) {
        opts.writable_roots = try sandbox_mod.resolveWritableRoots(io, arena, init.environ_map, opts.sandbox.writable, opts.session_dir);
        if (!sandbox_mod.applySandbox(arena, opts.writable_roots)) {
            // Not enforced: Landlock needs Linux 5.13 or newer and Seatbelt refused the profile. Saying so is
            // what keeps `enabled = true` from reading as protection `bash` and the MCP servers
            // do not have.
            net.note(io, arena, "microagent: sandbox: the kernel sandbox could not be applied (Linux needs 5.13 or newer for Landlock, macOS uses Seatbelt); only `write` and `edit` are confined, not `bash` or MCP servers\n", .{});
        }
    }
    // Built before the skills and the servers, because a tool subprocess and
    // an MCP server both inherit the environment it withholds the provider
    // key from. Built once for the run: a tool subprocess is spawned once per
    // call, and each one would otherwise inherit the provider key.
    // The remote servers' keys are read first, from the environment as it
    // came, and then the variables that held them are scrubbed with the rest.
    const remote_entries = try mcp_mod.withKeys(arena, init.environ_map, loaded.mcp);
    scrubSecrets(init.environ_map, remote_entries);
    const tool_env = init.environ_map;
    // Discovered before the trace and before the first request: the listing is
    // part of the system prompt, so a skill added between the two reads would
    // otherwise be advertised without a body to load.
    const skill_roots = skill_mod.roots(init.environ_map, arena, loaded.skills);
    opts.skills = skill_mod.discover(io, arena, skill_roots);
    // The servers are connected before the first request for the same reason:
    // their tools are in the schema the request carries. A server that fails
    // to start or to answer is reported and skipped, so this cannot fail the
    // run, and the ones that did connect are shut down with the run.
    opts.mcp = mcp_mod.connect(io, arena, tool_env, &client, remote_entries, version);
    defer opts.mcp.shutdown(io);
    traceConfig(io, arena, opts, loaded, skill_roots, key.source);
    const skill_block = try opts.skills.prompt(arena);
    const agents = readAgentsFile(io, arena, loaded.agents_file, loaded.agents_file_named);
    const agents_block = if (agents) |text|
        try std.fmt.allocPrint(arena, "\n\nThe repository's own instructions, from {s}, which this run follows within the task above:\n{s}", .{
            chat_mod.safeTextAll(arena, loaded.agents_file),
            text,
        })
    else
        "";
    const system_text = try systemText(arena, loaded.system_prompt_extra, agents_block, skill_block, opts.disabled_tools);
    try conversation_mod.openConversation(gpa, &msgs, system_text, opts.prompt);

    const ended = run(&client, io, gpa, init.arena.allocator(), opts, &msgs, tool_env, &opts.mcp) catch |err| {
        // The endpoint is the one thing every failure below shares, and it is
        // not in the error: a DNS failure, a refused connection and a truncated
        // stream all arrive here as a bare name.
        const msg = try std.fmt.allocPrint(arena, "microagent: the run against {s} failed: {s}\n", .{
            displayUrl(arena, opts.base_url),
            @errorName(err),
        });
        net.writeErr(io, msg);
        return 1;
    };
    // A run that stopped at a ceiling still has the model's words on stdout,
    // and they are a prefix of the work rather than an answer to it. Reporting
    // 0 would tell a script reading them that the task finished, which is the
    // one claim a ceiling-truncated answer cannot support.
    if (ended != .answered) return exit_incomplete;
    return 0;
}

/// The repository's own instructions, read from the working directory when the
/// run starts, or null when the config turned the read off, the file is not
/// there, or it cannot be read. Repository text is not the operator's, so the
/// block it becomes says where it came from; a file larger than the cap is
/// followed up to the cap rather than not at all, and the note names the size
/// it was cut from.
fn readAgentsFile(io: Io, arena: std.mem.Allocator, path: []const u8, named: bool) ?[]const u8 {
    if (path.len == 0) return null;
    var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| {
        noteAgentsUnread(io, arena, path, named, err);
        return null;
    };
    defer file.close(io);
    // One byte past the cap, so a file that is over it is known to be over it.
    // `readFileAlloc` refuses at the cap rather than past it, and refusing a
    // file past it is the wrong answer here: the first 16 KB of a long file is
    // the part a run can follow, and the rest is what the note names.
    const bytes = arena.alloc(u8, max_agents_bytes + 1) catch return null;
    var read_buffer: [stream_read_chunk]u8 = undefined;
    var file_reader = file.reader(io, &read_buffer);
    const r = &file_reader.interface;
    var filled: usize = 0;
    while (filled < bytes.len) {
        const n = r.readSliceShort(bytes[filled..]) catch |err| {
            noteAgentsUnread(io, arena, path, named, file_reader.err orelse err);
            return null;
        };
        if (n == 0) break;
        filled += n;
    }
    if (filled <= max_agents_bytes) return bytes[0..filled];
    // The cut lands on a code point boundary, so the prompt never carries half
    // a character at its end.
    const head = bytes[0..max_agents_bytes];
    const whole = head[0 .. head.len - chat_mod.partialTailLen(head)];
    net.note(io, arena, "microagent: the repository instructions {s} are larger than {d} bytes; the first {d} are followed\n", .{
        chat_mod.safeTextAll(arena, path),
        max_agents_bytes,
        whole.len,
    });
    return whole;
}

/// Why there are no repository instructions this turn, on stderr, when the
/// reason is one the operator can act on. A named file that is not there is
/// their own spelling of a setting that did nothing; the default name is silent
/// there, because most repositories have no such file. A file that is there
/// and unreadable is said either way, because it exists.
fn noteAgentsUnread(io: Io, arena: std.mem.Allocator, path: []const u8, named: bool, err: anyerror) void {
    if (!named and err == error.FileNotFound) return;
    net.note(io, arena, "microagent: the repository instructions {s} could not be read ({s}); this run follows the system prompt alone\n", .{
        chat_mod.safeTextAll(arena, path),
        @errorName(err),
    });
}

/// The system prompt: one string, so a run with no addendum, no repository
/// instructions, no skills and every tool on sends exactly the prompt it sent
/// before any of them existed. A run that turned built-in tools off ends it
/// with one line naming them, so the model does not learn of them from a
/// refusal.
fn systemText(arena: std.mem.Allocator, extra: []const u8, agents_block: []const u8, skill_block: []const u8, disabled: std.EnumSet(chat_mod.Tool)) ![]const u8 {
    if (extra.len == 0 and agents_block.len == 0 and skill_block.len == 0 and disabled.count() == 0) return conversation_mod.system_prompt;
    var text: std.ArrayList(u8) = .empty;
    try text.appendSlice(arena, conversation_mod.system_prompt);
    if (extra.len != 0) {
        try text.appendSlice(arena, "\n\n");
        try text.appendSlice(arena, extra);
    }
    try text.appendSlice(arena, agents_block);
    try text.appendSlice(arena, skill_block);
    if (disabled.count() != 0) {
        try text.appendSlice(arena, "\n\nDisabled tools: ");
        var first = true;
        for (chat_mod.tools()) |tool| {
            if (!disabled.contains(tool)) continue;
            if (!first) try text.appendSlice(arena, ", ");
            first = false;
            try text.appendSlice(arena, tool.name());
        }
        try text.appendSlice(arena, ".");
    }
    return text.items;
}

/// The reason the config makes this run unable to start, or null. A tool
/// table the run cannot honor stops it: a misspelled name that left the tool
/// on, or a value that left an option at its default, is a run configured
/// differently from the file that was read. So does a file that disables every
/// built-in, which leaves the model nothing to work with.
fn toolConfigError(arena: std.mem.Allocator, loaded: LoadedConfig) ?[]const u8 {
    const path = chat_mod.safeTextAll(arena, loaded.source orelse "");
    if (loaded.tool_problem) |problem| {
        const name = chat_mod.safeText(arena, problem.name, net.quoted_value_bytes);
        const key = chat_mod.safeText(arena, problem.key, net.quoted_value_bytes);
        return switch (problem.kind) {
            .unknown_tool => std.fmt.allocPrint(arena, "config {s}: [tools.{s}] is not a tool; the tools are {s}", .{ path, name, config_mod.tool_names }) catch "config: a [tools] table names no tool",
            .bad_value => std.fmt.allocPrint(arena, "config {s}: {s} in [tools.{s}] is not a value this key takes", .{ path, key, name }) catch "config: a [tools] value is not usable",
        };
    }
    if (loaded.disabled_tools.count() == chat_mod.tools().len)
        return std.fmt.allocPrint(arena, "config {s}: every built-in tool is disabled; remove `enabled = false` from at least one [tools.<name>] table", .{path}) catch "config: every built-in tool is disabled";
    return null;
}

/// Injected once when a run that already edited the tree stops without having
/// run any test runner. The measured failure mode: a SWE-bench instance that
/// ended after 20 turns and zero test commands, against 5-15 test commands in
/// every instance that passed.
const verify_push =
    "Nothing in this session has run a test, so nothing verifies the change. Run the tests that " ++
    "cover what you changed, using the project's own test command, and fix whatever they report. " ++
    "If the project has no test for this code, run the closest thing that exercises the changed " ++
    "line and say what it proved.";

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
    \\  -m, --model <model>    model id (env MICROAGENT_MODEL, config key
    \\                         model, default
++ " " ++ default_model ++ ")\n" ++
    \\  -b, --base-url <url>   OpenAI-compatible base url (env
    \\                         MICROAGENT_BASE_URL, config key base_url). One of
    \\                         the three has to name an endpoint: there is no
    \\                         default provider. https, or http on loopback,
    \\                         because the api key goes to it in the clear
    \\                         otherwise
    \\  -k, --api-key <key>    api key (env MICROAGENT_API_KEY, config key
    \\                         api_key; no key file is read). The key goes to
    \\                         the base url, so name a base url from the same
    \\                         provider as the key. A key on the
    \\                         command line is in the process table, where any
    \\                         user of this machine can read it; a variable or
    \\                         a file mode 600 is not
    \\      --max-turns <n>    tool-loop turn ceiling, at least 1
++ (std.fmt.comptimePrint("\n                         (env MICROAGENT_MAX_TURNS, default {d})\n", .{max_turns_default})) ++
    \\      --stall-timeout <s>  seconds the response socket may stay silent
    \\                         before the read fails
++ (std.fmt.comptimePrint("\n                         (env MICROAGENT_STALL_TIMEOUT, default {d})\n", .{default_stall_timeout_s})) ++
    \\      --max-tokens <n>   max_tokens sent to the provider: the ceiling on
    \\                         one response's generated tokens, at least 1
++ (std.fmt.comptimePrint("\n                         (env MICROAGENT_MAX_TOKENS, default {d})\n", .{default_max_tokens})) ++
    \\      --config <file>    TOML config: system prompt addendum, skills, MCP servers
    \\                         and tools (env MICROAGENT_CONFIG, default
    \\                         ~/.microagent/config.toml)
    \\      --ca-bundle <file>
    \\                         PEM file to trust instead of the system store
    \\                         (env MICROAGENT_CA_BUNDLE, SSL_CERT_FILE). Needed in
    \\                         images that ship no ca-certificates.
    \\      --budget <seconds>
    \\                         stop starting turns after this long, and say so.
    \\                         At least 1; leaving it out is what says "no
    \\                         budget". The last turn it takes may run
++ (std.fmt.comptimePrint("\n                         {d} minutes past it; a turn cut off there is\n", .{final_push_grace_m})) ++
    \\                         discarded, not half-applied
    \\                         (env MICROAGENT_BUDGET_SECONDS)
    \\      --max-spend-tokens <n>
    \\                         stop starting turns once the run has billed
    \\                         this many tokens, prompt and completion
    \\                         together. At least 1; leaving it out is what
    \\                         says "no ceiling", the way an unset --budget
    \\                         says "no deadline". The turn that reaches the
    \\                         ceiling is the one that finishes, and the run
    \\                         says on stderr once 80% of it is spent
    \\                         (env MICROAGENT_MAX_SPEND_TOKENS)
    \\      --reasoning-effort <level>
    \\                         reasoning.effort sent to the provider: minimal,
    \\                         low, medium, high, or none to disable (env
    \\                         MICROAGENT_REASONING_EFFORT)
    \\  -h, --help             this text ("help" as the only argument too)
    \\  -V, --version          version
    \\
    \\every long flag also takes --flag=value. A flag wins over the environment
    \\variable for the same option, and wins over one the run could not use:
    \\MICROAGENT_MAX_TURNS=0 with --max-turns 5 is a run with five turns, and the
    \\variable is named on stderr rather than stopping it. A bare -- ends the
    \\flags, so a task that begins with a dash is passed after it. A bare "help"
    \\asks for this text while the prompt is still empty; any other bare word, or
    \\a value of --print, is a task. A
    \\second bare word is the one thing this does not read as a task: two prompts
    \\are a usage error.
    \\
    \\session log:
    \\  MICROAGENT_SESSION_DIR where the per-response JSONL session log goes
    \\                         (default ~/.microagent/sessions; empty writes none)
    \\
    \\skills (the `skills` list in the config, or MICROAGENT_SKILLS as a
    \\colon-separated list that wins over it; default $HOME/.microagent/skills):
    \\  a skill is a directory holding SKILL.md, with an optional frontmatter
    \\  block naming it and saying when it applies. The run lists what it found
    \\  in the system prompt, and the model loads one body at a time with the
    \\  `skill` tool, so a skill the task never needs costs the listing alone.
    \\  Skills are instructions the operator installed: nothing under the
    \\  working directory is read unless the config or the variable names it.
    \\
    \\MCP servers (`[[mcp]]` tables in the config):
    \\  each table names one server, with `name` and one of `command` (a local
    \\  server over stdio, with optional `args`, a list of strings, and `env`, an
    \\  inline table) or `url` (a remote streamable-HTTP server, with optional
    \\  `api_key_env`, `api_key_header` and `timeout`), e.g.
    \\  [[mcp]] name = "fs" command = "npx" args = ["-y", "server-fs", "/tmp"].
    \\  Its tools are offered to the model as mcp__<server>__<tool>, on the same
    \\  deadline as any other tool. A server that cannot start, be reached or
    \\  answer is reported on stderr and skipped.
    \\
    \\Tools (`[tools.<name>]` tables in the config):
    \\  `enabled = false` removes a built-in tool (bash, read, write, edit,
    \\  multi_edit, search, ast, git, todo) from the schema and refuses its calls;
    \\  at least one must stay on. The presets web_search, context7, grep_app and deepwiki
    \\  are public remote MCP servers, on until `enabled = false`, and take `url`,
    \\  `api_key_env` (the NAME of a variable holding the key), `api_key_header`
    \\  and `timeout` (seconds). A name that is not a tool stops the run with exit
    \\  status 2.
    \\
    \\subcommand:
    \\  update [--check]
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
    \\  microagent -- "explain why -Werror is failing in src/net.zig"
    \\
    \\exit status: 0 the run finished, 1 the run failed, 2 the command line was
    \\wrong, 3 the run stopped without an answer (--max-turns, --max-spend-tokens,
    \\or a budget that ran out, or a last response that carried no text, was cut
    \\at --max-tokens, or the provider stopped generating it) so the answer on
    \\stdout is a prefix of the work rather than an answer, 130 interrupted
    \\(Ctrl+C or kill), which takes the tool subprocess with it.
    \\
    \\output: stdout carries the model's text and one JSON line per response,
    \\{"type":"usage","usage":{...}}, and nothing else. stderr carries the tool
    \\gutter, the notes and every error, so a script reading stdout gets the
    \\answer and the token counters.
    \\
    \\MDEBUG=1                 trace a stuck stream on stderr, and print the
    \\                         configuration this run resolved: model, base
    \\                         url, ceilings, the config file that was
    \\                         read, the skill roots, the sandbox and
    \\                         the tools it turned off, and the
    \\                         name of the source the api key came from, never
    \\                         the key.
    \\                         0, off, no, false and an empty value all leave
    \\                         it off.
    \\
    \\A variable set to an empty string is not a value: MICROAGENT_MODEL,
    \\MICROAGENT_BASE_URL, MICROAGENT_REASONING_EFFORT, MICROAGENT_BUDGET_SECONDS,
    \\MICROAGENT_MAX_SPEND_TOKENS, MICROAGENT_MAX_TURNS, MICROAGENT_MAX_TOKENS,
    \\MICROAGENT_STALL_TIMEOUT and MDEBUG keep their defaults, and
    \\MICROAGENT_CA_BUNDLE and MICROAGENT_API_KEY fall through to whatever
    \\comes next.
    \\MICROAGENT_CONFIG, MICROAGENT_SESSION_DIR and MICROAGENT_SKILLS are the
    \\three where empty means off: no config file, no session log, no skills. HOME
    \\is trimmed like the rest, and an empty one is no home rather than a path
    \\off the root.
    \\
;

/// A command line that does not parse: one line saying which argument was
/// wrong, then the help text. Both go to stderr, so a script reading stdout
/// gets nothing from a failed invocation. Exit 2, the conventional code for a
/// usage error.
fn usageError(io: Io, comptime fmt: []const u8, args: anytype) noreturn {
    die(io, "bad arguments", fmt, args);
}

/// A configuration value the program cannot use, whether it arrived on a flag
/// or in the environment. Same exit code and the same help text as a bad
/// argument, but the message names the value and the file or variable it came
/// from, because a bad env var is otherwise invisible at the call site.
fn configError(io: Io, comptime fmt: []const u8, args: anytype) noreturn {
    die(io, "bad configuration", fmt, args);
}

fn die(io: Io, comptime fallback: []const u8, comptime fmt: []const u8, args: anytype) noreturn {
    const msg = std.fmt.allocPrint(std.heap.page_allocator, "microagent: " ++ fmt ++ "\n", args) catch
        "microagent: " ++ fallback ++ "\n";
    net.writeErr(io, msg);
    net.writeErr(io, help_text);
    std.process.exit(2);
}

test "a run that stopped at a ceiling reports a status of its own" {
    // 3 is the status a ceiling-stopped run uses, and it is not one of the four
    // a finished, failed, malformed or interrupted run answers to: a run that
    // reports 0 claims the model finished, and its stdout is a prefix of the
    // work rather than an answer to it. The value is pinned against the help
    // text below, which is where a reader learns it, rather than against a list
    // written here, which could only disagree with itself.
    try std.testing.expectEqual(@as(u8, 3), exit_incomplete);

    // The code is only a contract if the help text states it. A script reads
    // the help, not the source, so a status added to the exit path and not to
    // the table is a status nobody can discover. The paragraph wraps, so the
    // block is gathered across its lines rather than read off the first one.
    var block: std.ArrayList(u8) = .empty;
    defer block.deinit(std.testing.allocator);
    var lines = std.mem.splitScalar(u8, help_text, '\n');
    var started = false;
    while (lines.next()) |line| {
        if (!started) {
            if (std.mem.indexOf(u8, line, "exit status:") == null) continue;
            started = true;
        }
        // The paragraph ends at the blank line, so a status spelled in a
        // wrapped continuation is inside the block rather than beside it.
        if (line.len == 0) break;
        try block.appendSlice(std.testing.allocator, line);
        try block.append(std.testing.allocator, ' ');
    }
    try std.testing.expect(started);
    try std.testing.expect(std.mem.indexOf(u8, block.items, "3 the run stopped without an answer") != null);
}

test "the help text names the default model and the two config-only provider keys" {
    // The model is the one a run reaches without anybody setting it. The base
    // url and the key have no default, so the text has to say where they come
    // from: a reader learns what a run talks to from this text, not from the
    // source. Spelled from the constants, so a default that moves takes the
    // sentence with it.
    try std.testing.expect(std.mem.indexOf(u8, help_text, default_model) != null);
    try std.testing.expect(std.mem.indexOf(u8, help_text, "config key base_url") != null);
    try std.testing.expect(std.mem.indexOf(u8, help_text, "config key") != null);
    // No provider is named as a default, because there is none.
    try std.testing.expect(std.mem.indexOf(u8, help_text, "openrouter") == null);
}

test "the help text names the spend alarm the run prints" {
    // `--max-spend-tokens` warns on stderr once the share is spent, and the
    // usage reference says so. A flag documented without the warning is a flag whose
    // one line of stderr looks like a fault rather than the ceiling working.
    // Spelled from the constant, so a percent that moves takes the sentence
    // with it.
    const said = std.fmt.comptimePrint("once {d}% of it is spent", .{spend_alarm_percent});
    try std.testing.expect(std.mem.indexOf(u8, help_text, said) != null);
}

test "the help text states the ceilings and the budget grace the run uses" {
    // Three numbers a caller sizes a run against, and the only place any of
    // them is written down for a reader is this text. A number written out
    // here and a number the code uses are two facts that can drift, and the
    // one that drifts is the one nobody notices: the default is in force until
    // the reader's second run bills for it. Each sentence is built from the
    // constant the run reads, so a default that moves takes the sentence with
    // it and this test fails if one is ever written out by hand again.
    const turns = std.fmt.comptimePrint("(env MICROAGENT_MAX_TURNS, default {d})", .{max_turns_default});
    const tokens = std.fmt.comptimePrint("(env MICROAGENT_MAX_TOKENS, default {d})", .{default_max_tokens});
    const grace = std.fmt.comptimePrint("{d} minutes past it", .{final_push_grace_m});
    try std.testing.expect(std.mem.indexOf(u8, help_text, turns) != null);
    try std.testing.expect(std.mem.indexOf(u8, help_text, tokens) != null);
    try std.testing.expect(std.mem.indexOf(u8, help_text, grace) != null);
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
/// trim for themselves at the point of parsing, and `githubBearer` trims for
/// the same reason; this makes the environment itself the one place the
/// whitespace is removed.
fn envValue(env: *const std.process.Environ.Map, name: []const u8) ?[]const u8 {
    const v = std.mem.trim(u8, env.get(name) orelse return null, net.env_surrounding);
    return if (v.len == 0) null else v;
}

/// The debugging switch, on unless the variable is set to something that reads
/// as off. A wrapper that exports the name to pass a flag it has not set yet
/// must not turn the trace on by exporting the name at all.
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
/// The same list as the sentence an error needs, derived
/// with `comptimePrint`: a level added above is named by the message without either being told.
const reasoning_effort_names = std.fmt.comptimePrint("{s}, {s}, {s}, {s}, {s}", .{
    reasoning_efforts[0],
    reasoning_efforts[1],
    reasoning_efforts[2],
    reasoning_efforts[3],
    reasoning_efforts[4],
});

/// The level, written through `out`, or the message saying it is not one.
/// The caller decides what a message does with it, because the flag path
/// hands it back as a usage error while the environment path exits on it.
fn reasoningEffort(buf: []u8, value: []const u8, out: *?[]const u8) ?[]const u8 {
    const v = std.mem.trim(u8, value, net.env_surrounding);
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
fn ceiling(comptime T: type, buf: []u8, from: []const u8, value: []const u8, out: *T) ?[]const u8 {
    const n = std.fmt.parseInt(T, std.mem.trim(u8, value, net.env_surrounding), 10) catch
        return std.fmt.bufPrint(buf, "{s} must be a number, got '{s}'", .{ from, clip(value) }) catch
            "must be a number";
    if (n == 0) return std.fmt.bufPrint(buf, "{s} must be at least 1", .{from}) catch
        "must be at least 1";
    out.* = n;
    return null;
}

/// A value the environment named that this run could not use, and the option it
/// configures. Recorded where the value is read and reported after the command
/// line, because the command line is read after the environment and a flag
/// wins over the variable for the same option: `MICROAGENT_MAX_TURNS=0
/// microagent --max-turns 5` is a run with five turns, and stopping on the
/// variable would send an operator after a value the run never used. The base
/// url has always been checked after `parseArgs` for the same reason, and this
/// brings the ceilings and the reasoning level to the same rule.
const EnvProblem = struct {
    option: ValuedOption,
    /// The variable's name, which is what a message about the value leads with.
    name: []const u8,
    /// The value as the environment spelled it, trimmed, so the line is spelled
    /// from the same text the reader saw rather than from a copy of it.
    value: []const u8,
};

/// A ceiling read out of the environment, for the reason `ceiling` returns a
/// message rather than stopping. Each one is a name, an option, a type and a
/// field, so `main` calls this once per variable and the block that reads a
/// value this build cannot use is this function's rather than six of them.
fn ceilingFromEnv(
    comptime T: type,
    env: *const std.process.Environ.Map,
    name: []const u8,
    option: ValuedOption,
    out: *T,
    problem: *?EnvProblem,
) void {
    const v = envValue(env, name) orelse return;
    if (ceiling(T, &.{}, name, v, out) != null) {
        if (problem.* == null) problem.* = .{ .option = option, .name = name, .value = v };
    }
}

/// The same for a ceiling that zero turns off rather than forbids.
fn optionalCeilingFromEnv(
    env: *const std.process.Environ.Map,
    name: []const u8,
    option: ValuedOption,
    out: *?u64,
    problem: *?EnvProblem,
) void {
    const v = envValue(env, name) orelse return;
    if (optionalCeiling(&.{}, name, v, out) != null) {
        if (problem.* == null) problem.* = .{ .option = option, .name = name, .value = v };
    }
}

/// The reasoning level the environment named, checked where it is read and
/// recorded rather than reported, for the reason the ceilings above are.
fn reasoningEffortFromEnv(
    env: *const std.process.Environ.Map,
    name: []const u8,
    out: *?[]const u8,
    problem: *?EnvProblem,
) void {
    const v = envValue(env, name) orelse return;
    if (reasoningEffort(&.{}, v, out) != null) {
        if (problem.* == null) problem.* = .{ .option = .reasoning_effort, .name = name, .value = v };
    }
}

/// The line about a value the environment could not use, spelled by the reader
/// that would have reported it where the value was read. Derived rather than
/// carried, so each message is spelled once in the tree, and it lands in a
/// buffer the caller owns for the rest of the run.
fn envProblemMessage(buf: []u8, problem: EnvProblem) []const u8 {
    switch (problem.option) {
        .reasoning_effort => {
            var unused: ?[]const u8 = null;
            return reasoningEffort(buf, problem.value, &unused) orelse reasoning_effort_names;
        },
        .budget, .max_spend_tokens => {
            var unused: ?u64 = null;
            return optionalCeiling(buf, problem.name, problem.value, &unused) orelse problem.name;
        },
        .max_turns => return ceilingMessage(usize, buf, problem),
        .max_tokens, .stall_timeout => return ceilingMessage(u32, buf, problem),
        // No variable is read for the rest: a model id and a base url are
        // values the provider refuses, and the base url is checked where the
        // run uses it rather than where it is read. The name is the one line
        // that is true of any of them.
        .prompt, .model, .base_url, .api_key, .ca_bundle, .config => {},
    }
    return problem.name;
}

/// One recorded problem through the ceiling reader that recorded it. A value
/// recorded as unusable stays unusable when it is read again, so the message
/// is the one the first read wrote.
fn ceilingMessage(comptime T: type, buf: []u8, problem: EnvProblem) []const u8 {
    var unused: T = 1;
    return ceiling(T, buf, problem.name, problem.value, &unused) orelse problem.name;
}

/// What the run does about a value the environment could not use, once the
/// command line says whether it is still in force. A flag for the same option
/// wins, so the line is a note naming what the run used instead; with no such
/// flag the value is the run's, and the message stops the run as a bad argument
/// would.
fn reportEnvProblem(
    io: Io,
    arena: std.mem.Allocator,
    problem: EnvProblem,
    from_flag: std.EnumSet(ValuedOption),
    buf: []u8,
) void {
    const msg = envProblemMessage(buf, problem);
    if (from_flag.contains(problem.option)) {
        net.note(io, arena, "microagent: {s}; the command line sets this option, so the run goes on\n", .{msg});
        return;
    }
    configError(io, "{s}", .{msg});
}

/// The url as the stderr notes name it, with any `user:password@` in front of
/// the host replaced. Credentials belong in the environment, but an operator
/// who put them in the base url should not find them copied into every line
/// the run writes when the stream fails.
///
/// Redaction is not the only thing a url needs before it is printed. The value
/// is the operator's own `--base-url`, and the notes below name it on every
/// failure, so it is the one place this program hands back bytes the shell
/// passed: `MICROAGENT_BASE_URL=$'\e[2J...'` cleared the screen on the way to
/// an error message, and one that is not UTF-8 reached it as mojibake. The
/// escaping is `chat.safeText`, the one every other diagnostic quoting a value
/// already uses. It is given a budget that no escaping can overrun rather than
/// the quote budget `clip` applies, because a url is the one value a reader
/// needs in full to recognize the endpoint a run was talking to.
fn displayUrl(arena: std.mem.Allocator, url: []const u8) []const u8 {
    const shown = redactUserinfo(arena, url);
    return chat_mod.safeTextAll(arena, shown);
}

/// The url with a password in it removed, for the notes that name the
/// endpoint. Only a url carrying a scheme is rewritten: the authority a bare
/// `user:pass@host/v1` holds is not a url this program can parse, and such a
/// base url is refused before the first request, so it never reaches a note.
fn redactUserinfo(arena: std.mem.Allocator, url: []const u8) []const u8 {
    const scheme_end = std.mem.indexOf(u8, url, "://") orelse return url;
    const rest = url[scheme_end + "://".len ..];
    const authority_end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    const at = std.mem.lastIndexOfScalar(u8, rest[0..authority_end], '@') orelse return url;
    return std.fmt.allocPrint(arena, "{s}[redacted]@{s}", .{ url[0 .. scheme_end + "://".len], rest[at + 1 ..] }) catch url;
}

/// An optional ceiling from a flag or a variable, or the message saying the
/// value is not one. It goes through `ceiling` like the turn and token limits,
/// so a zero budget is refused the same way: zero is not "no limit" to the
/// loop, it is a deadline that has already passed, so the first turn the run
/// would take is the forced final push and then it stops. A caller that meant
/// no ceiling has to say so by leaving the option out.
fn optionalCeiling(buf: []u8, from: []const u8, value: []const u8, out: *?u64) ?[]const u8 {
    var ceiling_value: u64 = undefined;
    if (ceiling(u64, buf, from, value, &ceiling_value)) |m| return m;
    out.* = ceiling_value;
    return null;
}

/// A value quoted back into a message about itself.
///
/// Cutting the value on a codepoint boundary is only half of what a diagnostic
/// needs. An `argv` entry is whatever bytes the shell passed, so `microagent
/// $'\e[2J'` names an argument whose first bytes clear the terminal and
/// `microagent $'\xff'` names one that reaches the screen as mojibake: cutting
/// on a boundary leaves both untouched, and the message is the one place this
/// program hands the operator's own bytes back to the terminal. `chat.safeText`
/// is the escaping the gutter line, the config key and the config path already
/// use, so every diagnostic quoting a value reads the same way.
///
/// The allocation is `page_allocator` because the caller cannot pass one: these
/// functions format into a fixed buffer the parse owns, and `die` already
/// formats its own line the same way. Every message here is terminal, and the
/// process exits on it.
fn clip(s: []const u8) []const u8 {
    return chat_mod.safeText(std.heap.page_allocator, s, net.quoted_value_bytes);
}

/// The option a flag that takes a value sets.
const ValuedOption = enum {
    prompt,
    model,
    base_url,
    api_key,
    ca_bundle,
    config,
    reasoning_effort,
    budget,
    max_spend_tokens,
    max_turns,
    max_tokens,
    stall_timeout,
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
    .{ .short = null, .long = "--max-spend-tokens", .noun = "a number", .option = .max_spend_tokens },
    .{ .short = null, .long = "--max-turns", .noun = "a number", .option = .max_turns },
    .{ .short = null, .long = "--max-tokens", .noun = "a number", .option = .max_tokens },
    .{ .short = null, .long = "--stall-timeout", .noun = "a number of seconds", .option = .stall_timeout },
};

/// The flag `name` spells, in either form, or null when it is not one.
fn valuedFlag(name: []const u8) ?ValuedFlag {
    for (valued_flags) |flag| {
        if (std.mem.eql(u8, name, flag.long)) return flag;
        if (flag.short) |short| if (std.mem.eql(u8, name, short)) return flag;
    }
    return null;
}

fn flagNeeds(buf: []u8, flag: ValuedFlag) []const u8 {
    return std.fmt.bufPrint(buf, "{s} needs {s}", .{ flag.long, flag.noun }) catch "bad arguments";
}

/// The option one valued flag sets. A value the option refuses says so and
/// returns the message; null means it was taken.
fn setValued(
    buf: []u8,
    opts: *Options,
    option: ValuedOption,
    value: []const u8,
) ?[]const u8 {
    opts.from_flag.insert(option);
    switch (option) {
        .prompt => return setPrompt(buf, opts, value),
        .model => opts.model = value,
        .base_url => opts.base_url = value,
        .api_key => opts.api_key = value,
        .ca_bundle => opts.ca_bundle = value,
        .config => opts.config = value,
        .reasoning_effort => return reasoningEffort(buf, value, &opts.reasoning_effort),
        .budget => return optionalCeiling(buf, "--budget", value, &opts.budget_s),
        .max_spend_tokens => return optionalCeiling(buf, "--max-spend-tokens", value, &opts.max_spend_tokens),
        .max_turns => return ceiling(usize, buf, "--max-turns", value, &opts.max_turns),
        .max_tokens => return ceiling(u32, buf, "--max-tokens", value, &opts.max_tokens),
        .stall_timeout => return ceiling(u32, buf, "--stall-timeout", value, &opts.stall_timeout_s),
    }
    return null;
}

/// An argument's name and the value joined to it, as `--flag=value` spells
/// them. `joined` is null for every other argument, and for a short flag: `-p=x`
/// stays the unknown argument it is, because a single dash never joins.
///
/// Both walks of the command line ask this, so the rule that decides which
/// arguments are a flag with a value lives here once.
const SplitArg = struct { name: []const u8, joined: ?[]const u8 };

fn splitArg(arg: []const u8) SplitArg {
    if (arg.len > 2 and arg[0] == '-' and arg[1] == '-') {
        if (std.mem.indexOfScalar(u8, arg, '=')) |eq| {
            return .{ .name = arg[0..eq], .joined = arg[eq + 1 ..] };
        }
    }
    return .{ .name = arg, .joined = null };
}

/// Reads the arguments after the program name into `opts`, formatting any
/// message that names a bad argument into `buf`. Returns null when
/// they parse, or a message naming what was wrong, which `usageError` prints
/// with the help text before exiting 2. A reasoning level and a turn ceiling are
/// refused where they are set, and reported through that usage error; the
/// environment path reports the same kind of bad value through `configError`.
/// Every long flag also takes
/// `--flag=value`, the form `microagent update` already took, so both commands
/// spell an option the same way. `--help` and `--version` win wherever they
/// appear, and stop the parse there.
fn parseArgs(buf: []u8, argv: []const []const u8, opts: *Options) ?[]const u8 {
    var i: usize = 0;
    var flags_ended = false;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        const split = splitArg(arg);
        const name = split.name;
        const joined = split.joined;
        // A bare `--` ends the flags, the way every other command line reads
        // it. A task is model output and starts with a dash as often as not
        // ("-Werror", "--fix"), and there was no spelling for one that did
        // before this: it was an unknown argument, exit 2, before a request.
        if (!flags_ended and std.mem.eql(u8, name, "--")) {
            flags_ended = true;
            continue;
        }
        if (flags_ended) {
            if (arg.len == 0) return empty_prompt_message;
            if (setPrompt(buf, opts, arg)) |m| return m;
        } else if (isFlag(name, "-V", "--version")) {
            opts.action = .version;
            return null;
        } else if (isFlag(name, "-h", "--help")) {
            opts.action = .help;
            return null;
        } else if (valuedFlag(name)) |flag| {
            // A flag that ends the command line and one handed an empty value
            // are the same mistake, so both say the same thing.
            const v = joined orelse if (i + 1 < argv.len) argv[i + 1] else return flagNeeds(buf, flag);
            if (v.len == 0) return flagNeeds(buf, flag);
            if (setValued(buf, opts, flag.option, v)) |m| return m;
            if (joined == null) i += 1;
        } else if (arg.len > 0 and arg[0] != '-') {
            // A bare argument is the prompt. gauntlet's custom-agent
            // definitions insert the model flags before the prompt, so
            // "microagent -p {prompt}" would hand the model flag to -p;
            // taking the prompt positionally makes the order irrelevant.
            // The one bare word that is a request rather than a task is the
            // word `help_word` names, and it only answers while the prompt is
            // still empty, so
            // `microagent "help me find the leak"` is a task and
            // `microagent -p help` is a task, both by the existing rules.
            if (opts.prompt.len == 0 and std.mem.eql(u8, arg, help_word)) {
                opts.action = .help;
                return null;
            }
            if (setPrompt(buf, opts, arg)) |m| return m;
        } else if (arg.len == 0) {
            return empty_prompt_message;
        } else {
            return std.fmt.bufPrint(buf, "unknown or incomplete argument '{s}'", .{clip(arg)}) catch "bad arguments";
        }
    }
    return null;
}

/// An empty word is a prompt with nothing in it, which is the same mistake as
/// `--print=`. Saying it is an unknown argument would describe a flag nobody
/// wrote, so both spellings of the mistake get this one sentence.
const empty_prompt_message = "the prompt is empty: pass the task as an argument or with --print";

/// The action `--help` or `--version` asks for, or null when the command line
/// asks for neither. Read over the same arguments, and with the same rules,
/// as `parseArgs` above: a value a flag takes is stepped over, so
/// `microagent -p --help` is a run whose prompt is the words `--help` and not
/// a request for help, in both places, and a bare `--` ends the flags in both
/// too, so `microagent -- --help` is a run rather than a request for help. A
/// change to how one walks the command line is a change to both.
fn earlyAction(argv: []const []const u8) ?Action {
    var i: usize = 0;
    var prompt_seen = false;
    while (i < argv.len) : (i += 1) {
        const split = splitArg(argv[i]);
        if (std.mem.eql(u8, split.name, "--")) return null;
        if (isFlag(split.name, "-V", "--version")) return .version;
        if (isFlag(split.name, "-h", "--help")) return .help;
        if (valuedFlag(split.name)) |flag| {
            // `--print` is the prompt flag, so its value is the prompt the
            // walk below counts. Without this the two walks disagreed:
            // `microagent -p task help` printed the help text and exited 0
            // here, where `parseArgs` refuses the same command line because
            // the task and the word `help` are two prompts.
            if (flag.option == .prompt) prompt_seen = true;
            if (split.joined != null) continue;
            i += 1;
            continue;
        }
        // The first bare word is the prompt, and `help` as that word is the
        // request `parseArgs` answers to below, so this walk reaches the same
        // answer. A word after it is a second prompt the parser refuses, and
        // the flag decides what is printed, not the word.
        if (split.name.len == 0 or split.name[0] == '-') continue;
        if (!prompt_seen and std.mem.eql(u8, split.name, help_word)) return .help;
        prompt_seen = true;
    }
    return null;
}

/// The one bare word that asks for the help text rather than naming a task.
/// `update` answers to `--help` and `-h` only, so the word is spelled here.
const help_word = "help";

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

/// The key this run will use, and where it came from.
const Key = struct { value: []const u8, source: []const u8 };

/// The key this run sends, and the name of the source it came from.
///
/// `--api-key` wins, then `key_var`, then the `api_key` key of the config file.
/// There is no key file to look in: a provider's key belongs to the account
/// paying for the run, and a path baked into the binary named one provider's.
/// `MDEBUG` prints the source by name.
fn resolveKey(environ: *std.process.Environ.Map, given: []const u8, from_config: []const u8) Key {
    if (given.len > 0) return .{ .value = given, .source = "--api-key" };
    if (envValue(environ, key_var)) |v| return .{ .value = v, .source = key_var };
    if (from_config.len > 0) return .{ .value = from_config, .source = "config file" };
    return .{ .value = "", .source = "none" };
}

/// The one variable the API key is read from.
const key_var = "MICROAGENT_API_KEY";

test "a key carrying a control character is refused, from every source" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const arena = state.allocator();

    var env: std.process.Environ.Map = .init(arena);
    // The ordinary way one arrives: a wrapper exporting a value it read out of
    // a file carries the newline that file ended with, and a config file
    // edited by hand can hold a CR. Both are the key the run would put in an
    // `Authorization` header, so both are refused before the first request.
    try env.put(key_var, "sk-a-key\r\nInjected: x");
    const from_env = resolveKey(&env, "", "");
    try std.testing.expectEqualStrings(key_var, from_env.source);
    try std.testing.expect(net.hasHeaderControlBytes(from_env.value));

    const from_flag = resolveKey(&env, "sk-a\nkey", "");
    try std.testing.expectEqualStrings("--api-key", from_flag.source);
    try std.testing.expect(net.hasHeaderControlBytes(from_flag.value));

    // A separate map, so the variable above does not answer first: the file is
    // the weakest of the three, and a control character there is the case a
    // hand-edited config file produces.
    var bare: std.process.Environ.Map = .init(arena);
    const from_file = resolveKey(&bare, "", "sk-a\x7fkey");
    try std.testing.expectEqualStrings("config file", from_file.source);
    try std.testing.expect(net.hasHeaderControlBytes(from_file.value));

    // A key that is only whitespace-bearing in the ordinary sense is a key.
    const clean = resolveKey(&bare, "sk-a key", "");
    try std.testing.expect(!net.hasHeaderControlBytes(clean.value));
}

/// Every environment variable the program reads, which is what a user has to
/// know to configure it. The resolution order each one is read in is spelled by
/// the reader that reads it; this list is the documentation check and nothing
/// else, so a variable added to a reader and to neither `--help` nor the usage reference
/// is one a user finds by reading the source. `net.caBundlePath` carries the
/// bundle's two and `secret_env_vars` the credentials scrubbed from a tool's
/// environment; this is the union of those with the ceilings, the paths and the
/// GitHub token, held to one list so the two documents cannot each name a
/// different subset of it.
const env_vars = [_][]const u8{
    "MICROAGENT_MODEL",
    base_url_var,
    key_var,
    "MICROAGENT_MAX_TURNS",
    "MICROAGENT_MAX_TOKENS",
    "MICROAGENT_STALL_TIMEOUT",
    "MICROAGENT_BUDGET_SECONDS",
    "MICROAGENT_MAX_SPEND_TOKENS",
    "MICROAGENT_REASONING_EFFORT",
    "MICROAGENT_CONFIG",
    "MICROAGENT_SKILLS",
    "MICROAGENT_CA_BUNDLE",
    "SSL_CERT_FILE",
    "MICROAGENT_SESSION_DIR",
    "GITHUB_TOKEN",
    "MDEBUG",
    "HOME",
};

/// The variables whose empty value is not a value: a wrapper that populates
/// the environment from a file exports a name with nothing behind it, and
/// `envValue` reads that as unset, so each of these keeps its default rather
/// than becoming a request the provider refuses. The rest of `env_vars` reads
/// empty as something else, and the two documents below spell out which is
/// which: `MICROAGENT_CONFIG` and `MICROAGENT_SESSION_DIR` turn their feature
/// off, and the bundle falls through to the next source.
///
/// The help text and docs/usage.md both state this in prose, and prose
/// drifts: a variable one names here and the other leaves out means a reader
/// of that document cannot tell whether an empty value falls back or reaches
/// the provider. The list is the category, and the test below holds both
/// documents to it.
const empty_is_unset_vars = [_][]const u8{
    "MICROAGENT_MODEL",
    base_url_var,
    "MICROAGENT_REASONING_EFFORT",
    "MICROAGENT_BUDGET_SECONDS",
    "MICROAGENT_MAX_SPEND_TOKENS",
    "MICROAGENT_MAX_TURNS",
    "MICROAGENT_MAX_TOKENS",
    "MICROAGENT_STALL_TIMEOUT",
    "MDEBUG",
};

/// Every variable this program reads a credential out of, and which a tool
/// subprocess therefore never sees. The provider key plus the GitHub
/// token `microagent update` presents to the releases API: all of them are
/// credentials this binary sends in an `Authorization` header, so all of them
/// belong to the same scrub, and a name read by one subcommand is a secret to
/// the other.
const secret_env_vars = [_][]const u8{ key_var, "GITHUB_TOKEN" };

/// The environment every tool subprocess runs under: this process's, less the
/// credentials.
///
/// A tool's output is a tool message, and a tool message is re-sent to the
/// provider on every later turn of the run. So `bash: env` or `bash:
/// printenv` under an inherited environment did not print a variable, it put
/// the run's API key in the transcript, on the wire, for the rest of the run.
/// Removing the credentials from what the child can see closes that without
/// trying to parse a shell to work out which of its commands print an
/// environment, which no name check can do reliably.
///
/// The token `microagent update` authenticates with is in the same list for the
/// same reason: it is a credential this binary sends over the wire, an operator
/// who exported it for an update has no reason to expect a coding run's tool
/// output to carry it to the provider, and no tool in the set needs it.
///
/// Everything else is inherited. A build tool that needs `PATH`, `HOME` or a
/// CI variable set in the caller's shell has to keep working, so the map keeps
/// everything but the names above. It is scrubbed in place, after the key is
/// read: a copy of the whole environment was a fifth of the work before the
/// first request.
fn scrubSecrets(env: *std.process.Environ.Map, remote: []const mcp_mod.Entry) void {
    for (secret_env_vars) |name| _ = env.swapRemove(name);
    // The variables that hold a remote server's key are credentials this
    // binary sends over the wire, so a tool subprocess does not inherit them.
    for (remote) |entry| _ = env.swapRemove(entry.api_key_env);
}

/// What the config file said for this run, and the path it was read from, the
/// latter for the trace.
const LoadedConfig = struct {
    /// Text appended to the system prompt, empty for none.
    system_prompt_extra: []const u8,
    /// The repository instructions file, and whether the config named it.
    agents_file: []const u8,
    agents_file_named: bool,
    /// The provider settings the file named, empty when it named none.
    model: []const u8,
    base_url: []const u8,
    api_key: []const u8,
    /// The skill directories the config file named, or null when it named
    /// none, which is how the caller tells "use the default root" from "the
    /// file turned skills off".
    skills: ?[]const []const u8,
    /// The MCP servers the config file declared.
    mcp: []const mcp_mod.Entry,
    /// Commands denied from running via the bash tool.
    deny_commands: []const []const u8,
    /// The built-in tools the config file switched off.
    disabled_tools: std.EnumSet(chat_mod.Tool),
    /// The `[tools.*]` mistake the run stops on, if there is one.
    tool_problem: ?config_mod.ToolProblem,
    /// Sandbox settings to confine filesystem writes.
    sandbox: config_mod.Sandbox,
    source: ?[]const u8,
};

/// Everything the config file said, from the TOML named by --config,
/// MICROAGENT_CONFIG or `$HOME/.microagent/config.toml`. A missing file, an unreadable one, or a line the
/// reader could not use costs the run nothing: everything that was understood
/// still applies. The source is the file that was looked for, readable or not,
/// because the question the trace answers is which one was consulted.
fn loadConfig(io: Io, init: std.process.Init, arena: std.mem.Allocator, config: []const u8) LoadedConfig {
    const source = configSource(init.environ_map, arena, config);
    // Both a path and a key out of this file are quoted through `safeText`
    // rather than `clip`: a config is a file a reviewed repository can
    // commit, so its lines carry whatever bytes the commit did, and the same
    // is true of a path a directory name was spelled with. The two untrusted
    // byte paths this program already has normalize what they print, and a
    // diagnostic is the third.
    // No file is the same as an empty one, so the presets that are on by default are on.
    var parsed = config_mod.parse(arena, "");
    if (source.path) |p| {
        const text = std.Io.Dir.cwd().readFileAlloc(io, p, arena, .limited(max_config_bytes)) catch |err| blk: {
            // The default path with nothing at it is a first run, and a first
            // run gets the template: the commented file the repository ships,
            // written where the next edit will find it. A path somebody named
            // is never created for them, and a file that is there is never
            // touched.
            if (err == error.FileNotFound and !source.named) writeDefaultConfig(io, arena, source);
            if (configReadWorthReporting(source.named, err))
                net.note(io, arena, "microagent: config {s}: {s}; using the built-in defaults\n", .{ configPathText(arena, source), @errorName(err) });
            break :blk null;
        };
        if (text) |t| parsed = config_mod.parse(arena, t);
    }
    if (parsed.problem) |problem| reportConfigProblem(io, arena, source, problem);
    return .{
        .system_prompt_extra = parsed.system_prompt_extra,
        .agents_file = parsed.agents_file,
        .agents_file_named = parsed.agents_file_named,
        .model = parsed.model,
        .base_url = parsed.base_url,
        .api_key = parsed.api_key,
        .skills = parsed.skills,
        .mcp = parsed.mcp,
        .deny_commands = parsed.deny_commands,
        .disabled_tools = parsed.disabled_tools,
        .tool_problem = parsed.tool_problem,
        .sandbox = parsed.sandbox,
        .source = source.path,
    };
}

/// One line on stderr for the first thing the config could not use. The kind
/// decides the sentence: a value the key does not take, a key the file does
/// not define, and a `[[mcp]]` table with no server in it are different
/// mistakes with different fixes.
fn reportConfigProblem(io: Io, arena: std.mem.Allocator, source: ConfigSource, problem: config_mod.Problem) void {
    const key = chat_mod.safeText(arena, problem.key, net.quoted_value_bytes);
    switch (problem.kind) {
        .bad_value => net.note(io, arena, "microagent: config {s}: '{s}' is not a value this key takes; keeping the default\n", .{ configPathText(arena, source), key }),
        .unknown_key => net.note(io, arena, "microagent: config {s}: '{s}' is not a key this file uses; keeping the default\n", .{ configPathText(arena, source), key }),
        .bad_server => net.note(io, arena, "microagent: config {s}: a [[mcp]] entry with no usable name or command is skipped\n", .{configPathText(arena, source)}),
        .duplicate_server => net.note(io, arena, "microagent: config {s}: the MCP server '{s}' is declared twice; the second entry is skipped\n", .{ configPathText(arena, source), key }),
        .list_truncated => net.note(io, arena, "microagent: config {s}: '{s}' is declared more than once and its values could not be joined; only the ones declared before the lost one are in force\n", .{ configPathText(arena, source), key }),
    }
}

/// The config path as a diagnostic should spell it. Built where a diagnostic
/// is about to be written rather than once for the run: every use of it is an
/// error path, and most runs take none of them, so computing it up front meant
/// walking the path byte by byte into a fresh allocation that was then dropped.
///
/// Escaped whole rather than cut to `net.quoted_value_bytes`, and the trace
/// below already spells the same path that way: this line is on the path a
/// reader has to go and fix, and a path cut at 80 bytes ends mid-directory
/// naming one that is not there. The key of a config problem is still cut,
/// because a key is short by construction and a line quoting a whole file is
/// not a diagnostic.
fn configPathText(arena: std.mem.Allocator, source: ConfigSource) []const u8 {
    return chat_mod.safeTextAll(arena, source.path orelse "");
}

/// The configuration this run resolved, on stderr when MDEBUG is on. Precedence
/// spans three sources per option, so the only way to tell which one answered
/// is to be told; the key is named by the source it came from and never
/// printed, and a base url is the redacted spelling so credentials in one do
/// not reach a log either.
///
/// Every value the environment supplied is escaped by `traceText`, the same
/// reason the notes below it are: a model id, a bundle path, a session
/// directory and the config path are all operator-supplied bytes, and a
/// `MICROAGENT_SESSION_DIR` carrying a C0 byte wrote it to the terminal
/// unsanitized on the one line whose whole job is telling an operator what the
/// run resolved.
fn traceConfig(
    io: Io,
    arena: std.mem.Allocator,
    opts: Options,
    loaded: LoadedConfig,
    skill_roots: []const skill_mod.Root,
    key_source: []const u8,
) void {
    if (!debug_enabled) return;
    net.note(io, arena,
        \\[mdebug] model={s} base_url={s}
        \\[mdebug] max_turns={d} max_tokens={d} budget_s={s} max_spend_tokens={s} reasoning_effort={s}
        \\[mdebug] ca_bundle={s} session_dir={s}
        \\[mdebug] config={s} system_prompt_extra_bytes={d}
        \\[mdebug] skills={d} skill_roots={s}
        \\[mdebug] mcp_servers={d} mcp_tools={d}
        \\[mdebug] sandbox={s} writable_roots={d} disabled_tools={d} deny_commands={d}
        \\[mdebug] api key from {s}
        \\
    , .{
        traceText(arena, opts.model),
        displayUrl(arena, opts.base_url),
        opts.max_turns,
        opts.max_tokens,
        if (opts.budget_s) |b| std.fmt.allocPrint(arena, "{d}", .{b}) catch "?" else "unset",
        if (opts.max_spend_tokens) |m| std.fmt.allocPrint(arena, "{d}", .{m}) catch "?" else "unset",
        traceText(arena, opts.reasoning_effort orelse "unset"),
        traceText(arena, if (opts.ca_bundle.len == 0) "unset" else opts.ca_bundle),
        traceText(arena, if (opts.session_dir.len == 0) "off" else opts.session_dir),
        traceText(arena, loaded.source orelse "none"),
        loaded.system_prompt_extra.len,
        opts.skills.items.len,
        skillRootsText(arena, skill_roots),
        opts.mcp.items.len,
        opts.mcp.toolCount(),
        // The three settings that decide what the run is allowed to touch, and
        // the ones a trace is the only place to look when a machine behaves as
        // though the sandbox were on and it is not. The roots are counted
        // rather than listed: they are already in `sandbox.writable` in the
        // file the line above names, and a count is what tells a reader that
        // the config was read at all.
        if (opts.sandbox.enabled) "enabled" else "off",
        opts.writable_roots.len,
        opts.disabled_tools.count(),
        opts.deny_commands.len,
        chat_mod.safeTextAll(arena, key_source),
    });
}

/// The roots skills were read from, as one line: a run that found no skills
/// and a run that looked in the wrong directories report the same count, and
/// the directories are the only part of that line a reader can go and look at.
/// Each path is escaped on its own and the paths are joined by a comma, so one
/// path carrying a separator does not read as two roots.
fn skillRootsText(arena: std.mem.Allocator, roots: []const skill_mod.Root) []const u8 {
    if (roots.len == 0) return "none";
    var buf: std.ArrayList(u8) = .empty;
    for (roots, 0..) |root, i| {
        if (i != 0) buf.appendSlice(arena, ", ") catch return "none";
        buf.appendSlice(arena, traceText(arena, root.path)) catch return "none";
    }
    return buf.items;
}

/// A configuration value the way the trace should spell it: escaped, and in
/// full rather than cut to `net.quoted_value_bytes`, because the trace exists to
/// let a reader recognize the value the run resolved, and a truncated path
/// names no directory. Same escaping, same reasoning, as `displayUrl` above.
fn traceText(arena: std.mem.Allocator, value: []const u8) []const u8 {
    return chat_mod.safeText(arena, value, value.len *| chat_mod.safe_text_widening);
}

/// Whether a config that could not be read is worth a line on stderr. A
/// config somebody named is one the caller believes is there, so any failure
/// is said out loud. The default path is missing on most machines and that is
/// not a fault, but a file that is there and is a directory, is unreadable,
/// or is over the cap is: the run continues on the built-in levels, and
/// silence there is a misconfiguration nothing reports.
fn configReadWorthReporting(named: bool, err: anyerror) bool {
    return named or err != error.FileNotFound;
}

/// The commented template the release ships, embedded at build time.
const config_template = build_options.config_template;

/// Writes the config template to the default path, for the first run that found
/// nothing there. Nothing is fatal: a config file is optional, so a home this
/// process cannot write to costs the run the same defaults it would have had,
/// and the line says so rather than leaving the run silently unchanged.
///
/// The file is created exclusively, so a second run racing this one finds the
/// first run's file and keeps it. Mode 0600, because the file may later hold an
/// api key and a reader who has not decided that yet is better served by a
/// tighter file than a looser one.
fn writeDefaultConfig(io: Io, arena: std.mem.Allocator, source: ConfigSource) void {
    const path = source.path orelse return;
    const shown = configPathText(arena, source);
    if (std.fs.path.dirname(path)) |dir| {
        _ = std.Io.Dir.cwd().createDirPathStatus(io, dir, default_config_dir_mode) catch |err| {
            // `dir` is the parent of the operator's own `--config` value, and it
            // reaches the terminal through a note like any other, so it is
            // escaped like `shown` is: the escape is what keeps a path holding
            // a control byte from writing over the line that reports it.
            net.note(io, arena, "microagent: config {s}: {s} could not be created ({s}), so the template was not written\n", .{ shown, chat_mod.safeTextAll(arena, dir), @errorName(err) });
            return;
        };
    }
    const file = std.Io.Dir.createFileAbsolute(io, path, .{ .exclusive = true, .permissions = default_config_mode }) catch |err| switch (err) {
        // Another run wrote it between the read and this call, which is the
        // file the reader wanted and no reason for a line.
        error.PathAlreadyExists => return,
        else => |e| {
            net.note(io, arena, "microagent: config {s}: the template could not be created ({s}); the built-in defaults are in force\n", .{ shown, @errorName(e) });
            return;
        },
    };
    defer file.close(io);
    file.writeStreamingAll(io, config_template) catch |err| {
        net.note(io, arena, "microagent: config {s}: the template could not be written ({s}); the built-in defaults are in force\n", .{ shown, @errorName(err) });
        return;
    };
    net.note(io, arena, "microagent: config {s}: no file there, so the commented template was written; edit it to configure the run\n", .{shown});
}

/// The config file holds operator settings and may later hold a provider key, so
/// the template is written as the same 0600 the rest of the home state uses,
/// under a 0700 directory holding this and the session logs.
const default_config_mode: Io.File.Permissions = @enumFromInt(@as(std.posix.mode_t, 0o600));
const default_config_dir_mode: Io.File.Permissions = @enumFromInt(@as(std.posix.mode_t, 0o700));

/// The file the config is read from, and whether anything named it. A
/// flag or a variable naming a file that cannot be read is a caller's mistake
/// worth reporting; the default path is absent on most machines.
const ConfigSource = struct { path: ?[]const u8, named: bool };

/// Where the config is read from: --config, else MICROAGENT_CONFIG, else
/// `$HOME/.microagent/config.toml`. An empty MICROAGENT_CONFIG turns the
/// file off, as does a home that is not there. A named path may start with
/// `~`, which `net.expandHome` answers: a value that came out of a wrapper's
/// environment file never went through a shell, and the help text prints the
/// tilde spelling. Takes the environment map rather than the whole `Init`, so
/// the precedence is testable without one.
fn configSource(env: *const std.process.Environ.Map, arena: std.mem.Allocator, config: []const u8) ConfigSource {
    if (config.len > 0) return .{ .path = std.fs.path.resolve(arena, &.{net.expandHome(env, arena, config)}) catch config, .named = true };
    if (env.get("MICROAGENT_CONFIG")) |raw| {
        const path = std.mem.trim(u8, raw, net.env_surrounding);
        if (path.len == 0) return .{ .path = null, .named = false };
        return .{ .path = std.fs.path.resolve(arena, &.{net.expandHome(env, arena, path)}) catch path, .named = true };
    }
    const home = net.homeDir(env) orelse return .{ .path = null, .named = false };
    const path = std.fs.path.join(arena, &.{ home, ".microagent", "config.toml" }) catch
        return .{ .path = null, .named = false };
    return .{ .path = std.fs.path.resolve(arena, &.{path}) catch path, .named = false };
}

/// The clock the run's budget is measured on: the one that keeps counting
/// while the machine is suspended. `Io.Clock.awake` is CLOCK_MONOTONIC, and
/// that clock stops for a suspend, so a laptop closed for the night wakes with
/// the whole `--budget` still in hand and spends it all on a fresh provider
/// bill, which is the exact outcome the ceiling exists to prevent. `.boot` is
/// CLOCK_BOOTTIME on Linux and CLOCK_MONOTONIC_RAW on macOS, and both include
/// the suspend. It stays monotonic either way, so an NTP step or a manual
/// clock change cannot move a deadline, and a tool's own timeout stays on
/// `.awake` because a child that was not running spent none of its own.
const budget_clock: Io.Clock = .boot;

/// The clock a response's `elapsed_ms` is measured on: the one that stops for a
/// suspend. It is `.awake` for the same reason a tool's own timeout is, and it
/// is not `budget_clock` even though both are monotonic, because the two
/// measure different things. The budget is a promise about wall time, so the
/// time the machine spent off counts against it. The model's time is the time
/// it spent generating, and a machine that was asleep was not generating: the
/// record's number is what a monitor divides a turn's tokens by, so counting a
/// suspend in it reports a generation at four tokens an hour. Both the stamp
/// and the reading are on this one clock, so the difference is a duration and
/// not the gap between two unrelated origins.
const model_clock: Io.Clock = .awake;

/// The run's time budget as an instant on the clock the loop already reads.
/// Every part of a turn asks this, not just the top of the loop: a provider
/// that is slow rather than broken hands the loop one long turn, and a budget
/// only checked between turns is a budget that provider ignores, which is the
/// run being killed in the middle of the turn the budget exists to avoid.
///
/// A deadline is a number on `budget_clock`, so it is read there and nowhere
/// else: an instant taken from one clock and compared against the other is
/// two unrelated origins, and the difference between them is however long the
/// machine has been asleep.
const Budget = struct {
    /// Nanoseconds on `budget_clock`, or null when no budget was set.
    deadline_ns: ?i96 = null,

    fn of(started_ns: i96, seconds: ?u64) Budget {
        const s = seconds orelse return .{};
        return .{ .deadline_ns = started_ns + @as(i96, s) * std.time.ns_per_s };
    }

    fn expired(self: Budget, io: Io) bool {
        const d = self.deadline_ns orelse return false;
        return Io.Timestamp.now(io, budget_clock).nanoseconds >= d;
    }

    /// Milliseconds left on the budget, or null when there is no budget. Zero
    /// means expired; callers that only care about that use `expired`.
    ///
    /// A budget is seconds the caller typed, and a cast is where that stops
    /// being trustworthy: the deadline is held at nanosecond resolution, so a
    /// budget past `u64` milliseconds (about 5.8e8 years, which
    /// `--budget 20000000000000000` is) needs more milliseconds than
    /// the answer has bits for. `cast` saturates instead, and a ceiling no
    /// caller can wait out is as good an answer as the exact figure.
    fn remainingMs(self: Budget, io: Io) ?u64 {
        const d = self.deadline_ns orelse return null;
        const now = Io.Timestamp.now(io, budget_clock).nanoseconds;
        if (now >= d) return 0;
        return std.math.cast(u64, @divTrunc(d - now, std.time.ns_per_ms)) orelse std.math.maxInt(u64);
    }

    /// The ceiling a tool's own deadline may not pass, or null when the run
    /// set no budget. The floor stops a nearly-spent budget from handing a tool
    /// a zero timeout, which fails instantly and reads as a broken tool rather
    /// than a spent budget.
    fn toolCeilingMs(self: Budget, io: Io) ?u64 {
        const left = self.remainingMs(io) orelse return null;
        return @max(left, tool_timeout_floor_ms);
    }

    /// Whether this run can afford to wait `want_ms` before its next attempt,
    /// False means the caller must not make the attempt: a retry taken after a
    /// refusal the provider is still refusing is a second billable refusal, and
    /// one taken by sitting out the wait is a turn that never arrives.
    ///
    /// A provider asking for two minutes is weather and sitting it out is the
    /// right answer to it. Sitting it out inside a caller's per-review timeout
    /// is not: the run is killed mid-sleep with nothing to show for it, which
    /// is the one thing the budget exists to prevent. So the wait is taken only
    /// when the budget covers it.
    fn canAffordWait(self: Budget, io: Io, want_ms: u64) bool {
        const left = self.remainingMs(io) orelse return true;
        return want_ms < left;
    }

    /// The same budget with `seconds` more to run. The final push is the one
    /// turn that is allowed past the budget, and the grace is what keeps that
    /// turn bounded too: it lands or it is cut off with a reason, never left
    /// waiting on a provider that stopped answering.
    fn withGraceNs(self: Budget, seconds: u64) Budget {
        const d = self.deadline_ns orelse return self;
        return .{ .deadline_ns = d + @as(i96, seconds) * std.time.ns_per_s };
    }
};

/// How much of a turn's peak the run keeps for the next one.
///
/// Resetting with the capacity retained is what keeps a turn from asking the
/// allocator again on every turn, and an ordinary turn is a couple of
/// megabytes, so nothing is given back for it. The ceiling matters for the turn
/// that is not ordinary: a response at `max_response_bytes` fills the turn's
/// content buffer in full, and retaining that leaves 16 MB resident for the rest
/// of the run to serve turns that need a few. The stdout copy of the same
/// response is the run's own allocator, not the turn's, so it does not count
/// against this ceiling. Four megabytes is comfortably above an ordinary turn
/// and far below the ceiling, so a big turn re-allocates once and a normal one
/// never notices.
const turn_arena_retain_bytes: usize = 4 * 1024 * 1024;

/// How long the final turn may run past the budget. It exists to turn what the
/// model has already read into one edit, which is a few tool calls, not a
/// fresh investigation.
const final_push_grace_s: u64 = 300;

/// The same grace in whole minutes, which is how the help text states it: a
/// reader deciding whether `--budget` leaves room for a last edit counts in
/// minutes, not in a number of seconds. A grace that stopped being a whole
/// number of minutes would print a fraction of one and read as noise, so the
/// help takes the value in the unit it can spell.
const final_push_grace_m: u64 = final_push_grace_s / 60;
comptime {
    if (final_push_grace_s % 60 != 0) @compileError("the --budget help states the last turn's grace in whole minutes");
}

/// The shortest a tool timeout may be cut to, even with the budget spent: a
/// zero timeout would fail before the tool could even start.
const tool_timeout_floor_ms: u64 = 5_000;

/// How close to the spend ceiling a run says so, as a percentage of the cap.
/// Said once, on the turn that crosses it, so an operator watching a bill sees
/// the run approaching its own limit rather than discovering afterwards that it
/// stopped there. A cap small enough to be crossed by the first turn is never
/// announced: the ceiling itself is the news, and a warning above it would be
/// a warning about every run.
const spend_alarm_percent: u64 = 80;

/// Whether a run that has billed `spent` tokens may take another turn.
///
/// The count is the run's `total`, which is the whole conversation re-sent plus
/// what came back, cached prompt tokens included. Counting the cached ones is
/// the conservative reading: they are billed, at a lower rate, and a ceiling
/// the run can pass while cheap is not the ceiling an operator set.
///
/// The turn that reaches the cap is the one that is allowed to finish. The
/// check is made before a turn is started, not after one is billed, so the
/// provider never sees a request this run has already priced itself out of.
fn spendCeilingReached(spent: u64, cap: ?u64) bool {
    const limit = cap orelse return false;
    return spent >= limit;
}

/// Whether a run that has billed `spent` tokens is close enough to its ceiling
/// to say so. The first turn at or past `spend_alarm_percent` of the cap.
fn spendAlarmDue(spent: u64, cap: ?u64) bool {
    const limit = cap orelse return false;
    if (limit < 2) return false;
    return spent >= spendAlarmThreshold(limit);
}

/// The token count the alarm is due at: `spend_alarm_percent` of the cap.
///
/// The percentage is taken on a widened product rather than on `u64`, because
/// `limit * percent` overflows a cap near the `u64` ceiling and the cap is
/// checked, not assumed. Dividing each part before summing instead lost the
/// remainder's fraction: a cap of three asked for 80% of it and answered one,
/// so the alarm could not fire before the ceiling it precedes. The widen is
/// exact for every `u64` and the result is the floor the alarm compares
/// against, so a run that has spent 80% of its cap and not a token more is
/// announced.
fn spendAlarmThreshold(limit: u64) u64 {
    return @intCast((@as(u128, limit) * spend_alarm_percent) / 100);
}

/// Why a run stopped at its spend ceiling, in the words the operator reads, and
/// the announcement that precedes the stop. Null for a run with no ceiling, and
/// for a run that has not reached the announcement yet.
fn spendNotice(arena: std.mem.Allocator, spent: u64, cap: ?u64, turn: usize) ?[]const u8 {
    if (spendCeilingReached(spent, cap))
        return std.fmt.allocPrint(arena, "microagent: stopped at the --max-spend-tokens ceiling ({d} tokens) after {d} turn(s) and {d} token(s); the answer is a prefix of the work\n", .{
            cap.?, turn, spent,
        }) catch
            "microagent: stopped at the --max-spend-tokens ceiling; the answer is a prefix of the work\n";
    if (spendAlarmDue(spent, cap))
        return std.fmt.allocPrint(arena, "microagent: {d} of the {d} token ceiling spent after {d} turn(s)\n", .{
            spent, cap.?, turn,
        }) catch
            "microagent: the run is close to its token ceiling\n";
    return null;
}

/// How a turn ended, which is what tells a finished run from a stopped one.
///
/// A turn is finished when the model stopped asking for tools on its own, and
/// said something. The other two end the run without that: `wants_tools` is a
/// turn whose answer was a request for more work, and `cut_off` is a turn the
/// budget ended before there was a turn to append, or a response that called no
/// tool and is not an answer either (`incompleteAnswer`). Both leave a prefix of
/// an answer on stdout, or none, so neither may report itself as a finished
/// run.
const TurnEnd = enum { answered, wants_tools, cut_off };

/// The agent loop: keep asking until the model stops calling tools.
///
/// What it returns is the last turn's end, and only `.answered` is a run that
/// reached an answer on its own. A loop that leaves through `--max-turns` or
/// through the spend ceiling is `.cut_off`: the model was still working when
/// the ceiling took the turn away, so what is on stdout is a prefix.
fn run(
    client: *std.http.Client,
    io: Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    opts: Options,
    msgs: *std.ArrayList(u8),
    tool_env: *const std.process.Environ.Map,
    mcp: *mcp_mod.Servers,
) !TurnEnd {
    const started = Io.Timestamp.now(io, budget_clock).nanoseconds;
    const budget = Budget.of(started, opts.budget_s);
    var session: ?session_mod.Session = session_mod.open(io, arena, opts.session_dir, opts.model);
    defer session_mod.close(io, &session);
    // The constant half of every request, built once from the run arena. It is
    // a pure function of `opts`, and nothing in the loop below changes any of
    // what goes into it: the model, the token ceiling, the reasoning field, the
    // built-in tool schema, the run's skills and the servers' tools are all
    // settled before the first turn. Rebuilding it per turn walked that whole
    // schema again and copied every remote tool's `inputSchema` into a fresh
    // buffer on the turn arena, once per turn, for bytes the previous turn had
    // already produced identically. On a run with three servers carrying
    // megabytes of schemas that is the largest allocation the loop makes after
    // the conversation itself, and it is the one that grows with the server
    // count rather than with the work.
    const prefix = try bodyPrefix(arena, opts);
    const ep = try endpoint(arena, opts);
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
    var usage: chat_mod.Usage = .{};
    var compaction_floor: usize = 0;
    var verify_asked = false;
    var spend_alarmed = false;
    var progress: Progress = .{};
    while (turn < opts.max_turns) : (turn += 1) {
        _ = turn_state.reset(.{ .retain_with_limit = turn_arena_retain_bytes });
        // Before the time budget, because the final push below is a turn like
        // any other and would spend past a ceiling the operator set in money
        // rather than in seconds. Announced once, on the turn that crosses the
        // alarm, and spent for the rest of the run: a warning repeated on every
        // turn after it is noise the first one has already made.
        if (spendNotice(arena, usage.total, opts.max_spend_tokens, turn)) |notice| {
            if (spendCeilingReached(usage.total, opts.max_spend_tokens)) {
                net.writeErr(io, notice);
                return .cut_off;
            }
            if (!spend_alarmed) {
                spend_alarmed = true;
                net.writeErr(io, notice);
            }
        }
        if (budget.expired(io)) {
            // Stop in the middle of the work, or stop after one last push
            // that is told to edit? A review that ran out of time with
            // nothing changed is worth less than one that ran out of time
            // with a small diff, and the model has already done the reading.
            net.note(io, arena, "microagent: budget of {d}s reached after {d} turn(s); one final turn\n", .{ opts.budget_s.?, turn });
            try conversation_mod.appendMessage(gpa, msgs, "user", final_push);
            // The final push is a turn like any other, so it ends the run the
            // way any other does. A model that answers it finished, and one
            // that asks for more tools was cut off mid-work, which is a
            // different exit status from a finished run.
            return try runTurn(client, io, turn_arena, gpa, prefix, opts, ep, msgs, &session, &usage, budget.withGraceNs(final_push_grace_s), tool_env, &progress, mcp);
        }
        // The ceiling is announced on the turn it applies to, before it is
        // spent, so a truncated answer is never the last thing on stdout with no
        // word about the ceiling that cut it.
        if (turn + 1 == opts.max_turns)
            net.note(io, arena, "microagent: last turn (--max-turns {d})\n", .{opts.max_turns});
        try conversation_mod.compactMessages(io, gpa, msgs, turn_arena, &compaction_floor);
        // `.wants_tools` keeps the loop going, and `.cut_off` is the budget
        // ending the run mid-turn, so neither is a finished run.
        switch (try runTurn(client, io, turn_arena, gpa, prefix, opts, ep, msgs, &session, &usage, budget, tool_env, &progress, mcp)) {
            // The tool results are already appended, so the next request
            // carries them and the loop asks again. Returning here ended the
            // run on the first turn that asked for a tool, which is every turn
            // of a run that does any work.
            .wants_tools => continue,
            .cut_off => return .cut_off,
            // The model stopped asking for tools. If it changed the tree
            // without ever running a test, ask for that once rather than
            // accepting the answer: a fix nobody ran is the failure mode this
            // loop exists to catch, and one extra turn is a cheap way to catch
            // it.
            .answered => {
                // A verification turn is a turn like any other, so the ceiling
                // is asked first: `--max-turns 2` on a run that answers on the
                // second turn would otherwise ask for a third, fall out of the
                // loop, and report exit 3 for an answer that is whole.
                if (!verify_asked and turn + 1 < opts.max_turns and progress.edited and !progress.tested) {
                    verify_asked = true;
                    net.note(io, arena, "microagent: no test runner was used; asking for one verification turn\n", .{});
                    try conversation_mod.appendMessage(gpa, msgs, "user", verify_push);
                    continue;
                }
                return .answered;
            },
        }
    }
    net.note(io, arena, "microagent: stopped at the --max-turns ceiling ({d}); the answer is a prefix of the work\n", .{opts.max_turns});
    return .cut_off;
}

/// Test runners worth recognising, so a run that never touched one can be
/// asked to verify itself once before it is allowed to finish.
const test_runners = [_][]const u8{
    "pytest",      "unittest",       "runtests",   "manage.py test", "cargo test",
    "go test",     "npm test",       "yarn test",  "pnpm test",      "make test",
    "ctest",       "zig build test", "tox",        "nox",            "jest",
    "vitest",      "mocha",          "rspec",      "phpunit",        "dotnet test",
    "gradle test", "mvn test",       "bazel test", "swift test",     "mix test",
};

/// What separates one word of a tool call's arguments from the next. The JSON
/// punctuation is in the set because the arguments arrive as the raw text the
/// provider streamed, so a name whose words are split across it rather than
/// across a space still tokenizes whole: `{"command":"cargo","other":"test"}`
/// carries `cargo` and `test` as two of its words.
const tool_word_separators = " \t\r\n\"{},:";

/// The most words any name in `test_runners` is spelled as, counted out of the
/// table rather than guessed, so the window `isTestRun` slides over it is wide
/// enough for the longest name and no wider.
const test_runner_max_words = blk: {
    var n: usize = 0;
    // The tokenizer is run once per name in the table here, which is past
    // the default comptime branch budget and nothing the shipped code hits.
    @setEvalBranchQuota(10_000);
    for (test_runners) |runner| {
        var count: usize = 0;
        var words = std.mem.tokenizeAny(u8, runner, tool_word_separators);
        while (words.next()) |_| count += 1;
        n = @max(n, count);
    }
    break :blk n;
};
comptime {
    std.debug.assert(test_runner_max_words > 0);
}

/// One name out of `test_runners`, split into its words. Built from that table
/// rather than spelled beside it, so a name added to one is split the same way
/// for the other and the two cannot drift.
const RunnerWords = struct { words: [test_runner_max_words][]const u8, len: usize };

const test_runner_words = blk: {
    var list: [test_runners.len]RunnerWords = undefined;
    @setEvalBranchQuota(10_000);
    for (test_runners, 0..) |runner, i| {
        var entry: RunnerWords = .{ .words = undefined, .len = 0 };
        var words = std.mem.tokenizeAny(u8, runner, tool_word_separators);
        while (words.next()) |word| {
            entry.words[entry.len] = word;
            entry.len += 1;
        }
        list[i] = entry;
    }
    break :blk list;
};

/// True when a single tool call's arguments name a test runner. It reads the
/// call's own arguments, not the whole conversation: a `read` of a test file,
/// or the issue text mentioning pytest, is not a test run, and judging by the
/// conversation counted both of those and never asked for verification.
///
/// A substring is not the question the flag is asking. The model reads
/// `pytest_output.log`, greps a comment for the words `cargo test`, or edits
/// `build/tox.ini`, and a substring match called each of those a test run, which
/// set `tested` on a run that changed the tree and never ran anything. The
/// verification turn is there to catch an untested edit, so a match that is too
/// eager takes away the thing that would have found the mistake.
///
/// The shell is not parsed, so `sh -c pytest`, `$(cargo test)` and a runner
/// behind a variable still match only where the words stand as they are typed.
/// That errs toward missing a run, which costs one extra verification turn.
///
/// The haystack is the call's raw argument JSON, so the JSON punctuation cuts
/// words too, which is what a name split across it rather than across a space
/// needs: `{"command":"cargo","other":"test"}` tokenizes as `command`, `cargo`
/// and `test`, and the last two are the run.
///
/// The arguments are walked once, not once per name. Every name used to be
/// searched for by tokenizing the whole string again, so a multi-kilobyte
/// `bash` command was scanned once per name in the table over to answer one
/// question, on the path
/// every tool call walks until the run has seen a test. A name matches where
/// its words end at the word just read, so the last `test_runner_max_words`
/// words are all the answer needs, and each name is tried against them once.
fn isTestRun(call_name: []const u8, args: []const u8) bool {
    if (!std.mem.eql(u8, call_name, "bash")) return false;
    var window: [test_runner_max_words][]const u8 = undefined;
    var filled: usize = 0;
    var words = std.mem.tokenizeAny(u8, args, tool_word_separators);
    while (words.next()) |word| {
        if (filled < window.len) {
            window[filled] = word;
            filled += 1;
        } else {
            std.mem.copyForwards([]const u8, window[0 .. window.len - 1], window[1..]);
            window[window.len - 1] = word;
        }
        for (test_runner_words) |entry| {
            if (entry.len > filled) continue;
            const at = filled - entry.len;
            var matched = true;
            for (entry.words[0..entry.len], window[at..filled]) |want, got| {
                if (!std.mem.eql(u8, got, want)) {
                    matched = false;
                    break;
                }
            }
            if (matched) return true;
        }
    }
    return false;
}

/// Whether this call could have changed the tree, which is what the loop asks
/// about when the model stops: an edit nobody tested is the failure mode one
/// more turn is asked to catch, and a run that changed nothing has no edit to
/// catch it on.
///
/// `ast` is here for its `rewrite` argument, not for the tool: a search prints
/// its matches
/// and leaves the tree exactly as it found it, so counting every structural
/// search as an edit made a read-only investigation ask for a verification turn
/// on changes that were never made. The key is read as a string, which is the
/// only shape `runTool` dispatches a rewrite from.
fn isEdit(call_name: []const u8, args: []const u8) bool {
    const tool = chat_mod.Tool.fromName(call_name) orelse return false;
    if (tool.writes()) return true;
    if (tool != .ast) return false;
    // The page allocator, freed on the way out: this is a per-call parse of
    // arguments a few hundred bytes long, once, and the tree it builds is
    // released before the next one is read.
    const parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, args, .{}) catch return false;
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |o| o,
        else => return false,
    };
    return chat_mod.str(object.get("rewrite")) != null;
}

/// What the run has done that the loop needs to know about afterwards.
const Progress = struct {
    edited: bool = false,
    tested: bool = false,
};

/// One request and everything its answer causes: the completion, the assistant
/// message and tool results it appends, the usage line, and the session record.
/// `.answered` when the response asked for no tools, which ends the loop;
/// `.wants_tools` when it did, and `.cut_off` when the budget ended the turn
/// before there was a turn to append.
fn runTurn(
    client: *std.http.Client,
    io: Io,
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    prefix: []const u8,
    opts: Options,
    ep: Endpoint,
    msgs: *std.ArrayList(u8),
    session: *?session_mod.Session,
    usage: *chat_mod.Usage,
    budget: Budget,
    tool_env: *const std.process.Environ.Map,
    progress: *Progress,
    mcp: *mcp_mod.Servers,
) !TurnEnd {
    // Stamped on `model_clock`, which `elapsedMs` below is read on: the two
    // ends of one duration on one clock, not the difference between origins.
    const asked = Io.Timestamp.now(io, model_clock).nanoseconds;
    // A turn the budget cut off is not a turn: half a tool call's arguments is
    // not a tool call, so nothing of it is appended and the run ends here with
    // the reason already on stderr.
    var result = streamChat(client, io, gpa, arena, opts, ep, prefix, budget, msgs.items) catch |err| switch (err) {
        error.BudgetExhausted => return .cut_off,
        else => return err,
    };
    defer result.deinit(gpa);
    // The model time is taken here, before the tool calls `finishTurn` runs:
    // the record says how long the model generated, and a gap that spans the
    // tools would report a rate for a generation that was never continuous. It
    // is on `model_clock` and not the budget's, because a suspended machine
    // spent no time generating: see that constant.
    const model_ms = session_mod.elapsedMs(io, model_clock, asked);
    // The record is written before the tools run, not after them. A turn that
    // builds or tests holds the log for as long as the tools do, and a monitor
    // following a run is told it is still going while the answer to the last
    // response it has read is minutes old. The model time is already taken
    // above, so the record itself is the same either way; only the moment it
    // lands is not.
    session_mod.writeRecord(io, arena, session, model_ms, &result);
    try finishTurn(io, arena, gpa, msgs, &result, usage, budget, tool_env, progress, opts.skills, mcp, opts.disabled_tools, opts.deny_commands, opts.writable_roots);
    if (result.calls.items.len != 0) return .wants_tools;
    // No tool call ends the loop, but only an answer ends the run. A refusal, a
    // provider that stopped generating, a response cut at `max_tokens` and a
    // response with nothing in it all arrive as "called no tool", and each
    // leaves stdout holding the model's words or nothing at all while exit 0
    // says the task finished. The reason is named before the run reports itself
    // unfinished, so a caller sees which of the four it was.
    if (incompleteAnswer(arena, &result, opts.max_tokens)) |notice| {
        net.note(io, arena, "microagent: {s}\n", .{notice});
        return .cut_off;
    }
    return .answered;
}

/// Why a response that called no tool is not an answer, in the words the
/// operator reads. Null when it is one.
///
/// The stderr line for a `content_filter` stop, which is the one shape whose
/// message does not name a number the run can report.
const content_filter_notice = "the provider stopped generating this response (finish_reason content_filter); there is no answer to report";

/// The provider is the one saying so, in its own `finish_reason`, and a
/// response is model output rather than this program's own, so the question
/// asked here is what the run is about to report, not whether the model was
/// right. Three shapes end a run that would otherwise exit 0 with nothing on
/// stdout:
///
///   * `content_filter`: the provider stopped generating on purpose, and
///     usually sends no text with it.
///   * nothing at all: no text and no tool call, which is how a refusal, an
///     empty completion and a stream that carried only a usage frame each
///     arrive.
///   * `length`: the response was cut at `max_tokens`, so what it said is a
///     prefix of the answer. With tool calls in it the loop continues and the
///     next turn says more, so only the toolless turn is an unfinished run.
fn incompleteAnswer(arena: std.mem.Allocator, result: *const chat_mod.ChatResult, max_tokens: u32) ?[]const u8 {
    const reason = result.finish_reason;
    if (std.mem.eql(u8, reason, "content_filter")) return content_filter_notice;
    if (result.content.items.len == 0) {
        // The reason is the provider's own bytes, and this notice is the last
        // line the run prints, so it goes out through the escaping every other
        // diagnostic quoting a value uses: a gateway answering
        // `"finish_reason":"\u001b[2J"` reached the operator's terminal as an
        // escape sequence, and a lone `0xff` reached it as mojibake. The
        // comparison above reads the raw value and the sentence below quotes
        // it, the same split the release tag makes in `update`.
        const shown = if (reason.len == 0) "none sent" else chat_mod.safeText(arena, reason, net.quoted_value_bytes);
        return std.fmt.allocPrint(arena, "the last response carried no text and no tool call (finish_reason: {s}), so the run ends with nothing to report", .{
            shown,
        }) catch "the last response carried no text and no tool call, so the run ends with nothing to report";
    }
    if (std.mem.eql(u8, reason, "length")) {
        return std.fmt.allocPrint(arena, "the answer was cut at the generation ceiling (max_tokens {d}) after {d} byte(s) of text, so what is on stdout is a prefix of it", .{
            max_tokens, result.content.items.len,
        }) catch "the answer was cut at the generation ceiling, so what is on stdout is a prefix of it";
    }
    return null;
}

/// Everything in a request body that is not the conversation: the tool schema
/// is 3.8 KB, and the rest is the model, the stream flags and the token
/// ceiling. The credential is a header, not a field, so it is not in this. A
/// reservation rather than a bound, and the buffer still grows if it does not
/// cover the body, which a long model name would do. The optional `skill`
/// entry is reserved too, because which tools a run advertises is fixed before
/// the first turn; MCP entries are not, because their size is whatever the
/// servers sent, and the buffer grows for them.
const body_scaffolding_bytes = tools_json.len + skill_mod.tool_json.len + 1024;

/// The start of every built-in entry in `tools_json`, up to the tool's name.
const tool_entry_prefix = "{\"type\":\"function\",\"function\":{\"name\":\"";

/// `tools_json` less the tools in `disabled`, in the same shape: one entry per
/// line, `[` first and `]` last, so what a run adds is appended the same way.
fn builtinToolsJson(arena: std.mem.Allocator, disabled: std.EnumSet(chat_mod.Tool)) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "[\n");
    var lines = std.mem.splitScalar(u8, tools_json, '\n');
    while (lines.next()) |line| {
        const entry = std.mem.trimEnd(u8, line, ",");
        const rest = std.mem.cutPrefix(u8, entry, tool_entry_prefix) orelse continue;
        const tool = chat_mod.Tool.fromName(rest[0 .. std.mem.indexOfScalar(u8, rest, '"') orelse continue]) orelse continue;
        if (disabled.contains(tool)) continue;
        if (out.items.len != "[\n".len) try out.appendSlice(arena, ",\n");
        try out.appendSlice(arena, entry);
    }
    try out.appendSlice(arena, "\n]");
    return out.items;
}

/// The entries a run adds to the built-in seven: the `skill` entry when skills
/// were found, and one entry per MCP tool. Comma-separated and without the
/// surrounding brackets, and empty when the run adds nothing.
fn extraToolsJson(arena: std.mem.Allocator, opts: Options) ![]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    if (opts.skills.items.len != 0) try parts.append(arena, skill_mod.tool_json);
    const remote = try opts.mcp.toolsJson(arena);
    if (remote.len != 0) try parts.append(arena, remote);
    return std.mem.join(arena, ",", parts.items);
}

/// The request body, with `messages` last.
///
/// Prompt caching keys on the exact byte prefix of a request, so a turn's body
/// has to be the previous turn's body plus the new messages. That only holds
/// while nothing constant sits *behind* the growing array: the tool schema is
/// a few kilobytes, and written after `messages` it fell outside the cacheable
/// prefix on every turn of every run, so the provider re-read it each time.
/// Member order is not significant in JSON, so the constant fields go first and
/// the conversation ends the body.
fn bodyPrefix(arena: std.mem.Allocator, opts: Options) ![]u8 {
    // The constant fields are written into one buffer reserved for them, so the
    // scaffold never walks the doubling ladder and never lands in the
    // conversation's shadow. The conversation follows this on the wire, from
    // where it already is: `sendRequest` writes the two together without making
    // one buffer hold both.
    var jb = chat_mod.JsonBuf.initCapacity(arena, body_scaffolding_bytes);
    const w = jb.writer();
    try w.print("{{\"model\":", .{});
    try chat_mod.writeJsonString(w, opts.model);
    try w.writeAll(",\"tools\":");
    // The last byte of the constant is the array's closing bracket, so a run
    // that adds a tool writes everything before it, a comma and the run's own
    // entries. The bytes a run with nothing to add sends are the constant
    // itself, which is what keeps the request prefix the provider caches
    // identical to what it was before either feature existed.
    const builtin_tools = if (opts.disabled_tools.count() == 0) tools_json else try builtinToolsJson(arena, opts.disabled_tools);
    const extra = try extraToolsJson(arena, opts);
    if (extra.len == 0) {
        try w.writeAll(builtin_tools);
    } else {
        try w.writeAll(builtin_tools[0 .. builtin_tools.len - 1]);
        try w.writeAll(",");
        try w.writeAll(extra);
        try w.writeAll("]");
    }
    try w.writeAll(",\"stream\":true,\"stream_options\":{\"include_usage\":true}");
    try w.print(",\"max_tokens\":{d}", .{opts.max_tokens});
    if (opts.reasoning_effort) |effort| {
        if (std.mem.eql(u8, effort, "none")) {
            try w.writeAll(",\"reasoning\":{\"enabled\":false}");
        } else {
            try w.writeAll(",\"reasoning\":{\"effort\":");
            try chat_mod.writeJsonString(w, effort);
            try w.writeAll("}");
        }
    }
    try w.writeAll(",\"messages\":");
    return jb.items();
}

/// The two bytes that close the conversation array and the request object.
const body_close = "]}";

/// The request body as one buffer, for the callers that need the bytes in hand:
/// the tests that read a body back, and anything comparing two of them. The
/// wire does not, which is what `sendRequest` is for, so this is defined as the
/// same three parts the stream sends, in the same order.
fn buildBody(arena: std.mem.Allocator, opts: Options, messages: []const u8) ![]u8 {
    const prefix = try bodyPrefix(arena, opts);
    const body = try arena.alloc(u8, prefix.len + messages.len + body_close.len);
    @memcpy(body[0..prefix.len], prefix);
    @memcpy(body[prefix.len..][0..messages.len], messages);
    @memcpy(body[prefix.len + messages.len ..], body_close);
    return body;
}

/// Sends one request: the constant prefix, the conversation where it already
/// is, and the closing bytes. `sendBodyComplete` wants the whole body in one
/// buffer, and building that buffer copies the conversation once per turn,
/// which on a long run is the largest single memcpy the harness makes. The
/// bytes on the wire are the same ones in the same order; only the copy is
/// gone.
fn sendRequest(open: *std.http.Client.Request, chunk: []u8, prefix: []const u8, msgs: []const u8) !void {
    open.transfer_encoding = .{ .content_length = prefix.len + msgs.len + body_close.len };
    var bw = try open.sendBodyUnflushed(chunk);
    try bw.writer.writeAll(prefix);
    try bw.writer.writeAll(msgs);
    try bw.writer.writeAll(body_close);
    try bw.end();
    try open.connection.?.flush();
}

/// The request headers carrying the credential. The authorization header is
/// `.override` rather than `.privileged`, because the client drops a privileged
/// header on a redirect, and dropping it costs a 401 from every provider.
fn authHeaders(arena: std.mem.Allocator, api_key: []const u8) !std.http.Client.Request.Headers {
    return .{
        .authorization = .{ .override = try std.fmt.allocPrint(arena, "Bearer {s}", .{api_key}) },
    };
}

/// Makes a silent response socket fail instead of blocking forever.
///
/// A read on a connection that is open but never speaks does not return, so
/// nothing checked between reads — the budget, a stop flag — ever runs. A
/// receive timeout turns that hang into a read error the loop already handles.
/// Applied per request because the client pools connections and `std.http` has
/// no per-request read timeout.
///
/// A socket that refused the option leaves a read that can block forever, and
/// that is the whole failure this exists to prevent, so the refusal is the
/// caller's to hear about: swallowing it would run the turn with the guard
/// silently absent and nothing to tell that from a socket that took it.
fn setStallTimeout(handle: std.posix.socket_t, seconds: u32) !void {
    if (@import("builtin").os.tag == .windows or seconds == 0) return;
    const tv = std.posix.timeval{ .sec = @intCast(seconds), .usec = 0 };
    return std.posix.setsockopt(handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&tv));
}

/// Where a request goes and what authorizes it, both settled by `opts` before
/// the first turn. Built once from the run arena for the reason `bodyPrefix` is
/// built there: nothing in the loop changes a base url or a key, so a URI parse
/// and a `Bearer` copy per turn were per-turn work over a run constant, and
/// both landed on the turn arena that the loop resets.
const Endpoint = struct {
    uri: std.Uri,
    shown_url: []const u8,
    auth: std.http.Client.Request.Headers,
};

fn endpoint(arena: std.mem.Allocator, opts: Options) !Endpoint {
    const url = try std.fmt.allocPrint(arena, "{s}/chat/completions", .{std.mem.trimEnd(u8, opts.base_url, "/")});
    return .{
        .uri = std.Uri.parse(url) catch return error.InvalidUrl,
        // What the notes below name, and what the userinfo a base url may carry
        // never reaches: the run's log is not the place for a password.
        .shown_url = displayUrl(arena, url),
        // The authorization header is `override`, not `privileged`, and
        // `authHeaders` says why. The redirect is unhandled, which is the
        // promise made again where the request is opened: a provider that
        // answers with a Location is an error rather than a second request, so
        // nothing to drop the key out of.
        .auth = try authHeaders(arena, opts.api_key),
    };
}

/// One turn's completion, asked again while the provider reports a failure it
/// says it did not generate.
///
/// A request the provider has is never sent twice, because the completion
/// behind it may already have been generated and billed. An error frame that
/// arrives before a byte of content is the provider saying that did not happen:
/// nothing reached stdout, no tool call is half assembled, and the prompt it
/// re-reads is the one its cache already holds. That is worth another ask
/// rather than a lost review; anything with a byte in it is not, and the branch
/// in `streamChatOnce` is where the two are told apart.
fn streamChat(
    client: *std.http.Client,
    io: Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    opts: Options,
    ep: Endpoint,
    prefix: []const u8,
    budget: Budget,
    msgs: []const u8,
) !chat_mod.ChatResult {
    var ask: u32 = 0;
    while (true) {
        ask += 1;
        const result = streamChatOnce(client, io, gpa, arena, opts, ep, prefix, budget, msgs) catch |err| {
            if (err != error.StreamRetryable) return err;
            const wait = reaskWaitMs(io, budget, ask, arena, ep.shown_url) orelse return error.StreamError;
            waitMs(io, wait) catch return error.StreamError;
            continue;
        };
        return result;
    }
}

/// How long to wait before asking for a turn the provider failed without
/// producing anything, or null when this is the last ask. Null is also the
/// answer when the wait would pass the run's budget: a run killed mid-sleep
/// has nothing to show for the turn either way, and the note says which of the
/// two it was.
fn reaskWaitMs(io: Io, budget: Budget, ask: u32, arena: std.mem.Allocator, shown_url: []const u8) ?u64 {
    if (ask >= max_attempts) {
        net.note(io, arena, "microagent: the provider failed this turn before any content {d} time(s); it is not asked again\n", .{ask});
        return null;
    }
    const wait = net.retryBackoffMs(ask, max_backoff_ms);
    if (!budget.canAffordWait(io, wait)) {
        net.note(io, arena, "microagent: the provider failed this turn before any content, and the {d}ms before another ask would pass the run's budget; this one is the last\n", .{wait});
        return null;
    }
    net.note(io, arena, "microagent: the provider failed this turn before any content from {s}; asking again in {d}ms\n", .{ shown_url, wait });
    return wait;
}

/// Streams one completion, printing visible text as it arrives and accumulating
/// tool calls and token counters. Text on stderr is tool activity; stdout is
/// the model's own output plus one JSON usage line per response.
///
/// One ask, not the whole turn: `streamChat` above is what turns a provider's
/// own reported failure into another one.
fn streamChatOnce(
    client: *std.http.Client,
    io: Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    opts: Options,
    ep: Endpoint,
    prefix: []const u8,
    budget: Budget,
    msgs: []const u8,
) !chat_mod.ChatResult {
    const uri = ep.uri;
    const shown_url = ep.shown_url;
    const auth_headers = ep.auth;

    // The request lives in a slot so `Response.request` stays valid for the
    // reader handed back out of the retry loop below.
    var req_slot: ?std.http.Client.Request = null;
    defer if (req_slot) |*r| r.deinit();

    var redirect_buffer: [8 * 1024]u8 = undefined;
    var transfer: [16 * 1024]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    var decompress_buffer: [std.compress.flate.max_window_len]u8 = undefined;

    // The optional request fields are the ones a provider may refuse without
    // the request being wrong: `reasoning` is ours, not theirs, and NVIDIA's
    // NIM answers a request carrying it with
    // `400 Validation: Unsupported parameter(s): reasoning`. One retry without
    // them, on a 400, is the difference between "this provider cannot run the
    // harness" and a run.
    var prefix_now = prefix;
    // One buffer for the request writer to run through: the body itself is
    // written straight from the prefix and the conversation, so this only ever
    // holds a flush's worth.
    var body_chunk: [64 * 1024]u8 = undefined;
    var dropped_optional = false;
    var attempt: u32 = 0;
    // A rate limit, or a connection that died before the request was on the
    // wire, is the provider's weather rather than the review's verdict: retry
    // those rather than making gauntlet redo the whole review against a tree
    // the agent has already partly changed. A request the provider has already
    // read whole is a different case, and the head branch below is where the
    // two are kept apart.
    const reader = retry: while (true) {
        attempt += 1;
        if (req_slot) |*r| {
            r.deinit();
            req_slot = null;
        }
        const req = client.request(.POST, uri, .{
            .redirect_behavior = .unhandled,
            .headers = auth_headers,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "application/json" },
                .{ .name = "accept", .value = "text/event-stream" },
            },
        }) catch |err| {
            if (worthAnotherAttempt(.opened, err) and waitBeforeRetry(io, arena, shown_url, attempt, "opening the request to", err, budget)) continue;
            return err;
        };
        req_slot = req;
        net.releaseDeadStack();
        // A turn with no stall guard can hang until the caller kills it, so the
        // failure to install one ends the request rather than reading on.
        if (req_slot.?.connection) |connection|
            try setStallTimeout(connection.stream_reader.stream.socket.handle, opts.stall_timeout_s);
        var open = &req_slot.?;
        sendRequest(open, &body_chunk, prefix_now, msgs) catch |err| {
            if (worthAnotherAttempt(.sending, err) and waitBeforeRetry(io, arena, shown_url, attempt, "sending the request body to", err, budget)) continue;
            return err;
        };
        if (debug_enabled) std.debug.print("[mdebug] request sent, body={d} bytes\n", .{prefix_now.len + msgs.len + body_close.len});

        var response = open.receiveHead(&redirect_buffer) catch |err| {
            // `worthAnotherAttempt` is what says a head is not worth another
            // one; this is the operator's half of that, so a run that lost a
            // billable turn says so rather than reporting a connection fault.
            if (!worthAnotherAttempt(.head, err))
                net.note(io, arena, "microagent: the request to {s} was sent in full and its response never arrived ({s}); it is not sent again, because a second POST of one turn is a second billable completion\n", .{
                    shown_url, @errorName(err),
                });
            return err;
        };
        if (debug_enabled) std.debug.print("[mdebug] head status={d} enc={s}\n", .{ @intFromEnum(response.head.status), @tagName(response.head.content_encoding) });
        if (response.head.status != .ok) {
            // The one retry the declaration above is for, on the status that
            // carries the refusal.
            if (response.head.status == .bad_request and !dropped_optional and opts.reasoning_effort != null) {
                dropped_optional = true;
                // The count is the attempt within one request body, so a body
                // that changed restarts it. Carrying it over spent one of the
                // three attempts the transient-failure schedule below is
                // documented to have, and a provider that then answered 429
                // got one retry where it gets two.
                attempt = 0;
                var plain = opts;
                plain.reasoning_effort = null;
                prefix_now = try bodyPrefix(arena, plain);
                net.note(io, arena, "microagent: {s} refused the optional request fields (HTTP 400); retrying once without them\n", .{shown_url});
                continue;
            }
            if (net.retryableStatus(response.head.status) and attempt < max_attempts) {
                // A rate limit carries the wait the provider wants, and its own
                // backoff is the wrong one to spend: this run's schedule is 1 s
                // and 2 s, the two waits between three attempts, and a provider
                // that says "come back in 30" is still refusing at second 2, so
                // each retry is a second billable
                // refusal. The header wins where it is a number this run is
                // willing to wait, and the schedule stands where it is not.
                const wait = retryWaitMs(response.head.bytes, net.nowSeconds(io), attempt);
                // Three outcomes, each with its own reason. They are spelled
                // out rather than as a block with a `break` out of it, because
                // the break landed on the budget note below and reported a
                // cause that was not the one that had just been given.
                if (!budget.canAffordWait(io, wait)) {
                    // The provider asked for longer than this run has left.
                    // Waiting the full ask would put the run to sleep inside
                    // the caller's timeout, and retrying early is the second
                    // billable refusal the header was meant to prevent, so the
                    // turn is given up here with the reason below.
                    net.note(io, arena, "microagent: {s} answered HTTP {d} asking for {d}ms, which is past what is left of this run's budget; the turn is given up\n", .{
                        shown_url, @intFromEnum(response.head.status), wait,
                    });
                } else {
                    net.note(io, arena, "microagent: {s} answered HTTP {d}, retrying in {d}ms (attempt {d}/{d})\n", .{
                        shown_url, @intFromEnum(response.head.status), wait, attempt + 1, max_attempts,
                    });
                    // The same rule `waitBeforeRetry` follows: a sleep that
                    // failed is not a sleep, and continuing would answer a
                    // provider that asked for a pause with an immediate second
                    // request, which is the refusal the header was meant to
                    // prevent. The turn is given up instead, with this reason
                    // on stderr and the status below still reported.
                    if (waitMs(io, wait)) |_| {
                        continue;
                    } else |wait_err| {
                        net.note(io, arena, "microagent: the {d}ms wait {s} asked for could not be taken ({s}); the turn is given up rather than retried at once\n", .{
                            wait, shown_url, @errorName(wait_err),
                        });
                    }
                }
            }
            var err_transfer: [8 * 1024]u8 = undefined;
            const err_reader = response.reader(&err_transfer);
            // The body is the only thing that says why the provider refused the
            // turn, so a read of it that fails is named rather than answered
            // with an empty body: `http 500:` on its own reads as a provider
            // that said nothing, which is a different thing from a body this
            // run could not read.
            const err_body = err_reader.allocRemaining(arena, .limited(max_error_body_bytes)) catch |err|
                try std.fmt.allocPrint(arena, "(the error body could not be read: {s})", .{@errorName(err)});
            const msg = try std.fmt.allocPrint(arena, "http {d}: {s}\n", .{
                @intFromEnum(response.head.status),
                tool_mod.terminalSafe(arena, err_body),
            });
            net.writeErr(io, msg);
            return error.ApiError;
        }
        break :retry response.readerDecompressing(&transfer, &decompress, &decompress_buffer);
    };

    var result: chat_mod.ChatResult = .{};
    errdefer result.deinit(gpa);
    var calls: std.ArrayList(chat_mod.ToolCall) = .empty;
    errdefer chat_mod.deinitCalls(gpa, &calls);

    // Frames are parsed in a scratch arena reset after each one, so a long
    // stream costs the size of its largest frame, not the sum of all of them.
    var frame_arena_state = std.heap.ArenaAllocator.init(arena);
    defer frame_arena_state.deinit();
    const frame_arena = frame_arena_state.allocator();

    // stdout is buffered per read chunk rather than written per token: one
    // write per chunk the provider sent. Tokens that arrived in the same chunk
    // are drawn in the same tick either way, so streaming latency is unchanged
    // while the syscall count per completion drops by orders of magnitude.
    var out_buf: std.ArrayList(u8) = .empty;
    defer out_buf.deinit(gpa);

    // Chunked reads, split into lines here rather than with the reader's
    // delimiter helpers: those stall on a chunked body reader (they hand back
    // an endless run of empty lines instead of reading on).
    var pending: std.ArrayList(u8) = .empty;
    defer pending.deinit(gpa);
    var scanned: usize = 0;
    var done = false;
    var unparsable: usize = 0;
    while (!done) {
        // Between reads, because a read is the one thing here that cannot be
        // interrupted: a provider that is slow rather than gone has to cost the
        // run its budget and stop there, not a caller's whole review timeout.
        if (budget.expired(io)) {
            net.note(io, arena, "microagent: the time budget ran out after {d} byte(s) of content and {d} tool call(s) from {s}; the turn is discarded\n", .{
                result.content.items.len, calls.items.len, shown_url,
            });
            return error.BudgetExhausted;
        }
        // Straight into the pending buffer, rather than into a stack chunk that
        // is appended after it: every byte of every completion passed through
        // that copy, and the line split below works on `pending` itself.
        try pending.ensureUnusedCapacity(gpa, stream_read_chunk);
        const n = reader.readSliceShort(pending.unusedCapacitySlice()) catch |err| {
            net.note(io, arena, "microagent: reading the completion stream from {s} failed after {d} byte(s) of content and {d} tool call(s): {s}\n", .{ shown_url, result.content.items.len, calls.items.len, @errorName(err) });
            return err;
        };
        if (n == 0) break;
        pending.items.len += n;

        var start: usize = 0;
        while (net.nextLineEnd(pending.items, &scanned)) |pos| {
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
            try stream_mod.applyFrame(frame_arena, gpa, payload, &result, &calls, &out_buf, &unparsable);
            _ = frame_arena_state.reset(.retain_capacity);
        }
        // Drop what was consumed, so a long stream does not keep every frame.
        if (start > 0) {
            dropWritten(&pending, start);
            scanned -|= start;
        }
        // What is left above is the one line that has not ended, and a line
        // that has not ended by now is not one this turn can carry, so the run
        // says so and ends the turn rather than growing with the rest of the
        // stream. The check reads what the split left rather than the buffer
        // as it arrived, because a read lands whole lines beside the partial
        // one: asked before the split, a complete line of exactly the ceiling
        // was refused for its own newline, and a short frame read alongside a
        // partial line counted the short frame against the long one.
        if (frameOverran(pending.items)) {
            net.note(io, arena, "microagent: a line of the completion stream from {s} passed {d} byte(s) without ending; the turn is discarded\n", .{
                shown_url, pending.items.len,
            });
            return error.StreamTruncated;
        }
        // Write every whole character in the buffer and keep a trailing partial
        // one for the next chunk. The chunk boundary is the transport's, not
        // the text's: a `\xe6\x97\xa5` split as `\xe6\x97` and `\xa5` across two
        // reads is a legal chunking of a legal answer, and writing each half as
        // it arrives puts a replacement glyph and then a broken byte on the
        // operator's screen. What is held back is at most three bytes, so
        // nothing waits on it that would not have waited on the next read
        // anyway, and the run's last flush holds the same tail back.
        const held = chat_mod.partialTailLen(out_buf.items);
        try writeOutPrefix(io, arena, &out_buf, out_buf.items.len - held, shown_url);
    }

    if (unparsable > 0)
        net.note(io, arena, "microagent: {d} frame(s) of the completion stream from {s} were not JSON, or carried a token count that is not a number; their content and their counts are not in this turn\n", .{ unparsable, shown_url });
    // The turn's own ceiling, reached while the stream was still arriving. Past
    // it `appendStreamed` and `applyCallDelta` drop every further byte, and a
    // dropped argument fragment is what makes a tool call the next turn cannot
    // dispatch: the run then reads its own `error: tool arguments are not valid
    // JSON` and blames the model for a truncation nothing reported. Only a turn
    // that arrived whole under the ceiling is a turn the model meant.
    //
    // `dropped` rather than the counter alone. `clamp` cuts on a codepoint
    // boundary, so the last character before the ceiling is whatever fits: a
    // response that arrives with one to three bytes of room and a character of
    // two to four bytes to add keeps none of it, and the counter stops that
    // far short of the ceiling. Reading the counter alone, that turn is
    // reported as a finished one whose answer is short by a character nobody
    // was told about.
    if (result.dropped or result.streamed >= stream_mod.max_response_bytes)
        net.note(io, arena, "microagent: the completion stream from {s} reached the {d} byte ceiling for one turn with {d} tool call(s) still being assembled; anything past it is not in this turn, and a tool call whose arguments were cut cannot be dispatched\n", .{
            shown_url, stream_mod.max_response_bytes, calls.items.len,
        });
    // A failure the provider reported in the middle of the stream. It goes
    // before the terminator check below, because a provider that reports a
    // failure and then closes the stream cleanly is the case neither of the two
    // notes names: the turn has text in it, the stream carried `[DONE]`, and
    // what is on stdout is a prefix of an answer the provider abandoned. The
    // provider's own words are the diagnostic, and a turn that has been given
    // up on is not one the loop asks about again: the request is not a
    // resumption, and a second one is a second billable completion.
    if (result.stream_error.len != 0) {
        // A failure with nothing behind it is the one case the turn is asked
        // for again: the provider is saying it did not generate anything, so
        // there is no answer on stdout to duplicate and no half-assembled call
        // to lose. `streamChat` is what takes that answer and asks.
        if (result.content.items.len == 0 and calls.items.len == 0) {
            net.note(io, arena, "microagent: the provider reported a failure before any content from {s}: {s}\n", .{
                shown_url, tool_mod.terminalSafe(arena, result.stream_error),
            });
            return error.StreamRetryable;
        }
        net.note(io, arena, "microagent: the provider reported a failure part way through the completion stream from {s} after {d} byte(s) of content and {d} tool call(s): {s}; what is on stdout is a prefix of what it meant to send, and the turn is not retried\n", .{
            shown_url, result.content.items.len, calls.items.len, tool_mod.terminalSafe(arena, result.stream_error),
        });
        return error.StreamError;
    }
    // The provider closes a finished stream with a `[DONE]` frame. A stream
    // that ends without one was cut off partway, and the truncated turn below
    // would otherwise be appended as a complete answer: a turn that lost its
    // tail, tool calls and all, reads as one the model finished on purpose.
    if (stream_mod.truncatedNotice(arena, shown_url, done, result.content.items.len, calls.items.len)) |notice| {
        net.note(io, arena, "{s}\n", .{notice});
        return error.StreamTruncated;
    }
    // `length` is the provider saying it stopped at `max_tokens`. The frame
    // arrived and the stream terminated cleanly, so nothing here is broken: the
    // response is simply the prefix of what the model meant to say, and a
    // truncated tool call's arguments are not JSON the next turn can run them
    // from, so the run fails and blames the model rather than calling a tool
    // with half an argument.
    // A run that printed it as a finished answer would be reporting a cut
    // generation as the review's result.
    if (std.mem.eql(u8, result.finish_reason, "length"))
        net.note(io, arena, "microagent: the response from {s} hit the generation ceiling (max_tokens {d}) after {d} byte(s) of content and {d} tool call(s); the turn is incomplete\n", .{
            shown_url, opts.max_tokens, result.content.items.len, calls.items.len,
        });
    // The last flush holds the tail back on the same rule as every read above:
    // a stream that ends partway through a character leaves that character
    // unfinished for good, and there is no next read to finish it, so writing
    // it would put a broken byte on the operator's screen and nothing after it
    // would replace it. The newline goes on after the count, not before it.
    const held = chat_mod.partialTailLen(out_buf.items);
    if (result.content.items.len > 0) try out_buf.append(gpa, '\n');
    try writeOutPrefix(io, arena, &out_buf, out_buf.items.len - held, shown_url);
    result.calls = calls;
    // Whatever the filter took out is named, one reason at a time. A turn is
    // still complete without those calls, and a run that silently ran every call
    // the response carried would be a run whose side effects a reader cannot
    // account for from the turn it read; the same is true in the other
    // direction, where a call the model asked for is not dispatched and the
    // assistant message that goes back names fewer calls than the stream did.
    const dropped = stream_mod.keepRunnableCalls(gpa, &result.calls);
    if (stream_mod.droppedCallNotice(arena, shown_url, dropped, result.over_cap)) |notice| net.note(io, arena, "{s}\n", .{notice});
    if (dropped.duplicate > 0) net.note(io, arena, "microagent: the completion stream from {s} carried {d} tool call(s) whose id this response had already delivered; they are not dispatched a second time\n", .{ shown_url, dropped.duplicate });
    return result;
}

// The other half of the stream loop's flush: what the writer writes, and what
// the next chunk starts from. A run whose answer carries a character the
// transport split across two reads writes it as one character rather than as a
// replacement glyph and a broken byte.
test "a character split across two reads is written once it is whole" {
    const answer = "a\u{65e5}\u{1f600}z";
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    var written: std.ArrayList(u8) = .empty;
    defer written.deinit(std.testing.allocator);
    var taken: usize = 0;

    // The transport's chunking, not the text's: the reads below cut the answer
    // in the middle of a three-byte character and of a four-byte one.
    for ([_]usize{ 1, 3, 2, 1, 4, 1 }) |chunk| {
        const take = @min(chunk, answer.len - taken);
        try buf.appendSlice(std.testing.allocator, answer[taken..][0..take]);
        taken += take;
        const held = chat_mod.partialTailLen(buf.items);
        try written.appendSlice(std.testing.allocator, buf.items[0 .. buf.items.len - held]);
        dropWritten(&buf, buf.items.len - held);
    }
    try written.appendSlice(std.testing.allocator, buf.items);

    try std.testing.expectEqualStrings(answer, written.items);
    try std.testing.expectEqual(@as(usize, 0), buf.items.len);
}

/// Hands the buffered tokens to stdout, and says so when stdout refuses them.
/// A closed pipe and a full disk both arrive as a failed write, and the turn is
/// given up on either: continuing would put a partial answer on stdout under an
/// exit status that says the run finished. The reason is on stderr before the
/// run ends, and the error is re-raised so the caller fails the run.
///
/// Writes the first `len` bytes of the buffer and keeps the rest at its front,
/// so the bytes that were not written are the ones the next call starts from.
fn writeOutPrefix(
    io: Io,
    arena: std.mem.Allocator,
    out_buf: *std.ArrayList(u8),
    len: usize,
    shown_url: []const u8,
) !void {
    if (len == 0) return;
    net.writeOut(io, out_buf.items[0..len]) catch |err| {
        net.note(io, arena, "microagent: the text streamed from {s} could not be written to stdout ({s}); the rest of this run's output is not on it either, and the run fails rather than finishing with a partial answer\n", .{ shown_url, @errorName(err) });
        return err;
    };
    dropWritten(out_buf, len);
}

/// Drops the `len` bytes just consumed, whether they were written out or parsed
/// as a line, and moves what is left to the front, so the bytes the next chunk
/// has to complete are the ones the next call starts from. The buffer only ever
/// holds one read's worth, so the move is over a few bytes.
fn dropWritten(out_buf: *std.ArrayList(u8), len: usize) void {
    const kept = out_buf.items.len - len;
    std.mem.copyForwards(u8, out_buf.items[0..kept], out_buf.items[len..]);
    out_buf.shrinkRetainingCapacity(kept);
}

/// One tool call, to whichever half of the tool surface answers for its name:
/// the run's skill set for `skill`, and the tool module for the seven built
/// ins. Everything else about a call -- the argument check, the gutter line,
/// the cap -- belongs to the half that runs it, which is why this is a name
/// comparison and not a second dispatch table.
fn dispatchCall(
    io: Io,
    arena: std.mem.Allocator,
    skills: skill_mod.Skills,
    mcp: *mcp_mod.Servers,
    disabled: std.EnumSet(chat_mod.Tool),
    call: chat_mod.ToolCall,
    ceiling_ms: ?u64,
    tool_env: ?*const std.process.Environ.Map,
    deny_commands: []const []const u8,
    writable_roots: []const []const u8,
) ![]const u8 {
    // A tool the config switched off was left out of the schema, so a call to
    // it is the model naming a tool from memory or from an earlier prompt.
    if (chat_mod.Tool.fromName(call.name)) |tool| {
        if (disabled.contains(tool))
            return std.fmt.allocPrint(arena, "error: the tool '{s}' is disabled by configuration", .{tool.name()});
    }
    if (std.mem.startsWith(u8, call.name, mcp_mod.tool_prefix)) {
        const remote = mcp.resolve(call.name) orelse
            return std.fmt.allocPrint(arena, "error: unknown tool '{s}'", .{chat_mod.safeText(arena, call.name, 40)});
        // An MCP call is a subprocess round trip with no other bound, so it
        // answers to the same deadline every other tool does: the run's own
        // remaining budget when it set one, and the read-only ceiling when it
        // did not.
        return mcp_mod.Servers.call(io, arena, remote, call.args.items, net.durationMs(ceiling_ms orelse tool_mod.tool_timeout_ms));
    }
    if (std.mem.eql(u8, call.name, skill_mod.tool_name))
        return skill_mod.call(io, arena, call.args.items, skills);
    return tool_mod.runTool(io, arena, call, ceiling_ms, tool_env, deny_commands, writable_roots);
}

/// Appends the assistant message and, for every tool call it requested, runs
/// the tool and appends its result.
fn finishTurn(
    io: Io,
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    msgs: *std.ArrayList(u8),
    result: *chat_mod.ChatResult,
    usage: *chat_mod.Usage,
    budget: Budget,
    tool_env: *const std.process.Environ.Map,
    progress: *Progress,
    skills: skill_mod.Skills,
    mcp: *mcp_mod.Servers,
    disabled: std.EnumSet(chat_mod.Tool),
    deny_commands: []const []const u8,
    writable_roots: []const []const u8,
) !void {
    try msgs.appendSlice(gpa, ",");
    try msgs.appendSlice(gpa, try assistantMessage(arena, result));

    var carried: usize = 0;
    var capped = false;
    var capped_said = false;
    for (result.calls.items) |call| {
        // Both flags only ever go false to true, so once one is set nothing
        // later in the turn can change it, and the check that would record it
        // is skipped rather than repeated over the remaining calls' arguments.
        if (!progress.edited and isEdit(call.name, call.args.items)) progress.edited = true;
        if (!progress.tested and isTestRun(call.name, call.args.items)) progress.tested = true;
        // A call the budget will not pay for still gets a tool message. An
        // assistant turn that names calls the conversation never answers is one
        // the next request rejects, so the loop below would spend a turn on a
        // 400 instead of on the answer.
        const output = if (budget.expired(io))
            "error: not run, the run's time budget is exhausted"
        else blk: {
            // The ceiling is read here rather than once for the turn, because a
            // turn's calls run in sequence: a reading taken before the first of
            // them is already stale by the time the second starts, and the
            // budget the ceiling cuts to is the one left, not the one the turn
            // began with. A call that runs long is exactly the reason the next
            // one is shorter, so each reads for itself. The clock here is the
            // run's own, and a tool that takes no time at all costs nothing to
            // re-read: a `git status` spends its reading on the same syscall
            // the process spawn beside it already makes.
            //
            // `skill` is the one name the tool module does not hold: the set it
            // loads from belongs to the run, and a run that found no skills
            // never advertised the name, so a call to it here is the model
            // asking for a tool the schema did not offer.
            break :blk dispatchCall(io, arena, skills, mcp, disabled, call, budget.toolCeilingMs(io), tool_env, deny_commands, writable_roots) catch |err|
                // A tool that fails outright (rather than reporting its own
                // failure as text) is named here, so a result reading
                // `error: OutOfMemory` says which of the calls ran out.
                try std.fmt.allocPrint(arena, "error: {s}: {s}", .{ call.name, @errorName(err) });
        };
        // A tool result is capped at `max_tool_output`, so the message holding
        // it is bounded before the first byte is written. Reserving that now
        // keeps a full-size result from walking the doubling ladder, which on
        // the turn arena leaves every intermediate block behind. A short result
        // is the ordinary one, so the reservation is the result's own size
        // under that ceiling: a turn of two dozen `git status` calls otherwise
        // reserves the whole cap for each of them.
        //
        // The turn's own ceiling is a second one, and it is the one a
        // 64-call response hits: the calls all run, and what a result costs is
        // carried forward to every later turn, so past the ceiling the call
        // keeps its place in the conversation and loses its output.
        const result_bytes = carriedToolResult(try tool_mod.toolResult(arena, output), &carried, &capped);
        if (capped and !capped_said) {
            capped_said = true;
            net.note(io, arena, "microagent: this turn's tool results reached the {d} byte ceiling ({d} carried so far); every later result in the same turn is a marker, the calls themselves still ran, and the model is told which\n", .{ max_turn_tool_output, carried });
        }
        var tool_msg = chat_mod.JsonBuf.initCapacity(arena, @min(tool_result_message_bytes, result_bytes.len + tool_result_message_scaffolding_bytes));
        try tool_msg.writer().writeAll(",{\"role\":\"tool\",\"tool_call_id\":");
        try chat_mod.writeJsonString(tool_msg.writer(), call.id);
        try tool_msg.writer().writeAll(",\"content\":");
        try chat_mod.writeJsonString(tool_msg.writer(), result_bytes);
        try tool_msg.writer().writeAll("}");
        try msgs.appendSlice(gpa, tool_msg.items());
    }
    try logUsage(io, arena, usage, result);
}

/// What one call's result is carried into the conversation as: the result
/// itself while the turn has room for it, and `turn_output_capped_marker` once
/// it does not. A result that does not fit whole is not carried partly: half a
/// file read is not evidence of anything, and the marker says the output is
/// gone where a truncated one would read as the whole of it.
///
/// `carried` is what this turn's results have added so far and `capped`
/// whether the marker has been written, both handed back so the caller can
/// name the ceiling once for the turn instead of once per call past it.
fn carriedToolResult(
    result: []const u8,
    carried: *usize,
    capped: *bool,
) []const u8 {
    if (carried.* +| result.len <= max_turn_tool_output) {
        carried.* += result.len;
        return result;
    }
    capped.* = true;
    return turn_output_capped_marker;
}

/// The assistant turn as the request body spells it. Plain content when the
/// response called no tool, else the call list: `arguments` is whatever the
/// provider streamed, as a string, whether or not it is JSON yet.
fn assistantMessage(arena: std.mem.Allocator, result: *const chat_mod.ChatResult) ![]u8 {
    // Every byte written below is a byte that arrived over the wire this turn,
    // and the surrounding JSON adds a fixed amount per call, so the message is
    // sized before the first write. On the request arena a buffer grown to that
    // size leaves every intermediate block behind. It is a starting size rather
    // than a bound, since escaping can make a message longer, which is what
    // `JsonBuf.initCapacity` is for.
    const json_per_call: usize = 64;
    const json_per_message: usize = 32;
    var bytes: usize = result.content.items.len + json_per_message;
    for (result.calls.items) |call| {
        bytes += call.id.len + call.name.len + call.args.items.len + json_per_call;
    }
    var msg = chat_mod.JsonBuf.initCapacity(arena, bytes);
    try msg.writer().writeAll("{\"role\":\"assistant\",\"content\":");
    if (result.content.items.len == 0 and result.calls.items.len > 0) {
        try msg.writer().writeAll("null");
    } else {
        try chat_mod.writeJsonString(msg.writer(), result.content.items);
    }
    if (result.calls.items.len == 0) {
        try msg.writer().writeAll("}");
        return msg.items();
    }
    try msg.writer().writeAll(",\"tool_calls\":[");
    for (result.calls.items, 0..) |call, idx| {
        if (idx > 0) try msg.writer().writeAll(",");
        try msg.writer().writeAll("{\"id\":");
        try chat_mod.writeJsonString(msg.writer(), call.id);
        try msg.writer().writeAll(",\"type\":\"function\",\"function\":{\"name\":");
        try chat_mod.writeJsonString(msg.writer(), call.name);
        try msg.writer().writeAll(",\"arguments\":");
        try chat_mod.writeJsonString(msg.writer(), call.args.items);
        try msg.writer().writeAll("}}");
    }
    try msg.writer().writeAll("]}");
    return msg.items();
}

// One machine-readable line per response: gauntlet reads these for live
// token rates, and they are the only stdout that is not model output.
fn logUsage(io: Io, arena: std.mem.Allocator, usage: *chat_mod.Usage, result: *const chat_mod.ChatResult) !void {
    usage.add(result);
    var usage_line = chat_mod.JsonBuf.init(arena);
    const w = usage_line.writer();
    try w.writeAll("{\"type\":\"usage\",\"usage\":{");
    try w.print(chat_mod.usage_fields, .{
        usage.prompt, usage.cached, usage.completion, usage.reasoning, usage.total,
    });
    try w.writeAll("}}\n");
    // The usage line is what a live reader parses tokens out of, so a stdout
    // that refuses it is said on stderr: a monitor that sees the run's counters
    // stop and no line for the last response learns why from the run's end.
    net.writeOut(io, usage_line.items()) catch |err| {
        net.note(io, arena, "microagent: the usage line for this response could not be written to stdout ({s})\n", .{@errorName(err)});
        return err;
    };
}

const max_attempts: u32 = 3;
/// The ceiling on the wait between attempts. The base and the doubling count
/// are the shared ones in `net`; only the cap is this run's, and `update`
/// names a shorter one for a fetch with nobody waiting on it.
const max_backoff_ms: u64 = 60_000;

/// How far one attempt got with the request before it failed.
const request_stage = enum {
    /// Nothing of the request reached the wire.
    opened,
    /// The body is partly on the wire, so the provider cannot have parsed a
    /// turn out of it yet.
    sending,
    /// Every byte of the turn is on the wire and the provider has had it since.
    head,
};

/// Whether a failure at this stage is worth sending the turn again.
///
/// Only the head is not. The provider read the whole request, so a connection
/// that died before the response arrived may have generated and billed the
/// completion anyway, and a second POST of the same conversation is a second
/// billable completion for one turn. Losing that turn is the cheaper failure,
/// so the run ends on the error and the operator is told it was not resent.
/// An idempotency key would settle it, and the OpenAI-shaped completions API
/// this speaks takes none, so the request cannot be made safe to send twice.
///
/// Past that the error decides, and the set of them is the shared one: the
/// failures a second connection can answer, where nothing this run or the URL
/// got wrong is among them.
fn worthAnotherAttempt(stage: request_stage, err: anyerror) bool {
    if (stage == .head) return false;
    return net.transientTransportError(err);
}

/// Names the endpoint and the step that failed, then sleeps before the next
/// attempt. False means attempts are spent and the caller should surface the
/// error. A retried request says so: without this line a provider that refuses
/// two requests in a row and answers the third is a run that merely took
/// longer, and nothing on the operator's screen explains the gap. Only the
/// steps that fail before the request is on the wire come through here; one
/// that fails after is not retried at all, for the reason the head branch in
/// `streamChat` gives.
fn waitBeforeRetry(io: Io, arena: std.mem.Allocator, url: []const u8, attempt: u32, what: []const u8, err: anyerror, budget: Budget) bool {
    if (attempt >= max_attempts) return false;
    const backoff = net.retryBackoffMs(attempt, max_backoff_ms);
    if (!budget.canAffordWait(io, backoff)) {
        net.note(io, arena, "microagent: {s} {s} failed ({s}), and the {d}ms before another attempt would pass the run's budget; this one is the last\n", .{
            what, url, @errorName(err), backoff,
        });
        return false;
    }
    net.note(io, arena, "microagent: {s} {s} failed ({s}), retrying (attempt {d}/{d})\n", .{
        what, url, @errorName(err), attempt + 1, max_attempts,
    });
    // A wait that could not be taken is not a wait. Returning true anyway sent
    // the next attempt the instant the sleep failed, which is the one thing the
    // backoff exists to prevent, and it did it silently: the line above already
    // promised a delay the run then did not take.
    waitMs(io, backoff) catch |wait_err| {
        net.note(io, arena, "microagent: the {d}ms wait before that attempt to {s} could not be taken ({s}); the attempt is abandoned rather than sent at once\n", .{
            backoff, url, @errorName(wait_err),
        });
        return false;
    };
    return true;
}

/// The wait before attempt `attempt + 1` to a response the provider refused:
/// the one its `Retry-After` names, and the run's own backoff where the header
/// names none this run is willing to wait.
///
/// The header wins where it names a wait, and the schedule stands where it does
/// not, because the schedule is 1 s and 2 s and a provider that says "come
/// back in 30" is still refusing at second 2. Zero is not a wait, so a header
/// that reads as one does not get to spend the backoff's place. A `Retry-After`
/// date the run's clock has already passed is the ordinary way to reach it: the
/// date form is the one a CDN or gateway computes against its own clock sends,
/// and two machines' clocks a minute apart is a smaller disagreement than the
/// run is likely to have with either of them. A literal `retry-after: 0`
/// reaches it too. Either way the header named a wait that has already
/// elapsed, which is a reason to try again and not a reason to try again at
/// once: taking the zero sent all three attempts within milliseconds of each
/// other, three billable refusals from a provider that had asked for a pause,
/// and the backoff this schedule exists for never ran at all.
fn retryWaitMs(head: []const u8, now_seconds: i64, attempt: u32) u64 {
    const backoff = net.retryBackoffMs(attempt, max_backoff_ms);
    const asked = net.retryAfterMs(head, now_seconds) orelse return backoff;
    return if (asked > 0) asked else backoff;
}

/// The wait a backoff or a `Retry-After` asks for. It sleeps on
/// `budget_clock` because the budget is what the wait was measured against,
/// and a wait that ignores the suspend the budget counted would be longer than
/// the run's own accounting says it is.
fn waitMs(io: Io, ms: u64) !void {
    try io.sleep(.{ .nanoseconds = ms *| std.time.ns_per_ms }, budget_clock);
}

// A file's tests are collected only when the root file's test block imports
// it, so the conversation, stream frame, `update` subcommand and
// session log tests are pulled in here.
test {
    _ = conversation_mod;
    _ = session_mod;
    _ = stream_mod;
    _ = update_mod;
}

test "the api key is only sent over https, or to a loopback gateway" {
    try std.testing.expect(net.urlCarriesKey("https://openrouter.ai/api/v1"));
    try std.testing.expect(net.urlCarriesKey("https://gateway.internal:8443/v1"));

    // The loopback exemption is what makes a local gateway usable at all.
    try std.testing.expect(net.urlCarriesKey("http://localhost:1234/v1"));
    try std.testing.expect(net.urlCarriesKey("http://LocalHost:1234/v1"));
    try std.testing.expect(net.urlCarriesKey("http://127.0.0.1:1234/v1"));
    try std.testing.expect(net.urlCarriesKey("http://127.1.2.3/v1"));
    try std.testing.expect(net.urlCarriesKey("http://[::1]:1234/v1"));
    // A name that ends in the loopback spelling is the same machine: a
    // resolver sends `.localhost` nowhere, so the exemption has to read the
    // suffix and not only the whole name.
    try std.testing.expect(net.urlCarriesKey("http://gateway.localhost:1234/v1"));
    try std.testing.expect(net.urlCarriesKey("http://Gateway.LocalHost/v1"));

    // Anywhere else, plaintext would put the key on the wire in the clear.
    try std.testing.expect(!net.urlCarriesKey("http://openrouter.ai/api/v1"));
    try std.testing.expect(!net.urlCarriesKey("http://gateway.internal:1234/v1"));
    // A name that merely starts with the loopback prefix is somebody else's.
    try std.testing.expect(!net.urlCarriesKey("http://127.evil.com/api/v1"));
    try std.testing.expect(!net.urlCarriesKey("http://localhost.evil.com/api/v1"));
    try std.testing.expect(!net.urlCarriesKey("http://127.0.0/v1"));
    // Octets past 255 are not addresses, so a resolver is what answers a name
    // spelled that way, and the resolver is not this machine.
    try std.testing.expect(!net.urlCarriesKey("http://127.256.0.1/v1"));
    try std.testing.expect(!net.urlCarriesKey("http://127.0.0.999:1234/v1"));
    try std.testing.expect(!net.urlCarriesKey("http://[::2]:1234/v1"));
    // Anything that is not a url at all carries nothing.
    try std.testing.expect(!net.urlCarriesKey("not a url"));
    try std.testing.expect(!net.urlCarriesKey(""));
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
    try std.testing.expectEqualStrings("https://openrouter.ai/api/v1", displayUrl(arena, "https://openrouter.ai/api/v1"));
    try std.testing.expectEqualStrings(
        "https://openrouter.ai/api/v1?x=1",
        displayUrl(arena, "https://openrouter.ai/api/v1?x=1"),
    );
    // Not a url at all, so there is no authority to look in.
    try std.testing.expectEqualStrings("openrouter.ai", displayUrl(arena, "openrouter.ai"));
    // The base url is whatever the operator's shell passed, and the notes name
    // it on every failure, so it reaches the terminal the way every other value
    // a diagnostic quotes does: no control byte, and no byte that is not text.
    try std.testing.expectEqualStrings(
        "https://[redacted]@openrouter.ai/caf\u{fffd}\\x1b",
        displayUrl(arena, "https://u:p@openrouter.ai/caf\xe9\x1b"),
    );
    try std.testing.expectEqualStrings(
        "https://openrouter.ai/\u{fffd}",
        displayUrl(arena, "https://openrouter.ai/\xff"),
    );
}

// `$HOME` is the operator's own environment, and it is named on the one line a
// run with no key at all reaches: the message saying where to put one. A home
// a wrapper, a container image or a shell set with a control byte or a byte
// that is not text reached the terminal through it, while every sibling
// diagnostic quoting a path escaped the same value through `safeTextAll`.
// `clip` is that escaping for the `die` paths, and this is what it does to the
// shapes an environment actually carries.
test "a home directory quoted into a diagnostic is escaped" {
    // The quoted form of each, because a check that the output merely has no
    // control byte in it is satisfied by dropping the ESC sequence outright,
    // and by a string that says nothing about the path either. The bytes a
    // terminal would act on are named as the escape for the byte, and a byte
    // that is not UTF-8 is replaced rather than written through, so the
    // quoted form is valid UTF-8 and cannot end mid-codepoint.
    for ([_]struct { home: []const u8, shown: []const u8 }{
        .{ .home = "/home/me", .shown = "/home/me" },
        // ESC and the clear-screen sequence behind it.
        .{ .home = "/home/\x1b[2J", .shown = "/home/\\x1b[2J" },
        // A latin-1 e-acute: not UTF-8, so it reaches the screen as mojibake
        // written through rather than as the character the operator set.
        .{ .home = "/home/caf\xe9", .shown = "/home/caf\u{fffd}" },
        // The truncation tail of a two-byte sequence.
        .{ .home = "/home/\xe6\x97", .shown = "/home/\u{fffd}\u{fffd}" },
        // Bidi override: the path reads as a different directory from the one
        // named.
        .{ .home = "/home/\u{202e}sj.nigulp", .shown = "/home/\\u202esj.nigulp" },
        // Zero-width space inside a component.
        .{ .home = "/home/me\u{200b}/.secrets", .shown = "/home/me\\u200b/.secrets" },
    }) |case| {
        const shown = clip(case.home);
        try std.testing.expectEqualStrings(case.shown, shown);
        try std.testing.expect(std.unicode.utf8ValidateSlice(shown));
        for (shown) |c| try std.testing.expect(c >= 0x20 and c != 0x7f);
    }
    // An ordinary home comes back as it went in, so the message still names a
    // path the operator can copy.
    try std.testing.expectEqualStrings("/home/me/.secrets", clip("/home/me/.secrets"));
}

// The base url is the one value that decides where the api key goes, and it
// arrives from a flag, an environment variable or a config file rather than
// from this program: every spelling of an endpoint is somebody else's text.
// The two things it has to keep doing are hand-written above, so this harness
// runs the fuzzer's bytes through both and holds them to the property rather
// than to the examples: plaintext earns the key only for a host that is this
// machine, and a url that carries credentials never prints them.
// `std.testing.fuzz` runs this corpus on every `zig build test`, and through
// the fuzzer's mutations when the test binary is built in fuzz mode. The corpus
// is the shapes that decide the answer: each scheme, the loopback spellings and
// the names that only look like them, a port, userinfo, an ipv6 host, and the
// bytes a terminal would act on.
const base_url_corpus = [_][]const u8{
    "",
    " ",
    "not a url",
    "https://openrouter.ai/api/v1",
    "HTTPS://OpenRouter.AI/api/v1",
    "http://openrouter.ai/api/v1",
    "httpsx://openrouter.ai",
    "ftp://openrouter.ai",
    "//openrouter.ai",
    "https:/openrouter.ai",
    "https://",
    "https://:8443/v1",
    "https://user:sk-secret@openrouter.ai/api/v1",
    "https://user@openrouter.ai",
    "https://@openrouter.ai",
    "https://a@b@openrouter.ai",
    "http://localhost:1234/v1",
    "http://LocalHost:1234/v1",
    "http://localhost.",
    "http://localhost.evil.com/v1",
    "http://localhost:99999999/v1",
    "http://x.localhost:1/v1",
    "http://.localhost/v1",
    "http://127.0.0.1:1234/v1",
    "http://127.1.2.3/v1",
    "http://127.256.0.1/v1",
    "http://127.0.0.1.evil.com/v1",
    "http://127./v1",
    "http://127.0.0/v1",
    "http://127.0.0.1./v1",
    "http://[::1]:1234/v1",
    "http://[::2]/v1",
    "http://[::1",
    "http://gateway.internal:8443/v1",
    "http://127.0.0.1\t.evil.com/v1",
    "http://127.0.0.1\u{1b}[31m/v1",
    "https://u:p@openrouter.ai/caf\xe9\x1b",
    "https://openrouter.ai/\xff",
    "https://openrouter.ai/\u{0}\u{7f}",
    "https://" ++ "a" ** 300 ++ ".com/v1",
    "http://\u{65e5}\u{8a00}/v1",
};

test "a fuzzed base url carries the key only over tls or to this machine" {
    try std.testing.fuzz({}, fuzzBaseUrl, .{ .corpus = &base_url_corpus });
}

fn fuzzBaseUrl(_: void, smith: *std.testing.Smith) !void {
    const gpa = std.testing.allocator;
    var scratch: [8 * 1024]u8 = undefined;
    const url: []const u8 = if (smith.in) |seed| seed else scratch[0..smith.slice(&scratch)];

    // The key rides in an `Authorization` header on every request, so the
    // exemption is read from the parsed url rather than from its text: a
    // scheme that parses is the one the request will use, and a host that
    // parses out of it is the one the socket is opened to.
    if (net.urlCarriesKey(url)) {
        const uri = std.Uri.parse(url) catch return error.TestUnexpectedResult;
        if (std.ascii.eqlIgnoreCase(uri.scheme, "https")) return;
        // Plaintext. The host has to be this machine, spelled the four ways a
        // resolver sends to this machine and no other.
        var host_buf: [Io.net.HostName.max_len]u8 = undefined;
        const host = (uri.getHost(&host_buf) catch return error.TestUnexpectedResult).bytes;
        try std.testing.expect(net.isLoopbackHost(host));
        var lower: [256]u8 = undefined;
        if (host.len > lower.len) return error.TestUnexpectedResult;
        const h = std.ascii.lowerString(&lower, host);
        if (std.mem.eql(u8, std.mem.trim(u8, h, "[]"), "::1")) return;
        if (std.mem.eql(u8, h, "localhost") or std.mem.endsWith(u8, h, ".localhost")) return;
        // A dotted quad, and `127` is the whole of the range: a name that only
        // begins with it is a host somebody else can point anywhere.
        var octets: usize = 0;
        var it = std.mem.splitScalar(u8, h, '.');
        var first: u16 = 0;
        while (it.next()) |part| {
            if (part.len == 0 or part.len > 3) return error.TestUnexpectedResult;
            const n = std.fmt.parseInt(u16, part, 10) catch return error.TestUnexpectedResult;
            if (n > 255) return error.TestUnexpectedResult;
            if (octets == 0) first = n;
            octets += 1;
        }
        try std.testing.expectEqual(@as(usize, 4), octets);
        try std.testing.expectEqual(@as(u16, 127), first);
    }

    var state = std.heap.ArenaAllocator.init(gpa);
    defer state.deinit();
    const arena = state.allocator();

    // The shown url is what every failure of the run names, so it holds no
    // byte a terminal acts on and no byte that is not text.
    const shown = displayUrl(arena, url);
    try std.testing.expect(std.unicode.utf8ValidateSlice(shown));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, shown, "\n"));
    for (shown) |c| try std.testing.expect(c >= 0x20 and c != 0x7f);
    // Redaction is not a second pass over different bytes: a shown url carries
    // no further userinfo to hide, so showing it again changes nothing.
    try std.testing.expectEqualStrings(shown, displayUrl(arena, shown));

    // What the redactor removes never comes back, whatever it was spelled
    // with: a printable userinfo is absent from what a reader is shown.
    const scheme_end = std.mem.indexOf(u8, url, "://") orelse return;
    const rest = url[scheme_end + "://".len ..];
    const authority_end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    const at = std.mem.lastIndexOfScalar(u8, rest[0..authority_end], '@') orelse return;
    const userinfo = rest[0..at];
    if (userinfo.len == 0) return;
    for (shown) |c| {
        if (c < 0x20 or c >= 0x7f) return;
    }
    try std.testing.expect(std.mem.indexOf(u8, shown, userinfo) == null);
}

// The trace is a diagnostic like any other, and every value on it came from
// the environment or the command line. One that carries a C0 byte is written
// escaped, on the one line whose job is telling an operator which value the run
// resolved. Escaped, and long enough to still name the value: a path cut to
// the quote budget names no directory.
test "every value on the config trace is escaped and left readable" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Nothing to escape comes back as it went in, which is the common case and
    // the one a reader is scanning for.
    try std.testing.expectEqualStrings("some/model", traceText(arena, "some/model"));
    try std.testing.expectEqualStrings("unset", traceText(arena, "unset"));

    // The roots are the one value on the line that is a list, so the joining is
    // what the test is about: one root, several, and none. A run that found no
    // skills says which directories it looked in, because a count of zero is
    // the same number for a wrong root and an empty one.
    try std.testing.expectEqualStrings("none", skillRootsText(arena, &.{}));
    try std.testing.expectEqualStrings(
        "/home/me/.microagent/skills",
        skillRootsText(arena, &.{.{ .path = "/home/me/.microagent/skills", .named = false }}),
    );
    try std.testing.expectEqualStrings(
        "/one, /two",
        skillRootsText(arena, &.{
            .{ .path = "/one", .named = true },
            .{ .path = "/two", .named = true },
        }),
    );
    // A path is escaped on its own, so a directory name carrying a C0 byte
    // cannot move the cursor on the line that names the roots.
    try std.testing.expectEqualStrings(
        "/one\\x1b[2J, /two",
        skillRootsText(arena, &.{
            .{ .path = "/one\x1b[2J", .named = true },
            .{ .path = "/two", .named = true },
        }),
    );

    // A C0 byte is spelled, so a session directory or a model id carrying one
    // cannot move the cursor, clear the screen or rewrite the line under it.
    try std.testing.expectEqualStrings("a\\x1bb", traceText(arena, "a\x1bb"));
    try std.testing.expectEqualStrings("\\x00", traceText(arena, "\x00"));
    // A byte that is not text is replaced rather than passed through as
    // mojibake, the same way every other diagnostic quotes a value.
    try std.testing.expectEqualStrings("\u{fffd}", traceText(arena, "\xff"));

    // Well past the quote budget every other diagnostic cuts at.
    const long_path = "/home/" ++ "d" ** 400 ++ "/sessions";
    const shown = traceText(arena, long_path);
    try std.testing.expectEqualStrings(long_path, shown);
    try std.testing.expect(shown.len >= long_path.len);
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

    // The task is taken where it stands, so a flag after it is still a flag.
    // A parser that wanted its flags first would read "fix it" as the prompt
    // and then stop, and every case above would still pass.
    var after: Options = .{};
    const after_argv = [_][]const u8{ "fix it", "--max-turns", "7", "--model", "some/model" };
    try std.testing.expectEqual(@as(?[]const u8, null), parseArgs(&buf, &after_argv, &after));
    try std.testing.expectEqualStrings("fix it", after.prompt);
    try std.testing.expectEqual(@as(usize, 7), after.max_turns);
    try std.testing.expectEqualStrings("some/model", after.model);

    // The two flags the help spells with their own names reach their own
    // fields: both are one long word away from another option, so a table row
    // that drifted would set the CA bundle path into the config path and leave
    // every other case in the suite green.
    var named: Options = .{};
    const named_argv = [_][]const u8{ "--ca-bundle", "/etc/ca.pem", "--config", "/etc/agent.toml" };
    try std.testing.expectEqual(@as(?[]const u8, null), parseArgs(&buf, &named_argv, &named));
    try std.testing.expectEqualStrings("/etc/ca.pem", named.ca_bundle);
    try std.testing.expectEqualStrings("/etc/agent.toml", named.config);

    // And the short form of a row in the same table.
    var short_k: Options = .{};
    try std.testing.expectEqual(@as(?[]const u8, null), parseArgs(&buf, &.{ "-k", "sk-a-key" }, &short_k));
    try std.testing.expectEqualStrings("sk-a-key", short_k.api_key);
}

// A task is model output, so a prompt that begins with a dash is ordinary, and
// `--` is the spelling every other command line gives it. Before this, the only
// way to pass one was `--print`, and a bare `microagent -- "-Werror"` was an
// unknown argument and exit 2.
test "a bare -- ends the flags, so a task that starts with a dash is a task" {
    var opts: Options = .{};
    var buf: [512]u8 = undefined;
    const argv = [_][]const u8{ "--max-turns", "5", "--", "--version is not a flag here" };
    try std.testing.expectEqual(@as(?[]const u8, null), parseArgs(&buf, &argv, &opts));
    try std.testing.expectEqual(@as(usize, 5), opts.max_turns);
    try std.testing.expectEqualStrings("--version is not a flag here", opts.prompt);
    // The action stays a run, so `--` also protects a prompt that is a word
    // this parser would otherwise answer to.
    try std.testing.expectEqual(Action.run, opts.action);

    // A flag after `--` is the task, not a request for help: the early pass
    // reads the same line and has to agree, or `microagent -- --help` prints
    // the help and then runs a task nobody asked to read.
    try std.testing.expectEqual(@as(?Action, null), earlyAction(&.{ "--", "--help" }));
    try std.testing.expectEqual(@as(?Action, null), earlyAction(&.{ "--", "-V" }));
    // Before the `--`, a flag is still a flag.
    try std.testing.expectEqual(@as(?Action, .help), earlyAction(&.{ "--model", "some/model", "--help" }));

    // The prompt is still taken once, and still says so when it is taken twice.
    var twice: Options = .{};
    try std.testing.expectEqualStrings("prompt given twice: 'one' and 'two'", parseArgs(&buf, &.{ "--", "one", "two" }, &twice).?);
    var with_flag: Options = .{};
    try std.testing.expectEqualStrings("prompt given twice: 'flag' and 'task'", parseArgs(&buf, &.{ "--print", "flag", "--", "task" }, &with_flag).?);
    // An empty word after `--` is the empty prompt, not an unknown argument.
    var empty: Options = .{};
    try std.testing.expectEqualStrings("the prompt is empty: pass the task as an argument or with --print", parseArgs(&buf, &.{ "--", "" }, &empty).?);
    // A `--` on its own names no prompt, so the run says so rather than
    // sending the flag to the provider as the task.
    var bare: Options = .{};
    try std.testing.expectEqual(@as(?[]const u8, null), parseArgs(&buf, &.{"--"}, &bare));
    try std.testing.expectEqualStrings("", bare.prompt);
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

// An `argv` entry is whatever bytes the shell passed, so a diagnostic that
// quotes one is handing the operator's own bytes back to the terminal. Cut on
// a codepoint boundary is not enough of a policy: `\e[2J` clears the screen
// and `\e]0;...\a` retitles the window without a byte being invalid UTF-8, and
// a lone `\xff` is invalid and used to reach the screen as mojibake. Every
// message the parse produces goes through `clip`, which is the escaping the
// gutter line and the config diagnostics already use.
test "a command line that quotes a value quotes it as text, not as bytes" {
    var opts: Options = .{};
    var buf: [512]u8 = undefined;
    try std.testing.expectEqualStrings(
        "unknown or incomplete argument '--\\x1b[2J\\x1b[31m'",
        parseArgs(&buf, &.{"--\x1b[2J\x1b[31m"}, &opts).?,
    );
    // A byte that is not text at all reads as U+FFFD rather than passing
    // through, and the C1 range escapes as the code point a terminal acts on.
    try std.testing.expectEqualStrings(
        "unknown or incomplete argument '--\\x9b31m\u{fffd}'",
        parseArgs(&buf, &.{"--\u{009b}31m\xff"}, &opts).?,
    );
    // Text is left alone, in the scripts the operator actually types.
    try std.testing.expectEqualStrings(
        "prompt given twice: 'caf\u{00e9}' and '\u{65e5}\u{672c}\u{8a9e}'",
        parseArgs(&buf, &.{ "caf\u{00e9}", "\u{65e5}\u{672c}\u{8a9e}" }, &opts).?,
    );
    // The budget is the other message that quotes a value, and it quotes an
    // environment value as well as an argument.
    try std.testing.expectEqualStrings(
        "--budget must be a number, got '\u{fffd}\u{fffd}'",
        parseArgs(&buf, &.{ "--budget", "\xff\xfe" }, &opts).?,
    );
    // Nothing the escaper writes is a half character, whatever the value and
    // whatever the budget.
    for ([_][]const u8{ "--\x1b[2J", "\u{1f600}\u{1f600}\u{1f600}", "ok\xff\xff", "\u{65e5}\u{672c}\u{8a9e}" }) |raw| {
        const quoted = clip(raw);
        try std.testing.expect(quoted.len <= net.quoted_value_bytes);
        try std.testing.expect(std.unicode.utf8ValidateSlice(quoted));
        for (quoted) |c| try std.testing.expect(c >= 0x20 and c != 0x7f);
    }
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
    try std.testing.expectEqualStrings("MICROAGENT_BUDGET_SECONDS must be at least 1", optionalCeiling(&buf, "MICROAGENT_BUDGET_SECONDS", env.get("MICROAGENT_BUDGET_SECONDS").?, &opts.budget_s).?);
    try std.testing.expectEqual(@as(?u64, null), opts.budget_s);

    // A real budget still takes, trimmed the way a shell leaves it.
    try std.testing.expectEqual(@as(?[]const u8, null), optionalCeiling(&buf, "--budget", " 90 ", &opts.budget_s));
    try std.testing.expectEqual(@as(?u64, 90), opts.budget_s);

    // The spend ceiling refuses zero the same way: zero tokens is not "no
    // ceiling", it is a run whose first turn is not affordable. Saying "no
    // ceiling" is leaving the option out.
    try std.testing.expectEqualStrings("--max-spend-tokens must be at least 1", parseArgs(&buf, &.{ "--max-spend-tokens", "0" }, &opts).?);
    try std.testing.expectEqual(@as(?u64, null), opts.max_spend_tokens);
    try std.testing.expectEqual(@as(?[]const u8, null), parseArgs(&buf, &.{ "--max-spend-tokens", " 500000 " }, &opts));
    try std.testing.expectEqual(@as(?u64, 500_000), opts.max_spend_tokens);
    try std.testing.expectEqualStrings("--max-spend-tokens must be a number, got 'soon'", parseArgs(&buf, &.{ "--max-spend-tokens", "soon" }, &opts).?);
    try std.testing.expectEqual(@as(?u64, 500_000), opts.max_spend_tokens);

    // The other two ceilings, which are typed rather than u64, so a value a
    // wider one accepts is refused here for being out of range rather than out
    // of shape. A zero turn count is a run that does no work; a zero token
    // count is one the provider rejects, and either costs a whole turn to
    // learn. The option is left at its default: a refused value is not a value.
    var counted: Options = .{};
    try std.testing.expectEqualStrings("--max-turns must be at least 1", parseArgs(&buf, &.{ "--max-turns", "0" }, &counted).?);
    try std.testing.expectEqual(max_turns_default, counted.max_turns);
    try std.testing.expectEqualStrings("--max-tokens must be at least 1", parseArgs(&buf, &.{ "--max-tokens", "0" }, &counted).?);
    try std.testing.expectEqual(default_max_tokens, counted.max_tokens);

    // 1e30 is a number, past the u32 the option is sent in, so it is refused
    // for overflow and the message says it could not be read as one rather than
    // that it was too small.
    try std.testing.expectEqualStrings("--max-tokens must be a number, got '1e30'", parseArgs(&buf, &.{ "--max-tokens", "1e30" }, &counted).?);
    try std.testing.expectEqual(default_max_tokens, counted.max_tokens);
}

// A run's spend is the one ceiling nothing else bounds. `--max-turns` counts
// turns, so a run that reaches the ceiling in five turns and one that reaches
// it in a hundred cost the same by its own count, and a turn's cost is a whole
// conversation re-sent: the run that keeps appending tool results and never
// compacts bills more with fewer turns than one that does. `--max-tokens` is
// the same figure for every response, so neither of them is a bound on what a
// run spends. This is.
test "a run stops at the spend ceiling, and announces itself before it does" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // No ceiling is no ceiling: the loop is bounded by turns and by time, and
    // neither of those is a number of tokens.
    try std.testing.expect(!spendCeilingReached(1_000_000_000, null));
    try std.testing.expect(!spendAlarmDue(1_000_000_000, null));
    try std.testing.expect(spendNotice(arena, 1_000_000_000, null, 5) == null);

    // Under the ceiling the run goes on, and quietly: the alarm is a fraction
    // of the way there, not every turn below it.
    try std.testing.expect(!spendCeilingReached(99, 100));
    try std.testing.expect(!spendAlarmDue(79, 100));
    try std.testing.expect(spendNotice(arena, 79, 100, 3) == null);

    // The announcement is one line naming the numbers, so an operator watching
    // a bill sees the run approaching the limit it set.
    try std.testing.expectEqualStrings(
        "microagent: 80 of the 100 token ceiling spent after 3 turn(s)\n",
        spendNotice(arena, 80, 100, 3).?,
    );

    // The ceiling itself, reached on the turn that is already paid for: the
    // check is made before a turn is started, so a run that lands exactly on
    // the cap stops rather than taking one more.
    try std.testing.expect(spendCeilingReached(100, 100));
    try std.testing.expect(spendCeilingReached(101, 100));
    try std.testing.expectEqualStrings(
        "microagent: stopped at the --max-spend-tokens ceiling (100 tokens) after 4 turn(s) and 100 token(s); the answer is a prefix of the work\n",
        spendNotice(arena, 100, 100, 4).?,
    );

    // A cap of one token is crossed by any turn at all, so the alarm would
    // always be saying what the ceiling stop already says.
    try std.testing.expect(spendCeilingReached(1, 1));
    try std.testing.expect(!spendAlarmDue(0, 1));
    try std.testing.expect(!spendAlarmDue(1, 1));

    // A cap far past what any provider reports. The percent divides before it
    // multiplies, so nothing wraps and the threshold stays a fraction of the
    // cap rather than a small number that alarms on the first turn.
    const huge = std.math.maxInt(u64);
    const threshold = huge / 100 * spend_alarm_percent + huge % 100 * spend_alarm_percent / 100;
    try std.testing.expect(threshold > huge / 2);
    try std.testing.expect(!spendAlarmDue(threshold - 1, huge));
    try std.testing.expect(spendAlarmDue(threshold, huge));
    try std.testing.expect(!spendCeilingReached(huge - 1, huge));
    try std.testing.expect(spendCeilingReached(huge, huge));

    // A cap small enough that the percent is a fraction of a token. An
    // announcement after a turn that spent nothing would name a run approaching
    // a limit it had not touched.
    try std.testing.expectEqual(@as(u64, 8), spendAlarmThreshold(10));
    try std.testing.expect(!spendAlarmDue(0, 10));
    try std.testing.expect(!spendAlarmDue(7, 10));
    try std.testing.expect(spendAlarmDue(8, 10));
    try std.testing.expectEqual(@as(u64, 99), spendAlarmThreshold(124));
    try std.testing.expect(!spendAlarmDue(98, 124));
    try std.testing.expect(spendAlarmDue(99, 124));
}

test "the spend ceiling is set from a flag or its variable, and the run trace names it" {
    var opts: Options = .{};
    var buf: [512]u8 = undefined;
    // Both spellings the other ceilings take, and the environment path a
    // harness that prices a review sets it through.
    try std.testing.expectEqual(@as(?[]const u8, null), parseArgs(&buf, &.{ "--max-spend-tokens=250000", "fix it" }, &opts));
    try std.testing.expectEqual(@as(?u64, 250_000), opts.max_spend_tokens);
    try std.testing.expectEqualStrings("fix it", opts.prompt);

    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    try env.put("MICROAGENT_MAX_SPEND_TOKENS", " 250000 \n");
    var env_buf: [256]u8 = undefined;
    try std.testing.expectEqual(@as(?[]const u8, null), optionalCeiling(&env_buf, "MICROAGENT_MAX_SPEND_TOKENS", env.get("MICROAGENT_MAX_SPEND_TOKENS").?, &opts.max_spend_tokens));
    try std.testing.expectEqual(@as(?u64, 250_000), opts.max_spend_tokens);

    // Every flag the table lists is spelled the way the help text spells it, so
    // a new ceiling cannot be parsed by a name its own help does not have.
    try std.testing.expectEqual(@as(ValuedOption, .max_spend_tokens), valuedFlag("--max-spend-tokens").?.option);
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

// `microagent help` is a request, not a task: a bare word on the agent's own
// command line must not be billed to the caller as a coding run. Only a bare
// word, though: a prompt already set, a value of --print, and anything after
// `--` are all still a task, by the rules that were already there.
test "a bare help is a request, and only a bare one" {
    var buf: [512]u8 = undefined;

    var asked: Options = .{};
    try std.testing.expectEqual(@as(?[]const u8, null), parseArgs(&buf, &.{"help"}, &asked));
    try std.testing.expectEqual(Action.help, asked.action);
    try std.testing.expectEqualStrings("", asked.prompt);

    // A flags line in front of it changes nothing, and the walk that runs
    // before the environment is read reaches the same answer.
    var after_flag: Options = .{};
    try std.testing.expectEqual(@as(?[]const u8, null), parseArgs(&buf, &.{ "--model", "some/model", "help" }, &after_flag));
    try std.testing.expectEqual(Action.help, after_flag.action);
    try std.testing.expectEqual(@as(?Action, .help), earlyAction(&.{"help"}));
    try std.testing.expectEqual(@as(?Action, .help), earlyAction(&.{ "--budget", "30", "help" }));

    // The three ways of asking for the word as a task, each already spelled.
    var given: Options = .{};
    try std.testing.expectEqualStrings("prompt given twice: 'hi' and 'help'", parseArgs(&buf, &.{ "hi", "help" }, &given).?);
    var valued: Options = .{};
    try std.testing.expectEqual(@as(?[]const u8, null), parseArgs(&buf, &.{ "-p", "help" }, &valued));
    try std.testing.expectEqualStrings("help", valued.prompt);
    try std.testing.expectEqual(Action.run, valued.action);
    var after: Options = .{};
    try std.testing.expectEqual(@as(?[]const u8, null), parseArgs(&buf, &.{ "--", "help" }, &after));
    try std.testing.expectEqualStrings("help", after.prompt);
    try std.testing.expectEqual(Action.run, after.action);
    try std.testing.expectEqual(@as(?Action, null), earlyAction(&.{ "--", "help" }));
}

// The walk that runs before the environment is read has to reach the same
// answer as the walk that runs after it, on the arguments both of them are
// given, and it has to leave a command line that asks for no help and no
// version alone. `earlyAction` is what keeps `microagent --help` working on
// a machine whose `MICROAGENT_MAX_TURNS` is not a number, which is the only
// way that walk is reachable at all.
test "the walk that answers help before reading the environment agrees with the parser" {
    const cases = [_]struct { argv: []const []const u8, want: ?Action }{
        .{ .argv = &.{ "a prompt", "--help" }, .want = .help },
        .{ .argv = &.{ "-V", "--model" }, .want = .version },
        .{ .argv = &.{"--help=1"}, .want = .help },
        // The value of a valued flag is stepped over, so these words are a
        // prompt and not a request for help. The parser says the same.
        .{ .argv = &.{ "-p", "--help" }, .want = null },
        .{ .argv = &.{ "--print", "--help" }, .want = null },
        .{ .argv = &.{ "-p", "hi", "-h" }, .want = .help },
        .{ .argv = &.{"hi"}, .want = null },
        .{ .argv = &.{"help"}, .want = .help },
        // The word is a request only while it is the first bare word, and only
        // outside a value a flag took.
        .{ .argv = &.{ "hi", "help" }, .want = null },
        .{ .argv = &.{ "-p", "hi", "help" }, .want = null },
        .{ .argv = &.{ "--print=hi", "help" }, .want = null },
        .{ .argv = &.{ "-p", "help" }, .want = null },
        .{ .argv = &.{ "--", "help" }, .want = null },
        .{ .argv = &.{"--nope"}, .want = null },
        .{ .argv = &.{}, .want = null },
    };
    for (cases) |c| {
        try std.testing.expectEqual(c.want, earlyAction(c.argv));
        var opts: Options = .{};
        var buf: [512]u8 = undefined;
        _ = parseArgs(&buf, c.argv, &opts);
        if (c.want) |want| try std.testing.expectEqual(want, opts.action) else try std.testing.expectEqual(Action.run, opts.action);
    }
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
    "help",
    "one help",
    "--print help",
    "-- help",
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

    // One word per run of blanks, up to the array: a parser is handed arguments
    // rather than one opaque word.
    var argv: [64][]const u8 = undefined;
    var split = std.mem.tokenizeAny(u8, text, " \t\n");
    var n: usize = 0;
    while (n < argv.len) : (n += 1) argv[n] = split.next() orelse break;
    const words = argv[0..n];

    var buf: [512]u8 = undefined;
    var opts: Options = .{};
    const msg = parseArgs(&buf, words, &opts);
    if (msg) |m| try std.testing.expect(m.len > 0);

    // `--help` and `--version` stop the parse where they are, so an argument
    // after one of them sets nothing, whatever it says.
    const stops = blk: {
        for (words) |arg| {
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
        try std.testing.expect(inArgv(words, value));
    }
    if (opts.reasoning_effort) |level| try std.testing.expect(inArgv(words, level));
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
        for (words) |arg| {
            const n_ = std.fmt.parseInt(u64, std.mem.trim(u8, arg, " \t\r\n"), 10) catch continue;
            if (n_ == seconds) on_the_line = true;
        }
        try std.testing.expect(on_the_line);
    }

    // The same line parsed twice says the same thing, so an operator who
    // reruns the failing invocation sees the failure again.
    var again: Options = .{};
    var again_buf: [512]u8 = undefined;
    const again_msg = parseArgs(&again_buf, words, &again);
    try std.testing.expectEqualStrings(opts.prompt, again.prompt);
    try std.testing.expectEqual(opts.max_turns, again.max_turns);
    try std.testing.expectEqual(opts.max_tokens, again.max_tokens);
    try std.testing.expectEqual(again_msg == null, msg == null);
}

/// Whether a value is the default that `Options` starts with, which is what an
/// argument that never arrived leaves behind.
fn isDefault(value: []const u8) bool {
    return std.mem.eql(u8, value, default_model) or
        value.len == 0;
}

/// Whether `value` came out of a word on the command line, whole or cut at the
/// `=` of a joined `--flag=value`. An option the parser did not take keeps the
/// default, so a value that is in no word was written by the parser itself.
fn inArgv(argv: []const []const u8, value: []const u8) bool {
    for (argv) |arg| if (std.mem.indexOf(u8, arg, value) != null) return true;
    return false;
}

test "conversation and tool schema serialize as one valid request body" {
    // The body's storage belongs to a chat_mod.JsonBuf, not to the caller, so the test
    // hands it an arena instead of trying to free the slice by hand.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const gpa = arena_state.allocator();
    var msgs: std.ArrayList(u8) = .empty;
    try msgs.appendSlice(gpa, "[");
    try conversation_mod.appendMessage(gpa, &msgs, "system", conversation_mod.system_prompt);
    try conversation_mod.appendMessage(gpa, &msgs, "user", "say \"hi\"\nplease");

    const opts: Options = .{ .model = "test/model" };
    const body = try buildBody(gpa, opts, msgs.items);

    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, body, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqualStrings("test/model", root.get("model").?.string);
    try std.testing.expect(root.get("stream").?.bool);
    // The generation ceiling is on every request: without it the provider's own
    // limit is the only bound on what one turn can cost.
    try std.testing.expectEqual(
        @as(i64, default_max_tokens),
        root.get("max_tokens").?.integer,
    );

    const messages = root.get("messages").?.array;
    try std.testing.expectEqual(@as(usize, 2), messages.items.len);
    try std.testing.expectEqualStrings("system", messages.items[0].object.get("role").?.string);
    try std.testing.expectEqualStrings("say \"hi\"\nplease", messages.items[1].object.get("content").?.string);

    // The advertised names and the tool_mod dispatch table are one list, because
    // both are `chat.Tool`: a tool in the schema that the dispatcher cannot
    // dispatch is a variant with no arm in an exhaustive switch, which does not
    // build. What is left to hold the schema to is that it advertises the list
    // in the order `chat.tools` gives, with nothing added and nothing dropped.
    const advertised = blk: {
        var names: [chat_mod.tools().len][]const u8 = undefined;
        for (chat_mod.tools(), &names) |tool, *slot| slot.* = tool.name();
        break :blk &names;
    };
    // What each tool answers when its one required argument is missing, which
    // is the dispatch every advertised name has to reach.
    const missing_argument = std.StaticStringMap([]const u8).initComptime(.{
        .{ "read", "error: missing path" },
        .{ "write", "error: missing path" },
        .{ "edit", "error: missing path" },
        .{ "multi_edit", "error: missing edits" },
        .{ "todo", "error: missing items" },
        .{ "search", "error: missing pattern" },
        .{ "ast", "error: missing pattern" },
        .{ "git", "error: missing cmd" },
        .{ "bash", "error: missing command" },
    });

    const tools = root.get("tools").?.array;
    try std.testing.expectEqual(advertised.len, tools.items.len);
    for (advertised, tools.items) |name, tool| {
        const f = tool.object.get("function").?.object;
        try std.testing.expectEqualStrings(name, f.get("name").?.string);
        // The description is what the model picks the tool by, so an empty one
        // is a tool the model has no reason to call.
        try std.testing.expect(f.get("description").?.string.len > 0);
        try std.testing.expect(f.get("parameters").?.object.get("required") != null);
        // Every tool has a required argument, so `{}` is refused by the tool
        // itself, each with its own message. A dispatcher that answered with
        // the empty string, or with any other error, would satisfy a check for
        // the absence of one particular string, so the refusal each tool owes
        // is the thing asserted.
        const err = try tool_mod.dispatch(arena_state.allocator(), name, "{}");
        try std.testing.expectEqualStrings(missing_argument.get(name).?, err);
    }

    // The numbers the schema quotes to the model are the only defaults written
    // twice: once as a constant the tool acts on, once as prose the model plans
    // a command around. A constant moved without the prose leaves the model
    // budgeting a timeout the run no longer grants, and nothing else in the
    // build notices, because both halves are well-formed on their own. The
    // constants are public for this one check, and the check is here because
    // this is the only module that holds both halves.
    const bash_timeout = try std.fmt.allocPrint(gpa, "default {d}, at most {d}", .{
        tool_mod.default_bash_timeout_ms,
        tool_mod.max_bash_timeout_ms,
    });
    try std.testing.expect(std.mem.indexOf(u8, parameterDescription(tools.items, "bash", "timeout_ms"), bash_timeout) != null);
    const git_limit = try std.fmt.allocPrint(gpa, "default {d}", .{tool_mod.git_default_limit});
    try std.testing.expect(std.mem.indexOf(u8, parameterDescription(tools.items, "git", "limit"), git_limit) != null);
}

// A run that found skills advertises one more tool than the built-in list, and
// a run that found none sends the constant schema byte for byte. Both halves
// matter: the first is how the model learns a skill exists, the second is the
// request prefix a provider caches, which a stray entry would change on every
// run.
test "skills add one tool to the schema and change nothing when there are none" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var msgs: std.ArrayList(u8) = .empty;
    try msgs.appendSlice(arena, "[");
    try conversation_mod.appendMessage(arena, &msgs, "system", conversation_mod.system_prompt);
    try conversation_mod.appendMessage(arena, &msgs, "user", "hi");

    const with_skills: Options = .{ .model = "m", .skills = .{ .items = &.{
        .{ .name = "pdf", .description = "fills forms", .path = "/pdf/SKILL.md" },
    } } };
    const body = try buildBody(arena, with_skills, msgs.items);
    const parsed = try std.json.parseFromSlice(std.json.Value, arena, body, .{});
    const tools = parsed.value.object.get("tools").?.array;
    try std.testing.expectEqual(chat_mod.tools().len + 1, tools.items.len);
    const last = tools.items[tools.items.len - 1].object.get("function").?.object;
    try std.testing.expectEqualStrings(skill_mod.tool_name, last.get("name").?.string);

    const plain = try buildBody(arena, .{ .model = "m" }, msgs.items);
    try std.testing.expect(std.mem.indexOf(u8, plain, "\"skill\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, plain, tools_json) != null);
}

// The wire gets the prefix and the conversation as two writes and the closing
// bytes as a third; `buildBody` is those three parts in one buffer for the
// tests that read a body back. This pins the two together, so a change to one
// that forgets the other is caught here rather than by a provider's cache.
test "the streamed body is the prefix, the conversation and the close" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const arena = state.allocator();
    const opts: Options = .{ .model = "m" };
    const messages = "[{\"role\":\"user\",\"content\":\"hi\"}]";
    const prefix = try bodyPrefix(arena, opts);
    try std.testing.expect(std.mem.endsWith(u8, prefix, ",\"messages\":"));
    const body = try buildBody(arena, opts, messages);
    try std.testing.expectEqualStrings(prefix, body[0..prefix.len]);
    try std.testing.expectEqualStrings(messages, body[prefix.len..][0..messages.len]);
    try std.testing.expectEqualStrings(body_close, body[prefix.len + messages.len ..]);
}

// The routing half: a `skill` call reaches the run's set rather than the tool
// module's seven names, and a body on disk comes back. Without this the name
// comparison could be dropped and the call would read `unknown tool 'skill'`
// to a model the schema had just advertised it to.
test "a skill call is served from the run's skill set" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "pdf");
    try tmp.dir.writeFile(io, .{ .sub_path = "pdf/SKILL.md", .data = "---\nname: pdf\ndescription: d\n---\nuse qpdf\n" });
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = path_buf[0..try tmp.dir.realPath(io, &path_buf)];
    const skills = skill_mod.discover(io, arena, &.{.{ .path = root, .named = true }});

    var call: chat_mod.ToolCall = .{ .id = try arena.dupe(u8, ""), .name = try arena.dupe(u8, skill_mod.tool_name) };
    try call.args.appendSlice(arena, "{\"name\":\"pdf\"}");
    var mcp: mcp_mod.Servers = .{};
    try std.testing.expectEqualStrings("use qpdf\n", try dispatchCall(io, arena, skills, &mcp, .initEmpty(), call, null, null, &.{}, &.{}));

    // The same call on a run with no skills is the set's own refusal, not the
    // tool module's `unknown tool`.
    const out = try dispatchCall(io, arena, .{}, &mcp, .initEmpty(), call, null, null, &.{}, &.{});
    try std.testing.expect(std.mem.startsWith(u8, out, "error: unknown skill 'pdf'"));
}

test "dispatchCall enforces sandbox writable roots on write" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = path_buf[0..try tmp.dir.realPath(io, &path_buf)];
    const writable_roots = [_][]const u8{root};

    var call: chat_mod.ToolCall = .{ .id = try arena.dupe(u8, ""), .name = try arena.dupe(u8, "write") };
    try call.args.appendSlice(arena, "{\"path\":\"/etc/forbidden.txt\",\"content\":\"hello\"}");
    var mcp: mcp_mod.Servers = .{};
    const out = try dispatchCall(io, arena, .{}, &mcp, .initEmpty(), call, null, null, &.{}, &writable_roots);
    try std.testing.expect(std.mem.startsWith(u8, out, "refused:"));
    try std.testing.expect(std.mem.indexOf(u8, out, "outside the sandbox writable roots") != null);
}

// An MCP server's tools are in the schema the same way a skill is: appended to
// the constant, with the server's own inputSchema copied verbatim. A run with
// no servers sends the constant, which the test above already holds.
test "MCP tools join the schema with the server's own inputSchema" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var msgs: std.ArrayList(u8) = .empty;
    try msgs.appendSlice(arena, "[");
    try conversation_mod.appendMessage(arena, &msgs, "system", conversation_mod.system_prompt);
    try conversation_mod.appendMessage(arena, &msgs, "user", "hi");

    // Only the tool list is read, so the transport is never touched, and
    // the list is never shut down: there is nothing behind it.
    const items = try arena.alloc(mcp_mod.Server, 1);
    items[0] = .{
        .name = "srv",
        .transport = undefined,
        .tools = &.{.{
            .name = "echo",
            .exposed = "mcp__srv__echo",
            .description = "Echo text back",
            .schema = "{\"type\":\"object\",\"properties\":{\"text\":{\"type\":\"string\"}}}",
        }},
    };
    const servers: mcp_mod.Servers = .{ .items = items };
    const body = try buildBody(arena, .{ .model = "m", .mcp = servers }, msgs.items);
    const parsed = try std.json.parseFromSlice(std.json.Value, arena, body, .{});
    const tools = parsed.value.object.get("tools").?.array;
    try std.testing.expectEqual(chat_mod.tools().len + 1, tools.items.len);
    const last = tools.items[tools.items.len - 1].object.get("function").?.object;
    try std.testing.expectEqualStrings("mcp__srv__echo", last.get("name").?.string);
    try std.testing.expect(last.get("parameters").?.object.get("properties") != null);
}

/// The description one property of one tool's schema carries, which is where a
/// default the model reads is written down. A tool or property this schema does
/// not have is a test that cannot say what it meant to check, so the lookup
/// fails rather than answering with an empty string.
fn parameterDescription(tools: []const std.json.Value, tool_name: []const u8, property: []const u8) []const u8 {
    for (tools) |tool| {
        const f = tool.object.get("function") orelse continue;
        if (!std.mem.eql(u8, chat_mod.str(f.object.get("name")) orelse continue, tool_name)) continue;
        const parameters = f.object.get("parameters") orelse return "";
        const named = parameters.object.get("properties") orelse return "";
        const one = named.object.get(property) orelse return "";
        return chat_mod.str(one.object.get("description")) orelse return "";
    }
    return "";
}

// The quadratic a ranged read had, one module up: a line longer than the
// tool's 8 KB read means nothing is consumed until the far end of the file,
// so a scan that restarts at the front of the buffer and a copy of the whole
// buffer cost a full pass per read. This lives in main rather than in the tool
// module on purpose: `--test-filter` does not reach tests declared in an
// imported module, so a test over there is not something the instruction gate
// can measure, which is how a multi-billion-instruction regression stayed
// unmeasured for two rounds.
test "a ranged read of a long line comes back whole" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    const path = try std.fs.path.join(arena, &.{ dir_path, "long-line.txt" });

    // Sixty-four reads plus a bit. The size is the point: the quadratic is a
    // re-scan and a full copy of the buffer per read, so it is invisible at a
    // few reads and the instruction gate would sit inside its own tolerance
    // band with a test too small to catch a re-introduction. At this width the
    // work is two orders of magnitude apart between the two versions.
    const width = 8 * 1024 * 64 + 137;
    var text: std.ArrayList(u8) = .empty;
    try text.appendSlice(arena, "before\n");
    try text.appendNTimes(arena, 'z', width);
    try text.appendSlice(arena, "\nafter\n");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "long-line.txt", .data = text.items });

    const args = try std.fmt.allocPrint(arena, "{{\"path\":\"{s}\",\"offset\":2,\"limit\":1}}", .{path});
    const got = try tool_mod.dispatch(arena, "read", args);

    var want: std.ArrayList(u8) = .empty;
    try want.appendNTimes(arena, 'z', width);
    try want.append(arena, '\n');
    try std.testing.expectEqualStrings(want.items, got);
}

// The cacheable part of a request is its leading bytes, so the only thing a
// turn may add is the tail. Asserted as a byte count, because that is the whole
// point: a field moved back behind `messages` costs the provider a re-read of
// its bytes on every turn of every run, and nothing else here would notice.
test "one request body is the previous one plus its new messages" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const gpa = arena_state.allocator();

    var msgs: std.ArrayList(u8) = .empty;
    try msgs.appendSlice(gpa, "[");
    try conversation_mod.appendMessage(gpa, &msgs, "system", conversation_mod.system_prompt);
    try conversation_mod.appendMessage(gpa, &msgs, "user", "fix the bug");

    const opts: Options = .{ .model = "test/model" };
    // A body is the constant header, the message array, then `]}`, so the
    // header is whatever is left once those two are taken off the end.
    var previous = try gpa.dupe(u8, try buildBody(gpa, opts, msgs.items));
    const header = previous.len - msgs.items.len - 2;
    try std.testing.expect(header > tools_json.len);

    var turn: usize = 0;
    while (turn < 40) : (turn += 1) {
        try msgs.appendSlice(gpa, ",{\"role\":\"assistant\",\"content\":\"working\"}");
        try msgs.appendSlice(gpa, ",{\"role\":\"tool\",\"tool_call_id\":\"c\",\"content\":\"ok\"}");
        const added = msgs.items.len;

        const body = try buildBody(gpa, opts, msgs.items);
        // Header and every message so far are still there byte for byte, so the
        // un-cacheable tail is the two closing bytes and the schema is inside
        // the cache from the second turn on.
        const shared = header + (previous.len - header - 2);
        try std.testing.expectEqualSlices(u8, previous[0..shared], body[0..shared]);
        try std.testing.expectEqual(added - (shared - header), body.len - previous.len);
        try std.testing.expectEqualSlices(u8, "]", body[body.len - 2 .. body.len - 1]);

        gpa.free(previous);
        previous = try gpa.dupe(u8, body);
    }
}

// The tool schema is the largest constant in a body, so where it sits decides
// whether the provider can cache it at all. This says so out loud instead of
// leaving it to a field order nobody reads twice.
test "the tool schema sits inside the cacheable prefix, not behind the conversation" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const gpa = arena_state.allocator();
    const body = try buildBody(gpa, .{ .model = "m" }, "[{\"role\":\"user\",\"content\":\"hi\"}]");

    const tools_at = std.mem.indexOf(u8, body, "\"tools\":").?;
    const messages_at = std.mem.indexOf(u8, body, "\"messages\":").?;
    try std.testing.expect(tools_at < messages_at);
    // Worth ordering only because the schema is worth caching: a few kilobytes
    // of it is several hundred tokens of prefill the provider would otherwise
    // repeat. The band below is what holds the size the comments quote, so a
    // schema that leaves it is big enough to want remeasuring.
    try std.testing.expect(tools_json.len > 2 * 1024);
    try std.testing.expect(tools_json.len < 8 * 1024);
    try std.testing.expectEqualStrings(tools_json, body[tools_at + 8 ..][0..tools_json.len]);
}

// A line of the stream that never ends is the one shape the response ceiling
// cannot see, because nothing is consumed and nothing is folded into a frame.
test "a stream line that never ends is bounded" {
    try std.testing.expect(max_frame_bytes < stream_mod.max_response_bytes);

    // The check is on what the split left, so that is the buffer that has to
    // stop growing.
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const gpa = state.allocator();

    var pending: std.ArrayList(u8) = .empty;
    try pending.appendNTimes(gpa, 'd', max_frame_bytes + 1);
    try std.testing.expect(frameOverran(pending.items));

    // The boundary itself: a line of exactly the ceiling is carried, and one
    // byte more ends the turn. A ceiling moved by a byte moves this pair, so
    // the check is pinned to the number rather than to a buffer it grew.
    try pending.resize(gpa, max_frame_bytes);
    try std.testing.expect(!frameOverran(pending.items));
    try pending.append(gpa, 'd');
    try std.testing.expect(frameOverran(pending.items));
    // A line that ends costs nothing whatever its length, because the split
    // has consumed it before the ceiling is read.
    var whole: std.ArrayList(u8) = .empty;
    try whole.appendNTimes(gpa, 'd', max_frame_bytes * 2);
    try whole.append(gpa, '\n');
    var consumed: usize = 0;
    _ = net.nextLineEnd(whole.items, &consumed).?;
    try std.testing.expect(!frameOverran(whole.items[consumed..]));

    // A line that does end is consumed by the split before the ceiling is
    // read, so what the ceiling is applied to is the residual rather than
    // everything the read carried: a line of exactly the ceiling, plus the
    // newline that ends it, is a line this turn carries.
    var complete: std.ArrayList(u8) = .empty;
    try complete.appendNTimes(gpa, 'd', max_frame_bytes);
    try complete.append(gpa, '\n');
    var scanned: usize = 0;
    const end = net.nextLineEnd(complete.items, &scanned).?;
    try std.testing.expectEqual(@as(usize, max_frame_bytes), end);
    try std.testing.expect(complete.items[end + 1 ..].len <= max_frame_bytes);
}

// A response may ask for `max_tool_calls` results of `max_tool_output` each, and
// compaction only runs at the top of a turn, so the turn that fills the
// conversation is the one nothing bounds. Every result past the turn's ceiling
// is a marker: the call keeps its place in the conversation, so the next
// request still pairs every `tool_call_id`, and its output is gone.
test "a turn's tool results stop at the turn's ceiling and every call still answers" {
    var carried: usize = 0;
    var capped = false;
    // A full-size result, which is what a `read` of a large file returns.
    const full = try std.testing.allocator.alloc(u8, tool_mod.max_tool_output);
    defer std.testing.allocator.free(full);
    @memset(full, 'x');

    var carried_results: usize = 0;
    var markers: usize = 0;
    // More calls than fit, so the ceiling is reached inside this loop and the
    // rest of the turn is markers.
    for (0..stream_mod.max_tool_calls + 1) |_| {
        const carried_bytes = carriedToolResult(full, &carried, &capped);
        if (std.mem.eql(u8, carried_bytes, turn_output_capped_marker)) {
            markers += 1;
        } else {
            try std.testing.expectEqualStrings(full, carried_bytes);
            carried_results += 1;
        }
    }
    try std.testing.expect(capped);
    try std.testing.expect(markers > 0);
    // Every call still has a result to write, which is what keeps the pairing
    // the next request rejects without: every call answered with either the
    // full result or a marker, and none was left without one.
    try std.testing.expectEqual(
        @as(usize, stream_mod.max_tool_calls + 1),
        carried_results + markers,
    );
    // The calls the ceiling did fit are exactly the ones that fit: every result
    // is a full `max_tool_output`, so the turn carries that many and marks the
    // rest, and a ceiling moved by one result would move this count.
    try std.testing.expectEqual(max_turn_tool_output / tool_mod.max_tool_output, carried_results);
    try std.testing.expect(carried <= max_turn_tool_output);
    // A result that still fits the turn's remaining room is carried, so a turn
    // of many small results never meets the ceiling, and the total stays under
    // it either way.
    const after = carriedToolResult("small", &carried, &capped);
    try std.testing.expectEqualStrings("small", after);
    try std.testing.expect(carried <= max_turn_tool_output);
}

// A run's conversation has no closing bracket: `buildBody` is what writes it,
// so the buffer every request is built from is an open array. `appendToolResults`
// closes it for the tests above, which is why compaction was only ever driven
// over a complete document and this shape was never reached. The two halves of
// the contract are pinned together here, because either one alone is silent: a
// parse that wants a document it does not have aborts the run, and a rewrite
// that keeps the bracket sends every later request as a closed array followed
// by the one `buildBody` adds.
test "compaction reads and rewrites the open array a run carries" {
    const gpa = std.testing.allocator;
    var scratch_state = std.heap.ArenaAllocator.init(gpa);
    defer scratch_state.deinit();

    var msgs: std.ArrayList(u8) = .empty;
    defer msgs.deinit(gpa);

    try conversation_mod.openConversation(gpa, &msgs, "you are a coding agent", "fix the bug");
    try conversation_mod.appendToolResults(gpa, &msgs, 120, "x" ** 8192);
    try std.testing.expectEqual(@as(u8, '}'), msgs.items[msgs.items.len - 1]);

    const before = msgs.items.len;
    try std.testing.expect(before > conversation_mod.conversation_soft_limit);
    var floor: usize = 0;
    try conversation_mod.compactMessages(std.testing.io, gpa, &msgs, scratch_state.allocator(), &floor);

    // It elided, and it is still open, and it still parses once the run's own
    // bracket is written back.
    try std.testing.expect(msgs.items.len < before);
    try std.testing.expect(msgs.items[msgs.items.len - 1] == '}');
    var body_arena_state = std.heap.ArenaAllocator.init(gpa);
    defer body_arena_state.deinit();
    const body_arena = body_arena_state.allocator();
    const body = try buildBody(body_arena, .{ .model = "test/model" }, msgs.items);
    const parsed = try std.json.parseFromSlice(std.json.Value, body_arena, body, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 122), parsed.value.object.get("messages").?.array.items.len);
}

// The stream arrives in reads of a fixed size, so a frame longer than one read
// is handed over in pieces. Splitting has to find every line exactly once and
// search each byte of it once, whether it lands whole or a byte at a time.
test "a frame split across reads yields the same lines, and is searched once" {
    const gpa = std.testing.allocator;

    const lines = [_][]const u8{ "data: one", "", "data: two", "data: [DONE]" };
    var wire: std.ArrayList(u8) = .empty;
    defer wire.deinit(gpa);
    for (lines, 0..) |line, i| {
        if (i > 0) try wire.appendSlice(gpa, "\n");
        try wire.appendSlice(gpa, line);
    }
    try wire.append(gpa, '\n');

    var seen: std.ArrayList([]u8) = .empty;
    defer {
        for (seen.items) |l| gpa.free(l);
        seen.deinit(gpa);
    }

    // The stream loop's own shape: append what a read brought, drain the lines
    // it completed, drop what was consumed. One byte at a time is the worst
    // case for the scan, so the counter is at its most meaningful here.
    var pending: std.ArrayList(u8) = .empty;
    defer pending.deinit(gpa);
    var scanned: usize = 0;
    var searched: usize = 0;
    for (wire.items) |b| {
        try pending.append(gpa, b);
        var start: usize = 0;
        while (true) {
            // Each call looks at exactly the bytes between the old cursor and
            // the new one, whether it found a newline or ran off the end.
            const was = scanned;
            const found = net.nextLineEnd(pending.items, &scanned);
            searched += scanned - was;
            const pos = found orelse break;
            try seen.append(gpa, gpa.dupe(u8, pending.items[start..pos]) catch return error.OutOfMemory);
            start = pos + 1;
        }
        if (start > 0) {
            dropWritten(&pending, start);
            scanned -|= start;
        }
    }
    try std.testing.expectEqual(lines.len, seen.items.len);
    for (lines, seen.items) |want, got| try std.testing.expectEqualStrings(want, got);
    // Every byte looked at exactly once, not once per line that followed it.
    try std.testing.expectEqual(wire.items.len, searched);
}

test "the api key is sent as the request's authorization header" {
    // Regression: this was passed as a privileged header, which never reached
    // the wire, and every provider answered 401 with no credential at all. The
    // header struct is the one the request writer reads, so asserting on it is
    // asserting on the wire.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const headers = try authHeaders(arena_state.allocator(), "sk-test");
    switch (headers.authorization) {
        .override => |value| try std.testing.expectEqualStrings("Bearer sk-test", value),
        else => return error.TestUnexpectedResult,
    }

    // A key with a newline in it is still one header value: the request writer
    // is what stops a CRLF here from becoming a second header, so the value it
    // is handed has to carry the key whole.
    const spaced = try authHeaders(arena_state.allocator(), "sk-two words");
    switch (spaced.authorization) {
        .override => |value| try std.testing.expectEqualStrings("Bearer sk-two words", value),
        else => return error.TestUnexpectedResult,
    }
}

test "only a bash call that names a runner counts as verification" {
    // A runner in a bash command is a test run.
    try std.testing.expect(isTestRun("bash", "{\"command\":\"python -m pytest tests/\"}"));
    try std.testing.expect(isTestRun("bash", "{\"command\":\"cargo test --all\"}"));
    try std.testing.expect(isTestRun("bash", "{\"command\":\"zig build test\"}"));

    // Reading a test file is not, and neither is the issue text mentioning
    // pytest: judging by the conversation counted both and asked for nothing.
    try std.testing.expect(!isTestRun("read", "{\"path\":\"tests/test_thing.py\"}"));
    try std.testing.expect(!isTestRun("bash", "{\"command\":\"ls tests/\"}"));
    try std.testing.expect(!isTestRun("search", "{\"pattern\":\"pytest\"}"));

    // A name inside a longer word is not a runner either: a substring match
    // read each of these as a test run, which told the loop an untested edit had
    // been tested and took away the verification turn that would have caught
    // it. The words have to stand as they are typed.
    try std.testing.expect(!isTestRun("bash", "{\"command\":\"cat pytest_output.log\"}"));
    try std.testing.expect(!isTestRun("bash", "{\"command\":\"grep -rn 'cargo test' src/\"}"));
    try std.testing.expect(!isTestRun("bash", "{\"command\":\"sed -i s/tox/pox/ tox.ini\"}"));
    try std.testing.expect(!isTestRun("bash", "{\"command\":\"cargo testfoo\"}"));
    try std.testing.expect(!isTestRun("bash", "{\"command\":\"zig build test-fast\"}"));

    // The same words on their own still are, whatever surrounds them.
    try std.testing.expect(isTestRun("bash", "{\"command\":\"cd src && cargo test --all\"}"));
    try std.testing.expect(isTestRun("bash", "{\"command\":\"uv run pytest -q\"}"));

    // The window is the optimization, and the edge it puts between a name that
    // matches and one that does not is a name spanning a word boundary the
    // window drops. A three-word name matched at its last word, so the two
    // words before it have to survive being pushed out by everything between
    // it and the next candidate; the two-word names have to survive the same
    // push. The brute-force reference below is the predicate the window has to
    // agree with, spelled out per name over the whole string, and these are the
    // shapes where the two can part company.
    const cases = [_][]const u8{
        "{\"command\":\"cargo test\"}",
        "{\"command\":\"zig build test\"}",
        "{\"command\":\"manage.py test\"}",
        "{\"command\":\"gradle test --info\"}",
        "{\"command\":\"dotnet test -c Release\"}",
        // A two-word name whose first word is one read, and the second another.
        "{\"command\":\"ls; cargo test; ls\"}",
        "{\"command\":\"a b cargo c d test e f\"}",
        // The longest name, with words on either side pushing the window.
        "{\"command\":\"x y z zig build test p q r\"}",
        "{\"command\":\"x y z mvn test p q r\"}",
        // One word short of a name, and one past it.
        "{\"command\":\"cargo tests\"}",
        "{\"command\":\"zig build tests\"}",
        // A name whose words are adjacent but in the wrong order.
        "{\"command\":\"test cargo\"}",
        "{\"command\":\"build zig test\"}",
        // The same name split across the JSON punctuation rather than a space.
        "{\"command\":\"cargo\",\"other\":\"test\"}",
        // Nothing at all, and only separators.
        "{\"command\":\"\"}",
        "{\"command\":\"   \"}",
        "",
    };
    inline for (cases) |args| {
        try std.testing.expectEqual(
            bruteForceTestRun(args),
            isTestRun("bash", args),
        );
    }
}

// The arguments of a `bash` call, and the shapes that decide whether the run
// they belong to counts as having tested itself. `std.testing.fuzz` runs this
// corpus through the harness on every `zig build test`, and through the fuzzer's
// mutations when the test binary is built in fuzz mode. Every byte here is the
// provider's: the arguments are the raw text it streamed, so a name is matched
// against whatever the model wrote rather than against a command anybody typed.
// The corpus is the hand-picked list above grown to what a run really receives:
// each name in the table bare and inside a JSON call, a name with words on
// either side pushing the window past it, one word short of a name and one past
// it, a name split across the JSON punctuation, the same name twice, and the
// argument text that is not a call at all.
const test_run_corpus = [_][]const u8{
    "",
    " ",
    "\t\r\n",
    "{}",
    "{\"command\":\"\"}",
    "{\"command\":\"ls\"}",
    "{\"command\":\"ls tests/\"}",
    "{\"command\":\"cat pytest_output.log\"}",
    "{\"command\":\"grep -rn 'cargo test' src/\"}",
    "{\"command\":\"sed -i s/tox/pox/ tox.ini\"}",
    "pytest",
    "cargo test",
    "cargo tests",
    "test cargo",
    "zig build test",
    "zig build tests",
    "build zig test",
    "manage.py test",
    "manage.py tests",
    "gradle test --info",
    "dotnet test -c Release",
    "{\"command\":\"cargo test\"}",
    "{\"command\":\"cargo test --all -- --nocapture\"}",
    "{\"command\":\"zig build test --summary all\"}",
    "{\"command\":\"uv run pytest -q\"}",
    "{\"command\":\"python -m pytest tests/\"}",
    "{\"command\":\"npm test && npm run build\"}",
    "{\"command\":\"cd src && cargo test --all\"}",
    "{\"command\":\"ls; cargo test; ls\"}",
    "{\"command\":\"a b cargo c d test e f\"}",
    "{\"command\":\"x y z zig build test p q r\"}",
    "{\"command\":\"x y z mvn test p q r\"}",
    "{\"command\":\"x y z gradle test p q r\"}",
    "{\"command\":\"x y z bazel test p q r\"}",
    "{\"command\":\"x y z swift test p q r\"}",
    "{\"command\":\"x y z mix test p q r\"}",
    "{\"command\":\"x y z dotnet test p q r\"}",
    // The name split across the JSON punctuation rather than a space, which is
    // how a streamed argument actually arrives.
    "{\"command\":\"cargo\",\"other\":\"test\"}",
    "{\"command\":\"zig\",\"other\":\"build\",\"third\":\"test\"}",
    "{\"command\":\"manage.py\",\"other\":\"test\"}",
    "{\"command\":\"cargo test\"}{\"command\":\"cargo test\"}",
    "{\"command\":\"cargo test\",\"cwd\":\"src\"}",
    "{\"path\":\"tests/test_thing.py\"}",
    "{\"pattern\":\"fn main\",\"lang\":\"zig\"}",
    "{\"command\":\"cargo test\"}\n{\"command\":\"ls\"}",
    "{\"command\":\"\\u0000cargo test\"}",
    "{\"command\":\"cargo test\\u0000\"}",
    "{\"command\":\"CARGO TEST\"}",
    "{\"command\":\"Cargo test\"}",
    "{\"command\":\"cargo  test\"}",
    "{\"command\":\"\\tcargo\\ntest\\r\"}",
    "{\"command\":\"caf\\u00e9 cargo test \\u65e5\\u8a00\"}",
    "{\"command\":\"" ++ "a" ** 500 ++ " cargo test\"}",
    "{\"command\":\"" ++ "a" ** 500 ++ "\"}",
    "{\"command\":\"\\ud83d\\ude80 test\"}",
    "{\"command\":\"\\xff\\xfe cargo test\"}",
};

test "a fuzzed bash call is a test run to both the window and the whole-string search" {
    try std.testing.fuzz({}, fuzzTestRun, .{ .corpus = &test_run_corpus });

    // The corpus has to reach both answers, or the equality above is never
    // disagreed with: a command naming a runner is a test run, and one naming
    // none is not.
    try std.testing.expect(isTestRun("bash", "{\"command\":\"cargo test\"}"));
    try std.testing.expect(!isTestRun("bash", "{\"command\":\"cargo tests\"}"));
}

fn fuzzTestRun(_: void, smith: *std.testing.Smith) !void {
    var scratch: [8 * 1024]u8 = undefined;
    const args: []const u8 = if (smith.in) |seed| seed else scratch[0..smith.slice(&scratch)];

    // The window `finishTurn` slides over the argument words and the
    // whole-string search below are two answers to one question, and they
    // answering differently is a verification turn gained or lost: a run that
    // edited the tree and never named a runner is the one this predicate asks
    // for a turn it did not get. The reference is the whole-string search, so
    // the window is what the fuzzer holds to it.
    const windowed = isTestRun("bash", args);
    try std.testing.expectEqual(bruteForceTestRun(args), windowed);

    // Only a `bash` call is one. The same bytes under a read or a search named
    // nothing that was run, and counting it would verify a run that did not
    // happen.
    for ([_][]const u8{ "read", "search", "edit", "git", "write", "" }) |name|
        try std.testing.expect(!isTestRun(name, args));

    // What separates one word of the argument from the next is the set below,
    // and the arguments arrive as raw JSON where a name is often split by its
    // own punctuation. Every name in the table, spelled with each of those
    // characters in place of its spaces, is that runner to both searches: a
    // separator dropped from the set is a runner this run never recognizes, and
    // no hand-picked seed finds that on its own.
    var any_matched = false;
    for (test_runners) |runner| {
        for (tool_word_separators) |separator| {
            var spelled: [max_runner_spelling]u8 = undefined;
            const n = replaceSpaces(runner, separator, &spelled);
            const windowed_spell = isTestRun("bash", spelled[0..n]);
            try std.testing.expectEqual(bruteForceTestRun(spelled[0..n]), windowed_spell);
            if (windowed_spell) any_matched = true;
        }
    }
    // Every name in the table, spelled with every separator in place of its
    // spaces, is a test run. A separator dropped from the set leaves the names
    // that use it unrecognized, and the two searches agree on that, so nothing
    // above would have said so.
    if (!any_matched) return error.TestUnexpectedResult;
}

/// The longest a name in `test_runners` is, so the harness spells one over a
/// stack buffer rather than an allocation it has to free. Counted out of the
/// table rather than guessed, the way `test_runner_max_words` is: a name added
/// to the table that is longer than this is written past the buffer.
const max_runner_spelling = blk: {
    var n: usize = 0;
    @setEvalBranchQuota(10_000);
    for (test_runners) |runner| n = @max(n, runner.len);
    break :blk n;
};

/// `text` with every space replaced by `separator`, which is what the
/// tokenizer sees when a name arrives split by the argument's own punctuation.
fn replaceSpaces(text: []const u8, separator: u8, buf: []u8) usize {
    var n: usize = 0;
    for (text) |c| {
        buf[n] = if (c == ' ') separator else c;
        n += 1;
    }
    return n;
}

/// The runner search `isTestRun` answers, written as it was before the window:
/// every name searched for by tokenizing the whole argument string again. Kept
/// as the reference the windowed version is asserted against, because the two
/// answering differently is a verification turn gained or lost and neither
/// shape is a case a hand-picked example reliably finds.
fn bruteForceTestRun(args: []const u8) bool {
    for (test_runners) |runner| {
        var words = std.mem.tokenizeAny(u8, args, tool_word_separators);
        while (words.next()) |word| {
            var ahead = words;
            var wanted = std.mem.tokenizeAny(u8, runner, tool_word_separators);
            const head = wanted.next() orelse return false;
            if (!std.mem.eql(u8, word, head)) continue;
            var matched = true;
            while (wanted.next()) |want| {
                const got = ahead.next() orelse {
                    matched = false;
                    break;
                };
                if (!std.mem.eql(u8, got, want)) {
                    matched = false;
                    break;
                }
            }
            if (matched) return true;
        }
    }
    return false;
}

test "only a call that changes the tree counts as an edit" {
    // The two tools that write whatever they are handed, with or without
    // arguments this has to read.
    try std.testing.expect(isEdit("edit", "{\"path\":\"src/net.zig\",\"old_string\":\"a\",\"new_string\":\"b\"}"));
    try std.testing.expect(isEdit("write", "{\"path\":\"src/net.zig\",\"content\":\"\"}"));
    try std.testing.expect(!isEdit("read", "{\"path\":\"src/net.zig\"}"));
    try std.testing.expect(!isEdit("bash", "{\"command\":\"sed -i s/a/b/ src/net.zig\"}"));

    // A structural search prints its matches and changes nothing, so it is not
    // an edit: a run that only looked was being asked to verify changes it
    // never made.
    try std.testing.expect(!isEdit("ast", "{\"pattern\":\"$A == $A\",\"lang\":\"zig\"}"));
    // The one that does rewrite, every match of it.
    try std.testing.expect(isEdit("ast", "{\"pattern\":\"$A == $A\",\"lang\":\"zig\",\"rewrite\":\"$A != $A\"}"));
    // A rewrite key carrying something other than a string is not the shape
    // `runTool` dispatches, and arguments a stream cut in half are not a call
    // at all: neither is an edit, and neither has to parse to say so.
    try std.testing.expect(!isEdit("ast", "{\"pattern\":\"$A\",\"rewrite\":true}"));
    try std.testing.expect(!isEdit("ast", "{\"pattern\":\"$A\",\"rewri"));
    try std.testing.expect(!isEdit("ast", ""));
}

test "a tool timeout is cut to what is left of the budget" {
    const io = std.testing.io;
    const now = Io.Timestamp.now(io, budget_clock).nanoseconds;

    // No budget: every tool keeps the timeout it asked for, so there is no
    // ceiling to hand one.
    try std.testing.expectEqual(@as(?u64, null), (Budget{}).remainingMs(io));
    try std.testing.expectEqual(@as(?u64, null), (Budget{}).toolCeilingMs(io));

    // Ten minutes of budget left: a shorter request is untouched, a longer one
    // is cut, because it cannot finish before the deadline it would cross. The
    // ceiling is the only thing a tool's own timeout is measured against, so it
    // is the only thing asserted here; the min is `boundedMs`'s, and that it
    // does the min is the tool's own test.
    const fresh = Budget.of(now, 600);
    const left = fresh.toolCeilingMs(io).?;
    try std.testing.expect(left <= 600_000 and left > 599_000);

    // Nearly spent: the floor, but never zero, which would fail before the tool
    // started and read as a broken tool rather than a spent budget.
    const nearly = Budget{ .deadline_ns = now + 2 * std.time.ns_per_s };
    try std.testing.expectEqual(tool_timeout_floor_ms, nearly.toolCeilingMs(io).?);

    // Spent: remaining is zero, and the ceiling still leaves the floor.
    const spent = Budget{ .deadline_ns = now - 1 };
    try std.testing.expectEqual(@as(u64, 0), spent.remainingMs(io).?);
    try std.testing.expectEqual(tool_timeout_floor_ms, spent.toolCeilingMs(io).?);
    try std.testing.expect(spent.expired(io));
}

// A turn's tool calls run one after another, so a ceiling read before the first
// of them is already stale by the time the second starts. Reading once for the
// whole turn handed every call the budget as it stood when the turn began, and
// a turn naming three `bash` calls against a two-minute budget gave each of them
// the full two minutes: 180s of command on a 120s ceiling, and the run only
// noticed on the next turn. `finishTurn` reads per call for that reason, and
// this is what the per-call read buys: the same budget answers a smaller ceiling
// later, so a call that ran long is what shortens the one after it.
test "a budget read later is a smaller ceiling for the next call in a turn" {
    const io = std.testing.io;
    // A minute, not a second: below `tool_timeout_floor_ms` the ceiling is the
    // floor however much budget is left, so a short budget would answer the same
    // number twice and prove nothing about the clock behind it.
    const budget = Budget.of(Io.Timestamp.now(io, budget_clock).nanoseconds, 60);
    const first = budget.toolCeilingMs(io).?;
    // Comfortably inside the second, so a loaded host cannot spend the whole gap
    // and leave nothing to compare.
    io.sleep(.{ .nanoseconds = 200 * std.time.ns_per_ms }, .awake) catch |err| {
        std.debug.print("\nno sleep on this host: {t}\n", .{err});
        return err;
    };
    const second = budget.toolCeilingMs(io).?;
    try std.testing.expect(second < first);
    // And by about what was slept, not merely by a millisecond: the ceiling
    // tracks the budget's own clock, so a second reading 200ms on is 200ms
    // closer to the deadline. Half the sleep is the bound, so a slow host still
    // passes and a ceiling that ignored the clock does not.
    try std.testing.expect(first - second >= 100);
}

test "reasoning effort is only sent when asked for" {
    // chat_mod.JsonBuf owns the storage it hands back, so the test gives it an arena
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
    try std.testing.expect(net.retryableStatus(.too_many_requests));
    try std.testing.expect(net.retryableStatus(.bad_gateway));
    try std.testing.expect(net.retryableStatus(.service_unavailable));
    try std.testing.expect(!net.retryableStatus(.bad_request));
    try std.testing.expect(!net.retryableStatus(.unauthorized));
    try std.testing.expect(!net.retryableStatus(.not_found));
}

// The provider reading a whole request is the point at which the turn behind
// it may already have been generated and billed. Resending it buys a second
// billable completion for one turn, so a lost head ends the run instead, while
// the two failures that happen before the request is readable on the far end
// are the provider's weather and are still retried. The error narrows that
// further: a transport fault a second connection can answer, and nothing that
// this run got wrong, since three attempts at a refused CA bundle only delay
// the same refusal.
test "a turn is resent only while the provider cannot have read it" {
    try std.testing.expect(worthAnotherAttempt(.opened, error.ConnectionRefused));
    try std.testing.expect(worthAnotherAttempt(.sending, error.ConnectionRefused));
    try std.testing.expect(!worthAnotherAttempt(.head, error.ConnectionRefused));
    try std.testing.expect(!worthAnotherAttempt(.opened, error.OutOfMemory));
    try std.testing.expect(!worthAnotherAttempt(.sending, error.InvalidUrl));
}

// The one failure after the request is on the wire that is asked again is the
// provider reporting a failure it produced nothing behind: there is no answer
// on stdout to duplicate and no half-assembled tool call to lose. The schedule
// is the pre-wire one, and the same three-attempt cap.
test "a provider failure with nothing behind it is asked again, up to the cap" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const shown_url = "https://example.invalid/v1/chat/completions";

    const first = reaskWaitMs(io, .{}, 1, arena, shown_url) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(net.retryBackoffMs(1, max_backoff_ms), first);
    // The last ask under the cap is not another one.
    try std.testing.expectEqual(@as(?u64, null), reaskWaitMs(io, .{}, max_attempts, arena, shown_url));
    // A budget that cannot cover the wait ends the run rather than sleeping
    // through it, and the note says which of the two it was.
    const spent: Budget = .{ .deadline_ns = Io.Timestamp.now(io, budget_clock).nanoseconds - 1 };
    try std.testing.expectEqual(@as(?u64, null), reaskWaitMs(io, spent, 1, arena, shown_url));
}

// A response that called no tool ends the loop, and a run that ends there is
// only finished if the response was an answer. A refusal, a content filter and a
// response cut at `max_tokens` all arrive the same way, and each of them would
// otherwise leave the run exiting 0 over nothing or over a prefix.
test "a toolless response that is not an answer does not finish the run" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Text and no reason: the ordinary answer, and the only shape that is one.
    var answered: chat_mod.ChatResult = .{};
    try answered.content.appendSlice(std.testing.allocator, "done");
    defer answered.deinit(std.testing.allocator);
    try std.testing.expect(incompleteAnswer(arena, &answered, default_max_tokens) == null);

    // The provider stopped generating: no answer whatever it left behind.
    var blocked: chat_mod.ChatResult = .{ .finish_reason = try arena.dupe(u8, "content_filter") };
    const blocked_notice = incompleteAnswer(arena, &blocked, default_max_tokens).?;
    try std.testing.expect(std.mem.indexOf(u8, blocked_notice, "content_filter") != null);

    // A refusal, an empty completion and a stream that carried only a usage
    // frame all arrive with nothing in them and no reason to read.
    var empty: chat_mod.ChatResult = .{};
    const empty_notice = incompleteAnswer(arena, &empty, default_max_tokens).?;
    try std.testing.expect(std.mem.indexOf(u8, empty_notice, "no text and no tool call") != null);
    try std.testing.expect(std.mem.indexOf(u8, empty_notice, "none sent") != null);

    var tool_only: chat_mod.ChatResult = .{ .finish_reason = try arena.dupe(u8, "tool_calls") };
    const tool_notice = incompleteAnswer(arena, &tool_only, default_max_tokens).?;
    try std.testing.expect(std.mem.indexOf(u8, tool_notice, "tool_calls") != null);

    // Cut at the generation ceiling: what is there is a prefix of the answer,
    // and the ceiling that cut it is named so a caller can raise it.
    var cut: chat_mod.ChatResult = .{ .finish_reason = try arena.dupe(u8, "length") };
    try cut.content.appendSlice(std.testing.allocator, "half an ans");
    defer cut.content.deinit(std.testing.allocator);
    const cut_notice = incompleteAnswer(arena, &cut, default_max_tokens).?;
    try std.testing.expect(std.mem.indexOf(u8, cut_notice, "max_tokens 65536") != null);
    try std.testing.expect(std.mem.indexOf(u8, cut_notice, "prefix") != null);
}

// The reason this notice quotes is the provider's own field, and the notice is
// the last line a run prints before it exits, so a provider (or a gateway in
// front of one) that spells it with a control byte or a byte that is not text
// would otherwise be acting on the operator's terminal through it. Both reach
// this notice on the one path that produces it: a response with no content and
// no tool call.
test "the finish reason in an incomplete-answer notice is escaped" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    for ([_][]const u8{
        // ESC and the CSI that follows it: what a terminal acts on.
        "blocked\x1b[2J",
        // A lone lead byte and a truncated sequence: what reaches the screen as
        // mojibake.
        "caf\xe9",
        "trimmed\xe6\x97",
        // Bidi override: it reorders the sentence around it, so a reader sees
        // a reason other than the one the provider sent.
        "deploy/\u{202e}gnp.exe",
        // A zero-width space inside a word the operator is meant to compare.
        "slo\u{200b}w",
        // Long enough to be cut, so the cut lands on a character boundary
        // rather than in the middle of one.
        "\u{65e5}" ** 40,
    }) |reason| {
        var result: chat_mod.ChatResult = .{ .finish_reason = try arena.dupe(u8, reason) };
        const notice = incompleteAnswer(arena, &result, default_max_tokens).?;

        try std.testing.expect(std.unicode.utf8ValidateSlice(notice));
        for (notice) |c| {
            // DEL is escaped too, and so is every C0 control; what is left is
            // printable ASCII and whole characters above it.
            try std.testing.expect(c >= 0x20 and c != 0x7f);
        }
        // And none of the invisible set, which is valid text a byte test passes.
        var i: usize = 0;
        while (i < notice.len) {
            const len = chat_mod.utf8SequenceLen(notice, i);
            try std.testing.expect(len > 0);
            try std.testing.expect(!chat_mod.isInvisibleFormat(
                std.unicode.utf8Decode(notice[i..][0..len]) catch unreachable,
            ));
            i += len;
        }
    }
}

test "token counters read the OpenAI and OpenRouter spellings" {
    try std.testing.expectEqual(@as(u64, 42), chat_mod.num(.{ .integer = 42 }));
    try std.testing.expectEqual(@as(u64, 7), chat_mod.num(.{ .number_string = "7" }));
    try std.testing.expectEqual(@as(u64, 0), chat_mod.num(.{ .integer = -1 }));
    try std.testing.expectEqual(@as(u64, 0), chat_mod.num(null));
}

// A tool argument is a model-controlled string, and a model that sends
// `{"path": 42}` or `{"path": null}` must be told the argument is missing
// rather than having the number read as a path. Only a JSON string is a
// string; every other type, including a number and a bool, is refused.
test "a tool argument is a string or it is refused" {
    try std.testing.expectEqualStrings("a.zig", chat_mod.str(.{ .string = "a.zig" }).?);
    try std.testing.expectEqualStrings("", chat_mod.str(.{ .string = "" }).?);
    try std.testing.expect(chat_mod.str(null) == null);
    try std.testing.expect(chat_mod.str(.{ .integer = 42 }) == null);
    try std.testing.expect(chat_mod.str(.{ .float = 1.5 }) == null);
    try std.testing.expect(chat_mod.str(.{ .bool = true }) == null);
}

/// Cheap env-gated trace, for debugging a stuck stream. Set once from MDEBUG
/// before any turn runs.
var debug_enabled: bool = false;

test "out-of-range numbers from the model saturate instead of trapping" {
    try std.testing.expectEqual(std.math.maxInt(u64), chat_mod.num(.{ .float = 1e30 }));
    try std.testing.expectEqual(@as(u64, 0), chat_mod.num(.{ .float = -5 }));
    try std.testing.expectEqual(@as(u64, 0), chat_mod.num(.{ .float = std.math.nan(f64) }));
    // A millisecond count that would overflow the nanosecond multiply is
    // pinned to the top of the range, not to whatever the wrapping multiply
    // left behind: a timeout of a few hours is a slow server, and one of a few
    // hundred nanoseconds is a server that answers nothing.
    const huge = net.durationMs(std.math.maxInt(u64));
    try std.testing.expectEqual(std.math.maxInt(u64), huge.duration.raw.nanoseconds);
    // The ordinary spelling next to it, so the saturating one is a saturating
    // one and not the only value this ever returns.
    try std.testing.expectEqual(@as(u64, 60_000) * std.time.ns_per_ms, net.durationMs(60_000).duration.raw.nanoseconds);
}

test "a saturated token count does not overflow the run total" {
    var usage: chat_mod.Usage = .{};
    const absurd: chat_mod.ChatResult = .{ .prompt_tokens = std.math.maxInt(u64), .total_tokens = std.math.maxInt(u64) };
    usage.add(&absurd);
    const ordinary: chat_mod.ChatResult = .{ .prompt_tokens = 10 };
    usage.add(&ordinary);
    try std.testing.expectEqual(std.math.maxInt(u64), usage.prompt);
    try std.testing.expectEqual(std.math.maxInt(u64), usage.total);
}

test "backoff doubles, caps, and never overflows an attempt counter" {
    try std.testing.expectEqual(@as(u64, 1000), net.retryBackoffMs(0, max_backoff_ms));
    try std.testing.expectEqual(@as(u64, 1000), net.retryBackoffMs(1, max_backoff_ms));
    try std.testing.expectEqual(@as(u64, 2000), net.retryBackoffMs(2, max_backoff_ms));
    try std.testing.expectEqual(@as(u64, 4000), net.retryBackoffMs(3, max_backoff_ms));
    try std.testing.expectEqual(max_backoff_ms, net.retryBackoffMs(1000, max_backoff_ms));
}

// Retaining a turn's peak is a speed choice; retaining an unbounded one is a
// memory choice nobody made. A response at the ceiling fills the turn's content
// buffer in full, and keeping that would leave 16 MB resident for the rest of
// the run to serve turns that need a few megabytes. The reset is the only place
// that can give it back.
test "a turn that outgrows the retained size gives the memory back" {
    var base_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer base_state.deinit();
    const base = base_state.allocator();

    // An ordinary turn keeps everything it used: the limit is above it, so the
    // reset is the one it always was. The bytes it allocated are still readable
    // afterwards, which is the half of "keeps everything" this file owns; how
    // many bytes the arena happened to reserve to hold them is the allocator's
    // decision and is not asserted here.
    var ordinary = std.heap.ArenaAllocator.init(base);
    defer ordinary.deinit();
    const peak = try ordinary.allocator().alloc(u8, 256 * 1024);
    for (peak, 0..) |_, i| peak[i] = @truncate(i);
    _ = ordinary.reset(.{ .retain_with_limit = turn_arena_retain_bytes });
    for (peak, 0..) |b, i| try std.testing.expectEqual(@as(u8, @truncate(i)), b);

    // A turn past the retain size does not: 8 MB in, and what stays behind is
    // the limit rather than the whole thing.
    var huge = std.heap.ArenaAllocator.init(base);
    defer huge.deinit();
    const big = try huge.allocator().alloc(u8, 2 * turn_arena_retain_bytes);
    std.mem.doNotOptimizeAway(big.ptr);
    _ = huge.reset(.{ .retain_with_limit = turn_arena_retain_bytes });
    try std.testing.expect(huge.queryCapacity() <= turn_arena_retain_bytes);
}

// A rate limit names the wait it wants. Retrying on this run's own 1 s and 2 s
// schedule instead is a second and third refusal from a provider that
// asked for thirty seconds, and every one of them is billed as a request.
// A provider that asks for longer than the run has left is weather the run
// cannot wait out: sleeping the full ask puts it to bed inside the caller's
// timeout, which is what --budget exists to stop, and retrying early is the
// second billable refusal the header was there to prevent. So the decision is
// the budget's.
//
// The two ends only, because std.testing.io's clock does not advance and a
// deadline between them is arithmetic that needs a real one.
test "a wait the budget cannot cover is not taken" {
    // No budget: every wait is affordable, which is the behaviour for a run
    // nobody put a ceiling on. This is the two-minute ask and the run's own
    // schedule, and both are taken exactly as before.
    const unbounded: Budget = .{};
    try std.testing.expect(unbounded.canAffordWait(std.testing.io, net.max_retry_after_ms));
    try std.testing.expect(unbounded.canAffordWait(std.testing.io, net.retryBackoffMs(2, max_backoff_ms)));

    // Spent: nothing is affordable, not even a millisecond, so no attempt is
    // made and the run ends with the reason already on stderr.
    const spent: Budget = .{ .deadline_ns = 0 };
    try std.testing.expect(!spent.canAffordWait(std.testing.io, 1));
    try std.testing.expect(!spent.canAffordWait(std.testing.io, net.retryBackoffMs(0, max_backoff_ms)));
    try std.testing.expect(!spent.canAffordWait(std.testing.io, net.max_retry_after_ms));
}

test "a budget too large to count in milliseconds is a ceiling, not a trap" {
    // `--budget 20000000000000000` is a number `ceiling` accepts: it
    // is a u64 and it is not zero. In milliseconds it needs more bits than a
    // u64 has, and the deadline is nanoseconds, so the millisecond answer is
    // the one that runs out of room. It saturates: a run set up that way keeps
    // its own ceiling for anything that reads a duration, rather than panicking
    // on the cast in a checked build and wrapping in a release one.
    const huge: Budget = .{ .deadline_ns = @as(i96, std.math.maxInt(u64)) * std.time.ns_per_s };
    try std.testing.expectEqual(@as(?u64, std.math.maxInt(u64)), huge.remainingMs(std.testing.io));
    // The same ceiling reaches a tool rather than a number it cannot hold.
    try std.testing.expectEqual(@as(?u64, std.math.maxInt(u64)), huge.toolCeilingMs(std.testing.io));

    // An ordinary budget is still counted exactly rather than saturated: a
    // minute taken at the clock this test reads has its 60,000 milliseconds
    // left, less whatever the run between the two readings spent on the
    // assertion itself.
    const now = Io.Timestamp.now(std.testing.io, budget_clock).nanoseconds;
    const left = Budget.of(now, 60).remainingMs(std.testing.io).?;
    try std.testing.expect(left > 59_000 and left <= 60_000);
}

test "a Retry-After header sets the wait, and only a wait worth taking" {
    // The seconds form is a count, so the clock is not read for it; it is passed
    // anyway because the reader takes one reading for both forms.
    const now = net.nowSeconds(std.testing.io);
    const head =
        "HTTP/1.1 429 Too Many Requests\r\n" ++
        "content-type: application/json\r\n" ++
        "retry-after: 30\r\n" ++
        "content-length: 0\r\n\r\n";
    try std.testing.expectEqual(@as(?u64, 30_000), net.retryAfterMs(head, now));

    // The header's name is case-insensitive, and the value carries the spaces
    // a real server puts around it.
    const sloppy = "HTTP/1.1 503 Service Unavailable\r\nRetry-After:   7  \r\n\r\n";
    try std.testing.expectEqual(@as(?u64, 7000), net.retryAfterMs(sloppy, now));

    // A wait longer than this run will sit out falls back to the schedule
    // rather than stalling the turn for an hour.
    const forever = "HTTP/1.1 429 Too Many Requests\r\nretry-after: 3600\r\n\r\n";
    try std.testing.expectEqual(@as(?u64, net.max_retry_after_ms), net.retryAfterMs(forever, now));

    // Absent, and the forms this run cannot read, are all the backoff's
    // business rather than a guess.
    try std.testing.expectEqual(@as(?u64, null), net.retryAfterMs("HTTP/1.1 429 Too Many Requests\r\ncontent-length: 0\r\n\r\n", now));
    try std.testing.expectEqual(@as(?u64, null), net.retryAfterMs("HTTP/1.1 429 Too Many Requests\r\nretry-after: soon\r\n\r\n", now));

    // A count past what the multiply holds is still a count, so it is the
    // ceiling rather than an unreadable header: the run sits the ceiling out
    // rather than coming back on the 1 s backoff while the provider is still
    // refusing, and no wrap turns it into a short wait.
    try std.testing.expectEqual(@as(?u64, net.max_retry_after_ms), net.retryAfterMs("HTTP/1.1 429 Too Many Requests\r\nretry-after: 99999999999\r\n\r\n", now));
    // A count that is not a number a sender can mean at all, digits or not a
    // delay-seconds, is the one value the backoff's business.
    try std.testing.expectEqual(@as(?u64, null), net.retryAfterMs("HTTP/1.1 429 Too Many Requests\r\nretry-after: 99999999999999999999\r\n\r\n", now));
}

test "a Retry-After date becomes a wait, read against the clock it names" {
    // The value the header carries becomes a wait: a deadline thirty seconds
    // out is thirty seconds, and one the run read late is what is left of it.
    // The reading is taken once and handed to both, so the header and the
    // arithmetic are checked against one clock rather than two.
    const now = net.nowSeconds(std.testing.io);
    var head: [160]u8 = undefined;
    const thirty_ms = net.retryAfterMs(retryAfterDateHead(&head, now, 30), now).?;
    try std.testing.expect(thirty_ms >= 29_000 and thirty_ms <= 30_000);

    // A deadline already past is a wait of zero rather than the backoff
    // schedule: the wait it names has elapsed, and adding to it is how a run
    // comes back early and is refused again.
    try std.testing.expectEqual(@as(?u64, 0), net.retryAfterMs(retryAfterDateHead(&head, now, -5), now));

    // A deadline further out than this run will sit out is the ceiling, on
    // either form.
    try std.testing.expectEqual(@as(?u64, net.max_retry_after_ms), net.retryAfterMs(retryAfterDateHead(&head, now, 3600), now));
}

// The parser reading a past date as zero is right: the wait it names has
// elapsed. Spending that zero as the run's wait is not, and the two are read
// apart here. The date form is what a CDN or gateway computes against its own
// clock sends, so a run whose clock runs a minute ahead of the provider's reads
// every one of those headers as a deadline already past, and a run that took
// the zero sent all three attempts within milliseconds of each other: three
// billable refusals from a provider that had asked for a pause, and the backoff
// that exists for exactly that never ran.
test "a Retry-After that names no wait falls back to the backoff, not to zero" {
    const now = net.nowSeconds(std.testing.io);
    var head: [160]u8 = undefined;

    // A real wait is the provider's, taken whole: the header wins over the
    // schedule because the schedule is 1 s and 2 s and a provider asking for
    // thirty is still refusing at second two.
    try std.testing.expectEqual(@as(u64, 30_000), retryWaitMs(retryAfterDateHead(&head, now, 30), now, 1));
    try std.testing.expectEqual(
        @as(u64, 30_000),
        retryWaitMs("HTTP/1.1 429 Too Many Requests\r\nretry-after: 30\r\n\r\n", now, 1),
    );

    // A date the run's clock has already passed, and a literal zero, both name
    // no wait at all. Each is the schedule for the attempt, which is what the
    // three attempts between a first refusal and a fourth would be without a
    // header saying otherwise.
    for ([_]i64{ -5, -1, 0 }) |past| {
        try std.testing.expectEqual(
            net.retryBackoffMs(1, max_backoff_ms),
            retryWaitMs(retryAfterDateHead(&head, now, past), now, 1),
        );
    }
    try std.testing.expectEqual(
        net.retryBackoffMs(1, max_backoff_ms),
        retryWaitMs("HTTP/1.1 429 Too Many Requests\r\nretry-after: 0\r\n\r\n", now, 1),
    );

    // The schedule moves with the attempt, so the fallback is a backoff rather
    // than a constant that happens to be nonzero.
    try std.testing.expectEqual(@as(u64, 1000), retryWaitMs("HTTP/1.1 429 Too Many Requests\r\nretry-after: 0\r\n\r\n", now, 1));
    try std.testing.expectEqual(@as(u64, 2000), retryWaitMs("HTTP/1.1 429 Too Many Requests\r\nretry-after: 0\r\n\r\n", now, 2));

    // No header is the same case as a header naming nothing.
    try std.testing.expectEqual(
        net.retryBackoffMs(2, max_backoff_ms),
        retryWaitMs("HTTP/1.1 429 Too Many Requests\r\ncontent-length: 0\r\n\r\n", now, 2),
    );
}

/// A 429 head whose `Retry-After` is an IMF-fixdate naming an instant
/// `seconds` after `now`, written into `buf` by the caller. The calendar fields
/// come from the epoch arithmetic in the standard library, so the header the
/// test builds is one the parser has to agree with rather than one spelled the
/// same way twice.
fn retryAfterDateHead(buf: []u8, now: i64, seconds: i64) []const u8 {
    const target = now + seconds;
    const seconds_in = std.time.epoch.EpochSeconds{ .secs = @intCast(target) };
    const day = seconds_in.getEpochDay().calculateYearDay();
    const month_day = day.calculateMonthDay();
    const rest: u32 = @intCast(@mod(target, std.time.epoch.secs_per_day));
    const clock = std.time.epoch.DaySeconds{ .secs = @intCast(rest) };
    return std.fmt.bufPrint(buf, "HTTP/1.1 429 Too Many Requests\r\nretry-after: Thu, {d:0>2} {s} {d} {d:0>2}:{d:0>2}:{d:0>2} GMT\r\n\r\n", .{
        @as(u32, month_day.day_index) + 1,
        net.calendar_months[month_day.month.numeric() - 1],
        day.year,
        clock.getHoursIntoDay(),
        clock.getMinutesIntoHour(),
        clock.getSecondsIntoMinute(),
    }) catch unreachable;
}

// The run's ceiling is a promise about wall time, and the clock it is measured
// on is the one that keeps running while the machine is away. `.awake` stops
// for a suspend, so on a laptop closed for the night the whole budget is still
// in hand at the resume and the spend it exists to cap is the spend after it.
// `.boot` is that clock plus the suspend, which is why it reads ahead of
// `.awake` and never behind it, and why it is still the answer rather than the
// wall clock: a clock an NTP step can move is not a ceiling.
test "the budget is measured on a clock that keeps counting through a suspend" {
    const io = std.testing.io;
    const awake = Io.Timestamp.now(io, .awake).nanoseconds;
    const boot = Io.Timestamp.now(io, budget_clock).nanoseconds;
    try std.testing.expect(boot >= awake);

    // A deadline stamped on the run's clock and read on it is a deadline; the
    // same two operations on the wall clock are not, and this is the shape
    // every `Budget` in the run is built from.
    const budget = Budget.of(Io.Timestamp.now(io, budget_clock).nanoseconds, 60);
    try std.testing.expect(!budget.expired(io));
    try std.testing.expect(budget.remainingMs(io).? <= 60_000);
}

// The budget and the record want opposite answers from a suspend, so they are
// read on different clocks and the two are not interchangeable. The budget
// counts the time the machine spent off; the model's time does not, because a
// machine that was asleep was not generating, and `elapsed_ms` is what a
// monitor divides a turn's tokens by. Measured on the budget's clock, a lid
// closed for eight hours mid-response is written as `elapsed_ms: 28800000`,
// which reports a model that generated four tokens an hour.
test "a response's model time is measured on the clock that stops for a suspend" {
    const io = std.testing.io;
    // The two clocks are distinct, which is the whole point: `.boot` counts
    // what `.awake` does not, so picking the wrong one is visible here.
    try std.testing.expect(model_clock != budget_clock);
    try std.testing.expectEqual(Io.Clock.awake, model_clock);

    // The shape `runTurn` uses, and it is a duration rather than the gap
    // between two origins: both readings are on `model_clock`, and a stamp
    // taken there answers a positive span bounded by the wall time the test
    // itself spent.
    const asked = Io.Timestamp.now(io, model_clock).nanoseconds;
    io.sleep(.{ .nanoseconds = 20 * std.time.ns_per_ms }, .awake) catch |err| {
        std.debug.print("\nno sleep on this host: {t}\n", .{err});
        return err;
    };
    const took = session_mod.elapsedMs(io, model_clock, asked);
    try std.testing.expect(took >= 20);
    try std.testing.expect(took < 60_000);
}

// The budget is a deadline, not a turn counter. Checked only at the top of the
// loop, a provider that is slow rather than broken hands the run one long turn
// and the budget is never asked again, which is the run being killed in the
// middle of the turn the budget exists to avoid.
test "the time budget is a deadline the turn itself is held to" {
    const io = std.testing.io;
    const now = Io.Timestamp.now(io, budget_clock).nanoseconds;

    // No budget set is a budget that never runs out, at any point in a turn.
    const none = Budget.of(now, null);
    try std.testing.expect(!none.expired(io));

    const short = Budget.of(now, 1);
    try std.testing.expect(!short.expired(io));

    // A deadline already in the past is spent, wherever it is read.
    const spent = Budget.of(now, 0);
    try std.testing.expect(spent.expired(io));
    const long_gone = Budget.of(now - std.time.ns_per_s * 10, 1);
    try std.testing.expect(long_gone.expired(io));

    // The final push is the one turn allowed past the budget, and the grace is
    // what keeps that turn bounded too: the grace moves the deadline later, so
    // the push is not already over before it starts.
    const push = short.withGraceNs(final_push_grace_s);
    try std.testing.expect(!push.expired(io));
    const push_later = spent.withGraceNs(final_push_grace_s);
    try std.testing.expect(!push_later.expired(io));
    // Grace on a run with no budget is still no budget.
    try std.testing.expect(!none.withGraceNs(final_push_grace_s).expired(io));
}

// The provider stream is the largest untrusted input the binary parses: every
// byte of it arrives over the network, and every visible part of it is copied
// straight into the next request body. `std.testing.fuzz` runs this corpus
// through the harness on every `zig build test`, and through the fuzzer's
// mutations when the test binary is built in fuzz mode. Real OpenRouter and
// DeepSeek frames, a usage-only trailer, the terminator, and the shapes that
// break a line-oriented reader: a frame with no newline, CRLF, a payload that
// is not JSON, a `data:` line with nothing after it.
const stream_corpus = [_][]const u8{
    "",
    "\n",
    "\r\n",
    "data:\n",
    "data: [DONE]\n",
    "data: [DONE]",
    ": ping\n",
    "event: message\ndata: {}\n",
    "data: {\"choices\":[{\"delta\":{\"content\":\"Hello\"}}]}\n",
    "data: {\"choices\":[{\"delta\":{\"content\":\" wor\"}}]}\r\ndata: {\"choices\":[{\"delta\":{\"content\":\"ld\"}}]}\n",
    "data: {\"choices\":[{\"delta\":{\"content\":\"a\\u0000b\\u001fc\\\"d\\\\e\"}}]}\n",
    "data: {\"choices\":[{\"delta\":{\"content\":\"\\u00e9\\u65e5\\ud83d\\ude80\"}}]}\n",
    "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_1\",\"function\":{\"name\":\"bash\",\"arguments\":\"{\\\"comm\"}}]}}]}\n",
    "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"and\\\":\\\"ls\\\"}\"}}]}}]}\ndata: [DONE]\n",
    "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_1\",\"function\":{\"name\":\"read\",\"arguments\":\"{\\\"path\\\":\\\"a\\\"}\"}},{\"index\":63,\"function\":{\"name\":\"git\"}}]}}]}\n",
    "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":64,\"function\":{\"name\":\"bash\"}}]}}]}\n",
    "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":-1},{\"index\":1e30},{\"index\":\"0\"},{\"index\":null},\"x\",[],{}]}}]}\n",
    "data: {\"usage\":{\"prompt_tokens\":12,\"completion_tokens\":3,\"total_tokens\":15,\"completion_tokens_details\":{\"reasoning_tokens\":2},\"prompt_tokens_details\":{\"cached_tokens\":9}}}\n",
    "data: {\"usage\":{\"prompt_tokens\":1e30,\"prompt_cache_hit_tokens\":7,\"cache_read_input_tokens\":8}}\n",
    "data: {\"usage\":\"nope\",\"choices\":[]}\n",
    "data: {\"choices\":[{\"delta\":{\"content\":123}},{\"delta\":\"x\"},null,5]}\n",
    "data: {\"choices\":[{\"delta\":{\"content\":\"unterminated}}\n",
    "data: {}\ndata: [DONE]\n",
};

test "a fuzzed provider stream always leaves a request body the body writer can carry" {
    try std.testing.fuzz({}, fuzzStream, .{ .corpus = &stream_corpus });
}

fn fuzzStream(_: void, smith: *std.testing.Smith) !void {
    const gpa = std.testing.allocator;
    var scratch: [8 * 1024]u8 = undefined;
    const stream: []const u8 = if (smith.in) |seed| seed else scratch[0..smith.slice(&scratch)];

    var sink = stream_mod.FrameSink.init(gpa);
    defer sink.deinit();

    // The line loop from `streamChat`, so the harness splits and trims frames
    // the way the reader does rather than a second, more forgiving way.
    var lines = std.mem.splitScalar(u8, stream, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (!std.mem.startsWith(u8, line, "data:")) continue;
        const frame = std.mem.trim(u8, line[5..], " ");
        if (frame.len == 0) continue;
        if (std.mem.eql(u8, frame, "[DONE]")) break;
        try sink.feed(frame);
    }

    // A provider-chosen index sizes the call list, so the list stays inside
    // the cap no matter how many frames claim a slot.
    try std.testing.expect(sink.calls.items.len <= stream_mod.max_tool_calls);
    for (sink.calls.items) |call| try std.testing.expect(call.args.items.len <= stream.len * 2 + 64);

    // Everything the frames produced goes back out as a request body, so the
    // turn has to survive the round trip: a byte the escaping does not cover
    // is a request the provider rejects, and a lost code point is a reply the
    // user never asked for.
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var msgs: std.ArrayList(u8) = .empty;
    defer msgs.deinit(gpa);
    try conversation_mod.openConversation(gpa, &msgs, conversation_mod.system_prompt, "fix the bug");
    try msgs.appendSlice(gpa, ",");
    try msgs.appendSlice(gpa, try assistantMessage(arena, &sink.result));
    for (sink.calls.items) |call| {
        var tool_msg = chat_mod.JsonBuf.init(arena);
        try msgs.appendSlice(gpa, ",{\"role\":\"tool\",\"tool_call_id\":");
        try chat_mod.writeJsonString(tool_msg.writer(), call.id);
        try tool_msg.writer().writeAll(",\"content\":");
        try chat_mod.writeJsonString(tool_msg.writer(), "ok");
        try tool_msg.writer().writeAll("}");
        try msgs.appendSlice(gpa, tool_msg.items());
    }
    // `buildBody` closes the `messages` array, and the run opens it through
    // `openConversation`, so what it is given is the array, brackets and all.
    const body = try buildBody(arena, .{}, msgs.items);
    try std.testing.expect(try std.json.validate(gpa, body));
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

    // A wrapper that populates the environment from a file leaves the newline
    // that file ended with, and each option fails differently on it: an api
    // key becomes a header carrying a byte a header may not hold, a base url
    // stops parsing and the run claims the key would go out in the clear.
    try env.put("MICROAGENT_MODEL", " gpt-5\n");
    try std.testing.expectEqualStrings("gpt-5", envValue(&env, "MICROAGENT_MODEL").?);
    try env.put("MICROAGENT_BASE_URL", "\thttps://example.test/v1\r\n");
    try std.testing.expectEqualStrings("https://example.test/v1", envValue(&env, "MICROAGENT_BASE_URL").?);

    // Whitespace alone is the empty case, not a value.
    try env.put("MICROAGENT_MODEL", " \t\r\n");
    try std.testing.expect(envValue(&env, "MICROAGENT_MODEL") == null);
}

// The help says a flag wins over the environment variable for the same option,
// and a variable the run cannot use is a value the run is not going to use once
// the flag has been read. Reporting it where it was read made
// `MICROAGENT_MAX_TURNS=0 microagent --max-turns 5` a usage error, which is the
// same mistake the early `--help` scan already refuses to make: a variable this
// machine cannot use takes away the one command line that says what it would
// have been. The base url has always been checked after `parseArgs` for this
// reason, and these values now follow it.
test "a flag for the same option wins over a variable the run could not use" {
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    var opts: Options = .{};
    var problem: ?EnvProblem = null;
    var buf: [512]u8 = undefined;

    try env.put("MICROAGENT_MAX_TURNS", "0");
    try env.put("MICROAGENT_REASONING_EFFORT", "soon");
    try env.put("MICROAGENT_MAX_TOKENS", "4096");
    ceilingFromEnv(usize, &env, "MICROAGENT_MAX_TURNS", .max_turns, &opts.max_turns, &problem);
    reasoningEffortFromEnv(&env, "MICROAGENT_REASONING_EFFORT", &opts.reasoning_effort, &problem);
    ceilingFromEnv(u32, &env, "MICROAGENT_MAX_TOKENS", .max_tokens, &opts.max_tokens, &problem);

    // The first problem is the run's to report and the later one does not
    // overwrite it, and a variable the run could use is read as it always was:
    // refusing one value stops nothing else being configured.
    try std.testing.expectEqualStrings("MICROAGENT_MAX_TURNS", problem.?.name);
    try std.testing.expectEqual(ValuedOption.max_turns, problem.?.option);
    try std.testing.expectEqualStrings("MICROAGENT_MAX_TURNS must be at least 1", envProblemMessage(&buf, problem.?));
    try std.testing.expectEqual(max_turns_default, opts.max_turns);
    try std.testing.expectEqual(@as(u32, 4096), opts.max_tokens);
    try std.testing.expect(opts.reasoning_effort == null);
    try std.testing.expect(!opts.from_flag.contains(.max_turns));

    // The flag wins, and it is recorded as having won: that is the fact
    // `reportEnvProblem` asks about, and nothing else in the run can say it.
    try std.testing.expectEqual(@as(?[]const u8, null), parseArgs(&buf, &.{ "--max-turns", "5" }, &opts));
    try std.testing.expectEqual(@as(usize, 5), opts.max_turns);
    try std.testing.expect(opts.from_flag.contains(.max_turns));
    // A flag for a different option says nothing about this one.
    try std.testing.expect(!opts.from_flag.contains(.max_tokens));

    // The message is spelled from the value as the environment wrote it, so a
    // wrapper's trailing newline is not part of what the operator is shown.
    try env.put("MICROAGENT_MAX_TOKENS", "soon\n");
    var second: ?EnvProblem = null;
    var tokens: u32 = default_max_tokens;
    ceilingFromEnv(u32, &env, "MICROAGENT_MAX_TOKENS", .max_tokens, &tokens, &second);
    try std.testing.expectEqualStrings("MICROAGENT_MAX_TOKENS must be a number, got 'soon'", envProblemMessage(&buf, second.?));

    // Every ceiling a variable can name is reachable through this path, and
    // each is the option its flag sets, so no one of them reports a value the
    // run then overrode.
    for ([_]struct { name: []const u8, option: ValuedOption, flag: []const u8, value: []const u8 }{
        .{ .name = "MICROAGENT_MAX_TURNS", .option = .max_turns, .flag = "--max-turns", .value = "0" },
        .{ .name = "MICROAGENT_MAX_TOKENS", .option = .max_tokens, .flag = "--max-tokens", .value = "0" },
        .{ .name = "MICROAGENT_STALL_TIMEOUT", .option = .stall_timeout, .flag = "--stall-timeout", .value = "0" },
        .{ .name = "MICROAGENT_BUDGET_SECONDS", .option = .budget, .flag = "--budget", .value = "0" },
        .{ .name = "MICROAGENT_MAX_SPEND_TOKENS", .option = .max_spend_tokens, .flag = "--max-spend-tokens", .value = "0" },
    }) |one| {
        var each: std.process.Environ.Map = .init(std.testing.allocator);
        defer each.deinit();
        try each.put(one.name, one.value);
        var option: Options = .{};
        var found: ?EnvProblem = null;
        switch (one.option) {
            .max_turns => ceilingFromEnv(usize, &each, one.name, one.option, &option.max_turns, &found),
            .max_tokens => ceilingFromEnv(u32, &each, one.name, one.option, &option.max_tokens, &found),
            .stall_timeout => ceilingFromEnv(u32, &each, one.name, one.option, &option.stall_timeout_s, &found),
            .budget => optionalCeilingFromEnv(&each, one.name, one.option, &option.budget_s, &found),
            .max_spend_tokens => optionalCeilingFromEnv(&each, one.name, one.option, &option.max_spend_tokens, &found),
            else => unreachable,
        }
        try std.testing.expect(found != null);
        try std.testing.expectEqual(one.option, found.?.option);
        const flag_args = [_][]const u8{ one.flag, "1" };
        try std.testing.expectEqual(@as(?[]const u8, null), parseArgs(&buf, &flag_args, &option));
        try std.testing.expect(option.from_flag.contains(one.option));
    }
}

test "a config path in a diagnostic is spelled whole rather than cut" {
    // The line naming the file a run could not read is the one a reader has to
    // go and fix, and the trace below already spells this same path whole for
    // the same reason. Cut at `quoted_value_bytes` a path ends mid-directory
    // naming one that is not there, which is worse than no path at all: the
    // reader goes looking for a file that does not exist.
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const arena = state.allocator();

    const long = try std.fmt.allocPrint(arena, "{s}config.toml", .{"/opt/microagent/config/" ** 10});
    try std.testing.expect(long.len > net.quoted_value_bytes);
    try std.testing.expectEqualStrings(long, configPathText(arena, .{ .path = long, .named = true }));

    // It is the escaping that is kept, not the length: a path is bytes a
    // directory name or a reviewed repository's config file can carry, and one
    // holding a control character still reaches the terminal as text.
    try std.testing.expectEqualStrings(
        "/home/me/.microagent/config.toml",
        configPathText(arena, .{ .path = "/home/me/.microagent/config.toml", .named = true }),
    );
    try std.testing.expectEqualStrings(
        "/home/me\\x1b[2J",
        configPathText(arena, .{ .path = "/home/me\x1b[2J", .named = true }),
    );
    try std.testing.expectEqualStrings("", configPathText(arena, .{ .path = null, .named = false }));
}

test "a config that cannot be read is reported, a missing one is not" {
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

test "the config path follows flag, then variable, then home" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();

    // A flag names the file outright, and it wins over the variable below it.
    try env.put("MICROAGENT_CONFIG", "/from/env.toml");
    try env.put("HOME", "/home/one");
    try std.testing.expectEqualStrings("/from/flag.toml", configSource(&env, arena, "/from/flag.toml").path.?);
    try std.testing.expect(configSource(&env, arena, "/from/flag.toml").named);

    // The variable is next, and the flag does not name one when it is absent.
    try std.testing.expectEqualStrings("/from/env.toml", configSource(&env, arena, "").path.?);
    try std.testing.expect(configSource(&env, arena, "").named);

    // An empty variable is the documented way to turn the file off, and the
    // home below it must not answer it.
    try env.put("MICROAGENT_CONFIG", "");
    try std.testing.expect(configSource(&env, arena, "").path == null);

    // A path exported from a file carries that file's newline, and a path with
    // one is a file nothing holds: the run would report on a config the caller
    // never wrote and fall back to the built-in levels.
    try env.put("MICROAGENT_CONFIG", "/from/env.toml\n");
    try std.testing.expectEqualStrings("/from/env.toml", configSource(&env, arena, "").path.?);

    // Whitespace alone is the empty case: the file is off, as it is for "".
    try env.put("MICROAGENT_CONFIG", "  \n");
    try std.testing.expect(configSource(&env, arena, "").path == null);

    // With neither, the home is where the file is looked for, and it is not
    // something the caller named, so its absence stays quiet.
    var home_only: std.process.Environ.Map = .init(std.testing.allocator);
    defer home_only.deinit();
    try home_only.put("HOME", "/home/one");
    const home = configSource(&home_only, arena, "");
    try std.testing.expect(std.mem.endsWith(u8, home.path.?, "/home/one/.microagent/config.toml"));
    try std.testing.expect(!home.named);

    // No home at all is no file.
    var bare: std.process.Environ.Map = .init(std.testing.allocator);
    defer bare.deinit();
    try std.testing.expect(configSource(&bare, arena, "").path == null);

    // A home exported from a file carries that file's newline, and a directory
    // with one is a directory nothing holds: the config is never found, and its
    // absence from the default path is not a fault worth reporting, so the run
    // is on the built-in levels with nothing said.
    try home_only.put("HOME", "/home/one\n");
    const wrapped = configSource(&home_only, arena, "");
    try std.testing.expect(std.mem.endsWith(u8, wrapped.path.?, "/home/one/.microagent/config.toml"));

    // An empty home is no home, not a root-relative directory.
    try home_only.put("HOME", "");
    try std.testing.expect(configSource(&home_only, arena, "").path == null);
}

test "a config path written with a leading tilde is read from the home directory" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    try env.put("HOME", "/home/one");

    // A shell expands the tilde in `--config ~/x.toml` before the flag is
    // read, but nothing expands it in a value that came out of a variable or a
    // wrapper's environment file, and the help text prints the tilde spelling.
    try env.put("MICROAGENT_CONFIG", "~/.microagent/other.toml");
    try std.testing.expectEqualStrings("/home/one/.microagent/other.toml", configSource(&env, arena, "").path.?);
    try std.testing.expectEqualStrings("/home/one/from/flag.toml", configSource(&env, arena, "~/from/flag.toml").path.?);
}

// The first run that finds nothing at the default config path gets the
// repository's commented template, and an installed binary has no checkout to
// read it from: the bytes are embedded at build time, so these two assertions
// are the only thing that would notice the shipped template drifting from the
// file the config tests apply.
test "the first run writes the tracked template where the config is looked for" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const tracked = try std.Io.Dir.cwd().readFileAlloc(io, config_template_path, gpa, .limited(max_config_bytes));
    defer gpa.free(tracked);
    try std.testing.expectEqualStrings(tracked, config_template);

    var state = std.heap.ArenaAllocator.init(gpa);
    defer state.deinit();
    const arena = state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", arena);
    const path = try std.fs.path.join(arena, &.{ dir, "home", ".microagent", "config.toml" });
    const source: ConfigSource = .{ .path = path, .named = false };

    writeDefaultConfig(io, arena, source);

    // The directory did not exist and was made for it, 0700 like the rest of
    // the home state, and the file is the template at 0600.
    try std.testing.expectEqualStrings(config_template, try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_config_bytes)));
    const stat = try tmp.dir.statFile(io, "home/.microagent/config.toml", .{});
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), stat.permissions.toMode() & tool_mod.permission_bits);

    // A file that is there is the operator's. The second call leaves it as it
    // stands rather than restoring the template over an edit.
    const file = try std.Io.Dir.createFileAbsolute(io, path, .{ .truncate = true });
    try file.writeStreamingAll(io, "model = \"mine\"\n");
    file.close(io);
    writeDefaultConfig(io, arena, source);
    try std.testing.expectEqualStrings("model = \"mine\"\n", try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_config_bytes)));

    // A path this process cannot write to costs the run nothing: the template
    // is a convenience, and the run is on the same defaults without it. A file
    // where the directory would go is one way the create fails, and the file
    // that was in its way is left as the operator left it, empty.
    try tmp.dir.writeFile(io, .{ .sub_path = "blocked", .data = "" });
    writeDefaultConfig(io, arena, .{ .path = try std.fs.path.join(arena, &.{ dir, "blocked", "config.toml" }), .named = false });
    try std.testing.expectError(error.NotDir, std.Io.Dir.cwd().statFile(io, try std.fs.path.join(arena, &.{ dir, "blocked", "config.toml" }), .{}));
    // The file that was in the way is the one the run leaves as it stands, and
    // the config written above it is the one it does not touch.
    try std.testing.expectEqualStrings("", try tmp.dir.readFileAlloc(io, "blocked", arena, .limited(max_config_bytes)));
    try std.testing.expectEqualStrings("model = \"mine\"\n", try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_config_bytes)));
}

/// The template the release embeds and writes on a first run.
const config_template_path = "config.example.toml";

// The threaded io, the temporary directory and the arena the three atomic
// write tests below share: what varies between them is the tree they put in
// the directory and what they then write over.
const WriteFixture = struct {
    arena_state: std.heap.ArenaAllocator,
    threaded: std.Io.Threaded,
    tmp: std.testing.TmpDir,

    fn init() WriteFixture {
        return .{
            .arena_state = std.heap.ArenaAllocator.init(std.testing.allocator),
            .threaded = std.Io.Threaded.init(std.testing.allocator, .{}),
            .tmp = std.testing.tmpDir(.{}),
        };
    }

    fn deinit(self: *WriteFixture) void {
        self.tmp.cleanup();
        self.threaded.deinit();
        self.arena_state.deinit();
    }

    fn io(self: *WriteFixture) Io {
        return self.threaded.io();
    }

    fn arena(self: *WriteFixture) std.mem.Allocator {
        return self.arena_state.allocator();
    }
};

// The rename that puts a rewritten file in place brings the temporary file's
// mode with it, so a 0o600 file the run never asked to change comes back 0o644
// and a secret the repository kept private becomes readable by everyone on the
// machine.
test "an atomic write keeps the mode the destination already had" {
    var f = WriteFixture.init();
    defer f.deinit();
    const io = f.io();
    const arena = f.arena();

    try f.tmp.dir.writeFile(io, .{ .sub_path = "secret", .data = "old" });
    try f.tmp.dir.setFilePermissions(io, "secret", Io.File.Permissions.fromMode(0o600), .{});
    try tool_mod.writeFileAtomic(io, f.tmp.dir, "secret", "new");

    try std.testing.expectEqualStrings("new", try f.tmp.dir.readFileAlloc(io, "secret", arena, .limited(64)));
    const stat = try f.tmp.dir.statFile(io, "secret", .{});
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), stat.permissions.toMode() & tool_mod.permission_bits);

    // A file that is not there yet is created with the default mode, so the
    // helper does not need a caller to say what a new file should be.
    try tool_mod.writeFileAtomic(io, f.tmp.dir, "fresh", "content");
    try std.testing.expectEqualStrings("content", try f.tmp.dir.readFileAlloc(io, "fresh", arena, .limited(64)));
}

// The mode the destination had is carried onto the file the run wrote, and the
// setuid, setgid and sticky bits are not part of what is carried. A rewrite
// over a setuid helper would otherwise leave a setuid file holding whatever
// text the model supplied, which the umask cannot prevent and no reader of the
// tree would notice.
test "an atomic write does not carry the setuid, setgid or sticky bit over" {
    var f = WriteFixture.init();
    defer f.deinit();
    const io = f.io();

    // The three bits a mode can hold beyond the nine, one file each so a write
    // that cleared one of them is not masked by another.
    const carried = [_]struct { name: []const u8, mode: std.posix.mode_t }{
        .{ .name = "setuid", .mode = 0o4755 },
        .{ .name = "setgid", .mode = 0o2755 },
        .{ .name = "sticky", .mode = 0o1755 },
    };
    for (carried) |entry| {
        try f.tmp.dir.writeFile(io, .{ .sub_path = entry.name, .data = "old" });
        try f.tmp.dir.setFilePermissions(io, entry.name, Io.File.Permissions.fromMode(entry.mode), .{});

        try tool_mod.writeFileAtomic(io, f.tmp.dir, entry.name, "new");

        const stat = try f.tmp.dir.statFile(io, entry.name, .{});
        const mode = stat.permissions.toMode();
        // The nine `rwx` bits came across unchanged, so the write still leaves a
        // 0o755 file a 0o755 file and this is not a change to what a rewrite
        // preserves.
        try std.testing.expectEqual(@as(std.posix.mode_t, 0o755), mode & tool_mod.permission_bits);
        // And the bit this is about is gone: the file the run wrote is not
        // executable as whoever owns it. The type bits are not part of the
        // comparison, because a stat reads them back above the permission bits
        // and `S_IFMT` is the mask a type is compared with rather than one that
        // clears it.
        try std.testing.expectEqual(@as(std.posix.mode_t, 0o100000), mode & posix_mode_type_mask);
        try std.testing.expectEqual(@as(std.posix.mode_t, 0), mode & special_mode_bits);
    }
}

/// The three bits a mode carries above the nine: setuid, setgid and sticky.
const special_mode_bits: std.posix.mode_t = 0o7000;
/// The file type, as a stat reports it beside the permission bits.
const posix_mode_type_mask: std.posix.mode_t = 0o170000;

// A rename replaces the name it is given, so writing over a symlink without
// following it leaves a regular file where the link was and the file the link
// named exactly as it was.
test "an atomic write follows a symlink to the file it names" {
    var f = WriteFixture.init();
    defer f.deinit();
    const io = f.io();
    const arena = f.arena();

    try f.tmp.dir.writeFile(io, .{ .sub_path = "real", .data = "old" });
    try f.tmp.dir.symLink(io, "real", "link", .{});
    try tool_mod.writeFileAtomic(io, f.tmp.dir, "link", "new");

    try std.testing.expectEqualStrings("new", try f.tmp.dir.readFileAlloc(io, "real", arena, .limited(64)));
    // The link is still a link: a run that resolves paths from the repository
    // has not gained a second copy of every file it wrote through one.
    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try f.tmp.dir.readLink(io, "link", &link_buf);
    try std.testing.expectEqualStrings("real", link_buf[0..n]);
}

// A `write` is the one tool call a duplicate is naturally safe on, because it
// sets a file to a fixed value rather than changing it by an amount, and that is
// a property of the call rather than of the caller, so it is worth holding in
// place: a turn cut before its result reached the model, a re-read to check
// the change landed, a frame a reconnecting relay replayed, and a wrapper that
// re-runs the task all hand the same tool the same arguments a second time.
// `toolEdit` has its own test for this, and this is the other half: the same
// run twice leaves the file, the link and the mode the first run left, rather
// than a second pass over a file the first pass already rewrote.
test "a write issued twice leaves the file the first run left" {
    var f = WriteFixture.init();
    defer f.deinit();
    const io = f.io();
    const arena = f.arena();

    try f.tmp.dir.writeFile(io, .{ .sub_path = "real", .data = "old" });
    try f.tmp.dir.setFilePermissions(io, "real", Io.File.Permissions.fromMode(0o600), .{});
    try f.tmp.dir.symLink(io, "real", "link", .{});

    try tool_mod.writeFileAtomic(io, f.tmp.dir, "link", "new");
    try tool_mod.writeFileAtomic(io, f.tmp.dir, "link", "new");

    try std.testing.expectEqualStrings("new", try f.tmp.dir.readFileAlloc(io, "real", arena, .limited(64)));
    // The link survives the duplicate: a second run that replaced the name
    // rather than the file it names leaves a regular file where the link was,
    // so a repository holding links grows one copy per run.
    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try f.tmp.dir.readLink(io, "link", &link_buf);
    try std.testing.expectEqualStrings("real", link_buf[0..n]);
    // The mode is read after the second run, because the rename brings the
    // temporary file's mode with it and the duplicate is the run that would
    // hand a 0o600 file back as whatever the second one created.
    const stat = try f.tmp.dir.statFile(io, "real", .{});
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), stat.permissions.toMode() & tool_mod.permission_bits);
}

// Where the key comes from is decided before the first turn: a `--api-key`
// beats the variable, the variable beats the config file, and a value that is
// set to nothing is not a key at all. No key file is read: the one that used to
// be was named after a provider this binary no longer picks.
test "the key is the flag, then the variable, then the config file" {
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();

    // A flag is a key and is not looked past, whatever the environment or the
    // file says.
    try env.put(key_var, "from-var");
    {
        const k = resolveKey(&env, "from-flag", "from-config");
        try std.testing.expectEqualStrings("from-flag", k.value);
        try std.testing.expectEqualStrings("--api-key", k.source);
    }
    {
        const k = resolveKey(&env, "", "from-config");
        try std.testing.expectEqualStrings("from-var", k.value);
        try std.testing.expectEqualStrings(key_var, k.source);
    }
    {
        const k = resolveKey(&env, "", "");
        try std.testing.expectEqualStrings("from-var", k.value);
    }

    // The variable of another provider is not a key for this program.
    _ = env.swapRemove(key_var);
    try env.put("OPENAI_API_KEY", "not-read");
    {
        const k = resolveKey(&env, "", "from-config");
        try std.testing.expectEqualStrings("from-config", k.value);
        try std.testing.expectEqualStrings("config file", k.source);
    }
    _ = env.swapRemove("OPENAI_API_KEY");

    // A variable set to nothing is not a key, so the file answers.
    try env.put(key_var, "");
    {
        const k = resolveKey(&env, "", "from-config");
        try std.testing.expectEqualStrings("from-config", k.value);
    }
    _ = env.swapRemove(key_var);

    // No variable and no file entry: no key, said so by the source rather than
    // by a path that was never tried.
    {
        const k = resolveKey(&env, "", "");
        try std.testing.expectEqualStrings("", k.value);
        try std.testing.expectEqualStrings("none", k.source);
    }
}

// The credentials are in this process's environment, and a tool result is
// re-sent to the provider on every later turn of a run. So a subprocess that
// inherited one turned `bash: printenv` into the key, on the wire, for the rest
// of the run. The scrub happens once, before the first turn, and everything
// else the caller's shell exported still reaches the tools.
test "the tool environment is this one less the credentials" {
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    try env.put("PATH", "/usr/bin");
    try env.put("HOME", "/home/agent");
    try env.put("CI", "1");
    try env.put(key_var, "sk-live-not-a-real-key");
    // The token `microagent update` authenticates with is a credential of the
    // same shape, so the scrub that keeps the provider key out of a tool's
    // environment keeps this out of it too.
    try env.put("GITHUB_TOKEN", "ghp_not-a-real-token");

    scrubSecrets(&env, &.{});
    const scrubbed = &env;

    for (secret_env_vars) |name| {
        try std.testing.expectEqual(@as(?[]const u8, null), scrubbed.get(name));
    }
    // The rest is inherited, because a build that needs PATH or a CI variable
    // set in the caller's shell has to keep working.
    try std.testing.expectEqualStrings("/usr/bin", scrubbed.get("PATH").?);
    try std.testing.expectEqualStrings("/home/agent", scrubbed.get("HOME").?);
    try std.testing.expectEqualStrings("1", scrubbed.get("CI").?);

    // A name that only reads like a key is not a key variable and stays.
    var with_lookalike: std.process.Environ.Map = .init(std.testing.allocator);
    defer with_lookalike.deinit();
    try with_lookalike.put("MY_API_KEY", "not-a-provider-key");
    scrubSecrets(&with_lookalike, &.{});
    try std.testing.expectEqualStrings("not-a-provider-key", with_lookalike.get("MY_API_KEY").?);
}

// The Harbor adapter (`integrations/harbor/microagent_agent.py`) reads the
// host's environment and hands this binary a subset of it, so it duplicates
// the configuration this file owns: the provider key variable, the
// reasoning levels, the endpoint it passes as MICROAGENT_BASE_URL, the grace
// the budget is derived against, and the exit code a stopped run leaves. A
// duplicate is fine; a silent divergence is not, and nothing else in the tree
// would notice one: the adapter is Python, it never imports this file, and the
// values it disagrees about are the ones a run is scored on. The adapter also
// supplies the base url the binary no longer defaults: a run it starts always
// names an endpoint this way. The adapter's values are read from its source
// here, against the constants themselves rather than against a second copy of
// them.
test "the harbor adapter mirrors this binary's configuration schema" {
    const gpa = std.testing.allocator;
    // The test runs with the build root as its working directory, which is
    // where the adapter is tracked.
    const adapter = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, harbor_adapter_path, gpa, .limited(max_harbor_adapter_bytes));
    defer gpa.free(adapter);

    // The one key variable the adapter reads, and the reasoning levels in the
    // order they are named. Each name has to appear after the last one before
    // it, so a reordering is caught and not just a rename.
    try expectSpelled(adapter, "trimmed_env(\"" ++ key_var ++ "\")");
    try expectNamesInOrder(adapter, "REASONING_EFFORTS = (", &reasoning_efforts);

    // The scalars the adapter spells as its own constant, and the one variable
    // it sets so the base url this binary no longer defaults is always named.
    try expectSpelled(adapter, "\"" ++ base_url_var ++ "\"");
    try expectSpelled(adapter, std.fmt.comptimePrint("FINAL_PUSH_GRACE_S = {d}", .{final_push_grace_s}));
    try expectSpelled(adapter, std.fmt.comptimePrint("INCOMPLETE_EXIT_CODE = {d}", .{exit_incomplete}));

    // The turn ceiling the adapter passes is its own, and deliberately above
    // the binary's default: a run that asked for more than the binary would
    // give it is capped there, and the cap the operator chose is the one that
    // counts. A default that dropped to the binary's own would silently make
    // the adapter's knob a no-op.
    const turns = harborNumberAfter(adapter, "DEFAULT_MAX_TURNS = \"") orelse {
        std.debug.print("\n" ++ harbor_adapter_path ++ ": DEFAULT_MAX_TURNS is not a quoted number\n", .{});
        return error.TestUnexpectedResult;
    };
    if (turns <= max_turns_default) {
        std.debug.print("\n" ++ harbor_adapter_path ++ ": DEFAULT_MAX_TURNS is {d}, not above the binary's own {d}\n", .{ turns, max_turns_default });
        return error.TestUnexpectedResult;
    }
}

const harbor_adapter_path = "integrations/harbor/microagent_agent.py";
/// The adapter is a few hundred lines; a bigger file is not the one tracked.
const max_harbor_adapter_bytes: usize = 128 * 1024;
const harbor_readme_path = "integrations/harbor/README.md";
/// The adapter's README is prose and a table; a bigger file is not the one tracked.
const max_harbor_readme_bytes: usize = 128 * 1024;

// The other half of what the adapter duplicates, and the half nothing else
// holds: the variables it reads are named in its own README, and nowhere else.
// The test above holds the values, which a change to either side can silently
// disagree about; this one holds the names, which a new knob reaches by being
// added to a reader and to no document. An operator who sets one the README does
// not list gets a run that behaved as it always has, and no way to tell that the
// variable was read at all.
//
// `MICROAGENT_STALL_TIMEOUT` is the one that was missing: the adapter read it,
// checked it, and forwarded it to the container, and the table above it named
// nine other variables and not this one.
test "the harbor README names every variable the adapter reads" {
    const gpa = std.testing.allocator;
    // Both files are read with the build root as the working directory, which
    // is where they are tracked.
    const adapter = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, harbor_adapter_path, gpa, .limited(max_harbor_adapter_bytes));
    defer gpa.free(adapter);
    const readme = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, harbor_readme_path, gpa, .limited(max_harbor_readme_bytes));
    defer gpa.free(readme);

    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(gpa);
    try adapterEnvNames(adapter, &names, gpa);
    try std.testing.expect(names.items.len > 0);
    for (names.items) |name| {
        if (!namesWholeToken(readme, name)) {
            std.debug.print("\n" ++ harbor_readme_path ++ ": does not name {s}, so the adapter reads a variable the operator has to find in its source\n", .{name});
            return error.TestUnexpectedResult;
        }
    }
}

/// The names of the variables the adapter reads, in the order it reads them.
/// A name reaches the adapter as a quoted literal: in a `trimmed_env` or
/// `int_env` call, in the tuple `api_key` walks, or in the message it refuses
/// with. A quoted run is what separates those from the module's own constants,
/// which are bare uppercase identifiers and are named by their own comments
/// rather than by a table in a README.
///
/// A run of digits is not a name but a default spelled as a string, and a
/// lower-case word is a path or a message rather than a name, so a run has to
/// hold a letter to be one. Each is reported once: a name read in two places is
/// one variable, and the README carries it once.
fn adapterEnvNames(adapter: []const u8, out: *std.ArrayList([]const u8), gpa: std.mem.Allocator) !void {
    var i: usize = 0;
    while (i < adapter.len) {
        // A name is at least two characters: the first byte after the quote
        // opens it and the second is the first of the name, so a quote followed
        // by anything else is prose and not a name at all.
        if (adapter[i] != '"' or
            i + 2 >= adapter.len or
            !isEnvNameByte(adapter[i + 1]) or
            !isEnvNameByte(adapter[i + 2]))
        {
            i += 1;
            continue;
        }
        const start = i + 1;
        var end = start;
        while (end < adapter.len and isEnvNameByte(adapter[end])) end += 1;
        var letter = false;
        for (adapter[start..end]) |c| if (c >= 'A' and c <= 'Z') {
            letter = true;
            break;
        };
        var already = false;
        if (letter) for (out.items) |kept| {
            if (std.mem.eql(u8, kept, adapter[start..end])) {
                already = true;
                break;
            }
        };
        if (letter and !already) try out.append(gpa, adapter[start..end]);
        i = end;
    }
}

fn isEnvNameByte(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_';
}

// Every variable the program reads is named by `--help` and by docs/usage.md,
// and the two documents state the empty-value rule for the same subset.
// Nothing else in the tree connects the two: the readers are spread over
// main.zig, net.zig and session.zig, a variable added to one of them works from
// the first request, and the only place a user looks for its name is the help
// text, so a variable that reached neither document is one a user finds by
// reading this source.
//
// The empty-value rule is the narrower half and the one that drifts: a
// variable one document lists among those an empty value leaves at their
// default and the other does not makes the two disagree about what an empty
// value means. Both are prose about `empty_is_unset_vars` rather than a
// rendering of it, since the help wraps its lines by hand; the test is what
// holds the prose to the list.
test "the help text and the usage reference name every variable the program reads" {
    const gpa = std.testing.allocator;
    // The test runs with the build root as its working directory, which is
    // where docs/usage.md is tracked.
    const doc = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, usage_doc_path, gpa, .limited(max_usage_doc_bytes));
    defer gpa.free(doc);

    for (env_vars) |name| {
        if (!namesWholeToken(help_text, name)) {
            std.debug.print("\n" ++ usage_doc_path ++ ": --help does not name {s}, so a user has to read the source to find it\n", .{name});
            return error.TestUnexpectedResult;
        }
        if (!namesWholeToken(doc, name)) {
            std.debug.print("\n" ++ usage_doc_path ++ ": does not name {s}, so a user has to read the source to find it\n", .{name});
            return error.TestUnexpectedResult;
        }
    }

    // The empty-value rule, in both documents, in the paragraph that states it
    // rather than anywhere in the file. A member of the list missing from one
    // of them is the drift this test exists for, and it is silent twice over:
    // an empty value reads as unset either way, so nothing tells a user the
    // document is wrong, and a name the document happens to spell elsewhere
    // (MICROAGENT_STALL_TIMEOUT in the flag table) would satisfy a search of
    // the whole file. The paragraph is what a reader of the rule reads.
    const rule_anchor = "is not a value:";
    const help_rule = paragraphFrom(help_text, rule_anchor) orelse {
        std.debug.print("\n--help has no paragraph saying an empty value is not a value\n", .{});
        return error.TestUnexpectedResult;
    };
    const doc_rule = paragraphFrom(doc, rule_anchor) orelse {
        std.debug.print("\n" ++ usage_doc_path ++ ": has no paragraph saying an empty value is not a value\n", .{});
        return error.TestUnexpectedResult;
    };
    for (empty_is_unset_vars) |name| {
        if (!namesWholeToken(help_rule, name)) {
            std.debug.print("\n--help: {s} keeps its default on an empty value and the paragraph saying so does not name it\n", .{name});
            return error.TestUnexpectedResult;
        }
        if (!namesWholeToken(doc_rule, name)) {
            std.debug.print("\n" ++ usage_doc_path ++ ": {s} keeps its default on an empty value and the paragraph saying so does not name it\n", .{name});
            return error.TestUnexpectedResult;
        }
    }

    // The three that read empty as off are named in the same paragraph as the
    // exception, which is why they are not in the list above: an empty
    // MICROAGENT_CONFIG means no config file rather than the default one, an
    // empty MICROAGENT_SESSION_DIR means no session log rather than one
    // under $HOME, and an empty MICROAGENT_SKILLS means no skills rather than
    // the default directory. Requiring them here is what keeps a fourth
    // convention from starting, where a variable is settled in a paragraph and
    // in no list.
    for ([_][]const u8{ "MICROAGENT_CONFIG", "MICROAGENT_SESSION_DIR", "MICROAGENT_SKILLS" }) |name| {
        if (!namesWholeToken(help_rule, name) or !namesWholeToken(doc_rule, name)) {
            std.debug.print("\n" ++ usage_doc_path ++ ": {s} reads empty as off rather than falling through, and one paragraph saying so does not name it\n", .{name});
            return error.TestUnexpectedResult;
        }
    }
}

/// The paragraph holding `anchor`: from the anchor to the blank line that ends
/// it. Both documents write the rule as one paragraph, and both end it the same
/// way, so a blank line is the whole delimiter and no paragraph grammar is
/// needed. Null when the anchor is in neither.
fn paragraphFrom(text: []const u8, anchor: []const u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, text, anchor) orelse return null;
    const end = std.mem.indexOfPos(u8, text, at, "\n\n") orelse text.len;
    return text[at..end];
}

const usage_doc_path = "docs/usage.md";
/// The usage reference is prose; a bigger file is not the one tracked.
const max_usage_doc_bytes: usize = 256 * 1024;

/// Whether `text` spells `name` as a word of its own, rather than as a part of
/// a longer one: a plain substring search lets `MICROAGENT_MAX_TOKENS` be
/// satisfied by a document naming only `MICROAGENT_MAX_TOKENS_TOTAL`, which is
/// a variable this build does not read and one the test would then have passed
/// without the documentation it was asked for.
fn namesWholeToken(text: []const u8, name: []const u8) bool {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, text, from, name)) |at| {
        from = at + 1;
        const before_ok = at == 0 or !isNameByte(text[at - 1]);
        const after = at + name.len;
        const after_ok = after == text.len or !isNameByte(text[after]);
        if (before_ok and after_ok) return true;
    }
    return false;
}

fn isNameByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// Every one of `names` in the tuple that starts at `anchor`, each after the one
/// before it, and nowhere outside it. The anchor is the assignment or the loop
/// header, and the closing parenthesis is the other end, so a name that is only
/// spelled somewhere else in the file does not satisfy this: the search bounded
/// to the opening bracket alone ran past a reordered tuple and found the names
/// in order in the error message below it, which is the one place the file
/// spells them in the binary's order.
fn expectNamesInOrder(text: []const u8, anchor: []const u8, names: []const []const u8) !void {
    const at = std.mem.indexOf(u8, text, anchor) orelse {
        std.debug.print("\n" ++ harbor_adapter_path ++ ": no '{s}'\n", .{anchor});
        return error.TestUnexpectedResult;
    };
    const after = at + anchor.len;
    const close = std.mem.indexOfScalarPos(u8, text, after, ')') orelse {
        std.debug.print("\n" ++ harbor_adapter_path ++ ": '{s}' opens no tuple\n", .{anchor});
        return error.TestUnexpectedResult;
    };
    const tuple = text[after..close];
    var rest = tuple;
    for (names) |name| {
        const found = std.mem.indexOf(u8, rest, name) orelse {
            std.debug.print("\n" ++ harbor_adapter_path ++ ": '{s}' does not name '{s}' in order\n", .{ anchor, name });
            return error.TestUnexpectedResult;
        };
        rest = rest[found + name.len ..];
    }
    // The other direction, which order alone does not catch: a name in the
    // tuple this build does not have. The adapter promises to refuse a level
    // the binary would refuse, before a container starts, and a level it lists
    // and the binary does not have is a value it passes on and the run rejects
    // there instead. Every quoted word in the tuple has to be one of `names`,
    // and there have to be no more of them than there are names.
    var seen: usize = 0;
    var scan: usize = 0;
    while (std.mem.indexOfScalarPos(u8, tuple, scan, '"')) |open| {
        const word_start = open + 1;
        const word_end = std.mem.indexOfScalarPos(u8, tuple, word_start, '"') orelse break;
        seen += 1;
        if (seen > names.len or !hasName(names, tuple[word_start..word_end])) {
            std.debug.print("\n" ++ harbor_adapter_path ++ ": '{s}' names a value this build does not have\n", .{anchor});
            return error.TestUnexpectedResult;
        }
        scan = word_end + 1;
    }
    if (seen != names.len) {
        std.debug.print("\n" ++ harbor_adapter_path ++ ": '{s}' names {d} values, this build has {d}\n", .{ anchor, seen, names.len });
        return error.TestUnexpectedResult;
    }
}

fn hasName(names: []const []const u8, candidate: []const u8) bool {
    for (names) |name| if (std.mem.eql(u8, name, candidate)) return true;
    return false;
}

/// The whole of `line` present in `text`, spelled exactly.
fn expectSpelled(text: []const u8, line: []const u8) !void {
    if (std.mem.indexOf(u8, text, line) != null) return;
    std.debug.print("\n" ++ harbor_adapter_path ++ ": does not spell '{s}'\n", .{line});
    return error.TestUnexpectedResult;
}

/// The number a quoted constant after `anchor` holds.
fn harborNumberAfter(text: []const u8, anchor: []const u8) ?u64 {
    const at = std.mem.indexOf(u8, text, anchor) orelse return null;
    const rest = text[at + anchor.len ..];
    const end = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    return std.fmt.parseInt(u64, rest[0..end], 10) catch null;
}

test "environMap holds what createMap holds" {
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const arena = state.allocator();

    const lines = [_:null]?[*:0]const u8{ "PATH=/usr/bin", "EMPTY=", "MODE=a=b", "HOME=/home/x" };
    const environ: std.process.Environ = .{ .block = .{ .slice = &lines } };

    var ours = try environMap(arena, environ);
    var reference = try environ.createMap(arena);
    try std.testing.expectEqual(reference.count(), ours.count());
    for (reference.keys(), reference.values()) |key, value| {
        try std.testing.expectEqualStrings(value, ours.get(key).?);
    }
    // The scrub `runMain` applies goes through the same map.
    try ours.put(key_var, "sk");
    scrubSecrets(&ours, &.{});
    try std.testing.expectEqual(@as(?[]const u8, null), ours.get(key_var));
    try std.testing.expectEqualStrings("/usr/bin", ours.get("PATH").?);
}

// The schema the model is offered. A run that turns nothing off sends the
// constant, byte for byte, because the provider caches on that prefix; a run
// that turns tools off sends the same entries less those, in the same order,
// as JSON a provider parses.
test "the built-in schema is the constant unless the config turned a tool off" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const arena = state.allocator();

    // The filter, given nothing to drop, reproduces the constant, which is what
    // says it splits `tools_json` on the right boundaries.
    try std.testing.expectEqualStrings(tools_json, try builtinToolsJson(arena, .initEmpty()));
    const default_prefix = try bodyPrefix(arena, .{ .model = "m" });
    try std.testing.expect(std.mem.indexOf(u8, default_prefix, "\"tools\":" ++ tools_json ++ ",\"stream\"") != null);

    var off: std.EnumSet(chat_mod.Tool) = .initEmpty();
    off.insert(.ast);
    off.insert(.bash);
    off.insert(.todo);
    const prefix = try bodyPrefix(arena, .{ .model = "m", .disabled_tools = off });
    const body = try std.mem.concat(arena, u8, &.{ prefix, "[]}" });
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{});
    const tools = parsed.object.get("tools").?.array;
    const expected = [_][]const u8{ "read", "write", "edit", "multi_edit", "search", "git" };
    try std.testing.expectEqual(expected.len, tools.items.len);
    for (expected, tools.items) |name, entry| {
        try std.testing.expectEqualStrings(name, entry.object.get("function").?.object.get("name").?.string);
    }
    // What an entry says is untouched: the filter drops entries, it does not rewrite them.
    try std.testing.expect(std.mem.indexOf(u8, prefix, "\"name\":\"git\",\"description\":\"Read repository state") != null);
    try std.testing.expect(std.mem.indexOf(u8, prefix, "\"name\":\"ast\"") == null);

    // A skill and a server's tools still follow the built-ins, and the array
    // is one array: a comma between the two halves and one closing bracket.
    const items = try arena.alloc(mcp_mod.Server, 1);
    items[0] = .{ .name = "srv", .transport = undefined, .tools = &.{.{
        .name = "echo",
        .exposed = "mcp__srv__echo",
        .description = "Echo",
        .schema = "{\"type\":\"object\"}",
    }} };
    const with_extras: Options = .{
        .model = "m",
        .disabled_tools = off,
        .skills = .{ .items = &.{.{ .name = "pdf", .description = "fills forms", .path = "/pdf/SKILL.md" }} },
        .mcp = .{ .items = items },
    };
    const extras_body = try buildBody(arena, with_extras, "[");
    const extras = (try std.json.parseFromSliceLeaky(std.json.Value, arena, extras_body, .{})).object.get("tools").?.array;
    const extra_names = [_][]const u8{ "read", "write", "edit", "multi_edit", "search", "git", "skill", "mcp__srv__echo" };
    try std.testing.expectEqual(extra_names.len, extras.items.len);
    for (extra_names, extras.items) |name, entry| {
        try std.testing.expectEqualStrings(name, entry.object.get("function").?.object.get("name").?.string);
    }

    // With one built-in left the array is still valid, and with none it is empty
    // rather than malformed; the run refuses that case before it is built.
    var one_left: std.EnumSet(chat_mod.Tool) = .initFull();
    one_left.remove(.read);
    const lone = try std.json.parseFromSliceLeaky(std.json.Value, arena, try builtinToolsJson(arena, one_left), .{});
    try std.testing.expectEqual(@as(usize, 1), lone.array.items.len);
    const empty = try std.json.parseFromSliceLeaky(std.json.Value, arena, try builtinToolsJson(arena, .initFull()), .{});
    try std.testing.expectEqual(@as(usize, 0), empty.array.items.len);
}

test "the system prompt names the tools that are off, and only then" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const arena = state.allocator();

    // Nothing to add: the compile-time prompt itself, not a copy of it.
    const stock = try systemText(arena, "", "", "", .initEmpty());
    try std.testing.expectEqual(conversation_mod.system_prompt.ptr, stock.ptr);

    var off: std.EnumSet(chat_mod.Tool) = .initEmpty();
    off.insert(.git);
    off.insert(.ast);
    const text = try systemText(arena, "", "", "", off);
    try std.testing.expect(std.mem.startsWith(u8, text, conversation_mod.system_prompt));
    try std.testing.expectEqualStrings("\n\nDisabled tools: ast, git.", text[conversation_mod.system_prompt.len..]);

    // The addendum follows the stock prompt after a blank line, and it and the
    // skills keep their place ahead of the line.
    const extended = try systemText(arena, "be brief", "", "\n\nSkills: x", off);
    try std.testing.expect(std.mem.startsWith(u8, extended, conversation_mod.system_prompt ++ "\n\nbe brief"));
    try std.testing.expect(std.mem.indexOf(u8, extended, "be brief").? < std.mem.indexOf(u8, extended, "Skills: x").?);
    try std.testing.expect(std.mem.endsWith(u8, extended, "\n\nDisabled tools: ast, git."));
}

// The repository's own instructions are followed, so a file that is there is
// read and a file that is not leaves the prompt alone. The three ways that can
// come out nothing: the read turned off, the default name with no such file,
// and a named path that is not there.
test "the repository instructions are read, and their absence is silent unless the path was named" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const arena = state.allocator();
    const io = std.testing.io;

    // This file is the working directory the test runs in, so the default name
    // resolves without anything setting a process-wide cwd.
    try std.testing.expect(readAgentsFile(io, arena, "src/copy.zig", false) != null);
    try std.testing.expectEqualStrings("", readAgentsFile(io, arena, "", false) orelse "");

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const big = path_buf[0..try tmp.dir.realPath(io, &path_buf)];
    const big_path = try std.fs.path.join(arena, &.{ big, "AGENTS.md" });
    try tmp.dir.writeFile(io, .{
        .sub_path = "AGENTS.md",
        .data = "house rules\n" ++ "a" ** (max_agents_bytes * 2),
    });

    // A file past the cap is followed up to the cap rather than not at all, cut
    // on a code point boundary so the prompt never carries half a character.
    const whole = readAgentsFile(io, arena, big_path, false).?;
    try std.testing.expectEqual(max_agents_bytes, whole.len);
    try std.testing.expect(std.mem.startsWith(u8, whole, "house rules\n"));

    // None of the three is an error: the run follows the system prompt alone.
    try std.testing.expect(readAgentsFile(io, arena, "src/there-is-no-such-file.md", false) == null);
    try std.testing.expect(readAgentsFile(io, arena, "src/there-is-no-such-file.md", true) == null);
}

// The reason a run does not start is decided from the parsed file, before any
// network, so it is the one place these three stops can be driven without a
// process: `runMain` turns the message into exit status 2.
test "a config the tool tables make unusable stops the run with the fix named" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const arena = state.allocator();

    const load = struct {
        fn of(a: std.mem.Allocator, text: []const u8) LoadedConfig {
            const parsed = config_mod.parse(a, text);
            return .{
                .system_prompt_extra = parsed.system_prompt_extra,
                .agents_file = parsed.agents_file,
                .agents_file_named = parsed.agents_file_named,
                .model = parsed.model,
                .base_url = parsed.base_url,
                .api_key = parsed.api_key,
                .skills = parsed.skills,
                .mcp = parsed.mcp,
                .deny_commands = parsed.deny_commands,
                .disabled_tools = parsed.disabled_tools,
                .tool_problem = parsed.tool_problem,
                .sandbox = parsed.sandbox,
                .source = "/home/u/.microagent/config.toml",
            };
        }
    }.of;

    try std.testing.expect(toolConfigError(arena, load(arena, "")) == null);
    try std.testing.expect(toolConfigError(arena, load(arena, "[tools.ast]\nenabled = false\n[tools.context7]\nenabled = true\n")) == null);

    // A misspelled name is never quietly ignored: the message names it, the
    // file, and every name that would have worked.
    const typo = toolConfigError(arena, load(arena, "[tools.serach]\nenabled = false\n")).?;
    try std.testing.expect(std.mem.indexOf(u8, typo, "/home/u/.microagent/config.toml") != null);
    try std.testing.expect(std.mem.indexOf(u8, typo, "[tools.serach] is not a tool") != null);
    try std.testing.expect(std.mem.indexOf(u8, typo, "bash, read, write, edit, multi_edit, search, ast, git, todo, web_search, context7, grep_app") != null);

    const bad = toolConfigError(arena, load(arena, "[tools.grep_app]\nenabled = true\ntimeout = 0\n")).?;
    try std.testing.expect(std.mem.indexOf(u8, bad, "timeout in [tools.grep_app]") != null);

    // The name is the file's own bytes, so it is escaped before it is printed.
    const hostile = toolConfigError(arena, load(arena, "[tools.a\x1b[2Jb]\n")).?;
    try std.testing.expect(std.mem.indexOfScalar(u8, hostile, 0x1b) == null);

    var all_off: std.ArrayList(u8) = .empty;
    for (chat_mod.tools()) |tool| try all_off.print(arena, "[tools.{s}]\nenabled = false\n", .{tool.name()});
    const nothing = toolConfigError(arena, load(arena, all_off.items)).?;
    try std.testing.expect(std.mem.indexOf(u8, nothing, "every built-in tool is disabled") != null);
    // One left is a run.
    const one = try std.mem.replaceOwned(u8, arena, all_off.items, "[tools.todo]\nenabled = false\n", "");
    try std.testing.expect(toolConfigError(arena, load(arena, one)) == null);
}

test "a call to a tool the config switched off is refused where it is dispatched" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const arena = state.allocator();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = path_buf[0..try tmp.dir.realPath(io, &path_buf)];
    const target = try std.fs.path.join(arena, &.{ root, "made.txt" });

    var off: std.EnumSet(chat_mod.Tool) = .initEmpty();
    off.insert(.write);
    var call: chat_mod.ToolCall = .{ .id = try arena.dupe(u8, ""), .name = try arena.dupe(u8, "write") };
    try call.args.appendSlice(arena, try std.fmt.allocPrint(arena, "{{\"path\":\"{s}\",\"content\":\"x\"}}", .{target}));
    var mcp: mcp_mod.Servers = .{};

    const refused = try dispatchCall(io, arena, .{}, &mcp, off, call, null, null, &.{}, &.{});
    try std.testing.expectEqualStrings("error: the tool 'write' is disabled by configuration", refused);
    // Refused before it ran: nothing was written.
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "made.txt", .{}));

    // The same call with the tool on is served, and another tool is untouched by the switch.
    const served = try dispatchCall(io, arena, .{}, &mcp, .initEmpty(), call, null, null, &.{}, &.{});
    try std.testing.expect(!std.mem.startsWith(u8, served, "error: the tool"));
    try tmp.dir.access(io, "made.txt", .{});
    var read_call: chat_mod.ToolCall = .{ .id = try arena.dupe(u8, ""), .name = try arena.dupe(u8, "read") };
    try read_call.args.appendSlice(arena, try std.fmt.allocPrint(arena, "{{\"path\":\"{s}\"}}", .{target}));
    const read = try dispatchCall(io, arena, .{}, &mcp, off, read_call, null, null, &.{}, &.{});
    try std.testing.expect(std.mem.indexOf(u8, read, "x") != null);
}

test "the variables that hold a remote server's key are scrubbed from the tool environment" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const arena = state.allocator();

    var env: std.process.Environ.Map = .init(arena);
    try env.put("EXA_API_KEY", "sk-exa");
    try env.put("DOCS_KEY", "sk-docs");
    try env.put("PATH", "/usr/bin");
    const entries = try mcp_mod.withKeys(arena, &env, &.{
        .{ .name = "web_search", .url = "https://mcp.exa.ai/mcp", .api_key_env = "EXA_API_KEY" },
        .{ .name = "docs", .url = "https://docs.example/mcp", .api_key_env = "DOCS_KEY" },
        .{ .name = "fs", .command = "npx" },
    });
    scrubSecrets(&env, entries);
    try std.testing.expect(env.get("EXA_API_KEY") == null);
    try std.testing.expect(env.get("DOCS_KEY") == null);
    try std.testing.expectEqualStrings("/usr/bin", env.get("PATH").?);
    // Read before the scrub, so the connection still has what it needs.
    try std.testing.expectEqualStrings("sk-exa", entries[0].api_key);
    try std.testing.expectEqualStrings("sk-docs", entries[1].api_key);
}

test "cstrlen agrees with std.mem.len at every alignment and length" {
    // The string ends flush with the end of the allocation, the hardest place for a scan: it must
    // stop at the terminator and must not depend on what follows it.
    const gpa = std.testing.allocator;
    for (0..word_bytes) |offset| {
        for (0..41) |len| {
            const buf = try gpa.alloc(u8, offset + len + 1);
            defer gpa.free(buf);
            @memset(buf, 'a');
            buf[offset + len] = 0;
            const s: [*:0]const u8 = @ptrCast(buf.ptr + offset);
            try std.testing.expectEqual(len, cstrlen(s));
            try std.testing.expectEqual(std.mem.len(s), cstrlen(s));
        }
    }
    // A byte at or above 0x80 is not a terminator, and neither is 0x01 or 0xff next to one.
    const tricky = [_:0]u8{ 0x80, 0xff, 0x01, 0x7f, 0x80, 0xff, 0x01, 0x7f, 0x80, 'x' };
    try std.testing.expectEqual(@as(usize, tricky.len), cstrlen(&tricky));
}
