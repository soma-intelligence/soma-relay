//! APNs sender: HTTP/2 with token auth (ES256 JWT signed by a `.p8` key).

use std::sync::Mutex;
use std::time::{Duration, Instant};

use p256::ecdsa::SigningKey;
use p256::pkcs8::DecodePrivateKey;
use serde_json::{Value, json};

use super::{Outcome, es256_jwt, unix_now};

pub const HOST_PROD: &str = "https://api.push.apple.com";
pub const HOST_SANDBOX: &str = "https://api.sandbox.push.apple.com";
/// Apple accepts a provider token for one hour; refresh it well before.
const JWT_LIFETIME: Duration = Duration::from_secs(50 * 60);

/// The alert every APNs push carries. No content, no sender.
pub fn payload() -> Value {
    json!({"aps": {"alert": {"title": "Soma Relay", "body": "Nouveau message"}, "sound": "default", "mutable-content": 1, "content-available": 1}})
}

pub struct Apns {
    key: SigningKey,
    key_id: String,
    team_id: String,
    topic: String,
    client: reqwest::Client,
    jwt: Mutex<Option<(String, Instant)>>,
}

impl Apns {
    /// Builds the sender from the four settings. `key_p8` is the PEM text of the `.p8` key or
    /// a path to it. Returns `Ok(None)` when none of the settings is given (APNs off) and an
    /// error when they are incomplete or the key does not load.
    pub fn from_config(
        key_p8: Option<&str>,
        key_id: Option<&str>,
        team_id: Option<&str>,
        topic: Option<&str>,
    ) -> anyhow::Result<Option<Self>> {
        fn given(o: Option<&str>) -> Option<&str> {
            o.map(str::trim).filter(|s| !s.is_empty())
        }
        let (key_p8, key_id, team_id, topic) = (given(key_p8), given(key_id), given(team_id), given(topic));
        match (key_p8, key_id, team_id, topic) {
            (None, None, None, None) => Ok(None),
            (Some(k), Some(id), Some(team), Some(topic)) => {
                let pem = if k.contains("-----BEGIN") {
                    k.replace("\\n", "\n")
                } else {
                    std::fs::read_to_string(k).map_err(|e| anyhow::anyhow!("RELAY_APNS_KEY_P8: cannot read the key file: {e}"))?
                };
                let key = SigningKey::from_pkcs8_pem(pem.trim())
                    .map_err(|e| anyhow::anyhow!("RELAY_APNS_KEY_P8 is not a PKCS#8 P-256 key: {e}"))?;
                Ok(Some(Self::new(key, id, team, topic)))
            }
            _ => anyhow::bail!(
                "APNs needs all of RELAY_APNS_KEY_P8, RELAY_APNS_KEY_ID, RELAY_APNS_TEAM_ID and RELAY_APNS_TOPIC (or none)"
            ),
        }
    }

    pub fn new(key: SigningKey, key_id: &str, team_id: &str, topic: &str) -> Self {
        let client = reqwest::Client::builder()
            .timeout(Duration::from_secs(10))
            .pool_idle_timeout(Duration::from_secs(600))
            .build()
            .expect("reqwest client");
        Self {
            key,
            key_id: key_id.into(),
            team_id: team_id.into(),
            topic: topic.into(),
            client,
            jwt: Mutex::new(None),
        }
    }

    /// The provider token, cached for 50 minutes.
    pub fn token(&self) -> String {
        let mut cached = self.jwt.lock().unwrap_or_else(|e| e.into_inner());
        if let Some((jwt, at)) = cached.as_ref()
            && at.elapsed() < JWT_LIFETIME
        {
            return jwt.clone();
        }
        let jwt = es256_jwt(
            &json!({"alg": "ES256", "kid": self.key_id}),
            &json!({"iss": self.team_id, "iat": unix_now()}),
            &self.key,
        );
        *cached = Some((jwt.clone(), Instant::now()));
        jwt
    }

    fn drop_token(&self) {
        *self.jwt.lock().unwrap_or_else(|e| e.into_inner()) = None;
    }

    /// Sends the alert to `token` (hex). `env` is `prod` or `sandbox`.
    pub async fn send(&self, token: &str, env: &str) -> Outcome {
        let host = if env == "sandbox" { HOST_SANDBOX } else { HOST_PROD };
        let url = format!("{host}/3/device/{token}");
        let resp = self
            .client
            .post(&url)
            .header("authorization", format!("bearer {}", self.token()))
            .header("apns-topic", &self.topic)
            .header("apns-push-type", "alert")
            .header("apns-priority", "10")
            .header("apns-collapse-id", "relay")
            .header("content-type", "application/json")
            .body(payload().to_string())
            .send()
            .await;
        let resp = match resp {
            Ok(r) => r,
            Err(e) => {
                tracing::warn!("apns request failed: {e}");
                return Outcome::Failed;
            }
        };
        let status = resp.status().as_u16();
        if status == 200 {
            return Outcome::Sent;
        }
        let reason = resp
            .bytes()
            .await
            .ok()
            .and_then(|b| serde_json::from_slice::<Value>(&b).ok())
            .and_then(|v| v.get("reason").and_then(Value::as_str).map(str::to_string))
            .unwrap_or_default();
        classify(status, &reason, || self.drop_token())
    }
}

/// Maps an APNs error answer to an outcome.
fn classify(status: u16, reason: &str, on_bad_token: impl FnOnce()) -> Outcome {
    match (status, reason) {
        (410, _) | (_, "BadDeviceToken") | (_, "Unregistered") | (_, "DeviceTokenNotForTopic") => Outcome::Remove,
        (403, "ExpiredProviderToken") | (403, "InvalidProviderToken") => {
            on_bad_token();
            tracing::warn!(reason, "apns refused the provider token");
            Outcome::Failed
        }
        _ => {
            tracing::warn!(status, reason, "apns push refused");
            Outcome::Failed
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::push::decode_jwt;
    use p256::pkcs8::{EncodePrivateKey, LineEnding};

    #[test]
    fn payload_is_exact() {
        assert_eq!(
            payload(),
            serde_json::from_str::<Value>(
                r#"{"aps":{"alert":{"title":"Soma Relay","body":"Nouveau message"},"sound":"default","mutable-content":1,"content-available":1}}"#
            )
            .unwrap()
        );
    }

    #[test]
    fn config_and_cached_jwt() {
        assert!(Apns::from_config(None, None, None, None).unwrap().is_none());
        assert!(Apns::from_config(None, Some("K"), None, None).is_err());
        let key = SigningKey::random(&mut p256::elliptic_curve::rand_core::OsRng);
        let pem = key.to_pkcs8_pem(LineEnding::LF).unwrap();
        let a = Apns::from_config(Some(&pem), Some("KEYID12345"), Some("TEAMID1234"), Some("me.somalabs.relay"))
            .unwrap()
            .unwrap();
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("AuthKey.p8");
        std::fs::write(&path, pem.as_bytes()).unwrap();
        assert!(Apns::from_config(Some(path.to_str().unwrap()), Some("K"), Some("T"), Some("x")).unwrap().is_some());
        assert!(Apns::from_config(Some("-----BEGIN PRIVATE KEY-----\nnope\n"), Some("K"), Some("T"), Some("x")).is_err());

        let t1 = a.token();
        assert_eq!(t1, a.token(), "token is cached");
        let (h, c, s) = decode_jwt(&t1).unwrap();
        assert_eq!((h["alg"].as_str(), h["kid"].as_str()), (Some("ES256"), Some("KEYID12345")));
        assert_eq!(c["iss"], "TEAMID1234");
        assert!(c["iat"].as_u64().unwrap() > 1_700_000_000);
        assert_eq!(s.len(), 64);
        a.drop_token();
        assert!(a.jwt.lock().unwrap().is_none());
    }

    #[test]
    fn error_classes() {
        let mut dropped = false;
        assert_eq!(classify(410, "Unregistered", || {}), Outcome::Remove);
        assert_eq!(classify(400, "BadDeviceToken", || {}), Outcome::Remove);
        assert_eq!(classify(429, "TooManyRequests", || {}), Outcome::Failed);
        assert_eq!(classify(403, "ExpiredProviderToken", || dropped = true), Outcome::Failed);
        assert!(dropped);
    }
}
