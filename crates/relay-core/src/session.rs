//! 1:1 sessions: PQXDH-like hybrid opening, then a Double Ratchet with a
//! periodic ML-KEM-1024 step mixed into the root key.

use serde::{Deserialize, Serialize};
use zeroize::{Zeroize, Zeroizing};

use crate::card::Card;
use crate::error::{RelayError, Result, decrypt_err};
use crate::hybrid::{HybridSig, KemKey, MLKEM_CT_LEN, MLKEM_PUB_LEN, SigningSeeds, XKey, hybrid_verify, kem_encapsulate};
use crate::util::{Rng, from_postcard, hkdf, hkdf32, hmac, message_key_material, open, seal, sha3, to_postcard};

/// Largest gap of skipped messages in one chain, and cap of stored skipped keys.
pub const MAX_SKIP: u32 = 2000;
/// Skipped message keys are dropped after 7 days.
pub const SKIPPED_TTL_MS: i64 = 7 * 24 * 3600 * 1000;
/// PQ ratchet step: on a direction change once 50 messages or 24 hours passed.
pub const PQ_EVERY_MSGS: u32 = 50;
pub const PQ_EVERY_MS: i64 = 24 * 3600 * 1000;

#[derive(Clone, Serialize, Deserialize, Debug, PartialEq, Eq)]
pub struct KemAnnounce {
    pub id: u32,
    pub pk: Vec<u8>,
}

#[derive(Clone, Serialize, Deserialize, Debug, PartialEq, Eq)]
pub struct KemStep {
    pub target: u32,
    pub ct: Vec<u8>,
}

#[derive(Clone, Serialize, Deserialize, Debug, PartialEq, Eq)]
pub struct Header {
    pub session_id: [u8; 16],
    pub dh: [u8; 32],
    pub pn: u32,
    pub n: u32,
    /// Id of the peer's ratchet KEM key the sender holds (0 = none).
    pub seen_kem: u32,
    /// The sender's current ratchet KEM key, sent until the peer acknowledges it.
    pub kem_pub: Option<KemAnnounce>,
    /// PQ step of this sending chain (repeated on every message of the chain).
    pub kem_ct: Option<KemStep>,
}

#[derive(Clone, Serialize, Deserialize, Debug, PartialEq, Eq)]
pub struct RatchetMsg {
    pub header: Header,
    pub ct: Vec<u8>,
}

/// Clear part of a first message. `sealed` hides the sender (sealed sender).
#[derive(Clone, Serialize, Deserialize, Debug, PartialEq, Eq)]
pub struct InitHeader {
    pub ek: [u8; 32],
    pub kem_ct: Vec<u8>,
    pub spk_id: u32,
    pub sealed: Vec<u8>,
}

#[derive(Clone, Serialize, Deserialize, Debug, PartialEq, Eq)]
pub enum DirectBody {
    Init { init: InitHeader, msg: RatchetMsg },
    Msg(RatchetMsg),
}

#[derive(Serialize, Deserialize)]
struct SealedSender {
    card: Vec<u8>,
    sig: HybridSig,
}

#[derive(Clone, Serialize, Deserialize)]
pub struct Skipped {
    pub dh: [u8; 32],
    pub n: u32,
    pub mk: [u8; 32],
    pub at_ms: i64,
}

#[derive(Clone, Serialize, Deserialize)]
pub struct KemSlot {
    pub id: u32,
    pub key: KemKey,
}

#[derive(Clone, Serialize, Deserialize)]
pub struct Session {
    pub id: [u8; 16],
    /// Associated data: the opening transcript hash (binds both identities).
    pub ad: [u8; 32],
    pub rk: [u8; 32],
    pub dhs: XKey,
    pub dhr: Option<[u8; 32]>,
    pub cks: Option<[u8; 32]>,
    pub ckr: Option<[u8; 32]>,
    pub ns: u32,
    pub nr: u32,
    pub pn: u32,
    pub skipped: Vec<Skipped>,
    pub my_kem: KemSlot,
    pub my_prev_kem: Option<KemSlot>,
    pub peer_kem: Option<KemAnnounce>,
    pub peer_seen_my_kem: u32,
    pub send_fresh: bool,
    pub chain_pq: Option<KemStep>,
    pub msgs_since_pq: u32,
    pub last_pq_ms: i64,
    pub pq_steps: u32,
    pub pending_init: Option<InitHeader>,
    /// Stable per-session secret for exports (call keys).
    pub export_base: [u8; 32],
    pub created_ms: i64,
}

impl Drop for Session {
    fn drop(&mut self) {
        self.rk.zeroize();
        self.cks.zeroize();
        self.ckr.zeroize();
        self.export_base.zeroize();
        for s in &mut self.skipped {
            s.mk.zeroize();
        }
    }
}

/// What the local identity contributes to an opening.
pub struct Me<'a> {
    pub fp: [u8; 32],
    pub dev_x: &'a XKey,
    pub sign: &'a SigningSeeds,
    pub card_bytes: Vec<u8>,
}

#[allow(clippy::too_many_arguments)]
fn transcript(
    a_fp: &[u8; 32],
    b_fp: &[u8; 32],
    a_dev_x: &[u8; 32],
    b_dev_x: &[u8; 32],
    spk_id: u32,
    spk_x: &[u8; 32],
    spk_kem: &[u8],
    ek: &[u8; 32],
    kem_ct: &[u8],
) -> [u8; 32] {
    sha3(&[
        b"soma-relay/v1/transcript",
        a_fp,
        b_fp,
        a_dev_x,
        b_dev_x,
        &spk_id.to_le_bytes(),
        spk_x,
        &sha3(&[spk_kem]),
        ek,
        &sha3(&[kem_ct]),
    ])
}

fn seal_key(dh2: &[u8], dh3: &[u8], ss: &[u8], ek: &[u8; 32], kem_ct: &[u8]) -> Zeroizing<[u8; 32]> {
    let mut ikm = Zeroizing::new(Vec::with_capacity(96));
    ikm.extend_from_slice(dh2);
    ikm.extend_from_slice(dh3);
    ikm.extend_from_slice(ss);
    Zeroizing::new(hkdf32(&[0u8; 32], &ikm, &[b"soma-relay/v1/init-seal", ek, &sha3(&[kem_ct])]))
}

fn root_secret(dh1: &[u8], dh2: &[u8], dh3: &[u8], ss: &[u8], transcript: &[u8; 32]) -> Zeroizing<[u8; 32]> {
    let mut ikm = Zeroizing::new(vec![0xFFu8; 32]);
    ikm.extend_from_slice(dh1);
    ikm.extend_from_slice(dh2);
    ikm.extend_from_slice(dh3);
    ikm.extend_from_slice(ss);
    Zeroizing::new(hkdf32(&[0u8; 32], &ikm, &[b"soma-relay/v1/x3dh", transcript]))
}

fn kdf_rk(rk: &[u8; 32], ikm: &[u8], info: &[u8]) -> ([u8; 32], [u8; 32]) {
    let mut out = Zeroizing::new([0u8; 64]);
    hkdf(rk, ikm, &[info], &mut out[..]);
    let mut a = [0u8; 32];
    let mut b = [0u8; 32];
    a.copy_from_slice(&out[..32]);
    b.copy_from_slice(&out[32..]);
    (a, b)
}

fn kdf_ck(ck: &[u8; 32]) -> ([u8; 32], [u8; 32]) {
    (hmac(ck, &[1]), hmac(ck, &[2]))
}

fn derive_ids(sk: &[u8; 32]) -> ([u8; 16], [u8; 32]) {
    let sid = hkdf32(sk, b"", &[b"soma-relay/v1/session-id"]);
    let mut id = [0u8; 16];
    id.copy_from_slice(&sid[..16]);
    (id, hkdf32(sk, b"", &[b"soma-relay/v1/export"]))
}

fn aad(ad: &[u8; 32], header: &Header) -> Vec<u8> {
    let mut a = ad.to_vec();
    a.extend_from_slice(&to_postcard(header));
    a
}

/// Responder side lookup of its signed prekeys by id.
pub struct Prekey<'a> {
    pub id: u32,
    pub x: &'a XKey,
    pub kem: &'a KemKey,
}

impl Session {
    fn new_common(sk: &[u8; 32], ad: [u8; 32], dhs: XKey, rng: &mut Rng, now: i64) -> Session {
        let (id, export_base) = derive_ids(sk);
        Session {
            id,
            ad,
            rk: *sk,
            dhs,
            dhr: None,
            cks: None,
            ckr: None,
            ns: 0,
            nr: 0,
            pn: 0,
            skipped: Vec::new(),
            my_kem: KemSlot { id: 1, key: KemKey::generate(rng) },
            my_prev_kem: None,
            peer_kem: None,
            peer_seen_my_kem: 0,
            send_fresh: false,
            chain_pq: None,
            msgs_since_pq: 0,
            last_pq_ms: now,
            pq_steps: 0,
            pending_init: None,
            export_base,
            created_ms: now,
        }
    }

    /// Initiator: opens a session to `peer` (its signed prekey and device keys).
    pub fn initiate(me: &Me, peer: &Card, rng: &mut Rng, now: i64) -> Result<Session> {
        let b = &peer.body;
        let peer_fp = peer.fingerprint();
        let ek = XKey::generate(rng);
        let ek_pub = ek.public();
        let dh1 = me.dev_x.dh(&b.spk_x)?;
        let dh2 = ek.dh(&b.dev_x)?;
        let dh3 = ek.dh(&b.spk_x)?;
        let (kem_ct, ss) = kem_encapsulate(&b.spk_kem, rng)?;
        let t = transcript(&me.fp, &peer_fp, &me.dev_x.public(), &b.dev_x, b.spk_id, &b.spk_x, &b.spk_kem, &ek_pub, &kem_ct);
        let sig = me.sign.sign(&t, rng);
        let sealed_plain = Zeroizing::new(to_postcard(&SealedSender { card: me.card_bytes.clone(), sig }));
        let key = seal_key(&dh2[..], &dh3[..], &ss[..], &ek_pub, &kem_ct);
        let mut seal_aad = ek_pub.to_vec();
        seal_aad.extend_from_slice(&b.spk_id.to_le_bytes());
        let sealed = seal(&key, &[0u8; 12], &seal_aad, &sealed_plain);
        let sk = root_secret(&dh1[..], &dh2[..], &dh3[..], &ss[..], &t);

        let dhs = XKey::generate(rng);
        let mut s = Session::new_common(&sk, t, dhs, rng, now);
        let dh = s.dhs.dh(&b.spk_x)?;
        let (rk, cks) = kdf_rk(&s.rk, &dh[..], b"soma-relay/v1/rk");
        s.rk = rk;
        s.cks = Some(cks);
        s.dhr = Some(b.spk_x);
        s.pending_init = Some(InitHeader { ek: ek_pub, kem_ct, spk_id: b.spk_id, sealed });
        Ok(s)
    }

    /// Responder: opens the sealed part of an init header. Returns the sender's
    /// verified card and the new session (not yet used to decrypt).
    pub fn respond(me: &Me, init: &InitHeader, prekeys: &[Prekey], rng: &mut Rng, now: i64) -> Result<(Card, Session)> {
        let spk = prekeys
            .iter()
            .find(|p| p.id == init.spk_id)
            .ok_or_else(|| RelayError::NoSession("unknown signed prekey".into()))?;
        if init.kem_ct.len() != MLKEM_CT_LEN || init.sealed.len() > 64 * 1024 {
            return Err(RelayError::Malformed("bad init header".into()));
        }
        let dh2 = me.dev_x.dh(&init.ek)?;
        let dh3 = spk.x.dh(&init.ek)?;
        let ss = spk.kem.decapsulate(&init.kem_ct)?;
        let key = seal_key(&dh2[..], &dh3[..], &ss[..], &init.ek, &init.kem_ct);
        let mut seal_aad = init.ek.to_vec();
        seal_aad.extend_from_slice(&init.spk_id.to_le_bytes());
        let plain = Zeroizing::new(open(&key, &[0u8; 12], &seal_aad, &init.sealed)?);
        let sealed: SealedSender = from_postcard(&plain, "sealed sender")?;
        let card = Card::from_bytes(&sealed.card)?;
        let a_fp = card.fingerprint();
        if a_fp == me.fp {
            return Err(RelayError::Malformed("message from self".into()));
        }
        let dh1 = spk.x.dh(&card.body.dev_x)?;
        let spk_kem = spk.kem.public();
        let t = transcript(&a_fp, &me.fp, &card.body.dev_x, &me.dev_x.public(), spk.id, &spk.x.public(), &spk_kem, &init.ek, &init.kem_ct);
        if !hybrid_verify(&card.body.ed_pub, &card.body.dsa_pub, &t, &sealed.sig) {
            return Err(RelayError::Decrypt("opening signature does not verify".into()));
        }
        let sk = root_secret(&dh1[..], &dh2[..], &dh3[..], &ss[..], &t);
        let s = Session::new_common(&sk, t, spk.x.clone(), rng, now);
        Ok((card, s))
    }

    fn pq_due(&self, now: i64) -> bool {
        self.msgs_since_pq >= PQ_EVERY_MSGS || now.saturating_sub(self.last_pq_ms) >= PQ_EVERY_MS
    }

    /// Encrypts one plaintext; returns the ratchet message (and the init header
    /// while the peer has not answered yet).
    pub fn encrypt(&mut self, plain: &[u8], rng: &mut Rng, now: i64) -> Result<DirectBody> {
        let Some(mut cks) = self.cks else {
            return Err(RelayError::NoSession("no sending chain yet".into()));
        };
        if self.send_fresh {
            self.send_fresh = false;
            self.chain_pq = None;
            if self.pq_due(now)
                && let Some(peer) = self.peer_kem.clone()
            {
                let (ct, ss) = kem_encapsulate(&peer.pk, rng)?;
                let (rk, ck) = kdf_rk(&self.rk, &ss[..], b"soma-relay/v1/pq");
                self.rk = rk;
                cks = ck;
                self.chain_pq = Some(KemStep { target: peer.id, ct });
                self.msgs_since_pq = 0;
                self.last_pq_ms = now;
                self.pq_steps += 1;
            }
        }
        let (mk, next) = kdf_ck(&cks);
        cks.zeroize();
        self.cks = Some(next);
        let header = Header {
            session_id: self.id,
            dh: self.dhs.public(),
            pn: self.pn,
            n: self.ns,
            seen_kem: self.peer_kem.as_ref().map_or(0, |k| k.id),
            kem_pub: (self.peer_seen_my_kem != self.my_kem.id)
                .then(|| KemAnnounce { id: self.my_kem.id, pk: self.my_kem.key.public() }),
            kem_ct: self.chain_pq.clone(),
        };
        self.ns = self.ns.checked_add(1).ok_or_else(|| RelayError::NoSession("chain exhausted".into()))?;
        self.msgs_since_pq = self.msgs_since_pq.saturating_add(1);
        let mk = Zeroizing::new(mk);
        let (key, nonce) = message_key_material(&mk, b"soma-relay/v1/msg");
        let ct = seal(&key, &nonce, &aad(&self.ad, &header), plain);
        let msg = RatchetMsg { header, ct };
        Ok(match &self.pending_init {
            Some(init) => DirectBody::Init { init: init.clone(), msg },
            None => DirectBody::Msg(msg),
        })
    }

    fn skip_until(&mut self, until: u32, now: i64) -> Result<()> {
        let Some(mut ck) = self.ckr else { return Ok(()) };
        let Some(dh) = self.dhr else { return Ok(()) };
        if until > self.nr.saturating_add(MAX_SKIP) {
            return Err(RelayError::Decrypt("too many skipped messages".into()));
        }
        while self.nr < until {
            let (mk, next) = kdf_ck(&ck);
            ck = next;
            self.skipped.push(Skipped { dh, n: self.nr, mk, at_ms: now });
            self.nr += 1;
        }
        self.ckr = Some(ck);
        ck.zeroize();
        if self.skipped.len() > MAX_SKIP as usize {
            let excess = self.skipped.len() - MAX_SKIP as usize;
            for s in self.skipped.iter_mut().take(excess) {
                s.mk.zeroize();
            }
            self.skipped.drain(..excess);
        }
        Ok(())
    }

    fn take_skipped(&mut self, dh: &[u8; 32], n: u32) -> Option<Zeroizing<[u8; 32]>> {
        let pos = self.skipped.iter().position(|s| &s.dh == dh && s.n == n)?;
        let mut s = self.skipped.remove(pos);
        let mk = Zeroizing::new(s.mk);
        s.mk.zeroize();
        Some(mk)
    }

    /// Drops skipped keys older than 7 days.
    pub fn expire(&mut self, now: i64) {
        self.skipped.retain_mut(|s| {
            let keep = now.saturating_sub(s.at_ms) < SKIPPED_TTL_MS;
            if !keep {
                s.mk.zeroize();
            }
            keep
        });
    }

    fn kem_for(&self, id: u32) -> Option<&KemKey> {
        if self.my_kem.id == id {
            return Some(&self.my_kem.key);
        }
        self.my_prev_kem.as_ref().filter(|k| k.id == id).map(|k| &k.key)
    }

    fn dh_ratchet(&mut self, header: &Header, rng: &mut Rng, now: i64) -> Result<()> {
        self.pn = self.ns;
        self.ns = 0;
        self.nr = 0;
        self.dhr = Some(header.dh);
        let dh = self.dhs.dh(&header.dh)?;
        let (rk, mut ckr) = kdf_rk(&self.rk, &dh[..], b"soma-relay/v1/rk");
        self.rk = rk;
        if let Some(step) = &header.kem_ct {
            let key = self.kem_for(step.target).ok_or_else(decrypt_err)?;
            let ss = key.decapsulate(&step.ct)?;
            let (rk, ck) = kdf_rk(&self.rk, &ss[..], b"soma-relay/v1/pq");
            self.rk = rk;
            ckr = ck;
            // The used key is retired: a fresh one is announced next.
            let next = KemSlot { id: self.my_kem.id.wrapping_add(1).max(1), key: KemKey::generate(rng) };
            self.my_prev_kem = Some(std::mem::replace(&mut self.my_kem, next));
            self.msgs_since_pq = 0;
            self.last_pq_ms = now;
            self.pq_steps += 1;
        }
        self.ckr = Some(ckr);
        self.dhs = XKey::generate(rng);
        let dh = self.dhs.dh(&header.dh)?;
        let (rk, cks) = kdf_rk(&self.rk, &dh[..], b"soma-relay/v1/rk");
        self.rk = rk;
        self.cks = Some(cks);
        self.send_fresh = true;
        Ok(())
    }

    fn check_header(h: &Header) -> Result<()> {
        if h.kem_pub.as_ref().is_some_and(|k| k.pk.len() != MLKEM_PUB_LEN || k.id == 0)
            || h.kem_ct.as_ref().is_some_and(|k| k.ct.len() != MLKEM_CT_LEN)
        {
            return Err(RelayError::Malformed("bad ratchet header".into()));
        }
        Ok(())
    }

    /// Decrypts on a copy and returns the updated session; the caller commits
    /// it only on success, so a forged message never changes state.
    pub fn decrypt(&self, msg: &RatchetMsg, rng: &mut Rng, now: i64) -> Result<(Session, Vec<u8>)> {
        let h = &msg.header;
        Self::check_header(h)?;
        if h.session_id != self.id {
            return Err(RelayError::NoSession("session mismatch".into()));
        }
        let mut s = self.clone();
        s.expire(now);
        let aad = aad(&s.ad, h);
        let mk = if let Some(mk) = s.take_skipped(&h.dh, h.n) {
            mk
        } else {
            if s.dhr != Some(h.dh) {
                s.skip_until(h.pn, now)?;
                s.dh_ratchet(h, rng, now)?;
            }
            s.skip_until(h.n, now)?;
            let ck = s.ckr.ok_or_else(decrypt_err)?;
            let (mk, next) = kdf_ck(&ck);
            s.ckr = Some(next);
            s.nr = s.nr.checked_add(1).ok_or_else(decrypt_err)?;
            Zeroizing::new(mk)
        };
        let (key, nonce) = message_key_material(&mk, b"soma-relay/v1/msg");
        let plain = open(&key, &nonce, &aad, &msg.ct)?;
        // Authenticated: accept the peer's KEM announcements and acks.
        if let Some(k) = &h.kem_pub
            && s.peer_kem.as_ref().is_none_or(|p| k.id > p.id)
        {
            s.peer_kem = Some(k.clone());
        }
        s.peer_seen_my_kem = s.peer_seen_my_kem.max(h.seen_kem);
        s.pending_init = None;
        s.msgs_since_pq = s.msgs_since_pq.saturating_add(1);
        Ok((s, plain))
    }

    pub fn call_key(&self, call_id: &str) -> [u8; 32] {
        hkdf32(&self.export_base, call_id.as_bytes(), &[b"soma-relay/v1/call-key"])
    }
}
