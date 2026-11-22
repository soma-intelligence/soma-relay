//! Seals a passkey vault blob from an engine state file, to seed a local node in UI tests.
//!
//! ```text
//! cargo run -p relay-core --example make_vault -- \
//!     --state engine.bin --prf-second <64 hex> --credential-id <hex> --out vault.bin \
//!     [--create <display name>] [--handle <handle>] [--node-url <url>]
//! ```
//!
//! `--state` holds raw `RelayEngine::export_state()` bytes; with `--create` a new identity is
//! written there first. Prints one JSON line: `vault_id`, `mailbox`, `sig` (base64url of the
//! Ed25519 signature for `X-Relay-Sig`), `vault_key` (hex) and `size`. Then:
//! `curl -X PUT --data-binary @vault.bin -H "X-Relay-Mailbox: <mailbox>" -H "X-Relay-Sig: <sig>"
//! <node>/v1/vault/<vault_id>` (the mailbox must have authenticated over /v1/ws once).

use std::process::exit;

use base64::Engine as _;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use relay_core::RelayEngine;
use relay_core::util::{hex, unhex};
use relay_core::vault::{VaultPlain, seal_vault, vault_id, vault_key};

fn usage(msg: &str) -> ! {
    eprintln!("make_vault: {msg}");
    eprintln!(
        "usage: make_vault --state FILE --prf-second HEX32 --credential-id HEX --out FILE \
         [--create NAME] [--handle H] [--node-url URL]"
    );
    exit(64)
}

fn main() {
    let mut state = None;
    let mut prf_second = None;
    let mut cred = None;
    let mut out = None;
    let mut create = None;
    let mut handle = None;
    let mut node_url = None;
    let mut args = std::env::args().skip(1);
    while let Some(flag) = args.next() {
        let value = args.next().unwrap_or_else(|| usage(&format!("{flag} needs a value")));
        match flag.as_str() {
            "--state" => state = Some(value),
            "--prf-second" => prf_second = Some(value),
            "--credential-id" => cred = Some(value),
            "--out" => out = Some(value),
            "--create" => create = Some(value),
            "--handle" => handle = Some(value),
            "--node-url" => node_url = Some(value),
            _ => usage(&format!("unknown flag {flag}")),
        }
    }
    let state = state.unwrap_or_else(|| usage("--state is required"));
    let out = out.unwrap_or_else(|| usage("--out is required"));
    let prf_second: [u8; 32] = unhex(&prf_second.unwrap_or_else(|| usage("--prf-second is required")))
        .ok()
        .and_then(|b| b.try_into().ok())
        .unwrap_or_else(|| usage("--prf-second must be 64 hex characters"));
    let cred = unhex(&cred.unwrap_or_else(|| usage("--credential-id is required")))
        .unwrap_or_else(|_| usage("--credential-id must be hex"));

    if let Some(name) = create {
        std::fs::write(&state, RelayEngine::create(name).export_state())
            .unwrap_or_else(|e| usage(&format!("cannot write {state}: {e}")));
    }
    let bytes = std::fs::read(&state).unwrap_or_else(|e| usage(&format!("cannot read {state}: {e}")));
    let engine = RelayEngine::restore(&bytes).unwrap_or_else(|e| usage(&format!("bad state: {e}")));

    let key = vault_key(&prf_second);
    let id = vault_id(&cred);
    let plain = VaultPlain { v: 1, engine: bytes, handle, node_url, channels_prefs: Vec::new(), photo: None };
    let blob = seal_vault(&key, &id, &plain).unwrap_or_else(|e| usage(&format!("seal: {e}")));
    std::fs::write(&out, &blob).unwrap_or_else(|e| usage(&format!("cannot write {out}: {e}")));
    let sig = engine.sign_vault(&id, &blob);
    println!(
        "{}",
        serde_json::json!({
            "vault_id": id,
            "mailbox": engine.mailbox_hex(),
            "sig": URL_SAFE_NO_PAD.encode(sig),
            "vault_key": hex(&key),
            "size": blob.len(),
        })
    );
}
