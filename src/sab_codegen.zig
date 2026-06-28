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
    stack_ty: ?*const ast.Type = null,
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
    constructor,
    function,
    method,
    fallible_method,
    index,
};

const StdSurfaceArgKind = enum {
    out,
    ok,
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
            .array => |arr| arraySize(arr),
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

    fn tupleFieldLayout(tuple: ast.TupleType, index: usize) ?FieldLayout {
        var offset: usize = 0;
        for (tuple.elems, 0..) |elem_ty, i| {
            const size = typeSize(elem_ty);
            offset = alignOffset(offset, size);
            if (i == index) return .{ .offset = offset, .ty = primType(elem_ty) catch return null };
            offset += size;
        }
        return null;
    }

    fn arrayStride(elem_ty: *const ast.Type) usize {
        return @max(typeSize(elem_ty), 1);
    }

    fn arraySize(arr: ast.ArrayType) usize {
        return @max(arrayStride(arr.elem) * arr.len, 1);
    }

    fn arrayElementLayout(arr: ast.ArrayType, index: usize) ?FieldLayout {
        if (index >= arr.len) return null;
        const stride = arrayStride(arr.elem);
        return .{ .offset = stride * index, .ty = primType(arr.elem) catch return null };
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
    };

    fn stdSurfaceArgText(self: *Codegen, kind: StdSurfaceArgKind, values: StdSurfaceValues) ![]const u8 {
        return switch (kind) {
            .out => self.symbols.items[values.out orelse return Error.UnsupportedSabDirectFeature],
            .ok => self.symbols.items[values.ok orelse return Error.UnsupportedSabDirectFeature],
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
            .identifier => |name| {
                if (self.tc.expr_types.get(node)) |expr_ty| {
                    if (typeBaseName(expr_ty)) |type_name| {
                        if (self.findStdSurfaceRule(.constructor, type_name, name)) |rule| try self.ensureRuleDeps(rule);
                    }
                }
            },
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

    fn pushStackLocal(self: *Codegen, name: []const u8, reg: u32, ty: *const ast.Type) !void {
        try self.recordReg(reg);
        try self.locals.append(.{ .name = name, .reg = reg, .is_param = false, .stack_ty = ty });
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
            if (local.stack_ty != null) continue;
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
        var item = self.makeInst(.assign);
        item.operands[0] = .{ .reg = dst };
        item.operands[1] = .{ .imm_float = value };
        try self.appendInst(item);
    }

    fn emitAssignReg(self: *Codegen, dst: u32, src: u32) !void {
        if (dst == src) return;
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
        var current = try self.allocator.dupe(u8, text);
        for (args, 0..) |arg, idx| {
            const placeholder = try self.stdMacroPlaceholder(idx);
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

    fn remapTemplateOperand(self: *Codegen, symbols: []const []const u8, operand: inst.Operand, args: []const []const u8) !inst.Operand {
        return switch (operand) {
            .reg => |old_id| .{ .reg = try self.remapTemplateSymbol(symbols, old_id, args) },
            .symbol => |old_id| .{ .symbol = try self.remapTemplateSymbol(symbols, old_id, args) },
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

    fn stdMacroTemplateSupportsArgs(self: *Codegen, template: *const StdMacroTemplate, args: []const []const u8) !bool {
        for (args, 0..) |arg, idx| {
            if (isStdMacroTemplateIdentArg(arg)) continue;
            const placeholder = try self.stdMacroPlaceholder(idx);
            defer self.allocator.free(placeholder);
            for (template.module.instructions) |item| {
                for (item.operands) |operand| {
                    const symbol_id = switch (operand) {
                        .reg, .symbol, .label, .func => |id| id,
                        else => continue,
                    };
                    const sym_idx: usize = @intCast(symbol_id);
                    if (sym_idx >= template.module.symbols.len) return Error.UnsupportedSabDirectFeature;
                    if (std.mem.eql(u8, template.module.symbols[sym_idx], placeholder)) return false;
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
        if (try self.emitCachedStdMacroFragment(import_path, macro_name, args)) return;

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

    fn genFuncDecl(self: *Codegen, f: *const ast.FuncDecl) !void {
        const old_locals = self.locals.items.len;
        defer self.popLocalsTo(old_locals);
        self.beginFunction();
        try self.collectBorrowedBindingsInBlock(f.body);
        var fsig = try self.genFuncSig(f.name, .normal, f.params, f.ret_ty, false, false);
        try self.appendDeclInst(fsig);
        try self.emitLabel("L_ENTRY");
        try self.materializeBorrowedParams(f.params);
        const ret_prim = try primType(f.ret_ty);
        if (ret_prim != .void and blockTailExpr(f.body) != null) {
            const tail = blockTailExpr(f.body).?;
            for (f.body[0 .. f.body.len - 1]) |stmt| {
                try self.genStmt(stmt);
                if (self.lastIsTerminator()) break;
            }
            if (!self.lastIsTerminator()) {
                const value = try self.genExpr(tail);
                try self.releaseOpenLocals(value);
                try self.emitReturn(value);
            }
        } else {
            try self.genBlock(f.body);
        }
        if (ret_prim == .void and !self.lastIsTerminator()) {
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
        try self.collectBorrowedBindingsInBlock(t.body);
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
            .var_stmt => |v| {
                const dst = try self.intern(v.name);
                try self.emitStackAlloc(dst, typeSize(v.ty));
                try self.pushStackLocal(v.name, dst, v.ty);
            },
            .let_stmt => |let| {
                const dst = try self.intern(let.name);
                if (closureLiteralFromExpr(let.value)) |closure| {
                    try self.closure_bindings.put(let.name, closure);
                    try self.emitAssignImm(dst, 0);
                    try self.pushLocal(let.name, dst, false);
                    return;
                }
                const src = try self.genExpr(let.value);
                const let_ty = if (let.ty) |explicit_ty| explicit_ty else self.tc.expr_types.get(let.value) orelse return Error.MissingType;
                if (self.borrowed_bindings.contains(let.name) and isStackAddressableType(let_ty)) {
                    try self.emitStackAlloc(dst, typeSize(let_ty));
                    try self.emitStore(dst, 0, src, try primType(let_ty));
                    if (!self.isLocalReg(src)) try self.emitRelease(src);
                    try self.pushStackLocal(let.name, dst, let_ty);
                    return;
                }
                if (let.value.* == .borrow_expr) {
                    try self.pushLocal(let.name, src, false);
                    return;
                }
                try self.emitAssignReg(dst, src);
                try self.pushLocal(let.name, dst, false);
            },
            .let_destructure_stmt => |let| try self.genLetDestructure(let),
            .assign_stmt => |assign| try self.genAssign(assign),
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
                try self.pushLocal(name, dst, false);
            }
        }
        if (!self.isLocalReg(value)) try self.emitRelease(value);
    }

    fn genAssign(self: *Codegen, assign: ast.AssignStmt) anyerror!void {
        if (assign.target.* == .index_expr) {
            const idx = assign.target.index_expr;
            const target_ty = self.tc.expr_types.get(idx.target) orelse return Error.MissingType;
            if (target_ty.* != .array) return Error.UnsupportedSabDirectFeature;
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
                break :blk self.localReg(name) orelse try self.intern(name);
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

    fn genBorrow(self: *Codegen, borrow: ast.BorrowExpr) anyerror!u32 {
        const source = if (borrow.expr.* == .identifier) blk: {
            if (self.stackLocal(borrow.expr.identifier)) |slot| break :blk slot.reg;
            break :blk try self.genExpr(borrow.expr);
        } else try self.genExpr(borrow.expr);
        const dst = try self.intern(try self.newTmp());
        try self.emitBorrowReg(dst, source, "read");
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
            if (arg.* == .borrow_expr) try text.append('&');
            if (arg.* == .move_expr) try text.append('^');
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

        try self.emitLabel(body_label);
        if (!self.isLocalReg(cond)) try self.emitBranchRelease(cond);
        try self.genBlock(w.body);
        if (!self.lastIsTerminator()) try self.emitJmp(head_label);

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
        try self.emitLabel(then_label);
        if (!self.isLocalReg(cond)) try self.emitBranchRelease(cond);
        const then_terminated = try self.genBlockTailValueStore(ife.then_block, result_slot, result_ty);
        if (!then_terminated) try self.emitJmp(merge_label);
        try self.emitLabel(else_label);
        if (!self.isLocalReg(cond)) try self.emitBranchRelease(cond);
        const else_terminated = try self.genBlockTailValueStore(else_block, result_slot, result_ty);
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
        try self.emitLabel(then_label);
        if (!self.isLocalReg(cond)) try self.emitBranchRelease(cond);
        try self.genBlock(ife.then_block);
        const then_terminated = self.lastIsTerminator();
        if (!then_terminated) try self.emitJmp(merge_label);
        try self.emitLabel(else_label);
        if (!self.isLocalReg(cond)) try self.emitBranchRelease(cond);
        if (ife.else_block) |else_block| try self.genBlock(else_block);
        const else_terminated = self.lastIsTerminator();
        if (!else_terminated) try self.emitJmp(merge_label);
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
