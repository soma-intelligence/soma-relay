import { useState } from 'react'
import { LOCAL_BUS_AVAILABLE, relay } from '../state/relay'
import { downloadBlob, useRelay } from './common'
import { frameE2eeSupported } from '../calls/callManager'

export function SettingsView({ onMyCode }: { onMyCode: () => void }) {
  const snap = useRelay()
  const me = snap.me!
  const [name, setName] = useState(me.name)
  const [nodeUrl, setNodeUrl] = useState(snap.settings.nodeUrl)
  const [handle, setHandle] = useState(snap.settings.handle)
  const [handleMsg, setHandleMsg] = useState<{ ok: boolean; text: string } | null>(null)
  const [wipeStep, setWipeStep] = useState(0)
  const notif = typeof Notification !== 'undefined' ? Notification.permission : 'denied'
  const [, bump] = useState(0)
  const notifOn = snap.settings.notifications && notif === 'granted'

  return (
    <div className="scroll">
      <div className="settings">
        <div className="group-title">Identité</div>
        <div className="group">
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
              <small className="mono">{me.fingerprint.toUpperCase().match(/.{1,4}/g)?.slice(0, 8).join('·')}</small>
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

        <div className="group-title">Données</div>
        <div className="group">
          <div className="set-row">
            <span className="lbl">
              Exporter ma clé
              <small>Une sauvegarde non chiffrée de ton identité et de tes sessions. Garde-la en lieu sûr.</small>
            </span>
            <button className="btn" onClick={() => downloadBlob(relay.backupFile(), `soma-relay-${snap.profile}.json`)}>
              Exporter
            </button>
          </div>
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
