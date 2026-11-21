# Soma Relay: design (v1)

Date: 2026-11-21. Owner: Quentin Caron (Soma Labs). Status: approved direction, built autonomously.

Soma Relay is an open source messenger that keeps working when the Internet and the cell
network are down. Messages, voice notes, photos, video and files travel over a Bluetooth and
peer-to-peer Wi-Fi mesh between nearby phones, over the Internet through optional,
self-hostable nodes, and, as a last resort, as an encrypted SMS. Audio and video calls run
peer to peer. Everything is end-to-end encrypted with hybrid post-quantum cryptography
(X25519 + ML-KEM-1024, Ed25519 + ML-DSA-87), the same family as OnePass.

## 1. Owner decisions (from the brainstorm)

- Public open source product, AGPL-3.0-or-later, repo `soma-intelligence/soma-relay`.
- Platforms: iOS first (store), then macOS and Android. A web client exists for testing and
  for people without the app.
- Look: direction E ("Verre + Radar"): native glass bars, system font, bubble colour = transport
  (mesh green, Internet blue), a collapsible "path" card with a mini radar and the hop chain,
  mono metadata (`MESH 2 · LU`), pending messages drawn dashed. Light and dark.
- Network: no central server. Bluetooth mesh + local Wi-Fi P2P + Internet P2P, plus optional
  nodes anyone can host (rendezvous, blind relay, store-and-forward mailbox, directory, push).
- v1 scope: 1:1 chat, private groups, local public channels, voice notes, photos (compressed),
  video, files, audio and video calls, contacts directory, QR add with the OnePass-style
  cipher animation, bots through an HTTP API, encrypted SMS fallback. Money: later.
- Identity: key + QR, plus an optional handle directory on nodes (`ines@node`). No phone
  number, no e-mail.
- Build approach A: one Rust core (crypto, sessions, groups, envelopes, mesh routing) shared by
  every client through UniFFI (Swift, Kotlin) and wasm-bindgen (web). Native code only for
  radios, media and UI.

## 2. Repository layout

```
crates/relay-core   pure Rust, sans-IO, wasm-compatible: identity, sessions, groups,
                    envelopes, fragmentation, mesh router, app message schema
crates/relay-ffi    UniFFI wrapper -> RelayCoreFFI.xcframework + Swift bindings
crates/relay-wasm   wasm-bindgen wrapper -> web/src/core/pkg
crates/relay-node   optional node: WebSocket mailbox + rendezvous + directory + serves web/dist
crates/relay-bot    bot runtime: holds an identity, exposes a local REST API
web/                Vite + React + TypeScript client (design E), WebRTC calls
apple/              SwiftUI iOS app (xcodegen), MultipeerConnectivity mesh, WebRTC calls
docs/               specs, research, protocol
```

## 3. Cryptography (relay-core)

Pure Rust crates only, so the same code compiles for iOS, Android and wasm32:
`libcrux-ml-kem` (ML-KEM-1024), `libcrux-ml-dsa` (ML-DSA-87), `x25519-dalek`,
`ed25519-dalek`, `aes-gcm` (AES-256-GCM), `hkdf` + `sha2` (HKDF-SHA256), `sha3`,
`getrandom` (with the `js` / wasm_js backend on wasm), `zeroize`, `postcard` + `serde`.

### 3.1 Identity
- Identity signing key = Ed25519 + ML-DSA-87. A hybrid signature is the pair; it verifies only
  if both verify.
- Device keys: X25519 static + ML-KEM-1024 static, signed by the identity.
- Signed prekey (X25519 + ML-KEM-1024), rotated weekly, signed by the identity. v1 publishes no
  one-time prekeys (keeps the card small enough for a QR); replay of a first message is caught
  by the receiver's message-id cache.
- Fingerprint = SHA3-256(ed25519_pub || mldsa_pub). Shown as: 4 French words (from a fixed
  2048-word list in the core), grouped hex `4F2A·91C0·77DE·...`, and the QR.
- Contact card (`ContactCard`): display name, identity public keys, device public keys, signed
  prekey, optional node URL + handle, created_at, hybrid signature over all of it. Text form
  `relay1:` + base64url(postcard). A full card (with ML-DSA and ML-KEM keys) is about 6-7 KB.
  Compact link form for QR: `relay1c:` + base64url(fingerprint 32 B + node URL + handle),
  the full card is then fetched from the node or the mesh and checked against the fingerprint.
  The QR shows the full card when it fits (QR version 40, binary, low ECC: 2953 bytes is too
  small), so the QR carries the compact form plus, when the peer is in mesh range, the full card
  is exchanged over the mesh. Both forms are accepted everywhere.

### 3.2 Sessions (1:1, per device pair)
- Opening (PQXDH-like, asynchronous): initiator A, responder B with signed prekey SPK_B.
  `dh1 = X25519(IK_A_dev, SPK_B)`, `dh2 = X25519(EK_A, IK_B_dev)`, `dh3 = X25519(EK_A, SPK_B)`,
  `(ct, ss) = ML-KEM-1024.Encaps(SPK_B_kem)`,
  `root = HKDF-SHA256(salt = 0, ikm = 0xFF*32 || dh1 || dh2 || dh3 || ss, info = "soma-relay/v1/x3dh" || transcript_hash)`.
  The first message carries EK_A, ct, the ids of the keys used, and a hybrid signature by A's
  identity over the transcript hash, so authentication is post-quantum too.
- Then a Double Ratchet (X25519 DH ratchet, HKDF chains, AES-256-GCM, encrypted header
  not required in v1) with a **post-quantum ratchet step**: each time the sending direction
  changes and at least 50 messages or 24 hours passed since the last PQ step, the sender
  includes a fresh ML-KEM-1024 encapsulation to the peer's current ratchet KEM key, and the
  shared secret is mixed into the root key. This gives post-compromise security against a
  quantum adversary at bounded cost on the mesh.
- Skipped message keys: at most 2000 per session, dropped after 7 days.
- Sealed sender: the sender identity is inside the ciphertext; the outer envelope only carries
  a routing tag.

### 3.3 Groups
- Sender keys: each member keeps a chain key per group, distributed through 1:1 sessions.
  A group message is encrypted once (AES-256-GCM, chain ratchet per message) and signed with
  the sender's Ed25519 device key.
- Group state = a log of signed operations (create, add, remove, rename, promote) with Lamport
  clock + previous hash; concurrent ops merge deterministically (Lamport, then hash).
- Removing a member rotates every remaining member's sender key. Weekly rotation otherwise.

### 3.4 Local public channels
- Name-based (`#festival`), open to anyone in mesh range. Not end-to-end encrypted (the UI says
  so). Signed with Ed25519 only (ML-DSA is too large per broadcast). Optional password ->
  Argon2id is too slow for wasm per message, so key = HKDF(Argon2id(password, channel name))
  computed once on join.
- Rate limit per sender, ephemeral (not stored by default).

## 4. Envelope and wire format

```
Envelope (postcard) {
  v: u8 = 1,
  kind: u8,            // 1 = direct, 2 = group, 3 = channel, 4 = announce, 5 = receipt-free control
  tag: [u8; 16],       // routing: mailbox id (node) or rotating mesh tag
  ttl: u8,             // mesh hops left, starts at 7
  id: [u8; 16],        // random message id, for dedup
  body: Vec<u8>,       // ciphertext, padded to 256 / 1 KiB / 4 KiB / 16 KiB / 64 KiB / n*64 KiB
}
```

- Mailbox id (node delivery) = first 16 bytes of SHA3-256("soma-relay/mailbox" || fingerprint).
- Mesh tag = HKDF(session root, "mesh-tag" || unix_hour) first 16 bytes; contacts precompute the
  current and previous hour; strangers see random-looking tags. Announces use a random
  ephemeral id that rotates every 15 minutes.
- Fragmentation: `fragment(envelope_bytes, mtu) -> Vec<frame>`; frame header = id (16) + index
  (u16) + count (u16). Reassembler caps: 128 assemblies, 30 s timeout, 1 MiB per message.
- Mesh router: dedup LRU (4096 ids, 10 min), TTL decrement, never send back on the ingress link,
  random 10-120 ms jitter is the transport's job (the core returns the frames to forward).

## 5. App message schema (shared by every client)

`AppMessage` (postcard inside the ciphertext, JSON in the FFI/wasm boundary):

```
{ id: string (uuid v7), ts: i64 ms, kind: "text" | "image" | "audio" | "video" | "file"
  | "receipt" | "typing" | "call" | "reaction" | "group-op" | "profile",
  text?: string, reply_to?: string,
  attachment?: { mime, size, sha256, key (base64, 32 B), name?, width?, height?,
                 duration_ms?, thumb? (base64 tiny JPEG/HEIC, <= 4 KiB), inline? (base64 when
                 the encrypted file is <= 48 KiB) , url? (node blob url) },
  receipt?: { of: [ids], state: "delivered" | "read" },
  call?: { call_id, action: "offer" | "answer" | "ice" | "end" | "decline" | "busy",
           sdp?, candidate?, video: bool },
  group?: { ... } }
```

Attachments: encrypted with AES-256-GCM in 64 KiB chunks (nonce = chunk index, AAD = sha256 of
plaintext + index + last flag), uploaded to the node (`PUT /v1/blobs/{sha}`) or sent over the
mesh/data channel in frames. BLE cap 512 KiB per attachment; larger files wait for Wi-Fi P2P or
the Internet.

Media encoding (clients):
- Photos: longest side 2048 px, HEIC on Apple (quality 0.6), WebP/AVIF on web (quality 0.7),
  JPEG fallback. Thumbnail 64 px for instant preview.
- Voice notes: AAC-LC/HE 32 kbps mono in m4a (plays everywhere), Opus when both ends support it.
- Video: HEVC (Apple) / H.264 fallback, 720p, ~1.5 Mbps; capped by size.

## 6. Transports

The client keeps one `Router`: it tries, in order, an open P2P link (mesh peer or WebRTC data
channel), the node mailbox, then queues (courier) and offers SMS.

- Multipeer mesh (iOS v1): MultipeerConnectivity uses Bluetooth and peer-to-peer Wi-Fi with no
  Internet. Every app instance advertises and browses service `soma-relay`, connects to up to 8
  peers, and runs the core mesh router over those links (multi-hop flooding with TTL).
  A raw CoreBluetooth GATT mesh (for Android interop and background) is phase 2.
- Node (optional, self-hostable): WebSocket `wss://<node>/v1/ws`.
- WebRTC data channel P2P between online peers after a signalling exchange through any
  transport.
- Encrypted SMS (iOS): when nothing else works, the app opens the SMS composer prefilled with
  `https://relay.somalabs.me/m#<base64url envelope>` (or `somarelay://m/...`); the receiver
  taps the link and the app ingests it. Text only, size-limited (one envelope <= 1 KiB padded).
  iOS never lets an app send SMS silently, so the user taps Send.

## 7. Node protocol (relay-node)

WebSocket JSON frames, binary envelopes base64url:

- Client -> node `{"t":"hello","mailbox":hex16,"pub":b64(ed25519 device pub)}`;
  node -> client `{"t":"challenge","nonce":b64(32)}`;
  client -> node `{"t":"auth","sig":b64(ed25519 sig over "soma-relay/node-auth/v1" || nonce || mailbox)}`.
  The node checks the mailbox is SHA3 of the identity fingerprint registered with that key
  (first auth registers: mailbox -> fingerprint + key, trust on first use; the card must be
  posted with `{"t":"register","card":b64}` and its hybrid signature is verified by the node).
- `{"t":"send","to":hex16,"env":b64}` -> stored if offline (14 days, 50 MiB per mailbox), pushed
  live if online `{"t":"env","env":b64}`. Client acks `{"t":"ack","id":hex16}`.
- `{"t":"presence","mailboxes":[...]}` -> `{"t":"presence","online":[...]}` (contacts only;
  the node learns nothing it does not already route).
- HTTP: `GET /v1/cards/{mailbox}`, `PUT /v1/directory/{handle}` (signed card),
  `GET /v1/directory/{handle}`, `PUT/GET /v1/blobs/{sha256}` (encrypted, 100 MiB max, 14 days),
  `GET /v1/ice` (STUN/TURN list), `GET /healthz`. Serves `web/dist` at `/`.
- No logs of content; access logs off by default.

## 8. Bots (relay-bot)

`relay-bot serve --node https://... --name "Weather" --listen 127.0.0.1:8787` creates or loads an
identity in `./bot-identity.bin` and exposes:
- `GET /v1/card` -> its contact card (and QR PNG at `/v1/card.png`),
- `POST /v1/messages {"to": "<card | handle@node | mailbox>", "text": "..."}`,
- `GET /v1/messages?since=` and an optional `--webhook URL` POST for each incoming message.
Auth: bearer token printed on first run. A bot is a normal end-to-end encrypted contact.

## 9. Calls

WebRTC, peer to peer (STUN, TURN on the node if configured), signalling as encrypted `call`
messages through whatever transport is up. Media E2EE: SFrame-style frame encryption with a key
exported from the 1:1 session (`call_key(contact, call_id)`), on top of DTLS-SRTP, where the
platform allows it (web: RTCRtpScriptTransform / insertable streams; iOS: frame encryptor
when the WebRTC build exposes it, else DTLS-SRTP with fingerprint bound in the signed offer).
Codecs and tuning: see `docs/research/calls.md`.

## 10. Storage

Everything stays on the device. iOS: SQLite (GRDB) with message bodies sealed by AES-256-GCM
(CryptoKit, key in the Keychain, this-device-only), media files sealed, file protection
complete. Web: IndexedDB with bodies sealed by a non-extractable WebCrypto key. Core state
(identity, sessions) exported as one blob, sealed the same way.

## 11. Testing

Core: unit + property tests (out-of-order, loss, duplicates, concurrent group ops), KAT
round-trips, fuzz targets for decoders. Node: integration tests with two clients. Web: two
browser instances on one node exchange text, image and a call (Playwright or the browser pane).
iOS: simulator build, UI smoke, two simulators over Multipeer when possible.

## 12. Out of scope for v1

Money, Android app, macOS app, raw BLE GATT mesh, push notifications (needs APNs key on a node),
MLS groups, multi-device linking (one device per identity in v1).
