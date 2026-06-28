const std = @import("std");
const ast = @import("ast.zig");
const type_checker = @import("type_checker.zig");
const sci_bridge = @import("sci_bridge");

const sab = sci_bridge.sab;
const inst = sab.instruction;
const sig = sab.signature;
const const_decl = sab.const_decl;

pub const Error = error{
    UnsupportedSabDirectFeature,
    MissingType,
    OutOfMemory,
};

const Local = struct {
    name: []const u8,
    reg: u32,
    is_param: bool,
};

const FieldLayout = struct {
    offset: usize,
    ty: sig.PrimType,
};

pub const Codegen = struct {
    allocator: std.mem.Allocator,
    tc: *type_checker.TypeChecker,
    symbols: std.ArrayList([]const u8),
    symbol_ids: std.StringHashMap(u32),
    const_decls: std.ArrayList(const_decl.ConstDecl),
    fn_ptr_vtables: std.StringHashMap(void),
    instructions: std.ArrayList(inst.Instruction),
    function_sigs: std.ArrayList(sig.FunctionSig),
    test_sigs: std.ArrayList(sig.FunctionSig),
    locals: std.ArrayList(Local),
    current_reg_ids: std.ArrayList(u32),
    current_reg_seen: std.AutoHashMap(u32, void),
    released_regs: std.AutoHashMap(u32, void),
    tmp_idx: usize = 0,
    label_idx: usize = 0,

    pub fn init(allocator: std.mem.Allocator, tc: *type_checker.TypeChecker) Codegen {
        return .{
            .allocator = allocator,
            .tc = tc,
            .symbols = std.ArrayList([]const u8).init(allocator),
            .symbol_ids = std.StringHashMap(u32).init(allocator),
            .const_decls = std.ArrayList(const_decl.ConstDecl).init(allocator),
            .fn_ptr_vtables = std.StringHashMap(void).init(allocator),
            .instructions = std.ArrayList(inst.Instruction).init(allocator),
            .function_sigs = std.ArrayList(sig.FunctionSig).init(allocator),
            .test_sigs = std.ArrayList(sig.FunctionSig).init(allocator),
            .locals = std.ArrayList(Local).init(allocator),
            .current_reg_ids = std.ArrayList(u32).init(allocator),
            .current_reg_seen = std.AutoHashMap(u32, void).init(allocator),
            .released_regs = std.AutoHashMap(u32, void).init(allocator),
        };
    }

    pub fn deinit(self: *Codegen) void {
        self.symbols.deinit();
        self.symbol_ids.deinit();
        self.const_decls.deinit();
        self.fn_ptr_vtables.deinit();
        self.instructions.deinit();
        self.function_sigs.deinit();
        self.test_sigs.deinit();
        self.locals.deinit();
        self.current_reg_ids.deinit();
        self.current_reg_seen.deinit();
        self.released_regs.deinit();
    }

    pub fn generate(self: *Codegen, program: *ast.Node) ![]u8 {
        if (program.* != .program) return Error.UnsupportedSabDirectFeature;
        for (program.program.decls) |decl| {
            switch (decl.*) {
                .func_decl => |*f| {
                    if (!f.is_decl_only) try self.genFuncDecl(f);
                },
                .test_decl => |*t| try self.genTestDecl(t),
                .struct_decl, .enum_decl, .trait_decl, .impl_decl, .type_alias_decl, .overload_decl, .macro_decl, .import_decl, .using_decl => {},
                else => return Error.UnsupportedSabDirectFeature,
            }
        }
        return try sab.encodeProgramWithConsts(
            self.allocator,
            self.symbols.items,
            self.const_decls.items,
            self.function_sigs.items,
            self.instructions.items,
        );
    }

    fn intern(self: *Codegen, name: []const u8) !u32 {
        if (self.symbol_ids.get(name)) |id| return id;
        const id: u32 = @intCast(self.symbols.items.len);
        try self.symbols.append(name);
        try self.symbol_ids.put(name, id);
        return id;
    }

    fn loweredFuncSymbol(self: *Codegen, name: []const u8) ![]const u8 {
        if (std.mem.eql(u8, name, "main")) return name;
        if (self.tc.funcs.get(name)) |func| {
            if (func.is_extern or func.no_mangle) return name;
        }
        if (self.tc.extern_funcs.contains(name) or std.mem.startsWith(u8, name, "sa_")) return name;
        return try std.fmt.allocPrint(self.allocator, "sla__{s}", .{name});
    }

    fn fnPtrVTableName(self: *Codegen, func_name: []const u8) ![]u8 {
        return try std.fmt.allocPrint(self.allocator, "SLA_FNPTR_VT_{s}", .{func_name});
    }

    fn ensureFunctionPointerVTable(self: *Codegen, func_name: []const u8) ![]const u8 {
        const vt_name = try self.fnPtrVTableName(func_name);
        if (self.fn_ptr_vtables.contains(vt_name)) return vt_name;

        const lowered = try self.loweredFuncSymbol(func_name);
        const literal_text = try std.fmt.allocPrint(self.allocator, "vtable {{ call = @{s} }}", .{lowered});
        const raw_text = try std.fmt.allocPrint(self.allocator, "@const {s} = {s}", .{ vt_name, literal_text });
        const slots = try self.allocator.alloc(const_decl.VTableSlot, 1);
        slots[0] = .{
            .name = try self.allocator.dupe(u8, "call"),
            .func_name = try self.allocator.dupe(u8, lowered),
        };
        try self.const_decls.append(.{
            .source_line = 0,
            .expanded_line = 0,
            .upstream_loc = null,
            .raw_text = raw_text,
            .name = vt_name,
            .literal_text = literal_text,
            .value = .{ .vtable = .{ .slots = slots } },
        });
        try self.fn_ptr_vtables.put(vt_name, {});
        _ = try self.intern(vt_name);
        _ = try self.intern(lowered);
        return vt_name;
    }

    fn makeInst(self: *Codegen, kind: inst.InstKind) inst.Instruction {
        return inst.makeInstruction(kind, 0, @intCast(self.instructions.items.len), null, "");
    }

    fn appendInst(self: *Codegen, item: inst.Instruction) !void {
        try self.instructions.append(item);
    }

    fn newTmp(self: *Codegen) ![]const u8 {
        const name = try std.fmt.allocPrint(self.allocator, "tmp_{}", .{self.tmp_idx});
        self.tmp_idx += 1;
        return name;
    }

    fn newLabel(self: *Codegen, prefix: []const u8) ![]const u8 {
        const name = try std.fmt.allocPrint(self.allocator, "{s}_{}", .{ prefix, self.label_idx });
        self.label_idx += 1;
        return name;
    }

    fn primType(ty: *const ast.Type) !sig.PrimType {
        return switch (ty.*) {
            .primitive => |p| switch (p) {
                .i8 => .i8,
                .i16 => .i16,
                .i32 => .i32,
                .i64, .integer, .isize => .i64,
                .u8 => .u8,
                .u16 => .u16,
                .u32 => .u32,
                .u64, .usize => .u64,
                .f32 => .f32,
                .f64, .float => .f64,
                .boolean => .i1,
                .void_type => .void,
            },
            .pointer, .borrow, .fn_ptr, .user_defined, .tuple, .array => .ptr,
            else => Error.UnsupportedSabDirectFeature,
        };
    }

    fn typeSize(ty: *const ast.Type) usize {
        return switch (ty.*) {
            .primitive => |p| switch (p) {
                .boolean, .u8, .i8 => 1,
                .u16, .i16 => 2,
                .u32, .i32, .f32 => 4,
                .u64, .i64, .usize, .isize, .f64 => 8,
                .integer, .float => 8,
                .void_type => 8,
            },
            .tuple => |tuple| tupleSize(tuple),
            else => 8,
        };
    }

    fn alignOffset(offset: usize, size: usize) usize {
        if (size == 8) return (offset + 7) & ~@as(usize, 7);
        return offset;
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

    fn structSize(s: *const ast.StructDecl) usize {
        if (s.is_opaque) return 1;
        if (s.is_union) {
            var max_size: usize = 0;
            for (s.fields) |f| max_size = @max(max_size, typeSize(f.ty));
            return @max(max_size, 1);
        }
        var offset: usize = 0;
        for (s.fields) |f| {
            const size = typeSize(f.ty);
            offset = alignOffset(offset, size);
            offset += size;
        }
        return @max(offset, 1);
    }

    fn structDeclForType(self: *Codegen, ty: *const ast.Type) ?*ast.StructDecl {
        var curr = ty;
        while (true) {
            switch (curr.*) {
                .pointer => |p| curr = p,
                .borrow => |b| curr = b,
                else => break,
            }
        }
        if (curr.* != .user_defined) return null;
        if (self.tc.structs.get(curr.user_defined.name)) |decl| return decl;
        if (self.tc.alias_struct_cache.get(curr.user_defined.name)) |decl| return decl;
        return null;
    }

    fn fieldLayout(self: *Codegen, ty: *const ast.Type, name: []const u8) !FieldLayout {
        const decl = self.structDeclForType(ty) orelse return Error.UnsupportedSabDirectFeature;
        if (decl.is_opaque) return Error.UnsupportedSabDirectFeature;
        if (decl.is_union) {
            for (decl.fields) |field| {
                if (std.mem.eql(u8, field.name, name)) return .{ .offset = 0, .ty = try primType(field.ty) };
            }
            return Error.UnsupportedSabDirectFeature;
        }
        var offset: usize = 0;
        for (decl.fields) |field| {
            const size = typeSize(field.ty);
            offset = alignOffset(offset, size);
            if (std.mem.eql(u8, field.name, name)) return .{ .offset = offset, .ty = try primType(field.ty) };
            offset += size;
        }
        return Error.UnsupportedSabDirectFeature;
    }

    fn fieldType(self: *Codegen, ty: *const ast.Type, name: []const u8) ?*ast.Type {
        const decl = self.structDeclForType(ty) orelse return null;
        for (decl.fields) |field| {
            if (std.mem.eql(u8, field.name, name)) return field.ty;
        }
        return null;
    }

    fn exprHasFnPtrType(self: *Codegen, expr: *const ast.Node) bool {
        const ty = self.tc.expr_types.get(expr) orelse return false;
        return ty.* == .fn_ptr;
    }

    fn opKind(op: ast.BinaryOp) !inst.OpKind {
        return switch (op) {
            .add => .add,
            .sub => .sub,
            .mul => .mul,
            .div => .sdiv,
            .mod => .srem,
            .eq => .eq,
            .ne => .ne,
            .lt => .slt,
            .le => .sle,
            .gt => .sgt,
            .ge => .sge,
            .bit_and => .@"and",
            .bit_or => .@"or",
            .bit_xor => .xor,
            .shl => .shl,
            .shr => .ashr,
            else => Error.UnsupportedSabDirectFeature,
        };
    }

    fn pushLocal(self: *Codegen, name: []const u8, reg: u32, is_param: bool) !void {
        try self.recordReg(reg);
        try self.locals.append(.{ .name = name, .reg = reg, .is_param = is_param });
    }

    fn beginFunction(self: *Codegen) void {
        self.current_reg_ids.clearRetainingCapacity();
        self.current_reg_seen.clearRetainingCapacity();
        self.released_regs.clearRetainingCapacity();
    }

    fn recordReg(self: *Codegen, reg: u32) !void {
        if (self.current_reg_seen.contains(reg)) return;
        try self.current_reg_seen.put(reg, {});
        try self.current_reg_ids.append(reg);
    }

    fn finishFunctionRegs(self: *Codegen) ![]const u32 {
        if (self.current_reg_ids.items.len == 0) return &.{};
        return try self.allocator.dupe(u32, self.current_reg_ids.items);
    }

    fn releaseOpenLocals(self: *Codegen, except: ?u32) !void {
        var i = self.locals.items.len;
        while (i > 0) {
            i -= 1;
            const local = self.locals.items[i];
            if (local.is_param) continue;
            if (except != null and local.reg == except.?) continue;
            if (self.released_regs.contains(local.reg)) continue;
            try self.emitRelease(local.reg);
        }
    }

    fn popLocalsTo(self: *Codegen, len: usize) void {
        self.locals.shrinkRetainingCapacity(len);
    }

    fn localReg(self: *Codegen, name: []const u8) ?u32 {
        var i = self.locals.items.len;
        while (i > 0) {
            i -= 1;
            const local = self.locals.items[i];
            if (std.mem.eql(u8, local.name, name)) return local.reg;
        }
        return null;
    }

    fn isLocalReg(self: *Codegen, reg: u32) bool {
        for (self.locals.items) |local| {
            if (local.reg == reg) return true;
        }
        return false;
    }

    fn releaseNonLocalTemps(self: *Codegen, regs: []const u32) !void {
        for (regs) |reg| {
            if (!self.isLocalReg(reg)) try self.emitRelease(reg);
        }
    }

    fn emitLabel(self: *Codegen, name: []const u8) !void {
        const id = try self.intern(name);
        var item = self.makeInst(.label);
        item.operands[0] = .{ .symbol = id };
        item.operands[1] = .{ .label = id };
        try self.appendInst(item);
    }

    fn emitRelease(self: *Codegen, reg: u32) !void {
        if (self.released_regs.contains(reg)) return;
        var item = self.makeInst(.release);
        item.operands[0] = .{ .reg = reg };
        try self.appendInst(item);
        try self.released_regs.put(reg, {});
    }

    fn emitAssignImm(self: *Codegen, dst: u32, value: i64) !void {
        var item = self.makeInst(.assign);
        item.operands[0] = .{ .reg = dst };
        item.operands[1] = .{ .imm_i64 = value };
        try self.appendInst(item);
    }

    fn emitAssignReg(self: *Codegen, dst: u32, src: u32) !void {
        if (dst == src) return;
        var item = self.makeInst(.assign);
        item.operands[0] = .{ .reg = dst };
        item.operands[1] = .{ .reg = src };
        try self.appendInst(item);
    }

    fn emitAlloc(self: *Codegen, dst: u32, size: usize) !void {
        try self.recordReg(dst);
        var item = self.makeInst(.alloc);
        item.operands[0] = .{ .reg = dst };
        item.operands[1] = .{ .imm_u64 = @intCast(size) };
        try self.appendInst(item);
    }

    fn emitLoad(self: *Codegen, dst: u32, base: u32, offset: usize, ty: sig.PrimType) !void {
        try self.recordReg(dst);
        var item = self.makeInst(.load);
        item.operands[0] = .{ .reg = dst };
        item.operands[1] = .{ .reg = base };
        item.operands[2] = .{ .imm_u64 = @intCast(offset) };
        item.operands[3] = .{ .ty = @intFromEnum(ty) };
        try self.appendInst(item);
    }

    fn emitStore(self: *Codegen, base: u32, offset: usize, value: u32, ty: sig.PrimType) !void {
        var item = self.makeInst(.store);
        item.operands[0] = .{ .reg = base };
        item.operands[1] = .{ .imm_u64 = @intCast(offset) };
        item.operands[2] = .{ .reg = value };
        item.operands[3] = .{ .ty = @intFromEnum(ty) };
        try self.appendInst(item);
    }

    fn emitBorrowSymbol(self: *Codegen, dst: u32, symbol_name: []const u8) !void {
        const symbol_id = try self.intern(symbol_name);
        try self.recordReg(dst);
        try self.recordReg(symbol_id);
        var item = self.makeInst(.borrow);
        item.operands[0] = .{ .reg = dst };
        item.operands[1] = .{ .reg = symbol_id };
        item.operands[2] = .{ .text = "read" };
        item.operands[3] = .{ .cap_prefix = .borrow };
        try self.appendInst(item);
    }

    fn genFuncSig(self: *Codegen, name: []const u8, kind: sig.FunctionKind, params: []const ast.Param, ret_ty: *ast.Type, ignored: bool, should_panic: bool) !sig.FunctionSig {
        const id: u32 = @intCast(self.function_sigs.items.len + self.test_sigs.items.len);
        const lowered = if (kind == .test_func)
            try std.fmt.allocPrint(self.allocator, "\"{s}\"", .{name})
        else
            try self.loweredFuncSymbol(name);
        _ = try self.intern(lowered);
        const specs = try self.allocator.alloc(sig.ParamSpec, params.len);
        const param_ids = try self.allocator.alloc(u32, params.len);
        for (params, 0..) |param, i| {
            const param_id = try self.intern(param.name);
            specs[i] = .{
                .name = param.name,
                .ty = try primType(param.ty),
                .cap = if (param.is_borrow) .borrow else if (param.is_move) .move else .by_value,
            };
            param_ids[i] = param_id;
            try self.pushLocal(param.name, param_id, true);
        }
        return .{
            .id = id,
            .name = lowered,
            .params = specs,
            .kind = kind,
            .return_cap = null,
            .return_ty = try primType(ret_ty),
            .entry_inst_idx = @intCast(self.instructions.items.len),
            .is_ffi_wrapper = false,
            .param_ids = param_ids,
            .reg_ids = &.{},
            .llvm_name = if (kind == .test_func) try std.fmt.allocPrint(self.allocator, "_saasm_test_{d}", .{id}) else null,
            .ignored = ignored,
            .should_panic = should_panic,
        };
    }

    fn appendDeclInst(self: *Codegen, fsig: sig.FunctionSig) !void {
        const id = try self.intern(fsig.name);
        const kind: inst.InstKind = switch (fsig.kind) {
            .normal => .func_decl,
            .ffi_wrapper => .ffi_wrapper_decl,
            .external => .extern_decl,
            .exported => .export_decl,
            .test_func => .test_decl,
        };
        var item = self.makeInst(kind);
        item.operands[0] = .{ .symbol = id };
        item.operands[1] = .{ .func = id };
        try self.appendInst(item);
    }

    fn genFuncDecl(self: *Codegen, f: *const ast.FuncDecl) !void {
        const old_locals = self.locals.items.len;
        defer self.popLocalsTo(old_locals);
        self.beginFunction();
        var fsig = try self.genFuncSig(f.name, .normal, f.params, f.ret_ty, false, false);
        try self.appendDeclInst(fsig);
        try self.emitLabel("L_ENTRY");
        try self.genBlock(f.body);
        if ((try primType(f.ret_ty)) == .void and !self.lastIsTerminator()) {
            try self.releaseOpenLocals(null);
            try self.emitReturn(null);
        }
        fsig.reg_ids = try self.finishFunctionRegs();
        try self.function_sigs.append(fsig);
    }

    fn genTestDecl(self: *Codegen, t: *const ast.TestDecl) !void {
        const old_locals = self.locals.items.len;
        defer self.popLocalsTo(old_locals);
        self.beginFunction();
        var fsig = try self.genFuncSig(t.name, .test_func, &.{}, self.voidType(), t.is_ignored, t.should_panic);
        try self.appendDeclInst(fsig);
        const label = try self.newLabel("L_TEST_ENTRY");
        try self.emitLabel(label);
        try self.genBlock(t.body);
        if (!self.lastIsTerminator()) {
            try self.releaseOpenLocals(null);
            try self.emitReturn(null);
        }
        fsig.reg_ids = try self.finishFunctionRegs();
        try self.function_sigs.append(fsig);
        try self.test_sigs.append(fsig);
    }

    fn voidType(self: *Codegen) *ast.Type {
        const ty = self.allocator.create(ast.Type) catch unreachable;
        ty.* = .{ .primitive = .void_type };
        return ty;
    }

    fn genBlock(self: *Codegen, body: []const *ast.Node) !void {
        for (body) |stmt| {
            try self.genStmt(stmt);
            if (self.lastIsTerminator()) break;
        }
    }

    fn isTerminator(kind: inst.InstKind) bool {
        return switch (kind) {
            .jmp, .br, .br_null, .return_, .panic, .panic_msg, .early_return => true,
            else => false,
        };
    }

    fn lastIsTerminator(self: *Codegen) bool {
        if (self.instructions.items.len == 0) return false;
        return isTerminator(self.instructions.items[self.instructions.items.len - 1].kind);
    }

    fn genStmt(self: *Codegen, stmt: *ast.Node) anyerror!void {
        switch (stmt.*) {
            .let_stmt => |let| {
                const dst = try self.intern(let.name);
                const src = try self.genExpr(let.value);
                try self.emitAssignReg(dst, src);
                try self.pushLocal(let.name, dst, false);
            },
            .expr_stmt => |expr| {
                if (expr.* == .if_expr) {
                    _ = try self.genExpr(expr);
                } else if (expr.* == .call_expr and std.mem.eql(u8, expr.call_expr.func_name, "panic")) {
                    _ = try self.genExpr(expr);
                } else {
                    const value = try self.genExpr(expr);
                    try self.emitRelease(value);
                }
            },
            .return_stmt => |ret| {
                const value = if (ret.value) |v| try self.genExpr(v) else null;
                try self.releaseOpenLocals(value);
                try self.emitReturn(value);
            },
            .block_stmt => |blk| try self.genBlock(blk.body),
            else => return Error.UnsupportedSabDirectFeature,
        }
    }

    fn genExpr(self: *Codegen, expr: *ast.Node) anyerror!u32 {
        return switch (expr.*) {
            .literal => |lit| try self.genLiteral(lit),
            .identifier => |name| blk: {
                if (self.exprHasFnPtrType(expr) and self.tc.funcs.contains(name)) {
                    const dst = try self.intern(try self.newTmp());
                    const vt_name = try self.ensureFunctionPointerVTable(name);
                    try self.emitBorrowSymbol(dst, vt_name);
                    break :blk dst;
                }
                if (self.exprHasFnPtrType(expr)) break :blk self.localReg(name) orelse try self.intern(name);
                break :blk self.localReg(name) orelse try self.intern(name);
            },
            .binary_expr => |bin| try self.genBinary(bin),
            .call_expr => |call| blk: {
                if (self.tc.fn_ptr_calls.contains(expr)) break :blk try self.genFnPtrCall(call);
                break :blk try self.genCall(expr, call);
            },
            .field_expr => |field| try self.genField(field),
            .struct_literal => |lit| try self.genStructLiteral(lit),
            .if_expr => |ife| try self.genIf(ife),
            else => Error.UnsupportedSabDirectFeature,
        };
    }

    fn genLiteral(self: *Codegen, lit: ast.Literal) anyerror!u32 {
        const reg = try self.intern(try self.newTmp());
        try self.recordReg(reg);
        switch (lit) {
            .int_val => |v| try self.emitAssignImm(reg, v),
            .bool_val => |v| try self.emitAssignImm(reg, if (v) 1 else 0),
            else => return Error.UnsupportedSabDirectFeature,
        }
        return reg;
    }

    fn genBinary(self: *Codegen, bin: ast.BinaryExpr) anyerror!u32 {
        const lhs = try self.genExpr(bin.left);
        const rhs = try self.genExpr(bin.right);
        const dst = try self.intern(try self.newTmp());
        try self.recordReg(dst);
        var item = self.makeInst(.op);
        item.op_kind = try opKind(bin.op);
        item.operands[0] = .{ .reg = dst };
        item.operands[1] = .{ .reg = lhs };
        item.operands[2] = .{ .reg = rhs };
        try self.appendInst(item);
        try self.releaseNonLocalTemps(&.{ lhs, rhs });
        return dst;
    }

    fn genCall(self: *Codegen, expr: *const ast.Node, call: ast.CallExpr) anyerror!u32 {
        if (std.mem.eql(u8, call.func_name, "panic")) {
            var item = self.makeInst(.panic);
            if (call.args.len == 1 and call.args[0].* == .literal and call.args[0].literal == .int_val) {
                item.operands[0] = .{ .text = try std.fmt.allocPrint(self.allocator, "{}", .{call.args[0].literal.int_val}) };
            } else if (call.args.len == 1) {
                const code = try self.genExpr(@constCast(call.args[0]));
                item.operands[0] = .{ .reg = code };
            } else {
                item.operands[0] = .{ .text = "1" };
            }
            try self.appendInst(item);
            return try self.intern(try self.newTmp());
        }
        const call_symbol = if (self.tc.resolved_call_symbols.get(expr)) |symbol|
            symbol
        else if (call.associated_target == null)
            call.func_name
        else
            return Error.UnsupportedSabDirectFeature;

        const dst = try self.intern(try self.newTmp());
        try self.recordReg(dst);
        const lowered = try self.loweredFuncSymbol(call_symbol);
        var text = std.ArrayList(u8).init(self.allocator);
        var arg_regs = std.ArrayList(u32).init(self.allocator);
        defer arg_regs.deinit();
        try text.writer().print("@{s}(", .{lowered});
        for (call.args, 0..) |arg, i| {
            const arg_reg = try self.genExpr(@constCast(arg));
            try arg_regs.append(arg_reg);
            if (i > 0) try text.appendSlice(", ");
            try text.writer().print("{s}", .{self.symbols.items[arg_reg]});
        }
        try text.append(')');
        var item = self.makeInst(.call);
        item.operands[0] = .{ .reg = dst };
        item.operands[1] = .{ .text = try text.toOwnedSlice() };
        try self.appendInst(item);
        try self.releaseNonLocalTemps(arg_regs.items);
        return dst;
    }

    fn genFnPtrCall(self: *Codegen, call: ast.CallExpr) anyerror!u32 {
        const fn_reg = self.localReg(call.func_name) orelse try self.intern(call.func_name);
        const call_reg = try self.intern(try self.newTmp());
        try self.recordReg(call_reg);

        var load = self.makeInst(.load);
        load.operands[0] = .{ .reg = call_reg };
        load.operands[1] = .{ .reg = fn_reg };
        load.operands[2] = .{ .imm_u64 = 0 };
        load.operands[3] = .{ .ty = @intFromEnum(sig.PrimType.ptr) };
        try self.appendInst(load);

        const dst = try self.intern(try self.newTmp());
        try self.recordReg(dst);
        var body = std.ArrayList(u8).init(self.allocator);
        var arg_regs = std.ArrayList(u32).init(self.allocator);
        defer arg_regs.deinit();
        try body.writer().print("{s}(", .{self.symbols.items[call_reg]});
        for (call.args, 0..) |arg, i| {
            const arg_reg = try self.genExpr(@constCast(arg));
            try arg_regs.append(arg_reg);
            if (i > 0) try body.appendSlice(", ");
            try body.writer().print("{s}", .{self.symbols.items[arg_reg]});
        }
        try body.append(')');

        var item = self.makeInst(.call_indirect);
        item.operands[0] = .{ .reg = dst };
        item.operands[1] = .{ .text = try body.toOwnedSlice() };
        try self.appendInst(item);
        try self.releaseNonLocalTemps(arg_regs.items);
        try self.emitRelease(call_reg);
        return dst;
    }

    fn genStructLiteral(self: *Codegen, lit: ast.StructLiteral) anyerror!u32 {
        if (lit.update_expr != null) return Error.UnsupportedSabDirectFeature;
        const decl = self.structDeclForType(lit.ty) orelse return Error.UnsupportedSabDirectFeature;
        if (decl.is_opaque or decl.is_union) return Error.UnsupportedSabDirectFeature;

        const dst = try self.intern(try self.newTmp());
        try self.emitAlloc(dst, structSize(decl));

        for (decl.fields) |decl_field| {
            var literal_value: ?*ast.Node = null;
            for (lit.fields) |literal_field| {
                if (std.mem.eql(u8, literal_field.name, decl_field.name)) {
                    literal_value = literal_field.value;
                    break;
                }
            }
            const value = literal_value orelse return Error.UnsupportedSabDirectFeature;
            const layout = try self.fieldLayout(lit.ty, decl_field.name);
            const value_reg = try self.genExpr(value);
            try self.emitStore(dst, layout.offset, value_reg, layout.ty);
            if (!self.isLocalReg(value_reg)) try self.emitRelease(value_reg);
        }

        return dst;
    }

    fn genField(self: *Codegen, field: ast.FieldExpr) anyerror!u32 {
        const expr_ty = self.tc.expr_types.get(field.expr) orelse return Error.MissingType;
        const layout = try self.fieldLayout(expr_ty, field.field_name);
        _ = self.fieldType(expr_ty, field.field_name) orelse return Error.UnsupportedSabDirectFeature;

        const base = try self.genExpr(field.expr);
        const dst = try self.intern(try self.newTmp());
        try self.emitLoad(dst, base, layout.offset, layout.ty);
        if (!self.isLocalReg(base)) try self.emitRelease(base);
        return dst;
    }

    fn genIf(self: *Codegen, ife: ast.IfExpr) anyerror!u32 {
        if (ife.let_chain != null) return Error.UnsupportedSabDirectFeature;
        const cond = try self.genExpr(ife.cond);
        const then_label = try self.newLabel("L_THEN");
        const else_label = try self.newLabel("L_ELSE");
        const merge_label = try self.newLabel("L_MERGE");
        var br = self.makeInst(.br);
        br.operands[0] = .{ .reg = cond };
        br.operands[1] = .{ .label = try self.intern(then_label) };
        br.operands[2] = .{ .label = try self.intern(then_label) };
        br.operands[3] = .{ .label = try self.intern(else_label) };
        try self.appendInst(br);
        try self.emitLabel(then_label);
        try self.emitRelease(cond);
        try self.genBlock(ife.then_block);
        const then_terminated = self.lastIsTerminator();
        if (!then_terminated) try self.emitJmp(merge_label);
        try self.emitLabel(else_label);
        try self.emitRelease(cond);
        if (ife.else_block) |else_block| try self.genBlock(else_block);
        const else_terminated = self.lastIsTerminator();
        if (!else_terminated) try self.emitJmp(merge_label);
        if (!then_terminated or !else_terminated) try self.emitLabel(merge_label);
        const result = try self.intern(try self.newTmp());
        try self.recordReg(result);
        return result;
    }

    fn emitJmp(self: *Codegen, label: []const u8) !void {
        const id = try self.intern(label);
        var item = self.makeInst(.jmp);
        item.operands[0] = .{ .symbol = id };
        item.operands[1] = .{ .label = id };
        try self.appendInst(item);
    }

    fn emitReturn(self: *Codegen, value: ?u32) !void {
        var item = self.makeInst(.return_);
        if (value) |reg| item.operands[0] = .{ .reg = reg };
        try self.appendInst(item);
    }
};

pub fn generate(allocator: std.mem.Allocator, tc: *type_checker.TypeChecker, program: *ast.Node) ![]u8 {
    var cg = Codegen.init(allocator, tc);
    defer cg.deinit();
    return try cg.generate(program);
}
