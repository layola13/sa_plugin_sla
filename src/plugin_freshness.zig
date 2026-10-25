const std = @import("std");
const plugin_api = @import("plugin_api");
const sio = @import("sio");
const plugin_compile_options = @import("plugin_compile_options.zig");

const SlaCompileOptions = plugin_compile_options.SlaCompileOptions;

// Whole-compilation freshness gate.
//
// The SLA front-end (read -> source expand -> parse -> import expand ->
// monomorphize -> type check -> codegen) is a pure function of the root
// source, every transitively imported file, and the compile options.
// Historically every invocation re-ran the entire pipeline even when
// nothing had changed; the existing caches only trimmed individual
// phases, so a zero-change rebuild still cost a full compile. This
// module records, per (root file, output kind, options) key, the full
// dependency closure with per-file content hashes plus the produced
// artifact. A later invocation whose recorded closure still hashes
// identically reuses the stored artifact and skips the front-end.
//
// Set SLA_NO_FRESHNESS_CACHE=1 to bypass the gate entirely.

pub const FreshnessKind = enum {
    sab,
    sa_text,

    fn tag(self: FreshnessKind) []const u8 {
        return switch (self) {
            .sab => "sab",
            .sa_text => "sa",
        };
    }
};

const ManifestDep = struct {
    path: []const u8,
    len: u64,
    hash: u64,
};

const Manifest = struct {
    version: u32,
    kind: []const u8,
    deps: []ManifestDep,
};

const manifest_version: u32 = 1;
const max_manifest_bytes: usize = 64 * 1024 * 1024;
const max_dep_bytes: usize = 256 * 1024 * 1024;
const max_artifact_bytes: usize = 1024 * 1024 * 1024;


/// Host broker context for the current dispatch (set by plugin.zig's
/// ABI entry when the host loads this plugin; null for the standalone
/// sla binary, where the local gate below is the authority). When a
/// broker is present, the host cache service owns freshness storage:
/// the host rehashes the recorded dependency closure itself, so a hit
/// here is exactly as trustworthy as a local hit.
pub var host_ctx: ?*const plugin_api.Context = null;

fn brokerCtx() ?*const plugin_api.Context {
    const ctx = host_ctx orelse return null;
    if (!plugin_api.brokerAvailable(ctx)) return null;
    return ctx;
}

fn brokerKeyMaterial(
    allocator: std.mem.Allocator,
    file: []const u8,
    kind: FreshnessKind,
    options: SlaCompileOptions,
    output_file: ?[]const u8,
) ![]u8 {
    const tag = kind.tag();
    var material = std.array_list.Managed(u8).init(allocator);
    errdefer material.deinit();
    try material.appendSlice(tag);
    try material.append(0);
    var key_bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &key_bytes, gateKey(file, kind, options, output_file), .little);
    try material.appendSlice(&key_bytes);
    return material.toOwnedSlice();
}

fn brokerLoadFreshArtifact(
    allocator: std.mem.Allocator,
    ctx: *const plugin_api.Context,
    file: []const u8,
    kind: FreshnessKind,
    options: SlaCompileOptions,
    output_file: ?[]const u8,
) ?[]u8 {
    const broker_call = ctx.broker_call orelse return null;
    const key = brokerKeyMaterial(allocator, file, kind, options, output_file) catch return null;
    defer allocator.free(key);
    var response = plugin_api.BrokerCacheLookupResponse{ .hit = 0, .value_len = 0 };
    var request = plugin_api.BrokerCacheLookupRequest{
        .ns_ptr = "sla".ptr,
        .ns_len = 3,
        .key_ptr = key.ptr,
        .key_len = key.len,
        .closure_ptr = key.ptr,
        .closure_len = 0,
        .value_ptr = null,
        .value_cap = 0,
    };
    var status = broker_call(ctx.broker_ctx, plugin_api.broker_op_cache_lookup, &request, &response);
    if (sio.getEnvVarOwned(allocator, "SLA_CACHE_DEBUG")) |dbg| {
        allocator.free(dbg);
        std.debug.print("[cache-debug] lookup status={d} hit={d} len={d}\n", .{ status, response.hit, response.value_len });
    } else |_| {}
    if (status == 0 and response.hit == 0) return null;
    if (status != 5 and status != 0) return null;
    if (response.value_len > max_artifact_bytes) return null;
    const buffer = allocator.alloc(u8, response.value_len) catch return null;
    errdefer allocator.free(buffer);
    request.value_ptr = if (buffer.len == 0) null else buffer.ptr;
    request.value_cap = buffer.len;
    var response2 = plugin_api.BrokerCacheLookupResponse{ .hit = 0, .value_len = 0 };
    status = broker_call(ctx.broker_ctx, plugin_api.broker_op_cache_lookup, &request, &response2);
    if (status != 0 or response2.hit == 0) {
        allocator.free(buffer);
        return null;
    }
    return buffer[0..response2.value_len];
}

fn brokerStoreFreshArtifact(
    allocator: std.mem.Allocator,
    ctx: *const plugin_api.Context,
    file: []const u8,
    kind: FreshnessKind,
    options: SlaCompileOptions,
    output_file: ?[]const u8,
    dep_paths: []const []const u8,
    artifact_bytes: []const u8,
) void {
    const broker_call = ctx.broker_call orelse return;
    const key = brokerKeyMaterial(allocator, file, kind, options, output_file) catch return;
    defer allocator.free(key);

    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();
    var blob = std.array_list.Managed(u8).init(allocator);
    defer blob.deinit();
    var count: u32 = 0;
    var count_slot: [4]u8 = .{ 0, 0, 0, 0 };
    blob.appendSlice(&count_slot) catch return;
    for (dep_paths) |path| {
        if (seen.contains(path)) continue;
        seen.put(path, {}) catch return;
        var len_bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &len_bytes, @intCast(path.len), .little);
        blob.appendSlice(&len_bytes) catch return;
        blob.appendSlice(path) catch return;
        count += 1;
    }
    if (count == 0) return;
    std.mem.writeInt(u32, @as(*[4]u8, @ptrCast(blob.items.ptr)), count, .little);

    var response = plugin_api.BrokerCacheStoreResponse{ .stored = 0 };
    const request = plugin_api.BrokerCacheStoreRequest{
        .ns_ptr = "sla".ptr,
        .ns_len = 3,
        .key_ptr = key.ptr,
        .key_len = key.len,
        .closure_ptr = blob.items.ptr,
        .closure_len = blob.items.len,
        .value_ptr = artifact_bytes.ptr,
        .value_len = artifact_bytes.len,
    };
    const store_status = broker_call(ctx.broker_ctx, plugin_api.broker_op_cache_store, &request, &response);
    if (sio.getEnvVarOwned(allocator, "SLA_CACHE_DEBUG")) |dbg| {
        allocator.free(dbg);
        std.debug.print("[cache-debug] store status={d} stored={d} deps={d}\n", .{ store_status, response.stored, count });
    } else |_| {}
}

fn gateDisabled(allocator: std.mem.Allocator) bool {
    const value = sio.getEnvVarOwned(allocator, "SLA_NO_FRESHNESS_CACHE") catch return false;
    defer allocator.free(value);
    return value.len != 0 and !std.mem.eql(u8, value, "0") and !std.mem.eql(u8, value, "false");
}

fn optionsDigest(kind: FreshnessKind, options: SlaCompileOptions, output_file: ?[]const u8) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(kind.tag());
    hasher.update("\x00");
    if (options.test_filter) |filter| {
        hasher.update("filter:");
        hasher.update(filter);
    } else {
        hasher.update("filter:none");
    }
    hasher.update("\x00");
    hasher.update(&.{@intFromBool(options.prune_for_test_codegen)});
    hasher.update(&.{@intFromBool(options.load_reachable_imported_bodies_from_registry)});
    if (options.prune_for_entry_function) |entry| {
        hasher.update("entry:");
        hasher.update(entry);
    } else {
        hasher.update("entry:none");
    }
    hasher.update("\x00");
    // SA-text output rewrites @import paths relative to the output file,
    // so the output location is part of the result for that kind.
    if (output_file) |out| {
        hasher.update("out:");
        hasher.update(out);
    }
    return hasher.final();
}

fn gateKey(file: []const u8, kind: FreshnessKind, options: SlaCompileOptions, output_file: ?[]const u8) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(file);
    hasher.update("\x00");
    hasher.update(&std.mem.toBytes(optionsDigest(kind, options, output_file)));
    return hasher.final();
}

fn freshDirPath(
    allocator: std.mem.Allocator,
    file: []const u8,
    kind: FreshnessKind,
    options: SlaCompileOptions,
    output_file: ?[]const u8,
    ext: []const u8,
) ![]u8 {
    const base = std.fs.path.basename(file);
    const stem = if (std.mem.endsWith(u8, base, ".sla")) base[0 .. base.len - 4] else base;
    const key = gateKey(file, kind, options, output_file);
    return try std.fmt.allocPrint(allocator, ".sla-cache/fresh/{s}-{x}.{s}", .{ stem, key, ext });
}

/// Returns the stored artifact bytes when every recorded dependency
/// still hashes to the recorded value. Any doubt (missing files, parse
/// errors, changed bytes) yields null, i.e. a normal full compile.
pub fn tryLoadFreshArtifact(
    allocator: std.mem.Allocator,
    file: []const u8,
    kind: FreshnessKind,
    options: SlaCompileOptions,
    output_file: ?[]const u8,
) ?[]u8 {
    if (gateDisabled(allocator)) return null;

    if (sio.getEnvVarOwned(allocator, "SLA_CACHE_DEBUG")) |dbg| {
        allocator.free(dbg);
        std.debug.print("[cache-debug] host_ctx={} broker={}\n", .{ host_ctx != null, brokerCtx() != null });
    } else |_| {}
    if (brokerCtx()) |ctx| {
        return brokerLoadFreshArtifact(allocator, ctx, file, kind, options, output_file);
    }

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const manifest_path = freshDirPath(a, file, kind, options, output_file, "json") catch return null;
    const manifest_bytes = sio.cwd().readFileAlloc(a, manifest_path, max_manifest_bytes) catch return null;
    const manifest = std.json.parseFromSlice(Manifest, a, manifest_bytes, .{}) catch return null;
    if (manifest.value.version != manifest_version) return null;
    if (!std.mem.eql(u8, manifest.value.kind, kind.tag())) return null;

    for (manifest.value.deps) |dep| {
        const bytes = sio.cwd().readFileAlloc(a, dep.path, max_dep_bytes) catch return null;
        if (bytes.len != dep.len) return null;
        if (std.hash.Wyhash.hash(0, bytes) != dep.hash) return null;
    }

    const artifact_path = freshDirPath(a, file, kind, options, output_file, "bin") catch return null;
    const artifact = sio.cwd().readFileAlloc(a, artifact_path, max_artifact_bytes) catch return null;
    return allocator.dupe(u8, artifact) catch null;
}

/// Records the dependency closure (raw file contents hashed now) and the
/// produced artifact for future freshness checks. Best effort: any file
/// that cannot be read simply leaves the gate disarmed for this key.
pub fn storeFreshArtifact(
    allocator: std.mem.Allocator,
    file: []const u8,
    kind: FreshnessKind,
    options: SlaCompileOptions,
    output_file: ?[]const u8,
    dep_paths: []const []const u8,
    artifact_bytes: []const u8,
) !void {
    if (gateDisabled(allocator)) return;

    if (brokerCtx()) |ctx| {
        brokerStoreFreshArtifact(allocator, ctx, file, kind, options, output_file, dep_paths, artifact_bytes);
        return;
    }

    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();
    var deps = std.array_list.Managed(ManifestDep).init(allocator);
    defer deps.deinit();
    for (dep_paths) |path| {
        if (seen.contains(path)) continue;
        try seen.put(path, {});
        const bytes = sio.cwd().readFileAlloc(allocator, path, max_dep_bytes) catch continue;
        defer allocator.free(bytes);
        try deps.append(.{
            .path = try allocator.dupe(u8, path),
            .len = @intCast(bytes.len),
            .hash = std.hash.Wyhash.hash(0, bytes),
        });
    }
    if (deps.items.len == 0) return;

    const artifact_path = try freshDirPath(allocator, file, kind, options, output_file, "bin");
    defer allocator.free(artifact_path);
    const manifest_path = try freshDirPath(allocator, file, kind, options, output_file, "json");
    defer allocator.free(manifest_path);
    if (std.fs.path.dirname(artifact_path)) |dir| {
        try sio.cwd().makePath(dir);
    }

    try sio.cwd().writeFile(.{ .sub_path = artifact_path, .data = artifact_bytes });

    const manifest: Manifest = .{
        .version = manifest_version,
        .kind = kind.tag(),
        .deps = deps.items,
    };
    const manifest_bytes = try std.json.Stringify.valueAlloc(allocator, manifest, .{});
    defer allocator.free(manifest_bytes);
    try sio.cwd().writeFile(.{ .sub_path = manifest_path, .data = manifest_bytes });
}
