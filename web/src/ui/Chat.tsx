import { lazy, Suspense, useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react'
import { MediaViewer } from './MediaViewer'
import { expireLabel, relay } from '../state/relay'
import type { ChatMessage } from '../state/types'
import type { LinkPreview } from '../core/engine'
import { firstUrl } from '../state/sanitize'
import { prepareDocument, prepareImage, prepareVideo, VoiceRecorder, formatDuration } from '../media/media'
import { Avatar, useRelay } from './common'
import { CameraCapture } from './Camera'
import { MessageItem, type MessageHandlers, type RunPos } from './Message'
import { MessageMenu, type MenuAction } from './MessageMenu'
import { ForwardSheet, InfoSheet, LocationSheet, PollSheet } from './ChatSheets'
import { LinkCard } from './Rich'
import {
  ArrowDown,
  Back,
  Camera,
  Chevron,
  ChevronDown,
  ChevronUp,
  Close,
  File,
  Image,
  Mic,
  Pencil,
  Phone,
  Pin,
  Plus,
  Poll,
  Search,
  Send,
  Timer,
  Video,
} from './Icons'
import { fpShort } from '../lib/bytes'

const DocViewer = lazy(() => import('./DocViewer'))
const MapView = lazy(() => import('./MapView'))

const RUN_GAP_MS = 5 * 60_000
const reducedMotion = () => matchMedia('(prefers-reduced-motion: reduce)').matches

function Radar({ live, peers, direct }: { live: boolean; peers: number; direct: boolean }) {
  const dots = [
    [54, 26],
    [20, 50],
    [58, 56],
    [24, 20],
  ].slice(0, Math.min(4, peers))
  return (
    <svg width="52" height="52" viewBox="0 0 76 76" role="img" aria-label={live ? 'Radar : contact joignable' : 'Radar : contact hors ligne'}>
      <circle cx="38" cy="38" r="36" fill="none" stroke="var(--radar-line)" />
      <circle cx="38" cy="38" r="22" fill="none" stroke="var(--radar-line)" />
      {live && <path className="radar-sweep" d="M38 38 L38 2 A36 36 0 0 1 63.5 12.5 Z" fill="var(--mesh)" opacity="0.08" />}
      <circle cx="38" cy="38" r="4" fill="var(--fg)" />
      {dots.map(([x, y]) => (
        <circle key={`${x}-${y}`} cx={x} cy={y} r="3.5" fill="var(--radar-dot)" />
      ))}
      <circle className={`radar-peer${live ? ' live' : ''}`} cx="64" cy="14" r="5" fill={live ? 'var(--mesh)' : 'var(--radar-dot)'} />
      <path
        d={direct ? 'M38 38L64 14' : 'M38 38L54 26L64 14'}
        stroke={live ? 'var(--mesh)' : 'var(--radar-dot)'}
        strokeWidth="2"
        fill="none"
        strokeDasharray="3 3"
      />
    </svg>
  )
}

/** "Aujourd'hui", "Hier", the weekday within a week, else the date. */
export function daySeparator(ts: number): string {
  const d = new Date(ts)
  const now = new Date()
  const start = (x: Date) => new Date(x.getFullYear(), x.getMonth(), x.getDate()).getTime()
  const days = Math.round((start(now) - start(d)) / 864e5)
  if (days === 0) return 'Aujourd’hui'
  if (days === 1) return 'Hier'
  if (days > 1 && days < 7) {
    const w = d.toLocaleDateString('fr-FR', { weekday: 'long' })
    return w[0].toUpperCase() + w.slice(1)
  }
  return d.toLocaleDateString('fr-FR', { day: 'numeric', month: 'long', year: d.getFullYear() === now.getFullYear() ? undefined : 'numeric' })
}

const SENDER_COLORS = ['#c2410c', '#0f766e', '#7c3aed', '#be185d', '#1d4ed8', '#15803d', '#b45309', '#0e7490']
export function senderColor(fp: string): string {
  let h = 0
  for (const c of fp) h = (h * 31 + c.charCodeAt(0)) >>> 0
  return SENDER_COLORS[h % SENDER_COLORS.length]
}

const groupable = (m: ChatMessage) => m.kind !== 'system' && m.kind !== 'call'

type ChatSheet = { kind: 'poll' } | { kind: 'location' } | { kind: 'forward'; m: ChatMessage } | { kind: 'info'; m: ChatMessage } | null

export function ChatView({
  convId,
  onBack,
  onInfo,
  showBack,
}: {
  convId: string
  onBack: () => void
  onInfo: () => void
  showBack: boolean
}) {
  const snap = useRelay()
  const isGroup = convId.startsWith('g:')
  const contact = isGroup ? undefined : snap.contacts.find((c) => c.fingerprint === convId)
  const group = isGroup ? snap.groups.find((g) => g.id === convId.slice(2)) : undefined
  const conv = snap.conversations.find((c) => c.id === convId)
  const title = relay.titleOf(convId)
  const messages = useMemo(() => snap.messages[convId] ?? [], [snap.messages, convId])
  const online = !!contact && snap.online.has(contact.mailbox)
  const p2p = !isGroup && snap.p2pOpen.has(convId)
  const nodeOnline = snap.node === 'online' || snap.localBus
  const [pathOpen, setPathOpen] = useState(false)
  const [menu, setMenu] = useState<{ m: ChatMessage; x: number; y: number } | null>(null)
  const [replyTo, setReplyTo] = useState<ChatMessage | null>(null)
  const [editing, setEditing] = useState<ChatMessage | null>(null)
  const [lightbox, setLightbox] = useState<{ url: string; kind: 'image' | 'video' } | null>(null)
  const [doc, setDoc] = useState<ChatMessage | null>(null)
  const [mapMsg, setMapMsg] = useState<ChatMessage | null>(null)
  const [sheet, setSheet] = useState<ChatSheet>(null)
  const [flash, setFlash] = useState<string | null>(null)
  const [search, setSearch] = useState<{ q: string; idx: number } | null>(null)
  const [atBottom, setAtBottom] = useState(true)
  const [newCount, setNewCount] = useState(0)
  const scroller = useRef<HTMLDivElement>(null)
  const stick = useRef(true)
  const mountedAt = useRef(Date.now())
  // Unread separator: the number of unread messages when the conversation opened.
  const unreadAtOpen = useRef(relay.getSnapshot().conversations.find((c) => c.id === convId)?.unread ?? 0)
  const [firstUnread, setFirstUnread] = useState<string | null>(null)

  useEffect(() => {
    void relay.openConversation(convId)
  }, [convId])

  useEffect(() => {
    if (firstUnread || !unreadAtOpen.current || !messages.length) return
    const incoming = messages.filter((m) => m.from !== 'me' && groupable(m))
    const first = incoming[Math.max(0, incoming.length - unreadAtOpen.current)]
    if (first) {
      setFirstUnread(first.id)
      stick.current = false
      requestAnimationFrame(() => {
        scroller.current?.querySelector('.unread-sep')?.scrollIntoView({ block: 'start' })
      })
    }
  }, [messages, firstUnread])

  // Count incoming messages that arrive while scrolled up.
  const lastLen = useRef(messages.length)
  useEffect(() => {
    const added = messages.slice(lastLen.current)
    lastLen.current = messages.length
    if (!stick.current && added.some((m) => m.from !== 'me')) setNewCount((n) => n + added.filter((m) => m.from !== 'me').length)
    if (added.some((m) => m.from === 'me')) stick.current = true
  }, [messages])

  useLayoutEffect(() => {
    const el = scroller.current
    if (el && stick.current) el.scrollTop = el.scrollHeight
  }, [messages, convId])

  const onScroll = () => {
    const el = scroller.current
    if (!el) return
    const bottom = el.scrollHeight - el.scrollTop - el.clientHeight < 80
    stick.current = bottom
    if (bottom !== atBottom) setAtBottom(bottom)
    if (bottom && newCount) setNewCount(0)
  }

  const toBottom = () => {
    const el = scroller.current
    if (!el) return
    stick.current = true
    el.scrollTo({ top: el.scrollHeight, behavior: reducedMotion() ? 'auto' : 'smooth' })
    setNewCount(0)
  }

  const scrollToMessage = useCallback((id: string) => {
    const el = scroller.current?.querySelector<HTMLElement>(`[data-id="${CSS.escape(id)}"]`)
    if (!el) {
      relay.toast('Message introuvable dans l’historique chargé.')
      return
    }
    stick.current = false
    el.scrollIntoView({ block: 'center', behavior: reducedMotion() ? 'auto' : 'smooth' })
    setFlash(null)
    requestAnimationFrame(() => setFlash(id))
    setTimeout(() => setFlash((f) => (f === id ? null : f)), 1600)
  }, [])

  // A search result or a notification asked for a message.
  useEffect(() => {
    const j = snap.jump
    if (!j || j.convId !== convId || !messages.some((m) => m.id === j.id)) return
    relay.clearJump()
    requestAnimationFrame(() => scrollToMessage(j.id))
  }, [snap.jump, messages, convId, scrollToMessage])

  const typingNow = Object.entries(snap.typing).some(([k, until]) => k.startsWith(convId + '|') && until > Date.now())
  const [, tick] = useState(0)
  useEffect(() => {
    if (!typingNow) return
    const t = setTimeout(() => tick((x) => x + 1), 6100)
    return () => clearTimeout(t)
  }, [typingNow, snap.typing])

  const byId = useMemo(() => new Map(messages.map((m) => [m.id, m])), [messages])
  // Names come from contacts, then from received profiles (members who are not contacts).
  const nameOf = useCallback((fp: string) => relay.nameOf(fp), [])
  const me = snap.me?.fingerprint
  const members = useMemo(
    () => (group ? group.members.filter((fp) => fp !== me).map((fp) => ({ fp, name: nameOf(fp) })) : []),
    [group, me, nameOf],
  )
  const mentionNames = useMemo(() => [...members.map((x) => x.name), snap.me?.name ?? ''].filter(Boolean), [members, snap.me?.name])

  // In-conversation search
  const hits = useMemo(() => {
    const q = search?.q.trim().toLowerCase()
    if (!q || q.length < 2) return []
    return messages
      .filter((m) => !m.deleted && (m.kind === 'text' ? m.text : m.kind === 'poll' ? m.poll?.question : m.kind === 'file' ? m.attachment?.name : '')?.toLowerCase().includes(q))
      .map((m) => m.id)
  }, [messages, search?.q])
  // idx -1 = the newest hit. Up and Enter go to older hits, down and Shift+Enter to newer ones.
  const cur = search && hits.length ? (search.idx < 0 ? hits.length - 1 : Math.min(search.idx, hits.length - 1)) : -1
  const step = (d: number) => {
    if (!search || !hits.length) return
    setSearch({ ...search, idx: (cur + d + hits.length) % hits.length })
  }
  useEffect(() => {
    if (cur < 0) return
    const id = hits[cur]
    if (id) scrollToMessage(id)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [cur, hits.length])

  const handlers = useMemo<MessageHandlers>(
    () => ({
      onMenu: (m, x, y) => setMenu({ m, x, y }),
      onReply: (m) => {
        setEditing(null)
        setReplyTo(m)
      },
      onOpenMedia: (url, kind) => setLightbox({ url, kind }),
      onOpenDoc: (m) => setDoc(m),
      onOpenMap: (m) => setMapMsg(m),
      onJump: (id) => scrollToMessage(id),
      nameOf,
    }),
    [nameOf, scrollToMessage],
  )

  const onMenuAction = useCallback(
    (a: MenuAction, m: ChatMessage) => {
      switch (a) {
        case 'reply':
          setEditing(null)
          setReplyTo(m)
          break
        case 'forward':
          setSheet({ kind: 'forward', m })
          break
        case 'edit':
          setReplyTo(null)
          setEditing(m)
          break
        case 'info':
          setSheet({ kind: 'info', m })
          break
        case 'delete-me':
          void relay.deleteForMe(m.convId, m.id)
          break
        case 'delete-all':
          void relay.deleteForEveryone(m.convId, m.id)
          break
      }
    },
    [],
  )

  const editLast = useCallback(() => {
    const last = [...messages].reverse().find((m) => relay.canEdit(m))
    if (last) {
      setReplyTo(null)
      setEditing(last)
    }
  }, [messages])

  let chain: string
  let headline: string
  if (isGroup) {
    headline = `${group?.members.length ?? 0} membres · chiffré`
    chain = nodeOnline ? `toi → nœud → ${group?.members.length ? group.members.length - 1 : 0} boîtes` : 'hors ligne · en file d’attente'
  } else if (p2p) {
    headline = 'Lien direct, pair à pair'
    chain = `toi → ${title} · P2P`
  } else if (snap.node !== 'online' && snap.localBus) {
    headline = online ? 'Bus local du navigateur' : 'Bus local, contact absent'
    chain = `toi → bus local → ${title} · test`
  } else if (nodeOnline && online) {
    headline = 'En ligne par le nœud'
    chain = `toi → nœud → ${title} · 1 relais`
  } else if (nodeOnline) {
    headline = 'Boîte aux lettres sur le nœud'
    chain = `toi → nœud ⇢ ${title} · à la reconnexion`
  } else {
    headline = 'Hors ligne'
    chain = `en file d’attente · ${snap.outboxCount} en route`
  }

  const host = (() => {
    try {
      return new URL(snap.nodeBase).host
    } catch {
      return snap.nodeBase
    }
  })()

  // Bubbles with day separators, the unread line and grouped runs.
  const items: React.ReactNode[] = []
  let prevDay = ''
  const startOfRun = (m: ChatMessage, prev?: ChatMessage) =>
    !prev || !groupable(prev) || !groupable(m) || prev.from !== m.from || m.ts - prev.ts > RUN_GAP_MS || m.id === firstUnread || new Date(prev.ts).toDateString() !== new Date(m.ts).toDateString()
  const hl = search && search.q.trim().length >= 2 ? search.q : undefined
  messages.forEach((m, i) => {
    const day = new Date(m.ts).toDateString()
    if (day !== prevDay) {
      items.push(
        <div className="day" key={`d-${m.id}`} role="separator">
          <span>{daySeparator(m.ts)}</span>
          {prevDay === '' && <small>{snap.engineKind === 'mock' ? 'CHIFFREMENT SIMULÉ' : 'ML-KEM-1024 + X25519'}</small>}
        </div>,
      )
      prevDay = day
    }
    if (m.id === firstUnread)
      items.push(
        <div className="unread-sep" key="unread" role="separator">
          <span>
            {unreadAtOpen.current} nouveau{unreadAtOpen.current > 1 ? 'x' : ''} message{unreadAtOpen.current > 1 ? 's' : ''}
          </span>
        </div>,
      )
    const prev = messages[i - 1]
    const next = messages[i + 1]
    const first = startOfRun(m, prev)
    const last = !next || startOfRun(next, m)
    const pos: RunPos = first && last ? 'single' : first ? 'first' : last ? 'last' : 'mid'
    items.push(
      <MessageItem
        key={m.id}
        m={m}
        quoted={m.replyTo ? byId.get(m.replyTo) : undefined}
        senderName={isGroup && m.from !== 'me' ? nameOf(m.from) : undefined}
        senderFace={isGroup && m.from !== 'me' && (pos === 'last' || pos === 'single')}
        senderColor={isGroup && m.from !== 'me' ? senderColor(m.from) : undefined}
        isGroup={isGroup}
        pos={pos}
        showMeta={last}
        fresh={m.ts > mountedAt.current - 500 && (m.from === 'me' || !m.times?.received || m.times.received > mountedAt.current)}
        flash={flash === m.id}
        highlight={hl}
        mentionNames={isGroup ? mentionNames : []}
        h={handlers}
      />,
    )
  })

  const expire = conv?.expireS ?? 0
  return (
    <section className="chat" aria-label={`Discussion avec ${title}`}>
      <div className="chat-head">
        <header className="bar glass">
          {showBack ? (
            <button className="icon-btn" onClick={onBack} aria-label="Retour">
              <Back />
            </button>
          ) : (
            <span style={{ width: 44 }} />
          )}
          <button className="chat-title with-face" onClick={onInfo} aria-label={`Infos sur ${title}`}>
            <Avatar id={convId} name={title} group={isGroup} size={36} online={online} />
            <span className="chat-title-text">
            <span className="name">{title}</span>
            <span className="fp">
              {isGroup ? `${group?.members.length ?? 0} membres` : `fp ${fpShort(convId)} · ${contact?.verified ? 'vérifiée' : 'non vérifiée'}`}
              {expire ? (
                <span className="eph">
                  {' '}
                  · <Timer size={10} /> {expireLabel(expire)}
                </span>
              ) : null}
            </span>
            </span>
          </button>
          <button className="icon-btn" aria-label="Chercher dans la discussion" aria-pressed={!!search} onClick={() => setSearch((s) => (s ? null : { q: '', idx: -1 }))}>
            <Search />
          </button>
          {!isGroup && (
            <>
              <button className="icon-btn" aria-label="Appel vidéo" onClick={() => void relay.calls.start(convId, true)} disabled={!contact}>
                <Video />
              </button>
              <button className="icon-btn strong" aria-label="Appeler" onClick={() => void relay.calls.start(convId, false)} disabled={!contact}>
                <Phone />
              </button>
            </>
          )}
        </header>
        {search ? (
          <form
            className="chat-search glass"
            role="search"
            onSubmit={(e) => {
              e.preventDefault()
              step(-1)
            }}
          >
            <Search size={16} />
            <label htmlFor="chat-search" className="sr-only">
              Chercher dans la discussion
            </label>
            <input
              id="chat-search"
              type="search"
              autoFocus
              placeholder="Chercher"
              value={search.q}
              onChange={(e) => setSearch({ q: e.target.value, idx: -1 })}
              aria-keyshortcuts="Enter Shift+Enter ArrowUp ArrowDown Escape"
              onKeyDown={(e) => {
                if (e.key === 'Escape') {
                  e.preventDefault()
                  setSearch(null)
                } else if (e.key === 'Enter' && e.shiftKey) {
                  e.preventDefault()
                  step(1)
                } else if (e.key === 'ArrowUp' || e.key === 'ArrowDown') {
                  e.preventDefault()
                  step(e.key === 'ArrowUp' ? -1 : 1)
                }
              }}
            />
            <span className="hits" aria-live="polite" data-testid="search-count">
              {search.q.trim().length >= 2 ? (hits.length ? `${hits.length - cur} sur ${hits.length}` : 'Aucun') : ''}
            </span>
            <button type="button" className="icon-btn plain" aria-label="Résultat plus ancien" disabled={hits.length < 2} onClick={() => step(-1)}>
              <ChevronUp />
            </button>
            <button type="button" className="icon-btn plain" aria-label="Résultat plus récent" disabled={hits.length < 2} onClick={() => step(1)}>
              <ChevronDown />
            </button>
            <button type="button" className="icon-btn plain" aria-label="Fermer la recherche" onClick={() => setSearch(null)}>
              <Close size={16} />
            </button>
          </form>
        ) : (
          <div className="path" data-open={pathOpen}>
            <button className="path-toggle" aria-expanded={pathOpen} onClick={() => setPathOpen((v) => !v)}>
              <Radar live={p2p || (online && nodeOnline)} peers={isGroup ? (group?.members.length ?? 1) - 1 : 3} direct={p2p} />
              <span className="path-text">
                <span className="t">{headline}</span>
                <span className="chain">{chain}</span>
              </span>
              <Chevron className="chev" />
            </button>
            <div className="path-detail">
              <div>
                <dl>
                  <dt>Chiffrement</dt>
                  <dd>{snap.engineKind === 'mock' ? 'simulé (moteur de test)' : 'ML-KEM-1024 + X25519, AES-256-GCM'}</dd>
                  <dt>Transport</dt>
                  <dd>{p2p ? 'WebRTC data channel (P2P)' : snap.node === 'online' ? `nœud ${host}` : snap.localBus ? 'bus local du navigateur' : 'aucun, file d’attente'}</dd>
                  <dt>Nœud</dt>
                  <dd>{snap.node === 'online' ? 'en ligne' : snap.node === 'connecting' ? 'connexion…' : 'hors ligne'}</dd>
                  <dt>En route</dt>
                  <dd>
                    {snap.outboxCount} message{snap.outboxCount > 1 ? 's' : ''}
                  </dd>
                  {!isGroup && (
                    <>
                      <dt>Mesh</dt>
                      <dd>Bluetooth et Wi-Fi direct dans l’app iPhone seulement</dd>
                    </>
                  )}
                </dl>
              </div>
            </div>
          </div>
        )}
      </div>
      <div
        className={`messages${pathOpen && !search ? ' with-path-open' : ''}`}
        ref={scroller}
        onScroll={onScroll}
        role="log"
        aria-live="polite"
        aria-relevant="additions"
        aria-label="Messages"
      >
        {messages.length === 0 && (
          <div className="empty">
            {contact && !contact.verified
              ? 'Avant d’échanger des choses sensibles, comparez vos quatre mots de sécurité : touche son nom en haut.'
              : 'Écris le premier message. Il part chiffré de bout en bout.'}
          </div>
        )}
        {items}
        {typingNow && (
          <div className="typing-dots" role="status" aria-label={`${title} écrit`}>
            <span />
            <span />
            <span />
          </div>
        )}
      </div>
      {!atBottom && (
        <button className="to-bottom glass" onClick={toBottom} aria-label={newCount ? `${newCount} nouveaux messages, aller en bas` : 'Aller en bas'}>
          <ArrowDown />
          {newCount > 0 && <span className="badge">{newCount}</span>}
        </button>
      )}
      <Composer
        convId={convId}
        replyTo={replyTo}
        onClearReply={() => setReplyTo(null)}
        editing={editing}
        onClearEdit={() => setEditing(null)}
        onEditLast={editLast}
        onSheet={(k) => setSheet({ kind: k })}
        members={members}
      />
      {menu && <MessageMenu m={menu.m} x={menu.x} y={menu.y} onAction={onMenuAction} onClose={() => setMenu(null)} />}
      {sheet?.kind === 'poll' && <PollSheet convId={convId} onClose={() => setSheet(null)} />}
      {sheet?.kind === 'location' && <LocationSheet convId={convId} onClose={() => setSheet(null)} />}
      {sheet?.kind === 'forward' && <ForwardSheet m={sheet.m} onClose={() => setSheet(null)} />}
      {sheet?.kind === 'info' && <InfoSheet m={sheet.m} onClose={() => setSheet(null)} />}
      {lightbox && <MediaViewer url={lightbox.url} kind={lightbox.kind} onClose={() => setLightbox(null)} />}
      <Suspense fallback={<div className="lazy-veil"><span className="spinner" aria-label="Chargement" /></div>}>
        {doc && <DocViewer m={doc} onClose={() => setDoc(null)} />}
        {mapMsg && <MapView m={mapMsg} onClose={() => setMapMsg(null)} />}
      </Suspense>
    </section>
  )
}

function Composer({
  convId,
  replyTo,
  onClearReply,
  editing,
  onClearEdit,
  onEditLast,
  onSheet,
  members,
}: {
  convId: string
  replyTo: ChatMessage | null
  onClearReply: () => void
  editing: ChatMessage | null
  onClearEdit: () => void
  onEditLast: () => void
  onSheet: (k: 'poll' | 'location') => void
  members: { fp: string; name: string }[]
}) {
  const snap = useRelay()
  const conv = snap.conversations.find((c) => c.id === convId)
  const [text, setText] = useState(conv?.draft ?? '')
  const [menu, setMenu] = useState(false)
  const [recording, setRecording] = useState(false)
  const [elapsed, setElapsed] = useState(0)
  const [mention, setMention] = useState<{ q: string; at: number; sel: number } | null>(null)
  const [preview, setPreview] = useState<{ url: string; link: LinkPreview | null } | null>(null)
  const [dismissed, setDismissed] = useState<string | null>(null)
  const rec = useRef<VoiceRecorder | null>(null)
  const area = useRef<HTMLTextAreaElement>(null)
  const wave = useRef<HTMLCanvasElement>(null)
  const menuRef = useRef<HTMLDivElement>(null)
  const photoInput = useRef<HTMLInputElement>(null)
  const fileInput = useRef<HTMLInputElement>(null)
  const cameraInput = useRef<HTMLInputElement>(null)
  const savedDraft = useRef('')
  const coarse = useMemo(() => matchMedia('(pointer: coarse)').matches, [])
  const [camera, setCamera] = useState(false)

  /** Phones: the native camera. Desktop: live preview in a capture sheet. */
  const openCamera = () => {
    setMenu(false)
    if (coarse || typeof navigator.mediaDevices?.getUserMedia !== 'function') cameraInput.current?.click()
    else setCamera(true)
  }

  const sendShot = async (blob: Blob, caption: string) => {
    setCamera(false)
    try {
      const name = `photo-${new Date().toISOString().slice(0, 19).replace(/[:T]/g, '-')}.jpg`
      await relay.sendMedia(convId, 'image', await prepareImage(new globalThis.File([blob], name, { type: 'image/jpeg' })), name)
      if (caption) await relay.sendText(convId, caption)
    } catch (e) {
      relay.toast(e instanceof Error ? e.message : 'Envoi impossible.')
    }
  }

  useEffect(() => {
    setText(relay.getSnapshot().conversations.find((c) => c.id === convId)?.draft ?? '')
    if (matchMedia('(pointer: fine)').matches) area.current?.focus()
  }, [convId])

  useEffect(() => {
    if (replyTo) area.current?.focus()
  }, [replyTo])

  // Editing puts the message text in the composer and gives the draft back afterwards.
  const editId = editing?.id
  useEffect(() => {
    if (!editing) return
    savedDraft.current = area.current?.value ?? ''
    setText(editing.text ?? '')
    requestAnimationFrame(() => {
      const el = area.current
      if (el) {
        el.focus()
        el.setSelectionRange(el.value.length, el.value.length)
      }
    })
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [editId])

  useLayoutEffect(() => {
    const el = area.current
    if (!el) return
    el.style.height = 'auto'
    el.style.height = Math.min(154, el.scrollHeight) + 'px'
  }, [text])

  useEffect(() => {
    return () => {
      if (editId) return
      void relay.setDraft(convId, area.current?.value ?? '')
    }
  }, [convId, editId])

  // Link preview of the first URL, asked to the node while typing (sender side only).
  const url = snap.settings.linkPreviews && !editing ? firstUrl(text) : null
  useEffect(() => {
    if (!url || url === dismissed) {
      setPreview(null)
      return
    }
    if (preview?.url === url) return
    const t = setTimeout(() => {
      setPreview({ url, link: null })
      void relay.linkPreview(url).then((link) => setPreview((p) => (p?.url === url ? { url, link } : p)))
    }, 500)
    return () => clearTimeout(t)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [url, dismissed])

  // Close the attachment menu on an outside click.
  useEffect(() => {
    if (!menu) return
    const onDown = (e: PointerEvent) => {
      if (!menuRef.current?.contains(e.target as Node) && !(e.target as HTMLElement).closest('[aria-label="Joindre"]')) setMenu(false)
    }
    document.addEventListener('pointerdown', onDown)
    requestAnimationFrame(() => menuRef.current?.querySelector<HTMLElement>('[role="menuitem"]')?.focus())
    return () => document.removeEventListener('pointerdown', onDown)
  }, [menu])

  const mentionList = mention ? members.filter((x) => x.name.toLowerCase().startsWith(mention.q.toLowerCase())).slice(0, 6) : []

  const updateMention = (value: string, caret: number) => {
    if (!members.length) return setMention(null)
    const before = value.slice(0, caret)
    const m = before.match(/(^|\s)@([^\s@]{0,24})$/)
    setMention(m ? { q: m[2], at: caret - m[2].length - 1, sel: 0 } : null)
  }

  const pickMention = (name: string) => {
    if (!mention) return
    const el = area.current
    const caret = el?.selectionStart ?? text.length
    const next = text.slice(0, mention.at) + '@' + name + ' ' + text.slice(caret)
    setText(next)
    setMention(null)
    requestAnimationFrame(() => {
      const pos = mention.at + name.length + 2
      el?.focus()
      el?.setSelectionRange(pos, pos)
    })
  }

  const send = async () => {
    const body = text.trim()
    if (!body) return
    setText('')
    setMention(null)
    area.current?.focus()
    if (editing) {
      const id = editing.id
      onClearEdit()
      setText(savedDraft.current)
      await relay.editMessage(convId, id, body)
      return
    }
    const reply = replyTo?.id
    onClearReply()
    const mentions = members.filter((x) => body.includes('@' + x.name)).map((x) => x.fp)
    let link: LinkPreview | null = null
    const u = snap.settings.linkPreviews ? firstUrl(body) : null
    if (u && u !== dismissed) {
      link = preview?.url === u && preview.link ? preview.link : await Promise.race([relay.linkPreview(u), new Promise<null>((r) => setTimeout(() => r(null), 1500))])
    }
    setPreview(null)
    setDismissed(null)
    await relay.sendText(convId, body, reply, { link: link ?? undefined, mentions })
  }

  const onFiles = async (files: FileList | null, mode: 'media' | 'file') => {
    setMenu(false)
    if (!files) return
    for (const f of Array.from(files)) {
      try {
        if (mode === 'media' && f.type.startsWith('image/')) await relay.sendMedia(convId, 'image', await prepareImage(f), f.name)
        else if (mode === 'media' && f.type.startsWith('video/')) await relay.sendMedia(convId, 'video', await prepareVideo(f), f.name)
        else await relay.sendMedia(convId, 'file', await prepareDocument(f), f.name)
      } catch (e) {
        relay.toast(e instanceof Error ? e.message : 'Envoi impossible.')
      }
    }
  }

  const startRec = async () => {
    const r = new VoiceRecorder()
    try {
      await r.start()
    } catch {
      relay.toast('Micro indisponible ou refusé.')
      return
    }
    rec.current = r
    setRecording(true)
    setElapsed(0)
    const draw = () => {
      if (!rec.current) return
      setElapsed(rec.current.elapsed)
      const c = wave.current
      const an = rec.current.analyser
      if (c && an) {
        const ctx = c.getContext('2d')!
        const w = (c.width = c.clientWidth * devicePixelRatio)
        const h = (c.height = c.clientHeight * devicePixelRatio)
        const data = new Uint8Array(an.frequencyBinCount)
        an.getByteFrequencyData(data)
        ctx.clearRect(0, 0, w, h)
        ctx.fillStyle = getComputedStyle(c).color
        const bars = 32
        const bw = w / bars
        for (let i = 0; i < bars; i++) {
          const v = data[Math.floor((i / bars) * data.length * 0.6)] / 255
          const bh = Math.max(2 * devicePixelRatio, v * h)
          ctx.globalAlpha = 0.35 + v * 0.65
          ctx.beginPath()
          ctx.roundRect(i * bw + bw * 0.2, (h - bh) / 2, bw * 0.6, bh, bw * 0.3)
          ctx.fill()
        }
      }
      requestAnimationFrame(draw)
    }
    requestAnimationFrame(draw)
  }

  const stopRec = async (sendIt: boolean) => {
    const r = rec.current
    rec.current = null
    setRecording(false)
    if (!r) return
    if (!sendIt) {
      r.cancel()
      return
    }
    const media = await r.stop()
    if (media) await relay.sendMedia(convId, 'audio', media, 'note-vocale')
  }

  const hasText = text.trim().length > 0
  const sendMode = hasText || !!editing
  const pick = (fn: () => void) => () => {
    setMenu(false)
    fn()
  }
  return (
    <div className="composer-wrap">
      {mention && mentionList.length > 0 && (
        <div className="mention-list glass" role="listbox" aria-label="Mentionner">
          {mentionList.map((x, i) => (
            <button
              key={x.fp}
              role="option"
              aria-selected={i === mention.sel}
              onMouseDown={(e) => {
                e.preventDefault()
                pickMention(x.name)
              }}
            >
              @{x.name}
            </button>
          ))}
        </div>
      )}
      {preview && (
        <div className="link-draft glass">
          {preview.link ? <LinkCard link={preview.link} /> : <span className="hint mono">aperçu du lien…</span>}
          <button className="icon-btn plain" aria-label="Retirer l’aperçu du lien" onClick={() => setDismissed(preview.url)}>
            <Close size={16} />
          </button>
        </div>
      )}
      {editing && (
        <div className="reply-bar glass">
          <Pencil />
          <span className="txt">
            <b>Modifier le message</b>
            {editing.text}
          </span>
          <button
            className="icon-btn plain"
            onClick={() => {
              onClearEdit()
              setText(savedDraft.current)
            }}
            aria-label="Annuler la modification"
          >
            <Close size={16} />
          </button>
        </div>
      )}
      {replyTo && !editing && (
        <div className="reply-bar glass">
          <span className="txt">
            <b>Réponse à {replyTo.from === 'me' ? 'toi' : relay.titleOf(replyTo.from)}</b>
            {replyTo.text ?? (replyTo.kind === 'poll' ? replyTo.poll?.question : replyTo.kind === 'location' ? 'Position' : 'Pièce jointe')}
          </span>
          <button className="icon-btn plain" onClick={onClearReply} aria-label="Annuler la réponse">
            <Close size={16} />
          </button>
        </div>
      )}
      {menu && (
        <div
          className="attach-menu glass"
          role="menu"
          ref={menuRef}
          aria-label="Joindre"
          onKeyDown={(e) => {
            if (e.key === 'Escape') {
              e.stopPropagation()
              setMenu(false)
              area.current?.focus()
            }
            if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
              e.preventDefault()
              const items = [...(menuRef.current?.querySelectorAll<HTMLElement>('[role="menuitem"]') ?? [])]
              const i = items.indexOf(document.activeElement as HTMLElement)
              items[(i + (e.key === 'ArrowDown' ? 1 : -1) + items.length) % items.length]?.focus()
            }
          }}
        >
          <button role="menuitem" onClick={() => photoInput.current?.click()}>
            <span className="am-ico am-photo">
              <Image />
            </span>
            Photo ou vidéo
          </button>
          <button role="menuitem" onClick={openCamera}>
            <span className="am-ico am-camera">
              <Camera />
            </span>
            Appareil photo
          </button>
          <button role="menuitem" onClick={() => fileInput.current?.click()}>
            <span className="am-ico am-doc">
              <File />
            </span>
            Document
          </button>
          <button role="menuitem" onClick={pick(() => onSheet('location'))}>
            <span className="am-ico am-loc">
              <Pin />
            </span>
            Position
          </button>
          <button role="menuitem" onClick={pick(() => onSheet('poll'))}>
            <span className="am-ico am-poll">
              <Poll />
            </span>
            Sondage
          </button>
        </div>
      )}
      <form
        className="composer bar glass"
        onSubmit={(e) => {
          e.preventDefault()
          void send()
        }}
      >
        {recording ? (
          <>
            <button type="button" className="icon-btn" onClick={() => void stopRec(false)} aria-label="Annuler l’enregistrement">
              <Close />
            </button>
            <div className="rec" aria-live="polite">
              <span className="dot" aria-hidden="true" />
              <span>{formatDuration(elapsed)}</span>
              <canvas ref={wave} aria-hidden="true" style={{ color: 'var(--fg)' }} />
            </div>
            <button type="button" className="icon-btn strong" onClick={() => void stopRec(true)} aria-label="Envoyer la note vocale">
              <Send />
            </button>
          </>
        ) : (
          <>
            <button
              type="button"
              className="icon-btn attach-btn"
              aria-label="Joindre"
              aria-expanded={menu}
              aria-haspopup="menu"
              data-open={menu}
              onClick={() => setMenu((v) => !v)}
            >
              <Plus />
            </button>
            <label htmlFor="composer-input" className="sr-only">
              Message
            </label>
            <textarea
              id="composer-input"
              ref={area}
              rows={1}
              value={text}
              placeholder={editing ? 'Modifier le message' : snap.engineKind === 'mock' ? 'Message (chiffrement simulé)' : 'Message chiffré'}
              aria-keyshortcuts="Enter Shift+Enter ArrowUp Escape"
              onChange={(e) => {
                setText(e.target.value)
                updateMention(e.target.value, e.target.selectionStart)
                if (e.target.value && !editing) relay.typing(convId)
              }}
              onKeyDown={(e) => {
                if (mention && mentionList.length) {
                  if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
                    e.preventDefault()
                    const d = e.key === 'ArrowDown' ? 1 : -1
                    setMention({ ...mention, sel: (mention.sel + d + mentionList.length) % mentionList.length })
                    return
                  }
                  if (e.key === 'Enter' || e.key === 'Tab') {
                    e.preventDefault()
                    pickMention(mentionList[mention.sel].name)
                    return
                  }
                  if (e.key === 'Escape') {
                    e.preventDefault()
                    setMention(null)
                    return
                  }
                }
                if (e.key === 'Enter' && !e.shiftKey && !e.nativeEvent.isComposing) {
                  e.preventDefault()
                  void send()
                } else if (e.key === 'ArrowUp' && !text && !editing) {
                  e.preventDefault()
                  onEditLast()
                } else if (e.key === 'Escape') {
                  if (editing) {
                    e.preventDefault()
                    onClearEdit()
                    setText(savedDraft.current)
                  } else if (replyTo) {
                    e.preventDefault()
                    onClearReply()
                  }
                }
              }}
            />
            <button
              type="button"
              className="icon-btn plain cam-btn"
              data-hidden={sendMode}
              tabIndex={sendMode ? -1 : 0}
              aria-hidden={sendMode}
              aria-label="Prendre une photo"
              onClick={openCamera}
            >
              <Camera />
            </button>
            <button
              type={sendMode ? 'submit' : 'button'}
              className="icon-btn strong morph"
              data-mode={sendMode ? 'send' : 'mic'}
              aria-label={editing ? 'Enregistrer la modification' : sendMode ? 'Envoyer' : 'Note vocale'}
              onClick={sendMode ? undefined : () => void startRec()}
            >
              <span className="morph-mic" aria-hidden="true">
                <Mic />
              </span>
              <span className="morph-send" aria-hidden="true">
                <Send />
              </span>
            </button>
          </>
        )}
      </form>
      {camera && <CameraCapture withCaption onClose={() => setCamera(false)} onCapture={(blob, caption) => void sendShot(blob, caption)} />}
      <input ref={photoInput} type="file" accept="image/*,video/*" multiple hidden onChange={(e) => void onFiles(e.target.files, 'media').then(() => (e.target.value = ''))} />
      <input ref={cameraInput} type="file" accept="image/*" capture="environment" hidden onChange={(e) => void onFiles(e.target.files, 'media').then(() => (e.target.value = ''))} />
      <input ref={fileInput} type="file" multiple hidden onChange={(e) => void onFiles(e.target.files, 'file').then(() => (e.target.value = ''))} />
    </div>
  )
}
