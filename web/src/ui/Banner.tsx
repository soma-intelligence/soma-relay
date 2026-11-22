// In-app banner (spec v1.2 section 6): a message arrived in another conversation than the open
// one. Glass, at the top; click opens, drag or swipe up dismisses, hides after 4 s, the timer
// pauses while hovered or focused.

import { useEffect, useRef, useState } from 'react'
import { relay } from '../state/relay'
import { Avatar, useRelay } from './common'
import { Close } from './Icons'

const SHOW_MS = 4000

export function MessageBanner({ onOpen }: { onOpen: (convId: string, msgId: string) => void }) {
  const snap = useRelay()
  const b = snap.banner
  const [leaving, setLeaving] = useState(false)
  const [dy, setDy] = useState(0)
  const drag = useRef<{ id: number; y: number; moved: boolean } | null>(null)
  const paused = useRef(false)
  const left = useRef(SHOW_MS)
  const startedAt = useRef(0)
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null)
  const seq = b?.seq

  const dismiss = () => {
    if (!b) return
    const s = b.seq
    setLeaving(true)
    setTimeout(() => relay.dismissBanner(s), matchMedia('(prefers-reduced-motion: reduce)').matches ? 0 : 220)
  }

  const arm = (ms: number) => {
    if (timer.current) clearTimeout(timer.current)
    startedAt.current = Date.now()
    left.current = ms
    timer.current = setTimeout(dismiss, ms)
  }
  const pause = () => {
    if (paused.current) return
    paused.current = true
    if (timer.current) clearTimeout(timer.current)
    left.current = Math.max(800, left.current - (Date.now() - startedAt.current))
  }
  const resume = () => {
    if (!paused.current) return
    paused.current = false
    arm(left.current)
  }

  useEffect(() => {
    if (seq === undefined) return
    setLeaving(false)
    setDy(0)
    paused.current = false
    arm(SHOW_MS)
    return () => {
      if (timer.current) clearTimeout(timer.current)
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [seq])

  if (!b) return null
  return (
    <div className="banner-wrap" aria-live="polite">
      <div
        key={b.seq}
        className={`banner glass${leaving ? ' leaving' : ''}`}
        style={dy ? { transform: `translateY(${dy}px)`, opacity: Math.max(0, 1 + dy / 90), transition: 'none' } : undefined}
        onMouseEnter={pause}
        onMouseLeave={resume}
        onFocus={pause}
        onBlur={resume}
        onPointerDown={(e) => {
          if ((e.target as HTMLElement).closest('.banner-close')) return
          drag.current = { id: e.pointerId, y: e.clientY, moved: false }
          ;(e.currentTarget as HTMLElement).setPointerCapture(e.pointerId)
          pause()
        }}
        onPointerMove={(e) => {
          const d = drag.current
          if (!d || d.id !== e.pointerId) return
          const delta = e.clientY - d.y
          if (Math.abs(delta) > 4) d.moved = true
          setDy(delta < 0 ? delta : delta * 0.2)
        }}
        onPointerUp={(e) => {
          const d = drag.current
          drag.current = null
          if (!d) return
          if (dy < -36) {
            dismiss()
            return
          }
          setDy(0)
          if (!d.moved && !(e.target as HTMLElement).closest('.banner-close')) {
            relay.dismissBanner(b.seq)
            onOpen(b.convId, b.msgId)
          } else resume()
        }}
        onPointerCancel={() => {
          drag.current = null
          setDy(0)
          resume()
        }}
      >
        <button
          className="banner-main"
          onClick={(e) => {
            // Keyboard activation (pointer clicks are handled on pointerup).
            if (e.detail === 0) {
              relay.dismissBanner(b.seq)
              onOpen(b.convId, b.msgId)
            }
          }}
          aria-label={`Nouveau message de ${b.title} : ${b.text}. Ouvrir la discussion`}
        >
          <Avatar id={b.avatarId} name={b.title} group={b.avatarId.startsWith('g:')} size={40} />
          <span className="banner-text">
            <b>{b.title}</b>
            <span>{b.text}</span>
          </span>
        </button>
        <button className="banner-close icon-btn plain" aria-label="Masquer la notification" onClick={dismiss}>
          <Close size={16} />
        </button>
      </div>
    </div>
  )
}
