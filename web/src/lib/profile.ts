// `?profile=<name>` namespaces every storage (IndexedDB, localStorage, BroadcastChannel) so
// two instances can run side by side in one browser.

function readProfile(): string {
  const raw = new URLSearchParams(location.search).get('profile') ?? 'default'
  const clean = raw.toLowerCase().replace(/[^a-z0-9_-]/g, '').slice(0, 32)
  return clean || 'default'
}

export const PROFILE = readProfile()
export const ns = (key: string): string => `soma-relay:${PROFILE}:${key}`

export function localGet(key: string): string | null {
  try {
    return localStorage.getItem(ns(key))
  } catch {
    return null
  }
}

export function localSet(key: string, value: string | null): void {
  try {
    if (value === null) localStorage.removeItem(ns(key))
    else localStorage.setItem(ns(key), value)
  } catch {
    /* private mode */
  }
}
