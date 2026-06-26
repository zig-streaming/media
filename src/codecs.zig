pub const h264 = @import("codecs/h264.zig");
pub const vp8 = @import("codecs/vp8.zig");

test {
    _ = @import("codecs/h264.zig");
    _ = @import("codecs/vp8.zig");
}
