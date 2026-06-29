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

pub const PrefixedIdentifierArg = struct {
    prefix: u8,
    name: []const u8,
};

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
        .identifier => false,
        .field_expr => true,
        .index_expr => true,
        .borrow_expr => |borrow| exprResultNeedsRelease(borrow.expr),
        .move_expr => |move| exprResultNeedsRelease(move.expr),
        .deref_expr => true,
        .cast_expr => false,
        else => true,
    };
}

pub fn exprResultNeedsRelease(expr: *const ast.Node) bool {
    return switch (expr.*) {
        .identifier => false,
        .field_expr => true,
        .index_expr => true,
        .borrow_expr => false,
        .deref_expr => true,
        .cast_expr => false,
        else => true,
    };
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

test "shared lowering rules classify call materialization decisions" {
    var value = ast.Node{ .identifier = "value" };
    var field = ast.Node{ .field_expr = .{ .expr = &value, .field_name = "field" } };
    var borrowed_field = ast.Node{ .borrow_expr = .{ .expr = &field } };
    var cast_ty = ast.Type{ .primitive = .i64 };
    var cast_value = ast.Node{ .cast_expr = .{ .expr = &value, .ty = &cast_ty } };

    try std.testing.expect(!callArgNeedsRelease(&value));
    try std.testing.expect(callArgNeedsRelease(&field));
    try std.testing.expect(callArgNeedsRelease(&borrowed_field));
    try std.testing.expect(!callArgNeedsRelease(&cast_value));
    try std.testing.expect(!exprResultNeedsRelease(&value));
    try std.testing.expect(exprResultNeedsRelease(&field));

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
}
