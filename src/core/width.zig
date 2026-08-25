//! Monospace cell width classification.
//!
//! The TypeScript original carried three separate hand-written copies of a CJK
//! range list (`wrap.ts:114`, `wrap.ts:133`, `Editor.svelte:680`) that had
//! drifted apart and omitted CJK Extension B. They are unified here against the
//! real East_Asian_Width property.

const std = @import("std");
const table = @import("width_table.zig");
const grapheme = @import("grapheme.zig");

/// Variation Selector-16: requests emoji (wide) presentation.
const vs16: u21 = 0xFE0F;

/// True when `cp` occupies two monospace cells (East_Asian_Width W or F).
pub fn isWide(cp: u21) bool {
    var lo: usize = 0;
    var hi: usize = table.wide_ranges.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const r = table.wide_ranges[mid];
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

/// True when a grapheme cluster occupies two cells.
///
/// The base (first) code point decides, except that an explicit emoji
/// presentation selector anywhere in the cluster forces the wide form -- that is
/// what makes `⬛️` (U+2B1B U+FE0F) and keycap sequences line up in a grid.
///
/// The TS version approximated this as "more than one UTF-16 unit", which
/// misclassified every combining-mark cluster as wide.
pub fn clusterIsWide(cluster: []const u8) bool {
    if (cluster.len == 0) return false;

    // Decoded defensively: `grapheme.iterate` deliberately tolerates malformed
    // UTF-8 so a corrupt file cannot wedge the editor, which means every
    // consumer of its clusters has to tolerate it too. `std.unicode.Utf8Iterator`
    // asserts validity and would panic here.
    var i: usize = 0;
    var first = true;
    while (i < cluster.len) {
        const len = std.unicode.utf8ByteSequenceLength(cluster[i]) catch {
            i += 1;
            first = false;
            continue;
        };
        if (i + len > cluster.len) break;
        const cp = std.unicode.utf8Decode(cluster[i..][0..len]) catch {
            i += len;
            first = false;
            continue;
        };
        if (first and isWide(cp)) return true;
        if (cp == vs16) return true;
        first = false;
        i += len;
    }
    return false;
}

/// True when a cluster is a legal character-level break opportunity because it
/// is CJK-like. Used by soft wrap as the fallback tier when a row holds no
/// whitespace at all -- long Chinese/Japanese runs have no spaces to break at.
pub fn clusterIsCjkLike(cluster: []const u8) bool {
    return clusterIsWide(cluster);
}

const testing = std.testing;

test "hangul and cjk are wide" {
    try testing.expect(isWide('안'));
    try testing.expect(isWide('中'));
    try testing.expect(isWide('あ'));
    try testing.expect(isWide(0xFF01)); // fullwidth !
}

test "latin is narrow" {
    try testing.expect(!isWide('a'));
    try testing.expect(!isWide('Z'));
    try testing.expect(!isWide('0'));
}

test "cjk extension B is wide -- the old hand-written table missed it" {
    try testing.expect(isWide(0x20000));
}

test "emoji presentation selector forces wide" {
    try testing.expect(clusterIsWide("\u{2B1B}\u{FE0F}"));
    try testing.expect(clusterIsWide("\u{1F468}"));
}

test "malformed UTF-8 does not panic" {
    try testing.expect(!clusterIsWide(&[_]u8{0xFF}));
    try testing.expect(!clusterIsWide(&[_]u8{ 0xC3, 0x28 }));
    try testing.expect(!clusterIsWide(&[_]u8{0xE0}));
}

test "combining marks do not make a cluster wide" {
    // "e" + U+0301 combining acute -- two code points, still one narrow cell.
    try testing.expect(!clusterIsWide("e\u{0301}"));
}
