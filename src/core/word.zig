//! Double-click word selection.
//!
//! Ported from `src/lib/editor/wordAt.ts`. Characters fall into three classes
//! -- word, whitespace, other -- and the range expands in both directions while
//! the class holds. That matches macOS / Sublime / VS Code:
//!
//!     double-click on "foo"  -> selects foo
//!     double-click on spaces -> selects the whitespace run
//!     double-click on "+="   -> selects the punctuation run
//!
//! Note this is a *different* word model from the one `commands.zig` uses for
//! Alt+Arrow, which splits on whitespace only. The divergence is deliberate and
//! matches the original.
//!
//! Offsets are byte offsets. Like the original, this is grapheme-naive: a
//! combining mark classifies the same as its base character, so it sticks to it.

const std = @import("std");
const table = @import("wordchar_table.zig");

pub const Class = enum { word, ws, other };

/// General_Category L* or N*. Also used by filename slugification, which
/// keeps exactly the characters Rust's `char::is_alphanumeric` kept.
pub fn isLetterOrNumber(cp: u21) bool {
    var lo: usize = 0;
    var hi: usize = table.word_ranges.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const r = table.word_ranges[mid];
        if (cp < r.lo) {
            hi = mid;
        } else if (cp > r.hi) {
            lo = mid + 1;
        } else {
            return true;
        }
    }
    return false;
}

pub fn classOf(cp: u21) Class {
    if (cp == ' ' or cp == '\t') return .ws;
    if (cp == '_' or isLetterOrNumber(cp)) return .word;
    return .other;
}

fn cpAt(line: []const u8, i: usize) u21 {
    const len = std.unicode.utf8ByteSequenceLength(line[i]) catch return 0xFFFD;
    if (i + len > line.len) return 0xFFFD;
    return std.unicode.utf8Decode(line[i..][0..len]) catch 0xFFFD;
}

fn stepBack(line: []const u8, i: usize) usize {
    var j = i;
    var guard: usize = 0;
    while (j > 0 and guard < 4) {
        j -= 1;
        guard += 1;
        if (line[j] & 0xC0 != 0x80) break;
    }
    return j;
}

fn stepForward(line: []const u8, i: usize) usize {
    const len = std.unicode.utf8ByteSequenceLength(line[i]) catch return i + 1;
    return @min(i + len, line.len);
}

pub const Range = struct { start: usize, end: usize };

/// The `[start, end)` byte range of the run containing `col`.
///
/// A `col` past the end of the line backs up one code point, so clicking the
/// empty space after a word still selects the word. An empty line yields
/// `{ 0, 0 }`; the caller treats that as "nothing to select".
pub fn wordAt(line: []const u8, col: usize) Range {
    if (line.len == 0) return .{ .start = 0, .end = 0 };

    // Land on a code point start at or before `col`.
    var i = @min(col, line.len - 1);
    while (i > 0 and line[i] & 0xC0 == 0x80) i -= 1;

    const cls = classOf(cpAt(line, i));

    var start = i;
    while (start > 0) {
        const p = stepBack(line, start);
        if (classOf(cpAt(line, p)) != cls) break;
        start = p;
    }

    var end = stepForward(line, i);
    while (end < line.len) {
        if (classOf(cpAt(line, end)) != cls) break;
        end = stepForward(line, end);
    }

    return .{ .start = start, .end = end };
}

// -- tests -------------------------------------------------------------------
// Ported from src/lib/editor/wordAt.test.ts. Ranges are byte offsets, so the
// CJK case differs numerically from the UTF-16 original.

const testing = std.testing;

fn expectRange(expected: Range, line: []const u8, col: usize) !void {
    const got = wordAt(line, col);
    testing.expectEqual(expected, got) catch |err| {
        std.debug.print("line={s} col={d}\n", .{ line, col });
        return err;
    };
}

test "classifies ASCII letters, digits and underscore as word" {
    for ([_]u21{ 'a', 'Z', '0', '9', '_' }) |cp| {
        try testing.expectEqual(Class.word, classOf(cp));
    }
}

test "classifies space and tab as whitespace" {
    try testing.expectEqual(Class.ws, classOf(' '));
    try testing.expectEqual(Class.ws, classOf('\t'));
}

test "classifies punctuation as other" {
    for ([_]u21{ '.', ',', '+', '=', '(', ')', '!', '?' }) |cp| {
        try testing.expectEqual(Class.other, classOf(cp));
    }
}

test "classifies CJK and Hangul as word" {
    try testing.expectEqual(Class.word, classOf('가'));
    try testing.expectEqual(Class.word, classOf('漢'));
    try testing.expectEqual(Class.word, classOf('あ'));
}

test "returns the ASCII word under the cursor" {
    const line = "foo bar baz";
    try expectRange(.{ .start = 0, .end = 3 }, line, 0);
    try expectRange(.{ .start = 0, .end = 3 }, line, 2);
    try expectRange(.{ .start = 4, .end = 7 }, line, 4);
    try expectRange(.{ .start = 8, .end = 11 }, line, 10);
}

test "selects whitespace runs" {
    const line = "foo   bar";
    try expectRange(.{ .start = 3, .end = 6 }, line, 3);
    try expectRange(.{ .start = 3, .end = 6 }, line, 4);
}

test "selects punctuation runs" {
    const line = "x += 1";
    try expectRange(.{ .start = 2, .end = 4 }, line, 2);
    try expectRange(.{ .start = 2, .end = 4 }, line, 3);
}

test "a click past the end grabs the trailing run" {
    try expectRange(.{ .start = 0, .end = 5 }, "hello", 99);
}

test "an empty line yields an empty range" {
    try expectRange(.{ .start = 0, .end = 0 }, "", 0);
    try expectRange(.{ .start = 0, .end = 0 }, "", 5);
}

test "groups CJK characters into a word" {
    // `안녕 world`: 안녕 spans bytes 0..6, the space is byte 6, world is 7..12.
    const line = "안녕 world";
    try expectRange(.{ .start = 0, .end = 6 }, line, 0);
    try expectRange(.{ .start = 0, .end = 6 }, line, 3);
    try expectRange(.{ .start = 7, .end = 12 }, line, 7);
}

test "a click mid-codepoint snaps to the code point start" {
    // Byte 1 is a continuation byte of 안; it must still select the word.
    try expectRange(.{ .start = 0, .end = 6 }, "안녕 world", 1);
}

test "treats underscore as part of the word" {
    const line = "my_var = 1";
    try expectRange(.{ .start = 0, .end = 6 }, line, 0);
    try expectRange(.{ .start = 0, .end = 6 }, line, 3);
}
