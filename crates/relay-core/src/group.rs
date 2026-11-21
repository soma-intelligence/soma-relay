//! Private groups: signed operation log + sender keys.

use std::collections::{BTreeMap, BTreeSet};

use ed25519_dalek::{Signer, SigningKey};
use serde::{Deserialize, Serialize};
use zeroize::{Zeroize, Zeroizing};

use crate::card::Card;
use crate::error::{RelayError, Result, decrypt_err};
use crate::hybrid::{HybridSig, SigningSeeds, ed_verify, hybrid_verify};
use crate::session::MAX_SKIP;
use crate::util::{Rng, hmac, message_key_material, open, seal, sha3, to_postcard};

const OP_DOMAIN: &[u8] = b"soma-relay/v1/group-op";
const MSG_DOMAIN: &[u8] = b"soma-relay/v1/group-msg";
/// Sender keys rotate weekly.
pub const SENDER_KEY_MAX_AGE_MS: i64 = 7 * 24 * 3600 * 1000;
pub const MAX_OPS: usize = 4096;

#[derive(Clone, Serialize, Deserialize, Debug, PartialEq, Eq)]
pub enum OpKind {
    /// Cards of every first member, creator included.
    Create { name: String, members: Vec<Vec<u8>> },
    Add { card: Vec<u8> },
    Remove { fp: [u8; 32] },
    Rename { name: String },
    Promote { fp: [u8; 32] },
}

#[derive(Clone, Serialize, Deserialize, Debug, PartialEq, Eq)]
pub struct Op {
    pub group_id: [u8; 16],
    pub kind: OpKind,
    pub lamport: u64,
    pub prev: [u8; 32],
    pub author: [u8; 32],
}

#[derive(Clone, Serialize, Deserialize, Debug, PartialEq, Eq)]
pub struct SignedOp {
    pub op: Op,
    pub sig: HybridSig,
}

impl SignedOp {
    pub fn hash(&self) -> [u8; 32] {
        sha3(&[&to_postcard(self)])
    }

    fn message(op: &Op) -> Vec<u8> {
        let mut m = OP_DOMAIN.to_vec();
        m.extend_from_slice(&to_postcard(op));
        m
    }

    pub fn sign(op: Op, seeds: &SigningSeeds, rng: &mut Rng) -> SignedOp {
        let sig = seeds.sign(&Self::message(&op), rng);
        SignedOp { op, sig }
    }

    fn verify_with(&self, card: &Card) -> bool {
        card.fingerprint() == self.op.author
            && hybrid_verify(&card.body.ed_pub, &card.body.dsa_pub, &Self::message(&self.op), &self.sig)
    }
}

/// Group state computed from the log.
#[derive(Clone, Debug, Default)]
pub struct View {
    pub name: String,
    pub members: BTreeMap<[u8; 32], Card>,
    pub admins: BTreeSet<[u8; 32]>,
}

fn cards_in(op: &OpKind) -> Vec<Card> {
    let raw: Vec<&Vec<u8>> = match op {
        OpKind::Create { members, .. } => members.iter().collect(),
        OpKind::Add { card } => vec![card],
        _ => vec![],
    };
    raw.into_iter().filter_map(|b| Card::from_bytes(b).ok()).collect()
}

/// Replays a log sorted by (lamport, hash). Unauthorised ops are skipped.
pub fn replay(ops: &[SignedOp]) -> Result<View> {
    let mut v = View::default();
    let mut created = false;
    for so in ops {
        let op = &so.op;
        match &op.kind {
            OpKind::Create { name, .. } => {
                if created {
                    continue;
                }
                created = true;
                v.name = name.clone();
                for c in cards_in(&op.kind) {
                    v.members.insert(c.fingerprint(), c);
                }
                if !v.members.contains_key(&op.author) {
                    return Err(RelayError::Group("creator is not a member".into()));
                }
                v.admins.insert(op.author);
            }
            _ if !created || !v.admins.contains(&op.author) || !v.members.contains_key(&op.author) => continue,
            OpKind::Add { .. } => {
                for c in cards_in(&op.kind) {
                    v.members.entry(c.fingerprint()).or_insert(c);
                }
            }
            OpKind::Remove { fp } => {
                v.members.remove(fp);
                v.admins.remove(fp);
            }
            OpKind::Rename { name } => v.name = name.clone(),
            OpKind::Promote { fp } => {
                if v.members.contains_key(fp) {
                    v.admins.insert(*fp);
                }
            }
        }
    }
    if !created {
        return Err(RelayError::Group("no create operation".into()));
    }
    Ok(v)
}

#[derive(Clone, Serialize, Deserialize)]
pub struct SenderChain {
    pub key_id: [u8; 8],
    pub ck: [u8; 32],
    pub n: u32,
    pub sign: [u8; 32],
    pub created_ms: i64,
}

impl Drop for SenderChain {
    fn drop(&mut self) {
        self.ck.zeroize();
        self.sign.zeroize();
    }
}

impl SenderChain {
    pub fn generate(rng: &mut Rng, now: i64) -> Self {
        SenderChain { key_id: rng.bytes(), ck: rng.bytes(), n: 0, sign: rng.bytes(), created_ms: now }
    }

    pub fn sign_public(&self) -> [u8; 32] {
        SigningKey::from_bytes(&self.sign).verifying_key().to_bytes()
    }
}

#[derive(Clone, Serialize, Deserialize)]
pub struct ReceiverChain {
    pub owner: [u8; 32],
    pub key_id: [u8; 8],
    pub ck: [u8; 32],
    pub n: u32,
    pub sign_pub: [u8; 32],
    pub skipped: Vec<(u32, [u8; 32])>,
}

impl Drop for ReceiverChain {
    fn drop(&mut self) {
        self.ck.zeroize();
        for s in &mut self.skipped {
            s.1.zeroize();
        }
    }
}

/// Sender key distribution, carried inside a 1:1 session.
#[derive(Clone, Serialize, Deserialize, Debug, PartialEq, Eq)]
pub struct KeyDist {
    pub key_id: [u8; 8],
    pub ck: [u8; 32],
    pub n: u32,
    pub sign_pub: [u8; 32],
}

/// Group message body (kind 2 envelope).
#[derive(Clone, Serialize, Deserialize, Debug)]
pub struct GroupMsg {
    pub key_id: [u8; 8],
    pub n: u32,
    pub ct: Vec<u8>,
    pub sig: Vec<u8>,
}

#[derive(Clone, Serialize, Deserialize)]
pub struct Group {
    pub id: [u8; 16],
    pub ops: Vec<SignedOp>,
    pub my_chain: SenderChain,
    /// Members holding my current sender key.
    pub distributed_to: Vec<[u8; 32]>,
    pub receivers: Vec<ReceiverChain>,
}

pub fn group_tag(id: &[u8; 16]) -> [u8; 16] {
    let h = sha3(&[b"soma-relay/v1/group-tag", id]);
    let mut t = [0u8; 16];
    t.copy_from_slice(&h[..16]);
    t
}

fn msg_signed(gid: &[u8; 16], key_id: &[u8; 8], n: u32, ct: &[u8]) -> Vec<u8> {
    let mut m = MSG_DOMAIN.to_vec();
    m.extend_from_slice(gid);
    m.extend_from_slice(key_id);
    m.extend_from_slice(&n.to_le_bytes());
    m.extend_from_slice(ct);
    m
}

fn msg_aad(gid: &[u8; 16], key_id: &[u8; 8], n: u32) -> Vec<u8> {
    let mut a = gid.to_vec();
    a.extend_from_slice(key_id);
    a.extend_from_slice(&n.to_le_bytes());
    a
}

impl Group {
    pub fn view(&self) -> Result<View> {
        replay(&self.ops)
    }

    pub fn head(&self) -> ([u8; 32], u64) {
        self.ops.last().map_or(([0u8; 32], 0), |o| (o.hash(), o.op.lamport))
    }

    pub fn new_op(&self, kind: OpKind, author: [u8; 32], seeds: &SigningSeeds, rng: &mut Rng) -> SignedOp {
        let lamport = self.ops.iter().map(|o| o.op.lamport).max().map_or(0, |l| l + 1);
        let (prev, _) = self.head();
        SignedOp::sign(Op { group_id: self.id, kind, lamport, prev, author }, seeds, rng)
    }

    /// Verifies and merges ops (deduplicated, deterministic order). Returns true
    /// when the log changed.
    pub fn merge(&mut self, incoming: &[SignedOp]) -> Result<bool> {
        let mut known: BTreeSet<[u8; 32]> = self.ops.iter().map(SignedOp::hash).collect();
        let mut changed = false;
        // Several passes: an op can be signed by a member added in the same batch.
        let mut pending: Vec<&SignedOp> = incoming.iter().filter(|o| o.op.group_id == self.id).collect();
        loop {
            let mut progress = false;
            let mut rest = Vec::new();
            for so in pending {
                let h = so.hash();
                if known.contains(&h) {
                    continue;
                }
                let mut cards: Vec<Card> = self.ops.iter().flat_map(|o| cards_in(&o.op.kind)).collect();
                if let OpKind::Create { .. } = so.op.kind {
                    cards.extend(cards_in(&so.op.kind));
                }
                if cards.iter().any(|c| so.verify_with(c)) {
                    self.ops.push(so.clone());
                    known.insert(h);
                    changed = true;
                    progress = true;
                } else {
                    rest.push(so);
                }
            }
            pending = rest;
            if !progress || pending.is_empty() {
                break;
            }
        }
        if self.ops.len() > MAX_OPS {
            return Err(RelayError::Group("operation log too large".into()));
        }
        self.ops.sort_by_cached_key(|o| (o.op.lamport, o.hash()));
        Ok(changed)
    }

    pub fn rotate(&mut self, rng: &mut Rng, now: i64) {
        self.my_chain = SenderChain::generate(rng, now);
        self.distributed_to.clear();
    }

    pub fn dist(&self) -> KeyDist {
        KeyDist {
            key_id: self.my_chain.key_id,
            ck: self.my_chain.ck,
            n: self.my_chain.n,
            sign_pub: self.my_chain.sign_public(),
        }
    }

    pub fn install(&mut self, owner: [u8; 32], d: &KeyDist) {
        if self.receivers.iter().any(|r| r.key_id == d.key_id) {
            return;
        }
        self.receivers.push(ReceiverChain {
            owner,
            key_id: d.key_id,
            ck: d.ck,
            n: d.n,
            sign_pub: d.sign_pub,
            skipped: Vec::new(),
        });
        // Keep the two most recent chains per owner (in-flight messages).
        let mine: Vec<usize> = self.receivers.iter().enumerate().filter(|(_, r)| r.owner == owner).map(|(i, _)| i).collect();
        if mine.len() > 2 {
            self.receivers.remove(mine[0]);
        }
    }

    pub fn drop_member(&mut self, fp: &[u8; 32]) {
        self.receivers.retain(|r| &r.owner != fp);
        self.distributed_to.retain(|f| f != fp);
    }

    pub fn encrypt(&mut self, plain: &[u8]) -> GroupMsg {
        let c = &mut self.my_chain;
        let mk = Zeroizing::new(hmac(&c.ck, &[1]));
        c.ck = hmac(&c.ck, &[2]);
        let n = c.n;
        c.n = c.n.saturating_add(1);
        let (key, nonce) = message_key_material(&mk, b"soma-relay/v1/group-key");
        let ct = seal(&key, &nonce, &msg_aad(&self.id, &c.key_id, n), plain);
        let sig = SigningKey::from_bytes(&c.sign).sign(&msg_signed(&self.id, &c.key_id, n, &ct)).to_bytes().to_vec();
        GroupMsg { key_id: c.key_id, n, ct, sig }
    }

    /// Returns (sender fp, plaintext); state changes only on success.
    pub fn decrypt(&mut self, m: &GroupMsg) -> Result<([u8; 32], Vec<u8>)> {
        let gid = self.id;
        let idx = self
            .receivers
            .iter()
            .position(|r| r.key_id == m.key_id)
            .ok_or_else(|| RelayError::NoSession("unknown sender key".into()))?;
        let r = &self.receivers[idx];
        if !ed_verify(&r.sign_pub, &msg_signed(&gid, &m.key_id, m.n, &m.ct), &m.sig) {
            return Err(decrypt_err());
        }
        let mut r2 = r.clone();
        let mk = if m.n < r2.n {
            let pos = r2.skipped.iter().position(|(n, _)| *n == m.n).ok_or_else(decrypt_err)?;
            let (_, mk) = r2.skipped.remove(pos);
            Zeroizing::new(mk)
        } else {
            if m.n - r2.n > MAX_SKIP {
                return Err(RelayError::Decrypt("too many skipped group messages".into()));
            }
            while r2.n < m.n {
                r2.skipped.push((r2.n, hmac(&r2.ck, &[1])));
                r2.ck = hmac(&r2.ck, &[2]);
                r2.n += 1;
            }
            if r2.skipped.len() > MAX_SKIP as usize {
                let excess = r2.skipped.len() - MAX_SKIP as usize;
                r2.skipped.drain(..excess);
            }
            let mk = Zeroizing::new(hmac(&r2.ck, &[1]));
            r2.ck = hmac(&r2.ck, &[2]);
            r2.n = r2.n.saturating_add(1);
            mk
        };
        let (key, nonce) = message_key_material(&mk, b"soma-relay/v1/group-key");
        let plain = open(&key, &nonce, &msg_aad(&gid, &m.key_id, m.n), &m.ct)?;
        let owner = r2.owner;
        self.receivers[idx] = r2;
        Ok((owner, plain))
    }
}
