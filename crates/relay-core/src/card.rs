//! Contact cards (`relay1:`) and compact links (`relay1c:`).

use serde::{Deserialize, Serialize};

use crate::error::{RelayError, Result};
use crate::hybrid::{HybridSig, MLDSA_PUB_LEN, MLKEM_PUB_LEN, hybrid_verify, valid_kem_public};
use crate::util::{b64url, from_postcard, sha3, to_postcard, unb64url};

pub const CARD_PREFIX: &str = "relay1:";
pub const COMPACT_PREFIX: &str = "relay1c:";
const CARD_DOMAIN: &[u8] = b"soma-relay/v1/card";
const MAX_CARD_TEXT: usize = 64 * 1024;
const MAX_NAME: usize = 128;
const MAX_URL: usize = 512;
const MAX_HANDLE: usize = 128;

#[derive(Clone, Serialize, Deserialize, PartialEq, Eq, Debug)]
pub struct CardBody {
    pub v: u8,
    pub name: String,
    pub ed_pub: [u8; 32],
    pub dsa_pub: Vec<u8>,
    pub dev_x: [u8; 32],
    pub dev_kem: Vec<u8>,
    pub spk_id: u32,
    pub spk_x: [u8; 32],
    pub spk_kem: Vec<u8>,
    pub node_url: Option<String>,
    pub handle: Option<String>,
    pub created_at: i64,
}

#[derive(Clone, Serialize, Deserialize, PartialEq, Eq, Debug)]
pub struct Card {
    pub body: CardBody,
    pub sig: HybridSig,
}

pub fn fingerprint(ed_pub: &[u8; 32], dsa_pub: &[u8]) -> [u8; 32] {
    sha3(&[ed_pub, dsa_pub])
}

pub fn mailbox(fp: &[u8; 32]) -> [u8; 16] {
    let h = sha3(&[b"soma-relay/mailbox", fp]);
    let mut m = [0u8; 16];
    m.copy_from_slice(&h[..16]);
    m
}

pub fn signed_message(body: &CardBody) -> Vec<u8> {
    let mut m = CARD_DOMAIN.to_vec();
    m.extend_from_slice(&to_postcard(body));
    m
}

impl Card {
    pub fn fingerprint(&self) -> [u8; 32] {
        fingerprint(&self.body.ed_pub, &self.body.dsa_pub)
    }

    /// Checks sizes, key validity and the hybrid signature.
    pub fn verify(&self) -> Result<()> {
        let b = &self.body;
        let bad = |m: &str| Err(RelayError::InvalidCard(m.into()));
        if b.v != 1 {
            return bad("unsupported card version");
        }
        if b.dsa_pub.len() != MLDSA_PUB_LEN || b.dev_kem.len() != MLKEM_PUB_LEN || b.spk_kem.len() != MLKEM_PUB_LEN {
            return bad("bad key length");
        }
        if b.name.chars().count() > MAX_NAME
            || b.node_url.as_ref().is_some_and(|u| u.len() > MAX_URL)
            || b.handle.as_ref().is_some_and(|h| h.len() > MAX_HANDLE)
        {
            return bad("field too long");
        }
        if !valid_kem_public(&b.dev_kem) || !valid_kem_public(&b.spk_kem) {
            return bad("invalid ML-KEM key");
        }
        if !hybrid_verify(&b.ed_pub, &b.dsa_pub, &signed_message(b), &self.sig) {
            return bad("signature does not verify");
        }
        Ok(())
    }

    pub fn to_bytes(&self) -> Vec<u8> {
        to_postcard(self)
    }

    pub fn from_bytes(bytes: &[u8]) -> Result<Card> {
        let card: Card = from_postcard(bytes, "card").map_err(|_| RelayError::InvalidCard("card does not parse".into()))?;
        card.verify()?;
        Ok(card)
    }

    pub fn to_text(&self) -> String {
        format!("{CARD_PREFIX}{}", b64url(&self.to_bytes()))
    }

    pub fn parse(text: &str) -> Result<Card> {
        let text = text.trim();
        if text.len() > MAX_CARD_TEXT {
            return Err(RelayError::InvalidCard("card too large".into()));
        }
        let rest = text
            .strip_prefix(CARD_PREFIX)
            .ok_or_else(|| RelayError::InvalidCard("expected relay1: card".into()))?;
        let bytes = unb64url(rest).map_err(|_| RelayError::InvalidCard("bad base64url".into()))?;
        Card::from_bytes(&bytes)
    }

    /// Same identity and device keys (the parts a key change would alter).
    pub fn same_keys(&self, other: &Card) -> bool {
        self.body.ed_pub == other.body.ed_pub
            && self.body.dsa_pub == other.body.dsa_pub
            && self.body.dev_x == other.body.dev_x
            && self.body.dev_kem == other.body.dev_kem
    }
}

#[derive(Clone, Serialize, Deserialize, PartialEq, Eq, Debug)]
pub struct Compact {
    pub fingerprint: [u8; 32],
    pub node_url: Option<String>,
    pub handle: Option<String>,
}

impl Compact {
    pub fn to_text(&self) -> String {
        format!("{COMPACT_PREFIX}{}", b64url(&to_postcard(self)))
    }

    pub fn parse(text: &str) -> Result<Compact> {
        let text = text.trim();
        if text.len() > 4096 {
            return Err(RelayError::InvalidCard("link too large".into()));
        }
        let rest = text
            .strip_prefix(COMPACT_PREFIX)
            .ok_or_else(|| RelayError::InvalidCard("expected relay1c: link".into()))?;
        let bytes = unb64url(rest).map_err(|_| RelayError::InvalidCard("bad base64url".into()))?;
        let c: Compact = from_postcard(&bytes, "link").map_err(|_| RelayError::InvalidCard("link does not parse".into()))?;
        if c.node_url.as_ref().is_some_and(|u| u.len() > MAX_URL) || c.handle.as_ref().is_some_and(|h| h.len() > MAX_HANDLE) {
            return Err(RelayError::InvalidCard("field too long".into()));
        }
        Ok(c)
    }
}
