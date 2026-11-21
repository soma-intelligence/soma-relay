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
        tokio::spawn(serve(listener, state, async move {
            let _ = rx.await;
        }));
        Node { addr, _dir: dir, stop: Some(tx) }
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
