//! Safety words: the BIP-39 French list (2048 words, NFC), 11 bits per word.

use crate::util::sha3;

static WORDS_FR: &str = include_str!("words_fr.txt");

pub fn word_list() -> Vec<&'static str> {
    WORDS_FR.lines().filter(|l| !l.is_empty()).collect()
}

/// Four words from the first 44 bits of `bytes` (at least 6 bytes).
pub fn four_words(bytes: &[u8]) -> Vec<String> {
    let list = word_list();
    debug_assert_eq!(list.len(), 2048);
    let mut acc: u64 = 0;
    for b in bytes.iter().take(6) {
        acc = (acc << 8) | u64::from(*b);
    }
    // 48 bits in acc: keep the top 44.
    acc >>= 4;
    (0..4)
        .map(|i| {
            let idx = ((acc >> (33 - 11 * i)) & 0x7ff) as usize;
            list[idx % list.len()].to_string()
        })
        .collect()
}

/// Words of one fingerprint (shown under one's own QR).
pub fn fingerprint_words(fp: &[u8; 32]) -> Vec<String> {
    four_words(fp)
}

fn pair_hash(a: &[u8; 32], b: &[u8; 32]) -> [u8; 32] {
    let (lo, hi) = if a <= b { (a, b) } else { (b, a) };
    sha3(&[b"soma-relay/v1/safety", lo, hi])
}

/// Words both sides of a contact see (order independent).
pub fn pair_words(a: &[u8; 32], b: &[u8; 32]) -> Vec<String> {
    four_words(&pair_hash(a, b))
}

/// Nine digit code `418 902 377`, same on both sides.
pub fn pair_code(a: &[u8; 32], b: &[u8; 32]) -> String {
    let h = pair_hash(a, b);
    let mut v = [0u8; 8];
    v.copy_from_slice(&h[8..16]);
    let n = u64::from_be_bytes(v) % 1_000_000_000;
    format!("{:03} {:03} {:03}", n / 1_000_000, (n / 1000) % 1000, n % 1000)
}
