import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react'
import { relay } from '../state/relay'
import type { ChatMessage } from '../state/types'
import { prepareFile, prepareImage, prepareVideo, VoiceRecorder, formatDuration } from '../media/media'
import { dayLabel, useRelay } from './common'
import { MessageItem } from './Message'
import { Back, Camera, Chevron, Close, File, Image, Mic, Phone, Plus, Send, Video } from './Icons'
import { fpShort } from '../lib/bytes'

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
      {live && (
        <path className="radar-sweep" d="M38 38 L38 2 A36 36 0 0 1 63.5 12.5 Z" fill="var(--mesh)" opacity="0.08" />
      )}
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
  const title = isGroup ? (group?.name ?? 'Groupe') : (contact?.name ?? 'Inconnu')
  const messages = snap.messages[convId] ?? []
  const online = !!contact && snap.online.has(contact.mailbox)
  const p2p = !isGroup && snap.p2pOpen.has(convId)
  const nodeOnline = snap.node === 'online' || snap.localBus
  const [pathOpen, setPathOpen] = useState(false)
  const [activeMsg, setActiveMsg] = useState<string | null>(null)
  const [replyTo, setReplyTo] = useState<ChatMessage | null>(null)
  const [lightbox, setLightbox] = useState<{ url: string; kind: 'image' | 'video' } | null>(null)
  const scroller = useRef<HTMLDivElement>(null)
  const stick = useRef(true)

  useEffect(() => {
    void relay.openConversation(convId)
    setReplyTo(null)
    setActiveMsg(null)
    stick.current = true
  }, [convId])

  useLayoutEffect(() => {
    const el = scroller.current
    if (el && stick.current) el.scrollTop = el.scrollHeight
  }, [messages.length, convId])

  const onScroll = () => {
    const el = scroller.current
    if (el) stick.current = el.scrollHeight - el.scrollTop - el.clientHeight < 80
  }

  const typingNow = Object.entries(snap.typing).some(
    ([k, until]) => k.startsWith(convId + '|') && until > Date.now(),
  )
  // Re-render when the typing indicator expires.
  const [, tick] = useState(0)
  useEffect(() => {
    if (!typingNow) return
    const t = setTimeout(() => tick((x) => x + 1), 6100)
    return () => clearTimeout(t)
  }, [typingNow, snap.typing])

  const byId = useMemo(() => new Map(messages.map((m) => [m.id, m])), [messages])
  const nameOf = useCallback(
    (fp: string) => snap.contacts.find((c) => c.fingerprint === fp)?.name ?? fpShort(fp),
    [snap.contacts],
  )

  let chain: string
  let headline: string
  if (isGroup) {
    headline = `${group?.members.length ?? 0} membres · chiffré`
    chain = nodeOnline ? `toi → nœud → ${group?.members.length ? group.members.length - 1 : 0} boîtes` : 'hors ligne · en file d’attente'
  } else if (p2p) {
    headline = 'Lien direct, pair à pair'
    chain = `toi → ${title} · P2P`
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

  const items: React.ReactNode[] = []
  let lastTs = 0
  for (const m of messages) {
    if (m.ts - lastTs > 30 * 60_000) {
      items.push(
        <div className="day" key={`d-${m.id}`}>
          {dayLabel(m.ts)}
          {lastTs === 0 ? (snap.engineKind === 'mock' ? ' · CHIFFREMENT SIMULÉ' : ' · ML-KEM-1024 + X25519') : ''}
        </div>,
      )
    }
    lastTs = m.ts
    items.push(
      <MessageItem
        key={m.id}
        m={m}
        quoted={m.replyTo ? byId.get(m.replyTo) : undefined}
        senderName={isGroup && m.from !== 'me' ? nameOf(m.from) : undefined}
        isGroup={isGroup}
        active={activeMsg === m.id}
        onActivate={setActiveMsg}
        onReply={setReplyTo}
        onOpenMedia={(url, kind) => setLightbox({ url, kind })}
      />,
    )
  }

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
          <button className="chat-title" onClick={onInfo} aria-label={`Infos sur ${title}`}>
            <span className="name">{title}</span>
            <span className="fp">
              {isGroup
                ? `${group?.members.length ?? 0} membres`
                : `fp ${fpShort(convId)} · ${contact?.verified ? 'vérifiée' : 'non vérifiée'}`}
            </span>
          </button>
          {!isGroup ? (
            <>
              <button
                className="icon-btn"
                aria-label="Appel vidéo"
                onClick={() => void relay.calls.start(convId, true)}
                disabled={!contact}
              >
                <Video />
              </button>
              <button
                className="icon-btn strong"
                aria-label="Appeler"
                onClick={() => void relay.calls.start(convId, false)}
                disabled={!contact}
              >
                <Phone />
              </button>
            </>
          ) : (
            <span style={{ width: 44 }} />
          )}
        </header>
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
                <dd>{snap.outboxCount} message{snap.outboxCount > 1 ? 's' : ''}</dd>
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
      </div>
      <div
        className={`messages${pathOpen ? ' with-path-open' : ''}`}
        ref={scroller}
        onScroll={onScroll}
        onClick={(e) => {
          if (activeMsg && !(e.target as HTMLElement).closest('.msg-actions')) setActiveMsg(null)
        }}
        role="log"
        aria-live="polite"
        aria-relevant="additions"
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
          <div className="typing-dots" aria-label={`${title} écrit`}>
            <span />
            <span />
            <span />
          </div>
        )}
      </div>
      <Composer convId={convId} replyTo={replyTo} onClearReply={() => setReplyTo(null)} />
      {lightbox && (
        <div className="lightbox" role="dialog" aria-label="Aperçu" onClick={() => setLightbox(null)}>
          {lightbox.kind === 'image' ? (
            <img src={lightbox.url} alt="" />
          ) : (
            <video src={lightbox.url} controls autoPlay playsInline onClick={(e) => e.stopPropagation()} />
          )}
          <button className="icon-btn" aria-label="Fermer" onClick={() => setLightbox(null)} autoFocus>
            <Close />
          </button>
        </div>
      )}
    </section>
  )
}

function Composer({
  convId,
  replyTo,
  onClearReply,
}: {
  convId: string
  replyTo: ChatMessage | null
  onClearReply: () => void
}) {
  const snap = useRelay()
  const conv = snap.conversations.find((c) => c.id === convId)
  const [text, setText] = useState(conv?.draft ?? '')
  const [menu, setMenu] = useState(false)
  const [recording, setRecording] = useState(false)
  const [elapsed, setElapsed] = useState(0)
  const rec = useRef<VoiceRecorder | null>(null)
  const area = useRef<HTMLTextAreaElement>(null)
  const wave = useRef<HTMLCanvasElement>(null)
  const photoInput = useRef<HTMLInputElement>(null)
  const fileInput = useRef<HTMLInputElement>(null)
  const cameraInput = useRef<HTMLInputElement>(null)

  useEffect(() => {
    setText(relay.getSnapshot().conversations.find((c) => c.id === convId)?.draft ?? '')
    if (matchMedia('(pointer: fine)').matches) area.current?.focus()
  }, [convId])

  useEffect(() => {
    if (replyTo) area.current?.focus()
  }, [replyTo])

  useLayoutEffect(() => {
    const el = area.current
    if (!el) return
    el.style.height = 'auto'
    el.style.height = Math.min(160, el.scrollHeight) + 'px'
  }, [text])

  // Save the draft when leaving the conversation.
  useEffect(() => {
    return () => {
      const v = area.current?.value ?? ''
      void relay.setDraft(convId, v)
    }
  }, [convId])

  const send = () => {
    const body = text.trim()
    if (!body) return
    void relay.sendText(convId, body, replyTo?.id)
    setText('')
    onClearReply()
    area.current?.focus()
  }

  const onFiles = async (files: FileList | null, mode: 'media' | 'file') => {
    setMenu(false)
    if (!files) return
    for (const f of Array.from(files)) {
      try {
        if (mode === 'media' && f.type.startsWith('image/')) await relay.sendMedia(convId, 'image', await prepareImage(f), f.name)
        else if (mode === 'media' && f.type.startsWith('video/'))
          await relay.sendMedia(convId, 'video', await prepareVideo(f), f.name)
        else await relay.sendMedia(convId, 'file', await prepareFile(f), f.name)
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
  return (
    <div className="composer-wrap">
      {replyTo && (
        <div className="reply-bar glass">
          <span className="txt">
            <b>Réponse à {replyTo.from === 'me' ? 'toi' : relay.titleOf(replyTo.from)}</b>
            {replyTo.text ?? 'Pièce jointe'}
          </span>
          <button className="icon-btn plain" onClick={onClearReply} aria-label="Annuler la réponse">
            <Close size={16} />
          </button>
        </div>
      )}
      {menu && (
        <div className="attach-menu glass" role="menu">
          <button role="menuitem" onClick={() => photoInput.current?.click()}>
            <Image /> Photo ou vidéo
          </button>
          <button role="menuitem" onClick={() => cameraInput.current?.click()}>
            <Camera /> Appareil photo
          </button>
          <button role="menuitem" onClick={() => fileInput.current?.click()}>
            <File /> Fichier
          </button>
        </div>
      )}
      <form
        className="composer bar glass"
        onSubmit={(e) => {
          e.preventDefault()
          send()
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
              className="icon-btn"
              aria-label="Joindre"
              aria-expanded={menu}
              aria-haspopup="menu"
              onClick={() => setMenu((v) => !v)}
            >
              <Plus style={{ transform: menu ? 'rotate(45deg)' : undefined, transition: 'transform .2s' }} />
            </button>
            <label htmlFor="composer-input" className="sr-only">
              Message
            </label>
            <textarea
              id="composer-input"
              ref={area}
              rows={1}
              value={text}
              placeholder={snap.engineKind === 'mock' ? 'Message (chiffrement simulé)' : 'Message chiffré'}
              onChange={(e) => {
                setText(e.target.value)
                if (e.target.value) relay.typing(convId)
              }}
              onKeyDown={(e) => {
                if (e.key === 'Enter' && !e.shiftKey && !e.nativeEvent.isComposing) {
                  e.preventDefault()
                  send()
                }
              }}
            />
            {hasText ? (
              <button type="submit" className="icon-btn strong" aria-label="Envoyer">
                <Send />
              </button>
            ) : (
              <button type="button" className="icon-btn strong" aria-label="Note vocale" onClick={() => void startRec()}>
                <Mic />
              </button>
            )}
          </>
        )}
      </form>
      <input ref={photoInput} type="file" accept="image/*,video/*" multiple hidden onChange={(e) => void onFiles(e.target.files, 'media').then(() => (e.target.value = ''))} />
      <input ref={cameraInput} type="file" accept="image/*" capture="environment" hidden onChange={(e) => void onFiles(e.target.files, 'media').then(() => (e.target.value = ''))} />
      <input ref={fileInput} type="file" multiple hidden onChange={(e) => void onFiles(e.target.files, 'file').then(() => (e.target.value = ''))} />
    </div>
  )
}
