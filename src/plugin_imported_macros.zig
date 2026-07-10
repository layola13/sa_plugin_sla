const std = @import("std");
const type_checker_mod = @import("type_checker.zig");
const source_expand = @import("source_expand.zig");

pub fn expandedSourceMayContainImportedMacros(expanded_source: []const u8) bool {
    return std.mem.indexOf(u8, expanded_source, "[MACRO]") != null;
}

pub fn macroParamName(raw: []const u8) []const u8 {
    var param = std.mem.trim(u8, raw, " \t\r,");
    if (param.len > 0 and param[0] == '%') param = param[1..];
    return param;
}

pub fn isLeadingOutputMacroParam(raw: []const u8) bool {
    const param = macroParamName(raw);
    return std.mem.startsWith(u8, param, "out") or
        std.mem.eql(u8, param, "nonnull_ptr") or
        std.mem.eql(u8, param, "type_id") or
        std.mem.eql(u8, param, "any_ref") or
        std.mem.eql(u8, param, "cursor") or
        std.mem.eql(u8, param, "take") or
        std.mem.eql(u8, param, "repeat");
}

pub fn macroParamIndex(param_names: []const []const u8, name: []const u8) ?usize {
    for (param_names, 0..) |param, idx| {
        if (std.mem.eql(u8, param, name)) return idx;
    }
    return null;
}

pub fn markBorrowedParam(mask: *u64, param_names: []const []const u8, raw_name: []const u8) void {
    const name = macroParamName(raw_name);
    if (macroParamIndex(param_names, name)) |idx| {
        if (idx < 64) mask.* |= (@as(u64, 1) << @intCast(idx));
    }
}

pub fn markDirectBorrowedMacroParams(allocator: std.mem.Allocator, mask: *u64, param_names: []const []const u8, line: []const u8) !void {
    for (param_names) |param| {
        const needle = try std.fmt.allocPrint(allocator, "&%{s}", .{param});
        defer allocator.free(needle);
        if (std.mem.indexOf(u8, line, needle) != null) markBorrowedParam(mask, param_names, param);
    }
}

pub fn markDirectAddressSlotMacroParams(allocator: std.mem.Allocator, mask: *u64, param_names: []const []const u8, line: []const u8) !void {
    for (param_names) |param| {
        const needle = try std.fmt.allocPrint(allocator, "%{s}+", .{param});
        defer allocator.free(needle);
        if (std.mem.indexOf(u8, line, needle) != null) markBorrowedParam(mask, param_names, param);
    }
}

pub fn markExpandedImportedMacroParamMasks(
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

pub fn importedMacroCalleeName(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n\"");
    const without_at = if (std.mem.startsWith(u8, trimmed, "@")) trimmed[1..] else trimmed;
    const source_name = if (std.mem.startsWith(u8, without_at, "sla__")) without_at["sla__".len..] else without_at;
    return try allocator.dupe(u8, source_name);
}

pub fn appendUniqueDirectCallee(callees: *std.ArrayList([]const u8), name: []const u8) !void {
    for (callees.items) |existing| {
        if (std.mem.eql(u8, existing, name)) return;
    }
    try callees.append(name);
}

pub fn collectDirectSlaMacroCallees(allocator: std.mem.Allocator, callees: *std.ArrayList([]const u8), line: []const u8) !void {
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

pub fn appendExpandedImportedMacroDirectCallees(
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

pub fn loadImportedMacrosFromExpandedSource(
    tc: *type_checker_mod.TypeChecker,
    allocator: std.mem.Allocator,
    expanded_source: []const u8,
    import_path: ?[]const u8,
) !void {
    if (!expandedSourceMayContainImportedMacros(expanded_source)) return;
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

pub fn loadImportedMacros(tc: *type_checker_mod.TypeChecker, allocator: std.mem.Allocator, source: []const u8, import_path: ?[]const u8) !void {
    const expanded_source = try source_expand.expand(allocator, source);
    try loadImportedMacrosFromExpandedSource(tc, allocator, expanded_source, import_path);
}
