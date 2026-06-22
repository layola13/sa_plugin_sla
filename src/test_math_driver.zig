// test_math_driver.zig – verify test_unit_math.sla compiles to SA successfully.
const std = @import("std");
const parser_mod = @import("parser.zig");
const monomorphizer_mod = @import("monomorphizer.zig");
const type_checker_mod = @import("type_checker.zig");
const codegen_mod = @import("codegen.zig");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source = try std.fs.cwd().readFileAlloc(alloc, "tests/test_unit_math.sla", 1 * 1024 * 1024);

    var p = parser_mod.Parser.init(alloc, source);
    const prog = p.parseProgram() catch |err| {
        std.debug.print("PARSE ERROR: {}\n", .{err});
        std.process.exit(1);
    };

    var mono = monomorphizer_mod.Monomorphizer.init(alloc);
    defer mono.deinit();
    const specialized = mono.monomorphize(prog, null, null) catch |err| {
        std.debug.print("MONO ERROR: {}\n", .{err});
        std.process.exit(1);
    };

    var tc = type_checker_mod.TypeChecker.init(alloc);
    defer tc.deinit();
    tc.checkProgram(specialized) catch |err| {
        std.debug.print("TYPE ERROR: {} — {s}\n", .{ err, tc.last_error });
        std.process.exit(1);
    };

    var cg = codegen_mod.Codegen.init(alloc, &tc);
    defer cg.deinit();
    const sa_code = cg.generate(specialized) catch |err| {
        std.debug.print("CODEGEN ERROR: {}\n", .{err});
        std.process.exit(1);
    };

    const out_path = "tests/test_unit_math.sa";
    try std.fs.cwd().writeFile(.{ .sub_path = out_path, .data = sa_code });

    const stdout = std.io.getStdOut().writer();
    try stdout.print("OK  {s}  →  {s}  ({d} bytes, {d} @test blocks)\n", .{
        "tests/test_unit_math.sla",
        out_path,
        sa_code.len,
        std.mem.count(u8, sa_code, "@test "),
    });
}
