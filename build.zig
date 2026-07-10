const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const requested_optimize = b.standardOptimizeOption(.{});
    const optimize = effectiveOptimizeForDevInstall(b, requested_optimize);
    const test_filter = b.option([]const u8, "test-filter", "Only compile and run Zig tests whose name contains this filter.");

    const plugin_api = b.createModule(.{
        .root_source_file = b.path("src/plugin_api.zig"),
        .target = target,
        .optimize = optimize,
    });
    const sci_build_options = b.addOptions();
    sci_build_options.addOption([]const u8, "repo_root", b.pathFromRoot("../../sci"));
    sci_build_options.addOption([]const u8, "sa_std_archive_path", b.pathFromRoot("../../sci/artifacts/sa_std/libsa_std.a"));
    sci_build_options.addOption([]const u8, "version", "dev");
    const root_module = b.createModule(.{
        .root_source_file = b.path("src/plugin.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    root_module.addImport("plugin_api", plugin_api);
    root_module.addOptions("build_options", sci_build_options);
    const sci_bridge = b.createModule(.{
        .root_source_file = b.path("../../sci/src/plugin_bridge.zig"),
        .target = target,
        .optimize = optimize,
    });
    sci_bridge.addOptions("build_options", sci_build_options);
    root_module.addImport("sci_bridge", sci_bridge);

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
    local_cli_module.addImport("sci_bridge", sci_bridge);
    local_cli_module.addOptions("build_options", sci_build_options);
    const local_cli = b.addExecutable(.{
        .name = "sla-local-cli",
        .root_module = local_cli_module,
    });
    b.installArtifact(local_cli);
    const run_local_cli = b.addRunArtifact(local_cli);
    if (b.args) |args| run_local_cli.addArgs(args);
    const local_cli_step = b.step("local-cli", "Run the local Sla CLI driver");
    local_cli_step.dependOn(&run_local_cli.step);

    const install_sap = b.addInstallFile(b.path("sap.json"), "lib/sap.json");
    b.getInstallStep().dependOn(&install_sap.step);

    // Test step
    const main_tests = b.addTest(.{
        .root_module = root_module,
        .filter = test_filter,
    });
    main_tests.root_module.addImport("sci_bridge", sci_bridge);
    const run_main_tests = b.addRunArtifact(main_tests);
    const test_step = b.step("test", "Run library unit tests");
    test_step.dependOn(&run_main_tests.step);

    // Batched test binary: compiled once with a custom simple-mode runner that
    // executes only the slice [SLA_TEST_START, SLA_TEST_START+SLA_TEST_COUNT).
    // A driver script invokes the installed binary repeatedly in fresh
    // processes so runtime memory is released between small batches on
    // memory-constrained hosts. See tools/run_tests_batched.sh.
    const batch_tests = b.addTest(.{
        .root_module = root_module,
        .test_runner = .{ .path = b.path("src/batch_test_runner.zig"), .mode = .simple },
    });
    batch_tests.root_module.addImport("sci_bridge", sci_bridge);
    const install_batch_tests = b.addInstallArtifact(batch_tests, .{
        .dest_dir = .{ .override = .{ .custom = "test" } },
    });
    const batch_build_step = b.step("test-batch-build", "Build the batched test binary (run via tools/run_tests_batched.sh)");
    batch_build_step.dependOn(&install_batch_tests.step);
}

fn effectiveOptimizeForDevInstall(b: *std.Build, requested: std.builtin.OptimizeMode) std.builtin.OptimizeMode {
    if (requested != .ReleaseFast) return requested;
    const value = std.process.getEnvVarOwned(b.allocator, "SA_PLUGIN_DEV") catch return requested;
    defer b.allocator.free(value);
    if (std.mem.eql(u8, value, "1") or std.mem.eql(u8, value, "true")) return .Debug;
    return requested;
}
