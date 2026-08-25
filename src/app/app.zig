//! Stage 2: application state.

pub const datefmt = @import("datefmt.zig");
pub const state = @import("state.zig");
pub const notion = @import("notion.zig");

test {
    _ = datefmt;
    _ = state;
    _ = notion;
}
