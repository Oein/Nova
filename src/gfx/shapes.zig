//! Rounded rectangles and stroked paths.
//!
//! The original leaned on CSS for both: `border-radius` on every panel and
//! button, and inline SVG for the bottom-bar icons. Neither survives the move
//! off a browser, and square corners and missing icons are the most visible
//! difference between the two builds.
//!
//! Everything here is drawn from a signed distance function rather than by
//! scan-converting edges: coverage falls out as `0.5 - distance`, which
//! antialiases corners and diagonal strokes for free and keeps round joins and
//! caps from needing any special case. Icons are a dozen segments each, so the
//! per-pixel cost of evaluating them is irrelevant.

const std = @import("std");
const color = @import("color.zig");
const surface = @import("surface.zig");

const Rgba = color.Rgba;
const Rect = surface.Rect;
const Surface = surface.Surface;

/// One piece of an icon outline, in the icon's own 16x16 coordinate space.
pub const Segment = union(enum) {
    line: struct { x0: f32, y0: f32, x1: f32, y1: f32 },
    /// Angles in radians, measured clockwise from three o'clock in screen
    /// coordinates (y grows downward), sweeping from `a0` to `a1`.
    arc: struct { cx: f32, cy: f32, r: f32, a0: f32, a1: f32 },
};

/// A `<polyline>`: consecutive points joined by segments.
pub fn polyline(comptime pts: []const [2]f32) [pts.len - 1]Segment {
    var out: [pts.len - 1]Segment = undefined;
    for (0..pts.len - 1) |i| {
        out[i] = .{ .line = .{
            .x0 = pts[i][0],
            .y0 = pts[i][1],
            .x1 = pts[i + 1][0],
            .y1 = pts[i + 1][1],
        } };
    }
    return out;
}

fn coverageOf(distance: f32) u8 {
    const a = std.math.clamp(0.5 - distance, 0, 1);
    return @intFromFloat(@round(a * 255));
}

/// Signed distance to a box with corner radius `r`, from a point relative to
/// the box centre. `hx`/`hy` are the half-extents.
fn sdRoundBox(px: f32, py: f32, hx: f32, hy: f32, r: f32) f32 {
    const qx = @abs(px) - hx + r;
    const qy = @abs(py) - hy + r;
    const outside = @sqrt(@max(qx, 0) * @max(qx, 0) + @max(qy, 0) * @max(qy, 0));
    return outside + @min(@max(qx, qy), 0) - r;
}

/// Fill `rect` with corners rounded by `radius`.
pub fn fillRoundRect(surf: *Surface, clip: Rect, rect: Rect, radius: f32, c: Rgba) void {
    if (rect.w <= 0 or rect.h <= 0) return;
    const area = rect.intersect(clip);
    if (area.isEmpty()) return;

    const hx = @as(f32, @floatFromInt(rect.w)) / 2;
    const hy = @as(f32, @floatFromInt(rect.h)) / 2;
    const r = std.math.clamp(radius, 0, @min(hx, hy));
    const cx = @as(f32, @floatFromInt(rect.x)) + hx;
    const cy = @as(f32, @floatFromInt(rect.y)) + hy;

    var y = area.y;
    while (y < area.bottom()) : (y += 1) {
        const py = @as(f32, @floatFromInt(y)) + 0.5 - cy;
        var x = area.x;
        while (x < area.right()) : (x += 1) {
            const px = @as(f32, @floatFromInt(x)) + 0.5 - cx;
            const cov = coverageOf(sdRoundBox(px, py, hx, hy, r));
            if (cov != 0) surf.blendPixel(x, y, c, cov);
        }
    }
}

/// Outline `rect` with corners rounded by `radius`, `width` pixels thick,
/// drawn inside the rectangle.
pub fn strokeRoundRect(
    surf: *Surface,
    clip: Rect,
    rect: Rect,
    radius: f32,
    width: f32,
    c: Rgba,
) void {
    if (rect.w <= 0 or rect.h <= 0) return;
    const area = rect.intersect(clip);
    if (area.isEmpty()) return;

    const hx = @as(f32, @floatFromInt(rect.w)) / 2;
    const hy = @as(f32, @floatFromInt(rect.h)) / 2;
    const r = std.math.clamp(radius, 0, @min(hx, hy));
    const cx = @as(f32, @floatFromInt(rect.x)) + hx;
    const cy = @as(f32, @floatFromInt(rect.y)) + hy;
    const half = width / 2;

    var y = area.y;
    while (y < area.bottom()) : (y += 1) {
        const py = @as(f32, @floatFromInt(y)) + 0.5 - cy;
        var x = area.x;
        while (x < area.right()) : (x += 1) {
            const px = @as(f32, @floatFromInt(x)) + 0.5 - cx;
            // The border sits just inside the edge, as CSS draws it.
            const d = @abs(sdRoundBox(px, py, hx - half, hy - half, @max(r - half, 0))) - half;
            const cov = coverageOf(d);
            if (cov != 0) surf.blendPixel(x, y, c, cov);
        }
    }
}

fn distanceToSegment(seg: Segment, px: f32, py: f32) f32 {
    switch (seg) {
        .line => |l| {
            const vx = l.x1 - l.x0;
            const vy = l.y1 - l.y0;
            const wx = px - l.x0;
            const wy = py - l.y0;
            const len2 = vx * vx + vy * vy;
            const t = if (len2 <= 0) 0 else std.math.clamp((wx * vx + wy * vy) / len2, 0, 1);
            const dx = wx - t * vx;
            const dy = wy - t * vy;
            return @sqrt(dx * dx + dy * dy);
        },
        .arc => |a| {
            const dx = px - a.cx;
            const dy = py - a.cy;
            const len = @sqrt(dx * dx + dy * dy);

            const ang = std.math.atan2(dy, dx);
            const tau = std.math.tau;
            // Normalize both the point and the sweep to [0, tau) starting at
            // `a0`, so "inside the sweep" is a single comparison.
            var rel = @mod(ang - a.a0, tau);
            if (rel < 0) rel += tau;
            var sweep = @mod(a.a1 - a.a0, tau);
            if (sweep <= 0) sweep += tau;
            if (rel <= sweep) return @abs(len - a.r);

            // Outside the sweep: the nearest point is whichever end is closer.
            const e0x = a.cx + a.r * @cos(a.a0);
            const e0y = a.cy + a.r * @sin(a.a0);
            const e1x = a.cx + a.r * @cos(a.a1);
            const e1y = a.cy + a.r * @sin(a.a1);
            const d0 = @sqrt((px - e0x) * (px - e0x) + (py - e0y) * (py - e0y));
            const d1 = @sqrt((px - e1x) * (px - e1x) + (py - e1y) * (py - e1y));
            return @min(d0, d1);
        },
    }
}

/// Draw `segments` -- given in a `viewbox` x `viewbox` space -- scaled to fill
/// `dest`, stroked `width` pixels thick with round caps and joins.
pub fn strokePath(
    surf: *Surface,
    clip: Rect,
    dest: Rect,
    viewbox: f32,
    segments: []const Segment,
    width: f32,
    c: Rgba,
) void {
    if (segments.len == 0 or dest.w <= 0 or dest.h <= 0) return;
    const scale = @as(f32, @floatFromInt(@min(dest.w, dest.h))) / viewbox;
    const half = @max(width, 0.6) * scale / 2;

    // Pad by the stroke so round caps are not shaved off at the edges.
    const pad: i32 = @intFromFloat(@ceil(half + 1));
    const padded = Rect{
        .x = dest.x - pad,
        .y = dest.y - pad,
        .w = dest.w + 2 * pad,
        .h = dest.h + 2 * pad,
    };
    const area = padded.intersect(clip);
    if (area.isEmpty()) return;

    const ox = @as(f32, @floatFromInt(dest.x));
    const oy = @as(f32, @floatFromInt(dest.y));

    var y = area.y;
    while (y < area.bottom()) : (y += 1) {
        const py = (@as(f32, @floatFromInt(y)) + 0.5 - oy) / scale;
        var x = area.x;
        while (x < area.right()) : (x += 1) {
            const px = (@as(f32, @floatFromInt(x)) + 0.5 - ox) / scale;

            var d: f32 = std.math.floatMax(f32);
            for (segments) |seg| d = @min(d, distanceToSegment(seg, px, py));

            const cov = coverageOf(d * scale - half);
            if (cov != 0) surf.blendPixel(x, y, c, cov);
        }
    }
}

// -- tests -------------------------------------------------------------------

const testing = std.testing;

fn inkAt(s: *const Surface, x: i32, y: i32, bg: Rgba) bool {
    const px = s.at(x, y);
    return px.r != bg.r or px.g != bg.g or px.b != bg.b;
}

test "a rounded rectangle keeps its middle and loses its corners" {
    var s = try Surface.init(testing.allocator, 40, 40);
    defer s.deinit();
    const bg = Rgba{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const fg = Rgba{ .r = 255, .g = 255, .b = 255, .a = 255 };
    s.clear(bg);

    fillRoundRect(&s, s.bounds(), .{ .x = 4, .y = 4, .w = 32, .h = 32 }, 8, fg);

    try testing.expect(inkAt(&s, 20, 20, bg)); // centre
    try testing.expect(inkAt(&s, 20, 5, bg)); // top edge
    try testing.expect(!inkAt(&s, 4, 4, bg)); // corner is cut away
    try testing.expect(!inkAt(&s, 35, 35, bg));
}

test "a radius of zero is a plain rectangle" {
    var s = try Surface.init(testing.allocator, 20, 20);
    defer s.deinit();
    const bg = Rgba{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const fg = Rgba{ .r = 255, .g = 255, .b = 255, .a = 255 };
    s.clear(bg);

    fillRoundRect(&s, s.bounds(), .{ .x = 2, .y = 2, .w = 10, .h = 10 }, 0, fg);
    try testing.expect(inkAt(&s, 2, 2, bg));
    try testing.expect(inkAt(&s, 11, 11, bg));
    try testing.expect(!inkAt(&s, 12, 12, bg));
}

test "a stroked path puts ink on the line and not beside it" {
    var s = try Surface.init(testing.allocator, 40, 40);
    defer s.deinit();
    const bg = Rgba{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const fg = Rgba{ .r = 255, .g = 255, .b = 255, .a = 255 };
    s.clear(bg);

    const segs = [_]Segment{.{ .line = .{ .x0 = 2, .y0 = 8, .x1 = 14, .y1 = 8 } }};
    strokePath(&s, s.bounds(), .{ .x = 0, .y = 0, .w = 32, .h = 32 }, 16, &segs, 1.4, fg);

    try testing.expect(inkAt(&s, 16, 16, bg)); // on the line
    try testing.expect(!inkAt(&s, 16, 26, bg)); // well below it
}

test "an arc draws over its sweep and not outside it" {
    var s = try Surface.init(testing.allocator, 64, 64);
    defer s.deinit();
    const bg = Rgba{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const fg = Rgba{ .r = 255, .g = 255, .b = 255, .a = 255 };
    s.clear(bg);

    // The right half of a circle: from noon clockwise to six o'clock.
    const segs = [_]Segment{.{ .arc = .{
        .cx = 8,
        .cy = 8,
        .r = 6,
        .a0 = -std.math.pi / 2.0,
        .a1 = std.math.pi / 2.0,
    } }};
    strokePath(&s, s.bounds(), .{ .x = 0, .y = 0, .w = 64, .h = 64 }, 16, &segs, 1.4, fg);

    try testing.expect(inkAt(&s, 56, 32, bg)); // right of centre, on the arc
    try testing.expect(!inkAt(&s, 8, 32, bg)); // left of centre, off it
}
