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
    b.step("test", "Run unit tests").dependOn(&run_tests.step);
}
