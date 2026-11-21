//! Contact card verification hook.

/// Checks a contact card posted to the node, either with the WebSocket `register` frame or
/// with `PUT /v1/directory/{handle}`.
///
/// The node stores cards as opaque bytes. A verifier decides whether a card may be bound to
/// a mailbox: a full implementation parses the `relay1:` card, checks its hybrid
/// signature (Ed25519 + ML-DSA-87), checks that `mailbox` is the first 16 bytes of
/// `SHA3-256("soma-relay/mailbox" || fingerprint)` and that `device_pub` is the device
/// signing key listed in the card. [`CoreCardVerifier`] does exactly that with relay-core and
/// is the default of the `relay-node` binary; other policies plug in by implementing this
/// trait and passing it to [`crate::NodeState::with_verifier`].
pub trait CardVerifier: Send + Sync + 'static {
    /// Returns `Ok(())` when `card` may be published for `mailbox` by the holder of
    /// `device_pub`, or a short human-readable reason otherwise.
    fn verify(&self, card: &[u8], mailbox: &[u8; 16], device_pub: &[u8; 32]) -> Result<(), String>;
}

/// Lenient verifier for tests and experiments: accepts any non-empty card up to [`MAX_CARD_BYTES`]. Binding is still
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

/// Production verifier backed by relay-core. A card is accepted only when:
/// - it is UTF-8 text in the `relay1:` form and parses as a v1 card,
/// - its hybrid signature (Ed25519 + ML-DSA-87) verifies,
/// - `SHA3-256("soma-relay/mailbox" || fingerprint)[..16]` equals the mailbox it is posted for,
/// - its Ed25519 identity key (the device signing key in v1) equals the key bound by auth.
#[derive(Debug, Default, Clone, Copy)]
pub struct CoreCardVerifier;

impl CardVerifier for CoreCardVerifier {
    fn verify(&self, card: &[u8], mailbox: &[u8; 16], device_pub: &[u8; 32]) -> Result<(), String> {
        if card.len() > MAX_CARD_BYTES {
            return Err("card too large".into());
        }
        let text = std::str::from_utf8(card).map_err(|_| "card is not relay1: text".to_string())?;
        let parsed = relay_core::card::Card::parse(text).map_err(|e| e.to_string())?;
        if &relay_core::card::mailbox(&parsed.fingerprint()) != mailbox {
            return Err("card fingerprint does not derive this mailbox".into());
        }
        if &parsed.body.ed_pub != device_pub {
            return Err("card signing key differs from the key bound to this mailbox".into());
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use relay_core::RelayEngine;

    fn mailbox_of(e: &RelayEngine) -> [u8; 16] {
        hex::decode(e.mailbox_hex()).unwrap().try_into().unwrap()
    }

    #[test]
    fn real_card_accepted_and_mismatches_refused() {
        let mut a = RelayEngine::create_with_seed("ada".into(), [1; 32]);
        let b = RelayEngine::create_with_seed("bob".into(), [2; 32]);
        let card = a.my_card(Some("https://relay.example.org".into()), None);
        let key: [u8; 32] = a.device_signing_public().try_into().unwrap();
        let v = CoreCardVerifier;
        assert_eq!(v.verify(card.as_bytes(), &mailbox_of(&a), &key), Ok(()));

        // Another mailbox.
        assert!(v.verify(card.as_bytes(), &mailbox_of(&b), &key).is_err());
        // Another bound key.
        let other: [u8; 32] = b.device_signing_public().try_into().unwrap();
        assert!(v.verify(card.as_bytes(), &mailbox_of(&a), &other).is_err());
        // Tampered card.
        let mut bad = card.clone().into_bytes();
        let i = bad.len() - 10;
        bad[i] = if bad[i] == b'A' { b'B' } else { b'A' };
        assert!(v.verify(&bad, &mailbox_of(&a), &key).is_err());
        // Not a card.
        assert!(v.verify(b"relay1:nope", &mailbox_of(&a), &key).is_err());
    }
}
