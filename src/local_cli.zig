const std = @import("std");
const plugin = @import("plugin.zig");
const plugin_api = @import("plugin_api");

/// Returns true when the token is one of the sla plugin's top-level commands,
/// i.e. something that should be dispatched as `sla <command> ...`.  When the
/// caller already included the literal "sla"/"slab" marker this is false, so
/// the legacy `sla sla <cmd>` / `sla slab <cmd>` forms keep working verbatim.
fn isTopLevelSlaCommand(token: []const u8) bool {
    const commands = [_][]const u8{
        "init",      "skills", "stability", "build", "build-workspace",
        "build-exe", "sab",    "check",     "test",  "help",
    };
    for (commands) |cmd| {
        if (std.mem.eql(u8, token, cmd)) return true;
    }
    return false;
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);

    if (argv.len >= 2 and (std.mem.eql(u8, argv[1], "--version") or std.mem.eql(u8, argv[1], "-V"))) {
        try std.io.getStdOut().writer().print("sla 0.1.0{c}", .{10});
        return;
    }

    // `sla` as a global binary is invoked as `sla <command> ...`; the plugin
    // dispatcher (runSlaCommandImpl) requires argv[1] to be the literal "sla"/
    // "slab" marker.  When the caller already passed that marker (e.g. the
    // legacy `sla sla <cmd>` form), pass argv through verbatim.  Otherwise
    // synthesize the marker so the new top-level `sla test x.sla`,
    // `sla build ... `, etc. "just work" and every downstream parser offset
    // (which all key off the marker at position 1) stays unchanged.
    var synthesized: ?[][]const u8 = null;
    defer if (synthesized) |s| allocator.free(s);

    const args: []const []const u8 = if (argv.len >= 2 and
        !std.mem.eql(u8, argv[1], "sla") and
        !std.mem.eql(u8, argv[1], "slab") and
        isTopLevelSlaCommand(argv[1]))
    blk: {
        const synth = try allocator.alloc([]const u8, argv.len + 1);
        synth[0] = argv[0];
        synth[1] = "sla";
        synth[2] = argv[1]; // keep argv[1] (the command) at slot 2, where runSlaCommandImpl reads cmd
        for (argv[2..], 0..) |a, i| synth[i + 3] = a;
        synthesized = synth;
        break :blk synth;
    } else argv;

    var ctx = plugin_api.Context{
        .allocator = allocator,
    };

    const stdout_writer = std.io.getStdOut().writer().any();
    const stderr_writer = std.io.getStdErr().writer().any();

    const maybe_code = try plugin.runSlaCommandImpl(&ctx, args, stdout_writer, stderr_writer);
    const code = maybe_code orelse 1;
    if (code != 0) std.process.exit(code);
}
