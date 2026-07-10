const std = @import("std");
const sla_workspace = @import("workspace.zig");
const plugin_cli = @import("plugin_cli.zig");

pub fn defaultOutputPath(allocator: std.mem.Allocator, file: []const u8, from_ext: []const u8, to_ext: []const u8) ![]u8 {
    if (std.mem.endsWith(u8, file, from_ext)) {
        return try std.fmt.allocPrint(allocator, "{s}{s}", .{ file[0 .. file.len - from_ext.len], to_ext });
    }
    return try std.fmt.allocPrint(allocator, "{s}{s}", .{ file, to_ext });
}

pub fn managedSabPath(allocator: std.mem.Allocator, file: []const u8) ![]u8 {
    const base = std.fs.path.basename(file);
    const stem = if (std.mem.endsWith(u8, base, ".sla")) base[0 .. base.len - 4] else base;
    const hash = std.hash.Wyhash.hash(0, file);
    return try std.fmt.allocPrint(allocator, ".sla-cache/sab/{s}-{x}.sab", .{ stem, hash });
}

fn managedSabPathWithVariantParts(
    allocator: std.mem.Allocator,
    file: []const u8,
    variant_name: []const u8,
    variant_value: ?[]const u8,
) ![]u8 {
    const base = std.fs.path.basename(file);
    const stem = if (std.mem.endsWith(u8, base, ".sla")) base[0 .. base.len - 4] else base;
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(file);
    hasher.update("\x00");
    hasher.update(variant_name);
    if (variant_value) |value| {
        hasher.update("\x00");
        hasher.update(value);
    }
    const hash = hasher.final();
    return try std.fmt.allocPrint(allocator, ".sla-cache/sab/{s}-{x}.sab", .{ stem, hash });
}

fn managedSabPathWithVariant(allocator: std.mem.Allocator, file: []const u8, variant: []const u8) ![]u8 {
    return try managedSabPathWithVariantParts(allocator, file, variant, null);
}

pub fn managedSabTestPath(allocator: std.mem.Allocator, file: []const u8, extra_args: []const []const u8) ![]u8 {
    if (plugin_cli.saTestFilterFromArgs(extra_args)) |filter| {
        return try managedSabPathWithVariantParts(allocator, file, "test-filter", filter);
    }
    return try managedSabPathWithVariant(allocator, file, "test-all");
}

pub fn writeSabFile(allocator: std.mem.Allocator, path: []const u8, sab_bytes: []const u8, stderr: std.io.AnyWriter) !bool {
    if (std.fs.path.dirname(path)) |dir| {
        std.fs.cwd().makePath(dir) catch |err| {
            try stderr.print("File Error: failed to create SAB output directory {s}: {}\n", .{ dir, err });
            return false;
        };
    }

    if (std.fs.cwd().readFileAlloc(allocator, path, sab_bytes.len + 1)) |existing| {
        defer allocator.free(existing);
        if (std.mem.eql(u8, existing, sab_bytes)) return true;
    } else |_| {}

    std.fs.cwd().writeFile(.{ .sub_path = path, .data = sab_bytes }) catch |err| {
        try stderr.print("File Error: failed to write SAB output {s}: {}\n", .{ path, err });
        return false;
    };
    return true;
}

pub fn writeManagedSab(allocator: std.mem.Allocator, file: []const u8, sab_bytes: []const u8, stderr: std.io.AnyWriter) !?[]u8 {
    const path = try managedSabPath(allocator, file);
    if (!try writeSabFile(allocator, path, sab_bytes, stderr)) return null;
    return path;
}

pub fn parseOutFileArg(args: []const []const u8, start_idx: usize) ?[]const u8 {
    var idx = start_idx;
    while (idx < args.len) : (idx += 1) {
        if (std.mem.eql(u8, args[idx], "--out") or std.mem.eql(u8, args[idx], "-o")) {
            if (idx + 1 < args.len) return args[idx + 1];
            return null;
        }
    }
    return null;
}

pub fn parseSabOutFileArg(args: []const []const u8, start_idx: usize) ?[]const u8 {
    var idx = start_idx;
    while (idx < args.len) : (idx += 1) {
        if (std.mem.eql(u8, args[idx], "--sab-out")) {
            if (idx + 1 < args.len) return args[idx + 1];
            return null;
        }
    }
    return null;
}

pub fn hasEmitSabArg(args: []const []const u8, start_idx: usize) bool {
    for (args[start_idx..]) |arg| {
        if (std.mem.eql(u8, arg, "--emit-sab") or std.mem.eql(u8, arg, "--emit-sab-file")) return true;
    }
    return false;
}

pub fn appendSabWorkspacePassthrough(argv: *std.ArrayList([]const u8), args: []const []const u8) !void {
    var idx: usize = 0;
    while (idx < args.len) : (idx += 1) {
        const arg = args[idx];
        if (std.mem.eql(u8, arg, "--emit-sab") or std.mem.eql(u8, arg, "--emit-sab-file")) continue;
        if (std.mem.eql(u8, arg, "--sab-out")) {
            idx += 1;
            continue;
        }
        try argv.append(arg);
    }
    try plugin_cli.appendDefaultJobsAuto(argv, args);
}

pub fn virtualSaPathForSabOutput(allocator: std.mem.Allocator, output_file: []const u8) ![]const u8 {
    const stem = if (std.mem.endsWith(u8, output_file, ".sab")) output_file[0 .. output_file.len - 4] else output_file;
    const sa_path = try std.fmt.allocPrint(allocator, "{s}.sa", .{stem});
    if (std.fs.path.isAbsolute(sa_path)) return sa_path;
    const cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
    return try std.fs.path.join(allocator, &.{ cwd, sa_path });
}

fn saStdRootLooksValid(allocator: std.mem.Allocator, root: []const u8) !bool {
    const required_files = [_][]const u8{
        "core/sa_core.sa",
        "core/option.sa",
        "core/result.sa",
        "io/print.sai",
    };
    for (required_files) |rel| {
        const path = try std.fs.path.join(allocator, &.{ root, rel });
        if (std.fs.cwd().openFile(path, .{})) |file| {
            file.close();
        } else |err| switch (err) {
            error.FileNotFound, error.NotDir => return false,
            else => return err,
        }
    }
    return true;
}

pub fn sabSaStdRoot(allocator: std.mem.Allocator) ![]const u8 {
    if (std.process.getEnvVarOwned(allocator, "SA_STD_DIR")) |env_root| {
        if (try saStdRootLooksValid(allocator, env_root)) return env_root;
    } else |_| {}

    if (std.process.getEnvVarOwned(allocator, "HOME")) |home| {
        const home_repo_std_root = try std.fs.path.join(allocator, &.{ home, "projects", "sci", "sa_std" });
        if (try saStdRootLooksValid(allocator, home_repo_std_root)) return home_repo_std_root;

        const installed_std_root = try std.fs.path.join(allocator, &.{ home, ".sa", "std" });
        if (try saStdRootLooksValid(allocator, installed_std_root)) return installed_std_root;
    } else |_| {}

    const candidate_roots = [_][]const u8{
        "sa_std",
        "sci/sa_std",
        "../sci/sa_std",
        "../../sci/sa_std",
        "/home/vscode/projects/sci/sa_std",
        "/home/vscode/.sa/std",
    };
    for (candidate_roots) |root| {
        if (try saStdRootLooksValid(allocator, root)) return try allocator.dupe(u8, root);
    }

    return error.FileNotFound;
}

pub fn sabProjectRoot(allocator: std.mem.Allocator, source_file: []const u8) ![]const u8 {
    const source_abs = std.fs.cwd().realpathAlloc(allocator, source_file) catch return std.fs.cwd().realpathAlloc(allocator, ".");
    const source_dir = std.fs.path.dirname(source_abs) orelse ".";
    var resolution = sla_workspace.resolveFromRootPath(allocator, source_dir, .{}) catch return std.fs.cwd().realpathAlloc(allocator, ".");
    defer resolution.deinit(allocator);
    return try allocator.dupe(u8, resolution.workspace_root);
}

test "sla sab workspace passthrough defaults to jobs auto unless supplied" {
    var workspace_argv = std.ArrayList([]const u8).init(std.testing.allocator);
    defer workspace_argv.deinit();
    try appendSabWorkspacePassthrough(&workspace_argv, &.{ "--sab-out", "/tmp/out.sab", "-o", "/tmp/app" });
    try std.testing.expectEqualStrings("-o", workspace_argv.items[0]);
    try std.testing.expectEqualStrings("/tmp/app", workspace_argv.items[1]);
    try std.testing.expectEqualStrings("--jobs", workspace_argv.items[2]);
    try std.testing.expectEqualStrings("auto", workspace_argv.items[3]);
}

test "sla sab test managed path is scoped by test filter" {
    const build_path = try managedSabPath(std.testing.allocator, "direct.sla");
    defer std.testing.allocator.free(build_path);
    const all_tests_path = try managedSabTestPath(std.testing.allocator, "direct.sla", &.{});
    defer std.testing.allocator.free(all_tests_path);
    const keep_path = try managedSabTestPath(std.testing.allocator, "direct.sla", &.{ "--filter", "keep" });
    defer std.testing.allocator.free(keep_path);
    const keep_path_again = try managedSabTestPath(std.testing.allocator, "direct.sla", &.{"--filter=keep"});
    defer std.testing.allocator.free(keep_path_again);
    const drop_path = try managedSabTestPath(std.testing.allocator, "direct.sla", &.{ "--filter", "drop" });
    defer std.testing.allocator.free(drop_path);

    try std.testing.expect(!std.mem.eql(u8, build_path, all_tests_path));
    try std.testing.expect(!std.mem.eql(u8, all_tests_path, keep_path));
    try std.testing.expect(!std.mem.eql(u8, keep_path, drop_path));
    try std.testing.expectEqualStrings(keep_path, keep_path_again);
}
