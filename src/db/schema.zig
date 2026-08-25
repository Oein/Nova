//! Workspace database schema and migrations.
//!
//! Ported verbatim from `SCHEMA` in `src-tauri/src/workspace.rs:305`. Keeping
//! the SQL identical is what lets the Zig build open a workspace created by the
//! Tauri build.
//!
//! The `notion_*` tables are created here even though Notion sync itself lands
//! in a later stage -- an existing `workspace.db` already has them, and creating
//! them up front keeps one schema definition rather than two.

const std = @import("std");
const sqlite = @import("sqlite.zig");

pub const sql =
    \\CREATE TABLE IF NOT EXISTS notes (
    \\    id TEXT PRIMARY KEY,
    \\    title TEXT NOT NULL,
    \\    created_ms INTEGER NOT NULL,
    \\    mtime_ms INTEGER NOT NULL,
    \\    size INTEGER NOT NULL
    \\);
    \\
    \\CREATE TABLE IF NOT EXISTS session_meta (
    \\    key TEXT PRIMARY KEY,
    \\    value TEXT
    \\);
    \\
    \\CREATE TABLE IF NOT EXISTS session_tabs (
    \\    note_id TEXT PRIMARY KEY,
    \\    position INTEGER NOT NULL,
    \\    cursor_line INTEGER NOT NULL DEFAULT 0,
    \\    cursor_col INTEGER NOT NULL DEFAULT 0,
    \\    scroll_top INTEGER NOT NULL DEFAULT 0,
    \\    unsaved_content TEXT,
    \\    undo_log TEXT
    \\);
    \\
    \\-- Jamo-normalized full-text index. Three indexed columns give BM25 a
    \\-- signal to rank matches: title hits rank highest, body_loose (spaces
    \\-- preserved) marks within-word matches, body_tight (spaces stripped)
    \\-- catches cross-boundary substrings at a lower weight.
    \\CREATE VIRTUAL TABLE IF NOT EXISTS notes_fts USING fts5(
    \\    id UNINDEXED,
    \\    title_jamo,
    \\    body_jamo_tight,
    \\    body_jamo_loose,
    \\    tokenize='trigram'
    \\);
    \\
    \\CREATE TABLE IF NOT EXISTS notion_config (
    \\    id             INTEGER PRIMARY KEY CHECK (id = 1),
    \\    token          TEXT,
    \\    database_id    TEXT,
    \\    database_title TEXT,
    \\    title_prop     TEXT NOT NULL DEFAULT 'Name',
    \\    created_prop   TEXT,
    \\    updated_prop   TEXT,
    \\    id_prop        TEXT,
    \\    enabled        INTEGER NOT NULL DEFAULT 0,
    \\    sync_on_start  INTEGER NOT NULL DEFAULT 1,
    \\    auto_sync      INTEGER NOT NULL DEFAULT 1,
    \\    interval_sec   INTEGER NOT NULL DEFAULT 900,
    \\    last_sync_ms   INTEGER,
    \\    last_status    TEXT
    \\);
    \\
    \\CREATE TABLE IF NOT EXISTS notion_links (
    \\    note_id             TEXT PRIMARY KEY,
    \\    page_id             TEXT UNIQUE,
    \\    base_local_hash     TEXT NOT NULL DEFAULT '',
    \\    base_local_mtime_ms INTEGER NOT NULL DEFAULT 0,
    \\    base_remote_hash    TEXT NOT NULL DEFAULT '',
    \\    base_remote_edited  TEXT NOT NULL DEFAULT '',
    \\    last_synced_ms      INTEGER NOT NULL DEFAULT 0,
    \\    push_mode           TEXT NOT NULL DEFAULT 'rebuild',
    \\    state               TEXT NOT NULL DEFAULT 'ok',
    \\    last_error          TEXT
    \\);
    \\CREATE INDEX IF NOT EXISTS idx_notion_links_page ON notion_links(page_id);
    \\
    \\CREATE TABLE IF NOT EXISTS notion_blocks (
    \\    note_id     TEXT NOT NULL,
    \\    block_id    TEXT NOT NULL,
    \\    ord         INTEGER NOT NULL,
    \\    block_type  TEXT NOT NULL,
    \\    raw_json    TEXT NOT NULL,
    \\    recreatable INTEGER NOT NULL DEFAULT 1,
    \\    PRIMARY KEY (note_id, block_id)
    \\);
    \\
    \\CREATE TABLE IF NOT EXISTS notion_conflicts (
    \\    note_id        TEXT PRIMARY KEY,
    \\    page_id        TEXT,
    \\    kind           TEXT NOT NULL,
    \\    local_content  TEXT,
    \\    remote_content TEXT,
    \\    local_title    TEXT,
    \\    remote_title   TEXT,
    \\    detected_ms    INTEGER NOT NULL
    \\);
;

/// Schema version stamped into `PRAGMA user_version`.
///
///   0 -- anything written by the Tauri build (it never set the pragma)
///   1 -- `session_tabs.cursor_col` holds a **byte** offset
///
/// The Zig editor addresses columns by byte offset; the TypeScript editor used
/// UTF-16 code units. A stored cursor from the old build therefore points into
/// the wrong place on any line containing non-ASCII text.
pub const current_version: i64 = 1;

/// SQLite has no `ADD COLUMN IF NOT EXISTS`; the pragma check is the idiom.
fn addColumnIfMissing(
    db: *sqlite.Db,
    table: []const u8,
    column: []const u8,
    decl: []const u8,
) !void {
    const present = try db.queryInt(
        "SELECT COUNT(*) FROM pragma_table_info(?1) WHERE name = ?2",
        .{ table, column },
    ) orelse 0;
    if (present != 0) return;

    var buf: [256]u8 = undefined;
    const stmt = std.fmt.bufPrintZ(
        &buf,
        "ALTER TABLE {s} ADD COLUMN {s} {s}",
        .{ table, column, decl },
    ) catch return error.SqliteError;
    try db.exec(stmt);
}

/// Create the schema and bring an older database up to date.
pub fn migrate(db: *sqlite.Db) !void {
    try db.exec(sql);

    // Columns added to tables that already shipped.
    try addColumnIfMissing(db, "notes", "deleted_at_ms", "INTEGER");
    try addColumnIfMissing(db, "notes", "filename", "TEXT");
    for ([_][]const u8{ "created_prop", "updated_prop", "id_prop" }) |col| {
        try addColumnIfMissing(db, "notion_config", col, "TEXT");
    }

    const version = try db.queryInt("PRAGMA user_version", .{}) orelse 0;
    if (version < 1) try migrateCursorColsToBytes(db);

    var buf: [64]u8 = undefined;
    const stmt = std.fmt.bufPrintZ(&buf, "PRAGMA user_version = {d}", .{current_version}) catch
        return error.SqliteError;
    try db.exec(stmt);
}

/// v0 -> v1: reinterpret `session_tabs.cursor_col`.
///
/// The honest conversion needs each tab's line text, which lives in
/// `unsaved_content` for a dirty tab and on disk otherwise -- and the note file
/// may since have changed. Rather than half-restore a cursor to the wrong place
/// inside a word, this clamps every stored column to 0 and keeps the line.
/// Reopening a workspace lands the caret at the start of the line it was on,
/// which is a small, obviously-correct loss compared to a caret that silently
/// splits a Hangul syllable.
fn migrateCursorColsToBytes(db: *sqlite.Db) !void {
    try db.exec("UPDATE session_tabs SET cursor_col = 0 WHERE cursor_col != 0");
}

// -- tests -------------------------------------------------------------------

const testing = std.testing;

test "schema creates every table" {
    var db = try sqlite.Db.openMemory();
    defer db.close();
    try migrate(&db);

    for ([_][]const u8{
        "notes",         "session_meta",  "session_tabs", "notes_fts",
        "notion_config", "notion_links",  "notion_blocks", "notion_conflicts",
    }) |name| {
        const n = try db.queryInt(
            "SELECT COUNT(*) FROM sqlite_master WHERE name = ?1",
            .{name},
        );
        testing.expectEqual(@as(?i64, 1), n) catch |err| {
            std.debug.print("missing table: {s}\n", .{name});
            return err;
        };
    }
}

test "migrate is idempotent" {
    var db = try sqlite.Db.openMemory();
    defer db.close();
    try migrate(&db);
    try migrate(&db);
    try testing.expectEqual(
        @as(?i64, current_version),
        try db.queryInt("PRAGMA user_version", .{}),
    );
}

test "migrating an old database adds the late columns" {
    var db = try sqlite.Db.openMemory();
    defer db.close();

    // The original shipped schema, before the trash and filename columns.
    try db.exec(
        \\CREATE TABLE notes (
        \\    id TEXT PRIMARY KEY, title TEXT NOT NULL,
        \\    created_ms INTEGER NOT NULL, mtime_ms INTEGER NOT NULL,
        \\    size INTEGER NOT NULL
        \\);
    );
    try db.run(
        "INSERT INTO notes VALUES (?1, ?2, 0, 0, 0)",
        .{ "n1", "Old note" },
    );

    try migrate(&db);

    for ([_][]const u8{ "deleted_at_ms", "filename" }) |col| {
        const present = try db.queryInt(
            "SELECT COUNT(*) FROM pragma_table_info('notes') WHERE name = ?1",
            .{col},
        );
        try testing.expectEqual(@as(?i64, 1), present);
    }
    // The existing row survives.
    try testing.expectEqual(@as(?i64, 1), try db.queryInt("SELECT COUNT(*) FROM notes", .{}));
}

test "v0 cursor columns are reset rather than misinterpreted" {
    var db = try sqlite.Db.openMemory();
    defer db.close();
    try db.exec(sql);
    // A tab saved by the TypeScript build: cursor_col is a UTF-16 offset.
    try db.run(
        "INSERT INTO session_tabs (note_id, position, cursor_line, cursor_col) VALUES (?1, 0, 3, 7)",
        .{"n1"},
    );
    try migrate(&db);

    try testing.expectEqual(
        @as(?i64, 0),
        try db.queryInt("SELECT cursor_col FROM session_tabs", .{}),
    );
    // The line is preserved -- only the column is untrustworthy.
    try testing.expectEqual(
        @as(?i64, 3),
        try db.queryInt("SELECT cursor_line FROM session_tabs", .{}),
    );
}

test "already-migrated databases keep their cursor columns" {
    var db = try sqlite.Db.openMemory();
    defer db.close();
    try migrate(&db);
    try db.run(
        "INSERT INTO session_tabs (note_id, position, cursor_line, cursor_col) VALUES (?1, 0, 1, 5)",
        .{"n1"},
    );
    try migrate(&db);
    try testing.expectEqual(
        @as(?i64, 5),
        try db.queryInt("SELECT cursor_col FROM session_tabs", .{}),
    );
}
