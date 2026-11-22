// NodeClient: the node WebSocket protocol (spec section 7) plus its HTTP API.
//
// hello -> challenge -> auth -> ready, then register (card), send / env / ack, presence.
// Reconnects with exponential backoff and jitter (1 s to 30 s), pings every 25 s.

import { fromB64, toB64Url, utf8 } from '../lib/bytes'
import type { Engine } from '../core/engine'

export type NodeEvent =
  | { t: 'state'; state: 'connecting' | 'online' | 'offline' }
  | { t: 'env'; id: string; env: Uint8Array }
  | { t: 'sent'; id: string }
  | { t: 'error'; code: string; msg: string; id?: string }
  | { t: 'presence'; online: string[] }

export function resolveNodeUrl(configured: string): string {
  const raw = configured.trim()
  if (!raw) return location.origin
  return raw.replace(/\/+$/, '')
}

function wsUrl(base: string): string {
  const u = new URL('/v1/ws', base)
  u.protocol = u.protocol === 'https:' ? 'wss:' : 'ws:'
  return u.toString()
}

export class NodeClient {
  private ws: WebSocket | null = null
  private attempt = 0
  private timer: ReturnType<typeof setTimeout> | null = null
  private pingTimer: ReturnType<typeof setInterval> | null = null
  private stopped = false
  private ready = false
  /** Push registration (spec v1.1 section 2), re-sent after every `ready`. */
  private pushFrame: Record<string, unknown> | null = null
  readonly base: string

  constructor(
    nodeUrl: string,
    private engine: Engine,
    private card: () => string,
    private onEvent: (e: NodeEvent) => void,
  ) {
    this.base = resolveNodeUrl(nodeUrl)
  }

  get isReady(): boolean {
    return this.ready
  }

  start() {
    this.stopped = false
    this.connect()
    window.addEventListener('online', this.onOnline)
  }

  stop() {
    this.stopped = true
    window.removeEventListener('online', this.onOnline)
    if (this.timer) clearTimeout(this.timer)
    if (this.pingTimer) clearInterval(this.pingTimer)
    this.ws?.close()
    this.ws = null
    this.ready = false
  }

  private onOnline = () => {
    if (!this.ready) {
      this.attempt = 0
      if (this.timer) clearTimeout(this.timer)
      this.connect()
    }
  }

  private connect() {
    if (this.stopped) return
    this.onEvent({ t: 'state', state: 'connecting' })
    let ws: WebSocket
    try {
      ws = new WebSocket(wsUrl(this.base))
    } catch {
      this.scheduleReconnect()
      return
    }
    this.ws = ws
    ws.onopen = () => {
      ws.send(
        JSON.stringify({
          t: 'hello',
          mailbox: this.engine.mailboxHex(),
          pub: toB64Url(this.engine.deviceSigningPublic()),
        }),
      )
    }
    ws.onmessage = (ev) => {
      if (typeof ev.data !== 'string') return
      let f: Record<string, unknown>
      try {
        f = JSON.parse(ev.data) as Record<string, unknown>
      } catch {
        return
      }
      this.handle(f)
    }
    ws.onclose = () => {
      if (this.ws !== ws) return
      this.ready = false
      this.ws = null
      if (this.pingTimer) clearInterval(this.pingTimer)
      this.onEvent({ t: 'state', state: 'offline' })
      this.scheduleReconnect()
    }
    ws.onerror = () => ws.close()
  }

  private scheduleReconnect() {
    if (this.stopped) return
    const base = Math.min(30_000, 1000 * 2 ** this.attempt)
    this.attempt++
    const delay = base / 2 + Math.random() * (base / 2)
    this.timer = setTimeout(() => this.connect(), delay)
  }

  private handle(f: Record<string, unknown>) {
    switch (f.t) {
      case 'challenge': {
        const sig = this.engine.signNodeChallenge(fromB64(String(f.nonce)))
        this.raw({ t: 'auth', sig: toB64Url(sig) })
        break
      }
      case 'ready': {
        this.ready = true
        this.attempt = 0
        this.raw({ t: 'register', card: toB64Url(utf8(this.card())) })
        if (this.pingTimer) clearInterval(this.pingTimer)
        this.pingTimer = setInterval(() => this.raw({ t: 'ping' }), 25_000)
        if (this.pushFrame) this.raw(this.pushFrame)
        this.onEvent({ t: 'state', state: 'online' })
        break
      }
      case 'env': {
        const env = fromB64(String(f.env))
        const id = typeof f.id === 'string' ? f.id : (this.engine.envelopeHeader(env)?.id ?? '')
        this.onEvent({ t: 'env', id, env })
        break
      }
      case 'sent':
        this.onEvent({ t: 'sent', id: String(f.id) })
        break
      case 'presence':
        this.onEvent({ t: 'presence', online: (f.online as string[]) ?? [] })
        break
      case 'push':
        // {"t":"push","ok":bool,"reason"?}: informative only.
        if (f.ok === false) console.info('push not registered on the node:', f.reason ?? 'unknown')
        break
      case 'error':
        this.onEvent({
          t: 'error',
          code: String(f.code),
          msg: String(f.msg ?? ''),
          id: typeof f.id === 'string' ? f.id : undefined,
        })
        break
    }
  }

  private raw(frame: unknown): boolean {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) return false
    this.ws.send(JSON.stringify(frame))
    return true
  }

  send(toMailbox: string, env: Uint8Array): boolean {
    if (!this.ready) return false
    return this.raw({ t: 'send', to: toMailbox, env: toB64Url(env) })
  }

  ack(id: string) {
    this.raw({ t: 'ack', id })
  }

  presence(mailboxes: string[]) {
    if (this.ready && mailboxes.length) this.raw({ t: 'presence', mailboxes })
  }

  /**
   * Registers (webpush) or removes (none) the push target of this mailbox. Kept and sent
   * again after every reconnection.
   */
  setPush(frame: { t: 'push'; kind: 'webpush'; sub: unknown } | { t: 'push'; kind: 'none' }) {
    this.pushFrame = frame.kind === 'none' ? null : frame
    if (this.ready) this.raw(frame)
  }

  /** Re-sends the card, after a rename or a new handle. */
  reregister() {
    if (this.ready) this.raw({ t: 'register', card: toB64Url(utf8(this.card())) })
  }

  // HTTP

  url(path: string): string {
    return new URL(path, this.base).toString()
  }

  async iceServers(): Promise<RTCIceServer[]> {
    try {
      const r = await fetch(this.url('/v1/ice'), { cache: 'no-store' })
      if (!r.ok) return []
      const j = (await r.json()) as RTCIceServer[] | { iceServers?: RTCIceServer[] }
      return Array.isArray(j) ? j : (j.iceServers ?? [])
    } catch {
      return []
    }
  }

  /** VAPID public key of the node (`GET /v1/push/vapid`), base64url, or null. */
  async vapidKey(): Promise<string | null> {
    try {
      const r = await fetch(this.url('/v1/push/vapid'))
      if (!r.ok) return null
      const j = (await r.json()) as { key?: unknown }
      return typeof j.key === 'string' && j.key ? j.key : null
    } catch {
      return null
    }
  }

  /** Link preview made by the node (`GET /v1/preview?url=`). Null on any failure. */
  async preview(url: string, signal?: AbortSignal): Promise<Record<string, unknown> | null> {
    try {
      const r = await fetch(this.url(`/v1/preview?url=${encodeURIComponent(url)}`), {
        signal: signal ?? AbortSignal.timeout(10_000),
      })
      if (!r.ok) return null
      const j = (await r.json()) as unknown
      return j && typeof j === 'object' ? (j as Record<string, unknown>) : null
    } catch {
      return null
    }
  }

  async putBlob(shaHex: string, data: Uint8Array): Promise<string> {
    const url = this.url(`/v1/blobs/${shaHex}`)
    const r = await fetch(url, {
      method: 'PUT',
      body: new Blob([data.slice().buffer as ArrayBuffer]),
      headers: { 'content-type': 'application/octet-stream' },
    })
    if (!r.ok && r.status !== 409) throw new Error(`blob upload failed (${r.status})`)
    return url
  }

  async lookupHandle(handle: string): Promise<string | null> {
    const r = await fetch(this.url(`/v1/directory/${encodeURIComponent(handle)}`))
    if (!r.ok) return null
    return readCard(r)
  }

  async cardByMailbox(mailbox: string): Promise<string | null> {
    const r = await fetch(this.url(`/v1/cards/${mailbox}`))
    if (!r.ok) return null
    return readCard(r)
  }

  /**
   * Publishes the card under a handle (docs/node-protocol.md): `PUT /v1/directory/{handle}`,
   * body = the card text signed by the core, `X-Relay-Mailbox` and `X-Relay-Sig` (Ed25519 by
   * the device key the node bound to this mailbox at WebSocket auth). `code` is the node's
   * error code (`handle_taken`, `too_many_handles`, `bad_signature`...).
   */
  async registerHandle(handle: string): Promise<{ ok: boolean; status: number; code: string }> {
    if (!this.engine.signDirectoryEntry) return { ok: false, status: 0, code: 'unsupported' }
    const entry = this.engine.signDirectoryEntry(handle)
    const r = await fetch(this.url(`/v1/directory/${encodeURIComponent(handle)}`), {
      method: 'PUT',
      headers: {
        'content-type': 'text/plain; charset=utf-8',
        'x-relay-mailbox': this.engine.mailboxHex(),
        'x-relay-sig': entry.sig_b64,
      },
      body: entry.card,
    })
    if (r.ok) return { ok: true, status: r.status, code: '' }
    let code = ''
    try {
      code = String(((await r.json()) as { error?: string; code?: string }).error ?? '')
    } catch {
      /* not JSON */
    }
    return { ok: false, status: r.status, code }
  }

  async health(): Promise<boolean> {
    try {
      const r = await fetch(this.url('/healthz'))
      return r.ok
    } catch {
      return false
    }
  }
}

/** A card response is the card text, raw card bytes, or JSON `{card: b64}`. */
async function readCard(r: Response): Promise<string | null> {
  const text = (await r.text()).trim()
  if (text.startsWith('relay1:')) return text
  try {
    const j = JSON.parse(text) as { card?: string }
    if (j.card) {
      if (j.card.startsWith('relay1:')) return j.card
      const decoded = new TextDecoder().decode(fromB64(j.card))
      if (decoded.startsWith('relay1:')) return decoded
    }
  } catch {
    /* not JSON */
  }
  return null
}
