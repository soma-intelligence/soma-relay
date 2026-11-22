// Soma Relay service worker: Web Push wake-ups and notification clicks only. No caching.
//
// The node never puts content in a push: the payload is {"t":"wake"}. When no window of the
// app is visible we show "Nouveau message"; the app fetches and decrypts when it opens.

self.addEventListener('install', () => self.skipWaiting())
self.addEventListener('activate', (event) => event.waitUntil(self.clients.claim()))

self.addEventListener('push', (event) => {
  let data = {}
  try {
    data = event.data ? event.data.json() : {}
  } catch {
    data = {}
  }
  if (data.t !== 'wake') return
  event.waitUntil(
    self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then((list) => {
      if (list.some((c) => c.visibilityState === 'visible')) return undefined
      return self.registration.showNotification('Soma Relay', {
        body: 'Nouveau message',
        tag: 'relay',
        icon: 'icon-512.png',
        data: { url: self.registration.scope },
      })
    }),
  )
})

self.addEventListener('notificationclick', (event) => {
  event.notification.close()
  const data = event.notification.data || {}
  const target = typeof data.url === 'string' ? data.url : self.registration.scope
  event.waitUntil(
    self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then(async (list) => {
      // Prefer the window of the same profile (same query string), else any window of the app.
      const same = list.find((c) => c.url === target) || list.find((c) => c.url.split('#')[0] === target.split('#')[0])
      const client = same || list[0]
      if (client) {
        await client.focus()
        if (data.conv) client.postMessage({ t: 'open', conv: data.conv })
        return
      }
      const url = new URL(target)
      if (data.conv) url.hash = 'conv=' + encodeURIComponent(data.conv)
      await self.clients.openWindow(url.toString())
    }),
  )
})
