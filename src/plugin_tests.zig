// Auto-split from plugin.zig: all plugin-level unit tests + test helpers.
// Prelude replicates the facade's module imports and symbol aliases so the
// moved tests resolve exactly as they did in plugin.zig.

const std = @import("std");
const plugin_api = @import("plugin_api");
const ast = @import("ast.zig");
const parser_mod = @import("parser.zig");
const monomorphizer_mod = @import("monomorphizer.zig");
const type_checker_mod = @import("type_checker.zig");
const codegen_mod = @import("codegen.zig");
const sab_codegen_mod = @import("sab_codegen.zig");
const stability_metadata = @import("stability_metadata.zig");
const source_expand = @import("source_expand.zig");
const sla_workspace = @import("workspace.zig");
const lowering_rules = @import("lowering_rules.zig");
const control_flow_rules = @import("control_flow_rules.zig");
const sci_bridge = @import("sci_bridge");
pub const handler_bridge = @import("handler_bridge.zig");
const plugin_handler = @import("plugin_handler.zig");
const plugin_skills = @import("plugin_skills.zig");
const plugin_cli = @import("plugin_cli.zig");
const plugin_sab_paths = @import("plugin_sab_paths.zig");
const SlaHandlerStateFieldAbi = plugin_handler.SlaHandlerStateFieldAbi;
const SlaCompileHandlerOptionsAbi = plugin_handler.SlaCompileHandlerOptionsAbi;
const SlaCompileHandlerResultAbi = plugin_handler.SlaCompileHandlerResultAbi;
const sla_compile_handler = plugin_handler.sla_compile_handler;
const sla_compile_handler_result_free = plugin_handler.sla_compile_handler_result_free;
const TestBackend = plugin_cli.TestBackend;
const SlaCliOptions = plugin_cli.SlaCliOptions;
const isHelpArg = plugin_cli.isHelpArg;
const parseTestBackendFromArgs = plugin_cli.parseTestBackendFromArgs;
const appendSaTestPassthrough = plugin_cli.appendSaTestPassthrough;
const appendDefaultJobsAuto = plugin_cli.appendDefaultJobsAuto;
const runSlaSkillsCommand = plugin_cli.runSlaSkillsCommand;
const runSlaInitCommand = plugin_cli.runSlaInitCommand;
const runSlaStabilityCommand = plugin_cli.runSlaStabilityCommand;
const writeCommandHelp = plugin_cli.writeCommandHelp;
const parseSlaCliOptionsFrom = plugin_cli.parseSlaCliOptionsFrom;
const parseSlaCliOptions = plugin_cli.parseSlaCliOptions;
const saTestFilterFromArgs = plugin_cli.saTestFilterFromArgs;
const defaultOutputPath = plugin_sab_paths.defaultOutputPath;
const managedSabPath = plugin_sab_paths.managedSabPath;
const managedSabTestPath = plugin_sab_paths.managedSabTestPath;
const writeSabFile = plugin_sab_paths.writeSabFile;
const writeManagedSab = plugin_sab_paths.writeManagedSab;
const parseOutFileArg = plugin_sab_paths.parseOutFileArg;
const parseSabOutFileArg = plugin_sab_paths.parseSabOutFileArg;
const hasEmitSabArg = plugin_sab_paths.hasEmitSabArg;
const appendSabWorkspacePassthrough = plugin_sab_paths.appendSabWorkspacePassthrough;
const virtualSaPathForSabOutput = plugin_sab_paths.virtualSaPathForSabOutput;
const sabSaStdRoot = plugin_sab_paths.sabSaStdRoot;
const sabProjectRoot = plugin_sab_paths.sabProjectRoot;
const plugin_imports = @import("plugin_imports.zig");
const max_import_bytes = plugin_imports.max_import_bytes;
const ResolvedImport = plugin_imports.ResolvedImport;
const ResolvedModuleImport = plugin_imports.ResolvedModuleImport;
const moduleNamespaceFromImportPath = plugin_imports.moduleNamespaceFromImportPath;
const moduleNamespaceMatchesImportPath = plugin_imports.moduleNamespaceMatchesImportPath;
const ImportedMangledSymbol = plugin_imports.ImportedMangledSymbol;
const splitImportedMangledSymbol = plugin_imports.splitImportedMangledSymbol;
const stringSliceLessThan = plugin_imports.stringSliceLessThan;
const resolvedImportLessThan = plugin_imports.resolvedImportLessThan;
const isGlobImportPath = plugin_imports.isGlobImportPath;
const globNameMatches = plugin_imports.globNameMatches;
const isSaStdImport = plugin_imports.isSaStdImport;
const isSlaStdImport = plugin_imports.isSlaStdImport;
const readImportFileIfExistsWithOutputPath = plugin_imports.readImportFileIfExistsWithOutputPath;
const readImportFileIfExists = plugin_imports.readImportFileIfExists;
const readImportFromRoot = plugin_imports.readImportFromRoot;
const resolveSaStdImport = plugin_imports.resolveSaStdImport;
const resolveSlaStdImport = plugin_imports.resolveSlaStdImport;
const resolveImportFile = plugin_imports.resolveImportFile;
const appendResolvedImportFiles = plugin_imports.appendResolvedImportFiles;
const resolveImportFiles = plugin_imports.resolveImportFiles;
const importPathFromLine = plugin_imports.importPathFromLine;
const expandedSourceMayContainImports = plugin_imports.expandedSourceMayContainImports;
const plugin_import_expand = @import("plugin_import_expand.zig");
const appendModuleDeclsSelective = plugin_import_expand.appendModuleDeclsSelective;
const expandSlaImports = plugin_import_expand.expandSlaImports;
const expandSlaImportsWithModuleTable = plugin_import_expand.expandSlaImportsWithModuleTable;
const expandSlaImportsWithModuleTableUsingContractTypeChecker = plugin_import_expand.expandSlaImportsWithModuleTableUsingContractTypeChecker;
const loadImportedContracts = plugin_import_expand.loadImportedContracts;
const loadImportedContractsFromResolvedImports = plugin_import_expand.loadImportedContractsFromResolvedImports;
const registerImportedFunctionAliases = plugin_import_expand.registerImportedFunctionAliases;
const registerImportedFunctionAliasesFromResolvedImports = plugin_import_expand.registerImportedFunctionAliasesFromResolvedImports;
const plugin_imported_macros = @import("plugin_imported_macros.zig");
const expandedSourceMayContainImportedMacros = plugin_imported_macros.expandedSourceMayContainImportedMacros;
const macroParamName = plugin_imported_macros.macroParamName;
const isLeadingOutputMacroParam = plugin_imported_macros.isLeadingOutputMacroParam;
const macroParamIndex = plugin_imported_macros.macroParamIndex;
const markBorrowedParam = plugin_imported_macros.markBorrowedParam;
const markDirectBorrowedMacroParams = plugin_imported_macros.markDirectBorrowedMacroParams;
const markDirectAddressSlotMacroParams = plugin_imported_macros.markDirectAddressSlotMacroParams;
const markExpandedImportedMacroParamMasks = plugin_imported_macros.markExpandedImportedMacroParamMasks;
const importedMacroCalleeName = plugin_imported_macros.importedMacroCalleeName;
const appendUniqueDirectCallee = plugin_imported_macros.appendUniqueDirectCallee;
const collectDirectSlaMacroCallees = plugin_imported_macros.collectDirectSlaMacroCallees;
const appendExpandedImportedMacroDirectCallees = plugin_imported_macros.appendExpandedImportedMacroDirectCallees;
const loadImportedMacrosFromExpandedSource = plugin_imported_macros.loadImportedMacrosFromExpandedSource;
const loadImportedMacros = plugin_imported_macros.loadImportedMacros;
const plugin_module_table = @import("plugin_module_table.zig");
const SlaModuleExports = plugin_module_table.SlaModuleExports;
const SlaModule = plugin_module_table.SlaModule;
const SlaImportExpansionOptions = plugin_module_table.SlaImportExpansionOptions;
const SlaResolvedImportGroup = plugin_module_table.SlaResolvedImportGroup;
const SlaModuleTable = plugin_module_table.SlaModuleTable;
const plugin_reachability = @import("plugin_reachability.zig");
const SlaCallableIndex = plugin_reachability.SlaCallableIndex;
const SyntacticFactSet = plugin_reachability.SyntacticFactSet;
const fieldFactKeyMatchesName = plugin_reachability.fieldFactKeyMatchesName;
const FunctionSyntacticFacts = plugin_reachability.FunctionSyntacticFacts;
const ReachabilityAnalysis = plugin_reachability.ReachabilityAnalysis;
const ReachabilitySession = plugin_reachability.ReachabilitySession;
const literalHasNoImportKeyword = plugin_reachability.literalHasNoImportKeyword;
const nodeIsNoImportSource = plugin_reachability.nodeIsNoImportSource;
const nodeIsZeroImportScan = plugin_reachability.nodeIsZeroImportScan;
const evalSyntacticInt = plugin_reachability.evalSyntacticInt;
const evalSyntacticBool = plugin_reachability.evalSyntacticBool;
const buildCallFactsForDecl = plugin_reachability.buildCallFactsForDecl;
const syntacticFuncDeclForCall = plugin_reachability.syntacticFuncDeclForCall;
const moduleQualifiedCallableForCaller = plugin_reachability.moduleQualifiedCallableForCaller;
const syntacticFuncDeclForCallFromCaller = plugin_reachability.syntacticFuncDeclForCallFromCaller;
const singleReturnValue = plugin_reachability.singleReturnValue;
const recordKnownFieldsFromStructLiteral = plugin_reachability.recordKnownFieldsFromStructLiteral;
const recordKnownFieldsFromCall = plugin_reachability.recordKnownFieldsFromCall;
const recordKnownFieldsFromExpr = plugin_reachability.recordKnownFieldsFromExpr;
const syntacticConcreteTypeNameFromExpr = plugin_reachability.syntacticConcreteTypeNameFromExpr;
const updateFactsForLetBinding = plugin_reachability.updateFactsForLetBinding;
const pruneKnownFalseBranchesInBlock = plugin_reachability.pruneKnownFalseBranchesInBlock;
const pruneKnownFalseBranchesInExpr = plugin_reachability.pruneKnownFalseBranchesInExpr;
const reachabilityNodeBindsIdentifier = plugin_reachability.reachabilityNodeBindsIdentifier;
const reachabilityClosureShadowsIdentifier = plugin_reachability.reachabilityClosureShadowsIdentifier;
const reachabilityBlockUsesIdentifier = plugin_reachability.reachabilityBlockUsesIdentifier;
const reachabilityNodeUsesIdentifier = plugin_reachability.reachabilityNodeUsesIdentifier;
const pruneDeadZeroImportScanLetsInBlock = plugin_reachability.pruneDeadZeroImportScanLetsInBlock;
const plugin_project_shortcuts = @import("plugin_project_shortcuts.zig");
const rewriteProjectSnapshotTestShortcuts = plugin_project_shortcuts.rewriteProjectSnapshotTestShortcuts;
const isProjectShortcutRetainedHelperName = plugin_project_shortcuts.isProjectShortcutRetainedHelperName;
const pruneKnownFalseBranchesInReachableDecls = plugin_reachability.pruneKnownFalseBranchesInReachableDecls;
const scanReferencedSymbolRoots = plugin_reachability.scanReferencedSymbolRoots;
const scanReferencedExportedTypeSignatures = plugin_reachability.scanReferencedExportedTypeSignatures;
const buildReachableSymbols = plugin_reachability.buildReachableSymbols;
const buildAndMaterializeReachableImportedModuleBodies = plugin_reachability.buildAndMaterializeReachableImportedModuleBodies;
const collectReachableModuleBodyNames = plugin_reachability.collectReachableModuleBodyNames;
const materializeReachableImportedModuleBodies = plugin_reachability.materializeReachableImportedModuleBodies;
const testMatchesFilter = plugin_reachability.testMatchesFilter;
const recordReferencedType = plugin_reachability.recordReferencedType;
const markSyntacticReachableFunc = plugin_reachability.markSyntacticReachableFunc;
const collectSyntacticReachableExpr = plugin_reachability.collectSyntacticReachableExpr;
const collectSyntacticReachableBlock = plugin_reachability.collectSyntacticReachableBlock;
const plugin_output_paths = @import("plugin_output_paths.zig");
const rewriteProgramImportsForOutput = plugin_output_paths.rewriteProgramImportsForOutput;
const plugin_compile_options = @import("plugin_compile_options.zig");
const SlaCompileOptions = plugin_compile_options.SlaCompileOptions;
const defaultSlaCompileOptions = plugin_compile_options.defaultSlaCompileOptions;
const slaProfileEnabled = plugin_compile_options.slaProfileEnabled;
const slaSabFallbackAllowed = plugin_compile_options.slaSabFallbackAllowed;
const slaProfileStage = plugin_compile_options.slaProfileStage;
const writeEmptyTestResult = plugin_compile_options.writeEmptyTestResult;
const plugin_compile = @import("plugin_compile.zig");
const compileSlaFileToSab = plugin_compile.compileSlaFileToSab;
const compileSlaFileToSabOrSa = plugin_compile.compileSlaFileToSabOrSa;
const compileSlaFileToSabWithOptions = plugin_compile.compileSlaFileToSabWithOptions;
const compileSlaSaTestInput = plugin_compile.compileSlaSaTestInput;
const compileSlaSabTestInput = plugin_compile.compileSlaSabTestInput;
const compileSlaToSaString = plugin_compile.compileSlaToSaString;
const compileSlaToSaStringWithOptions = plugin_compile.compileSlaToSaStringWithOptions;
const maybeWriteSiblingSab = plugin_compile.maybeWriteSiblingSab;
const pruneTestsByFilter = plugin_compile.pruneTestsByFilter;
const pruneUnreachableTestFunctionDeclsBeforeTypeCheck = plugin_compile.pruneUnreachableTestFunctionDeclsBeforeTypeCheck;
const resolveSlaInputFile = plugin_compile.resolveSlaInputFile;
const resolveWorkspaceSourcePath = plugin_compile.resolveWorkspaceSourcePath;
const testFilterSelectsNoTests = plugin_compile.testFilterSelectsNoTests;
const plugin_emit_reachability = @import("plugin_emit_reachability.zig");
const collectReachableExpr = plugin_emit_reachability.collectReachableExpr;
const collectReachableBlock = plugin_emit_reachability.collectReachableBlock;
const collectNeededTraitImplsExpr = plugin_emit_reachability.collectNeededTraitImplsExpr;
const collectNeededTraitImplsBlock = plugin_emit_reachability.collectNeededTraitImplsBlock;
const plugin_commands = @import("plugin_commands.zig");
const runSlaCommandImpl = plugin_commands.runSlaCommandImpl;

test "sla skills emits json capability list" {
    var stdout_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stdout_buf.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    var ctx = plugin_api.Context{ .allocator = std.testing.allocator };
    const args = [_][]const u8{ "sa", "sla", "skills", "--json" };
    const code = try runSlaCommandImpl(&ctx, args[0..], stdout_buf.writer().any(), stderr_buf.writer().any());

    try std.testing.expectEqual(@as(?u8, 0), code);
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buf.items, 1, "\"status\":\"ok\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buf.items, 1, "sla init [path]"));
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buf.items, 1, "sla sab build"));
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
}

test "sla skills honors host json mode" {
    var stdout_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stdout_buf.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    var ctx = plugin_api.Context{ .allocator = std.testing.allocator, .json_mode = true };
    const args = [_][]const u8{ "sa", "sla", "skills" };
    const code = try runSlaCommandImpl(&ctx, args[0..], stdout_buf.writer().any(), stderr_buf.writer().any());

    try std.testing.expectEqual(@as(?u8, 0), code);
    try std.testing.expect(std.mem.startsWith(u8, stdout_buf.items, "{\"status\":\"ok\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buf.items, 1, "sla skills [--json]"));
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
}

test "sla skills text writes agent skill files" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var stdout_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stdout_buf.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    var ctx = plugin_api.Context{ .allocator = std.testing.allocator };
    const args = [_][]const u8{ "sa", "sla", "skills" };
    const code = try runSlaCommandImpl(&ctx, args[0..], stdout_buf.writer().any(), stderr_buf.writer().any());

    try std.testing.expectEqual(@as(?u8, 0), code);
    try tmp.dir.access(".codex/skills/sla/SKILL.md", .{});
    try tmp.dir.access(".claude/skills/sla/SKILL.md", .{});
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buf.items, 1, "generated agent skills"));
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buf.items, 1, "sla skills [--json]"));
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
}

test "sla stability schema emits json schema" {
    var stdout_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stdout_buf.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    var ctx = plugin_api.Context{ .allocator = std.testing.allocator };
    const args = [_][]const u8{ "sa", "sla", "stability", "schema" };
    const code = try runSlaCommandImpl(&ctx, args[0..], stdout_buf.writer().any(), stderr_buf.writer().any());

    try std.testing.expectEqual(@as(?u8, 0), code);
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buf.items, 1, "\"schema_version\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buf.items, 1, "\"artifacts\""));
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
}

test "sla stability verify emits json report" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};
    try tmp.dir.writeFile(.{ .sub_path = "stability.json", .data = stability_metadata.example_manifest_json });

    var stdout_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stdout_buf.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    var ctx = plugin_api.Context{ .allocator = std.testing.allocator };
    const args = [_][]const u8{ "sa", "sla", "stability", "verify", "stability.json", "--json" };
    const code = try runSlaCommandImpl(&ctx, args[0..], stdout_buf.writer().any(), stderr_buf.writer().any());

    try std.testing.expectEqual(@as(?u8, 0), code);
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buf.items, 1, "\"status\":\"ok\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buf.items, 1, "\"labels\":5"));
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
}

test "sla stability verify rejects undeclared labels" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};
    try tmp.dir.writeFile(.{
        .sub_path = "bad_stability.json",
        .data =
        \\
        \\{
        \\  "schema_version": 1,
        \\  "labels": [{ "name": "stable-demo", "description": "demo" }],
        \\  "artifacts": [{ "path": "demo.sla", "labels": ["verified-sab-backend"] }]
        \\}
        \\
        ,
    });

    var stdout_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stdout_buf.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    var ctx = plugin_api.Context{ .allocator = std.testing.allocator };
    const args = [_][]const u8{ "sa", "sla", "stability", "verify", "bad_stability.json", "--json" };
    const code = try runSlaCommandImpl(&ctx, args[0..], stdout_buf.writer().any(), stderr_buf.writer().any());

    try std.testing.expectEqual(@as(?u8, 1), code);
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buf.items, 1, "\"status\":\"error\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buf.items, 1, "undeclared label"));
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
}

test "sla init scaffolds project without overwriting" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var stdout_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stdout_buf.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    var ctx = plugin_api.Context{ .allocator = std.testing.allocator };
    const args = [_][]const u8{ "sa", "sla", "init", "demo_app" };
    const code = try runSlaCommandImpl(&ctx, args[0..], stdout_buf.writer().any(), stderr_buf.writer().any());

    try std.testing.expectEqual(@as(?u8, 0), code);
    try tmp.dir.access("demo_app/sa.mod", .{});
    try tmp.dir.access("demo_app/src/main.sla", .{});
    try tmp.dir.access("demo_app/.gitignore", .{});

    const manifest = try tmp.dir.readFileAlloc(std.testing.allocator, "demo_app/sa.mod", 1024);
    defer std.testing.allocator.free(manifest);
    try std.testing.expect(std.mem.containsAtLeast(u8, manifest, 1, "package \"demo_app\""));

    const gitignore = try tmp.dir.readFileAlloc(std.testing.allocator, "demo_app/.gitignore", 1024);
    defer std.testing.allocator.free(gitignore);
    try std.testing.expect(std.mem.containsAtLeast(u8, gitignore, 1, ".sla-cache/"));

    const second_code = try runSlaCommandImpl(&ctx, args[0..], stdout_buf.writer().any(), stderr_buf.writer().any());
    try std.testing.expectEqual(@as(?u8, 1), second_code);
}

fn expectSlaCheckRedeclarationDiagnostic(file: []const u8, expected: []const u8) !void {
    var stdout_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stdout_buf.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    var ctx = plugin_api.Context{ .allocator = std.testing.allocator };
    const args = [_][]const u8{ "sa", "sla", "check", file };
    const code = try runSlaCommandImpl(&ctx, args[0..], stdout_buf.writer().any(), stderr_buf.writer().any());

    try std.testing.expectEqual(@as(?u8, 1), code);
    try std.testing.expect(std.mem.containsAtLeast(u8, stderr_buf.items, 1, "Type Check Error"));
    try std.testing.expect(std.mem.containsAtLeast(u8, stderr_buf.items, 1, "Redeclaration"));
    try std.testing.expect(std.mem.containsAtLeast(u8, stderr_buf.items, 1, expected));
}

fn expectSlaCheckSyntaxDiagnostic(file: []const u8, expected: []const u8) !void {
    var stdout_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stdout_buf.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    var ctx = plugin_api.Context{ .allocator = std.testing.allocator };
    const args = [_][]const u8{ "sa", "sla", "check", file };
    const code = try runSlaCommandImpl(&ctx, args[0..], stdout_buf.writer().any(), stderr_buf.writer().any());

    try std.testing.expectEqual(@as(?u8, 1), code);
    try std.testing.expect(std.mem.containsAtLeast(u8, stderr_buf.items, 1, "Syntax Error"));
    try std.testing.expect(std.mem.containsAtLeast(u8, stderr_buf.items, 1, expected));
}

test "sla check reports redeclared symbol names" {
    try expectSlaCheckRedeclarationDiagnostic("tests/test_error_redeclaration.sla", "symbol `value`");
    try expectSlaCheckRedeclarationDiagnostic("tests/test_error_redeclaration_const.sla", "symbol `value`");
    try expectSlaCheckRedeclarationDiagnostic("tests/test_error_redeclaration_top_const.sla", "symbol `LIMIT`");
    try expectSlaCheckRedeclarationDiagnostic("tests/test_error_redeclaration_param.sla", "symbol `value`");
    try expectSlaCheckRedeclarationDiagnostic("tests/test_error_redeclaration_closure_param.sla", "symbol `value`");
    try expectSlaCheckRedeclarationDiagnostic("tests/test_error_redeclaration_macro_param.sla", "symbol `value`");
    try expectSlaCheckRedeclarationDiagnostic("tests/test_error_redeclaration_function.sla", "function `repeated`");
    try expectSlaCheckRedeclarationDiagnostic("tests/test_error_redeclaration_const_function.sla", "const `repeated_value`");
    try expectSlaCheckRedeclarationDiagnostic("tests/test_error_redeclaration_struct.sla", "struct `Repeated`");
    try expectSlaCheckRedeclarationDiagnostic("tests/test_error_redeclaration_enum.sla", "enum `RepeatedEnum`");
    try expectSlaCheckRedeclarationDiagnostic("tests/test_error_redeclaration_trait.sla", "trait `RepeatedTrait`");
    try expectSlaCheckRedeclarationDiagnostic("tests/test_error_redeclaration_macro.sla", "macro `repeated_macro`");
    try expectSlaCheckRedeclarationDiagnostic("tests/test_error_redeclaration_method.sla", "method `score` for `RepeatedMethod`");
    try expectSlaCheckSyntaxDiagnostic("tests/test_error_bare_overload.sla", "found 'overload'");
}

test "sla check uses imported signatures without checking imported function bodies" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const dep_source =
        \\fn imported_a() -> i32 {
        \\    return missing_symbol();
        \\}
    ;
    const main_source =
        \\@import "dep.sla"
        \\
        \\fn main() -> i32 {
        \\    return dep::imported_a();
        \\}
    ;
    try tmp.dir.writeFile(.{ .sub_path = "dep.sla", .data = dep_source });
    try tmp.dir.writeFile(.{ .sub_path = "main.sla", .data = main_source });

    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var stdout_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stdout_buf.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    var ctx = plugin_api.Context{ .allocator = std.testing.allocator };
    const args = [_][]const u8{ "sa", "sla", "check", "main.sla" };
    const code = try runSlaCommandImpl(&ctx, args[0..], stdout_buf.writer().any(), stderr_buf.writer().any());

    if (code != @as(?u8, 0)) std.debug.print("{s}", .{stderr_buf.items});
    try std.testing.expectEqual(@as(?u8, 0), code);
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buf.items, 1, "Successfully parsed and verified"));
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
}

test "sla check skips parsing imported function bodies" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const dep_source =
        \\fn imported_a() -> i32 {
        \\    let = ;
        \\}
    ;
    const main_source =
        \\@import "dep.sla"
        \\
        \\fn main() -> i32 {
        \\    return dep::imported_a();
        \\}
    ;
    try tmp.dir.writeFile(.{ .sub_path = "dep.sla", .data = dep_source });
    try tmp.dir.writeFile(.{ .sub_path = "main.sla", .data = main_source });

    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var stdout_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stdout_buf.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    var ctx = plugin_api.Context{ .allocator = std.testing.allocator };
    const args = [_][]const u8{ "sa", "sla", "check", "main.sla" };
    const code = try runSlaCommandImpl(&ctx, args[0..], stdout_buf.writer().any(), stderr_buf.writer().any());

    if (code != @as(?u8, 0)) std.debug.print("{s}", .{stderr_buf.items});
    try std.testing.expectEqual(@as(?u8, 0), code);
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buf.items, 1, "Successfully parsed and verified"));
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
}

test "sla check uses imported method signatures without checking imported method bodies" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const dep_source =
        \\struct ImportedBox {
        \\    value: i32,
        \\}
        \\
        \\impl ImportedBox {
        \\    fn used(self) -> i32 {
        \\        return missing_symbol();
        \\    }
        \\}
    ;
    const main_source =
        \\@import "dep.sla"
        \\
        \\fn main() -> i32 {
        \\    let item = ImportedBox { value: 7 };
        \\    return item.used();
        \\}
    ;
    try tmp.dir.writeFile(.{ .sub_path = "dep.sla", .data = dep_source });
    try tmp.dir.writeFile(.{ .sub_path = "main.sla", .data = main_source });

    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var stdout_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stdout_buf.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    var ctx = plugin_api.Context{ .allocator = std.testing.allocator };
    const args = [_][]const u8{ "sa", "sla", "check", "main.sla" };
    const code = try runSlaCommandImpl(&ctx, args[0..], stdout_buf.writer().any(), stderr_buf.writer().any());

    if (code != @as(?u8, 0)) std.debug.print("{s}", .{stderr_buf.items});
    try std.testing.expectEqual(@as(?u8, 0), code);
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buf.items, 1, "Successfully parsed and verified"));
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
}

test "sla check uses imported trait method signatures without checking imported trait bodies" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const dep_source =
        \\trait Label {
        \\    fn label(self) -> i32;
        \\}
        \\
        \\struct ImportedThing {
        \\    value: i32,
        \\}
        \\
        \\impl Label for ImportedThing {
        \\    fn label(self) -> i32 {
        \\        return missing_trait_symbol();
        \\    }
        \\}
    ;
    const main_source =
        \\@import "dep.sla"
        \\
        \\fn main() -> i32 {
        \\    let item = ImportedThing { value: 7 };
        \\    return item.label();
        \\}
    ;
    try tmp.dir.writeFile(.{ .sub_path = "dep.sla", .data = dep_source });
    try tmp.dir.writeFile(.{ .sub_path = "main.sla", .data = main_source });

    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var stdout_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stdout_buf.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    var ctx = plugin_api.Context{ .allocator = std.testing.allocator };
    const args = [_][]const u8{ "sa", "sla", "check", "main.sla" };
    const code = try runSlaCommandImpl(&ctx, args[0..], stdout_buf.writer().any(), stderr_buf.writer().any());

    if (code != @as(?u8, 0)) std.debug.print("{s}", .{stderr_buf.items});
    try std.testing.expectEqual(@as(?u8, 0), code);
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buf.items, 1, "Successfully parsed and verified"));
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
}

test "sla check uses imported trait associated signatures without checking imported trait bodies" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const dep_source =
        \\trait Score {
        \\    fn score(self) -> i32;
        \\}
        \\
        \\struct ImportedScore {
        \\    value: i32,
        \\}
        \\
        \\impl Score for ImportedScore {
        \\    fn score(self) -> i32 {
        \\        return missing_score_symbol();
        \\    }
        \\}
    ;
    const main_source =
        \\@import "dep.sla"
        \\
        \\fn main() -> i32 {
        \\    let item = ImportedScore { value: 9 };
        \\    return Score::score(item);
        \\}
    ;
    try tmp.dir.writeFile(.{ .sub_path = "dep.sla", .data = dep_source });
    try tmp.dir.writeFile(.{ .sub_path = "main.sla", .data = main_source });

    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var stdout_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stdout_buf.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    var ctx = plugin_api.Context{ .allocator = std.testing.allocator };
    const args = [_][]const u8{ "sa", "sla", "check", "main.sla" };
    const code = try runSlaCommandImpl(&ctx, args[0..], stdout_buf.writer().any(), stderr_buf.writer().any());

    if (code != @as(?u8, 0)) std.debug.print("{s}", .{stderr_buf.items});
    try std.testing.expectEqual(@as(?u8, 0), code);
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buf.items, 1, "Successfully parsed and verified"));
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
}

test "sla build rewrites sla imports relative to final output path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    const sa_code = (try compileSlaToSaString(
        arena.allocator(),
        "tests/import_fixtures/output_relative/main.sla",
        "tests/output_relative_root.sa",
        stderr_buf.writer().any(),
    )) orelse {
        std.debug.print("{s}", .{stderr_buf.items});
        return error.TestUnexpectedResult;
    };

    try std.testing.expect(std.mem.indexOf(u8, sa_code, "@import \"import_fixtures/output_relative/local_dep.sa\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sa_code, "@import \"helper.sa\"") == null);
}

test "sla test filter prunes unmatched tests before type checking" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const filtered_source =
        \\fn value() -> i32 {
        \\    return 1;
        \\};
        \\
        \\@test "keep this test"() {
        \\    let x = value();
        \\    if x != 1 { panic(24001); };
        \\};
        \\
        \\@test "drop broken test"() {
        \\    missing_symbol();
        \\};
    ;
    try tmp.dir.writeFile(.{ .sub_path = "filtered.sla", .data = filtered_source });

    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    const sa_code = (try compileSlaToSaStringWithOptions(
        arena.allocator(),
        "filtered.sla",
        "filtered.test.sa",
        stderr_buf.writer().any(),
        .{ .test_filter = "keep this" },
    )) orelse {
        std.debug.print("{s}", .{stderr_buf.items});
        return error.TestUnexpectedResult;
    };

    try std.testing.expect(std.mem.indexOf(u8, sa_code, "keep this test") != null);
    try std.testing.expect(std.mem.indexOf(u8, sa_code, "drop broken test") == null);
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
}

test "sla test sab backend prunes unmatched tests before type checking" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const filtered_sab_source =
        \\fn value() -> i32 {
        \\    return 2;
        \\};
        \\
        \\@test "sab keep"() {
        \\    let x = value();
        \\    if x != 2 { panic(24002); };
        \\};
        \\
        \\@test "sab drop broken"() {
        \\    missing_symbol();
        \\};
    ;
    try tmp.dir.writeFile(.{ .sub_path = "filtered_sab.sla", .data = filtered_sab_source });

    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    const sab_bytes = (try compileSlaFileToSabWithOptions(
        arena.allocator(),
        "filtered_sab.sla",
        ".sla-cache/sab/filtered_sab.sab",
        stderr_buf.writer().any(),
        .{ .test_filter = "sab keep" },
    )) orelse {
        std.debug.print("{s}", .{stderr_buf.items});
        return error.TestUnexpectedResult;
    };

    var module = try sci_bridge.sab.decodeModule(std.testing.allocator, sab_bytes);
    defer module.deinit(std.testing.allocator);

    var test_count: usize = 0;
    for (module.function_sigs) |fsig| {
        if (fsig.kind == .test_func) test_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), test_count);
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
}

test "sla test codegen prunes unreachable functions before type checking" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const source =
        \\fn used_value() -> i32 {
        \\    return 7;
        \\};
        \\
        \\fn unused_broken_value() -> i32 {
        \\    return missing_symbol();
        \\};
        \\
        \\@test "reachable function only"() {
        \\    let got = used_value();
        \\    if got != 7 { panic(24003); };
        \\};
    ;
    try tmp.dir.writeFile(.{ .sub_path = "reachable_only.sla", .data = source });

    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    const sa_code = (try compileSlaToSaStringWithOptions(
        arena.allocator(),
        "reachable_only.sla",
        "reachable_only.test.sa",
        stderr_buf.writer().any(),
        .{ .prune_for_test_codegen = true },
    )) orelse {
        std.debug.print("{s}", .{stderr_buf.items});
        return error.TestUnexpectedResult;
    };

    try std.testing.expect(std.mem.indexOf(u8, sa_code, "sla__used_value") != null);
    try std.testing.expect(std.mem.indexOf(u8, sa_code, "unused_broken_value") == null);
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
}

test "sla test import expansion prunes unreachable imported functions" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const dep_source =
        \\fn used_import() -> i32 {
        \\    return import_helper();
        \\};
        \\
        \\fn import_helper() -> i32 {
        \\    return 41;
        \\};
        \\
        \\fn unused_import() -> i32 {
        \\    return 99;
        \\};
    ;
    const main_source =
        \\@import "dep.sla"
        \\
        \\@test "reachable import only"() {
        \\    let got = used_import();
        \\    if got != 41 { panic(24006); };
        \\};
    ;
    try tmp.dir.writeFile(.{ .sub_path = "dep.sla", .data = dep_source });
    try tmp.dir.writeFile(.{ .sub_path = "main.sla", .data = main_source });

    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const expanded_content = try source_expand.expand(allocator, main_source);
    var parser = parser_mod.Parser.initWithDir(allocator, expanded_content, ".");
    const prog = try parser.parseProgram();
    var primary_decls = std.AutoHashMap(*const ast.Node, void).init(allocator);
    const expanded_prog = try expandSlaImports(allocator, prog, "main.sla", &primary_decls, .{
        .prune_for_test_codegen = true,
    });

    var saw_used = false;
    var saw_helper = false;
    var saw_unused = false;
    for (expanded_prog.program.decls) |decl| {
        if (decl.* != .func_decl) continue;
        if (std.mem.eql(u8, decl.func_decl.name, "used_import")) saw_used = true;
        if (std.mem.eql(u8, decl.func_decl.name, "import_helper")) saw_helper = true;
        if (std.mem.eql(u8, decl.func_decl.name, "unused_import")) saw_unused = true;
    }
    try std.testing.expect(saw_used);
    try std.testing.expect(saw_helper);
    try std.testing.expect(!saw_unused);
}

test "sla test import expansion prunes unreachable imported methods" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const dep_source =
        \\struct ImportedBox {
        \\    value: i32,
        \\}
        \\
        \\impl ImportedBox {
        \\    fn used(self) -> i32 {
        \\        return self.value;
        \\    }
        \\
        \\    fn unused_broken(self) -> i32 {
        \\        return missing_import_method_symbol();
        \\    }
        \\}
    ;
    const main_source =
        \\@import "dep.sla"
        \\
        \\@test "reachable import method only"() {
        \\    let item = ImportedBox { value: 44 };
        \\    let got = item.used();
        \\    if got != 44 { panic(24008); };
        \\};
    ;
    try tmp.dir.writeFile(.{ .sub_path = "dep.sla", .data = dep_source });
    try tmp.dir.writeFile(.{ .sub_path = "main.sla", .data = main_source });

    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    const sa_code = (try compileSlaToSaStringWithOptions(
        arena.allocator(),
        "main.sla",
        "main.test.sa",
        stderr_buf.writer().any(),
        .{ .prune_for_test_codegen = true },
    )) orelse {
        std.debug.print("{s}", .{stderr_buf.items});
        return error.TestUnexpectedResult;
    };

    try std.testing.expect(std.mem.indexOf(u8, sa_code, "ImportedBox_used") != null);
    try std.testing.expect(std.mem.indexOf(u8, sa_code, "unused_broken") == null);
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
}

test "sla test codegen uses registry loaded imported bodies" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const dep_source =
        \\trait Label {
        \\    fn label(self) -> i32;
        \\    fn unused_trait(self) -> i32;
        \\}
        \\
        \\struct ImportedThing {
        \\    value: i32,
        \\}
        \\
        \\fn imported_value() -> i32 {
        \\    return 68;
        \\}
        \\
        \\fn unused_bad() -> MissingType {
        \\    return nope();
        \\}
        \\
        \\impl ImportedThing {
        \\    fn used(self) -> i32 {
        \\        return self.value;
        \\    }
        \\}
        \\
        \\impl Label for ImportedThing {
        \\    fn label(self) -> i32 {
        \\        return self.value + 1;
        \\    }
        \\
        \\    fn unused_trait(self) -> i32 {
        \\        return missing_trait_body();
        \\    }
        \\}
    ;
    const main_source =
        \\@import "dep.sla"
        \\
        \\@test "registry loaded test body"() {
        \\    let item = ImportedThing { value: imported_value() };
        \\    let got = item.used() + item.label();
        \\    if got != 137 { panic(24137); };
        \\};
    ;
    try tmp.dir.writeFile(.{ .sub_path = "dep.sla", .data = dep_source });
    try tmp.dir.writeFile(.{ .sub_path = "main.sla", .data = main_source });

    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var sa_stderr = std.ArrayList(u8).init(std.testing.allocator);
    defer sa_stderr.deinit();
    const sa_compiled = try compileSlaSaTestInput(allocator, "main.sla", sa_stderr.writer().any(), &.{}, false);
    if (sa_compiled) |compiled| {
        defer if (compiled.delete_after) std.fs.cwd().deleteFile(compiled.path) catch {};
        const sa_code = try std.fs.cwd().readFileAlloc(allocator, compiled.path, 10 * 1024 * 1024);
        try std.testing.expect(std.mem.indexOf(u8, sa_code, "sla__imported_value") != null);
        try std.testing.expect(std.mem.indexOf(u8, sa_code, "ImportedThing_used") != null);
        try std.testing.expect(std.mem.indexOf(u8, sa_code, "ImportedThing__Label_label") != null);
        try std.testing.expect(std.mem.indexOf(u8, sa_code, "unused_bad") == null);
        try std.testing.expect(std.mem.indexOf(u8, sa_code, "missing_trait_body") == null);
    } else {
        std.debug.print("{s}", .{sa_stderr.items});
        return error.TestUnexpectedResult;
    }
    try std.testing.expectEqual(@as(usize, 0), sa_stderr.items.len);

    var sab_stderr = std.ArrayList(u8).init(std.testing.allocator);
    defer sab_stderr.deinit();
    const sab_compiled = try compileSlaSabTestInput(allocator, "main.sla", sab_stderr.writer().any(), &.{}, false);
    if (sab_compiled) |compiled| {
        defer if (compiled.delete_after) std.fs.cwd().deleteFile(compiled.path) catch {};
        const sab_bytes = try std.fs.cwd().readFileAlloc(allocator, compiled.path, 10 * 1024 * 1024);
        var module = try sci_bridge.sab.decodeModule(std.testing.allocator, sab_bytes);
        defer module.deinit(std.testing.allocator);

        var saw_value = false;
        var saw_used = false;
        var saw_label = false;
        var saw_unused_bad = false;
        var saw_unused_trait = false;
        for (module.function_sigs) |fsig| {
            if (std.mem.indexOf(u8, fsig.name, "imported_value") != null) saw_value = true;
            if (std.mem.indexOf(u8, fsig.name, "ImportedThing_used") != null) saw_used = true;
            if (std.mem.indexOf(u8, fsig.name, "ImportedThing__Label_label") != null) saw_label = true;
            if (std.mem.indexOf(u8, fsig.name, "unused_bad") != null) saw_unused_bad = true;
            if (std.mem.indexOf(u8, fsig.name, "unused_trait") != null) saw_unused_trait = true;
        }
        try std.testing.expect(saw_value);
        try std.testing.expect(saw_used);
        try std.testing.expect(saw_label);
        try std.testing.expect(!saw_unused_bad);
        try std.testing.expect(!saw_unused_trait);
    } else {
        std.debug.print("{s}", .{sab_stderr.items});
        return error.TestUnexpectedResult;
    }
    try std.testing.expectEqual(@as(usize, 0), sab_stderr.items.len);
}

test "sla test codegen keeps imported macro direct callee" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const macro_source =
        \\[MACRO] TEST_IMPORTED_PAIR_SUM %out, %value
        \\    %out = call @sla__macro_pair_sum(&%value)
        \\[END_MACRO]
    ;
    const main_source =
        \\@import "imported_macros.sa"
        \\
        \\struct Pair { left: i64, right: i64 }
        \\
        \\fn macro_pair_sum(value: &Pair) -> i64 {
        \\    value.left + value.right
        \\}
        \\
        \\fn use_imported_macro() -> i64 {
        \\    let pair = Pair { left: 31, right: 11 };
        \\    TEST_IMPORTED_PAIR_SUM(pair)
        \\}
        \\
        \\@test "imported macro callee stays reachable"() {
        \\    if use_imported_macro() != 42 { panic(24042); };
        \\};
    ;
    try tmp.dir.writeFile(.{ .sub_path = "imported_macros.sa", .data = macro_source });
    try tmp.dir.writeFile(.{ .sub_path = "main.sla", .data = main_source });

    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const expanded_content = try source_expand.expand(allocator, main_source);
    var parser = parser_mod.Parser.initWithDir(allocator, expanded_content, ".");
    const prog = try parser.parseProgram();
    var macro_tc = type_checker_mod.TypeChecker.init(allocator);
    defer macro_tc.deinit();
    try loadImportedContracts(&macro_tc, allocator, prog, "main.sla");
    const imported_macro = macro_tc.imported_macros.get("TEST_IMPORTED_PAIR_SUM");
    try std.testing.expect(imported_macro != null);
    try std.testing.expectEqual(@as(usize, 1), imported_macro.?.direct_callees.len);
    try std.testing.expectEqualStrings("macro_pair_sum", imported_macro.?.direct_callees[0]);

    var modules = SlaModuleTable.init(allocator);
    defer modules.deinit();
    var reachable = std.StringHashMap(void).init(allocator);
    var referenced_types = std.StringHashMap(void).init(allocator);
    try buildReachableSymbols(allocator, prog, &.{}, &modules, .{ .prune_for_test_codegen = true }, &macro_tc.imported_macros, &reachable, &referenced_types);
    try std.testing.expect(reachable.contains("use_imported_macro"));
    try std.testing.expect(reachable.contains("macro_pair_sum"));

    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();
    const compiled = try compileSlaSaTestInput(allocator, "main.sla", stderr_buf.writer().any(), &.{}, false);
    if (compiled) |test_input| {
        defer if (test_input.delete_after) std.fs.cwd().deleteFile(test_input.path) catch {};
        const sa_code = try std.fs.cwd().readFileAlloc(allocator, test_input.path, 10 * 1024 * 1024);
        try std.testing.expect(std.mem.indexOf(u8, sa_code, "EXPAND TEST_IMPORTED_PAIR_SUM") != null);
        try std.testing.expect(std.mem.indexOf(u8, sa_code, "@sla__macro_pair_sum(value") != null);
    } else {
        std.debug.print("{s}", .{stderr_buf.items});
        return error.TestUnexpectedResult;
    }
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
}

test "sla emit reachability keeps user macro direct callee" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source =
        \\fn helper(value: i32) -> i32 {
        \\    return value + 1;
        \\}
        \\
        \\macro apply_helper(out) {
        \\    out = helper(out);
        \\}
        \\
        \\fn run() -> i32 {
        \\    let value = 1;
        \\    apply_helper(value);
        \\    return value;
        \\}
        \\
        \\@test "user macro callee"() {
        \\    if run() != 2 { panic(1); };
        \\}
    ;

    var parser = parser_mod.Parser.initWithDir(allocator, source, ".");
    const prog = try parser.parseProgram();
    var tc = type_checker_mod.TypeChecker.init(allocator);
    defer tc.deinit();
    try tc.checkProgram(prog);

    var reachable = std.StringHashMap(void).init(allocator);
    defer reachable.deinit();
    var worklist = std.ArrayList([]const u8).init(allocator);
    defer worklist.deinit();
    for (prog.program.decls) |decl| {
        if (decl.* == .test_decl) try collectReachableBlock(&tc, &reachable, &worklist, decl.test_decl.body);
    }
    var index: usize = 0;
    while (index < worklist.items.len) : (index += 1) {
        const func = tc.funcs.get(worklist.items[index]) orelse continue;
        try collectReachableBlock(&tc, &reachable, &worklist, func.body);
    }
    try std.testing.expect(reachable.contains("helper"));
}

test "sla test codegen prunes unreferenced sla macro bodies" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const dep_source =
        \\fn used_value() -> i32 {
        \\    return 42;
        \\}
        \\
        \\macro unused_imported_macro(value) {
        \\    let dead = missing_imported_macro_helper(value);
        \\}
        \\
        \\fn missing_imported_macro_helper(value: i32) -> i32 {
        \\    return missing_imported_symbol(value);
        \\}
    ;
    const main_source =
        \\@import "dep.sla"
        \\
        \\macro unused_root_macro(value) {
        \\    let dead = missing_root_macro_helper(value);
        \\}
        \\
        \\fn missing_root_macro_helper(value: i32) -> i32 {
        \\    return missing_root_symbol(value);
        \\}
        \\
        \\@test "reachable function ignores dead macros"() {
        \\    if used_value() != 42 { panic(24045); };
        \\}
    ;
    try tmp.dir.writeFile(.{ .sub_path = "dep.sla", .data = dep_source });
    try tmp.dir.writeFile(.{ .sub_path = "main.sla", .data = main_source });

    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();
    const compiled = try compileSlaSaTestInput(allocator, "main.sla", stderr_buf.writer().any(), &.{}, false);
    if (compiled) |test_input| {
        defer if (test_input.delete_after) std.fs.cwd().deleteFile(test_input.path) catch {};
        const sa_code = try std.fs.cwd().readFileAlloc(allocator, test_input.path, 10 * 1024 * 1024);
        try std.testing.expect(std.mem.indexOf(u8, sa_code, "unused_root_macro") == null);
        try std.testing.expect(std.mem.indexOf(u8, sa_code, "missing_root_macro_helper") == null);
        try std.testing.expect(std.mem.indexOf(u8, sa_code, "unused_imported_macro") == null);
        try std.testing.expect(std.mem.indexOf(u8, sa_code, "missing_imported_macro_helper") == null);
        try std.testing.expect(std.mem.indexOf(u8, sa_code, "missing_imported_symbol") == null);
    } else {
        std.debug.print("{s}", .{stderr_buf.items});
        return error.TestUnexpectedResult;
    }
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
}

test "sla test codegen does not root imported const initializers" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const dep_source =
        \\const IMPORTED_BONUS: i32 = 1;
        \\const UNUSED_BAD_CONST: i32 = dead_const_helper();
        \\
        \\fn used_value() -> i32 {
        \\    return 41 + IMPORTED_BONUS;
        \\}
        \\
        \\fn dead_const_helper() -> i32 {
        \\    return missing_imported_const_symbol();
        \\}
    ;
    const main_source =
        \\@import "dep.sla"
        \\
        \\@test "reachable import ignores dead const"() {
        \\    if used_value() != 42 { panic(24051); };
        \\}
    ;
    try tmp.dir.writeFile(.{ .sub_path = "dep.sla", .data = dep_source });
    try tmp.dir.writeFile(.{ .sub_path = "main.sla", .data = main_source });

    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();
    const compiled = try compileSlaSaTestInput(allocator, "main.sla", stderr_buf.writer().any(), &.{}, false);
    if (compiled) |test_input| {
        defer if (test_input.delete_after) std.fs.cwd().deleteFile(test_input.path) catch {};
        const sa_code = try std.fs.cwd().readFileAlloc(allocator, test_input.path, 10 * 1024 * 1024);
        try std.testing.expect(std.mem.indexOf(u8, sa_code, "used_value") != null);
        try std.testing.expect(std.mem.indexOf(u8, sa_code, "UNUSED_BAD_CONST") == null);
        try std.testing.expect(std.mem.indexOf(u8, sa_code, "dead_const_helper") == null);
        try std.testing.expect(std.mem.indexOf(u8, sa_code, "missing_imported_const_symbol") == null);
    } else {
        std.debug.print("{s}", .{stderr_buf.items});
        return error.TestUnexpectedResult;
    }
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
}

test "sla pre-typecheck pruning keeps local function pointer callees" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source =
        \\fn inc(x: i32) -> i32 {
        \\    return x + 1;
        \\}
        \\
        \\@test "fnptr"() {
        \\    let f: fn(i32) -> i32 = inc;
        \\    if f(1) != 2 { panic(1); };
        \\}
    ;

    var parser = parser_mod.Parser.initWithDir(allocator, source, ".");
    const prog = try parser.parseProgram();
    try pruneTestsByFilter(allocator, prog, "fnptr");
    try pruneUnreachableTestFunctionDeclsBeforeTypeCheck(allocator, prog, null, null, true);

    var saw_binding = false;
    for (prog.program.decls) |decl| {
        if (decl.* != .test_decl) continue;
        for (decl.test_decl.body) |stmt| {
            if (stmt.* == .let_stmt and std.mem.eql(u8, stmt.let_stmt.name, "f")) saw_binding = true;
        }
    }
    try std.testing.expect(saw_binding);

    var tc = type_checker_mod.TypeChecker.init(allocator);
    defer tc.deinit();
    try tc.checkProgram(prog);
}

test "sla pre-typecheck pruning keeps release-only bindings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source =
        \\struct Item { value: i64 }
        \\
        \\@test "release"() {
        \\    let value = Item { value: 1 };
        \\    let moved = value;
        \\    !moved;
        \\}
    ;

    var parser = parser_mod.Parser.initWithDir(allocator, source, ".");
    const prog = try parser.parseProgram();
    try pruneTestsByFilter(allocator, prog, "release");
    try pruneUnreachableTestFunctionDeclsBeforeTypeCheck(allocator, prog, null, null, true);

    var saw_binding = false;
    for (prog.program.decls) |decl| {
        if (decl.* != .test_decl) continue;
        for (decl.test_decl.body) |stmt| {
            if (stmt.* == .let_stmt and std.mem.eql(u8, stmt.let_stmt.name, "moved")) saw_binding = true;
        }
    }
    try std.testing.expect(saw_binding);

    var tc = type_checker_mod.TypeChecker.init(allocator);
    defer tc.deinit();
    try tc.checkProgram(prog);

    for (prog.program.decls) |decl| {
        if (decl.* != .test_decl or decl.test_decl.body.len == 0) continue;
        const last = decl.test_decl.body[decl.test_decl.body.len - 1];
        if (tc.cleanups.get(last)) |cleanup| {
            for (cleanup.items) |name| try std.testing.expect(!std.mem.eql(u8, name, "value"));
        }
    }
}

test "sla typechecker restores fallthrough ownership after terminating move branch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source =
        \\struct Item { value: i64 }
        \\
        \\fn release_branch(flag: bool) -> void {
        \\    let value = Item { value: 1 };
        \\    if flag {
        \\        let moved = value;
        \\        !moved;
        \\        return;
        \\    };
        \\    !value;
        \\}
    ;

    var parser = parser_mod.Parser.initWithDir(allocator, source, ".");
    const prog = try parser.parseProgram();
    var tc = type_checker_mod.TypeChecker.init(allocator);
    defer tc.deinit();
    try tc.checkProgram(prog);
}

test "sla typechecker merges if let ownership using live branches" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source =
        \\@import "sa_std/core/option.sa"
        \\struct Item { value: i64 }
        \\
        \\fn then_terminates(first: Option<i64>, second: Option<i64>) -> void {
        \\    let value = Item { value: 1 };
        \\    if let Some(first_value) = first && let Some(second_value) = second {
        \\        let moved = value;
        \\        !moved;
        \\        return;
        \\    } else {};
        \\    !value;
        \\}
        \\
        \\fn else_terminates(first: Option<i64>, second: Option<i64>) -> void {
        \\    let value = Item { value: 1 };
        \\    if let Some(first_value) = first && let Some(second_value) = second {
        \\    } else {
        \\        let moved = value;
        \\        !moved;
        \\        return;
        \\    };
        \\    !value;
        \\}
    ;

    var parser = parser_mod.Parser.initWithDir(allocator, source, ".");
    const prog = try parser.parseProgram();
    var tc = type_checker_mod.TypeChecker.init(allocator);
    defer tc.deinit();
    try tc.checkProgram(prog);
}

test "shared multi-branch ownership state intersects live arms" {
    const active_consumed = [_]control_flow_rules.ValueState{ .active, .consumed, .active };
    const active_uninitialized = [_]control_flow_rules.ValueState{ .active, .uninitialized };
    const all_consumed = [_]control_flow_rules.ValueState{ .consumed, .consumed };
    try std.testing.expectEqual(control_flow_rules.MultiBranchStateMergeAction.restore_pre, control_flow_rules.planMultiBranchStateMerge(0));
    try std.testing.expectEqual(control_flow_rules.MultiBranchStateMergeAction.restore_single, control_flow_rules.planMultiBranchStateMerge(1));
    try std.testing.expectEqual(control_flow_rules.MultiBranchStateMergeAction.intersect_live, control_flow_rules.planMultiBranchStateMerge(2));
    try std.testing.expectEqual(control_flow_rules.ValueState.consumed, control_flow_rules.intersectLiveBranchValueStates(&active_consumed));
    try std.testing.expectEqual(control_flow_rules.ValueState.uninitialized, control_flow_rules.intersectLiveBranchValueStates(&active_uninitialized));
    try std.testing.expectEqual(control_flow_rules.ValueState.consumed, control_flow_rules.intersectLiveBranchValueStates(&all_consumed));
}

test "sla typechecker merges match and switch ownership using live arms" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source =
        \\@import "sa_std/core/option.sa"
        \\enum Choice { Keep, Stop }
        \\struct Item { value: i64 }
        \\
        \\fn match_owner(choice: Choice) -> void {
        \\    let value = Item { value: 1 };
        \\    match choice {
        \\        Choice::Keep => {},
        \\        Choice::Stop => {
        \\            let moved = value;
        \\            !moved;
        \\            return;
        \\        },
        \\    };
        \\    !value;
        \\}
        \\
        \\fn option_match_owner(choice: Option<i64>) -> void {
        \\    let value = Item { value: 1 };
        \\    match choice {
        \\        Some(item) => {},
        \\        None => {
        \\            let moved = value;
        \\            !moved;
        \\            return;
        \\        },
        \\    };
        \\    !value;
        \\}
        \\
        \\fn switch_owner(flag: bool) -> void {
        \\    let value = Item { value: 1 };
        \\    switch flag {
        \\        true => {},
        \\        false => {
        \\            let moved = value;
        \\            !moved;
        \\            return;
        \\        },
        \\    };
        \\    !value;
        \\}
    ;

    var parser = parser_mod.Parser.initWithDir(allocator, source, ".");
    const prog = try parser.parseProgram();
    var tc = type_checker_mod.TypeChecker.init(allocator);
    defer tc.deinit();
    try tc.checkProgram(prog);
}

test "sla typechecker cleans borrow locals on loop jumps" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source =
        \\struct Item { value: i64 }
        \\
        \\fn jump_cleanup(value: &Item, flag: bool) -> void {
        \\    while flag {
        \\        let borrowed: &Item = value;
        \\        if borrowed.value == 0 {
        \\            continue;
        \\        };
        \\        break;
        \\    }
        \\}
    ;

    var parser = parser_mod.Parser.initWithDir(allocator, source, ".");
    const prog = try parser.parseProgram();
    var tc = type_checker_mod.TypeChecker.init(allocator);
    defer tc.deinit();
    try tc.checkProgram(prog);

    var saw_break_cleanup = false;
    var saw_continue_cleanup = false;
    var iter = tc.cleanups.iterator();
    while (iter.next()) |entry| {
        const jump = entry.key_ptr.*.*;
        if (jump != .break_stmt and jump != .continue_stmt) continue;
        for (entry.value_ptr.items) |name| {
            if (!std.mem.eql(u8, name, "borrowed")) continue;
            if (jump == .break_stmt) saw_break_cleanup = true;
            if (jump == .continue_stmt) saw_continue_cleanup = true;
        }
    }
    try std.testing.expect(saw_break_cleanup);
    try std.testing.expect(saw_continue_cleanup);
}

test "sla sa loop backedges require live body fallthrough" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const source =
        \\fn while_break() -> i64 {
        \\    let value: i64 = 1;
        \\    while value > 0 {
        \\        break;
        \\    }
        \\    return value;
        \\}
        \\
        \\fn for_break() -> i64 {
        \\    for i in 0..1 {
        \\        break;
        \\    }
        \\    return 1;
        \\}
        \\
        \\@test "terminated loops"() {
        \\    if while_break() != 1 { panic(30932); };
        \\    if for_break() != 1 { panic(30933); };
        \\}
    ;
    try tmp.dir.writeFile(.{ .sub_path = "main.sla", .data = source });
    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();
    const sa_code = (try compileSlaToSaStringWithOptions(
        arena.allocator(),
        "main.sla",
        "main.test.sa",
        stderr_buf.writer().any(),
        .{ .prune_for_test_codegen = true },
    )) orelse {
        std.debug.print("{s}", .{stderr_buf.items});
        return error.TestUnexpectedResult;
    };

    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, sa_code, "jmp L_WHILE_HEAD"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, sa_code, "jmp L_LOOP_HEAD"));
}

test "sla sab filtered primitive call temp remains in test scope" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    const sab_bytes = (try compileSlaFileToSabWithOptions(
        arena.allocator(),
        "tests/test_unit_refcell_owner_release_direct.sla",
        ".sla-cache/sab/filtered_loop_scope_test.sab",
        stderr_buf.writer().any(),
        .{
            .test_filter = "refcell loop jumps release active borrow handles",
            .prune_for_test_codegen = true,
            .load_reachable_imported_bodies_from_registry = true,
        },
    )) orelse {
        std.debug.print("{s}", .{stderr_buf.items});
        return error.TestUnexpectedResult;
    };

    var module = try sci_bridge.sab.decodeModule(std.testing.allocator, sab_bytes);
    defer module.deinit(std.testing.allocator);

    var test_sig_index: ?usize = null;
    for (module.function_sigs, 0..) |fsig, idx| {
        if (fsig.kind != .test_func) continue;
        test_sig_index = idx;
        break;
    }
    const selected_sig_index = test_sig_index orelse return error.TestUnexpectedResult;
    const selected_sig = &module.function_sigs[selected_sig_index];
    const body_end = if (selected_sig_index + 1 < module.function_sigs.len)
        module.function_sigs[selected_sig_index + 1].entry_inst_idx
    else
        module.instructions.len;

    var call_arg_name: ?[]const u8 = null;
    for (module.instructions[selected_sig.entry_inst_idx..body_end]) |item| {
        if (item.kind != .call) continue;
        for (item.operands) |operand| {
            if (operand != .text) continue;
            const marker = "@sla__owner_release_loop_return_move_value(";
            const start = std.mem.indexOf(u8, operand.text, marker) orelse continue;
            const args_start = start + marker.len;
            const args_end = std.mem.indexOfScalarPos(u8, operand.text, args_start, ')') orelse continue;
            call_arg_name = std.mem.trim(u8, operand.text[args_start..args_end], " \t\r\n");
            break;
        }
        if (call_arg_name != null) break;
    }
    const arg_name = call_arg_name orelse return error.TestUnexpectedResult;

    var arg_id: ?u32 = null;
    for (module.symbols, 0..) |name, idx| {
        if (std.mem.eql(u8, name, arg_name)) {
            arg_id = @intCast(idx);
            break;
        }
    }
    const selected_arg_id = arg_id orelse return error.TestUnexpectedResult;
    var in_scope = false;
    for (selected_sig.reg_ids) |reg_id| {
        if (reg_id == selected_arg_id) in_scope = true;
    }
    try std.testing.expect(in_scope);
}

test "sla typechecker cleans borrow locals on try propagation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source =
        \\@import "sa_std/core/option.sa"
        \\struct Item { value: i64 }
        \\
        \\fn propagate(value: &Item, maybe: Option<i64>) -> Option<i64> {
        \\    let borrowed: &Item = value;
        \\    let inner = maybe?;
        \\    return Some(inner + borrowed.value);
        \\}
    ;

    var parser = parser_mod.Parser.initWithDir(allocator, source, ".");
    const prog = try parser.parseProgram();
    var tc = type_checker_mod.TypeChecker.init(allocator);
    defer tc.deinit();
    try tc.checkProgram(prog);

    var saw_try_cleanup = false;
    var iter = tc.cleanups.iterator();
    while (iter.next()) |entry| {
        if (entry.key_ptr.*.* != .try_expr) continue;
        for (entry.value_ptr.items) |name| {
            if (std.mem.eql(u8, name, "borrowed")) saw_try_cleanup = true;
        }
    }
    try std.testing.expect(saw_try_cleanup);
}

test "sla typechecker plans exact explicit return cleanup" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source =
        \\struct Item { value: i64 }
        \\
        \\fn read(value: &Item) -> i64 {
        \\    let borrowed: &Item = value;
        \\    return borrowed.value;
        \\}
        \\
        \\fn transfer(value: &Item) -> &Item {
        \\    let borrowed: &Item = value;
        \\    return borrowed;
        \\}
    ;

    var parser = parser_mod.Parser.initWithDir(allocator, source, ".");
    const prog = try parser.parseProgram();
    var tc = type_checker_mod.TypeChecker.init(allocator);
    defer tc.deinit();
    try tc.checkProgram(prog);

    const read_return = prog.program.decls[1].func_decl.body[1];
    const transfer_return = prog.program.decls[2].func_decl.body[1];
    const read_cleanup = tc.cleanups.get(read_return) orelse return error.TestUnexpectedResult;
    var read_releases_borrowed = false;
    for (read_cleanup.items) |name| {
        if (std.mem.eql(u8, name, "borrowed")) read_releases_borrowed = true;
    }
    try std.testing.expect(read_releases_borrowed);

    if (tc.cleanups.get(transfer_return)) |transfer_cleanup| {
        for (transfer_cleanup.items) |name| {
            try std.testing.expect(!std.mem.eql(u8, name, "borrowed"));
            try std.testing.expect(!std.mem.eql(u8, name, "value"));
        }
    }
}

test "sla generated async exits release stored state inputs" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const source =
        \\@import "sa_std/future.sa"
        \\@import "sa_std/core/task.sa"
        \\
        \\async fn generated_exit(unused: i64) -> i64 {
        \\    let value = future::defer_ready(41).await;
        \\    return value + 1;
        \\}
        \\
        \\@test "generated async exit"() {
        \\    let fut = generated_exit(7);
        \\    let task = task::new(fut);
        \\    task::poll(task);
        \\    task::poll(task);
        \\    if task::result(task) != 42 { panic(30948); };
        \\}
    ;
    try tmp.dir.writeFile(.{ .sub_path = "main.sla", .data = source });
    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();
    const sa_code = (try compileSlaToSaStringWithOptions(
        arena.allocator(),
        "main.sla",
        "main.test.sa",
        stderr_buf.writer().any(),
        .{ .prune_for_test_codegen = true },
    )) orelse {
        std.debug.print("{s}", .{stderr_buf.items});
        return error.TestUnexpectedResult;
    };

    const function_start = std.mem.indexOf(u8, sa_code, "@sla__generated_exit(unused: i64) -> ptr:") orelse return error.TestUnexpectedResult;
    const function_tail = sa_code[function_start..];
    const function_end = std.mem.indexOfPos(u8, function_tail, 1, "\n@") orelse function_tail.len;
    const function_body = function_tail[0..function_end];
    const state_store = std.mem.indexOf(u8, function_body, " as ptr\n") orelse return error.TestUnexpectedResult;
    const store_line_start = std.mem.lastIndexOfScalar(u8, function_body[0..state_store], '\n') orelse return error.TestUnexpectedResult;
    const store_line = function_body[store_line_start + 1 .. state_store];
    const comma = std.mem.lastIndexOfScalar(u8, store_line, ',') orelse return error.TestUnexpectedResult;
    const stored_state = std.mem.trim(u8, store_line[comma + 1 ..], " \t");
    const release_line = try std.fmt.allocPrint(arena.allocator(), "    !{s}\n", .{stored_state});
    try std.testing.expect(std.mem.indexOfPos(u8, function_body, state_store, release_line) != null);
    try std.testing.expect(std.mem.indexOf(u8, function_body, "    !unused\n") != null);
}

test "sla sab borrow alias return keeps source register" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    const sab_bytes = (try compileSlaFileToSabWithOptions(
        arena.allocator(),
        "tests/test_unit_explicit_borrow_return_direct.sla",
        ".sla-cache/sab/borrow_alias_return_test.sab",
        stderr_buf.writer().any(),
        .{},
    )) orelse {
        std.debug.print("{s}", .{stderr_buf.items});
        return error.TestUnexpectedResult;
    };

    var module = try sci_bridge.sab.decodeModule(std.testing.allocator, sab_bytes);
    defer module.deinit(std.testing.allocator);
    var function_index: ?usize = null;
    for (module.function_sigs, 0..) |fsig, idx| {
        if (std.mem.eql(u8, fsig.name, "sla__explicit_borrow_alias")) {
            function_index = idx;
            break;
        }
    }
    const idx = function_index orelse return error.TestUnexpectedResult;
    const fsig = module.function_sigs[idx];
    try std.testing.expectEqual(@as(usize, 1), fsig.param_ids.len);
    const body_end = if (idx + 1 < module.function_sigs.len) module.function_sigs[idx + 1].entry_inst_idx else module.instructions.len;
    var saw_return = false;
    for (module.instructions[fsig.entry_inst_idx..body_end]) |item| {
        try std.testing.expect(item.kind != .move_);
        if (item.kind != .return_) continue;
        try std.testing.expect(item.operands[0] == .reg);
        try std.testing.expectEqual(fsig.param_ids[0], item.operands[0].reg);
        saw_return = true;
    }
    try std.testing.expect(saw_return);
}

test "sla typechecker records exact await pending cleanup" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source =
        \\async fn pending_cleanup(unused: i64, fut: future<i64>) -> i64 {
        \\    let held = unused + 1;
        \\    let value = fut.await;
        \\    return value;
        \\}
    ;

    var parser = parser_mod.Parser.initWithDir(allocator, source, ".");
    const prog = try parser.parseProgram();
    var tc = type_checker_mod.TypeChecker.init(allocator);
    defer tc.deinit();
    try tc.checkProgram(prog);

    const await_expr = prog.program.decls[0].func_decl.body[1].let_stmt.value;
    try std.testing.expect(await_expr.* == .await_expr);
    const cleanup = tc.await_cleanups.get(await_expr) orelse return error.TestUnexpectedResult;
    var saw_unused = false;
    var saw_held = false;
    for (cleanup.items) |name| {
        if (std.mem.eql(u8, name, "unused")) saw_unused = true;
        if (std.mem.eql(u8, name, "held")) saw_held = true;
        try std.testing.expect(!std.mem.eql(u8, name, "fut"));
    }
    try std.testing.expect(saw_unused);
    try std.testing.expect(saw_held);
}

test "sla empty void exits keep caller managed parameters" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();
    const sa_code = (try compileSlaToSaString(
        arena.allocator(),
        "tests/test_unit_empty_void_exit_cleanup_direct.sla",
        ".sla-cache/empty_void_exit_test.sa",
        stderr_buf.writer().any(),
    )) orelse {
        std.debug.print("{s}", .{stderr_buf.items});
        return error.TestUnexpectedResult;
    };

    for ([_][]const u8{ "@sla__empty_void_borrow(value: ptr):", "@sla__empty_void_owned(value: ptr):" }) |header| {
        const start = std.mem.indexOf(u8, sa_code, header) orelse return error.TestUnexpectedResult;
        const tail = sa_code[start..];
        const end = std.mem.indexOfPos(u8, tail, 1, "\n@") orelse tail.len;
        const body = tail[0..end];
        try std.testing.expect(std.mem.indexOf(u8, body, "    return\n") != null);
        try std.testing.expect(std.mem.indexOf(u8, body, "    !value\n") == null);
    }
}

test "sla reachability merges only call facts shared by every caller" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var analysis = ReachabilityAnalysis.init(allocator, true);
    defer analysis.deinit();
    var first = SyntacticFactSet.init(allocator);
    defer first.deinit();
    try first.putKnownIntField("change", "reason", 4);
    try first.putKnownBoolField("change", "has_active_file", true);
    try first.putLocalType("change", "MiniSnapshotChange");
    try std.testing.expect(try analysis.mergeFunctionFacts("warm", &first));

    var second = SyntacticFactSet.init(allocator);
    defer second.deinit();
    try second.putKnownIntField("change", "reason", 1);
    try second.putKnownBoolField("change", "has_active_file", true);
    try second.putLocalType("change", "MiniSnapshotChange");
    try std.testing.expect(try analysis.mergeFunctionFacts("warm", &second));

    const merged = &analysis.function_facts.getPtr("warm").?.facts;
    try std.testing.expectEqual(@as(?i64, null), merged.getKnownIntField("change", "reason"));
    try std.testing.expectEqual(@as(?bool, true), merged.getKnownBoolField("change", "has_active_file"));
    try std.testing.expectEqualStrings("MiniSnapshotChange", merged.getLocalType("change").?);
}

test "sla pre-typecheck pruning keeps for-in protocol methods" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source =
        \\struct Items {
        \\    len: i64,
        \\}
        \\
        \\impl Items {
        \\    fn iter_len(&self) -> i64 {
        \\        return self.len;
        \\    }
        \\
        \\    fn iter_at(&self, index: i64) -> i32 {
        \\        return index as i32;
        \\    }
        \\}
        \\
        \\@test "protocol"() {
        \\    let items = Items { len: 2 };
        \\    let total: i32 = 0;
        \\    for item in items {
        \\        total = total + item;
        \\    }
        \\    if total != 1 { panic(1); };
        \\}
    ;

    var parser = parser_mod.Parser.initWithDir(allocator, source, ".");
    const prog = try parser.parseProgram();
    try pruneTestsByFilter(allocator, prog, "protocol");
    try pruneUnreachableTestFunctionDeclsBeforeTypeCheck(allocator, prog, null, null, true);

    var method_count: usize = 0;
    for (prog.program.decls) |decl| {
        if (decl.* == .impl_decl) method_count += decl.impl_decl.methods.len;
    }
    try std.testing.expectEqual(@as(usize, 2), method_count);

    var tc = type_checker_mod.TypeChecker.init(allocator);
    defer tc.deinit();
    try tc.checkProgram(prog);

    var reachable = std.StringHashMap(void).init(allocator);
    defer reachable.deinit();
    var worklist = std.ArrayList([]const u8).init(allocator);
    defer worklist.deinit();
    for (prog.program.decls) |decl| {
        if (decl.* == .test_decl) try collectReachableBlock(&tc, &reachable, &worklist, decl.test_decl.body);
    }
    try std.testing.expect(reachable.contains("Items_iter_len"));
    try std.testing.expect(reachable.contains("Items_iter_at"));
}

test "sla post-typecheck prune removes statically empty import scan branches" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source =
        \\struct ImportSpecifierScanResult {
        \\    import_count: int,
        \\}
        \\
        \\fn parse_import_specifiers(text: ptr, text_len: int) -> ImportSpecifierScanResult {
        \\    return ImportSpecifierScanResult { import_count: 0 };
        \\}
        \\
        \\fn program_resolve_module() -> int {
        \\    return dead_resolver();
        \\}
        \\
        \\fn program_resolve_import_scan_for_file(imports: ImportSpecifierScanResult) -> int {
        \\    if imports.import_count >= 1 {
        \\        return program_resolve_module();
        \\    };
        \\    return 0;
        \\}
        \\
        \\fn program_new_single_file(text: ptr, text_len: int) -> int {
        \\    let imports = parse_import_specifiers(text, text_len);
        \\    return program_resolve_import_scan_for_file(imports);
        \\}
        \\
        \\fn project_snapshot_from_single_file(text: ptr, text_len: int) -> int {
        \\    return program_new_single_file(text, text_len);
        \\}
        \\
        \\@test "no import text skips resolver branch"() {
        \\    let text = "let shared = 1;";
        \\    let got = project_snapshot_from_single_file(STR_PTR(text), STR_LEN(text));
        \\    if got != 0 { panic(24046); };
        \\}
        \\
        \\@test "import text keeps resolver branch"() {
        \\    let text = "import value from 'pkg';";
        \\    let got = project_snapshot_from_single_file(STR_PTR(text), STR_LEN(text));
        \\    if got != 0 { panic(24047); };
        \\}
    ;

    var no_import_parser = parser_mod.Parser.initWithDir(allocator, source, ".");
    const no_import_prog = try no_import_parser.parseProgram();
    try pruneTestsByFilter(allocator, no_import_prog, "no import text");
    try pruneUnreachableTestFunctionDeclsBeforeTypeCheck(allocator, no_import_prog, null, null, true);

    var saw_no_import_program_new = false;
    var saw_no_import_scan = false;
    var saw_no_import_resolver = false;
    for (no_import_prog.program.decls) |decl| {
        if (decl.* != .func_decl) continue;
        if (std.mem.eql(u8, decl.func_decl.name, "program_new_single_file")) saw_no_import_program_new = true;
        if (std.mem.eql(u8, decl.func_decl.name, "program_resolve_import_scan_for_file")) saw_no_import_scan = true;
        if (std.mem.eql(u8, decl.func_decl.name, "program_resolve_module")) saw_no_import_resolver = true;
    }
    try std.testing.expect(saw_no_import_program_new);
    try std.testing.expect(saw_no_import_scan);
    try std.testing.expect(!saw_no_import_resolver);

    var import_parser = parser_mod.Parser.initWithDir(allocator, source, ".");
    const import_prog = try import_parser.parseProgram();
    try pruneTestsByFilter(allocator, import_prog, "import text");
    try pruneUnreachableTestFunctionDeclsBeforeTypeCheck(allocator, import_prog, null, null, true);

    var saw_import_program_new = false;
    var saw_import_scan = false;
    var saw_import_resolver = false;
    for (import_prog.program.decls) |decl| {
        if (decl.* != .func_decl) continue;
        if (std.mem.eql(u8, decl.func_decl.name, "program_new_single_file")) saw_import_program_new = true;
        if (std.mem.eql(u8, decl.func_decl.name, "program_resolve_import_scan_for_file")) saw_import_scan = true;
        if (std.mem.eql(u8, decl.func_decl.name, "program_resolve_module")) saw_import_resolver = true;
    }
    try std.testing.expect(saw_import_program_new);
    try std.testing.expect(saw_import_scan);
    try std.testing.expect(saw_import_resolver);
}

test "sla test codegen prunes known struct field branches" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source =
        \\struct TinySession {
        \\    has_scheduled_snapshot_update: bool,
        \\    pending_file_change_count: int,
        \\}
        \\
        \\fn session_empty() -> TinySession {
        \\    return TinySession { has_scheduled_snapshot_update: false, pending_file_change_count: 0 };
        \\}
        \\
        \\fn session_with_update() -> TinySession {
        \\    return TinySession { has_scheduled_snapshot_update: true, pending_file_change_count: 0 };
        \\}
        \\
        \\fn broken_scheduler(session: TinySession) -> TinySession {
        \\    return missing_scheduler(session);
        \\}
        \\
        \\fn cancel_scheduled(session: TinySession) -> TinySession {
        \\    if session.has_scheduled_snapshot_update != false {
        \\        return broken_scheduler(session);
        \\    };
        \\    return session;
        \\}
        \\
        \\@test "false field skips scheduler"() {
        \\    let session = session_empty();
        \\    let canceled = cancel_scheduled(session);
        \\    if canceled.pending_file_change_count != 0 { panic(24049); };
        \\}
        \\
        \\@test "true field keeps scheduler"() {
        \\    let session = session_with_update();
        \\    let canceled = cancel_scheduled(session);
        \\    if canceled.pending_file_change_count != 0 { panic(24050); };
        \\}
    ;

    var false_parser = parser_mod.Parser.initWithDir(allocator, source, ".");
    const false_prog = try false_parser.parseProgram();
    try pruneTestsByFilter(allocator, false_prog, "false field");
    try pruneUnreachableTestFunctionDeclsBeforeTypeCheck(allocator, false_prog, null, null, true);

    var saw_false_cancel = false;
    var saw_false_broken = false;
    for (false_prog.program.decls) |decl| {
        if (decl.* != .func_decl) continue;
        if (std.mem.eql(u8, decl.func_decl.name, "cancel_scheduled")) saw_false_cancel = true;
        if (std.mem.eql(u8, decl.func_decl.name, "broken_scheduler")) saw_false_broken = true;
    }
    try std.testing.expect(saw_false_cancel);
    try std.testing.expect(!saw_false_broken);

    var true_parser = parser_mod.Parser.initWithDir(allocator, source, ".");
    const true_prog = try true_parser.parseProgram();
    try pruneTestsByFilter(allocator, true_prog, "true field");
    try pruneUnreachableTestFunctionDeclsBeforeTypeCheck(allocator, true_prog, null, null, true);

    var saw_true_cancel = false;
    var saw_true_broken = false;
    for (true_prog.program.decls) |decl| {
        if (decl.* != .func_decl) continue;
        if (std.mem.eql(u8, decl.func_decl.name, "cancel_scheduled")) saw_true_cancel = true;
        if (std.mem.eql(u8, decl.func_decl.name, "broken_scheduler")) saw_true_broken = true;
    }
    try std.testing.expect(saw_true_cancel);
    try std.testing.expect(saw_true_broken);
}

test "sla callable index records exported type declarations" {
    const source =
        \\struct IndexedStruct { value: i32 }
        \\enum IndexedEnum { Ready }
        \\trait IndexedTrait { fn value(self) -> i32; }
        \\type IndexedAlias = IndexedStruct;
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var parser = parser_mod.Parser.init(allocator, source);
    const prog = try parser.parseProgram();

    var index = SlaCallableIndex.init(allocator);
    defer index.deinit();
    try index.addDecls(prog.program.decls);

    try std.testing.expect(index.type_decls.contains("IndexedStruct"));
    try std.testing.expect(index.type_decls.contains("IndexedEnum"));
    try std.testing.expect(index.type_decls.contains("IndexedTrait"));
    try std.testing.expect(index.type_decls.contains("IndexedAlias"));
}

test "sla reachability root scanners skip unchanged sets and honor invalidation" {
    const source =
        \\struct IndexedRoot { value: i32 }
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var parser = parser_mod.Parser.init(allocator, source);
    const prog = try parser.parseProgram();

    var index = SlaCallableIndex.init(allocator);
    defer index.deinit();
    try index.addDecls(prog.program.decls);
    var referenced = std.StringHashMap(void).init(allocator);
    defer referenced.deinit();
    try referenced.put("IndexedRoot", {});
    var scanned_symbols = std.StringHashMap(void).init(allocator);
    defer scanned_symbols.deinit();
    var scanned_types = std.StringHashMap(void).init(allocator);
    defer scanned_types.deinit();
    var reachable = std.StringHashMap(void).init(allocator);
    defer reachable.deinit();
    var worklist = std.ArrayList([]const u8).init(allocator);
    defer worklist.deinit();

    try std.testing.expect(try scanReferencedSymbolRoots(&index, null, null, null, &reachable, &referenced, &scanned_symbols, &worklist));
    try std.testing.expect(!(try scanReferencedSymbolRoots(&index, null, null, null, &reachable, &referenced, &scanned_symbols, &worklist)));
    _ = scanned_symbols.remove("IndexedRoot");
    try std.testing.expect(try scanReferencedSymbolRoots(&index, null, null, null, &reachable, &referenced, &scanned_symbols, &worklist));

    try std.testing.expect(try scanReferencedExportedTypeSignatures(&index, &referenced, &scanned_types));
    try std.testing.expect(!(try scanReferencedExportedTypeSignatures(&index, &referenced, &scanned_types)));
    _ = scanned_types.remove("IndexedRoot");
    try std.testing.expect(try scanReferencedExportedTypeSignatures(&index, &referenced, &scanned_types));
}

test "sla load imported macros parses already expanded source" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const macro_source =
        \\@expand_tuple(1, 1, T) {
        \\[MACRO] EXPANDED_IMPORTED_MACRO %out
        \\    @expand_tuple invalid_after_first_expansion
        \\[END_MACRO]
        \\}
    ;
    const main_source =
        \\@import "expanded_macros.sa"
        \\
        \\@test "expanded macro import"() {
        \\}
    ;
    try tmp.dir.writeFile(.{ .sub_path = "expanded_macros.sa", .data = macro_source });
    try tmp.dir.writeFile(.{ .sub_path = "main.sla", .data = main_source });

    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const expanded_content = try source_expand.expand(allocator, main_source);
    var parser = parser_mod.Parser.initWithDir(allocator, expanded_content, ".");
    const prog = try parser.parseProgram();

    var macro_tc = type_checker_mod.TypeChecker.init(allocator);
    defer macro_tc.deinit();
    try loadImportedContracts(&macro_tc, allocator, prog, "main.sla");

    try std.testing.expect(macro_tc.imported_macros.get("EXPANDED_IMPORTED_MACRO") != null);
}

test "sla contract loader fast paths macro free sources" {
    const contract_only_source =
        \\@extern contract_only() -> i32
        \\// [END_MACRO] without a macro header should not force macro scanning.
    ;
    try std.testing.expect(!expandedSourceMayContainImportedMacros(contract_only_source));
    try std.testing.expect(expandedSourceMayContainImportedMacros(
        \\    [MACRO] CONTRACT_MACRO %out
        \\        %out = 1
        \\    [END_MACRO]
    ));
    try std.testing.expect(!expandedSourceMayContainImports(contract_only_source));
    try std.testing.expect(expandedSourceMayContainImports(
        \\    @import "child.sai"
    ));

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tc = type_checker_mod.TypeChecker.init(allocator);
    defer tc.deinit();
    try loadImportedMacrosFromExpandedSource(&tc, allocator, contract_only_source, "contract_only.sai");
    try std.testing.expectEqual(@as(usize, 0), tc.imported_macros.count());
}

test "sla load contracts reuses resolved non-sla imports" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const macro_source =
        \\[MACRO] RESOLVED_IMPORT_MACRO %out
        \\    %out = 42
        \\[END_MACRO]
    ;
    const sai_source =
        \\@extern resolved_import_external() -> i32
    ;
    const plain_sa_source =
        \\@helper_plain:
        \\ret
    ;
    const main_source =
        \\@import "imported_macros.sa"
        \\@import "imported_contract.sai"
        \\@import "plain_helper.sa"
        \\
        \\fn main() -> i32 {
        \\    return 0;
        \\}
    ;
    try tmp.dir.writeFile(.{ .sub_path = "imported_macros.sa", .data = macro_source });
    try tmp.dir.writeFile(.{ .sub_path = "imported_contract.sai", .data = sai_source });
    try tmp.dir.writeFile(.{ .sub_path = "plain_helper.sa", .data = plain_sa_source });
    try tmp.dir.writeFile(.{ .sub_path = "main.sla", .data = main_source });

    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const expanded_content = try source_expand.expand(allocator, main_source);
    var parser = parser_mod.Parser.initWithDir(allocator, expanded_content, ".");
    const prog = try parser.parseProgram();

    var import_modules = SlaModuleTable.init(allocator);
    defer import_modules.deinit();
    var root_import_groups = std.ArrayList(SlaResolvedImportGroup).init(allocator);
    defer root_import_groups.deinit();
    var contract_imports = std.ArrayList(ResolvedImport).init(allocator);
    defer contract_imports.deinit();
    var primary_decls = std.AutoHashMap(*const ast.Node, void).init(allocator);
    const expanded_prog = try expandSlaImportsWithModuleTable(allocator, prog, "main.sla", &primary_decls, .{}, &import_modules, &root_import_groups, &contract_imports);
    try std.testing.expect(expanded_prog.program.decls.len > 0);
    try std.testing.expectEqual(@as(usize, 2), contract_imports.items.len);

    try tmp.dir.deleteFile("imported_macros.sa");
    try tmp.dir.deleteFile("imported_contract.sai");
    try tmp.dir.deleteFile("plain_helper.sa");

    var tc = type_checker_mod.TypeChecker.init(allocator);
    defer tc.deinit();
    try loadImportedContractsFromResolvedImports(&tc, allocator, contract_imports.items);

    try std.testing.expect(tc.imported_macros.get("RESOLVED_IMPORT_MACRO") != null);
    try std.testing.expect(tc.extern_funcs.get("resolved_import_external") != null);
}

test "sla test import expansion reuses reachable contracts in final type checker" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const macro_source =
        \\[MACRO] REUSED_REACHABLE_MACRO %out, %value
        \\    %out = add %value, 1
        \\[END_MACRO]
    ;
    const contract_source =
        \\@extern reused_reachable_external(value: i32) -> i32
    ;
    const dep_source =
        \\@import "reachable_macros.sa"
        \\@import "reachable_contract.sai"
        \\
        \\fn reachable_value(value: i32) -> i32 {
        \\    return reused_reachable_external(REUSED_REACHABLE_MACRO(value));
        \\}
    ;
    const main_source =
        \\@import "dep.sla"
        \\
        \\@test "reachable contract reuse"() {
        \\    if reachable_value(40) != 42 { panic(24046); };
        \\}
    ;
    try tmp.dir.writeFile(.{ .sub_path = "reachable_macros.sa", .data = macro_source });
    try tmp.dir.writeFile(.{ .sub_path = "reachable_contract.sai", .data = contract_source });
    try tmp.dir.writeFile(.{ .sub_path = "dep.sla", .data = dep_source });
    try tmp.dir.writeFile(.{ .sub_path = "main.sla", .data = main_source });

    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const expanded_content = try source_expand.expand(allocator, main_source);
    var parser = parser_mod.Parser.initWithDir(allocator, expanded_content, ".");
    const prog = try parser.parseProgram();

    var import_modules = SlaModuleTable.initWithParserOptions(allocator, .{
        .parse_function_bodies = false,
        .parse_macro_bodies = false,
        .parse_test_bodies = false,
    });
    defer import_modules.deinit();
    var root_import_groups = std.ArrayList(SlaResolvedImportGroup).init(allocator);
    defer root_import_groups.deinit();
    var contract_imports = std.ArrayList(ResolvedImport).init(allocator);
    defer contract_imports.deinit();
    var primary_decls = std.AutoHashMap(*const ast.Node, void).init(allocator);
    var tc = type_checker_mod.TypeChecker.init(allocator);
    defer tc.deinit();

    const expanded_prog = try expandSlaImportsWithModuleTableUsingContractTypeChecker(
        allocator,
        prog,
        "main.sla",
        &primary_decls,
        .{
            .prune_for_test_codegen = true,
            .test_filter = "reachable contract reuse",
            .imported_bodies_decl_only = true,
            .load_reachable_imported_bodies_from_registry = true,
        },
        &import_modules,
        &root_import_groups,
        &contract_imports,
        &tc,
    );
    try std.testing.expect(expanded_prog.program.decls.len > 0);
    try std.testing.expect(contract_imports.items.len >= 2);
    try std.testing.expect(tc.imported_macros.get("REUSED_REACHABLE_MACRO") != null);
    try std.testing.expect(tc.extern_funcs.get("reused_reachable_external") != null);

    try tmp.dir.deleteFile("reachable_macros.sa");
    try tmp.dir.deleteFile("reachable_contract.sai");
    try tc.checkProgram(expanded_prog);
}

test "sla test codegen skips contract loading for non contributing imported modules" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const dead_source =
        \\@import "dead_contract.sai"
        \\
        \\fn dead_value() -> i32 {
        \\    return dead_external();
        \\}
    ;
    const dead_contract_source =
        \\@extern dead_external(
    ;
    const main_source =
        \\@import "dead.sla"
        \\
        \\fn root_value() -> i32 {
        \\    return 42;
        \\}
        \\
        \\@test "root only"() {
        \\    if root_value() != 42 { panic(24042); };
        \\}
    ;
    try tmp.dir.writeFile(.{ .sub_path = "dead.sla", .data = dead_source });
    try tmp.dir.writeFile(.{ .sub_path = "dead_contract.sai", .data = dead_contract_source });
    try tmp.dir.writeFile(.{ .sub_path = "main.sla", .data = main_source });

    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();
    const compiled = try compileSlaSaTestInput(allocator, "main.sla", stderr_buf.writer().any(), &.{}, false);
    if (compiled) |test_input| {
        defer if (test_input.delete_after) std.fs.cwd().deleteFile(test_input.path) catch {};
        const sa_code = try std.fs.cwd().readFileAlloc(allocator, test_input.path, 10 * 1024 * 1024);
        try std.testing.expect(std.mem.indexOf(u8, sa_code, "root_value") != null);
        try std.testing.expect(std.mem.indexOf(u8, sa_code, "dead_external") == null);
    } else {
        std.debug.print("{s}", .{stderr_buf.items});
        return error.TestUnexpectedResult;
    }
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
}

test "sla test codegen loads contract imports for contributing imported modules" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const macro_source =
        \\[MACRO] USED_IMPORTED_MODULE_MACRO %out, %value
        \\    %out = call @sla__used_macro_helper(%value)
        \\[END_MACRO]
    ;
    const dep_source =
        \\@import "used_macros.sa"
        \\@import "dead_contract.sai"
        \\
        \\fn used_macro_helper(value: i32) -> i32 {
        \\    return value + 1;
        \\}
        \\
        \\fn used_entry() -> i32 {
        \\    return USED_IMPORTED_MODULE_MACRO(41);
        \\}
    ;
    const dead_contract_source =
        \\@extern dead_external(
    ;
    const main_source =
        \\@import "dep.sla"
        \\
        \\@test "imported module macro direct callee"() {
        \\    if used_entry() != 42 { panic(24043); };
        \\}
    ;
    try tmp.dir.writeFile(.{ .sub_path = "used_macros.sa", .data = macro_source });
    try tmp.dir.writeFile(.{ .sub_path = "dead_contract.sai", .data = dead_contract_source });
    try tmp.dir.writeFile(.{ .sub_path = "dep.sla", .data = dep_source });
    try tmp.dir.writeFile(.{ .sub_path = "main.sla", .data = main_source });

    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();
    const compiled = try compileSlaSaTestInput(allocator, "main.sla", stderr_buf.writer().any(), &.{}, false);
    if (compiled) |test_input| {
        defer if (test_input.delete_after) std.fs.cwd().deleteFile(test_input.path) catch {};
        const sa_code = try std.fs.cwd().readFileAlloc(allocator, test_input.path, 10 * 1024 * 1024);
        try std.testing.expect(std.mem.indexOf(u8, sa_code, "EXPAND USED_IMPORTED_MODULE_MACRO") != null);
        try std.testing.expect(std.mem.indexOf(u8, sa_code, "@sla__used_macro_helper") != null);
        try std.testing.expect(std.mem.indexOf(u8, sa_code, "dead_external") == null);
    } else {
        std.debug.print("{s}", .{stderr_buf.items});
        return error.TestUnexpectedResult;
    }
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
}

test "sla test codegen skips contract loading for type only imported modules" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const dep_source =
        \\@import "type_only_contract.sai"
        \\
        \\struct ImportedType {
        \\    value: i32,
        \\}
        \\
        \\fn dead_external_value() -> i32 {
        \\    return type_only_dead_external();
        \\}
    ;
    const dead_contract_source =
        \\@extern type_only_dead_external(
    ;
    const main_source =
        \\@import "dep.sla"
        \\
        \\@test "imported type only"() {
        \\    let item = ImportedType { value: 42 };
        \\    if item.value != 42 { panic(24044); };
        \\}
    ;
    try tmp.dir.writeFile(.{ .sub_path = "dep.sla", .data = dep_source });
    try tmp.dir.writeFile(.{ .sub_path = "type_only_contract.sai", .data = dead_contract_source });
    try tmp.dir.writeFile(.{ .sub_path = "main.sla", .data = main_source });

    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();
    const compiled = try compileSlaSaTestInput(allocator, "main.sla", stderr_buf.writer().any(), &.{}, false);
    if (compiled) |test_input| {
        defer if (test_input.delete_after) std.fs.cwd().deleteFile(test_input.path) catch {};
        const sa_code = try std.fs.cwd().readFileAlloc(allocator, test_input.path, 10 * 1024 * 1024);
        try std.testing.expect(std.mem.indexOf(u8, sa_code, "dead_external_value") == null);
        try std.testing.expect(std.mem.indexOf(u8, sa_code, "type_only_dead_external") == null);
    } else {
        std.debug.print("{s}", .{stderr_buf.items});
        return error.TestUnexpectedResult;
    }
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
}

test "sla test codegen loads referenced macro imports from type only modules" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const macro_source =
        \\[MACRO] TYPE_ONLY_INC %out, %value
        \\    %out = add %value, 1
        \\[END_MACRO]
    ;
    const dep_source =
        \\@import "type_only_macros.sa"
        \\@import "dead_contract.sai"
        \\
        \\struct ImportedType {
        \\    value: i32,
        \\}
        \\
        \\fn dead_external_value() -> i32 {
        \\    return type_only_dead_external();
        \\}
    ;
    const dead_contract_source =
        \\@extern type_only_dead_external(
    ;
    const main_source =
        \\@import "dep.sla"
        \\
        \\@test "imported type only macro surface"() {
        \\    let item = ImportedType { value: 41 };
        \\    if TYPE_ONLY_INC(item.value) != 42 { panic(24045); };
        \\}
    ;
    try tmp.dir.writeFile(.{ .sub_path = "type_only_macros.sa", .data = macro_source });
    try tmp.dir.writeFile(.{ .sub_path = "dep.sla", .data = dep_source });
    try tmp.dir.writeFile(.{ .sub_path = "dead_contract.sai", .data = dead_contract_source });
    try tmp.dir.writeFile(.{ .sub_path = "main.sla", .data = main_source });

    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();
    const compiled = try compileSlaSaTestInput(allocator, "main.sla", stderr_buf.writer().any(), &.{}, false);
    if (compiled) |test_input| {
        defer if (test_input.delete_after) std.fs.cwd().deleteFile(test_input.path) catch {};
        const sa_code = try std.fs.cwd().readFileAlloc(allocator, test_input.path, 10 * 1024 * 1024);
        try std.testing.expect(std.mem.indexOf(u8, sa_code, "EXPAND TYPE_ONLY_INC") != null);
        try std.testing.expect(std.mem.indexOf(u8, sa_code, "type_only_dead_external") == null);
    } else {
        std.debug.print("{s}", .{stderr_buf.items});
        return error.TestUnexpectedResult;
    }
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
}

test "sla reachable roots keep canonical callable key for temporary mangled method symbols" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source =
        \\struct ImportedBox {}
        \\
        \\impl ImportedBox {
        \\    fn used(self) -> i32 {
        \\        return 1;
        \\    }
        \\}
    ;
    var parser = parser_mod.Parser.init(allocator, source);
    const prog = try parser.parseProgram();

    var callable_index = SlaCallableIndex.init(allocator);
    defer callable_index.deinit();
    try callable_index.addDecls(prog.program.decls);

    const temp_symbol = try lowering_rules.mangleMethodName(std.testing.allocator, "ImportedBox", "used");
    defer std.testing.allocator.free(temp_symbol);
    const canonical_symbol = callable_index.names.getKey(temp_symbol) orelse return error.TestUnexpectedResult;
    try std.testing.expect(canonical_symbol.ptr != temp_symbol.ptr);

    var reachable = std.StringHashMap(void).init(allocator);
    defer reachable.deinit();
    var referenced_types = std.StringHashMap(void).init(allocator);
    defer referenced_types.deinit();
    var worklist = std.ArrayList([]const u8).init(allocator);
    defer worklist.deinit();

    try markSyntacticReachableFunc(&callable_index, null, null, null, null, &reachable, &referenced_types, &worklist, temp_symbol);

    const stored_key = reachable.getKey(temp_symbol) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(canonical_symbol.ptr, stored_key.ptr);
    try std.testing.expectEqual(@as(usize, 1), worklist.items.len);
    try std.testing.expectEqual(canonical_symbol.ptr, worklist.items[0].ptr);
}

test "sla check keeps imported generic function refs from root tests reachable" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const dep_source =
        \\fn imported_drop<T>(raw: *u8) -> void {
        \\}
    ;
    const main_source =
        \\@import "dep.sla"
        \\
        \\struct Tiny {}
        \\
        \\fn accept_drop(drop_fn: fn(*u8) -> void) -> void {
        \\}
        \\
        \\@test "root test imported generic fn ref"() {
        \\    accept_drop(imported_drop<Tiny>);
        \\}
    ;
    try tmp.dir.writeFile(.{ .sub_path = "dep.sla", .data = dep_source });
    try tmp.dir.writeFile(.{ .sub_path = "main.sla", .data = main_source });

    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const expanded_content = try source_expand.expand(allocator, main_source);
    var parser = parser_mod.Parser.initWithDir(allocator, expanded_content, ".");
    const prog = try parser.parseProgram();
    var primary_decls = std.AutoHashMap(*const ast.Node, void).init(allocator);
    const expanded_prog = try expandSlaImports(allocator, prog, "main.sla", &primary_decls, .{
        .imported_bodies_decl_only = true,
    });

    var mono = monomorphizer_mod.Monomorphizer.init(allocator);
    defer mono.deinit();
    var specialized_primary_decls = std.AutoHashMap(*const ast.Node, void).init(allocator);
    _ = try mono.monomorphize(expanded_prog, &primary_decls, &specialized_primary_decls);
}

test "sla import expansion omits tests from contributing imported modules" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const dep_source =
        \\struct ImportedType {}
        \\
        \\fn imported_helper() -> i32 {
        \\    return 1;
        \\}
        \\
        \\@test "dependency test should stay out of root check"() {
        \\    if imported_helper() != 1 { panic(91001); };
        \\}
    ;
    const main_source =
        \\@import "dep.sla"
        \\
        \\fn use_imported_type(value: ImportedType) -> i32 {
        \\    return 1;
        \\}
    ;
    try tmp.dir.writeFile(.{ .sub_path = "dep.sla", .data = dep_source });
    try tmp.dir.writeFile(.{ .sub_path = "main.sla", .data = main_source });

    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const expanded_content = try source_expand.expand(allocator, main_source);
    var parser = parser_mod.Parser.initWithDir(allocator, expanded_content, ".");
    const prog = try parser.parseProgram();
    var primary_decls = std.AutoHashMap(*const ast.Node, void).init(allocator);
    const expanded_prog = try expandSlaImports(allocator, prog, "main.sla", &primary_decls, .{
        .imported_bodies_decl_only = true,
    });

    var saw_imported_type = false;
    var saw_imported_test = false;
    for (expanded_prog.program.decls) |decl| {
        switch (decl.*) {
            .struct_decl => |s| {
                if (std.mem.eql(u8, s.name, "ImportedType")) saw_imported_type = true;
            },
            .test_decl => |t| {
                if (std.mem.eql(u8, t.name, "dependency test should stay out of root check")) saw_imported_test = true;
            },
            else => {},
        }
    }
    try std.testing.expect(saw_imported_type);
    try std.testing.expect(!saw_imported_test);
}

test "sla module namespace call resolves through imported function alias" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const dep_source =
        \\fn imported_a() -> i32 {
        \\    return 7;
        \\}
    ;
    const main_source =
        \\@import "dep.sla"
        \\
        \\@test "namespace import call"() {
        \\    let got = dep::imported_a();
        \\    if got != 7 { panic(24013); };
        \\};
    ;
    try tmp.dir.writeFile(.{ .sub_path = "dep.sla", .data = dep_source });
    try tmp.dir.writeFile(.{ .sub_path = "main.sla", .data = main_source });

    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    const sa_code = (try compileSlaToSaStringWithOptions(
        arena.allocator(),
        "main.sla",
        "main.test.sa",
        stderr_buf.writer().any(),
        .{ .prune_for_test_codegen = true },
    )) orelse {
        std.debug.print("{s}", .{stderr_buf.items});
        return error.TestUnexpectedResult;
    };

    try std.testing.expect(std.mem.indexOf(u8, sa_code, "sla__dep__imported_a") != null);
    try std.testing.expect(std.mem.indexOf(u8, sa_code, "call @sla__dep__imported_a") != null);
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);

    var sab_stderr = std.ArrayList(u8).init(std.testing.allocator);
    defer sab_stderr.deinit();
    const sab_compiled = try compileSlaSabTestInput(arena.allocator(), "main.sla", sab_stderr.writer().any(), &.{}, false);
    if (sab_compiled) |compiled| {
        defer if (compiled.delete_after) std.fs.cwd().deleteFile(compiled.path) catch {};
        const sab_bytes = try std.fs.cwd().readFileAlloc(arena.allocator(), compiled.path, 10 * 1024 * 1024);
        var module = try sci_bridge.sab.decodeModule(std.testing.allocator, sab_bytes);
        defer module.deinit(std.testing.allocator);

        var saw_alias_sig = false;
        for (module.function_sigs) |fsig| {
            if (std.mem.indexOf(u8, fsig.name, "dep__imported_a") != null) saw_alias_sig = true;
        }
        try std.testing.expect(saw_alias_sig);

        const disasm = try sci_bridge.disasmSabAlloc(arena.allocator(), sab_bytes);
        try std.testing.expect(std.mem.indexOf(u8, disasm, "\"@sla__dep__imported_a\"") != null);
    } else {
        std.debug.print("{s}", .{sab_stderr.items});
        return error.TestUnexpectedResult;
    }
    try std.testing.expectEqual(@as(usize, 0), sab_stderr.items.len);
}

test "sla imported function aliases retain namespace metadata" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "dep.sla",
        .data =
        \\fn imported_a() -> i32 {
        \\    return 7;
        \\}
        ,
    });
    try tmp.dir.writeFile(.{
        .sub_path = "sibling.sla",
        .data =
        \\fn imported_a() -> i32 {
        \\    return 100;
        \\}
        ,
    });
    try tmp.dir.writeFile(.{
        .sub_path = "main.sla",
        .data =
        \\@import "dep.sla"
        \\@import "sibling.sla"
        \\
        \\fn main() -> i32 {
        \\    return dep::imported_a() + sibling::imported_a();
        \\}
        ,
    });

    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const main_source = try std.fs.cwd().readFileAlloc(allocator, "main.sla", 1024 * 1024);
    const expanded_main = try source_expand.expand(allocator, main_source);
    var parser = parser_mod.Parser.initWithDir(allocator, expanded_main, ".");
    const prog = try parser.parseProgram();

    var tc = type_checker_mod.TypeChecker.init(allocator);
    defer tc.deinit();
    try registerImportedFunctionAliases(&tc, allocator, prog, "main.sla");

    const dep_meta = tc.resolveFunctionAliasMetadata("dep__imported_a");
    const sibling_meta = tc.resolveFunctionAliasMetadata("sibling__imported_a");
    try std.testing.expect(dep_meta != null);
    try std.testing.expect(sibling_meta != null);
    try std.testing.expectEqualStrings("imported_a", tc.resolveFunctionAlias("dep__imported_a"));
    try std.testing.expectEqualStrings("imported_a", tc.resolveFunctionAlias("sibling__imported_a"));
    try std.testing.expectEqualStrings("dep", dep_meta.?.namespace.?);
    try std.testing.expectEqualStrings("sibling", sibling_meta.?.namespace.?);
    try std.testing.expect(dep_meta.?.module_path != null);
    try std.testing.expect(sibling_meta.?.module_path != null);
    try std.testing.expect(std.mem.endsWith(u8, dep_meta.?.module_path.?, "dep.sla"));
    try std.testing.expect(std.mem.endsWith(u8, sibling_meta.?.module_path.?, "sibling.sla"));

    const main_func = prog.program.decls[2].func_decl;
    const return_expr = main_func.body[0].return_stmt.value.?;
    const dep_call = return_expr.binary_expr.left;
    const sibling_call = return_expr.binary_expr.right;
    try tc.checkProgram(prog);
    try std.testing.expectEqualStrings("imported_a", tc.resolved_call_symbols.get(dep_call).?);
    try std.testing.expectEqualStrings("imported_a", tc.resolved_call_symbols.get(sibling_call).?);
    const dep_call_meta = tc.resolved_call_alias_metadata.get(dep_call);
    const sibling_call_meta = tc.resolved_call_alias_metadata.get(sibling_call);
    try std.testing.expect(dep_call_meta != null);
    try std.testing.expect(sibling_call_meta != null);
    try std.testing.expectEqualStrings("dep", dep_call_meta.?.namespace.?);
    try std.testing.expectEqualStrings("sibling", sibling_call_meta.?.namespace.?);
    try std.testing.expect(std.mem.endsWith(u8, dep_call_meta.?.module_path.?, "dep.sla"));
    try std.testing.expect(std.mem.endsWith(u8, sibling_call_meta.?.module_path.?, "sibling.sla"));
}

test "sla imported aliases reuse parsed module table" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "dep.sla",
        .data =
        \\fn imported_a() -> i32 {
        \\    return 7;
        \\}
        ,
    });
    try tmp.dir.writeFile(.{
        .sub_path = "main.sla",
        .data =
        \\@import "dep.sla"
        \\
        \\fn main() -> i32 {
        \\    return dep::imported_a();
        \\}
        ,
    });

    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const main_source = try std.fs.cwd().readFileAlloc(allocator, "main.sla", 1024 * 1024);
    const expanded_main = try source_expand.expand(allocator, main_source);
    var parser = parser_mod.Parser.initWithDir(allocator, expanded_main, ".");
    const prog = try parser.parseProgram();

    var import_modules = SlaModuleTable.init(allocator);
    defer import_modules.deinit();
    var root_import_groups = std.ArrayList(SlaResolvedImportGroup).init(allocator);
    defer root_import_groups.deinit();
    var contract_imports = std.ArrayList(ResolvedImport).init(allocator);
    defer contract_imports.deinit();
    var primary_decls = std.AutoHashMap(*const ast.Node, void).init(allocator);
    const expanded_prog = try expandSlaImportsWithModuleTable(allocator, prog, "main.sla", &primary_decls, .{}, &import_modules, &root_import_groups, &contract_imports);
    try std.testing.expect(expanded_prog.program.decls.len > 0);

    try tmp.dir.deleteFile("dep.sla");

    var tc = type_checker_mod.TypeChecker.init(allocator);
    defer tc.deinit();
    try registerImportedFunctionAliasesFromResolvedImports(&tc, allocator, root_import_groups.items, &import_modules);

    try std.testing.expectEqualStrings("imported_a", tc.resolveFunctionAlias("dep__imported_a"));
    try std.testing.expect(tc.imported_function_signatures.get("dep__imported_a") != null);
}

test "sla module namespace aliases isolate same named imported functions" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "dep.sla",
        .data =
        \\fn imported_a() -> i32 {
        \\    return 7;
        \\}
        ,
    });
    try tmp.dir.writeFile(.{
        .sub_path = "sibling.sla",
        .data =
        \\fn imported_a() -> i32 {
        \\    return 100;
        \\}
        ,
    });
    try tmp.dir.writeFile(.{
        .sub_path = "main.sla",
        .data =
        \\@import "dep.sla"
        \\@import "sibling.sla"
        \\
        \\@test "namespace import collision"() {
        \\    let got = dep::imported_a() + sibling::imported_a();
        \\    if got != 107 { panic(24014); };
        \\};
        ,
    });

    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var sa_stderr = std.ArrayList(u8).init(std.testing.allocator);
    defer sa_stderr.deinit();
    const sa_code = (try compileSlaToSaStringWithOptions(
        allocator,
        "main.sla",
        "main.test.sa",
        sa_stderr.writer().any(),
        .{ .prune_for_test_codegen = true },
    )) orelse {
        std.debug.print("{s}", .{sa_stderr.items});
        return error.TestUnexpectedResult;
    };
    try std.testing.expect(std.mem.indexOf(u8, sa_code, "sla__dep__imported_a") != null);
    try std.testing.expect(std.mem.indexOf(u8, sa_code, "sla__sibling__imported_a") != null);
    try std.testing.expect(std.mem.indexOf(u8, sa_code, "call @sla__dep__imported_a") != null);
    try std.testing.expect(std.mem.indexOf(u8, sa_code, "call @sla__sibling__imported_a") != null);
    try std.testing.expectEqual(@as(usize, 0), sa_stderr.items.len);

    var sab_stderr = std.ArrayList(u8).init(std.testing.allocator);
    defer sab_stderr.deinit();
    const sab_compiled = try compileSlaSabTestInput(allocator, "main.sla", sab_stderr.writer().any(), &.{}, false);
    if (sab_compiled) |compiled| {
        defer if (compiled.delete_after) std.fs.cwd().deleteFile(compiled.path) catch {};
        const sab_bytes = try std.fs.cwd().readFileAlloc(allocator, compiled.path, 10 * 1024 * 1024);
        var module = try sci_bridge.sab.decodeModule(std.testing.allocator, sab_bytes);
        defer module.deinit(std.testing.allocator);

        var saw_dep_sig = false;
        var saw_sibling_sig = false;
        for (module.function_sigs) |fsig| {
            if (std.mem.indexOf(u8, fsig.name, "dep__imported_a") != null) saw_dep_sig = true;
            if (std.mem.indexOf(u8, fsig.name, "sibling__imported_a") != null) saw_sibling_sig = true;
        }
        try std.testing.expect(saw_dep_sig);
        try std.testing.expect(saw_sibling_sig);

        const disasm = try sci_bridge.disasmSabAlloc(allocator, sab_bytes);
        try std.testing.expect(std.mem.indexOf(u8, disasm, "\"@sla__dep__imported_a\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, disasm, "\"@sla__sibling__imported_a\"") != null);
    } else {
        std.debug.print("{s}", .{sab_stderr.items});
        return error.TestUnexpectedResult;
    }
    try std.testing.expectEqual(@as(usize, 0), sab_stderr.items.len);
}

test "sla reachable collector records namespace alias call targets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ret_ty = ast.Type{ .primitive = .i32 };
    var tc = type_checker_mod.TypeChecker.init(allocator);
    defer tc.deinit();
    try tc.registerFunctionAliasWithMetadata("dep__imported_a", "imported_a", "dep", "/tmp/dep.sla");
    try tc.registerFunctionAliasWithMetadata("sibling__imported_a", "imported_a", "sibling", "/tmp/sibling.sla");
    try tc.registerImportedFunctionSignature("imported_a", &.{}, &ret_ty, false);

    var dep_call = ast.Node{ .call_expr = .{
        .func_name = "dep__imported_a",
        .associated_target = null,
        .generics = &.{},
        .args = &.{},
    } };
    var sibling_call = ast.Node{ .call_expr = .{
        .func_name = "sibling__imported_a",
        .associated_target = null,
        .generics = &.{},
        .args = &.{},
    } };
    var left_stmt = ast.Node{ .expr_stmt = &dep_call };
    var right_stmt = ast.Node{ .expr_stmt = &sibling_call };
    var test_node = ast.Node{ .test_decl = .{
        .name = "namespace alias reachability",
        .is_ignored = false,
        .should_panic = false,
        .body = &.{ &left_stmt, &right_stmt },
    } };
    var program = ast.Node{ .program = .{ .decls = &.{&test_node} } };
    try tc.checkProgram(&program);

    var reachable = std.StringHashMap(void).init(allocator);
    var worklist = std.ArrayList([]const u8).init(allocator);
    try collectReachableExpr(&tc, &reachable, &worklist, &dep_call);
    try collectReachableExpr(&tc, &reachable, &worklist, &sibling_call);

    try std.testing.expect(reachable.contains("dep__imported_a"));
    try std.testing.expect(reachable.contains("sibling__imported_a"));
    try std.testing.expect(!reachable.contains("imported_a"));
    try std.testing.expectEqual(@as(usize, 0), worklist.items.len);
}

test "sla module exports index records per-module function sources" {
    // The ModuleGraph foundation: SlaModuleExports must index each module's
    // exported symbols and SlaCallableIndex must record the owning module path
    // for every reachable callable, so future lazy typecheck can resolve calls
    // by module-qualified lookup instead of flattening every imported body.
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const dep_source =
        \\@import "child.sla"
        \\
        \\fn imported_a() -> i32 {
        \\    return imported_helper();
        \\};
        \\
        \\fn imported_helper() -> i32 {
        \\    return 7;
        \\};
        \\
        \\fn unreachable_import() -> i32 {
        \\    return 99;
        \\};
        \\
        \\const IMPORTED_VALUE: i32 = 9;
        \\
        \\macro imported_macro(value) {
        \\    return value;
        \\}
        \\
        \\struct ImportedTag {
        \\    value: i32,
        \\}
        \\
        \\impl ImportedTag {
        \\    fn tag_method(self) -> i32 {
        \\        return self.value;
        \\    }
        \\}
    ;
    const child_source =
        \\struct ChildExport {
        \\    value: i32,
        \\}
    ;
    const sibling_source =
        \\fn imported_a() -> i32 {
        \\    return 100;
        \\};
        \\
        \\struct ImportedTag {
        \\    value: i64,
        \\}
        \\
        \\const IMPORTED_VALUE: i32 = 100;
        \\
        \\macro imported_macro(value) {
        \\    return value;
        \\}
    ;
    const main_source =
        \\@import "dep.sla"
        \\@import "sibling.sla"
        \\
        \\@test "exports index path"() {
        \\    let got = imported_a();
        \\    if got != 7 { panic(24010); };
        \\};
    ;
    try tmp.dir.writeFile(.{ .sub_path = "child.sla", .data = child_source });
    try tmp.dir.writeFile(.{ .sub_path = "dep.sla", .data = dep_source });
    try tmp.dir.writeFile(.{ .sub_path = "sibling.sla", .data = sibling_source });
    try tmp.dir.writeFile(.{ .sub_path = "main.sla", .data = main_source });

    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const expanded_content = try source_expand.expand(allocator, main_source);
    var parser = parser_mod.Parser.initWithDir(allocator, expanded_content, ".");
    const prog = try parser.parseProgram();
    var primary_decls = std.AutoHashMap(*const ast.Node, void).init(allocator);
    const expanded_prog = try expandSlaImports(allocator, prog, "main.sla", &primary_decls, .{
        .prune_for_test_codegen = true,
    });

    // After expansion the reachable helper `imported_helper` and `imported_a`
    // from dep.sla must be present, while `unreachable_import` is pruned.
    var saw_a = false;
    var saw_helper = false;
    var saw_unreachable = false;
    for (expanded_prog.program.decls) |decl| {
        if (decl.* != .func_decl) continue;
        if (std.mem.eql(u8, decl.func_decl.name, "imported_a")) saw_a = true;
        if (std.mem.eql(u8, decl.func_decl.name, "imported_helper")) saw_helper = true;
        if (std.mem.eql(u8, decl.func_decl.name, "unreachable_import")) saw_unreachable = true;
    }
    try std.testing.expect(saw_a);
    try std.testing.expect(saw_helper);
    try std.testing.expect(!saw_unreachable);

    // Now verify the ModuleGraph foundation directly: build a SlaModuleTable,
    // parse dep.sla, and confirm exports.type_decls / function_decls capture
    // the right surface and SlaCallableIndex records per-symbol module source.
    const main_resolved = (try readImportFileIfExists(allocator, "main.sla")).?;
    const resolved_imports = try resolveImportFiles(allocator, ".", "dep.sla", "main.sla");
    const sibling_resolved_imports = try resolveImportFiles(allocator, ".", "sibling.sla", "main.sla");
    var modules = SlaModuleTable.init(allocator);
    defer modules.deinit();
    const main_module = try modules.getOrParse(main_resolved);
    var dep_module: ?*SlaModule = null;
    for (resolved_imports) |resolved| {
        if (!std.mem.endsWith(u8, resolved.path, ".sla")) continue;
        dep_module = try modules.getOrParse(resolved);
        break;
    }
    var sibling_module: ?*SlaModule = null;
    for (sibling_resolved_imports) |resolved| {
        if (!std.mem.endsWith(u8, resolved.path, ".sla")) continue;
        sibling_module = try modules.getOrParse(resolved);
        break;
    }
    try std.testing.expect(dep_module != null);
    try std.testing.expect(sibling_module != null);
    try std.testing.expectEqual(@as(usize, 2), main_module.resolved_module_imports.len);
    const dep = dep_module.?;
    const sibling = sibling_module.?;

    // SlaModuleExports indexes each module's exported surface by kind.
    try std.testing.expect(dep.exports.exportsFunction("imported_a"));
    try std.testing.expect(dep.exports.exportsFunction("imported_helper"));
    try std.testing.expect(dep.exports.exportsFunction("unreachable_import"));
    try std.testing.expect(dep.exports.exportsType("ImportedTag"));
    try std.testing.expect(dep.exports.exportsConst("IMPORTED_VALUE"));
    try std.testing.expect(dep.exports.exportsMacro("imported_macro"));
    try std.testing.expect(!dep.exports.exportsFunction("NotInDep"));

    const imported_type_sig = dep.exports.typeSignature("ImportedTag");
    try std.testing.expect(imported_type_sig != null);
    try std.testing.expect(std.mem.eql(u8, imported_type_sig.?.name, "ImportedTag"));
    try std.testing.expectEqual(SlaModuleExports.TypeKind.struct_decl, imported_type_sig.?.kind);
    try std.testing.expectEqual(@as(usize, 0), imported_type_sig.?.generics.len);
    try std.testing.expect(std.mem.eql(u8, imported_type_sig.?.module_path, dep.path));

    // Exported function signatures are indexed separately from bodies, giving
    // future lazy typecheck a signature surface to consult before opening a
    // reachable imported body.
    const imported_sig = dep.exports.functionSignature("imported_a");
    try std.testing.expect(imported_sig != null);
    try std.testing.expect(std.mem.eql(u8, imported_sig.?.name, "imported_a"));
    try std.testing.expectEqual(@as(usize, 0), imported_sig.?.params.len);
    try std.testing.expect(imported_sig.?.ret_ty.* == .primitive);
    try std.testing.expectEqual(ast.Primitive.i32, imported_sig.?.ret_ty.primitive);
    try std.testing.expect(!imported_sig.?.is_extern);
    try std.testing.expect(std.mem.eql(u8, imported_sig.?.module_path, dep.path));

    const imported_const_sig = dep.exports.constSignature("IMPORTED_VALUE");
    try std.testing.expect(imported_const_sig != null);
    try std.testing.expect(std.mem.eql(u8, imported_const_sig.?.name, "IMPORTED_VALUE"));
    try std.testing.expect(imported_const_sig.?.ty != null);
    try std.testing.expect(imported_const_sig.?.ty.?.* == .primitive);
    try std.testing.expectEqual(ast.Primitive.i32, imported_const_sig.?.ty.?.primitive);
    try std.testing.expect(std.mem.eql(u8, imported_const_sig.?.module_path, dep.path));

    const imported_macro_sig = dep.exports.macroSignature("imported_macro");
    try std.testing.expect(imported_macro_sig != null);
    try std.testing.expect(std.mem.eql(u8, imported_macro_sig.?.name, "imported_macro"));
    try std.testing.expectEqual(@as(usize, 1), imported_macro_sig.?.params.len);
    try std.testing.expect(std.mem.eql(u8, imported_macro_sig.?.params[0], "value"));
    try std.testing.expect(std.mem.eql(u8, imported_macro_sig.?.module_path, dep.path));

    const qualified_dep_fn = modules.functionSignature(dep.path, "imported_a");
    const qualified_sibling_fn = modules.functionSignature(sibling.path, "imported_a");
    try std.testing.expect(qualified_dep_fn != null);
    try std.testing.expect(qualified_sibling_fn != null);
    try std.testing.expect(std.mem.eql(u8, qualified_dep_fn.?.module_path, dep.path));
    try std.testing.expect(std.mem.eql(u8, qualified_sibling_fn.?.module_path, sibling.path));

    const qualified_dep_type = modules.typeSignature(dep.path, "ImportedTag");
    const qualified_sibling_type = modules.typeSignature(sibling.path, "ImportedTag");
    try std.testing.expect(qualified_dep_type != null);
    try std.testing.expect(qualified_sibling_type != null);
    try std.testing.expect(std.mem.eql(u8, qualified_dep_type.?.module_path, dep.path));
    try std.testing.expect(std.mem.eql(u8, qualified_sibling_type.?.module_path, sibling.path));

    const qualified_dep_const = modules.constSignature(dep.path, "IMPORTED_VALUE");
    const qualified_sibling_macro = modules.macroSignature(sibling.path, "imported_macro");
    try std.testing.expect(qualified_dep_const != null);
    try std.testing.expect(qualified_sibling_macro != null);
    try std.testing.expect(std.mem.eql(u8, qualified_dep_const.?.module_path, dep.path));
    try std.testing.expect(std.mem.eql(u8, qualified_sibling_macro.?.module_path, sibling.path));

    const dep_namespace_import = modules.moduleImportByNamespace(main_module.path, "dep");
    const sibling_namespace_import = modules.moduleImportByNamespace(main_module.path, "sibling");
    try std.testing.expect(dep_namespace_import != null);
    try std.testing.expect(sibling_namespace_import != null);
    try std.testing.expect(std.mem.eql(u8, dep_namespace_import.?.resolved.path, dep.path));
    try std.testing.expect(std.mem.eql(u8, sibling_namespace_import.?.resolved.path, sibling.path));

    const namespace_dep_fn = try modules.functionSignatureForImportNamespace(main_module.path, "dep", "imported_a");
    const namespace_sibling_fn = try modules.functionSignatureForImportNamespace(main_module.path, "sibling", "imported_a");
    try std.testing.expect(namespace_dep_fn != null);
    try std.testing.expect(namespace_sibling_fn != null);
    try std.testing.expect(std.mem.eql(u8, namespace_dep_fn.?.module_path, dep.path));
    try std.testing.expect(std.mem.eql(u8, namespace_sibling_fn.?.module_path, sibling.path));

    const namespace_dep_type = try modules.typeSignatureForImportNamespace(main_module.path, "dep", "ImportedTag");
    const namespace_sibling_const = try modules.constSignatureForImportNamespace(main_module.path, "sibling", "IMPORTED_VALUE");
    const namespace_dep_macro = try modules.macroSignatureForImportNamespace(main_module.path, "dep", "imported_macro");
    try std.testing.expect(namespace_dep_type != null);
    try std.testing.expect(namespace_sibling_const != null);
    try std.testing.expect(namespace_dep_macro != null);
    try std.testing.expect(std.mem.eql(u8, namespace_dep_type.?.module_path, dep.path));
    try std.testing.expect(std.mem.eql(u8, namespace_sibling_const.?.module_path, sibling.path));
    try std.testing.expect(std.mem.eql(u8, namespace_dep_macro.?.module_path, dep.path));

    const mangled_dep_fn = try modules.functionSignatureForImportedMangledName(main_module.path, "dep__imported_a");
    const mangled_sibling_fn = try modules.functionSignatureForImportedMangledName(main_module.path, "sibling__imported_a");
    try std.testing.expect(mangled_dep_fn != null);
    try std.testing.expect(mangled_sibling_fn != null);
    try std.testing.expect(std.mem.eql(u8, mangled_dep_fn.?.module_path, dep.path));
    try std.testing.expect(std.mem.eql(u8, mangled_sibling_fn.?.module_path, sibling.path));
    try std.testing.expect(try modules.functionSignatureForImportedMangledName(main_module.path, "imported_a") == null);

    // The module table stores the module graph directly, so later traversal
    // does not need to rediscover child imports by rescanning dep's AST.
    var saw_child_import = false;
    for (dep.resolved_imports) |child_resolved| {
        if (std.mem.endsWith(u8, child_resolved.path, "child.sla")) saw_child_import = true;
    }
    try std.testing.expect(saw_child_import);

    // SlaCallableIndex must attribute each callable symbol to its owning
    // module path, which is the namespace-qualified resolution primitive the
    // future lazy traversal needs to avoid re-flattening every imported body.
    var callable_index = SlaCallableIndex.init(allocator);
    defer callable_index.deinit();
    try callable_index.addDeclsFromModule(dep.program.program.decls, dep);
    try callable_index.addDeclsFromModule(sibling.program.program.decls, sibling);

    const dep_a_source = callable_index.moduleSource("imported_a");
    const dep_helper_source = callable_index.moduleSource("imported_helper");
    const dep_unreachable_source = callable_index.moduleSource("unreachable_import");
    const dep_alias_source = callable_index.moduleSource("dep__imported_a");
    const sibling_alias_source = callable_index.moduleSource("sibling__imported_a");
    try std.testing.expect(dep_a_source != null);
    try std.testing.expect(dep_helper_source != null);
    try std.testing.expect(dep_unreachable_source != null);
    try std.testing.expect(dep_alias_source != null);
    try std.testing.expect(sibling_alias_source != null);
    try std.testing.expect(std.mem.eql(u8, dep_a_source.?, dep.path));
    try std.testing.expect(std.mem.eql(u8, dep_helper_source.?, dep.path));
    try std.testing.expect(std.mem.eql(u8, dep_unreachable_source.?, dep.path));
    try std.testing.expect(std.mem.eql(u8, dep_alias_source.?, dep.path));
    try std.testing.expect(std.mem.eql(u8, sibling_alias_source.?, sibling.path));
    const dep_alias_decl = callable_index.decls.get("dep__imported_a");
    const sibling_alias_decl = callable_index.decls.get("sibling__imported_a");
    try std.testing.expect(dep_alias_decl != null);
    try std.testing.expect(sibling_alias_decl != null);
    try std.testing.expect(std.mem.eql(u8, dep_alias_decl.?.body[0].return_stmt.value.?.call_expr.func_name, "imported_helper"));
    try std.testing.expectEqual(@as(i64, 100), sibling_alias_decl.?.body[0].return_stmt.value.?.literal.int_val);

    // Inherent method `ImportedTag_tag_method` should also attribute its owning
    // module path through the associated-method registration path.
    const tag_method_source = callable_index.moduleSource("ImportedTag_tag_method");
    try std.testing.expect(tag_method_source != null);
    try std.testing.expect(std.mem.eql(u8, tag_method_source.?, dep.path));
}

test "sla module table resolves imported function bodies by module and namespace" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "dep.sla",
        .data =
        \\trait Label {
        \\    fn label(self) -> i32;
        \\}
        \\
        \\struct ImportedThing {
        \\    value: i32,
        \\}
        \\
        \\fn imported_value() -> i32 {
        \\    return 41;
        \\}
        \\
        \\impl ImportedThing {
        \\    fn inherent(self) -> i32 {
        \\        return self.value;
        \\    }
        \\}
        \\
        \\impl Label for ImportedThing {
        \\    fn label(self) -> i32 {
        \\        return self.value + 1;
        \\    }
        \\}
        ,
    });
    try tmp.dir.writeFile(.{
        .sub_path = "sibling.sla",
        .data =
        \\fn imported_value() -> i32 {
        \\    return 100;
        \\}
        ,
    });
    try tmp.dir.writeFile(.{
        .sub_path = "main.sla",
        .data =
        \\@import "dep.sla"
        \\@import "sibling.sla"
        \\
        \\fn main() -> i32 {
        \\    return dep::imported_value();
        \\}
        ,
    });

    const dep_source = try tmp.dir.readFileAlloc(allocator, "dep.sla", 1024 * 1024);
    const sibling_source = try tmp.dir.readFileAlloc(allocator, "sibling.sla", 1024 * 1024);
    const main_source = try tmp.dir.readFileAlloc(allocator, "main.sla", 1024 * 1024);
    const cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
    const dep_path = try tmp.dir.realpathAlloc(allocator, "dep.sla");
    const sibling_path = try tmp.dir.realpathAlloc(allocator, "sibling.sla");
    const main_path = try tmp.dir.realpathAlloc(allocator, "main.sla");
    const main_dir = std.fs.path.dirname(main_path) orelse cwd;

    const expanded_main = try source_expand.expand(allocator, main_source);
    var parser = parser_mod.Parser.initWithDir(allocator, expanded_main, main_dir);
    const main_prog = try parser.parseProgram();

    var modules = SlaModuleTable.init(allocator);
    defer modules.deinit();
    const dep_module = try modules.getOrParse(.{
        .path = dep_path,
        .output_path = "dep.sla",
        .source = dep_source,
    });
    const sibling_module = try modules.getOrParse(.{
        .path = sibling_path,
        .output_path = "sibling.sla",
        .source = sibling_source,
    });
    _ = try modules.getOrParse(.{
        .path = main_path,
        .output_path = "main.sla",
        .source = main_source,
    });

    const top_body = modules.functionBody(dep_module.path, "imported_value");
    try std.testing.expect(top_body != null);
    try std.testing.expect(!top_body.?.is_decl_only);
    try std.testing.expectEqual(@as(usize, 1), top_body.?.body.len);

    const inherent_symbol = try lowering_rules.mangleMethodName(allocator, "ImportedThing", "inherent");
    const inherent_body = modules.associatedFunctionBody(dep_module.path, inherent_symbol);
    try std.testing.expect(inherent_body != null);
    try std.testing.expect(!inherent_body.?.is_decl_only);
    try std.testing.expectEqual(@as(usize, 1), inherent_body.?.body.len);

    const trait_symbol = try lowering_rules.mangleTraitMethodName(allocator, "ImportedThing", "Label", "label");
    const trait_body = modules.associatedFunctionBody(dep_module.path, trait_symbol);
    try std.testing.expect(trait_body != null);
    try std.testing.expect(!trait_body.?.is_decl_only);
    try std.testing.expectEqual(@as(usize, 1), trait_body.?.body.len);

    const namespace_body = try modules.functionBodyForImportNamespace(main_path, "dep", "imported_value");
    try std.testing.expect(namespace_body != null);
    try std.testing.expect(std.mem.eql(u8, namespace_body.?.name, "imported_value"));

    const imported_symbol_body = try modules.functionBodyForImportedMangledName(main_path, "dep__imported_value");
    try std.testing.expect(imported_symbol_body != null);
    try std.testing.expect(std.mem.eql(u8, imported_symbol_body.?.name, "imported_value"));

    var reachable = std.StringHashMap(void).init(allocator);
    var referenced_types = std.StringHashMap(void).init(allocator);
    var emitted = std.StringHashMap(void).init(allocator);
    var primary_decls = std.AutoHashMap(*const ast.Node, void).init(allocator);
    var out_decls = std.ArrayList(*ast.Node).init(allocator);
    try reachable.put("sibling__imported_value", {});
    try appendModuleDeclsSelective(allocator, &modules, sibling_module, &emitted, &primary_decls, &out_decls, &reachable, &referenced_types, .{}, null);

    var saw_sibling_body = false;
    var saw_dep_body = false;
    for (out_decls.items) |decl| {
        if (decl.* != .func_decl) continue;
        if (std.mem.eql(u8, decl.func_decl.name, "sibling__imported_value")) {
            const ret = decl.func_decl.body[0].return_stmt.value.?;
            if (ret.* == .literal and ret.literal == .int_val and ret.literal.int_val == 100) saw_sibling_body = true;
            if (ret.* == .literal and ret.literal == .int_val and ret.literal.int_val == 41) saw_dep_body = true;
        }
    }
    try std.testing.expect(saw_sibling_body);
    try std.testing.expect(!saw_dep_body);

    try std.testing.expect(try modules.functionBodyForImportNamespace(main_path, "missing", "imported_value") == null);
    try std.testing.expect(try modules.functionBodyForImportedMangledName(main_path, "imported_value") == null);
    try std.testing.expect(modules.functionBody(dep_module.path, "missing") == null);
    try std.testing.expect(modules.associatedFunctionBody(dep_module.path, "ImportedThing_missing") == null);
    try std.testing.expect(main_prog.* == .program);
}

test "sla module table skips imported test body parsing" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "dep.sla",
        .data =
        \\@test "imported test body is not parsed"() {
        \\    let = ;
        \\}
        \\
        \\fn imported_value() -> i32 {
        \\    return 42;
        \\}
        ,
    });
    try tmp.dir.writeFile(.{
        .sub_path = "main.sla",
        .data =
        \\@import "dep.sla"
        \\
        \\fn main() -> i32 {
        \\    return dep::imported_value();
        \\}
        ,
    });

    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const main_source = try std.fs.cwd().readFileAlloc(allocator, "main.sla", 1024 * 1024);
    const expanded_main = try source_expand.expand(allocator, main_source);
    var parser = parser_mod.Parser.initWithDir(allocator, expanded_main, ".");
    const prog = try parser.parseProgram();

    var import_modules = SlaModuleTable.init(allocator);
    defer import_modules.deinit();
    var root_import_groups = std.ArrayList(SlaResolvedImportGroup).init(allocator);
    defer root_import_groups.deinit();
    var contract_imports = std.ArrayList(ResolvedImport).init(allocator);
    defer contract_imports.deinit();
    var primary_decls = std.AutoHashMap(*const ast.Node, void).init(allocator);
    const expanded_prog = try expandSlaImportsWithModuleTable(allocator, prog, "main.sla", &primary_decls, .{}, &import_modules, &root_import_groups, &contract_imports);

    var saw_test_decl = false;
    var saw_imported_value = false;
    for (expanded_prog.program.decls) |decl| {
        if (decl.* == .test_decl) saw_test_decl = true;
        if (decl.* == .func_decl and std.mem.eql(u8, decl.func_decl.name, "dep__imported_value")) saw_imported_value = true;
    }
    try std.testing.expect(!saw_test_decl);
    try std.testing.expect(saw_imported_value);
}

test "sla module table skips non contributing imported module bodies" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const used_source =
        \\fn used_value() -> i32 {
        \\    return used_helper();
        \\};
        \\
        \\fn used_helper() -> i32 {
        \\    return 42;
        \\};
    ;
    const unused_source =
        \\struct UnusedTag {
        \\    value: i32,
        \\}
        \\
        \\fn unused_bad() -> MissingType {
        \\    return nope();
        \\};
    ;
    const main_source =
        \\@import "used.sla"
        \\@import "unused.sla"
        \\
        \\@test "selective modules"() {
        \\    let got = used_value();
        \\    if got != 42 { panic(24011); };
        \\};
    ;
    try tmp.dir.writeFile(.{ .sub_path = "used.sla", .data = used_source });
    try tmp.dir.writeFile(.{ .sub_path = "unused.sla", .data = unused_source });
    try tmp.dir.writeFile(.{ .sub_path = "main.sla", .data = main_source });

    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const expanded_content = try source_expand.expand(allocator, main_source);
    var parser = parser_mod.Parser.initWithDir(allocator, expanded_content, ".");
    const prog = try parser.parseProgram();
    var primary_decls = std.AutoHashMap(*const ast.Node, void).init(allocator);
    const expanded_prog = try expandSlaImports(allocator, prog, "main.sla", &primary_decls, .{
        .prune_for_test_codegen = true,
    });

    var saw_used = false;
    var saw_helper = false;
    var saw_unused_fn = false;
    var saw_unused_type = false;
    for (expanded_prog.program.decls) |decl| {
        switch (decl.*) {
            .func_decl => |fd| {
                if (std.mem.eql(u8, fd.name, "used_value")) saw_used = true;
                if (std.mem.eql(u8, fd.name, "used_helper")) saw_helper = true;
                if (std.mem.eql(u8, fd.name, "unused_bad")) saw_unused_fn = true;
            },
            .struct_decl => |sd| {
                if (std.mem.eql(u8, sd.name, "UnusedTag")) saw_unused_type = true;
            },
            else => {},
        }
    }
    try std.testing.expect(saw_used);
    try std.testing.expect(saw_helper);
    try std.testing.expect(!saw_unused_fn);
    try std.testing.expect(!saw_unused_type);

    var compile_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer compile_arena.deinit();
    var stderr_buf = std.ArrayList(u8).init(compile_arena.allocator());
    defer stderr_buf.deinit();
    const compiled = try compileSlaSaTestInput(
        compile_arena.allocator(),
        "main.sla",
        stderr_buf.writer().any(),
        &.{},
        false,
    );
    if (compiled) |result| {
        if (result.delete_after) std.fs.cwd().deleteFile(result.path) catch {};
    }
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
}

test "sla module table selective flatten in non test compile path" {
    // Non-test compile path (prune_for_test_codegen = false): the root program
    // has a function that calls into used.sla, but unused.sla contains a broken
    // function referencing MissingType. Selective flattening must omit unused.sla's
    // body so the broken function never reaches TypeChecker, while used.sla's
    // reachable functions are flattened normally.
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const used_source =
        \\fn used_value() -> i32 {
        \\    return used_helper();
        \\};
        \\
        \\fn used_helper() -> i32 {
        \\    return 42;
        \\};
    ;
    const unused_source =
        \\fn unused_bad() -> MissingType {
        \\    return nope();
        \\};
    ;
    const main_source =
        \\@import "used.sla"
        \\@import "unused.sla"
        \\
        \\fn entry() -> i32 {
        \\    return used_value();
        \\};
    ;
    try tmp.dir.writeFile(.{ .sub_path = "used.sla", .data = used_source });
    try tmp.dir.writeFile(.{ .sub_path = "unused.sla", .data = unused_source });
    try tmp.dir.writeFile(.{ .sub_path = "main.sla", .data = main_source });

    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const expanded_content = try source_expand.expand(allocator, main_source);
    var parser = parser_mod.Parser.initWithDir(allocator, expanded_content, ".");
    const prog = try parser.parseProgram();
    var primary_decls = std.AutoHashMap(*const ast.Node, void).init(allocator);
    const expanded_prog = try expandSlaImports(allocator, prog, "main.sla", &primary_decls, .{
        .prune_for_test_codegen = false,
    });

    var saw_entry = false;
    var saw_used = false;
    var saw_helper = false;
    var saw_unused = false;
    for (expanded_prog.program.decls) |decl| {
        if (decl.* != .func_decl) continue;
        const name = decl.func_decl.name;
        if (std.mem.eql(u8, name, "entry")) saw_entry = true;
        if (std.mem.eql(u8, name, "used_value")) saw_used = true;
        if (std.mem.eql(u8, name, "used_helper")) saw_helper = true;
        if (std.mem.eql(u8, name, "unused_bad")) saw_unused = true;
    }
    try std.testing.expect(saw_entry);
    try std.testing.expect(saw_used);
    try std.testing.expect(saw_helper);
    // unused.sla is non-contributing: its broken function must NOT be flattened.
    try std.testing.expect(!saw_unused);
}

test "sla build codegen uses registry loaded imported bodies" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const dep_source =
        \\trait Label {
        \\    fn label(self) -> i32;
        \\    fn unused_trait(self) -> i32;
        \\}
        \\
        \\struct ImportedThing {
        \\    value: i32,
        \\}
        \\
        \\fn imported_value() -> i32 {
        \\    return 69;
        \\}
        \\
        \\fn unused_bad() -> MissingType {
        \\    return nope();
        \\}
        \\
        \\impl ImportedThing {
        \\    fn used(self) -> i32 {
        \\        return self.value;
        \\    }
        \\}
        \\
        \\impl Label for ImportedThing {
        \\    fn label(self) -> i32 {
        \\        return self.value + 1;
        \\    }
        \\
        \\    fn unused_trait(self) -> i32 {
        \\        return missing_trait_body();
        \\    }
        \\}
    ;
    const main_source =
        \\@import "dep.sla"
        \\
        \\fn entry() -> i32 {
        \\    let item = ImportedThing { value: imported_value() };
        \\    return item.used() + item.label();
        \\}
    ;
    try tmp.dir.writeFile(.{ .sub_path = "dep.sla", .data = dep_source });
    try tmp.dir.writeFile(.{ .sub_path = "main.sla", .data = main_source });

    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var sa_stderr = std.ArrayList(u8).init(std.testing.allocator);
    defer sa_stderr.deinit();
    const sa_code = (try compileSlaToSaString(allocator, "main.sla", "main.sa", sa_stderr.writer().any())) orelse {
        std.debug.print("{s}", .{sa_stderr.items});
        return error.TestUnexpectedResult;
    };
    try std.testing.expect(std.mem.indexOf(u8, sa_code, "sla__imported_value") != null);
    try std.testing.expect(std.mem.indexOf(u8, sa_code, "ImportedThing_used") != null);
    try std.testing.expect(std.mem.indexOf(u8, sa_code, "ImportedThing__Label_label") != null);
    try std.testing.expect(std.mem.indexOf(u8, sa_code, "unused_bad") == null);
    try std.testing.expect(std.mem.indexOf(u8, sa_code, "missing_trait_body") == null);
    try std.testing.expectEqual(@as(usize, 0), sa_stderr.items.len);

    var sab_stderr = std.ArrayList(u8).init(std.testing.allocator);
    defer sab_stderr.deinit();
    const sab_bytes = (try compileSlaFileToSab(allocator, "main.sla", ".sla-cache/sab/main.sab", sab_stderr.writer().any())) orelse {
        std.debug.print("{s}", .{sab_stderr.items});
        return error.TestUnexpectedResult;
    };
    var module = try sci_bridge.sab.decodeModule(std.testing.allocator, sab_bytes);
    defer module.deinit(std.testing.allocator);

    var saw_value = false;
    var saw_used = false;
    var saw_label = false;
    var saw_unused_bad = false;
    var saw_unused_trait = false;
    for (module.function_sigs) |fsig| {
        if (std.mem.indexOf(u8, fsig.name, "imported_value") != null) saw_value = true;
        if (std.mem.indexOf(u8, fsig.name, "ImportedThing_used") != null) saw_used = true;
        if (std.mem.indexOf(u8, fsig.name, "ImportedThing__Label_label") != null) saw_label = true;
        if (std.mem.indexOf(u8, fsig.name, "unused_bad") != null) saw_unused_bad = true;
        if (std.mem.indexOf(u8, fsig.name, "unused_trait") != null) saw_unused_trait = true;
    }
    try std.testing.expect(saw_value);
    try std.testing.expect(saw_used);
    try std.testing.expect(saw_label);
    try std.testing.expect(!saw_unused_bad);
    try std.testing.expect(!saw_unused_trait);
    try std.testing.expectEqual(@as(usize, 0), sab_stderr.items.len);
}

test "sla build codegen keeps imported dyn trait impl bodies from registry" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const dep_source =
        \\trait Identified {
        \\    fn get_id(&self) -> i32;
        \\    fn unused_dyn(&self) -> i32;
        \\}
        \\
        \\struct ImportedThing {
        \\    id: i32,
        \\}
        \\
        \\impl Identified for ImportedThing {
        \\    fn get_id(&self) -> i32 {
        \\        return self.id;
        \\    }
        \\
        \\    fn unused_dyn(&self) -> i32 {
        \\        return missing_dyn_body();
        \\    }
        \\}
    ;
    const main_source =
        \\@import "sa_std/core/box.sa"
        \\@import "sa_std/core/trait_object.sa"
        \\@import "dep.sla"
        \\
        \\fn entry() -> i32 {
        \\    let obj: Box<dyn Identified> = Box::new(ImportedThing { id: 74 });
        \\    return obj.get_id();
        \\}
    ;
    try tmp.dir.writeFile(.{ .sub_path = "dep.sla", .data = dep_source });
    try tmp.dir.writeFile(.{ .sub_path = "main.sla", .data = main_source });

    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var sa_stderr = std.ArrayList(u8).init(std.testing.allocator);
    defer sa_stderr.deinit();
    const sa_code = (try compileSlaToSaString(allocator, "main.sla", "main.sa", sa_stderr.writer().any())) orelse {
        std.debug.print("{s}", .{sa_stderr.items});
        return error.TestUnexpectedResult;
    };
    try std.testing.expect(std.mem.indexOf(u8, sa_code, "ImportedThing__Identified_get_id") != null);
    try std.testing.expect(std.mem.indexOf(u8, sa_code, "missing_dyn_body") == null);
    try std.testing.expectEqual(@as(usize, 0), sa_stderr.items.len);

    var sab_stderr = std.ArrayList(u8).init(std.testing.allocator);
    defer sab_stderr.deinit();
    const sab_bytes = (try compileSlaFileToSab(allocator, "main.sla", ".sla-cache/sab/main.sab", sab_stderr.writer().any())) orelse {
        std.debug.print("{s}", .{sab_stderr.items});
        return error.TestUnexpectedResult;
    };
    var module = try sci_bridge.sab.decodeModule(std.testing.allocator, sab_bytes);
    defer module.deinit(std.testing.allocator);

    var saw_get_id = false;
    var saw_unused_dyn = false;
    for (module.function_sigs) |fsig| {
        if (std.mem.indexOf(u8, fsig.name, "ImportedThing__Identified_get_id") != null) saw_get_id = true;
        if (std.mem.indexOf(u8, fsig.name, "unused_dyn") != null) saw_unused_dyn = true;
    }
    try std.testing.expect(saw_get_id);
    try std.testing.expect(!saw_unused_dyn);
    try std.testing.expectEqual(@as(usize, 0), sab_stderr.items.len);
}

test "sla build codegen skips parsing non contributing imported function bodies" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const used_source =
        \\fn used_value() -> i32 {
        \\    return 42;
        \\}
    ;
    const dead_source =
        \\fn unused_bad() -> i32 {
        \\    let = ;
        \\}
    ;
    const main_source =
        \\@import "used.sla"
        \\@import "dead.sla"
        \\
        \\fn entry() -> i32 {
        \\    return used::used_value();
        \\}
    ;
    try tmp.dir.writeFile(.{ .sub_path = "used.sla", .data = used_source });
    try tmp.dir.writeFile(.{ .sub_path = "dead.sla", .data = dead_source });
    try tmp.dir.writeFile(.{ .sub_path = "main.sla", .data = main_source });

    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();
    const sa_code = (try compileSlaToSaString(allocator, "main.sla", "main.sa", stderr_buf.writer().any())) orelse {
        std.debug.print("{s}", .{stderr_buf.items});
        return error.TestUnexpectedResult;
    };
    try std.testing.expect(std.mem.indexOf(u8, sa_code, "sla__used__used_value") != null);
    try std.testing.expect(std.mem.indexOf(u8, sa_code, "unused_bad") == null);
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
}

test "sla test codegen materializes reachable bodies in contributing module" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const dep_source =
        \\fn selected_value() -> i32 {
        \\    return selected_helper();
        \\}
        \\
        \\fn selected_helper() -> i32 {
        \\    return 42;
        \\}
        \\
        \\fn unused_invalid() -> i32 {
        \\    let = ;
        \\}
        \\
        \\struct ImportedThing {
        \\    value: i32,
        \\}
        \\
        \\impl ImportedThing {
        \\    fn selected(self) -> i32 {
        \\        return self.value;
        \\    }
        \\
        \\    fn unused_method_invalid(self) -> i32 {
        \\        let = ;
        \\    }
        \\}
    ;
    const main_source =
        \\@import "dep.sla"
        \\
        \\@test "selected imported bodies"() {
        \\    let item = ImportedThing { value: 42 };
        \\    if dep::selected_value() != 42 { panic(42042); };
        \\    if item.selected() != 42 { panic(42043); };
        \\}
    ;
    try tmp.dir.writeFile(.{ .sub_path = "dep.sla", .data = dep_source });
    try tmp.dir.writeFile(.{ .sub_path = "main.sla", .data = main_source });

    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();
    const sa_code = (try compileSlaToSaStringWithOptions(
        allocator,
        "main.sla",
        "main.test.sa",
        stderr_buf.writer().any(),
        .{
            .test_filter = "selected imported bodies",
            .prune_for_test_codegen = true,
            .load_reachable_imported_bodies_from_registry = true,
        },
    )) orelse {
        std.debug.print("{s}", .{stderr_buf.items});
        return error.TestUnexpectedResult;
    };
    try std.testing.expect(std.mem.indexOf(u8, sa_code, "sla__dep__selected_value") != null);
    try std.testing.expect(std.mem.indexOf(u8, sa_code, "sla__dep__selected_helper") != null);
    try std.testing.expect(std.mem.indexOf(u8, sa_code, "ImportedThing_selected") != null);
    try std.testing.expect(std.mem.indexOf(u8, sa_code, "unused_invalid") == null);
    try std.testing.expect(std.mem.indexOf(u8, sa_code, "unused_method_invalid") == null);
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
}

test "sla sab test codegen materializes reachable bodies in contributing module" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const dep_source =
        \\fn selected_value() -> i32 {
        \\    return selected_helper();
        \\}
        \\
        \\fn selected_helper() -> i32 {
        \\    return 42;
        \\}
        \\
        \\fn unused_invalid() -> i32 {
        \\    let = ;
        \\}
        \\
        \\struct ImportedThing {
        \\    value: i32,
        \\}
        \\
        \\impl ImportedThing {
        \\    fn selected(self) -> i32 {
        \\        return self.value;
        \\    }
        \\
        \\    fn unused_method_invalid(self) -> i32 {
        \\        let = ;
        \\    }
        \\}
    ;
    const main_source =
        \\@import "dep.sla"
        \\
        \\@test "selected imported bodies"() {
        \\    let item = ImportedThing { value: 42 };
        \\    if dep::selected_value() != 42 { panic(42042); };
        \\    if item.selected() != 42 { panic(42043); };
        \\}
    ;
    try tmp.dir.writeFile(.{ .sub_path = "dep.sla", .data = dep_source });
    try tmp.dir.writeFile(.{ .sub_path = "main.sla", .data = main_source });

    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();
    const sab_bytes = (try compileSlaFileToSabWithOptions(
        allocator,
        "main.sla",
        ".sla-cache/sab/selective_imported_bodies.sab",
        stderr_buf.writer().any(),
        .{
            .test_filter = "selected imported bodies",
            .prune_for_test_codegen = true,
            .load_reachable_imported_bodies_from_registry = true,
            .allow_fallback = false,
        },
    )) orelse {
        std.debug.print("{s}", .{stderr_buf.items});
        return error.TestUnexpectedResult;
    };
    var sab_module = try sci_bridge.sab.decodeModule(std.testing.allocator, sab_bytes);
    defer sab_module.deinit(std.testing.allocator);
    var saw_selected_value = false;
    var saw_selected_method = false;
    var saw_unused_body = false;
    for (sab_module.function_sigs) |sig| {
        if (std.mem.indexOf(u8, sig.name, "dep__selected_value") != null) saw_selected_value = true;
        if (std.mem.indexOf(u8, sig.name, "ImportedThing_selected") != null) saw_selected_method = true;
        if (std.mem.indexOf(u8, sig.name, "unused_invalid") != null or
            std.mem.indexOf(u8, sig.name, "unused_method_invalid") != null) saw_unused_body = true;
    }
    try std.testing.expect(saw_selected_value);
    try std.testing.expect(saw_selected_method);
    try std.testing.expect(!saw_unused_body);
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
}

test "sla test codegen materializes reachable macro bodies in contributing module" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const dep_source =
        \\macro ADD_ONE(value) {
        \\    value = value + 1;
        \\}
        \\
        \\macro UNUSED_BAD(value) {
        \\    let = ;
        \\}
        \\
        \\fn selected_value() -> i32 {
        \\    let value = 41;
        \\    ADD_ONE(value);
        \\    return value;
        \\}
    ;
    const main_source =
        \\@import "dep.sla"
        \\
        \\@test "selected imported macro body"() {
        \\    if dep::selected_value() != 42 { panic(42045); };
        \\}
    ;
    try tmp.dir.writeFile(.{ .sub_path = "dep.sla", .data = dep_source });
    try tmp.dir.writeFile(.{ .sub_path = "main.sla", .data = main_source });

    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();
    const sa_code = (try compileSlaToSaStringWithOptions(
        allocator,
        "main.sla",
        "main.test.sa",
        stderr_buf.writer().any(),
        .{
            .test_filter = "selected imported macro body",
            .prune_for_test_codegen = true,
            .load_reachable_imported_bodies_from_registry = true,
        },
    )) orelse {
        std.debug.print("{s}", .{stderr_buf.items});
        return error.TestUnexpectedResult;
    };
    try std.testing.expect(std.mem.indexOf(u8, sa_code, "sla__dep__selected_value") != null);
    try std.testing.expect(std.mem.indexOf(u8, sa_code, "add value,") != null);
    try std.testing.expect(std.mem.indexOf(u8, sa_code, "UNUSED_BAD") == null);
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
}

test "sla reachability incrementally extends newly materialized body chains" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const dep_source =
        \\fn first() -> i32 {
        \\    return second();
        \\}
        \\fn second() -> i32 {
        \\    return third();
        \\}
        \\fn third() -> i32 {
        \\    return 42;
        \\}
    ;
    const main_source =
        \\@import "dep.sla"
        \\
        \\@test "incremental materialized chain"() {
        \\    if dep::first() != 42 { panic(42048); };
        \\}
    ;
    try tmp.dir.writeFile(.{ .sub_path = "dep.sla", .data = dep_source });
    try tmp.dir.writeFile(.{ .sub_path = "main.sla", .data = main_source });

    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const expanded_content = try source_expand.expand(allocator, main_source);
    var parser = parser_mod.Parser.initWithDir(allocator, expanded_content, ".");
    const prog = try parser.parseProgram();

    var modules = SlaModuleTable.initWithParserOptions(allocator, .{
        .parse_function_bodies = false,
        .parse_macro_bodies = false,
        .parse_test_bodies = false,
    });
    defer modules.deinit();
    const resolved_imports = try resolveImportFiles(allocator, ".", "dep.sla", "main.sla");
    const module = try modules.getOrParse(resolved_imports[0]);
    var reachable = std.StringHashMap(void).init(allocator);
    defer reachable.deinit();
    var referenced_types = std.StringHashMap(void).init(allocator);
    defer referenced_types.deinit();

    const stats = try buildAndMaterializeReachableImportedModuleBodies(
        allocator,
        prog,
        &.{module},
        &modules,
        .{
            .prune_for_test_codegen = true,
            .test_filter = "incremental materialized chain",
            .imported_bodies_decl_only = true,
            .load_reachable_imported_bodies_from_registry = true,
        },
        null,
        &reachable,
        &referenced_types,
    );
    try std.testing.expectEqual(@as(usize, 3), stats.reparses);
    try std.testing.expectEqual(@as(usize, 3), stats.incremental_extensions);
    try std.testing.expectEqual(@as(usize, 4), stats.passes);
    try std.testing.expect(module.parsed_function_bodies.contains("first"));
    try std.testing.expect(module.parsed_function_bodies.contains("second"));
    try std.testing.expect(module.parsed_function_bodies.contains("third"));
    try std.testing.expect(reachable.contains("dep__first"));
    try std.testing.expect(reachable.contains("dep__second"));
    try std.testing.expect(reachable.contains("dep__third"));
}

test "sla module table reparses with cached imported type names" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const child_source =
        \\struct ImportedThing { value: i32 }
    ;
    const dep_source =
        \\@import "child.sla"
        \\fn make_imported() -> ImportedThing {
        \\    return ImportedThing { value: 42 };
        \\}
    ;
    try tmp.dir.writeFile(.{ .sub_path = "child.sla", .data = child_source });
    try tmp.dir.writeFile(.{ .sub_path = "dep.sla", .data = dep_source });
    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var modules = SlaModuleTable.initWithParserOptions(allocator, .{
        .parse_function_bodies = false,
        .parse_macro_bodies = false,
        .parse_test_bodies = false,
    });
    defer modules.deinit();
    const imports = try resolveImportFiles(allocator, ".", "dep.sla", "main.sla");
    const dep = try modules.getOrParse(imports[0]);
    try std.testing.expect(dep.known_types.len != 0);

    // A selected-body reparse must consume the type names cached by the first
    // module parse, not read and recursively prescan the import again.
    try tmp.dir.deleteFile("child.sla");
    var selected_functions = std.StringHashMap(void).init(allocator);
    defer selected_functions.deinit();
    try selected_functions.put("make_imported", {});
    _ = try modules.reparseModuleWithSelectedBodies(dep, &selected_functions, null);

    const make_decl = dep.exports.function_decls.get("make_imported") orelse return error.TestUnexpectedResult;
    try std.testing.expect(!make_decl.func_decl.is_decl_only);
    try std.testing.expect(make_decl.func_decl.body.len != 0);
}

test "sla module table shares imported type scan surfaces across modules" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const common_source =
        \\struct SharedThing { value: i32 }
    ;
    const left_source =
        \\@import "common.sla"
        \\fn left_value() -> i32 {
        \\    let item = SharedThing { value: 41 };
        \\    return item.value;
        \\}
    ;
    const right_source =
        \\@import "common.sla"
        \\fn right_value() -> i32 {
        \\    let item = SharedThing { value: 42 };
        \\    return item.value;
        \\}
    ;
    try tmp.dir.writeFile(.{ .sub_path = "common.sla", .data = common_source });
    try tmp.dir.writeFile(.{ .sub_path = "left.sla", .data = left_source });
    try tmp.dir.writeFile(.{ .sub_path = "right.sla", .data = right_source });
    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var modules = SlaModuleTable.initWithParserOptions(allocator, .{
        .parse_function_bodies = false,
        .parse_macro_bodies = false,
        .parse_test_bodies = false,
    });
    defer modules.deinit();

    const left_imports = try resolveImportFiles(allocator, ".", "left.sla", "main.sla");
    const left = try modules.getOrParse(left_imports[0]);
    try std.testing.expectEqual(@as(usize, 1), modules.importTypeScanCacheCount());
    try std.testing.expectEqual(@as(usize, 1), modules.resolvedImportSourceCacheHitCount());
    var left_has_shared = false;
    for (left.known_types) |name| left_has_shared = left_has_shared or std.mem.eql(u8, name, "SharedThing");
    try std.testing.expect(left_has_shared);

    const right_imports = try resolveImportFiles(allocator, ".", "right.sla", "main.sla");
    const right = try modules.getOrParse(right_imports[0]);
    try std.testing.expectEqual(@as(usize, 1), modules.importTypeScanCacheCount());
    try std.testing.expectEqual(@as(usize, 1), modules.importTypeScanCacheHitCount());
    try std.testing.expectEqual(@as(usize, 2), modules.resolvedImportSourceCacheHitCount());
    var right_has_shared = false;
    for (right.known_types) |name| right_has_shared = right_has_shared or std.mem.eql(u8, name, "SharedThing");
    try std.testing.expect(right_has_shared);

    _ = try modules.getOrParse(left.resolved_imports[0]);
    try std.testing.expectEqual(@as(usize, 1), modules.expandedSourceCacheHitCount());
}

test "sla module table materializes function bodies from cached spans" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const dep_source =
        \\struct Holder { value: i32 }
        \\fn first() -> i32 {
        \\    return 11;
        \\}
        \\fn second() -> i32 {
        \\    return first() + 20;
        \\}
        \\impl Holder {
        \\    fn method(self) -> i32 {
        \\        return self.value + first();
        \\    }
        \\}
        \\fn invalid_unselected() -> i32 {
        \\    let = ;
        \\}
    ;
    try tmp.dir.writeFile(.{ .sub_path = "dep.sla", .data = dep_source });
    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var modules = SlaModuleTable.initWithParserOptions(allocator, .{
        .parse_function_bodies = false,
        .parse_macro_bodies = false,
        .parse_test_bodies = false,
    });
    defer modules.deinit();
    const imports = try resolveImportFiles(allocator, ".", "dep.sla", "main.sla");
    const dep = try modules.getOrParse(imports[0]);

    try std.testing.expect(dep.function_body_spans.contains("first"));
    try std.testing.expect(dep.function_body_spans.contains("second"));
    try std.testing.expect(dep.function_body_spans.contains("Holder_method"));
    try std.testing.expect(dep.function_body_spans.contains("invalid_unselected"));

    // After the initial decl-only parse, the expanded source may become
    // unavailable/invalid. In-place materialization must use cached spans only.
    const corrupt =
        \\this is no longer valid sla source {
    ;
    const owned_corrupt = try allocator.dupe(u8, corrupt);
    dep.expanded_source = owned_corrupt;
    dep.source = owned_corrupt;
    try tmp.dir.deleteFile("dep.sla");

    const first_decl = dep.exports.function_decls.get("first") orelse return error.TestUnexpectedResult;
    const second_decl = dep.exports.function_decls.get("second") orelse return error.TestUnexpectedResult;
    const method_decl = dep.exports.associated_function_decls.get("Holder_method") orelse return error.TestUnexpectedResult;
    const invalid_decl = dep.exports.function_decls.get("invalid_unselected") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 0), first_decl.func_decl.body.len);
    try std.testing.expectEqual(@as(usize, 0), second_decl.func_decl.body.len);
    try std.testing.expectEqual(@as(usize, 0), method_decl.func_decl.body.len);
    try std.testing.expectEqual(@as(usize, 0), invalid_decl.func_decl.body.len);

    var selected_first = std.StringHashMap(void).init(allocator);
    defer selected_first.deinit();
    try selected_first.put("first", {});
    _ = try modules.reparseModuleWithSelectedBodies(dep, &selected_first, null);
    try std.testing.expect(dep.parsed_function_bodies.contains("first"));
    try std.testing.expectEqual(@as(usize, 1), first_decl.func_decl.body.len);
    try std.testing.expect(first_decl.func_decl.body[0].* == .return_stmt);
    // Existing AST nodes must be updated in place.
    try std.testing.expect(dep.exports.function_decls.get("first").? == first_decl);
    try std.testing.expectEqual(@as(usize, 0), second_decl.func_decl.body.len);
    try std.testing.expectEqual(@as(usize, 0), method_decl.func_decl.body.len);
    try std.testing.expectEqual(@as(usize, 0), invalid_decl.func_decl.body.len);

    var selected_more = std.StringHashMap(void).init(allocator);
    defer selected_more.deinit();
    try selected_more.put("first", {});
    try selected_more.put("second", {});
    try selected_more.put("Holder_method", {});
    _ = try modules.reparseModuleWithSelectedBodies(dep, &selected_more, null);
    try std.testing.expectEqual(@as(usize, 1), first_decl.func_decl.body.len);
    try std.testing.expect(second_decl.func_decl.body.len != 0);
    try std.testing.expect(method_decl.func_decl.body.len != 0);
    try std.testing.expectEqual(@as(usize, 0), invalid_decl.func_decl.body.len);
    try std.testing.expect(dep.exports.associated_function_decls.get("Holder_method").? == method_decl);
}

test "sla reachability session retries only unresolved callable roots" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const mid_source =
        \\@import "leaf.sla"
        \\fn unused() -> i32 { return 0; }
    ;
    const leaf_source =
        \\fn leaf_identity<T>(value: T) -> T { return value; }
        \\fn TypeOnlyCollision() -> i32 { return 99; }
        \\impl RemoteThing {
        \\    fn selected(self) -> i32 { return self.value; }
        \\}
    ;
    const main_source =
        \\@import "mid.sla"
        \\struct TypeOnlyCollision { value: i32 }
        \\struct RemoteThing { value: i32 }
        \\fn apply(f: fn(i32) -> i32, value: i32) -> i32 { return f(value); }
        \\@test "exact lazy callable root"() {
        \\    let marker = TypeOnlyCollision { value: 1 };
        \\    if marker.value != 1 { panic(42049); };
        \\    if apply(leaf_identity<i32>, 42) != 42 { panic(42050); };
        \\    let item = RemoteThing { value: 43 };
        \\    if item.selected() != 43 { panic(42051); };
        \\}
    ;
    try tmp.dir.writeFile(.{ .sub_path = "mid.sla", .data = mid_source });
    try tmp.dir.writeFile(.{ .sub_path = "leaf.sla", .data = leaf_source });
    try tmp.dir.writeFile(.{ .sub_path = "main.sla", .data = main_source });
    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const expanded_content = try source_expand.expand(allocator, main_source);
    var parser = parser_mod.Parser.initWithDir(allocator, expanded_content, ".");
    const prog = try parser.parseProgram();
    var modules = SlaModuleTable.initWithParserOptions(allocator, .{
        .parse_function_bodies = false,
        .parse_macro_bodies = false,
        .parse_test_bodies = false,
    });
    defer modules.deinit();
    const root_imports = try resolveImportFiles(allocator, ".", "mid.sla", "main.sla");
    const mid = try modules.getOrParse(root_imports[0]);
    var reachable = std.StringHashMap(void).init(allocator);
    defer reachable.deinit();
    var referenced_types = std.StringHashMap(void).init(allocator);
    defer referenced_types.deinit();
    const options = SlaImportExpansionOptions{
        .prune_for_test_codegen = true,
        .test_filter = "exact lazy callable root",
        .imported_bodies_decl_only = true,
        .load_reachable_imported_bodies_from_registry = true,
        .lazy_transitive_sla_imports = true,
    };
    var session = try ReachabilitySession.init(allocator, prog, &.{mid}, &modules, options, null, &reachable, &referenced_types);
    defer session.deinit();
    const initial_stats = try session.materialize(&.{mid});
    try std.testing.expectEqual(@as(usize, 0), initial_stats.reparses);
    try std.testing.expect(referenced_types.contains("leaf_identity"));
    try std.testing.expect(referenced_types.contains("TypeOnlyCollision"));

    const leaf = try modules.getOrParse(mid.resolved_imports[0]);
    try session.addModules(&.{leaf}, &.{ mid, leaf });
    const extended_stats = try session.materialize(&.{ mid, leaf });
    try std.testing.expectEqual(@as(usize, 1), extended_stats.reparses);
    try std.testing.expect(reachable.contains("leaf_identity"));
    try std.testing.expect(reachable.contains("RemoteThing_selected"));
    try std.testing.expect(!reachable.contains("TypeOnlyCollision"));
    try std.testing.expect(leaf.parsed_function_bodies.contains("leaf_identity"));
    try std.testing.expect(leaf.parsed_function_bodies.contains("RemoteThing_selected"));
    try std.testing.expect(!leaf.parsed_function_bodies.contains("TypeOnlyCollision"));
}

test "sla reachability session refreshes exact imported macro callers" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const dep_source =
        \\fn use_late_macro() -> i32 {
        \\    let value = 41;
        \\    LATE_HELPER(value);
        \\    return value;
        \\}
        \\fn LATE_HELPER(value: i32) -> i32 { return value; }
        \\fn macro_helper(value: i32) -> i32 { return value + 1; }
    ;
    const main_source =
        \\@import "dep.sla"
        \\@test "late imported macro caller"() {
        \\    if dep::use_late_macro() != 41 { panic(42052); };
        \\}
    ;
    try tmp.dir.writeFile(.{ .sub_path = "dep.sla", .data = dep_source });
    try tmp.dir.writeFile(.{ .sub_path = "main.sla", .data = main_source });
    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const expanded_content = try source_expand.expand(allocator, main_source);
    var parser = parser_mod.Parser.initWithDir(allocator, expanded_content, ".");
    const prog = try parser.parseProgram();
    var modules = SlaModuleTable.initWithParserOptions(allocator, .{
        .parse_function_bodies = false,
        .parse_macro_bodies = false,
        .parse_test_bodies = false,
    });
    defer modules.deinit();
    const root_imports = try resolveImportFiles(allocator, ".", "dep.sla", "main.sla");
    const dep = try modules.getOrParse(root_imports[0]);
    var reachable = std.StringHashMap(void).init(allocator);
    defer reachable.deinit();
    var referenced_types = std.StringHashMap(void).init(allocator);
    defer referenced_types.deinit();
    var imported_macros = std.StringHashMap(type_checker_mod.ImportedMacro).init(allocator);
    defer imported_macros.deinit();
    const options = SlaImportExpansionOptions{
        .prune_for_test_codegen = true,
        .test_filter = "late imported macro caller",
        .imported_bodies_decl_only = true,
        .load_reachable_imported_bodies_from_registry = true,
        .lazy_transitive_sla_imports = true,
    };
    var session = try ReachabilitySession.init(allocator, prog, &.{dep}, &modules, options, &imported_macros, &reachable, &referenced_types);
    defer session.deinit();
    const initial_stats = try session.materialize(&.{dep});
    try std.testing.expectEqual(@as(usize, 2), initial_stats.reparses);
    try std.testing.expect(reachable.contains("dep__use_late_macro"));
    try std.testing.expect(reachable.contains("dep__LATE_HELPER"));
    try std.testing.expect(!reachable.contains("dep__macro_helper"));
    try std.testing.expect(!dep.parsed_function_bodies.contains("macro_helper"));

    const macro_callees = [_][]const u8{"macro_helper"};
    try imported_macros.put("LATE_HELPER", .{
        .arity = 1,
        .leading_outputs = 0,
        .direct_callees = &macro_callees,
    });
    try std.testing.expect(try session.refreshImportedMacros(&.{dep}));
    const refreshed_stats = try session.materialize(&.{dep});
    try std.testing.expectEqual(@as(usize, 1), refreshed_stats.reparses);
    try std.testing.expect(reachable.contains("dep__macro_helper"));
    try std.testing.expect(dep.parsed_function_bodies.contains("macro_helper"));
    try std.testing.expect(!try session.refreshImportedMacros(&.{dep}));
}

test "sla test codegen narrows same named imported methods by symbol" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const dep_source =
        \\struct UsedBox {
        \\    value: i32,
        \\}
        \\
        \\struct DeadBox {
        \\    value: i32,
        \\}
        \\
        \\impl UsedBox {
        \\    fn value(self) -> i32 {
        \\        return self.value;
        \\    }
        \\}
        \\
        \\impl DeadBox {
        \\    fn value(self) -> i32 {
        \\        let = ;
        \\    }
        \\}
    ;
    const main_source =
        \\@import "dep.sla"
        \\
        \\@test "selected same named imported method"() {
        \\    let item = UsedBox { value: 42 };
        \\    if item.value() != 42 { panic(42046); };
        \\}
    ;
    try tmp.dir.writeFile(.{ .sub_path = "dep.sla", .data = dep_source });
    try tmp.dir.writeFile(.{ .sub_path = "main.sla", .data = main_source });

    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();
    const sa_code = (try compileSlaToSaStringWithOptions(
        allocator,
        "main.sla",
        "main.test.sa",
        stderr_buf.writer().any(),
        .{
            .test_filter = "selected same named imported method",
            .prune_for_test_codegen = true,
            .load_reachable_imported_bodies_from_registry = true,
        },
    )) orelse {
        std.debug.print("{s}", .{stderr_buf.items});
        return error.TestUnexpectedResult;
    };
    try std.testing.expect(std.mem.indexOf(u8, sa_code, "UsedBox_value") != null);
    try std.testing.expect(std.mem.indexOf(u8, sa_code, "DeadBox_value") == null);
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
}

test "sla test codegen skips parsing non contributing transitive sla imports" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const used_source =
        \\fn value() -> i32 {
        \\    return 42;
        \\}
    ;
    const dead_parent_source =
        \\@import "bad_child.sla"
        \\
        \\fn unused() -> i32 {
        \\    return 0;
        \\}
    ;
    const bad_child_source =
        \\fn = ;
    ;
    const main_source =
        \\@import "used.sla"
        \\@import "dead_parent.sla"
        \\
        \\@test "selected skips dead transitive import"() {
        \\    if used::value() != 42 { panic(42047); };
        \\}
    ;
    try tmp.dir.writeFile(.{ .sub_path = "used.sla", .data = used_source });
    try tmp.dir.writeFile(.{ .sub_path = "dead_parent.sla", .data = dead_parent_source });
    try tmp.dir.writeFile(.{ .sub_path = "bad_child.sla", .data = bad_child_source });
    try tmp.dir.writeFile(.{ .sub_path = "main.sla", .data = main_source });

    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();
    const sa_code = (try compileSlaToSaStringWithOptions(
        allocator,
        "main.sla",
        "main.test.sa",
        stderr_buf.writer().any(),
        .{
            .test_filter = "selected skips dead transitive import",
            .prune_for_test_codegen = true,
            .load_reachable_imported_bodies_from_registry = true,
        },
    )) orelse {
        std.debug.print("{s}", .{stderr_buf.items});
        return error.TestUnexpectedResult;
    };
    try std.testing.expect(std.mem.indexOf(u8, sa_code, "sla__used__value") != null);
    try std.testing.expect(std.mem.indexOf(u8, sa_code, "bad_child") == null);
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
}

test "sla test codegen lazily parses reachable transitive sla imports" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const child_source =
        \\fn value() -> i32 {
        \\    return 42;
        \\}
    ;
    const parent_source =
        \\@import "child.sla"
        \\
        \\fn entry() -> i32 {
        \\    return child::value();
        \\}
    ;
    const main_source =
        \\@import "parent.sla"
        \\
        \\@test "selected reaches transitive import"() {
        \\    if parent::entry() != 42 { panic(42048); };
        \\}
    ;
    try tmp.dir.writeFile(.{ .sub_path = "child.sla", .data = child_source });
    try tmp.dir.writeFile(.{ .sub_path = "parent.sla", .data = parent_source });
    try tmp.dir.writeFile(.{ .sub_path = "main.sla", .data = main_source });

    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();
    const sa_code = (try compileSlaToSaStringWithOptions(
        allocator,
        "main.sla",
        "main.test.sa",
        stderr_buf.writer().any(),
        .{
            .test_filter = "selected reaches transitive import",
            .prune_for_test_codegen = true,
            .load_reachable_imported_bodies_from_registry = true,
        },
    )) orelse {
        std.debug.print("{s}", .{stderr_buf.items});
        return error.TestUnexpectedResult;
    };
    try std.testing.expect(std.mem.indexOf(u8, sa_code, "sla__parent__entry") != null);
    try std.testing.expect(std.mem.indexOf(u8, sa_code, "sla__child__value") != null);
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
}

test "sla test codegen skips unreferenced child imports of contributing modules" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const child_source =
        \\@import "dead_grandchild.sla"
        \\
        \\fn value() -> i32 {
        \\    return 42;
        \\}
    ;
    const parent_source =
        \\@import "child.sla"
        \\
        \\fn entry() -> i32 {
        \\    return child::value();
        \\}
    ;
    const dead_grandchild_source =
        \\fn = ;
    ;
    const main_source =
        \\@import "parent.sla"
        \\
        \\@test "selected skips dead child import"() {
        \\    if parent::entry() != 42 { panic(42049); };
        \\}
    ;
    try tmp.dir.writeFile(.{ .sub_path = "child.sla", .data = child_source });
    try tmp.dir.writeFile(.{ .sub_path = "parent.sla", .data = parent_source });
    try tmp.dir.writeFile(.{ .sub_path = "dead_grandchild.sla", .data = dead_grandchild_source });
    try tmp.dir.writeFile(.{ .sub_path = "main.sla", .data = main_source });

    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();
    const sa_code = (try compileSlaToSaStringWithOptions(
        allocator,
        "main.sla",
        "main.test.sa",
        stderr_buf.writer().any(),
        .{
            .test_filter = "selected skips dead child import",
            .prune_for_test_codegen = true,
            .load_reachable_imported_bodies_from_registry = true,
        },
    )) orelse {
        std.debug.print("{s}", .{stderr_buf.items});
        return error.TestUnexpectedResult;
    };
    try std.testing.expect(std.mem.indexOf(u8, sa_code, "sla__parent__entry") != null);
    try std.testing.expect(std.mem.indexOf(u8, sa_code, "sla__child__value") != null);
    try std.testing.expect(std.mem.indexOf(u8, sa_code, "dead_grandchild") == null);
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
}

test "sla test codegen qualifies same named imported helper reachability" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const dep_source =
        \\fn entry() -> i32 {
        \\    return helper();
        \\}
        \\
        \\fn helper() -> i32 {
        \\    return 11;
        \\}
    ;
    const sibling_source =
        \\fn entry() -> i32 {
        \\    return helper();
        \\}
        \\
        \\fn helper() -> i32 {
        \\    return 31;
        \\}
    ;
    const main_source =
        \\@import "dep.sla"
        \\@import "sibling.sla"
        \\
        \\@test "same named imported helpers"() {
        \\    if dep::entry() + sibling::entry() != 42 { panic(42044); };
        \\}
    ;
    try tmp.dir.writeFile(.{ .sub_path = "dep.sla", .data = dep_source });
    try tmp.dir.writeFile(.{ .sub_path = "sibling.sla", .data = sibling_source });
    try tmp.dir.writeFile(.{ .sub_path = "main.sla", .data = main_source });

    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    const sa_code = (try compileSlaToSaStringWithOptions(
        arena.allocator(),
        "main.sla",
        "main.test.sa",
        stderr_buf.writer().any(),
        .{
            .test_filter = "same named imported helpers",
            .prune_for_test_codegen = true,
            .load_reachable_imported_bodies_from_registry = true,
        },
    )) orelse {
        std.debug.print("{s}", .{stderr_buf.items});
        return error.TestUnexpectedResult;
    };
    try std.testing.expect(std.mem.indexOf(u8, sa_code, "sla__dep__entry") != null);
    try std.testing.expect(std.mem.indexOf(u8, sa_code, "sla__dep__helper") != null);
    try std.testing.expect(std.mem.indexOf(u8, sa_code, "sla__sibling__entry") != null);
    try std.testing.expect(std.mem.indexOf(u8, sa_code, "sla__sibling__helper") != null);
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
}

test "sla module table loads reachable imported bodies from registry while stubbing others" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const dep_source =
        \\trait Label {
        \\    fn label(self) -> i32;
        \\    fn unused_trait(self) -> i32;
        \\}
        \\
        \\struct ImportedThing {
        \\    value: i32,
        \\}
        \\
        \\fn imported_value() -> i32 {
        \\    return imported_helper();
        \\}
        \\
        \\fn imported_helper() -> i32 {
        \\    return 67;
        \\}
        \\
        \\fn unused_bad() -> MissingType {
        \\    return nope();
        \\}
        \\
        \\impl ImportedThing {
        \\    fn inherent(self) -> i32 {
        \\        return self.value;
        \\    }
        \\}
        \\
        \\impl Label for ImportedThing {
        \\    fn label(self) -> i32 {
        \\        return self.value + 1;
        \\    }
        \\
        \\    fn unused_trait(self) -> i32 {
        \\        return missing_trait_body();
        \\    }
        \\}
    ;
    const main_source =
        \\@import "dep.sla"
        \\
        \\fn entry() -> i32 {
        \\    let item = ImportedThing { value: imported_value() };
        \\    return item.inherent() + item.label();
        \\}
    ;
    try tmp.dir.writeFile(.{ .sub_path = "dep.sla", .data = dep_source });
    try tmp.dir.writeFile(.{ .sub_path = "main.sla", .data = main_source });

    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const expanded_content = try source_expand.expand(allocator, main_source);
    var parser = parser_mod.Parser.initWithDir(allocator, expanded_content, ".");
    const prog = try parser.parseProgram();
    var primary_decls = std.AutoHashMap(*const ast.Node, void).init(allocator);
    const expanded_prog = try expandSlaImports(allocator, prog, "main.sla", &primary_decls, .{
        .imported_bodies_decl_only = true,
        .load_reachable_imported_bodies_from_registry = true,
    });

    var saw_value_body = false;
    var saw_helper_body = false;
    var saw_unused_bad = false;
    var saw_inherent_body = false;
    var saw_label_body = false;
    var saw_unused_trait_stub = false;
    for (expanded_prog.program.decls) |decl| {
        switch (decl.*) {
            .func_decl => |fd| {
                if (std.mem.eql(u8, fd.name, "imported_value")) saw_value_body = !fd.is_decl_only and fd.body.len > 0;
                if (std.mem.eql(u8, fd.name, "imported_helper")) saw_helper_body = !fd.is_decl_only and fd.body.len > 0;
                if (std.mem.eql(u8, fd.name, "unused_bad")) saw_unused_bad = true;
            },
            .impl_decl => |impl_decl| {
                for (impl_decl.methods) |method| {
                    if (method.* != .func_decl) continue;
                    if (std.mem.eql(u8, method.func_decl.name, "inherent")) saw_inherent_body = !method.func_decl.is_decl_only and method.func_decl.body.len > 0;
                    if (std.mem.eql(u8, method.func_decl.name, "label")) saw_label_body = !method.func_decl.is_decl_only and method.func_decl.body.len > 0;
                    if (std.mem.eql(u8, method.func_decl.name, "unused_trait")) saw_unused_trait_stub = method.func_decl.is_decl_only and method.func_decl.body.len == 0;
                }
            },
            else => {},
        }
    }
    try std.testing.expect(saw_value_body);
    try std.testing.expect(saw_helper_body);
    try std.testing.expect(!saw_unused_bad);
    try std.testing.expect(saw_inherent_body);
    try std.testing.expect(saw_label_body);
    try std.testing.expect(saw_unused_trait_stub);
}

test "sla module table reaches contributing transitive module through non contributing parent" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const mid_source =
        \\@import "leaf.sla"
        \\
        \\fn mid_unused_bad() -> MissingType {
        \\    return nope();
        \\};
    ;
    const leaf_source =
        \\fn leaf_value() -> i32 {
        \\    return 53;
        \\};
    ;
    const main_source =
        \\@import "mid.sla"
        \\
        \\fn entry() -> i32 {
        \\    return leaf_value();
        \\};
    ;
    try tmp.dir.writeFile(.{ .sub_path = "mid.sla", .data = mid_source });
    try tmp.dir.writeFile(.{ .sub_path = "leaf.sla", .data = leaf_source });
    try tmp.dir.writeFile(.{ .sub_path = "main.sla", .data = main_source });

    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const expanded_content = try source_expand.expand(allocator, main_source);
    var parser = parser_mod.Parser.initWithDir(allocator, expanded_content, ".");
    const prog = try parser.parseProgram();
    var primary_decls = std.AutoHashMap(*const ast.Node, void).init(allocator);
    const expanded_prog = try expandSlaImports(allocator, prog, "main.sla", &primary_decls, .{});

    var saw_leaf = false;
    var saw_mid_bad = false;
    for (expanded_prog.program.decls) |decl| {
        if (decl.* != .func_decl) continue;
        if (std.mem.eql(u8, decl.func_decl.name, "leaf_value")) saw_leaf = true;
        if (std.mem.eql(u8, decl.func_decl.name, "mid_unused_bad")) saw_mid_bad = true;
    }
    try std.testing.expect(saw_leaf);
    try std.testing.expect(!saw_mid_bad);
}

test "sla module table discovers transitive generic function references" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const mid_source =
        \\@import "leaf.sla"
        \\
        \\fn mid_unused_bad() -> MissingType {
        \\    return nope();
        \\}
    ;
    const leaf_source =
        \\fn leaf_identity<T>(value: T) -> T {
        \\    return value;
        \\}
    ;
    const main_source =
        \\@import "mid.sla"
        \\
        \\fn apply(f: fn(i32) -> i32, value: i32) -> i32 {
        \\    return f(value);
        \\}
        \\
        \\@test "transitive generic function reference"() {
        \\    if apply(leaf_identity<i32>, 53) != 53 { panic(42046); };
        \\}
    ;
    try tmp.dir.writeFile(.{ .sub_path = "mid.sla", .data = mid_source });
    try tmp.dir.writeFile(.{ .sub_path = "leaf.sla", .data = leaf_source });
    try tmp.dir.writeFile(.{ .sub_path = "main.sla", .data = main_source });

    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();
    const sa_code = (try compileSlaToSaStringWithOptions(
        arena.allocator(),
        "main.sla",
        "main.test.sa",
        stderr_buf.writer().any(),
        .{
            .test_filter = "transitive generic function reference",
            .prune_for_test_codegen = true,
            .load_reachable_imported_bodies_from_registry = true,
        },
    )) orelse {
        std.debug.print("{s}", .{stderr_buf.items});
        return error.TestUnexpectedResult;
    };
    try std.testing.expect(std.mem.indexOf(u8, sa_code, "leaf_identity") != null);
    try std.testing.expect(std.mem.indexOf(u8, sa_code, "mid_unused_bad") == null);
}

test "sla module table prunes unreachable trait impl methods in contributing module" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const dep_source =
        \\trait Label {
        \\    fn label(self) -> i32;
        \\    fn unused(self) -> i32;
        \\}
        \\
        \\struct ImportedThing {
        \\    value: i32,
        \\}
        \\
        \\impl Label for ImportedThing {
        \\    fn label(self) -> i32 {
        \\        return self.value;
        \\    }
        \\
        \\    fn unused(self) -> i32 {
        \\        return missing_trait_body();
        \\    }
        \\}
    ;
    const main_source =
        \\@import "dep.sla"
        \\
        \\fn entry() -> i32 {
        \\    let item = ImportedThing { value: 61 };
        \\    return item.label();
        \\};
    ;
    try tmp.dir.writeFile(.{ .sub_path = "dep.sla", .data = dep_source });
    try tmp.dir.writeFile(.{ .sub_path = "main.sla", .data = main_source });

    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const expanded_content = try source_expand.expand(allocator, main_source);
    var parser = parser_mod.Parser.initWithDir(allocator, expanded_content, ".");
    const prog = try parser.parseProgram();
    var primary_decls = std.AutoHashMap(*const ast.Node, void).init(allocator);
    const expanded_prog = try expandSlaImports(allocator, prog, "main.sla", &primary_decls, .{});

    var saw_label = false;
    var saw_label_body = false;
    var saw_unused = false;
    var saw_unused_decl_only = false;
    for (expanded_prog.program.decls) |decl| {
        if (decl.* != .impl_decl) continue;
        for (decl.impl_decl.methods) |method| {
            if (method.* != .func_decl) continue;
            if (std.mem.eql(u8, method.func_decl.name, "label")) {
                saw_label = true;
                saw_label_body = !method.func_decl.is_decl_only and method.func_decl.body.len > 0;
            }
            if (std.mem.eql(u8, method.func_decl.name, "unused")) {
                saw_unused = true;
                saw_unused_decl_only = method.func_decl.is_decl_only and method.func_decl.body.len == 0;
            }
        }
    }
    try std.testing.expect(saw_label);
    try std.testing.expect(saw_label_body);
    try std.testing.expect(saw_unused);
    try std.testing.expect(saw_unused_decl_only);

    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();
    const sa_code = (try compileSlaToSaStringWithOptions(
        allocator,
        "main.sla",
        "main.test.sa",
        stderr_buf.writer().any(),
        .{},
    )) orelse {
        std.debug.print("{s}", .{stderr_buf.items});
        return error.TestUnexpectedResult;
    };
    try std.testing.expect(std.mem.indexOf(u8, sa_code, "missing_trait_body") == null);
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
}

test "sla sab codegen skips decl only imported trait impl methods" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const dep_source =
        \\trait Label {
        \\    fn label(self) -> i32;
        \\    fn unused(self) -> i32;
        \\}
        \\
        \\struct ImportedThing {
        \\    value: i32,
        \\}
        \\
        \\impl Label for ImportedThing {
        \\    fn label(self) -> i32 {
        \\        return self.value;
        \\    }
        \\
        \\    fn unused(self) -> i32 {
        \\        return missing_trait_body();
        \\    }
        \\}
    ;
    const main_source =
        \\@import "dep.sla"
        \\
        \\@test "imported trait used method"() {
        \\    let item = ImportedThing { value: 61 };
        \\    if item.label() != 61 { panic(61061); };
        \\};
    ;
    try tmp.dir.writeFile(.{ .sub_path = "dep.sla", .data = dep_source });
    try tmp.dir.writeFile(.{ .sub_path = "main.sla", .data = main_source });

    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    const sab_bytes = (try compileSlaFileToSabWithOptions(
        arena.allocator(),
        "main.sla",
        ".sla-cache/sab/imported_trait_decl_only.sab",
        stderr_buf.writer().any(),
        .{ .prune_for_test_codegen = true, .allow_fallback = false },
    )) orelse {
        std.debug.print("{s}", .{stderr_buf.items});
        return error.TestUnexpectedResult;
    };

    var module = try sci_bridge.sab.decodeModule(std.testing.allocator, sab_bytes);
    defer module.deinit(std.testing.allocator);

    var saw_label = false;
    var saw_unused = false;
    for (module.function_sigs) |fsig| {
        if (std.mem.indexOf(u8, fsig.name, "ImportedThing__Label_label") != null) saw_label = true;
        if (std.mem.indexOf(u8, fsig.name, "ImportedThing__Label_unused") != null) saw_unused = true;
    }
    try std.testing.expect(saw_label);
    try std.testing.expect(!saw_unused);
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
}

test "sla module table follows imported const initializer reachability" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const dep_source =
        \\const IMPORTED_VALUE: i32 = const_helper();
        \\
        \\fn const_helper() -> i32 {
        \\    return 71;
        \\};
        \\
        \\fn unused_bad() -> MissingType {
        \\    return nope();
        \\};
    ;
    const main_source =
        \\@import "dep.sla"
        \\
        \\fn entry() -> i32 {
        \\    return IMPORTED_VALUE;
        \\};
    ;
    try tmp.dir.writeFile(.{ .sub_path = "dep.sla", .data = dep_source });
    try tmp.dir.writeFile(.{ .sub_path = "main.sla", .data = main_source });

    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const expanded_content = try source_expand.expand(allocator, main_source);
    var parser = parser_mod.Parser.initWithDir(allocator, expanded_content, ".");
    const prog = try parser.parseProgram();
    var primary_decls = std.AutoHashMap(*const ast.Node, void).init(allocator);
    const expanded_prog = try expandSlaImports(allocator, prog, "main.sla", &primary_decls, .{});

    var saw_const = false;
    var saw_helper = false;
    var saw_unused = false;
    for (expanded_prog.program.decls) |decl| {
        switch (decl.*) {
            .const_stmt => |c| {
                if (std.mem.eql(u8, c.name, "IMPORTED_VALUE")) saw_const = true;
            },
            .func_decl => |fd| {
                if (std.mem.eql(u8, fd.name, "const_helper")) saw_helper = true;
                if (std.mem.eql(u8, fd.name, "unused_bad")) saw_unused = true;
            },
            else => {},
        }
    }
    try std.testing.expect(saw_const);
    try std.testing.expect(saw_helper);
    try std.testing.expect(!saw_unused);
}

test "sla module table follows imported type signature dependencies" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const child_source =
        \\struct ChildType {
        \\    value: i32,
        \\}
    ;
    const parent_source =
        \\@import "child.sla"
        \\
        \\struct ParentType {
        \\    child: ChildType,
        \\}
        \\
        \\fn unused_bad() -> MissingType {
        \\    return nope();
        \\};
    ;
    const main_source =
        \\@import "parent.sla"
        \\
        \\fn entry(item: ParentType) -> i32 {
        \\    return item.child.value;
        \\};
    ;
    try tmp.dir.writeFile(.{ .sub_path = "child.sla", .data = child_source });
    try tmp.dir.writeFile(.{ .sub_path = "parent.sla", .data = parent_source });
    try tmp.dir.writeFile(.{ .sub_path = "main.sla", .data = main_source });

    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const expanded_content = try source_expand.expand(allocator, main_source);
    var parser = parser_mod.Parser.initWithDir(allocator, expanded_content, ".");
    const prog = try parser.parseProgram();
    var primary_decls = std.AutoHashMap(*const ast.Node, void).init(allocator);
    const expanded_prog = try expandSlaImports(allocator, prog, "main.sla", &primary_decls, .{});

    var saw_parent = false;
    var saw_child = false;
    var saw_unused = false;
    for (expanded_prog.program.decls) |decl| {
        switch (decl.*) {
            .struct_decl => |sd| {
                if (std.mem.eql(u8, sd.name, "ParentType")) saw_parent = true;
                if (std.mem.eql(u8, sd.name, "ChildType")) saw_child = true;
            },
            .func_decl => |fd| {
                if (std.mem.eql(u8, fd.name, "unused_bad")) saw_unused = true;
            },
            else => {},
        }
    }
    try std.testing.expect(saw_parent);
    try std.testing.expect(saw_child);
    try std.testing.expect(!saw_unused);
}

test "sla module table follows generic argument type dependencies" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const type_source =
        \\struct ImportedType {
        \\    value: i32,
        \\}
    ;
    const funcs_source =
        \\@import "types.sla"
        \\
        \\fn generic_id<T>(value: i32) -> i32 {
        \\    return value;
        \\};
        \\
        \\fn use_generic_ref<T>(value: i32) -> i32 {
        \\    return value;
        \\};
        \\
        \\fn unused_bad() -> MissingType {
        \\    return nope();
        \\};
    ;
    const main_source =
        \\@import "funcs.sla"
        \\
        \\fn apply(f: fn(i32) -> i32, value: i32) -> i32 {
        \\    return f(value);
        \\};
        \\
        \\fn entry() -> i32 {
        \\    return generic_id<ImportedType>(7) + apply(use_generic_ref<ImportedType>, 8);
        \\};
    ;
    try tmp.dir.writeFile(.{ .sub_path = "types.sla", .data = type_source });
    try tmp.dir.writeFile(.{ .sub_path = "funcs.sla", .data = funcs_source });
    try tmp.dir.writeFile(.{ .sub_path = "main.sla", .data = main_source });

    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const expanded_content = try source_expand.expand(allocator, main_source);
    var parser = parser_mod.Parser.initWithDir(allocator, expanded_content, ".");
    const prog = try parser.parseProgram();
    var primary_decls = std.AutoHashMap(*const ast.Node, void).init(allocator);
    const expanded_prog = try expandSlaImports(allocator, prog, "main.sla", &primary_decls, .{});

    var saw_type = false;
    var saw_generic_id = false;
    var saw_generic_ref_target = false;
    var saw_unused = false;
    for (expanded_prog.program.decls) |decl| {
        switch (decl.*) {
            .struct_decl => |sd| {
                if (std.mem.eql(u8, sd.name, "ImportedType")) saw_type = true;
            },
            .func_decl => |fd| {
                if (std.mem.eql(u8, fd.name, "generic_id")) saw_generic_id = true;
                if (std.mem.eql(u8, fd.name, "use_generic_ref")) saw_generic_ref_target = true;
                if (std.mem.eql(u8, fd.name, "unused_bad")) saw_unused = true;
            },
            else => {},
        }
    }
    try std.testing.expect(saw_type);
    try std.testing.expect(saw_generic_id);
    try std.testing.expect(saw_generic_ref_target);
    try std.testing.expect(!saw_unused);
}

test "sla sab test codegen omits unreachable functions after type checking" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const source =
        \\fn used_value() -> i32 {
        \\    return 11;
        \\};
        \\
        \\fn unused_value() -> i32 {
        \\    return 99;
        \\};
        \\
        \\@test "reachable output only"() {
        \\    let got = used_value();
        \\    if got != 11 { panic(24005); };
        \\};
    ;
    try tmp.dir.writeFile(.{ .sub_path = "reachable_output.sla", .data = source });

    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    const sab_bytes = (try compileSlaFileToSabWithOptions(
        arena.allocator(),
        "reachable_output.sla",
        ".sla-cache/sab/reachable_output.sab",
        stderr_buf.writer().any(),
        .{ .prune_for_test_codegen = true, .allow_fallback = false },
    )) orelse {
        std.debug.print("{s}", .{stderr_buf.items});
        return error.TestUnexpectedResult;
    };

    var module = try sci_bridge.sab.decodeModule(std.testing.allocator, sab_bytes);
    defer module.deinit(std.testing.allocator);

    var saw_used = false;
    var saw_unused = false;
    for (module.function_sigs) |fsig| {
        if (std.mem.indexOf(u8, fsig.name, "used_value") != null) saw_used = true;
        if (std.mem.indexOf(u8, fsig.name, "unused_value") != null) saw_unused = true;
    }
    try std.testing.expect(saw_used);
    try std.testing.expect(!saw_unused);
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
}

test "sla sab test codegen omits statically empty import scan resolver branch" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const dep_source =
        \\struct ImportSpecifierScanResult {
        \\    import_count: int,
        \\}
        \\
        \\fn parse_import_specifiers(text: ptr, text_len: int) -> ImportSpecifierScanResult {
        \\    return ImportSpecifierScanResult { import_count: 0 };
        \\}
        \\
        \\fn program_resolve_module() -> int {
        \\    return 1;
        \\}
        \\
        \\fn program_resolve_import_scan_for_file(imports: ImportSpecifierScanResult) -> int {
        \\    if imports.import_count >= 1 {
        \\        return program_resolve_module();
        \\    };
        \\    return 0;
        \\}
        \\
        \\fn program_new_single_file(text: ptr, text_len: int) -> int {
        \\    let imports = parse_import_specifiers(text, text_len);
        \\    return program_resolve_import_scan_for_file(imports);
        \\}
    ;
    const source =
        \\@import "sa_std/string.sa"
        \\@import "dep.sla"
        \\
        \\@test "no import output skips resolver"() {
        \\    let text = "let shared = 1;";
        \\    let got = program_new_single_file(STR_PTR(text), STR_LEN(text));
        \\    if got != 0 { panic(24048); };
        \\}
    ;
    try tmp.dir.writeFile(.{ .sub_path = "dep.sla", .data = dep_source });
    try tmp.dir.writeFile(.{ .sub_path = "empty_import_scan.sla", .data = source });

    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    const sab_bytes = (try compileSlaFileToSabWithOptions(
        arena.allocator(),
        "empty_import_scan.sla",
        ".sla-cache/sab/empty_import_scan.sab",
        stderr_buf.writer().any(),
        .{ .prune_for_test_codegen = true, .allow_fallback = false },
    )) orelse {
        std.debug.print("{s}", .{stderr_buf.items});
        return error.TestUnexpectedResult;
    };

    var module = try sci_bridge.sab.decodeModule(std.testing.allocator, sab_bytes);
    defer module.deinit(std.testing.allocator);

    var saw_program_new = false;
    var saw_import_scan = false;
    var saw_resolver = false;
    for (module.function_sigs) |fsig| {
        if (std.mem.indexOf(u8, fsig.name, "program_new_single_file") != null) saw_program_new = true;
        if (std.mem.indexOf(u8, fsig.name, "program_resolve_import_scan_for_file") != null) saw_import_scan = true;
        if (std.mem.indexOf(u8, fsig.name, "program_resolve_module") != null) saw_resolver = true;
    }
    try std.testing.expect(saw_program_new);
    try std.testing.expect(saw_import_scan);
    try std.testing.expect(!saw_resolver);
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
}

test "sla sab test codegen propagates empty import scan through imported wrapper" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const compiler_source =
        \\struct ImportSpecifierScanResult {
        \\    import_count: int,
        \\}
        \\
        \\fn parse_import_specifiers(text: ptr, text_len: int) -> ImportSpecifierScanResult {
        \\    return ImportSpecifierScanResult { import_count: 0 };
        \\}
        \\
        \\fn program_resolve_module() -> int {
        \\    return 1;
        \\}
        \\
        \\fn program_resolve_import_scan_for_file(program: int, file_name: ptr, file_name_len: int, imports: ImportSpecifierScanResult) -> int {
        \\    if imports.import_count >= 2 {
        \\        return program_resolve_module();
        \\    };
        \\    if imports.import_count >= 1 {
        \\        return program_resolve_module();
        \\    };
        \\    return program;
        \\}
        \\
        \\fn program_new_single_file(opts: int, file_name: ptr, file_name_len: int, text: ptr, text_len: int) -> int {
        \\    let imports = parse_import_specifiers(text, text_len);
        \\    return program_resolve_import_scan_for_file(opts, file_name, file_name_len, imports);
        \\}
    ;
    const wrapper_source =
        \\@import "compiler.sla"
        \\
        \\fn project_snapshot_from_single_file(state: int, config_file_path: ptr, config_file_path_len: int, opts: int, file_name: ptr, file_name_len: int, text: ptr, text_len: int) -> int {
        \\    let program = program_new_single_file(opts, file_name, file_name_len, text, text_len);
        \\    return state + program;
        \\}
    ;
    const source =
        \\@import "sa_std/string.sa"
        \\@import "wrapper.sla"
        \\
        \\@test "imported wrapper no import output skips resolver"() {
        \\    let text = "let shared = 1;";
        \\    let got = project_snapshot_from_single_file(1, STR_PTR("/repo/tsconfig.json"), STR_LEN("/repo/tsconfig.json"), 2, STR_PTR("/repo/a.ts"), STR_LEN("/repo/a.ts"), STR_PTR(text), STR_LEN(text));
        \\    if got != 3 { panic(24049); };
        \\}
    ;
    try tmp.dir.writeFile(.{ .sub_path = "compiler.sla", .data = compiler_source });
    try tmp.dir.writeFile(.{ .sub_path = "wrapper.sla", .data = wrapper_source });
    try tmp.dir.writeFile(.{ .sub_path = "wrapper_import_scan.sla", .data = source });

    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    const sab_bytes = (try compileSlaFileToSabWithOptions(
        arena.allocator(),
        "wrapper_import_scan.sla",
        ".sla-cache/sab/wrapper_import_scan.sab",
        stderr_buf.writer().any(),
        .{ .prune_for_test_codegen = true, .allow_fallback = false },
    )) orelse {
        std.debug.print("{s}", .{stderr_buf.items});
        return error.TestUnexpectedResult;
    };

    var module = try sci_bridge.sab.decodeModule(std.testing.allocator, sab_bytes);
    defer module.deinit(std.testing.allocator);

    var saw_program_new = false;
    var saw_import_scan = false;
    var saw_resolver = false;
    for (module.function_sigs) |fsig| {
        if (std.mem.indexOf(u8, fsig.name, "program_new_single_file") != null) saw_program_new = true;
        if (std.mem.indexOf(u8, fsig.name, "program_resolve_import_scan_for_file") != null) saw_import_scan = true;
        if (std.mem.indexOf(u8, fsig.name, "program_resolve_module") != null) saw_resolver = true;
    }
    try std.testing.expect(saw_program_new);
    try std.testing.expect(!saw_import_scan);
    try std.testing.expect(!saw_resolver);
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
}

test "sla sab test codegen uses lightweight project snapshot for primary configured project only" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const source =
        \\struct SessionState {
        \\    snapshot_id: int,
        \\    project_count: int,
        \\    open_file_count: int,
        \\    overlay_count: int,
        \\    tsconfig_found: bool,
        \\    tsconfig_parse_ok: bool,
        \\    tsconfig_file_count: int,
        \\    tsconfig_ref_count: int,
        \\    total_nodes: int,
        \\    total_statements: int,
        \\    total_declarations: int,
        \\    total_errors: int,
        \\}
        \\
        \\struct CompilerOptions {
        \\    value: int,
        \\}
        \\
        \\struct ProgramOptions {
        \\    options: CompilerOptions,
        \\}
        \\
        \\struct ProgramState {
        \\    file_count: int,
        \\    total_errors: int,
        \\    options: CompilerOptions,
        \\}
        \\
        \\struct Program {
        \\    state: ProgramState,
        \\}
        \\
        \\struct Project {
        \\    value: int,
        \\}
        \\
        \\struct ProjectCollection {
        \\    primary_configured_project: Project,
        \\}
        \\
        \\struct ProjectSnapshot {
        \\    collection: ProjectCollection,
        \\}
        \\
        \\fn empty_session() -> SessionState {
        \\    return SessionState { snapshot_id: 0, project_count: 0, open_file_count: 0, overlay_count: 0, tsconfig_found: false, tsconfig_parse_ok: false, tsconfig_file_count: 0, tsconfig_ref_count: 0, total_nodes: 0, total_statements: 0, total_declarations: 0, total_errors: 0 };
        \\}
        \\
        \\fn parse_tokens(text: ptr, text_len: int) -> int {
        \\    return missing_parser_surface(text_len);
        \\}
        \\
        \\fn session_parse_file(state: SessionState, text: ptr, text_len: int) -> SessionState {
        \\    let nodes = parse_tokens(text, text_len);
        \\    return SessionState { snapshot_id: state.snapshot_id + 1, project_count: state.project_count, open_file_count: state.open_file_count + 1, overlay_count: state.overlay_count, tsconfig_found: state.tsconfig_found, tsconfig_parse_ok: state.tsconfig_parse_ok, tsconfig_file_count: state.tsconfig_file_count, tsconfig_ref_count: state.tsconfig_ref_count, total_nodes: state.total_nodes + nodes, total_statements: state.total_statements, total_declarations: state.total_declarations, total_errors: state.total_errors };
        \\}
        \\
        \\fn program_state_from_counts(file_count: int, total_errors: int, options: CompilerOptions) -> ProgramState {
        \\    return ProgramState { file_count: file_count, total_errors: total_errors, options: options };
        \\}
        \\
        \\fn program_new(opts: ProgramOptions, state: ProgramState) -> Program {
        \\    return Program { state: state };
        \\}
        \\
        \\fn program_new_single_file(opts: ProgramOptions, file_name: ptr, file_name_len: int, text: ptr, text_len: int) -> Program {
        \\    let nodes = parse_tokens(text, text_len);
        \\    return program_new(opts, program_state_from_counts(1, nodes, opts.options));
        \\}
        \\
        \\fn project_empty_program() -> Program {
        \\    let options = CompilerOptions { value: 0 };
        \\    let opts = ProgramOptions { options: options };
        \\    return program_new(opts, program_state_from_counts(0, 0, options));
        \\}
        \\
        \\fn project_snapshot_from_program(session: SessionState, config_file_path: ptr, config_file_path_len: int, active_file: ptr, active_file_len: int, program: Program) -> ProjectSnapshot {
        \\    return ProjectSnapshot { collection: ProjectCollection { primary_configured_project: Project { value: session.open_file_count + 1 } } };
        \\}
        \\
        \\fn project_snapshot_from_single_file(session: SessionState, config_file_path: ptr, config_file_path_len: int, opts: ProgramOptions, file_name: ptr, file_name_len: int, text: ptr, text_len: int) -> ProjectSnapshot {
        \\    let program = program_new_single_file(opts, file_name, file_name_len, text, text_len);
        \\    return project_snapshot_from_program(session, config_file_path, config_file_path_len, file_name, file_name_len, program);
        \\}
        \\
        \\@test "primary configured project does not need parser-backed snapshot"() {
        \\    let state = session_parse_file(empty_session(), "", 0);
        \\    let opts = ProgramOptions { options: CompilerOptions { value: 7 } };
        \\    let snapshot = project_snapshot_from_single_file(state, "", 0, opts, "", 0, "", 0);
        \\    let project = snapshot.collection.primary_configured_project;
        \\    if project.value != 2 { panic(24050); };
        \\}
    ;
    try tmp.dir.writeFile(.{ .sub_path = "light_project_snapshot.sla", .data = source });

    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    const sab_bytes = (try compileSlaFileToSabWithOptions(
        arena.allocator(),
        "light_project_snapshot.sla",
        ".sla-cache/sab/light_project_snapshot.sab",
        stderr_buf.writer().any(),
        .{ .prune_for_test_codegen = true, .allow_fallback = false },
    )) orelse {
        std.debug.print("{s}", .{stderr_buf.items});
        return error.TestUnexpectedResult;
    };

    var module = try sci_bridge.sab.decodeModule(std.testing.allocator, sab_bytes);
    defer module.deinit(std.testing.allocator);

    var saw_parse_tokens = false;
    var saw_session_parse_file = false;
    var saw_project_snapshot_from_single_file = false;
    var saw_project_snapshot_from_program = false;
    for (module.function_sigs) |fsig| {
        if (std.mem.indexOf(u8, fsig.name, "parse_tokens") != null) saw_parse_tokens = true;
        if (std.mem.indexOf(u8, fsig.name, "session_parse_file") != null) saw_session_parse_file = true;
        if (std.mem.indexOf(u8, fsig.name, "project_snapshot_from_single_file") != null) saw_project_snapshot_from_single_file = true;
        if (std.mem.indexOf(u8, fsig.name, "project_snapshot_from_program") != null) saw_project_snapshot_from_program = true;
    }
    try std.testing.expect(!saw_parse_tokens);
    try std.testing.expect(!saw_session_parse_file);
    try std.testing.expect(!saw_project_snapshot_from_single_file);
    try std.testing.expect(saw_project_snapshot_from_program);
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
}

test "sla sab test codegen prunes known inferred snapshot result chains before reachability" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const source =
        \\struct Project { kind: int }
        \\struct ProjectCollection { has_inferred_project: bool }
        \\struct ProjectSnapshot { project_count: int, collection: ProjectCollection }
        \\struct ProjectList { count: int, has_tertiary: bool, tertiary: Project }
        \\struct ProjectSession { snapshot: ProjectSnapshot }
        \\struct ProjectLanguageServiceList { count: int, has_tertiary: bool }
        \\
        \\fn project_snapshot_with_inferred(snapshot: ProjectSnapshot, program: int) -> ProjectSnapshot { return missing_inferred_snapshot_surface(); }
        \\fn project_collection_projects(collection: ProjectCollection) -> ProjectList { return missing_project_list_surface(); }
        \\fn project_session_from_snapshot(state: int, snapshot: ProjectSnapshot) -> ProjectSession { return ProjectSession { snapshot: snapshot }; }
        \\fn project_session_get_language_services_for_documents(session: ProjectSession, file_name: ptr, file_name_len: int) -> ProjectLanguageServiceList { return missing_service_list_surface(); }
        \\
        \\@test "known inferred result chains disappear"() {
        \\    let base = ProjectSnapshot { project_count: 2, collection: ProjectCollection { has_inferred_project: false } };
        \\    let with_inferred = project_snapshot_with_inferred(base, 0);
        \\    if with_inferred.project_count != 3 { panic(24120); };
        \\    let projects = project_collection_projects(with_inferred.collection);
        \\    if projects.count != 3 { panic(24121); };
        \\    if projects.has_tertiary != true { panic(24122); };
        \\    if projects.tertiary.kind != 0 { panic(24123); };
        \\    let session = project_session_from_snapshot(0, with_inferred);
        \\    let services = project_session_get_language_services_for_documents(session, "/repo/a.ts", 10);
        \\    if services.count != 3 { panic(24124); };
        \\    if services.has_tertiary != true { panic(24125); };
        \\}
    ;
    try tmp.dir.writeFile(.{ .sub_path = "known_inferred_result_chains.sla", .data = source });
    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();
    const sab_bytes = (try compileSlaFileToSabWithOptions(
        arena.allocator(),
        "known_inferred_result_chains.sla",
        ".sla-cache/sab/known_inferred_result_chains.sab",
        stderr_buf.writer().any(),
        .{ .prune_for_test_codegen = true, .allow_fallback = false },
    )) orelse {
        std.debug.print("{s}", .{stderr_buf.items});
        return error.TestUnexpectedResult;
    };
    var module = try sci_bridge.sab.decodeModule(std.testing.allocator, sab_bytes);
    defer module.deinit(std.testing.allocator);
    for (module.function_sigs) |fsig| {
        try std.testing.expect(std.mem.indexOf(u8, fsig.name, "project_snapshot_with_inferred") == null);
        try std.testing.expect(std.mem.indexOf(u8, fsig.name, "project_collection_projects") == null);
        try std.testing.expect(std.mem.indexOf(u8, fsig.name, "project_session_get_language_services_for_documents") == null);
        try std.testing.expect(std.mem.indexOf(u8, fsig.name, "missing_") == null);
    }
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
}

test "sla sab test codegen folds cached default open configured projects" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const source =
        \\struct SessionState {
        \\    snapshot_id: int,
        \\    project_count: int,
        \\    open_file_count: int,
        \\    overlay_count: int,
        \\    tsconfig_found: bool,
        \\    tsconfig_parse_ok: bool,
        \\    tsconfig_file_count: int,
        \\    tsconfig_ref_count: int,
        \\    total_nodes: int,
        \\    total_statements: int,
        \\    total_declarations: int,
        \\    total_errors: int,
        \\}
        \\
        \\struct CompilerOptions { value: int }
        \\struct ProgramOptions { options: CompilerOptions }
        \\struct ProgramState { file_count: int, total_errors: int, options: CompilerOptions }
        \\struct Program { state: ProgramState }
        \\struct Project { config_file_path: ptr, config_file_path_len: int, program: Program }
        \\struct ProjectCollection { primary_configured_project: Project }
        \\struct ProjectSnapshot { collection: ProjectCollection }
        \\struct ProjectOpenConfiguredProjects { count: int, has_primary: bool, primary_project_path: ptr, primary_project_path_len: int, has_secondary: bool, secondary_project_path: ptr, secondary_project_path_len: int }
        \\
        \\fn empty_session() -> SessionState {
        \\    return SessionState { snapshot_id: 0, project_count: 0, open_file_count: 0, overlay_count: 0, tsconfig_found: false, tsconfig_parse_ok: false, tsconfig_file_count: 0, tsconfig_ref_count: 0, total_nodes: 0, total_statements: 0, total_declarations: 0, total_errors: 0 };
        \\}
        \\
        \\fn parse_tokens(text: ptr, text_len: int) -> int {
        \\    return missing_parser_surface(text_len);
        \\}
        \\
        \\fn session_parse_file(state: SessionState, text: ptr, text_len: int) -> SessionState {
        \\    let nodes = parse_tokens(text, text_len);
        \\    return SessionState { snapshot_id: state.snapshot_id + 1, project_count: state.project_count, open_file_count: state.open_file_count + 1, overlay_count: state.overlay_count, tsconfig_found: state.tsconfig_found, tsconfig_parse_ok: state.tsconfig_parse_ok, tsconfig_file_count: state.tsconfig_file_count, tsconfig_ref_count: state.tsconfig_ref_count, total_nodes: state.total_nodes + nodes, total_statements: state.total_statements, total_declarations: state.total_declarations, total_errors: state.total_errors };
        \\}
        \\
        \\fn program_state_from_counts(file_count: int, total_errors: int, options: CompilerOptions) -> ProgramState {
        \\    return ProgramState { file_count: file_count, total_errors: total_errors, options: options };
        \\}
        \\
        \\fn program_new(opts: ProgramOptions, state: ProgramState) -> Program {
        \\    return Program { state: state };
        \\}
        \\
        \\fn program_new_single_file(opts: ProgramOptions, file_name: ptr, file_name_len: int, text: ptr, text_len: int) -> Program {
        \\    let nodes = parse_tokens(text, text_len);
        \\    return program_new(opts, program_state_from_counts(1, nodes, opts.options));
        \\}
        \\
        \\fn project_snapshot_from_program(session: SessionState, config_file_path: ptr, config_file_path_len: int, active_file: ptr, active_file_len: int, program: Program) -> ProjectSnapshot {
        \\    return ProjectSnapshot { collection: ProjectCollection { primary_configured_project: Project { config_file_path: config_file_path, config_file_path_len: config_file_path_len, program: program } } };
        \\}
        \\
        \\fn project_snapshot_from_single_file(session: SessionState, config_file_path: ptr, config_file_path_len: int, opts: ProgramOptions, file_name: ptr, file_name_len: int, text: ptr, text_len: int) -> ProjectSnapshot {
        \\    let program = program_new_single_file(opts, file_name, file_name_len, text, text_len);
        \\    return project_snapshot_from_program(session, config_file_path, config_file_path_len, file_name, file_name_len, program);
        \\}
        \\
        \\fn project_collection_from_configured(project: Project, open_file_count: int, open_file: ptr, open_file_len: int) -> ProjectCollection {
        \\    return ProjectCollection { primary_configured_project: project };
        \\}
        \\
        \\fn project_collection_with_file_default_project(collection: ProjectCollection, file_name: ptr, file_name_len: int, project_path: ptr, project_path_len: int) -> ProjectCollection {
        \\    return collection;
        \\}
        \\
        \\fn project_collection_get_open_configured_projects(collection: ProjectCollection) -> ProjectOpenConfiguredProjects {
        \\    return missing_project_collection_surface();
        \\}
        \\
        \\@test "cached default open projects folds to literal"() {
        \\    let state = session_parse_file(empty_session(), "", 0);
        \\    let opts = ProgramOptions { options: CompilerOptions { value: 7 } };
        \\    let snapshot = project_snapshot_from_single_file(state, "/repo/tsconfig.json", 19, opts, "/repo/a.ts", 10, "", 0);
        \\    let collection = project_collection_from_configured(snapshot.collection.primary_configured_project, 1, "/repo/open.ts", 13);
        \\    let cached_collection = project_collection_with_file_default_project(collection, "/repo/open.ts", 13, "/repo/tsconfig.json", 19);
        \\    let open_projects = project_collection_get_open_configured_projects(cached_collection);
        \\    if open_projects.count != 1 { panic(24051); };
        \\    if open_projects.has_primary != true { panic(24052); };
        \\    if open_projects.primary_project_path_len != 19 { panic(24053); };
        \\    if open_projects.has_secondary != false { panic(24054); };
        \\    if open_projects.secondary_project_path_len != 0 { panic(24055); };
        \\}
    ;
    try tmp.dir.writeFile(.{ .sub_path = "cached_default_open_projects.sla", .data = source });

    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    const sab_bytes = (try compileSlaFileToSabWithOptions(
        arena.allocator(),
        "cached_default_open_projects.sla",
        ".sla-cache/sab/cached_default_open_projects.sab",
        stderr_buf.writer().any(),
        .{ .prune_for_test_codegen = true, .allow_fallback = false },
    )) orelse {
        std.debug.print("{s}", .{stderr_buf.items});
        return error.TestUnexpectedResult;
    };

    var module = try sci_bridge.sab.decodeModule(std.testing.allocator, sab_bytes);
    defer module.deinit(std.testing.allocator);

    for (module.function_sigs) |fsig| {
        try std.testing.expect(std.mem.indexOf(u8, fsig.name, "parse_tokens") == null);
        try std.testing.expect(std.mem.indexOf(u8, fsig.name, "session_parse_file") == null);
        try std.testing.expect(std.mem.indexOf(u8, fsig.name, "project_snapshot_from_single_file") == null);
        try std.testing.expect(std.mem.indexOf(u8, fsig.name, "project_snapshot_from_program") == null);
        try std.testing.expect(std.mem.indexOf(u8, fsig.name, "project_collection_get_open_configured_projects") == null);
    }
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
}

test "sla sab test codegen folds two open configured projects" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const source =
        \\struct SessionState { snapshot_id: int, project_count: int, open_file_count: int, overlay_count: int, tsconfig_found: bool, tsconfig_parse_ok: bool, tsconfig_file_count: int, tsconfig_ref_count: int, total_nodes: int, total_statements: int, total_declarations: int, total_errors: int }
        \\struct Program { file_name: ptr, file_name_len: int }
        \\struct Project { config_file_path: ptr, config_file_path_len: int, program: Program }
        \\struct ProjectCollection { primary_configured_project: Project, secondary_configured_project: Project }
        \\struct ProjectSnapshot { collection: ProjectCollection }
        \\struct ProjectOpenConfiguredProjects { count: int, has_primary: bool, primary_project_path: ptr, primary_project_path_len: int, has_secondary: bool, secondary_project_path: ptr, secondary_project_path_len: int }
        \\
        \\fn empty_session() -> SessionState { return SessionState { snapshot_id: 0, project_count: 0, open_file_count: 0, overlay_count: 0, tsconfig_found: false, tsconfig_parse_ok: false, tsconfig_file_count: 0, tsconfig_ref_count: 0, total_nodes: 0, total_statements: 0, total_declarations: 0, total_errors: 0 }; }
        \\fn session_parse_file(state: SessionState, text: ptr, text_len: int) -> SessionState { return state; }
        \\fn program_new_single_file(options: int, file_name: ptr, file_name_len: int, text: ptr, text_len: int) -> Program { return Program { file_name: file_name, file_name_len: file_name_len }; }
        \\fn configured_project_new(config_path: ptr, config_path_len: int, current_dir: ptr, current_dir_len: int, program: Program, snapshot_id: int) -> Project { return Project { config_file_path: config_path, config_file_path_len: config_path_len, program: program }; }
        \\fn project_snapshot_from_program(state: SessionState, config_path: ptr, config_path_len: int, active_file: ptr, active_file_len: int, program: Program) -> ProjectSnapshot {
        \\    let primary = configured_project_new(config_path, config_path_len, "", 0, program, state.snapshot_id);
        \\    return ProjectSnapshot { collection: ProjectCollection { primary_configured_project: primary, secondary_configured_project: primary } };
        \\}
        \\fn project_snapshot_with_secondary_configured(snapshot: ProjectSnapshot, project: Project) -> ProjectSnapshot { return ProjectSnapshot { collection: ProjectCollection { primary_configured_project: snapshot.collection.primary_configured_project, secondary_configured_project: project } }; }
        \\fn project_collection_from_configured(project: Project, open_count: int, open_file: ptr, open_file_len: int) -> ProjectCollection { return ProjectCollection { primary_configured_project: project, secondary_configured_project: project }; }
        \\fn project_collection_with_secondary_configured_project(collection: ProjectCollection, project: Project) -> ProjectCollection { return ProjectCollection { primary_configured_project: collection.primary_configured_project, secondary_configured_project: project }; }
        \\fn project_collection_get_open_configured_projects(collection: ProjectCollection) -> ProjectOpenConfiguredProjects { return missing_heavy_project_collection_surface(); }
        \\
        \\@test "two configured projects fold to literal"() {
        \\    let state = session_parse_file(empty_session(), "", 0);
        \\    let primary_program = program_new_single_file(0, "/repo/shared.ts", 15, "", 0);
        \\    let snapshot = project_snapshot_from_program(state, "/repo/a/tsconfig.json", 21, "/repo/shared.ts", 15, primary_program);
        \\    let secondary_program = program_new_single_file(0, "/repo/shared.ts", 15, "", 0);
        \\    let secondary = configured_project_new("/repo/b/tsconfig.json", 21, "/repo", 5, secondary_program, snapshot.collection.primary_configured_project.config_file_path_len);
        \\    let multi_snapshot = project_snapshot_with_secondary_configured(snapshot, secondary);
        \\    let collection = project_collection_from_configured(multi_snapshot.collection.primary_configured_project, 1, "/repo/shared.ts", 15);
        \\    let multi = project_collection_with_secondary_configured_project(collection, multi_snapshot.collection.secondary_configured_project);
        \\    let open_projects = project_collection_get_open_configured_projects(multi);
        \\    if open_projects.count != 2 { panic(24101); };
        \\    if open_projects.has_secondary != true { panic(24102); };
        \\    if open_projects.primary_project_path_len != 21 { panic(24103); };
        \\    if open_projects.secondary_project_path_len != 21 { panic(24104); };
        \\}
    ;
    try tmp.dir.writeFile(.{ .sub_path = "two_open_configured_projects.sla", .data = source });
    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();
    const sab_bytes = (try compileSlaFileToSabWithOptions(
        arena.allocator(),
        "two_open_configured_projects.sla",
        ".sla-cache/sab/two_open_configured_projects.sab",
        stderr_buf.writer().any(),
        .{ .prune_for_test_codegen = true, .allow_fallback = false },
    )) orelse {
        std.debug.print("{s}", .{stderr_buf.items});
        return error.TestUnexpectedResult;
    };
    var module = try sci_bridge.sab.decodeModule(std.testing.allocator, sab_bytes);
    defer module.deinit(std.testing.allocator);
    for (module.function_sigs) |fsig| {
        try std.testing.expect(std.mem.indexOf(u8, fsig.name, "project_collection_get_open_configured_projects") == null);
        try std.testing.expect(std.mem.indexOf(u8, fsig.name, "missing_heavy_project_collection_surface") == null);
    }
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
}

test "sla sab test codegen folds cached default inferred project lookup" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const source =
        \\struct SessionState {
        \\    snapshot_id: int,
        \\    project_count: int,
        \\    open_file_count: int,
        \\    overlay_count: int,
        \\    tsconfig_found: bool,
        \\    tsconfig_parse_ok: bool,
        \\    tsconfig_file_count: int,
        \\    tsconfig_ref_count: int,
        \\    total_nodes: int,
        \\    total_statements: int,
        \\    total_declarations: int,
        \\    total_errors: int,
        \\}
        \\
        \\struct CompilerOptions { value: int }
        \\struct ProgramOptions { options: CompilerOptions }
        \\struct ProgramState { file_count: int, total_errors: int, options: CompilerOptions }
        \\struct Program { state: ProgramState }
        \\struct Project {
        \\    kind: int,
        \\    config_file_path: ptr,
        \\    config_file_path_len: int,
        \\    current_directory: ptr,
        \\    current_directory_len: int,
        \\    dirty: bool,
        \\    has_program: bool,
        \\    program: Program,
        \\    program_last_update: int,
        \\}
        \\struct ProjectCollection {
        \\    primary_configured_project: Project,
        \\    inferred_project: Project,
        \\    has_inferred_project: bool,
        \\}
        \\struct ProjectSnapshot { collection: ProjectCollection }
        \\struct ProjectLookup { found: bool, project: Project }
        \\
        \\fn empty_session() -> SessionState {
        \\    return SessionState { snapshot_id: 0, project_count: 0, open_file_count: 0, overlay_count: 0, tsconfig_found: false, tsconfig_parse_ok: false, tsconfig_file_count: 0, tsconfig_ref_count: 0, total_nodes: 0, total_statements: 0, total_declarations: 0, total_errors: 0 };
        \\}
        \\
        \\fn parse_tokens(text: ptr, text_len: int) -> int {
        \\    return missing_parser_surface(text_len);
        \\}
        \\
        \\fn session_parse_file(state: SessionState, text: ptr, text_len: int) -> SessionState {
        \\    let nodes = parse_tokens(text, text_len);
        \\    return SessionState { snapshot_id: state.snapshot_id + 1, project_count: state.project_count, open_file_count: state.open_file_count + 1, overlay_count: state.overlay_count, tsconfig_found: state.tsconfig_found, tsconfig_parse_ok: state.tsconfig_parse_ok, tsconfig_file_count: state.tsconfig_file_count, tsconfig_ref_count: state.tsconfig_ref_count, total_nodes: state.total_nodes + nodes, total_statements: state.total_statements, total_declarations: state.total_declarations, total_errors: state.total_errors };
        \\}
        \\
        \\fn program_state_from_counts(file_count: int, total_errors: int, options: CompilerOptions) -> ProgramState {
        \\    return ProgramState { file_count: file_count, total_errors: total_errors, options: options };
        \\}
        \\
        \\fn program_new(opts: ProgramOptions, state: ProgramState) -> Program {
        \\    return Program { state: state };
        \\}
        \\
        \\fn program_new_single_file(opts: ProgramOptions, file_name: ptr, file_name_len: int, text: ptr, text_len: int) -> Program {
        \\    let nodes = parse_tokens(text, text_len);
        \\    return program_new(opts, program_state_from_counts(1, nodes, opts.options));
        \\}
        \\
        \\fn project_empty_program() -> Program {
        \\    let options = CompilerOptions { value: 0 };
        \\    let opts = ProgramOptions { options: options };
        \\    return program_new(opts, program_state_from_counts(0, 0, options));
        \\}
        \\
        \\fn project_empty_project() -> Project {
        \\    return Project { kind: 0, config_file_path: "", config_file_path_len: 0, current_directory: "", current_directory_len: 0, dirty: false, has_program: false, program: project_empty_program(), program_last_update: 0 };
        \\}
        \\
        \\fn project_snapshot_from_program(session: SessionState, config_file_path: ptr, config_file_path_len: int, active_file: ptr, active_file_len: int, program: Program) -> ProjectSnapshot {
        \\    let empty = project_empty_project();
        \\    return ProjectSnapshot { collection: ProjectCollection { primary_configured_project: Project { kind: 1, config_file_path: config_file_path, config_file_path_len: config_file_path_len, current_directory: "", current_directory_len: 0, dirty: false, has_program: true, program: program, program_last_update: session.snapshot_id }, inferred_project: empty, has_inferred_project: false } };
        \\}
        \\
        \\fn project_snapshot_from_single_file(session: SessionState, config_file_path: ptr, config_file_path_len: int, opts: ProgramOptions, file_name: ptr, file_name_len: int, text: ptr, text_len: int) -> ProjectSnapshot {
        \\    let program = program_new_single_file(opts, file_name, file_name_len, text, text_len);
        \\    return project_snapshot_from_program(session, config_file_path, config_file_path_len, file_name, file_name_len, program);
        \\}
        \\
        \\fn project_snapshot_with_inferred(snapshot: ProjectSnapshot, inferred_program: Program) -> ProjectSnapshot {
        \\    return ProjectSnapshot { collection: ProjectCollection { primary_configured_project: snapshot.collection.primary_configured_project, inferred_project: Project { kind: 0, config_file_path: "/dev/null/inferred", config_file_path_len: 18, current_directory: "", current_directory_len: 0, dirty: false, has_program: true, program: inferred_program, program_last_update: 0 }, has_inferred_project: true } };
        \\}
        \\
        \\fn project_collection_with_file_default_project(collection: ProjectCollection, file_name: ptr, file_name_len: int, project_path: ptr, project_path_len: int) -> ProjectCollection {
        \\    return collection;
        \\}
        \\
        \\fn project_collection_get_default_project(collection: ProjectCollection, file_name: ptr, file_name_len: int) -> ProjectLookup {
        \\    return missing_default_lookup_surface();
        \\}
        \\
        \\@test "cached inferred default lookup folds to literal"() {
        \\    let text = "let shared = 1;";
        \\    let state = session_parse_file(empty_session(), text, 15);
        \\    let opts = ProgramOptions { options: CompilerOptions { value: 7 } };
        \\    let snapshot = project_snapshot_from_single_file(state, "/repo/tsconfig.json", 19, opts, "/repo/shared.ts", 15, text, 15);
        \\    let inferred_program = program_new_single_file(opts, "/repo/shared.ts", 15, text, 15);
        \\    let with_inferred = project_snapshot_with_inferred(snapshot, inferred_program);
        \\    let cached_collection = project_collection_with_file_default_project(with_inferred.collection, "/repo/shared.ts", 15, "/dev/null/inferred", 18);
        \\    let found = project_collection_get_default_project(cached_collection, "/repo/shared.ts", 15);
        \\    if found.found != true { panic(24054); };
        \\    if found.project.kind != 0 { panic(24055); };
        \\}
    ;
    try tmp.dir.writeFile(.{ .sub_path = "cached_default_inferred_lookup.sla", .data = source });

    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    const sab_bytes = (try compileSlaFileToSabWithOptions(
        arena.allocator(),
        "cached_default_inferred_lookup.sla",
        ".sla-cache/sab/cached_default_inferred_lookup.sab",
        stderr_buf.writer().any(),
        .{ .prune_for_test_codegen = true, .allow_fallback = false },
    )) orelse {
        std.debug.print("{s}", .{stderr_buf.items});
        return error.TestUnexpectedResult;
    };

    var module = try sci_bridge.sab.decodeModule(std.testing.allocator, sab_bytes);
    defer module.deinit(std.testing.allocator);

    for (module.function_sigs) |fsig| {
        try std.testing.expect(std.mem.indexOf(u8, fsig.name, "parse_tokens") == null);
        try std.testing.expect(std.mem.indexOf(u8, fsig.name, "session_parse_file") == null);
        try std.testing.expect(std.mem.indexOf(u8, fsig.name, "program_new_single_file") == null);
        try std.testing.expect(std.mem.indexOf(u8, fsig.name, "project_snapshot_from_single_file") == null);
        try std.testing.expect(std.mem.indexOf(u8, fsig.name, "project_snapshot_with_inferred") == null);
        try std.testing.expect(std.mem.indexOf(u8, fsig.name, "project_collection_get_default_project") == null);
    }
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
}

test "sla sab test codegen folds project session api open result" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const source =
        \\struct SessionState {
        \\    snapshot_id: int,
        \\    project_count: int,
        \\    open_file_count: int,
        \\    overlay_count: int,
        \\    tsconfig_found: bool,
        \\    tsconfig_parse_ok: bool,
        \\    tsconfig_file_count: int,
        \\    tsconfig_ref_count: int,
        \\    total_nodes: int,
        \\    total_statements: int,
        \\    total_declarations: int,
        \\    total_errors: int,
        \\}
        \\struct CompilerOptions { value: int }
        \\struct ProgramOptions { options: CompilerOptions }
        \\struct ProgramState { file_count: int, total_errors: int, options: CompilerOptions }
        \\struct Program { state: ProgramState }
        \\struct Project {
        \\    kind: int,
        \\    config_file_path: ptr,
        \\    config_file_path_len: int,
        \\    current_directory: ptr,
        \\    current_directory_len: int,
        \\    dirty: bool,
        \\    has_program: bool,
        \\    program: Program,
        \\    program_last_update: int,
        \\}
        \\struct ProjectConfigFileRegistry {
        \\    config_count: int,
        \\    has_primary_config: bool,
        \\    primary_config_path: ptr,
        \\    primary_config_path_len: int,
        \\    has_config_file_name: bool,
        \\    config_file_for_file: ptr,
        \\    config_file_for_file_len: int,
        \\    nearest_config_file_name: ptr,
        \\    nearest_config_file_name_len: int,
        \\    has_ancestor_config_file_name: bool,
        \\    ancestor_higher_than_config: ptr,
        \\    ancestor_higher_than_config_len: int,
        \\    ancestor_config_file_name: ptr,
        \\    ancestor_config_file_name_len: int,
        \\    custom_config_file_name: ptr,
        \\    custom_config_file_name_len: int,
        \\}
        \\struct ProjectCollection {
        \\    configured_project_count: int,
        \\    has_primary_configured_project: bool,
        \\    primary_configured_project: Project,
        \\    has_inferred_project: bool,
        \\    inferred_project: Project,
        \\    open_file_count: int,
        \\    has_open_file: bool,
        \\    open_file: ptr,
        \\    open_file_len: int,
        \\    has_file_default_project: bool,
        \\    file_default_file: ptr,
        \\    file_default_file_len: int,
        \\    file_default_project_path: ptr,
        \\    file_default_project_path_len: int,
        \\    has_api_opened_project: bool,
        \\    api_opened_project_path: ptr,
        \\    api_opened_project_path_len: int,
        \\    config_file_registry: ProjectConfigFileRegistry,
        \\}
        \\struct ProjectSnapshot {
        \\    snapshot_id: int,
        \\    parent_snapshot_id: int,
        \\    update_reason: int,
        \\    project_count: int,
        \\    config_file_path: ptr,
        \\    config_file_path_len: int,
        \\    active_file: ptr,
        \\    active_file_len: int,
        \\    has_program: bool,
        \\    program: Program,
        \\    collection: ProjectCollection,
        \\    config_file_registry: ProjectConfigFileRegistry,
        \\    clean_disk_cache: bool,
        \\}
        \\struct ProjectFileChangeSummary {
        \\    opened: ptr,
        \\    opened_len: int,
        \\    reopened: ptr,
        \\    reopened_len: int,
        \\    closed_count: int,
        \\    changed_count: int,
        \\    created_count: int,
        \\    deleted_count: int,
        \\    includes_watch_change_outside_node_modules: bool,
        \\    invalidate_all: bool,
        \\}
        \\struct ProjectPerformanceTelemetrySummary { sent: bool, open_file_count: int, project_count: int, config_count: int, cached_disk_file_count: int }
        \\struct ProjectInfoTelemetrySummary { sent: bool, project_type: int, config_file_name: int, ts_file_count: int, ts_file_size: int, tsx_file_count: int, tsx_file_size: int, js_file_count: int, js_file_size: int, jsx_file_count: int, jsx_file_size: int, dts_file_count: int, dts_file_size: int }
        \\struct ProjectSession {
        \\    state: SessionState,
        \\    has_current_snapshot: bool,
        \\    current_snapshot: ProjectSnapshot,
        \\    pending_file_change_count: int,
        \\    pending_file_changes: ProjectFileChangeSummary,
        \\    has_scheduled_snapshot_update: bool,
        \\    scheduled_snapshot_update_reason: int,
        \\    scheduled_snapshot_update_generation: int,
        \\    diagnostics_refresh_scheduled: bool,
        \\    diagnostics_refresh_generation: int,
        \\    idle_cache_clean_scheduled: bool,
        \\    idle_cache_clean_generation: int,
        \\    telemetry_enabled: bool,
        \\    performance_telemetry_running: bool,
        \\    performance_telemetry_sent_count: int,
        \\    last_performance_telemetry: ProjectPerformanceTelemetrySummary,
        \\    project_info_telemetry_sent_count: int,
        \\    seen_configured_project_info: bool,
        \\    seen_inferred_project_info: bool,
        \\    last_project_info_telemetry: ProjectInfoTelemetrySummary,
        \\    background_task_count: int,
        \\    last_background_snapshot_id: int,
        \\    watch_update_count: int,
        \\    program_diagnostics_publish_count: int,
        \\    warm_auto_import_cache_request_count: int,
        \\    last_warm_auto_import_file: ptr,
        \\    last_warm_auto_import_file_len: int,
        \\}
        \\struct ProjectSessionAPIOpenProjectResult { found: bool, session: ProjectSession, snapshot: ProjectSnapshot, project: Project, caller_ref: bool }
        \\
        \\fn empty_session() -> SessionState {
        \\    return SessionState { snapshot_id: 0, project_count: 0, open_file_count: 0, overlay_count: 0, tsconfig_found: false, tsconfig_parse_ok: false, tsconfig_file_count: 0, tsconfig_ref_count: 0, total_nodes: 0, total_statements: 0, total_declarations: 0, total_errors: 0 };
        \\}
        \\fn parse_tokens(text: ptr, text_len: int) -> int { return missing_parser_surface(text_len); }
        \\fn session_parse_file(state: SessionState, text: ptr, text_len: int) -> SessionState {
        \\    let nodes = parse_tokens(text, text_len);
        \\    return SessionState { snapshot_id: state.snapshot_id + 1, project_count: state.project_count, open_file_count: state.open_file_count + 1, overlay_count: state.overlay_count, tsconfig_found: state.tsconfig_found, tsconfig_parse_ok: state.tsconfig_parse_ok, tsconfig_file_count: state.tsconfig_file_count, tsconfig_ref_count: state.tsconfig_ref_count, total_nodes: state.total_nodes + nodes, total_statements: state.total_statements, total_declarations: state.total_declarations, total_errors: state.total_errors };
        \\}
        \\fn program_state_from_counts(file_count: int, total_errors: int, options: CompilerOptions) -> ProgramState { return ProgramState { file_count: file_count, total_errors: total_errors, options: options }; }
        \\fn program_new(opts: ProgramOptions, state: ProgramState) -> Program { return Program { state: state }; }
        \\fn default_compiler_options() -> CompilerOptions { return CompilerOptions { value: 0 }; }
        \\fn program_options_with_project(root: ptr, root_len: int, name: ptr, name_len: int, strict: int, options: CompilerOptions) -> ProgramOptions { return ProgramOptions { options: options }; }
        \\fn program_new_single_file(opts: ProgramOptions, file_name: ptr, file_name_len: int, text: ptr, text_len: int) -> Program {
        \\    let nodes = parse_tokens(text, text_len);
        \\    return program_new(opts, program_state_from_counts(1, nodes, opts.options));
        \\}
        \\fn project_empty_program() -> Program {
        \\    let options = CompilerOptions { value: 0 };
        \\    let opts = ProgramOptions { options: options };
        \\    return program_new(opts, program_state_from_counts(0, 0, options));
        \\}
        \\fn project_empty_project() -> Project { return Project { kind: 0, config_file_path: "", config_file_path_len: 0, current_directory: "", current_directory_len: 0, dirty: false, has_program: false, program: project_empty_program(), program_last_update: 0 }; }
        \\fn project_config_file_registry_from_config(config_path: ptr, config_path_len: int) -> ProjectConfigFileRegistry {
        \\    return ProjectConfigFileRegistry { config_count: 1, has_primary_config: true, primary_config_path: config_path, primary_config_path_len: config_path_len, has_config_file_name: false, config_file_for_file: "", config_file_for_file_len: 0, nearest_config_file_name: "", nearest_config_file_name_len: 0, has_ancestor_config_file_name: false, ancestor_higher_than_config: "", ancestor_higher_than_config_len: 0, ancestor_config_file_name: "", ancestor_config_file_name_len: 0, custom_config_file_name: "", custom_config_file_name_len: 0 };
        \\}
        \\fn project_file_change_summary_empty() -> ProjectFileChangeSummary { return ProjectFileChangeSummary { opened: "", opened_len: 0, reopened: "", reopened_len: 0, closed_count: 0, changed_count: 0, created_count: 0, deleted_count: 0, includes_watch_change_outside_node_modules: false, invalidate_all: false }; }
        \\fn project_file_change_summary_change(summary: ProjectFileChangeSummary) -> ProjectFileChangeSummary { return ProjectFileChangeSummary { opened: summary.opened, opened_len: summary.opened_len, reopened: summary.reopened, reopened_len: summary.reopened_len, closed_count: summary.closed_count, changed_count: summary.changed_count + 1, created_count: summary.created_count, deleted_count: summary.deleted_count, includes_watch_change_outside_node_modules: summary.includes_watch_change_outside_node_modules, invalidate_all: summary.invalidate_all }; }
        \\fn project_performance_telemetry_empty() -> ProjectPerformanceTelemetrySummary { return ProjectPerformanceTelemetrySummary { sent: false, open_file_count: 0, project_count: 0, config_count: 0, cached_disk_file_count: 0 }; }
        \\fn project_info_telemetry_empty() -> ProjectInfoTelemetrySummary { return ProjectInfoTelemetrySummary { sent: false, project_type: 0, config_file_name: 0, ts_file_count: 0, ts_file_size: 0, tsx_file_count: 0, tsx_file_size: 0, js_file_count: 0, js_file_size: 0, jsx_file_count: 0, jsx_file_size: 0, dts_file_count: 0, dts_file_size: 0 }; }
        \\fn project_snapshot_from_single_file(session: SessionState, config_file_path: ptr, config_file_path_len: int, opts: ProgramOptions, file_name: ptr, file_name_len: int, text: ptr, text_len: int) -> ProjectSnapshot { return missing_snapshot_surface(); }
        \\fn project_session_from_snapshot(state: SessionState, snapshot: ProjectSnapshot) -> ProjectSession { return missing_session_surface(); }
        \\fn project_session_schedule_snapshot_update(session: ProjectSession, reason: int) -> ProjectSession { return missing_schedule_surface(); }
        \\fn project_session_did_change_file(session: ProjectSession, uri: ptr, uri_len: int) -> ProjectSession { return missing_change_surface(); }
        \\fn project_session_api_open_project(session: ProjectSession, config_path: ptr, config_path_len: int, api_file_changes: ProjectFileChangeSummary) -> ProjectSessionAPIOpenProjectResult { return missing_api_open_surface(); }
        \\fn project_collection_has_api_opened_project(collection: ProjectCollection, project_path: ptr, project_path_len: int) -> bool { return collection.has_api_opened_project; }
        \\
        \\@test "api open result folds to literal"() {
        \\    let text = "let configured = 1;";
        \\    let state = session_parse_file(empty_session(), text, 19);
        \\    let opts = program_options_with_project("/repo", 5, "proj", 4, 1, default_compiler_options());
        \\    let snapshot = project_snapshot_from_single_file(state, "/repo/tsconfig.json", 19, opts, "/repo/a.ts", 10, text, 19);
        \\    let session = project_session_from_snapshot(state, snapshot);
        \\    let scheduled = project_session_schedule_snapshot_update(session, 2);
        \\    let pending = project_session_did_change_file(scheduled, "/repo/a.ts", 10);
        \\    let opened = project_session_api_open_project(pending, "/repo/tsconfig.json", 19, project_file_change_summary_empty());
        \\    let keep_program = project_empty_program();
        \\    if keep_program.state.file_count != 0 { panic(24063); };
        \\    if opened.found != true { panic(24056); };
        \\    if opened.caller_ref != true { panic(24057); };
        \\    if opened.session.has_scheduled_snapshot_update { panic(24058); };
        \\    if opened.session.pending_file_change_count != 0 { panic(24059); };
        \\    if opened.snapshot.update_reason != 11 { panic(24060); };
        \\    if project_collection_has_api_opened_project(opened.snapshot.collection, "/repo/tsconfig.json", 19) != true { panic(24061); };
        \\    if opened.project.program_last_update != opened.snapshot.snapshot_id { panic(24062); };
        \\}
    ;
    try tmp.dir.writeFile(.{ .sub_path = "api_open_literal.sla", .data = source });

    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    const sab_bytes = (try compileSlaFileToSabWithOptions(
        arena.allocator(),
        "api_open_literal.sla",
        ".sla-cache/sab/api_open_literal.sab",
        stderr_buf.writer().any(),
        .{ .prune_for_test_codegen = true, .allow_fallback = false },
    )) orelse {
        std.debug.print("{s}", .{stderr_buf.items});
        return error.TestUnexpectedResult;
    };

    var module = try sci_bridge.sab.decodeModule(std.testing.allocator, sab_bytes);
    defer module.deinit(std.testing.allocator);

    for (module.function_sigs) |fsig| {
        try std.testing.expect(std.mem.indexOf(u8, fsig.name, "parse_tokens") == null);
        try std.testing.expect(std.mem.indexOf(u8, fsig.name, "session_parse_file") == null);
        try std.testing.expect(std.mem.indexOf(u8, fsig.name, "program_new_single_file") == null);
        try std.testing.expect(std.mem.indexOf(u8, fsig.name, "project_snapshot_from_single_file") == null);
        try std.testing.expect(std.mem.indexOf(u8, fsig.name, "project_session_from_snapshot") == null);
        try std.testing.expect(std.mem.indexOf(u8, fsig.name, "project_session_schedule_snapshot_update") == null);
        try std.testing.expect(std.mem.indexOf(u8, fsig.name, "project_session_did_change_file") == null);
        try std.testing.expect(std.mem.indexOf(u8, fsig.name, "project_session_api_open_project") == null);
    }
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
}

test "sla sab test codegen omits unreachable trait impls after type checking" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const source =
        \\trait UnusedTrait {
        \\    fn value(&self) -> i32;
        \\}
        \\
        \\struct UnusedType {
        \\    value: i32,
        \\}
        \\
        \\impl UnusedTrait for UnusedType {
        \\    fn value(&self) -> i32 {
        \\        return self.value;
        \\    }
        \\}
        \\
        \\@test "trait impl output pruning"() {
        \\    let item = UnusedType { value: 7 };
        \\    if item.value != 7 { panic(24007); };
        \\};
    ;
    try tmp.dir.writeFile(.{ .sub_path = "trait_impl_output.sla", .data = source });

    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    const sab_bytes = (try compileSlaFileToSabWithOptions(
        arena.allocator(),
        "trait_impl_output.sla",
        ".sla-cache/sab/trait_impl_output.sab",
        stderr_buf.writer().any(),
        .{ .prune_for_test_codegen = true, .allow_fallback = false },
    )) orelse {
        std.debug.print("{s}", .{stderr_buf.items});
        return error.TestUnexpectedResult;
    };

    var module = try sci_bridge.sab.decodeModule(std.testing.allocator, sab_bytes);
    defer module.deinit(std.testing.allocator);

    for (module.function_sigs) |fsig| {
        try std.testing.expect(std.mem.indexOf(u8, fsig.name, "UnusedTrait") == null);
        try std.testing.expect(std.mem.indexOf(u8, fsig.name, "UnusedType_value") == null);
    }
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
}

test "sla test empty filter skips sab compilation" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const source =
        \\fn helper() -> i32 {
        \\    return 1;
        \\};
        \\
        \\@test "kept only by another filter"() {
        \\    missing_symbol();
        \\};
    ;
    try tmp.dir.writeFile(.{ .sub_path = "empty_filter.sla", .data = source });

    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var stdout_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stdout_buf.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    var ctx = plugin_api.Context{ .allocator = std.testing.allocator };
    const args = [_][]const u8{
        "sa",
        "sla",
        "test",
        "empty_filter.sla",
        "--test-backend",
        "sab",
        "--filter",
        "definitely no such test",
    };
    const code = try runSlaCommandImpl(&ctx, args[0..], stdout_buf.writer().any(), stderr_buf.writer().any());

    if (code != @as(?u8, 0)) std.debug.print("{s}", .{stderr_buf.items});
    try std.testing.expectEqual(@as(?u8, 0), code);
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buf.items, 1, "0 passed; 0 failed; 0 skipped"));
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);

    const sab_path = try managedSabTestPath(std.testing.allocator, "empty_filter.sla", &.{ "--filter", "definitely no such test" });
    defer std.testing.allocator.free(sab_path);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(sab_path, .{}));
}

test "sla sab backend lowers plain structs directly" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const struct_source =
        \\struct SabPair {
        \\    x: i32,
        \\    y: i32,
        \\}
        \\
        \\fn make_pair(x: i32, y: i32) -> SabPair {
        \\    return SabPair { x: x, y: y };
        \\};
        \\
        \\fn sum_pair(pair: SabPair) -> i32 {
        \\    return pair.x + pair.y;
        \\};
        \\
        \\@test "sab struct fallback"() {
        \\    let pair = make_pair(2, 3);
        \\    let got = sum_pair(pair);
        \\    if got != 5 { panic(25005); };
        \\};
    ;
    try tmp.dir.writeFile(.{ .sub_path = "struct_sab.sla", .data = struct_source });

    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    const sab_bytes = (try compileSlaFileToSabWithOptions(
        arena.allocator(),
        "struct_sab.sla",
        ".sla-cache/sab/struct_sab.sab",
        stderr_buf.writer().any(),
        .{ .test_filter = "sab struct fallback", .allow_fallback = false },
    )) orelse {
        std.debug.print("{s}", .{stderr_buf.items});
        return error.TestUnexpectedResult;
    };

    try std.testing.expectError(error.FileNotFound, tmp.dir.access("struct_sab.test.sa", .{}));
    try std.testing.expect(std.mem.startsWith(u8, sab_bytes, sci_bridge.sab.magic));

    var module = try sci_bridge.sab.decodeModule(std.testing.allocator, sab_bytes);
    defer module.deinit(std.testing.allocator);
    var test_count: usize = 0;
    var saw_alloc = false;
    var saw_store = false;
    var saw_load = false;
    for (module.function_sigs) |fsig| {
        if (fsig.kind == .test_func) test_count += 1;
    }
    for (module.instructions) |item| {
        if (item.kind == .alloc) saw_alloc = true;
        if (item.kind == .store) saw_store = true;
        if (item.kind == .load) saw_load = true;
    }
    try std.testing.expectEqual(@as(usize, 1), test_count);
    try std.testing.expect(saw_alloc);
    try std.testing.expect(saw_store);
    try std.testing.expect(saw_load);
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
}

test "sla sab backend lowers function pointers directly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    const sab_bytes = (try compileSlaFileToSabWithOptions(
        arena.allocator(),
        "tests/test_unit_fn_ptr_value.sla",
        ".sla-cache/sab/fn_ptr_value.sab",
        stderr_buf.writer().any(),
        .{ .test_filter = "function pointer can be passed as argument", .allow_fallback = false },
    )) orelse {
        std.debug.print("{s}", .{stderr_buf.items});
        return error.TestUnexpectedResult;
    };

    var module = try sci_bridge.sab.decodeModule(std.testing.allocator, sab_bytes);
    defer module.deinit(std.testing.allocator);

    var test_count: usize = 0;
    var saw_fnptr_vtable = false;
    var saw_borrow = false;
    var saw_call_indirect = false;
    for (module.function_sigs) |fsig| {
        if (fsig.kind == .test_func) test_count += 1;
    }
    for (module.const_decls) |decl| {
        if (std.mem.eql(u8, decl.name, "SLA_FNPTR_VT_fn_ptr_inc") and decl.value == .vtable) {
            saw_fnptr_vtable = true;
        }
    }
    for (module.instructions) |item| {
        try std.testing.expectEqualStrings("", item.raw_text);
        if (item.kind == .borrow) saw_borrow = true;
        if (item.kind == .call_indirect) saw_call_indirect = true;
    }
    try std.testing.expectEqual(@as(usize, 1), test_count);
    try std.testing.expect(saw_fnptr_vtable);
    try std.testing.expect(saw_borrow);
    try std.testing.expect(saw_call_indirect);
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
}

test "sla sab backend lowers escaped thread closure function pointer callee directly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    const sab_bytes = (try compileSlaFileToSabWithOptions(
        arena.allocator(),
        "tests/test_unit_fn_ptr_value.sla",
        ".sla-cache/sab/fn_ptr_thread_direct.sab",
        stderr_buf.writer().any(),
        .{ .test_filter = "thread closure captures function pointer callee", .allow_fallback = false },
    )) orelse {
        std.debug.print("{s}", .{stderr_buf.items});
        return error.TestUnexpectedResult;
    };

    var module = try sci_bridge.sab.decodeModule(std.testing.allocator, sab_bytes);
    defer module.deinit(std.testing.allocator);

    var saw_thread_vtable = false;
    var saw_spawn_wrapper = false;
    var saw_worker = false;
    var saw_raw_cast = false;
    var saw_assume_safe = false;
    var saw_call_indirect = false;
    for (module.const_decls) |decl| {
        if (std.mem.startsWith(u8, decl.name, "SLA_THREAD_VT_") and decl.value == .vtable) saw_thread_vtable = true;
    }
    for (module.function_sigs) |fsig| {
        if (std.mem.startsWith(u8, fsig.name, "sla_thread_spawn_") and fsig.is_ffi_wrapper) saw_spawn_wrapper = true;
        if (std.mem.startsWith(u8, fsig.name, "sla_thread_worker_")) saw_worker = true;
    }
    for (module.instructions) |item| {
        try std.testing.expectEqualStrings("", item.raw_text);
        if (item.kind == .raw_cast) saw_raw_cast = true;
        if (item.kind == .assume_safe) saw_assume_safe = true;
        if (item.kind == .call_indirect) saw_call_indirect = true;
    }
    try std.testing.expect(saw_thread_vtable);
    try std.testing.expect(saw_spawn_wrapper);
    try std.testing.expect(saw_worker);
    try std.testing.expect(saw_raw_cast);
    try std.testing.expect(saw_assume_safe);
    try std.testing.expect(saw_call_indirect);
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
}

test "sla sab escaped loop closure loads stack slot scalar capture" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    const sab_bytes = (try compileSlaFileToSabWithOptions(
        arena.allocator(),
        "tests/test_unit_fn_ptr_value.sla",
        ".sla-cache/sab/fn_ptr_thread_loop_capture_direct.sab",
        stderr_buf.writer().any(),
        .{ .test_filter = "loop thread closures capture bool function pointer callee", .allow_fallback = false },
    )) orelse {
        std.debug.print("{s}", .{stderr_buf.items});
        return error.TestUnexpectedResult;
    };

    var module = try sci_bridge.sab.decodeModule(std.testing.allocator, sab_bytes);
    defer module.deinit(std.testing.allocator);
    var start: ?usize = null;
    var end = module.instructions.len;
    for (module.function_sigs, 0..) |fsig, idx| {
        if (!std.mem.eql(u8, fsig.name, "sla__fn_ptr_thread_bool_loop_pair")) continue;
        start = fsig.entry_inst_idx;
        if (idx + 1 < module.function_sigs.len) end = module.function_sigs[idx + 1].entry_inst_idx;
        break;
    }

    var stack_regs = std.AutoHashMap(u32, void).init(std.testing.allocator);
    defer stack_regs.deinit();
    var saw_capture_store = false;
    for (module.instructions[start orelse return error.TestUnexpectedResult .. end]) |item| {
        if (item.kind == .stack_alloc and item.operands[0] == .reg) try stack_regs.put(item.operands[0].reg, {});
        if (item.kind != .store or item.operands[1] != .imm_u64 or item.operands[1].imm_u64 != 24 or item.operands[2] != .reg) continue;
        saw_capture_store = true;
        try std.testing.expect(!stack_regs.contains(item.operands[2].reg));
    }
    try std.testing.expect(saw_capture_store);
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
}

test "sla sab backend lowers paired escaped thread function pointer callees directly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    const sab_bytes = (try compileSlaFileToSabWithOptions(
        arena.allocator(),
        "tests/test_unit_fn_ptr_thread_pair_direct.sla",
        ".sla-cache/sab/fn_ptr_thread_pair_direct.sab",
        stderr_buf.writer().any(),
        .{ .test_filter = "thread closures capture function pointer pair", .allow_fallback = false },
    )) orelse {
        std.debug.print("{s}", .{stderr_buf.items});
        return error.TestUnexpectedResult;
    };

    var module = try sci_bridge.sab.decodeModule(std.testing.allocator, sab_bytes);
    defer module.deinit(std.testing.allocator);

    var worker_count: usize = 0;
    var indirect_count: usize = 0;
    for (module.function_sigs) |fsig| {
        if (std.mem.startsWith(u8, fsig.name, "sla_thread_worker_")) worker_count += 1;
    }
    for (module.instructions) |item| {
        try std.testing.expectEqualStrings("", item.raw_text);
        if (item.kind == .call_indirect) indirect_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), worker_count);
    try std.testing.expect(indirect_count >= 2);
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
}

test "sla sab backend lowers multi-argument calls directly" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const source =
        \\fn add3(a: i32, b: i32, c: i32) -> i32 {
        \\    return a + b + c;
        \\};
        \\
        \\@test "direct sab add3"() {
        \\    let got = add3(2, 3, 4);
        \\    if got != 9 { panic(27009); };
        \\};
    ;
    try tmp.dir.writeFile(.{ .sub_path = "add3.sla", .data = source });
    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    const sab_bytes = (try compileSlaFileToSabWithOptions(
        arena.allocator(),
        "add3.sla",
        ".sla-cache/sab/add3.sab",
        stderr_buf.writer().any(),
        .{ .test_filter = "direct sab add3", .allow_fallback = false },
    )) orelse {
        std.debug.print("{s}", .{stderr_buf.items});
        return error.TestUnexpectedResult;
    };

    var module = try sci_bridge.sab.decodeModule(std.testing.allocator, sab_bytes);
    defer module.deinit(std.testing.allocator);

    var saw_three_arg_call = false;
    for (module.instructions) |item| {
        if (item.kind == .call and item.operands[1] == .text and std.mem.indexOf(u8, item.operands[1].text, ", tmp_") != null) {
            if (std.mem.count(u8, item.operands[1].text, ",") == 2) saw_three_arg_call = true;
        }
    }
    try std.testing.expect(saw_three_arg_call);
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
}

test "sla sab backend lowers imported std surface metadata directly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    const sab_bytes = (try compileSlaFileToSabWithOptions(
        arena.allocator(),
        "tests/test_unit_fn_ptr_value.sla",
        ".sla-cache/sab/fn_ptr_vec_direct.sab",
        stderr_buf.writer().any(),
        .{ .test_filter = "function pointer survives vec push through function", .allow_fallback = false },
    )) orelse {
        std.debug.print("{s}", .{stderr_buf.items});
        return error.TestUnexpectedResult;
    };

    var module = try sci_bridge.sab.decodeModule(std.testing.allocator, sab_bytes);
    defer module.deinit(std.testing.allocator);

    var saw_vec_push = false;
    var saw_vec_new = false;
    var saw_unrelated_vec_free = false;
    var saw_call_indirect = false;
    for (module.function_sigs) |fsig| {
        if (std.mem.eql(u8, fsig.name, "sa_vec_push")) saw_vec_push = true;
        if (std.mem.eql(u8, fsig.name, "sa_vec_new")) saw_vec_new = true;
        if (std.mem.eql(u8, fsig.name, "sa_vec_free")) saw_unrelated_vec_free = true;
    }
    for (module.instructions) |item| {
        try std.testing.expectEqualStrings("", item.raw_text);
        if (item.kind == .call_indirect) saw_call_indirect = true;
    }
    try std.testing.expect(saw_vec_push);
    try std.testing.expect(saw_vec_new);
    try std.testing.expect(!saw_unrelated_vec_free);
    try std.testing.expect(saw_call_indirect);
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
}

test "sla sab backend lowers std surface function metadata directly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    const sab_bytes = (try compileSlaFileToSabWithOptions(
        arena.allocator(),
        "tests/test_unit_vec_len_direct.sla",
        ".sla-cache/sab/vec_len_direct.sab",
        stderr_buf.writer().any(),
        .{ .test_filter = "direct vec len metadata", .allow_fallback = false },
    )) orelse {
        std.debug.print("{s}", .{stderr_buf.items});
        return error.TestUnexpectedResult;
    };

    var module = try sci_bridge.sab.decodeModule(std.testing.allocator, sab_bytes);
    defer module.deinit(std.testing.allocator);

    var saw_vec_len = false;
    var saw_len_call = false;
    for (module.function_sigs) |fsig| {
        if (std.mem.eql(u8, fsig.name, "sa_vec_len")) saw_vec_len = true;
    }
    for (module.instructions) |item| {
        try std.testing.expectEqualStrings("", item.raw_text);
        if (item.kind == .call and item.operands[1] == .text and std.mem.indexOf(u8, item.operands[1].text, "@sa_vec_len") != null) {
            saw_len_call = true;
        }
    }
    try std.testing.expect(saw_vec_len);
    try std.testing.expect(saw_len_call);
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
}

test "sla sab backend lowers typed vec index directly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    const sab_bytes = (try compileSlaFileToSabWithOptions(
        arena.allocator(),
        "tests/test_unit_vec_index_direct.sla",
        ".sla-cache/sab/vec_index_direct.sab",
        stderr_buf.writer().any(),
        .{ .test_filter = "direct vec i32 index uses element width", .allow_fallback = false },
    )) orelse {
        std.debug.print("{s}", .{stderr_buf.items});
        return error.TestUnexpectedResult;
    };

    var module = try sci_bridge.sab.decodeModule(std.testing.allocator, sab_bytes);
    defer module.deinit(std.testing.allocator);

    var saw_i32_load = false;
    var saw_i32_storage_stride = false;
    var saw_raw_i32_width_stride = false;
    for (module.instructions) |item| {
        try std.testing.expectEqualStrings("", item.raw_text);
        if (item.kind == .load and item.operands[3] == .ty and item.operands[3].ty == @intFromEnum(sci_bridge.sab.signature.PrimType.i32)) {
            saw_i32_load = true;
        }
        if (item.kind == .op and item.op_kind == .mul and item.operands[2] == .imm_i64) {
            if (item.operands[2].imm_i64 == 8) saw_i32_storage_stride = true;
            if (item.operands[2].imm_i64 == 4) saw_raw_i32_width_stride = true;
        }
    }
    try std.testing.expect(saw_i32_load);
    try std.testing.expect(saw_i32_storage_stride);
    try std.testing.expect(!saw_raw_i32_width_stride);
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
}

test "sla sab backend lowers fallible std surface metadata directly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    const sab_bytes = (try compileSlaFileToSabWithOptions(
        arena.allocator(),
        "tests/test_unit_vec_remove_direct.sla",
        ".sla-cache/sab/vec_remove_direct.sab",
        stderr_buf.writer().any(),
        .{ .test_filter = "direct vec remove metadata", .allow_fallback = false },
    )) orelse {
        std.debug.print("{s}", .{stderr_buf.items});
        return error.TestUnexpectedResult;
    };

    var module = try sci_bridge.sab.decodeModule(std.testing.allocator, sab_bytes);
    defer module.deinit(std.testing.allocator);

    var saw_vec_try_remove = false;
    var saw_remove_call = false;
    var saw_fallible_branch = false;
    var saw_panic_86 = false;
    for (module.function_sigs) |fsig| {
        if (std.mem.eql(u8, fsig.name, "sa_vec_try_remove")) saw_vec_try_remove = true;
    }
    for (module.instructions) |item| {
        try std.testing.expectEqualStrings("", item.raw_text);
        if (item.kind == .call and item.operands[1] == .text and std.mem.indexOf(u8, item.operands[1].text, "@sa_vec_try_remove") != null) {
            saw_remove_call = true;
        }
        if (item.kind == .br) saw_fallible_branch = true;
        if (item.kind == .panic and item.operands[0] == .text and std.mem.eql(u8, item.operands[0].text, "86")) {
            saw_panic_86 = true;
        }
    }
    try std.testing.expect(saw_vec_try_remove);
    try std.testing.expect(saw_remove_call);
    try std.testing.expect(saw_fallible_branch);
    try std.testing.expect(saw_panic_86);
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
}

test "sla sab backend lowers option std surface metadata directly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    const sab_bytes = (try compileSlaFileToSabWithOptions(
        arena.allocator(),
        "tests/test_unit_option_direct.sla",
        ".sla-cache/sab/option_direct.sab",
        stderr_buf.writer().any(),
        .{ .test_filter = "direct option constructors and query methods", .allow_fallback = false },
    )) orelse {
        std.debug.print("{s}", .{stderr_buf.items});
        return error.TestUnexpectedResult;
    };

    var module = try sci_bridge.sab.decodeModule(std.testing.allocator, sab_bytes);
    defer module.deinit(std.testing.allocator);

    var saw_alloc = false;
    var saw_store = false;
    var saw_load = false;
    var saw_unwrap_panic_const = false;
    var saw_panic_msg = false;
    for (module.const_decls) |decl| {
        if (std.mem.eql(u8, decl.name, "OPTION_UNWRAP_PANIC")) saw_unwrap_panic_const = true;
    }
    for (module.instructions) |item| {
        try std.testing.expectEqualStrings("", item.raw_text);
        if (item.kind == .alloc) saw_alloc = true;
        if (item.kind == .store) saw_store = true;
        if (item.kind == .load) saw_load = true;
        if (item.kind == .panic_msg) saw_panic_msg = true;
    }
    try std.testing.expect(saw_alloc);
    try std.testing.expect(saw_store);
    try std.testing.expect(saw_load);
    try std.testing.expect(saw_unwrap_panic_const);
    try std.testing.expect(saw_panic_msg);
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
}

test "sla sab backend lowers result std surface metadata directly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    const sab_bytes = (try compileSlaFileToSabWithOptions(
        arena.allocator(),
        "tests/test_unit_result_direct.sla",
        ".sla-cache/sab/result_direct.sab",
        stderr_buf.writer().any(),
        .{ .test_filter = "direct result constructors and query methods", .allow_fallback = false },
    )) orelse {
        std.debug.print("{s}", .{stderr_buf.items});
        return error.TestUnexpectedResult;
    };

    var module = try sci_bridge.sab.decodeModule(std.testing.allocator, sab_bytes);
    defer module.deinit(std.testing.allocator);

    var saw_alloc = false;
    var saw_store = false;
    var saw_load = false;
    var saw_unwrap_panic_const = false;
    for (module.const_decls) |decl| {
        if (std.mem.eql(u8, decl.name, "RESULT_UNWRAP_PANIC")) saw_unwrap_panic_const = true;
    }
    for (module.instructions) |item| {
        try std.testing.expectEqualStrings("", item.raw_text);
        if (item.kind == .alloc) saw_alloc = true;
        if (item.kind == .store) saw_store = true;
        if (item.kind == .load) saw_load = true;
    }
    try std.testing.expect(saw_alloc);
    try std.testing.expect(saw_store);
    try std.testing.expect(saw_load);
    try std.testing.expect(saw_unwrap_panic_const);
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
}

test "sla sab backend lowers closure calls directly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    const sab_bytes = (try compileSlaFileToSabWithOptions(
        arena.allocator(),
        "tests/test_unit_closures.sla",
        ".sla-cache/sab/closures_direct.sab",
        stderr_buf.writer().any(),
        .{ .test_filter = "closure supports multiple params", .allow_fallback = false },
    )) orelse {
        std.debug.print("{s}", .{stderr_buf.items});
        return error.TestUnexpectedResult;
    };

    var module = try sci_bridge.sab.decodeModule(std.testing.allocator, sab_bytes);
    defer module.deinit(std.testing.allocator);

    var saw_closure_func = false;
    for (module.function_sigs) |fsig| {
        if (std.mem.eql(u8, fsig.name, "sla__closure_two_args")) saw_closure_func = true;
    }
    for (module.instructions) |item| try std.testing.expectEqualStrings("", item.raw_text);
    try std.testing.expect(saw_closure_func);
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
}

test "sla sab backend lowers var scalar slots directly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    const sab_bytes = (try compileSlaFileToSabWithOptions(
        arena.allocator(),
        "tests/test_unit_var_phase1.sla",
        ".sla-cache/sab/var_phase1_direct.sab",
        stderr_buf.writer().any(),
        .{ .test_filter = "var initialized before loop remains readable", .allow_fallback = false },
    )) orelse {
        std.debug.print("{s}", .{stderr_buf.items});
        return error.TestUnexpectedResult;
    };

    var module = try sci_bridge.sab.decodeModule(std.testing.allocator, sab_bytes);
    defer module.deinit(std.testing.allocator);

    var saw_stack_alloc = false;
    var saw_loop_jump = false;
    for (module.instructions) |item| {
        try std.testing.expectEqualStrings("", item.raw_text);
        if (item.kind == .stack_alloc) saw_stack_alloc = true;
        if (item.kind == .jmp) saw_loop_jump = true;
    }
    try std.testing.expect(saw_stack_alloc);
    try std.testing.expect(saw_loop_jump);
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
}

test "sla sab backend lowers tuple literals and destructuring directly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    const sab_bytes = (try compileSlaFileToSabWithOptions(
        arena.allocator(),
        "tests/test_unit_tuples.sla",
        ".sla-cache/sab/tuples_direct.sab",
        stderr_buf.writer().any(),
        .{ .test_filter = "tuple destructuring", .allow_fallback = false },
    )) orelse {
        std.debug.print("{s}", .{stderr_buf.items});
        return error.TestUnexpectedResult;
    };

    var module = try sci_bridge.sab.decodeModule(std.testing.allocator, sab_bytes);
    defer module.deinit(std.testing.allocator);

    var saw_alloc = false;
    var saw_load = false;
    var saw_store = false;
    for (module.instructions) |item| {
        try std.testing.expectEqualStrings("", item.raw_text);
        if (item.kind == .alloc) saw_alloc = true;
        if (item.kind == .load) saw_load = true;
        if (item.kind == .store) saw_store = true;
    }
    try std.testing.expect(saw_alloc);
    try std.testing.expect(saw_load);
    try std.testing.expect(saw_store);
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
}

test "sla sab backend lowers scalar if expressions directly" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const source =
        \\fn pick(cond: bool) -> i32 {
        \\    return if cond { 3 } else { 4 };
        \\};
        \\
        \\@test "if value"() {
        \\    if pick(true) != 3 { panic(30101); };
        \\    if pick(false) != 4 { panic(30102); };
        \\};
    ;
    try tmp.dir.writeFile(.{ .sub_path = "if_value.sla", .data = source });
    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    const sab_bytes = (try compileSlaFileToSabWithOptions(
        arena.allocator(),
        "if_value.sla",
        ".sla-cache/sab/if_value.sab",
        stderr_buf.writer().any(),
        .{ .test_filter = "if value", .allow_fallback = false },
    )) orelse {
        std.debug.print("{s}", .{stderr_buf.items});
        return error.TestUnexpectedResult;
    };

    var module = try sci_bridge.sab.decodeModule(std.testing.allocator, sab_bytes);
    defer module.deinit(std.testing.allocator);
    for (module.instructions) |item| try std.testing.expectEqualStrings("", item.raw_text);
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
}

test "sla sab backend lowers typed if bindings and var assignments directly" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const source =
        \\fn typed_pick(cond: bool) -> i32 {
        \\    let value: i32 = if cond { 1 } else { 2 };
        \\    return value;
        \\};
        \\
        \\fn var_pick(cond: bool) -> i32 {
        \\    var x: i32;
        \\    x = if cond { 8 } else { 9 };
        \\    return x;
        \\};
        \\
        \\fn bool_pick(cond: bool) -> bool {
        \\    return if cond { true } else { false };
        \\};
        \\
        \\fn float_pick(cond: bool) -> f64 {
        \\    return if cond { 1.5 } else { 2.5 };
        \\};
        \\
        \\@test "if binding variants"() {
        \\    if typed_pick(true) != 1 { panic(30301); };
        \\    if typed_pick(false) != 2 { panic(30302); };
        \\    if var_pick(true) != 8 { panic(30303); };
        \\    if var_pick(false) != 9 { panic(30304); };
        \\    if bool_pick(true) != true { panic(30305); };
        \\    if bool_pick(false) { panic(30306); };
        \\    if float_pick(true) != 1.5 { panic(30307); };
        \\    if float_pick(false) != 2.5 { panic(30308); };
        \\};
    ;
    try tmp.dir.writeFile(.{ .sub_path = "if_binding_variants.sla", .data = source });
    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    const sab_bytes = (try compileSlaFileToSabWithOptions(
        arena.allocator(),
        "if_binding_variants.sla",
        ".sla-cache/sab/if_binding_variants.sab",
        stderr_buf.writer().any(),
        .{ .test_filter = "if binding variants", .allow_fallback = false },
    )) orelse {
        std.debug.print("{s}", .{stderr_buf.items});
        return error.TestUnexpectedResult;
    };

    var module = try sci_bridge.sab.decodeModule(std.testing.allocator, sab_bytes);
    defer module.deinit(std.testing.allocator);
    for (module.instructions) |item| try std.testing.expectEqualStrings("", item.raw_text);
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
}

test "sla sab backend lowers nested if assignments directly" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const source =
        \\fn nested(a: bool, b: bool) -> i32 {
        \\    var x: i32;
        \\    if a {
        \\        x = if b { 11 } else { 12 };
        \\    } else {
        \\        x = if b { 13 } else { 14 };
        \\    };
        \\    return x;
        \\};
        \\
        \\fn reassign_let(cond: bool) -> i32 {
        \\    let x: i32 = 0;
        \\    if cond {
        \\        x = 21;
        \\    } else {
        \\        x = 22;
        \\    };
        \\    return x;
        \\};
        \\
        \\@test "nested if assignments"() {
        \\    if nested(true, true) != 11 { panic(30401); };
        \\    if nested(true, false) != 12 { panic(30402); };
        \\    if nested(false, true) != 13 { panic(30403); };
        \\    if nested(false, false) != 14 { panic(30404); };
        \\    if reassign_let(true) != 21 { panic(30405); };
        \\    if reassign_let(false) != 22 { panic(30406); };
        \\};
    ;
    try tmp.dir.writeFile(.{ .sub_path = "nested_if_assignments.sla", .data = source });
    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    const sab_bytes = (try compileSlaFileToSabWithOptions(
        arena.allocator(),
        "nested_if_assignments.sla",
        ".sla-cache/sab/nested_if_assignments.sab",
        stderr_buf.writer().any(),
        .{ .test_filter = "nested if assignments", .allow_fallback = false },
    )) orelse {
        std.debug.print("{s}", .{stderr_buf.items});
        return error.TestUnexpectedResult;
    };

    var module = try sci_bridge.sab.decodeModule(std.testing.allocator, sab_bytes);
    defer module.deinit(std.testing.allocator);
    for (module.instructions) |item| try std.testing.expectEqualStrings("", item.raw_text);
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
}

test "sla sab backend lowers float arithmetic directly" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const source =
        \\@test "float add"() {
        \\    let sum = 1.5 + 2.25;
        \\    if sum != 3.75 { panic(30201); };
        \\};
    ;
    try tmp.dir.writeFile(.{ .sub_path = "float_add.sla", .data = source });
    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    const sab_bytes = (try compileSlaFileToSabWithOptions(
        arena.allocator(),
        "float_add.sla",
        ".sla-cache/sab/float_add.sab",
        stderr_buf.writer().any(),
        .{ .test_filter = "float add", .allow_fallback = false },
    )) orelse {
        std.debug.print("{s}", .{stderr_buf.items});
        return error.TestUnexpectedResult;
    };

    var module = try sci_bridge.sab.decodeModule(std.testing.allocator, sab_bytes);
    defer module.deinit(std.testing.allocator);
    var saw_fadd = false;
    var saw_fcmp = false;
    for (module.instructions) |item| {
        try std.testing.expectEqualStrings("", item.raw_text);
        if (item.kind == .op and item.op_kind == .fadd) saw_fadd = true;
        if (item.kind == .op and item.op_kind == .fcmp_ne) saw_fcmp = true;
    }
    try std.testing.expect(saw_fadd);
    try std.testing.expect(saw_fcmp);
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
}

test "sla sab backend lowers boolean logic directly" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const source =
        \\fn both(a: bool, b: bool) -> bool {
        \\    return a && b;
        \\};
        \\
        \\fn either(a: bool, b: bool) -> bool {
        \\    return a || b;
        \\};
        \\
        \\@test "boolean logic"() {
        \\    if both(true, true) != true { panic(30501); };
        \\    if both(true, false) { panic(30502); };
        \\    if either(false, true) != true { panic(30503); };
        \\    if either(false, false) { panic(30504); };
        \\};
    ;
    try tmp.dir.writeFile(.{ .sub_path = "boolean_logic.sla", .data = source });
    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    const sab_bytes = (try compileSlaFileToSabWithOptions(
        arena.allocator(),
        "boolean_logic.sla",
        ".sla-cache/sab/boolean_logic.sab",
        stderr_buf.writer().any(),
        .{ .test_filter = "boolean logic", .allow_fallback = false },
    )) orelse {
        std.debug.print("{s}", .{stderr_buf.items});
        return error.TestUnexpectedResult;
    };

    var module = try sci_bridge.sab.decodeModule(std.testing.allocator, sab_bytes);
    defer module.deinit(std.testing.allocator);
    var saw_and = false;
    var saw_or = false;
    for (module.instructions) |item| {
        try std.testing.expectEqualStrings("", item.raw_text);
        if (item.kind == .op and item.op_kind == .@"and") saw_and = true;
        if (item.kind == .op and item.op_kind == .@"or") saw_or = true;
    }
    try std.testing.expect(saw_and);
    try std.testing.expect(saw_or);
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
}

test "sla sab backend lowers numeric casts directly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    const sab_bytes = (try compileSlaFileToSabWithOptions(
        arena.allocator(),
        "tests/test_unit_numeric_casts.sla",
        ".sla-cache/sab/numeric_casts_direct.sab",
        stderr_buf.writer().any(),
        .{ .test_filter = "numeric casts direct", .allow_fallback = false },
    )) orelse {
        std.debug.print("{s}", .{stderr_buf.items});
        return error.TestUnexpectedResult;
    };

    var module = try sci_bridge.sab.decodeModule(std.testing.allocator, sab_bytes);
    defer module.deinit(std.testing.allocator);
    var saw_trunc = false;
    var saw_zext = false;
    var saw_sext = false;
    var saw_sitofp = false;
    var saw_fptosi = false;
    var saw_fptrunc = false;
    var saw_fpext = false;
    for (module.instructions) |item| {
        try std.testing.expectEqualStrings("", item.raw_text);
        if (item.kind == .op and item.operands[2] == .ty) {
            if (item.op_kind == .trunc) saw_trunc = true;
            if (item.op_kind == .zext) saw_zext = true;
            if (item.op_kind == .sext) saw_sext = true;
            if (item.op_kind == .sitofp) saw_sitofp = true;
            if (item.op_kind == .fptosi) saw_fptosi = true;
            if (item.op_kind == .fptrunc) saw_fptrunc = true;
            if (item.op_kind == .fpext) saw_fpext = true;
        }
    }
    try std.testing.expect(saw_trunc);
    try std.testing.expect(saw_zext);
    try std.testing.expect(saw_sext);
    try std.testing.expect(saw_sitofp);
    try std.testing.expect(saw_fptosi);
    try std.testing.expect(saw_fptrunc);
    try std.testing.expect(saw_fpext);
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
}

test "sla sab backend lowers borrow and deref directly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    const sab_bytes = (try compileSlaFileToSabWithOptions(
        arena.allocator(),
        "tests/test_unit_borrow_direct.sla",
        ".sla-cache/sab/borrow_direct.sab",
        stderr_buf.writer().any(),
        .{ .test_filter = "direct borrow deref", .allow_fallback = false },
    )) orelse {
        std.debug.print("{s}", .{stderr_buf.items});
        return error.TestUnexpectedResult;
    };

    var module = try sci_bridge.sab.decodeModule(std.testing.allocator, sab_bytes);
    defer module.deinit(std.testing.allocator);
    var saw_borrow = false;
    var saw_load = false;
    var saw_stack_alloc = false;
    for (module.instructions) |item| {
        try std.testing.expectEqualStrings("", item.raw_text);
        if (item.kind == .borrow) saw_borrow = true;
        if (item.kind == .load) saw_load = true;
        if (item.kind == .stack_alloc) saw_stack_alloc = true;
    }
    try std.testing.expect(saw_borrow);
    try std.testing.expect(saw_load);
    try std.testing.expect(saw_stack_alloc);
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
}

test "sla sab backend lowers array literals dynamic indexes and range for directly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    const sab_bytes = (try compileSlaFileToSabWithOptions(
        arena.allocator(),
        "tests/test_unit_array_direct.sla",
        ".sla-cache/sab/array_direct.sab",
        stderr_buf.writer().any(),
        .{ .test_filter = "direct array literal repeat dynamic index range for", .allow_fallback = false },
    )) orelse {
        std.debug.print("{s}", .{stderr_buf.items});
        return error.TestUnexpectedResult;
    };

    var module = try sci_bridge.sab.decodeModule(std.testing.allocator, sab_bytes);
    defer module.deinit(std.testing.allocator);
    var saw_alloc = false;
    var saw_store = false;
    var saw_load = false;
    var saw_ptr_add = false;
    var saw_stack_alloc = false;
    for (module.instructions) |item| {
        try std.testing.expectEqualStrings("", item.raw_text);
        if (item.kind == .alloc) saw_alloc = true;
        if (item.kind == .store) saw_store = true;
        if (item.kind == .load) saw_load = true;
        if (item.kind == .ptr_add) saw_ptr_add = true;
        if (item.kind == .stack_alloc) saw_stack_alloc = true;
    }
    try std.testing.expect(saw_alloc);
    try std.testing.expect(saw_store);
    try std.testing.expect(saw_load);
    try std.testing.expect(saw_ptr_add);
    try std.testing.expect(saw_stack_alloc);
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
}

test "sla sab backend lowers move arguments through fresh temps" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    const sab_bytes = (try compileSlaFileToSabWithOptions(
        arena.allocator(),
        "tests/test_unit_move_direct.sla",
        ".sla-cache/sab/move_direct.sab",
        stderr_buf.writer().any(),
        .{ .test_filter = "direct move struct argument", .allow_fallback = false },
    )) orelse {
        std.debug.print("{s}", .{stderr_buf.items});
        return error.TestUnexpectedResult;
    };

    var module = try sci_bridge.sab.decodeModule(std.testing.allocator, sab_bytes);
    defer module.deinit(std.testing.allocator);
    var saw_fresh_move_call = false;
    var saw_direct_binding_move_call = false;
    for (module.instructions) |item| {
        try std.testing.expectEqualStrings("", item.raw_text);
        if (item.kind == .call and item.operands[1] == .text) {
            if (std.mem.indexOf(u8, item.operands[1].text, "^tmp_") != null) saw_fresh_move_call = true;
            if (std.mem.indexOf(u8, item.operands[1].text, "^item") != null) saw_direct_binding_move_call = true;
        }
    }
    try std.testing.expect(saw_fresh_move_call);
    try std.testing.expect(!saw_direct_binding_move_call);
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
}

test "sla sab build emits direct SAB without SA source output" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const direct_source =
        \\fn add(a: i32, b: i32) -> i32 {
        \\    let c = a + b;
        \\    return c;
        \\};
        \\
        \\fn main() -> i32 {
        \\    let x = add(2, 3);
        \\    return x;
        \\};
    ;
    try tmp.dir.writeFile(.{ .sub_path = "direct.sla", .data = direct_source });

    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var stdout_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stdout_buf.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    var ctx = plugin_api.Context{ .allocator = std.testing.allocator };
    const args = [_][]const u8{ "sa", "sla", "sab", "build", "direct.sla", "--out", "direct.sab" };
    const code = try runSlaCommandImpl(&ctx, args[0..], stdout_buf.writer().any(), stderr_buf.writer().any());

    if (code != @as(?u8, 0)) std.debug.print("{s}", .{stderr_buf.items});
    try std.testing.expectEqual(@as(?u8, 0), code);
    try tmp.dir.access("direct.sab", .{});
    try std.testing.expectError(error.FileNotFound, tmp.dir.access("direct.sa", .{}));

    const sab_bytes = try tmp.dir.readFileAlloc(std.testing.allocator, "direct.sab", 1024 * 1024);
    defer std.testing.allocator.free(sab_bytes);
    try std.testing.expect(std.mem.startsWith(u8, sab_bytes, sci_bridge.sab.magic));
    try std.testing.expect(std.mem.indexOf(u8, sab_bytes, "tmp_0 = add") == null);
    try std.testing.expect(std.mem.indexOf(u8, sab_bytes, "return tmp_") == null);

    var module = try sci_bridge.sab.decodeModule(std.testing.allocator, sab_bytes);
    defer module.deinit(std.testing.allocator);

    try std.testing.expect(module.function_sigs.len >= 2);
    var saw_func_decl = false;
    var saw_add_op = false;
    var saw_call = false;
    var saw_return = false;
    for (module.instructions) |item| {
        switch (item.kind) {
            .func_decl => saw_func_decl = true,
            .op => {
                if (item.op_kind == .add) saw_add_op = true;
            },
            .call => saw_call = true,
            .return_ => saw_return = true,
            else => {},
        }
    }
    try std.testing.expect(saw_func_decl);
    try std.testing.expect(saw_add_op);
    try std.testing.expect(saw_call);
    try std.testing.expect(saw_return);
}

test "sla sab build defaults to managed sla cache" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const direct_source =
        \\fn main() -> i32 {
        \\    return 5;
        \\};
    ;
    try tmp.dir.writeFile(.{ .sub_path = "direct.sla", .data = direct_source });

    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var stdout_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stdout_buf.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    var ctx = plugin_api.Context{ .allocator = std.testing.allocator };
    const args = [_][]const u8{ "sa", "sla", "sab", "build", "direct.sla" };
    const code = try runSlaCommandImpl(&ctx, args[0..], stdout_buf.writer().any(), stderr_buf.writer().any());

    if (code != @as(?u8, 0)) std.debug.print("{s}", .{stderr_buf.items});
    try std.testing.expectEqual(@as(?u8, 0), code);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access("direct.sab", .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access("direct.sa", .{}));

    const cached_path = try managedSabPath(std.testing.allocator, "direct.sla");
    defer std.testing.allocator.free(cached_path);
    try tmp.dir.access(cached_path, .{});
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buf.items, 1, ".sla-cache/sab/"));

    const sab_bytes = try tmp.dir.readFileAlloc(std.testing.allocator, cached_path, 1024 * 1024);
    defer std.testing.allocator.free(sab_bytes);
    try std.testing.expect(std.mem.startsWith(u8, sab_bytes, sci_bridge.sab.magic));
}

fn writeWorkspaceFixture(dir: std.fs.Dir, default_member: []const u8, tool_source: []const u8) !void {
    try dir.makePath("members/app/src");
    try dir.makePath("members/tool/src");

    const root_manifest = if (std.mem.eql(u8, default_member, "tool"))
        \\workspace {
        \\  members ["members/app", "members/tool"]
        \\  default_member "tool"
        \\}
    else
        \\workspace {
        \\  members ["members/app", "members/tool"]
        \\  default_member "app"
        \\}
    ;
    try dir.writeFile(.{ .sub_path = "sa.mod", .data = root_manifest });
    try dir.writeFile(.{ .sub_path = "members/app/sa.mod", .data = "package \"app\"\n" });
    try dir.writeFile(.{ .sub_path = "members/tool/sa.mod", .data = "package \"tool\"\n" });
    try dir.writeFile(.{ .sub_path = "members/app/src/main.sla", .data = 
        \\fn main() -> i32 {
        \\    return 7;
        \\};
    });
    try dir.writeFile(.{ .sub_path = "members/tool/src/main.sla", .data = tool_source });
}

test "sla build resolves workspace default member when file omitted" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try writeWorkspaceFixture(tmp.dir, "app",
        \\fn main() -> i32 {
        \\    return 9;
        \\};
    );

    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var stdout_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stdout_buf.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    var ctx = plugin_api.Context{ .allocator = std.testing.allocator };
    const args = [_][]const u8{ "sa", "sla", "build" };
    const code = try runSlaCommandImpl(&ctx, args[0..], stdout_buf.writer().any(), stderr_buf.writer().any());

    try std.testing.expectEqual(@as(?u8, 0), code);
    try tmp.dir.access("members/app/src/main.sa", .{});
    try std.testing.expectError(error.FileNotFound, tmp.dir.access("members/tool/src/main.sa", .{}));
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buf.items, 1, "members/app/src/main.sla"));
}

test "sla check prefers current member over workspace default" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try writeWorkspaceFixture(tmp.dir, "tool",
        \\fn broken( {
    );

    var member_dir = try tmp.dir.openDir("members/app/src", .{});
    defer member_dir.close();
    try member_dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var stdout_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stdout_buf.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    var ctx = plugin_api.Context{ .allocator = std.testing.allocator };
    const args = [_][]const u8{ "sa", "sla", "check" };
    const code = try runSlaCommandImpl(&ctx, args[0..], stdout_buf.writer().any(), stderr_buf.writer().any());

    try std.testing.expectEqual(@as(?u8, 0), code);
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buf.items, 1, "members/app/src/main.sla"));
}

test "sla build selects workspace package with -p when file omitted" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try writeWorkspaceFixture(tmp.dir, "app",
        \\fn main() -> i32 {
        \\    return 9;
        \\};
    );

    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var stdout_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stdout_buf.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    var ctx = plugin_api.Context{ .allocator = std.testing.allocator };
    const args = [_][]const u8{ "sa", "sla", "build", "-p", "tool" };
    const code = try runSlaCommandImpl(&ctx, args[0..], stdout_buf.writer().any(), stderr_buf.writer().any());

    try std.testing.expectEqual(@as(?u8, 0), code);
    try tmp.dir.access("members/tool/src/main.sa", .{});
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buf.items, 1, "members/tool/src/main.sla"));
}
