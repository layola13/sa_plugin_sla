const std = @import("std");
const ast = @import("ast.zig");
const contract_parser = @import("contract_parser.zig");
const type_checker = @import("type_checker.zig");
const lowering_rules = @import("lowering_rules.zig");
const sci_bridge = @import("sci_bridge");

const sab = sci_bridge.sab;
const flattener = sci_bridge.flattener;
const inst = sab.instruction;
const sig = sab.signature;
const const_decl = sab.const_decl;

fn stringSliceLessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn sabProfileEnabled(allocator: std.mem.Allocator) bool {
    const value = std.process.getEnvVarOwned(allocator, "SLA_SAB_PROFILE") catch return false;
    defer allocator.free(value);
    return value.len != 0 and
        !std.mem.eql(u8, value, "0") and
        !std.ascii.eqlIgnoreCase(value, "false");
}

fn sabProfileElapsedMs(start_ns: i128) i128 {
    return @divTrunc(std.time.nanoTimestamp() - start_ns, std.time.ns_per_ms);
}

fn sabProfileStage(enabled: bool, label: []const u8, start_ns: i128) void {
    if (!enabled) return;
    std.io.getStdErr().writer().print("[sla-sab-profile] {s}: {d}ms\n", .{
        label,
        sabProfileElapsedMs(start_ns),
    }) catch {};
}

fn sabProfileDecl(enabled: bool, kind: []const u8, name: []const u8, start_ns: i128) void {
    if (!enabled) return;
    const elapsed_ms = sabProfileElapsedMs(start_ns);
    if (elapsed_ms < 25) return;
    std.io.getStdErr().writer().print("[sla-sab-profile] {s} {s}: {d}ms\n", .{
        kind,
        name,
        elapsed_ms,
    }) catch {};
}

pub const Error = error{
    UnsupportedSabDirectFeature,
    MissingType,
    OutOfMemory,
    InvalidStringLiteral,
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

const ParamCleanupAction = enum {
    skip,
    mark_consumed,
    consume,
    release,
};

const RefCellBorrowValue = struct {
    cell_reg: u32,
    kind: lowering_rules.RefCellBorrowKind,
    release_regs: []const u32 = &.{},
};

const BorrowAddressTempState = struct {
    release_regs: []const u32 = &.{},
    restore_slot: ?u32 = null,
    restore_value: ?u32 = null,
};

const BranchEmitterStateSnapshot = struct {
    released: std.AutoHashMap(u32, void),
    refcell_values: std.AutoHashMap(u32, RefCellBorrowValue),
    borrow_temps: std.AutoHashMap(u32, BorrowAddressTempState),
};

const ResultSlotRefCellHandle = struct {
    cell_slot: u32,
    kind: lowering_rules.RefCellBorrowKind,
};

const LoopJumpKind = enum {
    break_,
    continue_,
};

const MacroArgBinding = struct {
    name: []const u8,
    arg: *const ast.Node,
    ctx: ?*MacroExpansionContext = null,
    evaluated_reg: ?u32 = null,
    release_evaluated_reg: bool = false,
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
    inline_join: bool = false,
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
    release_regs: []const u32 = &.{},
    restore_slot: ?u32 = null,
};

const StdSurfaceRuleKind = enum {
    associated,
    constructor,
    function,
    method,
    fallible_method,
    index,
    index_address,
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
    consume_value: bool = false,
};

const StdSurfaceRuleOptions = struct {
    deps: []const []const u8 = &.{},
    panic_code: ?i64 = null,
    consume_value: bool = false,
};

const StdImportModule = struct {
    import_path: []const u8,
    flat: flattener.FlattenResult,
    function_sigs: []sig.FunctionSig,

    fn module(self: *const StdImportModule) sab.Module {
        return .{
            .symbols = self.flat.symbols.names.items,
            .function_sigs = self.function_sigs,
            .const_decls = self.flat.const_decls,
            .instructions = self.flat.instructions,
            .owned_text = &.{},
        };
    }
};

const StdMacroTemplate = struct {
    key: []const u8,
    func_name: []const u8,
    arg_count: usize,
    module: sab.Module,
};

const PendingStdDep = struct {
    import_path: []const u8,
    dep: []const u8,
};

const DecodedModuleLocalRemap = struct {
    reg_ids: std.AutoHashMap(u32, u32),
    reg_order: std.ArrayList(u32),
    extra_reg_ids: std.ArrayList(u32),
    stable_reg_ids: std.AutoHashMap(u32, u32),
    source_reg_symbol_ids: std.AutoHashMap(u32, u32),
    label_ids: std.AutoHashMap(u32, u32),
    reg_names: std.StringHashMap([]const u8),
    reg_name_ids: std.StringHashMap(u32),

    fn init(allocator: std.mem.Allocator) DecodedModuleLocalRemap {
        return .{
            .reg_ids = std.AutoHashMap(u32, u32).init(allocator),
            .reg_order = std.ArrayList(u32).init(allocator),
            .extra_reg_ids = std.ArrayList(u32).init(allocator),
            .stable_reg_ids = std.AutoHashMap(u32, u32).init(allocator),
            .source_reg_symbol_ids = std.AutoHashMap(u32, u32).init(allocator),
            .label_ids = std.AutoHashMap(u32, u32).init(allocator),
            .reg_names = std.StringHashMap([]const u8).init(allocator),
            .reg_name_ids = std.StringHashMap(u32).init(allocator),
        };
    }

    fn deinit(self: *DecodedModuleLocalRemap) void {
        self.reg_ids.deinit();
        self.reg_order.deinit();
        self.extra_reg_ids.deinit();
        self.stable_reg_ids.deinit();
        self.source_reg_symbol_ids.deinit();
        self.label_ids.deinit();
        self.reg_names.deinit();
        self.reg_name_ids.deinit();
    }
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
    assigned_bindings: std.StringHashMap(void),
    // Names bound by `let` two or more times within one function. Register
    // identity is otherwise name-keyed and function-global, so sibling-scope
    // bindings such as the two `id_len` locals in `scan_ident` would alias one
    // register even though they have distinct lexical lifetimes. Each occurrence
    // of a name in this set receives a fresh register id when it is lowered.
    multi_let_bindings: std.StringHashMap(void),
    std_surface_rules: std.ArrayList(StdSurfaceRule),
    included_imports: std.StringHashMap(void),
    pending_std_deps: std.ArrayList(PendingStdDep),
    std_import_modules: std.ArrayList(StdImportModule),
    std_import_module_ids: std.StringHashMap(usize),
    std_macro_templates: std.ArrayList(StdMacroTemplate),
    std_macro_template_ids: std.StringHashMap(usize),
    escaped_closure_entries: std.AutoHashMap(*const ast.Node, EscapedClosureEntry),
    refcell_borrow_values: std.AutoHashMap(u32, RefCellBorrowValue),
    result_slot_refcell_handles: std.AutoHashMap(u32, ResultSlotRefCellHandle),
    result_slot_refcell_slots: std.AutoHashMap(u32, u32),
    borrow_address_temps: std.AutoHashMap(u32, BorrowAddressTempState),
    non_owning_regs: std.AutoHashMap(u32, void),
    future_state_vtables: std.AutoHashMap(u32, []const u8),
    future_readiness: std.AutoHashMap(u32, lowering_rules.FutureReadiness),
    future_readiness_by_name: std.StringHashMap(lowering_rules.FutureReadiness),
    global_scalar_consts: std.StringHashMap(*const ast.Node),
    copy_value_cache: std.StringHashMap(bool),
    string_literal_consts: std.StringHashMap([]const u8),
    sa_std_root: ?[]const u8 = null,
    instructions: std.ArrayList(inst.Instruction),
    function_sigs: std.ArrayList(sig.FunctionSig),
    test_sigs: std.ArrayList(sig.FunctionSig),
    locals: std.ArrayList(Local),
    loop_continue_labels: std.ArrayList([]const u8),
    loop_break_labels: std.ArrayList([]const u8),
    current_reg_ids: std.ArrayList(u32),
    current_reg_seen: std.AutoHashMap(u32, void),
    released_regs: std.AutoHashMap(u32, void),
    // Register ids that have already had a `stack_alloc` emitted in the current
    // function body. Sibling-scope `let`s of the same name intern to one
    // function-global register id (register identity here is name-keyed), so a
    // scalar-reassign-slot binding in two sibling `if`/loop scopes would emit
    // `stack_alloc <id>` twice for the same id, tripping the SAB verifier's
    // RegisterRedefinition. The two bindings never coexist and share type/size,
    // so the slot is allocated once and reused (store-only) on later bindings.
    stack_alloc_emitted: std.AutoHashMap(u32, void),
    tmp_idx: usize = 0,
    label_idx: usize = 0,
    string_idx: usize = 0,
    macro_fragment_idx: usize = 0,
    macro_call_idx: usize = 0,
    escaped_closure_idx: usize = 0,
    in_function_body: bool = false,
    current_async_return: bool = false,
    current_async_return_ty: ?*const ast.Type = null,
    current_expr_result_escapes: bool = false,
    current_block: ?[]const *ast.Node = null,
    current_stmt_index: usize = 0,
    active_macro_try_cleanup: ?[]const []const u8 = null,
    current_expr_later_nodes: std.ArrayList(*const ast.Node),
    future_task_helpers_emitted: bool = false,
    // When appending a decoded std-macro fragment, fragment-internal temp/local
    // registers (named `tmp_N`, `__...` by the snippet flattener) share the
    // `tmp_N` namespace across independently-flattened fragments and with main
    // codegen. Name-based interning would alias them, so while a fragment is
    // being appended this map renames each such internal register to a fresh
    // globally-unique name. Arg-passed names (real main-codegen registers) are
    // excluded so their references still resolve to the caller's registers.
    fragment_rename: ?*std.StringHashMap([]const u8) = null,
    fragment_rename_args: ?[]const []const u8 = null,
    fragment_rename_idx: usize = 0,
    decoded_module_rename_idx: usize = 0,

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
            .assigned_bindings = std.StringHashMap(void).init(allocator),
            .multi_let_bindings = std.StringHashMap(void).init(allocator),
            .std_surface_rules = std.ArrayList(StdSurfaceRule).init(allocator),
            .included_imports = std.StringHashMap(void).init(allocator),
            .pending_std_deps = std.ArrayList(PendingStdDep).init(allocator),
            .std_import_modules = std.ArrayList(StdImportModule).init(allocator),
            .std_import_module_ids = std.StringHashMap(usize).init(allocator),
            .std_macro_templates = std.ArrayList(StdMacroTemplate).init(allocator),
            .std_macro_template_ids = std.StringHashMap(usize).init(allocator),
            .escaped_closure_entries = std.AutoHashMap(*const ast.Node, EscapedClosureEntry).init(allocator),
            .refcell_borrow_values = std.AutoHashMap(u32, RefCellBorrowValue).init(allocator),
            .result_slot_refcell_handles = std.AutoHashMap(u32, ResultSlotRefCellHandle).init(allocator),
            .result_slot_refcell_slots = std.AutoHashMap(u32, u32).init(allocator),
            .borrow_address_temps = std.AutoHashMap(u32, BorrowAddressTempState).init(allocator),
            .non_owning_regs = std.AutoHashMap(u32, void).init(allocator),
            .future_state_vtables = std.AutoHashMap(u32, []const u8).init(allocator),
            .future_readiness = std.AutoHashMap(u32, lowering_rules.FutureReadiness).init(allocator),
            .future_readiness_by_name = std.StringHashMap(lowering_rules.FutureReadiness).init(allocator),
            .global_scalar_consts = std.StringHashMap(*const ast.Node).init(allocator),
            .copy_value_cache = std.StringHashMap(bool).init(allocator),
            .string_literal_consts = std.StringHashMap([]const u8).init(allocator),
            .instructions = std.ArrayList(inst.Instruction).init(allocator),
            .function_sigs = std.ArrayList(sig.FunctionSig).init(allocator),
            .test_sigs = std.ArrayList(sig.FunctionSig).init(allocator),
            .locals = std.ArrayList(Local).init(allocator),
            .loop_continue_labels = std.ArrayList([]const u8).init(allocator),
            .loop_break_labels = std.ArrayList([]const u8).init(allocator),
            .current_reg_ids = std.ArrayList(u32).init(allocator),
            .current_reg_seen = std.AutoHashMap(u32, void).init(allocator),
            .released_regs = std.AutoHashMap(u32, void).init(allocator),
            .stack_alloc_emitted = std.AutoHashMap(u32, void).init(allocator),
            .current_expr_later_nodes = std.ArrayList(*const ast.Node).init(allocator),
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
        self.assigned_bindings.deinit();
        self.multi_let_bindings.deinit();
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
        for (self.pending_std_deps.items) |dep| {
            self.allocator.free(dep.import_path);
            self.allocator.free(dep.dep);
        }
        self.pending_std_deps.deinit();
        for (self.std_import_modules.items) |*entry| {
            self.allocator.free(entry.import_path);
            for (entry.function_sigs) |*fsig| fsig.deinit(self.allocator);
            if (entry.function_sigs.len != 0) self.allocator.free(entry.function_sigs);
            entry.flat.deinit(self.allocator);
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
        self.clearRefCellBorrowValues();
        self.refcell_borrow_values.deinit();
        self.result_slot_refcell_handles.deinit();
        self.result_slot_refcell_slots.deinit();
        self.clearBorrowAddressTemps();
        self.borrow_address_temps.deinit();
        self.non_owning_regs.deinit();
        self.future_state_vtables.deinit();
        self.future_readiness.deinit();
        self.future_readiness_by_name.deinit();
        self.global_scalar_consts.deinit();
        self.copy_value_cache.deinit();
        self.string_literal_consts.deinit();
        if (self.sa_std_root) |root| self.allocator.free(root);
        self.instructions.deinit();
        self.function_sigs.deinit();
        self.test_sigs.deinit();
        self.locals.deinit();
        self.loop_continue_labels.deinit();
        self.loop_break_labels.deinit();
        self.current_reg_ids.deinit();
        self.current_reg_seen.deinit();
        self.released_regs.deinit();
        self.stack_alloc_emitted.deinit();
        self.current_expr_later_nodes.deinit();
    }

    pub fn generate(self: *Codegen, program: *ast.Node) ![]u8 {
        if (program.* != .program) return Error.UnsupportedSabDirectFeature;
        const profile = sabProfileEnabled(self.allocator);
        var stage_start = std.time.nanoTimestamp();
        try self.collectGlobalScalarConsts(program);
        try self.collectAssignedBindings(program);
        sabProfileStage(profile, "pre-scan", stage_start);
        stage_start = std.time.nanoTimestamp();
        try self.loadStdSurfaceRules();
        self.preloadStdSurfaceDeps(program) catch |err| {
            self.traceUnsupported("std surface preload failed: {s}\n", .{@errorName(err)});
            return err;
        };
        sabProfileStage(profile, "std surface deps", stage_start);
        stage_start = std.time.nanoTimestamp();
        if (programUsesFutureTaskRuntime(program)) {
            try self.emitFutureTaskHelpers();
        }
        sabProfileStage(profile, "future helpers", stage_start);
        stage_start = std.time.nanoTimestamp();
        for (program.program.decls) |decl| {
            if (decl.* == .impl_decl and decl.impl_decl.trait_name != null) {
                try self.emitTraitVTableDecl(&decl.impl_decl);
            }
        }
        sabProfileStage(profile, "trait vtables", stage_start);
        stage_start = std.time.nanoTimestamp();
        for (program.program.decls) |decl| {
            switch (decl.*) {
                .func_decl => |*f| {
                    const decl_start = if (profile) std.time.nanoTimestamp() else 0;
                    if (f.is_decl_only) {
                        if (f.is_extern) {
                            self.genExternDecl(f) catch |err| {
                                self.traceUnsupported("extern decl {s} failed: {s}\n", .{ f.name, @errorName(err) });
                                return err;
                            };
                            sabProfileDecl(profile, "extern", f.name, decl_start);
                        }
                    } else {
                        self.genFuncDecl(f) catch |err| {
                            self.traceUnsupported("func decl {s} failed: {s}\n", .{ f.name, @errorName(err) });
                            return err;
                        };
                        sabProfileDecl(profile, "func", f.name, decl_start);
                    }
                },
                .test_decl => |*t| {
                    const decl_start = if (profile) std.time.nanoTimestamp() else 0;
                    self.genTestDecl(t) catch |err| {
                        self.traceUnsupported("test decl {s} failed: {s}\n", .{ t.name, @errorName(err) });
                        return err;
                    };
                    sabProfileDecl(profile, "test", t.name, decl_start);
                },
                .impl_decl => |*i| {
                    const decl_start = if (profile) std.time.nanoTimestamp() else 0;
                    self.genImplDecl(i) catch |err| {
                        self.traceUnsupported("impl decl failed: {s}\n", .{@errorName(err)});
                        return err;
                    };
                    sabProfileDecl(profile, "impl", concreteTypeName(i.target_ty) orelse "?", decl_start);
                },
                .overload_decl => |*o| {
                    const decl_start = if (profile) std.time.nanoTimestamp() else 0;
                    self.genOverloadDecl(o) catch |err| {
                        self.traceUnsupported("overload decl failed: {s}\n", .{@errorName(err)});
                        return err;
                    };
                    sabProfileDecl(profile, "overload", concreteTypeName(o.target_ty) orelse "?", decl_start);
                },
                .struct_decl, .enum_decl, .trait_decl, .type_alias_decl, .macro_decl, .import_decl, .using_decl, .const_stmt => {},
                else => {
                    self.traceUnsupported("top-level decl {s} failed\n", .{@tagName(decl.*)});
                    return Error.UnsupportedSabDirectFeature;
                },
            }
        }
        sabProfileStage(profile, "top-level decls", stage_start);
        stage_start = std.time.nanoTimestamp();
        try self.emitEscapedClosureEntries();
        sabProfileStage(profile, "escaped closures", stage_start);
        stage_start = std.time.nanoTimestamp();
        try self.emitReferencedContractExternDecls();
        sabProfileStage(profile, "extern decls", stage_start);
        stage_start = std.time.nanoTimestamp();
        const bytes = try sab.encodeProgramWithConsts(
            self.allocator,
            self.symbols.items,
            self.const_decls.items,
            self.function_sigs.items,
            self.instructions.items,
        );
        sabProfileStage(profile, "encode", stage_start);
        return bytes;
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
        while (true) {
            var changed = false;
            for (program.program.decls) |decl| {
                if (decl.* != .const_stmt) continue;
                const c = decl.const_stmt;
                if (c.value.* != .identifier) continue;
                if (self.global_scalar_consts.contains(c.name)) continue;
                if (self.global_scalar_consts.get(c.value.identifier)) |target_literal| {
                    try self.global_scalar_consts.put(c.name, target_literal);
                    changed = true;
                }
            }
            if (!changed) break;
        }
        while (true) {
            var folded_any = false;
            for (program.program.decls) |decl| {
                if (decl.* != .const_stmt) continue;
                const c = decl.const_stmt;
                if (c.value.* != .binary_expr) continue;
                if (self.global_scalar_consts.contains(c.name)) continue;
                if (try self.foldTopLevelBinaryConst(&c.value.binary_expr)) |folded| {
                    try self.global_scalar_consts.put(c.name, folded);
                    folded_any = true;
                }
            }
            if (!folded_any) break;
            while (true) {
                var alias_changed = false;
                for (program.program.decls) |decl| {
                    if (decl.* != .const_stmt) continue;
                    const c = decl.const_stmt;
                    if (c.value.* != .identifier) continue;
                    if (self.global_scalar_consts.contains(c.name)) continue;
                    if (self.global_scalar_consts.get(c.value.identifier)) |target_literal| {
                        try self.global_scalar_consts.put(c.name, target_literal);
                        alias_changed = true;
                    }
                }
                if (!alias_changed) break;
            }
        }
    }

    fn scalarConstantNodeFor(self: *Codegen, expr: *const ast.Node) ?*const ast.Node {
        if (expr.* == .literal) {
            return switch (expr.literal) {
                .int_val, .float_val, .bool_val => expr,
                .string_val => null,
            };
        }
        if (expr.* == .identifier) return self.global_scalar_consts.get(expr.identifier);
        return null;
    }

    fn foldTopLevelBinaryConst(self: *Codegen, bin: *const ast.BinaryExpr) !?*const ast.Node {
        const left_node = self.scalarConstantNodeFor(bin.left) orelse return null;
        const right_node = self.scalarConstantNodeFor(bin.right) orelse return null;
        const left_lit = left_node.literal;
        const right_lit = right_node.literal;
        const folded = try self.allocator.create(ast.Node);
        switch (left_lit) {
            .int_val => |li| {
                if (right_lit != .int_val) return null;
                const ri = right_lit.int_val;
                const value = switch (bin.op) {
                    .add => std.math.add(i64, li, ri) catch return null,
                    .sub => std.math.sub(i64, li, ri) catch return null,
                    .mul => std.math.mul(i64, li, ri) catch return null,
                    .div => if (ri == 0) return null else @divTrunc(li, ri),
                    .mod => if (ri == 0) return null else @rem(li, ri),
                    .bit_and => li & ri,
                    .bit_or => li | ri,
                    .bit_xor => li ^ ri,
                    .shl => if (ri >= 0 and ri < 64) li << @as(u6, @intCast(ri)) else return null,
                    .shr => if (ri >= 0 and ri < 64) li >> @as(u6, @intCast(ri)) else return null,
                    else => return null,
                };
                folded.* = .{ .literal = .{ .int_val = value } };
            },
            .float_val => |lf| {
                if (right_lit != .float_val) return null;
                const rf = right_lit.float_val;
                const value = switch (bin.op) {
                    .add => lf + rf,
                    .sub => lf - rf,
                    .mul => lf * rf,
                    .div => if (rf == 0.0) return null else lf / rf,
                    else => return null,
                };
                folded.* = .{ .literal = .{ .float_val = value } };
            },
            .bool_val => |lb| {
                if (right_lit != .bool_val) return null;
                const rb = right_lit.bool_val;
                const value = switch (bin.op) {
                    .logical_and => lb and rb,
                    .logical_or => lb or rb,
                    else => return null,
                };
                folded.* = .{ .literal = .{ .bool_val = value } };
            },
            .string_val => return null,
        }
        return folded;
    }

    fn collectAssignedBindings(self: *Codegen, program: *const ast.Node) !void {
        self.assigned_bindings.clearRetainingCapacity();
        if (program.* != .program) return;
        for (program.program.decls) |decl| try self.collectAssignedBindingsInNode(decl);
    }

    // Populate `multi_let_bindings` with names bound by `let` two or more times
    // within a single function body. Such names would otherwise collide on one
    // function-global register id. Counting is per-function so a name bound once
    // in each of two different functions does not trigger fresh binding ids.
    fn prepareMultiLetBindings(self: *Codegen, body: []const *ast.Node) !void {
        try lowering_rules.collectRepeatedLetBindings(self.allocator, body, &self.multi_let_bindings);
    }

    fn collectAssignedBindingsInBlock(self: *Codegen, body: []const *ast.Node) !void {
        for (body) |node| try self.collectAssignedBindingsInNode(node);
    }

    fn collectAssignedBindingsInNode(self: *Codegen, node: *const ast.Node) anyerror!void {
        switch (node.*) {
            .func_decl => |f| try self.collectAssignedBindingsInBlock(f.body),
            .test_decl => |t| try self.collectAssignedBindingsInBlock(t.body),
            .impl_decl => |i| for (i.methods) |method| try self.collectAssignedBindingsInNode(method),
            .overload_decl => |o| for (o.methods) |method| try self.collectAssignedBindingsInNode(method),
            .let_stmt => |let| try self.collectAssignedBindingsInNode(let.value),
            .let_destructure_stmt => |let| try self.collectAssignedBindingsInNode(let.value),
            .let_else_stmt => |let| {
                try self.collectAssignedBindingsInNode(let.value);
                try self.collectAssignedBindingsInBlock(let.else_block);
            },
            .const_stmt => |c| try self.collectAssignedBindingsInNode(c.value),
            .var_stmt => {},
            .assign_stmt => |assign| {
                if (lowering_rules.rootIdentifier(assign.target)) |name| try self.assigned_bindings.put(name, {});
                try self.collectAssignedBindingsInNode(assign.target);
                try self.collectAssignedBindingsInNode(assign.value);
            },
            .expr_stmt => |expr| try self.collectAssignedBindingsInNode(expr),
            .return_stmt => |ret| if (ret.value) |value| try self.collectAssignedBindingsInNode(value),
            .block_stmt => |block| try self.collectAssignedBindingsInBlock(block.body),
            .binary_expr => |bin| {
                try self.collectAssignedBindingsInNode(bin.left);
                try self.collectAssignedBindingsInNode(bin.right);
            },
            .call_expr => |call| for (call.args) |arg| try self.collectAssignedBindingsInNode(arg),
            .field_expr => |field| try self.collectAssignedBindingsInNode(field.expr),
            .struct_literal => |lit| {
                for (lit.fields) |field| try self.collectAssignedBindingsInNode(field.value);
                if (lit.update_expr) |update| try self.collectAssignedBindingsInNode(update);
            },
            .tuple_literal => |lit| for (lit.elements) |elem| try self.collectAssignedBindingsInNode(elem),
            .array_literal => |lit| for (lit.elements) |elem| try self.collectAssignedBindingsInNode(elem),
            .repeat_array_literal => |lit| try self.collectAssignedBindingsInNode(lit.value),
            .index_expr => |idx| {
                try self.collectAssignedBindingsInNode(idx.target);
                try self.collectAssignedBindingsInNode(idx.index);
            },
            .if_expr => |ife| {
                try self.collectAssignedBindingsInNode(ife.cond);
                if (ife.let_chain) |chain| for (chain) |cond| try self.collectAssignedBindingsInNode(cond.value);
                try self.collectAssignedBindingsInBlock(ife.then_block);
                if (ife.else_block) |else_block| try self.collectAssignedBindingsInBlock(else_block);
            },
            .while_stmt => |w| {
                try self.collectAssignedBindingsInNode(w.cond);
                try self.collectAssignedBindingsInBlock(w.body);
            },
            .for_stmt => |f| {
                try self.collectAssignedBindingsInNode(f.start);
                if (f.end) |end| try self.collectAssignedBindingsInNode(end);
                try self.collectAssignedBindingsInBlock(f.body);
            },
            .match_expr => |mat| {
                try self.collectAssignedBindingsInNode(mat.val);
                for (mat.cases) |case| try self.collectAssignedBindingsInBlock(case.body);
            },
            .borrow_expr => |borrow| try self.collectAssignedBindingsInNode(borrow.expr),
            .move_expr => |move| try self.collectAssignedBindingsInNode(move.expr),
            .deref_expr => |deref| try self.collectAssignedBindingsInNode(deref.expr),
            .cast_expr => |cast| try self.collectAssignedBindingsInNode(cast.expr),
            .unsafe_expr => |unsafe_expr| try self.collectAssignedBindingsInBlock(unsafe_expr.body),
            .await_expr => |aw| try self.collectAssignedBindingsInNode(aw.expr),
            .closure_literal => |closure| try self.collectAssignedBindingsInNode(closure.body),
            else => {},
        }
    }

    fn typeCanUseScalarReassignSlot(ty: *const ast.Type) bool {
        return switch (ty.*) {
            .primitive => true,
            else => false,
        };
    }

    fn bindingNeedsScalarReassignSlot(self: *Codegen, name: []const u8, ty: *const ast.Type) bool {
        return typeCanUseScalarReassignSlot(ty) and self.assigned_bindings.contains(name);
    }

    fn bindingNeedsCopyScalarReuseSlot(self: *Codegen, name: []const u8, ty: *const ast.Type) bool {
        return typeCanUseScalarReassignSlot(ty) and self.identifierUsedLaterInCurrentBlock(name);
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

    fn bindingReg(self: *Codegen, name: []const u8) !u32 {
        if (!self.multi_let_bindings.contains(name)) return try self.intern(name);
        return try self.intern(try self.newTmp());
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

    /// A unique hygiene-suffix token for FORMAT/STRFMT macros' `%tag` parameter.
    /// It must NOT collide with the `tmp_N` register namespace used by the
    /// snippet flattener, so it uses a distinct `fmttag_N` prefix. The macros
    /// only use `%tag` to build unique local names (`__format_..._%tag`), never
    /// as a value register.
    fn newFormatTag(self: *Codegen) ![]const u8 {
        const name = try std.fmt.allocPrint(self.allocator, "fmttag_{}", .{self.tmp_idx});
        self.tmp_idx += 1;
        return name;
    }

    fn newLabel(self: *Codegen, prefix: []const u8) ![]const u8 {
        const name = try std.fmt.allocPrint(self.allocator, "{s}_{}", .{ prefix, self.label_idx });
        self.label_idx += 1;
        return name;
    }

    fn newStringConst(self: *Codegen) ![]const u8 {
        const name = try std.fmt.allocPrint(self.allocator, "SLA_STR_{}", .{self.string_idx});
        self.string_idx += 1;
        return name;
    }

    fn parseHexDigitPair(text: []const u8) !u8 {
        if (text.len != 2) return Error.InvalidStringLiteral;
        const hi = std.fmt.charToDigit(text[0], 16) catch return Error.InvalidStringLiteral;
        const lo = std.fmt.charToDigit(text[1], 16) catch return Error.InvalidStringLiteral;
        return @as(u8, @intCast((hi << 4) | lo));
    }

    fn decodedStringLiteralLen(value: []const u8) !usize {
        var len: usize = 0;
        var i: usize = 0;
        while (i < value.len) {
            const c = value[i];
            if (c != '\\') {
                len += 1;
                i += 1;
                continue;
            }
            if (i + 1 >= value.len) return Error.InvalidStringLiteral;
            switch (value[i + 1]) {
                '\\', '"', 'n', 'r', 't', '0' => {
                    len += 1;
                    i += 2;
                },
                'x' => {
                    if (i + 3 >= value.len) return Error.InvalidStringLiteral;
                    _ = try parseHexDigitPair(value[i + 2 .. i + 4]);
                    len += 1;
                    i += 4;
                },
                else => return Error.InvalidStringLiteral,
            }
        }
        return len;
    }

    fn decodeStringLiteralBytes(self: *Codegen, value: []const u8) ![]u8 {
        var out = std.ArrayList(u8).init(self.allocator);
        errdefer out.deinit();

        var i: usize = 0;
        while (i < value.len) {
            const c = value[i];
            if (c != '\\') {
                try out.append(c);
                i += 1;
                continue;
            }
            if (i + 1 >= value.len) return Error.InvalidStringLiteral;
            switch (value[i + 1]) {
                '\\' => try out.append('\\'),
                '"' => try out.append('"'),
                'n' => try out.append('\n'),
                'r' => try out.append('\r'),
                't' => try out.append('\t'),
                '0' => try out.append(0),
                'x' => {
                    if (i + 3 >= value.len) return Error.InvalidStringLiteral;
                    try out.append(try parseHexDigitPair(value[i + 2 .. i + 4]));
                    i += 4;
                    continue;
                },
                else => return Error.InvalidStringLiteral,
            }
            i += 2;
        }
        return out.toOwnedSlice();
    }

    fn escapedUtf8LiteralBytes(self: *Codegen, bytes: []const u8) ![]u8 {
        var out = std.ArrayList(u8).init(self.allocator);
        errdefer out.deinit();

        for (bytes) |b| switch (b) {
            '\\' => try out.appendSlice("\\\\"),
            '"' => try out.appendSlice("\\\""),
            '\n' => try out.appendSlice("\\n"),
            '\r' => try out.appendSlice("\\r"),
            '\t' => try out.appendSlice("\\t"),
            0 => try out.appendSlice("\\0"),
            else => if (std.ascii.isPrint(b)) {
                try out.append(b);
            } else {
                try out.writer().print("\\x{X:0>2}", .{b});
            },
        };

        return out.toOwnedSlice();
    }

    fn appendUtf8Const(self: *Codegen, name: []const u8, bytes: []const u8) !void {
        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        const escaped = try self.escapedUtf8LiteralBytes(bytes);
        defer self.allocator.free(escaped);
        const literal_text = try std.fmt.allocPrint(self.allocator, "utf8:\"{s}\"", .{escaped});
        errdefer self.allocator.free(literal_text);
        const raw_text = try std.fmt.allocPrint(self.allocator, "@const {s} = {s}", .{ name, literal_text });
        errdefer self.allocator.free(raw_text);
        try self.const_decls.append(.{
            .source_line = 0,
            .expanded_line = 0,
            .upstream_loc = null,
            .raw_text = raw_text,
            .name = owned_name,
            .literal_text = literal_text,
            .value = .{ .utf8 = .{
                .kind = .utf8,
                .bytes = try self.allocator.dupe(u8, bytes),
            } },
        });
        _ = try self.intern(name);
    }

    fn stringLiteralConstLabel(self: *Codegen, value: []const u8) ![]const u8 {
        if (self.string_literal_consts.get(value)) |label| return label;

        const label = try self.newStringConst();
        errdefer self.allocator.free(label);
        const bytes = try self.decodeStringLiteralBytes(value);
        defer self.allocator.free(bytes);
        try self.appendUtf8Const(label, bytes);
        try self.string_literal_consts.put(value, label);
        return label;
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
        if (std.mem.eql(u8, text, "consume_value")) {
            options.consume_value = true;
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
            .consume_value = options.consume_value,
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
            } else if (std.mem.eql(u8, raw_kind, "index_address")) {
                const type_name = parts.next() orelse return Error.UnsupportedSabDirectFeature;
                const import_path = parts.next() orelse return Error.UnsupportedSabDirectFeature;
                const macro_name = parts.next() orelse return Error.UnsupportedSabDirectFeature;
                const arg_text = parts.next() orelse "";
                var options = StdSurfaceRuleOptions{};
                while (parts.next()) |option| try self.parseStdSurfaceOption(option, &options);
                try self.appendStdSurfaceRule(.index_address, type_name, null, import_path, macro_name, arg_text, options);
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
            else => if (lowering_rules.abiPassesAsPointer(ty)) .ptr else Error.UnsupportedSabDirectFeature,
        };
    }

    fn paramPrimType(ty: *const ast.Type) !sig.PrimType {
        if (ty.* == .primitive and ty.primitive == .void_type) return .ptr;
        return try primType(ty);
    }

    fn storagePrimType(ty: *const ast.Type) !sig.PrimType {
        if (ty.* == .primitive and ty.primitive == .void_type) return .ptr;
        return try primType(ty);
    }

    fn addressableSlotPrimType(ty: *const ast.Type) !sig.PrimType {
        if (ty.* == .infer) return .ptr;
        return try storagePrimType(ty);
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
        return .{ .offset = layout.offset, .ty = storagePrimType(layout.ty) catch return null };
    }

    fn arrayStride(elem_ty: *const ast.Type) usize {
        return lowering_rules.inlineArrayStride(elem_ty);
    }

    fn arraySize(arr: ast.ArrayType) usize {
        return lowering_rules.inlineArraySize(arr);
    }

    fn arrayElementLayout(arr: ast.ArrayType, index: usize) ?FieldLayout {
        const layout = lowering_rules.arrayElementLayout(arr, index) orelse return null;
        return .{ .offset = layout.offset, .ty = storagePrimType(layout.ty) catch return null };
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

    fn enumNameMatchesDecl(pattern_name: []const u8, decl_name: []const u8) bool {
        if (std.mem.eql(u8, pattern_name, decl_name)) return true;
        if (decl_name.len <= pattern_name.len) return false;
        if (!std.mem.startsWith(u8, decl_name, pattern_name)) return false;
        return decl_name[pattern_name.len] == '_';
    }

    fn enumDeclForValueType(self: *Codegen, ty: *const ast.Type) ?*ast.EnumDecl {
        var curr = ty;
        while (true) {
            switch (curr.*) {
                .pointer => |p| curr = p,
                .borrow => |b| curr = b,
                .user_defined => |ud| {
                    if (std.mem.eql(u8, ud.name, "Option") or std.mem.eql(u8, ud.name, "Result")) return null;
                    return self.tc.enums.get(ud.name);
                },
                else => return null,
            }
        }
    }

    fn enumDeclForPatternValue(self: *Codegen, value: *const ast.Node, pattern: ast.EnumPattern) !?*ast.EnumDecl {
        const value_ty = self.tc.expr_types.get(value) orelse return Error.MissingType;
        const decl = self.enumDeclForValueType(value_ty) orelse return null;
        if (!enumNameMatchesDecl(pattern.enum_name, decl.name)) return Error.UnsupportedSabDirectFeature;
        return decl;
    }

    fn emitLetPatternCheck(
        self: *Codegen,
        pattern: ast.EnumPattern,
        value_reg: u32,
        enum_decl: ?*ast.EnumDecl,
        plan: lowering_rules.LetPatternPlan,
        branch_flag: u32,
    ) !void {
        switch (plan.kind) {
            .enum_variant => {
                const decl = enum_decl orelse return Error.UnsupportedSabDirectFeature;
                const tag = lowering_rules.enumVariantIndex(decl, pattern.variant_name) orelse return Error.UnsupportedSabDirectFeature;
                const tag_reg = try self.intern(try self.newTmp());
                try self.emitLoad(tag_reg, value_reg, lowering_rules.enum_tag_offset, .i64);
                try self.emitOp(branch_flag, .eq, .{ .reg = tag_reg }, .{ .imm_i64 = @intCast(tag) });
                try self.emitRelease(tag_reg);
            },
            .option_some, .option_none => try self.emitStdMacroFragment("sa_std/core/option.sa", "OPTION_IS_SOME", &.{
                self.symbols.items[branch_flag],
                self.symbols.items[value_reg],
            }),
            .result_ok, .result_err => try self.emitStdMacroFragment("sa_std/core/result.sa", "RESULT_IS_OK", &.{
                self.symbols.items[branch_flag],
                self.symbols.items[value_reg],
            }),
        }
    }

    fn bindLetPatternPayload(
        self: *Codegen,
        pattern: ast.EnumPattern,
        value_reg: u32,
        value_ty: *const ast.Type,
        enum_decl: ?*ast.EnumDecl,
        plan: lowering_rules.LetPatternPlan,
    ) !void {
        switch (plan.kind) {
            .enum_variant => {
                const decl = enum_decl orelse return Error.UnsupportedSabDirectFeature;
                const variant = lowering_rules.enumVariant(decl, pattern.variant_name) orelse return Error.UnsupportedSabDirectFeature;
                if (pattern.bindings.len != variant.fields.len) return Error.UnsupportedSabDirectFeature;
                for (pattern.bindings, variant.fields) |binding, field| {
                    const layout = lowering_rules.enumFieldLayout(variant, field.name) orelse return Error.UnsupportedSabDirectFeature;
                    const binding_reg = try self.intern(try self.newTmp());
                    try self.emitLoad(binding_reg, value_reg, layout.offset, try storagePrimType(layout.ty));
                    try self.pushTypedLocal(binding, binding_reg, false, field.ty);
                }
            },
            .option_some => {
                if (pattern.bindings.len > 1) return Error.UnsupportedSabDirectFeature;
                if (pattern.bindings.len == 1) {
                    const inner_ty = lowering_rules.optionInnerType(value_ty) orelse return Error.UnsupportedSabDirectFeature;
                    const binding_reg = try self.intern(try self.newTmp());
                    try self.recordReg(binding_reg);
                    try self.emitStdMacroFragment("sa_std/core/option.sa", "OPTION_GET", &.{
                        self.symbols.items[binding_reg],
                        self.symbols.items[value_reg],
                    });
                    try self.pushTypedLocal(pattern.bindings[0], binding_reg, false, inner_ty);
                }
            },
            .option_none => if (pattern.bindings.len != 0) return Error.UnsupportedSabDirectFeature,
            .result_ok => {
                if (pattern.bindings.len > 1) return Error.UnsupportedSabDirectFeature;
                if (pattern.bindings.len == 1) {
                    const ok_ty = lowering_rules.resultOkType(value_ty) orelse return Error.UnsupportedSabDirectFeature;
                    const binding_reg = try self.intern(try self.newTmp());
                    try self.recordReg(binding_reg);
                    try self.emitStdMacroFragment("sa_std/core/result.sa", "RESULT_GET_OK", &.{
                        self.symbols.items[binding_reg],
                        self.symbols.items[value_reg],
                    });
                    try self.pushTypedLocal(pattern.bindings[0], binding_reg, false, ok_ty);
                }
            },
            .result_err => {
                if (pattern.bindings.len > 1) return Error.UnsupportedSabDirectFeature;
                if (pattern.bindings.len == 1) {
                    const err_ty = lowering_rules.resultErrType(value_ty) orelse return Error.UnsupportedSabDirectFeature;
                    const binding_reg = try self.intern(try self.newTmp());
                    try self.recordReg(binding_reg);
                    try self.emitStdMacroFragment("sa_std/core/result.sa", "RESULT_GET_ERR", &.{
                        self.symbols.items[binding_reg],
                        self.symbols.items[value_reg],
                    });
                    try self.pushTypedLocal(pattern.bindings[0], binding_reg, false, err_ty);
                }
            },
        }
    }

    fn fieldLayout(self: *Codegen, ty: *const ast.Type, name: []const u8) !FieldLayout {
        const decl = self.structDeclForType(ty) orelse return Error.UnsupportedSabDirectFeature;
        if (decl.is_opaque) return Error.UnsupportedSabDirectFeature;
        const layout = lowering_rules.structFieldLayout(decl, name) orelse return Error.UnsupportedSabDirectFeature;
        return .{ .offset = layout.offset, .ty = try storagePrimType(layout.ty) };
    }

    fn typeHasCopyDerive(self: *Codegen, ty: *const ast.Type) bool {
        return switch (ty.*) {
            .primitive => true,
            .user_defined => blk: {
                const cache_name: ?[]const u8 = if (ty.user_defined.generics.len == 0) ty.user_defined.name else null;
                if (cache_name) |name| {
                    if (self.copy_value_cache.get(name)) |cached| break :blk cached;
                }
                if (userDefinedStdOwnerIsNonCopy(ty)) {
                    if (cache_name) |name| self.copy_value_cache.put(name, false) catch {};
                    break :blk false;
                }
                const decl = self.structDeclForType(ty) orelse {
                    if (cache_name) |name| self.copy_value_cache.put(name, false) catch {};
                    break :blk false;
                };
                if (!lowering_rules.structHasDerive(decl, "copy") or decl.is_opaque or decl.is_union) {
                    if (cache_name) |name| self.copy_value_cache.put(name, false) catch {};
                    break :blk false;
                }
                var result = true;
                for (decl.fields) |field| {
                    if (!self.typeHasCopyDerive(field.ty)) {
                        result = false;
                        break;
                    }
                }
                if (cache_name) |name| self.copy_value_cache.put(name, result) catch {};
                break :blk result;
            },
            else => false,
        };
    }

    fn userDefinedStdOwnerIsNonCopy(ty: *const ast.Type) bool {
        if (ty.* != .user_defined) return false;
        const name = ty.user_defined.name;
        return std.mem.eql(u8, name, "Vec") or
            std.mem.eql(u8, name, "VecDeque") or
            std.mem.eql(u8, name, "String") or
            std.mem.eql(u8, name, "Box") or
            std.mem.eql(u8, name, "Rc") or
            std.mem.eql(u8, name, "Arc") or
            std.mem.eql(u8, name, "HashMap") or
            std.mem.eql(u8, name, "BTreeMap") or
            std.mem.eql(u8, name, "HashSet") or
            std.mem.eql(u8, name, "BTreeSet") or
            std.mem.eql(u8, name, "RefCell") or
            std.mem.eql(u8, name, "Mutex") or
            std.mem.eql(u8, name, "RwLock") or
            std.mem.eql(u8, name, "JoinHandle");
    }

    fn typeIsCopyStruct(self: *Codegen, ty: *const ast.Type) bool {
        return self.structDeclForType(ty) != null and self.typeHasCopyDerive(ty);
    }

    fn typeIsCopyValue(self: *Codegen, ty: *const ast.Type) bool {
        return switch (ty.*) {
            .primitive => |p| p != .void_type,
            .fn_ptr => true,
            .user_defined => self.typeHasCopyDerive(ty),
            .tuple => |tuple| blk: {
                for (tuple.elems) |elem| {
                    if (!self.typeIsCopyValue(elem)) break :blk false;
                }
                break :blk true;
            },
            else => false,
        };
    }

    fn typeIsShallowCopyCallArgValue(self: *Codegen, ty: *const ast.Type, depth: usize) bool {
        if (depth > 8) return false;
        return switch (ty.*) {
            .primitive => true,
            .pointer, .borrow, .fn_ptr => true,
            .tuple => |tuple| blk: {
                for (tuple.elems) |elem| {
                    if (!self.typeIsShallowCopyCallArgValue(elem, depth + 1)) break :blk false;
                }
                break :blk true;
            },
            .array => |arr| self.typeIsShallowCopyCallArgValue(arr.elem, depth + 1),
            .user_defined => blk: {
                if (userDefinedStdOwnerIsNonCopy(ty)) break :blk false;
                const decl = self.structDeclForType(ty) orelse break :blk false;
                if (decl.is_opaque or decl.is_union) break :blk false;
                for (decl.fields) |field| {
                    if (!self.typeIsShallowCopyCallArgValue(field.ty, depth + 1)) break :blk false;
                }
                break :blk true;
            },
            else => false,
        };
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
        if (lowering_rules.vecElementType(ty)) |elem_ty| return lowering_rules.vecElementSlotSize(elem_ty);
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

    fn stdSurfaceArgMustBeLiteral(kind: StdSurfaceArgKind) bool {
        return switch (kind) {
            .elem_ty => true,
            else => false,
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
        try self.ensureRuleDeps(rule);
        var args = std.ArrayList([]const u8).init(self.allocator);
        defer args.deinit();
        var literal_args = std.ArrayList(bool).init(self.allocator);
        defer literal_args.deinit();
        for (rule.args) |arg_kind| {
            try args.append(try self.stdSurfaceArgText(arg_kind, values));
            try literal_args.append(stdSurfaceArgMustBeLiteral(arg_kind));
        }
        const macro_name = try self.stdSurfaceMacroName(rule, values);
        defer self.allocator.free(macro_name);
        try self.emitStdMacroFragmentWithLiteralArgs(rule.import_path, macro_name, args.items, literal_args.items);
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

    fn isFutureTaskRuntimeCall(call: ast.CallExpr) bool {
        return lowering_rules.planTaskRuntimeCall(call) != null or
            lowering_rules.planExecutorRuntimeCall(call) != null;
    }

    fn nodeUsesFutureTaskRuntime(node: *const ast.Node) bool {
        return switch (node.*) {
            .func_decl => |f| blockUsesFutureTaskRuntime(f.body),
            .test_decl => |t| blockUsesFutureTaskRuntime(t.body),
            .let_stmt => |let| nodeUsesFutureTaskRuntime(let.value),
            .let_destructure_stmt => |let| nodeUsesFutureTaskRuntime(let.value),
            .let_else_stmt => |let| nodeUsesFutureTaskRuntime(let.value) or blockUsesFutureTaskRuntime(let.else_block),
            .const_stmt => |c| nodeUsesFutureTaskRuntime(c.value),
            .assign_stmt => |assign| nodeUsesFutureTaskRuntime(assign.target) or nodeUsesFutureTaskRuntime(assign.value),
            .expr_stmt => |expr| nodeUsesFutureTaskRuntime(expr),
            .return_stmt => |ret| if (ret.value) |value| nodeUsesFutureTaskRuntime(value) else false,
            .block_stmt => |block| blockUsesFutureTaskRuntime(block.body),
            .await_expr => |aw| nodeUsesFutureTaskRuntime(aw.expr),
            .binary_expr => |bin| nodeUsesFutureTaskRuntime(bin.left) or nodeUsesFutureTaskRuntime(bin.right),
            .borrow_expr => |borrow| nodeUsesFutureTaskRuntime(borrow.expr),
            .move_expr => |move| nodeUsesFutureTaskRuntime(move.expr),
            .deref_expr => |deref| nodeUsesFutureTaskRuntime(deref.expr),
            .cast_expr => |cast| nodeUsesFutureTaskRuntime(cast.expr),
            .field_expr => |field| nodeUsesFutureTaskRuntime(field.expr),
            .try_expr => |try_expr| nodeUsesFutureTaskRuntime(try_expr.expr),
            .unsafe_expr => |unsafe_expr| blockUsesFutureTaskRuntime(unsafe_expr.body),
            .struct_literal => |lit| blk: {
                for (lit.fields) |field| {
                    if (nodeUsesFutureTaskRuntime(field.value)) break :blk true;
                }
                if (lit.update_expr) |update| {
                    if (nodeUsesFutureTaskRuntime(update)) break :blk true;
                }
                break :blk false;
            },
            .tuple_literal => |lit| blk: {
                for (lit.elements) |elem| {
                    if (nodeUsesFutureTaskRuntime(elem)) break :blk true;
                }
                break :blk false;
            },
            .array_literal => |lit| blk: {
                for (lit.elements) |elem| {
                    if (nodeUsesFutureTaskRuntime(elem)) break :blk true;
                }
                break :blk false;
            },
            .enum_literal => |lit| blk: {
                for (lit.fields) |field| {
                    if (nodeUsesFutureTaskRuntime(field.value)) break :blk true;
                }
                break :blk false;
            },
            .repeat_array_literal => |lit| nodeUsesFutureTaskRuntime(lit.value),
            .closure_literal => |lit| nodeUsesFutureTaskRuntime(lit.body),
            .call_expr => |call| blk: {
                if (isFutureTaskRuntimeCall(call)) break :blk true;
                for (call.args) |arg| {
                    if (nodeUsesFutureTaskRuntime(arg)) break :blk true;
                }
                break :blk false;
            },
            .index_expr => |idx| nodeUsesFutureTaskRuntime(idx.target) or nodeUsesFutureTaskRuntime(idx.index),
            .slice_expr => |slc| nodeUsesFutureTaskRuntime(slc.target) or nodeUsesFutureTaskRuntime(slc.start) or nodeUsesFutureTaskRuntime(slc.end),
            .if_expr => |ife| blk: {
                if (nodeUsesFutureTaskRuntime(ife.cond)) break :blk true;
                if (ife.let_chain) |chain| {
                    for (chain) |cond| {
                        if (nodeUsesFutureTaskRuntime(cond.value)) break :blk true;
                    }
                }
                if (blockUsesFutureTaskRuntime(ife.then_block)) break :blk true;
                if (ife.else_block) |else_block| {
                    if (blockUsesFutureTaskRuntime(else_block)) break :blk true;
                }
                break :blk false;
            },
            .switch_expr => |sw| blk: {
                if (nodeUsesFutureTaskRuntime(sw.val)) break :blk true;
                for (sw.cases) |case| {
                    if (nodeUsesFutureTaskRuntime(case.pattern)) break :blk true;
                    if (blockUsesFutureTaskRuntime(case.body)) break :blk true;
                }
                break :blk false;
            },
            .match_expr => |mat| blk: {
                if (nodeUsesFutureTaskRuntime(mat.val)) break :blk true;
                for (mat.cases) |case| {
                    if (case.guard) |guard| {
                        if (nodeUsesFutureTaskRuntime(guard)) break :blk true;
                    }
                    if (blockUsesFutureTaskRuntime(case.body)) break :blk true;
                }
                break :blk false;
            },
            .while_stmt => |w| nodeUsesFutureTaskRuntime(w.cond) or blockUsesFutureTaskRuntime(w.body),
            .for_stmt => |f| nodeUsesFutureTaskRuntime(f.start) or
                (if (f.end) |end| nodeUsesFutureTaskRuntime(end) else false) or
                blockUsesFutureTaskRuntime(f.body),
            .impl_decl => |impl| block: {
                for (impl.methods) |method| {
                    if (nodeUsesFutureTaskRuntime(method)) break :block true;
                }
                break :block false;
            },
            .overload_decl => |overload| block: {
                for (overload.methods) |method| {
                    if (nodeUsesFutureTaskRuntime(method)) break :block true;
                }
                break :block false;
            },
            else => false,
        };
    }

    fn blockUsesFutureTaskRuntime(body: []const *ast.Node) bool {
        for (body) |stmt| {
            if (nodeUsesFutureTaskRuntime(stmt)) return true;
        }
        return false;
    }

    fn programUsesFutureTaskRuntime(program: *const ast.Node) bool {
        if (program.* != .program) return false;
        for (program.program.decls) |decl| {
            if (nodeUsesFutureTaskRuntime(decl)) return true;
        }
        return false;
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
                if (std.mem.eql(u8, call.func_name, "println") and call.associated_target == null) try self.ensurePrintlnDeps();
                if (std.mem.eql(u8, call.func_name, "debug") and call.args.len == 1) try self.ensureDebugFormatDeps();
                if (call.associated_target == null and std.mem.eql(u8, call.func_name, "vec")) {
                    if (self.tc.expr_types.get(node)) |expr_ty| {
                        if (lowering_rules.vecElementType(expr_ty) != null) try self.ensureStdDeps("sa_std/vec.sa", &.{ "sa_vec_new", "sa_vec_push", "sa_mem_copy" });
                    }
                }
                if (call.associated_target == null and std.mem.eql(u8, call.func_name, "pop") and call.args.len == 1) {
                    if (self.tc.expr_types.get(call.args[0])) |receiver_ty| {
                        if (lowering_rules.vecElementType(receiver_ty) != null) try self.ensureStdDeps("sa_std/vec.sa", &.{"sa_vec_try_pop"});
                    }
                }
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
                        if (self.findStdSurfaceRule(.index_address, target_type_name, null)) |rule| try self.ensureRuleDeps(rule);
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

    fn typeIsPointerScalarValue(ty: *const ast.Type) bool {
        return switch (ty.*) {
            .primitive => |prim| prim == .void_type,
            .pointer => true,
            else => false,
        };
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

    fn borrowedBindingNeedsStackStorage(self: *Codegen, name: []const u8, ty: *const ast.Type) bool {
        return lowering_rules.planBorrowedBindingStorage(self.borrowed_bindings.contains(name), ty).materialize_stack_slot;
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

    fn pushStackAllocTypedLocal(self: *Codegen, name: []const u8, reg: u32, ty: *const ast.Type) !void {
        try self.recordReg(reg);
        try self.locals.append(.{ .name = name, .reg = reg, .is_param = false, .is_stack_alloc = true, .ty = ty });
    }

    fn beginFunction(self: *Codegen) void {
        self.in_function_body = true;
        self.current_reg_ids.clearRetainingCapacity();
        self.current_reg_seen.clearRetainingCapacity();
        self.released_regs.clearRetainingCapacity();
        self.stack_alloc_emitted.clearRetainingCapacity();
        self.multi_let_bindings.clearRetainingCapacity();
        self.loop_continue_labels.clearRetainingCapacity();
        self.loop_break_labels.clearRetainingCapacity();
        self.closure_bindings.clearRetainingCapacity();
        self.closure_param_regs.clearRetainingCapacity();
        self.borrowed_bindings.clearRetainingCapacity();
        self.clearRefCellBorrowValues();
        self.result_slot_refcell_handles.clearRetainingCapacity();
        self.result_slot_refcell_slots.clearRetainingCapacity();
        self.clearBorrowAddressTemps();
        self.non_owning_regs.clearRetainingCapacity();
        self.future_state_vtables.clearRetainingCapacity();
        self.future_readiness.clearRetainingCapacity();
        self.future_readiness_by_name.clearRetainingCapacity();
    }

    fn finishFunctionBody(self: *Codegen, sig_idx: usize) !void {
        self.function_sigs.items[sig_idx].reg_ids = try self.finishFunctionRegs();
        self.in_function_body = false;
        try self.flushPendingStdDeps();
    }

    fn freeBorrowAddressTempSlices(self: *Codegen, map: *std.AutoHashMap(u32, BorrowAddressTempState)) void {
        var iter = map.valueIterator();
        while (iter.next()) |state| {
            if (state.release_regs.len != 0) self.allocator.free(state.release_regs);
        }
    }

    fn clearBorrowAddressTemps(self: *Codegen) void {
        self.freeBorrowAddressTempSlices(&self.borrow_address_temps);
        self.borrow_address_temps.clearRetainingCapacity();
    }

    fn cloneBorrowAddressTemps(self: *Codegen) !std.AutoHashMap(u32, BorrowAddressTempState) {
        var clone = std.AutoHashMap(u32, BorrowAddressTempState).init(self.allocator);
        errdefer self.deinitBorrowAddressTempSnapshot(&clone);

        var iter = self.borrow_address_temps.iterator();
        while (iter.next()) |entry| {
            const state = entry.value_ptr.*;
            const copied = if (state.release_regs.len == 0) &.{} else try self.allocator.dupe(u32, state.release_regs);
            try clone.put(entry.key_ptr.*, .{
                .release_regs = copied,
                .restore_slot = state.restore_slot,
                .restore_value = state.restore_value,
            });
        }
        return clone;
    }

    fn deinitBorrowAddressTempSnapshot(self: *Codegen, snapshot: *std.AutoHashMap(u32, BorrowAddressTempState)) void {
        self.freeBorrowAddressTempSlices(snapshot);
        snapshot.deinit();
    }

    fn restoreBorrowAddressTemps(self: *Codegen, snapshot: *const std.AutoHashMap(u32, BorrowAddressTempState)) !void {
        self.clearBorrowAddressTemps();
        var iter = snapshot.iterator();
        while (iter.next()) |entry| {
            const state = entry.value_ptr.*;
            const copied = if (state.release_regs.len == 0) &.{} else try self.allocator.dupe(u32, state.release_regs);
            try self.borrow_address_temps.put(entry.key_ptr.*, .{
                .release_regs = copied,
                .restore_slot = state.restore_slot,
                .restore_value = state.restore_value,
            });
        }
    }

    fn freeRefCellBorrowValueSlices(self: *Codegen, map: *std.AutoHashMap(u32, RefCellBorrowValue)) void {
        var iter = map.valueIterator();
        while (iter.next()) |value| {
            if (value.release_regs.len != 0) self.allocator.free(value.release_regs);
        }
    }

    fn clearRefCellBorrowValues(self: *Codegen) void {
        self.freeRefCellBorrowValueSlices(&self.refcell_borrow_values);
        self.refcell_borrow_values.clearRetainingCapacity();
    }

    fn cloneRefCellBorrowValues(self: *Codegen) !std.AutoHashMap(u32, RefCellBorrowValue) {
        var clone = std.AutoHashMap(u32, RefCellBorrowValue).init(self.allocator);
        errdefer self.deinitRefCellBorrowValueSnapshot(&clone);

        var iter = self.refcell_borrow_values.iterator();
        while (iter.next()) |entry| {
            const value = entry.value_ptr.*;
            const copied_release_regs = if (value.release_regs.len == 0) &.{} else try self.allocator.dupe(u32, value.release_regs);
            try clone.put(entry.key_ptr.*, .{
                .cell_reg = value.cell_reg,
                .kind = value.kind,
                .release_regs = copied_release_regs,
            });
        }
        return clone;
    }

    fn deinitRefCellBorrowValueSnapshot(self: *Codegen, snapshot: *std.AutoHashMap(u32, RefCellBorrowValue)) void {
        self.freeRefCellBorrowValueSlices(snapshot);
        snapshot.deinit();
    }

    fn cloneBranchEmitterState(self: *Codegen) !BranchEmitterStateSnapshot {
        var released = try self.released_regs.clone();
        errdefer released.deinit();
        var refcell_values = try self.cloneRefCellBorrowValues();
        errdefer self.deinitRefCellBorrowValueSnapshot(&refcell_values);
        var borrow_temps = try self.cloneBorrowAddressTemps();
        errdefer self.deinitBorrowAddressTempSnapshot(&borrow_temps);
        return .{
            .released = released,
            .refcell_values = refcell_values,
            .borrow_temps = borrow_temps,
        };
    }

    fn deinitBranchEmitterStateSnapshot(self: *Codegen, snapshot: *BranchEmitterStateSnapshot) void {
        snapshot.released.deinit();
        self.deinitRefCellBorrowValueSnapshot(&snapshot.refcell_values);
        self.deinitBorrowAddressTempSnapshot(&snapshot.borrow_temps);
    }

    fn appendCurrentBranchEmitterState(self: *Codegen, snapshots: *std.ArrayList(BranchEmitterStateSnapshot)) !void {
        var snapshot = try self.cloneBranchEmitterState();
        errdefer self.deinitBranchEmitterStateSnapshot(&snapshot);
        try snapshots.append(snapshot);
    }

    fn refCellBorrowValueEqual(left: RefCellBorrowValue, right: RefCellBorrowValue) bool {
        return left.cell_reg == right.cell_reg and left.kind == right.kind and std.mem.eql(u32, left.release_regs, right.release_regs);
    }

    fn setMergeBranchEmitterState(
        self: *Codegen,
        live_snapshots: []const BranchEmitterStateSnapshot,
        pre_snapshot: *const BranchEmitterStateSnapshot,
    ) !void {
        switch (lowering_rules.planMultiBranchStateMerge(live_snapshots.len)) {
            .restore_pre => {
                try self.restoreReleased(&pre_snapshot.released);
                try self.restoreRefCellBranchState(&pre_snapshot.refcell_values, &pre_snapshot.borrow_temps);
            },
            .restore_single => {
                try self.restoreReleased(&live_snapshots[0].released);
                try self.restoreRefCellBranchState(&live_snapshots[0].refcell_values, &live_snapshots[0].borrow_temps);
            },
            .intersect_live => {
                self.released_regs.clearRetainingCapacity();
                var released_iter = live_snapshots[0].released.iterator();
                while (released_iter.next()) |entry| {
                    const reg = entry.key_ptr.*;
                    var shared = true;
                    for (live_snapshots[1..]) |snapshot| {
                        if (!snapshot.released.contains(reg)) {
                            shared = false;
                            break;
                        }
                    }
                    if (shared) try self.released_regs.put(reg, {});
                }

                self.clearRefCellBorrowValues();
                var value_iter = live_snapshots[0].refcell_values.iterator();
                while (value_iter.next()) |entry| {
                    const reg = entry.key_ptr.*;
                    const value = entry.value_ptr.*;
                    var shared = true;
                    for (live_snapshots[1..]) |snapshot| {
                        const other = snapshot.refcell_values.get(reg) orelse {
                            shared = false;
                            break;
                        };
                        if (!refCellBorrowValueEqual(value, other)) {
                            shared = false;
                            break;
                        }
                    }
                    if (shared) {
                        const copied_release_regs = if (value.release_regs.len == 0) &.{} else try self.allocator.dupe(u32, value.release_regs);
                        try self.refcell_borrow_values.put(reg, .{
                            .cell_reg = value.cell_reg,
                            .kind = value.kind,
                            .release_regs = copied_release_regs,
                        });
                    }
                }

                self.clearBorrowAddressTemps();
                var temp_iter = live_snapshots[0].borrow_temps.iterator();
                while (temp_iter.next()) |entry| {
                    const reg = entry.key_ptr.*;
                    const state = entry.value_ptr.*;
                    var shared = true;
                    for (live_snapshots[1..]) |snapshot| {
                        const other = snapshot.borrow_temps.get(reg) orelse {
                            shared = false;
                            break;
                        };
                        if (!std.mem.eql(u32, state.release_regs, other.release_regs) or
                            state.restore_slot != other.restore_slot or
                            state.restore_value != other.restore_value)
                        {
                            shared = false;
                            break;
                        }
                    }
                    if (shared) {
                        const copied = if (state.release_regs.len == 0) &.{} else try self.allocator.dupe(u32, state.release_regs);
                        try self.borrow_address_temps.put(reg, .{
                            .release_regs = copied,
                            .restore_slot = state.restore_slot,
                            .restore_value = state.restore_value,
                        });
                    }
                }
            },
        }
    }

    fn restoreRefCellBorrowValues(self: *Codegen, snapshot: *const std.AutoHashMap(u32, RefCellBorrowValue)) !void {
        self.clearRefCellBorrowValues();
        var iter = snapshot.iterator();
        while (iter.next()) |entry| {
            const value = entry.value_ptr.*;
            const copied_release_regs = if (value.release_regs.len == 0) &.{} else try self.allocator.dupe(u32, value.release_regs);
            try self.refcell_borrow_values.put(entry.key_ptr.*, .{
                .cell_reg = value.cell_reg,
                .kind = value.kind,
                .release_regs = copied_release_regs,
            });
        }
    }

    fn restoreRefCellBranchState(
        self: *Codegen,
        values: *const std.AutoHashMap(u32, RefCellBorrowValue),
        temps: *const std.AutoHashMap(u32, BorrowAddressTempState),
    ) !void {
        try self.restoreRefCellBorrowValues(values);
        try self.restoreBorrowAddressTemps(temps);
    }

    fn setMergeRefCellBranchState(
        self: *Codegen,
        then_terminated: bool,
        then_values: *const std.AutoHashMap(u32, RefCellBorrowValue),
        then_temps: *const std.AutoHashMap(u32, BorrowAddressTempState),
        else_terminated: bool,
        else_values: *const std.AutoHashMap(u32, RefCellBorrowValue),
        else_temps: *const std.AutoHashMap(u32, BorrowAddressTempState),
        pre_values: *const std.AutoHashMap(u32, RefCellBorrowValue),
        pre_temps: *const std.AutoHashMap(u32, BorrowAddressTempState),
    ) !void {
        switch (lowering_rules.planRefCellBranchStateMerge(then_terminated, else_terminated)) {
            .restore_pre => try self.restoreRefCellBranchState(pre_values, pre_temps),
            .restore_then => try self.restoreRefCellBranchState(then_values, then_temps),
            .restore_else => try self.restoreRefCellBranchState(else_values, else_temps),
            .keep_current => {},
        }
    }

    fn singleReleaseReg(self: *Codegen, reg: u32) ![]const u32 {
        var regs = [_]u32{reg};
        return try self.allocator.dupe(u32, regs[0..]);
    }

    fn ownedReleaseRegs(self: *Codegen, regs: []const u32) ![]const u32 {
        if (regs.len == 0) return &.{};
        return try self.allocator.dupe(u32, regs);
    }

    fn rememberBorrowAddressTemps(self: *Codegen, borrow_reg: u32, source: AddressSource) !void {
        const plan = lowering_rules.planBorrowAddressTemps(!self.isLocalReg(source.reg), source.release_regs.len != 0);
        if (!plan.remember and source.restore_slot == null) return;
        var regs = std.ArrayList(u32).init(self.allocator);
        defer regs.deinit();
        if (plan.track_primary_temp) try regs.append(source.reg);
        if (plan.track_extra_temps) try regs.appendSlice(source.release_regs);
        try self.borrow_address_temps.put(borrow_reg, .{
            .release_regs = try regs.toOwnedSlice(),
            .restore_slot = source.restore_slot,
            .restore_value = if (source.restore_slot != null) source.reg else null,
        });
    }

    fn rebindRefCellBorrowValueOwners(self: *Codegen, src: u32, dst: u32) void {
        if (src == dst) return;
        var iter = self.refcell_borrow_values.valueIterator();
        while (iter.next()) |handle| {
            switch (lowering_rules.planRefCellHandleOwnerTransfer(handle.cell_reg == src)) {
                .keep_owner => {},
                .rebind_owner => handle.cell_reg = dst,
            }
        }
    }

    fn transferReleaseMetadata(self: *Codegen, dst: u32, src: u32) !void {
        if (dst == src) return;
        self.rebindRefCellBorrowValueOwners(src, dst);
        const refcell_transfer_plan = lowering_rules.planRefCellValueStateTransfer(
            self.refcell_borrow_values.contains(src),
            self.borrow_address_temps.contains(src),
        );
        switch (refcell_transfer_plan.handle) {
            .move_borrow_handle => if (self.refcell_borrow_values.fetchRemove(src)) |entry| {
                _ = self.refcell_borrow_values.remove(dst);
                try self.refcell_borrow_values.put(dst, entry.value);
            },
            .transfer_value_state => {},
        }
        switch (refcell_transfer_plan.borrow_address_temps) {
            .move_borrow_address_temps => if (self.borrow_address_temps.fetchRemove(src)) |entry| {
                if (self.borrow_address_temps.fetchRemove(dst)) |old| {
                    if (old.value.release_regs.len != 0) self.allocator.free(old.value.release_regs);
                }
                try self.borrow_address_temps.put(dst, entry.value);
            },
            .transfer_value_state => {},
        }
        if (self.non_owning_regs.fetchRemove(src)) |_| {
            try self.non_owning_regs.put(dst, {});
        }
    }

    fn transferResultSlotValueState(self: *Codegen, dst: u32, src: u32, consume_src: bool) !void {
        if (dst == src) return;
        try self.transferReleaseMetadata(dst, src);
        try self.transferFutureStateVTable(src, dst);
        try self.transferFutureReadiness(src, dst);
        if (consume_src) try self.markConsumed(src);
    }

    fn ensureResultSlotRefCellSlot(self: *Codegen, slot: u32) !u32 {
        if (self.result_slot_refcell_slots.get(slot)) |existing| return existing;
        const cell_slot = try self.intern(try self.newTmp());
        try self.emitAlloc(cell_slot, 8);
        try self.result_slot_refcell_slots.put(slot, cell_slot);
        return cell_slot;
    }

    fn prepareResultSlotRefCellCompanion(self: *Codegen, slot: u32, target_ty: *const ast.Type) !void {
        if (!lowering_rules.planResultSlotTransfer(target_ty).needs_refcell_companion) return;
        _ = try self.ensureResultSlotRefCellSlot(slot);
    }

    fn ensureResultSlotRefCellHandle(self: *Codegen, slot: u32, kind: lowering_rules.RefCellBorrowKind) !ResultSlotRefCellHandle {
        if (self.result_slot_refcell_handles.get(slot)) |existing| {
            const updated = ResultSlotRefCellHandle{ .cell_slot = existing.cell_slot, .kind = kind };
            try self.result_slot_refcell_handles.put(slot, updated);
            return updated;
        }
        const cell_slot = try self.ensureResultSlotRefCellSlot(slot);
        const meta = ResultSlotRefCellHandle{ .cell_slot = cell_slot, .kind = kind };
        try self.result_slot_refcell_handles.put(slot, meta);
        return meta;
    }

    fn storeResultSlotTransferredValue(self: *Codegen, slot: u32, src: u32, target_ty: *const ast.Type) !void {
        const plan = lowering_rules.planResultSlotTransfer(target_ty);
        switch (lowering_rules.planResultSlotStoreLifecycle(plan, !self.isLocalReg(src))) {
            .release_source => return self.emitRelease(src),
            .keep_source => return,
            .transfer_value_state => {},
        }

        switch (lowering_rules.planResultSlotRefCellStore(plan, self.refcell_borrow_values.contains(src))) {
            .store_borrow_handle_companion => {
                if (self.refcell_borrow_values.fetchRemove(src)) |entry| {
                    const meta = try self.ensureResultSlotRefCellHandle(slot, entry.value.kind);
                    try self.emitStore(meta.cell_slot, 0, entry.value.cell_reg, .ptr);
                    const cleanup_plan = lowering_rules.planRefCellCompanionStoreCleanup(
                        entry.value.release_regs.len != 0,
                        self.borrow_address_temps.contains(src),
                        self.non_owning_regs.contains(src),
                    );
                    if (cleanup_plan.release_owner_temps) {
                        try self.releaseNonLocalTemps(entry.value.release_regs);
                        self.allocator.free(entry.value.release_regs);
                    } else if (entry.value.release_regs.len != 0) {
                        self.allocator.free(entry.value.release_regs);
                    }
                    if (cleanup_plan.release_borrow_address_temps) {
                        if (self.borrow_address_temps.fetchRemove(src)) |temps| {
                            if (temps.value.restore_slot) |restore_slot| {
                                const restore_value = temps.value.restore_value orelse return Error.UnsupportedSabDirectFeature;
                                try self.emitStore(restore_slot, 0, restore_value, .ptr);
                                try self.markConsumed(restore_value);
                            }
                            try self.releaseNonLocalTemps(temps.value.release_regs);
                            if (temps.value.release_regs.len != 0) self.allocator.free(temps.value.release_regs);
                        }
                    }
                    if (cleanup_plan.clear_non_owning_metadata) _ = self.non_owning_regs.fetchRemove(src);
                    if (cleanup_plan.consume_handle_value) try self.markConsumed(src);
                    return;
                }
            },
            .transfer_value_state => {},
        }

        try self.transferResultSlotValueState(slot, src, true);
    }

    fn loadResultSlotTransferredValue(self: *Codegen, dst: u32, slot: u32, target_ty: *const ast.Type) !void {
        const plan = lowering_rules.planResultSlotTransfer(target_ty);
        switch (lowering_rules.planResultSlotLoadLifecycle(plan)) {
            .no_value_state => return,
            .load_value_state => {},
        }
        switch (lowering_rules.planResultSlotRefCellLoad(
            plan,
            self.result_slot_refcell_handles.contains(slot),
            self.result_slot_refcell_slots.contains(slot),
        )) {
            .restore_borrow_handle_companion => if (self.result_slot_refcell_handles.fetchRemove(slot)) |entry| {
                _ = self.result_slot_refcell_slots.fetchRemove(slot);
                const cell_reg = try self.intern(try self.newTmp());
                const restore_plan = lowering_rules.planRefCellCompanionRestore();
                try self.emitLoad(cell_reg, entry.value.cell_slot, 0, .ptr);
                const release_regs = if (restore_plan.track_loaded_cell_owner_temp) try self.singleReleaseReg(cell_reg) else &.{};
                try self.refcell_borrow_values.put(dst, .{
                    .cell_reg = cell_reg,
                    .kind = entry.value.kind,
                    .release_regs = release_regs,
                });
                if (restore_plan.release_companion_slot_after_restore) try self.emitRelease(entry.value.cell_slot);
            },
            .release_empty_companion => if (self.result_slot_refcell_slots.fetchRemove(slot)) |entry| {
                try self.emitRelease(entry.value);
            },
            .transfer_value_state => {},
        }
        try self.transferResultSlotValueState(dst, slot, false);
    }

    fn markNonOwningReg(self: *Codegen, reg: u32) !void {
        try self.non_owning_regs.put(reg, {});
    }

    fn collectBorrowedBindingsInBlock(self: *Codegen, body: []const *ast.Node) anyerror!void {
        for (body) |node| try self.collectBorrowedBindingsInNode(node);
    }

    fn collectBorrowedBindingsInNode(self: *Codegen, node: *const ast.Node) anyerror!void {
        switch (node.*) {
            .borrow_expr => |borrow| {
                if (lowering_rules.borrowedIdentifierName(node)) |name| try self.borrowed_bindings.put(name, {});
                try self.collectBorrowedBindingsInNode(borrow.expr);
            },
            .move_expr => |move| try self.collectBorrowedBindingsInNode(move.expr),
            .deref_expr => |deref| try self.collectBorrowedBindingsInNode(deref.expr),
            .cast_expr => |cast| try self.collectBorrowedBindingsInNode(cast.expr),
            .binary_expr => |bin| {
                try self.collectBorrowedBindingsInNode(bin.left);
                try self.collectBorrowedBindingsInNode(bin.right);
            },
            .call_expr => |call| {
                if (lowering_rules.planImportedMacroCall(self.tc, call)) |plan| {
                    for (call.args, 0..) |arg, i| {
                        if (plan.addressableIdentifierArgName(i, arg)) |name| try self.borrowed_bindings.put(name, {});
                    }
                }
                for (call.args) |arg| try self.collectBorrowedBindingsInNode(arg);
            },
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

    fn paramCleanupAction(self: *Codegen, local: Local) !ParamCleanupAction {
        if (!local.is_param) return .release;
        const cap = local.param_cap orelse return .skip;
        if (cap == .raw) return .skip;
        if (cap == .borrow) return .release;
        const ty = local.ty orelse return .skip;
        if (cap == .by_value and (try primType(ty)) == .ptr) return .consume;
        if (cap == .by_value and self.typeIsCopyValue(ty)) return .skip;
        if (ty.* == .fn_ptr) return .consume;
        if (self.typeIsCopyValue(ty)) return .consume;
        if ((try primType(ty)) == .ptr) return .consume;
        return .skip;
    }

    fn releaseLocalsFrom(self: *Codegen, start: usize, except: ?u32) !void {
        var i = self.locals.items.len;
        while (i > start) {
            i -= 1;
            const local = self.locals.items[i];
            if (except != null and local.reg == except.?) continue;
            if (self.released_regs.contains(local.reg)) continue;
            if (local.is_param) switch (try self.paramCleanupAction(local)) {
                .skip => continue,
                .mark_consumed => {
                    try self.markConsumed(local.reg);
                    continue;
                },
                .consume => {
                    try self.emitMove(local.reg);
                    continue;
                },
                .release => {},
            };
            if (local.stack_ty != null) {
                try self.releaseStackLocalValue(local);
                continue;
            }
            if (local.is_stack_alloc) {
                if (self.stack_alloc_emitted.contains(local.reg)) try self.emitRelease(local.reg);
                continue;
            }
            try self.emitRelease(local.reg);
        }
    }

    fn emitBranchReleaseLocalsFrom(self: *Codegen, start: usize, except: ?u32) !void {
        var seen = std.AutoHashMap(u32, void).init(self.allocator);
        defer seen.deinit();

        var i = self.locals.items.len;
        while (i > start) {
            i -= 1;
            const local = self.locals.items[i];
            if (except != null and local.reg == except.?) continue;
            if (self.released_regs.contains(local.reg)) continue;
            if (local.is_param) switch (try self.paramCleanupAction(local)) {
                .skip => continue,
                .mark_consumed => {
                    try self.markConsumed(local.reg);
                    continue;
                },
                .consume => {
                    try self.emitBranchMove(local.reg);
                    continue;
                },
                .release => {},
            };
            if (local.stack_ty != null) {
                try self.releaseStackLocalValue(local);
                continue;
            }
            if (local.is_stack_alloc) {
                if (self.stack_alloc_emitted.contains(local.reg)) try self.emitBranchReleaseWithMetadata(local.reg, &seen);
                continue;
            }
            try self.emitBranchReleaseWithMetadata(local.reg, &seen);
        }
    }

    fn emitBalanceReleaseLocal(self: *Codegen, local: Local) !void {
        if (self.released_regs.contains(local.reg)) return;
        if (local.ty) |ty| {
            const abi_ty = primType(ty) catch return;
            if (abi_ty == .ptr) return;
        }
        if (local.is_param) switch (try self.paramCleanupAction(local)) {
            .skip => return,
            .mark_consumed => {
                try self.markConsumed(local.reg);
                return;
            },
            .consume => {
                try self.emitMove(local.reg);
                return;
            },
            .release => {},
        };
        if (local.stack_ty != null) return try self.releaseStackLocalValue(local);
        if (local.is_stack_alloc) {
            if (self.stack_alloc_emitted.contains(local.reg)) try self.emitRelease(local.reg);
            return;
        }
        try self.emitRelease(local.reg);
    }

    fn balanceBranchReleasedLocals(
        self: *Codegen,
        branch_locals_len: usize,
        branch_released: *std.AutoHashMap(u32, void),
        target_released: *const std.AutoHashMap(u32, void),
    ) !void {
        for (self.locals.items[0..branch_locals_len]) |local| {
            if (!target_released.contains(local.reg) or branch_released.contains(local.reg)) continue;
            const local_ty = local.ty orelse continue;
            if (lowering_rules.isBorrowLikeType(local_ty)) continue;
            try self.emitBalanceReleaseLocal(local);
            try branch_released.put(local.reg, {});
        }
    }

    fn releaseStackLocalValue(self: *Codegen, local: Local) !void {
        const ty = local.stack_ty orelse return;
        if (self.released_regs.contains(local.reg)) return;
        if (typeIsPointerScalarValue(ty)) {
            try self.markConsumed(local.reg);
            return;
        }
        if (self.stack_alloc_emitted.contains(local.reg)) {
            if (!self.typeIsCopyValue(ty)) {
                const value = try self.intern(try self.newTmp());
                try self.emitLoad(value, local.reg, 0, try storagePrimType(ty));
                try self.emitRelease(value);
            }
            try self.markConsumed(local.reg);
            return;
        }
        if (self.typeIsCopyValue(ty)) {
            try self.emitRelease(local.reg);
            return;
        }
        const value = try self.intern(try self.newTmp());
        try self.emitLoad(value, local.reg, 0, try storagePrimType(ty));
        try self.emitRelease(value);
        try self.emitRelease(local.reg);
    }

    fn releaseCleanupName(self: *Codegen, name: []const u8) !void {
        var i = self.locals.items.len;
        while (i > 0) {
            i -= 1;
            const local = self.locals.items[i];
            if (!std.mem.eql(u8, local.name, name)) continue;
            if (local.is_param) switch (try self.paramCleanupAction(local)) {
                .skip => return,
                .mark_consumed => {
                    try self.markConsumed(local.reg);
                    return;
                },
                .consume => {
                    if (!self.released_regs.contains(local.reg)) try self.emitMove(local.reg);
                    return;
                },
                .release => {},
            };
            if (local.stack_ty != null) return try self.releaseStackLocalValue(local);
            if (local.is_stack_alloc) {
                if (self.stack_alloc_emitted.contains(local.reg)) try self.emitRelease(local.reg);
                return;
            }
            if (self.released_regs.contains(local.reg)) return;
            try self.emitRelease(local.reg);
            return;
        }

        const reg = try self.intern(name);
        if (!self.released_regs.contains(reg)) try self.emitRelease(reg);
    }

    fn releaseCleanupForStmt(self: *Codegen, stmt: *const ast.Node) !void {
        if (self.tc.cleanups.get(stmt)) |list| {
            for (list.items) |name| try self.releaseCleanupName(name);
        }
    }

    fn emitBranchCleanupForNode(self: *Codegen, node: *const ast.Node) !void {
        var seen = std.AutoHashMap(u32, void).init(self.allocator);
        defer seen.deinit();
        if (self.active_macro_try_cleanup) |names| {
            for (names) |name| {
                var i = self.locals.items.len;
                while (i > 0) {
                    i -= 1;
                    const local = self.locals.items[i];
                    if (!std.mem.eql(u8, local.name, name)) continue;
                    if (local.stack_ty == null and !local.is_stack_alloc) try self.emitBranchReleaseWithMetadata(local.reg, &seen);
                    break;
                }
            }
            return;
        }
        if (self.tc.cleanups.get(node)) |list| {
            for (list.items) |name| {
                var reg: ?u32 = null;
                var i = self.locals.items.len;
                while (i > 0) {
                    i -= 1;
                    const local = self.locals.items[i];
                    if (!std.mem.eql(u8, local.name, name)) continue;
                    if (local.stack_ty == null and !local.is_stack_alloc) reg = local.reg;
                    break;
                }
                const value_reg = reg orelse continue;
                try self.emitBranchReleaseWithMetadata(value_reg, &seen);
            }
        }
    }

    fn genLoopJump(self: *Codegen, stmt: *const ast.Node, kind: LoopJumpKind) !void {
        try self.releaseCleanupForStmt(stmt);
        const labels = switch (kind) {
            .break_ => self.loop_break_labels.items,
            .continue_ => self.loop_continue_labels.items,
        };
        if (labels.len == 0) return Error.UnsupportedSabDirectFeature;
        try self.emitJmp(labels[labels.len - 1]);
    }

    fn genReleaseStmt(self: *Codegen, rel: ast.ReleaseStmt) !void {
        if (self.stackLocal(rel.var_name)) |local| return try self.releaseStackLocalValue(local);

        const reg = self.localReg(rel.var_name) orelse try self.intern(rel.var_name);
        if (self.localType(rel.var_name)) |ty| {
            if (self.typeIsCopyValue(ty)) {
                try self.markConsumed(reg);
                return;
            }
        }
        try self.emitRelease(reg);
    }

    fn genScopedBlock(self: *Codegen, body: []const *ast.Node) !void {
        const old_locals = self.locals.items.len;
        defer self.popLocalsTo(old_locals);
        try self.genBlock(body);
        if (!self.lastIsTerminator()) try self.releaseLocalsFrom(old_locals, null);
    }

    fn releaseOpenLocals(self: *Codegen, except: ?u32) !void {
        try self.releaseLocalsFrom(0, except);
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

    fn isParamReg(self: *Codegen, reg: u32) bool {
        for (self.locals.items) |local| {
            if (local.reg == reg) return local.is_param;
        }
        return false;
    }

    fn releaseNonLocalTemps(self: *Codegen, regs: []const u32) anyerror!void {
        for (regs) |reg| {
            if (!self.isLocalReg(reg)) try self.emitRelease(reg);
        }
    }

    fn releaseExprResultIfNeeded(self: *Codegen, expr: *const ast.Node, reg: u32) !void {
        if (expr.* == .identifier and self.stackLocal(expr.identifier) != null) {
            if (!self.isLocalReg(reg)) try self.emitRelease(reg);
            return;
        }
        if (!lowering_rules.exprResultNeedsRelease(expr)) return;
        if (!self.isLocalReg(reg)) try self.emitRelease(reg);
    }

    fn releaseStoredExprResultIfNeeded(self: *Codegen, expr: *const ast.Node, reg: u32, stored_ty: *const ast.Type) !void {
        if (expr.* == .identifier and self.stackLocal(expr.identifier) != null) {
            if (!self.isLocalReg(reg)) {
                if (typeIsPointerScalarValue(stored_ty)) try self.markNonOwningReg(reg);
                try self.emitRelease(reg);
            }
            return;
        }
        if (!lowering_rules.exprResultNeedsRelease(expr)) return;
        if (!self.isLocalReg(reg)) {
            if (typeIsPointerScalarValue(stored_ty)) try self.markNonOwningReg(reg);
            try self.emitRelease(reg);
        }
    }

    fn emitLabel(self: *Codegen, name: []const u8) !void {
        const id = try self.intern(name);
        var item = self.makeInst(.label);
        item.operands[0] = .{ .symbol = id };
        item.operands[1] = .{ .label = id };
        try self.appendInst(item);
    }

    fn emitRefCellBorrowRelease(self: *Codegen, handle: RefCellBorrowValue) !void {
        const release_plan = lowering_rules.planRefCellHandleRelease(handle.release_regs.len != 0);
        if (release_plan.release_dynamic_borrow) {
            try self.emitStdMacroFragment("sa_std/core/refcell.sa", lowering_rules.refCellBorrowReleaseMacroName(handle.kind), &.{
                self.symbols.items[handle.cell_reg],
            });
        }
        if (release_plan.release_owner_temps) try self.releaseNonLocalTemps(handle.release_regs);
        if (handle.release_regs.len != 0) self.allocator.free(handle.release_regs);
    }

    fn emitRefCellBorrowBranchRelease(self: *Codegen, handle: RefCellBorrowValue, seen: *std.AutoHashMap(u32, void)) anyerror!void {
        const release_plan = lowering_rules.planRefCellHandleRelease(handle.release_regs.len != 0);
        if (release_plan.release_dynamic_borrow) {
            try self.emitStdMacroFragment("sa_std/core/refcell.sa", lowering_rules.refCellBorrowReleaseMacroName(handle.kind), &.{
                self.symbols.items[handle.cell_reg],
            });
        }
        if (release_plan.release_owner_temps) {
            for (handle.release_regs) |reg| {
                if (!self.isLocalReg(reg)) try self.emitBranchReleaseWithMetadata(reg, seen);
            }
        }
    }

    fn emitRefCellBorrowReleasesForCell(self: *Codegen, cell_reg: u32) anyerror!void {
        var handles_to_release = std.ArrayList(u32).init(self.allocator);
        defer handles_to_release.deinit();

        var iter = self.refcell_borrow_values.iterator();
        while (iter.next()) |entry| {
            switch (lowering_rules.planRefCellHandleCellRelease(
                entry.value_ptr.cell_reg == cell_reg,
                entry.key_ptr.* == cell_reg,
            )) {
                .release_handle => try handles_to_release.append(entry.key_ptr.*),
                .skip => {},
            }
        }

        for (handles_to_release.items) |handle_reg| {
            if (!self.released_regs.contains(handle_reg)) try self.emitRelease(handle_reg);
        }
    }

    fn emitBranchReleaseWithMetadata(self: *Codegen, reg: u32, seen: *std.AutoHashMap(u32, void)) anyerror!void {
        if (seen.contains(reg)) return;
        try seen.put(reg, {});

        var handles_to_release = std.ArrayList(u32).init(self.allocator);
        defer handles_to_release.deinit();
        var iter = self.refcell_borrow_values.iterator();
        while (iter.next()) |entry| {
            switch (lowering_rules.planRefCellHandleCellRelease(
                entry.value_ptr.cell_reg == reg,
                entry.key_ptr.* == reg,
            )) {
                .release_handle => try handles_to_release.append(entry.key_ptr.*),
                .skip => {},
            }
        }
        for (handles_to_release.items) |handle_reg| try self.emitBranchReleaseWithMetadata(handle_reg, seen);

        if (self.refcell_borrow_values.get(reg)) |handle| {
            try self.emitRefCellBorrowBranchRelease(handle, seen);
        }
        if (self.non_owning_regs.contains(reg)) return;

        const borrow_temp_release = lowering_rules.planBorrowAddressTempRelease(self.borrow_address_temps.contains(reg));
        try self.emitBranchRelease(reg);
        if (borrow_temp_release.release_source_temps) {
            if (self.borrow_address_temps.get(reg)) |state| {
                if (state.restore_slot) |restore_slot| {
                    const restore_value = state.restore_value orelse return Error.UnsupportedSabDirectFeature;
                    try self.emitStore(restore_slot, 0, restore_value, .ptr);
                }
                for (state.release_regs) |temp| {
                    if (state.restore_value != null and temp == state.restore_value.?) continue;
                    try self.emitBranchReleaseWithMetadata(temp, seen);
                }
            }
        }
    }

    fn emitRelease(self: *Codegen, reg: u32) anyerror!void {
        if (self.released_regs.contains(reg)) return;
        try self.emitRefCellBorrowReleasesForCell(reg);
        if (self.refcell_borrow_values.fetchRemove(reg)) |entry| {
            try self.emitRefCellBorrowRelease(entry.value);
        }
        if (self.stack_alloc_emitted.contains(reg)) {
            _ = self.non_owning_regs.remove(reg);
            _ = self.future_state_vtables.remove(reg);
            _ = self.future_readiness.remove(reg);
            try self.released_regs.put(reg, {});
            return;
        }
        if (self.non_owning_regs.fetchRemove(reg)) |_| {
            var item = self.makeInst(.move_);
            item.operands[0] = .{ .reg = reg };
            try self.appendInst(item);
            try self.released_regs.put(reg, {});
            return;
        }
        const borrow_temp_release = lowering_rules.planBorrowAddressTempRelease(self.borrow_address_temps.contains(reg));
        _ = self.future_state_vtables.remove(reg);
        _ = self.future_readiness.remove(reg);
        var item = self.makeInst(.release);
        item.operands[0] = .{ .reg = reg };
        try self.appendInst(item);
        try self.released_regs.put(reg, {});
        if (borrow_temp_release.release_source_temps) {
            if (self.borrow_address_temps.fetchRemove(reg)) |entry| {
                if (entry.value.restore_slot) |restore_slot| {
                    const restore_value = entry.value.restore_value orelse return Error.UnsupportedSabDirectFeature;
                    try self.emitStore(restore_slot, 0, restore_value, .ptr);
                    try self.markConsumed(restore_value);
                }
                for (entry.value.release_regs) |temp| try self.emitRelease(temp);
                if (entry.value.release_regs.len != 0) self.allocator.free(entry.value.release_regs);
            }
        }
    }

    fn emitMove(self: *Codegen, reg: u32) !void {
        if (self.released_regs.contains(reg)) return;
        var item = self.makeInst(.move_);
        item.operands[0] = .{ .reg = reg };
        try self.appendInst(item);
        try self.released_regs.put(reg, {});
    }

    fn paramCapability(self: *Codegen, param: ast.Param) inst.CapPrefix {
        if (param.is_borrow or param.ty.* == .borrow) return .borrow;
        if (lowering_rules.byValueRawPointerParam(param)) return .by_value;
        if (param.is_move or (!self.typeIsCopyValue(param.ty) and !lowering_rules.isBorrowLikeType(param.ty))) return .move;
        return .by_value;
    }

    fn emitAssignmentMove(self: *Codegen, reg: u32) !void {
        var item = self.makeInst(.move_);
        item.operands[0] = .{ .reg = reg };
        try self.appendInst(item);
        try self.released_regs.put(reg, {});
    }

    fn markConsumed(self: *Codegen, reg: u32) !void {
        try self.released_regs.put(reg, {});
    }

    fn markStoredValueMovedIfNeeded(self: *Codegen, value: *const ast.Node, value_ty: *const ast.Type) !void {
        _ = lowering_rules.storedValueMovesIdentifier(value, value_ty, self.typeIsCopyValue(value_ty)) orelse return;
        if (value.* != .identifier) return;
        const value_reg = self.localReg(value.identifier) orelse return;
        try self.markConsumed(value_reg);
    }

    fn consumeStoredMoveValue(self: *Codegen, value: *const ast.Node, value_reg: u32, value_ty: *const ast.Type) !void {
        try self.markStoredValueMovedIfNeeded(value, value_ty);
        if (value.* != .identifier and lowering_rules.exprResultNeedsRelease(value)) {
            try self.markConsumed(value_reg);
        }
    }

    fn markLoadedFieldViewIfNeeded(self: *Codegen, reg: u32, field_ty: *const ast.Type) !void {
        if (self.typeIsCopyValue(field_ty) or lowering_rules.isBorrowLikeType(field_ty)) return;
        try self.markNonOwningReg(reg);
    }

    fn transferFutureStateVTable(self: *Codegen, src: u32, dst: u32) !void {
        if (self.future_state_vtables.get(src)) |vt_name| {
            try self.future_state_vtables.put(dst, vt_name);
            if (src != dst) _ = self.future_state_vtables.remove(src);
        }
    }

    fn futureReadinessForState(self: *Codegen, state_reg: u32) lowering_rules.FutureReadiness {
        return self.future_readiness.get(state_reg) orelse .unknown;
    }

    fn recordFutureReadiness(self: *Codegen, state_reg: u32, readiness: lowering_rules.FutureReadiness) !void {
        if (readiness == .unknown) {
            _ = self.future_readiness.remove(state_reg);
            return;
        }
        try self.future_readiness.put(state_reg, readiness);
    }

    fn transferFutureReadiness(self: *Codegen, src: u32, dst: u32) !void {
        if (self.future_readiness.get(src)) |readiness| {
            try self.recordFutureReadiness(dst, readiness);
            if (src != dst) _ = self.future_readiness.remove(src);
            return;
        }
        _ = self.future_readiness.remove(dst);
    }

    fn emitBranchRelease(self: *Codegen, reg: u32) !void {
        var item = self.makeInst(.release);
        item.operands[0] = .{ .reg = reg };
        try self.appendInst(item);
    }

    fn emitBranchMove(self: *Codegen, reg: u32) !void {
        var item = self.makeInst(.move_);
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
        try self.transferReleaseMetadata(dst, src);
        if (!self.isLocalReg(src)) try self.markConsumed(src);
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

    fn emitAllocOperand(self: *Codegen, dst: u32, size: inst.Operand) !void {
        try self.recordReg(dst);
        var item = self.makeInst(.alloc);
        item.operands[0] = .{ .reg = dst };
        item.operands[1] = size;
        try self.appendInst(item);
    }

    fn emitStackAlloc(self: *Codegen, dst: u32, size: usize) !void {
        try self.recordReg(dst);
        // Register identity in this backend is name-keyed and function-global, so
        // two sibling-scope `let` bindings of the same name (e.g. `let str_end`
        // in two separate `if` blocks) resolve to one register id. Stack-slot
        // locals are never killed by scope-exit release, so emitting `stack_alloc`
        // for the same id twice trips the SAB verifier's RegisterRedefinition.
        // The bindings never coexist and share type/size, so re-emit is a no-op:
        // reuse the already-allocated slot and let the caller's store overwrite it.
        if (self.stack_alloc_emitted.contains(dst)) return;
        try self.stack_alloc_emitted.put(dst, {});
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

    fn emitTake(self: *Codegen, dst: u32, base: u32, offset: usize, ty: sig.PrimType) !void {
        try self.recordReg(dst);
        var item = self.makeInst(.take);
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

    fn emitConsumedMarker(self: *Codegen, value: u32) !void {
        var item = self.makeInst(.fence);
        item.operands[0] = .{ .text = try std.fmt.allocPrint(self.allocator, "^{s}", .{self.symbols.items[value]}) };
        try self.appendInst(item);
    }

    fn emitSliceNew(self: *Codegen, slice_reg: u32, ptr_reg: u32, len_reg: u32) !void {
        try self.emitStore(slice_reg, lowering_rules.SliceAbi.ptr_offset, ptr_reg, .ptr);
        try self.emitStore(slice_reg, lowering_rules.SliceAbi.len_offset, len_reg, .u64);
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
        const name = symbols[idx];
        if (self.fragment_rename) |rename| {
            if (try self.fragmentRenamedName(rename, name)) |renamed| {
                return try self.internStable(renamed);
            }
        }
        return try self.internStable(name);
    }

    fn decodedModuleSymbolName(symbols: []const []const u8, old_id: u32) ![]const u8 {
        const idx: usize = @intCast(old_id);
        if (idx >= symbols.len) return Error.UnsupportedSabDirectFeature;
        return symbols[idx];
    }

    fn newDecodedModuleLocalSymbol(self: *Codegen, prefix: []const u8, old_id: u32) !u32 {
        const name = try std.fmt.allocPrint(self.allocator, "__decoded_{s}_{d}_{d}", .{ prefix, self.decoded_module_rename_idx, old_id });
        errdefer self.allocator.free(name);
        self.decoded_module_rename_idx += 1;
        return try self.intern(name);
    }

    fn decodedModuleRegSymbolName(symbols: []const []const u8, remap: *DecodedModuleLocalRemap, old_id: u32) ![]const u8 {
        _ = remap;
        return try decodedModuleSymbolName(symbols, old_id);
    }

    fn ensureDecodedModuleRegId(self: *Codegen, symbols: []const []const u8, remap: *DecodedModuleLocalRemap, old_id: u32) !u32 {
        if (remap.stable_reg_ids.get(old_id)) |existing| return existing;
        if (remap.reg_ids.get(old_id)) |existing| return existing;
        const old_name = try decodedModuleRegSymbolName(symbols, remap, old_id);
        const new_id = try self.internStable(old_name);
        try remap.reg_ids.put(old_id, new_id);
        try remap.reg_order.append(old_id);
        const entry = try remap.reg_names.getOrPut(old_name);
        if (!entry.found_existing) entry.value_ptr.* = self.symbols.items[new_id];
        const id_entry = try remap.reg_name_ids.getOrPut(old_name);
        if (!id_entry.found_existing) id_entry.value_ptr.* = new_id;
        return new_id;
    }

    fn ensureDecodedModuleNamedRegId(self: *Codegen, remap: *DecodedModuleLocalRemap, name: []const u8) !u32 {
        if (remap.reg_name_ids.get(name)) |existing| return existing;
        const id = try self.internStable(name);
        try remap.extra_reg_ids.append(id);
        try remap.reg_name_ids.put(self.symbols.items[id], id);
        return id;
    }

    fn ensureDecodedModuleLabelId(self: *Codegen, remap: *DecodedModuleLocalRemap, old_id: u32) !u32 {
        if (remap.label_ids.get(old_id)) |existing| return existing;
        const new_id = try self.newDecodedModuleLocalSymbol("L", old_id);
        try remap.label_ids.put(old_id, new_id);
        return new_id;
    }

    fn remapDecodedModuleRegId(self: *Codegen, symbols: []const []const u8, old_id: u32, remap: *DecodedModuleLocalRemap, stable_names: *const std.StringHashMap(void)) !u32 {
        if (remap.stable_reg_ids.get(old_id)) |existing| return existing;
        const name = try decodedModuleRegSymbolName(symbols, remap, old_id);
        if (stable_names.contains(name)) return try self.internStable(name);
        return try self.ensureDecodedModuleRegId(symbols, remap, old_id);
    }

    fn remapDecodedModuleIds(self: *Codegen, symbols: []const []const u8, ids: []const u32, remap: *DecodedModuleLocalRemap, stable_names: *const std.StringHashMap(void)) ![]const u32 {
        if (ids.len == 0) return &.{};
        const out = try self.allocator.alloc(u32, ids.len);
        for (ids, 0..) |old_id, idx| out[idx] = try self.remapDecodedModuleRegId(symbols, old_id, remap, stable_names);
        return out;
    }

    fn cloneDecodedModuleRegIds(self: *Codegen, required_ids: []const u32, remap: *DecodedModuleLocalRemap) ![]const u32 {
        var out = std.ArrayList(u32).init(self.allocator);
        errdefer out.deinit();
        var seen = std.AutoHashMap(u32, void).init(self.allocator);
        defer seen.deinit();

        for (required_ids) |new_id| {
            if (seen.contains(new_id)) continue;
            try seen.put(new_id, {});
            try out.append(new_id);
        }

        for (remap.reg_order.items) |old_id| {
            const new_id = remap.reg_ids.get(old_id) orelse continue;
            if (seen.contains(new_id)) continue;
            try seen.put(new_id, {});
            try out.append(new_id);
        }
        for (remap.extra_reg_ids.items) |new_id| {
            if (seen.contains(new_id)) continue;
            try seen.put(new_id, {});
            try out.append(new_id);
        }

        if (out.items.len == 0) {
            out.deinit();
            return &.{};
        }
        return try out.toOwnedSlice();
    }

    fn decodedModuleSymbolOperandIsLabel(kind: inst.InstKind, operand_idx: usize) bool {
        return switch (kind) {
            .label, .jmp => operand_idx == 0,
            else => false,
        };
    }

    fn collectDecodedModuleRegId(self: *Codegen, symbols: []const []const u8, old_id: u32, remap: *DecodedModuleLocalRemap, stable_names: *const std.StringHashMap(void)) !void {
        const name = try decodedModuleSymbolName(symbols, old_id);
        if (stable_names.contains(name)) return;
        _ = try self.ensureDecodedModuleRegId(symbols, remap, old_id);
    }

    fn decodedModuleSymbolIdByName(symbols: []const []const u8, name: []const u8) ?u32 {
        for (symbols, 0..) |symbol_name, idx| {
            if (std.mem.eql(u8, symbol_name, name)) return @intCast(idx);
        }
        return null;
    }

    fn decodedModuleOperandIdForSourceSymbol(remap: *DecodedModuleLocalRemap, source_symbol_id: u32) ?u32 {
        _ = remap;
        _ = source_symbol_id;
        return null;
    }

    fn decodedModuleTextTokenCanBeLocalReg(token: []const u8) bool {
        if (token.len == 0) return false;
        if (token[0] == '@') return false;
        if (!(std.ascii.isAlphabetic(token[0]) or token[0] == '_')) return false;
        for (token[1..]) |ch| {
            if (!(std.ascii.isAlphanumeric(ch) or ch == '_')) return false;
        }
        return true;
    }

    fn collectDecodedModuleTextRegs(self: *Codegen, symbols: []const []const u8, text: []const u8, remap: *DecodedModuleLocalRemap, stable_names: *const std.StringHashMap(void), allow_unknown: bool) !void {
        var token = std.ArrayList(u8).init(self.allocator);
        defer token.deinit();
        const flush = struct {
            fn call(cg: *Codegen, source_symbols: []const []const u8, tok: *std.ArrayList(u8), local_remap: *DecodedModuleLocalRemap, stable: *const std.StringHashMap(void), collect_unknown: bool) !void {
                if (tok.items.len == 0) return;
                defer tok.clearRetainingCapacity();
                if (!decodedModuleTextTokenCanBeLocalReg(tok.items)) return;
                if (stable.contains(tok.items)) return;
                if (local_remap.reg_names.contains(tok.items)) return;
                if (decodedModuleSymbolIdByName(source_symbols, tok.items)) |old_id| {
                    const operand_id = decodedModuleOperandIdForSourceSymbol(local_remap, old_id) orelse old_id;
                    try cg.collectDecodedModuleRegId(source_symbols, operand_id, local_remap, stable);
                    return;
                }
                if (collect_unknown) _ = try cg.ensureDecodedModuleNamedRegId(local_remap, tok.items);
            }
        }.call;
        for (text) |ch| {
            const is_delim = ch == ',' or ch == ' ' or ch == '\t' or ch == '\r' or ch == '\n' or
                ch == '&' or ch == '^' or ch == '*' or ch == '(' or ch == ')';
            if (is_delim) {
                try flush(self, symbols, &token, remap, stable_names, allow_unknown);
            } else {
                try token.append(ch);
            }
        }
        try flush(self, symbols, &token, remap, stable_names, allow_unknown);
    }

    fn collectDecodedModuleLocalRemap(
        self: *Codegen,
        module: sab.Module,
        fsig: sig.FunctionSig,
        start: usize,
        end: usize,
        remap: *DecodedModuleLocalRemap,
        stable_names: *const std.StringHashMap(void),
    ) !void {
        for (fsig.param_ids, 0..) |old_id, param_idx| {
            if (param_idx >= fsig.params.len) break;
            const stable_id = try self.internStable(fsig.params[param_idx].name);
            try remap.stable_reg_ids.put(old_id, stable_id);
            try remap.reg_name_ids.put(self.symbols.items[stable_id], stable_id);
        }
        for (module.instructions[start..end]) |item| {
            for (item.operands, 0..) |operand, operand_idx| {
                switch (operand) {
                    .reg => |old_id| try self.collectDecodedModuleRegId(module.symbols, old_id, remap, stable_names),
                    .label => |old_id| _ = try self.ensureDecodedModuleLabelId(remap, old_id),
                    .symbol => |old_id| {
                        if (decodedModuleSymbolOperandIsLabel(item.kind, operand_idx)) {
                            _ = try self.ensureDecodedModuleLabelId(remap, old_id);
                        }
                    },
                    .text => |text| try self.collectDecodedModuleTextRegs(module.symbols, text, remap, stable_names, true),
                    .native_text => |text| try self.collectDecodedModuleTextRegs(module.symbols, text, remap, stable_names, false),
                    else => {},
                }
            }
            if (item.atomic_expected_text) |text| try self.collectDecodedModuleTextRegs(module.symbols, text, remap, stable_names, true);
            if (item.atomic_new_text) |text| try self.collectDecodedModuleTextRegs(module.symbols, text, remap, stable_names, true);
            for (item.native_reg_names) |name| try self.collectDecodedModuleTextRegs(module.symbols, name, remap, stable_names, false);
        }
    }

    fn renameDecodedModuleLocalText(self: *Codegen, text: []const u8, remap: *DecodedModuleLocalRemap) ![]const u8 {
        _ = remap;
        return try self.allocator.dupe(u8, text);
    }

    fn remapDecodedModuleOperand(
        self: *Codegen,
        symbols: []const []const u8,
        operand: inst.Operand,
        kind: inst.InstKind,
        operand_idx: usize,
        remap: *DecodedModuleLocalRemap,
        stable_names: *const std.StringHashMap(void),
    ) !inst.Operand {
        return switch (operand) {
            .reg => |old_id| .{ .reg = try self.remapDecodedModuleRegId(symbols, old_id, remap, stable_names) },
            .symbol => |old_id| if (decodedModuleSymbolOperandIsLabel(kind, operand_idx))
                .{ .symbol = try self.ensureDecodedModuleLabelId(remap, old_id) }
            else
                .{ .symbol = try self.remapModuleSymbol(symbols, old_id) },
            .label => |old_id| .{ .label = try self.ensureDecodedModuleLabelId(remap, old_id) },
            .func => |old_id| .{ .func = try self.remapModuleSymbol(symbols, old_id) },
            .text => |text| .{ .text = try self.renameDecodedModuleLocalText(text, remap) },
            .native_text => |text| .{ .native_text = try self.renameDecodedModuleLocalText(text, remap) },
            else => operand,
        };
    }

    /// When appending a decoded std-macro fragment, its internal SA temps
    /// (`tmp_N` from the snippet flattener), hygiene locals (`__`-prefixed),
    /// and labels (`L_`-prefixed) share a name namespace with the main
    /// codegen's registers and with other fragments. Interning them by name
    /// would alias distinct SA values (e.g. fragment `tmp_0` == main `tmp_0`),
    /// producing UnknownRegister / UseAfterMove at verify time. This gives each
    /// such fragment-internal name a globally-unique rewrite, while names that
    /// were passed in as caller arguments (real main-codegen registers) keep
    /// their identity so their references still resolve to the caller's values.
    /// Returns null when the name is not fragment-internal (globals, consts,
    /// extern callees, caller args) and should be interned as-is.
    fn fragmentRenamedName(self: *Codegen, rename: *std.StringHashMap([]const u8), name: []const u8) !?[]const u8 {
        if (self.fragment_rename_args) |args| {
            for (args) |arg| {
                if (std.mem.eql(u8, arg, name)) return null;
            }
        }
        const is_internal = std.mem.startsWith(u8, name, "tmp_") or
            std.mem.startsWith(u8, name, "__") or
            std.mem.startsWith(u8, name, "L_");
        if (!is_internal) return null;
        if (rename.get(name)) |existing| return existing;
        const unique = try std.fmt.allocPrint(self.allocator, "__frag{}_{s}", .{ self.fragment_rename_idx, name });
        self.fragment_rename_idx += 1;
        try rename.put(try self.allocator.dupe(u8, name), unique);
        return unique;
    }

    /// Append a decoded fragment function body with per-fragment uniquification
    /// of internal registers/labels active. See `fragmentRenamedName`.
    fn appendRenamedFragmentBody(self: *Codegen, module: sab.Module, func_name: []const u8, args: []const []const u8) !void {
        var rename = std.StringHashMap([]const u8).init(self.allocator);
        defer {
            var it = rename.iterator();
            while (it.next()) |entry| self.allocator.free(entry.key_ptr.*);
            rename.deinit();
        }
        const prev_rename = self.fragment_rename;
        const prev_args = self.fragment_rename_args;
        self.fragment_rename = &rename;
        self.fragment_rename_args = args;
        defer {
            self.fragment_rename = prev_rename;
            self.fragment_rename_args = prev_args;
        }
        try self.appendDecodedFunctionBody(module, func_name);
    }

    /// Append a decoded macro fragment that was flattened with
    /// `__sla_macro_arg_N` placeholders instead of caller register names. This
    /// keeps SCI's flatten/encode stage from treating caller temps as fragment
    /// locals and renumbering them. During append we replace placeholders with
    /// the real caller args, while still applying per-fragment hygiene to all
    /// fragment-internal temps/labels.
    fn appendRenamedTemplateFragmentBody(self: *Codegen, module: sab.Module, func_name: []const u8, args: []const []const u8) !void {
        var rename = std.StringHashMap([]const u8).init(self.allocator);
        defer {
            var it = rename.iterator();
            while (it.next()) |entry| self.allocator.free(entry.key_ptr.*);
            rename.deinit();
        }
        const prev_rename = self.fragment_rename;
        const prev_args = self.fragment_rename_args;
        self.fragment_rename = &rename;
        self.fragment_rename_args = args;
        defer {
            self.fragment_rename = prev_rename;
            self.fragment_rename_args = prev_args;
        }
        try self.appendDecodedFragmentTemplateFunctionBody(module, func_name, args);
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
            .text => |text| .{ .text = try self.renameFragmentText(text) },
            .native_text => |text| .{ .native_text = try self.allocator.dupe(u8, text) },
            else => operand,
        };
    }

    /// Rewrite fragment-internal register/label tokens embedded in a call-body
    /// `.text` operand using the active per-fragment rename map, so they match
    /// the uniquified `.reg` definitions. Tokens split on SA operand
    /// punctuation (`,` ` ` `&` `^` `(` `)`); caller registers (in
    /// `fragment_rename_args`), immediates, and `@func` targets pass through.
    fn renameFragmentText(self: *Codegen, text: []const u8) ![]const u8 {
        const rename = self.fragment_rename orelse return try self.allocator.dupe(u8, text);
        var out = std.ArrayList(u8).init(self.allocator);
        errdefer out.deinit();
        var token = std.ArrayList(u8).init(self.allocator);
        defer token.deinit();
        const flush = struct {
            fn call(cg: *Codegen, r: *std.StringHashMap([]const u8), tok: *std.ArrayList(u8), o: *std.ArrayList(u8)) !void {
                if (tok.items.len == 0) return;
                if (try cg.fragmentRenamedName(r, tok.items)) |renamed| {
                    try o.appendSlice(renamed);
                } else {
                    try o.appendSlice(tok.items);
                }
                tok.clearRetainingCapacity();
            }
        }.call;
        for (text) |ch| {
            const is_delim = ch == ',' or ch == ' ' or ch == '&' or ch == '^' or ch == '(' or ch == ')';
            if (is_delim) {
                try flush(self, rename, &token, &out);
                try out.append(ch);
            } else {
                try token.append(ch);
            }
        }
        try flush(self, rename, &token, &out);
        return try out.toOwnedSlice();
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

    fn replaceStdMacroPlaceholdersThenRename(self: *Codegen, text: []const u8, args: []const []const u8) ![]const u8 {
        const rename = self.fragment_rename orelse {
            return try self.replaceStdMacroPlaceholders(text, args);
        };
        var out = std.ArrayList(u8).init(self.allocator);
        errdefer out.deinit();
        var token = std.ArrayList(u8).init(self.allocator);
        defer token.deinit();
        const flush = struct {
            fn call(cg: *Codegen, r: *std.StringHashMap([]const u8), tok: *std.ArrayList(u8), o: *std.ArrayList(u8), call_args: []const []const u8) !void {
                if (tok.items.len == 0) return;
                if (templateSymbolNameArgIndex(tok.items)) |arg_idx| {
                    if (arg_idx >= call_args.len) return Error.UnsupportedSabDirectFeature;
                    try o.appendSlice(call_args[arg_idx]);
                    tok.clearRetainingCapacity();
                    return;
                }
                const replaced = try cg.replaceStdMacroPlaceholders(tok.items, call_args);
                defer cg.allocator.free(replaced);
                if (try cg.fragmentRenamedName(r, replaced)) |renamed| {
                    try o.appendSlice(renamed);
                } else {
                    try o.appendSlice(replaced);
                }
                tok.clearRetainingCapacity();
            }
        }.call;
        for (text) |ch| {
            const is_delim = ch == ',' or ch == ' ' or ch == '&' or ch == '^' or ch == '(' or ch == ')';
            if (is_delim) {
                try flush(self, rename, &token, &out, args);
                try out.append(ch);
            } else {
                try token.append(ch);
            }
        }
        try flush(self, rename, &token, &out, args);
        return try out.toOwnedSlice();
    }

    fn remapFragmentTemplateSymbol(self: *Codegen, symbols: []const []const u8, old_id: u32, args: []const []const u8) !u32 {
        if (templateSymbolArgIndex(symbols, old_id)) |arg_idx| {
            if (arg_idx >= args.len) return Error.UnsupportedSabDirectFeature;
            return try self.internStable(args[arg_idx]);
        }
        const idx: usize = @intCast(old_id);
        if (idx >= symbols.len) return Error.UnsupportedSabDirectFeature;
        const replaced = try self.replaceStdMacroPlaceholders(symbols[idx], args);
        defer self.allocator.free(replaced);
        if (self.fragment_rename) |rename| {
            if (try self.fragmentRenamedName(rename, replaced)) |renamed| {
                return try self.internStable(renamed);
            }
        }
        return try self.internStable(replaced);
    }

    fn remapTemplateSymbol(self: *Codegen, symbols: []const []const u8, old_id: u32, args: []const []const u8) !u32 {
        const idx: usize = @intCast(old_id);
        if (idx >= symbols.len) return Error.UnsupportedSabDirectFeature;
        const name = try self.replaceStdMacroPlaceholders(symbols[idx], args);
        defer self.allocator.free(name);
        return try self.internStable(name);
    }

    fn templatePlaceholderArgIndex(name: []const u8) ?usize {
        const prefix = "__sla_macro_arg_";
        if (name.len <= prefix.len) return null;
        if (!std.mem.startsWith(u8, name, prefix)) return null;
        return std.fmt.parseInt(usize, name[prefix.len..], 10) catch null;
    }

    fn templateSymbolNameArgIndex(name: []const u8) ?usize {
        if (templatePlaceholderArgIndex(name)) |arg_idx| return arg_idx;

        const hygiene_prefix = "__frag";
        if (!std.mem.startsWith(u8, name, hygiene_prefix)) return null;
        var idx: usize = hygiene_prefix.len;
        const digits_start = idx;
        while (idx < name.len and std.ascii.isDigit(name[idx])) : (idx += 1) {}
        if (idx == digits_start or idx >= name.len or name[idx] != '_') return null;
        return templatePlaceholderArgIndex(name[idx + 1 ..]);
    }

    fn templateSymbolArgIndex(symbols: []const []const u8, old_id: u32) ?usize {
        const idx: usize = @intCast(old_id);
        if (idx >= symbols.len) return null;
        return templateSymbolNameArgIndex(symbols[idx]);
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

    fn remapFragmentTemplateOperand(self: *Codegen, symbols: []const []const u8, operand: inst.Operand, args: []const []const u8) !inst.Operand {
        return switch (operand) {
            .reg => |old_id| {
                if (templateSymbolArgIndex(symbols, old_id)) |arg_idx| {
                    if (arg_idx < args.len and isStdMacroTemplateIntegerArg(args[arg_idx])) {
                        return try stdMacroTemplateIntegerOperand(args[arg_idx]);
                    }
                }
                return .{ .reg = try self.remapFragmentTemplateSymbol(symbols, old_id, args) };
            },
            .symbol => |old_id| {
                if (templateSymbolArgIndex(symbols, old_id)) |arg_idx| {
                    if (arg_idx < args.len and isStdMacroTemplateIntegerArg(args[arg_idx])) {
                        return try stdMacroTemplateIntegerOperand(args[arg_idx]);
                    }
                }
                return .{ .symbol = try self.remapFragmentTemplateSymbol(symbols, old_id, args) };
            },
            .label => |old_id| .{ .label = try self.remapFragmentTemplateSymbol(symbols, old_id, args) },
            .func => |old_id| .{ .func = try self.remapFragmentTemplateSymbol(symbols, old_id, args) },
            .text => |text| .{ .text = try self.replaceStdMacroPlaceholdersThenRename(text, args) },
            .native_text => |text| .{ .native_text = try self.replaceStdMacroPlaceholdersThenRename(text, args) },
            else => operand,
        };
    }

    fn coerceTemplateValueOperand(self: *Codegen, operand: *inst.Operand) !void {
        if (operand.* != .text) return;
        const text = std.mem.trim(u8, operand.text, " \t\r\n");
        if (isStdMacroTemplateIntegerArg(text)) {
            operand.* = try stdMacroTemplateIntegerOperand(text);
            return;
        }
        const reg = self.symbol_ids.get(text) orelse return;
        if (!self.current_reg_seen.contains(reg)) return;
        operand.* = .{ .reg = reg };
    }

    fn coerceTemplateInstructionOperands(self: *Codegen, item: *inst.Instruction) !void {
        switch (item.kind) {
            .store => try self.coerceTemplateValueOperand(&item.operands[2]),
            .assign => try self.coerceTemplateValueOperand(&item.operands[1]),
            .op => {
                try self.coerceTemplateValueOperand(&item.operands[1]);
                try self.coerceTemplateValueOperand(&item.operands[2]);
            },
            .ptr_add, .borrow => try self.coerceTemplateValueOperand(&item.operands[1]),
            .release => try self.coerceTemplateValueOperand(&item.operands[0]),
            else => {},
        }
    }

    fn coerceDecodedValueOperand(self: *Codegen, operand: *inst.Operand, remap: *DecodedModuleLocalRemap) !void {
        _ = self;
        if (operand.* != .text) return;
        const text = std.mem.trim(u8, operand.text, " \t\r\n");
        if (isStdMacroTemplateIntegerArg(text)) {
            operand.* = try stdMacroTemplateIntegerOperand(text);
            return;
        }
        const reg = remap.reg_name_ids.get(text) orelse return;
        operand.* = .{ .reg = reg };
    }

    fn coerceDecodedInstructionOperands(self: *Codegen, item: *inst.Instruction, remap: *DecodedModuleLocalRemap) !void {
        switch (item.kind) {
            .store => try self.coerceDecodedValueOperand(&item.operands[2], remap),
            .assign => try self.coerceDecodedValueOperand(&item.operands[1], remap),
            .op => {
                try self.coerceDecodedValueOperand(&item.operands[1], remap);
                try self.coerceDecodedValueOperand(&item.operands[2], remap);
            },
            .ptr_add, .borrow => try self.coerceDecodedValueOperand(&item.operands[1], remap),
            .release => try self.coerceDecodedValueOperand(&item.operands[0], remap),
            else => {},
        }
    }

    fn cloneTemplateTextList(self: *Codegen, items: []const []const u8, args: []const []const u8) ![]const []const u8 {
        if (items.len == 0) return &.{};
        const out = try self.allocator.alloc([]const u8, items.len);
        for (items, 0..) |item, idx| out[idx] = try self.replaceStdMacroPlaceholders(item, args);
        return out;
    }

    fn cloneFragmentTemplateTextList(self: *Codegen, items: []const []const u8, args: []const []const u8) ![]const []const u8 {
        if (items.len == 0) return &.{};
        const out = try self.allocator.alloc([]const u8, items.len);
        errdefer self.allocator.free(out);
        var initialized: usize = 0;
        errdefer for (out[0..initialized]) |item| self.allocator.free(item);
        for (items, 0..) |item, idx| {
            out[idx] = try self.replaceStdMacroPlaceholdersThenRename(item, args);
            initialized += 1;
        }
        return out;
    }

    fn ownDecodedModuleSymbols(self: *Codegen, module: *sab.Module) !void {
        if (module.owns_symbol_text) return;
        const owned = try self.allocator.alloc([]const u8, module.symbols.len);
        errdefer self.allocator.free(owned);
        var initialized: usize = 0;
        errdefer for (owned[0..initialized]) |name| self.allocator.free(name);
        for (module.symbols, 0..) |name, idx| {
            owned[idx] = try self.allocator.dupe(u8, name);
            initialized += 1;
        }
        self.allocator.free(module.symbols);
        module.symbols = owned;
        module.owns_symbol_text = true;
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

    fn remapVerifiedSymbolIdsByName(self: *Codegen, ids: []const u32, from_symbols: *const flattener.SymbolTable, to_symbols: *const flattener.SymbolTable) ![]const u32 {
        if (ids.len == 0) return &.{};
        const out = try self.allocator.alloc(u32, ids.len);
        errdefer self.allocator.free(out);
        for (ids, 0..) |id, idx| {
            const name = from_symbols.lookupName(id) orelse return Error.UnsupportedSabDirectFeature;
            out[idx] = to_symbols.findId(name) orelse return Error.UnsupportedSabDirectFeature;
        }
        return out;
    }

    fn cloneVerifiedFunctionSigForFlatSymbols(self: *Codegen, source: sig.FunctionSig, from_symbols: *const flattener.SymbolTable, to_symbols: *const flattener.SymbolTable) !sig.FunctionSig {
        var out = sig.FunctionSig{
            .id = source.id,
            .name = try self.allocator.dupe(u8, source.name),
            .params = &.{},
            .kind = source.kind,
            .return_cap = source.return_cap,
            .return_ty = source.return_ty,
            .return_fallible = source.return_fallible,
            .entry_inst_idx = source.entry_inst_idx,
            .is_ffi_wrapper = source.is_ffi_wrapper,
            .upstream_file = null,
            .upstream_loc = null,
            .param_ids = &.{},
            .reg_ids = &.{},
            .llvm_name = null,
            .ignored = source.ignored,
            .should_panic = source.should_panic,
        };
        errdefer out.deinit(self.allocator);

        out.params = try self.cloneModuleParamSpecs(source.params);
        out.param_ids = try self.remapVerifiedSymbolIdsByName(source.param_ids, from_symbols, to_symbols);
        out.reg_ids = try self.remapVerifiedSymbolIdsByName(source.reg_ids, from_symbols, to_symbols);
        if (source.upstream_loc) |loc| {
            const file_copy = try self.allocator.dupe(u8, loc.file);
            out.upstream_file = file_copy;
            out.upstream_loc = .{ .file = file_copy, .line = loc.line, .col = loc.col };
        } else if (source.upstream_file) |file| {
            out.upstream_file = try self.allocator.dupe(u8, file);
        }
        if (source.llvm_name) |llvm_name| {
            out.llvm_name = try self.allocator.dupe(u8, llvm_name);
        }
        return out;
    }

    fn cloneVerifiedFunctionSigsForFlatSymbols(self: *Codegen, source_sigs: []const sig.FunctionSig, from_symbols: *const flattener.SymbolTable, to_symbols: *const flattener.SymbolTable) ![]sig.FunctionSig {
        if (source_sigs.len == 0) return &.{};
        const out = try self.allocator.alloc(sig.FunctionSig, source_sigs.len);
        errdefer self.allocator.free(out);
        var initialized: usize = 0;
        errdefer for (out[0..initialized]) |*item| item.deinit(self.allocator);
        for (source_sigs, 0..) |fsig, idx| {
            out[idx] = try self.cloneVerifiedFunctionSigForFlatSymbols(fsig, from_symbols, to_symbols);
            initialized += 1;
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

    fn cloneDecodedModuleFunctionSig(
        self: *Codegen,
        symbols: []const []const u8,
        source: sig.FunctionSig,
        entry_inst_idx: usize,
        remap: *DecodedModuleLocalRemap,
        stable_names: *const std.StringHashMap(void),
    ) !sig.FunctionSig {
        const param_ids = try self.remapDecodedModuleIds(symbols, source.param_ids, remap, stable_names);
        const source_reg_ids = try self.remapDecodedModuleIds(symbols, source.reg_ids, remap, stable_names);
        defer if (source_reg_ids.len != 0) self.allocator.free(source_reg_ids);
        var required_reg_ids = std.ArrayList(u32).init(self.allocator);
        defer required_reg_ids.deinit();
        try required_reg_ids.appendSlice(param_ids);
        try required_reg_ids.appendSlice(source_reg_ids);
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
            .param_ids = param_ids,
            .reg_ids = try self.cloneDecodedModuleRegIds(required_reg_ids.items, remap),
            .llvm_name = try self.cloneOptionalText(source.llvm_name),
            .ignored = source.ignored,
            .should_panic = source.should_panic,
        };
    }

    fn cloneDecodedModuleTextList(self: *Codegen, items: []const []const u8, remap: *DecodedModuleLocalRemap) ![]const []const u8 {
        if (items.len == 0) return &.{};
        const out = try self.allocator.alloc([]const u8, items.len);
        errdefer self.allocator.free(out);
        var initialized: usize = 0;
        errdefer for (out[0..initialized]) |item| self.allocator.free(item);
        for (items, 0..) |item, idx| {
            out[idx] = try self.renameDecodedModuleLocalText(item, remap);
            initialized += 1;
        }
        return out;
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

    fn cloneDecodedModuleInstruction(
        self: *Codegen,
        symbols: []const []const u8,
        source: inst.Instruction,
        remap: *DecodedModuleLocalRemap,
        stable_names: *const std.StringHashMap(void),
    ) !inst.Instruction {
        var out = source;
        out.package_identity = try self.cloneOptionalText(source.package_identity);
        out.upstream_loc = try self.cloneUpstreamLoc(source.upstream_loc);
        out.raw_text = "";
        out.atomic_expected_text = if (source.atomic_expected_text) |text| try self.renameDecodedModuleLocalText(text, remap) else null;
        out.atomic_new_text = if (source.atomic_new_text) |text| try self.renameDecodedModuleLocalText(text, remap) else null;
        out.native_reg_names = try self.cloneDecodedModuleTextList(source.native_reg_names, remap);
        for (&out.operands, 0..) |*operand, operand_idx| operand.* = try self.remapDecodedModuleOperand(symbols, operand.*, source.kind, operand_idx, remap, stable_names);
        try self.coerceDecodedInstructionOperands(&out, remap);
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
        try self.coerceTemplateInstructionOperands(&out);
        if (out.kind == .panic_msg and out.operands[0] == .text) {
            if (try self.structuredPanicMsgOperands(out.operands[0].text)) |ops| {
                out.operands[0] = ops[0];
                out.operands[1] = ops[1];
                out.operands[2] = ops[2];
            }
        }
        return out;
    }

    fn cloneFragmentTemplateInstruction(self: *Codegen, symbols: []const []const u8, source: inst.Instruction, args: []const []const u8) !inst.Instruction {
        var out = source;
        out.package_identity = try self.cloneOptionalText(source.package_identity);
        out.upstream_loc = try self.cloneUpstreamLoc(source.upstream_loc);
        out.raw_text = "";
        out.atomic_expected_text = if (source.atomic_expected_text) |text| try self.replaceStdMacroPlaceholdersThenRename(text, args) else null;
        out.atomic_new_text = if (source.atomic_new_text) |text| try self.replaceStdMacroPlaceholdersThenRename(text, args) else null;
        out.native_reg_names = try self.cloneFragmentTemplateTextList(source.native_reg_names, args);
        for (&out.operands) |*operand| operand.* = try self.remapFragmentTemplateOperand(symbols, operand.*, args);
        try self.coerceTemplateInstructionOperands(&out);
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
        if (callInstructionBody(item)) |body| try self.recordCallBodyRegs(body);
    }

    fn isCallBodyIdentChar(c: u8) bool {
        return std.ascii.isAlphanumeric(c) or c == '_';
    }

    fn recordCallBodyRegs(self: *Codegen, body: []const u8) !void {
        if (directCallTargetName(body)) |callee| {
            try self.recordReg(try self.internStable(callee));
        }
        var i: usize = 0;
        while (i < body.len) {
            while (i < body.len and !isCallBodyIdentChar(body[i])) i += 1;
            const start = i;
            while (i < body.len and isCallBodyIdentChar(body[i])) i += 1;
            if (start == i) continue;
            const name = body[start..i];
            if (self.symbol_ids.get(name)) |reg| {
                if (self.current_reg_seen.contains(reg)) try self.recordReg(reg);
            }
        }
    }

    fn moduleHasFunctionSig(module: sab.Module, name: []const u8) bool {
        for (module.function_sigs) |fsig| {
            if (std.mem.eql(u8, fsig.name, name)) return true;
        }
        return false;
    }

    fn moduleFunctionBodyEnd(module: sab.Module, sig_idx: usize) usize {
        if (sig_idx + 1 < module.function_sigs.len) return module.function_sigs[sig_idx + 1].entry_inst_idx;
        return module.instructions.len;
    }

    fn collectDecodedModuleDepClosure(self: *Codegen, module: sab.Module, deps: []const []const u8, selected: *std.StringHashMap(void)) !void {
        if (deps.len == 0) {
            for (module.function_sigs) |fsig| try selected.put(fsig.name, {});
            return;
        }

        for (deps) |dep| try selected.put(dep, {});

        var changed = true;
        while (changed) {
            changed = false;
            for (module.function_sigs, 0..) |fsig, idx| {
                if (!selected.contains(fsig.name)) continue;
                if (fsig.kind == .external) continue;
                const start: usize = @intCast(fsig.entry_inst_idx);
                if (start >= module.instructions.len) continue;
                const end = moduleFunctionBodyEnd(module, idx);
                for (module.instructions[start..@min(end, module.instructions.len)]) |item| {
                    const target = callTargetName(callInstructionBody(item) orelse continue) orelse continue;
                    if (!moduleHasFunctionSig(module, target)) continue;
                    if (selected.contains(target)) continue;
                    try selected.put(target, {});
                    changed = true;
                }
            }
        }

        _ = self;
    }

    fn appendDecodedModuleFiltered(self: *Codegen, module: sab.Module, deps: []const []const u8) !void {
        var stable_names = std.StringHashMap(void).init(self.allocator);
        defer stable_names.deinit();
        for (module.function_sigs) |fsig| try stable_names.put(fsig.name, {});
        for (module.const_decls) |decl| try stable_names.put(decl.name, {});

        for (module.const_decls) |decl| {
            const const_id = try self.internStable(decl.name);
            try self.recordReg(const_id);
            if (self.hasConstDecl(decl.name)) continue;
            var cloned = try self.cloneModuleConstDecl(decl);
            cloned.source_line = 0;
            cloned.expanded_line = 0;
            try self.const_decls.append(cloned);
        }

        var selected = std.StringHashMap(void).init(self.allocator);
        defer selected.deinit();
        try self.collectDecodedModuleDepClosure(module, deps, &selected);

        for (module.function_sigs, 0..) |fsig, idx| {
            if (!selected.contains(fsig.name)) continue;
            if (self.included_imports.contains(fsig.name)) continue;
            try self.included_imports.put(try self.allocator.dupe(u8, fsig.name), {});
            const entry_idx = self.instructions.items.len;

            if (fsig.kind == .external) {
                const cloned = try self.cloneModuleFunctionSig(module.symbols, fsig, entry_idx);
                try self.function_sigs.append(cloned);
                if (cloned.kind == .test_func) try self.test_sigs.append(cloned);
                try self.appendDeclInst(cloned);
                continue;
            }

            const start: usize = fsig.entry_inst_idx;
            const end: usize = if (idx + 1 < module.function_sigs.len) module.function_sigs[idx + 1].entry_inst_idx else module.instructions.len;
            var function_stable_names = std.StringHashMap(void).init(self.allocator);
            defer function_stable_names.deinit();
            var stable_it = stable_names.iterator();
            while (stable_it.next()) |entry| try function_stable_names.put(entry.key_ptr.*, {});
            for (fsig.params) |param| try function_stable_names.put(param.name, {});

            var local_remap = DecodedModuleLocalRemap.init(self.allocator);
            defer local_remap.deinit();
            try self.collectDecodedModuleLocalRemap(module, fsig, start, end, &local_remap, &function_stable_names);

            const cloned = try self.cloneDecodedModuleFunctionSig(module.symbols, fsig, entry_idx, &local_remap, &function_stable_names);
            try self.function_sigs.append(cloned);
            if (cloned.kind == .test_func) try self.test_sigs.append(cloned);

            for (module.instructions[start..end]) |item| {
                try self.instructions.append(try self.cloneDecodedModuleInstruction(module.symbols, item, &local_remap, &function_stable_names));
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

    fn appendDecodedFragmentTemplateFunctionBody(self: *Codegen, module: sab.Module, func_name: []const u8, args: []const []const u8) !void {
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
            const cloned = try self.cloneFragmentTemplateInstruction(module.symbols, source, args);
            try self.recordInstructionRegs(cloned);
            try self.instructions.append(cloned);
        }
    }

    fn cachedStdImportModule(self: *Codegen, import_path: []const u8) !*const StdImportModule {
        if (self.std_import_module_ids.get(import_path)) |idx| return &self.std_import_modules.items[idx];

        const source = try std.fmt.allocPrint(self.allocator, "@import \"{s}\"\n", .{import_path});
        defer self.allocator.free(source);
        var flat = try self.flattenStdSnippet(source);
        errdefer flat.deinit(self.allocator);

        const verified = try sci_bridge.verifier.verifyWithOptions(self.allocator, flat.instructions, flat.const_decls, .{});
        var function_sigs: []sig.FunctionSig = &.{};
        switch (verified) {
            .ok => |ok| {
                var owned = ok;
                defer owned.deinit(self.allocator);
                function_sigs = try self.cloneVerifiedFunctionSigsForFlatSymbols(owned.function_sigs, &owned.symbols, &flat.symbols);
            },
            .trap => return Error.UnsupportedSabDirectFeature,
        }
        errdefer {
            for (function_sigs) |*fsig| fsig.deinit(self.allocator);
            if (function_sigs.len != 0) self.allocator.free(function_sigs);
        }

        const owned_import_path = try self.allocator.dupe(u8, import_path);
        errdefer self.allocator.free(owned_import_path);

        const idx = self.std_import_modules.items.len;
        try self.std_import_module_ids.put(owned_import_path, idx);
        errdefer _ = self.std_import_module_ids.remove(owned_import_path);
        try self.std_import_modules.append(.{
            .import_path = owned_import_path,
            .flat = flat,
            .function_sigs = function_sigs,
        });
        return &self.std_import_modules.items[idx];
    }

    fn ensureStdDeps(self: *Codegen, import_path: []const u8, deps: []const []const u8) !void {
        if (deps.len == 0) return;
        var missing = std.ArrayList([]const u8).init(self.allocator);
        defer missing.deinit();
        for (deps) |dep| {
            if (!self.included_imports.contains(dep) and !self.pendingStdDepContains(dep)) try missing.append(dep);
        }
        if (missing.items.len == 0) return;

        if (self.in_function_body) {
            for (missing.items) |dep| {
                try self.pending_std_deps.append(.{
                    .import_path = try self.allocator.dupe(u8, import_path),
                    .dep = try self.allocator.dupe(u8, dep),
                });
            }
            return;
        }

        try self.appendStdDepsNow(import_path, missing.items);
    }

    fn pendingStdDepContains(self: *Codegen, dep: []const u8) bool {
        for (self.pending_std_deps.items) |pending| {
            if (std.mem.eql(u8, pending.dep, dep)) return true;
        }
        return false;
    }

    fn appendStdDepsNow(self: *Codegen, import_path: []const u8, deps: []const []const u8) !void {
        if (deps.len == 0) return;
        const cached = try self.cachedStdImportModule(import_path);
        try self.appendDecodedModuleFiltered(cached.module(), deps);
        for (deps) |dep| {
            if (!self.included_imports.contains(dep)) {
                try self.included_imports.put(try self.allocator.dupe(u8, dep), {});
            }
        }
    }

    fn flushPendingStdDeps(self: *Codegen) !void {
        if (self.pending_std_deps.items.len == 0) return;
        var i: usize = 0;
        while (i < self.pending_std_deps.items.len) : (i += 1) {
            const pending = self.pending_std_deps.items[i];
            if (!self.included_imports.contains(pending.dep)) {
                try self.appendStdDepsNow(pending.import_path, &.{pending.dep});
            }
        }
        for (self.pending_std_deps.items) |pending| {
            self.allocator.free(pending.import_path);
            self.allocator.free(pending.dep);
        }
        self.pending_std_deps.clearRetainingCapacity();
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
        try self.ownDecodedModuleSymbols(&module);

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
        const bounds = templateFunctionBodyBounds(template, template.func_name) orelse return false;
        var body_i = bounds.start;
        while (body_i < bounds.end) : (body_i += 1) {
            const source = template.module.instructions[body_i];
            if (callInstructionBody(source) != null) return false;
        }

        for (args, 0..) |arg, idx| {
            if (isStdMacroTemplateIdentArg(arg)) continue;
            if (isStdMacroTemplateIntegerArg(arg)) continue;
            const placeholder = try self.stdMacroPlaceholder(idx);
            defer self.allocator.free(placeholder);
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
        // FORMAT_* / STRFMT_* macros in string_format.sa use a `%tag` hygiene
        // suffix to name per-expansion local temporaries. Those locals are both
        // *defined* by structured instructions (remapped to fresh registers on
        // inlining) and *referenced* inside call-body text operands (which the
        // arg-placeholder cache only rewrites for `%argN`, not for remapped
        // local names). Caching therefore freezes a stale local name in the
        // text call body and desyncs it from the fresh structured register,
        // producing UnknownRegister at verify time. The fresh-flatten path
        // re-expands hygiene per call and stays consistent, so bypass the cache
        // for this module.
        if (std.mem.eql(u8, import_path, "sa_std/string_format.sa")) return false;
        const template = try self.cachedStdMacroTemplate(import_path, macro_name, args.len);
        if (template.arg_count != args.len) return Error.UnsupportedSabDirectFeature;
        if (!try self.stdMacroTemplateSupportsArgs(template, args)) return false;
        try self.appendDecodedModuleConstDecls(template.module);
        try self.appendRenamedTemplateFragmentBody(template.module, template.func_name, args);
        return true;
    }

    fn emitStdMacroFragment(self: *Codegen, import_path: []const u8, macro_name: []const u8, args: []const []const u8) !void {
        try self.emitStdMacroFragmentWithLiteralArgs(import_path, macro_name, args, &.{});
    }

    fn emitStdMacroFragmentWithLiteralArgs(self: *Codegen, import_path: []const u8, macro_name: []const u8, args: []const []const u8, literal_args: []const bool) !void {
        if (literal_args.len != 0 and literal_args.len != args.len) return Error.UnsupportedSabDirectFeature;
        const has_literal_args = blk: {
            for (literal_args) |is_literal| if (is_literal) break :blk true;
            break :blk false;
        };

        if (has_literal_args) {
            return try self.emitStdMacroFragmentFresh(import_path, macro_name, args, literal_args);
        }

        const used_cached = self.emitCachedStdMacroFragment(import_path, macro_name, args) catch |err| switch (err) {
            error.UnsupportedType => false,
            else => return err,
        };
        if (used_cached) return;

        try self.emitStdMacroFragmentFresh(import_path, macro_name, args, literal_args);
    }

    fn emitStdMacroFragmentFresh(self: *Codegen, import_path: []const u8, macro_name: []const u8, args: []const []const u8, literal_args: []const bool) !void {
        const func_name = try std.fmt.allocPrint(self.allocator, "__sla_macro_fragment_{}", .{self.macro_fragment_idx});
        self.macro_fragment_idx += 1;

        var source = std.ArrayList(u8).init(self.allocator);
        try source.writer().print("@import \"{s}\"\n@{s}() -> void:\nL_ENTRY:\n    EXPAND {s}", .{ import_path, func_name, macro_name });
        for (args, 0..) |arg, i| {
            const use_literal = literal_args.len != 0 and literal_args[i];
            if (use_literal) {
                if (i == 0) {
                    try source.writer().print(" {s}", .{arg});
                } else {
                    try source.writer().print(", {s}", .{arg});
                }
            } else {
                const placeholder = try self.stdMacroPlaceholder(i);
                defer self.allocator.free(placeholder);
                if (i == 0) {
                    try source.writer().print(" {s}", .{placeholder});
                } else {
                    try source.writer().print(", {s}", .{placeholder});
                }
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
        try self.appendRenamedTemplateFragmentBody(module, func_name, args);
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
        try self.recordCallBodyRegs(body);
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

    fn returnCapForType(ty: *const ast.Type) ?inst.CapPrefix {
        return switch (ty.*) {
            .borrow => .borrow,
            else => null,
        };
    }

    fn abiReturnCap(raw: []const u8) ?inst.CapPrefix {
        const name = std.mem.trim(u8, raw, " \t\r");
        if (name.len == 0) return null;
        return switch (name[0]) {
            '&' => .borrow,
            '^' => .move,
            '*' => .raw,
            else => null,
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
        const fsig = try self.appendGeneratedFuncSig(entry.spawn_name, .ffi_wrapper, param.specs, param.ids, .i32, true);
        const sig_idx = self.function_sigs.items.len;
        try self.function_sigs.append(fsig);
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
        try self.emitMove(worker_safe);
        try self.emitMove(worker_fn);
        try self.emitMove(worker_vt);
        try self.emitMove(param.id);
        try self.emitReturn(handle);

        try self.finishFunctionBody(sig_idx);
    }

    fn emitFutureTaskHelpers(self: *Codegen) !void {
        if (self.future_task_helpers_emitted) return;
        self.future_task_helpers_emitted = true;

        try self.appendVTableConst("SLA_READY_FUTURE_VT", "sla_future_ready_poll");
        try self.appendVTableConst("SLA_DEFER_READY_FUTURE_VT", "sla_future_defer_ready_poll");
        try self.appendVTableConst("SLA_JOIN2_FUTURE_VT", "sla_future_join2_poll");
        try self.appendVTableConst("SLA_SELECT2_FUTURE_VT", "sla_future_select2_poll");

        const old_locals = self.locals.items.len;
        defer self.popLocalsTo(old_locals);
        self.beginFunction();

        const names = [_][]const u8{ "data_slot", "ctx_slot", "out_poll_slot" };
        const specs = try self.allocator.alloc(sig.ParamSpec, names.len);
        const ids = try self.allocator.alloc(u32, names.len);
        for (names, 0..) |name, i| {
            ids[i] = try self.intern(name);
            specs[i] = .{ .name = name, .ty = .ptr, .cap = .borrow };
            try self.pushRawParamLocal(name, ids[i], .borrow);
        }

        const fsig = try self.appendGeneratedFuncSig("sla_future_ready_poll", .normal, specs, ids, .void, false);
        const sig_idx = self.function_sigs.items.len;
        try self.function_sigs.append(fsig);
        try self.appendDeclInst(fsig);
        try self.emitLabel("L_ENTRY");

        try self.emitStdMacroFragment("sa_std/core/future.sa", "FUTURE_READY_SET_POLL_STATE", &.{
            self.symbols.items[ids[2]],
            self.symbols.items[ids[0]],
        });
        for (ids) |id| try self.emitRelease(id);
        try self.emitReturn(null);

        try self.finishFunctionBody(sig_idx);

        self.popLocalsTo(old_locals);
        self.beginFunction();

        const defer_specs = try self.allocator.alloc(sig.ParamSpec, names.len);
        const defer_ids = try self.allocator.alloc(u32, names.len);
        for (names, 0..) |name, i| {
            defer_ids[i] = try self.intern(name);
            defer_specs[i] = .{ .name = name, .ty = .ptr, .cap = .borrow };
            try self.pushRawParamLocal(name, defer_ids[i], .borrow);
        }

        const defer_fsig = try self.appendGeneratedFuncSig("sla_future_defer_ready_poll", .normal, defer_specs, defer_ids, .void, false);
        const defer_sig_idx = self.function_sigs.items.len;
        try self.function_sigs.append(defer_fsig);
        try self.appendDeclInst(defer_fsig);
        try self.emitLabel("L_ENTRY");

        const defer_stage = try self.intern(try self.newTmp());
        const defer_is_initial = try self.intern(try self.newTmp());
        const defer_pending_label = try self.newLabel("L_DEFER_READY_PENDING");
        const defer_check_ready_label = try self.newLabel("L_DEFER_READY_CHECK_READY");
        const defer_ready_label = try self.newLabel("L_DEFER_READY_READY");
        const defer_empty_label = try self.newLabel("L_DEFER_READY_EMPTY");
        const defer_done_label = try self.newLabel("L_DEFER_READY_DONE");
        try self.emitLoad(defer_stage, defer_ids[0], 0, .u64);
        try self.emitOp(defer_is_initial, .eq, .{ .reg = defer_stage }, .{ .imm_i64 = 0 });
        try self.emitBranch(defer_is_initial, defer_pending_label, defer_check_ready_label);

        try self.emitLabel(defer_pending_label);
        const defer_stage_one = try self.intern(try self.newTmp());
        try self.emitAssignImm(defer_stage_one, 1);
        try self.emitStore(defer_ids[0], 0, defer_stage_one, .u64);
        try self.emitStdMacroFragment("sa_std/core/future.sa", "POLL_SET_PENDING", &.{self.symbols.items[defer_ids[2]]});
        try self.emitRelease(defer_stage_one);
        try self.emitJmp(defer_done_label);

        try self.emitLabel(defer_check_ready_label);
        const defer_is_ready = try self.intern(try self.newTmp());
        try self.emitOp(defer_is_ready, .eq, .{ .reg = defer_stage }, .{ .imm_i64 = 1 });
        try self.emitBranch(defer_is_ready, defer_ready_label, defer_empty_label);

        try self.emitLabel(defer_ready_label);
        const defer_value = try self.intern(try self.newTmp());
        const defer_stage_two = try self.intern(try self.newTmp());
        try self.emitLoad(defer_value, defer_ids[0], 8, .u64);
        try self.emitAssignImm(defer_stage_two, 2);
        try self.emitStore(defer_ids[0], 0, defer_stage_two, .u64);
        try self.emitStdMacroFragment("sa_std/core/future.sa", "POLL_SET_READY", &.{
            self.symbols.items[defer_ids[2]],
            self.symbols.items[defer_value],
        });
        try self.emitRelease(defer_stage_two);
        try self.emitRelease(defer_value);
        try self.emitRelease(defer_is_ready);
        try self.emitJmp(defer_done_label);

        try self.emitLabel(defer_empty_label);
        try self.emitStdMacroFragment("sa_std/core/future.sa", "POLL_SET_PENDING", &.{self.symbols.items[defer_ids[2]]});
        try self.emitRelease(defer_is_ready);

        try self.emitLabel(defer_done_label);
        try self.emitRelease(defer_is_initial);
        try self.emitRelease(defer_stage);
        for (defer_ids) |id| try self.emitRelease(id);
        try self.emitReturn(null);

        try self.finishFunctionBody(defer_sig_idx);

        self.popLocalsTo(old_locals);
        self.beginFunction();

        const join_specs = try self.allocator.alloc(sig.ParamSpec, names.len);
        const join_ids = try self.allocator.alloc(u32, names.len);
        for (names, 0..) |name, i| {
            join_ids[i] = try self.intern(name);
            join_specs[i] = .{ .name = name, .ty = .ptr, .cap = .borrow };
            try self.pushRawParamLocal(name, join_ids[i], .borrow);
        }

        const join_fsig = try self.appendGeneratedFuncSig("sla_future_join2_poll", .normal, join_specs, join_ids, .void, false);
        const join_sig_idx = self.function_sigs.items.len;
        try self.function_sigs.append(join_fsig);
        try self.appendDeclInst(join_fsig);
        try self.emitLabel("L_ENTRY");

        const join_poll = try self.intern(try self.newTmp());
        const join_tag = try self.intern(try self.newTmp());
        const join_value = try self.intern(try self.newTmp());
        try self.emitStdMacroFragment("sa_std/core/future.sa", "FUTURE_JOIN2_STATE_POLL", &.{
            self.symbols.items[join_poll],
            self.symbols.items[join_ids[0]],
            self.symbols.items[join_ids[1]],
        });
        try self.emitLoad(join_tag, join_poll, 0, .u64);
        try self.emitLoad(join_value, join_poll, 8, .u64);
        try self.emitStore(join_ids[2], 0, join_tag, .u64);
        try self.emitStore(join_ids[2], 8, join_value, .u64);
        try self.emitRelease(join_value);
        try self.emitRelease(join_tag);
        try self.emitRelease(join_poll);
        for (join_ids) |id| try self.emitRelease(id);
        try self.emitReturn(null);

        try self.finishFunctionBody(join_sig_idx);

        self.popLocalsTo(old_locals);
        self.beginFunction();

        const select_specs = try self.allocator.alloc(sig.ParamSpec, names.len);
        const select_ids = try self.allocator.alloc(u32, names.len);
        for (names, 0..) |name, i| {
            select_ids[i] = try self.intern(name);
            select_specs[i] = .{ .name = name, .ty = .ptr, .cap = .borrow };
            try self.pushRawParamLocal(name, select_ids[i], .borrow);
        }

        const select_fsig = try self.appendGeneratedFuncSig("sla_future_select2_poll", .normal, select_specs, select_ids, .void, false);
        const select_sig_idx = self.function_sigs.items.len;
        try self.function_sigs.append(select_fsig);
        try self.appendDeclInst(select_fsig);
        try self.emitLabel("L_ENTRY");

        const select_poll = try self.intern(try self.newTmp());
        const select_tag = try self.intern(try self.newTmp());
        const select_value = try self.intern(try self.newTmp());
        try self.emitStdMacroFragment("sa_std/core/future.sa", "FUTURE_SELECT2_STATE_POLL", &.{
            self.symbols.items[select_poll],
            self.symbols.items[select_ids[0]],
            self.symbols.items[select_ids[1]],
        });
        try self.emitLoad(select_tag, select_poll, 0, .u64);
        try self.emitLoad(select_value, select_poll, 8, .u64);
        try self.emitStore(select_ids[2], 0, select_tag, .u64);
        try self.emitStore(select_ids[2], 8, select_value, .u64);
        try self.emitRelease(select_value);
        try self.emitRelease(select_tag);
        try self.emitRelease(select_poll);
        for (select_ids) |id| try self.emitRelease(id);
        try self.emitReturn(null);

        try self.finishFunctionBody(select_sig_idx);
    }

    fn emitEscapedWorker(self: *Codegen, entry: EscapedClosureEntry) !void {
        const old_locals = self.locals.items.len;
        defer self.popLocalsTo(old_locals);
        self.beginFunction();

        const param = try self.oneGeneratedParam("slot", .borrow);
        try self.pushRawParamLocal("slot", param.id, .borrow);
        const fsig = try self.appendGeneratedFuncSig(entry.worker_name, .normal, param.specs, param.ids, .i32, false);
        const sig_idx = self.function_sigs.items.len;
        try self.function_sigs.append(fsig);
        try self.appendDeclInst(fsig);
        try self.emitLabel("L_ENTRY");

        var capture_regs = std.ArrayList(struct { reg: u32, ty: *const ast.Type }).init(self.allocator);
        defer capture_regs.deinit();
        for (entry.captures) |capture| {
            const reg = try self.intern(try self.newTmp());
            if (capture.ty.* == .fn_ptr) {
                try self.emitPtrAdd(reg, param.id, .{ .imm_u64 = @intCast(capture.offset) });
            } else {
                try self.emitLoad(reg, param.id, capture.offset, try storagePrimType(capture.ty));
            }
            try self.pushTypedLocal(capture.name, reg, false, capture.ty);
            try capture_regs.append(.{ .reg = reg, .ty = capture.ty });
        }

        const value = try self.genExpr(@constCast(entry.closure.body));
        try self.emitStore(param.id, 8, value, try primType(entry.ret_ty));
        for (capture_regs.items) |capture| {
            if (capture.reg == value or self.released_regs.contains(capture.reg)) continue;
            if (self.typeIsCopyValue(capture.ty) or lowering_rules.isBorrowLikeType(capture.ty)) {
                try self.emitMove(capture.reg);
            } else {
                try self.emitRelease(capture.reg);
            }
        }
        if ((try primType(entry.ret_ty)) == .i32) {
            try self.emitMove(param.id);
            try self.emitReturn(value);
        } else {
            try self.emitMove(value);
            try self.emitMove(param.id);
            const zero = try self.intern(try self.newTmp());
            try self.emitAssignImm(zero, 0);
            try self.emitReturn(zero);
        }

        try self.finishFunctionBody(sig_idx);
    }

    fn emitEscapedClosureEntries(self: *Codegen) !void {
        if (self.escaped_closure_entries.count() == 0) return;
        var iter = self.escaped_closure_entries.valueIterator();
        while (iter.next()) |entry| {
            try self.emitEscapedSpawnWrapper(entry.*);
            try self.emitEscapedWorker(entry.*);
        }
    }

    fn genFuncSig(self: *Codegen, name: []const u8, kind: sig.FunctionKind, params: []const ast.Param, ret_ty: *ast.Type, is_async: bool, ignored: bool, should_panic: bool) !sig.FunctionSig {
        const id: u32 = @intCast(self.function_sigs.items.len + self.test_sigs.items.len);
        const lowered = if (kind == .test_func)
            try std.fmt.allocPrint(self.allocator, "\"{s}\"", .{name})
        else
            try self.loweredFuncSymbol(name);
        _ = try self.intern(lowered);
        const specs = try self.allocator.alloc(sig.ParamSpec, params.len);
        const param_ids = try self.allocator.alloc(u32, params.len);
        for (params, 0..) |param, i| {
            const scoped_param_name = try std.fmt.allocPrint(self.allocator, "{s}__param_{d}_{s}", .{ lowered, i, param.name });
            const param_id = try self.intern(scoped_param_name);
            const cap: inst.CapPrefix = self.paramCapability(param);
            specs[i] = .{
                .name = param.name,
                .ty = try paramPrimType(param.ty),
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
            .return_cap = returnCapForType(ret_ty),
            .return_ty = if (is_async) .ptr else try self.abiReturnPrimType(ret_ty),
            .entry_inst_idx = @intCast(self.instructions.items.len),
            .is_ffi_wrapper = false,
            .param_ids = param_ids,
            .reg_ids = &.{},
            .llvm_name = if (kind == .test_func) try std.fmt.allocPrint(self.allocator, "_saasm_test_{d}", .{id}) else null,
            .ignored = ignored,
            .should_panic = should_panic,
        };
    }

    fn abiReturnPrimType(self: *Codegen, ret_ty: *const ast.Type) !sig.PrimType {
        _ = self;
        if (ret_ty.* == .primitive and ret_ty.primitive == .boolean) return .i32;
        return try primType(ret_ty);
    }

    fn declInstForSig(self: *Codegen, fsig: sig.FunctionSig, expanded_line: usize) !inst.Instruction {
        const id = try self.intern(fsig.name);
        const kind: inst.InstKind = switch (fsig.kind) {
            .normal => .func_decl,
            .ffi_wrapper => .ffi_wrapper_decl,
            .external => .extern_decl,
            .exported => .export_decl,
            .test_func => .test_decl,
        };
        var item = inst.makeInstruction(kind, 0, @intCast(expanded_line), null, "");
        item.operands[0] = .{ .symbol = id };
        item.operands[1] = .{ .func = id };
        return item;
    }

    fn appendDeclInst(self: *Codegen, fsig: sig.FunctionSig) !void {
        const item = try self.declInstForSig(fsig, self.instructions.items.len);
        try self.appendInst(item);
    }

    fn paramNeedsEntryStackSlot(self: *Codegen, param: ast.Param) bool {
        if (param.is_borrow or param.is_move) return false;
        if (self.borrowedBindingNeedsStackStorage(param.name, param.ty)) return true;
        if (self.typeIsCopyValue(param.ty)) return false;
        if (self.bindingNeedsScalarReassignSlot(param.name, param.ty)) return true;
        return false;
    }

    fn materializeBorrowedParams(self: *Codegen, params: []const ast.Param) !void {
        for (params) |param| {
            if (!self.paramNeedsEntryStackSlot(param)) continue;
            const slot_name = try std.fmt.allocPrint(self.allocator, "{s}_slot", .{param.name});
            const slot = try self.intern(slot_name);
            const param_reg = self.localReg(param.name) orelse return Error.UnsupportedSabDirectFeature;
            try self.emitStackAlloc(slot, typeSize(param.ty));
            try self.emitStore(slot, 0, param_reg, try storagePrimType(param.ty));
            if ((try primType(param.ty)) != .ptr and !self.typeIsCopyValue(param.ty)) {
                try self.emitMove(param_reg);
            }
            try self.pushStackLocal(param.name, slot, param.ty);
        }
    }

    fn genAsyncSingleAwaitFuncDeclNamed(self: *Codegen, name: []const u8, f: *const ast.FuncDecl, plan: lowering_rules.AsyncSingleAwaitContinuationPlan) !void {
        try self.emitAsyncSingleAwaitPollHelper(name, plan);

        self.beginFunction();
        try self.prepareMultiLetBindings(f.body);
        try self.collectBorrowedBindingsInBlock(f.body);
        const async_plan = lowering_rules.planAsyncFunctionReturn(f.*, try self.makePointerType());
        const fsig = try self.genFuncSig(name, .normal, f.params, @constCast(async_plan.abi_ret_ty), f.is_async, false, false);
        const sig_idx = self.function_sigs.items.len;
        try self.function_sigs.append(fsig);
        try self.appendDeclInst(fsig);
        try self.emitLabel("L_ENTRY");
        try self.materializeBorrowedParams(f.params);

        var captured_addends: [2]?u32 = .{ null, null };
        for (0..plan.capture_count) |capture_idx| {
            const capture = plan.captures[capture_idx] orelse return Error.UnsupportedSabDirectFeature;
            const capture_reg = try self.genExpr(@constCast(capture.expr));
            captured_addends[capture_idx] = switch (capture.storage) {
                .scalar => capture_reg,
                .copy_struct => blk: {
                    const capture_ty = self.tc.expr_types.get(capture.expr) orelse return Error.MissingType;
                    if (!self.typeIsCopyStruct(capture_ty)) return Error.UnsupportedSabDirectFeature;
                    if (capture.expr.* == .identifier) {
                        const copied = try self.genCopyValue(capture_reg, capture_ty);
                        break :blk copied;
                    }
                    break :blk capture_reg;
                },
            };
        }
        const inner_state = try self.genExpr(@constCast(plan.await_expr));
        const async_state = try self.intern(try self.newTmp());
        const zero = try self.intern(try self.newTmp());
        try self.emitAlloc(async_state, plan.asyncStateSize());
        try self.emitAssignImm(zero, 0);
        try self.emitStore(async_state, 0, zero, .u64);
        try self.emitStore(async_state, 8, inner_state, .ptr);
        for (0..plan.capture_count) |capture_idx| {
            const capture = plan.captures[capture_idx] orelse return Error.UnsupportedSabDirectFeature;
            const addend_reg = captured_addends[capture_idx] orelse return Error.UnsupportedSabDirectFeature;
            try self.emitStore(async_state, capture.offset, addend_reg, switch (capture.storage) {
                .scalar => .u64,
                .copy_struct => .ptr,
            });
            if (capture.storage == .scalar) try self.emitRelease(addend_reg);
        }
        try self.emitRelease(zero);
        try self.emitRelease(inner_state);
        try self.future_state_vtables.put(async_state, try self.asyncSingleAwaitVTableName(name));
        try self.recordFutureReadiness(async_state, .unknown);
        try self.releaseOpenLocals(async_state);
        try self.emitReturn(async_state);

        try self.finishFunctionBody(sig_idx);
    }

    fn genAsyncTwoAwaitFuncDeclNamed(self: *Codegen, name: []const u8, f: *const ast.FuncDecl, plan: lowering_rules.AsyncTwoAwaitContinuationPlan) !void {
        try self.emitAsyncTwoAwaitPollHelper(name, plan);

        self.beginFunction();
        try self.prepareMultiLetBindings(f.body);
        try self.collectBorrowedBindingsInBlock(f.body);
        const async_plan = lowering_rules.planAsyncFunctionReturn(f.*, try self.makePointerType());
        const fsig = try self.genFuncSig(name, .normal, f.params, @constCast(async_plan.abi_ret_ty), f.is_async, false, false);
        const sig_idx = self.function_sigs.items.len;
        try self.function_sigs.append(fsig);
        try self.appendDeclInst(fsig);
        try self.emitLabel("L_ENTRY");
        try self.materializeBorrowedParams(f.params);

        const first_state = try self.genExpr(@constCast(plan.first_await_expr));
        const second_state = try self.genExpr(@constCast(plan.second_await_expr));
        const async_state = try self.intern(try self.newTmp());
        const zero = try self.intern(try self.newTmp());
        try self.emitAlloc(async_state, plan.asyncStateSize());
        try self.emitAssignImm(zero, 0);
        try self.emitStore(async_state, 0, zero, .u64);
        try self.emitStore(async_state, 8, first_state, .ptr);
        try self.emitStore(async_state, 16, second_state, .ptr);
        try self.emitStore(async_state, 24, zero, .u64);
        try self.emitRelease(zero);
        try self.emitRelease(second_state);
        try self.emitRelease(first_state);
        try self.future_state_vtables.put(async_state, try self.asyncTwoAwaitVTableName(name));
        try self.recordFutureReadiness(async_state, .unknown);
        try self.releaseOpenLocals(async_state);
        try self.emitReturn(async_state);

        try self.finishFunctionBody(sig_idx);
    }

    fn genAsyncJoin2AwaitFuncDeclNamed(self: *Codegen, name: []const u8, f: *const ast.FuncDecl, plan: lowering_rules.AsyncJoin2AwaitContinuationPlan) !void {
        try self.emitAsyncJoin2AwaitPollHelper(name, plan);

        self.beginFunction();
        try self.prepareMultiLetBindings(f.body);
        try self.collectBorrowedBindingsInBlock(f.body);
        const async_plan = lowering_rules.planAsyncFunctionReturn(f.*, try self.makePointerType());
        const fsig = try self.genFuncSig(name, .normal, f.params, @constCast(async_plan.abi_ret_ty), f.is_async, false, false);
        const sig_idx = self.function_sigs.items.len;
        try self.function_sigs.append(fsig);
        try self.appendDeclInst(fsig);
        try self.emitLabel("L_ENTRY");
        try self.materializeBorrowedParams(f.params);

        const join_state = try self.genExpr(@constCast(plan.await_expr));
        const async_state = try self.intern(try self.newTmp());
        const zero = try self.intern(try self.newTmp());
        try self.emitAlloc(async_state, plan.asyncStateSize());
        try self.emitAssignImm(zero, 0);
        try self.emitStore(async_state, 0, zero, .u64);
        try self.emitStore(async_state, 8, join_state, .ptr);
        try self.emitRelease(zero);
        try self.emitRelease(join_state);
        try self.future_state_vtables.put(async_state, try self.asyncJoin2AwaitVTableName(name));
        try self.recordFutureReadiness(async_state, .unknown);
        try self.releaseOpenLocals(async_state);
        try self.emitReturn(async_state);

        try self.finishFunctionBody(sig_idx);
    }

    fn genFuncDeclNamed(self: *Codegen, name: []const u8, f: *const ast.FuncDecl) !void {
        const old_locals = self.locals.items.len;
        defer self.popLocalsTo(old_locals);
        const old_async_return = self.current_async_return;
        const old_async_return_ty = self.current_async_return_ty;
        self.current_async_return = f.is_async;
        self.current_async_return_ty = if (f.is_async) f.ret_ty else null;
        defer self.current_async_return = old_async_return;
        defer self.current_async_return_ty = old_async_return_ty;
        if (lowering_rules.planAsyncJoin2AwaitContinuation(f)) |plan| {
            return try self.genAsyncJoin2AwaitFuncDeclNamed(name, f, plan);
        }
        if (lowering_rules.planAsyncTwoAwaitContinuation(f)) |plan| {
            return try self.genAsyncTwoAwaitFuncDeclNamed(name, f, plan);
        }
        if (lowering_rules.planAsyncSingleAwaitContinuation(f)) |plan| {
            return try self.genAsyncSingleAwaitFuncDeclNamed(name, f, plan);
        }
        self.beginFunction();
        try self.prepareMultiLetBindings(f.body);
        try self.collectBorrowedBindingsInBlock(f.body);
        const async_plan = lowering_rules.planAsyncFunctionReturn(f.*, try self.makePointerType());
        const fsig = try self.genFuncSig(name, .normal, f.params, @constCast(async_plan.abi_ret_ty), f.is_async, false, false);
        const sig_idx = self.function_sigs.items.len;
        try self.function_sigs.append(fsig);
        try self.appendDeclInst(fsig);
        try self.emitLabel("L_ENTRY");
        try self.materializeBorrowedParams(f.params);
        const ret_prim = try primType(async_plan.abi_ret_ty);
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
                const old_result_escapes = self.current_expr_result_escapes;
                self.current_expr_result_escapes = true;
                defer self.current_expr_result_escapes = old_result_escapes;
                var value = try self.genExpr(tail);
                if (async_plan.wrap_ready_future) value = try self.genReadyFuture(value);
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
        if (async_plan.wrap_ready_future and !self.lastIsTerminator()) {
            const zero = try self.intern(try self.newTmp());
            try self.emitAssignImm(zero, 0);
            const future = try self.genReadyFuture(zero);
            try self.releaseOpenLocals(future);
            try self.emitReturn(future);
        } else if (ret_prim == .void and !self.lastIsTerminator()) {
            try self.releaseOpenLocals(null);
            try self.emitReturn(null);
        }
        try self.finishFunctionBody(sig_idx);
    }

    fn genFuncDecl(self: *Codegen, f: *const ast.FuncDecl) !void {
        try self.genFuncDeclNamed(f.name, f);
    }

    fn genExternDecl(self: *Codegen, f: *const ast.FuncDecl) !void {
        var fsig = try self.genFuncSig(f.name, .external, f.params, f.ret_ty, false, false, false);
        try self.appendDeclInst(fsig);
        fsig.reg_ids = fsig.param_ids;
        try self.function_sigs.append(fsig);
    }

    fn abiPrimType(raw: []const u8) sig.PrimType {
        var name = std.mem.trim(u8, raw, " \t\r");
        if (name.len > 0 and (name[0] == '&' or name[0] == '^' or name[0] == '*')) name = std.mem.trim(u8, name[1..], " \t\r");
        if (std.mem.endsWith(u8, name, "!")) name = std.mem.trim(u8, name[0 .. name.len - 1], " \t\r");
        if (std.mem.eql(u8, name, "ptr")) return .ptr;
        if (std.mem.eql(u8, name, "bool")) return .i1;
        if (std.mem.eql(u8, name, "i8")) return .i8;
        if (std.mem.eql(u8, name, "i16")) return .i16;
        if (std.mem.eql(u8, name, "i32")) return .i32;
        if (std.mem.eql(u8, name, "i64") or std.mem.eql(u8, name, "int") or std.mem.eql(u8, name, "isize")) return .i64;
        if (std.mem.eql(u8, name, "u8")) return .u8;
        if (std.mem.eql(u8, name, "u16")) return .u16;
        if (std.mem.eql(u8, name, "u32")) return .u32;
        if (std.mem.eql(u8, name, "u64") or std.mem.eql(u8, name, "usize")) return .u64;
        if (std.mem.eql(u8, name, "f32")) return .f32;
        if (std.mem.eql(u8, name, "f64") or std.mem.eql(u8, name, "float")) return .f64;
        return .void;
    }

    fn hasFunctionSig(self: *Codegen, name: []const u8, kind: sig.FunctionKind) bool {
        for (self.function_sigs.items) |fsig| {
            if (fsig.kind == kind and std.mem.eql(u8, fsig.name, name)) return true;
        }
        return false;
    }

    fn makeContractExternSig(self: *Codegen, name: []const u8, entry_inst_idx: usize) !sig.FunctionSig {
        const ext = self.tc.extern_funcs.get(name) orelse return Error.UnsupportedSabDirectFeature;
        const lowered = try self.loweredFuncSymbol(name);
        _ = try self.intern(lowered);

        const specs = try self.allocator.alloc(sig.ParamSpec, ext.params.len);
        const param_ids = try self.allocator.alloc(u32, ext.params.len);
        for (ext.params, 0..) |param, idx| {
            const cap: inst.CapPrefix = if (param.is_borrow) .borrow else if (param.is_move) .move else .by_value;
            specs[idx] = .{
                .name = param.name,
                .ty = abiPrimType(param.ty),
                .cap = cap,
            };
            param_ids[idx] = try self.intern(param.name);
        }

        return sig.FunctionSig{
            .id = 0,
            .name = lowered,
            .params = specs,
            .kind = .external,
            .return_cap = abiReturnCap(ext.ret_ty),
            .return_ty = abiPrimType(ext.ret_ty),
            .return_fallible = ext.return_fallible,
            .entry_inst_idx = @intCast(entry_inst_idx),
            .is_ffi_wrapper = false,
            .param_ids = param_ids,
            .reg_ids = param_ids,
            .llvm_name = null,
            .ignored = false,
            .should_panic = false,
        };
    }

    fn emitContractExternDecl(self: *Codegen, name: []const u8) !void {
        const lowered = try self.loweredFuncSymbol(name);
        if (self.hasFunctionSig(lowered, .external)) return;
        var fsig = try self.makeContractExternSig(name, self.instructions.items.len);
        fsig.id = @intCast(self.function_sigs.items.len);
        try self.appendDeclInst(fsig);
        try self.function_sigs.append(fsig);
    }

    fn emitContractExternDecls(self: *Codegen) !void {
        var names = std.ArrayList([]const u8).init(self.allocator);
        defer names.deinit();
        var iter = self.tc.extern_funcs.keyIterator();
        while (iter.next()) |name| try names.append(name.*);
        std.mem.sort([]const u8, names.items, {}, stringSliceLessThan);
        for (names.items) |name| try self.emitContractExternDecl(name);
    }

    fn callInstructionBody(item: inst.Instruction) ?[]const u8 {
        if (item.kind != .call and item.kind != .call_indirect) return null;
        if (item.operands[1] == .text) return item.operands[1].text;
        if (item.operands[0] == .text) return item.operands[0].text;
        return null;
    }

    fn isCallTargetChar(ch: u8) bool {
        return std.ascii.isAlphanumeric(ch) or ch == '_';
    }

    fn callTargetName(body: []const u8) ?[]const u8 {
        const trimmed = std.mem.trimLeft(u8, body, " \t\r");
        if (trimmed.len == 0 or trimmed[0] != '@') return null;
        var end: usize = 1;
        while (end < trimmed.len and isCallTargetChar(trimmed[end])) : (end += 1) {}
        if (end == 1) return null;
        return trimmed[1..end];
    }

    fn directCallTargetName(body: []const u8) ?[]const u8 {
        const trimmed = std.mem.trimLeft(u8, body, " \t\r");
        const target = callTargetName(trimmed) orelse return null;
        const after = std.mem.trimLeft(u8, trimmed[target.len + 1 ..], " \t\r");
        if (after.len == 0 or after[0] != '(') return null;
        return target;
    }

    fn emitReferencedContractExternDecls(self: *Codegen) !void {
        var names = std.StringHashMap(void).init(self.allocator);
        defer names.deinit();
        for (self.instructions.items) |item| {
            const target = callTargetName(callInstructionBody(item) orelse continue) orelse continue;
            if (!self.tc.extern_funcs.contains(target)) continue;
            if (self.hasFunctionSig(target, .external)) continue;
            try names.put(target, {});
        }

        var sorted = std.ArrayList([]const u8).init(self.allocator);
        defer sorted.deinit();
        var iter = names.keyIterator();
        while (iter.next()) |name| try sorted.append(name.*);
        std.mem.sort([]const u8, sorted.items, {}, stringSliceLessThan);
        if (sorted.items.len == 0) return;

        var extern_sigs = std.ArrayList(sig.FunctionSig).init(self.allocator);
        defer extern_sigs.deinit();
        var extern_insts = std.ArrayList(inst.Instruction).init(self.allocator);
        defer extern_insts.deinit();
        for (sorted.items, 0..) |name, idx| {
            var fsig = try self.makeContractExternSig(name, idx);
            fsig.id = @intCast(idx);
            try extern_insts.append(try self.declInstForSig(fsig, idx));
            try extern_sigs.append(fsig);
        }

        const shift = extern_insts.items.len;
        var shifted_insts = std.ArrayList(inst.Instruction).init(self.allocator);
        try shifted_insts.ensureTotalCapacity(shift + self.instructions.items.len);
        shifted_insts.appendSliceAssumeCapacity(extern_insts.items);
        shifted_insts.appendSliceAssumeCapacity(self.instructions.items);
        self.instructions.deinit();
        self.instructions = shifted_insts;

        var shifted_sigs = std.ArrayList(sig.FunctionSig).init(self.allocator);
        try shifted_sigs.ensureTotalCapacity(extern_sigs.items.len + self.function_sigs.items.len);
        shifted_sigs.appendSliceAssumeCapacity(extern_sigs.items);
        for (self.function_sigs.items) |fsig| {
            var shifted = fsig;
            shifted.entry_inst_idx += @intCast(shift);
            shifted_sigs.appendAssumeCapacity(shifted);
        }
        self.function_sigs.deinit();
        self.function_sigs = shifted_sigs;

        for (self.test_sigs.items) |*test_sig| {
            test_sig.entry_inst_idx += @intCast(shift);
        }
        self.renumberFunctionSigs();
    }

    fn renumberFunctionSigs(self: *Codegen) void {
        for (self.function_sigs.items, 0..) |*fsig, idx| {
            fsig.id = @intCast(idx);
        }
        for (self.test_sigs.items) |*test_sig| {
            for (self.function_sigs.items) |fsig| {
                if (fsig.kind == .test_func and std.mem.eql(u8, fsig.name, test_sig.name)) {
                    test_sig.id = fsig.id;
                    test_sig.entry_inst_idx = fsig.entry_inst_idx;
                    break;
                }
            }
        }
    }

    fn genImplDecl(self: *Codegen, impl_decl: *const ast.ImplDecl) !void {
        const impl_name = concreteTypeName(impl_decl.target_ty) orelse return Error.UnsupportedSabDirectFeature;
        for (impl_decl.methods) |method| {
            if (method.* != .func_decl) return Error.UnsupportedSabDirectFeature;
            if (method.func_decl.is_decl_only) continue;
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
            if (method.func_decl.is_decl_only) continue;
            const mangled = try self.mangleMethodName(overload_name, method.func_decl.name);
            try self.genFuncDeclNamed(mangled, &method.func_decl);
        }
    }

    fn genTestDecl(self: *Codegen, t: *const ast.TestDecl) !void {
        const old_locals = self.locals.items.len;
        defer self.popLocalsTo(old_locals);
        self.beginFunction();
        try self.prepareMultiLetBindings(t.body);
        try self.collectBorrowedBindingsInBlock(t.body);
        const fsig = try self.genFuncSig(t.name, .test_func, &.{}, self.voidType(), false, t.is_ignored, t.should_panic);
        const sig_idx = self.function_sigs.items.len;
        try self.function_sigs.append(fsig);
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
        try self.finishFunctionBody(sig_idx);
        try self.test_sigs.append(self.function_sigs.items[sig_idx]);
    }

    fn voidType(self: *Codegen) *ast.Type {
        const ty = self.allocator.create(ast.Type) catch unreachable;
        ty.* = .{ .primitive = .void_type };
        return ty;
    }

    fn nodeBindsIdentifier(node: *const ast.Node, name: []const u8) bool {
        return switch (node.*) {
            .let_stmt => |let| std.mem.eql(u8, let.name, name),
            .const_stmt => |constant| std.mem.eql(u8, constant.name, name),
            .var_stmt => |variable| std.mem.eql(u8, variable.name, name),
            .let_destructure_stmt => |let| blk: {
                for (let.names) |binding| {
                    if (std.mem.eql(u8, binding, name)) break :blk true;
                }
                break :blk false;
            },
            else => false,
        };
    }

    fn blockUsesIdentifier(body: []const *ast.Node, name: []const u8) bool {
        for (body) |stmt| {
            if (nodeUsesIdentifier(stmt, name)) return true;
            if (nodeBindsIdentifier(stmt, name)) return false;
        }
        return false;
    }

    fn closureShadowsIdentifier(closure: ast.ClosureLiteral, name: []const u8) bool {
        for (closure.params) |param| {
            if (std.mem.eql(u8, param.name, name)) return true;
        }
        return false;
    }

    fn nodeUsesIdentifier(node: *const ast.Node, name: []const u8) bool {
        return switch (node.*) {
            .program => |program| blockUsesIdentifier(program.decls, name),
            .func_decl => |func| blockUsesIdentifier(func.body, name),
            .macro_decl => |macro| blockUsesIdentifier(macro.body, name),
            .test_decl => |test_decl| blockUsesIdentifier(test_decl.body, name),
            .impl_decl => |impl_decl| blockUsesIdentifier(impl_decl.methods, name),
            .let_stmt => |let| nodeUsesIdentifier(let.value, name),
            .let_else_stmt => |let| nodeUsesIdentifier(let.value, name) or blockUsesIdentifier(let.else_block, name),
            .let_destructure_stmt => |let| nodeUsesIdentifier(let.value, name),
            .const_stmt => |constant| nodeUsesIdentifier(constant.value, name),
            .assign_stmt => |assign| nodeUsesIdentifier(assign.target, name) or nodeUsesIdentifier(assign.value, name),
            .block_stmt => |block| blockUsesIdentifier(block.body, name),
            .expr_stmt => |expr| nodeUsesIdentifier(expr, name),
            .return_stmt => |ret| if (ret.value) |value| nodeUsesIdentifier(value, name) else false,
            .for_stmt => |for_stmt| blk: {
                if (nodeUsesIdentifier(for_stmt.start, name)) break :blk true;
                if (for_stmt.end) |end| {
                    if (nodeUsesIdentifier(end, name)) break :blk true;
                }
                if (std.mem.eql(u8, for_stmt.var_name, name)) break :blk false;
                break :blk blockUsesIdentifier(for_stmt.body, name);
            },
            .while_stmt => |while_stmt| nodeUsesIdentifier(while_stmt.cond, name) or blockUsesIdentifier(while_stmt.body, name),
            .identifier => |ident| std.mem.eql(u8, ident, name),
            .generic_func_ref => false,
            .if_expr => |ife| blk: {
                if (nodeUsesIdentifier(ife.cond, name)) break :blk true;
                if (ife.let_chain) |chain| {
                    for (chain) |item| {
                        if (nodeUsesIdentifier(item.value, name)) break :blk true;
                    }
                }
                if (blockUsesIdentifier(ife.then_block, name)) break :blk true;
                if (ife.else_block) |else_block| {
                    if (blockUsesIdentifier(else_block, name)) break :blk true;
                }
                break :blk false;
            },
            .switch_expr => |switch_expr| blk: {
                if (nodeUsesIdentifier(switch_expr.val, name)) break :blk true;
                for (switch_expr.cases) |case| {
                    if (blockUsesIdentifier(case.body, name)) break :blk true;
                }
                break :blk false;
            },
            .match_expr => |match_expr| blk: {
                if (nodeUsesIdentifier(match_expr.val, name)) break :blk true;
                for (match_expr.cases) |case| {
                    if (case.guard) |guard| {
                        if (nodeUsesIdentifier(guard, name)) break :blk true;
                    }
                    if (blockUsesIdentifier(case.body, name)) break :blk true;
                }
                break :blk false;
            },
            .unsafe_expr => |unsafe_expr| blockUsesIdentifier(unsafe_expr.body, name),
            .await_expr => |await_expr| nodeUsesIdentifier(await_expr.expr, name),
            .binary_expr => |bin| nodeUsesIdentifier(bin.left, name) or nodeUsesIdentifier(bin.right, name),
            .call_expr => |call| blk: {
                for (call.args) |arg| {
                    if (nodeUsesIdentifier(arg, name)) break :blk true;
                }
                break :blk false;
            },
            .closure_literal => |closure| if (closureShadowsIdentifier(closure, name)) false else nodeUsesIdentifier(closure.body, name),
            .borrow_expr => |borrow| nodeUsesIdentifier(borrow.expr, name),
            .move_expr => |move| nodeUsesIdentifier(move.expr, name),
            .deref_expr => |deref| nodeUsesIdentifier(deref.expr, name),
            .cast_expr => |cast| nodeUsesIdentifier(cast.expr, name),
            .field_expr => |field| nodeUsesIdentifier(field.expr, name),
            .struct_literal => |lit| blk: {
                if (lit.update_expr) |update| {
                    if (nodeUsesIdentifier(update, name)) break :blk true;
                }
                for (lit.fields) |field| {
                    if (nodeUsesIdentifier(field.value, name)) break :blk true;
                }
                break :blk false;
            },
            .enum_literal => |lit| blk: {
                for (lit.fields) |field| {
                    if (nodeUsesIdentifier(field.value, name)) break :blk true;
                }
                break :blk false;
            },
            .tuple_literal => |tuple| blk: {
                for (tuple.elements) |elem| {
                    if (nodeUsesIdentifier(elem, name)) break :blk true;
                }
                break :blk false;
            },
            .array_literal => |array| blk: {
                for (array.elements) |elem| {
                    if (nodeUsesIdentifier(elem, name)) break :blk true;
                }
                break :blk false;
            },
            .repeat_array_literal => |repeat| nodeUsesIdentifier(repeat.value, name),
            .index_expr => |idx| nodeUsesIdentifier(idx.target, name) or nodeUsesIdentifier(idx.index, name),
            .slice_expr => |slice| nodeUsesIdentifier(slice.target, name) or nodeUsesIdentifier(slice.start, name) or nodeUsesIdentifier(slice.end, name),
            .try_expr => |try_expr| nodeUsesIdentifier(try_expr.expr, name),
            else => false,
        };
    }

    fn nodeMayContainCall(node: *const ast.Node) bool {
        return switch (node.*) {
            .program => |program| blockMayContainCall(program.decls),
            .func_decl => |func| blockMayContainCall(func.body),
            .macro_decl => |macro| blockMayContainCall(macro.body),
            .test_decl => |test_decl| blockMayContainCall(test_decl.body),
            .impl_decl => |impl_decl| blockMayContainCall(impl_decl.methods),
            .let_stmt => |let| nodeMayContainCall(let.value),
            .let_else_stmt => |let| nodeMayContainCall(let.value) or blockMayContainCall(let.else_block),
            .let_destructure_stmt => |let| nodeMayContainCall(let.value),
            .const_stmt => |constant| nodeMayContainCall(constant.value),
            .assign_stmt => |assign| nodeMayContainCall(assign.target) or nodeMayContainCall(assign.value),
            .block_stmt => |block| blockMayContainCall(block.body),
            .expr_stmt => |expr| nodeMayContainCall(expr),
            .return_stmt => |ret| if (ret.value) |value| nodeMayContainCall(value) else false,
            .for_stmt => |for_stmt| nodeMayContainCall(for_stmt.start) or
                (if (for_stmt.end) |end| nodeMayContainCall(end) else false) or
                blockMayContainCall(for_stmt.body),
            .while_stmt => |while_stmt| nodeMayContainCall(while_stmt.cond) or blockMayContainCall(while_stmt.body),
            .if_expr => |ife| blk: {
                if (nodeMayContainCall(ife.cond)) break :blk true;
                if (ife.let_chain) |chain| {
                    for (chain) |item| {
                        if (nodeMayContainCall(item.value)) break :blk true;
                    }
                }
                if (blockMayContainCall(ife.then_block)) break :blk true;
                if (ife.else_block) |else_block| {
                    if (blockMayContainCall(else_block)) break :blk true;
                }
                break :blk false;
            },
            .switch_expr => |switch_expr| blk: {
                if (nodeMayContainCall(switch_expr.val)) break :blk true;
                for (switch_expr.cases) |case| {
                    if (blockMayContainCall(case.body)) break :blk true;
                }
                break :blk false;
            },
            .match_expr => |match_expr| blk: {
                if (nodeMayContainCall(match_expr.val)) break :blk true;
                for (match_expr.cases) |case| {
                    if (case.guard) |guard| {
                        if (nodeMayContainCall(guard)) break :blk true;
                    }
                    if (blockMayContainCall(case.body)) break :blk true;
                }
                break :blk false;
            },
            .unsafe_expr => |unsafe_expr| blockMayContainCall(unsafe_expr.body),
            .await_expr => |await_expr| nodeMayContainCall(await_expr.expr),
            .binary_expr => |bin| nodeMayContainCall(bin.left) or nodeMayContainCall(bin.right),
            .call_expr => true,
            .closure_literal => |closure| nodeMayContainCall(closure.body),
            .borrow_expr => |borrow| nodeMayContainCall(borrow.expr),
            .move_expr => |move| nodeMayContainCall(move.expr),
            .deref_expr => |deref| nodeMayContainCall(deref.expr),
            .cast_expr => |cast| nodeMayContainCall(cast.expr),
            .field_expr => |field| nodeMayContainCall(field.expr),
            .struct_literal => |lit| blk: {
                if (lit.update_expr) |update| {
                    if (nodeMayContainCall(update)) break :blk true;
                }
                for (lit.fields) |field| {
                    if (nodeMayContainCall(field.value)) break :blk true;
                }
                break :blk false;
            },
            .enum_literal => |lit| blk: {
                for (lit.fields) |field| {
                    if (nodeMayContainCall(field.value)) break :blk true;
                }
                break :blk false;
            },
            .tuple_literal => |tuple| blk: {
                for (tuple.elements) |elem| {
                    if (nodeMayContainCall(elem)) break :blk true;
                }
                break :blk false;
            },
            .array_literal => |array| blk: {
                for (array.elements) |elem| {
                    if (nodeMayContainCall(elem)) break :blk true;
                }
                break :blk false;
            },
            .repeat_array_literal => |repeat| nodeMayContainCall(repeat.value),
            .index_expr => |idx| nodeMayContainCall(idx.target) or nodeMayContainCall(idx.index),
            .slice_expr => |slice| nodeMayContainCall(slice.target) or nodeMayContainCall(slice.start) or nodeMayContainCall(slice.end),
            .try_expr => |try_expr| nodeMayContainCall(try_expr.expr),
            else => false,
        };
    }

    fn blockMayContainCall(body: []const *ast.Node) bool {
        for (body) |stmt| {
            if (nodeMayContainCall(stmt)) return true;
        }
        return false;
    }

    fn identifierUsedLaterInCurrentBlock(self: *Codegen, name: []const u8) bool {
        const block = self.current_block orelse return false;
        var idx = self.current_stmt_index + 1;
        while (idx < block.len) : (idx += 1) {
            const stmt = block[idx];
            if (nodeUsesIdentifier(stmt, name)) return true;
            if (nodeBindsIdentifier(stmt, name)) return false;
        }
        return false;
    }

    fn identifierUsedLaterInCurrentExpr(self: *Codegen, name: []const u8) bool {
        for (self.current_expr_later_nodes.items) |node| {
            if (nodeUsesIdentifier(node, name)) return true;
        }
        return false;
    }

    fn identifierMustStayLiveForLaterUse(self: *Codegen, name: []const u8) bool {
        return self.identifierUsedLaterInCurrentBlock(name) or self.identifierUsedLaterInCurrentExpr(name);
    }

    fn structLiteralFieldPlans(
        self: *Codegen,
        decl: *const ast.StructDecl,
        lit: *const ast.StructLiteral,
    ) ![]lowering_rules.StructLiteralFieldPlan {
        if (decl.is_union) return Error.UnsupportedSabDirectFeature;
        for (lit.fields) |literal_field| {
            var found = false;
            for (decl.fields) |decl_field| {
                if (std.mem.eql(u8, decl_field.name, literal_field.name)) {
                    found = true;
                    break;
                }
            }
            if (!found) return Error.UnsupportedSabDirectFeature;
        }

        const plans = try self.allocator.alloc(lowering_rules.StructLiteralFieldPlan, decl.fields.len);
        errdefer self.allocator.free(plans);
        var offset: usize = 0;
        for (decl.fields, 0..) |field, idx| {
            const size = lowering_rules.abiTypeSize(field.ty);
            offset = alignOffset(offset, size);
            const layout = lowering_rules.AbiFieldLayout{ .offset = offset, .size = size, .ty = field.ty };
            const explicit_value = blk: {
                for (lit.fields) |literal_field| {
                    if (std.mem.eql(u8, literal_field.name, field.name)) break :blk literal_field.value;
                }
                break :blk null;
            };
            if (explicit_value) |value| {
                plans[idx] = .{ .source = .explicit, .name = field.name, .value = value, .layout = layout, .field_ty = field.ty, .release_loaded = false };
            } else if (lit.update_expr) |update_expr| {
                plans[idx] = .{ .source = .update, .name = field.name, .value = null, .layout = layout, .field_ty = field.ty, .release_loaded = lowering_rules.callArgNeedsRelease(update_expr) };
            } else {
                return Error.UnsupportedSabDirectFeature;
            }
            offset += size;
        }
        return plans;
    }

    fn pushStructLiteralLaterFieldExprsFromPlans(
        self: *Codegen,
        plans: []const lowering_rules.StructLiteralFieldPlan,
        field_index: usize,
    ) !usize {
        const mark = self.current_expr_later_nodes.items.len;
        var i = field_index + 1;
        while (i < plans.len) : (i += 1) {
            const later = plans[i];
            if (later.source == .explicit) {
                if (later.value) |value| try self.current_expr_later_nodes.append(value);
            }
        }
        return mark;
    }

    fn pushCallSiblingArgExprs(self: *Codegen, args: []const *ast.Node, arg_index: usize) !usize {
        const mark = self.current_expr_later_nodes.items.len;
        for (args, 0..) |arg, i| {
            if (i == arg_index) continue;
            try self.current_expr_later_nodes.append(arg);
        }
        return mark;
    }

    fn pushMacroCallSiblingArgExprs(self: *Codegen, ctx: *MacroExpansionContext, args: []const *ast.Node, arg_index: usize) !usize {
        const mark = self.current_expr_later_nodes.items.len;
        for (args, 0..) |arg, i| {
            if (i == arg_index) continue;
            try self.current_expr_later_nodes.append(macroEffectiveArg(ctx, arg));
        }
        return mark;
    }

    fn pushIfBranchLaterNodes(self: *Codegen, ife: ast.IfExpr) !usize {
        const mark = self.current_expr_later_nodes.items.len;
        try self.current_expr_later_nodes.appendSlice(ife.then_block);
        if (ife.else_block) |else_block| try self.current_expr_later_nodes.appendSlice(else_block);
        return mark;
    }

    fn popExprLaterNodesTo(self: *Codegen, mark: usize) void {
        self.current_expr_later_nodes.shrinkRetainingCapacity(mark);
    }

    fn genBlock(self: *Codegen, body: []const *ast.Node) !void {
        const prev_block = self.current_block;
        const prev_stmt_index = self.current_stmt_index;
        self.current_block = body;
        defer {
            self.current_block = prev_block;
            self.current_stmt_index = prev_stmt_index;
        }
        for (body, 0..) |stmt, idx| {
            self.current_stmt_index = idx;
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
        const dst = try self.bindingReg(name);
        _ = self.future_readiness_by_name.remove(name);
        if (value_expr.* == .borrow_expr) {
            try self.pushLocal(name, src, false);
            return;
        }
        const let_ty = if (explicit_ty) |ty| ty else (try self.exprTypeOrFallback(value_expr)) orelse return Error.MissingType;
        const refcell_transfer_plan = lowering_rules.planRefCellValueStateTransfer(
            self.refcell_borrow_values.contains(src),
            self.borrow_address_temps.contains(src),
        );
        switch (lowering_rules.planRefCellHandleBinding(refcell_transfer_plan.handle == .move_borrow_handle)) {
            .bind_borrow_handle => {
                try self.pushTypedLocal(name, src, false, let_ty);
                return;
            },
            .ordinary_binding => {},
        }
        if (value_expr.* == .identifier and lowering_rules.isBorrowLikeType(let_ty) and self.isLocalReg(src)) {
            try self.pushTypedLocal(name, src, false, let_ty);
            return;
        }
        if (self.borrowedBindingNeedsStackStorage(name, let_ty)) {
            try self.emitStackAlloc(dst, typeSize(let_ty));
            try self.emitStore(dst, 0, src, try storagePrimType(let_ty));
            if (!self.isLocalReg(src) and !self.non_owning_regs.contains(src)) try self.emitRelease(src);
            try self.pushStackLocal(name, dst, let_ty);
            return;
        }
        if (self.bindingNeedsScalarReassignSlot(name, let_ty) or self.bindingNeedsCopyScalarReuseSlot(name, let_ty)) {
            try self.emitStackAlloc(dst, typeSize(let_ty));
            try self.emitStore(dst, 0, src, try storagePrimType(let_ty));
            if (!self.isLocalReg(src)) {
                if (typeIsPointerScalarValue(let_ty)) try self.markNonOwningReg(src);
                try self.emitRelease(src);
            }
            try self.pushStackLocal(name, dst, let_ty);
            return;
        }
        // `let b = a` where `a` is an identifier of a copy-struct type must deep
        // copy so `b` owns its own allocation, mirroring SA-text
        // `genCopyValueInto`. A plain `assign` would alias the same pointer and
        // both bindings would release the same allocation at scope end.
        if (value_expr.* == .identifier and self.isLocalReg(src) and self.typeIsCopyStruct(let_ty)) {
            const copied = try self.genCopyValue(src, let_ty);
            try self.emitAssignReg(dst, copied);
            try self.pushTypedLocal(name, dst, false, let_ty);
            return;
        }
        try self.emitAssignReg(dst, src);
        if (lowering_rules.storedValueMovesIdentifier(value_expr, let_ty, self.typeIsCopyValue(let_ty)) != null and self.isLocalReg(src)) {
            // `assign` gives the destination the same pointer-backed value. The
            // destination is now the sole cleanup owner, so suppress source
            // cleanup without emitting `move_`, which would invalidate both
            // verifier aliases of the same allocation.
            try self.markConsumed(src);
        }
        try self.transferFutureStateVTable(src, dst);
        try self.transferFutureReadiness(src, dst);
        if (self.futureReadinessForState(dst) != .unknown) {
            try self.future_readiness_by_name.put(name, self.futureReadinessForState(dst));
        } else {
            _ = self.future_readiness_by_name.remove(name);
        }
        try self.pushTypedLocal(name, dst, false, let_ty);
    }

    fn genLet(self: *Codegen, let: ast.LetStmt) anyerror!void {
        _ = self.future_readiness_by_name.remove(let.name);
        if (let.value.* == .call_expr and let.value.call_expr.associated_target == null and std.mem.eql(u8, let.value.call_expr.func_name, "stack_alloc")) {
            const dst = try self.bindingReg(let.name);
            try self.emitStackAlloc(dst, try stackAllocSize(let.value.call_expr));
            try self.pushStackAllocLocal(let.name, dst);
            return;
        }
        if (closureLiteralFromExpr(let.value)) |closure| {
            const dst = try self.bindingReg(let.name);
            try self.closure_bindings.put(let.name, closure);
            try self.emitAssignImm(dst, 0);
            try self.pushLocal(let.name, dst, false);
            return;
        }
        const src = try self.genExpr(let.value);
        if (self.lastIsTerminator()) return;
        if (std.mem.eql(u8, let.name, "_")) {
            if (!self.isLocalReg(src)) try self.emitRelease(src);
            return;
        }
        try self.genLetFromValue(let.name, let.ty, let.value, src);
    }

    fn genReadyFuture(self: *Codegen, value: u32) !u32 {
        const future = try self.intern(try self.newTmp());
        try self.recordReg(future);
        try self.emitStdMacroFragment("sa_std/core/future.sa", "FUTURE_READY_STATE_NEW", &.{
            self.symbols.items[future],
            self.symbols.items[value],
        });
        try self.future_state_vtables.put(future, "SLA_READY_FUTURE_VT");
        try self.recordFutureReadiness(future, .ready);
        return future;
    }

    fn genPendingFuture(self: *Codegen) !u32 {
        const future = try self.intern(try self.newTmp());
        try self.recordReg(future);
        try self.emitStdMacroFragment("sa_std/core/future.sa", "FUTURE_PENDING_STATE_NEW", &.{
            self.symbols.items[future],
        });
        try self.future_state_vtables.put(future, "SLA_READY_FUTURE_VT");
        try self.recordFutureReadiness(future, .pending);
        return future;
    }

    fn genDeferReadyFuture(self: *Codegen, value: u32) !u32 {
        const future = try self.intern(try self.newTmp());
        const zero = try self.intern(try self.newTmp());
        try self.emitAlloc(future, 16);
        try self.emitAssignImm(zero, 0);
        try self.emitStore(future, 0, zero, .u64);
        try self.emitStore(future, 8, value, .u64);
        try self.emitRelease(zero);
        try self.future_state_vtables.put(future, "SLA_DEFER_READY_FUTURE_VT");
        try self.recordFutureReadiness(future, .unknown);
        return future;
    }

    fn futureVTableForState(self: *Codegen, state_reg: u32) []const u8 {
        if (self.future_state_vtables.get(state_reg)) |vt_name| return vt_name;
        return "SLA_READY_FUTURE_VT";
    }

    fn genFutureObjectForState(self: *Codegen, state_reg: u32) !u32 {
        const vt_reg = try self.intern(try self.newTmp());
        const future_obj = try self.intern(try self.newTmp());
        try self.emitBorrowSymbol(vt_reg, self.futureVTableForState(state_reg));
        try self.emitStdMacroFragment("sa_std/core/future.sa", "FUTURE_NEW", &.{
            self.symbols.items[future_obj],
            self.symbols.items[state_reg],
            self.symbols.items[vt_reg],
        });
        try self.emitRelease(vt_reg);
        if (!self.isLocalReg(state_reg)) try self.emitRelease(state_reg);
        return future_obj;
    }

    fn genJoin2Future(self: *Codegen, left_state: u32, right_state: u32) !u32 {
        const readiness = lowering_rules.join2Readiness(self.futureReadinessForState(left_state), self.futureReadinessForState(right_state));
        const left_future = try self.genFutureObjectForState(left_state);
        const right_future = try self.genFutureObjectForState(right_state);
        const join_state = try self.intern(try self.newTmp());
        try self.recordReg(join_state);
        try self.emitStdMacroFragment("sa_std/core/future.sa", "FUTURE_JOIN2_STATE_NEW", &.{
            self.symbols.items[join_state],
            self.symbols.items[left_future],
            self.symbols.items[right_future],
        });
        try self.future_state_vtables.put(join_state, "SLA_JOIN2_FUTURE_VT");
        try self.recordFutureReadiness(join_state, readiness);
        try self.emitRelease(left_future);
        try self.emitRelease(right_future);
        return join_state;
    }

    fn genSelect2Future(self: *Codegen, left_state: u32, right_state: u32) !u32 {
        const readiness = lowering_rules.select2Readiness(self.futureReadinessForState(left_state), self.futureReadinessForState(right_state));
        const left_future = try self.genFutureObjectForState(left_state);
        const right_future = try self.genFutureObjectForState(right_state);
        const select_state = try self.intern(try self.newTmp());
        try self.recordReg(select_state);
        try self.emitStdMacroFragment("sa_std/core/future.sa", "FUTURE_SELECT2_STATE_NEW", &.{
            self.symbols.items[select_state],
            self.symbols.items[left_future],
            self.symbols.items[right_future],
        });
        try self.future_state_vtables.put(select_state, "SLA_SELECT2_FUTURE_VT");
        try self.recordFutureReadiness(select_state, readiness);
        try self.emitRelease(left_future);
        try self.emitRelease(right_future);
        return select_state;
    }

    fn asyncSingleAwaitVTableName(self: *Codegen, name: []const u8) ![]const u8 {
        return try std.fmt.allocPrint(self.allocator, "SLA_ASYNC_{s}_VT", .{name});
    }

    fn asyncSingleAwaitPollName(self: *Codegen, name: []const u8) ![]const u8 {
        return try std.fmt.allocPrint(self.allocator, "sla_async_{s}_poll", .{name});
    }

    fn asyncTwoAwaitVTableName(self: *Codegen, name: []const u8) ![]const u8 {
        return try std.fmt.allocPrint(self.allocator, "SLA_ASYNC_{s}_TWO_AWAIT_VT", .{name});
    }

    fn asyncTwoAwaitPollName(self: *Codegen, name: []const u8) ![]const u8 {
        return try std.fmt.allocPrint(self.allocator, "sla_async_{s}_two_await_poll", .{name});
    }

    fn asyncJoin2AwaitVTableName(self: *Codegen, name: []const u8) ![]const u8 {
        return try std.fmt.allocPrint(self.allocator, "SLA_ASYNC_{s}_JOIN2_AWAIT_VT", .{name});
    }

    fn asyncJoin2AwaitPollName(self: *Codegen, name: []const u8) ![]const u8 {
        return try std.fmt.allocPrint(self.allocator, "sla_async_{s}_join2_await_poll", .{name});
    }

    fn asyncContinuationConditionOp(op: ast.BinaryOp) !inst.OpKind {
        return switch (op) {
            .eq => .eq,
            .ne => .ne,
            .lt => .slt,
            .le => .sle,
            .gt => .sgt,
            .ge => .sge,
            else => Error.UnsupportedSabDirectFeature,
        };
    }

    fn emitAsyncContinuationScalarValue(self: *Codegen, scalar: lowering_rules.AsyncContinuationScalarPlan, result: u32, awaited: u32, captured: [2]?u32) !void {
        var current: ?u32 = null;
        var awaited_abs: ?u32 = null;
        var awaited_scaled: ?u32 = null;
        var captured_abs: ?u32 = null;
        var captured_scaled: ?u32 = null;
        var expr_sum: ?u32 = null;
        var captured2_abs: ?u32 = null;
        var captured2_scaled: ?u32 = null;
        var expr_sum2: ?u32 = null;

        if (scalar.awaited_coeff != 0) {
            if (scalar.awaited_coeff == 1) {
                current = awaited;
            } else if (scalar.awaited_coeff == -1) {
                const scaled = try self.intern(try self.newTmp());
                try self.emitOp(scaled, .sub, .{ .imm_i64 = 0 }, .{ .reg = awaited });
                current = scaled;
                awaited_scaled = scaled;
            } else {
                const abs_coeff = if (scalar.awaited_coeff < 0) -scalar.awaited_coeff else scalar.awaited_coeff;
                const abs_reg = try self.intern(try self.newTmp());
                try self.emitOp(abs_reg, .mul, .{ .reg = awaited }, .{ .imm_i64 = abs_coeff });
                awaited_abs = abs_reg;
                if (scalar.awaited_coeff < 0) {
                    const scaled = try self.intern(try self.newTmp());
                    try self.emitOp(scaled, .sub, .{ .imm_i64 = 0 }, .{ .reg = abs_reg });
                    current = scaled;
                    awaited_scaled = scaled;
                } else {
                    current = abs_reg;
                }
            }
        }

        if (scalar.captured_coeff != 0) {
            const captured_reg = captured[0] orelse return Error.UnsupportedSabDirectFeature;
            var captured_term = captured_reg;
            const abs_coeff = if (scalar.captured_coeff < 0) -scalar.captured_coeff else scalar.captured_coeff;
            if (abs_coeff != 1) {
                const abs_reg = try self.intern(try self.newTmp());
                try self.emitOp(abs_reg, .mul, .{ .reg = captured_reg }, .{ .imm_i64 = abs_coeff });
                captured_term = abs_reg;
                captured_abs = abs_reg;
            }
            if (current) |cur| {
                const sum_dest = if (scalar.captured2_coeff == 0 and scalar.immediate == 0) result else try self.intern(try self.newTmp());
                if (scalar.captured_coeff < 0) {
                    try self.emitOp(sum_dest, .sub, .{ .reg = cur }, .{ .reg = captured_term });
                } else {
                    try self.emitOp(sum_dest, .add, .{ .reg = cur }, .{ .reg = captured_term });
                }
                current = sum_dest;
                if (scalar.captured2_coeff != 0 or scalar.immediate != 0) expr_sum = sum_dest;
            } else if (scalar.captured_coeff < 0) {
                const scaled = try self.intern(try self.newTmp());
                try self.emitOp(scaled, .sub, .{ .imm_i64 = 0 }, .{ .reg = captured_term });
                current = scaled;
                captured_scaled = scaled;
            } else {
                current = captured_term;
            }
        }

        if (scalar.captured2_coeff != 0) {
            const captured_reg = captured[1] orelse return Error.UnsupportedSabDirectFeature;
            var captured_term = captured_reg;
            const abs_coeff = if (scalar.captured2_coeff < 0) -scalar.captured2_coeff else scalar.captured2_coeff;
            if (abs_coeff != 1) {
                const abs_reg = try self.intern(try self.newTmp());
                try self.emitOp(abs_reg, .mul, .{ .reg = captured_reg }, .{ .imm_i64 = abs_coeff });
                captured_term = abs_reg;
                captured2_abs = abs_reg;
            }
            if (current) |cur| {
                const sum_dest = if (scalar.immediate == 0) result else try self.intern(try self.newTmp());
                if (scalar.captured2_coeff < 0) {
                    try self.emitOp(sum_dest, .sub, .{ .reg = cur }, .{ .reg = captured_term });
                } else {
                    try self.emitOp(sum_dest, .add, .{ .reg = cur }, .{ .reg = captured_term });
                }
                current = sum_dest;
                if (scalar.immediate != 0) expr_sum2 = sum_dest;
            } else if (scalar.captured2_coeff < 0) {
                const scaled = try self.intern(try self.newTmp());
                try self.emitOp(scaled, .sub, .{ .imm_i64 = 0 }, .{ .reg = captured_term });
                current = scaled;
                captured2_scaled = scaled;
            } else {
                current = captured_term;
            }
        }

        if (scalar.immediate != 0) {
            const cur = current orelse blk: {
                const zero = try self.intern(try self.newTmp());
                try self.emitAssignImm(zero, 0);
                expr_sum = zero;
                break :blk zero;
            };
            const abs_imm = if (scalar.immediate < 0) -scalar.immediate else scalar.immediate;
            if (scalar.immediate < 0) {
                try self.emitOp(result, .sub, .{ .reg = cur }, .{ .imm_i64 = abs_imm });
            } else {
                try self.emitOp(result, .add, .{ .reg = cur }, .{ .imm_i64 = abs_imm });
            }
            current = result;
        }

        if (current) |cur| {
            if (cur != result) try self.emitOp(result, .add, .{ .reg = cur }, .{ .imm_i64 = 0 });
        } else {
            try self.emitAssignImm(result, 0);
        }

        if (expr_sum) |reg| try self.emitRelease(reg);
        if (expr_sum2) |reg| try self.emitRelease(reg);
        if (captured2_scaled) |reg| try self.emitRelease(reg);
        if (captured2_abs) |reg| try self.emitRelease(reg);
        if (captured_scaled) |reg| try self.emitRelease(reg);
        if (captured_abs) |reg| try self.emitRelease(reg);
        if (awaited_scaled) |reg| try self.emitRelease(reg);
        if (awaited_abs) |reg| try self.emitRelease(reg);
    }

    fn emitAsyncSingleAwaitPollHelper(self: *Codegen, name: []const u8, plan: lowering_rules.AsyncSingleAwaitContinuationPlan) !void {
        const vt_name = try self.asyncSingleAwaitVTableName(name);
        const poll_name = try self.asyncSingleAwaitPollName(name);
        try self.appendVTableConst(vt_name, poll_name);

        const old_locals = self.locals.items.len;
        defer self.popLocalsTo(old_locals);
        self.beginFunction();

        const names = [_][]const u8{ "data_slot", "ctx_slot", "out_poll_slot" };
        const specs = try self.allocator.alloc(sig.ParamSpec, names.len);
        const ids = try self.allocator.alloc(u32, names.len);
        for (names, 0..) |param_name, i| {
            ids[i] = try self.intern(param_name);
            specs[i] = .{ .name = param_name, .ty = .ptr, .cap = .borrow };
            try self.pushRawParamLocal(param_name, ids[i], .borrow);
        }

        const fsig = try self.appendGeneratedFuncSig(poll_name, .normal, specs, ids, .void, false);
        const sig_idx = self.function_sigs.items.len;
        try self.function_sigs.append(fsig);
        try self.appendDeclInst(fsig);
        try self.emitLabel("L_ENTRY");

        const stage = try self.intern(try self.newTmp());
        const done = try self.intern(try self.newTmp());
        const empty_label = try self.newLabel("L_ASYNC_SINGLE_AWAIT_EMPTY");
        const poll_label = try self.newLabel("L_ASYNC_SINGLE_AWAIT_POLL");
        const ready_label = try self.newLabel("L_ASYNC_SINGLE_AWAIT_READY");
        const pending_label = try self.newLabel("L_ASYNC_SINGLE_AWAIT_PENDING");
        const clean_label = try self.newLabel("L_ASYNC_SINGLE_AWAIT_CLEAN");
        const done_label = try self.newLabel("L_ASYNC_SINGLE_AWAIT_DONE");
        try self.emitLoad(stage, ids[0], 0, .u64);
        try self.emitOp(done, .eq, .{ .reg = stage }, .{ .imm_i64 = 1 });
        try self.emitBranch(done, empty_label, poll_label);

        try self.emitLabel(empty_label);
        try self.emitStdMacroFragment("sa_std/core/future.sa", "POLL_SET_PENDING", &.{self.symbols.items[ids[2]]});
        try self.emitJmp(done_label);

        try self.emitLabel(poll_label);
        const inner_state = try self.intern(try self.newTmp());
        const inner_stage = try self.intern(try self.newTmp());
        const inner_initial = try self.intern(try self.newTmp());
        const check_ready_label = try self.newLabel("L_ASYNC_SINGLE_AWAIT_CHECK_READY");
        const empty_after_done_label = try self.newLabel("L_ASYNC_SINGLE_AWAIT_EMPTY_AFTER_DONE");
        try self.emitLoad(inner_state, ids[0], 8, .ptr);
        try self.emitLoad(inner_stage, inner_state, 0, .u64);
        try self.emitOp(inner_initial, .eq, .{ .reg = inner_stage }, .{ .imm_i64 = 0 });
        try self.emitBranch(inner_initial, pending_label, check_ready_label);

        try self.emitLabel(pending_label);
        const inner_stage_one = try self.intern(try self.newTmp());
        try self.emitAssignImm(inner_stage_one, 1);
        try self.emitStore(inner_state, 0, inner_stage_one, .u64);
        try self.emitStdMacroFragment("sa_std/core/future.sa", "POLL_SET_PENDING", &.{self.symbols.items[ids[2]]});
        try self.emitRelease(inner_stage_one);
        try self.emitJmp(clean_label);

        try self.emitLabel(check_ready_label);
        const inner_ready = try self.intern(try self.newTmp());
        try self.emitOp(inner_ready, .eq, .{ .reg = inner_stage }, .{ .imm_i64 = 1 });
        try self.emitBranch(inner_ready, ready_label, empty_after_done_label);

        try self.emitLabel(empty_after_done_label);
        try self.emitStdMacroFragment("sa_std/core/future.sa", "POLL_SET_PENDING", &.{self.symbols.items[ids[2]]});
        try self.emitRelease(inner_ready);
        try self.emitJmp(clean_label);

        try self.emitLabel(ready_label);
        const value = try self.intern(try self.newTmp());
        const scalar = plan.scalar;
        const result = if (plan.branch != null) try self.intern(try self.newTmp()) else if (plan.resultBindingName()) |binding_name| try self.intern(binding_name) else if (scalar.isIdentity()) value else try self.intern(try self.newTmp());
        var captured_addends: [2]?u32 = .{ null, null };
        var captured_storage: [2]?u32 = .{ null, null };
        const stage_one = try self.intern(try self.newTmp());
        const inner_stage_two = try self.intern(try self.newTmp());
        try self.emitLoad(value, inner_state, 8, .u64);
        for (0..plan.capture_count) |capture_idx| {
            const capture = plan.captures[capture_idx] orelse return Error.UnsupportedSabDirectFeature;
            const addend_reg = try self.intern(try self.newTmp());
            switch (capture.storage) {
                .scalar => {
                    try self.emitLoad(addend_reg, ids[0], capture.offset, .u64);
                    captured_addends[capture_idx] = addend_reg;
                },
                .copy_struct => {
                    if (plan.branch != null) return Error.UnsupportedSabDirectFeature;
                    const field_name = if (capture_idx == 0) scalar.captured_field_name else scalar.captured2_field_name;
                    const field = field_name orelse return Error.UnsupportedSabDirectFeature;
                    const capture_ty = self.tc.expr_types.get(capture.expr) orelse return Error.MissingType;
                    if (!self.typeIsCopyStruct(capture_ty)) return Error.UnsupportedSabDirectFeature;
                    const layout = try self.fieldLayout(capture_ty, field);
                    const ptr_reg = try self.intern(try self.newTmp());
                    try self.emitLoad(ptr_reg, ids[0], capture.offset, .ptr);
                    try self.emitLoad(addend_reg, ptr_reg, layout.offset, layout.ty);
                    captured_addends[capture_idx] = addend_reg;
                    captured_storage[capture_idx] = ptr_reg;
                },
            }
        }
        var branch_cond: ?u32 = null;
        if (plan.branch) |branch| {
            const then_label = try self.newLabel("L_ASYNC_SINGLE_AWAIT_BRANCH_THEN");
            const else_label = try self.newLabel("L_ASYNC_SINGLE_AWAIT_BRANCH_ELSE");
            const branch_done_label = try self.newLabel("L_ASYNC_SINGLE_AWAIT_BRANCH_DONE");
            const cond = try self.intern(try self.newTmp());
            try self.emitOp(cond, try asyncContinuationConditionOp(branch.condition_op), .{ .reg = value }, .{ .imm_i64 = branch.threshold });
            try self.emitBranch(cond, then_label, else_label);
            try self.emitLabel(then_label);
            try self.emitAsyncContinuationScalarValue(branch.then_scalar, result, value, captured_addends);
            try self.emitJmp(branch_done_label);
            try self.emitLabel(else_label);
            try self.emitAsyncContinuationScalarValue(branch.else_scalar, result, value, captured_addends);
            try self.emitJmp(branch_done_label);
            try self.emitLabel(branch_done_label);
            branch_cond = cond;
        } else {
            try self.emitAsyncContinuationScalarValue(scalar, result, value, captured_addends);
        }
        try self.emitAssignImm(inner_stage_two, 2);
        try self.emitStore(inner_state, 0, inner_stage_two, .u64);
        try self.emitAssignImm(stage_one, 1);
        try self.emitStore(ids[0], 0, stage_one, .u64);
        try self.emitStdMacroFragment("sa_std/core/future.sa", "POLL_SET_READY", &.{
            self.symbols.items[ids[2]],
            self.symbols.items[result],
        });
        try self.emitRelease(inner_stage_two);
        try self.emitRelease(stage_one);
        if (result != value) try self.emitRelease(result);
        if (branch_cond) |cond| try self.emitRelease(cond);
        for (captured_addends) |maybe_addend_reg| {
            if (maybe_addend_reg) |addend_reg| try self.emitRelease(addend_reg);
        }
        for (captured_storage) |maybe_storage_reg| {
            if (maybe_storage_reg) |storage_reg| try self.emitRelease(storage_reg);
        }
        try self.emitRelease(value);
        try self.emitRelease(inner_ready);

        try self.emitLabel(clean_label);
        try self.emitRelease(inner_initial);
        try self.emitRelease(inner_stage);
        try self.emitRelease(inner_state);

        try self.emitLabel(done_label);
        try self.emitRelease(done);
        try self.emitRelease(stage);
        for (ids) |id| try self.emitRelease(id);
        try self.emitReturn(null);

        try self.finishFunctionBody(sig_idx);
    }

    fn emitAsyncTwoAwaitPollHelper(self: *Codegen, name: []const u8, plan: lowering_rules.AsyncTwoAwaitContinuationPlan) !void {
        const vt_name = try self.asyncTwoAwaitVTableName(name);
        const poll_name = try self.asyncTwoAwaitPollName(name);
        try self.appendVTableConst(vt_name, poll_name);

        const old_locals = self.locals.items.len;
        defer self.popLocalsTo(old_locals);
        self.beginFunction();

        const names = [_][]const u8{ "data_slot", "ctx_slot", "out_poll_slot" };
        const specs = try self.allocator.alloc(sig.ParamSpec, names.len);
        const ids = try self.allocator.alloc(u32, names.len);
        for (names, 0..) |param_name, i| {
            ids[i] = try self.intern(param_name);
            specs[i] = .{ .name = param_name, .ty = .ptr, .cap = .borrow };
            try self.pushRawParamLocal(param_name, ids[i], .borrow);
        }

        const fsig = try self.appendGeneratedFuncSig(poll_name, .normal, specs, ids, .void, false);
        const sig_idx = self.function_sigs.items.len;
        try self.function_sigs.append(fsig);
        try self.appendDeclInst(fsig);
        try self.emitLabel("L_ENTRY");

        const stage = try self.intern(try self.newTmp());
        const done = try self.intern(try self.newTmp());
        const empty_label = try self.newLabel("L_ASYNC_TWO_AWAIT_EMPTY");
        const dispatch_label = try self.newLabel("L_ASYNC_TWO_AWAIT_DISPATCH");
        const first_label = try self.newLabel("L_ASYNC_TWO_AWAIT_FIRST");
        const second_dispatch_label = try self.newLabel("L_ASYNC_TWO_AWAIT_SECOND_DISPATCH");
        const second_label = try self.newLabel("L_ASYNC_TWO_AWAIT_SECOND");
        const done_label = try self.newLabel("L_ASYNC_TWO_AWAIT_DONE");
        try self.emitLoad(stage, ids[0], 0, .u64);
        try self.emitOp(done, .eq, .{ .reg = stage }, .{ .imm_i64 = 2 });
        try self.emitBranch(done, empty_label, dispatch_label);

        try self.emitLabel(empty_label);
        try self.emitStdMacroFragment("sa_std/core/future.sa", "POLL_SET_PENDING", &.{self.symbols.items[ids[2]]});
        try self.emitJmp(done_label);

        try self.emitLabel(dispatch_label);
        const poll_first = try self.intern(try self.newTmp());
        try self.emitOp(poll_first, .eq, .{ .reg = stage }, .{ .imm_i64 = 0 });
        try self.emitBranch(poll_first, first_label, second_dispatch_label);

        try self.emitLabel(second_dispatch_label);
        try self.emitJmp(second_label);

        try self.emitLabel(first_label);
        const first_state = try self.intern(try self.newTmp());
        const first_stage = try self.intern(try self.newTmp());
        const first_initial = try self.intern(try self.newTmp());
        const first_pending_label = try self.newLabel("L_ASYNC_TWO_AWAIT_FIRST_PENDING");
        const first_check_label = try self.newLabel("L_ASYNC_TWO_AWAIT_FIRST_CHECK_READY");
        const first_ready_label = try self.newLabel("L_ASYNC_TWO_AWAIT_FIRST_READY");
        const first_empty_label = try self.newLabel("L_ASYNC_TWO_AWAIT_FIRST_EMPTY");
        const first_clean_label = try self.newLabel("L_ASYNC_TWO_AWAIT_FIRST_CLEAN");
        try self.emitLoad(first_state, ids[0], 8, .ptr);
        try self.emitLoad(first_stage, first_state, 0, .u64);
        try self.emitOp(first_initial, .eq, .{ .reg = first_stage }, .{ .imm_i64 = 0 });
        try self.emitBranch(first_initial, first_pending_label, first_check_label);

        try self.emitLabel(first_pending_label);
        const first_stage_one = try self.intern(try self.newTmp());
        try self.emitAssignImm(first_stage_one, 1);
        try self.emitStore(first_state, 0, first_stage_one, .u64);
        try self.emitStdMacroFragment("sa_std/core/future.sa", "POLL_SET_PENDING", &.{self.symbols.items[ids[2]]});
        try self.emitRelease(first_stage_one);
        try self.emitJmp(first_clean_label);

        try self.emitLabel(first_check_label);
        const first_ready = try self.intern(try self.newTmp());
        try self.emitOp(first_ready, .eq, .{ .reg = first_stage }, .{ .imm_i64 = 1 });
        try self.emitBranch(first_ready, first_ready_label, first_empty_label);

        try self.emitLabel(first_empty_label);
        try self.emitStdMacroFragment("sa_std/core/future.sa", "POLL_SET_PENDING", &.{self.symbols.items[ids[2]]});
        try self.emitRelease(first_ready);
        try self.emitJmp(first_clean_label);

        try self.emitLabel(first_ready_label);
        const first_value = try self.intern(try self.newTmp());
        const first_stage_two = try self.intern(try self.newTmp());
        const outer_stage_one = try self.intern(try self.newTmp());
        try self.emitLoad(first_value, first_state, 8, .u64);
        try self.emitStore(ids[0], 24, first_value, .u64);
        try self.emitAssignImm(first_stage_two, 2);
        try self.emitStore(first_state, 0, first_stage_two, .u64);
        try self.emitAssignImm(outer_stage_one, 1);
        try self.emitStore(ids[0], 0, outer_stage_one, .u64);
        try self.emitRelease(outer_stage_one);
        try self.emitRelease(first_stage_two);
        try self.emitRelease(first_value);
        try self.emitRelease(first_ready);
        try self.emitRelease(first_initial);
        try self.emitRelease(first_stage);
        try self.emitRelease(first_state);
        try self.emitJmp(second_label);

        try self.emitLabel(first_clean_label);
        try self.emitRelease(first_initial);
        try self.emitRelease(first_stage);
        try self.emitRelease(first_state);
        try self.emitJmp(done_label);

        try self.emitLabel(second_label);
        const second_state = try self.intern(try self.newTmp());
        const second_stage = try self.intern(try self.newTmp());
        const second_initial = try self.intern(try self.newTmp());
        const second_pending_label = try self.newLabel("L_ASYNC_TWO_AWAIT_SECOND_PENDING");
        const second_check_label = try self.newLabel("L_ASYNC_TWO_AWAIT_SECOND_CHECK_READY");
        const second_ready_label = try self.newLabel("L_ASYNC_TWO_AWAIT_SECOND_READY");
        const second_empty_label = try self.newLabel("L_ASYNC_TWO_AWAIT_SECOND_EMPTY");
        const second_clean_label = try self.newLabel("L_ASYNC_TWO_AWAIT_SECOND_CLEAN");
        try self.emitLoad(second_state, ids[0], 16, .ptr);
        try self.emitLoad(second_stage, second_state, 0, .u64);
        try self.emitOp(second_initial, .eq, .{ .reg = second_stage }, .{ .imm_i64 = 0 });
        try self.emitBranch(second_initial, second_pending_label, second_check_label);

        try self.emitLabel(second_pending_label);
        const second_stage_one = try self.intern(try self.newTmp());
        try self.emitAssignImm(second_stage_one, 1);
        try self.emitStore(second_state, 0, second_stage_one, .u64);
        try self.emitStdMacroFragment("sa_std/core/future.sa", "POLL_SET_PENDING", &.{self.symbols.items[ids[2]]});
        try self.emitRelease(second_stage_one);
        try self.emitJmp(second_clean_label);

        try self.emitLabel(second_check_label);
        const second_ready = try self.intern(try self.newTmp());
        try self.emitOp(second_ready, .eq, .{ .reg = second_stage }, .{ .imm_i64 = 1 });
        try self.emitBranch(second_ready, second_ready_label, second_empty_label);

        try self.emitLabel(second_empty_label);
        try self.emitStdMacroFragment("sa_std/core/future.sa", "POLL_SET_PENDING", &.{self.symbols.items[ids[2]]});
        try self.emitRelease(second_ready);
        try self.emitJmp(second_clean_label);

        try self.emitLabel(second_ready_label);
        const saved_first = try self.intern(try self.newTmp());
        const second_value = try self.intern(try self.newTmp());
        const result = try self.intern(try self.newTmp());
        const second_stage_two = try self.intern(try self.newTmp());
        const outer_stage_two = try self.intern(try self.newTmp());
        try self.emitLoad(saved_first, ids[0], 24, .u64);
        try self.emitLoad(second_value, second_state, 8, .u64);
        const scalar = lowering_rules.AsyncContinuationScalarPlan{
            .awaited_coeff = plan.scalar.second_coeff,
            .captured_coeff = plan.scalar.first_coeff,
            .immediate = plan.scalar.immediate,
        };
        try self.emitAsyncContinuationScalarValue(scalar, result, second_value, .{ saved_first, null });
        try self.emitAssignImm(second_stage_two, 2);
        try self.emitStore(second_state, 0, second_stage_two, .u64);
        try self.emitAssignImm(outer_stage_two, 2);
        try self.emitStore(ids[0], 0, outer_stage_two, .u64);
        try self.emitStdMacroFragment("sa_std/core/future.sa", "POLL_SET_READY", &.{
            self.symbols.items[ids[2]],
            self.symbols.items[result],
        });
        try self.emitRelease(outer_stage_two);
        try self.emitRelease(second_stage_two);
        try self.emitRelease(result);
        try self.emitRelease(second_value);
        try self.emitRelease(saved_first);
        try self.emitRelease(second_ready);

        try self.emitLabel(second_clean_label);
        try self.emitRelease(second_initial);
        try self.emitRelease(second_stage);
        try self.emitRelease(second_state);

        try self.emitLabel(done_label);
        try self.emitRelease(done);
        try self.emitRelease(stage);
        for (ids) |id| try self.emitRelease(id);
        try self.emitReturn(null);

        try self.finishFunctionBody(sig_idx);
    }

    fn emitAsyncJoin2AwaitPollHelper(self: *Codegen, name: []const u8, plan: lowering_rules.AsyncJoin2AwaitContinuationPlan) !void {
        const vt_name = try self.asyncJoin2AwaitVTableName(name);
        const poll_name = try self.asyncJoin2AwaitPollName(name);
        try self.appendVTableConst(vt_name, poll_name);

        const old_locals = self.locals.items.len;
        defer self.popLocalsTo(old_locals);
        self.beginFunction();

        const names = [_][]const u8{ "data_slot", "ctx_slot", "out_poll_slot" };
        const specs = try self.allocator.alloc(sig.ParamSpec, names.len);
        const ids = try self.allocator.alloc(u32, names.len);
        for (names, 0..) |param_name, i| {
            ids[i] = try self.intern(param_name);
            specs[i] = .{ .name = param_name, .ty = .ptr, .cap = .borrow };
            try self.pushRawParamLocal(param_name, ids[i], .borrow);
        }

        const fsig = try self.appendGeneratedFuncSig(poll_name, .normal, specs, ids, .void, false);
        const sig_idx = self.function_sigs.items.len;
        try self.function_sigs.append(fsig);
        try self.appendDeclInst(fsig);
        try self.emitLabel("L_ENTRY");

        const stage = try self.intern(try self.newTmp());
        const done = try self.intern(try self.newTmp());
        const empty_label = try self.newLabel("L_ASYNC_JOIN2_AWAIT_EMPTY");
        const poll_label = try self.newLabel("L_ASYNC_JOIN2_AWAIT_POLL");
        const ready_label = try self.newLabel("L_ASYNC_JOIN2_AWAIT_READY");
        const pending_label = try self.newLabel("L_ASYNC_JOIN2_AWAIT_PENDING");
        const clean_label = try self.newLabel("L_ASYNC_JOIN2_AWAIT_CLEAN");
        const done_label = try self.newLabel("L_ASYNC_JOIN2_AWAIT_DONE");
        try self.emitLoad(stage, ids[0], 0, .u64);
        try self.emitOp(done, .eq, .{ .reg = stage }, .{ .imm_i64 = 1 });
        try self.emitBranch(done, empty_label, poll_label);

        try self.emitLabel(empty_label);
        try self.emitStdMacroFragment("sa_std/core/future.sa", "POLL_SET_PENDING", &.{self.symbols.items[ids[2]]});
        try self.emitJmp(done_label);

        try self.emitLabel(poll_label);
        const join_state = try self.intern(try self.newTmp());
        const join_vt = try self.intern(try self.newTmp());
        const join_future = try self.intern(try self.newTmp());
        const join_ctx = try self.intern(try self.newTmp());
        const join_poll = try self.intern(try self.newTmp());
        const join_ready = try self.intern(try self.newTmp());
        try self.emitLoad(join_state, ids[0], 8, .ptr);
        try self.emitBorrowSymbol(join_vt, "SLA_JOIN2_FUTURE_VT");
        try self.emitStdMacroFragment("sa_std/core/future.sa", "FUTURE_NEW", &.{
            self.symbols.items[join_future],
            self.symbols.items[join_state],
            self.symbols.items[join_vt],
        });
        try self.emitAssignImm(join_ctx, 0);
        try self.emitStdMacroFragment("sa_std/core/future.sa", "FUTURE_POLL", &.{
            self.symbols.items[join_poll],
            self.symbols.items[join_future],
            self.symbols.items[join_ctx],
        });
        try self.emitStdMacroFragment("sa_std/core/future.sa", "POLL_IS_READY", &.{
            self.symbols.items[join_ready],
            self.symbols.items[join_poll],
        });
        try self.emitBranch(join_ready, ready_label, pending_label);

        try self.emitLabel(pending_label);
        try self.emitStdMacroFragment("sa_std/core/future.sa", "POLL_SET_PENDING", &.{self.symbols.items[ids[2]]});
        try self.emitJmp(clean_label);

        try self.emitLabel(ready_label);
        const pair = try self.intern(plan.binding_name);
        const pair_left = try self.intern(try self.newTmp());
        const pair_right = try self.intern(try self.newTmp());
        const result = try self.intern(try self.newTmp());
        const stage_done = try self.intern(try self.newTmp());
        try self.emitLoad(pair, join_poll, 8, .ptr);
        try self.emitStdMacroFragment("sa_std/core/future.sa", "FUTURE_PAIR_LEFT", &.{
            self.symbols.items[pair_left],
            self.symbols.items[pair],
        });
        try self.emitStdMacroFragment("sa_std/core/future.sa", "FUTURE_PAIR_RIGHT", &.{
            self.symbols.items[pair_right],
            self.symbols.items[pair],
        });
        const scalar = lowering_rules.AsyncContinuationScalarPlan{
            .awaited_coeff = plan.scalar.right_coeff,
            .captured_coeff = plan.scalar.left_coeff,
            .immediate = plan.scalar.immediate,
        };
        try self.emitAsyncContinuationScalarValue(scalar, result, pair_right, .{ pair_left, null });
        try self.emitAssignImm(stage_done, 1);
        try self.emitStore(ids[0], 0, stage_done, .u64);
        try self.emitStdMacroFragment("sa_std/core/future.sa", "POLL_SET_READY", &.{
            self.symbols.items[ids[2]],
            self.symbols.items[result],
        });
        try self.emitRelease(stage_done);
        try self.emitRelease(result);
        try self.emitRelease(pair_right);
        try self.emitRelease(pair_left);
        try self.emitRelease(pair);

        try self.emitLabel(clean_label);
        try self.emitRelease(join_ready);
        try self.emitRelease(join_poll);
        try self.emitRelease(join_ctx);
        try self.emitRelease(join_future);
        try self.emitRelease(join_vt);
        try self.emitRelease(join_state);

        try self.emitLabel(done_label);
        try self.emitRelease(done);
        try self.emitRelease(stage);
        for (ids) |id| try self.emitRelease(id);
        try self.emitReturn(null);

        try self.finishFunctionBody(sig_idx);
    }

    fn genReadyPoll(self: *Codegen, value: u32) !u32 {
        const poll = try self.intern(try self.newTmp());
        try self.recordReg(poll);
        try self.emitStdMacroFragment("sa_std/core/future.sa", "POLL_READY", &.{
            self.symbols.items[poll],
            self.symbols.items[value],
        });
        return poll;
    }

    fn genPendingPoll(self: *Codegen) !u32 {
        const poll = try self.intern(try self.newTmp());
        try self.recordReg(poll);
        try self.emitStdMacroFragment("sa_std/core/future.sa", "POLL_PENDING", &.{
            self.symbols.items[poll],
        });
        return poll;
    }

    fn genPollRuntimeCall(self: *Codegen, call: ast.CallExpr) anyerror!?u32 {
        const plan = lowering_rules.planPollRuntimeCall(call) orelse return null;
        return switch (plan.kind) {
            .ready => blk: {
                if (call.args.len != 1 or call.generics.len != 0) return Error.UnsupportedSabDirectFeature;
                const value_reg = try self.genExpr(call.args[0]);
                break :blk try self.genReadyPoll(value_reg);
            },
            .pending => blk: {
                if (call.args.len != 0 or call.generics.len != 1) return Error.UnsupportedSabDirectFeature;
                break :blk try self.genPendingPoll();
            },
            .is_ready, .is_pending => blk: {
                if (call.args.len != 1 or call.generics.len != 0) return Error.UnsupportedSabDirectFeature;
                const poll_reg = try self.genExpr(call.args[0]);
                const out_reg = try self.intern(try self.newTmp());
                const macro_name = if (plan.kind == .is_ready) "POLL_IS_READY" else "POLL_IS_PENDING";
                try self.emitStdMacroFragment("sa_std/core/future.sa", macro_name, &.{
                    self.symbols.items[out_reg],
                    self.symbols.items[poll_reg],
                });
                if (!self.isLocalReg(poll_reg)) try self.emitRelease(poll_reg);
                break :blk out_reg;
            },
            .value => blk: {
                if (call.args.len != 1 or call.generics.len != 0) return Error.UnsupportedSabDirectFeature;
                const poll_reg = try self.genExpr(call.args[0]);
                const value_reg = try self.intern(try self.newTmp());
                try self.emitStdMacroFragment("sa_std/core/future.sa", "POLL_VALUE", &.{
                    self.symbols.items[value_reg],
                    self.symbols.items[poll_reg],
                });
                if (!self.isLocalReg(poll_reg)) try self.emitRelease(poll_reg);
                break :blk value_reg;
            },
        };
    }

    fn genExecutorRuntimeCall(self: *Codegen, call: ast.CallExpr) anyerror!?u32 {
        const plan = lowering_rules.planExecutorRuntimeCall(call) orelse return null;
        return switch (plan.kind) {
            .new => blk: {
                if (call.args.len != 1 or call.generics.len != 0) return Error.UnsupportedSabDirectFeature;
                const tasks_ty = self.tc.expr_types.get(call.args[0]) orelse return Error.MissingType;
                const tasks_plan = lowering_rules.executorTaskBufferPlan(tasks_ty) orelse return Error.UnsupportedSabDirectFeature;
                const tasks_owner_reg = try self.genExpr(call.args[0]);
                var tasks_ptr_reg: u32 = tasks_owner_reg;
                var release_tasks_ptr = false;
                const len_reg = try self.intern(try self.newTmp());
                const executor_reg = try self.intern(try self.newTmp());
                switch (tasks_plan.kind) {
                    .fixed_array => try self.emitAssignImm(len_reg, @as(i64, @intCast(tasks_plan.fixed_len.?))),
                    .vec => {
                        try self.ensureStdDeps("sa_std/vec.sa", &.{"sa_vec_len"});
                        tasks_ptr_reg = try self.intern(try self.newTmp());
                        release_tasks_ptr = true;
                        try self.emitStdMacroFragment("sa_std/vec.sa", "VEC_AS_PTR", &.{
                            self.symbols.items[tasks_ptr_reg],
                            self.symbols.items[tasks_owner_reg],
                        });
                        try self.emitStdMacroFragment("sa_std/vec.sa", "VEC_LEN", &.{
                            self.symbols.items[len_reg],
                            self.symbols.items[tasks_owner_reg],
                        });
                    },
                }
                try self.emitStdMacroFragment("sa_std/core/task.sa", "EXECUTOR_NEW", &.{
                    self.symbols.items[executor_reg],
                    self.symbols.items[tasks_ptr_reg],
                    self.symbols.items[len_reg],
                });
                try self.emitRelease(len_reg);
                if (release_tasks_ptr) try self.emitRelease(tasks_ptr_reg);
                break :blk executor_reg;
            },
            .poll_one => blk: {
                if (call.args.len != 2 or call.generics.len != 0) return Error.UnsupportedSabDirectFeature;
                const executor_reg = try self.genExpr(call.args[0]);
                const index_reg = try self.genExpr(call.args[1]);
                const poll_reg = try self.intern(try self.newTmp());
                const tag_reg = try self.intern(try self.newTmp());
                const ready_reg = try self.intern(try self.newTmp());
                try self.emitStdMacroFragment("sa_std/core/task.sa", "EXECUTOR_POLL_ONE", &.{
                    self.symbols.items[poll_reg],
                    self.symbols.items[executor_reg],
                    self.symbols.items[index_reg],
                });
                try self.emitLoad(tag_reg, poll_reg, 0, .u64);
                try self.emitOp(ready_reg, .eq, .{ .reg = tag_reg }, .{ .imm_i64 = 1 });
                try self.emitRelease(tag_reg);
                try self.emitRelease(poll_reg);
                if (!self.isLocalReg(index_reg)) try self.emitRelease(index_reg);
                if (!self.isLocalReg(executor_reg)) try self.emitRelease(executor_reg);
                break :blk ready_reg;
            },
            .poll_ready_count => blk: {
                if (call.args.len != 1 or call.generics.len != 0) return Error.UnsupportedSabDirectFeature;
                const executor_reg = try self.genExpr(call.args[0]);
                const count_reg = try self.intern(try self.newTmp());
                try self.emitStdMacroFragment("sa_std/core/task.sa", "EXECUTOR_POLL_READY_COUNT", &.{
                    self.symbols.items[count_reg],
                    self.symbols.items[executor_reg],
                });
                if (!self.isLocalReg(executor_reg)) try self.emitRelease(executor_reg);
                break :blk count_reg;
            },
        };
    }

    fn genFutureTaskCall(self: *Codegen, call: ast.CallExpr) anyerror!?u32 {
        if (try self.genPollRuntimeCall(call)) |poll_reg| return poll_reg;

        if (try self.genExecutorRuntimeCall(call)) |executor_reg| return executor_reg;

        if (lowering_rules.planFutureRuntimeCall(call)) |future_plan| {
            return switch (future_plan.kind) {
                .ready => blk: {
                    if (call.args.len != 1) return Error.UnsupportedSabDirectFeature;
                    const value_reg = try self.genExpr(call.args[0]);
                    break :blk try self.genReadyFuture(value_reg);
                },
                .pending => blk: {
                    if (call.args.len != 0 or call.generics.len != 1) return Error.UnsupportedSabDirectFeature;
                    break :blk try self.genPendingFuture();
                },
                .defer_ready => blk: {
                    if (call.args.len != 1 or call.generics.len != 0) return Error.UnsupportedSabDirectFeature;
                    const value_reg = try self.genExpr(call.args[0]);
                    break :blk try self.genDeferReadyFuture(value_reg);
                },
                .join2 => blk: {
                    if (call.args.len != 2 or call.generics.len != 0) return Error.UnsupportedSabDirectFeature;
                    const left_state = try self.genExpr(call.args[0]);
                    const right_state = try self.genExpr(call.args[1]);
                    break :blk try self.genJoin2Future(left_state, right_state);
                },
                .select2 => blk: {
                    if (call.args.len != 2 or call.generics.len != 0) return Error.UnsupportedSabDirectFeature;
                    const left_state = try self.genExpr(call.args[0]);
                    const right_state = try self.genExpr(call.args[1]);
                    break :blk try self.genSelect2Future(left_state, right_state);
                },
                .pair_left, .pair_right => blk: {
                    if (call.args.len != 1 or call.generics.len != 0) return Error.UnsupportedSabDirectFeature;
                    const pair_reg = try self.genExpr(call.args[0]);
                    const value_reg = try self.intern(try self.newTmp());
                    const macro_name = if (future_plan.kind == .pair_left) "FUTURE_PAIR_LEFT" else "FUTURE_PAIR_RIGHT";
                    try self.emitStdMacroFragment("sa_std/core/future.sa", macro_name, &.{
                        self.symbols.items[value_reg],
                        self.symbols.items[pair_reg],
                    });
                    try self.releaseExprResultIfNeeded(call.args[0], pair_reg);
                    break :blk value_reg;
                },
                .either_side, .either_left, .either_right => blk: {
                    if (call.args.len != 1 or call.generics.len != 0) return Error.UnsupportedSabDirectFeature;
                    const either_reg = try self.genExpr(call.args[0]);
                    const value_reg = try self.intern(try self.newTmp());
                    const macro_name = switch (future_plan.kind) {
                        .either_side => "FUTURE_EITHER_SIDE",
                        .either_left => "FUTURE_EITHER_LEFT_VALUE",
                        .either_right => "FUTURE_EITHER_RIGHT_VALUE",
                        else => unreachable,
                    };
                    try self.emitStdMacroFragment("sa_std/core/future.sa", macro_name, &.{
                        self.symbols.items[value_reg],
                        self.symbols.items[either_reg],
                    });
                    try self.releaseExprResultIfNeeded(call.args[0], either_reg);
                    break :blk value_reg;
                },
            };
        }

        const target = call.associated_target orelse return null;
        if (!std.mem.eql(u8, target, "task")) return null;

        if (std.mem.eql(u8, call.func_name, "new")) {
            if (call.args.len != 1) return Error.UnsupportedSabDirectFeature;
            const state_reg = try self.genExpr(call.args[0]);
            const ctx = try self.intern(try self.newTmp());
            const task = try self.intern(try self.newTmp());
            const future_obj = try self.genFutureObjectForState(state_reg);
            try self.emitAssignImm(ctx, 0);
            try self.emitStdMacroFragment("sa_std/core/task.sa", "TASK_NEW", &.{
                self.symbols.items[task],
                self.symbols.items[future_obj],
                self.symbols.items[ctx],
            });
            try self.emitRelease(ctx);
            try self.emitRelease(future_obj);
            return task;
        }

        if (std.mem.eql(u8, call.func_name, "poll")) {
            if (call.args.len != 1) return Error.UnsupportedSabDirectFeature;
            const task_reg = try self.genExpr(call.args[0]);
            const poll_reg = try self.intern(try self.newTmp());
            const tag_reg = try self.intern(try self.newTmp());
            const ready_reg = try self.intern(try self.newTmp());
            try self.emitStdMacroFragment("sa_std/core/task.sa", "TASK_POLL", &.{
                self.symbols.items[poll_reg],
                self.symbols.items[task_reg],
            });
            try self.emitLoad(tag_reg, poll_reg, 0, .u64);
            try self.emitOp(ready_reg, .eq, .{ .reg = tag_reg }, .{ .imm_i64 = 1 });
            try self.emitRelease(tag_reg);
            try self.emitRelease(poll_reg);
            if (!self.isLocalReg(task_reg)) try self.emitRelease(task_reg);
            return ready_reg;
        }

        if (std.mem.eql(u8, call.func_name, "is_ready")) {
            if (call.args.len != 1) return Error.UnsupportedSabDirectFeature;
            const task_reg = try self.genExpr(call.args[0]);
            const ready_reg = try self.intern(try self.newTmp());
            try self.emitStdMacroFragment("sa_std/core/task.sa", "TASK_IS_READY", &.{
                self.symbols.items[ready_reg],
                self.symbols.items[task_reg],
            });
            if (!self.isLocalReg(task_reg)) try self.emitRelease(task_reg);
            return ready_reg;
        }

        if (std.mem.eql(u8, call.func_name, "result")) {
            if (call.args.len != 1) return Error.UnsupportedSabDirectFeature;
            const task_reg = try self.genExpr(call.args[0]);
            const value_reg = try self.intern(try self.newTmp());
            try self.emitStdMacroFragment("sa_std/core/task.sa", "TASK_RESULT", &.{
                self.symbols.items[value_reg],
                self.symbols.items[task_reg],
            });
            if (!self.isLocalReg(task_reg)) try self.emitRelease(task_reg);
            return value_reg;
        }

        if (std.mem.eql(u8, call.func_name, "state")) {
            if (call.args.len != 1) return Error.UnsupportedSabDirectFeature;
            const task_reg = try self.genExpr(call.args[0]);
            const state_reg = try self.intern(try self.newTmp());
            try self.emitStdMacroFragment("sa_std/core/task.sa", "TASK_STATE", &.{
                self.symbols.items[state_reg],
                self.symbols.items[task_reg],
            });
            if (!self.isLocalReg(task_reg)) try self.emitRelease(task_reg);
            return state_reg;
        }

        return null;
    }

    fn genAwait(self: *Codegen, expr: *const ast.Node, aw: ast.AwaitExpr) !u32 {
        const future_ty = self.tc.expr_types.get(aw.expr) orelse return Error.MissingType;
        const plan = lowering_rules.planAwaitFutureWithReadiness(aw.expr, future_ty, self.current_async_return_ty, &self.future_readiness_by_name);
        _ = expr;
        const future = try self.genExpr(aw.expr);
        if (self.current_async_return and plan.pending_return_if_async) {
            try self.releaseOpenLocals(future);
            try self.emitReturn(future);
            return future;
        }
        if (plan.poll_once_if_statically_ready) {
            const future_obj = try self.genFutureObjectForState(future);
            const ctx = try self.intern(try self.newTmp());
            const poll = try self.intern(try self.newTmp());
            const out = try self.intern(try self.newTmp());
            try self.recordReg(out);
            try self.emitAssignImm(ctx, 0);
            try self.emitStdMacroFragment("sa_std/core/future.sa", "FUTURE_POLL", &.{
                self.symbols.items[poll],
                self.symbols.items[future_obj],
                self.symbols.items[ctx],
            });
            try self.emitStdMacroFragment("sa_std/core/future.sa", "POLL_VALUE", &.{
                self.symbols.items[out],
                self.symbols.items[poll],
            });
            try self.emitRelease(poll);
            try self.emitRelease(ctx);
            try self.emitRelease(future_obj);
            return out;
        }
        if (self.current_async_return and plan.ready_pending_state_return_if_async) {
            const state = try self.intern(try self.newTmp());
            const zero = try self.intern(try self.newTmp());
            const is_pending = try self.intern(try self.newTmp());
            const pending_label = try self.newLabel("L_AWAIT_PENDING");
            const ready_label = try self.newLabel("L_AWAIT_READY");
            try self.emitLoad(state, future, 0, .u64);
            try self.emitAssignImm(zero, 0);
            try self.emitOp(is_pending, .eq, .{ .reg = state }, .{ .reg = zero });
            try self.emitBranch(is_pending, pending_label, ready_label);

            try self.emitLabel(pending_label);
            try self.releaseOpenLocals(future);
            try self.emitReturn(future);

            try self.emitLabel(ready_label);
            try self.emitBranchRelease(is_pending);
            try self.emitBranchRelease(zero);
            try self.emitBranchRelease(state);
            const out = try self.intern(try self.newTmp());
            try self.recordReg(out);
            try self.emitStdMacroFragment("sa_std/core/future.sa", "FUTURE_READY_STATE_INTO_INNER", &.{
                self.symbols.items[out],
                self.symbols.items[future],
            });
            if (!self.isLocalReg(future)) try self.emitRelease(future);
            return out;
        }
        if (!plan.ready_state_inner) return Error.UnsupportedSabDirectFeature;
        const out = try self.intern(try self.newTmp());
        try self.recordReg(out);
        try self.emitStdMacroFragment("sa_std/core/future.sa", "FUTURE_READY_STATE_INTO_INNER", &.{
            self.symbols.items[out],
            self.symbols.items[future],
        });
        if (!self.isLocalReg(future)) try self.emitRelease(future);
        return out;
    }

    fn assignToIdentifier(self: *Codegen, name: []const u8, value: u32) anyerror!void {
        if (self.stackLocal(name)) |slot| {
            const ty = slot.stack_ty orelse return Error.UnsupportedSabDirectFeature;
            try self.emitStore(slot.reg, 0, value, try storagePrimType(ty));
            if (!self.isLocalReg(value)) {
                if (typeIsPointerScalarValue(ty)) try self.markNonOwningReg(value);
                try self.emitRelease(value);
            }
            return;
        }

        const dst = self.localReg(name) orelse try self.intern(name);
        if (dst != value and !self.released_regs.contains(dst)) try self.emitRelease(dst);
        try self.emitAssignReg(dst, value);
    }

    fn markAssignmentMovedSource(self: *Codegen, target: *const ast.Node, value: *const ast.Node) anyerror!void {
        if (value.* != .identifier) return;
        const source_name = value.identifier;
        const value_ty = self.localType(source_name) orelse (try self.exprTypeOrFallback(value)) orelse return Error.MissingType;
        try self.markAssignmentMovedSourceWithType(target, value, value_ty);
    }

    fn markAssignmentMovedSourceWithType(self: *Codegen, target: *const ast.Node, value: *const ast.Node, stored_ty: *const ast.Type) anyerror!void {
        if (value.* != .identifier) return;
        const moved_name = lowering_rules.assignmentMovesIdentifier(target, value, stored_ty, self.typeIsCopyValue(stored_ty)) orelse return;
        const source_reg = self.localReg(moved_name) orelse return;
        try self.emitAssignmentMove(source_reg);
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
            if (binding.evaluated_reg) |reg| return reg;
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

    fn astTypeForAbiRaw(self: *Codegen, raw: []const u8) !*const ast.Type {
        return switch (abiPrimType(raw)) {
            .i1 => try self.makePrimitiveType(.boolean),
            .i8 => try self.makePrimitiveType(.i8),
            .i16 => try self.makePrimitiveType(.i16),
            .i32 => try self.makePrimitiveType(.i32),
            .i64 => try self.makePrimitiveType(.i64),
            .u8 => try self.makePrimitiveType(.u8),
            .u16 => try self.makePrimitiveType(.u16),
            .u32 => try self.makePrimitiveType(.u32),
            .u64 => try self.makePrimitiveType(.u64),
            .f32 => try self.makePrimitiveType(.f32),
            .f64 => try self.makePrimitiveType(.f64),
            .ptr, .void => try self.makePrimitiveType(.void_type),
            else => try self.makePrimitiveType(.void_type),
        };
    }

    fn makePointerType(self: *Codegen) !*const ast.Type {
        const inner = try self.allocator.create(ast.Type);
        inner.* = .{ .primitive = .void_type };
        const ty = try self.allocator.create(ast.Type);
        ty.* = .{ .pointer = inner };
        return ty;
    }

    fn makeSliceType(self: *Codegen, elem_ty: *ast.Type) !*const ast.Type {
        const generics = try self.allocator.alloc(*ast.Type, 1);
        generics[0] = elem_ty;
        const ty = try self.allocator.create(ast.Type);
        ty.* = .{ .user_defined = .{ .name = "Slice", .generics = generics } };
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
                    else => if (lowering_rules.smartPointerDerefType(source_ty)) |smart| smart.inner else null,
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
        var source = try self.addressWithOffset(base, layout.offset);
        if (layout.offset != 0 and !self.isLocalReg(base)) source.release_regs = try self.singleReleaseReg(base);
        return source;
    }

    fn genMacroIndexAddress(self: *Codegen, idx: ast.IndexExpr, ctx: *MacroExpansionContext) anyerror!AddressSource {
        const target_ty = (try self.macroExprType(idx.target, ctx)) orelse return Error.MissingType;
        const addressable_target_ty = lowering_rules.ordinaryIndexAddressTargetType(target_ty) orelse return Error.UnsupportedSabDirectFeature;
        if (addressable_target_ty.* != .array) return Error.UnsupportedSabDirectFeature;
        const target_reg = try self.genMacroExpr(idx.target, ctx);
        if (idx.index.* == .literal and idx.index.literal == .int_val) {
            const raw_index = idx.index.literal.int_val;
            if (raw_index < 0) return Error.UnsupportedSabDirectFeature;
            const layout = arrayElementLayout(addressable_target_ty.array, @intCast(raw_index)) orelse return Error.UnsupportedSabDirectFeature;
            var source = try self.addressWithOffset(target_reg, layout.offset);
            if (layout.offset != 0 and !self.isLocalReg(target_reg)) source.release_regs = try self.singleReleaseReg(target_reg);
            return source;
        }

        const index_reg = try self.genMacroExpr(idx.index, ctx);
        const elem_ptr = try self.genArrayElementPtr(addressable_target_ty.array, target_reg, index_reg);
        if (elem_ptr.offset) |offset| try self.emitRelease(offset);
        if (!self.isLocalReg(index_reg)) try self.emitRelease(index_reg);
        return .{
            .reg = elem_ptr.ptr,
            .release_regs = if (!self.isLocalReg(target_reg)) try self.singleReleaseReg(target_reg) else &.{},
        };
    }

    fn genMacroIdentifierAddress(self: *Codegen, name: []const u8, ctx: *MacroExpansionContext) anyerror!AddressSource {
        if (macroIdentifierName(ctx, name)) |mapped| {
            if (self.stackLocal(mapped)) |slot| return .{ .reg = slot.reg };
            return .{ .reg = try self.genIdentifierByName(mapped) };
        }
        if (macroArgBinding(ctx, name)) |binding| {
            if (binding.ctx) |arg_ctx| return try self.genMacroAddressOf(@constCast(binding.arg), arg_ctx);
            return try self.genAddressOf(@constCast(binding.arg));
        }
        if (self.stackLocal(name)) |slot| return .{ .reg = slot.reg };
        return .{ .reg = try self.genIdentifierByName(name) };
    }

    fn genMacroAddressOf(self: *Codegen, expr: *ast.Node, ctx: *MacroExpansionContext) anyerror!AddressSource {
        var deref_source_ty: ?*const ast.Type = null;
        var index_target_ty: ?*const ast.Type = null;
        switch (expr.*) {
            .deref_expr => |deref| deref_source_ty = (try self.macroExprType(deref.expr, ctx)) orelse return Error.MissingType,
            .index_expr => |idx| index_target_ty = (try self.macroExprType(idx.target, ctx)) orelse return Error.MissingType,
            else => {},
        }
        const address_plan = lowering_rules.planAddressOf(expr, .{
            .deref_source_ty = deref_source_ty,
            .index_target_ty = index_target_ty,
        });
        return switch (address_plan.shape) {
            .identifier => blk: {
                if (expr.* != .identifier) return Error.UnsupportedSabDirectFeature;
                break :blk try self.genMacroIdentifierAddress(expr.identifier, ctx);
            },
            .deref_borrow_or_pointer => .{ .reg = try self.genMacroExpr(expr.deref_expr.expr, ctx) },
            .deref_smart_pointer => blk: {
                const source_ty = deref_source_ty orelse return Error.MissingType;
                const source = try self.genMacroExpr(expr.deref_expr.expr, ctx);
                break :blk try self.genDerefAddressFallback(source_ty, source);
            },
            .field => blk: {
                if (expr.* != .field_expr) return Error.UnsupportedSabDirectFeature;
                break :blk try self.genMacroFieldAddress(expr.field_expr, ctx);
            },
            .index => blk: {
                if (expr.* != .index_expr) return Error.UnsupportedSabDirectFeature;
                break :blk try self.genMacroIndexAddress(expr.index_expr, ctx);
            },
            .value_temp => blk: {
                if (expr.* == .deref_expr) {
                    const source_ty = deref_source_ty orelse return Error.MissingType;
                    const source = try self.genMacroExpr(expr.deref_expr.expr, ctx);
                    break :blk try self.genDerefAddressFallback(source_ty, source);
                }
                break :blk .{ .reg = try self.genMacroExpr(expr, ctx) };
            },
        };
    }

    fn genMacroBorrow(self: *Codegen, borrow: ast.BorrowExpr, ctx: *MacroExpansionContext) anyerror!u32 {
        const source = try self.genMacroAddressOf(borrow.expr, ctx);
        const dst = try self.intern(try self.newTmp());
        try self.emitBorrowReg(dst, source.reg, "read");
        try self.rememberBorrowAddressTemps(dst, source);
        return dst;
    }

    fn genMacroDeref(self: *Codegen, expr: *const ast.Node, deref: ast.DerefExpr, ctx: *MacroExpansionContext) anyerror!u32 {
        const deref_ty = (try self.macroExprType(expr, ctx)) orelse return Error.MissingType;
        const source_ty = (try self.macroExprType(deref.expr, ctx)) orelse return Error.MissingType;
        const source = try self.genMacroExpr(deref.expr, ctx);
        if (try self.genSmartPointerGet(source_ty, source)) |value| {
            if (value != source and !self.isLocalReg(source)) try self.emitRelease(source);
            return value;
        }
        const dst = try self.intern(try self.newTmp());
        try self.emitLoad(dst, source, 0, try primType(deref_ty));
        if (!self.isLocalReg(source)) try self.emitRelease(source);
        return dst;
    }

    fn genMacroMove(self: *Codegen, move: ast.MoveExpr, ctx: *MacroExpansionContext) anyerror!u32 {
        const source = try self.genMacroExpr(move.expr, ctx);
        try self.markConsumed(source);
        return source;
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
        try self.releaseExprResultIfNeeded(bin.left, lhs);
        try self.releaseExprResultIfNeeded(bin.right, rhs);
        return dst;
    }

    fn genMacroCast(self: *Codegen, cast: ast.CastExpr, ctx: *MacroExpansionContext) anyerror!u32 {
        const src_ast_ty = (try self.macroExprType(cast.expr, ctx)) orelse return Error.MissingType;
        const src_ty = try primType(src_ast_ty);
        const dst_ty = try primType(cast.ty);
        const src = try self.genMacroExpr(cast.expr, ctx);

        if (!isNumericType(src_ast_ty) or !isNumericType(cast.ty)) {
            if (src_ty == .ptr and dst_ty == .ptr) {
                const dst = try self.intern(try self.newTmp());
                try self.recordReg(dst);
                var item = self.makeInst(.op);
                item.op_kind = .bitcast;
                item.operands[0] = .{ .reg = dst };
                item.operands[1] = .{ .reg = src };
                item.operands[2] = .{ .ty = @intFromEnum(dst_ty) };
                try self.appendInst(item);
                if (!self.isLocalReg(src)) try self.emitRelease(src);
                return dst;
            }
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
            try self.markLoadedFieldViewIfNeeded(dst, expr_ty.tuple.elems[index]);
            if (!self.isLocalReg(base)) try self.emitRelease(base);
            return dst;
        }
        const layout = try self.fieldLayout(expr_ty, field.field_name);
        const field_ty = self.fieldType(expr_ty, field.field_name) orelse return Error.UnsupportedSabDirectFeature;

        const base = try self.genMacroExpr(field.expr, ctx);
        const dst = try self.intern(try self.newTmp());
        try self.emitLoad(dst, base, layout.offset, layout.ty);
        try self.markLoadedFieldViewIfNeeded(dst, field_ty);
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
        const decl = self.structDeclForType(lit.ty) orelse return Error.UnsupportedSabDirectFeature;
        if (decl.is_opaque or decl.is_union) return Error.UnsupportedSabDirectFeature;

        const dst = try self.intern(try self.newTmp());
        try self.emitAlloc(dst, structSize(decl));

        const update_expr = lit.update_expr;
        var update_reg: ?u32 = null;
        if (update_expr) |expr| {
            update_reg = try self.genMacroExpr(expr, ctx);
        }
        defer {
            if (update_reg) |reg| {
                self.releaseExprResultIfNeeded(update_expr.?, reg) catch {};
            }
        }

        const plans = try self.structLiteralFieldPlans(decl, &lit);
        defer self.allocator.free(plans);
        for (plans) |plan| {
            const layout = plan.layout;
            const prim = storagePrimType(layout.ty) catch return Error.UnsupportedSabDirectFeature;
            const transfer = lowering_rules.planStructLiteralFieldTransfer(plan, self.typeIsCopyStruct(plan.field_ty));
            switch (plan.source) {
                .explicit => {
                    const value = plan.value orelse return Error.UnsupportedSabDirectFeature;
                    switch (transfer) {
                        .deep_copy => {
                            const source_reg = try self.genMacroExpr(value, ctx);
                            const copied = try self.genCopyValue(source_reg, plan.field_ty);
                            try self.emitStore(dst, layout.offset, copied, prim);
                            try self.emitRelease(copied);
                        },
                        .direct, .move => {
                            const value_reg = try self.genMacroExpr(value, ctx);
                            if (transfer == .move) {
                                try self.emitStore(dst, layout.offset, value_reg, prim);
                                try self.emitConsumedMarker(value_reg);
                                try self.consumeStoredMoveValue(value, value_reg, plan.field_ty);
                            } else {
                                try self.emitStore(dst, layout.offset, value_reg, prim);
                                try self.releaseStoredExprResultIfNeeded(value, value_reg, plan.field_ty);
                            }
                        },
                    }
                },
                .update => {
                    const src = update_reg orelse return Error.UnsupportedSabDirectFeature;
                    const loaded = try self.intern(try self.newTmp());
                    try self.emitLoad(loaded, src, layout.offset, prim);
                    switch (transfer) {
                        .direct => {
                            try self.emitStore(dst, layout.offset, loaded, prim);
                            if (plan.release_loaded and !self.isLocalReg(loaded)) try self.emitRelease(loaded);
                        },
                        .deep_copy => {
                            const copied = try self.genCopyValue(loaded, plan.field_ty);
                            try self.emitStore(dst, layout.offset, copied, prim);
                            try self.emitRelease(copied);
                            if (plan.release_loaded and !self.isLocalReg(loaded)) try self.emitRelease(loaded);
                        },
                        .move => {
                            try self.emitStore(dst, layout.offset, loaded, prim);
                        },
                    }
                },
            }
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
            try self.releaseStoredExprResultIfNeeded(elem, value, elem_tys[idx]);
        }
        return dst;
    }

    fn genMacroEnumLiteral(self: *Codegen, lit: ast.EnumLiteral, ctx: *MacroExpansionContext) anyerror!u32 {
        const decl = self.tc.enums.get(lit.enum_name) orelse return Error.UnsupportedSabDirectFeature;
        const tag = lowering_rules.enumVariantIndex(decl, lit.variant_name) orelse return Error.UnsupportedSabDirectFeature;
        const variant = lowering_rules.enumVariant(decl, lit.variant_name) orelse return Error.UnsupportedSabDirectFeature;

        const dst = try self.intern(try self.newTmp());
        try self.emitAlloc(dst, lowering_rules.enumAbiSize(decl));

        const tag_reg = try self.intern(try self.newTmp());
        try self.emitAssignImm(tag_reg, @intCast(tag));
        try self.emitStore(dst, lowering_rules.enum_tag_offset, tag_reg, .i64);
        try self.emitRelease(tag_reg);

        for (variant.fields) |field| {
            const value = lowering_rules.enumLiteralFieldValue(&lit, field.name) orelse return Error.UnsupportedSabDirectFeature;
            const layout = lowering_rules.enumFieldLayout(variant, field.name) orelse return Error.UnsupportedSabDirectFeature;
            const prim = storagePrimType(layout.ty) catch return Error.UnsupportedSabDirectFeature;
            const value_reg = try self.genMacroExpr(value, ctx);
            try self.emitStore(dst, layout.offset, value_reg, prim);
            try self.releaseStoredExprResultIfNeeded(value, value_reg, field.ty);
        }

        return dst;
    }

    fn genMacroUnsafeExpr(self: *Codegen, expr: *const ast.Node, unsafe_expr: ast.UnsafeExpr, ctx: *MacroExpansionContext) anyerror!u32 {
        const result_ty = (try self.macroExprType(expr, ctx)) orelse return Error.MissingType;
        if (isVoidType(result_ty)) return Error.UnsupportedSabDirectFeature;

        const block_locals_len = self.locals.items.len;
        defer self.popLocalsTo(block_locals_len);
        const mark = macroScopeMark(ctx);
        defer restoreMacroLocals(ctx, mark);

        const result_slot = try self.intern(try self.newTmp());
        try self.emitAlloc(result_slot, typeSize(result_ty));
        try self.prepareResultSlotRefCellCompanion(result_slot, result_ty);

        const terminated = try self.genMacroBlockTailValueStore(unsafe_expr.body, result_slot, result_ty, ctx);
        if (terminated) {
            const result = try self.intern(try self.newTmp());
            try self.recordReg(result);
            return result;
        }

        try self.releaseLocalsFrom(block_locals_len, null);
        const result = try self.intern(try self.newTmp());
        try self.emitLoad(result, result_slot, 0, try primType(result_ty));
        try self.loadResultSlotTransferredValue(result, result_slot, result_ty);
        try self.emitRelease(result_slot);
        return result;
    }

    fn genMacroTryExpr(self: *Codegen, expr: *const ast.Node, try_expr: ast.TryExpr, ctx: *MacroExpansionContext) anyerror!u32 {
        const inner_ty = (try self.macroExprType(try_expr.expr, ctx)) orelse return Error.MissingType;
        const previous = self.tc.expr_types.get(try_expr.expr);
        try self.tc.expr_types.put(try_expr.expr, @constCast(inner_ty));
        defer {
            if (previous) |ty| {
                self.tc.expr_types.put(try_expr.expr, ty) catch unreachable;
            } else {
                _ = self.tc.expr_types.remove(try_expr.expr);
            }
        }
        return try self.genTry(expr, try_expr);
    }

    fn genMacroArrayLiteralWithType(self: *Codegen, arr_ty: *const ast.Type, lit: ast.ArrayLiteral, ctx: *MacroExpansionContext) anyerror!u32 {
        if (arr_ty.* != .array or arr_ty.array.len != lit.elements.len) return Error.UnsupportedSabDirectFeature;

        const dst = try self.intern(try self.newTmp());
        try self.emitAlloc(dst, arraySize(arr_ty.array));
        for (lit.elements, 0..) |elem, idx| {
            const layout = arrayElementLayout(arr_ty.array, idx) orelse return Error.UnsupportedSabDirectFeature;
            const value = try self.genMacroExpr(elem, ctx);
            try self.emitStore(dst, layout.offset, value, layout.ty);
            try self.releaseStoredExprResultIfNeeded(elem, value, arr_ty.array.elem);
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
        try self.releaseStoredExprResultIfNeeded(lit.value, value, arr_ty.array.elem);
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
            if (lowering_rules.planImportedMacroCall(self.tc, call)) |plan| {
                const reg = try self.genImportedMacroCall(call, plan, ctx);
                if ((try self.macroExprType(expr, ctx))) |ty| {
                    if (typeIsPointerScalarValue(ty)) try self.markNonOwningReg(reg);
                }
                return reg;
            }
        }

        const call_plan = lowering_rules.planStaticCall(self.tc, expr, call) orelse return Error.UnsupportedSabDirectFeature;

        const emit_symbol = lowering_rules.staticCallEmitSymbol(call_plan);
        const lowered = try self.loweredFuncSymbol(emit_symbol);
        var text = std.ArrayList(u8).init(self.allocator);
        var release_regs = std.ArrayList(u32).init(self.allocator);
        defer release_regs.deinit();
        var consume_regs = std.ArrayList(u32).init(self.allocator);
        defer consume_regs.deinit();
        var forget_regs = std.ArrayList(u32).init(self.allocator);
        defer forget_regs.deinit();
        var restores = std.ArrayList(struct { slot: u32, value: u32 }).init(self.allocator);
        defer restores.deinit();
        try text.writer().print("@{s}(", .{lowered});
        for (call.args, 0..) |arg, i| {
            const effective = macroEffectiveArg(ctx, arg);
            const param_info = try self.directSabCallParam(call_plan.target_symbol, i);
            const sibling_mark = try self.pushMacroCallSiblingArgExprs(ctx, call.args, i);
            defer self.popExprLaterNodesTo(sibling_mark);
            const lowered_arg = try self.genPlannedSabMacroCallArg(
                arg,
                effective,
                ctx,
                call_plan,
                if (param_info) |info| info.param else null,
                if (param_info) |info| info.abi_borrow_auto_borrow else false,
                i,
                call.associated_target == null,
            );
            if (self.plannedCallArgReleaseReg(lowered_arg.release_reg)) |reg| try release_regs.append(reg);
            if (lowered_arg.release_regs.len != 0) {
                try release_regs.appendSlice(lowered_arg.release_regs);
                self.allocator.free(lowered_arg.release_regs);
            }
            if (lowered_arg.consume_reg) |reg| try consume_regs.append(reg);
            if (lowered_arg.forget_reg) |reg| try forget_regs.append(reg);
            if (lowered_arg.restore_slot) |slot| {
                try restores.append(.{ .slot = slot, .value = lowered_arg.restore_value orelse return Error.UnsupportedSabDirectFeature });
            }
            if (i > 0) try text.appendSlice(", ");
            try text.appendSlice(lowered_arg.operand);
        }
        try text.append(')');
        const dst = try self.emitPlannedCallBody(lowering_rules.planStaticCallResult(self.tc, call_plan, self.tc.expr_types.get(expr)), try text.toOwnedSlice());
        for (restores.items) |restore| {
            try self.emitStore(restore.slot, 0, restore.value, .ptr);
            try self.markConsumed(restore.value);
        }
        try self.releaseNonLocalTemps(release_regs.items);
        for (consume_regs.items) |reg| try self.emitMove(reg);
        for (forget_regs.items) |reg| try self.markConsumed(reg);
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
        try self.storeResultSlotTransferredValue(target, value, target_ty);
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
        try self.prepareResultSlotRefCellCompanion(result_slot, result_ty);
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
            try self.loadResultSlotTransferredValue(result, result_slot, result_ty);
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
            .enum_literal => |lit| try self.genMacroEnumLiteral(lit, ctx),
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
            .unsafe_expr => |unsafe_expr| try self.genMacroUnsafeExpr(expr, unsafe_expr, ctx),
            .try_expr => |try_expr| try self.genMacroTryExpr(expr, try_expr, ctx),
            .borrow_expr => |borrow| try self.genMacroBorrow(borrow, ctx),
            .deref_expr => |deref| try self.genMacroDeref(expr, deref, ctx),
            .move_expr => |move| try self.genMacroMove(move, ctx),
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

        if (self.macroAssignTargetName(assign.target, ctx)) |name| {
            const value = if (assign.value.* == .match_expr)
                try self.genMatchWithExpected(assign.value, &assign.value.match_expr, self.localType(name))
            else
                try self.genMacroExpr(assign.value, ctx);
            try self.assignToIdentifier(name, value);
            return;
        }
        return Error.UnsupportedSabDirectFeature;
    }

    fn genMacroLet(self: *Codegen, let: ast.LetStmt, ctx: *MacroExpansionContext) anyerror!void {
        const expected_ty = if (let.ty) |ty| @as(?*const ast.Type, ty) else try self.macroExprType(let.value, ctx);
        const value = try self.genMacroExprTyped(let.value, ctx, expected_ty);
        if (std.mem.eql(u8, let.name, "_")) {
            if (!self.isLocalReg(value)) try self.emitRelease(value);
            return;
        }
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
        const loop_control = lowering_rules.planLoopControl(w.body);
        const head_label = try self.newLabel("L_WHILE_HEAD");
        const body_label = try self.newLabel("L_WHILE_BODY");
        const cond_false_label = try self.newLabel("L_WHILE_COND_FALSE");
        const break_cleanup_label = try self.newLabel("L_WHILE_BREAK_CLEANUP");
        const exit_label = try self.newLabel("L_WHILE_EXIT");

        try self.emitJmp(head_label);
        try self.emitLabel(head_label);
        const cond = try self.genMacroExpr(w.cond, ctx);
        var br = self.makeInst(.br);
        br.operands[0] = .{ .reg = cond };
        br.operands[1] = .{ .label = try self.intern(body_label) };
        br.operands[2] = .{ .label = try self.intern(body_label) };
        br.operands[3] = .{ .label = try self.intern(cond_false_label) };
        try self.appendInst(br);

        try self.emitLabel(body_label);
        if (!self.isLocalReg(cond)) try self.emitBranchRelease(cond);
        try self.loop_continue_labels.append(head_label);
        try self.loop_break_labels.append(if (loop_control.has_break) break_cleanup_label else exit_label);
        try self.genMacroBlock(w.body, ctx, true);
        _ = self.loop_continue_labels.pop();
        _ = self.loop_break_labels.pop();
        if (!self.lastIsTerminator()) try self.emitJmp(head_label);

        try self.emitLabel(cond_false_label);
        if (!self.isLocalReg(cond)) try self.emitBranchRelease(cond);
        try self.emitJmp(exit_label);

        if (loop_control.has_break) {
            try self.emitLabel(break_cleanup_label);
            try self.emitJmp(exit_label);
        }

        try self.emitLabel(exit_label);
    }

    fn genMacroFor(self: *Codegen, f: ast.ForStmt, ctx: *MacroExpansionContext) anyerror!void {
        const end_expr = f.end orelse return Error.UnsupportedSabDirectFeature;
        const loop_control = lowering_rules.planLoopControl(f.body);
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
        const cond_false_label = try self.newLabel("L_FOR_COND_FALSE");
        const break_cleanup_label = try self.newLabel("L_FOR_BREAK_CLEANUP");
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
        br.operands[3] = .{ .label = try self.intern(cond_false_label) };
        try self.appendInst(br);

        var pre_released = try self.released_regs.clone();
        defer pre_released.deinit();

        try self.emitLabel(body_label);
        try self.emitBranchRelease(cond);
        try self.pushLocal(mapped_var, index_reg, false);
        try self.loop_continue_labels.append(cont_label);
        try self.loop_break_labels.append(if (loop_control.has_break) break_cleanup_label else exit_label);
        try self.genMacroBlock(f.body, ctx, true);
        _ = self.loop_continue_labels.pop();
        _ = self.loop_break_labels.pop();
        if (!self.lastIsTerminator()) try self.emitJmp(cont_label);

        try self.emitLabel(cont_label);
        const next = try self.intern(try self.newTmp());
        try self.emitOp(next, .add, .{ .reg = index_reg }, .{ .imm_i64 = 1 });
        try self.emitStore(counter_slot, 0, next, .i64);
        try self.emitRelease(next);
        if (!self.released_regs.contains(index_reg)) try self.emitRelease(index_reg);
        try self.emitJmp(head_label);

        try self.restoreReleased(&pre_released);

        try self.emitLabel(cond_false_label);
        try self.emitBranchRelease(cond);
        try self.emitBranchRelease(index_reg);
        try self.emitJmp(exit_label);

        if (loop_control.has_break) {
            try self.emitLabel(break_cleanup_label);
            try self.emitBranchRelease(index_reg);
            try self.emitJmp(exit_label);
        }

        try self.emitLabel(exit_label);
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
                var value: ?u32 = null;
                if (ret.value) |v| {
                    const old_result_escapes = self.current_expr_result_escapes;
                    self.current_expr_result_escapes = true;
                    defer self.current_expr_result_escapes = old_result_escapes;
                    value = try self.genMacroExpr(v, ctx);
                }
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
            .break_stmt => {
                if (self.loop_break_labels.items.len == 0) return Error.UnsupportedSabDirectFeature;
                try self.emitJmp(self.loop_break_labels.items[self.loop_break_labels.items.len - 1]);
            },
            .continue_stmt => {
                if (self.loop_continue_labels.items.len == 0) return Error.UnsupportedSabDirectFeature;
                try self.emitJmp(self.loop_continue_labels.items[self.loop_continue_labels.items.len - 1]);
            },
            else => return Error.UnsupportedSabDirectFeature,
        }
    }

    fn genUserMacroCallWithParent(self: *Codegen, macro_decl: *const ast.MacroDecl, call: ast.CallExpr, parent_ctx: ?*MacroExpansionContext) anyerror!void {
        if (macro_decl.params.len != call.args.len) return Error.UnsupportedSabDirectFeature;
        const old_locals = self.locals.items.len;
        defer self.popLocalsTo(old_locals);
        const bindings = try self.allocator.alloc(MacroArgBinding, call.args.len);
        defer self.allocator.free(bindings);
        for (macro_decl.params, call.args, 0..) |param, arg, idx| {
            const requires_lvalue = lowering_rules.macroParamRequiresLvalue(self.tc, macro_decl.body, param);
            const evaluated_reg = if (requires_lvalue)
                null
            else if (parent_ctx) |arg_ctx|
                try self.genMacroExpr(@constCast(arg), arg_ctx)
            else
                try self.genExpr(@constCast(arg));
            const release_evaluated_reg = if (evaluated_reg) |reg| !self.isLocalReg(reg) else false;
            bindings[idx] = .{
                .name = param,
                .arg = arg,
                .ctx = parent_ctx,
                .evaluated_reg = evaluated_reg,
                .release_evaluated_reg = release_evaluated_reg,
            };
            if (evaluated_reg) |reg| {
                const arg_ty = if (parent_ctx) |arg_ctx|
                    try self.macroExprType(arg, arg_ctx)
                else
                    try self.exprTypeOrFallback(arg);
                if (arg_ty) |ty| try self.pushTypedLocal(param, reg, true, ty) else try self.pushLocal(param, reg, true);
            }
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

        try self.genMacroBlock(macro_decl.body, &ctx, false);
        for (bindings) |binding| {
            if (binding.evaluated_reg) |reg| {
                if (binding.release_evaluated_reg and !self.released_regs.contains(reg)) try self.emitRelease(reg);
            }
        }
        var i = self.locals.items.len;
        while (i > old_locals) {
            i -= 1;
            const local = self.locals.items[i];
            if (local.is_param or local.stack_ty != null or self.released_regs.contains(local.reg)) continue;
            try self.emitRelease(local.reg);
        }
    }

    fn genUserMacroCall(self: *Codegen, macro_decl: *const ast.MacroDecl, call: *const ast.CallExpr) anyerror!void {
        const previous = self.active_macro_try_cleanup;
        self.active_macro_try_cleanup = if (self.tc.macro_call_try_cleanups.get(call)) |list| list.items else previous;
        defer self.active_macro_try_cleanup = previous;
        try self.genUserMacroCallWithParent(macro_decl, call.*, null);
    }

    fn genStmt(self: *Codegen, stmt: *ast.Node) anyerror!void {
        switch (stmt.*) {
            .var_stmt => |v| {
                const dst = try self.intern(try self.newTmp());
                try self.emitStackAlloc(dst, typeSize(v.ty));
                try self.pushStackLocal(v.name, dst, v.ty);
            },
            .let_stmt => |let| try self.genLet(let),
            .let_else_stmt => |let| try self.genLetElse(let),
            .let_destructure_stmt => |let| try self.genLetDestructure(let),
            .assign_stmt => |assign| try self.genAssign(assign),
            .expr_stmt => |expr| {
                if (expr.* == .if_expr or expr.* == .switch_expr) {
                    _ = try self.genExpr(expr);
                } else if (expr.* == .call_expr and std.mem.eql(u8, expr.call_expr.func_name, "panic")) {
                    _ = try self.genExpr(expr);
                } else if (expr.* == .call_expr) {
                    if (self.tc.macros.get(expr.call_expr.func_name)) |macro_decl| {
                        try self.genUserMacroCall(macro_decl, &expr.call_expr);
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
                var value: ?u32 = null;
                if (ret.value) |v| {
                    const old_result_escapes = self.current_expr_result_escapes;
                    self.current_expr_result_escapes = true;
                    defer self.current_expr_result_escapes = old_result_escapes;
                    value = try self.genExpr(v);
                }
                if (self.lastIsTerminator()) return;
                if (self.current_async_return) {
                    if (value == null) {
                        const zero = try self.intern(try self.newTmp());
                        try self.emitAssignImm(zero, 0);
                        value = zero;
                    }
                    value = try self.genReadyFuture(value.?);
                }
                try self.releaseOpenLocals(value);
                try self.emitReturn(value);
            },
            .block_stmt => |blk| try self.genScopedBlock(blk.body),
            .for_stmt => |f| try self.genFor(f),
            .while_stmt => |w| try self.genWhile(w),
            .break_stmt => try self.genLoopJump(stmt, .break_),
            .continue_stmt => try self.genLoopJump(stmt, .continue_),
            .release_stmt => |rel| try self.genReleaseStmt(rel),
            else => return Error.UnsupportedSabDirectFeature,
        }
    }

    fn genLetElse(self: *Codegen, let: ast.LetElseStmt) anyerror!void {
        const value_reg = try self.genExpr(let.value);
        const value_ty = self.tc.expr_types.get(let.value) orelse return Error.MissingType;
        const enum_decl = try self.enumDeclForPatternValue(let.value, let.pattern);
        const plan = lowering_rules.planLetPattern(let.pattern, enum_decl != null) orelse return Error.UnsupportedSabDirectFeature;
        const branch_flag = try self.intern(try self.newTmp());
        try self.recordReg(branch_flag);
        try self.emitLetPatternCheck(let.pattern, value_reg, enum_decl, plan, branch_flag);

        const success_label = try self.newLabel("L_LET_ELSE_SUCCESS");
        const else_label = try self.newLabel("L_LET_ELSE_FAILURE");
        try self.emitBranch(
            branch_flag,
            if (plan.success_on_true) success_label else else_label,
            if (plan.success_on_true) else_label else success_label,
        );

        const locals_len = self.locals.items.len;
        var pre_branch_state = try self.cloneBranchEmitterState();
        defer self.deinitBranchEmitterStateSnapshot(&pre_branch_state);

        try self.emitLabel(else_label);
        try self.emitBranchRelease(branch_flag);
        if (!self.isLocalReg(value_reg)) try self.emitBranchRelease(value_reg);
        try self.genBlock(let.else_block);

        self.popLocalsTo(locals_len);
        try self.restoreReleased(&pre_branch_state.released);
        try self.restoreRefCellBranchState(&pre_branch_state.refcell_values, &pre_branch_state.borrow_temps);

        try self.emitLabel(success_label);
        try self.emitBranchRelease(branch_flag);
        try self.bindLetPatternPayload(let.pattern, value_reg, value_ty, enum_decl, plan);
        if (!self.isLocalReg(value_reg)) try self.emitRelease(value_reg);
    }

    fn genLetDestructure(self: *Codegen, let: ast.LetDestructureStmt) anyerror!void {
        const value_ty = self.tc.expr_types.get(let.value) orelse return Error.MissingType;
        if (let.is_slice) {
            try self.genArrayLetDestructure(let, value_ty);
            return;
        }
        if (let.rest_name != null or let.rest_alias != null) return Error.UnsupportedSabDirectFeature;
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

    fn genArrayLetDestructure(self: *Codegen, let: ast.LetDestructureStmt, value_ty: *const ast.Type) anyerror!void {
        if (value_ty.* != .array) return Error.UnsupportedSabDirectFeature;
        const arr = value_ty.array;
        if (let.names.len > arr.len) return Error.UnsupportedSabDirectFeature;
        const rest_name = let.rest_name orelse return Error.UnsupportedSabDirectFeature;
        const rest_is_discard = std.mem.eql(u8, rest_name, "_");
        if (rest_is_discard) {
            if (let.rest_alias) |alias| {
                if (!std.mem.eql(u8, alias, "_")) return Error.UnsupportedSabDirectFeature;
            }
        }

        const value = try self.genExpr(let.value);
        const keep_owner = !rest_is_discard and !self.isLocalReg(value);
        if (keep_owner) {
            try self.pushTypedLocal(try self.newTmp(), value, false, value_ty);
        }

        for (let.names, 0..) |name, idx| {
            if (std.mem.eql(u8, name, "_")) continue;
            const layout = arrayElementLayout(arr, idx) orelse return Error.UnsupportedSabDirectFeature;
            const dst = try self.intern(name);
            try self.emitLoad(dst, value, layout.offset, layout.ty);
            try self.pushTypedLocal(name, dst, false, arr.elem);
        }

        if (!rest_is_discard) {
            const rest_len = lowering_rules.arrayRestLen(arr, let.names.len) orelse return Error.UnsupportedSabDirectFeature;
            const rest_ptr = try self.intern(try self.newTmp());
            try self.emitPtrAdd(rest_ptr, value, .{ .imm_u64 = @intCast(arrayStride(arr.elem) * let.names.len) });

            const rest_len_reg = try self.intern(try self.newTmp());
            try self.emitAssignImm(rest_len_reg, @intCast(rest_len));

            const rest_reg = try self.intern(rest_name);
            const slice_ty = try self.makeSliceType(arr.elem);
            try self.emitStackAlloc(rest_reg, lowering_rules.SliceAbi.size);
            try self.emitStdMacroFragment("sa_std/core/slice.sa", "SLICE_NEW", &.{
                self.symbols.items[rest_reg],
                self.symbols.items[rest_ptr],
                self.symbols.items[rest_len_reg],
            });
            try self.emitRelease(rest_len_reg);
            try self.emitRelease(rest_ptr);
            try self.pushStackAllocTypedLocal(rest_name, rest_reg, slice_ty);

            if (let.rest_alias) |alias| {
                if (!std.mem.eql(u8, alias, "_")) {
                    try self.pushStackAllocTypedLocal(alias, rest_reg, slice_ty);
                }
            }
        }

        if (!self.isLocalReg(value)) try self.emitRelease(value);
    }

    fn genAssign(self: *Codegen, assign: ast.AssignStmt) anyerror!void {
        if (assign.target.* == .deref_expr) {
            const source_expr = assign.target.deref_expr.expr;
            const source_ty = self.tc.expr_types.get(source_expr) orelse return Error.MissingType;
            const inner_ty = switch (source_ty.*) {
                .borrow => |inner| inner,
                .pointer => |inner| inner,
                else => return Error.UnsupportedSabDirectFeature,
            };
            const target = try self.genExpr(source_expr);
            const value = try self.genExpr(assign.value);
            try self.emitStore(target, 0, value, try storagePrimType(inner_ty));
            const target_lifecycle = lowering_rules.planDerefAssignmentTargetLifecycle(
                source_expr.* != .identifier,
                self.refcell_borrow_values.contains(target),
            );
            if (target_lifecycle.shouldRelease()) try self.emitRelease(target);
            if (!self.isLocalReg(value)) try self.emitRelease(value);
            return;
        }
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
            try self.markAssignmentMovedSourceWithType(assign.target, assign.value, field_ty);
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
                try self.markAssignmentMovedSource(assign.target, assign.value);
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
            try self.markAssignmentMovedSource(assign.target, assign.value);
            return;
        }

        if (assign.target.* != .identifier) return Error.UnsupportedSabDirectFeature;
        const name = assign.target.identifier;
        const value = try self.genExpr(assign.value);
        try self.assignToIdentifier(name, value);
        const target_ty = self.localType(name) orelse (try self.exprTypeOrFallback(assign.target)) orelse return Error.MissingType;
        if (assign.value.* == .identifier) {
            if (lowering_rules.assignmentMovesIdentifier(assign.target, assign.value, target_ty, self.typeIsCopyValue(target_ty))) |moved_name| {
                if (self.localReg(moved_name)) |source_reg| try self.markConsumed(source_reg);
            }
        }
    }

    fn switchCaseIsDefault(case: ast.Case) bool {
        return case.pattern.* == .identifier and std.mem.eql(u8, case.pattern.identifier, "default");
    }

    fn emitSwitchCaseCondition(self: *Codegen, pattern: *ast.Node, val_reg: u32, val_ty: *const ast.Type, enum_decl: ?*ast.EnumDecl, cond: u32) anyerror!void {
        if (pattern.* == .enum_literal) {
            const decl = enum_decl orelse return Error.UnsupportedSabDirectFeature;
            const lit = pattern.enum_literal;
            if (!enumNameMatchesDecl(lit.enum_name, decl.name)) return Error.UnsupportedSabDirectFeature;
            if (lit.fields.len != 0) return Error.UnsupportedSabDirectFeature;
            const tag = lowering_rules.enumVariantIndex(decl, lit.variant_name) orelse return Error.UnsupportedSabDirectFeature;
            const tag_reg = try self.intern(try self.newTmp());
            try self.emitLoad(tag_reg, val_reg, lowering_rules.enum_tag_offset, .i64);
            try self.emitOp(cond, .eq, .{ .reg = tag_reg }, .{ .imm_i64 = @intCast(tag) });
            try self.emitRelease(tag_reg);
            return;
        }

        if (enum_decl != null) return Error.UnsupportedSabDirectFeature;
        _ = val_ty;

        if (pattern.* == .literal and pattern.literal == .int_val) {
            try self.emitOp(cond, .eq, .{ .reg = val_reg }, .{ .imm_i64 = pattern.literal.int_val });
            return;
        }

        const pattern_reg = try self.genExpr(pattern);
        try self.emitOp(cond, .eq, .{ .reg = val_reg }, .{ .reg = pattern_reg });
        try self.releaseExprResultIfNeeded(pattern, pattern_reg);
    }

    fn genSwitchStatement(self: *Codegen, sw: ast.SwitchExpr) anyerror!u32 {
        if (sw.cases.len == 0) {
            const sentinel = try self.intern(try self.newTmp());
            try self.emitAssignImm(sentinel, 0);
            return sentinel;
        }

        var default_index: ?usize = null;
        for (sw.cases, 0..) |case, idx| {
            if (switchCaseIsDefault(case)) {
                if (default_index != null or idx + 1 != sw.cases.len) return Error.UnsupportedSabDirectFeature;
                default_index = idx;
            }
        }

        const val_ty = if (sw.val.* == .identifier)
            self.localType(sw.val.identifier) orelse self.tc.expr_types.get(sw.val) orelse return Error.MissingType
        else
            self.tc.expr_types.get(sw.val) orelse return Error.MissingType;
        const enum_decl = self.enumDeclForValueType(val_ty);
        const val_reg = try self.genExpr(sw.val);
        const val_is_local = self.isLocalReg(val_reg);

        var check_labels = std.ArrayList([]const u8).init(self.allocator);
        defer check_labels.deinit();
        for (sw.cases) |_| {
            try check_labels.append(try self.newLabel("L_SWITCH_CHECK"));
        }

        const merge_label = try self.newLabel("L_SWITCH_MERGE");
        const no_match_label = try self.newLabel("L_SWITCH_NO_MATCH");
        const branch_locals_len = self.locals.items.len;
        var pre_branch_state = try self.cloneBranchEmitterState();
        defer self.deinitBranchEmitterStateSnapshot(&pre_branch_state);
        var live_branch_states = std.ArrayList(BranchEmitterStateSnapshot).init(self.allocator);
        defer {
            for (live_branch_states.items) |*snapshot| self.deinitBranchEmitterStateSnapshot(snapshot);
            live_branch_states.deinit();
        }
        var any_fallthrough = false;

        try self.emitJmp(check_labels.items[0]);

        var previous_cond: ?u32 = null;
        for (sw.cases, 0..) |case, i| {
            try self.emitLabel(check_labels.items[i]);
            if (previous_cond) |cond| {
                try self.emitBranchRelease(cond);
                previous_cond = null;
            }

            const body_label = try self.newLabel("L_SWITCH_CASE");
            var case_cond: ?u32 = null;
            if (switchCaseIsDefault(case)) {
                try self.emitJmp(body_label);
            } else {
                const cond = try self.intern(try self.newTmp());
                try self.emitSwitchCaseCondition(case.pattern, val_reg, val_ty, enum_decl, cond);
                const next_label = if (i + 1 < sw.cases.len) check_labels.items[i + 1] else no_match_label;
                try self.emitBranch(cond, body_label, next_label);
                case_cond = cond;
                previous_cond = cond;
            }

            try self.emitLabel(body_label);
            if (case_cond) |cond| try self.emitBranchRelease(cond);
            if (!val_is_local) try self.emitBranchRelease(val_reg);
            try self.genBlock(case.body);
            const terminated = self.lastIsTerminator();
            if (!terminated) {
                try self.releaseLocalsFrom(branch_locals_len, null);
                try self.emitJmp(merge_label);
                any_fallthrough = true;
                try self.appendCurrentBranchEmitterState(&live_branch_states);
            }

            self.popLocalsTo(branch_locals_len);
            try self.restoreReleased(&pre_branch_state.released);
            try self.restoreRefCellBranchState(&pre_branch_state.refcell_values, &pre_branch_state.borrow_temps);
        }

        if (default_index == null) {
            try self.emitLabel(no_match_label);
            if (previous_cond) |cond| {
                try self.emitBranchRelease(cond);
                previous_cond = null;
            }
            if (!val_is_local) try self.emitBranchRelease(val_reg);
            try self.emitJmp(merge_label);
            any_fallthrough = true;
            try self.appendCurrentBranchEmitterState(&live_branch_states);
        }

        try self.setMergeBranchEmitterState(live_branch_states.items, &pre_branch_state);
        if (any_fallthrough) try self.emitLabel(merge_label);

        const sentinel = try self.intern(try self.newTmp());
        try self.emitAssignImm(sentinel, 0);
        return sentinel;
    }

    fn genExpr(self: *Codegen, expr: *ast.Node) anyerror!u32 {
        return switch (expr.*) {
            .literal => |lit| try self.genLiteral(lit),
            .identifier => |name| blk: {
                if (self.closure_param_regs.get(name)) |mapped| break :blk mapped;
                if (self.stackLocal(name)) |slot| {
                    const ty = slot.stack_ty orelse return Error.UnsupportedSabDirectFeature;
                    const dst = try self.intern(try self.newTmp());
                    try self.emitLoad(dst, slot.reg, 0, try storagePrimType(ty));
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
                if (lowering_rules.planDynCoercion(self.tc, expr)) |plan| break :blk try self.genDynCoercionExpr(expr, plan);
                if (self.tc.fn_ptr_calls.contains(expr)) break :blk try self.genFnPtrCall(expr, call);
                break :blk try self.genCall(expr, call);
            },
            .field_expr => |field| try self.genField(field),
            .struct_literal => |lit| try self.genStructLiteral(lit),
            .enum_literal => |lit| try self.genEnumLiteral(lit),
            .tuple_literal => |lit| try self.genTupleLiteral(lit),
            .array_literal => |lit| try self.genArrayLiteral(expr, lit),
            .repeat_array_literal => |lit| try self.genRepeatArrayLiteral(expr, lit),
            .index_expr => |idx| try self.genIndex(idx),
            .match_expr => |mat| try self.genMatch(expr, &mat),
            .switch_expr => |sw| try self.genSwitchStatement(sw),
            .if_expr => |ife| try self.genIf(expr, ife),
            .cast_expr => |cast| try self.genCast(cast),
            .unsafe_expr => |unsafe_expr| try self.genUnsafeExpr(expr, unsafe_expr),
            .try_expr => |try_expr| try self.genTry(expr, try_expr),
            .await_expr => |aw| try self.genAwait(expr, aw),
            .borrow_expr => |borrow| try self.genBorrow(borrow),
            .move_expr => |move| try self.genMove(move),
            .deref_expr => |deref| try self.genDeref(expr, deref),
            else => Error.UnsupportedSabDirectFeature,
        };
    }

    fn genTry(self: *Codegen, expr: *const ast.Node, try_expr: ast.TryExpr) anyerror!u32 {
        const inner_ty = self.tc.expr_types.get(try_expr.expr) orelse return Error.MissingType;
        const inner_reg = try self.genExpr(try_expr.expr);
        const success_label = try self.newLabel("L_TRY_SUCCESS");
        const error_label = try self.newLabel("L_TRY_ERROR");

        if (lowering_rules.optionInnerType(inner_ty) != null) {
            const is_some = try self.intern(try self.newTmp());
            try self.recordReg(is_some);
            try self.emitStdMacroFragment("sa_std/core/option.sa", "OPTION_IS_SOME", &.{
                self.symbols.items[is_some],
                self.symbols.items[inner_reg],
            });
            try self.emitBranch(is_some, success_label, error_label);

            try self.emitLabel(error_label);
            try self.emitBranchRelease(is_some);
            try self.emitBranchCleanupForNode(expr);
            try self.emitReturn(inner_reg);

            try self.emitLabel(success_label);
            try self.emitBranchRelease(is_some);
            const value = try self.intern(try self.newTmp());
            try self.recordReg(value);
            try self.emitStdMacroFragment("sa_std/core/option.sa", "OPTION_GET", &.{
                self.symbols.items[value],
                self.symbols.items[inner_reg],
            });
            if (!self.isLocalReg(inner_reg)) try self.emitRelease(inner_reg);
            return value;
        }

        if (lowering_rules.resultOkType(inner_ty) != null) {
            const is_ok = try self.intern(try self.newTmp());
            try self.recordReg(is_ok);
            try self.emitStdMacroFragment("sa_std/core/result.sa", "RESULT_IS_OK", &.{
                self.symbols.items[is_ok],
                self.symbols.items[inner_reg],
            });
            try self.emitBranch(is_ok, success_label, error_label);

            try self.emitLabel(error_label);
            try self.emitBranchRelease(is_ok);
            try self.emitBranchCleanupForNode(expr);
            try self.emitReturn(inner_reg);

            try self.emitLabel(success_label);
            try self.emitBranchRelease(is_ok);
            const value = try self.intern(try self.newTmp());
            try self.recordReg(value);
            try self.emitStdMacroFragment("sa_std/core/result.sa", "RESULT_GET_OK", &.{
                self.symbols.items[value],
                self.symbols.items[inner_reg],
            });
            if (!self.isLocalReg(inner_reg)) try self.emitRelease(inner_reg);
            return value;
        }

        var result_ty = inner_ty;
        while (true) {
            switch (result_ty.*) {
                .pointer => |p| result_ty = p,
                .borrow => |b| result_ty = b,
                else => break,
            }
        }
        if (result_ty.* != .user_defined) return Error.UnsupportedSabDirectFeature;
        const result_decl = self.tc.structs.get(result_ty.user_defined.name) orelse return Error.UnsupportedSabDirectFeature;
        const is_err_layout = lowering_rules.structFieldLayout(result_decl, "is_err") orelse return Error.UnsupportedSabDirectFeature;
        const value_layout = lowering_rules.structFieldLayout(result_decl, "value") orelse return Error.UnsupportedSabDirectFeature;
        const is_err = try self.intern(try self.newTmp());
        try self.emitLoad(is_err, inner_reg, is_err_layout.offset, try storagePrimType(is_err_layout.ty));
        try self.emitBranch(is_err, error_label, success_label);

        try self.emitLabel(error_label);
        try self.emitBranchRelease(is_err);
        try self.emitBranchCleanupForNode(expr);
        try self.emitReturn(inner_reg);

        try self.emitLabel(success_label);
        try self.emitBranchRelease(is_err);
        const value = try self.intern(try self.newTmp());
        try self.emitLoad(value, inner_reg, value_layout.offset, try storagePrimType(value_layout.ty));
        if (!self.isLocalReg(inner_reg)) try self.emitRelease(inner_reg);
        return value;
    }

    fn genLiteral(self: *Codegen, lit: ast.Literal) anyerror!u32 {
        const reg = try self.intern(try self.newTmp());
        try self.recordReg(reg);
        switch (lit) {
            .int_val => |v| try self.emitAssignImm(reg, v),
            .float_val => |v| try self.emitAssignFloat(reg, v),
            .bool_val => |v| try self.emitAssignImm(reg, if (v) 1 else 0),
            .string_val => |v| return try self.genStringLiteral(v),
        }
        return reg;
    }

    fn genStringLiteral(self: *Codegen, value: []const u8) anyerror!u32 {
        const label = try self.stringLiteralConstLabel(value);

        const len_reg = try self.intern(try self.newTmp());
        const bytes_len = try decodedStringLiteralLen(value);
        try self.emitAssignImm(len_reg, @intCast(bytes_len));

        const slice_reg = try self.intern(try self.newTmp());
        try self.emitStackAlloc(slice_reg, lowering_rules.SliceAbi.size);
        try self.markNonOwningReg(slice_reg);

        const ptr_reg = try self.intern(try self.newTmp());
        try self.emitBorrowSymbol(ptr_reg, label);
        try self.emitSliceNew(slice_reg, ptr_reg, len_reg);
        try self.emitRelease(ptr_reg);
        try self.emitRelease(len_reg);
        return slice_reg;
    }

    fn genRawPointerStringLiteralArg(self: *Codegen, value: []const u8) anyerror!u32 {
        const ptr_reg = try self.intern(try self.newTmp());
        const label = try self.stringLiteralConstLabel(value);
        try self.emitBorrowSymbol(ptr_reg, label);
        return ptr_reg;
    }

    fn genStrPtrCall(self: *Codegen, call: ast.CallExpr) anyerror!?u32 {
        if (!std.mem.eql(u8, call.func_name, "STR_PTR") or call.args.len != 1) return null;
        const arg = call.args[0];
        if (arg.* == .literal and arg.literal == .string_val) {
            return try self.genRawPointerStringLiteralArg(arg.literal.string_val);
        }
        return null;
    }

    fn genStrLenCall(self: *Codegen, call: ast.CallExpr) anyerror!?u32 {
        if (!std.mem.eql(u8, call.func_name, "STR_LEN") or call.args.len != 1) return null;
        const arg = call.args[0];
        if (arg.* == .literal and arg.literal == .string_val) {
            const dst = try self.intern(try self.newTmp());
            try self.emitAssignImm(dst, @intCast(try decodedStringLiteralLen(arg.literal.string_val)));
            return dst;
        }
        return null;
    }

    fn genBinary(self: *Codegen, bin: ast.BinaryExpr) anyerror!u32 {
        // `<=>` produces an `Ordering` struct value. Numeric and same-struct
        // field-wise comparison are lowered here through the shared spaceship
        // classification, mirroring the SA-text `genSpaceshipExpr`.
        if (bin.op == .spaceship) return try self.genSpaceship(bin);

        // Derived `==`/`!=` and `<`/`<=`/`>`/`>=` on same-struct operands are
        // lowered field-wise, mirroring SA-text `genStructEqualityExpr` /
        // `genStructOrdExpr`. Returns null when operands are not same-struct so
        // the primitive path below handles scalars.
        if (try self.genStructComparison(bin)) |reg| return reg;

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
        try self.releaseExprResultIfNeeded(bin.left, lhs);
        try self.releaseExprResultIfNeeded(bin.right, rhs);
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

    /// Direct SAB lowering for the `<=>` spaceship operator. Produces an
    /// `Ordering` struct value (`{ value: i64 }`, an 8-byte alloc holding the
    /// raw ordering at offset 0). The raw ordering (-1 / 0 / 1) is computed with
    /// structured comparison ops and branches, mirroring SA-text
    /// `genSpaceshipExpr`. Numeric operands and same-struct field-wise
    /// lexicographic comparison are supported; other shapes return
    /// `UnsupportedSabDirectFeature`. Comparison/ABI facts come from the shared
    /// `lowering_rules` layer so both emitters agree.
    fn genSpaceship(self: *Codegen, bin: ast.BinaryExpr) anyerror!u32 {
        const left_ty = self.tc.expr_types.get(bin.left) orelse return Error.MissingType;
        const right_ty = self.tc.expr_types.get(bin.right) orelse return Error.MissingType;

        const left_reg = try self.genExpr(bin.left);
        const right_reg = try self.genExpr(bin.right);

        const result = try self.intern(try self.newTmp());
        // Ordering is a struct { value: i64 } — a single 8-byte word.
        try self.emitAlloc(result, 8);

        if (lowering_rules.isNumericType(left_ty) and lowering_rules.isNumericType(right_ty)) {
            const raw = try self.genSpaceshipRawNumeric(left_reg, right_reg, left_ty);
            try self.emitStore(result, 0, raw, .i64);
            try self.emitRelease(raw);
            try self.releaseExprResultIfNeeded(bin.left, left_reg);
            try self.releaseExprResultIfNeeded(bin.right, right_reg);
            return result;
        }

        // Same-struct field-wise lexicographic comparison.
        const left_struct = self.structDeclForType(left_ty) orelse return Error.UnsupportedSabDirectFeature;
        const right_struct = self.structDeclForType(right_ty) orelse return Error.UnsupportedSabDirectFeature;
        if (left_struct != right_struct or left_struct.is_opaque or left_struct.is_union) return Error.UnsupportedSabDirectFeature;

        // Default to EQUAL; each field can overwrite and jump to done. Mirrors
        // SA-text `genSpaceshipExpr`: per field, `less` -> store LESS + done,
        // else `greater` -> store GREATER + done, else fall through to the next
        // field. No value register survives the `done` merge (only `result`,
        // which is a stable allocation), avoiding PhiStateConflict.
        const eq_seed = try self.intern(try self.newTmp());
        try self.emitAssignImm(eq_seed, lowering_rules.ordering_equal);
        try self.emitStore(result, 0, eq_seed, .i64);
        try self.emitRelease(eq_seed);

        const done_label = try self.newLabel("L_SPACESHIP_STRUCT_DONE");
        for (left_struct.fields) |field| {
            const layout = lowering_rules.structFieldLayout(left_struct, field.name) orelse return Error.UnsupportedSabDirectFeature;
            const prim = storagePrimType(layout.ty) catch return Error.UnsupportedSabDirectFeature;
            const is_float = lowering_rules.isFloatType(field.ty);
            const lt_op: inst.OpKind = if (is_float) .fcmp_lt else if (lowering_rules.isUnsignedIntegerType(field.ty)) .ult else .slt;
            const gt_op: inst.OpKind = if (is_float) .fcmp_gt else if (lowering_rules.isUnsignedIntegerType(field.ty)) .ugt else .sgt;

            const less_label = try self.newLabel("L_SPACESHIP_STRUCT_LESS");
            const check_gt_label = try self.newLabel("L_SPACESHIP_STRUCT_CHECK_GT");
            const greater_label = try self.newLabel("L_SPACESHIP_STRUCT_GREATER");
            const next_label = try self.newLabel("L_SPACESHIP_STRUCT_NEXT");

            const lhs = try self.intern(try self.newTmp());
            const rhs = try self.intern(try self.newTmp());
            try self.emitLoad(lhs, left_reg, layout.offset, prim);
            try self.emitLoad(rhs, right_reg, layout.offset, prim);
            const less = try self.intern(try self.newTmp());
            try self.emitOp(less, lt_op, .{ .reg = lhs }, .{ .reg = rhs });
            try self.emitBranch(less, less_label, check_gt_label);

            try self.emitLabel(less_label);
            try self.emitBranchRelease(less);
            const less_val = try self.intern(try self.newTmp());
            try self.emitAssignImm(less_val, lowering_rules.ordering_less);
            try self.emitStore(result, 0, less_val, .i64);
            try self.emitRelease(less_val);
            try self.emitJmp(done_label);

            try self.emitLabel(check_gt_label);
            try self.emitBranchRelease(less);
            const greater = try self.intern(try self.newTmp());
            try self.emitOp(greater, gt_op, .{ .reg = lhs }, .{ .reg = rhs });
            try self.emitBranch(greater, greater_label, next_label);

            try self.emitLabel(greater_label);
            try self.emitBranchRelease(greater);
            const greater_val = try self.intern(try self.newTmp());
            try self.emitAssignImm(greater_val, lowering_rules.ordering_greater);
            try self.emitStore(result, 0, greater_val, .i64);
            try self.emitRelease(greater_val);
            try self.emitJmp(done_label);

            try self.emitLabel(next_label);
            try self.emitBranchRelease(greater);
        }
        try self.emitJmp(done_label);
        try self.emitLabel(done_label);
        try self.releaseExprResultIfNeeded(bin.left, left_reg);
        try self.releaseExprResultIfNeeded(bin.right, right_reg);
        return result;
    }

    /// Compute the raw ordering value (-1 / 0 / 1) of two numeric registers
    /// into a fresh register, using structured comparison ops and branches.
    /// Signed/unsigned/float op selection comes from the shared type
    /// predicates. Mirrors SA-text `genNumericSpaceshipRaw`.
    fn genSpaceshipRawNumeric(self: *Codegen, left_reg: u32, right_reg: u32, ty: *const ast.Type) anyerror!u32 {
        const raw_slot = try self.intern(try self.newTmp());
        try self.emitStackAlloc(raw_slot, 8);

        const is_float = lowering_rules.isFloatType(ty);
        const lt_op: inst.OpKind = if (is_float) .fcmp_lt else if (lowering_rules.isUnsignedIntegerType(ty)) .ult else .slt;
        const gt_op: inst.OpKind = if (is_float) .fcmp_gt else if (lowering_rules.isUnsignedIntegerType(ty)) .ugt else .sgt;

        const less_label = try self.newLabel("L_SPACESHIP_LESS");
        const check_gt_label = try self.newLabel("L_SPACESHIP_CHECK_GT");
        const greater_label = try self.newLabel("L_SPACESHIP_GREATER");
        const equal_label = try self.newLabel("L_SPACESHIP_EQUAL");
        const done_label = try self.newLabel("L_SPACESHIP_DONE");

        const less = try self.intern(try self.newTmp());
        try self.emitOp(less, lt_op, .{ .reg = left_reg }, .{ .reg = right_reg });
        try self.emitBranch(less, less_label, check_gt_label);

        try self.emitLabel(less_label);
        try self.emitBranchRelease(less);
        const less_val = try self.intern(try self.newTmp());
        try self.emitAssignImm(less_val, lowering_rules.ordering_less);
        try self.emitStore(raw_slot, 0, less_val, .i64);
        try self.emitRelease(less_val);
        try self.emitJmp(done_label);

        try self.emitLabel(check_gt_label);
        try self.emitBranchRelease(less);
        const greater = try self.intern(try self.newTmp());
        try self.emitOp(greater, gt_op, .{ .reg = left_reg }, .{ .reg = right_reg });
        try self.emitBranch(greater, greater_label, equal_label);

        try self.emitLabel(greater_label);
        try self.emitBranchRelease(greater);
        const greater_val = try self.intern(try self.newTmp());
        try self.emitAssignImm(greater_val, lowering_rules.ordering_greater);
        try self.emitStore(raw_slot, 0, greater_val, .i64);
        try self.emitRelease(greater_val);
        try self.emitJmp(done_label);

        try self.emitLabel(equal_label);
        try self.emitBranchRelease(greater);
        const equal_val = try self.intern(try self.newTmp());
        try self.emitAssignImm(equal_val, lowering_rules.ordering_equal);
        try self.emitStore(raw_slot, 0, equal_val, .i64);
        try self.emitRelease(equal_val);
        try self.emitJmp(done_label);

        try self.emitLabel(done_label);
        const raw = try self.intern(try self.newTmp());
        try self.emitLoad(raw, raw_slot, 0, .i64);
        return raw;
    }

    /// Field-wise derived comparison (`==`, `!=`, `<`, `<=`, `>`, `>=`) on
    /// same-struct operands, mirroring SA-text `genStructEqualityExpr` and
    /// `genStructOrdExpr`. Uses only straight-line structured ops (no branches),
    /// so no value register crosses a control-flow merge. Returns null when the
    /// operands are not the same user struct (caller falls through to the
    /// primitive path); `ord` comparisons require the `ord` derive.
    fn genStructComparison(self: *Codegen, bin: ast.BinaryExpr) anyerror!?u32 {
        const is_eq = bin.op == .eq or bin.op == .ne;
        const is_ord = bin.op == .lt or bin.op == .le or bin.op == .gt or bin.op == .ge;
        if (!is_eq and !is_ord) return null;

        const left_ty = self.tc.expr_types.get(bin.left) orelse return null;
        const right_ty = self.tc.expr_types.get(bin.right) orelse return null;
        const left_struct = self.structDeclForType(left_ty) orelse return null;
        const right_struct = self.structDeclForType(right_ty) orelse return null;
        if (left_struct != right_struct or left_struct.is_opaque or left_struct.is_union) return null;
        if (is_ord and !lowering_rules.structHasDerive(left_struct, "ord")) return null;

        const left_reg = try self.genExpr(bin.left);
        const right_reg = try self.genExpr(bin.right);

        const cmp_op: inst.OpKind = switch (bin.op) {
            .lt, .le => .slt,
            .gt, .ge => .sgt,
            else => .eq,
        };

        var acc: ?u32 = null; // eq: AND of field eqs; ord: OR of ordered terms
        var eq_prefix: ?u32 = null; // ord: AND of leading-field eqs

        for (left_struct.fields) |field| {
            const layout = lowering_rules.structFieldLayout(left_struct, field.name) orelse return Error.UnsupportedSabDirectFeature;
            const prim = storagePrimType(layout.ty) catch return Error.UnsupportedSabDirectFeature;
            const lhs = try self.intern(try self.newTmp());
            const rhs = try self.intern(try self.newTmp());
            try self.emitLoad(lhs, left_reg, layout.offset, prim);
            try self.emitLoad(rhs, right_reg, layout.offset, prim);

            if (is_eq) {
                const eq_reg = try self.intern(try self.newTmp());
                try self.emitOp(eq_reg, .eq, .{ .reg = lhs }, .{ .reg = rhs });
                if (acc) |prev| {
                    const next = try self.intern(try self.newTmp());
                    try self.emitOp(next, .@"and", .{ .reg = prev }, .{ .reg = eq_reg });
                    acc = next;
                } else {
                    acc = eq_reg;
                }
            } else {
                const cmp = try self.intern(try self.newTmp());
                try self.emitOp(cmp, cmp_op, .{ .reg = lhs }, .{ .reg = rhs });
                const eq_reg = try self.intern(try self.newTmp());
                try self.emitOp(eq_reg, .eq, .{ .reg = lhs }, .{ .reg = rhs });

                // term = (leading fields equal) AND (this field ordered)
                const term = if (eq_prefix) |prefix| blk: {
                    const t = try self.intern(try self.newTmp());
                    try self.emitOp(t, .@"and", .{ .reg = prefix }, .{ .reg = cmp });
                    break :blk t;
                } else cmp;

                acc = if (acc) |prev| blk: {
                    const next = try self.intern(try self.newTmp());
                    try self.emitOp(next, .@"or", .{ .reg = prev }, .{ .reg = term });
                    break :blk next;
                } else term;

                eq_prefix = if (eq_prefix) |prefix| blk: {
                    const next = try self.intern(try self.newTmp());
                    try self.emitOp(next, .@"and", .{ .reg = prefix }, .{ .reg = eq_reg });
                    break :blk next;
                } else eq_reg;
            }
        }

        const result = try self.intern(try self.newTmp());
        if (is_eq) {
            if (acc) |eq_all| {
                if (bin.op == .eq) {
                    try self.emitOp(result, .@"or", .{ .reg = eq_all }, .{ .imm_i64 = 0 });
                } else {
                    try self.emitOp(result, .ne, .{ .reg = eq_all }, .{ .imm_i64 = 1 });
                }
            } else {
                try self.emitAssignImm(result, if (bin.op == .eq) 1 else 0);
            }
        } else {
            if (acc) |ordered| {
                if (bin.op == .le or bin.op == .ge) {
                    const eq_all = eq_prefix orelse return Error.UnsupportedSabDirectFeature;
                    try self.emitOp(result, .@"or", .{ .reg = ordered }, .{ .reg = eq_all });
                } else {
                    try self.emitOp(result, .@"or", .{ .reg = ordered }, .{ .imm_i64 = 0 });
                }
            } else {
                try self.emitAssignImm(result, if (bin.op == .le or bin.op == .ge) 1 else 0);
            }
        }

        try self.releaseExprResultIfNeeded(bin.left, left_reg);
        try self.releaseExprResultIfNeeded(bin.right, right_reg);
        return result;
    }

    /// Derived `hash(value)` for a struct or primitive, mirroring SA-text
    /// `genHashValue`/`genHashCall`. FNV-1a style: seed with the 64-bit offset
    /// basis, then for each field `xor` the field hash and `mul` by the prime.
    /// Primitive fields hash to their own bit pattern (identity), matching
    /// SA-text `primitiveHashBits`. Pure straight-line ops, so no register
    /// crosses a control-flow merge.
    fn genHashCall(self: *Codegen, call: ast.CallExpr) anyerror!u32 {
        if (call.args.len != 1) return Error.UnsupportedSabDirectFeature;
        const ty = self.tc.expr_types.get(call.args[0]) orelse return Error.MissingType;
        const value_reg = try self.genExpr(@constCast(call.args[0]));
        const result = try self.genHashValue(value_reg, ty);
        try self.releaseExprResultIfNeeded(call.args[0], value_reg);
        return result;
    }

    fn genHashValue(self: *Codegen, value_reg: u32, ty: *const ast.Type) anyerror!u32 {
        if (ty.* == .primitive) {
            // primitiveHashBits is identity in SA-text; return the value itself.
            // Copy into a fresh temp so callers can release uniformly.
            const dst = try self.intern(try self.newTmp());
            try self.emitOp(dst, .add, .{ .reg = value_reg }, .{ .imm_i64 = 0 });
            return dst;
        }
        const decl = self.structDeclForType(ty) orelse return Error.UnsupportedSabDirectFeature;
        if (!lowering_rules.structHasDerive(decl, "hash") or decl.is_opaque or decl.is_union) return Error.UnsupportedSabDirectFeature;

        var hash_reg = try self.intern(try self.newTmp());
        try self.emitAssignImm(hash_reg, @bitCast(@as(u64, 1469598103934665603)));
        for (decl.fields) |field| {
            const layout = lowering_rules.structFieldLayout(decl, field.name) orelse return Error.UnsupportedSabDirectFeature;
            const prim = storagePrimType(layout.ty) catch return Error.UnsupportedSabDirectFeature;
            const field_reg = try self.intern(try self.newTmp());
            try self.emitLoad(field_reg, value_reg, layout.offset, prim);
            const field_hash = try self.genHashValue(field_reg, field.ty);
            const mixed = try self.intern(try self.newTmp());
            try self.emitOp(mixed, .xor, .{ .reg = hash_reg }, .{ .reg = field_hash });
            const next = try self.intern(try self.newTmp());
            try self.emitOp(next, .mul, .{ .reg = mixed }, .{ .imm_i64 = 1099511628211 });
            if (!self.isLocalReg(field_reg)) try self.emitRelease(field_reg);
            hash_reg = next;
        }
        return hash_reg;
    }

    /// FORMAT_PUSH_{suffix} selector for a primitive field type, mirroring
    /// SA-text `formatMacroSuffix`.
    fn debugFormatSuffix(ty: *const ast.Type) ?[]const u8 {
        return switch (ty.*) {
            .primitive => |p| switch (p) {
                .i8, .i16, .i32, .i64, .isize, .integer => "I64",
                .u8, .u16, .u32, .u64, .usize => "U64",
                .f32, .f64, .float => "F64",
                .boolean => "BOOL",
                else => null,
            },
            else => null,
        };
    }

    /// Push a constant byte string into the format buffer through the shared
    /// `FORMAT_PUSH_BYTES` std macro. A fresh utf8 const holds the bytes; its
    /// borrowed pointer plus static length feed the macro. Mirrors SA-text
    /// `emitFormatPushConstBytes`.
    fn emitFormatPushConstBytes(self: *Codegen, out_string: u32, bytes: []const u8) !void {
        if (bytes.len == 0) return;
        const label = try self.newStringConst();
        try self.appendUtf8Const(label, bytes);
        const ptr_reg = try self.intern(try self.newTmp());
        try self.emitBorrowSymbol(ptr_reg, label);
        const len_reg = try self.intern(try self.newTmp());
        try self.emitAssignImm(len_reg, @intCast(bytes.len));
        const tag = try self.newFormatTag();
        try self.emitStdMacroFragment("sa_std/string_format.sa", "FORMAT_PUSH_BYTES", &.{
            tag,
            self.symbols.items[out_string],
            self.symbols.items[ptr_reg],
            self.symbols.items[len_reg],
        });
        try self.emitRelease(len_reg);
        try self.emitRelease(ptr_reg);
    }

    fn emitFormatPushPrimitiveValue(self: *Codegen, out_string: u32, value_reg: u32, suffix: []const u8) !void {
        const buf = try self.intern(try self.newTmp());
        try self.emitStackAlloc(buf, 64);
        const len_slot = try self.intern(try self.newTmp());
        try self.emitStackAlloc(len_slot, 8);

        const ok = try self.intern(try self.newTmp());
        if (std.mem.eql(u8, suffix, "I64")) {
            try self.emitCallBody(ok, try std.fmt.allocPrint(self.allocator, "@sa_fmt_i64_into({s}, 10, {s}, 64, &{s})", .{ self.symbols.items[value_reg], self.symbols.items[buf], self.symbols.items[len_slot] }));
        } else if (std.mem.eql(u8, suffix, "U64")) {
            try self.emitCallBody(ok, try std.fmt.allocPrint(self.allocator, "@sa_fmt_u64_into({s}, 10, {s}, 64, &{s})", .{ self.symbols.items[value_reg], self.symbols.items[buf], self.symbols.items[len_slot] }));
        } else if (std.mem.eql(u8, suffix, "F64")) {
            try self.emitCallBody(ok, try std.fmt.allocPrint(self.allocator, "@sa_fmt_f64_into({s}, 6, {s}, 64, &{s})", .{ self.symbols.items[value_reg], self.symbols.items[buf], self.symbols.items[len_slot] }));
        } else if (std.mem.eql(u8, suffix, "BOOL")) {
            try self.emitCallBody(ok, try std.fmt.allocPrint(self.allocator, "@sa_fmt_bool_into({s}, {s}, 64, &{s})", .{ self.symbols.items[value_reg], self.symbols.items[buf], self.symbols.items[len_slot] }));
        } else {
            return Error.UnsupportedSabDirectFeature;
        }

        const fmt_len = try self.intern(try self.newTmp());
        try self.emitLoad(fmt_len, len_slot, 0, .u64);

        const tag = try self.newFormatTag();
        try self.emitStdMacroFragment("sa_std/string_format.sa", "FORMAT_PUSH_BYTES", &.{
            tag,
            self.symbols.items[out_string],
            self.symbols.items[buf],
            self.symbols.items[fmt_len],
        });

        try self.emitRelease(ok);
        try self.emitRelease(fmt_len);
        try self.markNonOwningReg(len_slot);
        try self.emitRelease(len_slot);
        try self.markNonOwningReg(buf);
        try self.emitRelease(buf);
    }

    /// Append the debug representation of `value_reg` (of type `ty`) into the
    /// format buffer `out_string`. Primitive fields push their formatted value;
    /// derived-debug structs recurse `Name { field: value, ... }`. Layout and
    /// field order are owned by the shared `lowering_rules` struct helpers, so
    /// SA-text and SAB agree. Mirrors SA-text `genDebugValue`.
    fn genDebugValue(self: *Codegen, out_string: u32, value_reg: u32, ty: *const ast.Type) anyerror!void {
        if (ty.* == .primitive) {
            const suffix = debugFormatSuffix(ty) orelse return Error.UnsupportedSabDirectFeature;
            try self.emitFormatPushPrimitiveValue(out_string, value_reg, suffix);
            return;
        }
        const decl = self.structDeclForType(ty) orelse return Error.UnsupportedSabDirectFeature;
        if (!lowering_rules.structHasDerive(decl, "debug") or decl.is_opaque or decl.is_union) return Error.UnsupportedSabDirectFeature;
        try self.emitFormatPushConstBytes(out_string, decl.name);
        try self.emitFormatPushConstBytes(out_string, " { ");
        for (decl.fields, 0..) |field, i| {
            if (i > 0) try self.emitFormatPushConstBytes(out_string, ", ");
            try self.emitFormatPushConstBytes(out_string, field.name);
            try self.emitFormatPushConstBytes(out_string, ": ");
            const layout = lowering_rules.structFieldLayout(decl, field.name) orelse return Error.UnsupportedSabDirectFeature;
            const prim = storagePrimType(layout.ty) catch return Error.UnsupportedSabDirectFeature;
            const field_reg = try self.intern(try self.newTmp());
            try self.emitLoad(field_reg, value_reg, layout.offset, prim);
            try self.genDebugValue(out_string, field_reg, field.ty);
            if (!self.isLocalReg(field_reg)) try self.emitRelease(field_reg);
        }
        try self.emitFormatPushConstBytes(out_string, " }");
    }

    /// `debug(value)` builtin: build a String (Vec<u8>-backed format buffer)
    /// holding the debug representation. Returns the owned buffer register.
    /// Mirrors SA-text `genDebugCall`.
    fn ensureDebugFormatDeps(self: *Codegen) !void {
        try self.ensureStdDeps("sa_std/string_format.sa", &.{
            "sa_vec_with_capacity",
            "sa_vec_reserve",
            "sa_vec_free",
            "sa_mem_copy",
            "sa_mem_set",
            "sa_fmt_i64_into",
            "sa_fmt_u64_into",
            "sa_fmt_f64_into",
            "sa_fmt_bool_into",
        });
    }

    fn ensurePrintlnDeps(self: *Codegen) !void {
        try self.ensureStdDeps("sa_std/io/print.sai", &.{"sa_print_bytes"});
        try self.ensureStdDeps("sa_std/fmt.sai", &.{
            "sa_fmt_i64",
            "sa_fmt_u64",
            "sa_fmt_f64",
            "sa_fmt_bool",
            "sa_fmt_buffer_data",
            "sa_fmt_buffer_len",
            "sa_fmt_buffer_free",
        });
    }

    fn emitPrintBytes(self: *Codegen, ptr_name: []const u8, len_name: []const u8) !void {
        try self.emitCallBody(null, try std.fmt.allocPrint(self.allocator, "@sa_print_bytes(&{s}, {s})", .{ ptr_name, len_name }));
    }

    fn emitPrintConstBytes(self: *Codegen, bytes_text: []const u8) !void {
        const bytes = try self.decodeStringLiteralBytes(bytes_text);
        defer self.allocator.free(bytes);
        if (bytes.len == 0) return;
        const label = try self.newStringConst();
        try self.appendUtf8Const(label, bytes);
        try self.emitPrintBytes(label, try std.fmt.allocPrint(self.allocator, "{}", .{bytes.len}));
    }

    fn emitPrintSliceValue(self: *Codegen, slice_reg: u32) !void {
        const ptr_reg = try self.intern(try self.newTmp());
        const len_reg = try self.intern(try self.newTmp());
        try self.emitLoad(ptr_reg, slice_reg, lowering_rules.SliceAbi.ptr_offset, .ptr);
        try self.emitLoad(len_reg, slice_reg, lowering_rules.SliceAbi.len_offset, .u64);
        try self.emitPrintBytes(self.symbols.items[ptr_reg], self.symbols.items[len_reg]);
        try self.emitRelease(len_reg);
        try self.emitRelease(ptr_reg);
    }

    fn emitPrintPrimitiveValue(self: *Codegen, value_reg: u32, format: lowering_rules.PrintPrimitiveFormat) !void {
        const fmt_buf = try self.intern(try self.newTmp());
        switch (format) {
            .signed_int => try self.emitCallBody(fmt_buf, try std.fmt.allocPrint(self.allocator, "@sa_fmt_i64({s}, 10)", .{self.symbols.items[value_reg]})),
            .unsigned_int => try self.emitCallBody(fmt_buf, try std.fmt.allocPrint(self.allocator, "@sa_fmt_u64({s}, 10)", .{self.symbols.items[value_reg]})),
            .float => try self.emitCallBody(fmt_buf, try std.fmt.allocPrint(self.allocator, "@sa_fmt_f64({s}, 10)", .{self.symbols.items[value_reg]})),
            .boolean => try self.emitCallBody(fmt_buf, try std.fmt.allocPrint(self.allocator, "@sa_fmt_bool({s})", .{self.symbols.items[value_reg]})),
        }

        const data_reg = try self.intern(try self.newTmp());
        try self.emitCallBody(data_reg, try std.fmt.allocPrint(self.allocator, "@sa_fmt_buffer_data({s})", .{self.symbols.items[fmt_buf]}));
        const len_reg = try self.intern(try self.newTmp());
        try self.emitCallBody(len_reg, try std.fmt.allocPrint(self.allocator, "@sa_fmt_buffer_len({s})", .{self.symbols.items[fmt_buf]}));
        const print_ptr = try self.intern(try self.newTmp());
        try self.emitAssignReg(print_ptr, data_reg);
        try self.emitPrintBytes(self.symbols.items[print_ptr], self.symbols.items[len_reg]);
        try self.emitCallBody(null, try std.fmt.allocPrint(self.allocator, "@sa_fmt_buffer_free(^{s})", .{self.symbols.items[fmt_buf]}));
        try self.emitRelease(print_ptr);
        try self.emitRelease(len_reg);
    }

    fn emitPrintlnArg(self: *Codegen, arg: *const ast.Node) !void {
        if (arg.* == .literal and arg.literal == .string_val) {
            try self.emitPrintConstBytes(arg.literal.string_val);
            return;
        }

        const arg_ty = self.tc.expr_types.get(arg);
        switch (lowering_rules.planPrintlnArg(arg_ty)) {
            .format_string => {
                const owner_reg = try self.genExpr(@constCast(arg));
                const slice_reg = try self.intern(try self.newTmp());
                try self.emitStdMacroFragment("sa_std/string.sa", "STRING_BUF_AS_STR", &.{ self.symbols.items[slice_reg], self.symbols.items[owner_reg] });
                try self.emitPrintSliceValue(slice_reg);
                try self.emitRelease(slice_reg);
                try self.releaseExprResultIfNeeded(arg, owner_reg);
            },
            .string_like => {
                const slice_reg = try self.genExpr(@constCast(arg));
                try self.emitPrintSliceValue(slice_reg);
                try self.releaseExprResultIfNeeded(arg, slice_reg);
            },
            .borrowed_primitive => |inner_ty| {
                const ptr_reg = try self.genExpr(@constCast(arg));
                const value_reg = try self.intern(try self.newTmp());
                try self.emitLoad(value_reg, ptr_reg, 0, try storagePrimType(inner_ty));
                const format = lowering_rules.printPrimitiveFormat(inner_ty) orelse return Error.UnsupportedSabDirectFeature;
                try self.emitPrintPrimitiveValue(value_reg, format);
                try self.emitRelease(value_reg);
                try self.releaseExprResultIfNeeded(arg, ptr_reg);
            },
            .boxed_primitive => |inner_ty| {
                const box_reg = try self.genExpr(@constCast(arg));
                const value_reg = try self.intern(try self.newTmp());
                try self.emitLoad(value_reg, box_reg, 0, try storagePrimType(inner_ty));
                const format = lowering_rules.printPrimitiveFormat(inner_ty) orelse return Error.UnsupportedSabDirectFeature;
                try self.emitPrintPrimitiveValue(value_reg, format);
                try self.emitRelease(value_reg);
                try self.releaseExprResultIfNeeded(arg, box_reg);
            },
            .primitive => |format| {
                const value_reg = try self.genExpr(@constCast(arg));
                try self.emitPrintPrimitiveValue(value_reg, format);
                try self.releaseExprResultIfNeeded(arg, value_reg);
            },
            .unsupported => return Error.UnsupportedSabDirectFeature,
        }
    }

    fn genPrintlnCall(self: *Codegen, call: ast.CallExpr) !u32 {
        if (call.associated_target != null) return Error.UnsupportedSabDirectFeature;
        try self.ensurePrintlnDeps();
        if (call.args.len == 0 or call.args[0].* != .literal or call.args[0].literal != .string_val) {
            try self.emitPrintConstBytes("\\n");
        } else {
            const fmt = call.args[0].literal.string_val;
            var arg_idx: usize = 1;
            var i: usize = 0;
            while (i <= fmt.len) {
                const start = i;
                while (i < fmt.len and !(fmt[i] == '{' and i + 1 < fmt.len and fmt[i + 1] == '}')) : (i += 1) {}
                if (i > start) try self.emitPrintConstBytes(fmt[start..i]);
                if (i >= fmt.len) break;
                if (arg_idx >= call.args.len) break;
                try self.emitPrintlnArg(call.args[arg_idx]);
                arg_idx += 1;
                i += 2;
            }
            try self.emitPrintConstBytes("\\n");
        }

        const sentinel = try self.intern(try self.newTmp());
        try self.emitAssignImm(sentinel, 0);
        return sentinel;
    }

    fn genDebugCall(self: *Codegen, call: ast.CallExpr) anyerror!?u32 {
        if (call.args.len != 1) return Error.UnsupportedSabDirectFeature;
        const ty = self.tc.expr_types.get(call.args[0]) orelse return Error.MissingType;
        // The FORMAT_* macros call runtime helpers that must be declared before
        // the emitted call sites. Preload the full set the debug path can reach.
        try self.ensureDebugFormatDeps();
        const out_string = try self.intern(try self.newTmp());
        try self.recordReg(out_string);
        try self.emitStdMacroFragment("sa_std/string_format.sa", "FORMAT_BEGIN", &.{
            self.symbols.items[out_string],
            "128",
        });
        const value_reg = try self.genExpr(@constCast(call.args[0]));
        try self.genDebugValue(out_string, value_reg, ty);
        try self.releaseExprResultIfNeeded(call.args[0], value_reg);
        return out_string;
    }

    fn genCast(self: *Codegen, cast: ast.CastExpr) anyerror!u32 {
        const src_ast_ty = self.tc.expr_types.get(cast.expr) orelse return Error.MissingType;
        const src_ty = try primType(src_ast_ty);
        const dst_ty = try primType(cast.ty);
        const src = try self.genExpr(cast.expr);

        if (!isNumericType(src_ast_ty) or !isNumericType(cast.ty)) {
            if (src_ty == .ptr and dst_ty == .ptr) {
                const dst = try self.intern(try self.newTmp());
                try self.recordReg(dst);
                var item = self.makeInst(.op);
                item.op_kind = .bitcast;
                item.operands[0] = .{ .reg = dst };
                item.operands[1] = .{ .reg = src };
                item.operands[2] = .{ .ty = @intFromEnum(dst_ty) };
                try self.appendInst(item);
                if (!self.isLocalReg(src)) try self.emitRelease(src);
                return dst;
            }
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

    fn genUnsafeExpr(self: *Codegen, expr: *const ast.Node, unsafe_expr: ast.UnsafeExpr) anyerror!u32 {
        const result_ty = self.tc.expr_types.get(expr) orelse return Error.MissingType;
        if (isVoidType(result_ty)) return Error.UnsupportedSabDirectFeature;

        const block_locals_len = self.locals.items.len;
        const result_slot = try self.intern(try self.newTmp());
        try self.emitAlloc(result_slot, typeSize(result_ty));
        try self.prepareResultSlotRefCellCompanion(result_slot, result_ty);

        const terminated = try self.genBlockTailValueStore(unsafe_expr.body, result_slot, result_ty);
        if (terminated) {
            const result = try self.intern(try self.newTmp());
            try self.recordReg(result);
            return result;
        }

        try self.releaseLocalsFrom(block_locals_len, null);
        const result = try self.intern(try self.newTmp());
        try self.emitLoad(result, result_slot, 0, try primType(result_ty));
        try self.loadResultSlotTransferredValue(result, result_slot, result_ty);
        try self.emitRelease(result_slot);
        return result;
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
        var source = try self.addressWithOffset(base, layout.offset);
        if (layout.offset != 0 and !self.isLocalReg(base)) source.release_regs = try self.singleReleaseReg(base);
        return source;
    }

    fn genVecOwnerReceiver(self: *Codegen, target: *ast.Node) anyerror!AddressSource {
        if (target.* == .field_expr) {
            const projection = try self.genFieldAddress(target.field_expr);
            const owner = try self.intern(try self.newTmp());
            try self.emitLoad(owner, projection.reg, 0, .ptr);
            try self.markNonOwningReg(owner);
            try self.releaseAddressSource(projection);
            return .{ .reg = owner };
        }

        const target_reg = try self.genExpr(target);
        return .{ .reg = target_reg };
    }

    fn releaseAddressSource(self: *Codegen, source: AddressSource) anyerror!void {
        if (!self.isLocalReg(source.reg)) try self.emitRelease(source.reg);
        for (source.release_regs) |release_reg| try self.emitRelease(release_reg);
    }

    fn genIndexAddress(self: *Codegen, idx: ast.IndexExpr) anyerror!AddressSource {
        const target_ty = self.tc.expr_types.get(idx.target) orelse return Error.MissingType;
        const addressable_target_ty = lowering_rules.ordinaryIndexAddressTargetType(target_ty);
        if (addressable_target_ty == null or addressable_target_ty.?.* != .array) {
            if (addressable_target_ty) |ordinary_target_ty| {
                if (ordinary_target_ty.* == .user_defined and std.mem.eql(u8, ordinary_target_ty.user_defined.name, "Slice")) {
                    const elem_ty = ordinary_target_ty.user_defined.generics[0];
                    const target_reg = try self.genExpr(idx.target);
                    const base_ptr = try self.intern(try self.newTmp());
                    try self.emitLoad(base_ptr, target_reg, lowering_rules.SliceAbi.ptr_offset, .ptr);

                    if (idx.index.* == .literal and idx.index.literal == .int_val) {
                        const raw_index = idx.index.literal.int_val;
                        if (raw_index < 0) return Error.UnsupportedSabDirectFeature;
                        var source = try self.addressWithOffset(base_ptr, typeSize(elem_ty) * @as(usize, @intCast(raw_index)));
                        var release_regs = std.ArrayList(u32).init(self.allocator);
                        defer release_regs.deinit();
                        if (source.reg != base_ptr and !self.isLocalReg(base_ptr)) try release_regs.append(base_ptr);
                        if (!self.isLocalReg(target_reg)) try release_regs.append(target_reg);
                        source.release_regs = try self.ownedReleaseRegs(release_regs.items);
                        return source;
                    }

                    const index_reg = try self.genExpr(idx.index);
                    const offset = try self.intern(try self.newTmp());
                    try self.emitOp(offset, .mul, .{ .reg = index_reg }, .{ .imm_i64 = @intCast(typeSize(elem_ty)) });
                    const elem_ptr = try self.intern(try self.newTmp());
                    try self.emitPtrAdd(elem_ptr, base_ptr, .{ .reg = offset });
                    try self.emitRelease(offset);
                    if (!self.isLocalReg(base_ptr)) try self.emitRelease(base_ptr);
                    if (!self.isLocalReg(index_reg)) try self.emitRelease(index_reg);
                    return .{
                        .reg = elem_ptr,
                        .release_regs = if (!self.isLocalReg(target_reg)) try self.singleReleaseReg(target_reg) else &.{},
                    };
                }
            }
            const elem_ty = firstGenericArg(target_ty) orelse return Error.UnsupportedSabDirectFeature;
            if (lowering_rules.smartPointerType(elem_ty) == null) return Error.UnsupportedSabDirectFeature;
            const target_type_name = typeBaseName(target_ty) orelse return Error.UnsupportedSabDirectFeature;
            const rule = self.findStdSurfaceRule(.index_address, target_type_name, null) orelse return Error.UnsupportedSabDirectFeature;
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
            return .{ .reg = dst };
        }
        const target_reg = try self.genExpr(idx.target);
        if (idx.index.* == .literal and idx.index.literal == .int_val) {
            const raw_index = idx.index.literal.int_val;
            if (raw_index < 0) return Error.UnsupportedSabDirectFeature;
            const layout = arrayElementLayout(addressable_target_ty.?.array, @intCast(raw_index)) orelse return Error.UnsupportedSabDirectFeature;
            var source = try self.addressWithOffset(target_reg, layout.offset);
            if (layout.offset != 0 and !self.isLocalReg(target_reg)) source.release_regs = try self.singleReleaseReg(target_reg);
            return source;
        }

        const index_reg = try self.genExpr(idx.index);
        const elem_ptr = try self.genArrayElementPtr(addressable_target_ty.?.array, target_reg, index_reg);
        if (elem_ptr.offset) |offset| try self.emitRelease(offset);
        if (!self.isLocalReg(index_reg)) try self.emitRelease(index_reg);
        return .{
            .reg = elem_ptr.ptr,
            .release_regs = if (!self.isLocalReg(target_reg)) try self.singleReleaseReg(target_reg) else &.{},
        };
    }

    fn genSmartPointerGet(self: *Codegen, source_ty: *const ast.Type, source: u32) anyerror!?u32 {
        switch (lowering_rules.planSmartPointerGetAction(source_ty)) {
            .unsupported => return null,
            .dyn_box_identity => return source,
            .get_value => {},
        }
        const receiver = if (lowering_rules.smartPointerReceiverNeedsLoad(source_ty)) blk: {
            const loaded = try self.intern(try self.newTmp());
            try self.emitLoad(loaded, source, 0, .ptr);
            try self.markNonOwningReg(loaded);
            break :blk loaded;
        } else source;
        const dst = try self.intern(try self.newTmp());
        try self.emitStdSurfaceMethod(source_ty, "get", dst, receiver);
        try self.markNonOwningReg(dst);
        if (receiver != source and !self.isLocalReg(receiver)) try self.emitRelease(receiver);
        return dst;
    }

    fn genSmartPointerValueSlot(self: *Codegen, source_ty: *const ast.Type, source: u32) anyerror!?u32 {
        switch (lowering_rules.planSmartPointerValueSlotAction(source_ty)) {
            .unsupported => return null,
            .as_ptr_slot => {},
        }
        const receiver = if (lowering_rules.smartPointerReceiverNeedsLoad(source_ty)) blk: {
            const loaded = try self.intern(try self.newTmp());
            try self.emitLoad(loaded, source, 0, .ptr);
            try self.markNonOwningReg(loaded);
            break :blk loaded;
        } else source;
        const dst = try self.intern(try self.newTmp());
        try self.emitStdSurfaceMethod(source_ty, "as_ptr", dst, receiver);
        if (receiver != source and !self.isLocalReg(receiver)) try self.emitRelease(receiver);
        return dst;
    }

    fn genSmartPointerAddressSource(self: *Codegen, source_ty: *const ast.Type, source: u32) anyerror!?AddressSource {
        const action = lowering_rules.planSmartPointerAddressAction(source_ty);
        if (action == .unsupported) return null;
        if (action == .dyn_box_identity) return .{ .reg = source };

        const receiver = if (lowering_rules.smartPointerReceiverNeedsLoad(source_ty)) blk: {
            const loaded = try self.intern(try self.newTmp());
            try self.emitLoad(loaded, source, 0, .ptr);
            break :blk loaded;
        } else source;

        var release_regs = std.ArrayList(u32).init(self.allocator);
        defer release_regs.deinit();

        const slot = try self.intern(try self.newTmp());
        try self.emitStdSurfaceMethod(source_ty, "as_ptr", slot, receiver);
        if (action == .as_ptr_take_pointer_backed_value) {
            const value = try self.intern(try self.newTmp());
            try self.emitTake(value, slot, 0, .ptr);
            try release_regs.append(slot);
            if (receiver != source and !self.isLocalReg(receiver)) try release_regs.append(receiver);
            if (!self.isLocalReg(source) and source != receiver) try release_regs.append(source);
            if (source == receiver and !self.isLocalReg(source)) try release_regs.append(source);
            return .{
                .reg = value,
                .release_regs = try self.ownedReleaseRegs(release_regs.items),
                .restore_slot = slot,
            };
        }

        if (receiver != source and !self.isLocalReg(receiver)) try release_regs.append(receiver);
        if (!self.isLocalReg(source) and source != receiver) try release_regs.append(source);
        if (source == receiver and !self.isLocalReg(source)) try release_regs.append(source);
        return .{ .reg = slot, .release_regs = try self.ownedReleaseRegs(release_regs.items) };
    }

    fn genDerefAddressFallback(self: *Codegen, source_ty: *const ast.Type, source: u32) anyerror!AddressSource {
        if (try self.genSmartPointerAddressSource(source_ty, source)) |address| return address;
        if (try self.genSmartPointerValueSlot(source_ty, source)) |slot| {
            if (!self.isLocalReg(source)) try self.emitRelease(source);
            return .{ .reg = slot };
        }
        if (try self.genSmartPointerGet(source_ty, source)) |value| {
            if (value != source and !self.isLocalReg(source)) try self.emitRelease(source);
            return .{ .reg = value };
        }
        return .{ .reg = source };
    }

    fn genAddressOf(self: *Codegen, expr: *ast.Node) anyerror!AddressSource {
        var deref_source_ty: ?*const ast.Type = null;
        var index_target_ty: ?*const ast.Type = null;
        switch (expr.*) {
            .deref_expr => |deref| deref_source_ty = self.tc.expr_types.get(deref.expr) orelse return Error.MissingType,
            .index_expr => |idx| index_target_ty = self.tc.expr_types.get(idx.target) orelse return Error.MissingType,
            else => {},
        }
        const address_plan = lowering_rules.planAddressOf(expr, .{
            .deref_source_ty = deref_source_ty,
            .index_target_ty = index_target_ty,
        });
        return switch (address_plan.shape) {
            .identifier => blk: {
                const name = if (expr.* == .identifier) expr.identifier else return Error.UnsupportedSabDirectFeature;
                if (self.stackLocal(name)) |slot| break :blk .{ .reg = slot.reg };
                break :blk .{ .reg = try self.genExpr(expr) };
            },
            .deref_borrow_or_pointer => blk: {
                const source = try self.genExpr(expr.deref_expr.expr);
                break :blk .{ .reg = source };
            },
            .deref_smart_pointer => blk: {
                const source_ty = deref_source_ty orelse return Error.MissingType;
                const source = try self.genExpr(expr.deref_expr.expr);
                break :blk try self.genDerefAddressFallback(source_ty, source);
            },
            .field => blk: {
                if (expr.* != .field_expr) return Error.UnsupportedSabDirectFeature;
                break :blk try self.genFieldAddress(expr.field_expr);
            },
            .index => blk: {
                if (expr.* != .index_expr) return Error.UnsupportedSabDirectFeature;
                break :blk try self.genIndexAddress(expr.index_expr);
            },
            .value_temp => blk: {
                if (expr.* == .index_expr) break :blk try self.genIndexAddress(expr.index_expr);
                if (expr.* != .deref_expr) break :blk .{ .reg = try self.genExpr(expr) };
                const deref = expr.deref_expr;
                const source_ty = deref_source_ty orelse return Error.MissingType;
                const source = try self.genExpr(deref.expr);
                break :blk try self.genDerefAddressFallback(source_ty, source);
            },
        };
    }

    fn genAssociatedValueArg(
        self: *Codegen,
        target_name: []const u8,
        member_name: []const u8,
        arg: *ast.Node,
    ) anyerror!u32 {
        if (lowering_rules.associatedRuleNeedsUnderlyingSmartPointer(target_name, member_name)) {
            if (arg.* == .borrow_expr) {
                return try self.genExpr(@constCast(arg.borrow_expr.expr));
            }
        }
        return try self.genExpr(arg);
    }

    fn genBorrow(self: *Codegen, borrow: ast.BorrowExpr) anyerror!u32 {
        const source = try self.genAddressOf(borrow.expr);
        const dst = try self.intern(try self.newTmp());
        try self.emitBorrowReg(dst, source.reg, "read");
        try self.rememberBorrowAddressTemps(dst, source);
        return dst;
    }

    fn genMove(self: *Codegen, move: ast.MoveExpr) anyerror!u32 {
        const source = try self.genExpr(move.expr);
        try self.markConsumed(source);
        return source;
    }

    fn genDeref(self: *Codegen, expr: *const ast.Node, deref: ast.DerefExpr) anyerror!u32 {
        const deref_ty = self.tc.expr_types.get(expr) orelse return Error.MissingType;
        const source_ty = self.tc.expr_types.get(deref.expr) orelse return Error.MissingType;
        const source = try self.genExpr(deref.expr);
        if (try self.genSmartPointerGet(source_ty, source)) |value| {
            if (value != source and !self.isLocalReg(source)) try self.emitRelease(source);
            return value;
        }
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

    fn genDynConcreteFatPointer(self: *Codegen, source_expr: *ast.Node, trait_name: []const u8) anyerror!u32 {
        const source_ty = self.tc.expr_types.get(source_expr) orelse return Error.MissingType;
        const type_name = concreteTypeName(source_ty) orelse return Error.UnsupportedSabDirectFeature;
        const data_reg = try self.genExpr(source_expr);
        const vtable_reg = try self.intern(try self.newTmp());
        const vt_name = try self.vtableName(trait_name, type_name);
        try self.emitBorrowSymbol(vtable_reg, vt_name);

        const fat_reg = try self.intern(try self.newTmp());
        try self.emitDynNew(fat_reg, data_reg, vtable_reg);
        try self.emitRelease(vtable_reg);
        try self.releaseExprResultIfNeeded(source_expr, data_reg);
        return fat_reg;
    }

    fn genExprWithoutDynCoercion(self: *Codegen, expr: *ast.Node) anyerror!u32 {
        if (expr.* == .call_expr) return try self.genCall(expr, expr.call_expr);
        return try self.genExpr(expr);
    }

    fn genDynBoxCoercionExpr(self: *Codegen, expr: *ast.Node, trait_name: []const u8) anyerror!u32 {
        const expr_ty = self.tc.expr_types.get(expr) orelse return Error.MissingType;
        const inner_ty = lowering_rules.boxInnerType(expr_ty) orelse return Error.UnsupportedSabDirectFeature;
        const type_name = concreteTypeName(inner_ty) orelse return Error.UnsupportedSabDirectFeature;
        const box_reg = try self.genExprWithoutDynCoercion(expr);

        const data_reg = try self.intern(try self.newTmp());
        try self.emitStdSurfaceMethod(expr_ty, "get", data_reg, box_reg);

        const vtable_reg = try self.intern(try self.newTmp());
        const vt_name = try self.vtableName(trait_name, type_name);
        try self.emitBorrowSymbol(vtable_reg, vt_name);

        const fat_reg = try self.intern(try self.newTmp());
        try self.emitDynNew(fat_reg, data_reg, vtable_reg);
        try self.emitRelease(vtable_reg);
        try self.releaseNonLocalTemps(&.{ data_reg, box_reg });
        return fat_reg;
    }

    fn genDynRcCoercionExpr(self: *Codegen, expr: *ast.Node, trait_name: []const u8) anyerror!u32 {
        if (expr.* != .call_expr) return Error.UnsupportedSabDirectFeature;
        const call = expr.call_expr;
        if (call.args.len != 1) return Error.UnsupportedSabDirectFeature;

        const fat_reg = try self.genDynConcreteFatPointer(@constCast(call.args[0]), trait_name);
        const rule = self.findStdSurfaceRule(.associated, "Rc", "new") orelse return Error.UnsupportedSabDirectFeature;
        const rc_reg = try self.intern(try self.newTmp());
        try self.recordReg(rc_reg);
        const expr_ty = self.tc.expr_types.get(expr) orelse return Error.MissingType;
        try self.emitStdSurfaceRule(rule, .{
            .out = rc_reg,
            .value = fat_reg,
            .elem_size = self.elementSlotSize(expr_ty),
        });
        try self.releaseNonLocalTemps(&.{fat_reg});
        return rc_reg;
    }

    fn genDynCoercionExpr(self: *Codegen, expr: *ast.Node, plan: lowering_rules.DynCoercionPlan) anyerror!u32 {
        return switch (plan.kind) {
            .box_to_dyn => try self.genDynBoxCoercionExpr(expr, plan.trait_name),
            .rc_new_to_dyn_rc => try self.genDynRcCoercionExpr(expr, plan.trait_name),
        };
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
        const receiver_ty = self.tc.expr_types.get(call.args[0]) orelse return Error.MissingType;
        const receiver_reg = try self.genExpr(@constCast(call.args[0]));
        var dyn_reg = receiver_reg;
        if (lowering_rules.planDynDispatchReceiver(receiver_ty)) |receiver_plan| {
            switch (receiver_plan.kind) {
                .direct_dyn => {},
                .rc_get_dyn => {
                    dyn_reg = try self.intern(try self.newTmp());
                    try self.emitStdSurfaceMethod(receiver_ty, "get", dyn_reg, receiver_reg);
                },
            }
        }
        const data_reg = try self.intern(try self.newTmp());
        const vtable_reg = try self.intern(try self.newTmp());
        const fn_reg = try self.intern(try self.newTmp());
        const dst = try self.intern(try self.newTmp());
        try self.recordReg(data_reg);
        try self.recordReg(vtable_reg);
        try self.recordReg(fn_reg);
        try self.recordReg(dst);
        try self.emitStdMacroFragment("sa_std/core/trait_object.sa", "DYN_GET_DATA", &.{ self.symbols.items[data_reg], self.symbols.items[dyn_reg] });
        try self.emitStdMacroFragment("sa_std/core/trait_object.sa", "DYN_GET_VTABLE", &.{ self.symbols.items[vtable_reg], self.symbols.items[dyn_reg] });
        try self.emitLoad(fn_reg, vtable_reg, slot, .ptr);

        var body = std.ArrayList(u8).init(self.allocator);
        try body.writer().print("{s}(&{s})", .{ self.symbols.items[fn_reg], self.symbols.items[data_reg] });
        var item = self.makeInst(.call_indirect);
        item.operands[0] = .{ .reg = dst };
        item.operands[1] = .{ .text = try body.toOwnedSlice() };
        try self.recordCallBodyRegs(item.operands[1].text);
        try self.appendInst(item);

        try self.emitRelease(fn_reg);
        try self.emitRelease(vtable_reg);
        try self.emitRelease(data_reg);
        if (dyn_reg != receiver_reg and !self.isLocalReg(dyn_reg)) try self.emitRelease(dyn_reg);
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
        var capture_summary = lowering_rules.EscapedClosureCaptureSummary{};
        for (captures) |capture| {
            capture_summary = lowering_rules.accumulateEscapedClosureCapture(
                capture_summary,
                capture.ty,
                self.typeIsCopyValue(capture.ty),
            );
        }
        const execution_plan = lowering_rules.planEscapedClosureExecution(capture_summary);

        const entry = EscapedClosureEntry{
            .worker_name = try std.fmt.allocPrint(self.allocator, "sla_thread_worker_{}", .{idx}),
            .spawn_name = try std.fmt.allocPrint(self.allocator, "sla_thread_spawn_{}", .{idx}),
            .vtable_name = try std.fmt.allocPrint(self.allocator, "SLA_THREAD_VT_{}", .{idx}),
            .closure = closure,
            .ret_ty = ret_ty,
            .captures = captures,
            .slot_size = slot_size,
            .inline_join = execution_plan.inline_join,
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

        if (entry.inline_join) {
            const value = try self.genExpr(@constCast(entry.closure.body));
            try self.emitStore(slot, 8, value, try primType(entry.ret_ty));
            if (!self.isLocalReg(value) and !self.released_regs.contains(value)) try self.emitMove(value);

            const sentinel = try self.intern(try self.newTmp());
            try self.emitAssignImm(sentinel, -1);
            try self.emitStore(slot, 0, sentinel, .i32);
            try self.emitRelease(sentinel);
            return slot;
        }

        for (entry.captures) |capture| {
            const capture_reg = self.localReg(capture.name) orelse return Error.UnsupportedSabDirectFeature;
            const capture_plan = lowering_rules.planEscapedClosureCapture(capture.ty, self.typeIsCopyValue(capture.ty));
            if (capture.ty.* == .fn_ptr) {
                const target = try self.intern(try self.newTmp());
                try self.emitLoad(target, capture_reg, 0, .ptr);
                try self.emitStore(slot, capture.offset, target, .ptr);
                try self.emitMove(target);
            } else {
                var capture_value = capture_reg;
                const loaded_from_slot = self.stack_alloc_emitted.contains(capture_reg);
                if (loaded_from_slot) {
                    capture_value = try self.intern(try self.newTmp());
                    try self.emitLoad(capture_value, capture_reg, 0, try storagePrimType(capture.ty));
                }
                try self.emitStore(slot, capture.offset, capture_value, try storagePrimType(capture.ty));
                if (loaded_from_slot) {
                    if (capture_plan.consumes_source) {
                        try self.emitMove(capture_value);
                        try self.emitRelease(capture_reg);
                    } else {
                        try self.emitRelease(capture_value);
                    }
                }
            }
            if (capture_plan.consumes_source and !self.stack_alloc_emitted.contains(capture_reg)) try self.emitMove(capture_reg);
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
        const result_reg = try self.intern(try self.newTmp());
        const inner_prim = try storagePrimType(inner_ty);
        try self.emitLoad(handle, recv_reg, 0, .i32);

        const is_inline = try self.intern(try self.newTmp());
        try self.emitOp(is_inline, .eq, .{ .reg = handle }, .{ .imm_i64 = -1 });
        const inline_label = try self.newLabel("L_THREAD_JOIN_INLINE");
        const pthread_label = try self.newLabel("L_THREAD_JOIN_PTHREAD");
        const ok_label = try self.newLabel("L_THREAD_JOIN_OK");
        const err_label = try self.newLabel("L_THREAD_JOIN_ERR");
        const end_label = try self.newLabel("L_THREAD_JOIN_END");
        var inline_br = self.makeInst(.br);
        inline_br.operands[0] = .{ .reg = is_inline };
        inline_br.operands[1] = .{ .label = try self.intern(inline_label) };
        inline_br.operands[2] = .{ .label = try self.intern(inline_label) };
        inline_br.operands[3] = .{ .label = try self.intern(pthread_label) };
        try self.appendInst(inline_br);

        try self.emitLabel(inline_label);
        try self.emitBranchRelease(is_inline);
        const inline_value = try self.intern(try self.newTmp());
        try self.emitLoad(inline_value, recv_reg, 8, inner_prim);
        try self.emitAlloc(result_reg, 24);
        const inline_ok_tag = try self.intern(try self.newTmp());
        try self.emitAssignImm(inline_ok_tag, 0);
        try self.emitStore(result_reg, 0, inline_ok_tag, .u64);
        try self.emitStore(result_reg, 8, inline_value, inner_prim);
        try self.emitStore(result_reg, 16, inline_ok_tag, .u64);
        try self.emitRelease(inline_ok_tag);
        if ((try primType(inner_ty)) == .ptr) {
            try self.emitMove(inline_value);
        } else {
            try self.emitRelease(inline_value);
        }
        try self.emitJmp(end_label);

        try self.emitLabel(pthread_label);
        try self.emitBranchRelease(is_inline);
        const status = try self.intern(try self.newTmp());
        const is_ok = try self.intern(try self.newTmp());

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
        var br = self.makeInst(.br);
        br.operands[0] = .{ .reg = is_ok };
        br.operands[1] = .{ .label = try self.intern(ok_label) };
        br.operands[2] = .{ .label = try self.intern(ok_label) };
        br.operands[3] = .{ .label = try self.intern(err_label) };
        try self.appendInst(br);

        try self.emitLabel(ok_label);
        try self.emitBranchRelease(is_ok);
        const value = try self.intern(try self.newTmp());
        try self.emitLoad(value, recv_reg, 8, inner_prim);
        try self.emitAlloc(result_reg, 24);
        const ok_tag = try self.intern(try self.newTmp());
        try self.emitAssignImm(ok_tag, 0);
        try self.emitStore(result_reg, 0, ok_tag, .u64);
        try self.emitStore(result_reg, 8, value, inner_prim);
        try self.emitStore(result_reg, 16, ok_tag, .u64);
        try self.emitRelease(ok_tag);
        if ((try primType(inner_ty)) == .ptr) {
            try self.emitMove(value);
        } else {
            try self.emitRelease(value);
        }
        try self.emitRelease(status);
        try self.emitJmp(end_label);

        try self.emitLabel(err_label);
        try self.emitBranchRelease(is_ok);
        const err_value = try self.intern(try self.newTmp());
        try self.emitOp(err_value, .add, .{ .reg = status }, .{ .imm_i64 = 0 });
        try self.emitAlloc(result_reg, 24);
        const err_tag = try self.intern(try self.newTmp());
        try self.emitAssignImm(err_tag, 1);
        const err_zero = try self.intern(try self.newTmp());
        try self.emitAssignImm(err_zero, 0);
        try self.emitStore(result_reg, 0, err_tag, .u64);
        try self.emitStore(result_reg, 8, err_zero, inner_prim);
        try self.emitStore(result_reg, 16, err_value, .i64);
        try self.emitRelease(err_zero);
        try self.emitRelease(err_tag);
        try self.emitRelease(err_value);
        try self.emitRelease(status);
        try self.emitJmp(end_label);

        try self.emitLabel(end_label);
        try self.emitRelease(handle);
        try self.emitRelease(recv_reg);
        return result_reg;
    }

    fn genResultUnwrap(self: *Codegen, expr: *const ast.Node, call: ast.CallExpr) anyerror!?u32 {
        if (call.associated_target != null or !std.mem.eql(u8, call.func_name, "unwrap") or call.args.len != 1) return null;
        const receiver_ty = self.tc.expr_types.get(call.args[0]) orelse return null;
        const ok_ty = lowering_rules.resultOkType(receiver_ty) orelse return null;
        _ = expr;

        const receiver_reg = try self.genExpr(@constCast(call.args[0]));
        const tag = try self.intern(try self.newTmp());
        const is_ok = try self.intern(try self.newTmp());
        const dst = try self.intern(try self.newTmp());
        const ok_prim = try storagePrimType(ok_ty);
        try self.emitLoad(tag, receiver_reg, 0, .u64);
        try self.emitOp(is_ok, .eq, .{ .reg = tag }, .{ .imm_i64 = 0 });

        const ok_label = try self.newLabel("L_RESULT_UNWRAP_OK");
        const err_label = try self.newLabel("L_RESULT_UNWRAP_ERR");
        const end_label = try self.newLabel("L_RESULT_UNWRAP_END");
        try self.emitBranch(is_ok, ok_label, err_label);

        try self.emitLabel(ok_label);
        try self.emitBranchRelease(is_ok);
        try self.emitLoad(dst, receiver_reg, 8, ok_prim);
        if (ok_prim == .ptr) {
            const zero = try self.intern(try self.newTmp());
            try self.emitAssignImm(zero, 0);
            try self.emitStore(receiver_reg, 8, zero, ok_prim);
            try self.emitRelease(zero);
        }
        try self.emitBranchRelease(tag);
        try self.emitJmp(end_label);

        try self.emitLabel(err_label);
        try self.emitBranchRelease(is_ok);
        try self.emitPanicCode(17);
        try self.emitAssignImm(dst, 0);
        try self.emitBranchRelease(tag);
        try self.emitJmp(end_label);

        try self.emitLabel(end_label);
        if (!self.isLocalReg(receiver_reg)) try self.emitRelease(receiver_reg);
        return dst;
    }

    fn emitBranch(self: *Codegen, cond: u32, then_label: []const u8, else_label: []const u8) !void {
        var br = self.makeInst(.br);
        br.operands[0] = .{ .reg = cond };
        br.operands[1] = .{ .label = try self.intern(then_label) };
        br.operands[2] = .{ .label = try self.intern(then_label) };
        br.operands[3] = .{ .label = try self.intern(else_label) };
        try self.appendInst(br);
    }

    fn emitStdSurfaceMethod(self: *Codegen, receiver_ty: *const ast.Type, member_name: []const u8, out: u32, receiver: u32) !void {
        const type_name = typeBaseName(receiver_ty) orelse return Error.UnsupportedSabDirectFeature;
        const rule = self.findStdSurfaceRule(.method, type_name, member_name) orelse return Error.UnsupportedSabDirectFeature;
        try self.recordReg(out);
        try self.emitStdSurfaceRule(rule, .{
            .out = out,
            .receiver = receiver,
            .elem_size = self.elementSlotSize(receiver_ty),
        });
    }

    fn emitStdOptionMethod(self: *Codegen, receiver_ty: *const ast.Type, member_name: []const u8, out: u32, receiver: u32) !void {
        try self.emitStdSurfaceMethod(receiver_ty, member_name, out, receiver);
    }

    fn emitStdOptionConstructor(self: *Codegen, result_ty: *const ast.Type, member_name: []const u8, out: u32, value: ?u32) !void {
        const type_name = typeBaseName(result_ty) orelse return Error.UnsupportedSabDirectFeature;
        const rule = self.findStdSurfaceRule(.constructor, type_name, member_name) orelse return Error.UnsupportedSabDirectFeature;
        try self.recordReg(out);
        try self.emitStdSurfaceRule(rule, .{
            .out = out,
            .value = value,
            .elem_size = self.elementSlotSize(result_ty),
        });
    }

    fn genOptionMapClosureCall(self: *Codegen, expr: *const ast.Node, call: ast.CallExpr, receiver_ty: *const ast.Type, closure: *const ast.ClosureLiteral) anyerror!u32 {
        const result_ty = self.tc.expr_types.get(expr) orelse return Error.MissingType;
        const receiver_reg = try self.genExpr(@constCast(call.args[0]));
        const is_some = try self.intern(try self.newTmp());
        try self.emitStdOptionMethod(receiver_ty, "is_some", is_some, receiver_reg);

        const some_label = try self.newLabel("L_OPTION_MAP_SOME");
        const none_label = try self.newLabel("L_OPTION_MAP_NONE");
        const end_label = try self.newLabel("L_OPTION_MAP_END");
        const result_reg = try self.intern(try self.newTmp());
        try self.recordReg(result_reg);
        try self.emitBranch(is_some, some_label, none_label);

        const branch_locals_len = self.locals.items.len;
        var pre_released = try self.released_regs.clone();
        defer pre_released.deinit();

        try self.emitLabel(some_label);
        try self.emitBranchRelease(is_some);
        const value_reg = try self.intern(try self.newTmp());
        try self.emitStdOptionMethod(receiver_ty, "get", value_reg, receiver_reg);
        const mapped_reg = try self.genInlineClosureUnary(closure, value_reg);
        try self.emitStdOptionConstructor(result_ty, "Some", result_reg, mapped_reg);
        if (!self.isLocalReg(value_reg)) try self.emitRelease(value_reg);
        if (mapped_reg != value_reg and !self.isLocalReg(mapped_reg)) try self.emitRelease(mapped_reg);
        try self.emitJmp(end_label);
        var then_released = try self.released_regs.clone();
        defer then_released.deinit();

        self.popLocalsTo(branch_locals_len);
        try self.restoreReleased(&pre_released);

        try self.emitLabel(none_label);
        try self.emitBranchRelease(is_some);
        try self.emitStdOptionConstructor(result_ty, "None", result_reg, null);
        try self.emitJmp(end_label);
        var else_released = try self.released_regs.clone();
        defer else_released.deinit();

        self.popLocalsTo(branch_locals_len);
        try self.setMergeReleased(false, &then_released, false, &else_released, &pre_released);

        try self.emitLabel(end_label);
        if (!self.isLocalReg(receiver_reg)) try self.emitRelease(receiver_reg);
        return result_reg;
    }

    fn genOptionAndThenClosureCall(self: *Codegen, expr: *const ast.Node, call: ast.CallExpr, receiver_ty: *const ast.Type, closure: *const ast.ClosureLiteral) anyerror!u32 {
        const result_ty = self.tc.expr_types.get(expr) orelse return Error.MissingType;
        const receiver_reg = try self.genExpr(@constCast(call.args[0]));
        const is_some = try self.intern(try self.newTmp());
        try self.emitStdOptionMethod(receiver_ty, "is_some", is_some, receiver_reg);

        const some_label = try self.newLabel("L_OPTION_AND_THEN_SOME");
        const none_label = try self.newLabel("L_OPTION_AND_THEN_NONE");
        const end_label = try self.newLabel("L_OPTION_AND_THEN_END");
        const result_slot = try self.intern(try self.newTmp());
        try self.emitStackAlloc(result_slot, 8);
        try self.prepareResultSlotRefCellCompanion(result_slot, result_ty);
        try self.emitBranch(is_some, some_label, none_label);

        const branch_locals_len = self.locals.items.len;
        var pre_released = try self.released_regs.clone();
        defer pre_released.deinit();

        try self.emitLabel(some_label);
        try self.emitBranchRelease(is_some);
        const value_reg = try self.intern(try self.newTmp());
        try self.emitStdOptionMethod(receiver_ty, "get", value_reg, receiver_reg);
        const chained_reg = try self.genInlineClosureUnary(closure, value_reg);
        try self.emitStore(result_slot, 0, chained_reg, .ptr);
        try self.storeResultSlotTransferredValue(result_slot, chained_reg, result_ty);
        if (!self.isLocalReg(value_reg)) try self.emitRelease(value_reg);
        try self.emitJmp(end_label);
        var then_released = try self.released_regs.clone();
        defer then_released.deinit();

        self.popLocalsTo(branch_locals_len);
        try self.restoreReleased(&pre_released);

        try self.emitLabel(none_label);
        try self.emitBranchRelease(is_some);
        const none_reg = try self.intern(try self.newTmp());
        try self.emitStdOptionConstructor(result_ty, "None", none_reg, null);
        try self.emitStore(result_slot, 0, none_reg, .ptr);
        try self.storeResultSlotTransferredValue(result_slot, none_reg, result_ty);
        try self.emitJmp(end_label);
        var else_released = try self.released_regs.clone();
        defer else_released.deinit();

        self.popLocalsTo(branch_locals_len);
        try self.setMergeReleased(false, &then_released, false, &else_released, &pre_released);

        try self.emitLabel(end_label);
        const result_reg = try self.intern(try self.newTmp());
        try self.emitLoad(result_reg, result_slot, 0, try primType(result_ty));
        try self.loadResultSlotTransferredValue(result_reg, result_slot, result_ty);
        if (!self.isLocalReg(receiver_reg)) try self.emitRelease(receiver_reg);
        return result_reg;
    }

    fn genOptionUnwrapOrElseClosureCall(self: *Codegen, call: ast.CallExpr, receiver_ty: *const ast.Type, closure: *const ast.ClosureLiteral) anyerror!u32 {
        const inner_ty = lowering_rules.optionInnerType(receiver_ty) orelse return Error.UnsupportedSabDirectFeature;
        const receiver_reg = try self.genExpr(@constCast(call.args[0]));
        const is_some = try self.intern(try self.newTmp());
        try self.emitStdOptionMethod(receiver_ty, "is_some", is_some, receiver_reg);

        const some_label = try self.newLabel("L_OPTION_UNWRAP_OR_ELSE_SOME");
        const none_label = try self.newLabel("L_OPTION_UNWRAP_OR_ELSE_NONE");
        const end_label = try self.newLabel("L_OPTION_UNWRAP_OR_ELSE_END");
        const result_slot = try self.intern(try self.newTmp());
        try self.emitStackAlloc(result_slot, typeSize(inner_ty));
        try self.prepareResultSlotRefCellCompanion(result_slot, inner_ty);
        try self.emitBranch(is_some, some_label, none_label);

        const branch_locals_len = self.locals.items.len;
        var pre_released = try self.released_regs.clone();
        defer pre_released.deinit();

        try self.emitLabel(some_label);
        try self.emitBranchRelease(is_some);
        const value_reg = try self.intern(try self.newTmp());
        try self.emitStdOptionMethod(receiver_ty, "get", value_reg, receiver_reg);
        try self.emitStore(result_slot, 0, value_reg, try primType(inner_ty));
        try self.storeResultSlotTransferredValue(result_slot, value_reg, inner_ty);
        try self.emitJmp(end_label);
        var then_released = try self.released_regs.clone();
        defer then_released.deinit();

        self.popLocalsTo(branch_locals_len);
        try self.restoreReleased(&pre_released);

        try self.emitLabel(none_label);
        try self.emitBranchRelease(is_some);
        const default_reg = try self.genInlineClosureNullary(closure);
        try self.emitStore(result_slot, 0, default_reg, try primType(inner_ty));
        try self.storeResultSlotTransferredValue(result_slot, default_reg, inner_ty);
        try self.emitJmp(end_label);
        var else_released = try self.released_regs.clone();
        defer else_released.deinit();

        self.popLocalsTo(branch_locals_len);
        try self.setMergeReleased(false, &then_released, false, &else_released, &pre_released);

        try self.emitLabel(end_label);
        const result_reg = try self.intern(try self.newTmp());
        try self.emitLoad(result_reg, result_slot, 0, try primType(inner_ty));
        try self.loadResultSlotTransferredValue(result_reg, result_slot, inner_ty);
        if (!self.isLocalReg(receiver_reg)) try self.emitRelease(receiver_reg);
        return result_reg;
    }

    fn genOptionClosureCall(self: *Codegen, expr: *const ast.Node, call: ast.CallExpr) anyerror!?u32 {
        if (call.args.len == 0) return null;
        const receiver_ty = self.tc.expr_types.get(call.args[0]) orelse return null;
        const plan = lowering_rules.planOptionClosureCall(call, receiver_ty) orelse return null;
        const closure = closureLiteralFromExpr(call.args[plan.closure_arg_index]) orelse return Error.UnsupportedSabDirectFeature;
        if (closure.params.len != plan.closure_arity) return Error.UnsupportedSabDirectFeature;
        return switch (plan.kind) {
            .map => try self.genOptionMapClosureCall(expr, call, receiver_ty, closure),
            .and_then => try self.genOptionAndThenClosureCall(expr, call, receiver_ty, closure),
            .unwrap_or_else => try self.genOptionUnwrapOrElseClosureCall(call, receiver_ty, closure),
        };
    }

    fn genVecLiteralCall(self: *Codegen, expr: *const ast.Node, call: ast.CallExpr) anyerror!?u32 {
        if (call.associated_target != null or !std.mem.eql(u8, call.func_name, "vec")) return null;
        const vec_ty = self.tc.expr_types.get(expr) orelse return Error.MissingType;
        const elem_ty = lowering_rules.vecElementType(vec_ty) orelse return Error.UnsupportedSabDirectFeature;
        try self.ensureStdDeps("sa_std/vec.sa", &.{ "sa_vec_new", "sa_vec_push", "sa_mem_copy" });
        const elem_size_text = try std.fmt.allocPrint(self.allocator, "{}", .{lowering_rules.vecElementSlotSize(elem_ty)});
        defer self.allocator.free(elem_size_text);

        const vec_reg = try self.intern(try self.newTmp());
        try self.recordReg(vec_reg);
        try self.emitStdMacroFragment("sa_std/vec.sa", "VEC_NEW", &.{self.symbols.items[vec_reg]});
        const elem_transfers_ownership = lowering_rules.vecElementPushTransfersOwnership(elem_ty, self.typeIsCopyValue(elem_ty));
        for (call.args) |arg| {
            const arg_reg = try self.genExpr(@constCast(arg));
            try self.emitStdMacroFragmentWithLiteralArgs("sa_std/vec.sa", "VEC_PUSH", &.{
                self.symbols.items[vec_reg],
                self.symbols.items[arg_reg],
                elem_size_text,
            }, &.{ false, false, true });
            if (elem_transfers_ownership) {
                if (!self.isLocalReg(arg_reg)) try self.emitMove(arg_reg);
            } else {
                try self.releaseExprResultIfNeeded(arg, arg_reg);
            }
        }
        return vec_reg;
    }

    fn genVecNewCall(self: *Codegen, expr: *const ast.Node, call: ast.CallExpr) anyerror!?u32 {
        const target_name = call.associated_target orelse return null;
        if (!std.mem.eql(u8, target_name, "Vec") or !std.mem.eql(u8, call.func_name, "new") or call.args.len != 0) return null;
        const vec_ty = self.tc.expr_types.get(expr) orelse return Error.MissingType;
        _ = lowering_rules.vecElementType(vec_ty) orelse return null;

        try self.ensureStdDeps("sa_std/vec.sa", &.{"sa_vec_new"});
        const dst = try self.intern(try self.newTmp());
        try self.recordReg(dst);
        try self.emitCallBody(dst, "@sa_vec_new()");
        return dst;
    }

    fn genVecLenCall(self: *Codegen, call: ast.CallExpr) anyerror!?u32 {
        if (call.associated_target != null or !std.mem.eql(u8, call.func_name, "len") or call.args.len != 1) return null;
        const receiver_ty = self.tc.expr_types.get(call.args[0]) orelse return null;
        _ = lowering_rules.vecElementType(receiver_ty) orelse return null;

        try self.ensureStdDeps("sa_std/vec.sa", &.{"sa_vec_len"});
        const receiver_source = try self.genVecOwnerReceiver(@constCast(call.args[0]));
        const receiver_reg = receiver_source.reg;
        const dst = try self.intern(try self.newTmp());
        try self.recordReg(dst);
        try self.emitLoad(dst, receiver_reg, lowering_rules.VecAbi.len_offset, .u64);
        try self.releaseAddressSource(receiver_source);
        return dst;
    }

    fn genVecPopCall(self: *Codegen, call: ast.CallExpr) anyerror!?u32 {
        if (call.associated_target != null or !std.mem.eql(u8, call.func_name, "pop") or call.args.len != 1) return null;
        const receiver_ty = self.tc.expr_types.get(call.args[0]) orelse return null;
        _ = lowering_rules.vecElementType(receiver_ty) orelse return null;
        try self.ensureStdDeps("sa_std/vec.sa", &.{"sa_vec_try_pop"});

        const receiver_reg = try self.genExpr(@constCast(call.args[0]));
        const ok_reg = try self.intern(try self.newTmp());
        const value_reg = try self.intern(try self.newTmp());
        const value_slot = try self.intern(try self.newTmp());
        const option_reg = try self.intern(try self.newTmp());
        try self.recordReg(ok_reg);
        try self.recordReg(value_reg);
        try self.recordReg(option_reg);
        try self.emitStackAlloc(value_slot, 8);
        try self.emitCallBody(ok_reg, try std.fmt.allocPrint(self.allocator, "@sa_vec_try_pop(&{s}, &{s})", .{ self.symbols.items[receiver_reg], self.symbols.items[value_slot] }));
        try self.emitLoad(value_reg, value_slot, 0, .u64);
        try self.markNonOwningReg(value_slot);
        try self.emitRelease(value_slot);

        const some_label = try self.newLabel("L_VEC_POP_SOME");
        const none_label = try self.newLabel("L_VEC_POP_NONE");
        const end_label = try self.newLabel("L_VEC_POP_END");
        try self.emitBranch(ok_reg, some_label, none_label);

        const branch_locals_len = self.locals.items.len;
        var pre_released = try self.released_regs.clone();
        defer pre_released.deinit();

        try self.emitLabel(some_label);
        try self.emitBranchRelease(ok_reg);
        try self.emitStdMacroFragment("sa_std/core/option.sa", "OPTION_NEW_SOME", &.{
            self.symbols.items[option_reg],
            self.symbols.items[value_reg],
        });
        try self.emitRelease(value_reg);
        try self.emitJmp(end_label);
        var then_released = try self.released_regs.clone();
        defer then_released.deinit();

        self.popLocalsTo(branch_locals_len);
        try self.restoreReleased(&pre_released);

        try self.emitLabel(none_label);
        try self.emitBranchRelease(ok_reg);
        try self.emitRelease(value_reg);
        try self.emitStdMacroFragment("sa_std/core/option.sa", "OPTION_NEW_NONE", &.{
            self.symbols.items[option_reg],
        });
        try self.emitJmp(end_label);
        var else_released = try self.released_regs.clone();
        defer else_released.deinit();

        self.popLocalsTo(branch_locals_len);
        try self.setMergeReleased(false, &then_released, false, &else_released, &pre_released);

        try self.emitLabel(end_label);
        if (!self.isLocalReg(receiver_reg)) try self.emitRelease(receiver_reg);
        return option_reg;
    }

    fn genVecPushCall(self: *Codegen, call: ast.CallExpr) anyerror!?u32 {
        if (call.associated_target != null or !std.mem.eql(u8, call.func_name, "push") or call.args.len != 2) return null;
        const receiver_ty = self.tc.expr_types.get(call.args[0]) orelse return null;
        const elem_ty = lowering_rules.vecElementType(receiver_ty) orelse return null;
        if (lowering_rules.vecElementSlotSize(elem_ty) != 8) return null;

        try self.ensureStdDeps("sa_std/vec.sa", &.{ "sa_vec_push", "sa_mem_copy" });
        const receiver_reg = try self.genExpr(@constCast(call.args[0]));
        const value_reg = try self.genExpr(@constCast(call.args[1]));
        try self.emitCallBody(receiver_reg, try std.fmt.allocPrint(self.allocator, "@sa_vec_push(^{s}, {s}, 8)", .{
            self.symbols.items[receiver_reg],
            self.symbols.items[value_reg],
        }));

        if (!self.isLocalReg(receiver_reg)) try self.emitRelease(receiver_reg);
        if (lowering_rules.vecElementPushTransfersOwnership(elem_ty, self.typeIsCopyValue(elem_ty))) {
            if (!self.isLocalReg(value_reg)) try self.emitMove(value_reg);
        } else if (!self.isLocalReg(value_reg)) {
            try self.emitRelease(value_reg);
        }

        const sentinel = try self.intern(try self.newTmp());
        try self.recordReg(sentinel);
        try self.emitAssignImm(sentinel, 0);
        return sentinel;
    }

    fn genRefCellBorrowCall(self: *Codegen, call: ast.CallExpr) anyerror!?u32 {
        if (call.args.len == 0) return null;
        const receiver_ty = self.tc.expr_types.get(call.args[0]) orelse return null;
        const plan = lowering_rules.planRefCellBorrowCall(call, receiver_ty) orelse return null;

        const recv_reg = try self.genExpr(@constCast(call.args[0]));
        const ok_reg = try self.intern(try self.newTmp());
        const borrow_slot_reg = try self.intern(try self.newTmp());
        try self.recordReg(ok_reg);
        try self.recordReg(borrow_slot_reg);
        try self.emitStdMacroFragment("sa_std/core/refcell.sa", plan.tryBorrowMacroName(), &.{
            self.symbols.items[ok_reg],
            self.symbols.items[borrow_slot_reg],
            self.symbols.items[recv_reg],
        });

        const ok_label = try self.newLabel("L_REFCELL_BORROW_OK");
        const err_label = try self.newLabel("L_REFCELL_BORROW_PANIC");
        const guard_plan = lowering_rules.planRefCellBorrowRuntimeGuard(plan);
        try self.emitBranch(ok_reg, ok_label, err_label);

        try self.emitLabel(err_label);
        if (guard_plan.release_status_on_conflict) try self.emitBranchRelease(ok_reg);
        try self.emitPanicCode(guard_plan.conflict_panic_code);

        try self.emitLabel(ok_label);
        if (guard_plan.release_status_on_success) try self.emitBranchRelease(ok_reg);
        const result_plan = lowering_rules.planRefCellBorrowResult(.direct_sab, plan.value_kind);
        const borrow_reg = switch (result_plan.action) {
            .use_borrow_slot => borrow_slot_reg,
            .take_pointer_payload => blk: {
                const payload_reg = try self.intern(try self.newTmp());
                try self.emitTake(payload_reg, borrow_slot_reg, 0, .ptr);
                const temp_plan = lowering_rules.planBorrowAddressTemps(result_plan.track_borrow_slot_release_temp, false);
                if (temp_plan.track_primary_temp) {
                    try self.borrow_address_temps.put(payload_reg, .{
                        .release_regs = try self.singleReleaseReg(borrow_slot_reg),
                    });
                }
                break :blk payload_reg;
            },
            .load_pointer_payload => return Error.UnsupportedSabDirectFeature,
        };
        const handle_plan = lowering_rules.planRefCellBorrowHandleRegistration(plan);
        const release_regs = if (handle_plan.track_receiver_owner_temp) try self.singleReleaseReg(recv_reg) else &.{};
        try self.refcell_borrow_values.put(borrow_reg, .{
            .cell_reg = recv_reg,
            .kind = plan.kind,
            .release_regs = release_regs,
        });
        return borrow_reg;
    }

    fn genSmartPointerCloneCall(self: *Codegen, call: ast.CallExpr) anyerror!?u32 {
        if (!std.mem.eql(u8, call.func_name, "clone") or call.args.len != 1) return null;
        const receiver_ty = self.tc.expr_types.get(call.args[0]) orelse return null;
        const receiver_type_name = typeBaseName(receiver_ty) orelse return null;
        const macro_name = if (std.mem.eql(u8, receiver_type_name, "Rc"))
            "RC_CLONE_OUT"
        else if (std.mem.eql(u8, receiver_type_name, "Arc"))
            "ARC_CLONE_OUT"
        else
            return null;
        const import_path = if (std.mem.eql(u8, receiver_type_name, "Rc"))
            "sa_std/core/rc.sa"
        else
            "sa_std/core/arc.sa";

        const receiver_reg = try self.genExpr(@constCast(call.args[0]));
        const dst = try self.intern(try self.newTmp());
        try self.recordReg(dst);
        try self.emitStdMacroFragment(import_path, macro_name, &.{
            self.symbols.items[dst],
            self.symbols.items[receiver_reg],
        });
        if (!self.isLocalReg(receiver_reg)) try self.emitRelease(receiver_reg);
        return dst;
    }

    fn importedMacroExistingAddressableSymbol(self: *Codegen, arg: *const ast.Node, ctx: ?*MacroExpansionContext) ?[]const u8 {
        if (arg.* != .identifier) return null;
        const name = arg.identifier;
        if (ctx) |macro_ctx| {
            if (macroIdentifierName(macro_ctx, name)) |mapped| {
                if (self.stackLocal(mapped)) |slot| return self.symbols.items[slot.reg];
                return null;
            }
            if (macroArgBinding(macro_ctx, name)) |binding| {
                return self.importedMacroExistingAddressableSymbol(binding.arg, binding.ctx);
            }
        }
        if (self.stackLocal(name)) |slot| return self.symbols.items[slot.reg];
        return null;
    }

    fn importedMacroArgType(self: *Codegen, arg: *const ast.Node, ctx: ?*MacroExpansionContext) anyerror!?*const ast.Type {
        if (ctx) |macro_ctx| return try self.macroExprType(arg, macro_ctx);
        return try self.exprTypeOrFallback(arg);
    }

    fn importedMacroArgAddressShape(self: *Codegen, arg: *const ast.Node, ctx: ?*MacroExpansionContext) anyerror!lowering_rules.AddressOfShape {
        if (ctx) |macro_ctx| {
            if (arg.* == .identifier) {
                const name = arg.identifier;
                if (macroIdentifierName(macro_ctx, name) != null) return .identifier;
                if (macroArgBinding(macro_ctx, name)) |binding| {
                    return try self.importedMacroArgAddressShape(binding.arg, binding.ctx);
                }
            }
        }

        var deref_source_ty: ?*const ast.Type = null;
        var index_target_ty: ?*const ast.Type = null;
        switch (arg.*) {
            .deref_expr => |deref| deref_source_ty = (try self.importedMacroArgType(deref.expr, ctx)) orelse return Error.MissingType,
            .index_expr => |idx| index_target_ty = (try self.importedMacroArgType(idx.target, ctx)) orelse return Error.MissingType,
            else => {},
        }
        return lowering_rules.planAddressOf(arg, .{
            .deref_source_ty = deref_source_ty,
            .index_target_ty = index_target_ty,
        }).shape;
    }

    fn genImportedMacroValueArg(self: *Codegen, arg: *const ast.Node, ctx: ?*MacroExpansionContext, release_value: bool) anyerror!SabLoweredCallArg {
        const arg_reg = if (ctx) |macro_ctx| try self.genMacroExpr(@constCast(arg), macro_ctx) else try self.genExpr(@constCast(arg));
        return .{
            .operand = self.symbols.items[arg_reg],
            .release_reg = if (release_value and try self.importedMacroValueArgNeedsRelease(arg, arg_reg, ctx)) arg_reg else null,
        };
    }

    fn importedMacroOutputTargetName(self: *Codegen, arg: *const ast.Node, ctx: ?*MacroExpansionContext) ?[]const u8 {
        if (ctx) |macro_ctx| return self.macroAssignTargetName(@constCast(arg), macro_ctx);
        if (arg.* != .identifier) return null;
        return arg.identifier;
    }

    fn genImportedMacroLeadingOutputArg(
        self: *Codegen,
        plan: lowering_rules.ImportedMacroCallPlan,
        call_arg_index: usize,
        arg: *const ast.Node,
        ctx: ?*MacroExpansionContext,
        arg_ty: *const ast.Type,
    ) anyerror!?SabLoweredCallArg {
        if (plan.expression_output or call_arg_index >= plan.leading_outputs) return null;
        const name = self.importedMacroOutputTargetName(arg, ctx) orelse return null;
        const dst = try self.bindingReg(name);
        return .{
            .operand = self.symbols.items[dst],
            .release_reg = null,
            .output_bind_name = name,
            .output_bind_ty = arg_ty,
        };
    }

    fn importedMacroDirectCallConsumesValueArg(_: *Codegen, plan: lowering_rules.ImportedMacroCallPlan, call_arg_index: usize) bool {
        return (std.mem.eql(u8, plan.macro_name, "FS_READ_BUFFER_FREE") or
            std.mem.eql(u8, plan.macro_name, "SLA_FS_BUFFER_FREE")) and call_arg_index == 0;
    }

    fn importedMacroValueArgNeedsRelease(self: *Codegen, arg: *const ast.Node, reg: u32, ctx: ?*MacroExpansionContext) anyerror!bool {
        if (arg.* == .cast_expr) return !self.isLocalReg(reg);
        if (lowering_rules.exprResultNeedsRelease(arg)) return !self.isLocalReg(reg);
        if (arg.* != .identifier) return false;

        const name = arg.identifier;
        if (ctx) |macro_ctx| {
            if (macroIdentifierName(macro_ctx, name) != null) return !self.isLocalReg(reg);
            if (macroArgBinding(macro_ctx, name)) |binding| {
                return try self.importedMacroValueArgNeedsRelease(binding.arg, reg, binding.ctx);
            }
        }

        if (self.stackLocal(name) != null) return !self.isLocalReg(reg);
        if (self.global_scalar_consts.contains(name)) return !self.isLocalReg(reg);
        if (self.exprHasFnPtrType(arg) and self.tc.funcs.contains(name)) return !self.isLocalReg(reg);
        if (self.tc.expr_types.get(arg)) |expr_ty| {
            if (typeBaseName(expr_ty)) |type_name| {
                if (self.findStdSurfaceRule(.constructor, type_name, name) != null) return !self.isLocalReg(reg);
            }
        }
        return false;
    }

    fn genImportedMacroAddressExpressionSource(self: *Codegen, arg: *const ast.Node, ctx: ?*MacroExpansionContext) anyerror!AddressSource {
        if (ctx) |macro_ctx| return try self.genMacroAddressOf(@constCast(arg), macro_ctx);
        return try self.genAddressOf(@constCast(arg));
    }

    fn genImportedMacroMaterializedSlotArg(self: *Codegen, arg: *const ast.Node, ctx: ?*MacroExpansionContext) anyerror!SabLoweredCallArg {
        const value_reg = (if (ctx) |macro_ctx| self.genMacroExpr(@constCast(arg), macro_ctx) else self.genExpr(@constCast(arg))) catch |err| {
            self.traceUnsupported("imported macro addressable value {s} failed: {s}\n", .{ @tagName(arg.*), @errorName(err) });
            return err;
        };
        const arg_ty = ((try self.importedMacroArgType(arg, ctx)) orelse {
            self.traceUnsupported("imported macro addressable type {s} missing\n", .{@tagName(arg.*)});
            return Error.MissingType;
        });
        const slot = try self.intern(try self.newTmp());
        try self.emitStackAlloc(slot, typeSize(arg_ty));
        const store_ty = addressableSlotPrimType(arg_ty) catch |err| {
            self.traceUnsupported("imported macro addressable storage type {s} failed: {s}\n", .{ @tagName(arg_ty.*), @errorName(err) });
            return err;
        };
        try self.emitStore(slot, 0, value_reg, store_ty);
        if (try self.importedMacroValueArgNeedsRelease(arg, value_reg, ctx)) try self.emitRelease(value_reg);
        return .{ .operand = self.symbols.items[slot], .release_reg = null };
    }

    fn genImportedMacroAddressExpressionMaterializedSlotArg(self: *Codegen, arg: *const ast.Node, ctx: ?*MacroExpansionContext) anyerror!SabLoweredCallArg {
        const source = self.genImportedMacroAddressExpressionSource(arg, ctx) catch |err| {
            self.traceUnsupported("imported macro address-expression source {s} failed: {s}\n", .{ @tagName(arg.*), @errorName(err) });
            return err;
        };
        const arg_ty = ((try self.importedMacroArgType(arg, ctx)) orelse {
            self.traceUnsupported("imported macro address-expression type {s} missing\n", .{@tagName(arg.*)});
            return Error.MissingType;
        });
        const slot = try self.intern(try self.newTmp());
        try self.emitStackAlloc(slot, typeSize(arg_ty));
        const store_ty = addressableSlotPrimType(arg_ty) catch |err| {
            self.traceUnsupported("imported macro address-expression storage type {s} failed: {s}\n", .{ @tagName(arg_ty.*), @errorName(err) });
            return err;
        };
        const loaded = try self.intern(try self.newTmp());
        try self.emitLoad(loaded, source.reg, 0, store_ty);
        try self.emitStore(slot, 0, loaded, store_ty);
        if (try self.importedMacroValueArgNeedsRelease(arg, loaded, ctx)) try self.emitRelease(loaded);
        if (!self.isLocalReg(source.reg)) try self.emitRelease(source.reg);
        for (source.release_regs) |release_reg| try self.emitRelease(release_reg);
        if (source.release_regs.len != 0) self.allocator.free(source.release_regs);
        return .{ .operand = self.symbols.items[slot], .release_reg = null };
    }

    fn genImportedMacroAddressExpressionArg(self: *Codegen, arg: *const ast.Node, ctx: ?*MacroExpansionContext) anyerror!SabLoweredCallArg {
        const source = self.genImportedMacroAddressExpressionSource(arg, ctx) catch |err| {
            self.traceUnsupported("imported macro direct address-expression source {s} failed: {s}\n", .{ @tagName(arg.*), @errorName(err) });
            return err;
        };
        return .{
            .operand = self.symbols.items[source.reg],
            .release_reg = if (!self.isLocalReg(source.reg)) source.reg else null,
            .release_regs = source.release_regs,
        };
    }

    fn genImportedMacroArg(self: *Codegen, plan: lowering_rules.ImportedMacroCallPlan, call_arg_index: usize, arg: *const ast.Node, ctx: ?*MacroExpansionContext) anyerror!SabLoweredCallArg {
        const arg_ty = (try self.importedMacroArgType(arg, ctx)) orelse return Error.MissingType;
        if (try self.genImportedMacroLeadingOutputArg(plan, call_arg_index, arg, ctx, arg_ty)) |output_arg| return output_arg;
        const release_value = !self.importedMacroDirectCallConsumesValueArg(plan, call_arg_index);
        if (plan.planArgValueBypassAction(call_arg_index, arg, arg_ty)) |action| switch (action) {
            .pass_value, .pass_raw_pointer_value => return self.genImportedMacroValueArg(arg, ctx, release_value),
            else => unreachable,
        };
        const existing_symbol = self.importedMacroExistingAddressableSymbol(arg, ctx);
        const address_shape = try self.importedMacroArgAddressShape(arg, ctx);
        switch (plan.planAddressableArgLoweringAction(call_arg_index, address_shape, existing_symbol != null, arg_ty)) {
            .pass_value => return self.genImportedMacroValueArg(arg, ctx, release_value),
            .pass_raw_pointer_value => unreachable,
            .pass_address_expression => return self.genImportedMacroAddressExpressionArg(arg, ctx),
            .pass_pointer_backed_projection => return self.genImportedMacroValueArg(arg, ctx, release_value),
            .reuse_existing_addressable => return .{ .operand = existing_symbol.?, .release_reg = null },
            .materialize_stack_slot => return self.genImportedMacroMaterializedSlotArg(arg, ctx),
            .materialize_address_expression_stack_slot => return self.genImportedMacroAddressExpressionMaterializedSlotArg(arg, ctx),
        }
    }

    fn directImportedMacroReg(self: *Codegen, name: []const u8) !u32 {
        return try self.intern(name);
    }

    fn emitDirectJsonObjectGet(self: *Codegen, arg_names: []const []const u8) !void {
        const dst = try self.directImportedMacroReg(arg_names[0]);
        const node = try self.directImportedMacroReg(arg_names[1]);
        const key = try self.directImportedMacroReg(arg_names[2]);
        const key_len = try self.directImportedMacroReg(arg_names[3]);
        const slot = try self.intern(try self.newTmp());
        const tmp = try self.intern(try self.newTmp());
        try self.emitStackAlloc(slot, 8);
        try self.emitCallBody(tmp, try std.fmt.allocPrint(
            self.allocator,
            "@sa_json_object_get({s}, &{s}, {s}, &{s})",
            .{ self.symbols.items[node], self.symbols.items[key], self.symbols.items[key_len], self.symbols.items[slot] },
        ));
        try self.emitLoad(dst, slot, 0, .ptr);
        try self.emitRelease(tmp);
    }

    fn emitDirectJsonObjectKeyAt(
        self: *Codegen,
        arg_names: []const []const u8,
        load_offset: usize,
        load_ty: sig.PrimType,
    ) !void {
        const dst = try self.directImportedMacroReg(arg_names[0]);
        const node = try self.directImportedMacroReg(arg_names[1]);
        const index = try self.directImportedMacroReg(arg_names[2]);
        const ptr_slot = try self.intern(try self.newTmp());
        const len_slot = try self.intern(try self.newTmp());
        const tmp = try self.intern(try self.newTmp());
        try self.emitStackAlloc(ptr_slot, 8);
        try self.emitStackAlloc(len_slot, 8);
        try self.emitCallBody(tmp, try std.fmt.allocPrint(
            self.allocator,
            "@sa_json_object_key_at({s}, {s}, &{s}, &{s})",
            .{ self.symbols.items[node], self.symbols.items[index], self.symbols.items[ptr_slot], self.symbols.items[len_slot] },
        ));
        try self.emitLoad(dst, if (load_offset == 0) ptr_slot else len_slot, 0, load_ty);
        try self.emitRelease(tmp);
    }

    fn emitDirectImportedMacroCall(self: *Codegen, macro_name: []const u8, arg_names: []const []const u8) !bool {
        if (std.mem.eql(u8, macro_name, "SLA_BYTE_AT")) {
            if (arg_names.len != 3) return false;
            const dst = try self.directImportedMacroReg(arg_names[0]);
            const ptr = try self.directImportedMacroReg(arg_names[1]);
            const offset = try self.directImportedMacroReg(arg_names[2]);
            const addr = try self.intern(try self.newTmp());
            try self.emitPtrAdd(addr, ptr, .{ .reg = offset });
            try self.emitLoad(dst, addr, 0, .u8);
            return true;
        }

        if (std.mem.eql(u8, macro_name, "SLA_BYTE_PUT")) {
            if (arg_names.len != 3) return false;
            const ptr = try self.directImportedMacroReg(arg_names[0]);
            const offset = try self.directImportedMacroReg(arg_names[1]);
            const value = try self.directImportedMacroReg(arg_names[2]);
            const addr = try self.intern(try self.newTmp());
            try self.emitPtrAdd(addr, ptr, .{ .reg = offset });
            try self.emitStore(addr, 0, value, .u8);
            return true;
        }

        if (std.mem.eql(u8, macro_name, "SLA_PTR_ADD")) {
            if (arg_names.len != 3) return false;
            const dst = try self.directImportedMacroReg(arg_names[0]);
            const base = try self.directImportedMacroReg(arg_names[1]);
            const offset = try self.directImportedMacroReg(arg_names[2]);
            try self.emitPtrAdd(dst, base, .{ .reg = offset });
            try self.markNonOwningReg(dst);
            return true;
        }

        if (std.mem.eql(u8, macro_name, "SLA_BUF_ALLOC")) {
            if (arg_names.len != 2) return false;
            const dst = try self.directImportedMacroReg(arg_names[0]);
            const size = try self.directImportedMacroReg(arg_names[1]);
            try self.emitAllocOperand(dst, .{ .reg = size });
            return true;
        }

        if (std.mem.eql(u8, macro_name, "SLA_JSON_OBJECT_GET")) {
            if (arg_names.len != 4) return false;
            try self.emitDirectJsonObjectGet(arg_names);
            return true;
        }

        if (std.mem.eql(u8, macro_name, "SLA_JSON_ARRAY_GET")) {
            if (arg_names.len != 3) return false;
            const dst = try self.directImportedMacroReg(arg_names[0]);
            const node = try self.directImportedMacroReg(arg_names[1]);
            const index = try self.directImportedMacroReg(arg_names[2]);
            const slot = try self.intern(try self.newTmp());
            const tmp = try self.intern(try self.newTmp());
            try self.emitStackAlloc(slot, 8);
            try self.emitCallBody(tmp, try std.fmt.allocPrint(
                self.allocator,
                "@sa_json_array_get({s}, {s}, &{s})",
                .{ self.symbols.items[node], self.symbols.items[index], self.symbols.items[slot] },
            ));
            try self.emitLoad(dst, slot, 0, .ptr);
            try self.emitRelease(tmp);
            return true;
        }

        if (std.mem.eql(u8, macro_name, "SLA_JSON_VALUE_COUNT")) {
            if (arg_names.len != 2) return false;
            const dst = try self.directImportedMacroReg(arg_names[0]);
            const node = try self.directImportedMacroReg(arg_names[1]);
            const slot = try self.intern(try self.newTmp());
            const tmp = try self.intern(try self.newTmp());
            try self.emitStackAlloc(slot, 8);
            try self.emitCallBody(tmp, try std.fmt.allocPrint(self.allocator, "@sa_json_value_count({s}, &{s})", .{ self.symbols.items[node], self.symbols.items[slot] }));
            try self.emitLoad(dst, slot, 0, .u64);
            try self.emitRelease(tmp);
            return true;
        }

        if (std.mem.eql(u8, macro_name, "SLA_JSON_AS_I64")) {
            if (arg_names.len != 2) return false;
            const dst = try self.directImportedMacroReg(arg_names[0]);
            const node = try self.directImportedMacroReg(arg_names[1]);
            const slot = try self.intern(try self.newTmp());
            const tmp = try self.intern(try self.newTmp());
            try self.emitStackAlloc(slot, 8);
            try self.emitCallBody(tmp, try std.fmt.allocPrint(self.allocator, "@sa_json_as_i64({s}, &{s})", .{ self.symbols.items[node], self.symbols.items[slot] }));
            try self.emitLoad(dst, slot, 0, .i64);
            try self.emitRelease(tmp);
            return true;
        }

        if (std.mem.eql(u8, macro_name, "SLA_JSON_AS_BOOL")) {
            if (arg_names.len != 2) return false;
            const dst = try self.directImportedMacroReg(arg_names[0]);
            const node = try self.directImportedMacroReg(arg_names[1]);
            const slot = try self.intern(try self.newTmp());
            const tmp = try self.intern(try self.newTmp());
            try self.emitStackAlloc(slot, 1);
            try self.emitCallBody(tmp, try std.fmt.allocPrint(self.allocator, "@sa_json_as_bool({s}, &{s})", .{ self.symbols.items[node], self.symbols.items[slot] }));
            try self.emitLoad(dst, slot, 0, .u8);
            try self.emitRelease(tmp);
            return true;
        }

        if (std.mem.eql(u8, macro_name, "SLA_JSON_STRING_PTR")) {
            if (arg_names.len != 2) return false;
            const dst = try self.directImportedMacroReg(arg_names[0]);
            const node = try self.directImportedMacroReg(arg_names[1]);
            try self.emitCallBody(dst, try std.fmt.allocPrint(self.allocator, "@sa_json_string_ptr({s})", .{self.symbols.items[node]}));
            return true;
        }

        if (std.mem.eql(u8, macro_name, "SLA_JSON_STRING_LEN")) {
            if (arg_names.len != 2) return false;
            const dst = try self.directImportedMacroReg(arg_names[0]);
            const node = try self.directImportedMacroReg(arg_names[1]);
            try self.emitCallBody(dst, try std.fmt.allocPrint(self.allocator, "@sa_json_string_len({s})", .{self.symbols.items[node]}));
            return true;
        }

        if (std.mem.eql(u8, macro_name, "SLA_JSON_OBJECT_KEY_PTR")) {
            if (arg_names.len != 3) return false;
            try self.emitDirectJsonObjectKeyAt(arg_names, 0, .ptr);
            return true;
        }

        if (std.mem.eql(u8, macro_name, "SLA_JSON_OBJECT_KEY_LEN")) {
            if (arg_names.len != 3) return false;
            try self.emitDirectJsonObjectKeyAt(arg_names, 8, .u64);
            return true;
        }

        if (std.mem.eql(u8, macro_name, "SLA_FS_OPEN_READ")) {
            if (arg_names.len != 3) return false;
            const dst = try self.directImportedMacroReg(arg_names[0]);
            const path = try self.directImportedMacroReg(arg_names[1]);
            const path_len = try self.directImportedMacroReg(arg_names[2]);
            const slot = try self.intern(try self.newTmp());
            const tmp = try self.intern(try self.newTmp());
            try self.emitStackAlloc(slot, 8);
            try self.emitCallBody(tmp, try std.fmt.allocPrint(self.allocator, "@sa_std_fs_open_read(&{s}, {s}, &{s})", .{ self.symbols.items[path], self.symbols.items[path_len], self.symbols.items[slot] }));
            try self.emitLoad(dst, slot, 0, .u64);
            try self.emitRelease(tmp);
            return true;
        }

        if (std.mem.eql(u8, macro_name, "SLA_FS_READ_TO_STRING") or std.mem.eql(u8, macro_name, "SLA_FS_READ_FILE")) {
            if (arg_names.len != 4) return false;
            const dst = try self.directImportedMacroReg(arg_names[0]);
            const path = try self.directImportedMacroReg(arg_names[1]);
            const path_len = try self.directImportedMacroReg(arg_names[2]);
            const max_bytes = try self.directImportedMacroReg(arg_names[3]);
            const slot = try self.intern(try self.newTmp());
            const tmp = try self.intern(try self.newTmp());
            const callee = if (std.mem.eql(u8, macro_name, "SLA_FS_READ_TO_STRING")) "sa_std_fs_read_to_string" else "sa_std_fs_read_file";
            try self.emitStackAlloc(slot, 8);
            try self.emitCallBody(tmp, try std.fmt.allocPrint(self.allocator, "@{s}(&{s}, {s}, {s}, &{s})", .{ callee, self.symbols.items[path], self.symbols.items[path_len], self.symbols.items[max_bytes], self.symbols.items[slot] }));
            try self.emitLoad(dst, slot, 0, .u64);
            try self.emitRelease(tmp);
            return true;
        }

        if (std.mem.eql(u8, macro_name, "SLA_FS_BUFFER_DATA")) {
            if (arg_names.len != 2) return false;
            const dst = try self.directImportedMacroReg(arg_names[0]);
            const buffer = try self.directImportedMacroReg(arg_names[1]);
            try self.emitCallBody(dst, try std.fmt.allocPrint(self.allocator, "@sa_fs_read_buffer_data({s})", .{self.symbols.items[buffer]}));
            return true;
        }

        if (std.mem.eql(u8, macro_name, "SLA_FS_BUFFER_LEN")) {
            if (arg_names.len != 2) return false;
            const dst = try self.directImportedMacroReg(arg_names[0]);
            const buffer = try self.directImportedMacroReg(arg_names[1]);
            try self.emitCallBody(dst, try std.fmt.allocPrint(self.allocator, "@sa_fs_read_buffer_len({s})", .{self.symbols.items[buffer]}));
            return true;
        }

        if (std.mem.eql(u8, macro_name, "SLA_FS_BUFFER_FREE")) {
            if (arg_names.len != 1) return false;
            const buffer = try self.directImportedMacroReg(arg_names[0]);
            const tmp = try self.intern(try self.newTmp());
            try self.emitCallBody(tmp, try std.fmt.allocPrint(self.allocator, "@sa_fs_read_buffer_free(^{s})", .{self.symbols.items[buffer]}));
            return true;
        }

        if (std.mem.eql(u8, macro_name, "SLA_FS_CLOSE")) {
            if (arg_names.len != 2) return false;
            const dst = try self.directImportedMacroReg(arg_names[0]);
            const handle = try self.directImportedMacroReg(arg_names[1]);
            try self.emitCallBody(dst, try std.fmt.allocPrint(self.allocator, "@sa_std_close({s})", .{self.symbols.items[handle]}));
            return true;
        }

        if (std.mem.eql(u8, macro_name, "SLA_FS_EXISTS")) {
            if (arg_names.len != 3) return false;
            const dst = try self.directImportedMacroReg(arg_names[0]);
            const path = try self.directImportedMacroReg(arg_names[1]);
            const path_len = try self.directImportedMacroReg(arg_names[2]);
            const slot = try self.intern(try self.newTmp());
            const tmp = try self.intern(try self.newTmp());
            try self.emitStackAlloc(slot, 1);
            try self.emitCallBody(tmp, try std.fmt.allocPrint(self.allocator, "@sa_std_fs_try_exists(&{s}, {s}, &{s})", .{ self.symbols.items[path], self.symbols.items[path_len], self.symbols.items[slot] }));
            try self.emitLoad(dst, slot, 0, .u8);
            try self.emitRelease(tmp);
            return true;
        }

        if (std.mem.eql(u8, macro_name, "SLA_FS_METADATA")) {
            if (arg_names.len != 3) return false;
            const dst = try self.directImportedMacroReg(arg_names[0]);
            const path = try self.directImportedMacroReg(arg_names[1]);
            const path_len = try self.directImportedMacroReg(arg_names[2]);
            const slot = try self.intern(try self.newTmp());
            const tmp = try self.intern(try self.newTmp());
            try self.emitStackAlloc(slot, 8);
            try self.emitCallBody(tmp, try std.fmt.allocPrint(self.allocator, "@sa_std_fs_metadata(&{s}, {s}, &{s})", .{ self.symbols.items[path], self.symbols.items[path_len], self.symbols.items[slot] }));
            try self.emitLoad(dst, slot, 0, .u64);
            try self.emitRelease(tmp);
            return true;
        }

        if (std.mem.eql(u8, macro_name, "SLA_FS_IS_FILE") or std.mem.eql(u8, macro_name, "SLA_FS_IS_DIR")) {
            if (arg_names.len != 2) return false;
            const dst = try self.directImportedMacroReg(arg_names[0]);
            const metadata = try self.directImportedMacroReg(arg_names[1]);
            const callee = if (std.mem.eql(u8, macro_name, "SLA_FS_IS_FILE")) "sa_fs_metadata_is_file" else "sa_fs_metadata_is_directory";
            try self.emitCallBody(dst, try std.fmt.allocPrint(self.allocator, "@{s}({s})", .{ callee, self.symbols.items[metadata] }));
            return true;
        }

        if (std.mem.eql(u8, macro_name, "SLA_FS_METADATA_FREE")) {
            if (arg_names.len != 1) return false;
            const metadata = try self.directImportedMacroReg(arg_names[0]);
            const tmp = try self.intern(try self.newTmp());
            try self.emitCallBody(tmp, try std.fmt.allocPrint(self.allocator, "@sa_fs_metadata_free({s})", .{self.symbols.items[metadata]}));
            try self.emitRelease(tmp);
            return true;
        }

        return false;
    }

    fn genImportedMacroCall(self: *Codegen, call: ast.CallExpr, plan: lowering_rules.ImportedMacroCallPlan, ctx: ?*MacroExpansionContext) anyerror!u32 {
        const import_path = plan.import_path orelse return Error.UnsupportedSabDirectFeature;
        const dst = if (plan.expression_output) blk: {
            const reg = try self.intern(try self.newTmp());
            try self.recordReg(reg);
            break :blk reg;
        } else null;

        var arg_names = std.ArrayList([]const u8).init(self.allocator);
        defer arg_names.deinit();
        var release_regs = std.ArrayList(u32).init(self.allocator);
        defer release_regs.deinit();
        var restores = std.ArrayList(struct { slot: u32, value: u32 }).init(self.allocator);
        defer restores.deinit();
        var output_rebindings = std.ArrayList(struct { name: []const u8, reg: u32, ty: *const ast.Type }).init(self.allocator);
        defer output_rebindings.deinit();

        if (dst) |reg| try arg_names.append(self.symbols.items[reg]);
        for (call.args, 0..) |arg, i| {
            const lowered_arg = self.genImportedMacroArg(plan, i, arg, ctx) catch |err| {
                self.traceUnsupported("imported macro {s} arg {} failed: {s}\n", .{ plan.macro_name, i, @errorName(err) });
                return err;
            };
            try arg_names.append(lowered_arg.operand);
            if (self.plannedCallArgReleaseReg(lowered_arg.release_reg)) |reg| try release_regs.append(reg);
            if (lowered_arg.release_regs.len != 0) {
                try release_regs.appendSlice(lowered_arg.release_regs);
                self.allocator.free(lowered_arg.release_regs);
            }
            if (lowered_arg.restore_slot) |slot| {
                try restores.append(.{ .slot = slot, .value = lowered_arg.restore_value orelse return Error.UnsupportedSabDirectFeature });
            }
            if (lowered_arg.output_bind_name) |name| {
                const reg = try self.intern(lowered_arg.operand);
                try output_rebindings.append(.{ .name = name, .reg = reg, .ty = lowered_arg.output_bind_ty orelse return Error.MissingType });
            }
        }

        const emitted_direct = try self.emitDirectImportedMacroCall(plan.macro_name, arg_names.items);
        if (!emitted_direct) {
            self.emitStdMacroFragment(import_path, plan.macro_name, arg_names.items) catch |err| {
                self.traceUnsupported("imported macro {s} fragment failed: {s}\n", .{ plan.macro_name, @errorName(err) });
                return err;
            };
        }
        for (restores.items) |restore| {
            try self.emitStore(restore.slot, 0, restore.value, .ptr);
            try self.markConsumed(restore.value);
        }
        for (output_rebindings.items) |binding| {
            try self.pushTypedLocal(binding.name, binding.reg, false, binding.ty);
        }
        if (!emitted_direct) {
            try self.releaseNonLocalTemps(release_regs.items);
        }
        if (dst) |reg| return reg;

        const sentinel = try self.intern(try self.newTmp());
        try self.emitAssignImm(sentinel, 0);
        return sentinel;
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
            if (try self.genStrPtrCall(call)) |reg| return reg;
            if (try self.genStrLenCall(call)) |reg| return reg;
            if (std.mem.eql(u8, call.func_name, "println")) {
                return try self.genPrintlnCall(call);
            }
            if (std.mem.eql(u8, call.func_name, "stack_alloc")) {
                const dst = try self.intern(try self.newTmp());
                try self.emitStackAlloc(dst, try stackAllocSize(call));
                try self.pushStackAllocLocal(self.symbols.items[dst], dst);
                return dst;
            }
            if (std.mem.eql(u8, call.func_name, "str_eq") and call.args.len == 2) {
                return try self.genStrEqCall(call);
            }
            if (std.mem.eql(u8, call.func_name, "hash") and call.args.len == 1) {
                return try self.genHashCall(call);
            }
            if (std.mem.eql(u8, call.func_name, "debug") and call.args.len == 1) {
                if (try self.genDebugCall(call)) |reg| return reg;
            }
            if (self.closure_bindings.get(call.func_name)) |closure| return try self.genClosureCall(closure, call);
            if (self.tc.macros.get(call.func_name)) |macro_decl| {
                try self.genUserMacroCall(macro_decl, &expr.call_expr);
                const sentinel = try self.intern(try self.newTmp());
                try self.emitAssignImm(sentinel, 0);
                return sentinel;
            }
            if (lowering_rules.planImportedMacroCall(self.tc, call)) |plan| {
                const reg = try self.genImportedMacroCall(call, plan, null);
                if ((try self.exprTypeOrFallback(expr))) |ty| {
                    if (typeIsPointerScalarValue(ty)) try self.markNonOwningReg(reg);
                }
                return reg;
            }
        }
        if (try self.genFutureTaskCall(call)) |reg| return reg;
        if (isThreadSpawnCall(call)) return try self.genThreadSpawn(expr, call);
        if (try self.genJoinHandleJoin(expr, call)) |reg| return reg;
        if (try self.genDynMethodCall(expr, call)) |reg| return reg;
        if (try self.genOptionClosureCall(expr, call)) |reg| return reg;
        if (try self.genResultUnwrap(expr, call)) |reg| return reg;
        if (try self.genVecNewCall(expr, call)) |reg| return reg;
        if (try self.genVecLenCall(call)) |reg| return reg;
        if (try self.genVecLiteralCall(expr, call)) |reg| return reg;
        if (try self.genVecPopCall(call)) |reg| return reg;
        if (try self.genVecPushCall(call)) |reg| return reg;
        if (try self.genRefCellBorrowCall(call)) |reg| return reg;
        if (try self.genSmartPointerCloneCall(call)) |reg| return reg;
        if (try self.genStdSurfaceCall(expr, call)) |reg| return reg;
        const lowering = lowering_rules.planStaticCallLowering(self.tc, expr, call, self.tc.expr_types.get(expr)) orelse return Error.UnsupportedSabDirectFeature;
        return try self.emitPlannedStaticCall(lowering, call);
    }

    fn genStrEqCall(self: *Codegen, call: ast.CallExpr) anyerror!u32 {
        const left_ty = self.tc.expr_types.get(call.args[0]) orelse return Error.UnsupportedSabDirectFeature;
        const right_ty = self.tc.expr_types.get(call.args[1]) orelse return Error.UnsupportedSabDirectFeature;
        const left = try self.genExpr(@constCast(call.args[0]));
        const right = try self.genExpr(@constCast(call.args[1]));

        const left_arg = if (lowering_rules.isFormatStringType(left_ty)) blk: {
            const view = try self.intern(try self.newTmp());
            try self.emitStdMacroFragment("sa_std/string.sa", "STRING_BUF_AS_STR", &.{ self.symbols.items[view], self.symbols.items[left] });
            break :blk view;
        } else left;
        const right_arg = if (lowering_rules.isFormatStringType(right_ty)) blk: {
            const view = try self.intern(try self.newTmp());
            try self.emitStdMacroFragment("sa_std/string.sa", "STRING_BUF_AS_STR", &.{ self.symbols.items[view], self.symbols.items[right] });
            break :blk view;
        } else right;

        const reg = try self.intern(try self.newTmp());
        try self.emitStdMacroFragment("sa_std/string.sa", "STR_EQ", &.{ self.symbols.items[reg], self.symbols.items[left_arg], self.symbols.items[right_arg] });

        if (left_arg != left) try self.emitRelease(left_arg);
        if (right_arg != right) try self.emitRelease(right_arg);
        if (lowering_rules.callArgNeedsRelease(call.args[0]) and !self.isLocalReg(left)) try self.emitRelease(left);
        if (lowering_rules.callArgNeedsRelease(call.args[1]) and !self.isLocalReg(right)) try self.emitRelease(right);
        return reg;
    }

    /// Emit a planned static call: `dst = call @<symbol>(args...)`, materializing
    /// each argument through the shared `CallArgMaterializationPlan`. Shared by
    /// ordinary calls (`genCall`) and resolved operator-overload binaries
    /// (`genBinary`), so both consult the same `resolved_call_symbols` contract
    /// the SA-text emitter uses.
    fn emitPlannedStaticCall(
        self: *Codegen,
        lowering: lowering_rules.StaticCallLoweringPlan,
        call: ast.CallExpr,
    ) anyerror!u32 {
        return try self.emitPlannedStaticCallTo(lowering, call, null);
    }

    fn emitPlannedStaticCallTo(
        self: *Codegen,
        lowering: lowering_rules.StaticCallLoweringPlan,
        call: ast.CallExpr,
        dst_override: ?u32,
    ) anyerror!u32 {
        const call_plan = lowering.call;
        const emit_symbol = lowering_rules.staticCallEmitSymbol(call_plan);
        const lowered = try self.loweredFuncSymbol(emit_symbol);
        var text = std.ArrayList(u8).init(self.allocator);
        var release_regs = std.ArrayList(u32).init(self.allocator);
        defer release_regs.deinit();
        var consume_regs = std.ArrayList(u32).init(self.allocator);
        defer consume_regs.deinit();
        var forget_regs = std.ArrayList(u32).init(self.allocator);
        defer forget_regs.deinit();
        var restores = std.ArrayList(struct { slot: u32, value: u32 }).init(self.allocator);
        defer restores.deinit();
        try text.writer().print("@{s}(", .{lowered});
        for (call.args, 0..) |arg, i| {
            const param_info = try self.directSabCallParam(call_plan.target_symbol, i);
            const sibling_mark = try self.pushCallSiblingArgExprs(call.args, i);
            defer self.popExprLaterNodesTo(sibling_mark);
            const lowered_arg = try self.genPlannedSabCallArg(
                arg,
                call_plan,
                if (param_info) |info| info.param else null,
                if (param_info) |info| info.abi_borrow_auto_borrow else false,
                if (param_info) |info| info.abi_move_auto_move else false,
                i,
                call.associated_target == null,
            );
            if (self.plannedCallArgReleaseReg(lowered_arg.release_reg)) |reg| try release_regs.append(reg);
            if (lowered_arg.release_regs.len != 0) {
                try release_regs.appendSlice(lowered_arg.release_regs);
                self.allocator.free(lowered_arg.release_regs);
            }
            if (lowered_arg.consume_reg) |reg| try consume_regs.append(reg);
            if (lowered_arg.forget_reg) |reg| try forget_regs.append(reg);
            if (lowered_arg.restore_slot) |slot| {
                try restores.append(.{ .slot = slot, .value = lowered_arg.restore_value orelse return Error.UnsupportedSabDirectFeature });
            }
            if (i > 0) try text.appendSlice(", ");
            try text.appendSlice(lowered_arg.operand);
        }
        try text.append(')');
        const body = try text.toOwnedSlice();
        const dst = if (self.tc.extern_funcs.get(call_plan.target_symbol)) |ext| blk: {
            if (!ext.return_fallible) break :blk if (dst_override) |dst_reg| dst_blk: {
                if (lowering.result.returns_void) return Error.UnsupportedSabDirectFeature;
                try self.emitCallBody(dst_reg, body);
                break :dst_blk dst_reg;
            } else try self.emitPlannedCallBody(lowering.result, body);
            break :blk try self.emitFallibleExternPayloadBody(ext, body, dst_override);
        } else if (dst_override) |dst_reg| blk: {
            if (lowering.result.returns_void) return Error.UnsupportedSabDirectFeature;
            try self.emitCallBody(dst_reg, body);
            break :blk dst_reg;
        } else try self.emitPlannedCallBody(lowering.result, body);
        for (restores.items) |restore| {
            try self.emitStore(restore.slot, 0, restore.value, .ptr);
            try self.markConsumed(restore.value);
        }
        try self.releaseNonLocalTemps(release_regs.items);
        for (consume_regs.items) |reg| try self.emitMove(reg);
        for (forget_regs.items) |reg| try self.markConsumed(reg);
        const maybe_func = self.tc.funcs.get(call_plan.target_symbol);
        if (maybe_func) |func| {
            if (lowering_rules.planAsyncJoin2AwaitContinuation(func) != null) {
                try self.future_state_vtables.put(dst, try self.asyncJoin2AwaitVTableName(call_plan.target_symbol));
                try self.recordFutureReadiness(dst, .unknown);
            } else if (lowering_rules.planAsyncTwoAwaitContinuation(func) != null) {
                try self.future_state_vtables.put(dst, try self.asyncTwoAwaitVTableName(call_plan.target_symbol));
                try self.recordFutureReadiness(dst, .unknown);
            } else if (lowering_rules.planAsyncSingleAwaitContinuation(func) != null) {
                try self.future_state_vtables.put(dst, try self.asyncSingleAwaitVTableName(call_plan.target_symbol));
                try self.recordFutureReadiness(dst, .unknown);
            }
        }
        return dst;
    }

    fn emitPlannedCallBody(self: *Codegen, result_plan: lowering_rules.StaticCallResultPlan, body: []const u8) !u32 {
        if (!result_plan.returns_void) {
            const dst = try self.intern(try self.newTmp());
            try self.emitCallBody(dst, body);
            return dst;
        }
        try self.emitCallBody(null, body);
        const sentinel = try self.intern(try self.newTmp());
        try self.emitAssignImm(sentinel, 0);
        return sentinel;
    }

    fn emitFallibleExternPayloadBody(
        self: *Codegen,
        ext: contract_parser.ExternalFunction,
        body: []const u8,
        dst_override: ?u32,
    ) !u32 {
        const fallible_reg = try self.intern(try self.newTmp());
        try self.emitCallBody(fallible_reg, body);
        const payload_reg = dst_override orelse try self.intern(try self.newTmp());
        try self.emitLoad(payload_reg, fallible_reg, 8, abiPrimType(ext.ret_ty));
        try self.emitRelease(fallible_reg);
        return payload_reg;
    }

    const SabLoweredCallArg = struct {
        operand: []const u8,
        release_reg: ?u32,
        release_regs: []const u32 = &.{},
        consume_reg: ?u32 = null,
        forget_reg: ?u32 = null,
        restore_slot: ?u32 = null,
        restore_value: ?u32 = null,
        output_bind_name: ?[]const u8 = null,
        output_bind_ty: ?*const ast.Type = null,
    };

    const DirectSabCallParam = struct {
        param: ast.Param,
        abi_borrow_auto_borrow: bool = false,
        abi_move_auto_move: bool = false,
    };

    fn directSabExternParam(self: *Codegen, param: contract_parser.Param) !DirectSabCallParam {
        const ty = try self.astTypeForAbiRaw(param.ty);
        return .{
            .param = .{
                .name = param.name,
                .ty = @constCast(ty),
                .is_borrow = param.is_borrow,
                .is_move = param.is_move,
            },
            .abi_borrow_auto_borrow = param.is_borrow,
            .abi_move_auto_move = param.is_move,
        };
    }

    fn directSabCallParam(self: *Codegen, target_symbol: []const u8, index: usize) !?DirectSabCallParam {
        if (self.tc.funcs.get(target_symbol)) |func| {
            if (index < func.params.len) {
                const param = func.params[index];
                const cap = self.paramCapability(param);
                return .{
                    .param = param,
                    .abi_borrow_auto_borrow = cap == .borrow,
                    .abi_move_auto_move = cap == .move,
                };
            }
            return null;
        }
        if (self.tc.imported_function_signatures.get(target_symbol)) |signature| {
            if (index < signature.params.len) return .{ .param = signature.params[index] };
            return null;
        }
        if (self.tc.extern_funcs.get(target_symbol)) |ext| {
            if (index < ext.params.len) return try self.directSabExternParam(ext.params[index]);
            return null;
        }
        return null;
    }

    fn plannedCallArgReleaseReg(self: *Codegen, candidate: ?u32) ?u32 {
        const carries_refcell_borrow_handle = if (candidate) |reg| self.refcell_borrow_values.contains(reg) else false;
        const lifecycle = lowering_rules.planRefCellCallArgLifecycle(
            candidate != null,
            carries_refcell_borrow_handle,
        );
        return if (lifecycle.shouldRelease()) candidate.? else null;
    }

    fn borrowAddressCallArgReleaseRegs(self: *Codegen, source: AddressSource, prefix: u8) ![]const u32 {
        const plan = lowering_rules.planPrefixedBorrowAddressCallArgRelease(prefix, !self.isLocalReg(source.reg), source.release_regs.len != 0, source.restore_slot != null);
        var regs = std.ArrayList(u32).init(self.allocator);
        defer regs.deinit();
        if (plan.release_address_value) try regs.append(source.reg);
        if (plan.release_source_temps) try regs.appendSlice(source.release_regs);
        return try self.ownedReleaseRegs(regs.items);
    }

    fn prefixedBorrowAddressOperand(self: *Codegen, source_reg: u32, prefix: u8) ![]const u8 {
        const operand_prefix = lowering_rules.prefixedBorrowAddressCallArgOperandPrefix(prefix, true) orelse return self.symbols.items[source_reg];
        return try std.fmt.allocPrint(self.allocator, "{c}{s}", .{ operand_prefix, self.symbols.items[source_reg] });
    }

    fn externBorrowCallOperand(self: *Codegen, operand: []const u8) ![]const u8 {
        if (std.mem.startsWith(u8, operand, "&")) return operand;
        return try std.fmt.allocPrint(self.allocator, "&{s}", .{operand});
    }

    fn fieldBorrowLoadsStoredPointer(self: *Codegen, field_ty: *const ast.Type) bool {
        if (!lowering_rules.structFieldIsPointerBacked(field_ty)) return false;
        if (lowering_rules.smartPointerType(field_ty) != null) return false;
        return !self.typeIsCopyValue(field_ty) and !lowering_rules.isBorrowLikeType(field_ty);
    }

    fn fieldProjectionReleaseRegs(self: *Codegen, projection: AddressSource) ![]const u32 {
        var regs = std.ArrayList(u32).init(self.allocator);
        defer regs.deinit();
        if (!self.isLocalReg(projection.reg)) try regs.append(projection.reg);
        for (projection.release_regs) |reg| {
            if (reg != projection.reg) try regs.append(reg);
        }
        return try self.ownedReleaseRegs(regs.items);
    }

    fn moveCallArgFromValueReg(self: *Codegen, value_reg: u32) !SabLoweredCallArg {
        const moved_reg = try self.intern(try self.newTmp());
        try self.emitAssignReg(moved_reg, value_reg);
        try self.markConsumed(value_reg);
        return .{
            .operand = try std.fmt.allocPrint(self.allocator, "^{s}", .{self.symbols.items[moved_reg]}),
            .release_reg = null,
        };
    }

    fn genPrefixedBorrowAddressCallArg(self: *Codegen, arg: *const ast.Node, prefix: u8) anyerror!?SabLoweredCallArg {
        const inner = switch (arg.*) {
            .borrow_expr => |borrow| if (prefix == '&') borrow.expr else return null,
            .move_expr => |move| if (prefix == '^') {
                const value_reg = try self.genExpr(move.expr);
                return try self.moveCallArgFromValueReg(value_reg);
            } else return null,
            else => return null,
        };
        if (prefix == '&' and inner.* == .field_expr) {
            const inner_ty = self.tc.expr_types.get(inner);
            if (inner_ty != null and self.fieldBorrowLoadsStoredPointer(inner_ty.?)) {
                const projection = try self.genFieldAddress(inner.field_expr);
                const owner = try self.intern(try self.newTmp());
                try self.emitLoad(owner, projection.reg, 0, .ptr);
                try self.markNonOwningReg(owner);
                return .{
                    .operand = try std.fmt.allocPrint(self.allocator, "&{s}", .{self.symbols.items[owner]}),
                    .release_reg = owner,
                    .release_regs = try self.fieldProjectionReleaseRegs(projection),
                };
            }
        }
        const source = try self.genAddressOf(inner);
        const has_later_nodes = self.current_expr_later_nodes.items.len != 0;
        if (prefix == '&' and source.restore_slot != null and has_later_nodes) {
            try self.emitStore(source.restore_slot.?, 0, source.reg, .ptr);
            try self.markNonOwningReg(source.reg);
            return .{
                .operand = try self.prefixedBorrowAddressOperand(source.reg, prefix),
                .release_reg = source.reg,
                .release_regs = try self.ownedReleaseRegs(source.release_regs),
                .restore_slot = null,
                .restore_value = null,
            };
        }
        return .{
            .operand = try self.prefixedBorrowAddressOperand(source.reg, prefix),
            .release_reg = null,
            .release_regs = try self.borrowAddressCallArgReleaseRegs(source, prefix),
            .restore_slot = source.restore_slot,
            .restore_value = if (source.restore_slot != null) source.reg else null,
        };
    }

    fn genMacroPrefixedBorrowAddressCallArg(self: *Codegen, arg: *const ast.Node, ctx: *MacroExpansionContext, prefix: u8) anyerror!?SabLoweredCallArg {
        const inner = switch (arg.*) {
            .borrow_expr => |borrow| if (prefix == '&') borrow.expr else return null,
            .move_expr => |move| if (prefix == '^') {
                const value_reg = try self.genMacroExpr(move.expr, ctx);
                return try self.moveCallArgFromValueReg(value_reg);
            } else return null,
            else => return null,
        };
        if (prefix == '&' and inner.* == .field_expr) {
            const inner_ty = self.tc.expr_types.get(inner);
            if (inner_ty != null and self.fieldBorrowLoadsStoredPointer(inner_ty.?)) {
                const projection = try self.genMacroAddressOf(inner, ctx);
                const owner = try self.intern(try self.newTmp());
                try self.emitLoad(owner, projection.reg, 0, .ptr);
                try self.markNonOwningReg(owner);
                return .{
                    .operand = try std.fmt.allocPrint(self.allocator, "&{s}", .{self.symbols.items[owner]}),
                    .release_reg = owner,
                    .release_regs = try self.fieldProjectionReleaseRegs(projection),
                };
            }
        }
        const source = try self.genMacroAddressOf(inner, ctx);
        const has_later_nodes = self.current_expr_later_nodes.items.len != 0;
        if (prefix == '&' and source.restore_slot != null and has_later_nodes) {
            try self.emitStore(source.restore_slot.?, 0, source.reg, .ptr);
            try self.markNonOwningReg(source.reg);
            return .{
                .operand = try self.prefixedBorrowAddressOperand(source.reg, prefix),
                .release_reg = source.reg,
                .release_regs = try self.ownedReleaseRegs(source.release_regs),
                .restore_slot = null,
                .restore_value = null,
            };
        }
        return .{
            .operand = try self.prefixedBorrowAddressOperand(source.reg, prefix),
            .release_reg = null,
            .release_regs = try self.borrowAddressCallArgReleaseRegs(source, prefix),
            .restore_slot = source.restore_slot,
            .restore_value = if (source.restore_slot != null) source.reg else null,
        };
    }

    fn genArrayBorrowToSliceArgFromBase(
        self: *Codegen,
        inner: *const ast.Node,
        release_after_call: bool,
        base_source_reg: u32,
    ) anyerror!SabLoweredCallArg {
        const inner_ty = self.tc.expr_types.get(inner) orelse return Error.MissingType;
        if (inner_ty.* != .array) return Error.UnsupportedSabDirectFeature;
        const arr = inner_ty.array;

        const len_reg = try self.intern(try self.newTmp());
        try self.emitAssignImm(len_reg, @intCast(arr.len));

        const slice_reg = try self.intern(try self.newTmp());
        try self.emitStackAlloc(slice_reg, lowering_rules.SliceAbi.size);
        try self.markNonOwningReg(slice_reg);
        try self.emitStdMacroFragment("sa_std/core/slice.sa", "SLICE_NEW", &.{
            self.symbols.items[slice_reg],
            self.symbols.items[base_source_reg],
            self.symbols.items[len_reg],
        });
        try self.emitRelease(len_reg);

        var extra_releases = std.ArrayList(u32).init(self.allocator);
        defer extra_releases.deinit();
        if (release_after_call and !self.isLocalReg(base_source_reg)) {
            try extra_releases.append(base_source_reg);
        }

        return .{
            .operand = self.symbols.items[slice_reg],
            .release_reg = null,
            .release_regs = try self.ownedReleaseRegs(extra_releases.items),
        };
    }

    fn genArrayBorrowToSliceArg(
        self: *Codegen,
        arg: *const ast.Node,
        release_after_call: bool,
    ) anyerror!SabLoweredCallArg {
        if (arg.* != .borrow_expr) return Error.UnsupportedSabDirectFeature;
        const inner = arg.borrow_expr.expr;
        const base_source_reg = try self.genExpr(@constCast(inner));
        return try self.genArrayBorrowToSliceArgFromBase(inner, release_after_call, base_source_reg);
    }

    fn genMacroArrayBorrowToSliceArg(
        self: *Codegen,
        arg: *const ast.Node,
        effective_arg: *const ast.Node,
        ctx: *MacroExpansionContext,
        release_after_call: bool,
    ) anyerror!SabLoweredCallArg {
        if (arg.* == .borrow_expr) {
            const inner = arg.borrow_expr.expr;
            const base_source_reg = try self.genMacroExpr(@constCast(inner), ctx);
            return try self.genArrayBorrowToSliceArgFromBase(inner, release_after_call, base_source_reg);
        }
        if (effective_arg.* != .borrow_expr) return Error.UnsupportedSabDirectFeature;
        const inner = effective_arg.borrow_expr.expr;
        const base_source_reg = try self.genExpr(@constCast(inner));
        return try self.genArrayBorrowToSliceArgFromBase(inner, release_after_call, base_source_reg);
    }

    fn generatedFnPtrIdentifierArg(self: *Codegen, arg: *const ast.Node) bool {
        return arg.* == .identifier and self.tc.funcs.contains(arg.identifier) and self.exprHasFnPtrType(arg);
    }

    fn generatedScalarConstIdentifierArg(self: *Codegen, arg: *const ast.Node) bool {
        return arg.* == .identifier and self.global_scalar_consts.contains(arg.identifier);
    }

    fn materializeFnPtrValueArgSlot(self: *Codegen, source_reg: u32, release_source_after_call: bool) !SabLoweredCallArg {
        const target = try self.intern(try self.newTmp());
        try self.emitLoad(target, source_reg, 0, .ptr);
        const slot = try self.intern(try self.newTmp());
        try self.emitStackAlloc(slot, 8);
        try self.emitStore(slot, 0, target, .ptr);
        try self.emitMove(target);
        return .{
            .operand = self.symbols.items[slot],
            .release_reg = if (release_source_after_call) source_reg else null,
        };
    }

    fn isGeneratedFnPtrValueArg(self: *Codegen, arg: *const ast.Node, param: ?ast.Param) bool {
        const target_param = param orelse return false;
        if (target_param.is_borrow or target_param.is_move or target_param.ty.* != .fn_ptr) return false;
        if (arg.* != .identifier) return false;
        const arg_ty = self.tc.expr_types.get(arg) orelse return false;
        if (arg_ty.* != .fn_ptr) return false;
        return self.tc.funcs.contains(arg.identifier);
    }

    fn isLocalFnPtrValueArg(self: *Codegen, arg: *const ast.Node, param: ?ast.Param) bool {
        const target_param = param orelse return false;
        if (target_param.is_borrow or target_param.is_move or target_param.ty.* != .fn_ptr) return false;
        if (arg.* != .identifier or self.tc.funcs.contains(arg.identifier)) return false;
        const arg_ty = self.tc.expr_types.get(arg) orelse return false;
        if (arg_ty.* != .fn_ptr) return false;
        _ = self.localReg(arg.identifier) orelse return false;
        return true;
    }

    fn isShallowCopyValueArg(self: *Codegen, arg: *const ast.Node, param: ?ast.Param, arg_ty: ?*const ast.Type) bool {
        const target_param = param orelse return false;
        if (target_param.is_borrow or target_param.is_move) return false;
        if (arg.* != .identifier) return false;
        const ty = arg_ty orelse target_param.ty;
        if (ty.* != .user_defined) return false;
        if (self.typeIsCopyValue(ty) or lowering_rules.isBorrowLikeType(ty)) return false;
        return self.typeIsShallowCopyCallArgValue(ty, 0);
    }

    fn callArgType(self: *Codegen, arg: *const ast.Node) !?*const ast.Type {
        if (arg.* == .identifier) {
            if (self.localType(arg.identifier)) |ty| return ty;
        }
        return try self.exprTypeOrFallback(arg);
    }

    fn valueArgTransfersOwnership(self: *Codegen, param: ?ast.Param, arg_ty: ?*const ast.Type) bool {
        const target_param = param orelse return false;
        if (target_param.is_borrow or target_param.is_move) return false;
        if (lowering_rules.byValueRawPointerParam(target_param)) return false;
        const ty = arg_ty orelse target_param.ty;
        if (lowering_rules.isBorrowLikeType(ty)) return false;
        return !self.typeIsCopyValue(ty);
    }

    fn stackSlotIdentifierTempNeedsReleaseForParam(self: *Codegen, param: ?ast.Param, arg: *const ast.Node, arg_reg: u32) bool {
        if (param) |target_param| {
            if (lowering_rules.byValueRawPointerParam(target_param)) return false;
        }
        return arg.* == .identifier and self.stackLocal(arg.identifier) != null and !self.isLocalReg(arg_reg);
    }

    fn stackSlotIdentifierTempNeedsConsumeForParam(self: *Codegen, param: ?ast.Param, arg: *const ast.Node, arg_reg: u32) bool {
        const target_param = param orelse return false;
        if (!lowering_rules.byValueRawPointerParam(target_param)) return false;
        return arg.* == .identifier and self.stackLocal(arg.identifier) != null and !self.isLocalReg(arg_reg);
    }

    fn genPlannedSabCallArg(
        self: *Codegen,
        arg: *const ast.Node,
        call_plan: lowering_rules.StaticCallPlan,
        param: ?ast.Param,
        abi_borrow_auto_borrow: bool,
        abi_move_auto_move: bool,
        arg_index: usize,
        auto_borrow_receiver: bool,
    ) anyerror!SabLoweredCallArg {
        const arg_ty = try self.callArgType(arg);
        const materialization = lowering_rules.planCallArgMaterialization(arg, .{
            .target = .direct_sab,
            .param = param,
            .arg_ty = arg_ty,
            .arg_index = arg_index,
            .auto_borrow_receiver = auto_borrow_receiver,
            .abi_borrow_auto_borrow = abi_borrow_auto_borrow,
            .array_to_slice_borrow = self.tc.array_to_slice_borrow_args.contains(arg),
            .dyn_borrow_trait_name = self.tc.dyn_borrow_args.get(arg),
            .copy_struct_value = if (param) |p| !p.is_borrow and !p.is_move and arg.* == .identifier and self.typeIsCopyStruct(p.ty) else false,
            .generated_fn_ptr_identifier = self.isGeneratedFnPtrValueArg(arg, param),
            .local_fn_ptr_identifier = self.isLocalFnPtrValueArg(arg, param),
            .preserve_identifier_for_later_use = arg.* == .identifier and self.identifierMustStayLiveForLaterUse(arg.identifier),
            .shallow_copy_value = self.isShallowCopyValueArg(arg, param, arg_ty),
            .generated_scalar_const_identifier = self.generatedScalarConstIdentifierArg(arg),
            .value_arg_transfers_ownership = self.valueArgTransfersOwnership(param, arg_ty),
        });

        return switch (materialization.kind) {
            .raw_pointer_string_literal => blk: {
                if (arg.* != .literal or arg.literal != .string_val) return Error.UnsupportedSabDirectFeature;
                const arg_reg = try self.genRawPointerStringLiteralArg(arg.literal.string_val);
                if (param) |target_param| {
                    if (self.paramCapability(target_param) == .move) {
                        break :blk .{
                            .operand = try std.fmt.allocPrint(self.allocator, "^{s}", .{self.symbols.items[arg_reg]}),
                            .release_reg = null,
                            .forget_reg = arg_reg,
                        };
                    }
                }
                break :blk .{ .operand = self.symbols.items[arg_reg], .release_reg = arg_reg };
            },
            .array_to_slice_borrow => try self.genArrayBorrowToSliceArg(arg, materialization.release_after_call),
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
            .generated_fn_ptr_value_slot => blk: {
                const arg_reg = try self.genExpr(@constCast(arg));
                var fnptr_slot = try self.materializeFnPtrValueArgSlot(arg_reg, materialization.release_after_call);
                fnptr_slot.operand = try std.fmt.allocPrint(self.allocator, "&{s}", .{fnptr_slot.operand});
                break :blk fnptr_slot;
            },
            .borrow_local_fn_ptr_value => blk: {
                const arg_reg = try self.genExpr(@constCast(arg));
                break :blk .{
                    .operand = try std.fmt.allocPrint(self.allocator, "&{s}", .{self.symbols.items[arg_reg]}),
                    .release_reg = null,
                };
            },
            .shallow_copy_preserved_value => blk: {
                const ty = arg_ty orelse return Error.UnsupportedSabDirectFeature;
                const arg_reg = try self.genExpr(@constCast(arg));
                const copied = try self.genShallowCopyCallArgValue(arg_reg, ty);
                break :blk .{
                    .operand = try std.fmt.allocPrint(self.allocator, "^{s}", .{self.symbols.items[copied]}),
                    .release_reg = null,
                    .forget_reg = copied,
                };
            },
            .auto_borrow => blk: {
                const arg_reg = try self.genExpr(@constCast(arg));
                break :blk .{
                    .operand = try std.fmt.allocPrint(self.allocator, "&{s}", .{self.symbols.items[arg_reg]}),
                    .release_reg = arg_reg,
                };
            },
            .value => blk: {
                const abi_move_prefix: ?u8 = if (abi_move_auto_move and arg.* != .move_expr) '^' else null;
                if (call_plan.argPrefix(arg) orelse abi_move_prefix) |prefix| {
                    if (try self.genPrefixedBorrowAddressCallArg(arg, prefix)) |borrowed| {
                        var effective = borrowed;
                        if (prefix == '&' and abi_borrow_auto_borrow) {
                            effective.operand = try self.externBorrowCallOperand(effective.operand);
                        }
                        break :blk effective;
                    }
                    const arg_reg = try self.genExpr(@constCast(arg));
                    if (prefix == '^' and
                        arg.* == .identifier and
                        self.isShallowCopyValueArg(arg, param, arg_ty))
                    {
                        const ty = arg_ty orelse (param orelse return Error.UnsupportedSabDirectFeature).ty;
                        const copied = try self.genShallowCopyCallArgValue(arg_reg, ty);
                        break :blk .{
                            .operand = try std.fmt.allocPrint(self.allocator, "^{s}", .{self.symbols.items[copied]}),
                            .release_reg = null,
                            .forget_reg = copied,
                        };
                    }
                    const release_reg: ?u32 = if (materialization.release_after_call) arg_reg else null;
                    const operand = try std.fmt.allocPrint(self.allocator, "{c}{s}", .{ prefix, self.symbols.items[arg_reg] });
                    break :blk .{
                        .operand = if (prefix == '&' and abi_borrow_auto_borrow) try self.externBorrowCallOperand(operand) else operand,
                        .release_reg = if (prefix == '^') null else release_reg,
                        .forget_reg = if (prefix == '^') arg_reg else null,
                    };
                }
                const arg_reg = try self.genExpr(@constCast(arg));
                if (materialization.transfers_ownership) {
                    break :blk .{
                        .operand = self.symbols.items[arg_reg],
                        .release_reg = null,
                        .forget_reg = arg_reg,
                    };
                }
                if (abi_borrow_auto_borrow) {
                    break :blk .{
                        .operand = try self.externBorrowCallOperand(self.symbols.items[arg_reg]),
                        .release_reg = if (materialization.release_after_call or self.stackSlotIdentifierTempNeedsReleaseForParam(param, arg, arg_reg)) arg_reg else null,
                    };
                }
                const release_reg: ?u32 = if (materialization.release_after_call or self.stackSlotIdentifierTempNeedsReleaseForParam(param, arg, arg_reg)) arg_reg else null;
                const consume_temp = self.stackSlotIdentifierTempNeedsConsumeForParam(param, arg, arg_reg);
                const consumption = lowering_rules.planValueCallArgConsumption(
                    arg,
                    param,
                    arg_ty,
                    if (arg_ty) |ty| self.typeIsCopyValue(ty) else false,
                    false,
                    self.isParamReg(arg_reg),
                    if (arg_ty) |ty| userDefinedStdOwnerIsNonCopy(ty) else false,
                    self.current_expr_result_escapes,
                );
                const keep_for_later_use = arg.* == .identifier and self.identifierMustStayLiveForLaterUse(arg.identifier);
                const consume_source = (consumption.consumes_source or materialization.transfers_ownership) and !keep_for_later_use;
                break :blk .{
                    .operand = self.symbols.items[arg_reg],
                    .release_reg = if (consume_source) null else release_reg,
                    .consume_reg = if (consume_source or consume_temp) arg_reg else null,
                };
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
        abi_borrow_auto_borrow: bool,
        arg_index: usize,
        auto_borrow_receiver: bool,
    ) anyerror!SabLoweredCallArg {
        const materialization = lowering_rules.planCallArgMaterialization(effective_arg, .{
            .target = .direct_sab,
            .param = param,
            .arg_ty = self.tc.expr_types.get(effective_arg),
            .arg_index = arg_index,
            .auto_borrow_receiver = auto_borrow_receiver,
            .abi_borrow_auto_borrow = abi_borrow_auto_borrow,
            .array_to_slice_borrow = self.tc.array_to_slice_borrow_args.contains(effective_arg),
            .dyn_borrow_trait_name = self.tc.dyn_borrow_args.get(effective_arg),
            .copy_struct_value = if (param) |p| !p.is_borrow and !p.is_move and effective_arg.* == .identifier and self.typeIsCopyStruct(p.ty) else false,
            .generated_fn_ptr_identifier = self.generatedFnPtrIdentifierArg(effective_arg),
            .generated_scalar_const_identifier = self.generatedScalarConstIdentifierArg(effective_arg),
            .preserve_identifier_for_later_use = effective_arg.* == .identifier and self.identifierMustStayLiveForLaterUse(effective_arg.identifier),
            .shallow_copy_value = self.isShallowCopyValueArg(effective_arg, param, self.tc.expr_types.get(effective_arg)),
            .value_arg_transfers_ownership = self.valueArgTransfersOwnership(param, self.tc.expr_types.get(effective_arg)),
        });

        return switch (materialization.kind) {
            .raw_pointer_string_literal => blk: {
                if (effective_arg.* != .literal or effective_arg.literal != .string_val) return Error.UnsupportedSabDirectFeature;
                const arg_reg = try self.genRawPointerStringLiteralArg(effective_arg.literal.string_val);
                if (param) |target_param| {
                    if (self.paramCapability(target_param) == .move) {
                        break :blk .{
                            .operand = try std.fmt.allocPrint(self.allocator, "^{s}", .{self.symbols.items[arg_reg]}),
                            .release_reg = null,
                            .forget_reg = arg_reg,
                        };
                    }
                }
                break :blk .{ .operand = self.symbols.items[arg_reg], .release_reg = arg_reg };
            },
            .array_to_slice_borrow => try self.genMacroArrayBorrowToSliceArg(arg, effective_arg, ctx, materialization.release_after_call),
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
            .generated_fn_ptr_value_slot => blk: {
                const arg_reg = try self.genMacroExpr(@constCast(arg), ctx);
                var fnptr_slot = try self.materializeFnPtrValueArgSlot(arg_reg, materialization.release_after_call);
                fnptr_slot.operand = try std.fmt.allocPrint(self.allocator, "&{s}", .{fnptr_slot.operand});
                break :blk fnptr_slot;
            },
            .borrow_local_fn_ptr_value => blk: {
                const arg_reg = try self.genMacroExpr(@constCast(arg), ctx);
                break :blk .{
                    .operand = try std.fmt.allocPrint(self.allocator, "&{s}", .{self.symbols.items[arg_reg]}),
                    .release_reg = null,
                };
            },
            .shallow_copy_preserved_value => blk: {
                const effective_ty = self.tc.expr_types.get(effective_arg) orelse return Error.UnsupportedSabDirectFeature;
                const arg_reg = try self.genMacroExpr(@constCast(arg), ctx);
                const copied = try self.genShallowCopyCallArgValue(arg_reg, effective_ty);
                break :blk .{
                    .operand = try std.fmt.allocPrint(self.allocator, "^{s}", .{self.symbols.items[copied]}),
                    .release_reg = null,
                    .forget_reg = copied,
                };
            },
            .auto_borrow => blk: {
                const arg_reg = try self.genMacroExpr(@constCast(arg), ctx);
                break :blk .{
                    .operand = try std.fmt.allocPrint(self.allocator, "&{s}", .{self.symbols.items[arg_reg]}),
                    .release_reg = arg_reg,
                };
            },
            .value => blk: {
                if (call_plan.argPrefix(effective_arg)) |prefix| {
                    if (try self.genMacroPrefixedBorrowAddressCallArg(arg, ctx, prefix)) |borrowed| {
                        var effective = borrowed;
                        if (prefix == '&' and abi_borrow_auto_borrow) {
                            effective.operand = try self.externBorrowCallOperand(effective.operand);
                        }
                        break :blk effective;
                    }
                    const arg_reg = try self.genMacroExpr(@constCast(arg), ctx);
                    const release_reg: ?u32 = if (materialization.release_after_call) arg_reg else null;
                    const operand = try std.fmt.allocPrint(self.allocator, "{c}{s}", .{ prefix, self.symbols.items[arg_reg] });
                    break :blk .{
                        .operand = if (prefix == '&' and abi_borrow_auto_borrow) try self.externBorrowCallOperand(operand) else operand,
                        .release_reg = if (prefix == '^') null else release_reg,
                        .forget_reg = if (prefix == '^') arg_reg else null,
                    };
                }
                const arg_reg = try self.genMacroExpr(@constCast(arg), ctx);
                if (materialization.transfers_ownership) {
                    break :blk .{
                        .operand = self.symbols.items[arg_reg],
                        .release_reg = null,
                        .forget_reg = arg_reg,
                    };
                }
                if (abi_borrow_auto_borrow) {
                    break :blk .{
                        .operand = try self.externBorrowCallOperand(self.symbols.items[arg_reg]),
                        .release_reg = if (materialization.release_after_call) arg_reg else null,
                    };
                }
                const release_reg: ?u32 = if (materialization.release_after_call or self.stackSlotIdentifierTempNeedsReleaseForParam(param, effective_arg, arg_reg)) arg_reg else null;
                const consume_temp = self.stackSlotIdentifierTempNeedsConsumeForParam(param, effective_arg, arg_reg);
                const effective_ty = self.tc.expr_types.get(effective_arg);
                const consumption = lowering_rules.planValueCallArgConsumption(
                    effective_arg,
                    param,
                    effective_ty,
                    if (effective_ty) |arg_ty| self.typeIsCopyValue(arg_ty) else false,
                    false,
                    self.isParamReg(arg_reg),
                    if (effective_ty) |ty| userDefinedStdOwnerIsNonCopy(ty) else false,
                    self.current_expr_result_escapes,
                );
                const keep_for_later_use = effective_arg.* == .identifier and self.identifierMustStayLiveForLaterUse(effective_arg.identifier);
                const consume_source = (consumption.consumes_source or materialization.transfers_ownership) and !keep_for_later_use;
                break :blk .{
                    .operand = self.symbols.items[arg_reg],
                    .release_reg = if (consume_source) null else release_reg,
                    .consume_reg = if (consume_source or consume_temp) arg_reg else null,
                };
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

    fn genInlineClosureUnary(self: *Codegen, closure: *const ast.ClosureLiteral, arg_reg: u32) anyerror!u32 {
        if (closure.params.len != 1) return Error.UnsupportedSabDirectFeature;
        var saved = std.ArrayList(SavedClosureParam).init(self.allocator);
        defer saved.deinit();
        try saved.append(.{ .name = closure.params[0].name, .old = self.closure_param_regs.get(closure.params[0].name) });
        try self.closure_param_regs.put(closure.params[0].name, arg_reg);
        defer self.restoreClosureParams(saved.items);
        return try self.genExpr(@constCast(closure.body));
    }

    fn genInlineClosureNullary(self: *Codegen, closure: *const ast.ClosureLiteral) anyerror!u32 {
        if (closure.params.len != 0) return Error.UnsupportedSabDirectFeature;
        return try self.genExpr(@constCast(closure.body));
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
        const head_label = try self.newLabel("L_WHILE_HEAD");
        const body_label = try self.newLabel("L_WHILE_BODY");
        const cond_false_label = try self.newLabel("L_WHILE_COND_FALSE");
        const exit_label = try self.newLabel("L_WHILE_EXIT");

        try self.emitJmp(head_label);
        try self.emitLabel(head_label);
        const cond = try self.genExpr(w.cond);

        if (w.let_pattern) |pattern| {
            const enum_decl = try self.enumDeclForPatternValue(w.cond, pattern);
            const plan = lowering_rules.planWhileLetPattern(pattern, enum_decl != null) orelse return Error.UnsupportedSabDirectFeature;
            const cond_ty = self.tc.expr_types.get(w.cond) orelse return Error.MissingType;
            const branch_flag = try self.intern(try self.newTmp());
            try self.recordReg(branch_flag);

            switch (plan.kind) {
                .enum_variant => {
                    const decl = enum_decl orelse return Error.UnsupportedSabDirectFeature;
                    const tag = lowering_rules.enumVariantIndex(decl, pattern.variant_name) orelse return Error.UnsupportedSabDirectFeature;
                    const tag_reg = try self.intern(try self.newTmp());
                    try self.emitLoad(tag_reg, cond, lowering_rules.enum_tag_offset, .i64);
                    try self.emitOp(branch_flag, .eq, .{ .reg = tag_reg }, .{ .imm_i64 = @intCast(tag) });
                    try self.emitRelease(tag_reg);
                },
                .option_some, .option_none => try self.emitStdMacroFragment("sa_std/core/option.sa", "OPTION_IS_SOME", &.{
                    self.symbols.items[branch_flag],
                    self.symbols.items[cond],
                }),
                .result_ok, .result_err => try self.emitStdMacroFragment("sa_std/core/result.sa", "RESULT_IS_OK", &.{
                    self.symbols.items[branch_flag],
                    self.symbols.items[cond],
                }),
            }

            try self.emitBranch(
                branch_flag,
                if (plan.success_on_true) body_label else cond_false_label,
                if (plan.success_on_true) cond_false_label else body_label,
            );

            const body_locals_len = self.locals.items.len;
            var pre_released = try self.released_regs.clone();
            defer pre_released.deinit();
            var pre_refcell_values = try self.cloneRefCellBorrowValues();
            defer self.deinitRefCellBorrowValueSnapshot(&pre_refcell_values);
            var pre_refcell_temps = try self.cloneBorrowAddressTemps();
            defer self.deinitBorrowAddressTempSnapshot(&pre_refcell_temps);

            try self.emitLabel(body_label);
            try self.emitBranchRelease(branch_flag);
            switch (plan.kind) {
                .enum_variant => {
                    const decl = enum_decl orelse return Error.UnsupportedSabDirectFeature;
                    const variant = lowering_rules.enumVariant(decl, pattern.variant_name) orelse return Error.UnsupportedSabDirectFeature;
                    if (pattern.bindings.len != variant.fields.len) return Error.UnsupportedSabDirectFeature;
                    for (pattern.bindings, variant.fields) |binding, field| {
                        const layout = lowering_rules.enumFieldLayout(variant, field.name) orelse return Error.UnsupportedSabDirectFeature;
                        const binding_reg = try self.intern(try self.newTmp());
                        try self.emitLoad(binding_reg, cond, layout.offset, try storagePrimType(layout.ty));
                        try self.pushTypedLocal(binding, binding_reg, false, field.ty);
                    }
                },
                .option_some => {
                    if (pattern.bindings.len > 1) return Error.UnsupportedSabDirectFeature;
                    if (pattern.bindings.len == 1) {
                        const inner_ty = lowering_rules.optionInnerType(cond_ty) orelse return Error.UnsupportedSabDirectFeature;
                        const binding_reg = try self.intern(try self.newTmp());
                        try self.recordReg(binding_reg);
                        try self.emitStdMacroFragment("sa_std/core/option.sa", "OPTION_GET", &.{
                            self.symbols.items[binding_reg],
                            self.symbols.items[cond],
                        });
                        try self.pushTypedLocal(pattern.bindings[0], binding_reg, false, inner_ty);
                    }
                },
                .option_none => if (pattern.bindings.len != 0) return Error.UnsupportedSabDirectFeature,
                .result_ok => {
                    if (pattern.bindings.len > 1) return Error.UnsupportedSabDirectFeature;
                    if (pattern.bindings.len == 1) {
                        const ok_ty = lowering_rules.resultOkType(cond_ty) orelse return Error.UnsupportedSabDirectFeature;
                        const binding_reg = try self.intern(try self.newTmp());
                        try self.recordReg(binding_reg);
                        try self.emitStdMacroFragment("sa_std/core/result.sa", "RESULT_GET_OK", &.{
                            self.symbols.items[binding_reg],
                            self.symbols.items[cond],
                        });
                        try self.pushTypedLocal(pattern.bindings[0], binding_reg, false, ok_ty);
                    }
                },
                .result_err => {
                    if (pattern.bindings.len > 1) return Error.UnsupportedSabDirectFeature;
                    if (pattern.bindings.len == 1) {
                        const err_ty = lowering_rules.resultErrType(cond_ty) orelse return Error.UnsupportedSabDirectFeature;
                        const binding_reg = try self.intern(try self.newTmp());
                        try self.recordReg(binding_reg);
                        try self.emitStdMacroFragment("sa_std/core/result.sa", "RESULT_GET_ERR", &.{
                            self.symbols.items[binding_reg],
                            self.symbols.items[cond],
                        });
                        try self.pushTypedLocal(pattern.bindings[0], binding_reg, false, err_ty);
                    }
                },
            }
            if (!self.isLocalReg(cond)) try self.emitBranchRelease(cond);
            try self.loop_continue_labels.append(head_label);
            try self.loop_break_labels.append(exit_label);
            try self.genBlock(w.body);
            _ = self.loop_continue_labels.pop();
            _ = self.loop_break_labels.pop();
            if (!self.lastIsTerminator()) {
                try self.releaseLocalsFrom(body_locals_len, null);
                try self.emitJmp(head_label);
            }

            self.popLocalsTo(body_locals_len);
            try self.restoreReleased(&pre_released);
            switch (lowering_rules.planRefCellLoopStateMerge()) {
                .restore_pre_loop => try self.restoreRefCellBranchState(&pre_refcell_values, &pre_refcell_temps),
            }

            try self.emitLabel(cond_false_label);
            try self.emitBranchRelease(branch_flag);
            if (!self.isLocalReg(cond)) try self.emitBranchRelease(cond);
            try self.emitJmp(exit_label);

            try self.emitLabel(exit_label);
            return;
        }

        var br = self.makeInst(.br);
        br.operands[0] = .{ .reg = cond };
        br.operands[1] = .{ .label = try self.intern(body_label) };
        br.operands[2] = .{ .label = try self.intern(body_label) };
        br.operands[3] = .{ .label = try self.intern(cond_false_label) };
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
        var pre_refcell_values = try self.cloneRefCellBorrowValues();
        defer self.deinitRefCellBorrowValueSnapshot(&pre_refcell_values);
        var pre_refcell_temps = try self.cloneBorrowAddressTemps();
        defer self.deinitBorrowAddressTempSnapshot(&pre_refcell_temps);

        try self.emitLabel(body_label);
        if (!self.isLocalReg(cond)) try self.emitBranchRelease(cond);
        try self.loop_continue_labels.append(head_label);
        try self.loop_break_labels.append(exit_label);
        try self.genBlock(w.body);
        _ = self.loop_continue_labels.pop();
        _ = self.loop_break_labels.pop();
        if (!self.lastIsTerminator()) {
            try self.releaseLocalsFrom(body_locals_len, null);
            try self.emitJmp(head_label);
        }

        self.popLocalsTo(body_locals_len);
        try self.restoreReleased(&pre_released);
        switch (lowering_rules.planRefCellLoopStateMerge()) {
            .restore_pre_loop => try self.restoreRefCellBranchState(&pre_refcell_values, &pre_refcell_temps),
        }

        try self.emitLabel(cond_false_label);
        if (!self.isLocalReg(cond)) try self.emitBranchRelease(cond);
        try self.emitJmp(exit_label);

        try self.emitLabel(exit_label);
    }

    fn genFor(self: *Codegen, f: ast.ForStmt) anyerror!void {
        // `for item in <iterable>` (no numeric range end) lowers through the
        // iterable protocol (`iter_len`/`iter_at`), mirroring SA-text `genFor`.
        const end_expr = f.end orelse {
            const iterable_ty = self.tc.expr_types.get(f.start) orelse return Error.MissingType;
            return try self.genForOverProtocol(f, iterable_ty);
        };
        const old_locals = self.locals.items.len;
        defer self.popLocalsTo(old_locals);
        const loop_control = lowering_rules.planLoopControl(f.body);

        const counter_slot = try self.intern(try self.newTmp());
        try self.emitStackAlloc(counter_slot, 8);
        const start_reg = try self.genExpr(f.start);
        const end_reg = try self.genExpr(end_expr);
        try self.emitStore(counter_slot, 0, start_reg, .i64);
        if (!self.isLocalReg(start_reg)) try self.emitRelease(start_reg);

        const head_label = try self.newLabel("L_FOR_HEAD");
        const body_label = try self.newLabel("L_FOR_BODY");
        const cont_label = try self.newLabel("L_FOR_CONTINUE");
        const cond_false_label = try self.newLabel("L_FOR_COND_FALSE");
        const break_cleanup_label = try self.newLabel("L_FOR_BREAK_CLEANUP");
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
        br.operands[3] = .{ .label = try self.intern(cond_false_label) };
        try self.appendInst(br);

        const body_locals_len = self.locals.items.len;
        var pre_released = try self.released_regs.clone();
        defer pre_released.deinit();
        var pre_refcell_values = try self.cloneRefCellBorrowValues();
        defer self.deinitRefCellBorrowValueSnapshot(&pre_refcell_values);
        var pre_refcell_temps = try self.cloneBorrowAddressTemps();
        defer self.deinitBorrowAddressTempSnapshot(&pre_refcell_temps);

        try self.emitLabel(body_label);
        try self.emitBranchRelease(cond);
        const loop_value = try self.intern(try self.newTmp());
        try self.emitOp(loop_value, .add, .{ .reg = index_reg }, .{ .imm_i64 = 0 });
        try self.pushLocal(f.var_name, loop_value, false);
        try self.loop_continue_labels.append(cont_label);
        try self.loop_break_labels.append(if (loop_control.has_break) break_cleanup_label else exit_label);
        try self.genBlock(f.body);
        _ = self.loop_continue_labels.pop();
        _ = self.loop_break_labels.pop();
        if (!self.lastIsTerminator()) {
            try self.releaseLocalsFrom(body_locals_len, null);
            try self.emitJmp(cont_label);
        }

        self.popLocalsTo(body_locals_len);
        try self.restoreReleased(&pre_released);
        switch (lowering_rules.planRefCellLoopStateMerge()) {
            .restore_pre_loop => try self.restoreRefCellBranchState(&pre_refcell_values, &pre_refcell_temps),
        }

        try self.emitLabel(cont_label);
        const next = try self.intern(try self.newTmp());
        try self.emitOp(next, .add, .{ .reg = index_reg }, .{ .imm_i64 = 1 });
        try self.emitStore(counter_slot, 0, next, .i64);
        try self.emitRelease(next);
        try self.emitBranchRelease(index_reg);
        try self.emitJmp(head_label);

        if (loop_control.has_break) {
            try self.emitLabel(break_cleanup_label);
            try self.emitBranchRelease(index_reg);
            try self.emitJmp(exit_label);
        }

        try self.emitLabel(cond_false_label);
        try self.emitBranchRelease(cond);
        try self.emitBranchRelease(index_reg);
        try self.emitJmp(exit_label);

        try self.emitLabel(exit_label);
        if (!self.isLocalReg(end_reg)) try self.emitRelease(end_reg);
    }

    /// `for item in <iterable>` over a user type implementing the iterable
    /// protocol (`iter_len(&self) -> i64`, `iter_at(&self, i64) -> Item`),
    /// mirroring SA-text `genForOverProtocol`. The receiver is borrowed for
    /// each protocol call; the loop is a counted index from 0 to iter_len.
    /// Item binding and body cleanup follow the same branch-scoping discipline
    /// as the numeric `genFor`.
    fn genForOverProtocol(self: *Codegen, f: ast.ForStmt, iterable_ty: *const ast.Type) anyerror!void {
        const type_name = typeBaseName(iterable_ty) orelse return Error.UnsupportedSabDirectFeature;
        const mutable_ty = @constCast(iterable_ty);
        _ = self.tc.methodForType(mutable_ty, "iter_len") orelse return Error.UnsupportedSabDirectFeature;
        const at_method = self.tc.methodForType(mutable_ty, "iter_at") orelse return Error.UnsupportedSabDirectFeature;
        const item_ty = at_method.ret_ty;
        const len_sym = try self.loweredFuncSymbol(try self.mangleMethodName(type_name, "iter_len"));
        const at_sym = try self.loweredFuncSymbol(try self.mangleMethodName(type_name, "iter_at"));

        const old_locals = self.locals.items.len;
        defer self.popLocalsTo(old_locals);
        const loop_control = lowering_rules.planLoopControl(f.body);

        // Receiver value, borrowed for each protocol call.
        const recv_reg = try self.genExpr(f.start);

        // len = receiver.iter_len()
        const len_reg = try self.intern(try self.newTmp());
        try self.emitCallBody(len_reg, try std.fmt.allocPrint(self.allocator, "@{s}(&{s})", .{ len_sym, self.symbols.items[recv_reg] }));

        const counter_slot = try self.intern(try self.newTmp());
        try self.emitStackAlloc(counter_slot, 8);
        const zero = try self.intern(try self.newTmp());
        try self.emitAssignImm(zero, 0);
        try self.emitStore(counter_slot, 0, zero, .i64);
        try self.emitRelease(zero);

        const head_label = try self.newLabel("L_FORP_HEAD");
        const body_label = try self.newLabel("L_FORP_BODY");
        const cont_label = try self.newLabel("L_FORP_CONTINUE");
        const cond_false_label = try self.newLabel("L_FORP_COND_FALSE");
        const break_cleanup_label = try self.newLabel("L_FORP_BREAK_CLEANUP");
        const exit_label = try self.newLabel("L_FORP_EXIT");

        try self.emitJmp(head_label);
        try self.emitLabel(head_label);
        const index_reg = try self.intern(try self.newTmp());
        try self.emitLoad(index_reg, counter_slot, 0, .i64);
        const cond = try self.intern(try self.newTmp());
        try self.emitOp(cond, .slt, .{ .reg = index_reg }, .{ .reg = len_reg });

        var br = self.makeInst(.br);
        br.operands[0] = .{ .reg = cond };
        br.operands[1] = .{ .label = try self.intern(body_label) };
        br.operands[2] = .{ .label = try self.intern(body_label) };
        br.operands[3] = .{ .label = try self.intern(cond_false_label) };
        try self.appendInst(br);

        const body_locals_len = self.locals.items.len;
        var pre_released = try self.released_regs.clone();
        defer pre_released.deinit();
        var pre_refcell_values = try self.cloneRefCellBorrowValues();
        defer self.deinitRefCellBorrowValueSnapshot(&pre_refcell_values);
        var pre_refcell_temps = try self.cloneBorrowAddressTemps();
        defer self.deinitBorrowAddressTempSnapshot(&pre_refcell_temps);

        try self.emitLabel(body_label);
        try self.emitBranchRelease(cond);
        // item = receiver.iter_at(index)
        const item_reg = try self.intern(try self.newTmp());
        try self.emitCallBody(item_reg, try std.fmt.allocPrint(self.allocator, "@{s}(&{s}, {s})", .{ at_sym, self.symbols.items[recv_reg], self.symbols.items[index_reg] }));
        try self.pushTypedLocal(f.var_name, item_reg, false, item_ty);
        try self.loop_continue_labels.append(cont_label);
        try self.loop_break_labels.append(if (loop_control.has_break) break_cleanup_label else exit_label);
        try self.genBlock(f.body);
        _ = self.loop_continue_labels.pop();
        _ = self.loop_break_labels.pop();
        if (!self.lastIsTerminator()) {
            try self.releaseLocalsFrom(body_locals_len, null);
            try self.emitJmp(cont_label);
        }

        self.popLocalsTo(body_locals_len);
        try self.restoreReleased(&pre_released);
        switch (lowering_rules.planRefCellLoopStateMerge()) {
            .restore_pre_loop => try self.restoreRefCellBranchState(&pre_refcell_values, &pre_refcell_temps),
        }

        try self.emitLabel(cont_label);
        const next = try self.intern(try self.newTmp());
        try self.emitOp(next, .add, .{ .reg = index_reg }, .{ .imm_i64 = 1 });
        try self.emitStore(counter_slot, 0, next, .i64);
        try self.emitRelease(next);
        try self.emitBranchRelease(index_reg);
        try self.emitJmp(head_label);

        if (loop_control.has_break) {
            try self.emitLabel(break_cleanup_label);
            try self.emitBranchRelease(index_reg);
            try self.emitJmp(exit_label);
        }

        try self.emitLabel(cond_false_label);
        try self.emitBranchRelease(cond);
        try self.emitBranchRelease(index_reg);
        try self.emitJmp(exit_label);

        try self.emitLabel(exit_label);
        if (!self.isLocalReg(recv_reg)) try self.emitRelease(recv_reg);
    }

    fn genStdSurfaceCall(self: *Codegen, expr: *const ast.Node, call: ast.CallExpr) anyerror!?u32 {
        if (call.associated_target) |target_name| {
            if (self.findStdSurfaceRule(.associated, target_name, call.func_name)) |rule| {
                const value_reg = if (stdSurfaceRuleHasArg(rule, .value)) blk: {
                    if (call.args.len != 1) return Error.UnsupportedSabDirectFeature;
                    break :blk try self.genAssociatedValueArg(target_name, call.func_name, @constCast(call.args[0]));
                } else blk: {
                    if (call.args.len != 0) return Error.UnsupportedSabDirectFeature;
                    break :blk null;
                };
                const dst = try self.intern(try self.newTmp());
                try self.recordReg(dst);
                const expr_ty = self.tc.expr_types.get(expr) orelse return Error.MissingType;
                try self.emitStdSurfaceRule(rule, .{
                    .out = dst,
                    .value = value_reg,
                    .elem_size = self.elementSlotSize(expr_ty),
                });
                if (value_reg) |reg| {
                    if (rule.consume_value) {
                        try self.markConsumed(reg);
                    } else if (!self.isLocalReg(reg)) {
                        try self.emitRelease(reg);
                    }
                }
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
        try self.releaseNonLocalTemps(release_regs.items);
        if (value_reg) |reg| {
            if (!self.isLocalReg(reg)) {
                const value_ty = self.tc.expr_types.get(call.args[1]) orelse return Error.MissingType;
                if ((try primType(value_ty)) == .ptr) {
                    try self.emitMove(reg);
                } else {
                    try self.emitRelease(reg);
                }
            }
        }

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

        if (try self.genVecDirectIndex(idx, target_ty)) |dst| return dst;

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

    fn genVecDirectIndex(self: *Codegen, idx: ast.IndexExpr, target_ty: *const ast.Type) anyerror!?u32 {
        // Temporarily route Vec indexing through the standard surface path.
        // The direct path below still creates pointer/composite temporaries in
        // loop bodies that SAB merges as live on backedges; see issue014.
        if (self.symbols.items.len != std.math.maxInt(usize)) return null;

        const elem_ty = lowering_rules.vecElementType(target_ty) orelse return null;
        const load_ty: sig.PrimType = if (elem_ty.* == .fn_ptr)
            .ptr
        else switch (primType(elem_ty) catch return null) {
            .i1, .i8, .i16, .i32, .i64, .u8, .u16, .u32, .u64, .f32, .f64, .ptr => |ty| ty,
            else => return null,
        };
        if (lowering_rules.vecElementSlotSize(elem_ty) != 8) return null;

        const target_source = try self.genVecOwnerReceiver(idx.target);
        const target_reg = target_source.reg;
        const index_reg = try self.genExpr(idx.index);
        const len_reg = try self.intern(try self.newTmp());
        const in_bounds = try self.intern(try self.newTmp());
        try self.emitLoad(len_reg, target_reg, lowering_rules.VecAbi.len_offset, .u64);
        try self.emitOp(in_bounds, .ult, .{ .reg = index_reg }, .{ .reg = len_reg });
        try self.emitRelease(len_reg);

        const hit_label = try self.newLabel("L_VEC_DIRECT_INDEX_HIT");
        const miss_label = try self.newLabel("L_VEC_DIRECT_INDEX_MISS");
        try self.emitBranch(in_bounds, hit_label, miss_label);

        try self.emitLabel(miss_label);
        try self.emitBranchRelease(in_bounds);
        if (!self.isLocalReg(index_reg)) try self.emitBranchRelease(index_reg);
        try self.releaseAddressSource(target_source);
        try self.emitPanicCode(1);

        try self.emitLabel(hit_label);
        try self.emitBranchRelease(in_bounds);
        const data_ptr = try self.intern(try self.newTmp());
        const offset = try self.intern(try self.newTmp());
        const elem_ptr = try self.intern(try self.newTmp());
        const dst = try self.intern(try self.newTmp());
        try self.recordReg(dst);
        try self.emitLoad(data_ptr, target_reg, lowering_rules.VecAbi.ptr_offset, .ptr);
        try self.emitOp(offset, .mul, .{ .reg = index_reg }, .{ .imm_i64 = @intCast(lowering_rules.vecElementSlotSize(elem_ty)) });
        try self.emitPtrAdd(elem_ptr, data_ptr, .{ .reg = offset });
        try self.emitRelease(data_ptr);
        try self.emitLoad(dst, elem_ptr, 0, load_ty);
        try self.emitRelease(elem_ptr);
        try self.emitRelease(offset);
        if (!self.isLocalReg(index_reg)) try self.emitRelease(index_reg);
        try self.releaseAddressSource(target_source);
        return dst;
    }

    fn genFnPtrCall(self: *Codegen, expr: *const ast.Node, call: ast.CallExpr) anyerror!u32 {
        const fn_reg = self.localReg(call.func_name) orelse try self.intern(call.func_name);
        const call_reg = try self.intern(try self.newTmp());
        try self.recordReg(call_reg);

        var load = self.makeInst(.load);
        load.operands[0] = .{ .reg = call_reg };
        load.operands[1] = .{ .reg = fn_reg };
        load.operands[2] = .{ .imm_u64 = 0 };
        load.operands[3] = .{ .ty = @intFromEnum(sig.PrimType.ptr) };
        try self.appendInst(load);

        const result_ty = self.tc.expr_types.get(expr) orelse return Error.MissingType;
        const returns_void = isVoidType(result_ty);
        const dst = if (returns_void) null else try self.intern(try self.newTmp());
        if (dst) |reg| try self.recordReg(reg);
        var body = std.ArrayList(u8).init(self.allocator);
        var arg_regs = std.ArrayList(u32).init(self.allocator);
        defer arg_regs.deinit();
        try body.writer().print("{s}(", .{self.symbols.items[call_reg]});
        for (call.args, 0..) |arg, i| {
            const arg_reg = try self.genExpr(@constCast(arg));
            const call_arg_reg = blk: {
                if (arg.* == .identifier) {
                    const arg_ty = self.tc.expr_types.get(arg) orelse return Error.MissingType;
                    if (self.typeIsCopyValue(arg_ty) or lowering_rules.isBorrowLikeType(arg_ty)) {
                        const tmp = try self.copyFnPtrCallArg(arg_reg, arg_ty);
                        break :blk tmp;
                    }
                }
                break :blk arg_reg;
            };
            try arg_regs.append(call_arg_reg);
            if (i > 0) try body.appendSlice(", ");
            try body.writer().print("{s}", .{self.symbols.items[call_arg_reg]});
        }
        try body.append(')');

        var item = self.makeInst(.call_indirect);
        if (dst) |reg| {
            item.operands[0] = .{ .reg = reg };
            item.operands[1] = .{ .text = try body.toOwnedSlice() };
            try self.recordCallBodyRegs(item.operands[1].text);
        } else {
            item.operands[0] = .{ .text = try body.toOwnedSlice() };
            try self.recordCallBodyRegs(item.operands[0].text);
        }
        try self.appendInst(item);
        try self.releaseNonLocalTemps(arg_regs.items);
        try self.emitMove(call_reg);
        if (dst) |reg| return reg;

        const sentinel = try self.intern(try self.newTmp());
        try self.emitAssignImm(sentinel, 0);
        return sentinel;
    }

    fn copyFnPtrCallArg(self: *Codegen, source: u32, ty: *const ast.Type) anyerror!u32 {
        const dst = try self.intern(try self.newTmp());
        const prim = try storagePrimType(ty);
        const slot = try self.intern(try self.newTmp());
        try self.emitStackAlloc(slot, sig.primTypeBytes(prim));
        try self.emitStore(slot, 0, source, prim);
        try self.emitLoad(dst, slot, 0, prim);
        return dst;
    }

    fn genStructLiteral(self: *Codegen, lit: ast.StructLiteral) anyerror!u32 {
        const decl = self.structDeclForType(lit.ty) orelse return Error.UnsupportedSabDirectFeature;
        if (decl.is_opaque or decl.is_union) return Error.UnsupportedSabDirectFeature;

        const dst = try self.intern(try self.newTmp());
        try self.emitAlloc(dst, structSize(decl));

        const update_expr = lit.update_expr;
        var update_reg: ?u32 = null;
        if (update_expr) |expr| {
            update_reg = try self.genExpr(expr);
        }
        defer {
            if (update_reg) |reg| {
                self.releaseExprResultIfNeeded(update_expr.?, reg) catch {};
            }
        }

        var pending_moved_fields = std.AutoHashMap(u32, void).init(self.allocator);
        defer pending_moved_fields.deinit();

        const plans = try self.structLiteralFieldPlans(decl, &lit);
        defer self.allocator.free(plans);
        for (plans, 0..) |plan, field_index| {
            const layout = plan.layout;
            const prim = storagePrimType(layout.ty) catch return Error.UnsupportedSabDirectFeature;
            var transfer = lowering_rules.planStructLiteralFieldTransfer(plan, self.typeIsCopyStruct(plan.field_ty));
            var copy_elided_move = false;
            if (transfer == .deep_copy and plan.source == .explicit) {
                if (plan.value) |field_value| {
                    if (field_value.* == .identifier and !self.identifierMustStayLiveForLaterUse(field_value.identifier)) {
                        transfer = .move;
                        copy_elided_move = true;
                    }
                }
            }
            switch (plan.source) {
                .explicit => {
                    const value = plan.value orelse return Error.UnsupportedSabDirectFeature;
                    const later_mark = if (nodeMayContainCall(value))
                        try self.pushStructLiteralLaterFieldExprsFromPlans(plans, field_index)
                    else
                        self.current_expr_later_nodes.items.len;
                    defer self.popExprLaterNodesTo(later_mark);
                    switch (transfer) {
                        .deep_copy => {
                            const source_reg = try self.genExpr(value);
                            const copied = try self.genCopyValue(source_reg, plan.field_ty);
                            try self.emitStore(dst, layout.offset, copied, prim);
                            try self.emitRelease(copied);
                        },
                        .direct, .move => {
                            const value_reg = if (transfer == .move and value.* == .move_expr)
                                try self.genExpr(value.move_expr.expr)
                            else
                                try self.genExpr(value);
                            const explicit_move = value.* == .move_expr;
                            const moved_value = if (explicit_move) value.move_expr.expr else value;
                            const moves_identifier = moved_id: {
                                if (moved_value.* != .identifier) break :moved_id false;
                                if (lowering_rules.storedValueMovesIdentifier(moved_value, plan.field_ty, self.typeIsCopyValue(plan.field_ty)) != null) break :moved_id true;
                                break :moved_id explicit_move or copy_elided_move;
                            };
                            if (transfer == .move and !explicit_move and !copy_elided_move and !moves_identifier and self.typeIsShallowCopyCallArgValue(plan.field_ty, 0)) {
                                const copied = try self.genShallowCopyCallArgValue(value_reg, plan.field_ty);
                                try self.emitStore(dst, layout.offset, copied, prim);
                                try self.emitConsumedMarker(copied);
                                try self.releaseMovedShallowCopySource(value, value_reg, plan.field_ty);
                            } else {
                                try self.emitStore(dst, layout.offset, value_reg, prim);
                            }
                            if (transfer == .move) {
                                if (moved_value.* == .identifier) {
                                    if (moves_identifier) {
                                        if (self.localReg(moved_value.identifier)) |reg| try pending_moved_fields.put(reg, {});
                                    }
                                } else if (lowering_rules.exprResultNeedsRelease(moved_value)) {
                                    try self.markConsumed(value_reg);
                                }
                            } else {
                                try self.releaseStoredExprResultIfNeeded(value, value_reg, plan.field_ty);
                            }
                        },
                    }
                },
                .update => {
                    const src = update_reg orelse return Error.UnsupportedSabDirectFeature;
                    const loaded = try self.intern(try self.newTmp());
                    try self.emitLoad(loaded, src, layout.offset, prim);
                    switch (transfer) {
                        .direct => {
                            try self.emitStore(dst, layout.offset, loaded, prim);
                            if (plan.release_loaded and !self.isLocalReg(loaded)) try self.emitRelease(loaded);
                        },
                        .deep_copy => {
                            const copied = try self.genCopyValue(loaded, plan.field_ty);
                            try self.emitStore(dst, layout.offset, copied, prim);
                            try self.emitRelease(copied);
                            if (plan.release_loaded and !self.isLocalReg(loaded)) try self.emitRelease(loaded);
                        },
                        .move => {
                            try self.emitStore(dst, layout.offset, loaded, prim);
                        },
                    }
                },
            }
        }

        var iter = pending_moved_fields.keyIterator();
        while (iter.next()) |reg| try self.markConsumed(reg.*);

        return dst;
    }

    fn releaseMovedShallowCopySource(self: *Codegen, value: *const ast.Node, value_reg: u32, value_ty: *const ast.Type) !void {
        if (value.* == .identifier) {
            _ = lowering_rules.storedValueMovesIdentifier(value, value_ty, self.typeIsCopyValue(value_ty)) orelse return;
            const local_reg = self.localReg(value.identifier) orelse return;
            try self.emitRelease(local_reg);
            return;
        }
        if (lowering_rules.exprResultNeedsRelease(value)) try self.emitRelease(value_reg);
    }

    /// Direct SAB lowering for an enum literal (`Enum::Variant { fields }` or a
    /// unit variant `Enum::Variant`). Layout is owned by the shared
    /// `lowering_rules` enum helpers: the discriminant tag occupies the first
    /// word (`i64` at offset 0) and payload fields follow at the shared
    /// per-variant offsets. Mirrors SA-text `genEnumLiteralInto`.
    fn genEnumLiteral(self: *Codegen, lit: ast.EnumLiteral) anyerror!u32 {
        const decl = self.tc.enums.get(lit.enum_name) orelse return Error.UnsupportedSabDirectFeature;
        const tag = lowering_rules.enumVariantIndex(decl, lit.variant_name) orelse return Error.UnsupportedSabDirectFeature;
        const variant = lowering_rules.enumVariant(decl, lit.variant_name) orelse return Error.UnsupportedSabDirectFeature;

        const dst = try self.intern(try self.newTmp());
        try self.emitAlloc(dst, lowering_rules.enumAbiSize(decl));

        const tag_reg = try self.intern(try self.newTmp());
        try self.emitAssignImm(tag_reg, @intCast(tag));
        try self.emitStore(dst, lowering_rules.enum_tag_offset, tag_reg, .i64);
        try self.emitRelease(tag_reg);

        for (variant.fields) |field| {
            const value = lowering_rules.enumLiteralFieldValue(&lit, field.name) orelse return Error.UnsupportedSabDirectFeature;
            const layout = lowering_rules.enumFieldLayout(variant, field.name) orelse return Error.UnsupportedSabDirectFeature;
            const prim = storagePrimType(layout.ty) catch return Error.UnsupportedSabDirectFeature;
            const value_reg = try self.genExpr(value);
            try self.emitStore(dst, layout.offset, value_reg, prim);
            try self.releaseStoredExprResultIfNeeded(value, value_reg, field.ty);
        }

        return dst;
    }

    /// Direct SAB lowering for `match` over a user-defined enum value. The tag
    /// is loaded once per case into a fresh temp, compared against the shared
    /// discriminant index, and the matching case jumps to its body where the
    /// pattern bindings are loaded from the payload at the shared offsets.
    /// Non-matching falls through to the next check; an exhausted ladder
    /// panics. Enum tag/payload layout is owned by `lowering_rules`, so SA-text
    /// and SAB agree byte-for-byte. `Option`/`Result` matches are not handled
    /// here (they flow through their std-surface paths); this returns
    /// `UnsupportedSabDirectFeature` for non-enum match values.
    fn genMatch(self: *Codegen, expr: *ast.Node, mat: *const ast.MatchExpr) anyerror!u32 {
        return try self.genMatchWithExpected(expr, mat, null);
    }

    fn genMatchWithExpected(self: *Codegen, expr: *ast.Node, mat: *const ast.MatchExpr, expected_ty: ?*const ast.Type) anyerror!u32 {
        if (mat.cases.len == 0) return Error.UnsupportedSabDirectFeature;
        const val_ty = if (mat.val.* == .identifier)
            self.localType(mat.val.identifier) orelse self.tc.expr_types.get(mat.val) orelse return Error.MissingType
        else
            self.tc.expr_types.get(mat.val) orelse return Error.MissingType;
        const decl = if (val_ty.* == .user_defined) self.tc.enums.get(val_ty.user_defined.name) else null;
        if (decl == null and lowering_rules.optionInnerType(val_ty) == null and lowering_rules.resultOkType(val_ty) == null)
            return Error.UnsupportedSabDirectFeature;

        const expr_ty = expected_ty orelse self.tc.expr_types.get(expr) orelse return Error.MissingType;
        const value_match = !isVoidType(expr_ty);

        const val_reg = try self.genExpr(mat.val);
        const val_is_local = self.isLocalReg(val_reg);

        const result_slot = if (value_match) blk: {
            const slot = try self.intern(try self.newTmp());
            try self.emitAlloc(slot, typeSize(expr_ty));
            try self.prepareResultSlotRefCellCompanion(slot, expr_ty);
            break :blk slot;
        } else null;

        const merge_label = try self.newLabel("L_MATCH_MERGE");
        const panic_label = try self.newLabel("L_MATCH_NO_MATCH");

        // One check label per case plus the trailing no-match panic block.
        var check_labels = std.ArrayList([]const u8).init(self.allocator);
        defer check_labels.deinit();
        for (mat.cases) |_| {
            try check_labels.append(try self.newLabel("L_MATCH_CHECK"));
        }
        var case_cond_regs = std.ArrayList(u32).init(self.allocator);
        defer case_cond_regs.deinit();
        var case_guard_regs = std.ArrayList([]u32).init(self.allocator);
        defer {
            for (case_guard_regs.items) |regs| self.allocator.free(regs);
            case_guard_regs.deinit();
        }
        var case_binding_regs = std.ArrayList([]u32).init(self.allocator);
        defer {
            for (case_binding_regs.items) |regs| self.allocator.free(regs);
            case_binding_regs.deinit();
        }
        for (mat.cases) |case| {
            const cond = try self.intern(try self.newTmp());
            try self.emitAssignImm(cond, 0);
            try case_cond_regs.append(cond);
            const guard_count = if (case.guard) |guard| lowering_rules.scalarMatchGuardTempCount(guard) orelse return Error.UnsupportedSabDirectFeature else 0;
            const guard_regs = try self.allocator.alloc(u32, guard_count);
            for (guard_regs) |*guard_reg| {
                guard_reg.* = try self.intern(try self.newTmp());
                try self.emitAssignImm(guard_reg.*, 0);
            }
            try case_guard_regs.append(guard_regs);

            const regs = try self.allocator.alloc(u32, if (case.guard != null) case.pattern.bindings.len else 0);
            for (regs) |*reg| {
                reg.* = try self.intern(try self.newTmp());
                try self.emitAssignImm(reg.*, 0);
            }
            try case_binding_regs.append(regs);
        }

        const branch_locals_len = self.locals.items.len;
        var pre_branch_state = try self.cloneBranchEmitterState();
        defer self.deinitBranchEmitterStateSnapshot(&pre_branch_state);
        var live_branch_states = std.ArrayList(BranchEmitterStateSnapshot).init(self.allocator);
        defer {
            for (live_branch_states.items) |*snapshot| self.deinitBranchEmitterStateSnapshot(snapshot);
            live_branch_states.deinit();
        }

        var any_fallthrough = false;

        try self.emitJmp(check_labels.items[0]);

        for (mat.cases, 0..) |case, i| {
            try self.emitLabel(check_labels.items[i]);
            if (i > 0) try self.emitBranchRelease(case_cond_regs.items[i - 1]);
            const plan = lowering_rules.planLetPattern(case.pattern, decl != null) orelse return Error.UnsupportedSabDirectFeature;
            const variant = if (decl) |enum_decl|
                lowering_rules.enumVariant(enum_decl, case.pattern.variant_name) orelse return Error.UnsupportedSabDirectFeature
            else
                null;
            if (variant) |enum_variant| {
                if (case.pattern.bindings.len != enum_variant.fields.len) return Error.UnsupportedSabDirectFeature;
            } else if (case.pattern.bindings.len > 1) return Error.UnsupportedSabDirectFeature;
            const cond = case_cond_regs.items[i];
            try self.emitBranchRelease(cond);
            try self.emitLetPatternCheck(case.pattern, val_reg, decl, plan, cond);

            const body_label = try self.newLabel("L_MATCH_CASE");
            const next_label = if (i + 1 < mat.cases.len) check_labels.items[i + 1] else panic_label;
            try self.emitBranch(cond, if (plan.success_on_true) body_label else next_label, if (plan.success_on_true) next_label else body_label);

            try self.emitLabel(body_label);

            // Load pattern bindings from the payload at shared offsets.
            if (case.guard != null) {
                if (variant) |enum_variant| {
                    for (case.pattern.bindings, enum_variant.fields, 0..) |binding, field, binding_idx| {
                        const layout = lowering_rules.enumFieldLayout(enum_variant, field.name) orelse return Error.UnsupportedSabDirectFeature;
                        const prim = storagePrimType(layout.ty) catch return Error.UnsupportedSabDirectFeature;
                        if (prim == .ptr) return Error.UnsupportedSabDirectFeature;
                        const binding_reg = case_binding_regs.items[i][binding_idx];
                        try self.emitLoad(binding_reg, val_reg, layout.offset, prim);
                        try self.recordReg(binding_reg);
                        try self.locals.append(.{ .name = binding, .reg = binding_reg, .is_param = false, .ty = field.ty, .is_stack_alloc = true });
                    }
                } else if (case.pattern.bindings.len == 1) {
                    const binding_reg = case_binding_regs.items[i][0];
                    const binding_ty = switch (plan.kind) {
                        .option_some => lowering_rules.optionInnerType(val_ty),
                        .result_ok => lowering_rules.resultOkType(val_ty),
                        .result_err => lowering_rules.resultErrType(val_ty),
                        else => null,
                    } orelse return Error.UnsupportedSabDirectFeature;
                    if (binding_ty.* != .infer and
                        (storagePrimType(binding_ty) catch return Error.UnsupportedSabDirectFeature) == .ptr)
                        return Error.UnsupportedSabDirectFeature;
                    switch (plan.kind) {
                        .option_some => try self.emitStdMacroFragment("sa_std/core/option.sa", "OPTION_GET", &.{ self.symbols.items[binding_reg], self.symbols.items[val_reg] }),
                        .result_ok => try self.emitStdMacroFragment("sa_std/core/result.sa", "RESULT_GET_OK", &.{ self.symbols.items[binding_reg], self.symbols.items[val_reg] }),
                        .result_err => try self.emitStdMacroFragment("sa_std/core/result.sa", "RESULT_GET_ERR", &.{ self.symbols.items[binding_reg], self.symbols.items[val_reg] }),
                        else => return Error.UnsupportedSabDirectFeature,
                    }
                    try self.recordReg(binding_reg);
                    try self.locals.append(.{ .name = case.pattern.bindings[0], .reg = binding_reg, .is_param = false, .ty = binding_ty, .is_stack_alloc = true });
                }
            } else {
                try self.bindLetPatternPayload(case.pattern, val_reg, val_ty, decl, plan);
            }

            if (case.guard) |guard| {
                var guard_cursor: usize = 0;
                const guard_reg = try self.genScalarMatchGuard(guard, case_guard_regs.items[i], &guard_cursor);
                const guard_body_label = try self.newLabel("L_MATCH_GUARD_BODY");
                const guard_fail_label = try self.newLabel("L_MATCH_GUARD_FAIL");
                try self.emitBranch(guard_reg, guard_body_label, guard_fail_label);

                try self.emitLabel(guard_fail_label);
                try self.emitJmp(next_label);
                try self.emitLabel(guard_body_label);
            }
            for (case_cond_regs.items[i..]) |remaining_cond| try self.emitBranchRelease(remaining_cond);

            const terminated = if (value_match)
                try self.genBlockTailValueStore(case.body, result_slot.?, expr_ty)
            else blk: {
                try self.genBlock(case.body);
                break :blk self.lastIsTerminator();
            };
            if (!terminated) {
                try self.releaseLocalsFrom(branch_locals_len, null);
                try self.emitJmp(merge_label);
                any_fallthrough = true;
                try self.appendCurrentBranchEmitterState(&live_branch_states);
            }

            self.popLocalsTo(branch_locals_len);
            try self.restoreReleased(&pre_branch_state.released);
            try self.restoreRefCellBranchState(&pre_branch_state.refcell_values, &pre_branch_state.borrow_temps);
        }

        // Exhausted the ladder without a match: release the scrutinee and panic.
        try self.emitLabel(panic_label);
        try self.emitBranchRelease(case_cond_regs.items[case_cond_regs.items.len - 1]);
        for (case_guard_regs.items) |regs| for (regs) |reg| try self.emitBranchRelease(reg);
        for (case_binding_regs.items) |regs| for (regs) |reg| try self.emitBranchRelease(reg);
        if (!val_is_local) try self.emitBranchRelease(val_reg);
        try self.emitPanicCode(1);
        try self.setMergeBranchEmitterState(live_branch_states.items, &pre_branch_state);

        if (any_fallthrough) {
            try self.emitLabel(merge_label);
            for (case_guard_regs.items) |regs| for (regs) |reg| try self.emitRelease(reg);
            for (case_binding_regs.items) |regs| for (regs) |reg| try self.emitRelease(reg);
            if (!val_is_local) try self.emitRelease(val_reg);
            if (result_slot) |slot| {
                const result = try self.intern(try self.newTmp());
                try self.emitLoad(result, slot, 0, try primType(expr_ty));
                try self.loadResultSlotTransferredValue(result, slot, expr_ty);
                try self.emitRelease(slot);
                return result;
            }
        } else if (!val_is_local) {
            // No fallthrough path exists (every case terminates); the scrutinee
            // is released on the panic path already, so nothing to do here.
        }

        const result = try self.intern(try self.newTmp());
        try self.emitAssignImm(result, 0);
        return result;
    }

    fn genScalarMatchGuard(self: *Codegen, guard: *ast.Node, scratch: []const u32, cursor: *usize) anyerror!u32 {
        if (!lowering_rules.supportsScalarMatchGuard(guard)) return Error.UnsupportedSabDirectFeature;
        if (guard.* == .call_expr) {
            if (cursor.* >= scratch.len) return Error.UnsupportedSabDirectFeature;
            const dst = scratch[cursor.*];
            cursor.* += 1;
            const call_plan = lowering_rules.planStaticCall(self.tc, guard, guard.call_expr) orelse return Error.UnsupportedSabDirectFeature;
            const lowered = try self.loweredFuncSymbol(lowering_rules.staticCallEmitSymbol(call_plan));
            var body = std.ArrayList(u8).init(self.allocator);
            try body.writer().print("@{s}(", .{lowered});
            for (guard.call_expr.args, 0..) |arg, arg_idx| {
                if (arg_idx > 0) try body.appendSlice(", ");
                if (arg.* == .identifier) {
                    const reg = self.localReg(arg.identifier) orelse return Error.UnsupportedSabDirectFeature;
                    try body.appendSlice(self.symbols.items[reg]);
                } else if (arg.* == .literal and arg.literal == .int_val) {
                    try body.writer().print("{}", .{arg.literal.int_val});
                } else {
                    const reg = try self.genScalarMatchGuardValue(arg, scratch, cursor);
                    try body.appendSlice(self.symbols.items[reg]);
                }
            }
            try body.append(')');
            try self.emitCallBody(dst, try body.toOwnedSlice());
            return dst;
        }
        const bin = guard.binary_expr;
        const lhs: inst.Operand = if (bin.op == .logical_and or bin.op == .logical_or)
            .{ .reg = try self.genScalarMatchGuard(bin.left, scratch, cursor) }
        else
            .{ .reg = self.localReg(bin.left.identifier) orelse return Error.UnsupportedSabDirectFeature };
        const rhs: inst.Operand = if (bin.op == .logical_and or bin.op == .logical_or)
            .{ .reg = try self.genScalarMatchGuard(bin.right, scratch, cursor) }
        else if (bin.right.* == .identifier)
            .{ .reg = self.localReg(bin.right.identifier) orelse return Error.UnsupportedSabDirectFeature }
        else
            .{ .imm_i64 = bin.right.literal.int_val };
        if (cursor.* >= scratch.len) return Error.UnsupportedSabDirectFeature;
        const dst = scratch[cursor.*];
        cursor.* += 1;
        var item = self.makeInst(.op);
        item.op_kind = try self.opKindForBinary(bin);
        item.operands[0] = .{ .reg = dst };
        item.operands[1] = lhs;
        item.operands[2] = rhs;
        try self.appendInst(item);
        return dst;
    }

    fn genScalarMatchGuardValue(self: *Codegen, value: *ast.Node, scratch: []const u32, cursor: *usize) anyerror!u32 {
        if (value.* == .index_expr) {
            const index = value.index_expr;
            if (cursor.* >= scratch.len) return Error.UnsupportedSabDirectFeature;
            const base: u32, const base_ty: *const ast.Type = if (index.target.* == .identifier) .{
                self.localReg(index.target.identifier) orelse return Error.UnsupportedSabDirectFeature,
                self.localType(index.target.identifier) orelse return Error.UnsupportedSabDirectFeature,
            } else if (index.target.* == .field_expr and index.target.field_expr.expr.* == .identifier) blk: {
                const field = index.target.field_expr;
                const owner_ty = self.localType(field.expr.identifier) orelse return Error.UnsupportedSabDirectFeature;
                break :blk .{
                    try self.genScalarMatchGuardValue(index.target, scratch, cursor),
                    self.fieldType(owner_ty, field.field_name) orelse return Error.UnsupportedSabDirectFeature,
                };
            } else return Error.UnsupportedSabDirectFeature;
            if (base_ty.* != .array) return Error.UnsupportedSabDirectFeature;
            if (index.index.* == .literal and index.index.literal == .int_val and index.index.literal.int_val >= 0) {
                const layout = arrayElementLayout(base_ty.array, @intCast(index.index.literal.int_val)) orelse return Error.UnsupportedSabDirectFeature;
                const dst = scratch[cursor.*];
                cursor.* += 1;
                try self.emitLoad(dst, base, layout.offset, layout.ty);
                return dst;
            }
            const index_reg = if (index.index.* == .identifier)
                self.localReg(index.index.identifier) orelse return Error.UnsupportedSabDirectFeature
            else
                try self.genScalarMatchGuardValue(index.index, scratch, cursor);
            if (cursor.* + 2 >= scratch.len) return Error.UnsupportedSabDirectFeature;
            const offset = scratch[cursor.*];
            const ptr = scratch[cursor.* + 1];
            const dst = scratch[cursor.* + 2];
            cursor.* += 3;
            try self.emitOp(offset, .mul, .{ .reg = index_reg }, .{ .imm_i64 = @intCast(arrayStride(base_ty.array.elem)) });
            try self.emitPtrAdd(ptr, base, .{ .reg = offset });
            try self.emitLoad(dst, ptr, 0, try storagePrimType(base_ty.array.elem));
            return dst;
        }
        if (value.* == .field_expr) {
            const field = value.field_expr;
            if (field.expr.* != .identifier or cursor.* >= scratch.len) return Error.UnsupportedSabDirectFeature;
            const base = self.localReg(field.expr.identifier) orelse return Error.UnsupportedSabDirectFeature;
            const base_ty = self.localType(field.expr.identifier) orelse return Error.UnsupportedSabDirectFeature;
            const layout = try self.fieldLayout(base_ty, field.field_name);
            const dst = scratch[cursor.*];
            cursor.* += 1;
            try self.emitLoad(dst, base, layout.offset, layout.ty);
            return dst;
        }
        if (value.* == .cast_expr) {
            const cast = value.cast_expr;
            if (cast.expr.* == .literal and cast.expr.literal == .int_val) {
                if (cursor.* >= scratch.len) return Error.UnsupportedSabDirectFeature;
                const dst = scratch[cursor.*];
                cursor.* += 1;
                try self.emitAssignImm(dst, cast.expr.literal.int_val);
                return dst;
            }
            const source = if (cast.expr.* == .identifier)
                self.localReg(cast.expr.identifier) orelse return Error.UnsupportedSabDirectFeature
            else
                try self.genScalarMatchGuardValue(cast.expr, scratch, cursor);
            if (cursor.* >= scratch.len) return Error.UnsupportedSabDirectFeature;
            const dst = scratch[cursor.*];
            cursor.* += 1;
            const dst_ty = try primType(cast.ty);
            if (dst_ty == .i64 or dst_ty == .u64) {
                try self.emitOp(dst, .add, .{ .reg = source }, .{ .imm_i64 = 0 });
            } else return Error.UnsupportedSabDirectFeature;
            return dst;
        }
        if (value.* != .binary_expr) return Error.UnsupportedSabDirectFeature;
        const bin = value.binary_expr;
        const lhs: inst.Operand = if (bin.left.* == .identifier)
            .{ .reg = self.localReg(bin.left.identifier) orelse return Error.UnsupportedSabDirectFeature }
        else if (bin.left.* == .literal and bin.left.literal == .int_val)
            .{ .imm_i64 = bin.left.literal.int_val }
        else
            .{ .reg = try self.genScalarMatchGuardValue(bin.left, scratch, cursor) };
        const rhs: inst.Operand = if (bin.right.* == .identifier)
            .{ .reg = self.localReg(bin.right.identifier) orelse return Error.UnsupportedSabDirectFeature }
        else if (bin.right.* == .literal and bin.right.literal == .int_val)
            .{ .imm_i64 = bin.right.literal.int_val }
        else
            .{ .reg = try self.genScalarMatchGuardValue(bin.right, scratch, cursor) };
        if (cursor.* >= scratch.len) return Error.UnsupportedSabDirectFeature;
        const dst = scratch[cursor.*];
        cursor.* += 1;
        var item = self.makeInst(.op);
        item.op_kind = try self.opKindForBinary(bin);
        item.operands[0] = .{ .reg = dst };
        item.operands[1] = lhs;
        item.operands[2] = rhs;
        try self.appendInst(item);
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
                try self.emitConsumedMarker(copied_field);
                try self.emitRelease(field_reg);
            } else {
                try self.emitStore(dst, layout.offset, field_reg, layout.ty);
                try self.emitConsumedMarker(field_reg);
            }
        }
        return dst;
    }

    fn genShallowCopyCallArgValue(self: *Codegen, source: u32, ty: *const ast.Type) anyerror!u32 {
        const decl = self.structDeclForType(ty) orelse return Error.UnsupportedSabDirectFeature;
        if (!self.typeIsShallowCopyCallArgValue(ty, 0) or decl.is_opaque or decl.is_union) return Error.UnsupportedSabDirectFeature;

        const dst = try self.intern(try self.newTmp());
        try self.emitAlloc(dst, structSize(decl));
        for (decl.fields) |field| {
            const layout = try self.fieldLayout(ty, field.name);
            const field_reg = try self.intern(try self.newTmp());
            try self.emitLoad(field_reg, source, layout.offset, layout.ty);
            if (self.structDeclForType(field.ty) != null) {
                const copied_field = try self.genShallowCopyCallArgValue(field_reg, field.ty);
                try self.emitStore(dst, layout.offset, copied_field, layout.ty);
                try self.emitConsumedMarker(copied_field);
                try self.emitRelease(field_reg);
            } else {
                try self.emitStore(dst, layout.offset, field_reg, layout.ty);
                try self.emitConsumedMarker(field_reg);
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
            try self.releaseStoredExprResultIfNeeded(elem, value, elem_tys[idx]);
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
            try self.releaseStoredExprResultIfNeeded(elem, value, arr_ty.array.elem);
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
        try self.releaseStoredExprResultIfNeeded(lit.value, value, arr_ty.array.elem);
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
            try self.markLoadedFieldViewIfNeeded(dst, expr_ty.tuple.elems[index]);
            if (!self.isLocalReg(base)) try self.emitRelease(base);
            return dst;
        }
        const layout = try self.fieldLayout(expr_ty, field.field_name);
        const field_ty = self.fieldType(expr_ty, field.field_name) orelse return Error.UnsupportedSabDirectFeature;

        const base = try self.genExpr(field.expr);
        const dst = try self.intern(try self.newTmp());
        try self.emitLoad(dst, base, layout.offset, layout.ty);
        try self.markLoadedFieldViewIfNeeded(dst, field_ty);
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
        try self.storeResultSlotTransferredValue(target, value, target_ty);
        return false;
    }

    fn genIfLetChain(
        self: *Codegen,
        chain: []const ast.IfLetCond,
        then_label: []const u8,
        else_label: []const u8,
        branch_locals_len: usize,
    ) anyerror!void {
        for (chain, 0..) |cond, idx| {
            const success_label = if (idx + 1 == chain.len) then_label else try self.newLabel("L_IF_LET_NEXT");
            const fail_label = try self.newLabel("L_IF_LET_FAIL");
            const value_reg = try self.genExpr(@constCast(cond.value));
            const value_ty = self.tc.expr_types.get(cond.value) orelse return Error.MissingType;
            const enum_decl = try self.enumDeclForPatternValue(cond.value, cond.pattern);
            const plan = lowering_rules.planLetPattern(cond.pattern, enum_decl != null) orelse return Error.UnsupportedSabDirectFeature;
            const branch_flag = try self.intern(try self.newTmp());
            try self.recordReg(branch_flag);
            try self.emitLetPatternCheck(cond.pattern, value_reg, enum_decl, plan, branch_flag);
            try self.emitBranch(
                branch_flag,
                if (plan.success_on_true) success_label else fail_label,
                if (plan.success_on_true) fail_label else success_label,
            );

            try self.emitLabel(fail_label);
            try self.emitBranchRelease(branch_flag);
            if (!self.isLocalReg(value_reg)) try self.emitBranchRelease(value_reg);
            try self.emitBranchReleaseLocalsFrom(branch_locals_len, null);
            try self.emitJmp(else_label);

            try self.emitLabel(success_label);
            try self.emitBranchRelease(branch_flag);
            try self.bindLetPatternPayload(cond.pattern, value_reg, value_ty, enum_decl, plan);
            if (!self.isLocalReg(value_reg)) try self.emitBranchRelease(value_reg);
        }
    }

    fn genIfLetValue(self: *Codegen, ife: ast.IfExpr, chain: []const ast.IfLetCond, else_block: []const *ast.Node, result_ty: *const ast.Type) anyerror!u32 {
        const result_slot = try self.intern(try self.newTmp());
        try self.emitAlloc(result_slot, typeSize(result_ty));
        try self.prepareResultSlotRefCellCompanion(result_slot, result_ty);
        const then_label = try self.newLabel("L_IF_LET_THEN");
        const else_label = try self.newLabel("L_IF_LET_ELSE");
        const merge_label = try self.newLabel("L_IF_LET_MERGE");

        const branch_locals_len = self.locals.items.len;
        var pre_released = try self.released_regs.clone();
        defer pre_released.deinit();
        var pre_refcell_values = try self.cloneRefCellBorrowValues();
        defer self.deinitRefCellBorrowValueSnapshot(&pre_refcell_values);
        var pre_refcell_temps = try self.cloneBorrowAddressTemps();
        defer self.deinitBorrowAddressTempSnapshot(&pre_refcell_temps);

        try self.genIfLetChain(chain, then_label, else_label, branch_locals_len);
        const then_terminated = try self.genBlockTailValueStore(ife.then_block, result_slot, result_ty);
        if (!then_terminated) {
            try self.releaseLocalsFrom(branch_locals_len, null);
            try self.emitJmp(merge_label);
        }
        var then_released = try self.released_regs.clone();
        defer then_released.deinit();
        var then_refcell_values = try self.cloneRefCellBorrowValues();
        defer self.deinitRefCellBorrowValueSnapshot(&then_refcell_values);
        var then_refcell_temps = try self.cloneBorrowAddressTemps();
        defer self.deinitBorrowAddressTempSnapshot(&then_refcell_temps);

        self.popLocalsTo(branch_locals_len);
        try self.restoreReleased(&pre_released);
        try self.restoreRefCellBranchState(&pre_refcell_values, &pre_refcell_temps);

        try self.emitLabel(else_label);
        const else_terminated = try self.genBlockTailValueStore(else_block, result_slot, result_ty);
        if (!else_terminated) {
            try self.releaseLocalsFrom(branch_locals_len, null);
            try self.emitJmp(merge_label);
        }
        var else_released = try self.released_regs.clone();
        defer else_released.deinit();
        var else_refcell_values = try self.cloneRefCellBorrowValues();
        defer self.deinitRefCellBorrowValueSnapshot(&else_refcell_values);
        var else_refcell_temps = try self.cloneBorrowAddressTemps();
        defer self.deinitBorrowAddressTempSnapshot(&else_refcell_temps);

        self.popLocalsTo(branch_locals_len);
        try self.setMergeReleased(then_terminated, &then_released, else_terminated, &else_released, &pre_released);
        try self.setMergeRefCellBranchState(
            then_terminated,
            &then_refcell_values,
            &then_refcell_temps,
            else_terminated,
            &else_refcell_values,
            &else_refcell_temps,
            &pre_refcell_values,
            &pre_refcell_temps,
        );

        if (!then_terminated or !else_terminated) {
            try self.emitLabel(merge_label);
            const result = try self.intern(try self.newTmp());
            try self.emitLoad(result, result_slot, 0, try primType(result_ty));
            try self.loadResultSlotTransferredValue(result, result_slot, result_ty);
            try self.emitRelease(result_slot);
            return result;
        }

        const result = try self.intern(try self.newTmp());
        try self.recordReg(result);
        return result;
    }

    fn genIfLetStatement(self: *Codegen, ife: ast.IfExpr, chain: []const ast.IfLetCond) anyerror!u32 {
        const then_label = try self.newLabel("L_IF_LET_THEN");
        const else_label = try self.newLabel("L_IF_LET_ELSE");
        const merge_label = try self.newLabel("L_IF_LET_MERGE");

        const branch_locals_len = self.locals.items.len;
        var pre_released = try self.released_regs.clone();
        defer pre_released.deinit();
        var pre_refcell_values = try self.cloneRefCellBorrowValues();
        defer self.deinitRefCellBorrowValueSnapshot(&pre_refcell_values);
        var pre_refcell_temps = try self.cloneBorrowAddressTemps();
        defer self.deinitBorrowAddressTempSnapshot(&pre_refcell_temps);

        try self.genIfLetChain(chain, then_label, else_label, branch_locals_len);
        try self.genBlock(ife.then_block);
        const then_terminated = self.lastIsTerminator();
        if (!then_terminated) {
            try self.releaseLocalsFrom(branch_locals_len, null);
            try self.emitJmp(merge_label);
        }
        var then_released = try self.released_regs.clone();
        defer then_released.deinit();
        var then_refcell_values = try self.cloneRefCellBorrowValues();
        defer self.deinitRefCellBorrowValueSnapshot(&then_refcell_values);
        var then_refcell_temps = try self.cloneBorrowAddressTemps();
        defer self.deinitBorrowAddressTempSnapshot(&then_refcell_temps);

        self.popLocalsTo(branch_locals_len);
        try self.restoreReleased(&pre_released);
        try self.restoreRefCellBranchState(&pre_refcell_values, &pre_refcell_temps);

        try self.emitLabel(else_label);
        if (ife.else_block) |else_block| try self.genBlock(else_block);
        const else_terminated = self.lastIsTerminator();
        if (!else_terminated) {
            try self.releaseLocalsFrom(branch_locals_len, null);
            try self.emitJmp(merge_label);
        }
        var else_released = try self.released_regs.clone();
        defer else_released.deinit();
        var else_refcell_values = try self.cloneRefCellBorrowValues();
        defer self.deinitRefCellBorrowValueSnapshot(&else_refcell_values);
        var else_refcell_temps = try self.cloneBorrowAddressTemps();
        defer self.deinitBorrowAddressTempSnapshot(&else_refcell_temps);

        self.popLocalsTo(branch_locals_len);
        try self.setMergeReleased(then_terminated, &then_released, else_terminated, &else_released, &pre_released);
        try self.setMergeRefCellBranchState(
            then_terminated,
            &then_refcell_values,
            &then_refcell_temps,
            else_terminated,
            &else_refcell_values,
            &else_refcell_temps,
            &pre_refcell_values,
            &pre_refcell_temps,
        );

        if (!then_terminated or !else_terminated) try self.emitLabel(merge_label);
        const result = try self.intern(try self.newTmp());
        try self.recordReg(result);
        return result;
    }

    fn genIfValue(self: *Codegen, ife: ast.IfExpr, else_block: []const *ast.Node, result_ty: *const ast.Type) anyerror!u32 {
        if (ife.let_chain) |chain| return try self.genIfLetValue(ife, chain, else_block, result_ty);
        const cond = blk: {
            const later_mark = try self.pushIfBranchLaterNodes(ife);
            defer self.popExprLaterNodesTo(later_mark);
            break :blk try self.genExpr(ife.cond);
        };
        const result_slot = try self.intern(try self.newTmp());
        try self.emitAlloc(result_slot, typeSize(result_ty));
        try self.prepareResultSlotRefCellCompanion(result_slot, result_ty);
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
        var pre_refcell_values = try self.cloneRefCellBorrowValues();
        defer self.deinitRefCellBorrowValueSnapshot(&pre_refcell_values);
        var pre_refcell_temps = try self.cloneBorrowAddressTemps();
        defer self.deinitBorrowAddressTempSnapshot(&pre_refcell_temps);

        try self.emitLabel(then_label);
        const then_terminated = try self.genBlockTailValueStore(ife.then_block, result_slot, result_ty);
        if (!then_terminated) {
            try self.releaseLocalsFrom(branch_locals_len, null);
            try self.emitJmp(merge_label);
        }
        var then_released = try self.released_regs.clone();
        defer then_released.deinit();
        var then_refcell_values = try self.cloneRefCellBorrowValues();
        defer self.deinitRefCellBorrowValueSnapshot(&then_refcell_values);
        var then_refcell_temps = try self.cloneBorrowAddressTemps();
        defer self.deinitBorrowAddressTempSnapshot(&then_refcell_temps);

        self.popLocalsTo(branch_locals_len);
        try self.restoreReleased(&pre_released);
        try self.restoreRefCellBranchState(&pre_refcell_values, &pre_refcell_temps);

        try self.emitLabel(else_label);
        const else_terminated = try self.genBlockTailValueStore(else_block, result_slot, result_ty);
        if (!else_terminated) {
            try self.releaseLocalsFrom(branch_locals_len, null);
            try self.emitJmp(merge_label);
        }
        var else_released = try self.released_regs.clone();
        defer else_released.deinit();
        var else_refcell_values = try self.cloneRefCellBorrowValues();
        defer self.deinitRefCellBorrowValueSnapshot(&else_refcell_values);
        var else_refcell_temps = try self.cloneBorrowAddressTemps();
        defer self.deinitBorrowAddressTempSnapshot(&else_refcell_temps);

        self.popLocalsTo(branch_locals_len);
        try self.setMergeReleased(then_terminated, &then_released, else_terminated, &else_released, &pre_released);
        try self.setMergeRefCellBranchState(
            then_terminated,
            &then_refcell_values,
            &then_refcell_temps,
            else_terminated,
            &else_refcell_values,
            &else_refcell_temps,
            &pre_refcell_values,
            &pre_refcell_temps,
        );

        if (!then_terminated or !else_terminated) {
            try self.emitLabel(merge_label);
            const result = try self.intern(try self.newTmp());
            try self.emitLoad(result, result_slot, 0, try primType(result_ty));
            try self.loadResultSlotTransferredValue(result, result_slot, result_ty);
            try self.emitRelease(result_slot);
            return result;
        }

        const result = try self.intern(try self.newTmp());
        try self.recordReg(result);
        return result;
    }

    fn genIfStatement(self: *Codegen, ife: ast.IfExpr) anyerror!u32 {
        if (ife.let_chain) |chain| return try self.genIfLetStatement(ife, chain);
        const cond = blk: {
            const later_mark = try self.pushIfBranchLaterNodes(ife);
            defer self.popExprLaterNodesTo(later_mark);
            break :blk try self.genExpr(ife.cond);
        };
        const then_label = try self.newLabel("L_THEN");
        const else_label = try self.newLabel("L_ELSE");
        const merge_label = try self.newLabel("L_MERGE");
        const then_exit_label = try self.newLabel("L_THEN_EXIT");
        const else_exit_label = try self.newLabel("L_ELSE_EXIT");
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
        var pre_refcell_values = try self.cloneRefCellBorrowValues();
        defer self.deinitRefCellBorrowValueSnapshot(&pre_refcell_values);
        var pre_refcell_temps = try self.cloneBorrowAddressTemps();
        defer self.deinitBorrowAddressTempSnapshot(&pre_refcell_temps);

        try self.emitLabel(then_label);
        try self.genBlock(ife.then_block);
        const then_terminated = self.lastIsTerminator();
        if (!then_terminated) {
            try self.releaseLocalsFrom(branch_locals_len, null);
            try self.emitJmp(then_exit_label);
        }
        var then_released = try self.released_regs.clone();
        defer then_released.deinit();
        var then_refcell_values = try self.cloneRefCellBorrowValues();
        defer self.deinitRefCellBorrowValueSnapshot(&then_refcell_values);
        var then_refcell_temps = try self.cloneBorrowAddressTemps();
        defer self.deinitBorrowAddressTempSnapshot(&then_refcell_temps);

        self.popLocalsTo(branch_locals_len);
        try self.restoreReleased(&pre_released);
        try self.restoreRefCellBranchState(&pre_refcell_values, &pre_refcell_temps);

        try self.emitLabel(else_label);
        if (ife.else_block) |else_block| try self.genBlock(else_block);
        const else_terminated = self.lastIsTerminator();
        if (!else_terminated) {
            try self.releaseLocalsFrom(branch_locals_len, null);
            try self.emitJmp(else_exit_label);
        }
        var else_released = try self.released_regs.clone();
        defer else_released.deinit();
        var else_refcell_values = try self.cloneRefCellBorrowValues();
        defer self.deinitRefCellBorrowValueSnapshot(&else_refcell_values);
        var else_refcell_temps = try self.cloneBorrowAddressTemps();
        defer self.deinitBorrowAddressTempSnapshot(&else_refcell_temps);

        self.popLocalsTo(branch_locals_len);
        if (!then_terminated) {
            try self.restoreReleased(&then_released);
            try self.restoreRefCellBranchState(&then_refcell_values, &then_refcell_temps);
            try self.emitLabel(then_exit_label);
            if (!else_terminated) try self.balanceBranchReleasedLocals(branch_locals_len, &then_released, &else_released);
            try self.emitJmp(merge_label);
        }
        if (!else_terminated) {
            try self.restoreReleased(&else_released);
            try self.restoreRefCellBranchState(&else_refcell_values, &else_refcell_temps);
            try self.emitLabel(else_exit_label);
            if (!then_terminated) try self.balanceBranchReleasedLocals(branch_locals_len, &else_released, &then_released);
            try self.emitJmp(merge_label);
        }
        // The merge is reached only by the non-terminated incoming paths; a
        // register is released at the merge iff it is released on every such
        // path (intersection). This keeps the merge release state in sync with
        // both branches so the function-end `releaseOpenLocals` neither
        // double-releases (release present on all paths) nor leaks (release
        // present on only one path).
        try self.setMergeReleased(then_terminated, &then_released, else_terminated, &else_released, &pre_released);
        try self.setMergeRefCellBranchState(
            then_terminated,
            &then_refcell_values,
            &then_refcell_temps,
            else_terminated,
            &else_refcell_values,
            &else_refcell_temps,
            &pre_refcell_values,
            &pre_refcell_temps,
        );

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

test "direct sab instruction reg scan records call body refs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tc = type_checker.TypeChecker.init(allocator);
    defer tc.deinit();
    var cg = Codegen.init(allocator, &tc);
    defer cg.deinit();

    const out = try cg.internStable("out");
    const leaked_dst = try cg.internStable("dst");
    const param = try cg.internStable("s");
    const tmp = try cg.internStable("tmp_42");
    try std.testing.expect(cg.symbol_ids.get("later_func") == null);
    try cg.recordReg(param);

    var item = inst.makeInstruction(.call, 1, 1, null, "");
    item.operands[0] = .{ .reg = out };
    item.operands[1] = .{ .text = "@later_func(s, dst, tmp_42)" };

    try cg.recordInstructionRegs(item);

    const callee = cg.symbol_ids.get("later_func") orelse return error.TestExpectedEqual;
    try std.testing.expect(cg.current_reg_seen.contains(out));
    try std.testing.expect(cg.current_reg_seen.contains(param));
    try std.testing.expect(!cg.current_reg_seen.contains(leaked_dst));
    try std.testing.expect(!cg.current_reg_seen.contains(tmp));
    try std.testing.expect(cg.current_reg_seen.contains(callee));
}

test "filtered decoded std deps include same-module direct-call closure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tc = type_checker.TypeChecker.init(allocator);
    defer tc.deinit();
    var cg = Codegen.init(allocator, &tc);
    defer cg.deinit();

    const function_sigs = try allocator.alloc(sig.FunctionSig, 5);
    function_sigs[0] = try sig.parseFunctionSig(allocator, "@top() -> void:", 0, 0);
    function_sigs[1] = try sig.parseFunctionSig(allocator, "@ext() -> void:", 1, 3);
    function_sigs[1].kind = .external;
    function_sigs[2] = try sig.parseFunctionSig(allocator, "@helper() -> void:", 2, 4);
    function_sigs[3] = try sig.parseFunctionSig(allocator, "@helper() -> void:", 3, 7);
    function_sigs[4] = try sig.parseFunctionSig(allocator, "@unused() -> void:", 4, 10);

    const instructions = try allocator.alloc(inst.Instruction, 12);
    instructions[0] = inst.makeInstruction(.func_decl, 1, 1, null, "");
    instructions[1] = inst.makeInstruction(.call, 2, 2, null, "");
    instructions[1].operands[0] = .{ .text = "@helper()" };
    instructions[2] = inst.makeInstruction(.return_, 3, 3, null, "");
    instructions[3] = inst.makeInstruction(.extern_decl, 4, 4, null, "");
    instructions[4] = inst.makeInstruction(.func_decl, 5, 5, null, "");
    instructions[5] = inst.makeInstruction(.call, 6, 6, null, "");
    instructions[5].operands[0] = .{ .text = "@ext()" };
    instructions[6] = inst.makeInstruction(.return_, 7, 7, null, "");
    instructions[7] = inst.makeInstruction(.func_decl, 8, 8, null, "");
    instructions[8] = inst.makeInstruction(.call, 9, 9, null, "");
    instructions[8].operands[0] = .{ .text = "@ext()" };
    instructions[9] = inst.makeInstruction(.return_, 10, 10, null, "");
    instructions[10] = inst.makeInstruction(.func_decl, 11, 11, null, "");
    instructions[11] = inst.makeInstruction(.return_, 12, 12, null, "");

    const module = sab.Module{
        .symbols = &.{},
        .function_sigs = function_sigs,
        .const_decls = &.{},
        .instructions = instructions,
        .owned_text = &.{},
    };

    try cg.appendDecodedModuleFiltered(module, &.{"top"});

    var saw_top = false;
    var saw_helper = false;
    var saw_unused = false;
    var helper_count: usize = 0;
    for (cg.function_sigs.items) |fsig| {
        if (std.mem.eql(u8, fsig.name, "top")) saw_top = true;
        if (std.mem.eql(u8, fsig.name, "helper")) {
            saw_helper = true;
            helper_count += 1;
        }
        if (std.mem.eql(u8, fsig.name, "unused")) saw_unused = true;
    }
    try std.testing.expect(saw_top);
    try std.testing.expect(saw_helper);
    try std.testing.expect(!saw_unused);
    try std.testing.expectEqual(@as(usize, 3), cg.function_sigs.items.len);
    try std.testing.expectEqualStrings("top", cg.function_sigs.items[0].name);
    try std.testing.expectEqualStrings("ext", cg.function_sigs.items[1].name);
    try std.testing.expectEqualStrings("helper", cg.function_sigs.items[2].name);
    try std.testing.expectEqual(sig.FunctionKind.external, cg.function_sigs.items[1].kind);
    try std.testing.expectEqual(@as(usize, 1), helper_count);
    try std.testing.expect(cg.included_imports.contains("top"));
    try std.testing.expect(cg.included_imports.contains("ext"));
    try std.testing.expect(cg.included_imports.contains("helper"));
    try std.testing.expect(!cg.included_imports.contains("unused"));
}

test "filtered decoded std deps deduplicate and hoist consts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tc = type_checker.TypeChecker.init(allocator);
    defer tc.deinit();
    var cg = Codegen.init(allocator, &tc);
    defer cg.deinit();

    const function_sigs = try allocator.alloc(sig.FunctionSig, 1);
    function_sigs[0] = try sig.parseFunctionSig(allocator, "@entry() -> void:", 0, 0);
    function_sigs[0].reg_ids = try allocator.dupe(u32, &.{0});

    const instructions = try allocator.alloc(inst.Instruction, 2);
    instructions[0] = inst.makeInstruction(.func_decl, 1, 1, null, "");
    instructions[1] = inst.makeInstruction(.return_, 2, 2, null, "");

    const sentinel_bytes = try allocator.dupe(u8, "hashset");
    const sentinel = const_decl.ConstDecl{
        .source_line = 50,
        .expanded_line = 50,
        .upstream_loc = null,
        .raw_text = try allocator.dupe(u8, "@const HASHSET_SENTINEL = utf8:\"hashset\""),
        .name = try allocator.dupe(u8, "HASHSET_SENTINEL"),
        .literal_text = try allocator.dupe(u8, "utf8:\"hashset\""),
        .value = .{ .utf8 = .{ .kind = .utf8, .bytes = sentinel_bytes } },
    };
    const const_decls = try allocator.alloc(const_decl.ConstDecl, 1);
    const_decls[0] = sentinel;
    const module = sab.Module{
        .symbols = &.{"HASHSET_SENTINEL"},
        .function_sigs = function_sigs,
        .const_decls = const_decls,
        .instructions = instructions,
        .owned_text = &.{},
    };

    try cg.appendDecodedModuleFiltered(module, &.{"entry"});
    try cg.appendDecodedModuleFiltered(module, &.{"entry"});

    try std.testing.expectEqual(@as(usize, 1), cg.const_decls.items.len);
    try std.testing.expectEqual(@as(u32, 0), cg.const_decls.items[0].source_line);
    try std.testing.expectEqual(@as(u32, 0), cg.const_decls.items[0].expanded_line);
    const sentinel_id = cg.symbol_ids.get("HASHSET_SENTINEL") orelse return error.TestUnexpectedResult;
    try std.testing.expect(cg.current_reg_seen.contains(sentinel_id));
    var function_has_sentinel = false;
    for (cg.function_sigs.items[0].reg_ids) |reg_id| {
        if (reg_id == sentinel_id) function_has_sentinel = true;
    }
    try std.testing.expect(function_has_sentinel);
}

test "filtered decoded std deps emit exported helper bodies in original order" {
    // Exported std helpers (e.g. `@export sa_map_put`) reached transitively
    // from a selected dep must keep their full body, not degrade to a
    // decl-only clone like external symbols, and must stay in the decoded
    // module's original declaration order relative to the normal helper that
    // calls them. This guards the extern/export ordering boundary for the
    // filtered std-dep closure.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tc = type_checker.TypeChecker.init(allocator);
    defer tc.deinit();
    var cg = Codegen.init(allocator, &tc);
    defer cg.deinit();

    const function_sigs = try allocator.alloc(sig.FunctionSig, 3);
    function_sigs[0] = try sig.parseFunctionSig(allocator, "@entry() -> void:", 0, 0);
    function_sigs[1] = try sig.parseFunctionSig(allocator, "@exported_helper() -> void:", 1, 3);
    function_sigs[1].kind = .exported;
    function_sigs[2] = try sig.parseFunctionSig(allocator, "@normal_helper() -> void:", 2, 6);

    const instructions = try allocator.alloc(inst.Instruction, 9);
    // entry() { call @normal_helper() }
    instructions[0] = inst.makeInstruction(.func_decl, 1, 1, null, "");
    instructions[1] = inst.makeInstruction(.call, 2, 2, null, "");
    instructions[1].operands[0] = .{ .text = "@normal_helper()" };
    instructions[2] = inst.makeInstruction(.return_, 3, 3, null, "");
    // exported_helper() { ret } — declared before normal_helper in the module
    instructions[3] = inst.makeInstruction(.export_decl, 4, 4, null, "");
    instructions[4] = inst.makeInstruction(.op, 5, 5, null, "");
    instructions[5] = inst.makeInstruction(.return_, 6, 6, null, "");
    // normal_helper() { call @exported_helper() }
    instructions[6] = inst.makeInstruction(.func_decl, 7, 7, null, "");
    instructions[7] = inst.makeInstruction(.call, 8, 8, null, "");
    instructions[7].operands[0] = .{ .text = "@exported_helper()" };
    instructions[8] = inst.makeInstruction(.return_, 9, 9, null, "");

    const module = sab.Module{
        .symbols = &.{},
        .function_sigs = function_sigs,
        .const_decls = &.{},
        .instructions = instructions,
        .owned_text = &.{},
    };

    try cg.appendDecodedModuleFiltered(module, &.{"entry"});

    // All three are reachable: entry -> normal_helper -> exported_helper.
    try std.testing.expectEqual(@as(usize, 3), cg.function_sigs.items.len);
    // Original decoded declaration order is preserved (exported before normal).
    try std.testing.expectEqualStrings("entry", cg.function_sigs.items[0].name);
    try std.testing.expectEqualStrings("exported_helper", cg.function_sigs.items[1].name);
    try std.testing.expectEqualStrings("normal_helper", cg.function_sigs.items[2].name);
    // The exported helper keeps its kind, and its full body was cloned (not a
    // decl-only stub): the module has 9 body instructions, so the filtered
    // clone must reproduce all of them.
    try std.testing.expectEqual(sig.FunctionKind.exported, cg.function_sigs.items[1].kind);
    try std.testing.expectEqual(@as(usize, 9), cg.instructions.items.len);
    // The exported helper's body add instruction survives at its cloned offset.
    try std.testing.expectEqual(inst.InstKind.export_decl, cg.instructions.items[3].kind);
    try std.testing.expectEqual(inst.InstKind.op, cg.instructions.items[4].kind);
}

test "filtered decoded std deps uniquify helper-local labels and regs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tc = type_checker.TypeChecker.init(allocator);
    defer tc.deinit();
    var cg = Codegen.init(allocator, &tc);
    defer cg.deinit();

    const entry_id: u32 = 0;
    const helper_a_id: u32 = 1;
    const helper_b_id: u32 = 2;
    const label_a_id: u32 = 3;
    const label_b_id: u32 = 4;
    const tmp_a_id: u32 = 5;
    const tmp_b_id: u32 = 6;
    const symbols = &.{ "entry", "helper_a", "helper_b", "L_same", "L_same", "tmp", "tmp" };

    const function_sigs = try allocator.alloc(sig.FunctionSig, 3);
    function_sigs[0] = try sig.parseFunctionSig(allocator, "@entry() -> void:", 0, 0);
    function_sigs[1] = try sig.parseFunctionSig(allocator, "@helper_a() -> void:", 1, 3);
    function_sigs[1].reg_ids = try allocator.dupe(u32, &.{tmp_a_id});
    function_sigs[2] = try sig.parseFunctionSig(allocator, "@helper_b() -> void:", 2, 10);
    function_sigs[2].reg_ids = try allocator.dupe(u32, &.{tmp_b_id});

    const instructions = try allocator.alloc(inst.Instruction, 13);
    instructions[0] = inst.makeInstruction(.func_decl, 1, 1, null, "");
    instructions[0].operands[0] = .{ .symbol = entry_id };
    instructions[0].operands[1] = .{ .func = entry_id };
    instructions[1] = inst.makeInstruction(.call, 2, 2, null, "");
    instructions[1].operands[0] = .{ .text = "@helper_a()" };
    instructions[2] = inst.makeInstruction(.return_, 3, 3, null, "");

    instructions[3] = inst.makeInstruction(.func_decl, 4, 4, null, "");
    instructions[3].operands[0] = .{ .symbol = helper_a_id };
    instructions[3].operands[1] = .{ .func = helper_a_id };
    instructions[4] = inst.makeInstruction(.label, 5, 5, null, "");
    instructions[4].operands[0] = .{ .symbol = label_a_id };
    instructions[4].operands[1] = .{ .label = label_a_id };
    instructions[5] = inst.makeInstruction(.assign, 6, 6, null, "");
    instructions[5].operands[0] = .{ .reg = tmp_a_id };
    instructions[5].operands[1] = .{ .imm_i64 = 1 };
    instructions[6] = inst.makeInstruction(.jmp, 7, 7, null, "");
    instructions[6].operands[0] = .{ .symbol = label_b_id };
    instructions[6].operands[1] = .{ .label = label_b_id };
    instructions[7] = inst.makeInstruction(.label, 8, 8, null, "");
    instructions[7].operands[0] = .{ .symbol = label_b_id };
    instructions[7].operands[1] = .{ .label = label_b_id };
    instructions[8] = inst.makeInstruction(.call, 9, 9, null, "");
    instructions[8].operands[0] = .{ .text = "@helper_b(tmp, copy_bytes)" };
    instructions[9] = inst.makeInstruction(.return_, 10, 10, null, "");

    instructions[10] = inst.makeInstruction(.func_decl, 11, 11, null, "");
    instructions[10].operands[0] = .{ .symbol = helper_b_id };
    instructions[10].operands[1] = .{ .func = helper_b_id };
    instructions[11] = inst.makeInstruction(.assign, 12, 12, null, "");
    instructions[11].operands[0] = .{ .reg = tmp_b_id };
    instructions[11].operands[1] = .{ .imm_i64 = 2 };
    instructions[12] = inst.makeInstruction(.return_, 13, 13, null, "");

    const module = sab.Module{
        .symbols = symbols,
        .function_sigs = function_sigs,
        .const_decls = &.{},
        .instructions = instructions,
        .owned_text = &.{},
    };

    try cg.appendDecodedModuleFiltered(module, &.{"entry"});

    try std.testing.expectEqual(@as(usize, 3), cg.function_sigs.items.len);
    try std.testing.expectEqual(@as(usize, 13), cg.instructions.items.len);
    try std.testing.expectEqualStrings("helper_b", cg.function_sigs.items[2].name);

    const first_label = cg.instructions.items[4].operands[1].label;
    const second_label = cg.instructions.items[7].operands[1].label;
    try std.testing.expect(first_label != second_label);
    try std.testing.expectEqual(first_label, cg.instructions.items[4].operands[0].symbol);
    try std.testing.expectEqual(second_label, cg.instructions.items[6].operands[0].symbol);
    try std.testing.expectEqual(second_label, cg.instructions.items[6].operands[1].label);
    try std.testing.expectEqual(second_label, cg.instructions.items[7].operands[0].symbol);

    const helper_a_reg = cg.instructions.items[5].operands[0].reg;
    const helper_b_reg = cg.instructions.items[11].operands[0].reg;
    try std.testing.expectEqual(helper_a_reg, cg.function_sigs.items[1].reg_ids[0]);
    try std.testing.expectEqual(helper_b_reg, cg.function_sigs.items[2].reg_ids[0]);
    try std.testing.expectEqual(@as(usize, 2), cg.function_sigs.items[1].reg_ids.len);
    const helper_a_text_only_reg = cg.function_sigs.items[1].reg_ids[1];
    try std.testing.expect(helper_a_text_only_reg != helper_a_reg);
    try std.testing.expectEqualStrings("copy_bytes", cg.symbols.items[helper_a_text_only_reg]);

    const helper_a_call = cg.instructions.items[8].operands[0].text;
    try std.testing.expect(std.mem.startsWith(u8, helper_a_call, "@helper_b("));
    try std.testing.expect(std.mem.indexOf(u8, helper_a_call, "tmp") != null);
    try std.testing.expect(std.mem.indexOf(u8, helper_a_call, "copy_bytes") != null);
    try std.testing.expect(std.mem.indexOf(u8, helper_a_call, cg.symbols.items[helper_a_reg]) != null);
}

test "filtered decoded std deps keep text-only helper regs in scope" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tc = type_checker.TypeChecker.init(allocator);
    defer tc.deinit();
    var cg = Codegen.init(allocator, &tc);
    defer cg.deinit();

    const copy_id: u32 = 0;
    const slot_id: u32 = 1;
    const count_source_id: u32 = 2;
    const symbols = &.{ "copy", "slot", "count" };

    const function_sigs = try allocator.alloc(sig.FunctionSig, 1);
    function_sigs[0] = try sig.parseFunctionSig(allocator, "@copy(count: u64) -> void:", 0, 0);
    function_sigs[0].kind = .exported;
    function_sigs[0].param_ids = try allocator.dupe(u32, &.{count_source_id});
    function_sigs[0].reg_ids = try allocator.dupe(u32, &.{count_source_id});

    const instructions = try allocator.alloc(inst.Instruction, 4);
    instructions[0] = inst.makeInstruction(.export_decl, 1, 1, null, "");
    instructions[0].operands[0] = .{ .symbol = copy_id };
    instructions[0].operands[1] = .{ .func = copy_id };
    instructions[1] = inst.makeInstruction(.stack_alloc, 2, 2, null, "");
    instructions[1].operands[0] = .{ .reg = slot_id };
    instructions[1].operands[1] = .{ .imm_u64 = 8 };
    instructions[2] = inst.makeInstruction(.store, 3, 3, null, "");
    instructions[2].operands[0] = .{ .reg = slot_id };
    instructions[2].operands[1] = .{ .imm_u64 = 0 };
    instructions[2].operands[2] = .{ .text = "count" };
    instructions[2].operands[3] = .{ .ty = @intFromEnum(sig.PrimType.u64) };
    instructions[3] = inst.makeInstruction(.return_, 4, 4, null, "");

    const module = sab.Module{
        .symbols = symbols,
        .function_sigs = function_sigs,
        .const_decls = &.{},
        .instructions = instructions,
        .owned_text = &.{},
    };

    try cg.appendDecodedModuleFiltered(module, &.{"copy"});

    try std.testing.expectEqual(@as(usize, 1), cg.function_sigs.items.len);
    const count_id = cg.symbol_ids.get("count") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(count_id, cg.function_sigs.items[0].param_ids[0]);
    var saw_count = false;
    for (cg.function_sigs.items[0].reg_ids) |reg_id| {
        if (reg_id == count_id) saw_count = true;
    }
    try std.testing.expect(saw_count);
    try std.testing.expectEqual(count_id, cg.instructions.items[2].operands[2].reg);
}

test "std macro template preserves hygiened placeholder output args" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tc = type_checker.TypeChecker.init(allocator);
    defer tc.deinit();
    var cg = Codegen.init(allocator, &tc);
    defer cg.deinit();

    const func_id: u32 = 0;
    const label_id: u32 = 1;
    const out_placeholder_id: u32 = 2;
    const value_placeholder_id: u32 = 3;
    const internal_id: u32 = 4;
    const symbols = &.{
        "__sla_macro_template_0",
        "L_ENTRY",
        "__frag7___sla_macro_arg_0",
        "__frag7___sla_macro_arg_1",
        "__box_clone_value___sla_macro_arg_0",
    };

    const function_sigs = try allocator.alloc(sig.FunctionSig, 1);
    function_sigs[0] = try sig.parseFunctionSig(allocator, "@__sla_macro_template_0() -> void:", 0, 0);

    const instructions = try allocator.alloc(inst.Instruction, 6);
    instructions[0] = inst.makeInstruction(.func_decl, 1, 1, null, "");
    instructions[0].operands[0] = .{ .symbol = func_id };
    instructions[0].operands[1] = .{ .func = func_id };
    instructions[1] = inst.makeInstruction(.label, 2, 2, null, "");
    instructions[1].operands[0] = .{ .symbol = label_id };
    instructions[1].operands[1] = .{ .label = label_id };
    instructions[2] = inst.makeInstruction(.alloc, 3, 3, null, "");
    instructions[2].operands[0] = .{ .reg = out_placeholder_id };
    instructions[2].operands[1] = .{ .imm_u64 = 8 };
    instructions[3] = inst.makeInstruction(.store, 4, 4, null, "");
    instructions[3].operands[0] = .{ .reg = out_placeholder_id };
    instructions[3].operands[1] = .{ .imm_u64 = 0 };
    instructions[3].operands[2] = .{ .reg = value_placeholder_id };
    instructions[3].operands[3] = .{ .ty = @intFromEnum(sig.PrimType.u64) };
    instructions[4] = inst.makeInstruction(.assign, 5, 5, null, "");
    instructions[4].operands[0] = .{ .reg = internal_id };
    instructions[4].operands[1] = .{ .imm_i64 = 1 };
    instructions[5] = inst.makeInstruction(.return_, 6, 6, null, "");

    const module = sab.Module{
        .symbols = symbols,
        .function_sigs = function_sigs,
        .const_decls = &.{},
        .instructions = instructions,
        .owned_text = &.{},
    };

    try cg.appendRenamedTemplateFragmentBody(module, "__sla_macro_template_0", &.{ "tmp_out", "value_reg" });

    const out_id = cg.symbol_ids.get("tmp_out") orelse return error.TestUnexpectedResult;
    const value_id = cg.symbol_ids.get("value_reg") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 3), cg.instructions.items.len);
    try std.testing.expectEqual(out_id, cg.instructions.items[0].operands[0].reg);
    try std.testing.expectEqual(out_id, cg.instructions.items[1].operands[0].reg);
    try std.testing.expectEqual(value_id, cg.instructions.items[1].operands[2].reg);

    const internal_reg = cg.instructions.items[2].operands[0].reg;
    try std.testing.expect(internal_reg != out_id);
    try std.testing.expect(std.mem.startsWith(u8, cg.symbols.items[internal_reg], "__frag"));
}

test "cached std macro template owns decoded symbols for placeholder remap" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tc = type_checker.TypeChecker.init(allocator);
    defer tc.deinit();
    var cg = Codegen.init(allocator, &tc);
    defer cg.deinit();

    const value_id = try cg.internStable("value_reg");
    try cg.recordReg(value_id);

    const template = try cg.cachedStdMacroTemplate("sa_std/core/box.sa", "BOX_NEW", 2);
    try cg.appendDecodedModuleConstDecls(template.module);
    try cg.appendRenamedTemplateFragmentBody(template.module, template.func_name, &.{ "tmp_out", "value_reg" });

    const out_id = cg.symbol_ids.get("tmp_out") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 2), cg.instructions.items.len);
    try std.testing.expectEqual(inst.InstKind.alloc, cg.instructions.items[0].kind);
    try std.testing.expectEqual(out_id, cg.instructions.items[0].operands[0].reg);
    try std.testing.expectEqual(inst.InstKind.store, cg.instructions.items[1].kind);
    try std.testing.expectEqual(out_id, cg.instructions.items[1].operands[0].reg);
    try std.testing.expectEqual(value_id, cg.instructions.items[1].operands[2].reg);
}

test "direct sab normal sig preserves borrow return cap" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tc = type_checker.TypeChecker.init(allocator);
    defer tc.deinit();
    var cg = Codegen.init(allocator, &tc);
    defer cg.deinit();

    const inner = try allocator.create(ast.Type);
    inner.* = .{ .primitive = .void_type };
    const borrow_ret = try allocator.create(ast.Type);
    borrow_ret.* = .{ .borrow = inner };

    const fsig = try cg.genFuncSig("borrowed_view", .normal, &.{}, borrow_ret, false, false, false);
    try std.testing.expectEqual(inst.CapPrefix.borrow, fsig.return_cap.?);
    try std.testing.expectEqual(sig.PrimType.ptr, fsig.return_ty);
}

test "direct sab normal sig keeps by-value ptr params raw" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tc = type_checker.TypeChecker.init(allocator);
    defer tc.deinit();
    var cg = Codegen.init(allocator, &tc);
    defer cg.deinit();

    const ptr_ty = try allocator.create(ast.Type);
    ptr_ty.* = .{ .primitive = .void_type };
    const int_ty = try allocator.create(ast.Type);
    int_ty.* = .{ .primitive = .i64 };

    const params = [_]ast.Param{.{ .name = "data", .ty = ptr_ty }};
    const fsig = try cg.genFuncSig("raw_ptr_param", .normal, &params, int_ty, false, false, false);
    try std.testing.expectEqual(inst.CapPrefix.by_value, fsig.params[0].cap);
    try std.testing.expectEqual(sig.PrimType.ptr, fsig.params[0].ty);
}

test "direct sab contract extern sig preserves return caps" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tc = type_checker.TypeChecker.init(allocator);
    defer tc.deinit();
    var cg = Codegen.init(allocator, &tc);
    defer cg.deinit();

    try tc.extern_funcs.put("sa_move_ptr", contract_parser.ExternalFunction{
        .name = "sa_move_ptr",
        .params = &.{},
        .ret_ty = "^ptr",
    });
    try tc.extern_funcs.put("sa_borrow_ptr", contract_parser.ExternalFunction{
        .name = "sa_borrow_ptr",
        .params = &.{},
        .ret_ty = "&ptr",
    });
    try tc.extern_funcs.put("sa_raw_ptr", contract_parser.ExternalFunction{
        .name = "sa_raw_ptr",
        .params = &.{},
        .ret_ty = "*ptr",
    });
    try tc.extern_funcs.put("sa_borrow_out", contract_parser.ExternalFunction{
        .name = "sa_borrow_out",
        .params = &.{.{ .name = "out_value", .ty = "ptr", .is_borrow = true, .is_move = false }},
        .ret_ty = "u32",
    });

    const move_sig = try cg.makeContractExternSig("sa_move_ptr", 0);
    const borrow_sig = try cg.makeContractExternSig("sa_borrow_ptr", 1);
    const raw_sig = try cg.makeContractExternSig("sa_raw_ptr", 2);
    const borrow_param_sig = try cg.makeContractExternSig("sa_borrow_out", 3);

    try std.testing.expectEqual(inst.CapPrefix.move, move_sig.return_cap.?);
    try std.testing.expectEqual(inst.CapPrefix.borrow, borrow_sig.return_cap.?);
    try std.testing.expectEqual(inst.CapPrefix.raw, raw_sig.return_cap.?);
    try std.testing.expectEqual(sig.PrimType.ptr, raw_sig.return_ty);
    try std.testing.expectEqual(inst.CapPrefix.borrow, borrow_param_sig.params[0].cap);
    try std.testing.expectEqual(sig.PrimType.ptr, borrow_param_sig.params[0].ty);
}

test "direct sab extern borrow call operand keeps prefix" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tc = type_checker.TypeChecker.init(allocator);
    defer tc.deinit();
    var cg = Codegen.init(allocator, &tc);
    defer cg.deinit();

    const raw = try cg.externBorrowCallOperand("tmp_3");
    const already = try cg.externBorrowCallOperand("&tmp_4");

    try std.testing.expectEqualSlices(u8, "&tmp_3", raw);
    try std.testing.expectEqualSlices(u8, "&tmp_4", already);
}
