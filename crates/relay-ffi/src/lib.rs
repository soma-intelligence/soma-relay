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

    /// Own card carrying `handle` plus its directory signature, for
    /// `PUT /v1/directory/{handle}` (body = `card`, `X-Relay-Sig` = base64url of `sig`).
    pub fn sign_directory_entry(&self, handle: String) -> Result<DirectoryEntry> {
        let (card, sig) = self.lock().sign_directory_entry(&handle)?;
        Ok(DirectoryEntry { card, sig })
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

// ------------------------------------------------------------------ passkey vault

#[derive(Debug, uniffi::Error)]
pub enum VaultError {
    /// Larger than 1 MiB even without the photo.
    TooLarge { message: String },
    /// Not a `RVB1` blob.
    BadMagic { message: String },
    /// Wrong key or vault id, or tampered bytes.
    Decrypt { message: String },
    /// The plaintext is not a vault this version reads.
    Parse { message: String },
    /// A PRF output or vault key that is not 32 bytes.
    BadKey { message: String },
    /// A `relaystate2:` export with no passphrase, or one that does not open it.
    Passphrase { message: String },
}

impl std::error::Error for VaultError {}

impl std::fmt::Display for VaultError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let (k, m) = match self {
            VaultError::TooLarge { message } => ("TooLarge", message),
            VaultError::BadMagic { message } => ("BadMagic", message),
            VaultError::Decrypt { message } => ("Decrypt", message),
            VaultError::Parse { message } => ("Parse", message),
            VaultError::BadKey { message } => ("BadKey", message),
            VaultError::Passphrase { message } => ("Passphrase", message),
        };
        write!(f, "{k}: {m}")
    }
}

impl From<core::VaultError> for VaultError {
    fn from(e: core::VaultError) -> Self {
        let message = e.message().to_string();
        match e {
            core::VaultError::TooLarge => VaultError::TooLarge { message },
            core::VaultError::BadMagic => VaultError::BadMagic { message },
            core::VaultError::Decrypt => VaultError::Decrypt { message },
            core::VaultError::Parse => VaultError::Parse { message },
            core::VaultError::Passphrase => VaultError::Passphrase { message },
        }
    }
}

fn key32(b: &[u8]) -> std::result::Result<[u8; 32], VaultError> {
    b.try_into().map_err(|_| VaultError::BadKey {
        message: format!("expected 32 bytes, got {}", b.len()),
    })
}

/// Plaintext of the backup blob (`docs/specs/2026-11-22-passkey-unlock-backup.md` section 3).
/// The format version is not part of the record: `seal_vault` writes the current one.
#[derive(uniffi::Record, Debug, Clone, PartialEq, Eq)]
pub struct VaultPlain {
    pub engine: Vec<u8>,
    pub handle: Option<String>,
    pub node_url: Option<String>,
    pub channels_prefs: Vec<u8>,
    pub photo: Option<Vec<u8>>,
}

impl From<VaultPlain> for core::VaultPlain {
    fn from(p: VaultPlain) -> Self {
        core::VaultPlain {
            v: core::vault::VAULT_VERSION,
            engine: p.engine,
            handle: p.handle,
            node_url: p.node_url,
            channels_prefs: p.channels_prefs,
            photo: p.photo,
        }
    }
}

impl From<core::VaultPlain> for VaultPlain {
    fn from(p: core::VaultPlain) -> Self {
        VaultPlain {
            engine: p.engine,
            handle: p.handle,
            node_url: p.node_url,
            channels_prefs: p.channels_prefs,
            photo: p.photo,
        }
    }
}

/// PRF salt of the unlock output, `SHA-256("soma-relay/unlock/v1")`.
#[uniffi::export]
pub fn prf_salt_unlock() -> Vec<u8> {
    core::vault::PRF_SALT_UNLOCK.to_vec()
}

/// PRF salt of the backup output, `SHA-256("soma-relay/backup/v1")`.
#[uniffi::export]
pub fn prf_salt_backup() -> Vec<u8> {
    core::vault::PRF_SALT_BACKUP.to_vec()
}

/// `HMAC-SHA256(unlock_key, "ok")`, stored to check the next unlock.
#[uniffi::export]
pub fn unlock_check(prf_first: Vec<u8>) -> std::result::Result<Vec<u8>, VaultError> {
    Ok(core::vault::unlock_check(&key32(&prf_first)?).to_vec())
}

#[uniffi::export]
pub fn vault_key(prf_second: Vec<u8>) -> std::result::Result<Vec<u8>, VaultError> {
    Ok(core::vault::vault_key(&key32(&prf_second)?).to_vec())
}

/// 64 lowercase hex characters, the path of `/v1/vault/{id}`.
#[uniffi::export]
pub fn vault_id(credential_id: Vec<u8>) -> String {
    core::vault::vault_id(&credential_id)
}

/// Drops a photo over 64 KiB, or any photo when the blob would pass 1 MiB; still too large
/// throws `TooLarge`.
#[uniffi::export]
pub fn seal_vault(
    key: Vec<u8>,
    id: String,
    plain: VaultPlain,
) -> std::result::Result<Vec<u8>, VaultError> {
    Ok(core::vault::seal_vault(&key32(&key)?, &id, &plain.into())?)
}

#[uniffi::export]
pub fn open_vault(
    key: Vec<u8>,
    id: String,
    blob: Vec<u8>,
) -> std::result::Result<VaultPlain, VaultError> {
    Ok(core::vault::open_vault(&key32(&key)?, &id, &blob)?.into())
}

#[uniffi::export]
impl RelayEngine {
    /// Ed25519 signature for `PUT /v1/vault/{id}` (`X-Relay-Sig` = base64 of it).
    pub fn sign_vault(&self, id: String, blob: Vec<u8>) -> Vec<u8> {
        self.lock().sign_vault(&id, &blob).to_vec()
    }
}

/// Result of `sign_directory_entry`.
#[derive(uniffi::Record, Debug, Clone)]
pub struct DirectoryEntry {
    pub card: String,
    pub sig: Vec<u8>,
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

/// `relaystate2:` text of `state` (`export_state()`), sealed with `passphrase` (Argon2id 64 MiB,
/// t 3, p 1, then AES-256-GCM). Takes about a second on a phone: call it off the main thread.
#[uniffi::export]
pub fn seal_export(passphrase: String, state: Vec<u8>) -> String {
    core::vault::seal_export(&passphrase, &state)
}

/// Engine state from a `.relaykey` text: `relaystate1:` without passphrase, `relaystate2:` with it
/// (`Passphrase` when missing or wrong). Other text throws `BadMagic`.
#[uniffi::export]
pub fn open_export(passphrase: Option<String>, text: String) -> std::result::Result<Vec<u8>, VaultError> {
    Ok(core::vault::open_export(passphrase.as_deref(), &text)?)
}

/// Shortest passphrase the app accepts for a new export.
#[uniffi::export]
pub fn export_min_passphrase() -> u32 {
    core::vault::EXPORT_MIN_PASSPHRASE as u32
}
