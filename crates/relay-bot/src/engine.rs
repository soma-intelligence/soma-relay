//! The bot's view of the relay-core `RelayEngine` (contract in `docs/specs/core-api.md`).
//!
//! Everything cryptographic goes through the [`Engine`] trait, so the HTTP API and the node
//! client never touch keys or ciphertext formats. [`CoreEngine`] is the production
//! implementation backed by `relay_core::RelayEngine`; tests plug in their own.

use std::fmt;
use std::path::Path;
use std::sync::Arc;

use serde::{Deserialize, Serialize};

/// Error from the engine, carrying the core's message.
#[derive(Debug, Clone)]
pub struct EngineError(pub String);

impl fmt::Display for EngineError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for EngineError {}

/// `ContactJson` of the core API.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct Contact {
    pub fingerprint: String,
    pub name: String,
    pub mailbox: String,
    #[serde(default)]
    pub verified: bool,
    #[serde(default)]
    pub node_url: Option<String>,
    #[serde(default)]
    pub handle: Option<String>,
}

/// `CompactJson` of the core API (`relay1c:` links).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct CompactLink {
    pub fingerprint: String,
    #[serde(default)]
    pub node_url: Option<String>,
    #[serde(default)]
    pub handle: Option<String>,
}

/// The subset of `RelayEngine` a bot needs. Method names and meanings follow core-api.md.
pub trait Engine: Send + Sync + 'static {
    fn display_name(&self) -> String;
    fn fingerprint_hex(&self) -> String;
    fn mailbox_hex(&self) -> String;
    fn safety_words(&self) -> Vec<String>;
    /// Full `relay1:` card advertising `node_url`.
    fn my_card(&self, node_url: Option<String>) -> String;
    /// Compact `relay1c:` link (fits a QR code).
    fn my_compact_link(&self, node_url: Option<String>) -> String;
    /// Ed25519 public key used to authenticate to nodes (32 bytes).
    fn device_signing_public(&self) -> Vec<u8>;
    /// Signature over `"soma-relay/node-auth/v1" || nonce || mailbox`.
    fn sign_node_challenge(&self, nonce: &[u8]) -> Vec<u8>;
    /// Rotates the signed prekey when due. Returns `true` when the card changed.
    fn rotate_prekey_if_due(&self, now_ms: i64) -> bool;
    /// Verifies and stores a full card. Idempotent.
    fn add_contact(&self, card: &str) -> Result<Contact, EngineError>;
    fn parse_compact_link(&self, link: &str) -> Result<CompactLink, EngineError>;
    fn contacts(&self) -> Vec<Contact>;
    /// One direct envelope (postcard bytes) carrying `app_message_json` to `fingerprint`.
    fn encrypt_for(&self, fingerprint: &str, app_message_json: &str) -> Result<Vec<u8>, EngineError>;
    /// Opens an envelope. `Ok(None)` means it is not for this identity.
    /// `Ok(Some(v))` is the core's `InboundJson`.
    fn open(&self, envelope: &[u8], now_ms: i64) -> Result<Option<serde_json::Value>, EngineError>;
    /// Whole engine state, to be saved after every mutating call.
    fn export_state(&self) -> Vec<u8>;
}

/// Loads the engine from `state_path`, or creates a new identity named `name` there.
/// Returns the engine and whether it was just created.
pub fn load_or_create(state_path: &Path, name: &str) -> anyhow::Result<(Arc<dyn Engine>, bool)> {
    core_impl::load_or_create(state_path, name)
}

mod core_impl {
    use super::*;

    /// Placeholder until relay-core is wired: the bot refuses to start rather than run
    /// without end-to-end encryption.
    pub fn load_or_create(_state_path: &Path, _name: &str) -> anyhow::Result<(Arc<dyn Engine>, bool)> {
        anyhow::bail!("relay-bot was built without relay-core; the encryption engine is not linked yet")
    }
}
