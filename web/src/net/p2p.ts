// P2P: WebRTC data channels between online contacts. Envelopes go over the channel as they
// are (already end-to-end encrypted by the core), so the channel is only a faster pipe.
//
// Signalling rides on encrypted AppMessage kind "call" with a call_id starting with "dc:"
// (the AppMessage schema has no other field for it, and postcard drops unknown fields).
// Glare: if both sides offer at once, the smaller fingerprint keeps its offer.

import type { CallSignal } from '../core/engine'
import { uuidv7 } from '../lib/bytes'

interface Link {
  pc: RTCPeerConnection
  dc: RTCDataChannel | null
  callId: string
  pendingIce: RTCIceCandidateInit[]
  opening: boolean
  since: number
}

export const isDataChannelSignal = (s: CallSignal) => s.call_id.startsWith('dc:')

export class P2P {
  private links = new Map<string, Link>()

  constructor(
    private myFp: () => string,
    private signal: (fp: string, s: CallSignal) => void,
    private onEnvelope: (fp: string, env: Uint8Array) => void,
    private iceServers: () => Promise<RTCIceServer[]>,
    private onChange: () => void,
  ) {}

  isOpen(fp: string): boolean {
    return this.links.get(fp)?.dc?.readyState === 'open'
  }

  openPeers(): string[] {
    return [...this.links.keys()].filter((fp) => this.isOpen(fp))
  }

  send(fp: string, env: Uint8Array): boolean {
    const dc = this.links.get(fp)?.dc
    if (!dc || dc.readyState !== 'open') return false
    if (env.length > 200_000) return false
    try {
      dc.send(env.slice().buffer as ArrayBuffer)
      return true
    } catch {
      return false
    }
  }

  /** Starts a link if none is open or opening (or the last attempt is stale). */
  async connect(fp: string) {
    const existing = this.links.get(fp)
    if (existing && (this.isOpen(fp) || Date.now() - existing.since < 15_000)) return
    if (existing) this.close(fp, false)
    const link = await this.newLink(fp, 'dc:' + uuidv7())
    const dc = link.pc.createDataChannel('relay', { ordered: true })
    this.wire(fp, link, dc)
    link.opening = true
    const offer = await link.pc.createOffer()
    await link.pc.setLocalDescription(offer)
    this.signal(fp, { call_id: link.callId, action: 'offer', sdp: offer.sdp, video: false })
  }

  private async newLink(fp: string, callId: string): Promise<Link> {
    const pc = new RTCPeerConnection({ iceServers: await this.iceServers() })
    const link: Link = { pc, dc: null, callId, pendingIce: [], opening: false, since: Date.now() }
    this.links.set(fp, link)
    pc.onicecandidate = (e) => {
      if (e.candidate)
        this.signal(fp, {
          call_id: link.callId,
          action: 'ice',
          candidate: JSON.stringify(e.candidate.toJSON()),
          video: false,
        })
    }
    pc.ondatachannel = (e) => this.wire(fp, link, e.channel)
    pc.onconnectionstatechange = () => {
      if (pc.connectionState === 'failed' || pc.connectionState === 'closed') {
        if (this.links.get(fp) === link) this.close(fp, false)
      }
    }
    return link
  }

  private wire(fp: string, link: Link, dc: RTCDataChannel) {
    link.dc = dc
    dc.binaryType = 'arraybuffer'
    dc.onopen = () => this.onChange()
    dc.onclose = () => this.onChange()
    dc.onmessage = (e) => {
      if (e.data instanceof ArrayBuffer) this.onEnvelope(fp, new Uint8Array(e.data))
    }
  }

  async handleSignal(fp: string, s: CallSignal) {
    let link = this.links.get(fp)
    switch (s.action) {
      case 'offer': {
        if (link && link.opening && link.callId !== s.call_id) {
          // Glare: the smaller fingerprint keeps its own offer.
          if (this.myFp() < fp) return
          this.close(fp, false)
          link = undefined
        } else if (link && link.callId !== s.call_id) {
          this.close(fp, false)
          link = undefined
        }
        link = link ?? (await this.newLink(fp, s.call_id))
        await link.pc.setRemoteDescription({ type: 'offer', sdp: s.sdp })
        const answer = await link.pc.createAnswer()
        await link.pc.setLocalDescription(answer)
        this.signal(fp, { call_id: s.call_id, action: 'answer', sdp: answer.sdp, video: false })
        await this.flushIce(link)
        break
      }
      case 'answer':
        if (!link || link.callId !== s.call_id || link.pc.signalingState !== 'have-local-offer') return
        await link.pc.setRemoteDescription({ type: 'answer', sdp: s.sdp })
        link.opening = false
        await this.flushIce(link)
        break
      case 'ice': {
        if (!link || link.callId !== s.call_id || !s.candidate) return
        const cand = JSON.parse(s.candidate) as RTCIceCandidateInit
        if (link.pc.remoteDescription) await link.pc.addIceCandidate(cand).catch(() => {})
        else link.pendingIce.push(cand)
        break
      }
      case 'end':
      case 'decline':
      case 'busy':
        if (link && link.callId === s.call_id) this.close(fp, false)
        break
    }
  }

  private async flushIce(link: Link) {
    for (const c of link.pendingIce.splice(0)) await link.pc.addIceCandidate(c).catch(() => {})
  }

  close(fp: string, notify = true) {
    const link = this.links.get(fp)
    if (!link) return
    this.links.delete(fp)
    if (notify) this.signal(fp, { call_id: link.callId, action: 'end', video: false })
    link.dc?.close()
    link.pc.close()
    this.onChange()
  }

  closeAll() {
    for (const fp of [...this.links.keys()]) this.close(fp, false)
  }
}
