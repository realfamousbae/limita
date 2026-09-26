//! Reading a file's lines from last to first. Port of `TailLineReader.swift`.

use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::path::Path;

/// Yields the lines of a file from the last to the first, reading only as much as consumed.
///
/// Codex session transcripts grow to megabytes but the data we want is always appended at
/// the end, so reading forward would parse the whole history to reach it.
pub struct TailLines {
    file: Option<File>,
    chunk_size: usize,
    /// Offset of the not-yet-read head of the file.
    offset: u64,
    /// Bytes read but not yet split into complete lines; always a file prefix of what remains.
    pending: Vec<u8>,
    finished: bool,
}

impl TailLines {
    pub fn open(path: &Path) -> Self {
        Self::with_chunk_size(path, 64 * 1024)
    }

    pub fn with_chunk_size(path: &Path, chunk_size: usize) -> Self {
        let file = File::open(path).ok();
        let offset = file.as_ref().and_then(|f| f.metadata().ok()).map_or(0, |m| m.len());
        Self {
            finished: file.is_none() || offset == 0,
            file,
            chunk_size: chunk_size.max(1),
            offset,
            pending: Vec::new(),
        }
    }

    /// Prepends the chunk before `offset`. Reading backwards can split a UTF-8 sequence,
    /// so chunks are stitched as bytes and only decoded once a whole line is isolated.
    fn read_previous_chunk(&mut self) {
        let Some(file) = self.file.as_mut() else {
            self.finished = true;
            return;
        };
        let length = (self.chunk_size as u64).min(self.offset);
        let start = self.offset - length;
        let mut chunk = vec![0; length as usize];
        if file.seek(SeekFrom::Start(start)).is_err() || file.read_exact(&mut chunk).is_err() {
            self.finished = true;
            return;
        }
        chunk.extend_from_slice(&self.pending);
        self.pending = chunk;
        self.offset = start;
        if self.offset == 0 {
            self.finished = true;
        }
    }
}

impl Iterator for TailLines {
    type Item = String;

    fn next(&mut self) -> Option<String> {
        self.file.as_ref()?;
        loop {
            if let Some(newline) = self.pending.iter().rposition(|&byte| byte == b'\n') {
                let line = self.pending.split_off(newline + 1);
                self.pending.pop(); // the newline itself
                let line = trim_cr(line);
                if !line.is_empty() {
                    return Some(String::from_utf8_lossy(&line).into_owned());
                }
                continue; // blank line (trailing newline, or \n\n) — skip it
            }
            if self.finished {
                self.file = None;
                let rest = trim_cr(std::mem::take(&mut self.pending));
                return (!rest.is_empty()).then(|| String::from_utf8_lossy(&rest).into_owned());
            }
            self.read_previous_chunk();
        }
    }
}

/// Files written on Windows may end lines with CRLF.
fn trim_cr(mut line: Vec<u8>) -> Vec<u8> {
    if line.last() == Some(&b'\r') {
        line.pop();
    }
    line
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_backwards_across_small_chunks() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("fixture.txt");
        std::fs::write(&file, "первая\nsecond\r\nтретья\n").unwrap();
        let lines: Vec<_> = TailLines::with_chunk_size(&file, 3).collect();
        assert_eq!(lines, ["третья", "second", "первая"]);
        assert_eq!(TailLines::open(&dir.path().join("missing")).count(), 0);
    }
}
