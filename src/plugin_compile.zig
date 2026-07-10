const std = @import("std");
const ast = @import("ast.zig");
const parser_mod = @import("parser.zig");
const monomorphizer_mod = @import("monomorphizer.zig");
const type_checker_mod = @import("type_checker.zig");
const codegen_mod = @import("codegen.zig");
const sab_codegen_mod = @import("sab_codegen.zig");
const source_expand = @import("source_expand.zig");
const sla_workspace = @import("workspace.zig");
const lowering_rules = @import("lowering_rules.zig");
const sci_bridge = @import("sci_bridge");

const plugin_cli = @import("plugin_cli.zig");
const plugin_sab_paths = @import("plugin_sab_paths.zig");
const plugin_imports = @import("plugin_imports.zig");
const plugin_import_expand = @import("plugin_import_expand.zig");
const plugin_module_table = @import("plugin_module_table.zig");
const plugin_reachability = @import("plugin_reachability.zig");
const plugin_project_shortcuts = @import("plugin_project_shortcuts.zig");
const plugin_output_paths = @import("plugin_output_paths.zig");
const plugin_compile_options = @import("plugin_compile_options.zig");
const plugin_emit_reachability = @import("plugin_emit_reachability.zig");

const ResolvedImport = plugin_imports.ResolvedImport;
const SlaCliOptions = plugin_cli.SlaCliOptions;
const saTestFilterFromArgs = plugin_cli.saTestFilterFromArgs;
const defaultOutputPath = plugin_sab_paths.defaultOutputPath;
const managedSabTestPath = plugin_sab_paths.managedSabTestPath;
const writeSabFile = plugin_sab_paths.writeSabFile;
const virtualSaPathForSabOutput = plugin_sab_paths.virtualSaPathForSabOutput;
const sabSaStdRoot = plugin_sab_paths.sabSaStdRoot;
const sabProjectRoot = plugin_sab_paths.sabProjectRoot;
const SlaModuleTable = plugin_module_table.SlaModuleTable;
const SlaResolvedImportGroup = plugin_module_table.SlaResolvedImportGroup;
const ReachabilityAnalysis = plugin_reachability.ReachabilityAnalysis;
const SlaCallableIndex = plugin_reachability.SlaCallableIndex;
const collectSyntacticReachableBlock = plugin_reachability.collectSyntacticReachableBlock;
const collectSyntacticReachableExpr = plugin_reachability.collectSyntacticReachableExpr;
const pruneKnownFalseBranchesInReachableDecls = plugin_reachability.pruneKnownFalseBranchesInReachableDecls;
const recordReferencedType = plugin_reachability.recordReferencedType;
const scanReferencedSymbolRoots = plugin_reachability.scanReferencedSymbolRoots;
const testMatchesFilter = plugin_reachability.testMatchesFilter;
const expandSlaImports = plugin_import_expand.expandSlaImports;
const expandSlaImportsWithModuleTable = plugin_import_expand.expandSlaImportsWithModuleTable;
const loadImportedContractsFromResolvedImports = plugin_import_expand.loadImportedContractsFromResolvedImports;
const registerImportedFunctionAliasesFromResolvedImports = plugin_import_expand.registerImportedFunctionAliasesFromResolvedImports;
const isProjectShortcutRetainedHelperName = plugin_project_shortcuts.isProjectShortcutRetainedHelperName;
const rewriteProjectSnapshotTestShortcuts = plugin_project_shortcuts.rewriteProjectSnapshotTestShortcuts;
const rewriteProgramImportsForOutput = plugin_output_paths.rewriteProgramImportsForOutput;
const SlaCompileOptions = plugin_compile_options.SlaCompileOptions;
const defaultSlaCompileOptions = plugin_compile_options.defaultSlaCompileOptions;
const slaProfileEnabled = plugin_compile_options.slaProfileEnabled;
const slaProfileStage = plugin_compile_options.slaProfileStage;
const slaSabFallbackAllowed = plugin_compile_options.slaSabFallbackAllowed;
const collectNeededTraitImplsBlock = plugin_emit_reachability.collectNeededTraitImplsBlock;
const collectNeededTraitImplsExpr = plugin_emit_reachability.collectNeededTraitImplsExpr;
const collectReachableBlock = plugin_emit_reachability.collectReachableBlock;
const collectReachableExpr = plugin_emit_reachability.collectReachableExpr;

pub fn pruneTestsByFilter(allocator: std.mem.Allocator, program: *ast.Node, filter: ?[]const u8) !void {
    if (filter == null or filter.?.len == 0) return;
    if (program.* != .program) return error.InvalidProgram;

    var filtered_decls = std.ArrayList(*ast.Node).init(allocator);
    for (program.program.decls) |decl| {
        if (decl.* == .test_decl and !testMatchesFilter(&decl.test_decl, filter)) continue;
        try filtered_decls.append(decl);
    }
    program.program.decls = try filtered_decls.toOwnedSlice();
}

pub fn testFilterSelectsNoTests(
    allocator: std.mem.Allocator,
    file: []const u8,
    filter: ?[]const u8,
    stderr: std.io.AnyWriter,
) !?bool {
    const pattern = filter orelse return null;
    if (pattern.len == 0) return null;

    const content = std.fs.cwd().readFileAlloc(allocator, file, 10 * 1024 * 1024) catch |err| {
        try stderr.print("Error: failed to read file {s}: {}\n", .{ file, err });
        return null;
    };
    const expanded_content = source_expand.expand(allocator, content) catch |err| {
        try stderr.print("Macro Expansion Error: failed to expand tuple templates in {s}: {}\n", .{ file, err });
        return null;
    };

    const sla_base_dir = std.fs.path.dirname(file) orelse ".";
    var p = parser_mod.Parser.initWithDir(allocator, expanded_content, sla_base_dir);
    const prog = p.parseProgram() catch |err| {
        try p.printDiagnostic(stderr, file, err);
        return null;
    };

    var primary_decls = std.AutoHashMap(*const ast.Node, void).init(allocator);
    const expanded_prog = expandSlaImports(allocator, prog, file, &primary_decls, .{}) catch |err| {
        try stderr.print("Import Error: failed to expand @import SLA sources: {}\n", .{err});
        return null;
    };

    for (expanded_prog.program.decls) |decl| {
        if (decl.* == .test_decl and testMatchesFilter(&decl.test_decl, pattern)) return false;
    }
    return true;
}

pub fn pruneUnreachableTestFunctionDeclsBeforeTypeCheck(
    allocator: std.mem.Allocator,
    program: *ast.Node,
    imported_macros: ?*const std.StringHashMap(type_checker_mod.ImportedMacro),
    primary_decls: ?*std.AutoHashMap(*const ast.Node, void),
    prune_known_branches: bool,
) !void {
    if (program.* != .program) return error.InvalidProgram;

    try rewriteProjectSnapshotTestShortcuts(allocator, program);

    var callable_index = SlaCallableIndex.init(allocator);
    defer callable_index.deinit();
    try callable_index.addDecls(program.program.decls);
    if (callable_index.names.count() == 0) return;

    var reachable = std.StringHashMap(void).init(allocator);
    defer reachable.deinit();
    var referenced_types = std.StringHashMap(void).init(allocator);
    defer referenced_types.deinit();
    var worklist = std.ArrayList([]const u8).init(allocator);
    defer worklist.deinit();
    var scanned_symbol_roots = std.StringHashMap(void).init(allocator);
    defer scanned_symbol_roots.deinit();
    var analysis = ReachabilityAnalysis.init(allocator, prune_known_branches);
    defer analysis.deinit();

    var saw_test = false;
    for (program.program.decls) |decl| {
        switch (decl.*) {
            .test_decl => |test_decl| {
                saw_test = true;
                try collectSyntacticReachableBlock(&callable_index, null, imported_macros, &analysis, null, &reachable, &referenced_types, &worklist, test_decl.body);
            },
            .const_stmt => |const_stmt| {
                if (const_stmt.ty) |ty| try recordReferencedType(&referenced_types, ty);
                try collectSyntacticReachableExpr(&callable_index, null, imported_macros, &analysis, null, &reachable, &referenced_types, &worklist, const_stmt.value);
            },
            .impl_decl => |impl_decl| {
                try recordReferencedType(&referenced_types, impl_decl.target_ty);
                if (impl_decl.trait_name) |tn| try referenced_types.put(tn, {});
                if (impl_decl.trait_name != null) {
                    for (impl_decl.methods) |method| {
                        if (method.* == .func_decl) {
                            const type_name = lowering_rules.concreteTypeName(impl_decl.target_ty) orelse continue;
                            const symbol = try lowering_rules.mangleTraitMethodName(allocator, type_name, impl_decl.trait_name.?, method.func_decl.name);
                            defer allocator.free(symbol);
                            try collectSyntacticReachableBlock(&callable_index, null, imported_macros, &analysis, symbol, &reachable, &referenced_types, &worklist, method.func_decl.body);
                        }
                    }
                }
            },
            .overload_decl => |overload_decl| {
                try recordReferencedType(&referenced_types, overload_decl.target_ty);
                for (overload_decl.methods) |method| {
                    if (method.* == .func_decl) {
                        const type_name = lowering_rules.concreteTypeName(overload_decl.target_ty) orelse continue;
                        const symbol = try lowering_rules.mangleMethodName(allocator, type_name, method.func_decl.name);
                        defer allocator.free(symbol);
                        try collectSyntacticReachableBlock(&callable_index, null, imported_macros, &analysis, symbol, &reachable, &referenced_types, &worklist, method.func_decl.body);
                    }
                }
            },
            else => {},
        }
    }
    if (!saw_test) return;

    var index: usize = 0;
    while (true) {
        while (index < worklist.items.len) : (index += 1) {
            const name = worklist.items[index];
            const fd = callable_index.decls.get(name) orelse continue;
            for (fd.params) |param| {
                try recordReferencedType(&referenced_types, param.ty);
            }
            try recordReferencedType(&referenced_types, fd.ret_ty);
            const prev_facts = analysis.current_facts;
            if (analysis.function_facts.get(name)) |entry| {
                analysis.current_facts = &entry.facts;
            } else {
                analysis.current_facts = null;
            }
            try collectSyntacticReachableBlock(&callable_index, null, imported_macros, &analysis, name, &reachable, &referenced_types, &worklist, fd.body);
            analysis.current_facts = prev_facts;
        }
        if (!try scanReferencedSymbolRoots(&callable_index, null, imported_macros, &analysis, &reachable, &referenced_types, &scanned_symbol_roots, &worklist)) break;
    }

    if (prune_known_branches) {
        try pruneKnownFalseBranchesInReachableDecls(allocator, program, &analysis, &reachable);
    }

    var filtered_decls = std.ArrayList(*ast.Node).init(allocator);
    for (program.program.decls) |decl| {
        switch (decl.*) {
            .func_decl => |func_decl| {
                if (func_decl.is_decl_only or reachable.contains(func_decl.name) or isProjectShortcutRetainedHelperName(func_decl.name)) {
                    try filtered_decls.append(decl);
                    if (primary_decls) |decls| try decls.put(decl, {});
                }
            },
            .impl_decl => |impl_decl| {
                if (impl_decl.trait_name != null) {
                    try filtered_decls.append(decl);
                    continue;
                }
                const type_name = lowering_rules.concreteTypeName(impl_decl.target_ty) orelse {
                    try filtered_decls.append(decl);
                    continue;
                };
                var methods = std.ArrayList(*ast.Node).init(allocator);
                for (impl_decl.methods) |method| {
                    if (method.* != .func_decl) {
                        try methods.append(method);
                        continue;
                    }
                    const symbol = if (impl_decl.trait_name) |trait_name|
                        try lowering_rules.mangleTraitMethodName(allocator, type_name, trait_name, method.func_decl.name)
                    else
                        try lowering_rules.mangleMethodName(allocator, type_name, method.func_decl.name);
                    if (method.func_decl.is_decl_only or reachable.contains(symbol)) try methods.append(method);
                }
                if (methods.items.len == impl_decl.methods.len) {
                    try filtered_decls.append(decl);
                } else if (methods.items.len > 0) {
                    const pruned = try allocator.create(ast.Node);
                    pruned.* = .{ .impl_decl = .{
                        .trait_name = impl_decl.trait_name,
                        .target_ty = impl_decl.target_ty,
                        .methods = try methods.toOwnedSlice(),
                    } };
                    try filtered_decls.append(pruned);
                }
            },
            .overload_decl => |overload_decl| {
                const type_name = lowering_rules.concreteTypeName(overload_decl.target_ty) orelse {
                    try filtered_decls.append(decl);
                    continue;
                };
                var methods = std.ArrayList(*ast.Node).init(allocator);
                for (overload_decl.methods) |method| {
                    if (method.* != .func_decl) {
                        try methods.append(method);
                        continue;
                    }
                    const symbol = try lowering_rules.mangleMethodName(allocator, type_name, method.func_decl.name);
                    if (method.func_decl.is_decl_only or reachable.contains(symbol)) try methods.append(method);
                }
                if (methods.items.len == overload_decl.methods.len) {
                    try filtered_decls.append(decl);
                } else if (methods.items.len > 0) {
                    const pruned = try allocator.create(ast.Node);
                    pruned.* = .{ .overload_decl = .{
                        .target_ty = overload_decl.target_ty,
                        .methods = try methods.toOwnedSlice(),
                    } };
                    try filtered_decls.append(pruned);
                }
            },
            .macro_decl => |macro_decl| {
                if (referenced_types.contains(macro_decl.name)) try filtered_decls.append(decl);
            },
            else => try filtered_decls.append(decl),
        }
    }
    program.program.decls = try filtered_decls.toOwnedSlice();
}

fn pruneUnreachableFilteredTestDecls(
    allocator: std.mem.Allocator,
    program: *ast.Node,
    tc: *const type_checker_mod.TypeChecker,
    test_filter: ?[]const u8,
    force: bool,
) !void {
    if (!force and (test_filter == null or test_filter.?.len == 0)) return;
    if (program.* != .program) return error.InvalidProgram;

    var reachable = std.StringHashMap(void).init(allocator);
    var worklist = std.ArrayList([]const u8).init(allocator);

    for (program.program.decls) |decl| {
        switch (decl.*) {
            .test_decl => |test_decl| try collectReachableBlock(tc, &reachable, &worklist, test_decl.body),
            .const_stmt => |const_stmt| try collectReachableExpr(tc, &reachable, &worklist, const_stmt.value),
            else => {},
        }
    }

    var index: usize = 0;
    while (index < worklist.items.len) : (index += 1) {
        const name = worklist.items[index];
        const func = tc.funcs.get(name) orelse continue;
        try collectReachableBlock(tc, &reachable, &worklist, func.body);
    }

    var needed_trait_impls = std.StringHashMap(void).init(allocator);
    for (program.program.decls) |decl| {
        switch (decl.*) {
            .test_decl => |test_decl| try collectNeededTraitImplsBlock(allocator, tc, &needed_trait_impls, test_decl.body),
            .const_stmt => |const_stmt| try collectNeededTraitImplsExpr(allocator, tc, &needed_trait_impls, const_stmt.value),
            .func_decl => |func_decl| {
                if (reachable.contains(func_decl.name)) try collectNeededTraitImplsBlock(allocator, tc, &needed_trait_impls, func_decl.body);
            },
            .impl_decl => |impl_decl| {
                const type_name = lowering_rules.concreteTypeName(impl_decl.target_ty) orelse continue;
                for (impl_decl.methods) |method| {
                    if (method.* != .func_decl) continue;
                    const symbol = if (impl_decl.trait_name) |trait_name|
                        try lowering_rules.mangleTraitMethodName(allocator, type_name, trait_name, method.func_decl.name)
                    else
                        try lowering_rules.mangleMethodName(allocator, type_name, method.func_decl.name);
                    if (reachable.contains(symbol)) try collectNeededTraitImplsBlock(allocator, tc, &needed_trait_impls, method.func_decl.body);
                }
            },
            .overload_decl => |overload_decl| {
                const type_name = lowering_rules.concreteTypeName(overload_decl.target_ty) orelse continue;
                for (overload_decl.methods) |method| {
                    if (method.* != .func_decl) continue;
                    const symbol = try lowering_rules.mangleMethodName(allocator, type_name, method.func_decl.name);
                    if (reachable.contains(symbol)) try collectNeededTraitImplsBlock(allocator, tc, &needed_trait_impls, method.func_decl.body);
                }
            },
            else => {},
        }
    }

    var filtered_decls = std.ArrayList(*ast.Node).init(allocator);
    for (program.program.decls) |decl| {
        switch (decl.*) {
            .func_decl => |func_decl| {
                if (func_decl.is_decl_only or reachable.contains(func_decl.name)) try filtered_decls.append(decl);
            },
            .impl_decl => |impl_decl| {
                if (impl_decl.trait_name != null) {
                    const type_name = lowering_rules.concreteTypeName(impl_decl.target_ty) orelse {
                        try filtered_decls.append(decl);
                        continue;
                    };
                    const key = try std.fmt.allocPrint(allocator, "{s}|{s}", .{ impl_decl.trait_name.?, type_name });
                    var keep_impl = needed_trait_impls.contains(key);
                    if (!keep_impl) {
                        for (impl_decl.methods) |method| {
                            if (method.* != .func_decl) continue;
                            const symbol = try lowering_rules.mangleTraitMethodName(allocator, type_name, impl_decl.trait_name.?, method.func_decl.name);
                            if (reachable.contains(symbol)) {
                                keep_impl = true;
                                break;
                            }
                        }
                    }
                    if (keep_impl) try filtered_decls.append(decl);
                    continue;
                }
                const type_name = lowering_rules.concreteTypeName(impl_decl.target_ty) orelse {
                    try filtered_decls.append(decl);
                    continue;
                };

                var methods = std.ArrayList(*ast.Node).init(allocator);
                for (impl_decl.methods) |method| {
                    if (method.* != .func_decl) {
                        try methods.append(method);
                        continue;
                    }
                    const symbol = try lowering_rules.mangleMethodName(allocator, type_name, method.func_decl.name);
                    if (method.func_decl.is_decl_only or reachable.contains(symbol)) try methods.append(method);
                }
                if (methods.items.len == impl_decl.methods.len) {
                    try filtered_decls.append(decl);
                } else if (methods.items.len > 0) {
                    const pruned = try allocator.create(ast.Node);
                    pruned.* = .{ .impl_decl = .{
                        .trait_name = null,
                        .target_ty = impl_decl.target_ty,
                        .methods = try methods.toOwnedSlice(),
                    } };
                    try filtered_decls.append(pruned);
                }
            },
            .overload_decl => |overload_decl| {
                const type_name = lowering_rules.concreteTypeName(overload_decl.target_ty) orelse {
                    try filtered_decls.append(decl);
                    continue;
                };
                var methods = std.ArrayList(*ast.Node).init(allocator);
                for (overload_decl.methods) |method| {
                    if (method.* != .func_decl) {
                        try methods.append(method);
                        continue;
                    }
                    const symbol = try lowering_rules.mangleMethodName(allocator, type_name, method.func_decl.name);
                    if (method.func_decl.is_decl_only or reachable.contains(symbol)) try methods.append(method);
                }
                if (methods.items.len == overload_decl.methods.len) {
                    try filtered_decls.append(decl);
                } else if (methods.items.len > 0) {
                    const pruned = try allocator.create(ast.Node);
                    pruned.* = .{ .overload_decl = .{
                        .target_ty = overload_decl.target_ty,
                        .methods = try methods.toOwnedSlice(),
                    } };
                    try filtered_decls.append(pruned);
                }
            },
            else => try filtered_decls.append(decl),
        }
    }
    program.program.decls = try filtered_decls.toOwnedSlice();
}

pub fn compileSlaToSaString(
    allocator: std.mem.Allocator,
    file: []const u8,
    output_file: ?[]const u8,
    stderr: std.io.AnyWriter,
) !?[]const u8 {
    return compileSlaToSaStringWithOptions(allocator, file, output_file, stderr, defaultSlaCompileOptions());
}

/// Shared SLA compilation front-end: the trunk of the Y shared by the SA-text
/// (`compileSlaToSaStringWithOptions`) and SAB (`compileSlaFileToSabWithOptions`)
/// tails. Runs the byte-identical pipeline: read -> source-expand -> parse ->
/// `@import`-expand -> test-filter -> monomorphize -> load-contracts -> type-check ->
/// primary-decl filter.
///
/// `mono` and `tc` are caller-owned: the caller must `init`/`deinit` them (and
/// keep them alive across its tail codegen, which reads back from them). On any
/// front-end failure the diagnostic is printed and `null` is returned. On success
/// the type-checked, primary-decl-filtered program is returned.
fn runSlaFrontend(
    allocator: std.mem.Allocator,
    file: []const u8,
    mono: *monomorphizer_mod.Monomorphizer,
    tc: *type_checker_mod.TypeChecker,
    options: SlaCompileOptions,
    stderr: std.io.AnyWriter,
    profile: bool,
) !?*ast.Node {
    var stage_start = std.time.nanoTimestamp();
    const content = std.fs.cwd().readFileAlloc(allocator, file, 10 * 1024 * 1024) catch |err| {
        try stderr.print("Error: failed to read file {s}: {}\n", .{ file, err });
        return null;
    };
    slaProfileStage(stderr, profile, "read source", stage_start);

    stage_start = std.time.nanoTimestamp();
    const expanded_content = source_expand.expand(allocator, content) catch |err| {
        try stderr.print("Macro Expansion Error: failed to expand tuple templates in {s}: {}\n", .{ file, err });
        return null;
    };
    slaProfileStage(stderr, profile, "source expand", stage_start);

    stage_start = std.time.nanoTimestamp();
    const sla_base_dir = std.fs.path.dirname(file) orelse ".";
    var p = parser_mod.Parser.initWithDir(allocator, expanded_content, sla_base_dir);
    const prog = p.parseProgram() catch |err| {
        try p.printDiagnostic(stderr, file, err);
        return null;
    };
    slaProfileStage(stderr, profile, "parse", stage_start);

    stage_start = std.time.nanoTimestamp();
    var primary_decls = std.AutoHashMap(*const ast.Node, void).init(allocator);
    var import_modules = if (options.load_reachable_imported_bodies_from_registry)
        SlaModuleTable.initWithParserOptions(allocator, .{
            .parse_function_bodies = false,
            .parse_macro_bodies = false,
            .parse_test_bodies = false,
        })
    else
        SlaModuleTable.init(allocator);
    defer import_modules.deinit();
    var root_import_groups = std.ArrayList(SlaResolvedImportGroup).init(allocator);
    defer root_import_groups.deinit();
    var contract_imports = std.ArrayList(ResolvedImport).init(allocator);
    defer contract_imports.deinit();
    const expanded_prog = expandSlaImportsWithModuleTable(allocator, prog, file, &primary_decls, .{
        .prune_for_test_codegen = options.prune_for_test_codegen,
        .test_filter = options.test_filter,
        .imported_bodies_decl_only = options.load_reachable_imported_bodies_from_registry,
        .load_reachable_imported_bodies_from_registry = options.load_reachable_imported_bodies_from_registry,
    }, &import_modules, &root_import_groups, &contract_imports) catch |err| {
        try stderr.print("Import Error: failed to expand @import SLA sources: {}\n", .{err});
        return null;
    };
    slaProfileStage(stderr, profile, "import expand", stage_start);

    stage_start = std.time.nanoTimestamp();
    pruneTestsByFilter(allocator, expanded_prog, options.test_filter) catch |err| {
        try stderr.print("Test Filter Error: failed to prune @test declarations: {}\n", .{err});
        return null;
    };
    slaProfileStage(stderr, profile, "test filter prune", stage_start);

    stage_start = std.time.nanoTimestamp();
    var specialized_primary_decls = std.AutoHashMap(*const ast.Node, void).init(allocator);
    const specialized_prog = mono.monomorphize(expanded_prog, &primary_decls, &specialized_primary_decls) catch |err| {
        if (err == error.TemplateNotFound) {
            if (mono.missingTemplateName()) |name| {
                try stderr.print("Monomorphization Error: failed to specialize generics: {}: {s}\n", .{ err, name });
            } else {
                try stderr.print("Monomorphization Error: failed to specialize generics: {}\n", .{err});
            }
        } else {
            try stderr.print("Monomorphization Error: failed to specialize generics: {}\n", .{err});
        }
        return null;
    };
    slaProfileStage(stderr, profile, "monomorphize", stage_start);

    stage_start = std.time.nanoTimestamp();
    loadImportedContractsFromResolvedImports(tc, allocator, contract_imports.items) catch |err| {
        try stderr.print("Import Error: failed to load @import contracts: {}\n", .{err});
        return null;
    };
    slaProfileStage(stderr, profile, "load contracts", stage_start);

    stage_start = std.time.nanoTimestamp();
    registerImportedFunctionAliasesFromResolvedImports(tc, allocator, root_import_groups.items, &import_modules) catch |err| {
        try stderr.print("Import Error: failed to register @import function aliases: {}\n", .{err});
        return null;
    };
    slaProfileStage(stderr, profile, "import aliases", stage_start);

    if (options.prune_for_test_codegen) {
        stage_start = std.time.nanoTimestamp();
        pruneUnreachableTestFunctionDeclsBeforeTypeCheck(allocator, specialized_prog, &tc.imported_macros, &specialized_primary_decls, true) catch |err| {
            try stderr.print("Test Filter Error: failed to prune unreachable functions before type checking: {}\n", .{err});
            return null;
        };
        slaProfileStage(stderr, profile, "pre-typecheck reachable decl filter", stage_start);
    }

    stage_start = std.time.nanoTimestamp();
    tc.checkProgram(specialized_prog) catch |err| {
        try stderr.print("Type Check Error: failed to verify types: {s} ({})\n", .{ tc.last_error, err });
        return null;
    };
    slaProfileStage(stderr, profile, "type check", stage_start);

    // Filter specialized_prog to only include primary declarations
    stage_start = std.time.nanoTimestamp();
    var filtered_decls = std.ArrayList(*ast.Node).init(allocator);
    for (specialized_prog.program.decls) |decl| {
        if (specialized_primary_decls.contains(decl)) {
            try filtered_decls.append(decl);
        }
    }
    specialized_prog.program.decls = try filtered_decls.toOwnedSlice();
    slaProfileStage(stderr, profile, "primary decl filter", stage_start);

    return specialized_prog;
}

pub fn compileSlaToSaStringWithOptions(
    allocator: std.mem.Allocator,
    file: []const u8,
    output_file: ?[]const u8,
    stderr: std.io.AnyWriter,
    options: SlaCompileOptions,
) !?[]const u8 {
    const profile = slaProfileEnabled(allocator);

    var mono = monomorphizer_mod.Monomorphizer.init(allocator);
    defer mono.deinit();
    var tc = type_checker_mod.TypeChecker.init(allocator);
    defer tc.deinit();

    const specialized_prog = (try runSlaFrontend(allocator, file, &mono, &tc, options, stderr, profile)) orelse return null;

    var stage_start = std.time.nanoTimestamp();
    rewriteProgramImportsForOutput(allocator, specialized_prog, file, output_file) catch |err| {
        try stderr.print("Import Error: failed to rewrite @import paths for output: {}\n", .{err});
        return null;
    };
    slaProfileStage(stderr, profile, "rewrite imports", stage_start);

    stage_start = std.time.nanoTimestamp();
    var cg = codegen_mod.Codegen.init(allocator, &tc);
    defer cg.deinit();

    const sa_code = cg.generate(specialized_prog) catch |err| {
        try stderr.print("Codegen Error: failed to generate SA code: {}\n", .{err});
        if (@errorReturnTrace()) |trace| std.debug.dumpStackTrace(trace.*);
        return null;
    };
    slaProfileStage(stderr, profile, "sa codegen", stage_start);
    return sa_code;
}

fn compileSlaFileToSa(
    allocator: std.mem.Allocator,
    file: []const u8,
    output_file: ?[]const u8,
    stderr: std.io.AnyWriter,
) !?[]const u8 {
    return compileSlaToSaString(allocator, file, output_file, stderr);
}

pub fn resolveWorkspaceSourcePath(
    allocator: std.mem.Allocator,
    stderr: std.io.AnyWriter,
    package_name: ?[]const u8,
) !?[]u8 {
    var resolution = sla_workspace.resolveFromCurrentDir(allocator, .{ .request = package_name }) catch |err| switch (err) {
        error.FileNotFound => {
            try stderr.writeAll("Error: missing file argument and no workspace source could be resolved from the current directory\n");
            return null;
        },
        error.UnknownPackage => {
            try stderr.print("Error: unknown workspace package: {s}\n", .{package_name orelse ""});
            return null;
        },
        error.MissingDefaultMember => {
            try stderr.writeAll("Error: workspace has no resolvable default member; pass -p/--package or run inside a member directory\n");
            return null;
        },
        error.InvalidFormat => {
            try stderr.writeAll("Error: failed to parse workspace sa.mod\n");
            return null;
        },
        else => return err,
    };
    defer resolution.deinit(allocator);

    return sla_workspace.selectedSourcePath(allocator, &resolution) catch |err| switch (err) {
        error.FileNotFound => {
            try stderr.writeAll("Error: workspace member has no src/main.sla or main.sla entry source\n");
            return null;
        },
        else => return err,
    };
}

pub fn resolveSlaInputFile(
    allocator: std.mem.Allocator,
    stderr: std.io.AnyWriter,
    options: SlaCliOptions,
) !?[]u8 {
    if (options.source_file) |file| {
        const duped = try allocator.dupe(u8, file);
        return duped;
    }
    return resolveWorkspaceSourcePath(allocator, stderr, options.package_name);
}

pub fn compileSlaFileToSab(
    allocator: std.mem.Allocator,
    file: []const u8,
    output_file: []const u8,
    stderr: std.io.AnyWriter,
) !?[]u8 {
    return compileSlaFileToSabWithOptions(allocator, file, output_file, stderr, defaultSlaCompileOptions());
}

fn encodeSaTextAsSab(
    allocator: std.mem.Allocator,
    source_file: []const u8,
    source_path: []const u8,
    sa_code: []const u8,
    stderr: std.io.AnyWriter,
    profile: bool,
) !?[]u8 {
    if (std.fs.path.dirname(source_path)) |dir| {
        std.fs.cwd().makePath(dir) catch |err| {
            try stderr.print("File Error: failed to create SAB work directory {s}: {}\n", .{ dir, err });
            return null;
        };
    }

    const project_root = sabProjectRoot(allocator, source_file) catch |err| {
        try stderr.print("SAB Error: failed to resolve project root for {s}: {}\n", .{ source_file, err });
        return null;
    };
    const std_root = sabSaStdRoot(allocator) catch |err| {
        try stderr.print("SAB Error: failed to resolve SA std root: {}\n", .{err});
        return null;
    };
    const resolve_ctx = sci_bridge.flattener.ResolveContext{ .options = .{ .project_root = project_root, .std_root = std_root } };

    var stage_start = std.time.nanoTimestamp();
    var flat = sci_bridge.flattener.flattenFileWithPackages(allocator, source_path, sa_code, resolve_ctx) catch |err| {
        try stderr.print("SAB Error: failed to flatten SA-compatible lowering {s}: {}\n", .{ source_path, err });
        return null;
    };
    defer flat.deinit(allocator);
    slaProfileStage(stderr, profile, "sa flatten", stage_start);

    stage_start = std.time.nanoTimestamp();
    const sab_bytes = sci_bridge.encodeSabFromFlat(allocator, &flat) catch |err| {
        try stderr.print("SAB Error: failed to encode SAB for {s}: {}\n", .{ source_path, err });
        return null;
    };
    slaProfileStage(stderr, profile, "sab encode", stage_start);
    return sab_bytes;
}

fn compileTypedSlaProgramToCompatibleSab(
    allocator: std.mem.Allocator,
    tc: *type_checker_mod.TypeChecker,
    program: *ast.Node,
    source_file: []const u8,
    output_file: []const u8,
    stderr: std.io.AnyWriter,
    profile: bool,
) !?[]u8 {
    const stage_start = std.time.nanoTimestamp();
    rewriteProgramImportsForOutput(allocator, program, source_file, output_file) catch |err| {
        try stderr.print("Import Error: failed to rewrite @import paths for SAB output: {}\n", .{err});
        return null;
    };

    var cg = codegen_mod.Codegen.init(allocator, tc);
    defer cg.deinit();
    const sa_code = cg.generate(program) catch |err| {
        try stderr.print("SAB Error: failed to lower SLA through SA-compatible SAB path: {}\n", .{err});
        return null;
    };
    slaProfileStage(stderr, profile, "sa-compatible codegen", stage_start);

    const virtual_sa_path = try virtualSaPathForSabOutput(allocator, output_file);
    return try encodeSaTextAsSab(allocator, source_file, virtual_sa_path, sa_code, stderr, profile);
}

pub fn compileSlaFileToSabWithOptions(
    allocator: std.mem.Allocator,
    file: []const u8,
    output_file: []const u8,
    stderr: std.io.AnyWriter,
    options: SlaCompileOptions,
) !?[]u8 {
    const profile = slaProfileEnabled(allocator);

    var mono = monomorphizer_mod.Monomorphizer.init(allocator);
    defer mono.deinit();
    var tc = type_checker_mod.TypeChecker.init(allocator);
    defer tc.deinit();

    const specialized_prog = (try runSlaFrontend(allocator, file, &mono, &tc, options, stderr, profile)) orelse return null;

    var stage_start = std.time.nanoTimestamp();
    if (options.prune_for_test_codegen) {
        pruneUnreachableTestFunctionDeclsBeforeTypeCheck(allocator, specialized_prog, &tc.imported_macros, null, true) catch |err| {
            try stderr.print("Test Filter Error: failed to prune syntactic unreachable declarations after type checking: {}\n", .{err});
            return null;
        };
    }
    slaProfileStage(stderr, profile, "post-typecheck syntactic reachable decl filter", stage_start);

    stage_start = std.time.nanoTimestamp();
    pruneUnreachableFilteredTestDecls(allocator, specialized_prog, &tc, options.test_filter, options.prune_for_test_codegen) catch |err| {
        try stderr.print("Test Filter Error: failed to prune unreachable declarations: {}\n", .{err});
        return null;
    };
    slaProfileStage(stderr, profile, "reachable decl filter", stage_start);

    stage_start = std.time.nanoTimestamp();
    const sab_bytes = sab_codegen_mod.generate(allocator, &tc, specialized_prog) catch |err| {
        slaProfileStage(stderr, profile, "sab direct codegen", stage_start);
        switch (err) {
            error.OutOfMemory => return err,
            else => {
                if (!slaSabFallbackAllowed(allocator, options)) {
                    try stderr.print("SAB Direct Error: direct SLA-to-SAB lowering failed without fallback: {}\n", .{err});
                    return null;
                }
                return try compileTypedSlaProgramToCompatibleSab(allocator, &tc, specialized_prog, file, output_file, stderr, profile);
            },
        }
    };
    slaProfileStage(stderr, profile, "sab direct codegen", stage_start);
    return sab_bytes;
}

pub fn compileSlaFileToSabOrSa(
    allocator: std.mem.Allocator,
    file: []const u8,
    output_file: []const u8,
    stderr: std.io.AnyWriter,
) !?[]u8 {
    return compileSlaFileToSab(allocator, file, output_file, stderr);
}

pub fn maybeWriteSiblingSab(
    allocator: std.mem.Allocator,
    file: []const u8,
    stderr: std.io.AnyWriter,
) !void {
    const sab_out = try defaultOutputPath(allocator, file, ".sla", ".sab");
    const sab_bytes = (try compileSlaFileToSabOrSa(allocator, file, sab_out, stderr)) orelse return error.InvalidFormat;
    try std.fs.cwd().writeFile(.{ .sub_path = sab_out, .data = sab_bytes });
}

pub const CompiledTestInput = struct {
    path: []const u8,
    delete_after: bool = false,
};

pub fn compileSlaSabTestInput(
    allocator: std.mem.Allocator,
    file: []const u8,
    stderr: std.io.AnyWriter,
    extra_args: []const []const u8,
    emit_sab_file: bool,
) !?CompiledTestInput {
    const sab_out = try managedSabTestPath(allocator, file, extra_args);
    const sab_bytes = (try compileSlaFileToSabWithOptions(allocator, file, sab_out, stderr, .{
        .test_filter = saTestFilterFromArgs(extra_args),
        .prune_for_test_codegen = true,
        .load_reachable_imported_bodies_from_registry = true,
    })) orelse return null;
    if (!try writeSabFile(allocator, sab_out, sab_bytes, stderr)) return null;
    if (emit_sab_file) {
        maybeWriteSiblingSab(allocator, file, stderr) catch |err| {
            try stderr.print("File Error: failed to emit sibling SAB for {s}: {}\n", .{ file, err });
            return null;
        };
    }
    return .{ .path = sab_out };
}

pub fn compileSlaSaTestInput(
    allocator: std.mem.Allocator,
    file: []const u8,
    stderr: std.io.AnyWriter,
    extra_args: []const []const u8,
    emit_sab_file: bool,
) !?CompiledTestInput {
    const sa_out = if (std.mem.endsWith(u8, file, ".sla"))
        try std.fmt.allocPrint(allocator, "{s}.test.sa", .{file[0 .. file.len - 4]})
    else
        try std.fmt.allocPrint(allocator, "{s}.test.sa", .{file});

    const sa_code = (try compileSlaToSaStringWithOptions(allocator, file, sa_out, stderr, .{
        .test_filter = saTestFilterFromArgs(extra_args),
        .prune_for_test_codegen = true,
        .load_reachable_imported_bodies_from_registry = true,
    })) orelse return null;

    std.fs.cwd().writeFile(.{ .sub_path = sa_out, .data = sa_code }) catch |err| {
        try stderr.print("File Error: failed to write {s}: {}\n", .{ sa_out, err });
        return null;
    };
    if (emit_sab_file) {
        maybeWriteSiblingSab(allocator, file, stderr) catch |err| {
            try stderr.print("File Error: failed to emit sibling SAB for {s}: {}\n", .{ file, err });
            return null;
        };
    }
    return .{ .path = sa_out, .delete_after = true };
}
