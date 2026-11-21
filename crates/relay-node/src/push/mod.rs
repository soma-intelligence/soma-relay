//! Wake-up pushes for offline mailboxes: APNs (iOS) and Web Push (browsers).
//!
//! A push never carries content or sender. When the node stores an envelope for a mailbox
//! that has no live connection, it sends one push to the device registered with the `push`
//! frame, at most one per mailbox every 30 s, from a background task so the send path never
//! waits on Apple or a push service.

pub mod apns;
pub mod webpush;

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use p256::ecdsa::signature::Signer;
use p256::ecdsa::{Signature, SigningKey};
use serde_json::Value;

use crate::NodeState;
use crate::netguard::GuardedClient;
use crate::store::PushReg;
use crate::util::{b64, unb64};

/// At most one push per mailbox in this window.
pub const PUSH_EVERY: Duration = Duration::from_secs(30);
/// Throttle entries kept before old ones are pruned.
const THROTTLE_PRUNE_AT: usize = 10_000;

/// What a sender learned about the registration it used.
#[derive(Debug, PartialEq, Eq)]
pub enum Outcome {
    Sent,
    /// The token or subscription is gone for good: delete it.
    Remove,
    Failed,
}

/// Per-mailbox push throttle.
#[derive(Default)]
pub struct Throttle {
    last: HashMap<[u8; 16], Instant>,
}

impl Throttle {
    /// Returns `true` (and records `now`) when `mailbox` had no push in the last
    /// [`PUSH_EVERY`].
    pub fn allow(&mut self, mailbox: &[u8; 16], now: Instant) -> bool {
        if let Some(t) = self.last.get(mailbox)
            && now.saturating_duration_since(*t) < PUSH_EVERY
        {
            return false;
        }
        if self.last.len() >= THROTTLE_PRUNE_AT {
            self.last.retain(|_, t| now.saturating_duration_since(*t) < PUSH_EVERY);
        }
        self.last.insert(*mailbox, now);
        true
    }
}

/// Why a `push` frame was refused, sent back as `reason`.
#[derive(Debug, PartialEq, Eq)]
pub enum RegError {
    ApnsOff,
    BadRequest,
}

impl RegError {
    pub fn reason(&self) -> &'static str {
        match self {
            RegError::ApnsOff => "apns_off",
            RegError::BadRequest => "bad_request",
        }
    }
}

/// Validates the fields of a `push` frame. `Ok(None)` means unregister.
pub fn parse_registration(
    kind: &str,
    token: Option<&str>,
    env: Option<&str>,
    sub: Option<&Value>,
    apns_on: bool,
    net: &GuardedClient,
) -> Result<Option<PushReg>, RegError> {
    match kind {
        "none" => Ok(None),
        "apns" => {
            if !apns_on {
                return Err(RegError::ApnsOff);
            }
            let token = token.ok_or(RegError::BadRequest)?.trim().to_ascii_lowercase();
            if !(16..=200).contains(&token.len()) || token.len() % 2 != 0 || hex::decode(&token).is_err() {
                return Err(RegError::BadRequest);
            }
            let env = match env.unwrap_or("prod") {
                "prod" | "production" => "prod",
                "sandbox" | "development" => "sandbox",
                _ => return Err(RegError::BadRequest),
            };
            Ok(Some(PushReg { kind: "apns".into(), token: Some(token), env: Some(env.into()), sub_json: None }))
        }
        "webpush" => {
            let sub = webpush::Subscription::from_json(sub.ok_or(RegError::BadRequest)?, net)
                .ok_or(RegError::BadRequest)?;
            Ok(Some(PushReg { kind: "webpush".into(), token: None, env: None, sub_json: Some(sub.to_json()) }))
        }
        _ => Err(RegError::BadRequest),
    }
}

/// Push senders and throttle, owned by [`NodeState`].
pub struct Notifier {
    pub(crate) apns: Option<apns::Apns>,
    pub(crate) vapid: webpush::Vapid,
    throttle: Mutex<Throttle>,
}

impl Notifier {
    pub fn new(apns: Option<apns::Apns>, vapid: webpush::Vapid) -> Self {
        Self { apns, vapid, throttle: Mutex::new(Throttle::default()) }
    }

    pub fn apns_on(&self) -> bool {
        self.apns.is_some()
    }

    fn allow(&self, mailbox: &[u8; 16]) -> bool {
        self.throttle.lock().unwrap_or_else(|e| e.into_inner()).allow(mailbox, Instant::now())
    }
}

/// Called after an envelope was stored for `mailbox` and no live connection took it.
/// Returns at once; the push itself runs in a background task.
pub(crate) fn wake(state: &Arc<NodeState>, mailbox: [u8; 16]) {
    if !state.notifier.allow(&mailbox) {
        return;
    }
    let state = state.clone();
    tokio::spawn(async move {
        let reg = match state.store.get_push(&mailbox) {
            Ok(Some(r)) => r,
            Ok(None) => return,
            Err(e) => {
                tracing::error!("push lookup failed: {e}");
                return;
            }
        };
        let outcome = match reg.kind.as_str() {
            "apns" => match (&state.notifier.apns, &reg.token) {
                (Some(apns), Some(token)) => apns.send(token, reg.env.as_deref().unwrap_or("prod")).await,
                _ => Outcome::Failed,
            },
            "webpush" => match reg.sub_json.as_deref().and_then(webpush::Subscription::from_stored) {
                Some(sub) => state.notifier.vapid.send(&state.net, &sub).await,
                None => Outcome::Remove,
            },
            _ => Outcome::Remove,
        };
        match outcome {
            Outcome::Sent => tracing::debug!(kind = %reg.kind, "push sent"),
            Outcome::Failed => tracing::warn!(kind = %reg.kind, "push failed"),
            Outcome::Remove => {
                tracing::info!(kind = %reg.kind, "push registration expired, removed");
                if let Err(e) = state.store.delete_push_if(&mailbox, &reg) {
                    tracing::error!("push delete failed: {e}");
                }
            }
        }
    });
}

/// A compact ES256 JWT: `b64(header).b64(claims).b64(r || s)`.
pub fn es256_jwt(header: &Value, claims: &Value, key: &SigningKey) -> String {
    let signing_input = format!("{}.{}", b64(header.to_string().as_bytes()), b64(claims.to_string().as_bytes()));
    let sig: Signature = key.sign(signing_input.as_bytes());
    format!("{signing_input}.{}", b64(&sig.to_bytes()))
}

/// Splits and decodes a JWT into (header, claims, signature bytes). Used by tests and checks.
pub fn decode_jwt(jwt: &str) -> Option<(Value, Value, Vec<u8>)> {
    let mut parts = jwt.split('.');
    let h = serde_json::from_slice(&unb64(parts.next()?)?).ok()?;
    let c = serde_json::from_slice(&unb64(parts.next()?)?).ok()?;
    let s = unb64(parts.next()?)?;
    if parts.next().is_some() {
        return None;
    }
    Some((h, c, s))
}

pub(crate) fn unix_now() -> u64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;
    use p256::ecdsa::signature::Verifier;
    use serde_json::json;

    #[test]
    fn throttle_one_per_30s() {
        let mut t = Throttle::default();
        let a = [1u8; 16];
        let b = [2u8; 16];
        let t0 = Instant::now();
        assert!(t.allow(&a, t0));
        assert!(!t.allow(&a, t0 + Duration::from_secs(1)));
        assert!(!t.allow(&a, t0 + Duration::from_secs(29)));
        assert!(t.allow(&b, t0 + Duration::from_secs(1)));
        assert!(t.allow(&a, t0 + Duration::from_secs(30)));
        assert!(!t.allow(&a, t0 + Duration::from_secs(31)));
    }

    #[test]
    fn jwt_shape_and_signature() {
        let key = SigningKey::random(&mut p256::elliptic_curve::rand_core::OsRng);
        let jwt = es256_jwt(&json!({"alg": "ES256", "kid": "ABC123"}), &json!({"iss": "TEAM", "iat": 1}), &key);
        assert_eq!(jwt.split('.').count(), 3);
        assert!(!jwt.contains('=') && !jwt.contains('+') && !jwt.contains('/'));
        let (h, c, s) = decode_jwt(&jwt).unwrap();
        assert_eq!(h["alg"], "ES256");
        assert_eq!(h["kid"], "ABC123");
        assert_eq!(c["iss"], "TEAM");
        assert_eq!(s.len(), 64, "ES256 signatures are raw r || s");
        let input = jwt.rsplit_once('.').unwrap().0;
        let sig = Signature::from_slice(&s).unwrap();
        key.verifying_key().verify(input.as_bytes(), &sig).unwrap();
    }

    #[test]
    fn registration_validation() {
        let net = GuardedClient::new("test");
        let tok = "ab".repeat(32);
        let r = parse_registration("apns", Some(&tok), Some("sandbox"), None, true, &net).unwrap().unwrap();
        assert_eq!((r.token.as_deref(), r.env.as_deref()), (Some(tok.as_str()), Some("sandbox")));
        assert_eq!(parse_registration("apns", Some(&tok), None, None, false, &net), Err(RegError::ApnsOff));
        assert_eq!(parse_registration("apns", Some("zz"), None, None, true, &net), Err(RegError::BadRequest));
        assert_eq!(parse_registration("apns", Some(&tok), Some("beta"), None, true, &net), Err(RegError::BadRequest));
        assert_eq!(parse_registration("none", None, None, None, false, &net), Ok(None));
        assert_eq!(parse_registration("fax", None, None, None, true, &net), Err(RegError::BadRequest));
        let bad = json!({"endpoint": "https://push.example.org/x", "keys": {"p256dh": "AAAA", "auth": "AAAA"}});
        assert_eq!(parse_registration("webpush", None, None, Some(&bad), true, &net), Err(RegError::BadRequest));
        let ua = p256::SecretKey::random(&mut p256::elliptic_curve::rand_core::OsRng);
        let p256dh = b64(p256::EncodedPoint::from(ua.public_key()).as_bytes());
        let good = json!({"endpoint": "https://push.example.org/x", "keys": {"p256dh": p256dh, "auth": b64(&[7; 16])}});
        assert!(parse_registration("webpush", None, None, Some(&good), false, &net).unwrap().is_some());
        let private = json!({"endpoint": "https://10.0.0.1/x", "keys": {"p256dh": p256dh, "auth": b64(&[7; 16])}});
        assert_eq!(parse_registration("webpush", None, None, Some(&private), true, &net), Err(RegError::BadRequest));
        let plain = json!({"endpoint": "http://push.example.org/x", "keys": {"p256dh": p256dh, "auth": b64(&[7; 16])}});
        assert_eq!(parse_registration("webpush", None, None, Some(&plain), true, &net), Err(RegError::BadRequest));
    }
}
