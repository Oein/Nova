use std::path::{Path, PathBuf};
use std::sync::mpsc::channel;
use std::time::Duration;

use notify::event::{ModifyKind, RenameMode};
use notify::{EventKind, RecursiveMode, Watcher};
use notify_debouncer_full::{new_debouncer, DebouncedEvent, Debouncer, FileIdMap};
use serde::Serialize;
use tauri::{AppHandle, Emitter};

use crate::error::{AppError, AppResult};
use crate::fs_util::mtime_ms;
use crate::state::AppState;

#[derive(Debug, Serialize, Clone)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum FsEvent {
    #[serde(rename_all = "camelCase")]
    Modified {
        path: String,
        mtime_ms: i64,
        size: u64,
    },
    #[serde(rename_all = "camelCase")]
    Created {
        path: String,
        mtime_ms: i64,
        size: u64,
    },
    #[serde(rename_all = "camelCase")]
    Removed { path: String },
    #[serde(rename_all = "camelCase")]
    Renamed {
        from: String,
        to: String,
        mtime_ms: i64,
        size: u64,
    },
}

pub type EventSink = Box<dyn Fn(FsEvent) + Send + Sync>;

pub struct WatcherHandle {
    _debouncer: Debouncer<notify::RecommendedWatcher, FileIdMap>,
    _thread: std::thread::JoinHandle<()>,
}

pub fn start_watching_impl(
    root: &Path,
    sink: EventSink,
) -> AppResult<WatcherHandle> {
    let root = std::fs::canonicalize(root).unwrap_or_else(|_| root.to_path_buf());
    let (tx, rx) = channel::<Result<Vec<DebouncedEvent>, Vec<notify::Error>>>();
    let mut debouncer =
        new_debouncer(Duration::from_millis(250), None, move |res| {
            let _ = tx.send(res);
        })
        .map_err(|e| AppError::Other(e.to_string()))?;
    debouncer
        .watcher()
        .watch(&root, RecursiveMode::NonRecursive)
        .map_err(|e| AppError::Other(e.to_string()))?;
    let root_owned = root.clone();
    let thread = std::thread::spawn(move || {
        while let Ok(res) = rx.recv() {
            let events = match res {
                Ok(evts) => evts,
                Err(_) => continue,
            };
            let mut pending_rename: Option<PathBuf> = None;
            for ev in events {
                if std::env::var_os("WATCHER_DEBUG").is_some() {
                    eprintln!("[watcher] kind={:?} paths={:?}", ev.event.kind, ev.paths);
                }
                let classified = classify(&ev.event, &ev.paths, &root_owned, &mut pending_rename);
                for fs_ev in classified {
                    sink(fs_ev);
                }
            }
        }
    });
    Ok(WatcherHandle {
        _debouncer: debouncer,
        _thread: thread,
    })
}

fn classify(
    kind: &notify::Event,
    paths: &[PathBuf],
    root: &Path,
    pending_rename: &mut Option<PathBuf>,
) -> Vec<FsEvent> {
    let mut out = Vec::new();
    match kind.kind {
        EventKind::Create(_) => {
            for p in paths {
                if !is_root_file(p, root) {
                    continue;
                }
                if let Ok(meta) = std::fs::metadata(p) {
                    if meta.is_file() {
                        out.push(FsEvent::Created {
                            path: p.to_string_lossy().to_string(),
                            mtime_ms: mtime_ms(&meta),
                            size: meta.len(),
                        });
                    }
                }
            }
        }
        EventKind::Modify(ModifyKind::Name(RenameMode::From)) => {
            if let Some(p) = paths.first() {
                *pending_rename = Some(p.clone());
            }
        }
        EventKind::Modify(ModifyKind::Name(RenameMode::To)) => {
            if let Some(to) = paths.first() {
                if let Some(from) = pending_rename.take() {
                    let meta = std::fs::metadata(to).ok();
                    out.push(FsEvent::Renamed {
                        from: from.to_string_lossy().to_string(),
                        to: to.to_string_lossy().to_string(),
                        mtime_ms: meta.as_ref().map(mtime_ms).unwrap_or(0),
                        size: meta.as_ref().map(|m| m.len()).unwrap_or(0),
                    });
                } else if let Ok(meta) = std::fs::metadata(to) {
                    out.push(FsEvent::Created {
                        path: to.to_string_lossy().to_string(),
                        mtime_ms: mtime_ms(&meta),
                        size: meta.len(),
                    });
                }
            }
        }
        EventKind::Modify(ModifyKind::Name(RenameMode::Both)) => {
            if paths.len() >= 2 {
                let from = &paths[0];
                let to = &paths[1];
                let meta = std::fs::metadata(to).ok();
                out.push(FsEvent::Renamed {
                    from: from.to_string_lossy().to_string(),
                    to: to.to_string_lossy().to_string(),
                    mtime_ms: meta.as_ref().map(mtime_ms).unwrap_or(0),
                    size: meta.as_ref().map(|m| m.len()).unwrap_or(0),
                });
            }
        }
        EventKind::Modify(_) => {
            for p in paths {
                if !is_root_file(p, root) {
                    continue;
                }
                match std::fs::metadata(p) {
                    Ok(meta) if meta.is_file() => {
                        out.push(FsEvent::Modified {
                            path: p.to_string_lossy().to_string(),
                            mtime_ms: mtime_ms(&meta),
                            size: meta.len(),
                        });
                    }
                    Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                        out.push(FsEvent::Removed {
                            path: p.to_string_lossy().to_string(),
                        });
                    }
                    _ => {}
                }
            }
        }
        EventKind::Remove(_) => {
            for p in paths {
                if is_root_file(p, root) {
                    out.push(FsEvent::Removed {
                        path: p.to_string_lossy().to_string(),
                    });
                }
            }
        }
        _ => {}
    }
    out
}

fn is_root_file(p: &Path, root: &Path) -> bool {
    let parent = match p.parent() {
        Some(x) => x,
        None => return false,
    };
    parent == root
        || std::fs::canonicalize(parent)
            .map(|c| c == *root)
            .unwrap_or(false)
}

#[tauri::command]
pub async fn start_watching(
    app: AppHandle,
    state: tauri::State<'_, AppState>,
    path: String,
) -> Result<(), AppError> {
    let root = PathBuf::from(&path);
    let app_handle = app.clone();
    let sink: EventSink = Box::new(move |ev| {
        let _ = app_handle.emit("fs:change", &ev);
    });
    let handle = start_watching_impl(&root, sink)?;
    state
        .watchers
        .lock()
        .unwrap()
        .insert(root, handle);
    Ok(())
}

#[tauri::command]
pub async fn stop_watching(
    state: tauri::State<'_, AppState>,
    path: String,
) -> Result<(), AppError> {
    let root = PathBuf::from(path);
    state.watchers.lock().unwrap().remove(&root);
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Arc, Mutex};
    use std::time::Instant;
    use tempfile::tempdir;

    fn wait_for<F: Fn() -> bool>(pred: F, timeout: Duration) -> bool {
        let start = Instant::now();
        while start.elapsed() < timeout {
            if pred() {
                return true;
            }
            std::thread::sleep(Duration::from_millis(50));
        }
        false
    }

    #[test]
    fn watcher_detects_create_and_modify() {
        let dir = tempdir().unwrap();
        let events: Arc<Mutex<Vec<FsEvent>>> = Arc::new(Mutex::new(Vec::new()));
        let events_clone = events.clone();
        let _handle = start_watching_impl(
            dir.path(),
            Box::new(move |ev| events_clone.lock().unwrap().push(ev)),
        )
        .unwrap();
        // Give the watcher a moment to attach
        std::thread::sleep(Duration::from_millis(500));

        let p = dir.path().join("new.txt");
        std::fs::write(&p, b"hello").unwrap();

        assert!(
            wait_for(
                || events
                    .lock()
                    .unwrap()
                    .iter()
                    .any(|e| matches!(e, FsEvent::Created { .. })),
                Duration::from_secs(3),
            ),
            "expected Created event, got: {:?}",
            events.lock().unwrap()
        );

        events.lock().unwrap().clear();
        std::fs::write(&p, b"updated contents").unwrap();

        assert!(
            wait_for(
                || events
                    .lock()
                    .unwrap()
                    .iter()
                    .any(|e| matches!(e, FsEvent::Modified { .. } | FsEvent::Created { .. })),
                Duration::from_secs(3),
            ),
            "expected Modified event, got: {:?}",
            events.lock().unwrap()
        );
    }

    #[test]
    fn watcher_detects_remove() {
        let dir = tempdir().unwrap();
        let p = dir.path().join("victim.txt");
        std::fs::write(&p, b"bye").unwrap();
        std::thread::sleep(Duration::from_millis(50));

        let events: Arc<Mutex<Vec<FsEvent>>> = Arc::new(Mutex::new(Vec::new()));
        let events_clone = events.clone();
        let _handle = start_watching_impl(
            dir.path(),
            Box::new(move |ev| events_clone.lock().unwrap().push(ev)),
        )
        .unwrap();
        std::thread::sleep(Duration::from_millis(500));
        std::fs::remove_file(&p).unwrap();

        assert!(
            wait_for(
                || events
                    .lock()
                    .unwrap()
                    .iter()
                    .any(|e| matches!(e, FsEvent::Removed { .. })),
                Duration::from_secs(3),
            ),
            "expected Removed event, got: {:?}",
            events.lock().unwrap()
        );
    }
}
