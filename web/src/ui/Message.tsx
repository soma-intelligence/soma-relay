import { memo, useEffect, useRef, useState } from 'react'
import { relay } from '../state/relay'
import type { ChatMessage } from '../state/types'
import { formatDuration, formatSize } from '../media/media'
import { Download, File, Pause, Phone, Play, Reply, Smile, Video } from './Icons'

const REACTIONS = ['❤️', '👍', '😂', '😮', '🙏']

function transportClass(m: ChatMessage): string {
  if (m.from !== 'me') return ''
  if (m.status === 'pending') return 'pending'
  if (m.status === 'failed') return 'failed'
  return m.transport ?? 'net'
}

export function metaLine(m: ChatMessage, isGroup: boolean): string {
  const time = new Date(m.ts).toLocaleTimeString('fr-FR', { hour: '2-digit', minute: '2-digit' })
  const t = m.transport === 'p2p' ? 'P2P' : m.transport === 'local' ? 'LOCAL' : 'NET'
  if (m.from !== 'me') return `${t} · ${time}`
  switch (m.status) {
    case 'pending':
      return `EN ROUTE · en file d’attente · ${time}`
    case 'failed':
      return `ÉCHEC · ${time}`
    case 'sent':
      return `${t} · ENVOYÉ · ${time}`
    case 'delivered':
      return `${t} · ${isGroup ? 'ENVOYÉ' : 'REÇU'} · ${time}`
    case 'read':
      return `${t} · LU · ${time}`
  }
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

function Photo({ m, onOpen }: { m: ChatMessage; onOpen: (url: string, kind: 'image' | 'video') => void }) {
  const a = m.attachment!
  const { url, loading, error, load } = useMediaUrl(m, true)
  const ratio = a.width && a.height ? a.width / a.height : 4 / 3
  const w = Math.min(300, ratio >= 1 ? 300 : 300 * ratio)
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
  const ratio = a.width && a.height ? a.width / a.height : 16 / 9
  const w = Math.min(300, ratio >= 1 ? 300 : 300 * ratio)
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

function FileCard({ m }: { m: ChatMessage }) {
  const a = m.attachment!
  const [busy, setBusy] = useState(false)
  const save = async () => {
    setBusy(true)
    try {
      const url = await relay.mediaUrl(m)
      if (!url) return
      const link = document.createElement('a')
      link.href = url
      link.download = a.name ?? 'fichier'
      link.click()
    } catch (e) {
      relay.toast(e instanceof Error ? e.message : 'Téléchargement impossible.')
    } finally {
      setBusy(false)
    }
  }
  return (
    <button className={`file-card ${transportClass(m)}`} onClick={() => void save()} aria-label={`Télécharger ${a.name ?? 'le fichier'}`}>
      <span className="ico">{busy ? <span className="spinner" /> : <File />}</span>
      <span style={{ flex: 1, minWidth: 0 }}>
        <span className="fname">{a.name ?? 'Fichier'}</span>
        <span className="fsize" style={{ display: 'block' }}>
          {formatSize(a.size)} · {a.mime.split('/')[1]?.toUpperCase() ?? 'FICHIER'}
        </span>
      </span>
      <Download />
    </button>
  )
}

export const MessageItem = memo(function MessageItem({
  m,
  quoted,
  senderName,
  isGroup,
  active,
  onActivate,
  onReply,
  onOpenMedia,
}: {
  m: ChatMessage
  quoted?: ChatMessage
  senderName?: string
  isGroup: boolean
  active: boolean
  onActivate: (id: string | null) => void
  onReply: (m: ChatMessage) => void
  onOpenMedia: (url: string, kind: 'image' | 'video') => void
}) {
  if (m.kind === 'system') return <div className="system">{m.text}</div>
  const out = m.from === 'me'
  if (m.kind === 'call') {
    const missed = m.call?.outcome === 'missed' && !out
    return (
      <div className={`msg ${out ? 'out' : 'in'}`}>
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
  let body: React.ReactNode
  switch (m.kind) {
    case 'image':
      body = (
        <div className={`bubble media ${tc}`}>
          <Photo m={m} onOpen={onOpenMedia} />
        </div>
      )
      break
    case 'video':
      body = (
        <div className={`bubble media ${tc}`}>
          <VideoThumb m={m} onOpen={onOpenMedia} />
        </div>
      )
      break
    case 'audio':
      body = <Voice m={m} />
      break
    case 'file':
      body = <FileCard m={m} />
      break
    default:
      body = (
        <div className={`bubble ${tc}`}>
          {quoted && <div className="reply-quote">{quoted.text ?? (quoted.kind === 'image' ? 'Photo' : 'Pièce jointe')}</div>}
          {m.text}
        </div>
      )
  }
  return (
    <div
      className={`msg ${out ? 'out' : 'in'}`}
      onContextMenu={(e) => {
        e.preventDefault()
        onActivate(active ? null : m.id)
      }}
      onDoubleClick={() => onActivate(active ? null : m.id)}
      data-id={m.id}
    >
      {isGroup && !out && senderName && <div className="sender">{senderName}</div>}
      {active && (
        <div className="msg-actions glass" role="toolbar" aria-label="Actions du message">
          {REACTIONS.map((r) => (
            <button
              key={r}
              aria-label={`Réagir ${r}`}
              onClick={() => {
                void relay.react(m.convId, m.id, r)
                onActivate(null)
              }}
            >
              {r}
            </button>
          ))}
          <button
            aria-label="Répondre"
            onClick={() => {
              onReply(m)
              onActivate(null)
            }}
          >
            <Reply />
          </button>
        </div>
      )}
      {body}
      {reactions.length > 0 && (
        <div className="reactions" aria-label="Réactions">
          {reactions.map(([emoji, who]) => (
            <span key={emoji}>
              {emoji}
              {who.length > 1 ? ` ${who.length}` : ''}
            </span>
          ))}
        </div>
      )}
      <div className="meta">
        <span>{metaLine(m, isGroup)}</span>
        {m.status === 'failed' && out && <button onClick={() => void relay.retry(m.convId, m.id)}>réessayer</button>}
        <button
          className="sr-only"
          onClick={() => onActivate(active ? null : m.id)}
          aria-label="Réagir ou répondre"
          style={{ color: 'inherit' }}
        >
          <Smile />
        </button>
      </div>
    </div>
  )
})
