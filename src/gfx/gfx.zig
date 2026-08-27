//! Stage 3: rendering.

const std = @import("std");
const c = @import("c.zig");

pub const color = @import("color.zig");
pub const surface = @import("surface.zig");
pub const font = @import("font.zig");
pub const fonts = @import("fonts.zig");
pub const shapes = @import("shapes.zig");
pub const painter = @import("painter.zig");
pub const golden = @import("golden.zig");

pub const Rgba = color.Rgba;
pub const Rect = surface.Rect;
pub const Surface = surface.Surface;
pub const palette = color.palette;
pub const Painter = painter.Painter;
pub const Segment = shapes.Segment;
pub const FontStack = font.FontStack;
pub const Fonts = fonts.Fonts;
pub const Family = fonts.Family;

test {
    _ = color;
    _ = surface;
    _ = font;
    _ = fonts;
    _ = shapes;
    _ = painter;
    _ = golden;
    _ = @import("golden_test.zig");
}

test "the text stack links and initializes" {
    var lib: c.ft.FT_Library = null;
    try std.testing.expectEqual(@as(c_int, 0), c.ft.FT_Init_FreeType(&lib));
    defer _ = c.ft.FT_Done_FreeType(lib);

    var major: c.ft.FT_Int = 0;
    var minor: c.ft.FT_Int = 0;
    var patch: c.ft.FT_Int = 0;
    c.ft.FT_Library_Version(lib, &major, &minor, &patch);
    try std.testing.expect(major >= 2);

    const hb_version = std.mem.sliceTo(c.hb.hb_version_string(), 0);
    try std.testing.expect(hb_version.len > 0);
    try std.testing.expect(hb_version[0] >= '1');
}
