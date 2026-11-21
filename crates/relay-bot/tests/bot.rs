//! Bots talking through a real relay-node. `PlainEngine` is a test double that does NOT
//! encrypt: it exercises the REST API, the node client, card lookup and the webhook. The
//! last test runs the real relay-core engine end to end.

use std::net::SocketAddr;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use base64::Engine as _;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use ed25519_dalek::{Signer, SigningKey};
use relay_bot::engine::{CompactLink, Contact, Engine, EngineError};
use relay_bot::inbox::Inbox;
use relay_bot::resolve::mailbox_of;
use relay_bot::{Bot, Settings, api, node};
use serde_json::{Value, json};
use sha3::Digest;

struct PlainEngine {
    name: String,
    key: SigningKey,
    contacts: Mutex<Vec<Contact>>,
}

impl PlainEngine {
    fn new(name: &str, seed: u8) -> Self {
        Self { name: name.into(), key: SigningKey::from_bytes(&[seed; 32]), contacts: Mutex::new(Vec::new()) }
    }
    fn card_json(&self, node_url: Option<String>) -> Value {
        json!({"name": self.name, "fp": self.fingerprint_hex(), "node": node_url})
    }
}

impl Engine for PlainEngine {
    fn display_name(&self) -> String {
        self.name.clone()
    }
    fn fingerprint_hex(&self) -> String {
        hex::encode(sha3::Sha3_256::digest(self.key.verifying_key().as_bytes()))
    }
    fn mailbox_hex(&self) -> String {
        mailbox_of(&self.fingerprint_hex()).unwrap()
    }
    fn safety_words(&self) -> Vec<String> {
        vec!["un".into(), "deux".into(), "trois".into(), "quatre".into()]
    }
    fn my_card(&self, node_url: Option<String>, _handle: Option<String>) -> String {
        format!("relay1:{}", URL_SAFE_NO_PAD.encode(self.card_json(node_url).to_string()))
    }
    fn sign_directory_card(&self, card: &str) -> Result<Vec<u8>, EngineError> {
        Ok(self.key.sign(card.as_bytes()).to_bytes().to_vec())
    }
    fn my_compact_link(&self, node_url: Option<String>) -> String {
        let j = json!({"fingerprint": self.fingerprint_hex(), "node_url": node_url});
        format!("relay1c:{}", URL_SAFE_NO_PAD.encode(j.to_string()))
    }
    fn device_signing_public(&self) -> Vec<u8> {
        self.key.verifying_key().as_bytes().to_vec()
    }
    fn sign_node_challenge(&self, nonce: &[u8]) -> Vec<u8> {
        let mut m = b"soma-relay/node-auth/v1".to_vec();
        m.extend(nonce);
        m.extend(hex::decode(self.mailbox_hex()).unwrap());
        self.key.sign(&m).to_bytes().to_vec()
    }
    fn rotate_prekey_if_due(&self, _now_ms: i64) -> bool {
        false
    }
    fn add_contact(&self, card: &str) -> Result<Contact, EngineError> {
        let raw = card.strip_prefix("relay1:").ok_or(EngineError("not a card".into()))?;
        let j: Value = serde_json::from_slice(&URL_SAFE_NO_PAD.decode(raw).map_err(|e| EngineError(e.to_string()))?)
            .map_err(|e| EngineError(e.to_string()))?;
        let fp = j["fp"].as_str().unwrap().to_string();
        let c = Contact {
            mailbox: mailbox_of(&fp).unwrap(),
            fingerprint: fp,
            name: j["name"].as_str().unwrap().to_string(),
            verified: false,
            node_url: j["node"].as_str().map(str::to_string),
            handle: None,
        };
        let mut cs = self.contacts.lock().unwrap();
        if !cs.iter().any(|x| x.fingerprint == c.fingerprint) {
            cs.push(c.clone());
        }
        Ok(c)
    }
    fn parse_compact_link(&self, link: &str) -> Result<CompactLink, EngineError> {
        let raw = link.strip_prefix("relay1c:").ok_or(EngineError("not a link".into()))?;
        serde_json::from_slice(&URL_SAFE_NO_PAD.decode(raw).unwrap()).map_err(|e| EngineError(e.to_string()))
    }
    fn contacts(&self) -> Vec<Contact> {
        self.contacts.lock().unwrap().clone()
    }
    fn encrypt_for(&self, fingerprint: &str, app_message_json: &str) -> Result<Vec<u8>, EngineError> {
        let to = self.contacts().into_iter().find(|c| c.fingerprint == fingerprint).ok_or(EngineError("NoSession".into()))?;
        let mut env = vec![1u8, 1];
        env.extend(hex::decode(&to.mailbox).unwrap());
        env.push(7);
        env.extend(rand_id());
        let body = json!({"card": self.my_card(None, None), "msg": serde_json::from_str::<Value>(app_message_json).unwrap()});
        env.extend(body.to_string().as_bytes());
        Ok(env)
    }
    fn open(&self, envelope: &[u8], _now_ms: i64) -> Result<Option<Value>, EngineError> {
        if hex::encode(&envelope[2..18]) != self.mailbox_hex() {
            return Ok(None);
        }
        let body: Value = serde_json::from_slice(&envelope[35..]).map_err(|e| EngineError(e.to_string()))?;
        let from = self.add_contact(body["card"].as_str().unwrap())?;
        Ok(Some(json!({"from": from.fingerprint, "message": body["msg"], "envelope_id": hex::encode(&envelope[19..35])})))
    }
    fn export_state(&self) -> Vec<u8> {
        b"plain-test-engine".to_vec()
    }
}

fn rand_id() -> [u8; 16] {
    let mut id = [0u8; 16];
    rand::RngCore::fill_bytes(&mut rand::rngs::OsRng, &mut id);
    id
}

async fn start_node(dir: &std::path::Path) -> SocketAddr {
    let state = relay_node::NodeState::open(relay_node::Config::for_data_dir(dir.to_path_buf())).unwrap();
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(relay_node::serve(listener, state, std::future::pending()));
    addr
}

struct TestBot {
    bot: Arc<Bot>,
    api: String,
    token: String,
}

async fn start_bot(node: SocketAddr, dir: &std::path::Path, name: &str, seed: u8, webhook: Option<String>) -> TestBot {
    start_bot_with(node, dir, name, Arc::new(PlainEngine::new(name, seed)), webhook, None).await
}

async fn start_bot_with(
    node: SocketAddr,
    dir: &std::path::Path,
    name: &str,
    engine: Arc<dyn Engine>,
    webhook: Option<String>,
    handle: Option<String>,
) -> TestBot {
    let token = format!("token-{name}-0123456789abcdef0123456789abcdef");
    let settings = Settings {
        node_url: format!("http://{node}").parse().unwrap(),
        state_path: dir.join(format!("{name}.bin")),
        webhook: webhook.map(|w| w.parse().unwrap()),
        token: token.clone(),
        handle,
    };
    let (bot, outbox) = Bot::new(engine, settings, Inbox::memory());
    tokio::spawn(node::run(bot.clone(), outbox));
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let api = format!("http://{}", listener.local_addr().unwrap());
    tokio::spawn(axum::serve(listener, api::router(bot.clone())).into_future());
    for _ in 0..100 {
        if bot.is_connected() {
            break;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    assert!(bot.is_connected(), "{name} did not connect");
    TestBot { bot, api, token }
}

async fn wait_messages(http: &reqwest::Client, b: &TestBot, since: u64, n: usize) -> Vec<Value> {
    for _ in 0..100 {
        let v: Value = http
            .get(format!("{}/v1/messages?since={since}", b.api))
            .bearer_auth(&b.token)
            .send()
            .await
            .unwrap()
            .json()
            .await
            .unwrap();
        let msgs = v["messages"].as_array().unwrap().clone();
        if msgs.len() >= n {
            return msgs;
        }
        tokio::time::sleep(Duration::from_millis(30)).await;
    }
    panic!("messages did not arrive");
}

#[tokio::test]
async fn bots_exchange_messages_through_a_node() {
    let dir = tempfile::tempdir().unwrap();
    let node = start_node(dir.path()).await;

    // Webhook receiver for bot B.
    let hits: Arc<Mutex<Vec<Value>>> = Arc::default();
    let hook = {
        let hits = hits.clone();
        let app = axum::Router::new().route(
            "/hook",
            axum::routing::post(move |axum::Json(v): axum::Json<Value>| {
                let hits = hits.clone();
                async move {
                    hits.lock().unwrap().push(v);
                    "ok"
                }
            }),
        );
        let l = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}/hook", l.local_addr().unwrap());
        tokio::spawn(axum::serve(l, app).into_future());
        url
    };

    let a = start_bot(node, dir.path(), "alpha", 1, None).await;
    let b = start_bot(node, dir.path(), "bravo", 2, Some(hook)).await;
    let http = reqwest::Client::new();

    // Public card and QR.
    let card: Value = http.get(format!("{}/v1/card", b.api)).send().await.unwrap().json().await.unwrap();
    assert_eq!(card["name"], "bravo");
    assert_eq!(card["mailbox"], b.bot.engine.mailbox_hex());
    assert!(card["link"].as_str().unwrap().starts_with("relay1c:"));
    let png = http.get(format!("{}/v1/card.png", b.api)).send().await.unwrap();
    assert_eq!(png.headers()["content-type"], "image/png");
    assert_eq!(&png.bytes().await.unwrap()[..4], b"\x89PNG");

    // Token required.
    let r = http.post(format!("{}/v1/messages", a.api)).json(&json!({"to": "x", "text": "hi"})).send().await.unwrap();
    assert_eq!(r.status(), 401);

    // A -> B with B's full card.
    let r = http
        .post(format!("{}/v1/messages", a.api))
        .bearer_auth(&a.token)
        .json(&json!({"to": card["card"], "text": "hello bravo"}))
        .send()
        .await
        .unwrap();
    assert_eq!(r.status(), 201, "{}", r.text().await.unwrap());
    let msgs = wait_messages(&http, &b, 0, 1).await;
    assert_eq!(msgs[0]["message"]["text"], "hello bravo");
    assert_eq!(msgs[0]["message"]["kind"], "text");
    assert_eq!(msgs[0]["from"], a.bot.engine.fingerprint_hex());
    assert_eq!(msgs[0]["from_name"], "alpha");

    // B -> A by fingerprint (A became a contact when its message was opened).
    let r = http
        .post(format!("{}/v1/messages", b.api))
        .bearer_auth(&b.token)
        .json(&json!({"to": a.bot.engine.fingerprint_hex(), "text": "hi alpha", "reply_to": msgs[0]["message"]["id"]}))
        .send()
        .await
        .unwrap();
    assert_eq!(r.status(), 201);
    let back = wait_messages(&http, &a, 0, 1).await;
    assert_eq!(back[0]["message"]["text"], "hi alpha");
    assert_eq!(back[0]["message"]["reply_to"], msgs[0]["message"]["id"]);

    // C knows only B's mailbox: the card is fetched from the node.
    let c = start_bot(node, dir.path(), "charlie", 3, None).await;
    let r = http
        .post(format!("{}/v1/messages", c.api))
        .bearer_auth(&c.token)
        .json(&json!({"to": b.bot.engine.mailbox_hex(), "text": "from charlie"}))
        .send()
        .await
        .unwrap();
    assert_eq!(r.status(), 201, "{}", r.text().await.unwrap());
    let seq = msgs[0]["seq"].as_u64().unwrap();
    let more = wait_messages(&http, &b, seq, 1).await;
    assert_eq!(more[0]["message"]["text"], "from charlie");

    // Webhook saw both of B's messages.
    for _ in 0..50 {
        if hits.lock().unwrap().len() >= 2 {
            break;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    let hits = hits.lock().unwrap().clone();
    assert_eq!(hits.len(), 2);
    assert_eq!(hits[1]["message"]["text"], "from charlie");

    // Unknown fingerprint is a client error.
    let r = http
        .post(format!("{}/v1/messages", c.api))
        .bearer_auth(&c.token)
        .json(&json!({"to": "ab".repeat(32), "text": "?"}))
        .send()
        .await
        .unwrap();
    assert_eq!(r.status(), 422);
}

#[tokio::test]
async fn offline_bot_gets_messages_on_connect() {
    let dir = tempfile::tempdir().unwrap();
    let node = start_node(dir.path()).await;
    let a = start_bot(node, dir.path(), "alpha", 11, None).await;
    let http = reqwest::Client::new();

    // Bravo's card, without Bravo being online (its mailbox is unbound at the node).
    let bravo = PlainEngine::new("bravo", 12);
    let card = bravo.my_card(Some(format!("http://{node}")), None);
    let r = http
        .post(format!("{}/v1/messages", a.api))
        .bearer_auth(&a.token)
        .json(&json!({"to": card, "text": "while you were away"}))
        .send()
        .await
        .unwrap();
    assert_eq!(r.status(), 201);

    let b = start_bot(node, dir.path(), "bravo", 12, None).await;
    let msgs = wait_messages(&http, &b, 0, 1).await;
    assert_eq!(msgs[0]["message"]["text"], "while you were away");
}

#[tokio::test]
async fn core_engines_exchange_encrypted_messages() {
    use relay_bot::engine::CoreEngine;

    let dir = tempfile::tempdir().unwrap();
    let node = start_node(dir.path()).await;
    let a = start_bot_with(node, dir.path(), "ada", Arc::new(CoreEngine::create("ada")), None, None).await;
    let b = start_bot_with(node, dir.path(), "bob", Arc::new(CoreEngine::create("bob")), None, None).await;
    let http = reqwest::Client::new();

    // Ada only knows Bob's compact link: the full card comes from the node and is verified.
    let card: Value = http.get(format!("{}/v1/card", b.api)).send().await.unwrap().json().await.unwrap();
    let link = card["link"].as_str().unwrap();
    assert!(link.starts_with("relay1c:"));
    let r = http
        .post(format!("{}/v1/messages", a.api))
        .bearer_auth(&a.token)
        .json(&json!({"to": link, "text": "post-quantum hello"}))
        .send()
        .await
        .unwrap();
    assert_eq!(r.status(), 201, "{}", r.text().await.unwrap());
    let msgs = wait_messages(&http, &b, 0, 1).await;
    assert_eq!(msgs[0]["message"]["text"], "post-quantum hello");
    assert_eq!(msgs[0]["from"], a.bot.engine.fingerprint_hex());

    // Bob answers by fingerprint over the session Ada opened.
    let r = http
        .post(format!("{}/v1/messages", b.api))
        .bearer_auth(&b.token)
        .json(&json!({"to": a.bot.engine.fingerprint_hex(), "text": "loud and clear"}))
        .send()
        .await
        .unwrap();
    assert_eq!(r.status(), 201, "{}", r.text().await.unwrap());
    let back = wait_messages(&http, &a, 0, 1).await;
    assert_eq!(back[0]["message"]["text"], "loud and clear");

    // State survives a restore.
    let restored = CoreEngine::restore(&a.bot.engine.export_state()).unwrap();
    assert_eq!(restored.fingerprint_hex(), a.bot.engine.fingerprint_hex());
    assert_eq!(restored.contacts().len(), 1);
}

#[tokio::test]
async fn handle_claimed_on_startup_and_used_to_send() {
    let dir = tempfile::tempdir().unwrap();
    let node = start_node(dir.path()).await;
    let w = start_bot_with(node, dir.path(), "weather", Arc::new(PlainEngine::new("weather", 21)), None, Some("weather".into())).await;
    let http = reqwest::Client::new();

    let mut found = false;
    for _ in 0..100 {
        let r = http.get(format!("http://{node}/v1/directory/weather")).send().await.unwrap();
        if r.status() == 200 {
            assert_eq!(r.headers()["x-relay-mailbox"], w.bot.engine.mailbox_hex());
            found = true;
            break;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    assert!(found, "handle was not published");

    // Another bot reaches it by handle@node.
    let u = start_bot(node, dir.path(), "user", 22, None).await;
    let r = http
        .post(format!("{}/v1/messages", u.api))
        .bearer_auth(&u.token)
        .json(&json!({"to": format!("weather@http://{node}"), "text": "forecast?"}))
        .send()
        .await
        .unwrap();
    assert_eq!(r.status(), 201, "{}", r.text().await.unwrap());
    let msgs = wait_messages(&http, &w, 0, 1).await;
    assert_eq!(msgs[0]["message"]["text"], "forecast?");
}
