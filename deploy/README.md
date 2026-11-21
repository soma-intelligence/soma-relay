# Hosting a Soma Relay node

A node is optional. Soma Relay works phone to phone over Bluetooth and Wi-Fi without one.
A node adds an Internet mailbox (messages wait up to 14 days for an offline contact), a
handle directory (`ines@your-node`), an attachment store, a STUN/TURN list for calls and a
copy of the web client. It only ever holds ciphertext and public contact cards.

The wire protocol is in [`docs/node-protocol.md`](../docs/node-protocol.md).

## Quick start with Docker

From this `deploy/` directory:

```sh
docker compose up -d --build
curl http://localhost:8080/healthz
```

Data (SQLite database and blobs) lives in the `relay-data` volume, mounted at `/data`.

To serve the web client too, build it before the image so `web/dist` exists:

```sh
(cd ../web && pnpm install && pnpm build)
docker compose up -d --build
```

Multi-arch image (linux/amd64 and linux/arm64, for a VPS or a Raspberry Pi):

```sh
cd ..
docker buildx build -f deploy/Dockerfile --platform linux/amd64,linux/arm64 \
  -t <registry>/soma-relay-node:latest --push .
```

## Without Docker

```sh
cargo build --release -p relay-node
./target/release/relay-node --listen 0.0.0.0:8080 --data-dir /var/lib/soma-relay \
  --web-dir ./web/dist --public-url https://relay.example.org
```

## Settings

Every flag has an environment variable. Flags win over the environment.

| variable | flag | default | meaning |
|----------|------|---------|---------|
| `RELAY_LISTEN` | `--listen` | `0.0.0.0:8080` | address and port to listen on |
| `RELAY_DATA_DIR` | `--data-dir` | `./relay-data` (`/data` in Docker) | SQLite database and blobs |
| `RELAY_PUBLIC_URL` | `--public-url` | none | public base URL, shown by `/healthz` |
| `RELAY_WEB_DIR` | `--web-dir` | `./web/dist` (`/app/web` in Docker) | web client served at `/` |
| `RELAY_ICE_JSON` | `--ice-json` | Google and Cloudflare public STUN | ICE servers returned by `/v1/ice` |
| `RELAY_TRUST_PROXY` | `--trust-proxy` | `false` | take the client IP from `X-Forwarded-For` (set it behind Caddy or nginx, never when exposed directly) |
| `RELAY_RATE_PER_SEC` | `--rate-per-sec` | `20` | HTTP requests per second per IP, `0` disables |
| `RELAY_RATE_BURST` | `--rate-burst` | `100` | HTTP burst per IP |
| `RELAY_LOG` | | `relay_node=info` | log filter (`tracing` syntax). Nothing logged includes message content. |

Fixed limits: 2 MiB per envelope, 50 MiB queued per mailbox, 100 MiB per blob, 14 day
retention for envelopes and blobs, 5 handles per mailbox.

The node stops cleanly on `SIGTERM` or Ctrl-C: it closes WebSocket connections (clients
reconnect on their own) and finishes in-flight requests.

## TLS with Caddy

Clients need `https://` and `wss://`. The simplest way is Caddy, which gets certificates on
its own. Point the DNS name at the machine, open ports 80 and 443, then:

```sh
RELAY_HOST=relay.example.org RELAY_PUBLIC_URL=https://relay.example.org \
RELAY_TRUST_PROXY=true docker compose --profile tls up -d --build
```

The bundled [`Caddyfile`](Caddyfile) is all it takes:

```
{$RELAY_HOST:relay.example.org} {
	encode zstd gzip
	reverse_proxy relay-node:8080
}
```

Caddy proxies WebSocket upgrades without extra settings. With Caddy in front you can stop
publishing port 8080 (remove the `ports` entry of `relay-node`). Keep
`RELAY_TRUST_PROXY=true` only when every request goes through the proxy, otherwise clients
could fake their IP and dodge the rate limits.

With nginx, forward the upgrade headers on `/v1/ws` (`proxy_http_version 1.1`,
`Upgrade` and `Connection "upgrade"`) and raise `client_max_body_size` to `100m` for blobs.

## Calls through TURN (optional)

Most calls connect peer to peer with STUN. Phones behind strict NATs need a TURN relay.
coturn is included as an optional profile:

```sh
cp turnserver.conf.example turnserver.conf     # set realm, user, external-ip
docker compose --profile turn up -d
```

coturn runs with host networking (it needs a range of UDP ports: 3478, 5349 and
49160-49200 in the example; open them in the firewall). Then advertise it through the node:

```sh
RELAY_ICE_JSON='[
  {"urls":["stun:relay.example.org:3478"]},
  {"urls":["turn:relay.example.org:3478?transport=udp","turn:relay.example.org:3478?transport=tcp"],
   "username":"relay","credential":"CHANGE_ME"}
]' docker compose up -d
```

`RELAY_ICE_JSON` takes an array of `RTCIceServer` objects (or an object with an `iceServers`
key). Whatever you put there is public: every client reads it from `/v1/ice`. Calls stay
end-to-end encrypted through TURN; the relay only sees encrypted media.

## Backups and privacy

- Back up the data volume (`relay.sqlite3` plus the `blobs/` directory) if you care about
  queued messages surviving a disk loss. Everything in it is ciphertext or public cards,
  and it expires within 14 days anyway.
- The node keeps no access log and logs no content. Your reverse proxy might: turn off its
  access log (Caddy does not log requests unless you add a `log` directive).
- A mailbox is bound to the first device key that authenticates for it (trust on first
  use). Losing the data volume resets those bindings and the handle directory.
