const std = @import("std");
const builtin = @import("builtin");

const BufferRefAllocator = @import("root.zig").BufferRefAllocator;
const buffer_ref_size = @import("root.zig").buffer_ref_size;

const Bucket = struct {
    block_size: usize,
    buffer: []u8,
    free_list: ?*Block = null,

    const Block = struct { next: ?*Block };

    fn init(allocator: std.mem.Allocator, block_size: usize, block_count: usize) !Bucket {
        const total_size = block_size * block_count;
        const buffer = try allocator.alloc(u8, total_size);

        var self = Bucket{
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

    fn deinit(self: *Bucket, allocator: std.mem.Allocator) void {
        allocator.free(self.buffer);
    }

    fn acquire(self: *Bucket) ?[]u8 {
        if (self.free_list) |block| {
            self.free_list = block.next;
            const buffer: [*]u8 = @ptrCast(@alignCast(block));
            return buffer[0..self.block_size];
        }

        return null;
    }

    fn release(self: *Bucket, buf: []u8) void {
        const block_ptr = &buf[0];
        const block: *Block = @ptrCast(@alignCast(block_ptr));
        block.next = self.free_list;
        self.free_list = block;
    }
};

pub const Config = struct {
    bucket_sizes: []const usize,
    bucket_counts: []const usize,
    thread_safe: bool = !builtin.single_threaded,
};

pub fn BufferPoolAllocator(comptime config: Config) type {
    // Validate bucket sizes at compile time: each block must be large enough and
    // properly aligned to store the free-list Block node via @ptrCast/@alignCast.
    comptime {
        if (config.bucket_sizes.len != config.bucket_counts.len) {
            @compileError("bucket_sizes and bucket_counts must have the same length");
        }

        for (config.bucket_sizes) |size| {
            if (size < @sizeOf(Bucket.Block)) {
                @compileError("each bucket_size must be >= @sizeOf(Bucket.Block) bytes to store the free-list node");
            }
            if (size % @alignOf(Bucket.Block) != 0) {
                @compileError("each bucket_size must be a multiple of @alignOf(Bucket.Block) for correct pointer alignment");
            }
        }
    }

    return struct {
        const have_mutex = config.thread_safe;
        const mutex_init = if (have_mutex) std.Thread.Mutex{} else DummyMutex{};

        const DummyMutex = struct {
            inline fn lock(_: DummyMutex) void {}
            inline fn unlock(_: DummyMutex) void {}
        };

        buckets: [config.bucket_sizes.len]Bucket,
        backing_allocator: std.mem.Allocator,
        buffer_ref_allocator: BufferRefAllocator,
        mutex: @TypeOf(mutex_init) = mutex_init,

        pub fn init(backing_allocator: std.mem.Allocator) !@This() {
            var self = @This(){
                .backing_allocator = backing_allocator,
                .buckets = undefined,
                .buffer_ref_allocator = BufferRefAllocator.init(backing_allocator),
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
            self.buffer_ref_allocator.deinit();
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

        fn alloc(context: *anyopaque, len: usize, _: std.mem.Alignment, _: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (len == buffer_ref_size) {
                if (have_mutex) std.Thread.Mutex.lock(&self.mutex);
                defer if (have_mutex) std.Thread.Mutex.unlock(&self.mutex);
                const buf_ref = self.buffer_ref_allocator.create() catch {
                    return null;
                };
                return @ptrCast(@alignCast(buf_ref));
            }

            for (&self.buckets) |*bucket| {
                if (len <= bucket.block_size) {
                    if (have_mutex) std.Thread.Mutex.lock(&self.mutex);
                    defer if (have_mutex) std.Thread.Mutex.unlock(&self.mutex);

                    if (bucket.acquire()) |b| {
                        return b.ptr;
                    }
                }
            }
            return null;
        }

        fn free(context: *anyopaque, memory: []u8, _: std.mem.Alignment, _: usize) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (memory.len == buffer_ref_size) {
                if (have_mutex) std.Thread.Mutex.lock(&self.mutex);
                defer if (have_mutex) std.Thread.Mutex.unlock(&self.mutex);
                self.buffer_ref_allocator.destroy(@ptrCast(@alignCast(memory.ptr)));
                return;
            }
            const ptr = @intFromPtr(memory.ptr);
            for (&self.buckets) |*bucket| {
                const start = @intFromPtr(bucket.buffer.ptr);
                if (ptr >= start and ptr < start + bucket.buffer.len) {
                    if (have_mutex) std.Thread.Mutex.lock(&self.mutex);
                    defer if (have_mutex) std.Thread.Mutex.unlock(&self.mutex);
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
    var bucket = try Bucket.init(testing.allocator, 64, 2);
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
    var bucket = try Bucket.init(testing.allocator, 64, 1);
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

test "BufferPoolAllocator: alloc of buffer_ref_size bypasses buckets" {
    // Buckets are too small to hold a BufferRef; the dedicated buffer_ref
    // path must still satisfy the allocation.
    const Pool = BufferPoolAllocator(.{
        .bucket_sizes = &.{8},
        .bucket_counts = &.{1},
    });
    var pool = try Pool.init(testing.allocator);
    defer pool.deinit();
    const ally = pool.allocator();

    const buf = try ally.alloc(u8, buffer_ref_size);
    try testing.expectEqual(@as(usize, buffer_ref_size), buf.len);
    @memset(buf, 0xCD); // verify memory is writable
    // The buffer_ref path must not return memory from any bucket's backing buffer.
    const buf_addr = @intFromPtr(buf.ptr);
    for (&pool.buckets) |bucket| {
        const start = @intFromPtr(bucket.buffer.ptr);
        try testing.expect(buf_addr < start or buf_addr >= start + bucket.buffer.len);
    }
    ally.free(buf);
}

test "BufferPoolAllocator: buffer_ref allocs are independent of bucket exhaustion" {
    const Pool = BufferPoolAllocator(.{
        .bucket_sizes = &.{64},
        .bucket_counts = &.{1},
    });
    var pool = try Pool.init(testing.allocator);
    defer pool.deinit();
    const ally = pool.allocator();

    const bucket_buf = try ally.alloc(u8, 64); // exhaust the only bucket block

    const ref_buf1 = try ally.alloc(u8, buffer_ref_size);
    const ref_buf2 = try ally.alloc(u8, buffer_ref_size);
    try testing.expect(ref_buf1.ptr != ref_buf2.ptr);

    ally.free(ref_buf1);
    ally.free(ref_buf2);
    ally.free(bucket_buf);
}

test "BufferPoolAllocator: freed buffer_ref slot is reused" {
    const Pool = BufferPoolAllocator(.{
        .bucket_sizes = &.{64},
        .bucket_counts = &.{1},
    });
    var pool = try Pool.init(testing.allocator);
    defer pool.deinit();
    const ally = pool.allocator();

    const buf1 = try ally.alloc(u8, buffer_ref_size);
    const ptr1 = buf1.ptr;
    ally.free(buf1);

    const buf2 = try ally.alloc(u8, buffer_ref_size);
    try testing.expectEqual(ptr1, buf2.ptr);
    ally.free(buf2);
}
