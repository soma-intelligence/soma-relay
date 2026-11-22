# Soma Relay

**A private messenger that keeps working when the network doesn't.**

Soma Relay is an end-to-end encrypted chat app with post-quantum cryptography. It sends messages over the Internet when there is one, over a Bluetooth and Wi-Fi mesh of nearby phones when there isn't, and as an encrypted SMS when only the cellular network is left. It does audio and video calls, photos, voice notes, files, groups and local public channels. Bots can send and receive messages through a small REST API.

There is no account and no phone number. Your identity is a key pair that lives on your device. You add people by scanning a QR code, opening a link, or looking up an optional handle on a node.

The project is inspired by [bitchat](https://github.com/permissionlesstech/bitchat) and written from scratch.

> Status: v1, iOS first, plus a web client for testing. Android and macOS clients are planned. The cryptography has not been audited yet. Do not rely on it for life-or-death situations until it has been.

## What it does

| | |
|---|---|
| Profile | A profile photo and name, shared end to end with your contacts and groups only |
| Chat | 1:1 conversations, delivery and read receipts, replies, reactions, edit, delete for everyone, forward, typing state, search |
| Media | Photos (longest side 2048 px, HEIC on iPhone, WebP or AVIF on the web), 720p video (HEVC or H.264), voice notes (AAC, Opus when both ends support it), any file up to 100 MiB on the Internet path |
| Documents | PDF, Word, PowerPoint, Excel, Keynote, Pages and more open inside the app (QuickLook on iPhone; PDF, Word, PowerPoint and spreadsheets in the browser) |
| Location | Send a pin or share your live position for 15 minutes, 1 hour or 8 hours |
| Polls | Single or multiple choice, live results, closed by their creator |
| Link previews | Built by the sender, so the person reading never fetches anything |
| Disappearing messages | 5 minutes to 1 week, per conversation |
| Notifications | Grouped per conversation, reply from the notification, mute, previews on or off. Push wakes the app without carrying any content |
| Calls | Audio and video calls, peer to peer, with an extra end-to-end encryption layer on every frame |
| Groups | Private groups with several people, a group photo, admins who add and remove members, a signed member log and @mentions |
| Channels | Public channels for people nearby (a stand, a festival, a building), with an optional password |
| Directory | Optional `name@node` handles so people can find you without a QR code |
| Bots | A bot runtime with a REST API and a webhook |
| Offline | Messages hop phone to phone over the mesh and are stored and forwarded until they arrive |
| Storage | Everything stays on your device, in an encrypted local database |

## How messages travel

Each message picks the best path that works right now:

1. **Internet.** The app talks to a node over a WebSocket. The node only sees sealed envelopes addressed to a rotating mailbox id. It stores them for up to 14 days (50 MiB per mailbox) and deletes them once delivered.
2. **Mesh.** Phones nearby connect over Bluetooth and peer-to-peer Wi-Fi (MultipeerConnectivity on iOS). Envelopes hop from phone to phone, up to 7 hops, and are carried until the recipient is in range. Strangers' phones relay what they cannot read.
3. **SMS.** When there is no data at all but there is a cellular signal, the app can put a short text message, encrypted, in a regular SMS. On iOS you tap Send yourself, because Apple does not let apps send SMS silently. The other side pastes or opens the `somarelay://` link to decrypt it.

The bubble footer always tells you which path a message took (`NET`, `MESH 2`, `SMS`) and whether it is still on its way.

## Cryptography

Soma Relay uses a hybrid design: every step combines a classical algorithm and a post-quantum one, so an attacker has to break both.

| Purpose | Algorithms |
|---|---|
| Key agreement | X25519 + ML-KEM-1024 (FIPS 203) |
| Signatures | Ed25519 + ML-DSA-87 (FIPS 204) |
| Session opening | PQXDH-style handshake with a transcript signed by both signature schemes |
| Ongoing messages | Double Ratchet with a fresh ML-KEM step every 50 messages or 24 hours |
| Encryption | AES-256-GCM, keys from HKDF-SHA256 |
| Fingerprints | SHA3-256 of both public keys |
| Safety check | 4 words from the BIP-39 French list, the same on both phones |
| Groups | Sender keys, member changes in a signed log |
| Call media | Per-frame AES-GCM on top of DTLS-SRTP, key from the chat session, rotated every 5 minutes |

Metadata protection: sealed sender (the node never learns who sent a message), padding to fixed size buckets, mailbox ids derived from keys, and an hourly rotating tag on the mesh so phones cannot be tracked by their broadcasts.

The cryptographic core is one Rust crate, [`relay-core`](crates/relay-core), shared by every client. It builds to a Swift framework (UniFFI) and to WebAssembly (wasm-bindgen). The post-quantum primitives come from [libcrux](https://github.com/cryspen/libcrux), which is formally verified.

Full details: [docs/specs/2026-11-21-soma-relay-design.md](docs/specs/2026-11-21-soma-relay-design.md) and [docs/specs/2026-11-21-v1.1-messaging.md](docs/specs/2026-11-21-v1.1-messaging.md).

## Calls

Calls are peer to peer with WebRTC. The node only helps the two phones find each other. The choices come from recent work on real-time media and are explained in [docs/research/calls.md](docs/research/calls.md):

- Voice: Opus at 32 kbit/s with in-band forward error correction and discontinuous transmission.
- Video: hardware H.264 on iPhone, AV1 with temporal layers on the web when both sides support it, then VP9, then H.264.
- Bitrate ladder capped at 1.6 Mbit/s, with a 40 ms jitter buffer target for audio and 80 ms for video.
- A second encryption layer on every frame, so even a TURN relay sees nothing.
- The four safety words show on screen during the call. If both people read the same words, nobody is in the middle.

## Repository layout

```
crates/
  relay-core/   Rust: crypto, sessions, groups, channels, envelopes, mesh routing
  relay-ffi/    UniFFI bindings for Swift
  relay-wasm/   wasm-bindgen bindings for the web
  relay-node/   Node: WebSocket mailbox, blobs, directory, ICE config, serves the web client
  relay-bot/    Bot runtime with a REST API
apple/          iOS app (SwiftUI, iOS 26)
web/            Web client (React 19 + Vite), used for testing and as a fallback client
deploy/         Dockerfile for the node
docs/           Design spec, core API, node protocol, call research
scripts/        Build scripts for the Swift framework and the wasm package
```

## Try it in a browser

Soma Labs runs a public test node: https://somarelay.westus2.cloudapp.azure.com. It keeps undelivered messages on disk for up to 14 days and runs a TURN server for calls.

Every node serves the web client at `/`. Open it twice with two profiles to chat with yourself:

```
https://<node>/?profile=a
https://<node>/?profile=b
```

Each profile has its own identity in IndexedDB. Copy the link from one profile's "My card" screen and paste it in the other, or scan the QR code with a phone running the iOS app.

## Run your own node

Anyone can run a node. Clients can use several and switch freely.

```bash
docker build -f deploy/Dockerfile -t soma-relay-node .
docker run -p 8080:8080 -v relay-data:/data soma-relay-node
```

Or from source:

```bash
cargo run --release -p relay-node
```

Settings (flags or environment variables):

| Variable | Default | Meaning |
|---|---|---|
| `RELAY_LISTEN` | `0.0.0.0:8080` | Address to listen on |
| `RELAY_DATA_DIR` | `./relay-data` | SQLite database and blobs |
| `RELAY_PUBLIC_URL` | | Public URL, used in handles |
| `RELAY_WEB_DIR` | `./web/dist` | Web client to serve at `/` |
| `RELAY_ICE_JSON` | | STUN/TURN servers handed to clients for calls |
| `RELAY_TRUST_PROXY` | `false` | Trust `X-Forwarded-For` behind a reverse proxy |
| `RELAY_RATE_PER_SEC`, `RELAY_RATE_BURST` | `20`, `100` | Per-connection rate limit |
| `RELAY_PREVIEW` | `true` | Serve `GET /v1/preview` (link previews for web clients) |
| `RELAY_APNS_KEY_P8` | | APNs `.p8` key, PEM text or file path. APNs is on only when all four `RELAY_APNS_*` are set |
| `RELAY_APNS_KEY_ID` | | APNs key id |
| `RELAY_APNS_TEAM_ID` | | Apple developer team id |
| `RELAY_APNS_TOPIC` | | iOS app bundle id |
| `RELAY_TURN_SECRET` | | coturn `static-auth-secret`. With `RELAY_TURN_URLS`, `/v1/ice` hands out TURN credentials valid for `RELAY_TURN_TTL` |
| `RELAY_TURN_URLS` | | Comma separated `turn:` and `turns:` URLs |
| `RELAY_TURN_TTL` | `86400` | Lifetime of TURN credentials, in seconds |

Web Push needs no setup: the node creates its VAPID key in `<data dir>/vapid.pem` on first start. Back it up with the database, because a new key breaks every browser subscription.

The protocol is documented in [docs/node-protocol.md](docs/node-protocol.md). A node cannot read messages, cannot tell who sent them, and forgets them once they are delivered.

## Bots

A bot is a normal Soma Relay identity that runs on a server and exposes a local REST API.

```bash
cargo run --release -p relay-bot -- serve \
  --node https://relay.example.org \
  --name "Weather bot" \
  --handle weather \
  --webhook https://my-server.example.org/hook
```

On first start it prints its fingerprint, its link and an API token (shown once). People add the bot by scanning `GET /v1/card.png` or opening its link.

Send a message:

```bash
curl -X POST http://127.0.0.1:8787/v1/messages \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"to": "ines@relay.example.org", "text": "Rain expected at 4 pm."}'
```

`to` accepts a handle, a `relay1c:` link, a full `relay1:` card, a mailbox or a fingerprint. Read incoming messages with `GET /v1/messages?since=<seq>`, or set `--webhook` to receive each one as a JSON POST.

## Build from source

Requirements: Rust (stable), Node 22 with pnpm, Xcode 26 and [XcodeGen](https://github.com/yonaskolb/XcodeGen) for iOS.

```bash
cargo test --workspace                 # core, node and bot tests
./scripts/build-wasm.sh                # wasm package for the web client
cd web && pnpm install && pnpm build   # web client in web/dist
./scripts/build-xcframework.sh         # RelayCore.xcframework for iOS
cd apple && xcodegen && open SomaRelay.xcodeproj
```

The web end-to-end tests (`cd web && pnpm e2e`) start a local node and run two browser profiles against it.

## Limits

- The iOS app needs you to tap Send for SMS. That is an Apple rule.
- MultipeerConnectivity is the iOS mesh today. A raw Bluetooth LE transport (compatible across platforms) is planned.
- Push notifications never carry content: they only wake the app, which then fetches and decrypts.
- The browser PowerPoint viewer draws text, pictures, shapes and tables. Charts, SmartArt and animations are skipped.
- One device per identity for now. Multi-device is planned.
- Payments are out of scope for v1.

## Privacy

No account, no analytics, messages stored only on your device. Full policy: [PRIVACY.md](PRIVACY.md).

## License

[AGPL-3.0-or-later](LICENSE). If you run a modified node for others, you share your changes.

Made by [Soma Labs](https://somalabs.me).
