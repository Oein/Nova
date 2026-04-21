use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::commands::folder::FileEntry;
use crate::error::{AppError, AppResult};
use crate::fs_util::mtime_ms;

pub const SMALL_FILE_LIMIT: u64 = 16 * 1024 * 1024;

#[derive(Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FileRead {
    pub content: String,
    pub entry: FileEntry,
}

pub fn read_file_impl(path: &Path) -> AppResult<FileRead> {
    let meta = std::fs::metadata(path)?;
    if !meta.is_file() {
        return Err(AppError::NotAFile(path.display().to_string()));
    }
    if meta.len() > SMALL_FILE_LIMIT {
        return Err(AppError::FileTooLarge {
            size: meta.len(),
            limit: SMALL_FILE_LIMIT,
        });
    }
    let bytes = std::fs::read(path)?;
    let content = String::from_utf8(bytes).map_err(|e| AppError::InvalidUtf8 {
        offset: e.utf8_error().valid_up_to() as u64,
    })?;
    let name = path
        .file_name()
        .map(|s| s.to_string_lossy().to_string())
        .unwrap_or_default();
    let entry = FileEntry {
        path: path.to_string_lossy().to_string(),
        name,
        size: meta.len(),
        mtime_ms: mtime_ms(&meta),
    };
    Ok(FileRead { content, entry })
}

pub fn write_file_impl(
    path: &Path,
    content: &str,
    expected_mtime_ms: Option<i64>,
) -> AppResult<FileEntry> {
    if let Some(expected) = expected_mtime_ms {
        if let Ok(meta) = std::fs::metadata(path) {
            let disk = mtime_ms(&meta);
            if disk != 0 && expected != 0 && disk != expected {
                return Err(AppError::MtimeMismatch { disk, expected });
            }
        }
    }
    std::fs::write(path, content)?;
    let meta = std::fs::metadata(path)?;
    let name = path
        .file_name()
        .map(|s| s.to_string_lossy().to_string())
        .unwrap_or_default();
    Ok(FileEntry {
        path: path.to_string_lossy().to_string(),
        name,
        size: meta.len(),
        mtime_ms: mtime_ms(&meta),
    })
}

#[tauri::command]
pub async fn read_file(path: String) -> Result<FileRead, AppError> {
    let p = PathBuf::from(path);
    tokio::task::spawn_blocking(move || read_file_impl(&p))
        .await
        .map_err(|e| AppError::Other(e.to_string()))?
}

#[tauri::command]
pub async fn write_file(
    path: String,
    content: String,
    expected_mtime_ms: Option<i64>,
) -> Result<FileEntry, AppError> {
    let p = PathBuf::from(path);
    tokio::task::spawn_blocking(move || write_file_impl(&p, &content, expected_mtime_ms))
        .await
        .map_err(|e| AppError::Other(e.to_string()))?
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use tempfile::tempdir;

    #[test]
    fn round_trip() {
        let dir = tempdir().unwrap();
        let p = dir.path().join("x.txt");
        fs::write(&p, "initial").unwrap();
        let read = read_file_impl(&p).unwrap();
        assert_eq!(read.content, "initial");
        let meta = write_file_impl(&p, "updated!", None).unwrap();
        assert_eq!(meta.size, 8);
        let read2 = read_file_impl(&p).unwrap();
        assert_eq!(read2.content, "updated!");
    }

    #[test]
    fn rejects_oversize() {
        let dir = tempdir().unwrap();
        let p = dir.path().join("big.bin");
        let big = vec![b'a'; (SMALL_FILE_LIMIT as usize) + 1];
        fs::write(&p, &big).unwrap();
        let err = read_file_impl(&p).unwrap_err();
        assert!(matches!(err, AppError::FileTooLarge { .. }));
    }

    #[test]
    fn mtime_mismatch_detected() {
        let dir = tempdir().unwrap();
        let p = dir.path().join("x.txt");
        fs::write(&p, "one").unwrap();
        let m1 = read_file_impl(&p).unwrap().entry.mtime_ms;
        std::thread::sleep(std::time::Duration::from_millis(20));
        fs::write(&p, "two").unwrap();
        let err = write_file_impl(&p, "three", Some(m1)).unwrap_err();
        assert!(matches!(err, AppError::MtimeMismatch { .. }));
    }

    #[test]
    fn mtime_none_allows_overwrite() {
        let dir = tempdir().unwrap();
        let p = dir.path().join("x.txt");
        fs::write(&p, "one").unwrap();
        let updated = write_file_impl(&p, "two", None).unwrap();
        assert_eq!(updated.size, 3);
    }
}
