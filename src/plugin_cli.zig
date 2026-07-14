const std = @import("std");
const stability_metadata = @import("stability_metadata.zig");
const plugin_skills = @import("plugin_skills.zig");

pub const TestBackend = enum {
    auto,
    sab,
    sa,
};

pub const SlaCliOptions = struct {
    package_name: ?[]const u8 = null,
    source_file: ?[]const u8 = null,
    passthrough_start: usize,
    help_requested: bool = false,
    emit_sab_file: bool = false,
    test_backend: TestBackend = .auto,
};

pub fn isHelpArg(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help");
}

pub fn parseTestBackendValue(value: []const u8) !TestBackend {
    if (std.mem.eql(u8, value, "auto")) return .auto;
    if (std.mem.eql(u8, value, "sab")) return .sab;
    if (std.mem.eql(u8, value, "sa")) return .sa;
    return error.InvalidFormat;
}

pub fn parseTestBackendFromArgs(args: []const []const u8, default_backend: TestBackend) !TestBackend {
    var backend = default_backend;
    var idx: usize = 0;
    while (idx < args.len) : (idx += 1) {
        const arg = args[idx];
        if (std.mem.eql(u8, arg, "--test-backend")) {
            idx += 1;
            if (idx >= args.len) return error.InvalidFormat;
            backend = try parseTestBackendValue(args[idx]);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--test-backend=")) {
            backend = try parseTestBackendValue(arg["--test-backend=".len..]);
            continue;
        }
    }
    return backend;
}

pub fn saTestFilterFromArgs(args: []const []const u8) ?[]const u8 {
    var idx: usize = 0;
    while (idx < args.len) : (idx += 1) {
        const arg = args[idx];
        if (std.mem.eql(u8, arg, "--filter")) {
            if (idx + 1 < args.len and args[idx + 1].len != 0) return args[idx + 1];
            return null;
        }
        if (std.mem.startsWith(u8, arg, "--filter=")) {
            const pattern = arg["--filter=".len..];
            if (pattern.len != 0) return pattern;
            return null;
        }
    }
    return null;
}

pub fn appendSaTestPassthrough(argv: *std.ArrayList([]const u8), args: []const []const u8) !void {
    try appendSaTestPassthroughInternal(argv, args, false);
}

pub fn appendCompiledSaTestPassthrough(argv: *std.ArrayList([]const u8), args: []const []const u8) !void {
    try appendSaTestPassthroughInternal(argv, args, true);
}

fn appendSaTestPassthroughInternal(argv: *std.ArrayList([]const u8), args: []const []const u8, skip_filter: bool) !void {
    var idx: usize = 0;
    while (idx < args.len) : (idx += 1) {
        const arg = args[idx];
        if (std.mem.eql(u8, arg, "--test-backend")) {
            idx += 1;
            if (idx >= args.len) return error.InvalidFormat;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--test-backend=")) continue;
        if (skip_filter and std.mem.eql(u8, arg, "--filter")) {
            idx += 1;
            if (idx >= args.len) return error.InvalidFormat;
            continue;
        }
        if (skip_filter and std.mem.startsWith(u8, arg, "--filter=")) continue;
        try argv.append(arg);
    }
    try appendDefaultJobsAuto(argv, args);
}

fn hasJobsArg(args: []const []const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--jobs") or std.mem.startsWith(u8, arg, "--jobs=")) return true;
    }
    return false;
}

pub fn appendDefaultJobsAuto(argv: *std.ArrayList([]const u8), args: []const []const u8) !void {
    if (hasJobsArg(args)) return;
    try argv.append("--jobs");
    try argv.append("auto");
}

fn ensureParentDir(path: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir| {
        if (dir.len != 0) try std.fs.cwd().makePath(dir);
    }
}

fn ensureNewFile(path: []const u8, bytes: []const u8) !void {
    try ensureParentDir(path);
    var file = try std.fs.cwd().createFile(path, .{ .exclusive = true });
    defer file.close();
    try file.writeAll(bytes);
}

pub fn runSlaSkillsCommand(args: []const []const u8, option_start: usize, stdout: std.io.AnyWriter, stderr: std.io.AnyWriter, default_json_mode: bool) !u8 {
    var json_mode = default_json_mode;
    var idx = option_start;
    while (idx < args.len) : (idx += 1) {
        const arg = args[idx];
        if (isHelpArg(arg)) {
            try writeCommandHelp(stderr, "skills");
            return 0;
        }
        if (std.mem.eql(u8, arg, "--json")) {
            json_mode = true;
            continue;
        }
        try stderr.print("Unknown sla skills option: {s}\n", .{arg});
        try writeCommandHelp(stderr, "skills");
        return 1;
    }

    if (json_mode) {
        try plugin_skills.writeSlaSkillsJson(stdout);
    } else {
        const paths = try plugin_skills.writeSlaAgentSkills();
        try stdout.writeAll("sla compiler plugin\n");
        try stdout.print("generated agent skills:\n- {s}\n- {s}\n", .{ paths.codex, paths.claude });
        for (plugin_skills.skills) |section| try plugin_skills.writeSlaSkillSectionText(stdout, section);
    }
    return 0;
}

fn projectPackageName(project_path: []const u8) []const u8 {
    if (std.mem.eql(u8, project_path, ".")) return "app";
    const base = std.fs.path.basename(project_path);
    if (base.len == 0 or std.mem.eql(u8, base, ".")) return "app";
    return base;
}

pub fn runSlaInitCommand(allocator: std.mem.Allocator, args: []const []const u8, option_start: usize, stdout: std.io.AnyWriter, stderr: std.io.AnyWriter) !u8 {
    var project_path: ?[]const u8 = null;
    var idx = option_start;
    while (idx < args.len) : (idx += 1) {
        const arg = args[idx];
        if (isHelpArg(arg)) {
            try writeCommandHelp(stderr, "init");
            return 0;
        }
        if (std.mem.startsWith(u8, arg, "-")) {
            try stderr.print("Unknown sla init option: {s}\n", .{arg});
            try writeCommandHelp(stderr, "init");
            return 1;
        }
        if (project_path != null) {
            try stderr.print("Unexpected sla init argument: {s}\n", .{arg});
            try writeCommandHelp(stderr, "init");
            return 1;
        }
        project_path = arg;
    }

    const root = project_path orelse ".";
    const package_name = projectPackageName(root);
    try std.fs.cwd().makePath(root);

    const src_dir = try std.fs.path.join(allocator, &.{ root, "src" });
    defer allocator.free(src_dir);
    try std.fs.cwd().makePath(src_dir);

    const manifest_path = try std.fs.path.join(allocator, &.{ root, "sa.mod" });
    defer allocator.free(manifest_path);
    const main_path = try std.fs.path.join(allocator, &.{ root, "src", "main.sla" });
    defer allocator.free(main_path);
    const gitignore_path = try std.fs.path.join(allocator, &.{ root, ".gitignore" });
    defer allocator.free(gitignore_path);

    const manifest = try std.fmt.allocPrint(allocator,
        \\# generated by sla init
        \\package "{s}"
        \\
    , .{package_name});
    defer allocator.free(manifest);

    ensureNewFile(manifest_path, manifest) catch |err| {
        try stderr.print("File Error: failed to create {s}: {}\n", .{ manifest_path, err });
        return 1;
    };
    ensureNewFile(main_path,
        \\fn main() -> i32 {
        \\    return 0;
        \\};
        \\
    ) catch |err| {
        try stderr.print("File Error: failed to create {s}: {}\n", .{ main_path, err });
        return 1;
    };
    ensureNewFile(gitignore_path,
        \\.sla-cache/
        \\.zig-cache/
        \\.sa_cache/
        \\zig-out/
        \\*.out
        \\*.sa.bc
        \\
    ) catch |err| {
        try stderr.print("File Error: failed to create {s}: {}\n", .{ gitignore_path, err });
        return 1;
    };

    try stdout.print("Initialized SLA binary project: {s}\n", .{root});
    try stdout.print("Entry: {s}\n", .{main_path});
    return 0;
}

pub fn runSlaStabilityCommand(allocator: std.mem.Allocator, args: []const []const u8, option_start: usize, stdout: std.io.AnyWriter, stderr: std.io.AnyWriter, default_json_mode: bool) !u8 {
    if (option_start >= args.len) {
        try writeCommandHelp(stderr, "stability");
        return 1;
    }
    const subcmd = args[option_start];
    if (isHelpArg(subcmd)) {
        try writeCommandHelp(stderr, "stability");
        return 0;
    }

    if (std.mem.eql(u8, subcmd, "schema")) {
        var idx = option_start + 1;
        while (idx < args.len) : (idx += 1) {
            const arg = args[idx];
            if (isHelpArg(arg)) {
                try writeCommandHelp(stderr, "stability schema");
                return 0;
            }
            if (std.mem.eql(u8, arg, "--json")) continue;
            try stderr.print("Unknown sla stability schema option: {s}\n", .{arg});
            try writeCommandHelp(stderr, "stability schema");
            return 1;
        }
        try stdout.writeAll(stability_metadata.schema_json);
        try stdout.writeByte('\n');
        return 0;
    }

    if (std.mem.eql(u8, subcmd, "verify")) {
        var json_mode = default_json_mode;
        var manifest_path: ?[]const u8 = null;
        var idx = option_start + 1;
        while (idx < args.len) : (idx += 1) {
            const arg = args[idx];
            if (isHelpArg(arg)) {
                try writeCommandHelp(stderr, "stability verify");
                return 0;
            }
            if (std.mem.eql(u8, arg, "--json")) {
                json_mode = true;
                continue;
            }
            if (std.mem.startsWith(u8, arg, "-")) {
                try stderr.print("Unknown sla stability verify option: {s}\n", .{arg});
                try writeCommandHelp(stderr, "stability verify");
                return 1;
            }
            if (manifest_path != null) {
                try stderr.print("Unexpected sla stability verify argument: {s}\n", .{arg});
                try writeCommandHelp(stderr, "stability verify");
                return 1;
            }
            manifest_path = arg;
        }
        const path = manifest_path orelse {
            try stderr.writeAll("Missing stability manifest path\n");
            try writeCommandHelp(stderr, "stability verify");
            return 1;
        };
        const manifest = std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024) catch |err| {
            try stderr.print("File Error: failed to read {s}: {}\n", .{ path, err });
            return 1;
        };
        var report = try stability_metadata.validateManifestText(allocator, manifest);
        defer report.deinit();
        if (json_mode) {
            try stability_metadata.writeReportJson(stdout, &report);
        } else {
            try stability_metadata.writeReportText(stdout, &report);
        }
        return if (report.valid) 0 else 1;
    }

    try stderr.print("Unknown sla stability command: {s}\n", .{subcmd});
    try writeCommandHelp(stderr, "stability");
    return 1;
}

pub fn commandUsage(command: []const u8) []const u8 {
    if (std.mem.eql(u8, command, "init")) return "usage: sa sla init [path]\n";
    if (std.mem.eql(u8, command, "skills")) return "usage: sa sla skills [--json]\n";
    if (std.mem.eql(u8, command, "stability")) return "usage: sa sla stability <schema|verify> [options]\n";
    if (std.mem.eql(u8, command, "stability schema")) return "usage: sa sla stability schema [--json]\n";
    if (std.mem.eql(u8, command, "stability verify")) return "usage: sa sla stability verify <manifest.json> [--json]\n";
    if (std.mem.eql(u8, command, "build")) return "usage: sa sla build [file] [-p <package>] [--out <file>]\n";
    if (std.mem.eql(u8, command, "build-workspace")) return "usage: sa sla build-workspace [-p <package>] [sa-build-exe-options...]\n";
    if (std.mem.eql(u8, command, "build-exe")) return "usage: sa sla build-exe [file] [-p <package>] [sa-build-exe-options...]\n";
    if (std.mem.eql(u8, command, "sab")) return "usage: sa sla sab <build|workspace|disasm> [options]\n       sa slab <build|workspace|disasm> [options]\n";
    if (std.mem.eql(u8, command, "sab build")) return "usage: sa sla sab build [file] [-p <package>] [--out <file.sab>]\n       sa slab build [file] [-p <package>] [--out <file.sab>]\n";
    if (std.mem.eql(u8, command, "sab workspace")) return "usage: sa sla sab workspace [-p <package>] [--sab-out <file.sab>] [sa-build-exe-options...]\n       sa slab workspace [-p <package>] [--sab-out <file.sab>] [sa-build-exe-options...]\n";
    if (std.mem.eql(u8, command, "sab disasm")) return "usage: sa sla sab disasm <file.sab> [--out <file.sa>]\n       sa slab disasm <file.sab> [--out <file.sa>]\n";
    if (std.mem.eql(u8, command, "check")) return "usage: sa sla check [file] [-p <package>]\n";
    if (std.mem.eql(u8, command, "test")) return "usage: sa sla test [file] [-p <package>] [--test-backend auto|sab|sa] [sa-test-options...]\n";
    return "usage: sa sla <command> [options]\n";
}

pub fn writeCommandHelp(writer: std.io.AnyWriter, command: []const u8) !void {
    try writer.writeAll(commandUsage(command));
    if (std.mem.eql(u8, command, "init")) {
        try writer.writeAll("\n");
        try writer.writeAll("Create a new SLA binary project with sa.mod, src/main.sla, and .gitignore.\n\n");
        try writer.writeAll("  -h, --help              Show this help message\n");
    }
    if (std.mem.eql(u8, command, "skills")) {
        try writer.writeAll("\n");
        try writer.writeAll("List SLA plugin capabilities. Text mode also writes agent skills into the current directory.\n\n");
        try writer.writeAll("  --json                  Emit machine-readable capability JSON\n");
        try writer.writeAll("  -h, --help              Show this help message\n");
    }
    if (std.mem.eql(u8, command, "stability")) {
        try writer.writeAll("\n");
        try writer.writeAll("Validate downstream stability metadata manifests without assigning downstream label meaning.\n\n");
        try writer.writeAll("  schema                  Emit the JSON schema for stability metadata\n");
        try writer.writeAll("  verify <manifest.json>  Validate a downstream manifest\n");
        try writer.writeAll("  -h, --help              Show this help message\n");
    }
    if (std.mem.eql(u8, command, "stability schema")) {
        try writer.writeAll("\n");
        try writer.writeAll("  --json                  Accepted for consistency; schema output is JSON\n");
        try writer.writeAll("  -h, --help              Show this help message\n");
    }
    if (std.mem.eql(u8, command, "stability verify")) {
        try writer.writeAll("\n");
        try writer.writeAll("  --json                  Emit machine-readable verification output\n");
        try writer.writeAll("  -h, --help              Show this help message\n");
    }
    if (std.mem.eql(u8, command, "build") or
        std.mem.eql(u8, command, "build-workspace") or
        std.mem.eql(u8, command, "build-exe") or
        std.mem.eql(u8, command, "sab build") or
        std.mem.eql(u8, command, "sab workspace") or
        std.mem.eql(u8, command, "check") or
        std.mem.eql(u8, command, "test"))
    {
        try writer.writeAll("\n");
        try writer.writeAll("  -p, --package <name>    Select a workspace member package\n");
        if (std.mem.eql(u8, command, "build-exe") or std.mem.eql(u8, command, "build-workspace") or std.mem.eql(u8, command, "test")) {
            try writer.writeAll("  --emit-sab              Also write a sibling .sab artifact for inspection\n");
        }
        if (std.mem.eql(u8, command, "test")) {
            try writer.writeAll("  --test-backend auto|sab|sa\n");
            try writer.writeAll("                          Select test compiler backend; default auto uses SAB\n");
        }
        if (std.mem.eql(u8, command, "sab build")) {
            try writer.writeAll("  -o, --out <file.sab>    Also write SAB output file; default uses .sla-cache/sab/\n");
        }
        if (std.mem.eql(u8, command, "sab workspace")) {
            try writer.writeAll("  --sab-out <file.sab>    Also write SAB output file; default uses .sla-cache/sab/\n");
            try writer.writeAll("  --emit-sab              Also write a sibling .sab artifact for inspection\n");
        }
        try writer.writeAll("  -h, --help              Show this help message\n");
    }
    if (std.mem.eql(u8, command, "sab disasm")) {
        try writer.writeAll("\n");
        try writer.writeAll("  -o, --out <file.sa>     Write text SA debug output instead of stdout\n");
        try writer.writeAll("  -h, --help              Show this help message\n");
    }
}

pub fn parseSlaCliOptionsFrom(args: []const []const u8, command: []const u8, start_idx: usize) !SlaCliOptions {
    var options = SlaCliOptions{ .passthrough_start = args.len };
    var idx: usize = start_idx;
    while (idx < args.len) : (idx += 1) {
        const arg = args[idx];
        if (isHelpArg(arg)) {
            options.help_requested = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--emit-sab") or std.mem.eql(u8, arg, "--emit-sab-file")) {
            options.emit_sab_file = true;
            continue;
        }
        if (std.mem.eql(u8, command, "test") and std.mem.startsWith(u8, arg, "--test-backend=")) {
            options.test_backend = try parseTestBackendValue(arg["--test-backend=".len..]);
            continue;
        }
        if (std.mem.eql(u8, command, "test") and std.mem.eql(u8, arg, "--test-backend")) {
            idx += 1;
            if (idx >= args.len) return error.InvalidFormat;
            options.test_backend = try parseTestBackendValue(args[idx]);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--package=")) {
            options.package_name = arg["--package=".len..];
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-p=")) {
            options.package_name = arg["-p=".len..];
            continue;
        }
        if (std.mem.eql(u8, arg, "--package") or std.mem.eql(u8, arg, "-p")) {
            idx += 1;
            if (idx >= args.len) return error.InvalidFormat;
            options.package_name = args[idx];
            continue;
        }
        if (options.source_file == null and !std.mem.startsWith(u8, arg, "-")) {
            options.source_file = arg;
            options.passthrough_start = idx + 1;
            break;
        }
        options.passthrough_start = idx;
        break;
    }

    return options;
}

pub fn parseSlaCliOptions(args: []const []const u8, command: []const u8) !SlaCliOptions {
    return parseSlaCliOptionsFrom(args, command, 3);
}

test "sla delegated SA commands default to jobs auto unless supplied" {
    var test_argv = std.ArrayList([]const u8).init(std.testing.allocator);
    defer test_argv.deinit();
    try appendSaTestPassthrough(&test_argv, &.{ "--filter", "one" });
    try std.testing.expectEqualStrings("--jobs", test_argv.items[test_argv.items.len - 2]);
    try std.testing.expectEqualStrings("auto", test_argv.items[test_argv.items.len - 1]);

    var explicit_argv = std.ArrayList([]const u8).init(std.testing.allocator);
    defer explicit_argv.deinit();
    try appendSaTestPassthrough(&explicit_argv, &.{ "--filter", "one", "--jobs", "2" });
    var auto_count: usize = 0;
    for (explicit_argv.items) |item| {
        if (std.mem.eql(u8, item, "auto")) auto_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), auto_count);
}

test "sla compiled test passthrough drops already applied filter" {
    var argv = std.ArrayList([]const u8).init(std.testing.allocator);
    defer argv.deinit();
    try appendCompiledSaTestPassthrough(&argv, &.{ "--filter", "one", "--trace-panic", "--jobs=1", "--test-backend", "sab" });

    for (argv.items) |item| {
        try std.testing.expect(!std.mem.eql(u8, item, "--filter"));
        try std.testing.expect(!std.mem.eql(u8, item, "one"));
        try std.testing.expect(!std.mem.startsWith(u8, item, "--test-backend"));
    }
    try std.testing.expectEqualStrings("--trace-panic", argv.items[0]);
    try std.testing.expectEqualStrings("--jobs=1", argv.items[1]);

    var argv_eq = std.ArrayList([]const u8).init(std.testing.allocator);
    defer argv_eq.deinit();
    try appendCompiledSaTestPassthrough(&argv_eq, &.{ "--filter=one", "--trace-panic" });
    try std.testing.expectEqual(@as(usize, 3), argv_eq.items.len);
    try std.testing.expectEqualStrings("--trace-panic", argv_eq.items[0]);
    try std.testing.expectEqualStrings("--jobs", argv_eq.items[1]);
    try std.testing.expectEqualStrings("auto", argv_eq.items[2]);
}
