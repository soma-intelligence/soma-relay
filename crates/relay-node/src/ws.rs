//! WebSocket mailbox protocol (`/v1/ws`): hello, challenge, auth, register, send, ack,
//! presence, ping. See `docs/node-protocol.md`.

use std::sync::Arc;
use std::time::Duration;

use axum::extract::ws::{CloseFrame, Message, WebSocket, WebSocketUpgrade};
use axum::extract::State;
use axum::response::Response;
use ed25519_dalek::{Signature, Verifier, VerifyingKey};
use futures_util::{SinkExt, StreamExt};
use rand::RngCore;
use serde::Deserialize;
use serde_json::json;
use tokio::sync::mpsc;
use tokio::time::Instant;

use crate::ratelimit::Bucket;
use crate::store::Enqueue;
use crate::util::{auth_message, b64, envelope_id, now_ms, parse_hex16, unb64};
use crate::{MAILBOX_QUOTA, MAX_ENVELOPE_BYTES, MAX_WS_FRAME, NodeState, RETENTION_MS};

/// Time a connection has to complete hello and auth.
const AUTH_TIMEOUT: Duration = Duration::from_secs(30);
/// WebSocket ping interval.
const PING_EVERY: Duration = Duration::from_secs(30);
/// Live push queue per connection; a connection that falls this far behind is dropped
/// (its envelopes stay queued and are delivered again on reconnect).
const PUSH_QUEUE: usize = 1024;
/// Most mailboxes one presence query may ask about.
const MAX_PRESENCE: usize = 512;
/// Frames per second per connection, and burst.
const FRAME_RATE: f64 = 50.0;
const FRAME_BURST: f64 = 200.0;

#[derive(Deserialize)]
#[serde(tag = "t", rename_all = "lowercase")]
enum In {
    Hello {
        mailbox: String,
        #[serde(rename = "pub")]
        pubkey: String,
    },
    Auth {
        sig: String,
    },
    Register {
        card: String,
    },
    Send {
        to: String,
        env: String,
    },
    Ack {
        id: String,
    },
    Presence {
        mailboxes: Vec<String>,
    },
    Ping,
}

enum Phase {
    Fresh,
    Challenged { mailbox: [u8; 16], pubkey: [u8; 32], nonce: [u8; 32] },
    Authed { mailbox: [u8; 16], pubkey: [u8; 32], conn: u64 },
}

/// What the frame handler wants the connection loop to do next.
enum Next {
    Continue,
    Close(&'static str),
}

pub async fn upgrade(State(state): State<Arc<NodeState>>, ws: WebSocketUpgrade) -> Response {
    ws.max_message_size(MAX_WS_FRAME)
        .max_frame_size(MAX_WS_FRAME)
        .on_upgrade(move |socket| run(socket, state))
}

fn err(code: &str, msg: &str) -> String {
    json!({"t": "error", "code": code, "msg": msg}).to_string()
}

fn err_id(code: &str, msg: &str, id: &str) -> String {
    json!({"t": "error", "code": code, "msg": msg, "id": id}).to_string()
}

async fn recv_opt(rx: &mut Option<mpsc::Receiver<String>>) -> Option<String> {
    match rx {
        Some(rx) => rx.recv().await,
        None => std::future::pending().await,
    }
}

async fn run(socket: WebSocket, state: Arc<NodeState>) {
    let (mut sink, mut stream) = socket.split();
    let mut phase = Phase::Fresh;
    let mut rx: Option<mpsc::Receiver<String>> = None;
    let mut bucket = Bucket::new(FRAME_BURST);
    let mut shutdown = state.shutdown.clone();
    let auth_deadline = Instant::now() + AUTH_TIMEOUT;
    let mut ping = tokio::time::interval(PING_EVERY);
    ping.tick().await;

    let close_reason: &'static str = loop {
        let authed = matches!(phase, Phase::Authed { .. });
        tokio::select! {
            incoming = stream.next() => {
                let Some(Ok(msg)) = incoming else { break "" };
                let text = match msg {
                    Message::Text(t) => t,
                    Message::Close(_) => break "",
                    Message::Binary(_) => {
                        if sink.send(Message::Text(err("bad_frame", "binary frames are not used").into())).await.is_err() { break "" }
                        continue;
                    }
                    _ => continue,
                };
                if !bucket.take(1.0, FRAME_RATE, FRAME_BURST) {
                    if sink.send(Message::Text(err("rate_limited", "too many frames").into())).await.is_err() { break "" }
                    continue;
                }
                let mut out: Vec<String> = Vec::new();
                let next = handle(&state, &mut phase, &mut rx, text.as_str(), &mut out).await;
                let mut failed = false;
                for frame in out {
                    if sink.send(Message::Text(frame.into())).await.is_err() { failed = true; break; }
                }
                if failed { break "" }
                if let Next::Close(reason) = next { break reason }
            }
            pushed = recv_opt(&mut rx) => {
                match pushed {
                    Some(frame) => if sink.send(Message::Text(frame.into())).await.is_err() { break "" },
                    None => break "too slow",
                }
            }
            _ = ping.tick() => {
                if sink.send(Message::Ping(Vec::new().into())).await.is_err() { break "" }
            }
            _ = tokio::time::sleep_until(auth_deadline), if !authed => {
                let _ = sink.send(Message::Text(err("auth_timeout", "authenticate within 30 s").into())).await;
                break "auth timeout";
            }
            _ = shutdown.changed() => break "node shutting down",
        }
    };

    if let Phase::Authed { mailbox, conn, .. } = phase {
        let mut hub = state.hub.lock().await;
        if let Some(conns) = hub.conns.get_mut(&mailbox) {
            conns.remove(&conn);
            if conns.is_empty() {
                hub.conns.remove(&mailbox);
            }
        }
    }
    if !close_reason.is_empty() {
        let _ = sink
            .send(Message::Close(Some(CloseFrame { code: 1000, reason: close_reason.into() })))
            .await;
    }
    let _ = sink.close().await;
}

async fn handle(
    state: &Arc<NodeState>,
    phase: &mut Phase,
    rx: &mut Option<mpsc::Receiver<String>>,
    text: &str,
    out: &mut Vec<String>,
) -> Next {
    let frame: In = match serde_json::from_str(text) {
        Ok(f) => f,
        Err(_) => {
            out.push(err("bad_frame", "unknown or malformed frame"));
            return Next::Continue;
        }
    };
    match frame {
        In::Ping => out.push(json!({"t": "pong"}).to_string()),

        In::Hello { mailbox, pubkey } => {
            if !matches!(phase, Phase::Fresh) {
                out.push(err("bad_state", "hello was already sent"));
                return Next::Continue;
            }
            let (Some(mailbox), Some(pubkey)) =
                (parse_hex16(&mailbox), unb64(&pubkey).and_then(|v| <[u8; 32]>::try_from(v).ok()))
            else {
                out.push(err("bad_frame", "mailbox must be 32 hex chars and pub a 32-byte Ed25519 key"));
                return Next::Continue;
            };
            if VerifyingKey::from_bytes(&pubkey).is_err() {
                out.push(err("bad_frame", "pub is not a valid Ed25519 key"));
                return Next::Continue;
            }
            let mut nonce = [0u8; 32];
            rand::rngs::OsRng.fill_bytes(&mut nonce);
            out.push(json!({"t": "challenge", "nonce": b64(&nonce)}).to_string());
            *phase = Phase::Challenged { mailbox, pubkey, nonce };
        }

        In::Auth { sig } => {
            let Phase::Challenged { mailbox, pubkey, nonce } = *phase else {
                out.push(err("bad_state", "send hello first"));
                return Next::Continue;
            };
            let ok = unb64(&sig)
                .and_then(|s| <[u8; 64]>::try_from(s).ok())
                .map(|s| {
                    let vk = VerifyingKey::from_bytes(&pubkey).expect("checked at hello");
                    vk.verify(&auth_message(&nonce, &mailbox), &Signature::from_bytes(&s)).is_ok()
                })
                .unwrap_or(false);
            if !ok {
                out.push(err("bad_signature", "challenge signature does not verify"));
                return Next::Close("bad signature");
            }
            let bound = match state.store.bind(&mailbox, &pubkey, now_ms()) {
                Ok(k) => k,
                Err(e) => {
                    tracing::error!("bind failed: {e}");
                    out.push(err("internal", "storage error"));
                    return Next::Close("internal error");
                }
            };
            if bound != pubkey {
                out.push(err("key_mismatch", "this mailbox is bound to another device key"));
                return Next::Close("key mismatch");
            }
            let conn = state.conn_id();
            let (tx, new_rx) = mpsc::channel(PUSH_QUEUE);
            state.hub.lock().await.conns.entry(mailbox).or_default().insert(conn, tx);
            *rx = Some(new_rx);
            *phase = Phase::Authed { mailbox, pubkey, conn };
            let has_card = state.store.binding(&mailbox).ok().flatten().and_then(|b| b.card).is_some();
            out.push(json!({"t": "ready", "mailbox": hex::encode(mailbox), "card": has_card}).to_string());
            match state.store.pending(&mailbox, now_ms()) {
                Ok(pending) => {
                    for q in pending {
                        out.push(json!({"t": "env", "id": hex::encode(q.id), "env": b64(&q.env)}).to_string());
                    }
                }
                Err(e) => tracing::error!("pending query failed: {e}"),
            }
        }

        In::Register { card } => {
            let Phase::Authed { mailbox, pubkey, .. } = *phase else {
                out.push(err("auth_required", "authenticate first"));
                return Next::Continue;
            };
            let Some(card) = unb64(&card) else {
                out.push(err("bad_frame", "card must be base64"));
                return Next::Continue;
            };
            if let Err(reason) = state.verifier.verify(&card, &mailbox, &pubkey) {
                out.push(err("card_rejected", &reason));
                return Next::Continue;
            }
            match state.store.set_card(&mailbox, &card, now_ms()) {
                Ok(()) => out.push(json!({"t": "registered"}).to_string()),
                Err(e) => {
                    tracing::error!("set_card failed: {e}");
                    out.push(err("internal", "storage error"));
                }
            }
        }

        In::Send { to, env } => {
            if !matches!(phase, Phase::Authed { .. }) {
                out.push(err("auth_required", "authenticate first"));
                return Next::Continue;
            }
            let Some(to) = parse_hex16(&to) else {
                out.push(err("bad_frame", "to must be 32 hex chars"));
                return Next::Continue;
            };
            let Some(env) = unb64(&env) else {
                out.push(err("bad_frame", "env must be base64url"));
                return Next::Continue;
            };
            let Some(id) = envelope_id(&env) else {
                out.push(err("malformed", "env is not a v1 envelope"));
                return Next::Continue;
            };
            let id_hex = hex::encode(id);
            if env.len() > MAX_ENVELOPE_BYTES {
                out.push(err_id("too_large", "envelope over 2 MiB, use a blob", &id_hex));
                return Next::Continue;
            }
            match state.store.enqueue(&to, &id, &env, now_ms() + RETENTION_MS, MAILBOX_QUOTA) {
                Ok(Enqueue::Stored) => {
                    let frame = json!({"t": "env", "id": id_hex, "env": b64(&env)}).to_string();
                    push(state, &to, frame).await;
                    out.push(json!({"t": "sent", "id": id_hex}).to_string());
                }
                Ok(Enqueue::Duplicate) => out.push(json!({"t": "sent", "id": id_hex, "dup": true}).to_string()),
                Ok(Enqueue::QuotaExceeded) => out.push(err_id("quota", "recipient mailbox is full", &id_hex)),
                Err(e) => {
                    tracing::error!("enqueue failed: {e}");
                    out.push(err_id("internal", "storage error", &id_hex));
                }
            }
        }

        In::Ack { id } => {
            let Phase::Authed { mailbox, .. } = *phase else {
                out.push(err("auth_required", "authenticate first"));
                return Next::Continue;
            };
            let Some(id) = parse_hex16(&id) else {
                out.push(err("bad_frame", "id must be 32 hex chars"));
                return Next::Continue;
            };
            if let Err(e) = state.store.ack(&mailbox, &id) {
                tracing::error!("ack failed: {e}");
            }
        }

        In::Presence { mailboxes } => {
            if !matches!(phase, Phase::Authed { .. }) {
                out.push(err("auth_required", "authenticate first"));
                return Next::Continue;
            }
            let hub = state.hub.lock().await;
            let online: Vec<String> = mailboxes
                .iter()
                .take(MAX_PRESENCE)
                .filter_map(|m| parse_hex16(m))
                .filter(|m| hub.conns.get(m).is_some_and(|c| !c.is_empty()))
                .map(hex::encode)
                .collect();
            out.push(json!({"t": "presence", "online": online}).to_string());
        }
    }
    Next::Continue
}

/// Pushes a frame to every live connection of `mailbox`. A connection whose queue is full is
/// dropped from the hub, which closes it once it drains.
async fn push(state: &Arc<NodeState>, mailbox: &[u8; 16], frame: String) {
    let mut hub = state.hub.lock().await;
    let Some(conns) = hub.conns.get_mut(mailbox) else { return };
    conns.retain(|_, tx| match tx.try_send(frame.clone()) {
        Ok(()) => true,
        Err(mpsc::error::TrySendError::Full(_)) | Err(mpsc::error::TrySendError::Closed(_)) => false,
    });
    if conns.is_empty() {
        hub.conns.remove(mailbox);
    }
}
