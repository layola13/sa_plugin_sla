pub const BranchStateMergeAction = enum {
    restore_pre,
    restore_then,
    restore_else,
    keep_current,
};

pub fn planBranchStateMerge(then_terminated: bool, else_terminated: bool) BranchStateMergeAction {
    if (then_terminated and else_terminated) return .restore_pre;
    if (then_terminated) return .restore_else;
    if (else_terminated) return .restore_then;
    return .keep_current;
}
