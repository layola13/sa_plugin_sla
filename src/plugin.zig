const std = @import("std");
const plugin_api = @import("plugin_api");
const ast = @import("ast.zig");
const parser_mod = @import("parser.zig");
const monomorphizer_mod = @import("monomorphizer.zig");
const type_checker_mod = @import("type_checker.zig");
const codegen_mod = @import("codegen.zig");

const skills = [_]plugin_api.SkillSection{
    .{
        .name = "sla",
        .summary = "Sla compiler and tools",
        .items = &.{
            "sla build <file> [--out <file>]",
            "sla check <file>",
            "sla test <file> [sa-test-options...]",
        },
    },
};

const max_import_bytes = 16 * 1024 * 1024;

const ResolvedImport = struct {
    path: []const u8,
    source: []const u8,
};

fn isSaStdImport(path: []const u8) bool {
    return std.mem.eql(u8, path, "sa_std") or std.mem.startsWith(u8, path, "sa_std/");
}

fn readImportFileIfExists(allocator: std.mem.Allocator, path: []const u8) !?ResolvedImport {
    const source = std.fs.cwd().readFileAlloc(allocator, path, max_import_bytes) catch |err| {
        if (err == error.FileNotFound or err == error.NotDir or err == error.IsDir) return null;
        return err;
    };
    const real_path = std.fs.cwd().realpathAlloc(allocator, path) catch try allocator.dupe(u8, path);
    return .{ .path = real_path, .source = source };
}

fn readImportFromRoot(allocator: std.mem.Allocator, root: []const u8, rel_path: []const u8) !?ResolvedImport {
    if (rel_path.len == 0) return null;
    const candidate = try std.fs.path.join(allocator, &.{ root, rel_path });
    return try readImportFileIfExists(allocator, candidate);
}

fn resolveSaStdImport(allocator: std.mem.Allocator, import_path: []const u8) !?ResolvedImport {
    if (!isSaStdImport(import_path)) return null;
    if (std.mem.eql(u8, import_path, "sa_std")) return null;

    const rel_path = import_path["sa_std/".len..];

    if (std.process.getEnvVarOwned(allocator, "SA_STD_DIR")) |env_root| {
        if (try readImportFromRoot(allocator, env_root, rel_path)) |resolved| return resolved;
    } else |_| {}

    if (std.process.getEnvVarOwned(allocator, "HOME")) |home| {
        const home_std_root = try std.fs.path.join(allocator, &.{ home, "projects", "sci", "sa_std" });
        if (try readImportFromRoot(allocator, home_std_root, rel_path)) |resolved| return resolved;
    } else |_| {}

    const candidate_roots = [_][]const u8{
        "sa_std",
        "sci/sa_std",
        "../sa_std",
        "../sci/sa_std",
        "../../sa_std",
        "../../sci/sa_std",
        "/home/vscode/projects/sci/sa_std",
    };

    for (candidate_roots) |root| {
        if (try readImportFromRoot(allocator, root, rel_path)) |resolved| return resolved;
    }

    return null;
}

fn resolveImportFile(
    allocator: std.mem.Allocator,
    base_dir: []const u8,
    raw_import_path: []const u8,
) !ResolvedImport {
    const import_path = raw_import_path;

    if (try resolveSaStdImport(allocator, import_path)) |resolved| return resolved;

    const candidate = if (std.fs.path.isAbsolute(import_path))
        try allocator.dupe(u8, import_path)
    else
        try std.fs.path.join(allocator, &.{ base_dir, import_path });

    if (try readImportFileIfExists(allocator, candidate)) |resolved| return resolved;
    return error.FileNotFound;
}

fn importPathFromLine(raw_line: []const u8) ?[]const u8 {
    const line = std.mem.trim(u8, raw_line, " \t\r");
    if (!std.mem.startsWith(u8, line, "@import")) return null;

    var rest = std.mem.trim(u8, line["@import".len..], " \t");
    if (rest.len < 2 or rest[0] != '"') return null;
    rest = rest[1..];

    var idx: usize = 0;
    while (idx < rest.len) : (idx += 1) {
        if (rest[idx] == '\\') {
            idx += 1;
            continue;
        }
        if (rest[idx] == '"') return rest[0..idx];
    }
    return null;
}

fn macroParamName(raw: []const u8) []const u8 {
    var param = std.mem.trim(u8, raw, " \t\r,");
    if (param.len > 0 and param[0] == '%') param = param[1..];
    return param;
}

fn isLeadingOutputMacroParam(raw: []const u8) bool {
    const param = macroParamName(raw);
    return std.mem.startsWith(u8, param, "out") or
        std.mem.eql(u8, param, "nonnull_ptr") or
        std.mem.eql(u8, param, "type_id") or
        std.mem.eql(u8, param, "any_ref") or
        std.mem.eql(u8, param, "cursor") or
        std.mem.eql(u8, param, "take") or
        std.mem.eql(u8, param, "repeat");
}

fn loadImportedMacros(tc: *type_checker_mod.TypeChecker, allocator: std.mem.Allocator, source: []const u8) !void {
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (!std.mem.startsWith(u8, line, "[MACRO]")) continue;

        var parts = std.mem.tokenizeAny(u8, line["[MACRO]".len..], " \t");
        const raw_name = parts.next() orelse continue;
        const name = try allocator.dupe(u8, std.mem.trim(u8, raw_name, " \t\r,"));

        var arity: usize = 0;
        var leading_outputs: usize = 0;
        var still_leading = true;
        while (parts.next()) |raw_param| {
            const param = macroParamName(raw_param);
            if (param.len == 0) continue;
            if (still_leading and isLeadingOutputMacroParam(raw_param)) {
                leading_outputs += 1;
            } else {
                still_leading = false;
            }
            arity += 1;
        }

        try tc.registerImportedMacro(name, arity, leading_outputs);
    }
}

fn loadImportContractsRecursive(
    tc: *type_checker_mod.TypeChecker,
    allocator: std.mem.Allocator,
    base_dir: []const u8,
    import_path: []const u8,
    visited: *std.StringHashMap(void),
) !void {
    const resolved = try resolveImportFile(allocator, base_dir, import_path);
    if (visited.contains(resolved.path)) return;
    try visited.put(resolved.path, {});

    const import_dir = std.fs.path.dirname(resolved.path) orelse base_dir;
    var lines = std.mem.splitScalar(u8, resolved.source, '\n');
    while (lines.next()) |line| {
        if (importPathFromLine(line)) |child_import| {
            try loadImportContractsRecursive(tc, allocator, import_dir, child_import, visited);
        }
    }

    if (std.mem.endsWith(u8, resolved.path, ".sai")) {
        try tc.loadContracts(resolved.source, "");
    } else if (std.mem.endsWith(u8, resolved.path, ".sal")) {
        try tc.loadContracts("", resolved.source);
    }
    try loadImportedMacros(tc, allocator, resolved.source);
}

fn loadImportedContracts(
    tc: *type_checker_mod.TypeChecker,
    allocator: std.mem.Allocator,
    program: *ast.Node,
    source_file: []const u8,
) !void {
    if (program.* != .program) return error.InvalidProgram;

    var visited = std.StringHashMap(void).init(allocator);
    defer visited.deinit();

    const source_dir = std.fs.path.dirname(source_file) orelse ".";
    for (program.program.decls) |decl| {
        if (decl.* == .import_decl) {
            try loadImportContractsRecursive(tc, allocator, source_dir, decl.import_decl.path, &visited);
        }
    }
}

pub fn runSlaCommandImpl(
    ctx: *const plugin_api.Context,
    args: []const []const u8,
    stdout: std.io.AnyWriter,
    stderr: std.io.AnyWriter,
) !?u8 {
    _ = ctx;
    if (args.len < 2) return null;
    if (!std.mem.eql(u8, args[1], "sla")) return null;
    if (args.len < 3) {
        try stderr.writeAll("Usage: sa sla <command> [args]\n");
        return 1;
    }
    const cmd = args[2];
    if (std.mem.eql(u8, cmd, "build")) {
        if (args.len < 4) {
            try stderr.writeAll("Error: missing file argument for 'sla build'\n");
            return 1;
        }
        const file = args[3];

        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        var out_file: ?[]const u8 = null;
        var idx: usize = 4;
        while (idx < args.len) : (idx += 1) {
            if (std.mem.eql(u8, args[idx], "--out") or std.mem.eql(u8, args[idx], "-o")) {
                if (idx + 1 < args.len) {
                    out_file = args[idx + 1];
                    idx += 1;
                }
            }
        }

        const final_out = out_file orelse blk: {
            if (std.mem.endsWith(u8, file, ".sla")) {
                const base = file[0 .. file.len - 4];
                break :blk try std.fmt.allocPrint(allocator, "{s}.sa", .{base});
            } else {
                break :blk try std.fmt.allocPrint(allocator, "{s}.sa", .{file});
            }
        };

        const content = std.fs.cwd().readFileAlloc(allocator, file, 10 * 1024 * 1024) catch |err| {
            try stderr.print("Error: failed to read file {s}: {}\n", .{file, err});
            return 1;
        };

        var p = parser_mod.Parser.init(allocator, content);
        const prog = p.parseProgram() catch |err| {
            try stderr.print("Syntax Error: failed to parse {s}: {}\n", .{file, err});
            return 1;
        };

        var mono = monomorphizer_mod.Monomorphizer.init(allocator);
        defer mono.deinit();
        const specialized_prog = mono.monomorphize(prog) catch |err| {
            try stderr.print("Monomorphization Error: failed to specialize generics: {}\n", .{err});
            return 1;
        };

        var tc = type_checker_mod.TypeChecker.init(allocator);
        defer tc.deinit();

        loadImportedContracts(&tc, allocator, specialized_prog, file) catch |err| {
            try stderr.print("Import Error: failed to load @import contracts: {}\n", .{err});
            return 1;
        };
        
        tc.checkProgram(specialized_prog) catch |err| {
            try stderr.print("Type Check Error: failed to verify types: {s} ({})\n", .{tc.last_error, err});
            return 1;
        };

        var cg = codegen_mod.Codegen.init(allocator, &tc);
        defer cg.deinit();

        const sa_code = cg.generate(specialized_prog) catch |err| {
            try stderr.print("Codegen Error: failed to generate SA code: {}\n", .{err});
            return 1;
        };

        std.fs.cwd().writeFile(.{ .sub_path = final_out, .data = sa_code }) catch |err| {
            try stderr.print("File Error: failed to write output {s}: {}\n", .{final_out, err});
            return 1;
        };

        try stdout.print("Sla Compiler: Successfully compiled {s} to {s}.\n", .{file, final_out});
        return 0;
    } else if (std.mem.eql(u8, cmd, "check")) {
        if (args.len < 4) {
            try stderr.writeAll("Error: missing file argument for 'sla check'\n");
            return 1;
        }
        const file = args[3];

        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        const content = std.fs.cwd().readFileAlloc(allocator, file, 10 * 1024 * 1024) catch |err| {
            try stderr.print("Error: failed to read file {s}: {}\n", .{file, err});
            return 1;
        };

        var p = parser_mod.Parser.init(allocator, content);
        const prog = p.parseProgram() catch |err| {
            try stderr.print("Syntax Error: failed to parse {s}: {}\n", .{file, err});
            return 1;
        };

        var mono = monomorphizer_mod.Monomorphizer.init(allocator);
        defer mono.deinit();
        const specialized_prog = mono.monomorphize(prog) catch |err| {
            try stderr.print("Monomorphization Error: failed to specialize generics: {}\n", .{err});
            return 1;
        };

        var tc = type_checker_mod.TypeChecker.init(allocator);
        defer tc.deinit();

        loadImportedContracts(&tc, allocator, specialized_prog, file) catch |err| {
            try stderr.print("Import Error: failed to load @import contracts: {}\n", .{err});
            return 1;
        };
        
        tc.checkProgram(specialized_prog) catch |err| {
            try stderr.print("Type Check Error: failed to verify types: {s} ({})\n", .{tc.last_error, err});
            return 1;
        };

        try stdout.print("Sla Compiler: Successfully parsed and verified syntax and types of {s}.\n", .{file});
        return 0;
    } else if (std.mem.eql(u8, cmd, "test")) {
        if (args.len < 4) {
            try stderr.writeAll("Error: missing file argument for 'sla test'\n");
            return 1;
        }
        const file = args[3];
        const extra_args = args[4..];

        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        // Compile .sla -> temporary .sa file next to the source
        const sa_out = if (std.mem.endsWith(u8, file, ".sla"))
            try std.fmt.allocPrint(allocator, "{s}.test.sa", .{file[0 .. file.len - 4]})
        else
            try std.fmt.allocPrint(allocator, "{s}.test.sa", .{file});

        const content = std.fs.cwd().readFileAlloc(allocator, file, 10 * 1024 * 1024) catch |err| {
            try stderr.print("Error: failed to read file {s}: {}\n", .{ file, err });
            return 1;
        };

        var p = parser_mod.Parser.init(allocator, content);
        const prog = p.parseProgram() catch |err| {
            try stderr.print("Syntax Error: failed to parse {s}: {}\n", .{ file, err });
            return 1;
        };

        var mono = monomorphizer_mod.Monomorphizer.init(allocator);
        defer mono.deinit();
        const specialized_prog = mono.monomorphize(prog) catch |err| {
            try stderr.print("Monomorphization Error: {}\n", .{err});
            return 1;
        };

        var tc = type_checker_mod.TypeChecker.init(allocator);
        defer tc.deinit();
        loadImportedContracts(&tc, allocator, specialized_prog, file) catch |err| {
            try stderr.print("Import Error: failed to load @import contracts: {}\n", .{err});
            return 1;
        };
        tc.checkProgram(specialized_prog) catch |err| {
            try stderr.print("Type Check Error: {s} ({})\n", .{ tc.last_error, err });
            return 1;
        };

        var cg = codegen_mod.Codegen.init(allocator, &tc);
        defer cg.deinit();
        const sa_code = cg.generate(specialized_prog) catch |err| {
            try stderr.print("Codegen Error: {}\n", .{err});
            return 1;
        };

        std.fs.cwd().writeFile(.{ .sub_path = sa_out, .data = sa_code }) catch |err| {
            try stderr.print("File Error: failed to write {s}: {}\n", .{ sa_out, err });
            return 1;
        };

        // Build argv: ["sa", "test", sa_out, ...extra_args]
        var argv = std.ArrayList([]const u8).init(allocator);
        try argv.append("sa");
        try argv.append("test");
        try argv.append(sa_out);
        for (extra_args) |a| try argv.append(a);

        var child = std.process.Child.init(argv.items, allocator);
        const term = child.spawnAndWait() catch |err| {
            try stderr.print("Error: failed to run 'sa test': {}\n", .{err});
            return 1;
        };
        return switch (term) {
            .Exited => |code| code,
            else => 1,
        };
    } else {
        try stderr.print("Unknown sla command: {s}\n", .{cmd});
        return 1;
    }
}

fn anyWriterFromHostStream(stream: plugin_api.HostStream, storage: *plugin_api.HostStream) std.io.AnyWriter {
    storage.* = stream;
    return .{ .context = storage, .writeFn = struct {
        fn write(ctx: *const anyopaque, bytes: []const u8) anyerror!usize {
            const hs = @as(*const plugin_api.HostStream, @ptrCast(@alignCast(ctx)));
            const write_all = hs.write_all orelse return error.WriteFailed;
            if (write_all(hs.ctx, bytes.ptr, bytes.len) != @intFromEnum(plugin_api.AbiStatus.ok)) return error.WriteFailed;
            return bytes.len;
        }
    }.write };
}

fn runSlaCommandAbi(
    ctx: *const plugin_api.Context,
    argv: [*]const [*:0]const u8,
    argv_len: usize,
    stdout: plugin_api.HostStream,
    stderr: plugin_api.HostStream,
    out_code: *u8,
) callconv(.c) u32 {
    out_code.* = 0;
    const allocator = std.heap.page_allocator;
    var local_ctx = ctx.*;
    local_ctx.allocator = allocator;

    const args = allocator.alloc([]const u8, argv_len) catch return @intFromEnum(plugin_api.AbiStatus.failed);
    defer allocator.free(args);
    for (0..argv_len) |i| {
        args[i] = std.mem.span(argv[i]);
    }

    var stdout_storage = stdout;
    var stderr_storage = stderr;
    const stdout_writer = anyWriterFromHostStream(stdout, &stdout_storage);
    const stderr_writer = anyWriterFromHostStream(stderr, &stderr_storage);

    const result = runSlaCommandImpl(&local_ctx, args, stdout_writer, stderr_writer) catch return @intFromEnum(plugin_api.AbiStatus.failed);
    if (result) |code| {
        out_code.* = code;
        return @intFromEnum(plugin_api.AbiStatus.ok);
    }
    return @intFromEnum(plugin_api.AbiStatus.unknown_command);
}

const descriptor = plugin_api.PluginDescriptor{
    .abi_version = plugin_api.abi_version,
    .descriptor_size = @as(u32, @intCast(@sizeOf(plugin_api.PluginDescriptor))),
    .name = "sla",
    .init = null,
    .prebuild = null,
    .postbuild = null,
    .handle_command = runSlaCommandAbi,
    .skills_ptr = skills[0..].ptr,
    .skills_len = skills.len,
};

pub export const saasm_plugin_descriptor_v1: plugin_api.PluginDescriptor = descriptor;
pub export fn saasm_plugin_descriptor_v1_fn(out: *plugin_api.PluginDescriptor) callconv(.c) void {
    out.* = descriptor;
}
