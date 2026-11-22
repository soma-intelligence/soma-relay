//! Passkey vault (`docs/specs/2026-11-22-passkey-unlock-backup.md` section 3).
//!
//! Two WebAuthn PRF outputs drive everything: `prf_first` (salt `PRF_SALT_UNLOCK`) unlocks the
//! app through `unlock_check`, `prf_second` (salt `PRF_SALT_BACKUP`) gives `vault_key`, which
//! seals the backup blob stored on the node under `vault_id`.
//!
//! ```text
//! blob = "RVB1" || nonce(12) || AES-256-GCM(vault_key, nonce, postcard(VaultPlain), aad = vault_id ASCII)
//! ```

use argon2::{Algorithm, Argon2, Params, Version};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use zeroize::Zeroizing;

pub use crate::error::VaultError;
use crate::util::{Rng, b64url, hex, hkdf32, hmac, open, seal, to_postcard, unb64url};

/// `SHA-256("soma-relay/unlock/v1")`, the PRF salt whose output unlocks the app.
pub const PRF_SALT_UNLOCK: [u8; 32] = [
    0x57, 0x9d, 0xcf, 0x7e, 0x15, 0xec, 0x9e, 0xc8, 0x68, 0x29, 0x05, 0xd8, 0xb5, 0xd3, 0xe7, 0xab, 0x32, 0x33, 0x24,
    0x95, 0xaf, 0x68, 0xc9, 0x1d, 0xfa, 0x59, 0x0d, 0x88, 0xbb, 0x76, 0x0b, 0x56,
];

/// `SHA-256("soma-relay/backup/v1")`, the PRF salt whose output seals the backup.
pub const PRF_SALT_BACKUP: [u8; 32] = [
    0x38, 0x80, 0x2c, 0xe8, 0x79, 0x65, 0x5c, 0x02, 0x65, 0x2f, 0x3b, 0xcc, 0xc5, 0x43, 0x6e, 0x8d, 0x69, 0xd3, 0x41,
    0x44, 0x44, 0xe3, 0x62, 0x60, 0x5c, 0x92, 0xdf, 0x5d, 0xb5, 0xa8, 0x77, 0xf1,
];

/// Largest blob the node accepts (`MAX_VAULT_BYTES` in relay-node).
pub const MAX_VAULT_BYTES: usize = 1024 * 1024;

const MAGIC: &[u8; 4] = b"RVB1";
const NONCE_LEN: usize = 12;
const TAG_LEN: usize = 16;
const OVERHEAD: usize = MAGIC.len() + NONCE_LEN + TAG_LEN;
/// The only `VaultPlain::v` this version writes and reads. `seal_vault` sets it.
pub const VAULT_VERSION: u8 = 1;
/// Largest display photo kept in the vault; a larger one is dropped before sealing.
pub const MAX_PHOTO_BYTES: usize = 64 * 1024;
const SIG_DOMAIN: &[u8] = b"relay-vault-v1";

/// Plaintext of the backup blob, postcard encoded. Field order is part of the format.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct VaultPlain {
    pub v: u8,
    /// `RelayEngine::export_state()`.
    pub engine: Vec<u8>,
    pub handle: Option<String>,
    pub node_url: Option<String>,
    pub channels_prefs: Vec<u8>,
    pub photo: Option<Vec<u8>>,
}

/// `HMAC-SHA256(unlock_key, "ok")` with `unlock_key = HKDF-SHA256(prf_first, salt "", info "soma-relay unlock v1")`.
pub fn unlock_check(prf_first: &[u8; 32]) -> [u8; 32] {
    let unlock_key = Zeroizing::new(hkdf32(b"", prf_first, &[b"soma-relay unlock v1"]));
    hmac(&unlock_key[..], b"ok")
}

/// `HKDF-SHA256(prf_second, salt "", info "soma-relay vault v1", 32)`.
pub fn vault_key(prf_second: &[u8; 32]) -> [u8; 32] {
    hkdf32(b"", prf_second, &[b"soma-relay vault v1"])
}

/// `hex(SHA-256("soma-relay vault id v1" || credential_id))`, 64 lowercase hex characters.
pub fn vault_id(credential_id: &[u8]) -> String {
    let mut h = Sha256::new();
    h.update(b"soma-relay vault id v1");
    h.update(credential_id);
    hex(&h.finalize())
}

/// Seals `plain` with a fresh random nonce. `plain.v` is ignored and written as `VAULT_VERSION`.
/// A photo over `MAX_PHOTO_BYTES` is dropped; when the blob would still exceed `MAX_VAULT_BYTES`,
/// the photo is dropped and sealing retried; still too large gives `TooLarge`.
pub fn seal_vault(key: &[u8; 32], id: &str, plain: &VaultPlain) -> Result<Vec<u8>, VaultError> {
    seal_with(key, id, plain, Rng::os().bytes())
}

/// `seal_vault` with a caller-chosen nonce, for test vectors only.
#[cfg(any(test, feature = "testing"))]
pub fn seal_vault_with_nonce(
    key: &[u8; 32],
    id: &str,
    plain: &VaultPlain,
    nonce: [u8; NONCE_LEN],
) -> Result<Vec<u8>, VaultError> {
    seal_with(key, id, plain, nonce)
}

/// Borrowed mirror of `VaultPlain` with the same postcard encoding (a `&[u8]` encodes as a
/// `Vec<u8>`), so sealing never copies the engine state into a buffer that is not zeroized.
#[derive(Serialize)]
struct PlainRef<'a> {
    v: u8,
    engine: &'a [u8],
    handle: Option<&'a str>,
    node_url: Option<&'a str>,
    channels_prefs: &'a [u8],
    photo: Option<&'a [u8]>,
}

fn seal_with(key: &[u8; 32], id: &str, plain: &VaultPlain, nonce: [u8; NONCE_LEN]) -> Result<Vec<u8>, VaultError> {
    // Always the version `open_vault` reads, and never a photo over 64 KiB.
    let mut view = PlainRef {
        v: VAULT_VERSION,
        engine: &plain.engine,
        handle: plain.handle.as_deref(),
        node_url: plain.node_url.as_deref(),
        channels_prefs: &plain.channels_prefs,
        photo: plain.photo.as_deref().filter(|p| p.len() <= MAX_PHOTO_BYTES),
    };
    let mut body = Zeroizing::new(to_postcard(&view));
    if body.len() + OVERHEAD > MAX_VAULT_BYTES && view.photo.is_some() {
        view.photo = None;
        body = Zeroizing::new(to_postcard(&view));
    }
    if body.len() + OVERHEAD > MAX_VAULT_BYTES {
        return Err(VaultError::TooLarge);
    }
    Ok(seal_raw(key, id, &body, nonce))
}

fn seal_raw(key: &[u8; 32], id: &str, body: &[u8], nonce: [u8; NONCE_LEN]) -> Vec<u8> {
    let ct = seal(key, &nonce, id.as_bytes(), body);
    let mut out = Vec::with_capacity(OVERHEAD + body.len());
    out.extend_from_slice(MAGIC);
    out.extend_from_slice(&nonce);
    out.extend_from_slice(&ct);
    out
}

/// Opens a blob sealed by `seal_vault` for the same `id`.
pub fn open_vault(key: &[u8; 32], id: &str, blob: &[u8]) -> Result<VaultPlain, VaultError> {
    if blob.len() < OVERHEAD || &blob[..MAGIC.len()] != MAGIC {
        return Err(VaultError::BadMagic);
    }
    if blob.len() > MAX_VAULT_BYTES {
        return Err(VaultError::TooLarge);
    }
    let nonce: [u8; NONCE_LEN] = blob[MAGIC.len()..MAGIC.len() + NONCE_LEN].try_into().expect("length checked");
    let body = Zeroizing::new(
        open(key, &nonce, id.as_bytes(), &blob[MAGIC.len() + NONCE_LEN..]).map_err(|_| VaultError::Decrypt)?,
    );
    let plain: VaultPlain = postcard::from_bytes(&body).map_err(|_| VaultError::Parse)?;
    if plain.v != VAULT_VERSION {
        return Err(VaultError::Parse);
    }
    Ok(plain)
}

// ------------------------------------------------------------------ .relaykey export
//
// relaystate1:<b64url(state)>                          clear, read only (older exports)
// relaystate2:<b64url(salt16 || nonce12 || ct)>        ct = AES-256-GCM(k, nonce, state, aad "")
//                                                      k  = Argon2id(passphrase, salt, 64 MiB, t 3, p 1)

/// Prefix of the clear export written before v2. Still imported, never written.
pub const EXPORT_V1_PREFIX: &str = "relaystate1:";
/// Prefix of the passphrase sealed export.
pub const EXPORT_V2_PREFIX: &str = "relaystate2:";
/// Shortest passphrase the apps accept for a new export (the core itself does not refuse).
pub const EXPORT_MIN_PASSPHRASE: usize = 10;
const EXPORT_SALT_LEN: usize = 16;

fn export_key(passphrase: &str, salt: &[u8; EXPORT_SALT_LEN]) -> Zeroizing<[u8; 32]> {
    let params = Params::new(64 * 1024, 3, 1, Some(32)).expect("static argon2 params");
    let mut key = Zeroizing::new([0u8; 32]);
    Argon2::new(Algorithm::Argon2id, Version::V0x13, params)
        .hash_password_into(passphrase.as_bytes(), salt, &mut key[..])
        .expect("argon2 with a 16-byte salt and 32-byte output");
    key
}

/// `relaystate2:` text of `state` (`RelayEngine::export_state()`), sealed with `passphrase`.
pub fn seal_export(passphrase: &str, state: &[u8]) -> String {
    let mut rng = Rng::os();
    seal_export_with(passphrase, state, rng.bytes(), rng.bytes())
}

fn seal_export_with(passphrase: &str, state: &[u8], salt: [u8; EXPORT_SALT_LEN], nonce: [u8; NONCE_LEN]) -> String {
    let key = export_key(passphrase, &salt);
    let ct = seal(&key, &nonce, b"", state);
    let mut raw = Vec::with_capacity(EXPORT_SALT_LEN + NONCE_LEN + ct.len());
    raw.extend_from_slice(&salt);
    raw.extend_from_slice(&nonce);
    raw.extend_from_slice(&ct);
    format!("{EXPORT_V2_PREFIX}{}", b64url(&raw))
}

/// Engine state from a `.relaykey` text. `relaystate1:` needs no passphrase (one given is ignored);
/// `relaystate2:` gives `Passphrase` when it is missing or wrong. Anything else is `BadMagic`.
/// Surrounding whitespace is ignored.
pub fn open_export(passphrase: Option<&str>, text: &str) -> Result<Vec<u8>, VaultError> {
    let text = text.trim();
    if let Some(b64) = text.strip_prefix(EXPORT_V1_PREFIX) {
        return unb64url(b64).map_err(|_| VaultError::BadMagic);
    }
    let Some(b64) = text.strip_prefix(EXPORT_V2_PREFIX) else {
        return Err(VaultError::BadMagic);
    };
    let raw = unb64url(b64).map_err(|_| VaultError::BadMagic)?;
    if raw.len() < EXPORT_SALT_LEN + NONCE_LEN + TAG_LEN {
        return Err(VaultError::BadMagic);
    }
    let passphrase = passphrase.ok_or(VaultError::Passphrase)?;
    let salt: [u8; EXPORT_SALT_LEN] = raw[..EXPORT_SALT_LEN].try_into().expect("length checked");
    let nonce: [u8; NONCE_LEN] = raw[EXPORT_SALT_LEN..EXPORT_SALT_LEN + NONCE_LEN].try_into().expect("length checked");
    let key = export_key(passphrase, &salt);
    open(&key, &nonce, b"", &raw[EXPORT_SALT_LEN + NONCE_LEN..]).map_err(|_| VaultError::Passphrase)
}

/// Bytes the identity Ed25519 key signs for `PUT /v1/vault/{id}`:
/// `"relay-vault-v1" || id ASCII || SHA-256(blob)` (raw 32-byte digest).
pub fn vault_sig_message(id: &str, blob: &[u8]) -> Vec<u8> {
    let mut m = Vec::with_capacity(SIG_DOMAIN.len() + id.len() + 32);
    m.extend_from_slice(SIG_DOMAIN);
    m.extend_from_slice(id.as_bytes());
    m.extend_from_slice(&Sha256::digest(blob));
    m
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::engine::RelayEngine;
    use crate::util::{hex, unhex};
    use ed25519_dalek::{Signature, Verifier, VerifyingKey};
    use serde_json::Value;
    use sha2::{Digest, Sha256};

    const VECTORS: &str = include_str!("../../../docs/vectors/vault-v1.json");

    fn h(v: &Value, k: &str) -> Vec<u8> {
        unhex(v[k].as_str().unwrap_or_else(|| panic!("missing {k}"))).unwrap()
    }

    fn a32(b: Vec<u8>) -> [u8; 32] {
        b.try_into().unwrap()
    }

    fn sample() -> VaultPlain {
        VaultPlain {
            v: 1,
            engine: vec![7; 300],
            handle: Some("alice".into()),
            node_url: Some("https://relay.somalabs.me".into()),
            channels_prefs: b"{}".to_vec(),
            photo: None,
        }
    }

    #[test]
    fn salts_match_spec() {
        assert_eq!(PRF_SALT_UNLOCK, <[u8; 32]>::from(Sha256::digest(b"soma-relay/unlock/v1")));
        assert_eq!(PRF_SALT_BACKUP, <[u8; 32]>::from(Sha256::digest(b"soma-relay/backup/v1")));
    }

    #[test]
    fn vectors_v1() {
        let v: Value = serde_json::from_str(VECTORS).unwrap();
        assert_eq!(hex(&PRF_SALT_UNLOCK), v["prf_salt_unlock"].as_str().unwrap());
        assert_eq!(hex(&PRF_SALT_BACKUP), v["prf_salt_backup"].as_str().unwrap());
        let first = a32(h(&v, "prf_first"));
        let second = a32(h(&v, "prf_second"));
        let cred = h(&v, "credential_id");
        let nonce: [u8; 12] = h(&v, "nonce").try_into().unwrap();
        assert_eq!(hex(&unlock_check(&first)), v["unlock_check"].as_str().unwrap());
        let key = vault_key(&second);
        assert_eq!(hex(&key), v["vault_key"].as_str().unwrap());
        let id = vault_id(&cred);
        assert_eq!(id, v["vault_id"].as_str().unwrap());
        let p = &v["plain"];
        let plain = VaultPlain {
            v: p["v"].as_u64().unwrap() as u8,
            engine: h(p, "engine"),
            handle: p["handle"].as_str().map(String::from),
            node_url: p["node_url"].as_str().map(String::from),
            channels_prefs: h(p, "channels_prefs"),
            photo: p["photo"].as_str().map(|s| unhex(s).unwrap()),
        };
        assert_eq!(hex(&crate::util::to_postcard(&plain)), v["plain_postcard"].as_str().unwrap());
        let blob = seal_vault_with_nonce(&key, &id, &plain, nonce).unwrap();
        assert_eq!(hex(&blob), v["blob"].as_str().unwrap());
        assert_eq!(open_vault(&key, &id, &blob).unwrap(), plain);
        assert_eq!(hex(&vault_sig_message(&id, &blob)), v["sig_message"].as_str().unwrap());
    }

    #[test]
    fn seal_open_roundtrip() {
        let key = vault_key(&[3; 32]);
        let id = vault_id(b"cred");
        let plain = VaultPlain { photo: Some(vec![9; 1000]), ..sample() };
        let a = seal_vault(&key, &id, &plain).unwrap();
        let b = seal_vault(&key, &id, &plain).unwrap();
        assert_eq!(&a[..4], b"RVB1");
        assert_ne!(a, b, "fresh nonce per seal");
        assert_eq!(open_vault(&key, &id, &a).unwrap(), plain);
        assert_eq!(open_vault(&vault_key(&[4; 32]), &id, &a), Err(VaultError::Decrypt));
    }

    #[test]
    fn vault_id_is_lowercase_hex_64() {
        let id = vault_id(&[0xAB; 16]);
        assert_eq!(id.len(), 64);
        assert!(id.bytes().all(|c| c.is_ascii_digit() || (b'a'..=b'f').contains(&c)));
    }

    #[test]
    fn wrong_id_rejected() {
        let key = vault_key(&[3; 32]);
        let blob = seal_vault(&key, &vault_id(b"one"), &sample()).unwrap();
        assert_eq!(open_vault(&key, &vault_id(b"two"), &blob), Err(VaultError::Decrypt));
    }

    #[test]
    fn bad_magic_rejected() {
        let key = vault_key(&[3; 32]);
        let id = vault_id(b"one");
        let mut blob = seal_vault(&key, &id, &sample()).unwrap();
        blob[0] = b'X';
        assert_eq!(open_vault(&key, &id, &blob), Err(VaultError::BadMagic));
        assert_eq!(open_vault(&key, &id, b"RVB"), Err(VaultError::BadMagic));
        let mut tampered = seal_vault(&key, &id, &sample()).unwrap();
        let last = tampered.len() - 1;
        tampered[last] ^= 1;
        assert_eq!(open_vault(&key, &id, &tampered), Err(VaultError::Decrypt));
    }

    #[test]
    fn too_large_drops_photo_then_fails() {
        let key = vault_key(&[3; 32]);
        let id = vault_id(b"one");
        let big = VaultPlain { engine: vec![1; 200 * 1024], photo: Some(vec![2; 900 * 1024]), ..sample() };
        let blob = seal_vault(&key, &id, &big).unwrap();
        assert!(blob.len() <= MAX_VAULT_BYTES);
        let opened = open_vault(&key, &id, &blob).unwrap();
        assert_eq!(opened.photo, None);
        assert_eq!(opened.engine, big.engine);
        let huge = VaultPlain { engine: vec![1; 1100 * 1024], photo: None, ..sample() };
        assert_eq!(seal_vault(&key, &id, &huge), Err(VaultError::TooLarge));
        let huge_photo = VaultPlain { photo: Some(vec![2; 10]), ..huge };
        assert_eq!(seal_vault(&key, &id, &huge_photo), Err(VaultError::TooLarge));
    }

    #[test]
    fn parse_error_on_garbage_plaintext() {
        let key = vault_key(&[3; 32]);
        let id = vault_id(b"one");
        let blob = seal_raw(&key, &id, &[0xFF; 3], [0; 12]);
        assert_eq!(open_vault(&key, &id, &blob), Err(VaultError::Parse));
    }

    #[test]
    fn sign_vault_verifies() {
        let e = RelayEngine::create_with_seed("v".into(), [5; 32]);
        let id = vault_id(b"cred");
        let blob = seal_vault(&vault_key(&[3; 32]), &id, &sample()).unwrap();
        let sig = e.sign_vault(&id, &blob);
        // Same bytes the node verifies in crates/relay-node/src/vault.rs.
        let mut msg = b"relay-vault-v1".to_vec();
        msg.extend(id.as_bytes());
        msg.extend(Sha256::digest(&blob));
        assert_eq!(vault_sig_message(&id, &blob), msg);
        let pk: [u8; 32] = e.device_signing_public().try_into().unwrap();
        let vk = VerifyingKey::from_bytes(&pk).unwrap();
        assert!(vk.verify(&msg, &Signature::from_bytes(&sig)).is_ok());
        assert!(vk.verify(b"other", &Signature::from_bytes(&sig)).is_err());
    }

    #[test]
    fn plain_ref_encodes_like_vault_plain() {
        let p = VaultPlain { photo: Some(vec![1, 2, 3]), ..sample() };
        let view = PlainRef {
            v: p.v,
            engine: &p.engine,
            handle: p.handle.as_deref(),
            node_url: p.node_url.as_deref(),
            channels_prefs: &p.channels_prefs,
            photo: p.photo.as_deref(),
        };
        assert_eq!(crate::util::to_postcard(&view), crate::util::to_postcard(&p));
        let none = VaultPlain { handle: None, node_url: None, photo: None, ..sample() };
        let view = PlainRef { handle: None, node_url: None, photo: None, ..view };
        let view = PlainRef { engine: &none.engine, channels_prefs: &none.channels_prefs, ..view };
        assert_eq!(crate::util::to_postcard(&view), crate::util::to_postcard(&none));
    }

    #[test]
    fn seal_forces_version() {
        let key = vault_key(&[3; 32]);
        let id = vault_id(b"one");
        let plain = VaultPlain { v: 7, ..sample() };
        let blob = seal_vault(&key, &id, &plain).unwrap();
        let opened = open_vault(&key, &id, &blob).unwrap();
        assert_eq!(opened.v, VAULT_VERSION);
        assert_eq!(opened, VaultPlain { v: VAULT_VERSION, ..plain });
    }

    #[test]
    fn photo_over_64k_dropped() {
        let key = vault_key(&[3; 32]);
        let id = vault_id(b"one");
        let at_limit = VaultPlain { photo: Some(vec![5; MAX_PHOTO_BYTES]), ..sample() };
        let opened = open_vault(&key, &id, &seal_vault(&key, &id, &at_limit).unwrap()).unwrap();
        assert_eq!(opened.photo.as_deref().map(<[u8]>::len), Some(65536));
        let over = VaultPlain { photo: Some(vec![5; MAX_PHOTO_BYTES + 1]), ..sample() };
        let opened = open_vault(&key, &id, &seal_vault(&key, &id, &over).unwrap()).unwrap();
        assert_eq!(opened.photo, None);
        assert_eq!(opened.engine, over.engine);
    }

    #[test]
    fn export_v2_roundtrip() {
        let state = b"engine state bytes".to_vec();
        let text = seal_export("correct horse battery", &state);
        assert!(text.starts_with("relaystate2:"));
        let raw = crate::util::unb64url(&text["relaystate2:".len()..]).unwrap();
        assert_eq!(raw.len(), 16 + 12 + state.len() + 16, "salt16 || nonce12 || ct");
        assert_ne!(seal_export("correct horse battery", &state), text, "fresh salt and nonce");
        assert_eq!(open_export(Some("correct horse battery"), &text).unwrap(), state);
        // A file read back may carry a trailing newline.
        assert_eq!(open_export(Some("correct horse battery"), &format!("{text}\n")).unwrap(), state);
    }

    #[test]
    fn export_v2_wrong_passphrase() {
        let text = seal_export("correct horse battery", b"state");
        assert_eq!(open_export(Some("correct horse batterz"), &text), Err(VaultError::Passphrase));
        assert_eq!(open_export(Some(""), &text), Err(VaultError::Passphrase));
    }

    #[test]
    fn export_v2_needs_passphrase() {
        let text = seal_export("correct horse battery", b"state");
        assert_eq!(open_export(None, &text), Err(VaultError::Passphrase));
    }

    #[test]
    fn export_v1_still_imports() {
        let state = vec![1, 2, 3, 250, 251, 252];
        let text = format!("relaystate1:{}", crate::util::b64url(&state));
        assert_eq!(open_export(None, &text).unwrap(), state);
        assert_eq!(open_export(Some("ignored passphrase"), &text).unwrap(), state);
    }

    #[test]
    fn export_rejects_other_text() {
        assert_eq!(open_export(None, "hello"), Err(VaultError::BadMagic));
        assert_eq!(open_export(None, "relaystate1:!!!"), Err(VaultError::BadMagic));
        assert_eq!(open_export(Some("x"), "relaystate2:AAAA"), Err(VaultError::BadMagic));
        assert_eq!(open_export(Some("x"), "relaystate3:AAAA"), Err(VaultError::BadMagic));
    }

    /// Regenerates `docs/vectors/vault-v1.json`:
    /// `cargo test -p relay-core print_vault_vectors -- --ignored --nocapture`.
    #[test]
    #[ignore]
    fn print_vault_vectors() {
        let first: [u8; 32] = core::array::from_fn(|i| i as u8);
        let second: [u8; 32] = core::array::from_fn(|i| 0x80 + i as u8);
        let cred: Vec<u8> = (0..16u8).map(|i| 0xc0 + i).collect();
        let nonce: [u8; 12] = core::array::from_fn(|i| 0xa0 + i as u8);
        let plain = VaultPlain {
            v: 1,
            engine: b"engine-state".to_vec(),
            handle: Some("alice".into()),
            node_url: Some("https://relay.somalabs.me".into()),
            channels_prefs: b"{\"muted\":[]}".to_vec(),
            photo: Some(vec![0xff, 0xd8, 0xff, 0xe0]),
        };
        let key = vault_key(&second);
        let id = vault_id(&cred);
        let blob = seal_vault_with_nonce(&key, &id, &plain, nonce).unwrap();
        let v = serde_json::json!({
            "description": "Soma Relay passkey vault v1 (docs/specs/2026-11-22-passkey-unlock-backup.md section 3). All bytes are lowercase hex.",
            "prf_salt_unlock": hex(&PRF_SALT_UNLOCK),
            "prf_salt_backup": hex(&PRF_SALT_BACKUP),
            "prf_first": hex(&first),
            "prf_second": hex(&second),
            "credential_id": hex(&cred),
            "nonce": hex(&nonce),
            "plain": {
                "v": plain.v,
                "engine": hex(&plain.engine),
                "handle": plain.handle,
                "node_url": plain.node_url,
                "channels_prefs": hex(&plain.channels_prefs),
                "photo": plain.photo.as_deref().map(hex),
            },
            "plain_postcard": hex(&crate::util::to_postcard(&plain)),
            "unlock_check": hex(&unlock_check(&first)),
            "vault_key": hex(&key),
            "vault_id": id,
            "blob": hex(&blob),
            "sig_message": hex(&vault_sig_message(&id, &blob)),
        });
        println!("{}", serde_json::to_string_pretty(&v).unwrap());
    }
}
