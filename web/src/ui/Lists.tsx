import { useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react'
import type { Conversation } from '../state/types'
import { relay } from '../state/relay'
import { Avatar, timeLabel, useRelay } from './common'
import { BellOff, People, Qr, Radio, Search, Timer } from './Icons'

const reduced = () => matchMedia('(prefers-reduced-motion: reduce)').matches

/**
 * FLIP reorder: rows that moved slide from their old place with a gentle spring, a new row at
 * the top grows in. Reduced motion: a short fade instead.
 */
function useFlip(order: string[]) {
  const nodes = useRef(new Map<string, HTMLElement>())
  const tops = useRef(new Map<string, number>())
  const first = useRef(true)
  useLayoutEffect(() => {
    const next = new Map<string, number>()
    for (const [id, el] of nodes.current) if (el.isConnected) next.set(id, el.offsetTop)
    if (!first.current) {
      for (const [id, top] of next) {
        const el = nodes.current.get(id)!
        const was = tops.current.get(id)
        if (was === undefined) {
          el.animate(
            reduced()
              ? [{ opacity: 0 }, { opacity: 1 }]
              : [
                  { opacity: 0, transform: 'translateY(-10px) scale(0.97)' },
                  { opacity: 1, transform: 'none' },
                ],
            { duration: reduced() ? 160 : 380, easing: 'cubic-bezier(0.2, 0.8, 0.2, 1)' },
          )
        } else if (Math.abs(was - top) > 1) {
          if (reduced()) el.animate([{ opacity: 0.4 }, { opacity: 1 }], { duration: 180 })
          else
            el.animate([{ transform: `translateY(${was - top}px)` }, { transform: 'none' }], {
              duration: 460,
              easing: springOk() ? SPRING : 'cubic-bezier(0.2, 0.8, 0.2, 1)',
            })
        }
      }
    }
    first.current = false
    tops.current = next
  }, [order.join('|')])
  return (id: string) => (el: HTMLElement | null) => {
    if (el) nodes.current.set(id, el)
    else nodes.current.delete(id)
  }
}

const SPRING =
  'linear(0, 0.06 2.5%, 0.24 5.5%, 0.5 9.5%, 0.74 14%, 0.9 19%, 1 24%, 1.04 30%, 1.05 36%, 1.035 44%, 1.01 56%, 0.998 70%, 1)'
let springSupport: boolean | null = null
const springOk = () => (springSupport ??= typeof CSS !== 'undefined' && CSS.supports('animation-timing-function', SPRING))

/** Text with the first match of `needle` marked. */
export function Highlight({ text, needle }: { text: string; needle: string }) {
  const i = needle ? text.toLowerCase().indexOf(needle) : -1
  if (i < 0) return <>{text}</>
  return (
    <>
      {text.slice(0, i)}
      <mark>{text.slice(i, i + needle.length)}</mark>
      {text.slice(i + needle.length)}
    </>
  )
}

export function TransportBadge({ t }: { t?: string }) {
  if (!t) return null
  const label = t === 'p2p' ? 'P2P' : t === 'local' ? 'LOCAL' : 'NET'
  return <span className={`tbadge ${t === 'p2p' ? 'p2p' : 'net'}`}>{label}</span>
}

export function ConversationList({ onOpen, onNew }: { onOpen: (id: string) => void; onNew: () => void }) {
  const snap = useRelay()
  const now = Date.now()
  const onlineOf = (c: Conversation) => {
    if (c.kind !== 'direct') return false
    const contact = snap.contacts.find((x) => x.fingerprint === c.id)
    return !!contact && snap.online.has(contact.mailbox)
  }
  const isTyping = (c: Conversation) =>
    Object.entries(snap.typing).some(([k, until]) => k.startsWith(c.id + '|') && until > now)
  const [q, setQ] = useState('')
  const [hits, setHits] = useState<{ convId: string; id: string; text: string; ts: number }[]>([])
  useEffect(() => {
    const n = q.trim()
    if (n.length < 2) {
      setHits([])
      return
    }
    let off = false
    const t = setTimeout(() => void relay.search(n).then((h) => !off && setHits(h)), 180)
    return () => {
      off = true
      clearTimeout(t)
    }
  }, [q, snap.conversations])
  const needle = q.trim().toLowerCase()
  const convs = needle ? snap.conversations.filter((c) => c.title.toLowerCase().includes(needle)) : snap.conversations
  const flipRef = useFlip(convs.map((c) => c.id))

  return (
    <>
    {snap.conversations.length > 0 && (
      <div className="search">
        <Search />
        <label htmlFor="conv-search" className="sr-only">
          Chercher dans les discussions
        </label>
        <input id="conv-search" type="search" placeholder="Chercher noms et messages" value={q} onChange={(e) => setQ(e.target.value)} />
      </div>
    )}
    <div className="scroll">
      {needle.length >= 2 && (
        <>
          {convs.length === 0 && hits.length === 0 && <p className="empty" style={{ paddingTop: 12 }}>Aucun résultat.</p>}
          {hits.length > 0 && <div className="section-label">Messages · {hits.length}</div>}
          <ul className="list" style={{ paddingTop: 0 }} aria-label="Messages trouvés">
            {hits.map((h) => (
              <li key={h.id}>
                <button
                  className="row hit"
                  onClick={() => {
                    relay.setJump(h.convId, h.id)
                    onOpen(h.convId)
                  }}
                >
                  <Avatar id={h.convId} name={relay.titleOf(h.convId)} group={h.convId.startsWith('g:')} small />
                  <span className="row-main">
                    <span className="row-line">
                      <span className="row-title">{relay.titleOf(h.convId)}</span>
                      <span className="row-meta">{timeLabel(h.ts)}</span>
                    </span>
                    <span className="row-sub">{snippet(h.text, needle)}</span>
                  </span>
                </button>
              </li>
            ))}
          </ul>
          {convs.length > 0 && <div className="section-label">Discussions</div>}
        </>
      )}
      {snap.conversations.length === 0 ? (
        <div className="empty">
          <svg width="76" height="76" viewBox="0 0 76 76" aria-hidden="true">
            <circle cx="38" cy="38" r="36" fill="none" stroke="var(--radar-line)" />
            <circle cx="38" cy="38" r="22" fill="none" stroke="var(--radar-line)" />
            <circle cx="38" cy="38" r="4" fill="var(--fg)" />
          </svg>
          <h2>Personne à portée pour l’instant</h2>
          <p>Ajoute un contact avec son QR, son lien relay1 ou son identifiant, puis écris-lui.</p>
          <div className="actions">
            <button className="btn primary" onClick={onNew}>
              Ajouter un contact
            </button>
          </div>
        </div>
      ) : (
        <ul className="list" aria-label="Discussions">
          {convs.map((c) => (
            <li key={c.id} ref={flipRef(c.id)}>
              <button
                className={`row${c.unread > 0 ? ' unread' : ''}`}
                aria-current={snap.activeConv === c.id}
                onClick={() => onOpen(c.id)}
                aria-label={`${c.title}${c.unread ? `, ${c.unread} non lu${c.unread > 1 ? 's' : ''}` : ''}`}
              >
                <Avatar id={c.id} name={c.title} group={c.kind === 'group'} online={onlineOf(c)} />
                <span className="row-main">
                  <span className="row-line">
                    <span className="row-title">
                      <Highlight text={c.title} needle={needle.length >= 2 ? needle : ''} />
                    </span>
                    {c.expireS ? <Timer size={13} aria-label="Messages éphémères" className="row-ico" /> : null}
                    {c.mutedUntil && c.mutedUntil > now ? <BellOff size={13} aria-label="En sourdine" className="row-ico" /> : null}
                    <span className="row-meta">{timeLabel(c.lastTs)}</span>
                  </span>
                  <span className="row-line">
                    {isTyping(c) ? (
                      <span className="row-sub typing">écrit…</span>
                    ) : c.draft ? (
                      <span className="row-sub draft">
                        <em>Brouillon :</em> {c.draft}
                      </span>
                    ) : (
                      <span className="row-sub">{c.preview}</span>
                    )}
                    <TransportBadge t={c.transport} />
                    {c.unread > 0 && (
                      <span className="badge" key={c.unread}>
                        {c.unread}
                      </span>
                    )}
                  </span>
                </span>
              </button>
            </li>
          ))}
        </ul>
      )}
      <ChannelNote />
    </div>
    </>
  )
}

function snippet(text: string, needle: string): React.ReactNode {
  const i = text.toLowerCase().indexOf(needle)
  if (i < 0) return text
  const start = Math.max(0, i - 24)
  return (
    <>
      {start > 0 ? '…' : ''}
      {text.slice(start, i)}
      <mark>{text.slice(i, i + needle.length)}</mark>
      {text.slice(i + needle.length, i + needle.length + 80)}
    </>
  )
}

export function ChannelNote() {
  return (
    <div className="channel-note" role="note">
      <Radio />
      <div>
        <strong>Canaux locaux</strong>
        Les canaux comme #festival passent seulement par le mesh Bluetooth et Wi-Fi entre téléphones proches. Le
        navigateur n’y a pas accès : ouvre l’app sur ton iPhone pour les rejoindre.
      </div>
    </div>
  )
}

export function ContactList({
  onOpen,
  onAdd,
  onMyCode,
  onGroup,
}: {
  onOpen: (fp: string) => void
  onAdd: () => void
  onMyCode: () => void
  onGroup: () => void
}) {
  const snap = useRelay()
  const [q, setQ] = useState('')
  const list = useMemo(() => {
    const n = q.trim().toLowerCase()
    return [...snap.contacts]
      .filter((c) => !n || c.name.toLowerCase().includes(n) || (c.handle ?? '').includes(n) || c.fingerprint.startsWith(n))
      .sort((a, b) => a.name.localeCompare(b.name, 'fr'))
  }, [snap.contacts, q])
  const groups = snap.groups.filter((g) => !q.trim() || g.name.toLowerCase().includes(q.trim().toLowerCase()))

  return (
    <>
      <div className="search">
        <Search />
        <label htmlFor="contact-search" className="sr-only">
          Chercher un contact
        </label>
        <input
          id="contact-search"
          type="search"
          placeholder="Chercher"
          value={q}
          onChange={(e) => setQ(e.target.value)}
        />
      </div>
      <div className="scroll">
        <ul className="list">
          <li>
            <button className="row" onClick={onAdd}>
              <span className="avatar" aria-hidden="true">
                <Qr />
              </span>
              <span className="row-main">
                <span className="row-title">Ajouter un contact</span>
                <span className="row-sub">QR, lien relay1 ou nom@nœud</span>
              </span>
            </button>
          </li>
          <li>
            <button className="row" onClick={onGroup}>
              <span className="avatar" aria-hidden="true">
                <People />
              </span>
              <span className="row-main">
                <span className="row-title">Nouveau groupe</span>
                <span className="row-sub">Privé, chiffré de bout en bout</span>
              </span>
            </button>
          </li>
          <li>
            <button className="row" onClick={onMyCode}>
              <Avatar id="me" name={snap.me?.name ?? '?'} />
              <span className="row-main">
                <span className="row-title">Mon code</span>
                <span className="row-sub">À montrer pour qu’on t’ajoute</span>
              </span>
            </button>
          </li>
        </ul>
        {groups.length > 0 && <div className="section-label">Groupes</div>}
        <ul className="list" style={{ paddingTop: 0, paddingBottom: 0 }}>
          {groups.map((g) => (
            <li key={g.id}>
              <button className="row" onClick={() => onOpen(`g:${g.id}`)}>
                <Avatar id={`g:${g.id}`} name={relay.titleOf(`g:${g.id}`)} group />
                <span className="row-main">
                  <span className="row-title">{relay.titleOf(`g:${g.id}`)}</span>
                  <span className="row-sub">{g.members.length} membres</span>
                </span>
              </button>
            </li>
          ))}
        </ul>
        <div className="section-label">Contacts · {snap.contacts.length}</div>
        {list.length === 0 ? (
          <p className="empty" style={{ paddingTop: 12 }}>
            {q ? 'Aucun résultat.' : 'Pas encore de contact.'}
          </p>
        ) : (
          <ul className="list" style={{ paddingTop: 0 }}>
            {list.map((c) => (
              <li key={c.fingerprint}>
                <button className="row" onClick={() => onOpen(c.fingerprint)}>
                  <Avatar id={c.fingerprint} name={c.name} online={snap.online.has(c.mailbox)} />
                  <span className="row-main">
                    <span className="row-title">{c.name}</span>
                    <span className="row-sub mono" style={{ fontSize: 11 }}>
                      {c.handle ? `${c.handle} · ` : ''}
                      {c.fingerprint.slice(0, 8).toUpperCase().replace(/(.{4})/, '$1·')}
                      {c.verified ? ' · vérifié' : ''}
                    </span>
                  </span>
                </button>
              </li>
            ))}
          </ul>
        )}
      </div>
    </>
  )
}

export function useUnreadTotal(): number {
  const snap = useRelay()
  return snap.conversations.reduce((a, c) => a + c.unread, 0)
}

