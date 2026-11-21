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

## Implementation notes and deviations (relay-core 0.1, 2026-11-21)

These are binding: the code in `crates/relay-core`, `crates/relay-ffi` and `crates/relay-wasm`
behaves as written here wherever it differs from the contract above.

Crates: `libcrux-ml-kem` 0.0.11 and `libcrux-ml-dsa` 0.0.11 both build for wasm32 (portable
code), so no RustCrypto substitute was needed. `getrandom` 0.4 with `wasm_js` on wasm32 only;
no crate in the relay-core graph pulls getrandom 0.2 or `rand_core` with getrandom. Channel
passwords use `argon2` 0.5 (Argon2id, 19 MiB, 2 passes), once per join.

Signature changes:
- `join_channel(name, password) -> Result<()>` and `channel_encrypt(...) -> Result<Vec<u8>>`
  throw (bad name, bad JSON). They are `throws` in Swift and throw in JS.
- `seal_attachment` and `open_attachment` are methods of the engine (the engine owns the RNG).
- `group_encrypt` returns the sender-key distribution envelopes FIRST and the group envelope
  LAST. `group_add` returns `[key + log to the new member, op to each other member]`;
  `group_remove` returns `[op to the removed member, new key + log to each remaining member]`.
- `MeshRouter.frames_for(envelope, mtu)` has no clock: it timestamps the seen id with the latest
  `now_ms` given to `on_frame`.
- Infallible calls stay infallible: `remove_contact`, `set_verified`, `rename_contact` ignore an
  unknown or malformed fingerprint; `contact_safety_words` returns `[]` and
  `contact_safety_code` returns `""` for a malformed one; `mesh_tag_for` returns empty bytes for
  an unknown contact; `retag_for_mesh` returns the input unchanged when it cannot retag.
- `create_with_seed` and `regenerate_device_keys` exist only with the `testing` cargo feature.

Additions:
- `envelope_info(envelope) -> Result<String>`: `{"id","kind","tag","ttl","size"}` (hex), so a
  client can address an envelope (`tag` of a direct envelope = recipient mailbox; `kind`
  is `direct | group | channel | announce | control`).
- `groups()` items also carry `"mailboxes"` (hex, same order as `members`).

Bindings:
- Swift: module `RelayCore` (file `apple/Sources/RelayCore/RelayCoreFFI.swift`), C module
  `RelayCoreFFI` in `apple/Frameworks/RelayCoreFFI.xcframework`. `RelayEngine.create(displayName:)`
  and `RelayEngine.restore(state:) throws` are static; `MeshRouter()` is an init. Struct results
  (`add_contact`, `parse_compact_link`) are JSON strings. Errors: `RelayError.invalidCard(message:)`
  etc. `MeshResult` is a Swift struct `{complete: Data?, forward: [Data], excludeLink: UInt32}`.
- JS: `RelayEngine.create(name)`, `RelayEngine.restore(bytes)`, `new MeshRouter()`; times are
  numbers (ms); lists of envelopes are `Uint8Array[]`; `open` returns a string or `undefined`;
  `onFrame` returns `{complete: Uint8Array | null, forward: Uint8Array[], excludeLink: number}`.
  Errors are `Error` objects whose `name` is the RelayError variant.

Behaviour:
- Cards: `relay1:` card is about 10.5 KB binary, 14.1 K characters (ML-DSA-87 key 2592 B and
  signature 4627 B, two ML-KEM-1024 keys). `relay1c:` link is about 100 characters.
- Safety words: BIP-39 French list (2048 words, NFC, `crates/relay-core/src/words_fr.txt`),
  11 bits per word. Own words = first 44 bits of the fingerprint. Contact words and the
  `418 902 377` code = SHA3-256("soma-relay/v1/safety" || lower fp || higher fp).
- Opening: the first messages (until the peer answers) carry `ek`, the ML-KEM ciphertext, the
  prekey id and a sealed blob (AES-GCM under a key from DH(EK, IK_B), DH(EK, SPK_B) and the KEM
  secret) holding the sender's full card and its hybrid signature over the transcript. The outer
  ratchet header carries a 16-byte pseudonymous session id in clear. Replayed openings are
  refused through a cache of accepted ephemeral keys.
- PQ ratchet: each side announces its ratchet ML-KEM key in headers until the peer acknowledges
  it (`seen_kem`). On the first message of a new sending chain, once 50 messages or 24 hours
  passed, the sender encapsulates to the peer's key; the step repeats on every message of that
  chain and the receiver mixes it in during its DH ratchet step. The clock for this rule (and
  for weekly sender-key rotation) is the `ts` field of the AppMessage JSON, else the latest
  `now_ms` seen.
- Mesh tag: HKDF of a per-contact secret (X25519 of both device keys, both fingerprints) and the
  unix hour; `open` accepts the previous, current and next hour.
- Groups: the op log (create, add, remove, rename, promote) is hybrid signed; ops carry member
  cards, so members who are not contacts get added as unverified contacts when keys flow. Group
  messages carry an 8-byte sender key id and are Ed25519 signed with a per-chain key. A group
  envelope that arrives before its sender key: `open` returns `None` (group unknown) or
  `Err(NoSession)` (group known, key not yet): keep it and retry after the next successful
  `open`, it is not marked as seen. Key and op deliveries come out of `open` as an InboundJson
  whose message is a synthetic AppMessage `{"kind":"group-op","group":{"id","event":"key" |
  "update" | "removed","name","members","admins"}}`. `leave_group` is local only.
- Channels: AES-GCM under HKDF(name [+ Argon2id(password)]), Ed25519 signed, 30 messages per
  minute per sender key. `from` is the claimed fingerprint; it is checked only for contacts.
- Frames: `ver(1)=1 || hops_left(1) || id(16) || index(u16 BE) || count(u16 BE) || payload`
  (22-byte header). The frame id is the envelope id and `hops_left` starts at the envelope ttl.
- wasm size: 772 KiB, 267 KiB gzip (opt-level s, wasm-opt -Oz).
