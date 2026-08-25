//! Per-OS glue. Everything here has a different implementation, or a different
//! availability, on macOS, Windows and Linux.

pub const localtime = @import("localtime.zig");
pub const shell = @import("shell.zig");
pub const menu_macos = @import("menu_macos.zig");

test {
    _ = localtime;
    _ = shell;
    _ = menu_macos;
}
