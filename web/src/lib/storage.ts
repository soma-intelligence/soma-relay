// IndexedDB storage. Every value is sealed with AES-256-GCM under a non-extractable WebCrypto
// key that lives in the same database (structured clone keeps it non-extractable): a copy of
// the files is useless without the browser's key store. Plain fields are only what indexing
// needs (ids, conversation id, timestamp).

import { openDB, type IDBPDatabase } from 'idb'
import { PROFILE } from './profile'
import { buf, fromUtf8, randomBytes, utf8 } from './bytes'

interface SealedRecord {
  id: string
  convId?: string
  ts?: number
  iv: Uint8Array
  ct: ArrayBuffer
}

const STORES = ['meta', 'conversations', 'messages', 'outbox', 'media', 'profiles'] as const
type StoreName = (typeof STORES)[number]

export class Storage {
  private constructor(
    private db: IDBPDatabase,
    private key: CryptoKey,
  ) {}

  static readonly dbName = `soma-relay-${PROFILE}`

  static async open(): Promise<Storage> {
    // v2 adds `profiles` (photos and names received from contacts and groups).
    const db = await openDB(Storage.dbName, 2, {
      upgrade(db, oldVersion) {
        if (oldVersion < 1) {
          db.createObjectStore('keys')
          for (const s of STORES) {
            if (s === 'profiles') continue
            const store = db.createObjectStore(s, { keyPath: 'id' })
            if (s === 'messages') store.createIndex('conv', ['convId', 'ts'])
          }
        }
        if (oldVersion < 2) db.createObjectStore('profiles', { keyPath: 'id' })
      },
    })
    let key = (await db.get('keys', 'seal')) as CryptoKey | undefined
    if (!key) {
      key = await crypto.subtle.generateKey({ name: 'AES-GCM', length: 256 }, false, ['encrypt', 'decrypt'])
      await db.put('keys', key, 'seal')
    }
    return new Storage(db, key)
  }

  private async seal(plain: Uint8Array): Promise<{ iv: Uint8Array; ct: ArrayBuffer }> {
    const iv = randomBytes(12)
    const ct = await crypto.subtle.encrypt({ name: 'AES-GCM', iv: buf(iv) }, this.key, buf(plain))
    return { iv, ct }
  }

  private async unseal(r: SealedRecord): Promise<Uint8Array> {
    return new Uint8Array(await crypto.subtle.decrypt({ name: 'AES-GCM', iv: buf(r.iv) }, this.key, r.ct))
  }

  async putJson(store: StoreName, id: string, value: unknown, index?: { convId?: string; ts?: number }) {
    const { iv, ct } = await this.seal(utf8(JSON.stringify(value)))
    await this.db.put(store, { id, iv, ct, ...index } satisfies SealedRecord)
  }

  async getJson<T>(store: StoreName, id: string): Promise<T | null> {
    const r = (await this.db.get(store, id)) as SealedRecord | undefined
    if (!r) return null
    return JSON.parse(fromUtf8(await this.unseal(r))) as T
  }

  async allJson<T>(store: StoreName): Promise<T[]> {
    const rows = (await this.db.getAll(store)) as SealedRecord[]
    return Promise.all(rows.map(async (r) => JSON.parse(fromUtf8(await this.unseal(r))) as T))
  }

  async putBytes(store: StoreName, id: string, bytes: Uint8Array) {
    const { iv, ct } = await this.seal(bytes)
    await this.db.put(store, { id, iv, ct } satisfies SealedRecord)
  }

  async getBytes(store: StoreName, id: string): Promise<Uint8Array | null> {
    const r = (await this.db.get(store, id)) as SealedRecord | undefined
    return r ? this.unseal(r) : null
  }

  async delete(store: StoreName, id: string) {
    await this.db.delete(store, id)
  }

  /** Messages of one conversation, oldest first, at most `limit` of the newest. */
  async messagesOf<T>(convId: string, limit = 500): Promise<T[]> {
    const range = IDBKeyRange.bound([convId, -Infinity], [convId, Infinity])
    const rows: SealedRecord[] = []
    let cursor = await this.db.transaction('messages').store.index('conv').openCursor(range, 'prev')
    while (cursor && rows.length < limit) {
      rows.push(cursor.value as SealedRecord)
      cursor = await cursor.continue()
    }
    rows.reverse()
    return Promise.all(rows.map(async (r) => JSON.parse(fromUtf8(await this.unseal(r))) as T))
  }

  async deleteConversationMessages(convId: string) {
    const range = IDBKeyRange.bound([convId, -Infinity], [convId, Infinity])
    const tx = this.db.transaction('messages', 'readwrite')
    let cursor = await tx.store.index('conv').openCursor(range)
    while (cursor) {
      await cursor.delete()
      cursor = await cursor.continue()
    }
    await tx.done
  }

  close() {
    this.db.close()
  }

  static async wipe(): Promise<void> {
    await new Promise<void>((resolve) => {
      const req = indexedDB.deleteDatabase(Storage.dbName)
      req.onsuccess = req.onerror = req.onblocked = () => resolve()
    })
  }
}
