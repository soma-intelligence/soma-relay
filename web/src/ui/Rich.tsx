// v1.1 bubbles: poll, location (static raster map), link preview card.

import { useEffect, useState } from 'react'
import type { LinkPreview } from '../core/engine'
import { relay } from '../state/relay'
import type { ChatMessage } from '../state/types'
import { Check } from './Icons'

// Map tiles

/** OpenStreetMap raster tiles, drawn at half size from the next zoom level (sharp on 2x screens). */
const TILE = 128
const tileUrl = (z: number, x: number, y: number) => `https://tile.openstreetmap.org/${z}/${x}/${y}.png`

function project(lat: number, lon: number, z: number) {
  const n = 2 ** z
  const r = (lat * Math.PI) / 180
  return {
    x: ((lon + 180) / 360) * n * TILE,
    y: ((1 - Math.asinh(Math.tan(r)) / Math.PI) / 2) * n * TILE,
  }
}

export function StaticMap({
  lat,
  lon,
  accuracy,
  zoom = 15,
  width,
  height,
  live,
}: {
  lat: number
  lon: number
  accuracy?: number
  zoom?: number
  width: number
  height: number
  live?: boolean
}) {
  const z = zoom + 1
  const n = 2 ** z
  const c = project(lat, lon, z)
  const left = c.x - width / 2
  const top = c.y - height / 2
  const tiles: { key: string; src: string; x: number; y: number }[] = []
  for (let ty = Math.floor(top / TILE); ty <= Math.floor((top + height) / TILE); ty++) {
    if (ty < 0 || ty >= n) continue
    for (let tx = Math.floor(left / TILE); tx <= Math.floor((left + width) / TILE); tx++) {
      const wx = ((tx % n) + n) % n
      tiles.push({ key: `${tx}-${ty}`, src: tileUrl(z, wx, ty), x: tx * TILE - left, y: ty * TILE - top })
    }
  }
  // Metres per CSS pixel at this latitude (256 px tiles at `zoom`).
  const mpp = (156543.03 * Math.cos((lat * Math.PI) / 180)) / 2 ** zoom
  const accPx = accuracy ? Math.min(accuracy / mpp, Math.max(width, height)) : 0
  return (
    <div className="static-map" style={{ width, height }} aria-hidden="true">
      {tiles.map((t) => (
        <img key={t.key} src={t.src} alt="" draggable={false} loading="lazy" style={{ left: t.x, top: t.y, width: TILE, height: TILE }} />
      ))}
      {accPx > 8 && <span className="acc" style={{ width: accPx * 2, height: accPx * 2 }} />}
      {live ? <span className="live-dot" /> : <MapPin />}
    </div>
  )
}

function MapPin() {
  return (
    <svg className="map-pin" width="30" height="40" viewBox="0 0 30 40">
      <path d="M15 39s13-12.3 13-23A13 13 0 002 16c0 10.7 13 23 13 23z" fill="var(--danger)" stroke="#fff" strokeWidth="2" />
      <circle cx="15" cy="15.5" r="5" fill="#fff" />
    </svg>
  )
}

export function mapsLinks(lat: number, lon: number, name?: string) {
  const q = encodeURIComponent(name ?? `${lat.toFixed(6)},${lon.toFixed(6)}`)
  return {
    apple: `https://maps.apple.com/?ll=${lat},${lon}&q=${q}`,
    google: `https://www.google.com/maps/search/?api=1&query=${lat},${lon}`,
  }
}

function useNow(every: number, active: boolean) {
  const [now, setNow] = useState(Date.now())
  useEffect(() => {
    if (!active) return
    const t = setInterval(() => setNow(Date.now()), every)
    return () => clearInterval(t)
  }, [every, active])
  return now
}

const hm = (ts: number) => new Date(ts).toLocaleTimeString('fr-FR', { hour: '2-digit', minute: '2-digit' })

export function isLive(m: ChatMessage, now = Date.now()): boolean {
  return !!m.location?.live_until && !m.liveStopped && now < m.location.live_until
}

export function LocationBubble({ m, onOpen }: { m: ChatMessage; onOpen: () => void }) {
  const loc = m.location!
  const now = useNow(15_000, !!loc.live_until && !m.liveStopped)
  const live = isLive(m, now)
  const mine = m.from === 'me'
  const sharing = mine && relay.getSnapshot().liveShares.has(m.id)
  let label: string
  if (!loc.live_until) label = loc.name ?? 'Position'
  else if (live) label = `En direct · jusqu’à ${hm(loc.live_until)}`
  else label = 'Partage en direct terminé'
  return (
    <div className="loc-card">
      <button className="loc-map" onClick={onOpen} aria-label={`Ouvrir la carte : ${label}`}>
        <StaticMap lat={loc.lat} lon={loc.lon} accuracy={loc.accuracy_m} width={260} height={150} live={live} />
      </button>
      <div className="loc-foot">
        <span className={`loc-label${live ? ' live' : ''}`}>
          {live && <span className="pulse" aria-hidden="true" />}
          {label}
        </span>
        <span className="loc-sub mono">
          {loc.lat.toFixed(5)}, {loc.lon.toFixed(5)}
          {loc.accuracy_m ? ` · ±${Math.round(loc.accuracy_m)} m` : ''}
          {loc.live_until && m.locationTs && m.locationTs !== m.ts ? ` · màj ${hm(m.locationTs)}` : ''}
        </span>
        {sharing && live && (
          <button className="btn small" onClick={() => relay.stopLive(m.id)}>
            Arrêter le partage
          </button>
        )}
      </div>
    </div>
  )
}

export function PollBubble({ m, isGroup, nameOf }: { m: ChatMessage; isGroup: boolean; nameOf: (fp: string) => string }) {
  const p = m.poll!
  const votes = m.votes ?? {}
  const mine = votes.me?.opts ?? []
  const voters = Object.keys(votes)
  const total = voters.length
  const closed = !!m.pollClosed || (!!p.closes_at && Date.now() > p.closes_at)
  const counts = new Map<string, number>()
  for (const v of Object.values(votes)) for (const o of v.opts) counts.set(o, (counts.get(o) ?? 0) + 1)
  const max = Math.max(0, ...counts.values())
  const vote = (id: string) => {
    if (closed) return
    let next: string[]
    if (p.multi) next = mine.includes(id) ? mine.filter((x) => x !== id) : [...mine, id]
    else next = mine.includes(id) ? [] : [id]
    navigator.vibrate?.(8)
    void relay.vote(m.convId, m.id, next)
  }
  return (
    <div className="poll-card" role="group" aria-label={`Sondage : ${p.question}`}>
      <div className="poll-q">{p.question}</div>
      <div className="poll-sub">
        {closed ? 'Sondage clos' : p.multi ? 'Plusieurs réponses possibles' : 'Une seule réponse'}
      </div>
      <div className="poll-opts">
        {p.options.map((o) => {
          const n = counts.get(o.id) ?? 0
          const pct = total ? n / total : 0
          const chosen = mine.includes(o.id)
          const who = isGroup ? Object.entries(votes).filter(([, v]) => v.opts.includes(o.id)).map(([fp]) => (fp === 'me' ? 'toi' : nameOf(fp))) : []
          return (
            <button
              key={o.id}
              className={`poll-opt${chosen ? ' chosen' : ''}${n && n === max ? ' lead' : ''}`}
              aria-pressed={chosen}
              disabled={closed}
              onClick={() => vote(o.id)}
              title={who.length ? who.join(', ') : undefined}
              aria-label={`${o.text}, ${n} vote${n > 1 ? 's' : ''}${chosen ? ', ton choix' : ''}`}
            >
              <span className="poll-bar" style={{ transform: `scaleX(${pct})` }} aria-hidden="true" />
              <span className={`poll-check${p.multi ? ' square' : ''}`} aria-hidden="true">
                {chosen && <Check size={12} />}
              </span>
              <span className="poll-text">{o.text}</span>
              <span className="poll-count mono">{total ? `${Math.round(pct * 100)} %` : ''}</span>
            </button>
          )
        })}
      </div>
      <div className="poll-foot">
        <span className="mono">
          {total} vote{total > 1 ? 's' : ''}
        </span>
        {m.from === 'me' && !closed && (
          <button className="link-btn" onClick={() => void relay.closePoll(m.convId, m.id)}>
            Clore le sondage
          </button>
        )}
      </div>
    </div>
  )
}

export function LinkCard({ link }: { link: LinkPreview }) {
  let host = link.site
  if (!host)
    try {
      host = new URL(link.url).hostname.replace(/^www\./, '')
    } catch {
      host = link.url
    }
  return (
    <a className="link-card" href={link.url} target="_blank" rel="noopener noreferrer nofollow" onClick={(e) => e.stopPropagation()}>
      {link.image && <img src={`data:image/jpeg;base64,${link.image}`} alt="" loading="lazy" />}
      <span className="lc-body">
        <span className="lc-site">{host}</span>
        {link.title && <span className="lc-title">{link.title}</span>}
        {link.description && <span className="lc-desc">{link.description}</span>}
      </span>
    </a>
  )
}
