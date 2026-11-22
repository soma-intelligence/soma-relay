// Desktop camera capture (getUserMedia): live preview, shutter, then Envoyer or Reprendre with an
// optional caption. Phones use the native camera through <input capture> instead.

import { useEffect, useRef, useState } from 'react'
import { createPortal } from 'react-dom'
import { Close } from './Icons'

export const isTouch = (): boolean => matchMedia('(pointer: coarse)').matches

export function CameraCapture({
  facing = 'environment',
  title = 'Appareil photo',
  confirmLabel = 'Envoyer',
  withCaption,
  mirror,
  onCapture,
  onClose,
}: {
  facing?: 'user' | 'environment'
  title?: string
  confirmLabel?: string
  withCaption?: boolean
  /** Show the preview as a mirror (selfies). The photo itself is not mirrored. */
  mirror?: boolean
  onCapture: (photo: Blob, caption: string) => void
  onClose: () => void
}) {
  const video = useRef<HTMLVideoElement>(null)
  const root = useRef<HTMLDivElement>(null)
  const shutter = useRef<HTMLButtonElement>(null)
  const [error, setError] = useState<string | null>(null)
  const [ready, setReady] = useState(false)
  const [shot, setShot] = useState<{ blob: Blob; url: string } | null>(null)
  const [caption, setCaption] = useState('')
  const [flash, setFlash] = useState(false)

  useEffect(() => {
    let stream: MediaStream | null = null
    let stopped = false
    void (async () => {
      try {
        stream = await navigator.mediaDevices.getUserMedia({
          video: { facingMode: facing, width: { ideal: 1920 }, height: { ideal: 1080 } },
          audio: false,
        })
      } catch {
        setError('Caméra indisponible ou refusée. Autorise-la dans les réglages du site, ou choisis une photo.')
        return
      }
      if (stopped) return stream.getTracks().forEach((t) => t.stop())
      const v = video.current
      if (!v) return
      v.srcObject = stream
      await v.play().catch(() => {})
      setReady(true)
      shutter.current?.focus()
    })()
    return () => {
      stopped = true
      stream?.getTracks().forEach((t) => t.stop())
    }
  }, [facing])

  useEffect(() => {
    const prev = document.activeElement as HTMLElement | null
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') {
        e.stopPropagation()
        onClose()
      }
    }
    document.addEventListener('keydown', onKey, true)
    return () => {
      document.removeEventListener('keydown', onKey, true)
      prev?.focus?.()
    }
  }, [onClose])

  useEffect(() => () => {
    if (shot) URL.revokeObjectURL(shot.url)
  }, [shot])

  const take = async () => {
    const v = video.current
    if (!v || !v.videoWidth) return
    const c = document.createElement('canvas')
    c.width = v.videoWidth
    c.height = v.videoHeight
    c.getContext('2d')!.drawImage(v, 0, 0)
    const blob = await new Promise<Blob | null>((r) => c.toBlob(r, 'image/jpeg', 0.92))
    if (!blob) return
    setFlash(true)
    setTimeout(() => setFlash(false), 180)
    setShot({ blob, url: URL.createObjectURL(blob) })
  }

  return createPortal(
    <div className="cam-scrim" role="dialog" aria-modal="true" aria-label={title} ref={root}>
      <div className="cam">
        <div className="cam-head">
          <h2>{title}</h2>
          <button className="icon-btn" onClick={onClose} aria-label="Fermer">
            <Close />
          </button>
        </div>
        <div className="cam-stage">
          <video ref={video} muted playsInline className={mirror ? 'mirror' : undefined} aria-label="Aperçu de la caméra" hidden={!!shot} />
          {shot && <img src={shot.url} alt="Photo prise" className="cam-still" />}
          {!ready && !error && !shot && <span className="spinner" aria-label="Ouverture de la caméra" />}
          {error && (
            <p className="cam-error" role="alert">
              {error}
            </p>
          )}
          {flash && <span className="cam-flash" aria-hidden="true" />}
        </div>
        {shot ? (
          <form
            className="cam-actions"
            onSubmit={(e) => {
              e.preventDefault()
              onCapture(shot.blob, caption.trim())
            }}
          >
            {withCaption && (
              <>
                <label htmlFor="cam-caption" className="sr-only">
                  Légende
                </label>
                <input id="cam-caption" className="cam-caption" placeholder="Ajouter une légende" value={caption} onChange={(e) => setCaption(e.target.value)} autoComplete="off" />
              </>
            )}
            <div className="row-btns" style={{ marginTop: 0 }}>
              <button type="button" className="btn" onClick={() => setShot(null)}>
                Reprendre
              </button>
              <button className="btn primary" autoFocus={!withCaption}>
                {confirmLabel}
              </button>
            </div>
          </form>
        ) : (
          <div className="cam-actions shutter-row">
            <button ref={shutter} className="shutter" onClick={() => void take()} disabled={!ready} aria-label="Prendre la photo">
              <span />
            </button>
          </div>
        )}
      </div>
    </div>,
    document.body,
  )
}
