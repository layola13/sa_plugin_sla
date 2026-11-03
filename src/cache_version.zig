const std = @import("std");
const sla_build_options = @import("sla_build_options");

/// Compiler stamp mixed into every `.sla-cache` key that is computed
/// from input paths, options, and content hashes only. Such a key
/// cannot see the compiler itself, so when analysis, expansion,
/// reachability, or codegen behavior changes for identical inputs,
/// entries written by the older build would keep hitting and mask the
/// new behavior (the 2026-10-27 .sla-cache incident). The stamp pairs
/// two components:
///
/// - `key_version`: a dedicated constant. Bump it whenever a compiler
///   change can alter a cached artifact for identical inputs.
/// - the toolchain version string from build.zig (-Dversion, kept in
///   sync with the npm line), so release bumps roll every cache key
///   even when nobody remembers to bump the constant.
pub const key_version: u32 = 1;

pub fn mixInto(hasher: *std.hash.Wyhash) void {
    mixWith(hasher, key_version, sla_build_options.version);
}

pub fn mixWith(hasher: *std.hash.Wyhash, version: u32, toolchain_version: []const u8) void {
    hasher.update("sla-cache-key:");
    hasher.update(&std.mem.toBytes(version));
    hasher.update(toolchain_version);
    hasher.update("\x00");
}

fn digestForTest(version: u32, toolchain_version: []const u8) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update("some-input");
    mixWith(&hasher, version, toolchain_version);
    return hasher.final();
}

test "cache key stamp is sensitive to both version components" {
    const current = digestForTest(key_version, sla_build_options.version);
    try std.testing.expect(current != digestForTest(key_version + 1, sla_build_options.version));
    try std.testing.expect(current != digestForTest(key_version, "0.0.0-next"));
    var plain = std.hash.Wyhash.init(0);
    plain.update("some-input");
    try std.testing.expect(current != plain.final());
    var stamped = std.hash.Wyhash.init(0);
    stamped.update("some-input");
    mixInto(&stamped);
    try std.testing.expectEqual(current, stamped.final());
}
