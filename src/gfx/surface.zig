//! A CPU render target.
//!
//! Nova rasterizes the whole UI into an RGBA surface and hands SDL one texture
//! per frame. That keeps a single code path for what the app draws and what the
//! tests inspect: a golden-image test renders into exactly the same surface the
//! window gets, on a machine with no display at all.
//!
//! At 1200x800 a full repaint is ~3.8 MB of writes. The UI tracks damage and
//! repaints only what changed, so a keystroke touches one row, not the window.

const std = @import("std");
const color = @import("color.zig");

const Rgba = color.Rgba;

pub const Rect = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,

    pub fn right(self: Rect) i32 {
        return self.x + self.w;
    }
    pub fn bottom(self: Rect) i32 {
        return self.y + self.h;
    }
    pub fn isEmpty(self: Rect) bool {
        return self.w <= 0 or self.h <= 0;
    }

    pub fn contains(self: Rect, px: i32, py: i32) bool {
        return px >= self.x and px < self.right() and py >= self.y and py < self.bottom();
    }

    pub fn intersect(a: Rect, b: Rect) Rect {
        const x = @max(a.x, b.x);
        const y = @max(a.y, b.y);
        return .{
            .x = x,
            .y = y,
            .w = @min(a.right(), b.right()) - x,
            .h = @min(a.bottom(), b.bottom()) - y,
        };
    }

    /// The smallest rect covering both. An empty input is ignored.
    pub fn unite(a: Rect, b: Rect) Rect {
        if (a.isEmpty()) return b;
        if (b.isEmpty()) return a;
        const x = @min(a.x, b.x);
        const y = @min(a.y, b.y);
        return .{
            .x = x,
            .y = y,
            .w = @max(a.right(), b.right()) - x,
            .h = @max(a.bottom(), b.bottom()) - y,
        };
    }

    pub fn inset(self: Rect, d: i32) Rect {
        return .{ .x = self.x + d, .y = self.y + d, .w = self.w - 2 * d, .h = self.h - 2 * d };
    }
};

pub const Surface = struct {
    gpa: std.mem.Allocator,
    width: u32,
    height: u32,
    pixels: []Rgba,

    pub fn init(gpa: std.mem.Allocator, width: u32, height: u32) !Surface {
        const pixels = try gpa.alloc(Rgba, @as(usize, width) * height);
        @memset(pixels, .{ .r = 0, .g = 0, .b = 0, .a = 255 });
        return .{ .gpa = gpa, .width = width, .height = height, .pixels = pixels };
    }

    pub fn deinit(self: *Surface) void {
        self.gpa.free(self.pixels);
    }

    pub fn resize(self: *Surface, width: u32, height: u32) !void {
        if (self.width == width and self.height == height) return;
        const pixels = try self.gpa.alloc(Rgba, @as(usize, width) * height);
        self.gpa.free(self.pixels);
        self.pixels = pixels;
        self.width = width;
        self.height = height;
        @memset(self.pixels, .{ .r = 0, .g = 0, .b = 0, .a = 255 });
    }

    pub fn bounds(self: *const Surface) Rect {
        return .{ .x = 0, .y = 0, .w = @intCast(self.width), .h = @intCast(self.height) };
    }

    pub fn at(self: *const Surface, x: i32, y: i32) Rgba {
        if (x < 0 or y < 0 or x >= self.width or y >= self.height) return .{ .r = 0, .g = 0, .b = 0 };
        return self.pixels[@as(usize, @intCast(y)) * self.width + @as(usize, @intCast(x))];
    }

    /// Row slice, for a caller that wants to write a scanline directly.
    pub fn row(self: *Surface, y: i32) []Rgba {
        const yy: usize = @intCast(y);
        return self.pixels[yy * self.width ..][0..self.width];
    }

    pub fn clear(self: *Surface, c: Rgba) void {
        @memset(self.pixels, c);
    }

    /// Opaque fill, clipped to `clip`.
    pub fn fillRect(self: *Surface, rect: Rect, clip: Rect, c: Rgba) void {
        const r = rect.intersect(clip).intersect(self.bounds());
        if (r.isEmpty()) return;
        if (c.a == 0) return;

        var y = r.y;
        while (y < r.bottom()) : (y += 1) {
            const line = self.row(y);
            if (c.a == 255) {
                @memset(line[@intCast(r.x)..@intCast(r.right())], c);
            } else {
                var x: usize = @intCast(r.x);
                const end: usize = @intCast(r.right());
                while (x < end) : (x += 1) line[x] = color.blend(line[x], c);
            }
        }
    }

    /// A one-pixel outline just inside `rect`.
    pub fn strokeRect(self: *Surface, rect: Rect, clip: Rect, c: Rgba) void {
        if (rect.isEmpty()) return;
        self.fillRect(.{ .x = rect.x, .y = rect.y, .w = rect.w, .h = 1 }, clip, c);
        self.fillRect(.{ .x = rect.x, .y = rect.bottom() - 1, .w = rect.w, .h = 1 }, clip, c);
        self.fillRect(.{ .x = rect.x, .y = rect.y, .w = 1, .h = rect.h }, clip, c);
        self.fillRect(.{ .x = rect.right() - 1, .y = rect.y, .w = 1, .h = rect.h }, clip, c);
    }

    /// Blend a single pixel through a coverage mask (0-255), for glyph blitting.
    pub fn blendPixel(self: *Surface, x: i32, y: i32, c: Rgba, coverage: u8) void {
        if (coverage == 0) return;
        if (x < 0 or y < 0 or x >= self.width or y >= self.height) return;
        const idx = @as(usize, @intCast(y)) * self.width + @as(usize, @intCast(x));
        const a: u32 = (@as(u32, c.a) * coverage + 127) / 255;
        self.pixels[idx] = color.blend(self.pixels[idx], c.withAlpha(@intCast(a)));
    }
};

// -- PNG output --------------------------------------------------------------
//
// Golden-image tests need real files to write and diff. Rather than pull in a
// PNG library, this writes one directly: raw scanlines with filter type 0
// through `std.compress.flate` into a zlib stream, which is exactly what an
// IDAT chunk holds.
//
// The compression is not an optimization detail -- a golden is rewritten every
// time the rendering changes, so an uncompressed 900x560 frame would put 2 MB
// into the history each time.

fn crc32(data: []const u8, seed: u32) u32 {
    var c: u32 = seed ^ 0xFFFF_FFFF;
    for (data) |byte| {
        c ^= byte;
        for (0..8) |_| {
            c = if (c & 1 != 0) (c >> 1) ^ 0xEDB8_8320 else c >> 1;
        }
    }
    return c ^ 0xFFFF_FFFF;
}

fn writeChunk(out: *std.ArrayList(u8), gpa: std.mem.Allocator, tag: []const u8, data: []const u8) !void {
    var len_be: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_be, @intCast(data.len), .big);
    try out.appendSlice(gpa, &len_be);
    try out.appendSlice(gpa, tag);
    try out.appendSlice(gpa, data);

    var crc = crc32(tag, 0);
    crc = crc32(data, crc);
    var crc_be: [4]u8 = undefined;
    std.mem.writeInt(u32, &crc_be, crc, .big);
    try out.appendSlice(gpa, &crc_be);
}

/// Encode as an 8-bit RGBA PNG. Caller owns the result.
pub fn encodePng(self: *const Surface, gpa: std.mem.Allocator) ![]u8 {
    // Raw scanlines, each prefixed with filter type 0 (None).
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(gpa);
    try raw.ensureTotalCapacity(gpa, (@as(usize, self.width) * 4 + 1) * self.height);
    for (0..self.height) |y| {
        try raw.append(gpa, 0);
        const line = self.pixels[y * self.width ..][0..self.width];
        for (line) |px| {
            try raw.appendSlice(gpa, &[_]u8{ px.r, px.g, px.b, px.a });
        }
    }

    // Deflate the scanlines into a zlib stream.
    // The compressor asserts the sink has a real buffer to write through, so it
    // is given one up front rather than growing from empty.
    var sink: std.Io.Writer.Allocating = try .initCapacity(gpa, 64 * 1024);
    defer sink.deinit();

    const window = try gpa.alloc(u8, std.compress.flate.max_window_len);
    defer gpa.free(window);

    var deflate = try std.compress.flate.Compress.init(
        &sink.writer,
        window,
        .zlib,
        .default,
    );
    try deflate.writer.writeAll(raw.items);
    try deflate.finish();
    const z = sink.written();

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, &[_]u8{ 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A });

    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], self.width, .big);
    std.mem.writeInt(u32, ihdr[4..8], self.height, .big);
    ihdr[8] = 8; // bit depth
    ihdr[9] = 6; // color type: RGBA
    ihdr[10] = 0; // deflate
    ihdr[11] = 0; // adaptive filtering
    ihdr[12] = 0; // no interlace
    try writeChunk(&out, gpa, "IHDR", &ihdr);
    try writeChunk(&out, gpa, "IDAT", z);
    try writeChunk(&out, gpa, "IEND", "");

    return out.toOwnedSlice(gpa);
}

// -- tests -------------------------------------------------------------------

const testing = std.testing;
const palette = color.palette;

test "rect geometry" {
    const a = Rect{ .x = 0, .y = 0, .w = 10, .h = 10 };
    const b = Rect{ .x = 5, .y = 5, .w = 10, .h = 10 };

    const i = a.intersect(b);
    try testing.expectEqual(@as(i32, 5), i.x);
    try testing.expectEqual(@as(i32, 5), i.w);

    const u = a.unite(b);
    try testing.expectEqual(@as(i32, 0), u.x);
    try testing.expectEqual(@as(i32, 15), u.w);

    // Disjoint rects intersect to nothing.
    try testing.expect(a.intersect(.{ .x = 100, .y = 100, .w = 1, .h = 1 }).isEmpty());
    // Uniting with an empty rect is a no-op.
    try testing.expectEqual(a.w, a.unite(.{ .x = 0, .y = 0, .w = 0, .h = 0 }).w);

    try testing.expect(a.contains(0, 0));
    try testing.expect(!a.contains(10, 0));
}

test "fillRect respects the clip" {
    var s = try Surface.init(testing.allocator, 8, 8);
    defer s.deinit();
    s.clear(palette.bg_0);

    s.fillRect(.{ .x = 0, .y = 0, .w = 8, .h = 8 }, .{ .x = 2, .y = 2, .w = 2, .h = 2 }, palette.accent);

    try testing.expect(s.at(2, 2).eql(palette.accent));
    try testing.expect(s.at(3, 3).eql(palette.accent));
    try testing.expect(s.at(4, 4).eql(palette.bg_0));
    try testing.expect(s.at(1, 1).eql(palette.bg_0));
}

test "fillRect blends translucent colors" {
    var s = try Surface.init(testing.allocator, 4, 4);
    defer s.deinit();
    s.clear(.{ .r = 0, .g = 0, .b = 0 });
    s.fillRect(s.bounds(), s.bounds(), .{ .r = 255, .g = 255, .b = 255, .a = 128 });
    try testing.expectEqual(@as(u8, 128), s.at(0, 0).r);
}

test "drawing outside the surface is clipped, not a crash" {
    var s = try Surface.init(testing.allocator, 4, 4);
    defer s.deinit();
    s.clear(palette.bg_0);
    s.fillRect(.{ .x = -10, .y = -10, .w = 100, .h = 100 }, s.bounds(), palette.accent);
    try testing.expect(s.at(0, 0).eql(palette.accent));
    try testing.expect(s.at(3, 3).eql(palette.accent));
    s.blendPixel(-1, -1, palette.fg_0, 255);
    s.blendPixel(99, 99, palette.fg_0, 255);
}

test "strokeRect draws only the border" {
    var s = try Surface.init(testing.allocator, 6, 6);
    defer s.deinit();
    s.clear(palette.bg_0);
    s.strokeRect(.{ .x = 1, .y = 1, .w = 4, .h = 4 }, s.bounds(), palette.bg_3);

    try testing.expect(s.at(1, 1).eql(palette.bg_3));
    try testing.expect(s.at(4, 4).eql(palette.bg_3));
    try testing.expect(s.at(2, 2).eql(palette.bg_0)); // interior untouched
}

test "blendPixel applies coverage" {
    var s = try Surface.init(testing.allocator, 2, 2);
    defer s.deinit();
    s.clear(.{ .r = 0, .g = 0, .b = 0 });
    s.blendPixel(0, 0, .{ .r = 255, .g = 255, .b = 255 }, 128);
    try testing.expectEqual(@as(u8, 128), s.at(0, 0).r);
    s.blendPixel(1, 1, .{ .r = 255, .g = 255, .b = 255 }, 0);
    try testing.expectEqual(@as(u8, 0), s.at(1, 1).r);
}

test "png output has the right header and is non-trivial" {
    var s = try Surface.init(testing.allocator, 4, 3);
    defer s.deinit();
    s.clear(palette.accent);

    const png = try encodePng(&s, testing.allocator);
    defer testing.allocator.free(png);

    try testing.expectEqualSlices(u8, &[_]u8{ 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A }, png[0..8]);
    try testing.expectEqualSlices(u8, "IHDR", png[12..16]);
    try testing.expectEqual(@as(u32, 4), std.mem.readInt(u32, png[16..20], .big));
    try testing.expectEqual(@as(u32, 3), std.mem.readInt(u32, png[20..24], .big));
    try testing.expect(std.mem.indexOf(u8, png, "IDAT") != null);
    try testing.expect(std.mem.endsWith(u8, png, "IEND\xae\x42\x60\x82"));
}

test "resize reallocates and clears" {
    var s = try Surface.init(testing.allocator, 2, 2);
    defer s.deinit();
    s.clear(palette.accent);
    try s.resize(4, 4);
    try testing.expectEqual(@as(u32, 4), s.width);
    try testing.expectEqual(@as(usize, 16), s.pixels.len);
    try testing.expect(!s.at(0, 0).eql(palette.accent));
}
