//! The outer wire unit, identical on every transport.

use serde::{Deserialize, Serialize};

use crate::error::{Result, malformed};
use crate::util::{from_postcard, to_postcard};

pub const KIND_DIRECT: u8 = 1;
pub const KIND_GROUP: u8 = 2;
pub const KIND_CHANNEL: u8 = 3;
pub const KIND_ANNOUNCE: u8 = 4;
pub const KIND_CONTROL: u8 = 5;
pub const DEFAULT_TTL: u8 = 7;
/// Largest envelope accepted by `open` (the reassembler caps mesh messages at 1 MiB).
pub const MAX_ENVELOPE: usize = 2 * 1024 * 1024;

#[derive(Clone, Serialize, Deserialize, PartialEq, Eq, Debug)]
pub struct Envelope {
    pub v: u8,
    pub kind: u8,
    pub tag: [u8; 16],
    pub ttl: u8,
    pub id: [u8; 16],
    pub body: Vec<u8>,
}

impl Envelope {
    pub fn to_bytes(&self) -> Vec<u8> {
        to_postcard(self)
    }

    pub fn from_bytes(bytes: &[u8]) -> Result<Envelope> {
        if bytes.len() > MAX_ENVELOPE {
            return Err(malformed("envelope too large"));
        }
        let e: Envelope = from_postcard(bytes, "envelope")?;
        if e.v != 1 {
            return Err(malformed("unsupported envelope version"));
        }
        if !(KIND_DIRECT..=KIND_CONTROL).contains(&e.kind) {
            return Err(malformed("unknown envelope kind"));
        }
        Ok(e)
    }
}
