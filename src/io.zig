const std = @import("std");

const Reader = std.Io.Reader;
const assert = std.debug.assert;

pub const BitReader = struct {
    reader: *Reader,
    // Valid bits are left-justified: the next bit to read is bit 63.
    acc: u64 = 0,
    bit_count: u7 = 0,

    pub fn init(reader: *Reader) BitReader {
        return BitReader{ .reader = reader };
    }

    pub fn peekBit(self: *BitReader) Reader.Error!u1 {
        if (self.bit_count == 0) self.fill();
        if (self.bit_count == 0) return error.EndOfStream;
        return @intCast(self.acc >> 63);
    }

    pub fn skipBit(self: *BitReader) Reader.Error!void {
        if (self.bit_count == 0) self.fill();
        if (self.bit_count == 0) return error.EndOfStream;
        self.consume(1);
    }

    pub fn takeBit(self: *BitReader) Reader.Error!u1 {
        if (self.bit_count == 0) self.fill();
        if (self.bit_count == 0) return error.EndOfStream;
        const bit: u1 = @intCast(self.acc >> 63);
        self.consume(1);
        return bit;
    }

    pub fn takeBits(self: *BitReader, comptime T: type, count: usize) Reader.Error!T {
        assert(@typeInfo(T).int.bits >= count);
        if (count == 0) return 0;
        if (self.bit_count < count) self.fill();
        if (self.bit_count < count) return error.EndOfStream;

        const result = self.acc >> @intCast(64 - count);
        self.consume(@intCast(count));
        return @intCast(result);
    }

    /// Reads an signed/unsigned Exp-Golomb coded integer.
    pub fn takeExpGolomb(self: *BitReader, comptime T: type) Reader.Error!T {
        if (self.bit_count == 0) self.fill();
        if (self.bit_count == 0) return error.EndOfStream;

        var leading_zeros: u7 = @clz(self.acc);
        while (leading_zeros >= self.bit_count) {
            const before = self.bit_count;
            self.fill();
            if (self.bit_count == before) return error.EndOfStream;
            leading_zeros = @clz(self.acc);
        }

        const total = 2 * leading_zeros + 1;
        if (self.bit_count < total) {
            self.fill();
            if (self.bit_count < total) return error.EndOfStream;
        }

        const code: u64 = (self.acc >> @intCast(64 - total)) - 1;
        self.consume(total);

        const U = @Int(.unsigned, @typeInfo(T).int.bits);
        const num: U = @intCast(code);
        return switch (@typeInfo(T).int.signedness) {
            .unsigned => num,
            .signed => blk: {
                const magnitude: T = @intCast((num + 1) >> 1);
                break :blk if (num & 1 == 1) magnitude else -magnitude;
            },
        };
    }

    fn fill(self: *BitReader) void {
        while (self.bit_count <= 56) {
            const byte = self.reader.takeByte() catch break;
            self.acc |= @as(u64, byte) << @intCast(56 - self.bit_count);
            self.bit_count += 8;
        }
    }

    fn consume(self: *BitReader, count: u7) void {
        self.acc = if (count == 64) 0 else self.acc << @intCast(count);
        self.bit_count -= count;
    }

    test "takeBit" {
        const data = [_]u8{ 0b10101010, 0b11001100 };
        var reader = Reader.fixed(&data);
        var bit_reader = BitReader.init(&reader);

        try std.testing.expectEqual(1, bit_reader.takeBit());
        try std.testing.expectEqual(0, bit_reader.takeBit());
        try std.testing.expectEqual(1, bit_reader.takeBit());
        try std.testing.expectEqual(0, bit_reader.takeBit());
        try std.testing.expectEqual(1, bit_reader.takeBit());
        try std.testing.expectEqual(0, bit_reader.takeBit());
        try std.testing.expectEqual(1, bit_reader.takeBit());
        try std.testing.expectEqual(0, bit_reader.takeBit());

        try std.testing.expectEqual(1, bit_reader.takeBit());
        try std.testing.expectEqual(1, bit_reader.takeBit());
        try std.testing.expectEqual(0, bit_reader.takeBit());
        try std.testing.expectEqual(0, bit_reader.takeBit());
        try std.testing.expectEqual(1, bit_reader.takeBit());
        try std.testing.expectEqual(1, bit_reader.takeBit());
        try std.testing.expectEqual(0, bit_reader.takeBit());
        try std.testing.expectEqual(0, bit_reader.takeBit());

        try std.testing.expectError(Reader.Error.EndOfStream, bit_reader.takeBit());
    }

    test "takeBits" {
        const data = [_]u8{ 0b10101010, 0b11001100 };
        var reader = Reader.fixed(&data);
        var bit_reader = BitReader.init(&reader);

        try std.testing.expectEqual(10, bit_reader.takeBits(u4, 4));
        try std.testing.expectEqual(5, bit_reader.takeBits(u3, 3));
        try std.testing.expectEqual(102, bit_reader.takeBits(u8, 8));

        try std.testing.expectError(Reader.Error.EndOfStream, bit_reader.takeBits(u2, 2));
    }

    test "peekBit does not advance position" {
        // 0b10110100 bits MSB-first: 1, 0, 1, 1, 0, 1, 0, 0
        const data = [_]u8{0b10110100};
        var reader = Reader.fixed(&data);
        var bit_reader = BitReader.init(&reader);

        // Repeated peeks return the same bit
        try std.testing.expectEqual(1, bit_reader.peekBit());
        try std.testing.expectEqual(1, bit_reader.peekBit());

        _ = try bit_reader.takeBit(); // consume bit 0 (=1)
        try std.testing.expectEqual(0, bit_reader.peekBit()); // bit 1
        try std.testing.expectEqual(0, bit_reader.peekBit()); // still bit 1
        _ = try bit_reader.takeBit(); // consume bit 1 (=0)
        try std.testing.expectEqual(1, bit_reader.peekBit()); // bit 2
    }

    test "peekBit returns EndOfStream on empty reader" {
        const data = [_]u8{};
        var reader = Reader.fixed(&data);
        var bit_reader = BitReader.init(&reader);

        try std.testing.expectError(Reader.Error.EndOfStream, bit_reader.peekBit());
    }

    test "skipBit advances past bits" {
        // 0b10110100 bits MSB-first: 1, 0, 1, 1, 0, 1, 0, 0
        const data = [_]u8{0b10110100};
        var reader = Reader.fixed(&data);
        var bit_reader = BitReader.init(&reader);

        _ = try bit_reader.takeBit(); // consume bit 0 (=1), bit_pos=1
        try bit_reader.skipBit(); // skip bit 1 (=0), bit_pos=2
        try std.testing.expectEqual(1, bit_reader.takeBit()); // bit 2
        try std.testing.expectEqual(1, bit_reader.takeBit()); // bit 3
        try bit_reader.skipBit(); // skip bit 4 (=0), bit_pos=5
        try std.testing.expectEqual(1, bit_reader.takeBit()); // bit 5
    }

    test "takeExpGolombUint" {
        // Encoding (this implementation's scheme):
        //   value 1 → "1"      (1 bit)
        //   value 2 → "010"    (3 bits)
        //   value 3 → "011"    (3 bits)
        // Packed: 1 010 011 x = 0b10100110 = 0xA6 (last bit unused)
        const data = [_]u8{0b10100110};
        var reader = Reader.fixed(&data);
        var bit_reader = BitReader.init(&reader);

        try std.testing.expectEqual(0, bit_reader.takeExpGolomb(u8));
        try std.testing.expectEqual(1, bit_reader.takeExpGolomb(u8));
        try std.testing.expectEqual(2, bit_reader.takeExpGolomb(u8));
    }

    test "takeExpGolombUint larger values" {
        // value 4 → "00100"   (5 bits)
        // value 5 → "00101"   (5 bits)
        // Packed: 00100 00101 xx = 0b00100001 0b01xxxxxx
        //                       = 0b00100001 = 0x21, 0b01000000 = 0x40
        const data = [_]u8{ 0b00100001, 0b01000000 };
        var reader = Reader.fixed(&data);
        var bit_reader = BitReader.init(&reader);

        try std.testing.expectEqual(3, bit_reader.takeExpGolomb(u8));
        try std.testing.expectEqual(4, bit_reader.takeExpGolomb(u8));
    }

    test "takeExpGolombInt" {
        // Signed mapping: num=0 → 0, num=1 → 1, num=2 → -1
        //   0 → "1"      (1 bit)
        //   1 → "010"    (3 bits)
        //  -1 → "011"    (3 bits)
        // Packed: 1 010 011 x = 0b10100110 = 0xA6 (last bit unused)
        const data = [_]u8{0b10100110};
        var reader = Reader.fixed(&data);
        var bit_reader = BitReader.init(&reader);

        try std.testing.expectEqual(0, bit_reader.takeExpGolomb(i8));
        try std.testing.expectEqual(1, bit_reader.takeExpGolomb(i8));
        try std.testing.expectEqual(-1, bit_reader.takeExpGolomb(i8));
    }

    test "takeExpGolombInt larger values" {
        // Signed mapping: num=3 → 2, num=4 → -2
        //   2 → "00100"  (5 bits)
        //  -2 → "00101"  (5 bits)
        // Packed: 00100 00101 xx = 0b00100001 0b01xxxxxx
        //                       = 0b00100001 = 0x21, 0b01000000 = 0x40
        const data = [_]u8{ 0b00100001, 0b01000000 };
        var reader = Reader.fixed(&data);
        var bit_reader = BitReader.init(&reader);

        try std.testing.expectEqual(2, bit_reader.takeExpGolomb(i8));
        try std.testing.expectEqual(-2, bit_reader.takeExpGolomb(i8));
    }
};

test {
    std.testing.refAllDecls(@This());
}
