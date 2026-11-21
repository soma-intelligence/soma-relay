import { useCallback, useEffect, useRef, useState } from 'react'
import { relay } from '../state/relay'
import { Avatar, copyText, Sheet, useRelay } from './common'
import { CipherQR, type CipherStage } from './CipherQR'
import { QrScanner } from './QrScanner'
import { Check, Copy, Phone, Shield, Video } from './Icons'

function wordLines(words: string[]): string[] {
  return [words.slice(0, 2).join(' '), words.slice(2).join(' ')]
}

/** Add by QR scan, by pasting a relay1:/relay1c: link, or by handle@node. */
export function AddContactSheet({ onClose, onAdded }: { onClose: () => void; onAdded: (fp: string) => void }) {
  const [mode, setMode] = useState<'scan' | 'paste' | 'handle'>(() =>
    typeof navigator.mediaDevices?.getUserMedia === 'function' && matchMedia('(pointer: coarse)').matches ? 'scan' : 'paste',
  )
  const [value, setValue] = useState('')
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)

  const add = useCallback(
    async (input: string) => {
      setBusy(true)
      setError(null)
      try {
        const c = await relay.addFromText(input)
        relay.toast(`${c.name} ajouté. Vérifiez vos mots de sécurité.`)
        onAdded(c.fingerprint)
      } catch (e) {
        setError(e instanceof Error ? e.message : 'Ajout impossible.')
        setBusy(false)
      }
    },
    [onAdded],
  )

  return (
    <Sheet title="Ajouter un contact" onClose={onClose}>
      <div className="seg" role="group" aria-label="Méthode">
        <button aria-pressed={mode === 'scan'} onClick={() => setMode('scan')}>
          Scanner
        </button>
        <button aria-pressed={mode === 'paste'} onClick={() => setMode('paste')}>
          Lien
        </button>
        <button aria-pressed={mode === 'handle'} onClick={() => setMode('handle')}>
          Identifiant
        </button>
      </div>
      {mode === 'scan' && <QrScanner onResult={(t) => void add(t)} />}
      {mode === 'paste' && (
        <form
          onSubmit={(e) => {
            e.preventDefault()
            void add(value)
          }}
        >
          <div className="field">
            <label htmlFor="add-link">Son lien</label>
            <textarea
              id="add-link"
              value={value}
              onChange={(e) => setValue(e.target.value)}
              placeholder="relay1:… ou relay1c:…"
              spellCheck={false}
              autoCapitalize="off"
            />
          </div>
          <button className="btn primary block" disabled={!value.trim() || busy}>
            {busy ? 'Vérification de la carte…' : 'Ajouter'}
          </button>
        </form>
      )}
      {mode === 'handle' && (
        <form
          onSubmit={(e) => {
            e.preventDefault()
            void add(value)
          }}
        >
          <div className="field">
            <label htmlFor="add-handle">Identifiant</label>
            <input
              id="add-handle"
              value={value}
              onChange={(e) => setValue(e.target.value)}
              placeholder="ines@relay.somalabs.me"
              autoCapitalize="off"
              autoCorrect="off"
              spellCheck={false}
            />
            <span className="hint">Sans @nœud, on cherche sur ton nœud.</span>
          </div>
          <button className="btn primary block" disabled={!value.trim() || busy}>
            {busy ? 'Recherche…' : 'Chercher dans l’annuaire'}
          </button>
        </form>
      )}
      {error && (
        <p className="error" role="alert" style={{ marginTop: 12 }}>
          {error}
        </p>
      )}
    </Sheet>
  )
}

/**
 * My code: the compact link as a cipher QR. When someone adds me while it is open (a new
 * contact appears), the tile dissolves and settles into our four safety words.
 */
export function MyCodeSheet({ onClose }: { onClose: () => void }) {
  const snap = useRelay()
  const me = snap.me!
  const [stage, setStage] = useState<CipherStage>(() => ({ kind: 'code', text: relay.myCompactLink() }))
  const [peer, setPeer] = useState<string | null>(null)
  const known = useRef(new Set(snap.contacts.map((c) => c.fingerprint)))
  const [copied, setCopied] = useState<'link' | 'card' | null>(null)

  useEffect(() => {
    const fresh = snap.contacts.find((c) => !known.current.has(c.fingerprint))
    if (!fresh || peer) return
    setPeer(fresh.fingerprint)
    setStage({ kind: 'connecting' })
    const t = setTimeout(
      () => setStage({ kind: 'verify', lines: wordLines(relay.safetyWords(fresh.fingerprint)) }),
      900,
    )
    return () => clearTimeout(t)
  }, [snap.contacts, peer])

  const copy = async (what: 'link' | 'card') => {
    const ok = await copyText(what === 'link' ? relay.myCompactLink() : relay.myCard())
    if (ok) {
      setCopied(what)
      setTimeout(() => setCopied(null), 1600)
    }
  }
  const peerContact = peer ? snap.contacts.find((c) => c.fingerprint === peer) : null

  return (
    <Sheet title={peerContact ? `Connecté à ${peerContact.name}` : 'Mon code'} onClose={onClose}>
      <div className="qr-box">
        <CipherQR
          stage={stage}
          label={stage.kind === 'verify' ? `Mots de sécurité : ${stage.lines.join(' ')}` : 'Ton code QR Soma Relay'}
        />
      </div>
      {peerContact ? (
        <>
          <p className="hint center" style={{ marginTop: 14 }}>
            Mêmes mots sur son écran ? Alors personne ne s’est glissé entre vous.
          </p>
          <div className="row-btns">
            <button
              className="btn primary"
              onClick={() => {
                relay.setVerified(peerContact.fingerprint, true)
                onClose()
              }}
            >
              <Check /> Les mots sont identiques
            </button>
          </div>
        </>
      ) : (
        <>
          <div className="words" aria-label="Tes mots d’empreinte">
            {me.words.map((w) => (
              <span className="word" key={w}>
                {w}
              </span>
            ))}
          </div>
          <p className="fp-grid">{me.fingerprint.toUpperCase().match(/.{1,4}/g)?.join('·')}</p>
          {snap.settings.handle && (
            <p className="center mono" style={{ fontSize: 13 }}>
              {snap.settings.handle}@{new URL(snap.nodeBase).host}
            </p>
          )}
          <div className="row-btns">
            <button className="btn" onClick={() => void copy('link')}>
              <Copy /> {copied === 'link' ? 'Copié' : 'Lien court'}
            </button>
            <button className="btn" onClick={() => void copy('card')}>
              <Copy /> {copied === 'card' ? 'Copié' : 'Carte complète'}
            </button>
          </div>
          <p className="hint center" style={{ marginTop: 12 }}>
            Le lien court suffit quand ton nœud est joignable. La carte complète marche partout.
          </p>
        </>
      )}
    </Sheet>
  )
}

/** Contact details, safety words and verification. */
export function ContactSheet({ fp, onClose }: { fp: string; onClose: () => void }) {
  const snap = useRelay()
  const c = snap.contacts.find((x) => x.fingerprint === fp)
  const [stage, setStage] = useState<CipherStage>({ kind: 'connecting' })
  const [name, setName] = useState(c?.name ?? '')
  const [confirmRemove, setConfirmRemove] = useState(false)
  useEffect(() => {
    const t = setTimeout(() => setStage({ kind: 'verify', lines: wordLines(relay.safetyWords(fp)) }), 500)
    return () => clearTimeout(t)
  }, [fp])
  if (!c) return null
  const code = relay.safetyCode(fp)
  return (
    <Sheet title={c.name} onClose={onClose}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 12, marginBottom: 12 }}>
        <Avatar name={c.name} online={snap.online.has(c.mailbox)} />
        <div style={{ flex: 1, minWidth: 0 }}>
          <div className="mono" style={{ fontSize: 11, color: 'var(--muted)', overflowWrap: 'anywhere' }}>
            {c.fingerprint.toUpperCase().match(/.{1,4}/g)?.join('·')}
          </div>
          {c.handle && (
            <div className="mono" style={{ fontSize: 12, marginTop: 4 }}>
              {c.handle}
              {c.node_url ? `@${new URL(c.node_url).host}` : ''}
            </div>
          )}
        </div>
      </div>
      <div className="row-btns" style={{ marginTop: 0, marginBottom: 16 }}>
        <button
          className="btn"
          onClick={() => {
            onClose()
            void relay.calls.start(fp, false)
          }}
        >
          <Phone /> Appeler
        </button>
        <button
          className="btn"
          onClick={() => {
            onClose()
            void relay.calls.start(fp, true)
          }}
        >
          <Video /> Vidéo
        </button>
      </div>
      <div className="lbl hint" style={{ fontWeight: 600, marginBottom: 6 }}>
        Vos mots de sécurité
      </div>
      <div className="qr-box" style={{ width: 'min(240px, 100%)' }}>
        <CipherQR stage={stage} label={`Mots de sécurité avec ${c.name}`} />
      </div>
      <p className="code-big" aria-label={`Code de sécurité ${code}`}>
        {code}
      </p>
      <p className="hint center">
        Comparez ces mots en vrai ou au téléphone. S’ils sont identiques des deux côtés, vos clés sont les bonnes.
      </p>
      <div className="row-btns">
        {c.verified ? (
          <button className="btn" onClick={() => relay.setVerified(fp, false)}>
            <Shield /> Vérifié, annuler
          </button>
        ) : (
          <button className="btn primary" onClick={() => relay.setVerified(fp, true)}>
            <Check /> Marquer comme vérifié
          </button>
        )}
      </div>
      <form
        style={{ marginTop: 20 }}
        onSubmit={(e) => {
          e.preventDefault()
          if (name.trim()) relay.renameContact(fp, name.trim())
        }}
      >
        <div className="field">
          <label htmlFor="rename">Nom affiché chez toi</label>
          <div style={{ display: 'flex', gap: 8 }}>
            <input id="rename" value={name} onChange={(e) => setName(e.target.value)} style={{ flex: 1 }} />
            <button className="btn" disabled={!name.trim() || name === c.name}>
              Renommer
            </button>
          </div>
        </div>
      </form>
      {confirmRemove ? (
        <div className="stack">
          <p className="hint">La conversation et ses pièces jointes seront effacées de cet appareil. Pas de retour possible.</p>
          <div className="row-btns" style={{ marginTop: 0 }}>
            <button className="btn" onClick={() => setConfirmRemove(false)}>
              Garder
            </button>
            <button
              className="btn danger"
              onClick={() => {
                void relay.removeContact(fp)
                onClose()
              }}
            >
              Supprimer
            </button>
          </div>
        </div>
      ) : (
        <button className="btn block" style={{ color: 'var(--danger)' }} onClick={() => setConfirmRemove(true)}>
          Supprimer le contact
        </button>
      )}
    </Sheet>
  )
}

export function NewGroupSheet({ onClose, onCreated }: { onClose: () => void; onCreated: (convId: string) => void }) {
  const snap = useRelay()
  const [name, setName] = useState('')
  const [picked, setPicked] = useState<string[]>([])
  const [error, setError] = useState<string | null>(null)
  const toggle = (fp: string) => setPicked((p) => (p.includes(fp) ? p.filter((x) => x !== fp) : [...p, fp]))
  return (
    <Sheet title="Nouveau groupe" onClose={onClose}>
      <form
        onSubmit={async (e) => {
          e.preventDefault()
          try {
            onCreated(await relay.createGroup(name, picked))
          } catch (err) {
            setError(err instanceof Error ? err.message : 'Création impossible.')
          }
        }}
      >
        <div className="field">
          <label htmlFor="group-name">Nom du groupe</label>
          <input id="group-name" value={name} onChange={(e) => setName(e.target.value)} placeholder="Festival" maxLength={60} />
        </div>
        <fieldset style={{ border: 0, padding: 0, margin: '0 0 16px' }}>
          <legend className="lbl hint" style={{ fontWeight: 600, marginBottom: 6 }}>
            Membres · {picked.length}
          </legend>
          {snap.contacts.length === 0 && <p className="hint">Ajoute d’abord des contacts.</p>}
          {snap.contacts.map((c) => (
            <label className="check-row" key={c.fingerprint}>
              <input type="checkbox" checked={picked.includes(c.fingerprint)} onChange={() => toggle(c.fingerprint)} />
              <Avatar name={c.name} small />
              <span>{c.name}</span>
            </label>
          ))}
        </fieldset>
        {error && <p className="error">{error}</p>}
        <button className="btn primary block" disabled={!name.trim() || picked.length === 0}>
          Créer le groupe
        </button>
      </form>
    </Sheet>
  )
}

export function GroupSheet({ gid, onClose }: { gid: string; onClose: () => void }) {
  const snap = useRelay()
  const g = snap.groups.find((x) => x.id === gid)
  const [adding, setAdding] = useState(false)
  const [confirmLeave, setConfirmLeave] = useState(false)
  if (!g) return null
  const me = snap.me!.fingerprint
  const isAdmin = g.admins.includes(me)
  const nameOf = (fp: string) => (fp === me ? 'Toi' : (snap.contacts.find((c) => c.fingerprint === fp)?.name ?? fp.slice(0, 8)))
  const candidates = snap.contacts.filter((c) => !g.members.includes(c.fingerprint))
  return (
    <Sheet title={g.name} onClose={onClose}>
      <div className="lbl hint" style={{ fontWeight: 600 }}>
        Membres · {g.members.length}
      </div>
      <ul className="list" style={{ padding: '6px 0' }}>
        {g.members.map((fp) => (
          <li key={fp} className="check-row">
            <Avatar name={nameOf(fp)} small />
            <span style={{ flex: 1 }}>
              {nameOf(fp)}
              {g.admins.includes(fp) && <span className="mono hint"> · admin</span>}
            </span>
            {isAdmin && fp !== me && (
              <button className="btn" style={{ height: 34 }} onClick={() => void relay.groupRemove(gid, fp)}>
                Retirer
              </button>
            )}
          </li>
        ))}
      </ul>
      {adding ? (
        <div>
          <div className="lbl hint" style={{ fontWeight: 600, marginTop: 8 }}>
            Ajouter
          </div>
          {candidates.length === 0 && <p className="hint">Tous tes contacts sont déjà là.</p>}
          {candidates.map((c) => (
            <div className="check-row" key={c.fingerprint}>
              <Avatar name={c.name} small />
              <span style={{ flex: 1 }}>{c.name}</span>
              <button className="btn primary" style={{ height: 34 }} onClick={() => void relay.groupAdd(gid, c.fingerprint)}>
                Ajouter
              </button>
            </div>
          ))}
        </div>
      ) : (
        <button className="btn block" onClick={() => setAdding(true)} disabled={!isAdmin}>
          Ajouter des membres
        </button>
      )}
      <div style={{ marginTop: 12 }}>
        {confirmLeave ? (
          <div className="row-btns">
            <button className="btn" onClick={() => setConfirmLeave(false)}>
              Rester
            </button>
            <button
              className="btn danger"
              onClick={() => {
                void relay.leaveGroup(gid)
                onClose()
              }}
            >
              Quitter et effacer
            </button>
          </div>
        ) : (
          <button className="btn block" style={{ color: 'var(--danger)' }} onClick={() => setConfirmLeave(true)}>
            Quitter le groupe
          </button>
        )}
      </div>
    </Sheet>
  )
}
