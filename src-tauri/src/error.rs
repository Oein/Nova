use serde::Serialize;
use thiserror::Error;

#[derive(Debug, Error)]
pub enum AppError {
    #[error("io: {0}")]
    Io(#[from] std::io::Error),
    #[error("file too large: {size} bytes > limit {limit}")]
    FileTooLarge { size: u64, limit: u64 },
    #[error("file is not a regular file: {0}")]
    NotAFile(String),
    #[error("mtime mismatch: disk={disk}, expected={expected}")]
    MtimeMismatch { disk: i64, expected: i64 },
    #[error("no large file open: {0}")]
    NoLargeFile(String),
    #[error("invalid line range: {start}..{end}")]
    InvalidLineRange { start: u64, end: u64 },
    #[error("invalid utf-8 at offset {offset}")]
    InvalidUtf8 { offset: u64 },
    #[error("{0}")]
    Other(String),
}

impl Serialize for AppError {
    fn serialize<S: serde::Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        s.serialize_str(&self.to_string())
    }
}

pub type AppResult<T> = Result<T, AppError>;
