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
