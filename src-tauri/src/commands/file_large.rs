use std::path::{Path, PathBuf};
use std::sync::Arc;

use serde::{Deserialize, Serialize};

use crate::error::{AppError, AppResult};
use crate::line_index::LineIndex;
use crate::state::AppState;

#[derive(Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LargeFileHandle {
    pub path: String,
    pub size: u64,
    pub mtime_ms: i64,
    pub line_count: u64,
}

pub fn open_large_file_impl(
    state: &AppState,
    path: &Path,
) -> AppResult<LargeFileHandle> {
    let idx = Arc::new(LineIndex::open(path)?);
    let handle = LargeFileHandle {
        path: path.to_string_lossy().to_string(),
        size: idx.size,
        mtime_ms: idx.mtime_ms,
        line_count: idx.line_count,
    };
    state
        .large_files
        .lock()
        .unwrap()
        .insert(path.to_path_buf(), idx);
    Ok(handle)
}

pub fn read_line_range_impl(
    state: &AppState,
    path: &Path,
    start_line: u64,
    end_line: u64,
) -> AppResult<String> {
    let idx = {
        let map = state.large_files.lock().unwrap();
        map.get(path)
            .cloned()
            .ok_or_else(|| AppError::NoLargeFile(path.display().to_string()))?
    };
    idx.line_range_text(start_line, end_line)
}

pub fn read_byte_range_impl(
    state: &AppState,
    path: &Path,
    offset: u64,
    len: u64,
) -> AppResult<Vec<u8>> {
    let idx = {
        let map = state.large_files.lock().unwrap();
        map.get(path)
            .cloned()
            .ok_or_else(|| AppError::NoLargeFile(path.display().to_string()))?
    };
    Ok(idx.byte_range(offset, len)?.to_vec())
}

pub fn close_large_file_impl(state: &AppState, path: &Path) {
    state.large_files.lock().unwrap().remove(path);
}

#[tauri::command]
pub async fn open_large_file(
    state: tauri::State<'_, AppState>,
    path: String,
) -> Result<LargeFileHandle, AppError> {
    let p = PathBuf::from(path);
    let state = state.inner();
    let result = tokio::task::block_in_place(|| open_large_file_impl(state, &p));
    result
}

#[tauri::command]
pub async fn read_line_range(
    state: tauri::State<'_, AppState>,
    path: String,
    start_line: u64,
    end_line: u64,
) -> Result<String, AppError> {
    let p = PathBuf::from(path);
    let state = state.inner();
    tokio::task::block_in_place(|| read_line_range_impl(state, &p, start_line, end_line))
}

#[tauri::command]
pub async fn read_byte_range(
    state: tauri::State<'_, AppState>,
    path: String,
    offset: u64,
    len: u64,
) -> Result<Vec<u8>, AppError> {
    let p = PathBuf::from(path);
    let state = state.inner();
    tokio::task::block_in_place(|| read_byte_range_impl(state, &p, offset, len))
}

#[tauri::command]
pub async fn close_large_file(
    state: tauri::State<'_, AppState>,
    path: String,
) -> Result<(), AppError> {
    let p = PathBuf::from(path);
    close_large_file_impl(state.inner(), &p);
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use tempfile::tempdir;

    #[test]
    fn open_read_close_cycle() {
        let dir = tempdir().unwrap();
        let p = dir.path().join("big.txt");
        let content: String = (0..1000).map(|i| format!("line {}\n", i)).collect();
        fs::write(&p, &content).unwrap();
        let state = AppState::new();
        let handle = open_large_file_impl(&state, &p).unwrap();
        assert_eq!(handle.line_count, 1000);
        let text = read_line_range_impl(&state, &p, 500, 503).unwrap();
        assert_eq!(text, "line 500\nline 501\nline 502");
        let bytes = read_byte_range_impl(&state, &p, 0, 7).unwrap();
        assert_eq!(&bytes, b"line 0\n");
        close_large_file_impl(&state, &p);
        let err = read_line_range_impl(&state, &p, 0, 1).unwrap_err();
        assert!(matches!(err, AppError::NoLargeFile(_)));
    }
}
