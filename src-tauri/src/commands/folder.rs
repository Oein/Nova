use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::error::{AppError, AppResult};
use crate::fs_util::mtime_ms;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct FileEntry {
    pub path: String,
    pub name: String,
    pub size: u64,
    pub mtime_ms: i64,
}

pub fn open_folder_impl(path: &Path) -> AppResult<Vec<FileEntry>> {
    let mut out = Vec::new();
    let rd = std::fs::read_dir(path)?;
    for entry in rd {
        let entry = entry?;
        let meta = match entry.metadata() {
            Ok(m) => m,
            Err(_) => continue,
        };
        if !meta.is_file() {
            continue;
        }
        let name = entry.file_name().to_string_lossy().to_string();
        if name.starts_with('.') {
            continue;
        }
        let full = entry.path();
        out.push(FileEntry {
            path: full.to_string_lossy().to_string(),
            name,
            size: meta.len(),
            mtime_ms: mtime_ms(&meta),
        });
    }
    Ok(out)
}

pub fn get_metadata_impl(path: &Path) -> AppResult<FileEntry> {
    let meta = std::fs::metadata(path)?;
    if !meta.is_file() {
        return Err(AppError::NotAFile(path.display().to_string()));
    }
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
pub async fn open_folder(path: String) -> Result<Vec<FileEntry>, AppError> {
    let p = PathBuf::from(path);
    tokio::task::spawn_blocking(move || open_folder_impl(&p))
        .await
        .map_err(|e| AppError::Other(e.to_string()))?
}

#[tauri::command]
pub async fn get_metadata(path: String) -> Result<FileEntry, AppError> {
    let p = PathBuf::from(path);
    tokio::task::spawn_blocking(move || get_metadata_impl(&p))
        .await
        .map_err(|e| AppError::Other(e.to_string()))?
}

#[tauri::command]
pub async fn pick_folder(app: tauri::AppHandle) -> Result<Option<String>, AppError> {
    use tauri_plugin_dialog::DialogExt;
    let (tx, rx) = tokio::sync::oneshot::channel();
    app.dialog().file().pick_folder(move |picked| {
        let _ = tx.send(picked.and_then(|p| p.into_path().ok()));
    });
    let picked = rx.await.map_err(|e| AppError::Other(e.to_string()))?;
    Ok(picked.map(|p| p.to_string_lossy().to_string()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use tempfile::tempdir;

    #[test]
    fn lists_only_files_in_root() {
        let dir = tempdir().unwrap();
        fs::write(dir.path().join("a.txt"), b"hi").unwrap();
        fs::write(dir.path().join("b.md"), b"x").unwrap();
        fs::create_dir(dir.path().join("sub")).unwrap();
        fs::write(dir.path().join("sub").join("c.txt"), b"nested").unwrap();
        fs::write(dir.path().join(".hidden"), b"secret").unwrap();

        let mut entries = open_folder_impl(dir.path()).unwrap();
        entries.sort_by(|a, b| a.name.cmp(&b.name));
        let names: Vec<_> = entries.iter().map(|e| e.name.as_str()).collect();
        assert_eq!(names, vec!["a.txt", "b.md"]);
    }

    #[test]
    fn get_metadata_matches_filesystem() {
        let dir = tempdir().unwrap();
        let p = dir.path().join("foo.txt");
        fs::write(&p, b"hello world").unwrap();
        let m = get_metadata_impl(&p).unwrap();
        assert_eq!(m.name, "foo.txt");
        assert_eq!(m.size, 11);
        assert!(m.mtime_ms > 0);
    }

    #[test]
    fn get_metadata_rejects_directory() {
        let dir = tempdir().unwrap();
        let err = get_metadata_impl(dir.path()).unwrap_err();
        assert!(matches!(err, AppError::NotAFile(_)));
    }
}
