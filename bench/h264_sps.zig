const std = @import("std");
const h264 = @import("media").h264;

const sps_nal = [_]u8{
    0x67, 0x64, 0x00, 0x1F, 0xAC, 0xD9, 0x40,
    0x50, 0x05, 0xBB, 0x01, 0x6C, 0x80, 0x00,
    0x00, 0x03, 0x00, 0x80, 0x00, 0x00, 0x1E,
    0x07, 0x8C, 0x18, 0xCB,
};

const sps_with_scaling_list = [_]u8{
    0x66, 0x64, 0x00, 0x32, 0xAD, 0x84, 0x01, 0x0C, 0x20, 0x08,
    0x61, 0x00, 0x43, 0x08, 0x02, 0x18, 0x40, 0x10, 0xC2, 0x00,
    0x84, 0x3B, 0x50, 0x14, 0x00, 0x5A, 0xD3, 0x70, 0x10, 0x10,
    0x14, 0x00, 0x00, 0x03, 0x00, 0x04, 0x00, 0x00, 0x03, 0x00,
    0xA2, 0x10,
};

const sps_with_frame_cropping = [_]u8{
    0x67, 0x42, 0xC0, 0x28, 0xD9, 0x00, 0x78, 0x02,
    0x27, 0xE5, 0x84, 0x00, 0x00, 0x03, 0x00, 0x04,
    0x00, 0x00, 0x03, 0x00, 0xF0, 0x3C, 0x60, 0xC9,
    0x20,
};

const iterations = 1_000_000;

pub fn main() !void {
    var buffer: [1024]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&buffer);

    try stdout.interface.writeAll("\x1b[1;36m┌─────────────────────────┐\x1b[0m\n");
    try stdout.interface.writeAll("\x1b[1;36m│     H264 SPS Benchmarks │\x1b[0m\n");
    try stdout.interface.writeAll("\x1b[1;36m└─────────────────────────┘\x1b[0m\n\n");

    // Warm-up: one pass to bring code/data into cache.
    for (0..iterations) |_| {
        const sps = try h264.Sps.parse(sps_nal[1..]);
        std.mem.doNotOptimizeAway(sps);
    }

    const fixtures = [_]struct {
        name: []const u8,
        data: []const u8,
    }{
        .{ .name = "Basic SPS", .data = sps_nal[1..] },
        .{ .name = "SPS with scaling list", .data = sps_with_scaling_list[1..] },
        .{ .name = "SPS with frame cropping", .data = sps_with_frame_cropping[1..] },
    };

    for (fixtures) |fixture| {
        try benchMark(fixture.name, fixture.data, &stdout.interface);
    }

    try stdout.interface.flush();
}

fn benchMark(name: []const u8, data: []const u8, writer: *std.Io.Writer) !void {
    var timer = try std.time.Timer.start();

    for (0..iterations) |_| {
        const sps = try h264.Sps.parse(data);
        std.mem.doNotOptimizeAway(sps);
    }

    const elapsed_ns = timer.read();
    const ns_per_op = elapsed_ns / iterations;
    const ops_per_sec = @as(u64, std.time.ns_per_s) / @max(ns_per_op, 1);

    try writer.print("\x1b[1;33mH264 {s}\x1b[0m\n" ++
        "  iterations : {d}\n" ++
        "  total time : {d} ms\n" ++
        "  ns/op      : {d}\n" ++
        "  ops/sec    : {d}\n\n", .{
        name,
        iterations,
        elapsed_ns / std.time.ns_per_ms,
        ns_per_op,
        ops_per_sec,
    });
}
