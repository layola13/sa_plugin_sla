const std = @import("std");
const ast = @import("ast.zig");
const type_checker = @import("type_checker.zig");

pub const CodegenError = error{
    CodegenError,
    OutOfMemory,
};

pub const Codegen = struct {
    allocator: std.mem.Allocator,
    tc: *type_checker.TypeChecker,
    out: std.ArrayList(u8),
    tmp_idx: usize,
    label_idx: usize,
    string_idx: usize,
    macro_local_idx: usize,
    macro_locals: std.StringHashMap([]const u8),
    closure_bindings: std.StringHashMap(*const ast.ClosureLiteral),
    closure_param_regs: std.StringHashMap([]const u8),
    stack_alloc_bindings: std.StringHashMap(void),
    current_async: bool,

    pub fn init(allocator: std.mem.Allocator, tc: *type_checker.TypeChecker) Codegen {
        return .{
            .allocator = allocator,
            .tc = tc,
            .out = std.ArrayList(u8).init(allocator),
            .tmp_idx = 0,
            .label_idx = 0,
            .string_idx = 0,
            .macro_local_idx = 0,
            .macro_locals = std.StringHashMap([]const u8).init(allocator),
            .closure_bindings = std.StringHashMap(*const ast.ClosureLiteral).init(allocator),
            .closure_param_regs = std.StringHashMap([]const u8).init(allocator),
            .stack_alloc_bindings = std.StringHashMap(void).init(allocator),
            .current_async = false,
        };
    }

    pub fn deinit(self: *Codegen) void {
        self.out.deinit();
        var val_iter = self.macro_locals.valueIterator();
        while (val_iter.next()) |v| {
            self.allocator.free(v.*);
        }
        self.macro_locals.deinit();
        self.closure_bindings.deinit();
        self.closure_param_regs.deinit();
        self.stack_alloc_bindings.deinit();
    }

    fn newTmp(self: *Codegen) CodegenError![]const u8 {
        const name = std.fmt.allocPrint(self.allocator, "tmp_{}", .{self.tmp_idx}) catch return CodegenError.OutOfMemory;
        self.tmp_idx += 1;
        return name;
    }

    fn newLabel(self: *Codegen, prefix: []const u8) CodegenError![]const u8 {
        const name = std.fmt.allocPrint(self.allocator, "{s}_{}", .{ prefix, self.label_idx }) catch return CodegenError.OutOfMemory;
        self.label_idx += 1;
        return name;
    }

    fn newStringConst(self: *Codegen) CodegenError![]const u8 {
        const name = std.fmt.allocPrint(self.allocator, "SLA_STR_{}", .{self.string_idx}) catch return CodegenError.OutOfMemory;
        self.string_idx += 1;
        return name;
    }

    fn newMacroLocal(self: *Codegen, macro_name: []const u8, local_name: []const u8) CodegenError![]const u8 {
        const name = std.fmt.allocPrint(self.allocator, "{s}_{s}_uniq_{}", .{ macro_name, local_name, self.macro_local_idx }) catch return CodegenError.OutOfMemory;
        self.macro_local_idx += 1;
        self.macro_locals.put(local_name, name) catch return CodegenError.OutOfMemory;
        return name;
    }

    fn mangleMethodName(self: *Codegen, ty_name: []const u8, method_name: []const u8) CodegenError![]const u8 {
        _ = ty_name;
        return std.fmt.allocPrint(self.allocator, "{s}", .{method_name}) catch return CodegenError.OutOfMemory;
    }

    fn emitIntConst(self: *Codegen, target: []const u8, value: i64) CodegenError!void {
        self.out.writer().print("    {s} = {}\n", .{ target, value }) catch return CodegenError.CodegenError;
    }

    fn blockTerminates(block: []const *ast.Node) bool {
        if (block.len == 0) return false;
        return stmtTerminates(block[block.len - 1]);
    }

    fn stmtTerminates(stmt: *const ast.Node) bool {
        return switch (stmt.*) {
            .return_stmt => true,
            .expr_stmt => |expr| exprTerminates(expr),
            else => false,
        };
    }

    fn exprTerminates(expr: *const ast.Node) bool {
        return switch (expr.*) {
            .call_expr => |call| std.mem.eql(u8, call.func_name, "panic"),
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

    fn emitRelease(self: *Codegen, name: []const u8) CodegenError!void {
        if (std.mem.eql(u8, name, "return_ty_sentinel")) return;
        if (std.mem.startsWith(u8, name, "&")) return;
        if (std.mem.startsWith(u8, name, "^")) return;
        if (self.stack_alloc_bindings.contains(name)) return;
        self.out.writer().print("    !{s}\n", .{name}) catch return CodegenError.CodegenError;
    }

    fn isVoidCall(self: *Codegen, call: *const ast.CallExpr) bool {
        if (std.mem.eql(u8, call.func_name, "println")) return true;
        if (self.tc.extern_funcs.get(call.func_name)) |ext| {
            return std.mem.eql(u8, std.mem.trim(u8, ext.ret_ty, " \t\r"), "void");
        }
        if (self.tc.funcs.get(call.func_name)) |func| {
            if (func.is_async) return false;
            return isVoidType(func.ret_ty);
        }
        return std.mem.eql(u8, call.func_name, "panic");
    }

    fn genCallStmt(self: *Codegen, call: *const ast.CallExpr, hoisted_allocs: *const std.ArrayList([]const u8)) CodegenError!void {
        if (std.mem.eql(u8, call.func_name, "println")) {
            try self.emitPrintln(call, hoisted_allocs);
            return;
        }
        var arg_regs = std.ArrayList([]const u8).init(self.allocator);
        defer arg_regs.deinit();
        for (call.args) |arg| {
            arg_regs.append(try self.genCallArg(arg, hoisted_allocs)) catch return CodegenError.OutOfMemory;
        }

        self.out.writer().print("    call @{s}(", .{call.func_name}) catch return CodegenError.CodegenError;
        for (arg_regs.items, 0..) |ar, i| {
            if (i > 0) self.out.writer().print(", ", .{}) catch return CodegenError.CodegenError;
            self.out.writer().print("{s}", .{ar}) catch return CodegenError.CodegenError;
        }
        self.out.writer().print(")\n", .{}) catch return CodegenError.CodegenError;
    }

    fn emitPrintln(self: *Codegen, call: *const ast.CallExpr, hoisted_allocs: *const std.ArrayList([]const u8)) CodegenError!void {
        if (call.args.len == 0 or call.args[0].* != .literal or call.args[0].literal != .string_val) {
            self.out.writer().print("    call @sa_print_bytes(\"\\n\", 1)\n", .{}) catch return CodegenError.CodegenError;
            return;
        }

        const fmt = call.args[0].literal.string_val;
        var arg_idx: usize = 1;
        var i: usize = 0;
        while (i <= fmt.len) {
            const start = i;
            while (i < fmt.len and !(fmt[i] == '{' and i + 1 < fmt.len and fmt[i + 1] == '}')) : (i += 1) {}
            if (i > start) {
                const label = try self.newStringConst();
                self.out.writer().print("    @const {s} = utf8:\"{s}\"\n", .{ label, fmt[start..i] }) catch return CodegenError.CodegenError;
                self.out.writer().print("    call @sa_print_bytes(&{s}, {})\n", .{ label, i - start }) catch return CodegenError.CodegenError;
            }
            if (i >= fmt.len) break;
            if (arg_idx >= call.args.len) break;
            const arg = call.args[arg_idx];
            arg_idx += 1;
            const arg_ty = self.tc.expr_types.get(arg);
            if (arg.* == .literal and arg.literal == .string_val) {
                const s = arg.literal.string_val;
                self.out.writer().print("    call @sa_print_bytes(\"{s}\", {})\n", .{ s, s.len }) catch return CodegenError.CodegenError;
            } else if (arg_ty) |ty| switch (ty.*) {
                .primitive => |p| switch (p) {
                    .integer => {
                        const val_reg = try self.genExpr(arg, hoisted_allocs);
                        const fmt_buf = try self.newTmp();
                        const data_reg = try self.newTmp();
                        const len_reg = try self.newTmp();
                        self.out.writer().print("    {s} = call @sa_fmt_i64({s}, 10)\n", .{ fmt_buf, val_reg }) catch return CodegenError.CodegenError;
                        self.out.writer().print("    {s} = call @sa_fmt_buffer_data({s})\n", .{ data_reg, fmt_buf }) catch return CodegenError.CodegenError;
                        self.out.writer().print("    {s} = call @sa_fmt_buffer_len({s})\n", .{ len_reg, fmt_buf }) catch return CodegenError.CodegenError;
                        const ptr_reg = try self.newTmp();
                        self.out.writer().print("    {s} = {s}\n", .{ ptr_reg, data_reg }) catch return CodegenError.CodegenError;
                        self.out.writer().print("    call @sa_print_bytes(&{s}, {s})\n", .{ ptr_reg, len_reg }) catch return CodegenError.CodegenError;
                        self.out.writer().print("    call @sa_fmt_buffer_free(^{s})\n", .{fmt_buf}) catch return CodegenError.CodegenError;
                    },
                    .boolean => {
                        const val_reg = try self.genExpr(arg, hoisted_allocs);
                        const fmt_buf = try self.newTmp();
                        const data_reg = try self.newTmp();
                        const len_reg = try self.newTmp();
                        self.out.writer().print("    {s} = call @sa_fmt_bool({s})\n", .{ fmt_buf, val_reg }) catch return CodegenError.CodegenError;
                        self.out.writer().print("    {s} = call @sa_fmt_buffer_data({s})\n", .{ data_reg, fmt_buf }) catch return CodegenError.CodegenError;
                        self.out.writer().print("    {s} = call @sa_fmt_buffer_len({s})\n", .{ len_reg, fmt_buf }) catch return CodegenError.CodegenError;
                        const ptr_reg = try self.newTmp();
                        self.out.writer().print("    {s} = {s}\n", .{ ptr_reg, data_reg }) catch return CodegenError.CodegenError;
                        self.out.writer().print("    call @sa_print_bytes(&{s}, {s})\n", .{ ptr_reg, len_reg }) catch return CodegenError.CodegenError;
                        self.out.writer().print("    call @sa_fmt_buffer_free(^{s})\n", .{fmt_buf}) catch return CodegenError.CodegenError;
                    },
                    else => {
                        const val_reg = try self.genExpr(arg, hoisted_allocs);
                        const ptr_reg = try self.newTmp();
                        self.out.writer().print("    {s} = {s}\n", .{ ptr_reg, val_reg }) catch return CodegenError.CodegenError;
                        self.out.writer().print("    call @sa_print_bytes(&{s}, 1)\n", .{ptr_reg}) catch return CodegenError.CodegenError;
                    },
                },
                else => {
                    const val_reg = try self.genExpr(arg, hoisted_allocs);
                    const ptr_reg = try self.newTmp();
                    self.out.writer().print("    {s} = {s}\n", .{ ptr_reg, val_reg }) catch return CodegenError.CodegenError;
                    self.out.writer().print("    call @sa_print_bytes(&{s}, 1)\n", .{ptr_reg}) catch return CodegenError.CodegenError;
                },
            } else {
                const val_reg = try self.genExpr(arg, hoisted_allocs);
                const ptr_reg = try self.newTmp();
                self.out.writer().print("    {s} = {s}\n", .{ ptr_reg, val_reg }) catch return CodegenError.CodegenError;
                self.out.writer().print("    call @sa_print_bytes(&{s}, 1)\n", .{ptr_reg}) catch return CodegenError.CodegenError;
            }
            i += 2;
        }
        const nl_label = try self.newStringConst();
        self.out.writer().print("    @const {s} = utf8:\"\\n\"\n", .{ nl_label }) catch return CodegenError.CodegenError;
        self.out.writer().print("    call @sa_print_bytes(&{s}, 1)\n", .{nl_label}) catch return CodegenError.CodegenError;
    }

    fn sanitizeTestName(self: *Codegen, name: []const u8) CodegenError![]const u8 {
        var out = std.ArrayList(u8).init(self.allocator);
        for (name) |c| {
            switch (c) {
                '(', ')' => out.append('-') catch return CodegenError.OutOfMemory,
                '"', '\\', '\n', '\r', '\t' => out.append(' ') catch return CodegenError.OutOfMemory,
                else => out.append(c) catch return CodegenError.OutOfMemory,
            }
        }
        return out.toOwnedSlice() catch return CodegenError.OutOfMemory;
    }

    const FieldLayout = struct {
        offset: usize,
        ty_str: []const u8,
    };

    fn typeSize(ty: *const ast.Type) usize {
        return switch (ty.*) {
            .primitive => |p| switch (p) {
                .boolean => 1,
                .integer => 8,
                .float => 8,
                .void_type => 8,
            },
            .array => |arr| typeSize(arr.elem) * arr.len,
            .tuple => |tuple| tupleSize(tuple),
            else => 8,
        };
    }

    fn typeString(ty: *const ast.Type) []const u8 {
        return switch (ty.*) {
            .primitive => |p| switch (p) {
                .boolean => "u8",
                .integer => "i64",
                .float => "f64",
                .void_type => "ptr",
            },
            .array => "ptr",
            .tuple => "ptr",
            else => "ptr",
        };
    }

    fn arrayType(ty: *ast.Type) ?ast.ArrayType {
        var curr = ty;
        while (true) {
            switch (curr.*) {
                .array => |arr| return arr,
                .pointer => |p| curr = p,
                .borrow => |b| curr = b,
                else => return null,
            }
        }
    }

    fn alignOffset(offset: usize, size: usize) usize {
        if (size == 8) {
            return (offset + 7) & ~@as(usize, 7);
        }
        return offset;
    }

    fn structSize(s: *const ast.StructDecl) usize {
        var offset: usize = 0;
        for (s.fields) |f| {
            const size = typeSize(f.ty);
            offset = alignOffset(offset, size);
            offset += size;
        }
        return @max(offset, 1);
    }

    fn tupleSize(tuple: ast.TupleType) usize {
        var offset: usize = 0;
        for (tuple.elems) |elem_ty| {
            const size = typeSize(elem_ty);
            offset = alignOffset(offset, size);
            offset += size;
        }
        return @max(offset, 1);
    }

    fn tupleFieldLayout(tuple: ast.TupleType, index: usize) ?FieldLayout {
        var offset: usize = 0;
        for (tuple.elems, 0..) |elem_ty, i| {
            const size = typeSize(elem_ty);
            offset = alignOffset(offset, size);
            if (i == index) {
                return .{ .offset = offset, .ty_str = typeString(elem_ty) };
            }
            offset += size;
        }
        return null;
    }

    fn fieldLayout(s: *const ast.StructDecl, name: []const u8) ?FieldLayout {
        var offset: usize = 0;
        for (s.fields) |f| {
            const size = typeSize(f.ty);
            offset = alignOffset(offset, size);
            if (std.mem.eql(u8, f.name, name)) {
                return .{
                    .offset = offset,
                    .ty_str = typeString(f.ty),
                };
            }
            offset += size;
        }
        return null;
    }

    fn enumVariantIndex(e: *const ast.EnumDecl, name: []const u8) ?usize {
        for (e.variants, 0..) |variant, i| {
            if (std.mem.eql(u8, variant.name, name)) return i;
        }
        return null;
    }

    fn enumVariant(e: *const ast.EnumDecl, name: []const u8) ?ast.EnumVariant {
        for (e.variants) |variant| {
            if (std.mem.eql(u8, variant.name, name)) return variant;
        }
        return null;
    }

    fn enumFieldLayout(variant: ast.EnumVariant, name: []const u8) ?FieldLayout {
        var offset: usize = 8;
        for (variant.fields) |f| {
            const size = typeSize(f.ty);
            offset = alignOffset(offset, size);
            if (std.mem.eql(u8, f.name, name)) {
                return .{ .offset = offset, .ty_str = typeString(f.ty) };
            }
            offset += size;
        }
        return null;
    }

    fn enumSize(e: *const ast.EnumDecl) usize {
        var max_payload: usize = 0;
        for (e.variants) |variant| {
            var offset: usize = 8;
            for (variant.fields) |f| {
                const size = typeSize(f.ty);
                offset = alignOffset(offset, size);
                offset += size;
            }
            max_payload = @max(max_payload, offset - 8);
        }
        return @max(8 + max_payload, 8);
    }

    fn isVoidType(ty: *const ast.Type) bool {
        return switch (ty.*) {
            .primitive => |p| p == .void_type,
            else => false,
        };
    }

    fn emitAsyncMacros(self: *Codegen) CodegenError!void {
        self.out.writer().print("@import \"sa_std/future.sa\"\n", .{}) catch return CodegenError.CodegenError;
    }

    fn emitIterMacros(self: *Codegen) CodegenError!void {
        self.out.writer().print("@import \"sa_std/array.sa\"\n", .{}) catch return CodegenError.CodegenError;
        self.out.writer().print("@import \"sa_std/core/iter.sa\"\n", .{}) catch return CodegenError.CodegenError;
    }

    fn arrayIterSumSource(call: *const ast.CallExpr) ?*ast.Node {
        if (!std.mem.eql(u8, call.func_name, "sum") or call.args.len != 1) return null;
        const iter_expr = call.args[0];
        if (iter_expr.* != .call_expr) return null;
        const iter_call = &iter_expr.call_expr;
        if (!std.mem.eql(u8, iter_call.func_name, "iter") or iter_call.args.len != 1) return null;
        return iter_call.args[0];
    }

    fn exprNeedsIterMacros(expr: *const ast.Node) bool {
        return switch (expr.*) {
            .call_expr => |call| blk: {
                if (arrayIterSumSource(&call) != null) break :blk true;
                for (call.args) |arg| {
                    if (exprNeedsIterMacros(arg)) break :blk true;
                }
                break :blk false;
            },
            .binary_expr => |bin| exprNeedsIterMacros(bin.left) or exprNeedsIterMacros(bin.right),
            .borrow_expr => |borrow| exprNeedsIterMacros(borrow.expr),
            .move_expr => |move| exprNeedsIterMacros(move.expr),
            .deref_expr => |deref| exprNeedsIterMacros(deref.expr),
            .field_expr => |field| exprNeedsIterMacros(field.expr),
            .index_expr => |idx| exprNeedsIterMacros(idx.target) or exprNeedsIterMacros(idx.index),
            .slice_expr => |slc| exprNeedsIterMacros(slc.target) or exprNeedsIterMacros(slc.start) or exprNeedsIterMacros(slc.end),
            .closure_literal => |lit| exprNeedsIterMacros(lit.body),
            .await_expr => |aw| exprNeedsIterMacros(aw.expr),
            .try_expr => |trye| exprNeedsIterMacros(trye.expr),
            .struct_literal => |lit| blk: {
                for (lit.fields) |field| {
                    if (exprNeedsIterMacros(field.value)) break :blk true;
                }
                break :blk false;
            },
            .enum_literal => |lit| blk: {
                for (lit.fields) |field| {
                    if (exprNeedsIterMacros(field.value)) break :blk true;
                }
                break :blk false;
            },
            .tuple_literal => |lit| blk: {
                for (lit.elements) |elem| {
                    if (exprNeedsIterMacros(elem)) break :blk true;
                }
                break :blk false;
            },
            .array_literal => |lit| blk: {
                for (lit.elements) |elem| {
                    if (exprNeedsIterMacros(elem)) break :blk true;
                }
                break :blk false;
            },
            .if_expr => |ife| exprNeedsIterMacros(ife.cond) or blockNeedsIterMacros(ife.then_block) or if (ife.else_block) |eb| blockNeedsIterMacros(eb) else false,
            .switch_expr => |swe| blk: {
                if (exprNeedsIterMacros(swe.val)) break :blk true;
                for (swe.cases) |case| {
                    if (exprNeedsIterMacros(case.pattern) or blockNeedsIterMacros(case.body)) break :blk true;
                }
                break :blk false;
            },
            .match_expr => |mat| blk: {
                if (exprNeedsIterMacros(mat.val)) break :blk true;
                for (mat.cases) |case| {
                    if (blockNeedsIterMacros(case.body)) break :blk true;
                }
                break :blk false;
            },
            else => false,
        };
    }

    fn blockNeedsIterMacros(block: []const *ast.Node) bool {
        for (block) |stmt| {
            switch (stmt.*) {
                .let_stmt => |let| if (exprNeedsIterMacros(let.value)) return true,
                .let_destructure_stmt => |let| if (exprNeedsIterMacros(let.value)) return true,
                .const_stmt => |c| if (exprNeedsIterMacros(c.value)) return true,
                .assign_stmt => |assign| if (exprNeedsIterMacros(assign.target) or exprNeedsIterMacros(assign.value)) return true,
                .expr_stmt => |expr| if (exprNeedsIterMacros(expr)) return true,
                .return_stmt => |ret| if (ret.value) |v| if (exprNeedsIterMacros(v)) return true,
                .for_stmt => |f| if (exprNeedsIterMacros(f.start) or exprNeedsIterMacros(f.end) or blockNeedsIterMacros(f.body)) return true,
                else => {},
            }
        }
        return false;
    }

    fn programNeedsIterMacros(program: *const ast.Node) bool {
        for (program.program.decls) |decl| {
            switch (decl.*) {
                .func_decl => |f| if (blockNeedsIterMacros(f.body)) return true,
                .impl_decl => |i| for (i.methods) |method| {
                    if (method.* == .func_decl and blockNeedsIterMacros(method.func_decl.body)) return true;
                },
                .test_decl => |t| if (blockNeedsIterMacros(t.body)) return true,
                else => {},
            }
        }
        return false;
    }

    fn exprNeedsAsyncMacros(expr: *const ast.Node) bool {
        return switch (expr.*) {
            .await_expr => true,
            .binary_expr => |bin| exprNeedsAsyncMacros(bin.left) or exprNeedsAsyncMacros(bin.right),
            .borrow_expr => |borrow| exprNeedsAsyncMacros(borrow.expr),
            .move_expr => |move| exprNeedsAsyncMacros(move.expr),
            .deref_expr => |deref| exprNeedsAsyncMacros(deref.expr),
            .field_expr => |field| exprNeedsAsyncMacros(field.expr),
            .struct_literal => |lit| blk: {
                for (lit.fields) |field| {
                    if (exprNeedsAsyncMacros(field.value)) break :blk true;
                }
                break :blk false;
            },
            .enum_literal => |lit| blk: {
                for (lit.fields) |field| {
                    if (exprNeedsAsyncMacros(field.value)) break :blk true;
                }
                break :blk false;
            },
            .tuple_literal => |lit| blk: {
                for (lit.elements) |elem| {
                    if (exprNeedsAsyncMacros(elem)) break :blk true;
                }
                break :blk false;
            },
            .array_literal => |lit| blk: {
                for (lit.elements) |elem| {
                    if (exprNeedsAsyncMacros(elem)) break :blk true;
                }
                break :blk false;
            },
            .index_expr => |idx| exprNeedsAsyncMacros(idx.target) or exprNeedsAsyncMacros(idx.index),
            .slice_expr => |slc| exprNeedsAsyncMacros(slc.target) or exprNeedsAsyncMacros(slc.start) or exprNeedsAsyncMacros(slc.end),
            .closure_literal => |lit| exprNeedsAsyncMacros(lit.body),
            .call_expr => |call| blk: {
                for (call.args) |arg| {
                    if (exprNeedsAsyncMacros(arg)) break :blk true;
                }
                break :blk false;
            },
            .if_expr => |ife| exprNeedsAsyncMacros(ife.cond) or blockNeedsAsyncMacros(ife.then_block) or if (ife.else_block) |eb| blockNeedsAsyncMacros(eb) else false,
            .switch_expr => |swe| blk: {
                if (exprNeedsAsyncMacros(swe.val)) break :blk true;
                for (swe.cases) |case| {
                    if (exprNeedsAsyncMacros(case.pattern) or blockNeedsAsyncMacros(case.body)) break :blk true;
                }
                break :blk false;
            },
            .match_expr => |mat| blk: {
                if (exprNeedsAsyncMacros(mat.val)) break :blk true;
                for (mat.cases) |case| {
                    if (blockNeedsAsyncMacros(case.body)) break :blk true;
                }
                break :blk false;
            },
            .try_expr => |trye| exprNeedsAsyncMacros(trye.expr),
            else => false,
        };
    }

    fn blockNeedsAsyncMacros(block: []const *ast.Node) bool {
        for (block) |stmt| {
            switch (stmt.*) {
                .let_stmt => |let| if (exprNeedsAsyncMacros(let.value)) return true,
                .let_destructure_stmt => |let| if (exprNeedsAsyncMacros(let.value)) return true,
                .const_stmt => |c| if (exprNeedsAsyncMacros(c.value)) return true,
                .assign_stmt => |assign| if (exprNeedsAsyncMacros(assign.target) or exprNeedsAsyncMacros(assign.value)) return true,
                .expr_stmt => |expr| if (exprNeedsAsyncMacros(expr)) return true,
                .return_stmt => |ret| if (ret.value) |v| if (exprNeedsAsyncMacros(v)) return true,
                .for_stmt => |f| if (exprNeedsAsyncMacros(f.start) or exprNeedsAsyncMacros(f.end) or blockNeedsAsyncMacros(f.body)) return true,
                else => {},
            }
        }
        return false;
    }

    fn programNeedsAsyncMacros(program: *const ast.Node) bool {
        for (program.program.decls) |decl| {
            switch (decl.*) {
                .func_decl => |f| if (f.is_async or blockNeedsAsyncMacros(f.body)) return true,
                .test_decl => |t| if (blockNeedsAsyncMacros(t.body)) return true,
                else => {},
            }
        }
        return false;
    }

    pub fn generate(self: *Codegen, program: *ast.Node) CodegenError![]const u8 {
        if (program.* != .program) return CodegenError.CodegenError;

        // Struct layouts are compile-time Sla metadata. The generated SA uses
        // flattened stack offsets directly because SA rejects brace layouts.

        // 1. Emit imports before generated code so SA flattener sees std macros/contracts.
        for (program.program.decls) |decl| {
            if (decl.* == .import_decl) {
                try self.genImportDecl(&decl.import_decl);
            }
        }

        if (programNeedsAsyncMacros(program)) {
            try self.emitAsyncMacros();
        }

        if (programNeedsIterMacros(program)) {
            try self.emitIterMacros();
        }

        // 2. Emit macros
        for (program.program.decls) |decl| {
            if (decl.* == .macro_decl) {
                try self.genMacroDecl(&decl.macro_decl);
            }
        }

        // 3. Emit functions
        for (program.program.decls) |decl| {
            if (decl.* == .func_decl) {
                try self.genFuncDecl(&decl.func_decl);
            } else if (decl.* == .impl_decl) {
                const impl_name = switch (decl.impl_decl.target_ty.*) {
                    .user_defined => |ud| ud.name,
                    else => return CodegenError.CodegenError,
                };
                for (decl.impl_decl.methods) |method| {
                    if (method.* != .func_decl) return CodegenError.CodegenError;
                    const mangled = try self.mangleMethodName(impl_name, method.func_decl.name);
                    defer self.allocator.free(mangled);
                    try self.genFuncDeclNamed(mangled, &method.func_decl);
                }
            }
        }

        // 4. Emit test declarations
        for (program.program.decls) |decl| {
            if (decl.* == .test_decl) {
                try self.genTestDecl(&decl.test_decl);
            }
        }

        return self.out.toOwnedSlice() catch return CodegenError.OutOfMemory;
    }

    fn genImportDecl(self: *Codegen, import: *const ast.ImportDecl) CodegenError!void {
        self.out.writer().print("@import \"{s}\"\n", .{import.path}) catch return CodegenError.CodegenError;
    }

    fn genMacroDecl(self: *Codegen, m: *const ast.MacroDecl) CodegenError!void {
        // Clear previous macro locals
        var val_iter = self.macro_locals.valueIterator();
        while (val_iter.next()) |v| {
            self.allocator.free(v.*);
        }
        self.macro_locals.clearRetainingCapacity();

        self.out.writer().print("[MACRO] {s}", .{m.name}) catch return CodegenError.CodegenError;
        for (m.params) |p| {
            self.out.writer().print(" %{s}", .{p}) catch return CodegenError.CodegenError;
        }
        self.out.writer().print("\n", .{}) catch return CodegenError.CodegenError;

        // Perform Alpha-conversion for local variables declared in macro body
        // and map macro parameters to %param
        for (m.body) |stmt| {
            try self.genMacroStmt(stmt, m);
        }
        self.out.writer().print("[END_MACRO]\n\n", .{}) catch return CodegenError.CodegenError;
    }

    fn genMacroStmt(self: *Codegen, stmt: *ast.Node, m: *const ast.MacroDecl) CodegenError!void {
        // Simple macro body transpile converting parameter names to %param
        // and mangling local variables to ensure hygiene
        switch (stmt.*) {
            .let_stmt => |let| {
                const mangled = try self.newMacroLocal(m.name, let.name);
                const val_reg = try self.genMacroExpr(let.value, m);
                self.out.writer().print("    {s} = {s}\n", .{ mangled, val_reg }) catch return CodegenError.CodegenError;
            },
            .assign_stmt => |assign| {
                const target_reg = try self.genMacroExpr(assign.target, m);
                const val_reg = try self.genMacroExpr(assign.value, m);
                self.out.writer().print("    {s} = {s}\n", .{ target_reg, val_reg }) catch return CodegenError.CodegenError;
            },
            .release_stmt => |rel| {
                var is_param = false;
                for (m.params) |p| {
                    if (std.mem.eql(u8, rel.var_name, p)) {
                        self.out.writer().print("    !%{s}\n", .{p}) catch return CodegenError.CodegenError;
                        is_param = true;
                        break;
                    }
                }
                if (!is_param) {
                    // Assume it's a macro local
                    self.out.writer().print("    !{s}_{s}_uniq_0\n", .{ m.name, rel.var_name }) catch return CodegenError.CodegenError;
                }
            },
            .expr_stmt => |expr| {
                _ = try self.genMacroExpr(expr, m);
            },
            else => {},
        }
    }

    fn genMacroExpr(self: *Codegen, expr: *ast.Node, m: *const ast.MacroDecl) CodegenError![]const u8 {
        switch (expr.*) {
            .literal => |lit| {
                const reg = try self.newTmp();
                switch (lit) {
                    .int_val => |v| try self.emitIntConst(reg, v),
                    .float_val => |v| self.out.writer().print("    {s} = {d}\n", .{ reg, v }) catch return CodegenError.CodegenError,
                    .bool_val => |v| try self.emitIntConst(reg, if (v) 1 else 0),
                    .string_val => |v| {
                        const label = try self.newStringConst();
                        self.out.writer().print("    @const {s} = utf8:\"{s}\"\n", .{ label, v }) catch return CodegenError.CodegenError;
                        return std.fmt.allocPrint(self.allocator, "&{s}", .{label}) catch return CodegenError.OutOfMemory;
                    },
                }
                return reg;
            },
            .identifier => |name| {
                if (self.macro_locals.get(name)) |mangled| {
                    return mangled;
                }
                for (m.params) |p| {
                    if (std.mem.eql(u8, name, p)) {
                        const reg = try self.newTmp();
                        self.out.writer().print("    {s} = %{s}\n", .{ reg, p }) catch return CodegenError.CodegenError;
                        return reg;
                    }
                }
                return name;
            },
            .move_expr => |move| {
                const inner = try self.genMacroExpr(move.expr, m);
                return std.fmt.allocPrint(self.allocator, "^{s}", .{inner}) catch return CodegenError.OutOfMemory;
            },
            .borrow_expr => |borrow| {
                const inner = try self.genMacroExpr(borrow.expr, m);
                const reg = try self.newTmp();
                self.out.writer().print("    {s} = &{s}\n", .{ reg, inner }) catch return CodegenError.CodegenError;
                return reg;
            },
            .binary_expr => |bin| {
                const l = try self.genMacroExpr(bin.left, m);
                const r = try self.genMacroExpr(bin.right, m);
                const reg = try self.newTmp();
                const op = switch (bin.op) {
                    .add => "add",
                    .sub => "sub",
                    .mul => "mul",
                    .div => "div",
                    .mod => "rem",
                    .eq => "eq",
                    .ne => "ne",
                    .lt => "slt",
                    .le => "sle",
                    .gt => "sgt",
                    .ge => "sge",
                    .logical_and => "and",
                    .logical_or => "or",
                };
                self.out.writer().print("    {s} = {s} {s}, {s}\n", .{ reg, op, l, r }) catch return CodegenError.CodegenError;
                return reg;
            },
            else => return "tmp_macro_res",
        }
    }

    fn genFuncDeclNamed(self: *Codegen, name: []const u8, f: *const ast.FuncDecl) CodegenError!void {
        const prev_async = self.current_async;
        self.current_async = f.is_async;
        defer self.current_async = prev_async;

        // Emit function signature
        self.out.writer().print("@{s}(", .{name}) catch return CodegenError.CodegenError;
        for (f.params, 0..) |p, i| {
            if (i > 0) self.out.writer().print(", ", .{}) catch return CodegenError.CodegenError;
            const p_type_str = switch (p.ty.*) {
                .primitive => |pr| switch (pr) {
                    .boolean => "u8",
                    .integer => "i64",
                    .float => "f64",
                    .void_type => "ptr",
                },
                else => "ptr",
            };
            const prefix: []const u8 = if (p.is_move) "^" else if (p.is_borrow) "&" else "";
            self.out.writer().print("{s}{s}: {s}", .{ prefix, p.name, p_type_str }) catch return CodegenError.CodegenError;
        }
        const ret_type_str = if (f.is_async) "ptr" else switch (f.ret_ty.*) {
            .primitive => |pr| switch (pr) {
                .boolean => "u8",
                .integer => "i64",
                .float => "f64",
                .void_type => "void",
            },
            else => "ptr",
        };
        if (isVoidType(f.ret_ty) and !f.is_async) {
            self.out.writer().print("):\n", .{}) catch return CodegenError.CodegenError;
        } else {
            self.out.writer().print(") -> {s}:\n", .{ret_type_str}) catch return CodegenError.CodegenError;
        }
        self.out.writer().print("L_ENTRY:\n", .{}) catch return CodegenError.CodegenError;

        // 1. Loop allocation hoisting pre-pass
        // Detect all stack allocations inside for loops in this function body
        var hoisted_allocs = std.ArrayList([]const u8).init(self.allocator);
        defer hoisted_allocs.deinit();
        try self.collectHoistedAllocs(f.body, &hoisted_allocs);

        for (hoisted_allocs.items) |h_name| {
            self.out.writer().print("    {s} = stack_alloc 16 // Hoisted loop stack allocation\n", .{h_name}) catch return CodegenError.CodegenError;
        }

        // 2. Compile body statements
        try self.genBlock(f.body, &hoisted_allocs);

        if (f.is_async and !blockTerminates(f.body)) {
            const zero = try self.newTmp();
            self.out.writer().print("    {s} = 0\n", .{zero}) catch return CodegenError.CodegenError;
            const future = try self.genReadyFutureI64(zero);
            self.out.writer().print("    return {s}\n", .{future}) catch return CodegenError.CodegenError;
        } else if (isVoidType(f.ret_ty)) {
            self.out.writer().print("    return\n", .{}) catch return CodegenError.CodegenError;
        }
        self.out.writer().print("\n", .{}) catch return CodegenError.CodegenError;
    }

    fn genFuncDecl(self: *Codegen, f: *const ast.FuncDecl) CodegenError!void {
        try self.genFuncDeclNamed(f.name, f);
    }

    fn genTestDecl(self: *Codegen, t: *const ast.TestDecl) CodegenError!void {
        // Emit SA @test header:  @test [ignored] [should_panic] "name"():
        self.out.writer().print("@test", .{}) catch return CodegenError.CodegenError;
        if (t.is_ignored) {
            self.out.writer().print(" ignored", .{}) catch return CodegenError.CodegenError;
        }
        if (t.should_panic) {
            self.out.writer().print(" should_panic", .{}) catch return CodegenError.CodegenError;
        }
        const test_name = try self.sanitizeTestName(t.name);
        defer self.allocator.free(test_name);
        self.out.writer().print(" \"{s}\"():\n", .{test_name}) catch return CodegenError.CodegenError;
        const entry_label = try self.newLabel("L_TEST_ENTRY");
        self.out.writer().print("{s}:\n", .{entry_label}) catch return CodegenError.CodegenError;

        // Hoist any stack allocations inside the test body
        var hoisted_allocs = std.ArrayList([]const u8).init(self.allocator);
        defer hoisted_allocs.deinit();
        try self.collectHoistedAllocs(t.body, &hoisted_allocs);

        for (hoisted_allocs.items) |h_name| {
            self.out.writer().print("    {s} = stack_alloc 16 // Hoisted loop stack allocation\n", .{h_name}) catch return CodegenError.CodegenError;
        }

        // Compile body statements
        try self.genBlock(t.body, &hoisted_allocs);

        // Tests return void
        self.out.writer().print("    return\n", .{}) catch return CodegenError.CodegenError;
        self.out.writer().print("\n", .{}) catch return CodegenError.CodegenError;
    }

    fn collectHoistedAllocs(self: *Codegen, block: []const *ast.Node, list: *std.ArrayList([]const u8)) CodegenError!void {
        try self.collectHoistedAllocsInternal(block, list, false);
    }

    fn collectHoistedAllocsInternal(self: *Codegen, block: []const *ast.Node, list: *std.ArrayList([]const u8), in_loop: bool) CodegenError!void {
        for (block) |stmt| {
            switch (stmt.*) {
                .let_stmt => |let| {
                    if (in_loop) {
                        if (let.value.* == .call_expr and std.mem.eql(u8, let.value.call_expr.func_name, "stack_alloc")) {
                            list.append(let.name) catch return CodegenError.OutOfMemory;
                        }
                    }
                    try self.collectHoistedAllocsInExpr(let.value, list, in_loop);
                },
                .let_destructure_stmt => |let| {
                    try self.collectHoistedAllocsInExpr(let.value, list, in_loop);
                },
                .const_stmt => |c| {
                    if (in_loop) {
                        if (c.value.* == .call_expr and std.mem.eql(u8, c.value.call_expr.func_name, "stack_alloc")) {
                            list.append(c.name) catch return CodegenError.OutOfMemory;
                        }
                    }
                    try self.collectHoistedAllocsInExpr(c.value, list, in_loop);
                },
                .assign_stmt => |assign| {
                    try self.collectHoistedAllocsInExpr(assign.target, list, in_loop);
                    try self.collectHoistedAllocsInExpr(assign.value, list, in_loop);
                },
                .expr_stmt => |expr| {
                    try self.collectHoistedAllocsInExpr(expr, list, in_loop);
                },
                .return_stmt => |ret| {
                    if (ret.value) |v| {
                        try self.collectHoistedAllocsInExpr(v, list, in_loop);
                    }
                },
                .for_stmt => |f| {
                    try self.collectHoistedAllocsInternal(f.body, list, true);
                },
                .release_stmt => {},
                else => {},
            }
        }
    }

    fn collectHoistedAllocsInExpr(self: *Codegen, expr: *ast.Node, list: *std.ArrayList([]const u8), in_loop: bool) CodegenError!void {
        switch (expr.*) {
            .if_expr => |ife| {
                try self.collectHoistedAllocsInternal(ife.then_block, list, in_loop);
                if (ife.else_block) |eb| {
                    try self.collectHoistedAllocsInternal(eb, list, in_loop);
                }
            },
            .switch_expr => |swe| {
                for (swe.cases) |case| {
                    try self.collectHoistedAllocsInternal(case.body, list, in_loop);
                }
            },
            .binary_expr => |bin| {
                try self.collectHoistedAllocsInExpr(bin.left, list, in_loop);
                try self.collectHoistedAllocsInExpr(bin.right, list, in_loop);
            },
            .borrow_expr => |borrow| {
                try self.collectHoistedAllocsInExpr(borrow.expr, list, in_loop);
            },
            .move_expr => |move| {
                try self.collectHoistedAllocsInExpr(move.expr, list, in_loop);
            },
            .deref_expr => |deref| {
                try self.collectHoistedAllocsInExpr(deref.expr, list, in_loop);
            },
            .field_expr => |field| {
                try self.collectHoistedAllocsInExpr(field.expr, list, in_loop);
            },
            .struct_literal => |lit| {
                for (lit.fields) |field| {
                    try self.collectHoistedAllocsInExpr(field.value, list, in_loop);
                }
            },
            .enum_literal => |lit| {
                for (lit.fields) |field| {
                    try self.collectHoistedAllocsInExpr(field.value, list, in_loop);
                }
            },
            .tuple_literal => |lit| {
                for (lit.elements) |elem| {
                    try self.collectHoistedAllocsInExpr(elem, list, in_loop);
                }
            },
            .match_expr => |mat| {
                try self.collectHoistedAllocsInExpr(mat.val, list, in_loop);
                for (mat.cases) |case| {
                    try self.collectHoistedAllocsInternal(case.body, list, in_loop);
                }
            },
            .await_expr => |aw| {
                try self.collectHoistedAllocsInExpr(aw.expr, list, in_loop);
            },
            .closure_literal => |lit| {
                try self.collectHoistedAllocsInExpr(lit.body, list, in_loop);
            },
            .try_expr => |trye| {
                try self.collectHoistedAllocsInExpr(trye.expr, list, in_loop);
            },
            .call_expr => |call| {
                for (call.args) |arg| {
                    try self.collectHoistedAllocsInExpr(arg, list, in_loop);
                }
            },
            .array_literal => |lit| {
                for (lit.elements) |elem| {
                    try self.collectHoistedAllocsInExpr(elem, list, in_loop);
                }
            },
            .index_expr => |idx| {
                try self.collectHoistedAllocsInExpr(idx.target, list, in_loop);
                try self.collectHoistedAllocsInExpr(idx.index, list, in_loop);
            },
            .slice_expr => |slc| {
                try self.collectHoistedAllocsInExpr(slc.target, list, in_loop);
                try self.collectHoistedAllocsInExpr(slc.start, list, in_loop);
                try self.collectHoistedAllocsInExpr(slc.end, list, in_loop);
            },
            else => {},
        }
    }

    fn genBlock(self: *Codegen, block: []const *ast.Node, hoisted_allocs: *const std.ArrayList([]const u8)) CodegenError!void {
        for (block) |stmt| {
            try self.genStmt(stmt, hoisted_allocs);
        }
    }

    fn genReadyFutureI64(self: *Codegen, value_reg: []const u8) CodegenError![]const u8 {
        const future_reg = try self.newTmp();
        self.out.writer().print("    EXPAND FUTURE_READY_STATE_NEW {s}, {s}\n", .{ future_reg, value_reg }) catch return CodegenError.CodegenError;
        return future_reg;
    }

    fn genCallArg(self: *Codegen, arg: *ast.Node, hoisted_allocs: *const std.ArrayList([]const u8)) CodegenError![]const u8 {
        if (arg.* == .borrow_expr and arg.borrow_expr.expr.* == .identifier) {
            return std.fmt.allocPrint(self.allocator, "&{s}", .{arg.borrow_expr.expr.identifier}) catch return CodegenError.OutOfMemory;
        }
        if (arg.* == .move_expr and arg.move_expr.expr.* == .identifier) {
            return std.fmt.allocPrint(self.allocator, "^{s}", .{arg.move_expr.expr.identifier}) catch return CodegenError.OutOfMemory;
        }
        return try self.genExpr(arg, hoisted_allocs);
    }

    fn callArgNeedsRelease(arg: *const ast.Node) bool {
        return switch (arg.*) {
            .identifier => false,
            .borrow_expr => |borrow| borrow.expr.* != .identifier,
            .move_expr => |move| move.expr.* != .identifier,
            else => true,
        };
    }

    fn stackAllocSize(call: *const ast.CallExpr) i64 {
        if (call.args.len > 0 and call.args[0].* == .literal and call.args[0].literal == .int_val) {
            return call.args[0].literal.int_val;
        }
        return 16;
    }

    fn isStackAllocCall(node: *const ast.Node) bool {
        return node.* == .call_expr and std.mem.eql(u8, node.call_expr.func_name, "stack_alloc");
    }

    fn genStmt(self: *Codegen, stmt: *ast.Node, hoisted_allocs: *const std.ArrayList([]const u8)) CodegenError!void {
        switch (stmt.*) {
            .let_stmt => |let| {
                // If it is a hoisted loop allocation, we bypass stack_alloc emission since it is pre-allocated
                var is_hoisted = false;
                for (hoisted_allocs.items) |h| {
                    if (std.mem.eql(u8, let.name, h)) {
                        is_hoisted = true;
                        break;
                    }
                }

                if (is_hoisted) {
                    self.out.writer().print("    // Hoisted stack slot {s} initialized\n", .{let.name}) catch return CodegenError.CodegenError;
                } else if (isStackAllocCall(let.value)) {
                    self.stack_alloc_bindings.put(let.name, {}) catch return CodegenError.OutOfMemory;
                    self.out.writer().print("    {s} = stack_alloc {}\n", .{ let.name, stackAllocSize(&let.value.call_expr) }) catch return CodegenError.CodegenError;
                } else if (let.value.* == .closure_literal) {
                    try self.closure_bindings.put(let.name, &let.value.closure_literal);
                    self.out.writer().print("    {s} = 0\n", .{let.name}) catch return CodegenError.CodegenError;
                } else if (let.value.* == .struct_literal) {
                    try self.genStructLiteralInto(let.name, &let.value.struct_literal, hoisted_allocs);
                } else if (let.value.* == .enum_literal) {
                    try self.genEnumLiteralInto(let.name, &let.value.enum_literal, hoisted_allocs);
                } else if (let.value.* == .tuple_literal) {
                    try self.genTupleLiteralInto(let.name, &let.value.tuple_literal, hoisted_allocs);
                } else if (let.value.* == .array_literal) {
                    try self.genArrayLiteralInto(let.name, &let.value.array_literal, hoisted_allocs);
                } else {
                    const val_reg = try self.genExpr(let.value, hoisted_allocs);
                    self.out.writer().print("    {s} = {s}\n", .{ let.name, val_reg }) catch return CodegenError.CodegenError;
                }
            },
            .let_destructure_stmt => |let| {
                const value_reg = try self.genExpr(let.value, hoisted_allocs);
                const value_ty = self.tc.expr_types.get(let.value) orelse return CodegenError.CodegenError;
                if (value_ty.* != .tuple) return CodegenError.CodegenError;
                for (let.names, 0..) |name, i| {
                    const layout = tupleFieldLayout(value_ty.tuple, i) orelse return CodegenError.CodegenError;
                    self.out.writer().print("    {s} = load {s}+{} as {s}\n", .{ name, value_reg, layout.offset, layout.ty_str }) catch return CodegenError.CodegenError;
                }
                try self.emitRelease(value_reg);
            },
            .const_stmt => |c| {
                if (isStackAllocCall(c.value)) {
                    self.stack_alloc_bindings.put(c.name, {}) catch return CodegenError.OutOfMemory;
                    self.out.writer().print("    {s} = stack_alloc {}\n", .{ c.name, stackAllocSize(&c.value.call_expr) }) catch return CodegenError.CodegenError;
                } else if (c.value.* == .closure_literal) {
                    try self.closure_bindings.put(c.name, &c.value.closure_literal);
                    self.out.writer().print("    {s} = 0\n", .{c.name}) catch return CodegenError.CodegenError;
                } else if (c.value.* == .struct_literal) {
                    try self.genStructLiteralInto(c.name, &c.value.struct_literal, hoisted_allocs);
                } else if (c.value.* == .enum_literal) {
                    try self.genEnumLiteralInto(c.name, &c.value.enum_literal, hoisted_allocs);
                } else if (c.value.* == .tuple_literal) {
                    try self.genTupleLiteralInto(c.name, &c.value.tuple_literal, hoisted_allocs);
                } else if (c.value.* == .array_literal) {
                    try self.genArrayLiteralInto(c.name, &c.value.array_literal, hoisted_allocs);
                } else {
                    const val_reg = try self.genExpr(c.value, hoisted_allocs);
                    self.out.writer().print("    {s} = {s}\n", .{ c.name, val_reg }) catch return CodegenError.CodegenError;
                }
            },
            .assign_stmt => |assign| {
                if (assign.target.* == .index_expr) {
                    try self.genIndexAssign(&assign.target.index_expr, assign.value, hoisted_allocs);
                } else if (assign.target.* == .identifier) {
                    const val_reg = try self.genExpr(assign.value, hoisted_allocs);
                    try self.emitRelease(assign.target.identifier);
                    self.out.writer().print("    {s} = {s}\n", .{ assign.target.identifier, val_reg }) catch return CodegenError.CodegenError;
                } else {
                    const target_reg = try self.genExpr(assign.target, hoisted_allocs);
                    const val_reg = try self.genExpr(assign.value, hoisted_allocs);
                    self.out.writer().print("    {s} = {s}\n", .{ target_reg, val_reg }) catch return CodegenError.CodegenError;
                }
            },
            .return_stmt => |ret| {
                var val_reg: ?[]const u8 = null;
                if (ret.value) |v| {
                    val_reg = try self.genExpr(v, hoisted_allocs);
                }
                if (self.current_async) {
                    if (val_reg == null) {
                        const zero = try self.newTmp();
                        self.out.writer().print("    {s} = 0\n", .{zero}) catch return CodegenError.CodegenError;
                        val_reg = zero;
                    }
                    val_reg = try self.genReadyFutureI64(val_reg.?);
                }

                // Inject scope cleanups before return
                if (self.tc.cleanups.get(stmt)) |list| {
                    for (list.items) |c_var| {
                        try self.emitRelease(c_var);
                    }
                }

                if (val_reg) |vr| {
                    self.out.writer().print("    return {s}\n", .{vr}) catch return CodegenError.CodegenError;
                } else {
                    self.out.writer().print("    return\n", .{}) catch return CodegenError.CodegenError;
                }
            },
            .for_stmt => |f| {
                if (f.start.* == .literal and f.start.literal == .int_val and f.end.* == .literal and f.end.literal == .int_val) {
                    var i = f.start.literal.int_val;
                    const end = f.end.literal.int_val;
                    while (i < end) : (i += 1) {
                        try self.emitIntConst(f.var_name, i);
                        try self.genBlock(f.body, hoisted_allocs);
                        self.out.writer().print("    !{s}\n", .{f.var_name}) catch return CodegenError.CodegenError;
                    }
                    return;
                }

                const loop_head = try self.newLabel("L_LOOP_HEAD");
                const loop_body = try self.newLabel("L_LOOP_BODY");
                const loop_exit = try self.newLabel("L_LOOP_EXIT");

                const start_reg = try self.genExpr(f.start, hoisted_allocs);
                const end_reg = try self.genExpr(f.end, hoisted_allocs);

                // Allocate stack counter slot
                const counter_slot = std.fmt.allocPrint(self.allocator, "{s}_slot", .{f.var_name}) catch return CodegenError.OutOfMemory;
                defer self.allocator.free(counter_slot);

                self.out.writer().print("    {s} = stack_alloc 8\n", .{counter_slot}) catch return CodegenError.CodegenError;
                self.out.writer().print("    store {s}+0, {s} as i64\n", .{ counter_slot, start_reg }) catch return CodegenError.CodegenError;
                self.out.writer().print("    !{s}\n", .{start_reg}) catch return CodegenError.CodegenError;
                self.out.writer().print("    jmp {s}\n\n", .{loop_head}) catch return CodegenError.CodegenError;

                self.out.writer().print("{s}:\n", .{loop_head}) catch return CodegenError.CodegenError;
                self.out.writer().print("    {s} = load {s}+0 as i64\n", .{ f.var_name, counter_slot }) catch return CodegenError.CodegenError;
                const is_less = try self.newTmp();
                self.out.writer().print("    {s} = slt {s}, {s}\n", .{ is_less, f.var_name, end_reg }) catch return CodegenError.CodegenError;
                self.out.writer().print("    br {s} -> {s}, {s}\n\n", .{ is_less, loop_body, loop_exit }) catch return CodegenError.CodegenError;

                self.out.writer().print("{s}:\n", .{loop_body}) catch return CodegenError.CodegenError;
                self.out.writer().print("    !{s}\n", .{is_less}) catch return CodegenError.CodegenError;

                // Compile loop body block
                try self.genBlock(f.body, hoisted_allocs);

                // Increment counter
                const next_i = try self.newTmp();
                self.out.writer().print("    {s} = add {s}, 1\n", .{ next_i, f.var_name }) catch return CodegenError.CodegenError;
                self.out.writer().print("    store {s}+0, {s} as i64\n", .{ counter_slot, next_i }) catch return CodegenError.CodegenError;
                self.out.writer().print("    !{s}\n", .{next_i}) catch return CodegenError.CodegenError;
                self.out.writer().print("    !{s}\n", .{f.var_name}) catch return CodegenError.CodegenError;
                self.out.writer().print("    jmp {s}\n\n", .{loop_head}) catch return CodegenError.CodegenError;

                self.out.writer().print("{s}:\n", .{loop_exit}) catch return CodegenError.CodegenError;
                self.out.writer().print("    !{s}\n", .{is_less}) catch return CodegenError.CodegenError;
                self.out.writer().print("    !{s}\n", .{f.var_name}) catch return CodegenError.CodegenError;
                self.out.writer().print("    !{s}\n", .{counter_slot}) catch return CodegenError.CodegenError;
                self.out.writer().print("    !{s}\n", .{end_reg}) catch return CodegenError.CodegenError;
            },
            .release_stmt => |rel| {
                try self.emitRelease(rel.var_name);
            },
            .expr_stmt => |expr| {
                if (expr.* == .call_expr and self.isVoidCall(&expr.call_expr) and !std.mem.eql(u8, expr.call_expr.func_name, "panic")) {
                    try self.genCallStmt(&expr.call_expr, hoisted_allocs);
                } else if (expr.* == .call_expr and std.mem.eql(u8, expr.call_expr.func_name, "panic")) {
                    _ = try self.genExpr(expr, hoisted_allocs);
                } else if (expr.* == .if_expr or expr.* == .switch_expr or expr.* == .match_expr) {
                    _ = try self.genExpr(expr, hoisted_allocs);
                } else {
                    const value_reg = try self.genExpr(expr, hoisted_allocs);
                    try self.emitRelease(value_reg);
                }
            },
            else => {},
        }

        // Generate block exit cleanups if attached to this statement
        if (!stmtTerminates(stmt)) {
            if (self.tc.cleanups.get(stmt)) |list| {
                for (list.items) |c_var| {
                    try self.emitRelease(c_var);
                }
            }
        }
    }

    fn genStructLiteralInto(
        self: *Codegen,
        target: []const u8,
        lit: *const ast.StructLiteral,
        hoisted_allocs: *const std.ArrayList([]const u8),
    ) CodegenError!void {
        if (lit.ty.* != .user_defined) return CodegenError.CodegenError;
        const struct_decl = self.tc.structs.get(lit.ty.user_defined.name) orelse return CodegenError.CodegenError;

        self.out.writer().print("    {s} = alloc {}\n", .{ target, structSize(struct_decl) }) catch return CodegenError.CodegenError;

        for (struct_decl.fields) |decl_field| {
            var literal_value: ?*ast.Node = null;
            for (lit.fields) |literal_field| {
                if (std.mem.eql(u8, literal_field.name, decl_field.name)) {
                    literal_value = literal_field.value;
                    break;
                }
            }
            const value = literal_value orelse return CodegenError.CodegenError;
            const layout = fieldLayout(struct_decl, decl_field.name) orelse return CodegenError.CodegenError;
            const val_reg = try self.genExpr(value, hoisted_allocs);
            self.out.writer().print("    store {s}+{}, {s} as {s}\n", .{ target, layout.offset, val_reg, layout.ty_str }) catch return CodegenError.CodegenError;
        }
    }

    fn genArrayLiteralInto(
        self: *Codegen,
        target: []const u8,
        lit: *const ast.ArrayLiteral,
        hoisted_allocs: *const std.ArrayList([]const u8),
    ) CodegenError!void {
        if (lit.elements.len == 0) return CodegenError.CodegenError;
        const first_ty = self.tc.expr_types.get(lit.elements[0]) orelse return CodegenError.CodegenError;
        const elem_size = typeSize(first_ty);
        const elem_ty_str = typeString(first_ty);
        const total_size = @max(elem_size * lit.elements.len, 1);

        self.out.writer().print("    {s} = alloc {}\n", .{ target, total_size }) catch return CodegenError.CodegenError;
        for (lit.elements, 0..) |elem, i| {
            const val_reg = try self.genExpr(elem, hoisted_allocs);
            self.out.writer().print("    store {s}+{}, {s} as {s}\n", .{ target, elem_size * i, val_reg, elem_ty_str }) catch return CodegenError.CodegenError;
        }
    }

    fn genTupleLiteralInto(
        self: *Codegen,
        target: []const u8,
        lit: *const ast.TupleLiteral,
        hoisted_allocs: *const std.ArrayList([]const u8),
    ) CodegenError!void {
        var elems = std.ArrayList(*ast.Type).init(self.allocator);
        for (lit.elements) |elem| {
            try elems.append(self.tc.expr_types.get(elem) orelse return CodegenError.CodegenError);
        }
        const tuple = ast.TupleType{ .elems = try elems.toOwnedSlice() };

        self.out.writer().print("    {s} = alloc {}\n", .{ target, tupleSize(tuple) }) catch return CodegenError.CodegenError;
        for (lit.elements, 0..) |elem, i| {
            const layout = tupleFieldLayout(tuple, i) orelse return CodegenError.CodegenError;
            const val_reg = try self.genExpr(elem, hoisted_allocs);
            self.out.writer().print("    store {s}+{}, {s} as {s}\n", .{ target, layout.offset, val_reg, layout.ty_str }) catch return CodegenError.CodegenError;
        }
    }

    fn genEnumLiteralInto(
        self: *Codegen,
        target: []const u8,
        lit: *const ast.EnumLiteral,
        hoisted_allocs: *const std.ArrayList([]const u8),
    ) CodegenError!void {
        const decl = self.tc.enums.get(lit.enum_name) orelse return CodegenError.CodegenError;
        const tag = enumVariantIndex(decl, lit.variant_name) orelse return CodegenError.CodegenError;
        const variant = enumVariant(decl, lit.variant_name) orelse return CodegenError.CodegenError;

        self.out.writer().print("    {s} = alloc {}\n", .{ target, enumSize(decl) }) catch return CodegenError.CodegenError;
        self.out.writer().print("    store {s}+0, {} as i64\n", .{ target, tag }) catch return CodegenError.CodegenError;

        for (variant.fields) |field| {
            var literal_value: ?*ast.Node = null;
            for (lit.fields) |literal_field| {
                if (std.mem.eql(u8, literal_field.name, field.name)) {
                    literal_value = literal_field.value;
                    break;
                }
            }
            const value = literal_value orelse return CodegenError.CodegenError;
            const layout = enumFieldLayout(variant, field.name) orelse return CodegenError.CodegenError;
            const val_reg = try self.genExpr(value, hoisted_allocs);
            self.out.writer().print("    store {s}+{}, {s} as {s}\n", .{ target, layout.offset, val_reg, layout.ty_str }) catch return CodegenError.CodegenError;
        }
    }

    fn genMatchExpr(self: *Codegen, mat: *const ast.MatchExpr, hoisted_allocs: *const std.ArrayList([]const u8)) CodegenError![]const u8 {
        if (mat.cases.len == 0) return CodegenError.CodegenError;
        const val_reg = try self.genExpr(mat.val, hoisted_allocs);
        const val_ty = self.tc.expr_types.get(mat.val) orelse return CodegenError.CodegenError;
        if (val_ty.* != .user_defined) return CodegenError.CodegenError;
        const decl = self.tc.enums.get(val_ty.user_defined.name) orelse return CodegenError.CodegenError;

        const merge_label = try self.newLabel("L_MATCH_MERGE");
        const no_match_label = try self.newLabel("L_MATCH_NO_MATCH");
        var has_fallthrough_case = false;
        for (mat.cases) |case| {
            if (!blockTerminates(case.body)) {
                has_fallthrough_case = true;
                break;
            }
        }
        var check_labels = std.ArrayList([]const u8).init(self.allocator);
        var case_labels = std.ArrayList([]const u8).init(self.allocator);
        var cond_regs = std.ArrayList([]const u8).init(self.allocator);

        for (mat.cases, 0..) |_, i| {
            check_labels.append(try std.fmt.allocPrint(self.allocator, "L_MATCH_CHECK_{}_{}", .{ i, self.label_idx })) catch return CodegenError.OutOfMemory;
            case_labels.append(try std.fmt.allocPrint(self.allocator, "L_MATCH_CASE_{}_{}", .{ i, self.label_idx })) catch return CodegenError.OutOfMemory;
        }
        self.label_idx += 1;

        self.out.writer().print("    jmp {s}\n\n", .{check_labels.items[0]}) catch return CodegenError.CodegenError;

        for (mat.cases, 0..) |case, i| {
            self.out.writer().print("{s}:\n", .{check_labels.items[i]}) catch return CodegenError.CodegenError;
            if (i > 0) {
                self.out.writer().print("    !{s}\n", .{cond_regs.items[i - 1]}) catch return CodegenError.CodegenError;
            }
            const tag_reg = try self.newTmp();
            self.out.writer().print("    {s} = load {s}+0 as i64\n", .{ tag_reg, val_reg }) catch return CodegenError.CodegenError;
            const tag = enumVariantIndex(decl, case.pattern.variant_name) orelse return CodegenError.CodegenError;
            const tag_const = try self.newTmp();
            try self.emitIntConst(tag_const, @as(i64, @intCast(tag)));
            const cond = try self.newTmp();
            cond_regs.append(cond) catch return CodegenError.OutOfMemory;
            self.out.writer().print("    {s} = eq {s}, {s}\n", .{ cond, tag_reg, tag_const }) catch return CodegenError.CodegenError;
            self.out.writer().print("    !{s}\n", .{tag_reg}) catch return CodegenError.CodegenError;
            self.out.writer().print("    !{s}\n", .{tag_const}) catch return CodegenError.CodegenError;
            const next_label = if (i + 1 < mat.cases.len) check_labels.items[i + 1] else no_match_label;
            self.out.writer().print("    br {s} -> {s}, {s}\n\n", .{ cond, case_labels.items[i], next_label }) catch return CodegenError.CodegenError;

            self.out.writer().print("{s}:\n", .{case_labels.items[i]}) catch return CodegenError.CodegenError;
            self.out.writer().print("    !{s}\n", .{cond}) catch return CodegenError.CodegenError;
            const variant = enumVariant(decl, case.pattern.variant_name) orelse return CodegenError.CodegenError;
            for (case.pattern.bindings, variant.fields) |binding, field| {
                const layout = enumFieldLayout(variant, field.name) orelse return CodegenError.CodegenError;
                self.out.writer().print("    {s} = load {s}+{} as {s}\n", .{ binding, val_reg, layout.offset, layout.ty_str }) catch return CodegenError.CodegenError;
            }
            try self.genBlock(case.body, hoisted_allocs);
            if (!blockTerminates(case.body)) {
                self.out.writer().print("    jmp {s}\n", .{merge_label}) catch return CodegenError.CodegenError;
            }
            self.out.writer().print("\n", .{}) catch return CodegenError.CodegenError;
        }

        self.out.writer().print("{s}:\n", .{no_match_label}) catch return CodegenError.CodegenError;
        if (cond_regs.items.len > 0) {
            self.out.writer().print("    !{s}\n", .{cond_regs.items[cond_regs.items.len - 1]}) catch return CodegenError.CodegenError;
        }
        self.out.writer().print("    panic(1)\n\n", .{}) catch return CodegenError.CodegenError;
        if (has_fallthrough_case) {
            self.out.writer().print("{s}:\n", .{merge_label}) catch return CodegenError.CodegenError;
        }
        const reg = try self.newTmp();
        return reg;
    }

    fn genIndexAddress(
        self: *Codegen,
        idx: *const ast.IndexExpr,
        hoisted_allocs: *const std.ArrayList([]const u8),
    ) CodegenError!struct { ptr: []const u8, elem_ty: *ast.Type } {
        const target_ty = self.tc.expr_types.get(idx.target) orelse return CodegenError.CodegenError;
        const arr = arrayType(target_ty) orelse return CodegenError.CodegenError;

        const base_reg = try self.genExpr(idx.target, hoisted_allocs);
        const index_reg = try self.genExpr(idx.index, hoisted_allocs);
        const offset_reg = try self.newTmp();
        self.out.writer().print("    {s} = mul {s}, {}\n", .{ offset_reg, index_reg, typeSize(arr.elem) }) catch return CodegenError.CodegenError;
        const ptr_reg = try self.newTmp();
        self.out.writer().print("    {s} = ptr_add {s}, {s}\n", .{ ptr_reg, base_reg, offset_reg }) catch return CodegenError.CodegenError;
        return .{ .ptr = ptr_reg, .elem_ty = arr.elem };
    }

    fn genIndexAssign(
        self: *Codegen,
        idx: *const ast.IndexExpr,
        value: *ast.Node,
        hoisted_allocs: *const std.ArrayList([]const u8),
    ) CodegenError!void {
        const addr = try self.genIndexAddress(idx, hoisted_allocs);
        const val_reg = try self.genExpr(value, hoisted_allocs);
        self.out.writer().print("    store {s}+0, {s} as {s}\n", .{ addr.ptr, val_reg, typeString(addr.elem_ty) }) catch return CodegenError.CodegenError;
    }

    fn genSliceExpr(
        self: *Codegen,
        slc: *const ast.SliceExpr,
        hoisted_allocs: *const std.ArrayList([]const u8),
    ) CodegenError![]const u8 {
        const target_ty = self.tc.expr_types.get(slc.target) orelse return CodegenError.CodegenError;
        const arr = arrayType(target_ty) orelse return CodegenError.CodegenError;
        if (slc.start.* != .literal or slc.start.literal != .int_val) return CodegenError.CodegenError;
        const start = slc.start.literal.int_val;
        if (start < 0) return CodegenError.CodegenError;

        const base_reg = try self.genExpr(slc.target, hoisted_allocs);
        const offset_reg = try self.newTmp();
        try self.emitIntConst(offset_reg, @as(i64, @intCast(@as(usize, @intCast(start)) * typeSize(arr.elem))));
        const ptr_reg = try self.newTmp();
        self.out.writer().print("    {s} = ptr_add {s}, {s}\n", .{ ptr_reg, base_reg, offset_reg }) catch return CodegenError.CodegenError;
        return ptr_reg;
    }

    fn genArrayIterSum(
        self: *Codegen,
        source: *ast.Node,
        hoisted_allocs: *const std.ArrayList([]const u8),
    ) CodegenError![]const u8 {
        const source_ty = self.tc.expr_types.get(source) orelse return CodegenError.CodegenError;
        const arr = arrayType(source_ty) orelse return CodegenError.CodegenError;
        const elem_ty = arr.elem.*;
        if (elem_ty != .primitive or elem_ty.primitive != .integer) return CodegenError.CodegenError;

        const base_reg = try self.genExpr(source, hoisted_allocs);
        const slice_reg = try self.newTmp();
        self.out.writer().print("    {s} = alloc Slice_SIZE\n", .{slice_reg}) catch return CodegenError.CodegenError;
        self.out.writer().print("    EXPAND ARRAY_AS_SLICE_U64 {s}, {s}, {}\n", .{ slice_reg, base_reg, arr.len }) catch return CodegenError.CodegenError;

        const iter_reg = try self.newTmp();
        self.out.writer().print("    EXPAND ITER_FROM_SLICE {s}, {s}\n", .{ iter_reg, slice_reg }) catch return CodegenError.CodegenError;

        const out_reg = try self.newTmp();
        self.out.writer().print("    EXPAND ITER_SUM_U64 {s}, {s}\n", .{ out_reg, iter_reg }) catch return CodegenError.CodegenError;
        try self.emitRelease(iter_reg);
        try self.emitRelease(slice_reg);
        return out_reg;
    }

    const SavedClosureParam = struct {
        name: []const u8,
        old: ?[]const u8,
    };

    fn restoreClosureParams(self: *Codegen, saved: []const SavedClosureParam) void {
        var i = saved.len;
        while (i > 0) {
            i -= 1;
            const item = saved[i];
            if (item.old) |old| {
                self.closure_param_regs.put(item.name, old) catch {};
            } else {
                _ = self.closure_param_regs.remove(item.name);
            }
        }
    }

    fn genClosureCall(
        self: *Codegen,
        lit: *const ast.ClosureLiteral,
        call: *const ast.CallExpr,
        hoisted_allocs: *const std.ArrayList([]const u8),
    ) CodegenError![]const u8 {
        if (lit.params.len != call.args.len) return CodegenError.CodegenError;

        var arg_regs = std.ArrayList([]const u8).init(self.allocator);
        defer arg_regs.deinit();
        for (call.args) |arg| {
            arg_regs.append(try self.genExpr(arg, hoisted_allocs)) catch return CodegenError.OutOfMemory;
        }

        var saved = std.ArrayList(SavedClosureParam).init(self.allocator);
        defer saved.deinit();
        for (lit.params, arg_regs.items) |param, arg_reg| {
            saved.append(.{ .name = param.name, .old = self.closure_param_regs.get(param.name) }) catch return CodegenError.OutOfMemory;
            self.closure_param_regs.put(param.name, arg_reg) catch return CodegenError.OutOfMemory;
        }
        defer self.restoreClosureParams(saved.items);

        return try self.genExpr(lit.body, hoisted_allocs);
    }

    fn genExpr(self: *Codegen, expr: *ast.Node, hoisted_allocs: *const std.ArrayList([]const u8)) CodegenError![]const u8 {
        switch (expr.*) {
            .literal => |lit| {
                const reg = try self.newTmp();
                switch (lit) {
                    .int_val => |v| try self.emitIntConst(reg, v),
                    .float_val => |v| self.out.writer().print("    {s} = {d}\n", .{ reg, v }) catch return CodegenError.CodegenError,
                    .bool_val => |v| try self.emitIntConst(reg, if (v) 1 else 0),
                    .string_val => |v| {
                        const label = try self.newStringConst();
                        self.out.writer().print("    @const {s} = utf8:\"{s}\"\n", .{ label, v }) catch return CodegenError.CodegenError;
                        return std.fmt.allocPrint(self.allocator, "&{s}", .{label}) catch return CodegenError.OutOfMemory;
                    },
                }
                return reg;
            },
            .identifier => |name| {
                if (self.closure_param_regs.get(name)) |mapped| return mapped;
                return name;
            },
            .binary_expr => |bin| {
                const l = try self.genExpr(bin.left, hoisted_allocs);
                const r = try self.genExpr(bin.right, hoisted_allocs);
                const reg = try self.newTmp();
                const op = switch (bin.op) {
                    .add => "add",
                    .sub => "sub",
                    .mul => "mul",
                    .div => "div",
                    .mod => "rem",
                    .eq => "eq",
                    .ne => "ne",
                    .lt => "slt",
                    .le => "sle",
                    .gt => "sgt",
                    .ge => "sge",
                    .logical_and => "and",
                    .logical_or => "or",
                };
                self.out.writer().print("    {s} = {s} {s}, {s}\n", .{ reg, op, l, r }) catch return CodegenError.CodegenError;
                return reg;
            },
            .borrow_expr => |borrow| {
                const inner = try self.genExpr(borrow.expr, hoisted_allocs);
                const reg = try self.newTmp();
                self.out.writer().print("    {s} = &{s}\n", .{ reg, inner }) catch return CodegenError.CodegenError;
                return reg;
            },
            .move_expr => |move| {
                const inner = try self.genExpr(move.expr, hoisted_allocs);
                return std.fmt.allocPrint(self.allocator, "^{s}", .{inner}) catch return CodegenError.OutOfMemory;
            },
            .deref_expr => |deref| {
                const inner = try self.genExpr(deref.expr, hoisted_allocs);
                const reg = try self.newTmp();
                self.out.writer().print("    {s} = load {s}+0 as i64\n", .{ reg, inner }) catch return CodegenError.CodegenError;
                return reg;
            },
            .field_expr => |field| {
                const inner = try self.genExpr(field.expr, hoisted_allocs);
                const reg = try self.newTmp();

                // Look up the struct's type to find the field offset
                const expr_ty = self.tc.expr_types.get(field.expr) orelse return CodegenError.CodegenError;
                var curr_ty = expr_ty;
                while (true) {
                    switch (curr_ty.*) {
                        .pointer => |p| curr_ty = p,
                        .borrow => |b| curr_ty = b,
                        else => break,
                    }
                }

                if (curr_ty.* == .tuple) {
                    const index = std.fmt.parseInt(usize, field.field_name, 10) catch return CodegenError.CodegenError;
                    const layout = tupleFieldLayout(curr_ty.tuple, index) orelse return CodegenError.CodegenError;
                    self.out.writer().print("    {s} = load {s}+{} as {s}\n", .{ reg, inner, layout.offset, layout.ty_str }) catch return CodegenError.CodegenError;
                    return reg;
                }

                if (curr_ty.* != .user_defined) return CodegenError.CodegenError;
                const struct_decl = self.tc.structs.get(curr_ty.user_defined.name) orelse return CodegenError.CodegenError;

                var offset: usize = 0;
                var found = false;
                var field_ty_str: []const u8 = "i64";
                for (struct_decl.fields) |f| {
                    const size: usize = switch (f.ty.*) {
                        .primitive => |p| switch (p) {
                            .boolean => 1,
                            .integer => 8,
                            .float => 8,
                            .void_type => 8,
                        },
                        else => 8, // pointer or borrow
                    };
                    if (size == 8) {
                        offset = (offset + 7) & ~@as(usize, 7);
                    }
                    if (std.mem.eql(u8, f.name, field.field_name)) {
                        found = true;
                        field_ty_str = switch (f.ty.*) {
                            .primitive => |p| switch (p) {
                                .boolean => "u8",
                                .integer => "i64",
                                .float => "f64",
                                .void_type => "ptr",
                            },
                            else => "ptr",
                        };
                        break;
                    }
                    offset += size;
                }
                if (!found) return CodegenError.CodegenError;

                self.out.writer().print("    {s} = load {s}+{} as {s}\n", .{ reg, inner, offset, field_ty_str }) catch return CodegenError.CodegenError;
                return reg;
            },
            .struct_literal => |lit| {
                const reg = try self.newTmp();
                try self.genStructLiteralInto(reg, &lit, hoisted_allocs);
                return reg;
            },
            .enum_literal => |lit| {
                const reg = try self.newTmp();
                try self.genEnumLiteralInto(reg, &lit, hoisted_allocs);
                return reg;
            },
            .tuple_literal => |lit| {
                const reg = try self.newTmp();
                try self.genTupleLiteralInto(reg, &lit, hoisted_allocs);
                return reg;
            },
            .array_literal => |lit| {
                const reg = try self.newTmp();
                try self.genArrayLiteralInto(reg, &lit, hoisted_allocs);
                return reg;
            },
            .match_expr => |mat| {
                return try self.genMatchExpr(&mat, hoisted_allocs);
            },
            .await_expr => |aw| {
                const future_reg = try self.genExpr(aw.expr, hoisted_allocs);
                const out_reg = try self.newTmp();
                self.out.writer().print("    EXPAND FUTURE_READY_STATE_INTO_INNER {s}, {s}\n", .{ out_reg, future_reg }) catch return CodegenError.CodegenError;
                try self.emitRelease(future_reg);
                return out_reg;
            },
            .closure_literal => {
                const reg = try self.newTmp();
                self.out.writer().print("    {s} = 0\n", .{reg}) catch return CodegenError.CodegenError;
                return reg;
            },
            .index_expr => |idx| {
                const addr = try self.genIndexAddress(&idx, hoisted_allocs);
                const reg = try self.newTmp();
                self.out.writer().print("    {s} = load {s}+0 as {s}\n", .{ reg, addr.ptr, typeString(addr.elem_ty) }) catch return CodegenError.CodegenError;
                return reg;
            },
            .slice_expr => |slc| {
                return try self.genSliceExpr(&slc, hoisted_allocs);
            },
            .call_expr => |call| {
                if (arrayIterSumSource(&call)) |source| {
                    return try self.genArrayIterSum(source, hoisted_allocs);
                }

                if (self.closure_bindings.get(call.func_name)) |closure| {
                    return try self.genClosureCall(closure, &call, hoisted_allocs);
                }

                // Check if FFI function call
                if (call.args.len > 0) {
                    const recv_ty = self.tc.expr_types.get(call.args[0]) orelse null;
                    if (recv_ty) |rt| {
                        var curr = rt;
                        while (true) {
                            switch (curr.*) {
                                .borrow => |b| curr = b,
                                .pointer => |p| curr = p,
                                .user_defined => {
                                    var method_buf: [256]u8 = undefined;
                                    const method_key = std.fmt.bufPrint(&method_buf, "{s}", .{call.func_name}) catch break;
                                    if (self.tc.funcs.contains(method_key)) {
                                        var arg_regs = std.ArrayList([]const u8).init(self.allocator);
                                        const method_func = self.tc.funcs.get(method_key);
                                        for (call.args, 0..) |arg, i| {
                                            if (i == 0) {
                                                if (method_func) |func| {
                                                    if (func.params.len > 0 and func.params[0].is_borrow and arg.* != .borrow_expr) {
                                                        const recv_reg = try self.genExpr(arg, hoisted_allocs);
                                                        const borrow_arg = std.fmt.allocPrint(self.allocator, "&{s}", .{recv_reg}) catch return CodegenError.OutOfMemory;
                                                        arg_regs.append(borrow_arg) catch return CodegenError.OutOfMemory;
                                                        continue;
                                                    }
                                                }
                                            }
                                            arg_regs.append(try self.genCallArg(arg, hoisted_allocs)) catch return CodegenError.OutOfMemory;
                                        }
                                        const reg = try self.newTmp();
                                        self.out.writer().print("    {s} = call @{s}(", .{ reg, method_key }) catch return CodegenError.CodegenError;
                                        for (arg_regs.items, 0..) |ar, i| {
                                            if (i > 0) self.out.writer().print(", ", .{}) catch return CodegenError.CodegenError;
                                            self.out.writer().print("{s}", .{ar}) catch return CodegenError.CodegenError;
                                        }
                                        self.out.writer().print(")\n", .{}) catch return CodegenError.CodegenError;
                                        for (call.args, arg_regs.items) |arg, arg_reg| {
                                            if (callArgNeedsRelease(arg)) try self.emitRelease(arg_reg);
                                        }
                                        return reg;
                                    }
                                    break;
                                },
                                else => break,
                            }
                        }
                    }
                }

                if (self.tc.extern_funcs.contains(call.func_name) or self.tc.funcs.contains(call.func_name)) {
                    var arg_regs = std.ArrayList([]const u8).init(self.allocator);
                    defer arg_regs.deinit();
                    const maybe_func = self.tc.funcs.get(call.func_name);
                    for (call.args, 0..) |arg, i| {
                        if (i == 0) {
                            if (maybe_func) |func| {
                                if (func.params.len > 0 and func.params[0].is_borrow and arg.* != .borrow_expr) {
                                    const recv_reg = try self.genExpr(arg, hoisted_allocs);
                                    const borrow_arg = std.fmt.allocPrint(self.allocator, "&{s}", .{recv_reg}) catch return CodegenError.OutOfMemory;
                                    arg_regs.append(borrow_arg) catch return CodegenError.OutOfMemory;
                                    continue;
                                }
                            }
                        }
                        arg_regs.append(try self.genCallArg(arg, hoisted_allocs)) catch return CodegenError.OutOfMemory;
                    }
                    const reg = try self.newTmp();
                    self.out.writer().print("    {s} = call @{s}(", .{ reg, call.func_name }) catch return CodegenError.CodegenError;
                    for (arg_regs.items, 0..) |ar, i| {
                        if (i > 0) self.out.writer().print(", ", .{}) catch return CodegenError.CodegenError;
                        self.out.writer().print("{s}", .{ar}) catch return CodegenError.CodegenError;
                    }
                    self.out.writer().print(")\n", .{}) catch return CodegenError.CodegenError;
                    for (call.args, arg_regs.items) |arg, arg_reg| {
                        if (callArgNeedsRelease(arg)) {
                            try self.emitRelease(arg_reg);
                        }
                    }
                    return reg;
                }

                // If it is standard stack_alloc, it might be hoisted
                if (std.mem.eql(u8, call.func_name, "stack_alloc")) {
                    const reg = try self.newTmp();
                    self.out.writer().print("    {s} = stack_alloc {}\n", .{ reg, stackAllocSize(&call) }) catch return CodegenError.CodegenError;
                    return reg;
                }

                // panic(code) lowers to SA's panic intrinsic call syntax.
                if (std.mem.eql(u8, call.func_name, "panic")) {
                    const reg = try self.newTmp();
                    if (call.args.len > 0) {
                        const arg = call.args[0];
                        if (arg.* == .literal) {
                            switch (arg.literal) {
                                .int_val => |v| self.out.writer().print("    panic({})\n", .{v}) catch return CodegenError.CodegenError,
                                .bool_val => |v| self.out.writer().print("    panic({})\n", .{if (v) @as(u8, 1) else @as(u8, 0)}) catch return CodegenError.CodegenError,
                                else => {
                                    const code_reg = try self.genExpr(arg, hoisted_allocs);
                                    self.out.writer().print("    panic({s})\n", .{code_reg}) catch return CodegenError.CodegenError;
                                },
                            }
                        } else {
                            const code_reg = try self.genExpr(arg, hoisted_allocs);
                            self.out.writer().print("    panic({s})\n", .{code_reg}) catch return CodegenError.CodegenError;
                        }
                    } else {
                        self.out.writer().print("    panic(1)\n", .{}) catch return CodegenError.CodegenError;
                    }
                    return reg;
                }

                // Assume macro expansion call in Sla
                const reg = try self.newTmp();
                self.out.writer().print("    EXPAND {s}", .{call.func_name}) catch return CodegenError.CodegenError;
                for (call.args) |arg| {
                    const arg_reg = try self.genExpr(arg, hoisted_allocs);
                    self.out.writer().print(" {s}", .{arg_reg}) catch return CodegenError.CodegenError;
                }
                self.out.writer().print("\n", .{}) catch return CodegenError.CodegenError;
                return reg;
            },
            .if_expr => |ife| {
                const cond_reg = try self.genExpr(ife.cond, hoisted_allocs);
                const then_label = try self.newLabel("L_THEN");
                const else_label = try self.newLabel("L_ELSE");
                const merge_label = try self.newLabel("L_MERGE");
                const then_terminates = blockTerminates(ife.then_block);
                const else_terminates = if (ife.else_block) |eb| blockTerminates(eb) else false;
                const needs_merge = !then_terminates or !else_terminates;

                self.out.writer().print("    br {s} -> {s}, {s}\n\n", .{ cond_reg, then_label, else_label }) catch return CodegenError.CodegenError;

                self.out.writer().print("{s}:\n", .{then_label}) catch return CodegenError.CodegenError;
                self.out.writer().print("    !{s}\n", .{cond_reg}) catch return CodegenError.CodegenError;
                try self.genBlock(ife.then_block, hoisted_allocs);
                // Emit then block Phi cleanups
                if (ife.then_block.len > 0) {
                    if (self.tc.phi_cleanups.get(ife.then_block[ife.then_block.len - 1])) |list| {
                        for (list.items) |pv| {
                            self.out.writer().print("    !{s} // Phi alignment\n", .{pv}) catch return CodegenError.CodegenError;
                        }
                    }
                }
                if (needs_merge and !then_terminates) {
                    self.out.writer().print("    jmp {s}\n", .{merge_label}) catch return CodegenError.CodegenError;
                }
                self.out.writer().print("\n", .{}) catch return CodegenError.CodegenError;

                self.out.writer().print("{s}:\n", .{else_label}) catch return CodegenError.CodegenError;
                self.out.writer().print("    !{s}\n", .{cond_reg}) catch return CodegenError.CodegenError;
                if (ife.else_block) |eb| {
                    try self.genBlock(eb, hoisted_allocs);
                    // Emit else block Phi cleanups
                    if (eb.len > 0) {
                        if (self.tc.phi_cleanups.get(eb[eb.len - 1])) |list| {
                            for (list.items) |pv| {
                                self.out.writer().print("    !{s} // Phi alignment\n", .{pv}) catch return CodegenError.CodegenError;
                            }
                        }
                    }
                }
                if (needs_merge and !else_terminates) {
                    self.out.writer().print("    jmp {s}\n", .{merge_label}) catch return CodegenError.CodegenError;
                }
                self.out.writer().print("\n", .{}) catch return CodegenError.CodegenError;

                if (needs_merge) {
                    self.out.writer().print("{s}:\n", .{merge_label}) catch return CodegenError.CodegenError;
                }
                const reg = try self.newTmp();
                return reg;
            },
            .switch_expr => |swe| {
                const val_reg = try self.genExpr(swe.val, hoisted_allocs);
                const merge_label = try self.newLabel("L_SWITCH_MERGE");

                var cases_labels = std.ArrayList([]const u8).init(self.allocator);
                var check_labels = std.ArrayList([]const u8).init(self.allocator);

                for (swe.cases, 0..) |_, idx| {
                    const c_lbl = std.fmt.allocPrint(self.allocator, "L_CASE_{}_{}", .{ idx, self.label_idx }) catch return CodegenError.OutOfMemory;
                    const chk_lbl = std.fmt.allocPrint(self.allocator, "L_CHECK_{}_{}", .{ idx, self.label_idx }) catch return CodegenError.OutOfMemory;
                    cases_labels.append(c_lbl) catch return CodegenError.OutOfMemory;
                    check_labels.append(chk_lbl) catch return CodegenError.OutOfMemory;
                }
                self.label_idx += 1;

                // Jump to first check
                self.out.writer().print("    jmp {s}\n\n", .{check_labels.items[0]}) catch return CodegenError.CodegenError;

                // Generate equality checking ladder
                for (swe.cases, 0..) |case, idx| {
                    self.out.writer().print("{s}:\n", .{check_labels.items[idx]}) catch return CodegenError.CodegenError;
                    const is_eq = try self.newTmp();
                    const pat_reg = try self.genExpr(case.pattern, hoisted_allocs);
                    self.out.writer().print("    {s} = eq {s}, {s}\n", .{ is_eq, val_reg, pat_reg }) catch return CodegenError.CodegenError;

                    const next_chk = if (idx + 1 < swe.cases.len) check_labels.items[idx + 1] else merge_label;
                    self.out.writer().print("    br {s} -> {s}, {s}\n\n", .{ is_eq, cases_labels.items[idx], next_chk }) catch return CodegenError.CodegenError;

                    // Generate case body
                    self.out.writer().print("{s}:\n", .{cases_labels.items[idx]}) catch return CodegenError.CodegenError;
                    self.out.writer().print("    !{s}\n", .{is_eq}) catch return CodegenError.CodegenError;
                    self.out.writer().print("    !{s}\n", .{val_reg}) catch return CodegenError.CodegenError;
                    try self.genBlock(case.body, hoisted_allocs);
                    self.out.writer().print("    jmp {s}\n\n", .{merge_label}) catch return CodegenError.CodegenError;
                }

                self.out.writer().print("{s}:\n", .{merge_label}) catch return CodegenError.CodegenError;
                const reg = try self.newTmp();
                return reg;
            },
            .try_expr => |trye| {
                // Postfix ? unwrapper
                const inner_reg = try self.genExpr(trye.expr, hoisted_allocs);
                const is_err = try self.newTmp();
                self.out.writer().print("    {s} = load {s}+0 as u8 // check error state\n", .{ is_err, inner_reg }) catch return CodegenError.CodegenError;

                const ok_label = try self.newLabel("L_TRY_OK");
                const err_label = try self.newLabel("L_TRY_ERR");

                self.out.writer().print("    br {s} -> {s}, {s}\n\n", .{ is_err, err_label, ok_label }) catch return CodegenError.CodegenError;

                // Error branch
                self.out.writer().print("{s}:\n", .{err_label}) catch return CodegenError.CodegenError;
                self.out.writer().print("    !{s}\n", .{is_err}) catch return CodegenError.CodegenError;
                const err_payload = try self.newTmp();
                self.out.writer().print("    {s} = load {s}+8 as i64\n", .{ err_payload, inner_reg }) catch return CodegenError.CodegenError;
                self.out.writer().print("    !{s}\n", .{inner_reg}) catch return CodegenError.CodegenError;

                // Auto-cleanup all active local variables in current scopes before early return
                if (self.tc.cleanups.get(expr)) |list| {
                    for (list.items) |c_var| {
                        try self.emitRelease(c_var);
                    }
                }

                // Construct and return Err result structure
                const err_res = try self.newTmp();
                self.out.writer().print("    {s} = stack_alloc 16\n", .{err_res}) catch return CodegenError.CodegenError;
                self.out.writer().print("    store {s}+0, 1 as u8 // set is_err\n", .{err_res}) catch return CodegenError.CodegenError;
                self.out.writer().print("    store {s}+8, {s} as i64\n", .{ err_res, err_payload }) catch return CodegenError.CodegenError;
                self.out.writer().print("    !{s}\n", .{err_payload}) catch return CodegenError.CodegenError;
                self.out.writer().print("    return {s}\n\n", .{err_res}) catch return CodegenError.CodegenError;

                // Ok branch
                self.out.writer().print("{s}:\n", .{ok_label}) catch return CodegenError.CodegenError;
                self.out.writer().print("    !{s}\n", .{is_err}) catch return CodegenError.CodegenError;
                const ok_val = try self.newTmp();
                self.out.writer().print("    {s} = load {s}+8 as i64\n", .{ ok_val, inner_reg }) catch return CodegenError.CodegenError;
                self.out.writer().print("    !{s}\n", .{inner_reg}) catch return CodegenError.CodegenError;
                return ok_val;
            },
            else => return CodegenError.CodegenError,
        }
    }
};

test "basic code generation" {
    const source =
        \\fn sum(a: int, b: int) -> int {
        \\    return a + b;
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const parser_mod = @import("parser.zig");
    var p = parser_mod.Parser.init(arena.allocator(), source);
    const prog = try p.parseProgram();

    // Type check first to populate type metadata
    var tc = type_checker.TypeChecker.init(arena.allocator());
    defer tc.deinit();
    try tc.checkProgram(prog);

    var cg = Codegen.init(arena.allocator(), &tc);
    defer cg.deinit();

    const sa_code = try cg.generate(prog);

    // Verify generated instructions
    try std.testing.expect(std.mem.indexOf(u8, sa_code, "add") != null);
    try std.testing.expect(std.mem.indexOf(u8, sa_code, "return") != null);
}
