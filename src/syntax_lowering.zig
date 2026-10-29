//! Post-typecheck lowering for the goroutine syntax batch.
//!
//! Runs inside `runSlaFrontend` after `TypeChecker.checkProgram` and
//! before the primary-decl filter, so both code generators only ever
//! see plain SLA: let bindings, extern calls, and ifs. The checker
//! has already validated every construct (see DESIGN.md in the
//! gosyntax-local staging root); this pass only rewrites shapes and
//! registers the extern contracts + synthetic node types codegen
//! consults.
//!
//! P1 constructs handled here: `go` spawn (plain and supervised).
//! A go expression is only supported as a statement or as a let
//! initializer; any other surviving go node is a loud error.

const std = @import("std");
const ast = @import("ast.zig");
const tc_mod = @import("type_checker.zig");
const contract_parser = @import("contract_parser.zig");

pub const LowerError = error{ LoweringFailed, OutOfMemory };

/// Spawn failure is a loud panic, mirroring the acceptance-proven
/// hand-written shape (`if rc != 0 { panic(..); }`).
pub const SPAWN_PANIC_CODE: i64 = 60901;

pub const Lowerer = struct {
    allocator: std.mem.Allocator,
    tc: *tc_mod.TypeChecker,
    counter: usize = 0,
    err_buf: [1024]u8 = undefined,
    err_len: usize = 0,

    pub fn init(allocator: std.mem.Allocator, tc: *tc_mod.TypeChecker) Lowerer {
        return .{ .allocator = allocator, .tc = tc };
    }

    pub fn errorMessage(self: *const Lowerer) []const u8 {
        return self.err_buf[0..self.err_len];
    }

    fn fail(self: *Lowerer, comptime fmt: []const u8, args: anytype) LowerError {
        const msg = std.fmt.bufPrint(&self.err_buf, fmt, args) catch "goroutine syntax lowering failed";
        self.err_len = msg.len;
        return error.LoweringFailed;
    }

    // --- small constructors -------------------------------------------

    fn tyPrim(self: *Lowerer, prim: ast.Primitive) !*ast.Type {
        const ty = try self.allocator.create(ast.Type);
        ty.* = .{ .primitive = prim };
        return ty;
    }

    fn tyPtrTo(self: *Lowerer, inner: *ast.Type) !*ast.Type {
        const ty = try self.allocator.create(ast.Type);
        ty.* = .{ .pointer = inner };
        return ty;
    }

    fn newNode(self: *Lowerer, value: ast.Node) !*ast.Node {
        const node = try self.allocator.create(ast.Node);
        node.* = value;
        return node;
    }

    fn registerType(self: *Lowerer, node: *ast.Node, ty: *ast.Type) void {
        self.tc.expr_types.put(node, ty) catch {};
    }

    fn identNode(self: *Lowerer, name: []const u8, ty: *ast.Type) !*ast.Node {
        const node = try self.newNode(.{ .identifier = name });
        self.registerType(node, ty);
        return node;
    }

    fn intNode(self: *Lowerer, value: i64) !*ast.Node {
        const node = try self.newNode(.{ .literal = .{ .int_val = value } });
        self.registerType(node, try self.tyPrim(.i64));
        return node;
    }

    fn letNode(self: *Lowerer, name: []const u8, ty: *ast.Type, value: *ast.Node) !*ast.Node {
        return try self.newNode(.{ .let_stmt = .{ .name = name, .ty = ty, .value = value } });
    }

    /// Allocator-owned one-element slice (never a stack temporary:
    /// AST fields outlive this pass).
    fn sliceOf(self: *Lowerer, comptime T: type, item: T) ![]const T {
        const slice = try self.allocator.alloc(T, 1);
        slice[0] = item;
        return slice;
    }

    fn freshName(self: *Lowerer, prefix: []const u8) ![]const u8 {
        self.counter += 1;
        return try std.fmt.allocPrint(self.allocator, "{s}{d}", .{ prefix, self.counter });
    }

    // --- extern contracts ----------------------------------------------

    fn ensureExtern(self: *Lowerer, func: contract_parser.ExternalFunction) !void {
        if (self.tc.extern_funcs.contains(func.name)) return;
        try self.tc.extern_funcs.put(func.name, func);
    }

    fn ensureTaskExterns(self: *Lowerer) !void {
        try self.ensureExtern(.{
            .name = "sa_task_spawn",
            .params = &.{
                .{ .name = "entry", .ty = "ptr", .is_borrow = false, .is_move = false, .is_raw = true },
                .{ .name = "arg", .ty = "ptr", .is_borrow = false, .is_move = false },
                .{ .name = "out_handle", .ty = "ptr", .is_borrow = true, .is_move = false },
            },
            .ret_ty = "i32",
        });
        try self.ensureExtern(.{
            .name = "sa_task_spawn_supervised",
            .params = &.{
                .{ .name = "entry", .ty = "ptr", .is_borrow = false, .is_move = false, .is_raw = true },
                .{ .name = "arg", .ty = "ptr", .is_borrow = false, .is_move = false },
                .{ .name = "sink", .ty = "ptr", .is_borrow = false, .is_move = false, .is_raw = true },
                .{ .name = "sink_ctx", .ty = "ptr", .is_borrow = false, .is_move = false },
                .{ .name = "out_handle", .ty = "ptr", .is_borrow = true, .is_move = false },
            },
            .ret_ty = "i32",
        });
    }

    // --- entry point -----------------------------------------------------

    pub fn lowerProgram(self: *Lowerer, program: *ast.Node) LowerError!void {
        try self.ensureTaskExterns();
        for (program.program.decls) |decl| {
            switch (decl.*) {
                .func_decl => decl.func_decl.body = try self.lowerBlock(decl.func_decl.body),
                .test_decl => decl.test_decl.body = try self.lowerBlock(decl.test_decl.body),
                .impl_decl => {
                    for (decl.impl_decl.methods) |method| {
                        if (method.* == .func_decl) {
                            method.func_decl.body = try self.lowerBlock(method.func_decl.body);
                        }
                    }
                },
                else => {},
            }
        }
    }

    // --- block transform -------------------------------------------------

    fn lowerBlock(self: *Lowerer, stmts: []const *ast.Node) LowerError![]const *ast.Node {
        var out = std.array_list.Managed(*ast.Node).init(self.allocator);
        errdefer out.deinit();
        for (stmts) |stmt| {
            switch (stmt.*) {
                .let_stmt => |let| {
                    if (let.value.* == .go_expr) {
                        try self.emitSpawn(&out, let.value, let.name);
                    } else {
                        try self.scanExpr(let.value);
                        try out.append(stmt);
                    }
                },
                .expr_stmt => |expr| {
                    if (expr.* == .go_expr) {
                        const discard = try self.freshName("__go_h_");
                        try self.emitSpawn(&out, expr, discard);
                    } else {
                        try self.scanExpr(expr);
                        try out.append(stmt);
                    }
                },
                else => {
                    try self.lowerStmtChildren(stmt);
                    try out.append(stmt);
                },
            }
        }
        return try out.toOwnedSlice();
    }

    fn lowerStmtChildren(self: *Lowerer, stmt: *ast.Node) LowerError!void {
        switch (stmt.*) {
            .block_stmt => stmt.block_stmt.body = try self.lowerBlock(stmt.block_stmt.body),
            .while_stmt => {
                try self.scanExpr(stmt.while_stmt.cond);
                stmt.while_stmt.body = try self.lowerBlock(stmt.while_stmt.body);
            },
            .for_stmt => {
                try self.scanExpr(stmt.for_stmt.start);
                if (stmt.for_stmt.end) |end| try self.scanExpr(end);
                stmt.for_stmt.body = try self.lowerBlock(stmt.for_stmt.body);
            },
            .let_stmt => |let| try self.scanExpr(let.value),
            .let_else_stmt => |let_else| {
                try self.scanExpr(let_else.value);
                stmt.let_else_stmt.else_block = try self.lowerBlock(let_else.else_block);
            },
            .let_destructure_stmt => |letd| try self.scanExpr(letd.value),
            .const_stmt => |c| try self.scanExpr(c.value),
            .assign_stmt => |assign| {
                try self.scanExpr(assign.target);
                try self.scanExpr(assign.value);
            },
            .return_stmt => |ret| if (ret.value) |value| try self.scanExpr(value),
            .expr_stmt => |expr| try self.scanExpr(expr),
            else => {},
        }
    }

    /// Recurse an expression: lower any nested statement lists and
    /// reject go expressions in positions this pass does not rewrite
    /// (only statement / let-initializer positions are supported).
    fn scanExpr(self: *Lowerer, expr: *ast.Node) LowerError!void {
        switch (expr.*) {
            .go_expr => return self.fail("go expressions are only supported as a statement or a let initializer in this batch", .{}),
            .if_expr => {
                try self.scanExpr(expr.if_expr.cond);
                expr.if_expr.then_block = try self.lowerBlock(expr.if_expr.then_block);
                if (expr.if_expr.else_block) |else_block| {
                    expr.if_expr.else_block = try self.lowerBlock(else_block);
                }
            },
            .switch_expr => {
                try self.scanExpr(expr.switch_expr.val);
                var cases = std.array_list.Managed(ast.Case).init(self.allocator);
                errdefer cases.deinit();
                for (expr.switch_expr.cases) |case| {
                    try self.scanExpr(case.pattern);
                    var copy = case;
                    copy.body = try self.lowerBlock(case.body);
                    try cases.append(copy);
                }
                expr.switch_expr.cases = try cases.toOwnedSlice();
            },
            .match_expr => {
                try self.scanExpr(expr.match_expr.val);
                var cases = std.array_list.Managed(ast.MatchCase).init(self.allocator);
                errdefer cases.deinit();
                for (expr.match_expr.cases) |case| {
                    if (case.guard) |guard| try self.scanExpr(guard);
                    var copy = case;
                    copy.body = try self.lowerBlock(case.body);
                    try cases.append(copy);
                }
                expr.match_expr.cases = try cases.toOwnedSlice();
            },
            .unsafe_expr => expr.unsafe_expr.body = try self.lowerBlock(expr.unsafe_expr.body),
            .await_expr => try self.scanExpr(expr.await_expr.expr),
            .try_expr => try self.scanExpr(expr.try_expr.expr),
            .binary_expr => {
                try self.scanExpr(expr.binary_expr.left);
                try self.scanExpr(expr.binary_expr.right);
            },
            .call_expr => {
                if (expr.call_expr.callee) |callee| try self.scanExpr(callee);
                for (expr.call_expr.args) |arg| try self.scanExpr(arg);
            },
            .closure_literal => try self.scanExpr(expr.closure_literal.body),
            .borrow_expr => try self.scanExpr(expr.borrow_expr.expr),
            .move_expr => try self.scanExpr(expr.move_expr.expr),
            .deref_expr => try self.scanExpr(expr.deref_expr.expr),
            .cast_expr => try self.scanExpr(expr.cast_expr.expr),
            .field_expr => try self.scanExpr(expr.field_expr.expr),
            .struct_literal => {
                for (expr.struct_literal.fields) |field| try self.scanExpr(field.value);
                if (expr.struct_literal.update_expr) |update| try self.scanExpr(update);
            },
            .enum_literal => for (expr.enum_literal.fields) |field| try self.scanExpr(field.value),
            .tuple_literal => for (expr.tuple_literal.elements) |elem| try self.scanExpr(elem),
            .array_literal => for (expr.array_literal.elements) |elem| try self.scanExpr(elem),
            .repeat_array_literal => try self.scanExpr(expr.repeat_array_literal.value),
            .index_expr => {
                try self.scanExpr(expr.index_expr.target);
                try self.scanExpr(expr.index_expr.index);
            },
            .slice_expr => {
                try self.scanExpr(expr.slice_expr.target);
                try self.scanExpr(expr.slice_expr.start);
                try self.scanExpr(expr.slice_expr.end);
            },
            else => {},
        }
    }

    // --- spawn emission ----------------------------------------------------

    fn ptrNullNode(self: *Lowerer) !*ast.Node {
        const node = try self.newNode(.{ .call_expr = .{
            .func_name = "null",
            .associated_target = "ptr",
            .generics = try self.sliceOf(*ast.Type, try self.tyPrim(.raw_ptr)),
            .args = &.{},
            .callee = null,
        } });
        self.registerType(node, try self.tyPrim(.raw_ptr));
        return node;
    }

    /// Rewrite one go expression into the spawn sequence, appending
    /// the prefix statements plus a let binding `result_name` to the
    /// resulting handle.
    fn emitSpawn(self: *Lowerer, out: *std.array_list.Managed(*ast.Node), go_node: *ast.Node, result_name: []const u8) LowerError!void {
        const go = go_node.go_expr;
        if (go.call.* != .call_expr) return self.fail("go operand is not a call expression", .{});
        const call = go.call.call_expr;
        const entry_ty = self.tc.go_entry_types.get(go_node) orelse
            return self.fail("internal: go entry type was not recorded by the checker", .{});

        const u64_ty = try self.tyPrim(.u64);
        const i32_ty = try self.tyPrim(.i32);

        const handle_name = try self.freshName("__go_h_");
        const rc_name = try self.freshName("__go_rc_");

        // let __go_h_N: u64 = 0;
        try out.append(try self.letNode(handle_name, u64_ty, try self.intNode(0)));

        // Entry expression: the bare callee name, typed by the
        // checker-recorded entry function type (fn values are
        // materialized by the ordinary extern-argument plan).
        const entry_node = try self.newNode(.{ .identifier = call.func_name });
        self.registerType(entry_node, entry_ty);

        // Argument expression: the original single argument, or a
        // dummy slot address for zero-parameter entries.
        var arg_node: *ast.Node = undefined;
        if (call.args.len == 1) {
            arg_node = call.args[0];
        } else {
            const dummy_name = try self.freshName("__go_dummy_");
            try out.append(try self.letNode(dummy_name, try self.tyPrim(.u64), try self.intNode(0)));
            const dummy_ident = try self.identNode(dummy_name, try self.tyPrim(.u64));
            arg_node = try self.newNode(.{ .borrow_expr = .{ .expr = dummy_ident } });
            self.registerType(arg_node, try self.tyPtrTo(try self.tyPrim(.u64)));
        }

        const handle_ident = try self.identNode(handle_name, try self.tyPrim(.u64));
        const out_handle = try self.newNode(.{ .borrow_expr = .{ .expr = handle_ident } });
        self.registerType(out_handle, try self.tyPtrTo(try self.tyPrim(.u64)));

        var spawn_args = std.array_list.Managed(*ast.Node).init(self.allocator);
        errdefer spawn_args.deinit();
        try spawn_args.append(entry_node);
        try spawn_args.append(arg_node);
        if (go.supervised) {
            try spawn_args.append(try self.ptrNullNode());
            try spawn_args.append(try self.ptrNullNode());
        }
        try spawn_args.append(out_handle);

        const spawn_call = try self.newNode(.{ .call_expr = .{
            .func_name = if (go.supervised) "sa_task_spawn_supervised" else "sa_task_spawn",
            .associated_target = null,
            .generics = &.{},
            .args = try spawn_args.toOwnedSlice(),
            .callee = null,
        } });
        self.registerType(spawn_call, i32_ty);
        try out.append(try self.letNode(rc_name, i32_ty, spawn_call));

        // if __go_rc_N != 0 { panic(60901); }
        const rc_ident = try self.identNode(rc_name, try self.tyPrim(.i32));
        const cond = try self.newNode(.{ .binary_expr = .{ .op = .ne, .left = rc_ident, .right = try self.intNode(0) } });
        self.registerType(cond, try self.tyPrim(.boolean));
        const panic_call = try self.newNode(.{ .call_expr = .{
            .func_name = "panic",
            .associated_target = null,
            .generics = &.{},
            .args = try self.sliceOf(*ast.Node, try self.intNode(SPAWN_PANIC_CODE)),
            .callee = null,
        } });
        self.registerType(panic_call, try self.tyPrim(.void_type));
        const panic_stmt = try self.newNode(.{ .expr_stmt = panic_call });
        const if_node = try self.newNode(.{ .if_expr = .{
            .cond = cond,
            .then_block = try self.sliceOf(*ast.Node, panic_stmt),
            .else_block = null,
        } });
        self.registerType(if_node, try self.tyPrim(.void_type));
        try out.append(try self.newNode(.{ .expr_stmt = if_node }));

        // let <result>: u64 = __go_h_N;
        const result_ident = try self.identNode(handle_name, try self.tyPrim(.u64));
        try out.append(try self.letNode(result_name, try self.tyPrim(.u64), result_ident));
    }
};
