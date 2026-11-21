//! Local REST API of a bot.
//!
//! - `GET /healthz` and `GET /v1/card`, `GET /v1/card.png`: public (the card is public).
//! - `POST /v1/messages`, `GET /v1/messages?since=`: need `Authorization: Bearer <token>`.

use std::io::Cursor;
use std::sync::Arc;
use std::time::Duration;

use axum::extract::{Query, Request, State};
use axum::http::{StatusCode, header};
use axum::middleware::{self, Next};
use axum::response::{IntoResponse, Response};
use axum::routing::get;
use axum::{Json, Router};
use serde::Deserialize;
use serde_json::json;
use tokio::sync::oneshot;

use crate::node::{Outgoing, envelope_id_hex};
use crate::{Bot, now_ms, resolve};

pub fn router(bot: Arc<Bot>) -> Router {
    let private = Router::new()
        .route("/v1/messages", get(list_messages).post(send_message))
        .layer(middleware::from_fn_with_state(bot.clone(), require_token));
    Router::new()
        .route("/healthz", get(healthz))
        .route("/v1/card", get(card))
        .route("/v1/card.png", get(card_png))
        .merge(private)
        .with_state(bot)
}

fn error(status: StatusCode, msg: &str) -> Response {
    (status, Json(json!({"error": msg}))).into_response()
}

fn ct_eq(a: &[u8], b: &[u8]) -> bool {
    a.len() == b.len() && a.iter().zip(b).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

async fn require_token(State(bot): State<Arc<Bot>>, req: Request, next: Next) -> Response {
    let ok = req
        .headers()
        .get(header::AUTHORIZATION)
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.strip_prefix("Bearer "))
        .is_some_and(|t| ct_eq(t.trim().as_bytes(), bot.settings.token.as_bytes()));
    if !ok {
        return error(StatusCode::UNAUTHORIZED, "missing or wrong bearer token");
    }
    next.run(req).await
}

async fn healthz(State(bot): State<Arc<Bot>>) -> Response {
    Json(json!({"ok": true, "connected": bot.is_connected(), "mailbox": bot.engine.mailbox_hex()})).into_response()
}

async fn card(State(bot): State<Arc<Bot>>) -> Response {
    Json(json!({
        "name": bot.engine.display_name(),
        "fingerprint": bot.engine.fingerprint_hex(),
        "mailbox": bot.engine.mailbox_hex(),
        "safety_words": bot.engine.safety_words(),
        "node": bot.node_base(),
        "card": bot.my_card(),
        "link": bot.my_link(),
    }))
    .into_response()
}

/// PNG QR code of the compact link.
pub fn qr_png(data: &str) -> Result<Vec<u8>, String> {
    let code = qrcode::QrCode::with_error_correction_level(data.as_bytes(), qrcode::EcLevel::M)
        .map_err(|e| e.to_string())?;
    let img = code.render::<image::Luma<u8>>().min_dimensions(320, 320).quiet_zone(true).build();
    let mut out = Cursor::new(Vec::new());
    img.write_to(&mut out, image::ImageFormat::Png).map_err(|e| e.to_string())?;
    Ok(out.into_inner())
}

async fn card_png(State(bot): State<Arc<Bot>>) -> Response {
    match qr_png(&bot.my_link()) {
        Ok(png) => ([(header::CONTENT_TYPE, "image/png"), (header::CACHE_CONTROL, "no-cache")], png).into_response(),
        Err(e) => error(StatusCode::INTERNAL_SERVER_ERROR, &format!("QR rendering failed: {e}")),
    }
}

#[derive(Deserialize)]
struct SinceQuery {
    #[serde(default)]
    since: u64,
    #[serde(default)]
    limit: Option<usize>,
}

async fn list_messages(State(bot): State<Arc<Bot>>, Query(q): Query<SinceQuery>) -> Response {
    let limit = q.limit.unwrap_or(100).clamp(1, 1000);
    let items = bot.inbox.lock().await.since(q.since, limit);
    let next = items.last().map(|i| i.seq).unwrap_or(q.since);
    Json(json!({"messages": items, "next": next})).into_response()
}

#[derive(Deserialize)]
struct SendBody {
    to: String,
    text: String,
    #[serde(default)]
    reply_to: Option<String>,
}

/// Longest text a bot sends in one message.
const MAX_TEXT: usize = 32 * 1024;

async fn send_message(State(bot): State<Arc<Bot>>, Json(body): Json<SendBody>) -> Response {
    if body.text.is_empty() || body.text.len() > MAX_TEXT {
        return error(StatusCode::BAD_REQUEST, "text must be 1 to 32768 bytes");
    }
    let contact = match resolve::resolve(&bot, &body.to).await {
        Ok(c) => c,
        Err(e) => return error(StatusCode::UNPROCESSABLE_ENTITY, &e),
    };
    let mut msg = json!({
        "id": uuid::Uuid::now_v7().to_string(),
        "ts": now_ms(),
        "kind": "text",
        "text": body.text,
    });
    if let Some(r) = body.reply_to {
        msg["reply_to"] = json!(r);
    }
    let env = match bot.engine.encrypt_for(&contact.fingerprint, &msg.to_string()) {
        Ok(e) => e,
        Err(e) => return error(StatusCode::UNPROCESSABLE_ENTITY, &format!("encryption failed: {e}")),
    };
    bot.save();
    let Some(envelope_id) = envelope_id_hex(&env) else {
        return error(StatusCode::INTERNAL_SERVER_ERROR, "engine produced an unknown envelope format");
    };
    let (done, wait) = oneshot::channel();
    let out = Outgoing { to_mailbox: contact.mailbox.clone(), env, id: envelope_id.clone(), done };
    if bot.outbox.send(out).await.is_err() {
        return error(StatusCode::SERVICE_UNAVAILABLE, "node client stopped");
    }
    let summary = json!({
        "id": msg["id"],
        "envelope_id": envelope_id,
        "to": contact.fingerprint,
        "mailbox": contact.mailbox,
    });
    match tokio::time::timeout(Duration::from_secs(15), wait).await {
        Ok(Ok(Ok(()))) => (StatusCode::CREATED, Json(json!({"status": "sent", "message": summary}))).into_response(),
        Ok(Ok(Err(e))) => error(StatusCode::BAD_GATEWAY, &format!("node refused: {e}")),
        Ok(Err(_)) => error(StatusCode::BAD_GATEWAY, "connection to the node was lost"),
        Err(_) => (StatusCode::ACCEPTED, Json(json!({"status": "queued", "message": summary}))).into_response(),
    }
}
