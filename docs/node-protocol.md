# Soma Relay node protocol (v1)

This document describes the wire protocol of a Soma Relay node (`crates/relay-node`) for
anyone writing a client, a bot or another node implementation. A node is optional and
untrusted: it stores and forwards opaque envelopes, keeps a handle directory and a blob
store, and never sees plaintext. Everything it holds is end-to-end encrypted by the clients
or is public (contact cards).

Base URL examples below use `https://relay.example.org`. Every API path starts with `/v1`.

## Conventions

- **hex16**: 16 bytes as 32 lowercase hex characters. Used for mailbox ids and envelope ids.
  The node accepts upper case on input and always writes lower case.
- **b64**: base64url without padding (RFC 4648 section 5) on output. On input the node also
  accepts padding and the standard alphabet (`+`, `/`).
- **Mailbox id**: first 16 bytes of `SHA3-256("soma-relay/mailbox" || fingerprint)`, where
  `fingerprint = SHA3-256(ed25519_identity_pub || mldsa87_identity_pub)` (32 bytes).
- **Envelope**: the postcard encoding of the core `Envelope` struct. The node reads only the
  envelope id; the rest is opaque. Layout of a v1 envelope:

  | offset | size | field |
  |--------|------|-------|
  | 0      | 1    | `v` = 1 |
  | 1      | 1    | `kind` (1 direct, 2 group, 3 channel, 4 announce, 5 control) |
  | 2      | 16   | `tag` |
  | 18     | 1    | `ttl` |
  | 19     | 16   | `id` (random, used for dedup and `ack`) |
  | 35     | ...  | `body` (varint length, then ciphertext) |

  The node rejects a `send` whose bytes do not start with `v = 1` or are shorter than 35
  bytes (`malformed`).

## Limits

| item | limit |
|------|-------|
| envelope in a `send` frame | 2 MiB (use a blob for bigger payloads) |
| WebSocket text frame | 4 MiB |
| queued envelopes per mailbox | 50 MiB in total |
| envelope and blob retention | 14 days, then deleted |
| blob size | 100 MiB |
| contact card | 64 KiB |
| handles per mailbox | 5 |
| presence query | 512 mailboxes (extra entries are ignored) |
| WebSocket frames per connection | 50 per second, burst 200 |
| HTTP requests per client IP | default 20 per second, burst 100 (node setting) |
| auth deadline | `hello` + `auth` within 30 s of connecting |

## WebSocket: `GET /v1/ws`

`wss://relay.example.org/v1/ws`. Every message is a UTF-8 text frame holding one JSON object
with a string field `t` (the frame type). Binary frames are answered with `bad_frame`.
Unknown fields are ignored; unknown frame types are answered with `bad_frame`. The node
sends WebSocket pings every 30 s; clients that cannot answer protocol pings (browsers do
automatically) may also send `{"t":"ping"}` and get `{"t":"pong"}`.

### 1. Authentication

```
client -> {"t":"hello","mailbox":"<hex16>","pub":"<b64 Ed25519 public key, 32 bytes>"}
node   -> {"t":"challenge","nonce":"<b64, 32 random bytes>"}
client -> {"t":"auth","sig":"<b64 Ed25519 signature, 64 bytes>"}
node   -> {"t":"ready","mailbox":"<hex16>","card":<bool>}
```

The signature is computed over the byte string

```
"soma-relay/node-auth/v1" || nonce (32 bytes) || mailbox (16 raw bytes)
```

with the device Ed25519 key (relay-core: `sign_node_challenge(nonce)`, key from
`device_signing_public()`).

**Trust on first use.** The first successful auth for a mailbox binds it to that public key.
Later auths for the same mailbox with any other key fail with `key_mismatch` and the socket
is closed. A wrong signature fails with `bad_signature` and the socket is closed. A client
that does not finish within 30 s gets `auth_timeout` and is closed.

`ready.card` tells whether a card is already registered for this mailbox.

Right after `ready`, the node sends every envelope queued for the mailbox, oldest first, as
`env` frames (see below). Several connections may authenticate to the same mailbox (for
example two browser tabs); each receives live pushes.

### 2. Card registration

```
client -> {"t":"register","card":"<b64 card bytes>"}
node   -> {"t":"registered"}
```

The card is the client's contact card, usually the UTF-8 bytes of the `relay1:...` text form.
It becomes public at `GET /v1/cards/{mailbox}`. Registering again replaces it (for example
after a prekey rotation). Cards pass through the node's card verifier: a node may refuse a
card whose hybrid signature does not verify or that does not hash to the mailbox
(`card_rejected`). Requires auth.

### 3. Sending

```
client -> {"t":"send","to":"<hex16 recipient mailbox>","env":"<b64 envelope>"}
node   -> {"t":"sent","id":"<hex16 envelope id>"}
       or {"t":"sent","id":"<hex16>","dup":true}          (already queued for that mailbox)
       or {"t":"error","code":"quota","msg":"...","id":"<hex16>"}
       or {"t":"error","code":"too_large","msg":"...","id":"<hex16>"}
```

The node stores the envelope in the recipient's mailbox (keyed by recipient and envelope id,
so a resend is a no-op) and pushes it at once to every live connection of the recipient.
A group message is sent once per member mailbox with the same envelope. Requires auth.
The recipient mailbox does not need to be known to the node.

### 4. Receiving and acknowledging

```
node   -> {"t":"env","id":"<hex16 envelope id>","env":"<b64 envelope>"}
client -> {"t":"ack","id":"<hex16 envelope id>"}
```

Delivery is **at least once**: an envelope stays queued until the recipient acks it or it
expires after 14 days, and it is sent again on every new authentication. Clients must
deduplicate by envelope id (relay-core `open` does) and should ack every envelope they have
durably processed, including ones they could not open, so a bad envelope cannot stay queued.
`ack` has no reply. Only the mailbox owner can ack its envelopes.

If a connection falls more than 1024 frames behind on live pushes, the node closes it; the
envelopes are still queued and are delivered on reconnect.

### 5. Presence

```
client -> {"t":"presence","mailboxes":["<hex16>", ...]}
node   -> {"t":"presence","online":["<hex16>", ...]}
```

`online` is the subset of the asked mailboxes that have at least one authenticated
connection right now. Clients should only ask about their contacts. Requires auth.

### 6. Errors

```
{"t":"error","code":"<code>","msg":"<human readable>"[,"id":"<hex16>"]}
```

| code | meaning | socket |
|------|---------|--------|
| `bad_frame` | unparsable JSON, unknown `t`, bad field encoding, binary frame | stays open |
| `bad_state` | `hello` twice, or `auth` before `hello` | stays open |
| `auth_required` | `register`, `send`, `ack` or `presence` before `ready` | stays open |
| `bad_signature` | challenge signature does not verify | closed |
| `key_mismatch` | mailbox already bound to another key | closed |
| `auth_timeout` | no successful auth within 30 s | closed |
| `card_rejected` | card refused by the node's card verifier | stays open |
| `malformed` | `env` is not a v1 envelope | stays open |
| `too_large` | envelope over 2 MiB | stays open |
| `quota` | recipient mailbox over 50 MiB | stays open |
| `rate_limited` | more than the frame budget; the frame was dropped | stays open |
| `internal` | storage failure on the node | depends |

When the node shuts down it closes every socket with code 1000 and reason
`node shutting down`. Clients reconnect with backoff (for example 1 s doubling to 30 s).

## HTTP API

All API responses carry permissive CORS headers (`Access-Control-Allow-Origin: *`), so a web
client served from any origin can use any node. Errors are JSON:
`{"error":"<code>","msg":"<human readable>"}`. Requests over the per-IP budget get `429` with
`Retry-After: 1`.

### `GET /v1/cards/{mailbox}`

The card registered for the mailbox with the `register` frame.

- `200`: body is the card bytes (`text/plain; charset=utf-8` when they are UTF-8, otherwise
  `application/octet-stream`), header `X-Relay-Mailbox: <hex16>`.
- `404 not_found`: unknown mailbox or no card registered. `400 bad_mailbox`.

Clients must verify the card (hybrid signature, and that it hashes to the mailbox or the
fingerprint they expected) before trusting it. The node is not trusted.

### `PUT /v1/directory/{handle}` and `GET /v1/directory/{handle}`

A first-come handle directory, so people can share `ines@relay.example.org`.

Handle rule: 3 to 32 characters from `[a-z0-9_.-]` (lower case only). The full address
`handle@host` names the node that holds it.

PUT body: the card bytes. Headers:

- `X-Relay-Mailbox: <hex16>`: the mailbox claiming the handle. It must have authenticated
  over `/v1/ws` at least once (so the node knows its bound key).
- `X-Relay-Sig: <b64 Ed25519 signature>`: signature of the exact body bytes by the key
  bound to that mailbox.

Responses:

- `201`: handle created, `{"handle","mailbox"}`.
- `200`: the same mailbox updated its card.
- `409 handle_taken`: the handle belongs to another mailbox.
- `409 too_many_handles`: the mailbox already holds 5 handles.
- `403 unknown_mailbox`: the mailbox never authenticated on this node.
- `403 bad_signature`: the signature does not match the bound key.
- `400 bad_handle`, `400 bad_mailbox`, `400 bad_signature` (missing or badly encoded header).
- `422 card_rejected`: refused by the node's card verifier.

GET returns the card bytes with `X-Relay-Mailbox`, or `404`. As with `/v1/cards`, verify the
card on the client.

### `PUT /v1/blobs/{sha256}` and `GET /v1/blobs/{sha256}`

Encrypted attachments (the client encrypts before upload, see the design spec section 5).
`{sha256}` is the lowercase hex SHA-256 of the **uploaded bytes** (the ciphertext).

- PUT body: raw bytes, at most 100 MiB. The node hashes the stream and refuses the upload
  when the digest differs from the path (`400 hash_mismatch`, nothing stored). `413
  too_large` over 100 MiB. `201` on success: `{"sha256","size","expires_at"}` (ms since
  epoch). Uploading the same blob again refreshes its 14 day expiry.
- GET: `200` with the bytes (`application/octet-stream`), `404` when unknown or expired,
  `400 bad_hash` when the path is not 64 lowercase hex characters.

Blobs need no authentication: the hash is the capability, the content is ciphertext.

### `GET /v1/ice`

ICE servers for WebRTC calls, ready to pass to `new RTCPeerConnection({ iceServers })`:

```json
{"iceServers":[{"urls":["stun:stun.l.google.com:19302","stun:stun1.l.google.com:19302"]},
               {"urls":["stun:stun.cloudflare.com:3478"]}]}
```

The operator sets the list with `RELAY_ICE_JSON` (for example to add a TURN server with
credentials); see `deploy/README.md`.

### `GET /healthz`

`{"ok":true,"version":"0.1.0","public_url":"https://relay.example.org"}`.

### Static web client

Every other path serves the built web client from the node's web directory, with
`index.html` as the fallback for client-side routes. Unknown `/v1/...` paths return a JSON
`404 not_found` instead.

## Privacy notes

- The node logs no message content, no envelope bytes and no access log by default.
- It learns which mailboxes exchange envelopes, their sizes and timing, and the IP
  addresses of connected clients. Sealed sender means it does not learn the sender
  identity from the envelope itself, only from the authenticated connection that sent it.
- Presence answers reveal only whether mailboxes the client already knows are online.
