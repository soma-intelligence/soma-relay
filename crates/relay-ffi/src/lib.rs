//! UniFFI surface of relay-core (`docs/specs/core-api.md`). Swift and Kotlin see
//! `RelayEngine` and `MeshRouter` objects with camelCase methods.

use std::sync::{Arc, Mutex, MutexGuard};

use relay_core as core;

uniffi::setup_scaffolding!();

#[derive(Debug, uniffi::Error)]
pub enum RelayError {
    InvalidCard { message: String },
    KeyChanged { message: String },
    NoSession { message: String },
    Decrypt { message: String },
    Malformed { message: String },
    Unknown { message: String },
    Storage { message: String },
    Group { message: String },
}

impl std::error::Error for RelayError {}

impl std::fmt::Display for RelayError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let (k, m) = match self {
            RelayError::InvalidCard { message } => ("InvalidCard", message),
            RelayError::KeyChanged { message } => ("KeyChanged", message),
            RelayError::NoSession { message } => ("NoSession", message),
            RelayError::Decrypt { message } => ("Decrypt", message),
            RelayError::Malformed { message } => ("Malformed", message),
            RelayError::Unknown { message } => ("Unknown", message),
            RelayError::Storage { message } => ("Storage", message),
            RelayError::Group { message } => ("Group", message),
        };
        write!(f, "{k}: {m}")
    }
}

impl From<core::RelayError> for RelayError {
    fn from(e: core::RelayError) -> Self {
        let message = e.message().to_string();
        match e {
            core::RelayError::InvalidCard(_) => RelayError::InvalidCard { message },
            core::RelayError::KeyChanged(_) => RelayError::KeyChanged { message },
            core::RelayError::NoSession(_) => RelayError::NoSession { message },
            core::RelayError::Decrypt(_) => RelayError::Decrypt { message },
            core::RelayError::Malformed(_) => RelayError::Malformed { message },
            core::RelayError::Unknown(_) => RelayError::Unknown { message },
            core::RelayError::Storage(_) => RelayError::Storage { message },
            core::RelayError::Group(_) => RelayError::Group { message },
        }
    }
}

type Result<T> = std::result::Result<T, RelayError>;

#[derive(uniffi::Object)]
pub struct RelayEngine {
    inner: Mutex<core::RelayEngine>,
}

impl RelayEngine {
    fn lock(&self) -> MutexGuard<'_, core::RelayEngine> {
        // A panic while holding the lock leaves consistent state (every
        // mutation commits at the end), so a poisoned lock is still usable.
        self.inner.lock().unwrap_or_else(|p| p.into_inner())
    }
}

fn json<T: serde::Serialize>(v: &T) -> String {
    serde_json::to_string(v).unwrap_or_else(|_| "null".into())
}

#[uniffi::export]
impl RelayEngine {
    /// New identity.
    #[uniffi::constructor]
    pub fn create(display_name: String) -> Arc<Self> {
        Arc::new(RelayEngine { inner: Mutex::new(core::RelayEngine::create(display_name)) })
    }

    /// From `export_state()`.
    #[uniffi::constructor]
    pub fn restore(state: Vec<u8>) -> Result<Arc<Self>> {
        Ok(Arc::new(RelayEngine { inner: Mutex::new(core::RelayEngine::restore(&state)?) }))
    }

    pub fn export_state(&self) -> Vec<u8> {
        self.lock().export_state()
    }

    pub fn fingerprint_hex(&self) -> String {
        self.lock().fingerprint_hex()
    }

    pub fn safety_words(&self) -> Vec<String> {
        self.lock().safety_words()
    }

    pub fn mailbox_hex(&self) -> String {
        self.lock().mailbox_hex()
    }

    pub fn display_name(&self) -> String {
        self.lock().display_name()
    }

    pub fn set_display_name(&self, name: String) {
        self.lock().set_display_name(name)
    }

    pub fn my_card(&self, node_url: Option<String>, handle: Option<String>) -> String {
        self.lock().my_card(node_url, handle)
    }

    pub fn my_compact_link(&self, node_url: Option<String>) -> String {
        self.lock().my_compact_link(node_url)
    }

    pub fn device_signing_public(&self) -> Vec<u8> {
        self.lock().device_signing_public()
    }

    pub fn sign_node_challenge(&self, nonce: Vec<u8>) -> Vec<u8> {
        self.lock().sign_node_challenge(&nonce)
    }

    pub fn rotate_prekey_if_due(&self, now_ms: i64) -> bool {
        self.lock().rotate_prekey_if_due(now_ms)
    }

    pub fn add_contact(&self, card: String) -> Result<String> {
        Ok(json(&self.lock().add_contact(&card)?))
    }

    pub fn add_contact_replacing(&self, card: String) -> Result<String> {
        Ok(json(&self.lock().add_contact_replacing(&card)?))
    }

    pub fn parse_compact_link(&self, link: String) -> Result<String> {
        Ok(json(&self.lock().parse_compact_link(&link)?))
    }

    pub fn contacts(&self) -> String {
        self.lock().contacts()
    }

    pub fn remove_contact(&self, fp: String) {
        self.lock().remove_contact(&fp)
    }

    pub fn set_verified(&self, fp: String, verified: bool) {
        self.lock().set_verified(&fp, verified)
    }

    pub fn rename_contact(&self, fp: String, name: String) {
        self.lock().rename_contact(&fp, name)
    }

    pub fn contact_safety_words(&self, fp: String) -> Vec<String> {
        self.lock().contact_safety_words(&fp)
    }

    pub fn contact_safety_code(&self, fp: String) -> String {
        self.lock().contact_safety_code(&fp)
    }

    pub fn encrypt_for(&self, fp: String, app_message_json: String) -> Result<Vec<u8>> {
        Ok(self.lock().encrypt_for(&fp, &app_message_json)?)
    }

    pub fn mesh_tag_for(&self, fp: String, now_ms: i64) -> Vec<u8> {
        self.lock().mesh_tag_for(&fp, now_ms)
    }

    pub fn retag_for_mesh(&self, envelope: Vec<u8>, fp: String, now_ms: i64) -> Vec<u8> {
        self.lock().retag_for_mesh(&envelope, &fp, now_ms)
    }

    /// InboundJson, or nil when the envelope is not for this identity.
    pub fn open(&self, envelope: Vec<u8>, now_ms: i64) -> Result<Option<String>> {
        Ok(self.lock().open(&envelope, now_ms)?)
    }

    pub fn create_group(&self, name: String, member_fps: Vec<String>) -> Result<String> {
        Ok(self.lock().create_group(name, member_fps)?)
    }

    /// Sender-key distribution envelopes first, the group envelope last.
    pub fn group_encrypt(&self, group_id: String, app_message_json: String) -> Result<Vec<Vec<u8>>> {
        Ok(self.lock().group_encrypt(&group_id, &app_message_json)?)
    }

    pub fn groups(&self) -> String {
        self.lock().groups()
    }

    pub fn group_add(&self, group_id: String, fp: String) -> Result<Vec<Vec<u8>>> {
        Ok(self.lock().group_add(&group_id, &fp)?)
    }

    pub fn group_remove(&self, group_id: String, fp: String) -> Result<Vec<Vec<u8>>> {
        Ok(self.lock().group_remove(&group_id, &fp)?)
    }

    pub fn leave_group(&self, group_id: String) {
        self.lock().leave_group(&group_id)
    }

    pub fn channel_encrypt(&self, name: String, password: Option<String>, app_message_json: String) -> Result<Vec<u8>> {
        Ok(self.lock().channel_encrypt(&name, password, &app_message_json)?)
    }

    pub fn join_channel(&self, name: String, password: Option<String>) -> Result<()> {
        Ok(self.lock().join_channel(&name, password)?)
    }

    pub fn leave_channel(&self, name: String) {
        self.lock().leave_channel(&name)
    }

    /// `key(32) || sha256(32) || ciphertext`.
    pub fn seal_attachment(&self, plain: Vec<u8>) -> Vec<u8> {
        self.lock().seal_attachment(&plain)
    }

    pub fn open_attachment(&self, key: Vec<u8>, sha256: Vec<u8>, ciphertext: Vec<u8>) -> Result<Vec<u8>> {
        Ok(core::RelayEngine::open_attachment(&key, &sha256, &ciphertext)?)
    }

    pub fn call_key(&self, fp: String, call_id: String) -> Result<Vec<u8>> {
        Ok(self.lock().call_key(&fp, &call_id)?)
    }

    /// `{id, kind, tag, ttl, size}` (hex), to address an envelope.
    pub fn envelope_info(&self, envelope: Vec<u8>) -> Result<String> {
        Ok(core::RelayEngine::envelope_info(&envelope)?)
    }
}

#[derive(uniffi::Record, Debug, Clone)]
pub struct MeshResult {
    pub complete: Option<Vec<u8>>,
    pub forward: Vec<Vec<u8>>,
    pub exclude_link: u32,
}

#[derive(uniffi::Object)]
pub struct MeshRouter {
    inner: Mutex<core::MeshRouter>,
}

#[uniffi::export]
impl MeshRouter {
    #[uniffi::constructor]
    pub fn new() -> Arc<Self> {
        Arc::new(MeshRouter { inner: Mutex::new(core::MeshRouter::new()) })
    }

    pub fn on_frame(&self, frame: Vec<u8>, from_link: u32, now_ms: i64) -> MeshResult {
        let r = self.inner.lock().unwrap_or_else(|p| p.into_inner()).on_frame(&frame, from_link, now_ms);
        MeshResult { complete: r.complete, forward: r.forward, exclude_link: r.exclude_link }
    }

    pub fn frames_for(&self, envelope: Vec<u8>, mtu: u32) -> Vec<Vec<u8>> {
        self.inner.lock().unwrap_or_else(|p| p.into_inner()).frames_for(&envelope, mtu)
    }
}
