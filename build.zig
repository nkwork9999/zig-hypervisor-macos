const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ============== VMM (zigvm) ==============
    const exe = b.addExecutable(.{
        .name = "zigvm",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.linkFramework("Hypervisor");
    b.installArtifact(exe);

    // ============== zigvm-viewer (SDL2 GUI) ==============
    const viewer = b.addExecutable(.{
        .name = "zigvm-viewer",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/viewer_main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    viewer.addIncludePath(.{ .cwd_relative = "/opt/homebrew/include" });
    viewer.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/lib" });
    viewer.linkSystemLibrary("SDL2");
    viewer.linkLibC();
    b.installArtifact(viewer);

    const run_step = b.step("run", "Run zigvm (loads ../202601zigos kernel)");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    // ============== Tests (純粋ロジックモジュール) ==============
    const test_step = b.step("test", "Run all unit tests");
    inline for (&[_][]const u8{ "vmcore", "dtb", "gic", "pl011" }) |name| {
        const t = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/" ++ name ++ ".zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }

    // ============== Demos (自己完結) ==============
    const demos = [_]struct { name: []const u8, src: []const u8 }{
        .{ .name = "demo_a", .src = "demo_a_calc.zig" },
        .{ .name = "demo_b", .src = "demo_b_countdown.zig" },
        .{ .name = "demo_c", .src = "demo_c_input.zig" },
        .{ .name = "demo_d", .src = "demo_d_timer.zig" },
    };
    for (demos) |demo| {
        const demo_exe = b.addExecutable(.{
            .name = demo.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(demo.src),
                .target = target,
                .optimize = optimize,
            }),
        });
        demo_exe.linkFramework("Hypervisor");
        b.installArtifact(demo_exe);

        const demo_run = b.addRunArtifact(demo_exe);
        demo_run.step.dependOn(b.getInstallStep());
        const demo_step = b.step(demo.name, demo.src);
        demo_step.dependOn(&demo_run.step);
    }
}
