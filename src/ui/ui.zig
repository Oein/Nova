//! Stage 3: the user interface.

pub const event = @import("event.zig");
pub const theme = @import("theme.zig");
pub const editor_view = @import("editor_view.zig");
pub const chrome = @import("chrome.zig");
pub const overlays = @import("overlays.zig");
pub const find = @import("find.zig");
pub const root = @import("root.zig");

pub const Root = root.Root;
pub const Event = event.Event;
pub const Request = event.Request;

test {
    _ = event;
    _ = theme;
    _ = editor_view;
    _ = chrome;
    _ = overlays;
    _ = find;
    _ = root;
}
