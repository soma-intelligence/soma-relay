//! Attachments: AES-256-GCM in 64 KiB chunks, nonce = chunk index,
//! AAD = sha256(plaintext) || index (u32 BE) || last flag.

use zeroize::Zeroizing;

use crate::error::{RelayError, Result};
use crate::util::{Rng, ct_eq, open, seal, sha256};

pub const CHUNK: usize = 64 * 1024;
const TAG: usize = 16;

fn nonce(index: u32) -> [u8; 12] {
    let mut n = [0u8; 12];
    n[8..].copy_from_slice(&index.to_be_bytes());
    n
}

fn aad(sha: &[u8; 32], index: u32, last: bool) -> [u8; 37] {
    let mut a = [0u8; 37];
    a[..32].copy_from_slice(sha);
    a[32..36].copy_from_slice(&index.to_be_bytes());
    a[36] = u8::from(last);
    a
}

/// Returns `key(32) || sha256(32) || ciphertext`.
pub fn seal_attachment(plain: &[u8], rng: &mut Rng) -> Vec<u8> {
    let key = Zeroizing::new(rng.bytes::<32>());
    let sha = sha256(plain);
    let chunks: Vec<&[u8]> = if plain.is_empty() { vec![&[][..]] } else { plain.chunks(CHUNK).collect() };
    let mut out = Vec::with_capacity(64 + plain.len() + chunks.len() * TAG);
    out.extend_from_slice(&key[..]);
    out.extend_from_slice(&sha);
    let last_i = chunks.len() - 1;
    for (i, c) in chunks.iter().enumerate() {
        let idx = i as u32;
        out.extend_from_slice(&seal(&key, &nonce(idx), &aad(&sha, idx, i == last_i), c));
    }
    out
}

pub fn open_attachment(key: &[u8], sha: &[u8], ct: &[u8]) -> Result<Vec<u8>> {
    let key: [u8; 32] = key.try_into().map_err(|_| RelayError::Malformed("key must be 32 bytes".into()))?;
    let key = Zeroizing::new(key);
    let sha: [u8; 32] = sha.try_into().map_err(|_| RelayError::Malformed("sha256 must be 32 bytes".into()))?;
    if ct.len() < TAG {
        return Err(RelayError::Malformed("ciphertext too short".into()));
    }
    let chunks: Vec<&[u8]> = ct.chunks(CHUNK + TAG).collect();
    if chunks.len() > u32::MAX as usize || chunks.last().is_some_and(|c| c.len() < TAG) {
        return Err(RelayError::Malformed("bad attachment framing".into()));
    }
    let last_i = chunks.len() - 1;
    let mut out = Vec::with_capacity(ct.len());
    for (i, c) in chunks.iter().enumerate() {
        let idx = i as u32;
        out.extend_from_slice(&open(&key, &nonce(idx), &aad(&sha, idx, i == last_i), c)?);
    }
    if !ct_eq(&sha256(&out), &sha) {
        return Err(RelayError::Decrypt("attachment hash mismatch".into()));
    }
    Ok(out)
}
