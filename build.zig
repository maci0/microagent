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
        }),
    });
    // A position-independent image, so the executable is mapped where the
    // kernel's layout of this run puts it rather than at the fixed address
    // every build of every machine agreed on. Full RELRO is the linker's own
    // default here (Compile.link_z_relro), so the got table is read-only after
    // startup, and a non-executable stack is what a Zig link already emits.
    //
    // There is no stack canary: Zig's -fstack-protector needs a libc to call
    // __stack_chk_fail through, and nothing here links one, so the flag is a
    // build error rather than a weaker binary. A canary arrives with the libc
    // link, not before.
    exe.pie = true;
    // The release version comes from build.zig.zon, so `--version` and the
    // update check compare against the same number the release was tagged with.
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", @import("build.zig.zon").version);
    exe.root_module.addImport("build_options", build_options.createModule());
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
    run_tests.setEnvironmentVariable("LC_ALL", "C");
    run_tests.setEnvironmentVariable("TZ", "UTC");
    b.step("test", "Run unit tests").dependOn(&run_tests.step);
}
