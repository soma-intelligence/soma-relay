//! End-to-end tests: a real node on a random port, real WebSocket and HTTP clients.

use std::net::SocketAddr;
use std::time::Duration;

use base64::Engine as _;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use ed25519_dalek::{Signer, SigningKey};
use futures_util::{SinkExt, StreamExt};
use relay_node::{Config, NodeState, serve};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use tokio::net::TcpStream;
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::{MaybeTlsStream, WebSocketStream, connect_async};

struct Node {
    addr: SocketAddr,
    state: std::sync::Arc<NodeState>,
    _dir: tempfile::TempDir,
    stop: Option<tokio::sync::oneshot::Sender<()>>,
}

impl Node {
    async fn start() -> Self {
        Self::start_with(|_| {}).await
    }

    async fn start_with(tune: impl FnOnce(&mut Config)) -> Self {
        Self::start_full(tune, std::sync::Arc::new(relay_node::verifier::PermissiveVerifier)).await
    }

    async fn start_full(tune: impl FnOnce(&mut Config), verifier: std::sync::Arc<dyn relay_node::verifier::CardVerifier>) -> Self {
        let dir = tempfile::tempdir().unwrap();
        let web = dir.path().join("web");
        std::fs::create_dir_all(&web).unwrap();
        std::fs::write(web.join("index.html"), "<!doctype html><title>relay</title>").unwrap();
        let mut config = Config::for_data_dir(dir.path().to_path_buf());
        tune(&mut config);
        let state = NodeState::with_verifier(config, verifier).unwrap();
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let (tx, rx) = tokio::sync::oneshot::channel::<()>();
        tokio::spawn(serve(listener, state.clone(), async move {
            let _ = rx.await;
        }));
        Node { addr, state, _dir: dir, stop: Some(tx) }
    }

    fn http(&self, path: &str) -> String {
        format!("http://{}{}", self.addr, path)
    }

    fn ws(&self) -> String {
        format!("ws://{}/v1/ws", self.addr)
    }
}

impl Drop for Node {
    fn drop(&mut self) {
        if let Some(tx) = self.stop.take() {
            let _ = tx.send(());
        }
    }
}

fn b64(b: &[u8]) -> String {
    URL_SAFE_NO_PAD.encode(b)
}

fn unb64(s: &str) -> Vec<u8> {
    URL_SAFE_NO_PAD.decode(s).unwrap()
}

/// A v1 envelope as relay-core's postcard encoding lays it out:
/// v, kind, tag[16], ttl, id[16], body (varint length + bytes).
fn envelope(tag: [u8; 16], id: [u8; 16], body: &[u8]) -> Vec<u8> {
    assert!(body.len() < 128);
    let mut e = vec![1u8, 1];
    e.extend(tag);
    e.push(7);
    e.extend(id);
    e.push(body.len() as u8);
    e.extend(body);
    e
}

struct Client {
    ws: WebSocketStream<MaybeTlsStream<TcpStream>>,
    key: SigningKey,
}

impl Client {
    fn identity(seed: u8) -> (SigningKey, [u8; 16]) {
        let key = SigningKey::from_bytes(&[seed; 32]);
        let mut mailbox = [0u8; 16];
        mailbox.copy_from_slice(&Sha256::digest([b"test-mailbox".as_slice(), &[seed]].concat())[..16]);
        (key, mailbox)
    }

    async fn connect_raw(node: &Node) -> WebSocketStream<MaybeTlsStream<TcpStream>> {
        connect_async(node.ws()).await.unwrap().0
    }

    /// Connects and authenticates. Returns the client and every frame received up to and
    /// including the queued envelopes flushed right after `ready`.
    async fn connect(node: &Node, key: SigningKey, mailbox: [u8; 16]) -> (Client, Vec<Value>) {
        let mut c = Client { ws: Self::connect_raw(node).await, key };
        c.send(json!({"t": "hello", "mailbox": hex::encode(mailbox), "pub": b64(c.key.verifying_key().as_bytes())}))
            .await;
        let ch = c.recv().await;
        assert_eq!(ch["t"], "challenge");
        let nonce = unb64(ch["nonce"].as_str().unwrap());
        assert_eq!(nonce.len(), 32);
        let mut msg = b"soma-relay/node-auth/v1".to_vec();
        msg.extend(&nonce);
        msg.extend(mailbox);
        let sig = c.key.sign(&msg);
        c.send(json!({"t": "auth", "sig": b64(&sig.to_bytes())})).await;
        let ready = c.recv().await;
        assert_eq!(ready["t"], "ready", "{ready}");
        assert_eq!(ready["mailbox"], hex::encode(mailbox));
        // Drain the flush: ping and collect everything until the pong.
        c.send(json!({"t": "ping"})).await;
        let mut frames = Vec::new();
        loop {
            let f = c.recv().await;
            if f["t"] == "pong" {
                break;
            }
            frames.push(f);
        }
        (c, frames)
    }

    async fn send(&mut self, v: Value) {
        self.ws.send(Message::Text(v.to_string().into())).await.unwrap();
    }

    async fn recv(&mut self) -> Value {
        loop {
            let m = tokio::time::timeout(Duration::from_secs(5), self.ws.next())
                .await
                .expect("timed out waiting for a frame")
                .expect("socket closed")
                .unwrap();
            match m {
                Message::Text(t) => return serde_json::from_str(t.as_str()).unwrap(),
                Message::Close(c) => panic!("closed: {c:?}"),
                _ => continue,
            }
        }
    }

    /// Asserts nothing but `pong` arrives after a ping.
    async fn expect_quiet(&mut self) {
        self.send(json!({"t": "ping"})).await;
        let f = self.recv().await;
        assert_eq!(f["t"], "pong", "unexpected frame {f}");
    }

    fn sign(&self, data: &[u8]) -> String {
        b64(&self.key.sign(data).to_bytes())
    }

    /// Directory signature: `"soma-relay/directory/v1" || u8 len || handle || card`.
    fn sign_dir(&self, handle: &str, card: &[u8]) -> String {
        let mut m = b"soma-relay/directory/v1".to_vec();
        m.push(handle.len() as u8);
        m.extend(handle.as_bytes());
        m.extend(card);
        self.sign(&m)
    }
}

#[tokio::test]
async fn online_delivery_and_ack() {
    let node = Node::start().await;
    let (ka, ma) = Client::identity(1);
    let (kb, mb) = Client::identity(2);
    let (mut a, _) = Client::connect(&node, ka, ma).await;
    let (mut b, _) = Client::connect(&node, kb, mb).await;

    let env = envelope(mb, [0x11; 16], b"ciphertext");
    a.send(json!({"t": "send", "to": hex::encode(mb), "env": b64(&env)})).await;
    let sent = a.recv().await;
    assert_eq!(sent["t"], "sent");
    assert_eq!(sent["id"], hex::encode([0x11; 16]));

    let got = b.recv().await;
    assert_eq!(got["t"], "env");
    assert_eq!(got["id"], hex::encode([0x11; 16]));
    assert_eq!(unb64(got["env"].as_str().unwrap()), env);

    b.send(json!({"t": "ack", "id": hex::encode([0x11; 16])})).await;
    b.expect_quiet().await;
    drop(b);

    // Acked: a reconnect gets nothing.
    let (kb, _) = Client::identity(2);
    let (mut b2, flushed) = Client::connect(&node, kb, mb).await;
    assert!(flushed.is_empty(), "{flushed:?}");
    b2.expect_quiet().await;
}

#[tokio::test]
async fn offline_store_and_forward() {
    let node = Node::start().await;
    let (ka, ma) = Client::identity(3);
    let (_, mb) = Client::identity(4);
    let (mut a, _) = Client::connect(&node, ka, ma).await;

    let e1 = envelope(mb, [1; 16], b"first");
    let e2 = envelope(mb, [2; 16], b"second");
    for e in [&e1, &e2] {
        a.send(json!({"t": "send", "to": hex::encode(mb), "env": b64(e)})).await;
        assert_eq!(a.recv().await["t"], "sent");
    }
    // Same envelope again is a duplicate, not a second copy.
    a.send(json!({"t": "send", "to": hex::encode(mb), "env": b64(&e1)})).await;
    let dup = a.recv().await;
    assert_eq!(dup["t"], "sent");
    assert_eq!(dup["dup"], true);

    // B comes online: both envelopes, in order.
    let (kb, _) = Client::identity(4);
    let (mut b, flushed) = Client::connect(&node, kb, mb).await;
    let ids: Vec<_> = flushed.iter().map(|f| f["id"].as_str().unwrap().to_string()).collect();
    assert_eq!(ids, vec![hex::encode([1; 16]), hex::encode([2; 16])]);
    assert_eq!(unb64(flushed[1]["env"].as_str().unwrap()), e2);

    // Ack only the first; the second is delivered again next time.
    b.send(json!({"t": "ack", "id": hex::encode([1; 16])})).await;
    b.expect_quiet().await;
    drop(b);
    let (kb, _) = Client::identity(4);
    let (_b, flushed) = Client::connect(&node, kb, mb).await;
    assert_eq!(flushed.len(), 1);
    assert_eq!(flushed[0]["id"], hex::encode([2; 16]));
}

#[tokio::test]
async fn presence() {
    let node = Node::start().await;
    let (ka, ma) = Client::identity(5);
    let (kb, mb) = Client::identity(6);
    let (_, mc) = Client::identity(7);
    let (mut a, _) = Client::connect(&node, ka, ma).await;
    let (b, _) = Client::connect(&node, kb, mb).await;

    a.send(json!({"t": "presence", "mailboxes": [hex::encode(mb), hex::encode(mc)]})).await;
    let p = a.recv().await;
    assert_eq!(p["t"], "presence");
    assert_eq!(p["online"], json!([hex::encode(mb)]));

    drop(b);
    tokio::time::sleep(Duration::from_millis(200)).await;
    a.send(json!({"t": "presence", "mailboxes": [hex::encode(mb)]})).await;
    assert_eq!(a.recv().await["online"], json!([]));
}

#[tokio::test]
async fn auth_rules() {
    let node = Node::start().await;

    // Unauthenticated send is refused.
    let mut raw = Client::connect_raw(&node).await;
    raw.send(Message::Text(json!({"t": "send", "to": hex::encode([0u8; 16]), "env": "AQ"}).to_string().into()))
        .await
        .unwrap();
    let Message::Text(t) = raw.next().await.unwrap().unwrap() else { panic!() };
    let v: Value = serde_json::from_str(t.as_str()).unwrap();
    assert_eq!(v["code"], "auth_required");

    // A wrong signature is refused and closes the socket.
    let (k, m) = Client::identity(8);
    let mut c = Client { ws: Client::connect_raw(&node).await, key: k.clone() };
    c.send(json!({"t": "hello", "mailbox": hex::encode(m), "pub": b64(k.verifying_key().as_bytes())})).await;
    let _ = c.recv().await;
    c.send(json!({"t": "auth", "sig": b64(&[0u8; 64])})).await;
    assert_eq!(c.recv().await["code"], "bad_signature");

    // Trust on first use: the mailbox stays bound to the first key.
    let (k8, m8) = Client::identity(8);
    let (first, _) = Client::connect(&node, k8, m8).await;
    drop(first);
    let (other, _) = Client::identity(9);
    let mut c = Client { ws: Client::connect_raw(&node).await, key: other.clone() };
    c.send(json!({"t": "hello", "mailbox": hex::encode(m8), "pub": b64(other.verifying_key().as_bytes())})).await;
    let ch = c.recv().await;
    let mut msg = b"soma-relay/node-auth/v1".to_vec();
    msg.extend(unb64(ch["nonce"].as_str().unwrap()));
    msg.extend(m8);
    let sig = c.sign(&msg);
    c.send(json!({"t": "auth", "sig": sig})).await;
    assert_eq!(c.recv().await["code"], "key_mismatch");
}

#[tokio::test]
async fn register_card_and_fetch() {
    let node = Node::start().await;
    let http = reqwest::Client::new();
    let (k, m) = Client::identity(10);
    let (mut c, _) = Client::connect(&node, k, m).await;

    let r = http.get(node.http(&format!("/v1/cards/{}", hex::encode(m)))).send().await.unwrap();
    assert_eq!(r.status(), 404);

    c.send(json!({"t": "register", "card": b64(b"relay1:card-ten")})).await;
    assert_eq!(c.recv().await["t"], "registered");
    let r = http.get(node.http(&format!("/v1/cards/{}", hex::encode(m)))).send().await.unwrap();
    assert_eq!(r.status(), 200);
    assert_eq!(r.text().await.unwrap(), "relay1:card-ten");
}

#[tokio::test]
async fn blob_round_trip() {
    let node = Node::start().await;
    let http = reqwest::Client::new();
    let data: Vec<u8> = (0..300_000u32).map(|i| (i % 251) as u8).collect();
    let sha = hex::encode(Sha256::digest(&data));

    let r = http.put(node.http(&format!("/v1/blobs/{sha}"))).body(data.clone()).send().await.unwrap();
    assert_eq!(r.status(), 201);
    let r = http.get(node.http(&format!("/v1/blobs/{sha}"))).send().await.unwrap();
    assert_eq!(r.status(), 200);
    assert_eq!(r.bytes().await.unwrap().to_vec(), data);

    // Body that does not hash to the path is refused and not stored.
    let wrong = hex::encode(Sha256::digest(b"something else"));
    let r = http.put(node.http(&format!("/v1/blobs/{wrong}"))).body(data.clone()).send().await.unwrap();
    assert_eq!(r.status(), 400);
    let r = http.get(node.http(&format!("/v1/blobs/{wrong}"))).send().await.unwrap();
    assert_eq!(r.status(), 404);

    let r = http.get(node.http("/v1/blobs/not-a-hash")).send().await.unwrap();
    assert_eq!(r.status(), 400);
}

#[tokio::test]
async fn directory_first_come() {
    let node = Node::start().await;
    let http = reqwest::Client::new();
    let (ka, ma) = Client::identity(11);
    let (kb, mb) = Client::identity(12);
    let (a, _) = Client::connect(&node, ka, ma).await;
    let (b, _) = Client::connect(&node, kb, mb).await;

    let put = |handle: &str, mailbox: [u8; 16], card: &'static [u8], sig: String| {
        http.put(node.http(&format!("/v1/directory/{handle}")))
            .header("X-Relay-Mailbox", hex::encode(mailbox))
            .header("X-Relay-Sig", sig)
            .body(card)
            .send()
    };

    // Bad handle.
    let r = put("IN", ma, b"relay1:a", a.sign_dir("IN", b"relay1:a")).await.unwrap();
    assert_eq!(r.status(), 400);
    // Signature by the wrong key.
    let r = put("ines", ma, b"relay1:a", b.sign_dir("ines", b"relay1:a")).await.unwrap();
    assert_eq!(r.status(), 403);
    // A signature for another handle does not carry over (the handle is signed).
    let r = put("ines", ma, b"relay1:a", a.sign_dir("ines2", b"relay1:a")).await.unwrap();
    assert_eq!(r.status(), 403);
    // A plain signature over the card bytes is not enough either.
    let r = put("ines", ma, b"relay1:a", a.sign(b"relay1:a")).await.unwrap();
    assert_eq!(r.status(), 403);
    // First come.
    let r = put("ines", ma, b"relay1:a", a.sign_dir("ines", b"relay1:a")).await.unwrap();
    assert_eq!(r.status(), 201);
    // Someone else: conflict.
    let r = put("ines", mb, b"relay1:b", b.sign_dir("ines", b"relay1:b")).await.unwrap();
    assert_eq!(r.status(), 409);
    // Owner may update.
    let r = put("ines", ma, b"relay1:a2", a.sign_dir("ines", b"relay1:a2")).await.unwrap();
    assert_eq!(r.status(), 200);

    let r = http.get(node.http("/v1/directory/ines")).send().await.unwrap();
    assert_eq!(r.status(), 200);
    assert_eq!(r.headers()["x-relay-mailbox"], hex::encode(ma));
    assert_eq!(r.text().await.unwrap(), "relay1:a2");
    let r = http.get(node.http("/v1/directory/nobody")).send().await.unwrap();
    assert_eq!(r.status(), 404);

    // A mailbox that never authenticated cannot claim.
    let (kz, mz) = Client::identity(13);
    let zed = Client { ws: Client::connect_raw(&node).await, key: kz };
    let r = put("zed", mz, b"relay1:z", zed.sign_dir("zed", b"relay1:z")).await.unwrap();
    assert_eq!(r.status(), 403);
}

#[tokio::test]
async fn misc_http() {
    let node = Node::start().await;
    let http = reqwest::Client::new();

    let h: Value = http.get(node.http("/healthz")).send().await.unwrap().json().await.unwrap();
    assert_eq!(h["ok"], true);

    let ice: Value = http.get(node.http("/v1/ice")).send().await.unwrap().json().await.unwrap();
    let urls = ice["iceServers"].to_string();
    assert!(urls.contains("stun.l.google.com") && urls.contains("stun.cloudflare.com"), "{urls}");

    let r = http.get(node.http("/v1/nope")).send().await.unwrap();
    assert_eq!(r.status(), 404);
    assert_eq!(r.json::<Value>().await.unwrap()["error"], "not_found");

    // SPA fallback.
    let r = http.get(node.http("/chat/some-id")).send().await.unwrap();
    assert_eq!(r.status(), 200);
    assert!(r.text().await.unwrap().contains("<title>relay</title>"));

    // CORS on the API.
    let r = http
        .get(node.http("/v1/ice"))
        .header("Origin", "https://example.org")
        .send()
        .await
        .unwrap();
    assert_eq!(r.headers()["access-control-allow-origin"], "*");
}

#[tokio::test]
async fn ice_turn_credentials() {
    // Unset: the STUN list only.
    let node = Node::start().await;
    let http = reqwest::Client::new();
    let r = http.get(node.http("/v1/ice")).send().await.unwrap();
    assert_eq!(r.headers()["cache-control"], "no-store");
    let ice: Value = r.json().await.unwrap();
    let list = ice["iceServers"].as_array().unwrap();
    assert_eq!(list.len(), 2);
    assert!(list.iter().all(|s| s.get("username").is_none()));

    // Set: the STUN list plus one TURN entry with fresh credentials.
    let node = Node::start_with(|c| {
        c.turn_secret = Some("north".into());
        c.turn_urls = Some("turn:t.example:3478?transport=udp,turns:t.example:5349?transport=tcp".into());
        c.turn_ttl = 3600;
    })
    .await;
    let fetch = || async {
        let r = http.get(node.http("/v1/ice")).send().await.unwrap();
        assert_eq!(r.headers()["cache-control"], "no-store");
        r.json::<Value>().await.unwrap()["iceServers"].as_array().unwrap().clone()
    };
    let list = fetch().await;
    assert_eq!(list.len(), 3);
    assert!(list[0]["urls"].to_string().contains("stun.l.google.com"));
    let turn = &list[2];
    assert_eq!(
        turn["urls"],
        json!(["turn:t.example:3478?transport=udp", "turns:t.example:5349?transport=tcp"])
    );
    let user = turn["username"].as_str().unwrap();
    let (exp, tag) = user.split_once(':').unwrap();
    let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs();
    let exp: u64 = exp.parse().unwrap();
    assert!(exp >= now + 3590 && exp <= now + 3610, "{exp} vs {now}");
    assert_eq!(tag.len(), 16);
    assert_eq!(turn["credential"], relay_node::turn::credential("north", user));
    assert_ne!(fetch().await[2]["username"], turn["username"], "credentials are per request");
}

#[tokio::test]
async fn malformed_frames() {
    let node = Node::start().await;
    let (ka, ma) = Client::identity(14);
    let (mut a, _) = Client::connect(&node, ka, ma).await;
    a.send(json!({"t": "send", "to": hex::encode([9u8; 16]), "env": b64(b"\x02nope")})).await;
    assert_eq!(a.recv().await["code"], "malformed");
    a.send(json!({"t": "bogus"})).await;
    assert_eq!(a.recv().await["code"], "bad_frame");
}

#[tokio::test]
async fn http_rate_limit() {
    let node = Node::start_with(|c| {
        c.rate_per_sec = 0.01;
        c.rate_burst = 3.0;
    })
    .await;
    let http = reqwest::Client::new();
    for _ in 0..3 {
        assert_eq!(http.get(node.http("/v1/ice")).send().await.unwrap().status(), 200);
    }
    let r = http.get(node.http("/v1/ice")).send().await.unwrap();
    assert_eq!(r.status(), 429);
    assert_eq!(r.headers()["retry-after"], "1");
}

#[tokio::test]
async fn core_verifier_accepts_real_cards_only() {
    use relay_core::RelayEngine;

    let node = Node::start_full(|_| {}, std::sync::Arc::new(relay_node::verifier::CoreCardVerifier)).await;
    let http = reqwest::Client::new();
    let mut eng = RelayEngine::create_with_seed("ada".into(), [42; 32]);
    let mailbox: [u8; 16] = hex::decode(eng.mailbox_hex()).unwrap().try_into().unwrap();

    // Authenticate with the engine's own key and signature.
    let mut c = Client { ws: Client::connect_raw(&node).await, key: SigningKey::from_bytes(&[0; 32]) };
    c.send(json!({"t": "hello", "mailbox": eng.mailbox_hex(), "pub": b64(&eng.device_signing_public())})).await;
    let ch = c.recv().await;
    let nonce = unb64(ch["nonce"].as_str().unwrap());
    c.send(json!({"t": "auth", "sig": b64(&eng.sign_node_challenge(&nonce))})).await;
    assert_eq!(c.recv().await["t"], "ready");

    // A fake card is refused.
    c.send(json!({"t": "register", "card": b64(b"relay1:not-a-card")})).await;
    assert_eq!(c.recv().await["code"], "card_rejected");
    // Someone else's real card is refused (wrong mailbox and key).
    let mut other = RelayEngine::create_with_seed("eve".into(), [7; 32]);
    let foreign = other.my_card(None, None);
    c.send(json!({"t": "register", "card": b64(foreign.as_bytes())})).await;
    assert_eq!(c.recv().await["code"], "card_rejected");
    // The real card is accepted and published.
    let card = eng.my_card(Some(format!("http://{}", node.addr)), None);
    c.send(json!({"t": "register", "card": b64(card.as_bytes())})).await;
    assert_eq!(c.recv().await["t"], "registered");
    let r = http.get(node.http(&format!("/v1/cards/{}", hex::encode(mailbox)))).send().await.unwrap();
    assert_eq!(r.text().await.unwrap(), card);

    // Directory entry signed by the engine itself.
    let (entry, sig) = eng.sign_directory_entry("ada").unwrap();
    let put = |handle: &str, body: String, sig: &[u8]| {
        http.put(node.http(&format!("/v1/directory/{handle}")))
            .header("X-Relay-Mailbox", hex::encode(mailbox))
            .header("X-Relay-Sig", b64(sig))
            .body(body)
            .send()
    };
    // Replaying it under another handle fails.
    assert_eq!(put("ada2", entry.clone(), &sig).await.unwrap().status(), 403);
    assert_eq!(put("ada", entry.clone(), &sig).await.unwrap().status(), 201);
    let r = http.get(node.http("/v1/directory/ada")).send().await.unwrap();
    assert_eq!(r.text().await.unwrap(), entry);
}

#[tokio::test]
async fn push_registration_frames() {
    let node = Node::start().await;
    let (ka, ma) = Client::identity(31);
    let mut raw = Client::connect_raw(&node).await;
    raw.send(Message::Text(json!({"t": "push", "kind": "none"}).to_string().into())).await.unwrap();
    let Message::Text(t) = raw.next().await.unwrap().unwrap() else { panic!() };
    assert_eq!(serde_json::from_str::<Value>(t.as_str()).unwrap()["code"], "auth_required");

    let (mut a, _) = Client::connect(&node, ka, ma).await;
    let token = "0123456789abcdef".repeat(4);
    a.send(json!({"t": "push", "kind": "apns", "token": token, "env": "sandbox"})).await;
    assert_eq!(a.recv().await, json!({"t": "push", "ok": false, "reason": "apns_off"}));

    a.send(json!({"t": "push", "kind": "webpush", "sub": {"endpoint": "https://push.example.org/x"}})).await;
    assert_eq!(a.recv().await, json!({"t": "push", "ok": false, "reason": "bad_request"}));
    a.send(json!({"t": "push", "kind": "pigeon"})).await;
    assert_eq!(a.recv().await, json!({"t": "push", "ok": false, "reason": "bad_request"}));

    let ua = p256::SecretKey::random(&mut p256::elliptic_curve::rand_core::OsRng);
    let p256dh = b64(p256::EncodedPoint::from(ua.public_key()).as_bytes());
    let sub = json!({"endpoint": "https://push.example.org/send/abc", "keys": {"p256dh": p256dh, "auth": b64(&[9; 16])}});
    a.send(json!({"t": "push", "kind": "webpush", "sub": sub})).await;
    assert_eq!(a.recv().await, json!({"t": "push", "ok": true}));
    let reg = node.state.store.get_push(&ma).unwrap().unwrap();
    assert_eq!(reg.kind, "webpush");

    a.send(json!({"t": "push", "kind": "none"})).await;
    assert_eq!(a.recv().await, json!({"t": "push", "ok": true}));
    assert!(node.state.store.get_push(&ma).unwrap().is_none());

    // The VAPID key is served and stable.
    let key: Value = reqwest::get(node.http("/v1/push/vapid")).await.unwrap().json().await.unwrap();
    let key = unb64(key["key"].as_str().unwrap());
    assert_eq!((key.len(), key[0]), (65, 4));
    assert_eq!(b64(&key), node.state.vapid_public_key());
}

/// A fake push service on 127.0.0.1 records what the node posts.
async fn fake_push_service(status: u16) -> (SocketAddr, tokio::sync::mpsc::UnboundedReceiver<(axum::http::HeaderMap, Vec<u8>)>) {
    use axum::routing::post;
    let (tx, rx) = tokio::sync::mpsc::unbounded_channel();
    let app = axum::Router::new().route(
        "/push/{id}",
        post(move |headers: axum::http::HeaderMap, body: axum::body::Bytes| {
            let tx = tx.clone();
            async move {
                let _ = tx.send((headers, body.to_vec()));
                axum::http::StatusCode::from_u16(status).unwrap()
            }
        }),
    );
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    (addr, rx)
}

#[tokio::test]
async fn web_push_wakes_offline_mailbox_once_per_30s() {
    let node = Node::start().await;
    node.state.allow_loopback_for_tests();
    let (svc, mut posts) = fake_push_service(201).await;
    let (ka, ma) = Client::identity(41);
    let (kb, mb) = Client::identity(42);

    // B registers a subscription, then goes offline.
    let ua = p256::SecretKey::random(&mut p256::elliptic_curve::rand_core::OsRng);
    let p256dh = b64(p256::EncodedPoint::from(ua.public_key()).as_bytes());
    let auth = [5u8; 16];
    let sub = json!({"endpoint": format!("http://{svc}/push/b"), "keys": {"p256dh": p256dh, "auth": b64(&auth)}});
    let (mut b, _) = Client::connect(&node, kb, mb).await;
    b.send(json!({"t": "push", "kind": "webpush", "sub": sub})).await;
    assert_eq!(b.recv().await, json!({"t": "push", "ok": true}));

    let (mut a, _) = Client::connect(&node, ka, ma).await;
    // B online: no push.
    a.send(json!({"t": "send", "to": hex::encode(mb), "env": b64(&envelope(mb, [0x51; 16], b"x"))})).await;
    assert_eq!(a.recv().await["t"], "sent");
    assert_eq!(b.recv().await["t"], "env");
    drop(b);
    tokio::time::sleep(Duration::from_millis(100)).await;

    // B offline: one push, then throttled.
    for id in [0x52u8, 0x53, 0x54] {
        a.send(json!({"t": "send", "to": hex::encode(mb), "env": b64(&envelope(mb, [id; 16], b"x"))})).await;
        assert_eq!(a.recv().await["t"], "sent");
    }
    let (headers, body) = tokio::time::timeout(Duration::from_secs(5), posts.recv()).await.unwrap().unwrap();
    assert_eq!(headers["content-encoding"], "aes128gcm");
    assert_eq!(headers["ttl"], "86400");
    assert_eq!(headers["urgency"], "high");
    let authz = headers["authorization"].to_str().unwrap();
    assert!(authz.starts_with("vapid t="), "{authz}");
    assert!(authz.ends_with(&format!(", k={}", node.state.vapid_public_key())));
    let plain = relay_node::push::webpush::decrypt(&body, &ua, &auth).expect("decrypts");
    assert_eq!(plain, br#"{"t":"wake"}"#);
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert!(posts.try_recv().is_err(), "at most one push per mailbox every 30 s");
}

#[tokio::test]
async fn web_push_gone_removes_subscription() {
    let node = Node::start().await;
    node.state.allow_loopback_for_tests();
    let (svc, mut posts) = fake_push_service(410).await;
    let (ka, ma) = Client::identity(43);
    let (kb, mb) = Client::identity(44);
    let ua = p256::SecretKey::random(&mut p256::elliptic_curve::rand_core::OsRng);
    let p256dh = b64(p256::EncodedPoint::from(ua.public_key()).as_bytes());
    let sub = json!({"endpoint": format!("http://{svc}/push/b"), "keys": {"p256dh": p256dh, "auth": b64(&[1; 16])}});
    let (mut b, _) = Client::connect(&node, kb, mb).await;
    b.send(json!({"t": "push", "kind": "webpush", "sub": sub})).await;
    assert_eq!(b.recv().await, json!({"t": "push", "ok": true}));
    drop(b);
    tokio::time::sleep(Duration::from_millis(100)).await;

    let (mut a, _) = Client::connect(&node, ka, ma).await;
    a.send(json!({"t": "send", "to": hex::encode(mb), "env": b64(&envelope(mb, [0x61; 16], b"x"))})).await;
    assert_eq!(a.recv().await["t"], "sent");
    tokio::time::timeout(Duration::from_secs(5), posts.recv()).await.unwrap().unwrap();
    for _ in 0..50 {
        if node.state.store.get_push(&mb).unwrap().is_none() {
            return;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    panic!("410 must remove the subscription");
}

fn test_png(w: u32, h: u32) -> Vec<u8> {
    let img = image::RgbImage::from_fn(w, h, |x, y| image::Rgb([(x % 256) as u8, (y % 256) as u8, 128]));
    let mut out = Vec::new();
    image::DynamicImage::ImageRgb8(img)
        .write_to(&mut std::io::Cursor::new(&mut out), image::ImageFormat::Png)
        .unwrap();
    out
}

#[tokio::test]
async fn link_preview() {
    use axum::response::{Html, IntoResponse, Redirect};
    use axum::routing::get;
    let png = test_png(1200, 800);
    let site = axum::Router::new()
        .route("/start", get(|| async { Redirect::temporary("/page") }))
        .route(
            "/page",
            get(|| async {
                Html(
                    r#"<html><head><title>Fallback</title>
                    <meta property="og:title" content="Une page">
                    <meta property="og:description" content="Avec une description">
                    <meta property="og:site_name" content="Exemple">
                    <meta property="og:image" content="/card.png"></head></html>"#,
                )
            }),
        )
        .route("/card.png", get(move || async move { ([("content-type", "image/png")], png).into_response() }))
        .route("/evil", get(|| async { Redirect::temporary("http://169.254.169.254/latest/meta-data/") }))
        .route("/json", get(|| async { axum::Json(json!({"a": 1})) }));
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let svc = listener.local_addr().unwrap();
    tokio::spawn(async move { axum::serve(listener, site).await.unwrap() });

    let node = Node::start().await;
    let http = reqwest::Client::new();
    let ask = |target: String| {
        let http = http.clone();
        let url = node.http("/v1/preview");
        async move { http.get(url).query(&[("url", target)]).send().await.unwrap() }
    };

    // Without the test switch, loopback is refused.
    let r = ask(format!("http://{svc}/start")).await;
    assert_eq!(r.status(), 400, "port is not 80/443");
    let r = ask("http://127.0.0.1/start".into()).await;
    assert_eq!(r.status(), 403);
    let r = ask("http://localhost/".into()).await;
    assert_eq!(r.status(), 403);
    let r = ask("file:///etc/passwd".into()).await;
    assert_eq!(r.status(), 400);
    assert_eq!(http.get(node.http("/v1/preview")).send().await.unwrap().status(), 400);

    node.state.allow_loopback_for_tests();
    let r = ask(format!("http://{svc}/start")).await;
    assert_eq!(r.status(), 200);
    assert_eq!(r.headers()["access-control-allow-origin"], "*");
    let p: Value = r.json().await.unwrap();
    assert_eq!(p["url"], format!("http://{svc}/start"));
    assert_eq!(p["title"], "Une page");
    assert_eq!(p["description"], "Avec une description");
    assert_eq!(p["site"], "Exemple");
    let img = p["image"].as_str().unwrap();
    let data = img.strip_prefix("data:image/jpeg;base64,").expect("JPEG data URL");
    let bytes = base64::engine::general_purpose::STANDARD.decode(data).unwrap();
    assert!(bytes.len() <= 40 * 1024);
    let decoded = image::load_from_memory(&bytes).unwrap();
    assert_eq!((decoded.width(), decoded.height()), (600, 400));

    // Redirect to the metadata address is refused even in test mode.
    assert_eq!(ask(format!("http://{svc}/evil")).await.status(), 403);
    assert_eq!(ask(format!("http://{svc}/json")).await.status(), 502);
}

/// Vault signature: `"relay-vault-v1" || vault_id (ASCII hex) || SHA-256(blob)`.
fn vault_sig(c: &Client, id: &str, blob: &[u8]) -> String {
    let mut m = b"relay-vault-v1".to_vec();
    m.extend(id.as_bytes());
    m.extend(Sha256::digest(blob));
    c.sign(&m)
}

fn vault_id(n: u8) -> String {
    hex::encode(Sha256::digest([n]))
}

#[tokio::test]
async fn vault_roundtrip() {
    let node = Node::start().await;
    let http = reqwest::Client::new();
    let (ka, ma) = Client::identity(21);
    let (a, _) = Client::connect(&node, ka, ma).await;
    let id = vault_id(1);
    let blob = b"opaque vault bytes".to_vec();
    let r = http
        .put(node.http(&format!("/v1/vault/{id}")))
        .header("X-Relay-Mailbox", hex::encode(ma))
        .header("X-Relay-Sig", vault_sig(&a, &id, &blob))
        .body(blob.clone())
        .send()
        .await
        .unwrap();
    assert_eq!(r.status(), 200, "{}", r.text().await.unwrap());
    let r = http.get(node.http(&format!("/v1/vault/{id}"))).send().await.unwrap();
    assert_eq!(r.status(), 200);
    assert_eq!(r.bytes().await.unwrap().to_vec(), blob);
}

#[tokio::test]
async fn vault_bad_signature() {
    let node = Node::start().await;
    let http = reqwest::Client::new();
    let (ka, ma) = Client::identity(22);
    let (kb, _mb) = Client::identity(23);
    let (a, _) = Client::connect(&node, ka, ma).await;
    let id = vault_id(2);
    let put = |sig: String, body: &'static [u8]| {
        http.put(node.http(&format!("/v1/vault/{id}")))
            .header("X-Relay-Mailbox", hex::encode(ma))
            .header("X-Relay-Sig", sig)
            .body(body)
            .send()
    };
    // Signed by another key.
    let other = Client { ws: Client::connect_raw(&node).await, key: kb };
    let r = put(vault_sig(&other, &id, b"x"), b"x").await.unwrap();
    assert_eq!(r.status(), 403);
    assert_eq!(r.json::<Value>().await.unwrap()["error"], "bad_signature");
    // Signature over a different blob.
    let r = put(vault_sig(&a, &id, b"y"), b"x").await.unwrap();
    assert_eq!(r.status(), 403);
    // Signature for another vault id does not carry over.
    let r = put(vault_sig(&a, &vault_id(99), b"x"), b"x").await.unwrap();
    assert_eq!(r.status(), 403);
}

#[tokio::test]
async fn vault_unknown_mailbox() {
    let node = Node::start().await;
    let http = reqwest::Client::new();
    let (kz, mz) = Client::identity(24);
    let zed = Client { ws: Client::connect_raw(&node).await, key: kz };
    let id = vault_id(3);
    let r = http
        .put(node.http(&format!("/v1/vault/{id}")))
        .header("X-Relay-Mailbox", hex::encode(mz))
        .header("X-Relay-Sig", vault_sig(&zed, &id, b"x"))
        .body("x")
        .send()
        .await
        .unwrap();
    assert_eq!(r.status(), 403);
    assert_eq!(r.json::<Value>().await.unwrap()["error"], "unknown_mailbox");
}

#[tokio::test]
async fn vault_other_owner() {
    let node = Node::start().await;
    let http = reqwest::Client::new();
    let (ka, ma) = Client::identity(25);
    let (kb, mb) = Client::identity(26);
    let (a, _) = Client::connect(&node, ka, ma).await;
    let (b, _) = Client::connect(&node, kb, mb).await;
    let id = vault_id(4);
    let put = |c: &Client, mailbox: [u8; 16], body: &'static [u8]| {
        http.put(node.http(&format!("/v1/vault/{id}")))
            .header("X-Relay-Mailbox", hex::encode(mailbox))
            .header("X-Relay-Sig", vault_sig(c, &id, body))
            .body(body)
            .send()
    };
    assert_eq!(put(&a, ma, b"one").await.unwrap().status(), 200);
    let r = put(&b, mb, b"two").await.unwrap();
    assert_eq!(r.status(), 403);
    assert_eq!(r.json::<Value>().await.unwrap()["error"], "not_owner");
    assert_eq!(put(&a, ma, b"three").await.unwrap().status(), 200);
    let r = http.get(node.http(&format!("/v1/vault/{id}"))).send().await.unwrap();
    assert_eq!(r.bytes().await.unwrap().as_ref(), b"three");
}

#[tokio::test]
async fn vault_too_large() {
    let node = Node::start().await;
    let http = reqwest::Client::new();
    let (ka, ma) = Client::identity(27);
    let (a, _) = Client::connect(&node, ka, ma).await;
    let id = vault_id(5);
    let big = vec![7u8; (1 << 20) + 1];
    let r = http
        .put(node.http(&format!("/v1/vault/{id}")))
        .header("X-Relay-Mailbox", hex::encode(ma))
        .header("X-Relay-Sig", vault_sig(&a, &id, &big))
        .body(big)
        .send()
        .await
        .unwrap();
    assert_eq!(r.status(), 413);
    // Exactly 1 MiB is fine.
    let ok = vec![7u8; 1 << 20];
    let r = http
        .put(node.http(&format!("/v1/vault/{id}")))
        .header("X-Relay-Mailbox", hex::encode(ma))
        .header("X-Relay-Sig", vault_sig(&a, &id, &ok))
        .body(ok)
        .send()
        .await
        .unwrap();
    assert_eq!(r.status(), 200);
}

#[tokio::test]
async fn vault_missing() {
    let node = Node::start().await;
    let http = reqwest::Client::new();
    let r = http.get(node.http(&format!("/v1/vault/{}", vault_id(6)))).send().await.unwrap();
    assert_eq!(r.status(), 404);
}

#[tokio::test]
async fn vault_bad_id() {
    let node = Node::start().await;
    let http = reqwest::Client::new();
    let r = http.get(node.http("/v1/vault/xyz")).send().await.unwrap();
    assert_eq!(r.status(), 400);
    assert_eq!(r.json::<Value>().await.unwrap()["error"], "bad_vault_id");
}
