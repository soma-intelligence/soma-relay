import { useEffect, useState } from 'react'
import { EXPORT_MIN_PASSPHRASE, LOCAL_BUS_AVAILABLE, relay } from '../state/relay'
import { Avatar, downloadBlob, useRelay } from './common'
import { AvatarPicker } from './PhotoEditor'
import { frameE2eeSupported } from '../calls/callManager'
import { PasskeyError } from '../net/passkey'

export function SettingsView({ onMyCode }: { onMyCode: () => void }) {
  const snap = useRelay()
  const me = snap.me!
  const [name, setName] = useState(me.name)
  const [nodeUrl, setNodeUrl] = useState(snap.settings.nodeUrl)
  const [handle, setHandle] = useState(snap.settings.handle)
  const [handleMsg, setHandleMsg] = useState<{ ok: boolean; text: string } | null>(null)
  const [wipeStep, setWipeStep] = useState(0)
  const [exporting, setExporting] = useState(false)
  const notif = typeof Notification !== 'undefined' ? Notification.permission : 'denied'
  const [, bump] = useState(0)
  const notifOn = snap.settings.notifications && notif === 'granted'
  const [passkeyOk, setPasskeyOk] = useState(false)
  const [passkeyErr, setPasskeyErr] = useState<string | null>(null)
  useEffect(() => {
    let live = true
    void relay.passkeyAvailable().then((ok) => live && setPasskeyOk(ok))
    return () => {
      live = false
    }
  }, [])
  const vault = snap.vault
  const vaultText =
    vault.state === 'lockOnly'
      ? 'Ton gestionnaire ne prend pas en charge la sauvegarde'
      : vault.state === 'saved' && vault.at
        ? 'Sauvegardé à ' + new Date(vault.at).toLocaleTimeString('fr-FR', { hour: '2-digit', minute: '2-digit' })
        : vault.state === 'pending'
          ? 'En attente du réseau'
          : vault.state === 'failed'
            ? (vault.message ?? 'Sauvegarde impossible.')
            : ''
  const setUpPasskey = async () => {
    setPasskeyErr(null)
    try {
      await relay.setUpPasskey()
    } catch (err) {
      setPasskeyErr(
        err instanceof PasskeyError && err.code === 'cancelled'
          ? 'Création du passkey annulée.'
          : err instanceof PasskeyError
            ? 'Les passkeys ne sont pas disponibles sur ce navigateur.'
            : 'Passkey impossible à créer pour le moment.',
      )
    }
  }

  return (
    <div className="scroll">
      <div className="settings">
        <div className="group-title">Identité</div>
        <div className="group">
          <div className="set-row profile-row">
            <button className="mycard-face" onClick={onMyCode} aria-label="Ouvrir ma carte">
              <Avatar id="me" name={me.name} size={64} />
            </button>
            <div className="profile-side">
              <span className="lbl">
                Photo de profil
                <small>Envoyée chiffrée à tes contacts et à tes groupes, jamais en clair au nœud.</small>
              </span>
            </div>
            <AvatarPicker has={!!snap.profiles.me?.avatar} onPick={(jpeg) => relay.setMyAvatar(jpeg)} compact />
          </div>
          <form
            className="set-row"
            onSubmit={(e) => {
              e.preventDefault()
              if (name.trim()) relay.setDisplayName(name)
            }}
          >
            <label htmlFor="set-name" className="lbl">
              Nom
            </label>
            <input id="set-name" type="text" value={name} onChange={(e) => setName(e.target.value)} maxLength={40} />
            <button className="btn" disabled={!name.trim() || name.trim() === me.name}>
              OK
            </button>
          </form>
          <div className="set-row">
            <span className="lbl">
              Empreinte
              <small className="mono" data-testid="my-fingerprint">{/* A break may only follow a dot, so no line starts with one. */}
                {me.fingerprint.toUpperCase().match(/.{1,4}/g)?.slice(0, 8).join('·\u200b')}</small>
            </span>
            <button className="btn" onClick={onMyCode}>
              Mon code
            </button>
          </div>
          <div className="set-row">
            <span className="lbl">
              Mots d’empreinte
              <small>{me.words.join(' · ')}</small>
            </span>
          </div>
        </div>

        <div className="group-title">Nœud</div>
        <div className="group">
          <form
            className="set-row"
            onSubmit={(e) => {
              e.preventDefault()
              void relay.updateSettings({ nodeUrl: nodeUrl.trim() })
            }}
          >
            <label htmlFor="set-node" className="lbl" style={{ flex: 'none' }}>
              Adresse
            </label>
            <input
              id="set-node"
              type="url"
              value={nodeUrl}
              placeholder={location.origin}
              onChange={(e) => setNodeUrl(e.target.value)}
              autoCapitalize="off"
              spellCheck={false}
            />
            <button className="btn" disabled={nodeUrl.trim() === snap.settings.nodeUrl}>
              OK
            </button>
          </form>
          <div className="set-row">
            <span className="lbl">
              État
              <small className="mono">
                <span className={`status-dot ${snap.node}`} />
                {snap.node === 'online' ? 'en ligne' : snap.node === 'connecting' ? 'connexion…' : 'hors ligne'} ·{' '}
                {new URL(snap.nodeBase || location.origin).host}
                {snap.outboxCount ? ` · ${snap.outboxCount} en route` : ''}
              </small>
            </span>
          </div>
          <form
            className="set-row"
            onSubmit={async (e) => {
              e.preventDefault()
              setHandleMsg(null)
              const err = await relay.registerHandle(handle)
              setHandleMsg(err ? { ok: false, text: err } : { ok: true, text: 'Identifiant publié dans l’annuaire.' })
            }}
          >
            <label htmlFor="set-handle" className="lbl" style={{ flex: 'none' }}>
              Identifiant
            </label>
            <input
              id="set-handle"
              type="text"
              value={handle}
              placeholder="ines"
              onChange={(e) => setHandle(e.target.value.toLowerCase())}
              autoCapitalize="off"
              spellCheck={false}
            />
            <button className="btn" disabled={!handle.trim() || snap.node !== 'online'}>
              Publier
            </button>
          </form>
          {handleMsg && (
            <p className={handleMsg.ok ? 'hint' : 'error'} role="status" style={{ padding: '0 0 10px' }}>
              {handleMsg.text}
            </p>
          )}
        </div>

        <div className="group-title">Transports</div>
        <div className="group">
          <label className="set-row">
            <span className="lbl">
              Pair à pair (WebRTC)
              <small>Lien direct avec un contact en ligne, plus rapide. Révèle ton adresse IP à ce contact.</small>
            </span>
            <input
              type="checkbox"
              className="switch"
              checked={snap.settings.p2p}
              onChange={(e) => void relay.updateSettings({ p2p: e.target.checked })}
            />
          </label>
          {LOCAL_BUS_AVAILABLE && (
          <label className="set-row">
            <span className="lbl">
              Bus local de test
              <small>Relie les onglets de ce navigateur sans nœud. Pour tester à deux profils (?profile=).</small>
            </span>
            <input
              type="checkbox"
              className="switch"
              checked={snap.settings.localBus}
              onChange={(e) => void relay.updateSettings({ localBus: e.target.checked })}
            />
          </label>
          )}
          <div className="set-row">
            <span className="lbl">
              Mesh Bluetooth et Wi-Fi
              <small>Indisponible dans le navigateur. Les canaux locaux et le mesh sont dans l’app iPhone.</small>
            </span>
          </div>
        </div>

        <div className="group-title">Appels et notifications</div>
        <div className="group">
          <div className="set-row">
            <span className="lbl">
              Chiffrement des appels
              <small>
                {frameE2eeSupported()
                  ? 'Images et son chiffrés de bout en bout avec la clé post-quantique de votre session, en plus de DTLS-SRTP.'
                  : 'Ce navigateur ne permet que DTLS-SRTP (chiffré, mais clés classiques).'}
              </small>
            </span>
          </div>
          <label className="set-row">
            <span className="lbl">
              Notifications
              <small>
                {notif === 'denied'
                  ? 'Bloquées par le navigateur : autorise-les dans les réglages du site.'
                  : notifOn
                    ? 'Prévenu même onglet fermé quand ton nœud le permet.'
                    : 'Pour être prévenu quand l’onglet est en arrière-plan ou fermé.'}
              </small>
            </span>
            <input
              type="checkbox"
              className="switch"
              checked={notifOn}
              disabled={notif === 'denied' || typeof Notification === 'undefined'}
              onChange={(e) => void (e.target.checked ? relay.enableNotifications() : relay.disableNotifications()).then(() => bump((x) => x + 1))}
            />
          </label>
          <label className="set-row">
            <span className="lbl">
              Aperçu dans les notifications
              <small>Nom et texte du message. Sinon « Nouveau message ».</small>
            </span>
            <input
              type="checkbox"
              className="switch"
              checked={snap.settings.notifPreviews}
              onChange={(e) => void relay.updateSettings({ notifPreviews: e.target.checked })}
            />
          </label>
        </div>

        <div className="group-title">Messages</div>
        <div className="group">
          <label className="set-row">
            <span className="lbl">
              Aperçus des liens
              <small>Ton nœud lit la page pour toi et l’aperçu part avec le message. Le destinataire ne charge rien.</small>
            </span>
            <input
              type="checkbox"
              className="switch"
              checked={snap.settings.linkPreviews}
              onChange={(e) => void relay.updateSettings({ linkPreviews: e.target.checked })}
            />
          </label>
        </div>

        {passkeyOk && (
          <>
            <div className="group-title">Sécurité</div>
            <div className="group">
              <div className="set-row">
                <span className="lbl">
                  Sauvegarde par passkey
                  <small>
                    Ton identité, tes contacts et tes groupes, chiffrés par ton passkey. Pour la retrouver dans un
                    nouveau navigateur ou sur un nouveau téléphone.
                  </small>
                </span>
                <button className="btn" onClick={() => void setUpPasskey()} disabled={vault.busy}>
                  {vault.busy ? 'Création…' : vault.state === 'off' ? 'Créer un passkey' : 'Changer de passkey'}
                </button>
              </div>
              {(vaultText || passkeyErr) && (
                <p className={passkeyErr || vault.state === 'failed' ? 'error' : 'hint'} role="status" style={{ padding: '0 0 10px' }}>
                  {passkeyErr ?? vaultText}
                </p>
              )}
            </div>
          </>
        )}

        <div className="group-title">Données</div>
        <div className="group">
          {relay.canSealExport ? (
            <>
              <div className="set-row">
                <span className="lbl">
                  Exporter ma clé
                  <small>Un fichier .relaykey de ton identité et de tes sessions, chiffré par une phrase de passe.</small>
                </span>
                {!exporting && (
                  <button className="btn" onClick={() => setExporting(true)}>
                    Exporter
                  </button>
                )}
              </div>
              {exporting && <ExportForm profile={snap.profile} onDone={() => setExporting(false)} />}
            </>
          ) : (
            <div className="set-row">
              <span className="lbl">
                Exporter ma clé
                <small>Moteur de test : une sauvegarde non chiffrée de ton identité. Garde-la en lieu sûr.</small>
              </span>
              <button className="btn" onClick={() => downloadBlob(relay.backupFile(), `soma-relay-${snap.profile}.json`)}>
                Exporter
              </button>
            </div>
          )}
          <div className="set-row">
            <span className="lbl">
              Tout effacer
              <small>Identité, contacts, messages et pièces jointes de ce profil.</small>
            </span>
            {wipeStep === 0 ? (
              <button className="btn" style={{ color: 'var(--danger)' }} onClick={() => setWipeStep(1)}>
                Effacer
              </button>
            ) : (
              <button className="btn danger" onClick={() => void relay.wipe()}>
                Oui, tout effacer
              </button>
            )}
          </div>
        </div>
        <p className="engine-note">
          SOMA RELAY WEB · PROFIL {snap.profile.toUpperCase()} · MOTEUR {snap.engineKind === 'wasm' ? 'RELAY-CORE WASM' : 'DE TEST (SIMULÉ)'} · AGPL-3.0
        </p>
      </div>
    </div>
  )
}

/** Passphrase typed twice, then the sealed .relaykey download. */
function ExportForm({ profile, onDone }: { profile: string; onDone: () => void }) {
  const [pass, setPass] = useState('')
  const [confirm, setConfirm] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const tooShort = pass.length < EXPORT_MIN_PASSPHRASE
  const mismatch = confirm.length > 0 && confirm !== pass
  const ok = !tooShort && confirm === pass && !busy

  return (
    <form
      className="set-row export-form"
      onSubmit={async (e) => {
        e.preventDefault()
        if (!ok) return
        setBusy(true)
        setError(null)
        try {
          downloadBlob(await relay.exportFile(pass), `soma-relay-${profile}.relaykey`)
          onDone()
        } catch (err) {
          setError(err instanceof Error ? err.message : 'Export impossible.')
          setBusy(false)
        }
      }}
    >
      <div className="field">
        <label htmlFor="export-pass">Phrase de passe</label>
        <input
          id="export-pass"
          type="password"
          value={pass}
          onChange={(e) => setPass(e.target.value)}
          autoComplete="new-password"
          autoFocus
        />
      </div>
      <div className="field">
        <label htmlFor="export-pass2">Confirmation</label>
        <input
          id="export-pass2"
          type="password"
          value={confirm}
          onChange={(e) => setConfirm(e.target.value)}
          autoComplete="new-password"
        />
      </div>
      <small className={mismatch || error ? 'error' : undefined} role={mismatch || error ? 'alert' : undefined}>
        {error ??
          (mismatch
            ? 'Les deux phrases ne correspondent pas.'
            : `Au moins ${EXPORT_MIN_PASSPHRASE} caractères. Elle te sera demandée pour restaurer ce fichier.`)}
      </small>
      <div className="row-btns">
        <button type="button" className="btn" onClick={onDone} disabled={busy}>
          Annuler
        </button>
        <button className="btn primary" disabled={!ok}>
          {busy ? 'Chiffrement…' : 'Chiffrer et exporter'}
        </button>
      </div>
    </form>
  )
}
