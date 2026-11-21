//! Small encoding and time helpers shared by the node.

use base64::Engine as _;
use base64::engine::general_purpose::{STANDARD, STANDARD_NO_PAD, URL_SAFE, URL_SAFE_NO_PAD};

/// Encodes bytes the way the node writes them on the wire: base64url, no padding.
pub fn b64(bytes: &[u8]) -> String {
    URL_SAFE_NO_PAD.encode(bytes)
}

/// Decodes base64 leniently: base64url or standard alphabet, with or without padding.
pub fn unb64(s: &str) -> Option<Vec<u8>> {
    let s = s.trim();
    URL_SAFE_NO_PAD
        .decode(s)
        .or_else(|_| URL_SAFE.decode(s))
        .or_else(|_| STANDARD.decode(s))
        .or_else(|_| STANDARD_NO_PAD.decode(s))
        .ok()
}

/// Parses a 16-byte mailbox id written as 32 hex characters (either case).
pub fn parse_hex16(s: &str) -> Option<[u8; 16]> {
    let v = hex::decode(s.trim()).ok()?;
    v.try_into().ok()
}

/// Milliseconds since the Unix epoch.
pub fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

/// Domain separation prefix of the WebSocket auth signature.
pub const NODE_AUTH_CONTEXT: &[u8] = b"soma-relay/node-auth/v1";

/// The exact bytes a client signs to answer a challenge:
/// `"soma-relay/node-auth/v1" || nonce (32) || mailbox (16)`.
pub fn auth_message(nonce: &[u8; 32], mailbox: &[u8; 16]) -> Vec<u8> {
    let mut m = Vec::with_capacity(NODE_AUTH_CONTEXT.len() + 48);
    m.extend_from_slice(NODE_AUTH_CONTEXT);
    m.extend_from_slice(nonce);
    m.extend_from_slice(mailbox);
    m
}

/// Offset of the 16-byte envelope id inside a postcard-encoded v1 `Envelope`
/// (`v: u8`, `kind: u8`, `tag: [u8; 16]`, `ttl: u8`, `id: [u8; 16]`, `body`).
const ENVELOPE_ID_OFFSET: usize = 1 + 1 + 16 + 1;

/// Reads the envelope id of a v1 envelope without decoding the body.
/// Returns `None` when the bytes are not a v1 envelope.
pub fn envelope_id(env: &[u8]) -> Option<[u8; 16]> {
    if env.len() < ENVELOPE_ID_OFFSET + 16 || env[0] != 1 {
        return None;
    }
    env[ENVELOPE_ID_OFFSET..ENVELOPE_ID_OFFSET + 16].try_into().ok()
}

/// Directory handle rule: 3 to 32 characters from `[a-z0-9_.-]`.
pub fn valid_handle(h: &str) -> bool {
    (3..=32).contains(&h.len())
        && h.bytes().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || matches!(c, b'_' | b'.' | b'-'))
}

/// A blob path segment must be a lowercase hex SHA-256 (64 characters).
pub fn valid_sha256_hex(s: &str) -> bool {
    s.len() == 64 && s.bytes().all(|c| c.is_ascii_digit() || (b'a'..=b'f').contains(&c))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn handles() {
        assert!(valid_handle("ines"));
        assert!(valid_handle("a.b-c_9"));
        assert!(!valid_handle("ab"));
        assert!(!valid_handle("Ines"));
        assert!(!valid_handle("ines@node"));
        assert!(!valid_handle(&"a".repeat(33)));
    }

    #[test]
    fn envelope_ids() {
        let mut env = vec![1u8, 1];
        env.extend([7u8; 16]);
        env.push(7);
        env.extend([9u8; 16]);
        env.push(0);
        assert_eq!(envelope_id(&env), Some([9u8; 16]));
        env[0] = 2;
        assert_eq!(envelope_id(&env), None);
        assert_eq!(envelope_id(&[1, 2, 3]), None);
    }

    #[test]
    fn lenient_b64() {
        assert_eq!(unb64("_-8"), Some(vec![0xff, 0xef]));
        assert_eq!(unb64("/+8="), Some(vec![0xff, 0xef]));
    }
}
