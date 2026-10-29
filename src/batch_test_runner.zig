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
//!
//! ---------------------------------------------------------------------------
//! Supervisor mode (parallel test kernel)
//!
//! The legacy per-index protocol (one fresh process per test, driven by an
//! external shell loop with `timeout`) is correct but serial: a handful of
//! blocked tests at 60 s apiece dominate the wall clock of the whole suite.
//! Supervisor mode moves that protocol INTO this runner: the binary builds
//! once, then supervises one worker process per test (itself, re-executed
//! with SLA_TEST_START=i / SLA_TEST_COUNT=1), with a configurable number of
//! workers running concurrently, a hard per-test timeout enforced by the
//! supervisor (SIGTERM to the worker's process group, SIGKILL 5 s later),
//! and verdicts journaled incrementally so a killed run loses nothing.
//!
//! Worker processes (not threads) are the unit of parallelism on purpose:
//! the integration tests in this suite mutate process-global state — most
//! importantly the working directory (`setAsCwd` into a per-test tmp dir) —
//! so in-process thread parallelism cannot be sound. Each worker is a fresh
//! process with its own cwd state, its own testing allocator instance and a
//! private TMPDIR; fixture-relative reads still work because workers keep
//! the repository root as their initial cwd, exactly like the legacy
//! protocol.
//!
//! Activation:
//!   SLA_TEST_JOBS=N        (N >= 1) run N workers concurrently
//!   SLA_TEST_SUPERVISE=1   supervise with a default job count
//! (Environment variables are this runner's configuration surface, as with
//! SLA_TEST_START/COUNT/LIST above: the simple-mode runner entry point
//! receives no command-line arguments.)
//!
//! Further configuration (environment):
//!   SLA_TEST_TIMEOUT_MS    per-test timeout in ms (default 60000)
//!   SLA_TEST_RESULTS       journal file path: one "<idx>\t<VERDICT>\t<rc>\t<name>"
//!                          line per verdict, appended + fsynced as verdicts
//!                          land. Re-running with the same journal resumes:
//!                          indices whose recorded name still matches the
//!                          current test list are not re-run.
//!   SLA_TEST_LOG           path of the final ordered verdict log
//!                          (segment-6 format: "TOTAL <n>", then "PASS <i>" /
//!                          "FAIL <i> <i>\t<name> rc=<rc>" /
//!                          "HANG <i> <i>\t<name>", then "DONE"). The same
//!                          text is always printed to stderr at completion.
//!   SLA_TEST_SERIAL        comma-separated test-name substrings forced into
//!                          the serial phase (run one at a time, after the
//!                          parallel phase, still timeout-isolated). Use for
//!                          tests known to contend on a shared resource.
//!   SLA_TEST_SERIAL_FILE   file with one serial substring per line.
//!   SLA_TEST_START/COUNT   the usual window semantics.
//!
//! Worker stdout/stderr is captured per index into "<results>.out/<idx>.log"
//! (or "<log>.out/...", or "/tmp/sla-test-out-<pid>/..." when neither is
//! set) and dumped to stderr for FAIL/HANG indices at the end.
//!
//! Exit code is 1 if any test in the window FAILs or HANGs, else 0.
//! Supervisor mode is POSIX-only; on other platforms it warns loudly and
//! falls back to the legacy in-process slice.
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
    // NOTE(Zig 0.17): `std.process.getEnvVarOwned` was removed; read via
    // `std.c.getenv` (same approach as sci's sio.getEnvVarOwned) without
    // importing sio (this is a standalone test_runner module).
    const zkey = std.heap.page_allocator.dupeSentinel(u8, name, 0) catch return null;
    defer std.heap.page_allocator.free(zkey);
    const raw = std.c.getenv(zkey) orelse return null;
    const val = std.mem.span(raw);
    if (val.len == 0) return null;
    return std.fmt.parseUnsigned(usize, val, 10) catch null;
}

fn envFlag(name: []const u8) bool {
    const zkey = std.heap.page_allocator.dupeSentinel(u8, name, 0) catch return false;
    defer std.heap.page_allocator.free(zkey);
    const raw = std.c.getenv(zkey) orelse return false;
    const val = std.mem.span(raw);
    return std.mem.eql(u8, val, "1") or std.mem.eql(u8, val, "true");
}

fn envString(name: []const u8) ?[]const u8 {
    const zkey = std.heap.page_allocator.dupeSentinel(u8, name, 0) catch return null;
    defer std.heap.page_allocator.free(zkey);
    const raw = std.c.getenv(zkey) orelse return null;
    const val = std.mem.span(raw);
    if (val.len == 0) return null;
    return val;
}

pub fn main() void {
    const all = builtin.test_functions;

    if (envFlag("SLA_TEST_LIST")) {
        for (all, 0..) |t, i| {
            std.debug.print("{d}\t{s}\n", .{ i, t.name });
        }
        return;
    }

    // Supervisor mode: never entered by workers (SLA_TEST_WORKER=1) so a
    // worker always runs exactly its own slice through the legacy path.
    if (!envFlag("SLA_TEST_WORKER")) {
        if (supervisorRequested()) {
            std.process.exit(supervisorMain(all));
        }
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
        testing.allocator_instance = .init(std.heap.page_allocator, .{
            .canary = 0xc3a701ba,
            .check_write_after_free = true,
        });
        var leaked = false;
        defer {
            if (testing.allocator_instance.deinit() != 0) leaked = true;
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
                if (@errorReturnTrace()) |trace| std.debug.dumpErrorReturnTrace(trace);
            },
        }
    }

    std.debug.print(
        "batch [{d},{d}) result: {d} passed; {d} skipped; {d} failed; {d} leaked; {d} log-errors\n",
        .{ start, end, ok, skip, fail, leaks, log_err_count },
    );

    if (fail != 0 or leaks != 0 or log_err_count != 0) std.process.exit(1);
}

// ===========================================================================
// Supervisor mode implementation (POSIX).
// ===========================================================================

extern "c" var environ: [*:null]?[*:0]u8;
extern "c" fn fork() c_int;
extern "c" fn setsid() c_int;
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;
extern "c" fn execve(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8, envp: [*:null]?[*:0]u8) c_int;
extern "c" fn waitpid(pid: c_int, status: ?*c_int, options: c_int) c_int;
extern "c" fn kill(pid: c_int, sig: c_int) c_int;
extern "c" fn clock_gettime(clk: c_int, tp: *std.c.timespec) c_int;
extern "c" fn nanosleep(rqtp: *const std.c.timespec, rmtp: ?*std.c.timespec) c_int;
extern "c" fn _exit(status: c_int) noreturn;
extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern "c" fn read(fd: c_int, buf: [*]u8, count: usize) isize;
extern "c" fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn fsync(fd: c_int) c_int;
extern "c" fn mkdir(path: [*:0]const u8, mode: c_uint) c_int;
extern "c" fn dup2(old_fd: c_int, new_fd: c_int) c_int;
extern "c" fn getpid() c_int;

const CLOCK_MONOTONIC: c_int = 1;
const WNOHANG: c_int = 1;
const SIGTERM: c_int = 15;
const SIGKILL: c_int = 9;
const O_RDONLY: c_int = 0;
const O_WRONLY: c_int = 1;
const O_CREAT: c_int = 0o100;
const O_TRUNC: c_int = 0o1000;
const O_APPEND: c_int = 0o2000;

fn writeAllFd(fd: c_int, data: []const u8) void {
    var off: usize = 0;
    while (off < data.len) {
        const n = write(fd, data.ptr + off, data.len - off);
        if (n <= 0) return;
        off += @intCast(n);
    }
}

fn readFileAllocC(alloc: std.mem.Allocator, path: []const u8, max: usize) ?[]u8 {
    var zbuf: [768]u8 = undefined;
    const zp = std.fmt.bufPrintSentinel(&zbuf, "{s}", .{path}, 0) catch return null;
    const fd = open(zp, O_RDONLY);
    if (fd < 0) return null;
    defer _ = close(fd);
    var list: std.ArrayList(u8) = .empty;
    var chunk: [8192]u8 = undefined;
    while (list.items.len <= max) {
        const n = read(fd, &chunk, chunk.len);
        if (n < 0) {
            list.deinit(alloc);
            return null;
        }
        if (n == 0) break;
        list.appendSlice(alloc, chunk[0..@intCast(n)]) catch {
            list.deinit(alloc);
            return null;
        };
    }
    return list.items;
}

fn makePathC(path: []const u8) void {
    // mkdir -p: try each prefix, ignoring "already exists" errors.
    var zbuf: [768]u8 = undefined;
    const zp = std.fmt.bufPrintSentinel(&zbuf, "{s}", .{path}, 0) catch return;
    var i: usize = 1;
    while (i < zp.len) : (i += 1) {
        if (zp[i] == '/') {
            zp[i] = 0;
            _ = mkdir(zp, 0o755);
            zp[i] = '/';
        }
    }
    _ = mkdir(zp, 0o755);
}

fn nowMs() i64 {
    var ts: std.c.timespec = undefined;
    _ = clock_gettime(CLOCK_MONOTONIC, &ts);
    return @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.nsec)), 1_000_000);
}

fn sleepMs(ms: i64) void {
    const req: std.c.timespec = .{
        .sec = @intCast(@divTrunc(ms, 1000)),
        .nsec = @intCast(@rem(ms, 1000) * 1_000_000),
    };
    _ = nanosleep(&req, null);
}

const Verdict = enum { unknown, pass, fail, hang };

const SupConfig = struct {
    jobs: usize = 0, // 0 = not requested
    supervise: bool = false,
    timeout_ms: i64 = 60_000,
    results_path: ?[]const u8 = null,
    log_path: ?[]const u8 = null,
    serial_env: ?[]const u8 = null,
    serial_file: ?[]const u8 = null,
};

var g_cfg: SupConfig = .{};

fn supervisorRequested() bool {
    g_cfg = .{};
    if (envUsize("SLA_TEST_JOBS")) |j| {
        g_cfg.jobs = j;
        g_cfg.supervise = true;
    }
    if (envFlag("SLA_TEST_SUPERVISE")) g_cfg.supervise = true;
    if (envUsize("SLA_TEST_TIMEOUT_MS")) |t| g_cfg.timeout_ms = @intCast(t);
    g_cfg.results_path = envString("SLA_TEST_RESULTS");
    g_cfg.log_path = envString("SLA_TEST_LOG");
    g_cfg.serial_env = envString("SLA_TEST_SERIAL");
    g_cfg.serial_file = envString("SLA_TEST_SERIAL_FILE");
    return g_cfg.supervise;
}

const Running = struct {
    idx: usize,
    pid: c_int,
    started_ms: i64,
    term_sent_ms: ?i64 = null,
    timed_out: bool = false,
};

fn isSerialName(name: []const u8, pats: []const []const u8) bool {
    for (pats) |p| {
        if (p.len != 0 and std.mem.indexOf(u8, name, p) != null) return true;
    }
    return false;
}

fn spawnWorker(idx: usize, out_path_z: [:0]const u8, tmpdir_z: [:0]const u8) ?c_int {
    const pid = fork();
    if (pid < 0) return null;
    if (pid == 0) {
        // Child: new session (own process group so the supervisor can kill
        // the whole tree, including any `zig cc` grandchildren), stdio
        // redirected, environment pinned to exactly one legacy slice.
        _ = setsid();
        const devnull = open("/dev/null", O_RDONLY);
        if (devnull < 0) _exit(127);
        if (dup2(devnull, 0) < 0) _exit(127);
        const outfd = open(out_path_z, O_WRONLY | O_CREAT | O_TRUNC, @as(c_uint, 0o644));
        if (outfd < 0) _exit(127);
        if (dup2(outfd, 1) < 0) _exit(127);
        if (dup2(outfd, 2) < 0) _exit(127);

        var ibuf: [24]u8 = undefined;
        const ival = std.fmt.bufPrintSentinel(&ibuf, "{d}", .{idx}, 0) catch _exit(127);
        _ = setenv("SLA_TEST_START", ival, 1);
        _ = setenv("SLA_TEST_COUNT", "1", 1);
        _ = setenv("SLA_TEST_WORKER", "1", 1);
        _ = setenv("TMPDIR", tmpdir_z, 1);
        _ = unsetenv("SLA_TEST_JOBS");
        _ = unsetenv("SLA_TEST_SUPERVISE");
        _ = unsetenv("SLA_TEST_RESULTS");
        _ = unsetenv("SLA_TEST_LOG");
        _ = unsetenv("SLA_TEST_LIST");

        const self_path: [*:0]const u8 = "/proc/self/exe";
        const argv = [_:null]?[*:0]const u8{ self_path, null };
        _ = execve(self_path, &argv, environ);
        _exit(127);
    }
    return pid;
}

fn killTree(pid: c_int, sig: c_int) void {
    // Negative pid targets the worker's process group (it called setsid).
    if (kill(-pid, sig) != 0) {
        _ = kill(pid, sig);
    }
}

fn writeJournal(journal_fd: *?c_int, idx: usize, v: Verdict, rc: i64, name: []const u8) void {
    if (journal_fd.*) |fd| {
        var buf: [1200]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "{d}\t{s}\t{d}\t{s}\n", .{ idx, @tagName(v), rc, name }) catch return;
        writeAllFd(fd, line);
        _ = fsync(fd);
    }
}

fn supervisorMain(all: []const std.builtin.TestFn) u8 {
    const alloc = std.heap.page_allocator;
    const cfg = g_cfg;

    if (builtin.os.tag == .windows) {
        std.debug.print("supervisor mode is POSIX-only on this build; refusing to silently degrade (exit 2)\n", .{});
        return 2;
    }

    const jobs: usize = blk: {
        if (cfg.jobs > 0) break :blk @min(cfg.jobs, 64);
        const cpus = std.Thread.getCpuCount() catch 2;
        break :blk @max(1, @min(cpus, 8));
    };

    const start = envUsize("SLA_TEST_START") orelse 0;
    const count = envUsize("SLA_TEST_COUNT") orelse (if (start < all.len) all.len - start else 0);
    const end = @min(all.len, start +| count);
    const window_len = end - start;

    // Serial-phase substrings.
    var pats: std.ArrayList([]const u8) = .empty;
    defer pats.deinit(alloc);
    if (cfg.serial_env) |s| {
        var it = std.mem.splitScalar(u8, s, ',');
        while (it.next()) |p| {
            if (p.len != 0) pats.append(alloc, p) catch {};
        }
    }
    if (cfg.serial_file) |path| {
        if (readFileAllocC(alloc, path, 1 << 20)) |data| {
            var it = std.mem.splitScalar(u8, data, '\n');
            while (it.next()) |line| {
                const p = std.mem.trim(u8, line, " \r\t");
                if (p.len != 0) pats.append(alloc, p) catch {};
            }
        } else {
            std.debug.print("[sup] WARNING: cannot read serial file {s}\n", .{path});
        }
    }

    const verdicts = alloc.alloc(Verdict, all.len) catch return 2;
    const rcs = alloc.alloc(i64, all.len) catch return 2;
    @memset(verdicts, .unknown);
    @memset(rcs, 0);
    var done_count: usize = 0;

    // Journal (incremental results + resume).
    var journal: ?c_int = null;
    if (cfg.results_path) |rp| {
        if (readFileAllocC(alloc, rp, 1 << 24)) |data| {
            var lines = std.mem.splitScalar(u8, data, '\n');
            while (lines.next()) |line| {
                var f = std.mem.splitScalar(u8, line, '\t');
                const idx_s = f.next() orelse continue;
                const v_s = f.next() orelse continue;
                const rc_s = f.next() orelse continue;
                const name = f.next() orelse continue;
                const idx = std.fmt.parseUnsigned(usize, idx_s, 10) catch continue;
                if (idx < start or idx >= end) continue;
                if (!std.mem.eql(u8, name, all[idx].name)) continue;
                const v: Verdict = if (std.mem.eql(u8, v_s, "pass")) .pass else if (std.mem.eql(u8, v_s, "fail")) .fail else if (std.mem.eql(u8, v_s, "hang")) .hang else continue;
                verdicts[idx] = v;
                rcs[idx] = std.fmt.parseInt(i64, rc_s, 10) catch 0;
                done_count += 1;
            }
        } else {}
        var rpz: [768]u8 = undefined;
        if (std.fmt.bufPrintSentinel(&rpz, "{s}", .{rp}, 0)) |rpz_s| {
            const fd = open(rpz_s, O_WRONLY | O_CREAT | O_APPEND, @as(c_uint, 0o644));
            if (fd >= 0) journal = fd;
        } else |_| {}
    }
    defer if (journal) |fd| {
        _ = close(fd);
    };

    // Worker output directory.
    var outdir_buf: [512]u8 = undefined;
    const outdir: []const u8 = blk: {
        if (cfg.results_path) |rp| break :blk std.fmt.bufPrint(&outdir_buf, "{s}.out", .{rp}) catch "/tmp/sla-test-out";
        if (cfg.log_path) |lp| break :blk std.fmt.bufPrint(&outdir_buf, "{s}.out", .{lp}) catch "/tmp/sla-test-out";
        break :blk std.fmt.bufPrint(&outdir_buf, "/tmp/sla-test-out-{d}", .{getpid()}) catch "/tmp/sla-test-out";
    };
    makePathC(outdir);

    // Work queues: parallel first, serial second.
    var par_q: std.ArrayList(usize) = .empty;
    var ser_q: std.ArrayList(usize) = .empty;
    defer par_q.deinit(alloc);
    defer ser_q.deinit(alloc);
    var wi = start;
    while (wi < end) : (wi += 1) {
        if (verdicts[wi] != .unknown) continue;
        if (isSerialName(all[wi].name, pats.items)) {
            ser_q.append(alloc, wi) catch {};
        } else {
            par_q.append(alloc, wi) catch {};
        }
    }

    std.debug.print("[sup] window [{d},{d}) jobs={d} timeout={d}ms pending={d} (parallel {d}, serial {d}), resumed {d}\n", .{
        start, end, jobs, cfg.timeout_ms, window_len - done_count, par_q.items.len, ser_q.items.len, done_count,
    });

    var running: std.ArrayList(Running) = .empty;
    defer running.deinit(alloc);
    var par_pos: usize = 0;
    var ser_pos: usize = 0;
    const t_begin = nowMs();

    while (true) {
        // Serial phase gate: serial tests start only once every parallel
        // test has been spawned and all workers have drained, so they are
        // exclusive against the whole suite.
        const par_all_spawned = par_pos >= par_q.items.len;
        while (running.items.len < jobs) {
            var next_idx: ?usize = null;
            var from_par = false;
            if (par_pos < par_q.items.len) {
                next_idx = par_q.items[par_pos];
                from_par = true;
            } else if (par_all_spawned and running.items.len == 0 and ser_pos < ser_q.items.len) {
                next_idx = ser_q.items[ser_pos];
            }
            const idx = next_idx orelse break;

            var op_buf: [768]u8 = undefined;
            const op = std.fmt.bufPrintSentinel(&op_buf, "{s}/{d}.log", .{ outdir, idx }, 0) catch break;
            var td_buf: [768]u8 = undefined;
            const td = std.fmt.bufPrintSentinel(&td_buf, "{s}/tmp-{d}", .{ outdir, idx % jobs }, 0) catch break;
            makePathC(td);

            var attempts: usize = 0;
            const pid: ?c_int = blk2: while (true) {
                if (spawnWorker(idx, op, td)) |p| break :blk2 p;
                attempts += 1;
                if (attempts >= 10) break :blk2 null;
                sleepMs(50);
            };
            if (from_par) par_pos += 1 else ser_pos += 1;
            if (pid) |p| {
                running.append(alloc, .{ .idx = idx, .pid = p, .started_ms = nowMs() }) catch {
                    killTree(p, SIGKILL);
                    verdicts[idx] = .fail;
                    rcs[idx] = 127;
                    done_count += 1;
                    writeJournal(&journal, idx, .fail, 127, all[idx].name);
                };
            } else {
                verdicts[idx] = .fail;
                rcs[idx] = 127;
                done_count += 1;
                std.debug.print("[sup] {d}/{d} idx={d} fail rc=127 (spawn failure)\n", .{ done_count, window_len, idx });
                writeJournal(&journal, idx, .fail, 127, all[idx].name);
            }
        }

        if (running.items.len == 0) {
            if (par_pos >= par_q.items.len and ser_pos >= ser_q.items.len) break;
            if (par_pos >= par_q.items.len and ser_pos < ser_q.items.len) continue; // enter serial phase
            break; // should not happen; fail loud via unknown-verdict lines below
        }

        // Poll workers.
        var progressed = false;
        var r: usize = 0;
        while (r < running.items.len) {
            const w = running.items[r];
            var status: c_int = 0;
            const wp = waitpid(w.pid, &status, WNOHANG);
            if (wp == w.pid) {
                var v: Verdict = undefined;
                var rc: i64 = 0;
                if (w.timed_out) {
                    v = .hang;
                    rc = 124;
                } else if ((status & 0x7f) == 0) {
                    rc = @intCast((status >> 8) & 0xff);
                    v = if (rc == 0) .pass else .fail;
                } else if ((status & 0x7f) != 0x7f) {
                    const sig: i64 = @intCast(status & 0x7f);
                    v = .fail;
                    rc = 128 + sig;
                } else {
                    v = .fail;
                    rc = 1;
                }
                verdicts[w.idx] = v;
                rcs[w.idx] = rc;
                done_count += 1;
                progressed = true;
                std.debug.print("[sup] {d}/{d} idx={d} {s} rc={d} ({d}ms)\n", .{
                    done_count, window_len, w.idx, @tagName(v), rc, nowMs() - w.started_ms,
                });
                writeJournal(&journal, w.idx, v, rc, all[w.idx].name);
                _ = running.orderedRemove(r);
                continue;
            }
            // Timeout enforcement: SIGTERM first, SIGKILL 5 s later.
            const now = nowMs();
            if (!w.timed_out and now - w.started_ms >= cfg.timeout_ms) {
                running.items[r].timed_out = true;
                running.items[r].term_sent_ms = now;
                killTree(w.pid, SIGTERM);
            } else if (w.timed_out and w.term_sent_ms != null and now - w.term_sent_ms.? >= 5000) {
                killTree(w.pid, SIGKILL);
                running.items[r].term_sent_ms = now; // re-arm, avoid kill spam
            }
            r += 1;
        }
        if (!progressed) sleepMs(5);
    }

    // Ordered final log (segment-6 format).
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(alloc);
    text.print(alloc, "TOTAL {d}\n", .{all.len}) catch {};
    var idx = start;
    var n_pass: usize = 0;
    var n_fail: usize = 0;
    var n_hang: usize = 0;
    while (idx < end) : (idx += 1) {
        switch (verdicts[idx]) {
            .pass => {
                n_pass += 1;
                text.print(alloc, "PASS {d}\n", .{idx}) catch {};
            },
            .fail => {
                n_fail += 1;
                text.print(alloc, "FAIL {d} {d}\t{s} rc={d}\n", .{ idx, idx, all[idx].name, rcs[idx] }) catch {};
            },
            .hang => {
                n_hang += 1;
                text.print(alloc, "HANG {d} {d}\t{s}\n", .{ idx, idx, all[idx].name }) catch {};
            },
            .unknown => {
                n_fail += 1;
                text.print(alloc, "FAIL {d} {d}\t{s} rc=126\n", .{ idx, idx, all[idx].name }) catch {};
            },
        }
    }
    text.print(alloc, "DONE\n", .{}) catch {};
    if (cfg.log_path) |lp| {
        var lpz: [768]u8 = undefined;
        if (std.fmt.bufPrintSentinel(&lpz, "{s}", .{lp}, 0)) |lpz_s| {
            const fd = open(lpz_s, O_WRONLY | O_CREAT | O_TRUNC, @as(c_uint, 0o644));
            if (fd >= 0) {
                writeAllFd(fd, text.items);
                _ = close(fd);
            }
        } else |_| {}
    }
    std.debug.print("{s}", .{text.items});
    std.debug.print("[sup] finished: {d} pass, {d} fail, {d} hang, wall {d}ms\n", .{
        n_pass, n_fail, n_hang, nowMs() - t_begin,
    });

    // Dump captured worker output for failures/hangs (debugging aid).
    idx = start;
    while (idx < end) : (idx += 1) {
        if (verdicts[idx] == .fail or verdicts[idx] == .hang) {
            var op_buf: [768]u8 = undefined;
            const op = std.fmt.bufPrint(&op_buf, "{s}/{d}.log", .{ outdir, idx }) catch continue;
            if (readFileAllocC(alloc, op, 1 << 20)) |data| {
                if (data.len != 0) {
                    std.debug.print("----- worker output idx={d} ({s}) -----\n{s}\n", .{ idx, @tagName(verdicts[idx]), data });
                }
            }
        }
    }

    return if (n_fail == 0 and n_hang == 0) 0 else 1;
}
