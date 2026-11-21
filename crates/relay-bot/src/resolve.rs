//! Turns the `to` field of `POST /v1/messages` into a known contact.
//!
//! Accepted forms: a full card (`relay1:...`), a compact link (`relay1c:...`), a handle
//! (`ines@relay.example.org`), a mailbox (32 hex) or a fingerprint (64 hex) of a contact.

use sha3::{Digest, Sha3_256};

use crate::Bot;
use crate::engine::Contact;

/// Mailbox of a fingerprint: first 16 bytes of `SHA3-256("soma-relay/mailbox" || fp)`.
pub fn mailbox_of(fingerprint_hex: &str) -> Option<String> {
    let fp = hex::decode(fingerprint_hex).ok()?;
    if fp.len() != 32 {
        return None;
    }
    let mut h = Sha3_256::new();
    h.update(b"soma-relay/mailbox");
    h.update(&fp);
    Some(hex::encode(&h.finalize()[..16]))
}

fn is_hex(s: &str, len: usize) -> bool {
    s.len() == len && s.bytes().all(|c| c.is_ascii_hexdigit())
}

/// Base URL for a node given as a URL or a bare host.
fn node_base(node: &str) -> String {
    let node = node.trim().trim_end_matches('/');
    if node.starts_with("http://") || node.starts_with("https://") {
        node.to_string()
    } else {
        format!("https://{node}")
    }
}

async fn fetch_card(bot: &Bot, url: String) -> Result<String, String> {
    let resp = bot.http.get(&url).send().await.map_err(|e| format!("fetching {url}: {e}"))?;
    if !resp.status().is_success() {
        return Err(format!("fetching {url}: HTTP {}", resp.status()));
    }
    resp.text().await.map_err(|e| format!("fetching {url}: {e}"))
}

fn add(bot: &Bot, card: &str) -> Result<Contact, String> {
    let c = bot.engine.add_contact(card.trim()).map_err(|e| format!("card rejected: {e}"))?;
    bot.save();
    Ok(c)
}

fn known_by(bot: &Bot, pred: impl Fn(&Contact) -> bool) -> Option<Contact> {
    bot.engine.contacts().into_iter().find(pred)
}

/// Resolves `to` to a contact, fetching and verifying its card when needed.
pub async fn resolve(bot: &Bot, to: &str) -> Result<Contact, String> {
    let to = to.trim();
    if to.starts_with("relay1:") {
        return add(bot, to);
    }
    if to.starts_with("relay1c:") {
        let link = bot.engine.parse_compact_link(to).map_err(|e| format!("bad link: {e}"))?;
        let fp = link.fingerprint.to_lowercase();
        if let Some(c) = known_by(bot, |c| c.fingerprint.eq_ignore_ascii_case(&fp)) {
            return Ok(c);
        }
        let mailbox = mailbox_of(&fp).ok_or("bad fingerprint in link")?;
        let base = link.node_url.as_deref().map(node_base).unwrap_or_else(|| bot.node_base());
        let url = match &link.handle {
            Some(h) => format!("{base}/v1/directory/{h}"),
            None => format!("{base}/v1/cards/{mailbox}"),
        };
        let card = fetch_card(bot, url).await?;
        let c = add(bot, &card)?;
        if !c.fingerprint.eq_ignore_ascii_case(&fp) {
            return Err("the card fetched for this link has another fingerprint".into());
        }
        return Ok(c);
    }
    if let Some((handle, node)) = to.split_once('@') {
        let handle = handle.trim().to_lowercase();
        if let Some(c) = known_by(bot, |c| c.handle.as_deref() == Some(handle.as_str())) {
            return Ok(c);
        }
        let card = fetch_card(bot, format!("{}/v1/directory/{handle}", node_base(node))).await?;
        return add(bot, &card);
    }
    if is_hex(to, 64) {
        return known_by(bot, |c| c.fingerprint.eq_ignore_ascii_case(to))
            .ok_or_else(|| "unknown fingerprint: send a card, link or handle first".into());
    }
    if is_hex(to, 32) {
        if let Some(c) = known_by(bot, |c| c.mailbox.eq_ignore_ascii_case(to)) {
            return Ok(c);
        }
        let card = fetch_card(bot, format!("{}/v1/cards/{}", bot.node_base(), to.to_lowercase())).await?;
        let c = add(bot, &card)?;
        if !c.mailbox.eq_ignore_ascii_case(to) {
            return Err("the card registered for this mailbox belongs to someone else".into());
        }
        return Ok(c);
    }
    Err("`to` must be a relay1: card, a relay1c: link, handle@node, a mailbox or a fingerprint".into())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mailbox_derivation_is_sha3() {
        let fp = "00".repeat(32);
        let mut h = Sha3_256::new();
        h.update(b"soma-relay/mailbox");
        h.update([0u8; 32]);
        assert_eq!(mailbox_of(&fp).unwrap(), hex::encode(&h.finalize()[..16]));
        assert!(mailbox_of("abcd").is_none());
    }

    #[test]
    fn bases() {
        assert_eq!(node_base("relay.example.org"), "https://relay.example.org");
        assert_eq!(node_base("http://127.0.0.1:8080/"), "http://127.0.0.1:8080");
    }
}
