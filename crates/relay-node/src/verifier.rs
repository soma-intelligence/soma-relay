//! Contact card verification hook.

/// Checks a contact card posted to the node, either with the WebSocket `register` frame or
/// with `PUT /v1/directory/{handle}`.
///
/// The node stores cards as opaque bytes. A verifier decides whether a card may be bound to
/// a mailbox: a full implementation parses the `relay1:` card, checks its hybrid
/// signature (Ed25519 + ML-DSA-87), checks that `mailbox` is the first 16 bytes of
/// `SHA3-256("soma-relay/mailbox" || fingerprint)` and that `device_pub` is the device
/// signing key listed in the card. The relay-core card verifier plugs in here by
/// implementing this trait and passing it to [`crate::NodeState::with_verifier`].
pub trait CardVerifier: Send + Sync + 'static {
    /// Returns `Ok(())` when `card` may be published for `mailbox` by the holder of
    /// `device_pub`, or a short human-readable reason otherwise.
    fn verify(&self, card: &[u8], mailbox: &[u8; 16], device_pub: &[u8; 32]) -> Result<(), String>;
}

/// Default verifier: accepts any non-empty card up to [`MAX_CARD_BYTES`]. Binding is still
/// protected by the trust-on-first-use key check and by the signatures the node verifies
/// itself (WebSocket auth, directory PUT).
#[derive(Debug, Default, Clone, Copy)]
pub struct PermissiveVerifier;

/// Largest card the node accepts (a full hybrid card is about 6 to 7 KB).
pub const MAX_CARD_BYTES: usize = 64 * 1024;

impl CardVerifier for PermissiveVerifier {
    fn verify(&self, card: &[u8], _mailbox: &[u8; 16], _device_pub: &[u8; 32]) -> Result<(), String> {
        if card.is_empty() {
            return Err("empty card".into());
        }
        if card.len() > MAX_CARD_BYTES {
            return Err("card too large".into());
        }
        Ok(())
    }
}
