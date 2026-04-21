use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use crate::line_index::LineIndex;
use crate::workspace::Workspace;

#[derive(Default)]
pub struct AppState {
    pub large_files: Mutex<HashMap<PathBuf, Arc<LineIndex>>>,
    pub watchers: Mutex<HashMap<PathBuf, crate::commands::watcher::WatcherHandle>>,
    pub workspace: Mutex<Option<Workspace>>,
}

impl AppState {
    pub fn new() -> Self {
        Self::default()
    }
}
