const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const requested_optimize = b.standardOptimizeOption(.{});
    const optimize = effectiveOptimizeForDevInstall(b, requested_optimize);
    const test_filter = b.option([]const u8, "test-filter", "Only compile and run Zig tests whose name contains this filter.");
    const sa_std_dir_option = b.option([]const u8, "sa-std-dir", "Directory containing the SA standard library runtime archive (sa_std.lib / libsa_std.a). Overrides SA_STD_DIR and the default sibling sci/ layout.");

    const is_windows = target.result.os.tag == .windows;
    const sa_std_archive_rel = saStdArchivePath(target.result.os.tag);
    const repo_root = absoluteBuildPath(b, resolveRepoRoot(b));
    const sa_std_dir = absoluteBuildPath(b, resolveSaStdDir(b, repo_root, sa_std_dir_option, sa_std_archive_rel));
    const sa_std_archive_path = b.pathJoin(&.{ sa_std_dir, sa_std_archive_rel });

    const plugin_api = b.createModule(.{
        .root_source_file = b.path("src/plugin_api.zig"),
        .target = target,
        .optimize = optimize,
    });
    const sci_build_options = b.addOptions();
    sci_build_options.addOption([]const u8, "repo_root", repo_root);
    sci_build_options.addOption([]const u8, "sa_std_dir", sa_std_dir);
    sci_build_options.addOption([]const u8, "sa_std_archive_name", sa_std_archive_rel);
    sci_build_options.addOption([]const u8, "sa_std_archive_path", b.pathFromRoot(sa_std_archive_path));
    sci_build_options.addOption([]const u8, "version", "dev");
    const sla_build_options = b.addOptions();
    sla_build_options.addOption([]const u8, "sa_std_dir", sa_std_dir);
    const sa_std_source_dir = b.pathJoin(&.{ repo_root, "sa_std" });
    sla_build_options.addOption([]const u8, "sa_std_source_dir", sa_std_source_dir);
    const root_module = b.createModule(.{
        .root_source_file = b.path("src/plugin.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    root_module.addImport("plugin_api", plugin_api);
    root_module.addOptions("sla_build_options", sla_build_options);
    const sci_bridge = b.createModule(.{
        .root_source_file = lazyPath(b, b.pathJoin(&.{ repo_root, "src/plugin_bridge.zig" })),
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
    linkHostSystemLibs(lib, is_windows);
    b.installArtifact(lib);

    const local_cli_module = b.createModule(.{
        .root_source_file = b.path("src/local_cli.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    local_cli_module.addImport("plugin_api", plugin_api);
    local_cli_module.addOptions("sla_build_options", sla_build_options);
    local_cli_module.addImport("sci_bridge", sci_bridge);
    const local_cli = b.addExecutable(.{
        .name = "sla",
        .root_module = local_cli_module,
    });
    linkHostSystemLibs(local_cli, is_windows);
    b.installArtifact(local_cli);
    const run_local_cli = b.addRunArtifact(local_cli);
    if (b.args) |args| run_local_cli.addArgs(args);
    const local_cli_step = b.step("local-cli", "Run the local Sla CLI driver");
    local_cli_step.dependOn(&run_local_cli.step);

    const dump_sab_module = b.createModule(.{
        .root_source_file = b.path("tools/dump_sab.zig"),
        .target = target,
        .optimize = optimize,
    });
    dump_sab_module.addImport("sci_bridge", sci_bridge);
    const dump_sab = b.addExecutable(.{
        .name = "dump-sab",
        .root_module = dump_sab_module,
    });
    linkHostSystemLibs(dump_sab, is_windows);
    const run_dump_sab = b.addRunArtifact(dump_sab);
    if (b.args) |args| run_dump_sab.addArgs(args);
    const dump_sab_step = b.step("dump-sab", "Disassemble SAB or report uses of one symbol");
    dump_sab_step.dependOn(&run_dump_sab.step);

    const install_sap = b.addInstallFile(b.path("sap.json"), "lib/sap.json");
    b.getInstallStep().dependOn(&install_sap.step);

    // Test step
    const main_tests = b.addTest(.{
        .root_module = root_module,
        .filter = test_filter,
    });
    main_tests.root_module.addImport("sci_bridge", sci_bridge);
    linkHostSystemLibs(main_tests, is_windows);
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
    linkHostSystemLibs(batch_tests, is_windows);
    const install_batch_tests = b.addInstallArtifact(batch_tests, .{
        .dest_dir = .{ .override = .{ .custom = "test" } },
    });
    const batch_build_step = b.step("test-batch-build", "Build the batched test binary (run via tools/run_tests_batched.sh)");
    batch_build_step.dependOn(&install_batch_tests.step);
}

fn saStdArchivePath(os_tag: std.Target.Os.Tag) []const u8 {
    return switch (os_tag) {
        .windows => "sa_std.lib",
        else => "libsa_std.a",
    };
}

fn linkHostSystemLibs(compile: *std.Build.Step.Compile, is_windows: bool) void {
    if (!is_windows) return;
    compile.linkSystemLibrary("ws2_32");
    compile.linkSystemLibrary("iphlpapi");
}

// Wrap a possibly-absolute path as a LazyPath. Zig's b.path() rejects absolute
// inputs (configuring across hosts/roots often produces absolute roots via
// SCI_ROOT), so emit cwd_relative in that case and fall back to b.path().
fn lazyPath(b: *std.Build, sub_path: []const u8) std.Build.LazyPath {
    if (std.fs.path.isAbsolute(sub_path)) return .{ .cwd_relative = sub_path };
    return b.path(sub_path);
}

// Resolve the sci compiler repo root used for source (plugin_bridge.zig) and
// the default archive layout. Resolution order, first match wins:
//   1. SCI_ROOT env var
//   2. ../sci  (sibling layout, the historical default)
//   3. ../sci via absolute cwd parent probe
//   4. USERPROFILE/projects/sci  (Windows-friendly workspace under home)
//   5. /home/vscode/projects/sci (devcontainer default)
// Falls back to ../sci so a missing repo reports a clear build-time path error
// rather than silently emitting a dummy string.
fn resolveRepoRoot(b: *std.Build) []const u8 {
    const a = b.allocator;
    const candidates = blk: {
        var list = std.ArrayList([]const u8).init(a);
        list.append("../../../sci") catch {};
        list.append("../sci") catch {};
        // HOME-derived probes (works on Linux/macOS and Windows %USERPROFILE%).
        if (std.process.getEnvVarOwned(a, "USERPROFILE")) |home| {
            list.append(b.pathJoin(&.{ home, "projects", "sci" })) catch {};
        } else |_| {}
        if (std.process.getEnvVarOwned(a, "HOME")) |home| {
            list.append(b.pathJoin(&.{ home, "projects", "sci" })) catch {};
        } else |_| {}
        list.append("/home/vscode/projects/sci") catch {};
        break :blk list.toOwnedSlice() catch &.{};
    };

    if (std.process.getEnvVarOwned(a, "SCI_ROOT")) |env_root| {
        if (dirHasFile(env_root, "src/plugin_bridge.zig")) return env_root;
    } else |_| {}

    for (candidates) |c| {
        if (dirHasFile(c, "src/plugin_bridge.zig")) return a.dupe(u8, c) catch c;
    }
    return "../sci";
}

// Resolve the SA std archive directory. Resolution order, first match wins:
//   1. --sa-std-dir build option
//   2. SA_STD_DIR env var (matches the runtime convention used by the sci CLI)
//   3. SCI_ROOT env var (when it contains a built archive)
//   4. <repo_root>  (sci repo ships artifacts/sa_std/* in-tree)
//   5. sa_std sibling dirs and platform install roots
// When none of the absolute roots contain the archive, falls back to
// <repo_root> so a follow-up build-time file-missing error is actionable.
fn resolveSaStdDir(b: *std.Build, repo_root: []const u8, sa_std_dir_option: ?[]const u8, archive_name: []const u8) []const u8 {
    const a = b.allocator;

    if (sa_std_dir_option) |opt| {
        if (dirHasFile(opt, archive_name)) return opt;
    }
    if (std.process.getEnvVarOwned(a, "SA_STD_DIR")) |env_root| {
        if (dirHasFile(env_root, archive_name)) return env_root;
    } else |_| {}
    if (std.process.getEnvVarOwned(a, "SCI_ROOT")) |env_root| {
        const joined = b.pathJoin(&.{ env_root, "artifacts", "sa_std" });
        if (dirHasFile(joined, archive_name)) return joined;
    } else |_| {}
    {
        const joined = b.pathJoin(&.{ repo_root, "artifacts", "sa_std" });
        if (dirHasFile(joined, archive_name)) return joined;
    }

    // Common sibling / install locations, mirroring the runtime search in
    // sci's cli.zig and sa_plugin_sla's plugin_sab_paths.zig.
    const candidates = [_][]const u8{
        "sa_std",
        "../sa_std",
        "../../sa_std",
        "sci/sa_std",
        "../sci/sa_std",
        "../../sci/sa_std",
    };
    for (candidates) |c| {
        if (dirHasFile(c, archive_name)) return a.dupe(u8, c) catch c;
    }
    if (std.process.getEnvVarOwned(a, "USERPROFILE")) |home| {
        const installed = b.pathJoin(&.{ home, ".sa", "std" });
        if (dirHasFile(installed, archive_name)) return installed;
    } else |_| {}
    if (std.process.getEnvVarOwned(a, "HOME")) |home| {
        const installed = b.pathJoin(&.{ home, ".sa", "std" });
        if (dirHasFile(installed, archive_name)) return installed;
    } else |_| {}

    const joined = b.pathJoin(&.{ repo_root, "artifacts", "sa_std" });
    return joined;
}

fn absoluteBuildPath(b: *std.Build, path: []const u8) []const u8 {
    if (std.fs.path.isAbsolute(path)) return path;
    return b.pathFromRoot(path);
}
fn dirHasFile(dir: []const u8, name: []const u8) bool {
    var d = std.fs.cwd().openDir(dir, .{}) catch return false;
    defer d.close();
    d.access(name, .{}) catch return false;
    return true;
}

fn effectiveOptimizeForDevInstall(b: *std.Build, requested: std.builtin.OptimizeMode) std.builtin.OptimizeMode {
    if (requested != .ReleaseFast) return requested;
    const value = std.process.getEnvVarOwned(b.allocator, "SA_PLUGIN_DEV") catch return requested;
    defer b.allocator.free(value);
    if (std.mem.eql(u8, value, "1") or std.mem.eql(u8, value, "true")) return .Debug;
    return requested;
}
