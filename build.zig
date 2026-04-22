const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("media", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const media_tests = b.addTest(.{ .root_module = mod });
    const run_media_tests = b.addRunArtifact(media_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_media_tests.step);

    {
        const zbench_dep = b.dependency("zbench", .{
            .target = target,
            .optimize = .ReleaseFast,
        });
        const zbench_mod = zbench_dep.module("zbench");

        const bench_step = b.step("bench", "Run all benchmarks");

        const benches = .{
            .{ .name = "h264_sps", .src = "bench/h264_sps.zig" },
        };

        inline for (benches) |bench| {
            const bench_exe = b.addExecutable(.{
                .name = bench.name,
                .root_module = b.createModule(.{
                    .root_source_file = b.path(bench.src),
                    .target = target,
                    .optimize = .ReleaseFast,
                    .imports = &.{
                        .{ .name = "media", .module = mod },
                        .{ .name = "zbench", .module = zbench_mod },
                    },
                }),
            });

            const run = b.addRunArtifact(bench_exe);
            const single_step = b.step("bench-" ++ bench.name, "Run " ++ bench.name ++ " benchmark");
            single_step.dependOn(&run.step);
            bench_step.dependOn(&run.step);
        }
    }
}
