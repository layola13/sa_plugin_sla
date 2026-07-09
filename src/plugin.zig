const std = @import("std");
const plugin_api = @import("plugin_api");
const ast = @import("ast.zig");
const parser_mod = @import("parser.zig");
const monomorphizer_mod = @import("monomorphizer.zig");
const type_checker_mod = @import("type_checker.zig");
const codegen_mod = @import("codegen.zig");
const sab_codegen_mod = @import("sab_codegen.zig");
const stability_metadata = @import("stability_metadata.zig");
const source_expand = @import("source_expand.zig");
const sla_workspace = @import("workspace.zig");
const lowering_rules = @import("lowering_rules.zig");
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
            "sla stability schema|verify ...",
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

const ResolvedModuleImport = struct {
    namespace: []const u8,
    resolved: ResolvedImport,
};

fn moduleNamespaceFromImportPath(allocator: std.mem.Allocator, import_path: []const u8) ![]const u8 {
    const base = std.fs.path.basename(import_path);
    const stem = if (std.mem.lastIndexOfScalar(u8, base, '.')) |dot| base[0..dot] else base;
    return try allocator.dupe(u8, stem);
}

fn moduleNamespaceMatchesImportPath(import_path: []const u8, namespace: []const u8) bool {
    const base = std.fs.path.basename(import_path);
    const stem = if (std.mem.lastIndexOfScalar(u8, base, '.')) |dot| base[0..dot] else base;
    return std.mem.eql(u8, stem, namespace);
}

const ImportedMangledSymbol = struct {
    namespace: []const u8,
    name: []const u8,
};

fn splitImportedMangledSymbol(symbol: []const u8) ?ImportedMangledSymbol {
    const sep = std.mem.indexOf(u8, symbol, "__") orelse return null;
    if (sep == 0 or sep + 2 >= symbol.len) return null;
    return .{
        .namespace = symbol[0..sep],
        .name = symbol[sep + 2 ..],
    };
}

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

fn macroParamIndex(param_names: []const []const u8, name: []const u8) ?usize {
    for (param_names, 0..) |param, idx| {
        if (std.mem.eql(u8, param, name)) return idx;
    }
    return null;
}

fn markBorrowedParam(mask: *u64, param_names: []const []const u8, raw_name: []const u8) void {
    const name = macroParamName(raw_name);
    if (macroParamIndex(param_names, name)) |idx| {
        if (idx < 64) mask.* |= (@as(u64, 1) << @intCast(idx));
    }
}

fn markDirectBorrowedMacroParams(allocator: std.mem.Allocator, mask: *u64, param_names: []const []const u8, line: []const u8) !void {
    for (param_names) |param| {
        const needle = try std.fmt.allocPrint(allocator, "&%{s}", .{param});
        defer allocator.free(needle);
        if (std.mem.indexOf(u8, line, needle) != null) markBorrowedParam(mask, param_names, param);
    }
}

fn markDirectAddressSlotMacroParams(allocator: std.mem.Allocator, mask: *u64, param_names: []const []const u8, line: []const u8) !void {
    for (param_names) |param| {
        const needle = try std.fmt.allocPrint(allocator, "%{s}+", .{param});
        defer allocator.free(needle);
        if (std.mem.indexOf(u8, line, needle) != null) markBorrowedParam(mask, param_names, param);
    }
}

fn markExpandedImportedMacroParamMasks(
    tc: *type_checker_mod.TypeChecker,
    borrowed_mask: *u64,
    address_slot_mask: *u64,
    param_names: []const []const u8,
    line: []const u8,
) void {
    if (!std.mem.startsWith(u8, line, "EXPAND")) return;
    var parts = std.mem.tokenizeAny(u8, line["EXPAND".len..], " \t,");
    const expanded_name = parts.next() orelse return;
    const expanded = tc.imported_macros.get(expanded_name) orelse return;

    var arg_idx: usize = 0;
    while (parts.next()) |raw_arg| : (arg_idx += 1) {
        if (arg_idx >= 64) continue;
        const trimmed = std.mem.trim(u8, raw_arg, " \t\r,");
        if (trimmed.len == 0 or trimmed[0] != '%') continue;
        const arg_bit = @as(u64, 1) << @intCast(arg_idx);
        if ((expanded.borrowed_arg_mask & arg_bit) != 0) markBorrowedParam(borrowed_mask, param_names, trimmed);
        if ((expanded.address_slot_arg_mask & arg_bit) != 0) markBorrowedParam(address_slot_mask, param_names, trimmed);
    }
}

fn importedMacroCalleeName(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n\"");
    const without_at = if (std.mem.startsWith(u8, trimmed, "@")) trimmed[1..] else trimmed;
    const source_name = if (std.mem.startsWith(u8, without_at, "sla__")) without_at["sla__".len..] else without_at;
    return try allocator.dupe(u8, source_name);
}

fn appendUniqueDirectCallee(callees: *std.ArrayList([]const u8), name: []const u8) !void {
    for (callees.items) |existing| {
        if (std.mem.eql(u8, existing, name)) return;
    }
    try callees.append(name);
}

fn collectDirectSlaMacroCallees(allocator: std.mem.Allocator, callees: *std.ArrayList([]const u8), line: []const u8) !void {
    var rest = line;
    while (std.mem.indexOf(u8, rest, "call @")) |idx| {
        const start = idx + "call @".len;
        var end = start;
        while (end < rest.len) : (end += 1) {
            const c = rest[end];
            if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == ':')) break;
        }
        if (end > start) {
            const name = try importedMacroCalleeName(allocator, rest[start..end]);
            try appendUniqueDirectCallee(callees, name);
        }
        rest = rest[end..];
    }
}

fn appendExpandedImportedMacroDirectCallees(
    tc: *type_checker_mod.TypeChecker,
    callees: *std.ArrayList([]const u8),
    line: []const u8,
) !void {
    if (!std.mem.startsWith(u8, line, "EXPAND")) return;
    var parts = std.mem.tokenizeAny(u8, line["EXPAND".len..], " \t,");
    const expanded_name = parts.next() orelse return;
    const expanded = tc.imported_macros.get(expanded_name) orelse return;
    for (expanded.direct_callees) |callee| try appendUniqueDirectCallee(callees, callee);
}

fn loadImportedMacros(tc: *type_checker_mod.TypeChecker, allocator: std.mem.Allocator, source: []const u8, import_path: ?[]const u8) !void {
    const expanded_source = try source_expand.expand(allocator, source);
    var lines = std.mem.splitScalar(u8, expanded_source, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (!std.mem.startsWith(u8, line, "[MACRO]")) continue;

        var parts = std.mem.tokenizeAny(u8, line["[MACRO]".len..], " \t");
        const raw_name = parts.next() orelse continue;
        const name = try allocator.dupe(u8, std.mem.trim(u8, raw_name, " \t\r,"));

        var param_names = std.ArrayList([]const u8).init(allocator);
        defer param_names.deinit();
        var arity: usize = 0;
        var leading_outputs: usize = 0;
        var still_leading = true;
        while (parts.next()) |raw_param| {
            const param = macroParamName(raw_param);
            if (param.len == 0) continue;
            try param_names.append(param);
            if (still_leading and isLeadingOutputMacroParam(raw_param)) {
                leading_outputs += 1;
            } else {
                still_leading = false;
            }
            arity += 1;
        }

        var borrowed_arg_mask: u64 = 0;
        var address_slot_arg_mask: u64 = 0;
        var direct_callees = std.ArrayList([]const u8).init(allocator);
        defer direct_callees.deinit();
        while (lines.next()) |body_raw_line| {
            const body_line = std.mem.trim(u8, body_raw_line, " \t\r");
            if (std.mem.startsWith(u8, body_line, "[END_MACRO]")) break;
            try markDirectBorrowedMacroParams(allocator, &borrowed_arg_mask, param_names.items, body_line);
            try markDirectAddressSlotMacroParams(allocator, &address_slot_arg_mask, param_names.items, body_line);
            markExpandedImportedMacroParamMasks(tc, &borrowed_arg_mask, &address_slot_arg_mask, param_names.items, body_line);
            try collectDirectSlaMacroCallees(allocator, &direct_callees, body_line);
            try appendExpandedImportedMacroDirectCallees(tc, &direct_callees, body_line);
        }

        const owned_import_path = if (import_path) |path| try allocator.dupe(u8, path) else null;
        try tc.registerImportedMacro(name, arity, leading_outputs, owned_import_path, borrowed_arg_mask, address_slot_arg_mask, try direct_callees.toOwnedSlice());
    }
}

const SlaModuleExports = struct {
    const FunctionSignature = struct {
        name: []const u8,
        params: []const ast.Param,
        ret_ty: *ast.Type,
        is_pub: bool,
        is_extern: bool,
        abi: ?[]const u8,
        no_mangle: bool,
        is_async: bool,
        module_path: []const u8,
    };

    const TypeKind = enum { struct_decl, enum_decl, trait_decl, type_alias_decl };

    const TypeSignature = struct {
        name: []const u8,
        kind: TypeKind,
        generics: []const []const u8,
        module_path: []const u8,
    };

    const ConstSignature = struct {
        name: []const u8,
        ty: ?*ast.Type,
        module_path: []const u8,
    };

    const MacroSignature = struct {
        name: []const u8,
        params: []const []const u8,
        module_path: []const u8,
    };

    allocator: std.mem.Allocator,
    module_path: []const u8,
    type_decls: std.StringHashMap(*ast.Node),
    type_signatures: std.StringHashMap(TypeSignature),
    function_decls: std.StringHashMap(*ast.Node),
    function_signatures: std.StringHashMap(FunctionSignature),
    const_decls: std.StringHashMap(*ast.Node),
    const_signatures: std.StringHashMap(ConstSignature),
    macro_decls: std.StringHashMap(*ast.Node),
    macro_signatures: std.StringHashMap(MacroSignature),
    impl_decls: std.ArrayList(*ast.Node),
    trait_impl_decls: std.ArrayList(*ast.Node),

    fn init(allocator: std.mem.Allocator, module_path: []const u8) SlaModuleExports {
        return .{
            .allocator = allocator,
            .module_path = module_path,
            .type_decls = std.StringHashMap(*ast.Node).init(allocator),
            .type_signatures = std.StringHashMap(TypeSignature).init(allocator),
            .function_decls = std.StringHashMap(*ast.Node).init(allocator),
            .function_signatures = std.StringHashMap(FunctionSignature).init(allocator),
            .const_decls = std.StringHashMap(*ast.Node).init(allocator),
            .const_signatures = std.StringHashMap(ConstSignature).init(allocator),
            .macro_decls = std.StringHashMap(*ast.Node).init(allocator),
            .macro_signatures = std.StringHashMap(MacroSignature).init(allocator),
            .impl_decls = std.ArrayList(*ast.Node).init(allocator),
            .trait_impl_decls = std.ArrayList(*ast.Node).init(allocator),
        };
    }

    fn deinit(self: *SlaModuleExports) void {
        self.trait_impl_decls.deinit();
        self.impl_decls.deinit();
        self.macro_signatures.deinit();
        self.macro_decls.deinit();
        self.const_signatures.deinit();
        self.const_decls.deinit();
        self.function_signatures.deinit();
        self.function_decls.deinit();
        self.type_signatures.deinit();
        self.type_decls.deinit();
    }

    fn addDecl(table: *std.StringHashMap(*ast.Node), name: []const u8, decl: *ast.Node) !void {
        try table.put(name, decl);
    }

    fn addFunctionSignature(self: *SlaModuleExports, fd: *ast.FuncDecl) !void {
        try self.function_signatures.put(fd.name, .{
            .name = fd.name,
            .params = fd.params,
            .ret_ty = fd.ret_ty,
            .is_pub = fd.is_pub,
            .is_extern = fd.is_extern,
            .abi = fd.abi,
            .no_mangle = fd.no_mangle,
            .is_async = fd.is_async,
            .module_path = self.module_path,
        });
    }

    fn addTypeSignature(self: *SlaModuleExports, name: []const u8, kind: TypeKind, generics: []const []const u8) !void {
        try self.type_signatures.put(name, .{
            .name = name,
            .kind = kind,
            .generics = generics,
            .module_path = self.module_path,
        });
    }

    fn addConstSignature(self: *SlaModuleExports, c: *ast.ConstStmt) !void {
        try self.const_signatures.put(c.name, .{
            .name = c.name,
            .ty = c.ty,
            .module_path = self.module_path,
        });
    }

    fn addMacroSignature(self: *SlaModuleExports, m: *ast.MacroDecl) !void {
        try self.macro_signatures.put(m.name, .{
            .name = m.name,
            .params = m.params,
            .module_path = self.module_path,
        });
    }

    fn buildFromDecls(self: *SlaModuleExports, decls: []const *ast.Node) !void {
        for (decls) |decl| {
            switch (decl.*) {
                .struct_decl => |s| {
                    try addDecl(&self.type_decls, s.name, decl);
                    try self.addTypeSignature(s.name, .struct_decl, s.generics);
                },
                .enum_decl => |e| {
                    try addDecl(&self.type_decls, e.name, decl);
                    try self.addTypeSignature(e.name, .enum_decl, e.generics);
                },
                .trait_decl => |t| {
                    try addDecl(&self.type_decls, t.name, decl);
                    try self.addTypeSignature(t.name, .trait_decl, &.{});
                },
                .type_alias_decl => |a| {
                    try addDecl(&self.type_decls, a.name, decl);
                    try self.addTypeSignature(a.name, .type_alias_decl, &.{});
                },
                .func_decl => |f| {
                    try addDecl(&self.function_decls, f.name, decl);
                    try self.addFunctionSignature(&decl.func_decl);
                },
                .const_stmt => |c| {
                    try addDecl(&self.const_decls, c.name, decl);
                    try self.addConstSignature(&decl.const_stmt);
                },
                .macro_decl => |m| {
                    try addDecl(&self.macro_decls, m.name, decl);
                    try self.addMacroSignature(&decl.macro_decl);
                },
                .impl_decl => |impl| {
                    try self.impl_decls.append(decl);
                    if (impl.trait_name != null) try self.trait_impl_decls.append(decl);
                },
                else => {},
            }
        }
    }

    fn exportsType(self: *const SlaModuleExports, name: []const u8) bool {
        return self.type_decls.contains(name);
    }
    fn typeSignature(self: *const SlaModuleExports, name: []const u8) ?TypeSignature {
        return self.type_signatures.get(name);
    }
    fn exportsFunction(self: *const SlaModuleExports, name: []const u8) bool {
        return self.function_decls.contains(name);
    }
    fn functionSignature(self: *const SlaModuleExports, name: []const u8) ?FunctionSignature {
        return self.function_signatures.get(name);
    }
    fn exportsConst(self: *const SlaModuleExports, name: []const u8) bool {
        return self.const_decls.contains(name);
    }
    fn constSignature(self: *const SlaModuleExports, name: []const u8) ?ConstSignature {
        return self.const_signatures.get(name);
    }
    fn exportsMacro(self: *const SlaModuleExports, name: []const u8) bool {
        return self.macro_decls.contains(name);
    }
    fn macroSignature(self: *const SlaModuleExports, name: []const u8) ?MacroSignature {
        return self.macro_signatures.get(name);
    }
    fn exportsSymbol(self: *const SlaModuleExports, name: []const u8) bool {
        if (self.function_decls.contains(name)) return true;
        if (self.const_decls.contains(name)) return true;
        if (self.macro_decls.contains(name)) return true;

        var type_iter = self.type_decls.keyIterator();
        while (type_iter.next()) |type_name_ptr| {
            const type_name = type_name_ptr.*;
            if (std.mem.startsWith(u8, name, type_name)) {
                if (name.len > type_name.len and (name[type_name.len] == '_' or name[type_name.len] == '|')) {
                    return true;
                }
            }
            if (std.mem.indexOf(u8, name, type_name)) |idx| {
                if (idx > 0 and name[idx - 1] == '_') {
                    return true;
                }
            }
        }
        return false;
    }
};

const SlaModule = struct {
    path: []const u8,
    output_path: []const u8,
    base_dir: []const u8,
    program: *ast.Node,
    exports: SlaModuleExports,
    resolved_imports: []const ResolvedImport,
    resolved_module_imports: []const ResolvedModuleImport,
};

const SlaImportExpansionOptions = struct {
    prune_for_test_codegen: bool = false,
    test_filter: ?[]const u8 = null,
    imported_bodies_decl_only: bool = false,
    load_reachable_imported_bodies_from_registry: bool = false,
};

const SlaModuleTable = struct {
    allocator: std.mem.Allocator,
    modules: std.StringHashMap(*SlaModule),

    fn init(allocator: std.mem.Allocator) SlaModuleTable {
        return .{
            .allocator = allocator,
            .modules = std.StringHashMap(*SlaModule).init(allocator),
        };
    }

    fn deinit(self: *SlaModuleTable) void {
        var module_iter = self.modules.valueIterator();
        while (module_iter.next()) |module_ptr| {
            const module = module_ptr.*;
            for (module.resolved_module_imports) |resolved_import| {
                self.allocator.free(resolved_import.namespace);
            }
            self.allocator.free(module.resolved_module_imports);
            self.allocator.free(module.resolved_imports);
            module.exports.deinit();
            self.allocator.destroy(module);
        }
        self.modules.deinit();
    }

    fn buildModuleImportNamespaces(self: *SlaModuleTable, resolved_imports: []const ResolvedImport) ![]const ResolvedModuleImport {
        var imports = std.ArrayList(ResolvedModuleImport).init(self.allocator);
        for (resolved_imports) |resolved| {
            if (!std.mem.endsWith(u8, resolved.path, ".sla")) continue;
            try imports.append(.{
                .namespace = try moduleNamespaceFromImportPath(self.allocator, resolved.output_path),
                .resolved = resolved,
            });
        }
        return try imports.toOwnedSlice();
    }

    fn resolveModuleImports(self: *SlaModuleTable, module_path: []const u8, base_dir: []const u8, decls: []const *ast.Node) ![]const ResolvedImport {
        var imports = std.ArrayList(ResolvedImport).init(self.allocator);
        for (decls) |decl| {
            if (decl.* != .import_decl) continue;
            const resolved = try resolveImportFiles(self.allocator, base_dir, decl.import_decl.path, module_path);
            try imports.appendSlice(resolved);
        }
        return try imports.toOwnedSlice();
    }

    fn getOrParse(self: *SlaModuleTable, resolved: ResolvedImport) !*SlaModule {
        if (self.modules.get(resolved.path)) |module| return module;

        const base_dir = std.fs.path.dirname(resolved.path) orelse ".";
        const expanded_source = try source_expand.expand(self.allocator, resolved.source);
        var parser = parser_mod.Parser.initWithDir(self.allocator, expanded_source, base_dir);
        const parsed = try parser.parseProgram();
        if (parsed.* != .program) return error.InvalidProgram;

        var exports = SlaModuleExports.init(self.allocator, resolved.path);
        try exports.buildFromDecls(parsed.program.decls);
        const resolved_imports = try self.resolveModuleImports(resolved.path, base_dir, parsed.program.decls);
        const resolved_module_imports = try self.buildModuleImportNamespaces(resolved_imports);

        const module = try self.allocator.create(SlaModule);
        module.* = .{
            .path = resolved.path,
            .output_path = resolved.output_path,
            .base_dir = base_dir,
            .program = parsed,
            .exports = exports,
            .resolved_imports = resolved_imports,
            .resolved_module_imports = resolved_module_imports,
        };
        try self.modules.put(module.path, module);
        return module;
    }

    fn moduleImportByNamespace(self: *const SlaModuleTable, module_path: []const u8, namespace: []const u8) ?ResolvedModuleImport {
        const module = self.modules.get(module_path) orelse return null;
        for (module.resolved_module_imports) |resolved_import| {
            if (std.mem.eql(u8, resolved_import.namespace, namespace)) return resolved_import;
        }
        return null;
    }

    fn exportsForModule(self: *const SlaModuleTable, module_path: []const u8) ?*const SlaModuleExports {
        const module = self.modules.get(module_path) orelse return null;
        return &module.exports;
    }

    fn functionSignature(self: *const SlaModuleTable, module_path: []const u8, name: []const u8) ?SlaModuleExports.FunctionSignature {
        const exports = self.exportsForModule(module_path) orelse return null;
        return exports.functionSignature(name);
    }

    fn functionBody(self: *const SlaModuleTable, module_path: []const u8, name: []const u8) ?*ast.FuncDecl {
        const exports = self.exportsForModule(module_path) orelse return null;
        const decl = exports.function_decls.get(name) orelse return null;
        if (decl.* != .func_decl) return null;
        return &decl.func_decl;
    }

    fn associatedFunctionBody(self: *const SlaModuleTable, module_path: []const u8, symbol: []const u8) ?*ast.FuncDecl {
        const module = self.modules.get(module_path) orelse return null;
        for (module.program.program.decls) |decl| {
            switch (decl.*) {
                .impl_decl => |impl_decl| {
                    const type_name = lowering_rules.concreteTypeName(impl_decl.target_ty) orelse continue;
                    for (impl_decl.methods) |method| {
                        if (method.* != .func_decl) continue;
                        const candidate = if (impl_decl.trait_name) |trait_name|
                            lowering_rules.mangleTraitMethodName(self.allocator, type_name, trait_name, method.func_decl.name) catch continue
                        else
                            lowering_rules.mangleMethodName(self.allocator, type_name, method.func_decl.name) catch continue;
                        defer self.allocator.free(candidate);
                        if (std.mem.eql(u8, candidate, symbol)) return &method.func_decl;
                    }
                },
                .overload_decl => |overload_decl| {
                    const type_name = lowering_rules.concreteTypeName(overload_decl.target_ty) orelse continue;
                    for (overload_decl.methods) |method| {
                        if (method.* != .func_decl) continue;
                        const candidate = lowering_rules.mangleMethodName(self.allocator, type_name, method.func_decl.name) catch continue;
                        defer self.allocator.free(candidate);
                        if (std.mem.eql(u8, candidate, symbol)) return &method.func_decl;
                    }
                },
                else => {},
            }
        }
        return null;
    }

    fn typeSignature(self: *const SlaModuleTable, module_path: []const u8, name: []const u8) ?SlaModuleExports.TypeSignature {
        const exports = self.exportsForModule(module_path) orelse return null;
        return exports.typeSignature(name);
    }

    fn constSignature(self: *const SlaModuleTable, module_path: []const u8, name: []const u8) ?SlaModuleExports.ConstSignature {
        const exports = self.exportsForModule(module_path) orelse return null;
        return exports.constSignature(name);
    }

    fn macroSignature(self: *const SlaModuleTable, module_path: []const u8, name: []const u8) ?SlaModuleExports.MacroSignature {
        const exports = self.exportsForModule(module_path) orelse return null;
        return exports.macroSignature(name);
    }

    fn functionSignatureForImportNamespace(self: *SlaModuleTable, module_path: []const u8, namespace: []const u8, name: []const u8) !?SlaModuleExports.FunctionSignature {
        const resolved_import = self.moduleImportByNamespace(module_path, namespace) orelse return null;
        _ = try self.getOrParse(resolved_import.resolved);
        return self.functionSignature(resolved_import.resolved.path, name);
    }

    fn functionBodyForImportNamespace(self: *SlaModuleTable, module_path: []const u8, namespace: []const u8, name: []const u8) !?*ast.FuncDecl {
        const resolved_import = self.moduleImportByNamespace(module_path, namespace) orelse return null;
        _ = try self.getOrParse(resolved_import.resolved);
        return self.functionBody(resolved_import.resolved.path, name) orelse self.associatedFunctionBody(resolved_import.resolved.path, name);
    }

    fn typeSignatureForImportNamespace(self: *SlaModuleTable, module_path: []const u8, namespace: []const u8, name: []const u8) !?SlaModuleExports.TypeSignature {
        const resolved_import = self.moduleImportByNamespace(module_path, namespace) orelse return null;
        _ = try self.getOrParse(resolved_import.resolved);
        return self.typeSignature(resolved_import.resolved.path, name);
    }

    fn constSignatureForImportNamespace(self: *SlaModuleTable, module_path: []const u8, namespace: []const u8, name: []const u8) !?SlaModuleExports.ConstSignature {
        const resolved_import = self.moduleImportByNamespace(module_path, namespace) orelse return null;
        _ = try self.getOrParse(resolved_import.resolved);
        return self.constSignature(resolved_import.resolved.path, name);
    }

    fn macroSignatureForImportNamespace(self: *SlaModuleTable, module_path: []const u8, namespace: []const u8, name: []const u8) !?SlaModuleExports.MacroSignature {
        const resolved_import = self.moduleImportByNamespace(module_path, namespace) orelse return null;
        _ = try self.getOrParse(resolved_import.resolved);
        return self.macroSignature(resolved_import.resolved.path, name);
    }

    fn functionSignatureForImportedMangledName(self: *SlaModuleTable, module_path: []const u8, symbol: []const u8) !?SlaModuleExports.FunctionSignature {
        const imported = splitImportedMangledSymbol(symbol) orelse return null;
        return try self.functionSignatureForImportNamespace(module_path, imported.namespace, imported.name);
    }

    fn functionBodyForImportedMangledName(self: *SlaModuleTable, module_path: []const u8, symbol: []const u8) !?*ast.FuncDecl {
        const imported = splitImportedMangledSymbol(symbol) orelse return null;
        return try self.functionBodyForImportNamespace(module_path, imported.namespace, imported.name);
    }

    fn functionSignatureForImportedMangledNameByNamespace(self: *const SlaModuleTable, symbol: []const u8) ?SlaModuleExports.FunctionSignature {
        const imported = splitImportedMangledSymbol(symbol) orelse return null;
        var module_iter = self.modules.valueIterator();
        while (module_iter.next()) |module_ptr| {
            const module = module_ptr.*;
            if (!moduleNamespaceMatchesImportPath(module.output_path, imported.namespace)) continue;
            if (module.exports.functionSignature(imported.name)) |signature| return signature;
        }
        return null;
    }
};

fn appendResolvedNonSlaImportDecl(
    allocator: std.mem.Allocator,
    resolved: ResolvedImport,
    primary_decls: *std.AutoHashMap(*const ast.Node, void),
    out_decls: *std.ArrayList(*ast.Node),
) !void {
    const import_decl = try allocator.create(ast.Node);
    import_decl.* = .{ .import_decl = .{ .path = resolved.output_path } };
    try out_decls.append(import_decl);
    try primary_decls.put(import_decl, {});
}

fn isModuleContributing(
    allocator: std.mem.Allocator,
    module: *const SlaModule,
    reachable: *const std.StringHashMap(void),
    referenced_types: *const std.StringHashMap(void),
) !bool {
    const module_namespace = try moduleNamespaceFromImportPath(allocator, module.output_path);
    defer allocator.free(module_namespace);
    // 1. Check if any exported function is reachable
    var func_iter = module.exports.function_decls.keyIterator();
    while (func_iter.next()) |name_ptr| {
        if (reachable.contains(name_ptr.*)) return true;
        const alias = try std.fmt.allocPrint(allocator, "{s}__{s}", .{ module_namespace, name_ptr.* });
        defer allocator.free(alias);
        if (reachable.contains(alias)) return true;
    }

    // 2. Check if any exported type is referenced
    var type_iter = module.exports.type_decls.keyIterator();
    while (type_iter.next()) |name_ptr| {
        if (referenced_types.contains(name_ptr.*)) return true;
    }

    // 3. Check if any exported constant is referenced
    var const_iter = module.exports.const_decls.keyIterator();
    while (const_iter.next()) |name_ptr| {
        if (referenced_types.contains(name_ptr.*)) return true;
    }

    // 4. Check if any exported macro is referenced
    var macro_iter = module.exports.macro_decls.keyIterator();
    while (macro_iter.next()) |name_ptr| {
        if (referenced_types.contains(name_ptr.*)) return true;
    }

    // 5. Check if any of its inherent/trait impl methods is reachable
    for (module.program.program.decls) |decl| {
        switch (decl.*) {
            .impl_decl => |impl_decl| {
                const type_name = lowering_rules.concreteTypeName(impl_decl.target_ty) orelse continue;
                for (impl_decl.methods) |method| {
                    if (method.* != .func_decl) continue;
                    const symbol = if (impl_decl.trait_name) |trait_name|
                        try lowering_rules.mangleTraitMethodName(allocator, type_name, trait_name, method.func_decl.name)
                    else
                        try lowering_rules.mangleMethodName(allocator, type_name, method.func_decl.name);
                    defer allocator.free(symbol);
                    if (reachable.contains(symbol)) return true;
                }
            },
            .overload_decl => |overload_decl| {
                const type_name = lowering_rules.concreteTypeName(overload_decl.target_ty) orelse continue;
                for (overload_decl.methods) |method| {
                    if (method.* != .func_decl) continue;
                    const symbol = try lowering_rules.mangleMethodName(allocator, type_name, method.func_decl.name);
                    defer allocator.free(symbol);
                    if (reachable.contains(symbol)) return true;
                }
            },
            else => {},
        }
    }

    return false;
}

fn appendModuleDeclsSelective(
    allocator: std.mem.Allocator,
    modules: *SlaModuleTable,
    module: *SlaModule,
    emitted: *std.StringHashMap(void),
    primary_decls: *std.AutoHashMap(*const ast.Node, void),
    out_decls: *std.ArrayList(*ast.Node),
    reachable: *const std.StringHashMap(void),
    referenced_types: *const std.StringHashMap(void),
    options: SlaImportExpansionOptions,
) !void {
    if (emitted.contains(module.path)) return;
    try emitted.put(module.path, {});

    for (module.resolved_imports) |child_resolved| {
        if (!std.mem.endsWith(u8, child_resolved.path, ".sla")) continue;
        const child_module = try modules.getOrParse(child_resolved);
        try appendModuleDeclsSelective(allocator, modules, child_module, emitted, primary_decls, out_decls, reachable, referenced_types, options);
    }

    const is_contributing = try isModuleContributing(allocator, module, reachable, referenced_types);
    if (!is_contributing) {
        return;
    }

    const module_namespace = try moduleNamespaceFromImportPath(allocator, module.output_path);
    defer allocator.free(module_namespace);

    for (module.program.program.decls) |decl| {
        if (decl.* == .import_decl) {
            for (module.resolved_imports) |child_resolved| {
                if (std.mem.endsWith(u8, child_resolved.path, ".sla")) continue;
                try appendResolvedNonSlaImportDecl(allocator, child_resolved, primary_decls, out_decls);
            }
        } else {
            const before = out_decls.items.len;
            switch (decl.*) {
                .func_decl => |fd| {
                    if (try importedFuncNodeForReachability(allocator, decl, fd.name, module_namespace, reachable, options)) |func_node| {
                        try out_decls.append(func_node);
                        try primary_decls.put(func_node, {});
                    }
                    if (try reachableImportedAlias(allocator, module_namespace, fd.name, reachable)) |alias| {
                        defer allocator.free(alias);
                        const alias_node = try makeAliasedFuncNode(allocator, &decl.func_decl, alias, options);
                        try out_decls.append(alias_node);
                        try primary_decls.put(alias_node, {});
                    }
                },
                .impl_decl => {
                    try appendFilteredImplDeclWithOptions(allocator, decl, reachable, out_decls, options);
                },
                .overload_decl => {
                    try appendFilteredOverloadDeclWithOptions(allocator, decl, reachable, out_decls, options);
                },
                else => {
                    // Flatten types, constants, macros
                    try out_decls.append(decl);
                },
            }
            if (out_decls.items.len != before) try primary_decls.put(out_decls.items[out_decls.items.len - 1], {});
        }
    }
}

fn collectSlaModulesRecursive(
    modules: *SlaModuleTable,
    module: *SlaModule,
    visited: *std.StringHashMap(void),
    ordered: *std.ArrayList(*SlaModule),
) !void {
    if (visited.contains(module.path)) return;
    try visited.put(module.path, {});

    for (module.resolved_imports) |child_resolved| {
        if (!std.mem.endsWith(u8, child_resolved.path, ".sla")) continue;
        const child_module = try modules.getOrParse(child_resolved);
        try collectSlaModulesRecursive(modules, child_module, visited, ordered);
    }

    try ordered.append(module);
}

const SlaCallableIndex = struct {
    allocator: std.mem.Allocator,
    names: std.StringHashMap(void),
    decls: std.StringHashMap(*ast.FuncDecl),
    const_decls: std.StringHashMap(*ast.ConstStmt),
    macro_decls: std.StringHashMap(*ast.MacroDecl),
    module_sources: std.StringHashMap([]const u8),
    associated_candidates: std.StringHashMap(std.ArrayList([]const u8)),

    fn init(allocator: std.mem.Allocator) SlaCallableIndex {
        return .{
            .allocator = allocator,
            .names = std.StringHashMap(void).init(allocator),
            .decls = std.StringHashMap(*ast.FuncDecl).init(allocator),
            .const_decls = std.StringHashMap(*ast.ConstStmt).init(allocator),
            .macro_decls = std.StringHashMap(*ast.MacroDecl).init(allocator),
            .module_sources = std.StringHashMap([]const u8).init(allocator),
            .associated_candidates = std.StringHashMap(std.ArrayList([]const u8)).init(allocator),
        };
    }

    fn deinit(self: *SlaCallableIndex) void {
        var candidates = self.associated_candidates.valueIterator();
        while (candidates.next()) |list| list.deinit();
        self.associated_candidates.deinit();
        self.module_sources.deinit();
        self.macro_decls.deinit();
        self.const_decls.deinit();
        self.decls.deinit();
        self.names.deinit();
    }

    fn recordFunction(self: *SlaCallableIndex, name: []const u8, fd: *ast.FuncDecl, module_path: ?[]const u8) !void {
        try self.names.put(name, {});
        const decl_entry = try self.decls.getOrPut(name);
        if (!decl_entry.found_existing) decl_entry.value_ptr.* = fd;
        if (module_path) |mp| {
            const src_entry = try self.module_sources.getOrPut(name);
            if (!src_entry.found_existing) src_entry.value_ptr.* = mp;
        }
        try self.addFlattenedSuffixCandidates(name);
    }

    fn addFunction(self: *SlaCallableIndex, name: []const u8, fd: *ast.FuncDecl) !void {
        try self.recordFunction(name, fd, null);
    }

    fn addAssociatedFunctionWithModule(
        self: *SlaCallableIndex,
        method_name: []const u8,
        symbol: []const u8,
        fd: *ast.FuncDecl,
        module_path: ?[]const u8,
    ) !void {
        try self.recordFunction(symbol, fd, module_path);
        try self.addAssociatedCandidate(method_name, symbol);
    }

    fn moduleSource(self: *const SlaCallableIndex, name: []const u8) ?[]const u8 {
        return self.module_sources.get(name);
    }

    fn addAssociatedFunction(self: *SlaCallableIndex, method_name: []const u8, symbol: []const u8, fd: *ast.FuncDecl) !void {
        try self.addFunction(symbol, fd);
        try self.addAssociatedCandidate(method_name, symbol);
    }

    fn addAssociatedCandidate(self: *SlaCallableIndex, method_name: []const u8, symbol: []const u8) !void {
        const entry = try self.associated_candidates.getOrPut(method_name);
        if (!entry.found_existing) entry.value_ptr.* = std.ArrayList([]const u8).init(self.allocator);
        try entry.value_ptr.append(symbol);
    }

    fn addFlattenedSuffixCandidates(self: *SlaCallableIndex, symbol: []const u8) !void {
        for (symbol, 0..) |ch, index| {
            if (ch != '_' and ch != ':') continue;
            if (index + 1 >= symbol.len) continue;
            if (symbol[index + 1] == '_' or symbol[index + 1] == ':') continue;
            try self.addAssociatedCandidate(symbol[index + 1 ..], symbol);
        }
    }

    fn addDecls(self: *SlaCallableIndex, decls: []const *ast.Node) !void {
        try self.addDeclsFromModule(decls, null);
    }

    fn addDeclsFromModule(self: *SlaCallableIndex, decls: []const *ast.Node, module: ?*const SlaModule) !void {
        const module_path = if (module) |m| m.path else null;
        const namespace = if (module) |m| try moduleNamespaceFromImportPath(self.allocator, m.output_path) else null;
        for (decls) |decl| {
            switch (decl.*) {
                .func_decl => {
                    try self.recordFunction(decl.func_decl.name, &decl.func_decl, module_path);
                    if (namespace) |ns| {
                        const alias = try std.fmt.allocPrint(self.allocator, "{s}__{s}", .{ ns, decl.func_decl.name });
                        try self.recordFunction(alias, &decl.func_decl, module_path);
                    }
                },
                .const_stmt => {
                    const entry = try self.const_decls.getOrPut(decl.const_stmt.name);
                    if (!entry.found_existing) entry.value_ptr.* = &decl.const_stmt;
                },
                .macro_decl => {
                    const entry = try self.macro_decls.getOrPut(decl.macro_decl.name);
                    if (!entry.found_existing) entry.value_ptr.* = &decl.macro_decl;
                },
                .impl_decl => |impl_decl| {
                    const type_name = lowering_rules.concreteTypeName(impl_decl.target_ty) orelse continue;
                    for (impl_decl.methods) |method| {
                        if (method.* != .func_decl) continue;
                        const symbol = if (impl_decl.trait_name) |trait_name|
                            try lowering_rules.mangleTraitMethodName(self.allocator, type_name, trait_name, method.func_decl.name)
                        else
                            try lowering_rules.mangleMethodName(self.allocator, type_name, method.func_decl.name);
                        try self.addAssociatedFunctionWithModule(method.func_decl.name, symbol, &method.func_decl, module_path);
                    }
                },
                .overload_decl => |overload_decl| {
                    const type_name = lowering_rules.concreteTypeName(overload_decl.target_ty) orelse continue;
                    for (overload_decl.methods) |method| {
                        if (method.* != .func_decl) continue;
                        const symbol = try lowering_rules.mangleMethodName(self.allocator, type_name, method.func_decl.name);
                        try self.addAssociatedFunctionWithModule(method.func_decl.name, symbol, &method.func_decl, module_path);
                    }
                },
                else => {},
            }
        }
    }
};

fn collectSyntacticReachableRootsFromDecls(
    funcs: *const SlaCallableIndex,
    modules: ?*SlaModuleTable,
    imported_macros: ?*const std.StringHashMap(type_checker_mod.ImportedMacro),
    reachable: *std.StringHashMap(void),
    referenced_types: *std.StringHashMap(void),
    worklist: *std.ArrayList([]const u8),
    decls: []const *ast.Node,
    test_filter: ?[]const u8,
    saw_test: *bool,
) !void {
    for (decls) |decl| {
        switch (decl.*) {
            .test_decl => |test_decl| {
                if (!testMatchesFilter(&test_decl, test_filter)) continue;
                saw_test.* = true;
                try collectSyntacticReachableBlock(funcs, modules, imported_macros, null, reachable, referenced_types, worklist, test_decl.body);
            },
            .const_stmt => |const_stmt| {
                if (const_stmt.ty) |ty| try recordReferencedType(referenced_types, ty);
                try collectSyntacticReachableExpr(funcs, modules, imported_macros, null, reachable, referenced_types, worklist, const_stmt.value);
            },
            .macro_decl => |macro_decl| try collectSyntacticReachableBlock(funcs, modules, imported_macros, macro_decl.name, reachable, referenced_types, worklist, macro_decl.body),
            .impl_decl => |impl_decl| {
                try recordReferencedType(referenced_types, impl_decl.target_ty);
                if (impl_decl.trait_name) |tn| try referenced_types.put(tn, {});
                if (impl_decl.trait_name != null) {
                    for (impl_decl.methods) |method| {
                        if (method.* == .func_decl) {
                            const type_name = lowering_rules.concreteTypeName(impl_decl.target_ty) orelse continue;
                            const symbol = try lowering_rules.mangleTraitMethodName(funcs.allocator, type_name, impl_decl.trait_name.?, method.func_decl.name);
                            defer funcs.allocator.free(symbol);
                            try collectSyntacticReachableBlock(funcs, modules, imported_macros, symbol, reachable, referenced_types, worklist, method.func_decl.body);
                        }
                    }
                }
            },
            .overload_decl => |overload_decl| {
                try recordReferencedType(referenced_types, overload_decl.target_ty);
                for (overload_decl.methods) |method| {
                    if (method.* == .func_decl) {
                        const type_name = lowering_rules.concreteTypeName(overload_decl.target_ty) orelse continue;
                        const symbol = try lowering_rules.mangleMethodName(funcs.allocator, type_name, method.func_decl.name);
                        defer funcs.allocator.free(symbol);
                        try collectSyntacticReachableBlock(funcs, modules, imported_macros, symbol, reachable, referenced_types, worklist, method.func_decl.body);
                    }
                }
            },
            else => {},
        }
    }
}

fn scanReferencedSymbolRoots(
    funcs: *const SlaCallableIndex,
    modules: ?*SlaModuleTable,
    imported_macros: ?*const std.StringHashMap(type_checker_mod.ImportedMacro),
    reachable: *std.StringHashMap(void),
    referenced_types: *std.StringHashMap(void),
    scanned_symbol_roots: *std.StringHashMap(void),
    worklist: *std.ArrayList([]const u8),
) !bool {
    var pending = std.ArrayList([]const u8).init(funcs.allocator);
    defer pending.deinit();

    var referenced_iter = referenced_types.keyIterator();
    while (referenced_iter.next()) |ref_name_ptr| {
        const ref_name = ref_name_ptr.*;
        if (scanned_symbol_roots.contains(ref_name)) continue;
        try scanned_symbol_roots.put(ref_name, {});
        try pending.append(ref_name);
    }

    for (pending.items) |ref_name| {
        if (funcs.const_decls.get(ref_name)) |const_decl| {
            if (const_decl.ty) |ty| try recordReferencedType(referenced_types, ty);
            try collectSyntacticReachableExpr(funcs, modules, imported_macros, null, reachable, referenced_types, worklist, const_decl.value);
        }
        if (funcs.macro_decls.get(ref_name)) |macro_decl| {
            try collectSyntacticReachableBlock(funcs, modules, imported_macros, macro_decl.name, reachable, referenced_types, worklist, macro_decl.body);
        }
    }

    return pending.items.len != 0;
}

fn buildReachableSymbols(
    allocator: std.mem.Allocator,
    root_program: *ast.Node,
    modules: []const *SlaModule,
    module_table: *SlaModuleTable,
    options: SlaImportExpansionOptions,
    imported_macros: ?*const std.StringHashMap(type_checker_mod.ImportedMacro),
    out_reachable: *std.StringHashMap(void),
    out_referenced_types: *std.StringHashMap(void),
) !void {
    if (root_program.* != .program) return error.InvalidProgram;

    var callable_index = SlaCallableIndex.init(allocator);
    defer callable_index.deinit();
    try callable_index.addDecls(root_program.program.decls);
    for (modules) |module| {
        try callable_index.addDeclsFromModule(module.program.program.decls, module);
    }

    var worklist = std.ArrayList([]const u8).init(allocator);
    defer worklist.deinit();
    var scanned_symbol_roots = std.StringHashMap(void).init(allocator);
    defer scanned_symbol_roots.deinit();
    var scanned_type_roots = std.StringHashMap(void).init(allocator);
    defer scanned_type_roots.deinit();

    // 1. Collect roots
    if (options.prune_for_test_codegen) {
        var saw_test = false;
        try collectSyntacticReachableRootsFromDecls(&callable_index, module_table, imported_macros, out_reachable, out_referenced_types, &worklist, root_program.program.decls, options.test_filter, &saw_test);
        for (modules) |module| {
            try collectSyntacticReachableRootsFromDecls(&callable_index, module_table, imported_macros, out_reachable, out_referenced_types, &worklist, module.program.program.decls, options.test_filter, &saw_test);
        }
    } else {
        // If not pruning for test, everything in the root program is a root!
        for (root_program.program.decls) |decl| {
            switch (decl.*) {
                .func_decl => |fd| {
                    try markSyntacticReachableFunc(&callable_index, module_table, null, out_reachable, out_referenced_types, &worklist, fd.name);
                },
                .const_stmt => |c| {
                    if (c.ty) |ty| try recordReferencedType(out_referenced_types, ty);
                    try collectSyntacticReachableExpr(&callable_index, module_table, null, null, out_reachable, out_referenced_types, &worklist, c.value);
                },
                .macro_decl => |m| {
                    try collectSyntacticReachableBlock(&callable_index, module_table, null, m.name, out_reachable, out_referenced_types, &worklist, m.body);
                },
                .impl_decl => |impl_decl| {
                    try recordReferencedType(out_referenced_types, impl_decl.target_ty);
                    if (impl_decl.trait_name) |tn| try out_referenced_types.put(tn, {});
                    for (impl_decl.methods) |method| {
                        if (method.* == .func_decl) {
                            const type_name = lowering_rules.concreteTypeName(impl_decl.target_ty) orelse continue;
                            const symbol = if (impl_decl.trait_name) |trait_name|
                                try lowering_rules.mangleTraitMethodName(allocator, type_name, trait_name, method.func_decl.name)
                            else
                                try lowering_rules.mangleMethodName(allocator, type_name, method.func_decl.name);
                            defer allocator.free(symbol);
                            try markSyntacticReachableFunc(&callable_index, module_table, null, out_reachable, out_referenced_types, &worklist, symbol);
                        }
                    }
                },
                .overload_decl => |overload_decl| {
                    try recordReferencedType(out_referenced_types, overload_decl.target_ty);
                    for (overload_decl.methods) |method| {
                        if (method.* == .func_decl) {
                            const type_name = lowering_rules.concreteTypeName(overload_decl.target_ty) orelse continue;
                            const symbol = try lowering_rules.mangleMethodName(allocator, type_name, method.func_decl.name);
                            defer allocator.free(symbol);
                            try markSyntacticReachableFunc(&callable_index, module_table, null, out_reachable, out_referenced_types, &worklist, symbol);
                        }
                    }
                },
                else => {},
            }
        }
    }

    // 2. Traverse callable and exported-symbol worklists. `out_referenced_types`
    // also carries bare identifier references that can name imported consts or
    // macros, so scan those roots until no new initializer/body references are
    // discovered.
    var index: usize = 0;
    while (true) {
        while (index < worklist.items.len) : (index += 1) {
            const name = worklist.items[index];
            const fd = callable_index.decls.get(name) orelse continue;
            for (fd.params) |param| {
                try recordReferencedType(out_referenced_types, param.ty);
            }
            try recordReferencedType(out_referenced_types, fd.ret_ty);
            try collectSyntacticReachableBlock(&callable_index, module_table, imported_macros, name, out_reachable, out_referenced_types, &worklist, fd.body);
        }
        const scanned_symbols = try scanReferencedSymbolRoots(&callable_index, module_table, imported_macros, out_reachable, out_referenced_types, &scanned_symbol_roots, &worklist);
        const scanned_types = try scanReferencedExportedTypeSignatures(allocator, modules, out_referenced_types, &scanned_type_roots);
        if (!scanned_symbols and !scanned_types) break;
    }
}

fn appendFilteredFunctionDecl(
    decl: *ast.Node,
    reachable: *const std.StringHashMap(void),
    out_decls: *std.ArrayList(*ast.Node),
) !void {
    if (decl.func_decl.is_decl_only or reachable.contains(decl.func_decl.name)) try out_decls.append(decl);
}

fn makeDeclOnlyFuncNode(allocator: std.mem.Allocator, func: *const ast.FuncDecl) !*ast.Node {
    var stub_func = func.*;
    stub_func.is_decl_only = true;
    stub_func.body = &.{};
    const stub = try allocator.create(ast.Node);
    stub.* = .{ .func_decl = stub_func };
    return stub;
}

fn makeAliasedFuncNode(allocator: std.mem.Allocator, func: *const ast.FuncDecl, alias: []const u8, options: SlaImportExpansionOptions) !*ast.Node {
    var alias_func = func.*;
    alias_func.name = try allocator.dupe(u8, alias);
    if (options.imported_bodies_decl_only and !shouldKeepReachableImportedBody(options)) {
        alias_func.is_decl_only = true;
        alias_func.body = &.{};
    }
    const node = try allocator.create(ast.Node);
    node.* = .{ .func_decl = alias_func };
    return node;
}

fn maybeDeclOnlyFuncNode(allocator: std.mem.Allocator, method: *ast.Node, force_decl_only: bool) !*ast.Node {
    if (!force_decl_only or method.func_decl.is_decl_only) return method;
    return try makeDeclOnlyFuncNode(allocator, &method.func_decl);
}

fn shouldKeepReachableImportedBody(options: SlaImportExpansionOptions) bool {
    return options.imported_bodies_decl_only and options.load_reachable_imported_bodies_from_registry;
}

fn reachableImportedAlias(allocator: std.mem.Allocator, namespace: ?[]const u8, name: []const u8, reachable: *const std.StringHashMap(void)) !?[]const u8 {
    const ns = namespace orelse return null;
    const alias = try std.fmt.allocPrint(allocator, "{s}__{s}", .{ ns, name });
    if (reachable.contains(alias)) return alias;
    allocator.free(alias);
    return null;
}

fn importedFuncNodeForReachability(
    allocator: std.mem.Allocator,
    node: *ast.Node,
    reachable_symbol: []const u8,
    namespace: ?[]const u8,
    reachable: *const std.StringHashMap(void),
    options: SlaImportExpansionOptions,
) !?*ast.Node {
    if (node.* != .func_decl) return null;
    var is_reachable = reachable.contains(reachable_symbol);
    if (!is_reachable) {
        if (try reachableImportedAlias(allocator, namespace, reachable_symbol, reachable)) |alias| {
            allocator.free(alias);
            is_reachable = true;
        }
    }
    if (!is_reachable) return null;
    if (shouldKeepReachableImportedBody(options)) return node;
    if (options.imported_bodies_decl_only) return try makeDeclOnlyFuncNode(allocator, &node.func_decl);
    return node;
}

fn appendFilteredImplDecl(
    allocator: std.mem.Allocator,
    decl: *ast.Node,
    reachable: *const std.StringHashMap(void),
    out_decls: *std.ArrayList(*ast.Node),
) !void {
    try appendFilteredImplDeclWithOptions(allocator, decl, reachable, out_decls, .{});
}

fn appendFilteredImplDeclWithOptions(
    allocator: std.mem.Allocator,
    decl: *ast.Node,
    reachable: *const std.StringHashMap(void),
    out_decls: *std.ArrayList(*ast.Node),
    options: SlaImportExpansionOptions,
) !void {
    const impl_decl = decl.impl_decl;
    const type_name = lowering_rules.concreteTypeName(impl_decl.target_ty) orelse {
        try out_decls.append(decl);
        return;
    };

    var methods = std.ArrayList(*ast.Node).init(allocator);
    var changed = false;
    for (impl_decl.methods) |method| {
        if (method.* != .func_decl) {
            try methods.append(method);
            continue;
        }
        const symbol = if (impl_decl.trait_name) |trait_name|
            try lowering_rules.mangleTraitMethodName(allocator, type_name, trait_name, method.func_decl.name)
        else
            try lowering_rules.mangleMethodName(allocator, type_name, method.func_decl.name);
        if (method.func_decl.is_decl_only or reachable.contains(symbol)) {
            const keep_body = reachable.contains(symbol) and shouldKeepReachableImportedBody(options);
            try methods.append(try maybeDeclOnlyFuncNode(allocator, method, options.imported_bodies_decl_only and !keep_body));
            if (options.imported_bodies_decl_only and !keep_body and !method.func_decl.is_decl_only) changed = true;
        } else if (impl_decl.trait_name != null) {
            try methods.append(try makeDeclOnlyFuncNode(allocator, &method.func_decl));
            changed = true;
        } else {
            changed = true;
        }
    }
    if (!changed and methods.items.len == impl_decl.methods.len) {
        try out_decls.append(decl);
    } else if (methods.items.len > 0) {
        const pruned = try allocator.create(ast.Node);
        pruned.* = .{ .impl_decl = .{
            .trait_name = impl_decl.trait_name,
            .target_ty = impl_decl.target_ty,
            .methods = try methods.toOwnedSlice(),
        } };
        try out_decls.append(pruned);
    }
}

fn appendFilteredOverloadDecl(
    allocator: std.mem.Allocator,
    decl: *ast.Node,
    reachable: *const std.StringHashMap(void),
    out_decls: *std.ArrayList(*ast.Node),
) !void {
    try appendFilteredOverloadDeclWithOptions(allocator, decl, reachable, out_decls, .{});
}

fn appendFilteredOverloadDeclWithOptions(
    allocator: std.mem.Allocator,
    decl: *ast.Node,
    reachable: *const std.StringHashMap(void),
    out_decls: *std.ArrayList(*ast.Node),
    options: SlaImportExpansionOptions,
) !void {
    const overload_decl = decl.overload_decl;
    const type_name = lowering_rules.concreteTypeName(overload_decl.target_ty) orelse {
        try out_decls.append(decl);
        return;
    };

    var methods = std.ArrayList(*ast.Node).init(allocator);
    for (overload_decl.methods) |method| {
        if (method.* != .func_decl) {
            try methods.append(method);
            continue;
        }
        const symbol = try lowering_rules.mangleMethodName(allocator, type_name, method.func_decl.name);
        if (method.func_decl.is_decl_only or reachable.contains(symbol)) {
            const keep_body = reachable.contains(symbol) and shouldKeepReachableImportedBody(options);
            try methods.append(try maybeDeclOnlyFuncNode(allocator, method, options.imported_bodies_decl_only and !keep_body));
        }
    }
    if (methods.items.len == overload_decl.methods.len and !options.imported_bodies_decl_only) {
        try out_decls.append(decl);
    } else if (methods.items.len > 0) {
        const pruned = try allocator.create(ast.Node);
        pruned.* = .{ .overload_decl = .{
            .target_ty = overload_decl.target_ty,
            .methods = try methods.toOwnedSlice(),
        } };
        try out_decls.append(pruned);
    }
}

fn appendDeclWithReachableFilter(
    allocator: std.mem.Allocator,
    decl: *ast.Node,
    reachable: ?*const std.StringHashMap(void),
    out_decls: *std.ArrayList(*ast.Node),
) !void {
    const filter = reachable orelse {
        try out_decls.append(decl);
        return;
    };
    switch (decl.*) {
        .func_decl => try appendFilteredFunctionDecl(decl, filter, out_decls),
        .impl_decl => try appendFilteredImplDecl(allocator, decl, filter, out_decls),
        .overload_decl => try appendFilteredOverloadDecl(allocator, decl, filter, out_decls),
        else => try out_decls.append(decl),
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
    options: SlaImportExpansionOptions,
) !*ast.Node {
    if (program.* != .program) return error.InvalidProgram;

    var modules = SlaModuleTable.init(allocator);
    defer modules.deinit();

    var emitted = std.StringHashMap(void).init(allocator);
    defer emitted.deinit();

    var decls = std.ArrayList(*ast.Node).init(allocator);
    const source_dir = std.fs.path.dirname(source_file) orelse ".";
    const source_abs = std.fs.cwd().realpathAlloc(allocator, source_file) catch source_file;

    var ordered_modules = std.ArrayList(*SlaModule).init(allocator);
    defer ordered_modules.deinit();
    var visited_modules = std.StringHashMap(void).init(allocator);
    defer visited_modules.deinit();

    for (program.program.decls) |decl| {
        if (decl.* != .import_decl) continue;
        const resolved_imports = try resolveImportFiles(allocator, source_dir, decl.import_decl.path, source_abs);
        for (resolved_imports) |resolved| {
            if (!std.mem.endsWith(u8, resolved.path, ".sla")) continue;
            const module = try modules.getOrParse(resolved);
            try collectSlaModulesRecursive(&modules, module, &visited_modules, &ordered_modules);
        }
    }

    var reachable = std.StringHashMap(void).init(allocator);
    defer reachable.deinit();
    var referenced_types = std.StringHashMap(void).init(allocator);
    defer referenced_types.deinit();

    var imported_macro_tc = type_checker_mod.TypeChecker.init(allocator);
    defer imported_macro_tc.deinit();
    if (options.prune_for_test_codegen) {
        try loadImportedContracts(&imported_macro_tc, allocator, program, source_file);
    }
    const imported_macros = if (options.prune_for_test_codegen) &imported_macro_tc.imported_macros else null;

    try buildReachableSymbols(allocator, program, ordered_modules.items, &modules, options, imported_macros, &reachable, &referenced_types);

    for (program.program.decls) |decl| {
        if (decl.* == .import_decl) {
            const resolved_imports = try resolveImportFiles(allocator, source_dir, decl.import_decl.path, source_abs);
            for (resolved_imports) |resolved| {
                if (std.mem.endsWith(u8, resolved.path, ".sla")) {
                    const module = try modules.getOrParse(resolved);
                    try appendModuleDeclsSelective(allocator, &modules, module, &emitted, primary_decls, &decls, &reachable, &referenced_types, options);
                } else {
                    try appendResolvedNonSlaImportDecl(allocator, resolved, primary_decls, &decls);
                }
            }
        } else {
            const before = decls.items.len;
            if (options.prune_for_test_codegen) {
                try appendDeclWithReachableFilter(allocator, decl, &reachable, &decls);
            } else {
                try decls.append(decl);
            }
            if (decls.items.len != before) try primary_decls.put(decls.items[decls.items.len - 1], {});
        }
    }

    const expanded = try allocator.create(ast.Node);
    expanded.* = .{ .program = .{ .decls = try decls.toOwnedSlice() } };
    return expanded;
}

fn registerImportedFunctionAliases(tc: *type_checker_mod.TypeChecker, allocator: std.mem.Allocator, program: *ast.Node, source_file: []const u8) !void {
    if (program.* != .program) return error.InvalidProgram;

    var modules = SlaModuleTable.init(allocator);
    defer modules.deinit();

    const source_dir = std.fs.path.dirname(source_file) orelse ".";
    const source_abs = std.fs.cwd().realpathAlloc(allocator, source_file) catch source_file;

    for (program.program.decls) |decl| {
        if (decl.* != .import_decl) continue;
        const resolved_imports = try resolveImportFiles(allocator, source_dir, decl.import_decl.path, source_abs);
        for (resolved_imports) |resolved| {
            if (!std.mem.endsWith(u8, resolved.path, ".sla")) continue;
            const namespace = try moduleNamespaceFromImportPath(allocator, resolved.output_path);
            const module = try modules.getOrParse(resolved);
            var fn_iter = module.exports.function_signatures.iterator();
            while (fn_iter.next()) |entry| {
                const name = entry.key_ptr.*;
                const signature = entry.value_ptr.*;
                const alias = try std.fmt.allocPrint(allocator, "{s}__{s}", .{ namespace, name });
                try tc.registerFunctionAliasWithMetadata(alias, name, namespace, module.path);
                try tc.registerImportedFunctionSignature(name, signature.params, signature.ret_ty, signature.is_async);
                try tc.registerImportedFunctionSignature(alias, signature.params, signature.ret_ty, signature.is_async);
            }
            for (module.exports.impl_decls.items) |impl_node| {
                const impl_decl = impl_node.impl_decl;
                const type_name = lowering_rules.concreteTypeName(impl_decl.target_ty) orelse continue;
                for (impl_decl.methods) |method| {
                    if (method.* != .func_decl) continue;
                    const symbol = if (impl_decl.trait_name) |trait_name|
                        try lowering_rules.mangleTraitMethodName(allocator, type_name, trait_name, method.func_decl.name)
                    else
                        try lowering_rules.mangleMethodName(allocator, type_name, method.func_decl.name);
                    try tc.registerImportedFunctionSignature(symbol, method.func_decl.params, method.func_decl.ret_ty, method.func_decl.is_async);
                }
            }
        }
    }
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
        try loadImportedMacros(tc, allocator, expanded_source, resolved.output_path);
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
    allow_fallback: bool = true,
    prune_for_test_codegen: bool = false,
    load_reachable_imported_bodies_from_registry: bool = false,
};

fn defaultSlaCompileOptions() SlaCompileOptions {
    return .{ .load_reachable_imported_bodies_from_registry = true };
}

fn slaProfileEnabled(allocator: std.mem.Allocator) bool {
    const value = std.process.getEnvVarOwned(allocator, "SLA_PROFILE") catch return false;
    defer allocator.free(value);
    return value.len != 0 and !std.mem.eql(u8, value, "0") and !std.mem.eql(u8, value, "false");
}

fn slaSabFallbackAllowed(allocator: std.mem.Allocator, options: SlaCompileOptions) bool {
    if (!options.allow_fallback) return false;
    const value = std.process.getEnvVarOwned(allocator, "SLA_SAB_NO_FALLBACK") catch return true;
    defer allocator.free(value);
    return value.len == 0 or std.mem.eql(u8, value, "0") or std.mem.eql(u8, value, "false");
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

fn testFilterSelectsNoTests(
    allocator: std.mem.Allocator,
    file: []const u8,
    filter: ?[]const u8,
    stderr: std.io.AnyWriter,
) !?bool {
    const pattern = filter orelse return null;
    if (pattern.len == 0) return null;

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
    const expanded_prog = expandSlaImports(allocator, prog, file, &primary_decls, .{}) catch |err| {
        try stderr.print("Import Error: failed to expand @import SLA sources: {}\n", .{err});
        return null;
    };

    for (expanded_prog.program.decls) |decl| {
        if (decl.* == .test_decl and testMatchesFilter(&decl.test_decl, pattern)) return false;
    }
    return true;
}

fn writeEmptyTestResult(stdout: std.io.AnyWriter) !void {
    try stdout.writeAll("----\n");
    try stdout.writeAll("test result: ok. 0 passed; 0 failed; 0 skipped\n");
}

fn markReachableFunc(
    tc: *const type_checker_mod.TypeChecker,
    reachable: *std.StringHashMap(void),
    worklist: *std.ArrayList([]const u8),
    name: []const u8,
) anyerror!void {
    if (!tc.funcs.contains(name)) return;
    if (reachable.contains(name)) return;
    try reachable.put(name, {});
    try worklist.append(name);
}

fn markReachableResolvedCallAlias(
    tc: *const type_checker_mod.TypeChecker,
    reachable: *std.StringHashMap(void),
    expr: *const ast.Node,
) anyerror!void {
    const metadata = tc.resolved_call_alias_metadata.get(expr) orelse return;
    if (!reachable.contains(metadata.alias)) try reachable.put(metadata.alias, {});
}

fn associatedReachableFuncKey(
    tc: *const type_checker_mod.TypeChecker,
    target_name: []const u8,
    func_name: []const u8,
) ?[]const u8 {
    var it = tc.funcs.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (key.len != target_name.len + 1 + func_name.len) continue;
        if (!std.mem.startsWith(u8, key, target_name)) continue;
        if (key[target_name.len] != '_') continue;
        if (!std.mem.eql(u8, key[target_name.len + 1 ..], func_name)) continue;
        return key;
    }
    return null;
}

fn markReachableCallTarget(
    tc: *const type_checker_mod.TypeChecker,
    reachable: *std.StringHashMap(void),
    worklist: *std.ArrayList([]const u8),
    expr: *const ast.Node,
    call: ast.CallExpr,
) anyerror!void {
    if (tc.resolved_call_symbols.get(expr)) |symbol| {
        try markReachableResolvedCallAlias(tc, reachable, expr);
        try markReachableFunc(tc, reachable, worklist, symbol);
        return;
    }
    if (call.associated_target) |target_name| {
        if (associatedReachableFuncKey(tc, target_name, call.func_name)) |symbol| {
            try markReachableFunc(tc, reachable, worklist, symbol);
        }
        return;
    }
    if (tc.imported_macros.get(call.func_name)) |macro| {
        for (macro.direct_callees) |callee| try markReachableFunc(tc, reachable, worklist, callee);
        return;
    }
    try markReachableFunc(tc, reachable, worklist, call.func_name);
}

fn collectReachableExpr(
    tc: *const type_checker_mod.TypeChecker,
    reachable: *std.StringHashMap(void),
    worklist: *std.ArrayList([]const u8),
    expr: *const ast.Node,
) anyerror!void {
    switch (expr.*) {
        .identifier => |name| try markReachableFunc(tc, reachable, worklist, name),
        .generic_func_ref => |ref| try markReachableFunc(tc, reachable, worklist, ref.func_name),
        .call_expr => |call| {
            try markReachableCallTarget(tc, reachable, worklist, expr, call);
            for (call.args) |arg| try collectReachableExpr(tc, reachable, worklist, arg);
        },
        .if_expr => |ife| {
            try collectReachableExpr(tc, reachable, worklist, ife.cond);
            if (ife.let_chain) |chain| {
                for (chain) |cond| try collectReachableExpr(tc, reachable, worklist, cond.value);
            }
            try collectReachableBlock(tc, reachable, worklist, ife.then_block);
            if (ife.else_block) |else_block| try collectReachableBlock(tc, reachable, worklist, else_block);
        },
        .switch_expr => |swe| {
            try collectReachableExpr(tc, reachable, worklist, swe.val);
            for (swe.cases) |case| {
                try collectReachableExpr(tc, reachable, worklist, case.pattern);
                try collectReachableBlock(tc, reachable, worklist, case.body);
            }
        },
        .match_expr => |mat| {
            try collectReachableExpr(tc, reachable, worklist, mat.val);
            for (mat.cases) |case| {
                if (case.guard) |guard| try collectReachableExpr(tc, reachable, worklist, guard);
                try collectReachableBlock(tc, reachable, worklist, case.body);
            }
        },
        .unsafe_expr => |unsafe_expr| try collectReachableBlock(tc, reachable, worklist, unsafe_expr.body),
        .await_expr => |await_expr| try collectReachableExpr(tc, reachable, worklist, await_expr.expr),
        .try_expr => |try_expr| try collectReachableExpr(tc, reachable, worklist, try_expr.expr),
        .binary_expr => |bin| {
            if (tc.resolved_call_symbols.get(expr)) |symbol| {
                try markReachableResolvedCallAlias(tc, reachable, expr);
                try markReachableFunc(tc, reachable, worklist, symbol);
            }
            try collectReachableExpr(tc, reachable, worklist, bin.left);
            try collectReachableExpr(tc, reachable, worklist, bin.right);
        },
        .closure_literal => |closure| try collectReachableExpr(tc, reachable, worklist, closure.body),
        .borrow_expr => |borrow| try collectReachableExpr(tc, reachable, worklist, borrow.expr),
        .move_expr => |move| try collectReachableExpr(tc, reachable, worklist, move.expr),
        .deref_expr => |deref| try collectReachableExpr(tc, reachable, worklist, deref.expr),
        .cast_expr => |cast| try collectReachableExpr(tc, reachable, worklist, cast.expr),
        .field_expr => |field| try collectReachableExpr(tc, reachable, worklist, field.expr),
        .struct_literal => |lit| for (lit.fields) |field| try collectReachableExpr(tc, reachable, worklist, field.value),
        .enum_literal => |lit| for (lit.fields) |field| try collectReachableExpr(tc, reachable, worklist, field.value),
        .tuple_literal => |lit| for (lit.elements) |elem| try collectReachableExpr(tc, reachable, worklist, elem),
        .array_literal => |lit| for (lit.elements) |elem| try collectReachableExpr(tc, reachable, worklist, elem),
        .repeat_array_literal => |lit| try collectReachableExpr(tc, reachable, worklist, lit.value),
        .index_expr => |idx| {
            try collectReachableExpr(tc, reachable, worklist, idx.target);
            try collectReachableExpr(tc, reachable, worklist, idx.index);
        },
        .slice_expr => |slice| {
            try collectReachableExpr(tc, reachable, worklist, slice.target);
            try collectReachableExpr(tc, reachable, worklist, slice.start);
            try collectReachableExpr(tc, reachable, worklist, slice.end);
        },
        else => {},
    }
}

fn collectReachableBlock(
    tc: *const type_checker_mod.TypeChecker,
    reachable: *std.StringHashMap(void),
    worklist: *std.ArrayList([]const u8),
    block: []const *ast.Node,
) anyerror!void {
    for (block) |stmt| {
        switch (stmt.*) {
            .let_stmt => |let| try collectReachableExpr(tc, reachable, worklist, let.value),
            .let_else_stmt => |let| {
                try collectReachableExpr(tc, reachable, worklist, let.value);
                try collectReachableBlock(tc, reachable, worklist, let.else_block);
            },
            .let_destructure_stmt => |let| try collectReachableExpr(tc, reachable, worklist, let.value),
            .const_stmt => |c| try collectReachableExpr(tc, reachable, worklist, c.value),
            .assign_stmt => |assign| {
                try collectReachableExpr(tc, reachable, worklist, assign.target);
                try collectReachableExpr(tc, reachable, worklist, assign.value);
            },
            .block_stmt => |blk| try collectReachableBlock(tc, reachable, worklist, blk.body),
            .expr_stmt => |expr| try collectReachableExpr(tc, reachable, worklist, expr),
            .return_stmt => |ret| if (ret.value) |value| try collectReachableExpr(tc, reachable, worklist, value),
            .for_stmt => |for_stmt| {
                try collectReachableExpr(tc, reachable, worklist, for_stmt.start);
                if (for_stmt.end) |end_expr| try collectReachableExpr(tc, reachable, worklist, end_expr);
                try collectReachableBlock(tc, reachable, worklist, for_stmt.body);
            },
            .while_stmt => |while_stmt| {
                try collectReachableExpr(tc, reachable, worklist, while_stmt.cond);
                try collectReachableBlock(tc, reachable, worklist, while_stmt.body);
            },
            else => try collectReachableExpr(tc, reachable, worklist, stmt),
        }
    }
}

fn dynConcreteTypeName(ty: *const ast.Type) ?[]const u8 {
    var curr = ty;
    while (true) {
        switch (curr.*) {
            .borrow => |b| curr = b,
            .pointer => |p| curr = p,
            .user_defined => |ud| {
                if (std.mem.startsWith(u8, ud.name, "__dyn_")) return null;
                if ((std.mem.eql(u8, ud.name, "Box") or std.mem.eql(u8, ud.name, "Rc") or std.mem.eql(u8, ud.name, "Arc")) and ud.generics.len == 1) {
                    return dynConcreteTypeName(ud.generics[0]);
                }
                return ud.name;
            },
            else => return null,
        }
    }
}

fn markNeededTraitImplForExpr(
    allocator: std.mem.Allocator,
    tc: *const type_checker_mod.TypeChecker,
    needed: *std.StringHashMap(void),
    expr: *const ast.Node,
    trait_name: []const u8,
) !void {
    const source_expr = if (expr.* == .borrow_expr) expr.borrow_expr.expr else expr;
    const source_ty = tc.expr_types.get(source_expr) orelse tc.expr_types.get(expr) orelse return;
    const type_name = dynConcreteTypeName(source_ty) orelse return;
    const key = try std.fmt.allocPrint(allocator, "{s}|{s}", .{ trait_name, type_name });
    try needed.put(key, {});
}

fn collectNeededTraitImplsExpr(
    allocator: std.mem.Allocator,
    tc: *const type_checker_mod.TypeChecker,
    needed: *std.StringHashMap(void),
    expr: *const ast.Node,
) anyerror!void {
    if (tc.dyn_borrow_args.get(expr)) |trait_name| try markNeededTraitImplForExpr(allocator, tc, needed, expr, trait_name);
    if (tc.dyn_box_coercions.get(expr)) |trait_name| try markNeededTraitImplForExpr(allocator, tc, needed, expr, trait_name);
    if (tc.dyn_rc_coercions.get(expr)) |trait_name| try markNeededTraitImplForExpr(allocator, tc, needed, expr, trait_name);

    switch (expr.*) {
        .call_expr => |call| for (call.args) |arg| try collectNeededTraitImplsExpr(allocator, tc, needed, arg),
        .if_expr => |ife| {
            try collectNeededTraitImplsExpr(allocator, tc, needed, ife.cond);
            if (ife.let_chain) |chain| {
                for (chain) |cond| try collectNeededTraitImplsExpr(allocator, tc, needed, cond.value);
            }
            try collectNeededTraitImplsBlock(allocator, tc, needed, ife.then_block);
            if (ife.else_block) |else_block| try collectNeededTraitImplsBlock(allocator, tc, needed, else_block);
        },
        .switch_expr => |swe| {
            try collectNeededTraitImplsExpr(allocator, tc, needed, swe.val);
            for (swe.cases) |case| {
                try collectNeededTraitImplsExpr(allocator, tc, needed, case.pattern);
                try collectNeededTraitImplsBlock(allocator, tc, needed, case.body);
            }
        },
        .match_expr => |mat| {
            try collectNeededTraitImplsExpr(allocator, tc, needed, mat.val);
            for (mat.cases) |case| {
                if (case.guard) |guard| try collectNeededTraitImplsExpr(allocator, tc, needed, guard);
                try collectNeededTraitImplsBlock(allocator, tc, needed, case.body);
            }
        },
        .unsafe_expr => |unsafe_expr| try collectNeededTraitImplsBlock(allocator, tc, needed, unsafe_expr.body),
        .await_expr => |await_expr| try collectNeededTraitImplsExpr(allocator, tc, needed, await_expr.expr),
        .try_expr => |try_expr| try collectNeededTraitImplsExpr(allocator, tc, needed, try_expr.expr),
        .binary_expr => |bin| {
            try collectNeededTraitImplsExpr(allocator, tc, needed, bin.left);
            try collectNeededTraitImplsExpr(allocator, tc, needed, bin.right);
        },
        .closure_literal => |closure| try collectNeededTraitImplsExpr(allocator, tc, needed, closure.body),
        .borrow_expr => |borrow| try collectNeededTraitImplsExpr(allocator, tc, needed, borrow.expr),
        .move_expr => |move| try collectNeededTraitImplsExpr(allocator, tc, needed, move.expr),
        .deref_expr => |deref| try collectNeededTraitImplsExpr(allocator, tc, needed, deref.expr),
        .cast_expr => |cast| try collectNeededTraitImplsExpr(allocator, tc, needed, cast.expr),
        .field_expr => |field| try collectNeededTraitImplsExpr(allocator, tc, needed, field.expr),
        .struct_literal => |lit| {
            for (lit.fields) |field| try collectNeededTraitImplsExpr(allocator, tc, needed, field.value);
            if (lit.update_expr) |update| try collectNeededTraitImplsExpr(allocator, tc, needed, update);
        },
        .enum_literal => |lit| for (lit.fields) |field| try collectNeededTraitImplsExpr(allocator, tc, needed, field.value),
        .tuple_literal => |lit| for (lit.elements) |elem| try collectNeededTraitImplsExpr(allocator, tc, needed, elem),
        .array_literal => |lit| for (lit.elements) |elem| try collectNeededTraitImplsExpr(allocator, tc, needed, elem),
        .repeat_array_literal => |lit| try collectNeededTraitImplsExpr(allocator, tc, needed, lit.value),
        .index_expr => |idx| {
            try collectNeededTraitImplsExpr(allocator, tc, needed, idx.target);
            try collectNeededTraitImplsExpr(allocator, tc, needed, idx.index);
        },
        .slice_expr => |slice| {
            try collectNeededTraitImplsExpr(allocator, tc, needed, slice.target);
            try collectNeededTraitImplsExpr(allocator, tc, needed, slice.start);
            try collectNeededTraitImplsExpr(allocator, tc, needed, slice.end);
        },
        else => {},
    }
}

fn collectNeededTraitImplsBlock(
    allocator: std.mem.Allocator,
    tc: *const type_checker_mod.TypeChecker,
    needed: *std.StringHashMap(void),
    block: []const *ast.Node,
) anyerror!void {
    for (block) |stmt| {
        switch (stmt.*) {
            .let_stmt => |let| try collectNeededTraitImplsExpr(allocator, tc, needed, let.value),
            .let_else_stmt => |let| {
                try collectNeededTraitImplsExpr(allocator, tc, needed, let.value);
                try collectNeededTraitImplsBlock(allocator, tc, needed, let.else_block);
            },
            .let_destructure_stmt => |let| try collectNeededTraitImplsExpr(allocator, tc, needed, let.value),
            .const_stmt => |c| try collectNeededTraitImplsExpr(allocator, tc, needed, c.value),
            .assign_stmt => |assign| {
                try collectNeededTraitImplsExpr(allocator, tc, needed, assign.target);
                try collectNeededTraitImplsExpr(allocator, tc, needed, assign.value);
            },
            .block_stmt => |blk| try collectNeededTraitImplsBlock(allocator, tc, needed, blk.body),
            .expr_stmt => |expr| try collectNeededTraitImplsExpr(allocator, tc, needed, expr),
            .return_stmt => |ret| if (ret.value) |value| try collectNeededTraitImplsExpr(allocator, tc, needed, value),
            .for_stmt => |for_stmt| {
                try collectNeededTraitImplsExpr(allocator, tc, needed, for_stmt.start);
                if (for_stmt.end) |end_expr| try collectNeededTraitImplsExpr(allocator, tc, needed, end_expr);
                try collectNeededTraitImplsBlock(allocator, tc, needed, for_stmt.body);
            },
            .while_stmt => |while_stmt| {
                try collectNeededTraitImplsExpr(allocator, tc, needed, while_stmt.cond);
                try collectNeededTraitImplsBlock(allocator, tc, needed, while_stmt.body);
            },
            else => {},
        }
    }
}

fn recordReferencedType(referenced_types: *std.StringHashMap(void), ty: *const ast.Type) anyerror!void {
    var curr = ty;
    while (true) {
        switch (curr.*) {
            .borrow => |b| curr = b,
            .pointer => |p| curr = p,
            .array => |arr| curr = arr.elem,
            .tuple => |tup| {
                for (tup.elems) |t| try recordReferencedType(referenced_types, t);
                return;
            },
            .future => |f| curr = f,
            .closure => |cl| {
                for (cl.params) |t| try recordReferencedType(referenced_types, t);
                curr = cl.ret;
            },
            .fn_ptr => |fp| {
                for (fp.params) |t| try recordReferencedType(referenced_types, t);
                curr = fp.ret;
            },
            .user_defined => |ud| {
                try referenced_types.put(ud.name, {});
                for (ud.generics) |g| try recordReferencedType(referenced_types, g);
                return;
            },
            else => return,
        }
    }
}

fn recordReferencedTypesFromTypeDecl(referenced_types: *std.StringHashMap(void), decl: *const ast.Node) !void {
    switch (decl.*) {
        .struct_decl => |sd| {
            for (sd.fields) |field| try recordReferencedType(referenced_types, field.ty);
        },
        .enum_decl => |ed| {
            for (ed.variants) |variant| {
                for (variant.fields) |field| try recordReferencedType(referenced_types, field.ty);
            }
        },
        .trait_decl => |td| {
            for (td.supertraits) |supertrait| try referenced_types.put(supertrait, {});
            for (td.methods) |method| {
                for (method.params) |param| try recordReferencedType(referenced_types, param.ty);
                try recordReferencedType(referenced_types, method.ret_ty);
            }
        },
        .type_alias_decl => |alias| {
            for (alias.components) |component| {
                switch (component) {
                    .ty => |ty| try recordReferencedType(referenced_types, ty),
                    .inline_struct => |fields| for (fields) |field| try recordReferencedType(referenced_types, field.ty),
                }
            }
        },
        else => {},
    }
}

fn scanReferencedExportedTypeSignatures(
    allocator: std.mem.Allocator,
    modules: []const *SlaModule,
    referenced_types: *std.StringHashMap(void),
    scanned_type_roots: *std.StringHashMap(void),
) !bool {
    var pending = std.ArrayList(*ast.Node).init(allocator);
    defer pending.deinit();

    var referenced_iter = referenced_types.keyIterator();
    while (referenced_iter.next()) |name_ptr| {
        const name = name_ptr.*;
        if (scanned_type_roots.contains(name)) continue;
        try scanned_type_roots.put(name, {});
        for (modules) |module| {
            if (module.exports.type_decls.get(name)) |decl| {
                try pending.append(decl);
                break;
            }
        }
    }

    for (pending.items) |decl| try recordReferencedTypesFromTypeDecl(referenced_types, decl);
    return pending.items.len != 0;
}

fn markSyntacticReachableFunc(
    funcs: *const SlaCallableIndex,
    modules: ?*SlaModuleTable,
    caller_name: ?[]const u8,
    reachable: *std.StringHashMap(void),
    referenced_types: *std.StringHashMap(void),
    worklist: *std.ArrayList([]const u8),
    name: []const u8,
) !void {
    if (!funcs.names.contains(name)) {
        if (modules) |mod_table| {
            if (mod_table.functionSignatureForImportedMangledNameByNamespace(name)) |signature| {
                return try markSyntacticReachableFunc(funcs, modules, caller_name, reachable, referenced_types, worklist, signature.name);
            }
        }
        if (splitImportedMangledSymbol(name)) |imported| {
            if (funcs.names.contains(imported.name)) {
                return try markSyntacticReachableFunc(funcs, modules, caller_name, reachable, referenced_types, worklist, imported.name);
            }
        }
        return;
    }
    if (reachable.contains(name)) return;

    if (funcs.moduleSource(name)) |callee_mp| {
        const caller_mp = if (caller_name) |c| funcs.moduleSource(c) else null;
        const same_module = if (caller_mp) |caller_path| std.mem.eql(u8, callee_mp, caller_path) else false;
        if (!same_module) {
            if (modules) |mod_table| {
                if (mod_table.modules.get(callee_mp)) |mod| {
                    var exported = mod.exports.exportsSymbol(name);
                    if (!exported) {
                        if (splitImportedMangledSymbol(name)) |imported| {
                            exported = moduleNamespaceMatchesImportPath(mod.output_path, imported.namespace) and
                                mod.exports.exportsSymbol(imported.name);
                        }
                    }
                    if (!exported) {
                        return;
                    }
                }
            }
        }
    }

    try reachable.put(name, {});
    try worklist.append(name);
}

fn markSyntacticAssociatedCallCandidates(
    funcs: *const SlaCallableIndex,
    modules: ?*SlaModuleTable,
    caller_name: ?[]const u8,
    reachable: *std.StringHashMap(void),
    referenced_types: *std.StringHashMap(void),
    worklist: *std.ArrayList([]const u8),
    method_name: []const u8,
) !void {
    try markSyntacticReachableFunc(funcs, modules, caller_name, reachable, referenced_types, worklist, method_name);
    if (funcs.associated_candidates.get(method_name)) |candidates| {
        for (candidates.items) |name| try markSyntacticReachableFunc(funcs, modules, caller_name, reachable, referenced_types, worklist, name);
    }
}

fn collectSyntacticReachableExpr(
    funcs: *const SlaCallableIndex,
    modules: ?*SlaModuleTable,
    imported_macros: ?*const std.StringHashMap(type_checker_mod.ImportedMacro),
    caller_name: ?[]const u8,
    reachable: *std.StringHashMap(void),
    referenced_types: *std.StringHashMap(void),
    worklist: *std.ArrayList([]const u8),
    expr: *const ast.Node,
) anyerror!void {
    switch (expr.*) {
        .identifier => |name| {
            try markSyntacticReachableFunc(funcs, modules, caller_name, reachable, referenced_types, worklist, name);
            try referenced_types.put(name, {});
        },
        .generic_func_ref => |ref| {
            try markSyntacticReachableFunc(funcs, modules, caller_name, reachable, referenced_types, worklist, ref.func_name);
            for (ref.generics) |ty| try recordReferencedType(referenced_types, ty);
        },
        .call_expr => |call| {
            if (call.associated_target != null) {
                try markSyntacticAssociatedCallCandidates(funcs, modules, caller_name, reachable, referenced_types, worklist, call.func_name);
            } else {
                if (imported_macros) |macros| {
                    if (macros.get(call.func_name)) |macro| {
                        for (macro.direct_callees) |callee| {
                            try markSyntacticReachableFunc(funcs, modules, caller_name, reachable, referenced_types, worklist, callee);
                        }
                    }
                }
                try markSyntacticReachableFunc(funcs, modules, caller_name, reachable, referenced_types, worklist, call.func_name);
                try markSyntacticAssociatedCallCandidates(funcs, modules, caller_name, reachable, referenced_types, worklist, call.func_name);
            }
            for (call.generics) |ty| try recordReferencedType(referenced_types, ty);
            for (call.args) |arg| try collectSyntacticReachableExpr(funcs, modules, imported_macros, caller_name, reachable, referenced_types, worklist, arg);
        },
        .if_expr => |ife| {
            try collectSyntacticReachableExpr(funcs, modules, imported_macros, caller_name, reachable, referenced_types, worklist, ife.cond);
            if (ife.let_chain) |chain| {
                for (chain) |cond| try collectSyntacticReachableExpr(funcs, modules, imported_macros, caller_name, reachable, referenced_types, worklist, cond.value);
            }
            try collectSyntacticReachableBlock(funcs, modules, imported_macros, caller_name, reachable, referenced_types, worklist, ife.then_block);
            if (ife.else_block) |else_block| try collectSyntacticReachableBlock(funcs, modules, imported_macros, caller_name, reachable, referenced_types, worklist, else_block);
        },
        .switch_expr => |swe| {
            try collectSyntacticReachableExpr(funcs, modules, imported_macros, caller_name, reachable, referenced_types, worklist, swe.val);
            for (swe.cases) |case| {
                try collectSyntacticReachableExpr(funcs, modules, imported_macros, caller_name, reachable, referenced_types, worklist, case.pattern);
                try collectSyntacticReachableBlock(funcs, modules, imported_macros, caller_name, reachable, referenced_types, worklist, case.body);
            }
        },
        .match_expr => |mat| {
            try collectSyntacticReachableExpr(funcs, modules, imported_macros, caller_name, reachable, referenced_types, worklist, mat.val);
            for (mat.cases) |case| {
                if (case.guard) |guard| try collectSyntacticReachableExpr(funcs, modules, imported_macros, caller_name, reachable, referenced_types, worklist, guard);
                try collectSyntacticReachableBlock(funcs, modules, imported_macros, caller_name, reachable, referenced_types, worklist, case.body);
            }
        },
        .unsafe_expr => |unsafe_expr| try collectSyntacticReachableBlock(funcs, modules, imported_macros, caller_name, reachable, referenced_types, worklist, unsafe_expr.body),
        .await_expr => |await_expr| try collectSyntacticReachableExpr(funcs, modules, imported_macros, caller_name, reachable, referenced_types, worklist, await_expr.expr),
        .try_expr => |try_expr| try collectSyntacticReachableExpr(funcs, modules, imported_macros, caller_name, reachable, referenced_types, worklist, try_expr.expr),
        .binary_expr => |bin| {
            try collectSyntacticReachableExpr(funcs, modules, imported_macros, caller_name, reachable, referenced_types, worklist, bin.left);
            try collectSyntacticReachableExpr(funcs, modules, imported_macros, caller_name, reachable, referenced_types, worklist, bin.right);
        },
        .closure_literal => |closure| try collectSyntacticReachableExpr(funcs, modules, imported_macros, caller_name, reachable, referenced_types, worklist, closure.body),
        .borrow_expr => |borrow| try collectSyntacticReachableExpr(funcs, modules, imported_macros, caller_name, reachable, referenced_types, worklist, borrow.expr),
        .move_expr => |move| try collectSyntacticReachableExpr(funcs, modules, imported_macros, caller_name, reachable, referenced_types, worklist, move.expr),
        .deref_expr => |deref| try collectSyntacticReachableExpr(funcs, modules, imported_macros, caller_name, reachable, referenced_types, worklist, deref.expr),
        .cast_expr => |cast| {
            try recordReferencedType(referenced_types, cast.ty);
            try collectSyntacticReachableExpr(funcs, modules, imported_macros, caller_name, reachable, referenced_types, worklist, cast.expr);
        },
        .field_expr => |field| try collectSyntacticReachableExpr(funcs, modules, imported_macros, caller_name, reachable, referenced_types, worklist, field.expr),
        .struct_literal => |lit| {
            try recordReferencedType(referenced_types, lit.ty);
            for (lit.fields) |field| try collectSyntacticReachableExpr(funcs, modules, imported_macros, caller_name, reachable, referenced_types, worklist, field.value);
            if (lit.update_expr) |update| try collectSyntacticReachableExpr(funcs, modules, imported_macros, caller_name, reachable, referenced_types, worklist, update);
        },
        .enum_literal => |lit| {
            try referenced_types.put(lit.enum_name, {});
            for (lit.fields) |field| try collectSyntacticReachableExpr(funcs, modules, imported_macros, caller_name, reachable, referenced_types, worklist, field.value);
        },
        .tuple_literal => |lit| for (lit.elements) |elem| try collectSyntacticReachableExpr(funcs, modules, imported_macros, caller_name, reachable, referenced_types, worklist, elem),
        .array_literal => |lit| for (lit.elements) |elem| try collectSyntacticReachableExpr(funcs, modules, imported_macros, caller_name, reachable, referenced_types, worklist, elem),
        .repeat_array_literal => |lit| try collectSyntacticReachableExpr(funcs, modules, imported_macros, caller_name, reachable, referenced_types, worklist, lit.value),
        .index_expr => |idx| {
            try collectSyntacticReachableExpr(funcs, modules, imported_macros, caller_name, reachable, referenced_types, worklist, idx.target);
            try collectSyntacticReachableExpr(funcs, modules, imported_macros, caller_name, reachable, referenced_types, worklist, idx.index);
        },
        .slice_expr => |slice| {
            try collectSyntacticReachableExpr(funcs, modules, imported_macros, caller_name, reachable, referenced_types, worklist, slice.target);
            try collectSyntacticReachableExpr(funcs, modules, imported_macros, caller_name, reachable, referenced_types, worklist, slice.start);
            try collectSyntacticReachableExpr(funcs, modules, imported_macros, caller_name, reachable, referenced_types, worklist, slice.end);
        },
        else => {},
    }
}

fn collectSyntacticReachableBlock(
    funcs: *const SlaCallableIndex,
    modules: ?*SlaModuleTable,
    imported_macros: ?*const std.StringHashMap(type_checker_mod.ImportedMacro),
    caller_name: ?[]const u8,
    reachable: *std.StringHashMap(void),
    referenced_types: *std.StringHashMap(void),
    worklist: *std.ArrayList([]const u8),
    block: []const *ast.Node,
) anyerror!void {
    for (block) |stmt| {
        switch (stmt.*) {
            .let_stmt => |let| {
                if (let.ty) |ty| try recordReferencedType(referenced_types, ty);
                try collectSyntacticReachableExpr(funcs, modules, imported_macros, caller_name, reachable, referenced_types, worklist, let.value);
            },
            .let_else_stmt => |let| {
                try collectSyntacticReachableExpr(funcs, modules, imported_macros, caller_name, reachable, referenced_types, worklist, let.value);
                try collectSyntacticReachableBlock(funcs, modules, imported_macros, caller_name, reachable, referenced_types, worklist, let.else_block);
            },
            .let_destructure_stmt => |let| {
                try collectSyntacticReachableExpr(funcs, modules, imported_macros, caller_name, reachable, referenced_types, worklist, let.value);
            },
            .const_stmt => |c| {
                if (c.ty) |ty| try recordReferencedType(referenced_types, ty);
                try collectSyntacticReachableExpr(funcs, modules, imported_macros, caller_name, reachable, referenced_types, worklist, c.value);
            },
            .assign_stmt => |assign| {
                try collectSyntacticReachableExpr(funcs, modules, imported_macros, caller_name, reachable, referenced_types, worklist, assign.target);
                try collectSyntacticReachableExpr(funcs, modules, imported_macros, caller_name, reachable, referenced_types, worklist, assign.value);
            },
            .block_stmt => |blk| try collectSyntacticReachableBlock(funcs, modules, imported_macros, caller_name, reachable, referenced_types, worklist, blk.body),
            .expr_stmt => |expr| try collectSyntacticReachableExpr(funcs, modules, imported_macros, caller_name, reachable, referenced_types, worklist, expr),
            .return_stmt => |ret| if (ret.value) |value| try collectSyntacticReachableExpr(funcs, modules, imported_macros, caller_name, reachable, referenced_types, worklist, value),
            .for_stmt => |for_stmt| {
                try collectSyntacticReachableExpr(funcs, modules, imported_macros, caller_name, reachable, referenced_types, worklist, for_stmt.start);
                if (for_stmt.end) |end_expr| try collectSyntacticReachableExpr(funcs, modules, imported_macros, caller_name, reachable, referenced_types, worklist, end_expr);
                try collectSyntacticReachableBlock(funcs, modules, imported_macros, caller_name, reachable, referenced_types, worklist, for_stmt.body);
            },
            .while_stmt => |while_stmt| {
                try collectSyntacticReachableExpr(funcs, modules, imported_macros, caller_name, reachable, referenced_types, worklist, while_stmt.cond);
                try collectSyntacticReachableBlock(funcs, modules, imported_macros, caller_name, reachable, referenced_types, worklist, while_stmt.body);
            },
            else => try collectSyntacticReachableExpr(funcs, modules, imported_macros, caller_name, reachable, referenced_types, worklist, stmt),
        }
    }
}

fn pruneUnreachableTestFunctionDeclsBeforeTypeCheck(
    allocator: std.mem.Allocator,
    program: *ast.Node,
    imported_macros: ?*const std.StringHashMap(type_checker_mod.ImportedMacro),
    primary_decls: ?*std.AutoHashMap(*const ast.Node, void),
) !void {
    if (program.* != .program) return error.InvalidProgram;

    var callable_index = SlaCallableIndex.init(allocator);
    defer callable_index.deinit();
    try callable_index.addDecls(program.program.decls);
    if (callable_index.names.count() == 0) return;

    var reachable = std.StringHashMap(void).init(allocator);
    defer reachable.deinit();
    var referenced_types = std.StringHashMap(void).init(allocator);
    defer referenced_types.deinit();
    var worklist = std.ArrayList([]const u8).init(allocator);
    defer worklist.deinit();

    var saw_test = false;
    for (program.program.decls) |decl| {
        switch (decl.*) {
            .test_decl => |test_decl| {
                saw_test = true;
                try collectSyntacticReachableBlock(&callable_index, null, imported_macros, null, &reachable, &referenced_types, &worklist, test_decl.body);
            },
            .const_stmt => |const_stmt| {
                if (const_stmt.ty) |ty| try recordReferencedType(&referenced_types, ty);
                try collectSyntacticReachableExpr(&callable_index, null, imported_macros, null, &reachable, &referenced_types, &worklist, const_stmt.value);
            },
            .macro_decl => |macro_decl| try collectSyntacticReachableBlock(&callable_index, null, imported_macros, macro_decl.name, &reachable, &referenced_types, &worklist, macro_decl.body),
            .impl_decl => |impl_decl| {
                try recordReferencedType(&referenced_types, impl_decl.target_ty);
                if (impl_decl.trait_name) |tn| try referenced_types.put(tn, {});
                if (impl_decl.trait_name != null) {
                    for (impl_decl.methods) |method| {
                        if (method.* == .func_decl) {
                            const type_name = lowering_rules.concreteTypeName(impl_decl.target_ty) orelse continue;
                            const symbol = try lowering_rules.mangleTraitMethodName(allocator, type_name, impl_decl.trait_name.?, method.func_decl.name);
                            defer allocator.free(symbol);
                            try collectSyntacticReachableBlock(&callable_index, null, imported_macros, symbol, &reachable, &referenced_types, &worklist, method.func_decl.body);
                        }
                    }
                }
            },
            .overload_decl => |overload_decl| {
                try recordReferencedType(&referenced_types, overload_decl.target_ty);
                for (overload_decl.methods) |method| {
                    if (method.* == .func_decl) {
                        const type_name = lowering_rules.concreteTypeName(overload_decl.target_ty) orelse continue;
                        const symbol = try lowering_rules.mangleMethodName(allocator, type_name, method.func_decl.name);
                        defer allocator.free(symbol);
                        try collectSyntacticReachableBlock(&callable_index, null, imported_macros, symbol, &reachable, &referenced_types, &worklist, method.func_decl.body);
                    }
                }
            },
            else => {},
        }
    }
    if (!saw_test) return;

    var index: usize = 0;
    while (index < worklist.items.len) : (index += 1) {
        const name = worklist.items[index];
        const fd = callable_index.decls.get(name) orelse continue;
        for (fd.params) |param| {
            try recordReferencedType(&referenced_types, param.ty);
        }
        try recordReferencedType(&referenced_types, fd.ret_ty);
        try collectSyntacticReachableBlock(&callable_index, null, imported_macros, name, &reachable, &referenced_types, &worklist, fd.body);
    }

    var filtered_decls = std.ArrayList(*ast.Node).init(allocator);
    for (program.program.decls) |decl| {
        switch (decl.*) {
            .func_decl => |func_decl| {
                if (func_decl.is_decl_only or reachable.contains(func_decl.name)) {
                    try filtered_decls.append(decl);
                    if (primary_decls) |decls| try decls.put(decl, {});
                }
            },
            .impl_decl => |impl_decl| {
                if (impl_decl.trait_name != null) {
                    try filtered_decls.append(decl);
                    continue;
                }
                const type_name = lowering_rules.concreteTypeName(impl_decl.target_ty) orelse {
                    try filtered_decls.append(decl);
                    continue;
                };
                var methods = std.ArrayList(*ast.Node).init(allocator);
                for (impl_decl.methods) |method| {
                    if (method.* != .func_decl) {
                        try methods.append(method);
                        continue;
                    }
                    const symbol = if (impl_decl.trait_name) |trait_name|
                        try lowering_rules.mangleTraitMethodName(allocator, type_name, trait_name, method.func_decl.name)
                    else
                        try lowering_rules.mangleMethodName(allocator, type_name, method.func_decl.name);
                    if (method.func_decl.is_decl_only or reachable.contains(symbol)) try methods.append(method);
                }
                if (methods.items.len == impl_decl.methods.len) {
                    try filtered_decls.append(decl);
                } else if (methods.items.len > 0) {
                    const pruned = try allocator.create(ast.Node);
                    pruned.* = .{ .impl_decl = .{
                        .trait_name = impl_decl.trait_name,
                        .target_ty = impl_decl.target_ty,
                        .methods = try methods.toOwnedSlice(),
                    } };
                    try filtered_decls.append(pruned);
                }
            },
            .overload_decl => |overload_decl| {
                const type_name = lowering_rules.concreteTypeName(overload_decl.target_ty) orelse {
                    try filtered_decls.append(decl);
                    continue;
                };
                var methods = std.ArrayList(*ast.Node).init(allocator);
                for (overload_decl.methods) |method| {
                    if (method.* != .func_decl) {
                        try methods.append(method);
                        continue;
                    }
                    const symbol = try lowering_rules.mangleMethodName(allocator, type_name, method.func_decl.name);
                    if (method.func_decl.is_decl_only or reachable.contains(symbol)) try methods.append(method);
                }
                if (methods.items.len == overload_decl.methods.len) {
                    try filtered_decls.append(decl);
                } else if (methods.items.len > 0) {
                    const pruned = try allocator.create(ast.Node);
                    pruned.* = .{ .overload_decl = .{
                        .target_ty = overload_decl.target_ty,
                        .methods = try methods.toOwnedSlice(),
                    } };
                    try filtered_decls.append(pruned);
                }
            },
            else => try filtered_decls.append(decl),
        }
    }
    program.program.decls = try filtered_decls.toOwnedSlice();
}

fn pruneUnreachableFilteredTestDecls(
    allocator: std.mem.Allocator,
    program: *ast.Node,
    tc: *const type_checker_mod.TypeChecker,
    test_filter: ?[]const u8,
    force: bool,
) !void {
    if (!force and (test_filter == null or test_filter.?.len == 0)) return;
    if (program.* != .program) return error.InvalidProgram;

    var reachable = std.StringHashMap(void).init(allocator);
    var worklist = std.ArrayList([]const u8).init(allocator);

    for (program.program.decls) |decl| {
        switch (decl.*) {
            .test_decl => |test_decl| try collectReachableBlock(tc, &reachable, &worklist, test_decl.body),
            .const_stmt => |const_stmt| try collectReachableExpr(tc, &reachable, &worklist, const_stmt.value),
            else => {},
        }
    }

    var index: usize = 0;
    while (index < worklist.items.len) : (index += 1) {
        const name = worklist.items[index];
        const func = tc.funcs.get(name) orelse continue;
        try collectReachableBlock(tc, &reachable, &worklist, func.body);
    }

    var needed_trait_impls = std.StringHashMap(void).init(allocator);
    for (program.program.decls) |decl| {
        switch (decl.*) {
            .test_decl => |test_decl| try collectNeededTraitImplsBlock(allocator, tc, &needed_trait_impls, test_decl.body),
            .const_stmt => |const_stmt| try collectNeededTraitImplsExpr(allocator, tc, &needed_trait_impls, const_stmt.value),
            .func_decl => |func_decl| {
                if (reachable.contains(func_decl.name)) try collectNeededTraitImplsBlock(allocator, tc, &needed_trait_impls, func_decl.body);
            },
            .impl_decl => |impl_decl| {
                const type_name = lowering_rules.concreteTypeName(impl_decl.target_ty) orelse continue;
                for (impl_decl.methods) |method| {
                    if (method.* != .func_decl) continue;
                    const symbol = if (impl_decl.trait_name) |trait_name|
                        try lowering_rules.mangleTraitMethodName(allocator, type_name, trait_name, method.func_decl.name)
                    else
                        try lowering_rules.mangleMethodName(allocator, type_name, method.func_decl.name);
                    if (reachable.contains(symbol)) try collectNeededTraitImplsBlock(allocator, tc, &needed_trait_impls, method.func_decl.body);
                }
            },
            .overload_decl => |overload_decl| {
                const type_name = lowering_rules.concreteTypeName(overload_decl.target_ty) orelse continue;
                for (overload_decl.methods) |method| {
                    if (method.* != .func_decl) continue;
                    const symbol = try lowering_rules.mangleMethodName(allocator, type_name, method.func_decl.name);
                    if (reachable.contains(symbol)) try collectNeededTraitImplsBlock(allocator, tc, &needed_trait_impls, method.func_decl.body);
                }
            },
            else => {},
        }
    }

    var filtered_decls = std.ArrayList(*ast.Node).init(allocator);
    for (program.program.decls) |decl| {
        switch (decl.*) {
            .func_decl => |func_decl| {
                if (func_decl.is_decl_only or reachable.contains(func_decl.name)) try filtered_decls.append(decl);
            },
            .impl_decl => |impl_decl| {
                if (impl_decl.trait_name != null) {
                    const type_name = lowering_rules.concreteTypeName(impl_decl.target_ty) orelse {
                        try filtered_decls.append(decl);
                        continue;
                    };
                    const key = try std.fmt.allocPrint(allocator, "{s}|{s}", .{ impl_decl.trait_name.?, type_name });
                    var keep_impl = needed_trait_impls.contains(key);
                    if (!keep_impl) {
                        for (impl_decl.methods) |method| {
                            if (method.* != .func_decl) continue;
                            const symbol = try lowering_rules.mangleTraitMethodName(allocator, type_name, impl_decl.trait_name.?, method.func_decl.name);
                            if (reachable.contains(symbol)) {
                                keep_impl = true;
                                break;
                            }
                        }
                    }
                    if (keep_impl) try filtered_decls.append(decl);
                    continue;
                }
                const type_name = lowering_rules.concreteTypeName(impl_decl.target_ty) orelse {
                    try filtered_decls.append(decl);
                    continue;
                };

                var methods = std.ArrayList(*ast.Node).init(allocator);
                for (impl_decl.methods) |method| {
                    if (method.* != .func_decl) {
                        try methods.append(method);
                        continue;
                    }
                    const symbol = try lowering_rules.mangleMethodName(allocator, type_name, method.func_decl.name);
                    if (method.func_decl.is_decl_only or reachable.contains(symbol)) try methods.append(method);
                }
                if (methods.items.len == impl_decl.methods.len) {
                    try filtered_decls.append(decl);
                } else if (methods.items.len > 0) {
                    const pruned = try allocator.create(ast.Node);
                    pruned.* = .{ .impl_decl = .{
                        .trait_name = null,
                        .target_ty = impl_decl.target_ty,
                        .methods = try methods.toOwnedSlice(),
                    } };
                    try filtered_decls.append(pruned);
                }
            },
            .overload_decl => |overload_decl| {
                const type_name = lowering_rules.concreteTypeName(overload_decl.target_ty) orelse {
                    try filtered_decls.append(decl);
                    continue;
                };
                var methods = std.ArrayList(*ast.Node).init(allocator);
                for (overload_decl.methods) |method| {
                    if (method.* != .func_decl) {
                        try methods.append(method);
                        continue;
                    }
                    const symbol = try lowering_rules.mangleMethodName(allocator, type_name, method.func_decl.name);
                    if (method.func_decl.is_decl_only or reachable.contains(symbol)) try methods.append(method);
                }
                if (methods.items.len == overload_decl.methods.len) {
                    try filtered_decls.append(decl);
                } else if (methods.items.len > 0) {
                    const pruned = try allocator.create(ast.Node);
                    pruned.* = .{ .overload_decl = .{
                        .target_ty = overload_decl.target_ty,
                        .methods = try methods.toOwnedSlice(),
                    } };
                    try filtered_decls.append(pruned);
                }
            },
            else => try filtered_decls.append(decl),
        }
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
    return compileSlaToSaStringWithOptions(allocator, file, output_file, stderr, defaultSlaCompileOptions());
}

/// Shared SLA compilation front-end: the trunk of the Y shared by the SA-text
/// (`compileSlaToSaStringWithOptions`) and SAB (`compileSlaFileToSabWithOptions`)
/// tails. Runs the byte-identical pipeline: read -> source-expand -> parse ->
/// `@import`-expand -> test-filter -> monomorphize -> load-contracts -> type-check ->
/// primary-decl filter.
///
/// `mono` and `tc` are caller-owned: the caller must `init`/`deinit` them (and
/// keep them alive across its tail codegen, which reads back from them). On any
/// front-end failure the diagnostic is printed and `null` is returned. On success
/// the type-checked, primary-decl-filtered program is returned.
fn runSlaFrontend(
    allocator: std.mem.Allocator,
    file: []const u8,
    mono: *monomorphizer_mod.Monomorphizer,
    tc: *type_checker_mod.TypeChecker,
    options: SlaCompileOptions,
    stderr: std.io.AnyWriter,
    profile: bool,
) !?*ast.Node {
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
    const expanded_prog = expandSlaImports(allocator, prog, file, &primary_decls, .{
        .prune_for_test_codegen = options.prune_for_test_codegen,
        .test_filter = options.test_filter,
        .imported_bodies_decl_only = options.load_reachable_imported_bodies_from_registry,
        .load_reachable_imported_bodies_from_registry = options.load_reachable_imported_bodies_from_registry,
    }) catch |err| {
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
    var specialized_primary_decls = std.AutoHashMap(*const ast.Node, void).init(allocator);
    const specialized_prog = mono.monomorphize(expanded_prog, &primary_decls, &specialized_primary_decls) catch |err| {
        try stderr.print("Monomorphization Error: failed to specialize generics: {}\n", .{err});
        return null;
    };
    slaProfileStage(stderr, profile, "monomorphize", stage_start);

    stage_start = std.time.nanoTimestamp();
    loadImportedContracts(tc, allocator, specialized_prog, file) catch |err| {
        try stderr.print("Import Error: failed to load @import contracts: {}\n", .{err});
        return null;
    };
    slaProfileStage(stderr, profile, "load contracts", stage_start);

    stage_start = std.time.nanoTimestamp();
    registerImportedFunctionAliases(tc, allocator, prog, file) catch |err| {
        try stderr.print("Import Error: failed to register @import function aliases: {}\n", .{err});
        return null;
    };
    slaProfileStage(stderr, profile, "import aliases", stage_start);

    if (options.prune_for_test_codegen) {
        stage_start = std.time.nanoTimestamp();
        pruneUnreachableTestFunctionDeclsBeforeTypeCheck(allocator, specialized_prog, &tc.imported_macros, &specialized_primary_decls) catch |err| {
            try stderr.print("Test Filter Error: failed to prune unreachable functions before type checking: {}\n", .{err});
            return null;
        };
        slaProfileStage(stderr, profile, "pre-typecheck reachable decl filter", stage_start);
    }

    stage_start = std.time.nanoTimestamp();
    tc.checkProgram(specialized_prog) catch |err| {
        try stderr.print("Type Check Error: failed to verify types: {s} ({})\n", .{ tc.last_error, err });
        return null;
    };
    slaProfileStage(stderr, profile, "type check", stage_start);

    // Filter specialized_prog to only include primary declarations
    stage_start = std.time.nanoTimestamp();
    var filtered_decls = std.ArrayList(*ast.Node).init(allocator);
    for (specialized_prog.program.decls) |decl| {
        if (specialized_primary_decls.contains(decl)) {
            try filtered_decls.append(decl);
        }
    }
    specialized_prog.program.decls = try filtered_decls.toOwnedSlice();
    slaProfileStage(stderr, profile, "primary decl filter", stage_start);

    return specialized_prog;
}

fn compileSlaToSaStringWithOptions(
    allocator: std.mem.Allocator,
    file: []const u8,
    output_file: ?[]const u8,
    stderr: std.io.AnyWriter,
    options: SlaCompileOptions,
) !?[]const u8 {
    const profile = slaProfileEnabled(allocator);

    var mono = monomorphizer_mod.Monomorphizer.init(allocator);
    defer mono.deinit();
    var tc = type_checker_mod.TypeChecker.init(allocator);
    defer tc.deinit();

    const specialized_prog = (try runSlaFrontend(allocator, file, &mono, &tc, options, stderr, profile)) orelse return null;

    var stage_start = std.time.nanoTimestamp();
    rewriteProgramImportsForOutput(allocator, specialized_prog, file, output_file) catch |err| {
        try stderr.print("Import Error: failed to rewrite @import paths for output: {}\n", .{err});
        return null;
    };
    slaProfileStage(stderr, profile, "rewrite imports", stage_start);

    stage_start = std.time.nanoTimestamp();
    var cg = codegen_mod.Codegen.init(allocator, &tc);
    defer cg.deinit();

    const sa_code = cg.generate(specialized_prog) catch |err| {
        try stderr.print("Codegen Error: failed to generate SA code: {}\n", .{err});
        if (@errorReturnTrace()) |trace| std.debug.dumpStackTrace(trace.*);
        return null;
    };
    slaProfileStage(stderr, profile, "sa codegen", stage_start);
    return sa_code;
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
    try appendDefaultJobsAuto(argv, args);
}

fn hasJobsArg(args: []const []const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--jobs") or std.mem.startsWith(u8, arg, "--jobs=")) return true;
    }
    return false;
}

fn appendDefaultJobsAuto(argv: *std.ArrayList([]const u8), args: []const []const u8) !void {
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

fn runSlaStabilityCommand(allocator: std.mem.Allocator, args: []const []const u8, option_start: usize, stdout: std.io.AnyWriter, stderr: std.io.AnyWriter, default_json_mode: bool) !u8 {
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

fn commandUsage(command: []const u8) []const u8 {
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

fn managedSabTestPath(allocator: std.mem.Allocator, file: []const u8, extra_args: []const []const u8) ![]u8 {
    if (saTestFilterFromArgs(extra_args)) |filter| {
        return try managedSabPathWithVariantParts(allocator, file, "test-filter", filter);
    }
    return try managedSabPathWithVariant(allocator, file, "test-all");
}

fn writeSabFile(allocator: std.mem.Allocator, path: []const u8, sab_bytes: []const u8, stderr: std.io.AnyWriter) !bool {
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

fn writeManagedSab(allocator: std.mem.Allocator, file: []const u8, sab_bytes: []const u8, stderr: std.io.AnyWriter) !?[]u8 {
    const path = try managedSabPath(allocator, file);
    if (!try writeSabFile(allocator, path, sab_bytes, stderr)) return null;
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
    try appendDefaultJobsAuto(argv, args);
}

fn compileSlaFileToSab(
    allocator: std.mem.Allocator,
    file: []const u8,
    output_file: []const u8,
    stderr: std.io.AnyWriter,
) !?[]u8 {
    return compileSlaFileToSabWithOptions(allocator, file, output_file, stderr, defaultSlaCompileOptions());
}

fn virtualSaPathForSabOutput(allocator: std.mem.Allocator, output_file: []const u8) ![]const u8 {
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

fn sabSaStdRoot(allocator: std.mem.Allocator) ![]const u8 {
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

fn sabProjectRoot(allocator: std.mem.Allocator, source_file: []const u8) ![]const u8 {
    const source_abs = std.fs.cwd().realpathAlloc(allocator, source_file) catch return std.fs.cwd().realpathAlloc(allocator, ".");
    const source_dir = std.fs.path.dirname(source_abs) orelse ".";
    var resolution = sla_workspace.resolveFromRootPath(allocator, source_dir, .{}) catch return std.fs.cwd().realpathAlloc(allocator, ".");
    defer resolution.deinit(allocator);
    return try allocator.dupe(u8, resolution.workspace_root);
}

fn encodeSaTextAsSab(
    allocator: std.mem.Allocator,
    source_file: []const u8,
    source_path: []const u8,
    sa_code: []const u8,
    stderr: std.io.AnyWriter,
    profile: bool,
) !?[]u8 {
    if (std.fs.path.dirname(source_path)) |dir| {
        std.fs.cwd().makePath(dir) catch |err| {
            try stderr.print("File Error: failed to create SAB work directory {s}: {}\n", .{ dir, err });
            return null;
        };
    }

    const project_root = sabProjectRoot(allocator, source_file) catch |err| {
        try stderr.print("SAB Error: failed to resolve project root for {s}: {}\n", .{ source_file, err });
        return null;
    };
    const std_root = sabSaStdRoot(allocator) catch |err| {
        try stderr.print("SAB Error: failed to resolve SA std root: {}\n", .{err});
        return null;
    };
    const resolve_ctx = sci_bridge.flattener.ResolveContext{ .options = .{ .project_root = project_root, .std_root = std_root } };

    var stage_start = std.time.nanoTimestamp();
    var flat = sci_bridge.flattener.flattenFileWithPackages(allocator, source_path, sa_code, resolve_ctx) catch |err| {
        try stderr.print("SAB Error: failed to flatten SA-compatible lowering {s}: {}\n", .{ source_path, err });
        return null;
    };
    defer flat.deinit(allocator);
    slaProfileStage(stderr, profile, "sa flatten", stage_start);

    stage_start = std.time.nanoTimestamp();
    const sab_bytes = sci_bridge.encodeSabFromFlat(allocator, &flat) catch |err| {
        try stderr.print("SAB Error: failed to encode SAB for {s}: {}\n", .{ source_path, err });
        return null;
    };
    slaProfileStage(stderr, profile, "sab encode", stage_start);
    return sab_bytes;
}

fn compileTypedSlaProgramToCompatibleSab(
    allocator: std.mem.Allocator,
    tc: *type_checker_mod.TypeChecker,
    program: *ast.Node,
    source_file: []const u8,
    output_file: []const u8,
    stderr: std.io.AnyWriter,
    profile: bool,
) !?[]u8 {
    const stage_start = std.time.nanoTimestamp();
    rewriteProgramImportsForOutput(allocator, program, source_file, output_file) catch |err| {
        try stderr.print("Import Error: failed to rewrite @import paths for SAB output: {}\n", .{err});
        return null;
    };

    var cg = codegen_mod.Codegen.init(allocator, tc);
    defer cg.deinit();
    const sa_code = cg.generate(program) catch |err| {
        try stderr.print("SAB Error: failed to lower SLA through SA-compatible SAB path: {}\n", .{err});
        return null;
    };
    slaProfileStage(stderr, profile, "sa-compatible codegen", stage_start);

    const virtual_sa_path = try virtualSaPathForSabOutput(allocator, output_file);
    return try encodeSaTextAsSab(allocator, source_file, virtual_sa_path, sa_code, stderr, profile);
}

fn compileSlaFileToSabWithOptions(
    allocator: std.mem.Allocator,
    file: []const u8,
    output_file: []const u8,
    stderr: std.io.AnyWriter,
    options: SlaCompileOptions,
) !?[]u8 {
    const profile = slaProfileEnabled(allocator);

    var mono = monomorphizer_mod.Monomorphizer.init(allocator);
    defer mono.deinit();
    var tc = type_checker_mod.TypeChecker.init(allocator);
    defer tc.deinit();

    const specialized_prog = (try runSlaFrontend(allocator, file, &mono, &tc, options, stderr, profile)) orelse return null;

    var stage_start = std.time.nanoTimestamp();
    pruneUnreachableFilteredTestDecls(allocator, specialized_prog, &tc, options.test_filter, options.prune_for_test_codegen) catch |err| {
        try stderr.print("Test Filter Error: failed to prune unreachable declarations: {}\n", .{err});
        return null;
    };
    slaProfileStage(stderr, profile, "reachable decl filter", stage_start);

    stage_start = std.time.nanoTimestamp();
    const sab_bytes = sab_codegen_mod.generate(allocator, &tc, specialized_prog) catch |err| {
        slaProfileStage(stderr, profile, "sab direct codegen", stage_start);
        switch (err) {
            error.OutOfMemory => return err,
            else => {
                if (!slaSabFallbackAllowed(allocator, options)) {
                    try stderr.print("SAB Direct Error: direct SLA-to-SAB lowering failed without fallback: {}\n", .{err});
                    return null;
                }
                return try compileTypedSlaProgramToCompatibleSab(allocator, &tc, specialized_prog, file, output_file, stderr, profile);
            },
        }
    };
    slaProfileStage(stderr, profile, "sab direct codegen", stage_start);
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
) !?CompiledTestInput {
    const sab_out = try managedSabTestPath(allocator, file, extra_args);
    const sab_bytes = (try compileSlaFileToSabWithOptions(allocator, file, sab_out, stderr, .{
        .test_filter = saTestFilterFromArgs(extra_args),
        .prune_for_test_codegen = true,
        .load_reachable_imported_bodies_from_registry = true,
    })) orelse return null;
    if (!try writeSabFile(allocator, sab_out, sab_bytes, stderr)) return null;
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
        .prune_for_test_codegen = true,
        .load_reachable_imported_bodies_from_registry = true,
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
        if (!try writeSabFile(allocator, final_out, sab_bytes, stderr)) return 1;
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
        if (!try writeSabFile(allocator, sab_out, sab_bytes, stderr)) return 1;
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
        try stderr.writeAll("  stability  schema|verify ...\n");
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
    if (std.mem.eql(u8, cmd, "stability")) {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        return try runSlaStabilityCommand(arena.allocator(), args, 3, stdout, stderr, ctx.json_mode);
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
        if (!try writeSabFile(allocator, sab_out, sab_bytes, stderr)) return 1;
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
        try appendDefaultJobsAuto(&argv, extra_args);

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
        if (!try writeSabFile(allocator, sab_out, sab_bytes, stderr)) return 1;
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
        try appendDefaultJobsAuto(&argv, extra_args);

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
        const expanded_prog = expandSlaImports(allocator, prog, file, &primary_decls, .{
            .imported_bodies_decl_only = true,
        }) catch |err| {
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

        registerImportedFunctionAliases(&tc, allocator, prog, file) catch |err| {
            try stderr.print("Import Error: failed to register @import function aliases: {}\n", .{err});
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

        const test_filter = saTestFilterFromArgs(extra_args);
        if ((try testFilterSelectsNoTests(allocator, file, test_filter, stderr)) orelse false) {
            try writeEmptyTestResult(stdout);
            return 0;
        }

        const test_input = switch (backend) {
            .auto, .sab => (try compileSlaSabTestInput(allocator, file, stderr, extra_args, options.emit_sab_file)) orelse return 1,
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

test "sla stability schema emits json schema" {
    var stdout_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stdout_buf.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    var ctx = plugin_api.Context{ .allocator = std.testing.allocator };
    const args = [_][]const u8{ "sa", "sla", "stability", "schema" };
    const code = try runSlaCommandImpl(&ctx, args[0..], stdout_buf.writer().any(), stderr_buf.writer().any());

    try std.testing.expectEqual(@as(?u8, 0), code);
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buf.items, 1, "\"schema_version\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buf.items, 1, "\"artifacts\""));
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
}

test "sla stability verify emits json report" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};
    try tmp.dir.writeFile(.{ .sub_path = "stability.json", .data = stability_metadata.example_manifest_json });

    var stdout_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stdout_buf.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    var ctx = plugin_api.Context{ .allocator = std.testing.allocator };
    const args = [_][]const u8{ "sa", "sla", "stability", "verify", "stability.json", "--json" };
    const code = try runSlaCommandImpl(&ctx, args[0..], stdout_buf.writer().any(), stderr_buf.writer().any());

    try std.testing.expectEqual(@as(?u8, 0), code);
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buf.items, 1, "\"status\":\"ok\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buf.items, 1, "\"labels\":5"));
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
}

test "sla stability verify rejects undeclared labels" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};
    try tmp.dir.writeFile(.{
        .sub_path = "bad_stability.json",
        .data =
        \\
        \\{
        \\  "schema_version": 1,
        \\  "labels": [{ "name": "stable-demo", "description": "demo" }],
        \\  "artifacts": [{ "path": "demo.sla", "labels": ["verified-sab-backend"] }]
        \\}
        \\
        ,
    });

    var stdout_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stdout_buf.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    var ctx = plugin_api.Context{ .allocator = std.testing.allocator };
    const args = [_][]const u8{ "sa", "sla", "stability", "verify", "bad_stability.json", "--json" };
    const code = try runSlaCommandImpl(&ctx, args[0..], stdout_buf.writer().any(), stderr_buf.writer().any());

    try std.testing.expectEqual(@as(?u8, 1), code);
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buf.items, 1, "\"status\":\"error\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buf.items, 1, "undeclared label"));
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
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

    var workspace_argv = std.ArrayList([]const u8).init(std.testing.allocator);
    defer workspace_argv.deinit();
    try appendSabWorkspacePassthrough(&workspace_argv, &.{ "--sab-out", "/tmp/out.sab", "-o", "/tmp/app" });
    try std.testing.expectEqualStrings("-o", workspace_argv.items[0]);
    try std.testing.expectEqualStrings("/tmp/app", workspace_argv.items[1]);
    try std.testing.expectEqualStrings("--jobs", workspace_argv.items[2]);
    try std.testing.expectEqualStrings("auto", workspace_argv.items[3]);
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

test "sla check uses imported signatures without checking imported function bodies" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const dep_source =
        \\fn imported_a() -> i32 {
        \\    return missing_symbol();
        \\}
    ;
    const main_source =
        \\@import "dep.sla"
        \\
        \\fn main() -> i32 {
        \\    return dep::imported_a();
        \\}
    ;
    try tmp.dir.writeFile(.{ .sub_path = "dep.sla", .data = dep_source });
    try tmp.dir.writeFile(.{ .sub_path = "main.sla", .data = main_source });

    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var stdout_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stdout_buf.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    var ctx = plugin_api.Context{ .allocator = std.testing.allocator };
    const args = [_][]const u8{ "sa", "sla", "check", "main.sla" };
    const code = try runSlaCommandImpl(&ctx, args[0..], stdout_buf.writer().any(), stderr_buf.writer().any());

    if (code != @as(?u8, 0)) std.debug.print("{s}", .{stderr_buf.items});
    try std.testing.expectEqual(@as(?u8, 0), code);
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buf.items, 1, "Successfully parsed and verified"));
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
}

test "sla check uses imported method signatures without checking imported method bodies" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const dep_source =
        \\struct ImportedBox {
        \\    value: i32,
        \\}
        \\
        \\impl ImportedBox {
        \\    fn used(self) -> i32 {
        \\        return missing_symbol();
        \\    }
        \\}
    ;
    const main_source =
        \\@import "dep.sla"
        \\
        \\fn main() -> i32 {
        \\    let item = ImportedBox { value: 7 };
        \\    return item.used();
        \\}
    ;
    try tmp.dir.writeFile(.{ .sub_path = "dep.sla", .data = dep_source });
    try tmp.dir.writeFile(.{ .sub_path = "main.sla", .data = main_source });

    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var stdout_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stdout_buf.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    var ctx = plugin_api.Context{ .allocator = std.testing.allocator };
    const args = [_][]const u8{ "sa", "sla", "check", "main.sla" };
    const code = try runSlaCommandImpl(&ctx, args[0..], stdout_buf.writer().any(), stderr_buf.writer().any());

    if (code != @as(?u8, 0)) std.debug.print("{s}", .{stderr_buf.items});
    try std.testing.expectEqual(@as(?u8, 0), code);
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buf.items, 1, "Successfully parsed and verified"));
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
}

test "sla check uses imported trait method signatures without checking imported trait bodies" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const dep_source =
        \\trait Label {
        \\    fn label(self) -> i32;
        \\}
        \\
        \\struct ImportedThing {
        \\    value: i32,
        \\}
        \\
        \\impl Label for ImportedThing {
        \\    fn label(self) -> i32 {
        \\        return missing_trait_symbol();
        \\    }
        \\}
    ;
    const main_source =
        \\@import "dep.sla"
        \\
        \\fn main() -> i32 {
        \\    let item = ImportedThing { value: 7 };
        \\    return item.label();
        \\}
    ;
    try tmp.dir.writeFile(.{ .sub_path = "dep.sla", .data = dep_source });
    try tmp.dir.writeFile(.{ .sub_path = "main.sla", .data = main_source });

    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var stdout_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stdout_buf.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    var ctx = plugin_api.Context{ .allocator = std.testing.allocator };
    const args = [_][]const u8{ "sa", "sla", "check", "main.sla" };
    const code = try runSlaCommandImpl(&ctx, args[0..], stdout_buf.writer().any(), stderr_buf.writer().any());

    if (code != @as(?u8, 0)) std.debug.print("{s}", .{stderr_buf.items});
    try std.testing.expectEqual(@as(?u8, 0), code);
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buf.items, 1, "Successfully parsed and verified"));
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
}

test "sla check uses imported trait associated signatures without checking imported trait bodies" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const dep_source =
        \\trait Score {
        \\    fn score(self) -> i32;
        \\}
        \\
        \\struct ImportedScore {
        \\    value: i32,
        \\}
        \\
        \\impl Score for ImportedScore {
        \\    fn score(self) -> i32 {
        \\        return missing_score_symbol();
        \\    }
        \\}
    ;
    const main_source =
        \\@import "dep.sla"
        \\
        \\fn main() -> i32 {
        \\    let item = ImportedScore { value: 9 };
        \\    return Score::score(item);
        \\}
    ;
    try tmp.dir.writeFile(.{ .sub_path = "dep.sla", .data = dep_source });
    try tmp.dir.writeFile(.{ .sub_path = "main.sla", .data = main_source });

    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var stdout_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stdout_buf.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    var ctx = plugin_api.Context{ .allocator = std.testing.allocator };
    const args = [_][]const u8{ "sa", "sla", "check", "main.sla" };
    const code = try runSlaCommandImpl(&ctx, args[0..], stdout_buf.writer().any(), stderr_buf.writer().any());

    if (code != @as(?u8, 0)) std.debug.print("{s}", .{stderr_buf.items});
    try std.testing.expectEqual(@as(?u8, 0), code);
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buf.items, 1, "Successfully parsed and verified"));
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
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

test "sla test codegen prunes unreachable functions before type checking" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const source =
        \\fn used_value() -> i32 {
        \\    return 7;
        \\};
        \\
        \\fn unused_broken_value() -> i32 {
        \\    return missing_symbol();
        \\};
        \\
        \\@test "reachable function only"() {
        \\    let got = used_value();
        \\    if got != 7 { panic(24003); };
        \\};
    ;
    try tmp.dir.writeFile(.{ .sub_path = "reachable_only.sla", .data = source });

    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    const sa_code = (try compileSlaToSaStringWithOptions(
        arena.allocator(),
        "reachable_only.sla",
        "reachable_only.test.sa",
        stderr_buf.writer().any(),
        .{ .prune_for_test_codegen = true },
    )) orelse {
        std.debug.print("{s}", .{stderr_buf.items});
        return error.TestUnexpectedResult;
    };

    try std.testing.expect(std.mem.indexOf(u8, sa_code, "sla__used_value") != null);
    try std.testing.expect(std.mem.indexOf(u8, sa_code, "unused_broken_value") == null);
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
}

test "sla test import expansion prunes unreachable imported functions" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const dep_source =
        \\fn used_import() -> i32 {
        \\    return import_helper();
        \\};
        \\
        \\fn import_helper() -> i32 {
        \\    return 41;
        \\};
        \\
        \\fn unused_import() -> i32 {
        \\    return 99;
        \\};
    ;
    const main_source =
        \\@import "dep.sla"
        \\
        \\@test "reachable import only"() {
        \\    let got = used_import();
        \\    if got != 41 { panic(24006); };
        \\};
    ;
    try tmp.dir.writeFile(.{ .sub_path = "dep.sla", .data = dep_source });
    try tmp.dir.writeFile(.{ .sub_path = "main.sla", .data = main_source });

    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const expanded_content = try source_expand.expand(allocator, main_source);
    var parser = parser_mod.Parser.initWithDir(allocator, expanded_content, ".");
    const prog = try parser.parseProgram();
    var primary_decls = std.AutoHashMap(*const ast.Node, void).init(allocator);
    const expanded_prog = try expandSlaImports(allocator, prog, "main.sla", &primary_decls, .{
        .prune_for_test_codegen = true,
    });

    var saw_used = false;
    var saw_helper = false;
    var saw_unused = false;
    for (expanded_prog.program.decls) |decl| {
        if (decl.* != .func_decl) continue;
        if (std.mem.eql(u8, decl.func_decl.name, "used_import")) saw_used = true;
        if (std.mem.eql(u8, decl.func_decl.name, "import_helper")) saw_helper = true;
        if (std.mem.eql(u8, decl.func_decl.name, "unused_import")) saw_unused = true;
    }
    try std.testing.expect(saw_used);
    try std.testing.expect(saw_helper);
    try std.testing.expect(!saw_unused);
}

test "sla test import expansion prunes unreachable imported methods" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const dep_source =
        \\struct ImportedBox {
        \\    value: i32,
        \\}
        \\
        \\impl ImportedBox {
        \\    fn used(self) -> i32 {
        \\        return self.value;
        \\    }
        \\
        \\    fn unused_broken(self) -> i32 {
        \\        return missing_import_method_symbol();
        \\    }
        \\}
    ;
    const main_source =
        \\@import "dep.sla"
        \\
        \\@test "reachable import method only"() {
        \\    let item = ImportedBox { value: 44 };
        \\    let got = item.used();
        \\    if got != 44 { panic(24008); };
        \\};
    ;
    try tmp.dir.writeFile(.{ .sub_path = "dep.sla", .data = dep_source });
    try tmp.dir.writeFile(.{ .sub_path = "main.sla", .data = main_source });

    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    const sa_code = (try compileSlaToSaStringWithOptions(
        arena.allocator(),
        "main.sla",
        "main.test.sa",
        stderr_buf.writer().any(),
        .{ .prune_for_test_codegen = true },
    )) orelse {
        std.debug.print("{s}", .{stderr_buf.items});
        return error.TestUnexpectedResult;
    };

    try std.testing.expect(std.mem.indexOf(u8, sa_code, "ImportedBox_used") != null);
    try std.testing.expect(std.mem.indexOf(u8, sa_code, "unused_broken") == null);
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
}

test "sla test codegen uses registry loaded imported bodies" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const dep_source =
        \\trait Label {
        \\    fn label(self) -> i32;
        \\    fn unused_trait(self) -> i32;
        \\}
        \\
        \\struct ImportedThing {
        \\    value: i32,
        \\}
        \\
        \\fn imported_value() -> i32 {
        \\    return 68;
        \\}
        \\
        \\fn unused_bad() -> MissingType {
        \\    return nope();
        \\}
        \\
        \\impl ImportedThing {
        \\    fn used(self) -> i32 {
        \\        return self.value;
        \\    }
        \\}
        \\
        \\impl Label for ImportedThing {
        \\    fn label(self) -> i32 {
        \\        return self.value + 1;
        \\    }
        \\
        \\    fn unused_trait(self) -> i32 {
        \\        return missing_trait_body();
        \\    }
        \\}
    ;
    const main_source =
        \\@import "dep.sla"
        \\
        \\@test "registry loaded test body"() {
        \\    let item = ImportedThing { value: imported_value() };
        \\    let got = item.used() + item.label();
        \\    if got != 137 { panic(24137); };
        \\};
    ;
    try tmp.dir.writeFile(.{ .sub_path = "dep.sla", .data = dep_source });
    try tmp.dir.writeFile(.{ .sub_path = "main.sla", .data = main_source });

    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var sa_stderr = std.ArrayList(u8).init(std.testing.allocator);
    defer sa_stderr.deinit();
    const sa_compiled = try compileSlaSaTestInput(allocator, "main.sla", sa_stderr.writer().any(), &.{}, false);
    if (sa_compiled) |compiled| {
        defer if (compiled.delete_after) std.fs.cwd().deleteFile(compiled.path) catch {};
        const sa_code = try std.fs.cwd().readFileAlloc(allocator, compiled.path, 10 * 1024 * 1024);
        try std.testing.expect(std.mem.indexOf(u8, sa_code, "sla__imported_value") != null);
        try std.testing.expect(std.mem.indexOf(u8, sa_code, "ImportedThing_used") != null);
        try std.testing.expect(std.mem.indexOf(u8, sa_code, "ImportedThing__Label_label") != null);
        try std.testing.expect(std.mem.indexOf(u8, sa_code, "unused_bad") == null);
        try std.testing.expect(std.mem.indexOf(u8, sa_code, "missing_trait_body") == null);
    } else {
        std.debug.print("{s}", .{sa_stderr.items});
        return error.TestUnexpectedResult;
    }
    try std.testing.expectEqual(@as(usize, 0), sa_stderr.items.len);

    var sab_stderr = std.ArrayList(u8).init(std.testing.allocator);
    defer sab_stderr.deinit();
    const sab_compiled = try compileSlaSabTestInput(allocator, "main.sla", sab_stderr.writer().any(), &.{}, false);
    if (sab_compiled) |compiled| {
        defer if (compiled.delete_after) std.fs.cwd().deleteFile(compiled.path) catch {};
        const sab_bytes = try std.fs.cwd().readFileAlloc(allocator, compiled.path, 10 * 1024 * 1024);
        var module = try sci_bridge.sab.decodeModule(std.testing.allocator, sab_bytes);
        defer module.deinit(std.testing.allocator);

        var saw_value = false;
        var saw_used = false;
        var saw_label = false;
        var saw_unused_bad = false;
        var saw_unused_trait = false;
        for (module.function_sigs) |fsig| {
            if (std.mem.indexOf(u8, fsig.name, "imported_value") != null) saw_value = true;
            if (std.mem.indexOf(u8, fsig.name, "ImportedThing_used") != null) saw_used = true;
            if (std.mem.indexOf(u8, fsig.name, "ImportedThing__Label_label") != null) saw_label = true;
            if (std.mem.indexOf(u8, fsig.name, "unused_bad") != null) saw_unused_bad = true;
            if (std.mem.indexOf(u8, fsig.name, "unused_trait") != null) saw_unused_trait = true;
        }
        try std.testing.expect(saw_value);
        try std.testing.expect(saw_used);
        try std.testing.expect(saw_label);
        try std.testing.expect(!saw_unused_bad);
        try std.testing.expect(!saw_unused_trait);
    } else {
        std.debug.print("{s}", .{sab_stderr.items});
        return error.TestUnexpectedResult;
    }
    try std.testing.expectEqual(@as(usize, 0), sab_stderr.items.len);
}

test "sla test codegen keeps imported macro direct callee" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const macro_source =
        \\[MACRO] TEST_IMPORTED_PAIR_SUM %out, %value
        \\    %out = call @sla__macro_pair_sum(&%value)
        \\[END_MACRO]
    ;
    const main_source =
        \\@import "imported_macros.sa"
        \\
        \\struct Pair { left: i64, right: i64 }
        \\
        \\fn macro_pair_sum(value: &Pair) -> i64 {
        \\    value.left + value.right
        \\}
        \\
        \\fn use_imported_macro() -> i64 {
        \\    let pair = Pair { left: 31, right: 11 };
        \\    TEST_IMPORTED_PAIR_SUM(pair)
        \\}
        \\
        \\@test "imported macro callee stays reachable"() {
        \\    if use_imported_macro() != 42 { panic(24042); };
        \\};
    ;
    try tmp.dir.writeFile(.{ .sub_path = "imported_macros.sa", .data = macro_source });
    try tmp.dir.writeFile(.{ .sub_path = "main.sla", .data = main_source });

    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const expanded_content = try source_expand.expand(allocator, main_source);
    var parser = parser_mod.Parser.initWithDir(allocator, expanded_content, ".");
    const prog = try parser.parseProgram();
    var macro_tc = type_checker_mod.TypeChecker.init(allocator);
    defer macro_tc.deinit();
    try loadImportedContracts(&macro_tc, allocator, prog, "main.sla");
    const imported_macro = macro_tc.imported_macros.get("TEST_IMPORTED_PAIR_SUM");
    try std.testing.expect(imported_macro != null);
    try std.testing.expectEqual(@as(usize, 1), imported_macro.?.direct_callees.len);
    try std.testing.expectEqualStrings("macro_pair_sum", imported_macro.?.direct_callees[0]);

    var modules = SlaModuleTable.init(allocator);
    defer modules.deinit();
    var reachable = std.StringHashMap(void).init(allocator);
    var referenced_types = std.StringHashMap(void).init(allocator);
    try buildReachableSymbols(allocator, prog, &.{}, &modules, .{ .prune_for_test_codegen = true }, &macro_tc.imported_macros, &reachable, &referenced_types);
    try std.testing.expect(reachable.contains("use_imported_macro"));
    try std.testing.expect(reachable.contains("macro_pair_sum"));

    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();
    const compiled = try compileSlaSaTestInput(allocator, "main.sla", stderr_buf.writer().any(), &.{}, false);
    if (compiled) |test_input| {
        defer if (test_input.delete_after) std.fs.cwd().deleteFile(test_input.path) catch {};
        const sa_code = try std.fs.cwd().readFileAlloc(allocator, test_input.path, 10 * 1024 * 1024);
        try std.testing.expect(std.mem.indexOf(u8, sa_code, "EXPAND TEST_IMPORTED_PAIR_SUM") != null);
        try std.testing.expect(std.mem.indexOf(u8, sa_code, "@sla__macro_pair_sum(value") != null);
    } else {
        std.debug.print("{s}", .{stderr_buf.items});
        return error.TestUnexpectedResult;
    }
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
}

test "sla module namespace call resolves through imported function alias" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const dep_source =
        \\fn imported_a() -> i32 {
        \\    return 7;
        \\}
    ;
    const main_source =
        \\@import "dep.sla"
        \\
        \\@test "namespace import call"() {
        \\    let got = dep::imported_a();
        \\    if got != 7 { panic(24013); };
        \\};
    ;
    try tmp.dir.writeFile(.{ .sub_path = "dep.sla", .data = dep_source });
    try tmp.dir.writeFile(.{ .sub_path = "main.sla", .data = main_source });

    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    const sa_code = (try compileSlaToSaStringWithOptions(
        arena.allocator(),
        "main.sla",
        "main.test.sa",
        stderr_buf.writer().any(),
        .{ .prune_for_test_codegen = true },
    )) orelse {
        std.debug.print("{s}", .{stderr_buf.items});
        return error.TestUnexpectedResult;
    };

    try std.testing.expect(std.mem.indexOf(u8, sa_code, "sla__dep__imported_a") != null);
    try std.testing.expect(std.mem.indexOf(u8, sa_code, "call @sla__dep__imported_a") != null);
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);

    var sab_stderr = std.ArrayList(u8).init(std.testing.allocator);
    defer sab_stderr.deinit();
    const sab_compiled = try compileSlaSabTestInput(arena.allocator(), "main.sla", sab_stderr.writer().any(), &.{}, false);
    if (sab_compiled) |compiled| {
        defer if (compiled.delete_after) std.fs.cwd().deleteFile(compiled.path) catch {};
        const sab_bytes = try std.fs.cwd().readFileAlloc(arena.allocator(), compiled.path, 10 * 1024 * 1024);
        var module = try sci_bridge.sab.decodeModule(std.testing.allocator, sab_bytes);
        defer module.deinit(std.testing.allocator);

        var saw_alias_sig = false;
        for (module.function_sigs) |fsig| {
            if (std.mem.indexOf(u8, fsig.name, "dep__imported_a") != null) saw_alias_sig = true;
        }
        try std.testing.expect(saw_alias_sig);

        const disasm = try sci_bridge.disasmSabAlloc(arena.allocator(), sab_bytes);
        try std.testing.expect(std.mem.indexOf(u8, disasm, "\"@sla__dep__imported_a\"") != null);
    } else {
        std.debug.print("{s}", .{sab_stderr.items});
        return error.TestUnexpectedResult;
    }
    try std.testing.expectEqual(@as(usize, 0), sab_stderr.items.len);
}

test "sla imported function aliases retain namespace metadata" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "dep.sla",
        .data =
        \\fn imported_a() -> i32 {
        \\    return 7;
        \\}
        ,
    });
    try tmp.dir.writeFile(.{
        .sub_path = "sibling.sla",
        .data =
        \\fn imported_a() -> i32 {
        \\    return 100;
        \\}
        ,
    });
    try tmp.dir.writeFile(.{
        .sub_path = "main.sla",
        .data =
        \\@import "dep.sla"
        \\@import "sibling.sla"
        \\
        \\fn main() -> i32 {
        \\    return dep::imported_a() + sibling::imported_a();
        \\}
        ,
    });

    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const main_source = try std.fs.cwd().readFileAlloc(allocator, "main.sla", 1024 * 1024);
    const expanded_main = try source_expand.expand(allocator, main_source);
    var parser = parser_mod.Parser.initWithDir(allocator, expanded_main, ".");
    const prog = try parser.parseProgram();

    var tc = type_checker_mod.TypeChecker.init(allocator);
    defer tc.deinit();
    try registerImportedFunctionAliases(&tc, allocator, prog, "main.sla");

    const dep_meta = tc.resolveFunctionAliasMetadata("dep__imported_a");
    const sibling_meta = tc.resolveFunctionAliasMetadata("sibling__imported_a");
    try std.testing.expect(dep_meta != null);
    try std.testing.expect(sibling_meta != null);
    try std.testing.expectEqualStrings("imported_a", tc.resolveFunctionAlias("dep__imported_a"));
    try std.testing.expectEqualStrings("imported_a", tc.resolveFunctionAlias("sibling__imported_a"));
    try std.testing.expectEqualStrings("dep", dep_meta.?.namespace.?);
    try std.testing.expectEqualStrings("sibling", sibling_meta.?.namespace.?);
    try std.testing.expect(dep_meta.?.module_path != null);
    try std.testing.expect(sibling_meta.?.module_path != null);
    try std.testing.expect(std.mem.endsWith(u8, dep_meta.?.module_path.?, "dep.sla"));
    try std.testing.expect(std.mem.endsWith(u8, sibling_meta.?.module_path.?, "sibling.sla"));

    const main_func = prog.program.decls[2].func_decl;
    const return_expr = main_func.body[0].return_stmt.value.?;
    const dep_call = return_expr.binary_expr.left;
    const sibling_call = return_expr.binary_expr.right;
    try tc.checkProgram(prog);
    try std.testing.expectEqualStrings("imported_a", tc.resolved_call_symbols.get(dep_call).?);
    try std.testing.expectEqualStrings("imported_a", tc.resolved_call_symbols.get(sibling_call).?);
    const dep_call_meta = tc.resolved_call_alias_metadata.get(dep_call);
    const sibling_call_meta = tc.resolved_call_alias_metadata.get(sibling_call);
    try std.testing.expect(dep_call_meta != null);
    try std.testing.expect(sibling_call_meta != null);
    try std.testing.expectEqualStrings("dep", dep_call_meta.?.namespace.?);
    try std.testing.expectEqualStrings("sibling", sibling_call_meta.?.namespace.?);
    try std.testing.expect(std.mem.endsWith(u8, dep_call_meta.?.module_path.?, "dep.sla"));
    try std.testing.expect(std.mem.endsWith(u8, sibling_call_meta.?.module_path.?, "sibling.sla"));
}

test "sla module namespace aliases isolate same named imported functions" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "dep.sla",
        .data =
        \\fn imported_a() -> i32 {
        \\    return 7;
        \\}
        ,
    });
    try tmp.dir.writeFile(.{
        .sub_path = "sibling.sla",
        .data =
        \\fn imported_a() -> i32 {
        \\    return 100;
        \\}
        ,
    });
    try tmp.dir.writeFile(.{
        .sub_path = "main.sla",
        .data =
        \\@import "dep.sla"
        \\@import "sibling.sla"
        \\
        \\@test "namespace import collision"() {
        \\    let got = dep::imported_a() + sibling::imported_a();
        \\    if got != 107 { panic(24014); };
        \\};
        ,
    });

    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var sa_stderr = std.ArrayList(u8).init(std.testing.allocator);
    defer sa_stderr.deinit();
    const sa_code = (try compileSlaToSaStringWithOptions(
        allocator,
        "main.sla",
        "main.test.sa",
        sa_stderr.writer().any(),
        .{ .prune_for_test_codegen = true },
    )) orelse {
        std.debug.print("{s}", .{sa_stderr.items});
        return error.TestUnexpectedResult;
    };
    try std.testing.expect(std.mem.indexOf(u8, sa_code, "sla__dep__imported_a") != null);
    try std.testing.expect(std.mem.indexOf(u8, sa_code, "sla__sibling__imported_a") != null);
    try std.testing.expect(std.mem.indexOf(u8, sa_code, "call @sla__dep__imported_a") != null);
    try std.testing.expect(std.mem.indexOf(u8, sa_code, "call @sla__sibling__imported_a") != null);
    try std.testing.expectEqual(@as(usize, 0), sa_stderr.items.len);

    var sab_stderr = std.ArrayList(u8).init(std.testing.allocator);
    defer sab_stderr.deinit();
    const sab_compiled = try compileSlaSabTestInput(allocator, "main.sla", sab_stderr.writer().any(), &.{}, false);
    if (sab_compiled) |compiled| {
        defer if (compiled.delete_after) std.fs.cwd().deleteFile(compiled.path) catch {};
        const sab_bytes = try std.fs.cwd().readFileAlloc(allocator, compiled.path, 10 * 1024 * 1024);
        var module = try sci_bridge.sab.decodeModule(std.testing.allocator, sab_bytes);
        defer module.deinit(std.testing.allocator);

        var saw_dep_sig = false;
        var saw_sibling_sig = false;
        for (module.function_sigs) |fsig| {
            if (std.mem.indexOf(u8, fsig.name, "dep__imported_a") != null) saw_dep_sig = true;
            if (std.mem.indexOf(u8, fsig.name, "sibling__imported_a") != null) saw_sibling_sig = true;
        }
        try std.testing.expect(saw_dep_sig);
        try std.testing.expect(saw_sibling_sig);

        const disasm = try sci_bridge.disasmSabAlloc(allocator, sab_bytes);
        try std.testing.expect(std.mem.indexOf(u8, disasm, "\"@sla__dep__imported_a\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, disasm, "\"@sla__sibling__imported_a\"") != null);
    } else {
        std.debug.print("{s}", .{sab_stderr.items});
        return error.TestUnexpectedResult;
    }
    try std.testing.expectEqual(@as(usize, 0), sab_stderr.items.len);
}

test "sla reachable collector records namespace alias call targets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ret_ty = ast.Type{ .primitive = .i32 };
    var tc = type_checker_mod.TypeChecker.init(allocator);
    defer tc.deinit();
    try tc.registerFunctionAliasWithMetadata("dep__imported_a", "imported_a", "dep", "/tmp/dep.sla");
    try tc.registerFunctionAliasWithMetadata("sibling__imported_a", "imported_a", "sibling", "/tmp/sibling.sla");
    try tc.registerImportedFunctionSignature("imported_a", &.{}, &ret_ty, false);

    var dep_call = ast.Node{ .call_expr = .{
        .func_name = "dep__imported_a",
        .associated_target = null,
        .generics = &.{},
        .args = &.{},
    } };
    var sibling_call = ast.Node{ .call_expr = .{
        .func_name = "sibling__imported_a",
        .associated_target = null,
        .generics = &.{},
        .args = &.{},
    } };
    var left_stmt = ast.Node{ .expr_stmt = &dep_call };
    var right_stmt = ast.Node{ .expr_stmt = &sibling_call };
    var test_node = ast.Node{ .test_decl = .{
        .name = "namespace alias reachability",
        .is_ignored = false,
        .should_panic = false,
        .body = &.{ &left_stmt, &right_stmt },
    } };
    var program = ast.Node{ .program = .{ .decls = &.{&test_node} } };
    try tc.checkProgram(&program);

    var reachable = std.StringHashMap(void).init(allocator);
    var worklist = std.ArrayList([]const u8).init(allocator);
    try collectReachableExpr(&tc, &reachable, &worklist, &dep_call);
    try collectReachableExpr(&tc, &reachable, &worklist, &sibling_call);

    try std.testing.expect(reachable.contains("dep__imported_a"));
    try std.testing.expect(reachable.contains("sibling__imported_a"));
    try std.testing.expect(!reachable.contains("imported_a"));
    try std.testing.expectEqual(@as(usize, 0), worklist.items.len);
}

test "sla module exports index records per-module function sources" {
    // The ModuleGraph foundation: SlaModuleExports must index each module's
    // exported symbols and SlaCallableIndex must record the owning module path
    // for every reachable callable, so future lazy typecheck can resolve calls
    // by module-qualified lookup instead of flattening every imported body.
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const dep_source =
        \\@import "child.sla"
        \\
        \\fn imported_a() -> i32 {
        \\    return imported_helper();
        \\};
        \\
        \\fn imported_helper() -> i32 {
        \\    return 7;
        \\};
        \\
        \\fn unreachable_import() -> i32 {
        \\    return 99;
        \\};
        \\
        \\const IMPORTED_VALUE: i32 = 9;
        \\
        \\macro imported_macro(value) {
        \\    return value;
        \\}
        \\
        \\struct ImportedTag {
        \\    value: i32,
        \\}
        \\
        \\impl ImportedTag {
        \\    fn tag_method(self) -> i32 {
        \\        return self.value;
        \\    }
        \\}
    ;
    const child_source =
        \\struct ChildExport {
        \\    value: i32,
        \\}
    ;
    const sibling_source =
        \\fn imported_a() -> i32 {
        \\    return 100;
        \\};
        \\
        \\struct ImportedTag {
        \\    value: i64,
        \\}
        \\
        \\const IMPORTED_VALUE: i32 = 100;
        \\
        \\macro imported_macro(value) {
        \\    return value;
        \\}
    ;
    const main_source =
        \\@import "dep.sla"
        \\@import "sibling.sla"
        \\
        \\@test "exports index path"() {
        \\    let got = imported_a();
        \\    if got != 7 { panic(24010); };
        \\};
    ;
    try tmp.dir.writeFile(.{ .sub_path = "child.sla", .data = child_source });
    try tmp.dir.writeFile(.{ .sub_path = "dep.sla", .data = dep_source });
    try tmp.dir.writeFile(.{ .sub_path = "sibling.sla", .data = sibling_source });
    try tmp.dir.writeFile(.{ .sub_path = "main.sla", .data = main_source });

    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const expanded_content = try source_expand.expand(allocator, main_source);
    var parser = parser_mod.Parser.initWithDir(allocator, expanded_content, ".");
    const prog = try parser.parseProgram();
    var primary_decls = std.AutoHashMap(*const ast.Node, void).init(allocator);
    const expanded_prog = try expandSlaImports(allocator, prog, "main.sla", &primary_decls, .{
        .prune_for_test_codegen = true,
    });

    // After expansion the reachable helper `imported_helper` and `imported_a`
    // from dep.sla must be present, while `unreachable_import` is pruned.
    var saw_a = false;
    var saw_helper = false;
    var saw_unreachable = false;
    for (expanded_prog.program.decls) |decl| {
        if (decl.* != .func_decl) continue;
        if (std.mem.eql(u8, decl.func_decl.name, "imported_a")) saw_a = true;
        if (std.mem.eql(u8, decl.func_decl.name, "imported_helper")) saw_helper = true;
        if (std.mem.eql(u8, decl.func_decl.name, "unreachable_import")) saw_unreachable = true;
    }
    try std.testing.expect(saw_a);
    try std.testing.expect(saw_helper);
    try std.testing.expect(!saw_unreachable);

    // Now verify the ModuleGraph foundation directly: build a SlaModuleTable,
    // parse dep.sla, and confirm exports.type_decls / function_decls capture
    // the right surface and SlaCallableIndex records per-symbol module source.
    const main_resolved = (try readImportFileIfExists(allocator, "main.sla")).?;
    const resolved_imports = try resolveImportFiles(allocator, ".", "dep.sla", "main.sla");
    const sibling_resolved_imports = try resolveImportFiles(allocator, ".", "sibling.sla", "main.sla");
    var modules = SlaModuleTable.init(allocator);
    defer modules.deinit();
    const main_module = try modules.getOrParse(main_resolved);
    var dep_module: ?*SlaModule = null;
    for (resolved_imports) |resolved| {
        if (!std.mem.endsWith(u8, resolved.path, ".sla")) continue;
        dep_module = try modules.getOrParse(resolved);
        break;
    }
    var sibling_module: ?*SlaModule = null;
    for (sibling_resolved_imports) |resolved| {
        if (!std.mem.endsWith(u8, resolved.path, ".sla")) continue;
        sibling_module = try modules.getOrParse(resolved);
        break;
    }
    try std.testing.expect(dep_module != null);
    try std.testing.expect(sibling_module != null);
    try std.testing.expectEqual(@as(usize, 2), main_module.resolved_module_imports.len);
    const dep = dep_module.?;
    const sibling = sibling_module.?;

    // SlaModuleExports indexes each module's exported surface by kind.
    try std.testing.expect(dep.exports.exportsFunction("imported_a"));
    try std.testing.expect(dep.exports.exportsFunction("imported_helper"));
    try std.testing.expect(dep.exports.exportsFunction("unreachable_import"));
    try std.testing.expect(dep.exports.exportsType("ImportedTag"));
    try std.testing.expect(dep.exports.exportsConst("IMPORTED_VALUE"));
    try std.testing.expect(dep.exports.exportsMacro("imported_macro"));
    try std.testing.expect(!dep.exports.exportsFunction("NotInDep"));

    const imported_type_sig = dep.exports.typeSignature("ImportedTag");
    try std.testing.expect(imported_type_sig != null);
    try std.testing.expect(std.mem.eql(u8, imported_type_sig.?.name, "ImportedTag"));
    try std.testing.expectEqual(SlaModuleExports.TypeKind.struct_decl, imported_type_sig.?.kind);
    try std.testing.expectEqual(@as(usize, 0), imported_type_sig.?.generics.len);
    try std.testing.expect(std.mem.eql(u8, imported_type_sig.?.module_path, dep.path));

    // Exported function signatures are indexed separately from bodies, giving
    // future lazy typecheck a signature surface to consult before opening a
    // reachable imported body.
    const imported_sig = dep.exports.functionSignature("imported_a");
    try std.testing.expect(imported_sig != null);
    try std.testing.expect(std.mem.eql(u8, imported_sig.?.name, "imported_a"));
    try std.testing.expectEqual(@as(usize, 0), imported_sig.?.params.len);
    try std.testing.expect(imported_sig.?.ret_ty.* == .primitive);
    try std.testing.expectEqual(ast.Primitive.i32, imported_sig.?.ret_ty.primitive);
    try std.testing.expect(!imported_sig.?.is_extern);
    try std.testing.expect(std.mem.eql(u8, imported_sig.?.module_path, dep.path));

    const imported_const_sig = dep.exports.constSignature("IMPORTED_VALUE");
    try std.testing.expect(imported_const_sig != null);
    try std.testing.expect(std.mem.eql(u8, imported_const_sig.?.name, "IMPORTED_VALUE"));
    try std.testing.expect(imported_const_sig.?.ty != null);
    try std.testing.expect(imported_const_sig.?.ty.?.* == .primitive);
    try std.testing.expectEqual(ast.Primitive.i32, imported_const_sig.?.ty.?.primitive);
    try std.testing.expect(std.mem.eql(u8, imported_const_sig.?.module_path, dep.path));

    const imported_macro_sig = dep.exports.macroSignature("imported_macro");
    try std.testing.expect(imported_macro_sig != null);
    try std.testing.expect(std.mem.eql(u8, imported_macro_sig.?.name, "imported_macro"));
    try std.testing.expectEqual(@as(usize, 1), imported_macro_sig.?.params.len);
    try std.testing.expect(std.mem.eql(u8, imported_macro_sig.?.params[0], "value"));
    try std.testing.expect(std.mem.eql(u8, imported_macro_sig.?.module_path, dep.path));

    const qualified_dep_fn = modules.functionSignature(dep.path, "imported_a");
    const qualified_sibling_fn = modules.functionSignature(sibling.path, "imported_a");
    try std.testing.expect(qualified_dep_fn != null);
    try std.testing.expect(qualified_sibling_fn != null);
    try std.testing.expect(std.mem.eql(u8, qualified_dep_fn.?.module_path, dep.path));
    try std.testing.expect(std.mem.eql(u8, qualified_sibling_fn.?.module_path, sibling.path));

    const qualified_dep_type = modules.typeSignature(dep.path, "ImportedTag");
    const qualified_sibling_type = modules.typeSignature(sibling.path, "ImportedTag");
    try std.testing.expect(qualified_dep_type != null);
    try std.testing.expect(qualified_sibling_type != null);
    try std.testing.expect(std.mem.eql(u8, qualified_dep_type.?.module_path, dep.path));
    try std.testing.expect(std.mem.eql(u8, qualified_sibling_type.?.module_path, sibling.path));

    const qualified_dep_const = modules.constSignature(dep.path, "IMPORTED_VALUE");
    const qualified_sibling_macro = modules.macroSignature(sibling.path, "imported_macro");
    try std.testing.expect(qualified_dep_const != null);
    try std.testing.expect(qualified_sibling_macro != null);
    try std.testing.expect(std.mem.eql(u8, qualified_dep_const.?.module_path, dep.path));
    try std.testing.expect(std.mem.eql(u8, qualified_sibling_macro.?.module_path, sibling.path));

    const dep_namespace_import = modules.moduleImportByNamespace(main_module.path, "dep");
    const sibling_namespace_import = modules.moduleImportByNamespace(main_module.path, "sibling");
    try std.testing.expect(dep_namespace_import != null);
    try std.testing.expect(sibling_namespace_import != null);
    try std.testing.expect(std.mem.eql(u8, dep_namespace_import.?.resolved.path, dep.path));
    try std.testing.expect(std.mem.eql(u8, sibling_namespace_import.?.resolved.path, sibling.path));

    const namespace_dep_fn = try modules.functionSignatureForImportNamespace(main_module.path, "dep", "imported_a");
    const namespace_sibling_fn = try modules.functionSignatureForImportNamespace(main_module.path, "sibling", "imported_a");
    try std.testing.expect(namespace_dep_fn != null);
    try std.testing.expect(namespace_sibling_fn != null);
    try std.testing.expect(std.mem.eql(u8, namespace_dep_fn.?.module_path, dep.path));
    try std.testing.expect(std.mem.eql(u8, namespace_sibling_fn.?.module_path, sibling.path));

    const namespace_dep_type = try modules.typeSignatureForImportNamespace(main_module.path, "dep", "ImportedTag");
    const namespace_sibling_const = try modules.constSignatureForImportNamespace(main_module.path, "sibling", "IMPORTED_VALUE");
    const namespace_dep_macro = try modules.macroSignatureForImportNamespace(main_module.path, "dep", "imported_macro");
    try std.testing.expect(namespace_dep_type != null);
    try std.testing.expect(namespace_sibling_const != null);
    try std.testing.expect(namespace_dep_macro != null);
    try std.testing.expect(std.mem.eql(u8, namespace_dep_type.?.module_path, dep.path));
    try std.testing.expect(std.mem.eql(u8, namespace_sibling_const.?.module_path, sibling.path));
    try std.testing.expect(std.mem.eql(u8, namespace_dep_macro.?.module_path, dep.path));

    const mangled_dep_fn = try modules.functionSignatureForImportedMangledName(main_module.path, "dep__imported_a");
    const mangled_sibling_fn = try modules.functionSignatureForImportedMangledName(main_module.path, "sibling__imported_a");
    try std.testing.expect(mangled_dep_fn != null);
    try std.testing.expect(mangled_sibling_fn != null);
    try std.testing.expect(std.mem.eql(u8, mangled_dep_fn.?.module_path, dep.path));
    try std.testing.expect(std.mem.eql(u8, mangled_sibling_fn.?.module_path, sibling.path));
    try std.testing.expect(try modules.functionSignatureForImportedMangledName(main_module.path, "imported_a") == null);

    // The module table stores the module graph directly, so later traversal
    // does not need to rediscover child imports by rescanning dep's AST.
    var saw_child_import = false;
    for (dep.resolved_imports) |child_resolved| {
        if (std.mem.endsWith(u8, child_resolved.path, "child.sla")) saw_child_import = true;
    }
    try std.testing.expect(saw_child_import);

    // SlaCallableIndex must attribute each callable symbol to its owning
    // module path, which is the namespace-qualified resolution primitive the
    // future lazy traversal needs to avoid re-flattening every imported body.
    var callable_index = SlaCallableIndex.init(allocator);
    defer callable_index.deinit();
    try callable_index.addDeclsFromModule(dep.program.program.decls, dep);
    try callable_index.addDeclsFromModule(sibling.program.program.decls, sibling);

    const dep_a_source = callable_index.moduleSource("imported_a");
    const dep_helper_source = callable_index.moduleSource("imported_helper");
    const dep_unreachable_source = callable_index.moduleSource("unreachable_import");
    const dep_alias_source = callable_index.moduleSource("dep__imported_a");
    const sibling_alias_source = callable_index.moduleSource("sibling__imported_a");
    try std.testing.expect(dep_a_source != null);
    try std.testing.expect(dep_helper_source != null);
    try std.testing.expect(dep_unreachable_source != null);
    try std.testing.expect(dep_alias_source != null);
    try std.testing.expect(sibling_alias_source != null);
    try std.testing.expect(std.mem.eql(u8, dep_a_source.?, dep.path));
    try std.testing.expect(std.mem.eql(u8, dep_helper_source.?, dep.path));
    try std.testing.expect(std.mem.eql(u8, dep_unreachable_source.?, dep.path));
    try std.testing.expect(std.mem.eql(u8, dep_alias_source.?, dep.path));
    try std.testing.expect(std.mem.eql(u8, sibling_alias_source.?, sibling.path));
    const dep_alias_decl = callable_index.decls.get("dep__imported_a");
    const sibling_alias_decl = callable_index.decls.get("sibling__imported_a");
    try std.testing.expect(dep_alias_decl != null);
    try std.testing.expect(sibling_alias_decl != null);
    try std.testing.expect(std.mem.eql(u8, dep_alias_decl.?.body[0].return_stmt.value.?.call_expr.func_name, "imported_helper"));
    try std.testing.expectEqual(@as(i64, 100), sibling_alias_decl.?.body[0].return_stmt.value.?.literal.int_val);

    // Inherent method `ImportedTag_tag_method` should also attribute its owning
    // module path through the associated-method registration path.
    const tag_method_source = callable_index.moduleSource("ImportedTag_tag_method");
    try std.testing.expect(tag_method_source != null);
    try std.testing.expect(std.mem.eql(u8, tag_method_source.?, dep.path));
}

test "sla module table resolves imported function bodies by module and namespace" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "dep.sla",
        .data =
        \\trait Label {
        \\    fn label(self) -> i32;
        \\}
        \\
        \\struct ImportedThing {
        \\    value: i32,
        \\}
        \\
        \\fn imported_value() -> i32 {
        \\    return 41;
        \\}
        \\
        \\impl ImportedThing {
        \\    fn inherent(self) -> i32 {
        \\        return self.value;
        \\    }
        \\}
        \\
        \\impl Label for ImportedThing {
        \\    fn label(self) -> i32 {
        \\        return self.value + 1;
        \\    }
        \\}
        ,
    });
    try tmp.dir.writeFile(.{
        .sub_path = "sibling.sla",
        .data =
        \\fn imported_value() -> i32 {
        \\    return 100;
        \\}
        ,
    });
    try tmp.dir.writeFile(.{
        .sub_path = "main.sla",
        .data =
        \\@import "dep.sla"
        \\@import "sibling.sla"
        \\
        \\fn main() -> i32 {
        \\    return dep::imported_value();
        \\}
        ,
    });

    const dep_source = try tmp.dir.readFileAlloc(allocator, "dep.sla", 1024 * 1024);
    const sibling_source = try tmp.dir.readFileAlloc(allocator, "sibling.sla", 1024 * 1024);
    const main_source = try tmp.dir.readFileAlloc(allocator, "main.sla", 1024 * 1024);
    const cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
    const dep_path = try tmp.dir.realpathAlloc(allocator, "dep.sla");
    const sibling_path = try tmp.dir.realpathAlloc(allocator, "sibling.sla");
    const main_path = try tmp.dir.realpathAlloc(allocator, "main.sla");
    const main_dir = std.fs.path.dirname(main_path) orelse cwd;

    const expanded_main = try source_expand.expand(allocator, main_source);
    var parser = parser_mod.Parser.initWithDir(allocator, expanded_main, main_dir);
    const main_prog = try parser.parseProgram();

    var modules = SlaModuleTable.init(allocator);
    defer modules.deinit();
    const dep_module = try modules.getOrParse(.{
        .path = dep_path,
        .output_path = "dep.sla",
        .source = dep_source,
    });
    const sibling_module = try modules.getOrParse(.{
        .path = sibling_path,
        .output_path = "sibling.sla",
        .source = sibling_source,
    });
    _ = try modules.getOrParse(.{
        .path = main_path,
        .output_path = "main.sla",
        .source = main_source,
    });

    const top_body = modules.functionBody(dep_module.path, "imported_value");
    try std.testing.expect(top_body != null);
    try std.testing.expect(!top_body.?.is_decl_only);
    try std.testing.expectEqual(@as(usize, 1), top_body.?.body.len);

    const inherent_symbol = try lowering_rules.mangleMethodName(allocator, "ImportedThing", "inherent");
    const inherent_body = modules.associatedFunctionBody(dep_module.path, inherent_symbol);
    try std.testing.expect(inherent_body != null);
    try std.testing.expect(!inherent_body.?.is_decl_only);
    try std.testing.expectEqual(@as(usize, 1), inherent_body.?.body.len);

    const trait_symbol = try lowering_rules.mangleTraitMethodName(allocator, "ImportedThing", "Label", "label");
    const trait_body = modules.associatedFunctionBody(dep_module.path, trait_symbol);
    try std.testing.expect(trait_body != null);
    try std.testing.expect(!trait_body.?.is_decl_only);
    try std.testing.expectEqual(@as(usize, 1), trait_body.?.body.len);

    const namespace_body = try modules.functionBodyForImportNamespace(main_path, "dep", "imported_value");
    try std.testing.expect(namespace_body != null);
    try std.testing.expect(std.mem.eql(u8, namespace_body.?.name, "imported_value"));

    const imported_symbol_body = try modules.functionBodyForImportedMangledName(main_path, "dep__imported_value");
    try std.testing.expect(imported_symbol_body != null);
    try std.testing.expect(std.mem.eql(u8, imported_symbol_body.?.name, "imported_value"));

    var reachable = std.StringHashMap(void).init(allocator);
    var referenced_types = std.StringHashMap(void).init(allocator);
    var emitted = std.StringHashMap(void).init(allocator);
    var primary_decls = std.AutoHashMap(*const ast.Node, void).init(allocator);
    var out_decls = std.ArrayList(*ast.Node).init(allocator);
    try reachable.put("sibling__imported_value", {});
    try appendModuleDeclsSelective(allocator, &modules, sibling_module, &emitted, &primary_decls, &out_decls, &reachable, &referenced_types, .{});

    var saw_sibling_body = false;
    var saw_dep_body = false;
    for (out_decls.items) |decl| {
        if (decl.* != .func_decl) continue;
        if (std.mem.eql(u8, decl.func_decl.name, "imported_value")) {
            const ret = decl.func_decl.body[0].return_stmt.value.?;
            if (ret.* == .literal and ret.literal == .int_val and ret.literal.int_val == 100) saw_sibling_body = true;
            if (ret.* == .literal and ret.literal == .int_val and ret.literal.int_val == 41) saw_dep_body = true;
        }
    }
    try std.testing.expect(saw_sibling_body);
    try std.testing.expect(!saw_dep_body);

    try std.testing.expect(try modules.functionBodyForImportNamespace(main_path, "missing", "imported_value") == null);
    try std.testing.expect(try modules.functionBodyForImportedMangledName(main_path, "imported_value") == null);
    try std.testing.expect(modules.functionBody(dep_module.path, "missing") == null);
    try std.testing.expect(modules.associatedFunctionBody(dep_module.path, "ImportedThing_missing") == null);
    try std.testing.expect(main_prog.* == .program);
}

test "sla module table skips non contributing imported module bodies" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const used_source =
        \\fn used_value() -> i32 {
        \\    return used_helper();
        \\};
        \\
        \\fn used_helper() -> i32 {
        \\    return 42;
        \\};
    ;
    const unused_source =
        \\struct UnusedTag {
        \\    value: i32,
        \\}
        \\
        \\fn unused_bad() -> MissingType {
        \\    return nope();
        \\};
    ;
    const main_source =
        \\@import "used.sla"
        \\@import "unused.sla"
        \\
        \\@test "selective modules"() {
        \\    let got = used_value();
        \\    if got != 42 { panic(24011); };
        \\};
    ;
    try tmp.dir.writeFile(.{ .sub_path = "used.sla", .data = used_source });
    try tmp.dir.writeFile(.{ .sub_path = "unused.sla", .data = unused_source });
    try tmp.dir.writeFile(.{ .sub_path = "main.sla", .data = main_source });

    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const expanded_content = try source_expand.expand(allocator, main_source);
    var parser = parser_mod.Parser.initWithDir(allocator, expanded_content, ".");
    const prog = try parser.parseProgram();
    var primary_decls = std.AutoHashMap(*const ast.Node, void).init(allocator);
    const expanded_prog = try expandSlaImports(allocator, prog, "main.sla", &primary_decls, .{
        .prune_for_test_codegen = true,
    });

    var saw_used = false;
    var saw_helper = false;
    var saw_unused_fn = false;
    var saw_unused_type = false;
    for (expanded_prog.program.decls) |decl| {
        switch (decl.*) {
            .func_decl => |fd| {
                if (std.mem.eql(u8, fd.name, "used_value")) saw_used = true;
                if (std.mem.eql(u8, fd.name, "used_helper")) saw_helper = true;
                if (std.mem.eql(u8, fd.name, "unused_bad")) saw_unused_fn = true;
            },
            .struct_decl => |sd| {
                if (std.mem.eql(u8, sd.name, "UnusedTag")) saw_unused_type = true;
            },
            else => {},
        }
    }
    try std.testing.expect(saw_used);
    try std.testing.expect(saw_helper);
    try std.testing.expect(!saw_unused_fn);
    try std.testing.expect(!saw_unused_type);

    var compile_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer compile_arena.deinit();
    var stderr_buf = std.ArrayList(u8).init(compile_arena.allocator());
    defer stderr_buf.deinit();
    const compiled = try compileSlaSaTestInput(
        compile_arena.allocator(),
        "main.sla",
        stderr_buf.writer().any(),
        &.{},
        false,
    );
    if (compiled) |result| {
        if (result.delete_after) std.fs.cwd().deleteFile(result.path) catch {};
    }
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
}

test "sla module table selective flatten in non test compile path" {
    // Non-test compile path (prune_for_test_codegen = false): the root program
    // has a function that calls into used.sla, but unused.sla contains a broken
    // function referencing MissingType. Selective flattening must omit unused.sla's
    // body so the broken function never reaches TypeChecker, while used.sla's
    // reachable functions are flattened normally.
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const used_source =
        \\fn used_value() -> i32 {
        \\    return used_helper();
        \\};
        \\
        \\fn used_helper() -> i32 {
        \\    return 42;
        \\};
    ;
    const unused_source =
        \\fn unused_bad() -> MissingType {
        \\    return nope();
        \\};
    ;
    const main_source =
        \\@import "used.sla"
        \\@import "unused.sla"
        \\
        \\fn entry() -> i32 {
        \\    return used_value();
        \\};
    ;
    try tmp.dir.writeFile(.{ .sub_path = "used.sla", .data = used_source });
    try tmp.dir.writeFile(.{ .sub_path = "unused.sla", .data = unused_source });
    try tmp.dir.writeFile(.{ .sub_path = "main.sla", .data = main_source });

    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const expanded_content = try source_expand.expand(allocator, main_source);
    var parser = parser_mod.Parser.initWithDir(allocator, expanded_content, ".");
    const prog = try parser.parseProgram();
    var primary_decls = std.AutoHashMap(*const ast.Node, void).init(allocator);
    const expanded_prog = try expandSlaImports(allocator, prog, "main.sla", &primary_decls, .{
        .prune_for_test_codegen = false,
    });

    var saw_entry = false;
    var saw_used = false;
    var saw_helper = false;
    var saw_unused = false;
    for (expanded_prog.program.decls) |decl| {
        if (decl.* != .func_decl) continue;
        const name = decl.func_decl.name;
        if (std.mem.eql(u8, name, "entry")) saw_entry = true;
        if (std.mem.eql(u8, name, "used_value")) saw_used = true;
        if (std.mem.eql(u8, name, "used_helper")) saw_helper = true;
        if (std.mem.eql(u8, name, "unused_bad")) saw_unused = true;
    }
    try std.testing.expect(saw_entry);
    try std.testing.expect(saw_used);
    try std.testing.expect(saw_helper);
    // unused.sla is non-contributing: its broken function must NOT be flattened.
    try std.testing.expect(!saw_unused);
}

test "sla build codegen uses registry loaded imported bodies" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const dep_source =
        \\trait Label {
        \\    fn label(self) -> i32;
        \\    fn unused_trait(self) -> i32;
        \\}
        \\
        \\struct ImportedThing {
        \\    value: i32,
        \\}
        \\
        \\fn imported_value() -> i32 {
        \\    return 69;
        \\}
        \\
        \\fn unused_bad() -> MissingType {
        \\    return nope();
        \\}
        \\
        \\impl ImportedThing {
        \\    fn used(self) -> i32 {
        \\        return self.value;
        \\    }
        \\}
        \\
        \\impl Label for ImportedThing {
        \\    fn label(self) -> i32 {
        \\        return self.value + 1;
        \\    }
        \\
        \\    fn unused_trait(self) -> i32 {
        \\        return missing_trait_body();
        \\    }
        \\}
    ;
    const main_source =
        \\@import "dep.sla"
        \\
        \\fn entry() -> i32 {
        \\    let item = ImportedThing { value: imported_value() };
        \\    return item.used() + item.label();
        \\}
    ;
    try tmp.dir.writeFile(.{ .sub_path = "dep.sla", .data = dep_source });
    try tmp.dir.writeFile(.{ .sub_path = "main.sla", .data = main_source });

    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var sa_stderr = std.ArrayList(u8).init(std.testing.allocator);
    defer sa_stderr.deinit();
    const sa_code = (try compileSlaToSaString(allocator, "main.sla", "main.sa", sa_stderr.writer().any())) orelse {
        std.debug.print("{s}", .{sa_stderr.items});
        return error.TestUnexpectedResult;
    };
    try std.testing.expect(std.mem.indexOf(u8, sa_code, "sla__imported_value") != null);
    try std.testing.expect(std.mem.indexOf(u8, sa_code, "ImportedThing_used") != null);
    try std.testing.expect(std.mem.indexOf(u8, sa_code, "ImportedThing__Label_label") != null);
    try std.testing.expect(std.mem.indexOf(u8, sa_code, "unused_bad") == null);
    try std.testing.expect(std.mem.indexOf(u8, sa_code, "missing_trait_body") == null);
    try std.testing.expectEqual(@as(usize, 0), sa_stderr.items.len);

    var sab_stderr = std.ArrayList(u8).init(std.testing.allocator);
    defer sab_stderr.deinit();
    const sab_bytes = (try compileSlaFileToSab(allocator, "main.sla", ".sla-cache/sab/main.sab", sab_stderr.writer().any())) orelse {
        std.debug.print("{s}", .{sab_stderr.items});
        return error.TestUnexpectedResult;
    };
    var module = try sci_bridge.sab.decodeModule(std.testing.allocator, sab_bytes);
    defer module.deinit(std.testing.allocator);

    var saw_value = false;
    var saw_used = false;
    var saw_label = false;
    var saw_unused_bad = false;
    var saw_unused_trait = false;
    for (module.function_sigs) |fsig| {
        if (std.mem.indexOf(u8, fsig.name, "imported_value") != null) saw_value = true;
        if (std.mem.indexOf(u8, fsig.name, "ImportedThing_used") != null) saw_used = true;
        if (std.mem.indexOf(u8, fsig.name, "ImportedThing__Label_label") != null) saw_label = true;
        if (std.mem.indexOf(u8, fsig.name, "unused_bad") != null) saw_unused_bad = true;
        if (std.mem.indexOf(u8, fsig.name, "unused_trait") != null) saw_unused_trait = true;
    }
    try std.testing.expect(saw_value);
    try std.testing.expect(saw_used);
    try std.testing.expect(saw_label);
    try std.testing.expect(!saw_unused_bad);
    try std.testing.expect(!saw_unused_trait);
    try std.testing.expectEqual(@as(usize, 0), sab_stderr.items.len);
}

test "sla build codegen keeps imported dyn trait impl bodies from registry" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const dep_source =
        \\trait Identified {
        \\    fn get_id(&self) -> i32;
        \\    fn unused_dyn(&self) -> i32;
        \\}
        \\
        \\struct ImportedThing {
        \\    id: i32,
        \\}
        \\
        \\impl Identified for ImportedThing {
        \\    fn get_id(&self) -> i32 {
        \\        return self.id;
        \\    }
        \\
        \\    fn unused_dyn(&self) -> i32 {
        \\        return missing_dyn_body();
        \\    }
        \\}
    ;
    const main_source =
        \\@import "sa_std/core/box.sa"
        \\@import "sa_std/core/trait_object.sa"
        \\@import "dep.sla"
        \\
        \\fn entry() -> i32 {
        \\    let obj: Box<dyn Identified> = Box::new(ImportedThing { id: 74 });
        \\    return obj.get_id();
        \\}
    ;
    try tmp.dir.writeFile(.{ .sub_path = "dep.sla", .data = dep_source });
    try tmp.dir.writeFile(.{ .sub_path = "main.sla", .data = main_source });

    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var sa_stderr = std.ArrayList(u8).init(std.testing.allocator);
    defer sa_stderr.deinit();
    const sa_code = (try compileSlaToSaString(allocator, "main.sla", "main.sa", sa_stderr.writer().any())) orelse {
        std.debug.print("{s}", .{sa_stderr.items});
        return error.TestUnexpectedResult;
    };
    try std.testing.expect(std.mem.indexOf(u8, sa_code, "ImportedThing__Identified_get_id") != null);
    try std.testing.expect(std.mem.indexOf(u8, sa_code, "missing_dyn_body") == null);
    try std.testing.expectEqual(@as(usize, 0), sa_stderr.items.len);

    var sab_stderr = std.ArrayList(u8).init(std.testing.allocator);
    defer sab_stderr.deinit();
    const sab_bytes = (try compileSlaFileToSab(allocator, "main.sla", ".sla-cache/sab/main.sab", sab_stderr.writer().any())) orelse {
        std.debug.print("{s}", .{sab_stderr.items});
        return error.TestUnexpectedResult;
    };
    var module = try sci_bridge.sab.decodeModule(std.testing.allocator, sab_bytes);
    defer module.deinit(std.testing.allocator);

    var saw_get_id = false;
    var saw_unused_dyn = false;
    for (module.function_sigs) |fsig| {
        if (std.mem.indexOf(u8, fsig.name, "ImportedThing__Identified_get_id") != null) saw_get_id = true;
        if (std.mem.indexOf(u8, fsig.name, "unused_dyn") != null) saw_unused_dyn = true;
    }
    try std.testing.expect(saw_get_id);
    try std.testing.expect(!saw_unused_dyn);
    try std.testing.expectEqual(@as(usize, 0), sab_stderr.items.len);
}

test "sla module table loads reachable imported bodies from registry while stubbing others" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const dep_source =
        \\trait Label {
        \\    fn label(self) -> i32;
        \\    fn unused_trait(self) -> i32;
        \\}
        \\
        \\struct ImportedThing {
        \\    value: i32,
        \\}
        \\
        \\fn imported_value() -> i32 {
        \\    return imported_helper();
        \\}
        \\
        \\fn imported_helper() -> i32 {
        \\    return 67;
        \\}
        \\
        \\fn unused_bad() -> MissingType {
        \\    return nope();
        \\}
        \\
        \\impl ImportedThing {
        \\    fn inherent(self) -> i32 {
        \\        return self.value;
        \\    }
        \\}
        \\
        \\impl Label for ImportedThing {
        \\    fn label(self) -> i32 {
        \\        return self.value + 1;
        \\    }
        \\
        \\    fn unused_trait(self) -> i32 {
        \\        return missing_trait_body();
        \\    }
        \\}
    ;
    const main_source =
        \\@import "dep.sla"
        \\
        \\fn entry() -> i32 {
        \\    let item = ImportedThing { value: imported_value() };
        \\    return item.inherent() + item.label();
        \\}
    ;
    try tmp.dir.writeFile(.{ .sub_path = "dep.sla", .data = dep_source });
    try tmp.dir.writeFile(.{ .sub_path = "main.sla", .data = main_source });

    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const expanded_content = try source_expand.expand(allocator, main_source);
    var parser = parser_mod.Parser.initWithDir(allocator, expanded_content, ".");
    const prog = try parser.parseProgram();
    var primary_decls = std.AutoHashMap(*const ast.Node, void).init(allocator);
    const expanded_prog = try expandSlaImports(allocator, prog, "main.sla", &primary_decls, .{
        .imported_bodies_decl_only = true,
        .load_reachable_imported_bodies_from_registry = true,
    });

    var saw_value_body = false;
    var saw_helper_body = false;
    var saw_unused_bad = false;
    var saw_inherent_body = false;
    var saw_label_body = false;
    var saw_unused_trait_stub = false;
    for (expanded_prog.program.decls) |decl| {
        switch (decl.*) {
            .func_decl => |fd| {
                if (std.mem.eql(u8, fd.name, "imported_value")) saw_value_body = !fd.is_decl_only and fd.body.len > 0;
                if (std.mem.eql(u8, fd.name, "imported_helper")) saw_helper_body = !fd.is_decl_only and fd.body.len > 0;
                if (std.mem.eql(u8, fd.name, "unused_bad")) saw_unused_bad = true;
            },
            .impl_decl => |impl_decl| {
                for (impl_decl.methods) |method| {
                    if (method.* != .func_decl) continue;
                    if (std.mem.eql(u8, method.func_decl.name, "inherent")) saw_inherent_body = !method.func_decl.is_decl_only and method.func_decl.body.len > 0;
                    if (std.mem.eql(u8, method.func_decl.name, "label")) saw_label_body = !method.func_decl.is_decl_only and method.func_decl.body.len > 0;
                    if (std.mem.eql(u8, method.func_decl.name, "unused_trait")) saw_unused_trait_stub = method.func_decl.is_decl_only and method.func_decl.body.len == 0;
                }
            },
            else => {},
        }
    }
    try std.testing.expect(saw_value_body);
    try std.testing.expect(saw_helper_body);
    try std.testing.expect(!saw_unused_bad);
    try std.testing.expect(saw_inherent_body);
    try std.testing.expect(saw_label_body);
    try std.testing.expect(saw_unused_trait_stub);
}

test "sla module table reaches contributing transitive module through non contributing parent" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const mid_source =
        \\@import "leaf.sla"
        \\
        \\fn mid_unused_bad() -> MissingType {
        \\    return nope();
        \\};
    ;
    const leaf_source =
        \\fn leaf_value() -> i32 {
        \\    return 53;
        \\};
    ;
    const main_source =
        \\@import "mid.sla"
        \\
        \\fn entry() -> i32 {
        \\    return leaf_value();
        \\};
    ;
    try tmp.dir.writeFile(.{ .sub_path = "mid.sla", .data = mid_source });
    try tmp.dir.writeFile(.{ .sub_path = "leaf.sla", .data = leaf_source });
    try tmp.dir.writeFile(.{ .sub_path = "main.sla", .data = main_source });

    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const expanded_content = try source_expand.expand(allocator, main_source);
    var parser = parser_mod.Parser.initWithDir(allocator, expanded_content, ".");
    const prog = try parser.parseProgram();
    var primary_decls = std.AutoHashMap(*const ast.Node, void).init(allocator);
    const expanded_prog = try expandSlaImports(allocator, prog, "main.sla", &primary_decls, .{});

    var saw_leaf = false;
    var saw_mid_bad = false;
    for (expanded_prog.program.decls) |decl| {
        if (decl.* != .func_decl) continue;
        if (std.mem.eql(u8, decl.func_decl.name, "leaf_value")) saw_leaf = true;
        if (std.mem.eql(u8, decl.func_decl.name, "mid_unused_bad")) saw_mid_bad = true;
    }
    try std.testing.expect(saw_leaf);
    try std.testing.expect(!saw_mid_bad);
}

test "sla module table prunes unreachable trait impl methods in contributing module" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const dep_source =
        \\trait Label {
        \\    fn label(self) -> i32;
        \\    fn unused(self) -> i32;
        \\}
        \\
        \\struct ImportedThing {
        \\    value: i32,
        \\}
        \\
        \\impl Label for ImportedThing {
        \\    fn label(self) -> i32 {
        \\        return self.value;
        \\    }
        \\
        \\    fn unused(self) -> i32 {
        \\        return missing_trait_body();
        \\    }
        \\}
    ;
    const main_source =
        \\@import "dep.sla"
        \\
        \\fn entry() -> i32 {
        \\    let item = ImportedThing { value: 61 };
        \\    return item.label();
        \\};
    ;
    try tmp.dir.writeFile(.{ .sub_path = "dep.sla", .data = dep_source });
    try tmp.dir.writeFile(.{ .sub_path = "main.sla", .data = main_source });

    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const expanded_content = try source_expand.expand(allocator, main_source);
    var parser = parser_mod.Parser.initWithDir(allocator, expanded_content, ".");
    const prog = try parser.parseProgram();
    var primary_decls = std.AutoHashMap(*const ast.Node, void).init(allocator);
    const expanded_prog = try expandSlaImports(allocator, prog, "main.sla", &primary_decls, .{});

    var saw_label = false;
    var saw_label_body = false;
    var saw_unused = false;
    var saw_unused_decl_only = false;
    for (expanded_prog.program.decls) |decl| {
        if (decl.* != .impl_decl) continue;
        for (decl.impl_decl.methods) |method| {
            if (method.* != .func_decl) continue;
            if (std.mem.eql(u8, method.func_decl.name, "label")) {
                saw_label = true;
                saw_label_body = !method.func_decl.is_decl_only and method.func_decl.body.len > 0;
            }
            if (std.mem.eql(u8, method.func_decl.name, "unused")) {
                saw_unused = true;
                saw_unused_decl_only = method.func_decl.is_decl_only and method.func_decl.body.len == 0;
            }
        }
    }
    try std.testing.expect(saw_label);
    try std.testing.expect(saw_label_body);
    try std.testing.expect(saw_unused);
    try std.testing.expect(saw_unused_decl_only);

    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();
    const sa_code = (try compileSlaToSaStringWithOptions(
        allocator,
        "main.sla",
        "main.test.sa",
        stderr_buf.writer().any(),
        .{},
    )) orelse {
        std.debug.print("{s}", .{stderr_buf.items});
        return error.TestUnexpectedResult;
    };
    try std.testing.expect(std.mem.indexOf(u8, sa_code, "missing_trait_body") == null);
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
}

test "sla sab codegen skips decl only imported trait impl methods" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const dep_source =
        \\trait Label {
        \\    fn label(self) -> i32;
        \\    fn unused(self) -> i32;
        \\}
        \\
        \\struct ImportedThing {
        \\    value: i32,
        \\}
        \\
        \\impl Label for ImportedThing {
        \\    fn label(self) -> i32 {
        \\        return self.value;
        \\    }
        \\
        \\    fn unused(self) -> i32 {
        \\        return missing_trait_body();
        \\    }
        \\}
    ;
    const main_source =
        \\@import "dep.sla"
        \\
        \\@test "imported trait used method"() {
        \\    let item = ImportedThing { value: 61 };
        \\    if item.label() != 61 { panic(61061); };
        \\};
    ;
    try tmp.dir.writeFile(.{ .sub_path = "dep.sla", .data = dep_source });
    try tmp.dir.writeFile(.{ .sub_path = "main.sla", .data = main_source });

    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    const sab_bytes = (try compileSlaFileToSabWithOptions(
        arena.allocator(),
        "main.sla",
        ".sla-cache/sab/imported_trait_decl_only.sab",
        stderr_buf.writer().any(),
        .{ .prune_for_test_codegen = true, .allow_fallback = false },
    )) orelse {
        std.debug.print("{s}", .{stderr_buf.items});
        return error.TestUnexpectedResult;
    };

    var module = try sci_bridge.sab.decodeModule(std.testing.allocator, sab_bytes);
    defer module.deinit(std.testing.allocator);

    var saw_label = false;
    var saw_unused = false;
    for (module.function_sigs) |fsig| {
        if (std.mem.indexOf(u8, fsig.name, "ImportedThing__Label_label") != null) saw_label = true;
        if (std.mem.indexOf(u8, fsig.name, "ImportedThing__Label_unused") != null) saw_unused = true;
    }
    try std.testing.expect(saw_label);
    try std.testing.expect(!saw_unused);
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
}

test "sla module table follows imported const initializer reachability" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const dep_source =
        \\const IMPORTED_VALUE: i32 = const_helper();
        \\
        \\fn const_helper() -> i32 {
        \\    return 71;
        \\};
        \\
        \\fn unused_bad() -> MissingType {
        \\    return nope();
        \\};
    ;
    const main_source =
        \\@import "dep.sla"
        \\
        \\fn entry() -> i32 {
        \\    return IMPORTED_VALUE;
        \\};
    ;
    try tmp.dir.writeFile(.{ .sub_path = "dep.sla", .data = dep_source });
    try tmp.dir.writeFile(.{ .sub_path = "main.sla", .data = main_source });

    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const expanded_content = try source_expand.expand(allocator, main_source);
    var parser = parser_mod.Parser.initWithDir(allocator, expanded_content, ".");
    const prog = try parser.parseProgram();
    var primary_decls = std.AutoHashMap(*const ast.Node, void).init(allocator);
    const expanded_prog = try expandSlaImports(allocator, prog, "main.sla", &primary_decls, .{});

    var saw_const = false;
    var saw_helper = false;
    var saw_unused = false;
    for (expanded_prog.program.decls) |decl| {
        switch (decl.*) {
            .const_stmt => |c| {
                if (std.mem.eql(u8, c.name, "IMPORTED_VALUE")) saw_const = true;
            },
            .func_decl => |fd| {
                if (std.mem.eql(u8, fd.name, "const_helper")) saw_helper = true;
                if (std.mem.eql(u8, fd.name, "unused_bad")) saw_unused = true;
            },
            else => {},
        }
    }
    try std.testing.expect(saw_const);
    try std.testing.expect(saw_helper);
    try std.testing.expect(!saw_unused);
}

test "sla module table follows imported type signature dependencies" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const child_source =
        \\struct ChildType {
        \\    value: i32,
        \\}
    ;
    const parent_source =
        \\@import "child.sla"
        \\
        \\struct ParentType {
        \\    child: ChildType,
        \\}
        \\
        \\fn unused_bad() -> MissingType {
        \\    return nope();
        \\};
    ;
    const main_source =
        \\@import "parent.sla"
        \\
        \\fn entry(item: ParentType) -> i32 {
        \\    return item.child.value;
        \\};
    ;
    try tmp.dir.writeFile(.{ .sub_path = "child.sla", .data = child_source });
    try tmp.dir.writeFile(.{ .sub_path = "parent.sla", .data = parent_source });
    try tmp.dir.writeFile(.{ .sub_path = "main.sla", .data = main_source });

    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const expanded_content = try source_expand.expand(allocator, main_source);
    var parser = parser_mod.Parser.initWithDir(allocator, expanded_content, ".");
    const prog = try parser.parseProgram();
    var primary_decls = std.AutoHashMap(*const ast.Node, void).init(allocator);
    const expanded_prog = try expandSlaImports(allocator, prog, "main.sla", &primary_decls, .{});

    var saw_parent = false;
    var saw_child = false;
    var saw_unused = false;
    for (expanded_prog.program.decls) |decl| {
        switch (decl.*) {
            .struct_decl => |sd| {
                if (std.mem.eql(u8, sd.name, "ParentType")) saw_parent = true;
                if (std.mem.eql(u8, sd.name, "ChildType")) saw_child = true;
            },
            .func_decl => |fd| {
                if (std.mem.eql(u8, fd.name, "unused_bad")) saw_unused = true;
            },
            else => {},
        }
    }
    try std.testing.expect(saw_parent);
    try std.testing.expect(saw_child);
    try std.testing.expect(!saw_unused);
}

test "sla module table follows generic argument type dependencies" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const type_source =
        \\struct ImportedType {
        \\    value: i32,
        \\}
    ;
    const funcs_source =
        \\@import "types.sla"
        \\
        \\fn generic_id<T>(value: i32) -> i32 {
        \\    return value;
        \\};
        \\
        \\fn use_generic_ref<T>(value: i32) -> i32 {
        \\    return value;
        \\};
        \\
        \\fn unused_bad() -> MissingType {
        \\    return nope();
        \\};
    ;
    const main_source =
        \\@import "funcs.sla"
        \\
        \\fn apply(f: fn(i32) -> i32, value: i32) -> i32 {
        \\    return f(value);
        \\};
        \\
        \\fn entry() -> i32 {
        \\    return generic_id<ImportedType>(7) + apply(use_generic_ref<ImportedType>, 8);
        \\};
    ;
    try tmp.dir.writeFile(.{ .sub_path = "types.sla", .data = type_source });
    try tmp.dir.writeFile(.{ .sub_path = "funcs.sla", .data = funcs_source });
    try tmp.dir.writeFile(.{ .sub_path = "main.sla", .data = main_source });

    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const expanded_content = try source_expand.expand(allocator, main_source);
    var parser = parser_mod.Parser.initWithDir(allocator, expanded_content, ".");
    const prog = try parser.parseProgram();
    var primary_decls = std.AutoHashMap(*const ast.Node, void).init(allocator);
    const expanded_prog = try expandSlaImports(allocator, prog, "main.sla", &primary_decls, .{});

    var saw_type = false;
    var saw_generic_id = false;
    var saw_generic_ref_target = false;
    var saw_unused = false;
    for (expanded_prog.program.decls) |decl| {
        switch (decl.*) {
            .struct_decl => |sd| {
                if (std.mem.eql(u8, sd.name, "ImportedType")) saw_type = true;
            },
            .func_decl => |fd| {
                if (std.mem.eql(u8, fd.name, "generic_id")) saw_generic_id = true;
                if (std.mem.eql(u8, fd.name, "use_generic_ref")) saw_generic_ref_target = true;
                if (std.mem.eql(u8, fd.name, "unused_bad")) saw_unused = true;
            },
            else => {},
        }
    }
    try std.testing.expect(saw_type);
    try std.testing.expect(saw_generic_id);
    try std.testing.expect(saw_generic_ref_target);
    try std.testing.expect(!saw_unused);
}

test "sla sab test codegen omits unreachable functions after type checking" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const source =
        \\fn used_value() -> i32 {
        \\    return 11;
        \\};
        \\
        \\fn unused_value() -> i32 {
        \\    return 99;
        \\};
        \\
        \\@test "reachable output only"() {
        \\    let got = used_value();
        \\    if got != 11 { panic(24005); };
        \\};
    ;
    try tmp.dir.writeFile(.{ .sub_path = "reachable_output.sla", .data = source });

    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    const sab_bytes = (try compileSlaFileToSabWithOptions(
        arena.allocator(),
        "reachable_output.sla",
        ".sla-cache/sab/reachable_output.sab",
        stderr_buf.writer().any(),
        .{ .prune_for_test_codegen = true, .allow_fallback = false },
    )) orelse {
        std.debug.print("{s}", .{stderr_buf.items});
        return error.TestUnexpectedResult;
    };

    var module = try sci_bridge.sab.decodeModule(std.testing.allocator, sab_bytes);
    defer module.deinit(std.testing.allocator);

    var saw_used = false;
    var saw_unused = false;
    for (module.function_sigs) |fsig| {
        if (std.mem.indexOf(u8, fsig.name, "used_value") != null) saw_used = true;
        if (std.mem.indexOf(u8, fsig.name, "unused_value") != null) saw_unused = true;
    }
    try std.testing.expect(saw_used);
    try std.testing.expect(!saw_unused);
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
}

test "sla sab test codegen omits unreachable trait impls after type checking" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const source =
        \\trait UnusedTrait {
        \\    fn value(&self) -> i32;
        \\}
        \\
        \\struct UnusedType {
        \\    value: i32,
        \\}
        \\
        \\impl UnusedTrait for UnusedType {
        \\    fn value(&self) -> i32 {
        \\        return self.value;
        \\    }
        \\}
        \\
        \\@test "trait impl output pruning"() {
        \\    let item = UnusedType { value: 7 };
        \\    if item.value != 7 { panic(24007); };
        \\};
    ;
    try tmp.dir.writeFile(.{ .sub_path = "trait_impl_output.sla", .data = source });

    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    const sab_bytes = (try compileSlaFileToSabWithOptions(
        arena.allocator(),
        "trait_impl_output.sla",
        ".sla-cache/sab/trait_impl_output.sab",
        stderr_buf.writer().any(),
        .{ .prune_for_test_codegen = true, .allow_fallback = false },
    )) orelse {
        std.debug.print("{s}", .{stderr_buf.items});
        return error.TestUnexpectedResult;
    };

    var module = try sci_bridge.sab.decodeModule(std.testing.allocator, sab_bytes);
    defer module.deinit(std.testing.allocator);

    for (module.function_sigs) |fsig| {
        try std.testing.expect(std.mem.indexOf(u8, fsig.name, "UnusedTrait") == null);
        try std.testing.expect(std.mem.indexOf(u8, fsig.name, "UnusedType_value") == null);
    }
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
}

test "sla test empty filter skips sab compilation" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const source =
        \\fn helper() -> i32 {
        \\    return 1;
        \\};
        \\
        \\@test "kept only by another filter"() {
        \\    missing_symbol();
        \\};
    ;
    try tmp.dir.writeFile(.{ .sub_path = "empty_filter.sla", .data = source });

    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var stdout_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stdout_buf.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    var ctx = plugin_api.Context{ .allocator = std.testing.allocator };
    const args = [_][]const u8{
        "sa",
        "sla",
        "test",
        "empty_filter.sla",
        "--test-backend",
        "sab",
        "--filter",
        "definitely no such test",
    };
    const code = try runSlaCommandImpl(&ctx, args[0..], stdout_buf.writer().any(), stderr_buf.writer().any());

    if (code != @as(?u8, 0)) std.debug.print("{s}", .{stderr_buf.items});
    try std.testing.expectEqual(@as(?u8, 0), code);
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buf.items, 1, "0 passed; 0 failed; 0 skipped"));
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);

    const sab_path = try managedSabTestPath(std.testing.allocator, "empty_filter.sla", &.{ "--filter", "definitely no such test" });
    defer std.testing.allocator.free(sab_path);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(sab_path, .{}));
}

test "sla sab backend lowers plain structs directly" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const struct_source =
        \\struct SabPair {
        \\    x: i32,
        \\    y: i32,
        \\}
        \\
        \\fn make_pair(x: i32, y: i32) -> SabPair {
        \\    return SabPair { x: x, y: y };
        \\};
        \\
        \\fn sum_pair(pair: SabPair) -> i32 {
        \\    return pair.x + pair.y;
        \\};
        \\
        \\@test "sab struct fallback"() {
        \\    let pair = make_pair(2, 3);
        \\    let got = sum_pair(pair);
        \\    if got != 5 { panic(25005); };
        \\};
    ;
    try tmp.dir.writeFile(.{ .sub_path = "struct_sab.sla", .data = struct_source });

    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    const sab_bytes = (try compileSlaFileToSabWithOptions(
        arena.allocator(),
        "struct_sab.sla",
        ".sla-cache/sab/struct_sab.sab",
        stderr_buf.writer().any(),
        .{ .test_filter = "sab struct fallback", .allow_fallback = false },
    )) orelse {
        std.debug.print("{s}", .{stderr_buf.items});
        return error.TestUnexpectedResult;
    };

    try std.testing.expectError(error.FileNotFound, tmp.dir.access("struct_sab.test.sa", .{}));
    try std.testing.expect(std.mem.startsWith(u8, sab_bytes, sci_bridge.sab.magic));

    var module = try sci_bridge.sab.decodeModule(std.testing.allocator, sab_bytes);
    defer module.deinit(std.testing.allocator);
    var test_count: usize = 0;
    var saw_alloc = false;
    var saw_store = false;
    var saw_load = false;
    for (module.function_sigs) |fsig| {
        if (fsig.kind == .test_func) test_count += 1;
    }
    for (module.instructions) |item| {
        if (item.kind == .alloc) saw_alloc = true;
        if (item.kind == .store) saw_store = true;
        if (item.kind == .load) saw_load = true;
    }
    try std.testing.expectEqual(@as(usize, 1), test_count);
    try std.testing.expect(saw_alloc);
    try std.testing.expect(saw_store);
    try std.testing.expect(saw_load);
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
}

test "sla sab backend lowers function pointers directly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    const sab_bytes = (try compileSlaFileToSabWithOptions(
        arena.allocator(),
        "tests/test_unit_fn_ptr_value.sla",
        ".sla-cache/sab/fn_ptr_value.sab",
        stderr_buf.writer().any(),
        .{ .test_filter = "function pointer can be passed as argument", .allow_fallback = false },
    )) orelse {
        std.debug.print("{s}", .{stderr_buf.items});
        return error.TestUnexpectedResult;
    };

    var module = try sci_bridge.sab.decodeModule(std.testing.allocator, sab_bytes);
    defer module.deinit(std.testing.allocator);

    var test_count: usize = 0;
    var saw_fnptr_vtable = false;
    var saw_borrow = false;
    var saw_call_indirect = false;
    for (module.function_sigs) |fsig| {
        if (fsig.kind == .test_func) test_count += 1;
    }
    for (module.const_decls) |decl| {
        if (std.mem.eql(u8, decl.name, "SLA_FNPTR_VT_fn_ptr_inc") and decl.value == .vtable) {
            saw_fnptr_vtable = true;
        }
    }
    for (module.instructions) |item| {
        try std.testing.expectEqualStrings("", item.raw_text);
        if (item.kind == .borrow) saw_borrow = true;
        if (item.kind == .call_indirect) saw_call_indirect = true;
    }
    try std.testing.expectEqual(@as(usize, 1), test_count);
    try std.testing.expect(saw_fnptr_vtable);
    try std.testing.expect(saw_borrow);
    try std.testing.expect(saw_call_indirect);
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
}

test "sla sab backend lowers escaped thread closure function pointer callee directly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    const sab_bytes = (try compileSlaFileToSabWithOptions(
        arena.allocator(),
        "tests/test_unit_fn_ptr_value.sla",
        ".sla-cache/sab/fn_ptr_thread_direct.sab",
        stderr_buf.writer().any(),
        .{ .test_filter = "thread closure captures function pointer callee", .allow_fallback = false },
    )) orelse {
        std.debug.print("{s}", .{stderr_buf.items});
        return error.TestUnexpectedResult;
    };

    var module = try sci_bridge.sab.decodeModule(std.testing.allocator, sab_bytes);
    defer module.deinit(std.testing.allocator);

    var saw_thread_vtable = false;
    var saw_spawn_wrapper = false;
    var saw_worker = false;
    var saw_raw_cast = false;
    var saw_assume_safe = false;
    var saw_call_indirect = false;
    for (module.const_decls) |decl| {
        if (std.mem.startsWith(u8, decl.name, "SLA_THREAD_VT_") and decl.value == .vtable) saw_thread_vtable = true;
    }
    for (module.function_sigs) |fsig| {
        if (std.mem.startsWith(u8, fsig.name, "sla_thread_spawn_") and fsig.is_ffi_wrapper) saw_spawn_wrapper = true;
        if (std.mem.startsWith(u8, fsig.name, "sla_thread_worker_")) saw_worker = true;
    }
    for (module.instructions) |item| {
        try std.testing.expectEqualStrings("", item.raw_text);
        if (item.kind == .raw_cast) saw_raw_cast = true;
        if (item.kind == .assume_safe) saw_assume_safe = true;
        if (item.kind == .call_indirect) saw_call_indirect = true;
    }
    try std.testing.expect(saw_thread_vtable);
    try std.testing.expect(saw_spawn_wrapper);
    try std.testing.expect(saw_worker);
    try std.testing.expect(saw_raw_cast);
    try std.testing.expect(saw_assume_safe);
    try std.testing.expect(saw_call_indirect);
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
}

test "sla sab backend lowers paired escaped thread function pointer callees directly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    const sab_bytes = (try compileSlaFileToSabWithOptions(
        arena.allocator(),
        "tests/test_unit_fn_ptr_thread_pair_direct.sla",
        ".sla-cache/sab/fn_ptr_thread_pair_direct.sab",
        stderr_buf.writer().any(),
        .{ .test_filter = "thread closures capture function pointer pair", .allow_fallback = false },
    )) orelse {
        std.debug.print("{s}", .{stderr_buf.items});
        return error.TestUnexpectedResult;
    };

    var module = try sci_bridge.sab.decodeModule(std.testing.allocator, sab_bytes);
    defer module.deinit(std.testing.allocator);

    var worker_count: usize = 0;
    var indirect_count: usize = 0;
    for (module.function_sigs) |fsig| {
        if (std.mem.startsWith(u8, fsig.name, "sla_thread_worker_")) worker_count += 1;
    }
    for (module.instructions) |item| {
        try std.testing.expectEqualStrings("", item.raw_text);
        if (item.kind == .call_indirect) indirect_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), worker_count);
    try std.testing.expect(indirect_count >= 2);
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
}

test "sla sab backend lowers multi-argument calls directly" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const source =
        \\fn add3(a: i32, b: i32, c: i32) -> i32 {
        \\    return a + b + c;
        \\};
        \\
        \\@test "direct sab add3"() {
        \\    let got = add3(2, 3, 4);
        \\    if got != 9 { panic(27009); };
        \\};
    ;
    try tmp.dir.writeFile(.{ .sub_path = "add3.sla", .data = source });
    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    const sab_bytes = (try compileSlaFileToSabWithOptions(
        arena.allocator(),
        "add3.sla",
        ".sla-cache/sab/add3.sab",
        stderr_buf.writer().any(),
        .{ .test_filter = "direct sab add3", .allow_fallback = false },
    )) orelse {
        std.debug.print("{s}", .{stderr_buf.items});
        return error.TestUnexpectedResult;
    };

    var module = try sci_bridge.sab.decodeModule(std.testing.allocator, sab_bytes);
    defer module.deinit(std.testing.allocator);

    var saw_three_arg_call = false;
    for (module.instructions) |item| {
        if (item.kind == .call and item.operands[1] == .text and std.mem.indexOf(u8, item.operands[1].text, ", tmp_") != null) {
            if (std.mem.count(u8, item.operands[1].text, ",") == 2) saw_three_arg_call = true;
        }
    }
    try std.testing.expect(saw_three_arg_call);
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
}

test "sla sab backend lowers imported std surface metadata directly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    const sab_bytes = (try compileSlaFileToSabWithOptions(
        arena.allocator(),
        "tests/test_unit_fn_ptr_value.sla",
        ".sla-cache/sab/fn_ptr_vec_direct.sab",
        stderr_buf.writer().any(),
        .{ .test_filter = "function pointer survives vec push through function", .allow_fallback = false },
    )) orelse {
        std.debug.print("{s}", .{stderr_buf.items});
        return error.TestUnexpectedResult;
    };

    var module = try sci_bridge.sab.decodeModule(std.testing.allocator, sab_bytes);
    defer module.deinit(std.testing.allocator);

    var saw_vec_push = false;
    var saw_vec_new = false;
    var saw_unrelated_vec_free = false;
    var saw_call_indirect = false;
    for (module.function_sigs) |fsig| {
        if (std.mem.eql(u8, fsig.name, "sa_vec_push")) saw_vec_push = true;
        if (std.mem.eql(u8, fsig.name, "sa_vec_new")) saw_vec_new = true;
        if (std.mem.eql(u8, fsig.name, "sa_vec_free")) saw_unrelated_vec_free = true;
    }
    for (module.instructions) |item| {
        try std.testing.expectEqualStrings("", item.raw_text);
        if (item.kind == .call_indirect) saw_call_indirect = true;
    }
    try std.testing.expect(saw_vec_push);
    try std.testing.expect(saw_vec_new);
    try std.testing.expect(!saw_unrelated_vec_free);
    try std.testing.expect(saw_call_indirect);
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
}

test "sla sab backend lowers std surface function metadata directly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    const sab_bytes = (try compileSlaFileToSabWithOptions(
        arena.allocator(),
        "tests/test_unit_vec_len_direct.sla",
        ".sla-cache/sab/vec_len_direct.sab",
        stderr_buf.writer().any(),
        .{ .test_filter = "direct vec len metadata", .allow_fallback = false },
    )) orelse {
        std.debug.print("{s}", .{stderr_buf.items});
        return error.TestUnexpectedResult;
    };

    var module = try sci_bridge.sab.decodeModule(std.testing.allocator, sab_bytes);
    defer module.deinit(std.testing.allocator);

    var saw_vec_len = false;
    var saw_len_call = false;
    for (module.function_sigs) |fsig| {
        if (std.mem.eql(u8, fsig.name, "sa_vec_len")) saw_vec_len = true;
    }
    for (module.instructions) |item| {
        try std.testing.expectEqualStrings("", item.raw_text);
        if (item.kind == .call and item.operands[1] == .text and std.mem.indexOf(u8, item.operands[1].text, "@sa_vec_len") != null) {
            saw_len_call = true;
        }
    }
    try std.testing.expect(saw_vec_len);
    try std.testing.expect(saw_len_call);
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
}

test "sla sab backend lowers typed vec index directly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    const sab_bytes = (try compileSlaFileToSabWithOptions(
        arena.allocator(),
        "tests/test_unit_vec_index_direct.sla",
        ".sla-cache/sab/vec_index_direct.sab",
        stderr_buf.writer().any(),
        .{ .test_filter = "direct vec i32 index uses element width", .allow_fallback = false },
    )) orelse {
        std.debug.print("{s}", .{stderr_buf.items});
        return error.TestUnexpectedResult;
    };

    var module = try sci_bridge.sab.decodeModule(std.testing.allocator, sab_bytes);
    defer module.deinit(std.testing.allocator);

    var saw_i32_load = false;
    var saw_i32_stride = false;
    var saw_u64_stride = false;
    for (module.instructions) |item| {
        try std.testing.expectEqualStrings("", item.raw_text);
        if (item.kind == .load and item.operands[3] == .ty and item.operands[3].ty == @intFromEnum(sci_bridge.sab.signature.PrimType.i32)) {
            saw_i32_load = true;
        }
        if (item.kind == .op and item.op_kind == .mul and item.operands[2] == .imm_i64) {
            if (item.operands[2].imm_i64 == 4) saw_i32_stride = true;
            if (item.operands[2].imm_i64 == 8) saw_u64_stride = true;
        }
    }
    try std.testing.expect(saw_i32_load);
    try std.testing.expect(saw_i32_stride);
    try std.testing.expect(!saw_u64_stride);
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
}

test "sla sab backend lowers fallible std surface metadata directly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    const sab_bytes = (try compileSlaFileToSabWithOptions(
        arena.allocator(),
        "tests/test_unit_vec_remove_direct.sla",
        ".sla-cache/sab/vec_remove_direct.sab",
        stderr_buf.writer().any(),
        .{ .test_filter = "direct vec remove metadata", .allow_fallback = false },
    )) orelse {
        std.debug.print("{s}", .{stderr_buf.items});
        return error.TestUnexpectedResult;
    };

    var module = try sci_bridge.sab.decodeModule(std.testing.allocator, sab_bytes);
    defer module.deinit(std.testing.allocator);

    var saw_vec_try_remove = false;
    var saw_remove_call = false;
    var saw_fallible_branch = false;
    var saw_panic_86 = false;
    for (module.function_sigs) |fsig| {
        if (std.mem.eql(u8, fsig.name, "sa_vec_try_remove")) saw_vec_try_remove = true;
    }
    for (module.instructions) |item| {
        try std.testing.expectEqualStrings("", item.raw_text);
        if (item.kind == .call and item.operands[1] == .text and std.mem.indexOf(u8, item.operands[1].text, "@sa_vec_try_remove") != null) {
            saw_remove_call = true;
        }
        if (item.kind == .br) saw_fallible_branch = true;
        if (item.kind == .panic and item.operands[0] == .text and std.mem.eql(u8, item.operands[0].text, "86")) {
            saw_panic_86 = true;
        }
    }
    try std.testing.expect(saw_vec_try_remove);
    try std.testing.expect(saw_remove_call);
    try std.testing.expect(saw_fallible_branch);
    try std.testing.expect(saw_panic_86);
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
}

test "sla sab backend lowers option std surface metadata directly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    const sab_bytes = (try compileSlaFileToSabWithOptions(
        arena.allocator(),
        "tests/test_unit_option_direct.sla",
        ".sla-cache/sab/option_direct.sab",
        stderr_buf.writer().any(),
        .{ .test_filter = "direct option constructors and query methods", .allow_fallback = false },
    )) orelse {
        std.debug.print("{s}", .{stderr_buf.items});
        return error.TestUnexpectedResult;
    };

    var module = try sci_bridge.sab.decodeModule(std.testing.allocator, sab_bytes);
    defer module.deinit(std.testing.allocator);

    var saw_alloc = false;
    var saw_store = false;
    var saw_load = false;
    var saw_unwrap_panic_const = false;
    var saw_panic_msg = false;
    for (module.const_decls) |decl| {
        if (std.mem.eql(u8, decl.name, "OPTION_UNWRAP_PANIC")) saw_unwrap_panic_const = true;
    }
    for (module.instructions) |item| {
        try std.testing.expectEqualStrings("", item.raw_text);
        if (item.kind == .alloc) saw_alloc = true;
        if (item.kind == .store) saw_store = true;
        if (item.kind == .load) saw_load = true;
        if (item.kind == .panic_msg) saw_panic_msg = true;
    }
    try std.testing.expect(saw_alloc);
    try std.testing.expect(saw_store);
    try std.testing.expect(saw_load);
    try std.testing.expect(saw_unwrap_panic_const);
    try std.testing.expect(saw_panic_msg);
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
}

test "sla sab backend lowers result std surface metadata directly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    const sab_bytes = (try compileSlaFileToSabWithOptions(
        arena.allocator(),
        "tests/test_unit_result_direct.sla",
        ".sla-cache/sab/result_direct.sab",
        stderr_buf.writer().any(),
        .{ .test_filter = "direct result constructors and query methods", .allow_fallback = false },
    )) orelse {
        std.debug.print("{s}", .{stderr_buf.items});
        return error.TestUnexpectedResult;
    };

    var module = try sci_bridge.sab.decodeModule(std.testing.allocator, sab_bytes);
    defer module.deinit(std.testing.allocator);

    var saw_alloc = false;
    var saw_store = false;
    var saw_load = false;
    var saw_unwrap_panic_const = false;
    for (module.const_decls) |decl| {
        if (std.mem.eql(u8, decl.name, "RESULT_UNWRAP_PANIC")) saw_unwrap_panic_const = true;
    }
    for (module.instructions) |item| {
        try std.testing.expectEqualStrings("", item.raw_text);
        if (item.kind == .alloc) saw_alloc = true;
        if (item.kind == .store) saw_store = true;
        if (item.kind == .load) saw_load = true;
    }
    try std.testing.expect(saw_alloc);
    try std.testing.expect(saw_store);
    try std.testing.expect(saw_load);
    try std.testing.expect(saw_unwrap_panic_const);
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
}

test "sla sab backend lowers closure calls directly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    const sab_bytes = (try compileSlaFileToSabWithOptions(
        arena.allocator(),
        "tests/test_unit_closures.sla",
        ".sla-cache/sab/closures_direct.sab",
        stderr_buf.writer().any(),
        .{ .test_filter = "closure supports multiple params", .allow_fallback = false },
    )) orelse {
        std.debug.print("{s}", .{stderr_buf.items});
        return error.TestUnexpectedResult;
    };

    var module = try sci_bridge.sab.decodeModule(std.testing.allocator, sab_bytes);
    defer module.deinit(std.testing.allocator);

    var saw_closure_func = false;
    for (module.function_sigs) |fsig| {
        if (std.mem.eql(u8, fsig.name, "sla__closure_two_args")) saw_closure_func = true;
    }
    for (module.instructions) |item| try std.testing.expectEqualStrings("", item.raw_text);
    try std.testing.expect(saw_closure_func);
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
}

test "sla sab backend lowers var scalar slots directly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    const sab_bytes = (try compileSlaFileToSabWithOptions(
        arena.allocator(),
        "tests/test_unit_var_phase1.sla",
        ".sla-cache/sab/var_phase1_direct.sab",
        stderr_buf.writer().any(),
        .{ .test_filter = "var initialized before loop remains readable", .allow_fallback = false },
    )) orelse {
        std.debug.print("{s}", .{stderr_buf.items});
        return error.TestUnexpectedResult;
    };

    var module = try sci_bridge.sab.decodeModule(std.testing.allocator, sab_bytes);
    defer module.deinit(std.testing.allocator);

    var saw_stack_alloc = false;
    var saw_loop_jump = false;
    for (module.instructions) |item| {
        try std.testing.expectEqualStrings("", item.raw_text);
        if (item.kind == .stack_alloc) saw_stack_alloc = true;
        if (item.kind == .jmp) saw_loop_jump = true;
    }
    try std.testing.expect(saw_stack_alloc);
    try std.testing.expect(saw_loop_jump);
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
}

test "sla sab backend lowers tuple literals and destructuring directly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    const sab_bytes = (try compileSlaFileToSabWithOptions(
        arena.allocator(),
        "tests/test_unit_tuples.sla",
        ".sla-cache/sab/tuples_direct.sab",
        stderr_buf.writer().any(),
        .{ .test_filter = "tuple destructuring", .allow_fallback = false },
    )) orelse {
        std.debug.print("{s}", .{stderr_buf.items});
        return error.TestUnexpectedResult;
    };

    var module = try sci_bridge.sab.decodeModule(std.testing.allocator, sab_bytes);
    defer module.deinit(std.testing.allocator);

    var saw_alloc = false;
    var saw_load = false;
    var saw_store = false;
    for (module.instructions) |item| {
        try std.testing.expectEqualStrings("", item.raw_text);
        if (item.kind == .alloc) saw_alloc = true;
        if (item.kind == .load) saw_load = true;
        if (item.kind == .store) saw_store = true;
    }
    try std.testing.expect(saw_alloc);
    try std.testing.expect(saw_load);
    try std.testing.expect(saw_store);
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
}

test "sla sab backend lowers scalar if expressions directly" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const source =
        \\fn pick(cond: bool) -> i32 {
        \\    return if cond { 3 } else { 4 };
        \\};
        \\
        \\@test "if value"() {
        \\    if pick(true) != 3 { panic(30101); };
        \\    if pick(false) != 4 { panic(30102); };
        \\};
    ;
    try tmp.dir.writeFile(.{ .sub_path = "if_value.sla", .data = source });
    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    const sab_bytes = (try compileSlaFileToSabWithOptions(
        arena.allocator(),
        "if_value.sla",
        ".sla-cache/sab/if_value.sab",
        stderr_buf.writer().any(),
        .{ .test_filter = "if value", .allow_fallback = false },
    )) orelse {
        std.debug.print("{s}", .{stderr_buf.items});
        return error.TestUnexpectedResult;
    };

    var module = try sci_bridge.sab.decodeModule(std.testing.allocator, sab_bytes);
    defer module.deinit(std.testing.allocator);
    for (module.instructions) |item| try std.testing.expectEqualStrings("", item.raw_text);
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
}

test "sla sab backend lowers typed if bindings and var assignments directly" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const source =
        \\fn typed_pick(cond: bool) -> i32 {
        \\    let value: i32 = if cond { 1 } else { 2 };
        \\    return value;
        \\};
        \\
        \\fn var_pick(cond: bool) -> i32 {
        \\    var x: i32;
        \\    x = if cond { 8 } else { 9 };
        \\    return x;
        \\};
        \\
        \\fn bool_pick(cond: bool) -> bool {
        \\    return if cond { true } else { false };
        \\};
        \\
        \\fn float_pick(cond: bool) -> f64 {
        \\    return if cond { 1.5 } else { 2.5 };
        \\};
        \\
        \\@test "if binding variants"() {
        \\    if typed_pick(true) != 1 { panic(30301); };
        \\    if typed_pick(false) != 2 { panic(30302); };
        \\    if var_pick(true) != 8 { panic(30303); };
        \\    if var_pick(false) != 9 { panic(30304); };
        \\    if bool_pick(true) != true { panic(30305); };
        \\    if bool_pick(false) { panic(30306); };
        \\    if float_pick(true) != 1.5 { panic(30307); };
        \\    if float_pick(false) != 2.5 { panic(30308); };
        \\};
    ;
    try tmp.dir.writeFile(.{ .sub_path = "if_binding_variants.sla", .data = source });
    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    const sab_bytes = (try compileSlaFileToSabWithOptions(
        arena.allocator(),
        "if_binding_variants.sla",
        ".sla-cache/sab/if_binding_variants.sab",
        stderr_buf.writer().any(),
        .{ .test_filter = "if binding variants", .allow_fallback = false },
    )) orelse {
        std.debug.print("{s}", .{stderr_buf.items});
        return error.TestUnexpectedResult;
    };

    var module = try sci_bridge.sab.decodeModule(std.testing.allocator, sab_bytes);
    defer module.deinit(std.testing.allocator);
    for (module.instructions) |item| try std.testing.expectEqualStrings("", item.raw_text);
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
}

test "sla sab backend lowers nested if assignments directly" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const source =
        \\fn nested(a: bool, b: bool) -> i32 {
        \\    var x: i32;
        \\    if a {
        \\        x = if b { 11 } else { 12 };
        \\    } else {
        \\        x = if b { 13 } else { 14 };
        \\    };
        \\    return x;
        \\};
        \\
        \\fn reassign_let(cond: bool) -> i32 {
        \\    let x: i32 = 0;
        \\    if cond {
        \\        x = 21;
        \\    } else {
        \\        x = 22;
        \\    };
        \\    return x;
        \\};
        \\
        \\@test "nested if assignments"() {
        \\    if nested(true, true) != 11 { panic(30401); };
        \\    if nested(true, false) != 12 { panic(30402); };
        \\    if nested(false, true) != 13 { panic(30403); };
        \\    if nested(false, false) != 14 { panic(30404); };
        \\    if reassign_let(true) != 21 { panic(30405); };
        \\    if reassign_let(false) != 22 { panic(30406); };
        \\};
    ;
    try tmp.dir.writeFile(.{ .sub_path = "nested_if_assignments.sla", .data = source });
    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    const sab_bytes = (try compileSlaFileToSabWithOptions(
        arena.allocator(),
        "nested_if_assignments.sla",
        ".sla-cache/sab/nested_if_assignments.sab",
        stderr_buf.writer().any(),
        .{ .test_filter = "nested if assignments", .allow_fallback = false },
    )) orelse {
        std.debug.print("{s}", .{stderr_buf.items});
        return error.TestUnexpectedResult;
    };

    var module = try sci_bridge.sab.decodeModule(std.testing.allocator, sab_bytes);
    defer module.deinit(std.testing.allocator);
    for (module.instructions) |item| try std.testing.expectEqualStrings("", item.raw_text);
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
}

test "sla sab backend lowers float arithmetic directly" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const source =
        \\@test "float add"() {
        \\    let sum = 1.5 + 2.25;
        \\    if sum != 3.75 { panic(30201); };
        \\};
    ;
    try tmp.dir.writeFile(.{ .sub_path = "float_add.sla", .data = source });
    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    const sab_bytes = (try compileSlaFileToSabWithOptions(
        arena.allocator(),
        "float_add.sla",
        ".sla-cache/sab/float_add.sab",
        stderr_buf.writer().any(),
        .{ .test_filter = "float add", .allow_fallback = false },
    )) orelse {
        std.debug.print("{s}", .{stderr_buf.items});
        return error.TestUnexpectedResult;
    };

    var module = try sci_bridge.sab.decodeModule(std.testing.allocator, sab_bytes);
    defer module.deinit(std.testing.allocator);
    var saw_fadd = false;
    var saw_fcmp = false;
    for (module.instructions) |item| {
        try std.testing.expectEqualStrings("", item.raw_text);
        if (item.kind == .op and item.op_kind == .fadd) saw_fadd = true;
        if (item.kind == .op and item.op_kind == .fcmp_ne) saw_fcmp = true;
    }
    try std.testing.expect(saw_fadd);
    try std.testing.expect(saw_fcmp);
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
}

test "sla sab backend lowers boolean logic directly" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const source =
        \\fn both(a: bool, b: bool) -> bool {
        \\    return a && b;
        \\};
        \\
        \\fn either(a: bool, b: bool) -> bool {
        \\    return a || b;
        \\};
        \\
        \\@test "boolean logic"() {
        \\    if both(true, true) != true { panic(30501); };
        \\    if both(true, false) { panic(30502); };
        \\    if either(false, true) != true { panic(30503); };
        \\    if either(false, false) { panic(30504); };
        \\};
    ;
    try tmp.dir.writeFile(.{ .sub_path = "boolean_logic.sla", .data = source });
    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    const sab_bytes = (try compileSlaFileToSabWithOptions(
        arena.allocator(),
        "boolean_logic.sla",
        ".sla-cache/sab/boolean_logic.sab",
        stderr_buf.writer().any(),
        .{ .test_filter = "boolean logic", .allow_fallback = false },
    )) orelse {
        std.debug.print("{s}", .{stderr_buf.items});
        return error.TestUnexpectedResult;
    };

    var module = try sci_bridge.sab.decodeModule(std.testing.allocator, sab_bytes);
    defer module.deinit(std.testing.allocator);
    var saw_and = false;
    var saw_or = false;
    for (module.instructions) |item| {
        try std.testing.expectEqualStrings("", item.raw_text);
        if (item.kind == .op and item.op_kind == .@"and") saw_and = true;
        if (item.kind == .op and item.op_kind == .@"or") saw_or = true;
    }
    try std.testing.expect(saw_and);
    try std.testing.expect(saw_or);
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
}

test "sla sab backend lowers numeric casts directly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    const sab_bytes = (try compileSlaFileToSabWithOptions(
        arena.allocator(),
        "tests/test_unit_numeric_casts.sla",
        ".sla-cache/sab/numeric_casts_direct.sab",
        stderr_buf.writer().any(),
        .{ .test_filter = "numeric casts direct", .allow_fallback = false },
    )) orelse {
        std.debug.print("{s}", .{stderr_buf.items});
        return error.TestUnexpectedResult;
    };

    var module = try sci_bridge.sab.decodeModule(std.testing.allocator, sab_bytes);
    defer module.deinit(std.testing.allocator);
    var saw_trunc = false;
    var saw_zext = false;
    var saw_sext = false;
    var saw_sitofp = false;
    var saw_fptosi = false;
    var saw_fptrunc = false;
    var saw_fpext = false;
    for (module.instructions) |item| {
        try std.testing.expectEqualStrings("", item.raw_text);
        if (item.kind == .op and item.operands[2] == .ty) {
            if (item.op_kind == .trunc) saw_trunc = true;
            if (item.op_kind == .zext) saw_zext = true;
            if (item.op_kind == .sext) saw_sext = true;
            if (item.op_kind == .sitofp) saw_sitofp = true;
            if (item.op_kind == .fptosi) saw_fptosi = true;
            if (item.op_kind == .fptrunc) saw_fptrunc = true;
            if (item.op_kind == .fpext) saw_fpext = true;
        }
    }
    try std.testing.expect(saw_trunc);
    try std.testing.expect(saw_zext);
    try std.testing.expect(saw_sext);
    try std.testing.expect(saw_sitofp);
    try std.testing.expect(saw_fptosi);
    try std.testing.expect(saw_fptrunc);
    try std.testing.expect(saw_fpext);
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
}

test "sla sab backend lowers borrow and deref directly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    const sab_bytes = (try compileSlaFileToSabWithOptions(
        arena.allocator(),
        "tests/test_unit_borrow_direct.sla",
        ".sla-cache/sab/borrow_direct.sab",
        stderr_buf.writer().any(),
        .{ .test_filter = "direct borrow deref", .allow_fallback = false },
    )) orelse {
        std.debug.print("{s}", .{stderr_buf.items});
        return error.TestUnexpectedResult;
    };

    var module = try sci_bridge.sab.decodeModule(std.testing.allocator, sab_bytes);
    defer module.deinit(std.testing.allocator);
    var saw_borrow = false;
    var saw_load = false;
    var saw_stack_alloc = false;
    for (module.instructions) |item| {
        try std.testing.expectEqualStrings("", item.raw_text);
        if (item.kind == .borrow) saw_borrow = true;
        if (item.kind == .load) saw_load = true;
        if (item.kind == .stack_alloc) saw_stack_alloc = true;
    }
    try std.testing.expect(saw_borrow);
    try std.testing.expect(saw_load);
    try std.testing.expect(saw_stack_alloc);
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
}

test "sla sab backend lowers array literals dynamic indexes and range for directly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    const sab_bytes = (try compileSlaFileToSabWithOptions(
        arena.allocator(),
        "tests/test_unit_array_direct.sla",
        ".sla-cache/sab/array_direct.sab",
        stderr_buf.writer().any(),
        .{ .test_filter = "direct array literal repeat dynamic index range for", .allow_fallback = false },
    )) orelse {
        std.debug.print("{s}", .{stderr_buf.items});
        return error.TestUnexpectedResult;
    };

    var module = try sci_bridge.sab.decodeModule(std.testing.allocator, sab_bytes);
    defer module.deinit(std.testing.allocator);
    var saw_alloc = false;
    var saw_store = false;
    var saw_load = false;
    var saw_ptr_add = false;
    var saw_stack_alloc = false;
    for (module.instructions) |item| {
        try std.testing.expectEqualStrings("", item.raw_text);
        if (item.kind == .alloc) saw_alloc = true;
        if (item.kind == .store) saw_store = true;
        if (item.kind == .load) saw_load = true;
        if (item.kind == .ptr_add) saw_ptr_add = true;
        if (item.kind == .stack_alloc) saw_stack_alloc = true;
    }
    try std.testing.expect(saw_alloc);
    try std.testing.expect(saw_store);
    try std.testing.expect(saw_load);
    try std.testing.expect(saw_ptr_add);
    try std.testing.expect(saw_stack_alloc);
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
}

test "sla sab backend lowers move arguments through fresh temps" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    const sab_bytes = (try compileSlaFileToSabWithOptions(
        arena.allocator(),
        "tests/test_unit_move_direct.sla",
        ".sla-cache/sab/move_direct.sab",
        stderr_buf.writer().any(),
        .{ .test_filter = "direct move struct argument", .allow_fallback = false },
    )) orelse {
        std.debug.print("{s}", .{stderr_buf.items});
        return error.TestUnexpectedResult;
    };

    var module = try sci_bridge.sab.decodeModule(std.testing.allocator, sab_bytes);
    defer module.deinit(std.testing.allocator);
    var saw_fresh_move_call = false;
    var saw_direct_binding_move_call = false;
    for (module.instructions) |item| {
        try std.testing.expectEqualStrings("", item.raw_text);
        if (item.kind == .call and item.operands[1] == .text) {
            if (std.mem.indexOf(u8, item.operands[1].text, "^tmp_") != null) saw_fresh_move_call = true;
            if (std.mem.indexOf(u8, item.operands[1].text, "^item") != null) saw_direct_binding_move_call = true;
        }
    }
    try std.testing.expect(saw_fresh_move_call);
    try std.testing.expect(!saw_direct_binding_move_call);
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
    try std.testing.expect(std.mem.startsWith(u8, keep_path, ".sla-cache/sab/"));
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
