const std = @import("std");

pub const SlaCompileOptions = struct {
    test_filter: ?[]const u8 = null,
    // SAB fallback 到 SA-text 已被禁止: 该字段仅为兼容保留, 门禁恒返 false。
    allow_fallback: bool = false,
    prune_for_test_codegen: bool = false,
    prune_for_entry_function: ?[]const u8 = null,
    load_reachable_imported_bodies_from_registry: bool = false,
};

pub fn defaultSlaCompileOptions() SlaCompileOptions {
    return .{ .load_reachable_imported_bodies_from_registry = true };
}

pub fn slaProfileEnabled(allocator: std.mem.Allocator) bool {
    const value = std.process.getEnvVarOwned(allocator, "SLA_PROFILE") catch return false;
    defer allocator.free(value);
    return value.len != 0 and !std.mem.eql(u8, value, "0") and !std.mem.eql(u8, value, "false");
}

pub fn slaProfileContractsEnabled(allocator: std.mem.Allocator) bool {
    const value = std.process.getEnvVarOwned(allocator, "SLA_PROFILE_CONTRACTS") catch return false;
    defer allocator.free(value);
    return value.len != 0 and !std.mem.eql(u8, value, "0") and !std.mem.eql(u8, value, "false");
}

/// SAB direct 失败时禁止回退到 SA-text 兼容路径: 恒返 false,
/// direct lowering 失败即显式报错 (SAB Direct Error ... without fallback)。
/// SA-text 是语义标准, SAB 是其从属产物, 语义分歧必须根修 codegen,
/// 禁止静默回退掩盖缺口 (见 sala 07_sab_parity 质量门禁)。
pub fn slaSabFallbackAllowed(allocator: std.mem.Allocator, options: SlaCompileOptions) bool {
    _ = allocator;
    _ = options;
    return false;
}

pub fn slaProfileStage(stderr: std.io.AnyWriter, enabled: bool, label: []const u8, start_ns: i128) void {
    if (!enabled) return;
    const elapsed_ms = @divTrunc(std.time.nanoTimestamp() - start_ns, std.time.ns_per_ms);
    stderr.print("[sla-profile] {s}: {d}ms\n", .{ label, elapsed_ms }) catch {};
}

pub fn writeEmptyTestResult(stdout: std.io.AnyWriter) !void {
    try stdout.writeAll("----\n");
    try stdout.writeAll("test result: ok. 0 passed; 0 failed; 0 skipped\n");
}
