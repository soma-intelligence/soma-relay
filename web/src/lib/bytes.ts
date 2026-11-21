// Byte helpers: base64 (standard and url-safe), hex, utf8, uuid v7.

const enc = new TextEncoder()
const dec = new TextDecoder()

export const utf8 = (s: string): Uint8Array => enc.encode(s)
export const fromUtf8 = (b: Uint8Array): string => dec.decode(b)

export function toB64(bytes: Uint8Array): string {
  let s = ''
  const chunk = 0x8000
  for (let i = 0; i < bytes.length; i += chunk) {
    s += String.fromCharCode.apply(null, Array.from(bytes.subarray(i, i + chunk)))
  }
  return btoa(s)
}

export const toB64Url = (bytes: Uint8Array): string =>
  toB64(bytes).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')

/** Decodes base64 or base64url, with or without padding. */
export function fromB64(s: string): Uint8Array {
  let t = s.trim().replace(/-/g, '+').replace(/_/g, '/')
  while (t.length % 4) t += '='
  const bin = atob(t)
  const out = new Uint8Array(bin.length)
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i)
  return out
}

export function toHex(bytes: Uint8Array): string {
  let s = ''
  for (const b of bytes) s += b.toString(16).padStart(2, '0')
  return s
}

export function fromHex(hex: string): Uint8Array {
  const clean = hex.replace(/[^0-9a-fA-F]/g, '')
  const out = new Uint8Array(clean.length >> 1)
  for (let i = 0; i < out.length; i++) out[i] = parseInt(clean.substr(i * 2, 2), 16)
  return out
}

export function randomBytes(n: number): Uint8Array {
  const b = new Uint8Array(n)
  crypto.getRandomValues(b)
  return b
}

export function concat(...parts: Uint8Array[]): Uint8Array {
  const len = parts.reduce((a, p) => a + p.length, 0)
  const out = new Uint8Array(len)
  let o = 0
  for (const p of parts) {
    out.set(p, o)
    o += p.length
  }
  return out
}

/** UUID v7: 48-bit ms timestamp, then random. Sorts by time. */
export function uuidv7(): string {
  const b = randomBytes(16)
  const ms = Date.now()
  b[0] = (ms / 2 ** 40) & 0xff
  b[1] = (ms / 2 ** 32) & 0xff
  b[2] = (ms >>> 24) & 0xff
  b[3] = (ms >>> 16) & 0xff
  b[4] = (ms >>> 8) & 0xff
  b[5] = ms & 0xff
  b[6] = (b[6] & 0x0f) | 0x70
  b[8] = (b[8] & 0x3f) | 0x80
  const h = toHex(b)
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`
}

/** A fresh ArrayBuffer copy, for APIs typed on ArrayBuffer (WebCrypto, Blob). */
export const buf = (b: Uint8Array): ArrayBuffer => b.slice().buffer as ArrayBuffer

export async function sha256(data: Uint8Array): Promise<Uint8Array> {
  return new Uint8Array(await crypto.subtle.digest('SHA-256', buf(data)))
}

/** Groups a fingerprint like the apps do: 4F2A·91C0·77DE. */
export function fpShort(fp: string, groups = 2): string {
  const up = fp.toUpperCase()
  const out: string[] = []
  for (let i = 0; i < groups; i++) out.push(up.slice(i * 4, i * 4 + 4))
  return out.join('·')
}
