//! Local public channels (`#festival`): not end-to-end encrypted, Ed25519 signed.
//! An optional password derives the key with Argon2id once, on join.

use argon2::{Algorithm, Argon2, Params, Version};
use serde::{Deserialize, Serialize};
use zeroize::{Zeroize, Zeroizing};

use crate::error::{RelayError, Result};
use crate::hybrid::ed_verify;
use crate::util::{hkdf32, open, seal, sha256, sha3};

pub const RATE_PER_MINUTE: u32 = 30;
const SIG_DOMAIN: &[u8] = b"soma-relay/v1/channel";

#[derive(Clone, Serialize, Deserialize)]
pub struct Channel {
    pub name: String,
    pub key: [u8; 32],
    pub tag: [u8; 16],
    pub password: bool,
}

impl Drop for Channel {
    fn drop(&mut self) {
        self.key.zeroize();
    }
}

pub fn normalize(name: &str) -> String {
    name.trim().trim_start_matches('#').trim().to_lowercase()
}

impl Channel {
    pub fn derive(name: &str, password: Option<&str>) -> Result<Channel> {
        let name = normalize(name);
        if name.is_empty() || name.len() > 64 {
            return Err(RelayError::Malformed("channel name must be 1 to 64 bytes".into()));
        }
        let mut ikm = Zeroizing::new(name.as_bytes().to_vec());
        let has_pw = password.is_some_and(|p| !p.is_empty());
        if let Some(pw) = password.filter(|p| !p.is_empty()) {
            // OWASP Argon2id baseline: 19 MiB, 2 passes, 1 lane. Computed once per join.
            let params = Params::new(19 * 1024, 2, 1, Some(32)).map_err(|_| RelayError::Malformed("argon2 params".into()))?;
            let salt = sha256(format!("soma-relay/channel/{name}").as_bytes());
            let mut out = Zeroizing::new([0u8; 32]);
            Argon2::new(Algorithm::Argon2id, Version::V0x13, params)
                .hash_password_into(pw.as_bytes(), &salt, &mut out[..])
                .map_err(|_| RelayError::Malformed("argon2 failed".into()))?;
            ikm.extend_from_slice(&out[..]);
        }
        let key = hkdf32(&[0u8; 32], &ikm, &[b"soma-relay/v1/channel-key"]);
        let h = sha3(&[b"soma-relay/v1/channel-tag", &key]);
        let mut tag = [0u8; 16];
        tag.copy_from_slice(&h[..16]);
        Ok(Channel { name, key, tag, password: has_pw })
    }
}

#[derive(Clone, Serialize, Deserialize, Debug)]
pub struct ChannelMsg {
    pub fp: [u8; 32],
    pub ed_pub: [u8; 32],
    pub nonce: [u8; 12],
    pub ct: Vec<u8>,
    pub sig: Vec<u8>,
}

fn signed(tag: &[u8; 16], fp: &[u8; 32], nonce: &[u8; 12], ct: &[u8]) -> Vec<u8> {
    let mut m = SIG_DOMAIN.to_vec();
    m.extend_from_slice(tag);
    m.extend_from_slice(fp);
    m.extend_from_slice(nonce);
    m.extend_from_slice(ct);
    m
}

impl ChannelMsg {
    pub fn build(ch: &Channel, fp: [u8; 32], ed_pub: [u8; 32], sign: impl Fn(&[u8]) -> [u8; 64], nonce: [u8; 12], plain: &[u8]) -> ChannelMsg {
        let ct = seal(&ch.key, &nonce, &ch.tag, plain);
        let sig = sign(&signed(&ch.tag, &fp, &nonce, &ct)).to_vec();
        ChannelMsg { fp, ed_pub, nonce, ct, sig }
    }

    pub fn open(&self, ch: &Channel) -> Result<Vec<u8>> {
        if !ed_verify(&self.ed_pub, &signed(&ch.tag, &self.fp, &self.nonce, &self.ct), &self.sig) {
            return Err(RelayError::Decrypt("channel signature does not verify".into()));
        }
        open(&ch.key, &self.nonce, &ch.tag, &self.ct)
    }
}
