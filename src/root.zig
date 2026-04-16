//! By convention, root.zig is the root source file when making a library.
pub const h264 = @import("h264.zig");
pub const io = @import("io.zig");
pub const BufferPoolAllocator = @import("buffer_pool_allocator.zig").BufferPoolAllocator;

const std = @import("std");
const Allocator = std.mem.Allocator;

const BufferRefAllocator = std.heap.MemoryPool(BufferRef);
pub var buffer_ref_allocator = BufferRefAllocator.init(std.heap.page_allocator);

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

    const empty = BufferRef{
        .data = &.{},
        .ref_count = .init(1),
    };

    fn init(buffer_ref: *BufferRef, allocator: Allocator, size: usize) !void {
        buffer_ref.data = try allocator.alloc(u8, size);
    }

    fn deinit(buffer_ref: *BufferRef, allocator: Allocator) bool {
        const old_value = buffer_ref.ref_count.fetchSub(1, .seq_cst);
        if (old_value == 1) {
            allocator.free(buffer_ref.data);
            return true;
        }

        return false;
    }
};

/// Represents a media packet, which may contain video frames, audio samples, or other media data.
pub const Packet = struct {
    /// Presentation Timestamp (PTS) indicates when the packet should be presented to the user.
    pts: i64 = 0,
    /// Decoding Timestamp (DTS) indicates when the packet should be decoded.
    dts: i64 = 0,
    /// Duration of the packet in time units (e.g., milliseconds). This is optional and may not be set for all packets.
    duration: ?u64 = null,
    /// Read-only view of the payload bytes, regardless of ownership.
    ///
    /// If `buffer_ref` is set, this slice points to the data owned by `buffer_ref`. Otherwise, it points to external data that this packet does not own.
    data: []const u8,
    /// Private. Non-null iff this packet owns its data via refcounted allocation.
    buffer_ref: ?*BufferRef = null,

    /// Allocates an uninitialised owned buffer of `size` bytes.
    /// Use `mutableData()` to fill the buffer before sharing the packet.
    pub fn alloc(allocator: Allocator, size: usize) !Packet {
        const buffer_ref = try buffer_ref_allocator.create();

        buffer_ref.* = .{
            .data = try allocator.alloc(u8, size),
            .ref_count = .init(1),
        };

        return .{
            .buffer_ref = buffer_ref,
            .data = buffer_ref.data,
        };
    }

    /// Allocates an owned buffer and copies `src` into it (analogous to `std.mem.Allocator.dupe`).
    pub fn dupe(allocator: Allocator, src: []const u8) !Packet {
        var packet = try alloc(allocator, src.len);
        @memcpy(packet.mutableData().?, src);
        return packet;
    }

    /// Decrements the refcount and frees the underlying buffer when it reaches zero.
    pub fn deinit(self: *Packet, allocator: Allocator) void {
        if (self.buffer_ref) |buffer_ref| if (buffer_ref.deinit(allocator)) {
            buffer_ref_allocator.destroy(buffer_ref);
        };
    }

    /// Increments the refcount, signalling that this packet is now an additional live owner of the buffer.
    /// Call this after copying the packet struct to declare the copy as a co-owner.
    /// For non-owning packets (created with `fromSlice`) this is a no-op.
    pub fn retain(self: *const Packet) void {
        if (self.buffer_ref) |buffer_ref| {
            _ = buffer_ref.ref_count.fetchAdd(1, .seq_cst);
        }
    }

    /// Borrows `src` without copying or allocating; the caller is responsible for keeping `src` alive.
    pub fn fromSlice(src: []const u8) Packet {
        return .{ .data = src };
    }

    /// Returns a mutable slice into the owned buffer, or null for non-owning packets.
    /// Only write before sharing with `retain`: writes are visible to all co-owners once the buffer is shared.
    pub fn mutableData(self: *Packet) ?[]u8 {
        const br = self.buffer_ref orelse return null;
        return br.data;
    }

    /// Returns true if this packet holds a reference-counted allocation.
    pub fn ownsData(self: *const Packet) bool {
        return self.buffer_ref != null;
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
};

const testing = std.testing;

test "Codec.toString returns correct strings" {
    const cases = .{
        .{ Codec.h264, "H.264" },
        .{ Codec.h265, "H.265" },
        .{ Codec.aac, "AAC" },
        .{ Codec.unknown, "Unknown" },
    };
    inline for (cases) |c| {
        const codec: Codec = c[0];
        try testing.expectEqualStrings(c[1], codec.toString());
    }
}

test "Packet.fromSlice: non-owning packet" {
    const data = "hello world";
    const packet = Packet.fromSlice(data);
    try testing.expectEqual(@as(i64, 0), packet.pts);
    try testing.expectEqual(@as(i64, 0), packet.dts);
    try testing.expectEqual(@as(?u64, null), packet.duration);
    try testing.expect(!packet.ownsData());
    try testing.expectEqualSlices(u8, data, packet.data);
}

test "Packet.alloc: allocates owned buffer with correct initial state" {
    var packet = try Packet.alloc(testing.allocator, 128);
    defer packet.deinit(testing.allocator);

    try testing.expectEqual(@as(i64, 0), packet.pts);
    try testing.expectEqual(@as(i64, 0), packet.dts);
    try testing.expect(packet.ownsData());
    try testing.expectEqual(@as(usize, 128), packet.data.len);
    // mutableData must alias the data slice
    try testing.expectEqual(packet.mutableData().?.ptr, packet.data.ptr);
    try testing.expectEqual(@as(u32, 1), packet.buffer_ref.?.ref_count.load(.seq_cst));
}

test "Packet.deinit: no-op for non-owning packet" {
    const data = "static data";
    var packet = Packet.fromSlice(data);
    packet.deinit(testing.allocator); // must not crash or cause use-after-free
}

test "Packet.retain: increments ref count and shares data pointer" {
    var p1 = try Packet.alloc(testing.allocator, 64);
    p1.pts = 1000;
    p1.dts = 900;
    p1.duration = 33;

    var p2 = p1; // struct copy — both now point at the same buffer_ref
    p2.retain(); // declare p2 as a co-owner

    try testing.expectEqual(@as(u32, 2), p1.buffer_ref.?.ref_count.load(.seq_cst));
    // both packets share the same buffer_ref and raw data pointer
    try testing.expectEqual(p1.buffer_ref, p2.buffer_ref);
    try testing.expectEqual(p1.data.ptr, p2.data.ptr);
    // timestamp fields are identical (copied by struct copy)
    try testing.expectEqual(p1.pts, p2.pts);
    try testing.expectEqual(p1.dts, p2.dts);
    try testing.expectEqual(p1.duration, p2.duration);

    // first deinit: ref count drops to 1, data must NOT be freed yet
    p2.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 1), p1.buffer_ref.?.ref_count.load(.seq_cst));

    // second deinit: ref count hits 0, data freed (testing.allocator verifies no leak)
    p1.deinit(testing.allocator);
}

test "Packet.retain: non-owning packet retain is a no-op" {
    const data = "static";
    const p1 = Packet.fromSlice(data);
    var p2 = p1;
    p2.retain(); // no-op — no buffer_ref to increment
    defer p2.deinit(testing.allocator);
    try testing.expect(!p2.ownsData());
    try testing.expectEqualSlices(u8, data, p2.data);
}

test "Packet.mutableData: returns null for non-owning packet" {
    var packet = Packet.fromSlice("hello");
    try testing.expect(packet.mutableData() == null);
}

test "Packet.mutableData: writes are visible through data slice" {
    var packet = try Packet.alloc(testing.allocator, 5);
    defer packet.deinit(testing.allocator);
    @memcpy(packet.mutableData().?, "hello");
    try testing.expectEqualSlices(u8, "hello", packet.data);
}

test {
    std.testing.refAllDeclsRecursive(@This());
    _ = @import("h264.zig");
    _ = @import("io.zig");
    _ = @import("buffer_pool_allocator.zig");
}
