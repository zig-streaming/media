const std = @import("std");

const tag_size = 3;
const frame_tag_size = 10;
const start_code = 0x9d012a;

pub const Tag = packed struct {
    frame_type: u1,
    version: u3,
    show_frame: bool,
    size: u19,
};

/// Represents a VP8 framee tag of the uncompressed data chunk.
///
/// This struct is used to get frame type and width/height of the frame.
pub const FrameTag = struct {
    tag: Tag,
    width: ?u16 = null,
    height: ?u16 = null,

    pub const Error = error{
        InvalidStartCode,
    };

    pub fn parse(data: []const u8) Error!FrameTag {
        std.debug.assert(data.len >= tag_size);
        var frame_tag: FrameTag = .{ .tag = undefined };
        frame_tag.tag = @bitCast(std.mem.readInt(u24, data[0..tag_size], .little));

        if (frame_tag.tag.frame_type == 0) {
            std.debug.assert(data.len >= frame_tag_size);
            if (std.mem.readInt(u24, data[tag_size .. tag_size + 3], .big) != start_code) {
                return error.InvalidStartCode;
            }

            frame_tag.width = std.mem.readInt(u16, data[tag_size + 3 .. tag_size + 5], .little) & 0x3FFF;
            frame_tag.height = std.mem.readInt(u16, data[tag_size + 5 .. tag_size + 7], .little) & 0x3FFF;
        }

        return frame_tag;
    }

    pub inline fn isKeyframe(self: *const FrameTag) bool {
        return self.tag.frame_type == 0;
    }
};

test "FrameHeader: parse keyframe" {
    const data = [_]u8{
        0xd0, 0x5a, 0x00, 0x9d, 0x01,
        0x2a, 0x40, 0x01, 0xf0, 0x00,
        0x00, 0x07, 0x08, 0x85, 0x85,
        0x88, 0x85, 0x84, 0x88, 0x02,
    };

    const frame_tag = try FrameTag.parse(&data);
    try std.testing.expect(frame_tag.isKeyframe());
    try std.testing.expect(frame_tag.tag.show_frame);
    try std.testing.expectEqual(0, frame_tag.tag.version);

    try std.testing.expectEqual(320, frame_tag.width.?);
    try std.testing.expectEqual(240, frame_tag.height.?);
}

test "FrameHeader: parse interframe" {
    const data = [_]u8{
        0xF1, 0x0D, 0x00, 0x03, 0x10, 0x20,
        0x00, 0x1C, 0xC2, 0x4B,
    };

    const frame_tag = try FrameTag.parse(&data);
    try std.testing.expect(!frame_tag.isKeyframe());
    try std.testing.expect(frame_tag.tag.show_frame);
    try std.testing.expectEqual(0, frame_tag.tag.version);

    try std.testing.expect(frame_tag.width == null);
    try std.testing.expect(frame_tag.height == null);
}
