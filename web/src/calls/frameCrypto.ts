// Frame E2EE for calls, shared by the worker (RTCRtpScriptTransform) and the main-thread
// fallback (createEncodedStreams). Layout matches the LiveKit frame cryptor so the iOS app
// (LiveKit libwebrtc fork, RTCFrameCryptor) interoperates. See docs/research/calls.md, "Interop".
//
//   frame = clear header || AES-GCM(ciphertext || tag 16) || IV (12) || [ivLength = 12, keyIndex]
//   AAD   = clear header
//   clear header: audio 1 byte; VP8 10 bytes (key frame) or 3 (delta);
//                 H.264 up to and including the first slice NALU header + 1 byte;
//                 other codecs: VP8 rule (E2EE calls negotiate VP8 or H.264 only).
//   IV    = ssrc (u32 BE) || rtp timestamp (u32 BE) || send counter (u32 BE)
//   keys  = key 0 = callKey(fp, call_id) used raw as AES-256-GCM; key n+1 = HKDF-SHA256(key n,
//           salt "soma-relay call ratchet", info "ratchet"), new index every 5 minutes, ring of 16.

export const IV_LENGTH = 12
export const RATCHET_MS = 5 * 60_000
const KEY_RING = 16

type EncodedFrame = RTCEncodedAudioFrame | RTCEncodedVideoFrame

function isVideo(f: EncodedFrame): f is RTCEncodedVideoFrame {
  return 'type' in f
}

function h264ClearBytes(data: Uint8Array): number | null {
  // Annex B: find NAL units; keep clear up to the first slice (type 1 or 5) header + 1 byte.
  let i = 0
  const n = data.length
  const startAt = (p: number) =>
    p + 3 < n && data[p] === 0 && data[p + 1] === 0 && (data[p + 2] === 1 || (data[p + 2] === 0 && data[p + 3] === 1))
  if (!startAt(0)) return null
  while (i < n) {
    if (startAt(i)) {
      const sc = data[i + 2] === 1 ? 3 : 4
      const nal = i + sc
      if (nal >= n) return null
      const type = data[nal] & 0x1f
      if (type === 1 || type === 5) return Math.min(n, nal + 2)
      i = nal + 1
    } else i++
  }
  return null
}

export function clearBytes(f: EncodedFrame, data: Uint8Array): number {
  if (!isVideo(f)) return 1
  const h264 = h264ClearBytes(data)
  if (h264 !== null) return h264
  return f.type === 'key' ? 10 : 3
}

async function hkdfNext(raw: Uint8Array): Promise<Uint8Array> {
  const base = await crypto.subtle.importKey('raw', raw.slice().buffer as ArrayBuffer, 'HKDF', false, ['deriveBits'])
  const bits = await crypto.subtle.deriveBits(
    {
      name: 'HKDF',
      hash: 'SHA-256',
      salt: new TextEncoder().encode('soma-relay call ratchet'),
      info: new TextEncoder().encode('ratchet'),
    },
    base,
    256,
  )
  return new Uint8Array(bits)
}

export class FrameCrypto {
  private keys: (CryptoKey | null)[] = new Array(KEY_RING).fill(null)
  private raw: Uint8Array | null = null
  private index = 0
  private counter = 0
  private started = 0
  private ratcheting = false
  /** Frames that failed to decrypt (shown in debug). */
  failures = 0
  /** False: frames pass through untouched (the peer does not do frame E2EE). */
  enabled = false

  async setKey(raw: Uint8Array) {
    this.raw = raw.slice()
    this.index = 0
    this.keys.fill(null)
    this.keys[0] = await this.importRaw(this.raw)
    this.started = Date.now()
  }

  private importRaw(raw: Uint8Array) {
    return crypto.subtle.importKey('raw', raw.slice().buffer as ArrayBuffer, 'AES-GCM', false, ['encrypt', 'decrypt'])
  }

  /** Derives keys up to `target` (index modulo the ring). */
  private async ensure(target: number) {
    if (!this.raw) return
    let guard = 0
    while (this.index < target && guard++ < KEY_RING) {
      this.raw = await hkdfNext(this.raw)
      this.index++
      this.keys[this.index % KEY_RING] = await this.importRaw(this.raw)
    }
  }

  private async maybeRatchet() {
    if (this.ratcheting || !this.raw) return
    const due = Math.floor((Date.now() - this.started) / RATCHET_MS)
    if (due > this.index) {
      this.ratcheting = true
      await this.ensure(due)
      this.ratcheting = false
    }
  }

  async encrypt(frame: EncodedFrame): Promise<EncodedFrame | null> {
    const key = this.keys[this.index % KEY_RING]
    if (!key) return null
    void this.maybeRatchet()
    const data = new Uint8Array(frame.data)
    if (data.length === 0) return frame
    const clear = Math.min(clearBytes(frame, data), data.length)
    const meta = frame.getMetadata() as { synchronizationSource?: number; rtpTimestamp?: number }
    const iv = new Uint8Array(IV_LENGTH)
    const view = new DataView(iv.buffer)
    view.setUint32(0, meta.synchronizationSource ?? 0)
    view.setUint32(4, (meta.rtpTimestamp ?? (frame as { timestamp?: number }).timestamp ?? 0) >>> 0)
    view.setUint32(8, this.counter++ >>> 0)
    const header = data.subarray(0, clear)
    const ct = new Uint8Array(
      await crypto.subtle.encrypt(
        { name: 'AES-GCM', iv, additionalData: header.slice(), tagLength: 128 },
        key,
        data.slice(clear),
      ),
    )
    const out = new Uint8Array(clear + ct.length + IV_LENGTH + 2)
    out.set(header, 0)
    out.set(ct, clear)
    out.set(iv, clear + ct.length)
    out[out.length - 2] = IV_LENGTH
    out[out.length - 1] = this.index % 256
    frame.data = out.buffer
    return frame
  }

  async decrypt(frame: EncodedFrame): Promise<EncodedFrame | null> {
    const data = new Uint8Array(frame.data)
    if (data.length < IV_LENGTH + 2 + 16) return null
    const ivLength = data[data.length - 2]
    const keyIndex = data[data.length - 1]
    if (ivLength !== IV_LENGTH) return null
    if (keyIndex > this.index % 256 && keyIndex - (this.index % 256) < KEY_RING) await this.ensure(keyIndex)
    const key = this.keys[keyIndex % KEY_RING]
    if (!key) return null
    const clear = Math.min(clearBytes(frame, data), data.length)
    const ivStart = data.length - 2 - IV_LENGTH
    if (ivStart <= clear) return null
    try {
      const plain = new Uint8Array(
        await crypto.subtle.decrypt(
          {
            name: 'AES-GCM',
            iv: data.slice(ivStart, ivStart + IV_LENGTH),
            additionalData: data.slice(0, clear),
            tagLength: 128,
          },
          key,
          data.slice(clear, ivStart),
        ),
      )
      const out = new Uint8Array(clear + plain.length)
      out.set(data.subarray(0, clear), 0)
      out.set(plain, clear)
      frame.data = out.buffer
      return frame
    } catch {
      this.failures++
      return null
    }
  }

  transformStream(direction: 'encrypt' | 'decrypt') {
    return new TransformStream<EncodedFrame, EncodedFrame>({
      transform: async (frame, controller) => {
        if (!this.enabled) {
          controller.enqueue(frame)
          return
        }
        const out = direction === 'encrypt' ? await this.encrypt(frame) : await this.decrypt(frame)
        if (out) controller.enqueue(out)
      },
    })
  }
}
