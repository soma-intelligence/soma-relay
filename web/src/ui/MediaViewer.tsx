import { useEffect, useRef, useState, type PointerEvent as RPointerEvent, type WheelEvent as RWheelEvent } from 'react'
import { Close } from './Icons'

// Full-screen media viewer. Images zoom with a pinch (two pointers), a double tap or double
// click, and the wheel; a zoomed image pans with one finger. A tap that does not move closes
// the viewer when the image is not zoomed. Escape closes.

const MAX = 5

interface View {
  s: number
  x: number
  y: number
}

const clampScale = (s: number) => Math.min(MAX, Math.max(1, s))

export function MediaViewer({ url, kind, onClose }: { url: string; kind: 'image' | 'video'; onClose: () => void }) {
  const [view, setView] = useState<View>({ s: 1, x: 0, y: 0 })
  const viewRef = useRef(view)
  viewRef.current = view
  const pointers = useRef(new Map<number, { x: number; y: number }>())
  const gesture = useRef<{ dist: number; s: number; cx: number; cy: number; x: number; y: number } | null>(null)
  const moved = useRef(false)
  const lastTap = useRef(0)

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') onClose()
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [onClose])

  const set = (v: View) => setView(v.s <= 1.001 ? { s: 1, x: 0, y: 0 } : v)

  /** Zooms to `s` keeping the screen point (px, py), relative to the centre, still. */
  const zoomAt = (s: number, px: number, py: number) => {
    const v = viewRef.current
    const ns = clampScale(s)
    const k = ns / v.s
    set({ s: ns, x: px - (px - v.x) * k, y: py - (py - v.y) * k })
  }

  const centre = (e: { clientX: number; clientY: number }, el: HTMLElement) => {
    const r = el.getBoundingClientRect()
    return { x: e.clientX - r.left - r.width / 2, y: e.clientY - r.top - r.height / 2 }
  }

  const onDown = (e: RPointerEvent<HTMLDivElement>) => {
    if (kind !== 'image') return
    e.currentTarget.setPointerCapture(e.pointerId)
    pointers.current.set(e.pointerId, { x: e.clientX, y: e.clientY })
    moved.current = pointers.current.size > 1
    const pts = [...pointers.current.values()]
    const v = viewRef.current
    if (pts.length === 2) {
      const c = centre({ clientX: (pts[0].x + pts[1].x) / 2, clientY: (pts[0].y + pts[1].y) / 2 }, e.currentTarget)
      gesture.current = { dist: Math.hypot(pts[0].x - pts[1].x, pts[0].y - pts[1].y), s: v.s, cx: c.x, cy: c.y, x: v.x, y: v.y }
    } else {
      gesture.current = { dist: 0, s: v.s, cx: e.clientX, cy: e.clientY, x: v.x, y: v.y }
    }
  }

  const onMove = (e: RPointerEvent<HTMLDivElement>) => {
    if (!pointers.current.has(e.pointerId) || !gesture.current) return
    pointers.current.set(e.pointerId, { x: e.clientX, y: e.clientY })
    const g = gesture.current
    const pts = [...pointers.current.values()]
    if (pts.length >= 2 && g.dist > 0) {
      const dist = Math.hypot(pts[0].x - pts[1].x, pts[0].y - pts[1].y)
      const ns = clampScale((g.s * dist) / g.dist)
      const k = ns / g.s
      set({ s: ns, x: g.cx - (g.cx - g.x) * k, y: g.cy - (g.cy - g.y) * k })
      moved.current = true
    } else if (pts.length === 1) {
      const dx = e.clientX - g.cx
      const dy = e.clientY - g.cy
      if (Math.abs(dx) + Math.abs(dy) > 6) moved.current = true
      if (viewRef.current.s > 1) set({ s: viewRef.current.s, x: g.x + dx, y: g.y + dy })
    }
  }

  const onUp = (e: RPointerEvent<HTMLDivElement>) => {
    if (!pointers.current.has(e.pointerId)) return
    pointers.current.delete(e.pointerId)
    if (pointers.current.size === 1) {
      // One finger left after a pinch: continue as a pan from here.
      const [p] = [...pointers.current.values()]
      const v = viewRef.current
      gesture.current = { dist: 0, s: v.s, cx: p.x, cy: p.y, x: v.x, y: v.y }
      return
    }
    if (pointers.current.size > 0) return
    gesture.current = null
    if (moved.current) return
    const now = Date.now()
    if (now - lastTap.current < 300) {
      lastTap.current = 0
      const c = centre(e, e.currentTarget)
      if (viewRef.current.s > 1) set({ s: 1, x: 0, y: 0 })
      else zoomAt(2.5, c.x, c.y)
      return
    }
    lastTap.current = now
    const wasZoomed = viewRef.current.s > 1
    setTimeout(() => {
      if (lastTap.current === now && !wasZoomed) onClose()
    }, 300)
  }

  const onWheel = (e: RWheelEvent<HTMLDivElement>) => {
    if (kind !== 'image') return
    const c = centre(e, e.currentTarget)
    zoomAt(viewRef.current.s * Math.exp(-e.deltaY * 0.002), c.x, c.y)
  }

  return (
    <div className="lightbox" role="dialog" aria-modal="true" aria-label="Aperçu">
      {kind === 'image' ? (
        <div
          className="lightbox-stage"
          onPointerDown={onDown}
          onPointerMove={onMove}
          onPointerUp={onUp}
          onPointerCancel={onUp}
          onWheel={onWheel}
        >
          <img
            src={url}
            alt=""
            draggable={false}
            style={{ transform: `translate(${view.x}px, ${view.y}px) scale(${view.s})` }}
          />
        </div>
      ) : (
        <div className="lightbox-stage" onClick={onClose}>
          <video src={url} controls autoPlay playsInline onClick={(e) => e.stopPropagation()} />
        </div>
      )}
      <button className="icon-btn" aria-label="Fermer" onClick={onClose} autoFocus>
        <Close />
      </button>
    </div>
  )
}
