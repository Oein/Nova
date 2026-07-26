//! Every read/write of the four `notion_*` tables lives here, so the sync
//! engine and the commands never hand-write SQL.

use rusqlite::{params, OptionalExtension};
use serde::Serialize;

use crate::error::{AppError, AppResult};
use crate::notion::{NotionConfigInput, NotionConfigView};
use crate::workspace::Workspace;

fn map_sql_err(e: rusqlite::Error) -> AppError {
    AppError::Other(format!("sqlite: {}", e))
}

pub const DEFAULT_INTERVAL_SEC: i64 = 900;
pub const MIN_INTERVAL_SEC: i64 = 60;
pub const MAX_INTERVAL_SEC: i64 = 24 * 60 * 60;

/// The full config row, PAT included. Stays inside Rust — the frontend gets
/// [`NotionConfigView`] instead.
#[derive(Debug, Clone)]
pub struct NotionConfig {
    pub token: Option<String>,
    pub database_id: Option<String>,
    pub database_title: Option<String>,
    pub title_prop: String,
    /// Name of a `date` property to write the note's creation time into.
    /// `None` = the user hasn't opted in.
    pub created_prop: Option<String>,
    /// Same, for the note's last-modified time.
    pub updated_prop: Option<String>,
    /// Name of a `rich_text` property holding the note's uuid. Gives pages a
    /// stable identity independent of their title.
    pub id_prop: Option<String>,
    pub enabled: bool,
    pub sync_on_start: bool,
    pub auto_sync: bool,
    pub interval_sec: i64,
    pub last_sync_ms: Option<i64>,
    pub last_status: Option<String>,
}

impl Default for NotionConfig {
    fn default() -> Self {
        Self {
            token: None,
            database_id: None,
            database_title: None,
            title_prop: "Name".to_string(),
            created_prop: None,
            updated_prop: None,
            id_prop: None,
            enabled: false,
            sync_on_start: true,
            auto_sync: true,
            interval_sec: DEFAULT_INTERVAL_SEC,
            last_sync_ms: None,
            last_status: None,
        }
    }
}

impl NotionConfig {
    pub fn to_view(&self, conflict_count: i64) -> NotionConfigView {
        NotionConfigView {
            token_set: self.token.as_deref().is_some_and(|t| !t.is_empty()),
            token_hint: self
                .token
                .as_deref()
                .map(|t| t.chars().rev().take(4).collect::<Vec<_>>().into_iter().rev().collect())
                .unwrap_or_default(),
            database_id: self.database_id.clone(),
            database_title: self.database_title.clone(),
            title_prop: self.title_prop.clone(),
            created_prop: self.created_prop.clone(),
            updated_prop: self.updated_prop.clone(),
            id_prop: self.id_prop.clone(),
            enabled: self.enabled,
            sync_on_start: self.sync_on_start,
            auto_sync: self.auto_sync,
            interval_sec: self.interval_sec,
            last_sync_ms: self.last_sync_ms,
            last_status: self.last_status.clone(),
            conflict_count,
        }
    }

    /// The token/database pair required before any sync can run.
    pub fn credentials(&self) -> AppResult<(String, String)> {
        let token = self
            .token
            .clone()
            .filter(|t| !t.is_empty())
            .ok_or_else(|| AppError::Other("Notion token is not set".into()))?;
        let db = self
            .database_id
            .clone()
            .filter(|d| !d.is_empty())
            .ok_or_else(|| AppError::Other("Notion database is not selected".into()))?;
        Ok((token, db))
    }
}

pub fn clamp_interval(sec: i64) -> i64 {
    sec.clamp(MIN_INTERVAL_SEC, MAX_INTERVAL_SEC)
}

pub fn get_config(ws: &Workspace) -> AppResult<NotionConfig> {
    let row = ws
        .conn
        .query_row(
            "SELECT token, database_id, database_title, title_prop, enabled, \
                    sync_on_start, auto_sync, interval_sec, last_sync_ms, last_status, \
                    created_prop, updated_prop, id_prop \
             FROM notion_config WHERE id = 1",
            [],
            |row| {
                Ok(NotionConfig {
                    token: row.get(0)?,
                    database_id: row.get(1)?,
                    database_title: row.get(2)?,
                    title_prop: row.get(3)?,
                    enabled: row.get::<_, i64>(4)? != 0,
                    sync_on_start: row.get::<_, i64>(5)? != 0,
                    auto_sync: row.get::<_, i64>(6)? != 0,
                    interval_sec: row.get(7)?,
                    last_sync_ms: row.get(8)?,
                    last_status: row.get(9)?,
                    created_prop: row.get(10)?,
                    updated_prop: row.get(11)?,
                    id_prop: row.get(12)?,
                })
            },
        )
        .optional()
        .map_err(map_sql_err)?;
    Ok(row.unwrap_or_default())
}

/// Applies a partial update. Fields left `None` keep their stored value —
/// notably `token`, which the settings UI never sends unless the user typed a
/// new one.
pub fn set_config(ws: &Workspace, input: &NotionConfigInput) -> AppResult<NotionConfig> {
    let mut cfg = get_config(ws)?;
    if let Some(t) = &input.token {
        cfg.token = if t.trim().is_empty() {
            None
        } else {
            Some(t.trim().to_string())
        };
    }
    if let Some(db) = &input.database_id {
        let new_db = if db.trim().is_empty() {
            None
        } else {
            Some(db.trim().to_string())
        };
        // Repointing at a different database invalidates every mapping — the
        // old page ids don't exist there. Clearing is safer than leaving links
        // that would resolve to "remote deleted" and trash the user's notes.
        if new_db != cfg.database_id {
            clear_all_links(ws)?;
        }
        cfg.database_id = new_db;
    }
    if let Some(t) = &input.database_title {
        cfg.database_title = Some(t.clone());
    }
    // An empty string is how the UI says "turn this column off".
    if let Some(p) = &input.created_prop {
        cfg.created_prop = Some(p.trim().to_string()).filter(|s| !s.is_empty());
    }
    if let Some(p) = &input.updated_prop {
        cfg.updated_prop = Some(p.trim().to_string()).filter(|s| !s.is_empty());
    }
    if let Some(p) = &input.id_prop {
        cfg.id_prop = Some(p.trim().to_string()).filter(|s| !s.is_empty());
    }
    if let Some(v) = input.enabled {
        cfg.enabled = v;
    }
    if let Some(v) = input.sync_on_start {
        cfg.sync_on_start = v;
    }
    if let Some(v) = input.auto_sync {
        cfg.auto_sync = v;
    }
    if let Some(v) = input.interval_sec {
        cfg.interval_sec = clamp_interval(v);
    }
    write_config(ws, &cfg)?;
    Ok(cfg)
}

pub fn write_config(ws: &Workspace, cfg: &NotionConfig) -> AppResult<()> {
    ws.conn
        .execute(
            "INSERT INTO notion_config \
               (id, token, database_id, database_title, title_prop, enabled, \
                sync_on_start, auto_sync, interval_sec, last_sync_ms, last_status, \
                created_prop, updated_prop, id_prop) \
             VALUES (1, ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13) \
             ON CONFLICT(id) DO UPDATE SET \
               token = ?1, database_id = ?2, database_title = ?3, title_prop = ?4, \
               enabled = ?5, sync_on_start = ?6, auto_sync = ?7, interval_sec = ?8, \
               last_sync_ms = ?9, last_status = ?10, created_prop = ?11, \
               updated_prop = ?12, id_prop = ?13",
            params![
                cfg.token,
                cfg.database_id,
                cfg.database_title,
                cfg.title_prop,
                cfg.enabled as i64,
                cfg.sync_on_start as i64,
                cfg.auto_sync as i64,
                cfg.interval_sec,
                cfg.last_sync_ms,
                cfg.last_status,
                cfg.created_prop,
                cfg.updated_prop,
                cfg.id_prop,
            ],
        )
        .map_err(map_sql_err)?;
    Ok(())
}

pub fn set_title_prop(ws: &Workspace, prop: &str) -> AppResult<()> {
    ws.conn
        .execute(
            "UPDATE notion_config SET title_prop = ?1 WHERE id = 1",
            params![prop],
        )
        .map_err(map_sql_err)?;
    Ok(())
}

pub fn set_last_sync(ws: &Workspace, ms: i64, status: &str) -> AppResult<()> {
    ws.conn
        .execute(
            "UPDATE notion_config SET last_sync_ms = ?1, last_status = ?2 WHERE id = 1",
            params![ms, status],
        )
        .map_err(map_sql_err)?;
    Ok(())
}

pub fn clear_token(ws: &Workspace) -> AppResult<()> {
    ws.conn
        .execute(
            "UPDATE notion_config SET token = NULL, enabled = 0 WHERE id = 1",
            [],
        )
        .map_err(map_sql_err)?;
    Ok(())
}

// ---------------------------------------------------------------------------
// links
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Link {
    pub note_id: String,
    pub page_id: Option<String>,
    pub base_local_hash: String,
    pub base_local_mtime_ms: i64,
    pub base_remote_hash: String,
    pub base_remote_edited: String,
    pub last_synced_ms: i64,
    pub push_mode: String,
    pub state: String,
    pub last_error: Option<String>,
}

impl Link {
    pub fn new(note_id: &str, page_id: Option<&str>) -> Self {
        Self {
            note_id: note_id.to_string(),
            page_id: page_id.map(|s| s.to_string()),
            base_local_hash: String::new(),
            base_local_mtime_ms: 0,
            base_remote_hash: String::new(),
            base_remote_edited: String::new(),
            last_synced_ms: 0,
            push_mode: "rebuild".to_string(),
            state: "ok".to_string(),
            last_error: None,
        }
    }

    pub fn is_blocked(&self) -> bool {
        self.push_mode == "blocked"
    }
}

fn row_to_link(row: &rusqlite::Row) -> rusqlite::Result<Link> {
    Ok(Link {
        note_id: row.get(0)?,
        page_id: row.get(1)?,
        base_local_hash: row.get(2)?,
        base_local_mtime_ms: row.get(3)?,
        base_remote_hash: row.get(4)?,
        base_remote_edited: row.get(5)?,
        last_synced_ms: row.get(6)?,
        push_mode: row.get(7)?,
        state: row.get(8)?,
        last_error: row.get(9)?,
    })
}

const LINK_COLS: &str = "note_id, page_id, base_local_hash, base_local_mtime_ms, \
                         base_remote_hash, base_remote_edited, last_synced_ms, \
                         push_mode, state, last_error";

pub fn list_links(ws: &Workspace) -> AppResult<Vec<Link>> {
    let sql = format!("SELECT {} FROM notion_links", LINK_COLS);
    let mut stmt = ws.conn.prepare(&sql).map_err(map_sql_err)?;
    let rows = stmt.query_map([], row_to_link).map_err(map_sql_err)?;
    let mut out = Vec::new();
    for r in rows {
        out.push(r.map_err(map_sql_err)?);
    }
    Ok(out)
}

pub fn get_link(ws: &Workspace, note_id: &str) -> AppResult<Option<Link>> {
    let sql = format!("SELECT {} FROM notion_links WHERE note_id = ?1", LINK_COLS);
    ws.conn
        .query_row(&sql, params![note_id], row_to_link)
        .optional()
        .map_err(map_sql_err)
}

pub fn upsert_link(ws: &Workspace, link: &Link) -> AppResult<()> {
    ws.conn
        .execute(
            "INSERT INTO notion_links \
               (note_id, page_id, base_local_hash, base_local_mtime_ms, base_remote_hash, \
                base_remote_edited, last_synced_ms, push_mode, state, last_error) \
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10) \
             ON CONFLICT(note_id) DO UPDATE SET \
               page_id = ?2, base_local_hash = ?3, base_local_mtime_ms = ?4, \
               base_remote_hash = ?5, base_remote_edited = ?6, last_synced_ms = ?7, \
               push_mode = ?8, state = ?9, last_error = ?10",
            params![
                link.note_id,
                link.page_id,
                link.base_local_hash,
                link.base_local_mtime_ms,
                link.base_remote_hash,
                link.base_remote_edited,
                link.last_synced_ms,
                link.push_mode,
                link.state,
                link.last_error,
            ],
        )
        .map_err(map_sql_err)?;
    Ok(())
}

pub fn set_link_state(ws: &Workspace, note_id: &str, state: &str, err: Option<&str>) -> AppResult<()> {
    ws.conn
        .execute(
            "UPDATE notion_links SET state = ?1, last_error = ?2 WHERE note_id = ?3",
            params![state, err, note_id],
        )
        .map_err(map_sql_err)?;
    Ok(())
}

pub fn delete_link(ws: &Workspace, note_id: &str) -> AppResult<()> {
    ws.conn
        .execute("DELETE FROM notion_links WHERE note_id = ?1", params![note_id])
        .map_err(map_sql_err)?;
    delete_blocks(ws, note_id)?;
    Ok(())
}

pub fn clear_all_links(ws: &Workspace) -> AppResult<()> {
    for sql in [
        "DELETE FROM notion_links",
        "DELETE FROM notion_blocks",
        "DELETE FROM notion_conflicts",
    ] {
        ws.conn.execute(sql, []).map_err(map_sql_err)?;
    }
    Ok(())
}

/// Every note in the workspace, trashed ones included — the sync engine has to
/// see a soft-deleted note to know it should archive the remote page.
#[derive(Debug, Clone)]
pub struct NoteRow {
    pub id: String,
    pub title: String,
    pub created_ms: i64,
    pub mtime_ms: i64,
    pub trashed: bool,
}

pub fn list_note_rows(ws: &Workspace) -> AppResult<Vec<NoteRow>> {
    let mut stmt = ws
        .conn
        .prepare("SELECT id, title, mtime_ms, deleted_at_ms, created_ms FROM notes")
        .map_err(map_sql_err)?;
    let rows = stmt
        .query_map([], |row| {
            Ok(NoteRow {
                id: row.get(0)?,
                title: row.get(1)?,
                mtime_ms: row.get(2)?,
                trashed: row.get::<_, Option<i64>>(3)?.is_some(),
                created_ms: row.get(4)?,
            })
        })
        .map_err(map_sql_err)?;
    let mut out = Vec::new();
    for r in rows {
        out.push(r.map_err(map_sql_err)?);
    }
    Ok(out)
}

// ---------------------------------------------------------------------------
// unsupported-block cache
// ---------------------------------------------------------------------------

#[derive(Debug, Clone)]
pub struct CachedBlock {
    pub block_id: String,
    pub ord: i64,
    pub block_type: String,
    pub raw_json: String,
    pub recreatable: bool,
}

pub fn list_blocks(ws: &Workspace, note_id: &str) -> AppResult<Vec<CachedBlock>> {
    let mut stmt = ws
        .conn
        .prepare(
            "SELECT block_id, ord, block_type, raw_json, recreatable \
             FROM notion_blocks WHERE note_id = ?1 ORDER BY ord ASC",
        )
        .map_err(map_sql_err)?;
    let rows = stmt
        .query_map(params![note_id], |row| {
            Ok(CachedBlock {
                block_id: row.get(0)?,
                ord: row.get(1)?,
                block_type: row.get(2)?,
                raw_json: row.get(3)?,
                recreatable: row.get::<_, i64>(4)? != 0,
            })
        })
        .map_err(map_sql_err)?;
    let mut out = Vec::new();
    for r in rows {
        out.push(r.map_err(map_sql_err)?);
    }
    Ok(out)
}

/// Wholesale replacement — the cache always mirrors the last pull, so
/// incremental updates would only create drift.
pub fn replace_blocks(ws: &Workspace, note_id: &str, blocks: &[CachedBlock]) -> AppResult<()> {
    delete_blocks(ws, note_id)?;
    for b in blocks {
        ws.conn
            .execute(
                "INSERT OR REPLACE INTO notion_blocks \
                   (note_id, block_id, ord, block_type, raw_json, recreatable) \
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
                params![
                    note_id,
                    b.block_id,
                    b.ord,
                    b.block_type,
                    b.raw_json,
                    b.recreatable as i64
                ],
            )
            .map_err(map_sql_err)?;
    }
    Ok(())
}

pub fn delete_blocks(ws: &Workspace, note_id: &str) -> AppResult<()> {
    ws.conn
        .execute("DELETE FROM notion_blocks WHERE note_id = ?1", params![note_id])
        .map_err(map_sql_err)?;
    Ok(())
}

// ---------------------------------------------------------------------------
// conflicts
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct NotionConflict {
    pub note_id: String,
    pub page_id: Option<String>,
    /// `both-changed` | `remote-deleted` | `local-deleted`
    pub kind: String,
    pub local_title: Option<String>,
    pub remote_title: Option<String>,
    pub detected_ms: i64,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct NotionConflictDetail {
    #[serde(flatten)]
    pub summary: NotionConflict,
    pub local_content: Option<String>,
    pub remote_content: Option<String>,
}

pub fn upsert_conflict(
    ws: &Workspace,
    note_id: &str,
    page_id: Option<&str>,
    kind: &str,
    local_content: Option<&str>,
    remote_content: Option<&str>,
    local_title: Option<&str>,
    remote_title: Option<&str>,
    detected_ms: i64,
) -> AppResult<()> {
    ws.conn
        .execute(
            "INSERT OR REPLACE INTO notion_conflicts \
               (note_id, page_id, kind, local_content, remote_content, \
                local_title, remote_title, detected_ms) \
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
            params![
                note_id,
                page_id,
                kind,
                local_content,
                remote_content,
                local_title,
                remote_title,
                detected_ms
            ],
        )
        .map_err(map_sql_err)?;
    Ok(())
}

pub fn list_conflicts(ws: &Workspace) -> AppResult<Vec<NotionConflict>> {
    let mut stmt = ws
        .conn
        .prepare(
            "SELECT note_id, page_id, kind, local_title, remote_title, detected_ms \
             FROM notion_conflicts ORDER BY detected_ms DESC",
        )
        .map_err(map_sql_err)?;
    let rows = stmt
        .query_map([], |row| {
            Ok(NotionConflict {
                note_id: row.get(0)?,
                page_id: row.get(1)?,
                kind: row.get(2)?,
                local_title: row.get(3)?,
                remote_title: row.get(4)?,
                detected_ms: row.get(5)?,
            })
        })
        .map_err(map_sql_err)?;
    let mut out = Vec::new();
    for r in rows {
        out.push(r.map_err(map_sql_err)?);
    }
    Ok(out)
}

pub fn count_conflicts(ws: &Workspace) -> AppResult<i64> {
    ws.conn
        .query_row("SELECT COUNT(*) FROM notion_conflicts", [], |row| row.get(0))
        .map_err(map_sql_err)
}

pub fn get_conflict(ws: &Workspace, note_id: &str) -> AppResult<Option<NotionConflictDetail>> {
    ws.conn
        .query_row(
            "SELECT note_id, page_id, kind, local_title, remote_title, detected_ms, \
                    local_content, remote_content \
             FROM notion_conflicts WHERE note_id = ?1",
            params![note_id],
            |row| {
                Ok(NotionConflictDetail {
                    summary: NotionConflict {
                        note_id: row.get(0)?,
                        page_id: row.get(1)?,
                        kind: row.get(2)?,
                        local_title: row.get(3)?,
                        remote_title: row.get(4)?,
                        detected_ms: row.get(5)?,
                    },
                    local_content: row.get(6)?,
                    remote_content: row.get(7)?,
                })
            },
        )
        .optional()
        .map_err(map_sql_err)
}

pub fn delete_conflict(ws: &Workspace, note_id: &str) -> AppResult<()> {
    ws.conn
        .execute(
            "DELETE FROM notion_conflicts WHERE note_id = ?1",
            params![note_id],
        )
        .map_err(map_sql_err)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::workspace::Workspace;

    fn ws() -> (tempfile::TempDir, Workspace) {
        let dir = tempfile::tempdir().unwrap();
        let ws = Workspace::open(dir.path()).unwrap();
        (dir, ws)
    }

    #[test]
    fn open_creates_notion_tables() {
        let (_d, ws) = ws();
        for t in [
            "notion_config",
            "notion_links",
            "notion_blocks",
            "notion_conflicts",
        ] {
            let n: i64 = ws
                .conn
                .query_row(
                    "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name=?1",
                    params![t],
                    |r| r.get(0),
                )
                .unwrap();
            assert_eq!(n, 1, "table {} missing", t);
        }
    }

    #[test]
    fn config_defaults_when_absent() {
        let (_d, ws) = ws();
        let cfg = get_config(&ws).unwrap();
        assert!(!cfg.enabled);
        assert_eq!(cfg.title_prop, "Name");
        assert_eq!(cfg.interval_sec, DEFAULT_INTERVAL_SEC);
        assert!(cfg.credentials().is_err());
    }

    #[test]
    fn set_config_preserves_token_when_omitted() {
        let (_d, ws) = ws();
        set_config(
            &ws,
            &NotionConfigInput {
                token: Some("secret_abcd1234".into()),
                database_id: Some("db1".into()),
                ..Default::default()
            },
        )
        .unwrap();
        let cfg = set_config(
            &ws,
            &NotionConfigInput {
                enabled: Some(true),
                ..Default::default()
            },
        )
        .unwrap();
        assert_eq!(cfg.token.as_deref(), Some("secret_abcd1234"));
        assert!(cfg.enabled);
        let view = cfg.to_view(0);
        assert!(view.token_set);
        assert_eq!(view.token_hint, "1234");
    }

    #[test]
    fn interval_is_clamped() {
        let (_d, ws) = ws();
        let cfg = set_config(
            &ws,
            &NotionConfigInput {
                interval_sec: Some(1),
                ..Default::default()
            },
        )
        .unwrap();
        assert_eq!(cfg.interval_sec, MIN_INTERVAL_SEC);
    }

    #[test]
    fn switching_database_clears_links() {
        let (_d, ws) = ws();
        set_config(
            &ws,
            &NotionConfigInput {
                database_id: Some("db1".into()),
                ..Default::default()
            },
        )
        .unwrap();
        upsert_link(&ws, &Link::new("n1", Some("p1"))).unwrap();
        assert_eq!(list_links(&ws).unwrap().len(), 1);
        set_config(
            &ws,
            &NotionConfigInput {
                database_id: Some("db2".into()),
                ..Default::default()
            },
        )
        .unwrap();
        assert!(list_links(&ws).unwrap().is_empty());
    }

    #[test]
    fn link_roundtrip_and_delete_cascades_blocks() {
        let (_d, ws) = ws();
        let mut link = Link::new("n1", Some("p1"));
        link.base_local_hash = "aaa".into();
        link.push_mode = "blocked".into();
        upsert_link(&ws, &link).unwrap();
        let got = get_link(&ws, "n1").unwrap().unwrap();
        assert_eq!(got, link);
        assert!(got.is_blocked());

        replace_blocks(
            &ws,
            "n1",
            &[CachedBlock {
                block_id: "b1".into(),
                ord: 0,
                block_type: "callout".into(),
                raw_json: "{}".into(),
                recreatable: true,
            }],
        )
        .unwrap();
        assert_eq!(list_blocks(&ws, "n1").unwrap().len(), 1);
        delete_link(&ws, "n1").unwrap();
        assert!(get_link(&ws, "n1").unwrap().is_none());
        assert!(list_blocks(&ws, "n1").unwrap().is_empty());
    }

    #[test]
    fn conflict_crud() {
        let (_d, ws) = ws();
        upsert_conflict(
            &ws,
            "n1",
            Some("p1"),
            "both-changed",
            Some("local"),
            Some("remote"),
            Some("L"),
            Some("R"),
            42,
        )
        .unwrap();
        assert_eq!(count_conflicts(&ws).unwrap(), 1);
        let d = get_conflict(&ws, "n1").unwrap().unwrap();
        assert_eq!(d.summary.kind, "both-changed");
        assert_eq!(d.local_content.as_deref(), Some("local"));
        delete_conflict(&ws, "n1").unwrap();
        assert_eq!(count_conflicts(&ws).unwrap(), 0);
    }
}
