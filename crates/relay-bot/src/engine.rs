//! The bot's view of the relay-core `RelayEngine` (contract in `docs/specs/core-api.md`).
//!
//! Everything cryptographic goes through the [`Engine`] trait, so the HTTP API and the node
//! client never touch keys or ciphertext formats. [`CoreEngine`] is the production
//! implementation backed by `relay_core::RelayEngine`; tests may plug in their own.

use std::fmt;
use std::path::Path;
use std::sync::{Arc, Mutex};

use relay_core::RelayEngine;

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
    /// Full `relay1:` card advertising `node_url` and the directory `handle`.
    fn my_card(&self, node_url: Option<String>, handle: Option<String>) -> String;
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
    /// Ed25519 signature of this identity's own card text, for `PUT /v1/directory/{handle}`
    /// (`X-Relay-Sig`). Engines that cannot sign it return an error and the bot skips the claim.
    fn sign_directory_card(&self, _card: &str) -> Result<Vec<u8>, EngineError> {
        Err(EngineError("relay-core exposes no directory card signature yet".into()))
    }
}

/// Loads the engine from `state_path`, or creates a new identity named `name` there.
/// Returns the engine and whether it was just created.
pub fn load_or_create(state_path: &Path, name: &str) -> anyhow::Result<(Arc<dyn Engine>, bool)> {
    match std::fs::read(state_path) {
        Ok(bytes) => {
            let engine = CoreEngine::restore(&bytes)
                .map_err(|e| anyhow::anyhow!("cannot restore {}: {e}", state_path.display()))?;
            engine.set_display_name(name);
            Ok((Arc::new(engine), false))
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok((Arc::new(CoreEngine::create(name)), true)),
        Err(e) => Err(anyhow::anyhow!("cannot read {}: {e}", state_path.display())),
    }
}

/// [`Engine`] backed by `relay_core::RelayEngine`: hybrid post-quantum identity, sessions
/// and envelopes.
pub struct CoreEngine(Mutex<RelayEngine>);

impl CoreEngine {
    /// A new identity.
    pub fn create(name: &str) -> Self {
        Self(Mutex::new(RelayEngine::create(name.to_string())))
    }

    /// An identity from `export_state()` bytes.
    pub fn restore(state: &[u8]) -> Result<Self, EngineError> {
        RelayEngine::restore(state).map(|e| Self(Mutex::new(e))).map_err(err)
    }

    /// Renames the identity when `name` differs from the stored one.
    pub fn set_display_name(&self, name: &str) {
        let mut e = self.lock();
        if e.display_name() != name {
            e.set_display_name(name.to_string());
        }
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, RelayEngine> {
        self.0.lock().unwrap_or_else(|e| e.into_inner())
    }
}

fn err(e: relay_core::RelayError) -> EngineError {
    EngineError(e.to_string())
}

fn contact(c: relay_core::ContactJson) -> Contact {
    Contact {
        fingerprint: c.fingerprint,
        name: c.name,
        mailbox: c.mailbox,
        verified: c.verified,
        node_url: c.node_url,
        handle: c.handle,
    }
}

impl Engine for CoreEngine {
    fn display_name(&self) -> String {
        self.lock().display_name()
    }
    fn fingerprint_hex(&self) -> String {
        self.lock().fingerprint_hex()
    }
    fn mailbox_hex(&self) -> String {
        self.lock().mailbox_hex()
    }
    fn safety_words(&self) -> Vec<String> {
        self.lock().safety_words()
    }
    fn my_card(&self, node_url: Option<String>, handle: Option<String>) -> String {
        self.lock().my_card(node_url, handle)
    }
    fn my_compact_link(&self, node_url: Option<String>) -> String {
        self.lock().my_compact_link(node_url)
    }
    fn device_signing_public(&self) -> Vec<u8> {
        self.lock().device_signing_public()
    }
    fn sign_node_challenge(&self, nonce: &[u8]) -> Vec<u8> {
        self.lock().sign_node_challenge(nonce)
    }
    fn rotate_prekey_if_due(&self, now_ms: i64) -> bool {
        self.lock().rotate_prekey_if_due(now_ms)
    }
    fn add_contact(&self, card: &str) -> Result<Contact, EngineError> {
        self.lock().add_contact(card).map(contact).map_err(err)
    }
    fn parse_compact_link(&self, link: &str) -> Result<CompactLink, EngineError> {
        self.lock()
            .parse_compact_link(link)
            .map(|c| CompactLink { fingerprint: c.fingerprint, node_url: c.node_url, handle: c.handle })
            .map_err(err)
    }
    fn contacts(&self) -> Vec<Contact> {
        serde_json::from_str(&self.lock().contacts()).unwrap_or_default()
    }
    fn encrypt_for(&self, fingerprint: &str, app_message_json: &str) -> Result<Vec<u8>, EngineError> {
        self.lock().encrypt_for(fingerprint, app_message_json).map_err(err)
    }
    fn open(&self, envelope: &[u8], now_ms: i64) -> Result<Option<serde_json::Value>, EngineError> {
        let opened = self.lock().open(envelope, now_ms).map_err(err)?;
        opened
            .map(|json| serde_json::from_str(&json).map_err(|e| EngineError(format!("bad InboundJson: {e}"))))
            .transpose()
    }
    fn export_state(&self) -> Vec<u8> {
        self.lock().export_state()
    }
}
