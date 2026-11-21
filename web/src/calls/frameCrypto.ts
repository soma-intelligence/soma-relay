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
//   keys  = material 0 = callKey(fp, call_id); AES-128-GCM key n = HKDF-SHA256(material n,
//           salt "soma-relay call ratchet", info 128 zero bytes, 16 bytes);
//           material n+1 = same HKDF with 32 bytes; new index every 5 minutes;
//           keyIndex in the trailer = n mod 16 (ring of 16).

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

const SALT = new TextEncoder().encode('soma-relay call ratchet')
/** LiveKit's HKDF info for both the AES key and the ratchet: 128 zero bytes. */
const INFO = new Uint8Array(128)

async function hkdf(material: Uint8Array, bits: number): Promise<Uint8Array> {
  const base = await crypto.subtle.importKey('raw', material.slice().buffer as ArrayBuffer, 'HKDF', false, ['deriveBits'])
  return new Uint8Array(await crypto.subtle.deriveBits({ name: 'HKDF', hash: 'SHA-256', salt: SALT, info: INFO }, base, bits))
}

/** AES-128-GCM key of one material, as LiveKit's key provider derives it (never the raw material). */
async function frameKey(material: Uint8Array): Promise<CryptoKey> {
  const raw = await hkdf(material, 128)
  return crypto.subtle.importKey('raw', raw.buffer as ArrayBuffer, 'AES-GCM', false, ['encrypt', 'decrypt'])
}

export class FrameCrypto {
  private keys: (CryptoKey | null)[] = new Array(KEY_RING).fill(null)
  /** Material of the highest derived index. */
  private material: Uint8Array | null = null
  /** Highest derived index (absolute, not modulo). */
  private derived = 0
  /** Index this side sends with, moves every RATCHET_MS. */
  private sendIndex = 0
  private counter = 0
  private started = 0
  private deriving: Promise<void> = Promise.resolve()
  /** Frames that failed to decrypt (shown in debug). */
  failures = 0
  /** False: frames pass through untouched (the peer does not do frame E2EE). */
  enabled = false

  async setKey(material: Uint8Array) {
    this.material = material.slice()
    this.derived = 0
    this.sendIndex = 0
    this.keys.fill(null)
    this.keys[0] = await frameKey(this.material)
    this.started = Date.now()
    // Like iOS: keep the next index ready, so a peer whose timer fires first still decrypts.
    await this.ensure(1)
  }

  /** Derives materials and keys up to absolute index `target`, one step at a time. */
  private ensure(target: number): Promise<void> {
    this.deriving = this.deriving.then(async () => {
      let guard = 0
      while (this.material && this.derived < target && guard++ < KEY_RING) {
        this.material = await hkdf(this.material, 256)
        this.derived++
        this.keys[this.derived % KEY_RING] = await frameKey(this.material)
      }
    })
    return this.deriving
  }

  private async maybeRatchet() {
    if (!this.material) return
    const due = Math.floor((Date.now() - this.started) / RATCHET_MS)
    if (due > this.sendIndex) {
      await this.ensure(due + 1)
      this.sendIndex = due
    }
  }

  async encrypt(frame: EncodedFrame): Promise<EncodedFrame | null> {
    void this.maybeRatchet()
    const key = this.keys[this.sendIndex % KEY_RING]
    if (!key) return null
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
    out[out.length - 1] = this.sendIndex % KEY_RING
    frame.data = out.buffer
    return frame
  }

  async decrypt(frame: EncodedFrame): Promise<EncodedFrame | null> {
    const data = new Uint8Array(frame.data)
    if (data.length < IV_LENGTH + 2 + 16) return null
    const ivLength = data[data.length - 2]
    const keyIndex = data[data.length - 1]
    if (ivLength !== IV_LENGTH) return null
    if (keyIndex >= KEY_RING) return null
    // The index wraps at 16: a short step ahead of the highest derived index is the peer
    // ratcheting first; anything else is the current or a recent key.
    const ahead = (keyIndex - (this.derived % KEY_RING) + KEY_RING) % KEY_RING
    if (ahead > 0 && ahead <= KEY_RING / 2) await this.ensure(this.derived + ahead)
    const key = this.keys[keyIndex]
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
