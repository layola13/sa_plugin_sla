// test_driver.zig – standalone end-to-end compilation check for @test support.
// Compile & run: zig run src/test_driver.zig
const std = @import("std");
const parser_mod = @import("parser.zig");
const monomorphizer_mod = @import("monomorphizer.zig");
const type_checker_mod = @import("type_checker.zig");
const codegen_mod = @import("codegen.zig");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\fn add(a: int, b: int) -> int {
        \\    return a + b;
        \\}
        \\
        \\@test "add passes"() {
        \\    let result = add(3, 4);
        \\    let ok = result == 7;
        \\    if ok {
        \\    } else {
        \\        panic(1);
        \\    };
        \\}
        \\
        \\@test ignored "skipped test"() {
        \\    let x = add(0, 0);
        \\}
        \\
        \\@test should_panic "expected panic"() {
        \\    panic(99);
        \\}
    ;

    var p = parser_mod.Parser.init(alloc, source);
    const prog = try p.parseProgram();

    var mono = monomorphizer_mod.Monomorphizer.init(alloc);
    defer mono.deinit();
    const specialized = try mono.monomorphize(prog);

    var tc = type_checker_mod.TypeChecker.init(alloc);
    defer tc.deinit();
    try tc.checkProgram(specialized);

    var cg = codegen_mod.Codegen.init(alloc, &tc);
    defer cg.deinit();
    const sa_code = try cg.generate(specialized);

    const stdout = std.io.getStdOut().writer();
    try stdout.print("=== Generated SA code ===\n{s}\n", .{sa_code});
}
