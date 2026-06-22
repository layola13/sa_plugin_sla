const std = @import("std");
const plugin_api = @import("plugin_api");
const ast = @import("ast.zig");
const parser_mod = @import("parser.zig");
const monomorphizer_mod = @import("monomorphizer.zig");
const type_checker_mod = @import("type_checker.zig");
const codegen_mod = @import("codegen.zig");
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
            "sla build <file> [--out <file>]",
            "sla build-exe <file> [sa-build-exe-options...]",
            "sla check <file>",
            "sla test <file> [sa-test-options...]",
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

    if (isSaStdImport(raw_import_path)) return error.FileNotFound;

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
        var parser = parser_mod.Parser.initWithDir(allocator, resolved.source, imported_base_dir);
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
    if (try normalizedSaStdImportPath(allocator, raw_import_path)) |std_path| return std_path;

    const source_dir = std.fs.path.dirname(source_file) orelse ".";
    const resolved = try resolveImportFile(allocator, source_dir, raw_import_path);
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
        var lines = std.mem.splitScalar(u8, resolved.source, '\n');
        while (lines.next()) |line| {
            if (importPathFromLine(line)) |child_import| {
                try loadImportContractsRecursive(tc, allocator, import_dir, child_import, resolved.path, visited);
            }
        }

        if (std.mem.endsWith(u8, resolved.path, ".sai")) {
            try tc.loadContracts(resolved.source, "");
        } else if (std.mem.endsWith(u8, resolved.path, ".sal")) {
            try tc.loadContracts("", resolved.source);
        }
        try loadImportedMacros(tc, allocator, resolved.source);
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

fn compileSlaToSaString(
    allocator: std.mem.Allocator,
    file: []const u8,
    output_file: ?[]const u8,
    stderr: std.io.AnyWriter,
) !?[]const u8 {
    const content = std.fs.cwd().readFileAlloc(allocator, file, 10 * 1024 * 1024) catch |err| {
        try stderr.print("Error: failed to read file {s}: {}\n", .{ file, err });
        return null;
    };

    const sla_base_dir = std.fs.path.dirname(file) orelse ".";
    var p = parser_mod.Parser.initWithDir(allocator, content, sla_base_dir);
    const prog = p.parseProgram() catch |err| {
        try stderr.print("Syntax Error: failed to parse {s}: {}\n", .{ file, err });
        return null;
    };

    var primary_decls = std.AutoHashMap(*const ast.Node, void).init(allocator);
    const expanded_prog = expandSlaImports(allocator, prog, file, &primary_decls) catch |err| {
        try stderr.print("Import Error: failed to expand @import SLA sources: {}\n", .{err});
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

        const sa_code = (try compileSlaToSaString(allocator, file, final_out, stderr)) orelse return 1;

        std.fs.cwd().writeFile(.{ .sub_path = final_out, .data = sa_code }) catch |err| {
            try stderr.print("File Error: failed to write output {s}: {}\n", .{ final_out, err });
            return 1;
        };

        try stdout.print("Sla Compiler: Successfully compiled {s} to {s}.\n", .{ file, final_out });
        return 0;
    } else if (std.mem.eql(u8, cmd, "build-exe")) {
        if (args.len < 4) {
            try stderr.writeAll("Error: missing file argument for 'sla build-exe'\n");
            return 1;
        }
        const file = args[3];
        const extra_args = args[4..];

        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        const sa_out = if (std.mem.endsWith(u8, file, ".sla"))
            try std.fmt.allocPrint(allocator, "{s}.build.sa", .{file[0 .. file.len - 4]})
        else
            try std.fmt.allocPrint(allocator, "{s}.build.sa", .{file});

        const sa_code = (try compileSlaFileToSa(allocator, file, sa_out, stderr)) orelse return 1;
        std.fs.cwd().writeFile(.{ .sub_path = sa_out, .data = sa_code }) catch |err| {
            try stderr.print("File Error: failed to write {s}: {}\n", .{ sa_out, err });
            return 1;
        };
        defer std.fs.cwd().deleteFile(sa_out) catch {};

        var argv = std.ArrayList([]const u8).init(allocator);
        try argv.append("sa");
        try argv.append("build-exe");
        try argv.append(sa_out);
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
        if (args.len < 4) {
            try stderr.writeAll("Error: missing file argument for 'sla check'\n");
            return 1;
        }
        const file = args[3];

        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        const content = std.fs.cwd().readFileAlloc(allocator, file, 10 * 1024 * 1024) catch |err| {
            try stderr.print("Error: failed to read file {s}: {}\n", .{ file, err });
            return 1;
        };

        const sla_base_dir = std.fs.path.dirname(file) orelse ".";
        var p = parser_mod.Parser.initWithDir(allocator, content, sla_base_dir);
        const prog = p.parseProgram() catch |err| {
            try stderr.print("Syntax Error: failed to parse {s}: {}\n", .{ file, err });
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

        const sa_code = (try compileSlaToSaString(allocator, file, sa_out, stderr)) orelse return 1;

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
