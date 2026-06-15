const std = @import("std");
const ast = @import("ast.zig");
const contract_parser = @import("contract_parser.zig");

pub const TypeError = error{
    UndefinedVariable,
    Redeclaration,
    TypeMismatch,
    UseAfterMove,
    InvalidBorrow,
    DereferenceNonPointer,
    FieldNotFound,
    NotAStruct,
    InvalidArgsCount,
    CompileError,
    OutOfMemory,
};

pub const ValueState = enum {
    active,
    consumed,
};

pub const Symbol = struct {
    name: []const u8,
    ty: *ast.Type,
    is_const: bool,
    state: ValueState,
};

pub const Scope = struct {
    allocator: std.mem.Allocator,
    parent: ?*Scope,
    symbols: std.StringHashMap(Symbol),

    pub fn init(allocator: std.mem.Allocator, parent: ?*Scope) !*Scope {
        const self = try allocator.create(Scope);
        self.* = .{
            .allocator = allocator,
            .parent = parent,
            .symbols = std.StringHashMap(Symbol).init(allocator),
        };
        return self;
    }

    pub fn deinit(self: *Scope) void {
        self.symbols.deinit();
        self.allocator.destroy(self);
    }

    pub fn define(self: *Scope, name: []const u8, ty: *ast.Type, is_const: bool) !void {
        if (self.symbols.contains(name)) return TypeError.Redeclaration;
        try self.symbols.put(name, .{
            .name = name,
            .ty = ty,
            .is_const = is_const,
            .state = .active,
        });
    }

    pub fn lookup(self: *Scope, name: []const u8) ?*Symbol {
        var curr: ?*Scope = self;
        while (curr) |s| {
            if (s.symbols.getPtr(name)) |sym| {
                return sym;
            }
            curr = s.parent;
        }
        return null;
    }

    pub fn lookupLocal(self: *Scope, name: []const u8) ?*Symbol {
        return self.symbols.getPtr(name);
    }
};

pub const TypeChecker = struct {
    allocator: std.mem.Allocator,
    structs: std.StringHashMap(*ast.StructDecl),
    enums: std.StringHashMap(*ast.EnumDecl),
    extern_funcs: std.StringHashMap(contract_parser.ExternalFunction),
    layout_defines: std.StringHashMap(contract_parser.LayoutDefine),
    scope_pool: std.ArrayList(*Scope),

    // Maps a return/block exit node to the variables that need to be dropped
    cleanups: std.AutoHashMap(*const ast.Node, std.ArrayList([]const u8)),
    // Maps a branch end to the variables to release for Phi resolution
    phi_cleanups: std.AutoHashMap(*const ast.Node, std.ArrayList([]const u8)),

    // Tracks internal Sla functions for validation
    funcs: std.StringHashMap(*ast.FuncDecl),
    // Tracks user-defined macros
    macros: std.StringHashMap(*ast.MacroDecl),
    // Maps expressions to their validated types for use in Codegen layout offsets
    expr_types: std.AutoHashMap(*const ast.Node, *ast.Type),

    last_error: []const u8,
    last_error_buf: [1024]u8,

    pub fn init(allocator: std.mem.Allocator) TypeChecker {
        return .{
            .allocator = allocator,
            .structs = std.StringHashMap(*ast.StructDecl).init(allocator),
            .enums = std.StringHashMap(*ast.EnumDecl).init(allocator),
            .extern_funcs = std.StringHashMap(contract_parser.ExternalFunction).init(allocator),
            .layout_defines = std.StringHashMap(contract_parser.LayoutDefine).init(allocator),
            .scope_pool = std.ArrayList(*Scope).init(allocator),
            .cleanups = std.AutoHashMap(*const ast.Node, std.ArrayList([]const u8)).init(allocator),
            .phi_cleanups = std.AutoHashMap(*const ast.Node, std.ArrayList([]const u8)).init(allocator),
            .funcs = std.StringHashMap(*ast.FuncDecl).init(allocator),
            .macros = std.StringHashMap(*ast.MacroDecl).init(allocator),
            .expr_types = std.AutoHashMap(*const ast.Node, *ast.Type).init(allocator),
            .last_error = "",
            .last_error_buf = undefined,
        };
    }

    pub fn setError(self: *TypeChecker, comptime fmt: []const u8, args: anytype) void {
        var fba = std.heap.FixedBufferAllocator.init(&self.last_error_buf);
        self.last_error = std.fmt.allocPrint(fba.allocator(), fmt, args) catch "Error formatting diagnostic";
    }

    pub fn deinit(self: *TypeChecker) void {
        self.structs.deinit();
        self.enums.deinit();
        self.extern_funcs.deinit();
        self.layout_defines.deinit();
        self.funcs.deinit();
        self.macros.deinit();
        self.expr_types.deinit();
        for (self.scope_pool.items) |s| {
            s.deinit();
        }
        self.scope_pool.deinit();

        var cleanup_iter = self.cleanups.valueIterator();
        while (cleanup_iter.next()) |list| {
            list.deinit();
        }
        self.cleanups.deinit();

        var phi_iter = self.phi_cleanups.valueIterator();
        while (phi_iter.next()) |list| {
            list.deinit();
        }
        self.phi_cleanups.deinit();
    }

    fn isInternalSymbol(name: []const u8) bool {
        return std.mem.eql(u8, name, "return_ty_sentinel");
    }

    fn isPrimitiveType(ty: *const ast.Type, primitive: ast.Primitive) bool {
        return switch (ty.*) {
            .primitive => |p| p == primitive,
            else => false,
        };
    }

    fn isNumericType(ty: *const ast.Type) bool {
        return switch (ty.*) {
            .primitive => |p| p == .integer or p == .float,
            else => false,
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

    fn makeFutureType(self: *TypeChecker, inner: *ast.Type) TypeError!*ast.Type {
        const ty = try self.allocator.create(ast.Type);
        ty.* = .{ .future = inner };
        return ty;
    }

    fn rootIdentifier(expr: *const ast.Node) ?[]const u8 {
        return switch (expr.*) {
            .identifier => |name| name,
            .index_expr => |idx| rootIdentifier(idx.target),
            .field_expr => |field| rootIdentifier(field.expr),
            else => null,
        };
    }

    fn findEnumVariant(e: *const ast.EnumDecl, name: []const u8) ?ast.EnumVariant {
        for (e.variants) |variant| {
            if (std.mem.eql(u8, variant.name, name)) return variant;
        }
        return null;
    }

    fn normalizeAbiTypeName(name: []const u8) []const u8 {
        var ty = std.mem.trim(u8, name, " \t\r");
        while (ty.len > 0 and (ty[0] == '^' or ty[0] == '&')) {
            ty = ty[1..];
        }
        return ty;
    }

    fn isIntegerAbiType(name: []const u8) bool {
        return std.mem.eql(u8, name, "i1") or
            std.mem.eql(u8, name, "u1") or
            std.mem.eql(u8, name, "i8") or
            std.mem.eql(u8, name, "u8") or
            std.mem.eql(u8, name, "i16") or
            std.mem.eql(u8, name, "u16") or
            std.mem.eql(u8, name, "i32") or
            std.mem.eql(u8, name, "u32") or
            std.mem.eql(u8, name, "i64") or
            std.mem.eql(u8, name, "u64") or
            std.mem.eql(u8, name, "usize") or
            std.mem.eql(u8, name, "isize");
    }

    fn setTypeFromAbiReturn(ret: *ast.Type, abi_ret_ty: []const u8) void {
        const raw_name = std.mem.trim(u8, abi_ret_ty, " \t\r");
        if (std.mem.endsWith(u8, raw_name, "!")) {
            ret.* = .{ .primitive = .void_type };
            return;
        }

        const name = normalizeAbiTypeName(abi_ret_ty);
        if (isIntegerAbiType(name)) {
            ret.* = .{ .primitive = .integer };
        } else if (std.mem.eql(u8, name, "f32") or std.mem.eql(u8, name, "f64")) {
            ret.* = .{ .primitive = .float };
        } else if (std.mem.eql(u8, name, "bool")) {
            ret.* = .{ .primitive = .boolean };
        } else {
            ret.* = .{ .primitive = .void_type };
        }
    }

    pub fn loadContracts(self: *TypeChecker, sai_content: []const u8, sal_content: []const u8) !void {
        var parser = contract_parser.ContractParser.init(self.allocator);

        const funcs = try parser.parseSai(sai_content);
        for (funcs) |f| {
            try self.extern_funcs.put(f.name, f);
        }

        const layouts = try parser.parseSal(sal_content);
        for (layouts) |l| {
            try self.layout_defines.put(l.name, l);
        }
    }

    pub fn checkProgram(self: *TypeChecker, program: *ast.Node) !void {
        if (program.* != .program) return TypeError.CompileError;

        // Register structs first
        for (program.program.decls) |decl| {
            if (decl.* == .struct_decl) {
                try self.structs.put(decl.struct_decl.name, &decl.struct_decl);
            } else if (decl.* == .enum_decl) {
                try self.enums.put(decl.enum_decl.name, &decl.enum_decl);
            }
        }

        // Register functions first
        for (program.program.decls) |decl| {
            if (decl.* == .func_decl) {
                try self.funcs.put(decl.func_decl.name, &decl.func_decl);
            }
        }

        // Register impl methods
        for (program.program.decls) |decl| {
            if (decl.* == .impl_decl) {
                for (decl.impl_decl.methods) |method| {
                    if (method.* != .func_decl) return TypeError.CompileError;
                    try self.funcs.put(method.func_decl.name, &method.func_decl);
                }
            }
        }

        // Register macros
        for (program.program.decls) |decl| {
            if (decl.* == .macro_decl) {
                try self.macros.put(decl.macro_decl.name, &decl.macro_decl);
            }
        }

        // Type check functions
        for (program.program.decls) |decl| {
            if (decl.* == .func_decl) {
                try self.checkFunc(&decl.func_decl);
            } else if (decl.* == .impl_decl) {
                try self.checkImpl(&decl.impl_decl);
            }
        }

        // Type check tests
        for (program.program.decls) |decl| {
            if (decl.* == .test_decl) {
                try self.checkTest(&decl.test_decl);
            }
        }
    }

    fn checkTest(self: *TypeChecker, test_decl: *ast.TestDecl) !void {
        var scope = try Scope.init(self.allocator, null);
        try self.scope_pool.append(scope);

        const ret_ty = try self.allocator.create(ast.Type);
        ret_ty.* = .{ .primitive = .void_type };

        try scope.define("return_ty_sentinel", ret_ty, true);

        try self.checkBlock(test_decl.body, scope, ret_ty, null);

        var iter = scope.symbols.valueIterator();
        while (iter.next()) |sym| {
            if (sym.state == .active and !isInternalSymbol(sym.name)) {
                sym.state = .consumed;
            }
        }
    }

    fn checkFunc(self: *TypeChecker, func: *ast.FuncDecl) !void {
        var scope = try Scope.init(self.allocator, null);
        try self.scope_pool.append(scope);

        try scope.define("return_ty_sentinel", func.ret_ty, true);

        for (func.params) |p| {
            try scope.define(p.name, p.ty, false);
        }

        try self.checkBlock(func.body, scope, func.ret_ty, null);

        // Verify that all parameters or locals in the function root scope are consumed (or we auto-release them)
        // For parameters/locals remaining active at function exit, compile-time checklist forces release.
        var iter = scope.symbols.valueIterator();
        while (iter.next()) |sym| {
            if (sym.state == .active and isPrimitiveType(func.ret_ty, .void_type) and !isInternalSymbol(sym.name)) {
                // If it returns void, we can auto-release. If it's a value return, return statement handles cleanups.
                sym.state = .consumed;
            }
        }
    }

    fn checkBlock(
        self: *TypeChecker,
        body: []const *ast.Node,
        parent_scope: *Scope,
        ret_ty: *ast.Type,
        loop_node: ?*ast.Node,
    ) !void {
        var scope = try Scope.init(self.allocator, parent_scope);
        try self.scope_pool.append(scope);

        for (body) |stmt| {
            try self.checkStmt(stmt, scope, ret_ty, loop_node);
        }

        // Auto-cleanup for variables local to this block that are still active
        var cleanup_list = std.ArrayList([]const u8).init(self.allocator);
        var iter = scope.symbols.valueIterator();
        while (iter.next()) |sym| {
            if (sym.state == .active and !isInternalSymbol(sym.name)) {
                try cleanup_list.append(sym.name);
                sym.state = .consumed;
            }
        }

        if (cleanup_list.items.len > 0) {
            // Associated cleanup list with the block's last statement, or block node itself
            if (body.len > 0) {
                const last_stmt = body[body.len - 1];
                if (last_stmt.* != .return_stmt) {
                    try self.cleanups.put(last_stmt, cleanup_list);
                } else {
                    cleanup_list.deinit();
                }
            } else {
                cleanup_list.deinit();
            }
        } else {
            cleanup_list.deinit();
        }
    }

    fn checkStmt(
        self: *TypeChecker,
        stmt: *ast.Node,
        scope: *Scope,
        ret_ty: *ast.Type,
        loop_node: ?*ast.Node,
    ) TypeError!void {
        _ = loop_node;
        self.checkStmtImpl(stmt, scope, ret_ty) catch |err| {
            if (self.last_error.len == 0) {
                self.setError("checkStmt failed at node tag {s}", .{@tagName(stmt.*)});
            }
            return err;
        };
    }

    fn checkStmtImpl(
        self: *TypeChecker,
        stmt: *ast.Node,
        scope: *Scope,
        ret_ty: *ast.Type,
    ) TypeError!void {
        switch (stmt.*) {
            .let_stmt => |let| {
                const val_ty = try self.checkExpr(let.value, scope);
                const declared_ty = let.ty orelse val_ty;
                if (!self.typesEqual(declared_ty, val_ty)) {
                    self.setError("TypeMismatch in let {s}: declared tag={s}, val tag={s}", .{ let.name, @tagName(declared_ty.*), @tagName(val_ty.*) });
                    return TypeError.TypeMismatch;
                }
                try scope.define(let.name, declared_ty, false);
            },
            .let_destructure_stmt => |let| {
                const val_ty = try self.checkExpr(let.value, scope);
                if (val_ty.* != .tuple) {
                    self.setError("let destructuring requires tuple value, actual tag={s}", .{@tagName(val_ty.*)});
                    return TypeError.TypeMismatch;
                }
                if (let.names.len != val_ty.tuple.elems.len) {
                    self.setError("let destructuring arity mismatch: pattern={}, tuple={}", .{ let.names.len, val_ty.tuple.elems.len });
                    return TypeError.InvalidArgsCount;
                }
                for (let.names, val_ty.tuple.elems) |name, elem_ty| {
                    try scope.define(name, elem_ty, false);
                }
                if (rootIdentifier(let.value)) |name| {
                    const sym = scope.lookup(name) orelse return TypeError.UndefinedVariable;
                    if (sym.state == .consumed) return TypeError.UseAfterMove;
                    sym.state = .consumed;
                }
            },
            .const_stmt => |c| {
                const val_ty = try self.checkExpr(c.value, scope);
                const declared_ty = c.ty orelse val_ty;
                if (!self.typesEqual(declared_ty, val_ty)) {
                    self.setError("TypeMismatch in const {s}: declared tag={s}, val tag={s}", .{ c.name, @tagName(declared_ty.*), @tagName(val_ty.*) });
                    return TypeError.TypeMismatch;
                }
                try scope.define(c.name, declared_ty, true);
            },
            .assign_stmt => |assign| {
                const target_ty = try self.checkExpr(assign.target, scope);
                const val_ty = try self.checkExpr(assign.value, scope);
                if (!self.typesEqual(target_ty, val_ty)) {
                    self.setError("TypeMismatch in assign: target tag={s}, val tag={s}", .{ @tagName(target_ty.*), @tagName(val_ty.*) });
                    return TypeError.TypeMismatch;
                }
                // let bindings can be reassigned and indexed; const bindings cannot.
                if (rootIdentifier(assign.target)) |root_name| {
                    const sym = scope.lookup(root_name) orelse return TypeError.UndefinedVariable;
                    if (sym.is_const) return TypeError.CompileError;
                }
            },
            .return_stmt => |ret| {
                if (ret.value) |val| {
                    const val_ty = try self.checkExpr(val, scope);
                    if (!self.typesEqual(ret_ty, val_ty)) {
                        self.setError("TypeMismatch in return: expected tag={s}, actual tag={s}", .{ @tagName(ret_ty.*), @tagName(val_ty.*) });
                        return TypeError.TypeMismatch;
                    }
                } else {
                    if (!isPrimitiveType(ret_ty, .void_type)) {
                        self.setError("TypeMismatch in return void: expected tag={s}", .{@tagName(ret_ty.*)});
                        return TypeError.TypeMismatch;
                    }
                }

                // Collect all active variables across all scope frames up to the function root
                var cleanup_list = std.ArrayList([]const u8).init(self.allocator);
                var curr: ?*Scope = scope;
                var returned_var: ?[]const u8 = null;
                if (ret.value) |val| {
                    if (val.* == .identifier) {
                        returned_var = val.identifier;
                    }
                }
                while (curr) |s| {
                    var iter = s.symbols.valueIterator();
                    while (iter.next()) |sym| {
                        if (sym.state == .active and !isInternalSymbol(sym.name)) {
                            if (returned_var) |rv| {
                                if (std.mem.eql(u8, sym.name, rv)) continue;
                            }
                            try cleanup_list.append(sym.name);
                        }
                    }
                    curr = s.parent;
                }
                if (cleanup_list.items.len > 0) {
                    try self.cleanups.put(stmt, cleanup_list);
                } else {
                    cleanup_list.deinit();
                }
            },
            .for_stmt => |*f| {
                // Loop counter start and end must be integers
                const start_ty = try self.checkExpr(f.start, scope);
                const end_ty = try self.checkExpr(f.end, scope);
                if (!isPrimitiveType(start_ty, .integer) or !isPrimitiveType(end_ty, .integer)) {
                    return TypeError.TypeMismatch;
                }

                var loop_scope = try Scope.init(self.allocator, scope);
                try self.scope_pool.append(loop_scope);

                // Add loop variable
                const i_ty = try self.allocator.create(ast.Type);
                i_ty.* = .{ .primitive = .integer };
                try loop_scope.define(f.var_name, i_ty, true);

                try self.checkBlock(f.body, loop_scope, ret_ty, stmt);
            },
            .release_stmt => |rel| {
                const sym = scope.lookup(rel.var_name) orelse return TypeError.UndefinedVariable;
                if (sym.state == .consumed) return TypeError.UseAfterMove;
                sym.state = .consumed;
            },
            .expr_stmt => |expr| {
                _ = try self.checkExpr(expr, scope);
            },
            else => return TypeError.CompileError,
        }
    }

    fn checkExpr(self: *TypeChecker, expr: *ast.Node, scope: *Scope) TypeError!*ast.Type {
        const ty = self.checkExprImpl(expr, scope) catch |err| {
            if (self.last_error.len == 0) {
                self.setError("checkExpr failed at node tag {s}", .{@tagName(expr.*)});
            }
            return err;
        };
        self.expr_types.put(expr, ty) catch return TypeError.OutOfMemory;
        return ty;
    }

    fn checkExprImpl(self: *TypeChecker, expr: *ast.Node, scope: *Scope) TypeError!*ast.Type {
        switch (expr.*) {
            .literal => |lit| {
                const ty = try self.allocator.create(ast.Type);
                switch (lit) {
                    .int_val => ty.* = .{ .primitive = .integer },
                    .float_val => ty.* = .{ .primitive = .float },
                    .bool_val => ty.* = .{ .primitive = .boolean },
                    .string_val => {
                        // In Sla, string literal evaluates to ptr (pointing to char array)
                        ty.* = .{ .primitive = .void_type }; // map to ptr/void
                    },
                }
                return ty;
            },
            .identifier => |name| {
                const sym = scope.lookup(name) orelse return TypeError.UndefinedVariable;
                if (sym.state == .consumed) return TypeError.UseAfterMove;
                return sym.ty;
            },
            .binary_expr => |bin| {
                const l_ty = try self.checkExpr(bin.left, scope);
                const r_ty = try self.checkExpr(bin.right, scope);
                if (!self.typesEqual(l_ty, r_ty)) {
                    return TypeError.TypeMismatch;
                }
                const ty = try self.allocator.create(ast.Type);
                switch (bin.op) {
                    .add, .sub, .mul, .div, .mod => {
                        if (!isNumericType(l_ty)) {
                            return TypeError.TypeMismatch;
                        }
                        ty.* = l_ty.*;
                    },
                    .eq, .ne, .lt, .le, .gt, .ge => {
                        ty.* = .{ .primitive = .integer }; // comparisons produce 0/1 i64
                    },
                    .logical_and, .logical_or => {
                        if (!isPrimitiveType(l_ty, .boolean)) return TypeError.TypeMismatch;
                        ty.* = .{ .primitive = .boolean };
                    },
                }
                return ty;
            },
            .borrow_expr => |borrow| {
                const inner_ty = try self.checkExpr(borrow.expr, scope);
                // For borrow, variable must be Active
                if (borrow.expr.* == .identifier) {
                    const sym = scope.lookup(borrow.expr.identifier) orelse return TypeError.UndefinedVariable;
                    if (sym.state == .consumed) return TypeError.UseAfterMove;
                }
                const ty = try self.allocator.create(ast.Type);
                ty.* = .{ .borrow = inner_ty };
                return ty;
            },
            .move_expr => |move| {
                const inner_ty = try self.checkExpr(move.expr, scope);
                if (move.expr.* == .identifier) {
                    const sym = scope.lookup(move.expr.identifier) orelse return TypeError.UndefinedVariable;
                    if (sym.state == .consumed) return TypeError.UseAfterMove;
                    sym.state = .consumed; // Consume ownership
                }
                return inner_ty;
            },
            .deref_expr => |deref| {
                const inner_ty = try self.checkExpr(deref.expr, scope);
                switch (inner_ty.*) {
                    .pointer => |p| return p,
                    .borrow => |b| return b,
                    else => return TypeError.DereferenceNonPointer,
                }
            },
            .field_expr => |field| {
                const struct_ty = try self.checkExpr(field.expr, scope);
                switch (struct_ty.*) {
                    .user_defined => |ud| {
                        const decl = self.structs.get(ud.name) orelse return TypeError.NotAStruct;
                        for (decl.fields) |f| {
                            if (std.mem.eql(u8, f.name, field.field_name)) {
                                return f.ty;
                            }
                        }
                        return TypeError.FieldNotFound;
                    },
                    .tuple => |tuple| {
                        const index = std.fmt.parseInt(usize, field.field_name, 10) catch return TypeError.FieldNotFound;
                        if (index >= tuple.elems.len) return TypeError.FieldNotFound;
                        return tuple.elems[index];
                    },
                    else => return TypeError.NotAStruct,
                }
            },
            .struct_literal => |lit| {
                if (lit.ty.* != .user_defined) return TypeError.NotAStruct;
                const ud = lit.ty.user_defined;
                const decl = self.structs.get(ud.name) orelse return TypeError.NotAStruct;

                var seen = std.StringHashMap(void).init(self.allocator);
                defer seen.deinit();

                for (lit.fields) |literal_field| {
                    if (seen.contains(literal_field.name)) {
                        self.setError("Duplicate field in struct literal: {s}.{s}", .{ ud.name, literal_field.name });
                        return TypeError.CompileError;
                    }
                    try seen.put(literal_field.name, {});

                    var expected_ty: ?*ast.Type = null;
                    for (decl.fields) |decl_field| {
                        if (std.mem.eql(u8, decl_field.name, literal_field.name)) {
                            expected_ty = decl_field.ty;
                            break;
                        }
                    }

                    const field_ty = expected_ty orelse {
                        self.setError("Field not found in struct literal: {s}.{s}", .{ ud.name, literal_field.name });
                        return TypeError.FieldNotFound;
                    };
                    const value_ty = try self.checkExpr(literal_field.value, scope);
                    if (!self.typesEqual(field_ty, value_ty)) {
                        self.setError("TypeMismatch in struct literal field {s}.{s}: expected tag={s}, actual tag={s}", .{ ud.name, literal_field.name, @tagName(field_ty.*), @tagName(value_ty.*) });
                        return TypeError.TypeMismatch;
                    }
                }

                if (seen.count() != decl.fields.len) {
                    self.setError("Missing field in struct literal: {s}", .{ud.name});
                    return TypeError.FieldNotFound;
                }

                return lit.ty;
            },
            .enum_literal => |lit| {
                const decl = self.enums.get(lit.enum_name) orelse return TypeError.NotAStruct;
                const variant = findEnumVariant(decl, lit.variant_name) orelse return TypeError.FieldNotFound;

                var seen = std.StringHashMap(void).init(self.allocator);
                defer seen.deinit();

                for (lit.fields) |literal_field| {
                    if (seen.contains(literal_field.name)) return TypeError.CompileError;
                    try seen.put(literal_field.name, {});

                    var expected_ty: ?*ast.Type = null;
                    for (variant.fields) |field| {
                        if (std.mem.eql(u8, field.name, literal_field.name)) {
                            expected_ty = field.ty;
                            break;
                        }
                    }
                    const field_ty = expected_ty orelse return TypeError.FieldNotFound;
                    const value_ty = try self.checkExpr(literal_field.value, scope);
                    if (!self.typesEqual(field_ty, value_ty)) return TypeError.TypeMismatch;
                }
                if (seen.count() != variant.fields.len) return TypeError.FieldNotFound;

                const ty = try self.allocator.create(ast.Type);
                ty.* = .{ .user_defined = .{ .name = lit.enum_name, .generics = &.{} } };
                return ty;
            },
            .tuple_literal => |lit| {
                if (lit.elements.len == 0) {
                    self.setError("Cannot infer empty tuple literal type", .{});
                    return TypeError.TypeMismatch;
                }

                var elems = std.ArrayList(*ast.Type).init(self.allocator);
                for (lit.elements) |elem| {
                    try elems.append(try self.checkExpr(elem, scope));
                }

                const ty = try self.allocator.create(ast.Type);
                ty.* = .{ .tuple = .{ .elems = try elems.toOwnedSlice() } };
                return ty;
            },
            .array_literal => |lit| {
                if (lit.elements.len == 0) {
                    self.setError("Cannot infer empty array literal type", .{});
                    return TypeError.TypeMismatch;
                }

                const elem_ty = try self.checkExpr(lit.elements[0], scope);
                for (lit.elements[1..]) |elem| {
                    const curr_ty = try self.checkExpr(elem, scope);
                    if (!self.typesEqual(elem_ty, curr_ty)) {
                        self.setError("TypeMismatch in array literal: element tag={s}, actual tag={s}", .{ @tagName(elem_ty.*), @tagName(curr_ty.*) });
                        return TypeError.TypeMismatch;
                    }
                }

                const ty = try self.allocator.create(ast.Type);
                ty.* = .{ .array = .{ .elem = elem_ty, .len = lit.elements.len } };
                return ty;
            },
            .index_expr => |idx| {
                const target_ty = try self.checkExpr(idx.target, scope);
                const index_ty = try self.checkExpr(idx.index, scope);
                if (!isPrimitiveType(index_ty, .integer)) return TypeError.TypeMismatch;

                const arr = arrayType(target_ty) orelse return TypeError.TypeMismatch;
                return arr.elem;
            },
            .slice_expr => |slc| {
                const target_ty = try self.checkExpr(slc.target, scope);
                const start_ty = try self.checkExpr(slc.start, scope);
                const end_ty = try self.checkExpr(slc.end, scope);
                if (!isPrimitiveType(start_ty, .integer) or !isPrimitiveType(end_ty, .integer)) return TypeError.TypeMismatch;

                const arr = arrayType(target_ty) orelse return TypeError.TypeMismatch;
                if (slc.start.* != .literal or slc.start.literal != .int_val or slc.end.* != .literal or slc.end.literal != .int_val) {
                    self.setError("slice ranges currently require integer literal bounds", .{});
                    return TypeError.TypeMismatch;
                }
                const start = slc.start.literal.int_val;
                const end = slc.end.literal.int_val;
                if (start < 0 or end < start or @as(usize, @intCast(end)) > arr.len) {
                    self.setError("slice range out of bounds: {}..{} for len {}", .{ start, end, arr.len });
                    return TypeError.TypeMismatch;
                }

                const ty = try self.allocator.create(ast.Type);
                ty.* = .{ .array = .{ .elem = arr.elem, .len = @as(usize, @intCast(end - start)) } };
                return ty;
            },
            .await_expr => |aw| {
                const future_ty = try self.checkExpr(aw.expr, scope);
                const inner_ty = switch (future_ty.*) {
                    .future => |inner| inner,
                    else => {
                        self.setError("await requires future<T>, actual tag={s}", .{@tagName(future_ty.*)});
                        return TypeError.TypeMismatch;
                    },
                };
                if (rootIdentifier(aw.expr)) |name| {
                    const sym = scope.lookup(name) orelse return TypeError.UndefinedVariable;
                    if (sym.state == .consumed) return TypeError.UseAfterMove;
                    sym.state = .consumed;
                }
                return inner_ty;
            },
            .closure_literal => |lit| {
                var closure_scope = try Scope.init(self.allocator, scope);
                try self.scope_pool.append(closure_scope);

                var param_types = std.ArrayList(*ast.Type).init(self.allocator);
                for (lit.params) |p| {
                    try closure_scope.define(p.name, p.ty, true);
                    try param_types.append(p.ty);
                }

                const ret_ty = try self.checkExpr(lit.body, closure_scope);
                const ty = try self.allocator.create(ast.Type);
                ty.* = .{ .closure = .{ .params = try param_types.toOwnedSlice(), .ret = ret_ty } };
                return ty;
            },
            .call_expr => |call| {
                if (std.mem.eql(u8, call.func_name, "println")) {
                    for (call.args) |arg| {
                        _ = try self.checkExpr(arg, scope);
                    }
                    const ret = try self.allocator.create(ast.Type);
                    ret.* = .{ .primitive = .void_type };
                    return ret;
                }

                if (scope.lookup(call.func_name)) |sym| {
                    if (sym.state == .consumed) return TypeError.UseAfterMove;
                    if (sym.ty.* == .closure) {
                        const closure = sym.ty.closure;
                        if (closure.params.len != call.args.len) return TypeError.InvalidArgsCount;
                        for (closure.params, call.args) |param_ty, arg| {
                            const arg_ty = try self.checkExpr(arg, scope);
                            if (!self.typesEqual(param_ty, arg_ty)) return TypeError.TypeMismatch;
                        }
                        return closure.ret;
                    }
                }

                // 1. Check Sla internal function calls
                const method_match = blk: {
                    if (call.args.len == 0) break :blk null;
                    const recv_ty = try self.checkExpr(call.args[0], scope);
                    var curr = recv_ty;
                    while (true) {
                        switch (curr.*) {
                            .borrow => |b| curr = b,
                            .pointer => |p| curr = p,
                            .user_defined => |ud| {
                                var method_buf: [256]u8 = undefined;
                                _ = ud;
                                break :blk std.fmt.bufPrint(&method_buf, "{s}", .{call.func_name}) catch null;
                            },
                            else => break :blk null,
                        }
                    }
                };

                if (method_match) |method_name| {
                    if (self.funcs.get(method_name)) |func| {
                        if (func.params.len != call.args.len) return TypeError.InvalidArgsCount;
                        for (func.params, call.args) |param, arg| {
                            if (param.is_move and arg.* != .move_expr) return TypeError.TypeMismatch;
                            if (param.is_borrow and call.args[0] == arg and arg.* != .borrow_expr) {
                                const arg_ty = try self.checkExpr(arg, scope);
                                if (!self.typesEqual(param.ty, arg_ty)) return TypeError.TypeMismatch;
                                continue;
                            }
                            if (param.is_borrow and arg.* != .borrow_expr) return TypeError.TypeMismatch;
                            if (!param.is_move and !param.is_borrow and (arg.* == .move_expr or arg.* == .borrow_expr)) return TypeError.TypeMismatch;
                            const arg_ty = try self.checkExpr(arg, scope);
                            if (!self.typesEqual(param.ty, arg_ty)) return TypeError.TypeMismatch;
                        }
                        if (func.is_async) {
                            return try self.makeFutureType(func.ret_ty);
                        }
                        return func.ret_ty;
                    }
                }

                if (self.funcs.get(call.func_name)) |func| {
                    if (func.params.len != call.args.len) return TypeError.InvalidArgsCount;
                    for (func.params, call.args) |param, arg| {
                        if (param.is_move and arg.* != .move_expr) {
                            self.setError("Call to {s} requires move argument for parameter {s}", .{ call.func_name, param.name });
                            return TypeError.TypeMismatch;
                        }
                        if (param.is_borrow and arg.* != .borrow_expr) {
                            self.setError("Call to {s} requires borrow argument for parameter {s}", .{ call.func_name, param.name });
                            return TypeError.TypeMismatch;
                        }
                        if (!param.is_move and !param.is_borrow and (arg.* == .move_expr or arg.* == .borrow_expr)) {
                            self.setError("Call to {s} passes capability argument to plain parameter {s}", .{ call.func_name, param.name });
                            return TypeError.TypeMismatch;
                        }
                        const arg_ty = try self.checkExpr(arg, scope);
                        if (!self.typesEqual(param.ty, arg_ty)) return TypeError.TypeMismatch;
                    }
                    if (func.is_async) {
                        return try self.makeFutureType(func.ret_ty);
                    }
                    return func.ret_ty;
                }

                if (std.mem.eql(u8, call.func_name, "iter")) {
                    if (call.args.len != 1) return TypeError.InvalidArgsCount;
                    const target_ty = try self.checkExpr(call.args[0], scope);
                    _ = arrayType(target_ty) orelse return TypeError.TypeMismatch;
                    return target_ty;
                }

                if (std.mem.eql(u8, call.func_name, "sum")) {
                    if (call.args.len != 1) return TypeError.InvalidArgsCount;
                    const target_ty = try self.checkExpr(call.args[0], scope);
                    _ = arrayType(target_ty) orelse return TypeError.TypeMismatch;
                    const ret = try self.allocator.create(ast.Type);
                    ret.* = .{ .primitive = .integer };
                    return ret;
                }

                // 2. Check FFI functions
                if (self.extern_funcs.get(call.func_name)) |ext| {
                    if (ext.params.len != call.args.len) return TypeError.InvalidArgsCount;
                    for (ext.params, call.args) |param, arg| {
                        const arg_ty = try self.checkExpr(arg, scope);
                        _ = param;
                        _ = arg_ty; // bypass signature checks for FFI pointers
                    }
                    const ret = try self.allocator.create(ast.Type);
                    setTypeFromAbiReturn(ret, ext.ret_ty);
                    return ret;
                }

                // 3. Check if it's a built-in: stack_alloc, panic
                if (std.mem.eql(u8, call.func_name, "stack_alloc") or
                    std.mem.eql(u8, call.func_name, "panic"))
                {
                    for (call.args) |arg| {
                        _ = try self.checkExpr(arg, scope);
                    }
                    const ret = try self.allocator.create(ast.Type);
                    ret.* = .{ .primitive = .void_type };
                    return ret;
                }

                // 4. Check user-defined macro calls
                if (self.macros.get(call.func_name)) |mac| {
                    _ = mac;
                    for (call.args) |arg| {
                        _ = try self.checkExpr(arg, scope);
                    }
                    const ret = try self.allocator.create(ast.Type);
                    ret.* = .{ .primitive = .void_type };
                    return ret;
                }

                if (call.args.len > 0) {
                    const recv_ty = try self.checkExpr(call.args[0], scope);
                    var curr = recv_ty;
                    while (true) {
                        switch (curr.*) {
                            .borrow => |b| curr = b,
                            .pointer => |p| curr = p,
                            .user_defined => |ud| {
                                var method_buf: [256]u8 = undefined;
                                const method_key = std.fmt.bufPrint(&method_buf, "{s}_{s}", .{ ud.name, call.func_name }) catch break;
                                if (self.funcs.get(method_key)) |func| {
                                    if (func.params.len != call.args.len) return TypeError.InvalidArgsCount;
                                    for (func.params, call.args) |param, arg| {
                                        if (param.is_move and arg.* != .move_expr) {
                                            self.setError("Call to {s} requires move argument for parameter {s}", .{ call.func_name, param.name });
                                            return TypeError.TypeMismatch;
                                        }
                                        if (param.is_borrow and arg.* != .borrow_expr) {
                                            self.setError("Call to {s} requires borrow argument for parameter {s}", .{ call.func_name, param.name });
                                            return TypeError.TypeMismatch;
                                        }
                                        if (!param.is_move and !param.is_borrow and (arg.* == .move_expr or arg.* == .borrow_expr)) {
                                            self.setError("Call to {s} passes capability argument to plain parameter {s}", .{ call.func_name, param.name });
                                            return TypeError.TypeMismatch;
                                        }
                                        const arg_ty = try self.checkExpr(arg, scope);
                                        if (!self.typesEqual(param.ty, arg_ty)) return TypeError.TypeMismatch;
                                    }
                                    if (func.is_async) return try self.makeFutureType(func.ret_ty);
                                    return func.ret_ty;
                                }
                                break;
                            },
                            else => break,
                        }
                    }
                }

                // If not found anywhere, undefined function call
                return TypeError.UndefinedVariable;
            },
            .if_expr => |*ife| {
                const cond_ty = try self.checkExpr(ife.cond, scope);
                // Comparisons produce integers (0/1) in SA; booleans are also fine.
                if (cond_ty.* != .primitive) return TypeError.TypeMismatch;
                switch (cond_ty.primitive) {
                    .boolean, .integer => {},
                    else => return TypeError.TypeMismatch,
                }

                if (ife.cond.* == .identifier) {
                    const sym = scope.lookup(ife.cond.identifier) orelse return TypeError.UndefinedVariable;
                    if (sym.state == .consumed) return TypeError.UseAfterMove;
                    sym.state = .consumed;
                }

                // For branching, save active symbols and states
                var saved_states = std.StringHashMap(ValueState).init(self.allocator);
                defer saved_states.deinit();

                var curr: ?*Scope = scope;
                while (curr) |s| {
                    var iter = s.symbols.iterator();
                    while (iter.next()) |entry| {
                        try saved_states.put(entry.key_ptr.*, entry.value_ptr.state);
                    }
                    curr = s.parent;
                }

                // Check then_block
                try self.checkBlock(ife.then_block, scope, scope.lookup("return_ty_sentinel").?.ty, null);

                // Collect states after then_block
                var then_states = std.StringHashMap(ValueState).init(self.allocator);
                defer then_states.deinit();
                curr = scope;
                while (curr) |s| {
                    var iter = s.symbols.iterator();
                    while (iter.next()) |entry| {
                        try then_states.put(entry.key_ptr.*, entry.value_ptr.state);
                    }
                    curr = s.parent;
                }

                // Restore scope state for else_block check
                curr = scope;
                while (curr) |s| {
                    var iter = s.symbols.iterator();
                    while (iter.next()) |entry| {
                        if (saved_states.get(entry.key_ptr.*)) |st| {
                            entry.value_ptr.state = st;
                        }
                    }
                    curr = s.parent;
                }

                // Check else_block
                if (ife.else_block) |eb| {
                    try self.checkBlock(eb, scope, scope.lookup("return_ty_sentinel").?.ty, null);
                }

                // Re-align states at merge point (Phi Resolution)
                // If a variable is active in one branch but consumed in another, we release it in the active branch.
                curr = scope;
                while (curr) |s| {
                    var iter = s.symbols.iterator();
                    while (iter.next()) |entry| {
                        const name = entry.key_ptr.*;
                        if (isInternalSymbol(name)) continue;
                        const else_state = entry.value_ptr.state;
                        const then_state = then_states.get(name) orelse .active;

                        if (then_state != else_state) {
                            // Phi conflict! We must demote the active one to consumed
                            entry.value_ptr.state = .consumed;

                            if (then_state == .active) {
                                // Add to then branch's phi cleanups
                                if (ife.then_block.len > 0) {
                                    const last = ife.then_block[ife.then_block.len - 1];
                                    var list = self.phi_cleanups.get(last) orelse std.ArrayList([]const u8).init(self.allocator);
                                    try list.append(name);
                                    try self.phi_cleanups.put(last, list);
                                }
                            } else {
                                // Add to else branch's phi cleanups
                                if (ife.else_block) |eb| {
                                    if (eb.len > 0) {
                                        const last = eb[eb.len - 1];
                                        var list = self.phi_cleanups.get(last) orelse std.ArrayList([]const u8).init(self.allocator);
                                        try list.append(name);
                                        try self.phi_cleanups.put(last, list);
                                    }
                                }
                            }
                        }
                    }
                    curr = s.parent;
                }

                const ty = try self.allocator.create(ast.Type);
                ty.* = .{ .primitive = .void_type };
                return ty;
            },
            .switch_expr => |*swe| {
                const val_ty = try self.checkExpr(swe.val, scope);
                _ = val_ty;

                if (swe.val.* == .identifier) {
                    const sym = scope.lookup(swe.val.identifier) orelse return TypeError.UndefinedVariable;
                    if (sym.state == .consumed) return TypeError.UseAfterMove;
                    sym.state = .consumed;
                }

                // For simplicity, switch patterns are literal/identifiers.
                // We return void or default case type.
                for (swe.cases) |case| {
                    try self.checkBlock(case.body, scope, scope.lookup("return_ty_sentinel").?.ty, null);
                }

                const ty = try self.allocator.create(ast.Type);
                ty.* = .{ .primitive = .void_type };
                return ty;
            },
            .match_expr => |*mat| {
                const val_ty = try self.checkExpr(mat.val, scope);
                if (val_ty.* != .user_defined) return TypeError.TypeMismatch;
                const decl = self.enums.get(val_ty.user_defined.name) orelse return TypeError.NotAStruct;

                for (mat.cases) |case| {
                    if (!std.mem.eql(u8, case.pattern.enum_name, decl.name)) return TypeError.TypeMismatch;
                    const variant = findEnumVariant(decl, case.pattern.variant_name) orelse return TypeError.FieldNotFound;
                    if (case.pattern.bindings.len != variant.fields.len) return TypeError.InvalidArgsCount;

                    var pattern_scope = try Scope.init(self.allocator, scope);
                    try self.scope_pool.append(pattern_scope);
                    for (case.pattern.bindings, variant.fields) |binding, field| {
                        try pattern_scope.define(binding, field.ty, true);
                    }
                    try self.checkBlock(case.body, pattern_scope, scope.lookup("return_ty_sentinel").?.ty, null);
                }

                const ty = try self.allocator.create(ast.Type);
                ty.* = .{ .primitive = .void_type };
                return ty;
            },
            .try_expr => |trye| {
                const inner_ty = try self.checkExpr(trye.expr, scope);

                // Unwrapped type is the type of the "value" field of the Result struct
                var struct_ty = inner_ty;
                while (true) {
                    switch (struct_ty.*) {
                        .pointer => |p| struct_ty = p,
                        .borrow => |b| struct_ty = b,
                        else => break,
                    }
                }

                if (struct_ty.* != .user_defined) return TypeError.NotAStruct;
                const struct_decl = self.structs.get(struct_ty.user_defined.name) orelse return TypeError.NotAStruct;
                var value_ty: ?*ast.Type = null;
                for (struct_decl.fields) |f| {
                    if (std.mem.eql(u8, f.name, "value")) {
                        value_ty = f.ty;
                        break;
                    }
                }
                const unwrapped_ty = value_ty orelse return TypeError.FieldNotFound;

                // Collect all currently active variables in the scope chain
                var try_cleanup = std.ArrayList([]const u8).init(self.allocator);
                var curr: ?*Scope = scope;
                while (curr) |s| {
                    var iter = s.symbols.valueIterator();
                    while (iter.next()) |sym| {
                        if (sym.state == .active and !isInternalSymbol(sym.name)) {
                            try try_cleanup.append(sym.name);
                        }
                    }
                    curr = s.parent;
                }
                if (try_cleanup.items.len > 0) {
                    try self.cleanups.put(expr, try_cleanup);
                } else {
                    try_cleanup.deinit();
                }

                return unwrapped_ty;
            },
            else => return TypeError.CompileError,
        }
    }

    fn typesEqual(self: *TypeChecker, a: *ast.Type, b: *ast.Type) bool {
        if (std.meta.activeTag(a.*) != std.meta.activeTag(b.*)) return false;
        switch (a.*) {
            .primitive => |pa| return pa == b.primitive,
            .pointer => |pa| return self.typesEqual(pa, b.pointer),
            .borrow => |ba| return self.typesEqual(ba, b.borrow),
            .array => |aa| {
                return aa.len == b.array.len and self.typesEqual(aa.elem, b.array.elem);
            },
            .tuple => |ta| {
                if (ta.elems.len != b.tuple.elems.len) return false;
                for (ta.elems, b.tuple.elems) |ea, eb| {
                    if (!self.typesEqual(ea, eb)) return false;
                }
                return true;
            },
            .future => |fa| return self.typesEqual(fa, b.future),
            .closure => |ca| {
                if (ca.params.len != b.closure.params.len) return false;
                for (ca.params, b.closure.params) |pa, pb| {
                    if (!self.typesEqual(pa, pb)) return false;
                }
                return self.typesEqual(ca.ret, b.closure.ret);
            },
            .user_defined => |uda| {
                if (!std.mem.eql(u8, uda.name, b.user_defined.name)) return false;
                if (uda.generics.len != b.user_defined.generics.len) return false;
                for (uda.generics, b.user_defined.generics) |ga, gb| {
                    if (!self.typesEqual(ga, gb)) return false;
                }
                return true;
            },
        }
    }

    fn typeName(self: *TypeChecker, ty: *ast.Type) TypeError![]const u8 {
        _ = self;
        return switch (ty.*) {
            .user_defined => |ud| ud.name,
            else => TypeError.CompileError,
        };
    }

    fn checkImpl(self: *TypeChecker, impl_decl: *ast.ImplDecl) !void {
        for (impl_decl.methods) |method| {
            if (method.* != .func_decl) return TypeError.CompileError;
            try self.checkFunc(&method.func_decl);
        }
    }
};

test "type checker basic validation" {
    // We can write tests here if we want to build it, but user requested 'no rushing to compile'.
    // Let's ensure the semantic correctness.
}
