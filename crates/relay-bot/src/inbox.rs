//! Received messages, kept in memory (last 1000) and appended to a JSON Lines file.

use std::collections::VecDeque;
use std::io::Write;
use std::path::PathBuf;

use serde::{Deserialize, Serialize};

/// Messages kept in memory and returned by `GET /v1/messages`.
pub const KEEP: usize = 1000;

/// One received message, as returned by the API and posted to the webhook.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct InboxItem {
    /// Monotonic cursor, use it as `since`.
    pub seq: u64,
    pub received_at: i64,
    /// Sender fingerprint (64 hex).
    pub from: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub from_name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub group: Option<String>,
    pub envelope_id: String,
    /// The `AppMessage` (spec section 5).
    pub message: serde_json::Value,
}

pub struct Inbox {
    items: VecDeque<InboxItem>,
    next_seq: u64,
    file: Option<PathBuf>,
}

impl Inbox {
    /// In-memory only.
    pub fn memory() -> Self {
        Self { items: VecDeque::new(), next_seq: 1, file: None }
    }

    /// Loads the tail of `path` (if it exists) and appends to it from now on.
    pub fn open(path: PathBuf) -> Self {
        let mut inbox = Self { items: VecDeque::new(), next_seq: 1, file: Some(path.clone()) };
        if let Ok(text) = std::fs::read_to_string(&path) {
            for line in text.lines() {
                if let Ok(item) = serde_json::from_str::<InboxItem>(line) {
                    inbox.next_seq = inbox.next_seq.max(item.seq + 1);
                    inbox.items.push_back(item);
                    if inbox.items.len() > KEEP {
                        inbox.items.pop_front();
                    }
                }
            }
        }
        inbox
    }

    /// Records a message and returns it with its sequence number.
    pub fn push(&mut self, mut item: InboxItem) -> InboxItem {
        item.seq = self.next_seq;
        self.next_seq += 1;
        if let Some(path) = &self.file {
            let line = serde_json::to_string(&item).unwrap_or_default();
            let res = std::fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(path)
                .and_then(|mut f| writeln!(f, "{line}"));
            if let Err(e) = res {
                tracing::error!("appending to the message log failed: {e}");
            }
        }
        self.items.push_back(item.clone());
        if self.items.len() > KEEP {
            self.items.pop_front();
        }
        item
    }

    /// Messages with `seq > since`, oldest first, at most `limit`.
    pub fn since(&self, since: u64, limit: usize) -> Vec<InboxItem> {
        self.items.iter().filter(|i| i.seq > since).take(limit).cloned().collect()
    }

    /// Has this envelope already been recorded? (the node delivers at least once)
    pub fn seen(&self, envelope_id: &str) -> bool {
        self.items.iter().rev().take(200).any(|i| i.envelope_id == envelope_id)
    }
}
