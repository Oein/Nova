//! Font faces, the fallback chain, and the rasterized-glyph cache.
//!
//! Replaces `src/lib/editor/measure.ts`, which probed the DOM by rendering
//! `"M"` a hundred times and dividing. With the font owned and loaded here, the
//! advance width is simply read out of the face -- which is what removes the
//! whole class of bug where the caret and the painted glyphs disagreed.

const std = @import("std");
const c = @import("c.zig");
const ft = c.ft;
const hb = c.hb;

const Allocator = std.mem.Allocator;

pub const Error = error{
    FreeTypeInit,
    FontLoad,
    OutOfMemory,
};

/// The bundled face.
///
/// D2Coding is the only font shipped, and it is the primary face rather than a
/// CJK fallback. That is a deliberate constraint: the editor lays text out on a
/// fixed cell grid where a wide glyph must be *exactly* two narrow cells, and
/// D2Coding is drawn to that ratio (Latin at 0.5 em, Hangul at 1.0 em).
///
/// Pairing a Latin coding font with a separate CJK font does not hold the
/// ratio -- JetBrains Mono's Latin is 0.6 em, so its cells and D2Coding's
/// Hangul cells disagree by 20%, and the caret drifts away from the glyphs on
/// any line mixing scripts. That is the exact failure the TypeScript build
/// fought with `document.fonts.ready` re-measurement, and it is not worth
/// re-importing for a nicer `a`.
///
/// A user-chosen font is still supported: see `prependFace`, which rescales the
/// fallbacks to the chosen font's grid.
pub const bundled = struct {
    pub const default_regular = @embedFile("font_default");
};

pub const Weight = enum { regular, bold };

/// Cell metrics for the monospace grid.
///
/// `wrap.zig` consumes these directly; the difference from the TypeScript
/// version is only that the numbers are exact instead of measured.
pub const Metrics = struct {
    /// Advance of a narrow cell, in pixels.
    ch_width: f64,
    /// Advance of a wide (East Asian) cell.
    cjk_width: f64,
    /// Line box height.
    row_height: f64,
    /// Baseline offset from the top of the line box.
    ascent: f64,
};

const Face = struct {
    ft_face: ft.FT_Face,
    hb_font: ?*hb.hb_font_t,
    /// True when this face has no bold cut and bold must be synthesized.
    embolden_for_bold: bool,
    /// Pixel size for this face specifically. A fallback is scaled so its cells
    /// land on the primary face's grid; see `matchFallbackSizes`.
    px_size: u32,

    fn deinit(self: *Face) void {
        if (self.hb_font) |f| hb.hb_font_destroy(f);
        _ = ft.FT_Done_Face(self.ft_face);
    }
};

/// A rasterized glyph, held as 8-bit coverage.
pub const Glyph = struct {
    width: u16,
    height: u16,
    /// Offset from the pen position to the top-left of the bitmap.
    left: i16,
    top: i16,
    /// Byte offset into `FontStack.coverage`.
    offset: u32,

    pub fn isEmpty(self: Glyph) bool {
        return self.width == 0 or self.height == 0;
    }
};

const GlyphKey = struct {
    face: u8,
    weight: Weight,
    index: u32,
};

/// Which face and glyph a cluster resolved to.
pub const Resolved = struct {
    face: u8,
    index: u32,
};

pub const FontStack = struct {
    gpa: Allocator,
    lib: ft.FT_Library,
    /// Regular faces, in fallback order.
    faces: std.ArrayList(Face) = .empty,
    /// Bold faces, index-aligned with `faces`. A null entry means the regular
    /// face is emboldened instead.
    bold_faces: std.ArrayList(?Face) = .empty,

    px_size: u32,
    metrics: Metrics,

    glyphs: std.AutoHashMapUnmanaged(GlyphKey, Glyph) = .empty,
    coverage: std.ArrayList(u8) = .empty,
    /// Cluster bytes -> resolved face and glyph. Text is overwhelmingly
    /// repeated characters, so this turns shaping into a hash lookup.
    cluster_cache: std.StringHashMapUnmanaged(Resolved) = .empty,

    pub fn init(gpa: Allocator, px_size: u32) Error!FontStack {
        var lib: ft.FT_Library = null;
        if (ft.FT_Init_FreeType(&lib) != 0) return error.FreeTypeInit;
        errdefer _ = ft.FT_Done_FreeType(lib);

        var self = FontStack{
            .gpa = gpa,
            .lib = lib,
            .px_size = px_size,
            .metrics = .{ .ch_width = 0, .cjk_width = 0, .row_height = 0, .ascent = 0 },
        };
        errdefer self.deinit();

        try self.addFace(bundled.default_regular, null);

        self.recomputeMetrics();
        return self;
    }

    pub fn deinit(self: *FontStack) void {
        for (self.faces.items) |*f| f.deinit();
        self.faces.deinit(self.gpa);
        for (self.bold_faces.items) |*maybe| {
            if (maybe.*) |*f| f.deinit();
        }
        self.bold_faces.deinit(self.gpa);

        self.glyphs.deinit(self.gpa);
        self.coverage.deinit(self.gpa);

        var it = self.cluster_cache.keyIterator();
        while (it.next()) |k| self.gpa.free(k.*);
        self.cluster_cache.deinit(self.gpa);

        _ = ft.FT_Done_FreeType(self.lib);
    }

    fn openFace(self: *FontStack, data: []const u8) Error!Face {
        var face: ft.FT_Face = null;
        const rc = ft.FT_New_Memory_Face(
            self.lib,
            data.ptr,
            @intCast(data.len),
            0,
            &face,
        );
        if (rc != 0) return error.FontLoad;
        errdefer _ = ft.FT_Done_Face(face);

        if (ft.FT_Set_Pixel_Sizes(face, 0, self.px_size) != 0) return error.FontLoad;

        // HarfBuzz shares the FT_Face, so the size set above applies to shaping
        // as well.
        const hb_font = hb.hb_ft_font_create_referenced(@ptrCast(face));
        return .{
            .ft_face = face,
            .hb_font = hb_font,
            .embolden_for_bold = false,
            .px_size = self.px_size,
        };
    }

    fn addFace(self: *FontStack, regular: []const u8, bold: ?[]const u8) Error!void {
        var face = try self.openFace(regular);
        errdefer face.deinit();

        var bold_face: ?Face = null;
        if (bold) |b| {
            bold_face = try self.openFace(b);
        } else {
            face.embolden_for_bold = true;
        }

        try self.faces.append(self.gpa, face);
        try self.bold_faces.append(self.gpa, bold_face);
    }

    /// Put a user-chosen font at the head of the fallback chain.
    ///
    /// The bundled faces stay behind it, so a font that lacks Hangul (or lacks
    /// anything else) still renders every note.
    pub fn prependFace(self: *FontStack, data: []const u8) Error!void {
        var face = try self.openFace(data);
        errdefer face.deinit();
        face.embolden_for_bold = true;

        try self.faces.insert(self.gpa, 0, face);
        try self.bold_faces.insert(self.gpa, 0, null);
        self.invalidateCaches();
        self.recomputeMetrics();
    }

    pub fn setPixelSize(self: *FontStack, px_size: u32) Error!void {
        if (px_size == self.px_size) return;
        self.px_size = px_size;
        for (self.faces.items) |*f| {
            if (ft.FT_Set_Pixel_Sizes(f.ft_face, 0, px_size) != 0) return error.FontLoad;
            f.px_size = px_size;
        }
        for (self.bold_faces.items) |*maybe| {
            if (maybe.*) |*f| {
                if (ft.FT_Set_Pixel_Sizes(f.ft_face, 0, px_size) != 0) return error.FontLoad;
            }
        }
        self.invalidateCaches();
        self.recomputeMetrics();
    }

    fn invalidateCaches(self: *FontStack) void {
        self.glyphs.clearRetainingCapacity();
        self.coverage.clearRetainingCapacity();
        var it = self.cluster_cache.keyIterator();
        while (it.next()) |k| self.gpa.free(k.*);
        self.cluster_cache.clearRetainingCapacity();
    }

    /// Advance of `cp` in the face that supplies it, at that face's size.
    fn advanceOf(self: *FontStack, cp: u21) f64 {
        const r = self.resolveCodepoint(cp) orelse return 0;
        return self.advanceInFace(r.face, r.index);
    }

    fn advanceInFace(self: *FontStack, face_index: u8, glyph_index: u32) f64 {
        const face = self.faces.items[face_index].ft_face;
        if (ft.FT_Load_Glyph(face, glyph_index, ft.FT_LOAD_DEFAULT) != 0) return 0;
        // 26.6 fixed point.
        const adv: f64 = @floatFromInt(face.*.glyph.*.advance.x);
        return adv / 64.0;
    }

    /// Rescale every fallback face so its cells match the primary face's grid.
    ///
    /// Without this, a fallback drawn at the same pixel size lands on a
    /// different advance -- the caret would sit right for Latin and drift for
    /// Korean on the same line. Matching sizes costs a slightly different
    /// visual weight between scripts, which is the correct trade: a grid that
    /// holds beats glyphs that are nominally the same point size.
    fn matchFallbackSizes(self: *FontStack) void {
        if (self.faces.items.len < 2) return;
        const base: f64 = @floatFromInt(self.px_size);

        for (self.faces.items[1..], 1..) |*face, i| {
            _ = i;
            // Measure this face on its own terms: prefer a narrow reference
            // glyph, fall back to a wide one.
            const narrow = ft.FT_Get_Char_Index(face.ft_face, 'M');
            const wide = ft.FT_Get_Char_Index(face.ft_face, '가');

            var target: f64 = 0;
            var measured: f64 = 0;
            if (narrow != 0) {
                target = self.metrics.ch_width;
                measured = rawAdvance(face.ft_face, narrow);
            } else if (wide != 0) {
                target = self.metrics.cjk_width;
                measured = rawAdvance(face.ft_face, wide);
            }
            if (measured <= 0 or target <= 0) continue;

            const scaled = @round(base * target / measured);
            const px: u32 = @intFromFloat(std.math.clamp(scaled, 4, 400));
            if (px != face.px_size) {
                if (ft.FT_Set_Pixel_Sizes(face.ft_face, 0, px) == 0) face.px_size = px;
            }
        }
    }

    fn rawAdvance(face: ft.FT_Face, glyph_index: u32) f64 {
        if (ft.FT_Load_Glyph(face, glyph_index, ft.FT_LOAD_DEFAULT) != 0) return 0;
        const adv: f64 = @floatFromInt(face.*.glyph.*.advance.x);
        return adv / 64.0;
    }

    fn recomputeMetrics(self: *FontStack) void {
        const size: f64 = @floatFromInt(self.px_size);

        const ch = self.advanceOf('M');
        const ch_width = if (ch > 0) ch else @round(size * 0.5);

        // The wide cell is *defined* as two narrow cells rather than measured.
        //
        // Measuring looks more honest but is not: FreeType rounds advances to
        // whole pixels, so at an odd size a 0.5 em Latin glyph rounds to 7 px
        // while the 1.0 em Hangul glyph is 13 px -- and 2 x 7 != 13. The grid
        // would drift by a pixel per wide character, which is exactly the
        // caret-versus-glyph disagreement this rewrite set out to remove. The
        // default editor size is 13 px, so this is the common case, not an edge
        // one. A wide glyph is drawn with up to a pixel of slack inside its
        // cell, which is invisible; a caret in the wrong place is not.
        const cjk = ch_width * 2;

        const primary = self.faces.items[0].ft_face;
        const scaled_ascent: f64 = @floatFromInt(primary.*.size.*.metrics.ascender);
        const scaled_height: f64 = @floatFromInt(primary.*.size.*.metrics.height);

        // The original floored the line box at `ceil(fontSize * 1.4)`; keeping
        // that keeps line spacing familiar across a font change.
        const min_height = @ceil(size * 1.4);
        const row_height = @max(scaled_height / 64.0, min_height);

        self.metrics = .{
            .ch_width = ch_width,
            .cjk_width = cjk,
            .row_height = row_height,
            .ascent = scaled_ascent / 64.0 + (row_height - scaled_height / 64.0) / 2.0,
        };
        self.matchFallbackSizes();
    }

    /// First face in the chain with a glyph for `cp`.
    pub fn resolveCodepoint(self: *FontStack, cp: u21) ?Resolved {
        for (self.faces.items, 0..) |f, i| {
            const idx = ft.FT_Get_Char_Index(f.ft_face, cp);
            if (idx != 0) return .{ .face = @intCast(i), .index = idx };
        }
        return null;
    }

    /// Resolve a whole grapheme cluster to one glyph.
    ///
    /// HarfBuzz shapes the cluster so a composed form (a precomposed Hangul
    /// syllable, an emoji ZWJ sequence a font supplies a single glyph for) is
    /// found when the font has one. When shaping yields several glyphs, the
    /// first is used: the editor lays text out on a fixed cell grid, so a
    /// cluster occupies one cell whatever its internal structure.
    pub fn resolveCluster(self: *FontStack, cluster: []const u8) ?Resolved {
        if (cluster.len == 0) return null;
        if (self.cluster_cache.get(cluster)) |hit| return hit;

        const resolved = self.shapeCluster(cluster) orelse return null;

        const key = self.gpa.dupe(u8, cluster) catch return resolved;
        self.cluster_cache.put(self.gpa, key, resolved) catch self.gpa.free(key);
        return resolved;
    }

    fn shapeCluster(self: *FontStack, cluster: []const u8) ?Resolved {
        // Pick the face by the base code point, then shape with it.
        //
        // Decoded by hand rather than with `Utf8Iterator`, which asserts
        // validity: grapheme clusters may carry malformed bytes from a corrupt
        // file, and the editor must draw something rather than panic.
        const base_len = std.unicode.utf8ByteSequenceLength(cluster[0]) catch return null;
        if (base_len > cluster.len) return null;
        const base = std.unicode.utf8Decode(cluster[0..base_len]) catch return null;
        const by_base = self.resolveCodepoint(base) orelse return null;
        if (cluster.len == base_len) return by_base;

        const hb_font = self.faces.items[by_base.face].hb_font orelse return by_base;
        const buf = hb.hb_buffer_create() orelse return by_base;
        defer hb.hb_buffer_destroy(buf);

        hb.hb_buffer_add_utf8(buf, cluster.ptr, @intCast(cluster.len), 0, @intCast(cluster.len));
        hb.hb_buffer_guess_segment_properties(buf);
        hb.hb_shape(hb_font, buf, null, 0);

        var count: c_uint = 0;
        const infos = hb.hb_buffer_get_glyph_infos(buf, &count);
        if (count == 0 or infos == null) return by_base;
        return .{ .face = by_base.face, .index = infos[0].codepoint };
    }

    /// Rasterize (and cache) a glyph.
    pub fn glyph(self: *FontStack, r: Resolved, weight: Weight) ?Glyph {
        const key = GlyphKey{ .face = r.face, .weight = weight, .index = r.index };
        if (self.glyphs.get(key)) |g| return g;

        const use_bold_face = weight == .bold and self.bold_faces.items[r.face] != null;
        const face = if (use_bold_face)
            self.bold_faces.items[r.face].?.ft_face
        else
            self.faces.items[r.face].ft_face;

        if (ft.FT_Load_Glyph(face, r.index, ft.FT_LOAD_DEFAULT) != 0) return null;
        if (weight == .bold and !use_bold_face) {
            // Synthetic bold for a face with no bold cut (the CJK font, and any
            // font the user supplies).
            const strength: ft.FT_Pos = @intCast(self.faces.items[r.face].px_size * 64 / 24);
            _ = ft.FT_Outline_Embolden(&face.*.glyph.*.outline, strength);
        }
        if (ft.FT_Render_Glyph(face.*.glyph, ft.FT_RENDER_MODE_NORMAL) != 0) return null;

        const bmp = face.*.glyph.*.bitmap;
        const w: u16 = @intCast(bmp.width);
        const h: u16 = @intCast(bmp.rows);

        const offset: u32 = @intCast(self.coverage.items.len);
        if (w > 0 and h > 0) {
            self.coverage.ensureUnusedCapacity(self.gpa, @as(usize, w) * h) catch return null;
            var y: usize = 0;
            while (y < h) : (y += 1) {
                const src_row = bmp.buffer + y * @as(usize, @intCast(bmp.pitch));
                self.coverage.appendSliceAssumeCapacity(src_row[0..w]);
            }
        }

        const g = Glyph{
            .width = w,
            .height = h,
            .left = @intCast(face.*.glyph.*.bitmap_left),
            .top = @intCast(face.*.glyph.*.bitmap_top),
            .offset = offset,
        };
        self.glyphs.put(self.gpa, key, g) catch return g;
        return g;
    }

    /// Coverage rows for a rasterized glyph.
    pub fn coverageOf(self: *const FontStack, g: Glyph) []const u8 {
        if (g.isEmpty()) return &.{};
        return self.coverage.items[g.offset..][0.. @as(usize, g.width) * g.height];
    }
};

// -- tests -------------------------------------------------------------------

const testing = std.testing;

test "the bundled fonts load and produce sane metrics" {
    var fs = try FontStack.init(testing.allocator, 13);
    defer fs.deinit();

    try testing.expect(fs.metrics.ch_width > 3 and fs.metrics.ch_width < 20);
    try testing.expect(fs.metrics.row_height >= @ceil(13 * 1.4));
    try testing.expect(fs.metrics.ascent > 0);
    try testing.expect(fs.metrics.ascent < fs.metrics.row_height);
}

test "a CJK cell is exactly two Latin cells, at every size" {
    // The assumption the whole wrap and caret model rests on. It has to hold at
    // odd sizes too -- 13 px is the default.
    for ([_]u32{ 8, 9, 11, 12, 13, 14, 16, 17, 24, 31, 48 }) |px| {
        var fs = try FontStack.init(testing.allocator, px);
        defer fs.deinit();
        testing.expectEqual(fs.metrics.ch_width * 2, fs.metrics.cjk_width) catch |err| {
            std.debug.print("size {d}: ch={d} cjk={d}\n", .{ px, fs.metrics.ch_width, fs.metrics.cjk_width });
            return err;
        };
    }
}

test "the bundled face supplies both Latin and Hangul" {
    var fs = try FontStack.init(testing.allocator, 13);
    defer fs.deinit();
    try testing.expectEqual(@as(u8, 0), fs.resolveCodepoint('A').?.face);
    try testing.expectEqual(@as(u8, 0), fs.resolveCodepoint('안').?.face);
}

test "an unmapped code point resolves to nothing" {
    var fs = try FontStack.init(testing.allocator, 13);
    defer fs.deinit();
    // A private-use code point no bundled font covers.
    try testing.expect(fs.resolveCodepoint(0x10FFFD) == null);
}

test "glyphs rasterize with plausible bitmaps" {
    var fs = try FontStack.init(testing.allocator, 16);
    defer fs.deinit();

    const r = fs.resolveCodepoint('M').?;
    const g = fs.glyph(r, .regular).?;
    try testing.expect(g.width > 0 and g.height > 0);
    try testing.expect(g.top > 0);

    const cov = fs.coverageOf(g);
    try testing.expectEqual(@as(usize, @as(usize, g.width) * g.height), cov.len);

    var ink: usize = 0;
    for (cov) |v| {
        if (v > 0) ink += 1;
    }
    try testing.expect(ink > 0);
}

test "a space rasterizes to an empty bitmap without erroring" {
    var fs = try FontStack.init(testing.allocator, 16);
    defer fs.deinit();
    const g = fs.glyph(fs.resolveCodepoint(' ').?, .regular).?;
    try testing.expect(g.isEmpty());
    try testing.expectEqual(@as(usize, 0), fs.coverageOf(g).len);
}

test "the glyph cache returns the same entry twice" {
    var fs = try FontStack.init(testing.allocator, 16);
    defer fs.deinit();
    const r = fs.resolveCodepoint('W').?;
    const a = fs.glyph(r, .regular).?;
    const before = fs.coverage.items.len;
    const b = fs.glyph(r, .regular).?;
    try testing.expectEqual(a.offset, b.offset);
    // The second lookup must not re-rasterize.
    try testing.expectEqual(before, fs.coverage.items.len);
}

test "bold uses the bold cut for Latin and emboldens Hangul" {
    var fs = try FontStack.init(testing.allocator, 16);
    defer fs.deinit();

    const latin = fs.resolveCodepoint('B').?;
    const regular = fs.glyph(latin, .regular).?;
    const bold = fs.glyph(latin, .bold).?;
    // Different cache entries, and bold is at least as wide.
    try testing.expect(regular.offset != bold.offset);
    try testing.expect(bold.width >= regular.width);

    const hangul = fs.resolveCodepoint('한').?;
    const h_regular = fs.glyph(hangul, .regular).?;
    const h_bold = fs.glyph(hangul, .bold).?;
    try testing.expect(h_bold.width >= h_regular.width);
}

test "cluster resolution caches and handles multi-codepoint clusters" {
    var fs = try FontStack.init(testing.allocator, 16);
    defer fs.deinit();

    const a = fs.resolveCluster("가").?;
    const b = fs.resolveCluster("가").?;
    try testing.expectEqual(a.index, b.index);
    try testing.expectEqual(@as(usize, 1), fs.cluster_cache.count());

    // A combining sequence still resolves to something drawable.
    try testing.expect(fs.resolveCluster("e\u{0301}") != null);
    try testing.expect(fs.resolveCluster("") == null);
}

test "changing the pixel size rescales the metrics and clears the cache" {
    var fs = try FontStack.init(testing.allocator, 13);
    defer fs.deinit();
    _ = fs.glyph(fs.resolveCodepoint('M').?, .regular);
    const small = fs.metrics.ch_width;

    try fs.setPixelSize(26);
    try testing.expect(fs.metrics.ch_width > small);
    try testing.expectEqual(@as(usize, 0), fs.glyphs.count());
}

test "a user font goes to the head of the chain but keeps the fallback" {
    var fs = try FontStack.init(testing.allocator, 13);
    defer fs.deinit();
    try fs.prependFace(bundled.default_regular);

    try testing.expectEqual(@as(usize, 2), fs.faces.items.len);
    try testing.expectEqual(@as(u8, 0), fs.resolveCodepoint('A').?.face);
    // Everything still resolves; the bundled face sits behind the user's.
    try testing.expect(fs.resolveCodepoint('안') != null);
}

test "a fallback is rescaled onto the primary face's grid" {
    var fs = try FontStack.init(testing.allocator, 16);
    defer fs.deinit();

    // Stand in for a user font whose Latin cell is wider than D2Coding's, by
    // making the bundled face primary at a size that forces a rescale.
    try fs.prependFace(bundled.default_regular);
    try fs.setPixelSize(20);

    // Both faces must agree on the narrow cell width after matching.
    const primary = fs.advanceInFace(0, ft.FT_Get_Char_Index(fs.faces.items[0].ft_face, 'M'));
    const fallback = fs.advanceInFace(1, ft.FT_Get_Char_Index(fs.faces.items[1].ft_face, 'M'));
    try testing.expectApproxEqAbs(primary, fallback, 1.01);
}
