const std = @import("std");
const pkg = @import("build.zig.zon");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{
        .preferred_optimize_mode = .ReleaseFast,
    });

    const target = b.standardTargetOptions(.{});

    const exe_name: []const u8 = @tagName(pkg.name);
    const exe = b.addExecutable(.{
        .name = exe_name,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = true,
            .single_threaded = true,
        }),
    });

    const options = b.addOptions();
    options.addOption([]const u8, "exe_name", exe_name);
    options.addOption([]const u8, "version", pkg.version);
    exe.root_module.addOptions("build_options", options);

    b.installArtifact(exe);
    const run_exe = b.addRunArtifact(exe);
    if (b.args) |args| {
        run_exe.addArgs(args);
    }

    const run_step = b.step("run", "Run the application");
    run_step.dependOn(&run_exe.step);

    const test_step = b.step("test", "Run unit tests");

    const native_target: std.Target.Query = .{};
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = b.resolveTargetQuery(native_target),
        }),
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    test_step.dependOn(&run_unit_tests.step);
}
