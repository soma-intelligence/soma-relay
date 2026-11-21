import { useEffect, useRef, useState } from 'react'
import { relay } from '../state/relay'
import { formatDuration } from '../media/media'
import { initials, useCall, useRelay } from './common'
import { CameraOff, Chat, Hang, Lock, Mic, MicOff, Phone, Speaker, Video } from './Icons'

/** The call screen (FusionAppel) and the incoming call sheet. */
export function CallLayer({ onOpenChat }: { onOpenChat: (fp: string) => void }) {
  const call = useCall()
  const snap = useRelay()
  if (call.phase === 'idle' || !call.peer) return null
  const name = snap.contacts.find((c) => c.fingerprint === call.peer)?.name ?? 'Inconnu'
  if (call.phase === 'incoming') return <Incoming name={name} video={call.video} />
  return <CallScreen name={name} onOpenChat={() => onOpenChat(call.peer!)} />
}

function Incoming({ name, video }: { name: string; video: boolean }) {
  const ref = useRef<HTMLButtonElement>(null)
  useEffect(() => ref.current?.focus(), [])
  return (
    <div className="incoming glass" role="alertdialog" aria-label={`Appel ${video ? 'vidéo' : 'audio'} de ${name}`}>
      <span className="avatar">{initials(name)}</span>
      <span className="who">
        <b>{name}</b>
        <span>{video ? 'APPEL VIDÉO CHIFFRÉ' : 'APPEL CHIFFRÉ'}</span>
      </span>
      <button className="icon-btn danger" onClick={() => relay.calls.decline()} aria-label="Refuser">
        <Hang size={20} />
      </button>
      <button ref={ref} className="icon-btn strong" onClick={() => void relay.calls.accept()} aria-label="Répondre">
        {video ? <Video /> : <Phone />}
      </button>
    </div>
  )
}

function Ring({ label }: { label: string }) {
  const arc = useRef<SVGCircleElement>(null)
  useEffect(() => {
    let raf = 0
    let smooth = 0
    const loop = () => {
      smooth = smooth * 0.8 + relay.calls.level() * 0.2
      const len = 60 + smooth * 450
      arc.current?.setAttribute('stroke-dasharray', `${len.toFixed(0)} 600`)
      raf = requestAnimationFrame(loop)
    }
    if (!matchMedia('(prefers-reduced-motion: reduce)').matches) loop()
    return () => cancelAnimationFrame(raf)
  }, [])
  return (
    <svg style={{ marginTop: 44, zIndex: 1 }} width="200" height="200" viewBox="0 0 220 220" role="img" aria-label={label}>
      <circle cx="110" cy="110" r="104" fill="none" stroke="#1f241f" />
      <circle cx="110" cy="110" r="82" fill="none" stroke="#2a2f2a" />
      <circle
        ref={arc}
        cx="110"
        cy="110"
        r="82"
        fill="none"
        stroke="#c6f24e"
        strokeWidth="3"
        strokeDasharray="190 400"
        strokeLinecap="round"
        transform="rotate(-90 110 110)"
      />
      <circle cx="110" cy="110" r="60" fill="#1a1e1b" />
      <text x="110" y="122" textAnchor="middle" fontFamily="-apple-system, system-ui, sans-serif" fontSize="34" fontWeight="600" fill="#e9ece6">
        {label.slice(0, 2).toUpperCase()}
      </text>
    </svg>
  )
}

function CallScreen({ name, onOpenChat }: { name: string; onOpenChat: () => void }) {
  const call = useCall()
  const [now, setNow] = useState(Date.now())
  const remoteV = useRef<HTMLVideoElement>(null)
  const remoteA = useRef<HTMLAudioElement>(null)
  const localV = useRef<HTMLVideoElement>(null)
  useEffect(() => {
    const t = setInterval(() => setNow(Date.now()), 500)
    return () => clearInterval(t)
  }, [])
  useEffect(() => {
    if (remoteV.current && remoteV.current.srcObject !== call.remoteStream) remoteV.current.srcObject = call.remoteStream
    if (remoteA.current && remoteA.current.srcObject !== call.remoteStream) {
      remoteA.current.srcObject = call.remoteStream
      void remoteA.current.play().catch(() => {})
    }
    if (localV.current && localV.current.srcObject !== call.localStream) localV.current.srcObject = call.localStream
  })
  useEffect(() => {
    if (remoteA.current) remoteA.current.volume = call.speaker ? 1 : 0.35
  }, [call.speaker])

  const words = call.peer ? relay.safetyWords(call.peer) : []
  const hasRemoteVideo = call.video && !!call.remoteStream?.getVideoTracks().length
  const status =
    call.phase === 'outgoing'
      ? 'Ça sonne…'
      : call.phase === 'connecting'
        ? 'Connexion…'
        : call.phase === 'ended'
          ? (call.endReason ?? 'Appel terminé.')
          : formatDuration(call.startedAt ? now - call.startedAt : 0)
  const pill =
    call.phase === 'active'
      ? `${call.security === 'frame' ? 'P2P · E2EE TRAME · CLÉS PQ' : 'P2P · DTLS-SRTP'}${call.rttMs !== null ? ` · ${call.rttMs} ms` : ''}`
      : 'SIGNAL CHIFFRÉ · CLÉS PQ'

  return (
    <div className={`call${hasRemoteVideo ? ' has-video' : ''}`} role="dialog" aria-modal="true" aria-label={`Appel avec ${name}`}>
      {call.video && <video ref={remoteV} className="remote-video" autoPlay playsInline muted />}
      {hasRemoteVideo && <div className="shade" />}
      <audio ref={remoteA} autoPlay />
      {call.video && call.localStream && !call.cameraOff && (
        <video ref={localV} className="local-video" autoPlay playsInline muted aria-label="Ta caméra" />
      )}
      <div className="pill">
        <Lock />
        {pill}
      </div>
      {!hasRemoteVideo && <Ring label={name} />}
      <h1 style={hasRemoteVideo ? { marginTop: 'auto' } : undefined}>{name}</h1>
      <div className="timer" aria-live="polite">
        {status}
      </div>
      {!hasRemoteVideo && (
        <>
          <div className="cwords" aria-label="Mots de sécurité de l’appel">
            {words.map((w) => (
              <span key={w}>{w}</span>
            ))}
          </div>
          <div className="cnote">
            Mêmes mots des deux côtés = appel sûr.
            <br />
            {call.videoPaused ? 'Réseau faible : vidéo en pause, le son continue.' : 'Coupure réseau : les messages repassent par le nœud.'}
          </div>
        </>
      )}
      {hasRemoteVideo && call.videoPaused && <div className="cnote">Réseau faible : vidéo en pause, le son continue.</div>}
      <div style={{ flexGrow: 1 }} />
      <div className="controls" role="toolbar" aria-label="Contrôles de l’appel">
        <button className="cbtn" aria-label={call.muted ? 'Réactiver le micro' : 'Couper le micro'} aria-pressed={call.muted} onClick={() => relay.calls.toggleMute()}>
          {call.muted ? <MicOff /> : <Mic size={22} />}
        </button>
        {call.video ? (
          <button className="cbtn" aria-label={call.cameraOff ? 'Rallumer la caméra' : 'Couper la caméra'} aria-pressed={call.cameraOff} onClick={() => relay.calls.toggleCamera()}>
            {call.cameraOff ? <CameraOff /> : <Video size={22} />}
          </button>
        ) : (
          <button className="cbtn" aria-label="Haut-parleur" aria-pressed={call.speaker} onClick={() => relay.calls.toggleSpeaker()}>
            <Speaker />
          </button>
        )}
        <button className="cbtn" aria-label="Ouvrir la conversation" onClick={onOpenChat}>
          <Chat />
        </button>
        <button className="cbtn hang" aria-label="Raccrocher" onClick={() => relay.calls.hangup()} disabled={call.phase === 'ended'}>
          <Hang />
        </button>
      </div>
    </div>
  )
}
