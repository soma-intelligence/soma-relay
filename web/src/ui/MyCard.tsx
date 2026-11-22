// My card, full screen (spec v1.2 section 6): large QR of my relay1c: link, photo and name,
// Share and Scanner. Scanning (or pasting) a card adds the contact and opens the chat. When
// someone adds me while the card is open, the QR settles into our safety words.

import { useCallback, useEffect, useRef, useState } from 'react'
import { createPortal } from 'react-dom'
import { relay } from '../state/relay'
import { Avatar, copyText, useRelay } from './common'
import { CipherQR, type CipherStage } from './CipherQR'
import { QrScanner } from './QrScanner'
import { AvatarPicker } from './PhotoEditor'
import { Back, Check, Close, Copy, Pencil, Qr } from './Icons'

function wordLines(words: string[]): string[] {
  return [words.slice(0, 2).join(' '), words.slice(2).join(' ')]
}

const ShareIcon = () => (
  <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.9" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
    <path d="M12 15V3M7.5 7.5 12 3l4.5 4.5" />
    <path d="M8 11H6a2 2 0 0 0-2 2v6a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-6a2 2 0 0 0-2-2h-2" />
  </svg>
)

export function MyCard({ onClose, onAdded, startScan }: { onClose: () => void; onAdded: (fp: string) => void; startScan?: boolean }) {
  const snap = useRelay()
  const me = snap.me!
  const [mode, setMode] = useState<'card' | 'scan'>(startScan ? 'scan' : 'card')
  const [stage, setStage] = useState<CipherStage>(() => ({ kind: 'code', text: relay.myCompactLink() }))
  const [peer, setPeer] = useState<string | null>(null)
  const known = useRef(new Set(snap.contacts.map((c) => c.fingerprint)))
  const [copied, setCopied] = useState<'link' | 'card' | 'share' | null>(null)
  const [editPhoto, setEditPhoto] = useState(false)
  const [paste, setPaste] = useState('')
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const [closing, setClosing] = useState(false)
  const root = useRef<HTMLDivElement>(null)

  const close = useCallback(() => {
    if (matchMedia('(prefers-reduced-motion: reduce)').matches) return onClose()
    setClosing(true)
    setTimeout(onClose, 200)
  }, [onClose])

  useEffect(() => {
    const prev = document.activeElement as HTMLElement | null
    root.current?.querySelector<HTMLElement>('[data-autofocus]')?.focus()
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') close()
    }
    document.addEventListener('keydown', onKey)
    return () => {
      document.removeEventListener('keydown', onKey)
      prev?.focus?.()
    }
  }, [close])

  // Someone added me while the card shows: dissolve into our safety words.
  useEffect(() => {
    const fresh = snap.contacts.find((c) => !known.current.has(c.fingerprint))
    if (!fresh || peer || mode !== 'card') return
    setPeer(fresh.fingerprint)
    setStage({ kind: 'connecting' })
    const t = setTimeout(() => setStage({ kind: 'verify', lines: wordLines(relay.safetyWords(fresh.fingerprint)) }), 900)
    return () => clearTimeout(t)
  }, [snap.contacts, peer, mode])

  const flashCopied = (what: 'link' | 'card' | 'share') => {
    setCopied(what)
    setTimeout(() => setCopied((c) => (c === what ? null : c)), 1600)
  }
  const copy = async (what: 'link' | 'card') => {
    if (await copyText(what === 'link' ? relay.myCompactLink() : relay.myCard())) flashCopied(what)
  }
  const share = async () => {
    const link = relay.myCompactLink()
    if (typeof navigator.share === 'function') {
      try {
        await navigator.share({ title: `${me.name} sur Soma Relay`, text: link })
        return
      } catch (e) {
        if (e instanceof DOMException && e.name === 'AbortError') return
      }
    }
    if (await copyText(link)) flashCopied('share')
  }

  const add = useCallback(
    async (input: string) => {
      setBusy(true)
      setError(null)
      try {
        const c = await relay.addFromText(input)
        known.current.add(c.fingerprint)
        relay.toast(`${c.name} ajouté. Vérifiez vos mots de sécurité.`)
        onAdded(c.fingerprint)
      } catch (e) {
        setError(e instanceof Error ? e.message : 'Ajout impossible.')
        setBusy(false)
      }
    },
    [onAdded],
  )

  const peerContact = peer ? snap.contacts.find((c) => c.fingerprint === peer) : null
  const host = (() => {
    try {
      return new URL(snap.nodeBase).host
    } catch {
      return ''
    }
  })()

  return createPortal(
    <div className={`mycard${closing ? ' closing' : ''}`} role="dialog" aria-modal="true" aria-label={mode === 'scan' ? 'Scanner une carte' : 'Ma carte'} ref={root}>
      <div className="mycard-inner">
        <div className="mycard-top">
          {mode === 'scan' ? (
            <button className="icon-btn" onClick={() => setMode('card')} aria-label="Revenir à ma carte">
              <Back />
            </button>
          ) : (
            <span style={{ width: 44 }} />
          )}
          <h2>{mode === 'scan' ? 'Scanner une carte' : peerContact ? `Connecté à ${peerContact.name}` : 'Ma carte'}</h2>
          <button className="icon-btn" onClick={close} aria-label="Fermer" data-autofocus>
            <Close />
          </button>
        </div>

        {mode === 'card' ? (
          <div className="mycard-body" key="card">
            <div className="mycard-id">
              <button className="mycard-face" onClick={() => setEditPhoto((v) => !v)} aria-label="Modifier ma photo" aria-expanded={editPhoto}>
                <Avatar id="me" name={me.name} size={88} />
                <span className="mycard-edit" aria-hidden="true">
                  <Pencil size={14} />
                </span>
              </button>
              <div className="mycard-name">{me.name}</div>
              {snap.settings.handle && host && (
                <div className="mono hint">
                  {snap.settings.handle}@{host}
                </div>
              )}
            </div>
            {editPhoto && (
              <div className="mycard-photo">
                <AvatarPicker
                  has={!!snap.profiles.me?.avatar}
                  onPick={async (jpeg) => {
                    await relay.setMyAvatar(jpeg)
                    setEditPhoto(false)
                  }}
                />
              </div>
            )}
            <div className="mycard-qr">
              <CipherQR stage={stage} label={stage.kind === 'verify' ? `Mots de sécurité : ${stage.lines.join(' ')}` : 'Ton code QR Soma Relay'} />
            </div>
            {peerContact ? (
              <>
                <p className="hint center">Mêmes mots sur son écran ? Alors personne ne s’est glissé entre vous.</p>
                <div className="row-btns">
                  <button
                    className="btn primary"
                    onClick={() => {
                      relay.setVerified(peerContact.fingerprint, true)
                      onAdded(peerContact.fingerprint)
                    }}
                  >
                    <Check /> Les mots sont identiques
                  </button>
                </div>
              </>
            ) : (
              <>
                <p className="hint center mycard-hint">Fais scanner ce code pour qu’on t’ajoute. Mots d’empreinte : {me.words.join(' · ')}</p>
                <div className="mycard-main-btns">
                  <button className="btn primary" onClick={() => void share()}>
                    <ShareIcon /> {copied === 'share' ? 'Lien copié' : 'Partager'}
                  </button>
                  <button className="btn" onClick={() => setMode('scan')}>
                    <Qr size={18} /> Scanner
                  </button>
                </div>
                <div className="mycard-sub-btns">
                  <button className="btn subtle" onClick={() => void copy('link')}>
                    <Copy size={16} /> {copied === 'link' ? 'Copié' : 'Lien court'}
                  </button>
                  <button className="btn subtle" onClick={() => void copy('card')}>
                    <Copy size={16} /> {copied === 'card' ? 'Copié' : 'Carte complète'}
                  </button>
                </div>
              </>
            )}
          </div>
        ) : (
          <div className="mycard-body" key="scan">
            <QrScanner onResult={(t) => void add(t)} />
            <form
              className="mycard-paste"
              onSubmit={(e) => {
                e.preventDefault()
                void add(paste)
              }}
            >
              <label htmlFor="card-paste" className="hint">
                Pas de caméra ? Colle son lien
              </label>
              <div style={{ display: 'flex', gap: 8 }}>
                <input
                  id="card-paste"
                  value={paste}
                  onChange={(e) => setPaste(e.target.value)}
                  placeholder="relay1c:… ou relay1:…"
                  autoCapitalize="off"
                  autoCorrect="off"
                  spellCheck={false}
                />
                <button className="btn primary" disabled={!paste.trim() || busy}>
                  {busy ? '…' : 'Ajouter'}
                </button>
              </div>
            </form>
            {error && (
              <p className="error" role="alert">
                {error}
              </p>
            )}
          </div>
        )}
      </div>
    </div>,
    document.body,
  )
}
