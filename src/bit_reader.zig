const std = @import("std");

const BitReader = @This();
const Reader = std.Io.Reader;
const assert = std.debug.assert;

reader: *Reader,
bit_pos: u3 = 0,
current_byte: u8 = 0,

pub fn init(reader: *Reader) BitReader {
    return BitReader{ .reader = reader };
}

pub fn peekBit(self: *BitReader) !u1 {
    var current_byte = self.current_byte;
    if (self.bit_pos == 0) {
        current_byte = try self.reader.peekByte();
    }

    return @intCast((current_byte >> (7 - self.bit_pos)) & 1);
}

pub fn skipBit(self: *BitReader) !void {
    if (self.bit_pos == 0) {
        self.current_byte = try self.reader.takeByte();
    }

    self.bit_pos = self.bit_pos +% 1;
}

pub fn takeBit(self: *BitReader) !u1 {
    if (self.bit_pos == 0) {
        self.current_byte = try self.reader.takeByte();
    }

    const bit = (self.current_byte >> (7 - self.bit_pos)) & 1;
    self.bit_pos = self.bit_pos +% 1;
    return @intCast(bit);
}

pub fn takeBits(self: *BitReader, comptime T: type, count: usize) !T {
    assert(@typeInfo(T).int.bits >= count);
    var result: T = try self.takeBit();

    switch (T) {
        u1 => return result,
        else => {
            @branchHint(.likely);
            var i: usize = 1;
            while (i < count) : (i += 1) {
                result = (result << 1) | try self.takeBit();
            }

            return result;
        },
    }
}

/// Reads an signed/unsigned Exp-Golomb coded integer.
pub fn takeExpGolomb(self: *BitReader, comptime T: type) !T {
    var leading_zeros: usize = 0;
    while (try self.peekBit() == 0) : (leading_zeros += 1) {
        _ = try self.skipBit();
    }

    const num = try self.takeBits(T, leading_zeros + 1) - 1;
    return switch (@typeInfo(T).int.signedness) {
        .unsigned => num,
        .signed => if (@rem(num, 2) == 0) @divExact(-num, 2) else @divExact(num + 1, 2),
    };
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
