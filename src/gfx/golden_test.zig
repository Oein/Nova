//! Golden-image tests for the text renderer.
//!
//! These pin the things that actually broke in the TypeScript build: where a
//! Korean line wraps, where the caret sits relative to the glyphs, how a
//! selection rectangle lines up, and what an IME preedit looks like inline.

const std = @import("std");
const core = @import("core");
const gfx = @import("gfx.zig");
const golden = @import("golden.zig");

const testing = std.testing;
const palette = gfx.palette;
const Rect = gfx.Rect;

const Scene = struct {
    surf: gfx.Surface,
    fonts: gfx.FontStack,
    tio: golden.TestIo,

    fn init(w: u32, h: u32, px: u32) !Scene {
        return .{
            .surf = try gfx.Surface.init(testing.allocator, w, h),
            .fonts = try gfx.FontStack.init(testing.allocator, px),
            .tio = try golden.TestIo.init(testing.allocator),
        };
    }
    fn deinit(self: *Scene) void {
        self.tio.deinit();
        self.fonts.deinit();
        self.surf.deinit();
    }
    fn painter(self: *Scene) gfx.Painter {
        return gfx.Painter.init(&self.surf, &self.fonts);
    }
    fn check(self: *Scene, name: []const u8) !void {
        try golden.expectMatches(testing.allocator, self.tio.io, name, &self.surf);
    }
};

/// Lay out `line` with soft wrap and paint it, exactly as the editor view does.
fn paintWrapped(
    p: *gfx.Painter,
    line: []const u8,
    origin_x: i32,
    origin_y: i32,
    max_px: f64,
) !usize {
    const m = p.wrapMetrics(4);
    const starts = try core.wrap.computeStarts(testing.allocator, line, max_px, m);
    defer starts.deinit(testing.allocator);

    const row_h = p.fonts.metrics.row_height;
    for (0..starts.rowCount()) |sr| {
        const r = starts.rowRange(sr, line.len);
        const y = @as(f64, @floatFromInt(origin_y)) + @as(f64, @floatFromInt(sr)) * row_h;
        _ = p.drawRun(
            @floatFromInt(origin_x),
            y + p.fonts.metrics.ascent,
            line[r.start..r.end],
            palette.fg_0,
            .{},
        );
    }
    return starts.rowCount();
}

test "golden: Korean text wraps at the space, not mid-compound" {
    var s = try Scene.init(160, 90, 16);
    defer s.deinit();
    var p = s.painter();
    p.clear(palette.bg_0);

    // The wrap.zig test case, rendered: `한국 시문집을` must break after the
    // space so `시문집을` stays whole.
    const rows = try paintWrapped(&p, "한국 시문집을 읽었다", 4, 4, 130);
    try testing.expect(rows >= 2);

    try s.check("wrap-korean");
}

test "golden: caret and selection line up with the glyphs" {
    var s = try Scene.init(260, 60, 16);
    defer s.deinit();
    var p = s.painter();
    p.clear(palette.bg_0);

    const line = "ab안녕cd";
    const m = p.wrapMetrics(4);
    const row_h = p.fonts.metrics.row_height;

    // Select from byte 2 to byte 8 -- the two Hangul syllables.
    const x0 = core.wrap.advanceTo(line, 2, m);
    const x1 = core.wrap.advanceTo(line, 8, m);
    p.fill(.{
        .x = 8 + @as(i32, @intFromFloat(x0)),
        .y = 8,
        .w = @intFromFloat(x1 - x0),
        .h = @intFromFloat(row_h),
    }, palette.selection);

    _ = p.drawRun(8, 8 + p.fonts.metrics.ascent, line, palette.fg_0, .{});

    // Caret at the end of the selection.
    p.fill(.{
        .x = 8 + @as(i32, @intFromFloat(x1)),
        .y = 8,
        .w = 2,
        .h = @intFromFloat(row_h),
    }, palette.fg_0);

    try s.check("caret-selection");
}

test "golden: an IME preedit renders inline, underlined in the accent color" {
    var s = try Scene.init(260, 60, 16);
    defer s.deinit();
    var p = s.painter();
    p.clear(palette.bg_0);

    const m = p.wrapMetrics(4);
    const before = "저는 ";
    const preedit = "한글";
    const after = "입니다";

    const baseline = 8 + p.fonts.metrics.ascent;
    var pen = p.drawRun(8, baseline, before, palette.fg_0, .{});
    pen = p.drawRun(pen, baseline, preedit, palette.accent, .{ .underline = true });
    _ = p.drawRun(pen, baseline, after, palette.fg_0, .{});

    // The candidate window is anchored past the composing text.
    const caret_x = 8 + core.wrap.advanceTo(before ++ preedit, (before ++ preedit).len, m);
    p.fill(.{
        .x = @intFromFloat(caret_x),
        .y = 8,
        .w = 2,
        .h = @intFromFloat(p.fonts.metrics.row_height),
    }, palette.fg_0);

    try s.check("ime-preedit");
}

test "golden: tab stops restart on each wrapped sub-row" {
    var s = try Scene.init(220, 70, 16);
    defer s.deinit();
    var p = s.painter();
    p.clear(palette.bg_0);

    _ = try paintWrapped(&p, "\tindented\tcolumns and a long tail", 4, 4, 200);
    try s.check("tabs");
}

test "golden: markdown styles paint bold, underline and strike" {
    var s = try Scene.init(300, 90, 16);
    defer s.deinit();
    var p = s.painter();
    p.clear(palette.bg_0);

    const lines = [_][]const u8{ "# 제목 heading", "a **bold** b", "__under__ ~~strike~~" };
    const row_h = p.fonts.metrics.row_height;

    for (lines, 0..) |line, i| {
        const ranges = try core.markdown.tokenize(testing.allocator, line);
        defer testing.allocator.free(ranges);
        const toks = try core.markdown.tokensForSlice(testing.allocator, ranges, line, 0, line.len);
        defer testing.allocator.free(toks);

        const baseline = 6 + @as(f64, @floatFromInt(i)) * row_h + p.fonts.metrics.ascent;
        var pen: f64 = 6;
        for (toks) |t| {
            pen = p.drawRun(pen, baseline, t.text, palette.fg_0, .{
                .weight = if (t.style.bold) .bold else .regular,
                .underline = t.style.underline,
                .strike = t.style.strike,
            });
        }
    }

    try s.check("markdown-styles");
}
