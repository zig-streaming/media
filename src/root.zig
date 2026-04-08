pub const core = @import("core");
pub const rtp = @import("rtp");

test {
    _ = @import("core/core.zig");
    _ = @import("rtp/rtp.zig");
}
