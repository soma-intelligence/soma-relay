//! `RelayEngine`: the whole client state behind the API of `docs/specs/core-api.md`.

use std::collections::{BTreeSet, HashMap, VecDeque};

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use zeroize::Zeroizing;

use crate::attachment;
use crate::card::{self, Card, CardBody, Compact};
use crate::channel::{Channel, ChannelMsg, RATE_PER_MINUTE, normalize};
use crate::envelope::{DEFAULT_TTL, Envelope, KIND_CHANNEL, KIND_DIRECT, KIND_GROUP};
use crate::error::{RelayError, Result, malformed};
use crate::group::{Group, KeyDist, OpKind, SENDER_KEY_MAX_AGE_MS, SenderChain, SignedOp, group_tag};
use crate::hybrid::{KemKey, SigningSeeds, XKey};
use crate::session::{DirectBody, Me, Prekey, Session};
use crate::util::{Rng, fp_from_hex, from_postcard, hex, hkdf32, pad, to_postcard, unhex, unpad};
use crate::words;

const STATE_VERSION: u8 = 1;
const PREKEY_MAX_AGE_MS: i64 = 7 * 24 * 3600 * 1000;
const PREKEYS_KEPT: usize = 4;
const SESSIONS_PER_CONTACT: usize = 3;
const SEEN_IDS: usize = 4096;
const MAX_APP_JSON: usize = 900 * 1024;
const NODE_AUTH_DOMAIN: &[u8] = b"soma-relay/node-auth/v1";
const HOUR_MS: i64 = 3_600_000;

#[derive(Clone, Serialize, Deserialize)]
struct SignedPrekey {
    id: u32,
    x: XKey,
    kem: KemKey,
    created_ms: i64,
}

#[derive(Clone, Serialize, Deserialize)]
struct Identity {
    name: String,
    sign: SigningSeeds,
    dev_x: XKey,
    dev_kem: KemKey,
    prekeys: Vec<SignedPrekey>,
    next_spk_id: u32,
    node_url: Option<String>,
    handle: Option<String>,
}

#[derive(Clone, Serialize, Deserialize)]
struct Contact {
    card: Card,
    fp: [u8; 32],
    name: String,
    verified: bool,
    added_at: i64,
    sessions: Vec<Session>,
}

#[derive(Clone, Serialize, Deserialize)]
struct State {
    v: u8,
    identity: Identity,
    contacts: Vec<Contact>,
    groups: Vec<Group>,
    channels: Vec<Channel>,
    seen: VecDeque<[u8; 16]>,
    /// Ephemeral keys of openings already accepted (replay guard once the
    /// session itself is gone).
    seen_inits: VecDeque<[u8; 32]>,
    now_ms: i64,
}

/// Payload inside a 1:1 ciphertext.
#[derive(Serialize, Deserialize)]
enum Payload {
    App(Vec<u8>),
    GroupKey { group_id: [u8; 16], ops: Vec<SignedOp>, dist: KeyDist },
    GroupOps { group_id: [u8; 16], ops: Vec<SignedOp> },
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Eq)]
pub struct ContactJson {
    pub fingerprint: String,
    pub name: String,
    pub mailbox: String,
    pub verified: bool,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub node_url: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub handle: Option<String>,
    pub added_at: i64,
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Eq)]
pub struct CompactJson {
    pub fingerprint: String,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub node_url: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub handle: Option<String>,
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
pub struct InboundJson {
    pub from: String,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub group: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub channel: Option<String>,
    pub message: Value,
    pub envelope_id: String,
}

/// Cached public values (derived from the seeds, never exported).
struct Cache {
    fp: [u8; 32],
    ed_pub: [u8; 32],
    dsa_pub: Vec<u8>,
    dev_x_pub: [u8; 32],
    dev_kem_pub: Vec<u8>,
    init_card: Option<Vec<u8>>,
    contact_secrets: HashMap<[u8; 32], Zeroizing<[u8; 32]>>,
    rate: HashMap<[u8; 32], (i64, u32)>,
}

pub struct RelayEngine {
    st: State,
    rng: Rng,
    cache: Cache,
}

fn contact_json(c: &Contact) -> ContactJson {
    ContactJson {
        fingerprint: hex(&c.fp),
        name: c.name.clone(),
        mailbox: hex(&card::mailbox(&c.fp)),
        verified: c.verified,
        node_url: c.card.body.node_url.clone(),
        handle: c.card.body.handle.clone(),
        added_at: c.added_at,
    }
}

fn parse_app(json: &str) -> Result<(Vec<u8>, Option<i64>)> {
    if json.len() > MAX_APP_JSON {
        return Err(malformed("message too large"));
    }
    let v: Value = serde_json::from_str(json).map_err(|_| malformed("AppMessage is not JSON"))?;
    if !v.is_object() {
        return Err(malformed("AppMessage must be a JSON object"));
    }
    let ts = v.get("ts").and_then(Value::as_i64);
    Ok((serde_json::to_vec(&v).map_err(|_| malformed("AppMessage"))?, ts))
}

fn new_cache(id: &Identity) -> Cache {
    let ed_pub = id.sign.ed_public();
    let dsa_pub = id.sign.dsa_public();
    Cache {
        fp: card::fingerprint(&ed_pub, &dsa_pub),
        ed_pub,
        dsa_pub,
        dev_x_pub: id.dev_x.public(),
        dev_kem_pub: id.dev_kem.public(),
        init_card: None,
        contact_secrets: HashMap::new(),
        rate: HashMap::new(),
    }
}

impl RelayEngine {
    // ---------------------------------------------------------------- creation

    fn with_rng(display_name: String, mut rng: Rng) -> RelayEngine {
        let identity = Identity {
            name: display_name,
            sign: SigningSeeds::generate(&mut rng),
            dev_x: XKey::generate(&mut rng),
            dev_kem: KemKey::generate(&mut rng),
            prekeys: vec![SignedPrekey { id: 1, x: XKey::generate(&mut rng), kem: KemKey::generate(&mut rng), created_ms: 0 }],
            next_spk_id: 2,
            node_url: None,
            handle: None,
        };
        let cache = new_cache(&identity);
        RelayEngine {
            st: State {
                v: STATE_VERSION,
                identity,
                contacts: Vec::new(),
                groups: Vec::new(),
                channels: Vec::new(),
                seen: VecDeque::new(),
                seen_inits: VecDeque::new(),
                now_ms: 0,
            },
            rng,
            cache,
        }
    }

    /// New identity.
    pub fn create(display_name: String) -> RelayEngine {
        Self::with_rng(display_name, Rng::os())
    }

    /// Deterministic identity and randomness (tests only).
    #[cfg(any(test, feature = "testing"))]
    pub fn create_with_seed(display_name: String, seed: [u8; 32]) -> RelayEngine {
        Self::with_rng(display_name, Rng::seeded(seed))
    }

    pub fn restore(state: &[u8]) -> Result<RelayEngine> {
        let st: State = postcard::from_bytes(state).map_err(|_| RelayError::Storage("state does not parse".into()))?;
        if st.v != STATE_VERSION {
            return Err(RelayError::Storage("unsupported state version".into()));
        }
        if st.identity.prekeys.is_empty() {
            return Err(RelayError::Storage("no signed prekey".into()));
        }
        let cache = new_cache(&st.identity);
        Ok(RelayEngine { st, rng: Rng::os(), cache })
    }

    pub fn export_state(&self) -> Vec<u8> {
        to_postcard(&self.st)
    }

    fn tick(&mut self, now: i64) {
        if now > self.st.now_ms {
            self.st.now_ms = now;
        }
    }

    // ---------------------------------------------------------------- identity

    pub fn fingerprint(&self) -> [u8; 32] {
        self.cache.fp
    }

    pub fn fingerprint_hex(&self) -> String {
        hex(&self.cache.fp)
    }

    pub fn safety_words(&self) -> Vec<String> {
        words::fingerprint_words(&self.cache.fp)
    }

    pub fn mailbox_hex(&self) -> String {
        hex(&card::mailbox(&self.cache.fp))
    }

    pub fn display_name(&self) -> String {
        self.st.identity.name.clone()
    }

    pub fn set_display_name(&mut self, name: String) {
        self.st.identity.name = name;
        self.cache.init_card = None;
    }

    fn card_body(&self, node_url: Option<String>, handle: Option<String>) -> CardBody {
        let id = &self.st.identity;
        let spk = id.prekeys.last().expect("at least one prekey");
        CardBody {
            v: 1,
            name: id.name.chars().take(128).collect(),
            ed_pub: self.cache.ed_pub,
            dsa_pub: self.cache.dsa_pub.clone(),
            dev_x: self.cache.dev_x_pub,
            dev_kem: self.cache.dev_kem_pub.clone(),
            spk_id: spk.id,
            spk_x: spk.x.public(),
            spk_kem: spk.kem.public(),
            node_url,
            handle,
            created_at: self.st.now_ms,
        }
    }

    fn build_card(&mut self, node_url: Option<String>, handle: Option<String>) -> Card {
        let body = self.card_body(node_url, handle);
        let sig = self.st.identity.sign.sign(&card::signed_message(&body), &mut self.rng);
        Card { body, sig }
    }

    /// Full contact card `relay1:...`. The node URL and handle are remembered
    /// and carried in the cards sent inside first messages.
    pub fn my_card(&mut self, node_url: Option<String>, handle: Option<String>) -> String {
        if node_url != self.st.identity.node_url || handle != self.st.identity.handle {
            self.st.identity.node_url = node_url.clone();
            self.st.identity.handle = handle.clone();
            self.cache.init_card = None;
        }
        self.build_card(node_url, handle).to_text()
    }

    pub fn my_compact_link(&self, node_url: Option<String>) -> String {
        Compact { fingerprint: self.cache.fp, node_url, handle: self.st.identity.handle.clone() }.to_text()
    }

    pub fn device_signing_public(&self) -> Vec<u8> {
        self.cache.ed_pub.to_vec()
    }

    pub fn sign_node_challenge(&self, nonce: &[u8]) -> Vec<u8> {
        let mut m = NODE_AUTH_DOMAIN.to_vec();
        m.extend_from_slice(nonce);
        m.extend_from_slice(&card::mailbox(&self.cache.fp));
        self.st.identity.sign.ed_sign(&m).to_vec()
    }

    pub fn rotate_prekey_if_due(&mut self, now_ms: i64) -> bool {
        self.tick(now_ms);
        let id = &mut self.st.identity;
        let Some(last) = id.prekeys.last_mut() else { return false };
        if last.created_ms == 0 {
            last.created_ms = now_ms;
            return false;
        }
        if now_ms.saturating_sub(last.created_ms) < PREKEY_MAX_AGE_MS {
            return false;
        }
        let spk = SignedPrekey {
            id: id.next_spk_id,
            x: XKey::generate(&mut self.rng),
            kem: KemKey::generate(&mut self.rng),
            created_ms: now_ms,
        };
        id.next_spk_id = id.next_spk_id.wrapping_add(1).max(1);
        id.prekeys.push(spk);
        if id.prekeys.len() > PREKEYS_KEPT {
            id.prekeys.remove(0);
        }
        self.cache.init_card = None;
        true
    }

    fn init_card(&mut self) -> Vec<u8> {
        if let Some(c) = &self.cache.init_card {
            return c.clone();
        }
        let (u, h) = (self.st.identity.node_url.clone(), self.st.identity.handle.clone());
        let bytes = self.build_card(u, h).to_bytes();
        self.cache.init_card = Some(bytes.clone());
        bytes
    }

    // ---------------------------------------------------------------- contacts

    fn contact_index(&self, fp: &[u8; 32]) -> Option<usize> {
        self.st.contacts.iter().position(|c| &c.fp == fp)
    }

    fn contact_by_hex(&self, fp: &str) -> Result<usize> {
        let fp = fp_from_hex(fp)?;
        self.contact_index(&fp).ok_or_else(|| RelayError::Unknown("unknown contact".into()))
    }

    /// Adds or refreshes a contact from a verified card.
    fn upsert_card(&mut self, card: Card, replace: bool) -> Result<usize> {
        let fp = card.fingerprint();
        if fp == self.cache.fp {
            return Err(RelayError::InvalidCard("this is your own card".into()));
        }
        if let Some(i) = self.contact_index(&fp) {
            let c = &mut self.st.contacts[i];
            if !c.card.same_keys(&card) {
                if !replace {
                    return Err(RelayError::KeyChanged(format!("keys changed for {}", hex(&fp))));
                }
                c.card = card;
                c.sessions.clear();
                c.verified = false;
                self.cache.contact_secrets.remove(&fp);
            } else if card.body.spk_id >= c.card.body.spk_id || card.body.created_at > c.card.body.created_at {
                c.card = card;
            }
            return Ok(i);
        }
        let name = card.body.name.clone();
        self.st.contacts.push(Contact { card, fp, name, verified: false, added_at: self.st.now_ms, sessions: Vec::new() });
        Ok(self.st.contacts.len() - 1)
    }

    pub fn add_contact(&mut self, card: &str) -> Result<ContactJson> {
        let card = Card::parse(card)?;
        let i = self.upsert_card(card, false)?;
        Ok(contact_json(&self.st.contacts[i]))
    }

    pub fn add_contact_replacing(&mut self, card: &str) -> Result<ContactJson> {
        let card = Card::parse(card)?;
        let i = self.upsert_card(card, true)?;
        Ok(contact_json(&self.st.contacts[i]))
    }

    pub fn parse_compact_link(&self, link: &str) -> Result<CompactJson> {
        let c = Compact::parse(link)?;
        Ok(CompactJson { fingerprint: hex(&c.fingerprint), node_url: c.node_url, handle: c.handle })
    }

    pub fn contacts(&self) -> String {
        let v: Vec<ContactJson> = self.st.contacts.iter().map(contact_json).collect();
        serde_json::to_string(&v).unwrap_or_else(|_| "[]".into())
    }

    pub fn remove_contact(&mut self, fp: &str) {
        if let Ok(fp) = fp_from_hex(fp) {
            self.st.contacts.retain(|c| c.fp != fp);
            self.cache.contact_secrets.remove(&fp);
        }
    }

    pub fn set_verified(&mut self, fp: &str, verified: bool) {
        if let Ok(i) = self.contact_by_hex(fp) {
            self.st.contacts[i].verified = verified;
        }
    }

    pub fn rename_contact(&mut self, fp: &str, name: String) {
        if let Ok(i) = self.contact_by_hex(fp) {
            self.st.contacts[i].name = name;
        }
    }

    pub fn contact_safety_words(&self, fp: &str) -> Vec<String> {
        fp_from_hex(fp).map(|fp| words::pair_words(&self.cache.fp, &fp)).unwrap_or_default()
    }

    pub fn contact_safety_code(&self, fp: &str) -> String {
        fp_from_hex(fp).map(|fp| words::pair_code(&self.cache.fp, &fp)).unwrap_or_default()
    }

    // ---------------------------------------------------------------- 1:1

    fn new_envelope(&mut self, kind: u8, tag: [u8; 16], payload: &[u8]) -> Vec<u8> {
        Envelope { v: 1, kind, tag, ttl: DEFAULT_TTL, id: self.rng.bytes(), body: pad(payload) }.to_bytes()
    }

    /// Encrypts a payload to contact `i` (opening a session when needed).
    fn encrypt_payload(&mut self, i: usize, payload: &Payload) -> Result<Vec<u8>> {
        let now = self.st.now_ms;
        if self.st.contacts[i].sessions.is_empty() {
            let card_bytes = self.init_card();
            let peer = self.st.contacts[i].card.clone();
            let s = {
                let me = Me {
                    fp: self.cache.fp,
                    dev_x: &self.st.identity.dev_x,
                    sign: &self.st.identity.sign,
                    card_bytes,
                };
                Session::initiate(&me, &peer, &mut self.rng, now)?
            };
            self.st.contacts[i].sessions.insert(0, s);
        }
        let plain = Zeroizing::new(to_postcard(payload));
        let body = self.st.contacts[i].sessions[0].encrypt(&plain, &mut self.rng, now)?;
        let tag = card::mailbox(&self.st.contacts[i].fp);
        Ok(self.new_envelope(KIND_DIRECT, tag, &to_postcard(&body)))
    }

    pub fn encrypt_for(&mut self, fp: &str, app_message_json: &str) -> Result<Vec<u8>> {
        let i = self.contact_by_hex(fp)?;
        let (bytes, ts) = parse_app(app_message_json)?;
        if let Some(ts) = ts {
            self.tick(ts);
        }
        self.encrypt_payload(i, &Payload::App(bytes))
    }

    fn contact_secret(&mut self, fp: &[u8; 32]) -> Option<[u8; 32]> {
        if let Some(s) = self.cache.contact_secrets.get(fp) {
            return Some(**s);
        }
        let c = &self.st.contacts[self.contact_index(fp)?];
        let dh = self.st.identity.dev_x.dh(&c.card.body.dev_x).ok()?;
        let (lo, hi) = if self.cache.fp <= *fp { (self.cache.fp, *fp) } else { (*fp, self.cache.fp) };
        let s = hkdf32(&[0u8; 32], &dh[..], &[b"soma-relay/v1/contact", &lo, &hi]);
        self.cache.contact_secrets.insert(*fp, Zeroizing::new(s));
        Some(s)
    }

    fn mesh_tag(&mut self, fp: &[u8; 32], hour: i64) -> Option<[u8; 16]> {
        let secret = Zeroizing::new(self.contact_secret(fp)?);
        let t = hkdf32(&secret[..], &hour.to_be_bytes(), &[b"soma-relay/v1/mesh-tag"]);
        let mut tag = [0u8; 16];
        tag.copy_from_slice(&t[..16]);
        Some(tag)
    }

    /// Current rotating mesh tag for a contact (empty for an unknown contact).
    pub fn mesh_tag_for(&mut self, fp: &str, now_ms: i64) -> Vec<u8> {
        self.tick(now_ms);
        let Ok(fp) = fp_from_hex(fp) else { return Vec::new() };
        self.mesh_tag(&fp, now_ms.div_euclid(HOUR_MS)).map(|t| t.to_vec()).unwrap_or_default()
    }

    /// Same envelope with its tag swapped for the mesh tag (input returned
    /// unchanged when it does not parse or the contact is unknown).
    pub fn retag_for_mesh(&mut self, envelope: &[u8], fp: &str, now_ms: i64) -> Vec<u8> {
        let tag = self.mesh_tag_for(fp, now_ms);
        let (Ok(mut env), Ok(tag)) = (Envelope::from_bytes(envelope), <[u8; 16]>::try_from(tag.as_slice())) else {
            return envelope.to_vec();
        };
        env.tag = tag;
        env.to_bytes()
    }

    /// Contact whose mesh tag (current or previous hour) is `tag`.
    fn contact_for_mesh_tag(&mut self, tag: &[u8; 16]) -> bool {
        let hour = self.st.now_ms.div_euclid(HOUR_MS);
        let fps: Vec<[u8; 32]> = self.st.contacts.iter().map(|c| c.fp).collect();
        fps.iter().any(|fp| {
            [hour, hour - 1, hour + 1]
                .iter()
                .any(|h| self.mesh_tag(fp, *h).is_some_and(|t| crate::util::ct_eq(&t, tag)))
        })
    }

    fn remember(&mut self, id: [u8; 16]) {
        self.st.seen.push_back(id);
        while self.st.seen.len() > SEEN_IDS {
            self.st.seen.pop_front();
        }
    }

    /// Opens an inbound envelope. `None` = not for this identity.
    pub fn open(&mut self, envelope: &[u8], now_ms: i64) -> Result<Option<String>> {
        self.tick(now_ms);
        let env = Envelope::from_bytes(envelope)?;
        if self.st.seen.contains(&env.id) {
            return Ok(None);
        }
        let out = match env.kind {
            KIND_DIRECT => self.open_direct(&env)?,
            KIND_GROUP => self.open_group(&env)?,
            KIND_CHANNEL => self.open_channel(&env)?,
            _ => None,
        };
        if let Some(inb) = out {
            self.remember(env.id);
            return Ok(Some(serde_json::to_string(&inb).map_err(|_| malformed("inbound"))?));
        }
        Ok(None)
    }

    fn find_session(&self, sid: &[u8; 16]) -> Option<(usize, usize)> {
        self.st
            .contacts
            .iter()
            .enumerate()
            .find_map(|(ci, c)| c.sessions.iter().position(|s| &s.id == sid).map(|si| (ci, si)))
    }

    fn open_direct(&mut self, env: &Envelope) -> Result<Option<InboundJson>> {
        let mine = crate::util::ct_eq(&env.tag, &card::mailbox(&self.cache.fp)) || self.contact_for_mesh_tag(&env.tag);
        if !mine {
            return Ok(None);
        }
        let body: DirectBody = from_postcard(unpad(&env.body)?, "direct body")?;
        let now = self.st.now_ms;
        let (msg, init) = match &body {
            DirectBody::Msg(m) => (m, None),
            DirectBody::Init { init, msg } => (msg, Some(init)),
        };
        let (ci, plain) = if let Some((ci, si)) = self.find_session(&msg.header.session_id) {
            let (s, plain) = self.st.contacts[ci].sessions[si].decrypt(msg, &mut self.rng, now)?;
            let sessions = &mut self.st.contacts[ci].sessions;
            sessions.remove(si);
            sessions.insert(0, s);
            (ci, plain)
        } else if let Some(init) = init {
            if self.st.seen_inits.contains(&init.ek) {
                return Err(RelayError::Decrypt("replayed opening".into()));
            }
            let (card, session) = {
                let me = Me {
                    fp: self.cache.fp,
                    dev_x: &self.st.identity.dev_x,
                    sign: &self.st.identity.sign,
                    card_bytes: Vec::new(),
                };
                let prekeys: Vec<Prekey> = self
                    .st
                    .identity
                    .prekeys
                    .iter()
                    .map(|p| Prekey { id: p.id, x: &p.x, kem: &p.kem })
                    .collect();
                Session::respond(&me, init, &prekeys, &mut self.rng, now)?
            };
            let (s, plain) = session.decrypt(msg, &mut self.rng, now)?;
            // Authenticated: record (or create, unverified) the sender.
            let ci = self.upsert_card(card, false)?;
            let sessions = &mut self.st.contacts[ci].sessions;
            sessions.insert(0, s);
            sessions.truncate(SESSIONS_PER_CONTACT);
            self.st.seen_inits.push_back(init.ek);
            while self.st.seen_inits.len() > SEEN_IDS {
                self.st.seen_inits.pop_front();
            }
            (ci, plain)
        } else {
            return Err(RelayError::NoSession("no session for this message".into()));
        };
        let plain = Zeroizing::new(plain);
        let from = self.st.contacts[ci].fp;
        let payload: Payload = from_postcard(&plain, "payload")?;
        let eid = hex(&env.id);
        match payload {
            Payload::App(bytes) => {
                let message: Value = serde_json::from_slice(&bytes).map_err(|_| malformed("AppMessage"))?;
                Ok(Some(InboundJson { from: hex(&from), group: None, channel: None, message, envelope_id: eid }))
            }
            Payload::GroupKey { group_id, ops, dist } => self.on_group_payload(from, group_id, &ops, Some(dist), eid).map(Some),
            Payload::GroupOps { group_id, ops } => self.on_group_payload(from, group_id, &ops, None, eid).map(Some),
        }
    }

    // ---------------------------------------------------------------- groups

    fn group_index(&self, gid: &str) -> Result<usize> {
        let g = unhex(gid)?;
        self.st.groups.iter().position(|x| x.id[..] == g[..]).ok_or_else(|| RelayError::Unknown("unknown group".into()))
    }

    fn group_event(&self, gi: usize, event: &str, eid: &str) -> Value {
        let g = &self.st.groups[gi];
        let (name, members, admins) = match g.view() {
            Ok(v) => (
                v.name,
                v.members.keys().map(|k| hex(k)).collect::<Vec<_>>(),
                v.admins.iter().map(|k| hex(k)).collect::<Vec<_>>(),
            ),
            Err(_) => (String::new(), vec![], vec![]),
        };
        json!({
            "id": eid,
            "ts": self.st.now_ms,
            "kind": "group-op",
            "group": { "id": hex(&g.id), "event": event, "name": name, "members": members, "admins": admins },
        })
    }

    fn on_group_payload(
        &mut self,
        from: [u8; 32],
        gid: [u8; 16],
        ops: &[SignedOp],
        dist: Option<KeyDist>,
        eid: String,
    ) -> Result<InboundJson> {
        let now = self.st.now_ms;
        let gi = match self.st.groups.iter().position(|g| g.id == gid) {
            Some(i) => i,
            None => {
                let g = Group {
                    id: gid,
                    ops: Vec::new(),
                    my_chain: SenderChain::generate(&mut self.rng, now),
                    distributed_to: Vec::new(),
                    receivers: Vec::new(),
                };
                self.st.groups.push(g);
                self.st.groups.len() - 1
            }
        };
        let fresh = self.st.groups[gi].ops.is_empty();
        let before: BTreeSet<[u8; 32]> =
            self.st.groups[gi].view().map(|v| v.members.keys().copied().collect()).unwrap_or_default();
        let mut g = self.st.groups[gi].clone();
        let merged = g.merge(ops).and_then(|_| g.view());
        let view = match merged {
            Ok(v) => v,
            Err(e) => {
                if fresh {
                    self.st.groups.remove(gi);
                }
                return Err(e);
            }
        };
        if !view.members.contains_key(&from) {
            if fresh {
                self.st.groups.remove(gi);
            }
            return Err(RelayError::Group("sender is not a member".into()));
        }
        let gid_hex = hex(&gid);
        if !view.members.contains_key(&self.cache.fp) {
            self.st.groups[gi] = g;
            let ev = self.group_event(gi, "removed", &eid);
            self.st.groups.remove(gi);
            return Ok(InboundJson { from: hex(&from), group: Some(gid_hex), channel: None, message: ev, envelope_id: eid });
        }
        let removed: Vec<[u8; 32]> = before.iter().filter(|f| !view.members.contains_key(*f)).copied().collect();
        if !removed.is_empty() {
            for f in &removed {
                g.drop_member(f);
            }
            g.rotate(&mut self.rng, now);
        }
        if let Some(d) = &dist {
            g.install(from, d);
        }
        self.st.groups[gi] = g;
        let event = if dist.is_some() { "key" } else { "update" };
        let ev = self.group_event(gi, event, &eid);
        Ok(InboundJson { from: hex(&from), group: Some(gid_hex), channel: None, message: ev, envelope_id: eid })
    }

    fn open_group(&mut self, env: &Envelope) -> Result<Option<InboundJson>> {
        let Some(gi) = self.st.groups.iter().position(|g| crate::util::ct_eq(&group_tag(&g.id), &env.tag)) else {
            return Ok(None);
        };
        let m: crate::group::GroupMsg = from_postcard(unpad(&env.body)?, "group message")?;
        let (owner, plain) = self.st.groups[gi].decrypt(&m)?;
        let message: Value = serde_json::from_slice(&plain).map_err(|_| malformed("AppMessage"))?;
        Ok(Some(InboundJson {
            from: hex(&owner),
            group: Some(hex(&self.st.groups[gi].id)),
            channel: None,
            message,
            envelope_id: hex(&env.id),
        }))
    }

    fn my_card_bytes(&mut self) -> Vec<u8> {
        self.init_card()
    }

    pub fn create_group(&mut self, name: String, member_fps: Vec<String>) -> Result<String> {
        let mut cards = vec![self.my_card_bytes()];
        let mut seen = BTreeSet::new();
        for fp in &member_fps {
            let i = self.contact_by_hex(fp)?;
            if seen.insert(self.st.contacts[i].fp) {
                cards.push(self.st.contacts[i].card.to_bytes());
            }
        }
        let now = self.st.now_ms;
        let mut g = Group {
            id: self.rng.bytes(),
            ops: Vec::new(),
            my_chain: SenderChain::generate(&mut self.rng, now),
            distributed_to: Vec::new(),
            receivers: Vec::new(),
        };
        let name: String = name.chars().take(128).collect();
        let op = g.new_op(OpKind::Create { name, members: cards }, self.cache.fp, &self.st.identity.sign, &mut self.rng);
        g.merge(&[op])?;
        g.view()?;
        let id = hex(&g.id);
        self.st.groups.push(g);
        Ok(id)
    }

    /// Contact index of a group member, adding the member's card (unverified)
    /// when it is not a contact yet.
    fn member_contact(&mut self, card: &Card) -> Result<usize> {
        match self.contact_index(&card.fingerprint()) {
            Some(i) => Ok(i),
            None => self.upsert_card(card.clone(), false),
        }
    }

    fn send_group_payload(&mut self, member: &Card, payload: &Payload) -> Result<Vec<u8>> {
        let i = self.member_contact(member)?;
        self.encrypt_payload(i, payload)
    }

    /// Distribution envelopes first, the group envelope last.
    pub fn group_encrypt(&mut self, group_id: &str, app_message_json: &str) -> Result<Vec<Vec<u8>>> {
        let gi = self.group_index(group_id)?;
        let (bytes, ts) = parse_app(app_message_json)?;
        if let Some(ts) = ts {
            self.tick(ts);
        }
        let now = self.st.now_ms;
        let view = self.st.groups[gi].view()?;
        if !view.members.contains_key(&self.cache.fp) {
            return Err(RelayError::Group("not a member".into()));
        }
        {
            let g = &mut self.st.groups[gi];
            if g.my_chain.created_ms > 0 && now.saturating_sub(g.my_chain.created_ms) >= SENDER_KEY_MAX_AGE_MS {
                g.rotate(&mut self.rng, now);
            } else if g.my_chain.created_ms == 0 {
                g.my_chain.created_ms = now;
            }
        }
        let mut out = Vec::new();
        let pending: Vec<Card> = view
            .members
            .iter()
            .filter(|(fp, _)| **fp != self.cache.fp && !self.st.groups[gi].distributed_to.contains(fp))
            .map(|(_, c)| c.clone())
            .collect();
        if !pending.is_empty() {
            let g = &self.st.groups[gi];
            let payload = Payload::GroupKey { group_id: g.id, ops: g.ops.clone(), dist: g.dist() };
            for card in &pending {
                out.push(self.send_group_payload(card, &payload)?);
                self.st.groups[gi].distributed_to.push(card.fingerprint());
            }
        }
        let msg = self.st.groups[gi].encrypt(&bytes);
        let tag = group_tag(&self.st.groups[gi].id);
        out.push(self.new_envelope(KIND_GROUP, tag, &to_postcard(&msg)));
        Ok(out)
    }

    fn require_admin(&self, gi: usize) -> Result<crate::group::View> {
        let v = self.st.groups[gi].view()?;
        if !v.admins.contains(&self.cache.fp) {
            return Err(RelayError::Group("only an admin can change members".into()));
        }
        Ok(v)
    }

    /// Adds a contact. Returns the envelopes to send (key + log to the new
    /// member, the new operation to the others).
    pub fn group_add(&mut self, group_id: &str, fp: &str) -> Result<Vec<Vec<u8>>> {
        let gi = self.group_index(group_id)?;
        let view = self.require_admin(gi)?;
        let ci = self.contact_by_hex(fp)?;
        let card = self.st.contacts[ci].card.clone();
        if view.members.contains_key(&card.fingerprint()) {
            return Ok(Vec::new());
        }
        let op = self.st.groups[gi].new_op(
            OpKind::Add { card: card.to_bytes() },
            self.cache.fp,
            &self.st.identity.sign,
            &mut self.rng,
        );
        self.st.groups[gi].merge(std::slice::from_ref(&op))?;
        let g = &self.st.groups[gi];
        let gid = g.id;
        let to_new = Payload::GroupKey { group_id: gid, ops: g.ops.clone(), dist: g.dist() };
        let to_others = Payload::GroupOps { group_id: gid, ops: vec![op] };
        let mut out = vec![self.send_group_payload(&card, &to_new)?];
        self.st.groups[gi].distributed_to.push(card.fingerprint());
        for (mfp, mcard) in &view.members {
            if *mfp != self.cache.fp {
                out.push(self.send_group_payload(mcard, &to_others)?);
            }
        }
        Ok(out)
    }

    /// Removes a member and rotates the sender key. Returns the envelopes to
    /// send (new key + log to the remaining members, the operation to the
    /// removed one).
    pub fn group_remove(&mut self, group_id: &str, fp: &str) -> Result<Vec<Vec<u8>>> {
        let gi = self.group_index(group_id)?;
        let view = self.require_admin(gi)?;
        let target = fp_from_hex(fp)?;
        let Some(target_card) = view.members.get(&target).cloned() else {
            return Ok(Vec::new());
        };
        let now = self.st.now_ms;
        let op = self.st.groups[gi].new_op(OpKind::Remove { fp: target }, self.cache.fp, &self.st.identity.sign, &mut self.rng);
        self.st.groups[gi].merge(std::slice::from_ref(&op))?;
        self.st.groups[gi].drop_member(&target);
        self.st.groups[gi].rotate(&mut self.rng, now);
        let g = &self.st.groups[gi];
        let gid = g.id;
        let to_members = Payload::GroupKey { group_id: gid, ops: g.ops.clone(), dist: g.dist() };
        let mut out = Vec::new();
        if target != self.cache.fp {
            out.push(self.send_group_payload(&target_card, &Payload::GroupOps { group_id: gid, ops: vec![op] })?);
        }
        for (mfp, mcard) in &view.members {
            if *mfp != self.cache.fp && *mfp != target {
                out.push(self.send_group_payload(mcard, &to_members)?);
                self.st.groups[gi].distributed_to.push(*mfp);
            }
        }
        if target == self.cache.fp {
            self.st.groups.remove(gi);
        }
        Ok(out)
    }

    pub fn groups(&self) -> String {
        let v: Vec<Value> = self
            .st
            .groups
            .iter()
            .filter_map(|g| {
                let view = g.view().ok()?;
                Some(json!({
                    "id": hex(&g.id),
                    "name": view.name,
                    "members": view.members.keys().map(|k| hex(k)).collect::<Vec<_>>(),
                    "mailboxes": view.members.keys().map(|k| hex(&card::mailbox(k))).collect::<Vec<_>>(),
                    "admins": view.admins.iter().map(|k| hex(k)).collect::<Vec<_>>(),
                }))
            })
            .collect();
        serde_json::to_string(&v).unwrap_or_else(|_| "[]".into())
    }

    pub fn leave_group(&mut self, group_id: &str) {
        if let Ok(gi) = self.group_index(group_id) {
            self.st.groups.remove(gi);
        }
    }

    // ---------------------------------------------------------------- channels

    fn channel_for(&mut self, name: &str, password: Option<&str>) -> Result<Channel> {
        let n = normalize(name);
        let has_pw = password.is_some_and(|p| !p.is_empty());
        if let Some(c) = self.st.channels.iter().find(|c| c.name == n && c.password == has_pw)
            && !has_pw
        {
            return Ok(c.clone());
        }
        Channel::derive(name, password)
    }

    pub fn join_channel(&mut self, name: &str, password: Option<String>) -> Result<()> {
        let ch = Channel::derive(name, password.as_deref())?;
        self.st.channels.retain(|c| c.name != ch.name);
        self.st.channels.push(ch);
        Ok(())
    }

    pub fn leave_channel(&mut self, name: &str) {
        let n = normalize(name);
        self.st.channels.retain(|c| c.name != n);
    }

    pub fn channel_encrypt(&mut self, name: &str, password: Option<String>, app_message_json: &str) -> Result<Vec<u8>> {
        let (bytes, ts) = parse_app(app_message_json)?;
        if let Some(ts) = ts {
            self.tick(ts);
        }
        let n = normalize(name);
        // A joined channel reuses its derived key (no Argon2 per message).
        let ch = match self.st.channels.iter().find(|c| c.name == n) {
            Some(c) if password.as_deref().is_none_or(str::is_empty) == !c.password => c.clone(),
            _ => self.channel_for(name, password.as_deref())?,
        };
        let sign = &self.st.identity.sign;
        let nonce = self.rng.bytes();
        let msg = ChannelMsg::build(&ch, self.cache.fp, self.cache.ed_pub, |m| sign.ed_sign(m), nonce, &bytes);
        Ok(self.new_envelope(KIND_CHANNEL, ch.tag, &to_postcard(&msg)))
    }

    fn open_channel(&mut self, env: &Envelope) -> Result<Option<InboundJson>> {
        let Some(ch) = self.st.channels.iter().find(|c| crate::util::ct_eq(&c.tag, &env.tag)).cloned() else {
            return Ok(None);
        };
        let m: ChannelMsg = from_postcard(unpad(&env.body)?, "channel message")?;
        if m.fp == self.cache.fp {
            return Ok(None);
        }
        let plain = m.open(&ch)?;
        if let Some(i) = self.contact_index(&m.fp)
            && self.st.contacts[i].card.body.ed_pub != m.ed_pub
        {
            return Err(RelayError::Decrypt("channel sender impersonates a contact".into()));
        }
        // Rate limit per sender key (after the signature check).
        let now = self.st.now_ms;
        let e = self.cache.rate.entry(m.ed_pub).or_insert((now, 0));
        if now.saturating_sub(e.0) >= 60_000 {
            *e = (now, 0);
        }
        e.1 += 1;
        if e.1 > RATE_PER_MINUTE {
            return Ok(None);
        }
        let message: Value = serde_json::from_slice(&plain).map_err(|_| malformed("AppMessage"))?;
        Ok(Some(InboundJson {
            from: hex(&m.fp),
            group: None,
            channel: Some(ch.name.clone()),
            message,
            envelope_id: hex(&env.id),
        }))
    }

    // ---------------------------------------------------------------- misc

    pub fn seal_attachment(&mut self, plain: &[u8]) -> Vec<u8> {
        attachment::seal_attachment(plain, &mut self.rng)
    }

    pub fn open_attachment(key: &[u8], sha256: &[u8], ciphertext: &[u8]) -> Result<Vec<u8>> {
        attachment::open_attachment(key, sha256, ciphertext)
    }

    pub fn call_key(&self, fp: &str, call_id: &str) -> Result<Vec<u8>> {
        let i = self.contact_by_hex(fp)?;
        let s = self.st.contacts[i].sessions.first().ok_or_else(|| RelayError::NoSession("no session with this contact".into()))?;
        Ok(s.call_key(call_id).to_vec())
    }

    /// `{id, kind, tag, ttl, size}` of an envelope (hex fields), for routing.
    pub fn envelope_info(envelope: &[u8]) -> Result<String> {
        let e = Envelope::from_bytes(envelope)?;
        let kind = match e.kind {
            KIND_DIRECT => "direct",
            KIND_GROUP => "group",
            KIND_CHANNEL => "channel",
            4 => "announce",
            _ => "control",
        };
        Ok(json!({ "id": hex(&e.id), "kind": kind, "tag": hex(&e.tag), "ttl": e.ttl, "size": envelope.len() }).to_string())
    }

    // ---------------------------------------------------------------- tests

    #[cfg(test)]
    pub(crate) fn pq_steps_with(&self, fp: &[u8; 32]) -> u32 {
        self.contact_index(fp).and_then(|i| self.st.contacts[i].sessions.first()).map_or(0, |s| s.pq_steps)
    }

    /// Replaces the device keys (simulates a reinstall with the same identity).
    #[cfg(any(test, feature = "testing"))]
    pub fn regenerate_device_keys(&mut self) {
        self.st.identity.dev_x = XKey::generate(&mut self.rng);
        self.st.identity.dev_kem = KemKey::generate(&mut self.rng);
        self.cache = new_cache(&self.st.identity);
    }
}
