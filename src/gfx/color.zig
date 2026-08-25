//! Colors and the Nova palette.
//!
//! The tokens come from `src/app.css`. The TypeScript build declared a
//! `--danger` variable it never used and hardcoded three different reds
//! instead, and its "danger" context-menu style was actually amber
//! (`ContextMenu.svelte:135`). They are unified here.

const std = @import("std");

pub const Rgba = extern struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8 = 255,

    pub fn hex(comptime s: []const u8) Rgba {
        const h = if (s[0] == '#') s[1..] else s;
        return .{
            .r = parseByte(h[0..2]),
            .g = parseByte(h[2..4]),
            .b = parseByte(h[4..6]),
            .a = if (h.len >= 8) parseByte(h[6..8]) else 255,
        };
    }

    fn parseByte(comptime s: []const u8) u8 {
        return std.fmt.parseInt(u8, s, 16) catch unreachable;
    }

    pub fn withAlpha(self: Rgba, a: u8) Rgba {
        return .{ .r = self.r, .g = self.g, .b = self.b, .a = a };
    }

    /// Alpha as a 0-255 fraction of the existing alpha.
    pub fn scaleAlpha(self: Rgba, factor: f32) Rgba {
        const a: f32 = @floatFromInt(self.a);
        return self.withAlpha(@intFromFloat(std.math.clamp(a * factor, 0, 255)));
    }

    pub fn eql(a: Rgba, b: Rgba) bool {
        return a.r == b.r and a.g == b.g and a.b == b.b and a.a == b.a;
    }
};

/// Source-over compositing of `src` onto `dst`, both non-premultiplied.
pub fn blend(dst: Rgba, src: Rgba) Rgba {
    if (src.a == 255) return src;
    if (src.a == 0) return dst;

    const sa: u32 = src.a;
    const ia: u32 = 255 - sa;

    // The destination is opaque in practice (the app paints a background
    // first), so a straight lerp is correct and avoids a divide.
    return .{
        .r = @intCast((@as(u32, src.r) * sa + @as(u32, dst.r) * ia + 127) / 255),
        .g = @intCast((@as(u32, src.g) * sa + @as(u32, dst.g) * ia + 127) / 255),
        .b = @intCast((@as(u32, src.b) * sa + @as(u32, dst.b) * ia + 127) / 255),
        .a = @intCast(sa + (@as(u32, dst.a) * ia + 127) / 255),
    };
}

/// The dark palette. Nova has never had a light theme.
pub const palette = struct {
    pub const bg_0 = Rgba.hex("1e2227"); // editor canvas
    pub const bg_1 = Rgba.hex("272b31"); // sidebar, tab bar, footer, dialogs
    pub const bg_2 = Rgba.hex("2d3138"); // hover surfaces, buttons
    pub const bg_3 = Rgba.hex("353a42"); // borders, resizer
    pub const fg_0 = Rgba.hex("e6e6e6"); // primary text
    pub const fg_1 = Rgba.hex("b9bcc1"); // secondary
    pub const fg_2 = Rgba.hex("7c828a"); // muted
    pub const accent = Rgba.hex("7aa2f7");
    pub const accent_dim = Rgba.hex("3d5a8a");
    pub const dirty = Rgba.hex("e0af68"); // unsaved dot, warnings
    pub const danger = Rgba.hex("f7768e");

    /// Selection fill: accent at 25% (`rgba(122,162,247,.25)`).
    pub const selection = accent.withAlpha(64);
    /// Find match fill and outline.
    pub const match = Rgba.hex("f0c800").withAlpha(71);
    pub const match_outline = Rgba.hex("f0c800").withAlpha(140);
    pub const match_active = Rgba.hex("ff8c00").withAlpha(115);
    pub const match_active_outline = Rgba.hex("ff8c00").withAlpha(230);
    /// Modal backdrop (`rgba(0,0,0,.5)`).
    pub const backdrop = Rgba{ .r = 0, .g = 0, .b = 0, .a = 128 };
    pub const backdrop_light = Rgba{ .r = 0, .g = 0, .b = 0, .a = 89 };
};

const testing = std.testing;

test "hex parsing" {
    const c = Rgba.hex("1e2227");
    try testing.expectEqual(@as(u8, 0x1e), c.r);
    try testing.expectEqual(@as(u8, 0x22), c.g);
    try testing.expectEqual(@as(u8, 0x27), c.b);
    try testing.expectEqual(@as(u8, 255), c.a);

    const t = Rgba.hex("ff000080");
    try testing.expectEqual(@as(u8, 0x80), t.a);
}

test "blending" {
    const black = Rgba{ .r = 0, .g = 0, .b = 0 };
    const white = Rgba{ .r = 255, .g = 255, .b = 255 };

    try testing.expect(blend(black, white).eql(white));
    try testing.expect(blend(black, white.withAlpha(0)).eql(black));

    const half = blend(black, white.withAlpha(128));
    try testing.expectEqual(@as(u8, 128), half.r);
}

test "the palette matches app.css" {
    try testing.expect(palette.bg_0.eql(Rgba{ .r = 0x1e, .g = 0x22, .b = 0x27 }));
    try testing.expect(palette.accent.eql(Rgba{ .r = 0x7a, .g = 0xa2, .b = 0xf7 }));
    try testing.expectEqual(@as(u8, 64), palette.selection.a);
}
