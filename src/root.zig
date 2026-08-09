pub const codecs = @import("codecs.zig");
pub const io = @import("io.zig");
pub const BufferPoolAllocator = @import("buffer_pool_allocator.zig").BufferPoolAllocator;
pub const BroadcastChannel = @import("broadcast_channel.zig").BroadcastChannel;

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Rational = struct {
    num: u64,
    den: u64,

    pub fn of(num: u64, den: u64) Rational {
        return .{ .num = num, .den = den };
    }

    pub fn ofDen(den: u64) Rational {
        return .{ .num = 1, .den = den };
    }
};

/// Enumeration of supported media codecs. This is not exhaustive and can be extended as needed.
pub const Codec = enum {
    unknown,
    // Video
    h264,
    h265,
    vp8,
    vp9,
    av1,
    // Audio
    aac,
    opus,
};

/// Represents a media packet, which may contain video frames, audio samples, or other media data.
pub const Packet = struct {
    const BufferRef = struct {
        ref_count: std.atomic.Value(u32),
        capacity: usize,
        alignment: std.mem.Alignment,
    };

    /// Presentation Timestamp (PTS) indicates when the packet should be presented to the user.
    pts: i64 = 0,
    /// Decoding Timestamp (DTS) indicates when the packet should be decoded.
    dts: i64 = 0,
    /// Duration of the packet in time units (e.g., milliseconds). This is optional and may not be set for all packets.
    duration: ?u64 = null,
    /// The stream identifier for this packet.
    stream_id: u32 = 0,
    /// Read-only view of the payload bytes, regardless of ownership.
    ///
    /// If `buffer_ref` is set, this slice points to the data owned by `buffer_ref`. Otherwise, it points to external data that this packet does not own.
    data: []const u8,
    /// Optional flags for the packet.
    flags: Flags = .{},
    /// Private. Non-null iff this packet owns its data via refcounted allocation.
    buffer_ref: ?*BufferRef = null,

    /// Struct describing packet flags.
    pub const Flags = packed struct(u16) {
        /// Indicates that this packet contains a keyframe (a self-contained frame that can be decoded without reference to other frames).
        keyframe: bool = false,
        /// Indicates that the packet's data is corrupted or invalid. The decoder should attempt to decode it but may produce artifacts or errors.
        corrupted: bool = false,
        _pad: u14 = 0,
    };

    /// Allocates an uninitialised owned buffer of `size` bytes.
    /// Use `mutableData()` to fill the buffer before sharing the packet.
    pub fn alloc(allocator: Allocator, size: usize) Allocator.Error!Packet {
        return try alignedAlloc(allocator, size, .of(BufferRef));
    }

    /// Allocates an uninitialised owned buffer of `size` bytes with the specified `alignment`.
    pub fn alignedAlloc(allocator: Allocator, size: usize, comptime alignment: std.mem.Alignment) Allocator.Error!Packet {
        const capacity = sizeOfControlBuf(alignment) + size;
        const buffer = try allocator.alignedAlloc(u8, alignment, capacity);

        const control_ref: *BufferRef = @ptrCast(@alignCast(buffer.ptr));
        control_ref.* = .{
            .ref_count = .init(1),
            .capacity = size,
            .alignment = alignment,
        };

        return .{
            .buffer_ref = control_ref,
            .data = buffer[sizeOfControlBuf(alignment)..],
        };
    }

    /// Allocates an owned buffer and copies `src` into it (analogous to `std.mem.Allocator.dupe`).
    pub fn dupe(allocator: Allocator, src: []const u8) Allocator.Error!Packet {
        var packet = try alloc(allocator, src.len);
        @memcpy(packet.mutableData().?, src);
        return packet;
    }

    /// Decrements the refcount and frees the underlying buffer when it reaches zero.
    pub fn deinit(self: *Packet, allocator: Allocator) void {
        if (self.buffer_ref) |buffer_ref| {
            if (buffer_ref.ref_count.fetchSub(1, .acq_rel) == 1) {
                const alignment = buffer_ref.alignment;
                const bytes: [*]u8 = @ptrCast(buffer_ref);
                const slice = bytes[0 .. buffer_ref.capacity + sizeOfControlBuf(alignment)];
                allocator.rawFree(slice, alignment, @returnAddress());

                self.buffer_ref = null;
                self.data = &.{};
            }
        }
    }

    /// Increments the refcount, signalling that this packet is now an additional live owner of the buffer.
    /// Call this after copying the packet struct to declare the copy as a co-owner.
    /// For non-owning packets (created with `fromSlice`) this is a no-op.
    pub fn retain(self: *const Packet) void {
        if (self.buffer_ref) |buffer_ref| {
            _ = buffer_ref.ref_count.fetchAdd(1, .monotonic);
        }
    }

    /// Borrows `src` without copying or allocating; the caller is responsible for keeping `src` alive.
    pub fn fromSlice(src: []const u8) Packet {
        return .{ .data = src };
    }

    /// Returns a mutable slice into the owned buffer, or null for non-owning packets.
    /// Only write before sharing with `retain`: writes are visible to all co-owners once the buffer is shared.
    pub fn mutableData(self: *Packet) ?[]u8 {
        return if (self.buffer_ref != null) @constCast(self.data) else null;
    }

    /// Returns true if this packet holds a reference-counted allocation.
    pub fn ownsData(self: *const Packet) bool {
        return self.buffer_ref != null;
    }

    pub fn scaleTimestamps(self: *Packet, src_time_base: Rational, dst_time_base: Rational) void {
        self.pts = scaleTimestamp(i64, self.pts, src_time_base, dst_time_base);
        self.dts = scaleTimestamp(i64, self.dts, src_time_base, dst_time_base);
        if (self.duration) |dur| {
            self.duration = scaleTimestamp(u64, dur, src_time_base, dst_time_base);
        }
    }

    fn scaleTimestamp(T: type, ts: T, src_time_base: Rational, dst_time_base: Rational) T {
        const scaled = @divTrunc(@as(i128, ts) * src_time_base.num * dst_time_base.den, @as(i128, src_time_base.den) * dst_time_base.num);
        return @intCast(scaled);
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

    fn sizeOfControlBuf(alignment: std.mem.Alignment) usize {
        return std.mem.alignForward(usize, @sizeOf(BufferRef), alignment.toByteUnits());
    }
};

pub const MediaType = enum {
    video,
    audio,
    subtitle,
    data,
    unknown,
};

pub const StreamConfig = union(MediaType) {
    video: VideoConfig,
    audio: AudioConfig,
    subtitle: void,
    data: void,
    unknown: void,
};

pub const VideoConfig = struct {
    width: u32,
    height: u32,
};

pub const AudioConfig = struct {
    sample_rate: u32,
    channels: u16,
};

/// Represents a media stream.
pub const Stream = struct {
    /// Unique stream identifier.
    id: u32,
    /// This is the fundamental unit of time (in seconds) in terms of which frame timestamps are represented.
    time_base: Rational,
    /// The stream's codec.
    codec: Codec,
    /// Stream specific configuration.
    config: StreamConfig,
    /// Total duration of the stream in `time_base` units, or 0 if unknown/unspecified.
    duration: u64 = 0,
    /// Total number of frames in the stream, or 0 if unknown/unspecified.
    nb_frames: u64 = 0,
    /// Codec initialization data (e.g., SPS/PPS for H.264) or other stream-specific metadata.
    extra_data: []u8 = &.{},
    /// Private data used internally.
    priv_data: []u8 = &.{},

    pub inline fn mediaType(self: *const Stream) MediaType {
        return @as(MediaType, self.config);
    }

    pub fn deinit(self: *Stream, allocator: Allocator) void {
        allocator.free(self.extra_data);
        allocator.free(self.priv_data);
    }
};

const testing = std.testing;

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

    try testing.expectEqual(0, packet.pts);
    try testing.expectEqual(0, packet.dts);
    try testing.expect(packet.ownsData());
    try testing.expectEqual(128, packet.data.len);
    try testing.expectEqual(packet.mutableData().?.ptr, packet.data.ptr);
    try testing.expectEqual(1, packet.buffer_ref.?.ref_count.load(.seq_cst));
}

test "Packet.alignedAlloc: allocates buffer aligned to the requested alignment" {
    var packet = try Packet.alignedAlloc(testing.allocator, 100, .fromByteUnits(64));
    defer packet.deinit(testing.allocator);

    try testing.expect(packet.ownsData());
    try testing.expectEqual(100, packet.data.len);
    try testing.expect(std.mem.isAligned(@intFromPtr(packet.data.ptr), 64));
    try testing.expectEqual(1, packet.buffer_ref.?.ref_count.load(.seq_cst));
}

test "Packet.alignedAlloc: writes through mutableData are visible" {
    var packet = try Packet.alignedAlloc(testing.allocator, 5, .fromByteUnits(32));
    defer packet.deinit(testing.allocator);
    @memcpy(packet.mutableData().?, "hello");
    try testing.expectEqualSlices(u8, "hello", packet.data);
}

test "Packet.deinit: no-op for non-owning packet" {
    const data = "static data";
    var packet = Packet.fromSlice(data);
    packet.deinit(testing.allocator);
}

test "Packet.retain: increments ref count and shares data pointer" {
    var p1 = try Packet.alloc(testing.allocator, 64);
    p1.pts = 1000;
    p1.dts = 900;
    p1.duration = 33;

    var p2 = p1;
    p2.retain();

    try testing.expectEqual(@as(u32, 2), p1.buffer_ref.?.ref_count.load(.seq_cst));
    try testing.expectEqual(p1.buffer_ref, p2.buffer_ref);
    try testing.expectEqual(p1.data.ptr, p2.data.ptr);
    try testing.expectEqual(p1.pts, p2.pts);
    try testing.expectEqual(p1.dts, p2.dts);
    try testing.expectEqual(p1.duration, p2.duration);

    p2.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 1), p1.buffer_ref.?.ref_count.load(.seq_cst));

    p1.deinit(testing.allocator);
}

test "Packet.retain: non-owning packet retain is a no-op" {
    const data = "static";
    const p1 = Packet.fromSlice(data);
    var p2 = p1;
    p2.retain();
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

test "Packet.scaleTimestamps: rescales a 90kHz PTS clock to milliseconds" {
    var packet = Packet.fromSlice("data");
    packet.pts = 90000;
    packet.dts = 88200;
    packet.duration = 3600;

    packet.scaleTimestamps(.ofDen(90000), .ofDen(1000));

    try testing.expectEqual(1000, packet.pts);
    try testing.expectEqual(980, packet.dts);
    try testing.expectEqual(40, packet.duration.?);
}

test "Packet.scaleTimestamps: zero pts/dts and null duration are left untouched" {
    var packet = Packet.fromSlice("data");
    packet.pts = 0;
    packet.dts = 0;
    packet.duration = null;

    packet.scaleTimestamps(.ofDen(48000), .ofDen(1000));

    try testing.expectEqual(0, packet.pts);
    try testing.expectEqual(0, packet.dts);
    try testing.expectEqual(null, packet.duration);
}

test "Packet.scaleTimestamps: round-trip between a 90kHz clock and milliseconds preserves values" {
    var packet = Packet.fromSlice("data");
    packet.pts = 90000;
    packet.dts = 88200;
    packet.duration = 3600;

    const pts_clock: Rational = .ofDen(90000);
    const ms_clock: Rational = .of(1, 1000);

    packet.scaleTimestamps(pts_clock, ms_clock);
    packet.scaleTimestamps(ms_clock, pts_clock);

    try testing.expectEqual(90000, packet.pts);
    try testing.expectEqual(88200, packet.dts);
    try testing.expectEqual(3600, packet.duration.?);
}

test {
    std.testing.refAllDecls(@This());
    _ = @import("codecs.zig");
    _ = @import("broadcast_channel.zig");
}
