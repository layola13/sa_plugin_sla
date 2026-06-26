const std = @import("std");
const plugin_api = @import("plugin_api");
const ast = @import("ast.zig");
const parser_mod = @import("parser.zig");
const monomorphizer_mod = @import("monomorphizer.zig");
const type_checker_mod = @import("type_checker.zig");
const codegen_mod = @import("codegen.zig");
const sab_codegen_mod = @import("sab_codegen.zig");
const source_expand = @import("source_expand.zig");
const sla_workspace = @import("workspace.zig");
const sci_bridge = @import("sci_bridge");
pub const handler_bridge = @import("handler_bridge.zig");

pub const SlaHandlerStateFieldAbi = extern struct {
    name_ptr: ?[*]const u8,
    name_len: usize,
    ty: u32,
    address_ptr: ?[*]const u8,
    address_len: usize,
};

pub const SlaCompileHandlerOptionsAbi = extern struct {
    base_dir_ptr: ?[*]const u8 = null,
    base_dir_len: usize = 0,
};

pub const SlaCompileHandlerResultAbi = extern struct {
    body_ptr: ?[*]const u8 = null,
    body_len: usize = 0,
    support_ptr: ?[*]const u8 = null,
    support_len: usize = 0,
    error_name_ptr: ?[*]const u8 = null,
    error_name_len: usize = 0,
};

fn abiSlice(ptr: ?[*]const u8, len: usize) ?[]const u8 {
    if (len == 0) return "";
    const raw = ptr orelse return null;
    return raw[0..len];
}

fn abiStateType(ty: u32) ?handler_bridge.HandlerStateType {
    return switch (ty) {
        1 => .i1,
        2 => .i32,
        3 => .i64,
        4 => .f64,
        5 => .ptr,
        else => null,
    };
}

fn setAbiError(out: *SlaCompileHandlerResultAbi, err_name: []const u8) void {
    out.* = .{
        .error_name_ptr = err_name.ptr,
        .error_name_len = err_name.len,
    };
}

pub export fn sla_compile_handler(
    handler_name_ptr: ?[*]const u8,
    handler_name_len: usize,
    handler_source_ptr: ?[*]const u8,
    handler_source_len: usize,
    fields_ptr: ?[*]const SlaHandlerStateFieldAbi,
    fields_len: usize,
    options_ptr: ?*const SlaCompileHandlerOptionsAbi,
    out: ?*SlaCompileHandlerResultAbi,
) callconv(.c) u32 {
    const result_out = out orelse return 1;
    result_out.* = .{};

    const handler_name = abiSlice(handler_name_ptr, handler_name_len) orelse {
        setAbiError(result_out, "InvalidHandlerName");
        return 1;
    };
    const handler_source = abiSlice(handler_source_ptr, handler_source_len) orelse {
        setAbiError(result_out, "InvalidHandlerSource");
        return 1;
    };
    const raw_fields = if (fields_len == 0) &[_]SlaHandlerStateFieldAbi{} else blk: {
        const ptr = fields_ptr orelse {
            setAbiError(result_out, "InvalidStateFields");
            return 1;
        };
        break :blk ptr[0..fields_len];
    };

    const allocator = std.heap.c_allocator;
    const fields = allocator.alloc(handler_bridge.HandlerStateField, raw_fields.len) catch {
        setAbiError(result_out, "OutOfMemory");
        return 1;
    };
    defer allocator.free(fields);

    for (raw_fields, 0..) |raw, idx| {
        const name = abiSlice(raw.name_ptr, raw.name_len) orelse {
            setAbiError(result_out, "InvalidStateFieldName");
            return 1;
        };
        const address = abiSlice(raw.address_ptr, raw.address_len) orelse {
            setAbiError(result_out, "InvalidStateFieldAddress");
            return 1;
        };
        fields[idx] = .{
            .name = name,
            .ty = abiStateType(raw.ty) orelse {
                setAbiError(result_out, "InvalidStateFieldType");
                return 1;
            },
            .address = address,
        };
    }

    const options = if (options_ptr) |opts| handler_bridge.CompileHandlerOptions{
        .base_dir = abiSlice(opts.base_dir_ptr, opts.base_dir_len) orelse {
            setAbiError(result_out, "InvalidBaseDir");
            return 1;
        },
    } else handler_bridge.CompileHandlerOptions{};

    const compiled = handler_bridge.compileHandlerWithSupport(allocator, handler_name, handler_source, fields, options) catch |err| {
        setAbiError(result_out, @errorName(err));
        return 2;
    };
    result_out.* = .{
        .body_ptr = compiled.body.ptr,
        .body_len = compiled.body.len,
        .support_ptr = compiled.support.ptr,
        .support_len = compiled.support.len,
    };
    return 0;
}

pub export fn sla_compile_handler_result_free(result: ?*SlaCompileHandlerResultAbi) callconv(.c) void {
    const res = result orelse return;
    const allocator = std.heap.c_allocator;
    if (res.body_ptr) |ptr| allocator.free(ptr[0..res.body_len]);
    if (res.support_ptr) |ptr| allocator.free(ptr[0..res.support_len]);
    res.* = .{};
}

const skills = [_]plugin_api.SkillSection{
    .{
        .name = "sla",
        .summary = "Sla compiler and tools",
        .items = &.{
            "sla init [path]",
            "sla skills [--json]",
            "sla build [file] [-p <package>] [--out <file>]",
            "sla build-workspace [-p <package>] [sa-build-exe-options...]",
            "sla build-exe [file] [-p <package>] [sa-build-exe-options...]",
            "sla sab build [file] [-p <package>] [--out <file.sab>]",
            "sla sab workspace [-p <package>] [--sab-out <file.sab>] [sa-build-exe-options...]",
            "slab build|workspace|disasm ...",
            "sla check [file] [-p <package>]",
            "sla test [file] [-p <package>] [--test-backend auto|sab|sa] [sa-test-options...]",
        },
    },
};

const max_import_bytes = 16 * 1024 * 1024;

const ResolvedImport = struct {
    path: []const u8,
    output_path: []const u8,
    source: []const u8,
};

fn stringSliceLessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn resolvedImportLessThan(_: void, a: ResolvedImport, b: ResolvedImport) bool {
    return std.mem.lessThan(u8, a.output_path, b.output_path);
}

fn isGlobImportPath(path: []const u8) bool {
    return std.mem.indexOfScalar(u8, path, '*') != null;
}

fn globNameMatches(pattern: []const u8, name: []const u8) bool {
    const star = std.mem.indexOfScalar(u8, pattern, '*') orelse return std.mem.eql(u8, pattern, name);
    if (std.mem.indexOfScalarPos(u8, pattern, star + 1, '*') != null) return false;
    const prefix = pattern[0..star];
    const suffix = pattern[star + 1 ..];
    if (name.len < prefix.len + suffix.len) return false;
    return std.mem.startsWith(u8, name, prefix) and std.mem.endsWith(u8, name, suffix);
}

fn isSaStdImport(path: []const u8) bool {
    return std.mem.eql(u8, path, "sa_std") or std.mem.startsWith(u8, path, "sa_std/");
}

fn isSlaStdImport(path: []const u8) bool {
    return std.mem.eql(u8, path, "sla_std") or std.mem.startsWith(u8, path, "sla_std/");
}

fn readImportFileIfExistsWithOutputPath(allocator: std.mem.Allocator, path: []const u8, output_path: []const u8) !?ResolvedImport {
    const source = std.fs.cwd().readFileAlloc(allocator, path, max_import_bytes) catch |err| {
        if (err == error.FileNotFound or err == error.NotDir or err == error.IsDir) return null;
        return err;
    };
    const real_path = std.fs.cwd().realpathAlloc(allocator, path) catch try allocator.dupe(u8, path);
    return .{ .path = real_path, .output_path = try allocator.dupe(u8, output_path), .source = source };
}

fn readImportFileIfExists(allocator: std.mem.Allocator, path: []const u8) !?ResolvedImport {
    return try readImportFileIfExistsWithOutputPath(allocator, path, path);
}

fn readImportFromRoot(allocator: std.mem.Allocator, root: []const u8, rel_path: []const u8, output_path: []const u8) !?ResolvedImport {
    if (rel_path.len == 0) return null;
    const candidate = try std.fs.path.join(allocator, &.{ root, rel_path });
    return try readImportFileIfExistsWithOutputPath(allocator, candidate, output_path);
}

fn resolveSaStdImport(allocator: std.mem.Allocator, import_path: []const u8) !?ResolvedImport {
    if (!isSaStdImport(import_path)) return null;
    if (std.mem.eql(u8, import_path, "sa_std")) return null;

    const rel_path = import_path["sa_std/".len..];

    if (std.process.getEnvVarOwned(allocator, "SA_STD_DIR")) |env_root| {
        if (try readImportFromRoot(allocator, env_root, rel_path, import_path)) |resolved| return resolved;
    } else |_| {}

    if (std.process.getEnvVarOwned(allocator, "HOME")) |home| {
        const home_std_root = try std.fs.path.join(allocator, &.{ home, "projects", "sci", "sa_std" });
        if (try readImportFromRoot(allocator, home_std_root, rel_path, import_path)) |resolved| return resolved;
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
        if (try readImportFromRoot(allocator, root, rel_path, import_path)) |resolved| return resolved;
    }

    return null;
}

fn resolveSlaStdImport(allocator: std.mem.Allocator, import_path: []const u8) !?ResolvedImport {
    if (!isSlaStdImport(import_path)) return null;
    if (std.mem.eql(u8, import_path, "sla_std")) return null;

    const rel_path = import_path["sla_std/".len..];

    if (std.process.getEnvVarOwned(allocator, "SLA_STD_DIR")) |env_root| {
        if (try readImportFromRoot(allocator, env_root, rel_path, import_path)) |resolved| return resolved;
    } else |_| {}

    if (std.process.getEnvVarOwned(allocator, "HOME")) |home| {
        const home_std_root = try std.fs.path.join(allocator, &.{ home, "projects", "sa_plugins", "sa_plugin_sla", "sla_std" });
        if (try readImportFromRoot(allocator, home_std_root, rel_path, import_path)) |resolved| return resolved;
    } else |_| {}

    const candidate_roots = [_][]const u8{
        "sla_std",
        "sa_plugin_sla/sla_std",
        "../sa_plugin_sla/sla_std",
        "../sa_plugins/sa_plugin_sla/sla_std",
        "../../sa_plugins/sa_plugin_sla/sla_std",
        "/home/vscode/projects/sa_plugins/sa_plugin_sla/sla_std",
    };

    for (candidate_roots) |root| {
        if (try readImportFromRoot(allocator, root, rel_path, import_path)) |resolved| return resolved;
    }

    return null;
}

fn resolveImportFile(
    allocator: std.mem.Allocator,
    base_dir: []const u8,
    raw_import_path: []const u8,
) !ResolvedImport {
    const import_path = raw_import_path;

    if (try resolveSlaStdImport(allocator, import_path)) |resolved| return resolved;
    if (try resolveSaStdImport(allocator, import_path)) |resolved| return resolved;

    const candidate = if (std.fs.path.isAbsolute(import_path))
        try allocator.dupe(u8, import_path)
    else
        try std.fs.path.join(allocator, &.{ base_dir, import_path });

    if (try readImportFileIfExists(allocator, candidate)) |resolved| return resolved;
    if (!std.fs.path.isAbsolute(import_path)) {
        if (try readImportFileIfExists(allocator, import_path)) |resolved| return resolved;
    }
    return error.FileNotFound;
}

fn appendResolvedImportFiles(
    allocator: std.mem.Allocator,
    base_dir: []const u8,
    raw_import_path: []const u8,
    exclude_path: ?[]const u8,
    out: *std.ArrayList(ResolvedImport),
) !void {
    if (!isGlobImportPath(raw_import_path)) {
        const resolved = try resolveImportFile(allocator, base_dir, raw_import_path);
        if (exclude_path) |exclude| {
            if (std.mem.eql(u8, resolved.path, exclude)) return;
        }
        try out.append(resolved);
        return;
    }

    if (isSaStdImport(raw_import_path) or isSlaStdImport(raw_import_path)) return error.FileNotFound;

    const pattern_path = if (std.fs.path.isAbsolute(raw_import_path))
        try allocator.dupe(u8, raw_import_path)
    else
        try std.fs.path.join(allocator, &.{ base_dir, raw_import_path });

    const dir_path = std.fs.path.dirname(pattern_path) orelse ".";
    const pattern_name = std.fs.path.basename(pattern_path);

    var dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
    defer dir.close();

    var matched_paths = std.ArrayList([]const u8).init(allocator);
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file and entry.kind != .sym_link) continue;
        if (!globNameMatches(pattern_name, entry.name)) continue;
        const candidate = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
        try matched_paths.append(candidate);
    }

    std.mem.sort([]const u8, matched_paths.items, {}, stringSliceLessThan);

    var matched_count: usize = 0;
    for (matched_paths.items) |candidate| {
        if (try readImportFileIfExists(allocator, candidate)) |resolved| {
            if (exclude_path) |exclude| {
                if (std.mem.eql(u8, resolved.path, exclude)) continue;
            }
            try out.append(resolved);
            matched_count += 1;
        }
    }
    if (matched_count == 0) return error.FileNotFound;
}

fn resolveImportFiles(
    allocator: std.mem.Allocator,
    base_dir: []const u8,
    raw_import_path: []const u8,
    exclude_path: ?[]const u8,
) ![]ResolvedImport {
    var out = std.ArrayList(ResolvedImport).init(allocator);
    try appendResolvedImportFiles(allocator, base_dir, raw_import_path, exclude_path, &out);
    std.mem.sort(ResolvedImport, out.items, {}, resolvedImportLessThan);
    return try out.toOwnedSlice();
}

fn importPathFromLine(raw_line: []const u8) ?[]const u8 {
    const line = std.mem.trim(u8, raw_line, " \t\r");
    if (!std.mem.startsWith(u8, line, "@import")) return null;

    var rest = std.mem.trim(u8, line["@import".len..], " \t");
    if (rest.len == 0) return null;
    if (rest[0] != '"') {
        if (std.mem.indexOf(u8, rest, "//")) |comment_idx| rest = rest[0..comment_idx];
        rest = std.mem.trim(u8, rest, " \t\r;");
        if (rest.len == 0) return null;
        return rest;
    }
    if (rest.len < 2) return null;
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
    const expanded_source = try source_expand.expand(allocator, source);
    var lines = std.mem.splitScalar(u8, expanded_source, '\n');
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

fn appendExpandedSlaImportDecls(
    allocator: std.mem.Allocator,
    base_dir: []const u8,
    import_path: []const u8,
    exclude_path: ?[]const u8,
    visited: *std.StringHashMap(void),
    primary_decls: *std.AutoHashMap(*const ast.Node, void),
    out_decls: *std.ArrayList(*ast.Node),
) !void {
    const resolved_imports = try resolveImportFiles(allocator, base_dir, import_path, exclude_path);
    for (resolved_imports) |resolved| {
        if (!std.mem.endsWith(u8, resolved.path, ".sla")) continue;
        if (visited.contains(resolved.path)) continue;
        try visited.put(resolved.path, {});

        const imported_base_dir = std.fs.path.dirname(resolved.path) orelse base_dir;
        const expanded_source = try source_expand.expand(allocator, resolved.source);
        var parser = parser_mod.Parser.initWithDir(allocator, expanded_source, imported_base_dir);
        const imported_prog = try parser.parseProgram();
        if (imported_prog.* != .program) return error.InvalidProgram;

        const import_dir = std.fs.path.dirname(resolved.path) orelse base_dir;
        for (imported_prog.program.decls) |decl| {
            if (decl.* == .import_decl) {
                const child_resolved_imports = try resolveImportFiles(allocator, import_dir, decl.import_decl.path, resolved.path);
                for (child_resolved_imports) |child_resolved| {
                    if (std.mem.endsWith(u8, child_resolved.path, ".sla")) {
                        try appendExpandedSlaImportDecls(allocator, import_dir, decl.import_decl.path, resolved.path, visited, primary_decls, out_decls);
                    } else {
                        const import_decl = try allocator.create(ast.Node);
                        import_decl.* = .{ .import_decl = .{ .path = child_resolved.output_path } };
                        try out_decls.append(import_decl);
                        try primary_decls.put(import_decl, {});
                    }
                }
            } else {
                try out_decls.append(decl);
                try primary_decls.put(decl, {});
            }
        }
    }
}

fn replaceSlaWithSa(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    if (std.mem.endsWith(u8, path, ".sla")) {
        const base = path[0 .. path.len - 4];
        return try std.fmt.allocPrint(allocator, "{s}.sa", .{base});
    }
    return try allocator.dupe(u8, path);
}

fn normalizedSaStdImportPath(allocator: std.mem.Allocator, path: []const u8) !?[]const u8 {
    if (isSaStdImport(path)) return try allocator.dupe(u8, path);
    if (std.mem.indexOf(u8, path, ".sa/std/")) |idx| {
        const suffix = path[idx + ".sa/std/".len ..];
        return try std.fmt.allocPrint(allocator, "sa_std/{s}", .{suffix});
    }
    if (std.mem.indexOf(u8, path, "sci/sa_std/")) |idx| {
        const suffix = path[idx + "sci/sa_std/".len ..];
        return try std.fmt.allocPrint(allocator, "sa_std/{s}", .{suffix});
    }
    if (std.mem.indexOf(u8, path, "sa_std/")) |idx| {
        return try allocator.dupe(u8, path[idx..]);
    }
    return null;
}

fn normalizedSlaStdImportPath(allocator: std.mem.Allocator, path: []const u8) !?[]const u8 {
    if (isSlaStdImport(path)) return try allocator.dupe(u8, path);
    if (std.mem.indexOf(u8, path, "sa_plugin_sla/sla_std/")) |idx| {
        const suffix = path[idx + "sa_plugin_sla/sla_std/".len ..];
        return try std.fmt.allocPrint(allocator, "sla_std/{s}", .{suffix});
    }
    if (std.mem.indexOf(u8, path, "sla_std/")) |idx| {
        return try allocator.dupe(u8, path[idx..]);
    }
    return null;
}

fn absoluteDirForOutput(allocator: std.mem.Allocator, output_file: []const u8) ![]const u8 {
    const output_dir = std.fs.path.dirname(output_file) orelse ".";
    if (std.fs.path.isAbsolute(output_dir)) return try allocator.dupe(u8, output_dir);
    return std.fs.cwd().realpathAlloc(allocator, output_dir) catch |err| switch (err) {
        error.FileNotFound => blk: {
            const cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
            break :blk try std.fs.path.join(allocator, &.{ cwd, output_dir });
        },
        else => return err,
    };
}

fn rewriteImportPathForOutput(
    allocator: std.mem.Allocator,
    source_file: []const u8,
    output_file: []const u8,
    raw_import_path: []const u8,
) ![]const u8 {
    if (try normalizedSlaStdImportPath(allocator, raw_import_path)) |std_path| return std_path;
    if (try normalizedSaStdImportPath(allocator, raw_import_path)) |std_path| return std_path;

    const source_dir = std.fs.path.dirname(source_file) orelse ".";
    const resolved = try resolveImportFile(allocator, source_dir, raw_import_path);
    if (try normalizedSlaStdImportPath(allocator, resolved.path)) |std_path| return std_path;
    if (try normalizedSaStdImportPath(allocator, resolved.path)) |std_path| return std_path;

    const target_path = try replaceSlaWithSa(allocator, resolved.path);
    if (!std.fs.path.isAbsolute(target_path)) return target_path;

    const output_dir = try absoluteDirForOutput(allocator, output_file);
    return try std.fs.path.relative(allocator, output_dir, target_path);
}

fn rewriteProgramImportsForOutput(
    allocator: std.mem.Allocator,
    program: *ast.Node,
    source_file: []const u8,
    output_file: ?[]const u8,
) !void {
    const out = output_file orelse return;
    if (program.* != .program) return error.InvalidProgram;

    for (program.program.decls) |decl| {
        if (decl.* != .import_decl) continue;
        decl.import_decl.path = try rewriteImportPathForOutput(allocator, source_file, out, decl.import_decl.path);
    }
}

fn expandSlaImports(
    allocator: std.mem.Allocator,
    program: *ast.Node,
    source_file: []const u8,
    primary_decls: *std.AutoHashMap(*const ast.Node, void),
) !*ast.Node {
    if (program.* != .program) return error.InvalidProgram;

    var visited = std.StringHashMap(void).init(allocator);
    defer visited.deinit();

    var decls = std.ArrayList(*ast.Node).init(allocator);
    const source_dir = std.fs.path.dirname(source_file) orelse ".";
    const source_abs = std.fs.cwd().realpathAlloc(allocator, source_file) catch source_file;

    for (program.program.decls) |decl| {
        if (decl.* == .import_decl) {
            const resolved_imports = try resolveImportFiles(allocator, source_dir, decl.import_decl.path, source_abs);
            for (resolved_imports) |resolved| {
                if (std.mem.endsWith(u8, resolved.path, ".sla")) {
                    try appendExpandedSlaImportDecls(allocator, source_dir, decl.import_decl.path, source_abs, &visited, primary_decls, &decls);
                } else {
                    const import_decl = try allocator.create(ast.Node);
                    import_decl.* = .{ .import_decl = .{ .path = resolved.output_path } };
                    try decls.append(import_decl);
                    try primary_decls.put(import_decl, {});
                }
            }
        } else {
            try decls.append(decl);
            try primary_decls.put(decl, {});
        }
    }

    const expanded = try allocator.create(ast.Node);
    expanded.* = .{ .program = .{ .decls = try decls.toOwnedSlice() } };
    return expanded;
}

fn loadImportContractsRecursive(
    tc: *type_checker_mod.TypeChecker,
    allocator: std.mem.Allocator,
    base_dir: []const u8,
    import_path: []const u8,
    exclude_path: ?[]const u8,
    visited: *std.StringHashMap(void),
) !void {
    const resolved_imports = try resolveImportFiles(allocator, base_dir, import_path, exclude_path);
    for (resolved_imports) |resolved| {
        if (visited.contains(resolved.path)) continue;
        try visited.put(resolved.path, {});

        const import_dir = std.fs.path.dirname(resolved.path) orelse base_dir;
        const expanded_source = try source_expand.expand(allocator, resolved.source);
        var lines = std.mem.splitScalar(u8, expanded_source, '\n');
        while (lines.next()) |line| {
            if (importPathFromLine(line)) |child_import| {
                try loadImportContractsRecursive(tc, allocator, import_dir, child_import, resolved.path, visited);
            }
        }

        if (std.mem.endsWith(u8, resolved.path, ".sai")) {
            try tc.loadContracts(expanded_source, "");
        } else if (std.mem.endsWith(u8, resolved.path, ".sal")) {
            try tc.loadContracts("", expanded_source);
        }
        try loadImportedMacros(tc, allocator, expanded_source);
    }
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
    const source_abs = std.fs.cwd().realpathAlloc(allocator, source_file) catch source_file;
    for (program.program.decls) |decl| {
        if (decl.* == .import_decl) {
            try loadImportContractsRecursive(tc, allocator, source_dir, decl.import_decl.path, source_abs, &visited);
        }
    }
}

const SlaCompileOptions = struct {
    test_filter: ?[]const u8 = null,
    return_unsupported_sab_error: bool = false,
};

fn slaProfileEnabled(allocator: std.mem.Allocator) bool {
    const value = std.process.getEnvVarOwned(allocator, "SLA_PROFILE") catch return false;
    defer allocator.free(value);
    return value.len != 0 and !std.mem.eql(u8, value, "0") and !std.mem.eql(u8, value, "false");
}

fn slaProfileStage(stderr: std.io.AnyWriter, enabled: bool, label: []const u8, start_ns: i128) void {
    if (!enabled) return;
    const elapsed_ms = @divTrunc(std.time.nanoTimestamp() - start_ns, std.time.ns_per_ms);
    stderr.print("[sla-profile] {s}: {d}ms\n", .{ label, elapsed_ms }) catch {};
}

fn testMatchesFilter(test_decl: *const ast.TestDecl, filter: ?[]const u8) bool {
    const pattern = filter orelse return true;
    if (pattern.len == 0) return true;
    return std.mem.indexOf(u8, test_decl.name, pattern) != null;
}

fn pruneTestsByFilter(allocator: std.mem.Allocator, program: *ast.Node, filter: ?[]const u8) !void {
    if (filter == null or filter.?.len == 0) return;
    if (program.* != .program) return error.InvalidProgram;

    var filtered_decls = std.ArrayList(*ast.Node).init(allocator);
    for (program.program.decls) |decl| {
        if (decl.* == .test_decl and !testMatchesFilter(&decl.test_decl, filter)) continue;
        try filtered_decls.append(decl);
    }
    program.program.decls = try filtered_decls.toOwnedSlice();
}

fn saTestFilterFromArgs(args: []const []const u8) ?[]const u8 {
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

fn compileSlaToSaString(
    allocator: std.mem.Allocator,
    file: []const u8,
    output_file: ?[]const u8,
    stderr: std.io.AnyWriter,
) !?[]const u8 {
    return compileSlaToSaStringWithOptions(allocator, file, output_file, stderr, .{});
}

fn compileSlaToSaStringWithOptions(
    allocator: std.mem.Allocator,
    file: []const u8,
    output_file: ?[]const u8,
    stderr: std.io.AnyWriter,
    options: SlaCompileOptions,
) !?[]const u8 {
    const content = std.fs.cwd().readFileAlloc(allocator, file, 10 * 1024 * 1024) catch |err| {
        try stderr.print("Error: failed to read file {s}: {}\n", .{ file, err });
        return null;
    };

    const expanded_content = source_expand.expand(allocator, content) catch |err| {
        try stderr.print("Macro Expansion Error: failed to expand tuple templates in {s}: {}\n", .{ file, err });
        return null;
    };

    const sla_base_dir = std.fs.path.dirname(file) orelse ".";
    var p = parser_mod.Parser.initWithDir(allocator, expanded_content, sla_base_dir);
    const prog = p.parseProgram() catch |err| {
        try p.printDiagnostic(stderr, file, err);
        return null;
    };

    var primary_decls = std.AutoHashMap(*const ast.Node, void).init(allocator);
    const expanded_prog = expandSlaImports(allocator, prog, file, &primary_decls) catch |err| {
        try stderr.print("Import Error: failed to expand @import SLA sources: {}\n", .{err});
        return null;
    };

    pruneTestsByFilter(allocator, expanded_prog, options.test_filter) catch |err| {
        try stderr.print("Test Filter Error: failed to prune @test declarations: {}\n", .{err});
        return null;
    };

    var mono = monomorphizer_mod.Monomorphizer.init(allocator);
    defer mono.deinit();
    var specialized_primary_decls = std.AutoHashMap(*const ast.Node, void).init(allocator);
    const specialized_prog = mono.monomorphize(expanded_prog, &primary_decls, &specialized_primary_decls) catch |err| {
        try stderr.print("Monomorphization Error: failed to specialize generics: {}\n", .{err});
        return null;
    };

    var tc = type_checker_mod.TypeChecker.init(allocator);
    defer tc.deinit();

    loadImportedContracts(&tc, allocator, specialized_prog, file) catch |err| {
        try stderr.print("Import Error: failed to load @import contracts: {}\n", .{err});
        return null;
    };

    tc.checkProgram(specialized_prog) catch |err| {
        try stderr.print("Type Check Error: failed to verify types: {s} ({})\n", .{ tc.last_error, err });
        return null;
    };

    // Filter specialized_prog to only include primary declarations
    var filtered_decls = std.ArrayList(*ast.Node).init(allocator);
    for (specialized_prog.program.decls) |decl| {
        if (specialized_primary_decls.contains(decl)) {
            try filtered_decls.append(decl);
        }
    }
    specialized_prog.program.decls = try filtered_decls.toOwnedSlice();

    rewriteProgramImportsForOutput(allocator, specialized_prog, file, output_file) catch |err| {
        try stderr.print("Import Error: failed to rewrite @import paths for output: {}\n", .{err});
        return null;
    };

    var cg = codegen_mod.Codegen.init(allocator, &tc);
    defer cg.deinit();

    return cg.generate(specialized_prog) catch |err| {
        try stderr.print("Codegen Error: failed to generate SA code: {}\n", .{err});
        if (@errorReturnTrace()) |trace| std.debug.dumpStackTrace(trace.*);
        return null;
    };
}

fn compileSlaFileToSa(
    allocator: std.mem.Allocator,
    file: []const u8,
    output_file: ?[]const u8,
    stderr: std.io.AnyWriter,
) !?[]const u8 {
    return compileSlaToSaString(allocator, file, output_file, stderr);
}

const TestBackend = enum {
    auto,
    sab,
    sa,
};

const SlaCliOptions = struct {
    package_name: ?[]const u8 = null,
    source_file: ?[]const u8 = null,
    passthrough_start: usize,
    help_requested: bool = false,
    emit_sab_file: bool = false,
    test_backend: TestBackend = .auto,
};

fn isHelpArg(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help");
}

fn parseTestBackendValue(value: []const u8) !TestBackend {
    if (std.mem.eql(u8, value, "auto")) return .auto;
    if (std.mem.eql(u8, value, "sab")) return .sab;
    if (std.mem.eql(u8, value, "sa")) return .sa;
    return error.InvalidFormat;
}

fn parseTestBackendFromArgs(args: []const []const u8, default_backend: TestBackend) !TestBackend {
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

fn appendSaTestPassthrough(argv: *std.ArrayList([]const u8), args: []const []const u8) !void {
    var idx: usize = 0;
    while (idx < args.len) : (idx += 1) {
        const arg = args[idx];
        if (std.mem.eql(u8, arg, "--test-backend")) {
            idx += 1;
            if (idx >= args.len) return error.InvalidFormat;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--test-backend=")) continue;
        try argv.append(arg);
    }
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

fn writeJsonString(writer: anytype, text: []const u8) !void {
    try writer.writeByte('"');
    for (text) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => {
                if (c < 0x20) {
                    try writer.print("\\u{X:0>4}", .{c});
                } else {
                    try writer.writeByte(c);
                }
            },
        }
    }
    try writer.writeByte('"');
}

fn writeJsonStringArray(writer: anytype, items: []const []const u8) !void {
    try writer.writeByte('[');
    for (items, 0..) |item, idx| {
        if (idx != 0) try writer.writeByte(',');
        try writeJsonString(writer, item);
    }
    try writer.writeByte(']');
}

fn writeSlaSkillsJson(writer: anytype) !void {
    try writer.writeAll("{\"status\":\"ok\",\"skills\":[");
    for (skills, 0..) |section, idx| {
        if (idx != 0) try writer.writeByte(',');
        try writer.writeByte('{');
        try writer.writeAll("\"name\":");
        try writeJsonString(writer, section.name);
        try writer.writeAll(",\"summary\":");
        try writeJsonString(writer, section.summary);
        try writer.writeAll(",\"items\":");
        try writeJsonStringArray(writer, section.items);
        try writer.writeByte('}');
    }
    try writer.writeAll("]}\n");
}

fn writeSlaSkillSectionText(writer: anytype, section: plugin_api.SkillSection) !void {
    try writer.print("{s}\n", .{section.name});
    try writer.print("summary: {s}\n", .{section.summary});
    for (section.items) |item| {
        try writer.print("- {s}\n", .{item});
    }
}

fn writeMarkdownCodeList(writer: anytype, items: []const []const u8) !void {
    for (items) |item| try writer.print("- `{s}`\n", .{item});
}

fn writeSlaAgentSkillMarkdown(writer: anytype, agent_name: []const u8) !void {
    const description = if (std.mem.eql(u8, agent_name, "claude"))
        "Use the installed SLA plugin from Claude to build, check, test, scaffold, and inspect direct SAB workflows."
    else
        "Use the installed SLA plugin from Codex to build, check, test, scaffold, and inspect direct SAB workflows.";

    try writer.writeAll("---\n");
    try writer.writeAll("name: \"sla\"\n");
    try writer.writeAll("description: ");
    try writeJsonString(writer, description);
    try writer.writeByte('\n');
    try writer.writeAll("when_to_use: \"Use when working on .sla sources, SLA workspace builds, direct SLA-to-SAB output, or SLA plugin CLI commands.\"\n");
    try writer.writeAll("---\n\n");

    try writer.writeAll("# SLA Toolchain\n\n");
    try writer.writeAll("## Core Workflow\n");
    try writer.writeAll("- Use `sa sla init [path]` to scaffold a minimal SLA binary project.\n");
    try writer.writeAll("- Use `sa sla build <file>` only when a visible `.sa` text artifact is needed.\n");
    try writer.writeAll("- Use `sa sla build-exe <file>` or `sa sla sab workspace` for executable builds through the direct SAB path.\n");
    try writer.writeAll("- Use `sa sla test <file>` for tests through the direct SAB path by default; add `--test-backend sa` only when debugging legacy `.test.sa` output.\n");
    try writer.writeAll("- Use `sa sla sab build <file>` to emit managed SAB under `.sla-cache/sab/`; add `--out <file.sab>` only for an inspection copy.\n");
    try writer.writeAll("- Keep SLA-to-SA and SLA-to-SAB as separate mainlines; SAB output must not be implemented as `sla -> sa -> sab`.\n");
    try writer.writeAll("- Prefer focused checks with `timeout 120s`; do not run full test suites unless explicitly requested. Build commands do not need the timeout wrapper.\n\n");

    try writer.writeAll("## CLI Skill Sections\n");
    for (skills) |section| {
        try writer.print("### {s}\n", .{section.name});
        try writer.print("{s}\n", .{section.summary});
        try writeMarkdownCodeList(writer, section.items);
        try writer.writeByte('\n');
    }
}

const SlaAgentSkillPaths = struct {
    codex: []const u8,
    claude: []const u8,
};

fn writeSlaAgentSkills() !SlaAgentSkillPaths {
    const codex_path = ".codex/skills/sla/SKILL.md";
    const claude_path = ".claude/skills/sla/SKILL.md";
    try ensureParentDir(codex_path);
    try ensureParentDir(claude_path);
    {
        var file = try std.fs.cwd().createFile(codex_path, .{ .truncate = true });
        defer file.close();
        try writeSlaAgentSkillMarkdown(file.writer(), "codex");
    }
    {
        var file = try std.fs.cwd().createFile(claude_path, .{ .truncate = true });
        defer file.close();
        try writeSlaAgentSkillMarkdown(file.writer(), "claude");
    }
    return .{ .codex = codex_path, .claude = claude_path };
}

fn runSlaSkillsCommand(args: []const []const u8, option_start: usize, stdout: std.io.AnyWriter, stderr: std.io.AnyWriter, default_json_mode: bool) !u8 {
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
        try writeSlaSkillsJson(stdout);
    } else {
        const paths = try writeSlaAgentSkills();
        try stdout.writeAll("sla compiler plugin\n");
        try stdout.print("generated agent skills:\n- {s}\n- {s}\n", .{ paths.codex, paths.claude });
        for (skills) |section| try writeSlaSkillSectionText(stdout, section);
    }
    return 0;
}

fn projectPackageName(project_path: []const u8) []const u8 {
    if (std.mem.eql(u8, project_path, ".")) return "app";
    const base = std.fs.path.basename(project_path);
    if (base.len == 0 or std.mem.eql(u8, base, ".")) return "app";
    return base;
}

fn runSlaInitCommand(allocator: std.mem.Allocator, args: []const []const u8, option_start: usize, stdout: std.io.AnyWriter, stderr: std.io.AnyWriter) !u8 {
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

fn commandUsage(command: []const u8) []const u8 {
    if (std.mem.eql(u8, command, "init")) return "usage: sa sla init [path]\n";
    if (std.mem.eql(u8, command, "skills")) return "usage: sa sla skills [--json]\n";
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

fn writeCommandHelp(writer: std.io.AnyWriter, command: []const u8) !void {
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
            try writer.writeAll("                          Select test compiler backend; default auto tries SAB first\n");
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

fn parseSlaCliOptionsFrom(args: []const []const u8, command: []const u8, start_idx: usize) !SlaCliOptions {
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

fn parseSlaCliOptions(args: []const []const u8, command: []const u8) !SlaCliOptions {
    return parseSlaCliOptionsFrom(args, command, 3);
}

fn resolveWorkspaceSourcePath(
    allocator: std.mem.Allocator,
    stderr: std.io.AnyWriter,
    package_name: ?[]const u8,
) !?[]u8 {
    var resolution = sla_workspace.resolveFromCurrentDir(allocator, .{ .request = package_name }) catch |err| switch (err) {
        error.FileNotFound => {
            try stderr.writeAll("Error: missing file argument and no workspace source could be resolved from the current directory\n");
            return null;
        },
        error.UnknownPackage => {
            try stderr.print("Error: unknown workspace package: {s}\n", .{package_name orelse ""});
            return null;
        },
        error.MissingDefaultMember => {
            try stderr.writeAll("Error: workspace has no resolvable default member; pass -p/--package or run inside a member directory\n");
            return null;
        },
        error.InvalidFormat => {
            try stderr.writeAll("Error: failed to parse workspace sa.mod\n");
            return null;
        },
        else => return err,
    };
    defer resolution.deinit(allocator);

    return sla_workspace.selectedSourcePath(allocator, &resolution) catch |err| switch (err) {
        error.FileNotFound => {
            try stderr.writeAll("Error: workspace member has no src/main.sla or main.sla entry source\n");
            return null;
        },
        else => return err,
    };
}

fn resolveSlaInputFile(
    allocator: std.mem.Allocator,
    stderr: std.io.AnyWriter,
    options: SlaCliOptions,
) !?[]u8 {
    if (options.source_file) |file| {
        const duped = try allocator.dupe(u8, file);
        return duped;
    }
    return resolveWorkspaceSourcePath(allocator, stderr, options.package_name);
}

fn defaultOutputPath(allocator: std.mem.Allocator, file: []const u8, from_ext: []const u8, to_ext: []const u8) ![]u8 {
    if (std.mem.endsWith(u8, file, from_ext)) {
        return try std.fmt.allocPrint(allocator, "{s}{s}", .{ file[0 .. file.len - from_ext.len], to_ext });
    }
    return try std.fmt.allocPrint(allocator, "{s}{s}", .{ file, to_ext });
}

fn managedSabPath(allocator: std.mem.Allocator, file: []const u8) ![]u8 {
    const base = std.fs.path.basename(file);
    const stem = if (std.mem.endsWith(u8, base, ".sla")) base[0 .. base.len - 4] else base;
    const hash = std.hash.Wyhash.hash(0, file);
    return try std.fmt.allocPrint(allocator, ".sla-cache/sab/{s}-{x}.sab", .{ stem, hash });
}

fn writeSabFile(path: []const u8, sab_bytes: []const u8, stderr: std.io.AnyWriter) !bool {
    if (std.fs.path.dirname(path)) |dir| {
        std.fs.cwd().makePath(dir) catch |err| {
            try stderr.print("File Error: failed to create SAB output directory {s}: {}\n", .{ dir, err });
            return false;
        };
    }
    std.fs.cwd().writeFile(.{ .sub_path = path, .data = sab_bytes }) catch |err| {
        try stderr.print("File Error: failed to write SAB output {s}: {}\n", .{ path, err });
        return false;
    };
    return true;
}

fn writeManagedSab(allocator: std.mem.Allocator, file: []const u8, sab_bytes: []const u8, stderr: std.io.AnyWriter) !?[]u8 {
    const path = try managedSabPath(allocator, file);
    if (!try writeSabFile(path, sab_bytes, stderr)) return null;
    return path;
}

fn parseOutFileArg(args: []const []const u8, start_idx: usize) ?[]const u8 {
    var idx = start_idx;
    while (idx < args.len) : (idx += 1) {
        if (std.mem.eql(u8, args[idx], "--out") or std.mem.eql(u8, args[idx], "-o")) {
            if (idx + 1 < args.len) return args[idx + 1];
            return null;
        }
    }
    return null;
}

fn parseSabOutFileArg(args: []const []const u8, start_idx: usize) ?[]const u8 {
    var idx = start_idx;
    while (idx < args.len) : (idx += 1) {
        if (std.mem.eql(u8, args[idx], "--sab-out")) {
            if (idx + 1 < args.len) return args[idx + 1];
            return null;
        }
    }
    return null;
}

fn hasEmitSabArg(args: []const []const u8, start_idx: usize) bool {
    for (args[start_idx..]) |arg| {
        if (std.mem.eql(u8, arg, "--emit-sab") or std.mem.eql(u8, arg, "--emit-sab-file")) return true;
    }
    return false;
}

fn appendSabWorkspacePassthrough(argv: *std.ArrayList([]const u8), args: []const []const u8) !void {
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
}

fn compileSlaFileToSab(
    allocator: std.mem.Allocator,
    file: []const u8,
    output_file: []const u8,
    stderr: std.io.AnyWriter,
) !?[]u8 {
    return compileSlaFileToSabWithOptions(allocator, file, output_file, stderr, .{});
}

fn compileSlaFileToSabWithOptions(
    allocator: std.mem.Allocator,
    file: []const u8,
    output_file: []const u8,
    stderr: std.io.AnyWriter,
    options: SlaCompileOptions,
) !?[]u8 {
    _ = output_file;
    const profile = slaProfileEnabled(allocator);
    var stage_start = std.time.nanoTimestamp();
    const content = std.fs.cwd().readFileAlloc(allocator, file, 10 * 1024 * 1024) catch |err| {
        try stderr.print("Error: failed to read file {s}: {}\n", .{ file, err });
        return null;
    };
    slaProfileStage(stderr, profile, "read source", stage_start);

    stage_start = std.time.nanoTimestamp();
    const expanded_content = source_expand.expand(allocator, content) catch |err| {
        try stderr.print("Macro Expansion Error: failed to expand tuple templates in {s}: {}\n", .{ file, err });
        return null;
    };
    slaProfileStage(stderr, profile, "source expand", stage_start);

    stage_start = std.time.nanoTimestamp();
    const sla_base_dir = std.fs.path.dirname(file) orelse ".";
    var p = parser_mod.Parser.initWithDir(allocator, expanded_content, sla_base_dir);
    const prog = p.parseProgram() catch |err| {
        try p.printDiagnostic(stderr, file, err);
        return null;
    };
    slaProfileStage(stderr, profile, "parse", stage_start);

    stage_start = std.time.nanoTimestamp();
    var primary_decls = std.AutoHashMap(*const ast.Node, void).init(allocator);
    const expanded_prog = expandSlaImports(allocator, prog, file, &primary_decls) catch |err| {
        try stderr.print("Import Error: failed to expand @import SLA sources: {}\n", .{err});
        return null;
    };
    slaProfileStage(stderr, profile, "import expand", stage_start);

    stage_start = std.time.nanoTimestamp();
    pruneTestsByFilter(allocator, expanded_prog, options.test_filter) catch |err| {
        try stderr.print("Test Filter Error: failed to prune @test declarations: {}\n", .{err});
        return null;
    };
    slaProfileStage(stderr, profile, "test filter prune", stage_start);

    stage_start = std.time.nanoTimestamp();
    var mono = monomorphizer_mod.Monomorphizer.init(allocator);
    defer mono.deinit();
    var specialized_primary_decls = std.AutoHashMap(*const ast.Node, void).init(allocator);
    const specialized_prog = mono.monomorphize(expanded_prog, &primary_decls, &specialized_primary_decls) catch |err| {
        try stderr.print("Monomorphization Error: failed to specialize generics: {}\n", .{err});
        return null;
    };
    slaProfileStage(stderr, profile, "monomorphize", stage_start);

    stage_start = std.time.nanoTimestamp();
    var tc = type_checker_mod.TypeChecker.init(allocator);
    defer tc.deinit();

    loadImportedContracts(&tc, allocator, specialized_prog, file) catch |err| {
        try stderr.print("Import Error: failed to load @import contracts: {}\n", .{err});
        return null;
    };
    slaProfileStage(stderr, profile, "load contracts", stage_start);

    stage_start = std.time.nanoTimestamp();
    tc.checkProgram(specialized_prog) catch |err| {
        try stderr.print("Type Check Error: failed to verify types: {s} ({})\n", .{ tc.last_error, err });
        return null;
    };
    slaProfileStage(stderr, profile, "type check", stage_start);

    stage_start = std.time.nanoTimestamp();
    var filtered_decls = std.ArrayList(*ast.Node).init(allocator);
    for (specialized_prog.program.decls) |decl| {
        if (specialized_primary_decls.contains(decl)) {
            try filtered_decls.append(decl);
        }
    }
    specialized_prog.program.decls = try filtered_decls.toOwnedSlice();
    slaProfileStage(stderr, profile, "primary decl filter", stage_start);

    stage_start = std.time.nanoTimestamp();
    const sab_bytes = sab_codegen_mod.generate(allocator, &tc, specialized_prog) catch |err| {
        if (options.return_unsupported_sab_error and err == sab_codegen_mod.Error.UnsupportedSabDirectFeature) return err;
        try stderr.print("SAB Error: direct SLA to SAB backend cannot compile {s}: {}\n", .{ file, err });
        return null;
    };
    slaProfileStage(stderr, profile, "sab codegen", stage_start);
    return sab_bytes;
}

fn compileSlaFileToSabOrSa(
    allocator: std.mem.Allocator,
    file: []const u8,
    output_file: []const u8,
    stderr: std.io.AnyWriter,
) !?[]u8 {
    return compileSlaFileToSab(allocator, file, output_file, stderr);
}

fn maybeWriteSiblingSab(
    allocator: std.mem.Allocator,
    file: []const u8,
    stderr: std.io.AnyWriter,
) !void {
    const sab_out = try defaultOutputPath(allocator, file, ".sla", ".sab");
    const sab_bytes = (try compileSlaFileToSabOrSa(allocator, file, sab_out, stderr)) orelse return error.InvalidFormat;
    try std.fs.cwd().writeFile(.{ .sub_path = sab_out, .data = sab_bytes });
}

const CompiledTestInput = struct {
    path: []const u8,
    delete_after: bool = false,
};

fn compileSlaSabTestInput(
    allocator: std.mem.Allocator,
    file: []const u8,
    stderr: std.io.AnyWriter,
    extra_args: []const []const u8,
    emit_sab_file: bool,
    return_unsupported_sab_error: bool,
) !?CompiledTestInput {
    const sab_out = try managedSabPath(allocator, file);
    const sab_bytes = (try compileSlaFileToSabWithOptions(allocator, file, sab_out, stderr, .{
        .test_filter = saTestFilterFromArgs(extra_args),
        .return_unsupported_sab_error = return_unsupported_sab_error,
    })) orelse return null;
    if (!try writeSabFile(sab_out, sab_bytes, stderr)) return null;
    if (emit_sab_file) {
        maybeWriteSiblingSab(allocator, file, stderr) catch |err| {
            try stderr.print("File Error: failed to emit sibling SAB for {s}: {}\n", .{ file, err });
            return null;
        };
    }
    return .{ .path = sab_out };
}

fn compileSlaSaTestInput(
    allocator: std.mem.Allocator,
    file: []const u8,
    stderr: std.io.AnyWriter,
    extra_args: []const []const u8,
    emit_sab_file: bool,
) !?CompiledTestInput {
    const sa_out = if (std.mem.endsWith(u8, file, ".sla"))
        try std.fmt.allocPrint(allocator, "{s}.test.sa", .{file[0 .. file.len - 4]})
    else
        try std.fmt.allocPrint(allocator, "{s}.test.sa", .{file});

    const sa_code = (try compileSlaToSaStringWithOptions(allocator, file, sa_out, stderr, .{
        .test_filter = saTestFilterFromArgs(extra_args),
    })) orelse return null;

    std.fs.cwd().writeFile(.{ .sub_path = sa_out, .data = sa_code }) catch |err| {
        try stderr.print("File Error: failed to write {s}: {}\n", .{ sa_out, err });
        return null;
    };
    if (emit_sab_file) {
        maybeWriteSiblingSab(allocator, file, stderr) catch |err| {
            try stderr.print("File Error: failed to emit sibling SAB for {s}: {}\n", .{ file, err });
            return null;
        };
    }
    return .{ .path = sa_out, .delete_after = true };
}

fn runSabBuildCommand(
    args: []const []const u8,
    option_start: usize,
    stdout: std.io.AnyWriter,
    stderr: std.io.AnyWriter,
) !u8 {
    const options = parseSlaCliOptionsFrom(args, "sab build", option_start) catch {
        try writeCommandHelp(stderr, "sab build");
        return 1;
    };
    if (options.help_requested) {
        try writeCommandHelp(stderr, "sab build");
        return 0;
    }

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const file = (try resolveSlaInputFile(allocator, stderr, options)) orelse return 1;
    const managed_out = try managedSabPath(allocator, file);
    const sab_bytes = (try compileSlaFileToSab(allocator, file, managed_out, stderr)) orelse return 1;
    const managed_path = (try writeManagedSab(allocator, file, sab_bytes, stderr)) orelse return 1;

    if (parseOutFileArg(args, option_start)) |final_out| {
        if (!try writeSabFile(final_out, sab_bytes, stderr)) return 1;
        try stdout.print("Sla Compiler: Successfully compiled {s} to SAB {s} (managed cache {s}).\n", .{ file, final_out, managed_path });
    } else {
        try stdout.print("Sla Compiler: Successfully compiled {s} to managed SAB {s}.\n", .{ file, managed_path });
    }
    return 0;
}

fn runSabWorkspaceCommand(
    args: []const []const u8,
    option_start: usize,
    stdout: std.io.AnyWriter,
    stderr: std.io.AnyWriter,
) !u8 {
    _ = stdout;
    const options = parseSlaCliOptionsFrom(args, "sab workspace", option_start) catch {
        try writeCommandHelp(stderr, "sab workspace");
        return 1;
    };
    if (options.help_requested) {
        try writeCommandHelp(stderr, "sab workspace");
        return 0;
    }
    if (options.source_file != null) {
        try stderr.writeAll("Error: sla sab workspace does not accept a source file argument; run it from a workspace root or member directory\n");
        return 1;
    }

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const file = (try resolveWorkspaceSourcePath(allocator, stderr, options.package_name)) orelse return 1;
    const extra_args = args[options.passthrough_start..];
    const managed_out = try managedSabPath(allocator, file);
    const sab_bytes = (try compileSlaFileToSab(allocator, file, managed_out, stderr)) orelse return 1;
    const managed_path = (try writeManagedSab(allocator, file, sab_bytes, stderr)) orelse return 1;

    if (parseSabOutFileArg(args, option_start)) |sab_out| {
        if (!try writeSabFile(sab_out, sab_bytes, stderr)) return 1;
    }
    if (options.emit_sab_file or hasEmitSabArg(args, option_start)) {
        maybeWriteSiblingSab(allocator, file, stderr) catch |err| {
            try stderr.print("File Error: failed to emit sibling SAB for {s}: {}\n", .{ file, err });
            return 1;
        };
    }

    var argv = std.ArrayList([]const u8).init(allocator);
    try argv.append("sa");
    try argv.append("build-exe");
    try argv.append(managed_path);
    try appendSabWorkspacePassthrough(&argv, extra_args);

    var child = std.process.Child.init(argv.items, allocator);
    const term = child.spawnAndWait() catch |err| {
        try stderr.print("Error: failed to run 'sa build-exe' for SAB workspace output: {}\n", .{err});
        return 1;
    };
    return switch (term) {
        .Exited => |code| code,
        else => 1,
    };
}

fn runSabDisasmCommand(
    args: []const []const u8,
    option_start: usize,
    stdout: std.io.AnyWriter,
    stderr: std.io.AnyWriter,
) !u8 {
    if (option_start >= args.len or isHelpArg(args[option_start])) {
        try writeCommandHelp(stderr, "sab disasm");
        return if (option_start < args.len) 0 else 1;
    }

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const file = args[option_start];
    const out_file = parseOutFileArg(args, option_start + 1);

    const sab_bytes = std.fs.cwd().readFileAlloc(allocator, file, 16 * 1024 * 1024) catch |err| {
        try stderr.print("SAB Error: failed to read {s}: {}\n", .{ file, err });
        return 1;
    };

    const text = sci_bridge.disasmSabAlloc(allocator, sab_bytes) catch |err| {
        try stderr.print("SAB Error: failed to disassemble {s}: {}\n", .{ file, err });
        return 1;
    };

    if (out_file) |path| {
        std.fs.cwd().writeFile(.{ .sub_path = path, .data = text }) catch |err| {
            try stderr.print("File Error: failed to write {s}: {}\n", .{ path, err });
            return 1;
        };
        try stdout.print("Disassembled {s} to {s}\n", .{ file, path });
    } else {
        try stdout.writeAll(text);
    }
    return 0;
}

fn runSabCommand(
    args: []const []const u8,
    subcommand_index: usize,
    stdout: std.io.AnyWriter,
    stderr: std.io.AnyWriter,
) !u8 {
    if (subcommand_index >= args.len or isHelpArg(args[subcommand_index])) {
        try writeCommandHelp(stderr, "sab");
        return if (subcommand_index < args.len) 0 else 1;
    }
    const subcmd = args[subcommand_index];
    const option_start = subcommand_index + 1;
    if (std.mem.eql(u8, subcmd, "build")) return try runSabBuildCommand(args, option_start, stdout, stderr);
    if (std.mem.eql(u8, subcmd, "workspace")) return try runSabWorkspaceCommand(args, option_start, stdout, stderr);
    if (std.mem.eql(u8, subcmd, "disasm")) return try runSabDisasmCommand(args, option_start, stdout, stderr);
    try stderr.print("Unknown sla sab command: {s}\n", .{subcmd});
    try writeCommandHelp(stderr, "sab");
    return 1;
}

pub fn runSlaCommandImpl(
    ctx: *const plugin_api.Context,
    args: []const []const u8,
    stdout: std.io.AnyWriter,
    stderr: std.io.AnyWriter,
) !?u8 {
    if (args.len < 2) return null;
    if (std.mem.eql(u8, args[1], "slab")) {
        return try runSabCommand(args, 2, stdout, stderr);
    }
    if (!std.mem.eql(u8, args[1], "sla")) return null;
    if (args.len < 3) {
        try stderr.writeAll("usage: sa sla <command> [options]\n");
        return 1;
    }
    const cmd = args[2];
    if (std.mem.eql(u8, cmd, "help")) {
        try stderr.writeAll("usage: sa sla <command> [options]\n\n");
        try stderr.writeAll("Commands:\n");
        try stderr.writeAll("  init       [path]\n");
        try stderr.writeAll("  skills     [--json]\n");
        try stderr.writeAll("  build      [file] [-p <package>] [--out <file>]\n");
        try stderr.writeAll("  build-workspace [-p <package>] [sa-build-exe args]\n");
        try stderr.writeAll("  build-exe  [file] [-p <package>] [sa-build-exe args]\n");
        try stderr.writeAll("  sab build  [file] [-p <package>] [--out <file.sab>]\n");
        try stderr.writeAll("  sab workspace [-p <package>] [--sab-out <file.sab>] [sa-build-exe args]\n");
        try stderr.writeAll("  sab disasm <file.sab> [--out <file.sa>]\n");
        try stderr.writeAll("  slab build|workspace|disasm ...    Short alias\n");
        try stderr.writeAll("  check      [file] [-p <package>]\n");
        try stderr.writeAll("  test       [file] [-p <package>] [--test-backend auto|sab|sa] [sa-test args]\n");
        return 0;
    }
    if (std.mem.eql(u8, cmd, "init")) {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        return try runSlaInitCommand(arena.allocator(), args, 3, stdout, stderr);
    }
    if (std.mem.eql(u8, cmd, "skills")) {
        return try runSlaSkillsCommand(args, 3, stdout, stderr, ctx.json_mode);
    }
    if (std.mem.eql(u8, cmd, "sab")) {
        return try runSabCommand(args, 3, stdout, stderr);
    }
    if (std.mem.eql(u8, cmd, "build")) {
        const options = parseSlaCliOptions(args, cmd) catch {
            try writeCommandHelp(stderr, cmd);
            return 1;
        };
        if (options.help_requested) {
            try writeCommandHelp(stderr, cmd);
            return 0;
        }

        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        const file = (try resolveSlaInputFile(allocator, stderr, options)) orelse return 1;

        var out_file: ?[]const u8 = null;
        var idx: usize = options.passthrough_start;
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

        const sa_code = (try compileSlaToSaString(allocator, file, final_out, stderr)) orelse return 1;

        std.fs.cwd().writeFile(.{ .sub_path = final_out, .data = sa_code }) catch |err| {
            try stderr.print("File Error: failed to write output {s}: {}\n", .{ final_out, err });
            return 1;
        };

        try stdout.print("Sla Compiler: Successfully compiled {s} to {s}.\n", .{ file, final_out });
        return 0;
    } else if (std.mem.eql(u8, cmd, "build-exe")) {
        const options = parseSlaCliOptions(args, cmd) catch {
            try writeCommandHelp(stderr, cmd);
            return 1;
        };
        if (options.help_requested) {
            try writeCommandHelp(stderr, cmd);
            return 0;
        }

        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        const file = (try resolveSlaInputFile(allocator, stderr, options)) orelse return 1;
        const extra_args = args[options.passthrough_start..];

        const sab_out = try managedSabPath(allocator, file);
        const sab_bytes = (try compileSlaFileToSabOrSa(allocator, file, sab_out, stderr)) orelse return 1;
        if (!try writeSabFile(sab_out, sab_bytes, stderr)) return 1;
        if (options.emit_sab_file) {
            maybeWriteSiblingSab(allocator, file, stderr) catch |err| {
                try stderr.print("File Error: failed to emit sibling SAB for {s}: {}\n", .{ file, err });
                return 1;
            };
        }

        var argv = std.ArrayList([]const u8).init(allocator);
        try argv.append("sa");
        try argv.append("build-exe");
        try argv.append(sab_out);
        for (extra_args) |a| try argv.append(a);

        var child = std.process.Child.init(argv.items, allocator);
        const term = child.spawnAndWait() catch |err| {
            try stderr.print("Error: failed to run 'sa build-exe': {}\n", .{err});
            return 1;
        };
        return switch (term) {
            .Exited => |code| code,
            else => 1,
        };
    } else if (std.mem.eql(u8, cmd, "build-workspace")) {
        const options = parseSlaCliOptions(args, cmd) catch {
            try writeCommandHelp(stderr, cmd);
            return 1;
        };
        if (options.help_requested) {
            try writeCommandHelp(stderr, cmd);
            return 0;
        }

        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        if (options.source_file != null) {
            try stderr.writeAll("Error: sla build-workspace does not accept a source file argument; run it from a workspace root or member directory\n");
            return 1;
        }

        const file = (try resolveWorkspaceSourcePath(allocator, stderr, options.package_name)) orelse return 1;
        const extra_args = args[options.passthrough_start..];

        const sab_out = try managedSabPath(allocator, file);
        const sab_bytes = (try compileSlaFileToSabOrSa(allocator, file, sab_out, stderr)) orelse return 1;
        if (!try writeSabFile(sab_out, sab_bytes, stderr)) return 1;
        if (options.emit_sab_file) {
            maybeWriteSiblingSab(allocator, file, stderr) catch |err| {
                try stderr.print("File Error: failed to emit sibling SAB for {s}: {}\n", .{ file, err });
                return 1;
            };
        }

        var argv = std.ArrayList([]const u8).init(allocator);
        try argv.append("sa");
        try argv.append("build-exe");
        try argv.append(sab_out);
        for (extra_args) |a| try argv.append(a);

        var child = std.process.Child.init(argv.items, allocator);
        const term = child.spawnAndWait() catch |err| {
            try stderr.print("Error: failed to run 'sa build-exe': {}\n", .{err});
            return 1;
        };
        return switch (term) {
            .Exited => |code| code,
            else => 1,
        };
    } else if (std.mem.eql(u8, cmd, "check")) {
        const options = parseSlaCliOptions(args, cmd) catch {
            try writeCommandHelp(stderr, cmd);
            return 1;
        };
        if (options.help_requested) {
            try writeCommandHelp(stderr, cmd);
            return 0;
        }

        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        const file = (try resolveSlaInputFile(allocator, stderr, options)) orelse return 1;

        const content = std.fs.cwd().readFileAlloc(allocator, file, 10 * 1024 * 1024) catch |err| {
            try stderr.print("Error: failed to read file {s}: {}\n", .{ file, err });
            return 1;
        };

        const expanded_content = source_expand.expand(allocator, content) catch |err| {
            try stderr.print("Macro Expansion Error: failed to expand tuple templates in {s}: {}\n", .{ file, err });
            return 1;
        };

        const sla_base_dir = std.fs.path.dirname(file) orelse ".";
        var p = parser_mod.Parser.initWithDir(allocator, expanded_content, sla_base_dir);
        const prog = p.parseProgram() catch |err| {
            try p.printDiagnostic(stderr, file, err);
            return 1;
        };

        var primary_decls = std.AutoHashMap(*const ast.Node, void).init(allocator);
        const expanded_prog = expandSlaImports(allocator, prog, file, &primary_decls) catch |err| {
            try stderr.print("Import Error: failed to expand @import SLA sources: {}\n", .{err});
            return 1;
        };

        var mono = monomorphizer_mod.Monomorphizer.init(allocator);
        defer mono.deinit();
        var specialized_primary_decls = std.AutoHashMap(*const ast.Node, void).init(allocator);
        const specialized_prog = mono.monomorphize(expanded_prog, &primary_decls, &specialized_primary_decls) catch |err| {
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
            try stderr.print("Type Check Error: failed to verify types: {s} ({})\n", .{ tc.last_error, err });
            return 1;
        };

        try stdout.print("Sla Compiler: Successfully parsed and verified syntax and types of {s}.\n", .{file});
        return 0;
    } else if (std.mem.eql(u8, cmd, "test")) {
        const options = parseSlaCliOptions(args, cmd) catch {
            try writeCommandHelp(stderr, cmd);
            return 1;
        };
        if (options.help_requested) {
            try writeCommandHelp(stderr, cmd);
            return 0;
        }

        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        const file = (try resolveSlaInputFile(allocator, stderr, options)) orelse return 1;
        const extra_args = args[options.passthrough_start..];
        const backend = parseTestBackendFromArgs(extra_args, options.test_backend) catch {
            try writeCommandHelp(stderr, cmd);
            return 1;
        };

        const test_input = switch (backend) {
            .auto => (compileSlaSabTestInput(allocator, file, stderr, extra_args, options.emit_sab_file, true) catch |err| switch (err) {
                error.UnsupportedSabDirectFeature => try compileSlaSaTestInput(allocator, file, stderr, extra_args, options.emit_sab_file),
                else => return err,
            }) orelse return 1,
            .sab => (try compileSlaSabTestInput(allocator, file, stderr, extra_args, options.emit_sab_file, false)) orelse return 1,
            .sa => (try compileSlaSaTestInput(allocator, file, stderr, extra_args, options.emit_sab_file)) orelse return 1,
        };
        defer {
            if (test_input.delete_after) std.fs.cwd().deleteFile(test_input.path) catch {};
        }

        var argv = std.ArrayList([]const u8).init(allocator);
        try argv.append("sa");
        try argv.append("test");
        try argv.append(test_input.path);
        appendSaTestPassthrough(&argv, extra_args) catch {
            try writeCommandHelp(stderr, cmd);
            return 1;
        };

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

test "sla_compile_handler C ABI lowers state handler" {
    const handler_name = "inc";
    const handler_source =
        \\fn inc() {
        \\  count = count + 1;
        \\  render();
        \\}
    ;
    const field_name = "count";
    const field_address = "state+Counter_count";
    const fields = [_]SlaHandlerStateFieldAbi{.{
        .name_ptr = field_name.ptr,
        .name_len = field_name.len,
        .ty = 3,
        .address_ptr = field_address.ptr,
        .address_len = field_address.len,
    }};

    var result: SlaCompileHandlerResultAbi = .{};
    const status = sla_compile_handler(
        handler_name.ptr,
        handler_name.len,
        handler_source.ptr,
        handler_source.len,
        fields[0..].ptr,
        fields.len,
        null,
        &result,
    );
    defer sla_compile_handler_result_free(&result);

    try std.testing.expectEqual(@as(u32, 0), status);
    const body_ptr = result.body_ptr orelse return error.TestUnexpectedResult;
    const body = body_ptr[0..result.body_len];
    try std.testing.expect(std.mem.containsAtLeast(u8, body, 1, "state+Counter_count"));
    try std.testing.expect(std.mem.containsAtLeast(u8, body, 1, "call @render()"));
}

test "sla skills emits json capability list" {
    var stdout_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stdout_buf.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    var ctx = plugin_api.Context{ .allocator = std.testing.allocator };
    const args = [_][]const u8{ "sa", "sla", "skills", "--json" };
    const code = try runSlaCommandImpl(&ctx, args[0..], stdout_buf.writer().any(), stderr_buf.writer().any());

    try std.testing.expectEqual(@as(?u8, 0), code);
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buf.items, 1, "\"status\":\"ok\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buf.items, 1, "sla init [path]"));
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buf.items, 1, "sla sab build"));
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
}

test "sla skills honors host json mode" {
    var stdout_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stdout_buf.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    var ctx = plugin_api.Context{ .allocator = std.testing.allocator, .json_mode = true };
    const args = [_][]const u8{ "sa", "sla", "skills" };
    const code = try runSlaCommandImpl(&ctx, args[0..], stdout_buf.writer().any(), stderr_buf.writer().any());

    try std.testing.expectEqual(@as(?u8, 0), code);
    try std.testing.expect(std.mem.startsWith(u8, stdout_buf.items, "{\"status\":\"ok\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buf.items, 1, "sla skills [--json]"));
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
}

test "sla skills text writes agent skill files" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var stdout_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stdout_buf.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    var ctx = plugin_api.Context{ .allocator = std.testing.allocator };
    const args = [_][]const u8{ "sa", "sla", "skills" };
    const code = try runSlaCommandImpl(&ctx, args[0..], stdout_buf.writer().any(), stderr_buf.writer().any());

    try std.testing.expectEqual(@as(?u8, 0), code);
    try tmp.dir.access(".codex/skills/sla/SKILL.md", .{});
    try tmp.dir.access(".claude/skills/sla/SKILL.md", .{});
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buf.items, 1, "generated agent skills"));
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buf.items, 1, "sla skills [--json]"));
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
}

test "sla init scaffolds project without overwriting" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var stdout_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stdout_buf.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    var ctx = plugin_api.Context{ .allocator = std.testing.allocator };
    const args = [_][]const u8{ "sa", "sla", "init", "demo_app" };
    const code = try runSlaCommandImpl(&ctx, args[0..], stdout_buf.writer().any(), stderr_buf.writer().any());

    try std.testing.expectEqual(@as(?u8, 0), code);
    try tmp.dir.access("demo_app/sa.mod", .{});
    try tmp.dir.access("demo_app/src/main.sla", .{});
    try tmp.dir.access("demo_app/.gitignore", .{});

    const manifest = try tmp.dir.readFileAlloc(std.testing.allocator, "demo_app/sa.mod", 1024);
    defer std.testing.allocator.free(manifest);
    try std.testing.expect(std.mem.containsAtLeast(u8, manifest, 1, "package \"demo_app\""));

    const gitignore = try tmp.dir.readFileAlloc(std.testing.allocator, "demo_app/.gitignore", 1024);
    defer std.testing.allocator.free(gitignore);
    try std.testing.expect(std.mem.containsAtLeast(u8, gitignore, 1, ".sla-cache/"));

    const second_code = try runSlaCommandImpl(&ctx, args[0..], stdout_buf.writer().any(), stderr_buf.writer().any());
    try std.testing.expectEqual(@as(?u8, 1), second_code);
}

fn expectSlaCheckRedeclarationDiagnostic(file: []const u8, expected: []const u8) !void {
    var stdout_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stdout_buf.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    var ctx = plugin_api.Context{ .allocator = std.testing.allocator };
    const args = [_][]const u8{ "sa", "sla", "check", file };
    const code = try runSlaCommandImpl(&ctx, args[0..], stdout_buf.writer().any(), stderr_buf.writer().any());

    try std.testing.expectEqual(@as(?u8, 1), code);
    try std.testing.expect(std.mem.containsAtLeast(u8, stderr_buf.items, 1, "Type Check Error"));
    try std.testing.expect(std.mem.containsAtLeast(u8, stderr_buf.items, 1, "Redeclaration"));
    try std.testing.expect(std.mem.containsAtLeast(u8, stderr_buf.items, 1, expected));
}

fn expectSlaCheckSyntaxDiagnostic(file: []const u8, expected: []const u8) !void {
    var stdout_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stdout_buf.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    var ctx = plugin_api.Context{ .allocator = std.testing.allocator };
    const args = [_][]const u8{ "sa", "sla", "check", file };
    const code = try runSlaCommandImpl(&ctx, args[0..], stdout_buf.writer().any(), stderr_buf.writer().any());

    try std.testing.expectEqual(@as(?u8, 1), code);
    try std.testing.expect(std.mem.containsAtLeast(u8, stderr_buf.items, 1, "Syntax Error"));
    try std.testing.expect(std.mem.containsAtLeast(u8, stderr_buf.items, 1, expected));
}

test "sla check reports redeclared symbol names" {
    try expectSlaCheckRedeclarationDiagnostic("tests/test_error_redeclaration.sla", "symbol `value`");
    try expectSlaCheckRedeclarationDiagnostic("tests/test_error_redeclaration_const.sla", "symbol `value`");
    try expectSlaCheckRedeclarationDiagnostic("tests/test_error_redeclaration_top_const.sla", "symbol `LIMIT`");
    try expectSlaCheckRedeclarationDiagnostic("tests/test_error_redeclaration_param.sla", "symbol `value`");
    try expectSlaCheckRedeclarationDiagnostic("tests/test_error_redeclaration_closure_param.sla", "symbol `value`");
    try expectSlaCheckRedeclarationDiagnostic("tests/test_error_redeclaration_macro_param.sla", "symbol `value`");
    try expectSlaCheckRedeclarationDiagnostic("tests/test_error_redeclaration_function.sla", "function `repeated`");
    try expectSlaCheckRedeclarationDiagnostic("tests/test_error_redeclaration_const_function.sla", "const `repeated_value`");
    try expectSlaCheckRedeclarationDiagnostic("tests/test_error_redeclaration_struct.sla", "struct `Repeated`");
    try expectSlaCheckRedeclarationDiagnostic("tests/test_error_redeclaration_enum.sla", "enum `RepeatedEnum`");
    try expectSlaCheckRedeclarationDiagnostic("tests/test_error_redeclaration_trait.sla", "trait `RepeatedTrait`");
    try expectSlaCheckRedeclarationDiagnostic("tests/test_error_redeclaration_macro.sla", "macro `repeated_macro`");
    try expectSlaCheckRedeclarationDiagnostic("tests/test_error_redeclaration_method.sla", "method `score` for `RepeatedMethod`");
    try expectSlaCheckSyntaxDiagnostic("tests/test_error_bare_overload.sla", "found 'overload'");
}

test "sla build rewrites sla imports relative to final output path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    const sa_code = (try compileSlaToSaString(
        arena.allocator(),
        "tests/import_fixtures/output_relative/main.sla",
        "tests/output_relative_root.sa",
        stderr_buf.writer().any(),
    )) orelse {
        std.debug.print("{s}", .{stderr_buf.items});
        return error.TestUnexpectedResult;
    };

    try std.testing.expect(std.mem.indexOf(u8, sa_code, "@import \"import_fixtures/output_relative/local_dep.sa\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sa_code, "@import \"helper.sa\"") == null);
}

test "sla test filter prunes unmatched tests before type checking" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const filtered_source =
        \\fn value() -> i32 {
        \\    return 1;
        \\};
        \\
        \\@test "keep this test"() {
        \\    let x = value();
        \\    if x != 1 { panic(24001); };
        \\};
        \\
        \\@test "drop broken test"() {
        \\    missing_symbol();
        \\};
    ;
    try tmp.dir.writeFile(.{ .sub_path = "filtered.sla", .data = filtered_source });

    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    const sa_code = (try compileSlaToSaStringWithOptions(
        arena.allocator(),
        "filtered.sla",
        "filtered.test.sa",
        stderr_buf.writer().any(),
        .{ .test_filter = "keep this" },
    )) orelse {
        std.debug.print("{s}", .{stderr_buf.items});
        return error.TestUnexpectedResult;
    };

    try std.testing.expect(std.mem.indexOf(u8, sa_code, "keep this test") != null);
    try std.testing.expect(std.mem.indexOf(u8, sa_code, "drop broken test") == null);
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
}

test "sla test sab backend prunes unmatched tests before type checking" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const filtered_sab_source =
        \\fn value() -> i32 {
        \\    return 2;
        \\};
        \\
        \\@test "sab keep"() {
        \\    let x = value();
        \\    if x != 2 { panic(24002); };
        \\};
        \\
        \\@test "sab drop broken"() {
        \\    missing_symbol();
        \\};
    ;
    try tmp.dir.writeFile(.{ .sub_path = "filtered_sab.sla", .data = filtered_sab_source });

    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    const sab_bytes = (try compileSlaFileToSabWithOptions(
        arena.allocator(),
        "filtered_sab.sla",
        ".sla-cache/sab/filtered_sab.sab",
        stderr_buf.writer().any(),
        .{ .test_filter = "sab keep" },
    )) orelse {
        std.debug.print("{s}", .{stderr_buf.items});
        return error.TestUnexpectedResult;
    };

    var module = try sci_bridge.sab.decodeModule(std.testing.allocator, sab_bytes);
    defer module.deinit(std.testing.allocator);

    var test_count: usize = 0;
    for (module.function_sigs) |fsig| {
        if (fsig.kind == .test_func) test_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), test_count);
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
}

test "sla sab build emits direct SAB without SA source output" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const direct_source =
        \\fn add(a: i32, b: i32) -> i32 {
        \\    let c = a + b;
        \\    return c;
        \\};
        \\
        \\fn main() -> i32 {
        \\    let x = add(2, 3);
        \\    return x;
        \\};
    ;
    try tmp.dir.writeFile(.{ .sub_path = "direct.sla", .data = direct_source });

    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var stdout_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stdout_buf.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    var ctx = plugin_api.Context{ .allocator = std.testing.allocator };
    const args = [_][]const u8{ "sa", "sla", "sab", "build", "direct.sla", "--out", "direct.sab" };
    const code = try runSlaCommandImpl(&ctx, args[0..], stdout_buf.writer().any(), stderr_buf.writer().any());

    if (code != @as(?u8, 0)) std.debug.print("{s}", .{stderr_buf.items});
    try std.testing.expectEqual(@as(?u8, 0), code);
    try tmp.dir.access("direct.sab", .{});
    try std.testing.expectError(error.FileNotFound, tmp.dir.access("direct.sa", .{}));

    const sab_bytes = try tmp.dir.readFileAlloc(std.testing.allocator, "direct.sab", 1024 * 1024);
    defer std.testing.allocator.free(sab_bytes);
    try std.testing.expect(std.mem.startsWith(u8, sab_bytes, sci_bridge.sab.magic));
    try std.testing.expect(std.mem.indexOf(u8, sab_bytes, "tmp_0 = add") == null);
    try std.testing.expect(std.mem.indexOf(u8, sab_bytes, "return tmp_") == null);

    var module = try sci_bridge.sab.decodeModule(std.testing.allocator, sab_bytes);
    defer module.deinit(std.testing.allocator);

    try std.testing.expect(module.function_sigs.len >= 2);
    var saw_func_decl = false;
    var saw_add_op = false;
    var saw_call = false;
    var saw_return = false;
    for (module.instructions) |item| {
        switch (item.kind) {
            .func_decl => saw_func_decl = true,
            .op => {
                if (item.op_kind == .add) saw_add_op = true;
            },
            .call => saw_call = true,
            .return_ => saw_return = true,
            else => {},
        }
    }
    try std.testing.expect(saw_func_decl);
    try std.testing.expect(saw_add_op);
    try std.testing.expect(saw_call);
    try std.testing.expect(saw_return);
}

test "sla sab build defaults to managed sla cache" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const direct_source =
        \\fn main() -> i32 {
        \\    return 5;
        \\};
    ;
    try tmp.dir.writeFile(.{ .sub_path = "direct.sla", .data = direct_source });

    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var stdout_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stdout_buf.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    var ctx = plugin_api.Context{ .allocator = std.testing.allocator };
    const args = [_][]const u8{ "sa", "sla", "sab", "build", "direct.sla" };
    const code = try runSlaCommandImpl(&ctx, args[0..], stdout_buf.writer().any(), stderr_buf.writer().any());

    if (code != @as(?u8, 0)) std.debug.print("{s}", .{stderr_buf.items});
    try std.testing.expectEqual(@as(?u8, 0), code);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access("direct.sab", .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access("direct.sa", .{}));

    const cached_path = try managedSabPath(std.testing.allocator, "direct.sla");
    defer std.testing.allocator.free(cached_path);
    try tmp.dir.access(cached_path, .{});
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buf.items, 1, ".sla-cache/sab/"));

    const sab_bytes = try tmp.dir.readFileAlloc(std.testing.allocator, cached_path, 1024 * 1024);
    defer std.testing.allocator.free(sab_bytes);
    try std.testing.expect(std.mem.startsWith(u8, sab_bytes, sci_bridge.sab.magic));
}

fn writeWorkspaceFixture(dir: std.fs.Dir, default_member: []const u8, tool_source: []const u8) !void {
    try dir.makePath("members/app/src");
    try dir.makePath("members/tool/src");

    const root_manifest = if (std.mem.eql(u8, default_member, "tool"))
        \\workspace {
        \\  members ["members/app", "members/tool"]
        \\  default_member "tool"
        \\}
    else
        \\workspace {
        \\  members ["members/app", "members/tool"]
        \\  default_member "app"
        \\}
    ;
    try dir.writeFile(.{ .sub_path = "sa.mod", .data = root_manifest });
    try dir.writeFile(.{ .sub_path = "members/app/sa.mod", .data = "package \"app\"\n" });
    try dir.writeFile(.{ .sub_path = "members/tool/sa.mod", .data = "package \"tool\"\n" });
    try dir.writeFile(.{ .sub_path = "members/app/src/main.sla", .data = 
        \\fn main() -> i32 {
        \\    return 7;
        \\};
    });
    try dir.writeFile(.{ .sub_path = "members/tool/src/main.sla", .data = tool_source });
}

test "sla build resolves workspace default member when file omitted" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try writeWorkspaceFixture(tmp.dir, "app",
        \\fn main() -> i32 {
        \\    return 9;
        \\};
    );

    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var stdout_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stdout_buf.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    var ctx = plugin_api.Context{ .allocator = std.testing.allocator };
    const args = [_][]const u8{ "sa", "sla", "build" };
    const code = try runSlaCommandImpl(&ctx, args[0..], stdout_buf.writer().any(), stderr_buf.writer().any());

    try std.testing.expectEqual(@as(?u8, 0), code);
    try tmp.dir.access("members/app/src/main.sa", .{});
    try std.testing.expectError(error.FileNotFound, tmp.dir.access("members/tool/src/main.sa", .{}));
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buf.items, 1, "members/app/src/main.sla"));
}

test "sla check prefers current member over workspace default" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try writeWorkspaceFixture(tmp.dir, "tool",
        \\fn broken( {
    );

    var member_dir = try tmp.dir.openDir("members/app/src", .{});
    defer member_dir.close();
    try member_dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var stdout_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stdout_buf.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    var ctx = plugin_api.Context{ .allocator = std.testing.allocator };
    const args = [_][]const u8{ "sa", "sla", "check" };
    const code = try runSlaCommandImpl(&ctx, args[0..], stdout_buf.writer().any(), stderr_buf.writer().any());

    try std.testing.expectEqual(@as(?u8, 0), code);
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buf.items, 1, "members/app/src/main.sla"));
}

test "sla build selects workspace package with -p when file omitted" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try writeWorkspaceFixture(tmp.dir, "app",
        \\fn main() -> i32 {
        \\    return 9;
        \\};
    );

    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var stdout_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stdout_buf.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    var ctx = plugin_api.Context{ .allocator = std.testing.allocator };
    const args = [_][]const u8{ "sa", "sla", "build", "-p", "tool" };
    const code = try runSlaCommandImpl(&ctx, args[0..], stdout_buf.writer().any(), stderr_buf.writer().any());

    try std.testing.expectEqual(@as(?u8, 0), code);
    try tmp.dir.access("members/tool/src/main.sa", .{});
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buf.items, 1, "members/tool/src/main.sla"));
}
