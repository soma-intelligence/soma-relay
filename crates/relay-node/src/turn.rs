//! Short-lived TURN credentials for coturn's `use-auth-secret` mode (the TURN REST API).
//!
//! The username is `<expiry unix seconds>:<random tag>` and the password is
//! `base64(HMAC-SHA1(shared secret, username))`. coturn checks the same HMAC and refuses the
//! username once the expiry has passed. Nothing here is logged.

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD;
use hmac::{Hmac, Mac};
use rand::RngCore;
use sha1::Sha1;

/// TURN settings of a node: the shared secret, the TURN URLs and the credential lifetime.
#[derive(Clone)]
pub struct TurnConfig {
    secret: String,
    urls: Vec<String>,
    ttl_secs: u64,
}

impl std::fmt::Debug for TurnConfig {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("TurnConfig")
            .field("secret", &"<redacted>")
            .field("urls", &self.urls)
            .field("ttl_secs", &self.ttl_secs)
            .finish()
    }
}

impl TurnConfig {
    /// Builds the TURN settings when both the secret and at least one URL are set.
    /// `urls` is a comma-separated list; empty entries are skipped.
    pub fn new(secret: Option<&str>, urls: Option<&str>, ttl_secs: u64) -> Option<Self> {
        let secret = secret.filter(|s| !s.is_empty())?;
        let urls: Vec<String> = urls?
            .split(',')
            .map(str::trim)
            .filter(|u| !u.is_empty())
            .map(String::from)
            .collect();
        if urls.is_empty() {
            return None;
        }
        Some(Self { secret: secret.to_string(), urls, ttl_secs: ttl_secs.max(1) })
    }

    /// A fresh RTCIceServer entry with credentials valid for the configured lifetime.
    pub fn ice_server(&self, now_unix: u64) -> serde_json::Value {
        let mut tag = [0u8; 8];
        rand::thread_rng().fill_bytes(&mut tag);
        let username = format!("{}:{}", now_unix + self.ttl_secs, hex::encode(tag));
        let credential = credential(&self.secret, &username);
        serde_json::json!({"urls": self.urls, "username": username, "credential": credential})
    }
}

/// `base64(HMAC-SHA1(secret, username))`, the coturn REST API password.
pub fn credential(secret: &str, username: &str) -> String {
    let mut mac = Hmac::<Sha1>::new_from_slice(secret.as_bytes()).expect("HMAC takes any key length");
    mac.update(username.as_bytes());
    STANDARD.encode(mac.finalize().into_bytes())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn credential_matches_openssl() {
        // printf '%s' "1700000000:abcd" | openssl dgst -sha1 -hmac north -binary | base64
        assert_eq!(credential("north", "1700000000:abcd"), "H0A8YRnrGPhqbqPxZdRmDSOcU/I=");
    }

    #[test]
    fn ice_server_shape() {
        let t = TurnConfig::new(Some("north"), Some(" turn:h:3478?transport=udp, ,turns:h:5349?transport=tcp"), 600).unwrap();
        let s = t.ice_server(1_700_000_000);
        assert_eq!(s["urls"], serde_json::json!(["turn:h:3478?transport=udp", "turns:h:5349?transport=tcp"]));
        let user = s["username"].as_str().unwrap();
        let (exp, tag) = user.split_once(':').unwrap();
        assert_eq!(exp, "1700000600");
        assert_eq!(tag.len(), 16);
        assert!(tag.bytes().all(|b| b.is_ascii_hexdigit()));
        assert_eq!(s["credential"], credential("north", user));
        assert_ne!(t.ice_server(1_700_000_000)["username"], s["username"]);
    }

    #[test]
    fn off_unless_secret_and_urls() {
        assert!(TurnConfig::new(None, Some("turn:h"), 60).is_none());
        assert!(TurnConfig::new(Some("s"), None, 60).is_none());
        assert!(TurnConfig::new(Some(""), Some("turn:h"), 60).is_none());
        assert!(TurnConfig::new(Some("s"), Some(" , "), 60).is_none());
        assert!(!format!("{:?}", TurnConfig::new(Some("north"), Some("turn:h"), 60).unwrap()).contains("north"));
    }
}
