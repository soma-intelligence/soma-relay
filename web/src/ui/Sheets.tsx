import { useCallback, useEffect, useMemo, useState } from 'react'
import { expireLabel, relay } from '../state/relay'
import { EXPIRE_CHOICES, MUTE_ALWAYS } from '../state/types'
import { Avatar, Sheet, useRelay } from './common'
import { CipherQR, type CipherStage } from './CipherQR'
import { QrScanner } from './QrScanner'
import { AvatarPicker } from './PhotoEditor'
import { Check, Pencil, People, Phone, Shield, Video } from './Icons'

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
        relay.toast(`Contact ajouté : ${c.name}. Vérifiez vos mots de sécurité.`)
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
        <Avatar id={fp} name={c.name} online={snap.online.has(c.mailbox)} size={64} />
        <div style={{ flex: 1, minWidth: 0 }}>
          <div className="mono" style={{ fontSize: 11, color: 'var(--muted)', overflowWrap: 'anywhere' }}>
            {c.fingerprint.toUpperCase().match(/.{1,4}/g)?.join('·\u200b')}
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
      <ConvOptions convId={fp} />
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
  const [q, setQ] = useState('')
  const [photo, setPhoto] = useState<Uint8Array | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const toggle = (fp: string) => setPicked((p) => (p.includes(fp) ? p.filter((x) => x !== fp) : [...p, fp]))
  const photoUrl = useMemo(() => (photo ? URL.createObjectURL(new Blob([photo.slice().buffer as ArrayBuffer], { type: 'image/jpeg' })) : null), [photo])
  useEffect(() => () => void (photoUrl && URL.revokeObjectURL(photoUrl)), [photoUrl])
  const needle = q.trim().toLowerCase()
  const list = [...snap.contacts]
    .filter((c) => !needle || c.name.toLowerCase().includes(needle))
    .sort((a, b) => a.name.localeCompare(b.name, 'fr'))
  return (
    <Sheet title="Nouveau groupe" onClose={onClose}>
      <form
        onSubmit={async (e) => {
          e.preventDefault()
          if (busy) return
          setBusy(true)
          try {
            onCreated(await relay.createGroup(name, picked, photo))
          } catch (err) {
            setError(err instanceof Error ? err.message : 'Création impossible.')
            setBusy(false)
          }
        }}
      >
        <div className="group-id">
          <span className={`avatar group-photo${photoUrl ? ' has-photo' : ''}`} aria-hidden="true" style={{ width: 64, height: 64, borderRadius: 32 }}>
            {photoUrl ? <img className="avatar-img ready" src={photoUrl} alt="" /> : <People size={26} />}
          </span>
          <div className="field" style={{ flex: 1, margin: 0 }}>
            <label htmlFor="group-name">Nom du groupe</label>
            <input id="group-name" value={name} onChange={(e) => setName(e.target.value)} placeholder="Festival" maxLength={60} />
          </div>
        </div>
        <AvatarPicker has={!!photo} onPick={(jpeg) => setPhoto(jpeg)} compact selfie={false} />
        {picked.length > 0 && (
          <div className="picked" aria-label="Membres choisis">
            {picked.map((fp) => (
              <button type="button" key={fp} className="picked-chip" onClick={() => toggle(fp)} aria-label={`Retirer ${relay.nameOf(fp)}`}>
                <Avatar id={fp} name={relay.nameOf(fp)} size={44} />
                <span>{relay.nameOf(fp).split(' ')[0]}</span>
                <i aria-hidden="true">×</i>
              </button>
            ))}
          </div>
        )}
        <fieldset className="pick-list">
          <legend className="lbl hint">
            Membres · {picked.length} sur {snap.contacts.length}
          </legend>
          {snap.contacts.length > 6 && (
            <input type="search" className="pick-search" placeholder="Chercher un contact" value={q} onChange={(e) => setQ(e.target.value)} aria-label="Chercher un contact" />
          )}
          {snap.contacts.length === 0 && <p className="hint">Ajoute d’abord des contacts.</p>}
          {list.map((c) => {
            const on = picked.includes(c.fingerprint)
            return (
              <label className={`pick-row${on ? ' on' : ''}`} key={c.fingerprint}>
                <input type="checkbox" className="sr-only" checked={on} onChange={() => toggle(c.fingerprint)} />
                <Avatar id={c.fingerprint} name={c.name} small />
                <span className="pick-name">{c.name}</span>
                <span className="checkmark" aria-hidden="true">
                  <Check size={14} />
                </span>
              </label>
            )
          })}
        </fieldset>
        {error && <p className="error">{error}</p>}
        <button className="btn primary block" disabled={!name.trim() || picked.length === 0 || busy}>
          {busy ? 'Création…' : picked.length ? `Créer le groupe à ${picked.length + 1}` : 'Créer le groupe'}
        </button>
      </form>
    </Sheet>
  )
}

export function GroupSheet({ gid, onClose }: { gid: string; onClose: () => void }) {
  const snap = useRelay()
  const g = snap.groups.find((x) => x.id === gid)
  const convId = `g:${gid}`
  const [adding, setAdding] = useState(false)
  const [confirmLeave, setConfirmLeave] = useState(false)
  const [removing, setRemoving] = useState<string | null>(null)
  const [name, setName] = useState(() => relay.titleOf(convId))
  const [editPhoto, setEditPhoto] = useState(false)
  if (!g) return null
  const title = relay.titleOf(convId)
  const me = snap.me!.fingerprint
  const isAdmin = g.admins.includes(me)
  const nameOf = (fp: string) => (fp === me ? 'Toi' : relay.nameOf(fp))
  const candidates = snap.contacts.filter((c) => !g.members.includes(c.fingerprint))
  const members = [...g.members].sort((a, b) => (a === me ? -1 : b === me ? 1 : nameOf(a).localeCompare(nameOf(b), 'fr')))
  const act = (p: Promise<unknown>) => void p.catch((e) => relay.toast(e instanceof Error ? e.message : 'Action impossible.'))
  return (
    <Sheet title={title} onClose={onClose}>
      <div className="group-hero">
        {isAdmin ? (
          <button className="mycard-face" data-autofocus onClick={() => setEditPhoto((v) => !v)} aria-label="Modifier la photo du groupe" aria-expanded={editPhoto}>
            <Avatar id={convId} name={title} group size={84} />
            <span className="mycard-edit" aria-hidden="true">
              <Pencil size={13} />
            </span>
          </button>
        ) : (
          <Avatar id={convId} name={title} group size={84} />
        )}
        <div className="hint mono">
          {g.members.length} membres · chiffré de bout en bout
        </div>
      </div>
      {isAdmin && editPhoto && (
        <AvatarPicker
          has={!!snap.profiles[convId]?.avatar}
          selfie={false}
          onPick={async (jpeg) => {
            setEditPhoto(false)
            act(relay.setGroupProfile(gid, { avatar: jpeg }))
          }}
        />
      )}
      {isAdmin && (
        <form
          style={{ marginTop: 6 }}
          onSubmit={(e) => {
            e.preventDefault()
            if (name.trim() && name.trim() !== title) act(relay.setGroupProfile(gid, { name: name.trim() }))
          }}
        >
          <div className="field">
            <label htmlFor="group-rename">Nom du groupe</label>
            <div style={{ display: 'flex', gap: 8 }}>
              <input id="group-rename" value={name} onChange={(e) => setName(e.target.value)} style={{ flex: 1 }} maxLength={60} />
              <button className="btn" disabled={!name.trim() || name.trim() === title}>
                Renommer
              </button>
            </div>
          </div>
        </form>
      )}
      <div className="lbl hint" style={{ fontWeight: 600 }}>
        Membres · {g.members.length}
      </div>
      <ul className="list member-list" style={{ padding: '6px 0' }} aria-label="Membres">
        {members.map((fp) => (
          <li key={fp} className="check-row">
            <Avatar id={fp === me ? 'me' : fp} name={nameOf(fp)} small online={fp !== me && snap.online.has(snap.contacts.find((c) => c.fingerprint === fp)?.mailbox ?? '')} />
            <span style={{ flex: 1, minWidth: 0 }}>
              {nameOf(fp)}
              {g.admins.includes(fp) && <span className="mono hint"> · admin</span>}
            </span>
            {isAdmin && fp !== me && (
              removing === fp ? (
                <span className="row-btns" style={{ margin: 0 }}>
                  <button className="btn" style={{ height: 34 }} onClick={() => setRemoving(null)}>
                    Garder
                  </button>
                  <button
                    className="btn danger"
                    style={{ height: 34 }}
                    onClick={() => {
                      setRemoving(null)
                      act(relay.groupRemove(gid, fp))
                    }}
                  >
                    Retirer
                  </button>
                </span>
              ) : (
                <button className="btn" style={{ height: 34 }} onClick={() => setRemoving(fp)} aria-label={`Retirer ${nameOf(fp)} du groupe`}>
                  Retirer
                </button>
              )
            )}
          </li>
        ))}
      </ul>
      {isAdmin &&
        (adding ? (
          <div>
            <div className="lbl hint" style={{ fontWeight: 600, marginTop: 8 }}>
              Ajouter
            </div>
            {candidates.length === 0 && <p className="hint">Tous tes contacts sont déjà là.</p>}
            {candidates.map((c) => (
              <div className="check-row" key={c.fingerprint}>
                <Avatar id={c.fingerprint} name={c.name} small />
                <span style={{ flex: 1 }}>{c.name}</span>
                <button className="btn primary" style={{ height: 34 }} onClick={() => act(relay.groupAdd(gid, c.fingerprint))} aria-label={`Ajouter ${c.name} au groupe`}>
                  Ajouter
                </button>
              </div>
            ))}
          </div>
        ) : (
          <button className="btn block" onClick={() => setAdding(true)}>
            Ajouter des membres
          </button>
        ))}
      <ConvOptions convId={convId} />
      <div style={{ marginTop: 12 }}>
        {confirmLeave ? (
          <div className="stack">
            <p className="hint">Les autres verront que tu es parti. La conversation sera effacée de cet appareil.</p>
            <div className="row-btns" style={{ marginTop: 0 }}>
              <button className="btn" onClick={() => setConfirmLeave(false)}>
                Rester
              </button>
              <button
                className="btn danger"
                onClick={() => {
                  onClose()
                  void relay.openConversation(null)
                  act(relay.leaveGroup(gid))
                }}
              >
                Quitter et effacer
              </button>
            </div>
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

const MUTES: { label: string; hours: number | null }[] = [
  { label: 'Non', hours: null },
  { label: '1 heure', hours: 1 },
  { label: '8 heures', hours: 8 },
  { label: '1 semaine', hours: 168 },
  { label: 'Toujours', hours: Infinity },
]

/** Disappearing messages and mute, per conversation. */
function ConvOptions({ convId }: { convId: string }) {
  const snap = useRelay()
  const conv = snap.conversations.find((c) => c.id === convId)
  const muted = conv?.mutedUntil && conv.mutedUntil > Date.now() ? conv.mutedUntil : 0
  const muteLabel = !muted ? 'Non' : muted >= MUTE_ALWAYS ? 'Toujours' : `jusqu’à ${new Date(muted).toLocaleString('fr-FR', { weekday: 'short', hour: '2-digit', minute: '2-digit' })}`
  return (
    <div className="group conv-options" style={{ marginTop: 16 }}>
      <label className="set-row">
        <span className="lbl">
          Messages éphémères
          <small>Effacés chez vous deux après ce délai, compté dès la lecture.</small>
        </span>
        <select
          value={conv?.expireS ?? 0}
          disabled={!conv}
          onChange={(e) => void relay.setExpire(convId, Number(e.target.value))}
          aria-label="Durée des messages éphémères"
        >
          {EXPIRE_CHOICES.map((s) => (
            <option key={s} value={s}>
              {s ? expireLabel(s) : 'Désactivés'}
            </option>
          ))}
        </select>
      </label>
      <label className="set-row">
        <span className="lbl">
          Sourdine
          <small>{muted ? `En sourdine ${muteLabel === 'Toujours' ? 'pour toujours' : muteLabel}. Les mentions passent quand même.` : 'Notifications actives.'}</small>
        </span>
        <select
          value=""
          disabled={!conv}
          onChange={(e) => {
            const m = MUTES[Number(e.target.value)]
            if (m) void relay.setMute(convId, m.hours)
          }}
          aria-label="Mettre en sourdine"
        >
          <option value="" disabled>
            {muted ? (muted >= MUTE_ALWAYS ? 'Toujours' : 'Active') : 'Non'}
          </option>
          {MUTES.map((m, i) => (
            <option key={m.label} value={i}>
              {m.label}
            </option>
          ))}
        </select>
      </label>
    </div>
  )
}
