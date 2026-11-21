// Full-screen map of a location message (MapLibre GL + OpenFreeMap "liberty"), loaded on
// demand. Live locations move their marker as updates arrive. Without WebGL, a large static
// raster map takes its place.

import { useEffect, useRef, useState } from 'react'
import * as maplibregl from 'maplibre-gl'
import workerUrl from 'maplibre-gl/dist/maplibre-gl-worker.mjs?url'
import 'maplibre-gl/dist/maplibre-gl.css'
import type { ChatMessage } from '../state/types'
import { useRelay } from './common'
import { Close, External } from './Icons'
import { isLive, mapsLinks, StaticMap } from './Rich'

maplibregl.setWorkerUrl(workerUrl)

const STYLE = 'https://tiles.openfreemap.org/styles/liberty'

export default function MapView({ m: initial, onClose }: { m: ChatMessage; onClose: () => void }) {
  const snap = useRelay()
  const m = snap.messages[initial.convId]?.find((x) => x.id === initial.id) ?? initial
  const loc = m.location!
  const box = useRef<HTMLDivElement>(null)
  const map = useRef<maplibregl.Map | null>(null)
  const marker = useRef<maplibregl.Marker | null>(null)
  const [failed, setFailed] = useState(false)
  const live = isLive(m)

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => e.key === 'Escape' && onClose()
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [onClose])

  useEffect(() => {
    if (!box.current) return
    let mp: maplibregl.Map
    try {
      mp = new maplibregl.Map({
        container: box.current,
        style: STYLE,
        center: [loc.lon, loc.lat],
        zoom: 15,
        attributionControl: false,
      })
    } catch (e) {
      console.info('map unavailable', e)
      setFailed(true)
      return
    }
    mp.addControl(new maplibregl.NavigationControl({ showCompass: false }), 'top-right')
    // Top right, under the zoom buttons: the bottom bar would hide the credits.
    mp.addControl(new maplibregl.AttributionControl({ compact: true }), 'top-right')
    const el = document.createElement('div')
    el.className = live ? 'mv-live' : 'mv-pin'
    marker.current = new maplibregl.Marker({ element: el, anchor: live ? 'center' : 'bottom' }).setLngLat([loc.lon, loc.lat]).addTo(mp)
    map.current = mp
    return () => {
      mp.remove()
      map.current = null
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  // Live updates move the marker and follow it.
  useEffect(() => {
    marker.current?.setLngLat([loc.lon, loc.lat])
    map.current?.easeTo({ center: [loc.lon, loc.lat], duration: 600 })
  }, [loc.lat, loc.lon])

  const links = mapsLinks(loc.lat, loc.lon, loc.name)
  return (
    <div className="mapview" role="dialog" aria-modal="true" aria-label="Carte">
      {failed ? (
        <div className="mv-static">
          <StaticMap lat={loc.lat} lon={loc.lon} accuracy={loc.accuracy_m} width={Math.min(innerWidth, 900)} height={Math.min(innerHeight - 140, 700)} live={live} zoom={16} />
        </div>
      ) : (
        <div className="mv-map" ref={box} />
      )}
      <button className="icon-btn mv-close glass" aria-label="Fermer la carte" onClick={onClose} autoFocus>
        <Close />
      </button>
      <div className="mv-bar glass">
        <div className="mv-title">
          <b>{loc.name ?? (live ? 'Position en direct' : 'Position')}</b>
          <span className="mono">
            {loc.lat.toFixed(5)}, {loc.lon.toFixed(5)}
            {loc.accuracy_m ? ` · ±${Math.round(loc.accuracy_m)} m` : ''}
          </span>
        </div>
        <div className="mv-links">
          <a className="btn" href={links.apple} target="_blank" rel="noopener noreferrer">
            <External /> Ouvrir dans Plans
          </a>
          <a className="btn" href={links.google} target="_blank" rel="noopener noreferrer">
            <External /> Google Maps
          </a>
        </div>
      </div>
    </div>
  )
}
