//! Mesh fragmentation, reassembly and flooding router (sans-IO).
//!
//! Frame = `ver(1) || hops_left(1) || id(16) || index(u16 BE) || count(u16 BE) || payload`.

use std::collections::{BTreeSet, HashMap, VecDeque};

use crate::envelope::{DEFAULT_TTL, Envelope};
use crate::util::sha3;

pub const FRAME_VERSION: u8 = 1;
pub const HEADER_LEN: usize = 22;
pub const MAX_ASSEMBLIES: usize = 128;
pub const ASSEMBLY_TIMEOUT_MS: i64 = 30_000;
pub const MAX_MESSAGE: usize = 1024 * 1024;
pub const SEEN_CAP: usize = 4096;
pub const SEEN_TTL_MS: i64 = 10 * 60 * 1000;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Frame {
    pub hops_left: u8,
    pub id: [u8; 16],
    pub index: u16,
    pub count: u16,
    pub payload: Vec<u8>,
}

impl Frame {
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::with_capacity(HEADER_LEN + self.payload.len());
        out.push(FRAME_VERSION);
        out.push(self.hops_left);
        out.extend_from_slice(&self.id);
        out.extend_from_slice(&self.index.to_be_bytes());
        out.extend_from_slice(&self.count.to_be_bytes());
        out.extend_from_slice(&self.payload);
        out
    }

    pub fn decode(b: &[u8]) -> Option<Frame> {
        if b.len() < HEADER_LEN || b[0] != FRAME_VERSION {
            return None;
        }
        let mut id = [0u8; 16];
        id.copy_from_slice(&b[2..18]);
        let index = u16::from_be_bytes([b[18], b[19]]);
        let count = u16::from_be_bytes([b[20], b[21]]);
        if count == 0 || index >= count {
            return None;
        }
        Some(Frame { hops_left: b[1], id, index, count, payload: b[HEADER_LEN..].to_vec() })
    }
}

/// Splits an envelope into frames. The frame id is the envelope id and
/// hops_left its ttl; bytes that are not an envelope get a hash id and ttl 7.
pub fn fragment(envelope: &[u8], mtu: usize) -> Vec<Frame> {
    let (id, hops) = match Envelope::from_bytes(envelope) {
        Ok(e) => (e.id, e.ttl),
        Err(_) => {
            let h = sha3(&[b"soma-relay/frame-id", envelope]);
            let mut id = [0u8; 16];
            id.copy_from_slice(&h[..16]);
            (id, DEFAULT_TTL)
        }
    };
    let per = mtu.saturating_sub(HEADER_LEN).max(1);
    let chunks: Vec<&[u8]> = if envelope.is_empty() { vec![&[][..]] } else { envelope.chunks(per).collect() };
    if chunks.len() > u16::MAX as usize || envelope.len() > MAX_MESSAGE {
        return Vec::new();
    }
    let count = chunks.len() as u16;
    chunks
        .into_iter()
        .enumerate()
        .map(|(i, c)| Frame { hops_left: hops, id, index: i as u16, count, payload: c.to_vec() })
        .collect()
}

struct Assembly {
    count: u16,
    parts: Vec<Option<Vec<u8>>>,
    received: usize,
    bytes: usize,
    started: i64,
}

/// Reassembles frames: 128 assemblies, 30 s timeout, 1 MiB per message.
#[derive(Default)]
pub struct Reassembler {
    assemblies: HashMap<[u8; 16], Assembly>,
}

impl Reassembler {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn push(&mut self, f: &Frame, now: i64) -> Option<Vec<u8>> {
        self.assemblies.retain(|_, a| now.saturating_sub(a.started) < ASSEMBLY_TIMEOUT_MS);
        if f.count == 1 {
            return (f.payload.len() <= MAX_MESSAGE).then(|| f.payload.clone());
        }
        if !self.assemblies.contains_key(&f.id) {
            if self.assemblies.len() >= MAX_ASSEMBLIES {
                // Evict the oldest assembly.
                let oldest = self.assemblies.iter().min_by_key(|(_, a)| a.started).map(|(k, _)| *k)?;
                self.assemblies.remove(&oldest);
            }
            self.assemblies.insert(
                f.id,
                Assembly { count: f.count, parts: vec![None; f.count as usize], received: 0, bytes: 0, started: now },
            );
        }
        let a = self.assemblies.get_mut(&f.id)?;
        if a.count != f.count {
            return None;
        }
        let slot = a.parts.get_mut(f.index as usize)?;
        if slot.is_some() {
            return None;
        }
        if a.bytes + f.payload.len() > MAX_MESSAGE {
            self.assemblies.remove(&f.id);
            return None;
        }
        a.bytes += f.payload.len();
        *slot = Some(f.payload.clone());
        a.received += 1;
        if a.received < a.count as usize {
            return None;
        }
        let a = self.assemblies.remove(&f.id)?;
        let mut out = Vec::with_capacity(a.bytes);
        for p in a.parts.into_iter().flatten() {
            out.extend_from_slice(&p);
        }
        Some(out)
    }

    pub fn len(&self) -> usize {
        self.assemblies.len()
    }

    pub fn is_empty(&self) -> bool {
        self.assemblies.is_empty()
    }
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct MeshResult {
    pub complete: Option<Vec<u8>>,
    pub forward: Vec<Vec<u8>>,
    pub exclude_link: u32,
}

struct Seen {
    at: i64,
    indices: BTreeSet<u16>,
    all: bool,
}

/// Flooding router: dedup of (id, index) over 4096 ids for 10 minutes,
/// hops_left decremented per hop, never sent back on the ingress link.
#[derive(Default)]
pub struct MeshRouter {
    seen: HashMap<[u8; 16], Seen>,
    order: VecDeque<[u8; 16]>,
    reassembler: Reassembler,
    last_now: i64,
}

impl MeshRouter {
    pub fn new() -> Self {
        Self::default()
    }

    fn expire(&mut self, now: i64) {
        while let Some(id) = self.order.front().copied() {
            let stale = self.seen.get(&id).is_none_or(|s| now.saturating_sub(s.at) >= SEEN_TTL_MS);
            if stale || self.order.len() > SEEN_CAP {
                self.order.pop_front();
                self.seen.remove(&id);
            } else {
                break;
            }
        }
    }

    fn entry(&mut self, id: [u8; 16], now: i64) -> &mut Seen {
        if !self.seen.contains_key(&id) {
            self.order.push_back(id);
            self.seen.insert(id, Seen { at: now, indices: BTreeSet::new(), all: false });
        }
        self.seen.get_mut(&id).expect("inserted above")
    }

    pub fn on_frame(&mut self, frame: &[u8], from_link: u32, now: i64) -> MeshResult {
        let mut res = MeshResult { complete: None, forward: Vec::new(), exclude_link: from_link };
        if self.last_now == 0 {
            // Ids marked by frames_for before any clock was known.
            for s in self.seen.values_mut().filter(|s| s.at == 0) {
                s.at = now;
            }
        }
        self.last_now = self.last_now.max(now);
        self.expire(now);
        let Some(f) = Frame::decode(frame) else { return res };
        let s = self.entry(f.id, now);
        if s.all || !s.indices.insert(f.index) {
            return res;
        }
        if f.hops_left > 1 {
            let mut fwd = f.clone();
            fwd.hops_left -= 1;
            res.forward.push(fwd.encode());
        }
        res.complete = self.reassembler.push(&f, now);
        self.expire(now);
        res
    }

    /// Frames for one of our own envelopes; marks its id as seen (timestamped
    /// with the latest `now_ms` given to `on_frame`).
    pub fn frames_for(&mut self, envelope: &[u8], mtu: u32) -> Vec<Vec<u8>> {
        let now = self.last_now;
        let frames = fragment(envelope, mtu as usize);
        if let Some(f) = frames.first() {
            let id = f.id;
            self.expire(now);
            self.entry(id, now).all = true;
        }
        frames.iter().map(Frame::encode).collect()
    }
}
