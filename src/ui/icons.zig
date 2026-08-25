//! The icon outlines, transcribed from the original's inline SVG.
//!
//! Every one was a `<svg viewBox="0 0 16 16">` with `stroke-width="1.4"` and
//! round caps, so the coordinates below are the `d` attributes read straight
//! across. Curves are the one liberty taken: at twelve pixels the trash bin's
//! two corner radii are a pixel each, so they are drawn as corners.
//!
//! The chevrons and the unsaved dot were text in the original (`▸`, `▾`, `●`).
//! They are drawn here instead because a bundled monospace font is not obliged
//! to have those glyphs, and a missing one shows up as a tofu box.

const gfx = @import("gfx");

const Segment = gfx.Segment;
const pi = @import("std").math.pi;

fn line(x0: f32, y0: f32, x1: f32, y1: f32) Segment {
    return .{ .line = .{ .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1 } };
}

fn arc(cx: f32, cy: f32, r: f32, a0: f32, a1: f32) Segment {
    return .{ .arc = .{ .cx = cx, .cy = cy, .r = r, .a0 = a0, .a1 = a1 } };
}

/// A waste basket: lid, handle, tapered body, two ribs.
pub const trash: []const Segment = &.{
    line(2.5, 4, 13.5, 4),
    line(6, 4, 6, 2.5),
    line(6, 2.5, 10, 2.5),
    line(10, 2.5, 10, 4),
    line(3.5, 4, 4.3, 13.9),
    line(4.3, 13.9, 11.7, 13.9),
    line(11.7, 13.9, 12.5, 4),
    line(6.5, 7, 6.5, 11),
    line(9.5, 7, 9.5, 11),
};

/// A gear: a hub and eight teeth.
pub const settings: []const Segment = &.{
    arc(8, 8, 2, 0, 2 * pi),
    line(8, 1.5, 8, 3.1),
    line(8, 12.9, 8, 14.5),
    line(3.4, 3.4, 4.5, 4.5),
    line(11.5, 11.5, 12.6, 12.6),
    line(1.5, 8, 3.1, 8),
    line(12.9, 8, 14.5, 8),
    line(3.4, 12.6, 4.5, 11.5),
    line(11.5, 4.5, 12.6, 3.4),
};

/// Two arrows chasing each other round a circle.
pub const sync: []const Segment = &.{
    arc(8, 8, 5.5, 0, 3 * pi / 4.0),
    arc(8, 8, 5.5, pi, -pi / 4.0),
    line(11.9, 1.6, 11.9, 4.1),
    line(11.9, 4.1, 9.4, 4.1),
    line(4.1, 14.4, 4.1, 11.9),
    line(4.1, 11.9, 6.6, 11.9),
};

/// An expanded group.
pub const chevron_down: []const Segment = &.{
    line(4.5, 6.5, 8, 10),
    line(8, 10, 11.5, 6.5),
};

/// A collapsed group.
pub const chevron_right: []const Segment = &.{
    line(6.5, 4.5, 10, 8),
    line(10, 8, 6.5, 11.5),
};
