//! Bounded output history and ordered broadcast chunks.

use std::{
    collections::VecDeque,
    sync::{Arc, Mutex, PoisonError},
};

use tokio::sync::broadcast;

pub(crate) const DEFAULT_OUTPUT_LIMIT: usize = 1024 * 1024;
const BROADCAST_CAPACITY: usize = 256;

/// One piece of terminal output with a monotonically increasing sequence number.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OutputChunk {
    pub seq: u64,
    pub bytes: Arc<[u8]>,
}

impl OutputChunk {
    pub fn data(&self) -> &[u8] {
        &self.bytes
    }
}

/// A point-in-time view of the retained output history.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OutputSnapshot {
    pub bytes: Vec<u8>,
    pub first_seq: Option<u64>,
    pub next_seq: u64,
    pub truncated: bool,
}

pub(crate) struct OutputState {
    limit: usize,
    inner: Mutex<OutputInner>,
    sender: broadcast::Sender<OutputChunk>,
}

struct OutputInner {
    chunks: VecDeque<OutputChunk>,
    size: usize,
    next_seq: u64,
    truncated: bool,
}

impl OutputState {
    pub(crate) fn new(limit: usize) -> Self {
        assert!(limit > 0, "output limit must be positive");
        let (sender, _) = broadcast::channel(BROADCAST_CAPACITY);
        Self {
            limit,
            inner: Mutex::new(OutputInner {
                chunks: VecDeque::new(),
                size: 0,
                next_seq: 0,
                truncated: false,
            }),
            sender,
        }
    }

    pub(crate) fn push(&self, bytes: Vec<u8>) {
        if bytes.is_empty() {
            return;
        }

        let chunk = {
            let mut inner = self.inner.lock().unwrap_or_else(PoisonError::into_inner);
            let seq = inner.next_seq;
            inner.next_seq += 1;

            let mut bytes: Arc<[u8]> = Arc::from(bytes);
            if bytes.len() > self.limit {
                let start = bytes.len() - self.limit;
                bytes = Arc::from(&bytes[start..]);
                inner.chunks.clear();
                inner.size = 0;
                inner.truncated = true;
            }

            let chunk = OutputChunk { seq, bytes };
            while inner.size + chunk.bytes.len() > self.limit {
                let Some(removed) = inner.chunks.pop_front() else {
                    break;
                };
                inner.size -= removed.bytes.len();
                inner.truncated = true;
            }
            inner.size += chunk.bytes.len();
            inner.chunks.push_back(chunk.clone());
            chunk
        };

        let _ = self.sender.send(chunk);
    }

    pub(crate) fn snapshot(&self) -> OutputSnapshot {
        let inner = self.inner.lock().unwrap_or_else(PoisonError::into_inner);
        let mut bytes = Vec::with_capacity(inner.size);
        for chunk in &inner.chunks {
            bytes.extend_from_slice(&chunk.bytes);
        }
        OutputSnapshot {
            bytes,
            first_seq: inner.chunks.front().map(|chunk| chunk.seq),
            next_seq: inner.next_seq,
            truncated: inner.truncated,
        }
    }

    pub(crate) fn subscribe(&self) -> broadcast::Receiver<OutputChunk> {
        self.sender.subscribe()
    }
}

#[cfg(test)]
mod tests {
    use super::OutputState;

    #[test]
    fn retains_only_the_newest_bytes_and_advances_sequences() {
        let output = OutputState::new(6);
        output.push(b"abc".to_vec());
        output.push(b"def".to_vec());
        output.push(b"ghi".to_vec());

        let snapshot = output.snapshot();
        assert_eq!(snapshot.bytes, b"defghi");
        assert_eq!(snapshot.first_seq, Some(1));
        assert_eq!(snapshot.next_seq, 3);
        assert!(snapshot.truncated);
    }

    #[test]
    fn snapshot_is_empty_before_any_output() {
        let output = OutputState::new(16);
        let snapshot = output.snapshot();
        assert!(snapshot.bytes.is_empty());
        assert_eq!(snapshot.first_seq, None);
        assert_eq!(snapshot.next_seq, 0);
        assert!(!snapshot.truncated);
    }

    #[test]
    fn a_chunk_larger_than_the_limit_is_truncated() {
        let output = OutputState::new(4);
        output.push(b"0123456789".to_vec());

        let snapshot = output.snapshot();
        assert_eq!(snapshot.bytes, b"6789");
        assert_eq!(snapshot.first_seq, Some(0));
        assert_eq!(snapshot.next_seq, 1);
        assert!(snapshot.truncated);
    }
}
