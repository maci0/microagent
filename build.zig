const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "microagent",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            // Debug keeps symbols so a panic is readable; release builds are
            // stripped because nothing reads them at runtime.
            .strip = optimize != .Debug,
            // Nothing unwinds the stack in a release build, and the tables are 62 KB of read-only
            // data the kernel maps in around every page the program touches.
            .unwind_tables = if (optimize == .Debug) null else .none,
        }),
    });
    // A fixed-address image, not a position-independent one. Address-space randomization protects
    // nothing this program keeps secret, and a PIE pays for it on every start: the loader applies
    // over a thousand relative relocations (about 11,000 instructions) and dirties the pages they
    // land in, which is resident memory the run holds for its whole life.
    //
    // There is no stack canary: Zig's -fstack-protector needs a libc to call
    // __stack_chk_fail through, and nothing here links one, so the flag is a
    // build error rather than a weaker binary. A canary arrives with the libc
    // link, not before.
    exe.pie = false;
    // The release version comes from build.zig.zon, so `--version` and the
    // update check compare against the same number the release was tagged with.
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", @import("build.zig.zon").version);
    // The first run with no config file writes this out, so an installed binary
    // hands the user the same commented template the repository ships. Embedded
    // from the tracked file rather than a second copy, and a test compares the
    // two, so the template cannot drift from the one the tests apply.
    build_options.addOption([]const u8, "config_template", @embedFile("config.example.toml"));
    const build_options_module = build_options.createModule();
    exe.root_module.addImport("build_options", build_options_module);
    // A word-at-a-time `memcpy` for `ReleaseSmall`, whose compiler runtime copies a byte at a time.
    // It is a module of its own because it has to be built with `-fno-builtin`: otherwise LLVM turns
    // its copy loop back into a call to `memcpy`, which is itself.
    const copy_module = b.createModule(.{
        .root_source_file = b.path("src/copy.zig"),
        .target = target,
        .optimize = optimize,
        .strip = optimize != .Debug,
        .no_builtin = true,
    });
    exe.root_module.addImport("copy", copy_module);
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run microagent").dependOn(&run.step);

    // -Dtest-filter runs one test by name, so editing a function does not mean
    // re-running the whole suite to see its own test.
    const test_filter = b.option([]const u8, "test-filter", "run only tests whose name contains this text");
    const tests = b.addTest(.{
        .root_module = exe.root_module,
        .filters = if (test_filter) |f| &[_][]const u8{f} else &.{},
    });
    const run_tests = b.addRunArtifact(tests);
    // The suite spawns real `/bin/sh` children and several tests assert on the
    // bytes a child printed, so the environment the run inherits has to be one
    // the host's own settings cannot change: a shell under an LC_ALL naming a
    // locale this machine does not have prints a `setlocale` warning on stderr
    // and turns those assertions into failures on a tree that is correct. The
    // Makefile exports the same two for the release builds, and `zig build
    // test` is the command the README and ci.yml both run, so the guarantee
    // belongs here rather than only under `make`.
    //
    // Both test runs get it, and through this one function so they cannot drift:
    // the sanitized run is the same suite, so a child it spawns is under the
    // same host locale, and pinning only the plain run left
    // `zig build test-sanitize` failing a child-environment test that the plain
    // run passed.
    const pin_test_env = struct {
        fn pin(step: *std.Build.Step.Run) void {
            step.setEnvironmentVariable("LC_ALL", "C");
            step.setEnvironmentVariable("TZ", "UTC");
        }
    }.pin;
    pin_test_env(run_tests);
    const run_copy_tests = b.addRunArtifact(b.addTest(.{ .root_module = copy_module }));
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&run_copy_tests.step);
    // Compiling the program, not just running the tests. Zig analyzes a
    // function body only when something calls it, and the test binary calls
    // none of `main`'s: a change to the entry point that no test reaches is
    // therefore not type-checked by the run above, so `zig build test` passed
    // on a tree whose `make build` and `make check` both failed to compile,
    // and the edit-test loop a contributor uses all day said green about a
    // binary that did not exist. The compile is a cache hit whenever the
    // sources behind the tests are unchanged, so it costs a run that edited
    // the test fixtures nothing and a run that touched main the seconds an
    // optimizing-less build of one file costs.
    test_step.dependOn(&exe.step);

    // The same suite again, compiled with the undefined-behavior sanitizer, so
    // an integer overflow, a misaligned load or a null dereference is a failed
    // check rather than a miscompiled release asset. It is a second compile of
    // the same sources and not a second way to run them: `test` and this share
    // the module options, the filter and the test names, and a bug the
    // instrumented run finds is a bug the plain run also has.
    //
    // It is a module of its own rather than `exe.root_module` with the flag set
    // on it, because a sanitize option is inherited by every artifact built
    // from the module: setting it on the executable would put instrumented code
    // in the asset release.yml publishes. `-fsanitize=address` is not offered
    // because Zig's address sanitizer needs a libc for its interceptors and
    // nothing here links one; the undefined-behavior half needs none.
    const sanitize_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_c = .full,
    });
    sanitize_module.addImport("build_options", build_options_module);
    sanitize_module.addImport("copy", copy_module);
    const sanitize_tests = b.addTest(.{
        .root_module = sanitize_module,
        .filters = if (test_filter) |f| &[_][]const u8{f} else &.{},
    });
    const run_sanitize = b.addRunArtifact(sanitize_tests);
    pin_test_env(run_sanitize);

    // Three tracked files are read by the suite at run time, from the build
    // root, rather than through the module system: docs/usage.md, the config
    // template and the Harbor adapter. Nothing the build graph knows about
    // changes when one of them does, so editing a document and rerunning the
    // suite was a cache hit on a binary compiled from the same sources: the
    // tests that read those files never saw the edit, and the one that holds
    // the two documents to the variables the program reads passed on a
    // document it had not read. Copying each into the cache makes a run step
    // depend on the bytes, which is what reruns it. The copies are not what
    // the tests open; each test reads the tracked path above by name, and only
    // the dependency is wanted here.
    //
    // Both run steps get them, through the one `WriteFile`, for the reason
    // `pin_test_env` is shared: the sanitized run is the same suite.
    const tracked_data = b.addWriteFiles();
    for ([_][]const u8{ "docs/usage.md", "config.example.toml", "integrations/harbor/microagent_agent.py" }) |path| {
        _ = tracked_data.addCopyFile(b.path(path), path);
    }
    run_tests.step.dependOn(&tracked_data.step);
    run_sanitize.step.dependOn(&tracked_data.step);

    b.step("test-sanitize", "Run unit tests under the undefined-behavior sanitizer").dependOn(&run_sanitize.step);
}
