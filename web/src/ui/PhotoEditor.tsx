// Profile and group photos: pick (file or camera), crop square under a round mask (drag, pinch,
// wheel, slider, keyboard), then encode to a 256 px JPEG of at most 24 KiB.

import { createPortal } from 'react-dom'
import { useCallback, useEffect, useLayoutEffect, useRef, useState } from 'react'
import { encodeAvatar, loadImage } from '../lib/avatar'
import { relay } from '../state/relay'
import { CameraCapture, isTouch } from './Camera'
import { Camera, Image, Trash } from './Icons'

const MAX_ZOOM = 4
const EDIT_MAX_SIDE = 1600

interface Source {
  canvas: HTMLCanvasElement
  url: string
}

async function toSource(file: Blob): Promise<Source> {
  const img = await loadImage(file)
  const w = 'naturalWidth' in img ? img.naturalWidth : img.width
  const h = 'naturalHeight' in img ? img.naturalHeight : img.height
  const k = Math.min(1, EDIT_MAX_SIDE / Math.max(w, h))
  const canvas = document.createElement('canvas')
  canvas.width = Math.max(1, Math.round(w * k))
  canvas.height = Math.max(1, Math.round(h * k))
  canvas.getContext('2d')!.drawImage(img, 0, 0, canvas.width, canvas.height)
  if ('close' in img) img.close()
  const blob = await new Promise<Blob | null>((r) => canvas.toBlob(r, 'image/jpeg', 0.9))
  if (!blob) throw new Error('Image illisible.')
  return { canvas, url: URL.createObjectURL(blob) }
}

/** Square crop with a round preview mask. Calls onDone with the encoded JPEG. */
export function AvatarCropper({ file, onDone, onCancel }: { file: Blob; onDone: (jpeg: Uint8Array) => void; onCancel: () => void }) {
  const [src, setSrc] = useState<Source | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const view = useRef<HTMLDivElement>(null)
  const [side, setSide] = useState(300)
  // Image position (top-left, view px) and zoom (1 = the image just covers the view).
  const [pos, setPos] = useState({ x: 0, y: 0, z: 1 })
  const pointers = useRef(new Map<number, { x: number; y: number }>())
  const pinch = useRef<{ d: number; z: number } | null>(null)

  useEffect(() => {
    let off = false
    let made: Source | null = null
    toSource(file)
      .then((s) => {
        made = s
        if (!off) setSrc(s)
        else URL.revokeObjectURL(s.url)
      })
      .catch(() => setError('Cette image ne s’ouvre pas. Essaie une autre photo.'))
    return () => {
      off = true
      if (made) URL.revokeObjectURL(made.url)
    }
  }, [file])

  useLayoutEffect(() => {
    const measure = () => setSide(Math.min(320, Math.max(200, window.innerWidth - 64)))
    measure()
    window.addEventListener('resize', measure)
    return () => window.removeEventListener('resize', measure)
  }, [])

  const w = src?.canvas.width ?? 1
  const h = src?.canvas.height ?? 1
  const base = side / Math.min(w, h)

  const clamp = useCallback(
    (x: number, y: number, z: number) => {
      const zz = Math.min(MAX_ZOOM, Math.max(1, z))
      const s = base * zz
      return {
        x: Math.min(0, Math.max(side - w * s, x)),
        y: Math.min(0, Math.max(side - h * s, y)),
        z: zz,
      }
    },
    [base, side, w, h],
  )

  // Center the image once it is known.
  useEffect(() => {
    if (!src) return
    const s = base
    setPos(clamp((side - w * s) / 2, (side - h * s) / 2, 1))
  }, [src, base, side, w, h, clamp])

  /** Zooms to `z` keeping the view point (px, py) still. */
  const zoomAt = useCallback(
    (z: number, px = side / 2, py = side / 2) =>
      setPos((p) => {
        const s0 = base * p.z
        const nz = Math.min(MAX_ZOOM, Math.max(1, z))
        const s1 = base * nz
        const ix = (px - p.x) / s0
        const iy = (py - p.y) / s0
        return clamp(px - ix * s1, py - iy * s1, nz)
      }),
    [base, side, clamp],
  )

  const onDown = (e: React.PointerEvent) => {
    ;(e.currentTarget as HTMLElement).setPointerCapture(e.pointerId)
    pointers.current.set(e.pointerId, { x: e.clientX, y: e.clientY })
    if (pointers.current.size === 2) {
      const [a, b] = [...pointers.current.values()]
      pinch.current = { d: Math.hypot(a.x - b.x, a.y - b.y), z: pos.z }
    }
  }
  const onMove = (e: React.PointerEvent) => {
    const prev = pointers.current.get(e.pointerId)
    if (!prev) return
    const cur = { x: e.clientX, y: e.clientY }
    pointers.current.set(e.pointerId, cur)
    if (pointers.current.size === 2 && pinch.current) {
      const [a, b] = [...pointers.current.values()]
      const r = view.current!.getBoundingClientRect()
      zoomAt((pinch.current.z * Math.hypot(a.x - b.x, a.y - b.y)) / pinch.current.d, (a.x + b.x) / 2 - r.left, (a.y + b.y) / 2 - r.top)
      return
    }
    setPos((p) => clamp(p.x + cur.x - prev.x, p.y + cur.y - prev.y, p.z))
  }
  const onUp = (e: React.PointerEvent) => {
    pointers.current.delete(e.pointerId)
    if (pointers.current.size < 2) pinch.current = null
  }

  useEffect(() => {
    const el = view.current
    if (!el) return
    const onWheel = (e: WheelEvent) => {
      e.preventDefault()
      const r = el.getBoundingClientRect()
      setPos((p) => {
        const nz = Math.min(MAX_ZOOM, Math.max(1, p.z * Math.exp(-e.deltaY / 300)))
        const s0 = base * p.z
        const s1 = base * nz
        const px = e.clientX - r.left
        const py = e.clientY - r.top
        return clamp(px - ((px - p.x) / s0) * s1, py - ((py - p.y) / s0) * s1, nz)
      })
    }
    el.addEventListener('wheel', onWheel, { passive: false })
    return () => el.removeEventListener('wheel', onWheel)
  }, [base, clamp, src])

  const onKey = (e: React.KeyboardEvent) => {
    const step = e.shiftKey ? 40 : 10
    const moves: Record<string, [number, number]> = { ArrowLeft: [step, 0], ArrowRight: [-step, 0], ArrowUp: [0, step], ArrowDown: [0, -step] }
    if (moves[e.key]) {
      e.preventDefault()
      const [dx, dy] = moves[e.key]
      setPos((p) => clamp(p.x + dx, p.y + dy, p.z))
    } else if (e.key === '+' || e.key === '=') {
      e.preventDefault()
      zoomAt(pos.z * 1.15)
    } else if (e.key === '-') {
      e.preventDefault()
      zoomAt(pos.z / 1.15)
    }
  }

  const done = async () => {
    if (!src) return
    setBusy(true)
    try {
      const s = base * pos.z
      const jpeg = await encodeAvatar(src.canvas, { sx: -pos.x / s, sy: -pos.y / s, size: side / s })
      onDone(jpeg)
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Encodage impossible.')
      setBusy(false)
    }
  }

  useEffect(() => {
    const onEsc = (e: KeyboardEvent) => {
      if (e.key === 'Escape') {
        e.stopPropagation()
        onCancel()
      }
    }
    document.addEventListener('keydown', onEsc, true)
    return () => document.removeEventListener('keydown', onEsc, true)
  }, [onCancel])

  const s = base * pos.z
  return createPortal(
    <div className="cam-scrim" role="dialog" aria-modal="true" aria-label="Recadrer la photo">
      <div className="cam crop">
        <div className="cam-head">
          <h2>Recadrer</h2>
        </div>
        <p className="hint center" style={{ margin: '0 0 14px' }}>
          Glisse pour placer, pince ou fais défiler pour zoomer.
        </p>
        <div
          ref={view}
          className="crop-view"
          style={{ width: side, height: side }}
          tabIndex={0}
          role="application"
          aria-label="Zone de recadrage. Flèches pour déplacer, plus et moins pour zoomer."
          onPointerDown={onDown}
          onPointerMove={onMove}
          onPointerUp={onUp}
          onPointerCancel={onUp}
          onKeyDown={onKey}
        >
          {src && (
            <img
              src={src.url}
              alt=""
              draggable={false}
              style={{ width: w, height: h, transform: `translate(${pos.x}px, ${pos.y}px) scale(${s})` }}
            />
          )}
          {!src && !error && <span className="spinner" aria-label="Chargement" />}
          <span className="crop-mask" aria-hidden="true" />
        </div>
        <label className="crop-zoom">
          <span className="sr-only">Zoom</span>
          <span aria-hidden="true">−</span>
          <input type="range" min={1} max={MAX_ZOOM} step={0.01} value={pos.z} onChange={(e) => zoomAt(Number(e.target.value))} aria-label="Zoom" />
          <span aria-hidden="true">+</span>
        </label>
        {error && (
          <p className="error" role="alert">
            {error}
          </p>
        )}
        <div className="row-btns">
          <button className="btn" onClick={onCancel}>
            Annuler
          </button>
          <button className="btn primary" onClick={() => void done()} disabled={!src || busy}>
            {busy ? 'Un instant…' : 'Choisir'}
          </button>
        </div>
      </div>
    </div>,
    document.body,
  )
}

/**
 * Buttons to choose a photo (file), take one (camera: native on phones, getUserMedia on
 * desktop) or remove it. The picked image goes through the cropper; onPick gets the JPEG.
 */
export function AvatarPicker({
  has,
  onPick,
  compact,
  selfie = true,
}: {
  has: boolean
  onPick: (jpeg: Uint8Array | null) => void | Promise<void>
  compact?: boolean
  selfie?: boolean
}) {
  const fileInput = useRef<HTMLInputElement>(null)
  const camInput = useRef<HTMLInputElement>(null)
  const [file, setFile] = useState<Blob | null>(null)
  const [camera, setCamera] = useState(false)
  const canCamera = typeof navigator.mediaDevices?.getUserMedia === 'function'

  const takePhoto = () => {
    if (isTouch()) camInput.current?.click()
    else if (canCamera) setCamera(true)
    else relay.toast('Pas de caméra dans ce navigateur.')
  }
  const onFile = (f: File | undefined) => {
    if (!f) return
    if (!f.type.startsWith('image/')) {
      relay.toast('Choisis une image.')
      return
    }
    setFile(f)
  }

  return (
    <>
      <div className={`avatar-actions${compact ? ' compact' : ''}`}>
        <button type="button" className="btn" onClick={() => fileInput.current?.click()} aria-label={has ? 'Changer la photo' : 'Choisir une photo'}>
          <Image size={18} /> {compact ? 'Choisir' : has ? 'Changer la photo' : 'Choisir une photo'}
        </button>
        <button type="button" className="btn" onClick={takePhoto} aria-label="Prendre une photo">
          <Camera size={18} /> {compact ? 'Caméra' : 'Prendre une photo'}
        </button>
        {has && (
          <button type="button" className="btn" style={{ color: 'var(--danger)' }} onClick={() => void onPick(null)} aria-label="Retirer la photo">
            <Trash size={18} /> {compact ? '' : 'Retirer'}
          </button>
        )}
      </div>
      <input
        ref={fileInput}
        type="file"
        accept="image/*"
        hidden
        data-testid="avatar-file"
        onChange={(e) => {
          onFile(e.target.files?.[0])
          e.target.value = ''
        }}
      />
      <input
        ref={camInput}
        type="file"
        accept="image/*"
        capture={selfie ? 'user' : 'environment'}
        hidden
        onChange={(e) => {
          onFile(e.target.files?.[0])
          e.target.value = ''
        }}
      />
      {camera && (
        <CameraCapture
          facing={selfie ? 'user' : 'environment'}
          mirror={selfie}
          title="Photo de profil"
          confirmLabel="Utiliser"
          onClose={() => setCamera(false)}
          onCapture={(blob) => {
            setCamera(false)
            setFile(blob)
          }}
        />
      )}
      {file && (
        <AvatarCropper
          file={file}
          onCancel={() => setFile(null)}
          onDone={(jpeg) => {
            setFile(null)
            void onPick(jpeg)
          }}
        />
      )}
    </>
  )
}
