const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const plugin_api = b.createModule(.{
        .root_source_file = b.path("src/plugin_api.zig"),
        .target = target,
        .optimize = optimize,
    });
    const root_module = b.createModule(.{
        .root_source_file = b.path("src/plugin.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    root_module.addImport("plugin_api", plugin_api);

    const lib = b.addLibrary(.{
        .name = "sla",
        .root_module = root_module,
        .linkage = .dynamic,
    });
    b.installArtifact(lib);

    const local_cli_module = b.createModule(.{
        .root_source_file = b.path("src/local_cli.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    local_cli_module.addImport("plugin_api", plugin_api);
    const local_cli = b.addExecutable(.{
        .name = "sla-local-cli",
        .root_module = local_cli_module,
    });
    const run_local_cli = b.addRunArtifact(local_cli);
    if (b.args) |args| run_local_cli.addArgs(args);
    const local_cli_step = b.step("local-cli", "Run the local Sla CLI driver");
    local_cli_step.dependOn(&run_local_cli.step);

    const install_sap = b.addInstallFile(b.path("sap.json"), "lib/sap.json");
    b.getInstallStep().dependOn(&install_sap.step);

    // Test step
    const main_tests = b.addTest(.{
        .root_module = root_module,
    });
    const run_main_tests = b.addRunArtifact(main_tests);
    const test_step = b.step("test", "Run library unit tests");
    test_step.dependOn(&run_main_tests.step);
}
