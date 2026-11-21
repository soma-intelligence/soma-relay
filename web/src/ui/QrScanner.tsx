// Camera QR scanner: BarcodeDetector when the browser has it, else jsQR on canvas frames.
import { useEffect, useRef, useState } from 'react'

interface Detector {
  detect(src: CanvasImageSource): Promise<{ rawValue: string }[]>
}
type DetectorCtor = new (opts: { formats: string[] }) => Detector

export function QrScanner({ onResult }: { onResult: (text: string) => void }) {
  const video = useRef<HTMLVideoElement>(null)
  const [error, setError] = useState<string | null>(null)
  const done = useRef(false)

  useEffect(() => {
    let stream: MediaStream | null = null
    let raf = 0
    let stopped = false
    const canvas = document.createElement('canvas')
    const ctx = canvas.getContext('2d', { willReadFrequently: true })!

    const start = async () => {
      try {
        stream = await navigator.mediaDevices.getUserMedia({
          video: { facingMode: 'environment', width: { ideal: 1280 }, height: { ideal: 720 } },
          audio: false,
        })
      } catch {
        setError('Caméra indisponible ou refusée. Colle plutôt le lien.')
        return
      }
      if (stopped) return stream.getTracks().forEach((t) => t.stop())
      const v = video.current!
      v.srcObject = stream
      await v.play().catch(() => {})
      const Ctor = (globalThis as { BarcodeDetector?: DetectorCtor }).BarcodeDetector
      let detector: Detector | null = null
      if (Ctor) {
        try {
          detector = new Ctor({ formats: ['qr_code'] })
        } catch {
          detector = null
        }
      }
      const jsqr = detector ? null : (await import('jsqr')).default
      let busy = false
      const loop = async () => {
        if (stopped || done.current) return
        if (!busy && v.readyState >= 2) {
          busy = true
          try {
            let text: string | null = null
            if (detector) {
              const codes = await detector.detect(v)
              text = codes[0]?.rawValue ?? null
            } else if (jsqr) {
              const w = Math.min(640, v.videoWidth)
              const h = Math.round((v.videoHeight / v.videoWidth) * w)
              canvas.width = w
              canvas.height = h
              ctx.drawImage(v, 0, 0, w, h)
              const img = ctx.getImageData(0, 0, w, h)
              text = jsqr(img.data, w, h, { inversionAttempts: 'dontInvert' })?.data ?? null
            }
            if (text && /^relay1c?:/.test(text.trim())) {
              done.current = true
              navigator.vibrate?.(30)
              onResult(text.trim())
              return
            }
          } catch {
            /* next frame */
          }
          busy = false
        }
        raf = requestAnimationFrame(() => void loop())
      }
      void loop()
    }
    void start()
    return () => {
      stopped = true
      cancelAnimationFrame(raf)
      stream?.getTracks().forEach((t) => t.stop())
    }
  }, [onResult])

  return (
    <div>
      <div className="scanner">
        <video ref={video} muted playsInline aria-label="Aperçu de la caméra" />
        <div className="frame" aria-hidden="true" />
      </div>
      {error && (
        <p className="error" role="alert">
          {error}
        </p>
      )}
      <p className="hint center" style={{ marginTop: 10 }}>
        Vise le code affiché dans son app Soma Relay.
      </p>
    </div>
  )
}
