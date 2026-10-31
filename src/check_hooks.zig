//! J-5 (independent check hooks, Jev slasl_macro_ruling j5 =
//! independent_check_hooks): a registry of named, read-only checker
//! hooks. A source file attaches one with `@check_hook <name>;`.
//! A hook receives the fully checked program (the TypeChecker plus
//! the AST) and may only emit a named diagnostic — the interface
//! hands it no writer into the AST, the checker state, or codegen,
//! so transformation is impossible by construction.
//!
//! Built-in hook: `macro_param_audit` — every parameter of every
//! user macro in the file must be referenced in the macro body
//! (MacroParamUnused). The reference walk is scope-aware: a
//! macro-local binding of the same name shadows the parameter from
//! its declaration point to the end of its block. Node kinds the
//! walk does not understand mark the analysis "unknown", and the
//! hook then stays silent for that macro — it never fires on a
//! guess.

const std = @import("std");
const ast = @import("ast.zig");
const type_checker = @import("type_checker.zig");

pub const Diagnostic = struct {
    text: []const u8 = "",
};

pub const HookError = error{ HookDiagnostic, OutOfMemory };

pub const HookFn = *const fn (tc: *type_checker.TypeChecker, program: *const ast.Node, diag: *Diagnostic) HookError!void;

pub fn lookup(name: []const u8) ?HookFn {
    if (std.mem.eql(u8, name, "macro_param_audit")) return macroParamAudit;
    return null;
}

fn macroParamAudit(tc: *type_checker.TypeChecker, program: *const ast.Node, diag: *Diagnostic) HookError!void {
    _ = program;
    var it = tc.macros.valueIterator();
    while (it.next()) |mac_ptr| {
        const mac = mac_ptr.*;
        if (mac.params.len == 0) continue;
        const used = tc.allocator.alloc(bool, mac.params.len) catch return error.OutOfMemory;
        @memset(used, false);
        var walker = Walker{
            .allocator = tc.allocator,
            .param_names = mac.params,
            .used = used,
            .shadow = std.array_list.Managed([]const u8).init(tc.allocator),
        };
        walker.walkStmts(mac.body);
        if (walker.unknown) continue;
        for (mac.params, 0..) |param, i| {
            if (!used[i]) {
                diag.text = std.fmt.allocPrint(tc.allocator, "MacroParamUnused: parameter `{s}` of macro `{s}` is never referenced in the macro body", .{ param, mac.name }) catch return error.OutOfMemory;
                return error.HookDiagnostic;
            }
        }
    }
}

const Walker = struct {
    allocator: std.mem.Allocator,
    param_names: []const []const u8,
    used: []bool,
    shadow: std.array_list.Managed([]const u8),
    unknown: bool = false,

    fn note(self: *Walker, name: []const u8) void {
        for (self.shadow.items) |shadowed| {
            if (std.mem.eql(u8, shadowed, name)) return;
        }
        for (self.param_names, 0..) |param, i| {
            if (std.mem.eql(u8, param, name)) {
                self.used[i] = true;
                return;
            }
        }
    }

    fn pushShadow(self: *Walker, name: []const u8) void {
        self.shadow.append(name) catch {
            self.unknown = true;
        };
    }

    fn walkStmts(self: *Walker, stmts: []const *ast.Node) void {
        const mark = self.shadow.items.len;
        for (stmts) |stmt| self.walkNode(stmt);
        self.shadow.shrinkRetainingCapacity(mark);
    }

    fn walkNode(self: *Walker, node: *const ast.Node) void {
        switch (node.*) {
            // Statements
            .let_stmt => |let_stmt| {
                self.walkNode(let_stmt.value);
                self.pushShadow(let_stmt.name);
            },
            .const_stmt => |const_stmt| {
                self.walkNode(const_stmt.value);
                self.pushShadow(const_stmt.name);
            },
            .var_stmt => |var_stmt| self.pushShadow(var_stmt.name),
            .let_destructure_stmt => |destructure| {
                self.walkNode(destructure.value);
                for (destructure.names) |name| self.pushShadow(name);
                if (destructure.rest_name) |name| self.pushShadow(name);
                if (destructure.rest_alias) |name| self.pushShadow(name);
            },
            .let_else_stmt => |let_else| {
                self.walkNode(let_else.value);
                self.walkStmts(let_else.else_block);
                for (let_else.pattern.bindings) |name| self.pushShadow(name);
            },
            .assign_stmt => |assign| {
                self.walkNode(assign.target);
                self.walkNode(assign.value);
            },
            .block_stmt => |block| self.walkStmts(block.body),
            .expr_stmt => |inner| self.walkNode(inner),
            .return_stmt => |ret| {
                if (ret.value) |value| self.walkNode(value);
            },
            .for_stmt => |for_stmt| {
                self.walkNode(for_stmt.start);
                if (for_stmt.end) |end| self.walkNode(end);
                const mark = self.shadow.items.len;
                self.pushShadow(for_stmt.var_name);
                self.walkStmts(for_stmt.body);
                self.shadow.shrinkRetainingCapacity(mark);
            },
            .while_stmt => |while_stmt| {
                self.walkNode(while_stmt.cond);
                const mark = self.shadow.items.len;
                if (while_stmt.let_pattern) |pattern| {
                    for (pattern.bindings) |name| self.pushShadow(name);
                }
                self.walkStmts(while_stmt.body);
                self.shadow.shrinkRetainingCapacity(mark);
            },
            .break_stmt, .continue_stmt => {},
            .release_stmt => |release| self.note(release.var_name),
            .defer_stmt => |defer_stmt| self.walkNode(defer_stmt.call),
            .select_stmt => |select| {
                if (select.timeout_expr) |timeout| self.walkNode(timeout);
                for (select.cases) |case| {
                    self.walkNode(case.call);
                    const mark = self.shadow.items.len;
                    if (case.bind_name) |name| self.pushShadow(name);
                    if (case.bind_closed) |name| self.pushShadow(name);
                    self.walkStmts(case.body);
                    self.shadow.shrinkRetainingCapacity(mark);
                }
                if (select.default_body) |body| self.walkStmts(body);
                if (select.timeout_body) |body| self.walkStmts(body);
            },
            // Expressions
            .literal => {},
            .identifier => |name| self.note(name),
            .generic_func_ref => {},
            .go_expr => |go| self.walkNode(go.call),
            .if_expr => |if_expr| {
                self.walkNode(if_expr.cond);
                if (if_expr.let_chain) |chain| {
                    for (chain) |cond| self.walkNode(cond.value);
                }
                self.walkStmts(if_expr.then_block);
                if (if_expr.else_block) |else_block| self.walkStmts(else_block);
            },
            .switch_expr => |switch_expr| {
                self.walkNode(switch_expr.val);
                for (switch_expr.cases) |case| self.walkStmts(case.body);
            },
            .match_expr => |match_expr| {
                self.walkNode(match_expr.val);
                for (match_expr.cases) |case| {
                    const mark = self.shadow.items.len;
                    for (case.pattern.bindings) |name| self.pushShadow(name);
                    if (case.guard) |guard| self.walkNode(guard);
                    self.walkStmts(case.body);
                    self.shadow.shrinkRetainingCapacity(mark);
                }
            },
            .unsafe_expr => |unsafe_expr| self.walkStmts(unsafe_expr.body),
            .await_expr => |await_expr| self.walkNode(await_expr.expr),
            .inline_asm_expr => |asm_expr| {
                for (asm_expr.operands) |operand| self.note(operand.var_name);
            },
            .binary_expr => |binary| {
                self.walkNode(binary.left);
                self.walkNode(binary.right);
            },
            .call_expr => |call| {
                if (call.callee) |callee| self.walkNode(callee);
                for (call.args) |arg| self.walkNode(arg);
            },
            .closure_literal => |closure| {
                const mark = self.shadow.items.len;
                for (closure.params) |param| self.pushShadow(param.name);
                self.walkNode(closure.body);
                self.shadow.shrinkRetainingCapacity(mark);
            },
            .borrow_expr => |borrow| self.walkNode(borrow.expr),
            .move_expr => |move| self.walkNode(move.expr),
            .deref_expr => |deref| self.walkNode(deref.expr),
            .cast_expr => |cast| self.walkNode(cast.expr),
            .field_expr => |field| self.walkNode(field.expr),
            .struct_literal => |literal| {
                for (literal.fields) |field| self.walkNode(field.value);
                if (literal.update_expr) |update| self.walkNode(update);
            },
            .enum_literal => |literal| {
                for (literal.fields) |field| self.walkNode(field.value);
            },
            .tuple_literal => |literal| {
                for (literal.elements) |elem| self.walkNode(elem);
            },
            .array_literal => |literal| {
                for (literal.elements) |elem| self.walkNode(elem);
            },
            .repeat_array_literal => |literal| self.walkNode(literal.value),
            .index_expr => |index| {
                self.walkNode(index.target);
                self.walkNode(index.index);
            },
            .slice_expr => |slice| {
                self.walkNode(slice.target);
                self.walkNode(slice.start);
                self.walkNode(slice.end);
            },
            .try_expr => |try_expr| self.walkNode(try_expr.expr),
            // Anything else (declarations and any future node kind):
            // the analysis is incomplete, so the hook stays silent
            // for this macro rather than firing on a guess.
            else => self.unknown = true,
        }
    }
};
