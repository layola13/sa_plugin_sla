const std = @import("std");
const ast = @import("ast.zig");

pub const BranchStateMergeAction = enum {
    restore_pre,
    restore_then,
    restore_else,
    keep_current,
};

pub const FunctionExitCleanupAction = enum {
    release,
    transfer_result,
};

pub fn planFunctionExitCleanup(cleanup_name: []const u8, result_expr: *const ast.Node) FunctionExitCleanupAction {
    const result_name = switch (result_expr.*) {
        .identifier => |name| name,
        .move_expr => |move| if (move.expr.* == .identifier) move.expr.identifier else return .release,
        else => return .release,
    };
    return if (std.mem.eql(u8, cleanup_name, result_name)) .transfer_result else .release;
}

pub fn macroParamConsumesValue(body: []const *ast.Node, name: []const u8) bool {
    for (body) |node| {
        if (macroNodeConsumesValue(node, name)) return true;
    }
    return false;
}

fn macroNodeConsumesValue(node: *const ast.Node, name: []const u8) bool {
    return switch (node.*) {
        .move_expr => |move| move.expr.* == .identifier and std.mem.eql(u8, move.expr.identifier, name),
        .release_stmt => |release| std.mem.eql(u8, release.var_name, name),
        .block_stmt => |block| macroParamConsumesValue(block.body, name),
        .if_expr => |ife| macroParamConsumesValue(ife.then_block, name) or
            (if (ife.else_block) |else_block| macroParamConsumesValue(else_block, name) else false),
        .switch_expr => |swe| blk: {
            for (swe.cases) |case| if (macroParamConsumesValue(case.body, name)) break :blk true;
            break :blk false;
        },
        .match_expr => |mat| blk: {
            for (mat.cases) |case| if (macroParamConsumesValue(case.body, name)) break :blk true;
            break :blk false;
        },
        .unsafe_expr => |unsafe_expr| macroParamConsumesValue(unsafe_expr.body, name),
        .for_stmt => |for_stmt| macroParamConsumesValue(for_stmt.body, name),
        .while_stmt => |while_stmt| macroParamConsumesValue(while_stmt.body, name),
        .expr_stmt => |expr| macroNodeConsumesValue(expr, name),
        .assign_stmt => |assign| macroNodeConsumesValue(assign.value, name),
        .let_stmt => |let| macroNodeConsumesValue(let.value, name),
        .return_stmt => |ret| if (ret.value) |value| macroNodeConsumesValue(value, name) else false,
        else => false,
    };
}

pub const ValueState = enum {
    uninitialized,
    active,
    consumed,
};

pub const MultiBranchStateMergeAction = enum {
    restore_pre,
    restore_single,
    intersect_live,
};

pub fn planBranchStateMerge(then_terminated: bool, else_terminated: bool) BranchStateMergeAction {
    if (then_terminated and else_terminated) return .restore_pre;
    if (then_terminated) return .restore_else;
    if (else_terminated) return .restore_then;
    return .keep_current;
}

pub fn planMultiBranchStateMerge(live_branch_count: usize) MultiBranchStateMergeAction {
    return switch (live_branch_count) {
        0 => .restore_pre,
        1 => .restore_single,
        else => .intersect_live,
    };
}

pub fn intersectLiveBranchValueStates(states: []const ValueState) ValueState {
    if (states.len == 0) return .active;
    const first = states[0];
    var all_same = true;
    var has_uninitialized = first == .uninitialized;
    for (states[1..]) |state| {
        if (state != first) all_same = false;
        if (state == .uninitialized) has_uninitialized = true;
    }
    if (all_same) return first;
    if (has_uninitialized) return .uninitialized;
    return .consumed;
}

test "user macro value consumption follows nested move expressions" {
    var value = ast.Node{ .identifier = "value" };
    var moved = ast.Node{ .move_expr = .{ .expr = &value } };
    var target = ast.Node{ .identifier = "out" };
    var assign = ast.Node{ .assign_stmt = .{ .target = &target, .value = &moved } };
    var block = ast.Node{ .block_stmt = .{ .body = &.{&assign} } };

    try std.testing.expect(macroParamConsumesValue(&.{&block}, "value"));
    try std.testing.expect(!macroParamConsumesValue(&.{&block}, "out"));
}
