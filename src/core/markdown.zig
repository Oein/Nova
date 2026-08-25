//! The inline markdown styling used by the editor.
//!
//! Ported from `tokenizeMarkdownRanges` in `src/lib/components/Editor.svelte`
//! (:964). This is not a markdown parser -- it is the small set of styles the
//! editor paints in place, Obsidian-source-mode style, with the delimiters left
//! visible:
//!
//!     `# `/`## `/`### ` prefix  -> the whole line is bold
//!     `**bold**`  `__underline__`  `~~strike~~`
//!
//! Tokenizing runs over a whole buffer line, never a wrapped sub-row, so a
//! `**bold**` span keeps its styling across a soft-wrap boundary.
//!
//! Not supported, matching the original: italics, inline code, fences, links,
//! lists, quotes, tables, headings past level 3, nesting, escapes.

const std = @import("std");

pub const Style = packed struct {
    bold: bool = false,
    underline: bool = false,
    strike: bool = false,

    pub fn eql(a: Style, b: Style) bool {
        return a.bold == b.bold and a.underline == b.underline and a.strike == b.strike;
    }
};

/// A styled run, as a byte range into the line.
pub const TokenRange = struct {
    start: usize,
    end: usize,
    style: Style,
};

/// A styled run with its text, clipped to one wrapped sub-row.
pub const Token = struct {
    text: []const u8,
    style: Style,
};

const Delim = struct { text: []const u8, style: Style };

const delims = [_]Delim{
    .{ .text = "**", .style = .{ .bold = true } },
    .{ .text = "__", .style = .{ .underline = true } },
    .{ .text = "~~", .style = .{ .strike = true } },
};

fn isHeading(line: []const u8) bool {
    var i: usize = 0;
    while (i < line.len and line[i] == '#') i += 1;
    return i >= 1 and i <= 3 and i < line.len and line[i] == ' ';
}

/// Split `line` into styled byte ranges covering it end to end.
/// Caller owns the returned slice.
pub fn tokenize(gpa: std.mem.Allocator, line: []const u8) ![]TokenRange {
    const heading_bold = isHeading(line);

    var out: std.ArrayList(TokenRange) = .empty;
    errdefer out.deinit(gpa);

    var i: usize = 0;
    var plain_start: ?usize = null;

    // Emitting the pending plain run, if any, up to `end`.
    const flushPlain = struct {
        fn f(
            list: *std.ArrayList(TokenRange),
            a: std.mem.Allocator,
            start: *?usize,
            end: usize,
            bold: bool,
        ) !void {
            if (start.*) |s| {
                if (s < end) {
                    try list.append(a, .{ .start = s, .end = end, .style = .{ .bold = bold } });
                }
            }
            start.* = null;
        }
    }.f;

    outer: while (i < line.len) {
        for (delims) |d| {
            if (!std.mem.startsWith(u8, line[i..], d.text)) continue;
            const rest = line[i + 2 ..];
            const rel = std.mem.indexOf(u8, rest, d.text) orelse continue;
            const closer = i + 2 + rel;
            // `closer > i + 2` rejects an empty span like `****`.
            if (closer <= i + 2) continue;

            try flushPlain(&out, gpa, &plain_start, i, heading_bold);
            var style = d.style;
            if (heading_bold) style.bold = true;
            // The delimiters stay inside the styled range -- they remain
            // visible in the editor.
            try out.append(gpa, .{ .start = i, .end = closer + 2, .style = style });
            i = closer + 2;
            continue :outer;
        }
        if (plain_start == null) plain_start = i;
        i += 1;
    }

    try flushPlain(&out, gpa, &plain_start, line.len, heading_bold);
    return out.toOwnedSlice(gpa);
}

/// Clip `ranges` to the byte window `[sub_start, sub_end)` of `line`, producing
/// the spans one wrapped sub-row renders. Caller owns the returned slice.
pub fn tokensForSlice(
    gpa: std.mem.Allocator,
    ranges: []const TokenRange,
    line: []const u8,
    sub_start: usize,
    sub_end: usize,
) ![]Token {
    var out: std.ArrayList(Token) = .empty;
    errdefer out.deinit(gpa);
    for (ranges) |r| {
        const s = @max(r.start, sub_start);
        const e = @min(r.end, sub_end);
        if (s >= e) continue;
        try out.append(gpa, .{ .text = line[s..e], .style = r.style });
    }
    return out.toOwnedSlice(gpa);
}

pub const Split = struct { before: []Token, after: []Token };

/// Split a row's tokens at byte offset `at` within their concatenated text.
/// Used to open a gap for inline IME preedit. Caller owns both slices.
pub fn splitTokensAt(gpa: std.mem.Allocator, tokens: []const Token, at: usize) !Split {
    var before: std.ArrayList(Token) = .empty;
    errdefer before.deinit(gpa);
    var after: std.ArrayList(Token) = .empty;
    errdefer after.deinit(gpa);

    var offset: usize = 0;
    for (tokens) |t| {
        const end = offset + t.text.len;
        if (end <= at) {
            try before.append(gpa, t);
        } else if (offset >= at) {
            try after.append(gpa, t);
        } else {
            const cut = at - offset;
            try before.append(gpa, .{ .text = t.text[0..cut], .style = t.style });
            try after.append(gpa, .{ .text = t.text[cut..], .style = t.style });
        }
        offset = end;
    }
    return .{
        .before = try before.toOwnedSlice(gpa),
        .after = try after.toOwnedSlice(gpa),
    };
}

// -- tests -------------------------------------------------------------------

const testing = std.testing;

fn expectRanges(expected: []const TokenRange, line: []const u8) !void {
    const got = try tokenize(testing.allocator, line);
    defer testing.allocator.free(got);
    testing.expectEqualSlices(TokenRange, expected, got) catch |err| {
        std.debug.print("line={s}\n", .{line});
        for (got) |r| std.debug.print("  {d}..{d} {any}\n", .{ r.start, r.end, r.style });
        return err;
    };
}

test "plain text is one unstyled run" {
    try expectRanges(&.{.{ .start = 0, .end = 5, .style = .{} }}, "hello");
}

test "empty line yields no runs" {
    try expectRanges(&.{}, "");
}

test "heading prefix bolds the entire line" {
    try expectRanges(&.{.{ .start = 0, .end = 9, .style = .{ .bold = true } }}, "## Title!");
}

test "heading needs a space and at most three hashes" {
    try expectRanges(&.{.{ .start = 0, .end = 6, .style = .{} }}, "#Title");
    try expectRanges(&.{.{ .start = 0, .end = 10, .style = .{} }}, "#### Title");
}

test "bold span keeps its delimiters inside the range" {
    // `a **b** c` -> plain 0..2, bold 2..7, plain 7..9
    try expectRanges(&.{
        .{ .start = 0, .end = 2, .style = .{} },
        .{ .start = 2, .end = 7, .style = .{ .bold = true } },
        .{ .start = 7, .end = 9, .style = .{} },
    }, "a **b** c");
}

test "underline and strike" {
    try expectRanges(&.{.{ .start = 0, .end = 5, .style = .{ .underline = true } }}, "__x__");
    try expectRanges(&.{.{ .start = 0, .end = 5, .style = .{ .strike = true } }}, "~~x~~");
}

test "an unclosed delimiter stays plain" {
    try expectRanges(&.{.{ .start = 0, .end = 6, .style = .{} }}, "**oops");
}

test "an empty span is not styled" {
    // `****` has a closer at i+2, which the `closer > i + 2` guard rejects.
    try expectRanges(&.{.{ .start = 0, .end = 4, .style = .{} }}, "****");
}

test "styling combines with a heading" {
    const got = try tokenize(testing.allocator, "# a ~~b~~");
    defer testing.allocator.free(got);
    try testing.expectEqual(@as(usize, 2), got.len);
    try testing.expect(got[1].style.strike);
    try testing.expect(got[1].style.bold); // inherited from the heading
}

test "Korean text tokenizes on byte boundaries" {
    // `**안녕**` -- one bold run: 2 + 6 + 2 = 10 bytes.
    try expectRanges(&.{.{ .start = 0, .end = 10, .style = .{ .bold = true } }}, "**안녕**");
}

test "tokensForSlice clips to a wrapped sub-row" {
    const line = "a **bb** c";
    const ranges = try tokenize(testing.allocator, line);
    defer testing.allocator.free(ranges);

    // Sub-row covering bytes 2..8 -- exactly the bold span.
    const toks = try tokensForSlice(testing.allocator, ranges, line, 2, 8);
    defer testing.allocator.free(toks);
    try testing.expectEqual(@as(usize, 1), toks.len);
    try testing.expectEqualStrings("**bb**", toks[0].text);
    try testing.expect(toks[0].style.bold);

    // A window straddling the boundary clips both runs.
    const straddle = try tokensForSlice(testing.allocator, ranges, line, 1, 5);
    defer testing.allocator.free(straddle);
    try testing.expectEqual(@as(usize, 2), straddle.len);
    try testing.expectEqualStrings(" ", straddle[0].text);
    try testing.expectEqualStrings("**b", straddle[1].text);
}

test "splitTokensAt opens a gap inside a run" {
    const line = "ab**cd**";
    const ranges = try tokenize(testing.allocator, line);
    defer testing.allocator.free(ranges);
    const toks = try tokensForSlice(testing.allocator, ranges, line, 0, line.len);
    defer testing.allocator.free(toks);

    const s = try splitTokensAt(testing.allocator, toks, 1);
    defer testing.allocator.free(s.before);
    defer testing.allocator.free(s.after);
    try testing.expectEqual(@as(usize, 1), s.before.len);
    try testing.expectEqualStrings("a", s.before[0].text);
    try testing.expectEqual(@as(usize, 2), s.after.len);
    try testing.expectEqualStrings("b", s.after[0].text);
    try testing.expectEqualStrings("**cd**", s.after[1].text);
}

test "splitTokensAt at a token boundary does not create empty pieces" {
    const line = "ab**cd**";
    const ranges = try tokenize(testing.allocator, line);
    defer testing.allocator.free(ranges);
    const toks = try tokensForSlice(testing.allocator, ranges, line, 0, line.len);
    defer testing.allocator.free(toks);

    const s = try splitTokensAt(testing.allocator, toks, 2);
    defer testing.allocator.free(s.before);
    defer testing.allocator.free(s.after);
    try testing.expectEqual(@as(usize, 1), s.before.len);
    try testing.expectEqual(@as(usize, 1), s.after.len);
}
