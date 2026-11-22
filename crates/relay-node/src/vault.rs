//! Encrypted vault blobs for passkey backup. The node stores opaque bytes keyed by a vault id
//! and only checks that the writer owns the mailbox the id was first written from.

use std::sync::Arc;

use axum::extract::{Path, State};
use axum::http::{HeaderMap, HeaderValue, StatusCode, header};
use axum::response::{IntoResponse, Response};
use bytes::Bytes;
use ed25519_dalek::{Signature, Verifier, VerifyingKey};
use serde_json::json;
use sha2::{Digest, Sha256};

use crate::NodeState;
use crate::http::api_error;
use crate::store::{MAX_VAULT_BYTES, PutVault};
use crate::util::{now_ms, parse_hex16, unb64, valid_sha256_hex};

const BAD_ID: &str = "path must be 64 lowercase hex characters";

fn internal(what: &str, e: rusqlite::Error) -> Response {
    tracing::error!("{what} failed: {e}");
    api_error(StatusCode::INTERNAL_SERVER_ERROR, "internal", "storage error")
}

pub(crate) async fn get_vault(State(state): State<Arc<NodeState>>, Path(id): Path<String>) -> Response {
    if !valid_sha256_hex(&id) {
        return api_error(StatusCode::BAD_REQUEST, "bad_vault_id", BAD_ID);
    }
    match state.store.get_vault(&id) {
        Ok(Some(blob)) => (
            StatusCode::OK,
            [
                (header::CONTENT_TYPE, HeaderValue::from_static("application/octet-stream")),
                (header::CACHE_CONTROL, HeaderValue::from_static("no-store")),
            ],
            blob,
        )
            .into_response(),
        Ok(None) => api_error(StatusCode::NOT_FOUND, "not_found", "unknown vault"),
        Err(e) => internal("vault lookup", e),
    }
}

pub(crate) async fn put_vault(
    State(state): State<Arc<NodeState>>,
    Path(id): Path<String>,
    headers: HeaderMap,
    blob: Bytes,
) -> Response {
    if !valid_sha256_hex(&id) {
        return api_error(StatusCode::BAD_REQUEST, "bad_vault_id", BAD_ID);
    }
    if blob.len() > MAX_VAULT_BYTES {
        return api_error(StatusCode::PAYLOAD_TOO_LARGE, "too_large", "vault blobs are limited to 1 MiB");
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
        Err(e) => return internal("binding lookup", e),
    };
    let verified = VerifyingKey::from_bytes(&binding.pubkey)
        .map(|vk| {
            let mut msg = b"relay-vault-v1".to_vec();
            msg.extend(id.as_bytes());
            msg.extend(Sha256::digest(&blob));
            vk.verify(&msg, &Signature::from_bytes(&sig)).is_ok()
        })
        .unwrap_or(false);
    if !verified {
        return api_error(StatusCode::FORBIDDEN, "bad_signature", "signature does not match the mailbox key");
    }
    match state.store.put_vault(&id, &mailbox, &blob, now_ms()) {
        Ok(PutVault::Written) => (StatusCode::OK, axum::Json(json!({"id": id, "size": blob.len()}))).into_response(),
        Ok(PutVault::OwnerMismatch) => {
            api_error(StatusCode::FORBIDDEN, "not_owner", "this vault belongs to another mailbox")
        }
        Err(e) => internal("vault write", e),
    }
}
