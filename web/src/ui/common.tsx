import { useEffect, useRef, useState, useSyncExternalStore, type ReactNode } from 'react'
import { relay, type Snapshot } from '../state/relay'
import { Close, People } from './Icons'

export function useRelay(): Snapshot {
  return useSyncExternalStore(relay.subscribe, relay.getSnapshot)
}

export function useCall() {
  return useSyncExternalStore(relay.calls.subscribe, relay.calls.getSnapshot)
}

export function initials(name: string): string {
  const parts = name.trim().split(/\s+/).filter(Boolean)
  if (!parts.length) return '?'
  if (parts.length === 1) return parts[0].slice(0, 2).toUpperCase()
  return (parts[0][0] + parts[1][0]).toUpperCase()
}

/**
 * A face: the photo of the profile `id` ('me', a fingerprint or 'g:' + group id) when there is
 * one, else the initials (or the group glyph). The photo fades in over the initials, same box,
 * so nothing moves when it loads.
 */
export function Avatar({
  name,
  id,
  online,
  small,
  size,
  group,
  className,
}: {
  name: string
  id?: string
  online?: boolean
  small?: boolean
  /** Pixel size, overrides the 48 px default (and `small`). */
  size?: number
  group?: boolean
  className?: string
}) {
  const snap = useRelay()
  const key = id && id === snap.me?.fingerprint ? 'me' : id
  const b64 = key ? snap.profiles[key]?.avatar : undefined
  const style = size ? { width: size, height: size, borderRadius: size / 2, fontSize: Math.round(size * 0.36) } : undefined
  return (
    <span className={`avatar${small ? ' sm' : ''}${b64 ? ' has-photo' : ''}${className ? ' ' + className : ''}`} style={style} aria-hidden="true">
      {group && !b64 ? <People size={size ? Math.round(size * 0.45) : small ? 17 : 20} /> : initials(name)}
      {b64 && <AvatarImg key={b64.length + b64.slice(-12)} src={`data:image/jpeg;base64,${b64}`} />}
      {online && <span className="presence" />}
    </span>
  )
}

function AvatarImg({ src }: { src: string }) {
  const [ready, setReady] = useState(false)
  return <img className={`avatar-img${ready ? ' ready' : ''}`} src={src} alt="" draggable={false} onLoad={() => setReady(true)} />
}

/** Modal sheet: focus trapped loosely (first field focused), Escape closes, scrim click closes. */
export function Sheet({
  title,
  onClose,
  children,
  wide,
}: {
  title: string
  onClose: () => void
  children: ReactNode
  wide?: boolean
}) {
  const ref = useRef<HTMLDivElement>(null)
  useEffect(() => {
    const prev = document.activeElement as HTMLElement | null
    const el = ref.current
    const first = el?.querySelector<HTMLElement>('input, textarea, [data-autofocus]')
    ;(first ?? el)?.focus()
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') onClose()
      if (e.key === 'Tab' && el) {
        const items = [...el.querySelectorAll<HTMLElement>('button, input, textarea, select, a[href], [tabindex="0"]')].filter(
          (x) => !x.hasAttribute('disabled'),
        )
        if (!items.length) return
        const [a, b] = [items[0], items[items.length - 1]]
        if (e.shiftKey && document.activeElement === a) {
          e.preventDefault()
          b.focus()
        } else if (!e.shiftKey && document.activeElement === b) {
          e.preventDefault()
          a.focus()
        }
      }
    }
    document.addEventListener('keydown', onKey)
    return () => {
      document.removeEventListener('keydown', onKey)
      prev?.focus?.()
    }
  }, [onClose])
  return (
    <div className="scrim" onMouseDown={(e) => e.target === e.currentTarget && onClose()}>
      <div
        className="sheet"
        role="dialog"
        aria-modal="true"
        aria-label={title}
        ref={ref}
        tabIndex={-1}
        style={wide ? { maxWidth: 560 } : undefined}
      >
        <div className="grabber" aria-hidden="true" />
        <div className="sheet-head">
          <h2>{title}</h2>
          <button className="icon-btn" onClick={onClose} aria-label="Fermer">
            <Close />
          </button>
        </div>
        {children}
      </div>
    </div>
  )
}

export function timeLabel(ts: number): string {
  const d = new Date(ts)
  const now = new Date()
  if (d.toDateString() === now.toDateString())
    return d.toLocaleTimeString('fr-FR', { hour: '2-digit', minute: '2-digit' })
  const y = new Date(now)
  y.setDate(now.getDate() - 1)
  if (d.toDateString() === y.toDateString()) return 'hier'
  if (now.getTime() - ts < 6 * 864e5) return d.toLocaleDateString('fr-FR', { weekday: 'short' })
  return d.toLocaleDateString('fr-FR', { day: 'numeric', month: 'short' })
}

export function dayLabel(ts: number): string {
  const d = new Date(ts)
  const now = new Date()
  const hm = d.toLocaleTimeString('fr-FR', { hour: '2-digit', minute: '2-digit' })
  if (d.toDateString() === now.toDateString()) return `AUJOURD'HUI ${hm}`
  const y = new Date(now)
  y.setDate(now.getDate() - 1)
  if (d.toDateString() === y.toDateString()) return `HIER ${hm}`
  return `${d.toLocaleDateString('fr-FR', { weekday: 'long', day: 'numeric', month: 'long' }).toUpperCase()} ${hm}`
}

export async function copyText(text: string): Promise<boolean> {
  try {
    await navigator.clipboard.writeText(text)
    return true
  } catch {
    return false
  }
}

export function downloadBlob(blob: Blob, name: string) {
  const url = URL.createObjectURL(blob)
  const a = document.createElement('a')
  a.href = url
  a.download = name
  document.body.appendChild(a)
  a.click()
  a.remove()
  setTimeout(() => URL.revokeObjectURL(url), 2000)
}
