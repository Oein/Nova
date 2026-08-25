//! Note search: jamo-normalized trigram matching, plus snippet extraction.
//!
//! Ported from the search half of `src-tauri/src/workspace.rs` (:691-857).
//!
//! Offsets are byte offsets throughout. The Rust original projected matches
//! back into *character* space and re-collected the body into a `Vec<char>` to
//! slice it; the jamo map here records source byte offsets directly, which
//! removes that conversion (and the class of off-by-one it invited).

const std = @import("std");
const core = @import("core");
const sqlite = @import("sqlite.zig");
const ws_mod = @import("workspace.zig");

const Allocator = std.mem.Allocator;
const Workspace = ws_mod.Workspace;

/// Context shown either side of a match, in code points.
pub const snippet_context_chars: usize = 30;

/// Below this many jamo, a query is not worth running.
const min_query_jamo: usize = 2;

pub const SnippetParts = struct {
    before: []const u8,
    matched: []const u8,
    after: []const u8,
    prefix_ellipsis: bool,
    suffix_ellipsis: bool,

    pub fn deinit(self: SnippetParts, gpa: Allocator) void {
        gpa.free(self.before);
        gpa.free(self.matched);
        gpa.free(self.after);
    }
};

pub const SearchHit = struct {
    id: []const u8,
    title: []const u8,
    mtime_ms: i64,
    score: f64,
    snippet: ?SnippetParts,

    pub fn deinit(self: SearchHit, gpa: Allocator) void {
        gpa.free(self.id);
        gpa.free(self.title);
        if (self.snippet) |s| s.deinit(gpa);
    }
};

pub fn freeHits(gpa: Allocator, hits: []SearchHit) void {
    for (hits) |h| h.deinit(gpa);
    gpa.free(hits);
}

// -- snippets ----------------------------------------------------------------

/// Replace newlines and tabs with spaces so a snippet stays on one line.
fn cleanInline(gpa: Allocator, s: []const u8) ![]u8 {
    const out = try gpa.dupe(u8, s);
    for (out) |*ch| {
        if (ch.* == '\n' or ch.* == '\r' or ch.* == '\t') ch.* = ' ';
    }
    return out;
}

fn charLenAt(s: []const u8, i: usize) usize {
    if (i >= s.len) return 0;
    const l = std.unicode.utf8ByteSequenceLength(s[i]) catch return 1;
    return if (i + l > s.len) 1 else l;
}

/// Step `n` code points back from byte offset `i`.
fn backChars(s: []const u8, i: usize, n: usize) usize {
    var j = i;
    var k: usize = 0;
    while (j > 0 and k < n) : (k += 1) {
        j -= 1;
        while (j > 0 and s[j] & 0xC0 == 0x80) j -= 1;
    }
    return j;
}

/// Step `n` code points forward from byte offset `i`.
fn forwardChars(s: []const u8, i: usize, n: usize) usize {
    var j = i;
    var k: usize = 0;
    while (j < s.len and k < n) : (k += 1) j += charLenAt(s, j);
    return j;
}

pub const Range = struct { start: usize, end: usize };

/// First byte range of `content` whose jamo form contains the query's.
///
/// Loose (spaces kept) is tried before tight (spaces stripped), matching the
/// original -- a within-word hit is a better snippet anchor than one that
/// spans a space.
pub fn findMatchRange(gpa: Allocator, content: []const u8, query_raw: []const u8) !?Range {
    const q_loose = try core.jamo.toJamo(gpa, query_raw, true);
    defer gpa.free(q_loose);
    const q_tight = try core.jamo.toJamo(gpa, query_raw, false);
    defer gpa.free(q_tight);
    if (q_tight.len == 0) return null;

    const loose = try core.jamo.toJamoWithMap(gpa, content, true);
    defer loose.deinit(gpa);
    const tight = try core.jamo.toJamoWithMap(gpa, content, false);
    defer tight.deinit(gpa);

    const attempts = [_]struct { flat: []const u8, map: []const usize, q: []const u8 }{
        .{ .flat = loose.flat, .map = loose.map, .q = q_loose },
        .{ .flat = tight.flat, .map = tight.map, .q = q_tight },
    };

    for (attempts) |a| {
        if (a.q.len == 0) continue;
        const byte_pos = std.mem.indexOf(u8, a.flat, a.q) orelse continue;
        const jamo_idx = std.unicode.utf8CountCodepoints(a.flat[0..byte_pos]) catch continue;
        const q_len = std.unicode.utf8CountCodepoints(a.q) catch continue;
        if (q_len == 0) continue;
        const end_idx = jamo_idx + q_len;
        if (end_idx == 0 or end_idx > a.map.len) continue;

        const start_src = a.map[jamo_idx];
        const last_src = a.map[end_idx - 1];
        return .{ .start = start_src, .end = last_src + charLenAt(content, last_src) };
    }
    return null;
}

/// Snippet around the first body match, or null when the body does not match
/// (a title-only hit).
pub fn buildSnippet(gpa: Allocator, content: []const u8, query_raw: []const u8) !?SnippetParts {
    const range = (try findMatchRange(gpa, content, query_raw)) orelse return null;

    const ctx_start = backChars(content, range.start, snippet_context_chars);
    const ctx_end = forwardChars(content, range.end, snippet_context_chars);

    const before = try cleanInline(gpa, content[ctx_start..range.start]);
    errdefer gpa.free(before);
    const matched = try cleanInline(gpa, content[range.start..range.end]);
    errdefer gpa.free(matched);
    const after = try cleanInline(gpa, content[range.end..ctx_end]);

    return .{
        .before = before,
        .matched = matched,
        .after = after,
        .prefix_ellipsis = ctx_start > 0,
        .suffix_ellipsis = ctx_end < content.len,
    };
}

// -- search ------------------------------------------------------------------

/// Search notes by jamo-normalized trigram match.
///
/// Queries normalizing to fewer than two jamo return nothing. Three or more go
/// through FTS5; exactly two fall back to a LIKE scan, since the trigram
/// tokenizer cannot index them.
pub fn searchNotes(
    ws: *Workspace,
    gpa: Allocator,
    query_raw: []const u8,
    limit: i64,
) ![]SearchHit {
    const jamo_q = try core.jamo.toJamo(gpa, query_raw, false);
    defer gpa.free(jamo_q);

    const jamo_len = std.unicode.utf8CountCodepoints(jamo_q) catch 0;
    if (jamo_len < min_query_jamo) return gpa.alloc(SearchHit, 0);

    const hits = if (core.jamo.hasTrigram(jamo_q))
        try searchFts(ws, gpa, jamo_q, limit)
    else
        try searchLike(ws, gpa, jamo_q, limit);
    errdefer freeHits(gpa, hits);

    for (hits) |*hit| {
        const path = ws.notePath(hit.id);
        const content = try ws.fs.readOrEmpty(gpa, path.slice());
        defer gpa.free(content);
        hit.snippet = try buildSnippet(gpa, content, query_raw);
    }
    return hits;
}

fn collectHits(gpa: Allocator, st: *sqlite.Stmt) ![]SearchHit {
    var out: std.ArrayList(SearchHit) = .empty;
    errdefer {
        for (out.items) |h| h.deinit(gpa);
        out.deinit(gpa);
    }
    while (try st.step()) {
        try out.append(gpa, .{
            .id = try st.textDupeOrEmpty(gpa, 0),
            .title = try st.textDupeOrEmpty(gpa, 1),
            .mtime_ms = st.int(2),
            .score = st.float(3),
            .snippet = null,
        });
    }
    return out.toOwnedSlice(gpa);
}

fn searchFts(ws: *Workspace, gpa: Allocator, jamo_q: []const u8, limit: i64) ![]SearchHit {
    // Quoting the query as an FTS5 phrase makes the trigram tokenizer require
    // an ordered sequence. That is what lets a query spanning a space fail on
    // body_jamo_loose while still matching body_jamo_tight.
    const match_expr = try std.fmt.allocPrint(gpa, "\"{s}\"", .{jamo_q});
    defer gpa.free(match_expr);

    // Two-tier ordering. BM25 column weights alone do not guarantee that a
    // title hit outranks a body hit -- title columns are short, and BM25's
    // length normalization can flip them -- so `title_rank` decides first.
    var st = try ws.db.prepare(
        "SELECT notes.id, notes.title, notes.mtime_ms, " ++
            "bm25(notes_fts, 5.0, 1.0, 2.5) AS score, " ++
            "CASE WHEN instr(notes_fts.title_jamo, ?1) > 0 THEN 0 ELSE 1 END AS title_rank " ++
            "FROM notes_fts JOIN notes ON notes.id = notes_fts.id " ++
            "WHERE notes_fts MATCH ?2 AND notes.deleted_at_ms IS NULL " ++
            "ORDER BY title_rank, score LIMIT ?3",
    );
    defer st.deinit();
    try st.bindAll(.{ jamo_q, match_expr, limit });
    return collectHits(gpa, &st);
}

fn searchLike(ws: *Workspace, gpa: Allocator, jamo_q: []const u8, limit: i64) ![]SearchHit {
    // Not indexed, but two-jamo queries are rare and the note counts are small.
    // No BM25 here, so score is 0 and ordering falls back to mtime.
    var escaped: std.ArrayList(u8) = .empty;
    defer escaped.deinit(gpa);
    try escaped.append(gpa, '%');
    for (jamo_q) |ch| {
        if (ch == '\\' or ch == '%' or ch == '_') try escaped.append(gpa, '\\');
        try escaped.append(gpa, ch);
    }
    try escaped.append(gpa, '%');

    var st = try ws.db.prepare(
        "SELECT notes.id, notes.title, notes.mtime_ms, 0.0 AS score, " ++
            "CASE WHEN instr(notes_fts.title_jamo, ?1) > 0 THEN 0 ELSE 1 END AS title_rank " ++
            "FROM notes_fts JOIN notes ON notes.id = notes_fts.id " ++
            "WHERE (notes_fts.title_jamo LIKE ?2 ESCAPE '\\' " ++
            "   OR notes_fts.body_jamo_tight LIKE ?2 ESCAPE '\\' " ++
            "   OR notes_fts.body_jamo_loose LIKE ?2 ESCAPE '\\') " ++
            "  AND notes.deleted_at_ms IS NULL " ++
            "ORDER BY title_rank, notes.mtime_ms DESC LIMIT ?3",
    );
    defer st.deinit();
    try st.bindAll(.{ jamo_q, escaped.items, limit });
    return collectHits(gpa, &st);
}

// -- tests -------------------------------------------------------------------
// Ported from the search tests in src-tauri/src/workspace.rs.

const testing = std.testing;
const TestWorkspace = ws_mod.TestWorkspace;

test "buildSnippet locates the match in the original text" {
    const content = "앞부분 텍스트 안녕하세요 반갑습니다 뒷부분 텍스트";
    const snip = (try buildSnippet(testing.allocator, content, "안녕ㅎ")).?;
    defer snip.deinit(testing.allocator);
    try testing.expectEqualStrings("안녕하", snip.matched);
    try testing.expect(std.mem.startsWith(u8, snip.after, "세요"));
}

test "buildSnippet returns null when the body does not match" {
    try testing.expect((try buildSnippet(testing.allocator, "totally different", "안녕")) == null);
}

test "buildSnippet collapses newlines to spaces" {
    const snip = (try buildSnippet(testing.allocator, "line1\n안녕하세요\nline3", "안녕")).?;
    defer snip.deinit(testing.allocator);
    try testing.expect(std.mem.indexOfScalar(u8, snip.before, '\n') == null);
    try testing.expect(std.mem.indexOfScalar(u8, snip.after, '\n') == null);
}

test "search matches a partial jamo query" {
    var t = try TestWorkspace.init(testing.allocator, "search-partial");
    defer t.deinit();
    try t.seedNote("a", "greetings", "안녕하세요 반갑습니다", 10);
    try t.seedNote("b", "other", "완전 다른 내용", 20);

    // `안녕ㅎ` -- a half-typed final consonant still matches `안녕하세요`.
    const hits = try searchNotes(&t.ws, testing.allocator, "안녕ㅎ", 10);
    defer freeHits(testing.allocator, hits);

    try testing.expect(containsId(hits, "a"));
    try testing.expect(!containsId(hits, "b"));
}

test "search finds a match spanning a space via the tight column" {
    var t = try TestWorkspace.init(testing.allocator, "search-tight");
    defer t.deinit();
    try t.seedNote("b", "note b", "안녕 하세요", 20);

    const hits = try searchNotes(&t.ws, testing.allocator, "녕하세요", 10);
    defer freeHits(testing.allocator, hits);
    try testing.expect(containsId(hits, "b"));
}

test "search finds within-word matches in both notes" {
    var t = try TestWorkspace.init(testing.allocator, "search-both");
    defer t.deinit();
    try t.seedNote("a", "note a", "하세요연습", 10);
    try t.seedNote("b", "note b", "안녕 하세요", 20);

    const hits = try searchNotes(&t.ws, testing.allocator, "하세요", 10);
    defer freeHits(testing.allocator, hits);
    try testing.expect(containsId(hits, "a"));
    try testing.expect(containsId(hits, "b"));
}

test "search excludes trashed notes" {
    var t = try TestWorkspace.init(testing.allocator, "search-trash");
    defer t.deinit();
    try t.seedNote("a", "t", "안녕하세요", 10);
    try t.ws.trashNote("a", 1000);

    const hits = try searchNotes(&t.ws, testing.allocator, "안녕하세요", 10);
    defer freeHits(testing.allocator, hits);
    try testing.expectEqual(@as(usize, 0), hits.len);
}

test "a title match ranks above a body match" {
    var t = try TestWorkspace.init(testing.allocator, "search-rank");
    defer t.deinit();
    try t.seedNote("a", "안녕하세요", "other body", 10);
    try t.seedNote("b", "other title", "안녕하세요 body", 20);

    const hits = try searchNotes(&t.ws, testing.allocator, "안녕하세요", 10);
    defer freeHits(testing.allocator, hits);
    try testing.expect(hits.len >= 1);
    try testing.expectEqualStrings("a", hits[0].id);
}

test "search attaches a snippet to each hit" {
    var t = try TestWorkspace.init(testing.allocator, "search-snippet");
    defer t.deinit();
    try t.seedNote("a", "other title", "안녕하세요 반갑습니다", 10);

    const hits = try searchNotes(&t.ws, testing.allocator, "안녕하", 10);
    defer freeHits(testing.allocator, hits);
    try testing.expectEqual(@as(usize, 1), hits.len);
    try testing.expectEqualStrings("안녕하", hits[0].snippet.?.matched);
}

test "search ignores one-character queries" {
    var t = try TestWorkspace.init(testing.allocator, "search-short");
    defer t.deinit();
    try t.seedNote("a", "t", "안녕", 10);

    const hits = try searchNotes(&t.ws, testing.allocator, "a", 10);
    defer freeHits(testing.allocator, hits);
    try testing.expectEqual(@as(usize, 0), hits.len);
}

test "a two-jamo query falls back to LIKE" {
    var t = try TestWorkspace.init(testing.allocator, "search-like");
    defer t.deinit();
    try t.seedNote("a", "t", "안녕하세요", 10);

    // `아` normalizes to `ㅇㅏ`, below the trigram floor, but the LIKE scan
    // still finds it inside the decomposed body.
    const hits = try searchNotes(&t.ws, testing.allocator, "아", 10);
    defer freeHits(testing.allocator, hits);
    try testing.expectEqual(@as(usize, 1), hits.len);
    try testing.expectEqualStrings("a", hits[0].id);
}

test "a LIKE query containing wildcards is escaped" {
    var t = try TestWorkspace.init(testing.allocator, "search-escape");
    defer t.deinit();
    try t.seedNote("a", "t", "안녕하세요", 10);

    // `%_` normalizes to nothing (punctuation is dropped), so this must return
    // no hits rather than matching everything through an unescaped wildcard.
    const hits = try searchNotes(&t.ws, testing.allocator, "%_", 10);
    defer freeHits(testing.allocator, hits);
    try testing.expectEqual(@as(usize, 0), hits.len);
}

fn containsId(hits: []const SearchHit, id: []const u8) bool {
    for (hits) |h| {
        if (std.mem.eql(u8, h.id, id)) return true;
    }
    return false;
}
