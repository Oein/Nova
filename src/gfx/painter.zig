//! Drawing operations on a `Surface`.
//!
//! The editor's text is laid out on the same monospace cell grid `core/wrap.zig`
//! computes with, so the painter advances by cell width rather than by the
//! font's own advances. That is what keeps the caret, the selection rectangles
//! and the glyphs on exactly the same coordinates -- the disagreement between
//! those two that the TypeScript build could never fully settle.

const std = @import("std");
const core = @import("core");
const color = @import("color.zig");
const surface = @import("surface.zig");
const font = @import("font.zig");

const Rgba = color.Rgba;
const Rect = surface.Rect;
const Surface = surface.Surface;
const FontStack = font.FontStack;

pub const Painter = struct {
    surf: *Surface,
    fonts: *FontStack,
    clip: Rect,

    pub fn init(surf: *Surface, fonts: *FontStack) Painter {
        return .{ .surf = surf, .fonts = fonts, .clip = surf.bounds() };
    }

    /// Narrow the clip, returning the previous one so the caller can restore it.
    pub fn pushClip(self: *Painter, rect: Rect) Rect {
        const previous = self.clip;
        self.clip = self.clip.intersect(rect);
        return previous;
    }

    pub fn popClip(self: *Painter, previous: Rect) void {
        self.clip = previous;
    }

    pub fn fill(self: *Painter, rect: Rect, c: Rgba) void {
        self.surf.fillRect(rect, self.clip, c);
    }

    pub fn stroke(self: *Painter, rect: Rect, c: Rgba) void {
        self.surf.strokeRect(rect, self.clip, c);
    }

    pub fn clear(self: *Painter, c: Rgba) void {
        self.surf.fillRect(self.surf.bounds(), self.clip, c);
    }

    /// Cell metrics, as `core/wrap.zig` wants them.
    pub fn wrapMetrics(self: *const Painter, tab_size: u8) core.wrap.Metrics {
        return .{
            .ch_width = self.fonts.metrics.ch_width,
            .cjk_width = self.fonts.metrics.cjk_width,
            .tab_size = tab_size,
        };
    }

    /// Blit one glyph with its top-left at `(pen_x, baseline_y)` adjusted by the
    /// glyph's bearings.
    fn blitGlyph(self: *Painter, g: font.Glyph, pen_x: f64, baseline_y: f64, c: Rgba) void {
        if (g.isEmpty()) return;
        const cov = self.fonts.coverageOf(g);

        const x0: i32 = @intFromFloat(@round(pen_x)) ;
        const y0: i32 = @intFromFloat(@round(baseline_y));
        const left = x0 + g.left;
        const top = y0 - g.top;

        // Reject early when the glyph cannot touch the clip at all.
        const box = Rect{ .x = left, .y = top, .w = g.width, .h = g.height };
        if (box.intersect(self.clip).isEmpty()) return;

        var row: usize = 0;
        while (row < g.height) : (row += 1) {
            const y = top + @as(i32, @intCast(row));
            if (y < self.clip.y or y >= self.clip.bottom()) continue;
            const line = cov[row * g.width ..][0..g.width];
            var col: usize = 0;
            while (col < g.width) : (col += 1) {
                const x = left + @as(i32, @intCast(col));
                if (x < self.clip.x or x >= self.clip.right()) continue;
                self.surf.blendPixel(x, y, c, line[col]);
            }
        }
    }

    /// Cell width of one grapheme cluster.
    pub fn cellWidth(self: *const Painter, cluster: []const u8) f64 {
        const m = self.fonts.metrics;
        return if (core.width.clusterIsWide(cluster)) m.cjk_width else m.ch_width;
    }

    pub const RunOptions = struct {
        weight: font.Weight = .regular,
        underline: bool = false,
        strike: bool = false,
        /// Tab stop in narrow cells. Tabs advance to the next stop measured
        /// from `start_x`, matching how the editor measures each wrapped
        /// sub-row independently.
        tab_size: u8 = 4,
    };

    /// Draw `text` starting at `x`, with the baseline at `baseline_y`.
    /// Returns the pen position after the run.
    pub fn drawRun(
        self: *Painter,
        x: f64,
        baseline_y: f64,
        text: []const u8,
        c: Rgba,
        opts: RunOptions,
    ) f64 {
        const m = self.fonts.metrics;
        const tab_px = @as(f64, @floatFromInt(opts.tab_size)) * m.ch_width;

        var pen = x;
        var it = core.grapheme.iterate(text);
        while (it.nextCluster()) |g| {
            if (g.text.len == 1 and g.text[0] == '\t') {
                pen = x + (@floor((pen - x) / tab_px) + 1) * tab_px;
                continue;
            }
            const advance = self.cellWidth(g.text);
            if (self.fonts.resolveCluster(g.text)) |resolved| {
                if (self.fonts.glyph(resolved, opts.weight)) |glyph| {
                    self.blitGlyph(glyph, pen, baseline_y, c);
                }
            }
            pen += advance;
        }

        const width = pen - x;
        if (width > 0) {
            if (opts.underline) {
                self.fill(.{
                    .x = @intFromFloat(@round(x)),
                    .y = @intFromFloat(@round(baseline_y + 2)),
                    .w = @intFromFloat(@round(width)),
                    .h = 1,
                }, c);
            }
            if (opts.strike) {
                self.fill(.{
                    .x = @intFromFloat(@round(x)),
                    .y = @intFromFloat(@round(baseline_y - m.ascent * 0.3)),
                    .w = @intFromFloat(@round(width)),
                    .h = 1,
                }, c);
            }
        }
        return pen;
    }

    /// Width `drawRun` would occupy, without drawing.
    pub fn measureRun(self: *const Painter, text: []const u8, tab_size: u8) f64 {
        return core.wrap.advanceTo(text, text.len, .{
            .ch_width = self.fonts.metrics.ch_width,
            .cjk_width = self.fonts.metrics.cjk_width,
            .tab_size = tab_size,
        });
    }

    pub const Align = enum { left, center, right };

    /// Draw a single-line label inside `rect`, vertically centered.
    pub fn drawLabel(
        self: *Painter,
        rect: Rect,
        text: []const u8,
        c: Rgba,
        how: Align,
        opts: RunOptions,
    ) void {
        const m = self.fonts.metrics;
        const width = self.measureRun(text, opts.tab_size);
        const x: f64 = switch (how) {
            .left => @floatFromInt(rect.x),
            .center => @as(f64, @floatFromInt(rect.x)) + (@as(f64, @floatFromInt(rect.w)) - width) / 2,
            .right => @as(f64, @floatFromInt(rect.x + rect.w)) - width,
        };
        const baseline = @as(f64, @floatFromInt(rect.y)) +
            (@as(f64, @floatFromInt(rect.h)) - m.row_height) / 2 + m.ascent;

        const saved = self.pushClip(rect);
        defer self.popClip(saved);
        _ = self.drawRun(x, baseline, text, c, opts);
    }

    /// Draw `text` clipped to `rect`, appending an ellipsis when it does not
    /// fit. Used by the sidebar and tab bar, which both ellipsize.
    pub fn drawEllipsized(
        self: *Painter,
        rect: Rect,
        text: []const u8,
        c: Rgba,
        opts: RunOptions,
    ) void {
        const m = self.fonts.metrics;
        const available: f64 = @floatFromInt(rect.w);
        if (self.measureRun(text, opts.tab_size) <= available) {
            self.drawLabel(rect, text, c, .left, opts);
            return;
        }

        // Trim clusters until the text plus an ellipsis fits.
        const ellipsis = "…";
        const ellipsis_w = self.cellWidth(ellipsis);
        var end: usize = 0;
        var used: f64 = 0;
        var it = core.grapheme.iterate(text);
        while (it.nextCluster()) |g| {
            const w = self.cellWidth(g.text);
            if (used + w + ellipsis_w > available) break;
            used += w;
            end = g.offset + g.text.len;
        }

        const saved = self.pushClip(rect);
        defer self.popClip(saved);
        const baseline = @as(f64, @floatFromInt(rect.y)) +
            (@as(f64, @floatFromInt(rect.h)) - m.row_height) / 2 + m.ascent;
        var pen = self.drawRun(@floatFromInt(rect.x), baseline, text[0..end], c, opts);
        _ = self.drawRun(pen, baseline, ellipsis, c, opts);
        pen = 0;
    }
};

// -- tests -------------------------------------------------------------------

const testing = std.testing;
const palette = color.palette;

/// Count pixels that differ from the background -- a cheap "did anything get
/// drawn, and roughly how much" probe.
fn inkCount(s: *const Surface, bg: Rgba) usize {
    var n: usize = 0;
    for (s.pixels) |px| {
        if (!px.eql(bg)) n += 1;
    }
    return n;
}

const Fixture = struct {
    surf: Surface,
    fonts: FontStack,

    fn init(w: u32, h: u32, px: u32) !Fixture {
        return .{
            .surf = try Surface.init(testing.allocator, w, h),
            .fonts = try FontStack.init(testing.allocator, px),
        };
    }
    fn deinit(self: *Fixture) void {
        self.fonts.deinit();
        self.surf.deinit();
    }
    fn painter(self: *Fixture) Painter {
        return Painter.init(&self.surf, &self.fonts);
    }
};

test "drawing text puts ink on the surface" {
    var f = try Fixture.init(200, 40, 16);
    defer f.deinit();
    var p = f.painter();
    p.clear(palette.bg_0);
    try testing.expectEqual(@as(usize, 0), inkCount(&f.surf, palette.bg_0));

    _ = p.drawRun(4, 20, "Hello", palette.fg_0, .{});
    try testing.expect(inkCount(&f.surf, palette.bg_0) > 20);
}

test "Korean text draws and advances two cells per syllable" {
    var f = try Fixture.init(200, 40, 16);
    defer f.deinit();
    var p = f.painter();
    p.clear(palette.bg_0);

    const end = p.drawRun(0, 24, "안녕", palette.fg_0, .{});
    try testing.expectApproxEqAbs(f.fonts.metrics.cjk_width * 2, end, 0.01);
    try testing.expect(inkCount(&f.surf, palette.bg_0) > 20);
}

test "a run of mixed scripts stays on the cell grid" {
    var f = try Fixture.init(300, 40, 16);
    defer f.deinit();
    var p = f.painter();
    p.clear(palette.bg_0);

    const m = f.fonts.metrics;
    const end = p.drawRun(0, 24, "ab안c", palette.fg_0, .{});
    // 2 narrow + 1 wide + 1 narrow.
    try testing.expectApproxEqAbs(m.ch_width * 3 + m.cjk_width, end, 0.01);
}

test "tabs advance to the next stop, measured from the run start" {
    var f = try Fixture.init(300, 40, 16);
    defer f.deinit();
    var p = f.painter();
    p.clear(palette.bg_0);
    const m = f.fonts.metrics;

    // A tab at the very start fills one whole stop.
    try testing.expectApproxEqAbs(
        m.ch_width * 4,
        p.drawRun(0, 24, "\t", palette.fg_0, .{ .tab_size = 4 }),
        0.01,
    );
    // `ab\t` fills to the same stop.
    try testing.expectApproxEqAbs(
        m.ch_width * 4,
        p.drawRun(0, 24, "ab\t", palette.fg_0, .{ .tab_size = 4 }),
        0.01,
    );
}

test "the clip stops drawing outside it" {
    var f = try Fixture.init(200, 40, 16);
    defer f.deinit();
    var p = f.painter();
    p.clear(palette.bg_0);

    const saved = p.pushClip(.{ .x = 0, .y = 0, .w = 1, .h = 40 });
    _ = p.drawRun(50, 20, "Hello", palette.fg_0, .{});
    p.popClip(saved);
    try testing.expectEqual(@as(usize, 0), inkCount(&f.surf, palette.bg_0));
}

test "underline and strike add rules" {
    var f = try Fixture.init(200, 40, 16);
    defer f.deinit();
    var p = f.painter();

    p.clear(palette.bg_0);
    _ = p.drawRun(4, 20, "x", palette.fg_0, .{});
    const plain = inkCount(&f.surf, palette.bg_0);

    p.clear(palette.bg_0);
    _ = p.drawRun(4, 20, "x", palette.fg_0, .{ .underline = true, .strike = true });
    try testing.expect(inkCount(&f.surf, palette.bg_0) > plain);
}

test "bold draws more ink than regular" {
    var f = try Fixture.init(200, 40, 20);
    defer f.deinit();
    var p = f.painter();

    p.clear(palette.bg_0);
    _ = p.drawRun(4, 24, "MMMM", palette.fg_0, .{});
    const regular = inkCount(&f.surf, palette.bg_0);

    p.clear(palette.bg_0);
    _ = p.drawRun(4, 24, "MMMM", palette.fg_0, .{ .weight = .bold });
    try testing.expect(inkCount(&f.surf, palette.bg_0) > regular);
}

test "labels align left, centre and right" {
    var f = try Fixture.init(200, 30, 16);
    defer f.deinit();
    var p = f.painter();
    const rect = Rect{ .x = 0, .y = 0, .w = 200, .h = 30 };

    for ([_]Painter.Align{ .left, .center, .right }) |how| {
        p.clear(palette.bg_0);
        p.drawLabel(rect, "hi", palette.fg_0, how, .{});
        var min_x: i32 = 200;
        for (0..30) |y| {
            for (0..200) |x| {
                if (!f.surf.at(@intCast(x), @intCast(y)).eql(palette.bg_0)) {
                    min_x = @min(min_x, @as(i32, @intCast(x)));
                }
            }
        }
        switch (how) {
            .left => try testing.expect(min_x < 10),
            .center => try testing.expect(min_x > 80 and min_x < 110),
            .right => try testing.expect(min_x > 150),
        }
    }
}

test "an over-long label is ellipsized rather than overflowing" {
    var f = try Fixture.init(120, 30, 16);
    defer f.deinit();
    var p = f.painter();
    p.clear(palette.bg_0);

    // A narrow box that cannot hold the whole string.
    p.drawEllipsized(.{ .x = 0, .y = 0, .w = 40, .h = 30 }, "a very long note title", palette.fg_0, .{});

    // Nothing may be painted past the box.
    for (0..30) |y| {
        var x: u32 = 40;
        while (x < 120) : (x += 1) {
            try testing.expect(f.surf.at(@intCast(x), @intCast(y)).eql(palette.bg_0));
        }
    }
    try testing.expect(inkCount(&f.surf, palette.bg_0) > 0);
}

test "a label that fits is not ellipsized" {
    var f = try Fixture.init(200, 30, 16);
    defer f.deinit();
    var p = f.painter();

    p.clear(palette.bg_0);
    p.drawEllipsized(.{ .x = 0, .y = 0, .w = 200, .h = 30 }, "short", palette.fg_0, .{});
    const with_ellipsis_path = inkCount(&f.surf, palette.bg_0);

    p.clear(palette.bg_0);
    p.drawLabel(.{ .x = 0, .y = 0, .w = 200, .h = 30 }, "short", palette.fg_0, .left, .{});
    try testing.expectEqual(inkCount(&f.surf, palette.bg_0), with_ellipsis_path);
}
