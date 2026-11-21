//! Small shared helpers: randomness, KDFs, AEAD, encodings, padding.

use aes_gcm::aead::{Aead, KeyInit, Payload};
use aes_gcm::{Aes256Gcm, Nonce};
use base64::Engine as _;
use hkdf::Hkdf;
use hmac::{Hmac, Mac};
use sha2::Sha256;
use sha3::digest::{ExtendableOutput, Update, XofReader};
use sha3::{Digest, Sha3_256, Shake256};
use subtle::ConstantTimeEq;
use zeroize::{Zeroize, Zeroizing};

use crate::error::{RelayError, Result, decrypt_err, malformed};

/// Randomness source. The OS generator in production; a SHAKE256 stream for
/// deterministic tests (`create_with_seed`).
#[derive(Default)]
pub struct Rng {
    seeded: Option<(Zeroizing<[u8; 32]>, u64)>,
}

impl Rng {
    pub fn os() -> Self {
        Rng { seeded: None }
    }

    pub fn seeded(seed: [u8; 32]) -> Self {
        Rng { seeded: Some((Zeroizing::new(seed), 0)) }
    }

    pub fn fill(&mut self, buf: &mut [u8]) {
        match &mut self.seeded {
            Some((seed, counter)) => {
                let mut h = Shake256::default();
                h.update(b"soma-relay/test-rng");
                h.update(&seed[..]);
                h.update(&counter.to_le_bytes());
                *counter += 1;
                h.finalize_xof().read(buf);
            }
            None => {
                // No recovery is possible without entropy; this never fails on the
                // supported targets (iOS, macOS, browsers).
                getrandom::fill(buf).expect("OS random generator unavailable");
            }
        }
    }

    pub fn bytes<const N: usize>(&mut self) -> [u8; N] {
        let mut out = [0u8; N];
        self.fill(&mut out);
        out
    }
}

pub fn sha3(parts: &[&[u8]]) -> [u8; 32] {
    let mut h = Sha3_256::new();
    for p in parts {
        Digest::update(&mut h, p);
    }
    h.finalize().into()
}

pub fn sha256(data: &[u8]) -> [u8; 32] {
    let mut h = Sha256::new();
    Digest::update(&mut h, data);
    h.finalize().into()
}

/// HKDF-SHA256 with an explicit output length.
pub fn hkdf(salt: &[u8], ikm: &[u8], info: &[&[u8]], out: &mut [u8]) {
    let hk = Hkdf::<Sha256>::new(Some(salt), ikm);
    let info: Vec<u8> = info.concat();
    // Output lengths used in this crate are far below the 255*32 HKDF limit.
    hk.expand(&info, out).expect("hkdf output length");
}

pub fn hkdf32(salt: &[u8], ikm: &[u8], info: &[&[u8]]) -> [u8; 32] {
    let mut out = [0u8; 32];
    hkdf(salt, ikm, info, &mut out);
    out
}

pub fn hmac(key: &[u8], data: &[u8]) -> [u8; 32] {
    let mut m = <Hmac<Sha256> as Mac>::new_from_slice(key).expect("hmac accepts any key length");
    Mac::update(&mut m, data);
    m.finalize().into_bytes().into()
}

pub fn ct_eq(a: &[u8], b: &[u8]) -> bool {
    a.len() == b.len() && bool::from(a.ct_eq(b))
}

pub fn seal(key: &[u8; 32], nonce: &[u8; 12], aad: &[u8], plain: &[u8]) -> Vec<u8> {
    let cipher = Aes256Gcm::new(key.into());
    cipher
        .encrypt(Nonce::from_slice(nonce), Payload { msg: plain, aad })
        .expect("AES-GCM encryption of an in-memory buffer")
}

pub fn open(key: &[u8; 32], nonce: &[u8; 12], aad: &[u8], ct: &[u8]) -> Result<Vec<u8>> {
    let cipher = Aes256Gcm::new(key.into());
    cipher.decrypt(Nonce::from_slice(nonce), Payload { msg: ct, aad }).map_err(|_| decrypt_err())
}

/// Derives an AES key and nonce from a one-time message key.
pub fn message_key_material(mk: &[u8; 32], info: &[u8]) -> (Zeroizing<[u8; 32]>, [u8; 12]) {
    let mut okm = Zeroizing::new([0u8; 44]);
    hkdf(&[0u8; 32], mk, &[info], &mut okm[..]);
    let mut key = Zeroizing::new([0u8; 32]);
    key.copy_from_slice(&okm[..32]);
    let mut nonce = [0u8; 12];
    nonce.copy_from_slice(&okm[32..]);
    (key, nonce)
}

pub fn hex(bytes: &[u8]) -> String {
    const H: &[u8; 16] = b"0123456789abcdef";
    let mut s = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        s.push(H[(b >> 4) as usize] as char);
        s.push(H[(b & 15) as usize] as char);
    }
    s
}

pub fn unhex(s: &str) -> Result<Vec<u8>> {
    let s = s.trim();
    if !s.len().is_multiple_of(2) {
        return Err(malformed("odd hex length"));
    }
    let val = |c: u8| -> Result<u8> {
        match c {
            b'0'..=b'9' => Ok(c - b'0'),
            b'a'..=b'f' => Ok(c - b'a' + 10),
            b'A'..=b'F' => Ok(c - b'A' + 10),
            _ => Err(malformed("bad hex digit")),
        }
    };
    s.as_bytes().chunks(2).map(|p| Ok((val(p[0])? << 4) | val(p[1])?)).collect()
}

pub fn fp_from_hex(s: &str) -> Result<[u8; 32]> {
    let v = unhex(s)?;
    v.try_into().map_err(|_| RelayError::Malformed("fingerprint must be 32 bytes".into()))
}

pub fn b64url(bytes: &[u8]) -> String {
    base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(bytes)
}

pub fn unb64url(s: &str) -> Result<Vec<u8>> {
    base64::engine::general_purpose::URL_SAFE_NO_PAD
        .decode(s.trim().trim_end_matches('='))
        .map_err(|_| malformed("bad base64url"))
}

pub fn b64(bytes: &[u8]) -> String {
    base64::engine::general_purpose::STANDARD.encode(bytes)
}

/// Padding buckets of envelope bodies: 256 B, 1 KiB, 4 KiB, 16 KiB, 64 KiB, then n * 64 KiB.
pub fn bucket(len: usize) -> usize {
    for b in [256usize, 1024, 4096, 16384, 65536] {
        if len <= b {
            return b;
        }
    }
    len.div_ceil(65536) * 65536
}

/// `u32 LE length || payload || zeros` up to the bucket.
pub fn pad(payload: &[u8]) -> Vec<u8> {
    let total = bucket(payload.len() + 4);
    let mut out = Vec::with_capacity(total);
    out.extend_from_slice(&(payload.len() as u32).to_le_bytes());
    out.extend_from_slice(payload);
    out.resize(total, 0);
    out
}

pub fn unpad(body: &[u8]) -> Result<&[u8]> {
    if body.len() < 4 {
        return Err(malformed("short body"));
    }
    let len = u32::from_le_bytes([body[0], body[1], body[2], body[3]]) as usize;
    body.get(4..4usize.saturating_add(len)).ok_or_else(|| malformed("bad padding length"))
}

pub fn to_postcard<T: serde::Serialize>(v: &T) -> Vec<u8> {
    postcard::to_allocvec(v).expect("postcard serialisation of an in-memory value")
}

pub fn from_postcard<'a, T: serde::Deserialize<'a>>(b: &'a [u8], what: &str) -> Result<T> {
    postcard::from_bytes(b).map_err(|_| malformed(format!("bad {what}")))
}

/// Wipes a byte vector before dropping it.
pub fn wipe(mut v: Vec<u8>) {
    v.zeroize();
}
