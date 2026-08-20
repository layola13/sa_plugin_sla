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
    // dispatcher requires argv[1] to be the literal "sla"/"slab" marker.
    // Normalize standalone help and top-level commands to that legacy shape,
    // while preserving explicit `sla sla ...` and `sla slab ...` invocations.
    var synthesized: ?[][]const u8 = null;
    defer if (synthesized) |s| allocator.free(s);

    const needs_help = blk: {
        if (argv.len < 2) break :blk true;
        break :blk std.mem.eql(u8, argv[1], "-h") or std.mem.eql(u8, argv[1], "--help");
    };
    const should_synthesize = blk: {
        if (needs_help) break :blk true;
        if (argv.len < 2) break :blk false;
        if (std.mem.eql(u8, argv[1], "sla") or std.mem.eql(u8, argv[1], "slab")) break :blk false;
        break :blk isTopLevelSlaCommand(argv[1]);
    };
    const args: []const []const u8 = if (should_synthesize)    blk: {
        const synth_len = if (needs_help) (if (argv.len > 2) argv.len + 1 else 3) else argv.len + 1;
        const synth = try allocator.alloc([]const u8, synth_len);
        synth[0] = argv[0];
        synth[1] = "sla";
        if (needs_help) {
            synth[2] = "help";
            if (argv.len > 2) {
                for (argv[2..], 0..) |a, i| synth[i + 3] = a;
            }
        } else {
            synth[2] = argv[1];
            if (argv.len > 2) {
                for (argv[2..], 0..) |a, i| synth[i + 3] = a;
            }
        }
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
