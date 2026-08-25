//! Hangul syllable -> compatibility jamo normalization.
//!
//! Ported from `src-tauri/src/jamo.rs`.
//!
//! Used by the FTS5 index so that a query like `안녕ㅎ` can match body text
//! `안녕하세요`: both sides collapse to a jamo stream (`ㅇㅏㄴㄴㅕㅇㅎㅏㅅㅔㅇㅛ`
//! vs `ㅇㅏㄴㄴㅕㅇㅎ`) and the FTS5 trigram tokenizer does the substring
//! matching.

const std = @import("std");

const CHO = [19]u21{
    'ㄱ', 'ㄲ', 'ㄴ', 'ㄷ', 'ㄸ', 'ㄹ', 'ㅁ', 'ㅂ', 'ㅃ', 'ㅅ',
    'ㅆ', 'ㅇ', 'ㅈ', 'ㅉ', 'ㅊ', 'ㅋ', 'ㅌ', 'ㅍ', 'ㅎ',
};

const JUNG = [21]u21{
    'ㅏ', 'ㅐ', 'ㅑ', 'ㅒ', 'ㅓ', 'ㅔ', 'ㅕ', 'ㅖ', 'ㅗ', 'ㅘ', 'ㅙ',
    'ㅚ', 'ㅛ', 'ㅜ', 'ㅝ', 'ㅞ', 'ㅟ', 'ㅠ', 'ㅡ', 'ㅢ', 'ㅣ',
};

/// Index 0 == "no final consonant" (encoded as 0). The remaining 27 map
/// precomposed final consonants to compatibility jamo.
const JONG = [28]u21{
    0,
    'ㄱ', 'ㄲ', 'ㄳ', 'ㄴ', 'ㄵ', 'ㄶ',
    'ㄷ', 'ㄹ', 'ㄺ', 'ㄻ', 'ㄼ', 'ㄽ',
    'ㄾ', 'ㄿ', 'ㅀ', 'ㅁ', 'ㅂ', 'ㅄ',
    'ㅅ', 'ㅆ', 'ㅇ', 'ㅈ', 'ㅊ', 'ㅋ',
    'ㅌ', 'ㅍ', 'ㅎ',
};

/// Matches Rust's `char::is_whitespace` (Unicode White_Space property).
fn isWhitespace(cp: u21) bool {
    return switch (cp) {
        0x09...0x0D, 0x20, 0x85, 0xA0, 0x1680,
        0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000 => true,
        else => false,
    };
}

/// Emit the jamo normalization of a single code point.
///
/// Returns the number of jamo code points appended, so `toJamoWithMap` can
/// extend its parallel index without re-scanning the output.
fn appendCodepoint(
    out: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    cp: u21,
    keep_whitespace: bool,
) !usize {
    if (cp >= 0xAC00 and cp <= 0xD7A3) {
        const idx = cp - 0xAC00;
        const cho = idx / 588;
        const jung = (idx % 588) / 28;
        const jong = idx % 28;
        try appendCp(out, gpa, CHO[cho]);
        try appendCp(out, gpa, JUNG[jung]);
        if (JONG[jong] != 0) {
            try appendCp(out, gpa, JONG[jong]);
            return 3;
        }
        return 2;
    }
    if (cp >= 0x1100 and cp <= 0x1112) {
        try appendCp(out, gpa, CHO[cp - 0x1100]);
        return 1;
    }
    if (cp >= 0x1161 and cp <= 0x1175) {
        try appendCp(out, gpa, JUNG[cp - 0x1161]);
        return 1;
    }
    if (cp >= 0x11A8 and cp <= 0x11C2) {
        const j = JONG[cp - 0x11A7];
        if (j != 0) {
            try appendCp(out, gpa, j);
            return 1;
        }
        return 0;
    }
    if (cp >= 0x3131 and cp <= 0x318E) {
        try appendCp(out, gpa, cp);
        return 1;
    }
    if (std.ascii.isAlphanumeric(@intCast(cp))) {
        try out.append(gpa, std.ascii.toLower(@intCast(cp)));
        return 1;
    }
    if (isWhitespace(cp)) {
        if (keep_whitespace) {
            try out.append(gpa, ' ');
            return 1;
        }
        return 0;
    }
    // Everything else (punctuation, symbols) is dropped -- FTS5 query syntax
    // safety and trigram noise reduction.
    return 0;
}

fn appendCp(out: *std.ArrayList(u8), gpa: std.mem.Allocator, cp: u21) !void {
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &buf) catch unreachable;
    try out.appendSlice(gpa, buf[0..n]);
}

/// Normalize `s` into a jamo stream suitable for FTS5 trigram indexing.
///
/// - Hangul syllables decompose into compatibility jamo (초+중+종).
/// - Conjoining jamo (U+1100 block) map to their compatibility counterparts.
/// - Compatibility jamo pass through as-is.
/// - ASCII letters are lowercased; digits pass through.
/// - Whitespace is kept when `keep_whitespace`; otherwise dropped.
/// - Everything else is dropped.
///
/// Caller owns the returned slice. Invalid UTF-8 bytes are skipped.
pub fn toJamo(gpa: std.mem.Allocator, s: []const u8, keep_whitespace: bool) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.ensureTotalCapacity(gpa, s.len * 2);

    var i: usize = 0;
    while (i < s.len) {
        const len = std.unicode.utf8ByteSequenceLength(s[i]) catch {
            i += 1;
            continue;
        };
        if (i + len > s.len) break;
        const cp = std.unicode.utf8Decode(s[i..][0..len]) catch {
            i += len;
            continue;
        };
        _ = try appendCodepoint(&out, gpa, cp, keep_whitespace);
        i += len;
    }
    return out.toOwnedSlice(gpa);
}

/// Returns `true` if the normalized query has enough jamo characters to
/// generate at least one trigram.
pub fn hasTrigram(normalized: []const u8) bool {
    return std.unicode.utf8CountCodepoints(normalized) catch 0 >= 3;
}

pub const JamoMap = struct {
    /// The normalized jamo stream.
    flat: []u8,
    /// One entry per jamo *code point* in `flat`, holding the **byte offset**
    /// into the source string that produced it.
    ///
    /// Note this diverges from the Rust original, which stored a source *char*
    /// index. Byte offsets are what every caller actually wants (they slice the
    /// original string), and they remove a char->byte conversion that was a
    /// standing source of off-by-one bugs in snippet extraction.
    map: []usize,

    pub fn deinit(self: JamoMap, gpa: std.mem.Allocator) void {
        gpa.free(self.flat);
        gpa.free(self.map);
    }
};

/// Same as `toJamo` but also returns a parallel mapping from each jamo code
/// point back to the source byte offset it came from. Lets callers find a match
/// position in jamo space and project it back to the original text for snippet
/// extraction.
pub fn toJamoWithMap(gpa: std.mem.Allocator, s: []const u8, keep_whitespace: bool) !JamoMap {
    var flat: std.ArrayList(u8) = .empty;
    errdefer flat.deinit(gpa);
    var map: std.ArrayList(usize) = .empty;
    errdefer map.deinit(gpa);

    var i: usize = 0;
    while (i < s.len) {
        const len = std.unicode.utf8ByteSequenceLength(s[i]) catch {
            i += 1;
            continue;
        };
        if (i + len > s.len) break;
        const cp = std.unicode.utf8Decode(s[i..][0..len]) catch {
            i += len;
            continue;
        };
        const emitted = try appendCodepoint(&flat, gpa, cp, keep_whitespace);
        try map.appendNTimes(gpa, i, emitted);
        i += len;
    }

    return .{
        .flat = try flat.toOwnedSlice(gpa),
        .map = try map.toOwnedSlice(gpa),
    };
}

// -- tests -------------------------------------------------------------------
// Ported 1:1 from the `mod tests` block in src-tauri/src/jamo.rs.

const testing = std.testing;

fn expectJamo(expected: []const u8, s: []const u8, keep_ws: bool) !void {
    const got = try toJamo(testing.allocator, s, keep_ws);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(expected, got);
}

test "decomposes syllables" {
    try expectJamo("ㅇㅏㄴㄴㅕㅇㅎㅏㅅㅔㅇㅛ", "안녕하세요", false);
}

test "trailing isolated cho matches prefix" {
    // User partially typed `안녕ㅎ` -- should stay as a jamo tail, which is a
    // *substring* of the decomposed body `안녕하세요` in jamo form.
    const body = try toJamo(testing.allocator, "안녕하세요", false);
    defer testing.allocator.free(body);
    const query = try toJamo(testing.allocator, "안녕ㅎ", false);
    defer testing.allocator.free(query);
    try testing.expect(std.mem.indexOf(u8, body, query) != null);
}

test "cross boundary substring matches tight but not loose" {
    const tight = try toJamo(testing.allocator, "안녕 하세요", false);
    defer testing.allocator.free(tight);
    const loose = try toJamo(testing.allocator, "안녕 하세요", true);
    defer testing.allocator.free(loose);
    const q = try toJamo(testing.allocator, "녕하세요", false);
    defer testing.allocator.free(q);
    try testing.expect(std.mem.indexOf(u8, tight, q) != null);
    try testing.expect(std.mem.indexOf(u8, loose, q) == null);
}

test "whitespace preservation" {
    try expectJamo("a b", "a b", true);
    try expectJamo("ab", "a b", false);
}

test "ascii lowercased" {
    try expectJamo("hello", "HELLO", false);
    try expectJamo("hello123", "Hello123", false);
}

test "punctuation stripped" {
    try expectJamo("hithere", "hi, there!", false);
}

test "compatibility jamo passthrough" {
    try expectJamo("ㅎㅏㅇ", "ㅎㅏㅇ", false);
}

test "has trigram threshold" {
    try testing.expect(!hasTrigram(""));
    try testing.expect(!hasTrigram("ㅇㅏ"));
    try testing.expect(hasTrigram("ㅇㅏㄴ"));
}

test "final consonant emitted" {
    // `안` has jong ㄴ; verify all three jamo appear.
    const got = try toJamo(testing.allocator, "안", false);
    defer testing.allocator.free(got);
    try testing.expectEqual(@as(usize, 3), try std.unicode.utf8CountCodepoints(got));
}

test "toJamoWithMap aligns source bytes" {
    const r = try toJamoWithMap(testing.allocator, "가b", false);
    defer r.deinit(testing.allocator);
    // 가 -> ㄱㅏ (2 jamo, both from byte 0; 가 is 3 bytes), b -> b (byte 3).
    try testing.expectEqualStrings("ㄱㅏb", r.flat);
    try testing.expectEqualSlices(usize, &.{ 0, 0, 3 }, r.map);
}

test "toJamoWithMap drops punct" {
    const r = try toJamoWithMap(testing.allocator, "a!b", false);
    defer r.deinit(testing.allocator);
    try testing.expectEqualStrings("ab", r.flat);
    try testing.expectEqualSlices(usize, &.{ 0, 2 }, r.map);
}
