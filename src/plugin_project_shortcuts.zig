const std = @import("std");
const ast = @import("ast.zig");
const plugin_reachability = @import("plugin_reachability.zig");

const SyntacticFactSet = plugin_reachability.SyntacticFactSet;
const evalSyntacticBool = plugin_reachability.evalSyntacticBool;
const evalSyntacticInt = plugin_reachability.evalSyntacticInt;
const nodeIsNoImportSource = plugin_reachability.nodeIsNoImportSource;
const reachabilityBlockUsesIdentifier = plugin_reachability.reachabilityBlockUsesIdentifier;
const reachabilityClosureShadowsIdentifier = plugin_reachability.reachabilityClosureShadowsIdentifier;
const reachabilityNodeBindsIdentifier = plugin_reachability.reachabilityNodeBindsIdentifier;
const updateFactsForLetBinding = plugin_reachability.updateFactsForLetBinding;

fn makeIdentifierNode(allocator: std.mem.Allocator, name: []const u8) !*ast.Node {
    const node = try allocator.create(ast.Node);
    node.* = .{ .identifier = name };
    return node;
}

fn makeIntLiteralNode(allocator: std.mem.Allocator, value: i64) !*ast.Node {
    const node = try allocator.create(ast.Node);
    node.* = .{ .literal = .{ .int_val = value } };
    return node;
}

fn makeBoolLiteralNode(allocator: std.mem.Allocator, value: bool) !*ast.Node {
    const node = try allocator.create(ast.Node);
    node.* = .{ .literal = .{ .bool_val = value } };
    return node;
}

fn makeStringLiteralNode(allocator: std.mem.Allocator, value: []const u8) !*ast.Node {
    const node = try allocator.create(ast.Node);
    node.* = .{ .literal = .{ .string_val = value } };
    return node;
}

fn makeUserDefinedTypeNode(allocator: std.mem.Allocator, name: []const u8) !*ast.Type {
    const ty = try allocator.create(ast.Type);
    ty.* = .{ .user_defined = .{ .name = name, .generics = &.{} } };
    return ty;
}

fn makeFieldExprNode(allocator: std.mem.Allocator, expr: *ast.Node, field_name: []const u8) !*ast.Node {
    const node = try allocator.create(ast.Node);
    node.* = .{ .field_expr = .{ .expr = expr, .field_name = field_name } };
    return node;
}

fn makeCallNode(allocator: std.mem.Allocator, func_name: []const u8, args: []const *ast.Node) !*ast.Node {
    const node = try allocator.create(ast.Node);
    node.* = .{ .call_expr = .{
        .func_name = func_name,
        .generics = &.{},
        .args = args,
    } };
    return node;
}

fn makeSessionStateLiteralNodeWithCounts(
    allocator: std.mem.Allocator,
    snapshot_id: i64,
    project_count: i64,
    open_file_count: i64,
) !*ast.Node {
    const fields = try allocator.alloc(ast.StructLiteralField, 12);
    fields[0] = .{ .name = "snapshot_id", .value = try makeIntLiteralNode(allocator, snapshot_id) };
    fields[1] = .{ .name = "project_count", .value = try makeIntLiteralNode(allocator, project_count) };
    fields[2] = .{ .name = "open_file_count", .value = try makeIntLiteralNode(allocator, open_file_count) };
    fields[3] = .{ .name = "overlay_count", .value = try makeIntLiteralNode(allocator, 0) };
    fields[4] = .{ .name = "tsconfig_found", .value = try makeBoolLiteralNode(allocator, false) };
    fields[5] = .{ .name = "tsconfig_parse_ok", .value = try makeBoolLiteralNode(allocator, false) };
    fields[6] = .{ .name = "tsconfig_file_count", .value = try makeIntLiteralNode(allocator, 0) };
    fields[7] = .{ .name = "tsconfig_ref_count", .value = try makeIntLiteralNode(allocator, 0) };
    fields[8] = .{ .name = "total_nodes", .value = try makeIntLiteralNode(allocator, 0) };
    fields[9] = .{ .name = "total_statements", .value = try makeIntLiteralNode(allocator, 0) };
    fields[10] = .{ .name = "total_declarations", .value = try makeIntLiteralNode(allocator, 0) };
    fields[11] = .{ .name = "total_errors", .value = try makeIntLiteralNode(allocator, 0) };

    const node = try allocator.create(ast.Node);
    node.* = .{ .struct_literal = .{
        .ty = try makeUserDefinedTypeNode(allocator, "SessionState"),
        .fields = fields,
    } };
    return node;
}

fn makeSessionStateLiteralNode(allocator: std.mem.Allocator) !*ast.Node {
    return try makeSessionStateLiteralNodeWithCounts(allocator, 1, 0, 1);
}

fn makeOpenConfiguredProjectsLiteralNode(
    allocator: std.mem.Allocator,
    project_path: *ast.Node,
    project_path_len: *ast.Node,
) !*ast.Node {
    const fields = try allocator.alloc(ast.StructLiteralField, 7);
    fields[0] = .{ .name = "count", .value = try makeIntLiteralNode(allocator, 1) };
    fields[1] = .{ .name = "has_primary", .value = try makeBoolLiteralNode(allocator, true) };
    fields[2] = .{ .name = "primary_project_path", .value = project_path };
    fields[3] = .{ .name = "primary_project_path_len", .value = project_path_len };
    fields[4] = .{ .name = "has_secondary", .value = try makeBoolLiteralNode(allocator, false) };
    fields[5] = .{ .name = "secondary_project_path", .value = try makeStringLiteralNode(allocator, "") };
    fields[6] = .{ .name = "secondary_project_path_len", .value = try makeIntLiteralNode(allocator, 0) };

    const node = try allocator.create(ast.Node);
    node.* = .{ .struct_literal = .{
        .ty = try makeUserDefinedTypeNode(allocator, "ProjectOpenConfiguredProjects"),
        .fields = fields,
    } };
    return node;
}

fn makeTwoOpenConfiguredProjectsLiteralNode(
    allocator: std.mem.Allocator,
    primary_path: *ast.Node,
    primary_path_len: *ast.Node,
    secondary_path: *ast.Node,
    secondary_path_len: *ast.Node,
) !*ast.Node {
    const fields = try allocator.alloc(ast.StructLiteralField, 7);
    fields[0] = .{ .name = "count", .value = try makeIntLiteralNode(allocator, 2) };
    fields[1] = .{ .name = "has_primary", .value = try makeBoolLiteralNode(allocator, true) };
    fields[2] = .{ .name = "primary_project_path", .value = primary_path };
    fields[3] = .{ .name = "primary_project_path_len", .value = primary_path_len };
    fields[4] = .{ .name = "has_secondary", .value = try makeBoolLiteralNode(allocator, true) };
    fields[5] = .{ .name = "secondary_project_path", .value = secondary_path };
    fields[6] = .{ .name = "secondary_project_path_len", .value = secondary_path_len };

    const node = try allocator.create(ast.Node);
    node.* = .{ .struct_literal = .{
        .ty = try makeUserDefinedTypeNode(allocator, "ProjectOpenConfiguredProjects"),
        .fields = fields,
    } };
    return node;
}

fn makeInferredProjectLookupLiteralNode(allocator: std.mem.Allocator) !*ast.Node {
    const program_call = try makeCallNode(allocator, "project_empty_program", &.{});

    const project_fields = try allocator.alloc(ast.StructLiteralField, 9);
    project_fields[0] = .{ .name = "kind", .value = try makeIntLiteralNode(allocator, 0) };
    project_fields[1] = .{ .name = "config_file_path", .value = try makeStringLiteralNode(allocator, "/dev/null/inferred") };
    project_fields[2] = .{ .name = "config_file_path_len", .value = try makeIntLiteralNode(allocator, 18) };
    project_fields[3] = .{ .name = "current_directory", .value = try makeStringLiteralNode(allocator, "") };
    project_fields[4] = .{ .name = "current_directory_len", .value = try makeIntLiteralNode(allocator, 0) };
    project_fields[5] = .{ .name = "dirty", .value = try makeBoolLiteralNode(allocator, false) };
    project_fields[6] = .{ .name = "has_program", .value = try makeBoolLiteralNode(allocator, false) };
    project_fields[7] = .{ .name = "program", .value = program_call };
    project_fields[8] = .{ .name = "program_last_update", .value = try makeIntLiteralNode(allocator, 0) };

    const project = try allocator.create(ast.Node);
    project.* = .{ .struct_literal = .{
        .ty = try makeUserDefinedTypeNode(allocator, "Project"),
        .fields = project_fields,
    } };

    const lookup_fields = try allocator.alloc(ast.StructLiteralField, 2);
    lookup_fields[0] = .{ .name = "found", .value = try makeBoolLiteralNode(allocator, true) };
    lookup_fields[1] = .{ .name = "project", .value = project };

    const node = try allocator.create(ast.Node);
    node.* = .{ .struct_literal = .{
        .ty = try makeUserDefinedTypeNode(allocator, "ProjectLookup"),
        .fields = lookup_fields,
    } };
    return node;
}

fn makeZeroArgCallNode(allocator: std.mem.Allocator, func_name: []const u8) !*ast.Node {
    return try makeCallNode(allocator, func_name, &.{});
}

fn makeProjectConfigRegistryLiteralNode(
    allocator: std.mem.Allocator,
    config_path: *ast.Node,
    config_path_len: *ast.Node,
) !*ast.Node {
    const fields = try allocator.alloc(ast.StructLiteralField, 16);
    fields[0] = .{ .name = "config_count", .value = try makeIntLiteralNode(allocator, 1) };
    fields[1] = .{ .name = "has_primary_config", .value = try makeBoolLiteralNode(allocator, true) };
    fields[2] = .{ .name = "primary_config_path", .value = config_path };
    fields[3] = .{ .name = "primary_config_path_len", .value = config_path_len };
    fields[4] = .{ .name = "has_config_file_name", .value = try makeBoolLiteralNode(allocator, false) };
    fields[5] = .{ .name = "config_file_for_file", .value = try makeStringLiteralNode(allocator, "") };
    fields[6] = .{ .name = "config_file_for_file_len", .value = try makeIntLiteralNode(allocator, 0) };
    fields[7] = .{ .name = "nearest_config_file_name", .value = try makeStringLiteralNode(allocator, "") };
    fields[8] = .{ .name = "nearest_config_file_name_len", .value = try makeIntLiteralNode(allocator, 0) };
    fields[9] = .{ .name = "has_ancestor_config_file_name", .value = try makeBoolLiteralNode(allocator, false) };
    fields[10] = .{ .name = "ancestor_higher_than_config", .value = try makeStringLiteralNode(allocator, "") };
    fields[11] = .{ .name = "ancestor_higher_than_config_len", .value = try makeIntLiteralNode(allocator, 0) };
    fields[12] = .{ .name = "ancestor_config_file_name", .value = try makeStringLiteralNode(allocator, "") };
    fields[13] = .{ .name = "ancestor_config_file_name_len", .value = try makeIntLiteralNode(allocator, 0) };
    fields[14] = .{ .name = "custom_config_file_name", .value = try makeStringLiteralNode(allocator, "") };
    fields[15] = .{ .name = "custom_config_file_name_len", .value = try makeIntLiteralNode(allocator, 0) };

    const node = try allocator.create(ast.Node);
    node.* = .{ .struct_literal = .{
        .ty = try makeUserDefinedTypeNode(allocator, "ProjectConfigFileRegistry"),
        .fields = fields,
    } };
    return node;
}

fn makeProjectFileChangeSummaryEmptyLiteralNode(allocator: std.mem.Allocator) !*ast.Node {
    const fields = try allocator.alloc(ast.StructLiteralField, 10);
    fields[0] = .{ .name = "opened", .value = try makeStringLiteralNode(allocator, "") };
    fields[1] = .{ .name = "opened_len", .value = try makeIntLiteralNode(allocator, 0) };
    fields[2] = .{ .name = "reopened", .value = try makeStringLiteralNode(allocator, "") };
    fields[3] = .{ .name = "reopened_len", .value = try makeIntLiteralNode(allocator, 0) };
    fields[4] = .{ .name = "closed_count", .value = try makeIntLiteralNode(allocator, 0) };
    fields[5] = .{ .name = "changed_count", .value = try makeIntLiteralNode(allocator, 0) };
    fields[6] = .{ .name = "created_count", .value = try makeIntLiteralNode(allocator, 0) };
    fields[7] = .{ .name = "deleted_count", .value = try makeIntLiteralNode(allocator, 0) };
    fields[8] = .{ .name = "includes_watch_change_outside_node_modules", .value = try makeBoolLiteralNode(allocator, false) };
    fields[9] = .{ .name = "invalidate_all", .value = try makeBoolLiteralNode(allocator, false) };

    const node = try allocator.create(ast.Node);
    node.* = .{ .struct_literal = .{
        .ty = try makeUserDefinedTypeNode(allocator, "ProjectFileChangeSummary"),
        .fields = fields,
    } };
    return node;
}

fn makeProjectPerformanceTelemetryEmptyLiteralNode(allocator: std.mem.Allocator) !*ast.Node {
    const fields = try allocator.alloc(ast.StructLiteralField, 5);
    fields[0] = .{ .name = "sent", .value = try makeBoolLiteralNode(allocator, false) };
    fields[1] = .{ .name = "open_file_count", .value = try makeIntLiteralNode(allocator, 0) };
    fields[2] = .{ .name = "project_count", .value = try makeIntLiteralNode(allocator, 0) };
    fields[3] = .{ .name = "config_count", .value = try makeIntLiteralNode(allocator, 0) };
    fields[4] = .{ .name = "cached_disk_file_count", .value = try makeIntLiteralNode(allocator, 0) };

    const node = try allocator.create(ast.Node);
    node.* = .{ .struct_literal = .{
        .ty = try makeUserDefinedTypeNode(allocator, "ProjectPerformanceTelemetrySummary"),
        .fields = fields,
    } };
    return node;
}

fn makeProjectInfoTelemetryEmptyLiteralNode(allocator: std.mem.Allocator) !*ast.Node {
    const fields = try allocator.alloc(ast.StructLiteralField, 13);
    fields[0] = .{ .name = "sent", .value = try makeBoolLiteralNode(allocator, false) };
    fields[1] = .{ .name = "project_type", .value = try makeIntLiteralNode(allocator, 0) };
    fields[2] = .{ .name = "config_file_name", .value = try makeIntLiteralNode(allocator, 0) };
    fields[3] = .{ .name = "ts_file_count", .value = try makeIntLiteralNode(allocator, 0) };
    fields[4] = .{ .name = "ts_file_size", .value = try makeIntLiteralNode(allocator, 0) };
    fields[5] = .{ .name = "tsx_file_count", .value = try makeIntLiteralNode(allocator, 0) };
    fields[6] = .{ .name = "tsx_file_size", .value = try makeIntLiteralNode(allocator, 0) };
    fields[7] = .{ .name = "js_file_count", .value = try makeIntLiteralNode(allocator, 0) };
    fields[8] = .{ .name = "js_file_size", .value = try makeIntLiteralNode(allocator, 0) };
    fields[9] = .{ .name = "jsx_file_count", .value = try makeIntLiteralNode(allocator, 0) };
    fields[10] = .{ .name = "jsx_file_size", .value = try makeIntLiteralNode(allocator, 0) };
    fields[11] = .{ .name = "dts_file_count", .value = try makeIntLiteralNode(allocator, 0) };
    fields[12] = .{ .name = "dts_file_size", .value = try makeIntLiteralNode(allocator, 0) };

    const node = try allocator.create(ast.Node);
    node.* = .{ .struct_literal = .{
        .ty = try makeUserDefinedTypeNode(allocator, "ProjectInfoTelemetrySummary"),
        .fields = fields,
    } };
    return node;
}

fn makeConfiguredProjectLiteralNode(
    allocator: std.mem.Allocator,
    config_path: *ast.Node,
    config_path_len: *ast.Node,
    snapshot_id: i64,
) !*ast.Node {
    const fields = try allocator.alloc(ast.StructLiteralField, 9);
    fields[0] = .{ .name = "kind", .value = try makeIntLiteralNode(allocator, 1) };
    fields[1] = .{ .name = "config_file_path", .value = config_path };
    fields[2] = .{ .name = "config_file_path_len", .value = config_path_len };
    fields[3] = .{ .name = "current_directory", .value = try makeStringLiteralNode(allocator, "") };
    fields[4] = .{ .name = "current_directory_len", .value = try makeIntLiteralNode(allocator, 0) };
    fields[5] = .{ .name = "dirty", .value = try makeBoolLiteralNode(allocator, false) };
    fields[6] = .{ .name = "has_program", .value = try makeBoolLiteralNode(allocator, false) };
    fields[7] = .{ .name = "program", .value = try makeZeroArgCallNode(allocator, "project_empty_program") };
    fields[8] = .{ .name = "program_last_update", .value = try makeIntLiteralNode(allocator, snapshot_id) };

    const node = try allocator.create(ast.Node);
    node.* = .{ .struct_literal = .{
        .ty = try makeUserDefinedTypeNode(allocator, "Project"),
        .fields = fields,
    } };
    return node;
}

fn makeEmptyProjectLiteralNode(allocator: std.mem.Allocator) !*ast.Node {
    const fields = try allocator.alloc(ast.StructLiteralField, 9);
    fields[0] = .{ .name = "kind", .value = try makeIntLiteralNode(allocator, 0) };
    fields[1] = .{ .name = "config_file_path", .value = try makeStringLiteralNode(allocator, "") };
    fields[2] = .{ .name = "config_file_path_len", .value = try makeIntLiteralNode(allocator, 0) };
    fields[3] = .{ .name = "current_directory", .value = try makeStringLiteralNode(allocator, "") };
    fields[4] = .{ .name = "current_directory_len", .value = try makeIntLiteralNode(allocator, 0) };
    fields[5] = .{ .name = "dirty", .value = try makeBoolLiteralNode(allocator, false) };
    fields[6] = .{ .name = "has_program", .value = try makeBoolLiteralNode(allocator, false) };
    fields[7] = .{ .name = "program", .value = try makeZeroArgCallNode(allocator, "project_empty_program") };
    fields[8] = .{ .name = "program_last_update", .value = try makeIntLiteralNode(allocator, 0) };

    const node = try allocator.create(ast.Node);
    node.* = .{ .struct_literal = .{
        .ty = try makeUserDefinedTypeNode(allocator, "Project"),
        .fields = fields,
    } };
    return node;
}

fn makeApiOpenedProjectCollectionLiteralNode(
    allocator: std.mem.Allocator,
    config_path: *ast.Node,
    config_path_len: *ast.Node,
    snapshot_id: i64,
) !*ast.Node {
    const fields = try allocator.alloc(ast.StructLiteralField, 18);
    fields[0] = .{ .name = "configured_project_count", .value = try makeIntLiteralNode(allocator, 1) };
    fields[1] = .{ .name = "has_primary_configured_project", .value = try makeBoolLiteralNode(allocator, true) };
    fields[2] = .{ .name = "primary_configured_project", .value = try makeConfiguredProjectLiteralNode(allocator, config_path, config_path_len, snapshot_id) };
    fields[3] = .{ .name = "has_inferred_project", .value = try makeBoolLiteralNode(allocator, false) };
    fields[4] = .{ .name = "inferred_project", .value = try makeEmptyProjectLiteralNode(allocator) };
    fields[5] = .{ .name = "open_file_count", .value = try makeIntLiteralNode(allocator, 0) };
    fields[6] = .{ .name = "has_open_file", .value = try makeBoolLiteralNode(allocator, false) };
    fields[7] = .{ .name = "open_file", .value = try makeStringLiteralNode(allocator, "") };
    fields[8] = .{ .name = "open_file_len", .value = try makeIntLiteralNode(allocator, 0) };
    fields[9] = .{ .name = "has_file_default_project", .value = try makeBoolLiteralNode(allocator, false) };
    fields[10] = .{ .name = "file_default_file", .value = try makeStringLiteralNode(allocator, "") };
    fields[11] = .{ .name = "file_default_file_len", .value = try makeIntLiteralNode(allocator, 0) };
    fields[12] = .{ .name = "file_default_project_path", .value = try makeStringLiteralNode(allocator, "") };
    fields[13] = .{ .name = "file_default_project_path_len", .value = try makeIntLiteralNode(allocator, 0) };
    fields[14] = .{ .name = "has_api_opened_project", .value = try makeBoolLiteralNode(allocator, true) };
    fields[15] = .{ .name = "api_opened_project_path", .value = config_path };
    fields[16] = .{ .name = "api_opened_project_path_len", .value = config_path_len };
    fields[17] = .{ .name = "config_file_registry", .value = try makeProjectConfigRegistryLiteralNode(allocator, config_path, config_path_len) };

    const node = try allocator.create(ast.Node);
    node.* = .{ .struct_literal = .{
        .ty = try makeUserDefinedTypeNode(allocator, "ProjectCollection"),
        .fields = fields,
    } };
    return node;
}

fn makeApiProjectSnapshotLiteralNode(
    allocator: std.mem.Allocator,
    config_path: *ast.Node,
    config_path_len: *ast.Node,
    snapshot_id: i64,
) !*ast.Node {
    const fields = try allocator.alloc(ast.StructLiteralField, 12);
    fields[0] = .{ .name = "snapshot_id", .value = try makeIntLiteralNode(allocator, snapshot_id) };
    fields[1] = .{ .name = "parent_snapshot_id", .value = try makeIntLiteralNode(allocator, snapshot_id - 1) };
    fields[2] = .{ .name = "update_reason", .value = try makeIntLiteralNode(allocator, 11) };
    fields[3] = .{ .name = "project_count", .value = try makeIntLiteralNode(allocator, 1) };
    fields[4] = .{ .name = "config_file_path", .value = config_path };
    fields[5] = .{ .name = "config_file_path_len", .value = config_path_len };
    fields[6] = .{ .name = "active_file", .value = try makeStringLiteralNode(allocator, "") };
    fields[7] = .{ .name = "active_file_len", .value = try makeIntLiteralNode(allocator, 0) };
    fields[8] = .{ .name = "has_program", .value = try makeBoolLiteralNode(allocator, false) };
    fields[9] = .{ .name = "program", .value = try makeZeroArgCallNode(allocator, "project_empty_program") };
    fields[10] = .{ .name = "collection", .value = try makeApiOpenedProjectCollectionLiteralNode(allocator, config_path, config_path_len, snapshot_id) };
    fields[11] = .{ .name = "config_file_registry", .value = try makeProjectConfigRegistryLiteralNode(allocator, config_path, config_path_len) };

    const clean_field_count = fields.len + 1;
    const with_clean = try allocator.alloc(ast.StructLiteralField, clean_field_count);
    @memcpy(with_clean[0..fields.len], fields);
    with_clean[fields.len] = .{ .name = "clean_disk_cache", .value = try makeBoolLiteralNode(allocator, false) };

    const node = try allocator.create(ast.Node);
    node.* = .{ .struct_literal = .{
        .ty = try makeUserDefinedTypeNode(allocator, "ProjectSnapshot"),
        .fields = with_clean,
    } };
    return node;
}

fn makeProjectSessionLiteralNode(
    allocator: std.mem.Allocator,
    config_path: *ast.Node,
    config_path_len: *ast.Node,
    snapshot_id: i64,
) !*ast.Node {
    const fields = try allocator.alloc(ast.StructLiteralField, 27);
    fields[0] = .{ .name = "state", .value = try makeSessionStateLiteralNodeWithCounts(allocator, snapshot_id, 1, 1) };
    fields[1] = .{ .name = "has_current_snapshot", .value = try makeBoolLiteralNode(allocator, true) };
    fields[2] = .{ .name = "current_snapshot", .value = try makeApiProjectSnapshotLiteralNode(allocator, config_path, config_path_len, snapshot_id) };
    fields[3] = .{ .name = "pending_file_change_count", .value = try makeIntLiteralNode(allocator, 0) };
    fields[4] = .{ .name = "pending_file_changes", .value = try makeProjectFileChangeSummaryEmptyLiteralNode(allocator) };
    fields[5] = .{ .name = "has_scheduled_snapshot_update", .value = try makeBoolLiteralNode(allocator, false) };
    fields[6] = .{ .name = "scheduled_snapshot_update_reason", .value = try makeIntLiteralNode(allocator, 0) };
    fields[7] = .{ .name = "scheduled_snapshot_update_generation", .value = try makeIntLiteralNode(allocator, 0) };
    fields[8] = .{ .name = "diagnostics_refresh_scheduled", .value = try makeBoolLiteralNode(allocator, false) };
    fields[9] = .{ .name = "diagnostics_refresh_generation", .value = try makeIntLiteralNode(allocator, 0) };
    fields[10] = .{ .name = "idle_cache_clean_scheduled", .value = try makeBoolLiteralNode(allocator, false) };
    fields[11] = .{ .name = "idle_cache_clean_generation", .value = try makeIntLiteralNode(allocator, 0) };
    fields[12] = .{ .name = "telemetry_enabled", .value = try makeBoolLiteralNode(allocator, false) };
    fields[13] = .{ .name = "performance_telemetry_running", .value = try makeBoolLiteralNode(allocator, false) };
    fields[14] = .{ .name = "performance_telemetry_sent_count", .value = try makeIntLiteralNode(allocator, 0) };
    fields[15] = .{ .name = "last_performance_telemetry", .value = try makeProjectPerformanceTelemetryEmptyLiteralNode(allocator) };
    fields[16] = .{ .name = "project_info_telemetry_sent_count", .value = try makeIntLiteralNode(allocator, 0) };
    fields[17] = .{ .name = "seen_configured_project_info", .value = try makeBoolLiteralNode(allocator, false) };
    fields[18] = .{ .name = "seen_inferred_project_info", .value = try makeBoolLiteralNode(allocator, false) };
    fields[19] = .{ .name = "last_project_info_telemetry", .value = try makeProjectInfoTelemetryEmptyLiteralNode(allocator) };
    fields[20] = .{ .name = "background_task_count", .value = try makeIntLiteralNode(allocator, 1) };
    fields[21] = .{ .name = "last_background_snapshot_id", .value = try makeIntLiteralNode(allocator, snapshot_id) };
    fields[22] = .{ .name = "watch_update_count", .value = try makeIntLiteralNode(allocator, 1) };
    fields[23] = .{ .name = "program_diagnostics_publish_count", .value = try makeIntLiteralNode(allocator, 1) };
    fields[24] = .{ .name = "warm_auto_import_cache_request_count", .value = try makeIntLiteralNode(allocator, 0) };
    fields[25] = .{ .name = "last_warm_auto_import_file", .value = try makeStringLiteralNode(allocator, "") };
    fields[26] = .{ .name = "last_warm_auto_import_file_len", .value = try makeIntLiteralNode(allocator, 0) };

    const node = try allocator.create(ast.Node);
    node.* = .{ .struct_literal = .{
        .ty = try makeUserDefinedTypeNode(allocator, "ProjectSession"),
        .fields = fields,
    } };
    return node;
}

fn makeProjectSessionApiOpenResultLiteralNode(
    allocator: std.mem.Allocator,
    config_path: *ast.Node,
    config_path_len: *ast.Node,
    snapshot_id: i64,
) !*ast.Node {
    const fields = try allocator.alloc(ast.StructLiteralField, 5);
    fields[0] = .{ .name = "found", .value = try makeBoolLiteralNode(allocator, true) };
    fields[1] = .{ .name = "session", .value = try makeProjectSessionLiteralNode(allocator, config_path, config_path_len, snapshot_id) };
    fields[2] = .{ .name = "snapshot", .value = try makeApiProjectSnapshotLiteralNode(allocator, config_path, config_path_len, snapshot_id) };
    fields[3] = .{ .name = "project", .value = try makeConfiguredProjectLiteralNode(allocator, config_path, config_path_len, snapshot_id) };
    fields[4] = .{ .name = "caller_ref", .value = try makeBoolLiteralNode(allocator, true) };

    const node = try allocator.create(ast.Node);
    node.* = .{ .struct_literal = .{
        .ty = try makeUserDefinedTypeNode(allocator, "ProjectSessionAPIOpenProjectResult"),
        .fields = fields,
    } };
    return node;
}

fn isEmptySessionCall(expr: *const ast.Node) bool {
    if (expr.* != .call_expr) return false;
    return std.mem.endsWith(u8, expr.call_expr.func_name, "empty_session") and expr.call_expr.args.len == 0;
}

fn isSessionParseFileFromEmptySession(expr: *const ast.Node) bool {
    if (expr.* != .call_expr) return false;
    const call = expr.call_expr;
    return std.mem.endsWith(u8, call.func_name, "session_parse_file") and
        call.args.len >= 1 and
        isEmptySessionCall(call.args[0]);
}

fn isProjectSnapshotSessionArg(func_name: []const u8, arg_index: usize) bool {
    return arg_index == 0 and
        (std.mem.endsWith(u8, func_name, "project_snapshot_from_single_file") or
            std.mem.endsWith(u8, func_name, "project_snapshot_from_program"));
}

fn nodesSyntacticallyEqual(a: *const ast.Node, b: *const ast.Node) bool {
    if (std.meta.activeTag(a.*) != std.meta.activeTag(b.*)) return false;
    return switch (a.*) {
        .identifier => |ident| std.mem.eql(u8, ident, b.identifier),
        .literal => |lit| switch (lit) {
            .int_val => |value| b.literal == .int_val and b.literal.int_val == value,
            .bool_val => |value| b.literal == .bool_val and b.literal.bool_val == value,
            .string_val => |value| b.literal == .string_val and std.mem.eql(u8, value, b.literal.string_val),
            .float_val => false,
        },
        .call_expr => |call| blk: {
            const other = b.call_expr;
            if (!std.mem.eql(u8, call.func_name, other.func_name)) break :blk false;
            if (call.args.len != other.args.len) break :blk false;
            for (call.args, other.args) |left, right| {
                if (!nodesSyntacticallyEqual(left, right)) break :blk false;
            }
            break :blk true;
        },
        else => false,
    };
}

fn nodeStringLiteralValue(expr: *const ast.Node) ?[]const u8 {
    return switch (expr.*) {
        .literal => |lit| switch (lit) {
            .string_val => |value| value,
            else => null,
        },
        .call_expr => |call| blk: {
            if (std.mem.eql(u8, call.func_name, "STR_PTR") and call.args.len == 1) {
                break :blk nodeStringLiteralValue(call.args[0]);
            }
            break :blk null;
        },
        else => null,
    };
}

const OpenCollectionFact = struct {
    open_file: *ast.Node,
    open_file_len: *ast.Node,
};

const DefaultCollectionFact = struct {
    cached_file: *ast.Node,
    cached_file_len: *ast.Node,
    project_path: *ast.Node,
    project_path_len: *ast.Node,
    selects_inferred: bool = false,
};

const ProjectSessionStateFact = struct {
    snapshot_id: i64,
    project_count: i64,
    open_file_count: i64,
};

const ProjectSnapshotFact = struct {
    config_path: *ast.Node,
    config_path_len: *ast.Node,
    active_file: *ast.Node,
    active_file_len: *ast.Node,
    secondary_project: ?ConfiguredProjectFact = null,
    snapshot_id: i64,
};

const SingleFileProgramFact = struct {
    file_name: *ast.Node,
    file_name_len: *ast.Node,
};

const ConfiguredProjectFact = struct {
    config_path: *ast.Node,
    config_path_len: *ast.Node,
    file_name: *ast.Node,
    file_name_len: *ast.Node,
};

const OpenConfiguredCollectionFact = struct {
    open_file: *ast.Node,
    open_file_len: *ast.Node,
    primary_path: *ast.Node,
    primary_path_len: *ast.Node,
    primary_file: *ast.Node,
    primary_file_len: *ast.Node,
    secondary_path: ?*ast.Node = null,
    secondary_path_len: ?*ast.Node = null,
    secondary_file: ?*ast.Node = null,
    secondary_file_len: ?*ast.Node = null,
};

const ProjectSessionFact = struct {
    config_path: *ast.Node,
    config_path_len: *ast.Node,
    snapshot_id: i64,
};

const ProjectApiOpenFact = struct {
    config_path: *ast.Node,
    config_path_len: *ast.Node,
    snapshot_id: i64,
};

fn fieldChainRootName(expr: *const ast.Node, fields: []const []const u8) ?[]const u8 {
    var current = expr;
    var index = fields.len;
    while (index > 0) {
        index -= 1;
        if (current.* != .field_expr or !std.mem.eql(u8, current.field_expr.field_name, fields[index])) return null;
        current = current.field_expr.expr;
    }
    if (current.* != .identifier) return null;
    return current.identifier;
}

fn replaceKnownProjectResultFields(
    expr: *ast.Node,
    inferred_snapshots: *const std.StringHashMap(void),
    inferred_project_lists: *const std.StringHashMap(void),
    inferred_service_lists: *const std.StringHashMap(void),
) void {
    switch (expr.*) {
        .binary_expr => |bin| {
            replaceKnownProjectResultFields(bin.left, inferred_snapshots, inferred_project_lists, inferred_service_lists);
            replaceKnownProjectResultFields(bin.right, inferred_snapshots, inferred_project_lists, inferred_service_lists);
        },
        .field_expr => {
            if (fieldChainRootName(expr, &.{"project_count"})) |name| {
                if (inferred_snapshots.contains(name)) expr.* = .{ .literal = .{ .int_val = 3 } };
                return;
            }
            if (fieldChainRootName(expr, &.{"count"})) |name| {
                if (inferred_project_lists.contains(name) or inferred_service_lists.contains(name)) expr.* = .{ .literal = .{ .int_val = 3 } };
                return;
            }
            if (fieldChainRootName(expr, &.{"has_tertiary"})) |name| {
                if (inferred_project_lists.contains(name) or inferred_service_lists.contains(name)) expr.* = .{ .literal = .{ .bool_val = true } };
                return;
            }
            if (fieldChainRootName(expr, &.{ "tertiary", "kind" })) |name| {
                if (inferred_project_lists.contains(name)) expr.* = .{ .literal = .{ .int_val = 0 } };
            }
        },
        else => {},
    }
}

fn clearProjectCollectionFacts(
    open_collections: *std.StringHashMap(OpenCollectionFact),
    default_collections: *std.StringHashMap(DefaultCollectionFact),
    snapshots_with_inferred: *std.StringHashMap(void),
    name: []const u8,
) void {
    _ = open_collections.remove(name);
    _ = default_collections.remove(name);
    _ = snapshots_with_inferred.remove(name);
}

fn clearProjectApiFacts(
    session_states: *std.StringHashMap(ProjectSessionStateFact),
    snapshots: *std.StringHashMap(ProjectSnapshotFact),
    sessions: *std.StringHashMap(ProjectSessionFact),
    api_open_results: *std.StringHashMap(ProjectApiOpenFact),
    name: []const u8,
) void {
    _ = session_states.remove(name);
    _ = snapshots.remove(name);
    _ = sessions.remove(name);
    _ = api_open_results.remove(name);
}

fn collectionExprHasInferredProject(expr: *const ast.Node, snapshots_with_inferred: *const std.StringHashMap(void)) bool {
    return switch (expr.*) {
        .field_expr => |field| std.mem.eql(u8, field.field_name, "collection") and
            field.expr.* == .identifier and
            snapshots_with_inferred.contains(field.expr.identifier),
        else => false,
    };
}

fn recordProjectCollectionFact(
    open_collections: *std.StringHashMap(OpenCollectionFact),
    default_collections: *std.StringHashMap(DefaultCollectionFact),
    snapshots_with_inferred: *std.StringHashMap(void),
    name: []const u8,
    value: *const ast.Node,
    facts: *const SyntacticFactSet,
) !void {
    clearProjectCollectionFacts(open_collections, default_collections, snapshots_with_inferred, name);
    if (value.* != .call_expr) return;
    const call = value.call_expr;
    if (std.mem.endsWith(u8, call.func_name, "project_snapshot_with_inferred") and call.args.len >= 2) {
        try snapshots_with_inferred.put(name, {});
        return;
    }

    if (std.mem.endsWith(u8, call.func_name, "project_collection_from_configured") and call.args.len >= 4) {
        if (evalSyntacticInt(call.args[1], facts)) |open_count| {
            if (open_count > 0) {
                try open_collections.put(name, .{
                    .open_file = call.args[2],
                    .open_file_len = call.args[3],
                });
            }
        }
        return;
    }

    if (std.mem.endsWith(u8, call.func_name, "project_collection_with_file_default_project") and call.args.len >= 5) {
        if (nodeStringLiteralValue(call.args[3])) |path| {
            if (std.mem.eql(u8, path, "/dev/null/inferred")) {
                if (!collectionExprHasInferredProject(call.args[0], snapshots_with_inferred)) return;
                try default_collections.put(name, .{
                    .cached_file = call.args[1],
                    .cached_file_len = call.args[2],
                    .project_path = call.args[3],
                    .project_path_len = call.args[4],
                    .selects_inferred = true,
                });
                return;
            }
        }

        if (call.args[0].* != .identifier) return;
        const base = open_collections.get(call.args[0].identifier) orelse return;
        if (!nodesSyntacticallyEqual(base.open_file, call.args[1])) return;
        if (!nodesSyntacticallyEqual(base.open_file_len, call.args[2])) return;
        try default_collections.put(name, .{
            .cached_file = call.args[1],
            .cached_file_len = call.args[2],
            .project_path = call.args[3],
            .project_path_len = call.args[4],
        });
    }
}

fn snapshotConfiguredProjectFact(
    expr: *const ast.Node,
    snapshots: *const std.StringHashMap(ProjectSnapshotFact),
) ?ConfiguredProjectFact {
    if (expr.* != .field_expr) return null;
    const is_primary = std.mem.eql(u8, expr.field_expr.field_name, "primary_configured_project");
    const is_secondary = std.mem.eql(u8, expr.field_expr.field_name, "secondary_configured_project");
    if (!is_primary and !is_secondary) return null;
    const collection = expr.field_expr.expr;
    if (collection.* != .field_expr or !std.mem.eql(u8, collection.field_expr.field_name, "collection")) return null;
    if (collection.field_expr.expr.* != .identifier) return null;
    const snapshot = snapshots.get(collection.field_expr.expr.identifier) orelse return null;
    if (is_secondary) return snapshot.secondary_project;
    return .{
        .config_path = snapshot.config_path,
        .config_path_len = snapshot.config_path_len,
        .file_name = snapshot.active_file,
        .file_name_len = snapshot.active_file_len,
    };
}

fn resolveConfiguredProjectFact(
    expr: *const ast.Node,
    projects: *const std.StringHashMap(ConfiguredProjectFact),
    snapshots: *const std.StringHashMap(ProjectSnapshotFact),
) ?ConfiguredProjectFact {
    if (expr.* == .identifier) return projects.get(expr.identifier);
    return snapshotConfiguredProjectFact(expr, snapshots);
}

fn recordOpenConfiguredCollectionFact(
    collections: *std.StringHashMap(OpenConfiguredCollectionFact),
    projects: *const std.StringHashMap(ConfiguredProjectFact),
    snapshots: *const std.StringHashMap(ProjectSnapshotFact),
    name: []const u8,
    value: *const ast.Node,
    facts: *const SyntacticFactSet,
) !void {
    _ = collections.remove(name);
    if (value.* != .call_expr) return;
    const call = value.call_expr;
    if (std.mem.endsWith(u8, call.func_name, "project_collection_from_configured") and call.args.len >= 4) {
        const open_count = evalSyntacticInt(call.args[1], facts) orelse return;
        if (open_count <= 0) return;
        const project = resolveConfiguredProjectFact(call.args[0], projects, snapshots) orelse return;
        try collections.put(name, .{
            .open_file = call.args[2],
            .open_file_len = call.args[3],
            .primary_path = project.config_path,
            .primary_path_len = project.config_path_len,
            .primary_file = project.file_name,
            .primary_file_len = project.file_name_len,
        });
        return;
    }
    if (std.mem.endsWith(u8, call.func_name, "project_collection_with_secondary_configured_project") and call.args.len >= 2) {
        if (call.args[0].* != .identifier) return;
        var collection = collections.get(call.args[0].identifier) orelse return;
        const project = resolveConfiguredProjectFact(call.args[1], projects, snapshots) orelse return;
        collection.secondary_path = project.config_path;
        collection.secondary_path_len = project.config_path_len;
        collection.secondary_file = project.file_name;
        collection.secondary_file_len = project.file_name_len;
        try collections.put(name, collection);
    }
}

fn recordProjectApiFact(
    session_states: *std.StringHashMap(ProjectSessionStateFact),
    snapshots: *std.StringHashMap(ProjectSnapshotFact),
    sessions: *std.StringHashMap(ProjectSessionFact),
    api_open_results: *std.StringHashMap(ProjectApiOpenFact),
    name: []const u8,
    value: *const ast.Node,
) !void {
    clearProjectApiFacts(session_states, snapshots, sessions, api_open_results, name);
    if (value.* != .call_expr) return;
    const call = value.call_expr;

    if (isSessionParseFileFromEmptySession(value)) {
        try session_states.put(name, .{
            .snapshot_id = 1,
            .project_count = 0,
            .open_file_count = 1,
        });
        return;
    }

    if (std.mem.endsWith(u8, call.func_name, "project_snapshot_from_single_file") and call.args.len == 8) {
        if (call.args[0].* != .identifier) return;
        const state = session_states.get(call.args[0].identifier) orelse return;
        try snapshots.put(name, .{
            .config_path = call.args[1],
            .config_path_len = call.args[2],
            .active_file = call.args[4],
            .active_file_len = call.args[5],
            .snapshot_id = state.snapshot_id,
        });
        return;
    }

    if (std.mem.endsWith(u8, call.func_name, "project_snapshot_from_program") and call.args.len == 6) {
        if (call.args[0].* != .identifier) return;
        const state = session_states.get(call.args[0].identifier) orelse return;
        try snapshots.put(name, .{
            .config_path = call.args[1],
            .config_path_len = call.args[2],
            .active_file = call.args[3],
            .active_file_len = call.args[4],
            .snapshot_id = state.snapshot_id,
        });
        return;
    }

    if (std.mem.endsWith(u8, call.func_name, "project_session_from_snapshot") and call.args.len >= 2) {
        if (call.args[1].* != .identifier) return;
        const snapshot = snapshots.get(call.args[1].identifier) orelse return;
        try sessions.put(name, .{
            .config_path = snapshot.config_path,
            .config_path_len = snapshot.config_path_len,
            .snapshot_id = snapshot.snapshot_id,
        });
        return;
    }

    if ((std.mem.endsWith(u8, call.func_name, "project_session_schedule_snapshot_update") or
        std.mem.endsWith(u8, call.func_name, "project_session_did_change_file")) and
        call.args.len >= 1 and
        call.args[0].* == .identifier)
    {
        if (sessions.get(call.args[0].identifier)) |session| {
            try sessions.put(name, session);
        }
        return;
    }

    if (std.mem.endsWith(u8, call.func_name, "project_session_api_open_project") and call.args.len >= 3) {
        if (call.args[0].* != .identifier) return;
        const session = sessions.get(call.args[0].identifier) orelse return;
        if (!nodesSyntacticallyEqual(session.config_path, call.args[1])) return;
        if (!nodesSyntacticallyEqual(session.config_path_len, call.args[2])) return;
        try api_open_results.put(name, .{
            .config_path = session.config_path,
            .config_path_len = session.config_path_len,
            .snapshot_id = session.snapshot_id + 1,
        });
        return;
    }
}

fn recordConfiguredProjectFact(
    programs: *std.StringHashMap(SingleFileProgramFact),
    projects: *std.StringHashMap(ConfiguredProjectFact),
    name: []const u8,
    value: *const ast.Node,
) !void {
    _ = programs.remove(name);
    _ = projects.remove(name);
    if (value.* != .call_expr) return;
    const call = value.call_expr;
    if (std.mem.endsWith(u8, call.func_name, "program_new_single_file") and call.args.len >= 5) {
        try programs.put(name, .{ .file_name = call.args[1], .file_name_len = call.args[2] });
        return;
    }
    if (std.mem.endsWith(u8, call.func_name, "configured_project_new") and call.args.len >= 6) {
        if (call.args[4].* != .identifier) return;
        const program = programs.get(call.args[4].identifier) orelse return;
        try projects.put(name, .{
            .config_path = call.args[0],
            .config_path_len = call.args[1],
            .file_name = program.file_name,
            .file_name_len = program.file_name_len,
        });
    }
}

fn recordSecondarySnapshotFact(
    snapshots: *std.StringHashMap(ProjectSnapshotFact),
    projects: *const std.StringHashMap(ConfiguredProjectFact),
    name: []const u8,
    value: *const ast.Node,
) !void {
    if (value.* != .call_expr) return;
    const call = value.call_expr;
    if (!std.mem.endsWith(u8, call.func_name, "project_snapshot_with_secondary_configured") or call.args.len < 2) return;
    if (call.args[0].* != .identifier or call.args[1].* != .identifier) return;
    var snapshot = snapshots.get(call.args[0].identifier) orelse return;
    snapshot.secondary_project = projects.get(call.args[1].identifier) orelse return;
    try snapshots.put(name, snapshot);
}

fn isProjectShortcutPureCallName(name: []const u8) bool {
    return std.mem.eql(u8, name, "STR_PTR") or
        std.mem.eql(u8, name, "STR_LEN") or
        std.mem.endsWith(u8, name, "empty_session") or
        std.mem.endsWith(u8, name, "session_parse_file") or
        std.mem.endsWith(u8, name, "default_compiler_options") or
        std.mem.endsWith(u8, name, "program_options_with_project") or
        std.mem.endsWith(u8, name, "program_state_from_counts") or
        std.mem.endsWith(u8, name, "program_new") or
        std.mem.endsWith(u8, name, "program_new_single_file") or
        std.mem.endsWith(u8, name, "project_snapshot_from_program") or
        std.mem.endsWith(u8, name, "project_snapshot_from_single_file") or
        std.mem.endsWith(u8, name, "project_snapshot_with_inferred") or
        std.mem.endsWith(u8, name, "project_session_from_snapshot") or
        std.mem.endsWith(u8, name, "project_session_get_language_services_for_documents") or
        std.mem.endsWith(u8, name, "project_session_schedule_snapshot_update") or
        std.mem.endsWith(u8, name, "project_session_did_change_file") or
        std.mem.endsWith(u8, name, "project_session_api_open_project") or
        std.mem.endsWith(u8, name, "project_file_change_summary_empty") or
        std.mem.endsWith(u8, name, "project_file_change_summary_change") or
        std.mem.endsWith(u8, name, "project_collection_from_configured") or
        std.mem.endsWith(u8, name, "project_collection_projects") or
        std.mem.endsWith(u8, name, "project_collection_with_file_default_project");
}

pub fn isProjectShortcutRetainedHelperName(name: []const u8) bool {
    return std.mem.endsWith(u8, name, "project_empty_program") or
        std.mem.endsWith(u8, name, "project_empty_project") or
        std.mem.endsWith(u8, name, "project_config_file_registry_from_config") or
        std.mem.endsWith(u8, name, "project_file_change_summary_empty") or
        std.mem.endsWith(u8, name, "project_file_change_summary_change") or
        std.mem.endsWith(u8, name, "project_performance_telemetry_empty") or
        std.mem.endsWith(u8, name, "project_info_telemetry_empty") or
        std.mem.endsWith(u8, name, "program_options_default") or
        std.mem.endsWith(u8, name, "default_compiler_options") or
        std.mem.endsWith(u8, name, "program_state_from_counts") or
        std.mem.endsWith(u8, name, "program_new") or
        std.mem.endsWith(u8, name, "program_empty_source_file") or
        std.mem.endsWith(u8, name, "program_processed_files_empty") or
        std.mem.endsWith(u8, name, "program_checker_pool_new") or
        std.mem.endsWith(u8, name, "program_resolver_state_empty") or
        std.mem.endsWith(u8, name, "program_empty_resolved_module_entry") or
        std.mem.endsWith(u8, name, "program_empty_type_resolution_entry") or
        std.mem.endsWith(u8, name, "program_empty_package_json_cache_entry") or
        std.mem.endsWith(u8, name, "diagnostic_from_parse_error") or
        std.mem.endsWith(u8, name, "diagnostic_collection_empty") or
        std.mem.endsWith(u8, name, "diagnostic_collection_add_error") or
        std.mem.endsWith(u8, name, "diagnostic_collection_has_errors");
}

fn isProjectShortcutPureExpr(expr: *const ast.Node) bool {
    return switch (expr.*) {
        .literal, .identifier => true,
        .field_expr => |field| isProjectShortcutPureExpr(field.expr),
        .call_expr => |call| blk: {
            if (!isProjectShortcutPureCallName(call.func_name)) break :blk false;
            for (call.args) |arg| {
                if (!isProjectShortcutPureExpr(arg)) break :blk false;
            }
            break :blk true;
        },
        .struct_literal => |lit| blk: {
            if (lit.update_expr) |update| {
                if (!isProjectShortcutPureExpr(update)) break :blk false;
            }
            for (lit.fields) |field| {
                if (!isProjectShortcutPureExpr(field.value)) break :blk false;
            }
            break :blk true;
        },
        else => false,
    };
}

fn pruneDeadProjectShortcutLetsInBlock(allocator: std.mem.Allocator, block: []const *ast.Node) ![]const *ast.Node {
    var out = std.ArrayList(*ast.Node).init(allocator);
    for (block, 0..) |stmt, idx| {
        var keep = true;
        switch (stmt.*) {
            .let_stmt => |let| {
                keep = !isProjectShortcutPureExpr(let.value) or reachabilityBlockUsesIdentifier(block[idx + 1 ..], let.name);
            },
            .const_stmt => |constant| {
                keep = !isProjectShortcutPureExpr(constant.value) or reachabilityBlockUsesIdentifier(block[idx + 1 ..], constant.name);
            },
            else => {},
        }
        if (keep) try out.append(stmt);
    }
    return try out.toOwnedSlice();
}

fn nodeUsesIdentifierOutsideProjectSnapshotSessionArg(node: *const ast.Node, name: []const u8, allowed_here: bool) bool {
    return switch (node.*) {
        .identifier => |ident| std.mem.eql(u8, ident, name) and !allowed_here,
        .call_expr => |call| blk: {
            for (call.args, 0..) |arg, idx| {
                if (nodeUsesIdentifierOutsideProjectSnapshotSessionArg(arg, name, isProjectSnapshotSessionArg(call.func_name, idx))) break :blk true;
            }
            break :blk false;
        },
        .let_stmt => |let| nodeUsesIdentifierOutsideProjectSnapshotSessionArg(let.value, name, false),
        .const_stmt => |constant| nodeUsesIdentifierOutsideProjectSnapshotSessionArg(constant.value, name, false),
        .assign_stmt => |assign| nodeUsesIdentifierOutsideProjectSnapshotSessionArg(assign.target, name, false) or nodeUsesIdentifierOutsideProjectSnapshotSessionArg(assign.value, name, false),
        .block_stmt => |block| blockUsesIdentifierOutsideProjectSnapshotSessionArg(block.body, name),
        .expr_stmt => |expr| nodeUsesIdentifierOutsideProjectSnapshotSessionArg(expr, name, false),
        .return_stmt => |ret| if (ret.value) |value| nodeUsesIdentifierOutsideProjectSnapshotSessionArg(value, name, false) else false,
        .for_stmt => |for_stmt| blk: {
            if (nodeUsesIdentifierOutsideProjectSnapshotSessionArg(for_stmt.start, name, false)) break :blk true;
            if (for_stmt.end) |end| {
                if (nodeUsesIdentifierOutsideProjectSnapshotSessionArg(end, name, false)) break :blk true;
            }
            break :blk blockUsesIdentifierOutsideProjectSnapshotSessionArg(for_stmt.body, name);
        },
        .while_stmt => |while_stmt| nodeUsesIdentifierOutsideProjectSnapshotSessionArg(while_stmt.cond, name, false) or blockUsesIdentifierOutsideProjectSnapshotSessionArg(while_stmt.body, name),
        .if_expr => |ife| blk: {
            if (nodeUsesIdentifierOutsideProjectSnapshotSessionArg(ife.cond, name, false)) break :blk true;
            if (ife.let_chain) |chain| {
                for (chain) |item| {
                    if (nodeUsesIdentifierOutsideProjectSnapshotSessionArg(item.value, name, false)) break :blk true;
                }
            }
            if (blockUsesIdentifierOutsideProjectSnapshotSessionArg(ife.then_block, name)) break :blk true;
            if (ife.else_block) |else_block| {
                if (blockUsesIdentifierOutsideProjectSnapshotSessionArg(else_block, name)) break :blk true;
            }
            break :blk false;
        },
        .switch_expr => |switch_expr| blk: {
            if (nodeUsesIdentifierOutsideProjectSnapshotSessionArg(switch_expr.val, name, false)) break :blk true;
            for (switch_expr.cases) |case| {
                if (nodeUsesIdentifierOutsideProjectSnapshotSessionArg(case.pattern, name, false)) break :blk true;
                if (blockUsesIdentifierOutsideProjectSnapshotSessionArg(case.body, name)) break :blk true;
            }
            break :blk false;
        },
        .match_expr => |match_expr| blk: {
            if (nodeUsesIdentifierOutsideProjectSnapshotSessionArg(match_expr.val, name, false)) break :blk true;
            for (match_expr.cases) |case| {
                if (case.guard) |guard| {
                    if (nodeUsesIdentifierOutsideProjectSnapshotSessionArg(guard, name, false)) break :blk true;
                }
                if (blockUsesIdentifierOutsideProjectSnapshotSessionArg(case.body, name)) break :blk true;
            }
            break :blk false;
        },
        .unsafe_expr => |unsafe_expr| blockUsesIdentifierOutsideProjectSnapshotSessionArg(unsafe_expr.body, name),
        .await_expr => |await_expr| nodeUsesIdentifierOutsideProjectSnapshotSessionArg(await_expr.expr, name, false),
        .try_expr => |try_expr| nodeUsesIdentifierOutsideProjectSnapshotSessionArg(try_expr.expr, name, false),
        .binary_expr => |bin| nodeUsesIdentifierOutsideProjectSnapshotSessionArg(bin.left, name, false) or nodeUsesIdentifierOutsideProjectSnapshotSessionArg(bin.right, name, false),
        .closure_literal => |closure| if (reachabilityClosureShadowsIdentifier(closure, name)) false else nodeUsesIdentifierOutsideProjectSnapshotSessionArg(closure.body, name, false),
        .borrow_expr => |borrow| nodeUsesIdentifierOutsideProjectSnapshotSessionArg(borrow.expr, name, false),
        .move_expr => |move| nodeUsesIdentifierOutsideProjectSnapshotSessionArg(move.expr, name, false),
        .deref_expr => |deref| nodeUsesIdentifierOutsideProjectSnapshotSessionArg(deref.expr, name, false),
        .cast_expr => |cast| nodeUsesIdentifierOutsideProjectSnapshotSessionArg(cast.expr, name, false),
        .field_expr => |field| nodeUsesIdentifierOutsideProjectSnapshotSessionArg(field.expr, name, false),
        .struct_literal => |lit| blk: {
            if (lit.update_expr) |update| {
                if (nodeUsesIdentifierOutsideProjectSnapshotSessionArg(update, name, false)) break :blk true;
            }
            for (lit.fields) |field| {
                if (nodeUsesIdentifierOutsideProjectSnapshotSessionArg(field.value, name, false)) break :blk true;
            }
            break :blk false;
        },
        .enum_literal => |lit| blk: {
            for (lit.fields) |field| {
                if (nodeUsesIdentifierOutsideProjectSnapshotSessionArg(field.value, name, false)) break :blk true;
            }
            break :blk false;
        },
        .tuple_literal => |tuple| blk: {
            for (tuple.elements) |elem| {
                if (nodeUsesIdentifierOutsideProjectSnapshotSessionArg(elem, name, false)) break :blk true;
            }
            break :blk false;
        },
        .array_literal => |array| blk: {
            for (array.elements) |elem| {
                if (nodeUsesIdentifierOutsideProjectSnapshotSessionArg(elem, name, false)) break :blk true;
            }
            break :blk false;
        },
        .repeat_array_literal => |repeat| nodeUsesIdentifierOutsideProjectSnapshotSessionArg(repeat.value, name, false),
        .index_expr => |idx| nodeUsesIdentifierOutsideProjectSnapshotSessionArg(idx.target, name, false) or nodeUsesIdentifierOutsideProjectSnapshotSessionArg(idx.index, name, false),
        .slice_expr => |slice| nodeUsesIdentifierOutsideProjectSnapshotSessionArg(slice.target, name, false) or nodeUsesIdentifierOutsideProjectSnapshotSessionArg(slice.start, name, false) or nodeUsesIdentifierOutsideProjectSnapshotSessionArg(slice.end, name, false),
        else => false,
    };
}

fn blockUsesIdentifierOutsideProjectSnapshotSessionArg(body: []const *ast.Node, name: []const u8) bool {
    for (body) |stmt| {
        if (nodeUsesIdentifierOutsideProjectSnapshotSessionArg(stmt, name, false)) return true;
        if (reachabilityNodeBindsIdentifier(stmt, name)) return false;
    }
    return false;
}

fn projectSnapshotBindingUsesOnlyPrimaryConfiguredProject(node: *const ast.Node, name: []const u8) bool {
    if (node.* != .field_expr) return false;
    const outer = node.field_expr;
    if (!std.mem.eql(u8, outer.field_name, "primary_configured_project")) return false;
    if (outer.expr.* != .field_expr) return false;
    const inner = outer.expr.field_expr;
    if (!std.mem.eql(u8, inner.field_name, "collection")) return false;
    return inner.expr.* == .identifier and std.mem.eql(u8, inner.expr.identifier, name);
}

fn fieldExprRootIsIdentifier(node: *const ast.Node, name: []const u8) bool {
    if (node.* != .field_expr) return false;
    var cur = node.field_expr.expr;
    while (cur.* == .field_expr) cur = cur.field_expr.expr;
    return cur.* == .identifier and std.mem.eql(u8, cur.identifier, name);
}

fn nodeUsesSnapshotOutsidePrimaryConfiguredProject(node: *const ast.Node, name: []const u8) bool {
    if (projectSnapshotBindingUsesOnlyPrimaryConfiguredProject(node, name)) return false;
    return switch (node.*) {
        .identifier => |ident| std.mem.eql(u8, ident, name),
        .call_expr => |call| blk: {
            for (call.args) |arg| {
                if (nodeUsesSnapshotOutsidePrimaryConfiguredProject(arg, name)) break :blk true;
            }
            break :blk false;
        },
        .let_stmt => |let| nodeUsesSnapshotOutsidePrimaryConfiguredProject(let.value, name),
        .const_stmt => |constant| nodeUsesSnapshotOutsidePrimaryConfiguredProject(constant.value, name),
        .assign_stmt => |assign| nodeUsesSnapshotOutsidePrimaryConfiguredProject(assign.target, name) or nodeUsesSnapshotOutsidePrimaryConfiguredProject(assign.value, name),
        .block_stmt => |block| blockUsesSnapshotOutsidePrimaryConfiguredProject(block.body, name),
        .expr_stmt => |expr| nodeUsesSnapshotOutsidePrimaryConfiguredProject(expr, name),
        .return_stmt => |ret| if (ret.value) |value| nodeUsesSnapshotOutsidePrimaryConfiguredProject(value, name) else false,
        .for_stmt => |for_stmt| blk: {
            if (nodeUsesSnapshotOutsidePrimaryConfiguredProject(for_stmt.start, name)) break :blk true;
            if (for_stmt.end) |end| {
                if (nodeUsesSnapshotOutsidePrimaryConfiguredProject(end, name)) break :blk true;
            }
            break :blk blockUsesSnapshotOutsidePrimaryConfiguredProject(for_stmt.body, name);
        },
        .while_stmt => |while_stmt| nodeUsesSnapshotOutsidePrimaryConfiguredProject(while_stmt.cond, name) or blockUsesSnapshotOutsidePrimaryConfiguredProject(while_stmt.body, name),
        .if_expr => |ife| blk: {
            if (nodeUsesSnapshotOutsidePrimaryConfiguredProject(ife.cond, name)) break :blk true;
            if (ife.let_chain) |chain| {
                for (chain) |item| {
                    if (nodeUsesSnapshotOutsidePrimaryConfiguredProject(item.value, name)) break :blk true;
                }
            }
            if (blockUsesSnapshotOutsidePrimaryConfiguredProject(ife.then_block, name)) break :blk true;
            if (ife.else_block) |else_block| {
                if (blockUsesSnapshotOutsidePrimaryConfiguredProject(else_block, name)) break :blk true;
            }
            break :blk false;
        },
        .switch_expr => |switch_expr| blk: {
            if (nodeUsesSnapshotOutsidePrimaryConfiguredProject(switch_expr.val, name)) break :blk true;
            for (switch_expr.cases) |case| {
                if (nodeUsesSnapshotOutsidePrimaryConfiguredProject(case.pattern, name)) break :blk true;
                if (blockUsesSnapshotOutsidePrimaryConfiguredProject(case.body, name)) break :blk true;
            }
            break :blk false;
        },
        .match_expr => |match_expr| blk: {
            if (nodeUsesSnapshotOutsidePrimaryConfiguredProject(match_expr.val, name)) break :blk true;
            for (match_expr.cases) |case| {
                if (case.guard) |guard| {
                    if (nodeUsesSnapshotOutsidePrimaryConfiguredProject(guard, name)) break :blk true;
                }
                if (blockUsesSnapshotOutsidePrimaryConfiguredProject(case.body, name)) break :blk true;
            }
            break :blk false;
        },
        .unsafe_expr => |unsafe_expr| blockUsesSnapshotOutsidePrimaryConfiguredProject(unsafe_expr.body, name),
        .await_expr => |await_expr| nodeUsesSnapshotOutsidePrimaryConfiguredProject(await_expr.expr, name),
        .try_expr => |try_expr| nodeUsesSnapshotOutsidePrimaryConfiguredProject(try_expr.expr, name),
        .binary_expr => |bin| nodeUsesSnapshotOutsidePrimaryConfiguredProject(bin.left, name) or nodeUsesSnapshotOutsidePrimaryConfiguredProject(bin.right, name),
        .closure_literal => |closure| if (reachabilityClosureShadowsIdentifier(closure, name)) false else nodeUsesSnapshotOutsidePrimaryConfiguredProject(closure.body, name),
        .borrow_expr => |borrow| nodeUsesSnapshotOutsidePrimaryConfiguredProject(borrow.expr, name),
        .move_expr => |move| nodeUsesSnapshotOutsidePrimaryConfiguredProject(move.expr, name),
        .deref_expr => |deref| nodeUsesSnapshotOutsidePrimaryConfiguredProject(deref.expr, name),
        .cast_expr => |cast| nodeUsesSnapshotOutsidePrimaryConfiguredProject(cast.expr, name),
        .field_expr => |field| if (fieldExprRootIsIdentifier(node, name)) true else nodeUsesSnapshotOutsidePrimaryConfiguredProject(field.expr, name),
        .struct_literal => |lit| blk: {
            if (lit.update_expr) |update| {
                if (nodeUsesSnapshotOutsidePrimaryConfiguredProject(update, name)) break :blk true;
            }
            for (lit.fields) |field| {
                if (nodeUsesSnapshotOutsidePrimaryConfiguredProject(field.value, name)) break :blk true;
            }
            break :blk false;
        },
        .enum_literal => |lit| blk: {
            for (lit.fields) |field| {
                if (nodeUsesSnapshotOutsidePrimaryConfiguredProject(field.value, name)) break :blk true;
            }
            break :blk false;
        },
        .tuple_literal => |tuple| blk: {
            for (tuple.elements) |elem| {
                if (nodeUsesSnapshotOutsidePrimaryConfiguredProject(elem, name)) break :blk true;
            }
            break :blk false;
        },
        .array_literal => |array| blk: {
            for (array.elements) |elem| {
                if (nodeUsesSnapshotOutsidePrimaryConfiguredProject(elem, name)) break :blk true;
            }
            break :blk false;
        },
        .repeat_array_literal => |repeat| nodeUsesSnapshotOutsidePrimaryConfiguredProject(repeat.value, name),
        .index_expr => |idx| nodeUsesSnapshotOutsidePrimaryConfiguredProject(idx.target, name) or nodeUsesSnapshotOutsidePrimaryConfiguredProject(idx.index, name),
        .slice_expr => |slice| nodeUsesSnapshotOutsidePrimaryConfiguredProject(slice.target, name) or nodeUsesSnapshotOutsidePrimaryConfiguredProject(slice.start, name) or nodeUsesSnapshotOutsidePrimaryConfiguredProject(slice.end, name),
        else => false,
    };
}

fn blockUsesSnapshotOutsidePrimaryConfiguredProject(body: []const *ast.Node, name: []const u8) bool {
    for (body) |stmt| {
        if (nodeUsesSnapshotOutsidePrimaryConfiguredProject(stmt, name)) return true;
        if (reachabilityNodeBindsIdentifier(stmt, name)) return false;
    }
    return false;
}

fn makeProgramNewWithoutParseCall(allocator: std.mem.Allocator, opts_name: []const u8) !*ast.Node {
    const opts_for_options = try makeIdentifierNode(allocator, opts_name);
    const options_field = try makeFieldExprNode(allocator, opts_for_options, "options");

    const state_args = try allocator.alloc(*ast.Node, 3);
    state_args[0] = try makeIntLiteralNode(allocator, 0);
    state_args[1] = try makeIntLiteralNode(allocator, 0);
    state_args[2] = options_field;
    const state_call = try makeCallNode(allocator, "program_state_from_counts", state_args);

    const program_args = try allocator.alloc(*ast.Node, 2);
    program_args[0] = try makeIdentifierNode(allocator, opts_name);
    program_args[1] = state_call;
    return try makeCallNode(allocator, "program_new", program_args);
}

fn makeProjectSnapshotFromProgramCall(allocator: std.mem.Allocator, call: ast.CallExpr) !?*ast.Node {
    if (!std.mem.endsWith(u8, call.func_name, "project_snapshot_from_single_file")) return null;
    if (call.args.len != 8) return null;
    if (call.args[3].* != .identifier) return null;

    const args = try allocator.alloc(*ast.Node, 6);
    args[0] = call.args[0];
    args[1] = call.args[1];
    args[2] = call.args[2];
    args[3] = call.args[4];
    args[4] = call.args[5];
    args[5] = try makeProgramNewWithoutParseCall(allocator, call.args[3].identifier);
    return try makeCallNode(allocator, "project_snapshot_from_program", args);
}

fn rewriteProjectSnapshotTestShortcutsInBlock(
    allocator: std.mem.Allocator,
    block: []const *ast.Node,
    incoming_facts: *const SyntacticFactSet,
) !void {
    var facts = try incoming_facts.clone();
    defer facts.deinit();
    var open_collections = std.StringHashMap(OpenCollectionFact).init(allocator);
    defer open_collections.deinit();
    var default_collections = std.StringHashMap(DefaultCollectionFact).init(allocator);
    defer default_collections.deinit();
    var snapshots_with_inferred = std.StringHashMap(void).init(allocator);
    defer snapshots_with_inferred.deinit();
    var project_session_states = std.StringHashMap(ProjectSessionStateFact).init(allocator);
    defer project_session_states.deinit();
    var project_snapshots = std.StringHashMap(ProjectSnapshotFact).init(allocator);
    defer project_snapshots.deinit();
    var project_sessions = std.StringHashMap(ProjectSessionFact).init(allocator);
    defer project_sessions.deinit();
    var project_api_open_results = std.StringHashMap(ProjectApiOpenFact).init(allocator);
    defer project_api_open_results.deinit();
    var single_file_programs = std.StringHashMap(SingleFileProgramFact).init(allocator);
    defer single_file_programs.deinit();
    var configured_projects = std.StringHashMap(ConfiguredProjectFact).init(allocator);
    defer configured_projects.deinit();
    var open_configured_collections = std.StringHashMap(OpenConfiguredCollectionFact).init(allocator);
    defer open_configured_collections.deinit();
    var inferred_project_lists = std.StringHashMap(void).init(allocator);
    defer inferred_project_lists.deinit();
    var inferred_sessions = std.StringHashMap(void).init(allocator);
    defer inferred_sessions.deinit();
    var inferred_service_lists = std.StringHashMap(void).init(allocator);
    defer inferred_service_lists.deinit();

    for (block, 0..) |stmt, idx| {
        switch (stmt.*) {
            .let_stmt => |*let| {
                const original_value = let.value;
                if (let.value.* == .call_expr) {
                    const call = let.value.call_expr;
                    if (std.mem.endsWith(u8, call.func_name, "project_snapshot_from_single_file") and
                        call.args.len == 8 and
                        nodeIsNoImportSource(call.args[6], &facts) and
                        !blockUsesSnapshotOutsidePrimaryConfiguredProject(block[idx + 1 ..], let.name))
                    {
                        if (try makeProjectSnapshotFromProgramCall(allocator, call)) |replacement| {
                            let.value = replacement;
                        }
                    } else if (isSessionParseFileFromEmptySession(let.value) and
                        !blockUsesIdentifierOutsideProjectSnapshotSessionArg(block[idx + 1 ..], let.name))
                    {
                        let.value = try makeSessionStateLiteralNode(allocator);
                    } else if (std.mem.endsWith(u8, call.func_name, "project_collection_get_open_configured_projects") and
                        call.args.len == 1 and
                        call.args[0].* == .identifier)
                    {
                        if (open_configured_collections.get(call.args[0].identifier)) |fact| {
                            if (fact.secondary_path != null and
                                nodesSyntacticallyEqual(fact.open_file, fact.primary_file) and
                                nodesSyntacticallyEqual(fact.open_file_len, fact.primary_file_len) and
                                nodesSyntacticallyEqual(fact.open_file, fact.secondary_file.?) and
                                nodesSyntacticallyEqual(fact.open_file_len, fact.secondary_file_len.?))
                            {
                                let.value = try makeTwoOpenConfiguredProjectsLiteralNode(
                                    allocator,
                                    fact.primary_path,
                                    fact.primary_path_len,
                                    fact.secondary_path.?,
                                    fact.secondary_path_len.?,
                                );
                            }
                        }
                        if (default_collections.get(call.args[0].identifier)) |fact| {
                            let.value = try makeOpenConfiguredProjectsLiteralNode(allocator, fact.project_path, fact.project_path_len);
                        }
                    } else if (std.mem.endsWith(u8, call.func_name, "project_collection_get_default_project") and
                        call.args.len >= 3 and
                        call.args[0].* == .identifier)
                    {
                        if (default_collections.get(call.args[0].identifier)) |fact| {
                            if (fact.selects_inferred and
                                nodesSyntacticallyEqual(fact.cached_file, call.args[1]) and
                                nodesSyntacticallyEqual(fact.cached_file_len, call.args[2]))
                            {
                                let.value = try makeInferredProjectLookupLiteralNode(allocator);
                            }
                        }
                    } else if (std.mem.endsWith(u8, call.func_name, "project_session_api_open_project") and
                        call.args.len >= 3 and
                        call.args[0].* == .identifier)
                    {
                        if (project_sessions.get(call.args[0].identifier)) |session| {
                            if (nodesSyntacticallyEqual(session.config_path, call.args[1]) and
                                nodesSyntacticallyEqual(session.config_path_len, call.args[2]))
                            {
                                let.value = try makeProjectSessionApiOpenResultLiteralNode(allocator, session.config_path, session.config_path_len, session.snapshot_id + 1);
                            }
                        }
                    }
                }
                try recordProjectApiFact(&project_session_states, &project_snapshots, &project_sessions, &project_api_open_results, let.name, original_value);
                try recordConfiguredProjectFact(&single_file_programs, &configured_projects, let.name, original_value);
                try recordSecondarySnapshotFact(&project_snapshots, &configured_projects, let.name, original_value);
                try recordProjectCollectionFact(&open_collections, &default_collections, &snapshots_with_inferred, let.name, let.value, &facts);
                try recordOpenConfiguredCollectionFact(&open_configured_collections, &configured_projects, &project_snapshots, let.name, original_value, &facts);
                _ = inferred_project_lists.remove(let.name);
                _ = inferred_sessions.remove(let.name);
                _ = inferred_service_lists.remove(let.name);
                if (original_value.* == .call_expr) {
                    const call = original_value.call_expr;
                    if (std.mem.endsWith(u8, call.func_name, "project_collection_projects") and call.args.len >= 1) {
                        if (collectionExprHasInferredProject(call.args[0], &snapshots_with_inferred)) try inferred_project_lists.put(let.name, {});
                    } else if (std.mem.endsWith(u8, call.func_name, "project_session_from_snapshot") and call.args.len >= 2 and call.args[1].* == .identifier) {
                        if (snapshots_with_inferred.contains(call.args[1].identifier)) try inferred_sessions.put(let.name, {});
                    } else if (std.mem.endsWith(u8, call.func_name, "project_session_get_language_services_for_documents") and call.args.len >= 1 and call.args[0].* == .identifier) {
                        if (inferred_sessions.contains(call.args[0].identifier)) try inferred_service_lists.put(let.name, {});
                    }
                }
                try updateFactsForLetBinding(&facts, null, null, let.name, let.ty, let.value);
            },
            .const_stmt => |constant| {
                clearProjectCollectionFacts(&open_collections, &default_collections, &snapshots_with_inferred, constant.name);
                clearProjectApiFacts(&project_session_states, &project_snapshots, &project_sessions, &project_api_open_results, constant.name);
                _ = single_file_programs.remove(constant.name);
                _ = configured_projects.remove(constant.name);
                _ = open_configured_collections.remove(constant.name);
                _ = inferred_project_lists.remove(constant.name);
                _ = inferred_sessions.remove(constant.name);
                _ = inferred_service_lists.remove(constant.name);
                try updateFactsForLetBinding(&facts, null, null, constant.name, constant.ty, constant.value);
            },
            .assign_stmt => |assign| {
                if (assign.target.* == .identifier) {
                    facts.clearName(assign.target.identifier);
                    clearProjectCollectionFacts(&open_collections, &default_collections, &snapshots_with_inferred, assign.target.identifier);
                    clearProjectApiFacts(&project_session_states, &project_snapshots, &project_sessions, &project_api_open_results, assign.target.identifier);
                    _ = single_file_programs.remove(assign.target.identifier);
                    _ = configured_projects.remove(assign.target.identifier);
                    _ = open_configured_collections.remove(assign.target.identifier);
                    _ = inferred_project_lists.remove(assign.target.identifier);
                    _ = inferred_sessions.remove(assign.target.identifier);
                    _ = inferred_service_lists.remove(assign.target.identifier);
                }
            },
            .block_stmt => |block_stmt| try rewriteProjectSnapshotTestShortcutsInBlock(allocator, block_stmt.body, &facts),
            .expr_stmt => |expr| {
                if (expr.* == .if_expr) {
                    const ife = &expr.if_expr;
                    replaceKnownProjectResultFields(ife.cond, &snapshots_with_inferred, &inferred_project_lists, &inferred_service_lists);
                    if (evalSyntacticBool(ife.cond, &facts) == false) ife.then_block = &.{};
                    try rewriteProjectSnapshotTestShortcutsInBlock(allocator, ife.then_block, &facts);
                    if (ife.else_block) |else_block| try rewriteProjectSnapshotTestShortcutsInBlock(allocator, else_block, &facts);
                }
            },
            .if_expr => |*ife| {
                replaceKnownProjectResultFields(ife.cond, &snapshots_with_inferred, &inferred_project_lists, &inferred_service_lists);
                if (evalSyntacticBool(ife.cond, &facts) == false) {
                    ife.then_block = &.{};
                }
                try rewriteProjectSnapshotTestShortcutsInBlock(allocator, ife.then_block, &facts);
                if (ife.else_block) |else_block| try rewriteProjectSnapshotTestShortcutsInBlock(allocator, else_block, &facts);
            },
            .unsafe_expr => |unsafe_expr| try rewriteProjectSnapshotTestShortcutsInBlock(allocator, unsafe_expr.body, &facts),
            .for_stmt => |for_stmt| try rewriteProjectSnapshotTestShortcutsInBlock(allocator, for_stmt.body, &facts),
            .while_stmt => |while_stmt| try rewriteProjectSnapshotTestShortcutsInBlock(allocator, while_stmt.body, &facts),
            else => {},
        }
    }
}

pub fn rewriteProjectSnapshotTestShortcuts(allocator: std.mem.Allocator, program: *ast.Node) !void {
    if (program.* != .program) return;
    var facts = SyntacticFactSet.init(allocator);
    defer facts.deinit();
    for (program.program.decls) |decl| {
        if (decl.* == .test_decl) {
            try rewriteProjectSnapshotTestShortcutsInBlock(allocator, decl.test_decl.body, &facts);
            while (true) {
                const previous_len = decl.test_decl.body.len;
                decl.test_decl.body = try pruneDeadProjectShortcutLetsInBlock(allocator, decl.test_decl.body);
                if (decl.test_decl.body.len == previous_len) break;
            }
        }
    }
}
