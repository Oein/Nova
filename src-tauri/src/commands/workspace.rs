use std::path::PathBuf;

use tauri::AppHandle;
use tauri_plugin_dialog::DialogExt;

use crate::error::{AppError, AppResult};
use crate::fs_util::mtime_ms;
use crate::state::AppState;
use crate::workspace::{self, Note, Session, SessionTab, Workspace};

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

pub fn first_line_title(content: &str, fallback: &str) -> String {
    let first = content.lines().next().unwrap_or("");
    let trimmed = first.trim_start_matches('#').trim();
    if trimmed.is_empty() {
        fallback.to_string()
    } else {
        trimmed.chars().take(120).collect()
    }
}

const TRASH_RETENTION_MS: i64 = 30 * 24 * 60 * 60 * 1000;

pub fn open_workspace_impl(root: PathBuf) -> AppResult<(Workspace, Vec<Note>, Session)> {
    let ws = Workspace::open(&root)?;
    let cutoff = now_ms().saturating_sub(TRASH_RETENTION_MS);
    let _ = workspace::purge_old_trash(&ws, cutoff);
    let notes = workspace::list_notes(&ws)?;
    let session = workspace::load_session(&ws)?;
    Ok((ws, notes, session))
}

#[tauri::command]
pub async fn open_workspace(
    state: tauri::State<'_, AppState>,
    path: String,
) -> Result<OpenWorkspaceResult, AppError> {
    let root = PathBuf::from(&path);
    let (ws, notes, session) = open_workspace_impl(root.clone())?;
    *state.workspace.lock().unwrap() = Some(ws);
    Ok(OpenWorkspaceResult {
        root: root.to_string_lossy().to_string(),
        notes,
        session,
    })
}

#[derive(serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct OpenWorkspaceResult {
    pub root: String,
    pub notes: Vec<Note>,
    pub session: Session,
}

#[tauri::command]
pub async fn pick_workspace(app: AppHandle) -> Result<Option<String>, AppError> {
    let (tx, rx) = std::sync::mpsc::channel();
    app.dialog()
        .file()
        .pick_folder(move |folder| {
            let _ = tx.send(folder);
        });
    let picked = rx.recv().map_err(|e| AppError::Other(e.to_string()))?;
    Ok(picked.map(|p| p.to_string()))
}

#[tauri::command]
pub async fn list_notes(state: tauri::State<'_, AppState>) -> Result<Vec<Note>, AppError> {
    let guard = state.workspace.lock().unwrap();
    let ws = guard.as_ref().ok_or_else(|| AppError::Other("no workspace open".into()))?;
    workspace::list_notes(ws)
}

#[tauri::command]
pub async fn create_note(state: tauri::State<'_, AppState>) -> Result<Note, AppError> {
    let guard = state.workspace.lock().unwrap();
    let ws = guard.as_ref().ok_or_else(|| AppError::Other("no workspace open".into()))?;
    let id = uuid::Uuid::new_v4().to_string();
    let title = "Untitled".to_string();
    // Insert DB row first so `ws.note_path` resolves to the new slug-based
    // filename (not the fallback `{id}.md`) when we create the file.
    let now = now_ms();
    let note_in = Note {
        id: id.clone(),
        title: title.clone(),
        created_ms: now,
        mtime_ms: now,
        size: 0,
    };
    workspace::insert_note(ws, &note_in, "")?;
    let file_path = ws.note_path(&id);
    std::fs::write(&file_path, "")?;
    let meta = std::fs::metadata(&file_path)?;
    let real_mtime = mtime_ms(&meta);
    ws.conn
        .execute(
            "UPDATE notes SET created_ms = ?1, mtime_ms = ?2 WHERE id = ?3",
            rusqlite::params![real_mtime, real_mtime, &id],
        )
        .map_err(|e| AppError::Other(format!("sqlite: {}", e)))?;
    Ok(Note {
        id,
        title,
        created_ms: real_mtime,
        mtime_ms: real_mtime,
        size: 0,
    })
}

#[tauri::command]
pub async fn read_note(
    state: tauri::State<'_, AppState>,
    id: String,
) -> Result<NoteContent, AppError> {
    let guard = state.workspace.lock().unwrap();
    let ws = guard.as_ref().ok_or_else(|| AppError::Other("no workspace open".into()))?;
    let path = ws.note_path(&id);
    let bytes = std::fs::read(&path)?;
    let content = String::from_utf8(bytes).map_err(|_| AppError::InvalidUtf8 { offset: 0 })?;
    let meta = std::fs::metadata(&path)?;
    Ok(NoteContent {
        id,
        content,
        mtime_ms: mtime_ms(&meta),
        size: meta.len() as i64,
    })
}

#[derive(serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct NoteContent {
    pub id: String,
    pub content: String,
    pub mtime_ms: i64,
    pub size: i64,
}

#[tauri::command]
pub async fn write_note(
    state: tauri::State<'_, AppState>,
    id: String,
    content: String,
    expected_mtime_ms: Option<i64>,
) -> Result<Note, AppError> {
    let guard = state.workspace.lock().unwrap();
    let ws = guard.as_ref().ok_or_else(|| AppError::Other("no workspace open".into()))?;
    let path = ws.note_path(&id);
    if let Ok(meta) = std::fs::metadata(&path) {
        if let Some(exp) = expected_mtime_ms {
            let disk = mtime_ms(&meta);
            if disk != exp {
                return Err(AppError::MtimeMismatch {
                    disk,
                    expected: exp,
                });
            }
        }
    }
    std::fs::write(&path, &content)?;
    let title = first_line_title(&content, "Untitled");
    // Rename the file when the title changed so the on-disk name keeps up.
    // The returned path points to the (possibly new) location — stat THAT
    // to get the mtime the frontend will treat as the save baseline.
    let final_path = workspace::rename_note_file_if_title_changed(ws, &id, &title)?;
    let meta = std::fs::metadata(&final_path)?;
    let mtime = mtime_ms(&meta);
    let size = meta.len() as i64;
    workspace::update_note_meta(ws, &id, &title, mtime, size, &content)?;
    Ok(Note {
        id,
        title,
        created_ms: 0,
        mtime_ms: mtime,
        size,
    })
}

#[tauri::command]
pub async fn delete_note(
    state: tauri::State<'_, AppState>,
    id: String,
) -> Result<(), AppError> {
    let guard = state.workspace.lock().unwrap();
    let ws = guard.as_ref().ok_or_else(|| AppError::Other("no workspace open".into()))?;
    // Soft-delete: hide from list + disconnect from session. Backing file
    // stays on disk until purge_old_trash reaps it past the 30-day window.
    workspace::trash_note(ws, &id, now_ms())?;
    Ok(())
}

/// Hard-delete a note: remove DB row, FTS entry, session tab, and the
/// backing file outright — bypassing trash. Used by the frontend when a
/// newly-created note is closed without ever being saved (the user never
/// committed it, so there's nothing to preserve).
#[tauri::command]
pub async fn hard_delete_note(
    state: tauri::State<'_, AppState>,
    id: String,
) -> Result<(), AppError> {
    let guard = state.workspace.lock().unwrap();
    let ws = guard.as_ref().ok_or_else(|| AppError::Other("no workspace open".into()))?;
    workspace::hard_delete_note(ws, &id)?;
    Ok(())
}

#[tauri::command]
pub async fn list_trashed_notes(
    state: tauri::State<'_, AppState>,
) -> Result<Vec<workspace::TrashedNote>, AppError> {
    let guard = state.workspace.lock().unwrap();
    let ws = guard.as_ref().ok_or_else(|| AppError::Other("no workspace open".into()))?;
    workspace::list_trashed_notes(ws)
}

#[tauri::command]
pub async fn restore_note(
    state: tauri::State<'_, AppState>,
    id: String,
) -> Result<Note, AppError> {
    let guard = state.workspace.lock().unwrap();
    let ws = guard.as_ref().ok_or_else(|| AppError::Other("no workspace open".into()))?;
    workspace::restore_note(ws, &id, now_ms())?;
    workspace::get_note(ws, &id)
}

#[tauri::command]
pub async fn search_notes(
    state: tauri::State<'_, AppState>,
    query: String,
    limit: Option<i64>,
) -> Result<Vec<workspace::SearchHit>, AppError> {
    let guard = state.workspace.lock().unwrap();
    let ws = guard.as_ref().ok_or_else(|| AppError::Other("no workspace open".into()))?;
    workspace::search_notes(ws, &query, limit.unwrap_or(30))
}

#[tauri::command]
pub async fn purge_trashed_note(
    state: tauri::State<'_, AppState>,
    id: String,
) -> Result<(), AppError> {
    let guard = state.workspace.lock().unwrap();
    let ws = guard.as_ref().ok_or_else(|| AppError::Other("no workspace open".into()))?;
    let _ = std::fs::remove_file(ws.note_path(&id));
    workspace::hard_delete_note(ws, &id)?;
    Ok(())
}

/// Reveal a note's backing file in the host OS's file manager. On macOS
/// this is `open -R <path>` which highlights the file inside Finder; on
/// other platforms we just open the containing folder.
#[tauri::command]
pub async fn reveal_note(
    state: tauri::State<'_, AppState>,
    id: String,
) -> Result<(), AppError> {
    let path = {
        let guard = state.workspace.lock().unwrap();
        let ws = guard.as_ref().ok_or_else(|| AppError::Other("no workspace open".into()))?;
        ws.note_path(&id)
    };
    if !path.exists() {
        return Err(AppError::Other(format!(
            "note {} is not on disk",
            path.display()
        )));
    }
    #[cfg(target_os = "macos")]
    {
        std::process::Command::new("open")
            .arg("-R")
            .arg(&path)
            .spawn()
            .map_err(AppError::Io)?;
    }
    #[cfg(target_os = "windows")]
    {
        std::process::Command::new("explorer")
            .arg(format!("/select,{}", path.display()))
            .spawn()
            .map_err(AppError::Io)?;
    }
    #[cfg(all(not(target_os = "macos"), not(target_os = "windows")))]
    {
        if let Some(parent) = path.parent() {
            std::process::Command::new("xdg-open")
                .arg(parent)
                .spawn()
                .map_err(AppError::Io)?;
        }
    }
    Ok(())
}

#[tauri::command]
pub async fn get_session(state: tauri::State<'_, AppState>) -> Result<Session, AppError> {
    let guard = state.workspace.lock().unwrap();
    let ws = guard.as_ref().ok_or_else(|| AppError::Other("no workspace open".into()))?;
    workspace::load_session(ws)
}

#[tauri::command]
pub async fn save_tab_state(
    state: tauri::State<'_, AppState>,
    tab: SessionTab,
) -> Result<(), AppError> {
    let guard = state.workspace.lock().unwrap();
    let ws = guard.as_ref().ok_or_else(|| AppError::Other("no workspace open".into()))?;
    workspace::save_tab(ws, &tab)
}

#[tauri::command]
pub async fn set_active_tab(
    state: tauri::State<'_, AppState>,
    active: Option<String>,
) -> Result<(), AppError> {
    let guard = state.workspace.lock().unwrap();
    let ws = guard.as_ref().ok_or_else(|| AppError::Other("no workspace open".into()))?;
    workspace::set_active_tab(ws, active.as_deref())
}

#[tauri::command]
pub async fn remove_tab_state(
    state: tauri::State<'_, AppState>,
    id: String,
) -> Result<(), AppError> {
    let guard = state.workspace.lock().unwrap();
    let ws = guard.as_ref().ok_or_else(|| AppError::Other("no workspace open".into()))?;
    workspace::remove_tab(ws, &id)
}

#[tauri::command]
pub async fn save_session(
    state: tauri::State<'_, AppState>,
    session: Session,
) -> Result<(), AppError> {
    let mut guard = state.workspace.lock().unwrap();
    let ws = guard.as_mut().ok_or_else(|| AppError::Other("no workspace open".into()))?;
    workspace::save_session(ws, &session)
}

// unused but keep; might be handy
pub fn _touch(_x: i64) -> i64 {
    now_ms()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn title_from_first_line() {
        assert_eq!(first_line_title("# Hello\nbody", "X"), "Hello");
        assert_eq!(first_line_title("plain line\nmore", "X"), "plain line");
        assert_eq!(first_line_title("", "Fallback"), "Fallback");
        assert_eq!(first_line_title("   ", "Fallback"), "Fallback");
        assert_eq!(first_line_title("###   spaced   \n", "X"), "spaced");
    }

    #[test]
    fn title_truncates_very_long_first_line() {
        let long = "a".repeat(500);
        assert_eq!(first_line_title(&long, "X").len(), 120);
    }
}
