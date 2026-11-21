//! HTTP API: cards, directory, blobs, ICE list, health, static web client.

use std::net::{IpAddr, SocketAddr};
use std::sync::Arc;

use axum::body::Body;
use axum::extract::{ConnectInfo, DefaultBodyLimit, Path, Request, State};
use axum::http::{HeaderMap, HeaderValue, StatusCode, header};
use axum::middleware::{self, Next};
use axum::response::{IntoResponse, Response};
use axum::routing::get;
use axum::{Json, Router};
use bytes::Bytes;
use ed25519_dalek::{Signature, Verifier, VerifyingKey};
use futures_util::StreamExt;
use rand::RngCore;
use serde_json::json;
use sha2::{Digest, Sha256};
use tokio::io::AsyncWriteExt;
use tower_http::cors::CorsLayer;
use tower_http::services::{ServeDir, ServeFile};

use crate::store::Claim;
use crate::util::{now_ms, parse_hex16, unb64, valid_handle, valid_sha256_hex};
use crate::{MAX_BLOB_BYTES, NodeState, RETENTION_MS, ws};

/// Builds the router.
pub fn router(state: Arc<NodeState>) -> Router {
    let api = Router::new()
        .route("/healthz", get(healthz))
        .route("/v1/ws", get(ws::upgrade))
        .route("/v1/ice", get(ice))
        .route("/v1/cards/{mailbox}", get(get_card))
        .route("/v1/directory/{handle}", get(get_handle).put(put_handle))
        .route(
            "/v1/blobs/{sha}",
            get(get_blob).put(put_blob).layer(DefaultBodyLimit::disable()),
        )
        .route("/v1", get(not_found))
        .route("/v1/{*rest}", get(not_found).put(not_found).post(not_found))
        .layer(middleware::from_fn_with_state(state.clone(), rate_limit))
        .layer(CorsLayer::permissive())
        .with_state(state.clone());

    let web = &state.config.web_dir;
    let spa = ServeDir::new(web).fallback(ServeFile::new(web.join("index.html")));
    api.fallback_service(spa)
}

fn api_error(status: StatusCode, code: &str, msg: &str) -> Response {
    (status, Json(json!({"error": code, "msg": msg}))).into_response()
}

fn client_ip(state: &NodeState, req: &Request) -> IpAddr {
    if state.config.trust_proxy
        && let Some(ip) = req
            .headers()
            .get("x-forwarded-for")
            .and_then(|v| v.to_str().ok())
            .and_then(|v| v.split(',').next())
            .and_then(|v| v.trim().parse().ok())
    {
        return ip;
    }
    req.extensions()
        .get::<ConnectInfo<SocketAddr>>()
        .map(|c| c.0.ip())
        .unwrap_or(IpAddr::from([0, 0, 0, 0]))
}

async fn rate_limit(State(state): State<Arc<NodeState>>, req: Request, next: Next) -> Response {
    let ip = client_ip(&state, &req);
    if !state.http_limiter.check(ip) {
        let mut r = api_error(StatusCode::TOO_MANY_REQUESTS, "rate_limited", "slow down");
        r.headers_mut().insert(header::RETRY_AFTER, HeaderValue::from_static("1"));
        return r;
    }
    next.run(req).await
}

async fn not_found() -> Response {
    api_error(StatusCode::NOT_FOUND, "not_found", "no such endpoint")
}

async fn healthz(State(state): State<Arc<NodeState>>) -> Response {
    Json(json!({
        "ok": true,
        "version": env!("CARGO_PKG_VERSION"),
        "public_url": state.config.public_url,
    }))
    .into_response()
}

async fn ice(State(state): State<Arc<NodeState>>) -> Response {
    Json(json!({"iceServers": state.ice})).into_response()
}

fn card_response(card: Vec<u8>, mailbox: Option<&[u8; 16]>) -> Response {
    let ct = if std::str::from_utf8(&card).is_ok() { "text/plain; charset=utf-8" } else { "application/octet-stream" };
    let mut r = (StatusCode::OK, [(header::CONTENT_TYPE, ct)], card).into_response();
    r.headers_mut().insert(header::CACHE_CONTROL, HeaderValue::from_static("no-cache"));
    if let Some(m) = mailbox {
        r.headers_mut().insert("x-relay-mailbox", HeaderValue::from_str(&hex::encode(m)).unwrap());
    }
    r
}

async fn get_card(State(state): State<Arc<NodeState>>, Path(mailbox): Path<String>) -> Response {
    let Some(mb) = parse_hex16(&mailbox) else {
        return api_error(StatusCode::BAD_REQUEST, "bad_mailbox", "mailbox must be 32 hex chars");
    };
    match state.store.binding(&mb) {
        Ok(Some(b)) => match b.card {
            Some(card) => card_response(card, Some(&mb)),
            None => api_error(StatusCode::NOT_FOUND, "not_found", "no card registered"),
        },
        Ok(None) => api_error(StatusCode::NOT_FOUND, "not_found", "unknown mailbox"),
        Err(e) => {
            tracing::error!("binding lookup failed: {e}");
            api_error(StatusCode::INTERNAL_SERVER_ERROR, "internal", "storage error")
        }
    }
}

async fn get_handle(State(state): State<Arc<NodeState>>, Path(handle): Path<String>) -> Response {
    if !valid_handle(&handle) {
        return api_error(StatusCode::BAD_REQUEST, "bad_handle", "3-32 chars from [a-z0-9_.-]");
    }
    match state.store.lookup_handle(&handle) {
        Ok(Some((mb, card))) => card_response(card, Some(&mb)),
        Ok(None) => api_error(StatusCode::NOT_FOUND, "not_found", "unknown handle"),
        Err(e) => {
            tracing::error!("directory lookup failed: {e}");
            api_error(StatusCode::INTERNAL_SERVER_ERROR, "internal", "storage error")
        }
    }
}

async fn put_handle(
    State(state): State<Arc<NodeState>>,
    Path(handle): Path<String>,
    headers: HeaderMap,
    card: Bytes,
) -> Response {
    if !valid_handle(&handle) {
        return api_error(StatusCode::BAD_REQUEST, "bad_handle", "3-32 chars from [a-z0-9_.-]");
    }
    let Some(mailbox) = headers.get("x-relay-mailbox").and_then(|v| v.to_str().ok()).and_then(parse_hex16) else {
        return api_error(StatusCode::BAD_REQUEST, "bad_mailbox", "X-Relay-Mailbox must be 32 hex chars");
    };
    let Some(sig) = headers
        .get("x-relay-sig")
        .and_then(|v| v.to_str().ok())
        .and_then(unb64)
        .and_then(|s| <[u8; 64]>::try_from(s).ok())
    else {
        return api_error(StatusCode::BAD_REQUEST, "bad_signature", "X-Relay-Sig must be a base64 Ed25519 signature");
    };
    let binding = match state.store.binding(&mailbox) {
        Ok(Some(b)) => b,
        Ok(None) => {
            return api_error(StatusCode::FORBIDDEN, "unknown_mailbox", "authenticate this mailbox over /v1/ws first");
        }
        Err(e) => {
            tracing::error!("binding lookup failed: {e}");
            return api_error(StatusCode::INTERNAL_SERVER_ERROR, "internal", "storage error");
        }
    };
    let verified = VerifyingKey::from_bytes(&binding.pubkey)
        .map(|vk| vk.verify(&card, &Signature::from_bytes(&sig)).is_ok())
        .unwrap_or(false);
    if !verified {
        return api_error(StatusCode::FORBIDDEN, "bad_signature", "signature does not match the mailbox key");
    }
    if let Err(reason) = state.verifier.verify(&card, &mailbox, &binding.pubkey) {
        return api_error(StatusCode::UNPROCESSABLE_ENTITY, "card_rejected", &reason);
    }
    match state.store.claim_handle(&handle, &mailbox, &card, now_ms()) {
        Ok(Claim::Created) => (StatusCode::CREATED, Json(json!({"handle": handle, "mailbox": hex::encode(mailbox)}))).into_response(),
        Ok(Claim::Updated) => (StatusCode::OK, Json(json!({"handle": handle, "mailbox": hex::encode(mailbox)}))).into_response(),
        Ok(Claim::Taken) => api_error(StatusCode::CONFLICT, "handle_taken", "this handle belongs to another mailbox"),
        Ok(Claim::TooMany) => api_error(StatusCode::CONFLICT, "too_many_handles", "a mailbox may hold 5 handles"),
        Err(e) => {
            tracing::error!("directory claim failed: {e}");
            api_error(StatusCode::INTERNAL_SERVER_ERROR, "internal", "storage error")
        }
    }
}

async fn get_blob(State(state): State<Arc<NodeState>>, Path(sha): Path<String>) -> Response {
    if !valid_sha256_hex(&sha) {
        return api_error(StatusCode::BAD_REQUEST, "bad_hash", "path must be a lowercase hex SHA-256");
    }
    match state.store.blob_exists(&sha, now_ms()) {
        Ok(true) => {}
        Ok(false) => return api_error(StatusCode::NOT_FOUND, "not_found", "unknown or expired blob"),
        Err(e) => {
            tracing::error!("blob lookup failed: {e}");
            return api_error(StatusCode::INTERNAL_SERVER_ERROR, "internal", "storage error");
        }
    }
    let file = match tokio::fs::File::open(state.blob_path(&sha)).await {
        Ok(f) => f,
        Err(_) => return api_error(StatusCode::NOT_FOUND, "not_found", "blob file missing"),
    };
    let len = file.metadata().await.map(|m| m.len()).unwrap_or(0);
    let body = Body::from_stream(tokio_util::io::ReaderStream::new(file));
    (
        StatusCode::OK,
        [
            (header::CONTENT_TYPE, HeaderValue::from_static("application/octet-stream")),
            (header::CONTENT_LENGTH, HeaderValue::from(len)),
            (header::CACHE_CONTROL, HeaderValue::from_static("private, max-age=1209600, immutable")),
        ],
        body,
    )
        .into_response()
}

async fn put_blob(
    State(state): State<Arc<NodeState>>,
    Path(sha): Path<String>,
    headers: HeaderMap,
    body: Body,
) -> Response {
    if !valid_sha256_hex(&sha) {
        return api_error(StatusCode::BAD_REQUEST, "bad_hash", "path must be a lowercase hex SHA-256");
    }
    let declared = headers
        .get(header::CONTENT_LENGTH)
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.parse::<u64>().ok());
    if declared.is_some_and(|n| n > MAX_BLOB_BYTES) {
        return api_error(StatusCode::PAYLOAD_TOO_LARGE, "too_large", "blobs are limited to 100 MiB");
    }

    let mut suffix = [0u8; 8];
    rand::rngs::OsRng.fill_bytes(&mut suffix);
    let tmp = state.config.data_dir.join("blobs").join(format!(".tmp-{}", hex::encode(suffix)));
    let result = receive_blob(&tmp, body).await;
    let (digest, size) = match result {
        Ok(v) => v,
        Err(resp) => {
            let _ = tokio::fs::remove_file(&tmp).await;
            return resp;
        }
    };
    if digest != sha {
        let _ = tokio::fs::remove_file(&tmp).await;
        return api_error(StatusCode::BAD_REQUEST, "hash_mismatch", "SHA-256 of the body does not match the path");
    }
    if let Err(e) = tokio::fs::rename(&tmp, state.blob_path(&sha)).await {
        tracing::error!("blob rename failed: {e}");
        let _ = tokio::fs::remove_file(&tmp).await;
        return api_error(StatusCode::INTERNAL_SERVER_ERROR, "internal", "storage error");
    }
    let expires_at = now_ms() + RETENTION_MS;
    if let Err(e) = state.store.put_blob(&sha, size as i64, expires_at) {
        tracing::error!("blob index failed: {e}");
        return api_error(StatusCode::INTERNAL_SERVER_ERROR, "internal", "storage error");
    }
    (StatusCode::CREATED, Json(json!({"sha256": sha, "size": size, "expires_at": expires_at}))).into_response()
}

/// Streams the request body into `tmp`, hashing as it goes. Returns (hex sha256, size).
#[allow(clippy::result_large_err)]
async fn receive_blob(tmp: &std::path::Path, body: Body) -> Result<(String, u64), Response> {
    let internal = |e: std::io::Error| {
        tracing::error!("blob write failed: {e}");
        api_error(StatusCode::INTERNAL_SERVER_ERROR, "internal", "storage error")
    };
    let mut file = tokio::fs::File::create(tmp).await.map_err(internal)?;
    let mut hasher = Sha256::new();
    let mut size: u64 = 0;
    let mut stream = body.into_data_stream();
    while let Some(chunk) = stream.next().await {
        let chunk = chunk.map_err(|_| api_error(StatusCode::BAD_REQUEST, "bad_body", "upload interrupted"))?;
        size += chunk.len() as u64;
        if size > MAX_BLOB_BYTES {
            return Err(api_error(StatusCode::PAYLOAD_TOO_LARGE, "too_large", "blobs are limited to 100 MiB"));
        }
        hasher.update(&chunk);
        file.write_all(&chunk).await.map_err(internal)?;
    }
    file.flush().await.map_err(internal)?;
    file.sync_all().await.map_err(internal)?;
    Ok((hex::encode(hasher.finalize()), size))
}
