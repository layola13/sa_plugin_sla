// sab_audit_driver.zig — DEF-SAB-AUDIT independent test driver.
// Exercises src/sab_audit.zig WITHOUT wiring it into the compile
// pipeline: parse -> monomorphize -> type-check -> audit, for one
// .sla file, printing every classified hardcoded-class symbol use
// and every audit finding in a stable, diffable format.
//
// Usage:
//   sab_audit_driver <file.sla> [production|both|mirror] [--lenient]
//
// Exit codes: 0 = no hard findings, 3 = hard findings present,
// 4 = check failed but lenient audit ran, 2 = usage / io / parse /
// monomorphize failure (or check failure without --lenient).
// When type checking fails, with --lenient the audit still runs in
// lenient mode over the partially checked program (the pre-E0
// `using` surface is the motivating case).
//
// Build (from the repo root, SCI_ROOT pointing at a sci checkout):
//   zig build-exe src/sab_audit_driver.zig \
//     -M sio=$SCI_ROOT/src/sa_io.zig \
//     -O Debug -femit-bin=/tmp/sab_audit_driver
const std = @import("std");
const builtin = @import("builtin");
const sio = @import("sio");
const parser_mod = @import("parser.zig");
const monomorphizer_mod = @import("monomorphizer.zig");
const type_checker_mod = @import("type_checker.zig");
const audit_mod = @import("sab_audit.zig");

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var args_it: std.process.Args.Iterator = if (comptime builtin.os.tag == .windows)
        try std.process.Args.Iterator.initAllocator(init.minimal.args, alloc)
    else
        std.process.Args.Iterator.init(init.minimal.args);
    defer args_it.deinit();
    _ = args_it.skip();

    const file = args_it.next() orelse {
        std.debug.print("usage: sab_audit_driver <file.sla> [production|both|mirror] [--lenient]\n", .{});
        std.process.exit(2);
    };
    var targets = audit_mod.Targets.production;
    var lenient = false;
    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "both")) {
            targets = audit_mod.Targets.both;
        } else if (std.mem.eql(u8, arg, "mirror")) {
            targets = audit_mod.Targets.mirror_only;
        } else if (std.mem.eql(u8, arg, "production")) {
            targets = audit_mod.Targets.production;
        } else if (std.mem.eql(u8, arg, "--lenient")) {
            lenient = true;
        }
    }

    const source = sio.cwd().readFileAlloc(alloc, file, 10 * 1024 * 1024) catch |err| {
        std.debug.print("READ-FAIL {}\n", .{err});
        std.process.exit(2);
    };

    var p = parser_mod.Parser.init(alloc, source);
    const prog = p.parseProgram() catch |err| {
        std.debug.print("PARSE-FAIL {}\n", .{err});
        std.process.exit(2);
    };

    var mono = monomorphizer_mod.Monomorphizer.init(alloc);
    defer mono.deinit();
    const specialized = mono.monomorphize(prog, null, null) catch |err| {
        std.debug.print("MONO-FAIL {}\n", .{err});
        std.process.exit(2);
    };

    var tc = type_checker_mod.TypeChecker.init(alloc);
    defer tc.deinit();
    const check_ok = blk: {
        tc.checkProgram(specialized) catch |err| {
            std.debug.print("CHECK-FAIL {} {s}\n", .{ err, tc.last_error });
            break :blk false;
        };
        break :blk true;
    };

    if (!check_ok and !lenient) std.process.exit(2);

    const result = if (check_ok)
        try audit_mod.auditProgram(alloc, &tc, specialized, targets)
    else
        try audit_mod.auditProgramLenient(alloc, &tc, specialized, targets);

    for (result.uses) |use| {
        std.debug.print("USE {s} {s}\n", .{ use.symbol, use.class });
    }
    for (result.findings) |f| {
        const backend = if (f.backend) |be| @tagName(be) else "-";
        std.debug.print("FINDING {s} {s} backend={s} severity={s} signature={s}\n", .{
            f.symbol, f.class, backend, @tagName(f.severity), f.signature,
        });
    }
    std.debug.print("SUMMARY uses={d} findings={d} hard={d} check_ok={}\n", .{
        result.uses.len, result.findings.len, result.hardCount(), check_ok,
    });

    if (!check_ok) std.process.exit(4);
    if (result.hardCount() > 0) std.process.exit(3);
    std.process.exit(0);
}
