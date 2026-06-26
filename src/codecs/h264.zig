pub const Sps = @import("h264/sps.zig");

const std = @import("std");
const BitReader = @import("../io.zig").BitReader;

pub const ParseError = error{ InvalidNal, InvalidSps };
pub const ReadError = std.Io.Reader.Error;
pub const WriteError = std.Io.Writer.Error;
pub const Error = ParseError || ReadError || WriteError;

pub const annexb_start_code = [_]u8{ 0x00, 0x00, 0x00, 0x01 };

/// H.264 NAL unit types.
pub const NalType = enum(u5) {
    unspecified0 = 0,
    non_idr,
    part_a,
    part_b,
    part_c,
    idr,
    sei,
    sps,
    pps,
    aud,
    end_sequence,
    end_stream,
    filler_data,
    sps_extension,
    prefix_nal_unit,
    subset_sps,
    depth_parameter_set,
    reserved17,
    reserved18,
    auxiliary_slice,
    coded_slice_extension,
    code_slice_extension_for_depth,
    reserved22,
    reserved23,
    // stap_a, stap_b, mtap_16, mtap_24, fu_a and fu_b are used in RTP
    stap_a,
    stap_b,
    mtap_16,
    mtap_24,
    fu_a,
    fu_b,
    unspecified30,
    unspecified31,

    pub inline fn isKeyframe(self: NalType) bool {
        return self == .idr;
    }
};

/// Describes the NAL unit header, which is the first byte of a NAL unit.
pub const NalHeader = packed struct {
    nal_type: NalType,
    ref_idc: u2,
    zero_bit: u1 = 0,

    pub inline fn fromByte(header: u8) NalHeader {
        return @bitCast(header);
    }

    pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("<Header: type={}, nal_ref_idc={}>", .{
            self.nal_type,
            self.ref_idc,
        });
    }

    test "parse nal header" {
        const header: u8 = 0b0100_0101;
        const nal_header = NalHeader.fromByte(header);

        try std.testing.expect(nal_header.nal_type == .idr);
        try std.testing.expect(nal_header.ref_idc == 2);
    }
};

/// Represents the AVCDecoderConfigurationRecord structure as defined in ISO/IEC 14496-15 (Carriage of network abstraction layer (NAL)
/// unit in the ISO base media file format).
pub const DecoderConfigurationRecord = struct {
    avc_profile_indication: u8,
    profile_compatibility: u8,
    avc_level_indication: u8,
    length_size: u8,
    ps_bytes: []const u8 = &.{},

    pub const H264Error = error{InvalidH264DCR};

    pub fn initFromSps(sps: *const Sps) DecoderConfigurationRecord {
        return DecoderConfigurationRecord{
            .avc_profile_indication = sps.profile_idc,
            .profile_compatibility = sps.constraint_set_flags,
            .avc_level_indication = sps.level_idc,
            .length_size = 4,
        };
    }

    pub fn parse(data: []const u8) H264Error!DecoderConfigurationRecord {
        if (data.len < 7) return error.InvalidH264DCR;

        return DecoderConfigurationRecord{
            .avc_profile_indication = data[1],
            .profile_compatibility = data[2],
            .avc_level_indication = data[3],
            .length_size = (data[4] & 0x03) + 1,
            .ps_bytes = data[5..],
        };
    }

    pub fn iterateParameterSets(self: *const DecoderConfigurationRecord) Iterator {
        return .init(self.ps_bytes);
    }

    pub fn writer(self: *const DecoderConfigurationRecord, w: *std.Io.Writer) !Writer {
        try w.writeByte(1); // configurationVersion
        try w.writeByte(self.avc_profile_indication);
        try w.writeByte(self.profile_compatibility);
        try w.writeByte(self.avc_level_indication);
        try w.writeByte(0xFC | (self.length_size - 1));
        return .{ .writer = w };
    }

    pub const Iterator = struct {
        reader: std.Io.Reader,
        nal_type: NalType,
        count: u8,

        pub fn init(bytes: []const u8) Iterator {
            return .{
                .reader = std.Io.Reader.fixed(bytes[1..]),
                .nal_type = .sps,
                .count = bytes[0] & 0x1F,
            };
        }

        pub fn next(it: *Iterator) H264Error!?[]const u8 {
            if (it.count == 0) {
                switch (it.nal_type) {
                    .sps => {
                        it.nal_type = .pps;
                        it.count = it.reader.takeByte() catch return error.InvalidH264DCR;
                        return it.next();
                    },
                    .pps => return null,
                    else => unreachable,
                }
            }

            const nal_size = it.reader.takeInt(u16, .big) catch return error.InvalidH264DCR;
            const result = it.reader.take(nal_size) catch return error.InvalidH264DCR;
            it.count -= 1;
            return result;
        }
    };

    pub const Writer = struct {
        writer: *std.Io.Writer,

        pub fn writeSpsCount(self: *Writer, count: u8) !void {
            std.debug.assert(count <= 31);
            try self.writer.writeByte(0xE0 | (count & 0x1F));
        }

        pub fn writePpsCount(self: *Writer, count: u8) !void {
            try self.writer.writeByte(count);
        }

        pub fn writeNalUnit(self: *Writer, nal_data: []const u8) !void {
            try self.writer.writeInt(u16, @intCast(nal_data.len), .big);
            try self.writer.writeAll(nal_data);
        }

        pub fn writeBase64NalUnit(self: *Writer, nal_data: []const u8) !void {
            var decoder = std.base64.standard.Decoder;

            const nal_size = try decoder.calcSizeForSlice(nal_data);
            try self.writer.writeInt(u16, @intCast(nal_size), .big);

            const slice = try self.writer.writableSlice(nal_size);
            try decoder.decode(slice, nal_data);
        }
    };

    test "parse valid configuration" {
        const data = [_]u8{ 1, 100, 0, 40, 0xFF, 0xE0, 0x00 };
        const config = try DecoderConfigurationRecord.parse(&data);

        try std.testing.expect(config.avc_profile_indication == 100);
        try std.testing.expect(config.avc_level_indication == 40);
        try std.testing.expect(config.length_size == 4);
        try std.testing.expect(config.profile_compatibility == 0);
    }

    test "write produces correct byte layout" {
        const config = DecoderConfigurationRecord{
            .avc_profile_indication = 0x64,
            .profile_compatibility = 0x00,
            .avc_level_indication = 0x28,
            .length_size = 4,
        };
        const sps_nal = [_]u8{ 0xAB, 0xCD };
        const pps_nal = [_]u8{0xEF};

        var buf: [64]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        var dcr_writer = try config.writer(&w);
        try dcr_writer.writeSpsCount(1);
        try dcr_writer.writeNalUnit(&sps_nal);
        try dcr_writer.writePpsCount(1);
        try dcr_writer.writeNalUnit(&pps_nal);

        const expected = [_]u8{
            0x01, 0x64, 0x00, 0x28, 0xFF,
            0xE1, 0x00, 0x02, 0xAB, 0xCD,
            0x01, 0x00, 0x01, 0xEF,
        };
        try std.testing.expectEqualSlices(u8, &expected, w.buffered());
    }

    test "write then parse round-trip" {
        const original = DecoderConfigurationRecord{
            .avc_profile_indication = 0x64,
            .profile_compatibility = 0xC0,
            .avc_level_indication = 0x28,
            .length_size = 2,
        };

        var buf: [64]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        var dcr_writer = try original.writer(&w);
        try dcr_writer.writeSpsCount(0);
        try dcr_writer.writePpsCount(0);

        const parsed = try DecoderConfigurationRecord.parse(w.buffered());
        try std.testing.expectEqual(original.avc_profile_indication, parsed.avc_profile_indication);
        try std.testing.expectEqual(original.profile_compatibility, parsed.profile_compatibility);
        try std.testing.expectEqual(original.avc_level_indication, parsed.avc_level_indication);
        try std.testing.expectEqual(original.length_size, parsed.length_size);
    }

    test "initFromSps populates fields from SPS" {
        const sps_data = &[_]u8{
            0x64, 0xC0, 0x28, 0xAC, 0xD9, 0x40,
            0x50, 0x05, 0xBB, 0x01, 0x6C, 0x80,
            0x00, 0x00, 0x03, 0x00, 0x80, 0x00,
            0x00, 0x1E, 0x07, 0x8C, 0x18, 0xCB,
        };
        const sps = try Sps.parse(sps_data);
        const config = DecoderConfigurationRecord.initFromSps(&sps);

        try std.testing.expectEqual(sps.profile_idc, config.avc_profile_indication);
        try std.testing.expectEqual(sps.constraint_set_flags, config.profile_compatibility);
        try std.testing.expectEqual(sps.level_idc, config.avc_level_indication);
        try std.testing.expectEqual(@as(u8, 4), config.length_size);
    }

    test "iterator parameter sets" {
        const bytes = [_]u8{
            0x01, 0x4d, 0x40, 0x1f, 0xff, 0xe1, 0x00,
            0x1d, 0x67, 0x4d, 0x40, 0x1f, 0xec, 0xa0,
            0x6c, 0x1f, 0xf2, 0x44, 0x7f, 0xe1, 0xe2,
            0x01, 0xe2, 0xa2, 0x00, 0x00, 0x03, 0x00,
            0x64, 0x00, 0x00, 0x12, 0xbc, 0x1e, 0x30,
            0x63, 0x2c, 0x01, 0x00, 0x04, 0x68, 0xef,
            0x86, 0xf2,
        };

        const dcr = try parse(&bytes);
        try std.testing.expectEqual(77, dcr.avc_profile_indication);
        try std.testing.expectEqual(64, dcr.profile_compatibility);
        try std.testing.expectEqual(31, dcr.avc_level_indication);
        try std.testing.expectEqual(4, dcr.length_size);

        const expected_sps = [_]u8{
            0x67, 0x4d, 0x40, 0x1f, 0xec,
            0xa0, 0x6c, 0x1f, 0xf2, 0x44,
            0x7f, 0xe1, 0xe2, 0x01, 0xe2,
            0xa2, 0x00, 0x00, 0x03, 0x00,
            0x64, 0x00, 0x00, 0x12, 0xbc,
            0x1e, 0x30, 0x63, 0x2c,
        };

        const expected_pps = [_]u8{ 0x68, 0xef, 0x86, 0xf2 };

        var it = dcr.iterateParameterSets();
        try std.testing.expectEqualSlices(u8, &expected_sps, (try it.next()).?);
        try std.testing.expectEqualSlices(u8, &expected_pps, (try it.next()).?);
        try std.testing.expectEqual(null, try it.next());
    }
};

pub const ParameterSetReader = struct {
    buffer: []const u8,
    interface: std.Io.Reader,
    pos: usize = 0,

    pub fn init(data: []const u8, reader_buf: []u8) ParameterSetReader {
        return ParameterSetReader{
            .buffer = data,
            .interface = .{
                .buffer = reader_buf,
                .seek = 0,
                .end = 0,
                .vtable = &.{
                    .stream = undefined,
                    .discard = undefined,
                    .rebase = std.Io.Reader.defaultRebase,
                    .readVec = readVec,
                },
            },
        };
    }

    fn readVec(r: *std.Io.Reader, _: [][]u8) !usize {
        var reader: *ParameterSetReader = @alignCast(@fieldParentPtr("interface", r));
        if (reader.pos >= reader.buffer.len) return error.EndOfStream;

        const src = reader.buffer;
        var dest = r.buffer[r.seek..];
        const read = @min(dest.len, src.len - reader.pos);

        var written: usize = 0;
        for (0..read) |_| {
            if (ignore(src, reader.pos)) {
                reader.pos += 1;
            } else {
                @branchHint(.likely);
                dest[written] = src[reader.pos];
                reader.pos += 1;
                written += 1;
            }
        }

        r.end += written;
        return 0;
    }

    fn ignore(buffer: []const u8, pos: usize) bool {
        if (pos < 2 or pos + 1 >= buffer.len) return false;
        return buffer[pos - 2] == 0 and buffer[pos - 1] == 0 and buffer[pos] == 3 and buffer[pos + 1] <= 3;
    }

    test "passthrough without emulation prevention bytes" {
        const data = [_]u8{ 0x01, 0x02, 0x03, 0x04 };
        var buffer: [64]u8 = undefined;
        var psr = ParameterSetReader.init(&data, &buffer);
        var reader = &psr.interface;

        try std.testing.expectEqual(0x01, reader.takeByte());
        try std.testing.expectEqual(0x02, reader.takeByte());
        try std.testing.expectEqual(0x03, reader.takeByte());
        try std.testing.expectEqual(0x04, reader.takeByte());
        try std.testing.expectError(error.EndOfStream, reader.takeByte());
    }

    test "strips emulation prevention byte 00 00 03 01" {
        // 00 00 03 01 → 00 00 01 (the 03 EPB is removed)
        const data = [_]u8{ 0x00, 0x00, 0x03, 0x01 };
        var buffer: [64]u8 = undefined;
        var psr = ParameterSetReader.init(&data, &buffer);
        var reader = &psr.interface;

        try std.testing.expectEqual(0x00, reader.takeByte());
        try std.testing.expectEqual(0x00, reader.takeByte());
        try std.testing.expectEqual(0x01, reader.takeByte());
        try std.testing.expectError(error.EndOfStream, reader.takeByte());
    }

    test "does not strip 00 00 03 04 (not an EPB sequence)" {
        // byte after 03 is 0x04 > 3, so this is not an EPB — all bytes kept
        const data = [_]u8{ 0x00, 0x00, 0x03, 0x04 };
        var buffer: [64]u8 = undefined;
        var psr = ParameterSetReader.init(&data, &buffer);
        var reader = &psr.interface;

        try std.testing.expectEqual(0x00, reader.takeByte());
        try std.testing.expectEqual(0x00, reader.takeByte());
        try std.testing.expectEqual(0x03, reader.takeByte());
        try std.testing.expectEqual(0x04, reader.takeByte());
    }

    test "EPB at position 2 (first possible EPB position)" {
        // buffer[0..4] = 00 00 03 02 — EPB at pos=2, requires pos < 2 guard fix
        const data = [_]u8{ 0x00, 0x00, 0x03, 0x02 };
        var buffer: [64]u8 = undefined;
        var psr = ParameterSetReader.init(&data, &buffer);
        var reader = &psr.interface;

        try std.testing.expectEqual(0x00, reader.takeByte());
        try std.testing.expectEqual(0x00, reader.takeByte());
        try std.testing.expectEqual(0x02, reader.takeByte());
        try std.testing.expectError(error.EndOfStream, reader.takeByte());
    }

    test "multiple EPBs in sequence" {
        // prefix + 00 00 03 03 + 00 00 03 03
        // Each 03 is an EPB, yielding: AA 00 00 03 00 00 03
        const data = [_]u8{ 0xAA, 0x00, 0x00, 0x03, 0x03, 0x00, 0x00, 0x03, 0x03 };
        var buffer: [64]u8 = undefined;
        var psr = ParameterSetReader.init(&data, &buffer);
        var reader = &psr.interface;

        try std.testing.expectEqual(0xAA, reader.takeByte());
        try std.testing.expectEqual(0x00, reader.takeByte());
        try std.testing.expectEqual(0x00, reader.takeByte());
        try std.testing.expectEqual(0x03, reader.takeByte()); // kept (this is the value, not EPB)
        try std.testing.expectEqual(0x00, reader.takeByte());
        try std.testing.expectEqual(0x00, reader.takeByte());
        try std.testing.expectEqual(0x03, reader.takeByte());
        try std.testing.expectError(error.EndOfStream, reader.takeByte());
    }

    test "short reader buffer forces multiple refills" {
        // Use a 2-byte reader buffer so readVec is called multiple times.
        // Data: 01 00 00 03 02 05 → strips EPB → 01 00 00 02 05
        const data = [_]u8{ 0x01, 0x00, 0x00, 0x03, 0x02, 0x05 };
        var buffer: [2]u8 = undefined;
        var psr = ParameterSetReader.init(&data, &buffer);
        var reader = &psr.interface;

        try std.testing.expectEqual(0x01, reader.takeByte());
        try std.testing.expectEqual(0x00, reader.takeByte());
        try std.testing.expectEqual(0x00, reader.takeByte());
        try std.testing.expectEqual(0x02, reader.takeByte());
        try std.testing.expectEqual(0x05, reader.takeByte());
        try std.testing.expectError(error.EndOfStream, reader.takeByte());
    }
};

test {
    std.testing.refAllDecls(@This());
    _ = @import("h264/sps.zig");
}
