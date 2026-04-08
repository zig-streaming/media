const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const core = b.addModule("core", .{
        .root_source_file = b.path("src/core/core.zig"),
        .target = target,
        .optimize = optimize,
    });

    const rtp = b.addModule("rtp", .{
        .root_source_file = b.path("src/rtp/rtp.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core", .module = core },
        },
    });

    const core_tests = b.addTest(.{ .root_module = core });
    const run_core_tests = b.addRunArtifact(core_tests);

    const rtp_tests = b.addTest(.{ .root_module = rtp });
    const run_rtp_tests = b.addRunArtifact(rtp_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_core_tests.step);
    test_step.dependOn(&run_rtp_tests.step);

    {
        const bench_step = b.step("bench", "Run all benchmarks");
        const benches = [_]struct { name: []const u8, src: []const u8 }{
            .{ .name = "h264_sps", .src = "bench/core/h264_sps.zig" },
        };

        inline for (benches) |bench| {
            const bench_exe = b.addExecutable(.{
                .name = bench.name,
                .root_module = b.createModule(.{
                    .root_source_file = b.path(bench.src),
                    .target = target,
                    .optimize = .ReleaseFast,
                    .imports = &.{
                        .{ .name = "core", .module = core },
                    },
                }),
            });

            bench_step.dependOn(&b.addRunArtifact(bench_exe).step);
        }
    }
}
