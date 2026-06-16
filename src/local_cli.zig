const std = @import("std");
const plugin = @import("plugin.zig");
const plugin_api = @import("plugin_api");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var ctx = plugin_api.Context{
        .allocator = allocator,
    };

    const stdout_writer = std.io.getStdOut().writer().any();
    const stderr_writer = std.io.getStdErr().writer().any();

    const maybe_code = try plugin.runSlaCommandImpl(&ctx, args, stdout_writer, stderr_writer);
    const code = maybe_code orelse 1;
    if (code != 0) std.process.exit(code);
}
