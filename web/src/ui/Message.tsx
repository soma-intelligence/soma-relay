import { memo, useEffect, useRef, useState, type PointerEvent as RPointerEvent } from 'react'
import { relay } from '../state/relay'
import type { ChatMessage } from '../state/types'
import { formatDuration, formatSize } from '../media/media'
import { File, Pause, Phone, Play, Reply, Timer, Video } from './Icons'
import { RichText } from './RichText'
import { LinkCard, LocationBubble, PollBubble } from './Rich'

export type RunPos = 'single' | 'first' | 'mid' | 'last'

function transportClass(m: ChatMessage): string {
  if (m.from !== 'me') return ''
  if (m.status === 'pending') return 'pending'
  if (m.status === 'failed') return 'failed'
  return m.transport ?? 'net'
}

export function statusWord(m: ChatMessage, isGroup: boolean): string {
  switch (m.status) {
    case 'pending':
      return 'EN ROUTE'
    case 'failed':
      return 'ÉCHEC'
    case 'sent':
      return 'ENVOYÉ'
    case 'delivered':
      return isGroup ? 'ENVOYÉ' : 'REÇU'
    case 'read':
      return 'LU'
  }
}

export function metaLine(m: ChatMessage): string {
  const time = new Date(m.ts).toLocaleTimeString('fr-FR', { hour: '2-digit', minute: '2-digit' })
  const t = m.transport === 'p2p' ? 'P2P' : m.transport === 'local' ? 'LOCAL' : 'NET'
  if (m.from !== 'me') return `${t} · ${time}`
  if (m.status === 'pending') return `en file d’attente · ${time}`
  if (m.status === 'failed') return time
  return `${t} · ${time}`
}

function useMediaUrl(m: ChatMessage, auto: boolean) {
  const [url, setUrl] = useState<string | undefined>(() => relay.cachedMediaUrl(m.id))
  const [error, setError] = useState<string | null>(null)
  const [loading, setLoading] = useState(false)
  const load = async () => {
    setLoading(true)
    setError(null)
    try {
      const u = await relay.mediaUrl(m)
      if (u) setUrl(u)
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Téléchargement impossible.')
    } finally {
      setLoading(false)
    }
  }
  useEffect(() => {
    if (!url && auto) void load()
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [m.id])
  return { url, error, loading, load }
}

/** Bubble media size: keeps the aspect ratio inside 280 x 360 px. */
function fitBox(width: number | undefined, height: number | undefined, fallback: number) {
  const ratio = width && height ? width / height : fallback
  const w = Math.round(Math.min(280, 360 * ratio, width ?? 280))
  return { w: Math.max(w, 80), ratio }
}

function Photo({ m, onOpen }: { m: ChatMessage; onOpen: (url: string, kind: 'image' | 'video') => void }) {
  const a = m.attachment!
  const { url, loading, error, load } = useMediaUrl(m, true)
  const { w, ratio } = fitBox(a.width, a.height, 4 / 3)
  const style = { width: w, aspectRatio: String(ratio) }
  if (url)
    return (
      <button className="photo-wrap" onClick={() => onOpen(url, 'image')} aria-label="Agrandir la photo">
        <img className="photo" src={url} alt="" style={style} />
      </button>
    )
  return (
    <button className="photo-wrap" onClick={() => void load()} aria-label={error ?? 'Charger la photo'}>
      {a.thumb ? (
        <img className="photo blur" src={`data:image/jpeg;base64,${a.thumb}`} alt="" style={style} />
      ) : (
        <span className="photo" style={{ ...style, display: 'block' }} />
      )}
      {loading && <span className="spinner" />}
    </button>
  )
}

function VideoThumb({ m, onOpen }: { m: ChatMessage; onOpen: (url: string, kind: 'image' | 'video') => void }) {
  const a = m.attachment!
  const { url, loading, load } = useMediaUrl(m, false)
  const { w, ratio } = fitBox(a.width, a.height, 16 / 9)
  const open = async () => {
    if (url) return onOpen(url, 'video')
    await load()
    const u = relay.cachedMediaUrl(m.id)
    if (u) onOpen(u, 'video')
  }
  return (
    <button className="photo-wrap" onClick={() => void open()} aria-label="Lire la vidéo">
      {a.thumb ? (
        <img className="photo" src={`data:image/jpeg;base64,${a.thumb}`} alt="" style={{ width: w, aspectRatio: String(ratio) }} />
      ) : (
        <span className="photo" style={{ width: w, aspectRatio: String(ratio), display: 'block' }} />
      )}
      <span
        style={{
          position: 'absolute',
          inset: 0,
          margin: 'auto',
          width: 48,
          height: 48,
          borderRadius: 24,
          background: 'rgba(0,0,0,0.55)',
          color: '#fff',
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'center',
        }}
      >
        {loading ? <span className="spinner" /> : <Play size={16} />}
      </span>
      {a.duration_ms ? (
        <span className="mono" style={{ position: 'absolute', right: 10, bottom: 8, color: '#fff', fontSize: 11, textShadow: '0 1px 4px #000' }}>
          {formatDuration(a.duration_ms)}
        </span>
      ) : null}
    </button>
  )
}

function Voice({ m }: { m: ChatMessage }) {
  const a = m.attachment!
  const { url, load } = useMediaUrl(m, true)
  const audio = useRef<HTMLAudioElement | null>(null)
  const [playing, setPlaying] = useState(false)
  const [progress, setProgress] = useState(0)
  const [pos, setPos] = useState(0)
  const toggle = async () => {
    let u = url
    if (!u) {
      await load()
      u = relay.cachedMediaUrl(m.id)
    }
    if (!u) return
    if (!audio.current) {
      const el = new Audio(u)
      el.ontimeupdate = () => {
        const d = el.duration && Number.isFinite(el.duration) ? el.duration : (a.duration_ms ?? 1000) / 1000
        setProgress(el.currentTime / d)
        setPos(el.currentTime * 1000)
      }
      el.onended = () => {
        setPlaying(false)
        setProgress(0)
        setPos(0)
      }
      audio.current = el
    }
    if (playing) {
      audio.current.pause()
      setPlaying(false)
    } else {
      await audio.current.play().catch(() => {})
      setPlaying(true)
    }
  }
  useEffect(() => () => audio.current?.pause(), [])
  const seek = (e: React.MouseEvent<HTMLDivElement>) => {
    const el = audio.current
    if (!el || !el.duration) return
    const r = e.currentTarget.getBoundingClientRect()
    el.currentTime = ((e.clientX - r.left) / r.width) * el.duration
  }
  return (
    <div className={`voice ${transportClass(m)}`}>
      <button className="play" onClick={() => void toggle()} aria-label={playing ? 'Mettre en pause' : 'Lire la note vocale'}>
        {playing ? <Pause /> : <Play />}
      </button>
      <div
        className="track"
        onClick={seek}
        role="slider"
        aria-label="Position"
        aria-valuemin={0}
        aria-valuemax={100}
        aria-valuenow={Math.round(progress * 100)}
        tabIndex={-1}
      >
        <div style={{ width: `${Math.max(progress * 100, playing ? 1 : 0)}%` }} />
      </div>
      <span className="time">{formatDuration(playing || pos ? pos : (a.duration_ms ?? 0))}</span>
    </div>
  )
}

/** Kind of document viewer for an attachment (the viewer itself is loaded on demand). */
export function docType(name: string | undefined, mime: string): 'pdf' | 'word' | 'sheet' | 'slides' | 'text' | 'image' | 'media' | 'other' {
  const ext = (name ?? '').toLowerCase().split('.').pop() ?? ''
  if (mime === 'application/pdf' || ext === 'pdf') return 'pdf'
  if (ext === 'docx' || mime.includes('wordprocessingml')) return 'word'
  if (['xlsx', 'xls', 'ods', 'csv', 'tsv'].includes(ext) || mime.includes('spreadsheetml') || mime === 'text/csv') return 'sheet'
  if (['pptx', 'ppt', 'key', 'odp'].includes(ext) || mime.includes('presentationml')) return 'slides'
  if (mime.startsWith('image/')) return 'image'
  if (mime.startsWith('audio/') || mime.startsWith('video/')) return 'media'
  if (
    mime.startsWith('text/') ||
    /json|xml|javascript|typescript|x-sh|yaml|toml/.test(mime) ||
    ['txt', 'md', 'log', 'json', 'xml', 'yml', 'yaml', 'toml', 'ini', 'js', 'ts', 'tsx', 'jsx', 'py', 'rs', 'swift', 'go', 'c', 'h', 'cpp', 'java', 'kt', 'rb', 'sh', 'css', 'html', 'sql'].includes(ext)
  )
    return 'text'
  return 'other'
}

const DOC_LABEL: Record<string, string> = { pdf: 'PDF', word: 'WORD', sheet: 'TABLEUR', slides: 'PRÉSENTATION', text: 'TEXTE' }

function FileCard({ m, onOpen }: { m: ChatMessage; onOpen: (m: ChatMessage) => void }) {
  const a = m.attachment!
  const kind = docType(a.name, a.mime)
  const ext = (a.name ?? '').split('.').pop()?.toUpperCase()
  const label = DOC_LABEL[kind] ?? (ext && ext.length <= 5 ? ext : (a.mime.split('/')[1]?.toUpperCase() ?? 'FICHIER'))
  return (
    <button className={`file-card ${transportClass(m)}${a.thumb ? ' has-thumb' : ''}`} onClick={() => onOpen(m)} aria-label={`Ouvrir ${a.name ?? 'le fichier'}`}>
      {a.thumb && (
        <span className="doc-thumb">
          <img src={`data:image/jpeg;base64,${a.thumb}`} alt="" style={a.width && a.height ? { aspectRatio: `${a.width} / ${a.height}` } : undefined} />
        </span>
      )}
      <span className="file-row">
        <span className={`ico doc-${kind}`}>
          <File />
        </span>
        <span style={{ flex: 1, minWidth: 0 }}>
          <span className="fname">{a.name ?? 'Fichier'}</span>
          <span className="fsize" style={{ display: 'block' }}>
            {label} · {formatSize(a.size)}
            {a.pages ? ` · ${a.pages} ${kind === 'slides' ? 'diapo' : 'page'}${a.pages > 1 ? 's' : ''}` : ''}
          </span>
        </span>
      </span>
    </button>
  )
}

export interface MessageHandlers {
  onMenu: (m: ChatMessage, x: number, y: number) => void
  onReply: (m: ChatMessage) => void
  onOpenMedia: (url: string, kind: 'image' | 'video') => void
  onOpenDoc: (m: ChatMessage) => void
  onOpenMap: (m: ChatMessage) => void
  onJump: (id: string) => void
  nameOf: (fp: string) => string
}

const SWIPE_MAX = 84
const SWIPE_FIRE = 56

function quoteText(q: ChatMessage): string {
  if (q.deleted) return 'Message supprimé'
  switch (q.kind) {
    case 'image':
      return 'Photo'
    case 'video':
      return 'Vidéo'
    case 'audio':
      return 'Note vocale'
    case 'file':
      return q.attachment?.name ?? 'Document'
    case 'poll':
      return `Sondage : ${q.poll?.question ?? ''}`
    case 'location':
      return 'Position'
    default:
      return q.text ?? ''
  }
}

export const MessageItem = memo(function MessageItem({
  m,
  quoted,
  senderName,
  senderColor,
  isGroup,
  pos,
  showMeta,
  fresh,
  flash,
  highlight,
  mentionNames,
  h,
}: {
  m: ChatMessage
  quoted?: ChatMessage
  senderName?: string
  senderColor?: string
  isGroup: boolean
  pos: RunPos
  showMeta: boolean
  fresh: boolean
  flash: boolean
  highlight?: string
  mentionNames: string[]
  h: MessageHandlers
}) {
  const row = useRef<HTMLDivElement>(null)
  const swipe = useRef<{ id: number; x: number; y: number; dx: number; on: boolean; fired: boolean; timer: ReturnType<typeof setTimeout> | null } | null>(null)
  const [dragX, setDragX] = useState(0)

  if (m.kind === 'system') return <div className="system" data-id={m.id}>{m.text}</div>
  const out = m.from === 'me'
  if (m.kind === 'call') {
    const missed = m.call?.outcome === 'missed' && !out
    return (
      <div className={`msg ${out ? 'out' : 'in'} pos-single`} data-id={m.id}>
        <div className={`call-log${missed ? ' missed' : ''}`}>
          {m.call?.video ? <Video /> : <Phone />}
          <span>
            {m.text}
            <small>
              {m.call?.durationMs ? formatDuration(m.call.durationMs) + ' · ' : ''}
              {new Date(m.ts).toLocaleTimeString('fr-FR', { hour: '2-digit', minute: '2-digit' })}
            </small>
          </span>
        </div>
      </div>
    )
  }

  const tc = transportClass(m)
  const reactions = Object.entries(m.reactions ?? {})
  const quote = quoted ? (
    <button
      className="reply-quote"
      onClick={(e) => {
        e.stopPropagation()
        h.onJump(quoted.id)
      }}
      aria-label={`Aller au message cité : ${quoteText(quoted)}`}
    >
      <b>{quoted.from === 'me' ? 'Toi' : h.nameOf(quoted.from)}</b>
      <span>{quoteText(quoted)}</span>
    </button>
  ) : null
  const fwd = m.forwarded ? <div className="fwd">Transféré</div> : null

  let body: React.ReactNode
  if (m.deleted) {
    body = <div className="bubble deleted">Message supprimé</div>
  } else
    switch (m.kind) {
      case 'image':
        body = (
          <div className={`bubble media ${tc}`}>
            <Photo m={m} onOpen={h.onOpenMedia} />
          </div>
        )
        break
      case 'video':
        body = (
          <div className={`bubble media ${tc}`}>
            <VideoThumb m={m} onOpen={h.onOpenMedia} />
          </div>
        )
        break
      case 'audio':
        body = <Voice m={m} />
        break
      case 'file':
        body = <FileCard m={m} onOpen={h.onOpenDoc} />
        break
      case 'poll':
        body = (
          <div className={`bubble card ${tc}`}>
            <PollBubble m={m} isGroup={isGroup} nameOf={h.nameOf} />
          </div>
        )
        break
      case 'location':
        body = (
          <div className={`bubble card ${tc}`}>
            <LocationBubble m={m} onOpen={() => h.onOpenMap(m)} />
          </div>
        )
        break
      default:
        body = (
          <div className={`bubble ${tc}${m.link ? ' with-link' : ''}`}>
            {fwd}
            {quote}
            <RichText text={m.text ?? ''} names={mentionNames} highlight={highlight} />
            {m.link && <LinkCard link={m.link} />}
          </div>
        )
    }
  const textLike = m.kind === 'text' || m.deleted

  // Long press (touch) opens the menu; a horizontal drag to the right replies.
  const onDown = (e: RPointerEvent<HTMLDivElement>) => {
    if (e.pointerType === 'mouse' || m.deleted) return
    const s = { id: e.pointerId, x: e.clientX, y: e.clientY, dx: 0, on: false, fired: false, timer: null as ReturnType<typeof setTimeout> | null }
    s.timer = setTimeout(() => {
      if (!s.on) {
        navigator.vibrate?.(10)
        h.onMenu(m, s.x, s.y)
        swipe.current = null
      }
    }, 450)
    swipe.current = s
  }
  const onMove = (e: RPointerEvent<HTMLDivElement>) => {
    const s = swipe.current
    if (!s || s.id !== e.pointerId) return
    const dx = e.clientX - s.x
    const dy = e.clientY - s.y
    if (!s.on && (Math.abs(dx) > 8 || Math.abs(dy) > 8)) {
      if (s.timer) clearTimeout(s.timer)
      if (dx > 10 && Math.abs(dx) > Math.abs(dy) * 1.5) s.on = true
      else {
        swipe.current = null
        return
      }
    }
    if (!s.on) return
    s.dx = Math.max(0, Math.min(SWIPE_MAX, dx * 0.8))
    if (!s.fired && s.dx >= SWIPE_FIRE) {
      s.fired = true
      navigator.vibrate?.(8)
    } else if (s.fired && s.dx < SWIPE_FIRE) s.fired = false
    setDragX(s.dx)
  }
  const onUp = () => {
    const s = swipe.current
    swipe.current = null
    if (!s) return
    if (s.timer) clearTimeout(s.timer)
    if (s.on && s.dx >= SWIPE_FIRE) h.onReply(m)
    setDragX(0)
  }

  const label = `${out ? 'Toi' : (senderName ?? 'Message')}, ${new Date(m.ts).toLocaleTimeString('fr-FR', { hour: '2-digit', minute: '2-digit' })}`
  return (
    <div
      ref={row}
      className={`msg ${out ? 'out' : 'in'} pos-${pos}${fresh ? ' fresh' : ''}${flash ? ' flash' : ''}`}
      onContextMenu={(e) => {
        if ((e.target as HTMLElement).closest('a')) return
        e.preventDefault()
        if (!m.deleted || out) h.onMenu(m, e.clientX, e.clientY)
      }}
      onPointerDown={onDown}
      onPointerMove={onMove}
      onPointerUp={onUp}
      onPointerCancel={onUp}
      data-id={m.id}
      aria-label={label}
      role="article"
    >
      {isGroup && !out && senderName && (pos === 'first' || pos === 'single') && (
        <div className="sender" style={{ color: senderColor }}>
          {senderName}
        </div>
      )}
      <div className="swipe-hint" aria-hidden="true" style={{ opacity: Math.min(1, dragX / SWIPE_FIRE), transform: `scale(${dragX >= SWIPE_FIRE ? 1 : 0.7})` }}>
        <Reply />
      </div>
      <div className="msg-body" style={dragX ? { transform: `translateX(${dragX}px)`, transition: 'none' } : undefined}>
        {!textLike && fwd}
        {!textLike && quote}
        {body}
        {!m.deleted && (
          <button
            className="msg-more"
            aria-label="Actions du message"
            onClick={(e) => {
              const r = (e.currentTarget as HTMLElement).getBoundingClientRect()
              h.onMenu(m, r.left, r.bottom)
            }}
          >
            ···
          </button>
        )}
      </div>
      {reactions.length > 0 && (
        <div className="reactions" aria-label="Réactions">
          {reactions.map(([emoji, who]) => (
            <button
              key={emoji + who.length}
              className={who.includes('me') ? 'mine' : ''}
              onClick={() => void relay.react(m.convId, m.id, emoji)}
              aria-label={`${emoji} ${who.length}${who.includes('me') ? ', dont toi' : ''}`}
              title={who.map((f) => (f === 'me' ? 'toi' : h.nameOf(f))).join(', ')}
            >
              {emoji}
              {who.length > 1 ? <span className="n">{who.length}</span> : null}
            </button>
          ))}
        </div>
      )}
      {(showMeta || m.editedAt || m.status === 'failed' || m.status === 'pending') && (
        <div className="meta">
          {m.expireS ? <Timer size={11} aria-label="Message éphémère" /> : null}
          {m.editedAt && !m.deleted ? <span className="edited">modifié</span> : null}
          <span>{metaLine(m)}</span>
          {out && (
            <span className={`st st-${m.status}`} key={m.status}>
              {statusWord(m, isGroup)}
            </span>
          )}
          {m.status === 'failed' && out && <button onClick={() => void relay.retry(m.convId, m.id)}>réessayer</button>}
        </div>
      )}
    </div>
  )
})
