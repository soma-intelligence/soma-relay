// Service worker registration and Web Push subscription (spec v1.1 section 2).
// Nothing here asks for a permission: the caller does that on a user click.

let registration: Promise<ServiceWorkerRegistration | null> | null = null

export function swSupported(): boolean {
  return typeof navigator !== 'undefined' && 'serviceWorker' in navigator && window.isSecureContext
}

/** Registers /sw.js once (no permission involved). */
export function registerSW(): Promise<ServiceWorkerRegistration | null> {
  if (!swSupported()) return Promise.resolve(null)
  registration ??= navigator.serviceWorker
    .register(new URL('sw.js', location.origin + '/').pathname, { scope: '/' })
    .then(() => navigator.serviceWorker.ready)
    .catch((e) => {
      console.info('service worker unavailable', e)
      return null
    })
  return registration
}

function b64urlToBytes(s: string): Uint8Array<ArrayBuffer> {
  const b64 = s.replace(/-/g, '+').replace(/_/g, '/') + '==='.slice((s.length + 3) % 4)
  const bin = atob(b64)
  const out = new Uint8Array(new ArrayBuffer(bin.length))
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i)
  return out
}

function sameKey(sub: PushSubscription, key: Uint8Array): boolean {
  const cur = sub.options.applicationServerKey
  if (!cur) return false
  const a = new Uint8Array(cur)
  return a.length === key.length && a.every((x, i) => x === key[i])
}

/** Push subscription for this origin under the node's VAPID key, or null when unavailable. */
export async function pushSubscription(vapidB64Url: string): Promise<PushSubscriptionJSON | null> {
  const reg = await registerSW()
  if (!reg || !('pushManager' in reg)) return null
  const key = b64urlToBytes(vapidB64Url)
  try {
    let sub = await reg.pushManager.getSubscription()
    if (sub && !sameKey(sub, key)) {
      await sub.unsubscribe()
      sub = null
    }
    sub ??= await reg.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: key })
    return sub.toJSON()
  } catch (e) {
    console.info('push subscription failed', e)
    return null
  }
}
