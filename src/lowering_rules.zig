const std = @import("std");
const ast = @import("ast.zig");
const type_checker = @import("type_checker.zig");

pub fn deriveNameMatches(actual: []const u8, wanted: []const u8) bool {
    return std.ascii.eqlIgnoreCase(actual, wanted);
}

pub fn structHasDerive(decl: *const ast.StructDecl, name: []const u8) bool {
    for (decl.derives) |derive| {
        if (deriveNameMatches(derive, name)) return true;
        if (deriveNameMatches(name, "eq") and deriveNameMatches(derive, "PartialEq")) return true;
        if (deriveNameMatches(name, "ord") and deriveNameMatches(derive, "PartialOrd")) return true;
    }
    return false;
}

pub const StaticCallPlan = struct {
    target_symbol: []const u8,
    arg_count: usize,

    pub fn argPrefix(_: StaticCallPlan, arg: *const ast.Node) ?u8 {
        return callArgPrefix(arg);
    }
};

pub const StaticCallResultPlan = struct {
    returns_void: bool,
};

pub const AsyncReturnPlan = struct {
    abi_ret_ty: *const ast.Type,
    wrap_ready_future: bool,
};

pub const AwaitPlan = struct {
    ready_state_inner: bool,
    pending_return_if_async: bool = false,
    ready_pending_state_return_if_async: bool = false,
    poll_once_if_statically_ready: bool = false,
};

pub const AsyncSingleAwaitContinuationPlan = struct {
    binding_name: []const u8,
    await_expr: *const ast.Node,
    awaited_kind: FutureRuntimeCallKind,
    addend: i64 = 0,
};

pub const FutureReadiness = enum {
    unknown,
    ready,
    pending,
};

pub const FutureRuntimeCallKind = enum {
    ready,
    pending,
    defer_ready,
    join2,
    pair_left,
    pair_right,
    select2,
    either_side,
    either_left,
    either_right,
};

pub const FutureRuntimeCallPlan = struct {
    kind: FutureRuntimeCallKind,
};

pub const TaskRuntimeCallKind = enum {
    new,
    poll,
    is_ready,
    result,
    state,
};

pub const TaskRuntimeCallPlan = struct {
    kind: TaskRuntimeCallKind,
};

pub const ExecutorRuntimeCallKind = enum {
    new,
    poll_one,
    poll_ready_count,
};

pub const ExecutorRuntimeCallPlan = struct {
    kind: ExecutorRuntimeCallKind,
};

pub const ExecutorTaskBufferKind = enum {
    fixed_array,
    vec,
};

pub const ExecutorTaskBufferPlan = struct {
    kind: ExecutorTaskBufferKind,
    inner: *ast.Type,
    fixed_len: ?usize = null,
};

pub const PollRuntimeCallKind = enum {
    ready,
    pending,
    is_ready,
    is_pending,
    value,
};

pub const PollRuntimeCallPlan = struct {
    kind: PollRuntimeCallKind,
};

pub const ImportedMacroCallPlan = struct {
    macro_name: []const u8,
    import_path: ?[]const u8,
    arity: usize,
    leading_outputs: usize,
    borrowed_arg_mask: u64,
    expression_output: bool,

    pub fn macroParamIndexForCallArg(self: ImportedMacroCallPlan, call_arg_index: usize) usize {
        return if (self.expression_output) call_arg_index + self.leading_outputs else call_arg_index;
    }

    pub fn callArgNeedsAddressableSlot(self: ImportedMacroCallPlan, call_arg_index: usize) bool {
        const macro_idx = self.macroParamIndexForCallArg(call_arg_index);
        if (macro_idx >= 64) return false;
        return (self.borrowed_arg_mask & (@as(u64, 1) << @intCast(macro_idx))) != 0;
    }
};

pub const LoopControlPlan = struct {
    has_break: bool,
    has_continue: bool,
};

pub const WhileLetPatternKind = enum {
    enum_variant,
    option_some,
    option_none,
    result_ok,
    result_err,
};

pub const WhileLetPatternPlan = struct {
    kind: WhileLetPatternKind,
    success_on_true: bool,
    binding_count: usize,

    pub fn bindsPayload(self: WhileLetPatternPlan) bool {
        return switch (self.kind) {
            .enum_variant, .option_some, .result_ok, .result_err => self.binding_count != 0,
            .option_none => false,
        };
    }
};

pub const DynCoercionKind = enum {
    box_to_dyn,
    rc_new_to_dyn_rc,
};

pub const DynCoercionPlan = struct {
    kind: DynCoercionKind,
    trait_name: []const u8,
};

pub fn planDynCoercion(tc: *type_checker.TypeChecker, expr: *const ast.Node) ?DynCoercionPlan {
    if (tc.dyn_box_coercions.get(expr)) |trait_name| return .{ .kind = .box_to_dyn, .trait_name = trait_name };
    if (tc.dyn_rc_coercions.get(expr)) |trait_name| return .{ .kind = .rc_new_to_dyn_rc, .trait_name = trait_name };
    return null;
}

pub const DynDispatchReceiverKind = enum {
    direct_dyn,
    rc_get_dyn,
};

pub const DynDispatchReceiverPlan = struct {
    kind: DynDispatchReceiverKind,
};

pub fn planDynDispatchReceiver(receiver_ty: *const ast.Type) ?DynDispatchReceiverPlan {
    if (rcInnerType(receiver_ty)) |inner| {
        if (dynTraitName(inner) != null) return .{ .kind = .rc_get_dyn };
    }
    if (dynTraitName(receiver_ty) != null) return .{ .kind = .direct_dyn };
    if (boxInnerType(receiver_ty)) |inner| {
        if (dynTraitName(inner) != null) return .{ .kind = .direct_dyn };
    }
    return null;
}

pub fn planLoopControl(body: []const *ast.Node) LoopControlPlan {
    return .{
        .has_break = blockContainsCurrentLoopBreak(body),
        .has_continue = blockContainsCurrentLoopContinue(body),
    };
}

pub fn planWhileLetPattern(pattern: ast.EnumPattern, has_user_enum_decl: bool) ?WhileLetPatternPlan {
    if (has_user_enum_decl) {
        return .{
            .kind = .enum_variant,
            .success_on_true = true,
            .binding_count = pattern.bindings.len,
        };
    }

    if (std.mem.eql(u8, pattern.enum_name, "Result") or std.mem.eql(u8, pattern.variant_name, "Ok") or std.mem.eql(u8, pattern.variant_name, "Err")) {
        if (std.mem.eql(u8, pattern.variant_name, "Ok")) {
            return .{ .kind = .result_ok, .success_on_true = true, .binding_count = pattern.bindings.len };
        }
        if (std.mem.eql(u8, pattern.variant_name, "Err")) {
            return .{ .kind = .result_err, .success_on_true = false, .binding_count = pattern.bindings.len };
        }
        return null;
    }

    if (std.mem.eql(u8, pattern.enum_name, "Option") or std.mem.eql(u8, pattern.variant_name, "Some") or std.mem.eql(u8, pattern.variant_name, "None")) {
        if (std.mem.eql(u8, pattern.variant_name, "Some")) {
            return .{ .kind = .option_some, .success_on_true = true, .binding_count = pattern.bindings.len };
        }
        if (std.mem.eql(u8, pattern.variant_name, "None")) {
            return .{ .kind = .option_none, .success_on_true = false, .binding_count = pattern.bindings.len };
        }
        return null;
    }

    return null;
}

pub fn blockTerminates(block: []const *ast.Node) bool {
    if (block.len == 0) return false;
    return stmtTerminates(block[block.len - 1]);
}

pub fn stmtTerminates(stmt: *const ast.Node) bool {
    return switch (stmt.*) {
        .return_stmt => true,
        .break_stmt => true,
        .continue_stmt => true,
        .expr_stmt => |expr| exprTerminates(expr),
        else => false,
    };
}

pub fn blockContainsCurrentLoopBreak(block: []const *ast.Node) bool {
    for (block) |stmt| {
        if (stmtContainsCurrentLoopBreak(stmt)) return true;
    }
    return false;
}

pub fn blockContainsCurrentLoopContinue(block: []const *ast.Node) bool {
    for (block) |stmt| {
        if (stmtContainsCurrentLoopContinue(stmt)) return true;
    }
    return false;
}

fn stmtContainsCurrentLoopBreak(stmt: *const ast.Node) bool {
    return switch (stmt.*) {
        .break_stmt => true,
        .for_stmt, .while_stmt => false,
        .block_stmt => |blk| blockContainsCurrentLoopBreak(blk.body),
        .let_else_stmt => |let_else| blockContainsCurrentLoopBreak(let_else.else_block),
        .expr_stmt => |expr| exprContainsCurrentLoopBreak(expr),
        else => false,
    };
}

fn stmtContainsCurrentLoopContinue(stmt: *const ast.Node) bool {
    return switch (stmt.*) {
        .continue_stmt => true,
        .for_stmt, .while_stmt => false,
        .block_stmt => |blk| blockContainsCurrentLoopContinue(blk.body),
        .let_else_stmt => |let_else| blockContainsCurrentLoopContinue(let_else.else_block),
        .expr_stmt => |expr| exprContainsCurrentLoopContinue(expr),
        else => false,
    };
}

fn exprContainsCurrentLoopBreak(expr: *const ast.Node) bool {
    return switch (expr.*) {
        .if_expr => |ife| blockContainsCurrentLoopBreak(ife.then_block) or if (ife.else_block) |eb| blockContainsCurrentLoopBreak(eb) else false,
        .switch_expr => |swe| blk: {
            for (swe.cases) |case| {
                if (blockContainsCurrentLoopBreak(case.body)) break :blk true;
            }
            break :blk false;
        },
        .match_expr => |mat| blk: {
            for (mat.cases) |case| {
                if (blockContainsCurrentLoopBreak(case.body)) break :blk true;
            }
            break :blk false;
        },
        .unsafe_expr => |ue| blockContainsCurrentLoopBreak(ue.body),
        else => false,
    };
}

fn exprContainsCurrentLoopContinue(expr: *const ast.Node) bool {
    return switch (expr.*) {
        .if_expr => |ife| blockContainsCurrentLoopContinue(ife.then_block) or if (ife.else_block) |eb| blockContainsCurrentLoopContinue(eb) else false,
        .switch_expr => |swe| blk: {
            for (swe.cases) |case| {
                if (blockContainsCurrentLoopContinue(case.body)) break :blk true;
            }
            break :blk false;
        },
        .match_expr => |mat| blk: {
            for (mat.cases) |case| {
                if (blockContainsCurrentLoopContinue(case.body)) break :blk true;
            }
            break :blk false;
        },
        .unsafe_expr => |ue| blockContainsCurrentLoopContinue(ue.body),
        else => false,
    };
}

fn exprTerminates(expr: *const ast.Node) bool {
    return switch (expr.*) {
        .call_expr => |call| std.mem.eql(u8, call.func_name, "panic"),
        .unsafe_expr => |ue| blockTerminates(ue.body),
        .if_expr => |ife| blockTerminates(ife.then_block) and if (ife.else_block) |eb| blockTerminates(eb) else false,
        .match_expr => |mat| {
            if (mat.cases.len == 0) return false;
            for (mat.cases) |case| {
                if (!blockTerminates(case.body)) return false;
            }
            return true;
        },
        else => false,
    };
}

pub fn isVoidType(ty: *const ast.Type) bool {
    return ty.* == .primitive and ty.primitive == .void_type;
}

pub fn planStaticCallResult(tc: *type_checker.TypeChecker, call_plan: StaticCallPlan, expr_ty: ?*const ast.Type) StaticCallResultPlan {
    if (expr_ty) |ty| return .{ .returns_void = isVoidType(ty) };
    if (tc.funcs.get(call_plan.target_symbol)) |func| {
        return .{ .returns_void = !func.is_async and isVoidType(func.ret_ty) };
    }
    return .{ .returns_void = false };
}

pub fn planAsyncFunctionReturn(func: ast.FuncDecl, ptr_ty: *const ast.Type) AsyncReturnPlan {
    return .{
        .abi_ret_ty = if (func.is_async) ptr_ty else func.ret_ty,
        .wrap_ready_future = func.is_async,
    };
}

fn asyncContinuationAddend(expr: *const ast.Node, binding_name: []const u8) ?i64 {
    switch (expr.*) {
        .identifier => |name| return if (std.mem.eql(u8, name, binding_name)) 0 else null,
        .binary_expr => |bin| {
            if (bin.op != .add) return null;
            if (bin.left.* == .identifier and std.mem.eql(u8, bin.left.identifier, binding_name) and bin.right.* == .literal and bin.right.literal == .int_val) {
                return bin.right.literal.int_val;
            }
            if (bin.right.* == .identifier and std.mem.eql(u8, bin.right.identifier, binding_name) and bin.left.* == .literal and bin.left.literal == .int_val) {
                return bin.left.literal.int_val;
            }
            return null;
        },
        else => return null,
    }
}

pub fn planAsyncSingleAwaitContinuation(func: *const ast.FuncDecl) ?AsyncSingleAwaitContinuationPlan {
    if (!func.is_async or func.body.len != 2) return null;
    if (func.body[0].* != .let_stmt) return null;
    const let_stmt = func.body[0].let_stmt;
    if (let_stmt.value.* != .await_expr) return null;
    if (let_stmt.value.await_expr.expr.* != .call_expr) return null;
    const awaited_call = planFutureRuntimeCall(let_stmt.value.await_expr.expr.call_expr) orelse return null;
    if (awaited_call.kind != .defer_ready) return null;

    const ret_expr = switch (func.body[1].*) {
        .return_stmt => |ret| ret.value orelse return null,
        .expr_stmt => |expr| expr,
        else => return null,
    };
    const addend = asyncContinuationAddend(ret_expr, let_stmt.name) orelse return null;
    return .{
        .binding_name = let_stmt.name,
        .await_expr = let_stmt.value.await_expr.expr,
        .awaited_kind = awaited_call.kind,
        .addend = addend,
    };
}

pub fn exprIsStaticallyPendingFuture(expr: *const ast.Node) bool {
    return exprFutureReadiness(expr, null) == .pending;
}

pub fn exprIsStaticallyReadyFuture(expr: *const ast.Node) bool {
    return exprFutureReadiness(expr, null) == .ready;
}

pub fn join2Readiness(left: FutureReadiness, right: FutureReadiness) FutureReadiness {
    if (left == .ready and right == .ready) return .ready;
    if (left == .pending or right == .pending) return .pending;
    return .unknown;
}

pub fn select2Readiness(left: FutureReadiness, right: FutureReadiness) FutureReadiness {
    if (left == .ready or right == .ready) return .ready;
    if (left == .pending and right == .pending) return .pending;
    return .unknown;
}

pub fn exprFutureReadiness(expr: *const ast.Node, readiness_by_name: ?*const std.StringHashMap(FutureReadiness)) FutureReadiness {
    if (expr.* == .identifier) {
        if (readiness_by_name) |map| return map.get(expr.identifier) orelse .unknown;
        return .unknown;
    }
    if (expr.* != .call_expr) return .unknown;
    const call = expr.call_expr;
    const plan = planFutureRuntimeCall(call) orelse return .unknown;
    return switch (plan.kind) {
        .ready => .ready,
        .pending => .pending,
        .join2 => if (call.args.len == 2)
            join2Readiness(exprFutureReadiness(call.args[0], readiness_by_name), exprFutureReadiness(call.args[1], readiness_by_name))
        else
            .unknown,
        .select2 => if (call.args.len == 2)
            select2Readiness(exprFutureReadiness(call.args[0], readiness_by_name), exprFutureReadiness(call.args[1], readiness_by_name))
        else
            .unknown,
        else => .unknown,
    };
}

pub fn exprNeedsPollOnceForReadyAwait(expr: *const ast.Node, readiness_by_name: ?*const std.StringHashMap(FutureReadiness)) bool {
    if (expr.* != .call_expr) return false;
    const call = expr.call_expr;
    const plan = planFutureRuntimeCall(call) orelse return false;
    return switch (plan.kind) {
        .join2, .select2 => exprFutureReadiness(expr, readiness_by_name) == .ready,
        else => false,
    };
}

pub fn futureInnerType(ty: *const ast.Type) ?*ast.Type {
    var curr = ty;
    while (true) {
        switch (curr.*) {
            .pointer => |p| curr = p,
            .borrow => |b| curr = b,
            .future => |inner| return inner,
            else => return null,
        }
    }
}

pub fn typesEquivalent(a: *const ast.Type, b: *const ast.Type) bool {
    if (a.* == .infer or b.* == .infer) return true;
    if (std.meta.activeTag(a.*) != std.meta.activeTag(b.*)) return false;
    return switch (a.*) {
        .infer => true,
        .primitive => |pa| pa == b.primitive,
        .pointer => |pa| typesEquivalent(pa, b.pointer),
        .borrow => |ba| typesEquivalent(ba, b.borrow),
        .array => |aa| aa.len == b.array.len and typesEquivalent(aa.elem, b.array.elem),
        .tuple => |ta| blk: {
            if (ta.elems.len != b.tuple.elems.len) break :blk false;
            for (ta.elems, b.tuple.elems) |ea, eb| {
                if (!typesEquivalent(ea, eb)) break :blk false;
            }
            break :blk true;
        },
        .future => |fa| typesEquivalent(fa, b.future),
        .closure => |ca| blk: {
            if (ca.params.len != b.closure.params.len) break :blk false;
            for (ca.params, b.closure.params) |pa, pb| {
                if (!typesEquivalent(pa, pb)) break :blk false;
            }
            break :blk typesEquivalent(ca.ret, b.closure.ret);
        },
        .fn_ptr => |fa| blk: {
            if (fa.abi == null) {
                if (b.fn_ptr.abi != null) break :blk false;
            } else if (b.fn_ptr.abi == null or !std.mem.eql(u8, fa.abi.?, b.fn_ptr.abi.?)) {
                break :blk false;
            }
            if (fa.params.len != b.fn_ptr.params.len) break :blk false;
            for (fa.params, b.fn_ptr.params) |pa, pb| {
                if (!typesEquivalent(pa, pb)) break :blk false;
            }
            break :blk typesEquivalent(fa.ret, b.fn_ptr.ret);
        },
        .user_defined => |ua| blk: {
            if (!std.mem.eql(u8, ua.name, b.user_defined.name)) break :blk false;
            if (ua.generics.len != b.user_defined.generics.len) break :blk false;
            for (ua.generics, b.user_defined.generics) |ga, gb| {
                if (!typesEquivalent(ga, gb)) break :blk false;
            }
            break :blk true;
        },
    };
}

pub fn planAwaitFuture(expr: *const ast.Node, future_ty: *const ast.Type, async_return_ty: ?*const ast.Type) AwaitPlan {
    return planAwaitFutureWithReadiness(expr, future_ty, async_return_ty, null);
}

pub fn planAwaitFutureWithReadiness(expr: *const ast.Node, future_ty: *const ast.Type, async_return_ty: ?*const ast.Type, readiness_by_name: ?*const std.StringHashMap(FutureReadiness)) AwaitPlan {
    const inner = futureInnerType(future_ty);
    return .{
        .ready_state_inner = true,
        .pending_return_if_async = exprFutureReadiness(expr, readiness_by_name) == .pending,
        .poll_once_if_statically_ready = exprNeedsPollOnceForReadyAwait(expr, readiness_by_name),
        .ready_pending_state_return_if_async = if (async_return_ty) |ret_ty|
            if (inner) |inner_ty| typesEquivalent(inner_ty, ret_ty) else false
        else
            false,
    };
}

pub fn planFutureRuntimeCall(call: ast.CallExpr) ?FutureRuntimeCallPlan {
    if (call.associated_target) |target| {
        if (!std.mem.eql(u8, target, "future")) return null;
        if (std.mem.eql(u8, call.func_name, "ready")) return .{ .kind = .ready };
        if (std.mem.eql(u8, call.func_name, "pending")) return .{ .kind = .pending };
        if (std.mem.eql(u8, call.func_name, "defer_ready")) return .{ .kind = .defer_ready };
        if (std.mem.eql(u8, call.func_name, "join2")) return .{ .kind = .join2 };
        if (std.mem.eql(u8, call.func_name, "pair_left")) return .{ .kind = .pair_left };
        if (std.mem.eql(u8, call.func_name, "pair_right")) return .{ .kind = .pair_right };
        if (std.mem.eql(u8, call.func_name, "select2")) return .{ .kind = .select2 };
        if (std.mem.eql(u8, call.func_name, "either_side")) return .{ .kind = .either_side };
        if (std.mem.eql(u8, call.func_name, "either_left")) return .{ .kind = .either_left };
        if (std.mem.eql(u8, call.func_name, "either_right")) return .{ .kind = .either_right };
        return null;
    }
    if (std.mem.eql(u8, call.func_name, "future__ready")) return .{ .kind = .ready };
    if (std.mem.eql(u8, call.func_name, "future__pending")) return .{ .kind = .pending };
    if (std.mem.eql(u8, call.func_name, "future__defer_ready")) return .{ .kind = .defer_ready };
    if (std.mem.eql(u8, call.func_name, "future__join2")) return .{ .kind = .join2 };
    if (std.mem.eql(u8, call.func_name, "future__pair_left")) return .{ .kind = .pair_left };
    if (std.mem.eql(u8, call.func_name, "future__pair_right")) return .{ .kind = .pair_right };
    if (std.mem.eql(u8, call.func_name, "future__select2")) return .{ .kind = .select2 };
    if (std.mem.eql(u8, call.func_name, "future__either_side")) return .{ .kind = .either_side };
    if (std.mem.eql(u8, call.func_name, "future__either_left")) return .{ .kind = .either_left };
    if (std.mem.eql(u8, call.func_name, "future__either_right")) return .{ .kind = .either_right };
    return null;
}

pub fn planTaskRuntimeCall(call: ast.CallExpr) ?TaskRuntimeCallPlan {
    const target = call.associated_target orelse return null;
    if (!std.mem.eql(u8, target, "task")) return null;
    if (std.mem.eql(u8, call.func_name, "new")) return .{ .kind = .new };
    if (std.mem.eql(u8, call.func_name, "poll")) return .{ .kind = .poll };
    if (std.mem.eql(u8, call.func_name, "is_ready")) return .{ .kind = .is_ready };
    if (std.mem.eql(u8, call.func_name, "result")) return .{ .kind = .result };
    if (std.mem.eql(u8, call.func_name, "state")) return .{ .kind = .state };
    return null;
}

pub fn planExecutorRuntimeCall(call: ast.CallExpr) ?ExecutorRuntimeCallPlan {
    const target = call.associated_target orelse return null;
    if (!std.mem.eql(u8, target, "executor")) return null;
    if (std.mem.eql(u8, call.func_name, "new")) return .{ .kind = .new };
    if (std.mem.eql(u8, call.func_name, "poll_one")) return .{ .kind = .poll_one };
    if (std.mem.eql(u8, call.func_name, "poll_ready_count")) return .{ .kind = .poll_ready_count };
    return null;
}

pub fn planPollRuntimeCall(call: ast.CallExpr) ?PollRuntimeCallPlan {
    if (call.associated_target) |target| {
        if (!std.mem.eql(u8, target, "poll")) return null;
        if (std.mem.eql(u8, call.func_name, "ready")) return .{ .kind = .ready };
        if (std.mem.eql(u8, call.func_name, "pending")) return .{ .kind = .pending };
        if (std.mem.eql(u8, call.func_name, "is_ready")) return .{ .kind = .is_ready };
        if (std.mem.eql(u8, call.func_name, "is_pending")) return .{ .kind = .is_pending };
        if (std.mem.eql(u8, call.func_name, "value")) return .{ .kind = .value };
        return null;
    }
    if (std.mem.eql(u8, call.func_name, "poll__ready")) return .{ .kind = .ready };
    if (std.mem.eql(u8, call.func_name, "poll__pending")) return .{ .kind = .pending };
    if (std.mem.eql(u8, call.func_name, "poll__is_ready")) return .{ .kind = .is_ready };
    if (std.mem.eql(u8, call.func_name, "poll__is_pending")) return .{ .kind = .is_pending };
    if (std.mem.eql(u8, call.func_name, "poll__value")) return .{ .kind = .value };
    return null;
}

pub fn importedMacroUsesExpressionOutput(macro: type_checker.ImportedMacro, arg_count: usize) bool {
    return macro.leading_outputs == 1 and arg_count + 1 == macro.arity;
}

pub fn planImportedMacroCall(tc: *type_checker.TypeChecker, call: ast.CallExpr) ?ImportedMacroCallPlan {
    if (call.associated_target != null) return null;
    const macro = tc.imported_macros.get(call.func_name) orelse return null;
    const expression_output = importedMacroUsesExpressionOutput(macro, call.args.len);
    if (call.args.len != macro.arity and !expression_output) return null;
    return .{
        .macro_name = call.func_name,
        .import_path = macro.import_path,
        .arity = macro.arity,
        .leading_outputs = macro.leading_outputs,
        .borrowed_arg_mask = macro.borrowed_arg_mask,
        .expression_output = expression_output,
    };
}

pub const PrefixedIdentifierArg = struct {
    prefix: u8,
    name: []const u8,
};

pub const CallArgMaterializationKind = enum {
    array_to_slice_borrow,
    dyn_borrow,
    auto_borrow,
    copy_struct_value,
    value,
};

pub const CallArgMaterializationInput = struct {
    param: ?ast.Param = null,
    arg_ty: ?*const ast.Type = null,
    arg_index: usize = 0,
    auto_borrow_receiver: bool = false,
    receiver_style_auto_borrow: bool = false,
    statement_receiver_auto_borrow: bool = false,
    array_to_slice_borrow: bool = false,
    dyn_borrow_trait_name: ?[]const u8 = null,
    copy_struct_value: bool = false,
    generated_fn_ptr_identifier: bool = false,
    generated_scalar_const_identifier: bool = false,
};

pub const CallArgMaterializationPlan = struct {
    kind: CallArgMaterializationKind,
    release_after_call: bool,
    dyn_borrow_trait_name: ?[]const u8 = null,
};

pub const AbiFieldLayout = struct {
    offset: usize,
    size: usize,
    ty: *const ast.Type,
};

pub const StructLiteralFieldSource = enum {
    explicit,
    update,
};

pub const StructLiteralFieldTransfer = enum {
    direct,
    deep_copy,
    move,
};

pub const StructLiteralFieldPlan = struct {
    source: StructLiteralFieldSource,
    name: []const u8,
    value: ?*ast.Node,
    layout: AbiFieldLayout,
    field_ty: *const ast.Type,
    /// Whether an `.update` field's loaded value should be released after
    /// being stored. Mirrors SA-text's `callArgNeedsRelease(update_expr)`,
    /// so identifier-backed sources are not released (move-by-reuse) while
    /// temporary sources are released.
    release_loaded: bool,
};

pub const SliceAbi = struct {
    pub const size: usize = 16;
    pub const ptr_offset: usize = 0;
    pub const len_offset: usize = 8;
};

pub const OptionClosureMethodKind = enum {
    map,
    and_then,
    unwrap_or_else,
};

pub const OptionClosureCallPlan = struct {
    kind: OptionClosureMethodKind,
    receiver_arg_index: usize = 0,
    closure_arg_index: usize = 1,
    closure_arity: usize,
};

pub const SmartPointerKind = enum {
    box,
    rc,
    arc,
    refcell,
};

pub const SmartPointerType = struct {
    kind: SmartPointerKind,
    inner: *ast.Type,
};

pub const RefCellBorrowKind = enum {
    shared,
    mutable,
};

pub const RefCellBorrowPlan = struct {
    kind: RefCellBorrowKind,
    inner: *ast.Type,

    pub fn isMutable(self: RefCellBorrowPlan) bool {
        return self.kind == .mutable;
    }
};

pub fn abiTypeSize(ty: *const ast.Type) usize {
    return switch (ty.*) {
        .primitive => |p| switch (p) {
            .boolean, .u8, .i8 => 1,
            .u16, .i16 => 2,
            .u32, .i32, .f32 => 4,
            .u64, .i64, .usize, .isize, .f64 => 8,
            .integer, .float => 8,
            .void_type => 8,
        },
        .array => 8,
        .tuple => |tuple| tupleAbiSize(tuple),
        else => 8,
    };
}

pub fn abiPassesAsPointer(ty: *const ast.Type) bool {
    return switch (ty.*) {
        .pointer, .borrow, .fn_ptr, .user_defined, .tuple, .array, .future => true,
        else => false,
    };
}

pub fn alignAggregateOffset(offset: usize, size: usize) usize {
    if (size == 8) return (offset + 7) & ~@as(usize, 7);
    return offset;
}

pub fn tupleAbiSize(tuple: ast.TupleType) usize {
    var offset: usize = 0;
    for (tuple.elems) |elem_ty| {
        const size = abiTypeSize(elem_ty);
        offset = alignAggregateOffset(offset, size);
        offset += size;
    }
    return @max(offset, 1);
}

pub fn tupleFieldLayout(tuple: ast.TupleType, index: usize) ?AbiFieldLayout {
    var offset: usize = 0;
    for (tuple.elems, 0..) |elem_ty, i| {
        const size = abiTypeSize(elem_ty);
        offset = alignAggregateOffset(offset, size);
        if (i == index) return .{ .offset = offset, .size = size, .ty = elem_ty };
        offset += size;
    }
    return null;
}

pub fn inlineArrayStride(elem_ty: *const ast.Type) usize {
    return @max(abiTypeSize(elem_ty), 1);
}

pub fn inlineArraySize(arr: ast.ArrayType) usize {
    return @max(inlineArrayStride(arr.elem) * arr.len, 1);
}

pub fn arrayElementLayout(arr: ast.ArrayType, index: usize) ?AbiFieldLayout {
    if (index >= arr.len) return null;
    const stride = inlineArrayStride(arr.elem);
    return .{ .offset = stride * index, .size = stride, .ty = arr.elem };
}

pub fn arrayRestLen(arr: ast.ArrayType, prefix_count: usize) ?usize {
    if (prefix_count > arr.len) return null;
    return arr.len - prefix_count;
}

pub fn optionInnerType(ty: *const ast.Type) ?*ast.Type {
    var curr = ty;
    while (true) {
        switch (curr.*) {
            .pointer => |p| curr = p,
            .borrow => |b| curr = b,
            .user_defined => |ud| {
                if (std.mem.eql(u8, ud.name, "Option") and ud.generics.len == 1) return ud.generics[0];
                return null;
            },
            else => return null,
        }
    }
}

pub fn resultOkType(ty: *const ast.Type) ?*ast.Type {
    var curr = ty;
    while (true) {
        switch (curr.*) {
            .pointer => |p| curr = p,
            .borrow => |b| curr = b,
            .user_defined => |ud| {
                if (std.mem.eql(u8, ud.name, "Result") and ud.generics.len == 2) return ud.generics[0];
                return null;
            },
            else => return null,
        }
    }
}

pub fn resultErrType(ty: *const ast.Type) ?*ast.Type {
    var curr = ty;
    while (true) {
        switch (curr.*) {
            .pointer => |p| curr = p,
            .borrow => |b| curr = b,
            .user_defined => |ud| {
                if (std.mem.eql(u8, ud.name, "Result") and ud.generics.len == 2) return ud.generics[1];
                return null;
            },
            else => return null,
        }
    }
}

fn userDefinedGenericInner(ty: *const ast.Type, name: []const u8) ?*ast.Type {
    var curr = ty;
    while (true) {
        switch (curr.*) {
            .pointer => |p| curr = p,
            .borrow => |b| curr = b,
            .user_defined => |ud| {
                if (std.mem.eql(u8, ud.name, name) and ud.generics.len == 1) return ud.generics[0];
                return null;
            },
            else => return null,
        }
    }
}

pub fn vecElementType(ty: *const ast.Type) ?*ast.Type {
    return userDefinedGenericInner(ty, "Vec");
}

pub fn taskInnerType(ty: *const ast.Type) ?*ast.Type {
    return userDefinedGenericInner(ty, "Task");
}

pub fn executorTaskBufferPlan(ty: *const ast.Type) ?ExecutorTaskBufferPlan {
    var curr = ty;
    while (true) {
        switch (curr.*) {
            .pointer => |p| curr = p,
            .borrow => |b| curr = b,
            .array => |arr| {
                const inner = taskInnerType(arr.elem) orelse return null;
                return .{ .kind = .fixed_array, .inner = inner, .fixed_len = arr.len };
            },
            else => {
                const elem = vecElementType(curr) orelse return null;
                const inner = taskInnerType(elem) orelse return null;
                return .{ .kind = .vec, .inner = inner };
            },
        }
    }
}

pub fn vecElementSlotSize(ty: *const ast.Type) usize {
    return @max(abiTypeSize(ty), 8);
}

pub fn boxInnerType(ty: *const ast.Type) ?*ast.Type {
    return userDefinedGenericInner(ty, "Box");
}

pub fn rcInnerType(ty: *const ast.Type) ?*ast.Type {
    return userDefinedGenericInner(ty, "Rc");
}

pub fn arcInnerType(ty: *const ast.Type) ?*ast.Type {
    return userDefinedGenericInner(ty, "Arc");
}

pub fn refCellInnerType(ty: *const ast.Type) ?*ast.Type {
    return userDefinedGenericInner(ty, "RefCell");
}

pub fn smartPointerType(ty: *const ast.Type) ?SmartPointerType {
    if (boxInnerType(ty)) |inner| return .{ .kind = .box, .inner = inner };
    if (rcInnerType(ty)) |inner| return .{ .kind = .rc, .inner = inner };
    if (arcInnerType(ty)) |inner| return .{ .kind = .arc, .inner = inner };
    if (refCellInnerType(ty)) |inner| return .{ .kind = .refcell, .inner = inner };
    return null;
}

pub fn smartPointerDerefType(ty: *const ast.Type) ?SmartPointerType {
    const smart = smartPointerType(ty) orelse return null;
    return switch (smart.kind) {
        .box, .rc, .arc => smart,
        .refcell => null,
    };
}

pub fn smartPointerReceiverNeedsLoad(ty: *const ast.Type) bool {
    return switch (ty.*) {
        .borrow, .pointer => smartPointerDerefType(ty) != null,
        else => false,
    };
}

pub fn smartPointerDerefNeedsValueSlot(inner_ty: *const ast.Type) bool {
    return smartPointerDerefType(inner_ty) != null;
}

pub fn smartPointerDerefIsDynBox(ty: *const ast.Type) bool {
    const inner = boxInnerType(ty) orelse return false;
    return dynTraitName(inner) != null;
}

pub const PrintPrimitiveFormat = enum {
    signed_int,
    unsigned_int,
    float,
    boolean,
};

pub const PrintlnArgPlan = union(enum) {
    format_string,
    string_like,
    borrowed_primitive: *const ast.Type,
    boxed_primitive: *const ast.Type,
    primitive: PrintPrimitiveFormat,
    unsupported,
};

pub fn borrowedPrimitiveType(ty: *const ast.Type) ?*const ast.Type {
    return switch (ty.*) {
        .borrow => |inner| if (inner.* == .primitive) inner else null,
        .pointer => |inner| if (inner.* == .primitive) inner else null,
        else => null,
    };
}

pub fn isStringLikeType(ty: *const ast.Type) bool {
    var curr = ty;
    while (true) {
        switch (curr.*) {
            .primitive => |p| return p == .void_type,
            .pointer => |p| curr = p,
            .borrow => |b| curr = b,
            .array => return true,
            .user_defined => |ud| return std.mem.eql(u8, ud.name, "String"),
            else => return false,
        }
    }
}

pub fn isFormatStringType(ty: *const ast.Type) bool {
    var curr = ty;
    while (true) {
        switch (curr.*) {
            .pointer => |p| curr = p,
            .borrow => |b| curr = b,
            .user_defined => |ud| return std.mem.eql(u8, ud.name, "String"),
            else => return false,
        }
    }
}

pub fn printPrimitiveFormat(ty: *const ast.Type) ?PrintPrimitiveFormat {
    return switch (ty.*) {
        .primitive => |p| switch (p) {
            .i8, .i16, .i32, .i64, .isize, .integer => .signed_int,
            .u8, .u16, .u32, .u64, .usize => .unsigned_int,
            .f32, .f64, .float => .float,
            .boolean => .boolean,
            else => null,
        },
        else => null,
    };
}

pub fn planPrintlnArg(ty: ?*const ast.Type) PrintlnArgPlan {
    const arg_ty = ty orelse return .unsupported;
    if (isFormatStringType(arg_ty)) return .format_string;
    if (isStringLikeType(arg_ty)) return .string_like;
    if (borrowedPrimitiveType(arg_ty)) |inner| return .{ .borrowed_primitive = inner };
    if (boxInnerType(arg_ty)) |inner| {
        if (printPrimitiveFormat(inner) != null) return .{ .boxed_primitive = inner };
    }
    if (printPrimitiveFormat(arg_ty)) |format| return .{ .primitive = format };
    return .unsupported;
}

/// Returns true when an associated-call rule (e.g. `Rc::clone`, `Arc::clone`)
/// expects its `value` argument to be the underlying smart-pointer value rather
/// than a `borrow` handle. The SA-text emitter treats `&rc1` as a transparent
/// register copy, but the SAB emitter would otherwise emit a real `borrow`
/// instruction that produces a separate handle and breaks the `RC_CLONE_OUT`
/// (or `ARC_CLONE_OUT`) macro expansion. Both emitters share this contract via
/// this helper so they materialize the receiver consistently.
pub fn associatedRuleNeedsUnderlyingSmartPointer(type_name: []const u8, member_name: []const u8) bool {
    if (!std.mem.eql(u8, member_name, "clone")) return false;
    return std.mem.eql(u8, type_name, "Rc") or std.mem.eql(u8, type_name, "Arc");
}

pub fn smartPointerDerefLoadsPointerBackedValue(inner_ty: *const ast.Type) bool {
    return switch (inner_ty.*) {
        .user_defined => smartPointerDerefType(inner_ty) == null,
        .tuple, .array => true,
        else => false,
    };
}

pub fn refCellPayloadIsPointer(ty: *const ast.Type) bool {
    return switch (ty.*) {
        .primitive => |p| p == .void_type,
        else => true,
    };
}

pub fn planRefCellBorrowCall(call: ast.CallExpr, receiver_ty: *const ast.Type) ?RefCellBorrowPlan {
    if (call.args.len != 1) return null;
    const inner = refCellInnerType(receiver_ty) orelse return null;
    if (std.mem.eql(u8, call.func_name, "borrow")) return .{ .kind = .shared, .inner = inner };
    if (std.mem.eql(u8, call.func_name, "borrow_mut")) return .{ .kind = .mutable, .inner = inner };
    return null;
}

fn closureLiteralArity(expr: *const ast.Node) ?usize {
    return switch (expr.*) {
        .closure_literal => |lit| lit.params.len,
        .move_expr => |move| closureLiteralArity(move.expr),
        else => null,
    };
}

pub fn planOptionClosureCall(call: ast.CallExpr, receiver_ty: *const ast.Type) ?OptionClosureCallPlan {
    if (call.args.len != 2) return null;
    if (optionInnerType(receiver_ty) == null) return null;
    const arity = closureLiteralArity(call.args[1]) orelse return null;
    if (std.mem.eql(u8, call.func_name, "map")) {
        if (arity != 1) return null;
        return .{ .kind = .map, .closure_arity = arity };
    }
    if (std.mem.eql(u8, call.func_name, "and_then")) {
        if (arity != 1) return null;
        return .{ .kind = .and_then, .closure_arity = arity };
    }
    if (std.mem.eql(u8, call.func_name, "unwrap_or_else")) {
        if (arity != 0) return null;
        return .{ .kind = .unwrap_or_else, .closure_arity = arity };
    }
    return null;
}

pub fn structAbiSize(decl: *const ast.StructDecl) usize {
    if (decl.is_opaque) return 1;
    if (decl.is_union) {
        var max_size: usize = 0;
        for (decl.fields) |field| max_size = @max(max_size, abiTypeSize(field.ty));
        return @max(max_size, 1);
    }
    var offset: usize = 0;
    for (decl.fields) |field| {
        const size = abiTypeSize(field.ty);
        offset = alignAggregateOffset(offset, size);
        offset += size;
    }
    return @max(offset, 1);
}

pub fn structFieldLayout(decl: *const ast.StructDecl, name: []const u8) ?AbiFieldLayout {
    if (decl.is_union) {
        for (decl.fields) |field| {
            if (std.mem.eql(u8, field.name, name)) {
                return .{ .offset = 0, .size = abiTypeSize(field.ty), .ty = field.ty };
            }
        }
        return null;
    }
    var offset: usize = 0;
    for (decl.fields) |field| {
        const size = abiTypeSize(field.ty);
        offset = alignAggregateOffset(offset, size);
        if (std.mem.eql(u8, field.name, name)) {
            return .{ .offset = offset, .size = size, .ty = field.ty };
        }
        offset += size;
    }
    return null;
}

/// Byte offset of an enum's payload region. The tag occupies the first 8
/// bytes (`i64`), so every variant's fields start at offset 8. Shared by both
/// emitters so SA-text and direct SAB agree on enum tag/payload layout.
pub const enum_tag_offset: usize = 0;
pub const enum_payload_offset: usize = 8;

/// Index (discriminant tag) of an enum variant by name.
pub fn enumVariantIndex(decl: *const ast.EnumDecl, name: []const u8) ?usize {
    for (decl.variants, 0..) |variant, i| {
        if (std.mem.eql(u8, variant.name, name)) return i;
    }
    return null;
}

/// The full enum variant record by name.
pub fn enumVariant(decl: *const ast.EnumDecl, name: []const u8) ?ast.EnumVariant {
    for (decl.variants) |variant| {
        if (std.mem.eql(u8, variant.name, name)) return variant;
    }
    return null;
}

/// Layout of a named field inside an enum variant's payload. Payload fields are
/// laid out starting at `enum_payload_offset`, using the same ABI size/align
/// rules as struct/tuple aggregates.
pub fn enumFieldLayout(variant: ast.EnumVariant, name: []const u8) ?AbiFieldLayout {
    var offset: usize = enum_payload_offset;
    for (variant.fields) |field| {
        const size = abiTypeSize(field.ty);
        offset = alignAggregateOffset(offset, size);
        if (std.mem.eql(u8, field.name, name)) {
            return .{ .offset = offset, .size = size, .ty = field.ty };
        }
        offset += size;
    }
    return null;
}

/// Total ABI size of an enum: the tag word plus the largest variant payload.
pub fn enumAbiSize(decl: *const ast.EnumDecl) usize {
    var max_payload: usize = 0;
    for (decl.variants) |variant| {
        var offset: usize = enum_payload_offset;
        for (variant.fields) |field| {
            const size = abiTypeSize(field.ty);
            offset = alignAggregateOffset(offset, size);
            offset += size;
        }
        max_payload = @max(max_payload, offset - enum_payload_offset);
    }
    return @max(enum_payload_offset + max_payload, enum_payload_offset);
}

/// The explicit value node for a named field in an enum literal, if present.
pub fn enumLiteralFieldValue(lit: *const ast.EnumLiteral, name: []const u8) ?*ast.Node {
    for (lit.fields) |field| {
        if (std.mem.eql(u8, field.name, name)) return field.value;
    }
    return null;
}

/// `Ordering` discriminant values (`struct Ordering { value: i64 }`), shared so
/// SA-text and direct SAB emit identical `<=>` results. These mirror the
/// `CMP_ORDERING_*` constants in `sa_std/core/cmp.sa`.
pub const ordering_less: i64 = -1;
pub const ordering_equal: i64 = 0;
pub const ordering_greater: i64 = 1;

pub fn isFloatType(ty: *const ast.Type) bool {
    return switch (ty.*) {
        .primitive => |p| switch (p) {
            .f32, .f64, .float => true,
            else => false,
        },
        else => false,
    };
}

pub fn isUnsignedIntegerType(ty: *const ast.Type) bool {
    return switch (ty.*) {
        .primitive => |p| switch (p) {
            .u8, .u16, .u32, .u64, .usize => true,
            else => false,
        },
        else => false,
    };
}

pub fn isNumericType(ty: *const ast.Type) bool {
    return switch (ty.*) {
        .primitive => |p| switch (p) {
            .i8, .i16, .i32, .i64, .isize, .u8, .u16, .u32, .u64, .usize, .integer, .f32, .f64, .float => true,
            else => false,
        },
        else => false,
    };
}

pub const SpaceshipOperandKind = enum {
    /// Numeric primitives compared directly into an Ordering.
    numeric,
    /// Same-struct lexicographic comparison over derived-`ord` fields.
    same_struct,
};

pub const SpaceshipPlan = struct {
    kind: SpaceshipOperandKind,
    /// For `.numeric`: whether the comparison is unsigned / float.
    is_unsigned: bool = false,
    is_float: bool = false,
    /// For `.same_struct`: the struct declaration whose fields are compared.
    struct_decl: ?*const ast.StructDecl = null,
};

/// Classify a `<=>` (spaceship) expression's operands into a shared plan so
/// both emitters agree on numeric vs. struct-lexicographic comparison and on
/// signedness/float selection. Returns null when the operand shape is not a
/// supported spaceship form (numeric-vs-numeric or same-struct-vs-same-struct).
pub fn planSpaceship(
    left_ty: *const ast.Type,
    right_ty: *const ast.Type,
    left_struct: ?*const ast.StructDecl,
    right_struct: ?*const ast.StructDecl,
) ?SpaceshipPlan {
    if (isNumericType(left_ty) and isNumericType(right_ty)) {
        return .{
            .kind = .numeric,
            .is_unsigned = isUnsignedIntegerType(left_ty),
            .is_float = isFloatType(left_ty),
        };
    }
    if (left_struct) |ls| {
        if (right_struct) |rs| {
            if (ls == rs and !ls.is_opaque and !ls.is_union) {
                return .{ .kind = .same_struct, .struct_decl = ls };
            }
        }
    }
    return null;
}

pub fn structLiteralExplicitValue(lit: *const ast.StructLiteral, name: []const u8) ?*ast.Node {
    for (lit.fields) |field| {
        if (std.mem.eql(u8, field.name, name)) return field.value;
    }
    return null;
}

pub fn planStructLiteralField(decl: *const ast.StructDecl, lit: *const ast.StructLiteral, field: ast.Field) ?StructLiteralFieldPlan {
    const layout = structFieldLayout(decl, field.name) orelse return null;
    if (structLiteralExplicitValue(lit, field.name)) |value| {
        return .{ .source = .explicit, .name = field.name, .value = value, .layout = layout, .field_ty = field.ty, .release_loaded = false };
    }
    if (lit.update_expr) |update_expr| {
        return .{ .source = .update, .name = field.name, .value = null, .layout = layout, .field_ty = field.ty, .release_loaded = callArgNeedsRelease(update_expr) };
    }
    return null;
}

/// Whether a struct field type is pointer-backed (heap-allocated aggregate,
/// slice, box, string buffer, nested struct, tuple, array). Such fields
/// cannot be safely shallow-copied through an update (`..base`) path without
/// a shared deep-copy/move plan, so direct SAB should fail explicitly rather
/// than emit an aliasing load/store.
pub fn structFieldIsPointerBacked(field_ty: *const ast.Type) bool {
    return switch (field_ty.*) {
        .primitive => |p| p == .void_type,
        .pointer, .borrow, .fn_ptr, .user_defined, .tuple, .array => true,
        else => true,
    };
}

pub fn planStructLiteralFieldTransfer(plan: StructLiteralFieldPlan, field_is_copy_struct: bool) StructLiteralFieldTransfer {
    return switch (plan.source) {
        .explicit => blk: {
            const value = plan.value orelse break :blk .direct;
            if (value.* == .identifier and field_is_copy_struct) break :blk .deep_copy;
            break :blk .direct;
        },
        .update => blk: {
            if (!structFieldIsPointerBacked(plan.field_ty)) break :blk .direct;
            if (field_is_copy_struct) break :blk .deep_copy;
            break :blk .move;
        },
    };
}

pub fn mangleMethodName(allocator: std.mem.Allocator, ty_name: []const u8, method_name: []const u8) ![]u8 {
    return try std.fmt.allocPrint(allocator, "{s}_{s}", .{ ty_name, method_name });
}

pub fn mangleTraitMethodName(allocator: std.mem.Allocator, ty_name: []const u8, trait_name: []const u8, method_name: []const u8) ![]u8 {
    return try std.fmt.allocPrint(allocator, "{s}__{s}_{s}", .{ ty_name, trait_name, method_name });
}

pub fn concreteTypeName(ty: *const ast.Type) ?[]const u8 {
    var curr = ty;
    while (true) {
        switch (curr.*) {
            .borrow => |b| curr = b,
            .pointer => |p| curr = p,
            .user_defined => |ud| return ud.name,
            else => return null,
        }
    }
}

pub fn dynTraitName(ty: *const ast.Type) ?[]const u8 {
    var curr = ty;
    while (true) {
        switch (curr.*) {
            .borrow => |b| curr = b,
            .pointer => |p| curr = p,
            .user_defined => |ud| {
                if (std.mem.startsWith(u8, ud.name, "__dyn_")) return ud.name["__dyn_".len..];
                return null;
            },
            else => return null,
        }
    }
}

pub fn vtableName(allocator: std.mem.Allocator, trait_name: []const u8, type_name: []const u8) ![]u8 {
    return try std.fmt.allocPrint(allocator, "VT_{s}_{s}", .{ type_name, trait_name });
}

pub fn dynVtableUpcastName(allocator: std.mem.Allocator, from_trait: []const u8, to_trait: []const u8) ![]u8 {
    return try std.fmt.allocPrint(allocator, "VT_DYN_{s}_TO_{s}", .{ from_trait, to_trait });
}

pub fn traitMethodCount(tc: *type_checker.TypeChecker, trait_name: []const u8) ?usize {
    const trait_decl = tc.traits.get(trait_name) orelse return null;
    var count: usize = 0;
    for (trait_decl.supertraits) |supertrait| {
        count += traitMethodCount(tc, supertrait) orelse return null;
    }
    count += trait_decl.methods.len;
    return count;
}

pub fn dynMethodSlot(tc: *type_checker.TypeChecker, trait_name: []const u8, method_name: []const u8) ?usize {
    const trait_decl = tc.traits.get(trait_name) orelse return null;
    var base: usize = 0;
    for (trait_decl.supertraits) |supertrait| {
        if (dynMethodSlot(tc, supertrait, method_name)) |slot| return base + slot;
        base += (traitMethodCount(tc, supertrait) orelse return null) * 8;
    }
    for (trait_decl.methods, 0..) |method, i| {
        if (std.mem.eql(u8, method.name, method_name)) return base + i * 8;
    }
    return null;
}

pub fn planResolvedStaticCall(tc: *type_checker.TypeChecker, expr: *const ast.Node, call: ast.CallExpr) ?StaticCallPlan {
    const symbol = tc.resolved_call_symbols.get(expr) orelse return null;
    return .{ .target_symbol = symbol, .arg_count = call.args.len };
}

pub fn planStaticCall(tc: *type_checker.TypeChecker, expr: *const ast.Node, call: ast.CallExpr) ?StaticCallPlan {
    if (planResolvedStaticCall(tc, expr, call)) |plan| return plan;
    if (call.associated_target == null) return .{ .target_symbol = call.func_name, .arg_count = call.args.len };
    return null;
}

pub fn resolveStaticCallSymbol(tc: *type_checker.TypeChecker, expr: *const ast.Node, call: ast.CallExpr) ?[]const u8 {
    const plan = planStaticCall(tc, expr, call) orelse return null;
    return plan.target_symbol;
}

pub fn callArgPrefix(arg: *const ast.Node) ?u8 {
    return switch (arg.*) {
        .borrow_expr => '&',
        .move_expr => '^',
        else => null,
    };
}

pub fn prefixedIdentifierCallArg(arg: *const ast.Node) ?PrefixedIdentifierArg {
    const prefix = callArgPrefix(arg) orelse return null;
    const inner = switch (arg.*) {
        .borrow_expr => arg.borrow_expr.expr,
        .move_expr => arg.move_expr.expr,
        else => return null,
    };
    if (inner.* != .identifier) return null;
    return .{ .prefix = prefix, .name = inner.identifier };
}

pub fn callArgNeedsRelease(arg: *const ast.Node) bool {
    return switch (arg.*) {
        .literal => |lit| lit != .string_val,
        .identifier => false,
        .field_expr => true,
        .index_expr => true,
        .borrow_expr => true,
        .move_expr => |move| exprResultNeedsRelease(move.expr),
        .deref_expr => true,
        .cast_expr => false,
        else => true,
    };
}

pub fn exprResultNeedsRelease(expr: *const ast.Node) bool {
    return switch (expr.*) {
        .literal => |lit| lit != .string_val,
        .identifier => false,
        .field_expr => true,
        .index_expr => true,
        .borrow_expr => true,
        .deref_expr => true,
        .cast_expr => false,
        else => true,
    };
}

pub fn rootIdentifier(expr: *const ast.Node) ?[]const u8 {
    return switch (expr.*) {
        .identifier => |name| name,
        .field_expr => |field| rootIdentifier(field.expr),
        .index_expr => |idx| rootIdentifier(idx.target),
        else => null,
    };
}

pub fn isBorrowLikeType(ty: *const ast.Type) bool {
    return switch (ty.*) {
        .borrow => true,
        .primitive => |p| p == .void_type,
        else => false,
    };
}

pub fn storedValueMovesIdentifier(value: *const ast.Node, value_ty: *const ast.Type, value_is_copy: bool) ?[]const u8 {
    if (value.* != .identifier) return null;
    if (value_is_copy or isBorrowLikeType(value_ty)) return null;
    return value.identifier;
}

pub fn assignmentMovesIdentifier(
    target: *const ast.Node,
    value: *const ast.Node,
    value_ty: *const ast.Type,
    value_is_copy: bool,
) ?[]const u8 {
    const value_name = storedValueMovesIdentifier(value, value_ty, value_is_copy) orelse return null;
    if (rootIdentifier(target)) |target_name| {
        if (std.mem.eql(u8, target_name, value_name)) return null;
    }
    return value_name;
}

pub fn shouldAutoBorrowResolvedArg(
    param: ast.Param,
    arg: *const ast.Node,
    arg_ty: *const ast.Type,
    arg_index: usize,
    auto_borrow_receiver: bool,
) bool {
    if (!param.is_borrow or arg.* == .borrow_expr) return false;
    return (auto_borrow_receiver and arg_index == 0) or arg_ty.* == .borrow;
}

pub fn shouldAutoBorrowReceiverArg(param: ast.Param, arg: *const ast.Node, arg_ty: *const ast.Type) bool {
    if (!param.is_borrow) return false;
    if (arg_ty.* == .borrow) return true;
    return arg.* != .borrow_expr;
}

pub fn shouldAutoBorrowStatementReceiverArg(param: ast.Param, arg: *const ast.Node, arg_ty: *const ast.Type) bool {
    if (!param.is_borrow or arg.* == .borrow_expr) return false;
    return arg_ty.* != .borrow;
}

pub fn planCallArgMaterialization(arg: *const ast.Node, input: CallArgMaterializationInput) CallArgMaterializationPlan {
    if (input.array_to_slice_borrow) {
        return .{ .kind = .array_to_slice_borrow, .release_after_call = callArgNeedsRelease(arg) };
    }
    if (input.dyn_borrow_trait_name) |trait_name| {
        return .{ .kind = .dyn_borrow, .release_after_call = false, .dyn_borrow_trait_name = trait_name };
    }
    if (input.param) |param| {
        if (input.arg_ty) |arg_ty| {
            if (input.statement_receiver_auto_borrow) {
                if (shouldAutoBorrowStatementReceiverArg(param, arg, arg_ty)) {
                    return .{ .kind = .auto_borrow, .release_after_call = input.generated_scalar_const_identifier };
                }
            } else if (input.receiver_style_auto_borrow) {
                if (shouldAutoBorrowReceiverArg(param, arg, arg_ty)) {
                    return .{ .kind = .auto_borrow, .release_after_call = input.generated_scalar_const_identifier };
                }
            } else if (shouldAutoBorrowResolvedArg(param, arg, arg_ty, input.arg_index, input.auto_borrow_receiver)) {
                return .{ .kind = .auto_borrow, .release_after_call = input.generated_scalar_const_identifier };
            }
        }
    }
    if (input.copy_struct_value) {
        return .{ .kind = .copy_struct_value, .release_after_call = true };
    }
    return .{
        .kind = .value,
        .release_after_call = callArgNeedsRelease(arg) or
            input.generated_fn_ptr_identifier or
            input.generated_scalar_const_identifier,
    };
}

test "shared lowering rules normalize derives and call argument prefixes" {
    const derives = [_][]const u8{ "PartialEq", "Hash" };
    const decl = ast.StructDecl{
        .name = "Thing",
        .derives = derives[0..],
        .generics = &.{},
        .fields = &.{},
    };

    try std.testing.expect(structHasDerive(&decl, "eq"));
    try std.testing.expect(structHasDerive(&decl, "HASH"));
    try std.testing.expect(!structHasDerive(&decl, "debug"));

    var value = ast.Node{ .identifier = "value" };
    var borrowed = ast.Node{ .borrow_expr = .{ .expr = &value } };
    var moved = ast.Node{ .move_expr = .{ .expr = &value } };

    try std.testing.expectEqual(@as(?u8, null), callArgPrefix(&value));
    try std.testing.expectEqual(@as(?u8, '&'), callArgPrefix(&borrowed));
    try std.testing.expectEqual(@as(?u8, '^'), callArgPrefix(&moved));

    const borrowed_ident = prefixedIdentifierCallArg(&borrowed) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(u8, '&'), borrowed_ident.prefix);
    try std.testing.expectEqualSlices(u8, "value", borrowed_ident.name);
    const moved_ident = prefixedIdentifierCallArg(&moved) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(u8, '^'), moved_ident.prefix);
    try std.testing.expectEqualSlices(u8, "value", moved_ident.name);
}

test "shared loop control plan detects only current loop jumps" {
    var zero = ast.Node{ .literal = .{ .int_val = 0 } };
    var one = ast.Node{ .literal = .{ .int_val = 1 } };
    var cond = ast.Node{ .literal = .{ .bool_val = true } };
    var current_break = ast.Node{ .break_stmt = .{} };
    var current_continue = ast.Node{ .continue_stmt = .{} };
    var nested_break = ast.Node{ .break_stmt = .{} };

    const if_then = [_]*ast.Node{&current_break};
    var if_expr = ast.Node{ .if_expr = .{ .cond = &cond, .then_block = if_then[0..], .else_block = null } };
    var if_stmt = ast.Node{ .expr_stmt = &if_expr };
    const nested_body = [_]*ast.Node{&nested_break};
    var nested_for = ast.Node{ .for_stmt = .{ .var_name = "j", .start = &zero, .end = &one, .body = nested_body[0..] } };
    const body = [_]*ast.Node{ &if_stmt, &current_continue, &nested_for };

    const plan = planLoopControl(body[0..]);
    try std.testing.expect(plan.has_break);
    try std.testing.expect(plan.has_continue);

    const nested_only = [_]*ast.Node{&nested_for};
    const nested_plan = planLoopControl(nested_only[0..]);
    try std.testing.expect(!nested_plan.has_break);
    try std.testing.expect(!nested_plan.has_continue);
}

test "shared lowering rules classify call materialization decisions" {
    var value = ast.Node{ .identifier = "value" };
    var field = ast.Node{ .field_expr = .{ .expr = &value, .field_name = "field" } };
    var borrowed_value = ast.Node{ .borrow_expr = .{ .expr = &value } };
    var borrowed_field = ast.Node{ .borrow_expr = .{ .expr = &field } };
    var cast_ty = ast.Type{ .primitive = .i64 };
    var cast_value = ast.Node{ .cast_expr = .{ .expr = &value, .ty = &cast_ty } };

    try std.testing.expect(!callArgNeedsRelease(&value));
    try std.testing.expect(callArgNeedsRelease(&field));
    try std.testing.expect(callArgNeedsRelease(&borrowed_value));
    try std.testing.expect(callArgNeedsRelease(&borrowed_field));
    try std.testing.expect(!callArgNeedsRelease(&cast_value));
    try std.testing.expect(!exprResultNeedsRelease(&value));
    try std.testing.expect(exprResultNeedsRelease(&field));
    try std.testing.expect(exprResultNeedsRelease(&borrowed_value));

    var boxed_ty = ast.Type{ .user_defined = .{ .name = "Boxed", .generics = &.{} } };
    var primitive_ty = ast.Type{ .primitive = .i32 };
    var borrow_boxed_ty = ast.Type{ .borrow = &boxed_ty };
    var target = ast.Node{ .identifier = "target" };
    var source = ast.Node{ .identifier = "source" };
    var same_target = ast.Node{ .identifier = "source" };
    var target_field = ast.Node{ .field_expr = .{ .expr = &target, .field_name = "field" } };

    const moved_to_identifier = assignmentMovesIdentifier(&target, &source, &boxed_ty, false) orelse return error.TestExpectedEqual;
    try std.testing.expectEqualSlices(u8, "source", moved_to_identifier);
    const moved_to_field = assignmentMovesIdentifier(&target_field, &source, &boxed_ty, false) orelse return error.TestExpectedEqual;
    try std.testing.expectEqualSlices(u8, "source", moved_to_field);
    try std.testing.expect(assignmentMovesIdentifier(&same_target, &source, &boxed_ty, false) == null);
    try std.testing.expect(assignmentMovesIdentifier(&target, &source, &primitive_ty, true) == null);
    try std.testing.expect(assignmentMovesIdentifier(&target, &source, &borrow_boxed_ty, false) == null);
    try std.testing.expect(assignmentMovesIdentifier(&target, &field, &boxed_ty, false) == null);

    var i64_ty = ast.Type{ .primitive = .i64 };
    var borrow_i64_ty = ast.Type{ .borrow = &i64_ty };
    const borrow_param = ast.Param{ .name = "self", .ty = &i64_ty, .is_borrow = true };
    const plain_param = ast.Param{ .name = "value", .ty = &i64_ty };

    try std.testing.expect(shouldAutoBorrowResolvedArg(borrow_param, &value, &i64_ty, 0, true));
    try std.testing.expect(!shouldAutoBorrowResolvedArg(borrow_param, &value, &i64_ty, 1, true));
    try std.testing.expect(shouldAutoBorrowResolvedArg(borrow_param, &value, &borrow_i64_ty, 1, false));
    try std.testing.expect(!shouldAutoBorrowResolvedArg(plain_param, &value, &i64_ty, 0, true));

    try std.testing.expect(shouldAutoBorrowReceiverArg(borrow_param, &value, &i64_ty));
    try std.testing.expect(shouldAutoBorrowReceiverArg(borrow_param, &value, &borrow_i64_ty));
    try std.testing.expect(!shouldAutoBorrowReceiverArg(plain_param, &value, &i64_ty));
    try std.testing.expect(shouldAutoBorrowStatementReceiverArg(borrow_param, &value, &i64_ty));
    try std.testing.expect(!shouldAutoBorrowStatementReceiverArg(borrow_param, &value, &borrow_i64_ty));
    try std.testing.expect(!shouldAutoBorrowStatementReceiverArg(plain_param, &value, &i64_ty));

    const array_plan = planCallArgMaterialization(&field, .{ .array_to_slice_borrow = true });
    try std.testing.expectEqual(CallArgMaterializationKind.array_to_slice_borrow, array_plan.kind);
    try std.testing.expect(array_plan.release_after_call);

    const dyn_plan = planCallArgMaterialization(&value, .{ .dyn_borrow_trait_name = "Drawable" });
    try std.testing.expectEqual(CallArgMaterializationKind.dyn_borrow, dyn_plan.kind);
    try std.testing.expect(!dyn_plan.release_after_call);
    try std.testing.expectEqualSlices(u8, "Drawable", dyn_plan.dyn_borrow_trait_name.?);

    const auto_borrow_plan = planCallArgMaterialization(&value, .{
        .param = borrow_param,
        .arg_ty = &i64_ty,
        .arg_index = 0,
        .auto_borrow_receiver = true,
    });
    try std.testing.expectEqual(CallArgMaterializationKind.auto_borrow, auto_borrow_plan.kind);
    try std.testing.expect(!auto_borrow_plan.release_after_call);

    const generated_auto_borrow_plan = planCallArgMaterialization(&value, .{
        .param = borrow_param,
        .arg_ty = &i64_ty,
        .arg_index = 0,
        .auto_borrow_receiver = true,
        .generated_scalar_const_identifier = true,
    });
    try std.testing.expectEqual(CallArgMaterializationKind.auto_borrow, generated_auto_borrow_plan.kind);
    try std.testing.expect(generated_auto_borrow_plan.release_after_call);

    const receiver_style_plan = planCallArgMaterialization(&value, .{
        .param = borrow_param,
        .arg_ty = &i64_ty,
        .receiver_style_auto_borrow = true,
    });
    try std.testing.expectEqual(CallArgMaterializationKind.auto_borrow, receiver_style_plan.kind);

    const statement_receiver_plan = planCallArgMaterialization(&value, .{
        .param = borrow_param,
        .arg_ty = &borrow_i64_ty,
        .statement_receiver_auto_borrow = true,
    });
    try std.testing.expectEqual(CallArgMaterializationKind.value, statement_receiver_plan.kind);

    const copy_plan = planCallArgMaterialization(&value, .{ .copy_struct_value = true });
    try std.testing.expectEqual(CallArgMaterializationKind.copy_struct_value, copy_plan.kind);
    try std.testing.expect(copy_plan.release_after_call);

    const generated_plan = planCallArgMaterialization(&value, .{ .generated_fn_ptr_identifier = true });
    try std.testing.expectEqual(CallArgMaterializationKind.value, generated_plan.kind);
    try std.testing.expect(generated_plan.release_after_call);
}

test "shared ABI layout keeps fixed-array fields as pointer slots" {
    var bool_ty = ast.Type{ .primitive = .boolean };
    var i32_ty = ast.Type{ .primitive = .i32 };
    var bool_array_ty = ast.Type{ .array = .{ .elem = &bool_ty, .len = 2 } };
    var i32_array_ty = ast.Type{ .array = .{ .elem = &i32_ty, .len = 2 } };
    const fields = [_]ast.Field{
        .{ .name = "active", .ty = &bool_array_ty },
        .{ .name = "values", .ty = &i32_array_ty },
    };
    const decl = ast.StructDecl{
        .name = "Bag",
        .generics = &.{},
        .fields = fields[0..],
    };

    try std.testing.expectEqual(@as(usize, 8), abiTypeSize(&bool_array_ty));
    try std.testing.expectEqual(@as(usize, 2), inlineArraySize(bool_array_ty.array));
    try std.testing.expectEqual(@as(usize, 16), structAbiSize(&decl));
    try std.testing.expectEqual(@as(usize, 16), SliceAbi.size);
    try std.testing.expectEqual(@as(usize, 0), SliceAbi.ptr_offset);
    try std.testing.expectEqual(@as(usize, 8), SliceAbi.len_offset);
    try std.testing.expectEqual(@as(?usize, 1), arrayRestLen(bool_array_ty.array, 1));
    try std.testing.expectEqual(@as(?usize, null), arrayRestLen(bool_array_ty.array, 3));

    const active = structFieldLayout(&decl, "active") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(usize, 0), active.offset);
    try std.testing.expectEqual(@as(usize, 8), active.size);
    const values = structFieldLayout(&decl, "values") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(usize, 8), values.offset);
    try std.testing.expectEqual(@as(usize, 8), values.size);

    const elem = arrayElementLayout(bool_array_ty.array, 1) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(usize, 1), elem.offset);
    try std.testing.expectEqual(@as(usize, 1), elem.size);
}

test "shared ABI treats ready futures as pointer-backed values" {
    var i32_ty = ast.Type{ .primitive = .i32 };
    var future_ty = ast.Type{ .future = &i32_ty };

    try std.testing.expectEqual(@as(usize, 8), abiTypeSize(&future_ty));
    try std.testing.expect(abiPassesAsPointer(&future_ty));
}

test "shared struct literal update field plan" {
    var i32_ty = ast.Type{ .primitive = .i32 };
    const fields = [_]ast.Field{
        .{ .name = "x", .ty = &i32_ty },
        .{ .name = "y", .ty = &i32_ty },
    };
    const decl = ast.StructDecl{
        .name = "Point",
        .generics = &.{},
        .fields = fields[0..],
    };
    var x_value = ast.Node{ .identifier = "new_x" };
    var base_value = ast.Node{ .identifier = "old" };
    const literal_fields = [_]ast.StructLiteralField{.{ .name = "x", .value = &x_value }};
    const lit = ast.StructLiteral{
        .ty = undefined,
        .fields = literal_fields[0..],
        .update_expr = &base_value,
    };

    const x_plan = planStructLiteralField(&decl, &lit, fields[0]) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(StructLiteralFieldSource.explicit, x_plan.source);
    try std.testing.expect(x_plan.value.? == &x_value);
    try std.testing.expectEqual(@as(usize, 0), x_plan.layout.offset);
    try std.testing.expect(x_plan.field_ty == &i32_ty);
    try std.testing.expect(!x_plan.release_loaded);

    const y_plan = planStructLiteralField(&decl, &lit, fields[1]) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(StructLiteralFieldSource.update, y_plan.source);
    try std.testing.expect(y_plan.value == null);
    try std.testing.expectEqual(@as(usize, 4), y_plan.layout.offset);
    try std.testing.expect(y_plan.field_ty == &i32_ty);
    // identifier-backed update source is not released (move-by-reuse).
    try std.testing.expect(!y_plan.release_loaded);
    // i32 is a primitive scalar, not pointer-backed.
    try std.testing.expect(!structFieldIsPointerBacked(&i32_ty));
    try std.testing.expectEqual(StructLiteralFieldTransfer.direct, planStructLiteralFieldTransfer(y_plan, false));

    var nested_ty = ast.Type{ .user_defined = .{ .name = "Nested", .generics = &.{} } };
    const nested_fields = [_]ast.Field{.{ .name = "payload", .ty = &nested_ty }};
    const nested_decl = ast.StructDecl{
        .name = "HasNested",
        .generics = &.{},
        .fields = nested_fields[0..],
    };
    const nested_lit = ast.StructLiteral{
        .ty = undefined,
        .fields = &.{},
        .update_expr = &base_value,
    };
    const nested_plan = planStructLiteralField(&nested_decl, &nested_lit, nested_fields[0]) orelse return error.TestExpectedEqual;
    try std.testing.expect(structFieldIsPointerBacked(nested_plan.field_ty));
    try std.testing.expectEqual(StructLiteralFieldTransfer.move, planStructLiteralFieldTransfer(nested_plan, false));
    try std.testing.expectEqual(StructLiteralFieldTransfer.deep_copy, planStructLiteralFieldTransfer(nested_plan, true));
}

test "shared enum tag/payload layout" {
    var i32_ty = ast.Type{ .primitive = .i32 };
    var i64_ty = ast.Type{ .primitive = .i64 };
    const move_fields = [_]ast.Field{
        .{ .name = "x", .ty = &i32_ty },
        .{ .name = "y", .ty = &i64_ty },
    };
    const variants = [_]ast.EnumVariant{
        .{ .name = "Quit", .fields = &.{} },
        .{ .name = "Move", .fields = move_fields[0..] },
    };
    const decl = ast.EnumDecl{
        .name = "Message",
        .generics = &.{},
        .variants = variants[0..],
    };

    // Discriminant tags are assigned by declaration order.
    try std.testing.expectEqual(@as(usize, 0), enumVariantIndex(&decl, "Quit").?);
    try std.testing.expectEqual(@as(usize, 1), enumVariantIndex(&decl, "Move").?);
    try std.testing.expectEqual(@as(?usize, null), enumVariantIndex(&decl, "Nope"));

    const move = enumVariant(&decl, "Move").?;
    // Payload starts at offset 8 (after the i64 tag word). `x:i32` at 8,
    // `y:i64` aligned to the next 8-byte boundary at 16.
    const x_layout = enumFieldLayout(move, "x").?;
    try std.testing.expectEqual(@as(usize, 8), x_layout.offset);
    const y_layout = enumFieldLayout(move, "y").?;
    try std.testing.expectEqual(@as(usize, 16), y_layout.offset);

    // Total size = tag word + largest variant payload (Move: through y at 16+8=24).
    try std.testing.expectEqual(@as(usize, 24), enumAbiSize(&decl));
}

test "shared while let pattern classification" {
    const some_bindings = [_][]const u8{"value"};
    const some = ast.EnumPattern{ .enum_name = "Option", .variant_name = "Some", .bindings = some_bindings[0..] };
    const some_plan = planWhileLetPattern(some, false).?;
    try std.testing.expectEqual(WhileLetPatternKind.option_some, some_plan.kind);
    try std.testing.expect(some_plan.success_on_true);
    try std.testing.expect(some_plan.bindsPayload());

    const none = ast.EnumPattern{ .enum_name = "Option", .variant_name = "None", .bindings = &.{} };
    const none_plan = planWhileLetPattern(none, false).?;
    try std.testing.expectEqual(WhileLetPatternKind.option_none, none_plan.kind);
    try std.testing.expect(!none_plan.success_on_true);
    try std.testing.expect(!none_plan.bindsPayload());

    const err_bindings = [_][]const u8{"err"};
    const err = ast.EnumPattern{ .enum_name = "Result", .variant_name = "Err", .bindings = err_bindings[0..] };
    const err_plan = planWhileLetPattern(err, false).?;
    try std.testing.expectEqual(WhileLetPatternKind.result_err, err_plan.kind);
    try std.testing.expect(!err_plan.success_on_true);
    try std.testing.expect(err_plan.bindsPayload());

    const message = ast.EnumPattern{ .enum_name = "Message", .variant_name = "Move", .bindings = &.{} };
    const enum_plan = planWhileLetPattern(message, true).?;
    try std.testing.expectEqual(WhileLetPatternKind.enum_variant, enum_plan.kind);
    try std.testing.expect(enum_plan.success_on_true);
}

test "shared executor task buffer classification" {
    var i32_ty = ast.Type{ .primitive = .i32 };
    const task_generics = [_]*ast.Type{&i32_ty};
    var task_ty = ast.Type{ .user_defined = .{ .name = "Task", .generics = task_generics[0..] } };

    var array_ty = ast.Type{ .array = .{ .elem = &task_ty, .len = 3 } };
    const array_plan = executorTaskBufferPlan(&array_ty).?;
    try std.testing.expectEqual(ExecutorTaskBufferKind.fixed_array, array_plan.kind);
    try std.testing.expectEqual(@as(?usize, 3), array_plan.fixed_len);
    try std.testing.expect(array_plan.inner == &i32_ty);

    const vec_generics = [_]*ast.Type{&task_ty};
    var vec_ty = ast.Type{ .user_defined = .{ .name = "Vec", .generics = vec_generics[0..] } };
    const vec_plan = executorTaskBufferPlan(&vec_ty).?;
    try std.testing.expectEqual(ExecutorTaskBufferKind.vec, vec_plan.kind);
    try std.testing.expectEqual(@as(?usize, null), vec_plan.fixed_len);
    try std.testing.expect(vec_plan.inner == &i32_ty);
}

test "shared future runtime call classification" {
    var value_node = ast.Node{ .literal = .{ .int_val = 1 } };
    const args = [_]*ast.Node{&value_node};
    const ready = ast.CallExpr{ .func_name = "ready", .associated_target = "future", .generics = &.{}, .args = args[0..] };
    try std.testing.expectEqual(FutureRuntimeCallKind.ready, planFutureRuntimeCall(ready).?.kind);

    var i32_ty = ast.Type{ .primitive = .i32 };
    const generics = [_]*ast.Type{&i32_ty};
    const pending = ast.CallExpr{ .func_name = "pending", .associated_target = "future", .generics = generics[0..], .args = &.{} };
    try std.testing.expectEqual(FutureRuntimeCallKind.pending, planFutureRuntimeCall(pending).?.kind);

    const flat_pending = ast.CallExpr{ .func_name = "future__pending", .generics = generics[0..], .args = &.{} };
    try std.testing.expectEqual(FutureRuntimeCallKind.pending, planFutureRuntimeCall(flat_pending).?.kind);

    const defer_ready = ast.CallExpr{ .func_name = "defer_ready", .associated_target = "future", .generics = &.{}, .args = args[0..] };
    try std.testing.expectEqual(FutureRuntimeCallKind.defer_ready, planFutureRuntimeCall(defer_ready).?.kind);
    var defer_ready_node = ast.Node{ .call_expr = defer_ready };
    try std.testing.expectEqual(FutureReadiness.unknown, exprFutureReadiness(&defer_ready_node, null));

    const flat_defer_ready = ast.CallExpr{ .func_name = "future__defer_ready", .generics = &.{}, .args = args[0..] };
    try std.testing.expectEqual(FutureRuntimeCallKind.defer_ready, planFutureRuntimeCall(flat_defer_ready).?.kind);

    const join_args = [_]*ast.Node{ &value_node, &value_node };
    const join2 = ast.CallExpr{ .func_name = "join2", .associated_target = "future", .generics = &.{}, .args = join_args[0..] };
    try std.testing.expectEqual(FutureRuntimeCallKind.join2, planFutureRuntimeCall(join2).?.kind);

    var ready_left = ast.Node{ .call_expr = ready };
    var ready_right = ast.Node{ .call_expr = ready };
    const ready_join_args = [_]*ast.Node{ &ready_left, &ready_right };
    var ready_join = ast.Node{ .call_expr = .{ .func_name = "join2", .associated_target = "future", .generics = &.{}, .args = ready_join_args[0..] } };
    var pair_ty = ast.Type{ .user_defined = .{ .name = "FuturePair", .generics = &.{} } };
    var pair_future_ty = ast.Type{ .future = &pair_ty };
    const ready_join_await_plan = planAwaitFuture(&ready_join, &pair_future_ty, null);
    try std.testing.expect(ready_join_await_plan.poll_once_if_statically_ready);

    var readiness = std.StringHashMap(FutureReadiness).init(std.testing.allocator);
    defer readiness.deinit();
    try readiness.put("left", .ready);
    try readiness.put("right", .ready);
    var left_ident = ast.Node{ .identifier = "left" };
    var right_ident = ast.Node{ .identifier = "right" };
    const local_join_args = [_]*ast.Node{ &left_ident, &right_ident };
    var local_join = ast.Node{ .call_expr = .{ .func_name = "join2", .associated_target = "future", .generics = &.{}, .args = local_join_args[0..] } };
    const local_join_await_plan = planAwaitFutureWithReadiness(&local_join, &pair_future_ty, null, &readiness);
    try std.testing.expect(local_join_await_plan.poll_once_if_statically_ready);

    try readiness.put("right", .pending);
    const local_pending_join_await_plan = planAwaitFutureWithReadiness(&local_join, &pair_future_ty, null, &readiness);
    try std.testing.expect(local_pending_join_await_plan.pending_return_if_async);
    try std.testing.expect(!local_pending_join_await_plan.poll_once_if_statically_ready);

    var pending_node = ast.Node{ .call_expr = pending };
    const pending_await_plan = planAwaitFuture(&pending_node, &i32_ty, null);
    try std.testing.expect(pending_await_plan.ready_state_inner);
    try std.testing.expect(pending_await_plan.pending_return_if_async);

    const pair_left = ast.CallExpr{ .func_name = "pair_left", .associated_target = "future", .generics = &.{}, .args = args[0..] };
    try std.testing.expectEqual(FutureRuntimeCallKind.pair_left, planFutureRuntimeCall(pair_left).?.kind);

    const select2 = ast.CallExpr{ .func_name = "select2", .associated_target = "future", .generics = &.{}, .args = join_args[0..] };
    try std.testing.expectEqual(FutureRuntimeCallKind.select2, planFutureRuntimeCall(select2).?.kind);

    const either_right = ast.CallExpr{ .func_name = "either_right", .associated_target = "future", .generics = &.{}, .args = args[0..] };
    try std.testing.expectEqual(FutureRuntimeCallKind.either_right, planFutureRuntimeCall(either_right).?.kind);

    const state = ast.CallExpr{ .func_name = "state", .associated_target = "task", .generics = &.{}, .args = args[0..] };
    try std.testing.expectEqual(TaskRuntimeCallKind.state, planTaskRuntimeCall(state).?.kind);

    const executor_new = ast.CallExpr{ .func_name = "new", .associated_target = "executor", .generics = &.{}, .args = args[0..] };
    try std.testing.expectEqual(ExecutorRuntimeCallKind.new, planExecutorRuntimeCall(executor_new).?.kind);

    const executor_poll_one = ast.CallExpr{ .func_name = "poll_one", .associated_target = "executor", .generics = &.{}, .args = args[0..] };
    try std.testing.expectEqual(ExecutorRuntimeCallKind.poll_one, planExecutorRuntimeCall(executor_poll_one).?.kind);

    const poll_ready = ast.CallExpr{ .func_name = "ready", .associated_target = "poll", .generics = &.{}, .args = args[0..] };
    try std.testing.expectEqual(PollRuntimeCallKind.ready, planPollRuntimeCall(poll_ready).?.kind);

    const poll_pending = ast.CallExpr{ .func_name = "pending", .associated_target = "poll", .generics = generics[0..], .args = &.{} };
    try std.testing.expectEqual(PollRuntimeCallKind.pending, planPollRuntimeCall(poll_pending).?.kind);

    const flat_poll_pending = ast.CallExpr{ .func_name = "poll__pending", .generics = generics[0..], .args = &.{} };
    try std.testing.expectEqual(PollRuntimeCallKind.pending, planPollRuntimeCall(flat_poll_pending).?.kind);

    const poll_value = ast.CallExpr{ .func_name = "value", .associated_target = "poll", .generics = &.{}, .args = args[0..] };
    try std.testing.expectEqual(PollRuntimeCallKind.value, planPollRuntimeCall(poll_value).?.kind);
}

test "shared async single await continuation plan is defer-ready only" {
    var i32_ty = ast.Type{ .primitive = .i32 };
    var value_node = ast.Node{ .literal = .{ .int_val = 41 } };
    const args = [_]*ast.Node{&value_node};
    var defer_call = ast.Node{ .call_expr = .{ .func_name = "defer_ready", .associated_target = "future", .generics = &.{}, .args = args[0..] } };
    var await_node = ast.Node{ .await_expr = .{ .expr = &defer_call } };
    var let_node = ast.Node{ .let_stmt = .{ .name = "value", .ty = null, .value = &await_node } };
    var ident_node = ast.Node{ .identifier = "value" };
    var addend_node = ast.Node{ .literal = .{ .int_val = 1 } };
    var return_expr = ast.Node{ .binary_expr = .{ .left = &ident_node, .op = .add, .right = &addend_node } };
    var return_node = ast.Node{ .return_stmt = .{ .value = &return_expr } };
    const body = [_]*ast.Node{ &let_node, &return_node };
    const func = ast.FuncDecl{ .name = "await_defer", .generics = &.{}, .params = &.{}, .ret_ty = &i32_ty, .body = body[0..], .is_inline = false, .is_async = true };

    const plan = planAsyncSingleAwaitContinuation(&func) orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("value", plan.binding_name);
    try std.testing.expectEqual(FutureRuntimeCallKind.defer_ready, plan.awaited_kind);
    try std.testing.expectEqual(@as(i64, 1), plan.addend);

    var ready_call = ast.Node{ .call_expr = .{ .func_name = "ready", .associated_target = "future", .generics = &.{}, .args = args[0..] } };
    await_node.await_expr.expr = &ready_call;
    try std.testing.expect(planAsyncSingleAwaitContinuation(&func) == null);
}

test "shared result generic inner types" {
    var ok_ty = ast.Type{ .primitive = .i32 };
    var err_ty = ast.Type{ .primitive = .i64 };
    const generics = [_]*ast.Type{ &ok_ty, &err_ty };
    var result_ty = ast.Type{ .user_defined = .{ .name = "Result", .generics = generics[0..] } };
    const vec_generics = [_]*ast.Type{&ok_ty};
    var vec_ty = ast.Type{ .user_defined = .{ .name = "Vec", .generics = vec_generics[0..] } };

    try std.testing.expect(resultOkType(&result_ty) == &ok_ty);
    try std.testing.expect(resultErrType(&result_ty) == &err_ty);
    try std.testing.expect(vecElementType(&vec_ty) == &ok_ty);
    try std.testing.expectEqual(@as(usize, 8), vecElementSlotSize(&ok_ty));
}

test "shared dyn trait naming and method slots" {
    var i32_ty = ast.Type{ .primitive = .i32 };
    var sprite_ty = ast.Type{ .user_defined = .{ .name = "Sprite", .generics = &.{} } };
    var dyn_draw_ty = ast.Type{ .user_defined = .{ .name = "__dyn_Draw", .generics = &.{} } };
    var borrowed_dyn_draw_ty = ast.Type{ .borrow = &dyn_draw_ty };
    const self_param = ast.Param{ .name = "self", .ty = &sprite_ty, .is_borrow = true };
    const base_methods = [_]ast.TraitMethod{.{ .name = "base", .params = &.{self_param}, .ret_ty = &i32_ty }};
    const draw_methods = [_]ast.TraitMethod{.{ .name = "draw", .params = &.{self_param}, .ret_ty = &i32_ty }};
    const base_trait = ast.TraitDecl{ .name = "Base", .methods = base_methods[0..] };
    const supers = [_][]const u8{"Base"};
    const draw_trait = ast.TraitDecl{ .name = "Draw", .supertraits = supers[0..], .methods = draw_methods[0..] };

    var tc = type_checker.TypeChecker.init(std.testing.allocator);
    defer tc.deinit();
    try tc.traits.put("Base", @constCast(&base_trait));
    try tc.traits.put("Draw", @constCast(&draw_trait));

    try std.testing.expectEqualSlices(u8, "Sprite", concreteTypeName(&sprite_ty).?);
    try std.testing.expectEqualSlices(u8, "Draw", dynTraitName(&borrowed_dyn_draw_ty).?);
    try std.testing.expectEqual(@as(usize, 0), dynMethodSlot(&tc, "Draw", "base").?);
    try std.testing.expectEqual(@as(usize, 8), dynMethodSlot(&tc, "Draw", "draw").?);

    const mangled = try mangleTraitMethodName(std.testing.allocator, "Sprite", "Draw", "draw");
    defer std.testing.allocator.free(mangled);
    try std.testing.expectEqualSlices(u8, "Sprite__Draw_draw", mangled);

    const vt = try vtableName(std.testing.allocator, "Draw", "Sprite");
    defer std.testing.allocator.free(vt);
    try std.testing.expectEqualSlices(u8, "VT_Sprite_Draw", vt);
}

test "shared dyn coercion and receiver plans" {
    var concrete_ty = ast.Type{ .user_defined = .{ .name = "Sprite", .generics = &.{} } };
    var dyn_ty = ast.Type{ .user_defined = .{ .name = "__dyn_Draw", .generics = &.{} } };
    const rc_generics = [_]*ast.Type{&dyn_ty};
    const box_generics = [_]*ast.Type{&dyn_ty};
    var rc_dyn_ty = ast.Type{ .user_defined = .{ .name = "Rc", .generics = rc_generics[0..] } };
    var box_dyn_ty = ast.Type{ .user_defined = .{ .name = "Box", .generics = box_generics[0..] } };
    var borrowed_dyn_ty = ast.Type{ .borrow = &dyn_ty };

    const rc_plan = planDynDispatchReceiver(&rc_dyn_ty) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(DynDispatchReceiverKind.rc_get_dyn, rc_plan.kind);
    const box_plan = planDynDispatchReceiver(&box_dyn_ty) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(DynDispatchReceiverKind.direct_dyn, box_plan.kind);
    const borrowed_plan = planDynDispatchReceiver(&borrowed_dyn_ty) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(DynDispatchReceiverKind.direct_dyn, borrowed_plan.kind);
    try std.testing.expect(smartPointerDerefIsDynBox(&box_dyn_ty));
    try std.testing.expect(!smartPointerDerefIsDynBox(&rc_dyn_ty));
    try std.testing.expect(planDynDispatchReceiver(&concrete_ty) == null);

    var rc_expr = ast.Node{ .identifier = "make_rc" };
    var box_expr = ast.Node{ .identifier = "make_box" };
    var tc = type_checker.TypeChecker.init(std.testing.allocator);
    defer tc.deinit();
    try tc.dyn_rc_coercions.put(&rc_expr, "Draw");
    try tc.dyn_box_coercions.put(&box_expr, "Draw");

    const rc_coercion = planDynCoercion(&tc, &rc_expr) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(DynCoercionKind.rc_new_to_dyn_rc, rc_coercion.kind);
    try std.testing.expectEqualSlices(u8, "Draw", rc_coercion.trait_name);
    const box_coercion = planDynCoercion(&tc, &box_expr) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(DynCoercionKind.box_to_dyn, box_coercion.kind);
    try std.testing.expectEqualSlices(u8, "Draw", box_coercion.trait_name);
}
