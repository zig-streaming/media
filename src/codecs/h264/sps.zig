//! Represents the Sequence Parameter Set (SPS) of an H.264 stream.

const std = @import("std");
const BitReader = @import("../../io.zig").BitReader;
const ParameterSetReader = @import("../h264.zig").ParameterSetReader;

const Sps = @This();

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
                    try parseScalingList(&bit_reader, if (i < 6) 16 else 64);
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

const testing = std.testing;

test "parse valid SPS" {
    const sps_data = &[_]u8{
        0x67, 0x64, 0x00, 0x1F, 0xAC, 0xD9, 0x40,
        0x50, 0x05, 0xBB, 0x01, 0x6C, 0x80, 0x00,
        0x00, 0x03, 0x00, 0x80, 0x00, 0x00, 0x1E,
        0x07, 0x8C, 0x18, 0xCB,
    };

    const sps = try Sps.parse(sps_data[1..]);

    try testing.expectEqual(100, sps.profile_idc);
    try testing.expectEqual(31, sps.level_idc);
    try testing.expectEqual(0, sps.seq_parameter_set_id);
    try testing.expectEqual(1, sps.chroma_format_idc);
    try testing.expectEqual(0, sps.bit_depth_luma_minus8);
    try testing.expectEqual(0, sps.bit_depth_chroma_minus8);
    try testing.expectEqual(0, sps.log2_max_frame_num_minus4);
    try testing.expectEqual(0, sps.pic_order_cnt_type);
    try testing.expectEqual(2, sps.log2_max_pic_order_cnt_lsb_minus4);
    try testing.expectEqual(null, sps.pic_order_cnt_type1);
    try testing.expectEqual(4, sps.max_num_ref_frames);
    try testing.expectEqual(false, sps.gaps_in_frame_num_value_allowed_flag);
    try testing.expectEqual(79, sps.pic_width_in_mbs_minus1);
    try testing.expectEqual(44, sps.pic_height_in_map_units_minus1);
    try testing.expectEqual(true, sps.frame_mbs_only_flag);
    try testing.expectEqual(false, sps.mb_adaptive_frame_field_flag);
    try testing.expectEqual(true, sps.direct_8x8_inference_flag);
    try testing.expectEqual(null, sps.frame_crop);

    try testing.expectEqual(1280, sps.getWidth());
    try testing.expectEqual(720, sps.getHeight());
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
    try testing.expectEqual(100, sps.profile_idc);
    try testing.expectEqual(50, sps.level_idc);
    try testing.expectEqual(0, sps.seq_parameter_set_id);
    try testing.expectEqual(1, sps.chroma_format_idc);
    try testing.expectEqual(6, sps.log2_max_frame_num_minus4);
    try testing.expectEqual(2, sps.pic_order_cnt_type);
}

test "parse with frame cropping" {
    const data = [_]u8{
        0x67, 0x42, 0xC0, 0x28, 0xD9, 0x00, 0x78, 0x02,
        0x27, 0xE5, 0x84, 0x00, 0x00, 0x03, 0x00, 0x04,
        0x00, 0x00, 0x03, 0x00, 0xF0, 0x3C, 0x60, 0xC9,
        0x20,
    };

    const sps = try Sps.parse(data[1..]);
    try testing.expectEqual(66, sps.profile_idc);
    try testing.expectEqual(40, sps.level_idc);
    try testing.expectEqual(0, sps.seq_parameter_set_id);

    try testing.expect(sps.frame_crop != null);
    try testing.expect(std.meta.eql(sps.frame_crop.?, .{
        .left = 0,
        .right = 0,
        .top = 0,
        .bottom = 4,
    }));

    try testing.expectEqual(1920, sps.getWidth());
    try testing.expectEqual(1080, sps.getHeight());
}
