const std = @import("std");
const sci_bridge = @import("sci_bridge");
const sab = sci_bridge.sab;
const inst = sab.instruction;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next();
    const path = args.next() orelse return error.MissingPath;
    const symbol_name = args.next();
    const bytes = try std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024 * 64);
    defer allocator.free(bytes);
    const stdout = std.io.getStdOut().writer();
    if (symbol_name) |name| {
        try dumpSymbolUses(allocator, bytes, name, stdout);
    } else {
        try sab.disasmModule(allocator, bytes, stdout);
    }
}

fn dumpSymbolUses(allocator: std.mem.Allocator, bytes: []const u8, symbol_name: []const u8, writer: anytype) !void {
    var module = try sab.decodeModule(allocator, bytes);
    defer module.deinit(allocator);

    const symbol_id = for (module.symbols, 0..) |name, idx| {
        if (std.mem.eql(u8, name, symbol_name)) break @as(u32, @intCast(idx));
    } else {
        try writer.print("symbol not found: {s}\n", .{symbol_name});
        return;
    };

    try writer.print("symbol {s} id={d}\n", .{ symbol_name, symbol_id });
    var use_count: usize = 0;
    for (module.instructions, 0..) |item, instruction_idx| {
        if (!instructionMentionsSymbol(item, symbol_id, symbol_name)) continue;
        use_count += 1;
        const function_name = enclosingFunctionName(module.function_sigs, instruction_idx);
        try writer.print(
            "\ninst[{d}] function={s} kind={s} source={d} expanded={d}\n",
            .{ instruction_idx, function_name, @tagName(item.kind), item.source_line, item.expanded_line },
        );
        if (item.upstream_loc) |loc| {
            try writer.print("  upstream={s}:{d}:{d}\n", .{ loc.file, loc.line, loc.col });
        }
        try writer.print("  raw={s}\n", .{item.raw_text});
        for (item.operands, 0..) |operand, operand_idx| {
            try writer.print("  operand[{d}]=", .{operand_idx});
            try writeOperand(writer, module.symbols, operand);
            try writer.writeByte('\n');
        }
        if (item.atomic_expected_text) |text| try writer.print("  atomic_expected={s}\n", .{text});
        if (item.atomic_new_text) |text| try writer.print("  atomic_new={s}\n", .{text});
        for (item.native_reg_names) |name| try writer.print("  native_reg={s}\n", .{name});
    }
    try writer.print("\nuses={d}\n", .{use_count});
}

fn enclosingFunctionName(function_sigs: []const sab.signature.FunctionSig, instruction_idx: usize) []const u8 {
    var best_name: []const u8 = "<module>";
    var best_entry: usize = 0;
    var found = false;
    for (function_sigs) |function_sig| {
        const entry: usize = @intCast(function_sig.entry_inst_idx);
        if (entry > instruction_idx) continue;
        if (!found or entry >= best_entry) {
            found = true;
            best_entry = entry;
            best_name = function_sig.name;
        }
    }
    return best_name;
}

fn instructionMentionsSymbol(item: inst.Instruction, symbol_id: u32, symbol_name: []const u8) bool {
    for (item.operands) |operand| {
        switch (operand) {
            .reg => |id| if (id == symbol_id) return true,
            .text, .native_text => |text| if (textMentionsSymbol(text, symbol_name)) return true,
            else => {},
        }
    }
    if (textMentionsSymbol(item.raw_text, symbol_name)) return true;
    if (item.atomic_expected_text) |text| {
        if (textMentionsSymbol(text, symbol_name)) return true;
    }
    if (item.atomic_new_text) |text| {
        if (textMentionsSymbol(text, symbol_name)) return true;
    }
    for (item.native_reg_names) |name| {
        if (textMentionsSymbol(name, symbol_name)) return true;
    }
    return false;
}

fn textMentionsSymbol(text: []const u8, symbol_name: []const u8) bool {
    var offset: usize = 0;
    while (std.mem.indexOfPos(u8, text, offset, symbol_name)) |start| {
        const end = start + symbol_name.len;
        const left_is_ident = start != 0 and isIdentifierChar(text[start - 1]);
        const right_is_ident = end != text.len and isIdentifierChar(text[end]);
        if (!left_is_ident and !right_is_ident) return true;
        offset = end;
    }
    return false;
}

fn isIdentifierChar(char: u8) bool {
    return std.ascii.isAlphanumeric(char) or char == '_';
}

fn writeOperand(writer: anytype, symbols: []const []const u8, operand: inst.Operand) !void {
    switch (operand) {
        .none => try writer.writeAll("none"),
        .reg => |id| try writeNamedId(writer, "reg", symbols, id),
        .symbol => |id| try writeNamedId(writer, "symbol", symbols, id),
        .label => |id| try writeNamedId(writer, "label", symbols, id),
        .func => |id| try writeNamedId(writer, "func", symbols, id),
        .imm_i64 => |value| try writer.print("imm_i64:{d}", .{value}),
        .imm_u64 => |value| try writer.print("imm_u64:{d}", .{value}),
        .imm_int => |value| try writer.print("imm_int:{d}", .{value}),
        .imm_float => |value| try writer.print("imm_float:{d}", .{value}),
        .op_code => |value| try writer.print("op_code:{s}", .{@tagName(value)}),
        .cap_prefix => |value| try writer.print("cap_prefix:{s}", .{@tagName(value)}),
        .offset => |value| try writer.print("offset:{d}", .{value}),
        .ty => |value| try writer.print("ty:{d}", .{value}),
        .text => |value| try writer.print("text:{s}", .{value}),
        .native_text => |value| try writer.print("native_text:{s}", .{value}),
    }
}

fn writeNamedId(writer: anytype, tag: []const u8, symbols: []const []const u8, id: u32) !void {
    const index: usize = @intCast(id);
    if (index < symbols.len) {
        try writer.print("{s}:{d}({s})", .{ tag, id, symbols[index] });
    } else {
        try writer.print("{s}:{d}(invalid)", .{ tag, id });
    }
}
