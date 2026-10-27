const std = @import("std");
const sio = @import("sio");
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

fn isMacroRegisterNameChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '%';
}

pub fn markDirectAddressSlotMacroParams(allocator: std.mem.Allocator, mask: *u64, param_names: []const []const u8, line: []const u8) !void {
    for (param_names) |param| {
        const needle = try std.fmt.allocPrint(allocator, "%{s}+", .{param});
        defer allocator.free(needle);
        // The `%param+` shape only proves the parameter is used as an
        // address base when the `%` starts a fresh register token. Inside
        // a longer synthetic register name built by textual interpolation
        // (e.g. the `%index` inside `__process_argv_slot_%argv_%index`
        // followed by `+SaProcessArgv_data` in a store) the match is a
        // different register entirely; treating it as the parameter made
        // pure value parameters (PROCESS_ARGV_SET_PTR's %index) look like
        // address-slot parameters, so callers passed a stack slot's
        // address where the value was expected (D3).
        var search_from: usize = 0;
        while (std.mem.indexOfPos(u8, line, search_from, needle)) |hit| {
            if (hit == 0 or !isMacroRegisterNameChar(line[hit - 1])) {
                markBorrowedParam(mask, param_names, param);
                break;
            }
            search_from = hit + 1;
        }
    }
}

const MacroParamRefKind = enum { value, deref, addr_take };

/// Classifies one whitespace/comma/paren-delimited body token as a
/// reference to macro parameter `param`. A token that merely contains
/// the parameter name inside a longer register name (an interpolated
/// synthetic like `__sink_%out_db`, or a longer parameter sharing the
/// prefix) is a different register entirely and does not count.
fn classifyMacroParamToken(token: []const u8, param: []const u8) ?MacroParamRefKind {
    var rest = token;
    var took_addr = false;
    if (rest.len > 0 and rest[0] == '&') {
        took_addr = true;
        rest = rest[1..];
    }
    if (rest.len == 0 or rest[0] != '%') return null;
    rest = rest[1..];
    if (!std.mem.startsWith(u8, rest, param)) return null;
    const after = rest[param.len..];
    if (after.len == 0) return if (took_addr) .addr_take else .value;
    if (after[0] == '+') return .deref;
    return null;
}

/// True when the (trimmed) body line assigns the parameter directly:
/// `%param = ...` with the parameter as the whole LHS token.
fn macroParamLineAssigns(line: []const u8, param: []const u8) bool {
    if (!std.mem.startsWith(u8, line, "%")) return false;
    var rest = line[1..];
    if (!std.mem.startsWith(u8, rest, param)) return false;
    rest = rest[param.len..];
    if (rest.len > 0 and isMacroRegisterNameChar(rest[0])) return false;
    rest = std.mem.trimStart(u8, rest, " \t");
    return rest.len > 0 and rest[0] == '=' and (rest.len == 1 or rest[1] != '=');
}

/// Per-parameter scan state for markAssignedOutputMacroParams:
/// 0 = unseen, 1 = assigned before any memory reference, 2 = tainted
/// (a memory dereference or address-take precedes the first assignment,
/// so the parameter has address semantics, not register-output
/// semantics). Passing a parameter into a nested EXPAND position that
/// the callee assigns counts as an assignment of the parameter;
/// passing it into a borrowed/address-slot callee position counts as a
/// memory reference.
pub fn markAssignedOutputMacroParams(
    tc: *type_checker_mod.TypeChecker,
    param_names: []const []const u8,
    ref_state: []u8,
    line: []const u8,
) void {
    const is_expand = std.mem.startsWith(u8, line, "EXPAND");
    var expanded_assigned: u64 = 0;
    var expanded_memory: u64 = 0;
    if (is_expand) {
        var head = std.mem.tokenizeAny(u8, line["EXPAND".len..], " \t,()");
        if (head.next()) |expanded_name| {
            if (tc.imported_macros.get(expanded_name)) |expanded| {
                expanded_assigned = expanded.assigned_output_mask;
                expanded_memory = expanded.borrowed_arg_mask | expanded.address_slot_arg_mask;
            }
        }
    }
    for (param_names, 0..) |param, idx| {
        if (ref_state[idx] == 2) continue;
        const lhs_assign = !is_expand and macroParamLineAssigns(line, param);
        var pending_assign = false;
        var tokens = std.mem.tokenizeAny(u8, line, " \t,()");
        var token_idx: usize = 0;
        while (tokens.next()) |token| : (token_idx += 1) {
            const kind = classifyMacroParamToken(token, param) orelse continue;
            if (lhs_assign and token_idx == 0) {
                // The LHS occurrence itself: its assignment takes effect
                // only after the line's RHS references are evaluated.
                pending_assign = true;
                continue;
            }
            if (is_expand and token_idx >= 2) {
                const arg_pos = token_idx - 2;
                if (arg_pos < 64) {
                    const bit = @as(u64, 1) << @intCast(arg_pos);
                    if ((expanded_assigned & bit) != 0) {
                        if (ref_state[idx] == 0) ref_state[idx] = 1;
                        continue;
                    }
                    if ((expanded_memory & bit) != 0) {
                        if (ref_state[idx] == 0) ref_state[idx] = 2;
                        continue;
                    }
                }
            }
            switch (kind) {
                .value => {},
                .deref, .addr_take => {
                    if (ref_state[idx] == 0) ref_state[idx] = 2;
                },
            }
        }
        if (pending_assign and ref_state[idx] == 0) ref_state[idx] = 1;
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

pub fn appendUniqueDirectCallee(callees: *std.array_list.Managed([]const u8), name: []const u8) !void {
    for (callees.items) |existing| {
        if (std.mem.eql(u8, existing, name)) return;
    }
    try callees.append(name);
}

pub fn collectDirectSlaMacroCallees(allocator: std.mem.Allocator, callees: *std.array_list.Managed([]const u8), line: []const u8) !void {
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
    callees: *std.array_list.Managed([]const u8),
    line: []const u8,
) !void {
    if (!std.mem.startsWith(u8, line, "EXPAND")) return;
    var parts = std.mem.tokenizeAny(u8, line["EXPAND".len..], " \t,");
    const expanded_name = parts.next() orelse return;
    const expanded = tc.imported_macros.get(expanded_name) orelse return;
    for (expanded.direct_callees) |callee| try appendUniqueDirectCallee(callees, callee);
}

fn macroIndexCachePath(allocator: std.mem.Allocator, import_path: []const u8, expanded_source: []const u8) ![]u8 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(import_path);
    hasher.update(&std.mem.toBytes(@as(u64, expanded_source.len)));
    hasher.update(expanded_source);
    const digest = hasher.final();
    const stem = std.fs.path.basename(import_path);
    return try std.fmt.allocPrint(allocator, ".sla-cache/macros/{s}-{x}.idx", .{ stem, digest });
}

fn tryLoadImportedMacrosFromCache(
    tc: *type_checker_mod.TypeChecker,
    allocator: std.mem.Allocator,
    cache_path: []const u8,
    import_path: ?[]const u8,
) !bool {
    const bytes = sio.cwd().readFileAlloc(allocator, cache_path, 16 * 1024 * 1024) catch return false;
    defer allocator.free(bytes);
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw| {
        if (raw.len == 0) continue;
        var parts = std.mem.splitScalar(u8, raw, '|');
        const name = parts.next() orelse continue;
        const arity_s = parts.next() orelse continue;
        const leading_s = parts.next() orelse continue;
        const borrow_s = parts.next() orelse continue;
        const address_s = parts.next() orelse continue;
        const callees_s = parts.next() orelse "";
        // Records written before the assigned-output mask existed have
        // no seventh field; treat the whole cache as stale and rescan
        // rather than silently registering masks of zero.
        const assigned_s = parts.next() orelse return false;
        const arity = std.fmt.parseInt(usize, arity_s, 10) catch continue;
        const leading = std.fmt.parseInt(usize, leading_s, 10) catch continue;
        const borrowed = std.fmt.parseInt(u64, borrow_s, 10) catch continue;
        const address = std.fmt.parseInt(u64, address_s, 10) catch continue;
        const assigned = std.fmt.parseInt(u64, assigned_s, 10) catch return false;
        var callee_list = std.array_list.Managed([]const u8).init(allocator);
        defer callee_list.deinit();
        if (callees_s.len != 0) {
            var cparts = std.mem.splitScalar(u8, callees_s, ',');
            while (cparts.next()) |c| {
                if (c.len == 0) continue;
                try callee_list.append(try allocator.dupe(u8, c));
            }
        }
        const owned_import = if (import_path) |path| try allocator.dupe(u8, path) else null;
        try tc.registerImportedMacro(try allocator.dupe(u8, name), arity, leading, owned_import, borrowed, address, assigned, try callee_list.toOwnedSlice());
    }
    return true;
}

fn storeImportedMacrosCache(cache_path: []const u8, records: []const []const u8) void {
    const dir = std.fs.path.dirname(cache_path) orelse return;
    sio.cwd().makePath(dir) catch return;
    const file = sio.cwd().createFile(cache_path, .{ .truncate = true }) catch return;
    defer file.close();
    var wb: [8192]u8 = undefined;
    var w = file.writer(&wb);
    for (records) |line| {
        w.interface.writeAll(line) catch return;
        w.interface.writeAll("\n") catch return;
    }
    w.interface.flush() catch return;
}

pub fn loadImportedMacrosFromExpandedSource(
    tc: *type_checker_mod.TypeChecker,
    allocator: std.mem.Allocator,
    expanded_source: []const u8,
    import_path: ?[]const u8,
) !void {
    if (!expandedSourceMayContainImportedMacros(expanded_source)) return;
    if (import_path) |path| {
        const cache_path = macroIndexCachePath(allocator, path, expanded_source) catch null;
        if (cache_path) |cp| {
            defer allocator.free(cp);
            if (try tryLoadImportedMacrosFromCache(tc, allocator, cp, import_path)) return;
        }
    }
    var cache_records = std.array_list.Managed([]const u8).init(allocator);
    defer {
        for (cache_records.items) |line| allocator.free(line);
        cache_records.deinit();
    }
    var lines = std.mem.splitScalar(u8, expanded_source, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (!std.mem.startsWith(u8, line, "[MACRO]")) continue;

        var parts = std.mem.tokenizeAny(u8, line["[MACRO]".len..], " \t");
        const raw_name = parts.next() orelse continue;
        const name = try allocator.dupe(u8, std.mem.trim(u8, raw_name, " \t\r,"));

        var param_names = std.array_list.Managed([]const u8).init(allocator);
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
        var assigned_output_mask: u64 = 0;
        const param_ref_state = try allocator.alloc(u8, param_names.items.len);
        defer allocator.free(param_ref_state);
        @memset(param_ref_state, 0);
        var direct_callees = std.array_list.Managed([]const u8).init(allocator);
        defer direct_callees.deinit();
        while (lines.next()) |body_raw_line| {
            const body_line = std.mem.trim(u8, body_raw_line, " \t\r");
            if (std.mem.startsWith(u8, body_line, "[END_MACRO]")) break;
            try markDirectBorrowedMacroParams(allocator, &borrowed_arg_mask, param_names.items, body_line);
            try markDirectAddressSlotMacroParams(allocator, &address_slot_arg_mask, param_names.items, body_line);
            markExpandedImportedMacroParamMasks(tc, &borrowed_arg_mask, &address_slot_arg_mask, param_names.items, body_line);
            markAssignedOutputMacroParams(tc, param_names.items, param_ref_state, body_line);
            try collectDirectSlaMacroCallees(allocator, &direct_callees, body_line);
            try appendExpandedImportedMacroDirectCallees(tc, &direct_callees, body_line);
        }
        for (param_ref_state, 0..) |state, idx| {
            if (state == 1 and idx < 64) assigned_output_mask |= @as(u64, 1) << @intCast(idx);
        }

        const owned_import_path = if (import_path) |path| try allocator.dupe(u8, path) else null;
        const owned_callees = try direct_callees.toOwnedSlice();
        // Cache line: name|arity|leading|borrow|address|callee1,callee2
        var callee_joined = std.array_list.Managed(u8).init(allocator);
        defer callee_joined.deinit();
        for (owned_callees, 0..) |callee, idx| {
            if (idx != 0) try callee_joined.append(',');
            try callee_joined.appendSlice(callee);
        }
        const record = try std.fmt.allocPrint(allocator, "{s}|{d}|{d}|{d}|{d}|{s}|{d}", .{ name, arity, leading_outputs, borrowed_arg_mask, address_slot_arg_mask, callee_joined.items, assigned_output_mask });
        try cache_records.append(record);
        try tc.registerImportedMacro(name, arity, leading_outputs, owned_import_path, borrowed_arg_mask, address_slot_arg_mask, assigned_output_mask, owned_callees);
    }
    if (import_path) |path| {
        const cache_path = macroIndexCachePath(allocator, path, expanded_source) catch null;
        if (cache_path) |cp| {
            defer allocator.free(cp);
            storeImportedMacrosCache(cp, cache_records.items);
        }
    }
}

pub fn loadImportedMacros(tc: *type_checker_mod.TypeChecker, allocator: std.mem.Allocator, source: []const u8, import_path: ?[]const u8) !void {
    const expanded_source = try source_expand.expand(allocator, source);
    try loadImportedMacrosFromExpandedSource(tc, allocator, expanded_source, import_path);
}
