//! Cooperative CPS/state-machine lowering for goroutine programs
//! (build-wasm only; see goroutine-cps DESIGN.md).
//!
//! This pass runs inside the SLA frontend AFTER syntax lowering,
//! gated by SlaCompileOptions.goroutine_coop, so build-exe / test /
//! check outputs are byte-identical to the standard pipeline.
//! The transformed program is consumed by BOTH codegens exactly
//! like the lowered program the syntax lowerer produces — the
//! state machines are ordinary SLA functions, which is what makes
//! the design target-shared: any future target that selects the
//! cooperative runtime (C via a cooperative archive, JS) reuses
//! this same lowering and the same task.sai surface.
//!
//! Mechanism (Jev ruling cps_state_machine_shared 0.95): every
//! function in the transform set — `main` plus every function
//! named as a `go` entry — is rewritten into a step function over
//! a heap frame struct:
//!
//!   fn __coop_step_F(__coop_frame: *FrameF) -> void {
//!       while true { switch (__coop_frame.state) { ... } }
//!   }
//!
//! All parameters and locals live in the frame (locals whose
//! value is address-resident — arrays/structs/tuples/enums — are
//! accessed through the field, mirroring the chan slot-view
//! convention: for an address-resident type the field access IS
//! the storage address in both codegens' register model). Every
//! blocking extern call (chan send/recv/select, join, sleep,
//! mutex/rwlock/ww waits, once_do, yield) ends a segment: locals
//! are written back to the frame, the continuation state is
//! stored, and the step returns when the runtime answers
//! SA_COOP_BLOCKED. On re-entry the continuation segment first
//! collects the delivered status via sa_coop_take_result.
//! Spawn sites allocate the callee frame in the caller's segment
//! (a post-check let allocation, never released) and pass its
//! pointer as the task argument; the original `main` becomes a
//! wrapper that runs sa_coop_run_main.
//!
//! Cooperative only — no preemption (that is the Go wasm yardstick
//! too). Anything outside the carried shapes fails HERE with a
//! named Coop* diagnostic; nothing degrades silently.

const std = @import("std");
const ast = @import("ast.zig");
const tc_mod = @import("type_checker.zig");
const contract_parser = @import("contract_parser.zig");
const TypeChecker = tc_mod.TypeChecker;

pub const CoopError = error{ CoopUnsupported, OutOfMemory };

pub const SA_COOP_BLOCKED: i64 = 0x4000_0000;

const BLOCKING_CALLS = [_][]const u8{
    "sa_chan_send",
    "sa_chan_recv",
    "sa_chan_select",
    "sa_task_join",
    "sa_task_sleep_ns",
    "sa_task_sleep_ms",
    "sa_sync_mutex_lock",
    "sa_sync_rwlock_rlock",
    "sa_sync_rwlock_lock",
    "sa_sync_waitgroup_wait",
    "sa_sync_once_do",
    "sa_task_yield",
};

fn isBlockingCall(name: []const u8) bool {
    for (BLOCKING_CALLS) |b| {
        if (std.mem.eql(u8, b, name)) return true;
    }
    return false;
}

const RESERVED_NAMES = [_][]const u8{
    "__coop_frame", "__coop_pend", "__coop_has", "__coop_fb", "__coop_fp", "__coop_rc",
};

fn isReservedName(name: []const u8) bool {
    for (RESERVED_NAMES) |r| {
        if (std.mem.eql(u8, r, name)) return true;
    }
    return false;
}

// ---------------------------------------------------------------------
// Scan: one generic walker used by every analysis pass.
// ---------------------------------------------------------------------

const Scan = struct {
    blocking: bool = false,
    blocking_in_closure: bool = false,
    spawn: bool = false,
    supervised: bool = false,
    go_or_await: bool = false,
    defer_found: bool = false,
    spawn_calls: std.array_list.Managed(*ast.Node) = undefined,
    called: std.StringHashMap(void) = undefined,
};

fn scanInit(allocator: std.mem.Allocator) Scan {
    return .{
        .spawn_calls = std.array_list.Managed(*ast.Node).init(allocator),
        .called = std.StringHashMap(void).init(allocator),
    };
}

fn scanStmts(scan: *Scan, stmts: []const *ast.Node, in_closure: bool) void {
    for (stmts) |s| scanNode(scan, s, in_closure);
}

fn scanNode(scan: *Scan, node: *ast.Node, in_closure: bool) void {
    switch (node.*) {
        .call_expr => |c| {
            if (c.callee) |cal| scanNode(scan, cal, in_closure);
            if (c.func_name.len > 0) {
                const name = c.func_name;
                scan.called.put(name, {}) catch {};
                if (isBlockingCall(name)) {
                    scan.blocking = true;
                    if (in_closure) scan.blocking_in_closure = true;
                } else if (std.mem.eql(u8, name, "sa_task_spawn")) {
                    scan.spawn = true;
                    scan.spawn_calls.append(node) catch {};
                } else if (std.mem.eql(u8, name, "sa_task_spawn_supervised")) {
                    scan.supervised = true;
                }
            }
            for (c.args) |a| scanNode(scan, a, in_closure);
        },
        .go_expr => scan.go_or_await = true,
        .await_expr => |a| {
            scan.go_or_await = true;
            scanNode(scan, a.expr, in_closure);
        },
        .defer_stmt => scan.defer_found = true,

        .func_decl => |fd| scanStmts(scan, fd.body, in_closure),
        .program => |p| for (p.decls) |d| scanNode(scan, d, in_closure),
        .impl_decl => |im| for (im.methods) |m| scanNode(scan, m, in_closure),
        .let_stmt => |s| scanNode(scan, s.value, in_closure),
        .const_stmt => |s| scanNode(scan, s.value, in_closure),
        .let_else_stmt => |s| {
            scanNode(scan, s.value, in_closure);
            scanStmts(scan, s.else_block, in_closure);
        },
        .let_destructure_stmt => |s| scanNode(scan, s.value, in_closure),
        .assign_stmt => |s| {
            scanNode(scan, s.target, in_closure);
            scanNode(scan, s.value, in_closure);
        },
        .block_stmt => |s| scanStmts(scan, s.body, in_closure),
        .return_stmt => |s| if (s.value) |v| scanNode(scan, v, in_closure),
        .for_stmt => |s| {
            scanNode(scan, s.start, in_closure);
            if (s.end) |e| scanNode(scan, e, in_closure);
            scanStmts(scan, s.body, in_closure);
        },
        .while_stmt => |s| {
            scanNode(scan, s.cond, in_closure);
            scanStmts(scan, s.body, in_closure);
        },
        .if_expr => |s| {
            scanNode(scan, s.cond, in_closure);
            scanStmts(scan, s.then_block, in_closure);
            if (s.else_block) |eb| scanStmts(scan, eb, in_closure);
        },
        .switch_expr => |s| {
            scanNode(scan, s.val, in_closure);
            for (s.cases) |case| scanStmts(scan, case.body, in_closure);
        },
        .match_expr => |s| {
            scanNode(scan, s.val, in_closure);
            for (s.cases) |case| scanStmts(scan, case.body, in_closure);
        },
        .select_stmt => |s| {
            for (s.cases) |case| {
                scanNode(scan, case.call, in_closure);
                scanStmts(scan, case.body, in_closure);
            }
            if (s.default_body) |db| scanStmts(scan, db, in_closure);
            if (s.timeout_body) |tb| scanStmts(scan, tb, in_closure);
        },
        .unsafe_expr => |s| scanStmts(scan, s.body, in_closure),
        .closure_literal => |s| scanNode(scan, s.body, true),
        .binary_expr => |s| {
            scanNode(scan, s.left, in_closure);
            scanNode(scan, s.right, in_closure);
        },
        .borrow_expr => |s| scanNode(scan, s.expr, in_closure),
        .move_expr => |s| scanNode(scan, s.expr, in_closure),
        .deref_expr => |s| scanNode(scan, s.expr, in_closure),
        .cast_expr => |s| scanNode(scan, s.expr, in_closure),
        .field_expr => |s| scanNode(scan, s.expr, in_closure),
        .index_expr => |s| {
            scanNode(scan, s.target, in_closure);
            scanNode(scan, s.index, in_closure);
        },
        .slice_expr => |s| {
            scanNode(scan, s.target, in_closure);
            scanNode(scan, s.start, in_closure);
            scanNode(scan, s.end, in_closure);
        },
        .tuple_literal => |s| for (s.elements) |e| scanNode(scan, e, in_closure),
        .array_literal => |s| for (s.elements) |e| scanNode(scan, e, in_closure),
        .repeat_array_literal => |s| scanNode(scan, s.value, in_closure),
        .struct_literal => |s| for (s.fields) |f| scanNode(scan, f.value, in_closure),
        .try_expr => |s| scanNode(scan, s.expr, in_closure),
        else => {},
    }
}

// ---------------------------------------------------------------------
// Frame description.
// ---------------------------------------------------------------------

const FieldInfo = struct {
    orig: []const u8,
    field: []const u8,
    ty: *ast.Type,
    /// The type the frame struct declares for this field. For
    /// decl-less user_defined word types (Chan<T> handles and
    /// friends) this is a same-width INTEGER type: codegen maps
    /// decl-less user_defined values to ptr-typed registers, which
    /// truncates 64-bit handles on 32-bit targets when they cross
    /// memory. Integer storage keeps the full word.
    storage_ty: *ast.Type,
    addr_resident: bool,
    is_param: bool,
};

const FrameInfo = struct {
    fn_name: []const u8,
    decl_node: *ast.Node,
    fd: ast.FuncDecl,
    frame_name: []const u8,
    step_name: []const u8,
    frame_ty: *ast.Type, // user_defined(frame_name)
    frame_ptr_ty: *ast.Type, // *frame_ty
    fields: std.array_list.Managed(FieldInfo),
    ret_ty: *ast.Type,
    /// Storage type of the frame's `result` field (see FieldInfo.storage_ty).
    result_storage_ty: *ast.Type = undefined,
    is_main: bool,

    fn fieldOf(self: *const FrameInfo, orig: []const u8) ?*const FieldInfo {
        for (self.fields.items) |*f| {
            if (std.mem.eql(u8, f.orig, orig)) return f;
        }
        return null;
    }
};

pub const CoopTransformer = struct {
    allocator: std.mem.Allocator,
    tc: *TypeChecker,
    err_msg: ?[]const u8 = null,
    counter: u32 = 0,
    frames: std.array_list.Managed(*FrameInfo),
    synth_decls: std.array_list.Managed(*ast.Node),

    pub fn init(allocator: std.mem.Allocator, tc: *TypeChecker) CoopTransformer {
        return .{
            .allocator = allocator,
            .tc = tc,
            .frames = std.array_list.Managed(*FrameInfo).init(allocator),
            .synth_decls = std.array_list.Managed(*ast.Node).init(allocator),
        };
    }

    pub fn synthesizedDecls(self: *CoopTransformer) []const *ast.Node {
        return self.synth_decls.items;
    }

    fn fail(self: *CoopTransformer, comptime fmt: []const u8, args: anytype) CoopError {
        self.err_msg = std.fmt.allocPrint(self.allocator, fmt, args) catch "coop lowering error";
        return error.CoopUnsupported;
    }

    // ---- node / type constructors (mirror syntax_lowering) ----

    fn newNode(self: *CoopTransformer, value: ast.Node) CoopError!*ast.Node {
        const n = self.allocator.create(ast.Node) catch return error.OutOfMemory;
        n.* = value;
        return n;
    }

    fn reg(self: *CoopTransformer, node: *ast.Node, ty: *ast.Type) void {
        self.tc.expr_types.put(node, ty) catch {};
    }

    fn tyPrim(self: *CoopTransformer, p: ast.Primitive) CoopError!*ast.Type {
        const t = self.allocator.create(ast.Type) catch return error.OutOfMemory;
        t.* = .{ .primitive = p };
        return t;
    }

    fn tyPtrTo(self: *CoopTransformer, inner: *ast.Type) CoopError!*ast.Type {
        const t = self.allocator.create(ast.Type) catch return error.OutOfMemory;
        t.* = .{ .pointer = inner };
        return t;
    }

    fn tyBorrowOf(self: *CoopTransformer, inner: *ast.Type) CoopError!*ast.Type {
        const t = self.allocator.create(ast.Type) catch return error.OutOfMemory;
        t.* = .{ .borrow = inner };
        return t;
    }

    fn identNode(self: *CoopTransformer, name: []const u8, ty: *ast.Type) CoopError!*ast.Node {
        const n = try self.newNode(.{ .identifier = name });
        self.reg(n, ty);
        return n;
    }

    fn intNodeAs(self: *CoopTransformer, value: i64, prim: ast.Primitive) CoopError!*ast.Node {
        const n = try self.newNode(.{ .literal = .{ .int_val = value } });
        self.reg(n, try self.tyPrim(prim));
        return n;
    }

    fn letNode(self: *CoopTransformer, name: []const u8, ty: ?*ast.Type, value: *ast.Node) CoopError!*ast.Node {
        return self.newNode(.{ .let_stmt = .{ .name = name, .ty = ty, .value = value } });
    }

    fn assignNode(self: *CoopTransformer, target: *ast.Node, value: *ast.Node) CoopError!*ast.Node {
        return self.newNode(.{ .assign_stmt = .{ .target = target, .value = value } });
    }

    fn exprStmt(self: *CoopTransformer, e: *ast.Node) CoopError!*ast.Node {
        return self.newNode(.{ .expr_stmt = e });
    }

    fn returnNode(self: *CoopTransformer) CoopError!*ast.Node {
        return self.newNode(.{ .return_stmt = .{ .value = null } });
    }

    fn fieldNode(self: *CoopTransformer, base: *ast.Node, name: []const u8, ty: *ast.Type) CoopError!*ast.Node {
        const n = try self.newNode(.{ .field_expr = .{ .expr = base, .field_name = name } });
        self.reg(n, ty);
        return n;
    }

    fn frameIdent(self: *CoopTransformer, finfo: *const FrameInfo) CoopError!*ast.Node {
        return self.identNode("__coop_frame", finfo.frame_ptr_ty);
    }

    fn frameField(self: *CoopTransformer, finfo: *const FrameInfo, name: []const u8, ty: *ast.Type) CoopError!*ast.Node {
        return self.fieldNode(try self.frameIdent(finfo), name, ty);
    }

    // ---- type utilities ----

    fn sameType(_: *CoopTransformer, a: *ast.Type, b: *ast.Type) bool {
        return typeEql(a, b);
    }

    fn storageTypeFor(self: *CoopTransformer, ty: *ast.Type) CoopError!*ast.Type {
        if (ty.* == .user_defined) {
            const name = ty.user_defined.name;
            if (!self.tc.structs.contains(name) and !self.tc.enums.contains(name)) {
                const sz = self.tc.payloadStorageSize(ty) orelse
                    return self.fail("CoopWordFieldSize: no storage size for handle type '{s}'", .{name});
                return switch (sz) {
                    8 => self.tyPrim(.u64),
                    4 => self.tyPrim(.u32),
                    2 => self.tyPrim(.u16),
                    1 => self.tyPrim(.u8),
                    else => self.fail("CoopWordFieldSize: handle type '{s}' has unsupported storage size {d}", .{ name, sz }),
                };
            }
        }
        return ty;
    }

    fn addrResident(self: *CoopTransformer, ty: *ast.Type) bool {
        return switch (ty.*) {
            .array, .tuple => true,
            .user_defined => |u| self.tc.structs.get(u.name) != null or self.tc.enums.get(u.name) != null,
            else => false,
        };
    }

    fn isVoidTy(_: *CoopTransformer, ty: *ast.Type) bool {
        return ty.* == .primitive and ty.primitive == .void_type;
    }

    // ---- coop extern registration (mirrors Lowerer.ensureExtern) ----

    fn ensureExtern(self: *CoopTransformer, func: contract_parser.ExternalFunction) CoopError!void {
        if (self.tc.extern_funcs.contains(func.name)) return;
        self.tc.extern_funcs.put(func.name, func) catch return error.OutOfMemory;
    }

    fn ensureCoopExterns(self: *CoopTransformer) CoopError!void {
        try self.ensureExtern(.{
            .name = "sa_coop_take_result",
            .params = &.{
                .{ .name = "out_status", .ty = "ptr", .is_borrow = true, .is_move = false },
            },
            .ret_ty = "i32",
        });
        try self.ensureExtern(.{
            .name = "sa_coop_finish",
            .params = &.{},
            .ret_ty = "void",
        });
        try self.ensureExtern(.{
            .name = "sa_coop_run_main",
            .params = &.{
                .{ .name = "entry", .ty = "ptr", .is_borrow = false, .is_move = false, .is_raw = true },
                .{ .name = "arg", .ty = "ptr", .is_borrow = false, .is_move = false },
            },
            .ret_ty = "i32",
        });
    }

    fn coopCall(self: *CoopTransformer, name: []const u8, args: []const *ast.Node, ret_ty: *ast.Type) CoopError!*ast.Node {
        // The args slice is stored in the node: copy it into the
        // arena (callers pass stack temporaries like `&.{...}`).
        const owned = self.allocator.dupe(*ast.Node, args) catch return error.OutOfMemory;
        const call = try self.newNode(.{ .call_expr = .{ .func_name = name, .generics = &.{}, .args = owned } });
        self.reg(call, ret_ty);
        return call;
    }

    // ---- transform driver ----

    fn frameInfoOf(self: *CoopTransformer, name: []const u8) ?*FrameInfo {
        for (self.frames.items) |f| {
            if (std.mem.eql(u8, f.fn_name, name)) return f;
        }
        return null;
    }

    pub fn transformProgram(self: *CoopTransformer, prog: *ast.Node) CoopError!void {
        try self.ensureCoopExterns();
        const allocator = self.allocator;

        // Index top-level functions; remember every body owner
        // (functions and impl methods) for the global scans.
        var funcs = std.StringHashMap(*ast.Node).init(allocator);
        var owners = std.array_list.Managed(struct { name: []const u8, body: []const *ast.Node, is_target_candidate: bool }).init(allocator);
        for (prog.program.decls) |d| {
            switch (d.*) {
                .func_decl => |fd| {
                    funcs.put(fd.name, d) catch return error.OutOfMemory;
                    owners.append(.{ .name = fd.name, .body = fd.body, .is_target_candidate = true }) catch return error.OutOfMemory;
                },
                .impl_decl => |im| {
                    for (im.methods) |m| {
                        if (m.* == .func_decl) {
                            owners.append(.{ .name = m.func_decl.name, .body = m.func_decl.body, .is_target_candidate = false }) catch return error.OutOfMemory;
                        }
                    }
                },
                else => {},
            }
        }

        const main_node = funcs.get("main") orelse
            return self.fail("CoopNoMain: cooperative (wasm) builds require a top-level `main` function", .{});

        // Fixpoint target set: main + every identifier-named go
        // entry reachable from targets.
        var targets = std.StringHashMap(void).init(allocator);
        var queue = std.array_list.Managed([]const u8).init(allocator);
        targets.put("main", {}) catch return error.OutOfMemory;
        queue.append("main") catch return error.OutOfMemory;
        var qi: usize = 0;
        while (qi < queue.items.len) {
            const fname = queue.items[qi];
            qi += 1;
            const fnode = funcs.get(fname) orelse continue;
            var scan = scanInit(allocator);
            scanStmts(&scan, fnode.func_decl.body, false);
            for (scan.spawn_calls.items) |call| {
                const entry = try self.spawnEntryName(call, fname);
                if (!targets.contains(entry)) {
                    if (funcs.get(entry) == null)
                        return self.fail("CoopEntryNotFunction: go entry '{s}' in '{s}' is not a top-level function (indirect/fn-value spawn is not carried by the cooperative lowering)", .{ entry, fname });
                    targets.put(entry, {}) catch return error.OutOfMemory;
                    queue.append(entry) catch return error.OutOfMemory;
                }
            }
        }

        // Global scans: loud rejection of shapes outside the set.
        for (owners.items) |owner| {
            var scan = scanInit(allocator);
            scanStmts(&scan, owner.body, false);
            if (scan.supervised)
                return self.fail("CoopSupervisedSpawn: supervised spawn in '{s}' is not carried by the cooperative lowering (per-task trap isolation is a named non-goal of the prototype)", .{owner.name});
            if ((scan.blocking or scan.spawn) and !targets.contains(owner.name))
                return self.fail("CoopBlockingOutsideTarget: '{s}' uses goroutine operations but is neither `main` nor a `go` entry; the cooperative lowering transforms only the spawn closure (direct calls to blocking helpers are not carried — inline the operation or spawn it)", .{owner.name});
            var cit = scan.called.iterator();
            while (cit.next()) |kv| {
                const callee = kv.key_ptr.*;
                if (targets.contains(callee)) {
                    if (std.mem.eql(u8, callee, owner.name))
                        return self.fail("CoopRecursiveCall: goroutine function '{s}' calls itself; recursion is not carried by the cooperative lowering", .{owner.name});
                    return self.fail("CoopDirectCall: '{s}' is called directly by '{s}'; goroutine functions may only be entered through `go` (their step functions are not callable values)", .{ callee, owner.name });
                }
            }
        }

        // Build frame descriptions (validates each target).
        var tit = targets.iterator();
        while (tit.next()) |kv| {
            const name = kv.key_ptr.*;
            const node = funcs.get(name).?;
            _ = try self.buildFrameInfo(node, std.mem.eql(u8, name, "main"));
        }
        _ = main_node;

        // Rewrite each target into its step function; main becomes
        // the run_main wrapper and its step is synthesized.
        for (self.frames.items) |finfo| {
            var sp = Splitter{ .tr = self, .finfo = finfo };
            try sp.rewrite();
        }

        // Append synthesized decls (frame structs + main's step).
        if (self.synth_decls.items.len > 0) {
            var all = std.array_list.Managed(*ast.Node).init(allocator);
            all.appendSlice(prog.program.decls) catch return error.OutOfMemory;
            all.appendSlice(self.synth_decls.items) catch return error.OutOfMemory;
            var prog_copy = prog.program;
            prog_copy.decls = all.items;
            prog.* = .{ .program = prog_copy };
        }
    }

    fn spawnEntryName(self: *CoopTransformer, call: *ast.Node, owner: []const u8) CoopError![]const u8 {
        const c = call.call_expr;
        if (c.args.len == 0 or c.args[0].* != .identifier)
            return self.fail("CoopIndirectSpawn: spawn in '{s}' does not name its entry function directly (fn-value spawn is not carried by the cooperative lowering)", .{owner});
        return c.args[0].identifier;
    }

    // ---- locals collection (scope aware) ----

    const CollectCtx = struct {
        tr: *CoopTransformer,
        finfo: *FrameInfo,
        scopes: std.array_list.Managed(std.StringHashMap(void)),
    };

    fn collectDeclare(self: *CoopTransformer, ctx: *CollectCtx, name: []const u8, ty: *ast.Type, is_param: bool) CoopError!void {
        if (isReservedName(name))
            return self.fail("CoopReservedName: '{s}' in goroutine function '{s}' collides with a name reserved by the cooperative lowering", .{ name, ctx.finfo.fn_name });
        // Same-scope redeclaration: a repeated `let` of one name in
        // one block is sequential shadowing; it shares the field.
        const cur = &ctx.scopes.items[ctx.scopes.items.len - 1];
        if (cur.contains(name)) {
            const existing = ctx.finfo.fieldOf(name).?;
            if (!self.sameType(existing.ty, ty))
                return self.fail("CoopShadowTypeMismatch: local '{s}' in '{s}' is redeclared with a different type; the cooperative frame holds one field per name", .{ name, ctx.finfo.fn_name });
            return;
        }
        // Nested-scope redeclaration would change value semantics
        // across suspension points: loud.
        var si: usize = 0;
        while (si + 1 < ctx.scopes.items.len) : (si += 1) {
            if (ctx.scopes.items[si].contains(name))
                return self.fail("CoopShadowedLocal: local '{s}' in '{s}' is shadowed in a nested block; shadowed locals are not carried by the cooperative lowering v1", .{ name, ctx.finfo.fn_name });
        }
        cur.put(name, {}) catch return error.OutOfMemory;
        if (ctx.finfo.fieldOf(name) != null) return; // param already framed
        var field_name = name;
        if (std.mem.eql(u8, name, "state") or std.mem.eql(u8, name, "result")) {
            field_name = std.fmt.allocPrint(self.allocator, "__coop_f_{s}", .{name}) catch return error.OutOfMemory;
        }
        ctx.finfo.fields.append(.{
            .orig = name,
            .field = field_name,
            .ty = ty,
            .storage_ty = try self.storageTypeFor(ty),
            .addr_resident = self.addrResident(ty),
            .is_param = is_param,
        }) catch return error.OutOfMemory;
    }

    fn collectStmts(self: *CoopTransformer, ctx: *CollectCtx, stmts: []const *ast.Node) CoopError!void {
        for (stmts) |stmt| {
            switch (stmt.*) {
                .let_stmt => |ls| {
                    const ty = ls.ty orelse self.tc.expr_types.get(ls.value) orelse
                        return self.fail("CoopUnknownLocalType: cannot determine the type of local '{s}' in '{s}'", .{ ls.name, ctx.finfo.fn_name });
                    try self.collectDeclare(ctx, ls.name, ty, false);
                },
                .const_stmt => |cs| {
                    const ty = cs.ty orelse self.tc.expr_types.get(cs.value) orelse
                        return self.fail("CoopUnknownLocalType: cannot determine the type of local '{s}' in '{s}'", .{ cs.name, ctx.finfo.fn_name });
                    try self.collectDeclare(ctx, cs.name, ty, false);
                },
                .var_stmt => |vs| {
                    try self.collectDeclare(ctx, vs.name, vs.ty, false);
                },
                .let_destructure_stmt => |ld| {
                    const vt = self.tc.expr_types.get(ld.value) orelse
                        return self.fail("CoopDestructureType: cannot determine the destructured value type in '{s}'", .{ctx.finfo.fn_name});
                    if (vt.* != .tuple or vt.tuple.elems.len != ld.names.len)
                        return self.fail("CoopDestructureType: only tuple destructuring is carried by the cooperative lowering ('{s}')", .{ctx.finfo.fn_name});
                    for (ld.names, vt.tuple.elems) |n, et| {
                        try self.collectDeclare(ctx, n, et, false);
                    }
                },
                .for_stmt => |fs| {
                    try ctx.scopes.append(std.StringHashMap(void).init(self.allocator));
                    const vt = self.tc.expr_types.get(fs.start) orelse try self.tyPrim(.i64);
                    try self.collectDeclare(ctx, fs.var_name, vt, false);
                    try self.collectStmts(ctx, fs.body);
                    _ = ctx.scopes.pop();
                },
                .while_stmt => |ws| {
                    if (ws.let_pattern != null)
                        return self.fail("CoopWhileLet: while-let in goroutine function '{s}' is not carried by the cooperative lowering v1", .{ctx.finfo.fn_name});
                    try ctx.scopes.append(std.StringHashMap(void).init(self.allocator));
                    try self.collectStmts(ctx, ws.body);
                    _ = ctx.scopes.pop();
                },
                .expr_stmt => |e| {
                    if (e.* == .if_expr) {
                        const ie = e.if_expr;
                        try ctx.scopes.append(std.StringHashMap(void).init(self.allocator));
                        try self.collectStmts(ctx, ie.then_block);
                        _ = ctx.scopes.pop();
                        if (ie.else_block) |eb| {
                            try ctx.scopes.append(std.StringHashMap(void).init(self.allocator));
                            try self.collectStmts(ctx, eb);
                            _ = ctx.scopes.pop();
                        }
                    } else if (e.* == .switch_expr) {
                        for (e.switch_expr.cases) |case| {
                            try ctx.scopes.append(std.StringHashMap(void).init(self.allocator));
                            try self.collectStmts(ctx, case.body);
                            _ = ctx.scopes.pop();
                        }
                    }
                },
                .block_stmt => |bs| {
                    try ctx.scopes.append(std.StringHashMap(void).init(self.allocator));
                    try self.collectStmts(ctx, bs.body);
                    _ = ctx.scopes.pop();
                },
                else => {},
            }
        }
    }

    // ---- cross-suspension liveness (frame membership) ----

    fn dupNameSet(self: *CoopTransformer, src_set: *const std.StringHashMap(void)) std.StringHashMap(void) {
        var out = std.StringHashMap(void).init(self.allocator);
        var it = src_set.keyIterator();
        while (it.next()) |k| out.put(k.*, {}) catch {};
        return out;
    }

    fn unionInto(dst: *std.StringHashMap(void), src_set: *const std.StringHashMap(void)) void {
        var it = src_set.keyIterator();
        while (it.next()) |k| dst.put(k.*, {}) catch {};
    }

    fn nameSetEq(a: *const std.StringHashMap(void), b: *const std.StringHashMap(void)) bool {
        if (a.count() != b.count()) return false;
        var it = a.keyIterator();
        while (it.next()) |k| if (!b.contains(k.*)) return false;
        return true;
    }

    /// Collect identifier reads (uses) and binding sites (defs)
    /// of one statement subtree. Mirrors scanTouch's recursion
    /// over the lowered AST shapes.
    fn liveWalk(self: *CoopTransformer, node: *ast.Node, uses: *std.StringHashMap(void), defs: *std.StringHashMap(void)) void {
        switch (node.*) {
            .identifier => |name| uses.put(name, {}) catch {},
            .call_expr => |c| {
                if (c.callee) |cal| self.liveWalk(cal, uses, defs);
                for (c.args) |a| self.liveWalk(a, uses, defs);
            },
            .let_stmt => |s| {
                defs.put(s.name, {}) catch {};
                self.liveWalk(s.value, uses, defs);
            },
            .const_stmt => |s| {
                defs.put(s.name, {}) catch {};
                self.liveWalk(s.value, uses, defs);
            },
            .let_destructure_stmt => |s| {
                for (s.names) |n| defs.put(n, {}) catch {};
                self.liveWalk(s.value, uses, defs);
            },
            .assign_stmt => |s| {
                if (s.target.* == .identifier) {
                    defs.put(s.target.identifier, {}) catch {};
                } else {
                    self.liveWalk(s.target, uses, defs);
                }
                self.liveWalk(s.value, uses, defs);
            },
            .borrow_expr => |s| self.liveWalk(s.expr, uses, defs),
            .move_expr => |s| self.liveWalk(s.expr, uses, defs),
            .expr_stmt => |s| self.liveWalk(s, uses, defs),
            .block_stmt => |s| for (s.body) |b| self.liveWalk(b, uses, defs),
            .return_stmt => |s| if (s.value) |v| self.liveWalk(v, uses, defs),
            .binary_expr => |s| {
                self.liveWalk(s.left, uses, defs);
                self.liveWalk(s.right, uses, defs);
            },
            .deref_expr => |s| self.liveWalk(s.expr, uses, defs),
            .cast_expr => |s| self.liveWalk(s.expr, uses, defs),
            .field_expr => |s| self.liveWalk(s.expr, uses, defs),
            .index_expr => |s| {
                self.liveWalk(s.target, uses, defs);
                self.liveWalk(s.index, uses, defs);
            },
            .slice_expr => |s| {
                self.liveWalk(s.target, uses, defs);
                self.liveWalk(s.start, uses, defs);
                self.liveWalk(s.end, uses, defs);
            },
            .tuple_literal => |s| for (s.elements) |e| self.liveWalk(e, uses, defs),
            .array_literal => |s| for (s.elements) |e| self.liveWalk(e, uses, defs),
            .repeat_array_literal => |s| self.liveWalk(s.value, uses, defs),
            .struct_literal => |s| for (s.fields) |f| self.liveWalk(f.value, uses, defs),
            .try_expr => |s| self.liveWalk(s.expr, uses, defs),
            .await_expr => |s| self.liveWalk(s.expr, uses, defs),
            else => {},
        }
    }

    /// Backward liveness over a statement list. Whenever a
    /// statement contains a blocking call, the names live at
    /// that point (live-after plus the statement's own uses,
    /// minus its defs) are recorded into `worthy`: those are
    /// the names whose values must cross the suspension in the
    /// frame. Returns the live-before set.
    fn liveList(self: *CoopTransformer, stmts: []const *ast.Node, live_after: *const std.StringHashMap(void), worthy: *std.StringHashMap(void)) std.StringHashMap(void) {
        var live = self.dupNameSet(live_after);
        var i = stmts.len;
        while (i > 0) {
            i -= 1;
            live = self.liveStmt(stmts[i], &live, worthy);
        }
        return live;
    }

    fn liveStmt(self: *CoopTransformer, stmt: *ast.Node, live_after: *const std.StringHashMap(void), worthy: *std.StringHashMap(void)) std.StringHashMap(void) {
        switch (stmt.*) {
            .expr_stmt => |inner| return self.liveStmt(inner, live_after, worthy),
            .if_expr => |s| {
                var out = std.StringHashMap(void).init(self.allocator);
                var defs = std.StringHashMap(void).init(self.allocator);
                self.liveWalk(s.cond, &out, &defs);
                const then_in = self.liveList(s.then_block, live_after, worthy);
                unionInto(&out, &then_in);
                if (s.else_block) |eb| {
                    const else_in = self.liveList(eb, live_after, worthy);
                    unionInto(&out, &else_in);
                } else {
                    unionInto(&out, live_after);
                }
                return out;
            },
            .while_stmt => |s| {
                var cond_uses = std.StringHashMap(void).init(self.allocator);
                var cond_defs = std.StringHashMap(void).init(self.allocator);
                self.liveWalk(s.cond, &cond_uses, &cond_defs);
                // Fixed point: the body's live-out includes the
                // loop head's live set (back edge).
                var w = self.dupNameSet(live_after);
                unionInto(&w, &cond_uses);
                while (true) {
                    var body_out = self.dupNameSet(&w);
                    unionInto(&body_out, live_after);
                    const body_in = self.liveList(s.body, &body_out, worthy);
                    var next = self.dupNameSet(live_after);
                    unionInto(&next, &cond_uses);
                    unionInto(&next, &body_in);
                    if (nameSetEq(&next, &w)) {
                        w = next;
                        break;
                    }
                    w = next;
                }
                return w;
            },
            .block_stmt => |s| return self.liveList(s.body, live_after, worthy),
            .switch_expr => |s| {
                var out = std.StringHashMap(void).init(self.allocator);
                var defs = std.StringHashMap(void).init(self.allocator);
                self.liveWalk(s.val, &out, &defs);
                for (s.cases) |case| {
                    const case_in = self.liveList(case.body, live_after, worthy);
                    unionInto(&out, &case_in);
                }
                return out;
            },
            else => {
                var uses = std.StringHashMap(void).init(self.allocator);
                var defs = std.StringHashMap(void).init(self.allocator);
                self.liveWalk(stmt, &uses, &defs);
                var scan = scanInit(self.allocator);
                scanNode(&scan, stmt, false);
                if (scan.blocking) {
                    var it = live_after.keyIterator();
                    while (it.next()) |k| worthy.put(k.*, {}) catch {};
                    var uit = uses.keyIterator();
                    while (uit.next()) |k| {
                        if (!defs.contains(k.*)) worthy.put(k.*, {}) catch {};
                    }
                    // A blocking let's own result is produced
                    // across the suspension (the continuation
                    // segment receives it from the pending-status
                    // delivery), so its name always frames.
                    switch (stmt.*) {
                        .let_stmt => |s| worthy.put(s.name, {}) catch {},
                        .const_stmt => |s| worthy.put(s.name, {}) catch {},
                        .let_destructure_stmt => |s| for (s.names) |n| worthy.put(n, {}) catch {},
                        else => {},
                    }
                }
                var out = self.dupNameSet(live_after);
                var dit = defs.keyIterator();
                while (dit.next()) |k| _ = out.remove(k.*);
                unionInto(&out, &uses);
                return out;
            },
        }
    }

    fn buildFrameInfo(self: *CoopTransformer, node: *ast.Node, is_main: bool) CoopError!*FrameInfo {
        const fd = node.func_decl;
        if (fd.generics.len > 0)
            return self.fail("CoopGenericTarget: generic goroutine function '{s}' is not carried by the cooperative lowering v1", .{fd.name});
        if (fd.is_extern or fd.is_decl_only)
            return self.fail("CoopEntryNotFunction: go entry '{s}' has no body to transform", .{fd.name});
        if (is_main and fd.params.len > 0)
            return self.fail("CoopMainParams: cooperative `main` must not take parameters", .{});
        if (!is_main and fd.params.len > 1)
            return self.fail("CoopMultiParam: goroutine function '{s}' takes {d} parameters; `go` entries carry at most one argument in the cooperative lowering v1", .{ fd.name, fd.params.len });
        var scan = scanInit(self.allocator);
        scanStmts(&scan, fd.body, false);
        if (scan.defer_found)
            return self.fail("CoopDefer: `defer` in goroutine function '{s}' is not carried by the cooperative lowering v1", .{fd.name});
        if (scan.go_or_await)
            return self.fail("CoopAsyncShape: `go`/`await` expression survived syntax lowering inside '{s}'; the cooperative lowering consumes the lowered statement forms only", .{fd.name});
        if (scan.blocking_in_closure)
            return self.fail("CoopBlockingInClosure: a closure inside '{s}' performs a blocking goroutine operation; closures cannot suspend in the cooperative lowering v1", .{fd.name});
        if (is_main and !self.isVoidTy(fd.ret_ty)) {
            const ok = fd.ret_ty.* == .primitive and switch (fd.ret_ty.primitive) {
                .i8, .i16, .i32, .i64, .isize, .u8, .u16, .u32, .u64, .usize, .integer => true,
                else => false,
            };
            if (!ok)
                return self.fail("CoopMainReturn: cooperative `main` must return void or an integer type", .{});
        }

        const finfo = self.allocator.create(FrameInfo) catch return error.OutOfMemory;
        finfo.* = .{
            .fn_name = fd.name,
            .decl_node = node,
            .fd = fd,
            .frame_name = std.fmt.allocPrint(self.allocator, "__CoopFrame_{s}", .{fd.name}) catch return error.OutOfMemory,
            .step_name = std.fmt.allocPrint(self.allocator, "__coop_step_{s}", .{fd.name}) catch return error.OutOfMemory,
            .frame_ty = undefined,
            .frame_ptr_ty = undefined,
            .fields = std.array_list.Managed(FieldInfo).init(self.allocator),
            .ret_ty = fd.ret_ty,
            .is_main = is_main,
        };
        const frame_ty = self.allocator.create(ast.Type) catch return error.OutOfMemory;
        frame_ty.* = .{ .user_defined = .{ .name = finfo.frame_name, .generics = &.{} } };
        finfo.frame_ty = frame_ty;
        finfo.frame_ptr_ty = try self.tyPtrTo(frame_ty);

        var ctx = CollectCtx{
            .tr = self,
            .finfo = finfo,
            .scopes = std.array_list.Managed(std.StringHashMap(void)).init(self.allocator),
        };
        ctx.scopes.append(std.StringHashMap(void).init(self.allocator)) catch return error.OutOfMemory;
        for (fd.params) |p| {
            try self.collectDeclare(&ctx, p.name, p.ty, true);
        }
        try self.collectStmts(&ctx, fd.body);

        // Frame only what can flow across a suspension:
        // parameters (delivered through the frame at spawn) and
        // locals live at at least one blocking call site.
        // Branch-local bindings — select arm bindings above
        // all — are defined and used inside a single segment;
        // framing them would add a prologue binding and
        // cross-branch write-backs for names the codegens keep
        // branch-local in the original function, which breaks
        // their name-keyed register resolution (multi-let
        // bindings) and reads registers retired inside sibling
        // branches.
        {
            var worthy = std.StringHashMap(void).init(self.allocator);
            var live_end = std.StringHashMap(void).init(self.allocator);
            _ = self.liveList(fd.body, &live_end, &worthy);
            var kept = std.array_list.Managed(FieldInfo).init(self.allocator);
            for (finfo.fields.items) |f| {
                if (f.is_param or worthy.contains(f.orig))
                    kept.append(f) catch return error.OutOfMemory;
            }
            finfo.fields = kept;
        }

        // Frame struct: state first, then params+locals, then result.
        var sfields = std.array_list.Managed(ast.Field).init(self.allocator);
        sfields.append(.{ .name = "state", .ty = try self.tyPrim(.i64) }) catch return error.OutOfMemory;
        for (finfo.fields.items) |f| {
            sfields.append(.{ .name = f.field, .ty = f.storage_ty }) catch return error.OutOfMemory;
        }
        finfo.result_storage_ty = try self.storageTypeFor(fd.ret_ty);
        if (!self.isVoidTy(fd.ret_ty)) {
            sfields.append(.{ .name = "result", .ty = finfo.result_storage_ty }) catch return error.OutOfMemory;
        }
        const sdecl = self.allocator.create(ast.StructDecl) catch return error.OutOfMemory;
        sdecl.* = .{ .name = finfo.frame_name, .generics = &.{}, .fields = sfields.items };
        self.tc.structs.put(finfo.frame_name, sdecl) catch return error.OutOfMemory;
        self.synth_decls.append(try self.newNode(.{ .struct_decl = sdecl.* })) catch return error.OutOfMemory;
        self.frames.append(finfo) catch return error.OutOfMemory;
        return finfo;
    }
};

// ---------------------------------------------------------------------
// Splitter: one target function -> segments -> step function.
// ---------------------------------------------------------------------

const Splitter = struct {
    tr: *CoopTransformer,
    finfo: *FrameInfo,
    segments: std.AutoHashMap(u64, *Segment) = undefined,
    next_id: u64 = 0,
    cur: ?*Segment = null,
    terminated: bool = false,
    break_id: ?u64 = null,
    cont_id: ?u64 = null,
    last_spawn_call: ?*ast.Node = null,

    const DONE_ID: u64 = 1_000_000;
    const END_ID: u64 = 1_000_001;

    const Segment = struct {
        id: u64,
        stmts: std.array_list.Managed(*ast.Node),
    };

    fn allocId(self: *Splitter) u64 {
        const id = self.next_id;
        self.next_id += 1;
        return id;
    }

    fn append(self: *Splitter, node: *ast.Node) CoopError!void {
        self.cur.?.stmts.append(node) catch return error.OutOfMemory;
    }

    fn openSegment(self: *Splitter, id: u64) CoopError!void {
        const seg = self.tr.allocator.create(Segment) catch return error.OutOfMemory;
        seg.* = .{ .id = id, .stmts = std.array_list.Managed(*ast.Node).init(self.tr.allocator) };
        self.segments.put(id, seg) catch return error.OutOfMemory;
        self.cur = seg;
        // Segment bodies are collected bare; rewrite() wraps
        // each in its own segment function with a per-function
        // prologue (one let per framed name in that function).
    }

    /// Per-segment record of which framed names the segment may
    /// have changed: assigned (target of an assignment or a
    /// surviving let), borrowed/moved (address taken — a callee
    /// may mutate through it), or forgotten (register retired —
    /// must never be read again).
    const Touch = struct {
        assigned: std.StringHashMap(void),
        borrowed: std.StringHashMap(void),
        forgotten: std.StringHashMap(void),
        consumed: std.StringHashMap(void),
    };

    fn touchInit(self: *Splitter) Touch {
        return .{
            .assigned = std.StringHashMap(void).init(self.tr.allocator),
            .borrowed = std.StringHashMap(void).init(self.tr.allocator),
            .forgotten = std.StringHashMap(void).init(self.tr.allocator),
            .consumed = std.StringHashMap(void).init(self.tr.allocator),
        };
    }

    /// A bare identifier in a value position that transfers
    /// ownership: a move expression, the whole right-hand side of
    /// a register-target assignment/let (a reg<-reg assign moves
    /// non-Copy values into their new home), or an argument
    /// passed to a by-move parameter. Reading such a name
    /// afterwards is UseAfterMove. A field/index target is a
    /// STORE — its source is only read — and Copy-typed values
    /// are never consumed; neither is marked here.
    fn noteConsumedUse(self: *Splitter, touch: *Touch, node: *ast.Node) void {
        if (node.* == .identifier and self.useIsConsuming(node))
            touch.consumed.put(node.identifier, {}) catch {};
    }

    /// Whether using this identifier node in a value position
    /// consumes its register. The codegens decide move-vs-copy
    /// from the VALUE's semantic type, which is not always the
    /// framed field's recorded type: syntax-lowering staging
    /// temps (e.g. `__ch_v_N`) can be recorded as raw u64 words
    /// while a use site (e.g. `a = __ch_v_7` into a Chan-typed
    /// target) moves them as the non-Copy handle type. Consult
    /// the checker's recorded type for the use node as well as
    /// the field's type.
    fn useIsConsuming(self: *Splitter, node: *ast.Node) bool {
        if (node.* != .identifier) return false;
        if (self.framedNonCopy(node.identifier)) return true;
        if (self.tr.tc.expr_types.get(node)) |ty| return self.isNonCopyTy(ty);
        return false;
    }

    fn paramIsMove(self: *Splitter, func_name: []const u8, arg_index: usize) bool {
        if (self.tr.tc.extern_funcs.get(func_name)) |ef| {
            if (arg_index < ef.params.len) return ef.params[arg_index].is_move;
            return false;
        }
        if (self.tr.tc.funcs.get(func_name)) |fd| {
            if (arg_index < fd.params.len) return fd.params[arg_index].is_move;
            return false;
        }
        return false;
    }

    fn scanTouch(self: *Splitter, touch: *Touch, node: *ast.Node) void {
        switch (node.*) {
            .call_expr => |c| {
                if (std.mem.eql(u8, c.func_name, "forget") and c.args.len == 1 and c.args[0].* == .identifier) {
                    touch.forgotten.put(c.args[0].identifier, {}) catch {};
                }
                if (c.callee) |cal| self.scanTouch(touch, cal);
                for (c.args, 0..) |a, ai| {
                    if (a.* == .identifier and self.paramIsMove(c.func_name, ai) and self.useIsConsuming(a))
                        touch.consumed.put(a.identifier, {}) catch {};
                    self.scanTouch(touch, a);
                }
            },
            .let_stmt => |s| {
                touch.assigned.put(s.name, {}) catch {};
                self.noteConsumedUse(touch, s.value);
                self.scanTouch(touch, s.value);
            },
            .const_stmt => |s| {
                touch.assigned.put(s.name, {}) catch {};
                self.noteConsumedUse(touch, s.value);
                self.scanTouch(touch, s.value);
            },
            .let_destructure_stmt => |s| {
                for (s.names) |n| touch.assigned.put(n, {}) catch {};
                self.scanTouch(touch, s.value);
            },
            .assign_stmt => |s| {
                if (s.target.* == .identifier) {
                    touch.assigned.put(s.target.identifier, {}) catch {};
                    self.noteConsumedUse(touch, s.value);
                    // An assignment into a non-Copy target moves
                    // the source even when the source's recorded
                    // type looks like a plain word (staging
                    // temps carrying handle values).
                    if (self.framedNonCopy(s.target.identifier) and s.value.* == .identifier)
                        touch.consumed.put(s.value.identifier, {}) catch {};
                }
                self.scanTouch(touch, s.target);
                self.scanTouch(touch, s.value);
            },
            .borrow_expr => |s| {
                if (s.expr.* == .identifier)
                    touch.borrowed.put(s.expr.identifier, {}) catch {};
                self.scanTouch(touch, s.expr);
            },
            .move_expr => |s| {
                if (s.expr.* == .identifier and self.useIsConsuming(s.expr))
                    touch.consumed.put(s.expr.identifier, {}) catch {};
                self.scanTouch(touch, s.expr);
            },
            .expr_stmt => |s| self.scanTouch(touch, s),
            .func_decl => |fd| for (fd.body) |b| self.scanTouch(touch, b),
            .let_else_stmt => |s| {
                self.scanTouch(touch, s.value);
                for (s.else_block) |b| self.scanTouch(touch, b);
            },
            .block_stmt => |s| for (s.body) |b| self.scanTouch(touch, b),
            .return_stmt => |s| if (s.value) |v| self.scanTouch(touch, v),
            .for_stmt => |s| {
                self.scanTouch(touch, s.start);
                if (s.end) |e| self.scanTouch(touch, e);
                for (s.body) |b| self.scanTouch(touch, b);
            },
            .while_stmt => |s| {
                self.scanTouch(touch, s.cond);
                for (s.body) |b| self.scanTouch(touch, b);
            },
            .if_expr => |s| {
                self.scanTouch(touch, s.cond);
                for (s.then_block) |b| self.scanTouch(touch, b);
                if (s.else_block) |eb| for (eb) |b| self.scanTouch(touch, b);
            },
            .switch_expr => |s| {
                self.scanTouch(touch, s.val);
                for (s.cases) |case| for (case.body) |b| self.scanTouch(touch, b);
            },
            .match_expr => |s| {
                self.scanTouch(touch, s.val);
                for (s.cases) |case| for (case.body) |b| self.scanTouch(touch, b);
            },
            .select_stmt => |s| {
                for (s.cases) |case| {
                    self.scanTouch(touch, case.call);
                    for (case.body) |b| self.scanTouch(touch, b);
                }
                if (s.default_body) |db| for (db) |b| self.scanTouch(touch, b);
                if (s.timeout_body) |tb| for (tb) |b| self.scanTouch(touch, b);
            },
            .unsafe_expr => |s| for (s.body) |b| self.scanTouch(touch, b),
            .closure_literal => |s| self.scanTouch(touch, s.body),
            .binary_expr => |s| {
                self.scanTouch(touch, s.left);
                self.scanTouch(touch, s.right);
            },
            .deref_expr => |s| self.scanTouch(touch, s.expr),
            .cast_expr => |s| self.scanTouch(touch, s.expr),
            .field_expr => |s| self.scanTouch(touch, s.expr),
            .index_expr => |s| {
                self.scanTouch(touch, s.target);
                self.scanTouch(touch, s.index);
            },
            .slice_expr => |s| {
                self.scanTouch(touch, s.target);
                self.scanTouch(touch, s.start);
                self.scanTouch(touch, s.end);
            },
            .tuple_literal => |s| for (s.elements) |e| self.scanTouch(touch, e),
            .array_literal => |s| for (s.elements) |e| self.scanTouch(touch, e),
            .repeat_array_literal => |s| self.scanTouch(touch, s.value),
            .struct_literal => |s| for (s.fields) |f| self.scanTouch(touch, f.value),
            .try_expr => |s| self.scanTouch(touch, s.expr),
            .await_expr => |s| self.scanTouch(touch, s.expr),
            else => {},
        }
    }

    fn writeBacks(self: *Splitter) CoopError!void {
        // Write back only the word fields this segment may have
        // changed. Fields the segment never assigned or borrowed
        // still hold the prologue-loaded value in the frame, so
        // writing them back is a no-op — except that reading
        // their registers is NOT always legal: the SAB codegen
        // retires registers whose last use sits inside a nested
        // branch (borrow views, branch-local bindings), and a
        // later unconditional read is rejected by the verifier
        // (UnknownRegister). Borrow-typed fields and forgotten
        // names are never written back: the lowering's borrow
        // temps are segment-local by construction.
        var touch = self.touchInit();
        if (self.cur) |seg| {
            for (seg.stmts.items) |s| self.scanTouch(&touch, s);
        }
        for (self.finfo.fields.items) |f| {
            if (f.addr_resident) continue;
            if (f.ty.* == .borrow) continue;
            if (touch.forgotten.contains(f.orig)) continue;
            if (touch.consumed.contains(f.orig)) continue;
            if (!touch.assigned.contains(f.orig) and !touch.borrowed.contains(f.orig)) continue;
            const lhs = try self.tr.frameField(self.finfo, f.field, f.storage_ty);
            const rhs = try self.tr.identNode(f.orig, f.ty);
            try self.append(try self.tr.assignNode(lhs, rhs));
        }
    }

    fn returnConst(self: *Splitter, v: i32) CoopError!*ast.Node {
        const val = try self.tr.intNodeAs(v, .i32);
        return self.tr.newNode(.{ .return_stmt = .{ .value = val } });
    }

    fn stateAssign(self: *Splitter, id: u64) CoopError!*ast.Node {
        const lhs = try self.tr.frameField(self.finfo, "state", try self.tr.tyPrim(.i64));
        const rhs = try self.tr.intNodeAs(@intCast(id), .i64);
        return self.tr.assignNode(lhs, rhs);
    }

    fn ifStmtNode(self: *Splitter, cond: *ast.Node, then_stmts: []const *ast.Node, else_stmts: ?[]const *ast.Node) CoopError!*ast.Node {
        // Branch slices are stored in the node: copy into the arena.
        const then_owned = self.tr.allocator.dupe(*ast.Node, then_stmts) catch return error.OutOfMemory;
        const else_owned: ?[]const *ast.Node = if (else_stmts) |es| (self.tr.allocator.dupe(*ast.Node, es) catch return error.OutOfMemory) else null;
        const n = try self.tr.newNode(.{ .if_expr = .{ .cond = cond, .then_block = then_owned, .else_block = else_owned } });
        self.tr.reg(n, try self.tr.tyPrim(.void_type));
        return self.tr.exprStmt(n);
    }

    fn closeToState(self: *Splitter, target: u64) CoopError!void {
        try self.writeBacks();
        try self.append(try self.stateAssign(target));
        try self.append(try self.returnConst(0));
        self.cur = null;
    }

    fn closeSuspend(self: *Splitter, rc_name: ?[]const u8, next_id: u64) CoopError!void {
        try self.writeBacks();
        try self.append(try self.stateAssign(next_id));
        if (rc_name) |rc| {
            const rc_ident = try self.tr.identNode(rc, try self.tr.tyPrim(.i32));
            const blocked = try self.tr.intNodeAs(SA_COOP_BLOCKED, .i32);
            const cond = try self.tr.newNode(.{ .binary_expr = .{ .op = .eq, .left = rc_ident, .right = blocked } });
            self.tr.reg(cond, try self.tr.tyPrim(.boolean));
            const ret = try self.returnConst(1);
            try self.append(try self.ifStmtNode(cond, &.{ret}, null));
        }
        try self.append(try self.returnConst(0));
        self.cur = null;
    }

    fn closeCondTransfer(self: *Splitter, cond: *ast.Node, then_id: u64, else_id: u64) CoopError!void {
        try self.writeBacks();
        const t = try self.stateAssign(then_id);
        const e = try self.stateAssign(else_id);
        try self.append(try self.ifStmtNode(cond, &.{t}, &.{e}));
        try self.append(try self.returnConst(0));
        self.cur = null;
    }

    fn closeReturn(self: *Splitter, value: ?*ast.Node) CoopError!void {
        if (value) |v| {
            if (!self.tr.isVoidTy(self.finfo.ret_ty)) {
                const lhs = try self.tr.frameField(self.finfo, "result", self.finfo.result_storage_ty);
                try self.append(try self.tr.assignNode(lhs, v));
            }
        }
        const finish = try self.tr.coopCall("sa_coop_finish", &.{}, try self.tr.tyPrim(.void_type));
        try self.append(try self.tr.exprStmt(finish));
        try self.append(try self.stateAssign(DONE_ID));
        try self.append(try self.returnConst(1));
        self.cur = null;
        self.terminated = true;
    }

    fn takePrologue(self: *Splitter, rc_name: ?[]const u8) CoopError!void {
        // The temp names are suffixed per site: a name let-bound
        // more than once in a function stops being a declared
        // symbol (multi-let binding), and the extern borrow
        // operand `&__coop_pend_N` resolves by name.
        self.tr.counter += 1;
        const pend_name = std.fmt.allocPrint(self.tr.allocator, "__coop_pend_{d}", .{self.tr.counter}) catch return error.OutOfMemory;
        const has_name = std.fmt.allocPrint(self.tr.allocator, "__coop_has_{d}", .{self.tr.counter}) catch return error.OutOfMemory;
        const i32_ty = try self.tr.tyPrim(.i32);
        const zero = try self.tr.intNodeAs(0, .i32);
        try self.append(try self.tr.letNode(pend_name, i32_ty, zero));
        const pend_ident = try self.tr.identNode(pend_name, i32_ty);
        const borrow = try self.tr.newNode(.{ .borrow_expr = .{ .expr = pend_ident } });
        self.tr.reg(borrow, try self.tr.tyBorrowOf(i32_ty));
        const call = try self.tr.coopCall("sa_coop_take_result", &.{borrow}, i32_ty);
        try self.append(try self.tr.letNode(has_name, i32_ty, call));
        if (rc_name) |rc| {
            const has_ident = try self.tr.identNode(has_name, i32_ty);
            const one = try self.tr.intNodeAs(1, .i32);
            const cond = try self.tr.newNode(.{ .binary_expr = .{ .op = .eq, .left = has_ident, .right = one } });
            self.tr.reg(cond, try self.tr.tyPrim(.boolean));
            const rc_ident = try self.tr.identNode(rc, i32_ty);
            const pend2 = try self.tr.identNode(pend_name, i32_ty);
            const assign = try self.tr.assignNode(rc_ident, pend2);
            try self.append(try self.ifStmtNode(cond, &.{assign}, null));
        }
    }

    // ---- scanning helpers ----

    fn scanOf(self: *Splitter, node: *ast.Node) Scan {
        var scan = scanInit(self.tr.allocator);
        scanNode(&scan, node, false);
        return scan;
    }

    fn isCallTo(node: *ast.Node, name: []const u8) bool {
        if (node.* != .call_expr) return false;
        return std.mem.eql(u8, node.call_expr.func_name, name);
    }

    fn isBlockingCallNode(_: *Splitter, node: *ast.Node) bool {
        if (node.* != .call_expr) return false;
        return isBlockingCall(node.call_expr.func_name);
    }

    // ---- statement emission ----

    fn emitSeq(self: *Splitter, stmts: []const *ast.Node, exit_id: u64) CoopError!void {
        const saved = self.terminated;
        self.terminated = false;
        for (stmts) |stmt| {
            if (self.terminated) break;
            try self.emitStmt(stmt);
        }
        if (!self.terminated) try self.closeToState(exit_id);
        self.terminated = saved;
    }

    fn emitStmt(self: *Splitter, stmt: *ast.Node) CoopError!void {
        switch (stmt.*) {
            .let_stmt => |ls| {
                if (self.isBlockingCallNode(ls.value)) {
                    try self.emitBlockingAssign(ls.name, ls.value);
                } else if (isCallTo(ls.value, "sa_task_spawn")) {
                    try self.emitSpawnSite(ls.value);
                    if (self.finfo.fieldOf(ls.name) != null) {
                        try self.append(try self.tr.assignNode(
                            try self.tr.identNode(ls.name, try self.tr.tyPrim(.i32)),
                            self.last_spawn_call.?,
                        ));
                    } else {
                        try self.append(try self.tr.letNode(ls.name, try self.tr.tyPrim(.i32), self.last_spawn_call.?));
                    }
                } else {
                    const s = self.scanOf(ls.value);
                    if (s.blocking or s.spawn or s.supervised)
                        return self.tr.fail("CoopBlockingNested: a goroutine operation appears in a nested expression position in '{s}' (let '{s}'); the cooperative lowering carries blocking calls at statement level only", .{ self.finfo.fn_name, ls.name });
                    try self.append(try self.emitPlain(stmt));
                }
            },
            .const_stmt => |cs| {
                const s = self.scanOf(cs.value);
                if (s.blocking or s.spawn or s.supervised)
                    return self.tr.fail("CoopBlockingNested: a goroutine operation appears in the initializer of const '{s}' in '{s}'", .{ cs.name, self.finfo.fn_name });
                try self.append(try self.emitPlain(stmt));
            },
            .var_stmt => |vs| {
                // Framed vars live in the frame (zero-initialised);
                // the declaration itself emits nothing.
                if (self.finfo.fieldOf(vs.name) == null) try self.append(stmt);
            },
            .let_destructure_stmt => |ld| {
                const s = self.scanOf(ld.value);
                if (s.blocking or s.spawn or s.supervised)
                    return self.tr.fail("CoopBlockingNested: a goroutine operation appears in a destructuring value in '{s}'", .{self.finfo.fn_name});
                try self.append(try self.emitPlain(stmt));
            },
            .expr_stmt => |e| {
                if (self.isBlockingCallNode(e)) {
                    try self.emitBlockingStmt(e);
                } else if (isCallTo(e, "sa_task_spawn")) {
                    try self.emitSpawnSite(e);
                    try self.append(try self.tr.exprStmt(self.last_spawn_call.?));
                } else if (e.* == .if_expr) {
                    const s = self.scanOf(e);
                    if (s.blocking or s.spawn or s.supervised) {
                        try self.emitIf(e.if_expr);
                    } else {
                        try self.append(try self.emitPlain(stmt));
                    }
                } else {
                    const s = self.scanOf(e);
                    if (s.blocking or s.spawn or s.supervised)
                        return self.tr.fail("CoopBlockingNested: a goroutine operation appears in a nested expression position in '{s}'", .{self.finfo.fn_name});
                    try self.append(try self.emitPlain(stmt));
                }
            },
            .assign_stmt => |as| {
                const s = self.scanOf(as.value);
                const s2 = self.scanOf(as.target);
                if (s.blocking or s.spawn or s.supervised or s2.blocking or s2.spawn)
                    return self.tr.fail("CoopBlockingNested: a goroutine operation appears inside an assignment in '{s}'", .{self.finfo.fn_name});
                if (as.target.* == .identifier) {
                    if (self.finfo.fieldOf(as.target.identifier)) |f| {
                        if (f.addr_resident)
                            return self.tr.fail("CoopAddrRebind: aggregate local '{s}' in '{s}' is rebound by assignment; the cooperative lowering v1 carries literal initialisers and element writes for framed aggregates", .{ as.target.identifier, self.finfo.fn_name });
                    }
                }
                try self.append(try self.emitPlain(stmt));
            },
            .while_stmt => |ws| {
                const s = self.scanOf(stmt);
                if (s.blocking or s.spawn or s.supervised) {
                    const cs = self.scanOf(ws.cond);
                    if (cs.blocking or cs.spawn)
                        return self.tr.fail("CoopBlockingInCondition: the condition of a `while` in '{s}' performs a goroutine operation", .{self.finfo.fn_name});
                    try self.emitWhile(ws);
                } else {
                    try self.append(try self.emitPlain(stmt));
                }
            },
            .for_stmt => |fs| {
                var bs = scanInit(self.tr.allocator);
                scanStmts(&bs, fs.body, false);
                if (bs.blocking or bs.spawn or bs.supervised)
                    return self.tr.fail("CoopBlockingInFor: a `for` loop body in '{s}' performs a goroutine operation; use a `while` loop (the cooperative lowering splits while loops at suspension points)", .{self.finfo.fn_name});
                try self.append(try self.emitPlain(stmt));
            },
            .block_stmt => |bs| {
                const s = self.scanOf(stmt);
                if (s.blocking or s.spawn or s.supervised) {
                    const cont = self.allocId();
                    try self.emitSeq(bs.body, cont);
                    try self.openSegment(cont);
                } else {
                    try self.append(try self.emitPlain(stmt));
                }
            },
            .return_stmt => |rs| {
                if (rs.value) |v| {
                    const s = self.scanOf(v);
                    if (s.blocking or s.spawn or s.supervised)
                        return self.tr.fail("CoopBlockingNested: a goroutine operation appears in a return value in '{s}'", .{self.finfo.fn_name});
                }
                try self.closeReturn(rs.value);
            },
            .break_stmt => {
                const t = self.break_id orelse return self.tr.fail("CoopBreakOutsideLoop: `break` outside a loop in '{s}'", .{self.finfo.fn_name});
                try self.closeToState(t);
                self.terminated = true;
            },
            .continue_stmt => {
                const t = self.cont_id orelse return self.tr.fail("CoopContinueOutsideLoop: `continue` outside a loop in '{s}'", .{self.finfo.fn_name});
                try self.closeToState(t);
                self.terminated = true;
            },
            .defer_stmt => return self.tr.fail("CoopDefer: `defer` in goroutine function '{s}' is not carried by the cooperative lowering v1", .{self.finfo.fn_name}),
            .select_stmt => return self.tr.fail("CoopUnloweredSelect: a `select` statement survived syntax lowering in '{s}'", .{self.finfo.fn_name}),
            else => {
                const s = self.scanOf(stmt);
                if (s.blocking or s.spawn or s.supervised)
                    return self.tr.fail("CoopBlockingNested: a goroutine operation appears inside a statement the cooperative lowering does not split ('{s}')", .{self.finfo.fn_name});
                try self.append(try self.emitPlain(stmt));
            },
        }
    }

    fn emitIf(self: *Splitter, ie: ast.IfExpr) CoopError!void {
        if (ie.let_chain != null)
            return self.tr.fail("CoopIfLetBlocking: an if-let whose branches suspend in '{s}' is not carried by the cooperative lowering v1", .{self.finfo.fn_name});
        const then_id = self.allocId();
        const else_id = self.allocId();
        const merge_id = self.allocId();
        try self.closeCondTransfer(ie.cond, then_id, else_id);
        try self.openSegment(then_id);
        try self.emitSeq(ie.then_block, merge_id);
        try self.openSegment(else_id);
        if (ie.else_block) |eb| {
            try self.emitSeq(eb, merge_id);
        } else {
            try self.closeToState(merge_id);
        }
        try self.openSegment(merge_id);
    }

    fn emitWhile(self: *Splitter, ws: ast.WhileStmt) CoopError!void {
        const head_id = self.allocId();
        const body_id = self.allocId();
        const after_id = self.allocId();
        try self.closeToState(head_id);
        try self.openSegment(head_id);
        try self.closeCondTransfer(ws.cond, body_id, after_id);
        const saved_break = self.break_id;
        const saved_cont = self.cont_id;
        self.break_id = after_id;
        self.cont_id = head_id;
        try self.openSegment(body_id);
        try self.emitSeq(ws.body, head_id);
        self.break_id = saved_break;
        self.cont_id = saved_cont;
        try self.openSegment(after_id);
    }

    // ---- blocking sites ----

    fn rewriteBlockingArgs(self: *Splitter, call: *ast.Node) CoopError!void {
        var c = call.call_expr;
        var args = std.array_list.Managed(*ast.Node).init(self.tr.allocator);
        for (c.args) |arg| {
            if (arg.* == .borrow_expr and arg.borrow_expr.expr.* == .identifier) {
                const name = arg.borrow_expr.expr.identifier;
                if (self.finfo.fieldOf(name)) |f| {
                    // The runtime holds this pointer across the
                    // suspension: it must address the frame field,
                    // not the segment-local prologue copy.
                    const field = try self.tr.frameField(self.finfo, f.field, f.ty);
                    const borrow = try self.tr.newNode(.{ .borrow_expr = .{ .expr = field } });
                    self.tr.reg(borrow, try self.tr.tyBorrowOf(f.ty));
                    args.append(borrow) catch return error.OutOfMemory;
                    continue;
                }
                return self.tr.fail("CoopBlockingPointerShape: a blocking call in '{s}' borrows '{s}', which is not a frame local; blocking out-pointers must address frame fields", .{ self.finfo.fn_name, name });
            }
            if (arg.* == .borrow_expr)
                return self.tr.fail("CoopBlockingPointerShape: a blocking call in '{s}' borrows a non-local expression; blocking out-pointers must address frame fields", .{self.finfo.fn_name});
            args.append(arg) catch return error.OutOfMemory;
        }
        c.args = args.items;
        call.* = .{ .call_expr = c };
    }

    fn suspendHere(self: *Splitter, rc_name: ?[]const u8) CoopError!void {
        const next_id = self.allocId();
        try self.closeSuspend(rc_name, next_id);
        try self.openSegment(next_id);
        try self.takePrologue(rc_name);
    }

    fn emitBlockingAssign(self: *Splitter, name: []const u8, call: *ast.Node) CoopError!void {
        try self.rewriteBlockingArgs(call);
        const target = try self.tr.identNode(name, try self.tr.tyPrim(.i32));
        try self.append(try self.tr.assignNode(target, call));
        try self.suspendHere(name);
    }

    fn emitBlockingStmt(self: *Splitter, call: *ast.Node) CoopError!void {
        try self.rewriteBlockingArgs(call);
        // The return value is semantically discarded, but the
        // suspension decision needs it: capture it in a
        // segment-local temp (never framed, never read after the
        // continuation prologue consumed the pending status).
        self.tr.counter += 1;
        const tmp = std.fmt.allocPrint(self.tr.allocator, "__coop_rcblk_{d}", .{self.tr.counter}) catch return error.OutOfMemory;
        try self.append(try self.tr.letNode(tmp, try self.tr.tyPrim(.i32), call));
        try self.suspendHere(tmp);
    }

    // ---- spawn sites ----

    fn emitSpawnSite(self: *Splitter, call: *ast.Node) CoopError!void {
        const c = call.call_expr;
        if (c.args.len != 3)
            return self.tr.fail("CoopSpawnShape: lowered spawn in '{s}' does not have the expected 3-argument shape", .{self.finfo.fn_name});
        const entry_name = try self.tr.spawnEntryName(call, self.finfo.fn_name);
        const tf = self.tr.frameInfoOf(entry_name) orelse
            return self.tr.fail("CoopEntryNotFunction: go entry '{s}' was not collected as a goroutine target", .{entry_name});
        const size = self.tr.tc.payloadStorageSize(tf.frame_ty) orelse
            return self.tr.fail("CoopFrameSize: cannot compute the frame size for '{s}'", .{entry_name});
        self.tr.counter += 1;
        const fb_name = std.fmt.allocPrint(self.tr.allocator, "__coop_fb_{d}", .{self.tr.counter}) catch return error.OutOfMemory;
        const fp_name = std.fmt.allocPrint(self.tr.allocator, "__coop_fp_{d}", .{self.tr.counter}) catch return error.OutOfMemory;

        // Frame storage: a plain post-check let allocation of the
        // frame's byte size; never released (the runtime owns task
        // lifetimes in v1), so the frame outlives every suspension.
        const bytes_ty = self.tr.allocator.create(ast.Type) catch return error.OutOfMemory;
        bytes_ty.* = .{ .array = .{ .elem = try self.tr.tyPrim(.u8), .len = size } };
        const zero = try self.tr.intNodeAs(0, .u8);
        const repeat = try self.tr.newNode(.{ .repeat_array_literal = .{ .value = zero, .len = size } });
        self.tr.reg(repeat, bytes_ty);
        try self.append(try self.tr.letNode(fb_name, bytes_ty, repeat));

        const fb_ident = try self.tr.identNode(fb_name, bytes_ty);
        const borrow = try self.tr.newNode(.{ .borrow_expr = .{ .expr = fb_ident } });
        self.tr.reg(borrow, try self.tr.tyBorrowOf(bytes_ty));
        const cast = try self.tr.newNode(.{ .cast_expr = .{ .expr = borrow, .ty = tf.frame_ptr_ty } });
        self.tr.reg(cast, tf.frame_ptr_ty);
        try self.append(try self.tr.letNode(fp_name, tf.frame_ptr_ty, cast));

        // Parameter delivery (at most one, validated).
        if (tf.fd.params.len == 1) {
            const p = tf.fields.items[0];
            std.debug.assert(p.is_param);
            const fp_ident = try self.tr.identNode(fp_name, tf.frame_ptr_ty);
            const lhs = try self.tr.fieldNode(fp_ident, p.field, p.storage_ty);
            try self.append(try self.tr.assignNode(lhs, c.args[1]));
        }

        // Rewritten call: entry = step function, arg = frame ptr.
        const step_ty = self.tr.allocator.create(ast.Type) catch return error.OutOfMemory;
        {
            var params = std.array_list.Managed(*ast.Type).init(self.tr.allocator);
            params.append(tf.frame_ptr_ty) catch return error.OutOfMemory;
            step_ty.* = .{ .fn_ptr = .{ .params = params.items, .ret = try self.tr.tyPrim(.void_type) } };
        }
        const step_ident = try self.tr.identNode(tf.step_name, step_ty);
        const fp_arg = try self.tr.identNode(fp_name, tf.frame_ptr_ty);
        var new_args = std.array_list.Managed(*ast.Node).init(self.tr.allocator);
        new_args.append(step_ident) catch return error.OutOfMemory;
        new_args.append(fp_arg) catch return error.OutOfMemory;
        new_args.append(c.args[2]) catch return error.OutOfMemory;
        const new_call = try self.tr.newNode(.{ .call_expr = .{ .func_name = c.func_name, .generics = &.{}, .args = new_args.items } });
        self.tr.reg(new_call, try self.tr.tyPrim(.i32));
        self.last_spawn_call = new_call;
    }

    // ---- plain (non-splitting) conversion ----

    /// Address-resident locals live IN the frame field; a
    /// materialising literal initializer (repeat/array/struct)
    /// must be stored INTO the field, never bound to the name:
    /// binding the name to freshly materialised stack storage
    /// loses the value across suspension points (the runtime
    /// holds pointers to the field, e.g. chan slot buffers).
    /// Materialise a literal initialiser INTO an addr-resident
    /// frame field's inline storage, element by element. (An
    /// earlier form assigned the literal to the field, which
    /// the codegens render as materialising a temporary array
    /// and storing its POINTER into the field's first bytes —
    /// readers of the field then see a pointer where element
    /// data belongs.) Returns null when the value is not a
    /// materialising literal.
    fn addrInitStmts(self: *Splitter, f: *const FieldInfo, value: *ast.Node) CoopError!?*ast.Node {
        if (!f.addr_resident) return null;
        var body = std.array_list.Managed(*ast.Node).init(self.tr.allocator);
        switch (value.*) {
            .array_literal => |al| {
                for (al.elements, 0..) |elem, i| {
                    const base = try self.tr.frameField(self.finfo, f.field, f.storage_ty);
                    const idx = try self.tr.intNodeAs(@intCast(i), .u64);
                    const target = try self.tr.newNode(.{ .index_expr = .{ .target = base, .index = idx } });
                    self.tr.reg(target, self.tr.tc.expr_types.get(elem) orelse f.ty);
                    body.append(try self.tr.assignNode(target, elem)) catch return error.OutOfMemory;
                }
            },
            .repeat_array_literal => |ra| {
                if (ra.value.* != .literal)
                    return self.tr.fail("CoopRepeatInitValue: a repeat-array initialiser with a non-literal value in '{s}' is not carried by the cooperative lowering v1", .{self.finfo.fn_name});
                if (ra.len > 1024)
                    return self.tr.fail("CoopArrayInitTooLarge: a {d}-element array initialiser in '{s}' exceeds the cooperative lowering v1 materialisation limit", .{ ra.len, self.finfo.fn_name });
                for (0..ra.len) |i| {
                    const base = try self.tr.frameField(self.finfo, f.field, f.storage_ty);
                    const idx = try self.tr.intNodeAs(@intCast(i), .u64);
                    const target = try self.tr.newNode(.{ .index_expr = .{ .target = base, .index = idx } });
                    const elem_ty = if (f.ty.* == .array) f.ty.array.elem else f.ty;
                    self.tr.reg(target, elem_ty);
                    const lit = try self.tr.newNode(.{ .literal = ra.value.literal });
                    self.tr.reg(lit, elem_ty);
                    body.append(try self.tr.assignNode(target, lit)) catch return error.OutOfMemory;
                }
            },
            .struct_literal => |sl| {
                for (sl.fields) |fld| {
                    const base = try self.tr.frameField(self.finfo, f.field, f.storage_ty);
                    const target = try self.tr.fieldNode(base, fld.name, self.tr.tc.expr_types.get(fld.value) orelse f.ty);
                    body.append(try self.tr.assignNode(target, fld.value)) catch return error.OutOfMemory;
                }
            },
            .tuple_literal => |tl| {
                for (tl.elements, 0..) |elem, i| {
                    const base = try self.tr.frameField(self.finfo, f.field, f.storage_ty);
                    const idx_name = std.fmt.allocPrint(self.tr.allocator, "{d}", .{i}) catch return error.OutOfMemory;
                    const target = try self.tr.fieldNode(base, idx_name, self.tr.tc.expr_types.get(elem) orelse f.ty);
                    body.append(try self.tr.assignNode(target, elem)) catch return error.OutOfMemory;
                }
            },
            else => return null,
        }
        if (body.items.len == 1) return body.items[0];
        return self.tr.newNode(.{ .block_stmt = .{ .body = body.items } });
    }

    /// Consumption-site guard. A reg<-reg assignment in the SAB
    /// codegen MOVES its source (the verifier's consumeSourceValue
    /// model): a framed non-Copy local read in a consuming
    /// position (bare-identifier right-hand side, move operand,
    /// by-move call argument) ends in the Consumed state on this
    /// control-flow path while sibling switch cases leave it
    /// Active/Untracked — the verifier rejects the join
    /// (PhiStateConflict / UseAfterMove), a limitation the
    /// baseline has for moves inside any conditional branch.
    /// The step function therefore never consumes a framed
    /// register: consuming positions are rewritten to load the
    /// value from the frame field (the load's fresh register is
    /// what gets consumed), with a single-field write-back first
    /// when the segment already changed the local.
    fn isNonCopyTy(_: *Splitter, ty: *ast.Type) bool {
        return switch (ty.*) {
            .user_defined, .borrow, .array, .tuple => true,
            else => false,
        };
    }

    fn framedNonCopy(self: *Splitter, name: []const u8) bool {
        const f = self.finfo.fieldOf(name) orelse return false;
        return self.isNonCopyTy(f.ty);
    }

    fn noteSite(self: *Splitter, sites: *std.StringHashMap(void), node: *ast.Node) void {
        if (node.* == .identifier and self.finfo.fieldOf(node.identifier) != null and self.useIsConsuming(node))
            sites.put(node.identifier, {}) catch {};
    }

    fn collectConsumedSites(self: *Splitter, sites: *std.StringHashMap(void), node: *ast.Node) void {
        switch (node.*) {
            .call_expr => |c| {
                if (c.callee) |cal| self.collectConsumedSites(sites, cal);
                for (c.args, 0..) |a, ai| {
                    if (a.* == .identifier and self.paramIsMove(c.func_name, ai))
                        self.noteSite(sites, a);
                    self.collectConsumedSites(sites, a);
                }
            },
            .let_stmt => |s| {
                self.noteSite(sites, s.value);
                self.collectConsumedSites(sites, s.value);
            },
            .const_stmt => |s| {
                self.noteSite(sites, s.value);
                self.collectConsumedSites(sites, s.value);
            },
            .let_destructure_stmt => |s| {
                self.noteSite(sites, s.value);
                self.collectConsumedSites(sites, s.value);
            },
            .assign_stmt => |s| {
                self.noteSite(sites, s.value);
                if (s.target.* == .identifier and self.framedNonCopy(s.target.identifier) and s.value.* == .identifier)
                    self.noteSite(sites, s.value);
                self.collectConsumedSites(sites, s.target);
                self.collectConsumedSites(sites, s.value);
            },
            .move_expr => |s| {
                self.noteSite(sites, s.expr);
                self.collectConsumedSites(sites, s.expr);
            },
            .borrow_expr => |s| self.collectConsumedSites(sites, s.expr),
            .expr_stmt => |s| self.collectConsumedSites(sites, s),
            .func_decl => |fd| for (fd.body) |b| self.collectConsumedSites(sites, b),
            .let_else_stmt => |s| {
                self.collectConsumedSites(sites, s.value);
                for (s.else_block) |b| self.collectConsumedSites(sites, b);
            },
            .block_stmt => |s| for (s.body) |b| self.collectConsumedSites(sites, b),
            .return_stmt => |s| if (s.value) |v| self.collectConsumedSites(sites, v),
            .for_stmt => |s| {
                self.collectConsumedSites(sites, s.start);
                if (s.end) |e| self.collectConsumedSites(sites, e);
                for (s.body) |b| self.collectConsumedSites(sites, b);
            },
            .while_stmt => |s| {
                self.collectConsumedSites(sites, s.cond);
                for (s.body) |b| self.collectConsumedSites(sites, b);
            },
            .if_expr => |s| {
                self.collectConsumedSites(sites, s.cond);
                for (s.then_block) |b| self.collectConsumedSites(sites, b);
                if (s.else_block) |eb| for (eb) |b| self.collectConsumedSites(sites, b);
            },
            .switch_expr => |s| {
                self.collectConsumedSites(sites, s.val);
                for (s.cases) |case| for (case.body) |b| self.collectConsumedSites(sites, b);
            },
            .match_expr => |s| {
                self.collectConsumedSites(sites, s.val);
                for (s.cases) |case| for (case.body) |b| self.collectConsumedSites(sites, b);
            },
            .select_stmt => |s| {
                for (s.cases) |case| {
                    self.collectConsumedSites(sites, case.call);
                    for (case.body) |b| self.collectConsumedSites(sites, b);
                }
                if (s.default_body) |db| for (db) |b| self.collectConsumedSites(sites, b);
                if (s.timeout_body) |tb| for (tb) |b| self.collectConsumedSites(sites, b);
            },
            .unsafe_expr => |s| for (s.body) |b| self.collectConsumedSites(sites, b),
            .closure_literal => |s| self.collectConsumedSites(sites, s.body),
            .binary_expr => |s| {
                self.collectConsumedSites(sites, s.left);
                self.collectConsumedSites(sites, s.right);
            },
            .deref_expr => |s| self.collectConsumedSites(sites, s.expr),
            .cast_expr => |s| self.collectConsumedSites(sites, s.expr),
            .field_expr => |s| self.collectConsumedSites(sites, s.expr),
            .index_expr => |s| {
                self.collectConsumedSites(sites, s.target);
                self.collectConsumedSites(sites, s.index);
            },
            .slice_expr => |s| {
                self.collectConsumedSites(sites, s.target);
                self.collectConsumedSites(sites, s.start);
                self.collectConsumedSites(sites, s.end);
            },
            .tuple_literal => |s| for (s.elements) |e| self.collectConsumedSites(sites, e),
            .array_literal => |s| for (s.elements) |e| self.collectConsumedSites(sites, e),
            .repeat_array_literal => |s| self.collectConsumedSites(sites, s.value),
            .struct_literal => |s| for (s.fields) |f| self.collectConsumedSites(sites, f.value),
            .try_expr => |s| self.collectConsumedSites(sites, s.expr),
            .await_expr => |s| self.collectConsumedSites(sites, s.expr),
            else => {},
        }
    }

    fn frameLoadOf(self: *Splitter, name: []const u8) CoopError!*ast.Node {
        const f = self.finfo.fieldOf(name).?;
        return self.tr.frameField(self.finfo, f.field, f.storage_ty);
    }

    fn rewriteConsumed(self: *Splitter, sites: *std.StringHashMap(void), node: *ast.Node) CoopError!void {
        switch (node.*) {
            .call_expr => |c| {
                if (c.callee) |cal| try self.rewriteConsumed(sites, cal);
                for (c.args, 0..) |a, ai| {
                    if (a.* == .identifier and sites.contains(a.identifier) and self.paramIsMove(c.func_name, ai)) {
                        @constCast(c.args)[ai] = try self.frameLoadOf(a.identifier);
                        continue;
                    }
                    try self.rewriteConsumed(sites, a);
                }
            },
            .let_stmt => |s| {
                if (s.value.* == .identifier and sites.contains(s.value.identifier)) {
                    var copy = s;
                    copy.value = try self.frameLoadOf(s.value.identifier);
                    node.* = .{ .let_stmt = copy };
                    return;
                }
                try self.rewriteConsumed(sites, s.value);
            },
            .const_stmt => |s| {
                if (s.value.* == .identifier and sites.contains(s.value.identifier)) {
                    var copy = s;
                    copy.value = try self.frameLoadOf(s.value.identifier);
                    node.* = .{ .const_stmt = copy };
                    return;
                }
                try self.rewriteConsumed(sites, s.value);
            },
            .let_destructure_stmt => |s| {
                if (s.value.* == .identifier and sites.contains(s.value.identifier)) {
                    var copy = s;
                    copy.value = try self.frameLoadOf(s.value.identifier);
                    node.* = .{ .let_destructure_stmt = copy };
                    return;
                }
                try self.rewriteConsumed(sites, s.value);
            },
            .assign_stmt => |s| {
                try self.rewriteConsumed(sites, s.target);
                if (s.value.* == .identifier and sites.contains(s.value.identifier)) {
                    var copy = s;
                    copy.value = try self.frameLoadOf(s.value.identifier);
                    node.* = .{ .assign_stmt = copy };
                    return;
                }
                try self.rewriteConsumed(sites, s.value);
            },
            .move_expr => |s| {
                if (s.expr.* == .identifier and sites.contains(s.expr.identifier)) {
                    const load = try self.frameLoadOf(s.expr.identifier);
                    node.* = load.*;
                    return;
                }
                try self.rewriteConsumed(sites, s.expr);
            },
            .borrow_expr => |s| try self.rewriteConsumed(sites, s.expr),
            .expr_stmt => |s| try self.rewriteConsumed(sites, s),
            .let_else_stmt => |s| {
                try self.rewriteConsumed(sites, s.value);
                for (s.else_block) |b| try self.rewriteConsumed(sites, b);
            },
            .block_stmt => |s| for (s.body) |b| try self.rewriteConsumed(sites, b),
            .return_stmt => |s| if (s.value) |v| try self.rewriteConsumed(sites, v),
            .for_stmt => |s| {
                try self.rewriteConsumed(sites, s.start);
                if (s.end) |e| try self.rewriteConsumed(sites, e);
                for (s.body) |b| try self.rewriteConsumed(sites, b);
            },
            .while_stmt => |s| {
                try self.rewriteConsumed(sites, s.cond);
                for (s.body) |b| try self.rewriteConsumed(sites, b);
            },
            .if_expr => |s| {
                try self.rewriteConsumed(sites, s.cond);
                for (s.then_block) |b| try self.rewriteConsumed(sites, b);
                if (s.else_block) |eb| for (eb) |b| try self.rewriteConsumed(sites, b);
            },
            .switch_expr => |s| {
                try self.rewriteConsumed(sites, s.val);
                for (s.cases) |case| for (case.body) |b| try self.rewriteConsumed(sites, b);
            },
            .match_expr => |s| {
                try self.rewriteConsumed(sites, s.val);
                for (s.cases) |case| for (case.body) |b| try self.rewriteConsumed(sites, b);
            },
            .select_stmt => |s| {
                for (s.cases) |case| {
                    try self.rewriteConsumed(sites, case.call);
                    for (case.body) |b| try self.rewriteConsumed(sites, b);
                }
                if (s.default_body) |db| for (db) |b| try self.rewriteConsumed(sites, b);
                if (s.timeout_body) |tb| for (tb) |b| try self.rewriteConsumed(sites, b);
            },
            .unsafe_expr => |s| for (s.body) |b| try self.rewriteConsumed(sites, b),
            .closure_literal => |s| try self.rewriteConsumed(sites, s.body),
            .binary_expr => |s| {
                try self.rewriteConsumed(sites, s.left);
                try self.rewriteConsumed(sites, s.right);
            },
            .deref_expr => |s| try self.rewriteConsumed(sites, s.expr),
            .cast_expr => |s| try self.rewriteConsumed(sites, s.expr),
            .field_expr => |s| try self.rewriteConsumed(sites, s.expr),
            .index_expr => |s| {
                try self.rewriteConsumed(sites, s.target);
                try self.rewriteConsumed(sites, s.index);
            },
            .slice_expr => |s| {
                try self.rewriteConsumed(sites, s.target);
                try self.rewriteConsumed(sites, s.start);
                try self.rewriteConsumed(sites, s.end);
            },
            .tuple_literal => |s| for (s.elements) |e| try self.rewriteConsumed(sites, e),
            .array_literal => |s| for (s.elements) |e| try self.rewriteConsumed(sites, e),
            .repeat_array_literal => |s| try self.rewriteConsumed(sites, s.value),
            .struct_literal => |s| for (s.fields) |f| try self.rewriteConsumed(sites, f.value),
            .try_expr => |s| try self.rewriteConsumed(sites, s.expr),
            .await_expr => |s| try self.rewriteConsumed(sites, s.expr),
            else => {},
        }
    }

    fn emitPlain(self: *Splitter, stmt: *ast.Node) CoopError!*ast.Node {
        var sites = std.StringHashMap(void).init(self.tr.allocator);
        self.collectConsumedSites(&sites, stmt);
        if (sites.count() == 0) return self.emitPlainInner(stmt);
        // The frame must be current for every consumed name the
        // segment already changed: flush those fields first.
        var touch = self.touchInit();
        if (self.cur) |seg| {
            for (seg.stmts.items) |s| self.scanTouch(&touch, s);
        }
        var prefix = std.array_list.Managed(*ast.Node).init(self.tr.allocator);
        var sit = sites.keyIterator();
        while (sit.next()) |name| {
            if (touch.assigned.contains(name.*) or touch.borrowed.contains(name.*)) {
                const f = self.finfo.fieldOf(name.*) orelse continue;
                const lhs = try self.tr.frameField(self.finfo, f.field, f.storage_ty);
                const rhs = try self.tr.identNode(name.*, f.ty);
                prefix.append(try self.tr.assignNode(lhs, rhs)) catch return error.OutOfMemory;
            }
        }
        try self.rewriteConsumed(&sites, stmt);
        const converted = try self.emitPlainInner(stmt);
        if (prefix.items.len == 0) return converted;
        prefix.append(converted) catch return error.OutOfMemory;
        return self.tr.newNode(.{ .block_stmt = .{ .body = prefix.items } });
    }

    fn emitPlainInner(self: *Splitter, stmt: *ast.Node) CoopError!*ast.Node {
        switch (stmt.*) {
            .let_stmt => |ls| {
                if (self.finfo.fieldOf(ls.name)) |f| {
                    if (try self.addrInitStmts(f, ls.value)) |stmts| return stmts;
                    if (f.addr_resident)
                        return self.tr.fail("CoopAddrRebind: aggregate local '{s}' in '{s}' is rebound from a non-literal value; the cooperative lowering v1 carries literal initialisers and element writes for framed aggregates", .{ ls.name, self.finfo.fn_name });
                    const target = try self.tr.identNode(ls.name, f.ty);
                    return self.tr.assignNode(target, ls.value);
                }
                return stmt;
            },
            .const_stmt => |cs| {
                if (self.finfo.fieldOf(cs.name)) |f| {
                    if (try self.addrInitStmts(f, cs.value)) |stmts| return stmts;
                    if (f.addr_resident)
                        return self.tr.fail("CoopAddrRebind: aggregate local '{s}' in '{s}' is rebound from a non-literal value; the cooperative lowering v1 carries literal initialisers and element writes for framed aggregates", .{ cs.name, self.finfo.fn_name });
                    const target = try self.tr.identNode(cs.name, f.ty);
                    return self.tr.assignNode(target, cs.value);
                }
                return stmt;
            },
            .let_destructure_stmt => |ld| {
                // tmp binding + per-name assignments (names are
                // frame locals, already bound by the prologue).
                self.tr.counter += 1;
                const tmp = std.fmt.allocPrint(self.tr.allocator, "__coop_dt_{d}", .{self.tr.counter}) catch return error.OutOfMemory;
                const vt = self.tr.tc.expr_types.get(ld.value) orelse return stmt;
                var body = std.array_list.Managed(*ast.Node).init(self.tr.allocator);
                body.append(try self.tr.letNode(tmp, vt, ld.value)) catch return error.OutOfMemory;
                for (ld.names, vt.tuple.elems) |n, et| {
                    const tmp_ident = try self.tr.identNode(tmp, vt);
                    const idx_name = std.fmt.allocPrint(self.tr.allocator, "{d}", .{body.items.len - 1}) catch return error.OutOfMemory;
                    const proj = try self.tr.fieldNode(tmp_ident, idx_name, et);
                    if (self.finfo.fieldOf(n) == null) {
                        body.append(try self.tr.letNode(n, et, proj)) catch return error.OutOfMemory;
                    } else {
                        const target = try self.tr.identNode(n, et);
                        body.append(try self.tr.assignNode(target, proj)) catch return error.OutOfMemory;
                    }
                }
                return self.tr.newNode(.{ .block_stmt = .{ .body = body.items } });
            },
            .expr_stmt => |e| {
                try self.plainExprBlocks(e);
                return stmt;
            },
            .while_stmt => |ws| {
                var copy = ws;
                copy.body = try self.plainList(ws.body);
                return self.copyNode(.{ .while_stmt = copy });
            },
            .for_stmt => |fs| {
                var copy = fs;
                copy.body = try self.plainList(fs.body);
                return self.copyNode(.{ .for_stmt = copy });
            },
            .block_stmt => |bs| {
                return self.tr.newNode(.{ .block_stmt = .{ .body = try self.plainList(bs.body) } });
            },
            else => {
                try self.plainStmtExprs(stmt);
                return stmt;
            },
        }
    }

    fn copyNode(self: *Splitter, value: ast.Node) CoopError!*ast.Node {
        return self.tr.newNode(value);
    }

    fn plainList(self: *Splitter, stmts: []const *ast.Node) CoopError![]const *ast.Node {
        var out = std.array_list.Managed(*ast.Node).init(self.tr.allocator);
        for (stmts) |s| {
            if (s.* == .var_stmt and self.finfo.fieldOf(s.var_stmt.name) != null) continue;
            out.append(try self.emitPlain(s)) catch return error.OutOfMemory;
        }
        return out.items;
    }

    fn plainExprBlocks(self: *Splitter, e: *ast.Node) CoopError!void {
        switch (e.*) {
            .if_expr => |ie| {
                var copy = ie;
                copy.then_block = try self.plainList(ie.then_block);
                if (ie.else_block) |eb| copy.else_block = try self.plainList(eb);
                e.* = .{ .if_expr = copy };
            },
            .switch_expr => |se| {
                var cases = std.array_list.Managed(ast.Case).init(self.tr.allocator);
                for (se.cases) |case| {
                    cases.append(.{ .pattern = case.pattern, .body = try self.plainList(case.body) }) catch return error.OutOfMemory;
                }
                e.* = .{ .switch_expr = .{ .val = se.val, .cases = cases.items } };
            },
            .match_expr => |me| {
                var cases = std.array_list.Managed(ast.MatchCase).init(self.tr.allocator);
                for (me.cases) |case| {
                    cases.append(.{ .pattern = case.pattern, .guard = case.guard, .body = try self.plainList(case.body) }) catch return error.OutOfMemory;
                }
                e.* = .{ .match_expr = .{ .val = me.val, .cases = cases.items } };
            },
            .binary_expr => |b| {
                try self.plainExprBlocks(b.left);
                try self.plainExprBlocks(b.right);
            },
            .call_expr => |c| {
                if (c.callee) |cal| try self.plainExprBlocks(cal);
                for (c.args) |a| try self.plainExprBlocks(a);
            },
            .borrow_expr => |b| try self.plainExprBlocks(b.expr),
            .move_expr => |b| try self.plainExprBlocks(b.expr),
            .deref_expr => |b| try self.plainExprBlocks(b.expr),
            .cast_expr => |b| try self.plainExprBlocks(b.expr),
            .field_expr => |b| try self.plainExprBlocks(b.expr),
            .try_expr => |b| try self.plainExprBlocks(b.expr),
            else => {},
        }
    }

    fn plainStmtExprs(self: *Splitter, stmt: *ast.Node) CoopError!void {
        switch (stmt.*) {
            .assign_stmt => |as| {
                try self.plainExprBlocks(as.target);
                try self.plainExprBlocks(as.value);
            },
            .return_stmt => |rs| {
                if (rs.value) |v| try self.plainExprBlocks(v);
            },
            else => {},
        }
    }

    // ---- assembly ----

    fn rewrite(self: *Splitter) CoopError!void {
        self.segments = std.AutoHashMap(u64, *Segment).init(self.tr.allocator);
        const entry_id = self.allocId();
        std.debug.assert(entry_id == 0);
        try self.openSegment(entry_id);
        try self.emitSeq(self.finfo.fd.body, END_ID);

        // Segment functions + dispatcher. Each segment is its
        // OWN function: segment bodies are ordinary structured
        // code (the shape both codegens' register-state
        // discipline is built for), and the only cross-segment
        // carrier is the frame memory plus frame.state. An
        // earlier single-function form (one switch whose cases
        // were the segments) repeatedly failed verification:
        // codegen releases named registers at case exits by
        // liveness, so cross-case register states (Active /
        // Consumed / Untracked) disagreed at the switch and
        // loop-head joins (PhiStateConflict / UnknownRegister)
        // for any non-trivial body. A segment function returns
        // 0 = keep dispatching, 1 = stop (suspended or done).
        const i32_ty = try self.tr.tyPrim(.i32);

        var ids = std.array_list.Managed(u64).init(self.tr.allocator);
        var kit = self.segments.keyIterator();
        while (kit.next()) |k| ids.append(k.*) catch return error.OutOfMemory;
        std.mem.sort(u64, ids.items, {}, std.sort.asc(u64));
        ids.append(END_ID) catch return error.OutOfMemory;

        var cases = std.array_list.Managed(ast.Case).init(self.tr.allocator);
        for (ids.items) |id| {
            const seg_name = std.fmt.allocPrint(self.tr.allocator, "__coop_seg_{s}_{d}", .{ self.finfo.fn_name, id }) catch return error.OutOfMemory;
            var seg_stmts = std.array_list.Managed(*ast.Node).init(self.tr.allocator);
            // Per-function prologue: bind every parameter/local
            // from its frame field exactly once in THIS function
            // (single-let per function, so name-keyed register
            // resolution for extern borrow operands works as in
            // ordinary code). For word types this loads the
            // value; for address-resident types the field access
            // IS the storage address, so in-place mutations land
            // in the frame directly.
            if (id != END_ID) {
                for (self.finfo.fields.items) |f| {
                    const rhs = try self.tr.frameField(self.finfo, f.field, f.storage_ty);
                    seg_stmts.append(try self.tr.letNode(f.orig, f.ty, rhs)) catch return error.OutOfMemory;
                }
            }
            if (id == END_ID) {
                // END: fell off the end of the body.
                const finish = try self.tr.coopCall("sa_coop_finish", &.{}, try self.tr.tyPrim(.void_type));
                seg_stmts.append(try self.tr.exprStmt(finish)) catch return error.OutOfMemory;
                seg_stmts.append(try self.stateAssign(DONE_ID)) catch return error.OutOfMemory;
                seg_stmts.append(try self.returnConst(1)) catch return error.OutOfMemory;
            } else {
                const seg = self.segments.get(id).?;
                for (seg.stmts.items) |s| seg_stmts.append(s) catch return error.OutOfMemory;
            }
            const seg_param = self.tr.allocator.alloc(ast.Param, 1) catch return error.OutOfMemory;
            seg_param[0] = .{ .name = "__coop_frame", .ty = self.finfo.frame_ptr_ty };
            const seg_fd = ast.FuncDecl{
                .name = seg_name,
                .generics = &.{},
                .params = seg_param,
                .ret_ty = i32_ty,
                .body = seg_stmts.items,
                .is_inline = false,
            };
            const seg_node = try self.tr.newNode(.{ .func_decl = seg_fd });
            self.tr.synth_decls.append(seg_node) catch return error.OutOfMemory;
            self.tr.tc.funcs.put(seg_fd.name, &seg_node.func_decl) catch return error.OutOfMemory;

            // Dispatcher case: if (seg(frame) == 1) { return; }
            const frame_ident = try self.tr.identNode("__coop_frame", self.finfo.frame_ptr_ty);
            const call_args = self.tr.allocator.dupe(*ast.Node, &.{frame_ident}) catch return error.OutOfMemory;
            const call = try self.tr.newNode(.{ .call_expr = .{ .func_name = seg_name, .associated_target = null, .generics = &.{}, .args = call_args, .callee = null } });
            self.tr.reg(call, i32_ty);
            const one = try self.tr.intNodeAs(1, .i32);
            const cond = try self.tr.newNode(.{ .binary_expr = .{ .op = .eq, .left = call, .right = one } });
            self.tr.reg(cond, try self.tr.tyPrim(.boolean));
            const ret = try self.tr.returnNode();
            const if_node = try self.ifStmtNode(cond, &.{ret}, null);
            const case_body = self.tr.allocator.dupe(*ast.Node, &.{if_node}) catch return error.OutOfMemory;
            const pat = try self.tr.intNodeAs(@intCast(id), .i64);
            cases.append(.{ .pattern = pat, .body = case_body }) catch return error.OutOfMemory;
        }
        {
            // DONE: terminal state; the step invocation returns.
            const pat = try self.tr.intNodeAs(@intCast(DONE_ID), .i64);
            const ret = try self.tr.returnNode();
            const body = self.tr.allocator.dupe(*ast.Node, &.{ret}) catch return error.OutOfMemory;
            cases.append(.{ .pattern = pat, .body = body }) catch return error.OutOfMemory;
        }
        {
            // Default: route to DONE and fall through to the
            // dispatch loop (which then returns via the DONE
            // case). Returning directly here would leave an
            // all-cases-return switch whose join block the SAB
            // codegen emits without a terminator.
            const pat = try self.tr.identNode("default", try self.tr.tyPrim(.i64));
            const to_done = try self.stateAssign(DONE_ID);
            const body = self.tr.allocator.dupe(*ast.Node, &.{to_done}) catch return error.OutOfMemory;
            cases.append(.{ .pattern = pat, .body = body }) catch return error.OutOfMemory;
        }

        const state_field = try self.tr.frameField(self.finfo, "state", try self.tr.tyPrim(.i64));
        const switch_node = try self.tr.newNode(.{ .switch_expr = .{ .val = state_field, .cases = cases.items } });
        self.tr.reg(switch_node, try self.tr.tyPrim(.void_type));
        const true_node = try self.tr.newNode(.{ .literal = .{ .bool_val = true } });
        self.tr.reg(true_node, try self.tr.tyPrim(.boolean));
        const switch_stmt = try self.tr.exprStmt(switch_node);
        const while_body = self.tr.allocator.dupe(*ast.Node, &.{switch_stmt}) catch return error.OutOfMemory;
        const while_node = try self.tr.newNode(.{ .while_stmt = .{ .cond = true_node, .body = while_body } });

        const param = self.tr.allocator.alloc(ast.Param, 1) catch return error.OutOfMemory;
        param[0] = .{ .name = "__coop_frame", .ty = self.finfo.frame_ptr_ty };
        const step_body = self.tr.allocator.dupe(*ast.Node, &.{while_node}) catch return error.OutOfMemory;
        const step_fd = ast.FuncDecl{
            .name = self.finfo.step_name,
            .generics = &.{},
            .params = param,
            .ret_ty = try self.tr.tyPrim(.void_type),
            .body = step_body,
            .is_inline = false,
        };

        if (self.finfo.is_main) {
            const step_node = try self.tr.newNode(.{ .func_decl = step_fd });
            self.tr.synth_decls.append(step_node) catch return error.OutOfMemory;
            // Codegens resolve function-value identifiers through
            // tc.funcs; the checker never saw the step functions.
            self.tr.tc.funcs.put(step_fd.name, &step_node.func_decl) catch return error.OutOfMemory;
            try self.buildMainWrapper();
        } else {
            self.finfo.decl_node.* = .{ .func_decl = step_fd };
            self.tr.tc.funcs.put(step_fd.name, &self.finfo.decl_node.func_decl) catch return error.OutOfMemory;
        }
    }

    fn buildMainWrapper(self: *Splitter) CoopError!void {
        const finfo = self.finfo;
        const size = self.tr.tc.payloadStorageSize(finfo.frame_ty) orelse
            return self.tr.fail("CoopFrameSize: cannot compute the frame size for `main`", .{});
        var body = std.array_list.Managed(*ast.Node).init(self.tr.allocator);

        const bytes_ty = self.tr.allocator.create(ast.Type) catch return error.OutOfMemory;
        bytes_ty.* = .{ .array = .{ .elem = try self.tr.tyPrim(.u8), .len = size } };
        const zero = try self.tr.intNodeAs(0, .u8);
        const repeat = try self.tr.newNode(.{ .repeat_array_literal = .{ .value = zero, .len = size } });
        self.tr.reg(repeat, bytes_ty);
        body.append(try self.tr.letNode("__coop_fb", bytes_ty, repeat)) catch return error.OutOfMemory;

        const fb_ident = try self.tr.identNode("__coop_fb", bytes_ty);
        const borrow = try self.tr.newNode(.{ .borrow_expr = .{ .expr = fb_ident } });
        self.tr.reg(borrow, try self.tr.tyBorrowOf(bytes_ty));
        const cast = try self.tr.newNode(.{ .cast_expr = .{ .expr = borrow, .ty = finfo.frame_ptr_ty } });
        self.tr.reg(cast, finfo.frame_ptr_ty);
        body.append(try self.tr.letNode("__coop_fp", finfo.frame_ptr_ty, cast)) catch return error.OutOfMemory;

        const step_ty = self.tr.allocator.create(ast.Type) catch return error.OutOfMemory;
        {
            var params = std.array_list.Managed(*ast.Type).init(self.tr.allocator);
            params.append(finfo.frame_ptr_ty) catch return error.OutOfMemory;
            step_ty.* = .{ .fn_ptr = .{ .params = params.items, .ret = try self.tr.tyPrim(.void_type) } };
        }
        const step_ident = try self.tr.identNode(finfo.step_name, step_ty);
        const fp_ident = try self.tr.identNode("__coop_fp", finfo.frame_ptr_ty);
        const i32_ty = try self.tr.tyPrim(.i32);
        const run_call = try self.tr.coopCall("sa_coop_run_main", &.{ step_ident, fp_ident }, i32_ty);
        body.append(try self.tr.letNode("__coop_rc", i32_ty, run_call)) catch return error.OutOfMemory;

        const wrapper_ret = if (self.tr.isVoidTy(finfo.ret_ty)) i32_ty else finfo.ret_ty;
        {
            const rc_ident = try self.tr.identNode("__coop_rc", i32_ty);
            const zero32 = try self.tr.intNodeAs(0, .i32);
            const cond = try self.tr.newNode(.{ .binary_expr = .{ .op = .ne, .left = rc_ident, .right = zero32 } });
            self.tr.reg(cond, try self.tr.tyPrim(.boolean));
            var ret_val: *ast.Node = rc_ident;
            if (!self.tr.sameType(wrapper_ret, i32_ty)) {
                const cast2 = try self.tr.newNode(.{ .cast_expr = .{ .expr = rc_ident, .ty = wrapper_ret } });
                self.tr.reg(cast2, wrapper_ret);
                ret_val = cast2;
            }
            const ret_stmt = try self.tr.newNode(.{ .return_stmt = .{ .value = ret_val } });
            const then_owned = self.tr.allocator.dupe(*ast.Node, &.{ret_stmt}) catch return error.OutOfMemory;
            const if_node = try self.tr.newNode(.{ .if_expr = .{ .cond = cond, .then_block = then_owned, .else_block = null } });
            self.tr.reg(if_node, try self.tr.tyPrim(.void_type));
            body.append(try self.tr.exprStmt(if_node)) catch return error.OutOfMemory;
        }
        if (self.tr.isVoidTy(finfo.ret_ty)) {
            const zero_ret = try self.tr.intNodeAs(0, .i32);
            body.append(try self.tr.newNode(.{ .return_stmt = .{ .value = zero_ret } })) catch return error.OutOfMemory;
        } else {
            const fp2 = try self.tr.identNode("__coop_fp", finfo.frame_ptr_ty);
            const result = try self.tr.fieldNode(fp2, "result", finfo.result_storage_ty);
            body.append(try self.tr.newNode(.{ .return_stmt = .{ .value = result } })) catch return error.OutOfMemory;
        }

        finfo.decl_node.* = .{ .func_decl = .{
            .name = "main",
            .generics = &.{},
            .params = &.{},
            .ret_ty = wrapper_ret,
            .body = body.items,
            .is_inline = false,
        } };
    }
};

/// Strict structural type equality for the transform's own
/// bookkeeping (shadowed-local detection and the main wrapper's
/// return cast decision).
fn typeEql(a: *ast.Type, b: *ast.Type) bool {
    if (std.meta.activeTag(a.*) != std.meta.activeTag(b.*)) return false;
    return switch (a.*) {
        .infer => true,
        .primitive => |pa| pa == b.primitive,
        .pointer => |pa| typeEql(pa, b.pointer),
        .borrow => |ba| typeEql(ba, b.borrow),
        .array => |aa| aa.len == b.array.len and typeEql(aa.elem, b.array.elem),
        .tuple => |ta| blk: {
            if (ta.elems.len != b.tuple.elems.len) break :blk false;
            for (ta.elems, b.tuple.elems) |ea, eb| {
                if (!typeEql(ea, eb)) break :blk false;
            }
            break :blk true;
        },
        .future => |fa| typeEql(fa, b.future),
        .closure => |ca| blk: {
            if (ca.params.len != b.closure.params.len) break :blk false;
            for (ca.params, b.closure.params) |pa, pb| {
                if (!typeEql(pa, pb)) break :blk false;
            }
            break :blk typeEql(ca.ret, b.closure.ret);
        },
        .fn_ptr => |fa| blk: {
            if (fa.params.len != b.fn_ptr.params.len) break :blk false;
            for (fa.params, b.fn_ptr.params) |pa, pb| {
                if (!typeEql(pa, pb)) break :blk false;
            }
            break :blk typeEql(fa.ret, b.fn_ptr.ret);
        },
        .user_defined => |uda| blk: {
            if (!std.mem.eql(u8, uda.name, b.user_defined.name)) break :blk false;
            if (uda.generics.len != b.user_defined.generics.len) break :blk false;
            for (uda.generics, b.user_defined.generics) |ga, gb| {
                if (!typeEql(ga, gb)) break :blk false;
            }
            break :blk true;
        },
    };
}
