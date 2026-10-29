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
    /// Stack of per-block lists of synthetic heap-alloc let names
    /// (the [u8; N] transfer slots). SA emits those lets as owning
    /// `alloc` registers, which the verifier requires to be
    /// released; the checker never saw the synthetic names, so no
    /// cleanup list mentions them. lowerBlock appends the names
    /// collected in its scope to the block's exit cleanup list.
    block_alloc_stack: std.array_list.Managed(std.array_list.Managed([]const u8)) = undefined,
    block_alloc_stack_ready: bool = false,
    /// Synthesized one-field wrapper struct decls for received
    /// payload slot views (see slotValueFromPtr), appended to the
    /// program decls at the end of lowerProgram.
    slot_view_decls: std.array_list.Managed(*ast.Node) = undefined,
    slot_view_decls_ready: bool = false,

    pub fn init(allocator: std.mem.Allocator, tc: *tc_mod.TypeChecker) Lowerer {
        return .{ .allocator = allocator, .tc = tc };
    }

    fn noteAllocLet(self: *Lowerer, name: []const u8) LowerError!void {
        if (!self.block_alloc_stack_ready) {
            self.block_alloc_stack = std.array_list.Managed(std.array_list.Managed([]const u8)).init(self.allocator);
            self.block_alloc_stack_ready = true;
        }
        if (self.block_alloc_stack.items.len == 0) return;
        const top = &self.block_alloc_stack.items[self.block_alloc_stack.items.len - 1];
        try top.append(name);
    }

    pub fn errorMessage(self: *const Lowerer) []const u8 {
        return self.err_buf[0..self.err_len];
    }

    /// Decl nodes synthesized by this pass (slot-view structs,
    /// head-word helper fns). The frontend's primary-decl filter
    /// must keep them or codegen loses the callees/layouts.
    pub fn synthesizedDecls(self: *const Lowerer) []const *ast.Node {
        if (!self.slot_view_decls_ready) return &.{};
        return self.slot_view_decls.items;
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
        try self.ensureExtern(.{
            .name = "sa_task_monitor",
            .params = &.{
                .{ .name = "handle", .ty = "u64", .is_borrow = false, .is_move = false },
                .{ .name = "out_chan", .ty = "ptr", .is_borrow = true, .is_move = false },
            },
            .ret_ty = "i32",
        });
    }

    pub fn lowerProgram(self: *Lowerer, program: *ast.Node) LowerError!void {
        try self.ensureTaskExterns();
        try self.ensureChanExterns();
        const orig_decls = program.program.decls;
        for (orig_decls) |decl| {
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
        if (self.slot_view_decls_ready and self.slot_view_decls.items.len > 0) {
            const merged = try self.allocator.alloc(*ast.Node, orig_decls.len + self.slot_view_decls.items.len);
            @memcpy(merged[0..orig_decls.len], orig_decls);
            @memcpy(merged[orig_decls.len..], self.slot_view_decls.items);
            program.program.decls = merged;
        }
    }

    // --- block transform -------------------------------------------------

    fn lowerBlock(self: *Lowerer, stmts: []const *ast.Node) LowerError![]const *ast.Node {
        if (!self.block_alloc_stack_ready) {
            self.block_alloc_stack = std.array_list.Managed(std.array_list.Managed([]const u8)).init(self.allocator);
            self.block_alloc_stack_ready = true;
        }
        try self.block_alloc_stack.append(std.array_list.Managed([]const u8).init(self.allocator));
        var out = std.array_list.Managed(*ast.Node).init(self.allocator);
        errdefer out.deinit();
        for (stmts) |stmt| {
            const before = out.items.len;
            switch (stmt.*) {
                .let_stmt => |let| {
                    if (let.value.* == .go_expr) {
                        try self.emitSpawn(&out, let.value, let.name);
                    } else {
                        const replacement = (try self.expandExpr(let.value, &out)) orelse
                            return self.fail("this channel operation produces no value and cannot be a let initializer", .{});
                        if (replacement != let.value) {
                            stmt.let_stmt.value = replacement;
                        }
                        try out.append(stmt);
                    }
                },
                .expr_stmt => |expr| {
                    if (expr.* == .go_expr) {
                        const discard = try self.freshName("__go_h_");
                        try self.emitSpawn(&out, expr, discard);
                    } else if (try self.expandExpr(expr, &out)) |replacement| {
                        try out.append(try self.newNode(.{ .expr_stmt = replacement }));
                    }
                },
                .let_destructure_stmt => |letd| {
                    const recv_info = self.tc.chan_calls.get(letd.value);
                    if (recv_info != null and recv_info.?.kind == .recv and letd.names.len == 2 and !letd.is_slice and letd.rest_name == null and !std.mem.eql(u8, letd.names[0], "_") and !std.mem.eql(u8, letd.names[1], "_")) {
                        try self.emitRecvBinding(letd.value, recv_info.?, letd.names[0], letd.names[1], &out);
                    } else {
                        try self.lowerStmtChildren(stmt, &out);
                        try out.append(stmt);
                    }
                },
                .select_stmt => try self.lowerSelect(stmt, &out),
                .defer_stmt => return self.fail("internal: defer statement survived the desugar pass", .{}),
                else => {
                    try self.lowerStmtChildren(stmt, &out);
                    try out.append(stmt);
                },
            }
            // The checker keys block-exit cleanup lists (register
            // releases) by statement node. When this statement was
            // replaced by a sequence (go, void channel ops,
            // select, ...), the original node never reaches
            // codegen and its cleanup list would be lost — the SA
            // verifier then reports the still-active locals as
            // leaks. Transfer the list to the last emitted
            // statement so the releases still happen at block exit.
            if (out.items.len > before and out.items[out.items.len - 1] != stmt) {
                if (self.tc.cleanups.fetchRemove(stmt)) |entry| {
                    try self.tc.cleanups.put(out.items[out.items.len - 1], entry.value);
                }
            }
        }
        // Release this block's synthetic heap-alloc lets (transfer
        // slots) at block exit: append their names to the cleanup
        // list attached to the last emitted statement.
        var alloc_names = self.block_alloc_stack.pop() orelse std.array_list.Managed([]const u8).init(self.allocator);
        defer alloc_names.deinit();
        if (alloc_names.items.len > 0 and out.items.len > 0) {
            const last = out.items[out.items.len - 1];
            var list = self.tc.cleanups.get(last) orelse std.array_list.Managed([]const u8).init(self.allocator);
            for (alloc_names.items) |name| try list.append(name);
            try self.tc.cleanups.put(last, list);
        }
        return try out.toOwnedSlice();
    }

    fn lowerStmtChildren(self: *Lowerer, stmt: *ast.Node, out: *std.array_list.Managed(*ast.Node)) LowerError!void {
        switch (stmt.*) {
            .block_stmt => stmt.block_stmt.body = try self.lowerBlock(stmt.block_stmt.body),
            .while_stmt => {
                stmt.while_stmt.cond = (try self.expandExpr(stmt.while_stmt.cond, out)) orelse return self.fail("channel operation with no value in a while condition", .{});
                stmt.while_stmt.body = try self.lowerBlock(stmt.while_stmt.body);
            },
            .for_stmt => {
                stmt.for_stmt.start = (try self.expandExpr(stmt.for_stmt.start, out)) orelse return self.fail("channel operation with no value in a for bound", .{});
                if (stmt.for_stmt.end) |end| {
                    stmt.for_stmt.end = (try self.expandExpr(end, out)) orelse return self.fail("channel operation with no value in a for bound", .{});
                }
                stmt.for_stmt.body = try self.lowerBlock(stmt.for_stmt.body);
            },
            .let_stmt => |let| {
                stmt.let_stmt.value = (try self.expandExpr(let.value, out)) orelse return self.fail("channel operation with no value in a let initializer", .{});
            },
            .let_else_stmt => |let_else| {
                stmt.let_else_stmt.value = (try self.expandExpr(let_else.value, out)) orelse return self.fail("channel operation with no value in a let-else initializer", .{});
                stmt.let_else_stmt.else_block = try self.lowerBlock(let_else.else_block);
            },
            .let_destructure_stmt => |letd| {
                stmt.let_destructure_stmt.value = (try self.expandExpr(letd.value, out)) orelse return self.fail("channel operation with no value in a destructure initializer", .{});
            },
            .const_stmt => |c| {
                stmt.const_stmt.value = (try self.expandExpr(c.value, out)) orelse return self.fail("channel operation with no value in a const initializer", .{});
            },
            .assign_stmt => |assign| {
                stmt.assign_stmt.target = (try self.expandExpr(assign.target, out)) orelse return self.fail("channel operation with no value in an assignment target", .{});
                stmt.assign_stmt.value = (try self.expandExpr(assign.value, out)) orelse return self.fail("channel operation with no value in an assignment", .{});
            },
            .return_stmt => |ret| {
                if (ret.value) |value| {
                    stmt.return_stmt.value = (try self.expandExpr(value, out)) orelse return self.fail("channel operation with no value in a return", .{});
                    }
            },
            .expr_stmt => |expr| {
                _ = try self.expandExpr(expr, out);
            },
            else => {},
        }
    }

    /// Rewrite an expression, expanding channel operations into
    /// prefix statements appended to `out` (in evaluation order) and
    /// returning the replacement expression, or null when the
    /// expression was a void channel operation consumed entirely as
    /// statements. Also lowers nested statement lists and rejects
    /// nested go expressions.
    fn expandExpr(self: *Lowerer, expr: *ast.Node, out: *std.array_list.Managed(*ast.Node)) LowerError!?*ast.Node {
        switch (expr.*) {
            .go_expr => return self.fail("go expressions are only supported as a statement or a let initializer in this batch", .{}),
            .call_expr => {
                if (self.tc.chan_calls.get(expr)) |info| {
                    return try self.emitChanCall(expr, info, out);
                }
                if (self.tc.monitor_calls.contains(expr)) {
                    return try self.emitMonitorCall(expr, out);
                }
                if (expr.call_expr.callee) |callee| {
                    expr.call_expr.callee = (try self.expandExpr(callee, out)) orelse return self.fail("channel operation with no value as a call target", .{});
                }
                {
                    const new_args = try self.allocator.alloc(*ast.Node, expr.call_expr.args.len);
                    for (expr.call_expr.args, 0..) |arg, i| {
                        new_args[i] = (try self.expandExpr(arg, out)) orelse return self.fail("channel operation with no value as a call argument", .{});
                    }
                    expr.call_expr.args = new_args;
                }
                return expr;
            },
            .if_expr => {
                expr.if_expr.cond = (try self.expandExpr(expr.if_expr.cond, out)) orelse return self.fail("channel operation with no value in an if condition", .{});
                expr.if_expr.then_block = try self.lowerBlock(expr.if_expr.then_block);
                if (expr.if_expr.else_block) |else_block| {
                    expr.if_expr.else_block = try self.lowerBlock(else_block);
                }
                return expr;
            },
            .switch_expr => {
                expr.switch_expr.val = (try self.expandExpr(expr.switch_expr.val, out)) orelse return self.fail("channel operation with no value in a switch value", .{});
                var cases = std.array_list.Managed(ast.Case).init(self.allocator);
                errdefer cases.deinit();
                for (expr.switch_expr.cases) |case| {
                    var copy = case;
                    copy.pattern = (try self.expandExpr(case.pattern, out)) orelse return self.fail("channel operation with no value in a switch pattern", .{});
                    copy.body = try self.lowerBlock(case.body);
                    try cases.append(copy);
                }
                expr.switch_expr.cases = try cases.toOwnedSlice();
                return expr;
            },
            .match_expr => {
                expr.match_expr.val = (try self.expandExpr(expr.match_expr.val, out)) orelse return self.fail("channel operation with no value in a match value", .{});
                var cases = std.array_list.Managed(ast.MatchCase).init(self.allocator);
                errdefer cases.deinit();
                for (expr.match_expr.cases) |case| {
                    if (case.guard) |guard| {
                        _ = (try self.expandExpr(guard, out)) orelse return self.fail("channel operation with no value in a match guard", .{});
                    }
                    var copy = case;
                    copy.body = try self.lowerBlock(case.body);
                    try cases.append(copy);
                }
                expr.match_expr.cases = try cases.toOwnedSlice();
                return expr;
            },
            .unsafe_expr => {
                expr.unsafe_expr.body = try self.lowerBlock(expr.unsafe_expr.body);
                return expr;
            },
            .await_expr => {
                expr.await_expr.expr = (try self.expandExpr(expr.await_expr.expr, out)) orelse return self.fail("channel operation with no value in an await", .{});
                return expr;
            },
            .try_expr => {
                expr.try_expr.expr = (try self.expandExpr(expr.try_expr.expr, out)) orelse return self.fail("channel operation with no value in a try expression", .{});
                return expr;
            },
            .binary_expr => {
                expr.binary_expr.left = (try self.expandExpr(expr.binary_expr.left, out)) orelse return self.fail("channel operation with no value in a binary expression", .{});
                expr.binary_expr.right = (try self.expandExpr(expr.binary_expr.right, out)) orelse return self.fail("channel operation with no value in a binary expression", .{});
                return expr;
            },
            .closure_literal => {
                expr.closure_literal.body = (try self.expandExpr(expr.closure_literal.body, out)) orelse return self.fail("channel operation with no value as a closure body", .{});
                return expr;
            },
            .borrow_expr => {
                expr.borrow_expr.expr = (try self.expandExpr(expr.borrow_expr.expr, out)) orelse return self.fail("channel operation with no value in a borrow", .{});
                return expr;
            },
            .move_expr => {
                expr.move_expr.expr = (try self.expandExpr(expr.move_expr.expr, out)) orelse return self.fail("channel operation with no value in a move", .{});
                return expr;
            },
            .deref_expr => {
                expr.deref_expr.expr = (try self.expandExpr(expr.deref_expr.expr, out)) orelse return self.fail("channel operation with no value in a deref", .{});
                return expr;
            },
            .cast_expr => {
                expr.cast_expr.expr = (try self.expandExpr(expr.cast_expr.expr, out)) orelse return self.fail("channel operation with no value in a cast", .{});
                return expr;
            },
            .field_expr => {
                expr.field_expr.expr = (try self.expandExpr(expr.field_expr.expr, out)) orelse return self.fail("channel operation with no value in a field access", .{});
                return expr;
            },
            .struct_literal => {
                {
                    const new_fields = try self.allocator.alloc(ast.StructLiteralField, expr.struct_literal.fields.len);
                    for (expr.struct_literal.fields, 0..) |field, i| {
                        new_fields[i] = field;
                        new_fields[i].value = (try self.expandExpr(field.value, out)) orelse return self.fail("channel operation with no value in a struct literal", .{});
                    }
                    expr.struct_literal.fields = new_fields;
                }
                if (expr.struct_literal.update_expr) |update| {
                    expr.struct_literal.update_expr = (try self.expandExpr(update, out)) orelse return self.fail("channel operation with no value in a struct update", .{});
                }
                return expr;
            },
            .enum_literal => {
                const new_fields = try self.allocator.alloc(ast.EnumLiteralField, expr.enum_literal.fields.len);
                for (expr.enum_literal.fields, 0..) |field, i| {
                    new_fields[i] = field;
                    new_fields[i].value = (try self.expandExpr(field.value, out)) orelse return self.fail("channel operation with no value in an enum literal", .{});
                }
                expr.enum_literal.fields = new_fields;
                return expr;
            },
            .tuple_literal => {
                const new_elems = try self.allocator.alloc(*ast.Node, expr.tuple_literal.elements.len);
                for (expr.tuple_literal.elements, 0..) |elem, i| {
                    new_elems[i] = (try self.expandExpr(elem, out)) orelse return self.fail("channel operation with no value in a tuple literal", .{});
                }
                expr.tuple_literal.elements = new_elems;
                return expr;
            },
            .array_literal => {
                const new_elems = try self.allocator.alloc(*ast.Node, expr.array_literal.elements.len);
                for (expr.array_literal.elements, 0..) |elem, i| {
                    new_elems[i] = (try self.expandExpr(elem, out)) orelse return self.fail("channel operation with no value in an array literal", .{});
                }
                expr.array_literal.elements = new_elems;
                return expr;
            },
            .repeat_array_literal => {
                expr.repeat_array_literal.value = (try self.expandExpr(expr.repeat_array_literal.value, out)) orelse return self.fail("channel operation with no value in a repeat literal", .{});
                return expr;
            },
            .index_expr => {
                expr.index_expr.target = (try self.expandExpr(expr.index_expr.target, out)) orelse return self.fail("channel operation with no value in an index target", .{});
                expr.index_expr.index = (try self.expandExpr(expr.index_expr.index, out)) orelse return self.fail("channel operation with no value in an index", .{});
                return expr;
            },
            .slice_expr => {
                expr.slice_expr.target = (try self.expandExpr(expr.slice_expr.target, out)) orelse return self.fail("channel operation with no value in a slice target", .{});
                expr.slice_expr.start = (try self.expandExpr(expr.slice_expr.start, out)) orelse return self.fail("channel operation with no value in a slice bound", .{});
                expr.slice_expr.end = (try self.expandExpr(expr.slice_expr.end, out)) orelse return self.fail("channel operation with no value in a slice bound", .{});
                return expr;
            },
            else => return expr,
        }
    }

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

    // --- channel contracts ----------------------------------------------

    fn ensureChanExterns(self: *Lowerer) !void {
        try self.ensureExtern(.{
            .name = "sa_chan_make",
            .params = &.{
                .{ .name = "capacity", .ty = "u32", .is_borrow = false, .is_move = false },
                .{ .name = "out_handle", .ty = "ptr", .is_borrow = true, .is_move = false },
            },
            .ret_ty = "i32",
        });
        try self.ensureExtern(.{
            .name = "sa_chan_destroy",
            .params = &.{.{ .name = "handle", .ty = "u64", .is_borrow = false, .is_move = false }},
            .ret_ty = "i32",
        });
        try self.ensureExtern(.{
            .name = "sa_chan_close",
            .params = &.{.{ .name = "handle", .ty = "u64", .is_borrow = false, .is_move = false }},
            .ret_ty = "i32",
        });
        try self.ensureExtern(.{
            .name = "sa_chan_send",
            .params = &.{
                .{ .name = "handle", .ty = "u64", .is_borrow = false, .is_move = false },
                .{ .name = "value", .ty = "ptr", .is_borrow = false, .is_move = false, .is_raw = true },
            },
            .ret_ty = "i32",
        });
        try self.ensureExtern(.{
            .name = "sa_chan_recv",
            .params = &.{
                .{ .name = "handle", .ty = "u64", .is_borrow = false, .is_move = false },
                .{ .name = "out_value", .ty = "ptr", .is_borrow = true, .is_move = false },
                .{ .name = "out_closed", .ty = "ptr", .is_borrow = true, .is_move = false },
            },
            .ret_ty = "i32",
        });
        try self.ensureExtern(.{
            .name = "sa_chan_len",
            .params = &.{
                .{ .name = "handle", .ty = "u64", .is_borrow = false, .is_move = false },
                .{ .name = "out_len", .ty = "ptr", .is_borrow = true, .is_move = false },
            },
            .ret_ty = "i32",
        });
        try self.ensureExtern(.{
            .name = "sa_chan_cap",
            .params = &.{
                .{ .name = "handle", .ty = "u64", .is_borrow = false, .is_move = false },
                .{ .name = "out_cap", .ty = "ptr", .is_borrow = true, .is_move = false },
            },
            .ret_ty = "i32",
        });
        try self.ensureExtern(.{
            .name = "sa_chan_select",
            .params = &.{
                .{ .name = "cases", .ty = "ptr", .is_borrow = false, .is_move = false, .is_raw = true },
                .{ .name = "ops", .ty = "ptr", .is_borrow = false, .is_move = false, .is_raw = true },
                .{ .name = "slots", .ty = "ptr", .is_borrow = false, .is_move = false, .is_raw = true },
                .{ .name = "count", .ty = "u64", .is_borrow = false, .is_move = false },
                .{ .name = "has_default", .ty = "u32", .is_borrow = false, .is_move = false },
                .{ .name = "timeout_ns", .ty = "i64", .is_borrow = false, .is_move = false },
                .{ .name = "out_index", .ty = "ptr", .is_borrow = true, .is_move = false },
                .{ .name = "out_closed", .ty = "ptr", .is_borrow = true, .is_move = false },
            },
            .ret_ty = "i32",
        });
        try self.ensureExtern(.{
            .name = "sa_mem_copy",
            .params = &.{
                .{ .name = "dst", .ty = "ptr", .is_borrow = true, .is_move = false },
                .{ .name = "src", .ty = "ptr", .is_borrow = true, .is_move = false },
                .{ .name = "count", .ty = "u64", .is_borrow = false, .is_move = false },
            },
            .ret_ty = "void",
        });
    }

    // --- shared emission helpers -------------------------------------------

    fn tyArrayOf(self: *Lowerer, elem: *ast.Type, len: usize) !*ast.Type {
        const ty = try self.allocator.create(ast.Type);
        ty.* = .{ .array = .{ .elem = elem, .len = len } };
        return ty;
    }

    fn tyTupleOf(self: *Lowerer, elems: []const *ast.Type) !*ast.Type {
        const ty = try self.allocator.create(ast.Type);
        ty.* = .{ .tuple = .{ .elems = elems } };
        return ty;
    }

    fn tyChanOf(self: *Lowerer, payload_ty: *ast.Type) !*ast.Type {
        const generics = try self.allocator.alloc(*ast.Type, 1);
        generics[0] = payload_ty;
        const ty = try self.allocator.create(ast.Type);
        ty.* = .{ .user_defined = .{ .name = "Chan", .generics = generics } };
        return ty;
    }

    fn intNodeAs(self: *Lowerer, value: i64, prim: ast.Primitive) !*ast.Node {
        const node = try self.newNode(.{ .literal = .{ .int_val = value } });
        self.registerType(node, try self.tyPrim(prim));
        return node;
    }

    fn externCallNode(self: *Lowerer, name: []const u8, args: []const *ast.Node, ret_ty: *ast.Type) !*ast.Node {
        const node = try self.newNode(.{ .call_expr = .{
            .func_name = name,
            .associated_target = null,
            .generics = &.{},
            .args = args,
            .callee = null,
        } });
        self.registerType(node, ret_ty);
        return node;
    }

    fn borrowNode(self: *Lowerer, target: *ast.Node, pointee_ty: *ast.Type) !*ast.Node {
        const node = try self.newNode(.{ .borrow_expr = .{ .expr = target } });
        self.registerType(node, try self.tyPtrTo(pointee_ty));
        return node;
    }

    fn emitRcCheck(self: *Lowerer, out: *std.array_list.Managed(*ast.Node), rc_name: []const u8, code: i64) LowerError!void {
        const rc_ident = try self.identNode(rc_name, try self.tyPrim(.i32));
        const cond = try self.newNode(.{ .binary_expr = .{ .op = .ne, .left = rc_ident, .right = try self.intNode(0) } });
        self.registerType(cond, try self.tyPrim(.boolean));
        const panic_call = try self.newNode(.{ .call_expr = .{
            .func_name = "panic",
            .associated_target = null,
            .generics = &.{},
            .args = try self.sliceOf(*ast.Node, try self.intNode(code)),
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
    }

    fn slotArrayNode(self: *Lowerer, name: []const u8, total_bytes: usize) LowerError!*ast.Node {
        try self.noteAllocLet(name);
        const zero = try self.intNode(0);
        const repeat = try self.newNode(.{ .repeat_array_literal = .{ .value = zero, .len = total_bytes } });
        self.registerType(repeat, try self.tyArrayOf(try self.tyPrim(.u8), total_bytes));
        return try self.letNode(name, try self.tyArrayOf(try self.tyPrim(.u8), total_bytes), repeat);
    }

    fn emitMemCopy(self: *Lowerer, out: *std.array_list.Managed(*ast.Node), dst: *ast.Node, src: *ast.Node, size: usize) LowerError!void {
        const args = try self.allocator.alloc(*ast.Node, 3);
        args[0] = dst;
        args[1] = src;
        args[2] = try self.intNode(@intCast(size));
        const call = try self.externCallNode("sa_mem_copy", args, try self.tyPrim(.void_type));
        try out.append(try self.newNode(.{ .expr_stmt = call }));
    }

    fn payloadSize(self: *Lowerer, payload_ty: *ast.Type) LowerError!usize {
        return self.tc.payloadStorageSize(payload_ty) orelse
            return self.fail("internal: channel payload size was not validated by the checker", .{});
    }

    /// Word payloads: primitives and decl-less handle types
    /// (String, Vec, Chan, Box, ...). Their register holds the
    /// value word itself, so a borrow of the binding in the SAB
    /// codegen yields the value, not the address of its home —
    /// sends must stage the word through a plain u64 binding and
    /// copy from there, and receives load the word from the slot.
    /// Aggregate payloads (structs, tuples, enums, arrays) are
    /// address-resident and transfer by address instead.
    fn payloadIsWord(self: *Lowerer, payload_ty: *ast.Type) bool {
        return payload_ty.* == .primitive or (payload_ty.* == .user_defined and self.tc.structs.get(payload_ty.user_defined.name) == null and self.tc.enums.get(payload_ty.user_defined.name) == null);
    }

    /// A-form send staging for word payloads (Jev ruling
    /// 2026-10-29: chan send/recv ownership is uniformly
    /// view+forget): view the slot through the synthesized
    /// wrapper struct (slotViewType), store the payload into the
    /// view field — the move send semantics want — and retire
    /// the view borrow with mem::forget. The exact mirror of
    /// slotValueFromPtrFull's load path: no staging lets, no
    /// helper fns, no mem_copy for word payloads.
    fn storeSlotValueViaView(self: *Lowerer, out: *std.array_list.Managed(*ast.Node), ptr_expr: *ast.Node, payload_ty: *ast.Type, value_node: *ast.Node) LowerError!void {
        const view_ty = try self.slotViewType(payload_ty);
        const borrow_view_ty = try self.allocator.create(ast.Type);
        borrow_view_ty.* = .{ .borrow = view_ty };
        const cast = try self.newNode(.{ .cast_expr = .{ .expr = ptr_expr, .ty = borrow_view_ty } });
        self.registerType(cast, borrow_view_ty);
        const ref_name = try self.freshName("__sv_ref_");
        try out.append(try self.letNode(ref_name, borrow_view_ty, cast));
        const field = try self.newNode(.{ .field_expr = .{ .expr = try self.identNode(ref_name, borrow_view_ty), .field_name = "v" } });
        self.registerType(field, payload_ty);
        try out.append(try self.newNode(.{ .assign_stmt = .{ .target = field, .value = value_node } }));
        try out.append(try self.forgetStmt(ref_name, borrow_view_ty));
    }

    // --- channel operation emission ----------------------------------------

    fn emitMonitorCall(self: *Lowerer, call_node: *ast.Node, out: *std.array_list.Managed(*ast.Node)) LowerError!?*ast.Node {
        const call = call_node.call_expr;
        const chan_ty = self.tc.expr_types.get(call_node) orelse return self.fail("internal: monitor call has no recorded type", .{});
        const handle_arg = (try self.expandExpr(call.args[0], out)) orelse return self.fail("internal: monitor handle has no value", .{});
        const chan_name = try self.freshName("__mon_ch_");
        const rc_name = try self.freshName("__mon_rc_");
        try out.append(try self.letNode(chan_name, try self.tyPrim(.u64), try self.intNode(0)));
        const chan_ident = try self.identNode(chan_name, try self.tyPrim(.u64));
        const args = try self.allocator.alloc(*ast.Node, 2);
        args[0] = handle_arg;
        args[1] = try self.borrowNode(chan_ident, try self.tyPrim(.u64));
        const mon_call = try self.externCallNode("sa_task_monitor", args, try self.tyPrim(.i32));
        try out.append(try self.letNode(rc_name, try self.tyPrim(.i32), mon_call));
        try self.emitRcCheck(out, rc_name, 60921);
        // Value-copy materialization, same as Chan::new (the
        // address-taken slot must not be moved out as the result).
        const val_name = try self.freshName("__mon_v_");
        try out.append(try self.letNode(val_name, try self.tyPrim(.u64), try self.identNode(chan_name, try self.tyPrim(.u64))));
        return try self.identNode(val_name, chan_ty);
    }

    fn emitChanCall(self: *Lowerer, call_node: *ast.Node, info: tc_mod.ChanCallInfo, out: *std.array_list.Managed(*ast.Node)) LowerError!?*ast.Node {
        const call = call_node.call_expr;
        // Normalize a non-identifier receiver (field/index/deref
        // shapes such as `pp.req`) into a handle binding first:
        // passed raw, the text codegen materializes the projection
        // address instead of the handle word and the runtime call
        // fails with INVALID_HANDLE. Mirrors lowerSelect, which
        // binds every arm handle to a let for the same reason.
        var receiver: *ast.Node = call.args[0];
        if (info.kind != .new and receiver.* != .identifier) {
            const recv_ty = self.tc.expr_types.get(call.args[0]) orelse try self.tyChanOf(info.payload_ty);
            const recv_name = try self.freshName("__ch_recv_");
            try out.append(try self.letNode(recv_name, recv_ty, receiver));
            receiver = try self.identNode(recv_name, recv_ty);
        }
        switch (info.kind) {
            .new => {
                const handle_name = try self.freshName("__ch_h_");
                const rc_name = try self.freshName("__ch_rc_");
                try out.append(try self.letNode(handle_name, try self.tyPrim(.u64), try self.intNode(0)));
                const cast = try self.newNode(.{ .cast_expr = .{ .expr = call.args[0], .ty = try self.tyPrim(.u32) } });
                self.registerType(cast, try self.tyPrim(.u32));
                const handle_ident = try self.identNode(handle_name, try self.tyPrim(.u64));
                const args = try self.allocator.alloc(*ast.Node, 2);
                args[0] = cast;
                args[1] = try self.borrowNode(handle_ident, try self.tyPrim(.u64));
                const make_call = try self.externCallNode("sa_chan_make", args, try self.tyPrim(.i32));
                try out.append(try self.letNode(rc_name, try self.tyPrim(.i32), make_call));
                try self.emitRcCheck(out, rc_name, 60911);
                // Materialize the handle as a value copy before
                // handing it out under the Chan<T> type: returning
                // the address-taken slot itself would make the
                // outer binding a move of the stack allocation
                // (SA verifier: StackEscape) instead of a load.
                const val_name = try self.freshName("__ch_v_");
                try out.append(try self.letNode(val_name, try self.tyPrim(.u64), try self.identNode(handle_name, try self.tyPrim(.u64))));
                return try self.identNode(val_name, try self.tyChanOf(info.payload_ty));
            },
            .send => {
                const slot_name = try self.freshName("__slot_");
                try out.append(try self.slotArrayNode(slot_name, 16));
                const slot_ty = try self.tyArrayOf(try self.tyPrim(.u8), 16);
                if (self.payloadIsWord(info.payload_ty)) {
                    // A form (see storeSlotValueViaView): view
                    // borrow of the slot, payload moved into the
                    // view field, borrow retired with mem::forget.
                    const addr = try self.borrowNode(try self.identNode(slot_name, slot_ty), slot_ty);
                    try self.storeSlotValueViaView(out, addr, info.payload_ty, call.args[1]);
                } else {
                    const size = try self.payloadSize(info.payload_ty);
                    var value_node = call.args[1];
                    const value_ty = self.tc.expr_types.get(call.args[1]) orelse info.payload_ty;
                    const is_place = switch (value_node.*) {
                        .identifier, .field_expr, .index_expr, .deref_expr => true,
                        else => false,
                    };
                    if (!is_place) {
                        const bind_name = try self.freshName("__sv_");
                        try out.append(try self.letNode(bind_name, info.payload_ty, value_node));
                        value_node = try self.identNode(bind_name, info.payload_ty);
                    }
                    const dst = try self.borrowNode(try self.identNode(slot_name, slot_ty), slot_ty);
                    const src = try self.borrowNode(value_node, value_ty);
                    try self.emitMemCopy(out, dst, src, size);
                }
                const rc_name = try self.freshName("__ch_rc_");
                const args = try self.allocator.alloc(*ast.Node, 2);
                args[0] = receiver;
                args[1] = try self.borrowNode(try self.identNode(slot_name, slot_ty), slot_ty);
                const send_call = try self.externCallNode("sa_chan_send", args, try self.tyPrim(.i32));
                try out.append(try self.letNode(rc_name, try self.tyPrim(.i32), send_call));
                try self.emitRcCheck(out, rc_name, 60912);
                return null;
            },
            .recv => {
                const slot_name = try self.freshName("__slot_");
                try out.append(try self.slotArrayNode(slot_name, 16));
                const slot_ty = try self.tyArrayOf(try self.tyPrim(.u8), 16);
                const closed_name = try self.freshName("__closed_");
                try out.append(try self.letNode(closed_name, try self.tyPrim(.u32), try self.intNode(0)));
                const rc_name = try self.freshName("__ch_rc_");
                const args = try self.allocator.alloc(*ast.Node, 3);
                args[0] = receiver;
                args[1] = try self.borrowNode(try self.identNode(slot_name, slot_ty), slot_ty);
                args[2] = try self.borrowNode(try self.identNode(closed_name, try self.tyPrim(.u32)), try self.tyPrim(.u32));
                const recv_call = try self.externCallNode("sa_chan_recv", args, try self.tyPrim(.i32));
                try out.append(try self.letNode(rc_name, try self.tyPrim(.i32), recv_call));
                try self.emitRcCheck(out, rc_name, 60915);
                const closed_ident = try self.identNode(closed_name, try self.tyPrim(.u32));
                const closed_expr = try self.newNode(.{ .binary_expr = .{ .op = .ne, .left = closed_ident, .right = try self.intNode(0) } });
                self.registerType(closed_expr, try self.tyPrim(.boolean));
                const tuple_elems = try self.allocator.alloc(*ast.Node, 2);
                tuple_elems[0] = try self.slotValueExpr(out, slot_name, slot_ty, info.payload_ty);
                tuple_elems[1] = closed_expr;
                const tuple_node = try self.newNode(.{ .tuple_literal = .{ .elements = tuple_elems } });
                const tuple_elem_tys = try self.allocator.alloc(*ast.Type, 2);
                tuple_elem_tys[0] = info.payload_ty;
                tuple_elem_tys[1] = try self.tyPrim(.boolean);
                const tuple_ty = try self.tyTupleOf(tuple_elem_tys);
                self.registerType(tuple_node, tuple_ty);
                const tuple_name = try self.freshName("__rt_");
                try out.append(try self.letNode(tuple_name, tuple_ty, tuple_node));
                return try self.identNode(tuple_name, tuple_ty);
            },
            .close, .destroy => {
                const rc_name = try self.freshName("__ch_rc_");
                const args = try self.allocator.alloc(*ast.Node, 1);
                args[0] = receiver;
                const close_call = try self.externCallNode(if (info.kind == .close) "sa_chan_close" else "sa_chan_destroy", args, try self.tyPrim(.i32));
                try out.append(try self.letNode(rc_name, try self.tyPrim(.i32), close_call));
                try self.emitRcCheck(out, rc_name, if (info.kind == .close) 60913 else 60914);
                return null;
            },
            .len, .cap => {
                const n_name = try self.freshName("__ch_n_");
                try out.append(try self.letNode(n_name, try self.tyPrim(.u64), try self.intNode(0)));
                const rc_name = try self.freshName("__ch_rc_");
                const args = try self.allocator.alloc(*ast.Node, 2);
                args[0] = receiver;
                args[1] = try self.borrowNode(try self.identNode(n_name, try self.tyPrim(.u64)), try self.tyPrim(.u64));
                const len_call = try self.externCallNode(if (info.kind == .len) "sa_chan_len" else "sa_chan_cap", args, try self.tyPrim(.i32));
                try out.append(try self.letNode(rc_name, try self.tyPrim(.i32), len_call));
                try self.emitRcCheck(out, rc_name, if (info.kind == .len) 60917 else 60918);
                return try self.identNode(n_name, try self.tyPrim(.u64));
            },
        }
    }

    /// Statement-level recv for `let (value, closed) = ch.recv()`:
    /// bind the payload var under the pattern's own name and the
    /// closed flag as a bool let, with no synthetic tuple value in
    /// between. Materializing the (payload, bool) tuple as a value
    /// makes the SAB codegen load a struct payload through an
    /// uninitialized spill slot (the value is address-resident),
    /// which segfaults for aggregate payloads; binding directly is
    /// the same shape the select recv arms use.
    fn emitRecvBinding(self: *Lowerer, call_node: *ast.Node, info: tc_mod.ChanCallInfo, value_name: []const u8, closed_bind: []const u8, out: *std.array_list.Managed(*ast.Node)) LowerError!void {
        const call = call_node.call_expr;
        var receiver: *ast.Node = call.args[0];
        if (receiver.* != .identifier) {
            const recv_ty = self.tc.expr_types.get(call.args[0]) orelse try self.tyChanOf(info.payload_ty);
            const recv_name = try self.freshName("__ch_recv_");
            try out.append(try self.letNode(recv_name, recv_ty, receiver));
            receiver = try self.identNode(recv_name, recv_ty);
        }
        const slot_name = try self.freshName("__slot_");
        try out.append(try self.slotArrayNode(slot_name, 16));
        const slot_ty = try self.tyArrayOf(try self.tyPrim(.u8), 16);
        const closed_name = try self.freshName("__closed_");
        try out.append(try self.letNode(closed_name, try self.tyPrim(.u32), try self.intNode(0)));
        const rc_name = try self.freshName("__ch_rc_");
        const args = try self.allocator.alloc(*ast.Node, 3);
        args[0] = receiver;
        args[1] = try self.borrowNode(try self.identNode(slot_name, slot_ty), slot_ty);
        args[2] = try self.borrowNode(try self.identNode(closed_name, try self.tyPrim(.u32)), try self.tyPrim(.u32));
        const recv_call = try self.externCallNode("sa_chan_recv", args, try self.tyPrim(.i32));
        try out.append(try self.letNode(rc_name, try self.tyPrim(.i32), recv_call));
        try self.emitRcCheck(out, rc_name, 60915);
        const sv = try self.slotValueForBinding(out, slot_name, slot_ty, info.payload_ty);
        try out.append(try self.letNode(value_name, info.payload_ty, sv.expr));
        if (sv.ref_name) |ref_name| {
            try out.append(try self.forgetStmt(ref_name, sv.ref_ty.?));
        }
        const closed_ident = try self.identNode(closed_name, try self.tyPrim(.u32));
        const closed_expr = try self.newNode(.{ .binary_expr = .{ .op = .ne, .left = closed_ident, .right = try self.intNode(0) } });
        self.registerType(closed_expr, try self.tyPrim(.boolean));
        try out.append(try self.letNode(closed_bind, try self.tyPrim(.boolean), closed_expr));
    }

    /// The received payload as a value expression: the slot bytes
    /// viewed through a synthesized one-field wrapper struct,
    /// `(slot as &__go_slot_view_N).v` (see slotViewType). Field
    /// projection through a struct borrow is an address
    /// computation in both codegens: an aggregate payload takes
    /// the slot address as its value, a scalar loads through it,
    /// and a String recovers the address of its {ptr, len} pair.
    /// Every shorter form miscompiles somewhere — a payload
    /// var_stmt is scalar-only in the checker and its SAB path
    /// allocates an 8-byte pointer cell that a 16-byte copy
    /// overflows, a synthetic tuple VALUE segfaults in SAB
    /// destructure (its aggregate element is loaded through an
    /// uninitialized spill slot), `*p` on an aggregate segfaults
    /// in both backends at base, an index projection loads the
    /// payload's first word as the element address (array values
    /// are pointer cells; the slot is raw storage, not a cell),
    /// and a tuple field projection through a borrow is
    /// UnsupportedSabDirectFeature.
    fn slotValueExpr(self: *Lowerer, out: *std.array_list.Managed(*ast.Node), slot_name: []const u8, slot_ty: *ast.Type, payload_ty: *ast.Type) LowerError!*ast.Node {
        // The cast source is a borrow of the slot, never the raw
        // array identifier: the SA-text codegen renders a cast of
        // a stack-array identifier as a move of the allocation
        // register (its scope-end release then double-consumes),
        // while a borrow materializes the address into a fresh
        // pointer temp in both codegens.
        const slot_ident = try self.identNode(slot_name, slot_ty);
        const addr = try self.borrowNode(slot_ident, slot_ty);
        return try self.slotValueFromPtr(out, addr, payload_ty);
    }

    const SlotValue = struct { expr: *ast.Node, ref_name: ?[]const u8, ref_ty: ?*ast.Type };

    /// `mem::forget(<ident>);` — retires a binding in both
    /// codegens with no drop emitted.
    fn forgetStmt(self: *Lowerer, name: []const u8, ty: *ast.Type) LowerError!*ast.Node {
        const args = try self.allocator.alloc(*ast.Node, 1);
        args[0] = try self.identNode(name, ty);
        const call = try self.newNode(.{ .call_expr = .{
            .func_name = "forget",
            .associated_target = "mem",
            .generics = &.{},
            .args = args,
            .callee = null,
        } });
        self.registerType(call, try self.tyPrim(.void_type));
        return try self.newNode(.{ .expr_stmt = call });
    }

    /// The receive-slot value for a statement-level binding,
    /// addressed through a borrow of the slot (see slotValueExpr),
    /// with the wrapper-view borrow's name so the caller can
    /// retire it with mem::forget after the value binding: in the
    /// SA-text codegen the borrow local otherwise stays live at
    /// function exit (MemoryLeak trap), while the SAB cleanup
    /// skips registers already marked consumed, so the explicit
    /// forget is safe there.
    fn slotValueForBinding(self: *Lowerer, out: *std.array_list.Managed(*ast.Node), slot_name: []const u8, slot_ty: *ast.Type, payload_ty: *ast.Type) LowerError!SlotValue {
        const slot_ident = try self.identNode(slot_name, slot_ty);
        const addr = try self.borrowNode(slot_ident, slot_ty);
        return try self.slotValueFromPtrFull(out, addr, payload_ty);
    }

    fn slotValueFromPtr(self: *Lowerer, out: *std.array_list.Managed(*ast.Node), ptr_expr: *ast.Node, payload_ty: *ast.Type) LowerError!*ast.Node {
        const sv = try self.slotValueFromPtrFull(out, ptr_expr, payload_ty);
        return sv.expr;
    }

    fn slotValueFromPtrFull(self: *Lowerer, out: *std.array_list.Managed(*ast.Node), ptr_expr: *ast.Node, payload_ty: *ast.Type) LowerError!SlotValue {
        // Address-resident payloads (structs, tuples, enums,
        // arrays): the payload value IS the slot address in both
        // codegens' register model, so a plain value cast of the
        // slot address is the binding — no load, no projection (a
        // projection would read the first payload word as an
        // address, since aggregate storage holds raw field words,
        // not a pointer to them). Word payloads — primitives and
        // decl-less handle types (String, Vec, Chan, Box, ...),
        // whose register holds the head word itself — take the
        // load path below instead.
        if (!self.payloadIsWord(payload_ty)) {
            const cast = try self.newNode(.{ .cast_expr = .{ .expr = ptr_expr, .ty = payload_ty } });
            self.registerType(cast, payload_ty);
            return .{ .expr = cast, .ref_name = null, .ref_ty = null };
        }
        const view_ty = try self.slotViewType(payload_ty);
        const borrow_view_ty = try self.allocator.create(ast.Type);
        borrow_view_ty.* = .{ .borrow = view_ty };
        const cast = try self.newNode(.{ .cast_expr = .{ .expr = ptr_expr, .ty = borrow_view_ty } });
        self.registerType(cast, borrow_view_ty);
        // The projection target must be a plain identifier (a cast
        // target is UnsupportedSabDirectFeature), so bind the
        // borrow to a borrow-typed let first — its register holds
        // the address as a value, like the select slot pointers.
        const ref_name = try self.freshName("__rv_ref_");
        try out.append(try self.letNode(ref_name, borrow_view_ty, cast));
        const ref_ident = try self.identNode(ref_name, borrow_view_ty);
        const field = try self.newNode(.{ .field_expr = .{ .expr = ref_ident, .field_name = "v" } });
        self.registerType(field, payload_ty);
        return .{ .expr = field, .ref_name = ref_name, .ref_ty = borrow_view_ty };
    }

    /// A synthesized one-field struct type `__go_slot_view_N { v: Payload }`
    /// registered with the checker and queued for declaration in
    /// the program. Struct fields are inline in both codegens, so
    /// viewing the receive slot through this wrapper makes the
    /// payload's field projection an exact address computation
    /// over the slot bytes — the one aggregate-producing form that
    /// works identically in both backends.
    fn slotViewType(self: *Lowerer, payload_ty: *ast.Type) LowerError!*ast.Type {
        if (!self.slot_view_decls_ready) {
            self.slot_view_decls = std.array_list.Managed(*ast.Node).init(self.allocator);
            self.slot_view_decls_ready = true;
        }
        const name = try self.freshName("__go_slot_view_");
        const fields = try self.allocator.alloc(ast.Field, 1);
        fields[0] = .{ .name = "v", .ty = payload_ty };
        const decl = try self.allocator.create(ast.StructDecl);
        decl.* = .{ .name = name, .generics = &.{}, .fields = fields };
        try self.tc.structs.put(name, decl);
        try self.slot_view_decls.append(try self.newNode(.{ .struct_decl = decl.* }));
        const ty = try self.allocator.create(ast.Type);
        ty.* = .{ .user_defined = .{ .name = name, .generics = &.{} } };
        return ty;
    }

    // --- select emission -----------------------------------------------------

    fn slotOffsetBorrow(self: *Lowerer, slots_name: []const u8, slots_ty: *ast.Type, offset: usize) LowerError!*ast.Node {
        const slots_ident = try self.identNode(slots_name, slots_ty);
        const index = try self.newNode(.{ .index_expr = .{ .target = slots_ident, .index = try self.intNode(@intCast(offset)) } });
        self.registerType(index, try self.tyPrim(.u8));
        return try self.borrowNode(index, try self.tyPrim(.u8));
    }

    /// Bind a select slot address to a borrow-typed let and
    /// return the identifier. A borrow-of-index passed inline at
    /// a call site materializes as a plain pointer temp and the
    /// SA verifier rejects it for &-parameters
    /// (CapabilityMismatch); a borrow-typed binding carries the
    /// borrow capability in its register.
    fn slotPtrLet(self: *Lowerer, out: *std.array_list.Managed(*ast.Node), slots_name: []const u8, slots_ty: *ast.Type, offset: usize) LowerError!*ast.Node {
        const borrow_ty = try self.allocator.create(ast.Type);
        borrow_ty.* = .{ .borrow = try self.tyPrim(.u8) };
        const name = try self.freshName("__sel_sp_");
        const addr = try self.slotOffsetBorrow(slots_name, slots_ty, offset);
        try out.append(try self.letNode(name, borrow_ty, addr));
        return try self.identNode(name, borrow_ty);
    }

    /// Call-site form of a select slot address for sa_mem_copy:
    /// a borrow expression over the slot-pointer binding. The SA
    /// text verifier takes the capability from the call-site `&`
    /// prefix (a bare register reads as a by-value pointer pass
    /// and is rejected for `&ptr` parameters), so the operand must
    /// be a borrow node — the same shape the plain chan send/recv
    /// copies use. The SAB side materializes it identically.
    fn slotPtrArg(self: *Lowerer, out: *std.array_list.Managed(*ast.Node), slots_name: []const u8, slots_ty: *ast.Type, offset: usize) LowerError!*ast.Node {
        const ident = try self.slotPtrLet(out, slots_name, slots_ty, offset);
        return try self.borrowNode(ident, try self.tyPrim(.u8));
    }

    fn lowerSelect(self: *Lowerer, stmt: *ast.Node, out: *std.array_list.Managed(*ast.Node)) LowerError!void {
        const sel = stmt.select_stmt;
        const n = sel.cases.len;

        // Entry evaluation in arm order: bind handles and send payloads.
        var handle_names = std.array_list.Managed([]const u8).init(self.allocator);
        defer handle_names.deinit();
        var send_binds = std.array_list.Managed(?[]const u8).init(self.allocator);
        defer send_binds.deinit();
        for (sel.cases) |case| {
            const info = self.tc.chan_calls.get(case.call) orelse
                return self.fail("internal: select case was not recorded by the checker", .{});
            const call = case.call.call_expr;
            const h_name = try self.freshName("__sel_h_");
            try out.append(try self.letNode(h_name, try self.tyPrim(.u64), call.args[0]));
            try handle_names.append(h_name);
            if (info.kind == .send) {
                // Stage the payload in a payload-typed binding
                // for every kind; word payloads are moved into
                // their slot through the A-form view at slot
                // staging time (see storeSlotValueViaView).
                const sv_name = try self.freshName("__sel_sv_");
                try out.append(try self.letNode(sv_name, info.payload_ty, call.args[1]));
                try send_binds.append(sv_name);
            } else {
                try send_binds.append(null);
            }
        }

        // Handles / ops arrays.
        const handles_name = try self.freshName("__sel_handles_");
        try self.noteAllocLet(handles_name);
        {
            const elems = try self.allocator.alloc(*ast.Node, n);
            for (handle_names.items, 0..) |h_name, i| {
                elems[i] = try self.identNode(h_name, try self.tyPrim(.u64));
            }
            const arr = try self.newNode(.{ .array_literal = .{ .elements = elems } });
            const arr_ty = try self.tyArrayOf(try self.tyPrim(.u64), n);
            self.registerType(arr, arr_ty);
            try out.append(try self.letNode(handles_name, arr_ty, arr));
        }
        const ops_name = try self.freshName("__sel_ops_");
        try self.noteAllocLet(ops_name);
        {
            const elems = try self.allocator.alloc(*ast.Node, n);
            for (sel.cases, 0..) |case, i| {
                const info = self.tc.chan_calls.get(case.call) orelse return self.fail("internal: select case was not recorded by the checker", .{});
                elems[i] = try self.intNodeAs(if (info.kind == .send) 1 else 0, .u32);
            }
            const arr = try self.newNode(.{ .array_literal = .{ .elements = elems } });
            const arr_ty = try self.tyArrayOf(try self.tyPrim(.u32), n);
            self.registerType(arr, arr_ty);
            try out.append(try self.letNode(ops_name, arr_ty, arr));
        }

        // Flat slot array; stage send payloads into their slots.
        const slots_name = try self.freshName("__sel_slots_");
        const slots_ty = try self.tyArrayOf(try self.tyPrim(.u8), 16 * n);
        try out.append(try self.slotArrayNode(slots_name, 16 * n));
        for (sel.cases, 0..) |case, i| {
            if (send_binds.items[i]) |sv_name| {
                const info = self.tc.chan_calls.get(case.call) orelse return self.fail("internal: select case was not recorded by the checker", .{});
                if (self.payloadIsWord(info.payload_ty)) {
                    // A form, mirroring emitChanCall's send:
                    // view the arm's slot, move the staged
                    // payload into the view field, forget the
                    // view borrow.
                    const slot_ptr = try self.slotPtrLet(out, slots_name, slots_ty, 16 * i);
                    try self.storeSlotValueViaView(out, slot_ptr, info.payload_ty, try self.identNode(sv_name, info.payload_ty));
                } else {
                    const size = try self.payloadSize(info.payload_ty);
                    const dst = try self.slotPtrArg(out, slots_name, slots_ty, 16 * i);
                    const src = try self.borrowNode(try self.identNode(sv_name, info.payload_ty), info.payload_ty);
                    try self.emitMemCopy(out, dst, src, size);
                }
            }
        }

        // The select call.
        const idx_name = try self.freshName("__sel_idx_");
        try out.append(try self.letNode(idx_name, try self.tyPrim(.i64), try self.intNode(0)));
        const closed_name = try self.freshName("__sel_closed_");
        try out.append(try self.letNode(closed_name, try self.tyPrim(.u32), try self.intNode(0)));
        const rc_name = try self.freshName("__sel_rc_");
        {
            const args = try self.allocator.alloc(*ast.Node, 8);
            args[0] = try self.borrowNode(try self.identNode(handles_name, try self.tyArrayOf(try self.tyPrim(.u64), n)), try self.tyArrayOf(try self.tyPrim(.u64), n));
            args[1] = try self.borrowNode(try self.identNode(ops_name, try self.tyArrayOf(try self.tyPrim(.u32), n)), try self.tyArrayOf(try self.tyPrim(.u32), n));
            args[2] = try self.borrowNode(try self.identNode(slots_name, slots_ty), slots_ty);
            args[3] = try self.intNode(@intCast(n));
            args[4] = try self.intNodeAs(if (sel.default_body != null) 1 else 0, .u32);
            args[5] = if (sel.timeout_expr) |timeout_expr| timeout_expr else try self.intNode(-1);
            args[6] = try self.borrowNode(try self.identNode(idx_name, try self.tyPrim(.i64)), try self.tyPrim(.i64));
            args[7] = try self.borrowNode(try self.identNode(closed_name, try self.tyPrim(.u32)), try self.tyPrim(.u32));
            const select_call = try self.externCallNode("sa_chan_select", args, try self.tyPrim(.i32));
            try out.append(try self.letNode(rc_name, try self.tyPrim(.i32), select_call));
        }
        try self.emitRcCheck(out, rc_name, 60916);

        // Dispatch chain, built from the last branch backwards.
        const Branch = struct { value: i64, body: []const *ast.Node };
        var branches = std.array_list.Managed(Branch).init(self.allocator);
        defer branches.deinit();
        if (sel.timeout_body) |timeout_body| {
            try branches.append(.{ .value = -2, .body = try self.lowerBlock(timeout_body) });
        }
        if (sel.default_body) |default_body| {
            try branches.append(.{ .value = -1, .body = try self.lowerBlock(default_body) });
        }
        for (sel.cases, 0..) |case, i| {
            const info = self.tc.chan_calls.get(case.call) orelse return self.fail("internal: select case was not recorded by the checker", .{});
            var body = std.array_list.Managed(*ast.Node).init(self.allocator);
            errdefer body.deinit();
            if (info.kind == .recv) {
                // Bind the arm's name to the payload reinterpreted
                // in place in the select slot region: no payload
                // var (aggregate vars are scalar-only in the
                // checker and misallocated by the SAB var path)
                // and no whole-var move (StackEscape on text).
                if (case.bind_name) |bind_name| {
                    const slot_ptr = try self.slotPtrLet(&body, slots_name, slots_ty, 16 * i);
                    const sv = try self.slotValueFromPtrFull(&body, slot_ptr, info.payload_ty);
                    try body.append(try self.letNode(bind_name, info.payload_ty, sv.expr));
                    // Retire the view borrow like the plain recv
                    // binding does (its register otherwise stays
                    // live at fn exit in the text codegen).
                    if (sv.ref_name) |ref_name| {
                        try body.append(try self.forgetStmt(ref_name, sv.ref_ty.?));
                    }
                }
                if (case.bind_closed) |bind_closed| {
                    const closed_ident = try self.identNode(closed_name, try self.tyPrim(.u32));
                    const closed_expr = try self.newNode(.{ .binary_expr = .{ .op = .ne, .left = closed_ident, .right = try self.intNode(0) } });
                    self.registerType(closed_expr, try self.tyPrim(.boolean));
                    try body.append(try self.letNode(bind_closed, try self.tyPrim(.boolean), closed_expr));
                }
            }
            const lowered_body = try self.lowerBlock(case.body);
            for (lowered_body) |body_stmt| try body.append(body_stmt);
            try branches.append(.{ .value = @intCast(i), .body = try body.toOwnedSlice() });
        }
        var else_block: ?[]const *ast.Node = null;
        var bi: usize = branches.items.len;
        while (bi > 0) {
            bi -= 1;
            const branch = branches.items[bi];
            const idx_ident = try self.identNode(idx_name, try self.tyPrim(.i64));
            const cond = try self.newNode(.{ .binary_expr = .{ .op = .eq, .left = idx_ident, .right = try self.intNode(branch.value) } });
            self.registerType(cond, try self.tyPrim(.boolean));
            const if_node = try self.newNode(.{ .if_expr = .{
                .cond = cond,
                .then_block = branch.body,
                .else_block = else_block,
            } });
            self.registerType(if_node, try self.tyPrim(.void_type));
            const if_stmt = try self.newNode(.{ .expr_stmt = if_node });
            const chain = try self.allocator.alloc(*ast.Node, 1);
            chain[0] = if_stmt;
            else_block = chain;
        }
        if (else_block) |chain| {
            for (chain) |chain_stmt| try out.append(chain_stmt);
        }
    }
};
