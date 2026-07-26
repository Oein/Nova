use std::path::{Path, PathBuf};

use rusqlite::{params, Connection};

use crate::error::{AppError, AppResult};
use crate::jamo;

pub struct Workspace {
    pub root: PathBuf,
    pub conn: Connection,
}

fn map_sql_err(e: rusqlite::Error) -> AppError {
    AppError::Other(format!("sqlite: {}", e))
}

impl Workspace {
    pub fn open(root: &Path) -> AppResult<Self> {
        std::fs::create_dir_all(root)?;
        std::fs::create_dir_all(root.join("notes"))?;
        std::fs::create_dir_all(root.join("trash"))?;
        let db_path = root.join("workspace.db");
        let conn = Connection::open(&db_path).map_err(map_sql_err)?;
        conn.execute_batch(SCHEMA).map_err(map_sql_err)?;
        // Migration: add deleted_at_ms column for soft-delete / trash retention.
        let has_trash_col: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM pragma_table_info('notes') WHERE name = 'deleted_at_ms'",
                [],
                |row| row.get(0),
            )
            .unwrap_or(0);
        if has_trash_col == 0 {
            conn.execute("ALTER TABLE notes ADD COLUMN deleted_at_ms INTEGER", [])
                .map_err(map_sql_err)?;
        }
        // Migration: add filename column for readable on-disk names.
        // Pre-migration notes live at `notes/{uuid}.md`; post-migration they
        // live at `notes/{slug}-{short-id}.md`.
        let has_filename_col: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM pragma_table_info('notes') WHERE name = 'filename'",
                [],
                |row| row.get(0),
            )
            .unwrap_or(0);
        if has_filename_col == 0 {
            conn.execute("ALTER TABLE notes ADD COLUMN filename TEXT", [])
                .map_err(map_sql_err)?;
        }
        // Migration: timestamp property names, added after notion_config
        // shipped. `CREATE TABLE IF NOT EXISTS` won't touch an existing table.
        for col in ["created_prop", "updated_prop", "id_prop"] {
            add_column_if_missing(&conn, "notion_config", col, "TEXT")?;
        }
        let ws = Self {
            root: root.to_path_buf(),
            conn,
        };
        ws.backfill_fts_if_empty()?;
        ws.backfill_filenames()?;
        Ok(ws)
    }

    /// First-open migration for existing workspaces that predate the FTS
    /// index. Reads each note's file from disk and populates `notes_fts`.
    fn backfill_fts_if_empty(&self) -> AppResult<()> {
        let fts_count: i64 = self
            .conn
            .query_row("SELECT COUNT(*) FROM notes_fts", [], |row| row.get(0))
            .unwrap_or(0);
        let notes_count: i64 = self
            .conn
            .query_row("SELECT COUNT(*) FROM notes", [], |row| row.get(0))
            .unwrap_or(0);
        if notes_count == 0 || fts_count >= notes_count {
            return Ok(());
        }
        let mut stmt = self
            .conn
            .prepare("SELECT id, title FROM notes")
            .map_err(map_sql_err)?;
        let rows = stmt
            .query_map([], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
            })
            .map_err(map_sql_err)?;
        let mut entries = Vec::new();
        for r in rows {
            entries.push(r.map_err(map_sql_err)?);
        }
        drop(stmt);
        for (id, title) in entries {
            let body = std::fs::read_to_string(self.note_path(&id)).unwrap_or_default();
            fts_upsert(&self.conn, &id, &title, &body)?;
        }
        Ok(())
    }

    /// On-disk path for the note's current location. Resolves to `trash/` when
    /// the note is soft-deleted, otherwise `notes/`. Callers that read/write a
    /// note's content don't need to care which folder it's in.
    pub fn note_path(&self, id: &str) -> PathBuf {
        let row: Option<(Option<String>, Option<i64>)> = self
            .conn
            .query_row(
                "SELECT filename, deleted_at_ms FROM notes WHERE id = ?1",
                params![id],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .ok();
        let (filename, deleted_at) = row.unwrap_or((None, None));
        let name = filename.unwrap_or_else(|| format!("{}.md", id));
        let dir = if deleted_at.is_some() { "trash" } else { "notes" };
        self.root.join(dir).join(name)
    }

    /// Explicit path under `notes/` for a given id, regardless of trash state.
    /// Used by trash/restore to compute source and destination paths.
    fn active_path(&self, id: &str) -> PathBuf {
        let filename: Option<String> = self
            .conn
            .query_row(
                "SELECT filename FROM notes WHERE id = ?1",
                params![id],
                |row| row.get(0),
            )
            .ok()
            .flatten();
        let name = filename.unwrap_or_else(|| format!("{}.md", id));
        self.root.join("notes").join(name)
    }

    /// Explicit path under `trash/` for a given id, regardless of trash state.
    fn trash_path(&self, id: &str) -> PathBuf {
        let filename: Option<String> = self
            .conn
            .query_row(
                "SELECT filename FROM notes WHERE id = ?1",
                params![id],
                |row| row.get(0),
            )
            .ok()
            .flatten();
        let name = filename.unwrap_or_else(|| format!("{}.md", id));
        self.root.join("trash").join(name)
    }

    /// Picks a filename for a new note that won't collide with any existing
    /// row (optionally ignoring one specific id — use when renaming during
    /// a save so the note doesn't collide with its own current filename).
    pub fn pick_filename(&self, title: &str, id: &str, exclude_id: Option<&str>) -> String {
        let base = filename_for(title, id);
        if !self.filename_taken(&base, exclude_id) {
            return base;
        }
        // Suffix with `-N` before `.md`. Collisions at this level require
        // both matching slug AND matching 8-hex UUID prefix, so this loop
        // is defensive rather than expected.
        let (stem, ext) = split_ext(&base);
        for n in 2..1000 {
            let candidate = format!("{}-{}.{}", stem, n, ext);
            if !self.filename_taken(&candidate, exclude_id) {
                return candidate;
            }
        }
        base
    }

    fn filename_taken(&self, candidate: &str, exclude_id: Option<&str>) -> bool {
        let count: i64 = match exclude_id {
            Some(id) => self
                .conn
                .query_row(
                    "SELECT COUNT(*) FROM notes WHERE filename = ?1 AND id != ?2",
                    params![candidate, id],
                    |row| row.get(0),
                )
                .unwrap_or(0),
            None => self
                .conn
                .query_row(
                    "SELECT COUNT(*) FROM notes WHERE filename = ?1",
                    params![candidate],
                    |row| row.get(0),
                )
                .unwrap_or(0),
        };
        count > 0
    }

    /// First-open migration for notes that predate the `filename` column.
    /// Renames each `notes/{uuid}.md` to `notes/{slug}-{short}.md` and fills
    /// the column.
    fn backfill_filenames(&self) -> AppResult<()> {
        let mut stmt = self
            .conn
            .prepare("SELECT id, title FROM notes WHERE filename IS NULL OR filename = ''")
            .map_err(map_sql_err)?;
        let rows = stmt
            .query_map([], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
            })
            .map_err(map_sql_err)?;
        let mut entries = Vec::new();
        for r in rows {
            entries.push(r.map_err(map_sql_err)?);
        }
        drop(stmt);
        for (id, title) in entries {
            let new_name = self.pick_filename(&title, &id, Some(&id));
            let old_path = self.root.join("notes").join(format!("{}.md", id));
            let new_path = self.root.join("notes").join(&new_name);
            if old_path.exists() && old_path != new_path {
                let _ = std::fs::rename(&old_path, &new_path);
            }
            self.conn
                .execute(
                    "UPDATE notes SET filename = ?1 WHERE id = ?2",
                    params![new_name, id],
                )
                .map_err(map_sql_err)?;
        }
        Ok(())
    }
}

/// Adds a column to an existing table when it isn't there yet. SQLite has no
/// `ADD COLUMN IF NOT EXISTS`, so the pragma check is the idiom.
fn add_column_if_missing(
    conn: &Connection,
    table: &str,
    column: &str,
    decl: &str,
) -> AppResult<()> {
    let present: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM pragma_table_info(?1) WHERE name = ?2",
            params![table, column],
            |row| row.get(0),
        )
        .unwrap_or(0);
    if present == 0 {
        conn.execute(
            &format!("ALTER TABLE {} ADD COLUMN {} {}", table, column, decl),
            [],
        )
        .map_err(map_sql_err)?;
    }
    Ok(())
}

fn split_ext(name: &str) -> (&str, &str) {
    match name.rsplit_once('.') {
        Some((stem, ext)) => (stem, ext),
        None => (name, "md"),
    }
}

/// Slugifies a title into a filesystem-safe, readable stem. Keeps Hangul and
/// CJK codepoints (they're alphanumeric in unicode), replaces every other
/// char with `-`, collapses repeats, trims, and caps length. Falls back to
/// "untitled" when nothing survives.
pub fn slugify(title: &str) -> String {
    let mut out = String::new();
    let mut prev_dash = true;
    for ch in title.chars() {
        if ch.is_alphanumeric() || ch == '_' {
            out.push(ch);
            prev_dash = false;
        } else if !prev_dash {
            out.push('-');
            prev_dash = true;
        }
    }
    while out.ends_with('-') {
        out.pop();
    }
    let truncated: String = out.chars().take(50).collect();
    if truncated.is_empty() {
        "untitled".to_string()
    } else {
        truncated
    }
}

/// Canonical filename for a given title + id: `{slug}-{first-8-of-id}.md`.
/// Uses the first 8 ascii-alphanumeric chars of the id so dashes in a UUID
/// don't leak into the suffix while non-UUID ids still produce a readable
/// name.
pub fn filename_for(title: &str, id: &str) -> String {
    let slug = slugify(title);
    let short: String = id
        .chars()
        .filter(|c| c.is_ascii_alphanumeric())
        .take(8)
        .collect();
    if short.is_empty() {
        format!("{}.md", slug)
    } else {
        format!("{}-{}.md", slug, short)
    }
}

const SCHEMA: &str = r#"
CREATE TABLE IF NOT EXISTS notes (
    id TEXT PRIMARY KEY,
    title TEXT NOT NULL,
    created_ms INTEGER NOT NULL,
    mtime_ms INTEGER NOT NULL,
    size INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS session_meta (
    key TEXT PRIMARY KEY,
    value TEXT
);

CREATE TABLE IF NOT EXISTS session_tabs (
    note_id TEXT PRIMARY KEY,
    position INTEGER NOT NULL,
    cursor_line INTEGER NOT NULL DEFAULT 0,
    cursor_col INTEGER NOT NULL DEFAULT 0,
    scroll_top INTEGER NOT NULL DEFAULT 0,
    unsaved_content TEXT,
    undo_log TEXT
);

-- Jamo-normalized full-text index. Three indexed columns give BM25 a signal
-- to rank matches: title hits rank highest, body_loose (spaces preserved)
-- marks within-word matches, body_tight (spaces stripped) catches
-- cross-boundary substrings at a lower weight.
CREATE VIRTUAL TABLE IF NOT EXISTS notes_fts USING fts5(
    id UNINDEXED,
    title_jamo,
    body_jamo_tight,
    body_jamo_loose,
    tokenize='trigram'
);

-- ---------------------------------------------------------------------------
-- Notion sync. All four tables are new (never shipped without them), so
-- `CREATE TABLE IF NOT EXISTS` in this batch is the whole migration — the
-- pragma_table_info + ALTER dance above is only needed for adding columns to
-- tables that already exist in the wild.
-- ---------------------------------------------------------------------------

-- Per-workspace connection settings. Single row pinned to id = 1.
CREATE TABLE IF NOT EXISTS notion_config (
    id             INTEGER PRIMARY KEY CHECK (id = 1),
    token          TEXT,
    database_id    TEXT,
    database_title TEXT,
    title_prop     TEXT NOT NULL DEFAULT 'Name',
    -- Names of `date` properties to write Nova's note timestamps into.
    -- NULL/empty means the user hasn't opted in.
    created_prop   TEXT,
    updated_prop   TEXT,
    -- Name of a `rich_text` property holding the note's uuid, so a page can be
    -- matched back to its note even if the local mapping is lost.
    id_prop        TEXT,
    enabled        INTEGER NOT NULL DEFAULT 0,
    sync_on_start  INTEGER NOT NULL DEFAULT 1,
    auto_sync      INTEGER NOT NULL DEFAULT 1,
    interval_sec   INTEGER NOT NULL DEFAULT 900,
    last_sync_ms   INTEGER,
    last_status    TEXT
);

-- note <-> page mapping plus the 3-way merge baseline: "the last state at
-- which both sides agreed". `base_remote_edited` is Notion's last_edited_time
-- verbatim (second-granularity, bumped by our own writes) and is only used as
-- a cheap prefilter for whether the page's blocks are worth fetching;
-- `base_remote_hash` over the rendered markdown is what actually decides
-- whether the remote content changed.
CREATE TABLE IF NOT EXISTS notion_links (
    note_id             TEXT PRIMARY KEY,
    page_id             TEXT UNIQUE,
    base_local_hash     TEXT NOT NULL DEFAULT '',
    base_local_mtime_ms INTEGER NOT NULL DEFAULT 0,
    base_remote_hash    TEXT NOT NULL DEFAULT '',
    base_remote_edited  TEXT NOT NULL DEFAULT '',
    last_synced_ms      INTEGER NOT NULL DEFAULT 0,
    push_mode           TEXT NOT NULL DEFAULT 'rebuild',
    state               TEXT NOT NULL DEFAULT 'ok',
    last_error          TEXT
);
CREATE INDEX IF NOT EXISTS idx_notion_links_page ON notion_links(page_id);

-- Raw JSON of blocks Nova can't represent as markdown. Pushing rebuilds a
-- page's body from scratch (Notion has no block-move API), so these have to be
-- replayed verbatim or the user loses their callouts/tables/toggles.
CREATE TABLE IF NOT EXISTS notion_blocks (
    note_id     TEXT NOT NULL,
    block_id    TEXT NOT NULL,
    ord         INTEGER NOT NULL,
    block_type  TEXT NOT NULL,
    raw_json    TEXT NOT NULL,
    recreatable INTEGER NOT NULL DEFAULT 1,
    PRIMARY KEY (note_id, block_id)
);

-- Unresolved conflicts, with both sides snapshotted at detection time so the
-- resolution UI shows what was actually compared even if either side moves on.
CREATE TABLE IF NOT EXISTS notion_conflicts (
    note_id        TEXT PRIMARY KEY,
    page_id        TEXT,
    kind           TEXT NOT NULL,
    local_content  TEXT,
    remote_content TEXT,
    local_title    TEXT,
    remote_title   TEXT,
    detected_ms    INTEGER NOT NULL
);
"#;

fn fts_upsert(conn: &Connection, id: &str, title: &str, body: &str) -> AppResult<()> {
    let title_jamo = jamo::to_jamo(title, true);
    let body_tight = jamo::to_jamo(body, false);
    let body_loose = jamo::to_jamo(body, true);
    conn.execute("DELETE FROM notes_fts WHERE id = ?1", params![id])
        .map_err(map_sql_err)?;
    conn.execute(
        "INSERT INTO notes_fts (id, title_jamo, body_jamo_tight, body_jamo_loose) \
         VALUES (?1, ?2, ?3, ?4)",
        params![id, title_jamo, body_tight, body_loose],
    )
    .map_err(map_sql_err)?;
    Ok(())
}

fn fts_delete(conn: &Connection, id: &str) -> AppResult<()> {
    conn.execute("DELETE FROM notes_fts WHERE id = ?1", params![id])
        .map_err(map_sql_err)?;
    Ok(())
}

#[derive(Debug, serde::Serialize, serde::Deserialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct Note {
    pub id: String,
    pub title: String,
    pub created_ms: i64,
    pub mtime_ms: i64,
    pub size: i64,
}

pub fn list_notes(ws: &Workspace) -> AppResult<Vec<Note>> {
    let mut stmt = ws
        .conn
        .prepare(
            "SELECT id, title, created_ms, mtime_ms, size FROM notes \
             WHERE deleted_at_ms IS NULL ORDER BY mtime_ms DESC",
        )
        .map_err(map_sql_err)?;
    let rows = stmt
        .query_map([], |row| {
            Ok(Note {
                id: row.get(0)?,
                title: row.get(1)?,
                created_ms: row.get(2)?,
                mtime_ms: row.get(3)?,
                size: row.get(4)?,
            })
        })
        .map_err(map_sql_err)?;
    let mut out = Vec::new();
    for r in rows {
        out.push(r.map_err(map_sql_err)?);
    }
    Ok(out)
}

pub fn get_note(ws: &Workspace, id: &str) -> AppResult<Note> {
    let mut stmt = ws
        .conn
        .prepare("SELECT id, title, created_ms, mtime_ms, size FROM notes WHERE id = ?1")
        .map_err(map_sql_err)?;
    let note = stmt
        .query_row(params![id], |row| {
            Ok(Note {
                id: row.get(0)?,
                title: row.get(1)?,
                created_ms: row.get(2)?,
                mtime_ms: row.get(3)?,
                size: row.get(4)?,
            })
        })
        .map_err(map_sql_err)?;
    Ok(note)
}

pub fn insert_note(ws: &Workspace, note: &Note, content: &str) -> AppResult<String> {
    let filename = ws.pick_filename(&note.title, &note.id, None);
    ws.conn
        .execute(
            "INSERT INTO notes (id, title, created_ms, mtime_ms, size, filename) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            params![
                note.id,
                note.title,
                note.created_ms,
                note.mtime_ms,
                note.size,
                filename,
            ],
        )
        .map_err(map_sql_err)?;
    fts_upsert(&ws.conn, &note.id, &note.title, content)?;
    Ok(filename)
}

pub fn update_note_meta(
    ws: &Workspace,
    id: &str,
    title: &str,
    mtime_ms: i64,
    size: i64,
    content: &str,
) -> AppResult<()> {
    ws.conn
        .execute(
            "UPDATE notes SET title = ?1, mtime_ms = ?2, size = ?3 WHERE id = ?4",
            params![title, mtime_ms, size, id],
        )
        .map_err(map_sql_err)?;
    fts_upsert(&ws.conn, id, title, content)?;
    Ok(())
}

/// Renames the on-disk file to match the current title when needed. Returns
/// the new path (== old path when no rename happened). Safe to call even if
/// the title is unchanged — it'll no-op.
pub fn rename_note_file_if_title_changed(
    ws: &Workspace,
    id: &str,
    new_title: &str,
) -> AppResult<PathBuf> {
    let old_path = ws.note_path(id);
    let desired = filename_for(new_title, id);
    let current_filename: Option<String> = ws
        .conn
        .query_row(
            "SELECT filename FROM notes WHERE id = ?1",
            params![id],
            |row| row.get(0),
        )
        .ok()
        .flatten();
    if current_filename.as_deref() == Some(desired.as_str()) {
        return Ok(old_path);
    }
    let unique = ws.pick_filename(new_title, id, Some(id));
    let new_path = ws.root.join("notes").join(&unique);
    if new_path != old_path && old_path.exists() {
        std::fs::rename(&old_path, &new_path)?;
    }
    ws.conn
        .execute(
            "UPDATE notes SET filename = ?1 WHERE id = ?2",
            params![unique, id],
        )
        .map_err(map_sql_err)?;
    Ok(new_path)
}

/// Overwrites a note's content from an external source (Notion pull) without
/// the optimistic-concurrency check `write_note` does — the sync engine has
/// already decided this content wins. Goes through the same rename + meta +
/// FTS path as a normal save so the on-disk name, search index and note list
/// all stay consistent. Returns the post-write `(mtime_ms, size)`.
pub fn apply_remote_content(
    ws: &Workspace,
    id: &str,
    content: &str,
    title: &str,
) -> AppResult<(i64, i64)> {
    let path = ws.note_path(id);
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    std::fs::write(&path, content)?;
    let final_path = rename_note_file_if_title_changed(ws, id, title)?;
    let meta = std::fs::metadata(&final_path)?;
    let mtime = crate::fs_util::mtime_ms(&meta);
    let size = meta.len() as i64;
    update_note_meta(ws, id, title, mtime, size, content)?;
    Ok((mtime, size))
}

/// Soft-delete: moves the backing file from `notes/` to `trash/`, sets
/// deleted_at_ms so the note is hidden from active list, and clears any open
/// session tab. Callers are responsible for purging after the retention
/// window expires.
///
/// Move happens before the DB update so that a filesystem failure doesn't
/// leave the row pointing at a ghost path. If the source file is missing
/// (e.g. user deleted it externally) we still mark the row as trashed — the
/// restore path will tolerate a missing file too.
pub fn trash_note(ws: &Workspace, id: &str, now_ms: i64) -> AppResult<()> {
    let src = ws.active_path(id);
    let dst = ws.trash_path(id);
    if src.exists() {
        if let Some(parent) = dst.parent() {
            std::fs::create_dir_all(parent)?;
        }
        std::fs::rename(&src, &dst)?;
    }
    ws.conn
        .execute(
            "UPDATE notes SET deleted_at_ms = ?1 WHERE id = ?2",
            params![now_ms, id],
        )
        .map_err(map_sql_err)?;
    ws.conn
        .execute(
            "DELETE FROM session_tabs WHERE note_id = ?1",
            params![id],
        )
        .map_err(map_sql_err)?;
    Ok(())
}

/// Hard-deletes every trashed note whose `deleted_at_ms` is older than
/// `cutoff_ms`. Removes both the row and the backing file. Returns the
/// number of notes purged.
pub fn purge_old_trash(ws: &Workspace, cutoff_ms: i64) -> AppResult<usize> {
    let mut stmt = ws
        .conn
        .prepare("SELECT id FROM notes WHERE deleted_at_ms IS NOT NULL AND deleted_at_ms < ?1")
        .map_err(map_sql_err)?;
    let rows = stmt
        .query_map(params![cutoff_ms], |row| row.get::<_, String>(0))
        .map_err(map_sql_err)?;
    let mut ids = Vec::new();
    for r in rows {
        ids.push(r.map_err(map_sql_err)?);
    }
    drop(stmt);
    for id in &ids {
        let _ = std::fs::remove_file(ws.note_path(id));
        ws.conn
            .execute("DELETE FROM notes WHERE id = ?1", params![id])
            .map_err(map_sql_err)?;
        fts_delete(&ws.conn, id)?;
    }
    Ok(ids.len())
}

/// Hard-deletes a single note: removes the DB row, FTS entry, session tab,
/// and the backing file (wherever it currently lives — resolved via
/// `note_path` so it works for both active and trashed notes).
pub fn hard_delete_note(ws: &Workspace, id: &str) -> AppResult<()> {
    // Resolve the file path BEFORE deleting the row (note_path reads the DB).
    let path = ws.note_path(id);
    let _ = std::fs::remove_file(&path);
    ws.conn
        .execute("DELETE FROM notes WHERE id = ?1", params![id])
        .map_err(map_sql_err)?;
    ws.conn
        .execute(
            "DELETE FROM session_tabs WHERE note_id = ?1",
            params![id],
        )
        .map_err(map_sql_err)?;
    fts_delete(&ws.conn, id)?;
    Ok(())
}

#[derive(Debug, serde::Serialize, serde::Deserialize, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct SnippetParts {
    pub before: String,
    pub matched: String,
    pub after: String,
    pub prefix_ellipsis: bool,
    pub suffix_ellipsis: bool,
}

#[derive(Debug, serde::Serialize, serde::Deserialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct SearchHit {
    pub id: String,
    pub title: String,
    pub mtime_ms: i64,
    pub score: f64,
    pub snippet: Option<SnippetParts>,
}

const SNIPPET_CONTEXT: usize = 30;

fn clean_inline(s: String) -> String {
    s.chars()
        .map(|c| if c == '\n' || c == '\r' || c == '\t' { ' ' } else { c })
        .collect()
}

/// Finds the first position in `content` whose jamo-normalized form contains
/// `query_jamo`. Tries loose (spaces preserved) first, then tight. Returns
/// the `(start_char, end_char)` range in `content`'s char-iteration space.
fn find_match_range(content: &str, query_raw: &str) -> Option<(usize, usize)> {
    let q_loose = jamo::to_jamo(query_raw, true);
    let q_tight = jamo::to_jamo(query_raw, false);
    if q_tight.is_empty() {
        return None;
    }
    let (loose_flat, loose_map) = jamo::to_jamo_with_map(content, true);
    let (tight_flat, tight_map) = jamo::to_jamo_with_map(content, false);
    for (flat, map, q) in [
        (&loose_flat, &loose_map, &q_loose),
        (&tight_flat, &tight_map, &q_tight),
    ] {
        if q.is_empty() {
            continue;
        }
        if let Some(byte_pos) = flat.find(q.as_str()) {
            let char_pos = flat[..byte_pos].chars().count();
            let q_chars = q.chars().count();
            if q_chars == 0 {
                continue;
            }
            let end_idx = char_pos + q_chars;
            if end_idx == 0 || end_idx > map.len() {
                continue;
            }
            let start_src = map[char_pos];
            let end_src = map[end_idx - 1] + 1;
            return Some((start_src, end_src));
        }
    }
    None
}

/// Builds a snippet for the body that shows the first match with a little
/// surrounding context. Returns `None` when the body has no match (e.g. only
/// the title matched).
pub fn build_snippet(content: &str, query_raw: &str) -> Option<SnippetParts> {
    let (start, end) = find_match_range(content, query_raw)?;
    let chars: Vec<char> = content.chars().collect();
    let ctx_start = start.saturating_sub(SNIPPET_CONTEXT);
    let ctx_end = (end + SNIPPET_CONTEXT).min(chars.len());
    Some(SnippetParts {
        before: clean_inline(chars[ctx_start..start].iter().collect()),
        matched: clean_inline(chars[start..end].iter().collect()),
        after: clean_inline(chars[end..ctx_end].iter().collect()),
        prefix_ellipsis: ctx_start > 0,
        suffix_ellipsis: ctx_end < chars.len(),
    })
}

/// Search notes by jamo-normalized trigram match. `query_raw` is the user's
/// raw query string; it is normalized and passed to FTS5 as a phrase.
///
/// Short queries (2 jamo chars — too short for the trigram tokenizer) fall
/// back to a LIKE scan over the already-normalized FTS columns. Slower than
/// MATCH but still cheap in practice since the result set of a 2-char
/// substring is naturally narrow.
///
/// Returns at most `limit` hits, best first (BM25 score for MATCH path,
/// mtime desc within title-rank tier for LIKE path).
pub fn search_notes(ws: &Workspace, query_raw: &str, limit: i64) -> AppResult<Vec<SearchHit>> {
    let jamo_q = jamo::to_jamo(query_raw, false);
    let jamo_len = jamo_q.chars().count();
    if jamo_len < 2 {
        return Ok(Vec::new());
    }
    let mut out = if jamo::has_trigram(&jamo_q) {
        search_notes_fts(ws, &jamo_q, limit)?
    } else {
        search_notes_like(ws, &jamo_q, limit)?
    };
    for hit in out.iter_mut() {
        let content = std::fs::read_to_string(ws.note_path(&hit.id)).unwrap_or_default();
        hit.snippet = build_snippet(&content, query_raw);
    }
    Ok(out)
}

fn search_notes_fts(ws: &Workspace, jamo_q: &str, limit: i64) -> AppResult<Vec<SearchHit>> {
    // Wrap as a phrase so the trigram tokenizer matches an ordered sequence
    // — this is what makes "녕하" fail on body_jamo_loose (space breaks the
    // trigram chain) while still matching on body_jamo_tight.
    let match_expr = format!("\"{}\"", jamo_q);
    // Two-tier ordering: title hits win over body-only hits deterministically
    // (via `title_rank`), then BM25 sorts within each tier. BM25 column
    // weights alone don't guarantee that — title columns are short, so BM25
    // length normalization can flip the order.
    let mut stmt = ws
        .conn
        .prepare(
            "SELECT notes.id, notes.title, notes.mtime_ms, \
                    bm25(notes_fts, 5.0, 1.0, 2.5) AS score, \
                    CASE WHEN instr(notes_fts.title_jamo, ?1) > 0 THEN 0 ELSE 1 END \
                      AS title_rank \
             FROM notes_fts \
             JOIN notes ON notes.id = notes_fts.id \
             WHERE notes_fts MATCH ?2 AND notes.deleted_at_ms IS NULL \
             ORDER BY title_rank, score \
             LIMIT ?3",
        )
        .map_err(map_sql_err)?;
    let rows = stmt
        .query_map(params![jamo_q, match_expr, limit], |row| {
            Ok(SearchHit {
                id: row.get(0)?,
                title: row.get(1)?,
                mtime_ms: row.get(2)?,
                score: row.get(3)?,
                snippet: None,
            })
        })
        .map_err(map_sql_err)?;
    let mut out = Vec::new();
    for r in rows {
        out.push(r.map_err(map_sql_err)?);
    }
    Ok(out)
}

fn search_notes_like(ws: &Workspace, jamo_q: &str, limit: i64) -> AppResult<Vec<SearchHit>> {
    // LIKE on FTS5 columns — not indexed, but 2-char queries are rare and
    // table scan cost is negligible at our note counts. No BM25 available
    // here; score is 0 and ordering falls back to title-rank then mtime.
    let like_pat = format!("%{}%", jamo_q.replace('\\', "\\\\").replace('%', "\\%").replace('_', "\\_"));
    let mut stmt = ws
        .conn
        .prepare(
            "SELECT notes.id, notes.title, notes.mtime_ms, \
                    0.0 AS score, \
                    CASE WHEN instr(notes_fts.title_jamo, ?1) > 0 THEN 0 ELSE 1 END \
                      AS title_rank \
             FROM notes_fts \
             JOIN notes ON notes.id = notes_fts.id \
             WHERE (notes_fts.title_jamo LIKE ?2 ESCAPE '\\' \
                    OR notes_fts.body_jamo_tight LIKE ?2 ESCAPE '\\' \
                    OR notes_fts.body_jamo_loose LIKE ?2 ESCAPE '\\') \
               AND notes.deleted_at_ms IS NULL \
             ORDER BY title_rank, notes.mtime_ms DESC \
             LIMIT ?3",
        )
        .map_err(map_sql_err)?;
    let rows = stmt
        .query_map(params![jamo_q, like_pat, limit], |row| {
            Ok(SearchHit {
                id: row.get(0)?,
                title: row.get(1)?,
                mtime_ms: row.get(2)?,
                score: row.get(3)?,
                snippet: None,
            })
        })
        .map_err(map_sql_err)?;
    let mut out = Vec::new();
    for r in rows {
        out.push(r.map_err(map_sql_err)?);
    }
    Ok(out)
}

#[derive(Debug, serde::Serialize, serde::Deserialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct TrashedNote {
    pub id: String,
    pub title: String,
    pub deleted_at_ms: i64,
    pub size: i64,
}

/// Lists notes currently in the trash (soft-deleted), newest deletion first.
pub fn list_trashed_notes(ws: &Workspace) -> AppResult<Vec<TrashedNote>> {
    let mut stmt = ws
        .conn
        .prepare(
            "SELECT id, title, deleted_at_ms, size FROM notes \
             WHERE deleted_at_ms IS NOT NULL ORDER BY deleted_at_ms DESC",
        )
        .map_err(map_sql_err)?;
    let rows = stmt
        .query_map([], |row| {
            Ok(TrashedNote {
                id: row.get(0)?,
                title: row.get(1)?,
                deleted_at_ms: row.get(2)?,
                size: row.get(3)?,
            })
        })
        .map_err(map_sql_err)?;
    let mut out = Vec::new();
    for r in rows {
        out.push(r.map_err(map_sql_err)?);
    }
    Ok(out)
}

/// Restores a trashed note: moves the backing file from `trash/` back to
/// `notes/`, clears deleted_at_ms, and bumps mtime so it appears at the top of
/// the active list again.
///
/// If a different active note has taken over this note's filename since it was
/// trashed (`pick_filename` only checks non-trashed rows… actually it checks
/// all rows, but defensively), we pick a fresh name to avoid collision. The
/// DB `filename` column is updated to match.
pub fn restore_note(ws: &Workspace, id: &str, now_ms: i64) -> AppResult<()> {
    // Resolve title so we can rename if the original filename is taken.
    let title: String = ws
        .conn
        .query_row(
            "SELECT title FROM notes WHERE id = ?1",
            params![id],
            |row| row.get(0),
        )
        .unwrap_or_else(|_| String::new());
    let src = ws.trash_path(id);
    let current_filename: Option<String> = ws
        .conn
        .query_row(
            "SELECT filename FROM notes WHERE id = ?1",
            params![id],
            |row| row.get(0),
        )
        .ok()
        .flatten();
    // Pick a non-colliding filename under notes/ — excluding self so if the
    // existing name is still free, we keep it.
    let new_name = ws.pick_filename(&title, id, Some(id));
    let dst = ws.root.join("notes").join(&new_name);
    if let Some(parent) = dst.parent() {
        std::fs::create_dir_all(parent)?;
    }
    if src.exists() {
        std::fs::rename(&src, &dst)?;
    }
    if current_filename.as_deref() != Some(new_name.as_str()) {
        ws.conn
            .execute(
                "UPDATE notes SET filename = ?1 WHERE id = ?2",
                params![new_name, id],
            )
            .map_err(map_sql_err)?;
    }
    ws.conn
        .execute(
            "UPDATE notes SET deleted_at_ms = NULL, mtime_ms = ?1 WHERE id = ?2",
            params![now_ms, id],
        )
        .map_err(map_sql_err)?;
    Ok(())
}

#[derive(Debug, serde::Serialize, serde::Deserialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct SessionTab {
    pub note_id: String,
    pub position: i64,
    pub cursor_line: i64,
    pub cursor_col: i64,
    pub scroll_top: i64,
    pub unsaved_content: Option<String>,
    pub undo_log: Option<String>,
}

#[derive(Debug, serde::Serialize, serde::Deserialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct Session {
    pub tabs: Vec<SessionTab>,
    pub active_tab: Option<String>,
}

pub fn load_session(ws: &Workspace) -> AppResult<Session> {
    let mut stmt = ws
        .conn
        .prepare("SELECT note_id, position, cursor_line, cursor_col, scroll_top, unsaved_content, undo_log FROM session_tabs ORDER BY position ASC")
        .map_err(map_sql_err)?;
    let rows = stmt
        .query_map([], |row| {
            Ok(SessionTab {
                note_id: row.get(0)?,
                position: row.get(1)?,
                cursor_line: row.get(2)?,
                cursor_col: row.get(3)?,
                scroll_top: row.get(4)?,
                unsaved_content: row.get(5)?,
                undo_log: row.get(6)?,
            })
        })
        .map_err(map_sql_err)?;
    let mut tabs = Vec::new();
    for r in rows {
        tabs.push(r.map_err(map_sql_err)?);
    }
    let active_tab = ws
        .conn
        .query_row(
            "SELECT value FROM session_meta WHERE key = 'active_tab'",
            [],
            |row| row.get::<_, Option<String>>(0),
        )
        .ok()
        .flatten();
    Ok(Session { tabs, active_tab })
}

pub fn save_session(ws: &mut Workspace, session: &Session) -> AppResult<()> {
    let tx = ws.conn.transaction().map_err(map_sql_err)?;
    tx.execute("DELETE FROM session_tabs", [])
        .map_err(map_sql_err)?;
    for (i, tab) in session.tabs.iter().enumerate() {
        tx.execute(
            "INSERT INTO session_tabs (note_id, position, cursor_line, cursor_col, scroll_top, unsaved_content, undo_log) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
            params![
                tab.note_id,
                i as i64,
                tab.cursor_line,
                tab.cursor_col,
                tab.scroll_top,
                tab.unsaved_content,
                tab.undo_log,
            ],
        )
        .map_err(map_sql_err)?;
    }
    tx.execute(
        "INSERT OR REPLACE INTO session_meta (key, value) VALUES ('active_tab', ?1)",
        params![session.active_tab],
    )
    .map_err(map_sql_err)?;
    tx.commit().map_err(map_sql_err)?;
    Ok(())
}

pub fn save_tab(ws: &Workspace, tab: &SessionTab) -> AppResult<()> {
    ws.conn
        .execute(
            "INSERT INTO session_tabs (note_id, position, cursor_line, cursor_col, scroll_top, unsaved_content, undo_log) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7) ON CONFLICT(note_id) DO UPDATE SET position=excluded.position, cursor_line=excluded.cursor_line, cursor_col=excluded.cursor_col, scroll_top=excluded.scroll_top, unsaved_content=excluded.unsaved_content, undo_log=excluded.undo_log",
            params![
                tab.note_id,
                tab.position,
                tab.cursor_line,
                tab.cursor_col,
                tab.scroll_top,
                tab.unsaved_content,
                tab.undo_log,
            ],
        )
        .map_err(map_sql_err)?;
    Ok(())
}

pub fn set_active_tab(ws: &Workspace, active: Option<&str>) -> AppResult<()> {
    ws.conn
        .execute(
            "INSERT OR REPLACE INTO session_meta (key, value) VALUES ('active_tab', ?1)",
            params![active],
        )
        .map_err(map_sql_err)?;
    Ok(())
}

pub fn remove_tab(ws: &Workspace, note_id: &str) -> AppResult<()> {
    ws.conn
        .execute(
            "DELETE FROM session_tabs WHERE note_id = ?1",
            params![note_id],
        )
        .map_err(map_sql_err)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    #[test]
    fn open_creates_schema_and_dir() {
        let dir = tempdir().unwrap();
        let ws = Workspace::open(dir.path()).unwrap();
        assert!(dir.path().join("notes").is_dir());
        assert!(dir.path().join("workspace.db").is_file());
        drop(ws);
    }

    #[test]
    fn note_crud_round_trip() {
        let dir = tempdir().unwrap();
        let ws = Workspace::open(dir.path()).unwrap();
        let note = Note {
            id: "abc".into(),
            title: "Hello".into(),
            created_ms: 100,
            mtime_ms: 200,
            size: 5,
        };
        insert_note(&ws, &note, "").unwrap();
        let got = get_note(&ws, "abc").unwrap();
        assert_eq!(got.title, "Hello");
        update_note_meta(&ws, "abc", "Updated", 300, 7, "body").unwrap();
        let after = get_note(&ws, "abc").unwrap();
        assert_eq!(after.title, "Updated");
        assert_eq!(after.mtime_ms, 300);
        let listed = list_notes(&ws).unwrap();
        assert_eq!(listed.len(), 1);
        hard_delete_note(&ws, "abc").unwrap();
        assert_eq!(list_notes(&ws).unwrap().len(), 0);
    }

    #[test]
    fn trash_moves_file_to_trash_folder() {
        let dir = tempdir().unwrap();
        let ws = Workspace::open(dir.path()).unwrap();
        insert_note(
            &ws,
            &Note {
                id: "abc".into(),
                title: "Hello".into(),
                created_ms: 100,
                mtime_ms: 200,
                size: 5,
            },
            "hello",
        )
        .unwrap();
        let active_path = ws.active_path("abc");
        std::fs::write(&active_path, "hello").unwrap();
        assert!(active_path.starts_with(dir.path().join("notes")));

        trash_note(&ws, "abc", 500).unwrap();

        assert_eq!(list_notes(&ws).unwrap().len(), 0, "trashed note hidden from active list");
        assert!(!active_path.exists(), "original notes/ file moved away");
        let trashed_path = ws.trash_path("abc");
        assert!(trashed_path.starts_with(dir.path().join("trash")));
        assert!(trashed_path.is_file(), "file now lives under trash/");
        assert_eq!(std::fs::read_to_string(&trashed_path).unwrap(), "hello");
        // note_path() should follow the file into trash/.
        assert_eq!(ws.note_path("abc"), trashed_path);
    }

    #[test]
    fn trash_and_purge_round_trip() {
        let dir = tempdir().unwrap();
        let ws = Workspace::open(dir.path()).unwrap();
        insert_note(
            &ws,
            &Note {
                id: "abc".into(),
                title: "Hello".into(),
                created_ms: 100,
                mtime_ms: 200,
                size: 5,
            },
            "hello",
        )
        .unwrap();
        let active_path = ws.active_path("abc");
        std::fs::write(&active_path, "hello").unwrap();
        trash_note(&ws, "abc", 500).unwrap();
        let trashed_path = ws.trash_path("abc");
        assert!(trashed_path.is_file(), "file kept on disk while in trash");
        let purged = purge_old_trash(&ws, 400).unwrap();
        assert_eq!(purged, 0, "cutoff < deleted_at — nothing purged");
        assert!(trashed_path.is_file());
        let purged = purge_old_trash(&ws, 600).unwrap();
        assert_eq!(purged, 1, "cutoff > deleted_at — purged");
        assert!(!trashed_path.exists(), "file removed on purge");
    }

    #[test]
    fn restore_moves_file_back_to_notes_folder() {
        let dir = tempdir().unwrap();
        let ws = Workspace::open(dir.path()).unwrap();
        insert_note(
            &ws,
            &Note {
                id: "abc".into(),
                title: "Hello".into(),
                created_ms: 100,
                mtime_ms: 200,
                size: 5,
            },
            "hello",
        )
        .unwrap();
        let active_path = ws.active_path("abc");
        std::fs::write(&active_path, "hello").unwrap();

        trash_note(&ws, "abc", 500).unwrap();
        assert!(!active_path.exists());
        assert!(ws.trash_path("abc").is_file());

        restore_note(&ws, "abc", 900).unwrap();

        assert_eq!(list_notes(&ws).unwrap().len(), 1, "restored note visible again");
        assert!(!ws.trash_path("abc").exists(), "file no longer in trash/");
        assert!(active_path.is_file(), "file back under notes/");
        assert_eq!(std::fs::read_to_string(&active_path).unwrap(), "hello");
        // mtime bumped so restored note sorts to the top.
        assert_eq!(get_note(&ws, "abc").unwrap().mtime_ms, 900);
    }

    #[test]
    fn restore_handles_filename_collision() {
        // If another note has grabbed the same filename while this one was in
        // trash, restore should pick a fresh name and update the DB column so
        // note_path keeps resolving.
        let dir = tempdir().unwrap();
        let ws = Workspace::open(dir.path()).unwrap();
        // Seed: note A exists, gets trashed.
        insert_note(
            &ws,
            &Note {
                id: "aaaaaaaa-1".into(),
                title: "Same Title".into(),
                created_ms: 1,
                mtime_ms: 1,
                size: 0,
            },
            "",
        )
        .unwrap();
        std::fs::write(ws.active_path("aaaaaaaa-1"), "first").unwrap();
        trash_note(&ws, "aaaaaaaa-1", 100).unwrap();

        // Force a collision: manually set another row to the same filename A
        // would restore to, simulating a race. Use the first 8-char prefix
        // that `filename_for` would derive for "aaaaaaaa-1".
        let taken_name = filename_for("Same Title", "aaaaaaaa-1");
        ws.conn
            .execute(
                "INSERT INTO notes (id, title, created_ms, mtime_ms, size, filename) \
                 VALUES ('other', 'Same Title', 2, 2, 0, ?1)",
                params![taken_name],
            )
            .unwrap();

        restore_note(&ws, "aaaaaaaa-1", 200).unwrap();

        // Restored file is on disk under a unique name (with a -N suffix).
        let restored_path = ws.note_path("aaaaaaaa-1");
        assert!(restored_path.is_file(), "restored file exists: {:?}", restored_path);
        assert_ne!(
            restored_path.file_name().unwrap().to_string_lossy(),
            taken_name,
            "did not reuse the taken filename"
        );
        assert_eq!(std::fs::read_to_string(&restored_path).unwrap(), "first");
    }

    #[test]
    fn session_round_trip() {
        let dir = tempdir().unwrap();
        let mut ws = Workspace::open(dir.path()).unwrap();
        let session = Session {
            tabs: vec![
                SessionTab {
                    note_id: "a".into(),
                    position: 0,
                    cursor_line: 1,
                    cursor_col: 2,
                    scroll_top: 40,
                    unsaved_content: Some("hi".into()),
                    undo_log: None,
                },
                SessionTab {
                    note_id: "b".into(),
                    position: 1,
                    cursor_line: 0,
                    cursor_col: 0,
                    scroll_top: 0,
                    unsaved_content: None,
                    undo_log: Some("[]".into()),
                },
            ],
            active_tab: Some("a".into()),
        };
        save_session(&mut ws, &session).unwrap();
        let loaded = load_session(&ws).unwrap();
        assert_eq!(loaded.tabs.len(), 2);
        assert_eq!(loaded.tabs[0].note_id, "a");
        assert_eq!(loaded.tabs[1].note_id, "b");
        assert_eq!(loaded.active_tab.as_deref(), Some("a"));
    }

    #[test]
    fn list_notes_sorted_by_mtime_desc() {
        let dir = tempdir().unwrap();
        let ws = Workspace::open(dir.path()).unwrap();
        insert_note(
            &ws,
            &Note {
                id: "old".into(),
                title: "old".into(),
                created_ms: 1,
                mtime_ms: 1,
                size: 0,
            },
            "",
        )
        .unwrap();
        insert_note(
            &ws,
            &Note {
                id: "new".into(),
                title: "new".into(),
                created_ms: 2,
                mtime_ms: 10,
                size: 0,
            },
            "",
        )
        .unwrap();
        let listed = list_notes(&ws).unwrap();
        assert_eq!(listed[0].id, "new");
        assert_eq!(listed[1].id, "old");
    }

    fn seed_note(ws: &Workspace, id: &str, title: &str, body: &str, mtime: i64) {
        insert_note(
            ws,
            &Note {
                id: id.into(),
                title: title.into(),
                created_ms: mtime,
                mtime_ms: mtime,
                size: body.len() as i64,
            },
            body,
        )
        .unwrap();
    }

    #[test]
    fn search_matches_partial_jamo() {
        let dir = tempdir().unwrap();
        let ws = Workspace::open(dir.path()).unwrap();
        seed_note(&ws, "a", "greetings", "안녕하세요 반갑습니다", 10);
        seed_note(&ws, "b", "other", "완전 다른 내용", 20);

        // "안녕ㅎ" → partial cho ㅎ should still match "안녕하세요".
        let hits = search_notes(&ws, "안녕ㅎ", 10).unwrap();
        assert!(hits.iter().any(|h| h.id == "a"), "hits={hits:?}");
        assert!(!hits.iter().any(|h| h.id == "b"));
    }

    #[test]
    fn search_prefers_within_boundary_match() {
        let dir = tempdir().unwrap();
        let ws = Workspace::open(dir.path()).unwrap();
        // Both contain "하세요" logically, but `a` has it contiguous inside
        // "하세요연습", while `b` splits it across a space: "안녕 하세요".
        seed_note(&ws, "a", "note a", "하세요연습", 10);
        seed_note(&ws, "b", "note b", "안녕 하세요", 20);
        // Query "녕하세" would match ONLY b on tight (across space); it would
        // not match a at all. So use a query that both can match but only one
        // can match on loose: "하세요" matches loose on both → ensure both
        // present.
        let hits = search_notes(&ws, "하세요", 10).unwrap();
        let ids: Vec<_> = hits.iter().map(|h| h.id.as_str()).collect();
        assert!(ids.contains(&"a"));
        assert!(ids.contains(&"b"));
    }

    #[test]
    fn search_cross_boundary_matches_tight_only() {
        let dir = tempdir().unwrap();
        let ws = Workspace::open(dir.path()).unwrap();
        seed_note(&ws, "b", "note b", "안녕 하세요", 20);
        // The trigram `ㅕㅇㅎ` is only present in the tight (space-stripped)
        // jamo stream, so this verifies tight-column matching works.
        let hits = search_notes(&ws, "녕하세요", 10).unwrap();
        assert!(hits.iter().any(|h| h.id == "b"), "hits={hits:?}");
    }

    #[test]
    fn search_excludes_trashed_notes() {
        let dir = tempdir().unwrap();
        let ws = Workspace::open(dir.path()).unwrap();
        seed_note(&ws, "a", "t", "안녕하세요", 10);
        trash_note(&ws, "a", 1000).unwrap();
        let hits = search_notes(&ws, "안녕하세요", 10).unwrap();
        assert!(hits.is_empty());
    }

    #[test]
    fn search_title_ranked_higher_than_body() {
        let dir = tempdir().unwrap();
        let ws = Workspace::open(dir.path()).unwrap();
        // Same keyword in title of a vs body of b. Title weight is 5.0 vs
        // body 1.0/2.5 — a should rank higher (smaller bm25 score).
        seed_note(&ws, "a", "안녕하세요", "other body", 10);
        seed_note(&ws, "b", "other title", "안녕하세요 body", 20);
        let hits = search_notes(&ws, "안녕하세요", 10).unwrap();
        assert_eq!(hits.first().map(|h| h.id.as_str()), Some("a"), "{hits:?}");
    }

    #[test]
    fn build_snippet_locates_match_in_original_chars() {
        let content = "앞부분 텍스트 안녕하세요 반갑습니다 뒷부분 텍스트";
        let snip = build_snippet(content, "안녕ㅎ").expect("should find match");
        assert_eq!(snip.matched, "안녕하");
        assert!(snip.before.ends_with("트 ") || snip.before.contains(" "));
        assert!(snip.after.starts_with("세요"));
    }

    #[test]
    fn build_snippet_returns_none_when_no_body_match() {
        let snip = build_snippet("totally different content", "안녕");
        assert!(snip.is_none());
    }

    #[test]
    fn build_snippet_collapses_newlines_to_spaces() {
        let content = "line1\n안녕하세요\nline3";
        let snip = build_snippet(content, "안녕").expect("should match");
        assert!(!snip.before.contains('\n'));
        assert!(!snip.after.contains('\n'));
    }

    #[test]
    fn search_attaches_snippet_to_hit() {
        let dir = tempdir().unwrap();
        let ws = Workspace::open(dir.path()).unwrap();
        insert_note(
            &ws,
            &Note {
                id: "a".into(),
                title: "other title".into(),
                created_ms: 10,
                mtime_ms: 10,
                size: 0,
            },
            "안녕하세요 반갑습니다",
        )
        .unwrap();
        std::fs::write(ws.note_path("a"), "안녕하세요 반갑습니다").unwrap();
        let hits = search_notes(&ws, "안녕하", 10).unwrap();
        assert_eq!(hits.len(), 1);
        let snip = hits[0].snippet.as_ref().expect("snippet populated");
        assert_eq!(snip.matched, "안녕하");
    }

    #[test]
    fn search_ignores_one_char_queries() {
        let dir = tempdir().unwrap();
        let ws = Workspace::open(dir.path()).unwrap();
        seed_note(&ws, "a", "t", "안녕", 10);
        // Single ASCII char normalizes to 1 jamo → below 2-char floor.
        assert!(search_notes(&ws, "a", 10).unwrap().is_empty());
    }

    #[test]
    fn search_two_jamo_falls_back_to_like() {
        let dir = tempdir().unwrap();
        let ws = Workspace::open(dir.path()).unwrap();
        insert_note(
            &ws,
            &Note {
                id: "a".into(),
                title: "t".into(),
                created_ms: 10,
                mtime_ms: 10,
                size: 0,
            },
            "안녕하세요",
        )
        .unwrap();
        std::fs::write(ws.note_path("a"), "안녕하세요").unwrap();
        // "아" → jamo "ㅇㅏ" (2 chars) — below trigram floor. LIKE fallback
        // should still match because "ㅇㅏ" appears in decomposed body.
        let hits = search_notes(&ws, "아", 10).unwrap();
        assert_eq!(hits.len(), 1, "hits={hits:?}");
        assert_eq!(hits[0].id, "a");
    }

    #[test]
    fn slugify_keeps_hangul_and_replaces_punct() {
        assert_eq!(slugify("Meeting with Alex!"), "Meeting-with-Alex");
        assert_eq!(slugify("프로젝트 노트 #1"), "프로젝트-노트-1");
        assert_eq!(slugify("   "), "untitled");
        assert_eq!(slugify("---"), "untitled");
        let long: String = "a".repeat(100);
        assert_eq!(slugify(&long).chars().count(), 50);
    }

    #[test]
    fn filename_for_uses_slug_and_short_id() {
        let id = "a3f29b14-1234-5678-9abc-def012345678";
        assert_eq!(filename_for("Meeting with Alex", id), "Meeting-with-Alex-a3f29b14.md");
    }

    #[test]
    fn insert_note_stores_readable_filename() {
        let dir = tempdir().unwrap();
        let ws = Workspace::open(dir.path()).unwrap();
        let id = "a3f29b14-deadbeef";
        insert_note(
            &ws,
            &Note {
                id: id.into(),
                title: "My Note".into(),
                created_ms: 1,
                mtime_ms: 1,
                size: 0,
            },
            "",
        )
        .unwrap();
        let p = ws.note_path(id);
        assert_eq!(p.file_name().unwrap().to_string_lossy(), "My-Note-a3f29b14.md");
    }

    #[test]
    fn rename_on_title_change_moves_file_and_updates_db() {
        let dir = tempdir().unwrap();
        let ws = Workspace::open(dir.path()).unwrap();
        let id = "abcdef01-5678-90ab-cdef-0123456789ab";
        insert_note(
            &ws,
            &Note {
                id: id.into(),
                title: "First".into(),
                created_ms: 1,
                mtime_ms: 1,
                size: 0,
            },
            "",
        )
        .unwrap();
        let old_path = ws.note_path(id);
        std::fs::write(&old_path, "hi").unwrap();
        rename_note_file_if_title_changed(&ws, id, "Second Title").unwrap();
        let new_path = ws.note_path(id);
        assert_ne!(old_path, new_path);
        assert!(!old_path.exists(), "old file removed");
        assert_eq!(std::fs::read_to_string(&new_path).unwrap(), "hi");
        assert_eq!(
            new_path.file_name().unwrap().to_string_lossy(),
            "Second-Title-abcdef01.md"
        );
    }

    #[test]
    fn backfill_renames_legacy_uuid_files() {
        let dir = tempdir().unwrap();
        // Pre-migration state: create DB row with NULL filename and a
        // `notes/{uuid}.md` file on disk.
        {
            let ws = Workspace::open(dir.path()).unwrap();
            // Simulate legacy state: insert a row and then clear `filename`
            // to mimic a workspace that predates the column.
            insert_note(
                &ws,
                &Note {
                    id: "legacy01-2345-6789".into(),
                    title: "Legacy Note".into(),
                    created_ms: 1,
                    mtime_ms: 1,
                    size: 0,
                },
                "",
            )
            .unwrap();
            let current = ws.note_path("legacy01-2345-6789");
            // Move it back to the legacy location and null out filename.
            let legacy = dir.path().join("notes").join("legacy01-2345-6789.md");
            std::fs::write(&legacy, "payload").unwrap();
            if current != legacy && current.exists() {
                std::fs::remove_file(&current).unwrap();
            }
            ws.conn
                .execute(
                    "UPDATE notes SET filename = NULL WHERE id = ?1",
                    params!["legacy01-2345-6789"],
                )
                .unwrap();
        }
        // Re-open — migration should rename the file and fill the column.
        let ws = Workspace::open(dir.path()).unwrap();
        let p = ws.note_path("legacy01-2345-6789");
        assert_eq!(
            p.file_name().unwrap().to_string_lossy(),
            "Legacy-Note-legacy01.md"
        );
        assert_eq!(std::fs::read_to_string(&p).unwrap(), "payload");
        assert!(!dir.path().join("notes").join("legacy01-2345-6789.md").exists());
    }
}
