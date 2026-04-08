const std = @import("std");
const BitReader = @import("bit_reader.zig");

pub const ParseError = error{ InvalidNal, InvalidSps };
pub const ReadError = std.Io.Reader.Error;
pub const WriteError = std.Io.Writer.Error;
pub const Error = ParseError || ReadError || WriteError;

/// H.264 NAL unit types.
pub const NalType = enum(u5) {
    non_idr = 1,
    part_a = 2,
    part_b = 3,
    part_c = 4,
    idr = 5,
    sei = 6,
    sps = 7,
    pps = 8,
    aud = 9,
    end_sequence = 10,
    end_stream = 11,
    filler_data = 12,
    sps_extension = 13,
    prefix_nal_unit = 14,
    subset_sps = 15,
    depth_parameter_set = 16,
    auxiliary_slice = 19,
    coded_slice_extension = 20,
    code_slice_extension_for_depth = 21,
    reserved = 17,
    unspecified = 0,

    pub fn fromInt(value: u5) NalType {
        return switch (value) {
            0, 24...31 => .unspecified,
            17, 18, 22, 23 => .reserved,
            else => @enumFromInt(value),
        };
    }
};

/// Describes the NAL unit header, which is the first byte of a NAL unit.
pub const NalHeader = struct {
    type: NalType,
    nal_ref_idc: u2,

    pub fn fromByte(header: u8) NalHeader {
        return NalHeader{
            .type = NalType.fromInt(@intCast(header & 0x1F)),
            .nal_ref_idc = @intCast((header >> 5) & 0x03),
        };
    }

    pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("<Header: type={}, nal_ref_idc={}>", .{
            self.type,
            self.nal_ref_idc,
        });
    }

    test "parse nal header" {
        const header: u8 = 0b0100_0101;
        const nal_header = NalHeader.fromByte(header);

        try std.testing.expect(nal_header.type == .idr);
        try std.testing.expect(nal_header.nal_ref_idc == 2);
    }
};

/// Represents the Sequence Parameter Set (SPS) of an H.264 stream.
pub const Sps = struct {
    profile_idc: u8,
    constraint_set_flags: u8,
    level_idc: u8,
    seq_parameter_set_id: u8,
    chroma_format_idc: u2 = 1,
    separate_colour_plane_flag: bool = false,
    bit_depth_luma_minus8: u8 = 0,
    bit_depth_chroma_minus8: u8 = 0,
    log2_max_frame_num_minus4: u8,
    pic_order_cnt_type: u8,
    log2_max_pic_order_cnt_lsb_minus4: ?u8 = null,
    pic_order_cnt_type1: ?PicOrderCntType1 = null,
    max_num_ref_frames: u8,
    gaps_in_frame_num_value_allowed_flag: bool,
    pic_width_in_mbs_minus1: u32,
    pic_height_in_map_units_minus1: u32,
    frame_mbs_only_flag: bool,
    mb_adaptive_frame_field_flag: bool = false,
    direct_8x8_inference_flag: bool,
    frame_crop: ?Rect = null,

    pub const PicOrderCntType1 = struct {
        delta_pic_order_always_zero_flag: bool,
        offset_for_non_ref_pic: i32,
        offset_for_top_to_bottom_field: i32,
        num_ref_frames_in_pic_order_cnt_cycle: u8,
        // offset_for_ref_frame: []i32,

        fn parse(bit_reader: *BitReader) !PicOrderCntType1 {
            var result: PicOrderCntType1 = undefined;
            result.delta_pic_order_always_zero_flag = try bit_reader.takeBit() == 1;
            result.offset_for_non_ref_pic = try bit_reader.takeExpGolomb(i32);
            result.offset_for_top_to_bottom_field = try bit_reader.takeExpGolomb(i32);
            result.num_ref_frames_in_pic_order_cnt_cycle = try bit_reader.takeExpGolomb(u8);

            for (0..result.num_ref_frames_in_pic_order_cnt_cycle) |_| {
                _ = try bit_reader.takeExpGolomb(i32); // offset_for_ref_frame
            }

            return result;
        }
    };

    pub const Rect = struct {
        left: u32,
        right: u32,
        top: u32,
        bottom: u32,

        fn parse(bit_reader: *BitReader) !Rect {
            return Rect{
                .left = try bit_reader.takeExpGolomb(@FieldType(Rect, "left")),
                .right = try bit_reader.takeExpGolomb(@FieldType(Rect, "right")),
                .top = try bit_reader.takeExpGolomb(@FieldType(Rect, "top")),
                .bottom = try bit_reader.takeExpGolomb(@FieldType(Rect, "bottom")),
            };
        }
    };

    pub fn parse(data: []const u8) !Sps {
        var buffer: [16]u8 = undefined;
        var reader = ParameterSetReader.init(data, &buffer);
        var bit_reader = BitReader.init(&reader.interface);

        var sps: Sps = .{
            .profile_idc = try reader.interface.takeByte(),
            .constraint_set_flags = try reader.interface.takeByte(),
            .level_idc = try reader.interface.takeByte(),
            .seq_parameter_set_id = try bit_reader.takeExpGolomb(@FieldType(Sps, "seq_parameter_set_id")),
            .log2_max_frame_num_minus4 = 0,
            .pic_order_cnt_type = 0,
            .max_num_ref_frames = 0,
            .gaps_in_frame_num_value_allowed_flag = false,
            .pic_width_in_mbs_minus1 = 0,
            .pic_height_in_map_units_minus1 = 0,
            .frame_mbs_only_flag = false,
            .direct_8x8_inference_flag = false,
        };

        switch (sps.profile_idc) {
            100, 110, 122, 244, 44, 83, 86, 118, 128, 138 => {
                sps.chroma_format_idc = try bit_reader.takeExpGolomb(@TypeOf(sps.chroma_format_idc));
                if (sps.chroma_format_idc == 3) {
                    sps.separate_colour_plane_flag = try bit_reader.takeBit() == 1;
                }
                sps.bit_depth_luma_minus8 = try bit_reader.takeExpGolomb(@TypeOf(sps.bit_depth_luma_minus8));
                sps.bit_depth_chroma_minus8 = try bit_reader.takeExpGolomb(@TypeOf(sps.bit_depth_chroma_minus8));
                try bit_reader.skipBit();
                if (try bit_reader.takeBit() == 1) {
                    const entries: usize = if (sps.chroma_format_idc != 3) 8 else 12;
                    for (0..entries) |i| {
                        if (try bit_reader.takeBit() == 0) continue;
                        if (i < 6) {
                            try parseScalingList(&bit_reader, 16);
                        } else {
                            try parseScalingList(&bit_reader, 64);
                        }
                    }
                }
            },
            else => {},
        }

        sps.log2_max_frame_num_minus4 = try bit_reader.takeExpGolomb(@TypeOf(sps.log2_max_frame_num_minus4));
        sps.pic_order_cnt_type = try bit_reader.takeExpGolomb(@TypeOf(sps.pic_order_cnt_type));

        switch (sps.pic_order_cnt_type) {
            0 => sps.log2_max_pic_order_cnt_lsb_minus4 = try bit_reader.takeExpGolomb(std.meta.Child(@TypeOf(sps.log2_max_pic_order_cnt_lsb_minus4))),
            1 => sps.pic_order_cnt_type1 = try PicOrderCntType1.parse(&bit_reader),
            else => {},
        }

        sps.max_num_ref_frames = try bit_reader.takeExpGolomb(@TypeOf(sps.max_num_ref_frames));
        sps.gaps_in_frame_num_value_allowed_flag = try bit_reader.takeBit() == 1;
        sps.pic_width_in_mbs_minus1 = try bit_reader.takeExpGolomb(@TypeOf(sps.pic_width_in_mbs_minus1));
        sps.pic_height_in_map_units_minus1 = try bit_reader.takeExpGolomb(@TypeOf(sps.pic_height_in_map_units_minus1));
        sps.frame_mbs_only_flag = try bit_reader.takeBit() == 1;
        if (!sps.frame_mbs_only_flag) {
            sps.mb_adaptive_frame_field_flag = try bit_reader.takeBit() == 1;
        }
        sps.direct_8x8_inference_flag = try bit_reader.takeBit() == 1;

        if (try bit_reader.takeBit() == 1) {
            sps.frame_crop = try Rect.parse(&bit_reader);
        }

        return sps;
    }

    pub fn getWidth(self: *const Sps) u32 {
        const chroma_array_type = if (!self.separate_colour_plane_flag) self.chroma_format_idc else 0;
        const sub_width_c: u8 = switch (self.chroma_format_idc) {
            0 => 0,
            1 => 2,
            2 => 2,
            3 => 1,
        };
        const crop_unit_x = if (chroma_array_type == 0) 1 else sub_width_c;
        const width_offset = if (self.frame_crop) |rect| (rect.left + rect.right) * @as(u32, crop_unit_x) else 0;

        return (self.pic_width_in_mbs_minus1 + 1) * 16 - width_offset;
    }

    pub fn getHeight(self: *const Sps) u32 {
        const chroma_array_type = if (!self.separate_colour_plane_flag) self.chroma_format_idc else 0;
        const sub_height_c: u8 = switch (self.chroma_format_idc) {
            0 => 0,
            1 => 2,
            2 => 1,
            3 => 1,
        };
        const crop_unit_y: u8 = switch (chroma_array_type) {
            0 => @as(u8, 2) - @intFromBool(self.frame_mbs_only_flag),
            else => sub_height_c * (@as(u8, 2) - @intFromBool(self.frame_mbs_only_flag)),
        };
        const height_offset = if (self.frame_crop) |rect| (rect.top + rect.bottom) * @as(u32, crop_unit_y) else 0;

        var height = (self.pic_height_in_map_units_minus1 + 1) * 16;
        height *= @as(u32, 2) - @intFromBool(self.frame_mbs_only_flag);
        height -= height_offset;
        return height;
    }

    fn parseScalingList(bit_reader: *BitReader, size: usize) !void {
        var last_scale: i32 = 8;
        var next_scale: i32 = 8;

        for (0..size) |_| {
            if (next_scale != 0) {
                const delta_scale = try bit_reader.takeExpGolomb(i8);
                next_scale = @rem(last_scale + @as(i32, delta_scale) + 256, 256);
            }
            last_scale = if (next_scale == 0) last_scale else next_scale;
        }
    }

    test "parse valid SPS" {
        const sps_data = &[_]u8{
            0x67, 0x64, 0x00, 0x1F, 0xAC, 0xD9, 0x40,
            0x50, 0x05, 0xBB, 0x01, 0x6C, 0x80, 0x00,
            0x00, 0x03, 0x00, 0x80, 0x00, 0x00, 0x1E,
            0x07, 0x8C, 0x18, 0xCB,
        };

        const sps = try Sps.parse(sps_data[1..]);

        try std.testing.expectEqual(100, sps.profile_idc);
        try std.testing.expectEqual(31, sps.level_idc);
        try std.testing.expectEqual(0, sps.seq_parameter_set_id);
        try std.testing.expectEqual(1, sps.chroma_format_idc);
        try std.testing.expectEqual(0, sps.bit_depth_luma_minus8);
        try std.testing.expectEqual(0, sps.bit_depth_chroma_minus8);
        try std.testing.expectEqual(0, sps.log2_max_frame_num_minus4);
        try std.testing.expectEqual(0, sps.pic_order_cnt_type);
        try std.testing.expectEqual(2, sps.log2_max_pic_order_cnt_lsb_minus4);
        try std.testing.expectEqual(null, sps.pic_order_cnt_type1);
        try std.testing.expectEqual(4, sps.max_num_ref_frames);
        try std.testing.expectEqual(false, sps.gaps_in_frame_num_value_allowed_flag);
        try std.testing.expectEqual(79, sps.pic_width_in_mbs_minus1);
        try std.testing.expectEqual(44, sps.pic_height_in_map_units_minus1);
        try std.testing.expectEqual(true, sps.frame_mbs_only_flag);
        try std.testing.expectEqual(false, sps.mb_adaptive_frame_field_flag);
        try std.testing.expectEqual(true, sps.direct_8x8_inference_flag);
        try std.testing.expectEqual(null, sps.frame_crop);

        try std.testing.expectEqual(1280, sps.getWidth());
        try std.testing.expectEqual(720, sps.getHeight());
    }

    test "parse with scaling list" {
        const data = [_]u8{
            0x66, 0x64, 0x00, 0x32, 0xAD, 0x84, 0x01, 0x0C, 0x20, 0x08,
            0x61, 0x00, 0x43, 0x08, 0x02, 0x18, 0x40, 0x10, 0xC2, 0x00,
            0x84, 0x3B, 0x50, 0x14, 0x00, 0x5A, 0xD3, 0x70, 0x10, 0x10,
            0x14, 0x00, 0x00, 0x03, 0x00, 0x04, 0x00, 0x00, 0x03, 0x00,
            0xA2, 0x10,
        };

        const sps = try Sps.parse(data[1..]);
        try std.testing.expectEqual(100, sps.profile_idc);
        try std.testing.expectEqual(50, sps.level_idc);
        try std.testing.expectEqual(0, sps.seq_parameter_set_id);
        try std.testing.expectEqual(1, sps.chroma_format_idc);
        try std.testing.expectEqual(6, sps.log2_max_frame_num_minus4);
        try std.testing.expectEqual(2, sps.pic_order_cnt_type);
    }

    test "parse with frame cropping" {
        const data = [_]u8{
            0x67, 0x42, 0xC0, 0x28, 0xD9, 0x00, 0x78, 0x02,
            0x27, 0xE5, 0x84, 0x00, 0x00, 0x03, 0x00, 0x04,
            0x00, 0x00, 0x03, 0x00, 0xF0, 0x3C, 0x60, 0xC9,
            0x20,
        };

        const sps = try Sps.parse(data[1..]);
        try std.testing.expectEqual(66, sps.profile_idc);
        try std.testing.expectEqual(40, sps.level_idc);
        try std.testing.expectEqual(0, sps.seq_parameter_set_id);

        try std.testing.expect(sps.frame_crop != null);
        try std.testing.expect(std.meta.eql(sps.frame_crop.?, .{
            .left = 0,
            .right = 0,
            .top = 0,
            .bottom = 4,
        }));

        try std.testing.expectEqual(1920, sps.getWidth());
        try std.testing.expectEqual(1080, sps.getHeight());
    }
};

/// Represents the AVCDecoderConfigurationRecord structure as defined in ISO/IEC 14496-15 (Carriage of network abstraction layer (NAL)
/// unit in the ISO base media file format).
pub const DecoderConfigurationRecord = struct {
    avc_profile_indication: u8,
    profile_compatibility: u8,
    avc_level_indication: u8,
    length_size: u8,

    pub fn initFromSps(sps: *const Sps) DecoderConfigurationRecord {
        return DecoderConfigurationRecord{
            .avc_profile_indication = sps.profile_idc,
            .profile_compatibility = sps.constraint_set_flags,
            .avc_level_indication = sps.level_idc,
            .length_size = 4,
        };
    }

    pub fn parse(data: []const u8) !DecoderConfigurationRecord {
        var reader = std.Io.Reader.fixed(data);
        _ = try reader.takeByte();

        return DecoderConfigurationRecord{
            .avc_profile_indication = try reader.takeByte(),
            .profile_compatibility = try reader.takeByte(),
            .avc_level_indication = try reader.takeByte(),
            .length_size = (try reader.takeByte() & 0x03) + 1,
        };
    }

    pub fn write(
        self: *const DecoderConfigurationRecord,
        sps: []const []const u8,
        pps: []const []const u8,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try writer.writeByte(1); // configurationVersion
        try writer.writeByte(self.avc_profile_indication);
        try writer.writeByte(self.profile_compatibility);
        try writer.writeByte(self.avc_level_indication);
        try writer.writeByte(0xFC | (self.length_size - 1));

        var sps_count: u8 = @intCast(sps.len);
        sps_count |= 0xE0;
        try writer.writeByte(sps_count);
        for (sps) |sps_data| {
            try writer.writeInt(u16, @intCast(sps_data.len), .big);
            try writer.writeAll(sps_data);
        }

        try writer.writeByte(@intCast(pps.len));
        for (pps) |pps_data| {
            try writer.writeInt(u16, @intCast(pps_data.len), .big);
            try writer.writeAll(pps_data);
        }
    }

    test "parse valid configuration" {
        const data = [_]u8{ 1, 100, 0, 40, 0xFF, 0x00 };
        const config = try DecoderConfigurationRecord.parse(&data);

        try std.testing.expect(config.avc_profile_indication == 100);
        try std.testing.expect(config.avc_level_indication == 40);
        try std.testing.expect(config.length_size == 4);
        try std.testing.expect(config.profile_compatibility == 0);
    }

    test "write produces correct byte layout" {
        const config = DecoderConfigurationRecord{
            .avc_profile_indication = 0x64, // 100
            .profile_compatibility = 0x00,
            .avc_level_indication = 0x28, // 40
            .length_size = 4,
        };
        const sps_nal = [_]u8{ 0xAB, 0xCD };
        const pps_nal = [_]u8{0xEF};
        const sps_list = [_][]const u8{&sps_nal};
        const pps_list = [_][]const u8{&pps_nal};

        var buf: [64]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buf);
        try config.write(&sps_list, &pps_list, &writer);

        const expected = [_]u8{
            0x01, // configurationVersion
            0x64, // avc_profile_indication
            0x00, // profile_compatibility
            0x28, // avc_level_indication
            0xFF, // 0xFC | (4-1)
            0xE1, // 0xE0 | numSPS=1
            0x00, 0x02, // SPS length
            0xAB, 0xCD, // SPS data
            0x01, // numPPS=1
            0x00, 0x01, // PPS length
            0xEF, // PPS data
        };
        try std.testing.expectEqualSlices(u8, &expected, writer.buffered());
    }

    test "write with empty SPS and PPS lists" {
        const config = DecoderConfigurationRecord{
            .avc_profile_indication = 0x42,
            .profile_compatibility = 0x00,
            .avc_level_indication = 0x1E,
            .length_size = 1,
        };

        var buf: [64]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buf);
        try config.write(&.{}, &.{}, &writer);

        const expected = [_]u8{
            0x01, // configurationVersion
            0x42, // avc_profile_indication
            0x00, // profile_compatibility
            0x1E, // avc_level_indication
            0xFC, // 0xFC | (1-1)
            0xE0, // 0xE0 | numSPS=0
            0x00, // numPPS=0
        };
        try std.testing.expectEqualSlices(u8, &expected, writer.buffered());
    }

    test "write then parse round-trip" {
        const original = DecoderConfigurationRecord{
            .avc_profile_indication = 0x64,
            .profile_compatibility = 0xC0,
            .avc_level_indication = 0x28,
            .length_size = 2,
        };

        var buf: [64]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buf);
        try original.write(&.{}, &.{}, &writer);

        const parsed = try DecoderConfigurationRecord.parse(writer.buffered());
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
};

const ParameterSetReader = struct {
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
}
