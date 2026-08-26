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
const shapes = @import("shapes.zig");
const fonts_mod = @import("fonts.zig");

const Rgba = color.Rgba;
const Rect = surface.Rect;
const Surface = surface.Surface;
const FontStack = font.FontStack;
const Fonts = fonts_mod.Fonts;
const Family = fonts_mod.Family;

pub const Painter = struct {
    surf: *Surface,
    /// The editor's monospace stack. Note text is drawn on its cell grid, so
    /// everything that reasons in cells reaches for this one directly.
    fonts: *FontStack,
    /// Every face. Interface text picks one by `RunOptions.family`.
    faces: *Fonts,
    /// Device pixels per logical unit. Every coordinate that arrives here is
    /// logical and every coordinate that leaves for the surface is multiplied
    /// by this, which is the whole of the program's high-density support:
    /// layout, hit testing and the event coordinates SDL reports all stay in
    /// logical units, and only this last step knows the display is denser.
    scale: f64,
    /// In device pixels, like the surface it bounds.
    clip: Rect,

    pub fn init(surf: *Surface, faces: *Fonts) Painter {
        return .{
            .surf = surf,
            .fonts = faces.get(.{ .kind = .mono }),
            .faces = faces,
            .scale = @floatCast(faces.scale),
            .clip = surf.bounds(),
        };
    }

    /// Logical rectangle to device pixels.
    ///
    /// Both edges are rounded rather than the origin and the size, so
    /// rectangles that abut in logical space still abut in device space and no
    /// seam opens between them.
    fn dev(self: *const Painter, r: Rect) Rect {
        const x0: i32 = @intFromFloat(@round(@as(f64, @floatFromInt(r.x)) * self.scale));
        const y0: i32 = @intFromFloat(@round(@as(f64, @floatFromInt(r.y)) * self.scale));
        const x1: i32 = @intFromFloat(@round(@as(f64, @floatFromInt(r.x + r.w)) * self.scale));
        const y1: i32 = @intFromFloat(@round(@as(f64, @floatFromInt(r.y + r.h)) * self.scale));
        return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
    }

    /// The drawing area, in logical units.
    pub fn bounds(self: *const Painter) Rect {
        const b = self.surf.bounds();
        return .{
            .x = 0,
            .y = 0,
            .w = @intFromFloat(@round(@as(f64, @floatFromInt(b.w)) / self.scale)),
            .h = @intFromFloat(@round(@as(f64, @floatFromInt(b.h)) / self.scale)),
        };
    }

    /// Narrow the clip, returning the previous one so the caller can restore it.
    pub fn pushClip(self: *Painter, rect: Rect) Rect {
        const previous = self.clip;
        self.clip = self.clip.intersect(self.dev(rect));
        return previous;
    }

    pub fn popClip(self: *Painter, previous: Rect) void {
        self.clip = previous;
    }

    pub fn fill(self: *Painter, rect: Rect, c: Rgba) void {
        self.surf.fillRect(self.dev(rect), self.clip, c);
    }

    pub fn stroke(self: *Painter, rect: Rect, c: Rgba) void {
        self.surf.strokeRect(self.dev(rect), self.clip, c);
    }

    /// Fill `rect` with its corners rounded, as `border-radius` did.
    pub fn fillRound(self: *Painter, rect: Rect, radius: f32, c: Rgba) void {
        const s: f32 = @floatCast(self.scale);
        shapes.fillRoundRect(self.surf, self.clip, self.dev(rect), radius * s, c);
    }

    pub fn strokeRound(self: *Painter, rect: Rect, radius: f32, width: f32, c: Rgba) void {
        const s: f32 = @floatCast(self.scale);
        shapes.strokeRoundRect(self.surf, self.clip, self.dev(rect), radius * s, width * s, c);
    }

    /// Draw an icon outline, scaled from its 16x16 design space into `dest`.
    pub fn drawIcon(
        self: *Painter,
        dest: Rect,
        segments: []const shapes.Segment,
        c: Rgba,
    ) void {
        // The original's icons were all `stroke-width: 1.4` in a 16-unit box.
        // The stroke width is in the icon's own units, so scaling `dest` is
        // all it takes for the outline to thicken with the display.
        shapes.strokePath(self.surf, self.clip, self.dev(dest), 16, segments, 1.4, c);
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
    fn blitGlyph(
        self: *Painter,
        stack: *const FontStack,
        g: font.Glyph,
        pen_x: f64,
        baseline_y: f64,
        c: Rgba,
    ) void {
        if (g.isEmpty()) return;
        const cov = stack.coverageOf(g);

        // The pen arrives in logical units; the bearings are already device
        // pixels, because the glyph was rasterized there.
        const x0: i32 = @intFromFloat(@round(pen_x * self.scale));
        const y0: i32 = @intFromFloat(@round(baseline_y * self.scale));
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
        /// Which face to draw in. Ignored by `drawRun`, which is the editor's
        /// cell-grid path and is always monospace.
        family: Family = .{},
        weight: font.Weight = .regular,
        /// Extra pixels between clusters, as CSS `letter-spacing`. Only the
        /// proportional path honours it; the editor's grid has no room for it.
        tracking: f64 = 0,
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
                    self.blitGlyph(self.fonts, glyph, pen, baseline_y, c);
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

    /// Vertical room for one line of text inside `rect`.
    ///
    /// A label is centered on its rect, so a rect shorter than the line box
    /// would clip the ascenders and descenders off every glyph rather than the
    /// horizontal overflow the caller meant to bound. Callers inset rects on
    /// all four sides routinely, which makes a too-short rect the common case:
    /// a 20px bar inset by 6 leaves 8px for a 19px line.
    fn lineClip(self: *Painter, rect: Rect, family: Family) Rect {
        const rh = self.faces.get(family).metrics.row_height;
        const top = @as(f64, @floatFromInt(rect.y)) +
            (@as(f64, @floatFromInt(rect.h)) - rh) / 2;
        const y = @min(rect.y, @as(i32, @intFromFloat(@floor(top))));
        const bottom = @max(rect.bottom(), @as(i32, @intFromFloat(@ceil(top + rh))));
        return .{ .x = rect.x, .y = y, .w = rect.w, .h = bottom - y };
    }

    /// Baseline for a single line centered in `rect`.
    fn baselineIn(self: *Painter, rect: Rect, family: Family) f64 {
        const m = self.faces.get(family).metrics;
        return @as(f64, @floatFromInt(rect.y)) +
            (@as(f64, @floatFromInt(rect.h)) - m.row_height) / 2 + m.ascent;
    }

    /// Width of one grapheme cluster in `family`.
    pub fn spanWidth(self: *Painter, cluster: []const u8, family: Family) f64 {
        return self.faces.get(family).clusterAdvance(cluster);
    }

    /// Width `drawSpan` would occupy, without drawing.
    pub fn measureSpan(self: *Painter, text: []const u8, opts: RunOptions) f64 {
        const stack = self.faces.get(opts.family);
        const tab_px = @as(f64, @floatFromInt(opts.tab_size)) * stack.metrics.ch_width;
        var w: f64 = 0;
        var it = core.grapheme.iterate(text);
        while (it.nextCluster()) |g| {
            if (g.text.len == 1 and g.text[0] == '\t') {
                w = (@floor(w / tab_px) + 1) * tab_px;
                continue;
            }
            w += stack.clusterAdvance(g.text) + opts.tracking;
        }
        return w;
    }

    /// Draw interface text, spaced by each glyph's own advance.
    ///
    /// Note text goes through `drawRun` instead, which snaps to the cell grid
    /// so the caret and the glyphs cannot disagree. The chrome has no caret to
    /// keep in step, and the original let the browser space `-apple-system`
    /// proportionally -- forcing it onto a grid shows up as wrong tracking in
    /// every label.
    pub fn drawSpan(
        self: *Painter,
        x: f64,
        baseline_y: f64,
        text: []const u8,
        c: Rgba,
        opts: RunOptions,
    ) f64 {
        const stack = self.faces.get(opts.family);
        const tab_px = @as(f64, @floatFromInt(opts.tab_size)) * stack.metrics.ch_width;

        var pen = x;
        var it = core.grapheme.iterate(text);
        while (it.nextCluster()) |g| {
            if (g.text.len == 1 and g.text[0] == '\t') {
                pen = x + (@floor((pen - x) / tab_px) + 1) * tab_px;
                continue;
            }
            if (stack.resolveCluster(g.text)) |resolved| {
                if (stack.glyph(resolved, opts.weight)) |glyph| {
                    self.blitGlyph(stack, glyph, pen, baseline_y, c);
                }
            }
            pen += stack.clusterAdvance(g.text) + opts.tracking;
        }

        const width = pen - x;
        if (width > 0) {
            if (opts.underline) self.fill(.{
                .x = @intFromFloat(@round(x)),
                .y = @intFromFloat(@round(baseline_y + 2)),
                .w = @intFromFloat(@round(width)),
                .h = 1,
            }, c);
            if (opts.strike) self.fill(.{
                .x = @intFromFloat(@round(x)),
                .y = @intFromFloat(@round(baseline_y - stack.metrics.ascent * 0.3)),
                .w = @intFromFloat(@round(width)),
                .h = 1,
            }, c);
        }
        return pen;
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
        const width = self.measureSpan(text, opts);
        const x: f64 = switch (how) {
            .left => @floatFromInt(rect.x),
            .center => @as(f64, @floatFromInt(rect.x)) + (@as(f64, @floatFromInt(rect.w)) - width) / 2,
            .right => @as(f64, @floatFromInt(rect.x + rect.w)) - width,
        };
        const baseline = self.baselineIn(rect, opts.family);

        const saved = self.pushClip(self.lineClip(rect, opts.family));
        defer self.popClip(saved);
        _ = self.drawSpan(x, baseline, text, c, opts);
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
        const available: f64 = @floatFromInt(rect.w);
        if (self.measureSpan(text, opts) <= available) {
            self.drawLabel(rect, text, c, .left, opts);
            return;
        }

        // Trim clusters until the text plus an ellipsis fits.
        const ellipsis = "…";
        const ellipsis_w = self.spanWidth(ellipsis, opts.family);
        var end: usize = 0;
        var used: f64 = 0;
        var it = core.grapheme.iterate(text);
        while (it.nextCluster()) |g| {
            const w = self.spanWidth(g.text, opts.family);
            if (used + w + ellipsis_w > available) break;
            used += w;
            end = g.offset + g.text.len;
        }

        const saved = self.pushClip(self.lineClip(rect, opts.family));
        defer self.popClip(saved);
        const baseline = self.baselineIn(rect, opts.family);
        const pen = self.drawSpan(@floatFromInt(rect.x), baseline, text[0..end], c, opts);
        _ = self.drawSpan(pen, baseline, ellipsis, c, opts);
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
    fonts: Fonts,

    fn init(w: u32, h: u32, px: u32) !Fixture {
        return .{
            .surf = try Surface.init(testing.allocator, w, h),
            .fonts = try Fonts.initBundled(testing.allocator, .{
                .ui_px = px,
                .editor_px = px,
            }),
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
    try testing.expectApproxEqAbs(f.fonts.mono_default.metrics.cjk_width * 2, end, 0.01);
    try testing.expect(inkCount(&f.surf, palette.bg_0) > 20);
}

test "a run of mixed scripts stays on the cell grid" {
    var f = try Fixture.init(300, 40, 16);
    defer f.deinit();
    var p = f.painter();
    p.clear(palette.bg_0);

    const m = f.fonts.mono_default.metrics;
    const end = p.drawRun(0, 24, "ab안c", palette.fg_0, .{});
    // 2 narrow + 1 wide + 1 narrow.
    try testing.expectApproxEqAbs(m.ch_width * 3 + m.cjk_width, end, 0.01);
}

test "tabs advance to the next stop, measured from the run start" {
    var f = try Fixture.init(300, 40, 16);
    defer f.deinit();
    var p = f.painter();
    p.clear(palette.bg_0);
    const m = f.fonts.mono_default.metrics;

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
