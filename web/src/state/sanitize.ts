// Inbound v1.1 fields come from peers: every one is checked and trimmed before it is stored
// or rendered. Anything that does not fit is dropped, never shown as "unreadable".

import type { GeoPoint, LinkPreview, PollSpec } from '../core/engine'
import { EXPIRE_CHOICES } from './types'

const str = (v: unknown, max: number): string | undefined =>
  typeof v === 'string' && v.trim() ? v.slice(0, max) : undefined

const num = (v: unknown): number | undefined => (typeof v === 'number' && Number.isFinite(v) ? v : undefined)

export function cleanPoll(v: unknown): PollSpec | undefined {
  if (!v || typeof v !== 'object') return undefined
  const p = v as Record<string, unknown>
  const question = str(p.question, 300)
  if (!question || !Array.isArray(p.options)) return undefined
  const seen = new Set<string>()
  const options: PollSpec['options'] = []
  for (const o of p.options.slice(0, 12)) {
    if (!o || typeof o !== 'object') continue
    const id = str((o as Record<string, unknown>).id, 16)
    const text = str((o as Record<string, unknown>).text, 200)
    if (!id || !text || seen.has(id)) continue
    seen.add(id)
    options.push({ id, text })
  }
  if (options.length < 2) return undefined
  const closes = num(p.closes_at)
  return { question, options, multi: p.multi === true, ...(closes ? { closes_at: closes } : {}) }
}

export function cleanGeo(v: unknown): GeoPoint | undefined {
  if (!v || typeof v !== 'object') return undefined
  const g = v as Record<string, unknown>
  const lat = num(g.lat)
  const lon = num(g.lon)
  if (lat === undefined || lon === undefined || Math.abs(lat) > 90 || Math.abs(lon) > 180) return undefined
  const out: GeoPoint = { lat, lon }
  const acc = num(g.accuracy_m)
  if (acc !== undefined && acc >= 0) out.accuracy_m = Math.min(acc, 100_000)
  const heading = num(g.heading)
  if (heading !== undefined) out.heading = ((heading % 360) + 360) % 360
  const name = str(g.name, 120)
  if (name) out.name = name
  const address = str(g.address, 240)
  if (address) out.address = address
  const until = num(g.live_until)
  if (until !== undefined) out.live_until = until
  if (g.stop === true) out.stop = true
  return out
}

export function isHttpUrl(u: string): boolean {
  try {
    const x = new URL(u)
    return x.protocol === 'https:' || x.protocol === 'http:'
  } catch {
    return false
  }
}

export function cleanLink(v: unknown): LinkPreview | undefined {
  if (!v || typeof v !== 'object') return undefined
  const l = v as Record<string, unknown>
  const url = str(l.url, 2048)
  if (!url || !isHttpUrl(url)) return undefined
  const out: LinkPreview = { url }
  const title = str(l.title, 200)
  if (title) out.title = title
  const description = str(l.description, 400)
  if (description) out.description = description
  const site = str(l.site, 80)
  if (site) out.site = site
  let image = typeof l.image === 'string' ? l.image : undefined
  if (image?.startsWith('data:')) image = image.slice(image.indexOf(',') + 1)
  // Base64 only, at most ~60 KiB of text (40 KiB of JPEG, with slack).
  if (image && image.length <= 60_000 && /^[A-Za-z0-9+/=]+$/.test(image)) out.image = image
  return out
}

export function cleanExpire(v: unknown): number | undefined {
  const n = num(v)
  return n && (EXPIRE_CHOICES as readonly number[]).includes(n) ? n : undefined
}

export function cleanStrings(v: unknown, max: number, len: number): string[] | undefined {
  if (!Array.isArray(v)) return undefined
  const out = v.filter((x): x is string => typeof x === 'string' && x.length > 0 && x.length <= len).slice(0, max)
  return out.length ? out : undefined
}

/** First http(s) URL in a text, without trailing punctuation. */
export function firstUrl(text: string): string | null {
  const m = text.match(/https?:\/\/[^\s<>"]+/i)
  if (!m) return null
  const u = m[0].replace(/[),.;:!?»”’']+$/, '')
  return isHttpUrl(u) ? u : null
}

export const URL_RE = /(https?:\/\/[^\s<>"]+[^\s<>"),.;:!?»”’'])/gi
