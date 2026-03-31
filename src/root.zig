//! By convention, root.zig is the root source file when making a library.
const std = @import("std");

const Allocator = std.mem.Allocator;

pub const h264 = @import("h264.zig");
pub const BitReader = @import("bit_reader.zig");

pub const Codec = enum {
    h264,
    h265,
    aac,
    unknown,

    pub fn toString(self: *const Codec) []const u8 {
        return switch (self.*) {
            .h264 => "H.264",
            .h265 => "H.265",
            .aac => "AAC",
            .unknown => "Unknown",
        };
    }
};

const BufferRef = struct {
    data: []u8,
    ref_count: std.atomic.Value(u32),

    pub const empty = BufferRef{
        .data = &.{},
        .ref_count = .init(1),
    };

    pub fn init(buffer_ref: *BufferRef, allocator: Allocator, size: usize) !void {
        buffer_ref.data = try allocator.alloc(u8, size);
    }

    pub fn deinit(buffer_ref: *BufferRef, allocator: Allocator) void {
        const old_value = buffer_ref.ref_count.fetchSub(1, .seq_cst);
        if (old_value == 1) allocator.free(buffer_ref.data);
    }
};

/// Represents a media packet, which may contain video frames, audio samples, or other media data.
pub const Packet = struct {
    /// Presentation Timestamp (PTS) indicates when the packet should be presented to the user.
    pts: i64,
    /// Decoding Timestamp (DTS) indicates when the packet should be decoded.
    dts: i64,
    /// Duration of the packet in time units (e.g., milliseconds). This is optional and may not be set for all packets.
    duration: ?u64 = null,
    /// This is a slice that points to the actual data.
    ///
    /// If `buffer_ref` is set, this slice points to the data owned by `buffer_ref`. Otherwise, it points to external data that this packet does not own.
    data: []const u8,
    /// This is reference counted buffer that owns the data.
    buffer_ref: ?*BufferRef = null,

    pub fn init(allocator: Allocator, size: usize) !Packet {
        const buffer_ref = try allocator.create(BufferRef);

        buffer_ref.* = .{
            .data = try allocator.alloc(u8, size),
            .ref_count = .init(1),
        };

        return .{
            .pts = 0,
            .dts = 0,
            .buffer_ref = buffer_ref,
            .data = buffer_ref.data,
        };
    }

    pub fn initReference(packet: *const Packet) Packet {
        if (packet.buffer_ref) |buffer_ref| {
            _ = buffer_ref.ref_count.fetchAdd(1, .seq_cst);
        }

        return .{
            .pts = packet.pts,
            .dts = packet.dts,
            .duration = packet.duration,
            .buffer_ref = packet.buffer_ref,
            .data = packet.data,
        };
    }

    pub fn initFromData(data: []const u8) Packet {
        return .{ .pts = 0, .dts = 0, .data = data };
    }

    pub fn deinit(self: *Packet, allocator: Allocator) void {
        if (self.buffer_ref) |buffer_ref| {
            buffer_ref.deinit(allocator);
            allocator.destroy(buffer_ref);
        }
    }

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try writer.print(
            "PTS: {}, DTS: {}, Duration: {?}, Data Length: {}",
            .{
                self.pts,
                self.dts,
                self.duration,
                self.data.len,
            },
        );
    }

    test "init packet" {
        const allocator = std.heap.page_allocator;
        var packet = try Packet.init(allocator, 1024);
        defer packet.deinit(allocator);

        try std.testing.expect(packet.pts == 0);
        try std.testing.expect(packet.dts == 0);
        try std.testing.expect(packet.duration == null);

        try std.testing.expect(packet.data.len == 1024);
    }
};

test {
    std.testing.refAllDeclsRecursive(@This());
    _ = @import("h264.zig");
    _ = @import("bit_reader.zig");
}
