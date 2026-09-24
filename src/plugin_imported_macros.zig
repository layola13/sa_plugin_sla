const std = @import("std");
const type_checker_mod = @import("type_checker.zig");
const lowering_rules = @import("lowering_rules.zig");
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

/// Mark params the macro body moves with an explicit `^` prefix (e.g.
/// `call @ext(^%buf)`). Unlike `&`, infix `^` is XOR, so a `^%param`
/// occurrence only counts when the `^` opens an operand: the previous
/// non-space character must be a delimiter (`(`, `,`, `=`, `[`, `{`) or the
/// start of the line. `a ^ %b` (XOR) and `%x^%y` are not moves.
pub fn markDirectMovedMacroParams(allocator: std.mem.Allocator, mask: *u64, param_names: []const []const u8, line: []const u8) !void {
    for (param_names) |param| {
        const needle = try std.fmt.allocPrint(allocator, "^%{s}", .{param});
        defer allocator.free(needle);
        var search_from: usize = 0;
        while (search_from < line.len) {
            const rel = std.mem.indexOf(u8, line[search_from..], needle) orelse break;
            const abs = search_from + rel;
            var back = abs;
            while (back > 0 and (line[back - 1] == ' ' or line[back - 1] == '\t')) back -= 1;
            const opens_operand = back == 0 or switch (line[back - 1]) {
                '(', ',', '=', '[', '{' => true,
                else => false,
            };
            if (opens_operand) {
                markBorrowedParam(mask, param_names, param);
                break;
            }
            search_from = abs + 1;
        }
    }
}

pub fn markDirectAddressSlotMacroParams(allocator: std.mem.Allocator, mask: *u64, param_names: []const []const u8, line: []const u8) !void {
    for (param_names) |param| {
        const needle = try std.fmt.allocPrint(allocator, "%{s}+", .{param});
        defer allocator.free(needle);
        // The `%param+` reference must be a standalone token: a `%` preceded
        // by an identifier character is a hygiene suffix embedded in another
        // variable (e.g. `__xosp_s_%out_ptr+0` embeds `%out_ptr` but is not
        // address arithmetic on `%out_ptr` itself). Without the boundary
        // check, such macros are misclassified as direct-address-slot
        // writers and the caller's slot register gets redefined by the
        // macro body's `%out = load ...` assignment.
        var search_from: usize = 0;
        while (search_from < line.len) {
            const rel = std.mem.indexOf(u8, line[search_from..], needle) orelse break;
            const abs = search_from + rel;
            const boundary_ok = abs == 0 or !isMacroIdentChar(line[abs - 1]);
            if (boundary_ok) {
                // 纯数字位移 (`load %p+0 as u8`) 是经由地址的穿透读写,
                // 需要地址本身的值, 而非给值安家; 只有命名位移
                // (`load %s+Slice_ptr`) 才是结构体字段投影, 需要槽位。
                // 否则调用方会被误标 addressable, 家化后宏读到槽内
                // 存的值字节 (如指针地址低字节) 而非穿透目标。
                var off_end = abs + needle.len;
                while (off_end < line.len and std.ascii.isDigit(line[off_end])) : (off_end += 1) {}
                const off_len = off_end - (abs + needle.len);
                if (off_len > 0 and (off_end >= line.len or !isMacroIdentChar(line[off_end]))) {
                    search_from = off_end;
                    continue;
                }
                markBorrowedParam(mask, param_names, param);
                break;
            }
            search_from = abs + 1;
        }
    }
}

fn isMacroIdentChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_';
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
    // Record the expanded macro itself so result-kind resolution can recurse
    // into it (e.g. STR_LEN -> SLICE_GET_LEN -> u64).
    try appendUniqueDirectCallee(callees, expanded_name);
    for (expanded.direct_callees) |callee| try appendUniqueDirectCallee(callees, callee);
}

// --- Bug 2 fix: derive a single-output imported macro's expression result
// type from its body ---
//
// When a user-defined single-output imported macro (e.g. J_GET) is used as an
// expression, the type checker needs a result type. Instead of growing the
// hardcoded name table in lowering_rules.importedMacroExpressionResultKind,
// we derive it here at index time from the macro body's `%out` assignment:
//   %out_node = load __slot_%out_node+0 as ptr   -> .raw_pointer
//   %out_n    = load __slot_%out_n+0 as u64      -> .u64
//   %out_p    = stack_alloc 8                    -> .raw_pointer

fn saTextCastTypeNameToExpressionResultKind(type_name: []const u8) ?lowering_rules.ImportedMacroExpressionResultKind {
    if (std.mem.eql(u8, type_name, "ptr")) return .raw_pointer;
    if (std.mem.eql(u8, type_name, "bool")) return .boolean;
    if (std.mem.eql(u8, type_name, "u8")) return .u8;
    if (std.mem.eql(u8, type_name, "u32")) return .u32;
    if (std.mem.eql(u8, type_name, "u64")) return .u64;
    if (std.mem.eql(u8, type_name, "i32")) return .i32;
    if (std.mem.eql(u8, type_name, "i64")) return .i64;
    if (std.mem.eql(u8, type_name, "f64")) return .f64;
    return null;
}

fn parseImportedMacroExpressionResultKind(s: []const u8) ?lowering_rules.ImportedMacroExpressionResultKind {
    inline for (@typeInfo(lowering_rules.ImportedMacroExpressionResultKind).@"enum".fields) |field| {
        if (std.mem.eql(u8, s, field.name)) return @field(lowering_rules.ImportedMacroExpressionResultKind, field.name);
    }
    return null;
}

fn stripSaTextLineComment(line: []const u8) []const u8 {
    if (std.mem.indexOf(u8, line, "//")) |idx| return std.mem.trimRight(u8, line[0..idx], " \t");
    return line;
}

fn deriveImportedMacroExpressionResultKind(
    out_param_name: []const u8,
    body_line: []const u8,
) ?lowering_rules.ImportedMacroExpressionResultKind {
    // Expect a plain assignment to the single `%out` param: "%<name> = <rhs>".
    const line = std.mem.trim(u8, stripSaTextLineComment(body_line), " \t\r");
    if (line.len < out_param_name.len + 2 or line[0] != '%') return null;
    if (!std.mem.eql(u8, line[1 .. 1 + out_param_name.len], out_param_name)) return null;
    var rest = std.mem.trimLeft(u8, line[1 + out_param_name.len ..], " \t");
    if (rest.len < 2 or rest[0] != '=' or rest[1] == '=') return null;
    rest = std.mem.trimLeft(u8, rest[1..], " \t");
    if (rest.len == 0) return null;
    if (std.mem.startsWith(u8, rest, "stack_alloc")) return .raw_pointer;
    // A trailing `as <ty>` cast on the RHS pins the result type.
    if (std.mem.lastIndexOf(u8, rest, " as ")) |idx| {
        const type_name = std.mem.trim(u8, rest[idx + " as ".len ..], " \t\r");
        return saTextCastTypeNameToExpressionResultKind(type_name);
    }
    return null;
}

/// Detects `%out = call @extern_name(...)` — a direct passthrough where the
/// macro's output IS the extern's return value (no transformation).
/// Returns the extern name, or null if not a direct call.
fn deriveDirectExternPassthrough(out_param_name: []const u8, body_line: []const u8) ?[]const u8 {
    const line = std.mem.trim(u8, body_line, " \t\r");
    if (line.len < out_param_name.len + 2 or line[0] != '%') return null;
    if (!std.mem.eql(u8, line[1 .. 1 + out_param_name.len], out_param_name)) return null;
    var rest = std.mem.trimLeft(u8, line[1 + out_param_name.len ..], " \t");
    if (rest.len < 2 or rest[0] != '=' or rest[1] == '=') return null;
    rest = std.mem.trimLeft(u8, rest[1..], " \t");
    // Must be exactly `call @name(...)` — no `as` cast, no other ops.
    if (!std.mem.startsWith(u8, rest, "call @")) return null;
    rest = rest["call @".len..];
    // Extract extern name up to '(' or whitespace.
    var end: usize = 0;
    while (end < rest.len and rest[end] != '(' and rest[end] != ' ' and rest[end] != '\t') : (end += 1) {}
    if (end == 0) return null;
    return rest[0..end];
}

/// Returns true if the body line directly assigns to `%out_param` (i.e.
/// `%<out_param> = ...`). Used to distinguish output-source EXPANDs from
/// helper EXPANDs.
fn isDirectOutAssignment(out_param_name: []const u8, body_line: []const u8) bool {
    const line = std.mem.trim(u8, body_line, " \t\r");
    if (line.len < out_param_name.len + 2 or line[0] != '%') return false;
    if (!std.mem.eql(u8, line[1 .. 1 + out_param_name.len], out_param_name)) return false;
    const rest = std.mem.trimLeft(u8, line[1 + out_param_name.len ..], " \t");
    if (rest.len < 2 or rest[0] != '=' or rest[1] == '=') return false;
    return true;
}

fn macroIndexCachePath(allocator: std.mem.Allocator, import_path: []const u8, expanded_source: []const u8) ![]u8 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(import_path);
    hasher.update(&std.mem.toBytes(@as(u64, expanded_source.len)));
    hasher.update(expanded_source);
    // Cache format v8: moved_arg_mask recorded (params the macro body moves
    // with an explicit `^` prefix); address-slot classification requires a
    // token boundary before `%param+` (hygiene-suffix false positives like
    // `__xosp_s_%out_ptr+0` fixed) and excludes pure-numeric displacements
    // (`load %p+0 as u8` is a penetrating read through the address value,
    // not a struct-field projection needing a home slot).
    hasher.update("idx-format-v8");
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
    const bytes = std.fs.cwd().readFileAlloc(allocator, cache_path, 16 * 1024 * 1024) catch return false;
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
        const moved_s = parts.next() orelse "0";
        const callees_s = parts.next() orelse "";
        const kind_s = parts.next() orelse "";
        const passthrough_s = parts.next() orelse "";
        const has_assign_s = parts.next() orelse "0";
        const arity = std.fmt.parseInt(usize, arity_s, 10) catch continue;
        const leading = std.fmt.parseInt(usize, leading_s, 10) catch continue;
        const borrowed = std.fmt.parseInt(u64, borrow_s, 10) catch continue;
        const address = std.fmt.parseInt(u64, address_s, 10) catch continue;
        const moved = std.fmt.parseInt(u64, moved_s, 10) catch 0;
        const expression_result_kind = parseImportedMacroExpressionResultKind(kind_s);
        var callee_list = std.ArrayList([]const u8).init(allocator);
        defer callee_list.deinit();
        if (callees_s.len != 0) {
            var cparts = std.mem.splitScalar(u8, callees_s, ',');
            while (cparts.next()) |c| {
                if (c.len == 0) continue;
                try callee_list.append(try allocator.dupe(u8, c));
            }
        }
        const owned_import = if (import_path) |path| try allocator.dupe(u8, path) else null;
        const owned_passthrough = if (passthrough_s.len > 0) try allocator.dupe(u8, passthrough_s) else null;
        const has_direct_out_assignment = std.mem.eql(u8, has_assign_s, "1");
        try tc.registerImportedMacro(try allocator.dupe(u8, name), arity, leading, owned_import, borrowed, address, moved, try callee_list.toOwnedSlice(), expression_result_kind, owned_passthrough, has_direct_out_assignment);
    }
    return true;
}

fn storeImportedMacrosCache(cache_path: []const u8, records: []const []const u8) void {
    const dir = std.fs.path.dirname(cache_path) orelse return;
    std.fs.cwd().makePath(dir) catch return;
    const file = std.fs.cwd().createFile(cache_path, .{}) catch return;
    defer file.close();
    for (records) |line| {
        file.writeAll(line) catch return;
        file.writeAll("\n") catch return;
    }
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
    var cache_records = std.ArrayList([]const u8).init(allocator);
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
        var moved_arg_mask: u64 = 0;
        var direct_callees = std.ArrayList([]const u8).init(allocator);
        defer direct_callees.deinit();
        // Bug 2 fix: for a single leading-output macro, derive the expression
        // result type from the `%out` param's assignment in the body.
        const single_out_param: ?[]const u8 = if (leading_outputs == 1 and param_names.items.len > 0) param_names.items[0] else null;
        var expression_result_kind: ?lowering_rules.ImportedMacroExpressionResultKind = null;
        var direct_extern_passthrough: ?[]const u8 = null;
        var has_direct_out_assignment: bool = false;
        while (lines.next()) |body_raw_line| {
            const body_line = std.mem.trim(u8, body_raw_line, " \t\r");
            if (std.mem.startsWith(u8, body_line, "[END_MACRO]")) break;
            try markDirectBorrowedMacroParams(allocator, &borrowed_arg_mask, param_names.items, body_line);
            try markDirectAddressSlotMacroParams(allocator, &address_slot_arg_mask, param_names.items, body_line);
            try markDirectMovedMacroParams(allocator, &moved_arg_mask, param_names.items, body_line);
            markExpandedImportedMacroParamMasks(tc, &borrowed_arg_mask, &address_slot_arg_mask, param_names.items, body_line);
            try collectDirectSlaMacroCallees(allocator, &direct_callees, body_line);
            try appendExpandedImportedMacroDirectCallees(tc, &direct_callees, body_line);
            if (single_out_param) |out_name| {
                if (expression_result_kind == null) {
                    expression_result_kind = deriveImportedMacroExpressionResultKind(out_name, body_line);
                }
                if (direct_extern_passthrough == null) {
                    if (deriveDirectExternPassthrough(out_name, body_line)) |ext_name| {
                        direct_extern_passthrough = ext_name;
                    }
                }
                if (!has_direct_out_assignment and isDirectOutAssignment(out_name, body_line)) {
                    has_direct_out_assignment = true;
                }
            }
        }

        const owned_import_path = if (import_path) |path| try allocator.dupe(u8, path) else null;
        const owned_callees = try direct_callees.toOwnedSlice();
        // Cache line: name|arity|leading|borrow|address|moved|callee1,callee2|result_kind|passthrough_extern|has_out_assign
        var callee_joined = std.ArrayList(u8).init(allocator);
        defer callee_joined.deinit();
        for (owned_callees, 0..) |callee, idx| {
            if (idx != 0) try callee_joined.append(',');
            try callee_joined.appendSlice(callee);
        }
        const kind_name = if (expression_result_kind) |kind| @tagName(kind) else "";
        const passthrough_name = direct_extern_passthrough orelse "";
        const has_assign_s = if (has_direct_out_assignment) "1" else "0";
        const record = try std.fmt.allocPrint(allocator, "{s}|{d}|{d}|{d}|{d}|{d}|{s}|{s}|{s}|{s}", .{ name, arity, leading_outputs, borrowed_arg_mask, address_slot_arg_mask, moved_arg_mask, callee_joined.items, kind_name, passthrough_name, has_assign_s });
        try cache_records.append(record);
        const owned_passthrough = if (direct_extern_passthrough) |pn| try allocator.dupe(u8, pn) else null;
        try tc.registerImportedMacro(name, arity, leading_outputs, owned_import_path, borrowed_arg_mask, address_slot_arg_mask, moved_arg_mask, owned_callees, expression_result_kind, owned_passthrough, has_direct_out_assignment);
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
