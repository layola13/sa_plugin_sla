const std = @import("std");
const builtin = @import("builtin");

/// Process-wide default `std.Io` for plugin library code.
///
/// Zig 0.17 removed ambient filesystem access (`std.fs.cwd()`); every fs op
/// needs an explicit `Io`. Threading it through the whole Sla call graph
/// would touch every function, so library code uses this instead:
/// * standalone entry points (`sla`, `dump-sab`, test drivers) call
///   `set(init.io)` once at startup (zero cost: std already built one);
/// * the `.so` plugin entry (`runSlaCommandAbi`) never calls `set`; the
///   first `get()` lazily creates a process-lifetime `Threaded` Io.
var current: ?std.Io = null;
var threaded_storage: ?std.Io.Threaded = null;

pub fn set(io: std.Io) void {
    current = io;
}

pub fn get() std.Io {
    if (current) |io| return io;
    threaded_storage = std.Io.Threaded.init(std.heap.page_allocator, .{ .argv0 = .empty });
    const io = threaded_storage.?.io();
    current = io;
    return io;
}

/// Owned environment-variable lookup for library code that has no
/// `std.process.Init` in scope (0.17 removed `std.process.getEnvVarOwned`).
/// Entry points with `Init` should prefer `init.environ_map` /
/// `init.minimal.environ` directly. Returns null when unavailable
/// (Windows/WASI, or variable unset); callers treat null as "disabled".
pub fn getEnvOwned(gpa: std.mem.Allocator, key: []const u8) ?[]u8 {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return null;
    if (builtin.link_libc == false) return null;
    var i: usize = 0;
    while (std.c.environ[i]) |entry| : (i += 1) {
        const pair = std.mem.span(entry);
        if (pair.len <= key.len) continue;
        if (!std.mem.eql(u8, pair[0..key.len], key)) continue;
        if (pair[key.len] != '=') continue;
        return gpa.dupe(u8, pair[key.len + 1 ..]) catch null;
    }
    return null;
}
