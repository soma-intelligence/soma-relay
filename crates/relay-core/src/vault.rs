//! Passkey vault (`docs/specs/2026-11-22-passkey-unlock-backup.md` section 3).
//!
//! Two WebAuthn PRF outputs drive everything: `prf_first` (salt `PRF_SALT_UNLOCK`) unlocks the
//! app through `unlock_check`, `prf_second` (salt `PRF_SALT_BACKUP`) gives `vault_key`, which
//! seals the backup blob stored on the node under `vault_id`.
//!
//! ```text
//! blob = "RVB1" || nonce(12) || AES-256-GCM(vault_key, nonce, postcard(VaultPlain), aad = vault_id ASCII)
//! ```

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use zeroize::Zeroizing;

pub use crate::error::VaultError;
use crate::util::{Rng, hex, hkdf32, hmac, open, seal, to_postcard};

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
const VAULT_VERSION: u8 = 1;
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

/// Seals `plain` with a fresh random nonce. When the blob would exceed `MAX_VAULT_BYTES`,
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

fn seal_with(key: &[u8; 32], id: &str, plain: &VaultPlain, nonce: [u8; NONCE_LEN]) -> Result<Vec<u8>, VaultError> {
    let mut body = Zeroizing::new(to_postcard(plain));
    if body.len() + OVERHEAD > MAX_VAULT_BYTES && plain.photo.is_some() {
        body = Zeroizing::new(to_postcard(&VaultPlain { photo: None, ..plain.clone() }));
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
