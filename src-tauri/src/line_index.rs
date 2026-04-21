use std::fs::File;
use std::path::Path;

use memmap2::Mmap;

use crate::error::{AppError, AppResult};

pub const STRIDE: u64 = 256;

pub struct LineIndex {
    pub path: std::path::PathBuf,
    pub size: u64,
    pub mtime_ms: i64,
    pub line_count: u64,
    pub offsets: Vec<u64>,
    pub mmap: Mmap,
}

impl LineIndex {
    pub fn open(path: &Path) -> AppResult<Self> {
        let file = File::open(path)?;
        let meta = file.metadata()?;
        if !meta.is_file() {
            return Err(AppError::NotAFile(path.display().to_string()));
        }
        let size = meta.len();
        let mtime_ms = crate::fs_util::mtime_ms(&meta);
        let mmap = unsafe { Mmap::map(&file)? };
        let (line_count, offsets) = build_index(&mmap);
        Ok(Self {
            path: path.to_path_buf(),
            size,
            mtime_ms,
            line_count,
            offsets,
            mmap,
        })
    }

    pub fn line_range_bytes(&self, start_line: u64, end_line: u64) -> AppResult<&[u8]> {
        if start_line > end_line || end_line > self.line_count {
            return Err(AppError::InvalidLineRange {
                start: start_line,
                end: end_line,
            });
        }
        let start_off = self.line_start(start_line);
        let end_off = if end_line == self.line_count {
            self.mmap.len() as u64
        } else {
            self.line_start(end_line)
        };
        Ok(&self.mmap[start_off as usize..end_off as usize])
    }

    pub fn line_range_text(&self, start_line: u64, end_line: u64) -> AppResult<String> {
        let bytes = self.line_range_bytes(start_line, end_line)?;
        match std::str::from_utf8(bytes) {
            Ok(s) => Ok(strip_trailing_newline(s).to_string()),
            Err(e) => Err(AppError::InvalidUtf8 {
                offset: self.line_start(start_line) + e.valid_up_to() as u64,
            }),
        }
    }

    pub fn byte_range(&self, offset: u64, len: u64) -> AppResult<&[u8]> {
        let end = offset.saturating_add(len).min(self.size);
        if offset > self.size {
            return Err(AppError::InvalidLineRange {
                start: offset,
                end,
            });
        }
        Ok(&self.mmap[offset as usize..end as usize])
    }

    fn line_start(&self, line: u64) -> u64 {
        if line == 0 {
            return 0;
        }
        let stride_idx = ((line - 1) / STRIDE) as usize;
        let mut off = self.offsets[stride_idx];
        let mut at = (stride_idx as u64) * STRIDE;
        while at < line - 1 {
            let slice = &self.mmap[off as usize..];
            if let Some(pos) = memchr_nl(slice) {
                off += pos as u64 + 1;
                at += 1;
            } else {
                break;
            }
        }
        if at == line - 1 {
            let slice = &self.mmap[off as usize..];
            if let Some(pos) = memchr_nl(slice) {
                return off + pos as u64 + 1;
            }
        }
        self.size
    }
}

fn build_index(bytes: &[u8]) -> (u64, Vec<u64>) {
    let mut offsets = vec![0u64];
    let mut lines: u64 = 1;
    let mut last_was_nl = false;
    for (i, &b) in bytes.iter().enumerate() {
        if b == b'\n' {
            let next_line = lines;
            if next_line % STRIDE == 0 {
                offsets.push((i as u64) + 1);
            }
            lines += 1;
            last_was_nl = true;
        } else {
            last_was_nl = false;
        }
    }
    if bytes.is_empty() {
        return (0, vec![0]);
    }
    if last_was_nl {
        lines -= 1;
    }
    (lines, offsets)
}

fn memchr_nl(haystack: &[u8]) -> Option<usize> {
    haystack.iter().position(|&b| b == b'\n')
}

fn strip_trailing_newline(s: &str) -> &str {
    if let Some(stripped) = s.strip_suffix('\n') {
        stripped.strip_suffix('\r').unwrap_or(stripped)
    } else {
        s
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use tempfile::NamedTempFile;

    fn write_tmp(bytes: &[u8]) -> NamedTempFile {
        let mut f = NamedTempFile::new().unwrap();
        f.write_all(bytes).unwrap();
        f.flush().unwrap();
        f
    }

    #[test]
    fn empty_file_has_zero_lines() {
        let f = write_tmp(b"");
        let idx = LineIndex::open(f.path()).unwrap();
        assert_eq!(idx.line_count, 0);
    }

    #[test]
    fn single_line_no_newline() {
        let f = write_tmp(b"hello");
        let idx = LineIndex::open(f.path()).unwrap();
        assert_eq!(idx.line_count, 1);
        assert_eq!(idx.line_range_text(0, 1).unwrap(), "hello");
    }

    #[test]
    fn trailing_newline_not_counted() {
        let f = write_tmp(b"a\nb\n");
        let idx = LineIndex::open(f.path()).unwrap();
        assert_eq!(idx.line_count, 2);
        assert_eq!(idx.line_range_text(0, 1).unwrap(), "a");
        assert_eq!(idx.line_range_text(1, 2).unwrap(), "b");
    }

    #[test]
    fn crlf_lines() {
        let f = write_tmp(b"a\r\nb\r\nc");
        let idx = LineIndex::open(f.path()).unwrap();
        assert_eq!(idx.line_count, 3);
        assert_eq!(idx.line_range_text(0, 1).unwrap(), "a");
        assert_eq!(idx.line_range_text(1, 2).unwrap(), "b");
        assert_eq!(idx.line_range_text(2, 3).unwrap(), "c");
    }

    #[test]
    fn large_stride_boundary() {
        let mut buf = Vec::new();
        for i in 0..600 {
            buf.extend_from_slice(format!("line{}\n", i).as_bytes());
        }
        let f = write_tmp(&buf);
        let idx = LineIndex::open(f.path()).unwrap();
        assert_eq!(idx.line_count, 600);
        assert_eq!(idx.line_range_text(0, 1).unwrap(), "line0");
        assert_eq!(idx.line_range_text(255, 256).unwrap(), "line255");
        assert_eq!(idx.line_range_text(256, 257).unwrap(), "line256");
        assert_eq!(idx.line_range_text(599, 600).unwrap(), "line599");
    }

    #[test]
    fn line_range_spans_multiple() {
        let f = write_tmp(b"a\nb\nc\nd");
        let idx = LineIndex::open(f.path()).unwrap();
        assert_eq!(idx.line_range_text(1, 3).unwrap(), "b\nc");
    }

    #[test]
    fn byte_range_basic() {
        let f = write_tmp(b"abcdef");
        let idx = LineIndex::open(f.path()).unwrap();
        assert_eq!(idx.byte_range(2, 3).unwrap(), b"cde");
        assert_eq!(idx.byte_range(4, 100).unwrap(), b"ef");
    }

    #[test]
    fn index_matches_brute_force() {
        let content: String = (0..1234)
            .map(|i| format!("hello line {} with some text\n", i))
            .collect();
        let f = write_tmp(content.as_bytes());
        let idx = LineIndex::open(f.path()).unwrap();
        let expected: Vec<&str> = content.lines().collect();
        assert_eq!(idx.line_count, expected.len() as u64);
        for (i, want) in expected.iter().enumerate() {
            let got = idx
                .line_range_text(i as u64, (i + 1) as u64)
                .unwrap_or_default();
            assert_eq!(&got, want, "mismatch at line {}", i);
        }
    }
}
