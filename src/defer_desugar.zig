//! Pre-monomorphize desugar for `defer` (goroutine syntax batch P3).
//!
//! Runs in runSlaFrontend after import expansion and before
//! monomorphization, so the checker and both codegens never see a
//! defer_stmt (any survivor is a loud error in syntax_lowering).
//!
//! Semantics (DESIGN section 5): a defer registers its call for the
//! enclosing BLOCK. Arguments (including a method receiver) are
//! snapshotted into synthetic lets at the defer statement — Go's
//! evaluate-at-defer rule — and copies of the call run, last-in
//! first-out, at every block exit the desugar can see: block
//! fallthrough, `return`, and `break`/`continue` crossing the block.
//! Defers do NOT run on `?`-propagation exits or on panic/trap: the
//! goroutine boundary rescue discards the stack without unwinding,
//! and cleanup after a trap belongs to supervision, not to defer.
//!
//! Macro bodies are transformed as independent root scopes (a
//! documented approximation: a defer inside a macro body binds to
//! the macro body's own blocks, not the expansion site's).

const std = @import("std");
const ast = @import("ast.zig");

pub const DesugarError = error{ DesugarFailed, OutOfMemory };

pub const Desugarer = struct {
    allocator: std.mem.Allocator,
    counter: usize = 0,
    err_buf: [512]u8 = undefined,
    err_len: usize = 0,

    pub fn init(allocator: std.mem.Allocator) Desugarer {
        return .{ .allocator = allocator };
    }

    pub fn errorMessage(self: *const Desugarer) []const u8 {
        return self.err_buf[0..self.err_len];
    }

    fn fail(self: *Desugarer, comptime fmt: []const u8, args: anytype) DesugarError {
        const msg = std.fmt.bufPrint(&self.err_buf, fmt, args) catch "defer desugar failed";
        self.err_len = msg.len;
        return error.DesugarFailed;
    }

    fn newNode(self: *Desugarer, value: ast.Node) !*ast.Node {
        const node = try self.allocator.create(ast.Node);
        node.* = value;
        return node;
    }

    fn freshName(self: *Desugarer, prefix: []const u8) ![]const u8 {
        self.counter += 1;
        return try std.fmt.allocPrint(self.allocator, "{s}{d}", .{ prefix, self.counter });
    }

    pub fn desugarProgram(self: *Desugarer, program: *ast.Node) DesugarError!void {
        for (program.program.decls) |decl| {
            switch (decl.*) {
                .func_decl => decl.func_decl.body = try self.processBlock(decl.func_decl.body, &.{}),
                .test_decl => decl.test_decl.body = try self.processBlock(decl.test_decl.body, &.{}),
                .impl_decl => {
                    for (decl.impl_decl.methods) |method| {
                        if (method.* == .func_decl) {
                            method.func_decl.body = try self.processBlock(method.func_decl.body, &.{});
                        }
                    }
                },
                .macro_decl => decl.macro_decl.body = try self.processBlock(decl.macro_decl.body, &.{}),
                else => {},
            }
        }
    }

    /// One block's registered defer calls (snapshot form), in
    /// registration order.
    const DeferList = std.array_list.Managed(*ast.Node);

    /// Process one statement list. `outer` is the chain of defer
    /// lists of enclosing blocks within the current loop body (or
    /// the whole function outside loops), innermost last; `return`
    /// runs the whole chain, break/continue run the whole chain too
    /// (the chain is reset at loop boundaries by the caller).
    fn processBlock(self: *Desugarer, stmts: []const *ast.Node, outer: []const DeferList) DesugarError![]const *ast.Node {
        var out = std.array_list.Managed(*ast.Node).init(self.allocator);
        errdefer out.deinit();
        var defers = DeferList.init(self.allocator);
        defer defers.deinit();
        var chain = std.array_list.Managed(DeferList).init(self.allocator);
        defer chain.deinit();
        for (outer) |list| try chain.append(list);
        try chain.append(defers);

        var last_was_exit = false;
        for (stmts) |stmt| {
            last_was_exit = false;
            switch (stmt.*) {
                .defer_stmt => |defer_stmt| {
                    const snapshot = try self.snapshotCall(defer_stmt.call, &out);
                    try defers.append(snapshot);
                    // chain holds a COPY of the list header from
                    // before this append; refresh the tail entry.
                    chain.items[chain.items.len - 1] = defers;
                },
                .return_stmt => |ret| {
                    // Go semantics: the return value is evaluated
                    // BEFORE deferred calls run. Snapshot it first
                    // when this exit path has any defers to run.
                    var has_defers = false;
                    for (chain.items) |list| {
                        if (list.items.len > 0) has_defers = true;
                    }
                    if (has_defers) {
                        if (ret.value) |value| {
                            if (value.* != .identifier and value.* != .literal) {
                                const name = try self.freshName("__dfret_");
                                try out.append(try self.newNode(.{ .let_stmt = .{ .name = name, .ty = null, .value = value } }));
                                const ident = try self.newNode(.{ .identifier = name });
                                const ret_copy = try self.newNode(.{ .return_stmt = .{ .value = ident } });
                                try self.emitDefers(&out, chain.items);
                                try out.append(ret_copy);
                                last_was_exit = true;
                                continue;
                            }
                        }
                    }
                    try self.emitDefers(&out, chain.items);
                    try out.append(stmt);
                    last_was_exit = true;
                },
                .break_stmt, .continue_stmt => {
                    try self.emitDefers(&out, chain.items);
                    try out.append(stmt);
                    last_was_exit = true;
                },
                else => {
                    try self.processStmtChildren(stmt, chain.items);
                    try out.append(stmt);
                },
            }
        }
        // Block fallthrough: this block's own defers run (enclosing
        // blocks run at their own exits). Skipped when the last
        // statement already exited the block.
        if (!last_was_exit) {
            var own = std.array_list.Managed(DeferList).init(self.allocator);
            defer own.deinit();
            try own.append(defers);
            try self.emitDefers(&out, own.items);
        }
        return try out.toOwnedSlice();
    }

    /// Emit copies of every defer in the chain, innermost block
    /// first, LIFO within each block.
    fn emitDefers(self: *Desugarer, out: *std.array_list.Managed(*ast.Node), chain: []const DeferList) DesugarError!void {
        var ci: usize = chain.len;
        while (ci > 0) {
            ci -= 1;
            const list = chain[ci];
            var di: usize = list.items.len;
            while (di > 0) {
                di -= 1;
                const copy = try self.cloneExpr(list.items[di]);
                try out.append(try self.newNode(.{ .expr_stmt = copy }));
            }
        }
    }

    /// Snapshot a defer call's arguments at the defer statement:
    /// each argument becomes a synthetic let, and the registered
    /// call is rebuilt over the snapshot identifiers.
    fn snapshotCall(self: *Desugarer, call_node: *ast.Node, out: *std.array_list.Managed(*ast.Node)) DesugarError!*ast.Node {
        if (call_node.* != .call_expr) return self.fail("defer operand is not a call expression", .{});
        const call = call_node.call_expr;
        const new_args = try self.allocator.alloc(*ast.Node, call.args.len);
        for (call.args, 0..) |arg, i| {
            const name = try self.freshName("__dfa_");
            try out.append(try self.newNode(.{ .let_stmt = .{ .name = name, .ty = null, .value = arg } }));
            new_args[i] = try self.newNode(.{ .identifier = name });
        }
        var callee_copy: ?*ast.Node = null;
        if (call.callee) |callee| callee_copy = try self.cloneExpr(callee);
        return try self.newNode(.{ .call_expr = .{
            .func_name = call.func_name,
            .associated_target = call.associated_target,
            .generics = call.generics,
            .args = new_args,
            .callee = callee_copy,
        } });
    }

    /// Recurse into a statement's nested blocks and expressions.
    /// Loop bodies reset the defer chain: a break inside the loop
    /// crosses only blocks within the loop body; defers registered
    /// outside the loop run when the loop's enclosing block exits.
    fn processStmtChildren(self: *Desugarer, stmt: *ast.Node, chain: []const DeferList) DesugarError!void {
        switch (stmt.*) {
            .block_stmt => stmt.block_stmt.body = try self.processBlock(stmt.block_stmt.body, chain),
            .while_stmt => {
                try self.processExpr(stmt.while_stmt.cond, chain);
                stmt.while_stmt.body = try self.processBlock(stmt.while_stmt.body, &.{});
            },
            .for_stmt => {
                try self.processExpr(stmt.for_stmt.start, chain);
                if (stmt.for_stmt.end) |end| try self.processExpr(end, chain);
                stmt.for_stmt.body = try self.processBlock(stmt.for_stmt.body, &.{});
            },
            .let_stmt => try self.processExpr(stmt.let_stmt.value, chain),
            .let_else_stmt => {
                try self.processExpr(stmt.let_else_stmt.value, chain);
                stmt.let_else_stmt.else_block = try self.processBlock(stmt.let_else_stmt.else_block, chain);
            },
            .let_destructure_stmt => try self.processExpr(stmt.let_destructure_stmt.value, chain),
            .const_stmt => try self.processExpr(stmt.const_stmt.value, chain),
            .assign_stmt => {
                try self.processExpr(stmt.assign_stmt.target, chain);
                try self.processExpr(stmt.assign_stmt.value, chain);
            },
            .return_stmt => if (stmt.return_stmt.value) |value| try self.processExpr(value, chain),
            .expr_stmt => try self.processExpr(stmt.expr_stmt, chain),
            else => {},
        }
    }

    /// Process statement lists nested inside an expression (if/match
    /// bodies and friends). Defers registered there bind to those
    /// blocks; returns and breaks inside them cross the expression
    /// block first, so the chain passes through.
    fn processExpr(self: *Desugarer, expr: *ast.Node, chain: []const DeferList) DesugarError!void {
        switch (expr.*) {
            .if_expr => {
                try self.processExpr(expr.if_expr.cond, chain);
                expr.if_expr.then_block = try self.processBlock(expr.if_expr.then_block, chain);
                if (expr.if_expr.else_block) |else_block| {
                    expr.if_expr.else_block = try self.processBlock(else_block, chain);
                }
            },
            .switch_expr => {
                try self.processExpr(expr.switch_expr.val, chain);
                const cases = try self.allocator.alloc(ast.Case, expr.switch_expr.cases.len);
                for (expr.switch_expr.cases, 0..) |case, i| {
                    cases[i] = case;
                    cases[i].body = try self.processBlock(case.body, chain);
                }
                expr.switch_expr.cases = cases;
            },
            .match_expr => {
                try self.processExpr(expr.match_expr.val, chain);
                const cases = try self.allocator.alloc(ast.MatchCase, expr.match_expr.cases.len);
                for (expr.match_expr.cases, 0..) |case, i| {
                    cases[i] = case;
                    if (case.guard) |guard| try self.processExpr(guard, chain);
                    cases[i].body = try self.processBlock(case.body, chain);
                }
                expr.match_expr.cases = cases;
            },
            .unsafe_expr => expr.unsafe_expr.body = try self.processBlock(expr.unsafe_expr.body, chain),
            .closure_literal => {
                // A defer inside a closure body binds to the closure's
                // own scope chain, not the enclosing function's.
                expr.closure_literal.body = try self.processClosureBody(expr.closure_literal.body);
            },
            .call_expr => {
                if (expr.call_expr.callee) |callee| try self.processExpr(callee, chain);
                for (expr.call_expr.args) |arg| try self.processExpr(arg, chain);
            },
            .binary_expr => {
                try self.processExpr(expr.binary_expr.left, chain);
                try self.processExpr(expr.binary_expr.right, chain);
            },
            .await_expr => try self.processExpr(expr.await_expr.expr, chain),
            .try_expr => try self.processExpr(expr.try_expr.expr, chain),
            .borrow_expr => try self.processExpr(expr.borrow_expr.expr, chain),
            .move_expr => try self.processExpr(expr.move_expr.expr, chain),
            .deref_expr => try self.processExpr(expr.deref_expr.expr, chain),
            .cast_expr => try self.processExpr(expr.cast_expr.expr, chain),
            .field_expr => try self.processExpr(expr.field_expr.expr, chain),
            .struct_literal => {
                for (expr.struct_literal.fields) |field| try self.processExpr(field.value, chain);
                if (expr.struct_literal.update_expr) |update| try self.processExpr(update, chain);
            },
            .enum_literal => for (expr.enum_literal.fields) |field| try self.processExpr(field.value, chain),
            .tuple_literal => for (expr.tuple_literal.elements) |elem| try self.processExpr(elem, chain),
            .array_literal => for (expr.array_literal.elements) |elem| try self.processExpr(elem, chain),
            .repeat_array_literal => try self.processExpr(expr.repeat_array_literal.value, chain),
            .index_expr => {
                try self.processExpr(expr.index_expr.target, chain);
                try self.processExpr(expr.index_expr.index, chain);
            },
            .slice_expr => {
                try self.processExpr(expr.slice_expr.target, chain);
                try self.processExpr(expr.slice_expr.start, chain);
                try self.processExpr(expr.slice_expr.end, chain);
            },
            else => {},
        }
    }

    fn processClosureBody(self: *Desugarer, body: *ast.Node) DesugarError!*ast.Node {
        // Closure bodies are single expressions; a defer can only
        // hide inside a nested block expression, which processBlock
        // handles with a fresh chain via processExpr's unsafe/if
        // arms. The body itself is processed with an empty chain.
        try self.processExpr(body, &.{});
        return body;
    }

    /// Deep-copy an expression node (defer call templates are
    /// emitted once per exit path). Types are shared (immutable);
    /// nodes are always fresh.
    fn cloneExpr(self: *Desugarer, node: *ast.Node) DesugarError!*ast.Node {
        const copy = try self.allocator.create(ast.Node);
        switch (node.*) {
            .literal, .identifier, .generic_func_ref => copy.* = node.*,
            .call_expr => |call| {
                const args = try self.allocator.alloc(*ast.Node, call.args.len);
                for (call.args, 0..) |arg, i| args[i] = try self.cloneExpr(arg);
                copy.* = .{ .call_expr = .{
                    .func_name = call.func_name,
                    .associated_target = call.associated_target,
                    .generics = call.generics,
                    .args = args,
                    .callee = if (call.callee) |callee| try self.cloneExpr(callee) else null,
                } };
            },
            .binary_expr => |bin| copy.* = .{ .binary_expr = .{ .op = bin.op, .left = try self.cloneExpr(bin.left), .right = try self.cloneExpr(bin.right) } },
            .borrow_expr => |b| copy.* = .{ .borrow_expr = .{ .expr = try self.cloneExpr(b.expr) } },
            .move_expr => |m| copy.* = .{ .move_expr = .{ .expr = try self.cloneExpr(m.expr) } },
            .deref_expr => |d| copy.* = .{ .deref_expr = .{ .expr = try self.cloneExpr(d.expr) } },
            .cast_expr => |c| copy.* = .{ .cast_expr = .{ .expr = try self.cloneExpr(c.expr), .ty = c.ty } },
            .field_expr => |f| copy.* = .{ .field_expr = .{ .expr = try self.cloneExpr(f.expr), .field_name = f.field_name } },
            .index_expr => |ix| copy.* = .{ .index_expr = .{ .target = try self.cloneExpr(ix.target), .index = try self.cloneExpr(ix.index) } },
            .slice_expr => |s| copy.* = .{ .slice_expr = .{ .target = try self.cloneExpr(s.target), .start = try self.cloneExpr(s.start), .end = try self.cloneExpr(s.end) } },
            .tuple_literal => |t| {
                const elems = try self.allocator.alloc(*ast.Node, t.elements.len);
                for (t.elements, 0..) |elem, i| elems[i] = try self.cloneExpr(elem);
                copy.* = .{ .tuple_literal = .{ .elements = elems } };
            },
            .array_literal => |a| {
                const elems = try self.allocator.alloc(*ast.Node, a.elements.len);
                for (a.elements, 0..) |elem, i| elems[i] = try self.cloneExpr(elem);
                copy.* = .{ .array_literal = .{ .elements = elems } };
            },
            .repeat_array_literal => |r| copy.* = .{ .repeat_array_literal = .{ .value = try self.cloneExpr(r.value), .len = r.len } },
            .struct_literal => |s| {
                const fields = try self.allocator.alloc(ast.StructLiteralField, s.fields.len);
                for (s.fields, 0..) |field, i| {
                    fields[i] = .{ .name = field.name, .value = try self.cloneExpr(field.value) };
                }
                copy.* = .{ .struct_literal = .{ .ty = s.ty, .fields = fields, .update_expr = if (s.update_expr) |u| try self.cloneExpr(u) else null } };
            },
            .enum_literal => |e| {
                const fields = try self.allocator.alloc(ast.EnumLiteralField, e.fields.len);
                for (e.fields, 0..) |field, i| {
                    fields[i] = .{ .name = field.name, .value = try self.cloneExpr(field.value) };
                }
                copy.* = .{ .enum_literal = .{ .enum_name = e.enum_name, .variant_name = e.variant_name, .fields = fields } };
            },
            .try_expr => |t| copy.* = .{ .try_expr = .{ .expr = try self.cloneExpr(t.expr) } },
            .await_expr => |a| copy.* = .{ .await_expr = .{ .expr = try self.cloneExpr(a.expr) } },
            else => return self.fail("defer: argument expression of this shape cannot be deferred in this batch", .{}),
        }
        return copy;
    }
};
