# relay-core public API (contract for relay-ffi, relay-wasm and every client)

This is the exact surface the clients code against. relay-ffi (UniFFI, Swift) and relay-wasm
(wasm-bindgen, TypeScript) expose the same object with the same method names (snake_case in
Rust, camelCase in Swift and TS). Bytes are `Vec<u8>` / `Data` / `Uint8Array`. JSON strings
carry `AppMessage` (spec section 5) and the small structs below.

## Object `RelayEngine`

Constructors:
- `RelayEngine::create(display_name: String) -> RelayEngine` : new identity.
- `RelayEngine::restore(state: Vec<u8>) -> Result<RelayEngine>` : from `export_state()`.

Identity:
- `export_state(&self) -> Vec<u8>` : whole state (identity, contacts, sessions, groups). The
  client seals it at rest and saves it after every mutating call (or debounced, 300 ms).
- `fingerprint_hex(&self) -> String` (64 hex), `safety_words(&self) -> Vec<String>` (4 words),
  `mailbox_hex(&self) -> String` (32 hex), `display_name()`, `set_display_name(String)`.
- `my_card(&self, node_url: Option<String>, handle: Option<String>) -> String` : `relay1:...`
- `my_compact_link(&self, node_url: Option<String>) -> String` : `relay1c:...` (fits a QR).
- `device_signing_public(&self) -> Vec<u8>` (Ed25519 32 B, for node auth)
- `sign_node_challenge(&self, nonce: Vec<u8>) -> Vec<u8>` (Ed25519 sig over
  `"soma-relay/node-auth/v1" || nonce || mailbox_bytes`).
- `rotate_prekey_if_due(&self, now_ms: i64) -> bool`.

Contacts:
- `add_contact(&self, card: String) -> Result<ContactJson>` : accepts `relay1:` full cards.
  Verifies the hybrid signature. Idempotent; a changed key for a known fingerprint is an error
  `KeyChanged` unless `replace = true` variant `add_contact_replacing` is used.
- `parse_compact_link(&self, link: String) -> Result<CompactJson>` : `{fingerprint, node_url, handle}`.
- `contacts(&self) -> String` (JSON array of ContactJson), `remove_contact(fp)`,
  `set_verified(fp, bool)`, `rename_contact(fp, name)`.
- `contact_safety_words(fp) -> Vec<String>` : 4 words derived from BOTH fingerprints (same on
  both sides, order independent), `contact_safety_code(fp) -> String` (`418 902 377`).
- ContactJson: `{ "fingerprint", "name", "mailbox", "verified", "node_url"?, "handle"?, "added_at" }`.

Messaging:
- `encrypt_for(&self, fp: String, app_message_json: String) -> Result<Vec<u8>>` : one Envelope
  (postcard bytes), kind direct, tag = peer mailbox. Creates the session on first use.
- `mesh_tag_for(&self, fp: String, now_ms: i64) -> Vec<u8>` : current mesh tag.
- `retag_for_mesh(&self, envelope: Vec<u8>, fp: String, now_ms: i64) -> Vec<u8>` : same envelope,
  tag swapped to the rotating mesh tag.
- `open(&self, envelope: Vec<u8>, now_ms: i64) -> Result<Option<InboundJson>>` : tries every
  session/group the tag matches (mailbox, current or previous mesh tag, group tag). `None` = not
  for me (the client may still forward it on the mesh). Dedups by envelope id.
- InboundJson: `{ "from": fp, "group"?: group_id, "channel"?: name, "message": AppMessage,
  "envelope_id": hex }`. Unknown sender with a valid first message carrying a full card returns
  `from` = new fp and adds the contact as unverified (message request).

Groups:
- `create_group(name, member_fps: Vec<String>) -> Result<String /*group_id*/>`
- `group_encrypt(group_id, app_message_json) -> Result<Vec<Vec<u8>>>` : one group envelope plus
  any pending sender-key distribution envelopes for members.
- `groups() -> String` JSON `[{id, name, members:[fp], admins:[fp]}]`,
  `group_add(group_id, fp) -> Result<Vec<Vec<u8>>>`, `group_remove(group_id, fp) -> Result<Vec<Vec<u8>>>`,
  `leave_group(group_id)`.

Local channels:
- `channel_encrypt(name, password: Option<String>, app_message_json) -> Vec<u8>`
- `join_channel(name, password: Option<String>)`, `leave_channel(name)`.

Attachments (stateless helpers):
- `seal_attachment(plain: Vec<u8>) -> SealedJson + bytes` exposed as two calls:
  `seal_attachment(plain) -> Vec<u8>` where the output is `key(32) || sha256(32) || ciphertext`
  and `open_attachment(key, sha256, ciphertext) -> Result<Vec<u8>>`.

Calls:
- `call_key(fp, call_id: String) -> Result<Vec<u8>>` : 32 bytes, same on both sides.

Mesh (sans-IO helpers, free functions or a separate `MeshRouter` object):
- `MeshRouter::new()`;
  `on_frame(&self, frame: Vec<u8>, from_link: u32, now_ms: i64) -> MeshResult` where MeshResult
  = `{ complete: Option<Vec<u8> /*envelope*/>, forward: Vec<Vec<u8> /*frames*/>, exclude_link: u32 }`;
  `frames_for(&self, envelope: Vec<u8>, mtu: u32) -> Vec<Vec<u8>>` (marks own id as seen).
  Forwarding decrements TTL inside the envelope header when the frame is the first fragment;
  simpler v1 rule: the router forwards frames as they are and tracks seen (id,index); TTL lives
  in a 1-byte frame header field (`hops_left`) decremented per hop, dropped at 0.

Errors: one enum `RelayError { InvalidCard, KeyChanged, NoSession, Decrypt, Malformed, Unknown,
Storage, Group }` with a message string.

Determinism hooks for tests: `RelayEngine::create_with_seed(name, seed: [u8;32])` (test builds only).
