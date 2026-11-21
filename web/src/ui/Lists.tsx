import { useMemo, useState } from 'react'
import type { Conversation } from '../state/types'
import { Avatar, timeLabel, useRelay } from './common'
import { People, Qr, Radio, Search } from './Icons'

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

  return (
    <div className="scroll">
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
          {snap.conversations.map((c) => (
            <li key={c.id}>
              <button
                className="row"
                aria-current={snap.activeConv === c.id}
                onClick={() => onOpen(c.id)}
                aria-label={`${c.title}${c.unread ? `, ${c.unread} non lu${c.unread > 1 ? 's' : ''}` : ''}`}
              >
                {c.kind === 'group' ? (
                  <span className="avatar" aria-hidden="true">
                    <People />
                  </span>
                ) : (
                  <Avatar name={c.title} online={onlineOf(c)} />
                )}
                <span className="row-main">
                  <span className="row-line">
                    <span className="row-title">{c.title}</span>
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
                    {c.unread > 0 && <span className="badge">{c.unread}</span>}
                  </span>
                </span>
              </button>
            </li>
          ))}
        </ul>
      )}
      <ChannelNote />
    </div>
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
              <Avatar name={snap.me?.name ?? '?'} />
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
                <span className="avatar" aria-hidden="true">
                  <People />
                </span>
                <span className="row-main">
                  <span className="row-title">{g.name}</span>
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
                  <Avatar name={c.name} online={snap.online.has(c.mailbox)} />
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

