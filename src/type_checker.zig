const std = @import("std");
const sio = @import("sio");
const ast = @import("ast.zig");
const lowering_rules = @import("lowering_rules.zig");
const control_flow_rules = @import("control_flow_rules.zig");
const contract_parser = @import("contract_parser.zig");
const sublanguage_shader = @import("sublanguage_shader.zig");
const check_hooks = @import("check_hooks.zig");

pub const TypeError = error{
    UndefinedVariable,
    Redeclaration,
    TypeMismatch,
    UseAfterMove,
    UseBeforeInit,
    InvalidBorrow,
    DereferenceNonPointer,
    FieldNotFound,
    NotAStruct,
    InvalidArgsCount,
    AmbiguousCall,
    CompileError,
    OutOfMemory,
};

pub const ValueState = control_flow_rules.ValueState;

pub const ImportedMacro = struct {
    arity: usize,
    leading_outputs: usize,
    import_path: ?[]const u8 = null,
    borrowed_arg_mask: u64 = 0,
    address_slot_arg_mask: u64 = 0,
    assigned_output_mask: u64 = 0,
    direct_callees: []const []const u8 = &.{},
};

const MacroConsumptionKey = struct {
    macro_decl: *const ast.MacroDecl,
    param_index: usize,
};

pub const Symbol = struct {
    name: []const u8,
    ty: *ast.Type,
    is_const: bool,
    state: ValueState,
    borrow_source: ?[]const u8 = null,
    // REG-BR-6: when this binding was consumed by being passed as a plain
    // by-value call argument, the name of that first consuming call, so a
    // later use can be diagnosed at the language level (naming the variable,
    // the first consuming call, and the explicit-copy fix) instead of leaking
    // the SA referee's UseAfterMove 1009.
    consumed_by_call: ?[]const u8 = null,
};

pub const InjectedScopeBinding = struct {
    name: []const u8,
    ty: *ast.Type,
    is_const: bool = false,
};

pub const Options = struct {
    injected_scope_bindings: []const InjectedScopeBinding = &.{},
    using_modules: []const []const u8 = &.{},
};

pub const Scope = struct {
    allocator: std.mem.Allocator,
    parent: ?*Scope,
    symbols: std.StringHashMap(Symbol),
    using_modules: std.array_list.Managed([]const u8),

    pub fn init(allocator: std.mem.Allocator, parent: ?*Scope) !*Scope {
        const self = try allocator.create(Scope);
        self.* = .{
            .allocator = allocator,
            .parent = parent,
            .symbols = std.StringHashMap(Symbol).init(allocator),
            .using_modules = std.array_list.Managed([]const u8).init(allocator),
        };
        return self;
    }

    pub fn deinit(self: *Scope) void {
        self.using_modules.deinit();
        self.symbols.deinit();
        self.allocator.destroy(self);
    }

    pub fn define(self: *Scope, name: []const u8, ty: *ast.Type, is_const: bool) !void {
        try self.defineWithState(name, ty, is_const, .active);
    }

    pub fn defineWithState(self: *Scope, name: []const u8, ty: *ast.Type, is_const: bool, state: ValueState) !void {
        if (self.symbols.contains(name)) return TypeError.Redeclaration;
        try self.symbols.put(name, .{
            .name = name,
            .ty = ty,
            .is_const = is_const,
            .state = state,
            .borrow_source = null,
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

/// Extern variadic batch: the result type of a `va_next_*` builtin, or
/// null when the name is not one. The readable set is exactly the C
/// promoted scalar set (the VaArgSafe analogue).
fn vaNextReadType(name: []const u8) ?ast.Type {
    const prim: ast.Primitive = if (std.mem.eql(u8, name, "va_next_i32"))
        .i32
    else if (std.mem.eql(u8, name, "va_next_i64"))
        .i64
    else if (std.mem.eql(u8, name, "va_next_u32"))
        .u32
    else if (std.mem.eql(u8, name, "va_next_u64"))
        .u64
    else if (std.mem.eql(u8, name, "va_next_f64"))
        .f64
    else if (std.mem.eql(u8, name, "va_next_ptr"))
        .raw_ptr
    else
        return null;
    return .{ .primitive = prim };
}

fn bindingIsLocalToLoop(scope: *Scope, loop_scope: *Scope, name: []const u8) bool {
    var curr: ?*Scope = scope;
    while (curr) |frame| : (curr = frame.parent) {
        if (frame.lookupLocal(name) != null) return true;
        if (frame == loop_scope) return false;
    }
    return false;
}

/// Goroutine syntax batch (channels): intrinsic channel operations
/// the checker validates and syntax_lowering.zig rewrites onto the
/// sa_std task channel externs.
pub const ChanCallKind = enum { new, send, recv, close, destroy, len, cap };
pub const ChanCallInfo = struct { kind: ChanCallKind, payload_ty: *ast.Type };

pub const TypeChecker = struct {
    pub const FunctionSignature = struct {
        params: []const ast.Param,
        ret_ty: *ast.Type,
        is_async: bool = false,
        is_variadic: bool = false,
    };

    pub const FunctionAliasMetadata = struct {
        alias: []const u8,
        target: []const u8,
        namespace: ?[]const u8 = null,
        module_path: ?[]const u8 = null,
    };

    allocator: std.mem.Allocator,
    structs: std.StringHashMap(*ast.StructDecl),
    type_aliases: std.StringHashMap(*ast.TypeAliasDecl),
    alias_struct_cache: std.StringHashMap(*ast.StructDecl),
    enums: std.StringHashMap(*ast.EnumDecl),
    traits: std.StringHashMap(*ast.TraitDecl),
    trait_impls: std.StringHashMap(void),
    extern_funcs: std.StringHashMap(contract_parser.ExternalFunction),
    layout_defines: std.StringHashMap(contract_parser.LayoutDefine),
    scope_pool: std.array_list.Managed(*Scope),

    // Maps a return/block exit node to the variables that need to be dropped
    cleanups: std.AutoHashMap(*const ast.Node, std.array_list.Managed([]const u8)),
    // Maps await expressions to cleanups used only when codegen emits a
    // generated pending return. Ready paths retain their ordinary state.
    await_cleanups: std.AutoHashMap(*const ast.Node, std.array_list.Managed([]const u8)),
    macro_call_try_cleanups: std.AutoHashMap(*const ast.CallExpr, std.array_list.Managed([]const u8)),
    // Maps a branch end to the variables to release for Phi resolution
    phi_cleanups: std.AutoHashMap(*const ast.Node, std.array_list.Managed([]const u8)),

    // Tracks internal Sla functions for validation
    funcs: std.StringHashMap(*ast.FuncDecl),
    function_aliases: std.StringHashMap([]const u8),
    function_alias_metadata: std.StringHashMap(FunctionAliasMetadata),
    imported_function_signatures: std.StringHashMap(FunctionSignature),
    // Function overloading (full range, exact-after-inference discipline):
    // same-name multi-signature candidate sets. Singletons never enter these
    // tables and keep the legacy single-signature paths untouched. Members of
    // a set are registered under a mangled member key (`<name>__ov_<tag>`);
    // FuncDecl members are renamed to their member key at registration.
    func_overload_sets: std.StringHashMap(std.array_list.Managed(*ast.FuncDecl)),
    overload_decl_plain_name: std.AutoHashMap(*const ast.FuncDecl, []const u8),
    imported_overload_sets: std.StringHashMap(std.array_list.Managed([]const u8)),
    imported_overload_members: std.StringHashMap(FunctionSignature),
    extern_overload_sets: std.StringHashMap(std.array_list.Managed(contract_parser.ExternalFunction)),
    // Tracks user-defined macros
    macros: std.StringHashMap(*ast.MacroDecl),
    imported_macros: std.StringHashMap(ImportedMacro),
    overloads: std.StringHashMap(std.array_list.Managed([]const u8)),
    using_modules_input: []const []const u8,
    // Maps expressions to their validated types for use in Codegen layout offsets
    expr_types: std.AutoHashMap(*const ast.Node, *ast.Type),
    dyn_call_traits: std.AutoHashMap(*const ast.Node, []const u8),
    dyn_borrow_args: std.AutoHashMap(*const ast.Node, []const u8),
    dyn_box_coercions: std.AutoHashMap(*const ast.Node, []const u8),
    dyn_rc_coercions: std.AutoHashMap(*const ast.Node, []const u8),
    fn_ptr_calls: std.AutoHashMap(*const ast.Node, void),
    // Goroutine syntax batch: for each go_expr node, the entry function
    // type recorded at check time so the post-check lowering in
    // syntax_lowering.zig can materialize the entry argument.
    go_entry_types: std.AutoHashMap(*const ast.Node, *ast.Type),
    monitor_calls: std.AutoHashMap(*const ast.Node, void),
    // Goroutine syntax batch (channels): every Chan::new call seen,
    // the subset validated by a Chan<T>-annotated let binding, the
    // payload type a let annotation supplied for a pending new call,
    // and the per-call intrinsic record the lowering consumes.
    chan_new_seen: std.AutoHashMap(*const ast.Node, void),
    chan_new_validated: std.AutoHashMap(*const ast.Node, void),
    chan_new_pending: std.AutoHashMap(*const ast.Node, *ast.Type),
    chan_calls: std.AutoHashMap(*const ast.Node, ChanCallInfo),
    array_to_slice_borrow_args: std.AutoHashMap(*const ast.Node, void),
    // Extern variadic batch: for each trailing argument of a call to a
    // variadic extern, the C-promoted type the codegens must emit for it.
    variadic_promotions: std.AutoHashMap(*const ast.Node, *ast.Type),
    // Extern variadic batch: whether the function body currently being
    // checked is an exported extern "C" variadic definition (gates the
    // va_next_* builtins).
    current_fn_is_variadic_def: bool = false,
    resolved_call_symbols: std.AutoHashMap(*const ast.Node, []const u8),
    resolved_call_alias_metadata: std.AutoHashMap(*const ast.Node, FunctionAliasMetadata),
    current_function_name: ?[]const u8,
    // Goroutine syntax batch R2: whether the function body
    // currently being checked is async (shallow: reset inside
    // closure bodies and test bodies).
    current_fn_is_async: bool,
    current_function_namespace: ?[]const u8,
    current_loop_scope: ?*Scope,
    current_loop_body_terminates: bool,
    // REG-BR-6: while checking an assignment statement's right-hand
    // side, the target identifier and value node, so the call-argument
    // consumption hook can recognize the self-assignment tail form
    // (`x = f(x, ..)`) whose consumption is healed by the assignment
    // itself.
    assign_rhs_target_name: ?[]const u8 = null,
    assign_rhs_value: ?*const ast.Node = null,
    field_borrows: std.array_list.Managed(FieldBorrow),
    global_scope: ?*Scope,
    unsafe_depth: usize,
    injected_scope_bindings: []const InjectedScopeBinding,
    last_error: []const u8,
    last_error_buf: [1024]u8,

    pub fn init(allocator: std.mem.Allocator) TypeChecker {
        return initWithOptions(allocator, .{});
    }

    pub fn initWithOptions(allocator: std.mem.Allocator, options: Options) TypeChecker {
        return .{
            .allocator = allocator,
            .field_borrows = std.array_list.Managed(FieldBorrow).init(allocator),
            .structs = std.StringHashMap(*ast.StructDecl).init(allocator),
            .type_aliases = std.StringHashMap(*ast.TypeAliasDecl).init(allocator),
            .alias_struct_cache = std.StringHashMap(*ast.StructDecl).init(allocator),
            .enums = std.StringHashMap(*ast.EnumDecl).init(allocator),
            .traits = std.StringHashMap(*ast.TraitDecl).init(allocator),
            .trait_impls = std.StringHashMap(void).init(allocator),
            .extern_funcs = std.StringHashMap(contract_parser.ExternalFunction).init(allocator),
            .layout_defines = std.StringHashMap(contract_parser.LayoutDefine).init(allocator),
            .scope_pool = std.array_list.Managed(*Scope).init(allocator),
            .cleanups = std.AutoHashMap(*const ast.Node, std.array_list.Managed([]const u8)).init(allocator),
            .await_cleanups = std.AutoHashMap(*const ast.Node, std.array_list.Managed([]const u8)).init(allocator),
            .macro_call_try_cleanups = std.AutoHashMap(*const ast.CallExpr, std.array_list.Managed([]const u8)).init(allocator),
            .phi_cleanups = std.AutoHashMap(*const ast.Node, std.array_list.Managed([]const u8)).init(allocator),
            .funcs = std.StringHashMap(*ast.FuncDecl).init(allocator),
            .function_aliases = std.StringHashMap([]const u8).init(allocator),
            .function_alias_metadata = std.StringHashMap(FunctionAliasMetadata).init(allocator),
            .imported_function_signatures = std.StringHashMap(FunctionSignature).init(allocator),
            .func_overload_sets = std.StringHashMap(std.array_list.Managed(*ast.FuncDecl)).init(allocator),
            .overload_decl_plain_name = std.AutoHashMap(*const ast.FuncDecl, []const u8).init(allocator),
            .imported_overload_sets = std.StringHashMap(std.array_list.Managed([]const u8)).init(allocator),
            .imported_overload_members = std.StringHashMap(FunctionSignature).init(allocator),
            .extern_overload_sets = std.StringHashMap(std.array_list.Managed(contract_parser.ExternalFunction)).init(allocator),
            .macros = std.StringHashMap(*ast.MacroDecl).init(allocator),
            .imported_macros = std.StringHashMap(ImportedMacro).init(allocator),
            .overloads = std.StringHashMap(std.array_list.Managed([]const u8)).init(allocator),
            .using_modules_input = options.using_modules,
            .expr_types = std.AutoHashMap(*const ast.Node, *ast.Type).init(allocator),
            .dyn_call_traits = std.AutoHashMap(*const ast.Node, []const u8).init(allocator),
            .dyn_borrow_args = std.AutoHashMap(*const ast.Node, []const u8).init(allocator),
            .dyn_box_coercions = std.AutoHashMap(*const ast.Node, []const u8).init(allocator),
            .dyn_rc_coercions = std.AutoHashMap(*const ast.Node, []const u8).init(allocator),
            .fn_ptr_calls = std.AutoHashMap(*const ast.Node, void).init(allocator),
            .go_entry_types = std.AutoHashMap(*const ast.Node, *ast.Type).init(allocator),
            .monitor_calls = std.AutoHashMap(*const ast.Node, void).init(allocator),
            .chan_new_seen = std.AutoHashMap(*const ast.Node, void).init(allocator),
            .chan_new_validated = std.AutoHashMap(*const ast.Node, void).init(allocator),
            .chan_new_pending = std.AutoHashMap(*const ast.Node, *ast.Type).init(allocator),
            .chan_calls = std.AutoHashMap(*const ast.Node, ChanCallInfo).init(allocator),
            .array_to_slice_borrow_args = std.AutoHashMap(*const ast.Node, void).init(allocator),
            .variadic_promotions = std.AutoHashMap(*const ast.Node, *ast.Type).init(allocator),
            .resolved_call_symbols = std.AutoHashMap(*const ast.Node, []const u8).init(allocator),
            .resolved_call_alias_metadata = std.AutoHashMap(*const ast.Node, FunctionAliasMetadata).init(allocator),
            .current_function_name = null,
            .current_fn_is_async = false,
            .current_function_namespace = null,
            .current_loop_scope = null,
            .current_loop_body_terminates = false,
            .global_scope = null,
            .unsafe_depth = 0,
            .injected_scope_bindings = options.injected_scope_bindings,
            .last_error = "",
            .last_error_buf = undefined,
        };
    }

    pub fn setError(self: *TypeChecker, comptime fmt: []const u8, args: anytype) void {
        var fba = std.heap.FixedBufferAllocator.init(&self.last_error_buf);
        self.last_error = std.fmt.allocPrint(fba.allocator(), fmt, args) catch "Error formatting diagnostic";
    }

    fn defineSymbol(self: *TypeChecker, scope: *Scope, name: []const u8, ty: *ast.Type, is_const: bool) TypeError!void {
        try self.defineSymbolWithState(scope, name, ty, is_const, .active);
    }

    fn defineSymbolWithState(self: *TypeChecker, scope: *Scope, name: []const u8, ty: *ast.Type, is_const: bool, state: ValueState) TypeError!void {
        scope.defineWithState(name, ty, is_const, state) catch |err| switch (err) {
            TypeError.Redeclaration => {
                self.setError("Redeclaration: symbol `{s}` is already defined", .{name});
                return TypeError.Redeclaration;
            },
            TypeError.OutOfMemory => return TypeError.OutOfMemory,
            else => return err,
        };
    }

    fn consumeBinding(self: *TypeChecker, scope: *Scope, name: []const u8, sym: *Symbol, operation: []const u8) TypeError!void {
        if (self.current_loop_scope) |loop_scope| {
            if (!self.current_loop_body_terminates and !bindingIsLocalToLoop(scope, loop_scope, name)) {
                self.setError("LoopConditionalConsume: binding `{s}` declared before the loop cannot be consumed by {s} inside the loop body", .{ name, operation });
                return TypeError.CompileError;
            }
        }
        sym.state = .consumed;
        sym.consumed_by_call = null;
    }

    fn consumeExternMoveArg(self: *TypeChecker, scope: *Scope, param: contract_parser.Param, arg: *const ast.Node) TypeError!void {
        if (!param.is_move) return;
        if (arg.* == .move_expr) return;
        if (arg.* != .identifier) return;

        const sym = scope.lookup(arg.identifier) orelse return TypeError.UndefinedVariable;
        if (sym.state == .consumed) return TypeError.UseAfterMove;
        if (sym.state == .uninitialized) {
            self.setError("UseBeforeInit: var `{s}` is read before assignment", .{arg.identifier});
            return TypeError.UseBeforeInit;
        }
        try self.consumeBinding(scope, arg.identifier, sym, "extern move argument");
    }

    fn directBorrowSource(expr: *const ast.Node) ?[]const u8 {
        return switch (expr.*) {
            .identifier => |name| name,
            .borrow_expr => |borrow| if (borrow.expr.* == .identifier) borrow.expr.identifier else null,
            else => null,
        };
    }

    fn borrowSourceAliasedByOtherActive(self: *TypeChecker, scope: *Scope, name: []const u8) bool {
        _ = self;
        // issue013: when a borrow value is `let y = x;` (x is a borrow), the borrow
        // handle is carried into y; only y should be released at scope exit.
        // Return true if some *other* active symbol `y` in the same scope (or an
        // ancestor scope) has borrow_source == name -- in that case we skip the
        // source `name` from cleanup, otherwise SA vm gets a double release
        // (UseAfterMove / PhiStateConflict).
        var curr: ?*Scope = scope;
        while (curr) |frame| : (curr = frame.parent) {
            var iter = frame.symbols.valueIterator();
            while (iter.next()) |sym| {
                if (std.mem.eql(u8, sym.name, name)) continue;
                if (sym.state != .active) continue;
                if (sym.borrow_source) |bsrc| {
                    if (std.mem.eql(u8, bsrc, name)) return true;
                }
            }
        }
        return false;
    }

    // ---- View-types stage 1: field-granularity borrow accounting ----
    // A place is a root binding plus a path of segments: field names,
    // "@" for a deref step, "*" for a dynamic index, or the literal
    // index digits. Two places overlap when they share a root and one
    // segment list is a prefix of the other ("*" matches any single
    // segment). The checker tracks live borrows at this granularity so
    // disjoint field borrows are legal everywhere (locals, call args,
    // any offset, both backends) while overlapping mutable borrows are
    // rejected loudly at check time instead of depending on which
    // register a backend happened to lock.
    const FieldPlace = struct {
        root: []const u8,
        segs: []const []const u8,
    };

    const FieldBorrow = struct {
        place: FieldPlace,
        borrower: []const u8,
        def_scope: *Scope,
    };

    fn placeOfExpr(self: *TypeChecker, expr: *const ast.Node) ?FieldPlace {
        var segs = std.array_list.Managed([]const u8).init(self.allocator);
        defer segs.deinit();
        var cur = expr;
        while (true) {
            switch (cur.*) {
                .field_expr => |f| {
                    segs.append(f.field_name) catch return null;
                    cur = f.expr;
                },
                .index_expr => |ix| {
                    if (ix.index.* == .literal and ix.index.literal == .int_val) {
                        const digits = std.fmt.allocPrint(self.allocator, "{}", .{ix.index.literal.int_val}) catch return null;
                        segs.append(digits) catch return null;
                    } else {
                        segs.append("*") catch return null;
                    }
                    cur = ix.target;
                },
                .deref_expr => |d| {
                    segs.append("@") catch return null;
                    cur = d.expr;
                },
                .borrow_expr => |b| {
                    cur = b.expr;
                },
                .move_expr => |m| {
                    cur = m.expr;
                },
                .identifier => |name| {
                    const owned = segs.toOwnedSlice() catch return null;
                    std.mem.reverse([]const u8, owned);
                    return .{ .root = name, .segs = owned };
                },
                else => return null,
            }
        }
    }

    fn fieldPlacesOverlap(a: FieldPlace, b: FieldPlace) bool {
        if (!std.mem.eql(u8, a.root, b.root)) return false;
        const n = @min(a.segs.len, b.segs.len);
        for (a.segs[0..n], b.segs[0..n]) |x, y| {
            if (std.mem.eql(u8, x, y)) continue;
            if (std.mem.eql(u8, x, "*") or std.mem.eql(u8, y, "*")) continue;
            return false;
        }
        return true;
    }

    fn fieldPlacesIdentical(a: FieldPlace, b: FieldPlace) bool {
        if (!std.mem.eql(u8, a.root, b.root)) return false;
        if (a.segs.len != b.segs.len) return false;
        for (a.segs, b.segs) |x, y| {
            if (!std.mem.eql(u8, x, y)) return false;
        }
        return true;
    }

    fn fieldPlaceDesc(self: *TypeChecker, place: FieldPlace) []const u8 {
        var buf = std.array_list.Managed(u8).init(self.allocator);
        buf.appendSlice(place.root) catch return place.root;
        for (place.segs) |seg| {
            if (std.mem.eql(u8, seg, "@")) {
                buf.appendSlice(".*") catch {};
            } else if (std.mem.eql(u8, seg, "*")) {
                buf.appendSlice("[_]") catch {};
            } else {
                buf.append('.') catch {};
                buf.appendSlice(seg) catch {};
            }
        }
        return buf.items;
    }

    fn fieldBorrowIsLive(self: *TypeChecker, scope: *Scope, entry: FieldBorrow) bool {
        _ = self;
        var curr: ?*Scope = scope;
        while (curr) |frame| : (curr = frame.parent) {
            if (frame == entry.def_scope) {
                if (frame.symbols.get(entry.borrower)) |sym| return sym.state == .active;
                return false;
            }
        }
        return false;
    }

    fn liveFieldBorrowConflict(self: *TypeChecker, scope: *Scope, place: FieldPlace) ?FieldBorrow {
        for (self.field_borrows.items) |entry| {
            if (!self.fieldBorrowIsLive(scope, entry)) continue;
            if (fieldPlacesOverlap(entry.place, place)) return entry;
        }
        return null;
    }

    fn rootHasLiveFieldBorrow(self: *TypeChecker, scope: *Scope, root: []const u8) ?FieldBorrow {
        for (self.field_borrows.items) |entry| {
            if (!std.mem.eql(u8, entry.place.root, root)) continue;
            if (!self.fieldBorrowIsLive(scope, entry)) continue;
            return entry;
        }
        return null;
    }

    fn dropFieldBorrowsOf(self: *TypeChecker, scope: *Scope, borrower: []const u8) void {
        // Resolve the scope that defines `borrower` from here; entries are
        // keyed by that exact frame so a shadowed name in a child scope
        // does not drop the outer borrow.
        var def_scope: ?*Scope = null;
        var curr: ?*Scope = scope;
        while (curr) |frame| : (curr = frame.parent) {
            if (frame.symbols.contains(borrower)) {
                def_scope = frame;
                break;
            }
        }
        const ds = def_scope orelse return;
        var i = self.field_borrows.items.len;
        while (i > 0) {
            i -= 1;
            const e = self.field_borrows.items[i];
            if (e.def_scope == ds and std.mem.eql(u8, e.borrower, borrower)) {
                _ = self.field_borrows.orderedRemove(i);
            }
        }
    }

    fn registerFieldBorrow(self: *TypeChecker, scope: *Scope, place: FieldPlace, borrower: []const u8) TypeError!void {
        self.dropFieldBorrowsOf(scope, borrower);
        self.field_borrows.append(.{ .place = place, .borrower = borrower, .def_scope = scope }) catch return TypeError.OutOfMemory;
    }

    /// The place a let/assign value borrows from, when the value is a
    /// direct borrow of a place, an alias of a tracked borrow binding,
    /// an alias of a direct borrow source, or a borrow-typed field/index
    /// extraction out of a place.
    fn borrowPlaceOfValue(self: *TypeChecker, scope: *Scope, value: *const ast.Node) ?FieldPlace {
        if (value.* == .borrow_expr) return self.placeOfExpr(value.borrow_expr.expr);
        if (value.* == .identifier) {
            for (self.field_borrows.items) |entry| {
                if (std.mem.eql(u8, entry.borrower, value.identifier) and self.fieldBorrowIsLive(scope, entry)) {
                    return entry.place;
                }
            }
            if (scope.lookup(value.identifier)) |sym| {
                if (sym.borrow_source) |src| return .{ .root = src, .segs = &.{} };
            }
            return null;
        }
        if (value.* == .field_expr or value.* == .index_expr) return self.placeOfExpr(value);
        return null;
    }

    /// Root binding of a place expression, walking deref steps too
    /// (rootIdentifier deliberately does not: `*x = v` writes through
    /// the borrow binding x).
    fn placeRootName(node: *const ast.Node) ?[]const u8 {
        return switch (node.*) {
            .identifier => |n| n,
            .field_expr => |f| placeRootName(f.expr),
            .index_expr => |ix| placeRootName(ix.target),
            .deref_expr => |d| placeRootName(d.expr),
            .borrow_expr => |b| placeRootName(b.expr),
            .move_expr => |m| placeRootName(m.expr),
            else => null,
        };
    }

    /// Conservative scan: true when a function body may write through
    /// the named parameter (direct assignment, borrow creation that can
    /// escape into another binding, or forwarding the parameter's place
    /// into any call). Unknown node shapes count as writes.
    fn nodeMayWriteThroughParam(node: *const ast.Node, name: []const u8) bool {
        switch (node.*) {
            .identifier, .literal => return false,
            .assign_stmt => |a| {
                if (placeRootName(a.target)) |r| {
                    if (std.mem.eql(u8, r, name)) return true;
                }
                return nodeMayWriteThroughParam(a.target, name) or nodeMayWriteThroughParam(a.value, name);
            },
            .call_expr => |c| {
                if (c.callee) |callee| {
                    if (nodeMayWriteThroughParam(callee, name)) return true;
                }
                for (c.args) |arg| {
                    if (rootIdentifier(arg)) |r| {
                        if (std.mem.eql(u8, r, name)) return true;
                    }
                    if (nodeMayWriteThroughParam(arg, name)) return true;
                }
                return false;
            },
            .borrow_expr => |b| {
                if (placeRootName(b.expr)) |r| {
                    if (std.mem.eql(u8, r, name)) return true;
                }
                return nodeMayWriteThroughParam(b.expr, name);
            },
            .move_expr => |m| {
                if (placeRootName(m.expr)) |r| {
                    if (std.mem.eql(u8, r, name)) return true;
                }
                return nodeMayWriteThroughParam(m.expr, name);
            },
            .let_stmt => |l| return nodeMayWriteThroughParam(l.value, name),
            .const_stmt => |c| return nodeMayWriteThroughParam(c.value, name),
            .let_else_stmt => |l| {
                if (nodeMayWriteThroughParam(l.value, name)) return true;
                for (l.else_block) |s| {
                    if (nodeMayWriteThroughParam(s, name)) return true;
                }
                return false;
            },
            .expr_stmt => |e| return nodeMayWriteThroughParam(e, name),
            .return_stmt => |r| {
                if (r.value) |v| return nodeMayWriteThroughParam(v, name);
                return false;
            },
            .block_stmt => |b| {
                for (b.body) |s| {
                    if (nodeMayWriteThroughParam(s, name)) return true;
                }
                return false;
            },
            .if_expr => |e| {
                if (nodeMayWriteThroughParam(e.cond, name)) return true;
                for (e.then_block) |s| {
                    if (nodeMayWriteThroughParam(s, name)) return true;
                }
                if (e.else_block) |eb| {
                    for (eb) |s| {
                        if (nodeMayWriteThroughParam(s, name)) return true;
                    }
                }
                return false;
            },
            .while_stmt => |w| {
                if (nodeMayWriteThroughParam(w.cond, name)) return true;
                for (w.body) |s| {
                    if (nodeMayWriteThroughParam(s, name)) return true;
                }
                return false;
            },
            .for_stmt => |f| {
                if (nodeMayWriteThroughParam(f.start, name)) return true;
                if (f.end) |e| {
                    if (nodeMayWriteThroughParam(e, name)) return true;
                }
                for (f.body) |s| {
                    if (nodeMayWriteThroughParam(s, name)) return true;
                }
                return false;
            },
            .binary_expr => |b| return nodeMayWriteThroughParam(b.left, name) or nodeMayWriteThroughParam(b.right, name),
            .field_expr => |f| return nodeMayWriteThroughParam(f.expr, name),
            .index_expr => |ix| return nodeMayWriteThroughParam(ix.target, name) or nodeMayWriteThroughParam(ix.index, name),
            .deref_expr => |d| return nodeMayWriteThroughParam(d.expr, name),
            .cast_expr => |c| return nodeMayWriteThroughParam(c.expr, name),
            .try_expr => |t| return nodeMayWriteThroughParam(t.expr, name),
            .struct_literal => |lit| {
                if (lit.update_expr) |u| {
                    if (nodeMayWriteThroughParam(u, name)) return true;
                }
                for (lit.fields) |fld| {
                    if (nodeMayWriteThroughParam(fld.value, name)) return true;
                }
                return false;
            },
            .tuple_literal => |t| {
                for (t.elements) |e| {
                    if (nodeMayWriteThroughParam(e, name)) return true;
                }
                return false;
            },
            .array_literal => |a| {
                for (a.elements) |e| {
                    if (nodeMayWriteThroughParam(e, name)) return true;
                }
                return false;
            },
            .closure_literal => |c| return nodeMayWriteThroughParam(c.body, name),
            .defer_stmt => |d| return nodeMayWriteThroughParam(d.call, name),
            else => return true,
        }
    }

    fn paramMayBeWritten(func: *const ast.FuncDecl, param_name: []const u8) bool {
        if (func.is_decl_only) return true;
        for (func.body) |stmt| {
            if (nodeMayWriteThroughParam(stmt, param_name)) return true;
        }
        return false;
    }

    /// Pure (side-effect-free) type of a place expression, resolved
    /// from scope bindings and struct declarations only, mirroring the
    /// field/index/deref typing of checkExprImpl without running it.
    /// Returns null when the type cannot be established this way;
    /// callers must treat null as "unknown", never as a concrete type.
    fn placeExprType(self: *TypeChecker, expr: *const ast.Node, scope: *Scope) ?*ast.Type {
        switch (expr.*) {
            .identifier => |name| {
                const sym = scope.lookup(name) orelse return null;
                return sym.ty;
            },
            .move_expr => |m| return self.placeExprType(m.expr, scope),
            .field_expr => |f| {
                const target_ty = self.placeExprType(f.expr, scope) orelse return null;
                if (std.mem.eql(u8, f.field_name, "len") and isStringLikeType(target_ty)) {
                    const ty = self.allocator.create(ast.Type) catch return null;
                    ty.* = .{ .primitive = .u64 };
                    return ty;
                }
                const curr_ty = @constCast(lowering_rules.peelBorrowPointerType(target_ty));
                switch (curr_ty.*) {
                    .user_defined => {
                        const decl = self.structDeclForType(curr_ty) orelse return null;
                        if (decl.is_opaque) return null;
                        for (decl.fields) |field| {
                            if (std.mem.eql(u8, field.name, f.field_name)) return field.ty;
                        }
                        return null;
                    },
                    .tuple => |tuple| {
                        const index = std.fmt.parseInt(usize, f.field_name, 10) catch return null;
                        if (index >= tuple.elems.len) return null;
                        return tuple.elems[index];
                    },
                    else => return null,
                }
            },
            .index_expr => |ix| {
                const target_ty = self.placeExprType(ix.target, scope) orelse return null;
                if (target_ty.* == .infer) return null;
                if (hashMapTypes(target_ty)) |hm| return hm.value;
                if (btreeMapTypes(target_ty)) |bm| return bm.value;
                if (vecElementType(target_ty)) |elem_ty| return elem_ty;
                if (vecDequeElementType(target_ty)) |elem_ty| return elem_ty;
                if (sliceElementType(target_ty)) |elem_ty| return elem_ty;
                if (arrayType(target_ty)) |arr| return arr.elem;
                return null;
            },
            .deref_expr => |d| {
                const inner_ty = self.placeExprType(d.expr, scope) orelse return null;
                if (inner_ty.* == .infer) return null;
                return @constCast(lowering_rules.pointerOrBorrowPointee(inner_ty) orelse return null);
            },
            else => return null,
        }
    }

    /// A plain (by-value) argument whose place has a Copy type is a
    /// pure read: evaluating it produces an independent value copy, so
    /// it cannot alias or invalidate a borrow of an overlapping place
    /// taken by the same call (it is exactly the "bind the reads to
    /// locals first" form, which is legal). Only non-Copy places are
    /// true by-value moves. The Copy decision comes from the argument
    /// expression's own type so signature calls and macro calls
    /// (params == null) classify identically.
    fn plainArgIsCopyRead(self: *TypeChecker, arg: *const ast.Node, scope: *Scope) bool {
        const ty = self.placeExprType(arg, scope) orelse return false;
        return self.typeIsCopy(ty);
    }

    /// Pairwise place-overlap validation for one call's arguments.
    /// Borrowed places come from explicit borrow expressions, from
    /// plain places passed to borrow parameters (auto-borrow), or from
    /// mask-flagged macro argument slots. Overlapping borrows of
    /// prefix-related (but not identical) places are always rejected;
    /// identical places are rejected unless both corresponding
    /// parameters are provably read-only in the callee body; a borrowed
    /// place may not overlap any plain place argument either — except
    /// that a plain argument which is a by-value read of a Copy-typed
    /// place is not a move and never conflicts (see plainArgIsCopyRead);
    /// and a by-value move of a root may not happen while a field of
    /// it is borrowed by a live local.
    fn checkCallArgPlaceOverlaps(
        self: *TypeChecker,
        params: ?[]const ast.Param,
        args: []const *ast.Node,
        scope: *Scope,
        call_name: []const u8,
        callee: ?*const ast.FuncDecl,
        borrowed_mask: u64,
    ) TypeError!void {
        const ArgPlace = struct { borrowed: ?FieldPlace = null, plain: ?FieldPlace = null };
        var places = std.array_list.Managed(ArgPlace).init(self.allocator);
        defer places.deinit();
        for (args, 0..) |arg, i| {
            var ap = ArgPlace{};
            if (arg.* == .borrow_expr) {
                ap.borrowed = self.placeOfExpr(arg.borrow_expr.expr);
            } else if (self.placeOfExpr(arg)) |p| {
                var is_borrowed = borrowed_mask & (@as(u64, 1) << @as(u6, @intCast(@min(i, 63)))) != 0;
                if (params) |ps| {
                    if (i < ps.len and (ps[i].ty.* == .borrow or ps[i].is_borrow)) is_borrowed = true;
                }
                if (is_borrowed) {
                    ap.borrowed = p;
                } else if (!self.plainArgIsCopyRead(arg, scope)) {
                    ap.plain = p;
                }
            }
            places.append(ap) catch return TypeError.OutOfMemory;
        }
        // Borrowed places against live local borrows.
        for (places.items) |ap| {
            if (ap.borrowed) |bp| {
                if (self.liveFieldBorrowConflict(scope, bp)) |conflict| {
                    self.setError("BorrowConflict: call to {s} borrows `{s}` while `{s}` is still borrowed by `{s}`", .{ call_name, self.fieldPlaceDesc(bp), self.fieldPlaceDesc(conflict.place), conflict.borrower });
                    return TypeError.InvalidBorrow;
                }
            }
        }
        // Borrowed against borrowed / plain within the call.
        for (places.items, 0..) |a, i| {
            const ab = a.borrowed orelse continue;
            for (places.items, 0..) |b, j| {
                if (i == j) continue;
                if (b.borrowed) |bb| {
                    if (j < i) continue;
                    if (!fieldPlacesOverlap(ab, bb)) continue;
                    if (fieldPlacesIdentical(ab, bb)) {
                        var read_only = false;
                        if (callee != null and params != null and i < params.?.len and j < params.?.len) {
                            read_only = !paramMayBeWritten(callee.?, params.?[i].name) and !paramMayBeWritten(callee.?, params.?[j].name);
                        }
                        if (read_only) continue;
                    }
                    self.setError("BorrowConflict: call to {s} borrows overlapping places `{s}` and `{s}` in the same call", .{ call_name, self.fieldPlaceDesc(ab), self.fieldPlaceDesc(bb) });
                    return TypeError.InvalidBorrow;
                }
                if (b.plain) |bp| {
                    if (fieldPlacesOverlap(ab, bp)) {
                        self.setError("BorrowConflict: call to {s} borrows `{s}` while also passing overlapping place `{s}` in the same call", .{ call_name, self.fieldPlaceDesc(ab), self.fieldPlaceDesc(bp) });
                        return TypeError.InvalidBorrow;
                    }
                }
            }
        }
        // By-value move of a root while a field of it is borrowed.
        for (args, places.items) |arg, ap| {
            if (ap.plain == null or arg.* != .identifier) continue;
            const sym = scope.lookup(arg.identifier) orelse continue;
            if (self.typeIsCopy(sym.ty) or isBorrowLikeType(sym.ty)) continue;
            if (self.rootHasLiveFieldBorrow(scope, arg.identifier)) |conflict| {
                self.setError("BorrowConflict: call to {s} moves `{s}` while `{s}` is still borrowed by `{s}`", .{ call_name, arg.identifier, self.fieldPlaceDesc(conflict.place), conflict.borrower });
                return TypeError.InvalidBorrow;
            }
        }
    }

    fn functionExitBindingEscapes(scope: *Scope, result_expr: *const ast.Node, candidate: []const u8) bool {
        const result_name = switch (result_expr.*) {
            .identifier => |name| name,
            .move_expr => |move| if (move.expr.* == .identifier) move.expr.identifier else return false,
            else => return false,
        };
        if (std.mem.eql(u8, candidate, result_name)) return true;

        var current_name = result_name;
        var remaining: usize = 1;
        var current_scope: ?*Scope = scope;
        while (current_scope) |frame| : (current_scope = frame.parent) remaining += frame.symbols.count();
        while (remaining > 0) : (remaining -= 1) {
            const current = scope.lookup(current_name) orelse return false;
            const source = current.borrow_source orelse return false;
            if (std.mem.eql(u8, candidate, source)) return true;
            current_name = source;
        }
        return false;
    }

    fn recordAwaitCleanup(self: *TypeChecker, await_node: *const ast.Node, future_expr: *const ast.Node, scope: *Scope) TypeError!void {
        var cleanup_list = std.array_list.Managed([]const u8).init(self.allocator);
        var current: ?*Scope = scope;
        while (current) |frame| : (current = frame.parent) {
            var iter = frame.symbols.valueIterator();
            while (iter.next()) |sym| {
                if (sym.state != .active or isInternalSymbol(sym.name)) continue;
                if (functionExitBindingEscapes(scope, future_expr, sym.name)) continue;
                // issue013: skip borrowed source that was aliased.
                if (isBorrowLikeType(sym.ty) and self.borrowSourceAliasedByOtherActive(scope, sym.name)) continue;
                try cleanup_list.append(sym.name);
            }
        }
        if (cleanup_list.items.len == 0) {
            cleanup_list.deinit();
            return;
        }
        try self.await_cleanups.put(await_node, cleanup_list);
    }

    fn ensureTopLevelNameUnused(self: *TypeChecker, name: []const u8, kind: []const u8) TypeError!void {
        if (self.structs.contains(name) or self.enums.contains(name) or self.traits.contains(name) or self.funcs.contains(name) or self.func_overload_sets.contains(name) or self.macros.contains(name)) {
            self.setError("Redeclaration: {s} `{s}` is already defined", .{ kind, name });
            return TypeError.Redeclaration;
        }
    }

    /// True when two same-named top-level functions form a legal C-style
    /// prototype/definition pair: exactly one is body-less, both use the extern
    /// ABI surface, and the signatures agree. Anything else stays a redeclaration.
    fn externPrototypePairsWith(a: *const ast.FuncDecl, b: *const ast.FuncDecl) bool {
        if (a.is_decl_only == b.is_decl_only) return false;
        const prototype = if (a.is_decl_only) a else b;
        const definition = if (a.is_decl_only) b else a;
        if (!prototype.is_extern) return false;
        if (!definition.is_extern and !definition.no_mangle) return false;
        if (prototype.abi != null and definition.abi != null and !std.mem.eql(u8, prototype.abi.?, definition.abi.?)) return false;
        if (prototype.is_variadic != definition.is_variadic) return false;
        if (prototype.is_variadic) {
            // Extern variadic batch: the prototype lists only the fixed
            // parameters (its list ends with `...`); the definition lists
            // the same fixed parameters plus the trailing VaList binding.
            if (definition.params.len == 0) return false;
            const last = definition.params[definition.params.len - 1];
            if (!(last.ty.* == .primitive and last.ty.primitive == .va_list)) return false;
            if (prototype.params.len != definition.params.len - 1) return false;
            for (prototype.params, definition.params[0 .. definition.params.len - 1]) |p, d| {
                if (!typesStructurallyEqual(p.ty, d.ty)) return false;
            }
            return typesStructurallyEqual(prototype.ret_ty, definition.ret_ty);
        }
        if (prototype.params.len != definition.params.len) return false;
        for (prototype.params, definition.params) |p, d| {
            if (!typesStructurallyEqual(p.ty, d.ty)) return false;
        }
        return typesStructurallyEqual(prototype.ret_ty, definition.ret_ty);
    }

    /// Allocation-free structural type comparison used before the checker's type
    /// tables are populated, so it cannot resolve aliases — declarations and
    /// definitions must spell their signature the same way.
    fn typesStructurallyEqual(a: *const ast.Type, b: *const ast.Type) bool {
        if (std.meta.activeTag(a.*) != std.meta.activeTag(b.*)) return false;
        return switch (a.*) {
            .infer => true,
            .primitive => |p| p == b.primitive,
            .pointer => typesStructurallyEqual(a.pointer, b.pointer),
            .borrow => typesStructurallyEqual(a.borrow, b.borrow),
            .future => typesStructurallyEqual(a.future, b.future),
            .array => |arr| arr.len == b.array.len and typesStructurallyEqual(arr.elem, b.array.elem),
            .tuple => |tup| blk: {
                if (tup.elems.len != b.tuple.elems.len) break :blk false;
                for (tup.elems, b.tuple.elems) |x, y| {
                    if (!typesStructurallyEqual(x, y)) break :blk false;
                }
                break :blk true;
            },
            .closure => |c| blk: {
                if (c.params.len != b.closure.params.len) break :blk false;
                for (c.params, b.closure.params) |x, y| {
                    if (!typesStructurallyEqual(x, y)) break :blk false;
                }
                break :blk typesStructurallyEqual(c.ret, b.closure.ret);
            },
            .fn_ptr => |f| blk: {
                if (f.is_variadic != b.fn_ptr.is_variadic) break :blk false;
                if (f.params.len != b.fn_ptr.params.len) break :blk false;
                for (f.params, b.fn_ptr.params) |x, y| {
                    if (!typesStructurallyEqual(x, y)) break :blk false;
                }
                break :blk typesStructurallyEqual(f.ret, b.fn_ptr.ret);
            },
            .user_defined => |ud| blk: {
                if (!std.mem.eql(u8, ud.name, b.user_defined.name)) break :blk false;
                if (ud.generics.len != b.user_defined.generics.len) break :blk false;
                for (ud.generics, b.user_defined.generics) |x, y| {
                    if (!typesStructurallyEqual(x, y)) break :blk false;
                }
                break :blk true;
            },
        };
    }

    /// Strict type identity for overload signatures: unlike `typesEqual`,
    /// integer widths are NOT interchangeable (i32 != i64) and untyped
    /// literal types (.integer/.float) equal only themselves. Used both for
    /// declaration-time signature identity and call-site exact matching.
    fn strictTypesEqual(a: *const ast.Type, b: *const ast.Type) bool {
        if (std.meta.activeTag(a.*) != std.meta.activeTag(b.*)) return false;
        return switch (a.*) {
            .infer => true,
            .primitive => |p| p == b.primitive,
            .pointer => strictTypesEqual(a.pointer, b.pointer),
            .borrow => strictTypesEqual(a.borrow, b.borrow),
            .future => strictTypesEqual(a.future, b.future),
            .array => |arr| arr.len == b.array.len and strictTypesEqual(arr.elem, b.array.elem),
            .tuple => |tup| blk: {
                if (tup.elems.len != b.tuple.elems.len) break :blk false;
                for (tup.elems, b.tuple.elems) |x, y| {
                    if (!strictTypesEqual(x, y)) break :blk false;
                }
                break :blk true;
            },
            .closure => |c| blk: {
                if (c.params.len != b.closure.params.len) break :blk false;
                for (c.params, b.closure.params) |x, y| {
                    if (!strictTypesEqual(x, y)) break :blk false;
                }
                break :blk strictTypesEqual(c.ret, b.closure.ret);
            },
            .fn_ptr => |f| blk: {
                if (f.params.len != b.fn_ptr.params.len) break :blk false;
                for (f.params, b.fn_ptr.params) |x, y| {
                    if (!strictTypesEqual(x, y)) break :blk false;
                }
                break :blk strictTypesEqual(f.ret, b.fn_ptr.ret);
            },
            .user_defined => |ud| blk: {
                if (!std.mem.eql(u8, ud.name, b.user_defined.name)) break :blk false;
                if (ud.generics.len != b.user_defined.generics.len) break :blk false;
                for (ud.generics, b.user_defined.generics) |x, y| {
                    if (!strictTypesEqual(x, y)) break :blk false;
                }
                break :blk true;
            },
        };
    }

    /// Parameter-list identity for overload declarations: arity, strict
    /// parameter types, and capability markers (borrow/move) must all agree.
    /// Return type is deliberately excluded — declarations whose parameter
    /// lists agree collide even if their return types differ.
    /// The parameters that make up a declaration's call signature:
    /// a variadic definition's trailing VaList parameter is the
    /// variadic marker itself, not a fixed parameter (mirrors
    /// checkCallArgsAgainstFunc).
    fn signatureParams(fd: *const ast.FuncDecl) []const ast.Param {
        if (fd.is_variadic and fd.params.len > 0) {
            const last = fd.params[fd.params.len - 1];
            if (last.ty.* == .primitive and last.ty.primitive == .va_list) {
                return fd.params[0 .. fd.params.len - 1];
            }
        }
        return fd.params;
    }

    /// Class identity for overload grouping: two declarations share
    /// a class when their signatures agree — fixed parameters plus
    /// the variadic marker. A variadic prototype (fixed parameters
    /// only) and its definition (fixed parameters + VaList binding)
    /// thus class together and pair, while a fixed and a variadic
    /// declaration with identical fixed parameters stay distinct
    /// members of one set.
    fn overloadClassSignaturesEqual(a: *const ast.FuncDecl, b: *const ast.FuncDecl) bool {
        if (a.is_variadic != b.is_variadic) return false;
        return paramSignaturesEqual(signatureParams(a), signatureParams(b));
    }

    fn paramSignaturesEqual(a: []const ast.Param, b: []const ast.Param) bool {
        if (a.len != b.len) return false;
        for (a, b) |pa, pb| {
            if (pa.is_borrow != pb.is_borrow or pa.is_move != pb.is_move) return false;
            if (!strictTypesEqual(pa.ty, pb.ty)) return false;
        }
        return true;
    }

    /// Short type rendering for overload diagnostics: `name(i32, &String) -> bool`.
    fn appendTypeShort(list: *std.array_list.Managed(u8), ty: *const ast.Type) !void {
        switch (ty.*) {
            .infer => try list.appendSlice("_"),
            .primitive => |p| try list.appendSlice(switch (p) {
                .boolean => "bool",
                .void_type => "void",
                .raw_ptr => "ptr",
                .integer => "int",
                .float => "float",
                else => @tagName(p),
            }),
            .pointer => |inner| {
                try list.append('*');
                try appendTypeShort(list, inner);
            },
            .borrow => |inner| {
                try list.append('&');
                try appendTypeShort(list, inner);
            },
            .future => |inner| {
                try list.appendSlice("Future<");
                try appendTypeShort(list, inner);
                try list.append('>');
            },
            .array => |arr| {
                try list.append('[');
                try appendTypeShort(list, arr.elem);
                sio.managedPrint(list, "; {}]", .{arr.len}) catch return error.OutOfMemory;
            },
            .tuple => |tup| {
                try list.append('(');
                for (tup.elems, 0..) |elem, i| {
                    if (i > 0) try list.appendSlice(", ");
                    try appendTypeShort(list, elem);
                }
                try list.append(')');
            },
            .closure => |c| {
                try list.appendSlice("fn(");
                for (c.params, 0..) |param, i| {
                    if (i > 0) try list.appendSlice(", ");
                    try appendTypeShort(list, param);
                }
                try list.appendSlice(") -> ");
                try appendTypeShort(list, c.ret);
            },
            .fn_ptr => |f| {
                try list.appendSlice("fn(");
                for (f.params, 0..) |param, i| {
                    if (i > 0) try list.appendSlice(", ");
                    try appendTypeShort(list, param);
                }
                try list.appendSlice(") -> ");
                try appendTypeShort(list, f.ret);
            },
            .user_defined => |ud| {
                try list.appendSlice(ud.name);
                if (ud.generics.len > 0) {
                    try list.append('<');
                    for (ud.generics, 0..) |g, i| {
                        if (i > 0) try list.appendSlice(", ");
                        try appendTypeShort(list, g);
                    }
                    try list.append('>');
                }
            },
        }
    }

    fn renderParamsShort(self: *TypeChecker, params: []const ast.Param) ![]const u8 {
        var list = std.array_list.Managed(u8).init(self.allocator);
        for (params, 0..) |param, i| {
            if (i > 0) try list.appendSlice(", ");
            try appendTypeShort(&list, param.ty);
        }
        return list.toOwnedSlice();
    }

    /// Canonical tag encoding of one type for overload member keys.
    /// Grammar (recursive, `_` joins parameters at the key level):
    /// primitive = its spelling; `*T` = "p"+enc; `&T` = "r"+enc;
    /// [T; N] = "a{N}_"+enc; tuple = "t"+encs+"e"; closure/fn_ptr =
    /// "f"+encs+"e"; Future<T> = "fu"+enc; user type = "u{len}{Name}"+encs.
    fn appendOverloadTypeTag(list: *std.array_list.Managed(u8), ty: *const ast.Type) !void {
        switch (ty.*) {
            .infer => try list.appendSlice("infer"),
            .primitive => |p| try list.appendSlice(switch (p) {
                .boolean => "bool",
                .void_type => "void",
                .raw_ptr => "ptr",
                else => @tagName(p),
            }),
            .pointer => |inner| {
                try list.append('p');
                try appendOverloadTypeTag(list, inner);
            },
            .borrow => |inner| {
                try list.append('r');
                try appendOverloadTypeTag(list, inner);
            },
            .future => |inner| {
                try list.appendSlice("fu");
                try appendOverloadTypeTag(list, inner);
            },
            .array => |arr| {
                sio.managedPrint(list, "a{}_", .{arr.len}) catch return error.OutOfMemory;
                try appendOverloadTypeTag(list, arr.elem);
            },
            .tuple => |tup| {
                try list.append('t');
                for (tup.elems, 0..) |elem, i| {
                    if (i > 0) try list.append('_');
                    try appendOverloadTypeTag(list, elem);
                }
                try list.append('e');
            },
            .closure => |c| {
                try list.append('f');
                for (c.params, 0..) |param, i| {
                    if (i > 0) try list.append('_');
                    try appendOverloadTypeTag(list, param);
                }
                try list.appendSlice("_e");
            },
            .fn_ptr => |f| {
                try list.append('f');
                for (f.params, 0..) |param, i| {
                    if (i > 0) try list.append('_');
                    try appendOverloadTypeTag(list, param);
                }
                try list.appendSlice("_e");
            },
            .user_defined => |ud| {
                sio.managedPrint(list, "u{}{s}", .{ ud.name.len, ud.name }) catch return error.OutOfMemory;
                for (ud.generics) |g| {
                    try list.append('_');
                    try appendOverloadTypeTag(list, g);
                }
            },
        }
    }

    /// Member key for one overload candidate: `<name>__ov_<tag>`, with a
    /// trailing capability marker per parameter (`b` = borrow, `m` = move)
    /// so capability-only signature differences still produce distinct keys.
    /// The empty parameter list encodes as `v`. `__ov_` is a reserved marker:
    /// source-level function names containing it are rejected at registration.
    pub fn overloadMemberKey(self: *TypeChecker, name: []const u8, params: []const ast.Param) ![]const u8 {
        var tag = std.array_list.Managed(u8).init(self.allocator);
        defer tag.deinit();
        if (params.len == 0) {
            try tag.append('v');
        } else {
            for (params, 0..) |param, i| {
                if (i > 0) try tag.append('_');
                try appendOverloadTypeTag(&tag, param.ty);
                if (param.is_borrow) try tag.append('b');
                if (param.is_move) try tag.append('m');
            }
        }
        return std.fmt.allocPrint(self.allocator, "{s}__ov_{s}", .{ name, tag.items });
    }

    fn normalizeUsingPath(self: *TypeChecker, using_path: []const u8) TypeError![]const u8 {
        var buf = std.array_list.Managed(u8).init(self.allocator);
        var i: usize = 0;
        while (i < using_path.len) {
            if (i + 1 < using_path.len and using_path[i] == ':' and using_path[i + 1] == ':') {
                try buf.appendSlice("__");
                i += 2;
            } else {
                try buf.append(using_path[i]);
                i += 1;
            }
        }
        return try buf.toOwnedSlice();
    }

    fn usingSymbolPrefix(self: *TypeChecker, using_path: []const u8, method_name: []const u8) TypeError![]const u8 {
        const normalized = try self.normalizeUsingPath(using_path);
        defer self.allocator.free(normalized);
        return try std.fmt.allocPrint(self.allocator, "{s}__{s}", .{ normalized, method_name });
    }

    fn overloadKey(self: *TypeChecker, type_name: []const u8, op_name: []const u8) TypeError![]const u8 {
        return std.fmt.allocPrint(self.allocator, "{s}|{s}", .{ type_name, op_name }) catch return TypeError.OutOfMemory;
    }

    fn operatorToOverloadName(op: ast.BinaryOp) ?[]const u8 {
        return switch (op) {
            .add => "op_add",
            .sub => "op_sub",
            .mul => "op_mul",
            .div => "op_div",
            .spaceship => "op_cmp",
            else => null,
        };
    }

    fn overloadSymbol(self: *TypeChecker, op: ast.BinaryOp, left_ty: *ast.Type, right_ty: *ast.Type) TypeError!?[]const u8 {
        const op_name = operatorToOverloadName(op) orelse return null;
        const left_name = concreteTypeName(left_ty) orelse return null;
        const key = try self.overloadKey(left_name, op_name);
        defer self.allocator.free(key);
        const list = self.overloads.get(key) orelse return null;

        var found: ?[]const u8 = null;
        for (list.items) |symbol| {
            const func = self.funcs.get(symbol) orelse continue;
            if (func.params.len != 2) continue;
            if (!self.typesEqual(func.params[0].ty, left_ty)) continue;
            if (!self.typesEqual(func.params[1].ty, right_ty)) continue;
            if (found) |prev| {
                if (!std.mem.eql(u8, prev, symbol)) {
                    self.setError("Ambiguous overload for operator `{s}` on `{s}`", .{ op_name, left_name });
                    return TypeError.AmbiguousCall;
                }
            } else {
                found = symbol;
            }
        }
        return found;
    }

    fn currentUsingModules(self: *TypeChecker, scope: *Scope) std.array_list.Managed([]const u8) {
        var mods = std.array_list.Managed([]const u8).init(self.allocator);
        var curr: ?*Scope = scope;
        while (curr) |s| {
            for (s.using_modules.items) |m| {
                mods.append(m) catch {};
            }
            curr = s.parent;
        }
        return mods;
    }

    fn resolveUsingMethodSymbolForType(
        self: *TypeChecker,
        scope: *Scope,
        recv_ty: *ast.Type,
        method_name: []const u8,
        arg_count: usize,
    ) TypeError!?[]const u8 {
        const recv = unwrappedReceiverType(recv_ty);

        var found_symbol: ?[]const u8 = null;
        var mods = self.currentUsingModules(scope);
        defer mods.deinit();
        for (mods.items) |using_path| {
            const symbol = try self.usingSymbolPrefix(using_path, method_name);
            defer self.allocator.free(symbol);
            if (!self.funcs.contains(symbol)) continue;
            const func = self.funcs.get(symbol) orelse continue;
            if (func.params.len != arg_count) continue;
            if (!self.receiverParamMatches(func.params[0], recv_ty)) continue;
            if (found_symbol) |prev| {
                if (!std.mem.eql(u8, prev, symbol)) {
                    const recv_name = if (recv.* == .user_defined) recv.user_defined.name else @tagName(recv.*);
                    self.setError("Ambiguous static extension call `{s}` for type `{s}`", .{ method_name, recv_name });
                    return TypeError.AmbiguousCall;
                }
            } else {
                found_symbol = try self.allocator.dupe(u8, symbol);
            }
        }
        return found_symbol;
    }

    fn isDiscardName(name: []const u8) bool {
        return std.mem.eql(u8, name, "_");
    }

    pub fn deinit(self: *TypeChecker) void {
        self.structs.deinit();
        self.type_aliases.deinit();
        self.alias_struct_cache.deinit();
        self.enums.deinit();
        self.traits.deinit();
        self.trait_impls.deinit();
        self.extern_funcs.deinit();
        self.layout_defines.deinit();
        self.function_aliases.deinit();
        self.function_alias_metadata.deinit();
        self.imported_function_signatures.deinit();
        var fos_it = self.func_overload_sets.valueIterator();
        while (fos_it.next()) |list| list.deinit();
        self.func_overload_sets.deinit();
        self.overload_decl_plain_name.deinit();
        var ios_it = self.imported_overload_sets.valueIterator();
        while (ios_it.next()) |list| list.deinit();
        self.imported_overload_sets.deinit();
        self.imported_overload_members.deinit();
        var eos_it = self.extern_overload_sets.valueIterator();
        while (eos_it.next()) |list| list.deinit();
        self.extern_overload_sets.deinit();
        self.funcs.deinit();
        self.macros.deinit();
        self.imported_macros.deinit();
        var overload_it = self.overloads.valueIterator();
        while (overload_it.next()) |list| {
            list.deinit();
        }
        self.overloads.deinit();
        self.expr_types.deinit();
        self.dyn_call_traits.deinit();
        self.dyn_borrow_args.deinit();
        self.dyn_box_coercions.deinit();
        self.dyn_rc_coercions.deinit();
        self.fn_ptr_calls.deinit();
        self.go_entry_types.deinit();
        self.monitor_calls.deinit();
        self.chan_new_seen.deinit();
        self.chan_new_validated.deinit();
        self.chan_new_pending.deinit();
        self.chan_calls.deinit();
        self.array_to_slice_borrow_args.deinit();
        self.variadic_promotions.deinit();
        self.resolved_call_symbols.deinit();
        self.resolved_call_alias_metadata.deinit();
        for (self.scope_pool.items) |s| {
            s.deinit();
        }
        self.scope_pool.deinit();

        var cleanup_iter = self.cleanups.valueIterator();
        while (cleanup_iter.next()) |list| {
            list.deinit();
        }
        self.cleanups.deinit();

        var await_cleanup_iter = self.await_cleanups.valueIterator();
        while (await_cleanup_iter.next()) |list| {
            list.deinit();
        }
        self.await_cleanups.deinit();

        var macro_try_cleanup_iter = self.macro_call_try_cleanups.valueIterator();
        while (macro_try_cleanup_iter.next()) |list| list.deinit();
        self.macro_call_try_cleanups.deinit();

        var phi_iter = self.phi_cleanups.valueIterator();
        while (phi_iter.next()) |list| {
            list.deinit();
        }
        self.phi_cleanups.deinit();
    }

    fn isInternalSymbol(name: []const u8) bool {
        return lowering_rules.isInternalSymbol(name);
    }

    fn isPrimitiveType(ty: *const ast.Type, primitive: ast.Primitive) bool {
        return lowering_rules.isPrimitiveType(ty, primitive);
    }

    fn isIntegerPrimitive(primitive: ast.Primitive) bool {
        return lowering_rules.isIntegerPrimitive(primitive);
    }

    fn isFloatPrimitive(primitive: ast.Primitive) bool {
        return lowering_rules.isFloatPrimitive(primitive);
    }

    fn isAnyIntegerType(ty: *const ast.Type) bool {
        return lowering_rules.isAnyIntegerType(ty);
    }

    fn isAnyFloatType(ty: *const ast.Type) bool {
        return lowering_rules.isAnyFloatType(ty);
    }

    fn isStringType(ty: *const ast.Type) bool {
        return lowering_rules.isStringType(ty);
    }

    fn isBorrowLikeType(ty: *const ast.Type) bool {
        return lowering_rules.isBorrowLikeType(ty);
    }

    /// BTreeSet keys are slices/C strings at runtime (key slots hold
    /// pointer-sized string data); scalar keys (int/bool/…) would be stored
    /// as bogus pointers and silently never match. Reject them loudly.
    fn btreeSetKeySupported(self: *TypeChecker, key_ty: *ast.Type) bool {
        _ = self;
        if (key_ty.* == .primitive and key_ty.primitive == .raw_ptr) return true;
        if (lowering_rules.sliceElementType(key_ty) != null) return true;
        return false;
    }

    fn iterableElementType(ty: *ast.Type) ?*ast.Type {
        if (arrayType(ty)) |arr| return arr.elem;
        if (sliceElementType(ty)) |elem| return elem;
        if (vecElementType(ty)) |elem| return elem;
        return null;
    }

    fn unwrappedReceiverType(ty: *ast.Type) *ast.Type {
        return lowering_rules.unwrapPointerLikeType(ty);
    }

    pub fn methodForType(self: *TypeChecker, ty: *ast.Type, method_name: []const u8) ?*ast.FuncDecl {
        const recv = unwrappedReceiverType(ty);
        if (recv.* != .user_defined) return null;
        var method_buf: [256]u8 = undefined;
        const key = std.fmt.bufPrint(&method_buf, "{s}_{s}", .{ recv.user_defined.name, method_name }) catch return null;
        return self.funcs.get(key);
    }

    pub fn registerFunctionAlias(self: *TypeChecker, alias: []const u8, target: []const u8) !void {
        try self.registerFunctionAliasWithMetadata(alias, target, null, null);
    }

    pub fn registerFunctionAliasWithMetadata(self: *TypeChecker, alias: []const u8, target: []const u8, namespace: ?[]const u8, module_path: ?[]const u8) !void {
        try self.function_aliases.put(alias, target);
        try self.function_alias_metadata.put(alias, .{
            .alias = alias,
            .target = target,
            .namespace = namespace,
            .module_path = module_path,
        });
    }

    pub fn resolveFunctionAlias(self: *TypeChecker, name: []const u8) []const u8 {
        return self.function_aliases.get(name) orelse name;
    }

    pub fn resolveFunctionAliasMetadata(self: *TypeChecker, name: []const u8) ?FunctionAliasMetadata {
        return self.function_alias_metadata.get(name);
    }

    fn recordResolvedCallSymbol(self: *TypeChecker, expr: *const ast.Node, call_name: []const u8, resolved_name: []const u8) TypeError!void {
        if (self.resolveFunctionAliasMetadata(call_name)) |metadata| {
            try self.resolved_call_symbols.put(expr, metadata.target);
            try self.resolved_call_alias_metadata.put(expr, metadata);
        } else if (self.resolveFunctionAliasMetadata(resolved_name)) |metadata| {
            try self.resolved_call_symbols.put(expr, metadata.target);
            try self.resolved_call_alias_metadata.put(expr, metadata);
        } else {
            try self.resolved_call_symbols.put(expr, resolved_name);
        }
    }

    pub fn registerImportedFunctionSignature(self: *TypeChecker, name: []const u8, params: []const ast.Param, ret_ty: *ast.Type, is_async: bool, is_variadic: bool) !void {
        try self.imported_function_signatures.put(name, .{
            .params = params,
            .ret_ty = ret_ty,
            .is_async = is_async,
            .is_variadic = is_variadic,
        });
    }

    /// Register one member of an imported .sla overload set. `member_key` is
    /// the canonical key computed from the plain (defining-module) name, so
    /// calls resolved through either the plain name or a module alias set
    /// converge on the same emitted symbol.
    pub fn registerImportedFunctionOverloadMember(self: *TypeChecker, set_name: []const u8, member_key: []const u8, params: []const ast.Param, ret_ty: *ast.Type, is_async: bool) !void {
        try self.imported_overload_members.put(member_key, .{
            .params = params,
            .ret_ty = ret_ty,
            .is_async = is_async,
        });
        const gop = try self.imported_overload_sets.getOrPut(set_name);
        if (!gop.found_existing) gop.value_ptr.* = std.array_list.Managed([]const u8).init(self.allocator);
        for (gop.value_ptr.items) |existing| {
            if (std.mem.eql(u8, existing, member_key)) return;
        }
        try gop.value_ptr.append(member_key);
    }

    // --- Overload resolution (exact-after-inference) ---

    const SymbolMark = struct {
        scope: *Scope,
        name: []const u8,
        state: ValueState,
        consumed_by_call: ?[]const u8,
        borrow_source: ?[]const u8,
    };

    /// Probing argument types for overload resolution re-runs checkExpr on
    /// arguments whose nested calls would otherwise consume bindings a
    /// second time when the winning candidate is validated for real.
    /// Snapshot the scope chain's symbol states before probing and roll
    /// them back afterwards; the final validation re-checks (and consumes)
    /// from the restored state.
    fn snapshotOverloadProbeStates(self: *TypeChecker, scope: *Scope) !std.array_list.Managed(SymbolMark) {
        var marks = std.array_list.Managed(SymbolMark).init(self.allocator);
        var current: ?*Scope = scope;
        while (current) |frame| {
            var it = frame.symbols.iterator();
            while (it.next()) |entry| {
                try marks.append(.{
                    .scope = frame,
                    .name = entry.key_ptr.*,
                    .state = entry.value_ptr.state,
                    .consumed_by_call = entry.value_ptr.consumed_by_call,
                    .borrow_source = entry.value_ptr.borrow_source,
                });
            }
            current = frame.parent;
        }
        return marks;
    }

    fn restoreOverloadProbeStates(self: *TypeChecker, marks: std.array_list.Managed(SymbolMark)) void {
        _ = self;
        for (marks.items) |mark| {
            if (mark.scope.symbols.getPtr(mark.name)) |sym| {
                sym.state = mark.state;
                sym.consumed_by_call = mark.consumed_by_call;
                sym.borrow_source = mark.borrow_source;
            }
        }
    }

    /// Call-site matching comparison: strict identity, except untyped
    /// literal types on the argument side adapt to any same-class concrete
    /// primitive (.integer -> any integer type, .float -> f32/f64), and
    /// `.infer` components (e.g. unannotated closure parameters) act as
    /// wildcards. Deliberately NOT typesEqual: integer widths never blur.
    fn callMatchTypesEqual(param_ty: *const ast.Type, arg_ty: *const ast.Type) bool {
        if (param_ty.* == .infer or arg_ty.* == .infer) return true;
        if (param_ty.* == .primitive and arg_ty.* == .primitive) {
            if (param_ty.primitive == arg_ty.primitive) return true;
            if (arg_ty.primitive == .integer) return isIntegerPrimitive(param_ty.primitive);
            if (arg_ty.primitive == .float) return param_ty.primitive == .f32 or param_ty.primitive == .f64;
            return false;
        }
        if (std.meta.activeTag(param_ty.*) != std.meta.activeTag(arg_ty.*)) {
            // A borrow argument may satisfy a pointer parameter (and vice
            // versa) when the pointees match, mirroring plainCallArgMatches.
            if (param_ty.* == .pointer and arg_ty.* == .borrow) return callMatchTypesEqual(param_ty.pointer, arg_ty.borrow);
            if (param_ty.* == .borrow and arg_ty.* == .pointer) return callMatchTypesEqual(param_ty.borrow, arg_ty.pointer);
            return false;
        }
        return switch (param_ty.*) {
            .infer, .primitive => unreachable,
            .pointer => callMatchTypesEqual(param_ty.pointer, arg_ty.pointer),
            .borrow => callMatchTypesEqual(param_ty.borrow, arg_ty.borrow),
            .future => callMatchTypesEqual(param_ty.future, arg_ty.future),
            .array => |arr| arr.len == arg_ty.array.len and callMatchTypesEqual(arr.elem, arg_ty.array.elem),
            .tuple => |tup| blk: {
                if (tup.elems.len != arg_ty.tuple.elems.len) break :blk false;
                for (tup.elems, arg_ty.tuple.elems) |x, y| {
                    if (!callMatchTypesEqual(x, y)) break :blk false;
                }
                break :blk true;
            },
            .closure => |c| blk: {
                if (c.params.len != arg_ty.closure.params.len) break :blk false;
                for (c.params, arg_ty.closure.params) |x, y| {
                    if (!callMatchTypesEqual(x, y)) break :blk false;
                }
                break :blk callMatchTypesEqual(c.ret, arg_ty.closure.ret);
            },
            .fn_ptr => |f| blk: {
                if (f.params.len != arg_ty.fn_ptr.params.len) break :blk false;
                for (f.params, arg_ty.fn_ptr.params) |x, y| {
                    if (!callMatchTypesEqual(x, y)) break :blk false;
                }
                break :blk callMatchTypesEqual(f.ret, arg_ty.fn_ptr.ret);
            },
            .user_defined => |ud| blk: {
                if (!std.mem.eql(u8, ud.name, arg_ty.user_defined.name)) break :blk false;
                if (ud.generics.len != arg_ty.user_defined.generics.len) break :blk false;
                for (ud.generics, arg_ty.user_defined.generics) |x, y| {
                    if (!callMatchTypesEqual(x, y)) break :blk false;
                }
                break :blk true;
            },
        };
    }

    fn overloadParamMatches(param: ast.Param, arg: *ast.Node, arg_ty: *ast.Type) bool {
        if (param.is_move and arg.* != .move_expr) return false;
        if (arg.* == .literal) {
            // Untyped literal nodes adapt to any same-class concrete
            // parameter type; if several candidates are distinguished only
            // by such a position, all of them win and the resolver reports
            // ambiguity (the call site must annotate).
            switch (arg.literal) {
                .string_val => if (isStringType(param.ty)) return true,
                .int_val => if (param.ty.* == .primitive and isIntegerPrimitive(param.ty.primitive)) return true,
                .float_val => if (param.ty.* == .primitive and (param.ty.primitive == .f32 or param.ty.primitive == .f64)) return true,
                .bool_val => {},
            }
        }
        if (param.ty.* == .borrow) {
            if (arg_ty.* == .borrow) return callMatchTypesEqual(param.ty.borrow, arg_ty.borrow);
            return false;
        }
        return callMatchTypesEqual(param.ty, unwrapBorrowForCallArg(arg, arg_ty));
    }

    fn primitiveFromSpelling(name: []const u8) ?ast.Primitive {
        const names = .{ "i8", "i16", "i32", "i64", "isize", "u8", "u16", "u32", "u64", "usize", "f32", "f64" };
        inline for (names) |n| {
            if (std.mem.eql(u8, name, n)) return @field(ast.Primitive, n);
        }
        if (std.mem.eql(u8, name, "bool")) return .boolean;
        return null;
    }

    /// Matching for .sai contract parameters, whose types are ABI spellings.
    /// The legacy FFI path performs no argument type checking at all; this
    /// matcher exists only to distinguish overload candidates, so pointer
    /// spellings accept any pointer-like argument and named spellings
    /// accept the same-named user type. Anything it cannot distinguish
    /// simply leaves multiple winners, which the resolver reports as
    /// ambiguity rather than guessing.
    fn contractParamMatches(spelling_raw: []const u8, arg: *ast.Node, arg_ty: *ast.Type) bool {
        const spelling = std.mem.trim(u8, spelling_raw, " \t\r");
        const effective = unwrapBorrowForCallArg(arg, arg_ty);
        if (std.mem.eql(u8, spelling, "ptr")) {
            return effective.* == .pointer or effective.* == .borrow or effective.* == .fn_ptr or
                (effective.* == .primitive and effective.primitive == .raw_ptr);
        }
        if (spelling.len > 0 and (spelling[0] == '*' or spelling[0] == '^')) {
            return effective.* == .pointer or effective.* == .borrow or
                (effective.* == .primitive and effective.primitive == .raw_ptr);
        }
        if (spelling.len > 0 and spelling[0] == '&') {
            return arg_ty.* == .borrow;
        }
        if (primitiveFromSpelling(spelling)) |prim| {
            if (arg.* == .literal) {
                switch (arg.literal) {
                    .int_val => return isIntegerPrimitive(prim),
                    .float_val => return prim == .f32 or prim == .f64,
                    else => {},
                }
            }
            if (effective.* != .primitive) return false;
            if (effective.primitive == prim) return true;
            if (effective.primitive == .integer) return isIntegerPrimitive(prim);
            if (effective.primitive == .float) return prim == .f32 or prim == .f64;
            return false;
        }
        if (effective.* == .user_defined) return std.mem.eql(u8, effective.user_defined.name, spelling);
        return false;
    }

    const OverloadCandidate = struct {
        member_key: []const u8,
        kind: enum { func_decl, imported, extern_contract },
        func: ?*ast.FuncDecl = null,
        imported_sig: ?FunctionSignature = null,
        ext: ?contract_parser.ExternalFunction = null,

        fn arity(self: OverloadCandidate) usize {
            return switch (self.kind) {
                .func_decl => self.func.?.params.len,
                .imported => self.imported_sig.?.params.len,
                .extern_contract => self.ext.?.params.len,
            };
        }

        fn isVariadic(self: OverloadCandidate) bool {
            return switch (self.kind) {
                .func_decl => self.func.?.is_variadic,
                .imported => self.imported_sig.?.is_variadic,
                .extern_contract => self.ext.?.is_variadic,
            };
        }

        /// The number of leading parameters a caller must supply. For
        /// a variadic member the trailing `...` accepts any number of
        /// additional arguments, so the member's arity is its fixed
        /// parameter count plus the variadic marker, not an exact
        /// count. A variadic definition's parameter list ends in the
        /// VaList parameter, which is not a call argument (mirrors
        /// checkCallArgsAgainstFunc).
        fn fixedArity(self: OverloadCandidate) usize {
            return switch (self.kind) {
                .func_decl => blk: {
                    const func = self.func.?;
                    if (func.is_variadic and func.params.len > 0) {
                        const last = func.params[func.params.len - 1];
                        if (last.ty.* == .primitive and last.ty.primitive == .va_list) {
                            break :blk func.params.len - 1;
                        }
                    }
                    break :blk func.params.len;
                },
                .imported => self.imported_sig.?.params.len,
                .extern_contract => self.ext.?.params.len,
            };
        }

        fn matches(self: OverloadCandidate, args: []const *ast.Node, arg_tys: []const *ast.Type) bool {
            // A variadic member matches any call at or above its
            // fixed arity; only the fixed prefix participates in
            // per-parameter matching. Trailing arguments are validated
            // by the winning member's real check, which applies the C
            // promotion rules (checkVariadicTrailingArg).
            if (self.isVariadic()) {
                if (args.len < self.fixedArity()) return false;
            } else if (self.arity() != args.len) return false;
            const n = self.fixedArity();
            switch (self.kind) {
                .func_decl => {
                    for (self.func.?.params[0..n], args[0..n], arg_tys[0..n]) |param, arg, arg_ty| {
                        if (!overloadParamMatches(param, arg, arg_ty)) return false;
                    }
                },
                .imported => {
                    for (self.imported_sig.?.params[0..n], args[0..n], arg_tys[0..n]) |param, arg, arg_ty| {
                        if (!overloadParamMatches(param, arg, arg_ty)) return false;
                    }
                },
                .extern_contract => {
                    for (self.ext.?.params[0..n], args[0..n], arg_tys[0..n]) |param, arg, arg_ty| {
                        if (param.is_move and arg.* != .move_expr) return false;
                        if (!contractParamMatches(param.ty, arg, arg_ty)) return false;
                    }
                },
            }
            return true;
        }
    };

    fn renderArgTypesShort(self: *TypeChecker, arg_tys: []const *ast.Type) ![]const u8 {
        var list = std.array_list.Managed(u8).init(self.allocator);
        for (arg_tys, 0..) |ty, i| {
            if (i > 0) try list.appendSlice(", ");
            try appendTypeShort(&list, ty);
        }
        return list.toOwnedSlice();
    }

    fn renderCandidateShort(self: *TypeChecker, display_name: []const u8, candidate: OverloadCandidate) ![]const u8 {
        var list = std.array_list.Managed(u8).init(self.allocator);
        try list.appendSlice(display_name);
        try list.append('(');
        switch (candidate.kind) {
            .func_decl => {
                const params = try self.renderParamsShort(candidate.func.?.params);
                defer self.allocator.free(params);
                try list.appendSlice(params);
                try list.appendSlice(") -> ");
                try appendTypeShort(&list, candidate.func.?.ret_ty);
            },
            .imported => {
                const params = try self.renderParamsShort(candidate.imported_sig.?.params);
                defer self.allocator.free(params);
                try list.appendSlice(params);
                try list.appendSlice(") -> ");
                try appendTypeShort(&list, candidate.imported_sig.?.ret_ty);
            },
            .extern_contract => {
                for (candidate.ext.?.params, 0..) |param, i| {
                    if (i > 0) try list.appendSlice(", ");
                    try list.appendSlice(std.mem.trim(u8, param.ty, " \t\r"));
                }
                try list.appendSlice(") -> ");
                try list.appendSlice(candidate.ext.?.ret_ty);
            },
        }
        return list.toOwnedSlice();
    }

    fn renderCandidateList(self: *TypeChecker, display_name: []const u8, candidates: []const OverloadCandidate) ![]const u8 {
        var list = std.array_list.Managed(u8).init(self.allocator);
        for (candidates, 0..) |candidate, i| {
            if (i > 0) try list.appendSlice("; ");
            const rendered = try self.renderCandidateShort(display_name, candidate);
            defer self.allocator.free(rendered);
            try list.appendSlice(rendered);
        }
        return list.toOwnedSlice();
    }

    /// The FFI argument validation shared by the legacy single-contract
    /// path and by overload winners: arguments are type-checked, closures
    /// are rejected for by-value pointer parameters (no trampoline
    /// address), move arguments are consumed per the contract, and the
    /// return type comes from the ABI return spelling.
    fn checkExternContractCall(self: *TypeChecker, ext: contract_parser.ExternalFunction, call: ast.CallExpr, scope: *Scope) TypeError!*ast.Type {
        if (ext.is_variadic) {
            if (call.args.len < ext.params.len) {
                self.setError("call to variadic function {s} needs at least {} arguments ({} fixed), got {}", .{ call.func_name, ext.params.len, ext.params.len, call.args.len });
                return TypeError.InvalidArgsCount;
            }
        } else if (ext.params.len != call.args.len) return TypeError.InvalidArgsCount;
        for (ext.params, call.args[0..ext.params.len]) |param, arg| {
            const arg_ty = try self.checkExpr(arg, scope);
            // bypass signature checks for FFI pointers
            // Fn values bound for a by-value pointer parameter
            // are materialized as callable machine addresses by
            // the emitters — except closures, which have no
            // trampoline address: invoking a closure needs its
            // capture pointer, which an arbitrary extern
            // `fn(ptr)` parameter cannot carry. A closure
            // argument's checked type is `.closure` (literals
            // and closure-typed bindings alike); reject it
            // explicitly instead of passing a wrong value.
            if (!param.is_borrow and !param.is_move and
                std.mem.eql(u8, std.mem.trim(u8, param.ty, " \t\r"), "ptr") and
                (arg_ty.* == .closure or (arg_ty.* == .fn_ptr and blk: {
                    const root = switch (arg.*) {
                        .move_expr => |mv| mv.expr,
                        else => arg,
                    };
                    break :blk root.* == .closure_literal;
                })))
            {
                self.setError("cannot pass a closure to extern parameter `{s}` of `{s}`: a closure has no callable trampoline address (its invocation needs the capture pointer); pass a top-level named function instead", .{ param.name, call.func_name });
                return TypeError.TypeMismatch;
            }
            try self.consumeExternMoveArg(scope, param, arg);
        }
        if (ext.is_variadic) {
            for (call.args[ext.params.len..]) |arg| {
                try self.checkVariadicTrailingArg(arg, scope, call.func_name);
            }
        }
        const ret = try self.allocator.create(ast.Type);
        setTypeFromAbiReturn(self.allocator, ret, ext.ret_ty);
        return ret;
    }

    /// Overload resolution entry point for plain (non-associated) calls.
    /// Returns null when no overload set exists for the name, leaving the
    /// legacy single-signature paths untouched. When a set exists (in any
    /// of the func / imported-signature / extern-contract sources),
    /// candidates from every source compete under exact-after-inference
    /// matching; singleton entries from other sources join the candidate
    /// pool so a name is never silently shadowed across sources.
    fn appendOverloadCandidateUnique(candidates: *std.array_list.Managed(OverloadCandidate), candidate: OverloadCandidate) !void {
        for (candidates.items) |existing| {
            if (std.mem.eql(u8, existing.member_key, candidate.member_key)) return;
        }
        try candidates.append(candidate);
    }

    fn tryResolveOverloadCall(self: *TypeChecker, expr: *ast.Node, call: ast.CallExpr, resolved_name: []const u8, module_local_name: ?[]const u8, scope: *Scope) TypeError!?*ast.Type {
        // Effective lookup name, extending the legacy precedence (a
        // module-local name shadows the plain name) to overload sets.
        var effective_name = resolved_name;
        if (module_local_name) |local_name| {
            if (self.func_overload_sets.contains(local_name) or self.imported_overload_sets.contains(local_name) or
                self.funcs.contains(local_name) or self.imported_function_signatures.contains(local_name))
            {
                effective_name = local_name;
            }
        }
        const func_set = self.func_overload_sets.get(effective_name);
        const imp_set = self.imported_overload_sets.get(effective_name);
        const ext_set = self.extern_overload_sets.get(call.func_name);
        if (func_set == null and imp_set == null and ext_set == null) return null;

        // The same member can be registered through several surfaces at
        // once (an imported .sla module's declarations are inlined into
        // this program AND registered as imported signatures); candidates
        // are deduped by member key, with body-carrying declarations
        // taking precedence by append order.
        var candidates = std.array_list.Managed(OverloadCandidate).init(self.allocator);
        defer candidates.deinit();
        if (func_set) |set| {
            for (set.items) |func| {
                try appendOverloadCandidateUnique(&candidates, .{ .member_key = func.name, .kind = .func_decl, .func = func });
            }
        } else if (self.funcs.get(effective_name)) |func| {
            try appendOverloadCandidateUnique(&candidates, .{ .member_key = effective_name, .kind = .func_decl, .func = func });
        }
        if (imp_set) |set| {
            for (set.items) |member_key| {
                if (self.imported_overload_members.get(member_key)) |sig| {
                    try appendOverloadCandidateUnique(&candidates, .{ .member_key = member_key, .kind = .imported, .imported_sig = sig });
                }
            }
        } else if (self.imported_function_signatures.get(effective_name)) |sig| {
            try appendOverloadCandidateUnique(&candidates, .{ .member_key = effective_name, .kind = .imported, .imported_sig = sig });
        }
        if (ext_set) |set| {
            for (set.items) |ext| {
                try appendOverloadCandidateUnique(&candidates, .{ .member_key = try self.externMemberKey(ext), .kind = .extern_contract, .ext = ext });
            }
        } else if (self.extern_funcs.get(call.func_name)) |ext| {
            try appendOverloadCandidateUnique(&candidates, .{ .member_key = call.func_name, .kind = .extern_contract, .ext = ext });
        }

        // Probe argument types under a scope-state snapshot, then roll
        // back: the winning candidate's real validation below re-checks
        // (and consumes) from the restored state.
        var winners = std.array_list.Managed(OverloadCandidate).init(self.allocator);
        defer winners.deinit();
        var arg_tys = std.array_list.Managed(*ast.Type).init(self.allocator);
        defer arg_tys.deinit();
        {
            const marks = try self.snapshotOverloadProbeStates(scope);
            defer {
                self.restoreOverloadProbeStates(marks);
                marks.deinit();
            }
            for (call.args) |arg| {
                try arg_tys.append(try self.checkExpr(arg, scope));
            }
            for (candidates.items) |candidate| {
                if (candidate.matches(call.args, arg_tys.items)) try winners.append(candidate);
            }
        }

        if (winners.items.len == 0) {
            const arg_desc = try self.renderArgTypesShort(arg_tys.items);
            defer self.allocator.free(arg_desc);
            const cand_desc = try self.renderCandidateList(call.func_name, candidates.items);
            defer self.allocator.free(cand_desc);
            self.setError("no overload of `{s}` matches the argument types ({s}); candidates: {s}", .{ call.func_name, arg_desc, cand_desc });
            return TypeError.TypeMismatch;
        }
        if (winners.items.len > 1) {
            const cand_desc = try self.renderCandidateList(call.func_name, winners.items);
            defer self.allocator.free(cand_desc);
            self.setError("AmbiguousCall: call to `{s}` matches multiple overloads: {s}", .{ call.func_name, cand_desc });
            return TypeError.AmbiguousCall;
        }

        const winner = winners.items[0];
        switch (winner.kind) {
            .func_decl => {
                const func = winner.func.?;
                try self.checkCallArgsAgainstFunc(func, call.args, scope, call.func_name, false);
                self.resolved_call_symbols.put(expr, winner.member_key) catch return TypeError.OutOfMemory;
                if (func.is_async) return try self.makeFutureType(func.ret_ty);
                return func.ret_ty;
            },
            .imported => {
                const sig = winner.imported_sig.?;
                try self.checkCallArgsAgainstSignature(sig.params, call.args, scope, call.func_name, false, sig.is_variadic);
                self.resolved_call_symbols.put(expr, winner.member_key) catch return TypeError.OutOfMemory;
                if (sig.is_async) return try self.makeFutureType(sig.ret_ty);
                return sig.ret_ty;
            },
            .extern_contract => {
                const ret = try self.checkExternContractCall(winner.ext.?, call, scope);
                self.resolved_call_symbols.put(expr, winner.member_key) catch return TypeError.OutOfMemory;
                return ret;
            },
        }
    }

    /// Goroutine syntax batch (DESIGN section 1): whether a type may
    /// cross a goroutine boundary as a spawn argument / channel
    /// payload component. Borrows dangle into the spawner frame,
    /// closures capture that frame by reference, and futures are
    /// bound to an executor; all three are rejected. Raw pointers
    /// are the sanctioned transfer mechanism (Box) and are followed
    /// so a pointer to a borrow-carrying struct is still caught.
    pub fn typeForbiddenAcrossBoundary(self: *TypeChecker, ty: *ast.Type, depth: usize) bool {
        if (depth > 8) return false;
        switch (ty.*) {
            .borrow, .closure, .future => return true,
            .pointer => |inner| return self.typeForbiddenAcrossBoundary(inner, depth + 1),
            .array => |arr| return self.typeForbiddenAcrossBoundary(arr.elem, depth + 1),
            .tuple => |tup| {
                for (tup.elems) |elem| if (self.typeForbiddenAcrossBoundary(elem, depth + 1)) return true;
                return false;
            },
            .user_defined => |ud| {
                if (self.structs.get(ud.name)) |decl| {
                    for (decl.fields) |field| if (self.typeForbiddenAcrossBoundary(field.ty, depth + 1)) return true;
                }
                return false;
            },
            else => return false,
        }
    }

    /// The goroutine entry receives exactly one word: pointer,
    /// word-sized scalar, function pointer, or a Chan handle.
    fn goParamIsWordOrPtr(ty: *ast.Type) bool {
        switch (ty.*) {
            .primitive => |prim| return prim != .void_type,
            .pointer, .fn_ptr => return true,
            .user_defined => |ud| return std.mem.eql(u8, ud.name, "Chan"),
            else => return false,
        }
    }

    fn checkGoExpr(self: *TypeChecker, expr: *ast.Node, go: ast.GoExpr, scope: *Scope) TypeError!*ast.Type {
        const call_node = go.call;
        if (call_node.* != .call_expr) return TypeError.CompileError;
        const call = call_node.call_expr;
        if (call.callee != null) {
            self.setError("go: closure literals cannot be spawned in this batch; name the function or pass a function value", .{});
            return TypeError.TypeMismatch;
        }
        if (call.associated_target != null) {
            self.setError("go: associated-function callees cannot be spawned; use a free function", .{});
            return TypeError.TypeMismatch;
        }
        var params: []const *ast.Type = &.{};
        var ret_ty: *ast.Type = undefined;
        var is_async = false;
        var entry_ty: *ast.Type = undefined;
        if (scope.lookup(call.func_name)) |sym| {
            switch (sym.ty.*) {
                .fn_ptr => |fp| {
                    params = fp.params;
                    ret_ty = fp.ret;
                    entry_ty = sym.ty;
                },
                .closure => {
                    self.setError("go: closure values cannot be spawned in this batch (the captured environment points into the spawner frame); use a named function and pass state explicitly", .{});
                    return TypeError.TypeMismatch;
                },
                else => {
                    self.setError("go: callee `{s}` is not a function value", .{call.func_name});
                    return TypeError.TypeMismatch;
                },
            }
        } else if (self.func_overload_sets.get(call.func_name)) |set| {
            // Goroutine entry resolution over an overload set: the member
            // must be unique at the call's arity (the entry signature is
            // fixed before the call itself is checked); the subsequent
            // checkExpr of the call runs full overload resolution.
            var found: ?*ast.FuncDecl = null;
            for (set.items) |func| {
                if (func.params.len != call.args.len) continue;
                if (found != null) {
                    self.setError("go: callee `{s}` is an overload set with several members taking {} argument(s); the spawn entry cannot choose between them - wrap the intended member in a named function", .{ call.func_name, call.args.len });
                    return TypeError.AmbiguousCall;
                }
                found = func;
            }
            const decl = found orelse {
                self.setError("go: callee `{s}` does not resolve to a free function taking {} argument(s) (method callees are not supported in this batch)", .{ call.func_name, call.args.len });
                return TypeError.TypeMismatch;
            };
            if (decl.is_extern) {
                self.setError("go: extern functions cannot be spawned; wrap the extern in an SLA function", .{});
                return TypeError.TypeMismatch;
            }
            var ps = std.array_list.Managed(*ast.Type).init(self.allocator);
            for (decl.params) |param| try ps.append(param.ty);
            params = try ps.toOwnedSlice();
            ret_ty = decl.ret_ty;
            is_async = decl.is_async;
            entry_ty = try self.makeFnPtrType(decl.abi, params, ret_ty);
        } else if (self.funcs.get(call.func_name)) |decl| {
            if (decl.is_extern) {
                self.setError("go: extern functions cannot be spawned; wrap the extern in an SLA function", .{});
                return TypeError.TypeMismatch;
            }
            if (decl.params.len != call.args.len) {
                self.setError("go: callee `{s}` does not resolve to a free function taking {} argument(s) (method callees are not supported in this batch)", .{ call.func_name, call.args.len });
                return TypeError.TypeMismatch;
            }
            var ps = std.array_list.Managed(*ast.Type).init(self.allocator);
            for (decl.params) |param| try ps.append(param.ty);
            params = try ps.toOwnedSlice();
            ret_ty = decl.ret_ty;
            is_async = decl.is_async;
            entry_ty = try self.makeFnPtrType(decl.abi, params, ret_ty);
        } else if (self.imported_function_signatures.get(call.func_name)) |sig| {
            if (sig.params.len != call.args.len) {
                self.setError("go: callee `{s}` does not resolve to a free function taking {} argument(s) (method callees are not supported in this batch)", .{ call.func_name, call.args.len });
                return TypeError.TypeMismatch;
            }
            var ps = std.array_list.Managed(*ast.Type).init(self.allocator);
            for (sig.params) |param| try ps.append(param.ty);
            params = try ps.toOwnedSlice();
            ret_ty = sig.ret_ty;
            is_async = sig.is_async;
            entry_ty = try self.makeFnPtrType(null, params, ret_ty);
        } else {
            self.setError("go: callee `{s}` does not resolve to a free function or function value (method callees are not supported in this batch)", .{call.func_name});
            return TypeError.UndefinedVariable;
        }
        // Ordinary call checking: argument types and ownership
        // consumption at the spawn point.
        _ = try self.checkExpr(call_node, scope);
        if (is_async) {
            self.setError("go: async function `{s}` cannot be spawned (goroutines run synchronous functions); drive it with a block_on wrapper in a synchronous function", .{call.func_name});
            return TypeError.TypeMismatch;
        }
        if (!lowering_rules.isVoidType(ret_ty)) {
            self.setError("go: spawned function `{s}` must return void (the goroutine entry discards results); wrap it if you need the value", .{call.func_name});
            return TypeError.TypeMismatch;
        }
        if (params.len > 1) {
            self.setError("go: spawned function `{s}` takes {} parameters; the goroutine entry convention is fn(ptr) - wrap the arguments in a heap struct (Box) and pass its pointer", .{ call.func_name, params.len });
            return TypeError.TypeMismatch;
        }
        if (params.len == 1) {
            if (params[0].* == .borrow) {
                self.setError("go: spawned function `{s}` takes a borrowed parameter, which would dangle across the goroutine boundary; pass an owned value or a raw pointer instead", .{call.func_name});
                return TypeError.TypeMismatch;
            }
            if (!goParamIsWordOrPtr(params[0])) {
                self.setError("go: parameter of spawned function `{s}` must be a pointer or word-sized scalar (the entry receives one word); box larger values and pass the pointer", .{call.func_name});
                return TypeError.TypeMismatch;
            }
            const arg_ty = self.expr_types.get(call.args[0]) orelse return TypeError.CompileError;
            if (self.typeForbiddenAcrossBoundary(arg_ty, 0)) {
                self.setError("go: argument cannot cross a goroutine boundary (borrow, closure, and future values would dangle or pin an executor); move an owned value, box it, or share through a channel/global cell", .{});
                return TypeError.TypeMismatch;
            }
        }
        try self.go_entry_types.put(expr, entry_ty);
        return try self.makeU64Type();
    }

    /// Goroutine syntax batch (channels): if `ty` is a Chan<T> type
    /// (possibly behind a borrow/pointer peel), return the payload
    /// type T.
    pub fn chanPayloadTypeOf(ty: *ast.Type) ?*ast.Type {
        const peeled = lowering_rules.peelBorrowPointerType(ty);
        if (peeled.* != .user_defined) return null;
        if (!std.mem.eql(u8, peeled.user_defined.name, "Chan")) return null;
        if (peeled.user_defined.generics.len != 1) return null;
        return peeled.user_defined.generics[0];
    }

    pub fn makeChanType(self: *TypeChecker, payload_ty: *ast.Type) TypeError!*ast.Type {
        const generics = try self.allocator.alloc(*ast.Type, 1);
        generics[0] = payload_ty;
        const ty = try self.allocator.create(ast.Type);
        ty.* = .{ .user_defined = .{ .name = "Chan", .generics = generics } };
        return ty;
    }

    fn makeVoidType(self: *TypeChecker) TypeError!*ast.Type {
        const ty = try self.allocator.create(ast.Type);
        ty.* = .{ .primitive = .void_type };
        return ty;
    }

    /// Byte size of a value's storage at its address, following the
    /// shared ABI layout rules: scalars at their natural size, every
    /// user-defined value one handle word, tuples/arrays/structs by
    /// the aggregate layouts in lowering_rules. Null when the size
    /// cannot be determined (borrow/closure/future/infer payloads).
    pub fn payloadStorageSize(self: *TypeChecker, ty: *ast.Type) ?usize {
        switch (ty.*) {
            .primitive => |prim| return switch (prim) {
                .boolean, .u8, .i8 => 1,
                .u16, .i16 => 2,
                .u32, .i32, .f32 => 4,
                .u64, .i64, .usize, .isize, .f64, .integer, .float, .raw_ptr => 8,
                .va_list => 8,
                .void_type => null,
            },
            .pointer, .fn_ptr => return 8,
            .tuple => |tup| return lowering_rules.tupleAbiSize(tup),
            .array => |arr| {
                if (self.payloadStorageSize(arr.elem) == null) return null;
                return lowering_rules.inlineArraySize(arr);
            },
            .user_defined => |ud| {
                if (self.structs.get(ud.name)) |decl| return lowering_rules.structAbiSize(decl);
                // Builtin handle types with no struct declaration
                // (String, Vec, Chan, Box, ...): the transferred
                // value is the head word itself (8) — the heap
                // head it points to changes ownership with the
                // word (DESIGN section 2, C3).
                if (self.enums.get(ud.name)) |decl| {
                    var max_span: usize = 0;
                    for (decl.variants) |variant| {
                        var elems = std.array_list.Managed(*ast.Type).init(self.allocator);
                        defer elems.deinit();
                        for (variant.fields) |field| elems.append(field.ty) catch return null;
                        const span = lowering_rules.tupleAbiSize(.{ .elems = elems.items });
                        if (span > max_span) max_span = span;
                    }
                    return 8 + max_span;
                }
                return 8;
            },
            else => return null,
        }
    }

    /// Channel payload rules C1/C2 (DESIGN section 2): the payload
    /// must fit the runtime's fixed 16-byte slot under the ABI
    /// storage model, and must not carry borrows, closures, or
    /// futures across the goroutine boundary.
    pub fn validateChanPayload(self: *TypeChecker, payload_ty: *ast.Type, context: []const u8) TypeError!usize {
        if (self.typeForbiddenAcrossBoundary(payload_ty, 0)) {
            self.setError("{s}: channel payload cannot cross a goroutine boundary (borrow, closure, and future values would dangle or pin an executor); move an owned value, box it, or share through a global cell", .{context});
            return TypeError.TypeMismatch;
        }
        const size = self.payloadStorageSize(payload_ty) orelse {
            self.setError("{s}: channel payload type {s} has no fixed storage size", .{ context, typeDesc(payload_ty) });
            return TypeError.TypeMismatch;
        };
        if (size == 0 or size > 16) {
            self.setError("{s}: channel payload type {s} occupies {} bytes; channel slots hold at most 16 bytes - box larger values and send the pointer", .{ context, typeDesc(payload_ty), size });
            return TypeError.TypeMismatch;
        }
        return size;
    }

    /// Intrinsic Chan method dispatch. The receiver has already been
    /// checked by the caller (recv_node_ty flow). Returns null when
    /// the name is not a channel operation.
    fn checkChanMethodCall(self: *TypeChecker, expr: *ast.Node, call: ast.CallExpr, payload_ty: *ast.Type, scope: *Scope) TypeError!?*ast.Type {
        const kind: ChanCallKind = if (std.mem.eql(u8, call.func_name, "send"))
            .send
        else if (std.mem.eql(u8, call.func_name, "recv"))
            .recv
        else if (std.mem.eql(u8, call.func_name, "close"))
            .close
        else if (std.mem.eql(u8, call.func_name, "destroy"))
            .destroy
        else if (std.mem.eql(u8, call.func_name, "len"))
            .len
        else if (std.mem.eql(u8, call.func_name, "cap"))
            .cap
        else
            return null;
        // Effect rule R2: send/recv are blocking operations; used
        // directly in an async function body they would park the
        // executor. Non-blocking alternatives (select with a
        // default/timeout) and the non-blocking ops stay legal.
        if (self.current_fn_is_async and (kind == .send or kind == .recv)) {
            self.setError("async: blocking channel {s} directly inside async function `{s}` is forbidden (it would park the executor); use a select with default/timeout, or move the channel work into a synchronous goroutine", .{ call.func_name, self.current_function_name orelse "?" });
            return TypeError.TypeMismatch;
        }
        switch (kind) {
            .send => {
                if (call.args.len != 2) return TypeError.InvalidArgsCount;
                _ = try self.validateChanPayload(payload_ty, "send");
                const arg_ty = try self.checkExpr(call.args[1], scope);
                if (!self.plainCallArgMatches(payload_ty, call.args[1], arg_ty)) {
                    self.setError("send: payload type mismatch: channel holds {s}", .{typeDesc(payload_ty)});
                    return TypeError.TypeMismatch;
                }
                const param = ast.Param{ .name = "value", .ty = payload_ty, .is_borrow = false, .is_move = false };
                try self.consumeCallArgIfMoved(scope, param, call.args[1], arg_ty, "send");
                try self.chan_calls.put(expr, .{ .kind = .send, .payload_ty = payload_ty });
                return try self.makeVoidType();
            },
            .recv => {
                if (call.args.len != 1) return TypeError.InvalidArgsCount;
                _ = try self.validateChanPayload(payload_ty, "recv");
                try self.chan_calls.put(expr, .{ .kind = .recv, .payload_ty = payload_ty });
                return try self.makeTupleType(&.{ payload_ty, try self.makeBoolType() });
            },
            .close, .destroy => {
                if (call.args.len != 1) return TypeError.InvalidArgsCount;
                _ = try self.validateChanPayload(payload_ty, call.func_name);
                try self.chan_calls.put(expr, .{ .kind = kind, .payload_ty = payload_ty });
                return try self.makeVoidType();
            },
            .len, .cap => {
                if (call.args.len != 1) return TypeError.InvalidArgsCount;
                try self.chan_calls.put(expr, .{ .kind = kind, .payload_ty = payload_ty });
                return try self.makeU64Type();
            },
            .new => unreachable,
        }
    }

    /// Chan::new intrinsic (associated form). The payload type comes
    /// from the let's Chan<T> annotation via chan_new_pending; an
    /// unannotated creation is recorded and rejected at the end of
    /// checkProgram.
    fn checkChanNewCall(self: *TypeChecker, expr: *ast.Node, call: ast.CallExpr, scope: *Scope) TypeError!*ast.Type {
        if (call.args.len != 1) return TypeError.InvalidArgsCount;
        if (call.generics.len != 0) return TypeError.InvalidArgsCount;
        const cap_ty = try self.checkExpr(call.args[0], scope);
        if (!isNumericType(cap_ty)) {
            self.setError("Chan::new: capacity must be an integer", .{});
            return TypeError.TypeMismatch;
        }
        try self.chan_new_seen.put(expr, {});
        if (self.chan_new_pending.get(expr)) |payload_ty| {
            try self.chan_calls.put(expr, .{ .kind = .new, .payload_ty = payload_ty });
            return try self.makeChanType(payload_ty);
        }
        const infer_ty = try self.makeInferType();
        try self.chan_calls.put(expr, .{ .kind = .new, .payload_ty = infer_ty });
        return try self.makeChanType(infer_ty);
    }

    /// Goroutine syntax batch: select statement validation. Case
    /// calls are validated here (not through checkExpr) because the
    /// operations must not execute at the select statement itself;
    /// their arguments are checked for types and ownership, and the
    /// intrinsic record is stored for the lowering.
    fn checkSelectStmt(self: *TypeChecker, sel: ast.SelectStmt, scope: *Scope, ret_ty: *ast.Type, current_loop_scope: ?*Scope) TypeError!void {
        if (sel.cases.len == 0) {
            self.setError("select requires at least one case", .{});
            return TypeError.TypeMismatch;
        }
        if (sel.default_body != null and sel.timeout_expr != null) {
            self.setError("select cannot have both a default case and a timeout case", .{});
            return TypeError.TypeMismatch;
        }
        if (self.current_fn_is_async and sel.default_body == null and sel.timeout_expr == null) {
            self.setError("async: blocking select (no default or timeout case) directly inside async function `{s}` is forbidden (it would park the executor)", .{self.current_function_name orelse "?"});
            return TypeError.TypeMismatch;
        }
        for (sel.cases) |case| {
            if (case.call.* != .call_expr) return TypeError.CompileError;
            const call = case.call.call_expr;
            if (call.args.len == 0) return TypeError.CompileError;
            const recv_ty = try self.checkExpr(call.args[0], scope);
            const payload_ty = chanPayloadTypeOf(recv_ty) orelse {
                self.setError("select case: receiver is not a Chan<T>", .{});
                return TypeError.TypeMismatch;
            };
            _ = try self.validateChanPayload(payload_ty, "select");
            const case_scope = try Scope.init(self.allocator, scope);
            try self.scope_pool.append(case_scope);
            switch (case.kind) {
                .recv => {
                    if (call.args.len != 1) return TypeError.InvalidArgsCount;
                    try self.chan_calls.put(case.call, .{ .kind = .recv, .payload_ty = payload_ty });
                    if (case.bind_name) |bind_name| {
                        try self.defineSymbol(case_scope, bind_name, payload_ty, false);
                    }
                    if (case.bind_closed) |bind_closed| {
                        try self.defineSymbol(case_scope, bind_closed, try self.makeBoolType(), false);
                    }
                },
                .send => {
                    if (call.args.len != 2) return TypeError.InvalidArgsCount;
                    const arg_ty = try self.checkExpr(call.args[1], scope);
                    if (!self.plainCallArgMatches(payload_ty, call.args[1], arg_ty)) {
                        self.setError("select send case: payload type mismatch: channel holds {s}", .{typeDesc(payload_ty)});
                        return TypeError.TypeMismatch;
                    }
                    const param = ast.Param{ .name = "value", .ty = payload_ty, .is_borrow = false, .is_move = false };
                    try self.consumeCallArgIfMoved(scope, param, call.args[1], arg_ty, "select send");
                    try self.chan_calls.put(case.call, .{ .kind = .send, .payload_ty = payload_ty });
                },
            }
            try self.checkBlock(case.body, case_scope, ret_ty, null, current_loop_scope);
        }
        if (sel.timeout_expr) |timeout_expr| {
            const timeout_ty = try self.checkExpr(timeout_expr, scope);
            if (!isNumericType(timeout_ty)) {
                self.setError("select timeout must be an integer nanosecond count", .{});
                return TypeError.TypeMismatch;
            }
        }
        if (sel.default_body) |default_body| {
            const default_scope = try Scope.init(self.allocator, scope);
            try self.scope_pool.append(default_scope);
            try self.checkBlock(default_body, default_scope, ret_ty, null, current_loop_scope);
        }
        if (sel.timeout_body) |timeout_body| {
            const timeout_scope = try Scope.init(self.allocator, scope);
            try self.scope_pool.append(timeout_scope);
            try self.checkBlock(timeout_body, timeout_scope, ret_ty, null, current_loop_scope);
        }
    }

    fn receiverParamMatches(self: *TypeChecker, param: ast.Param, recv_ty: *ast.Type) bool {
        const recv = unwrappedReceiverType(recv_ty);
        if (param.is_borrow) return self.typesEqual(param.ty, recv);
        return self.typesEqual(param.ty, recv_ty) or self.typesEqual(param.ty, recv);
    }

    fn checkCallArgsAgainstFunc(
        self: *TypeChecker,
        func: *ast.FuncDecl,
        args: []const *ast.Node,
        scope: *Scope,
        call_name: []const u8,
        auto_borrow_receiver: bool,
    ) TypeError!void {
        // A variadic definition's parameter list ends in the VaList
        // parameter, which is not a call argument: callers supply the
        // fixed parameters plus trailing promoted arguments.
        var params = func.params;
        if (func.is_variadic and params.len > 0) {
            const last = params[params.len - 1];
            if (last.ty.* == .primitive and last.ty.primitive == .va_list) {
                params = params[0 .. params.len - 1];
            }
        }
        try self.checkCallArgsAgainstSignature(params, args, scope, call_name, auto_borrow_receiver, func.is_variadic);
    }

    /// Extern variadic batch: the C default argument promotion for one
    /// trailing argument, or null when the argument's type may not pass
    /// through `...` at all. Follows C11 6.5.2.2/6.3.1.1 exactly: integer
    /// types narrower than int promote to int (u8/u16 included - int
    /// represents all their values), float promotes to double.
    fn variadicPromotedType(self: *TypeChecker, arg: *const ast.Node, arg_ty: *ast.Type) TypeError!?*ast.Type {
        switch (arg_ty.*) {
            .primitive => |prim| {
                return switch (prim) {
                    .i8, .i16, .u8, .u16 => try self.makeI32Type(),
                    .f32 => try self.makeF64Type(),
                    .integer => blk: {
                        // Unannotated integer literal: int when it fits,
                        // long otherwise (C literal-through-varargs rule).
                        if (arg.* == .literal and arg.literal == .int_val) {
                            const v = arg.literal.int_val;
                            break :blk if (v >= std.math.minInt(i32) and v <= std.math.maxInt(i32)) try self.makeI32Type() else try self.makeI64Type();
                        }
                        break :blk try self.makeI64Type();
                    },
                    .float => try self.makeF64Type(),
                    .i32, .u32, .i64, .u64, .isize, .usize, .f64, .raw_ptr => arg_ty,
                    else => null,
                };
            },
            .pointer => return arg_ty,
            else => return null,
        }
    }

    /// Extern variadic batch: validate one trailing argument of a call
    /// to a variadic extern and record its promoted type for codegen.
    fn checkVariadicTrailingArg(
        self: *TypeChecker,
        arg: *ast.Node,
        scope: *Scope,
        call_name: []const u8,
    ) TypeError!void {
        if (arg.* == .move_expr or arg.* == .borrow_expr) {
            self.setError("variadic argument to {s} must be a plain scalar or raw pointer value; borrows and moves may not pass through `...`", .{call_name});
            return TypeError.TypeMismatch;
        }
        const arg_ty = try self.checkExpr(arg, scope);
        const promoted = (try self.variadicPromotedType(arg, arg_ty)) orelse {
            self.setError("variadic argument to {s} has type {s}, which may not pass through `...`: only scalars and raw pointers are allowed (aggregates, String/Vec handles, borrows and owned values are rejected; pass a raw *u8 for C strings)", .{ call_name, typeDesc(arg_ty) });
            return TypeError.TypeMismatch;
        };
        self.variadic_promotions.put(arg, promoted) catch return TypeError.OutOfMemory;
    }

    fn checkCallArgsAgainstSignature(
        self: *TypeChecker,
        params: []const ast.Param,
        args: []const *ast.Node,
        scope: *Scope,
        call_name: []const u8,
        auto_borrow_receiver: bool,
        is_variadic: bool,
    ) TypeError!void {
        if (is_variadic) {
            if (args.len < params.len) {
                self.setError("call to variadic function {s} needs at least {} arguments ({} fixed), got {}", .{ call_name, params.len, params.len, args.len });
                return TypeError.InvalidArgsCount;
            }
        } else if (params.len != args.len) return TypeError.InvalidArgsCount;
        const fixed_count = if (is_variadic) params.len else args.len;
        // View-types stage 1: pairwise field-place overlap validation
        // for this call's arguments (runs before per-arg checking so
        // overlapping borrows are reported as borrow conflicts).
        try self.checkCallArgPlaceOverlaps(params, args[0..fixed_count], scope, call_name, self.funcs.get(call_name), 0);
        for (params, args[0..fixed_count], 0..) |param, arg, i| {
            if (param.is_move and arg.* != .move_expr) return TypeError.TypeMismatch;
            if (param.is_borrow) {
                if (dynTraitName(param.ty)) |trait_name| {
                    const arg_ty = try self.checkExpr(arg, scope);
                    if (dynDispatchTraitName(arg_ty)) |arg_trait_name| {
                        if (!self.traitExtendsTrait(arg_trait_name, trait_name)) return TypeError.TypeMismatch;
                        continue;
                    }
                    const concrete_ty = switch (arg_ty.*) {
                        .borrow => |inner| inner,
                        else => null,
                    } orelse return TypeError.TypeMismatch;
                    if (!self.typeImplementsTrait(concrete_ty, trait_name)) return TypeError.TypeMismatch;
                    self.dyn_borrow_args.put(arg, trait_name) catch return TypeError.OutOfMemory;
                    continue;
                }
            }
            if (auto_borrow_receiver and i == 0 and param.is_borrow and arg.* != .borrow_expr) {
                const arg_ty = try self.checkExpr(arg, scope);
                const effective_ty = switch (arg_ty.*) {
                    .borrow => |inner| inner,
                    else => unwrapBorrowForCallArg(arg, arg_ty),
                };
                if (dynTraitName(param.ty)) |target_trait| {
                    if (dynDispatchTraitName(effective_ty)) |arg_trait_name| {
                        if (!self.traitExtendsTrait(arg_trait_name, target_trait)) return TypeError.TypeMismatch;
                        continue;
                    }
                }
                if (!self.typesEqual(param.ty, effective_ty)) return TypeError.TypeMismatch;
                continue;
            }
            if (param.ty.* == .borrow) {
                const arg_ty = try self.checkExpr(arg, scope);
                if (canCoerceBorrowArrayToBorrowSlice(self, param.ty, arg_ty)) {
                    self.array_to_slice_borrow_args.put(arg, {}) catch return TypeError.OutOfMemory;
                    continue;
                }
                if (arg_ty.* != .borrow or !self.typesEqual(param.ty.borrow, arg_ty.borrow)) return TypeError.TypeMismatch;
                continue;
            }
            if (param.is_borrow and arg.* != .borrow_expr) {
                const arg_ty = try self.checkExpr(arg, scope);
                if (arg_ty.* != .borrow or !self.typesEqual(param.ty, arg_ty.borrow)) return TypeError.TypeMismatch;
                continue;
            }
            if (!param.is_move and !param.is_borrow and
                (arg.* == .move_expr or (arg.* == .borrow_expr and param.ty.* != .pointer)))
            {
                self.setError("Call to {s} passes capability argument to plain parameter {s}", .{ call_name, param.name });
                return TypeError.TypeMismatch;
            }
            const arg_ty = try self.checkExpr(arg, scope);
            if (!self.plainCallArgMatches(param.ty, arg, arg_ty)) return TypeError.TypeMismatch;
            // #1: reject silent integer-width array mismatches ([i64;N] vs [i32;N]).
            if (!self.arrayCallArgStrictMatches(param.ty, arg_ty)) {
                self.setError("TypeMismatch in call to {s}: array element type mismatch (param {s} vs arg {s}, stride differs)", .{ call_name, typeDesc(param.ty), typeDesc(arg_ty) });
                return TypeError.TypeMismatch;
            }
            if ((arg.* == .tuple_literal or arg.* == .array_literal) and
                self.typesEqual(arg_ty, param.ty))
            {
                self.expr_types.put(arg, param.ty) catch return TypeError.OutOfMemory;
            }
            // REG-BR-6: a plain by-value argument of a non-Copy owned type
            // moves the binding at the SA level. Record that consumption
            // here so a second use is diagnosed by the checker (naming the
            // variable and this call) instead of reaching the SA referee.
            try self.consumeCallArgIfMoved(scope, param, arg, arg_ty, call_name);
        }
        if (is_variadic) {
            for (args[fixed_count..]) |arg| {
                try self.checkVariadicTrailingArg(arg, scope, call_name);
            }
        }
    }

    fn checkStaticCallBySymbol(
        self: *TypeChecker,
        expr: *ast.Node,
        symbol: []const u8,
        args: []const *ast.Node,
        scope: *Scope,
        call_name: []const u8,
        auto_borrow_receiver: bool,
    ) TypeError!?*ast.Type {
        if (self.funcs.get(symbol)) |func| {
            try self.checkCallArgsAgainstFunc(func, args, scope, call_name, auto_borrow_receiver);
            self.resolved_call_symbols.put(expr, symbol) catch return TypeError.OutOfMemory;
            if (func.is_async) return try self.makeFutureType(func.ret_ty);
            return func.ret_ty;
        }
        if (self.imported_function_signatures.get(symbol)) |signature| {
            try self.checkCallArgsAgainstSignature(signature.params, args, scope, call_name, auto_borrow_receiver, signature.is_variadic);
            self.resolved_call_symbols.put(expr, symbol) catch return TypeError.OutOfMemory;
            if (signature.is_async) return try self.makeFutureType(signature.ret_ty);
            return signature.ret_ty;
        }
        return null;
    }

    fn protocolIterableElementType(self: *TypeChecker, ty: *ast.Type) ?*ast.Type {
        const len_func = self.methodForType(ty, "iter_len") orelse return null;
        const at_func = self.methodForType(ty, "iter_at") orelse return null;
        if (len_func.params.len != 1 or at_func.params.len != 2) return null;
        if (!self.receiverParamMatches(len_func.params[0], ty)) return null;
        if (!self.receiverParamMatches(at_func.params[0], ty)) return null;
        if (!isNumericType(len_func.ret_ty)) return null;
        if (!isNumericType(at_func.params[1].ty)) return null;
        return at_func.ret_ty;
    }

    fn unwrapBorrowForCallArg(arg: *const ast.Node, arg_ty: *ast.Type) *ast.Type {
        if (arg.* == .borrow_expr and arg_ty.* == .borrow) return arg_ty.borrow;
        return arg_ty;
    }

    fn plainCallArgMatches(self: *TypeChecker, param_ty: *const ast.Type, arg: *const ast.Node, arg_ty: *ast.Type) bool {
        if (self.typesEqual(@constCast(param_ty), unwrapBorrowForCallArg(arg, arg_ty))) return true;
        if (arg.* == .literal and arg.literal == .string_val and isStringType(param_ty)) return true;
        if (arg.* == .borrow_expr and arg_ty.* == .borrow and canCoerceBorrowArrayToBorrowSlice(self, @constCast(param_ty), arg_ty)) {
            self.array_to_slice_borrow_args.put(@constCast(arg), {}) catch return false;
            return true;
        }
        if (arg.* != .borrow_expr or arg_ty.* != .borrow) return false;
        return switch (param_ty.*) {
            .pointer => |inner| self.typesEqual(inner, arg_ty.borrow),
            else => false,
        };
    }

    /// #1: array element width must match exactly (stride safety).
    /// `typesEqual` is intentionally permissive across integer widths
    /// (i32 vs i64), but `[i64;N]` storage (8B stride) read as `[i32;N]`
    /// (4B stride) yields silent wrong values on the SA-text backend.
    /// Generic `.integer`/`.float` still matches any width.
    fn arrayElemStrictEqual(self: *TypeChecker, param_elem: *const ast.Type, arg_elem: *const ast.Type) bool {
        if (param_elem.* == .primitive and arg_elem.* == .primitive) {
            const pa = param_elem.primitive;
            const pb = arg_elem.primitive;
            if (pa == pb) return true;
            if (pa == .integer) return isAnyIntegerType(arg_elem);
            if (pb == .integer) return isAnyIntegerType(param_elem);
            if (pa == .float) return isAnyFloatType(arg_elem);
            if (pb == .float) return isAnyFloatType(param_elem);
            return false;
        }
        if (param_elem.* == .array and arg_elem.* == .array) {
            if (param_elem.array.len != arg_elem.array.len) return false;
            return self.arrayElemStrictEqual(param_elem.array.elem, arg_elem.array.elem);
        }
        if (param_elem.* == .tuple and arg_elem.* == .tuple) {
            if (param_elem.tuple.elems.len != arg_elem.tuple.elems.len) return false;
            for (param_elem.tuple.elems, arg_elem.tuple.elems) |pe, ae| {
                if (!self.arrayElemStrictEqual(pe, ae)) return false;
            }
            return true;
        }
        return self.typesEqual(@constCast(param_elem), @constCast(arg_elem));
    }

    fn arrayCallArgStrictMatches(self: *TypeChecker, param_ty: *const ast.Type, arg_ty: *ast.Type) bool {
        const p_arr = if (param_ty.* == .array) param_ty.array else return true;
        const a_arr = if (arg_ty.* == .array) arg_ty.array else return true;
        if (p_arr.len != a_arr.len) return false;
        return self.arrayElemStrictEqual(p_arr.elem, a_arr.elem);
    }

    fn isNumericType(ty: *const ast.Type) bool {
        return lowering_rules.isNumericType(ty);
    }

    fn isCellValueType(ty: *const ast.Type) bool {
        return lowering_rules.isCellValueType(ty);
    }

    fn isPollScalarValueType(ty: *const ast.Type) bool {
        return lowering_rules.isPollScalarValueType(ty);
    }

    fn isRawPtrAliasType(ty: *const ast.Type) bool {
        return lowering_rules.isRawPtrAliasType(ty);
    }

    fn isPointerValueType(ty: *const ast.Type) bool {
        return lowering_rules.isPointerValueType(ty);
    }

    fn valueAssignableTo(self: *TypeChecker, expected: *ast.Type, actual: *ast.Type) bool {
        if (self.typesEqual(expected, actual)) return true;
        return isRawPtrAliasType(expected) and actual.* == .pointer;
    }

    fn isPointerCarrierCastType(ty: *const ast.Type) bool {
        return lowering_rules.isPointerCarrierCastType(ty);
    }

    fn unwrapPointerLikeType(ty: *ast.Type) *ast.Type {
        return lowering_rules.unwrapPointerLikeType(ty);
    }

    fn structDeclForType(self: *TypeChecker, ty: *ast.Type) ?*ast.StructDecl {
        const curr = unwrapPointerLikeType(ty);
        switch (curr.*) {
            .user_defined => |ud| {
                if (self.structs.get(ud.name)) |decl| return decl;
                if (self.type_aliases.get(ud.name)) |alias| return self.syntheticStructDecl(alias);
                return null;
            },
            else => return null,
        }
    }

    fn syntheticStructDecl(self: *TypeChecker, alias: *ast.TypeAliasDecl) ?*ast.StructDecl {
        if (self.alias_struct_cache.get(alias.name)) |cached| return cached;

        const synthetic = self.allocator.create(ast.StructDecl) catch return null;
        synthetic.* = .{ .name = alias.name, .generics = &.{}, .fields = &.{}, .derives = &.{}, .is_union = false, .is_opaque = false };
        self.alias_struct_cache.put(alias.name, synthetic) catch return null;

        var fields = std.array_list.Managed(ast.Field).init(self.allocator);
        defer fields.deinit();
        for (alias.components) |component| {
            switch (component) {
                .ty => |ty| {
                    if (self.structDeclForType(ty)) |src_decl| {
                        for (src_decl.fields) |field| {
                            fields.append(.{ .name = field.name, .ty = field.ty }) catch return null;
                        }
                    } else {
                        fields.append(.{ .name = alias.name, .ty = ty }) catch return null;
                    }
                },
                .inline_struct => |inline_fields| {
                    for (inline_fields) |field| {
                        fields.append(field) catch return null;
                    }
                },
            }
        }
        synthetic.fields = fields.toOwnedSlice() catch return null;
        return synthetic;
    }

    fn deriveNameMatches(actual: []const u8, wanted: []const u8) bool {
        return lowering_rules.deriveNameMatches(actual, wanted);
    }

    fn structHasDerive(decl: *const ast.StructDecl, name: []const u8) bool {
        return lowering_rules.structHasDerive(decl, name);
    }

    fn typeIsCopy(self: *TypeChecker, ty: *ast.Type) bool {
        // Goroutine syntax batch: a Chan<T> value is a runtime
        // handle word (u64) — copyable like Go's channels; lifetime
        // is managed by the explicit destroy() operation, not by
        // ownership transfer.
        if (ty.* == .user_defined and std.mem.eql(u8, ty.user_defined.name, "Chan")) return true;
        // Use derive base (not full Copy-value base) so fn_ptr stays non-Copy in
        // typecheck, matching the pre-share behavior.
        if (lowering_rules.typeHasCopyDeriveBase(ty)) |decision| return decision;
        return switch (ty.*) {
            .user_defined => blk: {
                const decl = self.structDeclForType(ty) orelse break :blk false;
                if (!lowering_rules.typeHasCopyDeriveStructGate(decl)) break :blk false;
                for (decl.fields) |field| {
                    if (!self.typeIsCopy(field.ty)) break :blk false;
                }
                break :blk true;
            },
            .tuple => |tuple| blk: {
                for (tuple.elems) |elem| {
                    if (!self.typeIsCopy(elem)) break :blk false;
                }
                break :blk true;
            },
            else => false,
        };
    }

    // REG-BR-6 helpers: mirror the emitters' call-arg ownership facts
    // (lowering_rules.ValueArgOwnershipFacts and the shallow-copy / Vec-clone
    // preservation rules in codegen.zig and sab_codegen.zig) so the checker
    // consumes exactly those by-value identifier arguments that the SA
    // lowering actually moves without preserving the source binding.
    fn typeIsCopyValue(self: *TypeChecker, ty: *const ast.Type) bool {
        if (ty.* == .user_defined and std.mem.eql(u8, ty.user_defined.name, "Chan")) return true;
        if (lowering_rules.typeIsCopyValueBase(ty)) |decision| return decision;
        return switch (ty.*) {
            .user_defined => self.typeHasCopyDerive(ty),
            .tuple => |tuple| blk: {
                for (tuple.elems) |elem| {
                    if (!self.typeIsCopyValue(elem)) break :blk false;
                }
                break :blk true;
            },
            .array => |arr| self.typeIsCopyValue(arr.elem),
            else => false,
        };
    }

    fn typeHasCopyDerive(self: *TypeChecker, ty: *const ast.Type) bool {
        if (lowering_rules.typeHasCopyDeriveBase(ty)) |decision| return decision;
        if (ty.* != .user_defined) return false;
        const decl = self.structDeclForType(@constCast(ty)) orelse return false;
        if (!lowering_rules.typeHasCopyDeriveStructGate(decl)) return false;
        for (decl.fields) |field| {
            if (!self.typeIsCopyValue(field.ty)) return false;
        }
        return true;
    }

    fn typeIsShallowCopyCallArgValue(self: *TypeChecker, ty: *const ast.Type, depth: usize) bool {
        if (lowering_rules.shallowCopyCallArgValueBase(ty, depth)) |decision| return decision;
        return switch (ty.*) {
            .tuple => |tuple| blk: {
                for (tuple.elems) |elem| {
                    if (!self.typeIsShallowCopyCallArgValue(elem, depth + 1)) break :blk false;
                }
                break :blk true;
            },
            .array => |arr| self.typeIsShallowCopyCallArgValue(arr.elem, depth + 1),
            .user_defined => |ud| blk: {
                if (lowering_rules.shallowCopyCallArgUserDefinedBase(ty, depth)) |decision| break :blk decision;
                if (self.enums.contains(ud.name)) break :blk true;
                const decl = self.structDeclForType(@constCast(ty)) orelse break :blk false;
                if (!lowering_rules.shallowCopyCallArgStructGate(decl)) break :blk false;
                for (decl.fields) |field| {
                    if (!self.typeIsShallowCopyCallArgValue(field.ty, depth + 1)) break :blk false;
                }
                break :blk true;
            },
            else => false,
        };
    }

    fn callArgShallowCopyPreserved(self: *TypeChecker, arg: *const ast.Node, param: ast.Param, arg_ty: *ast.Type) bool {
        return lowering_rules.callArgIsShallowCopyValueCandidate(
            arg,
            param,
            arg_ty,
            self.typeIsCopyValue(arg_ty),
            self.typeIsShallowCopyCallArgValue(arg_ty, 0),
        ) and self.structDeclForType(arg_ty) != null;
    }

    // Enums whose variant payloads are all Copy values move as plain scalars
    // at the SA level; there is no owned register to consume.
    fn enumPayloadIsCopy(self: *TypeChecker, ty: *const ast.Type) bool {
        if (ty.* != .user_defined) return false;
        const decl = self.enums.get(ty.user_defined.name) orelse return false;
        for (decl.variants) |variant| {
            for (variant.fields) |field| {
                if (!self.typeIsCopyValue(field.ty)) return false;
            }
        }
        return true;
    }

    fn consumeCallArgIfMoved(
        self: *TypeChecker,
        scope: *Scope,
        param: ast.Param,
        arg: *const ast.Node,
        arg_ty: *ast.Type,
        call_name: []const u8,
    ) TypeError!void {
        if (arg.* != .identifier) return;
        // Inference placeholders (macro parameters inside a macro
        // definition, unresolved generics) cannot be classified here;
        // macro forwarding has its own consumption analysis.
        if (arg_ty.* == .infer) return;
        if (!lowering_rules.valueArgTransfersOwnershipFromParam(param, arg_ty, self.typeIsCopyValue(arg_ty))) return;
        // The emitters keep a Vec source binding live by cloning it when a
        // later use exists, so a Vec argument never strands the binding.
        if (lowering_rules.vecElementType(arg_ty) != null) return;
        // Shallow-copy-preserved struct arguments are copied at the call
        // boundary by both emitters; the source binding stays live.
        if (self.callArgShallowCopyPreserved(arg, param, arg_ty)) return;
        if (self.enumPayloadIsCopy(arg_ty)) return;
        const sym = scope.lookup(arg.identifier) orelse return;
        if (sym.is_const) return;
        if (sym.state != .active) return;
        // REG-BR-6 self-assignment tail form (`x = f(x, ..)`): the
        // assignment redefines the binding immediately after the
        // right-hand side is checked, so the consumption heals within
        // the same statement. Consume directly here instead of going
        // through consumeBinding, whose loop guard exists for
        // consumptions that stay dead across a loop back-edge - this
        // one cannot, on any path through the statement.
        if (self.assign_rhs_target_name) |target_name| {
            if (std.mem.eql(u8, target_name, arg.identifier)) {
                if (self.assign_rhs_value) |rhs| {
                    if (lowering_rules.tailChainContainsArg(rhs, arg) and lowering_rules.countIdentifierUsesExcept(rhs, arg.identifier, arg) == 0) {
                        sym.state = .consumed;
                        sym.consumed_by_call = call_name;
                        return;
                    }
                }
            }
        }
        try self.consumeBinding(scope, arg.identifier, sym, "call argument");
        sym.consumed_by_call = call_name;
    }

    fn typeIsEq(self: *TypeChecker, ty: *ast.Type) bool {
        const primitive_ok = if (ty.* == .primitive) lowering_rules.primitiveIsCopyValue(ty.primitive) else false;
        if (lowering_rules.typeHasNamedDeriveBase(ty, primitive_ok)) |decision| return decision;
        if (ty.* != .user_defined) return false;
        const decl = self.structDeclForType(ty) orelse return false;
        if (!lowering_rules.typeHasNamedDeriveStructGate(decl, "eq")) return false;
        for (decl.fields) |field| {
            if (!self.typeIsEq(field.ty)) return false;
        }
        return true;
    }

    fn typeIsOrd(self: *TypeChecker, ty: *ast.Type) bool {
        const primitive_ok = if (ty.* == .primitive) lowering_rules.primitiveIsHashable(ty.primitive) else false;
        if (lowering_rules.typeHasNamedDeriveBase(ty, primitive_ok)) |decision| return decision;
        if (ty.* != .user_defined) return false;
        const decl = self.structDeclForType(ty) orelse return false;
        if (!lowering_rules.typeHasNamedDeriveStructGate(decl, "ord")) return false;
        for (decl.fields) |field| {
            if (!self.typeIsOrd(field.ty)) return false;
        }
        return true;
    }

    fn typeIsHash(self: *TypeChecker, ty: *ast.Type) bool {
        const primitive_ok = if (ty.* == .primitive) lowering_rules.primitiveIsHashable(ty.primitive) else false;
        if (lowering_rules.typeHasNamedDeriveBase(ty, primitive_ok)) |decision| return decision;
        if (ty.* != .user_defined) return false;
        const decl = self.structDeclForType(ty) orelse return false;
        if (!lowering_rules.typeHasNamedDeriveStructGate(decl, "hash")) return false;
        for (decl.fields) |field| {
            if (!self.typeIsHash(field.ty)) return false;
        }
        return true;
    }

    fn typeIsDebug(self: *TypeChecker, ty: *ast.Type) bool {
        const primitive_ok = if (ty.* == .primitive) lowering_rules.primitiveIsCopyValue(ty.primitive) else false;
        if (lowering_rules.typeHasNamedDeriveBase(ty, primitive_ok)) |decision| return decision;
        if (ty.* != .user_defined) return false;
        const decl = self.structDeclForType(ty) orelse return false;
        if (!lowering_rules.typeHasNamedDeriveStructGate(decl, "debug")) return false;
        for (decl.fields) |field| {
            if (!self.typeIsDebug(field.ty)) return false;
        }
        return true;
    }

    fn structFieldsAllNumeric(decl: *const ast.StructDecl) bool {
        return lowering_rules.structFieldsAllNumeric(decl);
    }

    fn structFieldsAllComparable(decl: *const ast.StructDecl) bool {
        return lowering_rules.structFieldsAllComparable(decl);
    }

    fn literalZero(expr: *const ast.Node) bool {
        return lowering_rules.literalZero(expr);
    }

    fn isStringLikeType(ty: *const ast.Type) bool {
        return lowering_rules.isStringLikeType(ty);
    }

    fn dynTraitName(ty: *ast.Type) ?[]const u8 {
        return lowering_rules.dynTraitName(ty);
    }

    fn arrayType(ty: *ast.Type) ?ast.ArrayType {
        return lowering_rules.arrayType(ty);
    }

    fn sliceElementType(ty: *ast.Type) ?*ast.Type {
        return lowering_rules.sliceElementType(ty);
    }

    fn canCoerceBorrowArrayToBorrowSlice(self: *TypeChecker, param_ty: *ast.Type, arg_ty: *ast.Type) bool {
        if (arg_ty.* != .borrow) return false;
        const target_ty = if (param_ty.* == .borrow) param_ty.borrow else param_ty;
        const slice_elem = sliceElementType(target_ty) orelse return false;
        const arr = arrayType(arg_ty.borrow) orelse return false;
        return self.typesEqual(slice_elem, arr.elem);
    }

    fn checkClosureLiteralWithContext(
        self: *TypeChecker,
        expr: *ast.Node,
        scope: *Scope,
        contextual_params: []const *ast.Type,
    ) TypeError!*ast.Type {
        if (expr.* != .closure_literal) return TypeError.TypeMismatch;
        const lit = &expr.closure_literal;
        if (lit.params.len != contextual_params.len) return TypeError.InvalidArgsCount;

        const closure_scope = try Scope.init(self.allocator, scope);
        try self.scope_pool.append(closure_scope);

        var param_types = std.array_list.Managed(*ast.Type).init(self.allocator);
        for (lit.params, contextual_params) |p, ctx_ty| {
            if (p.ty.* != .infer and !self.typesEqual(p.ty, ctx_ty)) return TypeError.TypeMismatch;
            try self.defineSymbol(closure_scope, p.name, ctx_ty, true);
            try param_types.append(ctx_ty);
        }

        // R2 is shallow ("directly in an async body"): a closure
        // body is a separate body, so the async-blocking rule
        // resets across this boundary.
        const previous_fn_is_async = self.current_fn_is_async;
        self.current_fn_is_async = false;
        defer self.current_fn_is_async = previous_fn_is_async;
        const previous_fn_is_variadic_def = self.current_fn_is_variadic_def;
        self.current_fn_is_variadic_def = false;
        defer self.current_fn_is_variadic_def = previous_fn_is_variadic_def;
        const ret_ty = try self.checkExpr(lit.body, closure_scope);
        const ty = try self.allocator.create(ast.Type);
        ty.* = .{ .closure = .{ .params = try param_types.toOwnedSlice(), .ret = ret_ty } };
        self.expr_types.put(expr, ty) catch return TypeError.OutOfMemory;
        return ty;
    }

    fn makeFutureType(self: *TypeChecker, inner: *ast.Type) TypeError!*ast.Type {
        const ty = try self.allocator.create(ast.Type);
        ty.* = .{ .future = inner };
        return ty;
    }

    fn makeFuturePairType(self: *TypeChecker, left: *ast.Type, right: *ast.Type) TypeError!*ast.Type {
        const generics = try self.allocator.alloc(*ast.Type, 2);
        generics[0] = left;
        generics[1] = right;
        const ty = try self.allocator.create(ast.Type);
        ty.* = .{ .user_defined = .{ .name = "FuturePair", .generics = generics } };
        return ty;
    }

    fn makeFutureEitherType(self: *TypeChecker, left: *ast.Type, right: *ast.Type) TypeError!*ast.Type {
        const generics = try self.allocator.alloc(*ast.Type, 2);
        generics[0] = left;
        generics[1] = right;
        const ty = try self.allocator.create(ast.Type);
        ty.* = .{ .user_defined = .{ .name = "FutureEither", .generics = generics } };
        return ty;
    }

    fn makeBorrowType(self: *TypeChecker, inner: *ast.Type) TypeError!*ast.Type {
        const ty = try self.allocator.create(ast.Type);
        ty.* = .{ .borrow = inner };
        return ty;
    }

    fn makePointerType(self: *TypeChecker, inner: *ast.Type) TypeError!*ast.Type {
        const ty = try self.allocator.create(ast.Type);
        ty.* = .{ .pointer = inner };
        return ty;
    }

    fn makeFnPtrType(self: *TypeChecker, abi: ?[]const u8, params: []const *ast.Type, ret: *ast.Type) TypeError!*ast.Type {
        return self.makeFnPtrTypeVariadic(abi, params, ret, false);
    }

    fn makeFnPtrTypeVariadic(self: *TypeChecker, abi: ?[]const u8, params: []const *ast.Type, ret: *ast.Type, is_variadic: bool) TypeError!*ast.Type {
        const owned_params = try self.allocator.alloc(*ast.Type, params.len);
        for (params, 0..) |param, i| owned_params[i] = param;
        const ty = try self.allocator.create(ast.Type);
        ty.* = .{ .fn_ptr = .{ .abi = abi, .params = owned_params, .ret = ret, .is_variadic = is_variadic } };
        return ty;
    }

    /// The fn-pointer parameter types of a function declaration: for a
    /// variadic definition the trailing VaList parameter is dropped (the
    /// fn-pointer spelling carries the fixed parameters plus the `...`
    /// flag instead).
    fn fnPtrParamTypes(self: *TypeChecker, decl: *const ast.FuncDecl) TypeError![]const *ast.Type {
        var params = std.array_list.Managed(*ast.Type).init(self.allocator);
        const n = if (decl.is_variadic and decl.params.len > 0 and decl.params[decl.params.len - 1].ty.* == .primitive and decl.params[decl.params.len - 1].ty.primitive == .va_list)
            decl.params.len - 1
        else
            decl.params.len;
        for (decl.params[0..n]) |param| try params.append(param.ty);
        return params.toOwnedSlice();
    }

    fn makeInferType(self: *TypeChecker) TypeError!*ast.Type {
        const ty = try self.allocator.create(ast.Type);
        ty.* = .infer;
        return ty;
    }

    fn makeOptionType(self: *TypeChecker, inner: *ast.Type) TypeError!*ast.Type {
        const generics = try self.allocator.alloc(*ast.Type, 1);
        generics[0] = inner;
        const ty = try self.allocator.create(ast.Type);
        ty.* = .{ .user_defined = .{ .name = "Option", .generics = generics } };
        return ty;
    }

    fn makeResultType(self: *TypeChecker, ok_ty: *ast.Type, err_ty: *ast.Type) TypeError!*ast.Type {
        const generics = try self.allocator.alloc(*ast.Type, 2);
        generics[0] = ok_ty;
        generics[1] = err_ty;
        const ty = try self.allocator.create(ast.Type);
        ty.* = .{ .user_defined = .{ .name = "Result", .generics = generics } };
        return ty;
    }

    fn makeJoinHandleType(self: *TypeChecker, inner: *ast.Type) TypeError!*ast.Type {
        const generics = try self.allocator.alloc(*ast.Type, 1);
        generics[0] = inner;
        const ty = try self.allocator.create(ast.Type);
        ty.* = .{ .user_defined = .{ .name = "JoinHandle", .generics = generics } };
        return ty;
    }

    fn makeTaskType(self: *TypeChecker, inner: *ast.Type) TypeError!*ast.Type {
        const generics = try self.allocator.alloc(*ast.Type, 1);
        generics[0] = inner;
        const ty = try self.allocator.create(ast.Type);
        ty.* = .{ .user_defined = .{ .name = "Task", .generics = generics } };
        return ty;
    }

    fn makeExecutorType(self: *TypeChecker, inner: *ast.Type) TypeError!*ast.Type {
        const generics = try self.allocator.alloc(*ast.Type, 1);
        generics[0] = inner;
        const ty = try self.allocator.create(ast.Type);
        ty.* = .{ .user_defined = .{ .name = "Executor", .generics = generics } };
        return ty;
    }

    fn makePollType(self: *TypeChecker, inner: *ast.Type) TypeError!*ast.Type {
        const generics = try self.allocator.alloc(*ast.Type, 1);
        generics[0] = inner;
        const ty = try self.allocator.create(ast.Type);
        ty.* = .{ .user_defined = .{ .name = "Poll", .generics = generics } };
        return ty;
    }

    fn makeSenderType(self: *TypeChecker, inner: *ast.Type) TypeError!*ast.Type {
        const generics = try self.allocator.alloc(*ast.Type, 1);
        generics[0] = inner;
        const ty = try self.allocator.create(ast.Type);
        ty.* = .{ .user_defined = .{ .name = "Sender", .generics = generics } };
        return ty;
    }

    fn makeReceiverType(self: *TypeChecker, inner: *ast.Type) TypeError!*ast.Type {
        const generics = try self.allocator.alloc(*ast.Type, 1);
        generics[0] = inner;
        const ty = try self.allocator.create(ast.Type);
        ty.* = .{ .user_defined = .{ .name = "Receiver", .generics = generics } };
        return ty;
    }

    fn makeTupleType(self: *TypeChecker, elems: []const *ast.Type) TypeError!*ast.Type {
        const owned = try self.allocator.alloc(*ast.Type, elems.len);
        for (elems, 0..) |elem, i| owned[i] = elem;
        const ty = try self.allocator.create(ast.Type);
        ty.* = .{ .tuple = .{ .elems = owned } };
        return ty;
    }

    fn makeI32Type(self: *TypeChecker) TypeError!*ast.Type {
        const ty = try self.allocator.create(ast.Type);
        ty.* = .{ .primitive = .i32 };
        return ty;
    }

    fn makeI64Type(self: *TypeChecker) TypeError!*ast.Type {
        const ty = try self.allocator.create(ast.Type);
        ty.* = .{ .primitive = .i64 };
        return ty;
    }

    fn makeF64Type(self: *TypeChecker) TypeError!*ast.Type {
        const ty = try self.allocator.create(ast.Type);
        ty.* = .{ .primitive = .f64 };
        return ty;
    }

    fn makeRawPtrType(self: *TypeChecker) TypeError!*ast.Type {
        const ty = try self.allocator.create(ast.Type);
        ty.* = .{ .primitive = .raw_ptr };
        return ty;
    }

    fn makeBoolType(self: *TypeChecker) TypeError!*ast.Type {
        const ty = try self.allocator.create(ast.Type);
        ty.* = .{ .primitive = .boolean };
        return ty;
    }

    fn makeU8Type(self: *TypeChecker) TypeError!*ast.Type {
        const ty = try self.allocator.create(ast.Type);
        ty.* = .{ .primitive = .u8 };
        return ty;
    }

    fn makeU64Type(self: *TypeChecker) TypeError!*ast.Type {
        const ty = try self.allocator.create(ast.Type);
        ty.* = .{ .primitive = .u64 };
        return ty;
    }

    fn makeSliceType(self: *TypeChecker, inner: *ast.Type) TypeError!*ast.Type {
        const generics = try self.allocator.alloc(*ast.Type, 1);
        generics[0] = inner;
        const ty = try self.allocator.create(ast.Type);
        ty.* = .{ .user_defined = .{ .name = "Slice", .generics = generics } };
        return ty;
    }

    fn makePrimitiveType(self: *TypeChecker, primitive: ast.Primitive) TypeError!*ast.Type {
        const ty = try self.allocator.create(ast.Type);
        ty.* = .{ .primitive = primitive };
        return ty;
    }

    fn makeImportedMacroExpressionResultType(
        self: *TypeChecker,
        kind: lowering_rules.ImportedMacroExpressionResultKind,
    ) TypeError!*ast.Type {
        return switch (kind) {
            .raw_pointer => try self.makeRawPtrType(),
            .boolean => try self.makeBoolType(),
            .u8 => try self.makeU8Type(),
            .u32 => try self.makePrimitiveType(.u32),
            .u64 => try self.makeU64Type(),
            .i32 => try self.makeI32Type(),
            .i64 => try self.makeI64Type(),
            .f64 => try self.makePrimitiveType(.f64),
            .slice_u8 => try self.makeSliceType(try self.makeU8Type()),
        };
    }

    fn makeStringType(self: *TypeChecker) TypeError!*ast.Type {
        const ty = try self.allocator.create(ast.Type);
        ty.* = .{ .user_defined = .{ .name = "String", .generics = &.{} } };
        return ty;
    }

    fn makeFileType(self: *TypeChecker) TypeError!*ast.Type {
        const ty = try self.allocator.create(ast.Type);
        ty.* = .{ .user_defined = .{ .name = "File", .generics = &.{} } };
        return ty;
    }

    fn makeMetadataType(self: *TypeChecker) TypeError!*ast.Type {
        const ty = try self.allocator.create(ast.Type);
        ty.* = .{ .user_defined = .{ .name = "Metadata", .generics = &.{} } };
        return ty;
    }

    fn makeAtomicI32Type(self: *TypeChecker) TypeError!*ast.Type {
        const ty = try self.allocator.create(ast.Type);
        ty.* = .{ .user_defined = .{ .name = "AtomicI32", .generics = &.{} } };
        return ty;
    }

    fn makeAtomicUsizeType(self: *TypeChecker) TypeError!*ast.Type {
        const ty = try self.allocator.create(ast.Type);
        ty.* = .{ .user_defined = .{ .name = "AtomicUsize", .generics = &.{} } };
        return ty;
    }

    fn makeCellType(self: *TypeChecker, inner: *ast.Type) TypeError!*ast.Type {
        const generics = try self.allocator.alloc(*ast.Type, 1);
        generics[0] = inner;
        const ty = try self.allocator.create(ast.Type);
        ty.* = .{ .user_defined = .{ .name = "Cell", .generics = generics } };
        return ty;
    }

    fn makeRefCellType(self: *TypeChecker, inner: *ast.Type) TypeError!*ast.Type {
        const generics = try self.allocator.alloc(*ast.Type, 1);
        generics[0] = inner;
        const ty = try self.allocator.create(ast.Type);
        ty.* = .{ .user_defined = .{ .name = "RefCell", .generics = generics } };
        return ty;
    }

    fn makeMutexType(self: *TypeChecker, inner: *ast.Type) TypeError!*ast.Type {
        const generics = try self.allocator.alloc(*ast.Type, 1);
        generics[0] = inner;
        const ty = try self.allocator.create(ast.Type);
        ty.* = .{ .user_defined = .{ .name = "Mutex", .generics = generics } };
        return ty;
    }

    fn makeMutexGuardType(self: *TypeChecker, inner: *ast.Type) TypeError!*ast.Type {
        const generics = try self.allocator.alloc(*ast.Type, 1);
        generics[0] = inner;
        const ty = try self.allocator.create(ast.Type);
        ty.* = .{ .user_defined = .{ .name = "MutexGuard", .generics = generics } };
        return ty;
    }

    fn makeRwLockType(self: *TypeChecker, inner: *ast.Type) TypeError!*ast.Type {
        const generics = try self.allocator.alloc(*ast.Type, 1);
        generics[0] = inner;
        const ty = try self.allocator.create(ast.Type);
        ty.* = .{ .user_defined = .{ .name = "RwLock", .generics = generics } };
        return ty;
    }

    fn makeRwLockReadGuardType(self: *TypeChecker, inner: *ast.Type) TypeError!*ast.Type {
        const generics = try self.allocator.alloc(*ast.Type, 1);
        generics[0] = inner;
        const ty = try self.allocator.create(ast.Type);
        ty.* = .{ .user_defined = .{ .name = "RwLockReadGuard", .generics = generics } };
        return ty;
    }

    fn makeRwLockWriteGuardType(self: *TypeChecker, inner: *ast.Type) TypeError!*ast.Type {
        const generics = try self.allocator.alloc(*ast.Type, 1);
        generics[0] = inner;
        const ty = try self.allocator.create(ast.Type);
        ty.* = .{ .user_defined = .{ .name = "RwLockWriteGuard", .generics = generics } };
        return ty;
    }

    fn makeOrderingType(self: *TypeChecker) TypeError!*ast.Type {
        const ty = try self.allocator.create(ast.Type);
        ty.* = .{ .user_defined = .{ .name = "Ordering", .generics = &.{} } };
        return ty;
    }

    fn makeBoxType(self: *TypeChecker, inner: *ast.Type) TypeError!*ast.Type {
        const generics = try self.allocator.alloc(*ast.Type, 1);
        generics[0] = inner;
        const ty = try self.allocator.create(ast.Type);
        ty.* = .{ .user_defined = .{ .name = "Box", .generics = generics } };
        return ty;
    }

    fn makeManuallyDropType(self: *TypeChecker, inner: *ast.Type) TypeError!*ast.Type {
        const generics = try self.allocator.alloc(*ast.Type, 1);
        generics[0] = inner;
        const ty = try self.allocator.create(ast.Type);
        ty.* = .{ .user_defined = .{ .name = "ManuallyDrop", .generics = generics } };
        return ty;
    }

    fn makeRcType(self: *TypeChecker, inner: *ast.Type) TypeError!*ast.Type {
        const generics = try self.allocator.alloc(*ast.Type, 1);
        generics[0] = inner;
        const ty = try self.allocator.create(ast.Type);
        ty.* = .{ .user_defined = .{ .name = "Rc", .generics = generics } };
        return ty;
    }

    fn makeArcType(self: *TypeChecker, inner: *ast.Type) TypeError!*ast.Type {
        const generics = try self.allocator.alloc(*ast.Type, 1);
        generics[0] = inner;
        const ty = try self.allocator.create(ast.Type);
        ty.* = .{ .user_defined = .{ .name = "Arc", .generics = generics } };
        return ty;
    }

    fn makeAtomicPtrType(self: *TypeChecker, inner: *ast.Type) TypeError!*ast.Type {
        const generics = try self.allocator.alloc(*ast.Type, 1);
        generics[0] = inner;
        const ty = try self.allocator.create(ast.Type);
        ty.* = .{ .user_defined = .{ .name = "AtomicPtr", .generics = generics } };
        return ty;
    }

    fn makeVecType(self: *TypeChecker, inner: *ast.Type) TypeError!*ast.Type {
        const generics = try self.allocator.alloc(*ast.Type, 1);
        generics[0] = inner;
        const ty = try self.allocator.create(ast.Type);
        ty.* = .{ .user_defined = .{ .name = "Vec", .generics = generics } };
        return ty;
    }

    fn makeVecDequeType(self: *TypeChecker, inner: *ast.Type) TypeError!*ast.Type {
        const generics = try self.allocator.alloc(*ast.Type, 1);
        generics[0] = inner;
        const ty = try self.allocator.create(ast.Type);
        ty.* = .{ .user_defined = .{ .name = "VecDeque", .generics = generics } };
        return ty;
    }

    fn makeHashMapType(self: *TypeChecker, key_ty: *ast.Type, value_ty: *ast.Type) TypeError!*ast.Type {
        const generics = try self.allocator.alloc(*ast.Type, 2);
        generics[0] = key_ty;
        generics[1] = value_ty;
        const ty = try self.allocator.create(ast.Type);
        ty.* = .{ .user_defined = .{ .name = "HashMap", .generics = generics } };
        return ty;
    }

    fn makeHashSetType(self: *TypeChecker, key_ty: *ast.Type) TypeError!*ast.Type {
        const generics = try self.allocator.alloc(*ast.Type, 1);
        generics[0] = key_ty;
        const ty = try self.allocator.create(ast.Type);
        ty.* = .{ .user_defined = .{ .name = "HashSet", .generics = generics } };
        return ty;
    }

    fn makeBTreeMapType(self: *TypeChecker, key_ty: *ast.Type, value_ty: *ast.Type) TypeError!*ast.Type {
        const generics = try self.allocator.alloc(*ast.Type, 2);
        generics[0] = key_ty;
        generics[1] = value_ty;
        const ty = try self.allocator.create(ast.Type);
        ty.* = .{ .user_defined = .{ .name = "BTreeMap", .generics = generics } };
        return ty;
    }

    fn makeBTreeSetType(self: *TypeChecker, key_ty: *ast.Type) TypeError!*ast.Type {
        const generics = try self.allocator.alloc(*ast.Type, 1);
        generics[0] = key_ty;
        const ty = try self.allocator.create(ast.Type);
        ty.* = .{ .user_defined = .{ .name = "BTreeSet", .generics = generics } };
        return ty;
    }

    fn boxInnerType(ty: *const ast.Type) ?*ast.Type {
        return lowering_rules.boxInnerType(ty);
    }

    fn manuallyDropInnerType(ty: *const ast.Type) ?*ast.Type {
        return lowering_rules.manuallyDropInnerType(ty);
    }

    fn rcInnerType(ty: *const ast.Type) ?*ast.Type {
        return lowering_rules.rcInnerType(ty);
    }

    fn arcInnerType(ty: *const ast.Type) ?*ast.Type {
        return lowering_rules.arcInnerType(ty);
    }

    fn vecElementType(ty: *const ast.Type) ?*ast.Type {
        return lowering_rules.vecElementType(ty);
    }

    fn vecDequeElementType(ty: *const ast.Type) ?*ast.Type {
        return lowering_rules.vecDequeElementType(ty);
    }

    fn isAtomicI32Type(ty: *const ast.Type) bool {
        return lowering_rules.isAtomicI32Type(ty);
    }

    fn isAtomicUsizeType(ty: *const ast.Type) bool {
        return lowering_rules.isAtomicUsizeType(ty);
    }

    fn atomicPtrInnerType(ty: *const ast.Type) ?*ast.Type {
        return lowering_rules.atomicPtrInnerType(ty);
    }

    fn cellInnerType(ty: *const ast.Type) ?*ast.Type {
        return lowering_rules.cellInnerType(ty);
    }

    fn refCellInnerType(ty: *const ast.Type) ?*ast.Type {
        return lowering_rules.refCellInnerType(ty);
    }

    fn mutexInnerType(ty: *const ast.Type) ?*ast.Type {
        return lowering_rules.mutexInnerType(ty);
    }

    fn mutexGuardInnerType(ty: *const ast.Type) ?*ast.Type {
        return lowering_rules.mutexGuardInnerType(ty);
    }

    fn rwLockInnerType(ty: *const ast.Type) ?*ast.Type {
        return lowering_rules.rwLockInnerType(ty);
    }

    fn rwLockReadGuardInnerType(ty: *const ast.Type) ?*ast.Type {
        return lowering_rules.rwLockReadGuardInnerType(ty);
    }

    fn rwLockWriteGuardInnerType(ty: *const ast.Type) ?*ast.Type {
        return lowering_rules.rwLockWriteGuardInnerType(ty);
    }

    fn isOrderingType(ty: *const ast.Type) bool {
        return lowering_rules.isOrderingType(ty);
    }

    fn isFileType(ty: *const ast.Type) bool {
        return lowering_rules.isFileType(ty);
    }

    fn isMetadataType(ty: *const ast.Type) bool {
        return lowering_rules.isMetadataType(ty);
    }

    fn isOrderingName(name: []const u8) bool {
        return lowering_rules.isOrderingName(name);
    }

    const HashMapTypes = struct {
        key: *ast.Type,
        value: *ast.Type,
    };

    fn hashMapTypes(ty: *const ast.Type) ?HashMapTypes {
        const mapped = lowering_rules.hashMapTypes(ty) orelse return null;
        return .{ .key = mapped.key, .value = mapped.value };
    }

    const HashSetTypes = struct {
        key: *ast.Type,
    };

    fn hashSetTypes(ty: *const ast.Type) ?HashSetTypes {
        const key = lowering_rules.hashSetElementType(ty) orelse return null;
        return .{ .key = key };
    }

    const BTreeMapTypes = struct {
        key: *ast.Type,
        value: *ast.Type,
    };

    fn btreeMapTypes(ty: *const ast.Type) ?BTreeMapTypes {
        const mapped = lowering_rules.btreeMapTypes(ty) orelse return null;
        return .{ .key = mapped.key, .value = mapped.value };
    }

    const BTreeSetTypes = struct {
        key: *ast.Type,
    };

    fn btreeSetTypes(ty: *const ast.Type) ?BTreeSetTypes {
        const key = lowering_rules.btreeSetElementType(ty) orelse return null;
        return .{ .key = key };
    }

    fn optionInnerType(ty: *const ast.Type) ?*ast.Type {
        return lowering_rules.optionInnerType(ty);
    }

    fn resultOkType(ty: *const ast.Type) ?*ast.Type {
        return lowering_rules.resultOkType(ty);
    }

    fn resultErrType(ty: *const ast.Type) ?*ast.Type {
        return lowering_rules.resultErrType(ty);
    }

    fn patternBindingType(self: *TypeChecker, pattern: ast.EnumPattern, value_ty: *const ast.Type, comptime context: []const u8) TypeError!?*ast.Type {
        if (optionInnerType(value_ty)) |inner_ty| {
            if (!std.mem.eql(u8, pattern.enum_name, "Option")) {
                self.setError(context ++ " pattern must match Option<T>, got {s}", .{pattern.enum_name});
                return TypeError.TypeMismatch;
            }
            if (std.mem.eql(u8, pattern.variant_name, "Some")) {
                if (pattern.bindings.len != 1) {
                    self.setError("Some pattern requires one binding", .{});
                    return TypeError.InvalidArgsCount;
                }
                return inner_ty;
            }
            if (std.mem.eql(u8, pattern.variant_name, "None")) {
                if (pattern.bindings.len != 0) {
                    self.setError("None pattern requires zero bindings", .{});
                    return TypeError.InvalidArgsCount;
                }
                return null;
            }
            self.setError("unsupported Option variant {s} in " ++ context, .{pattern.variant_name});
            return TypeError.TypeMismatch;
        }

        if (resultOkType(value_ty)) |ok_ty| {
            const err_ty = resultErrType(value_ty) orelse return TypeError.TypeMismatch;
            if (!std.mem.eql(u8, pattern.enum_name, "Result")) {
                self.setError(context ++ " pattern must match Result<T, E>, got {s}", .{pattern.enum_name});
                return TypeError.TypeMismatch;
            }
            if (std.mem.eql(u8, pattern.variant_name, "Ok")) {
                if (pattern.bindings.len != 1) {
                    self.setError("Ok pattern requires one binding", .{});
                    return TypeError.InvalidArgsCount;
                }
                return ok_ty;
            }
            if (std.mem.eql(u8, pattern.variant_name, "Err")) {
                if (pattern.bindings.len != 1) {
                    self.setError("Err pattern requires one binding", .{});
                    return TypeError.InvalidArgsCount;
                }
                return err_ty;
            }
            self.setError("unsupported Result variant {s} in " ++ context, .{pattern.variant_name});
            return TypeError.TypeMismatch;
        }

        self.setError(context ++ " value must be Option<T> or Result<T, E>", .{});
        return TypeError.TypeMismatch;
    }

    fn enumDeclForValueType(self: *TypeChecker, value_ty: *const ast.Type) ?*ast.EnumDecl {
        const curr = lowering_rules.peelBorrowPointerType(value_ty);
        if (curr.* != .user_defined) return null;
        return self.enums.get(curr.user_defined.name);
    }

    fn definePatternBindings(self: *TypeChecker, scope: *Scope, pattern: ast.EnumPattern, value_ty: *const ast.Type, comptime context: []const u8, writable: bool) TypeError!void {
        if (optionInnerType(value_ty) != null or resultOkType(value_ty) != null) {
            const binding_ty = try self.patternBindingType(pattern, value_ty, context);
            if (binding_ty) |ty| {
                try self.defineSymbol(scope, pattern.bindings[0], ty, writable);
            }
            return;
        }

        const decl = self.enumDeclForValueType(value_ty) orelse {
            self.setError(context ++ " value must be Option<T>, Result<T, E>, or enum", .{});
            return TypeError.TypeMismatch;
        };
        if (!enumNameMatchesDecl(pattern.enum_name, decl.name)) {
            self.setError(context ++ " pattern must match enum {s}, got {s}", .{ decl.name, pattern.enum_name });
            return TypeError.TypeMismatch;
        }
        const variant = findEnumVariant(decl, pattern.variant_name) orelse return TypeError.FieldNotFound;
        if (pattern.bindings.len != variant.fields.len) return TypeError.InvalidArgsCount;
        for (pattern.bindings, variant.fields) |binding, field| {
            try self.defineSymbol(scope, binding, field.ty, writable);
        }
    }

    fn joinHandleInnerType(ty: *const ast.Type) ?*ast.Type {
        return lowering_rules.joinHandleInnerType(ty);
    }

    fn taskInnerType(ty: *const ast.Type) ?*ast.Type {
        return lowering_rules.taskInnerType(ty);
    }

    fn executorTaskBufferInnerType(ty: *const ast.Type) ?*ast.Type {
        const plan = lowering_rules.executorTaskBufferPlan(ty) orelse return null;
        return plan.inner;
    }

    fn futureInnerType(ty: *const ast.Type) ?*ast.Type {
        return lowering_rules.futureInnerType(ty);
    }

    const FuturePairInnerTypes = struct {
        left: *ast.Type,
        right: *ast.Type,
    };

    fn futurePairInnerTypes(ty: *const ast.Type) ?FuturePairInnerTypes {
        const mapped = lowering_rules.futurePairInnerTypes(ty) orelse return null;
        return .{ .left = mapped.key, .right = mapped.value };
    }

    fn checkFutureJoin2Call(self: *TypeChecker, call: ast.CallExpr, scope: *Scope) TypeError!*ast.Type {
        if (call.args.len != 2) return TypeError.InvalidArgsCount;
        if (call.generics.len != 0) return TypeError.InvalidArgsCount;
        const left_ty = try self.checkExpr(call.args[0], scope);
        const right_ty = try self.checkExpr(call.args[1], scope);
        const left_inner = futureInnerType(left_ty) orelse return TypeError.TypeMismatch;
        const right_inner = futureInnerType(right_ty) orelse return TypeError.TypeMismatch;
        if (!isPollScalarValueType(left_inner) or !isPollScalarValueType(right_inner)) return TypeError.TypeMismatch;
        const pair_ty = try self.makeFuturePairType(left_inner, right_inner);
        return try self.makeFutureType(pair_ty);
    }

    fn checkFuturePairAccessorCall(self: *TypeChecker, call: ast.CallExpr, scope: *Scope, want_left: bool) TypeError!*ast.Type {
        if (call.args.len != 1) return TypeError.InvalidArgsCount;
        if (call.generics.len != 0) return TypeError.InvalidArgsCount;
        const pair_ty = try self.checkExpr(call.args[0], scope);
        const pair = futurePairInnerTypes(pair_ty) orelse return TypeError.TypeMismatch;
        const out_ty = if (want_left) pair.left else pair.right;
        if (!isPollScalarValueType(out_ty)) return TypeError.TypeMismatch;
        return out_ty;
    }

    const FutureEitherInnerTypes = struct {
        left: *ast.Type,
        right: *ast.Type,
    };

    fn futureEitherInnerTypes(ty: *const ast.Type) ?FutureEitherInnerTypes {
        const mapped = lowering_rules.futureEitherInnerTypes(ty) orelse return null;
        return .{ .left = mapped.key, .right = mapped.value };
    }

    fn checkFutureSelect2Call(self: *TypeChecker, call: ast.CallExpr, scope: *Scope) TypeError!*ast.Type {
        if (call.args.len != 2) return TypeError.InvalidArgsCount;
        if (call.generics.len != 0) return TypeError.InvalidArgsCount;
        const left_ty = try self.checkExpr(call.args[0], scope);
        const right_ty = try self.checkExpr(call.args[1], scope);
        const left_inner = futureInnerType(left_ty) orelse return TypeError.TypeMismatch;
        const right_inner = futureInnerType(right_ty) orelse return TypeError.TypeMismatch;
        if (!isPollScalarValueType(left_inner) or !isPollScalarValueType(right_inner)) return TypeError.TypeMismatch;
        const either_ty = try self.makeFutureEitherType(left_inner, right_inner);
        return try self.makeFutureType(either_ty);
    }

    fn checkFutureEitherSideCall(self: *TypeChecker, call: ast.CallExpr, scope: *Scope) TypeError!*ast.Type {
        if (call.args.len != 1) return TypeError.InvalidArgsCount;
        if (call.generics.len != 0) return TypeError.InvalidArgsCount;
        const either_ty = try self.checkExpr(call.args[0], scope);
        _ = futureEitherInnerTypes(either_ty) orelse return TypeError.TypeMismatch;
        return try self.makeU64Type();
    }

    fn checkFutureEitherAccessorCall(self: *TypeChecker, call: ast.CallExpr, scope: *Scope, want_left: bool) TypeError!*ast.Type {
        if (call.args.len != 1) return TypeError.InvalidArgsCount;
        if (call.generics.len != 0) return TypeError.InvalidArgsCount;
        const either_ty = try self.checkExpr(call.args[0], scope);
        const either = futureEitherInnerTypes(either_ty) orelse return TypeError.TypeMismatch;
        const out_ty = if (want_left) either.left else either.right;
        if (!isPollScalarValueType(out_ty)) return TypeError.TypeMismatch;
        return out_ty;
    }

    fn executorInnerType(ty: *const ast.Type) ?*ast.Type {
        return lowering_rules.executorInnerType(ty);
    }

    fn pollInnerType(ty: *const ast.Type) ?*ast.Type {
        return lowering_rules.pollInnerType(ty);
    }

    fn senderInnerType(ty: *const ast.Type) ?*ast.Type {
        return lowering_rules.senderInnerType(ty);
    }

    fn receiverInnerType(ty: *const ast.Type) ?*ast.Type {
        return lowering_rules.receiverInnerType(ty);
    }

    fn dynDispatchTraitName(ty: *const ast.Type) ?[]const u8 {
        if (dynTraitName(@constCast(ty))) |name| return name;
        if (boxInnerType(ty)) |inner| {
            return dynTraitName(inner);
        }
        if (rcInnerType(ty)) |inner| {
            return dynTraitName(inner);
        }
        return null;
    }

    fn canCoerceToDynBox(self: *TypeChecker, declared_ty: *const ast.Type, val_ty: *const ast.Type) ?[]const u8 {
        const declared_inner = boxInnerType(declared_ty) orelse return null;
        const trait_name = dynTraitName(declared_inner) orelse return null;
        const val_inner = boxInnerType(val_ty) orelse return null;
        if (!self.typeImplementsTrait(val_inner, trait_name)) return null;
        return trait_name;
    }

    fn canCoerceRcNewToDynRc(self: *TypeChecker, declared_ty: *const ast.Type, val_ty: *const ast.Type, value_expr: *const ast.Node) ?[]const u8 {
        const declared_inner = rcInnerType(declared_ty) orelse return null;
        const trait_name = dynTraitName(declared_inner) orelse return null;
        const val_inner = rcInnerType(val_ty) orelse return null;
        if (!self.typeImplementsTrait(val_inner, trait_name)) return null;
        if (value_expr.* != .call_expr) return null;
        const call = value_expr.call_expr;
        if (!lowering_rules.isRcNewCall(call)) return null;
        return trait_name;
    }

    fn rootIdentifier(expr: *const ast.Node) ?[]const u8 {
        return switch (expr.*) {
            .identifier => |name| name,
            .index_expr => |idx| rootIdentifier(idx.target),
            .field_expr => |field| rootIdentifier(field.expr),
            else => null,
        };
    }

    fn borrowExprRootIdentifier(expr: *const ast.Node) ?[]const u8 {
        return switch (expr.*) {
            .borrow_expr => |borrow| rootIdentifier(borrow.expr),
            else => null,
        };
    }

    fn exprUsesIdentifierValue(expr: *const ast.Node, name: []const u8) bool {
        return switch (expr.*) {
            .identifier => |ident| std.mem.eql(u8, ident, name),
            .await_expr => |aw| exprUsesIdentifierValue(aw.expr, name),
            .go_expr => |g| exprUsesIdentifierValue(g.call, name),
            .move_expr => |mv| exprUsesIdentifierValue(mv.expr, name),
            .cast_expr => |cast| exprUsesIdentifierValue(cast.expr, name),
            .binary_expr => |bin| exprUsesIdentifierValue(bin.left, name) or exprUsesIdentifierValue(bin.right, name),
            .call_expr => |call| blk: {
                for (call.args) |arg| {
                    if (exprUsesIdentifierValue(arg, name)) break :blk true;
                }
                break :blk false;
            },
            .if_expr => |ife| blk: {
                if (exprUsesIdentifierValue(ife.cond, name)) break :blk true;
                if (blockUsesIdentifierValue(ife.then_block, name)) break :blk true;
                if (ife.else_block) |else_block| {
                    if (blockUsesIdentifierValue(else_block, name)) break :blk true;
                }
                break :blk false;
            },
            .switch_expr => |swe| blk: {
                if (exprUsesIdentifierValue(swe.val, name)) break :blk true;
                for (swe.cases) |case| {
                    if (blockUsesIdentifierValue(case.body, name)) break :blk true;
                }
                break :blk false;
            },
            .match_expr => |mat| blk: {
                if (exprUsesIdentifierValue(mat.val, name)) break :blk true;
                for (mat.cases) |case| {
                    if (case.guard) |guard| {
                        if (exprUsesIdentifierValue(guard, name)) break :blk true;
                    }
                    if (blockUsesIdentifierValue(case.body, name)) break :blk true;
                }
                break :blk false;
            },
            .try_expr => |trye| exprUsesIdentifierValue(trye.expr, name),
            .struct_literal => |lit| blk: {
                for (lit.fields) |field| {
                    if (exprUsesIdentifierValue(field.value, name)) break :blk true;
                }
                break :blk false;
            },
            .enum_literal => |lit| blk: {
                for (lit.fields) |field| {
                    if (exprUsesIdentifierValue(field.value, name)) break :blk true;
                }
                break :blk false;
            },
            .tuple_literal => |lit| blk: {
                for (lit.elements) |elem| {
                    if (exprUsesIdentifierValue(elem, name)) break :blk true;
                }
                break :blk false;
            },
            .array_literal => |lit| blk: {
                for (lit.elements) |elem| {
                    if (exprUsesIdentifierValue(elem, name)) break :blk true;
                }
                break :blk false;
            },
            .repeat_array_literal => |lit| exprUsesIdentifierValue(lit.value, name),
            .index_expr => |idx| exprUsesIdentifierValue(idx.index, name),
            .slice_expr => |slc| exprUsesIdentifierValue(slc.start, name) or exprUsesIdentifierValue(slc.end, name),
            else => false,
        };
    }

    fn stmtUsesIdentifierValue(stmt: *const ast.Node, name: []const u8) bool {
        return switch (stmt.*) {
            .let_stmt => |let| exprUsesIdentifierValue(let.value, name),
            .let_else_stmt => |let| exprUsesIdentifierValue(let.value, name) or blockUsesIdentifierValue(let.else_block, name),
            .let_destructure_stmt => |let| exprUsesIdentifierValue(let.value, name),
            .const_stmt => |c| exprUsesIdentifierValue(c.value, name),
            .assign_stmt => |assign| exprUsesIdentifierValue(assign.value, name),
            .expr_stmt => |expr| exprUsesIdentifierValue(expr, name),
            .return_stmt => |ret| if (ret.value) |value| exprUsesIdentifierValue(value, name) else false,
            .for_stmt => |f| exprUsesIdentifierValue(f.start, name) or (if (f.end) |end_expr| exprUsesIdentifierValue(end_expr, name) else false) or blockUsesIdentifierValue(f.body, name),
            .while_stmt => |w| exprUsesIdentifierValue(w.cond, name) or blockUsesIdentifierValue(w.body, name),
            .block_stmt => |blk| blockUsesIdentifierValue(blk.body, name),
            else => false,
        };
    }

    fn blockUsesIdentifierValue(body: []const *ast.Node, name: []const u8) bool {
        for (body) |stmt| {
            if (stmtUsesIdentifierValue(stmt, name)) return true;
        }
        return false;
    }

    fn findEnumVariant(e: *const ast.EnumDecl, name: []const u8) ?ast.EnumVariant {
        for (e.variants) |variant| {
            if (std.mem.eql(u8, variant.name, name)) return variant;
        }
        return null;
    }

    fn enumNameMatchesDecl(pattern_name: []const u8, decl_name: []const u8) bool {
        if (std.mem.eql(u8, pattern_name, decl_name)) return true;
        if (decl_name.len <= pattern_name.len) return false;
        if (!std.mem.startsWith(u8, decl_name, pattern_name)) return false;
        return decl_name[pattern_name.len] == '_';
    }

    fn concreteTypeName(ty: *const ast.Type) ?[]const u8 {
        return lowering_rules.concreteTypeName(ty);
    }

    fn traitExtendsTrait(self: *TypeChecker, trait_name: []const u8, target_trait: []const u8) bool {
        if (std.mem.eql(u8, trait_name, target_trait)) return true;
        const decl = self.traits.get(trait_name) orelse return false;
        for (decl.supertraits) |supertrait| {
            if (self.traitExtendsTrait(supertrait, target_trait)) return true;
        }
        return false;
    }

    fn findTraitMethod(self: *TypeChecker, trait_name: []const u8, method_name: []const u8) ?ast.TraitMethod {
        const decl = self.traits.get(trait_name) orelse return null;
        for (decl.supertraits) |supertrait| {
            if (self.findTraitMethod(supertrait, method_name)) |method| return method;
        }
        for (decl.methods) |method| {
            if (std.mem.eql(u8, method.name, method_name)) return method;
        }
        return null;
    }

    fn findTraitOwnMethod(self: *TypeChecker, trait_name: []const u8, method_name: []const u8) ?ast.TraitMethod {
        const decl = self.traits.get(trait_name) orelse return null;
        for (decl.methods) |method| {
            if (std.mem.eql(u8, method.name, method_name)) return method;
        }
        return null;
    }

    fn findTraitDeclaringMethod(self: *TypeChecker, trait_name: []const u8, method_name: []const u8) ?[]const u8 {
        const decl = self.traits.get(trait_name) orelse return null;
        for (decl.supertraits) |supertrait| {
            if (self.findTraitDeclaringMethod(supertrait, method_name)) |owner| return owner;
        }
        for (decl.methods) |method| {
            if (std.mem.eql(u8, method.name, method_name)) return trait_name;
        }
        return null;
    }

    fn typeDirectlyImplementsTrait(self: *TypeChecker, type_name: []const u8, trait_name: []const u8) bool {
        var key_buf: [512]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "{s}|{s}", .{ trait_name, type_name }) catch return false;
        return self.trait_impls.contains(key);
    }

    fn traitMethodSymbolAlloc(self: *TypeChecker, impl_trait: []const u8, type_name: []const u8, method_name: []const u8) TypeError![]const u8 {
        return std.fmt.allocPrint(self.allocator, "{s}__{s}_{s}", .{ type_name, impl_trait, method_name }) catch return TypeError.OutOfMemory;
    }

    fn functionOrImportedSignatureParamCount(self: *TypeChecker, symbol: []const u8) ?usize {
        if (self.funcs.get(symbol)) |func| return func.params.len;
        if (self.imported_function_signatures.get(symbol)) |signature| return signature.params.len;
        return null;
    }

    fn resolveTraitMethodSymbolForType(
        self: *TypeChecker,
        type_name: []const u8,
        target_trait: ?[]const u8,
        method_name: []const u8,
        arg_count: usize,
    ) TypeError!?[]const u8 {
        if (target_trait) |trait_name| {
            if (!self.typeDirectlyImplementsTrait(type_name, trait_name) and !self.typeImplementsTraitName(type_name, trait_name)) return null;
            const declaring_trait = self.findTraitDeclaringMethod(trait_name, method_name) orelse return null;
            const symbol = try self.traitMethodSymbolAlloc(declaring_trait, type_name, method_name);
            const param_count = self.functionOrImportedSignatureParamCount(symbol) orelse return null;
            if (param_count != arg_count) return null;
            return symbol;
        }

        var it = self.trait_impls.iterator();
        var found: ?[]const u8 = null;
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            const sep = std.mem.indexOfScalar(u8, key, '|') orelse continue;
            const impl_trait = key[0..sep];
            const impl_type = key[sep + 1 ..];
            if (!std.mem.eql(u8, impl_type, type_name)) continue;
            const declaring_trait = self.findTraitDeclaringMethod(impl_trait, method_name) orelse continue;

            const symbol = try self.traitMethodSymbolAlloc(declaring_trait, type_name, method_name);
            const param_count = self.functionOrImportedSignatureParamCount(symbol) orelse continue;
            if (param_count != arg_count) continue;
            if (found) |existing| {
                if (std.mem.eql(u8, existing, symbol)) continue;
                self.setError("Ambiguous trait method `{s}` for type `{s}`", .{ method_name, type_name });
                return TypeError.TypeMismatch;
            }
            found = symbol;
        }
        return found;
    }

    fn typeImplementsTraitName(self: *TypeChecker, type_name: []const u8, trait_name: []const u8) bool {
        if (self.typeDirectlyImplementsTrait(type_name, trait_name)) return true;
        var it = self.trait_impls.iterator();
        while (it.next()) |entry| {
            const impl_key = entry.key_ptr.*;
            const sep = std.mem.indexOfScalar(u8, impl_key, '|') orelse continue;
            const impl_trait = impl_key[0..sep];
            const impl_type = impl_key[sep + 1 ..];
            if (std.mem.eql(u8, impl_type, type_name) and self.traitExtendsTrait(impl_trait, trait_name)) return true;
        }
        return false;
    }

    fn typeImplementsTrait(self: *TypeChecker, ty: *const ast.Type, trait_name: []const u8) bool {
        if (dynTraitName(@constCast(ty))) |dyn_name| {
            return self.traitExtendsTrait(dyn_name, trait_name);
        }
        const type_name = concreteTypeName(ty) orelse return false;
        return self.typeImplementsTraitName(type_name, trait_name);
    }

    fn normalizeAbiTypeName(name: []const u8) []const u8 {
        var ty = std.mem.trim(u8, name, " \t\r");
        while (ty.len > 0 and (ty[0] == '^' or ty[0] == '&' or ty[0] == '*')) {
            ty = ty[1..];
        }
        return ty;
    }

    fn isPointerAbiType(name: []const u8) bool {
        return lowering_rules.isPointerAbiTypeName(name);
    }

    fn isIntegerAbiType(name: []const u8) bool {
        return lowering_rules.isIntegerAbiTypeName(name);
    }

    fn setTypeFromAbiReturn(allocator: std.mem.Allocator, ret: *ast.Type, abi_ret_ty: []const u8) void {
        const name = normalizeAbiTypeName(abi_ret_ty);
        if (isPointerAbiType(abi_ret_ty)) {
            const ty = normalizeAbiTypeName(abi_ret_ty);
            const inner = allocator.create(ast.Type) catch {
                ret.* = .{ .primitive = .void_type };
                return;
            };
            if (std.mem.eql(u8, ty, "u8")) {
                inner.* = .{ .primitive = .u8 };
            } else if (std.mem.eql(u8, ty, "i32")) {
                inner.* = .{ .primitive = .i32 };
            } else if (std.mem.eql(u8, ty, "u32")) {
                inner.* = .{ .primitive = .u32 };
            } else if (std.mem.eql(u8, ty, "i64")) {
                inner.* = .{ .primitive = .i64 };
            } else if (std.mem.eql(u8, ty, "u64")) {
                inner.* = .{ .primitive = .u64 };
            } else if (std.mem.eql(u8, ty, "void") or std.mem.eql(u8, ty, "ptr")) {
                inner.* = .{ .primitive = .void_type };
            } else {
                inner.* = .{ .primitive = .void_type };
            }
            ret.* = .{ .pointer = inner };
        } else if (isIntegerAbiType(name)) {
            if (std.mem.eql(u8, name, "i8")) ret.* = .{ .primitive = .i8 } else if (std.mem.eql(u8, name, "i16")) ret.* = .{ .primitive = .i16 } else if (std.mem.eql(u8, name, "i32")) ret.* = .{ .primitive = .i32 } else if (std.mem.eql(u8, name, "i64")) ret.* = .{ .primitive = .i64 } else if (std.mem.eql(u8, name, "isize")) ret.* = .{ .primitive = .isize } else if (std.mem.eql(u8, name, "u8")) ret.* = .{ .primitive = .u8 } else if (std.mem.eql(u8, name, "u16")) ret.* = .{ .primitive = .u16 } else if (std.mem.eql(u8, name, "u32")) ret.* = .{ .primitive = .u32 } else if (std.mem.eql(u8, name, "u64")) ret.* = .{ .primitive = .u64 } else if (std.mem.eql(u8, name, "usize")) ret.* = .{ .primitive = .usize } else ret.* = .{ .primitive = .integer };
        } else if (std.mem.eql(u8, name, "f32")) {
            ret.* = .{ .primitive = .f32 };
        } else if (std.mem.eql(u8, name, "f64")) {
            ret.* = .{ .primitive = .f64 };
        } else if (std.mem.eql(u8, name, "bool")) {
            ret.* = .{ .primitive = .boolean };
        } else if (std.mem.eql(u8, name, "ptr")) {
            ret.* = .{ .primitive = .raw_ptr };
        } else {
            ret.* = .{ .primitive = .void_type };
        }
    }

    /// Identity for .sai contract parameters: arity plus the ABI type
    /// spelling and capability markers of each parameter.
    fn externParamsEqual(a: contract_parser.ExternalFunction, b: contract_parser.ExternalFunction) bool {
        // A member's identity is its fixed parameters plus the
        // variadic marker: `fn pick(ptr)` and `fn pick(ptr, ...)` are
        // two declarations, not one.
        if (a.is_variadic != b.is_variadic) return false;
        if (a.params.len != b.params.len) return false;
        for (a.params, b.params) |pa, pb| {
            if (pa.is_borrow != pb.is_borrow or pa.is_move != pb.is_move or pa.is_raw != pb.is_raw) return false;
            if (!std.mem.eql(u8, std.mem.trim(u8, pa.ty, " \t\r"), std.mem.trim(u8, pb.ty, " \t\r"))) return false;
        }
        return true;
    }

    fn externMemberKey(self: *TypeChecker, f: contract_parser.ExternalFunction) ![]const u8 {
        var tag = std.array_list.Managed(u8).init(self.allocator);
        defer tag.deinit();
        if (f.params.len == 0) {
            try tag.append('v');
        } else {
            for (f.params, 0..) |param, i| {
                if (i > 0) try tag.append('_');
                for (std.mem.trim(u8, param.ty, " \t\r")) |ch| {
                    try tag.append(if (std.ascii.isAlphanumeric(ch)) ch else '_');
                }
                if (param.is_borrow) try tag.append('b');
                if (param.is_move) try tag.append('m');
                if (param.is_raw) try tag.append('r');
            }
        }
        if (f.is_variadic) {
            // Render the variadic marker exactly as the FuncDecl
            // member key renders the trailing VaList parameter, so a
            // contract member and its definition key identically and
            // candidate collection dedupes them into one member.
            try tag.appendSlice("_va_list");
        }
        return std.fmt.allocPrint(self.allocator, "{s}__ov_{s}", .{ f.name, tag.items });
    }

    /// Register one .sai contract declaration. Identical redeclarations
    /// (same name, same parameters, same return) dedupe silently — sa_std
    /// itself declares some contracts in two files (e.g. sa_print_bytes),
    /// and source expansion may inline several files into one load, so the
    /// duplicate boundary cannot be per-file. A second declaration with
    /// different parameters promotes the name to an overload set whose
    /// members live in extern_funcs under their member keys; the same
    /// parameters with a different return type are a loud conflict.
    fn registerExternContract(self: *TypeChecker, f: contract_parser.ExternalFunction) !void {
        if (self.extern_overload_sets.getPtr(f.name)) |set| {
            for (set.items) |existing| {
                if (externParamsEqual(existing, f)) {
                    if (!std.mem.eql(u8, existing.ret_ty, f.ret_ty)) {
                        self.setError("Redeclaration: extern contract `{s}` is declared with the same parameters but a different return type", .{f.name});
                        return TypeError.Redeclaration;
                    }
                    return;
                }
            }
            const key = try self.externMemberKey(f);
            if (self.extern_funcs.contains(key)) {
                self.setError("Redeclaration: extern contract `{s}` is already defined", .{f.name});
                return TypeError.Redeclaration;
            }
            try set.append(f);
            try self.extern_funcs.put(key, f);
            return;
        }
        if (self.extern_funcs.get(f.name)) |existing| {
            if (externParamsEqual(existing, f)) {
                if (!std.mem.eql(u8, existing.ret_ty, f.ret_ty)) {
                    self.setError("Redeclaration: extern contract `{s}` is declared with the same parameters but a different return type", .{f.name});
                    return TypeError.Redeclaration;
                }
                return;
            }
            var set = std.array_list.Managed(contract_parser.ExternalFunction).init(self.allocator);
            errdefer set.deinit();
            try set.append(existing);
            try set.append(f);
            _ = self.extern_funcs.remove(f.name);
            try self.extern_funcs.put(try self.externMemberKey(existing), existing);
            try self.extern_funcs.put(try self.externMemberKey(f), f);
            try self.extern_overload_sets.put(f.name, set);
            return;
        }
        try self.extern_funcs.put(f.name, f);
    }

    pub fn loadContracts(self: *TypeChecker, sai_content: []const u8, sal_content: []const u8) !void {
        var parser = contract_parser.ContractParser.init(self.allocator);

        const funcs = try parser.parseSai(sai_content);
        for (funcs) |f| {
            try self.registerExternContract(f);
        }

        const layouts = try parser.parseSal(sal_content);
        for (layouts) |l| {
            try self.layout_defines.put(l.name, l);
        }
    }

    pub fn registerImportedMacro(self: *TypeChecker, name: []const u8, arity: usize, leading_outputs: usize, import_path: ?[]const u8, borrowed_arg_mask: u64, address_slot_arg_mask: u64, assigned_output_mask: u64, direct_callees: []const []const u8) !void {
        try self.imported_macros.put(name, .{
            .arity = arity,
            .leading_outputs = leading_outputs,
            .import_path = import_path,
            .borrowed_arg_mask = borrowed_arg_mask,
            .address_slot_arg_mask = address_slot_arg_mask,
            .assigned_output_mask = assigned_output_mask,
            .direct_callees = direct_callees,
        });
    }

    /// Extern variadic batch: does this type mention VaList anywhere?
    /// Whether a VALUE of this type is (or directly embeds) the VaList
    /// object itself, as opposed to a function value whose signature
    /// merely mentions VaList in a parameter. Used by the let-binding
    /// copy guard: binding a variadic FUNCTION to a name is fine;
    /// binding its VaList is not.
    fn typeIsVaListValue(ty: *const ast.Type) bool {
        return switch (ty.*) {
            .primitive => |prim| prim == .va_list,
            .pointer => |inner| typeIsVaListValue(inner),
            .borrow => |inner| typeIsVaListValue(inner),
            .future => |inner| typeIsVaListValue(inner),
            .array => |arr| typeIsVaListValue(arr.elem),
            .tuple => |tup| blk: {
                for (tup.elems) |elem| {
                    if (typeIsVaListValue(elem)) break :blk true;
                }
                break :blk false;
            },
            .user_defined => |ud| blk: {
                for (ud.generics) |g| {
                    if (typeIsVaListValue(g)) break :blk true;
                }
                break :blk false;
            },
            else => false,
        };
    }

    fn typeContainsVaList(ty: *const ast.Type) bool {
        return switch (ty.*) {
            .primitive => |prim| prim == .va_list,
            .pointer => |inner| typeContainsVaList(inner),
            .borrow => |inner| typeContainsVaList(inner),
            .future => |inner| typeContainsVaList(inner),
            .array => |arr| typeContainsVaList(arr.elem),
            .tuple => |tup| blk: {
                for (tup.elems) |elem| {
                    if (typeContainsVaList(elem)) break :blk true;
                }
                break :blk false;
            },
            .closure => |c| blk: {
                for (c.params) |p| {
                    if (typeContainsVaList(p)) break :blk true;
                }
                break :blk typeContainsVaList(c.ret);
            },
            .fn_ptr => |f| blk: {
                for (f.params) |p| {
                    if (typeContainsVaList(p)) break :blk true;
                }
                break :blk typeContainsVaList(f.ret);
            },
            .user_defined => |ud| blk: {
                for (ud.generics) |g| {
                    if (typeContainsVaList(g)) break :blk true;
                }
                break :blk false;
            },
            .infer => false,
        };
    }

    /// Extern variadic batch: VaList is a non-copyable handle bound to
    /// one variadic definition's frame. It may appear in exactly one
    /// position: the trailing parameter of an exported extern "C"
    /// variadic definition. Everywhere else is a loud error.
    fn validateVaListPlacement(self: *TypeChecker, fd: *const ast.FuncDecl) TypeError!void {
        if (typeContainsVaList(fd.ret_ty)) {
            self.setError("VaList may not be used as a return type (function `{s}`)", .{fd.name});
            return TypeError.TypeMismatch;
        }
        for (fd.params, 0..) |p, i| {
            const is_trailing_valist = fd.is_variadic and fd.is_extern and !fd.is_decl_only and
                i + 1 == fd.params.len and p.ty.* == .primitive and p.ty.primitive == .va_list;
            if (is_trailing_valist) continue;
            if (typeContainsVaList(p.ty)) {
                self.setError("VaList may only appear as the trailing parameter of an exported extern \"C\" variadic definition (function `{s}`, parameter `{s}`)", .{ fd.name, p.name });
                return TypeError.TypeMismatch;
            }
        }
    }

    /// Function overloading registration. Top-level FuncDecls are grouped by
    /// name; a group whose members all share one parameter signature follows
    /// the legacy path (including the extern prototype/definition pair rule),
    /// while a group with two or more distinct parameter signatures becomes
    /// an overload set: every member is renamed to its member key
    /// (`<name>__ov_<tag>`) and registered under that key, and the set is
    /// recorded under the plain name for call-site resolution. Two members
    /// with identical parameter signatures are a redeclaration — differing
    /// only in return type does not rescue them.
    fn registerTopLevelFunctions(self: *TypeChecker, program: *ast.Node) !void {
        var groups = std.StringHashMap(std.array_list.Managed(*ast.FuncDecl)).init(self.allocator);
        defer {
            var it = groups.valueIterator();
            while (it.next()) |list| list.deinit();
            groups.deinit();
        }
        var order = std.array_list.Managed([]const u8).init(self.allocator);
        defer order.deinit();
        for (program.program.decls) |decl| {
            if (decl.* != .func_decl) continue;
            const fd = &decl.func_decl;
            if (std.mem.indexOf(u8, fd.name, "__ov_") != null) {
                self.setError("function name `{s}` uses the reserved `__ov_` marker (reserved for overload member symbols)", .{fd.name});
                return TypeError.CompileError;
            }
            const gop = try groups.getOrPut(fd.name);
            if (!gop.found_existing) {
                gop.value_ptr.* = std.array_list.Managed(*ast.FuncDecl).init(self.allocator);
                try order.append(fd.name);
            }
            try gop.value_ptr.append(fd);
        }
        for (order.items) |name| {
            try self.registerFunctionGroup(name, groups.get(name).?.items);
        }
    }

    fn registerFunctionGroup(self: *TypeChecker, name: []const u8, group: []*ast.FuncDecl) !void {
        const Class = struct {
            rep: *ast.FuncDecl,
            others: std.array_list.Managed(*ast.FuncDecl),
        };
        var classes = std.array_list.Managed(Class).init(self.allocator);
        defer {
            for (classes.items) |*class| class.others.deinit();
            classes.deinit();
        }
        for (group) |fd| {
            var matched: ?*Class = null;
            for (classes.items) |*class| {
                if (overloadClassSignaturesEqual(class.rep, fd)) {
                    matched = class;
                    break;
                }
            }
            if (matched) |class| {
                // Identical parameter signature: only the C-style extern
                // prototype/definition pair may share a class.
                if (externPrototypePairsWith(class.rep, fd)) {
                    if (class.rep.is_decl_only and !fd.is_decl_only) {
                        try class.others.append(class.rep);
                        class.rep = fd;
                    } else {
                        try class.others.append(fd);
                    }
                    continue;
                }
                if (!strictTypesEqual(class.rep.ret_ty, fd.ret_ty)) {
                    self.setError("Redeclaration: function `{s}` is already defined (overloads may not differ by return type only)", .{name});
                } else {
                    self.setError("Redeclaration: function `{s}` is already defined", .{name});
                }
                return TypeError.Redeclaration;
            }
            try classes.append(.{ .rep = fd, .others = std.array_list.Managed(*ast.FuncDecl).init(self.allocator) });
        }
        if (classes.items.len == 1) {
            try self.ensureTopLevelNameUnused(name, "function");
            try self.funcs.put(name, classes.items[0].rep);
            return;
        }
        try self.ensureTopLevelNameUnused(name, "function");
        var set = std.array_list.Managed(*ast.FuncDecl).init(self.allocator);
        errdefer set.deinit();
        for (classes.items) |class| {
            const key = try self.overloadMemberKey(name, class.rep.params);
            if (self.funcs.contains(key)) {
                self.setError("Redeclaration: function `{s}` is already defined", .{name});
                return TypeError.Redeclaration;
            }
            class.rep.name = key;
            for (class.others.items) |proto| proto.name = key;
            try self.funcs.put(key, class.rep);
            try self.overload_decl_plain_name.put(class.rep, name);
            try set.append(class.rep);
        }
        try self.func_overload_sets.put(name, set);
    }

    pub fn checkProgram(self: *TypeChecker, program: *ast.Node) !void {
        if (program.* != .program) return TypeError.CompileError;

        const global_scope = try Scope.init(self.allocator, null);
        try self.scope_pool.append(global_scope);
        self.global_scope = global_scope;

        for (self.injected_scope_bindings) |binding| {
            try self.defineSymbol(global_scope, binding.name, binding.ty, binding.is_const);
        }

        for (program.program.decls) |decl| {
            if (decl.* == .using_decl) {
                const normalized = try self.normalizeUsingPath(decl.using_decl.path);
                try global_scope.using_modules.append(normalized);
            }
        }

        // Register structs first
        for (program.program.decls) |decl| {
            if (decl.* == .struct_decl) {
                try self.ensureTopLevelNameUnused(decl.struct_decl.name, "struct");
                try self.structs.put(decl.struct_decl.name, &decl.struct_decl);
            } else if (decl.* == .type_alias_decl) {
                try self.ensureTopLevelNameUnused(decl.type_alias_decl.name, "type alias");
                try self.type_aliases.put(decl.type_alias_decl.name, &decl.type_alias_decl);
            } else if (decl.* == .enum_decl) {
                try self.ensureTopLevelNameUnused(decl.enum_decl.name, "enum");
                try self.enums.put(decl.enum_decl.name, &decl.enum_decl);
            } else if (decl.* == .trait_decl) {
                try self.ensureTopLevelNameUnused(decl.trait_decl.name, "trait");
                try self.traits.put(decl.trait_decl.name, &decl.trait_decl);
            }
        }

        for (program.program.decls) |decl| {
            if (decl.* == .trait_decl) {
                for (decl.trait_decl.supertraits) |supertrait| {
                    if (!self.traits.contains(supertrait)) return TypeError.UndefinedVariable;
                }
            }
        }

        // Extern variadic batch: VaList placement validation for every
        // function-shaped declaration (definitions, prototypes, methods).
        for (program.program.decls) |decl| {
            if (decl.* == .func_decl) {
                try self.validateVaListPlacement(&decl.func_decl);
            } else if (decl.* == .struct_decl) {
                for (decl.struct_decl.fields) |field| {
                    if (typeContainsVaList(field.ty)) {
                        self.setError("VaList may not be a struct field type (struct `{s}`, field `{s}`)", .{ decl.struct_decl.name, field.name });
                        return TypeError.TypeMismatch;
                    }
                }
            } else if (decl.* == .impl_decl) {
                for (decl.impl_decl.methods) |method| {
                    if (method.* == .func_decl) try self.validateVaListPlacement(&method.func_decl);
                }
            }
        }

        // Register functions first
        // Register functions first (overload-aware grouping; see
        // registerTopLevelFunctions). The legacy per-decl registration is
        // subsumed by the grouping pass, which preserves singleton and
        // extern prototype-pair behaviour exactly.
        try self.registerTopLevelFunctions(program);
        for (program.program.decls) |decl| {
            if (decl.* == .func_decl) {
                continue;
            } else if (decl.* == .overload_decl) {
                const type_name = try self.typeName(decl.overload_decl.target_ty);
                for (decl.overload_decl.methods) |method| {
                    if (method.* != .func_decl) {
                        self.setError("overload `{s}` contains a non-function member", .{type_name});
                        return TypeError.CompileError;
                    }
                    const op_name = switch (method.func_decl.operator orelse {
                        self.setError("overload `{s}` methods must use an operator function", .{type_name});
                        return TypeError.CompileError;
                    }) {
                        .add => "op_add",
                        .sub => "op_sub",
                        .mul => "op_mul",
                        .div => "op_div",
                        else => {
                            self.setError("unsupported overload operator `{s}` in overload `{s}`", .{ method.func_decl.name, type_name });
                            return TypeError.CompileError;
                        },
                    };
                    const key = try std.fmt.allocPrint(self.allocator, "{s}|{s}", .{ type_name, op_name });
                    var list = self.overloads.get(key) orelse std.array_list.Managed([]const u8).init(self.allocator);
                    const symbol = try std.fmt.allocPrint(self.allocator, "{s}__{s}", .{ type_name, op_name });
                    try list.append(symbol);
                    try self.overloads.put(key, list);
                    try self.funcs.put(symbol, &method.func_decl);
                }
            }
        }

        // Register impl methods
        for (program.program.decls) |decl| {
            if (decl.* == .impl_decl) {
                const target_name = try self.typeName(decl.impl_decl.target_ty);
                if (decl.impl_decl.trait_name) |trait_name| {
                    const impl_key = try std.fmt.allocPrint(self.allocator, "{s}|{s}", .{ trait_name, target_name });
                    if (self.trait_impls.contains(impl_key)) {
                        self.setError("Redeclaration: impl `{s}` for `{s}` is already defined", .{ trait_name, target_name });
                        return TypeError.Redeclaration;
                    }
                    try self.trait_impls.put(impl_key, {});
                }
                for (decl.impl_decl.methods) |method| {
                    if (method.* != .func_decl) return TypeError.CompileError;
                    const method_key = if (decl.impl_decl.trait_name) |trait_name|
                        try self.traitMethodSymbolAlloc(trait_name, target_name, method.func_decl.name)
                    else
                        try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ target_name, method.func_decl.name });
                    if (self.funcs.contains(method_key)) {
                        self.setError("Redeclaration: method `{s}` for `{s}` is already defined", .{ method.func_decl.name, target_name });
                        return TypeError.Redeclaration;
                    }
                    try self.funcs.put(method_key, &method.func_decl);
                }
            }
        }

        // Type check overload bodies as regular functions so their internals are validated.
        for (program.program.decls) |decl| {
            if (decl.* == .overload_decl) {
                for (decl.overload_decl.methods) |method| {
                    if (method.* != .func_decl) return TypeError.CompileError;
                    try self.checkFunc(&method.func_decl);
                }
            }
        }

        // Register macros
        for (program.program.decls) |decl| {
            if (decl.* == .macro_decl) {
                try self.ensureTopLevelNameUnused(decl.macro_decl.name, "macro");
                try self.macros.put(decl.macro_decl.name, &decl.macro_decl);
            }
        }

        // Type check macro bodies so codegen can rely on expr_types for
        // lowered macro expressions, especially binary ops inside assignments.
        for (program.program.decls) |decl| {
            if (decl.* == .macro_decl) {
                try self.checkMacro(&decl.macro_decl);
            }
        }

        // Register top-level consts into the global scope so functions/tests can use them.
        for (program.program.decls) |decl| {
            if (decl.* == .const_stmt) {
                const c = &decl.const_stmt;
                try self.ensureTopLevelNameUnused(c.name, "const");
                const val_ty = try self.checkExpr(c.value, global_scope);
                const declared_ty = c.ty orelse val_ty;
                if (c.ty != null and val_ty.* == .array and declared_ty.* == .array) {
                    self.expr_types.put(c.value, declared_ty) catch return TypeError.OutOfMemory;
                }
                if (!self.valueAssignableTo(declared_ty, val_ty)) {
                    self.setError("TypeMismatch in const {s}: declared tag={s}, val tag={s}", .{ c.name, @tagName(declared_ty.*), @tagName(val_ty.*) });
                    return TypeError.TypeMismatch;
                }
                try self.defineSymbol(global_scope, c.name, declared_ty, true);
            }
        }

        // J-1: registered sublanguage declarations. Registration
        // nodes are validated against the plugin's bound kinds;
        // payload declarations enter the shared top-level name table
        // under their own name and are checked by their kind's
        // checker, reporting through the shared error channel.
        for (program.program.decls) |decl| {
            if (decl.* == .sublanguage_registration) {
                const parser_mod = @import("parser.zig");
                if (!parser_mod.Parser.isBoundSublanguageKind(decl.sublanguage_registration.kind)) {
                    self.setError("SublanguageNotBound: no sub-parser is registered for declaration kind `{s}`", .{decl.sublanguage_registration.kind});
                    return TypeError.CompileError;
                }
            } else if (decl.* == .sublanguage_decl) {
                const sub = &decl.sublanguage_decl;
                try self.ensureTopLevelNameUnused(sub.name, sub.kind);
                switch (sub.payload) {
                    .shader => |*shader_decl| {
                        var diag = sublanguage_shader.Diagnostic{};
                        sublanguage_shader.checkShaderDecl(self.allocator, shader_decl, &diag) catch |err| switch (err) {
                            error.CheckFailed => {
                                self.setError("{s}", .{diag.text});
                                return TypeError.TypeMismatch;
                            },
                            error.OutOfMemory => return TypeError.OutOfMemory,
                        };
                    },
                }
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

        // Goroutine syntax batch: every Chan::new must have been
        // validated by an annotated let binding (see checkStmtImpl).
        var chan_new_it = self.chan_new_seen.keyIterator();
        while (chan_new_it.next()) |node| {
            if (!self.chan_new_validated.contains(node.*)) {
                self.setError("Chan::new must be bound directly by a let with a Chan<T> annotation so the payload type is known", .{});
                return TypeError.TypeMismatch;
            }
        }

        // J-5: independent check hooks run last, over the fully
        // checked program. A hook is read-only by construction: it
        // receives the checker and the AST and may only produce a
        // named diagnostic (HookDiagnostic) or nothing.
        for (program.program.decls) |decl| {
            if (decl.* == .check_hook_decl) {
                const hook_name = decl.check_hook_decl.name;
                const hook = check_hooks.lookup(hook_name) orelse {
                    self.setError("UnknownCheckHook: no check hook is registered under the name `{s}`", .{hook_name});
                    return TypeError.CompileError;
                };
                var diag = check_hooks.Diagnostic{};
                hook(self, program, &diag) catch |err| switch (err) {
                    error.HookDiagnostic => {
                        self.setError("{s}", .{diag.text});
                        return TypeError.TypeMismatch;
                    },
                    error.OutOfMemory => return TypeError.OutOfMemory,
                };
            }
        }
    }

    fn operatorName(op: ast.BinaryOp) ?[]const u8 {
        return switch (op) {
            .add => "+",
            .sub => "-",
            .mul => "*",
            .div => "/",
            else => null,
        };
    }

    /// J-4: count a user macro's leading output parameters with the
    /// exact rule imported SA macros use (plugin_imported_macros:
    /// a parameter counts while it is still in the leading run and
    /// its name satisfies isLeadingOutputMacroParam).
    fn userMacroLeadingOutputCount(mac: *const ast.MacroDecl) usize {
        const imported_macro_names = @import("plugin_imported_macros.zig");
        var count: usize = 0;
        for (mac.params) |param| {
            if (!imported_macro_names.isLeadingOutputMacroParam(param)) break;
            count += 1;
        }
        return count;
    }

    fn checkMacro(self: *TypeChecker, macro_decl: *ast.MacroDecl) !void {
        const scope = try Scope.init(self.allocator, self.global_scope);
        try self.scope_pool.append(scope);

        const void_ty = try self.allocator.create(ast.Type);
        void_ty.* = .{ .primitive = .void_type };
        try self.defineSymbol(scope, "return_ty_sentinel", void_ty, true);

        const infer_ty = try self.makeInferType();
        for (macro_decl.params, 0..) |param, index| {
            // J-3: a parameter with a declared type is bound at that
            // type, so the declared type is visible (and enforced)
            // inside the macro body; untyped parameters keep `.infer`.
            const param_ty = macro_decl.declaredParamType(index) orelse infer_ty;
            try self.defineSymbol(scope, param, param_ty, false);
        }

        try self.checkBlock(macro_decl.body, scope, void_ty, null, null);
    }

    fn macroParamConsumption(self: *TypeChecker, macro_decl: *const ast.MacroDecl, param_index: usize) TypeError!control_flow_rules.MacroParamConsumption {
        var visiting = std.AutoHashMap(MacroConsumptionKey, void).init(self.allocator);
        defer visiting.deinit();
        return try self.macroParamConsumptionRecursive(macro_decl, param_index, &visiting);
    }

    fn macroParamIsTrySource(self: *TypeChecker, macro_decl: *const ast.MacroDecl, param_index: usize) TypeError!bool {
        var visiting = std.AutoHashMap(MacroConsumptionKey, void).init(self.allocator);
        defer visiting.deinit();
        return try self.macroParamIsTrySourceRecursive(macro_decl, param_index, &visiting);
    }

    fn macroHasTry(self: *TypeChecker, macro_decl: *const ast.MacroDecl) TypeError!bool {
        var visiting = std.AutoHashMap(*const ast.MacroDecl, void).init(self.allocator);
        defer visiting.deinit();
        return try self.macroHasTryRecursive(macro_decl, &visiting);
    }

    fn macroHasTryRecursive(
        self: *TypeChecker,
        macro_decl: *const ast.MacroDecl,
        visiting: *std.AutoHashMap(*const ast.MacroDecl, void),
    ) TypeError!bool {
        if (visiting.contains(macro_decl)) return false;
        try visiting.put(macro_decl, {});
        defer _ = visiting.remove(macro_decl);
        if (control_flow_rules.macroBodyHasTry(macro_decl.body)) return true;
        for (macro_decl.body) |node| {
            if (try self.macroNodeCallsTryMacro(node, visiting)) return true;
        }
        return false;
    }

    fn macroNodeCallsTryMacro(
        self: *TypeChecker,
        node: *const ast.Node,
        visiting: *std.AutoHashMap(*const ast.MacroDecl, void),
    ) TypeError!bool {
        return switch (node.*) {
            .call_expr => |call| if (self.macros.get(call.func_name)) |nested| self.macroHasTryRecursive(nested, visiting) else false,
            .expr_stmt => |expr| self.macroNodeCallsTryMacro(expr, visiting),
            .assign_stmt => |assign| self.macroNodeCallsTryMacro(assign.value, visiting),
            .let_stmt => |let| self.macroNodeCallsTryMacro(let.value, visiting),
            .return_stmt => |ret| if (ret.value) |value| self.macroNodeCallsTryMacro(value, visiting) else false,
            .block_stmt => |block| blk: {
                for (block.body) |child| if (try self.macroNodeCallsTryMacro(child, visiting)) break :blk true;
                break :blk false;
            },
            .unsafe_expr => |unsafe_expr| blk: {
                for (unsafe_expr.body) |child| if (try self.macroNodeCallsTryMacro(child, visiting)) break :blk true;
                break :blk false;
            },
            .if_expr => |ife| blk: {
                for (ife.then_block) |child| if (try self.macroNodeCallsTryMacro(child, visiting)) break :blk true;
                if (ife.else_block) |else_block| for (else_block) |child| if (try self.macroNodeCallsTryMacro(child, visiting)) break :blk true;
                break :blk false;
            },
            .for_stmt => |for_stmt| blk: {
                for (for_stmt.body) |child| if (try self.macroNodeCallsTryMacro(child, visiting)) break :blk true;
                break :blk false;
            },
            .while_stmt => |while_stmt| blk: {
                for (while_stmt.body) |child| if (try self.macroNodeCallsTryMacro(child, visiting)) break :blk true;
                break :blk false;
            },
            else => false,
        };
    }

    fn macroParamIsTrySourceRecursive(
        self: *TypeChecker,
        macro_decl: *const ast.MacroDecl,
        param_index: usize,
        visiting: *std.AutoHashMap(MacroConsumptionKey, void),
    ) TypeError!bool {
        if (param_index >= macro_decl.params.len) return false;
        const key = MacroConsumptionKey{ .macro_decl = macro_decl, .param_index = param_index };
        if (visiting.contains(key)) return false;
        try visiting.put(key, {});
        defer _ = visiting.remove(key);
        const name = macro_decl.params[param_index];
        if (control_flow_rules.macroParamIsTrySource(macro_decl.body, name)) return true;
        for (macro_decl.body) |node| {
            if (try self.macroNodeForwardsTrySource(node, name, visiting)) return true;
        }
        return false;
    }

    fn macroNodeForwardsTrySource(
        self: *TypeChecker,
        node: *const ast.Node,
        name: []const u8,
        visiting: *std.AutoHashMap(MacroConsumptionKey, void),
    ) TypeError!bool {
        return switch (node.*) {
            .call_expr => |call| blk: {
                if (self.macros.get(call.func_name)) |nested| {
                    for (call.args, 0..) |arg, index| {
                        const root = rootIdentifier(arg) orelse continue;
                        if (!std.mem.eql(u8, root, name)) continue;
                        if (try self.macroParamIsTrySourceRecursive(nested, index, visiting)) break :blk true;
                    }
                }
                break :blk false;
            },
            .expr_stmt => |expr| self.macroNodeForwardsTrySource(expr, name, visiting),
            .assign_stmt => |assign| self.macroNodeForwardsTrySource(assign.value, name, visiting),
            .let_stmt => |let| self.macroNodeForwardsTrySource(let.value, name, visiting),
            .return_stmt => |ret| if (ret.value) |value| self.macroNodeForwardsTrySource(value, name, visiting) else false,
            .block_stmt => |block| blk: {
                for (block.body) |child| if (try self.macroNodeForwardsTrySource(child, name, visiting)) break :blk true;
                break :blk false;
            },
            .unsafe_expr => |unsafe_expr| blk: {
                for (unsafe_expr.body) |child| if (try self.macroNodeForwardsTrySource(child, name, visiting)) break :blk true;
                break :blk false;
            },
            .if_expr => |ife| blk: {
                for (ife.then_block) |child| if (try self.macroNodeForwardsTrySource(child, name, visiting)) break :blk true;
                if (ife.else_block) |else_block| for (else_block) |child| if (try self.macroNodeForwardsTrySource(child, name, visiting)) break :blk true;
                break :blk false;
            },
            .for_stmt => |for_stmt| blk: {
                for (for_stmt.body) |child| if (try self.macroNodeForwardsTrySource(child, name, visiting)) break :blk true;
                break :blk false;
            },
            .while_stmt => |while_stmt| blk: {
                for (while_stmt.body) |child| if (try self.macroNodeForwardsTrySource(child, name, visiting)) break :blk true;
                break :blk false;
            },
            else => false,
        };
    }

    fn macroParamConsumptionRecursive(
        self: *TypeChecker,
        macro_decl: *const ast.MacroDecl,
        param_index: usize,
        visiting: *std.AutoHashMap(MacroConsumptionKey, void),
    ) TypeError!control_flow_rules.MacroParamConsumption {
        if (param_index >= macro_decl.params.len) return .never;
        const key = MacroConsumptionKey{ .macro_decl = macro_decl, .param_index = param_index };
        if (visiting.contains(key)) return .never;
        try visiting.put(key, {});
        defer _ = visiting.remove(key);

        const name = macro_decl.params[param_index];
        const direct = control_flow_rules.macroParamConsumption(macro_decl.body, name);
        if (direct != .never) return direct;
        var effect: control_flow_rules.MacroParamConsumption = .never;
        for (macro_decl.body) |node| {
            effect = control_flow_rules.sequenceMacroParamConsumption(effect, try self.macroNodeForwardedConsumption(node, name, visiting));
        }
        return effect;
    }

    fn macroNodeForwardedConsumption(
        self: *TypeChecker,
        node: *const ast.Node,
        name: []const u8,
        visiting: *std.AutoHashMap(MacroConsumptionKey, void),
    ) TypeError!control_flow_rules.MacroParamConsumption {
        return switch (node.*) {
            .call_expr => |call| blk: {
                var effect: control_flow_rules.MacroParamConsumption = .never;
                if (self.macros.get(call.func_name)) |nested| {
                    for (nested.params, call.args, 0..) |_, arg, index| {
                        const root = rootIdentifier(arg) orelse continue;
                        if (!std.mem.eql(u8, root, name)) continue;
                        effect = control_flow_rules.sequenceMacroParamConsumption(effect, try self.macroParamConsumptionRecursive(nested, index, visiting));
                    }
                }
                for (call.args) |arg| effect = control_flow_rules.sequenceMacroParamConsumption(effect, try self.macroNodeForwardedConsumption(arg, name, visiting));
                break :blk effect;
            },
            .expr_stmt => |expr| self.macroNodeForwardedConsumption(expr, name, visiting),
            .assign_stmt => |assign| self.macroNodeForwardedConsumption(assign.value, name, visiting),
            .let_stmt => |let| self.macroNodeForwardedConsumption(let.value, name, visiting),
            .return_stmt => |ret| if (ret.value) |value| self.macroNodeForwardedConsumption(value, name, visiting) else .never,
            .block_stmt => |block| blk: {
                var effect: control_flow_rules.MacroParamConsumption = .never;
                for (block.body) |child| effect = control_flow_rules.sequenceMacroParamConsumption(effect, try self.macroNodeForwardedConsumption(child, name, visiting));
                break :blk effect;
            },
            .if_expr => |ife| blk: {
                const cond = try self.macroNodeForwardedConsumption(ife.cond, name, visiting);
                var then_effect: control_flow_rules.MacroParamConsumption = .never;
                for (ife.then_block) |child| then_effect = control_flow_rules.sequenceMacroParamConsumption(then_effect, try self.macroNodeForwardedConsumption(child, name, visiting));
                var else_effect: control_flow_rules.MacroParamConsumption = .never;
                if (ife.else_block) |else_block| {
                    for (else_block) |child| else_effect = control_flow_rules.sequenceMacroParamConsumption(else_effect, try self.macroNodeForwardedConsumption(child, name, visiting));
                }
                break :blk control_flow_rules.sequenceMacroParamConsumption(cond, control_flow_rules.branchMacroParamConsumption(then_effect, else_effect));
            },
            .binary_expr => |binary| control_flow_rules.sequenceMacroParamConsumption(try self.macroNodeForwardedConsumption(binary.left, name, visiting), try self.macroNodeForwardedConsumption(binary.right, name, visiting)),
            .field_expr => |field| self.macroNodeForwardedConsumption(field.expr, name, visiting),
            .index_expr => |index| control_flow_rules.sequenceMacroParamConsumption(try self.macroNodeForwardedConsumption(index.target, name, visiting), try self.macroNodeForwardedConsumption(index.index, name, visiting)),
            .cast_expr => |cast| self.macroNodeForwardedConsumption(cast.expr, name, visiting),
            .borrow_expr => |borrow| self.macroNodeForwardedConsumption(borrow.expr, name, visiting),
            .move_expr => |move| self.macroNodeForwardedConsumption(move.expr, name, visiting),
            .deref_expr => |deref| self.macroNodeForwardedConsumption(deref.expr, name, visiting),
            .try_expr => |try_expr| self.macroNodeForwardedConsumption(try_expr.expr, name, visiting),
            .await_expr => |await_expr| self.macroNodeForwardedConsumption(await_expr.expr, name, visiting),
            .go_expr => |g| self.macroNodeForwardedConsumption(g.call, name, visiting),
            .for_stmt => |for_stmt| blk: {
                var effect = try self.macroNodeForwardedConsumption(for_stmt.start, name, visiting);
                if (for_stmt.end) |end| effect = control_flow_rules.sequenceMacroParamConsumption(effect, try self.macroNodeForwardedConsumption(end, name, visiting));
                var body_effect: control_flow_rules.MacroParamConsumption = .never;
                for (for_stmt.body) |child| body_effect = control_flow_rules.sequenceMacroParamConsumption(body_effect, try self.macroNodeForwardedConsumption(child, name, visiting));
                if (body_effect != .never) body_effect = .conditional;
                break :blk control_flow_rules.sequenceMacroParamConsumption(effect, body_effect);
            },
            .while_stmt => |while_stmt| blk: {
                const cond = try self.macroNodeForwardedConsumption(while_stmt.cond, name, visiting);
                var body_effect: control_flow_rules.MacroParamConsumption = .never;
                for (while_stmt.body) |child| body_effect = control_flow_rules.sequenceMacroParamConsumption(body_effect, try self.macroNodeForwardedConsumption(child, name, visiting));
                if (body_effect != .never) body_effect = .conditional;
                break :blk control_flow_rules.sequenceMacroParamConsumption(cond, body_effect);
            },
            else => .never,
        };
    }

    fn checkTest(self: *TypeChecker, test_decl: *ast.TestDecl) !void {
        const previous_fn_is_async = self.current_fn_is_async;
        self.current_fn_is_async = false;
        defer self.current_fn_is_async = previous_fn_is_async;
        const previous_fn_is_variadic_def = self.current_fn_is_variadic_def;
        self.current_fn_is_variadic_def = false;
        defer self.current_fn_is_variadic_def = previous_fn_is_variadic_def;
        var scope = try Scope.init(self.allocator, self.global_scope);
        try self.scope_pool.append(scope);

        const ret_ty = try self.allocator.create(ast.Type);
        ret_ty.* = .{ .primitive = .void_type };

        try self.defineSymbol(scope, "return_ty_sentinel", ret_ty, true);

        try self.checkBlock(test_decl.body, scope, ret_ty, null, null);

        var iter = scope.symbols.valueIterator();
        while (iter.next()) |sym| {
            if (sym.state == .active and !isInternalSymbol(sym.name)) {
                sym.state = .consumed;
            }
        }
    }

    fn checkFunc(self: *TypeChecker, func: *ast.FuncDecl) !void {
        if (func.is_decl_only) return;

        const previous_name = self.current_function_name;
        self.current_function_name = func.name;
        defer self.current_function_name = previous_name;

        const previous_fn_is_async = self.current_fn_is_async;
        self.current_fn_is_async = func.is_async;
        defer self.current_fn_is_async = previous_fn_is_async;

        const previous_fn_is_variadic_def = self.current_fn_is_variadic_def;
        self.current_fn_is_variadic_def = func.is_variadic and func.is_extern and !func.is_decl_only;
        defer self.current_fn_is_variadic_def = previous_fn_is_variadic_def;

        const previous_namespace = self.current_function_namespace;
        self.current_function_namespace = if (self.resolveFunctionAliasMetadata(func.name)) |metadata| metadata.namespace else null;
        defer self.current_function_namespace = previous_namespace;

        var scope = try Scope.init(self.allocator, self.global_scope);
        try self.scope_pool.append(scope);

        try self.defineSymbol(scope, "return_ty_sentinel", func.ret_ty, true);

        for (func.params) |p| {
            const local_ty = if (p.is_borrow) try self.makeBorrowType(p.ty) else p.ty;
            try self.defineSymbol(scope, p.name, local_ty, false);
        }

        try self.checkBlock(func.body, scope, func.ret_ty, null, null);

        if (!isPrimitiveType(func.ret_ty, .void_type) and func.body.len > 0) {
            const last = func.body[func.body.len - 1];
            if (last.* == .expr_stmt and !stmtTerminates(last)) {
                const tail_ty = self.expr_types.get(last.expr_stmt) orelse return TypeError.CompileError;
                if (!self.valueAssignableTo(func.ret_ty, tail_ty)) {
                    self.setError("TypeMismatch in function tail expression: expected {s}, actual {s}", .{ typeDesc(func.ret_ty), typeDesc(tail_ty) });
                    return TypeError.TypeMismatch;
                }
            }
        }

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
        current_loop_scope: ?*Scope,
    ) !void {
        _ = loop_node;
        var scope = try Scope.init(self.allocator, parent_scope);
        try self.scope_pool.append(scope);

        for (body) |stmt| {
            try self.checkStmt(stmt, scope, ret_ty, current_loop_scope);
        }

        // Auto-cleanup for variables local to this block that are still active.
        // Raw pointers are non-owning, but they still need lexical liveness end
        // markers so generated SA does not leave pointer locals Active at exit.
        var cleanup_list = std.array_list.Managed([]const u8).init(self.allocator);
        var iter = scope.symbols.valueIterator();
        while (iter.next()) |sym| {
            if (sym.state == .active and !isInternalSymbol(sym.name)) {
                // Block-local borrows still need lexical end cleanups so codegen can
                // release tracked borrow handles such as RefCell shared/mut borrows.
                if (sym.ty.* == .primitive and sym.ty.primitive == .raw_ptr) continue;
                // issue013: if another active local has borrow_source == sym.name,
                // the borrow handle was moved into that local; skip the source here
                // so we do not emit a double `!name` release.
                if (isBorrowLikeType(sym.ty) and self.borrowSourceAliasedByOtherActive(scope, sym.name)) continue;
                try cleanup_list.append(sym.name);
                sym.state = .consumed;
            }
        }

        if (cleanup_list.items.len > 0) {
            // Associated cleanup list with the block's last statement, or block node itself
            if (body.len > 0) {
                const last_stmt = body[body.len - 1];
                if (last_stmt.* != .return_stmt and last_stmt.* != .break_stmt and last_stmt.* != .continue_stmt) {
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

    fn blockTerminates(body: []const *ast.Node) bool {
        if (body.len == 0) return false;
        return stmtTerminates(body[body.len - 1]);
    }

    fn stmtTerminates(stmt: *const ast.Node) bool {
        return switch (stmt.*) {
            .return_stmt, .break_stmt, .continue_stmt => true,
            .expr_stmt => |expr| exprTerminates(expr),
            else => false,
        };
    }

    fn exprTerminates(expr: *const ast.Node) bool {
        return switch (expr.*) {
            .call_expr => |call| lowering_rules.isPanicBuiltinName(call.func_name),
            .unsafe_expr => |ue| blockTerminates(ue.body),
            .if_expr => |ife| blockTerminates(ife.then_block) and if (ife.else_block) |eb| blockTerminates(eb) else false,
            .match_expr => |mat| blk: {
                if (mat.cases.len == 0) break :blk false;
                for (mat.cases) |case| {
                    if (!blockTerminates(case.body)) break :blk false;
                }
                break :blk true;
            },
            // #7: an all-diverging `switch` tail (every arm returns/panics,
            // with a `default` arm so no value can fall through) terminates
            // the function; without this the tail check misreports the
            // void-typed switch statement as a value mismatch.
            .switch_expr => |swe| blk: {
                if (swe.cases.len == 0) break :blk false;
                var has_default = false;
                for (swe.cases) |case| {
                    if (lowering_rules.isSwitchDefaultPattern(case.pattern)) has_default = true;
                    if (!blockTerminates(case.body)) break :blk false;
                }
                break :blk has_default;
            },
            else => false,
        };
    }

    fn saveScopeStates(self: *TypeChecker, scope: *Scope) TypeError!std.StringHashMap(ValueState) {
        var states = std.StringHashMap(ValueState).init(self.allocator);
        var curr: ?*Scope = scope;
        while (curr) |s| {
            var iter = s.symbols.iterator();
            while (iter.next()) |entry| {
                try states.put(entry.key_ptr.*, entry.value_ptr.state);
            }
            curr = s.parent;
        }
        return states;
    }

    fn restoreScopeStates(_: *TypeChecker, scope: *Scope, saved: *const std.StringHashMap(ValueState)) void {
        var curr: ?*Scope = scope;
        while (curr) |s| {
            var iter = s.symbols.iterator();
            while (iter.next()) |entry| {
                if (saved.get(entry.key_ptr.*)) |state| entry.value_ptr.state = state;
            }
            curr = s.parent;
        }
    }

    fn mergeMultiBranchScopeStates(
        self: *TypeChecker,
        scope: *Scope,
        saved_states: *const std.StringHashMap(ValueState),
        live_states: []const std.StringHashMap(ValueState),
        live_bodies: []const []const *ast.Node,
    ) TypeError!void {
        switch (control_flow_rules.planMultiBranchStateMerge(live_states.len)) {
            .restore_pre => self.restoreScopeStates(scope, saved_states),
            .restore_single => self.restoreScopeStates(scope, &live_states[0]),
            .intersect_live => {
                var branch_values = try self.allocator.alloc(ValueState, live_states.len);
                defer self.allocator.free(branch_values);

                var curr: ?*Scope = scope;
                while (curr) |s| {
                    var iter = s.symbols.iterator();
                    while (iter.next()) |entry| {
                        const name = entry.key_ptr.*;
                        if (isInternalSymbol(name)) continue;
                        for (live_states, 0..) |states, idx| {
                            branch_values[idx] = states.get(name) orelse .active;
                        }
                        const merged = control_flow_rules.intersectLiveBranchValueStates(branch_values);
                        entry.value_ptr.state = merged;
                        if (merged != .consumed) continue;

                        for (branch_values, live_bodies) |state, body| {
                            if (state != .active or body.len == 0) continue;
                            const last = body[body.len - 1];
                            var list = self.phi_cleanups.get(last) orelse std.array_list.Managed([]const u8).init(self.allocator);
                            try list.append(name);
                            try self.phi_cleanups.put(last, list);
                        }
                    }
                    curr = s.parent;
                }
            },
        }
    }

    fn restoreUninitializedFromSaved(self: *TypeChecker, scope: *Scope, saved: *const std.StringHashMap(ValueState)) void {
        _ = self;
        var curr: ?*Scope = scope;
        while (curr) |s| {
            var iter = s.symbols.iterator();
            while (iter.next()) |entry| {
                if (saved.get(entry.key_ptr.*)) |state| {
                    if (state == .uninitialized) entry.value_ptr.state = .uninitialized;
                }
            }
            curr = s.parent;
        }
    }

    fn checkStmt(
        self: *TypeChecker,
        stmt: *ast.Node,
        scope: *Scope,
        ret_ty: *ast.Type,
        current_loop_scope: ?*Scope,
    ) TypeError!void {
        self.checkStmtImpl(stmt, scope, ret_ty, current_loop_scope) catch |err| {
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
        current_loop_scope: ?*Scope,
    ) TypeError!void {
        switch (stmt.*) {
            .using_decl => |u| {
                const normalized = try self.normalizeUsingPath(u.path);
                try scope.using_modules.append(normalized);
            },
            .let_stmt => |let| {
                // Goroutine syntax batch: a Chan::new initializer must
                // be bound by an explicit Chan<T> annotation; validate
                // the payload rules here and hand the payload type to
                // the intrinsic through chan_new_pending.
                if (let.value.* == .call_expr and let.value.call_expr.associated_target != null and std.mem.eql(u8, let.value.call_expr.associated_target.?, "Chan") and std.mem.eql(u8, let.value.call_expr.func_name, "new")) {
                    const declared = let.ty orelse {
                        self.setError("Chan::new requires an explicit Chan<T> type annotation on the binding so the payload type is known (for example `let ch: Chan<u64> = Chan::new(0);`)", .{});
                        return TypeError.TypeMismatch;
                    };
                    const payload_ty = chanPayloadTypeOf(declared) orelse {
                        self.setError("Chan::new binding annotation must be a Chan<T> type", .{});
                        return TypeError.TypeMismatch;
                    };
                    _ = try self.validateChanPayload(payload_ty, "Chan::new");
                    try self.chan_new_pending.put(let.value, payload_ty);
                    try self.chan_new_validated.put(let.value, {});
                }
                const val_ty = try self.checkExpr(let.value, scope);
                if (typeIsVaListValue(val_ty) or (let.ty != null and typeIsVaListValue(let.ty.?))) {
                    self.setError("VaList is not copyable: it cannot be bound to a new name, stored, or returned; pass the variadic parameter itself to va_next_*", .{});
                    return TypeError.TypeMismatch;
                }
                const declared_ty = let.ty orelse val_ty;
                if (let.ty != null and val_ty.* == .array and declared_ty.* == .array) {
                    self.expr_types.put(let.value, declared_ty) catch return TypeError.OutOfMemory;
                }
                if (!self.valueAssignableTo(declared_ty, val_ty)) {
                    if (declared_ty.* == .user_defined and std.mem.eql(u8, declared_ty.user_defined.name, "Slice") and declared_ty.user_defined.generics.len == 1 and val_ty.* == .borrow) {
                        if (arrayType(val_ty.borrow)) |arr| {
                            if (self.typesEqual(declared_ty.user_defined.generics[0], arr.elem)) {
                                try self.defineSymbol(scope, let.name, declared_ty, false);
                                return;
                            }
                        }
                    }
                    if (self.canCoerceToDynBox(declared_ty, val_ty)) |trait_name| {
                        self.dyn_box_coercions.put(let.value, trait_name) catch return TypeError.OutOfMemory;
                    } else if (self.canCoerceRcNewToDynRc(declared_ty, val_ty, let.value)) |trait_name| {
                        self.dyn_rc_coercions.put(let.value, trait_name) catch return TypeError.OutOfMemory;
                    } else {
                        self.setError("TypeMismatch in let {s}: declared tag={s}, val tag={s}", .{ let.name, @tagName(declared_ty.*), @tagName(val_ty.*) });
                        return TypeError.TypeMismatch;
                    }
                }
                if (let.value.* == .identifier) {
                    if (scope.lookup(let.value.identifier)) |source| {
                        if (!self.typeIsCopy(source.ty) and !isBorrowLikeType(source.ty)) {
                            if (self.rootHasLiveFieldBorrow(scope, let.value.identifier)) |conflict| {
                                self.setError("BorrowConflict: cannot move `{s}` into `{s}` while `{s}` is still borrowed by `{s}`", .{ let.value.identifier, let.name, self.fieldPlaceDesc(conflict.place), conflict.borrower });
                                return TypeError.InvalidBorrow;
                            }
                            try self.consumeBinding(scope, let.value.identifier, source, "implicit let move");
                        }
                    }
                }
                if (!isDiscardName(let.name)) {
                    try self.defineSymbol(scope, let.name, declared_ty, false);
                    if (isBorrowLikeType(declared_ty)) {
                        if (directBorrowSource(let.value)) |source| {
                            scope.lookupLocal(let.name).?.borrow_source = source;
                        }
                        if (self.borrowPlaceOfValue(scope, let.value)) |place| {
                            try self.registerFieldBorrow(scope, place, let.name);
                        }
                    }
                }
            },
            .let_else_stmt => |let| {
                const value_ty = try self.checkExpr(let.value, scope);
                try self.checkBlock(let.else_block, scope, ret_ty, null, current_loop_scope);
                if (!blockTerminates(let.else_block)) {
                    self.setError("let else block must diverge", .{});
                    return TypeError.TypeMismatch;
                }
                try self.definePatternBindings(scope, let.pattern, value_ty, "let else", false);
            },
            .let_destructure_stmt => |let| {
                const val_ty = try self.checkExpr(let.value, scope);
                if (let.is_slice) {
                    const elem_ty = if (arrayType(val_ty)) |arr| arr.elem else if (sliceElementType(val_ty)) |elem| elem else {
                        self.setError("slice destructuring requires array or slice value, actual tag={s}", .{@tagName(val_ty.*)});
                        return TypeError.TypeMismatch;
                    };
                    if (let.rest_name == null) {
                        self.setError("slice destructuring requires a rest binding", .{});
                        return TypeError.InvalidArgsCount;
                    }
                    if (let.names.len > 0 and val_ty.* == .array and val_ty.array.len < let.names.len) {
                        self.setError("slice destructuring arity mismatch: pattern={}, array={}", .{ let.names.len, val_ty.array.len });
                        return TypeError.InvalidArgsCount;
                    }
                    for (let.names) |name| {
                        if (!isDiscardName(name)) {
                            try self.defineSymbol(scope, name, elem_ty, false);
                        }
                    }
                    if (let.rest_name) |rest_name| {
                        if (!isDiscardName(rest_name)) {
                            try self.defineSymbol(scope, rest_name, try self.makeSliceType(elem_ty), false);
                        }
                    }
                    if (let.rest_alias) |rest_alias| {
                        if (!isDiscardName(rest_alias)) {
                            try self.defineSymbol(scope, rest_alias, try self.makeSliceType(elem_ty), false);
                        }
                    }
                } else {
                    if (val_ty.* != .tuple) {
                        self.setError("let destructuring requires tuple value, actual tag={s}", .{@tagName(val_ty.*)});
                        return TypeError.TypeMismatch;
                    }
                    if (let.names.len != val_ty.tuple.elems.len) {
                        self.setError("let destructuring arity mismatch: pattern={}, tuple={}", .{ let.names.len, val_ty.tuple.elems.len });
                        return TypeError.InvalidArgsCount;
                    }
                    for (let.names, val_ty.tuple.elems) |name, elem_ty| {
                        if (!isDiscardName(name)) {
                            try self.defineSymbol(scope, name, elem_ty, false);
                        }
                    }
                }
                if (rootIdentifier(let.value)) |name| {
                    const sym = scope.lookup(name) orelse return TypeError.UndefinedVariable;
                    if (sym.state == .consumed) return TypeError.UseAfterMove;
                    try self.consumeBinding(scope, name, sym, "destructuring move");
                }
            },
            .const_stmt => |c| {
                const val_ty = try self.checkExpr(c.value, scope);
                const declared_ty = c.ty orelse val_ty;
                if (c.ty != null and val_ty.* == .array and declared_ty.* == .array) {
                    self.expr_types.put(c.value, declared_ty) catch return TypeError.OutOfMemory;
                }
                if (!self.valueAssignableTo(declared_ty, val_ty)) {
                    if (self.canCoerceToDynBox(declared_ty, val_ty)) |trait_name| {
                        self.dyn_box_coercions.put(c.value, trait_name) catch return TypeError.OutOfMemory;
                    } else if (self.canCoerceRcNewToDynRc(declared_ty, val_ty, c.value)) |trait_name| {
                        self.dyn_rc_coercions.put(c.value, trait_name) catch return TypeError.OutOfMemory;
                    } else {
                        self.setError("TypeMismatch in const {s}: declared tag={s}, val tag={s}", .{ c.name, @tagName(declared_ty.*), @tagName(val_ty.*) });
                        return TypeError.TypeMismatch;
                    }
                }
                try self.defineSymbol(scope, c.name, declared_ty, true);
            },
            .var_stmt => |v| {
                if (v.ty.* != .primitive) {
                    self.setError("var Phase 1 supports scalar primitive slots only: `{s}`", .{v.name});
                    return TypeError.TypeMismatch;
                }
                try self.defineSymbolWithState(scope, v.name, v.ty, false, .uninitialized);
            },
            .assign_stmt => |assign| {
                // View-types stage 1: rebinding a borrow binding ends its
                // previous borrow; assigning into a place that overlaps a
                // live field borrow is rejected (writing through a deref
                // target is the borrow's own use and stays legal).
                if (assign.target.* == .identifier) {
                    // Reassigning a root while any field of it is borrowed
                    // is rejected; rebinding a borrow binding itself only
                    // ends that binding's own borrow (its entries are
                    // rooted at the borrowed place, not at the binding).
                    if (self.rootHasLiveFieldBorrow(scope, assign.target.identifier)) |conflict| {
                        self.setError("BorrowConflict: cannot reassign `{s}` while `{s}` is still borrowed by `{s}`", .{ assign.target.identifier, self.fieldPlaceDesc(conflict.place), conflict.borrower });
                        return TypeError.InvalidBorrow;
                    }
                    self.dropFieldBorrowsOf(scope, assign.target.identifier);
                } else if (assign.target.* != .deref_expr) {
                    if (self.placeOfExpr(assign.target)) |place| {
                        if (self.liveFieldBorrowConflict(scope, place)) |conflict| {
                            self.setError("BorrowConflict: cannot assign to `{s}` while `{s}` is still borrowed by `{s}`", .{ self.fieldPlaceDesc(place), self.fieldPlaceDesc(conflict.place), conflict.borrower });
                            return TypeError.InvalidBorrow;
                        }
                    }
                }
                if (assign.target.* == .deref_expr) {
                    const deref_target_ty = try self.checkExpr(assign.target.deref_expr.expr, scope);
                    if (rwLockReadGuardInnerType(deref_target_ty) != null) {
                        self.setError("cannot assign through RwLock read guard", .{});
                        return TypeError.TypeMismatch;
                    }
                }
                const target_ty = if (assign.target.* == .identifier) blk: {
                    const sym = scope.lookup(assign.target.identifier) orelse return TypeError.UndefinedVariable;
                    self.expr_types.put(assign.target, sym.ty) catch return TypeError.OutOfMemory;
                    break :blk sym.ty;
                } else try self.checkExpr(assign.target, scope);
                const prev_assign_target = self.assign_rhs_target_name;
                const prev_assign_value = self.assign_rhs_value;
                if (assign.target.* == .identifier) {
                    self.assign_rhs_target_name = assign.target.identifier;
                    self.assign_rhs_value = assign.value;
                }
                const val_ty = self.checkExpr(assign.value, scope) catch |err| {
                    self.assign_rhs_target_name = prev_assign_target;
                    self.assign_rhs_value = prev_assign_value;
                    return err;
                };
                self.assign_rhs_target_name = prev_assign_target;
                self.assign_rhs_value = prev_assign_value;
                if (!self.valueAssignableTo(target_ty, val_ty)) {
                    const target_name = if (assign.target.* == .identifier) assign.target.identifier else "<expr>";
                    if (self.current_function_name) |fn_name| {
                        self.setError("TypeMismatch in assign in {s}: target `{s}` tag={s}, val tag={s}", .{ fn_name, target_name, @tagName(target_ty.*), @tagName(val_ty.*) });
                    } else {
                        self.setError("TypeMismatch in assign: target `{s}` tag={s}, val tag={s}", .{ target_name, @tagName(target_ty.*), @tagName(val_ty.*) });
                    }
                    return TypeError.TypeMismatch;
                }
                // let bindings can be reassigned and indexed; const bindings cannot.
                if (rootIdentifier(assign.target)) |root_name| {
                    const sym = scope.lookup(root_name) orelse return TypeError.UndefinedVariable;
                    if (sym.is_const) return TypeError.CompileError;
                    if (sym.state == .uninitialized and assign.target.* != .identifier) {
                        self.setError("UseBeforeInit: var `{s}` must be assigned as a whole before field/index assignment", .{root_name});
                        return TypeError.UseBeforeInit;
                    }
                }
                if (assign.value.* == .identifier) {
                    const value_name = assign.value.identifier;
                    const target_name = rootIdentifier(assign.target);
                    if (target_name == null or !std.mem.eql(u8, target_name.?, value_name)) {
                        const sym = scope.lookup(value_name) orelse return TypeError.UndefinedVariable;
                        if (sym.state == .consumed) return TypeError.UseAfterMove;
                        if (sym.state == .uninitialized) {
                            self.setError("UseBeforeInit: var `{s}` is read before assignment", .{value_name});
                            return TypeError.UseBeforeInit;
                        }
                        if (!self.typeIsCopy(sym.ty) and !isBorrowLikeType(sym.ty)) {
                            if (self.rootHasLiveFieldBorrow(scope, value_name)) |conflict| {
                                self.setError("BorrowConflict: cannot move `{s}` while `{s}` is still borrowed by `{s}`", .{ value_name, self.fieldPlaceDesc(conflict.place), conflict.borrower });
                                return TypeError.InvalidBorrow;
                            }
                            try self.consumeBinding(scope, value_name, sym, "assignment move");
                        }
                    }
                }
                if (assign.target.* == .identifier) {
                    const sym = scope.lookup(assign.target.identifier) orelse return TypeError.UndefinedVariable;
                    if (sym.state == .uninitialized) sym.state = .active;
                    // REG-BR-6: a whole-variable assignment redefines the
                    // binding, so a value consumed earlier (including by the
                    // assignment's own right-hand side, the `x = f(x, ..)`
                    // accumulation form) is live again from here on.
                    if (sym.state == .consumed) {
                        sym.state = .active;
                        sym.consumed_by_call = null;
                    }
                    // View-types stage 1: rebinding a borrow binding to a
                    // new borrowed place registers the new borrow.
                    if (isBorrowLikeType(sym.ty)) {
                        if (self.borrowPlaceOfValue(scope, assign.value)) |place| {
                            try self.registerFieldBorrow(scope, place, assign.target.identifier);
                        }
                    }
                }
            },
            .return_stmt => |ret| {
                if (ret.value) |val| {
                    const val_ty = try self.checkExpr(val, scope);
                    if (!self.valueAssignableTo(ret_ty, val_ty)) {
                        self.setError("TypeMismatch in return: expected {s}, actual {s}", .{ typeDesc(ret_ty), typeDesc(val_ty) });
                        return TypeError.TypeMismatch;
                    }
                } else {
                    if (!isPrimitiveType(ret_ty, .void_type)) {
                        self.setError("TypeMismatch in return void: expected tag={s}", .{@tagName(ret_ty.*)});
                        return TypeError.TypeMismatch;
                    }
                }

                // Collect all active variables across all scope frames up to the function root
                var cleanup_list = std.array_list.Managed([]const u8).init(self.allocator);
                var curr: ?*Scope = scope;
                while (curr) |s| {
                    var iter = s.symbols.valueIterator();
                    while (iter.next()) |sym| {
                        if (sym.state == .active and !isInternalSymbol(sym.name)) {
                            if (ret.value) |val| {
                                if (functionExitBindingEscapes(scope, val, sym.name)) continue;
                            }
                            // issue013: skip borrow source that has been re-aliased.
                            if (isBorrowLikeType(sym.ty) and self.borrowSourceAliasedByOtherActive(scope, sym.name)) continue;
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
                const start_ty = try self.checkExpr(f.start, scope);
                const iter_ty = if (f.end) |end_expr| blk: {
                    const end_ty = try self.checkExpr(end_expr, scope);
                    if (!isNumericType(start_ty) or !isNumericType(end_ty)) {
                        self.setError("for range bounds must be numeric: start tag={s}, end tag={s}", .{ @tagName(start_ty.*), @tagName(end_ty.*) });
                        return TypeError.TypeMismatch;
                    }
                    break :blk start_ty;
                } else blk: {
                    if (arrayType(start_ty)) |arr| break :blk arr.elem;
                    break :blk self.protocolIterableElementType(start_ty) orelse {
                        self.setError("for iterable value must be array or implement Iterable: start tag={s}", .{@tagName(start_ty.*)});
                        return TypeError.TypeMismatch;
                    };
                };

                const loop_scope = try Scope.init(self.allocator, scope);
                try self.scope_pool.append(loop_scope);

                const i_ty = try self.allocator.create(ast.Type);
                i_ty.* = iter_ty.*;
                try self.defineSymbol(loop_scope, f.var_name, i_ty, true);

                var saved_states = try self.saveScopeStates(scope);
                defer saved_states.deinit();

                const prev_loop_scope = self.current_loop_scope;
                const prev_loop_body_terminates = self.current_loop_body_terminates;
                self.current_loop_scope = loop_scope;
                self.current_loop_body_terminates = blockTerminates(f.body);
                defer {
                    self.current_loop_scope = prev_loop_scope;
                    self.current_loop_body_terminates = prev_loop_body_terminates;
                }
                try self.checkBlock(f.body, loop_scope, ret_ty, stmt, loop_scope);
                self.restoreUninitializedFromSaved(scope, &saved_states);
            },
            .while_stmt => |*w| {
                const cond_ty = try self.checkExpr(w.cond, scope);
                const loop_scope = try Scope.init(self.allocator, scope);
                try self.scope_pool.append(loop_scope);
                if (w.let_pattern) |pattern| {
                    try self.definePatternBindings(loop_scope, pattern, cond_ty, "while let", true);
                } else {
                    if (cond_ty.* != .primitive) {
                        self.setError("while condition must be bool/int unless using while let", .{});
                        return TypeError.TypeMismatch;
                    }
                    switch (cond_ty.primitive) {
                        .boolean, .integer => {},
                        else => return TypeError.TypeMismatch,
                    }
                }
                var saved_states = try self.saveScopeStates(scope);
                defer saved_states.deinit();

                const prev_loop_scope = self.current_loop_scope;
                const prev_loop_body_terminates = self.current_loop_body_terminates;
                self.current_loop_scope = loop_scope;
                self.current_loop_body_terminates = blockTerminates(w.body);
                defer {
                    self.current_loop_scope = prev_loop_scope;
                    self.current_loop_body_terminates = prev_loop_body_terminates;
                }
                try self.checkBlock(w.body, loop_scope, ret_ty, stmt, loop_scope);
                self.restoreUninitializedFromSaved(scope, &saved_states);
            },
            .break_stmt, .continue_stmt => {
                const loop_scope = current_loop_scope orelse {
                    self.setError("break/continue used outside loop", .{});
                    return TypeError.CompileError;
                };

                var cleanup_list = std.array_list.Managed([]const u8).init(self.allocator);
                var curr: ?*Scope = scope;
                while (curr) |s| {
                    var iter = s.symbols.valueIterator();
                    while (iter.next()) |sym| {
                        if (sym.state == .active and !isInternalSymbol(sym.name)) {
                            // issue013: skip borrowed source that was aliased.
                            if (isBorrowLikeType(sym.ty) and self.borrowSourceAliasedByOtherActive(scope, sym.name)) continue;
                            try cleanup_list.append(sym.name);
                        }
                    }
                    if (s == loop_scope) break;
                    curr = s.parent;
                }
                if (cleanup_list.items.len > 0) {
                    try self.cleanups.put(stmt, cleanup_list);
                } else {
                    cleanup_list.deinit();
                }
            },
            .release_stmt => |rel| {
                const sym = scope.lookup(rel.var_name) orelse return TypeError.UndefinedVariable;
                if (sym.state == .consumed) return TypeError.UseAfterMove;
                if (sym.state == .uninitialized) {
                    self.setError("UseBeforeInit: var `{s}` cannot be released before assignment", .{rel.var_name});
                    return TypeError.UseBeforeInit;
                }
                try self.consumeBinding(scope, rel.var_name, sym, "explicit release");
            },
            .expr_stmt => |expr| {
                _ = try self.checkExpr(expr, scope);
            },
            .select_stmt => |sel| {
                try self.checkSelectStmt(sel, scope, ret_ty, current_loop_scope);
            },
            .block_stmt => |blk| {
                const inner_scope = try Scope.init(self.allocator, scope);
                try self.scope_pool.append(inner_scope);
                try self.checkBlock(blk.body, inner_scope, ret_ty, stmt, current_loop_scope);
            },
            else => return TypeError.CompileError,
        }
    }

    fn checkExpr(self: *TypeChecker, expr: *ast.Node, scope: *Scope) TypeError!*ast.Type {
        const ty = self.checkExprImpl(expr, scope) catch |err| {
            if (self.last_error.len == 0) {
                if (expr.* == .call_expr) {
                    const call = expr.call_expr;
                    self.setError("checkExpr failed at call {s}{s}{s} with {} args", .{ if (call.associated_target) |target| target else "", if (call.associated_target != null) "::" else "", call.func_name, call.args.len });
                } else {
                    self.setError("checkExpr failed at node tag {s}", .{@tagName(expr.*)});
                }
            }
            return err;
        };
        self.expr_types.put(expr, ty) catch return TypeError.OutOfMemory;
        return ty;
    }

    fn blockTailExprType(self: *TypeChecker, block: []const *ast.Node) ?*ast.Type {
        if (block.len == 0) return null;
        const last = block[block.len - 1];
        if (last.* != .expr_stmt) return null;
        return self.expr_types.get(last.expr_stmt);
    }

    fn checkExprImpl(self: *TypeChecker, expr: *ast.Node, scope: *Scope) TypeError!*ast.Type {
        switch (expr.*) {
            .literal => |lit| {
                const ty = try self.allocator.create(ast.Type);
                switch (lit) {
                    .int_val => ty.* = .{ .primitive = .i64 },
                    .float_val => ty.* = .{ .primitive = .f64 },
                    .bool_val => ty.* = .{ .primitive = .boolean },
                    .string_val => {
                        // In Sla, string literal evaluates to ptr (pointing to char array)
                        ty.* = .{ .primitive = .raw_ptr };
                    },
                }
                return ty;
            },
            .identifier => |name| {
                if (lowering_rules.isOptionNoneName(name)) {
                    return try self.makeOptionType(try self.makeInferType());
                }
                if (isOrderingName(name)) {
                    return try self.makeOrderingType();
                }
                if (scope.lookup(name)) |sym| {
                    if (sym.state == .consumed) {
                        if (sym.consumed_by_call) |first_call| {
                            // REG-BR-6: language-level diagnostic for a value
                            // moved by an earlier by-value call argument.
                            if (isStringType(sym.ty)) {
                                self.setError("UseAfterMove: variable `{s}` was already moved by the call to `{s}`; a by-value argument transfers ownership, so it cannot be used again - pass an explicit copy to the earlier call if the value is still needed (for example `format(\"{{}}\", {s})`)", .{ name, first_call, name });
                            } else {
                                self.setError("UseAfterMove: variable `{s}` was already moved by the call to `{s}`; a by-value argument transfers ownership, so it cannot be used again - pass an explicit copy to the earlier call if the value is still needed", .{ name, first_call });
                            }
                            return TypeError.UseAfterMove;
                        }
                        self.setError("UseAfterMove: identifier `{s}` was already consumed", .{name});
                        return TypeError.UseAfterMove;
                    }
                    if (sym.state == .uninitialized) {
                        self.setError("UseBeforeInit: var `{s}` is read before assignment", .{name});
                        return TypeError.UseBeforeInit;
                    }
                    return sym.ty;
                }
                if (self.funcs.get(name)) |func| {
                    const params = try self.fnPtrParamTypes(func);
                    return try self.makeFnPtrTypeVariadic(func.abi, params, func.ret_ty, func.is_variadic);
                }
                if (self.func_overload_sets.get(name)) |set| {
                    // A bare reference carries no expected signature, so it
                    // cannot choose a member. Name the candidates and the
                    // member-symbol remedy instead of guessing.
                    var cands = std.array_list.Managed(OverloadCandidate).init(self.allocator);
                    defer cands.deinit();
                    for (set.items) |func| {
                        cands.append(.{ .member_key = func.name, .kind = .func_decl, .func = func }) catch return TypeError.OutOfMemory;
                    }
                    const cand_desc = try self.renderCandidateList(name, cands.items);
                    defer self.allocator.free(cand_desc);
                    const first_key = if (set.items.len > 0) set.items[0].name else name;
                    self.setError("AmbiguousCall: `{s}` is an overload set and a bare function reference cannot choose a member; candidates: {s}; call it with arguments, or reference one member by its member symbol (e.g. `{s}`)", .{ name, cand_desc, first_key });
                    return TypeError.AmbiguousCall;
                }
                self.setError("UndefinedVariable: identifier `{s}` is not defined in this scope", .{name});
                return TypeError.UndefinedVariable;
            },
            .generic_func_ref => return TypeError.CompileError,
            .binary_expr => |bin| {
                const l_ty = try self.checkExpr(bin.left, scope);
                const r_ty = try self.checkExpr(bin.right, scope);
                const ty = try self.allocator.create(ast.Type);
                switch (bin.op) {
                    .add, .sub, .mul, .div, .mod => {
                        if (try self.overloadSymbol(bin.op, l_ty, r_ty)) |symbol| {
                            const call_symbol = try self.allocator.dupe(u8, symbol);
                            try self.resolved_call_symbols.put(@as(*const ast.Node, @ptrCast(&bin)), call_symbol);
                            const ret = self.funcs.get(symbol) orelse return TypeError.UndefinedVariable;
                            ty.* = ret.ret_ty.*;
                            return ty;
                        }
                        if (self.structDeclForType(l_ty)) |left_struct| {
                            if (self.structDeclForType(r_ty)) |right_struct| {
                                if (!self.typesEqual(l_ty, r_ty)) return TypeError.TypeMismatch;
                                if ((bin.op == .add or bin.op == .sub) and structFieldsAllNumeric(left_struct) and left_struct == right_struct) {
                                    ty.* = l_ty.*;
                                    return ty;
                                }
                            } else if (bin.op == .mul and isNumericType(r_ty) and structFieldsAllNumeric(left_struct)) {
                                ty.* = l_ty.*;
                                return ty;
                            }
                        } else if (self.structDeclForType(r_ty)) |right_struct| {
                            if (bin.op == .sub and literalZero(bin.left) and structFieldsAllNumeric(right_struct)) {
                                ty.* = r_ty.*;
                                return ty;
                            }
                            if (bin.op == .mul and isNumericType(l_ty) and structFieldsAllNumeric(right_struct)) {
                                ty.* = r_ty.*;
                                return ty;
                            }
                        }
                        if (bin.op == .sub and literalZero(bin.left) and isNumericType(r_ty)) {
                            ty.* = r_ty.*;
                            return ty;
                        }
                        if (!self.typesEqual(l_ty, r_ty)) {
                            self.setError("binary expression type mismatch: op={s}, left tag={s}, right tag={s}", .{ @tagName(bin.op), @tagName(l_ty.*), @tagName(r_ty.*) });
                            return TypeError.TypeMismatch;
                        }
                        if (l_ty.* == .infer) {
                            ty.* = l_ty.*;
                            return ty;
                        }
                        if (!isNumericType(l_ty)) {
                            self.setError("binary expression requires numeric operands: op={s}, operand tag={s}", .{ @tagName(bin.op), @tagName(l_ty.*) });
                            return TypeError.TypeMismatch;
                        }
                        ty.* = l_ty.*;
                    },
                    .bit_and, .bit_or, .bit_xor => {
                        if (!self.typesEqual(l_ty, r_ty)) return TypeError.TypeMismatch;
                        if (l_ty.* == .infer) {
                            ty.* = l_ty.*;
                            return ty;
                        }
                        if (!isAnyIntegerType(l_ty)) return TypeError.TypeMismatch;
                        ty.* = l_ty.*;
                    },
                    .shl, .shr => {
                        if (l_ty.* == .infer) {
                            if (!isAnyIntegerType(r_ty) and r_ty.* != .infer) return TypeError.TypeMismatch;
                            ty.* = l_ty.*;
                            return ty;
                        }
                        if (!isAnyIntegerType(l_ty)) return TypeError.TypeMismatch;
                        if (r_ty.* != .infer and !isAnyIntegerType(r_ty)) return TypeError.TypeMismatch;
                        ty.* = l_ty.*;
                    },
                    .spaceship => {
                        if (try self.overloadSymbol(bin.op, l_ty, r_ty)) |symbol| {
                            const call_symbol = try self.allocator.dupe(u8, symbol);
                            try self.resolved_call_symbols.put(@as(*const ast.Node, @ptrCast(&bin)), call_symbol);
                            const ret = self.funcs.get(symbol) orelse return TypeError.UndefinedVariable;
                            ty.* = ret.ret_ty.*;
                            return ty;
                        }
                        if (self.structDeclForType(l_ty)) |left_struct| {
                            if (self.structDeclForType(r_ty)) |right_struct| {
                                if (!self.typesEqual(l_ty, r_ty) or left_struct != right_struct) return TypeError.TypeMismatch;
                                if (!self.typeIsOrd(l_ty)) return TypeError.TypeMismatch;
                                return try self.makeOrderingType();
                            }
                        }
                        if (!self.typesEqual(l_ty, r_ty)) return TypeError.TypeMismatch;
                        if (!isNumericType(l_ty)) return TypeError.TypeMismatch;
                        return try self.makeOrderingType();
                    },
                    .eq, .ne, .lt, .le, .gt, .ge => {
                        // Pointer-like operands compare by identity, never by
                        // pointee value. structDeclForType unwraps pointers, so
                        // without this fast path `*S == *S` (and the FFI staple
                        // `handle == ptr::null::<S>()`) is misrouted into the
                        // struct-value comparison below and rejected, because
                        // typeIsEq of a pointer type is always false. Only
                        // eq/ne are identity comparisons; relational ops keep
                        // the existing dispatch.
                        if ((bin.op == .eq or bin.op == .ne) and (l_ty.* == .pointer or l_ty.* == .borrow) and (r_ty.* == .pointer or r_ty.* == .borrow)) {
                            if (!self.typesEqual(l_ty, r_ty)) return TypeError.TypeMismatch;
                            ty.* = .{ .primitive = .boolean };
                            return ty;
                        }
                        if (self.structDeclForType(l_ty)) |left_struct| {
                            if (self.structDeclForType(r_ty)) |right_struct| {
                                if (!self.typesEqual(l_ty, r_ty) or left_struct != right_struct) return TypeError.TypeMismatch;
                                const supported = switch (bin.op) {
                                    .eq, .ne => self.typeIsEq(l_ty),
                                    .lt, .le, .gt, .ge => self.typeIsOrd(l_ty),
                                    else => false,
                                };
                                if (!supported) return TypeError.TypeMismatch;
                                ty.* = .{ .primitive = .boolean };
                                return ty;
                            }
                        }
                        if (!self.typesEqual(l_ty, r_ty)) return TypeError.TypeMismatch;
                        ty.* = .{ .primitive = .boolean };
                    },
                    .logical_and, .logical_or => {
                        if (!self.typesEqual(l_ty, r_ty)) return TypeError.TypeMismatch;
                        if (l_ty.* == .infer) {
                            ty.* = .{ .primitive = .boolean };
                            return ty;
                        }
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
                // View-types stage 1: a new borrow of a place that
                // overlaps a live field borrow is rejected here, at the
                // single point every borrow expression flows through.
                if (self.placeOfExpr(borrow.expr)) |place| {
                    if (self.liveFieldBorrowConflict(scope, place)) |conflict| {
                        self.setError("BorrowConflict: cannot borrow `{s}` while `{s}` is still borrowed by `{s}`; disjoint field borrows are allowed, overlapping field borrows are not", .{ self.fieldPlaceDesc(place), self.fieldPlaceDesc(conflict.place), conflict.borrower });
                        return TypeError.InvalidBorrow;
                    }
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
                    try self.consumeBinding(scope, move.expr.identifier, sym, "explicit move");
                }
                // View-types stage 1: moving a place (or its root) while
                // a field of it is borrowed is rejected.
                if (self.placeOfExpr(move.expr)) |place| {
                    if (self.liveFieldBorrowConflict(scope, place)) |conflict| {
                        self.setError("BorrowConflict: cannot move `{s}` while `{s}` is still borrowed by `{s}`", .{ self.fieldPlaceDesc(place), self.fieldPlaceDesc(conflict.place), conflict.borrower });
                        return TypeError.InvalidBorrow;
                    }
                }
                return inner_ty;
            },
            .deref_expr => |deref| {
                const inner_ty = try self.checkExpr(deref.expr, scope);
                if (inner_ty.* == .infer) return try self.makeInferType();
                if (rcInnerType(inner_ty)) |rc_inner| return rc_inner;
                if (arcInnerType(inner_ty)) |arc_inner| return arc_inner;
                if (boxInnerType(inner_ty)) |box_inner| return box_inner;
                if (mutexGuardInnerType(inner_ty)) |guard_inner| return guard_inner;
                if (rwLockReadGuardInnerType(inner_ty)) |guard_inner| return guard_inner;
                if (rwLockWriteGuardInnerType(inner_ty)) |guard_inner| return guard_inner;
                return @constCast(lowering_rules.pointerOrBorrowPointee(inner_ty) orelse return TypeError.DereferenceNonPointer);
            },
            .cast_expr => |cast| {
                const src_ty = try self.checkExpr(cast.expr, scope);
                if (isPointerCarrierCastType(src_ty) and isPointerCarrierCastType(cast.ty)) {
                    return cast.ty;
                }
                // Fn values may be cast to a raw pointer or a pointer-sized
                // integer: the cast materializes the callable machine
                // address from vtable slot 0 (see the fn-pointer-to-extern
                // materialization in lowering_rules). The reverse direction
                // (integer/pointer -> fn) stays rejected: fn values cannot
                // be fabricated.
                if (src_ty.* == .fn_ptr and cast.ty.* == .primitive and
                    (cast.ty.primitive == .raw_ptr or cast.ty.primitive == .u64 or cast.ty.primitive == .usize))
                {
                    return cast.ty;
                }
                if (src_ty.* == .infer) return cast.ty;
                if (!isNumericType(src_ty) or !isNumericType(cast.ty)) {
                    self.setError("unsupported cast: only numeric primitive casts are currently allowed", .{});
                    return TypeError.TypeMismatch;
                }
                return cast.ty;
            },
            .field_expr => |field| {
                if (std.mem.eql(u8, field.field_name, "len")) {
                    const recv_ty = try self.checkExpr(field.expr, scope);
                    if (isStringLikeType(recv_ty)) {
                        const ty = try self.allocator.create(ast.Type);
                        ty.* = .{ .primitive = .u64 };
                        return ty;
                    }
                }
                if (field.expr.* == .literal and field.expr.literal == .string_val and std.mem.eql(u8, field.field_name, "len")) {
                    const ty = try self.allocator.create(ast.Type);
                    ty.* = .{ .primitive = .u64 };
                    return ty;
                }
                const struct_ty = try self.checkExpr(field.expr, scope);
                const curr_ty = @constCast(lowering_rules.peelBorrowPointerType(struct_ty));
                switch (curr_ty.*) {
                    .user_defined => |ud| {
                        const decl = self.structDeclForType(curr_ty) orelse {
                            self.setError("field access target `{s}` is not a known struct", .{ud.name});
                            return TypeError.NotAStruct;
                        };
                        if (decl.is_opaque) {
                            self.setError("opaque type field access is not allowed: {s}", .{ud.name});
                            return TypeError.FieldNotFound;
                        }
                        if (decl.is_union and self.unsafe_depth == 0) {
                            self.setError("union field access requires unsafe", .{});
                            return TypeError.CompileError;
                        }
                        for (decl.fields) |f| {
                            if (std.mem.eql(u8, f.name, field.field_name)) {
                                return f.ty;
                            }
                        }
                        self.setError("FieldNotFound: `{s}` has no field `{s}`", .{ ud.name, field.field_name });
                        return TypeError.FieldNotFound;
                    },
                    .tuple => |tuple| {
                        const index = std.fmt.parseInt(usize, field.field_name, 10) catch {
                            self.setError("FieldNotFound: tuple field `{s}` is not a numeric index", .{field.field_name});
                            return TypeError.FieldNotFound;
                        };
                        if (index >= tuple.elems.len) {
                            self.setError("FieldNotFound: tuple index `{s}` out of range {}", .{ field.field_name, tuple.elems.len });
                            return TypeError.FieldNotFound;
                        }
                        return tuple.elems[index];
                    },
                    .infer => return try self.makeInferType(),
                    else => {
                        self.setError("field access `{s}` requires struct/tuple target, got tag={s}", .{ field.field_name, @tagName(curr_ty.*) });
                        return TypeError.NotAStruct;
                    },
                }
            },
            .struct_literal => |lit| {
                if (lit.ty.* != .user_defined) return TypeError.NotAStruct;
                const ud = lit.ty.user_defined;
                const decl = self.structDeclForType(lit.ty) orelse return TypeError.NotAStruct;
                if (decl.is_opaque) {
                    self.setError("cannot construct opaque type {s}", .{ud.name});
                    return TypeError.NotAStruct;
                }

                if (lit.update_expr) |update_expr| {
                    const update_ty = try self.checkExpr(update_expr, scope);
                    if (update_ty.* != .user_defined or !std.mem.eql(u8, update_ty.user_defined.name, ud.name)) {
                        self.setError("struct update expression type mismatch", .{});
                        return TypeError.TypeMismatch;
                    }
                }

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
                        self.setError("TypeMismatch in struct literal field {s}.{s}: expected {s}, actual {s}", .{ ud.name, literal_field.name, typeDesc(field_ty), typeDesc(value_ty) });
                        return TypeError.TypeMismatch;
                    }
                }

                if (decl.is_union) {
                    if (seen.count() != 1) {
                        self.setError("Union literal must initialize exactly one field: {s}", .{ud.name});
                        return TypeError.CompileError;
                    }
                } else if (lit.update_expr == null and seen.count() != decl.fields.len) {
                    self.setError("Missing field in struct literal: {s}", .{ud.name});
                    return TypeError.FieldNotFound;
                }

                return lit.ty;
            },
            .enum_literal => |lit| {
                // SA-text parity: Option is synthetic (no declared enum), but
                // Option::None is a valid unit constructor. Accept exactly this
                // shape; sab_codegen emits OPTION_NEW_NONE for it directly.
                if (std.mem.eql(u8, lit.enum_name, "Option") and std.mem.eql(u8, lit.variant_name, "None") and lit.fields.len == 0) {
                    return try self.makeOptionType(try self.makeInferType());
                }
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

                var elems = std.array_list.Managed(*ast.Type).init(self.allocator);
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
            .repeat_array_literal => |lit| {
                const elem_ty = try self.checkExpr(lit.value, scope);
                const ty = try self.allocator.create(ast.Type);
                ty.* = .{ .array = .{ .elem = elem_ty, .len = lit.len } };
                return ty;
            },
            .index_expr => |idx| {
                const target_ty = try self.checkExpr(idx.target, scope);
                const index_ty = try self.checkExpr(idx.index, scope);

                if (target_ty.* == .infer) return try self.makeInferType();

                if (hashMapTypes(target_ty)) |hm| {
                    if (!self.typesEqual(hm.key, index_ty)) return TypeError.TypeMismatch;
                    return hm.value;
                }

                if (btreeMapTypes(target_ty)) |bm| {
                    if (!self.typesEqual(bm.key, index_ty)) return TypeError.TypeMismatch;
                    return bm.value;
                }

                if (!isNumericType(index_ty)) return TypeError.TypeMismatch;

                if (vecElementType(target_ty)) |elem_ty| return elem_ty;
                if (vecDequeElementType(target_ty)) |elem_ty| return elem_ty;
                if (sliceElementType(target_ty)) |elem_ty| return elem_ty;

                const arr = arrayType(target_ty) orelse return TypeError.TypeMismatch;
                return arr.elem;
            },
            .slice_expr => |slc| {
                const target_ty = try self.checkExpr(slc.target, scope);
                const start_ty = try self.checkExpr(slc.start, scope);
                const end_ty = try self.checkExpr(slc.end, scope);
                if (!isNumericType(start_ty) or !isNumericType(end_ty)) return TypeError.TypeMismatch;

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
                try self.recordAwaitCleanup(expr, aw.expr, scope);
                if (rootIdentifier(aw.expr)) |name| {
                    const sym = scope.lookup(name) orelse return TypeError.UndefinedVariable;
                    if (sym.state == .consumed) return TypeError.UseAfterMove;
                    try self.consumeBinding(scope, name, sym, "await");
                }
                return inner_ty;
            },
            .go_expr => |go| return try self.checkGoExpr(expr, go, scope),
            .inline_asm_expr => |asm_expr| {
                if (self.unsafe_depth == 0) {
                    self.setError("inline asm requires unsafe", .{});
                    return TypeError.CompileError;
                }
                for (asm_expr.operands) |operand| {
                    if (!std.mem.eql(u8, operand.constraint, "inout")) {
                        self.setError("unsupported asm operand constraint: {s}", .{operand.constraint});
                        return TypeError.CompileError;
                    }
                    const sym = scope.lookup(operand.var_name) orelse return TypeError.UndefinedVariable;
                    if (sym.state == .consumed) return TypeError.UseAfterMove;
                    if (!isNumericType(sym.ty)) return TypeError.TypeMismatch;
                }
                const ty = try self.allocator.create(ast.Type);
                ty.* = .{ .primitive = .void_type };
                return ty;
            },
            .closure_literal => |lit| {
                for (lit.params) |p| {
                    if (p.ty.* == .infer) {
                        self.setError("closure parameter types must be inferred from context; standalone inference is not available", .{});
                        return TypeError.TypeMismatch;
                    }
                }
                const closure_scope = try Scope.init(self.allocator, scope);
                try self.scope_pool.append(closure_scope);

                var param_types = std.array_list.Managed(*ast.Type).init(self.allocator);
                for (lit.params) |p| {
                    try self.defineSymbol(closure_scope, p.name, p.ty, true);
                    try param_types.append(p.ty);
                }

                // R2 resets across closure bodies (see
                // checkClosureLiteralWithContext).
                const previous_fn_is_async = self.current_fn_is_async;
                self.current_fn_is_async = false;
                defer self.current_fn_is_async = previous_fn_is_async;
                const ret_ty = try self.checkExpr(lit.body, closure_scope);
                const ty = try self.allocator.create(ast.Type);
                ty.* = .{ .closure = .{ .params = try param_types.toOwnedSlice(), .ret = ret_ty } };
                return ty;
            },
            .call_expr => |call| {
                // #13: immediately-invoked closure literal `(|x| ...)(args)`.
                // Mirrors the named-closure-symbol path below; every builtin
                // special-case underneath is func_name-keyed and untouched.
                if (call.callee) |callee| {
                    const callee_ty = try self.checkExpr(callee, scope);
                    if (callee_ty.* != .closure) return TypeError.TypeMismatch;
                    const closure = callee_ty.closure;
                    if (closure.params.len != call.args.len) return TypeError.InvalidArgsCount;
                    for (closure.params, call.args) |param_ty, arg| {
                        const arg_ty = try self.checkExpr(arg, scope);
                        if (!self.plainCallArgMatches(param_ty, arg, arg_ty)) return TypeError.TypeMismatch;
                        if (!self.arrayCallArgStrictMatches(param_ty, arg_ty)) return TypeError.TypeMismatch;
                    }
                    return closure.ret;
                }
                // DEF triage (nested-call UseAfterMove): the receiver probe
                // below exists only to detect chan method calls, and
                // checkChanMethodCall returns null for every other name —
                // but the probe itself fully checks args[0], so for a
                // nested call argument (`outer(inner(v))`) the inner
                // call's by-value arguments were consumed by the probe and
                // the real argument check then reported a spurious
                // UseAfterMove. Probe only for the chan method names.
                const chan_method_probe = std.mem.eql(u8, call.func_name, "send") or
                    std.mem.eql(u8, call.func_name, "recv") or
                    std.mem.eql(u8, call.func_name, "close") or
                    std.mem.eql(u8, call.func_name, "destroy") or
                    std.mem.eql(u8, call.func_name, "len") or
                    std.mem.eql(u8, call.func_name, "cap");
                const recv_node_ty = if (chan_method_probe and call.args.len > 0 and call.args[0].* != .move_expr) try self.checkExpr(call.args[0], scope) else null;

                if (recv_node_ty) |recv_ty| {
                    if (chanPayloadTypeOf(recv_ty)) |payload_ty| {
                        if (try self.checkChanMethodCall(expr, call, payload_ty, scope)) |ret_ty| return ret_ty;
                    }
                }

                if (lowering_rules.isOptionSomeCall(call)) {
                    if (call.args.len != 1) return TypeError.InvalidArgsCount;
                    const inner_ty = try self.checkExpr(call.args[0], scope);
                    return try self.makeOptionType(inner_ty);
                }

                if (std.mem.eql(u8, call.func_name, "None") and call.associated_target == null) {
                    if (call.args.len != 0) return TypeError.InvalidArgsCount;
                    return try self.makeOptionType(try self.makeInferType());
                }

                if (std.mem.eql(u8, call.func_name, "monitor") and call.associated_target == null) {
                    // Goroutine syntax batch: monitor(handle)
                    // subscribes to a goroutine's exit and returns
                    // the notification channel Chan<(u64, i32)>:
                    // (watched handle, trap code; 0 = normal exit).
                    if (call.args.len != 1) { self.setError("monitor(handle) expects exactly one argument: a goroutine handle (u64)", .{}); return TypeError.CompileError; }
                    const h_ty = try self.checkExpr(call.args[0], scope);
                    const h_base = lowering_rules.peelBorrowPointerType(h_ty);
                    if (!(h_base.* == .primitive and h_base.primitive == .u64)) {
                        self.setError("monitor(handle): the handle must be u64 (the value returned by `go`)", .{});
                        return TypeError.CompileError;
                    }
                    const payload_ty = try self.makeTupleType(&.{ try self.makeU64Type(), try self.makeI32Type() });
                    try self.monitor_calls.put(expr, {});
                    return try self.makeChanType(payload_ty);
                }

                if (lowering_rules.isResultOkCall(call)) {
                    if (call.args.len != 1) return TypeError.InvalidArgsCount;
                    const ok_ty = try self.checkExpr(call.args[0], scope);
                    return try self.makeResultType(ok_ty, try self.makeInferType());
                }

                if (lowering_rules.isResultErrCall(call)) {
                    if (call.args.len != 1) return TypeError.InvalidArgsCount;
                    const err_ty = try self.checkExpr(call.args[0], scope);
                    return try self.makeResultType(try self.makeInferType(), err_ty);
                }

                if (lowering_rules.isPtrNullCall(call)) {
                    if (call.args.len != 0) return TypeError.InvalidArgsCount;
                    if (call.generics.len != 1) return TypeError.InvalidArgsCount;
                    return try self.makePointerType(call.generics[0]);
                }

                if (std.mem.eql(u8, call.func_name, "future__pending")) {
                    if (call.args.len != 0) return TypeError.InvalidArgsCount;
                    if (call.generics.len != 1) return TypeError.InvalidArgsCount;
                    return try self.makeFutureType(call.generics[0]);
                }

                if (std.mem.eql(u8, call.func_name, "future__defer_ready")) {
                    if (call.args.len != 1) return TypeError.InvalidArgsCount;
                    if (call.generics.len != 0) return TypeError.InvalidArgsCount;
                    const inner_ty = try self.checkExpr(call.args[0], scope);
                    return try self.makeFutureType(inner_ty);
                }

                if (std.mem.eql(u8, call.func_name, "future__join2")) {
                    return try self.checkFutureJoin2Call(call, scope);
                }

                if (std.mem.eql(u8, call.func_name, "future__pair_left")) {
                    return try self.checkFuturePairAccessorCall(call, scope, true);
                }

                if (std.mem.eql(u8, call.func_name, "future__pair_right")) {
                    return try self.checkFuturePairAccessorCall(call, scope, false);
                }

                // Extern variadic batch: va_next_* builtins read the next
                // promoted argument from the current function's VaList.
                if (vaNextReadType(call.func_name)) |read_ty| {
                    if (!self.current_fn_is_variadic_def) {
                        self.setError("{s} may only be used inside an exported extern \"C\" variadic definition", .{call.func_name});
                        return TypeError.TypeMismatch;
                    }
                    if (call.args.len != 1) return TypeError.InvalidArgsCount;
                    if (call.args[0].* != .identifier) {
                        self.setError("{s} argument must be the VaList parameter binding itself (VaList is not copyable)", .{call.func_name});
                        return TypeError.TypeMismatch;
                    }
                    const list_ty = try self.checkExpr(call.args[0], scope);
                    if (!(list_ty.* == .primitive and list_ty.primitive == .va_list)) {
                        self.setError("{s} argument must be the VaList parameter, got {s}", .{ call.func_name, typeDesc(list_ty) });
                        return TypeError.TypeMismatch;
                    }
                    const ret = try self.allocator.create(ast.Type);
                    ret.* = read_ty;
                    return ret;
                }
                if (std.mem.startsWith(u8, call.func_name, "va_next_")) {
                    self.setError("unknown variadic read builtin `{s}` (supported: va_next_i32, va_next_i64, va_next_u32, va_next_u64, va_next_f64, va_next_ptr)", .{call.func_name});
                    return TypeError.UndefinedVariable;
                }

                if (std.mem.eql(u8, call.func_name, "future__select2")) {
                    return try self.checkFutureSelect2Call(call, scope);
                }

                if (std.mem.eql(u8, call.func_name, "future__either_side")) {
                    return try self.checkFutureEitherSideCall(call, scope);
                }

                if (std.mem.eql(u8, call.func_name, "future__either_left")) {
                    return try self.checkFutureEitherAccessorCall(call, scope, true);
                }

                if (std.mem.eql(u8, call.func_name, "future__either_right")) {
                    return try self.checkFutureEitherAccessorCall(call, scope, false);
                }

                if (std.mem.eql(u8, call.func_name, "poll__ready")) {
                    if (call.args.len != 1) return TypeError.InvalidArgsCount;
                    if (call.generics.len != 0) return TypeError.InvalidArgsCount;
                    const inner_ty = try self.checkExpr(call.args[0], scope);
                    if (!isPollScalarValueType(inner_ty)) return TypeError.TypeMismatch;
                    return try self.makePollType(inner_ty);
                }

                if (std.mem.eql(u8, call.func_name, "poll__pending")) {
                    if (call.args.len != 0) return TypeError.InvalidArgsCount;
                    if (call.generics.len != 1) return TypeError.InvalidArgsCount;
                    if (!isPollScalarValueType(call.generics[0])) return TypeError.TypeMismatch;
                    return try self.makePollType(call.generics[0]);
                }

                if (std.mem.eql(u8, call.func_name, "poll__is_ready") or std.mem.eql(u8, call.func_name, "poll__is_pending")) {
                    if (call.args.len != 1) return TypeError.InvalidArgsCount;
                    if (call.generics.len != 0) return TypeError.InvalidArgsCount;
                    const poll_ty = try self.checkExpr(call.args[0], scope);
                    _ = pollInnerType(poll_ty) orelse return TypeError.TypeMismatch;
                    return try self.makeBoolType();
                }

                if (std.mem.eql(u8, call.func_name, "poll__value")) {
                    if (call.args.len != 1) return TypeError.InvalidArgsCount;
                    if (call.generics.len != 0) return TypeError.InvalidArgsCount;
                    const poll_ty = try self.checkExpr(call.args[0], scope);
                    const inner_ty = pollInnerType(poll_ty) orelse return TypeError.TypeMismatch;
                    if (!isPollScalarValueType(inner_ty)) return TypeError.TypeMismatch;
                    return inner_ty;
                }

                if (std.mem.eql(u8, call.func_name, "RAW_WAKER_NEW")) {
                    if (call.args.len != 2) return TypeError.InvalidArgsCount;
                    const data_ty = try self.checkExpr(call.args[0], scope);
                    const vtable_ty = try self.checkExpr(call.args[1], scope);
                    if (!isPointerValueType(data_ty) or !isPointerValueType(vtable_ty)) return TypeError.TypeMismatch;
                    const ty = try self.allocator.create(ast.Type);
                    ty.* = .{ .user_defined = .{ .name = "RawWaker", .generics = &.{} } };
                    return ty;
                }

                if (std.mem.eql(u8, call.func_name, "RAW_WAKER_GET_DATA") or
                    std.mem.eql(u8, call.func_name, "RAW_WAKER_GET_VTABLE"))
                {
                    if (call.args.len != 1) return TypeError.InvalidArgsCount;
                    _ = try self.checkExpr(call.args[0], scope);
                    return try self.makePointerType(try self.makeInferType());
                }

                if (std.mem.eql(u8, call.func_name, "RAW_WAKER_CLONE")) {
                    if (call.args.len != 1) return TypeError.InvalidArgsCount;
                    _ = try self.checkExpr(call.args[0], scope);
                    const ty = try self.allocator.create(ast.Type);
                    ty.* = .{ .user_defined = .{ .name = "RawWaker", .generics = &.{} } };
                    return ty;
                }

                if (std.mem.eql(u8, call.func_name, "WAKER_FROM_RAW") or std.mem.eql(u8, call.func_name, "WAKER_CLONE")) {
                    if (call.args.len != 1) return TypeError.InvalidArgsCount;
                    _ = try self.checkExpr(call.args[0], scope);
                    const ty = try self.allocator.create(ast.Type);
                    ty.* = .{ .user_defined = .{ .name = "Waker", .generics = &.{} } };
                    return ty;
                }

                if (std.mem.eql(u8, call.func_name, "WAKER_GET_DATA") or
                    std.mem.eql(u8, call.func_name, "WAKER_GET_VTABLE") or
                    std.mem.eql(u8, call.func_name, "LOCAL_WAKER_GET_DATA") or
                    std.mem.eql(u8, call.func_name, "LOCAL_WAKER_GET_VTABLE"))
                {
                    if (call.args.len != 1) return TypeError.InvalidArgsCount;
                    _ = try self.checkExpr(call.args[0], scope);
                    return try self.makePointerType(try self.makeInferType());
                }

                if (std.mem.eql(u8, call.func_name, "WAKER_WILL_WAKE")) {
                    if (call.args.len != 2) return TypeError.InvalidArgsCount;
                    _ = try self.checkExpr(call.args[0], scope);
                    _ = try self.checkExpr(call.args[1], scope);
                    const ty = try self.allocator.create(ast.Type);
                    ty.* = .{ .primitive = .boolean };
                    return ty;
                }

                if (std.mem.eql(u8, call.func_name, "WAKER_WAKE") or
                    std.mem.eql(u8, call.func_name, "WAKER_WAKE_BY_REF") or
                    std.mem.eql(u8, call.func_name, "RAW_WAKER_WAKE") or
                    std.mem.eql(u8, call.func_name, "RAW_WAKER_WAKE_BY_REF"))
                {
                    if (call.args.len != 1) return TypeError.InvalidArgsCount;
                    _ = try self.checkExpr(call.args[0], scope);
                    return try self.makeI32Type();
                }

                if (std.mem.eql(u8, call.func_name, "std__ptr__read_volatile") or std.mem.eql(u8, call.func_name, "ptr__read_volatile")) {
                    if (self.unsafe_depth == 0) {
                        self.setError("ptr::read_volatile requires unsafe", .{});
                        return TypeError.CompileError;
                    }
                    if (call.args.len != 1) return TypeError.InvalidArgsCount;
                    const ptr_ty = try self.checkExpr(call.args[0], scope);
                    return @constCast(lowering_rules.pointerOrBorrowPointee(ptr_ty) orelse return TypeError.TypeMismatch);
                }

                if (recv_node_ty) |rt| {
                    if (try self.resolveUsingMethodSymbolForType(scope, rt, call.func_name, call.args.len)) |symbol| {
                        if (try self.checkStaticCallBySymbol(expr, symbol, call.args, scope, call.func_name, false)) |ret_ty| return ret_ty;
                        return TypeError.UndefinedVariable;
                    }
                }

                if (call.associated_target) |target_name| {
                    if (self.traits.contains(target_name)) {
                        if (call.args.len == 0) {
                            self.setError("Trait associated call {s}::{s} needs an implementing value argument", .{ target_name, call.func_name });
                            return TypeError.InvalidArgsCount;
                        }
                        const recv_ty = try self.checkExpr(call.args[0], scope);
                        const concrete_name = concreteTypeName(recv_ty) orelse return TypeError.TypeMismatch;
                        const symbol = (try self.resolveTraitMethodSymbolForType(concrete_name, target_name, call.func_name, call.args.len)) orelse {
                            self.setError("Type `{s}` does not implement trait method `{s}::{s}`", .{ concrete_name, target_name, call.func_name });
                            return TypeError.UndefinedVariable;
                        };
                        const func = self.funcs.get(symbol) orelse return TypeError.UndefinedVariable;
                        try self.checkCallArgsAgainstFunc(func, call.args, scope, call.func_name, false);
                        self.resolved_call_symbols.put(expr, symbol) catch return TypeError.OutOfMemory;
                        if (func.is_async) return try self.makeFutureType(func.ret_ty);
                        return func.ret_ty;
                    }

                    const is_ptr_target = std.mem.eql(u8, target_name, "std__ptr") or std.mem.eql(u8, target_name, "ptr");
                    if (is_ptr_target and std.mem.eql(u8, call.func_name, "null")) {
                        if (call.args.len != 0) return TypeError.InvalidArgsCount;
                        if (call.generics.len != 1) return TypeError.InvalidArgsCount;
                        return try self.makePointerType(call.generics[0]);
                    }
                    if (is_ptr_target and std.mem.eql(u8, call.func_name, "read_volatile")) {
                        if (self.unsafe_depth == 0) {
                            self.setError("ptr::read_volatile requires unsafe", .{});
                            return TypeError.CompileError;
                        }
                        if (call.args.len != 1) return TypeError.InvalidArgsCount;
                        const ptr_ty = try self.checkExpr(call.args[0], scope);
                        return @constCast(lowering_rules.pointerOrBorrowPointee(ptr_ty) orelse return TypeError.TypeMismatch);
                    }
                    if (lowering_rules.isMemForgetCall(call)) {
                        if (call.args.len != 1) return TypeError.InvalidArgsCount;
                        _ = try self.checkExpr(call.args[0], scope);
                        if (rootIdentifier(call.args[0])) |name| {
                            const sym = scope.lookup(name) orelse return TypeError.UndefinedVariable;
                            if (sym.state == .consumed) return TypeError.UseAfterMove;
                            try self.consumeBinding(scope, name, sym, "mem::forget");
                        }
                        const ty = try self.allocator.create(ast.Type);
                        ty.* = .{ .primitive = .void_type };
                        return ty;
                    }
                    if (lowering_rules.isManuallyDropNewCall(call)) {
                        if (call.args.len != 1) return TypeError.InvalidArgsCount;
                        const inner_ty = try self.checkExpr(call.args[0], scope);
                        return try self.makeManuallyDropType(inner_ty);
                    }
                    if (lowering_rules.isManuallyDropIntoInnerCall(call)) {
                        if (call.args.len != 1) return TypeError.InvalidArgsCount;
                        const slot_ty = try self.checkExpr(call.args[0], scope);
                        const inner_ty = manuallyDropInnerType(slot_ty) orelse return TypeError.TypeMismatch;
                        if (call.args[0].* == .identifier) {
                            const sym = scope.lookup(call.args[0].identifier) orelse return TypeError.UndefinedVariable;
                            if (sym.state == .consumed) return TypeError.UseAfterMove;
                            try self.consumeBinding(scope, call.args[0].identifier, sym, "ManuallyDrop::into_inner");
                        }
                        return inner_ty;
                    }
                    if (lowering_rules.isMpscChannelCall(call)) {
                        if (call.args.len != 0) return TypeError.InvalidArgsCount;
                        const elem_ty = try self.makeI32Type();
                        const sender_ty = try self.makeSenderType(elem_ty);
                        const receiver_ty = try self.makeReceiverType(elem_ty);
                        return try self.makeTupleType(&.{ sender_ty, receiver_ty });
                    }
                    if (std.mem.eql(u8, target_name, "thread") and std.mem.eql(u8, call.func_name, "spawn")) {
                        if (call.args.len != 1) return TypeError.InvalidArgsCount;
                        const closure_ty = try self.checkExpr(call.args[0], scope);
                        if (closure_ty.* != .closure or closure_ty.closure.params.len != 0) return TypeError.TypeMismatch;
                        const ret_ty = if (closure_ty.closure.ret.* == .primitive and closure_ty.closure.ret.primitive == .integer)
                            try self.makeI32Type()
                        else
                            closure_ty.closure.ret;
                        return try self.makeJoinHandleType(ret_ty);
                    }
                    if (std.mem.eql(u8, target_name, "future") and std.mem.eql(u8, call.func_name, "ready")) {
                        if (call.args.len != 1) return TypeError.InvalidArgsCount;
                        const inner_ty = try self.checkExpr(call.args[0], scope);
                        return try self.makeFutureType(inner_ty);
                    }
                    if (std.mem.eql(u8, target_name, "future") and std.mem.eql(u8, call.func_name, "defer_ready")) {
                        if (call.args.len != 1) return TypeError.InvalidArgsCount;
                        if (call.generics.len != 0) return TypeError.InvalidArgsCount;
                        const inner_ty = try self.checkExpr(call.args[0], scope);
                        return try self.makeFutureType(inner_ty);
                    }
                    if (std.mem.eql(u8, target_name, "future") and std.mem.eql(u8, call.func_name, "pending")) {
                        if (call.args.len != 0) return TypeError.InvalidArgsCount;
                        if (call.generics.len != 1) return TypeError.InvalidArgsCount;
                        return try self.makeFutureType(call.generics[0]);
                    }
                    if (std.mem.eql(u8, target_name, "future") and std.mem.eql(u8, call.func_name, "join2")) {
                        return try self.checkFutureJoin2Call(call, scope);
                    }
                    if (std.mem.eql(u8, target_name, "future") and std.mem.eql(u8, call.func_name, "pair_left")) {
                        return try self.checkFuturePairAccessorCall(call, scope, true);
                    }
                    if (std.mem.eql(u8, target_name, "future") and std.mem.eql(u8, call.func_name, "pair_right")) {
                        return try self.checkFuturePairAccessorCall(call, scope, false);
                    }
                    if (std.mem.eql(u8, target_name, "future") and std.mem.eql(u8, call.func_name, "select2")) {
                        return try self.checkFutureSelect2Call(call, scope);
                    }
                    if (std.mem.eql(u8, target_name, "future") and std.mem.eql(u8, call.func_name, "either_side")) {
                        return try self.checkFutureEitherSideCall(call, scope);
                    }
                    if (std.mem.eql(u8, target_name, "future") and std.mem.eql(u8, call.func_name, "either_left")) {
                        return try self.checkFutureEitherAccessorCall(call, scope, true);
                    }
                    if (std.mem.eql(u8, target_name, "future") and std.mem.eql(u8, call.func_name, "either_right")) {
                        return try self.checkFutureEitherAccessorCall(call, scope, false);
                    }
                    if (std.mem.eql(u8, target_name, "poll") and std.mem.eql(u8, call.func_name, "ready")) {
                        if (call.args.len != 1) return TypeError.InvalidArgsCount;
                        if (call.generics.len != 0) return TypeError.InvalidArgsCount;
                        const inner_ty = try self.checkExpr(call.args[0], scope);
                        if (!isPollScalarValueType(inner_ty)) return TypeError.TypeMismatch;
                        return try self.makePollType(inner_ty);
                    }
                    if (std.mem.eql(u8, target_name, "poll") and std.mem.eql(u8, call.func_name, "pending")) {
                        if (call.args.len != 0) return TypeError.InvalidArgsCount;
                        if (call.generics.len != 1) return TypeError.InvalidArgsCount;
                        if (!isPollScalarValueType(call.generics[0])) return TypeError.TypeMismatch;
                        return try self.makePollType(call.generics[0]);
                    }
                    if (std.mem.eql(u8, target_name, "poll") and (std.mem.eql(u8, call.func_name, "is_ready") or std.mem.eql(u8, call.func_name, "is_pending"))) {
                        if (call.args.len != 1) return TypeError.InvalidArgsCount;
                        if (call.generics.len != 0) return TypeError.InvalidArgsCount;
                        const poll_ty = try self.checkExpr(call.args[0], scope);
                        _ = pollInnerType(poll_ty) orelse return TypeError.TypeMismatch;
                        return try self.makeBoolType();
                    }
                    if (std.mem.eql(u8, target_name, "poll") and std.mem.eql(u8, call.func_name, "value")) {
                        if (call.args.len != 1) return TypeError.InvalidArgsCount;
                        if (call.generics.len != 0) return TypeError.InvalidArgsCount;
                        const poll_ty = try self.checkExpr(call.args[0], scope);
                        const inner_ty = pollInnerType(poll_ty) orelse return TypeError.TypeMismatch;
                        if (!isPollScalarValueType(inner_ty)) return TypeError.TypeMismatch;
                        return inner_ty;
                    }
                    if (std.mem.eql(u8, target_name, "task") and std.mem.eql(u8, call.func_name, "new")) {
                        if (call.args.len != 1) return TypeError.InvalidArgsCount;
                        const future_ty = try self.checkExpr(call.args[0], scope);
                        const inner_ty = switch (future_ty.*) {
                            .future => |inner| inner,
                            else => return TypeError.TypeMismatch,
                        };
                        return try self.makeTaskType(inner_ty);
                    }
                    if (std.mem.eql(u8, target_name, "task") and (std.mem.eql(u8, call.func_name, "poll") or std.mem.eql(u8, call.func_name, "is_ready"))) {
                        if (call.args.len != 1) return TypeError.InvalidArgsCount;
                        const task_ty = try self.checkExpr(call.args[0], scope);
                        _ = taskInnerType(task_ty) orelse return TypeError.TypeMismatch;
                        return try self.makeBoolType();
                    }
                    if (std.mem.eql(u8, target_name, "task") and std.mem.eql(u8, call.func_name, "result")) {
                        if (call.args.len != 1) return TypeError.InvalidArgsCount;
                        const task_ty = try self.checkExpr(call.args[0], scope);
                        return taskInnerType(task_ty) orelse return TypeError.TypeMismatch;
                    }
                    if (std.mem.eql(u8, target_name, "task") and std.mem.eql(u8, call.func_name, "state")) {
                        if (call.args.len != 1) return TypeError.InvalidArgsCount;
                        const task_ty = try self.checkExpr(call.args[0], scope);
                        _ = taskInnerType(task_ty) orelse return TypeError.TypeMismatch;
                        return try self.makeU64Type();
                    }
                    if (std.mem.eql(u8, target_name, "executor") and std.mem.eql(u8, call.func_name, "new")) {
                        if (call.args.len != 1) return TypeError.InvalidArgsCount;
                        if (call.generics.len != 0) return TypeError.InvalidArgsCount;
                        const tasks_ty = try self.checkExpr(call.args[0], scope);
                        const inner_ty = executorTaskBufferInnerType(tasks_ty) orelse return TypeError.TypeMismatch;
                        return try self.makeExecutorType(inner_ty);
                    }
                    if (std.mem.eql(u8, target_name, "executor") and std.mem.eql(u8, call.func_name, "poll_one")) {
                        if (call.args.len != 2) return TypeError.InvalidArgsCount;
                        if (call.generics.len != 0) return TypeError.InvalidArgsCount;
                        const executor_ty = try self.checkExpr(call.args[0], scope);
                        _ = executorInnerType(executor_ty) orelse return TypeError.TypeMismatch;
                        const index_ty = try self.checkExpr(call.args[1], scope);
                        if (!isNumericType(index_ty)) return TypeError.TypeMismatch;
                        return try self.makeBoolType();
                    }
                    if (std.mem.eql(u8, target_name, "executor") and std.mem.eql(u8, call.func_name, "poll_ready_count")) {
                        if (call.args.len != 1) return TypeError.InvalidArgsCount;
                        if (call.generics.len != 0) return TypeError.InvalidArgsCount;
                        const executor_ty = try self.checkExpr(call.args[0], scope);
                        _ = executorInnerType(executor_ty) orelse return TypeError.TypeMismatch;
                        return try self.makeU64Type();
                    }
                    if (lowering_rules.isBoxNewCall(call)) {
                        if (call.args.len != 1) return TypeError.InvalidArgsCount;
                        const inner_ty = try self.checkExpr(call.args[0], scope);
                        return try self.makeBoxType(inner_ty);
                    }
                    if (lowering_rules.isBoxIntoRawCall(call)) {
                        if (call.args.len != 1) return TypeError.InvalidArgsCount;
                        const box_ty = try self.checkExpr(call.args[0], scope);
                        const inner_ty = boxInnerType(box_ty) orelse return TypeError.TypeMismatch;
                        if (rootIdentifier(call.args[0])) |name| {
                            const sym = scope.lookup(name) orelse return TypeError.UndefinedVariable;
                            if (sym.state == .consumed) return TypeError.UseAfterMove;
                            try self.consumeBinding(scope, name, sym, "Box::into_raw");
                        }
                        return try self.makePointerType(inner_ty);
                    }
                    if (lowering_rules.isBoxFromRawCall(call)) {
                        if (self.unsafe_depth == 0) {
                            self.setError("Box::from_raw requires unsafe", .{});
                            return TypeError.CompileError;
                        }
                        if (call.args.len != 1) return TypeError.InvalidArgsCount;
                        const ptr_ty = try self.checkExpr(call.args[0], scope);
                        return switch (ptr_ty.*) {
                            .pointer => |inner| try self.makeBoxType(inner),
                            .borrow => |inner| try self.makeBoxType(inner),
                            else => TypeError.TypeMismatch,
                        };
                    }
                    if (lowering_rules.isRcNewCall(call)) {
                        if (call.args.len != 1) return TypeError.InvalidArgsCount;
                        const inner_ty = try self.checkExpr(call.args[0], scope);
                        return try self.makeRcType(inner_ty);
                    }
                    if (lowering_rules.isArcNewCall(call)) {
                        if (call.args.len != 1) return TypeError.InvalidArgsCount;
                        const inner_ty = try self.checkExpr(call.args[0], scope);
                        return try self.makeArcType(inner_ty);
                    }
                    if (std.mem.eql(u8, target_name, "AtomicI32") and std.mem.eql(u8, call.func_name, "new")) {
                        if (call.args.len != 1) return TypeError.InvalidArgsCount;
                        const value_ty = try self.checkExpr(call.args[0], scope);
                        if (!isNumericType(value_ty)) return TypeError.TypeMismatch;
                        return try self.makeAtomicI32Type();
                    }
                    if (std.mem.eql(u8, target_name, "AtomicUsize") and std.mem.eql(u8, call.func_name, "new")) {
                        if (call.args.len != 1) return TypeError.InvalidArgsCount;
                        const value_ty = try self.checkExpr(call.args[0], scope);
                        if (!isNumericType(value_ty)) return TypeError.TypeMismatch;
                        return try self.makeAtomicUsizeType();
                    }
                    if (std.mem.eql(u8, target_name, "AtomicPtr") and std.mem.eql(u8, call.func_name, "new")) {
                        if (call.args.len != 1) return TypeError.InvalidArgsCount;
                        const value_ty = try self.checkExpr(call.args[0], scope);
                        const inner_ty = switch (value_ty.*) {
                            .pointer => |inner| inner,
                            else => return TypeError.TypeMismatch,
                        };
                        return try self.makeAtomicPtrType(inner_ty);
                    }
                    if (std.mem.eql(u8, target_name, "Cell") and std.mem.eql(u8, call.func_name, "new")) {
                        if (call.args.len != 1) return TypeError.InvalidArgsCount;
                        const value_ty = try self.checkExpr(call.args[0], scope);
                        if (!isCellValueType(value_ty)) return TypeError.TypeMismatch;
                        return try self.makeCellType(value_ty);
                    }
                    if (std.mem.eql(u8, target_name, "RefCell") and std.mem.eql(u8, call.func_name, "new")) {
                        if (call.args.len != 1) return TypeError.InvalidArgsCount;
                        const value_ty = try self.checkExpr(call.args[0], scope);
                        return try self.makeRefCellType(value_ty);
                    }
                    if (std.mem.eql(u8, target_name, "Mutex") and std.mem.eql(u8, call.func_name, "new")) {
                        if (call.args.len != 1) return TypeError.InvalidArgsCount;
                        const value_ty = try self.checkExpr(call.args[0], scope);
                        if (!isNumericType(value_ty)) return TypeError.TypeMismatch;
                        const inner_ty = if (call.args[0].* == .literal and call.args[0].literal == .int_val) try self.makeI32Type() else value_ty;
                        if (inner_ty != value_ty) self.expr_types.put(call.args[0], inner_ty) catch return TypeError.OutOfMemory;
                        return try self.makeMutexType(inner_ty);
                    }
                    if (std.mem.eql(u8, target_name, "RwLock") and std.mem.eql(u8, call.func_name, "new")) {
                        if (call.args.len != 1) return TypeError.InvalidArgsCount;
                        const value_ty = try self.checkExpr(call.args[0], scope);
                        if (!isNumericType(value_ty)) return TypeError.TypeMismatch;
                        const inner_ty = if (call.args[0].* == .literal and call.args[0].literal == .int_val) try self.makeI32Type() else value_ty;
                        if (inner_ty != value_ty) self.expr_types.put(call.args[0], inner_ty) catch return TypeError.OutOfMemory;
                        return try self.makeRwLockType(inner_ty);
                    }
                    if (std.mem.eql(u8, target_name, "File") and std.mem.eql(u8, call.func_name, "open")) {
                        if (call.args.len != 1) return TypeError.InvalidArgsCount;
                        const path_ty = try self.checkExpr(call.args[0], scope);
                        if (!isStringLikeType(path_ty)) return TypeError.TypeMismatch;
                        return try self.makeResultType(try self.makeFileType(), try self.makeI32Type());
                    }
                    if (std.mem.eql(u8, target_name, "VecDeque") and std.mem.eql(u8, call.func_name, "from")) {
                        if (call.args.len != 1) return TypeError.InvalidArgsCount;
                        const array_ty = try self.checkExpr(call.args[0], scope);
                        const arr = arrayType(array_ty) orelse return TypeError.TypeMismatch;
                        return try self.makeVecDequeType(arr.elem);
                    }
                    if (std.mem.eql(u8, target_name, "VecDeque") and std.mem.eql(u8, call.func_name, "new")) {
                        if (call.args.len != 0) return TypeError.InvalidArgsCount;
                        const elem_ty = if (call.generics.len == 1) call.generics[0] else try self.makeInferType();
                        return try self.makeVecDequeType(elem_ty);
                    }
                    if (std.mem.eql(u8, target_name, "HashMap") and std.mem.eql(u8, call.func_name, "new")) {
                        if (call.args.len != 0) return TypeError.InvalidArgsCount;
                        const key_ty = if (call.generics.len >= 1) call.generics[0] else try self.makeInferType();
                        const value_ty = if (call.generics.len >= 2) call.generics[1] else try self.makeInferType();
                        return try self.makeHashMapType(key_ty, value_ty);
                    }
                    if (std.mem.eql(u8, target_name, "HashSet") and std.mem.eql(u8, call.func_name, "new")) {
                        if (call.args.len != 0) return TypeError.InvalidArgsCount;
                        const key_ty = if (call.generics.len >= 1) call.generics[0] else try self.makeInferType();
                        return try self.makeHashSetType(key_ty);
                    }
                    if (std.mem.eql(u8, target_name, "BTreeMap") and std.mem.eql(u8, call.func_name, "new")) {
                        if (call.args.len != 0) return TypeError.InvalidArgsCount;
                        const key_ty = if (call.generics.len >= 1) call.generics[0] else try self.makeInferType();
                        const value_ty = if (call.generics.len >= 2) call.generics[1] else try self.makeInferType();
                        return try self.makeBTreeMapType(key_ty, value_ty);
                    }
                    if (std.mem.eql(u8, target_name, "BTreeSet") and std.mem.eql(u8, call.func_name, "new")) {
                        if (call.args.len != 0) return TypeError.InvalidArgsCount;
                        const key_ty = if (call.generics.len >= 1) call.generics[0] else try self.makeInferType();
                        return try self.makeBTreeSetType(key_ty);
                    }
                    if (std.mem.eql(u8, target_name, "Vec") and std.mem.eql(u8, call.func_name, "new")) {
                        if (call.args.len != 0) return TypeError.InvalidArgsCount;
                        const elem_ty = if (call.generics.len == 1) call.generics[0] else try self.makeInferType();
                        const generics = try self.allocator.alloc(*ast.Type, 1);
                        generics[0] = elem_ty;
                        const ty = try self.allocator.create(ast.Type);
                        ty.* = .{ .user_defined = .{ .name = "Vec", .generics = generics } };
                        return ty;
                    }
                    if (std.mem.eql(u8, target_name, "Chan") and std.mem.eql(u8, call.func_name, "new")) {
                        return try self.checkChanNewCall(expr, call, scope);
                    }
                    const method_key = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ target_name, call.func_name });
                    if (self.funcs.get(method_key)) |func| {
                        try self.checkCallArgsAgainstFunc(func, call.args, scope, call.func_name, false);
                        self.resolved_call_symbols.put(expr, method_key) catch return TypeError.OutOfMemory;
                        if (func.is_async) return try self.makeFutureType(func.ret_ty);
                        return func.ret_ty;
                    }
                    // Option::None() unit constructor: mirrors bare None value.
                    if (std.mem.eql(u8, target_name, "Option") and std.mem.eql(u8, call.func_name, "None")) {
                        if (call.args.len != 0) return TypeError.InvalidArgsCount;
                        return try self.makeOptionType(try self.makeInferType());
                    }
                    if (try self.resolveTraitMethodSymbolForType(target_name, null, call.func_name, call.args.len)) |symbol| {
                        const func = self.funcs.get(symbol) orelse return TypeError.UndefinedVariable;
                        try self.checkCallArgsAgainstFunc(func, call.args, scope, call.func_name, false);
                        self.resolved_call_symbols.put(expr, symbol) catch return TypeError.OutOfMemory;
                        if (func.is_async) return try self.makeFutureType(func.ret_ty);
                        return func.ret_ty;
                    }
                }

                if (std.mem.eql(u8, call.func_name, "vec")) {
                    if (call.args.len == 0) {
                        self.setError("vec requires at least one element", .{});
                        return TypeError.InvalidArgsCount;
                    }
                    const elem_ty = try self.checkExpr(call.args[0], scope);
                    for (call.args[1..]) |arg| {
                        const arg_ty = try self.checkExpr(arg, scope);
                        if (!self.typesEqual(elem_ty, arg_ty)) return TypeError.TypeMismatch;
                    }
                    const generics = try self.allocator.alloc(*ast.Type, 1);
                    generics[0] = elem_ty;
                    const ty = try self.allocator.create(ast.Type);
                    ty.* = .{ .user_defined = .{ .name = "Vec", .generics = generics } };
                    return ty;
                }

                if (lowering_rules.isLenCall(call) and call.args.len == 1) {
                    _ = try self.checkExpr(call.args[0], scope);
                    const ty = try self.allocator.create(ast.Type);
                    ty.* = .{ .primitive = .usize };
                    return ty;
                }
                if (lowering_rules.isLenCall(call)) {
                    self.setError("len call arity mismatch: {}", .{call.args.len});
                    return TypeError.InvalidArgsCount;
                }
                if (lowering_rules.isStrEqCall(call)) {
                    if (call.args.len != 2) return TypeError.InvalidArgsCount;
                    const left_ty = try self.checkExpr(call.args[0], scope);
                    const right_ty = try self.checkExpr(call.args[1], scope);
                    if (!isStringLikeType(left_ty) or !isStringLikeType(right_ty)) return TypeError.TypeMismatch;
                    const ty = try self.allocator.create(ast.Type);
                    ty.* = .{ .primitive = .boolean };
                    return ty;
                }
                if (std.mem.eql(u8, call.func_name, "format")) {
                    if (call.args.len == 0 or call.args[0].* != .literal or call.args[0].literal != .string_val) return TypeError.InvalidArgsCount;
                    for (call.args[1..]) |arg| {
                        _ = try self.checkExpr(arg, scope);
                    }
                    return try self.makeStringType();
                }
                if (lowering_rules.isHashCall(call)) {
                    if (call.args.len != 1) return TypeError.InvalidArgsCount;
                    const arg_ty = try self.checkExpr(call.args[0], scope);
                    if (!self.typeIsHash(arg_ty)) return TypeError.TypeMismatch;
                    return try self.makeU64Type();
                }
                if (lowering_rules.isDebugCall(call)) {
                    if (call.args.len != 1) return TypeError.InvalidArgsCount;
                    const arg_ty = try self.checkExpr(call.args[0], scope);
                    if (!self.typeIsDebug(arg_ty)) return TypeError.TypeMismatch;
                    return try self.makeStringType();
                }
                if (lowering_rules.isPrintlnCall(call)) {
                    for (call.args) |arg| {
                        _ = try self.checkExpr(arg, scope);
                    }
                    const ret = try self.allocator.create(ast.Type);
                    ret.* = .{ .primitive = .void_type };
                    return ret;
                }

                if (lowering_rules.isPanicBuiltinName(call.func_name)) {
                    for (call.args) |arg| {
                        _ = try self.checkExpr(arg, scope);
                    }
                    const ret = try self.allocator.create(ast.Type);
                    ret.* = .{ .primitive = .void_type };
                    return ret;
                }

                if (std.mem.eql(u8, call.func_name, "std__panic__catch_unwind") or
                    (call.associated_target != null and std.mem.eql(u8, call.associated_target.?, "panic") and std.mem.eql(u8, call.func_name, "catch_unwind")))
                {
                    if (call.args.len != 1) return TypeError.InvalidArgsCount;
                    const closure_expr = call.args[0];
                    const closure_ty = try self.checkExpr(closure_expr, scope);
                    if (closure_ty.* != .closure or closure_ty.closure.params.len != 0) return TypeError.TypeMismatch;
                    if (closure_expr.* != .closure_literal or closure_expr.closure_literal.body.* != .call_expr) {
                        self.setError("catch_unwind currently only supports direct panic bodies", .{});
                        return TypeError.TypeMismatch;
                    }
                    const body_call = closure_expr.closure_literal.body.call_expr;
                    if (!lowering_rules.isPanicBuiltinName(body_call.func_name)) {
                        self.setError("catch_unwind currently only supports direct panic bodies", .{});
                        return TypeError.TypeMismatch;
                    }
                    return try self.makeResultType(try self.makeI32Type(), try self.makeI32Type());
                }

                if (scope.lookup(call.func_name)) |sym| {
                    if (sym.state == .consumed) return TypeError.UseAfterMove;
                    if (sym.ty.* == .closure) {
                        const closure = sym.ty.closure;
                        if (closure.params.len != call.args.len) return TypeError.InvalidArgsCount;
                        for (closure.params, call.args) |param_ty, arg| {
                            const arg_ty = try self.checkExpr(arg, scope);
                            if (!self.plainCallArgMatches(param_ty, arg, arg_ty)) return TypeError.TypeMismatch;
                            if (!self.arrayCallArgStrictMatches(param_ty, arg_ty)) return TypeError.TypeMismatch;
                        }
                        return closure.ret;
                    }
                    if (sym.ty.* == .fn_ptr) {
                        const fn_ptr = sym.ty.fn_ptr;
                        if (fn_ptr.is_variadic) {
                            if (call.args.len < fn_ptr.params.len) {
                                self.setError("call through variadic function pointer needs at least {} arguments ({} fixed), got {}", .{ fn_ptr.params.len, fn_ptr.params.len, call.args.len });
                                return TypeError.InvalidArgsCount;
                            }
                        } else if (fn_ptr.params.len != call.args.len) return TypeError.InvalidArgsCount;
                        const fn_fixed = if (fn_ptr.is_variadic) fn_ptr.params.len else call.args.len;
                        for (fn_ptr.params, call.args[0..fn_fixed]) |param_ty, arg| {
                            const arg_ty = try self.checkExpr(arg, scope);
                            if (!self.plainCallArgMatches(param_ty, arg, arg_ty)) return TypeError.TypeMismatch;
                            if (!self.arrayCallArgStrictMatches(param_ty, arg_ty)) return TypeError.TypeMismatch;
                        }
                        if (fn_ptr.is_variadic) {
                            for (call.args[fn_fixed..]) |arg| {
                                try self.checkVariadicTrailingArg(arg, scope, call.func_name);
                            }
                        }
                        self.fn_ptr_calls.put(expr, {}) catch return TypeError.OutOfMemory;
                        return fn_ptr.ret;
                    }
                }

                var module_alias_buf: [512]u8 = undefined;
                const module_local_name = if (self.current_function_namespace) |namespace|
                    std.fmt.bufPrint(&module_alias_buf, "{s}__{s}", .{ namespace, call.func_name }) catch null
                else
                    null;
                const resolved_func_name = if (module_local_name) |alias|
                    if (self.funcs.contains(alias) or self.imported_function_signatures.contains(alias)) alias else self.resolveFunctionAlias(call.func_name)
                else if (self.funcs.contains(call.func_name) or self.imported_function_signatures.contains(call.func_name))
                    call.func_name
                else
                    self.resolveFunctionAlias(call.func_name);
                if (call.associated_target == null) {
                    if (try self.tryResolveOverloadCall(expr, call, resolved_func_name, module_local_name, scope)) |ret_ty| {
                        return ret_ty;
                    }
                }

                if (self.funcs.get(resolved_func_name)) |func| {
                    try self.checkCallArgsAgainstFunc(func, call.args, scope, call.func_name, false);
                    if (!std.mem.eql(u8, resolved_func_name, call.func_name) or
                        self.resolveFunctionAliasMetadata(call.func_name) != null or
                        self.resolveFunctionAliasMetadata(resolved_func_name) != null)
                    {
                        try self.recordResolvedCallSymbol(expr, call.func_name, resolved_func_name);
                    }
                    if (func.is_async) {
                        return try self.makeFutureType(func.ret_ty);
                    }
                    return func.ret_ty;
                }

                if (self.imported_function_signatures.get(resolved_func_name)) |signature| {
                    try self.checkCallArgsAgainstSignature(signature.params, call.args, scope, call.func_name, false, signature.is_variadic);
                    if (!std.mem.eql(u8, resolved_func_name, call.func_name) or
                        self.resolveFunctionAliasMetadata(call.func_name) != null or
                        self.resolveFunctionAliasMetadata(resolved_func_name) != null)
                    {
                        try self.recordResolvedCallSymbol(expr, call.func_name, resolved_func_name);
                    }
                    if (signature.is_async) return try self.makeFutureType(signature.ret_ty);
                    return signature.ret_ty;
                }

                if (self.structs.get(call.func_name)) |decl| {
                    if (decl.is_opaque) {
                        self.setError("cannot construct opaque type {s}", .{call.func_name});
                        return TypeError.NotAStruct;
                    }
                    if (decl.fields.len != call.args.len) return TypeError.InvalidArgsCount;
                    for (decl.fields, call.args) |field, arg| {
                        const arg_ty = try self.checkExpr(arg, scope);
                        if (!self.typesEqual(field.ty, unwrapBorrowForCallArg(arg, arg_ty))) return TypeError.TypeMismatch;
                    }
                    const ret = try self.allocator.create(ast.Type);
                    ret.* = .{ .user_defined = .{ .name = decl.name, .generics = &.{} } };
                    return ret;
                }

                if (call.args.len > 0) {
                    const recv_ty = try self.checkExpr(call.args[0], scope);
                    if (optionInnerType(recv_ty)) |inner_ty| {
                        if (lowering_rules.isOptionQueryCall(call)) {
                            if (call.args.len != 1) return TypeError.InvalidArgsCount;
                            const ty = try self.allocator.create(ast.Type);
                            ty.* = .{ .primitive = .boolean };
                            return ty;
                        }
                        if (lowering_rules.isCopiedCall(call)) {
                            if (call.args.len != 1) return TypeError.InvalidArgsCount;
                            if (inner_ty.* != .borrow) return TypeError.TypeMismatch;
                            return try self.makeOptionType(inner_ty.borrow);
                        }
                        if (lowering_rules.isMapCall(call)) {
                            if (call.args.len != 2) return TypeError.InvalidArgsCount;
                            const closure_ty = if (call.args[1].* == .closure_literal)
                                try self.checkClosureLiteralWithContext(call.args[1], scope, &.{inner_ty})
                            else
                                try self.checkExpr(call.args[1], scope);
                            if (closure_ty.* != .closure) return TypeError.TypeMismatch;
                            if (closure_ty.closure.params.len != 1) return TypeError.InvalidArgsCount;
                            if (!self.typesEqual(closure_ty.closure.params[0], inner_ty)) return TypeError.TypeMismatch;
                            return try self.makeOptionType(closure_ty.closure.ret);
                        }
                        if (lowering_rules.isAndThenCall(call)) {
                            if (call.args.len != 2) return TypeError.InvalidArgsCount;
                            const closure_ty = if (call.args[1].* == .closure_literal)
                                try self.checkClosureLiteralWithContext(call.args[1], scope, &.{inner_ty})
                            else
                                try self.checkExpr(call.args[1], scope);
                            if (closure_ty.* != .closure) return TypeError.TypeMismatch;
                            if (closure_ty.closure.params.len != 1) return TypeError.InvalidArgsCount;
                            if (!self.typesEqual(closure_ty.closure.params[0], inner_ty)) return TypeError.TypeMismatch;
                            if (optionInnerType(closure_ty.closure.ret) == null) return TypeError.TypeMismatch;
                            return closure_ty.closure.ret;
                        }
                        if (lowering_rules.isUnwrapCall(call)) {
                            if (call.args.len != 1) return TypeError.InvalidArgsCount;
                            return inner_ty;
                        }
                        if (lowering_rules.isUnwrapOrCall(call)) {
                            if (call.args.len != 2) return TypeError.InvalidArgsCount;
                            const default_ty = try self.checkExpr(call.args[1], scope);
                            if (!self.typesEqual(inner_ty, default_ty)) return TypeError.TypeMismatch;
                            return inner_ty;
                        }
                        if (lowering_rules.isUnwrapOrElseCall(call)) {
                            if (call.args.len != 2) return TypeError.InvalidArgsCount;
                            const closure_ty = if (call.args[1].* == .closure_literal)
                                try self.checkClosureLiteralWithContext(call.args[1], scope, &.{})
                            else
                                try self.checkExpr(call.args[1], scope);
                            if (closure_ty.* != .closure) return TypeError.TypeMismatch;
                            if (closure_ty.closure.params.len != 0) return TypeError.InvalidArgsCount;
                            if (!self.typesEqual(inner_ty, closure_ty.closure.ret)) return TypeError.TypeMismatch;
                            return inner_ty;
                        }
                        if (lowering_rules.isUnwrapOrDefaultCall(call)) {
                            if (call.args.len != 1) return TypeError.InvalidArgsCount;
                            return inner_ty;
                        }
                    }

                    if (resultOkType(recv_ty)) |ok_ty| {
                        if (lowering_rules.isResultQueryCall(call)) {
                            if (call.args.len != 1) return TypeError.InvalidArgsCount;
                            const ty = try self.allocator.create(ast.Type);
                            ty.* = .{ .primitive = .boolean };
                            return ty;
                        }
                        if (lowering_rules.isMapCall(call)) {
                            if (call.args.len != 2) return TypeError.InvalidArgsCount;
                            const err_ty = resultErrType(recv_ty) orelse return TypeError.TypeMismatch;
                            const closure_ty = if (call.args[1].* == .closure_literal)
                                try self.checkClosureLiteralWithContext(call.args[1], scope, &.{ok_ty})
                            else
                                try self.checkExpr(call.args[1], scope);
                            if (closure_ty.* != .closure) return TypeError.TypeMismatch;
                            if (closure_ty.closure.params.len != 1) return TypeError.InvalidArgsCount;
                            if (!self.typesEqual(closure_ty.closure.params[0], ok_ty)) return TypeError.TypeMismatch;
                            return try self.makeResultType(closure_ty.closure.ret, err_ty);
                        }
                        if (lowering_rules.isUnwrapCall(call)) {
                            if (call.args.len != 1) return TypeError.InvalidArgsCount;
                            return ok_ty;
                        }
                        if (lowering_rules.isUnwrapOrCall(call)) {
                            if (call.args.len != 2) return TypeError.InvalidArgsCount;
                            const default_ty = try self.checkExpr(call.args[1], scope);
                            if (!self.typesEqual(ok_ty, default_ty)) return TypeError.TypeMismatch;
                            return ok_ty;
                        }
                    }

                    if (isAtomicI32Type(recv_ty)) {
                        if (lowering_rules.isLoadCall(call)) {
                            if (call.args.len != 2) return TypeError.InvalidArgsCount;
                            const ordering_ty = try self.checkExpr(call.args[1], scope);
                            if (!isOrderingType(ordering_ty)) return TypeError.TypeMismatch;
                            return try self.makeI32Type();
                        }
                        if (lowering_rules.isStoreCall(call)) {
                            if (call.args.len != 3) return TypeError.InvalidArgsCount;
                            const value_ty = try self.checkExpr(call.args[1], scope);
                            const ordering_ty = try self.checkExpr(call.args[2], scope);
                            if (!isNumericType(value_ty) or !isOrderingType(ordering_ty)) return TypeError.TypeMismatch;
                            const ret = try self.allocator.create(ast.Type);
                            ret.* = .{ .primitive = .void_type };
                            return ret;
                        }
                        if (lowering_rules.isFetchAddCall(call)) {
                            if (call.args.len != 3) return TypeError.InvalidArgsCount;
                            const value_ty = try self.checkExpr(call.args[1], scope);
                            const ordering_ty = try self.checkExpr(call.args[2], scope);
                            if (!isNumericType(value_ty) or !isOrderingType(ordering_ty)) return TypeError.TypeMismatch;
                            return try self.makeI32Type();
                        }
                        if (lowering_rules.isCompareExchangeCall(call)) {
                            if (call.args.len != 5) return TypeError.InvalidArgsCount;
                            const expected_ty = try self.checkExpr(call.args[1], scope);
                            const new_ty = try self.checkExpr(call.args[2], scope);
                            const success_ty = try self.checkExpr(call.args[3], scope);
                            const failure_ty = try self.checkExpr(call.args[4], scope);
                            if (!isNumericType(expected_ty) or !isNumericType(new_ty) or !isOrderingType(success_ty) or !isOrderingType(failure_ty)) return TypeError.TypeMismatch;
                            const i32_ty = try self.makeI32Type();
                            return try self.makeResultType(i32_ty, i32_ty);
                        }
                    }

                    if (isAtomicUsizeType(recv_ty)) {
                        if (lowering_rules.isLoadCall(call)) {
                            if (call.args.len != 2) return TypeError.InvalidArgsCount;
                            const ordering_ty = try self.checkExpr(call.args[1], scope);
                            if (!isOrderingType(ordering_ty)) return TypeError.TypeMismatch;
                            const ty = try self.allocator.create(ast.Type);
                            ty.* = .{ .primitive = .usize };
                            return ty;
                        }
                        if (lowering_rules.isStoreCall(call)) {
                            if (call.args.len != 3) return TypeError.InvalidArgsCount;
                            const value_ty = try self.checkExpr(call.args[1], scope);
                            const ordering_ty = try self.checkExpr(call.args[2], scope);
                            if (!isNumericType(value_ty) or !isOrderingType(ordering_ty)) return TypeError.TypeMismatch;
                            const ret = try self.allocator.create(ast.Type);
                            ret.* = .{ .primitive = .void_type };
                            return ret;
                        }
                        if (lowering_rules.isFetchAddCall(call)) {
                            if (call.args.len != 3) return TypeError.InvalidArgsCount;
                            const value_ty = try self.checkExpr(call.args[1], scope);
                            const ordering_ty = try self.checkExpr(call.args[2], scope);
                            if (!isNumericType(value_ty) or !isOrderingType(ordering_ty)) return TypeError.TypeMismatch;
                            const ty = try self.allocator.create(ast.Type);
                            ty.* = .{ .primitive = .usize };
                            return ty;
                        }
                    }

                    if (cellInnerType(recv_ty)) |inner_ty| {
                        if (lowering_rules.isGetCall(call)) {
                            if (call.args.len != 1) return TypeError.InvalidArgsCount;
                            return inner_ty;
                        }
                        if (lowering_rules.isSetCall(call)) {
                            if (call.args.len != 2) return TypeError.InvalidArgsCount;
                            const value_ty = try self.checkExpr(call.args[1], scope);
                            if (!self.typesEqual(inner_ty, value_ty)) {
                                self.setError("Cell::set type mismatch: cell tag={s}, value tag={s}", .{ @tagName(inner_ty.*), @tagName(value_ty.*) });
                                return TypeError.TypeMismatch;
                            }
                            const ret = try self.allocator.create(ast.Type);
                            ret.* = .{ .primitive = .void_type };
                            return ret;
                        }
                    }

                    if (refCellInnerType(recv_ty)) |inner_ty| {
                        if (std.mem.eql(u8, call.func_name, "borrow") or std.mem.eql(u8, call.func_name, "borrow_mut")) {
                            if (call.args.len != 1) return TypeError.InvalidArgsCount;
                            return try self.makeBorrowType(inner_ty);
                        }
                    }

                    if (mutexInnerType(recv_ty)) |inner_ty| {
                        if (std.mem.eql(u8, call.func_name, "lock")) {
                            if (call.args.len != 1) return TypeError.InvalidArgsCount;
                            return try self.makeResultType(try self.makeMutexGuardType(inner_ty), try self.makeI32Type());
                        }
                    }

                    if (rwLockInnerType(recv_ty)) |inner_ty| {
                        if (std.mem.eql(u8, call.func_name, "read")) {
                            if (call.args.len != 1) return TypeError.InvalidArgsCount;
                            return try self.makeResultType(try self.makeRwLockReadGuardType(inner_ty), try self.makeI32Type());
                        }
                        if (std.mem.eql(u8, call.func_name, "write")) {
                            if (call.args.len != 1) return TypeError.InvalidArgsCount;
                            return try self.makeResultType(try self.makeRwLockWriteGuardType(inner_ty), try self.makeI32Type());
                        }
                    }

                    if (isFileType(recv_ty)) {
                        if (std.mem.eql(u8, call.func_name, "as_raw_fd")) {
                            if (call.args.len != 1) return TypeError.InvalidArgsCount;
                            return try self.makeI32Type();
                        }
                    }

                    if (isMetadataType(recv_ty)) {
                        if (std.mem.eql(u8, call.func_name, "is_file") or std.mem.eql(u8, call.func_name, "is_dir") or std.mem.eql(u8, call.func_name, "is_symlink")) {
                            if (call.args.len != 1) return TypeError.InvalidArgsCount;
                            const ty = try self.allocator.create(ast.Type);
                            ty.* = .{ .primitive = .boolean };
                            return ty;
                        }
                        if (std.mem.eql(u8, call.func_name, "modified_ms") or std.mem.eql(u8, call.func_name, "created_ms")) {
                            if (call.args.len != 1) return TypeError.InvalidArgsCount;
                            const ty = try self.allocator.create(ast.Type);
                            ty.* = .{ .primitive = .i64 };
                            return ty;
                        }
                    }

                    if (lowering_rules.isMetadataCall(call)) {
                        if (call.args.len != 1) return TypeError.InvalidArgsCount;
                        if (isStringLikeType(recv_ty)) {
                            return try self.makeResultType(try self.makeMetadataType(), try self.makeI32Type());
                        }
                    }

                    if (joinHandleInnerType(recv_ty)) |inner_ty| {
                        if (lowering_rules.isJoinCall(call)) {
                            if (call.args.len != 1) return TypeError.InvalidArgsCount;
                            return try self.makeResultType(inner_ty, try self.makeI32Type());
                        }
                    }

                    if (senderInnerType(recv_ty)) |inner_ty| {
                        if (lowering_rules.isCloneCall(call)) {
                            if (call.args.len != 1) return TypeError.InvalidArgsCount;
                            return recv_ty;
                        }
                        if (lowering_rules.isSendCall(call)) {
                            if (call.args.len != 2) return TypeError.InvalidArgsCount;
                            const value_ty = try self.checkExpr(call.args[1], scope);
                            if (!self.typesEqual(inner_ty, value_ty)) return TypeError.TypeMismatch;
                            const void_ty = try self.allocator.create(ast.Type);
                            void_ty.* = .{ .primitive = .void_type };
                            return try self.makeResultType(void_ty, try self.makeI32Type());
                        }
                    }

                    if (receiverInnerType(recv_ty)) |inner_ty| {
                        if (lowering_rules.isRecvCall(call)) {
                            if (call.args.len != 1) return TypeError.InvalidArgsCount;
                            return try self.makeResultType(inner_ty, try self.makeI32Type());
                        }
                    }

                    if (rcInnerType(recv_ty) != null and lowering_rules.isCloneCall(call)) {
                        if (call.args.len != 1) return TypeError.InvalidArgsCount;
                        return unwrappedReceiverType(recv_ty);
                    }

                    if (arcInnerType(recv_ty) != null and lowering_rules.isCloneCall(call)) {
                        if (call.args.len != 1) return TypeError.InvalidArgsCount;
                        return unwrappedReceiverType(recv_ty);
                    }

                    if (atomicPtrInnerType(recv_ty)) |inner_ty| {
                        if (lowering_rules.isLoadCall(call)) {
                            if (call.args.len != 2) return TypeError.InvalidArgsCount;
                            const ordering_ty = try self.checkExpr(call.args[1], scope);
                            if (!isOrderingType(ordering_ty)) return TypeError.TypeMismatch;
                            return try self.makePointerType(inner_ty);
                        }
                    }

                    if (vecDequeElementType(recv_ty)) |elem_ty| {
                        if (std.mem.eql(u8, call.func_name, "rotate_left")) {
                            if (call.args.len != 2) return TypeError.InvalidArgsCount;
                            const count_ty = try self.checkExpr(call.args[1], scope);
                            if (!isNumericType(count_ty)) return TypeError.TypeMismatch;
                            const ret = try self.allocator.create(ast.Type);
                            ret.* = .{ .primitive = .void_type };
                            return ret;
                        }
                        if (lowering_rules.isPushBackCall(call)) {
                            if (call.args.len != 2) return TypeError.InvalidArgsCount;
                            const value_ty = try self.checkExpr(call.args[1], scope);
                            if (!self.typesEqual(elem_ty, value_ty)) return TypeError.TypeMismatch;
                            if (elem_ty.* == .infer) {
                                if (rootIdentifier(call.args[0])) |recv_name| {
                                    if (scope.lookup(recv_name)) |sym| {
                                        const concrete_ty = try self.makeVecDequeType(value_ty);
                                        sym.ty = concrete_ty;
                                        self.expr_types.put(call.args[0], concrete_ty) catch return TypeError.OutOfMemory;
                                    }
                                }
                            }
                            const ret = try self.allocator.create(ast.Type);
                            ret.* = .{ .primitive = .void_type };
                            return ret;
                        }
                        if (lowering_rules.isPopFrontCall(call)) {
                            if (call.args.len != 1) return TypeError.InvalidArgsCount;
                            if (elem_ty.* == .infer) return TypeError.TypeMismatch;
                            return try self.makeOptionType(elem_ty);
                        }
                    }

                    if (arrayType(recv_ty)) |arr| {
                        if (lowering_rules.isAsPtrCall(call)) {
                            if (call.args.len != 1) return TypeError.InvalidArgsCount;
                            return try self.makePointerType(arr.elem);
                        }
                        if (std.mem.eql(u8, call.func_name, "fill")) {
                            if (call.args.len != 2) return TypeError.InvalidArgsCount;
                            const value_ty = try self.checkExpr(call.args[1], scope);
                            if (!self.typesEqual(arr.elem, value_ty)) return TypeError.TypeMismatch;
                            const ret = try self.allocator.create(ast.Type);
                            ret.* = .{ .primitive = .void_type };
                            return ret;
                        }
                    }

                    if (isStringLikeType(recv_ty)) {
                        if (lowering_rules.isAsPtrCall(call)) {
                            if (call.args.len != 1) return TypeError.InvalidArgsCount;
                            return try self.makePointerType(try self.makeU8Type());
                        }
                        if (std.mem.eql(u8, call.func_name, "as_bytes") or std.mem.eql(u8, call.func_name, "bytes")) {
                            if (call.args.len != 1) return TypeError.InvalidArgsCount;
                            return try self.makeSliceType(try self.makeU8Type());
                        }
                        if (std.mem.eql(u8, call.func_name, "try_exists") or
                            std.mem.eql(u8, call.func_name, "is_file") or
                            std.mem.eql(u8, call.func_name, "is_dir") or
                            std.mem.eql(u8, call.func_name, "is_symlink"))
                        {
                            if (call.args.len != 1) return TypeError.InvalidArgsCount;
                            const ty = try self.allocator.create(ast.Type);
                            ty.* = .{ .primitive = .boolean };
                            return ty;
                        }
                    }

                    if (sliceElementType(recv_ty)) |elem_ty| {
                        if (lowering_rules.isAsPtrCall(call)) {
                            if (call.args.len != 1) return TypeError.InvalidArgsCount;
                            return try self.makePointerType(elem_ty);
                        }
                    }

                    if (recv_ty.* == .pointer and std.mem.eql(u8, call.func_name, "add")) {
                        if (call.args.len != 2) return TypeError.InvalidArgsCount;
                        const index_ty = try self.checkExpr(call.args[1], scope);
                        if (!isAnyIntegerType(index_ty)) return TypeError.TypeMismatch;
                        return recv_ty;
                    }

                    if (hashMapTypes(recv_ty)) |hm| {
                        if (lowering_rules.isInsertCall(call)) {
                            if (call.args.len != 3) return TypeError.InvalidArgsCount;
                            const key_ty = try self.checkExpr(call.args[1], scope);
                            const value_ty = try self.checkExpr(call.args[2], scope);
                            if (!self.typesEqual(hm.key, key_ty) or !self.typesEqual(hm.value, value_ty)) return TypeError.TypeMismatch;
                            if (rootIdentifier(call.args[0])) |recv_name| {
                                if (scope.lookup(recv_name)) |sym| {
                                    if (hm.key.* == .infer or hm.value.* == .infer) {
                                        const concrete_ty = try self.makeHashMapType(key_ty, value_ty);
                                        sym.ty = concrete_ty;
                                        self.expr_types.put(call.args[0], concrete_ty) catch return TypeError.OutOfMemory;
                                    }
                                }
                            }
                            return try self.makeOptionType(value_ty);
                        }
                        if (lowering_rules.isGetCall(call)) {
                            if (call.args.len != 2) return TypeError.InvalidArgsCount;
                            const key_ty = try self.checkExpr(call.args[1], scope);
                            if (!self.typesEqual(hm.key, key_ty)) return TypeError.TypeMismatch;
                            return try self.makeOptionType(try self.makeBorrowType(hm.value));
                        }
                        if (lowering_rules.isClearCall(call)) {
                            if (call.args.len != 1) return TypeError.InvalidArgsCount;
                            _ = try self.checkExpr(call.args[0], scope);
                            const void_ty = try self.allocator.create(ast.Type);
                            void_ty.* = .{ .primitive = .void_type };
                            return void_ty;
                        }
                    }

                    if (hashSetTypes(recv_ty)) |hs| {
                        if (lowering_rules.isInsertCall(call)) {
                            if (call.args.len != 2) return TypeError.InvalidArgsCount;
                            const key_ty = try self.checkExpr(call.args[1], scope);
                            if (!self.typesEqual(hs.key, key_ty)) return TypeError.TypeMismatch;
                            if (rootIdentifier(call.args[0])) |recv_name| {
                                if (scope.lookup(recv_name)) |sym| {
                                    if (hs.key.* == .infer) {
                                        const concrete_ty = try self.makeHashSetType(key_ty);
                                        sym.ty = concrete_ty;
                                        self.expr_types.put(call.args[0], concrete_ty) catch return TypeError.OutOfMemory;
                                    }
                                }
                            }
                            const ty = try self.allocator.create(ast.Type);
                            ty.* = .{ .primitive = .boolean };
                            return ty;
                        }
                        if (lowering_rules.isContainsCall(call)) {
                            if (call.args.len != 2) return TypeError.InvalidArgsCount;
                            const key_ty = try self.checkExpr(call.args[1], scope);
                            if (!self.typesEqual(hs.key, key_ty)) return TypeError.TypeMismatch;
                            const ty = try self.allocator.create(ast.Type);
                            ty.* = .{ .primitive = .boolean };
                            return ty;
                        }
                    }

                    if (btreeMapTypes(recv_ty)) |bm| {
                        if (lowering_rules.isInsertCall(call)) {
                            if (call.args.len != 3) return TypeError.InvalidArgsCount;
                            const key_ty = try self.checkExpr(call.args[1], scope);
                            const value_ty = try self.checkExpr(call.args[2], scope);
                            if (!self.typesEqual(bm.key, key_ty) or !self.typesEqual(bm.value, value_ty)) return TypeError.TypeMismatch;
                            if (!self.btreeSetKeySupported(key_ty)) return TypeError.TypeMismatch;
                            if (rootIdentifier(call.args[0])) |recv_name| {
                                if (scope.lookup(recv_name)) |sym| {
                                    if (bm.key.* == .infer or bm.value.* == .infer) {
                                        const concrete_ty = try self.makeBTreeMapType(key_ty, value_ty);
                                        sym.ty = concrete_ty;
                                        self.expr_types.put(call.args[0], concrete_ty) catch return TypeError.OutOfMemory;
                                    }
                                }
                            }
                            return try self.makeOptionType(value_ty);
                        }
                        if (lowering_rules.isGetCall(call)) {
                            if (call.args.len != 2) return TypeError.InvalidArgsCount;
                            const key_ty = try self.checkExpr(call.args[1], scope);
                            if (!self.typesEqual(bm.key, key_ty)) return TypeError.TypeMismatch;
                            if (!self.btreeSetKeySupported(key_ty)) return TypeError.TypeMismatch;
                            return try self.makeOptionType(try self.makeBorrowType(bm.value));
                        }
                        if (lowering_rules.isClearCall(call)) {
                            if (call.args.len != 1) return TypeError.InvalidArgsCount;
                            _ = try self.checkExpr(call.args[0], scope);
                            const void_ty = try self.allocator.create(ast.Type);
                            void_ty.* = .{ .primitive = .void_type };
                            return void_ty;
                        }
                    }

                    if (btreeSetTypes(recv_ty)) |bs| {
                        if (lowering_rules.isInsertCall(call)) {
                            if (call.args.len != 2) return TypeError.InvalidArgsCount;
                            const key_ty = try self.checkExpr(call.args[1], scope);
                            if (!self.typesEqual(bs.key, key_ty)) return TypeError.TypeMismatch;
                            if (!self.btreeSetKeySupported(key_ty)) return TypeError.TypeMismatch;
                            if (rootIdentifier(call.args[0])) |recv_name| {
                                if (scope.lookup(recv_name)) |sym| {
                                    if (bs.key.* == .infer) {
                                        const concrete_ty = try self.makeBTreeSetType(key_ty);
                                        sym.ty = concrete_ty;
                                        self.expr_types.put(call.args[0], concrete_ty) catch return TypeError.OutOfMemory;
                                    }
                                }
                            }
                            const ty = try self.allocator.create(ast.Type);
                            ty.* = .{ .primitive = .boolean };
                            return ty;
                        }
                        if (lowering_rules.isContainsCall(call)) {
                            if (call.args.len != 2) return TypeError.InvalidArgsCount;
                            const key_ty = try self.checkExpr(call.args[1], scope);
                            if (!self.typesEqual(bs.key, key_ty)) return TypeError.TypeMismatch;
                            if (!self.btreeSetKeySupported(key_ty)) return TypeError.TypeMismatch;
                            const ty = try self.allocator.create(ast.Type);
                            ty.* = .{ .primitive = .boolean };
                            return ty;
                        }
                    }

                    if (dynDispatchTraitName(recv_ty)) |trait_name| {
                        if (self.findTraitMethod(trait_name, call.func_name)) |method| {
                            if (method.params.len != call.args.len) return TypeError.InvalidArgsCount;
                            for (method.params[1..], call.args[1..]) |param, arg| {
                                const arg_ty = try self.checkExpr(arg, scope);
                                if (!self.typesEqual(param.ty, unwrapBorrowForCallArg(arg, arg_ty))) {
                                    self.setError("dyn method {s} argument mismatch: param tag={s}, arg tag={s}", .{ call.func_name, @tagName(param.ty.*), @tagName(arg_ty.*) });
                                    return TypeError.TypeMismatch;
                                }
                            }
                            self.dyn_call_traits.put(expr, trait_name) catch return TypeError.OutOfMemory;
                            return method.ret_ty;
                        }
                    }
                }

                if (std.mem.eql(u8, call.func_name, "push")) {
                    if (call.args.len != 2) return TypeError.InvalidArgsCount;
                    const recv_ty = try self.checkExpr(call.args[0], scope);
                    const elem_ty = vecElementType(recv_ty) orelse return TypeError.TypeMismatch;
                    const arg_ty = try self.checkExpr(call.args[1], scope);
                    if (!self.typesEqual(elem_ty, arg_ty)) return TypeError.TypeMismatch;
                    if (elem_ty.* == .infer) {
                        if (rootIdentifier(call.args[0])) |recv_name| {
                            if (scope.lookup(recv_name)) |sym| {
                                const concrete_ty = try self.makeVecType(arg_ty);
                                sym.ty = concrete_ty;
                                self.expr_types.put(call.args[0], concrete_ty) catch return TypeError.OutOfMemory;
                            }
                        }
                    }
                    const ret = try self.allocator.create(ast.Type);
                    ret.* = .{ .primitive = .void_type };
                    return ret;
                }

                if (std.mem.eql(u8, call.func_name, "pop")) {
                    if (call.args.len != 1) return TypeError.InvalidArgsCount;
                    const recv_ty = try self.checkExpr(call.args[0], scope);
                    const elem_ty = vecElementType(recv_ty) orelse return TypeError.TypeMismatch;
                    if (elem_ty.* == .infer) return TypeError.TypeMismatch;
                    return try self.makeOptionType(elem_ty);
                }

                if (lowering_rules.isRemoveCall(call)) {
                    if (call.args.len != 2) return TypeError.InvalidArgsCount;
                    const recv_ty = try self.checkExpr(call.args[0], scope);
                    const elem_ty = vecElementType(recv_ty) orelse return TypeError.TypeMismatch;
                    const index_ty = try self.checkExpr(call.args[1], scope);
                    if (!isNumericType(index_ty)) return TypeError.TypeMismatch;
                    if (elem_ty.* == .infer) return TypeError.TypeMismatch;
                    return elem_ty;
                }

                // 1. Check Sla internal function calls
                const method_match = blk: {
                    if (call.args.len == 0) break :blk null;
                    const recv_ty = try self.checkExpr(call.args[0], scope);
                    const curr = lowering_rules.peelBorrowPointerType(recv_ty);
                    if (curr.* != .user_defined) break :blk null;
                    var method_buf: [256]u8 = undefined;
                    break :blk std.fmt.bufPrint(&method_buf, "{s}_{s}", .{ curr.user_defined.name, call.func_name }) catch null;
                };

                if (method_match) |method_name| {
                    if (self.funcs.get(method_name)) |func| {
                        try self.checkCallArgsAgainstFunc(func, call.args, scope, call.func_name, true);
                        const resolved = std.fmt.allocPrint(self.allocator, "{s}", .{method_name}) catch return TypeError.OutOfMemory;
                        self.resolved_call_symbols.put(expr, resolved) catch return TypeError.OutOfMemory;
                        if (func.is_async) {
                            return try self.makeFutureType(func.ret_ty);
                        }
                        return func.ret_ty;
                    }
                    if (self.imported_function_signatures.get(method_name)) |signature| {
                        try self.checkCallArgsAgainstSignature(signature.params, call.args, scope, call.func_name, true, signature.is_variadic);
                        const resolved = std.fmt.allocPrint(self.allocator, "{s}", .{method_name}) catch return TypeError.OutOfMemory;
                        self.resolved_call_symbols.put(expr, resolved) catch return TypeError.OutOfMemory;
                        if (signature.is_async) return try self.makeFutureType(signature.ret_ty);
                        return signature.ret_ty;
                    }
                }

                if (call.args.len > 0) {
                    const recv_ty = try self.checkExpr(call.args[0], scope);
                    if (concreteTypeName(recv_ty)) |type_name| {
                        if (try self.resolveTraitMethodSymbolForType(type_name, null, call.func_name, call.args.len)) |symbol| {
                            if (try self.checkStaticCallBySymbol(expr, symbol, call.args, scope, call.func_name, true)) |ret_ty| return ret_ty;
                            return TypeError.UndefinedVariable;
                        }
                    }
                }

                if (lowering_rules.isIterOrIntoIterCall(call)) {
                    if (call.args.len != 1) return TypeError.InvalidArgsCount;
                    const target_ty = try self.checkExpr(call.args[0], scope);
                    if (arrayType(target_ty) == null and vecElementType(target_ty) == null and sliceElementType(target_ty) == null) return TypeError.TypeMismatch;
                    return target_ty;
                }

                if (lowering_rules.isCopiedCall(call)) {
                    if (call.args.len != 1) return TypeError.InvalidArgsCount;
                    const target_ty = try self.checkExpr(call.args[0], scope);
                    if (arrayType(target_ty) == null and vecElementType(target_ty) == null and sliceElementType(target_ty) == null) return TypeError.TypeMismatch;
                    return target_ty;
                }

                if (std.mem.eql(u8, call.func_name, "collect")) {
                    if (call.args.len != 1 or call.generics.len != 1) return TypeError.InvalidArgsCount;
                    if (!isStringType(call.generics[0])) return TypeError.TypeMismatch;
                    const target_ty = try self.checkExpr(call.args[0], scope);
                    const elem_ty = iterableElementType(target_ty) orelse return TypeError.TypeMismatch;
                    if (!isPrimitiveType(elem_ty, .u8)) return TypeError.TypeMismatch;
                    return try self.makeStringType();
                }

                if (lowering_rules.isJoinCall(call)) {
                    if (call.args.len != 2) return TypeError.InvalidArgsCount;
                    const target_ty = try self.checkExpr(call.args[0], scope);
                    const elem_ty = iterableElementType(target_ty) orelse return TypeError.TypeMismatch;
                    if (!isStringLikeType(elem_ty) and !isStringType(elem_ty)) return TypeError.TypeMismatch;
                    const sep_ty = try self.checkExpr(call.args[1], scope);
                    if (!isStringLikeType(sep_ty) and !isStringType(sep_ty)) return TypeError.TypeMismatch;
                    return try self.makeStringType();
                }

                if (lowering_rules.isMapCall(call)) {
                    if (call.args.len != 2) return TypeError.InvalidArgsCount;
                    const source_ty = try self.checkExpr(call.args[0], scope);
                    const elem_ty = if (arrayType(source_ty)) |arr| arr.elem else vecElementType(source_ty) orelse return TypeError.TypeMismatch;
                    const closure_ty = if (call.args[1].* == .closure_literal)
                        try self.checkClosureLiteralWithContext(call.args[1], scope, &.{elem_ty})
                    else
                        try self.checkExpr(call.args[1], scope);
                    if (closure_ty.* != .closure) return TypeError.TypeMismatch;
                    if (closure_ty.closure.params.len != 1) return TypeError.InvalidArgsCount;
                    if (!self.typesEqual(closure_ty.closure.params[0], elem_ty)) return TypeError.TypeMismatch;
                    if (arrayType(source_ty)) |arr| {
                        const ty = try self.allocator.create(ast.Type);
                        ty.* = .{ .array = .{ .elem = closure_ty.closure.ret, .len = arr.len } };
                        return ty;
                    }
                    const generics = try self.allocator.alloc(*ast.Type, 1);
                    generics[0] = closure_ty.closure.ret;
                    const ty = try self.allocator.create(ast.Type);
                    ty.* = .{ .user_defined = .{ .name = "Vec", .generics = generics } };
                    return ty;
                }

                if (std.mem.eql(u8, call.func_name, "filter")) {
                    if (call.args.len != 2) return TypeError.InvalidArgsCount;
                    const source_ty = try self.checkExpr(call.args[0], scope);
                    const elem_ty = if (arrayType(source_ty)) |arr| arr.elem else vecElementType(source_ty) orelse return TypeError.TypeMismatch;
                    const closure_ty = if (call.args[1].* == .closure_literal)
                        try self.checkClosureLiteralWithContext(call.args[1], scope, &.{elem_ty})
                    else
                        try self.checkExpr(call.args[1], scope);
                    if (closure_ty.* != .closure) return TypeError.TypeMismatch;
                    if (closure_ty.closure.params.len != 1) return TypeError.InvalidArgsCount;
                    if (!self.typesEqual(closure_ty.closure.params[0], elem_ty)) return TypeError.TypeMismatch;
                    if (closure_ty.closure.ret.* != .primitive or closure_ty.closure.ret.primitive != .boolean) return TypeError.TypeMismatch;
                    return source_ty;
                }

                if (std.mem.eql(u8, call.func_name, "fold")) {
                    if (call.args.len != 3) return TypeError.InvalidArgsCount;
                    const source_ty = try self.checkExpr(call.args[0], scope);
                    const elem_ty = if (arrayType(source_ty)) |arr| arr.elem else vecElementType(source_ty) orelse return TypeError.TypeMismatch;
                    const init_ty = try self.checkExpr(call.args[1], scope);
                    const closure_ty = if (call.args[2].* == .closure_literal)
                        try self.checkClosureLiteralWithContext(call.args[2], scope, &.{ init_ty, elem_ty })
                    else
                        try self.checkExpr(call.args[2], scope);
                    if (closure_ty.* != .closure) return TypeError.TypeMismatch;
                    if (closure_ty.closure.params.len != 2) return TypeError.InvalidArgsCount;
                    const acc_ty = closure_ty.closure.params[0];
                    if (!self.typesEqual(acc_ty, init_ty)) return TypeError.TypeMismatch;
                    if (!self.typesEqual(closure_ty.closure.params[1], elem_ty)) return TypeError.TypeMismatch;
                    if (!self.typesEqual(closure_ty.closure.ret, acc_ty)) return TypeError.TypeMismatch;
                    return acc_ty;
                }

                if (std.mem.eql(u8, call.func_name, "sum")) {
                    if (call.args.len != 1) return TypeError.InvalidArgsCount;
                    const target_ty = try self.checkExpr(call.args[0], scope);
                    if (arrayType(target_ty)) |arr| {
                        const ret = try self.allocator.create(ast.Type);
                        ret.* = arr.elem.*;
                        return ret;
                    }
                    if (sliceElementType(target_ty)) |elem_ty| {
                        return elem_ty;
                    }
                    if (vecElementType(target_ty)) |elem_ty| {
                        return elem_ty;
                    }
                    return TypeError.TypeMismatch;
                }

                // 2. Check FFI functions (validation shared with the
                // overload resolver's extern-contract winners).
                if (self.extern_funcs.get(call.func_name)) |ext| {
                    return try self.checkExternContractCall(ext, call, scope);
                }

                // 3. Check if it's a built-in: stack_alloc, panic
                if (std.mem.eql(u8, call.func_name, "stack_alloc") or
                    lowering_rules.isPanicBuiltinName(call.func_name))
                {
                    for (call.args) |arg| {
                        _ = try self.checkExpr(arg, scope);
                    }
                    const ret = try self.allocator.create(ast.Type);
                    ret.* = .{ .primitive = if (std.mem.eql(u8, call.func_name, "stack_alloc")) .raw_ptr else .void_type };
                    return ret;
                }

                // 4. Check user-defined macro calls
                if (self.macros.get(call.func_name)) |mac| {
                    // View-types stage 1: explicit borrow arguments to a
                    // local macro get the same pairwise place-overlap
                    // validation (macro params carry no borrow flags, so
                    // only borrow-expression arguments are treated as
                    // borrowed places).
                    try self.checkCallArgPlaceOverlaps(null, call.args, scope, call.func_name, null, 0);
                    // J-4 (leading_output_convention, Jev
                    // slasl_macro_ruling j4): a user macro with exactly
                    // one leading output parameter (the same name rule
                    // as imported SA macros) may be called with the
                    // output argument omitted; the call is then an
                    // expression whose type is the output parameter's
                    // declared type (J-3). Full-arity calls keep the
                    // statement form and return void.
                    var param_offset: usize = 0;
                    var expr_output_ty: ?*ast.Type = null;
                    if (call.args.len == mac.params.len) {
                        // Full statement form.
                    } else if (call.args.len + 1 == mac.params.len and userMacroLeadingOutputCount(mac) == 1) {
                        param_offset = 1;
                        expr_output_ty = mac.declaredParamType(0) orelse {
                            self.setError("MacroExpressionOutputUntyped: macro `{s}` is used as an expression, so its leading output parameter `{s}` must declare a type (J-3 typed macro parameters)", .{ call.func_name, mac.params[0] });
                            return TypeError.TypeMismatch;
                        };
                    } else {
                        self.setError("macro {s} expects {} args, got {}", .{ call.func_name, mac.params.len, call.args.len });
                        return TypeError.InvalidArgsCount;
                    }
                    var arg_types = std.array_list.Managed(*ast.Type).init(self.allocator);
                    defer arg_types.deinit();
                    for (call.args) |arg| {
                        try arg_types.append(try self.checkExpr(arg, scope));
                    }
                    // J-3 (typed_macro_params): an argument bound to a
                    // parameter with a declared type must match that
                    // type, under the same compatibility rule as plain
                    // function call arguments.
                    for (call.args, arg_types.items, 0..) |arg, arg_ty, arg_index| {
                        const param_index = arg_index + param_offset;
                        if (mac.declaredParamType(param_index)) |declared_ty| {
                            if (!self.plainCallArgMatches(declared_ty, arg, arg_ty)) {
                                self.setError("TypeMismatch in call to macro `{s}`: parameter `{s}` is declared {s} but the argument has type {s}", .{ call.func_name, mac.params[param_index], typeDesc(declared_ty), typeDesc(arg_ty) });
                                return TypeError.TypeMismatch;
                            }
                        }
                    }
                    var propagated_args = std.StringHashMap(void).init(self.allocator);
                    defer propagated_args.deinit();
                    const has_macro_try = try self.macroHasTry(mac);
                    for (call.args, 0..) |arg, arg_index| {
                        const index = arg_index + param_offset;
                        if (!try self.macroParamIsTrySource(mac, index)) continue;
                        if (rootIdentifier(arg)) |name| try propagated_args.put(name, {});
                    }
                    if (has_macro_try) {
                        var cleanup = std.array_list.Managed([]const u8).init(self.allocator);
                        errdefer cleanup.deinit();
                        var current: ?*Scope = scope;
                        while (current) |frame| {
                            var symbols = frame.symbols.valueIterator();
                            while (symbols.next()) |sym| {
                                if (sym.state != .active or isInternalSymbol(sym.name) or propagated_args.contains(sym.name)) continue;
                                try cleanup.append(sym.name);
                            }
                            current = frame.parent;
                        }
                        try self.macro_call_try_cleanups.put(&expr.call_expr, cleanup);
                    }
                    for (call.args, 0..) |arg, arg_index| {
                        const index = arg_index + param_offset;
                        const consumption = try self.macroParamConsumption(mac, index);
                        if (consumption == .never) continue;
                        if (consumption == .conditional) {
                            self.setError("MacroConditionalConsume: macro `{s}` consumes parameter `{s}` only on some control-flow paths", .{ call.func_name, mac.params[index] });
                            return TypeError.CompileError;
                        }
                        if (arg.* != .identifier) continue;
                        const sym = scope.lookup(arg.identifier) orelse return TypeError.UndefinedVariable;
                        if (sym.state == .consumed) return TypeError.UseAfterMove;
                        try self.consumeBinding(scope, arg.identifier, sym, "user macro move");
                    }
                    if (expr_output_ty) |ty| return ty;
                    const ret = try self.allocator.create(ast.Type);
                    ret.* = .{ .primitive = .void_type };
                    return ret;
                }

                if (self.imported_macros.get(call.func_name)) |macro| {
                    // View-types stage 1: same pairwise place-overlap
                    // validation for imported macro calls; borrowed slots
                    // come from the macro's declared masks and write
                    // capability is unknown, so identical-place overlaps
                    // are rejected.
                    try self.checkCallArgPlaceOverlaps(null, call.args, scope, call.func_name, null, macro.borrowed_arg_mask | macro.address_slot_arg_mask);
                    for (call.args) |arg| {
                        _ = try self.checkExpr(arg, scope);
                    }
                    if (call.args.len == macro.arity) {
                        const ret = try self.allocator.create(ast.Type);
                        ret.* = .{ .primitive = .void_type };
                        return ret;
                    }
                    if (lowering_rules.importedMacroUsesExpressionOutput(macro, call.args.len)) {
                        if (lowering_rules.importedMacroExpressionResultKind(call.func_name)) |kind| {
                            return try self.makeImportedMacroExpressionResultType(kind);
                        }
                        return try self.makeInferType();
                    }
                    self.setError("macro {s} expects {} args or {} args when using expression output, got {}", .{ call.func_name, macro.arity, macro.arity - 1, call.args.len });
                    return TypeError.InvalidArgsCount;
                }

                if (call.associated_target) |target_name| {
                    if (std.mem.eql(u8, target_name, "str") and std.mem.eql(u8, call.func_name, "from_utf8")) {
                        if (call.args.len != 1) return TypeError.InvalidArgsCount;
                        const bytes_ty = try self.checkExpr(call.args[0], scope);
                        const slice_elem = sliceElementType(bytes_ty) orelse {
                            if (call.args[0].* == .borrow_expr) {
                                const borrowed_ty = try self.checkExpr(call.args[0].borrow_expr.expr, scope);
                                const borrowed_arr = arrayType(borrowed_ty) orelse return TypeError.TypeMismatch;
                                if (!isPrimitiveType(borrowed_arr.elem, .u8)) return TypeError.TypeMismatch;
                                self.array_to_slice_borrow_args.put(call.args[0], {}) catch return TypeError.OutOfMemory;
                                return try self.makeResultType(try self.makeStringType(), try self.makeI32Type());
                            }
                            return TypeError.TypeMismatch;
                        };
                        if (!isPrimitiveType(slice_elem, .u8)) return TypeError.TypeMismatch;
                        return try self.makeResultType(try self.makeStringType(), try self.makeI32Type());
                    }
                }

                self.setError("Undefined call: {s}", .{call.func_name});
                if (call.args.len > 0) {
                    const recv_ty = try self.checkExpr(call.args[0], scope);
                    const curr = lowering_rules.peelBorrowPointerType(recv_ty);
                    if (curr.* == .user_defined) {
                        var method_buf: [256]u8 = undefined;
                        const method_key = std.fmt.bufPrint(&method_buf, "{s}_{s}", .{ curr.user_defined.name, call.func_name }) catch null;
                        if (method_key) |mk| {
                            if (self.funcs.get(mk)) |func| {
                                if (func.params.len != call.args.len) return TypeError.InvalidArgsCount;
                                for (func.params, call.args) |param, arg| {
                                    if (param.is_move and arg.* != .move_expr) {
                                        self.setError("Call to {s} requires move argument for parameter {s}", .{ call.func_name, param.name });
                                        return TypeError.TypeMismatch;
                                    }
                                    if (param.is_borrow) {
                                        if (dynTraitName(param.ty)) |trait_name| {
                                            const arg_ty = try self.checkExpr(arg, scope);
                                            if (dynDispatchTraitName(arg_ty)) |arg_trait_name| {
                                                if (!self.traitExtendsTrait(arg_trait_name, trait_name)) {
                                                    self.setError("Type does not implement trait {s} for parameter {s}", .{ trait_name, param.name });
                                                    return TypeError.TypeMismatch;
                                                }
                                                continue;
                                            }
                                            const concrete_ty = switch (arg_ty.*) {
                                                .borrow => |inner| inner,
                                                else => null,
                                            } orelse {
                                                self.setError("Call to {s} requires dyn borrow for parameter {s}", .{ call.func_name, param.name });
                                                return TypeError.TypeMismatch;
                                            };
                                            if (!self.typeImplementsTrait(concrete_ty, trait_name)) {
                                                self.setError("Type does not implement trait {s} for parameter {s}", .{ trait_name, param.name });
                                                return TypeError.TypeMismatch;
                                            }
                                            self.dyn_borrow_args.put(arg, trait_name) catch return TypeError.OutOfMemory;
                                            continue;
                                        }
                                    }
                                    if (param.is_borrow and arg.* != .borrow_expr) {
                                        const arg_ty = try self.checkExpr(arg, scope);
                                        if (dynTraitName(param.ty)) |target_trait| {
                                            if (dynDispatchTraitName(arg_ty)) |arg_trait_name| {
                                                if (!self.traitExtendsTrait(arg_trait_name, target_trait)) {
                                                    self.setError("Type does not implement trait {s} for parameter {s}", .{ target_trait, param.name });
                                                    return TypeError.TypeMismatch;
                                                }
                                                continue;
                                            }
                                        }
                                        if (arg_ty.* != .borrow or !self.typesEqual(param.ty, arg_ty.borrow)) {
                                            self.setError("Call to {s} requires borrow argument for parameter {s}", .{ call.func_name, param.name });
                                            return TypeError.TypeMismatch;
                                        }
                                        continue;
                                    }
                                    if (!param.is_move and !param.is_borrow and arg.* == .move_expr) {
                                        self.setError("Call to {s} passes capability argument to plain parameter {s}", .{ call.func_name, param.name });
                                        return TypeError.TypeMismatch;
                                    }
                                    const arg_ty = try self.checkExpr(arg, scope);
                                    if (!self.plainCallArgMatches(param.ty, arg, arg_ty)) return TypeError.TypeMismatch;
                                    if (!self.arrayCallArgStrictMatches(param.ty, arg_ty)) {
                                        self.setError("TypeMismatch in call to {s}: array element type mismatch (stride differs)", .{call.func_name});
                                        return TypeError.TypeMismatch;
                                    }
                                }
                                if (func.is_async) return try self.makeFutureType(func.ret_ty);
                                return func.ret_ty;
                            }
                        }
                    }
                }

                // If not found anywhere, undefined function call
                return TypeError.UndefinedVariable;
            },
            .if_expr => |*ife| {
                if (ife.let_chain) |chain| {
                    var saved_states = try self.saveScopeStates(scope);
                    defer saved_states.deinit();

                    const chain_scope = try Scope.init(self.allocator, scope);
                    try self.scope_pool.append(chain_scope);

                    for (chain) |cond| {
                        const value_ty = try self.checkExpr(cond.value, chain_scope);
                        try self.definePatternBindings(chain_scope, cond.pattern, value_ty, "if let", true);
                    }

                    try self.checkBlock(ife.then_block, chain_scope, scope.lookup("return_ty_sentinel").?.ty, null, self.current_loop_scope);

                    var then_states = try self.saveScopeStates(scope);
                    defer then_states.deinit();
                    self.restoreScopeStates(scope, &saved_states);

                    if (ife.else_block) |eb| {
                        try self.checkBlock(eb, scope, scope.lookup("return_ty_sentinel").?.ty, null, self.current_loop_scope);
                    }

                    const merge_action = control_flow_rules.planBranchStateMerge(
                        blockTerminates(ife.then_block),
                        if (ife.else_block) |eb| blockTerminates(eb) else false,
                    );
                    switch (merge_action) {
                        .restore_pre => self.restoreScopeStates(scope, &saved_states),
                        .restore_then => self.restoreScopeStates(scope, &then_states),
                        .restore_else => {},
                        .keep_current => {
                            var curr: ?*Scope = scope;
                            while (curr) |s| {
                                var iter = s.symbols.iterator();
                                while (iter.next()) |entry| {
                                    const name = entry.key_ptr.*;
                                    if (isInternalSymbol(name)) continue;
                                    const else_state = entry.value_ptr.state;
                                    const then_state = then_states.get(name) orelse .active;

                                    if (then_state != else_state) {
                                        if (then_state == .uninitialized or else_state == .uninitialized) {
                                            entry.value_ptr.state = .uninitialized;
                                            continue;
                                        }
                                        entry.value_ptr.state = .consumed;
                                        if (then_state == .active) {
                                            if (ife.then_block.len > 0) {
                                                const last = ife.then_block[ife.then_block.len - 1];
                                                var list = self.phi_cleanups.get(last) orelse std.array_list.Managed([]const u8).init(self.allocator);
                                                try list.append(name);
                                                try self.phi_cleanups.put(last, list);
                                            }
                                        } else if (ife.else_block) |eb| {
                                            if (eb.len > 0) {
                                                const last = eb[eb.len - 1];
                                                var list = self.phi_cleanups.get(last) orelse std.array_list.Managed([]const u8).init(self.allocator);
                                                try list.append(name);
                                                try self.phi_cleanups.put(last, list);
                                            }
                                        }
                                    }
                                }
                                curr = s.parent;
                            }
                        },
                    }

                    const then_ty = self.blockTailExprType(ife.then_block);
                    if (ife.else_block) |eb| {
                        const else_ty = self.blockTailExprType(eb);
                        if (then_ty == null or else_ty == null) {
                            const ty = try self.allocator.create(ast.Type);
                            ty.* = .{ .primitive = .void_type };
                            return ty;
                        }
                        if (!self.typesEqual(then_ty.?, else_ty.?)) {
                            self.setError("if expression branch type mismatch", .{});
                            return TypeError.TypeMismatch;
                        }
                        return then_ty.?;
                    }

                    const ty = try self.allocator.create(ast.Type);
                    ty.* = .{ .primitive = .void_type };
                    return ty;
                }

                const cond_ty = try self.checkExpr(ife.cond, scope);
                // Comparisons produce integers (0/1) in SA; booleans are also fine.
                if (cond_ty.* == .infer) {
                    // Macro parameter condition; the call site supplies the concrete type.
                } else if (cond_ty.* != .primitive) {
                    return TypeError.TypeMismatch;
                } else switch (cond_ty.primitive) {
                    .boolean, .integer => {},
                    else => return TypeError.TypeMismatch,
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
                try self.checkBlock(ife.then_block, scope, scope.lookup("return_ty_sentinel").?.ty, null, self.current_loop_scope);

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
                    try self.checkBlock(eb, scope, scope.lookup("return_ty_sentinel").?.ty, null, self.current_loop_scope);
                }

                const merge_action = control_flow_rules.planBranchStateMerge(
                    blockTerminates(ife.then_block),
                    if (ife.else_block) |eb| blockTerminates(eb) else false,
                );
                switch (merge_action) {
                    .restore_pre => self.restoreScopeStates(scope, &saved_states),
                    .restore_then => self.restoreScopeStates(scope, &then_states),
                    .restore_else => {},
                    .keep_current => {
                        // Re-align states at merge point (Phi Resolution).
                        // If a variable is active in one branch but consumed in another,
                        // release it in the active branch.
                        curr = scope;
                        while (curr) |s| {
                            var iter = s.symbols.iterator();
                            while (iter.next()) |entry| {
                                const name = entry.key_ptr.*;
                                if (isInternalSymbol(name)) continue;
                                const else_state = entry.value_ptr.state;
                                const then_state = then_states.get(name) orelse .active;

                                if (then_state != else_state) {
                                    if (then_state == .uninitialized or else_state == .uninitialized) {
                                        entry.value_ptr.state = .uninitialized;
                                        continue;
                                    }
                                    entry.value_ptr.state = .consumed;

                                    if (then_state == .active) {
                                        if (ife.then_block.len > 0) {
                                            const last = ife.then_block[ife.then_block.len - 1];
                                            var list = self.phi_cleanups.get(last) orelse std.array_list.Managed([]const u8).init(self.allocator);
                                            try list.append(name);
                                            try self.phi_cleanups.put(last, list);
                                        }
                                    } else if (ife.else_block) |eb| {
                                        if (eb.len > 0) {
                                            const last = eb[eb.len - 1];
                                            var list = self.phi_cleanups.get(last) orelse std.array_list.Managed([]const u8).init(self.allocator);
                                            try list.append(name);
                                            try self.phi_cleanups.put(last, list);
                                        }
                                    }
                                }
                            }
                            curr = s.parent;
                        }
                    },
                }

                const then_ty = self.blockTailExprType(ife.then_block);
                if (ife.else_block) |eb| {
                    const else_ty = self.blockTailExprType(eb);
                    if (then_ty == null or else_ty == null) {
                        const ty = try self.allocator.create(ast.Type);
                        ty.* = .{ .primitive = .void_type };
                        return ty;
                    }
                    if (!self.typesEqual(then_ty.?, else_ty.?)) {
                        self.setError("if expression branch type mismatch", .{});
                        return TypeError.TypeMismatch;
                    }
                    return then_ty.?;
                }

                const ty = try self.allocator.create(ast.Type);
                ty.* = .{ .primitive = .void_type };
                return ty;
            },
            .switch_expr => |*swe| {
                const val_ty = try self.checkExpr(swe.val, scope);
                _ = val_ty;

                var saved_states = try self.saveScopeStates(scope);
                defer saved_states.deinit();
                var live_states = std.array_list.Managed(std.StringHashMap(ValueState)).init(self.allocator);
                defer {
                    for (live_states.items) |*states| states.deinit();
                    live_states.deinit();
                }
                var live_bodies = std.array_list.Managed([]const *ast.Node).init(self.allocator);
                defer live_bodies.deinit();

                for (swe.cases) |case| {
                    self.restoreScopeStates(scope, &saved_states);
                    try self.checkBlock(case.body, scope, scope.lookup("return_ty_sentinel").?.ty, null, self.current_loop_scope);
                    if (!blockTerminates(case.body)) {
                        var states = try self.saveScopeStates(scope);
                        errdefer states.deinit();
                        try live_bodies.append(case.body);
                        try live_states.append(states);
                    }
                }
                try self.mergeMultiBranchScopeStates(scope, &saved_states, live_states.items, live_bodies.items);

                const ty = try self.allocator.create(ast.Type);
                ty.* = .{ .primitive = .void_type };
                return ty;
            },
            .match_expr => |*mat| {
                var val_ty = try self.checkExpr(mat.val, scope);
                if (val_ty.* == .infer and mat.cases.len != 0) {
                    const first_pattern = mat.cases[0].pattern;
                    const inferred = if (std.mem.eql(u8, first_pattern.enum_name, "Option") or
                        std.mem.eql(u8, first_pattern.variant_name, "Some") or
                        std.mem.eql(u8, first_pattern.variant_name, "None"))
                        try self.makeOptionType(try self.makeInferType())
                    else if (std.mem.eql(u8, first_pattern.enum_name, "Result") or
                        std.mem.eql(u8, first_pattern.variant_name, "Ok") or
                        std.mem.eql(u8, first_pattern.variant_name, "Err"))
                        try self.makeResultType(try self.makeInferType(), try self.makeInferType())
                    else blk: {
                        const enum_decl = self.enums.get(first_pattern.enum_name) orelse return TypeError.TypeMismatch;
                        const ty = try self.allocator.create(ast.Type);
                        ty.* = .{ .user_defined = .{ .name = enum_decl.name, .generics = &.{} } };
                        break :blk ty;
                    };
                    if (mat.val.* == .identifier) {
                        const sym = scope.lookup(mat.val.identifier) orelse return TypeError.UndefinedVariable;
                        sym.ty = inferred;
                    }
                    self.expr_types.put(mat.val, inferred) catch return TypeError.OutOfMemory;
                    val_ty = inferred;
                }
                if (optionInnerType(val_ty) != null or resultOkType(val_ty) != null) {
                    var saved_states = try self.saveScopeStates(scope);
                    defer saved_states.deinit();
                    var live_states = std.array_list.Managed(std.StringHashMap(ValueState)).init(self.allocator);
                    defer {
                        for (live_states.items) |*states| states.deinit();
                        live_states.deinit();
                    }
                    var live_bodies = std.array_list.Managed([]const *ast.Node).init(self.allocator);
                    defer live_bodies.deinit();

                    var result_ty: ?*ast.Type = null;
                    var has_value_cases = true;
                    for (mat.cases) |case| {
                        self.restoreScopeStates(scope, &saved_states);

                        const pattern_scope = try Scope.init(self.allocator, scope);
                        try self.scope_pool.append(pattern_scope);
                        const binding_ty = try self.patternBindingType(case.pattern, val_ty, "match");
                        if (binding_ty) |ty| {
                            try self.defineSymbol(pattern_scope, case.pattern.bindings[0], ty, true);
                        }
                        if (case.guard) |guard| {
                            const guard_ty = try self.checkExpr(guard, pattern_scope);
                            if (guard_ty.* != .primitive) return TypeError.TypeMismatch;
                            switch (guard_ty.primitive) {
                                .boolean, .integer => {},
                                else => return TypeError.TypeMismatch,
                            }
                        }

                        try self.checkBlock(case.body, pattern_scope, scope.lookup("return_ty_sentinel").?.ty, null, self.current_loop_scope);
                        const terminated = blockTerminates(case.body);
                        if (!terminated) {
                            var states = try self.saveScopeStates(scope);
                            errdefer states.deinit();
                            try live_bodies.append(case.body);
                            try live_states.append(states);
                        }
                        if (self.blockTailExprType(case.body)) |case_ty| {
                            if (terminated) continue;
                            if (result_ty) |existing| {
                                if (!self.typesEqual(existing, case_ty)) return TypeError.TypeMismatch;
                            } else {
                                result_ty = case_ty;
                            }
                        } else if (!terminated) {
                            has_value_cases = false;
                        }
                    }

                    try self.mergeMultiBranchScopeStates(scope, &saved_states, live_states.items, live_bodies.items);

                    if (has_value_cases) {
                        if (result_ty) |ty| return ty;
                    }
                    const ty = try self.allocator.create(ast.Type);
                    ty.* = .{ .primitive = .void_type };
                    return ty;
                }

                if (val_ty.* != .user_defined) return TypeError.TypeMismatch;
                const decl = self.enums.get(val_ty.user_defined.name) orelse return TypeError.NotAStruct;

                var saved_states = try self.saveScopeStates(scope);
                defer saved_states.deinit();
                var live_states = std.array_list.Managed(std.StringHashMap(ValueState)).init(self.allocator);
                defer {
                    for (live_states.items) |*states| states.deinit();
                    live_states.deinit();
                }
                var live_bodies = std.array_list.Managed([]const *ast.Node).init(self.allocator);
                defer live_bodies.deinit();

                var result_ty: ?*ast.Type = null;
                var has_value_cases = true;
                for (mat.cases) |case| {
                    self.restoreScopeStates(scope, &saved_states);

                    if (!enumNameMatchesDecl(case.pattern.enum_name, decl.name)) return TypeError.TypeMismatch;
                    const variant = findEnumVariant(decl, case.pattern.variant_name) orelse return TypeError.FieldNotFound;
                    if (case.pattern.bindings.len != variant.fields.len) return TypeError.InvalidArgsCount;

                    const pattern_scope = try Scope.init(self.allocator, scope);
                    try self.scope_pool.append(pattern_scope);
                    for (case.pattern.bindings, variant.fields) |binding, field| {
                        try self.defineSymbol(pattern_scope, binding, field.ty, true);
                    }
                    if (case.guard) |guard| {
                        const guard_ty = try self.checkExpr(guard, pattern_scope);
                        if (guard_ty.* != .primitive) return TypeError.TypeMismatch;
                        switch (guard_ty.primitive) {
                            .boolean, .integer => {},
                            else => return TypeError.TypeMismatch,
                        }
                    }
                    try self.checkBlock(case.body, pattern_scope, scope.lookup("return_ty_sentinel").?.ty, null, self.current_loop_scope);

                    const terminated = blockTerminates(case.body);
                    if (!terminated) {
                        var states = try self.saveScopeStates(scope);
                        errdefer states.deinit();
                        try live_bodies.append(case.body);
                        try live_states.append(states);
                    }
                    const case_ty = self.blockTailExprType(case.body);
                    if (case_ty) |ty| {
                        if (terminated) continue;
                        if (result_ty) |existing| {
                            if (!self.typesEqual(existing, ty)) return TypeError.TypeMismatch;
                        } else {
                            result_ty = ty;
                        }
                    } else {
                        if (!terminated) has_value_cases = false;
                    }
                }

                try self.mergeMultiBranchScopeStates(scope, &saved_states, live_states.items, live_bodies.items);

                if (has_value_cases and result_ty != null) {
                    return result_ty.?;
                }

                const ty = try self.allocator.create(ast.Type);
                ty.* = .{ .primitive = .void_type };
                return ty;
            },
            .unsafe_expr => |ue| {
                self.unsafe_depth += 1;
                defer self.unsafe_depth -= 1;
                try self.checkBlock(ue.body, scope, scope.lookup("return_ty_sentinel").?.ty, null, self.current_loop_scope);
                if (blockTerminates(ue.body)) {
                    const ty = try self.allocator.create(ast.Type);
                    ty.* = .{ .primitive = .void_type };
                    return ty;
                }
                if (self.blockTailExprType(ue.body)) |tail_ty| return tail_ty;
                const ty = try self.allocator.create(ast.Type);
                ty.* = .{ .primitive = .void_type };
                return ty;
            },
            .try_expr => |trye| {
                const inner_ty = try self.checkExpr(trye.expr, scope);
                if (trye.expr.* == .identifier) {
                    if (scope.lookup(trye.expr.identifier)) |source| {
                        if (!self.typeIsCopy(source.ty) and !isBorrowLikeType(source.ty)) try self.consumeBinding(scope, trye.expr.identifier, source, "try propagation");
                    }
                }

                if (inner_ty.* == .infer) return inner_ty;

                if (optionInnerType(inner_ty)) |unwrapped_ty| {
                    var try_cleanup = std.array_list.Managed([]const u8).init(self.allocator);
                    var curr: ?*Scope = scope;
                    while (curr) |s| {
                        var iter = s.symbols.valueIterator();
                        while (iter.next()) |sym| {
                            if (sym.state == .active and !isInternalSymbol(sym.name)) {
                                if (exprUsesIdentifierValue(trye.expr, sym.name)) continue;
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
                }

                if (resultOkType(inner_ty)) |unwrapped_ty| {
                    var try_cleanup = std.array_list.Managed([]const u8).init(self.allocator);
                    var curr: ?*Scope = scope;
                    while (curr) |s| {
                        var iter = s.symbols.valueIterator();
                        while (iter.next()) |sym| {
                            if (sym.state == .active and !isInternalSymbol(sym.name)) {
                                if (exprUsesIdentifierValue(trye.expr, sym.name)) continue;
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
                }

                // Unwrapped type is the type of the "value" field of the Result struct
                const struct_ty = lowering_rules.peelBorrowPointerType(inner_ty);

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
                var try_cleanup = std.array_list.Managed([]const u8).init(self.allocator);
                var curr: ?*Scope = scope;
                while (curr) |s| {
                    var iter = s.symbols.valueIterator();
                    while (iter.next()) |sym| {
                        if (sym.state == .active and !isInternalSymbol(sym.name)) {
                            if (exprUsesIdentifierValue(trye.expr, sym.name)) continue;
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
        if (a.* == .infer or b.* == .infer) return true;
        if (std.meta.activeTag(a.*) != std.meta.activeTag(b.*)) return false;
        switch (a.*) {
            .infer => return true,
            .primitive => |pa| {
                if (pa == b.primitive) return true;
                return switch (pa) {
                    .integer => isAnyIntegerType(b),
                    .float => isAnyFloatType(b),
                    .i8, .i16, .i32, .i64, .isize, .u8, .u16, .u32, .u64, .usize => isAnyIntegerType(b),
                    .f32, .f64 => isAnyFloatType(b),
                    else => false,
                };
            },
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
            .fn_ptr => |fa| {
                if (fa.abi == null) {
                    if (b.fn_ptr.abi != null) return false;
                } else if (b.fn_ptr.abi == null or !std.mem.eql(u8, fa.abi.?, b.fn_ptr.abi.?)) {
                    return false;
                }
                if (fa.is_variadic != b.fn_ptr.is_variadic) return false;
                if (fa.params.len != b.fn_ptr.params.len) return false;
                for (fa.params, b.fn_ptr.params) |pa, pb| {
                    if (!self.typesEqual(pa, pb)) return false;
                }
                return self.typesEqual(fa.ret, b.fn_ptr.ret);
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

    /// Short human-readable label for diagnostics. Unlike `@tagName(ty.*)` this
    /// distinguishes primitive widths and named types, so `expected u32, actual i32`
    /// no longer collapses into `expected primitive, actual primitive`.
    fn typeDesc(ty: *const ast.Type) []const u8 {
        return switch (ty.*) {
            .infer => "infer",
            .primitive => |p| @tagName(p),
            .pointer => "pointer",
            .borrow => "borrow",
            .array => "array",
            .tuple => "tuple",
            .future => "future",
            .closure => "closure",
            .fn_ptr => "fn_ptr",
            .user_defined => |ud| ud.name,
        };
    }

    fn checkImpl(self: *TypeChecker, impl_decl: *ast.ImplDecl) !void {
        if (impl_decl.trait_name) |trait_name| {
            try self.checkTraitImpl(trait_name, impl_decl);
        }
        for (impl_decl.methods) |method| {
            if (method.* != .func_decl) return TypeError.CompileError;
            try self.checkFunc(&method.func_decl);
        }
    }

    fn typeEqualsWithSelf(self: *TypeChecker, actual: *ast.Type, expected: *ast.Type, self_ty: *ast.Type) bool {
        if (expected.* == .user_defined and std.mem.eql(u8, expected.user_defined.name, "Self")) {
            return self.typesEqual(actual, self_ty);
        }
        if (std.meta.activeTag(actual.*) != std.meta.activeTag(expected.*)) return self.typesEqual(actual, expected);
        switch (expected.*) {
            .borrow => |inner| return actual.* == .borrow and self.typeEqualsWithSelf(actual.borrow, inner, self_ty),
            .pointer => |inner| return actual.* == .pointer and self.typeEqualsWithSelf(actual.pointer, inner, self_ty),
            .array => |arr| return actual.* == .array and actual.array.len == arr.len and self.typeEqualsWithSelf(actual.array.elem, arr.elem, self_ty),
            .tuple => |tuple| {
                if (actual.* != .tuple or actual.tuple.elems.len != tuple.elems.len) return false;
                for (actual.tuple.elems, tuple.elems) |a, e| {
                    if (!self.typeEqualsWithSelf(a, e, self_ty)) return false;
                }
                return true;
            },
            .future => |inner| return actual.* == .future and self.typeEqualsWithSelf(actual.future, inner, self_ty),
            .fn_ptr => |fn_ptr| {
                if (actual.* != .fn_ptr) return false;
                if (fn_ptr.is_variadic != actual.fn_ptr.is_variadic) return false;
                if (fn_ptr.params.len != actual.fn_ptr.params.len) return false;
                for (actual.fn_ptr.params, fn_ptr.params) |a, e| {
                    if (!self.typeEqualsWithSelf(a, e, self_ty)) return false;
                }
                return self.typeEqualsWithSelf(actual.fn_ptr.ret, fn_ptr.ret, self_ty);
            },
            .user_defined => |ud| {
                if (actual.* != .user_defined or !std.mem.eql(u8, actual.user_defined.name, ud.name) or actual.user_defined.generics.len != ud.generics.len) return false;
                for (actual.user_defined.generics, ud.generics) |a, e| {
                    if (!self.typeEqualsWithSelf(a, e, self_ty)) return false;
                }
                return true;
            },
            else => return self.typesEqual(actual, expected),
        }
    }

    fn implMethodFor(impl_decl: *ast.ImplDecl, name: []const u8) ?*ast.FuncDecl {
        for (impl_decl.methods) |method| {
            if (method.* == .func_decl and std.mem.eql(u8, method.func_decl.name, name)) return &method.func_decl;
        }
        return null;
    }

    fn checkTraitImpl(self: *TypeChecker, trait_name: []const u8, impl_decl: *ast.ImplDecl) TypeError!void {
        const trait_decl = self.traits.get(trait_name) orelse return TypeError.UndefinedVariable;
        const target_name = try self.typeName(impl_decl.target_ty);
        for (trait_decl.supertraits) |supertrait| {
            if (!self.typeDirectlyImplementsTrait(target_name, supertrait)) {
                self.setError("Trait impl `{s}` for `{s}` requires separate impl of supertrait `{s}`", .{ trait_name, target_name, supertrait });
                return TypeError.UndefinedVariable;
            }
        }
        for (impl_decl.methods) |method| {
            if (method.* != .func_decl) return TypeError.CompileError;
            if (self.findTraitOwnMethod(trait_name, method.func_decl.name) == null) {
                self.setError("Trait impl for `{s}` contains method `{s}` not declared by trait `{s}`", .{ target_name, method.func_decl.name, trait_name });
                return TypeError.TypeMismatch;
            }
        }
        for (trait_decl.methods) |trait_method| {
            const impl_method = implMethodFor(impl_decl, trait_method.name) orelse {
                self.setError("Trait impl missing method `{s}` for trait `{s}`", .{ trait_method.name, trait_name });
                return TypeError.UndefinedVariable;
            };
            if (impl_method.params.len != trait_method.params.len) return TypeError.InvalidArgsCount;
            for (impl_method.params, trait_method.params) |actual, expected| {
                if (actual.is_borrow != expected.is_borrow or actual.is_move != expected.is_move) return TypeError.TypeMismatch;
                if (!self.typeEqualsWithSelf(actual.ty, expected.ty, impl_decl.target_ty)) return TypeError.TypeMismatch;
            }
            if (!self.typeEqualsWithSelf(impl_method.ret_ty, trait_method.ret_ty, impl_decl.target_ty)) return TypeError.TypeMismatch;
        }
    }
};

test "type checker basic validation" {
    // We can write tests here if we want to build it, but user requested 'no rushing to compile'.
    // Let's ensure the semantic correctness.
}

test "type checker classifies loop local release ownership" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var int_ty = ast.Type{ .primitive = .i64 };
    const function_scope = try Scope.init(arena.allocator(), null);
    try function_scope.define("outer", &int_ty, false);
    const loop_scope = try Scope.init(arena.allocator(), function_scope);
    try loop_scope.define("item", &int_ty, false);
    const nested_scope = try Scope.init(arena.allocator(), loop_scope);
    try nested_scope.define("inner", &int_ty, false);

    try std.testing.expect(!bindingIsLocalToLoop(nested_scope, loop_scope, "outer"));
    try std.testing.expect(bindingIsLocalToLoop(nested_scope, loop_scope, "item"));
    try std.testing.expect(bindingIsLocalToLoop(nested_scope, loop_scope, "inner"));
}

test "type checker resolves registered function alias" {
    var tc = TypeChecker.init(std.testing.allocator);
    defer tc.deinit();

    try tc.registerFunctionAliasWithMetadata("dep__imported_a", "imported_a", "dep", "/tmp/dep.sla");
    try std.testing.expectEqualStrings("imported_a", tc.resolveFunctionAlias("dep__imported_a"));
    try std.testing.expectEqualStrings("plain_name", tc.resolveFunctionAlias("plain_name"));

    const metadata = tc.resolveFunctionAliasMetadata("dep__imported_a");
    try std.testing.expect(metadata != null);
    try std.testing.expectEqualStrings("dep__imported_a", metadata.?.alias);
    try std.testing.expectEqualStrings("imported_a", metadata.?.target);
    try std.testing.expect(metadata.?.namespace != null);
    try std.testing.expect(metadata.?.module_path != null);
    try std.testing.expectEqualStrings("dep", metadata.?.namespace.?);
    try std.testing.expectEqualStrings("/tmp/dep.sla", metadata.?.module_path.?);
    try std.testing.expect(tc.resolveFunctionAliasMetadata("plain_name") == null);
}

test "type checker resolves imported function signature without function body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var tc = TypeChecker.init(arena.allocator());
    defer tc.deinit();

    var ret_ty = ast.Type{ .primitive = .i32 };
    try tc.registerFunctionAliasWithMetadata("dep__imported_a", "imported_a", "dep", "/tmp/dep.sla");
    try tc.registerImportedFunctionSignature("imported_a", &.{}, &ret_ty, false, false);

    var call_node = ast.Node{ .call_expr = .{
        .func_name = "dep__imported_a",
        .associated_target = null,
        .generics = &.{},
        .args = &.{},
    } };
    var expr_stmt_node = ast.Node{ .expr_stmt = &call_node };
    var test_node = ast.Node{ .test_decl = .{
        .name = "imported signature only",
        .is_ignored = false,
        .should_panic = false,
        .body = &.{&expr_stmt_node},
    } };
    var program = ast.Node{ .program = .{ .decls = &.{&test_node} } };

    try tc.checkProgram(&program);
    const call_ty = tc.expr_types.get(&call_node) orelse return error.TestUnexpectedResult;
    try std.testing.expect(call_ty.* == .primitive);
    try std.testing.expectEqual(ast.Primitive.i32, call_ty.primitive);
    try std.testing.expect(tc.funcs.get("imported_a") == null);
    try std.testing.expectEqualStrings("imported_a", tc.resolved_call_symbols.get(&call_node).?);
    const call_metadata = tc.resolved_call_alias_metadata.get(&call_node);
    try std.testing.expect(call_metadata != null);
    try std.testing.expectEqualStrings("dep__imported_a", call_metadata.?.alias);
    try std.testing.expectEqualStrings("imported_a", call_metadata.?.target);
    try std.testing.expectEqualStrings("dep", call_metadata.?.namespace.?);
    try std.testing.expectEqualStrings("/tmp/dep.sla", call_metadata.?.module_path.?);
}

test "type checker allows raw ptr bindings from pointer abi returns" {
    const parser_mod = @import("parser.zig");

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source =
        \\fn assign_probe(data: ptr, len: u64) -> i32 {
        \\    var node: ptr;
        \\    node = abi_make_ptr(data, len);
        \\    return 0;
        \\}
        \\
        \\fn let_probe(data: ptr, len: u64) -> ptr {
        \\    let node: ptr = abi_make_ptr(data, len);
        \\    return node;
        \\}
        \\
        \\fn return_probe(data: ptr, len: u64) -> ptr {
        \\    return abi_make_ptr(data, len);
        \\}
    ;
    var parser = parser_mod.Parser.init(arena.allocator(), source);
    const program = try parser.parseProgram();

    var tc = TypeChecker.init(arena.allocator());
    defer tc.deinit();
    try tc.loadContracts(
        \\@extern abi_make_ptr(data: ptr, len: u64) -> ^ptr
    , "");
    try tc.checkProgram(program);
}

test "type checker rejects scalar btreeset keys" {
    const parser_mod = @import("parser.zig");

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const bad_source =
        \\fn main() -> i32 {
        \\    let s = BTreeSet::new();
        \\    s.insert(1);
        \\    return 0;
        \\}
    ;
    var bad_parser = parser_mod.Parser.init(arena.allocator(), bad_source);
    const bad_program = try bad_parser.parseProgram();
    var bad_tc = TypeChecker.init(arena.allocator());
    defer bad_tc.deinit();
    try std.testing.expectError(error.TypeMismatch, bad_tc.checkProgram(bad_program));

    const ok_source =
        \\fn main() -> i32 {
        \\    let s = BTreeSet::new();
        \\    s.insert("a");
        \\    return 0;
        \\}
    ;
    var ok_parser = parser_mod.Parser.init(arena.allocator(), ok_source);
    const ok_program = try ok_parser.parseProgram();
    var ok_tc = TypeChecker.init(arena.allocator());
    defer ok_tc.deinit();
    try ok_tc.checkProgram(ok_program);
}

test "type checker rejects scalar btreemap keys" {
    const parser_mod = @import("parser.zig");

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const bad_source =
        \\fn main() -> i32 {
        \\    let m = BTreeMap::new();
        \\    m.insert(1, 10);
        \\    return 0;
        \\}
    ;
    var bad_parser = parser_mod.Parser.init(arena.allocator(), bad_source);
    const bad_program = try bad_parser.parseProgram();
    var bad_tc = TypeChecker.init(arena.allocator());
    defer bad_tc.deinit();
    try std.testing.expectError(error.TypeMismatch, bad_tc.checkProgram(bad_program));

    const ok_source =
        \\fn main() -> i32 {
        \\    let m = BTreeMap::new();
        \\    m.insert("a", 1);
        \\    return 0;
        \\}
    ;
    var ok_parser = parser_mod.Parser.init(arena.allocator(), ok_source);
    const ok_program = try ok_parser.parseProgram();
    var ok_tc = TypeChecker.init(arena.allocator());
    defer ok_tc.deinit();
    try ok_tc.checkProgram(ok_program);
}
