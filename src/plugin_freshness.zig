const std = @import("std");
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
