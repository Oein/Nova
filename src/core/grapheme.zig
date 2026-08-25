//! UAX #29 extended grapheme cluster boundaries.
//!
//! Replaces `src/lib/editor/grapheme.ts`, which delegated to the browser's
//! `Intl.Segmenter`. Two behavioral notes carried over from that port:
//!
//!   * Offsets are **byte** offsets into UTF-8, not UTF-16 code units.
//!   * `prev` is O(cluster length), not O(offset). The TS version re-segmented
//!     the entire prefix on every backward step, which put an allocation and a
//!     full-line scan in the caret/hit-test hot path.

const std = @import("std");
const table = @import("grapheme_table.zig");

const Prop = table.Prop;
const Incb = table.Incb;

fn lookup(comptime V: type, ranges: []const table.Range(V), cp: u21, none: V) V {
    var lo: usize = 0;
    var hi: usize = ranges.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const r = ranges[mid];
        if (cp < r.lo) {
            hi = mid;
        } else if (cp > r.hi) {
            lo = mid + 1;
        } else {
            return r.value;
        }
    }
    return none;
}

fn prop(cp: u21) Prop {
    return lookup(Prop, &table.gb_ranges, cp, .none);
}

fn incb(cp: u21) Incb {
    return lookup(Incb, &table.incb_ranges, cp, .none);
}

fn isPictographic(cp: u21) bool {
    var lo: usize = 0;
    var hi: usize = table.pict_ranges.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const r = table.pict_ranges[mid];
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

// -- code point stepping -----------------------------------------------------
//
// These tolerate malformed UTF-8 by treating each bad byte as one U+FFFD-ish
// unit, so an editor never gets stuck on a corrupt file.

const CpBack = struct { cp: u21, start: usize };

fn cpAt(s: []const u8, i: usize) u21 {
    const len = std.unicode.utf8ByteSequenceLength(s[i]) catch return 0xFFFD;
    if (i + len > s.len) return 0xFFFD;
    return std.unicode.utf8Decode(s[i..][0..len]) catch 0xFFFD;
}

fn nextCp(s: []const u8, i: usize) usize {
    const len = std.unicode.utf8ByteSequenceLength(s[i]) catch return i + 1;
    return @min(i + len, s.len);
}

fn prevCp(s: []const u8, i: usize) CpBack {
    var j = i;
    // Step back over continuation bytes to find the lead byte.
    var guard: usize = 0;
    while (j > 0 and guard < 4) {
        j -= 1;
        guard += 1;
        if (s[j] & 0xC0 != 0x80) break;
    }
    return .{ .cp = cpAt(s, j), .start = j };
}

// -- boundary rules ----------------------------------------------------------

/// GB9c: `Consonant [InCB=Extend InCB=Linker]* Linker [InCB=Extend InCB=Linker]*`
/// ending at `end` (exclusive), with at least one Linker in the run.
fn linkedConsonantBefore(s: []const u8, end: usize) bool {
    var i = end;
    var saw_linker = false;
    while (i > 0) {
        const b = prevCp(s, i);
        switch (incb(b.cp)) {
            .linker => saw_linker = true,
            .extend => {},
            .consonant => return saw_linker,
            .none => return false,
        }
        i = b.start;
    }
    return false;
}

/// GB11: `Extended_Pictographic Extend*` ending at `end` (exclusive).
fn pictographicBefore(s: []const u8, end: usize) bool {
    var i = end;
    while (i > 0) {
        const b = prevCp(s, i);
        if (isPictographic(b.cp)) return true;
        if (prop(b.cp) != .extend) return false;
        i = b.start;
    }
    return false;
}

/// GB12/GB13: number of Regional_Indicator code points ending at `end`.
fn regionalIndicatorRun(s: []const u8, end: usize) usize {
    var i = end;
    var n: usize = 0;
    while (i > 0) {
        const b = prevCp(s, i);
        if (prop(b.cp) != .regional_indicator) break;
        n += 1;
        i = b.start;
    }
    return n;
}

/// Is there a cluster boundary immediately before byte offset `pos`?
///
/// `pos` must sit on a code point boundary. Offsets 0 and `s.len` are always
/// boundaries (GB1, GB2).
pub fn isBoundary(s: []const u8, pos: usize) bool {
    if (pos == 0 or pos >= s.len) return true;

    const back = prevCp(s, pos);
    const a = back.cp;
    const b = cpAt(s, pos);
    const pa = prop(a);
    const pb = prop(b);

    if (pa == .cr and pb == .lf) return false; // GB3
    if (pa == .control or pa == .cr or pa == .lf) return true; // GB4
    if (pb == .control or pb == .cr or pb == .lf) return true; // GB5

    // GB6/7/8 -- Hangul syllable sequences.
    if (pa == .l and (pb == .l or pb == .v or pb == .lv or pb == .lvt)) return false;
    if ((pa == .lv or pa == .v) and (pb == .v or pb == .t)) return false;
    if ((pa == .lvt or pa == .t) and pb == .t) return false;

    if (pb == .extend or pb == .zwj) return false; // GB9
    if (pb == .spacing_mark) return false; // GB9a
    if (pa == .prepend) return false; // GB9b

    // GB9c -- Indic conjunct clusters.
    if (incb(b) == .consonant and linkedConsonantBefore(s, pos)) return false;

    // GB11 -- emoji ZWJ sequences.
    if (pa == .zwj and isPictographic(b) and pictographicBefore(s, back.start)) return false;

    // GB12/GB13 -- flags pair up from the start of the RI run.
    if (pa == .regional_indicator and pb == .regional_indicator) {
        if (regionalIndicatorRun(s, pos) % 2 == 1) return false;
    }

    return true; // GB999
}

/// Byte offset of the first cluster boundary strictly after `i`.
/// Returns `s.len` when `i` is already in the last cluster.
pub fn next(s: []const u8, i: usize) usize {
    if (i >= s.len) return s.len;
    var j = nextCp(s, i);
    while (j < s.len and !isBoundary(s, j)) j = nextCp(s, j);
    return j;
}

/// Byte offset of the last cluster boundary strictly before `i`.
/// Returns 0 when `i` is inside the first cluster.
pub fn prev(s: []const u8, i: usize) usize {
    if (i == 0) return 0;
    var j = prevCp(s, @min(i, s.len)).start;
    while (j > 0 and !isBoundary(s, j)) j = prevCp(s, j).start;
    return j;
}

pub const Cluster = struct { offset: usize, text: []const u8 };

pub const Iterator = struct {
    s: []const u8,
    i: usize = 0,

    pub fn nextCluster(self: *Iterator) ?Cluster {
        if (self.i >= self.s.len) return null;
        const start = self.i;
        self.i = next(self.s, start);
        return .{ .offset = start, .text = self.s[start..self.i] };
    }
};

pub fn iterate(s: []const u8) Iterator {
    return .{ .s = s };
}

/// Number of grapheme clusters in `s`.
pub fn count(s: []const u8) usize {
    var it = iterate(s);
    var n: usize = 0;
    while (it.nextCluster()) |_| n += 1;
    return n;
}

// -- tests -------------------------------------------------------------------

const testing = std.testing;

test "ascii is one cluster per byte" {
    try testing.expectEqual(@as(usize, 5), count("hello"));
    try testing.expectEqual(@as(usize, 1), next("hello", 0));
    try testing.expectEqual(@as(usize, 4), prev("hello", 5));
}

test "hangul syllables and jamo" {
    // Precomposed syllables are one cluster each.
    try testing.expectEqual(@as(usize, 5), count("안녕하세요"));
    // Conjoining L+V+T forms a single cluster (GB6/GB7).
    try testing.expectEqual(@as(usize, 1), count("\u{1100}\u{1161}\u{11A8}"));
}

test "emoji zwj sequence is one cluster" {
    // Family: man + ZWJ + woman + ZWJ + girl (GB11).
    try testing.expectEqual(@as(usize, 1), count("\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"));
}

test "regional indicator flags pair up" {
    // Two flags = two clusters, not four (GB12/GB13).
    try testing.expectEqual(@as(usize, 2), count("\u{1F1F0}\u{1F1F7}\u{1F1EF}\u{1F1F5}"));
    // An odd trailing RI stands alone.
    try testing.expectEqual(@as(usize, 2), count("\u{1F1F0}\u{1F1F7}\u{1F1EF}"));
}

test "variation selector attaches" {
    // The `⬛️` case from commands.test.ts: U+2B1B + U+FE0F is one cluster.
    try testing.expectEqual(@as(usize, 1), count("\u{2B1B}\u{FE0F}"));
}

test "crlf is one cluster" {
    try testing.expectEqual(@as(usize, 1), count("\r\n"));
    try testing.expectEqual(@as(usize, 3), count("a\r\nb"));
}

test "prev and next are inverses across clusters" {
    const s = "a안\u{1F468}\u{200D}\u{1F469}b\r\n";
    var offsets: [16]usize = undefined;
    var n: usize = 0;
    var it = iterate(s);
    while (it.nextCluster()) |c| {
        offsets[n] = c.offset;
        n += 1;
    }
    // Walking backwards from the end must visit exactly the same offsets.
    var i = s.len;
    var k = n;
    while (k > 0) {
        k -= 1;
        i = prev(s, i);
        try testing.expectEqual(offsets[k], i);
    }
    try testing.expectEqual(@as(usize, 0), i);
}

test "malformed utf8 does not stall" {
    const s = [_]u8{ 'a', 0xFF, 0xC3, 'b' };
    // Every step must make progress and terminate.
    var i: usize = 0;
    var guard: usize = 0;
    while (i < s.len and guard < 16) : (guard += 1) {
        const j = next(&s, i);
        try testing.expect(j > i);
        i = j;
    }
    try testing.expectEqual(@as(usize, 4), i);
}

// -- UAX #29 conformance -----------------------------------------------------

const conformance_data = @embedFile("testdata/GraphemeBreakTest.txt");

test "UAX #29 GraphemeBreakTest conformance" {
    var buf: [256]u8 = undefined;
    var expected: [64]usize = undefined;

    var lines = std.mem.splitScalar(u8, conformance_data, '\n');
    var cases: usize = 0;
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw[0 .. std.mem.indexOfScalar(u8, raw, '#') orelse raw.len], " \t\r");
        if (line.len == 0) continue;

        // Format: `÷ 0020 × 0308 ÷ 0020 ÷` -- U+00F7 marks a boundary,
        // U+00D7 marks "no boundary", hex fields are the code points.
        var len: usize = 0;
        var n_expected: usize = 0;
        var ok = true;

        var fields = std.mem.tokenizeAny(u8, line, " \t");
        while (fields.next()) |f| {
            if (std.mem.eql(u8, f, "\u{00F7}")) {
                expected[n_expected] = len;
                n_expected += 1;
            } else if (std.mem.eql(u8, f, "\u{00D7}")) {
                // no boundary here
            } else {
                const cp = std.fmt.parseInt(u21, f, 16) catch {
                    ok = false;
                    break;
                };
                const w = std.unicode.utf8Encode(cp, buf[len..]) catch {
                    ok = false;
                    break;
                };
                len += w;
            }
        }
        if (!ok) continue;

        const s = buf[0..len];
        var actual: [64]usize = undefined;
        var n_actual: usize = 0;
        var it = iterate(s);
        while (it.nextCluster()) |c| {
            actual[n_actual] = c.offset;
            n_actual += 1;
        }
        actual[n_actual] = len; // trailing boundary (GB2)
        n_actual += 1;

        testing.expectEqualSlices(usize, expected[0..n_expected], actual[0..n_actual]) catch |err| {
            std.debug.print("failing case: {s}\n", .{line});
            return err;
        };
        cases += 1;
    }

    // Guard against the parser silently skipping everything.
    try testing.expect(cases > 500);
}
