//! Node client: keeps one authenticated WebSocket to the bot's node, registers the card,
//! receives and opens envelopes, sends queued envelopes. Reconnects with backoff.

use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration;

use base64::Engine as _;
use base64::engine::general_purpose::{STANDARD, URL_SAFE, URL_SAFE_NO_PAD};
use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use tokio::sync::{mpsc, oneshot};
use tokio_tungstenite::tungstenite::Message;

use crate::inbox::InboxItem;
use crate::{Bot, now_ms};

/// An envelope waiting to go out, with a channel for the node's verdict.
pub struct Outgoing {
    /// Recipient mailbox (32 hex).
    pub to_mailbox: String,
    pub env: Vec<u8>,
    /// Envelope id (32 hex), echoed by the node in `sent`.
    pub id: String,
    pub done: oneshot::Sender<Result<(), String>>,
}

fn b64(b: &[u8]) -> String {
    URL_SAFE_NO_PAD.encode(b)
}

fn unb64(s: &str) -> Option<Vec<u8>> {
    URL_SAFE_NO_PAD.decode(s).or_else(|_| URL_SAFE.decode(s)).or_else(|_| STANDARD.decode(s)).ok()
}

/// Envelope id of a v1 envelope (bytes 19..35 of the postcard encoding).
pub fn envelope_id_hex(env: &[u8]) -> Option<String> {
    (env.len() >= 35 && env[0] == 1).then(|| hex::encode(&env[19..35]))
}

/// WebSocket URL of a node base URL.
pub fn ws_url(node: &url::Url) -> String {
    let base = node.as_str().trim_end_matches('/');
    let rest = base.strip_prefix("https://").map(|r| format!("wss://{r}"));
    let rest = rest.or_else(|| base.strip_prefix("http://").map(|r| format!("ws://{r}")));
    format!("{}/v1/ws", rest.unwrap_or_else(|| base.to_string()))
}

/// Runs forever: connect, serve, reconnect.
pub async fn run(bot: Arc<Bot>, mut outbox: mpsc::Receiver<Outgoing>) {
    let mut backoff = Duration::from_secs(1);
    loop {
        match session(&bot, &mut outbox).await {
            Ok(()) => backoff = Duration::from_secs(1),
            Err(e) => tracing::warn!("node connection: {e}"),
        }
        bot.set_connected(false);
        tokio::time::sleep(backoff).await;
        backoff = (backoff * 2).min(Duration::from_secs(30));
    }
}

async fn session(bot: &Arc<Bot>, outbox: &mut mpsc::Receiver<Outgoing>) -> anyhow::Result<()> {
    let url = ws_url(&bot.settings.node_url);
    let (ws, _) = tokio_tungstenite::connect_async(&url).await?;
    let (mut sink, mut stream) = ws.split();

    async fn next_json(
        stream: &mut (impl futures_util::Stream<Item = Result<Message, tokio_tungstenite::tungstenite::Error>> + Unpin),
    ) -> anyhow::Result<Value> {
        loop {
            match tokio::time::timeout(Duration::from_secs(30), stream.next()).await {
                Err(_) => anyhow::bail!("node did not answer"),
                Ok(None) => anyhow::bail!("node closed the connection"),
                Ok(Some(Err(e))) => return Err(e.into()),
                Ok(Some(Ok(Message::Text(t)))) => return Ok(serde_json::from_str(t.as_str())?),
                Ok(Some(Ok(Message::Close(c)))) => anyhow::bail!("node closed the connection: {c:?}"),
                Ok(Some(Ok(_))) => continue,
            }
        }
    }

    let mailbox = bot.engine.mailbox_hex();
    let hello = json!({"t": "hello", "mailbox": mailbox, "pub": b64(&bot.engine.device_signing_public())});
    sink.send(Message::Text(hello.to_string().into())).await?;
    let ch = next_json(&mut stream).await?;
    if ch["t"] != "challenge" {
        anyhow::bail!("expected challenge, got {ch}");
    }
    let nonce = ch["nonce"].as_str().and_then(unb64).ok_or_else(|| anyhow::anyhow!("bad nonce"))?;
    let sig = bot.engine.sign_node_challenge(&nonce);
    sink.send(Message::Text(json!({"t": "auth", "sig": b64(&sig)}).to_string().into())).await?;
    let ready = next_json(&mut stream).await?;
    if ready["t"] != "ready" {
        anyhow::bail!("authentication refused: {ready}");
    }
    let register = json!({"t": "register", "card": b64(bot.my_card().as_bytes())});
    sink.send(Message::Text(register.to_string().into())).await?;
    bot.set_connected(true);
    tracing::info!(node = %bot.settings.node_url, "connected to node");

    let mut pending: HashMap<String, oneshot::Sender<Result<(), String>>> = HashMap::new();
    let mut ping = tokio::time::interval(Duration::from_secs(25));
    let mut rotate = tokio::time::interval(Duration::from_secs(3600));

    loop {
        tokio::select! {
            frame = next_json(&mut stream) => {
                let frame = frame?;
                match frame["t"].as_str().unwrap_or("") {
                    "env" => {
                        if let Some(ack) = receive(bot, &frame).await {
                            sink.send(Message::Text(json!({"t": "ack", "id": ack}).to_string().into())).await?;
                        }
                    }
                    "sent" => {
                        if let Some(tx) = frame["id"].as_str().and_then(|id| pending.remove(id)) {
                            let _ = tx.send(Ok(()));
                        }
                    }
                    "error" => {
                        let msg = format!("{}: {}", frame["code"].as_str().unwrap_or("error"), frame["msg"].as_str().unwrap_or(""));
                        match frame["id"].as_str().and_then(|id| pending.remove(id)) {
                            Some(tx) => { let _ = tx.send(Err(msg)); }
                            None => tracing::warn!("node error: {msg}"),
                        }
                    }
                    _ => {}
                }
            }
            out = outbox.recv() => {
                let Some(out) = out else { return Ok(()) };
                let frame = json!({"t": "send", "to": out.to_mailbox, "env": b64(&out.env)});
                if let Err(e) = sink.send(Message::Text(frame.to_string().into())).await {
                    let _ = out.done.send(Err(format!("connection lost: {e}")));
                    return Err(e.into());
                }
                pending.insert(out.id, out.done);
            }
            _ = ping.tick() => {
                sink.send(Message::Text(json!({"t": "ping"}).to_string().into())).await?;
            }
            _ = rotate.tick() => {
                if bot.engine.rotate_prekey_if_due(now_ms()) {
                    bot.save();
                    let register = json!({"t": "register", "card": b64(bot.my_card().as_bytes())});
                    sink.send(Message::Text(register.to_string().into())).await?;
                }
            }
        }
    }
}

/// Handles one `env` frame. Returns the id to acknowledge. Envelopes that fail to open are
/// acknowledged too, so a bad envelope cannot block the mailbox.
async fn receive(bot: &Arc<Bot>, frame: &Value) -> Option<String> {
    let env = frame["env"].as_str().and_then(unb64)?;
    let id = frame["id"].as_str().map(str::to_string).or_else(|| envelope_id_hex(&env))?;
    if bot.inbox.lock().await.seen(&id) {
        return Some(id);
    }
    let opened = bot.engine.open(&env, now_ms());
    bot.save();
    let inbound = match opened {
        Ok(Some(v)) => v,
        Ok(None) => {
            tracing::debug!("envelope {id} is not for this identity");
            return Some(id);
        }
        Err(e) => {
            tracing::warn!("envelope {id} could not be opened: {e}");
            return Some(id);
        }
    };
    let message = inbound.get("message").cloned().unwrap_or(Value::Null);
    if message["kind"] == "typing" {
        return Some(id);
    }
    let from = inbound["from"].as_str().unwrap_or_default().to_string();
    let from_name = bot.engine.contacts().into_iter().find(|c| c.fingerprint == from).map(|c| c.name);
    let item = InboxItem {
        seq: 0,
        received_at: now_ms(),
        from,
        from_name,
        group: inbound["group"].as_str().map(str::to_string),
        envelope_id: id.clone(),
        message,
    };
    let item = bot.inbox.lock().await.push(item);
    if let Some(hook) = bot.settings.webhook.clone() {
        let http = bot.http.clone();
        tokio::spawn(async move {
            match http.post(hook).json(&item).send().await {
                Ok(r) if !r.status().is_success() => tracing::warn!("webhook answered HTTP {}", r.status()),
                Err(e) => tracing::warn!("webhook failed: {e}"),
                _ => {}
            }
        });
    }
    Some(id)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ws_urls() {
        assert_eq!(ws_url(&"https://relay.example.org".parse().unwrap()), "wss://relay.example.org/v1/ws");
        assert_eq!(ws_url(&"http://127.0.0.1:8080/".parse().unwrap()), "ws://127.0.0.1:8080/v1/ws");
    }
}
