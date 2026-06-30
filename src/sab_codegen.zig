const std = @import("std");
const ast = @import("ast.zig");
const type_checker = @import("type_checker.zig");
const lowering_rules = @import("lowering_rules.zig");
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
    stack_ty: ?*const ast.Type = null,
    ty: ?*const ast.Type = null,
    param_cap: ?inst.CapPrefix = null,
    is_stack_alloc: bool = false,
};

const MacroArgBinding = struct {
    name: []const u8,
    arg: *const ast.Node,
    ctx: ?*MacroExpansionContext = null,
};

const MacroLocalBinding = struct {
    mapped: []const u8,
    ty: ?*const ast.Type = null,
};

const MacroLocalChange = struct {
    name: []const u8,
    had_old: bool,
    old: MacroLocalBinding = undefined,
};

const MacroExpansionContext = struct {
    macro_name: []const u8,
    invocation: usize,
    local_idx: usize = 0,
    args: []const MacroArgBinding,
    locals: std.StringHashMap(MacroLocalBinding),
    local_changes: std.ArrayList(MacroLocalChange),
    allocated_names: std.ArrayList([]const u8),
};

const EscapedCapture = struct {
    name: []const u8,
    offset: usize,
    ty: *const ast.Type,
};

const EscapedClosureEntry = struct {
    worker_name: []const u8,
    spawn_name: []const u8,
    vtable_name: []const u8,
    closure: *const ast.ClosureLiteral,
    ret_ty: *const ast.Type,
    captures: []const EscapedCapture,
    slot_size: usize,
};

const EscapedCaptureCollector = struct {
    ordered: std.ArrayList(EscapedCapture),
    seen: std.StringHashMap(void),
};

const SavedClosureParam = struct {
    name: []const u8,
    old: ?u32,
};

const FieldLayout = struct {
    offset: usize,
    ty: sig.PrimType,
};

const AddressSource = struct {
    reg: u32,
};

const StdSurfaceRuleKind = enum {
    associated,
    constructor,
    function,
    method,
    fallible_method,
    index,
    index_assign,
};

const StdSurfaceArgKind = enum {
    out,
    ok,
    receiver,
    value,
    index,
    elem_size,
    elem_ty,
};

const StdSurfaceRule = struct {
    kind: StdSurfaceRuleKind,
    type_name: []const u8,
    member_name: ?[]const u8,
    import_path: []const u8,
    macro_name: []const u8,
    args: []const StdSurfaceArgKind,
    deps: []const []const u8,
    panic_code: ?i64 = null,
};

const StdSurfaceRuleOptions = struct {
    deps: []const []const u8 = &.{},
    panic_code: ?i64 = null,
};

const StdImportModule = struct {
    import_path: []const u8,
    module: sab.Module,
};

const StdMacroTemplate = struct {
    key: []const u8,
    func_name: []const u8,
    arg_count: usize,
    module: sab.Module,
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
    borrowed_bindings: std.StringHashMap(void),
    std_surface_rules: std.ArrayList(StdSurfaceRule),
    included_imports: std.StringHashMap(void),
    std_import_modules: std.ArrayList(StdImportModule),
    std_import_module_ids: std.StringHashMap(usize),
    std_macro_templates: std.ArrayList(StdMacroTemplate),
    std_macro_template_ids: std.StringHashMap(usize),
    escaped_closure_entries: std.AutoHashMap(*const ast.Node, EscapedClosureEntry),
    global_scalar_consts: std.StringHashMap(*const ast.Node),
    sa_std_root: ?[]const u8 = null,
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
    macro_call_idx: usize = 0,
    escaped_closure_idx: usize = 0,

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
            .borrowed_bindings = std.StringHashMap(void).init(allocator),
            .std_surface_rules = std.ArrayList(StdSurfaceRule).init(allocator),
            .included_imports = std.StringHashMap(void).init(allocator),
            .std_import_modules = std.ArrayList(StdImportModule).init(allocator),
            .std_import_module_ids = std.StringHashMap(usize).init(allocator),
            .std_macro_templates = std.ArrayList(StdMacroTemplate).init(allocator),
            .std_macro_template_ids = std.StringHashMap(usize).init(allocator),
            .escaped_closure_entries = std.AutoHashMap(*const ast.Node, EscapedClosureEntry).init(allocator),
            .global_scalar_consts = std.StringHashMap(*const ast.Node).init(allocator),
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
        self.borrowed_bindings.deinit();
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
        for (self.std_import_modules.items) |*entry| {
            self.allocator.free(entry.import_path);
            entry.module.deinit(self.allocator);
        }
        self.std_import_modules.deinit();
        self.std_import_module_ids.deinit();
        for (self.std_macro_templates.items) |*entry| {
            self.allocator.free(entry.key);
            self.allocator.free(entry.func_name);
            entry.module.deinit(self.allocator);
        }
        self.std_macro_templates.deinit();
        self.std_macro_template_ids.deinit();
        var escaped_iter = self.escaped_closure_entries.valueIterator();
        while (escaped_iter.next()) |entry| {
            self.allocator.free(entry.worker_name);
            self.allocator.free(entry.spawn_name);
            self.allocator.free(entry.vtable_name);
            if (entry.captures.len != 0) self.allocator.free(entry.captures);
        }
        self.escaped_closure_entries.deinit();
        self.global_scalar_consts.deinit();
        if (self.sa_std_root) |root| self.allocator.free(root);
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
        try self.collectGlobalScalarConsts(program);
        try self.loadStdSurfaceRules();
        self.preloadStdSurfaceDeps(program) catch |err| {
            self.traceUnsupported("std surface preload failed: {s}\n", .{@errorName(err)});
            return err;
        };
        for (program.program.decls) |decl| {
            if (decl.* == .impl_decl and decl.impl_decl.trait_name != null) {
                try self.emitTraitVTableDecl(&decl.impl_decl);
            }
        }
        for (program.program.decls) |decl| {
            switch (decl.*) {
                .func_decl => |*f| {
                    if (!f.is_decl_only) {
                        self.genFuncDecl(f) catch |err| {
                            self.traceUnsupported("func decl {s} failed: {s}\n", .{ f.name, @errorName(err) });
                            return err;
                        };
                    }
                },
                .test_decl => |*t| {
                    self.genTestDecl(t) catch |err| {
                        self.traceUnsupported("test decl {s} failed: {s}\n", .{ t.name, @errorName(err) });
                        return err;
                    };
                },
                .impl_decl => |*i| {
                    self.genImplDecl(i) catch |err| {
                        self.traceUnsupported("impl decl failed: {s}\n", .{@errorName(err)});
                        return err;
                    };
                },
                .overload_decl => |*o| {
                    self.genOverloadDecl(o) catch |err| {
                        self.traceUnsupported("overload decl failed: {s}\n", .{@errorName(err)});
                        return err;
                    };
                },
                .struct_decl, .enum_decl, .trait_decl, .type_alias_decl, .macro_decl, .import_decl, .using_decl, .const_stmt => {},
                else => {
                    self.traceUnsupported("top-level decl {s} failed\n", .{@tagName(decl.*)});
                    return Error.UnsupportedSabDirectFeature;
                },
            }
        }
        try self.emitEscapedClosureEntries();
        return try sab.encodeProgramWithConsts(
            self.allocator,
            self.symbols.items,
            self.const_decls.items,
            self.function_sigs.items,
            self.instructions.items,
        );
    }

    fn collectGlobalScalarConsts(self: *Codegen, program: *const ast.Node) !void {
        self.global_scalar_consts.clearRetainingCapacity();
        if (program.* != .program) return;
        for (program.program.decls) |decl| {
            if (decl.* != .const_stmt) continue;
            const c = decl.const_stmt;
            if (c.value.* != .literal) continue;
            switch (c.value.literal) {
                .int_val, .float_val, .bool_val => try self.global_scalar_consts.put(c.name, c.value),
                else => {},
            }
        }
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

    fn mangleMethodName(self: *Codegen, ty_name: []const u8, method_name: []const u8) ![]const u8 {
        return try lowering_rules.mangleMethodName(self.allocator, ty_name, method_name);
    }

    fn mangleTraitMethodName(self: *Codegen, ty_name: []const u8, trait_name: []const u8, method_name: []const u8) ![]const u8 {
        return try lowering_rules.mangleTraitMethodName(self.allocator, ty_name, trait_name, method_name);
    }

    fn concreteTypeName(ty: *const ast.Type) ?[]const u8 {
        return lowering_rules.concreteTypeName(ty);
    }

    fn dynTraitName(ty: *const ast.Type) ?[]const u8 {
        return lowering_rules.dynTraitName(ty);
    }

    fn vtableName(self: *Codegen, trait_name: []const u8, type_name: []const u8) ![]u8 {
        return try lowering_rules.vtableName(self.allocator, trait_name, type_name);
    }

    fn appendTraitVTableEntries(
        self: *Codegen,
        trait_name: []const u8,
        type_name: []const u8,
        slots: *std.ArrayList(const_decl.VTableSlot),
        literal: *std.ArrayList(u8),
    ) !void {
        const trait_decl = self.tc.traits.get(trait_name) orelse return Error.UnsupportedSabDirectFeature;
        for (trait_decl.supertraits) |supertrait| {
            try self.appendTraitVTableEntries(supertrait, type_name, slots, literal);
        }
        for (trait_decl.methods) |method| {
            if (slots.items.len > 0) try literal.appendSlice(", ");
            const mangled = try self.mangleTraitMethodName(type_name, trait_name, method.name);
            const lowered = try self.loweredFuncSymbol(mangled);
            try literal.writer().print("{s} = @{s}", .{ method.name, lowered });
            try slots.append(.{
                .name = try self.allocator.dupe(u8, method.name),
                .func_name = try self.allocator.dupe(u8, lowered),
            });
            _ = try self.intern(lowered);
        }
    }

    fn emitTraitVTableDecl(self: *Codegen, decl: *const ast.ImplDecl) !void {
        const trait_name = decl.trait_name orelse return;
        const type_name = concreteTypeName(decl.target_ty) orelse return Error.UnsupportedSabDirectFeature;
        const vt_name = try self.vtableName(trait_name, type_name);

        var slots = std.ArrayList(const_decl.VTableSlot).init(self.allocator);
        var literal = std.ArrayList(u8).init(self.allocator);
        try literal.appendSlice("vtable { ");
        try self.appendTraitVTableEntries(trait_name, type_name, &slots, &literal);
        try literal.appendSlice(" }");
        const literal_text = try literal.toOwnedSlice();
        const raw_text = try std.fmt.allocPrint(self.allocator, "@const {s} = {s}", .{ vt_name, literal_text });

        try self.const_decls.append(.{
            .source_line = 0,
            .expanded_line = 0,
            .upstream_loc = null,
            .raw_text = raw_text,
            .name = vt_name,
            .literal_text = literal_text,
            .value = .{ .vtable = .{ .slots = try slots.toOwnedSlice() } },
        });
        _ = try self.intern(vt_name);
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

    fn appendVTableConst(self: *Codegen, vtable_name: []const u8, worker_name: []const u8) !void {
        const literal_text = try std.fmt.allocPrint(self.allocator, "vtable {{ call = @{s} }}", .{worker_name});
        const raw_text = try std.fmt.allocPrint(self.allocator, "@const {s} = {s}", .{ vtable_name, literal_text });
        const slots = try self.allocator.alloc(const_decl.VTableSlot, 1);
        slots[0] = .{
            .name = try self.allocator.dupe(u8, "call"),
            .func_name = try self.allocator.dupe(u8, worker_name),
        };
        try self.const_decls.append(.{
            .source_line = 0,
            .expanded_line = 0,
            .upstream_loc = null,
            .raw_text = raw_text,
            .name = try self.allocator.dupe(u8, vtable_name),
            .literal_text = literal_text,
            .value = .{ .vtable = .{ .slots = slots } },
        });
        _ = try self.intern(vtable_name);
        _ = try self.intern(worker_name);
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

    fn cachedSaStdRoot(self: *Codegen) ![]const u8 {
        if (self.sa_std_root) |root| return root;
        self.sa_std_root = try self.resolveSaStdRoot();
        return self.sa_std_root.?;
    }

    fn flattenStdSnippet(self: *Codegen, source: []const u8) !flattener.FlattenResult {
        const std_root = try self.cachedSaStdRoot();
        const resolve_ctx = flattener.ResolveContext{ .options = .{ .std_root = std_root } };
        return flattener.flattenWithPackages(self.allocator, source, resolve_ctx);
    }

    fn parseStdSurfaceArg(text: []const u8) !StdSurfaceArgKind {
        if (std.mem.eql(u8, text, "out")) return .out;
        if (std.mem.eql(u8, text, "ok")) return .ok;
        if (std.mem.eql(u8, text, "receiver")) return .receiver;
        if (std.mem.eql(u8, text, "value")) return .value;
        if (std.mem.eql(u8, text, "index")) return .index;
        if (std.mem.eql(u8, text, "elem_size")) return .elem_size;
        if (std.mem.eql(u8, text, "elem_ty")) return .elem_ty;
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

    fn parseStdSurfaceOption(self: *Codegen, text: []const u8, options: *StdSurfaceRuleOptions) !void {
        if (std.mem.startsWith(u8, text, "deps=")) {
            options.deps = try self.parseStdSurfaceDeps(text);
            return;
        }
        if (std.mem.startsWith(u8, text, "panic=")) {
            options.panic_code = try std.fmt.parseInt(i64, text["panic=".len..], 10);
            return;
        }
        return Error.UnsupportedSabDirectFeature;
    }

    fn appendStdSurfaceRule(
        self: *Codegen,
        kind: StdSurfaceRuleKind,
        type_name: []const u8,
        member_name: ?[]const u8,
        import_path: []const u8,
        macro_name: []const u8,
        arg_text: []const u8,
        options: StdSurfaceRuleOptions,
    ) !void {
        try self.std_surface_rules.append(.{
            .kind = kind,
            .type_name = try self.allocator.dupe(u8, type_name),
            .member_name = if (member_name) |name| try self.allocator.dupe(u8, name) else null,
            .import_path = try self.allocator.dupe(u8, import_path),
            .macro_name = try self.allocator.dupe(u8, macro_name),
            .args = try self.parseStdSurfaceArgs(arg_text),
            .deps = options.deps,
            .panic_code = options.panic_code,
        });
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
                var options = StdSurfaceRuleOptions{};
                while (parts.next()) |option| try self.parseStdSurfaceOption(option, &options);
                try self.appendStdSurfaceRule(.associated, type_name, member_name, import_path, macro_name, arg_text, options);
            } else if (std.mem.eql(u8, raw_kind, "function")) {
                const member_name = parts.next() orelse return Error.UnsupportedSabDirectFeature;
                const type_name = parts.next() orelse return Error.UnsupportedSabDirectFeature;
                const import_path = parts.next() orelse return Error.UnsupportedSabDirectFeature;
                const macro_name = parts.next() orelse return Error.UnsupportedSabDirectFeature;
                const arg_text = parts.next() orelse "";
                var options = StdSurfaceRuleOptions{};
                while (parts.next()) |option| try self.parseStdSurfaceOption(option, &options);
                try self.appendStdSurfaceRule(.function, type_name, member_name, import_path, macro_name, arg_text, options);
            } else if (std.mem.eql(u8, raw_kind, "constructor")) {
                const member_name = parts.next() orelse return Error.UnsupportedSabDirectFeature;
                const type_name = parts.next() orelse return Error.UnsupportedSabDirectFeature;
                const import_path = parts.next() orelse return Error.UnsupportedSabDirectFeature;
                const macro_name = parts.next() orelse return Error.UnsupportedSabDirectFeature;
                const arg_text = parts.next() orelse "";
                var options = StdSurfaceRuleOptions{};
                while (parts.next()) |option| try self.parseStdSurfaceOption(option, &options);
                try self.appendStdSurfaceRule(.constructor, type_name, member_name, import_path, macro_name, arg_text, options);
            } else if (std.mem.eql(u8, raw_kind, "method")) {
                const type_name = parts.next() orelse return Error.UnsupportedSabDirectFeature;
                const member_name = parts.next() orelse return Error.UnsupportedSabDirectFeature;
                const import_path = parts.next() orelse return Error.UnsupportedSabDirectFeature;
                const macro_name = parts.next() orelse return Error.UnsupportedSabDirectFeature;
                const arg_text = parts.next() orelse "";
                var options = StdSurfaceRuleOptions{};
                while (parts.next()) |option| try self.parseStdSurfaceOption(option, &options);
                try self.appendStdSurfaceRule(.method, type_name, member_name, import_path, macro_name, arg_text, options);
            } else if (std.mem.eql(u8, raw_kind, "fallible_method")) {
                const type_name = parts.next() orelse return Error.UnsupportedSabDirectFeature;
                const member_name = parts.next() orelse return Error.UnsupportedSabDirectFeature;
                const import_path = parts.next() orelse return Error.UnsupportedSabDirectFeature;
                const macro_name = parts.next() orelse return Error.UnsupportedSabDirectFeature;
                const arg_text = parts.next() orelse "";
                var options = StdSurfaceRuleOptions{};
                while (parts.next()) |option| try self.parseStdSurfaceOption(option, &options);
                if (options.panic_code == null) return Error.UnsupportedSabDirectFeature;
                try self.appendStdSurfaceRule(.fallible_method, type_name, member_name, import_path, macro_name, arg_text, options);
            } else if (std.mem.eql(u8, raw_kind, "index")) {
                const type_name = parts.next() orelse return Error.UnsupportedSabDirectFeature;
                const import_path = parts.next() orelse return Error.UnsupportedSabDirectFeature;
                const macro_name = parts.next() orelse return Error.UnsupportedSabDirectFeature;
                const arg_text = parts.next() orelse "";
                var options = StdSurfaceRuleOptions{};
                while (parts.next()) |option| try self.parseStdSurfaceOption(option, &options);
                try self.appendStdSurfaceRule(.index, type_name, null, import_path, macro_name, arg_text, options);
            } else if (std.mem.eql(u8, raw_kind, "index_assign")) {
                const type_name = parts.next() orelse return Error.UnsupportedSabDirectFeature;
                const import_path = parts.next() orelse return Error.UnsupportedSabDirectFeature;
                const macro_name = parts.next() orelse return Error.UnsupportedSabDirectFeature;
                const arg_text = parts.next() orelse "";
                var options = StdSurfaceRuleOptions{};
                while (parts.next()) |option| try self.parseStdSurfaceOption(option, &options);
                try self.appendStdSurfaceRule(.index_assign, type_name, null, import_path, macro_name, arg_text, options);
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
        return lowering_rules.abiTypeSize(ty);
    }

    fn alignOffset(offset: usize, size: usize) usize {
        return lowering_rules.alignAggregateOffset(offset, size);
    }

    fn tupleSize(tuple: ast.TupleType) usize {
        return lowering_rules.tupleAbiSize(tuple);
    }

    fn tupleFieldLayout(tuple: ast.TupleType, index: usize) ?FieldLayout {
        const layout = lowering_rules.tupleFieldLayout(tuple, index) orelse return null;
        return .{ .offset = layout.offset, .ty = primType(layout.ty) catch return null };
    }

    fn arrayStride(elem_ty: *const ast.Type) usize {
        return lowering_rules.inlineArrayStride(elem_ty);
    }

    fn arraySize(arr: ast.ArrayType) usize {
        return lowering_rules.inlineArraySize(arr);
    }

    fn arrayElementLayout(arr: ast.ArrayType, index: usize) ?FieldLayout {
        const layout = lowering_rules.arrayElementLayout(arr, index) orelse return null;
        return .{ .offset = layout.offset, .ty = primType(layout.ty) catch return null };
    }

    fn structSize(s: *const ast.StructDecl) usize {
        return lowering_rules.structAbiSize(s);
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
        const layout = lowering_rules.structFieldLayout(decl, name) orelse return Error.UnsupportedSabDirectFeature;
        return .{ .offset = layout.offset, .ty = try primType(layout.ty) };
    }

    fn typeHasCopyDerive(self: *Codegen, ty: *const ast.Type) bool {
        return switch (ty.*) {
            .primitive => |p| p != .void_type,
            .user_defined => blk: {
                const decl = self.structDeclForType(ty) orelse break :blk false;
                if (!lowering_rules.structHasDerive(decl, "copy") or decl.is_opaque or decl.is_union) break :blk false;
                for (decl.fields) |field| {
                    if (!self.typeHasCopyDerive(field.ty)) break :blk false;
                }
                break :blk true;
            },
            else => false,
        };
    }

    fn typeIsCopyStruct(self: *Codegen, ty: *const ast.Type) bool {
        return self.structDeclForType(ty) != null and self.typeHasCopyDerive(ty);
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

    fn elementLoadType(self: *Codegen, ty: *const ast.Type) !sig.PrimType {
        _ = self;
        const elem_ty = firstGenericArg(ty) orelse return Error.UnsupportedSabDirectFeature;
        return try primType(elem_ty);
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

    fn stdSurfaceRuleHasArg(rule: StdSurfaceRule, arg: StdSurfaceArgKind) bool {
        for (rule.args) |candidate| {
            if (candidate == arg) return true;
        }
        return false;
    }

    const StdSurfaceValues = struct {
        out: ?u32 = null,
        ok: ?u32 = null,
        receiver: ?u32 = null,
        value: ?u32 = null,
        index: ?u32 = null,
        elem_size: usize = 8,
        elem_ty: ?sig.PrimType = null,
    };

    fn stdSurfaceArgText(self: *Codegen, kind: StdSurfaceArgKind, values: StdSurfaceValues) ![]const u8 {
        return switch (kind) {
            .out => self.symbols.items[values.out orelse return Error.UnsupportedSabDirectFeature],
            .ok => self.symbols.items[values.ok orelse return Error.UnsupportedSabDirectFeature],
            .receiver => self.symbols.items[values.receiver orelse return Error.UnsupportedSabDirectFeature],
            .value => self.symbols.items[values.value orelse return Error.UnsupportedSabDirectFeature],
            .index => self.symbols.items[values.index orelse return Error.UnsupportedSabDirectFeature],
            .elem_size => try std.fmt.allocPrint(self.allocator, "{}", .{values.elem_size}),
            .elem_ty => sig.primTypeName(values.elem_ty orelse return Error.UnsupportedSabDirectFeature),
        };
    }

    fn primTypeMacroSuffix(ty: sig.PrimType) ![]const u8 {
        return switch (ty) {
            .i1 => "I1",
            .i8 => "I8",
            .i16 => "I16",
            .i32 => "I32",
            .i64 => "I64",
            .u8 => "U8",
            .u16 => "U16",
            .u32 => "U32",
            .u64 => "U64",
            .f32 => "F32",
            .f64 => "F64",
            .ptr => "PTR",
            else => Error.UnsupportedSabDirectFeature,
        };
    }

    fn stdSurfaceMacroName(self: *Codegen, rule: StdSurfaceRule, values: StdSurfaceValues) ![]const u8 {
        const marker = "{elem_ty}";
        if (std.mem.indexOf(u8, rule.macro_name, marker) == null) return try self.allocator.dupe(u8, rule.macro_name);
        const elem_ty = values.elem_ty orelse return Error.UnsupportedSabDirectFeature;
        return try std.mem.replaceOwned(u8, self.allocator, rule.macro_name, marker, try primTypeMacroSuffix(elem_ty));
    }

    fn emitStdSurfaceRule(self: *Codegen, rule: StdSurfaceRule, values: StdSurfaceValues) !void {
        var args = std.ArrayList([]const u8).init(self.allocator);
        defer args.deinit();
        for (rule.args) |arg_kind| try args.append(try self.stdSurfaceArgText(arg_kind, values));
        const macro_name = try self.stdSurfaceMacroName(rule, values);
        defer self.allocator.free(macro_name);
        try self.emitStdMacroFragment(rule.import_path, macro_name, args.items);
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

    fn isThreadSpawnCall(call: ast.CallExpr) bool {
        return call.associated_target != null and
            std.mem.eql(u8, call.associated_target.?, "thread") and
            std.mem.eql(u8, call.func_name, "spawn") and
            call.args.len == 1;
    }

    fn preloadNodeStdSurfaceDeps(self: *Codegen, node: *const ast.Node) anyerror!void {
        switch (node.*) {
            .func_decl => |f| try self.preloadBlockStdSurfaceDeps(f.body),
            .test_decl => |t| try self.preloadBlockStdSurfaceDeps(t.body),
            .let_stmt => |let| try self.preloadNodeStdSurfaceDeps(let.value),
            .let_destructure_stmt => |let| try self.preloadNodeStdSurfaceDeps(let.value),
            .let_else_stmt => |let| {
                try self.preloadNodeStdSurfaceDeps(let.value);
                try self.preloadBlockStdSurfaceDeps(let.else_block);
            },
            .const_stmt => |c| try self.preloadNodeStdSurfaceDeps(c.value),
            .var_stmt => {},
            .assign_stmt => |assign| {
                if (assign.target.* == .index_expr) {
                    const idx = assign.target.index_expr;
                    if (self.tc.expr_types.get(idx.target)) |target_ty| {
                        if (typeBaseName(target_ty)) |target_type_name| {
                            if (self.findStdSurfaceRule(.index_assign, target_type_name, null)) |rule| try self.ensureRuleDeps(rule);
                        }
                    }
                }
                try self.preloadNodeStdSurfaceDeps(assign.target);
                try self.preloadNodeStdSurfaceDeps(assign.value);
            },
            .expr_stmt => |expr| try self.preloadNodeStdSurfaceDeps(expr),
            .return_stmt => |ret| if (ret.value) |value| try self.preloadNodeStdSurfaceDeps(value),
            .block_stmt => |blk| try self.preloadBlockStdSurfaceDeps(blk.body),
            .identifier => |name| {
                if (self.tc.expr_types.get(node)) |expr_ty| {
                    if (typeBaseName(expr_ty)) |type_name| {
                        if (self.findStdSurfaceRule(.constructor, type_name, name)) |rule| try self.ensureRuleDeps(rule);
                    }
                }
            },
            .binary_expr => |bin| {
                try self.preloadNodeStdSurfaceDeps(bin.left);
                try self.preloadNodeStdSurfaceDeps(bin.right);
            },
            .borrow_expr => |borrow| try self.preloadNodeStdSurfaceDeps(borrow.expr),
            .move_expr => |move| try self.preloadNodeStdSurfaceDeps(move.expr),
            .deref_expr => |deref| try self.preloadNodeStdSurfaceDeps(deref.expr),
            .cast_expr => |cast| try self.preloadNodeStdSurfaceDeps(cast.expr),
            .field_expr => |field| try self.preloadNodeStdSurfaceDeps(field.expr),
            .struct_literal => |lit| {
                for (lit.fields) |field| try self.preloadNodeStdSurfaceDeps(field.value);
                if (lit.update_expr) |update| try self.preloadNodeStdSurfaceDeps(update);
            },
            .tuple_literal => |lit| for (lit.elements) |elem| try self.preloadNodeStdSurfaceDeps(elem),
            .array_literal => |lit| for (lit.elements) |elem| try self.preloadNodeStdSurfaceDeps(elem),
            .repeat_array_literal => |lit| try self.preloadNodeStdSurfaceDeps(lit.value),
            .closure_literal => |lit| try self.preloadNodeStdSurfaceDeps(lit.body),
            .call_expr => |call| {
                if (isThreadSpawnCall(call)) try self.ensureStdDeps("sa_std/thread.sa", &.{"pthread_spawn"});
                if (call.associated_target) |target_name| {
                    if (self.findStdSurfaceRule(.associated, target_name, call.func_name)) |rule| try self.ensureRuleDeps(rule);
                } else if (call.args.len > 0) {
                    if (std.mem.eql(u8, call.func_name, "join")) {
                        if (self.tc.expr_types.get(call.args[0])) |receiver_ty| {
                            if (joinHandleInnerType(receiver_ty) != null) {
                                try self.ensureStdDeps("sa_std/thread.sa", &.{ "pthread_join", "pthread_drop" });
                            }
                        }
                    }
                    if (self.tc.expr_types.get(call.args[0])) |receiver_ty| {
                        if (typeBaseName(receiver_ty)) |receiver_type_name| {
                            if (self.findStdSurfaceRule(.function, receiver_type_name, call.func_name)) |rule| try self.ensureRuleDeps(rule);
                            if (self.findStdSurfaceRule(.method, receiver_type_name, call.func_name)) |rule| try self.ensureRuleDeps(rule);
                            if (self.findStdSurfaceRule(.fallible_method, receiver_type_name, call.func_name)) |rule| try self.ensureRuleDeps(rule);
                        }
                    }
                }
                if (self.tc.expr_types.get(node)) |expr_ty| {
                    if (typeBaseName(expr_ty)) |type_name| {
                        if (self.findStdSurfaceRule(.constructor, type_name, call.func_name)) |rule| try self.ensureRuleDeps(rule);
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
            .if_expr => |ife| {
                try self.preloadNodeStdSurfaceDeps(ife.cond);
                if (ife.let_chain) |chain| {
                    for (chain) |cond| try self.preloadNodeStdSurfaceDeps(cond.value);
                }
                try self.preloadBlockStdSurfaceDeps(ife.then_block);
                if (ife.else_block) |else_block| try self.preloadBlockStdSurfaceDeps(else_block);
            },
            .while_stmt => |w| {
                try self.preloadNodeStdSurfaceDeps(w.cond);
                try self.preloadBlockStdSurfaceDeps(w.body);
            },
            .for_stmt => |f| {
                try self.preloadNodeStdSurfaceDeps(f.start);
                if (f.end) |end| try self.preloadNodeStdSurfaceDeps(end);
                try self.preloadBlockStdSurfaceDeps(f.body);
            },
            else => {},
        }
    }

    fn exprHasFnPtrType(self: *Codegen, expr: *const ast.Node) bool {
        const ty = self.tc.expr_types.get(expr) orelse return false;
        return ty.* == .fn_ptr;
    }

    fn isVoidType(ty: *const ast.Type) bool {
        return ty.* == .primitive and ty.primitive == .void_type;
    }

    fn isFloatType(ty: *const ast.Type) bool {
        return ty.* == .primitive and switch (ty.primitive) {
            .f32, .f64, .float => true,
            else => false,
        };
    }

    fn isIntegerPrimType(ty: sig.PrimType) bool {
        return switch (ty) {
            .i1, .i8, .i16, .i32, .i64, .u8, .u16, .u32, .u64 => true,
            else => false,
        };
    }

    fn isSignedPrimType(ty: sig.PrimType) bool {
        return switch (ty) {
            .i8, .i16, .i32, .i64 => true,
            else => false,
        };
    }

    fn isFloatPrimType(ty: sig.PrimType) bool {
        return switch (ty) {
            .f32, .f64 => true,
            else => false,
        };
    }

    fn isNumericType(ty: *const ast.Type) bool {
        return ty.* == .primitive and switch (ty.primitive) {
            .i8, .i16, .i32, .i64, .isize, .u8, .u16, .u32, .u64, .usize, .integer, .f32, .f64, .float => true,
            else => false,
        };
    }

    fn isStackAddressableType(ty: *const ast.Type) bool {
        return ty.* == .primitive and ty.primitive != .void_type;
    }

    fn stackAllocSize(call: ast.CallExpr) !usize {
        if (call.args.len > 0 and call.args[0].* == .literal and call.args[0].literal == .int_val) {
            const value = call.args[0].literal.int_val;
            if (value < 0) return Error.UnsupportedSabDirectFeature;
            return @intCast(value);
        }
        return 16;
    }

    fn opKindForCast(src_ty: sig.PrimType, dst_ty: sig.PrimType) !inst.OpKind {
        if (src_ty == dst_ty) return .bitcast;
        const src_bits = sig.primTypeBits(src_ty);
        const dst_bits = sig.primTypeBits(dst_ty);
        const src_int = isIntegerPrimType(src_ty);
        const dst_int = isIntegerPrimType(dst_ty);
        const src_float = isFloatPrimType(src_ty);
        const dst_float = isFloatPrimType(dst_ty);

        if (src_int and dst_int) {
            if (dst_bits < src_bits) return .trunc;
            if (dst_bits > src_bits) return if (isSignedPrimType(src_ty)) .sext else .zext;
            return .bitcast;
        }
        if (src_int and dst_float) return if (isSignedPrimType(src_ty)) .sitofp else .uitofp;
        if (src_float and dst_int) return .fptosi;
        if (src_float and dst_float) return if (dst_bits < src_bits) .fptrunc else .fpext;
        if (src_ty == .ptr and dst_ty == .ptr) return .bitcast;
        return Error.UnsupportedSabDirectFeature;
    }

    fn blockTailExpr(block: []const *ast.Node) ?*ast.Node {
        if (block.len == 0) return null;
        const last = block[block.len - 1];
        if (last.* != .expr_stmt) return null;
        return last.expr_stmt;
    }

    fn opKindForBinary(self: *Codegen, bin: ast.BinaryExpr) !inst.OpKind {
        const lhs_ty = self.tc.expr_types.get(bin.left);
        const rhs_ty = self.tc.expr_types.get(bin.right);
        const use_float = (lhs_ty != null and isFloatType(lhs_ty.?)) or (rhs_ty != null and isFloatType(rhs_ty.?));
        if (use_float) {
            return switch (bin.op) {
                .add => .fadd,
                .sub => .fsub,
                .mul => .fmul,
                .div => .fdiv,
                .eq => .fcmp_eq,
                .ne => .fcmp_ne,
                .lt => .fcmp_lt,
                .le => .fcmp_le,
                .gt => .fcmp_gt,
                .ge => .fcmp_ge,
                else => Error.UnsupportedSabDirectFeature,
            };
        }
        return switch (bin.op) {
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
            .logical_and => .@"and",
            .logical_or => .@"or",
            else => Error.UnsupportedSabDirectFeature,
        };
    }

    fn pushLocal(self: *Codegen, name: []const u8, reg: u32, is_param: bool) !void {
        try self.recordReg(reg);
        try self.locals.append(.{ .name = name, .reg = reg, .is_param = is_param });
    }

    fn pushTypedLocal(self: *Codegen, name: []const u8, reg: u32, is_param: bool, ty: *const ast.Type) !void {
        try self.recordReg(reg);
        try self.locals.append(.{ .name = name, .reg = reg, .is_param = is_param, .ty = ty });
    }

    fn pushParamLocal(self: *Codegen, name: []const u8, reg: u32, ty: *const ast.Type, cap: inst.CapPrefix) !void {
        try self.recordReg(reg);
        try self.locals.append(.{ .name = name, .reg = reg, .is_param = true, .ty = ty, .param_cap = cap });
    }

    fn pushRawParamLocal(self: *Codegen, name: []const u8, reg: u32, cap: inst.CapPrefix) !void {
        try self.recordReg(reg);
        try self.locals.append(.{ .name = name, .reg = reg, .is_param = true, .param_cap = cap });
    }

    fn pushStackLocal(self: *Codegen, name: []const u8, reg: u32, ty: *const ast.Type) !void {
        try self.recordReg(reg);
        try self.locals.append(.{ .name = name, .reg = reg, .is_param = false, .stack_ty = ty });
    }

    fn pushStackAllocLocal(self: *Codegen, name: []const u8, reg: u32) !void {
        try self.recordReg(reg);
        try self.locals.append(.{ .name = name, .reg = reg, .is_param = false, .is_stack_alloc = true });
    }

    fn beginFunction(self: *Codegen) void {
        self.current_reg_ids.clearRetainingCapacity();
        self.current_reg_seen.clearRetainingCapacity();
        self.released_regs.clearRetainingCapacity();
        self.closure_bindings.clearRetainingCapacity();
        self.closure_param_regs.clearRetainingCapacity();
        self.borrowed_bindings.clearRetainingCapacity();
    }

    fn collectBorrowedBindingsInBlock(self: *Codegen, body: []const *ast.Node) anyerror!void {
        for (body) |node| try self.collectBorrowedBindingsInNode(node);
    }

    fn collectBorrowedBindingsInNode(self: *Codegen, node: *const ast.Node) anyerror!void {
        switch (node.*) {
            .borrow_expr => |borrow| {
                if (borrow.expr.* == .identifier) try self.borrowed_bindings.put(borrow.expr.identifier, {});
                try self.collectBorrowedBindingsInNode(borrow.expr);
            },
            .move_expr => |move| try self.collectBorrowedBindingsInNode(move.expr),
            .deref_expr => |deref| try self.collectBorrowedBindingsInNode(deref.expr),
            .cast_expr => |cast| try self.collectBorrowedBindingsInNode(cast.expr),
            .binary_expr => |bin| {
                try self.collectBorrowedBindingsInNode(bin.left);
                try self.collectBorrowedBindingsInNode(bin.right);
            },
            .call_expr => |call| for (call.args) |arg| try self.collectBorrowedBindingsInNode(arg),
            .field_expr => |field| try self.collectBorrowedBindingsInNode(field.expr),
            .struct_literal => |lit| {
                for (lit.fields) |field| try self.collectBorrowedBindingsInNode(field.value);
                if (lit.update_expr) |update| try self.collectBorrowedBindingsInNode(update);
            },
            .tuple_literal => |lit| for (lit.elements) |elem| try self.collectBorrowedBindingsInNode(elem),
            .index_expr => |idx| {
                try self.collectBorrowedBindingsInNode(idx.target);
                try self.collectBorrowedBindingsInNode(idx.index);
            },
            .if_expr => |ife| {
                try self.collectBorrowedBindingsInNode(ife.cond);
                try self.collectBorrowedBindingsInBlock(ife.then_block);
                if (ife.else_block) |else_block| try self.collectBorrowedBindingsInBlock(else_block);
                if (ife.let_chain) |chain| for (chain) |cond| try self.collectBorrowedBindingsInNode(cond.value);
            },
            .while_stmt => |w| {
                try self.collectBorrowedBindingsInNode(w.cond);
                try self.collectBorrowedBindingsInBlock(w.body);
            },
            .let_stmt => |let| try self.collectBorrowedBindingsInNode(let.value),
            .let_destructure_stmt => |let| try self.collectBorrowedBindingsInNode(let.value),
            .assign_stmt => |assign| {
                try self.collectBorrowedBindingsInNode(assign.target);
                try self.collectBorrowedBindingsInNode(assign.value);
            },
            .expr_stmt => |expr| try self.collectBorrowedBindingsInNode(expr),
            .return_stmt => |ret| if (ret.value) |value| try self.collectBorrowedBindingsInNode(value),
            .block_stmt => |block| try self.collectBorrowedBindingsInBlock(block.body),
            else => {},
        }
    }

    fn recordReg(self: *Codegen, reg: u32) !void {
        _ = self.released_regs.remove(reg);
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
            if (local.is_param) {
                if (local.param_cap != .by_value) continue;
                const ty = local.ty orelse continue;
                if ((try primType(ty)) != .ptr) continue;
            }
            if (local.stack_ty != null) continue;
            if (local.is_stack_alloc) continue;
            if (except != null and local.reg == except.?) continue;
            if (self.released_regs.contains(local.reg)) continue;
            try self.emitRelease(local.reg);
        }
    }

    fn popLocalsTo(self: *Codegen, len: usize) void {
        self.locals.shrinkRetainingCapacity(len);
    }

    /// Rebuild `released_regs` to match a previously-cloned snapshot. Used to
    /// scope per-branch release state so a release emitted inside one `if`
    /// branch (typically along an early-return path) does not poison the
    /// sibling branch or the merge path. This mirrors the SA-text emitter,
    /// where release placement is branch-scoped via the type checker's
    /// per-node cleanup lists.
    fn restoreReleased(self: *Codegen, snapshot: *const std.AutoHashMap(u32, void)) !void {
        self.released_regs.clearRetainingCapacity();
        var it = snapshot.iterator();
        while (it.next()) |entry| try self.released_regs.put(entry.key_ptr.*, {});
    }

    /// Compute the release state at an `if` merge point and install it as the
    /// current `released_regs`. The merge is reachable only from the branches
    /// that fall through (do not terminate via return/panic/jmp-out). A
    /// register is considered released at the merge iff it is released on every
    /// reachable incoming path: the intersection of the fall-through
    /// branches' release sets. If both branches terminate, the merge is dead
    /// and we fall back to the pre-`if` state. This keeps the function-end
    /// `releaseOpenLocals` from either double-releasing a register that both
    /// branches already released or leaking one that only a single branch did.
    fn setMergeReleased(
        self: *Codegen,
        then_terminated: bool,
        then_released: *const std.AutoHashMap(u32, void),
        else_terminated: bool,
        else_released: *const std.AutoHashMap(u32, void),
        pre_released: *const std.AutoHashMap(u32, void),
    ) !void {
        if (then_terminated and else_terminated) {
            // Merge is unreachable; state is irrelevant but keep it well-formed.
            try self.restoreReleased(pre_released);
            return;
        }
        if (then_terminated) {
            try self.restoreReleased(else_released);
            return;
        }
        if (else_terminated) {
            try self.restoreReleased(then_released);
            return;
        }
        // Both branches fall through: intersection of the two release sets.
        self.released_regs.clearRetainingCapacity();
        var it = then_released.iterator();
        while (it.next()) |entry| {
            const reg = entry.key_ptr.*;
            if (else_released.contains(reg)) try self.released_regs.put(reg, {});
        }
    }

    fn closureLiteralFromExpr(expr: *const ast.Node) ?*const ast.ClosureLiteral {
        return switch (expr.*) {
            .closure_literal => |*lit| lit,
            .move_expr => |mv| closureLiteralFromExpr(mv.expr),
            else => null,
        };
    }

    fn joinHandleInnerType(ty: *const ast.Type) ?*const ast.Type {
        var curr = ty;
        while (true) {
            switch (curr.*) {
                .pointer => |p| curr = p,
                .borrow => |b| curr = b,
                .user_defined => |ud| {
                    if (std.mem.eql(u8, ud.name, "JoinHandle") and ud.generics.len == 1) return ud.generics[0];
                    return null;
                },
                else => return null,
            }
        }
    }

    fn addEscapedCapture(
        self: *Codegen,
        name: []const u8,
        ty: ?*const ast.Type,
        captures: *EscapedCaptureCollector,
        locals: *const std.StringHashMap(void),
    ) !void {
        if (locals.contains(name)) return;
        if (self.tc.funcs.contains(name)) return;
        if (self.tc.macros.contains(name)) return;
        if (std.mem.eql(u8, name, "return_ty_sentinel")) return;
        if (captures.seen.contains(name)) return;
        const capture_ty = ty orelse self.localType(name) orelse return Error.MissingType;
        const offset = 16 + captures.ordered.items.len * 8;
        try captures.ordered.append(.{ .name = name, .offset = offset, .ty = capture_ty });
        try captures.seen.put(name, {});
    }

    fn collectEscapedCapturesInBlock(
        self: *Codegen,
        block: []const *ast.Node,
        captures: *EscapedCaptureCollector,
        locals: *std.StringHashMap(void),
    ) anyerror!void {
        for (block) |stmt| {
            switch (stmt.*) {
                .let_stmt => |let| {
                    try self.collectEscapedCapturesInExpr(let.value, captures, locals);
                    try locals.put(let.name, {});
                },
                .let_destructure_stmt => |let| {
                    try self.collectEscapedCapturesInExpr(let.value, captures, locals);
                    for (let.names) |name| try locals.put(name, {});
                },
                .var_stmt => |v| try locals.put(v.name, {}),
                .const_stmt => |c| {
                    try self.collectEscapedCapturesInExpr(c.value, captures, locals);
                    try locals.put(c.name, {});
                },
                .assign_stmt => |assign| {
                    try self.collectEscapedCapturesInExpr(assign.target, captures, locals);
                    try self.collectEscapedCapturesInExpr(assign.value, captures, locals);
                },
                .block_stmt => |blk| {
                    var child = try locals.clone();
                    defer child.deinit();
                    try self.collectEscapedCapturesInBlock(blk.body, captures, &child);
                },
                .expr_stmt => |expr| try self.collectEscapedCapturesInExpr(expr, captures, locals),
                .return_stmt => |ret| if (ret.value) |value| try self.collectEscapedCapturesInExpr(value, captures, locals),
                .for_stmt => |f| {
                    try self.collectEscapedCapturesInExpr(f.start, captures, locals);
                    if (f.end) |end_expr| try self.collectEscapedCapturesInExpr(end_expr, captures, locals);
                    var child = try locals.clone();
                    defer child.deinit();
                    try child.put(f.var_name, {});
                    try self.collectEscapedCapturesInBlock(f.body, captures, &child);
                },
                .while_stmt => |w| {
                    try self.collectEscapedCapturesInExpr(w.cond, captures, locals);
                    var child = try locals.clone();
                    defer child.deinit();
                    try self.collectEscapedCapturesInBlock(w.body, captures, &child);
                },
                else => {},
            }
        }
    }

    fn collectEscapedCapturesInExpr(
        self: *Codegen,
        expr: *const ast.Node,
        captures: *EscapedCaptureCollector,
        locals: *std.StringHashMap(void),
    ) anyerror!void {
        switch (expr.*) {
            .identifier => |name| try self.addEscapedCapture(name, self.tc.expr_types.get(expr), captures, locals),
            .binary_expr => |bin| {
                try self.collectEscapedCapturesInExpr(bin.left, captures, locals);
                try self.collectEscapedCapturesInExpr(bin.right, captures, locals);
            },
            .borrow_expr => |borrow| try self.collectEscapedCapturesInExpr(borrow.expr, captures, locals),
            .move_expr => |mv| try self.collectEscapedCapturesInExpr(mv.expr, captures, locals),
            .deref_expr => |deref| try self.collectEscapedCapturesInExpr(deref.expr, captures, locals),
            .cast_expr => |cast| try self.collectEscapedCapturesInExpr(cast.expr, captures, locals),
            .field_expr => |field| try self.collectEscapedCapturesInExpr(field.expr, captures, locals),
            .call_expr => |call| {
                if (call.associated_target == null) {
                    try self.addEscapedCapture(call.func_name, self.localType(call.func_name), captures, locals);
                }
                for (call.args) |arg| try self.collectEscapedCapturesInExpr(arg, captures, locals);
            },
            .struct_literal => |lit| {
                for (lit.fields) |field| try self.collectEscapedCapturesInExpr(field.value, captures, locals);
                if (lit.update_expr) |update| try self.collectEscapedCapturesInExpr(update, captures, locals);
            },
            .tuple_literal => |lit| for (lit.elements) |elem| try self.collectEscapedCapturesInExpr(elem, captures, locals),
            .array_literal => |lit| for (lit.elements) |elem| try self.collectEscapedCapturesInExpr(elem, captures, locals),
            .repeat_array_literal => |lit| try self.collectEscapedCapturesInExpr(lit.value, captures, locals),
            .index_expr => |idx| {
                try self.collectEscapedCapturesInExpr(idx.target, captures, locals);
                try self.collectEscapedCapturesInExpr(idx.index, captures, locals);
            },
            .if_expr => |ife| {
                try self.collectEscapedCapturesInExpr(ife.cond, captures, locals);
                var then_locals = try locals.clone();
                defer then_locals.deinit();
                try self.collectEscapedCapturesInBlock(ife.then_block, captures, &then_locals);
                if (ife.else_block) |else_block| {
                    var else_locals = try locals.clone();
                    defer else_locals.deinit();
                    try self.collectEscapedCapturesInBlock(else_block, captures, &else_locals);
                }
            },
            .closure_literal => {},
            else => {},
        }
    }

    fn collectEscapedClosureCaptures(self: *Codegen, closure: *const ast.ClosureLiteral) ![]const EscapedCapture {
        var locals = std.StringHashMap(void).init(self.allocator);
        defer locals.deinit();
        for (closure.params) |param| try locals.put(param.name, {});

        var collector = EscapedCaptureCollector{
            .ordered = std.ArrayList(EscapedCapture).init(self.allocator),
            .seen = std.StringHashMap(void).init(self.allocator),
        };
        defer collector.seen.deinit();
        errdefer collector.ordered.deinit();

        try self.collectEscapedCapturesInExpr(closure.body, &collector, &locals);
        return try collector.ordered.toOwnedSlice();
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

    fn localType(self: *Codegen, name: []const u8) ?*const ast.Type {
        var i = self.locals.items.len;
        while (i > 0) {
            i -= 1;
            const local = self.locals.items[i];
            if (std.mem.eql(u8, local.name, name)) return local.ty orelse local.stack_ty;
        }
        return null;
    }

    fn stackLocal(self: *Codegen, name: []const u8) ?Local {
        var i = self.locals.items.len;
        while (i > 0) {
            i -= 1;
            const local = self.locals.items[i];
            if (std.mem.eql(u8, local.name, name) and local.stack_ty != null) return local;
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

    fn markConsumed(self: *Codegen, reg: u32) !void {
        try self.released_regs.put(reg, {});
    }

    fn emitBranchRelease(self: *Codegen, reg: u32) !void {
        var item = self.makeInst(.release);
        item.operands[0] = .{ .reg = reg };
        try self.appendInst(item);
    }

    fn emitAssignImm(self: *Codegen, dst: u32, value: i64) !void {
        try self.recordReg(dst);
        var item = self.makeInst(.assign);
        item.operands[0] = .{ .reg = dst };
        item.operands[1] = .{ .imm_i64 = value };
        try self.appendInst(item);
    }

    fn emitPanicCode(self: *Codegen, code: i64) !void {
        var item = self.makeInst(.panic);
        item.operands[0] = .{ .text = try std.fmt.allocPrint(self.allocator, "{}", .{code}) };
        try self.appendInst(item);
    }

    fn emitAssignFloat(self: *Codegen, dst: u32, value: f64) !void {
        try self.recordReg(dst);
        var item = self.makeInst(.assign);
        item.operands[0] = .{ .reg = dst };
        item.operands[1] = .{ .imm_float = value };
        try self.appendInst(item);
    }

    fn emitAssignReg(self: *Codegen, dst: u32, src: u32) !void {
        if (dst == src) return;
        try self.recordReg(dst);
        var item = self.makeInst(.assign);
        item.operands[0] = .{ .reg = dst };
        item.operands[1] = .{ .reg = src };
        try self.appendInst(item);
    }

    fn emitOp(self: *Codegen, dst: u32, op: inst.OpKind, lhs: inst.Operand, rhs: inst.Operand) !void {
        try self.recordReg(dst);
        var item = self.makeInst(.op);
        item.op_kind = op;
        item.operands[0] = .{ .reg = dst };
        item.operands[1] = lhs;
        item.operands[2] = rhs;
        try self.appendInst(item);
    }

    fn emitPtrAdd(self: *Codegen, dst: u32, base: u32, offset: inst.Operand) !void {
        try self.recordReg(dst);
        var item = self.makeInst(.ptr_add);
        item.operands[0] = .{ .reg = dst };
        item.operands[1] = .{ .reg = base };
        item.operands[2] = offset;
        try self.appendInst(item);
    }

    fn emitAlloc(self: *Codegen, dst: u32, size: usize) !void {
        try self.recordReg(dst);
        var item = self.makeInst(.alloc);
        item.operands[0] = .{ .reg = dst };
        item.operands[1] = .{ .imm_u64 = @intCast(size) };
        try self.appendInst(item);
    }

    fn emitStackAlloc(self: *Codegen, dst: u32, size: usize) !void {
        try self.recordReg(dst);
        var item = self.makeInst(.stack_alloc);
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

    fn genArrayElementPtr(self: *Codegen, arr: ast.ArrayType, target_reg: u32, index_reg: u32) !struct { ptr: u32, offset: ?u32 } {
        const stride = arrayStride(arr.elem);
        const elem_ptr = try self.intern(try self.newTmp());
        if (stride == 1) {
            try self.emitPtrAdd(elem_ptr, target_reg, .{ .reg = index_reg });
            return .{ .ptr = elem_ptr, .offset = null };
        }

        const offset = try self.intern(try self.newTmp());
        try self.emitOp(offset, .mul, .{ .reg = index_reg }, .{ .imm_i64 = @intCast(stride) });
        try self.emitPtrAdd(elem_ptr, target_reg, .{ .reg = offset });
        return .{ .ptr = elem_ptr, .offset = offset };
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

    fn stdMacroPlaceholder(self: *Codegen, index: usize) ![]const u8 {
        return try std.fmt.allocPrint(self.allocator, "__sla_macro_arg_{}", .{index});
    }

    fn replaceStdMacroPlaceholders(self: *Codegen, text: []const u8, args: []const []const u8) ![]const u8 {
        if (std.mem.indexOf(u8, text, "__sla_macro_arg_") == null) {
            return try self.allocator.dupe(u8, text);
        }
        var current = try self.allocator.dupe(u8, text);
        for (args, 0..) |arg, idx| {
            const placeholder = try std.fmt.allocPrint(self.allocator, "__sla_macro_arg_{}", .{idx});
            defer self.allocator.free(placeholder);
            if (std.mem.indexOf(u8, current, placeholder) == null) continue;
            const next = try std.mem.replaceOwned(u8, self.allocator, current, placeholder, arg);
            self.allocator.free(current);
            current = next;
        }
        return current;
    }

    fn remapTemplateSymbol(self: *Codegen, symbols: []const []const u8, old_id: u32, args: []const []const u8) !u32 {
        const idx: usize = @intCast(old_id);
        if (idx >= symbols.len) return Error.UnsupportedSabDirectFeature;
        const name = try self.replaceStdMacroPlaceholders(symbols[idx], args);
        defer self.allocator.free(name);
        return try self.internStable(name);
    }

    fn templateSymbolArgIndex(symbols: []const []const u8, old_id: u32) ?usize {
        const idx: usize = @intCast(old_id);
        if (idx >= symbols.len) return null;
        const name = symbols[idx];
        const prefix = "__sla_macro_arg_";
        if (name.len <= prefix.len) return null;
        if (!std.mem.startsWith(u8, name, prefix)) return null;
        return std.fmt.parseInt(usize, name[prefix.len..], 10) catch null;
    }

    fn stdMacroTemplateIntegerOperand(arg: []const u8) !inst.Operand {
        return .{ .imm_i64 = try std.fmt.parseInt(i64, arg, 10) };
    }

    fn remapTemplateOperand(self: *Codegen, symbols: []const []const u8, operand: inst.Operand, args: []const []const u8) !inst.Operand {
        return switch (operand) {
            .reg => |old_id| {
                if (templateSymbolArgIndex(symbols, old_id)) |arg_idx| {
                    if (arg_idx < args.len and isStdMacroTemplateIntegerArg(args[arg_idx])) {
                        return try stdMacroTemplateIntegerOperand(args[arg_idx]);
                    }
                }
                return .{ .reg = try self.remapTemplateSymbol(symbols, old_id, args) };
            },
            .symbol => |old_id| {
                if (templateSymbolArgIndex(symbols, old_id)) |arg_idx| {
                    if (arg_idx < args.len and isStdMacroTemplateIntegerArg(args[arg_idx])) {
                        return try stdMacroTemplateIntegerOperand(args[arg_idx]);
                    }
                }
                return .{ .symbol = try self.remapTemplateSymbol(symbols, old_id, args) };
            },
            .label => |old_id| .{ .label = try self.remapTemplateSymbol(symbols, old_id, args) },
            .func => |old_id| .{ .func = try self.remapTemplateSymbol(symbols, old_id, args) },
            .text => |text| .{ .text = try self.replaceStdMacroPlaceholders(text, args) },
            .native_text => |text| .{ .native_text = try self.replaceStdMacroPlaceholders(text, args) },
            else => operand,
        };
    }

    fn cloneTemplateTextList(self: *Codegen, items: []const []const u8, args: []const []const u8) ![]const []const u8 {
        if (items.len == 0) return &.{};
        const out = try self.allocator.alloc([]const u8, items.len);
        for (items, 0..) |item, idx| out[idx] = try self.replaceStdMacroPlaceholders(item, args);
        return out;
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
        if (out.kind == .panic_msg and out.operands[0] == .text) {
            if (try self.structuredPanicMsgOperands(out.operands[0].text)) |ops| {
                out.operands[0] = ops[0];
                out.operands[1] = ops[1];
                out.operands[2] = ops[2];
            }
        }
        return out;
    }

    fn cloneTemplateInstruction(self: *Codegen, symbols: []const []const u8, source: inst.Instruction, args: []const []const u8) !inst.Instruction {
        var out = source;
        out.package_identity = try self.cloneOptionalText(source.package_identity);
        out.upstream_loc = try self.cloneUpstreamLoc(source.upstream_loc);
        out.raw_text = "";
        out.atomic_expected_text = if (source.atomic_expected_text) |text| try self.replaceStdMacroPlaceholders(text, args) else null;
        out.atomic_new_text = if (source.atomic_new_text) |text| try self.replaceStdMacroPlaceholders(text, args) else null;
        out.native_reg_names = try self.cloneTemplateTextList(source.native_reg_names, args);
        for (&out.operands) |*operand| operand.* = try self.remapTemplateOperand(symbols, operand.*, args);
        if (out.kind == .panic_msg and out.operands[0] == .text) {
            if (try self.structuredPanicMsgOperands(out.operands[0].text)) |ops| {
                out.operands[0] = ops[0];
                out.operands[1] = ops[1];
                out.operands[2] = ops[2];
            }
        }
        return out;
    }

    fn structuredPanicMsgOperands(self: *Codegen, text: []const u8) !?[3]inst.Operand {
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        if (trimmed.len < 2 or trimmed[0] != '(' or trimmed[trimmed.len - 1] != ')') return null;
        const inner = trimmed[1 .. trimmed.len - 1];
        var parts = std.mem.splitScalar(u8, inner, ',');
        const code_text = std.mem.trim(u8, parts.next() orelse return null, " \t\r\n");
        const msg_text = std.mem.trim(u8, parts.next() orelse return null, " \t\r\n");
        const len_text = std.mem.trim(u8, parts.next() orelse return null, " \t\r\n");
        if (parts.next() != null) return null;

        return .{
            .{ .native_text = try self.allocator.dupe(u8, code_text) },
            .{ .native_text = try self.allocator.dupe(u8, msg_text) },
            .{ .native_text = try self.allocator.dupe(u8, len_text) },
        };
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

    fn hasConstDecl(self: *Codegen, name: []const u8) bool {
        for (self.const_decls.items) |decl| {
            if (std.mem.eql(u8, decl.name, name)) return true;
        }
        return false;
    }

    fn appendDecodedModuleConstDecls(self: *Codegen, module: sab.Module) !void {
        for (module.symbols) |name| _ = try self.internStable(name);
        for (module.const_decls) |decl| {
            const const_id = try self.internStable(decl.name);
            try self.recordReg(const_id);
            if (self.hasConstDecl(decl.name)) continue;
            var cloned = try self.cloneModuleConstDecl(decl);
            cloned.source_line = 0;
            cloned.expanded_line = 0;
            try self.const_decls.append(cloned);
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

    fn appendDecodedTemplateFunctionBody(self: *Codegen, module: sab.Module, func_name: []const u8, args: []const []const u8) !void {
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
            const cloned = try self.cloneTemplateInstruction(module.symbols, source, args);
            try self.recordInstructionRegs(cloned);
            try self.instructions.append(cloned);
        }
    }

    fn cachedStdImportModule(self: *Codegen, import_path: []const u8) !*const sab.Module {
        if (self.std_import_module_ids.get(import_path)) |idx| return &self.std_import_modules.items[idx].module;

        const source = try std.fmt.allocPrint(self.allocator, "@import \"{s}\"\n", .{import_path});
        defer self.allocator.free(source);
        var flat = try self.flattenStdSnippet(source);
        defer flat.deinit(self.allocator);
        const bytes = sci_bridge.encodeSabFromFlat(self.allocator, &flat) catch |err| {
            std.debug.print("SAB std import fragment failed for {s}: {}\n", .{ import_path, err });
            return err;
        };
        defer self.allocator.free(bytes);

        const owned_import_path = try self.allocator.dupe(u8, import_path);
        errdefer self.allocator.free(owned_import_path);
        var module = try sab.decodeModule(self.allocator, bytes);
        errdefer module.deinit(self.allocator);

        const idx = self.std_import_modules.items.len;
        try self.std_import_module_ids.put(owned_import_path, idx);
        errdefer _ = self.std_import_module_ids.remove(owned_import_path);
        try self.std_import_modules.append(.{
            .import_path = owned_import_path,
            .module = module,
        });
        return &self.std_import_modules.items[idx].module;
    }

    fn ensureStdDeps(self: *Codegen, import_path: []const u8, deps: []const []const u8) !void {
        if (deps.len == 0) return;
        var missing = std.ArrayList([]const u8).init(self.allocator);
        defer missing.deinit();
        for (deps) |dep| {
            if (!self.included_imports.contains(dep)) try missing.append(dep);
        }
        if (missing.items.len == 0) return;

        const module = try self.cachedStdImportModule(import_path);
        try self.appendDecodedModuleFiltered(module.*, missing.items);
        for (missing.items) |dep| try self.included_imports.put(try self.allocator.dupe(u8, dep), {});
    }

    fn isStdMacroTemplateArgSafe(arg: []const u8) bool {
        if (arg.len == 0) return false;
        if (isStdMacroTemplateIntegerArg(arg)) return true;
        for (arg, 0..) |ch, idx| {
            const is_alpha = (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or ch == '_';
            const is_digit = ch >= '0' and ch <= '9';
            if (idx == 0) {
                if (!is_alpha) return false;
            } else if (!is_alpha and !is_digit) return false;
        }
        return true;
    }

    fn isStdMacroTemplateIntegerArg(arg: []const u8) bool {
        if (arg.len == 0) return false;
        var start: usize = 0;
        if (arg[0] == '-') {
            if (arg.len == 1) return false;
            start = 1;
        }
        for (arg[start..]) |ch| {
            if (ch < '0' or ch > '9') return false;
        }
        return true;
    }

    fn isStdMacroTemplateIdentArg(arg: []const u8) bool {
        if (arg.len == 0) return false;
        for (arg, 0..) |ch, idx| {
            const is_alpha = (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or ch == '_';
            const is_digit = ch >= '0' and ch <= '9';
            if (idx == 0) {
                if (!is_alpha) return false;
            } else if (!is_alpha and !is_digit) return false;
        }
        return true;
    }

    fn stdMacroTemplateArgsSafe(args: []const []const u8) bool {
        for (args) |arg| {
            if (!isStdMacroTemplateArgSafe(arg)) return false;
        }
        return true;
    }

    fn stdMacroTemplateKey(self: *Codegen, import_path: []const u8, macro_name: []const u8, arg_count: usize) ![]const u8 {
        return try std.fmt.allocPrint(self.allocator, "{s}\x1f{s}\x1f{}", .{ import_path, macro_name, arg_count });
    }

    fn cachedStdMacroTemplate(self: *Codegen, import_path: []const u8, macro_name: []const u8, arg_count: usize) !*const StdMacroTemplate {
        const lookup_key = try self.stdMacroTemplateKey(import_path, macro_name, arg_count);
        defer self.allocator.free(lookup_key);
        if (self.std_macro_template_ids.get(lookup_key)) |idx| return &self.std_macro_templates.items[idx];

        const owned_key = try self.stdMacroTemplateKey(import_path, macro_name, arg_count);
        errdefer self.allocator.free(owned_key);
        const func_name = try std.fmt.allocPrint(self.allocator, "__sla_macro_template_{}", .{self.std_macro_templates.items.len});
        errdefer self.allocator.free(func_name);

        var source = std.ArrayList(u8).init(self.allocator);
        defer source.deinit();
        try source.writer().print("@import \"{s}\"\n@{s}() -> void:\nL_ENTRY:\n    EXPAND {s}", .{ import_path, func_name, macro_name });
        for (0..arg_count) |idx| {
            const placeholder = try self.stdMacroPlaceholder(idx);
            defer self.allocator.free(placeholder);
            if (idx == 0) {
                try source.writer().print(" {s}", .{placeholder});
            } else {
                try source.writer().print(", {s}", .{placeholder});
            }
        }
        try source.appendSlice("\n    return\n");

        var flat = try self.flattenStdSnippet(source.items);
        defer flat.deinit(self.allocator);
        const bytes = try sci_bridge.encodeSabFromFlatUnchecked(self.allocator, &flat);
        defer self.allocator.free(bytes);
        var module = try sab.decodeModule(self.allocator, bytes);
        errdefer module.deinit(self.allocator);

        const idx = self.std_macro_templates.items.len;
        try self.std_macro_template_ids.put(owned_key, idx);
        errdefer _ = self.std_macro_template_ids.remove(owned_key);
        try self.std_macro_templates.append(.{
            .key = owned_key,
            .func_name = func_name,
            .arg_count = arg_count,
            .module = module,
        });
        return &self.std_macro_templates.items[idx];
    }

    fn templateFunctionBodyBounds(template: *const StdMacroTemplate, func_name: []const u8) ?struct { start: usize, end: usize } {
        var start: ?usize = null;
        var end: usize = template.module.instructions.len;
        for (template.module.function_sigs, 0..) |fsig, idx| {
            if (std.mem.eql(u8, fsig.name, func_name)) {
                start = fsig.entry_inst_idx;
                if (idx + 1 < template.module.function_sigs.len) end = template.module.function_sigs[idx + 1].entry_inst_idx;
                break;
            }
        }
        if (start == null) return null;
        return .{ .start = start.?, .end = end };
    }

    fn stdMacroTemplateSupportsArgs(self: *Codegen, template: *const StdMacroTemplate, args: []const []const u8) !bool {
        for (args, 0..) |arg, idx| {
            if (isStdMacroTemplateIdentArg(arg)) continue;
            if (isStdMacroTemplateIntegerArg(arg)) continue;
            const placeholder = try self.stdMacroPlaceholder(idx);
            defer self.allocator.free(placeholder);
            const bounds = templateFunctionBodyBounds(template, template.func_name) orelse return false;
            var i = bounds.start;
            while (i < bounds.end) : (i += 1) {
                const source = template.module.instructions[i];
                if (i == bounds.start and (source.kind == .func_decl or source.kind == .test_decl)) continue;
                if (i == bounds.start + 1 and source.kind == .label) continue;
                if (i + 1 == bounds.end and source.kind == .return_) continue;
                if (source.atomic_expected_text) |text| {
                    if (std.mem.indexOf(u8, text, placeholder) != null) return false;
                }
                if (source.atomic_new_text) |text| {
                    if (std.mem.indexOf(u8, text, placeholder) != null) return false;
                }
                for (source.native_reg_names) |text| {
                    if (std.mem.indexOf(u8, text, placeholder) != null) return false;
                }
            }
        }
        return true;
    }

    fn emitCachedStdMacroFragment(self: *Codegen, import_path: []const u8, macro_name: []const u8, args: []const []const u8) !bool {
        if (!stdMacroTemplateArgsSafe(args)) return false;
        const template = try self.cachedStdMacroTemplate(import_path, macro_name, args.len);
        if (template.arg_count != args.len) return Error.UnsupportedSabDirectFeature;
        if (!try self.stdMacroTemplateSupportsArgs(template, args)) return false;
        try self.appendDecodedModuleConstDecls(template.module);
        try self.appendDecodedTemplateFunctionBody(template.module, template.func_name, args);
        return true;
    }

    fn emitStdMacroFragment(self: *Codegen, import_path: []const u8, macro_name: []const u8, args: []const []const u8) !void {
        const used_cached = self.emitCachedStdMacroFragment(import_path, macro_name, args) catch |err| switch (err) {
            error.UnsupportedType => false,
            else => return err,
        };
        if (used_cached) return;

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
        try self.appendDecodedModuleConstDecls(module);
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

    fn emitRawCast(self: *Codegen, dst: u32, source: u32) !void {
        try self.recordReg(dst);
        var item = self.makeInst(.raw_cast);
        item.operands[0] = .{ .reg = dst };
        item.operands[1] = .{ .reg = source };
        try self.appendInst(item);
    }

    fn emitAssumeSafe(self: *Codegen, dst: u32, source: u32) !void {
        try self.recordReg(dst);
        var item = self.makeInst(.assume_safe);
        item.operands[0] = .{ .reg = dst };
        item.operands[1] = .{ .reg = source };
        try self.appendInst(item);
    }

    fn emitCallBody(self: *Codegen, dst: ?u32, body: []const u8) !void {
        var item = self.makeInst(.call);
        if (dst) |reg| {
            try self.recordReg(reg);
            item.operands[0] = .{ .reg = reg };
            item.operands[1] = .{ .text = body };
        } else {
            item.operands[0] = .{ .text = body };
        }
        try self.appendInst(item);
    }

    fn appendGeneratedFuncSig(
        self: *Codegen,
        name: []const u8,
        kind: sig.FunctionKind,
        params: []const sig.ParamSpec,
        param_ids: []const u32,
        return_ty: sig.PrimType,
        is_ffi_wrapper: bool,
    ) !sig.FunctionSig {
        _ = try self.intern(name);
        return .{
            .id = @intCast(self.function_sigs.items.len + self.test_sigs.items.len),
            .name = name,
            .params = params,
            .kind = kind,
            .return_cap = null,
            .return_ty = return_ty,
            .entry_inst_idx = @intCast(self.instructions.items.len),
            .is_ffi_wrapper = is_ffi_wrapper,
            .param_ids = param_ids,
            .reg_ids = &.{},
            .llvm_name = null,
            .ignored = false,
            .should_panic = false,
        };
    }

    fn oneGeneratedParam(self: *Codegen, name: []const u8, cap: inst.CapPrefix) !struct { specs: []const sig.ParamSpec, ids: []const u32, id: u32 } {
        const param_id = try self.intern(name);
        const specs = try self.allocator.alloc(sig.ParamSpec, 1);
        const ids = try self.allocator.alloc(u32, 1);
        specs[0] = .{ .name = name, .ty = .ptr, .cap = cap };
        ids[0] = param_id;
        return .{ .specs = specs, .ids = ids, .id = param_id };
    }

    fn emitEscapedSpawnWrapper(self: *Codegen, entry: EscapedClosureEntry) !void {
        const old_locals = self.locals.items.len;
        defer self.popLocalsTo(old_locals);
        self.beginFunction();

        const param = try self.oneGeneratedParam("slot", .raw);
        try self.pushRawParamLocal("slot", param.id, .raw);
        var fsig = try self.appendGeneratedFuncSig(entry.spawn_name, .ffi_wrapper, param.specs, param.ids, .i32, true);
        try self.appendDeclInst(fsig);
        try self.emitLabel("L_ENTRY");

        const worker_vt = try self.intern(try self.newTmp());
        const worker_fn = try self.intern(try self.newTmp());
        const worker_raw = try self.intern(try self.newTmp());
        const worker_safe = try self.intern(try self.newTmp());
        try self.emitBorrowSymbol(worker_vt, entry.vtable_name);
        try self.emitLoad(worker_fn, worker_vt, 0, .ptr);
        try self.emitRawCast(worker_raw, worker_fn);
        try self.emitAssumeSafe(worker_safe, worker_raw);

        const handle = try self.intern(try self.newTmp());
        var args = std.ArrayList([]const u8).init(self.allocator);
        defer args.deinit();
        try args.append(self.symbols.items[handle]);
        try args.append(try std.fmt.allocPrint(self.allocator, "*{s}", .{self.symbols.items[worker_safe]}));
        try args.append(try std.fmt.allocPrint(self.allocator, "*{s}", .{self.symbols.items[param.id]}));
        try self.emitStdMacroFragment("sa_std/thread.sa", "THREAD_SPAWN", args.items);
        try self.emitRelease(worker_safe);
        try self.emitRelease(worker_fn);
        try self.emitRelease(worker_vt);
        try self.emitRelease(param.id);
        try self.emitReturn(handle);

        fsig.reg_ids = try self.finishFunctionRegs();
        try self.function_sigs.append(fsig);
    }

    fn emitEscapedWorker(self: *Codegen, entry: EscapedClosureEntry) !void {
        const old_locals = self.locals.items.len;
        defer self.popLocalsTo(old_locals);
        self.beginFunction();

        const param = try self.oneGeneratedParam("slot", .borrow);
        try self.pushRawParamLocal("slot", param.id, .borrow);
        var fsig = try self.appendGeneratedFuncSig(entry.worker_name, .normal, param.specs, param.ids, .i32, false);
        try self.appendDeclInst(fsig);
        try self.emitLabel("L_ENTRY");

        var capture_regs = std.ArrayList(u32).init(self.allocator);
        defer capture_regs.deinit();
        for (entry.captures) |capture| {
            const reg = try self.intern(try self.newTmp());
            try self.emitLoad(reg, param.id, capture.offset, .ptr);
            try self.pushTypedLocal(capture.name, reg, false, capture.ty);
            try capture_regs.append(reg);
        }

        const value = try self.genExpr(@constCast(entry.closure.body));
        try self.emitStore(param.id, 8, value, try primType(entry.ret_ty));
        for (capture_regs.items) |capture_reg| {
            if (capture_reg == value or self.released_regs.contains(capture_reg)) continue;
            try self.emitRelease(capture_reg);
        }
        if ((try primType(entry.ret_ty)) == .i32) {
            try self.emitRelease(param.id);
            try self.emitReturn(value);
        } else {
            if (!self.isLocalReg(value)) try self.emitRelease(value);
            try self.emitRelease(param.id);
            const zero = try self.intern(try self.newTmp());
            try self.emitAssignImm(zero, 0);
            try self.emitReturn(zero);
        }

        fsig.reg_ids = try self.finishFunctionRegs();
        try self.function_sigs.append(fsig);
    }

    fn emitEscapedClosureEntries(self: *Codegen) !void {
        if (self.escaped_closure_entries.count() == 0) return;
        var iter = self.escaped_closure_entries.valueIterator();
        while (iter.next()) |entry| {
            try self.emitEscapedSpawnWrapper(entry.*);
            try self.emitEscapedWorker(entry.*);
        }
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
            const cap: inst.CapPrefix = if (param.is_borrow) .borrow else if (param.is_move) .move else .by_value;
            specs[i] = .{
                .name = param.name,
                .ty = try primType(param.ty),
                .cap = cap,
            };
            param_ids[i] = param_id;
            try self.pushParamLocal(param.name, param_id, param.ty, cap);
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

    fn materializeBorrowedParams(self: *Codegen, params: []const ast.Param) !void {
        for (params) |param| {
            if (param.is_borrow or param.is_move) continue;
            if (!self.borrowed_bindings.contains(param.name)) continue;
            if (!isStackAddressableType(param.ty)) continue;
            const slot_name = try std.fmt.allocPrint(self.allocator, "{s}_slot", .{param.name});
            const slot = try self.intern(slot_name);
            const param_reg = self.localReg(param.name) orelse return Error.UnsupportedSabDirectFeature;
            try self.emitStackAlloc(slot, typeSize(param.ty));
            try self.emitStore(slot, 0, param_reg, try primType(param.ty));
            try self.pushStackLocal(param.name, slot, param.ty);
        }
    }

    fn genFuncDeclNamed(self: *Codegen, name: []const u8, f: *const ast.FuncDecl) !void {
        const old_locals = self.locals.items.len;
        defer self.popLocalsTo(old_locals);
        self.beginFunction();
        try self.collectBorrowedBindingsInBlock(f.body);
        var fsig = try self.genFuncSig(name, .normal, f.params, f.ret_ty, false, false);
        try self.appendDeclInst(fsig);
        try self.emitLabel("L_ENTRY");
        try self.materializeBorrowedParams(f.params);
        const ret_prim = try primType(f.ret_ty);
        if (ret_prim != .void and blockTailExpr(f.body) != null) {
            const tail = blockTailExpr(f.body).?;
            for (f.body[0 .. f.body.len - 1]) |stmt| {
                self.genStmt(stmt) catch |err| {
                    self.traceUnsupported("func {s} stmt {s} failed: {s}\n", .{ name, @tagName(stmt.*), @errorName(err) });
                    return err;
                };
                if (self.lastIsTerminator()) break;
            }
            if (!self.lastIsTerminator()) {
                const value = try self.genExpr(tail);
                if (!self.lastIsTerminator()) {
                    try self.releaseOpenLocals(value);
                    try self.emitReturn(value);
                }
            }
        } else {
            self.genBlock(f.body) catch |err| {
                self.traceUnsupported("func {s} block failed: {s}\n", .{ name, @errorName(err) });
                return err;
            };
        }
        if (ret_prim == .void and !self.lastIsTerminator()) {
            try self.releaseOpenLocals(null);
            try self.emitReturn(null);
        }
        fsig.reg_ids = try self.finishFunctionRegs();
        try self.function_sigs.append(fsig);
    }

    fn genFuncDecl(self: *Codegen, f: *const ast.FuncDecl) !void {
        try self.genFuncDeclNamed(f.name, f);
    }

    fn genImplDecl(self: *Codegen, impl_decl: *const ast.ImplDecl) !void {
        const impl_name = concreteTypeName(impl_decl.target_ty) orelse return Error.UnsupportedSabDirectFeature;
        for (impl_decl.methods) |method| {
            if (method.* != .func_decl) return Error.UnsupportedSabDirectFeature;
            const mangled = if (impl_decl.trait_name) |trait_name|
                try self.mangleTraitMethodName(impl_name, trait_name, method.func_decl.name)
            else
                try self.mangleMethodName(impl_name, method.func_decl.name);
            try self.genFuncDeclNamed(mangled, &method.func_decl);
        }
    }

    fn genOverloadDecl(self: *Codegen, overload_decl: *const ast.OverloadDecl) !void {
        const overload_name = concreteTypeName(overload_decl.target_ty) orelse return Error.UnsupportedSabDirectFeature;
        for (overload_decl.methods) |method| {
            if (method.* != .func_decl) return Error.UnsupportedSabDirectFeature;
            const mangled = try self.mangleMethodName(overload_name, method.func_decl.name);
            try self.genFuncDeclNamed(mangled, &method.func_decl);
        }
    }

    fn genTestDecl(self: *Codegen, t: *const ast.TestDecl) !void {
        const old_locals = self.locals.items.len;
        defer self.popLocalsTo(old_locals);
        self.beginFunction();
        try self.collectBorrowedBindingsInBlock(t.body);
        var fsig = try self.genFuncSig(t.name, .test_func, &.{}, self.voidType(), t.is_ignored, t.should_panic);
        try self.appendDeclInst(fsig);
        const label = try self.newLabel("L_TEST_ENTRY");
        try self.emitLabel(label);
        self.genBlock(t.body) catch |err| {
            self.traceUnsupported("test {s} block failed: {s}\n", .{ t.name, @errorName(err) });
            return err;
        };
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
            self.genStmt(stmt) catch |err| {
                self.traceUnsupported("stmt {s} failed: {s}\n", .{ @tagName(stmt.*), @errorName(err) });
                return err;
            };
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

    fn traceSabUnsupported(self: *Codegen) bool {
        const value = std.process.getEnvVarOwned(self.allocator, "SLA_SAB_TRACE_UNSUPPORTED") catch return false;
        defer self.allocator.free(value);
        return value.len != 0 and !std.mem.eql(u8, value, "0");
    }

    fn traceUnsupported(self: *Codegen, comptime fmt: []const u8, args: anytype) void {
        if (!self.traceSabUnsupported()) return;
        std.debug.print("[sab-direct] " ++ fmt, args);
    }

    fn literalFallbackType(self: *Codegen, expr: *const ast.Node) !?*ast.Type {
        if (expr.* != .literal) return null;
        const ty = try self.allocator.create(ast.Type);
        ty.* = .{ .primitive = switch (expr.literal) {
            .int_val => .integer,
            .float_val => .float,
            .bool_val => .boolean,
            else => return null,
        } };
        return ty;
    }

    fn exprTypeOrFallback(self: *Codegen, expr: *const ast.Node) !?*const ast.Type {
        if (self.tc.expr_types.get(expr)) |ty| return ty;
        if (try self.literalFallbackType(expr)) |ty| return ty;
        return null;
    }

    fn genLetFromValue(self: *Codegen, name: []const u8, explicit_ty: ?*const ast.Type, value_expr: *ast.Node, src: u32) anyerror!void {
        const dst = try self.intern(name);
        if (value_expr.* == .borrow_expr) {
            try self.pushLocal(name, src, false);
            return;
        }
        const let_ty = if (explicit_ty) |ty| ty else (try self.exprTypeOrFallback(value_expr)) orelse return Error.MissingType;
        if (self.borrowed_bindings.contains(name) and isStackAddressableType(let_ty)) {
            try self.emitStackAlloc(dst, typeSize(let_ty));
            try self.emitStore(dst, 0, src, try primType(let_ty));
            if (!self.isLocalReg(src)) try self.emitRelease(src);
            try self.pushStackLocal(name, dst, let_ty);
            return;
        }
        try self.emitAssignReg(dst, src);
        try self.pushTypedLocal(name, dst, false, let_ty);
    }

    fn genLet(self: *Codegen, let: ast.LetStmt) anyerror!void {
        const dst = try self.intern(let.name);
        if (let.value.* == .call_expr and let.value.call_expr.associated_target == null and std.mem.eql(u8, let.value.call_expr.func_name, "stack_alloc")) {
            try self.emitStackAlloc(dst, try stackAllocSize(let.value.call_expr));
            try self.pushStackAllocLocal(let.name, dst);
            return;
        }
        if (closureLiteralFromExpr(let.value)) |closure| {
            try self.closure_bindings.put(let.name, closure);
            try self.emitAssignImm(dst, 0);
            try self.pushLocal(let.name, dst, false);
            return;
        }
        const src = try self.genExpr(let.value);
        try self.genLetFromValue(let.name, let.ty, let.value, src);
    }

    fn assignToIdentifier(self: *Codegen, name: []const u8, value: u32) anyerror!void {
        if (self.stackLocal(name)) |slot| {
            const ty = slot.stack_ty orelse return Error.UnsupportedSabDirectFeature;
            try self.emitStore(slot.reg, 0, value, try primType(ty));
            if (!self.isLocalReg(value)) try self.emitRelease(value);
            return;
        }

        const dst = self.localReg(name) orelse try self.intern(name);
        if (dst != value and !self.released_regs.contains(dst)) try self.emitRelease(dst);
        try self.emitAssignReg(dst, value);
    }

    fn macroArgBinding(ctx: *const MacroExpansionContext, name: []const u8) ?MacroArgBinding {
        for (ctx.args) |binding| {
            if (std.mem.eql(u8, binding.name, name)) return binding;
        }
        return null;
    }

    fn macroArg(ctx: *const MacroExpansionContext, name: []const u8) ?*const ast.Node {
        if (macroArgBinding(ctx, name)) |binding| return binding.arg;
        return null;
    }

    fn macroLocal(ctx: *const MacroExpansionContext, name: []const u8) ?MacroLocalBinding {
        return ctx.locals.get(name);
    }

    fn macroIdentifierName(ctx: *const MacroExpansionContext, name: []const u8) ?[]const u8 {
        if (macroLocal(ctx, name)) |local| return local.mapped;
        return null;
    }

    fn macroIdentifierType(ctx: *const MacroExpansionContext, name: []const u8) ?*const ast.Type {
        if (macroLocal(ctx, name)) |local| return local.ty;
        return null;
    }

    fn macroScopeMark(ctx: *const MacroExpansionContext) usize {
        return ctx.local_changes.items.len;
    }

    fn restoreMacroLocals(ctx: *MacroExpansionContext, mark: usize) void {
        while (ctx.local_changes.items.len > mark) {
            const change = ctx.local_changes.pop().?;
            if (change.had_old) {
                ctx.locals.put(change.name, change.old) catch unreachable;
            } else {
                _ = ctx.locals.remove(change.name);
            }
        }
    }

    fn newMacroLocalName(self: *Codegen, ctx: *MacroExpansionContext, name: []const u8) ![]const u8 {
        const idx = ctx.local_idx;
        ctx.local_idx += 1;
        const mapped = try std.fmt.allocPrint(self.allocator, "__sla_macro_{s}_{}_{}_{s}", .{ ctx.macro_name, ctx.invocation, idx, name });
        try ctx.allocated_names.append(mapped);
        return mapped;
    }

    fn putMacroLocal(self: *Codegen, ctx: *MacroExpansionContext, name: []const u8, mapped: []const u8, ty: ?*const ast.Type) !void {
        _ = self;
        if (ctx.locals.get(name)) |old| {
            try ctx.local_changes.append(.{ .name = name, .had_old = true, .old = old });
        } else {
            try ctx.local_changes.append(.{ .name = name, .had_old = false });
        }
        try ctx.locals.put(name, .{ .mapped = mapped, .ty = ty });
    }

    fn defineMacroLocal(self: *Codegen, ctx: *MacroExpansionContext, name: []const u8, ty: ?*const ast.Type) ![]const u8 {
        const mapped = try self.newMacroLocalName(ctx, name);
        try self.putMacroLocal(ctx, name, mapped, ty);
        return mapped;
    }

    fn genIdentifierByName(self: *Codegen, name: []const u8) anyerror!u32 {
        var node = ast.Node{ .identifier = name };
        return try self.genExpr(&node);
    }

    fn genMacroIdentifier(self: *Codegen, name: []const u8, ctx: *MacroExpansionContext) anyerror!u32 {
        if (macroIdentifierName(ctx, name)) |mapped| return try self.genIdentifierByName(mapped);
        if (macroArgBinding(ctx, name)) |binding| {
            if (binding.ctx) |arg_ctx| return try self.genMacroExpr(@constCast(binding.arg), arg_ctx);
            return try self.genExpr(@constCast(binding.arg));
        }
        return try self.genIdentifierByName(name);
    }

    fn makePrimitiveType(self: *Codegen, primitive: ast.Primitive) !*const ast.Type {
        const ty = try self.allocator.create(ast.Type);
        ty.* = .{ .primitive = primitive };
        return ty;
    }

    fn macroBinaryResultType(self: *Codegen, bin: ast.BinaryExpr, ctx: *MacroExpansionContext) !?*const ast.Type {
        switch (bin.op) {
            .eq, .ne, .lt, .le, .gt, .ge, .logical_and, .logical_or => return try self.makePrimitiveType(.boolean),
            else => {},
        }
        if (try self.macroExprType(bin.left, ctx)) |ty| {
            if (ty.* != .infer) return ty;
        }
        if (try self.macroExprType(bin.right, ctx)) |ty| return ty;
        return null;
    }

    fn macroExprType(self: *Codegen, expr: *const ast.Node, ctx: *MacroExpansionContext) anyerror!?*const ast.Type {
        return switch (expr.*) {
            .identifier => |name| blk: {
                if (macroIdentifierType(ctx, name)) |ty| break :blk ty;
                if (macroLocal(ctx, name) == null) {
                    if (macroArgBinding(ctx, name)) |binding| {
                        if (binding.ctx) |arg_ctx| break :blk try self.macroExprType(binding.arg, arg_ctx);
                        break :blk try self.exprTypeOrFallback(binding.arg);
                    }
                }
                break :blk try self.exprTypeOrFallback(expr);
            },
            .binary_expr => |bin| blk: {
                if (try self.exprTypeOrFallback(expr)) |ty| {
                    if (ty.* != .infer) break :blk ty;
                }
                break :blk try self.macroBinaryResultType(bin, ctx);
            },
            .borrow_expr => |borrow| blk: {
                if (try self.exprTypeOrFallback(expr)) |ty| {
                    if (ty.* != .infer) break :blk ty;
                }
                const inner = (try self.macroExprType(borrow.expr, ctx)) orelse break :blk null;
                const ty = try self.allocator.create(ast.Type);
                ty.* = .{ .borrow = @constCast(inner) };
                break :blk ty;
            },
            .deref_expr => |deref| blk: {
                if (try self.exprTypeOrFallback(expr)) |ty| {
                    if (ty.* != .infer) break :blk ty;
                }
                const source_ty = (try self.macroExprType(deref.expr, ctx)) orelse break :blk null;
                break :blk switch (source_ty.*) {
                    .borrow => |inner| inner,
                    .pointer => |inner| inner,
                    else => null,
                };
            },
            .cast_expr => |cast| cast.ty,
            .field_expr => |field| blk: {
                if (try self.exprTypeOrFallback(expr)) |ty| {
                    if (ty.* != .infer) break :blk ty;
                }
                const target_ty = (try self.macroExprType(field.expr, ctx)) orelse break :blk null;
                if (target_ty.* == .tuple) {
                    const index = std.fmt.parseUnsigned(usize, field.field_name, 10) catch break :blk null;
                    if (index >= target_ty.tuple.elems.len) break :blk null;
                    break :blk target_ty.tuple.elems[index];
                }
                break :blk self.fieldType(target_ty, field.field_name);
            },
            .index_expr => |idx| blk: {
                if (try self.exprTypeOrFallback(expr)) |ty| {
                    if (ty.* != .infer) break :blk ty;
                }
                const target_ty = (try self.macroExprType(idx.target, ctx)) orelse break :blk null;
                if (target_ty.* != .array) break :blk null;
                break :blk target_ty.array.elem;
            },
            .struct_literal => |lit| lit.ty,
            .tuple_literal => |lit| blk: {
                if (try self.exprTypeOrFallback(expr)) |ty| {
                    if (ty.* != .infer) break :blk ty;
                }
                if (lit.elements.len == 0) break :blk null;
                const elem_tys = try self.allocator.alloc(*ast.Type, lit.elements.len);
                for (lit.elements, 0..) |elem, idx| {
                    elem_tys[idx] = @constCast((try self.macroExprType(elem, ctx)) orelse break :blk null);
                }
                const ty = try self.allocator.create(ast.Type);
                ty.* = .{ .tuple = .{ .elems = elem_tys } };
                break :blk ty;
            },
            .array_literal => |lit| blk: {
                if (try self.exprTypeOrFallback(expr)) |ty| {
                    if (ty.* != .infer) break :blk ty;
                }
                if (lit.elements.len == 0) break :blk null;
                const elem_ty = (try self.macroExprType(lit.elements[0], ctx)) orelse break :blk null;
                const ty = try self.allocator.create(ast.Type);
                ty.* = .{ .array = .{ .elem = @constCast(elem_ty), .len = lit.elements.len } };
                break :blk ty;
            },
            .repeat_array_literal => |lit| blk: {
                if (try self.exprTypeOrFallback(expr)) |ty| {
                    if (ty.* != .infer) break :blk ty;
                }
                const elem_ty = (try self.macroExprType(lit.value, ctx)) orelse break :blk null;
                const ty = try self.allocator.create(ast.Type);
                ty.* = .{ .array = .{ .elem = @constCast(elem_ty), .len = lit.len } };
                break :blk ty;
            },
            .call_expr, .if_expr => try self.exprTypeOrFallback(expr),
            .move_expr => |move| try self.macroExprType(move.expr, ctx),
            else => try self.exprTypeOrFallback(expr),
        };
    }

    fn macroOpKindForBinary(self: *Codegen, bin: ast.BinaryExpr, ctx: *MacroExpansionContext) !inst.OpKind {
        const lhs_ty = try self.macroExprType(bin.left, ctx);
        const rhs_ty = try self.macroExprType(bin.right, ctx);
        const use_float = (lhs_ty != null and isFloatType(lhs_ty.?)) or (rhs_ty != null and isFloatType(rhs_ty.?));
        if (use_float) {
            return switch (bin.op) {
                .add => .fadd,
                .sub => .fsub,
                .mul => .fmul,
                .div => .fdiv,
                .eq => .fcmp_eq,
                .ne => .fcmp_ne,
                .lt => .fcmp_lt,
                .le => .fcmp_le,
                .gt => .fcmp_gt,
                .ge => .fcmp_ge,
                else => Error.UnsupportedSabDirectFeature,
            };
        }
        return switch (bin.op) {
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
            .logical_and => .@"and",
            .logical_or => .@"or",
            else => Error.UnsupportedSabDirectFeature,
        };
    }

    fn genMacroFieldAddress(self: *Codegen, field: ast.FieldExpr, ctx: *MacroExpansionContext) anyerror!AddressSource {
        const expr_ty = (try self.macroExprType(field.expr, ctx)) orelse return Error.MissingType;
        const layout = if (expr_ty.* == .tuple) blk: {
            const index = std.fmt.parseUnsigned(usize, field.field_name, 10) catch return Error.UnsupportedSabDirectFeature;
            break :blk tupleFieldLayout(expr_ty.tuple, index) orelse return Error.UnsupportedSabDirectFeature;
        } else try self.fieldLayout(expr_ty, field.field_name);
        const base = try self.genMacroExpr(field.expr, ctx);
        return try self.addressWithOffset(base, layout.offset);
    }

    fn genMacroIndexAddress(self: *Codegen, idx: ast.IndexExpr, ctx: *MacroExpansionContext) anyerror!AddressSource {
        const target_ty = (try self.macroExprType(idx.target, ctx)) orelse return Error.MissingType;
        if (target_ty.* != .array) return Error.UnsupportedSabDirectFeature;
        const target_reg = try self.genMacroExpr(idx.target, ctx);
        if (idx.index.* == .literal and idx.index.literal == .int_val) {
            const raw_index = idx.index.literal.int_val;
            if (raw_index < 0) return Error.UnsupportedSabDirectFeature;
            const layout = arrayElementLayout(target_ty.array, @intCast(raw_index)) orelse return Error.UnsupportedSabDirectFeature;
            return try self.addressWithOffset(target_reg, layout.offset);
        }

        const index_reg = try self.genMacroExpr(idx.index, ctx);
        const elem_ptr = try self.genArrayElementPtr(target_ty.array, target_reg, index_reg);
        if (elem_ptr.offset) |offset| try self.emitRelease(offset);
        if (!self.isLocalReg(index_reg)) try self.emitRelease(index_reg);
        return .{ .reg = elem_ptr.ptr };
    }

    fn genMacroAddressOf(self: *Codegen, expr: *ast.Node, ctx: *MacroExpansionContext) anyerror!AddressSource {
        return switch (expr.*) {
            .identifier => |name| blk: {
                if (macroIdentifierName(ctx, name)) |mapped| {
                    if (self.stackLocal(mapped)) |slot| break :blk .{ .reg = slot.reg };
                    break :blk .{ .reg = try self.genIdentifierByName(mapped) };
                }
                if (macroArgBinding(ctx, name)) |binding| {
                    if (binding.ctx) |arg_ctx| break :blk try self.genMacroAddressOf(@constCast(binding.arg), arg_ctx);
                    break :blk try self.genAddressOf(@constCast(binding.arg));
                }
                if (self.stackLocal(name)) |slot| break :blk .{ .reg = slot.reg };
                break :blk .{ .reg = try self.genIdentifierByName(name) };
            },
            .deref_expr => |deref| .{ .reg = try self.genMacroExpr(deref.expr, ctx) },
            .field_expr => |field| try self.genMacroFieldAddress(field, ctx),
            .index_expr => |idx| try self.genMacroIndexAddress(idx, ctx),
            else => .{ .reg = try self.genMacroExpr(expr, ctx) },
        };
    }

    fn genMacroBorrow(self: *Codegen, borrow: ast.BorrowExpr, ctx: *MacroExpansionContext) anyerror!u32 {
        const source = try self.genMacroAddressOf(borrow.expr, ctx);
        const dst = try self.intern(try self.newTmp());
        try self.emitBorrowReg(dst, source.reg, "read");
        return dst;
    }

    fn genMacroDeref(self: *Codegen, expr: *const ast.Node, deref: ast.DerefExpr, ctx: *MacroExpansionContext) anyerror!u32 {
        const deref_ty = (try self.macroExprType(expr, ctx)) orelse return Error.MissingType;
        const source = try self.genMacroExpr(deref.expr, ctx);
        const dst = try self.intern(try self.newTmp());
        try self.emitLoad(dst, source, 0, try primType(deref_ty));
        if (!self.isLocalReg(source)) try self.emitRelease(source);
        return dst;
    }

    fn genMacroBinary(self: *Codegen, bin: ast.BinaryExpr, ctx: *MacroExpansionContext) anyerror!u32 {
        const lhs = try self.genMacroExpr(bin.left, ctx);
        const rhs = try self.genMacroExpr(bin.right, ctx);
        const dst = try self.intern(try self.newTmp());
        try self.recordReg(dst);
        var item = self.makeInst(.op);
        item.op_kind = try self.macroOpKindForBinary(bin, ctx);
        item.operands[0] = .{ .reg = dst };
        item.operands[1] = .{ .reg = lhs };
        item.operands[2] = .{ .reg = rhs };
        try self.appendInst(item);
        try self.releaseNonLocalTemps(&.{ lhs, rhs });
        return dst;
    }

    fn genMacroCast(self: *Codegen, cast: ast.CastExpr, ctx: *MacroExpansionContext) anyerror!u32 {
        const src_ast_ty = (try self.macroExprType(cast.expr, ctx)) orelse return Error.MissingType;
        const src_ty = try primType(src_ast_ty);
        const dst_ty = try primType(cast.ty);
        const src = try self.genMacroExpr(cast.expr, ctx);

        if (!isNumericType(src_ast_ty) or !isNumericType(cast.ty)) {
            if (src_ty == .ptr and dst_ty == .ptr) return src;
            return Error.UnsupportedSabDirectFeature;
        }

        const dst = try self.intern(try self.newTmp());
        try self.recordReg(dst);
        var item = self.makeInst(.op);
        item.op_kind = try opKindForCast(src_ty, dst_ty);
        item.operands[0] = .{ .reg = dst };
        item.operands[1] = .{ .reg = src };
        item.operands[2] = .{ .ty = @intFromEnum(dst_ty) };
        try self.appendInst(item);
        if (!self.isLocalReg(src)) try self.emitRelease(src);
        return dst;
    }

    fn genMacroField(self: *Codegen, field: ast.FieldExpr, ctx: *MacroExpansionContext) anyerror!u32 {
        const expr_ty = (try self.macroExprType(field.expr, ctx)) orelse return Error.MissingType;
        if (expr_ty.* == .tuple) {
            const index = std.fmt.parseUnsigned(usize, field.field_name, 10) catch return Error.UnsupportedSabDirectFeature;
            const layout = tupleFieldLayout(expr_ty.tuple, index) orelse return Error.UnsupportedSabDirectFeature;
            const base = try self.genMacroExpr(field.expr, ctx);
            const dst = try self.intern(try self.newTmp());
            try self.emitLoad(dst, base, layout.offset, layout.ty);
            if (!self.isLocalReg(base)) try self.emitRelease(base);
            return dst;
        }
        const layout = try self.fieldLayout(expr_ty, field.field_name);
        _ = self.fieldType(expr_ty, field.field_name) orelse return Error.UnsupportedSabDirectFeature;

        const base = try self.genMacroExpr(field.expr, ctx);
        const dst = try self.intern(try self.newTmp());
        try self.emitLoad(dst, base, layout.offset, layout.ty);
        if (!self.isLocalReg(base)) try self.emitRelease(base);
        return dst;
    }

    fn genMacroIndex(self: *Codegen, idx: ast.IndexExpr, ctx: *MacroExpansionContext) anyerror!u32 {
        const target_ty = (try self.macroExprType(idx.target, ctx)) orelse return Error.MissingType;
        if (target_ty.* != .array) return Error.UnsupportedSabDirectFeature;
        const target_reg = try self.genMacroExpr(idx.target, ctx);
        const dst = try self.intern(try self.newTmp());
        if (idx.index.* == .literal and idx.index.literal == .int_val) {
            const raw_index = idx.index.literal.int_val;
            if (raw_index < 0) return Error.UnsupportedSabDirectFeature;
            const layout = arrayElementLayout(target_ty.array, @intCast(raw_index)) orelse return Error.UnsupportedSabDirectFeature;
            try self.emitLoad(dst, target_reg, layout.offset, layout.ty);
        } else {
            const index_reg = try self.genMacroExpr(idx.index, ctx);
            const elem_ptr = try self.genArrayElementPtr(target_ty.array, target_reg, index_reg);
            try self.emitLoad(dst, elem_ptr.ptr, 0, try primType(target_ty.array.elem));
            if (elem_ptr.offset) |offset| try self.emitRelease(offset);
            try self.emitRelease(elem_ptr.ptr);
            if (!self.isLocalReg(index_reg)) try self.emitRelease(index_reg);
        }
        if (!self.isLocalReg(target_reg)) try self.emitRelease(target_reg);
        return dst;
    }

    fn genMacroStructLiteral(self: *Codegen, lit: ast.StructLiteral, ctx: *MacroExpansionContext) anyerror!u32 {
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
            const value_reg = try self.genMacroExpr(value, ctx);
            try self.emitStore(dst, layout.offset, value_reg, layout.ty);
            if (!self.isLocalReg(value_reg)) try self.emitRelease(value_reg);
        }

        return dst;
    }

    fn genMacroTupleLiteral(self: *Codegen, lit: ast.TupleLiteral, ctx: *MacroExpansionContext) anyerror!u32 {
        if (lit.elements.len == 0) return Error.UnsupportedSabDirectFeature;
        const elem_tys = try self.allocator.alloc(*ast.Type, lit.elements.len);
        for (lit.elements, 0..) |elem, idx| {
            elem_tys[idx] = @constCast((try self.macroExprType(elem, ctx)) orelse return Error.MissingType);
        }
        const tuple_ty = ast.TupleType{ .elems = elem_tys };
        const dst = try self.intern(try self.newTmp());
        try self.emitAlloc(dst, tupleSize(tuple_ty));
        for (lit.elements, 0..) |elem, idx| {
            const layout = tupleFieldLayout(tuple_ty, idx) orelse return Error.UnsupportedSabDirectFeature;
            const value = try self.genMacroExpr(elem, ctx);
            try self.emitStore(dst, layout.offset, value, layout.ty);
            if (!self.isLocalReg(value)) try self.emitRelease(value);
        }
        return dst;
    }

    fn genMacroArrayLiteralWithType(self: *Codegen, arr_ty: *const ast.Type, lit: ast.ArrayLiteral, ctx: *MacroExpansionContext) anyerror!u32 {
        if (arr_ty.* != .array or arr_ty.array.len != lit.elements.len) return Error.UnsupportedSabDirectFeature;

        const dst = try self.intern(try self.newTmp());
        try self.emitAlloc(dst, arraySize(arr_ty.array));
        for (lit.elements, 0..) |elem, idx| {
            const layout = arrayElementLayout(arr_ty.array, idx) orelse return Error.UnsupportedSabDirectFeature;
            const value = try self.genMacroExpr(elem, ctx);
            try self.emitStore(dst, layout.offset, value, layout.ty);
            if (!self.isLocalReg(value)) try self.emitRelease(value);
        }
        return dst;
    }

    fn genMacroRepeatArrayLiteralWithType(self: *Codegen, arr_ty: *const ast.Type, lit: ast.RepeatArrayLiteral, ctx: *MacroExpansionContext) anyerror!u32 {
        if (arr_ty.* != .array or arr_ty.array.len != lit.len) return Error.UnsupportedSabDirectFeature;
        _ = try primType(arr_ty.array.elem);

        const dst = try self.intern(try self.newTmp());
        try self.emitAlloc(dst, arraySize(arr_ty.array));
        const value = try self.genMacroExpr(lit.value, ctx);
        for (0..lit.len) |idx| {
            const layout = arrayElementLayout(arr_ty.array, idx) orelse return Error.UnsupportedSabDirectFeature;
            try self.emitStore(dst, layout.offset, value, layout.ty);
        }
        if (!self.isLocalReg(value)) try self.emitRelease(value);
        return dst;
    }

    fn genMacroExprTyped(self: *Codegen, expr: *ast.Node, ctx: *MacroExpansionContext, expected_ty: ?*const ast.Type) anyerror!u32 {
        if (expected_ty) |ty| {
            switch (expr.*) {
                .array_literal => |lit| return try self.genMacroArrayLiteralWithType(ty, lit, ctx),
                .repeat_array_literal => |lit| return try self.genMacroRepeatArrayLiteralWithType(ty, lit, ctx),
                else => {},
            }
        }
        return try self.genMacroExpr(expr, ctx);
    }

    fn macroEffectiveArg(ctx: *MacroExpansionContext, arg: *const ast.Node) *const ast.Node {
        if (arg.* == .identifier and macroLocal(ctx, arg.identifier) == null) {
            if (macroArgBinding(ctx, arg.identifier)) |binding| {
                if (binding.ctx) |arg_ctx| return macroEffectiveArg(arg_ctx, binding.arg);
                return binding.arg;
            }
        }
        return arg;
    }

    fn genMacroCall(self: *Codegen, expr: *const ast.Node, call: ast.CallExpr, ctx: *MacroExpansionContext) anyerror!u32 {
        if (std.mem.eql(u8, call.func_name, "panic")) {
            var item = self.makeInst(.panic);
            if (call.args.len == 1 and call.args[0].* == .literal and call.args[0].literal == .int_val) {
                item.operands[0] = .{ .text = try std.fmt.allocPrint(self.allocator, "{}", .{call.args[0].literal.int_val}) };
            } else if (call.args.len == 1) {
                const code = try self.genMacroExpr(@constCast(call.args[0]), ctx);
                item.operands[0] = .{ .reg = code };
            } else {
                item.operands[0] = .{ .text = "1" };
            }
            try self.appendInst(item);
            return try self.intern(try self.newTmp());
        }
        if (call.associated_target == null) {
            if (std.mem.eql(u8, call.func_name, "stack_alloc")) {
                const dst = try self.intern(try self.newTmp());
                try self.emitStackAlloc(dst, try stackAllocSize(call));
                try self.pushStackAllocLocal(self.symbols.items[dst], dst);
                return dst;
            }
            if (self.tc.macros.get(call.func_name)) |macro_decl| {
                try self.genUserMacroCallWithParent(macro_decl, call, ctx);
                const sentinel = try self.intern(try self.newTmp());
                try self.emitAssignImm(sentinel, 0);
                return sentinel;
            }
        }

        const call_plan = lowering_rules.planStaticCall(self.tc, expr, call) orelse return Error.UnsupportedSabDirectFeature;

        const dst = try self.intern(try self.newTmp());
        try self.recordReg(dst);
        const lowered = try self.loweredFuncSymbol(call_plan.target_symbol);
        var text = std.ArrayList(u8).init(self.allocator);
        var release_regs = std.ArrayList(u32).init(self.allocator);
        defer release_regs.deinit();
        const maybe_func = self.tc.funcs.get(call_plan.target_symbol);
        try text.writer().print("@{s}(", .{lowered});
        for (call.args, 0..) |arg, i| {
            const effective = macroEffectiveArg(ctx, arg);
            const param = if (maybe_func) |func| if (i < func.params.len) func.params[i] else null else null;
            const lowered_arg = try self.genPlannedSabMacroCallArg(arg, effective, ctx, call_plan, param, i, call.associated_target == null);
            try release_regs.append(lowered_arg.release_reg);
            if (i > 0) try text.appendSlice(", ");
            try text.appendSlice(lowered_arg.operand);
        }
        try text.append(')');
        var item = self.makeInst(.call);
        item.operands[0] = .{ .reg = dst };
        item.operands[1] = .{ .text = try text.toOwnedSlice() };
        try self.appendInst(item);
        try self.releaseNonLocalTemps(release_regs.items);
        return dst;
    }

    fn genMacroBlockTailValueStore(self: *Codegen, block: []const *ast.Node, target: u32, target_ty: *const ast.Type, ctx: *MacroExpansionContext) anyerror!bool {
        const tail = blockTailExpr(block) orelse return Error.UnsupportedSabDirectFeature;
        for (block[0 .. block.len - 1]) |stmt| {
            try self.genMacroStmt(stmt, ctx);
            if (self.lastIsTerminator()) return true;
        }
        const value = try self.genMacroExpr(tail, ctx);
        try self.emitStore(target, 0, value, try primType(target_ty));
        if (!self.isLocalReg(value)) try self.emitRelease(value);
        return false;
    }

    fn macroBlockTailType(self: *Codegen, block: []const *ast.Node, ctx: *MacroExpansionContext) anyerror!?*const ast.Type {
        const tail = blockTailExpr(block) orelse return null;
        return try self.macroExprType(tail, ctx);
    }

    fn genMacroIfValue(self: *Codegen, ife: ast.IfExpr, else_block: []const *ast.Node, result_ty: *const ast.Type, ctx: *MacroExpansionContext) anyerror!u32 {
        if (ife.let_chain != null) return Error.UnsupportedSabDirectFeature;
        const cond = try self.genMacroExpr(ife.cond, ctx);
        const result_slot = try self.intern(try self.newTmp());
        try self.emitAlloc(result_slot, typeSize(result_ty));
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
        if (!self.isLocalReg(cond)) try self.emitBranchRelease(cond);
        const then_terminated = try self.genMacroBlockTailValueStore(ife.then_block, result_slot, result_ty, ctx);
        if (!then_terminated) try self.emitJmp(merge_label);
        try self.emitLabel(else_label);
        if (!self.isLocalReg(cond)) try self.emitBranchRelease(cond);
        const else_terminated = try self.genMacroBlockTailValueStore(else_block, result_slot, result_ty, ctx);
        if (!else_terminated) try self.emitJmp(merge_label);
        if (!then_terminated or !else_terminated) {
            try self.emitLabel(merge_label);
            const result = try self.intern(try self.newTmp());
            try self.emitLoad(result, result_slot, 0, try primType(result_ty));
            try self.emitRelease(result_slot);
            return result;
        }

        const result = try self.intern(try self.newTmp());
        try self.recordReg(result);
        return result;
    }

    fn genMacroIfStatement(self: *Codegen, ife: ast.IfExpr, ctx: *MacroExpansionContext) anyerror!u32 {
        if (ife.let_chain != null) return Error.UnsupportedSabDirectFeature;
        const cond = try self.genMacroExpr(ife.cond, ctx);
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
        if (!self.isLocalReg(cond)) try self.emitBranchRelease(cond);
        try self.genMacroBlock(ife.then_block, ctx, true);
        const then_terminated = self.lastIsTerminator();
        if (!then_terminated) try self.emitJmp(merge_label);
        try self.emitLabel(else_label);
        if (!self.isLocalReg(cond)) try self.emitBranchRelease(cond);
        if (ife.else_block) |else_block| try self.genMacroBlock(else_block, ctx, true);
        const else_terminated = self.lastIsTerminator();
        if (!else_terminated) try self.emitJmp(merge_label);
        if (!then_terminated or !else_terminated) try self.emitLabel(merge_label);
        const result = try self.intern(try self.newTmp());
        try self.recordReg(result);
        return result;
    }

    fn genMacroIf(self: *Codegen, expr: *const ast.Node, ife: ast.IfExpr, ctx: *MacroExpansionContext) anyerror!u32 {
        if (ife.else_block) |else_block| {
            if (blockTailExpr(ife.then_block) != null and blockTailExpr(else_block) != null) {
                if ((try self.macroExprType(expr, ctx)) orelse (try self.macroBlockTailType(ife.then_block, ctx))) |ty| {
                    if (!isVoidType(ty)) return try self.genMacroIfValue(ife, else_block, ty, ctx);
                }
            }
        }
        return try self.genMacroIfStatement(ife, ctx);
    }

    fn genMacroExpr(self: *Codegen, expr: *ast.Node, ctx: *MacroExpansionContext) anyerror!u32 {
        return switch (expr.*) {
            .literal => |lit| try self.genLiteral(lit),
            .identifier => |name| try self.genMacroIdentifier(name, ctx),
            .binary_expr => |bin| try self.genMacroBinary(bin, ctx),
            .call_expr => |call| try self.genMacroCall(expr, call, ctx),
            .field_expr => |field| try self.genMacroField(field, ctx),
            .struct_literal => |lit| try self.genMacroStructLiteral(lit, ctx),
            .tuple_literal => |lit| try self.genMacroTupleLiteral(lit, ctx),
            .array_literal => |lit| blk: {
                const ty = (try self.macroExprType(expr, ctx)) orelse return Error.MissingType;
                break :blk try self.genMacroArrayLiteralWithType(ty, lit, ctx);
            },
            .repeat_array_literal => |lit| blk: {
                const ty = (try self.macroExprType(expr, ctx)) orelse return Error.MissingType;
                break :blk try self.genMacroRepeatArrayLiteralWithType(ty, lit, ctx);
            },
            .index_expr => |idx| try self.genMacroIndex(idx, ctx),
            .if_expr => |ife| try self.genMacroIf(expr, ife, ctx),
            .cast_expr => |cast| try self.genMacroCast(cast, ctx),
            .borrow_expr => |borrow| try self.genMacroBorrow(borrow, ctx),
            .deref_expr => |deref| try self.genMacroDeref(expr, deref, ctx),
            .move_expr => |move| try self.genMacroExpr(move.expr, ctx),
            else => try self.genExpr(expr),
        };
    }

    fn macroAssignTargetName(self: *Codegen, target: *ast.Node, ctx: *MacroExpansionContext) ?[]const u8 {
        if (target.* != .identifier) return null;
        const name = target.identifier;
        if (macroIdentifierName(ctx, name)) |mapped| return mapped;
        if (macroArgBinding(ctx, name)) |binding| {
            if (binding.ctx) |arg_ctx| return self.macroAssignTargetName(@constCast(binding.arg), arg_ctx);
            if (binding.arg.* == .identifier) return binding.arg.identifier;
            return null;
        }
        return name;
    }

    fn genMacroAssign(self: *Codegen, assign: ast.AssignStmt, ctx: *MacroExpansionContext) anyerror!void {
        if (assign.target.* == .index_expr) {
            const idx = assign.target.index_expr;
            const target_ty = (try self.macroExprType(idx.target, ctx)) orelse return Error.MissingType;
            if (target_ty.* != .array) return Error.UnsupportedSabDirectFeature;
            const target_reg = try self.genMacroExpr(idx.target, ctx);
            const value = try self.genMacroExpr(assign.value, ctx);
            if (idx.index.* == .literal and idx.index.literal == .int_val) {
                const raw_index = idx.index.literal.int_val;
                if (raw_index < 0) return Error.UnsupportedSabDirectFeature;
                const layout = arrayElementLayout(target_ty.array, @intCast(raw_index)) orelse return Error.UnsupportedSabDirectFeature;
                try self.emitStore(target_reg, layout.offset, value, layout.ty);
            } else {
                const index_reg = try self.genMacroExpr(idx.index, ctx);
                const elem_ptr = try self.genArrayElementPtr(target_ty.array, target_reg, index_reg);
                try self.emitStore(elem_ptr.ptr, 0, value, try primType(target_ty.array.elem));
                if (elem_ptr.offset) |offset| try self.emitRelease(offset);
                try self.emitRelease(elem_ptr.ptr);
                if (!self.isLocalReg(index_reg)) try self.emitRelease(index_reg);
            }
            if (!self.isLocalReg(value)) try self.emitRelease(value);
            if (!self.isLocalReg(target_reg)) try self.emitRelease(target_reg);
            return;
        }

        const value = try self.genMacroExpr(assign.value, ctx);
        if (self.macroAssignTargetName(assign.target, ctx)) |name| {
            try self.assignToIdentifier(name, value);
            return;
        }
        return Error.UnsupportedSabDirectFeature;
    }

    fn genMacroLet(self: *Codegen, let: ast.LetStmt, ctx: *MacroExpansionContext) anyerror!void {
        const expected_ty = if (let.ty) |ty| @as(?*const ast.Type, ty) else try self.macroExprType(let.value, ctx);
        const value = try self.genMacroExprTyped(let.value, ctx, expected_ty);
        const mapped = try self.defineMacroLocal(ctx, let.name, expected_ty);
        try self.genLetFromValue(mapped, expected_ty, let.value, value);
    }

    fn genMacroVar(self: *Codegen, v: ast.VarStmt, ctx: *MacroExpansionContext) anyerror!void {
        const mapped = try self.defineMacroLocal(ctx, v.name, v.ty);
        const dst = try self.intern(mapped);
        try self.emitStackAlloc(dst, typeSize(v.ty));
        try self.pushStackLocal(mapped, dst, v.ty);
    }

    fn genMacroLetDestructure(self: *Codegen, let: ast.LetDestructureStmt, ctx: *MacroExpansionContext) anyerror!void {
        if (let.is_slice or let.rest_name != null or let.rest_alias != null) return Error.UnsupportedSabDirectFeature;
        const value_ty = (try self.macroExprType(let.value, ctx)) orelse return Error.MissingType;
        if (value_ty.* != .tuple or value_ty.tuple.elems.len != let.names.len) return Error.UnsupportedSabDirectFeature;
        const value = try self.genMacroExpr(let.value, ctx);
        for (let.names, 0..) |name, idx| {
            const layout = tupleFieldLayout(value_ty.tuple, idx) orelse return Error.UnsupportedSabDirectFeature;
            const discard = std.mem.eql(u8, name, "_");
            const mapped = if (discard) try self.newTmp() else try self.defineMacroLocal(ctx, name, value_ty.tuple.elems[idx]);
            const dst = try self.intern(mapped);
            try self.emitLoad(dst, value, layout.offset, layout.ty);
            if (discard) try self.emitRelease(dst) else try self.pushLocal(mapped, dst, false);
        }
        if (!self.isLocalReg(value)) try self.emitRelease(value);
    }

    fn genMacroBlock(self: *Codegen, body: []const *ast.Node, ctx: *MacroExpansionContext, scoped: bool) anyerror!void {
        const mark = macroScopeMark(ctx);
        defer if (scoped) restoreMacroLocals(ctx, mark);
        for (body) |stmt| {
            try self.genMacroStmt(stmt, ctx);
            if (self.lastIsTerminator()) break;
        }
    }

    fn genMacroWhile(self: *Codegen, w: ast.WhileStmt, ctx: *MacroExpansionContext) anyerror!void {
        if (w.let_pattern != null) return Error.UnsupportedSabDirectFeature;
        const head_label = try self.newLabel("L_WHILE_HEAD");
        const body_label = try self.newLabel("L_WHILE_BODY");
        const exit_label = try self.newLabel("L_WHILE_EXIT");

        try self.emitJmp(head_label);
        try self.emitLabel(head_label);
        const cond = try self.genMacroExpr(w.cond, ctx);
        var br = self.makeInst(.br);
        br.operands[0] = .{ .reg = cond };
        br.operands[1] = .{ .label = try self.intern(body_label) };
        br.operands[2] = .{ .label = try self.intern(body_label) };
        br.operands[3] = .{ .label = try self.intern(exit_label) };
        try self.appendInst(br);

        try self.emitLabel(body_label);
        if (!self.isLocalReg(cond)) try self.emitBranchRelease(cond);
        try self.genMacroBlock(w.body, ctx, true);
        if (!self.lastIsTerminator()) try self.emitJmp(head_label);

        try self.emitLabel(exit_label);
        if (!self.isLocalReg(cond)) try self.emitBranchRelease(cond);
    }

    fn genMacroFor(self: *Codegen, f: ast.ForStmt, ctx: *MacroExpansionContext) anyerror!void {
        const end_expr = f.end orelse return Error.UnsupportedSabDirectFeature;
        const old_locals = self.locals.items.len;
        defer self.popLocalsTo(old_locals);
        const mark = macroScopeMark(ctx);
        defer restoreMacroLocals(ctx, mark);

        const counter_slot = try self.intern(try self.newTmp());
        try self.emitStackAlloc(counter_slot, 8);
        const start_reg = try self.genMacroExpr(f.start, ctx);
        const end_reg = try self.genMacroExpr(end_expr, ctx);
        try self.emitStore(counter_slot, 0, start_reg, .i64);
        if (!self.isLocalReg(start_reg)) try self.emitRelease(start_reg);

        const loop_ty = try self.makePrimitiveType(.i64);
        const mapped_var = try self.defineMacroLocal(ctx, f.var_name, loop_ty);
        const head_label = try self.newLabel("L_FOR_HEAD");
        const body_label = try self.newLabel("L_FOR_BODY");
        const cont_label = try self.newLabel("L_FOR_CONTINUE");
        const exit_label = try self.newLabel("L_FOR_EXIT");

        try self.emitJmp(head_label);
        try self.emitLabel(head_label);
        const index_reg = try self.intern(try self.newTmp());
        try self.emitLoad(index_reg, counter_slot, 0, .i64);
        const cond = try self.intern(try self.newTmp());
        try self.emitOp(cond, .slt, .{ .reg = index_reg }, .{ .reg = end_reg });

        var br = self.makeInst(.br);
        br.operands[0] = .{ .reg = cond };
        br.operands[1] = .{ .label = try self.intern(body_label) };
        br.operands[2] = .{ .label = try self.intern(body_label) };
        br.operands[3] = .{ .label = try self.intern(exit_label) };
        try self.appendInst(br);

        try self.emitLabel(body_label);
        try self.emitBranchRelease(cond);
        try self.pushLocal(mapped_var, index_reg, false);
        try self.genMacroBlock(f.body, ctx, true);
        if (!self.lastIsTerminator()) try self.emitJmp(cont_label);

        try self.emitLabel(cont_label);
        const next = try self.intern(try self.newTmp());
        try self.emitOp(next, .add, .{ .reg = index_reg }, .{ .imm_i64 = 1 });
        try self.emitStore(counter_slot, 0, next, .i64);
        try self.emitRelease(next);
        if (!self.released_regs.contains(index_reg)) try self.emitRelease(index_reg);
        try self.emitJmp(head_label);

        try self.emitLabel(exit_label);
        try self.emitBranchRelease(cond);
        if (!self.isLocalReg(end_reg)) try self.emitRelease(end_reg);
    }

    fn genMacroStmt(self: *Codegen, stmt: *ast.Node, ctx: *MacroExpansionContext) anyerror!void {
        switch (stmt.*) {
            .let_stmt => |let| try self.genMacroLet(let, ctx),
            .let_destructure_stmt => |let| try self.genMacroLetDestructure(let, ctx),
            .var_stmt => |v| try self.genMacroVar(v, ctx),
            .assign_stmt => |assign| try self.genMacroAssign(assign, ctx),
            .expr_stmt => |expr| {
                if (expr.* == .call_expr and std.mem.eql(u8, expr.call_expr.func_name, "panic")) {
                    _ = try self.genMacroExpr(expr, ctx);
                    return;
                }
                if (expr.* == .if_expr) {
                    _ = try self.genMacroExpr(expr, ctx);
                    return;
                }
                const value = try self.genMacroExpr(expr, ctx);
                if (!self.isLocalReg(value)) try self.emitRelease(value);
            },
            .return_stmt => |ret| {
                const value = if (ret.value) |v| try self.genMacroExpr(v, ctx) else null;
                try self.releaseOpenLocals(value);
                try self.emitReturn(value);
            },
            .release_stmt => |rel| {
                const name = if (macroIdentifierName(ctx, rel.var_name)) |mapped| mapped else blk: {
                    if (macroArgBinding(ctx, rel.var_name)) |binding| {
                        if (binding.ctx) |arg_ctx| {
                            break :blk self.macroAssignTargetName(@constCast(binding.arg), arg_ctx) orelse return Error.UnsupportedSabDirectFeature;
                        }
                        if (binding.arg.* != .identifier) return Error.UnsupportedSabDirectFeature;
                        break :blk binding.arg.identifier;
                    }
                    break :blk rel.var_name;
                };
                const reg = self.localReg(name) orelse try self.intern(name);
                try self.emitRelease(reg);
            },
            .block_stmt => |block| try self.genMacroBlock(block.body, ctx, true),
            .for_stmt => |f| try self.genMacroFor(f, ctx),
            .while_stmt => |w| try self.genMacroWhile(w, ctx),
            else => return Error.UnsupportedSabDirectFeature,
        }
    }

    fn genUserMacroCallWithParent(self: *Codegen, macro_decl: *const ast.MacroDecl, call: ast.CallExpr, parent_ctx: ?*MacroExpansionContext) anyerror!void {
        if (macro_decl.params.len != call.args.len) return Error.UnsupportedSabDirectFeature;
        const bindings = try self.allocator.alloc(MacroArgBinding, call.args.len);
        defer self.allocator.free(bindings);
        for (macro_decl.params, call.args, 0..) |param, arg, idx| {
            bindings[idx] = .{ .name = param, .arg = arg, .ctx = parent_ctx };
        }

        const invocation = self.macro_call_idx;
        self.macro_call_idx += 1;
        var ctx = MacroExpansionContext{
            .macro_name = macro_decl.name,
            .invocation = invocation,
            .args = bindings,
            .locals = std.StringHashMap(MacroLocalBinding).init(self.allocator),
            .local_changes = std.ArrayList(MacroLocalChange).init(self.allocator),
            .allocated_names = std.ArrayList([]const u8).init(self.allocator),
        };
        defer {
            ctx.allocated_names.deinit();
            ctx.local_changes.deinit();
            ctx.locals.deinit();
        }

        const old_locals = self.locals.items.len;
        defer self.popLocalsTo(old_locals);
        try self.genMacroBlock(macro_decl.body, &ctx, false);
        var i = self.locals.items.len;
        while (i > old_locals) {
            i -= 1;
            const local = self.locals.items[i];
            if (local.is_param or local.stack_ty != null or self.released_regs.contains(local.reg)) continue;
            try self.emitRelease(local.reg);
        }
    }

    fn genUserMacroCall(self: *Codegen, macro_decl: *const ast.MacroDecl, call: ast.CallExpr) anyerror!void {
        try self.genUserMacroCallWithParent(macro_decl, call, null);
    }

    fn genStmt(self: *Codegen, stmt: *ast.Node) anyerror!void {
        switch (stmt.*) {
            .var_stmt => |v| {
                const dst = try self.intern(v.name);
                try self.emitStackAlloc(dst, typeSize(v.ty));
                try self.pushStackLocal(v.name, dst, v.ty);
            },
            .let_stmt => |let| try self.genLet(let),
            .let_destructure_stmt => |let| try self.genLetDestructure(let),
            .assign_stmt => |assign| try self.genAssign(assign),
            .expr_stmt => |expr| {
                if (expr.* == .if_expr) {
                    _ = try self.genExpr(expr);
                } else if (expr.* == .call_expr and std.mem.eql(u8, expr.call_expr.func_name, "panic")) {
                    _ = try self.genExpr(expr);
                } else if (expr.* == .call_expr) {
                    if (self.tc.macros.get(expr.call_expr.func_name)) |macro_decl| {
                        try self.genUserMacroCall(macro_decl, expr.call_expr);
                        return;
                    }
                    const value = try self.genExpr(expr);
                    try self.emitRelease(value);
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
            .for_stmt => |f| try self.genFor(f),
            .while_stmt => |w| try self.genWhile(w),
            else => return Error.UnsupportedSabDirectFeature,
        }
    }

    fn genLetDestructure(self: *Codegen, let: ast.LetDestructureStmt) anyerror!void {
        if (let.is_slice or let.rest_name != null or let.rest_alias != null) return Error.UnsupportedSabDirectFeature;
        const value_ty = self.tc.expr_types.get(let.value) orelse return Error.MissingType;
        if (value_ty.* != .tuple or value_ty.tuple.elems.len != let.names.len) return Error.UnsupportedSabDirectFeature;
        const value = try self.genExpr(let.value);
        for (let.names, 0..) |name, idx| {
            const layout = tupleFieldLayout(value_ty.tuple, idx) orelse return Error.UnsupportedSabDirectFeature;
            const discard = std.mem.eql(u8, name, "_");
            const dst = try self.intern(if (discard) try self.newTmp() else name);
            try self.emitLoad(dst, value, layout.offset, layout.ty);
            if (discard) {
                try self.emitRelease(dst);
            } else {
                try self.pushTypedLocal(name, dst, false, value_ty.tuple.elems[idx]);
            }
        }
        if (!self.isLocalReg(value)) try self.emitRelease(value);
    }

    fn genAssign(self: *Codegen, assign: ast.AssignStmt) anyerror!void {
        if (assign.target.* == .field_expr) {
            const field = assign.target.field_expr;
            const expr_ty = self.tc.expr_types.get(field.expr) orelse return Error.MissingType;
            const field_ty = if (expr_ty.* == .tuple) blk: {
                const index = std.fmt.parseUnsigned(usize, field.field_name, 10) catch return Error.UnsupportedSabDirectFeature;
                if (index >= expr_ty.tuple.elems.len) return Error.UnsupportedSabDirectFeature;
                break :blk expr_ty.tuple.elems[index];
            } else self.fieldType(expr_ty, field.field_name) orelse return Error.UnsupportedSabDirectFeature;
            const target = try self.genFieldAddress(field);
            const value = try self.genExpr(assign.value);
            try self.emitStore(target.reg, 0, value, try primType(field_ty));
            if (!self.isLocalReg(value)) try self.emitRelease(value);
            if (!self.isLocalReg(target.reg)) try self.emitRelease(target.reg);
            return;
        }

        if (assign.target.* == .index_expr) {
            const idx = assign.target.index_expr;
            const target_ty = self.tc.expr_types.get(idx.target) orelse return Error.MissingType;
            if (target_ty.* != .array) {
                const target_type_name = typeBaseName(target_ty) orelse return Error.UnsupportedSabDirectFeature;
                const rule = self.findStdSurfaceRule(.index_assign, target_type_name, null) orelse return Error.UnsupportedSabDirectFeature;
                const target_reg = try self.genExpr(idx.target);
                const index_reg = try self.genExpr(idx.index);
                const value = try self.genExpr(assign.value);
                try self.emitStdSurfaceRule(rule, .{
                    .receiver = target_reg,
                    .index = index_reg,
                    .value = value,
                    .elem_size = self.elementSlotSize(target_ty),
                    .elem_ty = try self.elementLoadType(target_ty),
                });
                try self.releaseNonLocalTemps(&.{ target_reg, index_reg, value });
                return;
            }
            const target_reg = try self.genExpr(idx.target);
            const value = try self.genExpr(assign.value);
            if (idx.index.* == .literal and idx.index.literal == .int_val) {
                const raw_index = idx.index.literal.int_val;
                if (raw_index < 0) return Error.UnsupportedSabDirectFeature;
                const layout = arrayElementLayout(target_ty.array, @intCast(raw_index)) orelse return Error.UnsupportedSabDirectFeature;
                try self.emitStore(target_reg, layout.offset, value, layout.ty);
            } else {
                const index_reg = try self.genExpr(idx.index);
                const elem_ptr = try self.genArrayElementPtr(target_ty.array, target_reg, index_reg);
                try self.emitStore(elem_ptr.ptr, 0, value, try primType(target_ty.array.elem));
                if (elem_ptr.offset) |offset| try self.emitRelease(offset);
                try self.emitRelease(elem_ptr.ptr);
                if (!self.isLocalReg(index_reg)) try self.emitRelease(index_reg);
            }
            if (!self.isLocalReg(value)) try self.emitRelease(value);
            if (!self.isLocalReg(target_reg)) try self.emitRelease(target_reg);
            return;
        }

        if (assign.target.* != .identifier) return Error.UnsupportedSabDirectFeature;
        const name = assign.target.identifier;
        const value = try self.genExpr(assign.value);
        try self.assignToIdentifier(name, value);
    }

    fn genExpr(self: *Codegen, expr: *ast.Node) anyerror!u32 {
        return switch (expr.*) {
            .literal => |lit| try self.genLiteral(lit),
            .identifier => |name| blk: {
                if (self.closure_param_regs.get(name)) |mapped| break :blk mapped;
                if (self.stackLocal(name)) |slot| {
                    const ty = slot.stack_ty orelse return Error.UnsupportedSabDirectFeature;
                    const dst = try self.intern(try self.newTmp());
                    try self.emitLoad(dst, slot.reg, 0, try primType(ty));
                    break :blk dst;
                }
                if (self.exprHasFnPtrType(expr) and self.tc.funcs.contains(name)) {
                    const dst = try self.intern(try self.newTmp());
                    const vt_name = try self.ensureFunctionPointerVTable(name);
                    try self.emitBorrowSymbol(dst, vt_name);
                    break :blk dst;
                }
                if (self.exprHasFnPtrType(expr)) break :blk self.localReg(name) orelse try self.intern(name);
                if (self.tc.expr_types.get(expr)) |expr_ty| {
                    if (typeBaseName(expr_ty)) |type_name| {
                        if (self.findStdSurfaceRule(.constructor, type_name, name)) |rule| {
                            const dst = try self.intern(try self.newTmp());
                            try self.recordReg(dst);
                            try self.emitStdSurfaceRule(rule, .{
                                .out = dst,
                                .elem_size = self.elementSlotSize(expr_ty),
                            });
                            break :blk dst;
                        }
                    }
                }
                if (self.localReg(name)) |reg| break :blk reg;
                if (self.global_scalar_consts.get(name)) |literal_node| {
                    if (literal_node.* != .literal) return Error.UnsupportedSabDirectFeature;
                    break :blk try self.genLiteral(literal_node.literal);
                }
                break :blk try self.intern(name);
            },
            .binary_expr => |bin| try self.genBinary(bin),
            .call_expr => |call| blk: {
                if (self.tc.fn_ptr_calls.contains(expr)) break :blk try self.genFnPtrCall(call);
                break :blk try self.genCall(expr, call);
            },
            .field_expr => |field| try self.genField(field),
            .struct_literal => |lit| try self.genStructLiteral(lit),
            .tuple_literal => |lit| try self.genTupleLiteral(lit),
            .array_literal => |lit| try self.genArrayLiteral(expr, lit),
            .repeat_array_literal => |lit| try self.genRepeatArrayLiteral(expr, lit),
            .index_expr => |idx| try self.genIndex(idx),
            .if_expr => |ife| try self.genIf(expr, ife),
            .cast_expr => |cast| try self.genCast(cast),
            .borrow_expr => |borrow| try self.genBorrow(borrow),
            .move_expr => |move| try self.genMove(move),
            .deref_expr => |deref| try self.genDeref(expr, deref),
            else => Error.UnsupportedSabDirectFeature,
        };
    }

    fn genLiteral(self: *Codegen, lit: ast.Literal) anyerror!u32 {
        const reg = try self.intern(try self.newTmp());
        try self.recordReg(reg);
        switch (lit) {
            .int_val => |v| try self.emitAssignImm(reg, v),
            .float_val => |v| try self.emitAssignFloat(reg, v),
            .bool_val => |v| try self.emitAssignImm(reg, if (v) 1 else 0),
            else => return Error.UnsupportedSabDirectFeature,
        }
        return reg;
    }

    fn genBinary(self: *Codegen, bin: ast.BinaryExpr) anyerror!u32 {
        // Struct-typed operands (e.g. an `@overload Vec2 { fn +(...) }`) must be
        // lowered field-wise, mirroring the SA-text emitter's
        // `genStructArithmeticExpr`. Without this, the generic path below emits a
        // primitive `op.add` on two struct *pointers* (since `primType` of a
        // struct is `.ptr`), producing a garbage pointer that segfaults on the
        // next field load. If neither operand is a struct this returns null and
        // we fall through to the primitive path.
        if (try self.genStructArithmetic(bin)) |reg| return reg;

        const lhs = try self.genExpr(bin.left);
        const rhs = try self.genExpr(bin.right);
        const dst = try self.intern(try self.newTmp());
        try self.recordReg(dst);
        var item = self.makeInst(.op);
        item.op_kind = try self.opKindForBinary(bin);
        item.operands[0] = .{ .reg = dst };
        item.operands[1] = .{ .reg = lhs };
        item.operands[2] = .{ .reg = rhs };
        try self.appendInst(item);
        try self.releaseNonLocalTemps(&.{ lhs, rhs });
        return dst;
    }

    /// Field-wise lowering of arithmetic on struct-typed operands, mirroring the
    /// SA-text emitter's `genStructArithmeticExpr`. Handles the same matrix:
    /// same-struct `+`/`-`, and scalar `*` in either operand order. Returns null
    /// when neither operand is a struct (caller uses the primitive path); returns
    /// `Error.UnsupportedSabDirectFeature` for struct shapes outside this matrix
    /// so the SA-compatible fallback can take over instead of emitting a bad op.
    fn genStructArithmetic(self: *Codegen, bin: ast.BinaryExpr) anyerror!?u32 {
        const left_ty = self.tc.expr_types.get(bin.left) orelse return null;
        const right_ty = self.tc.expr_types.get(bin.right) orelse return null;
        const left_struct = self.structDeclForType(left_ty);
        const right_struct = self.structDeclForType(right_ty);
        if (left_struct == null and right_struct == null) return null;

        const struct_decl = left_struct orelse right_struct.?;
        if (struct_decl.is_opaque or struct_decl.is_union) return Error.UnsupportedSabDirectFeature;

        const op_kind: inst.OpKind = switch (bin.op) {
            .add => .add,
            .sub => .sub,
            .mul => .mul,
            else => return Error.UnsupportedSabDirectFeature,
        };

        // Same-struct add/sub: field[i] = left.field[i] <op> right.field[i].
        if (left_struct != null and right_struct != null) {
            if (left_struct.? != right_struct.? or !(bin.op == .add or bin.op == .sub)) {
                return Error.UnsupportedSabDirectFeature;
            }
            const result = try self.intern(try self.newTmp());
            try self.emitAlloc(result, structSize(struct_decl));
            const left_reg = try self.genExpr(bin.left);
            const right_reg = try self.genExpr(bin.right);
            for (struct_decl.fields) |field| {
                if (!isNumericType(field.ty)) return Error.UnsupportedSabDirectFeature;
                const layout = try self.fieldLayout(left_ty, field.name);
                const lhs = try self.intern(try self.newTmp());
                const rhs = try self.intern(try self.newTmp());
                const value = try self.intern(try self.newTmp());
                try self.emitLoad(lhs, left_reg, layout.offset, layout.ty);
                try self.emitLoad(rhs, right_reg, layout.offset, layout.ty);
                try self.emitOp(value, op_kind, .{ .reg = lhs }, .{ .reg = rhs });
                try self.emitStore(result, layout.offset, value, layout.ty);
                try self.releaseNonLocalTemps(&.{ lhs, rhs, value });
            }
            try self.releaseNonLocalTemps(&.{ left_reg, right_reg });
            return result;
        }

        // Scalar multiply: struct * scalar or scalar * struct.
        if (bin.op == .mul) {
            const struct_is_left = left_struct != null;
            const scalar_ty = if (struct_is_left) right_ty else left_ty;
            if (!isNumericType(scalar_ty)) return Error.UnsupportedSabDirectFeature;
            const struct_ty = if (struct_is_left) left_ty else right_ty;
            const result = try self.intern(try self.newTmp());
            try self.emitAlloc(result, structSize(struct_decl));
            const struct_reg = try self.genExpr(if (struct_is_left) bin.left else bin.right);
            const scalar_reg = try self.genExpr(if (struct_is_left) bin.right else bin.left);
            for (struct_decl.fields) |field| {
                if (!isNumericType(field.ty)) return Error.UnsupportedSabDirectFeature;
                const layout = try self.fieldLayout(struct_ty, field.name);
                const fld = try self.intern(try self.newTmp());
                const value = try self.intern(try self.newTmp());
                try self.emitLoad(fld, struct_reg, layout.offset, layout.ty);
                // Keep field on the left so non-commutative widths stay stable.
                try self.emitOp(value, .mul, .{ .reg = fld }, .{ .reg = scalar_reg });
                try self.emitStore(result, layout.offset, value, layout.ty);
                try self.releaseNonLocalTemps(&.{ fld, value });
            }
            try self.releaseNonLocalTemps(&.{ struct_reg, scalar_reg });
            return result;
        }

        return Error.UnsupportedSabDirectFeature;
    }

    fn genCast(self: *Codegen, cast: ast.CastExpr) anyerror!u32 {
        const src_ast_ty = self.tc.expr_types.get(cast.expr) orelse return Error.MissingType;
        const src_ty = try primType(src_ast_ty);
        const dst_ty = try primType(cast.ty);
        const src = try self.genExpr(cast.expr);

        if (!isNumericType(src_ast_ty) or !isNumericType(cast.ty)) {
            if (src_ty == .ptr and dst_ty == .ptr) return src;
            return Error.UnsupportedSabDirectFeature;
        }

        const dst = try self.intern(try self.newTmp());
        try self.recordReg(dst);
        var item = self.makeInst(.op);
        item.op_kind = try opKindForCast(src_ty, dst_ty);
        item.operands[0] = .{ .reg = dst };
        item.operands[1] = .{ .reg = src };
        item.operands[2] = .{ .ty = @intFromEnum(dst_ty) };
        try self.appendInst(item);
        if (!self.isLocalReg(src)) try self.emitRelease(src);
        return dst;
    }

    fn emitBorrowReg(self: *Codegen, dst: u32, source: u32, mode: []const u8) !void {
        try self.recordReg(dst);
        var item = self.makeInst(.borrow);
        item.operands[0] = .{ .reg = dst };
        item.operands[1] = .{ .reg = source };
        item.operands[2] = .{ .text = mode };
        item.operands[3] = .{ .cap_prefix = .borrow };
        try self.appendInst(item);
    }

    fn addressWithOffset(self: *Codegen, base: u32, offset: usize) !AddressSource {
        if (offset == 0) return .{ .reg = base };
        const dst = try self.intern(try self.newTmp());
        try self.emitPtrAdd(dst, base, .{ .imm_u64 = @intCast(offset) });
        return .{ .reg = dst };
    }

    fn genFieldAddress(self: *Codegen, field: ast.FieldExpr) anyerror!AddressSource {
        const expr_ty = self.tc.expr_types.get(field.expr) orelse return Error.MissingType;
        const layout = if (expr_ty.* == .tuple) blk: {
            const index = std.fmt.parseUnsigned(usize, field.field_name, 10) catch return Error.UnsupportedSabDirectFeature;
            break :blk tupleFieldLayout(expr_ty.tuple, index) orelse return Error.UnsupportedSabDirectFeature;
        } else try self.fieldLayout(expr_ty, field.field_name);
        const base = try self.genExpr(field.expr);
        return try self.addressWithOffset(base, layout.offset);
    }

    fn genIndexAddress(self: *Codegen, idx: ast.IndexExpr) anyerror!AddressSource {
        const target_ty = self.tc.expr_types.get(idx.target) orelse return Error.MissingType;
        if (target_ty.* != .array) return Error.UnsupportedSabDirectFeature;
        const target_reg = try self.genExpr(idx.target);
        if (idx.index.* == .literal and idx.index.literal == .int_val) {
            const raw_index = idx.index.literal.int_val;
            if (raw_index < 0) return Error.UnsupportedSabDirectFeature;
            const layout = arrayElementLayout(target_ty.array, @intCast(raw_index)) orelse return Error.UnsupportedSabDirectFeature;
            return try self.addressWithOffset(target_reg, layout.offset);
        }

        const index_reg = try self.genExpr(idx.index);
        const elem_ptr = try self.genArrayElementPtr(target_ty.array, target_reg, index_reg);
        if (elem_ptr.offset) |offset| try self.emitRelease(offset);
        if (!self.isLocalReg(index_reg)) try self.emitRelease(index_reg);
        return .{ .reg = elem_ptr.ptr };
    }

    fn genAddressOf(self: *Codegen, expr: *ast.Node) anyerror!AddressSource {
        return switch (expr.*) {
            .identifier => |name| blk: {
                if (self.stackLocal(name)) |slot| break :blk .{ .reg = slot.reg };
                break :blk .{ .reg = try self.genExpr(expr) };
            },
            .deref_expr => |deref| .{ .reg = try self.genExpr(deref.expr) },
            .field_expr => |field| try self.genFieldAddress(field),
            .index_expr => |idx| try self.genIndexAddress(idx),
            else => .{ .reg = try self.genExpr(expr) },
        };
    }

    fn genBorrow(self: *Codegen, borrow: ast.BorrowExpr) anyerror!u32 {
        const source = try self.genAddressOf(borrow.expr);
        const dst = try self.intern(try self.newTmp());
        try self.emitBorrowReg(dst, source.reg, "read");
        return dst;
    }

    fn genMove(self: *Codegen, move: ast.MoveExpr) anyerror!u32 {
        const source = try self.genExpr(move.expr);
        try self.markConsumed(source);
        return source;
    }

    fn genDeref(self: *Codegen, expr: *const ast.Node, deref: ast.DerefExpr) anyerror!u32 {
        const deref_ty = self.tc.expr_types.get(expr) orelse return Error.MissingType;
        const source = try self.genExpr(deref.expr);
        const dst = try self.intern(try self.newTmp());
        try self.emitLoad(dst, source, 0, try primType(deref_ty));
        if (!self.isLocalReg(source)) try self.emitRelease(source);
        return dst;
    }

    fn emitDynNew(self: *Codegen, fat_reg: u32, data_reg: u32, vtable_reg: u32) !void {
        try self.emitStdMacroFragment("sa_std/core/trait_object.sa", "DYN_NEW", &.{
            self.symbols.items[fat_reg],
            self.symbols.items[data_reg],
            self.symbols.items[vtable_reg],
        });
    }

    fn genDynBorrowFromReg(self: *Codegen, source_ty: *const ast.Type, source_reg: u32, trait_name: []const u8) anyerror!u32 {
        const fat_reg = try self.intern(try self.newTmp());
        try self.recordReg(fat_reg);

        if (dynTraitName(source_ty) != null) {
            const data_reg = try self.intern(try self.newTmp());
            const vtable_reg = try self.intern(try self.newTmp());
            try self.recordReg(data_reg);
            try self.recordReg(vtable_reg);
            try self.emitStdMacroFragment("sa_std/core/trait_object.sa", "DYN_GET_DATA", &.{ self.symbols.items[data_reg], self.symbols.items[source_reg] });
            try self.emitStdMacroFragment("sa_std/core/trait_object.sa", "DYN_GET_VTABLE", &.{ self.symbols.items[vtable_reg], self.symbols.items[source_reg] });
            try self.emitDynNew(fat_reg, data_reg, vtable_reg);
            try self.emitRelease(vtable_reg);
            try self.emitRelease(data_reg);
        } else {
            const type_name = concreteTypeName(source_ty) orelse return Error.UnsupportedSabDirectFeature;
            const vt_name = try self.vtableName(trait_name, type_name);
            const vtable_reg = try self.intern(try self.newTmp());
            try self.emitBorrowSymbol(vtable_reg, vt_name);
            try self.emitDynNew(fat_reg, source_reg, vtable_reg);
            try self.emitRelease(vtable_reg);
        }

        if (!self.isLocalReg(source_reg)) try self.emitRelease(source_reg);
        return fat_reg;
    }

    fn genDynBorrowArg(self: *Codegen, arg: *const ast.Node, trait_name: []const u8) anyerror!u32 {
        const source_expr = if (arg.* == .borrow_expr) arg.borrow_expr.expr else arg;
        const source_ty = self.tc.expr_types.get(source_expr) orelse return Error.MissingType;
        const source_reg = try self.genExpr(@constCast(source_expr));
        return try self.genDynBorrowFromReg(source_ty, source_reg, trait_name);
    }

    fn genMacroDynBorrowArg(self: *Codegen, arg: *const ast.Node, ctx: *MacroExpansionContext, trait_name: []const u8) anyerror!u32 {
        const source_expr = if (arg.* == .borrow_expr) arg.borrow_expr.expr else arg;
        const source_ty = (try self.macroExprType(@constCast(source_expr), ctx)) orelse return Error.MissingType;
        const source_reg = try self.genMacroExpr(@constCast(source_expr), ctx);
        return try self.genDynBorrowFromReg(source_ty, source_reg, trait_name);
    }

    fn genDynMethodCall(self: *Codegen, expr: *const ast.Node, call: ast.CallExpr) anyerror!?u32 {
        const trait_name = self.tc.dyn_call_traits.get(expr) orelse return null;
        if (call.args.len != 1) return Error.UnsupportedSabDirectFeature;
        const slot = lowering_rules.dynMethodSlot(self.tc, trait_name, call.func_name) orelse return Error.UnsupportedSabDirectFeature;
        const receiver_reg = try self.genExpr(@constCast(call.args[0]));
        const data_reg = try self.intern(try self.newTmp());
        const vtable_reg = try self.intern(try self.newTmp());
        const fn_reg = try self.intern(try self.newTmp());
        const dst = try self.intern(try self.newTmp());
        try self.recordReg(data_reg);
        try self.recordReg(vtable_reg);
        try self.recordReg(fn_reg);
        try self.recordReg(dst);
        try self.emitStdMacroFragment("sa_std/core/trait_object.sa", "DYN_GET_DATA", &.{ self.symbols.items[data_reg], self.symbols.items[receiver_reg] });
        try self.emitStdMacroFragment("sa_std/core/trait_object.sa", "DYN_GET_VTABLE", &.{ self.symbols.items[vtable_reg], self.symbols.items[receiver_reg] });
        try self.emitLoad(fn_reg, vtable_reg, slot, .ptr);

        var body = std.ArrayList(u8).init(self.allocator);
        try body.writer().print("{s}(&{s})", .{ self.symbols.items[fn_reg], self.symbols.items[data_reg] });
        var item = self.makeInst(.call_indirect);
        item.operands[0] = .{ .reg = dst };
        item.operands[1] = .{ .text = try body.toOwnedSlice() };
        try self.appendInst(item);

        try self.emitRelease(fn_reg);
        try self.emitRelease(vtable_reg);
        try self.emitRelease(data_reg);
        if (!self.isLocalReg(receiver_reg)) try self.emitRelease(receiver_reg);
        return dst;
    }

    fn escapedClosureEntryForThreadSpawn(self: *Codegen, expr: *const ast.Node, call: ast.CallExpr) anyerror!EscapedClosureEntry {
        if (self.escaped_closure_entries.get(expr)) |entry| return entry;
        const closure = closureLiteralFromExpr(call.args[0]) orelse return Error.UnsupportedSabDirectFeature;
        if (closure.params.len != 0) return Error.UnsupportedSabDirectFeature;
        const join_ty = self.tc.expr_types.get(expr) orelse return Error.MissingType;
        const ret_ty = joinHandleInnerType(join_ty) orelse return Error.UnsupportedSabDirectFeature;

        const idx = self.escaped_closure_idx;
        self.escaped_closure_idx += 1;
        const captures = try self.collectEscapedClosureCaptures(closure);
        var slot_size: usize = 16;
        for (captures) |capture| slot_size = @max(slot_size, capture.offset + 8);

        const entry = EscapedClosureEntry{
            .worker_name = try std.fmt.allocPrint(self.allocator, "sla_thread_worker_{}", .{idx}),
            .spawn_name = try std.fmt.allocPrint(self.allocator, "sla_thread_spawn_{}", .{idx}),
            .vtable_name = try std.fmt.allocPrint(self.allocator, "SLA_THREAD_VT_{}", .{idx}),
            .closure = closure,
            .ret_ty = ret_ty,
            .captures = captures,
            .slot_size = slot_size,
        };
        try self.appendVTableConst(entry.vtable_name, entry.worker_name);
        try self.escaped_closure_entries.put(expr, entry);
        return entry;
    }

    fn genThreadSpawn(self: *Codegen, expr: *const ast.Node, call: ast.CallExpr) anyerror!u32 {
        const entry = try self.escapedClosureEntryForThreadSpawn(expr, call);
        const slot = try self.intern(try self.newTmp());
        try self.emitAlloc(slot, entry.slot_size);
        const zero = try self.intern(try self.newTmp());
        try self.emitAssignImm(zero, 0);
        try self.emitStore(slot, 0, zero, .i32);
        try self.emitStore(slot, 8, zero, try primType(entry.ret_ty));
        try self.emitRelease(zero);

        for (entry.captures) |capture| {
            const capture_reg = self.localReg(capture.name) orelse return Error.UnsupportedSabDirectFeature;
            try self.emitStore(slot, capture.offset, capture_reg, .ptr);
        }

        const handle = try self.intern(try self.newTmp());
        const body = try std.fmt.allocPrint(self.allocator, "@{s}(*{s})", .{ entry.spawn_name, self.symbols.items[slot] });
        try self.emitCallBody(handle, body);
        try self.emitStore(slot, 0, handle, .i32);
        try self.emitRelease(handle);
        return slot;
    }

    fn genJoinHandleJoin(self: *Codegen, expr: *const ast.Node, call: ast.CallExpr) anyerror!?u32 {
        if (call.associated_target != null or !std.mem.eql(u8, call.func_name, "join") or call.args.len != 1) return null;
        const receiver_ty = self.tc.expr_types.get(call.args[0]) orelse return null;
        const inner_ty = joinHandleInnerType(receiver_ty) orelse return null;
        _ = expr;

        const recv_reg = try self.genExpr(@constCast(call.args[0]));
        const handle = try self.intern(try self.newTmp());
        const status = try self.intern(try self.newTmp());
        const is_ok = try self.intern(try self.newTmp());
        const result_reg = try self.intern(try self.newTmp());
        try self.emitLoad(handle, recv_reg, 0, .i32);

        var join_args = std.ArrayList([]const u8).init(self.allocator);
        defer join_args.deinit();
        try join_args.append(self.symbols.items[status]);
        try join_args.append(self.symbols.items[handle]);
        try join_args.append(try std.fmt.allocPrint(self.allocator, "*{s}", .{self.symbols.items[recv_reg]}));
        try self.emitStdMacroFragment("sa_std/thread.sa", "THREAD_JOIN_STATUS", join_args.items);

        var drop_args = std.ArrayList([]const u8).init(self.allocator);
        defer drop_args.deinit();
        try drop_args.append(self.symbols.items[handle]);
        try self.emitStdMacroFragment("sa_std/thread.sa", "THREAD_DROP", drop_args.items);

        try self.emitOp(is_ok, .eq, .{ .reg = status }, .{ .imm_i64 = 0 });
        const ok_label = try self.newLabel("L_THREAD_JOIN_OK");
        const err_label = try self.newLabel("L_THREAD_JOIN_ERR");
        const end_label = try self.newLabel("L_THREAD_JOIN_END");
        var br = self.makeInst(.br);
        br.operands[0] = .{ .reg = is_ok };
        br.operands[1] = .{ .label = try self.intern(ok_label) };
        br.operands[2] = .{ .label = try self.intern(ok_label) };
        br.operands[3] = .{ .label = try self.intern(err_label) };
        try self.appendInst(br);

        try self.emitLabel(ok_label);
        try self.emitBranchRelease(is_ok);
        const value = try self.intern(try self.newTmp());
        try self.emitLoad(value, recv_reg, 8, try primType(inner_ty));
        var ok_args = std.ArrayList([]const u8).init(self.allocator);
        defer ok_args.deinit();
        try ok_args.append(self.symbols.items[result_reg]);
        try ok_args.append(self.symbols.items[value]);
        try self.emitStdMacroFragment("sa_std/core/result.sa", "RESULT_NEW_OK", ok_args.items);
        try self.emitRelease(value);
        try self.emitJmp(end_label);

        try self.emitLabel(err_label);
        try self.emitBranchRelease(is_ok);
        const err_value = try self.intern(try self.newTmp());
        try self.emitOp(err_value, .add, .{ .reg = status }, .{ .imm_i64 = 0 });
        var err_args = std.ArrayList([]const u8).init(self.allocator);
        defer err_args.deinit();
        try err_args.append(self.symbols.items[result_reg]);
        try err_args.append(self.symbols.items[err_value]);
        try self.emitStdMacroFragment("sa_std/core/result.sa", "RESULT_NEW_ERR", err_args.items);
        try self.emitRelease(err_value);
        try self.emitJmp(end_label);

        try self.emitLabel(end_label);
        try self.emitRelease(status);
        try self.emitRelease(handle);
        try self.emitRelease(recv_reg);
        return result_reg;
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
            if (std.mem.eql(u8, call.func_name, "stack_alloc")) {
                const dst = try self.intern(try self.newTmp());
                try self.emitStackAlloc(dst, try stackAllocSize(call));
                try self.pushStackAllocLocal(self.symbols.items[dst], dst);
                return dst;
            }
            if (self.closure_bindings.get(call.func_name)) |closure| return try self.genClosureCall(closure, call);
            if (self.tc.macros.get(call.func_name)) |macro_decl| {
                try self.genUserMacroCall(macro_decl, call);
                const sentinel = try self.intern(try self.newTmp());
                try self.emitAssignImm(sentinel, 0);
                return sentinel;
            }
        }
        if (isThreadSpawnCall(call)) return try self.genThreadSpawn(expr, call);
        if (try self.genJoinHandleJoin(expr, call)) |reg| return reg;
        if (try self.genDynMethodCall(expr, call)) |reg| return reg;
        if (try self.genStdSurfaceCall(expr, call)) |reg| return reg;
        const call_plan = lowering_rules.planStaticCall(self.tc, expr, call) orelse return Error.UnsupportedSabDirectFeature;
        return try self.emitPlannedStaticCall(call_plan, call);
    }

    /// Emit a planned static call: `dst = call @<symbol>(args...)`, materializing
    /// each argument through the shared `CallArgMaterializationPlan`. Shared by
    /// ordinary calls (`genCall`) and resolved operator-overload binaries
    /// (`genBinary`), so both consult the same `resolved_call_symbols` contract
    /// the SA-text emitter uses.
    fn emitPlannedStaticCall(
        self: *Codegen,
        call_plan: lowering_rules.StaticCallPlan,
        call: ast.CallExpr,
    ) anyerror!u32 {
        const dst = try self.intern(try self.newTmp());
        try self.recordReg(dst);
        const lowered = try self.loweredFuncSymbol(call_plan.target_symbol);
        var text = std.ArrayList(u8).init(self.allocator);
        var release_regs = std.ArrayList(u32).init(self.allocator);
        defer release_regs.deinit();
        const maybe_func = self.tc.funcs.get(call_plan.target_symbol);
        try text.writer().print("@{s}(", .{lowered});
        for (call.args, 0..) |arg, i| {
            const param = if (maybe_func) |func| if (i < func.params.len) func.params[i] else null else null;
            const lowered_arg = try self.genPlannedSabCallArg(arg, call_plan, param, i, call.associated_target == null);
            try release_regs.append(lowered_arg.release_reg);
            if (i > 0) try text.appendSlice(", ");
            try text.appendSlice(lowered_arg.operand);
        }
        try text.append(')');
        var item = self.makeInst(.call);
        item.operands[0] = .{ .reg = dst };
        item.operands[1] = .{ .text = try text.toOwnedSlice() };
        try self.appendInst(item);
        try self.releaseNonLocalTemps(release_regs.items);
        return dst;
    }

    const SabLoweredCallArg = struct {
        operand: []const u8,
        release_reg: u32,
    };

    fn generatedFnPtrIdentifierArg(self: *Codegen, arg: *const ast.Node) bool {
        return arg.* == .identifier and self.tc.funcs.contains(arg.identifier) and self.exprHasFnPtrType(arg);
    }

    fn generatedScalarConstIdentifierArg(self: *Codegen, arg: *const ast.Node) bool {
        return arg.* == .identifier and self.global_scalar_consts.contains(arg.identifier);
    }

    fn genPlannedSabCallArg(
        self: *Codegen,
        arg: *const ast.Node,
        call_plan: lowering_rules.StaticCallPlan,
        param: ?ast.Param,
        arg_index: usize,
        auto_borrow_receiver: bool,
    ) anyerror!SabLoweredCallArg {
        const materialization = lowering_rules.planCallArgMaterialization(arg, .{
            .param = param,
            .arg_ty = self.tc.expr_types.get(arg),
            .arg_index = arg_index,
            .auto_borrow_receiver = auto_borrow_receiver,
            .array_to_slice_borrow = self.tc.array_to_slice_borrow_args.contains(arg),
            .dyn_borrow_trait_name = self.tc.dyn_borrow_args.get(arg),
            .copy_struct_value = if (param) |p| !p.is_borrow and !p.is_move and arg.* == .identifier and self.typeIsCopyStruct(p.ty) else false,
            .generated_fn_ptr_identifier = self.generatedFnPtrIdentifierArg(arg),
            .generated_scalar_const_identifier = self.generatedScalarConstIdentifierArg(arg),
        });

        return switch (materialization.kind) {
            .array_to_slice_borrow => Error.UnsupportedSabDirectFeature,
            .dyn_borrow => blk: {
                const trait_name = materialization.dyn_borrow_trait_name orelse return Error.UnsupportedSabDirectFeature;
                const fat_reg = try self.genDynBorrowArg(arg, trait_name);
                break :blk .{
                    .operand = try std.fmt.allocPrint(self.allocator, "&{s}", .{self.symbols.items[fat_reg]}),
                    .release_reg = fat_reg,
                };
            },
            .copy_struct_value => blk: {
                const source_reg = try self.genExpr(@constCast(arg));
                const copied = try self.genCopyValue(source_reg, (param orelse return Error.UnsupportedSabDirectFeature).ty);
                break :blk .{ .operand = self.symbols.items[copied], .release_reg = copied };
            },
            .auto_borrow => blk: {
                const arg_reg = try self.genExpr(@constCast(arg));
                break :blk .{
                    .operand = try std.fmt.allocPrint(self.allocator, "&{s}", .{self.symbols.items[arg_reg]}),
                    .release_reg = arg_reg,
                };
            },
            .value => blk: {
                const arg_reg = try self.genExpr(@constCast(arg));
                if (call_plan.argPrefix(arg)) |prefix| {
                    break :blk .{
                        .operand = try std.fmt.allocPrint(self.allocator, "{c}{s}", .{ prefix, self.symbols.items[arg_reg] }),
                        .release_reg = arg_reg,
                    };
                }
                break :blk .{ .operand = self.symbols.items[arg_reg], .release_reg = arg_reg };
            },
        };
    }

    fn genPlannedSabMacroCallArg(
        self: *Codegen,
        arg: *const ast.Node,
        effective_arg: *const ast.Node,
        ctx: *MacroExpansionContext,
        call_plan: lowering_rules.StaticCallPlan,
        param: ?ast.Param,
        arg_index: usize,
        auto_borrow_receiver: bool,
    ) anyerror!SabLoweredCallArg {
        const materialization = lowering_rules.planCallArgMaterialization(effective_arg, .{
            .param = param,
            .arg_ty = self.tc.expr_types.get(effective_arg),
            .arg_index = arg_index,
            .auto_borrow_receiver = auto_borrow_receiver,
            .array_to_slice_borrow = self.tc.array_to_slice_borrow_args.contains(effective_arg),
            .dyn_borrow_trait_name = self.tc.dyn_borrow_args.get(effective_arg),
            .copy_struct_value = if (param) |p| !p.is_borrow and !p.is_move and effective_arg.* == .identifier and self.typeIsCopyStruct(p.ty) else false,
            .generated_fn_ptr_identifier = self.generatedFnPtrIdentifierArg(effective_arg),
            .generated_scalar_const_identifier = self.generatedScalarConstIdentifierArg(effective_arg),
        });

        return switch (materialization.kind) {
            .array_to_slice_borrow => Error.UnsupportedSabDirectFeature,
            .dyn_borrow => blk: {
                const trait_name = materialization.dyn_borrow_trait_name orelse return Error.UnsupportedSabDirectFeature;
                const fat_reg = try self.genMacroDynBorrowArg(arg, ctx, trait_name);
                break :blk .{
                    .operand = try std.fmt.allocPrint(self.allocator, "&{s}", .{self.symbols.items[fat_reg]}),
                    .release_reg = fat_reg,
                };
            },
            .copy_struct_value => blk: {
                const source_reg = try self.genMacroExpr(@constCast(arg), ctx);
                const copied = try self.genCopyValue(source_reg, (param orelse return Error.UnsupportedSabDirectFeature).ty);
                break :blk .{ .operand = self.symbols.items[copied], .release_reg = copied };
            },
            .auto_borrow => blk: {
                const arg_reg = try self.genMacroExpr(@constCast(arg), ctx);
                break :blk .{
                    .operand = try std.fmt.allocPrint(self.allocator, "&{s}", .{self.symbols.items[arg_reg]}),
                    .release_reg = arg_reg,
                };
            },
            .value => blk: {
                const arg_reg = try self.genMacroExpr(@constCast(arg), ctx);
                if (call_plan.argPrefix(effective_arg)) |prefix| {
                    break :blk .{
                        .operand = try std.fmt.allocPrint(self.allocator, "{c}{s}", .{ prefix, self.symbols.items[arg_reg] }),
                        .release_reg = arg_reg,
                    };
                }
                break :blk .{ .operand = self.symbols.items[arg_reg], .release_reg = arg_reg };
            },
        };
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

    fn genWhile(self: *Codegen, w: ast.WhileStmt) anyerror!void {
        if (w.let_pattern != null) return Error.UnsupportedSabDirectFeature;
        const head_label = try self.newLabel("L_WHILE_HEAD");
        const body_label = try self.newLabel("L_WHILE_BODY");
        const exit_label = try self.newLabel("L_WHILE_EXIT");

        try self.emitJmp(head_label);
        try self.emitLabel(head_label);
        const cond = try self.genExpr(w.cond);
        var br = self.makeInst(.br);
        br.operands[0] = .{ .reg = cond };
        br.operands[1] = .{ .label = try self.intern(body_label) };
        br.operands[2] = .{ .label = try self.intern(body_label) };
        br.operands[3] = .{ .label = try self.intern(exit_label) };
        try self.appendInst(br);

        // Scope the loop body's locals/release state. A `let` declared inside
        // the body (e.g. `let next = ...`) must not leak past the loop: after
        // the loop, code such as a trailing `return` runs `releaseOpenLocals`,
        // which would otherwise emit `release next` on the zero-iteration path
        // where `next` was never assigned (UnknownRegister at SAB verify time).
        // The body's releases likewise belong to the back-edge path, not the
        // exit path, so the post-loop release state is restored to pre-loop.
        const body_locals_len = self.locals.items.len;
        var pre_released = try self.released_regs.clone();
        defer pre_released.deinit();

        try self.emitLabel(body_label);
        if (!self.isLocalReg(cond)) try self.emitBranchRelease(cond);
        try self.genBlock(w.body);
        if (!self.lastIsTerminator()) try self.emitJmp(head_label);

        self.popLocalsTo(body_locals_len);
        try self.restoreReleased(&pre_released);

        try self.emitLabel(exit_label);
        if (!self.isLocalReg(cond)) try self.emitBranchRelease(cond);
    }

    fn genFor(self: *Codegen, f: ast.ForStmt) anyerror!void {
        const end_expr = f.end orelse return Error.UnsupportedSabDirectFeature;
        const old_locals = self.locals.items.len;
        defer self.popLocalsTo(old_locals);

        const counter_slot = try self.intern(try self.newTmp());
        try self.emitStackAlloc(counter_slot, 8);
        const start_reg = try self.genExpr(f.start);
        const end_reg = try self.genExpr(end_expr);
        try self.emitStore(counter_slot, 0, start_reg, .i64);
        if (!self.isLocalReg(start_reg)) try self.emitRelease(start_reg);

        const head_label = try self.newLabel("L_FOR_HEAD");
        const body_label = try self.newLabel("L_FOR_BODY");
        const cont_label = try self.newLabel("L_FOR_CONTINUE");
        const exit_label = try self.newLabel("L_FOR_EXIT");

        try self.emitJmp(head_label);
        try self.emitLabel(head_label);
        const index_reg = try self.intern(try self.newTmp());
        try self.emitLoad(index_reg, counter_slot, 0, .i64);
        const cond = try self.intern(try self.newTmp());
        try self.emitOp(cond, .slt, .{ .reg = index_reg }, .{ .reg = end_reg });

        var br = self.makeInst(.br);
        br.operands[0] = .{ .reg = cond };
        br.operands[1] = .{ .label = try self.intern(body_label) };
        br.operands[2] = .{ .label = try self.intern(body_label) };
        br.operands[3] = .{ .label = try self.intern(exit_label) };
        try self.appendInst(br);

        try self.emitLabel(body_label);
        try self.emitBranchRelease(cond);
        try self.pushLocal(f.var_name, index_reg, false);
        try self.genBlock(f.body);
        if (!self.lastIsTerminator()) try self.emitJmp(cont_label);

        try self.emitLabel(cont_label);
        const next = try self.intern(try self.newTmp());
        try self.emitOp(next, .add, .{ .reg = index_reg }, .{ .imm_i64 = 1 });
        try self.emitStore(counter_slot, 0, next, .i64);
        try self.emitRelease(next);
        if (!self.released_regs.contains(index_reg)) try self.emitRelease(index_reg);
        try self.emitJmp(head_label);

        try self.emitLabel(exit_label);
        try self.emitBranchRelease(cond);
        if (!self.isLocalReg(end_reg)) try self.emitRelease(end_reg);
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

        if (self.tc.expr_types.get(expr)) |expr_ty| {
            if (typeBaseName(expr_ty)) |type_name| {
                if (self.findStdSurfaceRule(.constructor, type_name, call.func_name)) |rule| {
                    const value_reg = if (call.args.len > 0) try self.genExpr(@constCast(call.args[0])) else null;
                    const dst = try self.intern(try self.newTmp());
                    try self.recordReg(dst);
                    try self.emitStdSurfaceRule(rule, .{
                        .out = dst,
                        .value = value_reg,
                        .elem_size = self.elementSlotSize(expr_ty),
                    });
                    if (value_reg) |reg| if (!self.isLocalReg(reg)) try self.emitRelease(reg);
                    return dst;
                }
            }
        }

        if (call.args.len == 0) return null;
        const receiver_ty = self.tc.expr_types.get(call.args[0]) orelse return null;
        const receiver_type_name = typeBaseName(receiver_ty) orelse return null;
        if (self.findStdSurfaceRule(.function, receiver_type_name, call.func_name)) |rule| {
            const receiver_reg = try self.genExpr(@constCast(call.args[0]));
            const dst = try self.intern(try self.newTmp());
            try self.recordReg(dst);
            try self.emitStdSurfaceRule(rule, .{
                .out = dst,
                .receiver = receiver_reg,
                .elem_size = self.elementSlotSize(receiver_ty),
            });
            try self.releaseNonLocalTemps(&.{receiver_reg});
            return dst;
        }
        if (self.findStdSurfaceRule(.fallible_method, receiver_type_name, call.func_name)) |rule| {
            const receiver_reg = try self.genExpr(@constCast(call.args[0]));
            const arg_reg = if (call.args.len > 1) try self.genExpr(@constCast(call.args[1])) else null;
            const ok_reg = try self.intern(try self.newTmp());
            const dst = try self.intern(try self.newTmp());
            try self.recordReg(ok_reg);
            try self.recordReg(dst);
            try self.emitStdSurfaceRule(rule, .{
                .out = dst,
                .ok = ok_reg,
                .receiver = receiver_reg,
                .value = arg_reg,
                .index = arg_reg,
                .elem_size = self.elementSlotSize(receiver_ty),
            });

            const ok_label = try self.newLabel("L_STD_SURFACE_OK");
            const fail_label = try self.newLabel("L_STD_SURFACE_FAIL");
            var br = self.makeInst(.br);
            br.operands[0] = .{ .reg = ok_reg };
            br.operands[1] = .{ .label = try self.intern(ok_label) };
            br.operands[2] = .{ .label = try self.intern(ok_label) };
            br.operands[3] = .{ .label = try self.intern(fail_label) };
            try self.appendInst(br);

            try self.emitLabel(fail_label);
            if (!self.isLocalReg(ok_reg)) try self.emitBranchRelease(ok_reg);
            try self.emitPanicCode(rule.panic_code orelse return Error.UnsupportedSabDirectFeature);

            try self.emitLabel(ok_label);
            if (!self.isLocalReg(ok_reg)) try self.emitBranchRelease(ok_reg);
            var release_regs = std.ArrayList(u32).init(self.allocator);
            defer release_regs.deinit();
            try release_regs.append(receiver_reg);
            if (arg_reg) |reg| try release_regs.append(reg);
            try self.releaseNonLocalTemps(release_regs.items);
            return dst;
        }
        const rule = self.findStdSurfaceRule(.method, receiver_type_name, call.func_name) orelse return null;
        const receiver_reg = try self.genExpr(@constCast(call.args[0]));
        const value_reg = if (call.args.len > 1) try self.genExpr(@constCast(call.args[1])) else null;
        const has_out = stdSurfaceRuleHasArg(rule, .out);
        const dst = if (has_out) try self.intern(try self.newTmp()) else null;
        if (dst) |reg| try self.recordReg(reg);
        try self.emitStdSurfaceRule(rule, .{
            .out = dst,
            .receiver = receiver_reg,
            .value = value_reg,
            .elem_size = self.elementSlotSize(receiver_ty),
        });
        var release_regs = std.ArrayList(u32).init(self.allocator);
        defer release_regs.deinit();
        try release_regs.append(receiver_reg);
        if (value_reg) |reg| try release_regs.append(reg);
        try self.releaseNonLocalTemps(release_regs.items);

        if (dst) |reg| return reg;

        const sentinel = try self.intern(try self.newTmp());
        try self.recordReg(sentinel);
        try self.emitAssignImm(sentinel, 0);
        return sentinel;
    }

    fn genIndex(self: *Codegen, idx: ast.IndexExpr) anyerror!u32 {
        const target_ty = self.tc.expr_types.get(idx.target) orelse return Error.MissingType;
        if (target_ty.* == .array) {
            const target_reg = try self.genExpr(idx.target);
            const dst = try self.intern(try self.newTmp());
            if (idx.index.* == .literal and idx.index.literal == .int_val) {
                const raw_index = idx.index.literal.int_val;
                if (raw_index < 0) return Error.UnsupportedSabDirectFeature;
                const layout = arrayElementLayout(target_ty.array, @intCast(raw_index)) orelse return Error.UnsupportedSabDirectFeature;
                try self.emitLoad(dst, target_reg, layout.offset, layout.ty);
            } else {
                const index_reg = try self.genExpr(idx.index);
                const elem_ptr = try self.genArrayElementPtr(target_ty.array, target_reg, index_reg);
                try self.emitLoad(dst, elem_ptr.ptr, 0, try primType(target_ty.array.elem));
                if (elem_ptr.offset) |offset| try self.emitRelease(offset);
                try self.emitRelease(elem_ptr.ptr);
                if (!self.isLocalReg(index_reg)) try self.emitRelease(index_reg);
            }
            if (!self.isLocalReg(target_reg)) try self.emitRelease(target_reg);
            return dst;
        }

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
            .elem_ty = try self.elementLoadType(target_ty),
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

    fn genCopyValue(self: *Codegen, source: u32, ty: *const ast.Type) anyerror!u32 {
        const decl = self.structDeclForType(ty) orelse return Error.UnsupportedSabDirectFeature;
        if (!self.typeHasCopyDerive(ty) or decl.is_opaque or decl.is_union) return Error.UnsupportedSabDirectFeature;

        const dst = try self.intern(try self.newTmp());
        try self.emitAlloc(dst, structSize(decl));
        for (decl.fields) |field| {
            const layout = try self.fieldLayout(ty, field.name);
            const field_reg = try self.intern(try self.newTmp());
            try self.emitLoad(field_reg, source, layout.offset, layout.ty);
            if (self.structDeclForType(field.ty) != null) {
                const copied_field = try self.genCopyValue(field_reg, field.ty);
                try self.emitStore(dst, layout.offset, copied_field, layout.ty);
                try self.emitRelease(copied_field);
                try self.emitRelease(field_reg);
            } else {
                try self.emitStore(dst, layout.offset, field_reg, layout.ty);
                try self.emitRelease(field_reg);
            }
        }
        return dst;
    }

    fn genTupleLiteral(self: *Codegen, lit: ast.TupleLiteral) anyerror!u32 {
        if (lit.elements.len == 0) return Error.UnsupportedSabDirectFeature;
        const elem_tys = try self.allocator.alloc(*ast.Type, lit.elements.len);
        for (lit.elements, 0..) |elem, idx| {
            elem_tys[idx] = self.tc.expr_types.get(elem) orelse return Error.MissingType;
        }
        const tuple_ty = ast.TupleType{ .elems = elem_tys };
        const dst = try self.intern(try self.newTmp());
        try self.emitAlloc(dst, tupleSize(tuple_ty));
        for (lit.elements, 0..) |elem, idx| {
            const layout = tupleFieldLayout(tuple_ty, idx) orelse return Error.UnsupportedSabDirectFeature;
            const value = try self.genExpr(elem);
            try self.emitStore(dst, layout.offset, value, layout.ty);
            if (!self.isLocalReg(value)) try self.emitRelease(value);
        }
        return dst;
    }

    fn genArrayLiteral(self: *Codegen, expr: *const ast.Node, lit: ast.ArrayLiteral) anyerror!u32 {
        const arr_ty = self.tc.expr_types.get(expr) orelse return Error.MissingType;
        if (arr_ty.* != .array or arr_ty.array.len != lit.elements.len) return Error.UnsupportedSabDirectFeature;

        const dst = try self.intern(try self.newTmp());
        try self.emitAlloc(dst, arraySize(arr_ty.array));
        for (lit.elements, 0..) |elem, idx| {
            const layout = arrayElementLayout(arr_ty.array, idx) orelse return Error.UnsupportedSabDirectFeature;
            const value = try self.genExpr(elem);
            try self.emitStore(dst, layout.offset, value, layout.ty);
            if (!self.isLocalReg(value)) try self.emitRelease(value);
        }
        return dst;
    }

    fn genRepeatArrayLiteral(self: *Codegen, expr: *const ast.Node, lit: ast.RepeatArrayLiteral) anyerror!u32 {
        const arr_ty = self.tc.expr_types.get(expr) orelse return Error.MissingType;
        if (arr_ty.* != .array or arr_ty.array.len != lit.len) return Error.UnsupportedSabDirectFeature;
        _ = try primType(arr_ty.array.elem);

        const dst = try self.intern(try self.newTmp());
        try self.emitAlloc(dst, arraySize(arr_ty.array));
        const value = try self.genExpr(lit.value);
        for (0..lit.len) |idx| {
            const layout = arrayElementLayout(arr_ty.array, idx) orelse return Error.UnsupportedSabDirectFeature;
            try self.emitStore(dst, layout.offset, value, layout.ty);
        }
        if (!self.isLocalReg(value)) try self.emitRelease(value);
        return dst;
    }

    fn genField(self: *Codegen, field: ast.FieldExpr) anyerror!u32 {
        const expr_ty = self.tc.expr_types.get(field.expr) orelse return Error.MissingType;
        if (expr_ty.* == .tuple) {
            const index = std.fmt.parseUnsigned(usize, field.field_name, 10) catch return Error.UnsupportedSabDirectFeature;
            const layout = tupleFieldLayout(expr_ty.tuple, index) orelse return Error.UnsupportedSabDirectFeature;
            const base = try self.genExpr(field.expr);
            const dst = try self.intern(try self.newTmp());
            try self.emitLoad(dst, base, layout.offset, layout.ty);
            if (!self.isLocalReg(base)) try self.emitRelease(base);
            return dst;
        }
        const layout = try self.fieldLayout(expr_ty, field.field_name);
        _ = self.fieldType(expr_ty, field.field_name) orelse return Error.UnsupportedSabDirectFeature;

        const base = try self.genExpr(field.expr);
        const dst = try self.intern(try self.newTmp());
        try self.emitLoad(dst, base, layout.offset, layout.ty);
        if (!self.isLocalReg(base)) try self.emitRelease(base);
        return dst;
    }

    fn genBlockTailValueStore(self: *Codegen, block: []const *ast.Node, target: u32, target_ty: *const ast.Type) anyerror!bool {
        const tail = blockTailExpr(block) orelse return Error.UnsupportedSabDirectFeature;
        for (block[0 .. block.len - 1]) |stmt| {
            try self.genStmt(stmt);
            if (self.lastIsTerminator()) return true;
        }
        const value = try self.genExpr(tail);
        try self.emitStore(target, 0, value, try primType(target_ty));
        if (!self.isLocalReg(value)) try self.emitRelease(value);
        return false;
    }

    fn genIfValue(self: *Codegen, ife: ast.IfExpr, else_block: []const *ast.Node, result_ty: *const ast.Type) anyerror!u32 {
        if (ife.let_chain != null) return Error.UnsupportedSabDirectFeature;
        const cond = try self.genExpr(ife.cond);
        const result_slot = try self.intern(try self.newTmp());
        try self.emitAlloc(result_slot, typeSize(result_ty));
        const then_label = try self.newLabel("L_THEN");
        const else_label = try self.newLabel("L_ELSE");
        const merge_label = try self.newLabel("L_MERGE");
        var br = self.makeInst(.br);
        br.operands[0] = .{ .reg = cond };
        br.operands[1] = .{ .label = try self.intern(then_label) };
        br.operands[2] = .{ .label = try self.intern(then_label) };
        br.operands[3] = .{ .label = try self.intern(else_label) };
        try self.appendInst(br);

        // Scope each branch's locals/release state; see genIfStatement.
        const branch_locals_len = self.locals.items.len;
        var pre_released = try self.released_regs.clone();
        defer pre_released.deinit();

        try self.emitLabel(then_label);
        if (!self.isLocalReg(cond)) try self.emitBranchRelease(cond);
        const then_terminated = try self.genBlockTailValueStore(ife.then_block, result_slot, result_ty);
        if (!then_terminated) try self.emitJmp(merge_label);
        var then_released = try self.released_regs.clone();
        defer then_released.deinit();

        self.popLocalsTo(branch_locals_len);
        try self.restoreReleased(&pre_released);

        try self.emitLabel(else_label);
        if (!self.isLocalReg(cond)) try self.emitBranchRelease(cond);
        const else_terminated = try self.genBlockTailValueStore(else_block, result_slot, result_ty);
        if (!else_terminated) try self.emitJmp(merge_label);
        var else_released = try self.released_regs.clone();
        defer else_released.deinit();

        self.popLocalsTo(branch_locals_len);
        try self.setMergeReleased(then_terminated, &then_released, else_terminated, &else_released, &pre_released);

        if (!then_terminated or !else_terminated) {
            try self.emitLabel(merge_label);
            const result = try self.intern(try self.newTmp());
            try self.emitLoad(result, result_slot, 0, try primType(result_ty));
            try self.emitRelease(result_slot);
            return result;
        }

        const result = try self.intern(try self.newTmp());
        try self.recordReg(result);
        return result;
    }

    fn genIfStatement(self: *Codegen, ife: ast.IfExpr) anyerror!u32 {
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

        // Scope each branch's `self.locals` and `released_regs` so a `let`
        // binding or a release emitted inside one branch (e.g. on an
        // early-return path) does not leak into the sibling branch or the
        // merge path. Without this, a `let v = ...; return v` in the then
        // branch leaves `v` in `self.locals` for the else branch's
        // `releaseOpenLocals`, emitting `release v` on a path where `v` was
        // never assigned (UnknownRegister at SAB verify time).
        const branch_locals_len = self.locals.items.len;
        var pre_released = try self.released_regs.clone();
        defer pre_released.deinit();

        try self.emitLabel(then_label);
        if (!self.isLocalReg(cond)) try self.emitBranchRelease(cond);
        try self.genBlock(ife.then_block);
        const then_terminated = self.lastIsTerminator();
        if (!then_terminated) try self.emitJmp(merge_label);
        var then_released = try self.released_regs.clone();
        defer then_released.deinit();

        self.popLocalsTo(branch_locals_len);
        try self.restoreReleased(&pre_released);

        try self.emitLabel(else_label);
        if (!self.isLocalReg(cond)) try self.emitBranchRelease(cond);
        if (ife.else_block) |else_block| try self.genBlock(else_block);
        const else_terminated = self.lastIsTerminator();
        if (!else_terminated) try self.emitJmp(merge_label);
        var else_released = try self.released_regs.clone();
        defer else_released.deinit();

        self.popLocalsTo(branch_locals_len);
        // The merge is reached only by the non-terminated incoming paths; a
        // register is released at the merge iff it is released on every such
        // path (intersection). This keeps the merge release state in sync with
        // both branches so the function-end `releaseOpenLocals` neither
        // double-releases (release present on all paths) nor leaks (release
        // present on only one path).
        try self.setMergeReleased(then_terminated, &then_released, else_terminated, &else_released, &pre_released);

        if (!then_terminated or !else_terminated) try self.emitLabel(merge_label);
        const result = try self.intern(try self.newTmp());
        try self.recordReg(result);
        return result;
    }

    fn genIf(self: *Codegen, expr: *const ast.Node, ife: ast.IfExpr) anyerror!u32 {
        if (self.tc.expr_types.get(expr)) |ty| {
            if (!isVoidType(ty) and blockTailExpr(ife.then_block) != null) {
                if (ife.else_block) |else_block| {
                    if (blockTailExpr(else_block) != null) return try self.genIfValue(ife, else_block, ty);
                }
            }
        }
        return try self.genIfStatement(ife);
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
