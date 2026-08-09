const std = @import("std");
const builtin = @import("builtin");

pub const default_alignment: std.mem.Alignment = .@"16";

fn Bucket(comptime alignment: std.mem.Alignment) type {
    return struct {
        block_size: usize,
        buffer: []align(alignment.toByteUnits()) u8,
        free_list: ?*Block = null,

        const Block = struct { next: ?*Block };

        fn init(allocator: std.mem.Allocator, block_size: usize, block_count: usize) std.mem.Allocator.Error!@This() {
            const total_size = block_size * block_count;
            const buffer = try allocator.alignedAlloc(u8, alignment, total_size);

            var self = @This(){
                .block_size = block_size,
                .buffer = buffer,
            };

            for (0..block_count) |idx| {
                const block_ptr = &buffer[idx * block_size];
                const block: *Block = @ptrCast(@alignCast(block_ptr));
                block.next = self.free_list;
                self.free_list = block;
            }

            return self;
        }

        fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            allocator.free(self.buffer);
        }

        fn acquire(self: *@This()) ?[]u8 {
            if (self.free_list) |block| {
                self.free_list = block.next;
                const buffer: [*]u8 = @ptrCast(@alignCast(block));
                return buffer[0..self.block_size];
            }

            return null;
        }

        fn release(self: *@This(), buf: []u8) void {
            const block: *Block = @ptrCast(@alignCast(buf.ptr));
            block.next = self.free_list;
            self.free_list = block;
        }
    };
}

pub const Config = struct {
    bucket_sizes: []const usize,
    bucket_counts: []const usize,
    thread_safe: bool = !builtin.single_threaded,
    alignment: std.mem.Alignment = default_alignment,
};

pub fn BufferPoolAllocator(comptime config: Config) type {
    const PoolBucket = Bucket(config.alignment);

    // Validate bucket sizes at compile time: each block must be large enough and
    // properly aligned to store the free-list Block node via @ptrCast/@alignCast.
    comptime {
        if (config.bucket_sizes.len != config.bucket_counts.len) {
            @compileError("bucket_sizes and bucket_counts must have the same length");
        }

        if (config.alignment.compare(.lt, .of(PoolBucket.Block))) {
            @compileError("config.alignment must be at least as large as the free-list block alignment");
        }

        for (config.bucket_sizes) |size| {
            if (size < @sizeOf(PoolBucket.Block)) {
                @compileError("each bucket_size must be >= @sizeOf(Block) bytes to store the free-list node");
            }
            if (size % config.alignment.toByteUnits() != 0) {
                @compileError("each bucket_size must be a multiple of config.alignment for correct pointer alignment");
            }
        }
    }

    return struct {
        const have_mutex = config.thread_safe;
        const Mutex = if (have_mutex) std.Io.Mutex else void;

        buckets: [config.bucket_sizes.len]PoolBucket,
        backing_allocator: std.mem.Allocator,
        mutex: Mutex = if (have_mutex) std.Io.Mutex.init else {},

        pub fn init(backing_allocator: std.mem.Allocator) !@This() {
            var self = @This(){
                .backing_allocator = backing_allocator,
                .buckets = undefined,
            };
            var initialized: usize = 0;
            errdefer {
                for (0..initialized) |idx| {
                    self.buckets[idx].deinit(backing_allocator);
                }
            }

            for (0..config.bucket_sizes.len) |idx| {
                self.buckets[idx] = try .init(backing_allocator, config.bucket_sizes[idx], config.bucket_counts[idx]);
                initialized += 1;
            }

            return self;
        }

        pub fn deinit(self: *@This()) void {
            for (0..config.bucket_sizes.len) |idx| {
                self.buckets[idx].deinit(self.backing_allocator);
            }
        }

        pub fn allocator(self: *@This()) std.mem.Allocator {
            return .{
                .ptr = self,
                .vtable = &.{
                    .alloc = alloc,
                    .free = free,
                    .remap = remap,
                    .resize = resize,
                },
            };
        }

        fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, _: usize) ?[*]u8 {
            if (alignment.compare(.gt, config.alignment)) return null;

            const self: *@This() = @ptrCast(@alignCast(context));
            for (&self.buckets) |*bucket| {
                if (len <= bucket.block_size) {
                    if (have_mutex) std.Io.Threaded.mutexLock(&self.mutex);
                    defer if (have_mutex) std.Io.Threaded.mutexUnlock(&self.mutex);

                    if (bucket.acquire()) |b| {
                        return b.ptr;
                    }
                }
            }
            return null;
        }

        fn free(context: *anyopaque, memory: []u8, _: std.mem.Alignment, _: usize) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            const ptr = @intFromPtr(memory.ptr);
            for (&self.buckets) |*bucket| {
                const start = @intFromPtr(bucket.buffer.ptr);
                if (ptr >= start and ptr < start + bucket.buffer.len) {
                    if (have_mutex) std.Io.Threaded.mutexLock(&self.mutex);
                    defer if (have_mutex) std.Io.Threaded.mutexUnlock(&self.mutex);

                    bucket.release(memory);
                    return;
                }
            }
        }

        fn remap(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
            _ = context;
            _ = memory;
            _ = alignment;
            _ = new_len;
            _ = ret_addr;
            return null;
        }

        fn resize(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
            _ = context;
            _ = memory;
            _ = alignment;
            _ = new_len;
            _ = ret_addr;
            return false;
        }
    };
}

const testing = std.testing;

test "Bucket: acquire exhausts pool and returns null" {
    var bucket = try Bucket(default_alignment).init(testing.allocator, 64, 2);
    defer bucket.deinit(testing.allocator);

    const b1 = bucket.acquire();
    const b2 = bucket.acquire();
    const b3 = bucket.acquire();

    try testing.expect(b1 != null);
    try testing.expect(b2 != null);
    try testing.expectEqual(@as(?[]u8, null), b3);

    bucket.release(b1.?);
    bucket.release(b2.?);
}

test "Bucket: released block is reacquired" {
    var bucket = try Bucket(default_alignment).init(testing.allocator, 64, 1);
    defer bucket.deinit(testing.allocator);

    const b1 = bucket.acquire();
    try testing.expect(b1 != null);
    const ptr = b1.?.ptr;
    bucket.release(b1.?);

    const b2 = bucket.acquire();
    try testing.expect(b2 != null);
    try testing.expectEqual(ptr, b2.?.ptr);
    bucket.release(b2.?);
}

test "BufferPoolAllocator: init and deinit" {
    const Pool = BufferPoolAllocator(.{
        .bucket_sizes = &.{ 64, 256, 1024 },
        .bucket_counts = &.{ 4, 4, 4 },
    });
    var pool = try Pool.init(testing.allocator);
    pool.deinit();
}

test "BufferPoolAllocator: alloc returns slice of requested length" {
    const Pool = BufferPoolAllocator(.{
        .bucket_sizes = &.{ 64, 256 },
        .bucket_counts = &.{ 4, 4 },
    });
    var pool = try Pool.init(testing.allocator);
    defer pool.deinit();
    const ally = pool.allocator();

    const buf = try ally.alloc(u8, 32);
    try testing.expectEqual(@as(usize, 32), buf.len);
    @memset(buf, 0xAB); // verify memory is writable
    ally.free(buf);
}

test "BufferPoolAllocator: pool exhaustion returns OutOfMemory" {
    const Pool = BufferPoolAllocator(.{
        .bucket_sizes = &.{64},
        .bucket_counts = &.{2},
    });
    var pool = try Pool.init(testing.allocator);
    defer pool.deinit();
    const ally = pool.allocator();

    const buf1 = try ally.alloc(u8, 64);
    const buf2 = try ally.alloc(u8, 64);
    try testing.expectError(error.OutOfMemory, ally.alloc(u8, 64));

    ally.free(buf1);
    ally.free(buf2);
}

test "BufferPoolAllocator: freed block is reused" {
    const Pool = BufferPoolAllocator(.{
        .bucket_sizes = &.{64},
        .bucket_counts = &.{1},
    });
    var pool = try Pool.init(testing.allocator);
    defer pool.deinit();
    const ally = pool.allocator();

    const buf1 = try ally.alloc(u8, 64);
    const ptr1 = buf1.ptr;
    ally.free(buf1);

    const buf2 = try ally.alloc(u8, 64);
    try testing.expectEqual(ptr1, buf2.ptr);
    ally.free(buf2);
}

test "BufferPoolAllocator: falls through to larger bucket when smaller is exhausted" {
    const Pool = BufferPoolAllocator(.{
        .bucket_sizes = &.{ 64, 256 },
        .bucket_counts = &.{ 1, 4 },
    });
    var pool = try Pool.init(testing.allocator);
    defer pool.deinit();
    const ally = pool.allocator();

    const buf1 = try ally.alloc(u8, 32); // takes the only 64-byte block
    const buf2 = try ally.alloc(u8, 32); // falls through to 256-byte bucket
    try testing.expectEqual(@as(usize, 32), buf2.len);

    ally.free(buf1);
    ally.free(buf2);
}

test "BufferPoolAllocator: request larger than all buckets fails" {
    const Pool = BufferPoolAllocator(.{
        .bucket_sizes = &.{64},
        .bucket_counts = &.{4},
    });
    var pool = try Pool.init(testing.allocator);
    defer pool.deinit();
    const ally = pool.allocator();

    try testing.expectError(error.OutOfMemory, ally.alloc(u8, 128));
}

test "BufferPoolAllocator: blocks are aligned to config.alignment" {
    const Pool = BufferPoolAllocator(.{
        .bucket_sizes = &.{ 32, 64 },
        .bucket_counts = &.{ 4, 4 },
        .alignment = .@"32",
    });
    var pool = try Pool.init(testing.allocator);
    defer pool.deinit();
    const ally = pool.allocator();

    const buf1 = try ally.alignedAlloc(u8, .@"32", 16);
    const buf2 = try ally.alignedAlloc(u8, .@"16", 40);
    try testing.expect(std.mem.isAligned(@intFromPtr(buf1.ptr), 32));
    try testing.expect(std.mem.isAligned(@intFromPtr(buf2.ptr), 32));

    ally.free(buf1);
    ally.free(buf2);
}

test "BufferPoolAllocator: rejects requests exceeding config.alignment" {
    const Pool = BufferPoolAllocator(.{
        .bucket_sizes = &.{64},
        .bucket_counts = &.{4},
        .alignment = .@"16",
    });
    var pool = try Pool.init(testing.allocator);
    defer pool.deinit();
    const ally = pool.allocator();

    try testing.expectError(error.OutOfMemory, ally.alignedAlloc(u8, .@"32", 16));
}

test "BufferPoolAllocator: freed buffer_ref slot is reused" {
    const Pool = BufferPoolAllocator(.{
        .bucket_sizes = &.{64},
        .bucket_counts = &.{1},
    });
    var pool = try Pool.init(testing.allocator);
    defer pool.deinit();
    const ally = pool.allocator();

    const buf1 = try ally.alloc(u8, 62);
    const ptr1 = buf1.ptr;
    ally.free(buf1);

    const buf2 = try ally.alloc(u8, 63);
    try testing.expectEqual(ptr1, buf2.ptr);
    ally.free(buf2);
}
