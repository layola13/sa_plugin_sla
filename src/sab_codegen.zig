const std = @import("std");
const ast = @import("ast.zig");
const type_checker = @import("type_checker.zig");
const sci_bridge = @import("sci_bridge");

const sab = sci_bridge.sab;
const flattener = sci_bridge.flattener;
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

const SavedClosureParam = struct {
    name: []const u8,
    old: ?u32,
};

const FieldLayout = struct {
    offset: usize,
    ty: sig.PrimType,
};

const StdSurfaceRuleKind = enum {
    associated,
    method,
    index,
};

const StdSurfaceArgKind = enum {
    out,
    receiver,
    value,
    index,
    elem_size,
};

const StdSurfaceRule = struct {
    kind: StdSurfaceRuleKind,
    type_name: []const u8,
    member_name: ?[]const u8,
    import_path: []const u8,
    macro_name: []const u8,
    args: []const StdSurfaceArgKind,
    deps: []const []const u8,
};

pub const Codegen = struct {
    allocator: std.mem.Allocator,
    tc: *type_checker.TypeChecker,
    symbols: std.ArrayList([]const u8),
    symbol_ids: std.StringHashMap(u32),
    const_decls: std.ArrayList(const_decl.ConstDecl),
    fn_ptr_vtables: std.StringHashMap(void),
    closure_bindings: std.StringHashMap(*const ast.ClosureLiteral),
    closure_param_regs: std.StringHashMap(u32),
    std_surface_rules: std.ArrayList(StdSurfaceRule),
    included_imports: std.StringHashMap(void),
    instructions: std.ArrayList(inst.Instruction),
    function_sigs: std.ArrayList(sig.FunctionSig),
    test_sigs: std.ArrayList(sig.FunctionSig),
    locals: std.ArrayList(Local),
    current_reg_ids: std.ArrayList(u32),
    current_reg_seen: std.AutoHashMap(u32, void),
    released_regs: std.AutoHashMap(u32, void),
    tmp_idx: usize = 0,
    label_idx: usize = 0,
    macro_fragment_idx: usize = 0,

    pub fn init(allocator: std.mem.Allocator, tc: *type_checker.TypeChecker) Codegen {
        return .{
            .allocator = allocator,
            .tc = tc,
            .symbols = std.ArrayList([]const u8).init(allocator),
            .symbol_ids = std.StringHashMap(u32).init(allocator),
            .const_decls = std.ArrayList(const_decl.ConstDecl).init(allocator),
            .fn_ptr_vtables = std.StringHashMap(void).init(allocator),
            .closure_bindings = std.StringHashMap(*const ast.ClosureLiteral).init(allocator),
            .closure_param_regs = std.StringHashMap(u32).init(allocator),
            .std_surface_rules = std.ArrayList(StdSurfaceRule).init(allocator),
            .included_imports = std.StringHashMap(void).init(allocator),
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
        self.closure_bindings.deinit();
        self.closure_param_regs.deinit();
        for (self.std_surface_rules.items) |rule| {
            self.allocator.free(rule.type_name);
            if (rule.member_name) |name| self.allocator.free(name);
            self.allocator.free(rule.import_path);
            self.allocator.free(rule.macro_name);
            if (rule.args.len != 0) self.allocator.free(rule.args);
            for (rule.deps) |dep| self.allocator.free(dep);
            if (rule.deps.len != 0) self.allocator.free(rule.deps);
        }
        self.std_surface_rules.deinit();
        self.included_imports.deinit();
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
        try self.loadStdSurfaceRules();
        try self.preloadStdSurfaceDeps(program);
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

    fn internStable(self: *Codegen, name: []const u8) !u32 {
        if (self.symbol_ids.get(name)) |id| return id;
        return try self.intern(try self.allocator.dupe(u8, name));
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

    fn readStdSurfaceFile(self: *Codegen) !?[]const u8 {
        if (std.process.getEnvVarOwned(self.allocator, "SLA_STD_DIR")) |root| {
            defer self.allocator.free(root);
            const path = try std.fs.path.join(self.allocator, &.{ root, "std_surface.sla_meta" });
            defer self.allocator.free(path);
            if (std.fs.cwd().readFileAlloc(self.allocator, path, 1024 * 1024)) |source| return source else |err| switch (err) {
                error.FileNotFound, error.NotDir => {},
                else => return err,
            }
        } else |_| {}

        if (std.process.getEnvVarOwned(self.allocator, "HOME")) |home| {
            defer self.allocator.free(home);
            const path = try std.fs.path.join(self.allocator, &.{ home, "projects", "sa_plugins", "sa_plugin_sla", "sla_std", "std_surface.sla_meta" });
            defer self.allocator.free(path);
            if (std.fs.cwd().readFileAlloc(self.allocator, path, 1024 * 1024)) |source| return source else |err| switch (err) {
                error.FileNotFound, error.NotDir => {},
                else => return err,
            }
        } else |_| {}

        const candidates = [_][]const u8{
            "sla_std/std_surface.sla_meta",
            "sa_plugins/sa_plugin_sla/sla_std/std_surface.sla_meta",
            "../sa_plugins/sa_plugin_sla/sla_std/std_surface.sla_meta",
            "/home/vscode/projects/sa_plugins/sa_plugin_sla/sla_std/std_surface.sla_meta",
        };
        for (candidates) |path| {
            if (std.fs.cwd().readFileAlloc(self.allocator, path, 1024 * 1024)) |source| return source else |err| switch (err) {
                error.FileNotFound, error.NotDir => {},
                else => return err,
            }
        }
        return null;
    }

    fn saStdRootLooksValid(self: *Codegen, root: []const u8) !bool {
        const required_files = [_][]const u8{
            "core/sa_core.sa",
            "core/option.sa",
            "core/result.sa",
            "io/print.sai",
        };
        for (required_files) |rel| {
            const path = try std.fs.path.join(self.allocator, &.{ root, rel });
            defer self.allocator.free(path);
            if (std.fs.cwd().openFile(path, .{})) |file| {
                file.close();
            } else |err| switch (err) {
                error.FileNotFound, error.NotDir => return false,
                else => return err,
            }
        }
        return true;
    }

    fn dupeIfValidSaStdRoot(self: *Codegen, root: []const u8) !?[]const u8 {
        if (try self.saStdRootLooksValid(root)) return try self.allocator.dupe(u8, root);
        return null;
    }

    fn resolveSaStdRoot(self: *Codegen) ![]const u8 {
        if (std.process.getEnvVarOwned(self.allocator, "SA_STD_DIR")) |env_root| {
            defer self.allocator.free(env_root);
            if (try self.dupeIfValidSaStdRoot(env_root)) |root| return root;
        } else |_| {}

        if (std.process.getEnvVarOwned(self.allocator, "HOME")) |home| {
            defer self.allocator.free(home);
            const home_repo_std_root = try std.fs.path.join(self.allocator, &.{ home, "projects", "sci", "sa_std" });
            defer self.allocator.free(home_repo_std_root);
            if (try self.dupeIfValidSaStdRoot(home_repo_std_root)) |root| return root;

            const installed_std_root = try std.fs.path.join(self.allocator, &.{ home, ".sa", "std" });
            defer self.allocator.free(installed_std_root);
            if (try self.dupeIfValidSaStdRoot(installed_std_root)) |root| return root;
        } else |_| {}

        const candidate_roots = [_][]const u8{
            "sa_std",
            "sci/sa_std",
            "../sci/sa_std",
            "../../sci/sa_std",
            "/home/vscode/projects/sci/sa_std",
            "/home/vscode/.sa/std",
        };
        for (candidate_roots) |root| {
            if (try self.dupeIfValidSaStdRoot(root)) |valid| return valid;
        }
        return error.FileNotFound;
    }

    fn flattenStdSnippet(self: *Codegen, source: []const u8) !flattener.FlattenResult {
        const std_root = try self.resolveSaStdRoot();
        defer self.allocator.free(std_root);
        const resolve_ctx = flattener.ResolveContext{ .options = .{ .std_root = std_root } };
        return flattener.flattenWithPackages(self.allocator, source, resolve_ctx);
    }

    fn parseStdSurfaceArg(text: []const u8) !StdSurfaceArgKind {
        if (std.mem.eql(u8, text, "out")) return .out;
        if (std.mem.eql(u8, text, "receiver")) return .receiver;
        if (std.mem.eql(u8, text, "value")) return .value;
        if (std.mem.eql(u8, text, "index")) return .index;
        if (std.mem.eql(u8, text, "elem_size")) return .elem_size;
        return Error.UnsupportedSabDirectFeature;
    }

    fn parseStdSurfaceArgs(self: *Codegen, text: []const u8) ![]const StdSurfaceArgKind {
        var args = std.ArrayList(StdSurfaceArgKind).init(self.allocator);
        var it = std.mem.splitScalar(u8, text, ',');
        while (it.next()) |raw| {
            const item = std.mem.trim(u8, raw, " \t\r");
            if (item.len == 0) continue;
            try args.append(try parseStdSurfaceArg(item));
        }
        return try args.toOwnedSlice();
    }

    fn parseStdSurfaceDeps(self: *Codegen, text: ?[]const u8) ![]const []const u8 {
        const raw = text orelse return &.{};
        if (!std.mem.startsWith(u8, raw, "deps=")) return Error.UnsupportedSabDirectFeature;
        var deps = std.ArrayList([]const u8).init(self.allocator);
        var it = std.mem.splitScalar(u8, raw["deps=".len..], ',');
        while (it.next()) |item_raw| {
            const item = std.mem.trim(u8, item_raw, " \t\r");
            if (item.len == 0) continue;
            try deps.append(try self.allocator.dupe(u8, item));
        }
        return try deps.toOwnedSlice();
    }

    fn loadStdSurfaceRules(self: *Codegen) !void {
        if (self.std_surface_rules.items.len != 0) return;
        const source = (try self.readStdSurfaceFile()) orelse return;
        defer self.allocator.free(source);
        var lines = std.mem.splitScalar(u8, source, '\n');
        while (lines.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            var parts = std.mem.tokenizeAny(u8, line, " \t");
            const raw_kind = parts.next() orelse continue;
            if (std.mem.eql(u8, raw_kind, "associated")) {
                const type_name = parts.next() orelse return Error.UnsupportedSabDirectFeature;
                const member_name = parts.next() orelse return Error.UnsupportedSabDirectFeature;
                const import_path = parts.next() orelse return Error.UnsupportedSabDirectFeature;
                const macro_name = parts.next() orelse return Error.UnsupportedSabDirectFeature;
                const arg_text = parts.next() orelse "";
                const deps = try self.parseStdSurfaceDeps(parts.next());
                try self.std_surface_rules.append(.{
                    .kind = .associated,
                    .type_name = try self.allocator.dupe(u8, type_name),
                    .member_name = try self.allocator.dupe(u8, member_name),
                    .import_path = try self.allocator.dupe(u8, import_path),
                    .macro_name = try self.allocator.dupe(u8, macro_name),
                    .args = try self.parseStdSurfaceArgs(arg_text),
                    .deps = deps,
                });
            } else if (std.mem.eql(u8, raw_kind, "method")) {
                const type_name = parts.next() orelse return Error.UnsupportedSabDirectFeature;
                const member_name = parts.next() orelse return Error.UnsupportedSabDirectFeature;
                const import_path = parts.next() orelse return Error.UnsupportedSabDirectFeature;
                const macro_name = parts.next() orelse return Error.UnsupportedSabDirectFeature;
                const arg_text = parts.next() orelse "";
                const deps = try self.parseStdSurfaceDeps(parts.next());
                try self.std_surface_rules.append(.{
                    .kind = .method,
                    .type_name = try self.allocator.dupe(u8, type_name),
                    .member_name = try self.allocator.dupe(u8, member_name),
                    .import_path = try self.allocator.dupe(u8, import_path),
                    .macro_name = try self.allocator.dupe(u8, macro_name),
                    .args = try self.parseStdSurfaceArgs(arg_text),
                    .deps = deps,
                });
            } else if (std.mem.eql(u8, raw_kind, "index")) {
                const type_name = parts.next() orelse return Error.UnsupportedSabDirectFeature;
                const import_path = parts.next() orelse return Error.UnsupportedSabDirectFeature;
                const macro_name = parts.next() orelse return Error.UnsupportedSabDirectFeature;
                const arg_text = parts.next() orelse "";
                const deps = try self.parseStdSurfaceDeps(parts.next());
                try self.std_surface_rules.append(.{
                    .kind = .index,
                    .type_name = try self.allocator.dupe(u8, type_name),
                    .member_name = null,
                    .import_path = try self.allocator.dupe(u8, import_path),
                    .macro_name = try self.allocator.dupe(u8, macro_name),
                    .args = try self.parseStdSurfaceArgs(arg_text),
                    .deps = deps,
                });
            } else {
                return Error.UnsupportedSabDirectFeature;
            }
        }
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

    fn typeBaseName(ty: *const ast.Type) ?[]const u8 {
        var curr = ty;
        while (true) {
            switch (curr.*) {
                .pointer => |p| curr = p,
                .borrow => |b| curr = b,
                else => break,
            }
        }
        if (curr.* != .user_defined) return null;
        return curr.user_defined.name;
    }

    fn firstGenericArg(ty: *const ast.Type) ?*ast.Type {
        var curr = ty;
        while (true) {
            switch (curr.*) {
                .pointer => |p| curr = p,
                .borrow => |b| curr = b,
                else => break,
            }
        }
        if (curr.* != .user_defined or curr.user_defined.generics.len == 0) return null;
        return curr.user_defined.generics[0];
    }

    fn elementSlotSize(self: *Codegen, ty: *const ast.Type) usize {
        _ = self;
        if (firstGenericArg(ty)) |elem_ty| return typeSize(elem_ty);
        return 8;
    }

    fn findStdSurfaceRule(self: *Codegen, kind: StdSurfaceRuleKind, type_name: []const u8, member_name: ?[]const u8) ?StdSurfaceRule {
        for (self.std_surface_rules.items) |rule| {
            if (rule.kind != kind) continue;
            if (!std.mem.eql(u8, rule.type_name, type_name)) continue;
            if (member_name) |member| {
                if (rule.member_name == null or !std.mem.eql(u8, rule.member_name.?, member)) continue;
            } else if (rule.member_name != null) continue;
            return rule;
        }
        return null;
    }

    const StdSurfaceValues = struct {
        out: ?u32 = null,
        receiver: ?u32 = null,
        value: ?u32 = null,
        index: ?u32 = null,
        elem_size: usize = 8,
    };

    fn stdSurfaceArgText(self: *Codegen, kind: StdSurfaceArgKind, values: StdSurfaceValues) ![]const u8 {
        return switch (kind) {
            .out => self.symbols.items[values.out orelse return Error.UnsupportedSabDirectFeature],
            .receiver => self.symbols.items[values.receiver orelse return Error.UnsupportedSabDirectFeature],
            .value => self.symbols.items[values.value orelse return Error.UnsupportedSabDirectFeature],
            .index => self.symbols.items[values.index orelse return Error.UnsupportedSabDirectFeature],
            .elem_size => try std.fmt.allocPrint(self.allocator, "{}", .{values.elem_size}),
        };
    }

    fn emitStdSurfaceRule(self: *Codegen, rule: StdSurfaceRule, values: StdSurfaceValues) !void {
        var args = std.ArrayList([]const u8).init(self.allocator);
        defer args.deinit();
        for (rule.args) |arg_kind| try args.append(try self.stdSurfaceArgText(arg_kind, values));
        try self.emitStdMacroFragment(rule.import_path, rule.macro_name, args.items);
    }

    fn ensureRuleDeps(self: *Codegen, rule: StdSurfaceRule) !void {
        try self.ensureStdDeps(rule.import_path, rule.deps);
    }

    fn preloadStdSurfaceDeps(self: *Codegen, program: *const ast.Node) !void {
        if (program.* != .program) return;
        for (program.program.decls) |decl| try self.preloadNodeStdSurfaceDeps(decl);
    }

    fn preloadBlockStdSurfaceDeps(self: *Codegen, body: []const *ast.Node) !void {
        for (body) |stmt| try self.preloadNodeStdSurfaceDeps(stmt);
    }

    fn preloadNodeStdSurfaceDeps(self: *Codegen, node: *const ast.Node) anyerror!void {
        switch (node.*) {
            .func_decl => |f| try self.preloadBlockStdSurfaceDeps(f.body),
            .test_decl => |t| try self.preloadBlockStdSurfaceDeps(t.body),
            .let_stmt => |let| try self.preloadNodeStdSurfaceDeps(let.value),
            .expr_stmt => |expr| try self.preloadNodeStdSurfaceDeps(expr),
            .return_stmt => |ret| if (ret.value) |value| try self.preloadNodeStdSurfaceDeps(value),
            .block_stmt => |blk| try self.preloadBlockStdSurfaceDeps(blk.body),
            .if_expr => |ife| {
                try self.preloadNodeStdSurfaceDeps(ife.cond);
                try self.preloadBlockStdSurfaceDeps(ife.then_block);
                if (ife.else_block) |else_block| try self.preloadBlockStdSurfaceDeps(else_block);
            },
            .binary_expr => |bin| {
                try self.preloadNodeStdSurfaceDeps(bin.left);
                try self.preloadNodeStdSurfaceDeps(bin.right);
            },
            .field_expr => |field| try self.preloadNodeStdSurfaceDeps(field.expr),
            .struct_literal => |lit| {
                for (lit.fields) |field| try self.preloadNodeStdSurfaceDeps(field.value);
                if (lit.update_expr) |update| try self.preloadNodeStdSurfaceDeps(update);
            },
            .call_expr => |call| {
                if (call.associated_target) |target_name| {
                    if (self.findStdSurfaceRule(.associated, target_name, call.func_name)) |rule| try self.ensureRuleDeps(rule);
                } else if (call.args.len > 0) {
                    if (self.tc.expr_types.get(call.args[0])) |receiver_ty| {
                        if (typeBaseName(receiver_ty)) |receiver_type_name| {
                            if (self.findStdSurfaceRule(.method, receiver_type_name, call.func_name)) |rule| try self.ensureRuleDeps(rule);
                        }
                    }
                }
                for (call.args) |arg| try self.preloadNodeStdSurfaceDeps(arg);
            },
            .index_expr => |idx| {
                if (self.tc.expr_types.get(idx.target)) |target_ty| {
                    if (typeBaseName(target_ty)) |target_type_name| {
                        if (self.findStdSurfaceRule(.index, target_type_name, null)) |rule| try self.ensureRuleDeps(rule);
                    }
                }
                try self.preloadNodeStdSurfaceDeps(idx.target);
                try self.preloadNodeStdSurfaceDeps(idx.index);
            },
            else => {},
        }
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
        self.closure_bindings.clearRetainingCapacity();
        self.closure_param_regs.clearRetainingCapacity();
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

    fn closureLiteralFromExpr(expr: *const ast.Node) ?*const ast.ClosureLiteral {
        return switch (expr.*) {
            .closure_literal => |*lit| lit,
            .move_expr => |mv| closureLiteralFromExpr(mv.expr),
            else => null,
        };
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

    fn remapModuleSymbol(self: *Codegen, symbols: []const []const u8, old_id: u32) !u32 {
        const idx: usize = @intCast(old_id);
        if (idx >= symbols.len) return Error.UnsupportedSabDirectFeature;
        return try self.internStable(symbols[idx]);
    }

    fn cloneOptionalText(self: *Codegen, text: ?[]const u8) !?[]const u8 {
        if (text) |value| return try self.allocator.dupe(u8, value);
        return null;
    }

    fn cloneUpstreamLoc(self: *Codegen, loc: anytype) !@TypeOf(loc) {
        if (loc) |value| return .{ .file = try self.allocator.dupe(u8, value.file), .line = value.line, .col = value.col };
        return null;
    }

    fn cloneTextList(self: *Codegen, items: []const []const u8) ![]const []const u8 {
        if (items.len == 0) return &.{};
        const out = try self.allocator.alloc([]const u8, items.len);
        for (items, 0..) |item, idx| out[idx] = try self.allocator.dupe(u8, item);
        return out;
    }

    fn remapModuleOperand(self: *Codegen, symbols: []const []const u8, operand: inst.Operand) !inst.Operand {
        return switch (operand) {
            .reg => |old_id| .{ .reg = try self.remapModuleSymbol(symbols, old_id) },
            .symbol => |old_id| .{ .symbol = try self.remapModuleSymbol(symbols, old_id) },
            .label => |old_id| .{ .label = try self.remapModuleSymbol(symbols, old_id) },
            .func => |old_id| .{ .func = try self.remapModuleSymbol(symbols, old_id) },
            .text => |text| .{ .text = try self.allocator.dupe(u8, text) },
            .native_text => |text| .{ .native_text = try self.allocator.dupe(u8, text) },
            else => operand,
        };
    }

    fn remapModuleIds(self: *Codegen, symbols: []const []const u8, ids: []const u32) ![]const u32 {
        if (ids.len == 0) return &.{};
        const out = try self.allocator.alloc(u32, ids.len);
        for (ids, 0..) |old_id, idx| out[idx] = try self.remapModuleSymbol(symbols, old_id);
        return out;
    }

    fn cloneModuleParamSpecs(self: *Codegen, params: []const sig.ParamSpec) ![]const sig.ParamSpec {
        if (params.len == 0) return &.{};
        const out = try self.allocator.alloc(sig.ParamSpec, params.len);
        for (params, 0..) |param, idx| {
            out[idx] = .{
                .name = try self.allocator.dupe(u8, param.name),
                .ty = param.ty,
                .cap = param.cap,
            };
        }
        return out;
    }

    fn cloneConstValue(self: *Codegen, value: const_decl.ConstValue) !const_decl.ConstValue {
        return switch (value) {
            .hex => |literal| .{ .hex = .{
                .kind = literal.kind,
                .bytes = try self.allocator.dupe(u8, literal.bytes),
                .repeat_count = literal.repeat_count,
                .repeat_byte = literal.repeat_byte,
            } },
            .utf8 => |literal| .{ .utf8 = .{
                .kind = literal.kind,
                .bytes = try self.allocator.dupe(u8, literal.bytes),
                .repeat_count = literal.repeat_count,
                .repeat_byte = literal.repeat_byte,
            } },
            .repeat => |literal| .{ .repeat = .{
                .kind = literal.kind,
                .bytes = try self.allocator.dupe(u8, literal.bytes),
                .repeat_count = literal.repeat_count,
                .repeat_byte = literal.repeat_byte,
            } },
            .struct_ => |literal| blk: {
                const fields = try self.allocator.alloc(const_decl.StructField, literal.fields.len);
                for (literal.fields, 0..) |field, idx| {
                    fields[idx] = .{
                        .name = try self.allocator.dupe(u8, field.name),
                        .size = field.size,
                        .value = try self.cloneConstValue(field.value),
                    };
                }
                break :blk .{ .struct_ = .{ .fields = fields } };
            },
            .vtable => |literal| blk: {
                const slots = try self.allocator.alloc(const_decl.VTableSlot, literal.slots.len);
                for (literal.slots, 0..) |slot, idx| {
                    slots[idx] = .{
                        .name = try self.allocator.dupe(u8, slot.name),
                        .func_name = try self.allocator.dupe(u8, slot.func_name),
                    };
                }
                break :blk .{ .vtable = .{ .slots = slots } };
            },
        };
    }

    fn cloneModuleConstDecl(self: *Codegen, source: const_decl.ConstDecl) !const_decl.ConstDecl {
        return .{
            .source_line = source.source_line,
            .expanded_line = source.expanded_line,
            .upstream_loc = try self.cloneUpstreamLoc(source.upstream_loc),
            .raw_text = try self.allocator.dupe(u8, source.raw_text),
            .name = try self.allocator.dupe(u8, source.name),
            .literal_text = try self.allocator.dupe(u8, source.literal_text),
            .value = try self.cloneConstValue(source.value),
        };
    }

    fn cloneModuleFunctionSig(self: *Codegen, symbols: []const []const u8, source: sig.FunctionSig, entry_inst_idx: usize) !sig.FunctionSig {
        return .{
            .id = @intCast(self.function_sigs.items.len),
            .name = try self.allocator.dupe(u8, source.name),
            .params = try self.cloneModuleParamSpecs(source.params),
            .kind = source.kind,
            .return_cap = source.return_cap,
            .return_ty = source.return_ty,
            .return_fallible = source.return_fallible,
            .entry_inst_idx = @intCast(entry_inst_idx),
            .is_ffi_wrapper = source.is_ffi_wrapper,
            .upstream_file = try self.cloneOptionalText(source.upstream_file),
            .upstream_loc = try self.cloneUpstreamLoc(source.upstream_loc),
            .param_ids = try self.remapModuleIds(symbols, source.param_ids),
            .reg_ids = try self.remapModuleIds(symbols, source.reg_ids),
            .llvm_name = try self.cloneOptionalText(source.llvm_name),
            .ignored = source.ignored,
            .should_panic = source.should_panic,
        };
    }

    fn cloneModuleInstruction(self: *Codegen, symbols: []const []const u8, source: inst.Instruction) !inst.Instruction {
        var out = source;
        out.package_identity = try self.cloneOptionalText(source.package_identity);
        out.upstream_loc = try self.cloneUpstreamLoc(source.upstream_loc);
        out.raw_text = "";
        out.atomic_expected_text = try self.cloneOptionalText(source.atomic_expected_text);
        out.atomic_new_text = try self.cloneOptionalText(source.atomic_new_text);
        out.native_reg_names = try self.cloneTextList(source.native_reg_names);
        for (&out.operands) |*operand| operand.* = try self.remapModuleOperand(symbols, operand.*);
        return out;
    }

    fn recordInstructionRegs(self: *Codegen, item: inst.Instruction) !void {
        for (item.operands) |operand| {
            if (operand == .reg) try self.recordReg(operand.reg);
        }
    }

    fn moduleHasDep(deps: []const []const u8, name: []const u8) bool {
        for (deps) |dep| {
            if (std.mem.eql(u8, dep, name)) return true;
        }
        return false;
    }

    fn appendDecodedModuleFiltered(self: *Codegen, module: sab.Module, deps: []const []const u8) !void {
        for (module.symbols) |name| _ = try self.internStable(name);
        for (module.const_decls) |decl| {
            _ = try self.internStable(decl.name);
            try self.const_decls.append(try self.cloneModuleConstDecl(decl));
        }

        for (module.function_sigs, 0..) |fsig, idx| {
            if (deps.len != 0 and !moduleHasDep(deps, fsig.name)) continue;
            const entry_idx = self.instructions.items.len;
            const cloned = try self.cloneModuleFunctionSig(module.symbols, fsig, entry_idx);
            try self.function_sigs.append(cloned);
            if (cloned.kind == .test_func) try self.test_sigs.append(cloned);

            const start: usize = fsig.entry_inst_idx;
            const end: usize = if (idx + 1 < module.function_sigs.len) module.function_sigs[idx + 1].entry_inst_idx else module.instructions.len;
            for (module.instructions[start..end]) |item| {
                try self.instructions.append(try self.cloneModuleInstruction(module.symbols, item));
            }
        }
    }

    fn appendDecodedFunctionBody(self: *Codegen, module: sab.Module, func_name: []const u8) !void {
        var start: ?usize = null;
        var end: usize = module.instructions.len;
        for (module.function_sigs, 0..) |fsig, idx| {
            if (std.mem.eql(u8, fsig.name, func_name)) {
                start = fsig.entry_inst_idx;
                if (idx + 1 < module.function_sigs.len) end = module.function_sigs[idx + 1].entry_inst_idx;
                break;
            }
        }
        const body_start = start orelse return Error.UnsupportedSabDirectFeature;
        var i = body_start;
        while (i < end) : (i += 1) {
            const source = module.instructions[i];
            if (i == body_start and (source.kind == .func_decl or source.kind == .test_decl)) continue;
            if (i == body_start + 1 and source.kind == .label) continue;
            if (i + 1 == end and source.kind == .return_) continue;
            const cloned = try self.cloneModuleInstruction(module.symbols, source);
            try self.recordInstructionRegs(cloned);
            try self.instructions.append(cloned);
        }
    }

    fn ensureStdDeps(self: *Codegen, import_path: []const u8, deps: []const []const u8) !void {
        if (deps.len == 0) return;
        var missing = std.ArrayList([]const u8).init(self.allocator);
        defer missing.deinit();
        for (deps) |dep| {
            if (!self.included_imports.contains(dep)) try missing.append(dep);
        }
        if (missing.items.len == 0) return;

        const source = try std.fmt.allocPrint(self.allocator, "@import \"{s}\"\n", .{import_path});
        defer self.allocator.free(source);
        var flat = try self.flattenStdSnippet(source);
        defer flat.deinit(self.allocator);
        const bytes = sci_bridge.encodeSabFromFlat(self.allocator, &flat) catch |err| {
            std.debug.print("SAB std import fragment failed for {s}: {}\n", .{ import_path, err });
            return err;
        };
        defer self.allocator.free(bytes);
        var module = try sab.decodeModule(self.allocator, bytes);
        defer module.deinit(self.allocator);
        try self.appendDecodedModuleFiltered(module, missing.items);
        for (missing.items) |dep| try self.included_imports.put(try self.allocator.dupe(u8, dep), {});
    }

    fn emitStdMacroFragment(self: *Codegen, import_path: []const u8, macro_name: []const u8, args: []const []const u8) !void {
        const func_name = try std.fmt.allocPrint(self.allocator, "__sla_macro_fragment_{}", .{self.macro_fragment_idx});
        self.macro_fragment_idx += 1;

        var source = std.ArrayList(u8).init(self.allocator);
        try source.writer().print("@import \"{s}\"\n@{s}() -> void:\nL_ENTRY:\n    EXPAND {s}", .{ import_path, func_name, macro_name });
        for (args, 0..) |arg, i| {
            if (i == 0) {
                try source.writer().print(" {s}", .{arg});
            } else {
                try source.writer().print(", {s}", .{arg});
            }
        }
        try source.appendSlice("\n    return\n");

        var flat = try self.flattenStdSnippet(source.items);
        defer flat.deinit(self.allocator);
        const bytes = try sci_bridge.encodeSabFromFlatUnchecked(self.allocator, &flat);
        defer self.allocator.free(bytes);
        var module = try sab.decodeModule(self.allocator, bytes);
        defer module.deinit(self.allocator);
        try self.appendDecodedFunctionBody(module, func_name);
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
                if (closureLiteralFromExpr(let.value)) |closure| {
                    try self.closure_bindings.put(let.name, closure);
                    try self.emitAssignImm(dst, 0);
                    try self.pushLocal(let.name, dst, false);
                    return;
                }
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
                if (self.closure_param_regs.get(name)) |mapped| break :blk mapped;
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
            .index_expr => |idx| try self.genIndex(idx),
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
        if (call.associated_target == null) {
            if (self.closure_bindings.get(call.func_name)) |closure| return try self.genClosureCall(closure, call);
        }
        if (try self.genStdSurfaceCall(expr, call)) |reg| return reg;
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

    fn genClosureCall(self: *Codegen, closure: *const ast.ClosureLiteral, call: ast.CallExpr) anyerror!u32 {
        if (closure.params.len != call.args.len) return Error.UnsupportedSabDirectFeature;

        var arg_regs = std.ArrayList(u32).init(self.allocator);
        defer arg_regs.deinit();
        for (call.args) |arg| try arg_regs.append(try self.genExpr(@constCast(arg)));

        var saved = std.ArrayList(SavedClosureParam).init(self.allocator);
        defer saved.deinit();
        for (closure.params, arg_regs.items) |param, arg_reg| {
            try saved.append(.{ .name = param.name, .old = self.closure_param_regs.get(param.name) });
            try self.closure_param_regs.put(param.name, arg_reg);
        }
        defer self.restoreClosureParams(saved.items);

        const result = try self.genExpr(@constCast(closure.body));
        for (arg_regs.items) |arg_reg| {
            if (arg_reg == result or self.isLocalReg(arg_reg)) continue;
            try self.emitRelease(arg_reg);
        }
        return result;
    }

    fn genStdSurfaceCall(self: *Codegen, expr: *const ast.Node, call: ast.CallExpr) anyerror!?u32 {
        if (call.associated_target) |target_name| {
            if (self.findStdSurfaceRule(.associated, target_name, call.func_name)) |rule| {
                const dst = try self.intern(try self.newTmp());
                try self.recordReg(dst);
                const expr_ty = self.tc.expr_types.get(expr) orelse return Error.MissingType;
                try self.emitStdSurfaceRule(rule, .{
                    .out = dst,
                    .elem_size = self.elementSlotSize(expr_ty),
                });
                return dst;
            }
            return null;
        }

        if (call.args.len == 0) return null;
        const receiver_ty = self.tc.expr_types.get(call.args[0]) orelse return null;
        const receiver_type_name = typeBaseName(receiver_ty) orelse return null;
        const rule = self.findStdSurfaceRule(.method, receiver_type_name, call.func_name) orelse return null;
        const receiver_reg = try self.genExpr(@constCast(call.args[0]));
        const value_reg = if (call.args.len > 1) try self.genExpr(@constCast(call.args[1])) else null;
        try self.emitStdSurfaceRule(rule, .{
            .receiver = receiver_reg,
            .value = value_reg,
            .elem_size = self.elementSlotSize(receiver_ty),
        });
        var release_regs = std.ArrayList(u32).init(self.allocator);
        defer release_regs.deinit();
        try release_regs.append(receiver_reg);
        if (value_reg) |reg| try release_regs.append(reg);
        try self.releaseNonLocalTemps(release_regs.items);

        const sentinel = try self.intern(try self.newTmp());
        try self.recordReg(sentinel);
        try self.emitAssignImm(sentinel, 0);
        return sentinel;
    }

    fn genIndex(self: *Codegen, idx: ast.IndexExpr) anyerror!u32 {
        const target_ty = self.tc.expr_types.get(idx.target) orelse return Error.MissingType;
        const target_type_name = typeBaseName(target_ty) orelse return Error.UnsupportedSabDirectFeature;
        const rule = self.findStdSurfaceRule(.index, target_type_name, null) orelse return Error.UnsupportedSabDirectFeature;
        const target_reg = try self.genExpr(idx.target);
        const index_reg = try self.genExpr(idx.index);
        const dst = try self.intern(try self.newTmp());
        try self.recordReg(dst);
        try self.emitStdSurfaceRule(rule, .{
            .out = dst,
            .receiver = target_reg,
            .index = index_reg,
            .elem_size = self.elementSlotSize(target_ty),
        });
        try self.releaseNonLocalTemps(&.{ target_reg, index_reg });
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
