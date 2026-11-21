/// <reference lib="webworker" />
// Call frame E2EE worker. Two entry points:
// - RTCRtpScriptTransform: `rtctransform` events with options {direction}.
// - createEncodedStreams fallback (Chromium): a message {t:'streams', direction, readable, writable}.
// The key arrives as {t:'key', key: Uint8Array}; {t:'mode', enabled} turns encryption on
// (off = pass through, when the peer does not do frame E2EE).

import { FrameCrypto } from './frameCrypto'

const crypto_ = new FrameCrypto()
let ready: Promise<void> = Promise.resolve()

interface RTCTransformEventLike extends Event {
  transformer: { readable: ReadableStream; writable: WritableStream; options?: { direction?: string } }
}

function pipe(direction: 'encrypt' | 'decrypt', readable: ReadableStream, writable: WritableStream) {
  ready
    .then(() => readable.pipeThrough(crypto_.transformStream(direction)).pipeTo(writable))
    .catch(() => {})
}

self.addEventListener('rtctransform', (event) => {
  const t = (event as RTCTransformEventLike).transformer
  pipe(t.options?.direction === 'decrypt' ? 'decrypt' : 'encrypt', t.readable, t.writable)
})

self.onmessage = (e: MessageEvent) => {
  const m = e.data as
    | { t: 'key'; key: Uint8Array }
    | { t: 'mode'; enabled: boolean }
    | { t: 'streams'; direction: 'encrypt' | 'decrypt'; readable: ReadableStream; writable: WritableStream }
  if (m.t === 'key') ready = crypto_.setKey(m.key)
  else if (m.t === 'mode') crypto_.enabled = m.enabled
  else if (m.t === 'streams') pipe(m.direction, m.readable, m.writable)
}
