const std = @import("std");
const ast = @import("ast.zig");

pub const MonomorphizeError = error{
    TemplateNotFound,
    MonomorphizeError,
    OutOfMemory,
};

pub const Substitution = struct {
    param: []const u8,
    arg: *ast.Type,
};

pub const Monomorphizer = struct {
    allocator: std.mem.Allocator,
    struct_templates: std.StringHashMap(*ast.StructDecl),
    func_templates: std.StringHashMap(*ast.FuncDecl),

    // Tracks already specialized structs and functions to avoid duplicate generation
    specialized_structs: std.StringHashMap([]const u8),
    specialized_funcs: std.StringHashMap([]const u8),

    // Accumulators for the generated concrete declarations
    new_decls: std.ArrayList(*ast.Node),

    pub fn init(allocator: std.mem.Allocator) Monomorphizer {
        return .{
            .allocator = allocator,
            .struct_templates = std.StringHashMap(*ast.StructDecl).init(allocator),
            .func_templates = std.StringHashMap(*ast.FuncDecl).init(allocator),
            .specialized_structs = std.StringHashMap([]const u8).init(allocator),
            .specialized_funcs = std.StringHashMap([]const u8).init(allocator),
            .new_decls = std.ArrayList(*ast.Node).init(allocator),
        };
    }

    pub fn deinit(self: *Monomorphizer) void {
        self.struct_templates.deinit();
        self.func_templates.deinit();

        var struct_val_iter = self.specialized_structs.valueIterator();
        while (struct_val_iter.next()) |v| {
            self.allocator.free(v.*);
        }
        self.specialized_structs.deinit();

        var func_val_iter = self.specialized_funcs.valueIterator();
        while (func_val_iter.next()) |v| {
            self.allocator.free(v.*);
        }
        self.specialized_funcs.deinit();

        self.new_decls.deinit();
    }

    pub fn monomorphize(self: *Monomorphizer, program: *ast.Node) MonomorphizeError!*ast.Node {
        if (program.* != .program) return MonomorphizeError.MonomorphizeError;

        var regular_decls = std.ArrayList(*ast.Node).init(self.allocator);
        errdefer regular_decls.deinit();

        // 1. Separate templates from concrete declarations
        for (program.program.decls) |decl| {
            switch (decl.*) {
                .struct_decl => |*s| {
                    if (s.generics.len > 0) {
                        try self.struct_templates.put(s.name, s);
                    } else {
                        try regular_decls.append(decl);
                    }
                },
                .func_decl => |*f| {
                    if (f.generics.len > 0) {
                        try self.func_templates.put(f.name, f);
                    } else {
                        try regular_decls.append(decl);
                    }
                },
                else => try regular_decls.append(decl),
            }
        }

        // 2. Scan all regular declarations for generic instantiations (structs or function calls)
        var i: usize = 0;
        while (i < regular_decls.items.len) : (i += 1) {
            const decl = regular_decls.items[i];
            const updated_decl = try self.specializeNode(decl);
            regular_decls.items[i] = updated_decl;
        }

        // 3. Append all newly generated specialized declarations
        for (self.new_decls.items) |nd| {
            try regular_decls.append(nd);
        }

        const result = try self.allocator.create(ast.Node);
        result.* = .{ .program = .{ .decls = try regular_decls.toOwnedSlice() } };
        return result;
    }

    fn specializeNode(self: *Monomorphizer, node: *ast.Node) MonomorphizeError!*ast.Node {
        switch (node.*) {
            .program => unreachable,
            .struct_decl => |s| {
                var new_fields = std.ArrayList(ast.Field).init(self.allocator);
                for (s.fields) |f| {
                    const new_ty = try self.specializeType(f.ty);
                    try new_fields.append(.{ .name = f.name, .ty = new_ty });
                }
                const res = try self.allocator.create(ast.Node);
                res.* = .{
                    .struct_decl = .{
                        .name = s.name,
                        .generics = &.{},
                        .fields = try new_fields.toOwnedSlice(),
                    },
                };
                return res;
            },
            .enum_decl => |e| {
                var new_variants = std.ArrayList(ast.EnumVariant).init(self.allocator);
                for (e.variants) |variant| {
                    var new_fields = std.ArrayList(ast.Field).init(self.allocator);
                    for (variant.fields) |f| {
                        const new_ty = try self.specializeType(f.ty);
                        try new_fields.append(.{ .name = f.name, .ty = new_ty });
                    }
                    try new_variants.append(.{ .name = variant.name, .fields = try new_fields.toOwnedSlice() });
                }
                const res = try self.allocator.create(ast.Node);
                res.* = .{ .enum_decl = .{ .name = e.name, .generics = &.{}, .variants = try new_variants.toOwnedSlice() } };
                return res;
            },
            .impl_decl => |i| {
                const new_target = try self.specializeType(i.target_ty);
                const new_methods = try self.specializeBlock(i.methods);
                const res = try self.allocator.create(ast.Node);
                res.* = .{ .impl_decl = .{ .target_ty = new_target, .methods = new_methods } };
                return res;
            },
            .func_decl => |f| {
                var new_params = std.ArrayList(ast.Param).init(self.allocator);
                for (f.params) |p| {
                    const new_ty = try self.specializeType(p.ty);
                    try new_params.append(.{ .name = p.name, .ty = new_ty, .is_borrow = p.is_borrow, .is_move = p.is_move });
                }
                const new_ret = try self.specializeType(f.ret_ty);
                const new_body = try self.specializeBlock(f.body);

                const res = try self.allocator.create(ast.Node);
                res.* = .{
                    .func_decl = .{
                        .name = f.name,
                        .generics = &.{},
                        .params = try new_params.toOwnedSlice(),
                        .ret_ty = new_ret,
                        .body = new_body,
                        .is_inline = f.is_inline,
                        .is_async = f.is_async,
                    },
                };
                return res;
            },
            .macro_decl => |m| {
                const new_body = try self.specializeBlock(m.body);
                const res = try self.allocator.create(ast.Node);
                res.* = .{
                    .macro_decl = .{
                        .name = m.name,
                        .params = m.params,
                        .body = new_body,
                    },
                };
                return res;
            },
            .import_decl => |import| {
                const res = try self.allocator.create(ast.Node);
                res.* = .{ .import_decl = .{ .path = import.path } };
                return res;
            },
            .test_decl => |t| {
                const new_body = try self.specializeBlock(t.body);
                const res = try self.allocator.create(ast.Node);
                res.* = .{
                    .test_decl = .{
                        .name = t.name,
                        .is_ignored = t.is_ignored,
                        .should_panic = t.should_panic,
                        .body = new_body,
                    },
                };
                return res;
            },
            .let_stmt => |let| {
                const new_ty = if (let.ty) |ty| try self.specializeType(ty) else null;
                const new_val = try self.specializeNode(let.value);
                const res = try self.allocator.create(ast.Node);
                res.* = .{
                    .let_stmt = .{
                        .name = let.name,
                        .ty = new_ty,
                        .value = new_val,
                    },
                };
                return res;
            },
            .let_destructure_stmt => |let| {
                const new_val = try self.specializeNode(let.value);
                const res = try self.allocator.create(ast.Node);
                res.* = .{ .let_destructure_stmt = .{ .names = let.names, .value = new_val } };
                return res;
            },
            .const_stmt => |c| {
                const new_ty = if (c.ty) |ty| try self.specializeType(ty) else null;
                const new_val = try self.specializeNode(c.value);
                const res = try self.allocator.create(ast.Node);
                res.* = .{
                    .const_stmt = .{
                        .name = c.name,
                        .ty = new_ty,
                        .value = new_val,
                    },
                };
                return res;
            },
            .assign_stmt => |assign| {
                const new_target = try self.specializeNode(assign.target);
                const new_val = try self.specializeNode(assign.value);
                const res = try self.allocator.create(ast.Node);
                res.* = .{
                    .assign_stmt = .{
                        .target = new_target,
                        .value = new_val,
                    },
                };
                return res;
            },
            .expr_stmt => |expr| {
                const new_expr = try self.specializeNode(expr);
                const res = try self.allocator.create(ast.Node);
                res.* = .{ .expr_stmt = new_expr };
                return res;
            },
            .return_stmt => |ret| {
                const new_val = if (ret.value) |v| try self.specializeNode(v) else null;
                const res = try self.allocator.create(ast.Node);
                res.* = .{ .return_stmt = .{ .value = new_val } };
                return res;
            },
            .for_stmt => |f| {
                const new_start = try self.specializeNode(f.start);
                const new_end = try self.specializeNode(f.end);
                const new_body = try self.specializeBlock(f.body);
                const res = try self.allocator.create(ast.Node);
                res.* = .{
                    .for_stmt = .{
                        .var_name = f.var_name,
                        .start = new_start,
                        .end = new_end,
                        .body = new_body,
                    },
                };
                return res;
            },
            .release_stmt => |rel| {
                const res = try self.allocator.create(ast.Node);
                res.* = .{ .release_stmt = .{ .var_name = rel.var_name } };
                return res;
            },
            .literal => |lit| {
                const res = try self.allocator.create(ast.Node);
                res.* = .{ .literal = lit };
                return res;
            },
            .identifier => |name| {
                const res = try self.allocator.create(ast.Node);
                res.* = .{ .identifier = name };
                return res;
            },
            .if_expr => |ife| {
                const new_cond = try self.specializeNode(ife.cond);
                const new_then = try self.specializeBlock(ife.then_block);
                const new_else = if (ife.else_block) |eb| try self.specializeBlock(eb) else null;
                const res = try self.allocator.create(ast.Node);
                res.* = .{
                    .if_expr = .{
                        .cond = new_cond,
                        .then_block = new_then,
                        .else_block = new_else,
                    },
                };
                return res;
            },
            .switch_expr => |swe| {
                const new_val = try self.specializeNode(swe.val);
                var new_cases = std.ArrayList(ast.Case).init(self.allocator);
                for (swe.cases) |case| {
                    const new_pattern = try self.specializeNode(case.pattern);
                    const new_body = try self.specializeBlock(case.body);
                    try new_cases.append(.{ .pattern = new_pattern, .body = new_body });
                }
                const res = try self.allocator.create(ast.Node);
                res.* = .{
                    .switch_expr = .{
                        .val = new_val,
                        .cases = try new_cases.toOwnedSlice(),
                    },
                };
                return res;
            },
            .match_expr => |mat| {
                const new_val = try self.specializeNode(mat.val);
                var new_cases = std.ArrayList(ast.MatchCase).init(self.allocator);
                for (mat.cases) |case| {
                    const new_body = try self.specializeBlock(case.body);
                    try new_cases.append(.{ .pattern = case.pattern, .body = new_body });
                }
                const res = try self.allocator.create(ast.Node);
                res.* = .{ .match_expr = .{ .val = new_val, .cases = try new_cases.toOwnedSlice() } };
                return res;
            },
            .await_expr => |aw| {
                const new_expr = try self.specializeNode(aw.expr);
                const res = try self.allocator.create(ast.Node);
                res.* = .{ .await_expr = .{ .expr = new_expr } };
                return res;
            },
            .binary_expr => |bin| {
                const new_left = try self.specializeNode(bin.left);
                const new_right = try self.specializeNode(bin.right);
                const res = try self.allocator.create(ast.Node);
                res.* = .{
                    .binary_expr = .{
                        .op = bin.op,
                        .left = new_left,
                        .right = new_right,
                    },
                };
                return res;
            },
            .borrow_expr => |borrow| {
                const new_expr = try self.specializeNode(borrow.expr);
                const res = try self.allocator.create(ast.Node);
                res.* = .{ .borrow_expr = .{ .expr = new_expr } };
                return res;
            },
            .move_expr => |move| {
                const new_expr = try self.specializeNode(move.expr);
                const res = try self.allocator.create(ast.Node);
                res.* = .{ .move_expr = .{ .expr = new_expr } };
                return res;
            },
            .deref_expr => |deref| {
                const new_expr = try self.specializeNode(deref.expr);
                const res = try self.allocator.create(ast.Node);
                res.* = .{ .deref_expr = .{ .expr = new_expr } };
                return res;
            },
            .field_expr => |field| {
                const new_expr = try self.specializeNode(field.expr);
                const res = try self.allocator.create(ast.Node);
                res.* = .{
                    .field_expr = .{
                        .expr = new_expr,
                        .field_name = field.field_name,
                    },
                };
                return res;
            },
            .struct_literal => |lit| {
                const new_ty = try self.specializeType(lit.ty);
                var new_fields = std.ArrayList(ast.StructLiteralField).init(self.allocator);
                for (lit.fields) |field| {
                    try new_fields.append(.{
                        .name = field.name,
                        .value = try self.specializeNode(field.value),
                    });
                }
                const res = try self.allocator.create(ast.Node);
                res.* = .{
                    .struct_literal = .{
                        .ty = new_ty,
                        .fields = try new_fields.toOwnedSlice(),
                    },
                };
                return res;
            },
            .enum_literal => |lit| {
                var new_fields = std.ArrayList(ast.EnumLiteralField).init(self.allocator);
                for (lit.fields) |field| {
                    try new_fields.append(.{ .name = field.name, .value = try self.specializeNode(field.value) });
                }
                const res = try self.allocator.create(ast.Node);
                res.* = .{ .enum_literal = .{ .enum_name = lit.enum_name, .variant_name = lit.variant_name, .fields = try new_fields.toOwnedSlice() } };
                return res;
            },
            .closure_literal => |lit| {
                var new_params = std.ArrayList(ast.Param).init(self.allocator);
                for (lit.params) |p| {
                    try new_params.append(.{ .name = p.name, .ty = try self.specializeType(p.ty), .is_borrow = p.is_borrow, .is_move = p.is_move });
                }
                const new_body = try self.specializeNode(lit.body);
                const res = try self.allocator.create(ast.Node);
                res.* = .{ .closure_literal = .{ .params = try new_params.toOwnedSlice(), .body = new_body } };
                return res;
            },
            .array_literal => |lit| {
                var new_elements = std.ArrayList(*ast.Node).init(self.allocator);
                for (lit.elements) |elem| {
                    try new_elements.append(try self.specializeNode(elem));
                }
                const res = try self.allocator.create(ast.Node);
                res.* = .{ .array_literal = .{ .elements = try new_elements.toOwnedSlice() } };
                return res;
            },
            .tuple_literal => |lit| {
                var new_elements = std.ArrayList(*ast.Node).init(self.allocator);
                for (lit.elements) |elem| {
                    try new_elements.append(try self.specializeNode(elem));
                }
                const res = try self.allocator.create(ast.Node);
                res.* = .{ .tuple_literal = .{ .elements = try new_elements.toOwnedSlice() } };
                return res;
            },
            .index_expr => |idx| {
                const new_target = try self.specializeNode(idx.target);
                const new_index = try self.specializeNode(idx.index);
                const res = try self.allocator.create(ast.Node);
                res.* = .{ .index_expr = .{ .target = new_target, .index = new_index } };
                return res;
            },
            .slice_expr => |slc| {
                const new_target = try self.specializeNode(slc.target);
                const new_start = try self.specializeNode(slc.start);
                const new_end = try self.specializeNode(slc.end);
                const res = try self.allocator.create(ast.Node);
                res.* = .{ .slice_expr = .{ .target = new_target, .start = new_start, .end = new_end } };
                return res;
            },
            .try_expr => |trye| {
                const new_expr = try self.specializeNode(trye.expr);
                const res = try self.allocator.create(ast.Node);
                res.* = .{ .try_expr = .{ .expr = new_expr } };
                return res;
            },
            .call_expr => |call| {
                // If this is a generic function call (e.g. unwrap_or<int>(opt, default))
                if (call.generics.len > 0) {
                    const mangled_name = try self.getMangledFuncName(call.func_name, call.generics);

                    // Instantiate if not already done
                    if (!self.specialized_funcs.contains(mangled_name)) {
                        const template = self.func_templates.get(call.func_name) orelse return MonomorphizeError.TemplateNotFound;
                        try self.instantiateFunction(mangled_name, template, call.generics);
                    }

                    var new_args = std.ArrayList(*ast.Node).init(self.allocator);
                    for (call.args) |arg| {
                        try new_args.append(try self.specializeNode(arg));
                    }

                    const res = try self.allocator.create(ast.Node);
                    res.* = .{
                        .call_expr = .{
                            .func_name = mangled_name,
                            .generics = &.{},
                            .args = try new_args.toOwnedSlice(),
                        },
                    };
                    return res;
                }

                // Ordinary function call
                var new_args = std.ArrayList(*ast.Node).init(self.allocator);
                for (call.args) |arg| {
                    try new_args.append(try self.specializeNode(arg));
                }
                const res = try self.allocator.create(ast.Node);
                res.* = .{
                    .call_expr = .{
                        .func_name = call.func_name,
                        .generics = &.{},
                        .args = try new_args.toOwnedSlice(),
                    },
                };
                return res;
            },
        }
    }

    fn specializeBlock(self: *Monomorphizer, block: []const *ast.Node) MonomorphizeError![]const *ast.Node {
        var new_block = std.ArrayList(*ast.Node).init(self.allocator);
        for (block) |stmt| {
            try new_block.append(try self.specializeNode(stmt));
        }
        return try new_block.toOwnedSlice();
    }

    fn specializeType(self: *Monomorphizer, ty: *ast.Type) MonomorphizeError!*ast.Type {
        switch (ty.*) {
            .primitive => return ty,
            .pointer => |inner| {
                const new_inner = try self.specializeType(inner);
                const res = try self.allocator.create(ast.Type);
                res.* = .{ .pointer = new_inner };
                return res;
            },
            .borrow => |inner| {
                const new_inner = try self.specializeType(inner);
                const res = try self.allocator.create(ast.Type);
                res.* = .{ .borrow = new_inner };
                return res;
            },
            .array => |arr| {
                const new_elem = try self.specializeType(arr.elem);
                const res = try self.allocator.create(ast.Type);
                res.* = .{ .array = .{ .elem = new_elem, .len = arr.len } };
                return res;
            },
            .tuple => |tuple| {
                var new_elems = std.ArrayList(*ast.Type).init(self.allocator);
                for (tuple.elems) |elem| {
                    try new_elems.append(try self.specializeType(elem));
                }
                const res = try self.allocator.create(ast.Type);
                res.* = .{ .tuple = .{ .elems = try new_elems.toOwnedSlice() } };
                return res;
            },
            .future => |inner| {
                const new_inner = try self.specializeType(inner);
                const res = try self.allocator.create(ast.Type);
                res.* = .{ .future = new_inner };
                return res;
            },
            .closure => |closure| {
                var new_params = std.ArrayList(*ast.Type).init(self.allocator);
                for (closure.params) |p| {
                    try new_params.append(try self.specializeType(p));
                }
                const new_ret = try self.specializeType(closure.ret);
                const res = try self.allocator.create(ast.Type);
                res.* = .{ .closure = .{ .params = try new_params.toOwnedSlice(), .ret = new_ret } };
                return res;
            },
            .user_defined => |ud| {
                if (ud.generics.len > 0) {
                    const mangled_name = try self.getMangledStructName(ud.name, ud.generics);

                    // Instantiate if not already done
                    if (!self.specialized_structs.contains(mangled_name)) {
                        const template = self.struct_templates.get(ud.name) orelse return MonomorphizeError.TemplateNotFound;
                        try self.instantiateStruct(mangled_name, template, ud.generics);
                    }

                    const res = try self.allocator.create(ast.Type);
                    res.* = .{
                        .user_defined = .{
                            .name = mangled_name,
                            .generics = &.{},
                        },
                    };
                    return res;
                }
                return ty;
            },
        }
    }

    fn getMangledStructName(self: *Monomorphizer, base: []const u8, generics: []const *ast.Type) MonomorphizeError![]const u8 {
        var name_buf = std.ArrayList(u8).init(self.allocator);
        try name_buf.appendSlice(base);
        for (generics) |g| {
            try name_buf.append('_');
            try self.appendTypeName(&name_buf, g);
        }
        return try name_buf.toOwnedSlice();
    }

    fn getMangledFuncName(self: *Monomorphizer, base: []const u8, generics: []const *ast.Type) MonomorphizeError![]const u8 {
        var name_buf = std.ArrayList(u8).init(self.allocator);
        try name_buf.appendSlice(base);
        for (generics) |g| {
            try name_buf.append('_');
            try self.appendTypeName(&name_buf, g);
        }
        return try name_buf.toOwnedSlice();
    }

    fn appendTypeName(self: *Monomorphizer, buf: *std.ArrayList(u8), ty: *ast.Type) MonomorphizeError!void {
        switch (ty.*) {
            .primitive => |p| {
                switch (p) {
                    .integer => try buf.appendSlice("int"),
                    .float => try buf.appendSlice("float"),
                    .boolean => try buf.appendSlice("bool"),
                    .void_type => try buf.appendSlice("void"),
                }
            },
            .pointer => |inner| {
                try buf.appendSlice("ptr_");
                try self.appendTypeName(buf, inner);
            },
            .borrow => |inner| {
                try buf.appendSlice("ref_");
                try self.appendTypeName(buf, inner);
            },
            .array => |arr| {
                try buf.appendSlice("arr");
                try buf.writer().print("{}", .{arr.len});
                try buf.append('_');
                try self.appendTypeName(buf, arr.elem);
            },
            .tuple => |tuple| {
                try buf.appendSlice("tuple_");
                for (tuple.elems) |elem| {
                    try self.appendTypeName(buf, elem);
                    try buf.append('_');
                }
            },
            .future => |inner| {
                try buf.appendSlice("future_");
                try self.appendTypeName(buf, inner);
            },
            .closure => |closure| {
                try buf.appendSlice("closure_");
                for (closure.params) |p| {
                    try self.appendTypeName(buf, p);
                    try buf.append('_');
                }
                try self.appendTypeName(buf, closure.ret);
            },
            .user_defined => |ud| {
                try buf.appendSlice(ud.name);
                for (ud.generics) |g| {
                    try buf.append('_');
                    try self.appendTypeName(buf, g);
                }
            },
        }
    }

    fn instantiateStruct(self: *Monomorphizer, mangled_name: []const u8, template: *ast.StructDecl, args: []const *ast.Type) MonomorphizeError!void {
        // Record specialization
        try self.specialized_structs.put(mangled_name, try self.allocator.dupe(u8, mangled_name));

        // Create specialized fields
        var spec_fields = std.ArrayList(ast.Field).init(self.allocator);
        for (template.fields) |f| {
            const spec_ty = try self.substituteType(f.ty, template.generics, args);
            const fully_spec_ty = try self.specializeType(spec_ty);
            try spec_fields.append(.{
                .name = f.name,
                .ty = fully_spec_ty,
            });
        }

        const node = try self.allocator.create(ast.Node);
        node.* = .{
            .struct_decl = .{
                .name = mangled_name,
                .generics = &.{},
                .fields = try spec_fields.toOwnedSlice(),
            },
        };
        try self.new_decls.append(node);
    }

    fn instantiateFunction(self: *Monomorphizer, mangled_name: []const u8, template: *ast.FuncDecl, args: []const *ast.Type) MonomorphizeError!void {
        // Record specialization
        try self.specialized_funcs.put(mangled_name, try self.allocator.dupe(u8, mangled_name));

        // Create specialized params
        var spec_params = std.ArrayList(ast.Param).init(self.allocator);
        for (template.params) |p| {
            const spec_ty = try self.substituteType(p.ty, template.generics, args);
            const fully_spec_ty = try self.specializeType(spec_ty);
            try spec_params.append(.{
                .name = p.name,
                .ty = fully_spec_ty,
                .is_borrow = p.is_borrow,
                .is_move = p.is_move,
            });
        }

        const spec_ret_ty = try self.substituteType(template.ret_ty, template.generics, args);
        const fully_spec_ret_ty = try self.specializeType(spec_ret_ty);

        // Substitute inside block
        const spec_body = try self.substituteBlock(template.body, template.generics, args);
        const fully_spec_body = try self.specializeBlock(spec_body);

        const node = try self.allocator.create(ast.Node);
        node.* = .{
            .func_decl = .{
                .name = mangled_name,
                .generics = &.{},
                .params = try spec_params.toOwnedSlice(),
                .ret_ty = fully_spec_ret_ty,
                .body = fully_spec_body,
                .is_inline = template.is_inline,
                .is_async = template.is_async,
            },
        };
        try self.new_decls.append(node);
    }

    fn substituteType(self: *Monomorphizer, ty: *ast.Type, params: []const []const u8, args: []const *ast.Type) MonomorphizeError!*ast.Type {
        switch (ty.*) {
            .primitive => return ty,
            .pointer => |inner| {
                const spec_inner = try self.substituteType(inner, params, args);
                const res = try self.allocator.create(ast.Type);
                res.* = .{ .pointer = spec_inner };
                return res;
            },
            .borrow => |inner| {
                const spec_inner = try self.substituteType(inner, params, args);
                const res = try self.allocator.create(ast.Type);
                res.* = .{ .borrow = spec_inner };
                return res;
            },
            .array => |arr| {
                const spec_elem = try self.substituteType(arr.elem, params, args);
                const res = try self.allocator.create(ast.Type);
                res.* = .{ .array = .{ .elem = spec_elem, .len = arr.len } };
                return res;
            },
            .tuple => |tuple| {
                var spec_elems = std.ArrayList(*ast.Type).init(self.allocator);
                for (tuple.elems) |elem| {
                    try spec_elems.append(try self.substituteType(elem, params, args));
                }
                const res = try self.allocator.create(ast.Type);
                res.* = .{ .tuple = .{ .elems = try spec_elems.toOwnedSlice() } };
                return res;
            },
            .future => |inner| {
                const spec_inner = try self.substituteType(inner, params, args);
                const res = try self.allocator.create(ast.Type);
                res.* = .{ .future = spec_inner };
                return res;
            },
            .closure => |closure| {
                var spec_params = std.ArrayList(*ast.Type).init(self.allocator);
                for (closure.params) |p| {
                    try spec_params.append(try self.substituteType(p, params, args));
                }
                const spec_ret = try self.substituteType(closure.ret, params, args);
                const res = try self.allocator.create(ast.Type);
                res.* = .{ .closure = .{ .params = try spec_params.toOwnedSlice(), .ret = spec_ret } };
                return res;
            },
            .user_defined => |ud| {
                // Check if this type matches one of the generic parameters
                for (params, args) |p, arg| {
                    if (std.mem.eql(u8, ud.name, p)) {
                        return arg;
                    }
                }

                // If not, recursively substitute its generic arguments
                var spec_args = std.ArrayList(*ast.Type).init(self.allocator);
                for (ud.generics) |g| {
                    try spec_args.append(try self.substituteType(g, params, args));
                }
                const res = try self.allocator.create(ast.Type);
                res.* = .{
                    .user_defined = .{
                        .name = ud.name,
                        .generics = try spec_args.toOwnedSlice(),
                    },
                };
                return res;
            },
        }
    }

    fn substituteBlock(self: *Monomorphizer, block: []const *ast.Node, params: []const []const u8, args: []const *ast.Type) MonomorphizeError![]const *ast.Node {
        var spec_block = std.ArrayList(*ast.Node).init(self.allocator);
        for (block) |stmt| {
            try spec_block.append(try self.substituteNode(stmt, params, args));
        }
        return try spec_block.toOwnedSlice();
    }

    fn substituteNode(self: *Monomorphizer, node: *ast.Node, params: []const []const u8, args: []const *ast.Type) MonomorphizeError!*ast.Node {
        switch (node.*) {
            .program => unreachable,
            .struct_decl => unreachable,
            .enum_decl => unreachable,
            .impl_decl => unreachable,
            .func_decl => unreachable,
            .macro_decl => unreachable,
            .import_decl => unreachable,
            .test_decl => unreachable,
            .let_stmt => |let| {
                const spec_ty = if (let.ty) |ty| try self.substituteType(ty, params, args) else null;
                const spec_val = try self.substituteNode(let.value, params, args);
                const res = try self.allocator.create(ast.Node);
                res.* = .{
                    .let_stmt = .{
                        .name = let.name,
                        .ty = spec_ty,
                        .value = spec_val,
                    },
                };
                return res;
            },
            .let_destructure_stmt => |let| {
                const spec_val = try self.substituteNode(let.value, params, args);
                const res = try self.allocator.create(ast.Node);
                res.* = .{ .let_destructure_stmt = .{ .names = let.names, .value = spec_val } };
                return res;
            },
            .const_stmt => |c| {
                const spec_ty = if (c.ty) |ty| try self.substituteType(ty, params, args) else null;
                const spec_val = try self.substituteNode(c.value, params, args);
                const res = try self.allocator.create(ast.Node);
                res.* = .{
                    .const_stmt = .{
                        .name = c.name,
                        .ty = spec_ty,
                        .value = spec_val,
                    },
                };
                return res;
            },
            .assign_stmt => |assign| {
                const spec_target = try self.substituteNode(assign.target, params, args);
                const spec_val = try self.substituteNode(assign.value, params, args);
                const res = try self.allocator.create(ast.Node);
                res.* = .{
                    .assign_stmt = .{
                        .target = spec_target,
                        .value = spec_val,
                    },
                };
                return res;
            },
            .expr_stmt => |expr| {
                const spec_expr = try self.substituteNode(expr, params, args);
                const res = try self.allocator.create(ast.Node);
                res.* = .{ .expr_stmt = spec_expr };
                return res;
            },
            .return_stmt => |ret| {
                const spec_val = if (ret.value) |v| try self.substituteNode(v, params, args) else null;
                const res = try self.allocator.create(ast.Node);
                res.* = .{ .return_stmt = .{ .value = spec_val } };
                return res;
            },
            .for_stmt => |f| {
                const spec_start = try self.substituteNode(f.start, params, args);
                const spec_end = try self.substituteNode(f.end, params, args);
                const spec_body = try self.substituteBlock(f.body, params, args);
                const res = try self.allocator.create(ast.Node);
                res.* = .{
                    .for_stmt = .{
                        .var_name = f.var_name,
                        .start = spec_start,
                        .end = spec_end,
                        .body = spec_body,
                    },
                };
                return res;
            },
            .release_stmt => |rel| {
                const res = try self.allocator.create(ast.Node);
                res.* = .{ .release_stmt = .{ .var_name = rel.var_name } };
                return res;
            },
            .literal => |lit| {
                const res = try self.allocator.create(ast.Node);
                res.* = .{ .literal = lit };
                return res;
            },
            .identifier => |name| {
                const res = try self.allocator.create(ast.Node);
                res.* = .{ .identifier = name };
                return res;
            },
            .if_expr => |ife| {
                const spec_cond = try self.substituteNode(ife.cond, params, args);
                const spec_then = try self.substituteBlock(ife.then_block, params, args);
                const spec_else = if (ife.else_block) |eb| try self.substituteBlock(eb, params, args) else null;
                const res = try self.allocator.create(ast.Node);
                res.* = .{
                    .if_expr = .{
                        .cond = spec_cond,
                        .then_block = spec_then,
                        .else_block = spec_else,
                    },
                };
                return res;
            },
            .switch_expr => |swe| {
                const spec_val = try self.substituteNode(swe.val, params, args);
                var spec_cases = std.ArrayList(ast.Case).init(self.allocator);
                for (swe.cases) |case| {
                    const spec_pattern = try self.substituteNode(case.pattern, params, args);
                    const spec_body = try self.substituteBlock(case.body, params, args);
                    try spec_cases.append(.{ .pattern = spec_pattern, .body = spec_body });
                }
                const res = try self.allocator.create(ast.Node);
                res.* = .{
                    .switch_expr = .{
                        .val = spec_val,
                        .cases = try spec_cases.toOwnedSlice(),
                    },
                };
                return res;
            },
            .match_expr => |mat| {
                const spec_val = try self.substituteNode(mat.val, params, args);
                var spec_cases = std.ArrayList(ast.MatchCase).init(self.allocator);
                for (mat.cases) |case| {
                    const spec_body = try self.substituteBlock(case.body, params, args);
                    try spec_cases.append(.{ .pattern = case.pattern, .body = spec_body });
                }
                const res = try self.allocator.create(ast.Node);
                res.* = .{ .match_expr = .{ .val = spec_val, .cases = try spec_cases.toOwnedSlice() } };
                return res;
            },
            .await_expr => |aw| {
                const spec_expr = try self.substituteNode(aw.expr, params, args);
                const res = try self.allocator.create(ast.Node);
                res.* = .{ .await_expr = .{ .expr = spec_expr } };
                return res;
            },
            .binary_expr => |bin| {
                const spec_left = try self.substituteNode(bin.left, params, args);
                const spec_right = try self.substituteNode(bin.right, params, args);
                const res = try self.allocator.create(ast.Node);
                res.* = .{
                    .binary_expr = .{
                        .op = bin.op,
                        .left = spec_left,
                        .right = spec_right,
                    },
                };
                return res;
            },
            .borrow_expr => |borrow| {
                const spec_expr = try self.substituteNode(borrow.expr, params, args);
                const res = try self.allocator.create(ast.Node);
                res.* = .{ .borrow_expr = .{ .expr = spec_expr } };
                return res;
            },
            .move_expr => |move| {
                const spec_expr = try self.substituteNode(move.expr, params, args);
                const res = try self.allocator.create(ast.Node);
                res.* = .{ .move_expr = .{ .expr = spec_expr } };
                return res;
            },
            .deref_expr => |deref| {
                const spec_expr = try self.substituteNode(deref.expr, params, args);
                const res = try self.allocator.create(ast.Node);
                res.* = .{ .deref_expr = .{ .expr = spec_expr } };
                return res;
            },
            .field_expr => |field| {
                const spec_expr = try self.substituteNode(field.expr, params, args);
                const res = try self.allocator.create(ast.Node);
                res.* = .{
                    .field_expr = .{
                        .expr = spec_expr,
                        .field_name = field.field_name,
                    },
                };
                return res;
            },
            .struct_literal => |lit| {
                const spec_ty = try self.substituteType(lit.ty, params, args);
                var spec_fields = std.ArrayList(ast.StructLiteralField).init(self.allocator);
                for (lit.fields) |field| {
                    try spec_fields.append(.{
                        .name = field.name,
                        .value = try self.substituteNode(field.value, params, args),
                    });
                }
                const res = try self.allocator.create(ast.Node);
                res.* = .{
                    .struct_literal = .{
                        .ty = spec_ty,
                        .fields = try spec_fields.toOwnedSlice(),
                    },
                };
                return res;
            },
            .enum_literal => |lit| {
                var spec_fields = std.ArrayList(ast.EnumLiteralField).init(self.allocator);
                for (lit.fields) |field| {
                    try spec_fields.append(.{ .name = field.name, .value = try self.substituteNode(field.value, params, args) });
                }
                const res = try self.allocator.create(ast.Node);
                res.* = .{ .enum_literal = .{ .enum_name = lit.enum_name, .variant_name = lit.variant_name, .fields = try spec_fields.toOwnedSlice() } };
                return res;
            },
            .closure_literal => |lit| {
                var spec_params = std.ArrayList(ast.Param).init(self.allocator);
                for (lit.params) |p| {
                    try spec_params.append(.{ .name = p.name, .ty = try self.substituteType(p.ty, params, args), .is_borrow = p.is_borrow, .is_move = p.is_move });
                }
                const spec_body = try self.substituteNode(lit.body, params, args);
                const res = try self.allocator.create(ast.Node);
                res.* = .{ .closure_literal = .{ .params = try spec_params.toOwnedSlice(), .body = spec_body } };
                return res;
            },
            .array_literal => |lit| {
                var spec_elements = std.ArrayList(*ast.Node).init(self.allocator);
                for (lit.elements) |elem| {
                    try spec_elements.append(try self.substituteNode(elem, params, args));
                }
                const res = try self.allocator.create(ast.Node);
                res.* = .{ .array_literal = .{ .elements = try spec_elements.toOwnedSlice() } };
                return res;
            },
            .tuple_literal => |lit| {
                var spec_elements = std.ArrayList(*ast.Node).init(self.allocator);
                for (lit.elements) |elem| {
                    try spec_elements.append(try self.substituteNode(elem, params, args));
                }
                const res = try self.allocator.create(ast.Node);
                res.* = .{ .tuple_literal = .{ .elements = try spec_elements.toOwnedSlice() } };
                return res;
            },
            .index_expr => |idx| {
                const spec_target = try self.substituteNode(idx.target, params, args);
                const spec_index = try self.substituteNode(idx.index, params, args);
                const res = try self.allocator.create(ast.Node);
                res.* = .{ .index_expr = .{ .target = spec_target, .index = spec_index } };
                return res;
            },
            .slice_expr => |slc| {
                const spec_target = try self.substituteNode(slc.target, params, args);
                const spec_start = try self.substituteNode(slc.start, params, args);
                const spec_end = try self.substituteNode(slc.end, params, args);
                const res = try self.allocator.create(ast.Node);
                res.* = .{ .slice_expr = .{ .target = spec_target, .start = spec_start, .end = spec_end } };
                return res;
            },
            .try_expr => |trye| {
                const spec_expr = try self.substituteNode(trye.expr, params, args);
                const res = try self.allocator.create(ast.Node);
                res.* = .{ .try_expr = .{ .expr = spec_expr } };
                return res;
            },
            .call_expr => |call| {
                var spec_generics = std.ArrayList(*ast.Type).init(self.allocator);
                for (call.generics) |g| {
                    try spec_generics.append(try self.substituteType(g, params, args));
                }
                var spec_args = std.ArrayList(*ast.Node).init(self.allocator);
                for (call.args) |arg| {
                    try spec_args.append(try self.substituteNode(arg, params, args));
                }
                const res = try self.allocator.create(ast.Node);
                res.* = .{
                    .call_expr = .{
                        .func_name = call.func_name,
                        .generics = try spec_generics.toOwnedSlice(),
                        .args = try spec_args.toOwnedSlice(),
                    },
                };
                return res;
            },
        }
    }
};

test "monomorphize generic struct" {
    const source =
        \\struct Option<T> {
        \\    has_value: bool,
        \\    value: T
        \\}
        \\fn process(opt: Option<int>) -> int {
        \\    return opt.value;
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const parser_mod = @import("parser.zig");
    var p = parser_mod.Parser.init(arena.allocator(), source);
    const prog = try p.parseProgram();

    var mono = Monomorphizer.init(arena.allocator());
    defer mono.deinit();

    const specialized_prog = try mono.monomorphize(prog);

    // Verify that Option_int struct decl was generated
    try std.testing.expect(specialized_prog.* == .program);
    var found_option_int = false;
    for (specialized_prog.program.decls) |decl| {
        if (decl.* == .struct_decl) {
            if (std.mem.eql(u8, decl.struct_decl.name, "Option_int")) {
                found_option_int = true;
                try std.testing.expectEqual(@as(usize, 2), decl.struct_decl.fields.len);
            }
        }
    }
    try std.testing.expect(found_option_int);
}
