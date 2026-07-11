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
