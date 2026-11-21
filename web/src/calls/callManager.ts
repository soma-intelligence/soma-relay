// 1:1 audio and video calls over WebRTC (spec section 9, docs/research/calls.md).
//
// Signalling: encrypted AppMessage kind "call" through whatever transport is up.
// Media: DTLS-SRTP always; frame E2EE on top (LiveKit-compatible layout, key from
// engine.callKey) when both ends advertise it with `a=x-soma-e2ee:lk1` in their SDP.
// Settings applied from the research guide: Opus fmtp (FEC, DTX, 32 kbps max, ptime 20),
// codec order, L1T3, maintain-framerate, jitterBufferTarget 40/80 ms, the getUserMedia
// constraints, a 2.5 Mbps cap and an audio-only fallback when the estimate stays under
// 150 kbps for 4 s (video retried every 10 s).

import type { CallSignal } from '../core/engine'
import { uuidv7 } from '../lib/bytes'
import { Ringer } from './ringtone'

export type CallPhase = 'idle' | 'outgoing' | 'incoming' | 'connecting' | 'active' | 'ended'

export interface CallSnapshot {
  phase: CallPhase
  callId: string | null
  peer: string | null
  video: boolean
  startedAt: number | null
  muted: boolean
  cameraOff: boolean
  speaker: boolean
  /** 'frame' = frame E2EE with the PQ call key, 'srtp' = DTLS-SRTP only. */
  security: 'frame' | 'srtp' | null
  rttMs: number | null
  videoPaused: boolean
  endReason: string | null
  localStream: MediaStream | null
  remoteStream: MediaStream | null
}

export interface CallEndInfo {
  peer: string
  callId: string
  video: boolean
  outgoing: boolean
  outcome: 'missed' | 'ended' | 'declined' | 'busy'
  durationMs?: number
}

const E2EE_LINE = 'a=x-soma-e2ee:lk1'

type TransformCtor = new (worker: Worker, options?: unknown) => unknown
const ScriptTransform = (globalThis as { RTCRtpScriptTransform?: TransformCtor }).RTCRtpScriptTransform
const hasEncodedStreams =
  typeof RTCRtpSender !== 'undefined' && 'createEncodedStreams' in RTCRtpSender.prototype

export const frameE2eeSupported = (): boolean => !!ScriptTransform || hasEncodedStreams

const AUDIO_CONSTRAINTS: MediaTrackConstraints = {
  echoCancellation: true,
  noiseSuppression: true,
  autoGainControl: true,
  channelCount: 1,
  sampleRate: 48000,
}
const VIDEO_CONSTRAINTS: MediaTrackConstraints = {
  width: { ideal: 1280 },
  height: { ideal: 720 },
  frameRate: { ideal: 30, max: 30 },
  facingMode: 'user',
}

/** Opus fmtp from the guide, applied to both the local and the transmitted SDP. */
export function mungeOpus(sdp: string): string {
  const m = sdp.match(/a=rtpmap:(\d+) opus\/48000\/2/i)
  if (!m) return sdp
  const pt = m[1]
  const fmtp = `a=fmtp:${pt} minptime=10;maxptime=40;useinbandfec=1;usedtx=1;stereo=0;sprop-stereo=0;maxaveragebitrate=32000;maxplaybackrate=48000;cbr=0`
  const re = new RegExp(`a=fmtp:${pt} [^\\r\\n]*`)
  let out = re.test(sdp) ? sdp.replace(re, fmtp) : sdp.replace(m[0], `${m[0]}\r\n${fmtp}`)
  // a=ptime:20 in the audio section, once.
  out = out.replace(/(m=audio[^]*?)(?=\r\nm=|$)/, (sec) =>
    /a=ptime:/.test(sec) ? sec : sec.replace(/\r\n$/, '') + '\r\na=ptime:20\r\n',
  )
  return out
}

function orderVideoCodecs(e2ee: boolean): RTCRtpCodec[] | null {
  const caps = RTCRtpReceiver.getCapabilities?.('video')
  if (!caps) return null
  // Frame E2EE keeps codec headers clear only for VP8 and H.264 (LiveKit layout).
  const order = e2ee
    ? ['video/VP8', 'video/H264']
    : ['video/AV1', 'video/VP9', 'video/H264', 'video/VP8']
  const rank = (c: RTCRtpCodec) => {
    const i = order.findIndex((m) => m.toLowerCase() === c.mimeType.toLowerCase())
    return i < 0 ? 100 : i
  }
  const media = caps.codecs.filter((c) => !/rtx|red|ulpfec|flexfec/i.test(c.mimeType))
  const rest = caps.codecs.filter((c) => /rtx|red|ulpfec|flexfec/i.test(c.mimeType))
  const sorted = media.filter((c) => !e2ee || rank(c) < 100).sort((a, b) => rank(a) - rank(b))
  return [...sorted, ...rest]
}

export class CallManager {
  private listeners = new Set<() => void>()
  private snap: CallSnapshot = CallManager.idle()
  private pc: RTCPeerConnection | null = null
  private worker: Worker | null = null
  private pendingIce: RTCIceCandidateInit[] = []
  private pendingOffer: string | null = null
  private ringer = new Ringer()
  private timeout: ReturnType<typeof setTimeout> | null = null
  private statsTimer: ReturnType<typeof setInterval> | null = null
  private lowSince = 0
  private pausedVideoTrack: MediaStreamTrack | null = null
  private retryAt = 0
  private outgoing = false
  private remoteE2ee = false
  private audioCtx: AudioContext | null = null
  private analyser: AnalyserNode | null = null

  constructor(
    private signal: (fp: string, s: CallSignal) => void,
    private callKey: (fp: string, callId: string) => Uint8Array,
    private iceServers: () => Promise<RTCIceServer[]>,
    private onEnded: (info: CallEndInfo) => void,
  ) {}

  static idle(): CallSnapshot {
    return {
      phase: 'idle',
      callId: null,
      peer: null,
      video: false,
      startedAt: null,
      muted: false,
      cameraOff: false,
      speaker: true,
      security: null,
      rttMs: null,
      videoPaused: false,
      endReason: null,
      localStream: null,
      remoteStream: null,
    }
  }

  subscribe = (fn: () => void) => {
    this.listeners.add(fn)
    return () => this.listeners.delete(fn)
  }
  getSnapshot = () => this.snap
  private set(patch: Partial<CallSnapshot>) {
    this.snap = { ...this.snap, ...patch }
    this.listeners.forEach((l) => l())
  }

  get busy(): boolean {
    return this.snap.phase !== 'idle' && this.snap.phase !== 'ended'
  }

  /** Voice level of the peer, 0..1, for the ring. */
  level(): number {
    if (!this.analyser) return 0
    const d = new Uint8Array(this.analyser.fftSize)
    this.analyser.getByteTimeDomainData(d)
    let sum = 0
    for (const v of d) sum += ((v - 128) / 128) ** 2
    return Math.min(1, Math.sqrt(sum / d.length) * 4)
  }

  async start(peer: string, video: boolean) {
    if (this.busy) return
    const callId = uuidv7()
    this.outgoing = true
    this.set({ ...CallManager.idle(), phase: 'outgoing', callId, peer, video })
    try {
      const local = await this.media(video)
      const pc = await this.createPc(peer, callId)
      this.addLocal(pc, local, video, frameE2eeSupported())
      const offer = await pc.createOffer()
      const sdp = mungeOpus(offer.sdp ?? '')
      await pc.setLocalDescription({ type: 'offer', sdp })
      this.signal(peer, { call_id: callId, action: 'offer', sdp: this.advertise(sdp), video })
      this.ringer.start('outgoing')
      this.timeout = setTimeout(() => this.hangup('missed'), 45_000)
    } catch (e) {
      this.finish(e instanceof Error && e.name === 'NotAllowedError' ? 'Micro ou caméra refusés.' : 'Appel impossible.', 'ended')
    }
  }

  private advertise(sdp: string): string {
    if (!frameE2eeSupported()) return sdp
    return sdp.replace(/\r\n$/, '') + '\r\n' + E2EE_LINE + '\r\n'
  }

  private stripAdvert(sdp: string): { sdp: string; e2ee: boolean } {
    const e2ee = sdp.includes(E2EE_LINE)
    return { sdp: sdp.replace(E2EE_LINE + '\r\n', '').replace(E2EE_LINE, ''), e2ee }
  }

  async handleSignal(peer: string, s: CallSignal) {
    switch (s.action) {
      case 'offer': {
        if (this.busy && this.snap.callId !== s.call_id) {
          this.signal(peer, { call_id: s.call_id, action: 'busy', video: s.video })
          this.onEnded({ peer, callId: s.call_id, video: s.video, outgoing: false, outcome: 'missed' })
          return
        }
        if (this.snap.callId === s.call_id) return
        this.outgoing = false
        this.pendingOffer = s.sdp ?? ''
        this.pendingIce = []
        this.set({ ...CallManager.idle(), phase: 'incoming', callId: s.call_id, peer, video: s.video })
        this.ringer.start('incoming')
        this.timeout = setTimeout(() => {
          if (this.snap.phase === 'incoming') this.finish('Appel manqué.', 'missed', false)
        }, 45_000)
        break
      }
      case 'answer': {
        if (s.call_id !== this.snap.callId || !this.pc) return
        const { sdp, e2ee } = this.stripAdvert(s.sdp ?? '')
        this.remoteE2ee = e2ee && frameE2eeSupported()
        this.enableFrameCrypto(peer, s.call_id)
        await this.pc.setRemoteDescription({ type: 'answer', sdp: mungeOpus(sdp) })
        await this.flushIce()
        this.ringer.stop()
        if (this.timeout) clearTimeout(this.timeout)
        this.set({ phase: 'connecting' })
        break
      }
      case 'ice': {
        if (s.call_id !== this.snap.callId || !s.candidate) return
        const c = JSON.parse(s.candidate) as RTCIceCandidateInit
        if (this.pc?.remoteDescription) await this.pc.addIceCandidate(c).catch(() => {})
        else this.pendingIce.push(c)
        break
      }
      case 'end':
        if (s.call_id === this.snap.callId)
          this.finish('Appel terminé.', this.snap.phase === 'incoming' ? 'missed' : 'ended', false)
        break
      case 'decline':
        if (s.call_id === this.snap.callId) this.finish('Appel refusé.', 'declined', false)
        break
      case 'busy':
        if (s.call_id === this.snap.callId) this.finish('Déjà en ligne.', 'busy', false)
        break
    }
  }

  async accept() {
    const { peer, callId, video } = this.snap
    if (this.snap.phase !== 'incoming' || !peer || !callId || this.pendingOffer === null) return
    this.ringer.stop()
    if (this.timeout) clearTimeout(this.timeout)
    this.set({ phase: 'connecting' })
    try {
      const { sdp: offer, e2ee } = this.stripAdvert(this.pendingOffer)
      this.remoteE2ee = e2ee && frameE2eeSupported()
      const local = await this.media(video)
      const pc = await this.createPc(peer, callId)
      this.enableFrameCrypto(peer, callId)
      await pc.setRemoteDescription({ type: 'offer', sdp: mungeOpus(offer) })
      this.addLocal(pc, local, video, this.remoteE2ee)
      const answer = await pc.createAnswer()
      const sdp = mungeOpus(answer.sdp ?? '')
      await pc.setLocalDescription({ type: 'answer', sdp })
      this.signal(peer, { call_id: callId, action: 'answer', sdp: this.remoteE2ee ? this.advertise(sdp) : sdp, video })
      await this.flushIce()
    } catch (e) {
      this.signal(peer, { call_id: callId, action: 'end', video })
      this.finish(e instanceof Error && e.name === 'NotAllowedError' ? 'Micro ou caméra refusés.' : 'Appel impossible.', 'ended')
    }
  }

  decline() {
    const { peer, callId, video } = this.snap
    if (!peer || !callId) return
    this.signal(peer, { call_id: callId, action: 'decline', video })
    this.finish('Appel refusé.', 'declined', false)
  }

  hangup(outcome: 'ended' | 'missed' = 'ended') {
    const { peer, callId, video } = this.snap
    if (!peer || !callId) return
    this.signal(peer, { call_id: callId, action: 'end', video })
    this.finish(outcome === 'missed' ? 'Pas de réponse.' : 'Appel terminé.', outcome)
  }

  toggleMute() {
    const muted = !this.snap.muted
    this.snap.localStream?.getAudioTracks().forEach((t) => (t.enabled = !muted))
    this.set({ muted })
  }

  toggleCamera() {
    const cameraOff = !this.snap.cameraOff
    this.snap.localStream?.getVideoTracks().forEach((t) => (t.enabled = !cameraOff))
    this.set({ cameraOff })
  }

  toggleSpeaker() {
    this.set({ speaker: !this.snap.speaker })
  }

  private async media(video: boolean): Promise<MediaStream> {
    const stream = await navigator.mediaDevices.getUserMedia({
      audio: AUDIO_CONSTRAINTS,
      video: video ? VIDEO_CONSTRAINTS : false,
    })
    stream.getVideoTracks().forEach((t) => (t.contentHint = 'motion'))
    this.set({ localStream: stream })
    return stream
  }

  private async createPc(peer: string, callId: string): Promise<RTCPeerConnection> {
    const config: RTCConfiguration & { encodedInsertableStreams?: boolean } = {
      iceServers: await this.iceServers(),
      bundlePolicy: 'max-bundle',
    }
    if (!ScriptTransform && hasEncodedStreams) config.encodedInsertableStreams = true
    const pc = new RTCPeerConnection(config)
    this.pc = pc
    if (frameE2eeSupported()) {
      this.worker = new Worker(new URL('./e2ee.worker.ts', import.meta.url), { type: 'module' })
      this.worker.postMessage({ t: 'key', key: this.callKey(peer, callId) })
      this.worker.postMessage({ t: 'mode', enabled: false })
    }
    const remote = new MediaStream()
    this.set({ remoteStream: remote })
    pc.onicecandidate = (e) => {
      if (e.candidate)
        this.signal(peer, {
          call_id: callId,
          action: 'ice',
          candidate: JSON.stringify(e.candidate.toJSON()),
          video: this.snap.video,
        })
    }
    pc.ontrack = (e) => {
      this.attachReceiver(e.receiver, e.track.kind)
      remote.addTrack(e.track)
      if (e.track.kind === 'audio') this.watchLevel(remote)
      this.set({ remoteStream: remote })
    }
    pc.onconnectionstatechange = () => {
      const st = pc.connectionState
      if (st === 'connected' && this.snap.phase !== 'active') {
        this.set({ phase: 'active', startedAt: Date.now(), security: this.remoteE2ee ? 'frame' : 'srtp' })
        this.startStats()
      } else if (st === 'failed') {
        this.hangup()
      }
    }
    return pc
  }

  private addLocal(pc: RTCPeerConnection, stream: MediaStream, video: boolean, e2eeLikely: boolean) {
    for (const track of stream.getTracks()) {
      const isVideo = track.kind === 'video'
      let tr: RTCRtpTransceiver
      // Reuse the transceiver the remote offer created, else add one.
      const existing = pc.getTransceivers().find((t) => t.receiver.track.kind === track.kind && !t.sender.track)
      if (existing) {
        existing.direction = 'sendrecv'
        void existing.sender.replaceTrack(track)
        existing.sender.setStreams?.(stream)
        tr = existing
      } else {
        const enc: RTCRtpEncodingParameters & { scalabilityMode?: string } = isVideo
          ? { maxBitrate: 2_500_000, maxFramerate: 30, scalabilityMode: 'L1T3' }
          : { networkPriority: 'high', priority: 'high' }
        try {
          tr = pc.addTransceiver(track, { direction: 'sendrecv', streams: [stream], sendEncodings: [enc] })
        } catch {
          tr = pc.addTransceiver(track, { direction: 'sendrecv', streams: [stream] })
        }
      }
      if (isVideo) {
        const prefs = orderVideoCodecs(e2eeLikely)
        if (prefs?.length) {
          try {
            tr.setCodecPreferences(prefs)
          } catch {
            /* unsupported */
          }
        }
        void this.tuneVideoSender(tr.sender)
      }
      this.attachSender(tr.sender)
    }
    if (!video) return
  }

  private async tuneVideoSender(sender: RTCRtpSender) {
    try {
      const p = sender.getParameters() as RTCRtpSendParameters & { degradationPreference?: string }
      p.degradationPreference = 'maintain-framerate'
      if (p.encodings?.[0]) {
        p.encodings[0].maxBitrate = 2_500_000
        p.encodings[0].maxFramerate = 30
      }
      await sender.setParameters(p)
    } catch {
      /* not supported before negotiation in some browsers */
    }
  }

  private attachSender(sender: RTCRtpSender) {
    if (!this.worker) return
    if (ScriptTransform) {
      ;(sender as unknown as { transform: unknown }).transform = new ScriptTransform(this.worker, { direction: 'encrypt' })
    } else if (hasEncodedStreams) {
      const s = (sender as unknown as { createEncodedStreams(): { readable: ReadableStream; writable: WritableStream } }).createEncodedStreams()
      this.worker.postMessage({ t: 'streams', direction: 'encrypt', readable: s.readable, writable: s.writable }, [
        s.readable as unknown as Transferable,
        s.writable as unknown as Transferable,
      ])
    }
  }

  private attachReceiver(receiver: RTCRtpReceiver, kind: string) {
    try {
      ;(receiver as unknown as { jitterBufferTarget: number }).jitterBufferTarget = kind === 'audio' ? 40 : 80
    } catch {
      /* not supported */
    }
    if (!this.worker) return
    if (ScriptTransform) {
      ;(receiver as unknown as { transform: unknown }).transform = new ScriptTransform(this.worker, { direction: 'decrypt' })
    } else if (hasEncodedStreams) {
      const s = (receiver as unknown as { createEncodedStreams(): { readable: ReadableStream; writable: WritableStream } }).createEncodedStreams()
      this.worker.postMessage({ t: 'streams', direction: 'decrypt', readable: s.readable, writable: s.writable }, [
        s.readable as unknown as Transferable,
        s.writable as unknown as Transferable,
      ])
    }
  }

  private enableFrameCrypto(_peer: string, _callId: string) {
    this.worker?.postMessage({ t: 'mode', enabled: this.remoteE2ee })
  }

  private async flushIce() {
    for (const c of this.pendingIce.splice(0)) await this.pc?.addIceCandidate(c).catch(() => {})
  }

  private watchLevel(stream: MediaStream) {
    if (this.audioCtx) return
    try {
      this.audioCtx = new AudioContext()
      this.analyser = this.audioCtx.createAnalyser()
      this.analyser.fftSize = 512
      this.audioCtx.createMediaStreamSource(stream).connect(this.analyser)
    } catch {
      this.analyser = null
    }
  }

  private startStats() {
    this.statsTimer = setInterval(async () => {
      const pc = this.pc
      if (!pc) return
      const stats = await pc.getStats()
      let rtt: number | null = null
      let available: number | null = null
      stats.forEach((r) => {
        if (r.type === 'candidate-pair' && r.nominated && r.state === 'succeeded') {
          if (typeof r.currentRoundTripTime === 'number') rtt = Math.round(r.currentRoundTripTime * 1000)
          if (typeof r.availableOutgoingBitrate === 'number') available = r.availableOutgoingBitrate
        }
      })
      this.set({ rttMs: rtt })
      if (this.snap.video) this.adaptVideo(available)
    }, 2000)
  }

  /** Audio-only under 150 kbps for 4 s, video retried every 10 s. */
  private adaptVideo(available: number | null) {
    const sender = this.pc?.getSenders().find((s) => s.track?.kind === 'video' || (this.pausedVideoTrack && !s.track && s !== undefined))
    const now = Date.now()
    if (!this.snap.videoPaused) {
      if (available !== null && available < 150_000) {
        if (!this.lowSince) this.lowSince = now
        if (now - this.lowSince >= 4000 && sender?.track) {
          this.pausedVideoTrack = sender.track
          void sender.replaceTrack(null)
          this.retryAt = now + 10_000
          this.set({ videoPaused: true })
        }
      } else this.lowSince = 0
    } else if (now >= this.retryAt && this.pausedVideoTrack) {
      const s = this.pc?.getSenders().find((x) => !x.track)
      if (s) void s.replaceTrack(this.pausedVideoTrack)
      this.pausedVideoTrack = null
      this.lowSince = 0
      this.set({ videoPaused: false })
    }
  }

  private finish(reason: string, outcome: CallEndInfo['outcome'], _local = true) {
    const { peer, callId, video, startedAt } = this.snap
    this.ringer.stop()
    if (this.timeout) clearTimeout(this.timeout)
    if (this.statsTimer) clearInterval(this.statsTimer)
    this.timeout = this.statsTimer = null
    this.snap.localStream?.getTracks().forEach((t) => t.stop())
    this.pausedVideoTrack?.stop()
    this.pausedVideoTrack = null
    this.pc?.close()
    this.pc = null
    this.worker?.terminate()
    this.worker = null
    this.audioCtx?.close().catch(() => {})
    this.audioCtx = null
    this.analyser = null
    this.pendingOffer = null
    this.pendingIce = []
    this.remoteE2ee = false
    if (peer && callId)
      this.onEnded({
        peer,
        callId,
        video,
        outgoing: this.outgoing,
        outcome: startedAt ? 'ended' : outcome,
        durationMs: startedAt ? Date.now() - startedAt : undefined,
      })
    this.set({ phase: 'ended', endReason: reason, localStream: null, remoteStream: null })
    setTimeout(() => {
      if (this.snap.phase === 'ended') this.set(CallManager.idle())
    }, 1600)
  }
}
