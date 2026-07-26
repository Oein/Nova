//! Notion database <-> workspace two-way sync.
//!
//! Layering, outermost first:
//!   `commands::notion`  Tauri entry points; owns the workspace mutex
//!   `sync`              `classify()` (pure) + `Executor` (async, I/O)
//!   `client`            `NotionApi` trait + reqwest implementation
//!   `md_to_blocks` / `blocks_to_md`   pure converters
//!   `store`             every `notion_*` SQLite table
//!   `model`             the slice of Notion's JSON we care about
//!
//! Two invariants hold the design together:
//!
//! 1. **`classify()` never does I/O.** Every merge decision is a pure function
//!    of (local hash, remote timestamp/hash, baseline), so the state machine is
//!    exhaustively table-testable without a network or a database.
//!
//! 2. **The baseline is content-addressed, not time-addressed.** Notion's
//!    `last_edited_time` has second granularity and bumps on our own writes, so
//!    it can only answer "might this have changed?". `base_remote_hash` over
//!    the rendered markdown answers "did it actually change?".

pub mod blocks_to_md;
pub mod client;
#[cfg(test)]
pub mod fake;
pub mod md_to_blocks;
pub mod model;
pub mod store;
pub mod sync;

use serde::{Deserialize, Serialize};

/// What the frontend is allowed to know about the stored config. Deliberately
/// has no `token` field — the PAT never crosses the IPC boundary once saved.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NotionConfigView {
    pub token_set: bool,
    /// Last 4 chars of the PAT, so the user can tell which token is stored.
    pub token_hint: String,
    pub database_id: Option<String>,
    pub database_title: Option<String>,
    pub title_prop: String,
    pub created_prop: Option<String>,
    pub updated_prop: Option<String>,
    pub id_prop: Option<String>,
    pub enabled: bool,
    pub sync_on_start: bool,
    pub auto_sync: bool,
    pub interval_sec: i64,
    pub last_sync_ms: Option<i64>,
    pub last_status: Option<String>,
    pub conflict_count: i64,
}

/// Partial update. `None` on any field means "leave as-is" — in particular
/// `token: None` keeps the stored PAT, which is how the settings UI can save
/// other fields without ever reading the secret back.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NotionConfigInput {
    pub token: Option<String>,
    pub database_id: Option<String>,
    pub database_title: Option<String>,
    /// Empty string clears the setting; `None` leaves it alone.
    pub created_prop: Option<String>,
    pub updated_prop: Option<String>,
    pub id_prop: Option<String>,
    pub enabled: Option<bool>,
    pub sync_on_start: Option<bool>,
    pub auto_sync: Option<bool>,
    pub interval_sec: Option<i64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NotionDbSummary {
    pub id: String,
    pub title: String,
    pub url: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct NotionConnectionInfo {
    pub bot_name: String,
    pub workspace_name: Option<String>,
    pub database_title: Option<String>,
    pub title_prop: Option<String>,
    pub page_count: Option<i64>,
    /// Configured timestamp columns that are missing from the database, or
    /// exist with a type other than `date`. Surfaced so the settings UI can
    /// explain what will happen before the first sync.
    pub property_warnings: Vec<String>,
}

/// One line of the post-sync summary. `kind` drives the icon; `severity`
/// drives the colour and whether the user needs to act.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SyncReportItem {
    pub note_id: Option<String>,
    pub page_id: Option<String>,
    pub title: String,
    /// `pulled` | `pushed` | `created-local` | `created-remote` |
    /// `archived-remote` | `trashed-local` | `conflict` | `blocked` | `error`
    pub kind: String,
    /// `info` | `warn` | `error`
    pub severity: String,
    pub message: Option<String>,
}

#[derive(Debug, Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SyncReport {
    pub pulled: i64,
    pub pushed: i64,
    pub created_local: i64,
    pub created_remote: i64,
    pub archived_remote: i64,
    pub trashed_local: i64,
    pub conflicts: i64,
    pub blocked: i64,
    pub errors: i64,
    pub cancelled: bool,
    pub dry_run: bool,
    pub items: Vec<SyncReportItem>,
    /// Notes whose on-disk content changed, so the UI knows what to reload.
    pub changed_note_ids: Vec<String>,
}

impl SyncReport {
    pub fn push_item(&mut self, item: SyncReportItem) {
        match item.kind.as_str() {
            "pulled" => self.pulled += 1,
            "pushed" => self.pushed += 1,
            "created-local" => self.created_local += 1,
            "created-remote" => self.created_remote += 1,
            "archived-remote" => self.archived_remote += 1,
            "trashed-local" => self.trashed_local += 1,
            "conflict" => self.conflicts += 1,
            "blocked" => self.blocked += 1,
            "error" => self.errors += 1,
            _ => {}
        }
        self.items.push(item);
    }
}

pub fn sha256_hex(s: &str) -> String {
    use sha2::{Digest, Sha256};
    let mut hasher = Sha256::new();
    hasher.update(s.as_bytes());
    format!("{:x}", hasher.finalize())
}

pub fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}
