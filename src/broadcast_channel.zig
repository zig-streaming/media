//! A broadcast channel or Fan-out channel is a channel that allows multiple receivers to receive the same messages sent
//! by a single sender.
//!
//! This is useful for media applications where a single publisher wants to send the same media stream to multiple subscribers.

const std = @import("std");

const Io = std.Io;

pub fn BroadcastChannel(comptime T: type, comptime size: u32) type {
    std.debug.assert(std.math.isPowerOfTwo(size));

    return struct {
        slots: [size]Slot,
        seq: std.atomic.Value(u32),
        /// Number of receivers currently parked in `futexWait`.
        waiters: std.atomic.Value(u32),
        deinit_ctx: ?*anyopaque,
        deinit_fn: DeinitFn,

        const Self = @This();

        /// Produces the receiver's owned copy of a stored value (e.g. bump a refcount, or deep-copy).
        pub const CloneFn = *const fn (ctx: ?*anyopaque, value: *const T) T;
        /// Releases a value that is being overwritten or dropped by the channel.
        pub const DeinitFn = *const fn (ctx: ?*anyopaque, value: *T) void;

        pub const Receiver = struct {
            next: u32,
            clone_ctx: ?*anyopaque,
            clone_fn: CloneFn,
        };

        const Slot = struct {
            value: T,
            lock: Io.RwLock,
        };

        pub const Options = struct {
            /// Value used to fill unused ring slots. `deinit` must be a safe no-op on it.
            empty: T,
            deinit_ctx: ?*anyopaque = null,
            deinit: DeinitFn,
        };

        pub fn init(options: Options) Self {
            return Self{
                .slots = @splat(.{ .value = options.empty, .lock = .init }),
                .seq = .init(0),
                .waiters = .init(0),
                .deinit_ctx = options.deinit_ctx,
                .deinit_fn = options.deinit,
            };
        }

        pub fn send(self: *Self, io: Io, value: T) void {
            const index = self.seq.raw & (size - 1);
            self.slots[index].lock.lockUncancelable(io);
            self.deinit_fn(self.deinit_ctx, &self.slots[index].value);
            self.slots[index].value = value;
            self.seq.store(self.seq.raw +% 1, .seq_cst);
            self.slots[index].lock.unlock(io);

            if (self.waiters.load(.seq_cst) != 0)
                io.futexWake(u32, &self.seq.raw, std.math.maxInt(u32));
        }

        pub fn subscribe(self: *Self, clone: CloneFn, clone_ctx: ?*anyopaque) Receiver {
            return Receiver{
                .next = self.seq.load(.seq_cst),
                .clone_ctx = clone_ctx,
                .clone_fn = clone,
            };
        }

        pub fn receive(self: *Self, io: Io, receiver: *Receiver) !T {
            while (self.seq.load(.acquire) == receiver.next) {
                _ = self.waiters.fetchAdd(1, .seq_cst);
                defer _ = self.waiters.fetchSub(1, .seq_cst);

                if (self.seq.load(.seq_cst) != receiver.next) continue;
                try io.futexWait(u32, &self.seq.raw, receiver.next);
            }

            const index = receiver.next & (size - 1);

            try self.slots[index].lock.lockShared(io);
            defer self.slots[index].lock.unlockShared(io);

            // Slot still holds `seq` iff `1 <= published - seq <= ring_size`.
            const distance = self.seq.load(.acquire) -% receiver.next;
            if (distance == 0 or distance > size) {
                receiver.next = self.seq.load(.acquire) -% size;
                return error.Lagged;
            }

            const value = receiver.clone_fn(receiver.clone_ctx, &self.slots[index].value);
            receiver.next +%= 1;
            return value;
        }

        pub fn deinit(self: *Self) void {
            for (&self.slots) |*slot| {
                self.deinit_fn(self.deinit_ctx, &slot.value);
            }
        }
    };
}

const testing = std.testing;
const Packet = @import("root.zig").Packet;

const PacketChannel = BroadcastChannel(Packet, 4);

var packet_alloc = testing.allocator;

fn packetClone(_: ?*anyopaque, value: *const Packet) Packet {
    value.retain();
    return value.*;
}

fn packetDeinit(ctx: ?*anyopaque, value: *Packet) void {
    const alloc: *std.mem.Allocator = @ptrCast(@alignCast(ctx.?));
    value.deinit(alloc.*);
}

fn initChannel() PacketChannel {
    return PacketChannel.init(.{
        .empty = .{ .data = &.{} },
        .deinit_ctx = &packet_alloc,
        .deinit = packetDeinit,
    });
}

fn dupePacket(bytes: []const u8) Packet {
    return Packet.dupe(testing.allocator, bytes) catch @panic("oom");
}

test "init: empty channel with zero sequence" {
    var channel = initChannel();
    defer channel.deinit();

    try testing.expectEqual(@as(u32, 0), channel.seq.load(.seq_cst));
    for (channel.slots) |slot| {
        try testing.expectEqual(@as(usize, 0), slot.value.data.len);
    }
}

test "subscribe: receiver starts at current sequence" {
    var channel = initChannel();
    defer channel.deinit();

    try testing.expectEqual(@as(u32, 0), channel.subscribe(packetClone, null).next);

    channel.send(testing.io, dupePacket("a"));
    channel.send(testing.io, dupePacket("b"));

    try testing.expectEqual(@as(u32, 2), channel.subscribe(packetClone, null).next);
}

test "send/receive: single receiver observes data and metadata" {
    var channel = initChannel();
    defer channel.deinit();

    var receiver = channel.subscribe(packetClone, null);

    var sent = dupePacket("frame");
    sent.pts = 42;
    sent.dts = 40;
    sent.duration = 33;
    sent.stream_id = 7;
    channel.send(testing.io, sent);

    var received = try channel.receive(testing.io, &receiver);
    defer received.deinit(testing.allocator);

    try testing.expectEqualSlices(u8, "frame", received.data);
    try testing.expectEqual(@as(i64, 42), received.pts);
    try testing.expectEqual(@as(i64, 40), received.dts);
    try testing.expectEqual(@as(?u64, 33), received.duration);
    try testing.expectEqual(@as(u32, 7), received.stream_id);
    try testing.expectEqual(@as(u32, 1), receiver.next);
}

test "receive: clone retains a reference independent of the channel" {
    var channel = initChannel();
    defer channel.deinit();

    var receiver = channel.subscribe(packetClone, null);
    channel.send(testing.io, dupePacket("data"));

    var received = try channel.receive(testing.io, &receiver);
    try testing.expectEqual(2, received.buffer_ref.?.ref_count.load(.seq_cst));

    received.deinit(testing.allocator);
    try testing.expectEqual(1, channel.slots[0].value.buffer_ref.?.ref_count.load(.seq_cst));
}

test "receive: multiple receivers observe the same messages" {
    var channel = initChannel();
    defer channel.deinit();

    var r1 = channel.subscribe(packetClone, null);
    var r2 = channel.subscribe(packetClone, null);

    channel.send(testing.io, dupePacket("x"));

    var p1 = try channel.receive(testing.io, &r1);
    defer p1.deinit(testing.allocator);
    var p2 = try channel.receive(testing.io, &r2);
    defer p2.deinit(testing.allocator);

    try testing.expectEqualSlices(u8, "x", p1.data);
    try testing.expectEqualSlices(u8, "x", p2.data);
    try testing.expectEqual(p1.data.ptr, p2.data.ptr);
}

test "receive: consumes messages in order across the ring" {
    var channel = initChannel();
    defer channel.deinit();

    var receiver = channel.subscribe(packetClone, null);

    const messages = [_][]const u8{ "0", "1", "2", "3", "4", "5" };
    for (messages) |msg| {
        channel.send(testing.io, dupePacket(msg));
        var got = try channel.receive(testing.io, &receiver);
        defer got.deinit(testing.allocator);
        try testing.expectEqualSlices(u8, msg, got.data);
    }
}

test "receive: slow receiver lags when overwritten, then recovers" {
    var channel = initChannel();
    defer channel.deinit();

    var receiver = channel.subscribe(packetClone, null);

    // Overrun the ring: 6 sends into 4 slots overwrites the two oldest.
    for (0..6) |i| {
        var buf: [1]u8 = .{@intCast('0' + i)};
        channel.send(testing.io, dupePacket(&buf));
    }

    try testing.expectError(error.Lagged, channel.receive(testing.io, &receiver));

    // After lagging, the receiver is repositioned `size` behind the head.
    try testing.expectEqual(channel.seq.load(.seq_cst) -% 4, receiver.next);

    var got = try channel.receive(testing.io, &receiver);
    defer got.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, "2", got.data);
}

test "receive: blocks until a message is sent from another thread" {
    var channel = initChannel();
    defer channel.deinit();

    var receiver = channel.subscribe(packetClone, null);

    const consumer = struct {
        fn run(io: Io, ch: *PacketChannel, rx: *PacketChannel.Receiver) []const u8 {
            var p = ch.receive(io, rx) catch @panic("receive failed");
            defer p.deinit(testing.allocator);
            return testing.allocator.dupe(u8, p.data) catch @panic("oom");
        }
    }.run;

    var future = try testing.io.concurrent(consumer, .{ testing.io, &channel, &receiver });

    channel.send(testing.io, dupePacket("late"));

    const data = future.await(testing.io);
    defer testing.allocator.free(data);
    try testing.expectEqualSlices(u8, "late", data);
}
