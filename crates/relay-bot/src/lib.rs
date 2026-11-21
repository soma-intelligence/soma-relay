//! Soma Relay bot runtime. A bot is a normal end-to-end encrypted contact: it holds an
//! identity, stays connected to one node, and exposes a small local REST API so any program
//! can read and send messages (see `docs/specs/2026-11-21-soma-relay-design.md`, section 8).

pub mod api;
pub mod engine;
pub mod inbox;
pub mod node;
pub mod resolve;

use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use tokio::sync::{Mutex, mpsc};

use crate::engine::Engine;
use crate::inbox::Inbox;
use crate::node::Outgoing;

/// Runtime settings of a bot.
#[derive(Debug, Clone)]
pub struct Settings {
    /// Node base URL, `https://relay.example.org`.
    pub node_url: url::Url,
    /// Where the engine state is saved.
    pub state_path: PathBuf,
    /// Optional URL that receives a POST for each incoming message.
    pub webhook: Option<url::Url>,
    /// Bearer token for the message endpoints.
    pub token: String,
}

/// Shared bot state.
pub struct Bot {
    pub engine: Arc<dyn Engine>,
    pub settings: Settings,
    pub inbox: Mutex<Inbox>,
    pub outbox: mpsc::Sender<Outgoing>,
    pub http: reqwest::Client,
    connected: AtomicBool,
    save_lock: std::sync::Mutex<()>,
}

impl Bot {
    /// Builds the bot and the receiving end of its outbox (to hand to [`node::run`]).
    pub fn new(engine: Arc<dyn Engine>, settings: Settings, inbox: Inbox) -> (Arc<Self>, mpsc::Receiver<Outgoing>) {
        let (outbox, rx) = mpsc::channel(256);
        let http = reqwest::Client::builder()
            .timeout(std::time::Duration::from_secs(20))
            .user_agent(concat!("soma-relay-bot/", env!("CARGO_PKG_VERSION")))
            .build()
            .expect("http client");
        let bot = Arc::new(Self {
            engine,
            settings,
            inbox: Mutex::new(inbox),
            outbox,
            http,
            connected: AtomicBool::new(false),
            save_lock: std::sync::Mutex::new(()),
        });
        (bot, rx)
    }

    /// Node URL as advertised in the card (no trailing slash).
    pub fn node_base(&self) -> String {
        self.settings.node_url.as_str().trim_end_matches('/').to_string()
    }

    pub fn my_card(&self) -> String {
        self.engine.my_card(Some(self.node_base()))
    }

    pub fn my_link(&self) -> String {
        self.engine.my_compact_link(Some(self.node_base()))
    }

    pub fn is_connected(&self) -> bool {
        self.connected.load(Ordering::Relaxed)
    }

    pub(crate) fn set_connected(&self, v: bool) {
        self.connected.store(v, Ordering::Relaxed);
    }

    /// Saves the engine state atomically (temp file + rename, mode 0600).
    pub fn save(&self) {
        let _g = self.save_lock.lock().unwrap_or_else(|e| e.into_inner());
        if let Err(e) = write_private(&self.settings.state_path, &self.engine.export_state()) {
            tracing::error!("saving state failed: {e}");
        }
    }
}

/// Writes `data` to `path` through a temporary file, readable by the owner only.
pub fn write_private(path: &Path, data: &[u8]) -> std::io::Result<()> {
    let tmp = path.with_extension("tmp");
    {
        use std::io::Write;
        let mut opts = std::fs::OpenOptions::new();
        opts.write(true).create(true).truncate(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            opts.mode(0o600);
        }
        let mut f = opts.open(&tmp)?;
        f.write_all(data)?;
        f.sync_all()?;
    }
    std::fs::rename(&tmp, path)
}

/// Loads the bearer token next to the state file, or creates one. Returns the token and
/// whether it is new.
pub fn load_or_create_token(state_path: &Path) -> std::io::Result<(String, bool)> {
    let path = token_path(state_path);
    if let Ok(t) = std::fs::read_to_string(&path) {
        let t = t.trim().to_string();
        if t.len() >= 32 {
            return Ok((t, false));
        }
    }
    let mut raw = [0u8; 32];
    rand::RngCore::fill_bytes(&mut rand::rngs::OsRng, &mut raw);
    let token = hex::encode(raw);
    write_private(&path, token.as_bytes())?;
    Ok((token, true))
}

/// `<state>.token`
pub fn token_path(state_path: &Path) -> PathBuf {
    let mut p = state_path.as_os_str().to_owned();
    p.push(".token");
    PathBuf::from(p)
}

/// `<state>.messages.jsonl`
pub fn inbox_path(state_path: &Path) -> PathBuf {
    let mut p = state_path.as_os_str().to_owned();
    p.push(".messages.jsonl");
    PathBuf::from(p)
}

/// Milliseconds since the Unix epoch.
pub fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}
