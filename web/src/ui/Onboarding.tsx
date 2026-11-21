import { useRef, useState } from 'react'
import { relay } from '../state/relay'
import { useRelay } from './common'
import { CipherQR } from './CipherQR'

function Mark() {
  return (
    <svg width="64" height="64" viewBox="0 0 76 76" aria-hidden="true">
      <circle cx="38" cy="38" r="36" fill="none" stroke="var(--radar-line)" />
      <circle cx="38" cy="38" r="22" fill="none" stroke="var(--radar-line)" />
      <circle cx="38" cy="38" r="4" fill="var(--fg)" />
      <circle cx="54" cy="26" r="3.5" fill="var(--radar-dot)" />
      <circle cx="20" cy="50" r="3.5" fill="var(--radar-dot)" />
      <circle cx="64" cy="14" r="5" fill="var(--mesh)" />
      <path d="M38 38L54 26L64 14" stroke="var(--mesh)" strokeWidth="2" fill="none" strokeDasharray="3 3" />
    </svg>
  )
}

export function Onboarding() {
  const snap = useRelay()
  const [name, setName] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const fileRef = useRef<HTMLInputElement>(null)

  const create = async (e: React.FormEvent) => {
    e.preventDefault()
    if (!name.trim()) return
    setBusy(true)
    setError(null)
    try {
      await relay.createIdentity(name)
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Création impossible.')
      setBusy(false)
    }
  }

  const restore = async (file: File | undefined) => {
    if (!file) return
    try {
      await relay.restoreBackup(file)
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Sauvegarde illisible.')
    }
  }

  return (
    <main className="onboard">
      <div className="onboard-card">
        <Mark />
        <h1>Soma Relay</h1>
        <p>
          Des messages chiffrés de bout en bout, post-quantiques, sans numéro ni e-mail. Choisis juste un nom, ta clé
          reste sur cet appareil.
        </p>
        <form onSubmit={create}>
          <div className="field">
            <label htmlFor="ob-name">Ton nom</label>
            <input
              id="ob-name"
              value={name}
              onChange={(e) => setName(e.target.value)}
              placeholder="Inès"
              autoComplete="nickname"
              maxLength={40}
              autoFocus
            />
          </div>
          {error && (
            <p className="error" role="alert">
              {error}
            </p>
          )}
          <button className="btn primary block" disabled={!name.trim() || busy}>
            {busy ? 'Création de ta clé…' : 'Créer mon identité'}
          </button>
        </form>
        <div className="row-btns">
          <button className="btn" onClick={() => fileRef.current?.click()}>
            Restaurer une sauvegarde
          </button>
        </div>
        <input
          ref={fileRef}
          type="file"
          accept="application/json,.json,.relaybackup"
          hidden
          onChange={(e) => void restore(e.target.files?.[0])}
        />
        <p className="engine-note">
          {snap.engineKind === 'mock'
            ? 'MOTEUR DE TEST · CHIFFREMENT SIMULÉ · PROFIL ' + snap.profile.toUpperCase()
            : 'ML-KEM-1024 + X25519 · ML-DSA-87 + ED25519 · PROFIL ' + snap.profile.toUpperCase()}
        </p>
      </div>
    </main>
  )
}

/** Shown once after creation: your code arrives with the cipher reveal. */
export function Welcome({ onDone }: { onDone: () => void }) {
  const snap = useRelay()
  const me = snap.me!
  let link = ''
  try {
    link = relay.myCompactLink()
  } catch {
    link = ''
  }
  return (
    <main className="onboard">
      <div className="onboard-card center">
        <h1>Voilà ton code</h1>
        <p>Montre-le à quelqu’un pour qu’il t’ajoute. Vos quatre mots de sécurité apparaîtront quand vous serez connectés.</p>
        <div className="qr-box">
          <CipherQR stage={{ kind: 'code', text: link || me.fingerprint }} label="Ton code QR" />
        </div>
        <div className="words" aria-label="Tes mots d’empreinte">
          {me.words.map((w) => (
            <span key={w} className="word">
              {w}
            </span>
          ))}
        </div>
        <p className="fp-grid">{me.fingerprint.toUpperCase().match(/.{1,4}/g)?.slice(0, 8).join('·')}</p>
        <div className="row-btns">
          <button className="btn primary" onClick={onDone} data-autofocus>
            C’est parti
          </button>
        </div>
      </div>
    </main>
  )
}
