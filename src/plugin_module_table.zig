const std = @import("std");
const ast = @import("ast.zig");
const parser_mod = @import("parser.zig");
const source_expand = @import("source_expand.zig");
const lowering_rules = @import("lowering_rules.zig");
const plugin_imports = @import("plugin_imports.zig");

const ResolvedImport = plugin_imports.ResolvedImport;
const ResolvedModuleImport = plugin_imports.ResolvedModuleImport;
const moduleNamespaceFromImportPath = plugin_imports.moduleNamespaceFromImportPath;
const moduleNamespaceMatchesImportPath = plugin_imports.moduleNamespaceMatchesImportPath;
const resolveImportFiles = plugin_imports.resolveImportFiles;
const splitImportedMangledSymbol = plugin_imports.splitImportedMangledSymbol;

pub const SlaModuleExports = struct {
    pub const FunctionSignature = struct {
        name: []const u8,
        params: []const ast.Param,
        ret_ty: *ast.Type,
        is_pub: bool,
        is_extern: bool,
        abi: ?[]const u8,
        no_mangle: bool,
        is_async: bool,
        module_path: []const u8,
    };

    pub const TypeKind = enum { struct_decl, enum_decl, trait_decl, type_alias_decl };

    pub const TypeSignature = struct {
        name: []const u8,
        kind: TypeKind,
        generics: []const []const u8,
        module_path: []const u8,
    };

    pub const ConstSignature = struct {
        name: []const u8,
        ty: ?*ast.Type,
        module_path: []const u8,
    };

    pub const MacroSignature = struct {
        name: []const u8,
        params: []const []const u8,
        module_path: []const u8,
    };

    allocator: std.mem.Allocator,
    module_path: []const u8,
    type_decls: std.StringHashMap(*ast.Node),
    type_signatures: std.StringHashMap(TypeSignature),
    function_decls: std.StringHashMap(*ast.Node),
    function_signatures: std.StringHashMap(FunctionSignature),
    associated_function_decls: std.StringHashMap(*ast.Node),
    associated_function_signatures: std.StringHashMap(FunctionSignature),
    const_decls: std.StringHashMap(*ast.Node),
    const_signatures: std.StringHashMap(ConstSignature),
    macro_decls: std.StringHashMap(*ast.Node),
    macro_signatures: std.StringHashMap(MacroSignature),
    impl_decls: std.ArrayList(*ast.Node),
    trait_impl_decls: std.ArrayList(*ast.Node),

    pub fn init(allocator: std.mem.Allocator, module_path: []const u8) SlaModuleExports {
        return .{
            .allocator = allocator,
            .module_path = module_path,
            .type_decls = std.StringHashMap(*ast.Node).init(allocator),
            .type_signatures = std.StringHashMap(TypeSignature).init(allocator),
            .function_decls = std.StringHashMap(*ast.Node).init(allocator),
            .function_signatures = std.StringHashMap(FunctionSignature).init(allocator),
            .associated_function_decls = std.StringHashMap(*ast.Node).init(allocator),
            .associated_function_signatures = std.StringHashMap(FunctionSignature).init(allocator),
            .const_decls = std.StringHashMap(*ast.Node).init(allocator),
            .const_signatures = std.StringHashMap(ConstSignature).init(allocator),
            .macro_decls = std.StringHashMap(*ast.Node).init(allocator),
            .macro_signatures = std.StringHashMap(MacroSignature).init(allocator),
            .impl_decls = std.ArrayList(*ast.Node).init(allocator),
            .trait_impl_decls = std.ArrayList(*ast.Node).init(allocator),
        };
    }

    pub fn deinit(self: *SlaModuleExports) void {
        self.trait_impl_decls.deinit();
        self.impl_decls.deinit();
        self.macro_signatures.deinit();
        self.macro_decls.deinit();
        self.const_signatures.deinit();
        self.const_decls.deinit();
        var associated_key_iter = self.associated_function_decls.keyIterator();
        while (associated_key_iter.next()) |key_ptr| self.allocator.free(key_ptr.*);
        self.associated_function_signatures.deinit();
        self.associated_function_decls.deinit();
        self.function_signatures.deinit();
        self.function_decls.deinit();
        self.type_signatures.deinit();
        self.type_decls.deinit();
    }

    pub fn addDecl(table: *std.StringHashMap(*ast.Node), name: []const u8, decl: *ast.Node) !void {
        try table.put(name, decl);
    }

    pub fn addFunctionSignature(self: *SlaModuleExports, fd: *ast.FuncDecl) !void {
        try self.addFunctionSignatureNamed(&self.function_signatures, fd.name, fd);
    }

    pub fn addFunctionSignatureNamed(self: *SlaModuleExports, table: *std.StringHashMap(FunctionSignature), name: []const u8, fd: *ast.FuncDecl) !void {
        try table.put(name, .{
            .name = name,
            .params = fd.params,
            .ret_ty = fd.ret_ty,
            .is_pub = fd.is_pub,
            .is_extern = fd.is_extern,
            .abi = fd.abi,
            .no_mangle = fd.no_mangle,
            .is_async = fd.is_async,
            .module_path = self.module_path,
        });
    }

    pub fn addAssociatedFunctionDecl(self: *SlaModuleExports, symbol: []const u8, decl: *ast.Node) !void {
        try self.associated_function_decls.put(symbol, decl);
        try self.addFunctionSignatureNamed(&self.associated_function_signatures, symbol, &decl.func_decl);
    }

    pub fn addTypeSignature(self: *SlaModuleExports, name: []const u8, kind: TypeKind, generics: []const []const u8) !void {
        try self.type_signatures.put(name, .{
            .name = name,
            .kind = kind,
            .generics = generics,
            .module_path = self.module_path,
        });
    }

    pub fn addConstSignature(self: *SlaModuleExports, c: *ast.ConstStmt) !void {
        try self.const_signatures.put(c.name, .{
            .name = c.name,
            .ty = c.ty,
            .module_path = self.module_path,
        });
    }

    pub fn addMacroSignature(self: *SlaModuleExports, m: *ast.MacroDecl) !void {
        try self.macro_signatures.put(m.name, .{
            .name = m.name,
            .params = m.params,
            .module_path = self.module_path,
        });
    }

    pub fn buildFromDecls(self: *SlaModuleExports, decls: []const *ast.Node) !void {
        for (decls) |decl| {
            switch (decl.*) {
                .struct_decl => |s| {
                    try addDecl(&self.type_decls, s.name, decl);
                    try self.addTypeSignature(s.name, .struct_decl, s.generics);
                },
                .enum_decl => |e| {
                    try addDecl(&self.type_decls, e.name, decl);
                    try self.addTypeSignature(e.name, .enum_decl, e.generics);
                },
                .trait_decl => |t| {
                    try addDecl(&self.type_decls, t.name, decl);
                    try self.addTypeSignature(t.name, .trait_decl, &.{});
                },
                .type_alias_decl => |a| {
                    try addDecl(&self.type_decls, a.name, decl);
                    try self.addTypeSignature(a.name, .type_alias_decl, &.{});
                },
                .func_decl => |f| {
                    try addDecl(&self.function_decls, f.name, decl);
                    try self.addFunctionSignature(&decl.func_decl);
                },
                .const_stmt => |c| {
                    try addDecl(&self.const_decls, c.name, decl);
                    try self.addConstSignature(&decl.const_stmt);
                },
                .macro_decl => |m| {
                    try addDecl(&self.macro_decls, m.name, decl);
                    try self.addMacroSignature(&decl.macro_decl);
                },
                .impl_decl => |impl| {
                    try self.impl_decls.append(decl);
                    if (impl.trait_name != null) try self.trait_impl_decls.append(decl);
                    const type_name = lowering_rules.concreteTypeName(impl.target_ty) orelse continue;
                    for (impl.methods) |method| {
                        if (method.* != .func_decl) continue;
                        const symbol = if (impl.trait_name) |trait_name|
                            try lowering_rules.mangleTraitMethodName(self.allocator, type_name, trait_name, method.func_decl.name)
                        else
                            try lowering_rules.mangleMethodName(self.allocator, type_name, method.func_decl.name);
                        try self.addAssociatedFunctionDecl(symbol, method);
                    }
                },
                .overload_decl => |overload| {
                    const type_name = lowering_rules.concreteTypeName(overload.target_ty) orelse continue;
                    for (overload.methods) |method| {
                        if (method.* != .func_decl) continue;
                        const symbol = try lowering_rules.mangleMethodName(self.allocator, type_name, method.func_decl.name);
                        try self.addAssociatedFunctionDecl(symbol, method);
                    }
                },
                else => {},
            }
        }
    }

    pub fn exportsType(self: *const SlaModuleExports, name: []const u8) bool {
        return self.type_decls.contains(name);
    }
    pub fn typeSignature(self: *const SlaModuleExports, name: []const u8) ?TypeSignature {
        return self.type_signatures.get(name);
    }
    pub fn exportsFunction(self: *const SlaModuleExports, name: []const u8) bool {
        return self.function_decls.contains(name);
    }
    pub fn functionSignature(self: *const SlaModuleExports, name: []const u8) ?FunctionSignature {
        return self.function_signatures.get(name) orelse self.associated_function_signatures.get(name);
    }
    pub fn exportsConst(self: *const SlaModuleExports, name: []const u8) bool {
        return self.const_decls.contains(name);
    }
    pub fn constSignature(self: *const SlaModuleExports, name: []const u8) ?ConstSignature {
        return self.const_signatures.get(name);
    }
    pub fn exportsMacro(self: *const SlaModuleExports, name: []const u8) bool {
        return self.macro_decls.contains(name);
    }
    pub fn macroSignature(self: *const SlaModuleExports, name: []const u8) ?MacroSignature {
        return self.macro_signatures.get(name);
    }
    pub fn exportsSymbol(self: *const SlaModuleExports, name: []const u8) bool {
        if (self.function_decls.contains(name)) return true;
        if (self.associated_function_decls.contains(name)) return true;
        if (self.const_decls.contains(name)) return true;
        if (self.macro_decls.contains(name)) return true;

        var type_iter = self.type_decls.keyIterator();
        while (type_iter.next()) |type_name_ptr| {
            const type_name = type_name_ptr.*;
            if (std.mem.startsWith(u8, name, type_name)) {
                if (name.len > type_name.len and (name[type_name.len] == '_' or name[type_name.len] == '|')) {
                    return true;
                }
            }
            if (std.mem.indexOf(u8, name, type_name)) |idx| {
                if (idx > 0 and name[idx - 1] == '_') {
                    return true;
                }
            }
        }
        return false;
    }
};

pub const SlaModule = struct {
    path: []const u8,
    output_path: []const u8,
    base_dir: []const u8,
    source: []const u8,
    expanded_source: []const u8,
    known_types: []const []const u8,
    known_enums: []const []const u8,
    program: *ast.Node,
    exports: SlaModuleExports,
    resolved_imports: []const ResolvedImport,
    resolved_module_imports: []const ResolvedModuleImport,
    has_function_bodies: bool,
    has_macro_bodies: bool,
    parsed_function_bodies: std.StringHashMap(void),
    parsed_macro_bodies: std.StringHashMap(void),
};

pub const SlaImportExpansionOptions = struct {
    prune_for_test_codegen: bool = false,
    test_filter: ?[]const u8 = null,
    imported_bodies_decl_only: bool = false,
    load_reachable_imported_bodies_from_registry: bool = false,
    lazy_transitive_sla_imports: bool = false,
};

pub const SlaResolvedImportGroup = struct {
    decl: *const ast.Node,
    imports: []const ResolvedImport,
};

pub const SlaModuleReparseStats = struct {
    parse_ns: i128 = 0,
    exports_ns: i128 = 0,
    commit_ns: i128 = 0,
};

pub const SlaModuleTable = struct {
    allocator: std.mem.Allocator,
    modules: std.StringHashMap(*SlaModule),
    parse_options: parser_mod.Parser.Options,

    pub fn init(allocator: std.mem.Allocator) SlaModuleTable {
        return initWithParserOptions(allocator, .{
            .parse_test_bodies = false,
        });
    }

    pub fn initWithParserOptions(allocator: std.mem.Allocator, parse_options: parser_mod.Parser.Options) SlaModuleTable {
        return .{
            .allocator = allocator,
            .modules = std.StringHashMap(*SlaModule).init(allocator),
            .parse_options = parse_options,
        };
    }

    pub fn deinit(self: *SlaModuleTable) void {
        var module_iter = self.modules.valueIterator();
        while (module_iter.next()) |module_ptr| {
            const module = module_ptr.*;
            for (module.resolved_module_imports) |resolved_import| {
                self.allocator.free(resolved_import.namespace);
            }
            self.allocator.free(module.resolved_module_imports);
            self.allocator.free(module.resolved_imports);
            self.allocator.free(module.known_enums);
            self.allocator.free(module.known_types);
            module.parsed_macro_bodies.deinit();
            module.parsed_function_bodies.deinit();
            module.exports.deinit();
            self.allocator.destroy(module);
        }
        self.modules.deinit();
    }

    pub fn buildModuleImportNamespaces(self: *SlaModuleTable, resolved_imports: []const ResolvedImport) ![]const ResolvedModuleImport {
        var imports = std.ArrayList(ResolvedModuleImport).init(self.allocator);
        for (resolved_imports) |resolved| {
            if (!std.mem.endsWith(u8, resolved.path, ".sla")) continue;
            try imports.append(.{
                .namespace = try moduleNamespaceFromImportPath(self.allocator, resolved.output_path),
                .resolved = resolved,
            });
        }
        return try imports.toOwnedSlice();
    }

    pub fn resolveModuleImports(self: *SlaModuleTable, module_path: []const u8, base_dir: []const u8, decls: []const *ast.Node) ![]const ResolvedImport {
        var imports = std.ArrayList(ResolvedImport).init(self.allocator);
        for (decls) |decl| {
            if (decl.* != .import_decl) continue;
            const resolved = try resolveImportFiles(self.allocator, base_dir, decl.import_decl.path, module_path);
            try imports.appendSlice(resolved);
        }
        return try imports.toOwnedSlice();
    }

    pub fn getOrParse(self: *SlaModuleTable, resolved: ResolvedImport) !*SlaModule {
        if (self.modules.get(resolved.path)) |module| return module;

        const base_dir = std.fs.path.dirname(resolved.path) orelse ".";
        const expanded_source = try source_expand.expand(self.allocator, resolved.source);
        var parser = parser_mod.Parser.initWithDirAndOptions(self.allocator, expanded_source, base_dir, self.parse_options);
        const parsed = try parser.parseProgram();
        if (parsed.* != .program) return error.InvalidProgram;

        var exports = SlaModuleExports.init(self.allocator, resolved.path);
        try exports.buildFromDecls(parsed.program.decls);
        const resolved_imports = try self.resolveModuleImports(resolved.path, base_dir, parsed.program.decls);
        const resolved_module_imports = try self.buildModuleImportNamespaces(resolved_imports);

        const module = try self.allocator.create(SlaModule);
        module.* = .{
            .path = resolved.path,
            .output_path = resolved.output_path,
            .base_dir = base_dir,
            .source = resolved.source,
            .expanded_source = expanded_source,
            .known_types = try self.allocator.dupe([]const u8, parser.knownTypeNames()),
            .known_enums = try self.allocator.dupe([]const u8, parser.knownEnumNames()),
            .program = parsed,
            .exports = exports,
            .resolved_imports = resolved_imports,
            .resolved_module_imports = resolved_module_imports,
            .has_function_bodies = self.parse_options.parse_function_bodies and self.parse_options.function_body_names == null,
            .has_macro_bodies = self.parse_options.parse_macro_bodies and self.parse_options.macro_body_names == null,
            .parsed_function_bodies = std.StringHashMap(void).init(self.allocator),
            .parsed_macro_bodies = std.StringHashMap(void).init(self.allocator),
        };
        if (self.parse_options.parse_function_bodies) {
            if (self.parse_options.function_body_names) |selected| {
                var selected_iter = selected.keyIterator();
                while (selected_iter.next()) |name_ptr| try module.parsed_function_bodies.put(name_ptr.*, {});
            }
        }
        if (self.parse_options.parse_macro_bodies) {
            if (self.parse_options.macro_body_names) |selected| {
                var selected_iter = selected.keyIterator();
                while (selected_iter.next()) |name_ptr| try module.parsed_macro_bodies.put(name_ptr.*, {});
            }
        }
        try self.modules.put(module.path, module);
        return module;
    }

    pub fn reparseModuleWithSelectedBodies(
        self: *SlaModuleTable,
        module: *SlaModule,
        selected_function_bodies: ?*const std.StringHashMap(void),
        selected_macro_bodies: ?*const std.StringHashMap(void),
    ) !SlaModuleReparseStats {
        if (module.has_function_bodies and module.has_macro_bodies) return .{};

        const parse_start = std.time.nanoTimestamp();
        var parser = parser_mod.Parser.initWithDirAndOptions(self.allocator, module.expanded_source, module.base_dir, .{
            .parse_function_bodies = true,
            .function_body_names = selected_function_bodies,
            .parse_macro_bodies = true,
            .macro_body_names = selected_macro_bodies,
            .parse_test_bodies = self.parse_options.parse_test_bodies,
            .prescan_sla_import_types = false,
        });
        try parser.seedKnownTypeNames(module.known_types, module.known_enums);
        const parsed = try parser.parseProgram();
        if (parsed.* != .program) return error.InvalidProgram;
        const parse_ns = std.time.nanoTimestamp() - parse_start;

        const exports_start = std.time.nanoTimestamp();
        var exports = SlaModuleExports.init(self.allocator, module.path);
        try exports.buildFromDecls(parsed.program.decls);
        const exports_ns = std.time.nanoTimestamp() - exports_start;

        const commit_start = std.time.nanoTimestamp();
        // Record the selected body-name sets into the module's persistent
        // tracking maps BEFORE freeing the old exports. Some selected names
        // (mangled method symbols such as `Type_method`) are strings owned by
        // the old `module.exports` and would be freed by `module.exports.deinit()`
        // below; storing the borrowed pointers directly would leave
        // `parsed_function_bodies` holding dangling keys, so the materialize
        // fixpoint's `stringSetsEqual` comparison would read corrupted memory,
        // never converge, and reparse unboundedly (OOM). Duping into
        // `self.allocator`-owned copies keeps the tracking keys valid and stable.
        module.parsed_function_bodies.clearRetainingCapacity();
        if (selected_function_bodies) |selected| {
            var selected_iter = selected.keyIterator();
            while (selected_iter.next()) |name_ptr| {
                const owned = try self.allocator.dupe(u8, name_ptr.*);
                try module.parsed_function_bodies.put(owned, {});
            }
        }
        module.parsed_macro_bodies.clearRetainingCapacity();
        if (selected_macro_bodies) |selected| {
            var selected_iter = selected.keyIterator();
            while (selected_iter.next()) |name_ptr| {
                const owned = try self.allocator.dupe(u8, name_ptr.*);
                try module.parsed_macro_bodies.put(owned, {});
            }
        }

        module.exports.deinit();
        module.program = parsed;
        module.exports = exports;
        module.has_function_bodies = selected_function_bodies == null;
        module.has_macro_bodies = selected_macro_bodies == null;
        return .{
            .parse_ns = parse_ns,
            .exports_ns = exports_ns,
            .commit_ns = std.time.nanoTimestamp() - commit_start,
        };
    }

    pub fn moduleImportByNamespace(self: *const SlaModuleTable, module_path: []const u8, namespace: []const u8) ?ResolvedModuleImport {
        const module = self.modules.get(module_path) orelse return null;
        for (module.resolved_module_imports) |resolved_import| {
            if (std.mem.eql(u8, resolved_import.namespace, namespace)) return resolved_import;
        }
        return null;
    }

    pub fn exportsForModule(self: *const SlaModuleTable, module_path: []const u8) ?*const SlaModuleExports {
        const module = self.modules.get(module_path) orelse return null;
        return &module.exports;
    }

    pub fn functionSignature(self: *const SlaModuleTable, module_path: []const u8, name: []const u8) ?SlaModuleExports.FunctionSignature {
        const exports = self.exportsForModule(module_path) orelse return null;
        return exports.functionSignature(name);
    }

    pub fn functionBody(self: *const SlaModuleTable, module_path: []const u8, name: []const u8) ?*ast.FuncDecl {
        const exports = self.exportsForModule(module_path) orelse return null;
        const decl = exports.function_decls.get(name) orelse return null;
        if (decl.* != .func_decl) return null;
        return &decl.func_decl;
    }

    pub fn associatedFunctionBody(self: *const SlaModuleTable, module_path: []const u8, symbol: []const u8) ?*ast.FuncDecl {
        const module = self.modules.get(module_path) orelse return null;
        const decl = module.exports.associated_function_decls.get(symbol) orelse return null;
        if (decl.* != .func_decl) return null;
        return &decl.func_decl;
    }

    pub fn typeSignature(self: *const SlaModuleTable, module_path: []const u8, name: []const u8) ?SlaModuleExports.TypeSignature {
        const exports = self.exportsForModule(module_path) orelse return null;
        return exports.typeSignature(name);
    }

    pub fn constSignature(self: *const SlaModuleTable, module_path: []const u8, name: []const u8) ?SlaModuleExports.ConstSignature {
        const exports = self.exportsForModule(module_path) orelse return null;
        return exports.constSignature(name);
    }

    pub fn macroSignature(self: *const SlaModuleTable, module_path: []const u8, name: []const u8) ?SlaModuleExports.MacroSignature {
        const exports = self.exportsForModule(module_path) orelse return null;
        return exports.macroSignature(name);
    }

    pub fn functionSignatureForImportNamespace(self: *SlaModuleTable, module_path: []const u8, namespace: []const u8, name: []const u8) !?SlaModuleExports.FunctionSignature {
        const resolved_import = self.moduleImportByNamespace(module_path, namespace) orelse return null;
        _ = try self.getOrParse(resolved_import.resolved);
        return self.functionSignature(resolved_import.resolved.path, name);
    }

    pub fn functionBodyForImportNamespace(self: *SlaModuleTable, module_path: []const u8, namespace: []const u8, name: []const u8) !?*ast.FuncDecl {
        const resolved_import = self.moduleImportByNamespace(module_path, namespace) orelse return null;
        _ = try self.getOrParse(resolved_import.resolved);
        return self.functionBody(resolved_import.resolved.path, name) orelse self.associatedFunctionBody(resolved_import.resolved.path, name);
    }

    pub fn typeSignatureForImportNamespace(self: *SlaModuleTable, module_path: []const u8, namespace: []const u8, name: []const u8) !?SlaModuleExports.TypeSignature {
        const resolved_import = self.moduleImportByNamespace(module_path, namespace) orelse return null;
        _ = try self.getOrParse(resolved_import.resolved);
        return self.typeSignature(resolved_import.resolved.path, name);
    }

    pub fn constSignatureForImportNamespace(self: *SlaModuleTable, module_path: []const u8, namespace: []const u8, name: []const u8) !?SlaModuleExports.ConstSignature {
        const resolved_import = self.moduleImportByNamespace(module_path, namespace) orelse return null;
        _ = try self.getOrParse(resolved_import.resolved);
        return self.constSignature(resolved_import.resolved.path, name);
    }

    pub fn macroSignatureForImportNamespace(self: *SlaModuleTable, module_path: []const u8, namespace: []const u8, name: []const u8) !?SlaModuleExports.MacroSignature {
        const resolved_import = self.moduleImportByNamespace(module_path, namespace) orelse return null;
        _ = try self.getOrParse(resolved_import.resolved);
        return self.macroSignature(resolved_import.resolved.path, name);
    }

    pub fn functionSignatureForImportedMangledName(self: *SlaModuleTable, module_path: []const u8, symbol: []const u8) !?SlaModuleExports.FunctionSignature {
        const imported = splitImportedMangledSymbol(symbol) orelse return null;
        return try self.functionSignatureForImportNamespace(module_path, imported.namespace, imported.name);
    }

    pub fn functionBodyForImportedMangledName(self: *SlaModuleTable, module_path: []const u8, symbol: []const u8) !?*ast.FuncDecl {
        const imported = splitImportedMangledSymbol(symbol) orelse return null;
        return try self.functionBodyForImportNamespace(module_path, imported.namespace, imported.name);
    }

    pub fn functionSignatureForImportedMangledNameByNamespace(self: *const SlaModuleTable, symbol: []const u8) ?SlaModuleExports.FunctionSignature {
        const imported = splitImportedMangledSymbol(symbol) orelse return null;
        var module_iter = self.modules.valueIterator();
        while (module_iter.next()) |module_ptr| {
            const module = module_ptr.*;
            if (!moduleNamespaceMatchesImportPath(module.output_path, imported.namespace)) continue;
            if (module.exports.functionSignature(imported.name)) |signature| return signature;
        }
        return null;
    }
};
