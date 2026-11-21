// Message menu: right click, long press or the "···" button. A reaction strip on top, then
// the actions. Arrow keys move, Escape closes, focus returns to where it was.

import { useEffect, useLayoutEffect, useRef, useState } from 'react'
import { createPortal } from 'react-dom'
import { relay } from '../state/relay'
import type { ChatMessage } from '../state/types'
import { Copy, Forward, Info, Pencil, Plus, Reply, Trash } from './Icons'
import { copyText } from './common'

export const QUICK_REACTIONS = ['👍', '❤️', '😂', '😮', '😢', '🙏']
const MORE_REACTIONS = [
  '🔥', '🎉', '👏', '😍', '🥲', '😅', '🤔', '😎', '🙌', '💯', '✅', '❌',
  '👀', '🤝', '💪', '🥳', '😴', '🤯', '😡', '🤗', '🫶', '⭐', '🍀', '☕',
]

export type MenuAction = 'reply' | 'forward' | 'edit' | 'info' | 'delete-me' | 'delete-all'

export function MessageMenu({
  m,
  x,
  y,
  onAction,
  onClose,
}: {
  m: ChatMessage
  x: number
  y: number
  onAction: (a: MenuAction, m: ChatMessage) => void
  onClose: () => void
}) {
  const ref = useRef<HTMLDivElement>(null)
  const [more, setMore] = useState(false)
  const [pos, setPos] = useState({ left: x, top: y })
  const mine = m.from === 'me'
  const myReaction = Object.entries(m.reactions ?? {}).find(([, who]) => who.includes('me'))?.[0]

  useLayoutEffect(() => {
    const el = ref.current
    if (!el) return
    // offsetWidth/Height ignore the scale of the opening animation.
    const w = el.offsetWidth
    const h = el.offsetHeight
    const pad = 10
    setPos({
      left: Math.max(pad, Math.min(x, innerWidth - w - pad)),
      top: Math.max(pad, Math.min(y, innerHeight - h - pad)),
    })
  }, [x, y, more])

  useEffect(() => {
    const prev = document.activeElement as HTMLElement | null
    ref.current?.querySelector<HTMLElement>('[role="menuitem"]')?.focus()
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') {
        e.stopPropagation()
        onClose()
        return
      }
      if (e.key !== 'ArrowDown' && e.key !== 'ArrowUp' && e.key !== 'ArrowLeft' && e.key !== 'ArrowRight') return
      const items = [...(ref.current?.querySelectorAll<HTMLElement>('[role="menuitem"]') ?? [])]
      const i = items.indexOf(document.activeElement as HTMLElement)
      const step = e.key === 'ArrowDown' || e.key === 'ArrowRight' ? 1 : -1
      items[(i + step + items.length) % items.length]?.focus()
      e.preventDefault()
    }
    document.addEventListener('keydown', onKey, true)
    return () => {
      document.removeEventListener('keydown', onKey, true)
      prev?.focus?.()
    }
  }, [onClose])

  const react = (emoji: string) => {
    void relay.react(m.convId, m.id, emoji)
    navigator.vibrate?.(8)
    onClose()
  }
  const act = (a: MenuAction) => {
    onClose()
    onAction(a, m)
  }
  const copyable =
    m.kind === 'text' ? m.text : m.kind === 'location' && m.location ? `${m.location.lat}, ${m.location.lon}` : m.kind === 'poll' ? m.poll?.question : undefined
  const canReact = !m.deleted && m.kind !== 'system' && m.kind !== 'call'

  // Portal: a transformed or blurred ancestor would turn position: fixed into local coordinates.
  return createPortal(
    <div className="menu-scrim" onMouseDown={(e) => e.target === e.currentTarget && onClose()} onContextMenu={(e) => e.preventDefault()}>
      <div className="msg-menu glass" ref={ref} role="menu" aria-label="Actions du message" style={{ left: pos.left, top: pos.top }}>
        {canReact && (
          <div className="react-strip" role="group" aria-label="Réactions">
            {QUICK_REACTIONS.map((r) => (
              <button key={r} role="menuitem" className={myReaction === r ? 'on' : ''} aria-label={`Réagir ${r}`} onClick={() => react(r)}>
                {r}
              </button>
            ))}
            <button role="menuitem" aria-label="Autres réactions" aria-expanded={more} onClick={() => setMore((v) => !v)}>
              <Plus size={18} />
            </button>
          </div>
        )}
        {more && (
          <div className="react-grid" role="group" aria-label="Toutes les réactions">
            {MORE_REACTIONS.map((r) => (
              <button key={r} role="menuitem" aria-label={`Réagir ${r}`} onClick={() => react(r)}>
                {r}
              </button>
            ))}
          </div>
        )}
        <div className="menu-items">
          {!m.deleted && m.kind !== 'call' && (
            <button role="menuitem" onClick={() => act('reply')}>
              <Reply /> Répondre
            </button>
          )}
          {copyable && (
            <button
              role="menuitem"
              onClick={() => {
                void copyText(copyable).then((ok) => relay.toast(ok ? 'Copié.' : 'Copie impossible.'))
                onClose()
              }}
            >
              <Copy /> Copier
            </button>
          )}
          {!m.deleted && m.kind !== 'call' && (
            <button role="menuitem" onClick={() => act('forward')}>
              <Forward /> Transférer
            </button>
          )}
          {relay.canEdit(m) && (
            <button role="menuitem" onClick={() => act('edit')}>
              <Pencil /> Modifier
            </button>
          )}
          <button role="menuitem" onClick={() => act('info')}>
            <Info /> Infos
          </button>
          <button role="menuitem" className="danger" onClick={() => act('delete-me')}>
            <Trash /> Supprimer pour moi
          </button>
          {mine && !m.deleted && m.kind !== 'call' && (
            <button role="menuitem" className="danger" onClick={() => act('delete-all')}>
              <Trash /> Supprimer pour tous
            </button>
          )}
        </div>
      </div>
    </div>,
    document.body,
  )
}
