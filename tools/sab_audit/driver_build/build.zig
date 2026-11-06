const std = @import("std");

// DEF-SAB-AUDIT independent driver build. Standalone mini-project so
// the audit driver can be built WITHOUT touching the plugin's own
// build.zig (no main-flow wiring of any kind). Mirrors the module
// wiring build.zig uses for tools/dump_sab.zig: the driver module
// plus the sci `sio` compat module that parser/monomorphizer/
// type_checker import by name.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const sci_root = b.option([]const u8, "sci-root", "Path to a sci checkout (for src/sa_io.zig)") orelse
        b.graph.environ_map.get("SCI_ROOT") orelse "/content/sa_all/sci";

    const sio_module = b.createModule(.{
        .root_source_file = .{ .cwd_relative = b.pathJoin(&.{ sci_root, "src/sa_io.zig" }) },
        .target = target,
        .optimize = optimize,
    });
    const driver_module = b.createModule(.{
        .root_source_file = b.path("../../../src/sab_audit_driver.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    driver_module.addImport("sio", sio_module);

    const exe = b.addExecutable(.{
        .name = "sab_audit_driver",
        .root_module = driver_module,
    });
    b.installArtifact(exe);
}
