const std = @import("std");
const sci_bridge = @import("sci_bridge");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next();
    const path = args.next() orelse return error.MissingPath;
    const bytes = try std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024 * 64);
    defer allocator.free(bytes);
    const stdout = std.io.getStdOut().writer();
    try sci_bridge.sab.disasmModule(allocator, bytes, stdout);
}
