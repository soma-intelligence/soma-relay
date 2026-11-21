// Sheets opened from a conversation: new poll, share location, forward, message info.

import { useEffect, useState } from 'react'
import { expireLabel, relay } from '../state/relay'
import type { ChatMessage } from '../state/types'
import { Avatar, Sheet, useRelay } from './common'
import { Close, People, Pin, Plus } from './Icons'
import { StaticMap } from './Rich'
import { statusWord } from './Message'

export function PollSheet({ convId, onClose }: { convId: string; onClose: () => void }) {
  const [question, setQuestion] = useState('')
  const [options, setOptions] = useState(['', ''])
  const [multi, setMulti] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const filled = options.map((o) => o.trim()).filter(Boolean)
  const ok = question.trim() && filled.length >= 2 && new Set(filled).size === filled.length
  const submit = async () => {
    try {
      await relay.sendPoll(convId, {
        question: question.trim(),
        options: filled.map((text, i) => ({ id: String.fromCharCode(97 + i), text })),
        multi,
      })
      onClose()
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Envoi impossible.')
    }
  }
  return (
    <Sheet title="Nouveau sondage" onClose={onClose}>
      <form
        onSubmit={(e) => {
          e.preventDefault()
          if (ok) void submit()
        }}
      >
        <div className="field">
          <label htmlFor="poll-q">Question</label>
          <input id="poll-q" value={question} onChange={(e) => setQuestion(e.target.value)} maxLength={300} placeholder="Resto ce soir ?" />
        </div>
        <fieldset className="poll-edit">
          <legend className="lbl hint">Réponses · {filled.length}/12</legend>
          {options.map((o, i) => (
            <div className="poll-edit-row" key={i}>
              <input
                aria-label={`Réponse ${i + 1}`}
                value={o}
                maxLength={200}
                placeholder={`Réponse ${i + 1}`}
                onChange={(e) => setOptions(options.map((x, j) => (j === i ? e.target.value : x)))}
                onKeyDown={(e) => {
                  if (e.key === 'Enter' && i === options.length - 1 && o.trim() && options.length < 12) {
                    e.preventDefault()
                    setOptions([...options, ''])
                    requestAnimationFrame(() => document.querySelector<HTMLInputElement>(`[aria-label="Réponse ${i + 2}"]`)?.focus())
                  }
                }}
              />
              {options.length > 2 && (
                <button type="button" className="icon-btn plain" aria-label={`Retirer la réponse ${i + 1}`} onClick={() => setOptions(options.filter((_, j) => j !== i))}>
                  <Close size={16} />
                </button>
              )}
            </div>
          ))}
          {options.length < 12 && (
            <button type="button" className="btn block ghost" onClick={() => setOptions([...options, ''])}>
              <Plus size={16} /> Ajouter une réponse
            </button>
          )}
        </fieldset>
        <label className="set-row" style={{ borderBottom: 0 }}>
          <span className="lbl">
            Plusieurs réponses
            <small>Chacun peut cocher plus d’une case.</small>
          </span>
          <input type="checkbox" className="switch" checked={multi} onChange={(e) => setMulti(e.target.checked)} />
        </label>
        {error && <p className="error">{error}</p>}
        <button className="btn primary block" disabled={!ok}>
          Envoyer le sondage
        </button>
      </form>
    </Sheet>
  )
}

const LIVE_CHOICES = [
  { label: '15 min', ms: 15 * 60_000 },
  { label: '1 h', ms: 3600_000 },
  { label: '8 h', ms: 8 * 3600_000 },
]

export function LocationSheet({ convId, onClose }: { convId: string; onClose: () => void }) {
  const [pos, setPos] = useState<GeolocationPosition | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [live, setLive] = useState(0)
  useEffect(() => {
    if (!('geolocation' in navigator)) {
      setError('Ce navigateur ne donne pas la position.')
      return
    }
    const id = navigator.geolocation.watchPosition(
      (p) => setPos(p),
      (e) => setError(e.code === e.PERMISSION_DENIED ? 'Position refusée. Autorise-la dans les réglages du site.' : 'Position introuvable pour l’instant.'),
      { enableHighAccuracy: true, timeout: 20_000, maximumAge: 10_000 },
    )
    return () => navigator.geolocation.clearWatch(id)
  }, [])
  const send = async (liveMs?: number) => {
    if (!pos) return
    await relay.sendLocation(convId, { lat: pos.coords.latitude, lon: pos.coords.longitude, accuracy_m: pos.coords.accuracy }, liveMs)
    onClose()
  }
  return (
    <Sheet title="Position" onClose={onClose}>
      <div className="loc-preview">
        {pos ? (
          <StaticMap lat={pos.coords.latitude} lon={pos.coords.longitude} accuracy={pos.coords.accuracy} width={424} height={200} />
        ) : (
          <div className="loc-wait">{error ?? <span className="spinner" aria-label="Recherche de ta position" />}</div>
        )}
      </div>
      {pos && (
        <p className="hint center mono" style={{ margin: '8px 0 14px' }}>
          ±{Math.round(pos.coords.accuracy)} m
        </p>
      )}
      <button className="btn primary block" disabled={!pos} onClick={() => void send()}>
        <Pin size={18} /> Envoyer ma position
      </button>
      <div className="lbl hint" style={{ fontWeight: 600, margin: '18px 0 6px' }}>
        Partager en direct
      </div>
      <div className="seg" role="group" aria-label="Durée du partage">
        {LIVE_CHOICES.map((c, i) => (
          <button key={c.label} aria-pressed={live === i} onClick={() => setLive(i)}>
            {c.label}
          </button>
        ))}
      </div>
      <button className="btn block" disabled={!pos} onClick={() => void send(LIVE_CHOICES[live].ms)}>
        Partager en direct pendant {LIVE_CHOICES[live].label}
      </button>
      <p className="hint" style={{ marginTop: 12 }}>
        En direct, ta position part chiffrée toutes les 10 secondes au plus, tant que cet onglet reste ouvert.
      </p>
    </Sheet>
  )
}

export function ForwardSheet({ m, onClose }: { m: ChatMessage; onClose: () => void }) {
  const snap = useRelay()
  const [q, setQ] = useState('')
  const targets = [
    ...snap.conversations.map((c) => ({ id: c.id, title: c.title, group: c.kind === 'group' })),
    ...snap.contacts.filter((c) => !snap.conversations.some((x) => x.id === c.fingerprint)).map((c) => ({ id: c.fingerprint, title: c.name, group: false })),
  ].filter((t) => !q.trim() || t.title.toLowerCase().includes(q.trim().toLowerCase()))
  return (
    <Sheet title="Transférer" onClose={onClose}>
      <div className="field">
        <label htmlFor="fwd-q" className="sr-only">
          Chercher
        </label>
        <input id="fwd-q" type="search" placeholder="Chercher une discussion" value={q} onChange={(e) => setQ(e.target.value)} />
      </div>
      <ul className="list" style={{ padding: 0 }}>
        {targets.map((t) => (
          <li key={t.id}>
            <button
              className="row"
              onClick={async () => {
                onClose()
                await relay.forward(m.convId, m.id, t.id)
                relay.toast(`Transféré à ${t.title}.`)
              }}
            >
              {t.group ? (
                <span className="avatar" aria-hidden="true">
                  <People />
                </span>
              ) : (
                <Avatar name={t.title} />
              )}
              <span className="row-main">
                <span className="row-title">{t.title}</span>
              </span>
            </button>
          </li>
        ))}
        {targets.length === 0 && <p className="hint center">Aucune discussion.</p>}
      </ul>
    </Sheet>
  )
}

const fmt = (ts?: number) =>
  ts ? new Date(ts).toLocaleString('fr-FR', { weekday: 'short', day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit', second: '2-digit' }) : '–'

export function InfoSheet({ m, onClose }: { m: ChatMessage; onClose: () => void }) {
  const snap = useRelay()
  const live = snap.messages[m.convId]?.find((x) => x.id === m.id) ?? m
  const isGroup = m.convId.startsWith('g:')
  const via = live.transport === 'p2p' ? 'Pair à pair (WebRTC)' : live.transport === 'local' ? 'Bus local du navigateur' : 'Nœud relais'
  const nameOf = (fp: string) => (fp === 'me' ? 'Toi' : relay.titleOf(fp))
  return (
    <Sheet title="Infos du message" onClose={onClose}>
      <dl className="info-list">
        <dt>De</dt>
        <dd>{nameOf(live.from)}</dd>
        <dt>Chemin</dt>
        <dd>{live.from === 'me' && live.status === 'pending' ? 'En file d’attente sur cet appareil' : via}</dd>
        <dt>Chiffrement</dt>
        <dd>{snap.engineKind === 'mock' ? 'simulé (moteur de test)' : isGroup ? 'Clés d’expéditeur de groupe, AES-256-GCM' : 'ML-KEM-1024 + X25519, AES-256-GCM'}</dd>
        <dt>{live.from === 'me' ? 'Envoyé' : 'Écrit'}</dt>
        <dd>{fmt(live.ts)}</dd>
        {live.from === 'me' ? (
          <>
            <dt>État</dt>
            <dd>{statusWord(live, isGroup)}</dd>
            {live.times?.sent && (
              <>
                <dt>Parti</dt>
                <dd>{fmt(live.times.sent)}</dd>
              </>
            )}
            {live.times?.delivered && (
              <>
                <dt>Reçu</dt>
                <dd>{fmt(live.times.delivered)}</dd>
              </>
            )}
            {live.times?.read && (
              <>
                <dt>Lu</dt>
                <dd>{fmt(live.times.read)}</dd>
              </>
            )}
          </>
        ) : (
          <>
            <dt>Reçu</dt>
            <dd>{fmt(live.times?.received)}</dd>
          </>
        )}
        {live.editedAt && (
          <>
            <dt>Modifié</dt>
            <dd>{fmt(live.editedAt)}</dd>
          </>
        )}
        {live.expireS ? (
          <>
            <dt>Éphémère</dt>
            <dd>
              {expireLabel(live.expireS)}
              {live.expireAt ? `, effacé ${fmt(live.expireAt)}` : ', après lecture'}
            </dd>
          </>
        ) : null}
        {live.attachment && (
          <>
            <dt>Fichier</dt>
            <dd className="mono">
              {live.attachment.mime} · {live.attachment.size} o · sha256 {live.attachment.sha256.slice(0, 16)}…
            </dd>
          </>
        )}
        <dt>Identifiant</dt>
        <dd className="mono">{live.id}</dd>
      </dl>
      {live.kind === 'poll' && live.poll && (
        <>
          <div className="lbl hint" style={{ fontWeight: 600, margin: '14px 0 6px' }}>
            Votes
          </div>
          {live.poll.options.map((o) => {
            const who = Object.entries(live.votes ?? {})
              .filter(([, v]) => v.opts.includes(o.id))
              .map(([fp]) => nameOf(fp))
            return (
              <p key={o.id} className="hint">
                <b style={{ color: 'var(--fg)' }}>{o.text}</b> · {who.length ? who.join(', ') : 'personne'}
              </p>
            )
          })}
        </>
      )}
    </Sheet>
  )
}
