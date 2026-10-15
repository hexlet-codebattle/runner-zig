const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "runner-zig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.addPassthruArgs();

    const run_step = b.step("run", "Run the HTTP service");
    run_step.dependOn(&run_cmd.step);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_tests = b.addRunArtifact(tests);
    // The integration tests spawn zig-out/bin/runner-zig, which is not an
    // input the run step can see: build it first and never serve cached results.
    run_tests.step.dependOn(b.getInstallStep());
    run_tests.has_side_effects = true;
    const test_step = b.step("test", "Run integration tests");
    test_step.dependOn(&run_tests.step);
}
