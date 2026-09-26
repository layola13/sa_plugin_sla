//! Simple-mode test runner that executes only a contiguous slice of the
//! compiled test list, selected by environment variables. This lets a driver
//! script run the (expensive-to-compile) test binary many times in fresh
//! processes, a few tests per invocation, so runtime memory is fully released
//! between batches on memory-constrained hosts.
//!
//!   SLA_TEST_START : index of the first test to run (default 0)
//!   SLA_TEST_COUNT : number of tests to run from START (default: all remaining)
//!   SLA_TEST_LIST  : if set to "1", print "<index>\t<name>" for every test and exit
//!
//! Exit code is non-zero if any test in the slice fails or leaks.
const builtin = @import("builtin");
const std = @import("std");
const testing = std.testing;

var log_err_count: usize = 0;

pub const std_options: std.Options = .{
    .logFn = log,
};

fn log(
    comptime message_level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    if (@intFromEnum(message_level) <= @intFromEnum(std.log.Level.err)) {
        log_err_count +|= 1;
    }
    if (@intFromEnum(message_level) <= @intFromEnum(std.testing.log_level)) {
        std.debug.print("[" ++ @tagName(scope) ++ "] (" ++ @tagName(message_level) ++ "): " ++ format ++ "\n", args);
    }
}

fn envUsize(name: []const u8) ?usize {
    const val = std.process.getEnvVarOwned(std.heap.page_allocator, name) catch return null;
    defer std.heap.page_allocator.free(val);
    if (val.len == 0) return null;
    return std.fmt.parseUnsigned(usize, val, 10) catch null;
}

fn envFlag(name: []const u8) bool {
    const val = std.process.getEnvVarOwned(std.heap.page_allocator, name) catch return false;
    defer std.heap.page_allocator.free(val);
    return std.mem.eql(u8, val, "1") or std.mem.eql(u8, val, "true");
}

pub fn main() void {
    const all = builtin.test_functions;

    if (envFlag("SLA_TEST_LIST")) {
        for (all, 0..) |t, i| {
            std.debug.print("{d}\t{s}\n", .{ i, t.name });
        }
        return;
    }

    const start = envUsize("SLA_TEST_START") orelse 0;
    const count = envUsize("SLA_TEST_COUNT") orelse (if (start < all.len) all.len - start else 0);
    const end = @min(all.len, start +| count);

    var ok: usize = 0;
    var skip: usize = 0;
    var fail: usize = 0;
    var leaks: usize = 0;

    var i = start;
    while (i < end) : (i += 1) {
        const t = all[i];
        testing.allocator_instance = .{};
        var leaked = false;
        defer {
            if (testing.allocator_instance.deinit() == .leak) leaked = true;
        }
        testing.log_level = .warn;

        std.debug.print("[{d}/{d}] {s} ... ", .{ i + 1, all.len, t.name });
        const result = t.func();
        if (result) |_| {
            if (leaked) {
                leaks += 1;
                std.debug.print("LEAK\n", .{});
            } else {
                ok += 1;
                std.debug.print("OK\n", .{});
            }
        } else |err| switch (err) {
            error.SkipZigTest => {
                skip += 1;
                std.debug.print("SKIP\n", .{});
            },
            else => {
                fail += 1;
                std.debug.print("FAIL ({s})\n", .{@errorName(err)});
                if (@errorReturnTrace()) |trace| std.debug.dumpStackTrace(trace.*);
            },
        }
    }

    std.debug.print(
        "batch [{d},{d}) result: {d} passed; {d} skipped; {d} failed; {d} leaked; {d} log-errors\n",
        .{ start, end, ok, skip, fail, leaks, log_err_count },
    );

    if (fail != 0 or leaks != 0 or log_err_count != 0) std.process.exit(1);
}
