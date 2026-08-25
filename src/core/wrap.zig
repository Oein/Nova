//! Soft wrap: where a logical line breaks into visual rows.
//!
//! Ported from `src/lib/editor/wrap.ts`. Columns are **byte** offsets into the
//! line, not UTF-16 code units.

const std = @import("std");
const grapheme = @import("grapheme.zig");
const width = @import("width.zig");

pub const Metrics = struct {
    /// Advance of a narrow cell, in pixels.
    ch_width: f64,
    /// Advance of a wide (East Asian) cell, in pixels.
    cjk_width: f64,
    /// Tab stop, in narrow cells.
    tab_size: u8,
};

/// Column positions where visual rows start. Entry 0 is always 0.
pub const Starts = struct {
    cols: []const usize,

    pub fn deinit(self: Starts, gpa: std.mem.Allocator) void {
        gpa.free(self.cols);
    }

    /// Sub-row index containing byte offset `col`.
    ///
    /// A linear backward scan, as in the original: lines have a handful of
    /// sub-rows, and the scan starts from the end where the caret usually is.
    pub fn subRowAt(self: Starts, col: usize) usize {
        var sr = self.cols.len - 1;
        while (sr > 0 and self.cols[sr] > col) sr -= 1;
        return sr;
    }

    /// Byte range of sub-row `sr` within a line of length `line_len`.
    pub fn rowRange(self: Starts, sr: usize, line_len: usize) struct { start: usize, end: usize } {
        const start = self.cols[sr];
        const end = if (sr + 1 < self.cols.len) self.cols[sr + 1] else line_len;
        return .{ .start = start, .end = end };
    }

    pub fn rowCount(self: Starts) usize {
        return self.cols.len;
    }
};

fn isWs(cluster: []const u8) bool {
    return cluster.len == 1 and (cluster[0] == ' ' or cluster[0] == '\t');
}

fn cellPx(cluster: []const u8, m: Metrics) f64 {
    return if (width.clusterIsWide(cluster)) m.cjk_width else m.ch_width;
}

/// Compute where visual rows start for a soft wrap at `max_px`.
///
/// Word-aware with three-tier priority:
///   1. Whitespace boundary (highest) -- the natural word break, and what
///      Korean/English/spaced-Japanese need.
///   2. CJK boundary (fallback) -- any wide-character boundary is a legal break
///      when the row holds no whitespace at all, so an unspaced Chinese or
///      Japanese sentence still wraps.
///   3. Hard grapheme break (last resort) -- a 100-character URL has to wrap
///      somewhere.
///
/// Tier 1 beats tier 2 so Korean compounds like `시문집` stay intact when the
/// line has spaces elsewhere. A cluster wider than `max_px` still gets its own
/// row; clusters are never split.
pub fn computeStarts(
    gpa: std.mem.Allocator,
    line: []const u8,
    max_px: f64,
    m: Metrics,
) !Starts {
    var starts: std.ArrayList(usize) = .empty;
    errdefer starts.deinit(gpa);
    try starts.append(gpa, 0);

    if (max_px <= 0 or line.len == 0) {
        return .{ .cols = try starts.toOwnedSlice(gpa) };
    }

    const tab_px = @as(f64, @floatFromInt(m.tab_size)) * m.ch_width;

    var row_start: usize = 0;
    // Cumulative width from row_start up to (but not including) the current
    // cluster.
    var x: f64 = 0;
    // Two classes of break opportunity, tracked separately so whitespace wins
    // over a CJK boundary.
    var ws_col: ?usize = null;
    var x_at_ws: f64 = 0;
    var cjk_col: ?usize = null;
    var x_at_cjk: f64 = 0;
    var prev: ?[]const u8 = null;

    var it = grapheme.iterate(line);
    while (it.nextCluster()) |g| {
        const is_tab = g.text.len == 1 and g.text[0] == '\t';
        const cw = if (is_tab)
            (@floor(x / tab_px) + 1) * tab_px - x
        else
            cellPx(g.text, m);

        // Classify the boundary just before `g`.
        if (prev) |p| {
            if (g.offset > row_start) {
                if (isWs(p)) {
                    ws_col = g.offset;
                    x_at_ws = x;
                } else if (width.clusterIsCjkLike(p) or width.clusterIsCjkLike(g.text)) {
                    cjk_col = g.offset;
                    x_at_cjk = x;
                }
            }
        }

        if (x + cw > max_px and x > 0) {
            if (isWs(g.text)) {
                // Whitespace at the end of a row may overflow -- CSS
                // `white-space: normal` semantics. The wrap lands *after* it, so
                // trailing spaces cling to the old row.
                x += cw;
                ws_col = g.offset + g.text.len;
                x_at_ws = x;
            } else if (ws_col != null and ws_col.? > row_start) {
                try starts.append(gpa, ws_col.?);
                row_start = ws_col.?;
                x = x - x_at_ws + cw;
                ws_col = null;
                x_at_ws = 0;
                cjk_col = null;
                x_at_cjk = 0;
            } else if (cjk_col != null and cjk_col.? > row_start) {
                try starts.append(gpa, cjk_col.?);
                row_start = cjk_col.?;
                x = x - x_at_cjk + cw;
                cjk_col = null;
                x_at_cjk = 0;
            } else {
                try starts.append(gpa, g.offset);
                row_start = g.offset;
                x = cw;
                ws_col = null;
                x_at_ws = 0;
                cjk_col = null;
                x_at_cjk = 0;
            }
        } else {
            x += cw;
        }

        prev = g.text;
    }

    return .{ .cols = try starts.toOwnedSlice(gpa) };
}

/// Pixel advance from the start of `slice` to byte offset `col` within it.
///
/// Tab stops are measured from the start of the slice, which -- because callers
/// pass a single wrapped sub-row -- means tab stops restart on each visual row.
/// That matches the original (`Editor.svelte:769`).
pub fn advanceTo(slice: []const u8, col: usize, m: Metrics) f64 {
    const tab_px = @as(f64, @floatFromInt(m.tab_size)) * m.ch_width;
    var x: f64 = 0;
    var it = grapheme.iterate(slice);
    while (it.nextCluster()) |g| {
        if (g.offset >= col) break;
        if (g.text.len == 1 and g.text[0] == '\t') {
            x = (@floor(x / tab_px) + 1) * tab_px;
        } else {
            x += cellPx(g.text, m);
        }
    }
    return x;
}

/// Inverse of `advanceTo`: the byte offset nearest to pixel position `px`.
///
/// Rounds to whichever cluster edge is closer, so clicking the right half of a
/// character puts the caret after it.
pub fn colFromPx(slice: []const u8, px: f64, m: Metrics) usize {
    const tab_px = @as(f64, @floatFromInt(m.tab_size)) * m.ch_width;
    var x: f64 = 0;
    var it = grapheme.iterate(slice);
    while (it.nextCluster()) |g| {
        const is_tab = g.text.len == 1 and g.text[0] == '\t';
        const cw = if (is_tab) (@floor(x / tab_px) + 1) * tab_px - x else cellPx(g.text, m);
        if (px < x + cw) {
            return if (px - x >= cw / 2) g.offset + g.text.len else g.offset;
        }
        x += cw;
    }
    return slice.len;
}

// -- tests -------------------------------------------------------------------
// Ported from src/lib/editor/wrap.test.ts. Expected columns are byte offsets,
// so the Korean cases differ numerically from the UTF-16 originals (each
// Hangul syllable is 3 bytes rather than 1 unit).

const testing = std.testing;

/// 1px per ASCII cell, 2px per CJK cell -- makes the arithmetic trivial.
const M: Metrics = .{ .ch_width = 1, .cjk_width = 2, .tab_size = 4 };

fn expectStarts(expected: []const usize, line: []const u8, max_px: f64) !void {
    const s = try computeStarts(testing.allocator, line, max_px, M);
    defer s.deinit(testing.allocator);
    testing.expectEqualSlices(usize, expected, s.cols) catch |err| {
        std.debug.print("line={s} max_px={d}\n", .{ line, max_px });
        return err;
    };
}

test "empty line is a single row" {
    try expectStarts(&.{0}, "", 10);
}

test "line that fits is a single row" {
    try expectStarts(&.{0}, "hello", 100);
}

test "breaks after whitespace rather than mid-word" {
    try expectStarts(&.{ 0, 8 }, "foo bar baz", 7);
}

test "breaks at multiple word boundaries" {
    try expectStarts(&.{ 0, 6, 12 }, "aa bb cc dd ee", 5);
}

test "hard-breaks unbroken long strings" {
    try expectStarts(&.{ 0, 3, 6, 9 }, "aaaaaaaaaa", 3);
}

test "wraps between CJK characters with no spaces" {
    // Two 2px syllables per 5px row; byte offsets 0, 6, 12.
    try expectStarts(&.{ 0, 6, 12 }, "안녕하세요", 5);
}

test "prefers whitespace break over mid-CJK break (Korean compound)" {
    // `한국 시문집을`: the space is at byte 6, so the break lands at byte 7 and
    // `시문집을` stays intact instead of splitting mid-compound.
    try expectStarts(&.{ 0, 7 }, "한국 시문집을", 8);
}

test "wraps between ASCII and CJK on the CJK boundary" {
    try expectStarts(&.{ 0, 3 }, "abc안녕", 4);
}

test "a leading grapheme wider than the row still gets its own row" {
    try expectStarts(&.{ 0, 3 }, "안녕", 1);
}

test "trailing whitespace overflows and wraps after the last space" {
    try expectStarts(&.{ 0, 6 }, "foo   bar", 5);
}

test "no break opportunity in the first row falls through to a hard break" {
    try expectStarts(&.{ 0, 3, 6, 9 }, "abcdefgh xy", 3);
}

test "tabs count toward width with tab-stop rounding" {
    try expectStarts(&.{0}, "a\tb", 5);
    try expectStarts(&.{ 0, 2 }, "a\tb", 4);
}

test "subRowAt finds the row containing a column" {
    const s = try computeStarts(testing.allocator, "aa bb cc dd ee", 5, M);
    defer s.deinit(testing.allocator);
    // cols == { 0, 6, 12 }
    try testing.expectEqual(@as(usize, 0), s.subRowAt(0));
    try testing.expectEqual(@as(usize, 0), s.subRowAt(5));
    try testing.expectEqual(@as(usize, 1), s.subRowAt(6));
    try testing.expectEqual(@as(usize, 1), s.subRowAt(11));
    try testing.expectEqual(@as(usize, 2), s.subRowAt(12));
    try testing.expectEqual(@as(usize, 2), s.subRowAt(14));
}

test "advanceTo and colFromPx round-trip on cluster edges" {
    const line = "ab안c";
    try testing.expectEqual(@as(f64, 0), advanceTo(line, 0, M));
    try testing.expectEqual(@as(f64, 2), advanceTo(line, 2, M));
    try testing.expectEqual(@as(f64, 4), advanceTo(line, 5, M)); // after 안
    // Clicking the left half of `안` (x in [2, 3)) lands before it.
    try testing.expectEqual(@as(usize, 2), colFromPx(line, 2.4, M));
    // The right half lands after it.
    try testing.expectEqual(@as(usize, 5), colFromPx(line, 3.6, M));
    // Past the end clamps to the line length.
    try testing.expectEqual(@as(usize, 6), colFromPx(line, 99, M));
}

test "advanceTo restarts tab stops per slice" {
    // A tab at the start of a sub-row advances a full stop.
    try testing.expectEqual(@as(f64, 4), advanceTo("\tx", 1, M));
    // `ab\t` -> the tab fills to the next multiple of 4.
    try testing.expectEqual(@as(f64, 4), advanceTo("ab\tx", 3, M));
}
