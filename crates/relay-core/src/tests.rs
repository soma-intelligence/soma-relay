use serde_json::{Value, json};

use crate::card::{Card, mailbox};
use crate::envelope::Envelope;
use crate::mesh::{Frame, MeshRouter, Reassembler, fragment};
use crate::util::{b64url, bucket, fp_from_hex, hex, unb64url};
use crate::{RelayEngine, RelayError};

const T0: i64 = 1_763_700_000_000;

fn engine(name: &str, n: u8) -> RelayEngine {
    let mut e = RelayEngine::create_with_seed(name.into(), [n; 32]);
    e.rotate_prekey_if_due(T0);
    e
}

fn msg(text: &str, ts: i64) -> String {
    json!({ "id": format!("m-{text}"), "ts": ts, "kind": "text", "text": text }).to_string()
}

fn open(e: &mut RelayEngine, env: &[u8]) -> Value {
    let s = e.open(env, T0).expect("open").expect("for me");
    serde_json::from_str(&s).expect("inbound json")
}

/// A knows B's card; B learns A from the first message.
fn pair() -> (RelayEngine, RelayEngine) {
    let a = engine("Alice", 1);
    let mut b = engine("Bob", 2);
    let card_b = b.my_card(Some("https://node.example".into()), None);
    let mut a = a;
    a.add_contact(&card_b).unwrap();
    (a, b)
}

fn text_of(v: &Value) -> &str {
    v["message"]["text"].as_str().unwrap_or("")
}

#[test]
fn card_round_trip_and_tamper() {
    let mut a = engine("Alice", 1);
    let card = a.my_card(Some("https://n.example".into()), Some("alice".into()));
    assert!(card.starts_with("relay1:"));
    let parsed = Card::parse(&card).unwrap();
    assert_eq!(hex(&parsed.fingerprint()), a.fingerprint_hex());
    assert_eq!(parsed.body.handle.as_deref(), Some("alice"));

    // Flip one byte of the name inside the signed body.
    let mut bytes = unb64url(card.trim_start_matches("relay1:")).unwrap();
    let pos = bytes.windows(5).position(|w| w == b"Alice").unwrap();
    bytes[pos] = b'X';
    let tampered = format!("relay1:{}", b64url(&bytes));
    let mut b = engine("Bob", 2);
    assert!(matches!(b.add_contact(&tampered), Err(RelayError::InvalidCard(_))));
    assert!(matches!(b.add_contact("relay1:AAAA"), Err(RelayError::InvalidCard(_))));
    assert!(matches!(a.add_contact(&card), Err(RelayError::InvalidCard(_))), "own card refused");

    let c = b.add_contact(&card).unwrap();
    assert_eq!(c.fingerprint, a.fingerprint_hex());
    assert_eq!(c.mailbox, a.mailbox_hex());
    assert!(!c.verified);
    // Idempotent.
    b.add_contact(&card).unwrap();
    let list: Vec<Value> = serde_json::from_str(&b.contacts()).unwrap();
    assert_eq!(list.len(), 1);
}

#[test]
fn compact_link() {
    let a = engine("Alice", 1);
    let link = a.my_compact_link(Some("https://n.example".into()));
    assert!(link.starts_with("relay1c:"));
    assert!(link.len() < 200);
    let c = a.parse_compact_link(&link).unwrap();
    assert_eq!(c.fingerprint, a.fingerprint_hex());
    assert_eq!(c.node_url.as_deref(), Some("https://n.example"));
    assert!(a.parse_compact_link("relay1c:!!").is_err());
}

#[test]
fn identity_strings_and_safety_words() {
    let (a, b) = pair();
    assert_eq!(a.fingerprint_hex().len(), 64);
    assert_eq!(a.mailbox_hex().len(), 32);
    assert_eq!(a.safety_words().len(), 4);
    assert_eq!(crate::words::word_list().len(), 2048);
    let wa = a.contact_safety_words(&b.fingerprint_hex());
    let wb = b.contact_safety_words(&a.fingerprint_hex());
    assert_eq!(wa, wb);
    assert_eq!(wa.len(), 4);
    let ca = a.contact_safety_code(&b.fingerprint_hex());
    assert_eq!(ca, b.contact_safety_code(&a.fingerprint_hex()));
    assert_eq!(ca.len(), 11);
    assert_eq!(&ca[3..4], " ");
}

#[test]
fn node_challenge_signature() {
    let a = engine("Alice", 1);
    let nonce = [7u8; 32];
    let sig = a.sign_node_challenge(&nonce);
    let mut m = b"soma-relay/node-auth/v1".to_vec();
    m.extend_from_slice(&nonce);
    m.extend_from_slice(&mailbox(&fp_from_hex(&a.fingerprint_hex()).unwrap()));
    let pubk: [u8; 32] = a.device_signing_public().try_into().unwrap();
    assert!(crate::hybrid::ed_verify(&pubk, &m, &sig));
}

#[test]
fn direct_round_trip_and_message_request() {
    let (mut a, mut b) = pair();
    let fb = b.fingerprint_hex();
    let env = a.encrypt_for(&fb, &msg("salut", T0)).unwrap();
    let e = Envelope::from_bytes(&env).unwrap();
    assert_eq!(hex(&e.tag), b.mailbox_hex());
    assert_eq!(e.body.len() % 1024, 0, "padded to a bucket");

    // B does not know A: the first message adds A as an unverified contact.
    let v = open(&mut b, &env);
    assert_eq!(v["from"], a.fingerprint_hex());
    assert_eq!(text_of(&v), "salut");
    let contacts: Vec<Value> = serde_json::from_str(&b.contacts()).unwrap();
    assert_eq!(contacts[0]["fingerprint"], a.fingerprint_hex());
    assert_eq!(contacts[0]["verified"], false);

    let fa = a.fingerprint_hex();
    for i in 0..3 {
        let r = b.encrypt_for(&fa, &msg(&format!("r{i}"), T0)).unwrap();
        assert_eq!(text_of(&open(&mut a, &r)), format!("r{i}"));
        let s = a.encrypt_for(&fb, &msg(&format!("s{i}"), T0)).unwrap();
        // After B answered, A's messages no longer carry the opening.
        assert!(s.len() < 4200, "no init header once answered");
        assert_eq!(text_of(&open(&mut b, &s)), format!("s{i}"));
    }
    // Not for a third party.
    let mut c = engine("Carol", 3);
    let s = a.encrypt_for(&fb, &msg("x", T0)).unwrap();
    assert_eq!(c.open(&s, T0).unwrap(), None);
}

#[test]
fn out_of_order_and_loss() {
    let (mut a, mut b) = pair();
    let fb = b.fingerprint_hex();
    let fa = a.fingerprint_hex();
    let first = a.encrypt_for(&fb, &msg("0", T0)).unwrap();
    open(&mut b, &first);
    let r = b.encrypt_for(&fa, &msg("ack", T0)).unwrap();
    open(&mut a, &r);

    let envs: Vec<Vec<u8>> = (1..=6).map(|i| a.encrypt_for(&fb, &msg(&i.to_string(), T0)).unwrap()).collect();
    // Shuffled, and message 3 lost for now.
    for i in [5usize, 1, 4, 0] {
        assert_eq!(text_of(&open(&mut b, &envs[i])), (i + 1).to_string());
    }
    // Direction change while 3 and 6 are still in flight.
    let r = b.encrypt_for(&fa, &msg("mid", T0)).unwrap();
    open(&mut a, &r);
    let late = a.encrypt_for(&fb, &msg("new-chain", T0)).unwrap();
    assert_eq!(text_of(&open(&mut b, &late)), "new-chain");
    assert_eq!(text_of(&open(&mut b, &envs[3])), "4");
    assert_eq!(text_of(&open(&mut b, &envs[2])), "3");
}

#[test]
fn duplicates_and_replays_rejected() {
    let (mut a, mut b) = pair();
    let fb = b.fingerprint_hex();
    let env = a.encrypt_for(&fb, &msg("once", T0)).unwrap();
    open(&mut b, &env);
    assert_eq!(b.open(&env, T0).unwrap(), None, "same envelope id");
    // Same ciphertext under a fresh envelope id: the message key is gone.
    let mut e = Envelope::from_bytes(&env).unwrap();
    e.id = [9u8; 16];
    assert!(b.open(&e.to_bytes(), T0).is_err());
    // Replayed opening after the session is gone (contact removed and re-added).
    let fa = a.fingerprint_hex();
    b.remove_contact(&fa);
    let mut e = Envelope::from_bytes(&env).unwrap();
    e.id = [10u8; 16];
    assert!(matches!(b.open(&e.to_bytes(), T0), Err(RelayError::Decrypt(_))));
}

#[test]
fn tampered_envelope_rejected() {
    let (mut a, mut b) = pair();
    let fb = b.fingerprint_hex();
    let fa = a.fingerprint_hex();
    let env = a.encrypt_for(&fb, &msg("hello", T0)).unwrap();
    open(&mut b, &env);
    let r = b.encrypt_for(&fa, &msg("back", T0)).unwrap();
    open(&mut a, &r);
    let env = a.encrypt_for(&fb, &msg("secret", T0)).unwrap();
    let mut e = Envelope::from_bytes(&env).unwrap();
    // Flip a byte in the ciphertext region (after the 4-byte length prefix and header).
    let len = u32::from_le_bytes(e.body[..4].try_into().unwrap()) as usize;
    e.body[4 + len - 3] ^= 0x01;
    assert!(matches!(b.open(&e.to_bytes(), T0), Err(RelayError::Decrypt(_))));
    // State untouched: the genuine message still opens.
    assert_eq!(text_of(&open(&mut b, &env)), "secret");
    // Garbage is malformed, not a panic.
    assert!(b.open(&[1, 2, 3], T0).is_err());
    let mut e2 = Envelope::from_bytes(&env).unwrap();
    e2.body = vec![0xff; 300];
    e2.id = [3; 16];
    assert!(b.open(&e2.to_bytes(), T0).is_err());
}

#[test]
fn pq_ratchet_step_keeps_both_sides_in_sync() {
    let (mut a, mut b) = pair();
    let fb = b.fingerprint_hex();
    let fa = a.fingerprint_hex();
    let fpa = fp_from_hex(&fa).unwrap();
    let fpb = fp_from_hex(&fb).unwrap();
    let env = a.encrypt_for(&fb, &msg("start", T0)).unwrap();
    open(&mut b, &env);
    let r = b.encrypt_for(&fa, &msg("hi", T0)).unwrap();
    open(&mut a, &r);
    assert_eq!(a.pq_steps_with(&fpb), 0);
    for i in 0..55 {
        let e = a.encrypt_for(&fb, &msg(&format!("m{i}"), T0)).unwrap();
        open(&mut b, &e);
    }
    // Direction change after >= 50 messages: B's chain carries an ML-KEM step.
    let r = b.encrypt_for(&fa, &msg("pq", T0)).unwrap();
    assert_eq!(b.pq_steps_with(&fpa), 1);
    assert_eq!(text_of(&open(&mut a, &r)), "pq");
    assert_eq!(a.pq_steps_with(&fpb), 1);
    for i in 0..5 {
        let e = a.encrypt_for(&fb, &msg(&format!("after{i}"), T0)).unwrap();
        assert_eq!(text_of(&open(&mut b, &e)), format!("after{i}"));
        let e = b.encrypt_for(&fa, &msg(&format!("back{i}"), T0)).unwrap();
        assert_eq!(text_of(&open(&mut a, &e)), format!("back{i}"));
    }
    // Time based step: 25 hours later.
    let later = T0 + 25 * 3600 * 1000;
    let e = a.encrypt_for(&fb, &msg("tomorrow", later)).unwrap();
    assert_eq!(text_of(&open(&mut b, &e)), "tomorrow");
    let e = b.encrypt_for(&fa, &msg("yes", later)).unwrap();
    assert_eq!(text_of(&open(&mut a, &e)), "yes");
    assert!(a.pq_steps_with(&fpb) >= 2);
    assert_eq!(b.pq_steps_with(&fpa), a.pq_steps_with(&fpb));
}

#[test]
fn restore_mid_conversation() {
    let (mut a, mut b) = pair();
    let fb = b.fingerprint_hex();
    let fa = a.fingerprint_hex();
    let env = a.encrypt_for(&fb, &msg("1", T0)).unwrap();
    open(&mut b, &env);
    let pending = a.encrypt_for(&fb, &msg("2", T0)).unwrap();
    let mut a2 = RelayEngine::restore(&a.export_state()).unwrap();
    let mut b2 = RelayEngine::restore(&b.export_state()).unwrap();
    assert_eq!(a2.fingerprint_hex(), fa);
    assert_eq!(text_of(&open(&mut b2, &pending)), "2");
    let r = b2.encrypt_for(&fa, &msg("3", T0)).unwrap();
    assert_eq!(text_of(&open(&mut a2, &r)), "3");
    let s = a2.encrypt_for(&fb, &msg("4", T0)).unwrap();
    assert_eq!(text_of(&open(&mut b2, &s)), "4");
    assert!(matches!(RelayEngine::restore(&[1, 2, 3]), Err(RelayError::Storage(_))));
}

#[test]
fn key_change_detected() {
    let (mut a, mut b) = pair();
    let fb = b.fingerprint_hex();
    let env = a.encrypt_for(&fb, &msg("x", T0)).unwrap();
    open(&mut b, &env);
    b.regenerate_device_keys();
    let new_card = b.my_card(None, None);
    assert!(matches!(a.add_contact(&new_card), Err(RelayError::KeyChanged(_))));
    let c = a.add_contact_replacing(&new_card).unwrap();
    assert!(!c.verified);
    // A fresh session opens against the new keys.
    let env = a.encrypt_for(&fb, &msg("again", T0)).unwrap();
    assert_eq!(text_of(&open(&mut b, &env)), "again");
}

#[test]
fn prekey_rotation_keeps_old_prekey_working() {
    let (mut a, mut b) = pair();
    assert!(!b.rotate_prekey_if_due(T0 + 1000));
    assert!(b.rotate_prekey_if_due(T0 + 8 * 24 * 3600 * 1000));
    // A still uses the old card's prekey.
    let env = a.encrypt_for(&b.fingerprint_hex(), &msg("old spk", T0)).unwrap();
    assert_eq!(text_of(&open(&mut b, &env)), "old spk");
}

#[test]
fn mesh_tag_retag() {
    let (mut a, mut b) = pair();
    let fb = b.fingerprint_hex();
    let fa = a.fingerprint_hex();
    let env = a.encrypt_for(&fb, &msg("hi", T0)).unwrap();
    open(&mut b, &env);
    let tag_a = a.mesh_tag_for(&fb, T0);
    let tag_b = b.mesh_tag_for(&fa, T0);
    assert_eq!(tag_a.len(), 16);
    assert_eq!(tag_a, tag_b, "both sides derive the same tag");
    assert_ne!(tag_a, a.mesh_tag_for(&fb, T0 + 2 * 3600 * 1000), "rotates hourly");
    let env = a.encrypt_for(&fb, &msg("via mesh", T0)).unwrap();
    let meshed = a.retag_for_mesh(&env, &fb, T0);
    assert_eq!(Envelope::from_bytes(&meshed).unwrap().tag.to_vec(), tag_a);
    assert_eq!(text_of(&open(&mut b, &meshed)), "via mesh");
}

#[test]
fn call_key_matches() {
    let (mut a, mut b) = pair();
    let fb = b.fingerprint_hex();
    let fa = a.fingerprint_hex();
    assert!(matches!(a.call_key(&fb, "c1"), Err(RelayError::NoSession(_))));
    let env = a.encrypt_for(&fb, &msg("hi", T0)).unwrap();
    open(&mut b, &env);
    let ka = a.call_key(&fb, "c1").unwrap();
    assert_eq!(ka.len(), 32);
    assert_eq!(ka, b.call_key(&fa, "c1").unwrap());
    assert_ne!(ka, a.call_key(&fb, "c2").unwrap());
}

fn deliver_all(to: &mut RelayEngine, envs: &[Vec<u8>]) -> Vec<Value> {
    envs.iter()
        .filter_map(|e| to.open(e, T0).unwrap().map(|s| serde_json::from_str(&s).unwrap()))
        .collect()
}

#[test]
fn groups_create_add_remove_with_rotation() {
    let mut a = engine("Alice", 1);
    let mut b = engine("Bob", 2);
    let mut c = engine("Carol", 3);
    let mut d = engine("Dan", 4);
    for x in [&mut b, &mut c, &mut d] {
        let card = x.my_card(None, None);
        a.add_contact(&card).unwrap();
    }
    let (fb, fc, fd) = (b.fingerprint_hex(), c.fingerprint_hex(), d.fingerprint_hex());
    let gid = a.create_group("Trek".into(), vec![fb.clone(), fc.clone()]).unwrap();
    let out = a.group_encrypt(&gid, &msg("bonjour", T0)).unwrap();
    assert_eq!(out.len(), 3, "two distributions then the group message");
    let (group_env, dists) = out.split_last().unwrap();
    for x in [&mut b, &mut c] {
        let evs = deliver_all(x, dists);
        assert_eq!(evs.len(), 1);
        assert_eq!(evs[0]["message"]["kind"], "group-op");
        assert_eq!(evs[0]["group"], gid);
        let v = open(x, group_env);
        assert_eq!(text_of(&v), "bonjour");
        assert_eq!(v["from"], a.fingerprint_hex());
        assert_eq!(v["group"], gid);
    }
    let groups: Vec<Value> = serde_json::from_str(&b.groups()).unwrap();
    assert_eq!(groups[0]["name"], "Trek");
    assert_eq!(groups[0]["members"].as_array().unwrap().len(), 3);

    // B speaks: distributes its key to A and C first.
    let out = b.group_encrypt(&gid, &msg("salut", T0)).unwrap();
    assert_eq!(out.len(), 3);
    for x in [&mut a, &mut c] {
        let mut got = deliver_all(x, &out);
        let last = got.pop().unwrap();
        assert_eq!(text_of(&last), "salut");
    }

    // A removes C: rotation.
    let out = a.group_remove(&gid, &fc).unwrap();
    assert_eq!(out.len(), 2);
    deliver_all(&mut b, &out);
    let evs = deliver_all(&mut c, &out);
    assert_eq!(evs[0]["message"]["group"]["event"], "removed");
    let groups: Vec<Value> = serde_json::from_str(&c.groups()).unwrap();
    assert!(groups.is_empty());

    let out = a.group_encrypt(&gid, &msg("sans carol", T0)).unwrap();
    assert_eq!(out.len(), 1, "B already has the rotated key");
    assert_eq!(text_of(&open(&mut b, &out[0])), "sans carol");
    assert_eq!(c.open(&out[0], T0).unwrap(), None, "C no longer matches the group");

    // B rotated too after seeing the removal.
    let out = b.group_encrypt(&gid, &msg("b rotated", T0)).unwrap();
    assert_eq!(out.len(), 2);
    let got = deliver_all(&mut a, &out);
    assert_eq!(text_of(got.last().unwrap()), "b rotated");

    // Add D.
    let out = a.group_add(&gid, &fd).unwrap();
    assert_eq!(out.len(), 2, "key to D, op to B");
    deliver_all(&mut d, &out[..1]);
    deliver_all(&mut b, &out[1..]);
    let out = a.group_encrypt(&gid, &msg("welcome", T0)).unwrap();
    assert_eq!(text_of(&open(&mut d, out.last().unwrap())), "welcome");
    // D speaks: its key goes to A and B (B learns D from the op log).
    let out = d.group_encrypt(&gid, &msg("merci", T0)).unwrap();
    assert_eq!(out.len(), 3);
    assert_eq!(text_of(deliver_all(&mut b, &out).last().unwrap()), "merci");

    // Only admins change members.
    assert!(matches!(b.group_remove(&gid, &a.fingerprint_hex()), Err(RelayError::Group(_))));
    // State survives export.
    let mut b2 = RelayEngine::restore(&b.export_state()).unwrap();
    let out = a.group_encrypt(&gid, &msg("restored", T0)).unwrap();
    assert_eq!(text_of(&open(&mut b2, out.last().unwrap())), "restored");
}

#[test]
fn group_message_tamper_and_unknown_key() {
    let mut a = engine("Alice", 1);
    let mut b = engine("Bob", 2);
    let card = b.my_card(None, None);
    a.add_contact(&card).unwrap();
    let gid = a.create_group("G".into(), vec![b.fingerprint_hex()]).unwrap();
    let out = a.group_encrypt(&gid, &msg("one", T0)).unwrap();
    // Group message before the distribution: not recognised yet, retry works later.
    assert_eq!(b.open(&out[1], T0).unwrap(), None);
    deliver_all(&mut b, &out[..1]);
    let mut e = Envelope::from_bytes(&out[1]).unwrap();
    let len = u32::from_le_bytes(e.body[..4].try_into().unwrap()) as usize;
    e.body[4 + len - 70] ^= 1;
    assert!(b.open(&e.to_bytes(), T0).is_err());
    assert_eq!(text_of(&open(&mut b, &out[1])), "one");
}

#[test]
fn channels() {
    let mut a = engine("Alice", 1);
    let mut b = engine("Bob", 2);
    b.join_channel("#Festival", None).unwrap();
    let env = a.channel_encrypt("festival", None, &msg("open air", T0)).unwrap();
    let v = open(&mut b, &env);
    assert_eq!(v["channel"], "festival");
    assert_eq!(v["from"], a.fingerprint_hex());
    assert_eq!(text_of(&v), "open air");

    b.join_channel("secret", Some("pw".into())).unwrap();
    let wrong = a.channel_encrypt("secret", Some("nope".into()), &msg("x", T0)).unwrap();
    assert_eq!(b.open(&wrong, T0).unwrap(), None);
    let right = a.channel_encrypt("secret", Some("pw".into()), &msg("y", T0)).unwrap();
    assert_eq!(text_of(&open(&mut b, &right)), "y");

    b.leave_channel("festival");
    let env = a.channel_encrypt("festival", None, &msg("gone", T0)).unwrap();
    assert_eq!(b.open(&env, T0).unwrap(), None);

    // Rate limit: 30 per minute per sender.
    let mut c = engine("Carol", 3);
    c.join_channel("busy", None).unwrap();
    let mut accepted = 0;
    for i in 0..40 {
        let e = a.channel_encrypt("busy", None, &msg(&i.to_string(), T0)).unwrap();
        if c.open(&e, T0).unwrap().is_some() {
            accepted += 1;
        }
    }
    assert_eq!(accepted, 30);
}

#[test]
fn attachments() {
    let mut a = engine("Alice", 1);
    for size in [0usize, 10, 65536, 65537, 200_000] {
        let plain: Vec<u8> = (0..size).map(|i| (i % 251) as u8).collect();
        let sealed = a.seal_attachment(&plain);
        let (key, rest) = sealed.split_at(32);
        let (sha, ct) = rest.split_at(32);
        assert_eq!(RelayEngine::open_attachment(key, sha, ct).unwrap(), plain);
        if !ct.is_empty() {
            let mut bad = ct.to_vec();
            bad[0] ^= 1;
            assert!(RelayEngine::open_attachment(key, sha, &bad).is_err());
        }
        if size > 65536 {
            // Truncation (dropping the last chunk) is caught.
            assert!(RelayEngine::open_attachment(key, sha, &ct[..65536 + 16]).is_err());
        }
    }
}

#[test]
fn padding_buckets() {
    assert_eq!(bucket(1), 256);
    assert_eq!(bucket(256), 256);
    assert_eq!(bucket(257), 1024);
    assert_eq!(bucket(5000), 16384);
    assert_eq!(bucket(65537), 131072);
}

#[test]
fn fragmentation_with_shuffled_frames() {
    let (mut a, b) = pair();
    let big = "x".repeat(20_000);
    let env = a.encrypt_for(&b.fingerprint_hex(), &msg(&big, T0)).unwrap();
    let frames = fragment(&env, 180);
    assert!(frames.len() > 100);
    let mut order: Vec<usize> = (0..frames.len()).collect();
    // Deterministic shuffle.
    let mut x: u64 = 12345;
    for i in (1..order.len()).rev() {
        x = x.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
        order.swap(i, (x >> 33) as usize % (i + 1));
    }
    let mut r = Reassembler::new();
    let mut done = None;
    for (k, i) in order.iter().enumerate() {
        let out = r.push(&frames[*i], T0);
        if k + 1 < order.len() {
            assert!(out.is_none());
        } else {
            done = out;
        }
    }
    assert_eq!(done.unwrap(), env);
    assert!(r.is_empty());

    // Timeout drops partial assemblies.
    let mut r = Reassembler::new();
    r.push(&frames[0], T0);
    assert_eq!(r.len(), 1);
    r.push(&frames[1], T0 + 31_000);
    assert_eq!(r.len(), 1, "old assembly dropped, new one started");
    // Malformed frames decode to None.
    assert!(Frame::decode(&[1, 2, 3]).is_none());
}

#[test]
fn mesh_router_dedup_and_hop_limit() {
    let (mut a, b) = pair();
    let env = a.encrypt_for(&b.fingerprint_hex(), &msg("hop", T0)).unwrap();
    let mut origin = MeshRouter::new();
    let frames = origin.frames_for(&env, 512);
    assert!(frames.len() > 1);
    // Our own frames echoed back are dropped.
    let echo = origin.on_frame(&frames[0], 3, T0);
    assert!(echo.forward.is_empty() && echo.complete.is_none());

    let mut relay = MeshRouter::new();
    let mut complete = None;
    for f in &frames {
        let r = relay.on_frame(f, 1, T0);
        assert_eq!(r.exclude_link, 1);
        assert_eq!(r.forward.len(), 1);
        assert_eq!(r.forward[0][1], 6, "hops_left decremented");
        if r.complete.is_some() {
            complete = r.complete;
        }
    }
    assert_eq!(complete.unwrap(), env);
    // Duplicates are neither forwarded nor delivered again.
    let dup = relay.on_frame(&frames[0], 2, T0);
    assert!(dup.forward.is_empty() && dup.complete.is_none());

    // Hop limit: a frame with hops_left 1 is delivered but not forwarded.
    let mut f = Frame::decode(&frames[0]).unwrap();
    f.id = [42; 16];
    f.count = 1;
    f.index = 0;
    f.hops_left = 1;
    let r = MeshRouter::new().on_frame(&f.encode(), 0, T0);
    assert!(r.forward.is_empty());
    assert!(r.complete.is_some());
    f.hops_left = 0;
    let r = MeshRouter::new().on_frame(&f.encode(), 0, T0);
    assert!(r.forward.is_empty());
}

#[test]
fn envelope_info_and_bad_json() {
    let (mut a, b) = pair();
    let env = a.encrypt_for(&b.fingerprint_hex(), &msg("x", T0)).unwrap();
    let info: Value = serde_json::from_str(&RelayEngine::envelope_info(&env).unwrap()).unwrap();
    assert_eq!(info["kind"], "direct");
    assert_eq!(info["tag"], b.mailbox_hex());
    assert_eq!(info["ttl"], 7);
    assert!(matches!(a.encrypt_for(&b.fingerprint_hex(), "not json"), Err(RelayError::Malformed(_))));
    assert!(matches!(a.encrypt_for(&"00".repeat(32), "{}"), Err(RelayError::Unknown(_))));
}

#[test]
fn directory_entry_signature_binds_handle_and_card() {
    use ed25519_dalek::{Signature, Verifier, VerifyingKey};

    let mut e = engine("ines", 1);
    let _ = e.my_card(Some("https://relay.example.org".into()), None);
    let (card_text, sig) = e.sign_directory_entry("ines").unwrap();
    let card = Card::parse(&card_text).unwrap();
    assert_eq!(card.body.handle.as_deref(), Some("ines"));
    assert_eq!(card.body.node_url.as_deref(), Some("https://relay.example.org"));

    let vk = VerifyingKey::from_bytes(&e.device_signing_public().try_into().unwrap()).unwrap();
    let sig = Signature::from_bytes(&sig.try_into().unwrap());
    let msg = crate::card::directory_message("ines", card_text.as_bytes());
    assert!(msg.starts_with(b"soma-relay/directory/v1\x04ines"));
    assert!(vk.verify(&msg, &sig).is_ok());
    // Bound to the handle: the same signature does not cover another one.
    assert!(vk.verify(&crate::card::directory_message("ines2", card_text.as_bytes()), &sig).is_err());

    assert!(matches!(e.sign_directory_entry("IN"), Err(RelayError::Malformed(_))));
}
