const std = @import("std");
const pkg = @import("build.zig.zon");

pub fn build(b: *std.Build) void {
    const exe_name: []const u8 = @tagName(pkg.name);
    const exe = b.addExecutable(.{ .name = exe_name, .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = b.standardTargetOptions(.{}),
        .optimize = b.standardOptimizeOption(.{}),
        .strip = true,
        .single_threaded = true,
    }) });

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
}
