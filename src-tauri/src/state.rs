use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::atomic::AtomicBool;
use std::sync::{Arc, Mutex};

use crate::line_index::LineIndex;
use crate::workspace::Workspace;

#[derive(Default)]
pub struct AppState {
    pub large_files: Mutex<HashMap<PathBuf, Arc<LineIndex>>>,
    pub watchers: Mutex<HashMap<PathBuf, crate::commands::watcher::WatcherHandle>>,
    pub workspace: Mutex<Option<Workspace>>,
    /// Set while a Notion sync is in flight. Compare-and-swapped so a second
    /// trigger (timer firing while the user clicked "Sync now") bails out with
    /// `AppError::SyncBusy` instead of running two syncs over the same DB.
    pub notion_running: Arc<AtomicBool>,
    /// Cooperative cancellation — checked between sync tasks.
    pub notion_cancel: Arc<AtomicBool>,
    /// Shared connection pool for Notion HTTP calls. The PAT is *not* baked
    /// into the client (it changes with the workspace); it goes on each
    /// request as an Authorization header.
    pub http: once_cell::sync::OnceCell<reqwest::Client>,
}

impl AppState {
    pub fn new() -> Self {
        Self::default()
    }
}
