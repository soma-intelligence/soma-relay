// Relay: the client runtime. Owns the engine, storage, transports and calls, and exposes an
// immutable snapshot for React (useSyncExternalStore).
//
// Router (spec section 6): an open WebRTC data channel first, then the node, then the local
// test bus, else the outbox (dashed "en route" bubbles) flushed when a transport comes back.

import type { AppMessage, Attachment, CallSignal, Contact, Engine, EngineFactory, GeoPoint, Group, Inbound, LinkPreview, PollSpec, ProfileWire } from '../core/engine'
import { RelayError } from '../core/engine'
import { loadEngineFactory } from '../core/loadEngine'
import { Storage } from '../lib/storage'
import { localGet, localSet, PROFILE } from '../lib/profile'
import { sha3_256 } from '@noble/hashes/sha3.js'
import { buf, fpShort, fromB64, randomBytes, sha256, toB64, toB64Url, toHex, utf8, uuidv7 } from '../lib/bytes'
import { avatarDataUrl, avatarHash, checkAvatar } from '../lib/avatar'
import { getVault, NodeClient, resolveNodeUrl, type NodeEvent } from '../net/nodeClient'
import { assertPasskey, PasskeyError, prfAvailable, registerPasskey, setPrfSalts } from '../net/passkey'
import {
  PasskeyRestoreError,
  RESTORED_TOAST,
  RETRYABLE,
  VAULT_DEBOUNCE_MS,
  VAULT_OFF,
  refusedMessage,
  statusOf,
  type VaultRecord,
  type VaultStatus,
} from './vaultSync'
import { LocalBus } from '../net/localBus'
import { isDataChannelSignal, P2P } from '../net/p2p'
import { CallManager, type CallEndInfo } from '../calls/callManager'
import type { PreparedMedia } from '../media/media'
import type { ChatKind, ChatMessage, Conversation, NodeState, OutboxItem, Settings, Status, Transport } from './types'
import { MUTE_ALWAYS } from './types'
import { cleanExpire, cleanGeo, cleanLink, cleanPoll, cleanStrings } from './sanitize'
import { pushSubscription, registerSW, swSupported } from '../net/push'

/** Shortest passphrase for a new `.relaykey` export (`EXPORT_MIN_PASSPHRASE` in relay-core). */
export const EXPORT_MIN_PASSPHRASE = 10

/** True when a backup text is a sealed `.relaykey`, which needs the passphrase field. */
export const needsPassphrase = (text: string): boolean => text.trim().startsWith('relaystate2:')

export interface Me {
  name: string
  fingerprint: string
  mailbox: string
  words: string[]
}

/** A photo and name received from a contact or a group admin, or my own (id 'me'). */
export interface PeerProfile {
  /** Fingerprint, 'g:' + group id, or 'me'. */
  id: string
  name?: string
  /** Base64 JPEG, 256 px. */
  avatar?: string
  /** Hex SHA-256 of the JPEG bytes. */
  hash?: string
  ts: number
}

/** The in-app banner for a message in another conversation than the open one. */
export interface Banner {
  seq: number
  convId: string
  msgId: string
  /** Avatar id: the sender for direct chats, the group otherwise. */
  avatarId: string
  title: string
  text: string
}

export interface Snapshot {
  phase: 'loading' | 'onboarding' | 'ready' | 'error'
  error: string | null
  engineKind: 'wasm' | 'mock' | null
  profile: string
  me: Me | null
  contacts: Contact[]
  groups: Group[]
  conversations: Conversation[]
  messages: Record<string, ChatMessage[]>
  activeConv: string | null
  node: NodeState
  nodeBase: string
  localBus: boolean
  online: Set<string>
  p2pOpen: Set<string>
  typing: Record<string, number>
  settings: Settings
  outboxCount: number
  toast: { id: number; text: string } | null
  /** A message to scroll to when its conversation opens (search results, notifications). */
  jump: { convId: string; id: string } | null
  /** My live location messages being shared right now. */
  liveShares: Set<string>
  /** Photos and names by fingerprint, 'g:' + group id, and 'me'. */
  profiles: Record<string, PeerProfile>
  banner: Banner | null
  /** Passkey backup (Settings > Sécurité). */
  vault: VaultStatus
}

const INLINE_MAX = 48 * 1024
const P2P_ACK_MS = 5000
const RANK: Record<Status, number> = { failed: 0, pending: 1, sent: 2, delivered: 3, read: 4 }

const BUS_PARAM = new URLSearchParams(location.search).get('bus')
/** The local test bus can be offered in the UI (dev server, or ?bus=1). */
export const LOCAL_BUS_AVAILABLE = import.meta.env.DEV || BUS_PARAM === '1'

const DEFAULT_SETTINGS: Settings = {
  nodeUrl: '',
  handle: '',
  localBus: false,
  p2p: true,
  linkPreviews: true,
  notifications: true,
  notifPreviews: true,
}

/** Kinds that become a bubble. Anything else unknown is ignored (spec v1.1). */
const BUBBLE_KINDS = new Set<string>(['text', 'image', 'audio', 'video', 'file', 'poll', 'location'])
const EDIT_WINDOW_MS = 24 * 3600_000

export function expireLabel(s: number): string {
  switch (s) {
    case 300:
      return '5 minutes'
    case 3600:
      return '1 heure'
    case 86400:
      return '1 jour'
    case 604800:
      return '1 semaine'
    default:
      return 'désactivé'
  }
}

export function convIdFor(inbound: { from: string; group?: string }): string {
  return inbound.group ? `g:${inbound.group}` : inbound.from
}

export function previewOf(m: Pick<ChatMessage, 'kind' | 'text' | 'poll' | 'location' | 'attachment' | 'deleted'>): string {
  if (m.deleted) return 'Message supprimé'
  switch (m.kind) {
    case 'image':
      return 'Photo'
    case 'audio':
      return 'Note vocale'
    case 'video':
      return 'Vidéo'
    case 'file':
      return `Document : ${m.attachment?.name ?? m.text ?? 'fichier'}`
    case 'call':
      return m.text || 'Appel'
    case 'poll':
      return `Sondage : ${m.poll?.question ?? ''}`
    case 'location':
      return m.location?.live_until ? 'Position en direct' : 'Position'
    default:
      return m.text ?? ''
  }
}

function haversine(a: { lat: number; lon: number }, b: { lat: number; lon: number }): number {
  const r = (x: number) => (x * Math.PI) / 180
  const dLat = r(b.lat - a.lat)
  const dLon = r(b.lon - a.lon)
  const h = Math.sin(dLat / 2) ** 2 + Math.cos(r(a.lat)) * Math.cos(r(b.lat)) * Math.sin(dLon / 2) ** 2
  return 2 * 6_371_000 * Math.asin(Math.sqrt(h))
}

/** Wire form of a stored message, for retries and forwards. */
function toApp(m: ChatMessage): AppMessage {
  const app: AppMessage = { id: m.id, ts: m.ts, kind: m.kind as AppMessage['kind'] }
  if (m.text !== undefined) app.text = m.text
  if (m.replyTo) app.reply_to = m.replyTo
  if (m.attachment) app.attachment = m.attachment
  if (m.poll) app.poll = m.poll
  if (m.location) app.location = m.location
  if (m.link) app.link = m.link
  if (m.forwarded) app.forwarded = true
  if (m.mentions) app.mentions = m.mentions
  if (m.expireS) app.expire_s = m.expireS
  return app
}

export class Relay {
  private listeners = new Set<() => void>()
  private snap: Snapshot
  private factory: EngineFactory | null = null
  private engine: Engine | null = null
  private store: Storage | null = null
  private node: NodeClient | null = null
  private bus: LocalBus | null = null
  readonly p2p: P2P
  readonly calls: CallManager
  private saveTimer: ReturnType<typeof setTimeout> | null = null
  private presenceTimer: ReturnType<typeof setInterval> | null = null
  private outbox: OutboxItem[] = []
  /** node envelope id -> our message id, to mark messages sent when the node confirms. */
  private inflight = new Map<string, string>()
  /**
   * Messages handed to a P2P data channel. A channel can still look open for a few seconds after
   * the other tab closed or lost its network, and whatever goes in then is lost. Each one waits
   * here for its delivery receipt; without one after P2P_ACK_MS it goes again through the node
   * (the core drops the copy if the first one did arrive).
   */
  private p2pPending = new Map<string, { env: Uint8Array; fp: string; mailbox: string; convId?: string; at: number }>()
  private lastTypingSent = new Map<string, number>()
  private mediaUrls = new Map<string, string>()
  private mediaLoading = new Map<string, Promise<string | null>>()
  private toastSeq = 0
  private iceCache: { at: number; servers: RTCIceServer[] } | null = null

  constructor() {
    const settings = { ...DEFAULT_SETTINGS, ...(JSON.parse(localGet('settings') ?? '{}') as Partial<Settings>) }
    this.snap = {
      phase: 'loading',
      error: null,
      engineKind: null,
      profile: PROFILE,
      me: null,
      contacts: [],
      groups: [],
      conversations: [],
      messages: {},
      activeConv: null,
      node: 'off',
      nodeBase: '',
      localBus: false,
      online: new Set(),
      p2pOpen: new Set(),
      typing: {},
      settings,
      outboxCount: 0,
      toast: null,
      jump: null,
      liveShares: new Set(),
      profiles: {},
      banner: null,
      vault: VAULT_OFF,
    }
    this.p2p = new P2P(
      () => this.engine?.fingerprintHex() ?? '',
      (fp, s) => this.sendSignal(fp, s),
      (fp, env) => this.ingest(env, 'p2p', fp),
      () => this.ice(),
      () => this.set({ p2pOpen: new Set(this.p2p.openPeers()) }),
    )
    this.calls = new CallManager(
      (fp, s) => this.sendSignal(fp, s),
      (fp, id) => this.engine!.callKey(fp, id),
      () => this.ice(true),
      (info) => void this.logCall(info),
    )
    document.addEventListener('visibilitychange', () => {
      if (document.visibilityState === 'visible' && this.snap.activeConv) void this.markRead(this.snap.activeConv)
      // Going to the background: the backup goes now, not 10 s later.
      if (document.visibilityState === 'hidden') void this.flushVault()
    })
    // A click on a notification asks this window to open the conversation.
    if (swSupported())
      navigator.serviceWorker.addEventListener('message', (e: MessageEvent) => {
        const d = e.data as { t?: string; conv?: string } | null
        if (d?.t === 'open' && typeof d.conv === 'string') void this.openConversation(d.conv)
      })
    setInterval(() => void this.sweepExpired(), 5000)
    setInterval(() => this.retryP2p(), 1000)
    // Close the data channels at once, so peers stop sending into them and use the node.
    window.addEventListener('pagehide', () => this.p2p.closeAll())
  }

  /** Sends again through the node (or the outbox) what a P2P channel did not confirm. */
  private retryP2p() {
    const now = Date.now()
    const stale = new Set<string>()
    for (const [msgId, p] of this.p2pPending) {
      if (now - p.at < P2P_ACK_MS) continue
      this.p2pPending.delete(msgId)
      stale.add(p.fp)
      this.route(p.env, { mailbox: p.mailbox }, { msgId, convId: p.convId })
    }
    // A channel that swallowed a message without answering is dead: drop it, the next message
    // reopens one if the peer is still there.
    for (const fp of stale) this.p2p.close(fp, false)
  }

  // Store plumbing

  subscribe = (fn: () => void) => {
    this.listeners.add(fn)
    return () => {
      this.listeners.delete(fn)
    }
  }
  getSnapshot = () => this.snap
  private set(patch: Partial<Snapshot>) {
    this.snap = { ...this.snap, ...patch }
    this.listeners.forEach((l) => l())
  }

  toast(text: string) {
    const id = ++this.toastSeq
    this.set({ toast: { id, text } })
    setTimeout(() => {
      if (this.snap.toast?.id === id) this.set({ toast: null })
    }, 3200)
  }

  get engineOrThrow(): Engine {
    if (!this.engine) throw new Error('no identity')
    return this.engine
  }

  // Boot

  async init() {
    try {
      this.store = await Storage.open()
      this.factory = await loadEngineFactory()
      const settings = this.snap.settings
      // The local bus between tabs is a test transport. Production builds keep it off unless
      // the page is opened with ?bus=1; the dev server turns it on by default (no node there).
      if (BUS_PARAM === '1') settings.localBus = true
      else if (BUS_PARAM === '0' || !import.meta.env.DEV) settings.localBus = false
      else if (localGet('settings') === null) settings.localBus = true
      this.set({ engineKind: this.factory.kind, settings: { ...settings } })
      const state = await this.store.getBytes('meta', 'engine')
      if (!state) {
        this.set({ phase: 'onboarding' })
        return
      }
      this.engine = this.factory.restore(state)
      await this.afterIdentity()
    } catch (e) {
      console.error(e)
      this.set({ phase: 'error', error: e instanceof Error ? e.message : String(e) })
    }
  }

  async createIdentity(name: string) {
    if (!this.factory || !this.store) return
    this.engine = this.factory.create(name.trim())
    await this.store.putBytes('meta', 'engine', this.engine.exportState())
    await this.afterIdentity()
  }

  /**
   * Restores from a backup text: `.relaykey` (`relaystate1:` clear, `relaystate2:` with
   * `passphrase`) or the older JSON backup of the web client.
   */
  async restoreBackup(text: string, passphrase: string | null = null) {
    if (!this.factory || !this.store) return
    const notBackup = 'Ce fichier n’est pas une sauvegarde Soma Relay.'
    let state: Uint8Array
    if (text.trim().startsWith('relaystate')) {
      const open = this.factory.openExport
      if (!open) throw new Error('Le moteur de test ne lit pas les fichiers .relaykey.')
      // Argon2id takes a moment: let the "Déchiffrement…" state paint first.
      await new Promise((r) => setTimeout(r, 30))
      try {
        state = open(passphrase, text)
      } catch (e) {
        if (e instanceof Error && e.name === 'Passphrase')
          throw new Error(passphrase ? 'Phrase de passe incorrecte.' : 'Ce fichier demande sa phrase de passe.')
        throw new Error(notBackup)
      }
    } else {
      let j: { kind?: string; state?: string }
      try {
        j = JSON.parse(text) as { kind?: string; state?: string }
      } catch {
        throw new Error(notBackup)
      }
      if (j.kind !== 'soma-relay-backup' || !j.state) throw new Error(notBackup)
      state = fromB64(j.state)
    }
    this.engine = this.factory.restore(state)
    await this.store.putBytes('meta', 'engine', this.engine.exportState())
    await this.afterIdentity()
  }

  private async afterIdentity() {
    const e = this.engine!
    e.rotatePrekeyIfDue(Date.now())
    const convs = await this.store!.allJson<Conversation>('conversations')
    this.outbox = await this.store!.allJson<OutboxItem>('outbox')
    const profiles: Record<string, PeerProfile> = {}
    for (const p of await this.store!.allJson<PeerProfile>('profiles')) profiles[p.id] = p
    this.sentProfile = (await this.store!.getJson<Record<string, string>>('meta', 'profile-sent')) ?? {}
    this.renamed = new Set((await this.store!.getJson<string[]>('meta', 'renamed')) ?? [])
    for (const g of e.groups()) this.groupMembers.set(g.id, [...g.members])
    await this.loadVault()
    this.set({
      profiles,
      phase: 'ready',
      me: this.meOf(e),
      contacts: e.contacts(),
      groups: e.groups(),
      conversations: sortConvs(convs),
      outboxCount: this.outbox.length,
    })
    this.persist()
    this.startTransports()
    void this.sweepStored()
    const hash = new URLSearchParams(location.hash.slice(1)).get('conv')
    if (hash && convs.some((c) => c.id === hash)) {
      history.replaceState(history.state, '', location.pathname + location.search)
      void this.openConversation(hash)
    }
  }

  private meOf(e: Engine): Me {
    return { name: e.displayName(), fingerprint: e.fingerprintHex(), mailbox: e.mailboxHex(), words: e.safetyWords() }
  }

  /** Saves the engine state, debounced 300 ms (core-api: after every mutating call). */
  persist() {
    if (this.saveTimer) clearTimeout(this.saveTimer)
    this.saveTimer = setTimeout(() => {
      if (this.engine && this.store) {
        void this.store.putBytes('meta', 'engine', this.engine.exportState()).then(() => this.markVaultDirty())
      }
    }, 300)
  }

  private refreshIdentity() {
    const e = this.engine
    if (!e) return
    this.set({ me: this.meOf(e), contacts: e.contacts(), groups: e.groups() })
    this.persist()
  }

  // Transports

  private startTransports() {
    const e = this.engine!
    const s = this.snap.settings
    this.node?.stop()
    this.node = new NodeClient(s.nodeUrl, e, () => this.myCard(), (ev) => this.onNode(ev))
    this.set({ nodeBase: this.node.base, node: 'connecting' })
    this.node.start()
    this.bus?.close()
    this.bus = s.localBus ? new LocalBus(e.mailboxHex(), (env) => this.ingest(env, 'local')) : null
    this.set({ localBus: !!this.bus })
    if (this.presenceTimer) clearInterval(this.presenceTimer)
    this.presenceTimer = setInterval(() => this.pollPresence(), 15_000)
    setTimeout(() => this.pollPresence(), 1500)
    void this.flushOutbox()
    if (s.notifications && typeof Notification !== 'undefined' && Notification.permission === 'granted') {
      void registerSW()
      void this.subscribePush()
    }
  }

  myCard(): string {
    const s = this.snap.settings
    return this.engineOrThrow.myCard(this.node?.base ?? null, s.handle || null)
  }

  myCompactLink(): string {
    return this.engineOrThrow.myCompactLink(this.node?.base ?? null)
  }

  private onNode(ev: NodeEvent) {
    switch (ev.t) {
      case 'state':
        this.set({ node: ev.state })
        if (ev.state === 'online') {
          void this.retryVaultIfOwed()
          void this.flushOutbox()
          this.pollPresence()
        }
        break
      case 'env':
        this.ingest(ev.env, 'net')
        this.node?.ack(ev.id)
        break
      case 'sent': {
        const msgId = this.inflight.get(ev.id)
        this.inflight.delete(ev.id)
        if (msgId) void this.updateStatus([msgId], 'sent', 'net')
        break
      }
      case 'presence':
        this.set({ online: new Set([...ev.online, ...(this.bus?.online(this.contactMailboxes()) ?? [])]) })
        this.maybeP2P()
        break
      case 'error':
        if (ev.id && this.inflight.has(ev.id)) {
          const msgId = this.inflight.get(ev.id)!
          this.inflight.delete(ev.id)
          void this.updateStatus([msgId], 'failed')
          this.toast(ev.code === 'quota' ? 'Sa boîte est pleine sur le nœud.' : 'Le nœud a refusé le message.')
        } else if (ev.code !== 'auth_required') console.warn('node error', ev)
        break
    }
  }

  private contactMailboxes(): string[] {
    return this.snap.contacts.map((c) => c.mailbox)
  }

  private pollPresence() {
    const mbs = this.contactMailboxes()
    if (this.node?.isReady) this.node.presence(mbs)
    else if (this.bus) {
      this.set({ online: new Set(this.bus.online(mbs)) })
      this.maybeP2P()
    }
  }

  /** Opens a data channel to the peer of the open conversation when it is online. */
  private maybeP2P() {
    if (!this.snap.settings.p2p) return
    const conv = this.snap.activeConv
    if (!conv || conv.startsWith('g:')) return
    const c = this.snap.contacts.find((x) => x.fingerprint === conv)
    if (c && this.snap.online.has(c.mailbox) && !this.p2p.isOpen(conv)) void this.p2p.connect(conv)
  }

  /** ICE servers from the node. Calls pass `fresh` so short-lived TURN credentials are new. */
  async ice(fresh = false): Promise<RTCIceServer[]> {
    if (!fresh && this.iceCache && Date.now() - this.iceCache.at < 10 * 60_000) return this.iceCache.servers
    let servers = (await this.node?.iceServers()) ?? []
    if (!servers.length) servers = [{ urls: 'stun:stun.cloudflare.com:3478' }]
    this.iceCache = { at: Date.now(), servers }
    return servers
  }

  /** Sends one envelope. Returns the transport used, or null when it was queued. */
  private route(
    env: Uint8Array,
    target: { fp?: string; mailbox: string },
    meta?: { msgId?: string; convId?: string; queue?: boolean; ack?: boolean },
  ): Transport | null {
    if (target.fp && this.p2p.send(target.fp, env)) {
      if (meta?.msgId && meta.ack) this.p2pPending.set(meta.msgId, { env, fp: target.fp, mailbox: target.mailbox, convId: meta.convId, at: Date.now() })
      return 'p2p'
    }
    if (this.node?.isReady) {
      const id = this.engine!.envelopeHeader(env)?.id
      if (id && meta?.msgId) this.inflight.set(id, meta.msgId)
      if (this.node.send(target.mailbox, env)) return 'net'
    }
    if (this.bus && this.bus.send(target.mailbox, env)) return 'local'
    if (meta?.queue !== false) {
      const item: OutboxItem = {
        id: uuidv7(),
        to: target.mailbox,
        env: toB64Url(env),
        msgId: meta?.msgId,
        convId: meta?.convId,
        ts: Date.now(),
      }
      this.outbox.push(item)
      void this.store?.putJson('outbox', item.id, item)
      this.set({ outboxCount: this.outbox.length })
    }
    return null
  }

  private async flushOutbox() {
    if (!this.outbox.length) return
    if (!this.node?.isReady && !this.bus) return
    const items = [...this.outbox]
    for (const item of items) {
      const env = fromB64(item.env)
      const fp = this.snap.contacts.find((c) => c.mailbox === item.to)?.fingerprint
      let via: Transport | null = null
      if (fp && this.p2p.send(fp, env)) via = 'p2p'
      else if (this.node?.isReady) {
        const id = this.engine!.envelopeHeader(env)?.id
        if (id && item.msgId) this.inflight.set(id, item.msgId)
        if (this.node.send(item.to, env)) via = 'net'
      } else if (this.bus?.send(item.to, env)) via = 'local'
      if (!via) break
      this.outbox = this.outbox.filter((x) => x.id !== item.id)
      await this.store?.delete('outbox', item.id)
      if (item.msgId && via !== 'net') await this.updateStatus([item.msgId], 'sent', via)
    }
    this.set({ outboxCount: this.outbox.length })
  }

  private sendSignal(fp: string, s: CallSignal) {
    const c = this.snap.contacts.find((x) => x.fingerprint === fp)
    if (!c || !this.engine) return
    const msg: AppMessage = { id: uuidv7(), ts: Date.now(), kind: 'call', call: s }
    try {
      const env = this.engine.encryptFor(fp, msg)
      this.persist()
      // Data channel signalling must not travel over the data channel it is setting up.
      if (isDataChannelSignal(s)) {
        if (this.node?.isReady) this.node.send(c.mailbox, env)
        else this.bus?.send(c.mailbox, env)
      } else this.route(env, { fp, mailbox: c.mailbox }, { queue: false })
    } catch (e) {
      console.warn('signal failed', e)
    }
  }

  // Inbound

  private ingest(env: Uint8Array, via: Transport, _fromFp?: string) {
    const e = this.engine
    if (!e) return
    let inbound: Inbound | null
    try {
      inbound = e.open(env, Date.now())
    } catch (err) {
      if (err instanceof RelayError && err.code === 'NoSession' && this.isGroupEnvelope(env)) this.holdGroup(env, via)
      else if (!(err instanceof RelayError) || err.code !== 'Malformed') console.warn('open failed', err)
      return
    }
    this.persist()
    if (!inbound) {
      // A group envelope may arrive before its sender key: keep it and retry later.
      if (this.isGroupEnvelope(env)) this.holdGroup(env, via)
      return
    }
    const knownBefore = this.snap.contacts.some((c) => c.fingerprint === inbound!.from)
    if (!knownBefore || inbound.group || inbound.message.kind === 'group-op')
      this.set({ contacts: e.contacts(), groups: e.groups() })
    void this.dispatch(inbound, via)
    this.retryHeld()
  }

  /** Group envelopes waiting for their sender key (relay-core: not marked seen, retry). */
  private held: { env: Uint8Array; via: Transport; at: number }[] = []

  private isGroupEnvelope(env: Uint8Array): boolean {
    return this.engine?.envelopeHeader(env)?.kind === 2
  }

  private holdGroup(env: Uint8Array, via: Transport) {
    const now = Date.now()
    this.held = this.held.filter((h) => now - h.at < 24 * 3600_000).slice(-199)
    this.held.push({ env, via, at: now })
  }

  private retrying = false
  private retryHeld() {
    if (this.retrying || !this.held.length) return
    this.retrying = true
    try {
      let progress = true
      while (progress && this.held.length) {
        progress = false
        for (const h of [...this.held]) {
          let inb: Inbound | null = null
          try {
            inb = this.engine!.open(h.env, Date.now())
          } catch {
            continue
          }
          if (!inb) continue
          this.held = this.held.filter((x) => x !== h)
          progress = true
          this.persist()
          this.set({ contacts: this.engine!.contacts(), groups: this.engine!.groups() })
          void this.dispatch(inb, h.via)
        }
      }
    } finally {
      this.retrying = false
    }
  }

  private async dispatch(inb: Inbound, via: Transport) {
    const m = inb.message
    const opGroup = m.kind === 'group-op' ? (m.group as { id?: string } | undefined)?.id : undefined
    const convId = convIdFor(inb.group || !opGroup ? inb : { from: inb.from, group: opGroup })
    switch (m.kind) {
      case 'receipt':
        if (m.receipt) await this.updateStatus(m.receipt.of, m.receipt.state)
        return
      case 'typing':
        this.set({ typing: { ...this.snap.typing, [convId + '|' + inb.from]: Date.now() + 6000 } })
        return
      case 'call':
        if (!m.call) return
        if (isDataChannelSignal(m.call)) await this.p2p.handleSignal(inb.from, m.call)
        else await this.calls.handleSignal(inb.from, m.call)
        return
      case 'reaction':
        if (m.reply_to) await this.applyReaction(convId, m.reply_to, m.text ?? '', inb.from)
        return
      case 'group-op': {
        this.set({ groups: this.engine!.groups() })
        if (!convId.startsWith('g:')) return
        const ev = (m.group as { event?: string; name?: string } | undefined)?.event
        const known = this.snap.conversations.some((c) => c.id === convId)
        if (ev === 'removed') {
          await this.addSystem(convId, 'Tu as été retiré du groupe.')
          this.groupMembers.delete(convId.slice(2))
        } else if (!known) {
          await this.addSystem(convId, `${this.nameOf(inb.from)} t’a ajouté au groupe.`)
          await this.syncMembers(convId.slice(2), false)
          // Spec 6: my profile goes into a group when I am added to it.
          this.ensureProfile(convId)
        } else await this.syncMembers(convId.slice(2), true)
        return
      }
      case 'profile':
        await this.applyProfile(inb.from, m.profile)
        return
      case 'group-profile':
        if (inb.group) await this.applyGroupProfile(inb.group, inb.from, m.group_profile)
        return
      case 'group-leave':
        if (inb.group) await this.applyGroupLeave(inb.group, inb.from)
        return
      case 'edit':
        await this.applyEdit(convId, inb.from, m)
        return
      case 'delete':
        if (m.reply_to) await this.applyDelete(convId, inb.from, m.reply_to)
        return
      case 'poll-vote':
        await this.applyVote(convId, inb.from, m)
        return
      case 'location-update':
        await this.applyLocationUpdate(convId, inb.from, m)
        return
      case 'settings':
        await this.applyConvSettings(convId, inb.from, m)
        return
    }
    if (!BUBBLE_KINDS.has(m.kind)) return
    const msg = this.toChat(m, convId, inb.from, 'delivered', via)
    if (!msg) return
    const typing = { ...this.snap.typing }
    delete typing[convId + '|' + inb.from]
    this.set({ typing })
    if (this.findMessage(convId, msg.id)) return
    const active = this.snap.activeConv === convId && document.visibilityState === 'visible'
    msg.times = { received: Date.now() }
    if (active && msg.expireS) msg.expireAt = Date.now() + msg.expireS * 1000
    await this.saveMessage(msg)
    await this.touchConv(convId, {
      preview: previewOf(msg),
      ts: m.ts,
      transport: via,
      unread: active ? 0 : 1,
      hadExpiring: !!msg.expireS,
    })
    if (!inb.group) this.sendReceipt(inb.from, [m.id], active ? 'read' : 'delivered')
    if (active) await this.updateStatus([m.id], 'read')
    const me = this.engine?.fingerprintHex()
    const mention = !!me && !!msg.mentions?.includes(me)
    this.notify(convId, msg, mention)
    this.showBanner(convId, msg, mention)
    // Spec 6: a new contact gets my profile after the first message received from them.
    this.ensureProfile(convId)
    // Small media downloads right away, so they show without a tap.
    if (m.attachment && m.attachment.size < 8 * 1024 * 1024 && msg.kind !== 'file') void this.mediaUrl(msg)
  }

  /** Validated ChatMessage of a wire message, or null when it is not displayable. */
  private toChat(m: AppMessage, convId: string, from: string, status: Status, via?: Transport): ChatMessage | null {
    const kind = m.kind as ChatKind
    const msg: ChatMessage = {
      id: m.id,
      convId,
      from,
      ts: m.ts,
      kind,
      text: typeof m.text === 'string' ? m.text.slice(0, 65_536) : undefined,
      replyTo: typeof m.reply_to === 'string' ? m.reply_to : undefined,
      attachment: m.attachment,
      status,
      transport: via,
    }
    if (kind === 'poll') {
      msg.poll = cleanPoll(m.poll)
      if (!msg.poll) return null
    }
    if (kind === 'location') {
      msg.location = cleanGeo(m.location)
      if (!msg.location) return null
      msg.locationTs = m.ts
    }
    if (kind !== 'text' && kind !== 'poll' && kind !== 'location' && !m.attachment) return null
    const link = cleanLink(m.link)
    if (link) msg.link = link
    if (m.forwarded === true) msg.forwarded = true
    const mentions = cleanStrings(m.mentions, 64, 64)
    if (mentions) msg.mentions = mentions
    const exp = cleanExpire(m.expire_s)
    if (exp) msg.expireS = exp
    return msg
  }

  /** Body of a notification, following the spec text rules. */
  private notifyBody(convId: string, m: ChatMessage): string {
    const body = previewOf(m)
    return convId.startsWith('g:') && m.from !== 'me' ? `${this.nameOf(m.from)} : ${body}` : body
  }

  private notify(convId: string, m: ChatMessage, mention: boolean) {
    if (document.visibilityState === 'visible') return
    if (!this.snap.settings.notifications) return
    if (typeof Notification === 'undefined' || Notification.permission !== 'granted') return
    const conv = this.snap.conversations.find((c) => c.id === convId)
    if (conv?.mutedUntil && conv.mutedUntil > Date.now() && !mention) return
    const previews = this.snap.settings.notifPreviews
    const title = previews ? this.titleOf(convId) : 'Soma Relay'
    const body = previews ? this.notifyBody(convId, m) : 'Nouveau message'
    const face = previews ? (this.avatarUrl(convId.startsWith('g:') ? convId : m.from) ?? this.avatarUrl(convId)) : undefined
    const opts: NotificationOptions = { body, tag: convId, icon: face ?? '/icon-512.png', data: { conv: convId, url: location.href } }
    const fallback = () => {
      try {
        const n = new Notification(title, opts)
        n.onclick = () => {
          window.focus()
          void this.openConversation(convId)
          n.close()
        }
      } catch {
        /* not allowed */
      }
    }
    if (swSupported())
      void registerSW().then((reg) => (reg ? reg.showNotification(title, opts).catch(fallback) : fallback()))
    else fallback()
  }

  // Notifications and push

  /** Turns notifications on: asks the browser permission (call only from a click). */
  async enableNotifications(): Promise<boolean> {
    if (typeof Notification === 'undefined') {
      this.toast('Ce navigateur ne gère pas les notifications.')
      return false
    }
    const perm = Notification.permission === 'granted' ? 'granted' : await Notification.requestPermission()
    if (perm !== 'granted') {
      this.toast('Notifications refusées par le navigateur. Autorise-les dans les réglages du site.')
      await this.updateSettings({ notifications: false })
      return false
    }
    await this.updateSettings({ notifications: true })
    await registerSW()
    const ok = await this.subscribePush()
    this.toast(ok ? 'Notifications activées, même onglet fermé.' : 'Notifications activées quand l’onglet est ouvert.')
    return true
  }

  async disableNotifications() {
    await this.updateSettings({ notifications: false })
    this.node?.setPush({ t: 'push', kind: 'none' })
  }

  /** Web Push through the node, when it publishes a VAPID key. */
  private async subscribePush(): Promise<boolean> {
    const node = this.node
    if (!node) return false
    const key = await node.vapidKey()
    if (!key) return false
    const sub = await pushSubscription(key)
    if (!sub || node !== this.node) return false
    node.setPush({ t: 'push', kind: 'webpush', sub })
    return true
  }

  private sendReceipt(fp: string, ids: string[], state: 'delivered' | 'read') {
    const c = this.snap.contacts.find((x) => x.fingerprint === fp)
    if (!c || !ids.length) return
    const msg: AppMessage = { id: uuidv7(), ts: Date.now(), kind: 'receipt', receipt: { of: ids, state } }
    try {
      const env = this.engine!.encryptFor(fp, msg)
      this.persist()
      this.route(env, { fp, mailbox: c.mailbox }, {})
    } catch {
      /* no session yet */
    }
  }

  // Conversations and messages

  titleOf(convId: string): string {
    if (convId.startsWith('g:'))
      return this.snap.profiles[convId]?.name ?? this.snap.groups.find((g) => g.id === convId.slice(2))?.name ?? 'Groupe'
    return this.snap.contacts.find((c) => c.fingerprint === convId)?.name ?? this.snap.profiles[convId]?.name ?? 'Inconnu'
  }

  /** Name of a person: contact name, else the name of their profile, else a short fingerprint. */
  nameOf(fp: string): string {
    if (fp === 'me' || fp === this.snap.me?.fingerprint) return this.snap.me?.name ?? 'Toi'
    return this.snap.contacts.find((c) => c.fingerprint === fp)?.name ?? this.snap.profiles[fp]?.name ?? fpShort(fp)
  }

  /** Photo of a person ('me' or fingerprint) or of a group ('g:' + id), as a data URL. */
  avatarUrl(id: string): string | undefined {
    const key = id === this.snap.me?.fingerprint ? 'me' : id
    const a = this.snap.profiles[key]?.avatar
    return a ? avatarDataUrl(a) : undefined
  }

  private findMessage(convId: string, id: string): ChatMessage | undefined {
    return this.snap.messages[convId]?.find((m) => m.id === id)
  }

  private async saveMessage(msg: ChatMessage) {
    const list = this.snap.messages[msg.convId] ?? (await this.loadMessages(msg.convId))
    const next = [...list.filter((m) => m.id !== msg.id), msg].sort((a, b) => a.ts - b.ts)
    this.set({ messages: { ...this.snap.messages, [msg.convId]: next } })
    await this.store?.putJson('messages', msg.id, msg, { convId: msg.convId, ts: msg.ts })
  }

  async loadMessages(convId: string): Promise<ChatMessage[]> {
    if (this.snap.messages[convId]) return this.snap.messages[convId]
    const list = (await this.store?.messagesOf<ChatMessage>(convId)) ?? []
    this.set({ messages: { ...this.snap.messages, [convId]: list } })
    return list
  }

  private async touchConv(
    convId: string,
    p: { preview: string; ts: number; transport?: Transport; unread?: number; hadExpiring?: boolean },
  ) {
    const existing = this.snap.conversations.find((c) => c.id === convId)
    const conv: Conversation = {
      ...existing,
      id: convId,
      kind: convId.startsWith('g:') ? 'group' : 'direct',
      title: this.titleOf(convId),
      lastTs: Math.max(existing?.lastTs ?? 0, p.ts),
      preview: p.preview,
      unread: (existing?.unread ?? 0) + (p.unread ?? 0),
      transport: p.transport ?? existing?.transport,
      draft: existing?.draft,
      hadExpiring: existing?.hadExpiring || p.hadExpiring || undefined,
    }
    this.set({ conversations: sortConvs([...this.snap.conversations.filter((c) => c.id !== convId), conv]) })
    await this.store?.putJson('conversations', convId, conv)
  }

  async openConversation(convId: string | null) {
    this.set({ activeConv: convId, banner: this.snap.banner?.convId === convId ? null : this.snap.banner })
    if (!convId) return
    if (!this.snap.conversations.some((c) => c.id === convId)) {
      // A new conversation shows up in the list only once a message exists.
    }
    await this.loadMessages(convId)
    await this.markRead(convId)
    this.maybeP2P()
  }

  private async markRead(convId: string) {
    if (document.visibilityState !== 'visible') return
    const conv = this.snap.conversations.find((c) => c.id === convId)
    if (conv && conv.unread) {
      const next = { ...conv, unread: 0 }
      this.set({ conversations: this.snap.conversations.map((c) => (c.id === convId ? next : c)) })
      await this.store?.putJson('conversations', convId, next)
    }
    const list = this.snap.messages[convId] ?? []
    const unread = list.filter((m) => m.from !== 'me' && m.status !== 'read' && m.kind !== 'system' && m.kind !== 'call')
    if (!unread.length) return
    if (!convId.startsWith('g:')) this.sendReceipt(convId, unread.map((m) => m.id), 'read')
    await this.updateStatus(unread.map((m) => m.id), 'read')
    // Disappearing messages start their timer when first seen.
    const now = Date.now()
    for (const m of unread) if (m.expireS && !m.expireAt) await this.patchMessage(m.id, convId, { expireAt: now + m.expireS * 1000 })
  }

  private async updateStatus(ids: string[], status: Status, transport?: Transport) {
    if (status === 'delivered' || status === 'read') for (const id of ids) this.p2pPending.delete(id)
    const set = new Set(ids)
    const messages = { ...this.snap.messages }
    const changed: ChatMessage[] = []
    for (const [conv, list] of Object.entries(messages)) {
      if (!list.some((m) => set.has(m.id))) continue
      messages[conv] = list.map((m) => {
        if (!set.has(m.id)) return m
        if (status !== 'failed' && RANK[m.status] >= RANK[status]) return m
        const next = { ...m, status, transport: transport ?? m.transport, times: { ...m.times, [status]: Date.now() } }
        changed.push(next)
        return next
      })
    }
    if (!changed.length) {
      // Messages of conversations not loaded yet: update them in storage.
      for (const id of ids) {
        const m = await this.store?.getJson<ChatMessage>('messages', id)
        if (m && (status === 'failed' || RANK[m.status] < RANK[status])) {
          await this.store?.putJson('messages', id, { ...m, status }, { convId: m.convId, ts: m.ts })
        }
      }
      return
    }
    this.set({ messages })
    for (const m of changed) await this.store?.putJson('messages', m.id, m, { convId: m.convId, ts: m.ts })
  }

  async setDraft(convId: string, draft: string) {
    const conv = this.snap.conversations.find((c) => c.id === convId)
    if (!conv || conv.draft === draft) return
    const next = { ...conv, draft }
    this.set({ conversations: this.snap.conversations.map((c) => (c.id === convId ? next : c)) })
    await this.store?.putJson('conversations', convId, next)
  }

  // Sending

  /** Encrypts and routes one AppMessage to a conversation. Returns the transport used. */
  private deliver(convId: string, msg: AppMessage, queue = true): Transport | null {
    const e = this.engineOrThrow
    if (convId.startsWith('g:')) {
      const gid = convId.slice(2)
      const g = e.groups().find((x) => x.id === gid)
      if (!g) throw new Error('Groupe introuvable.')
      const envs = e.groupEncrypt(gid, msg)
      this.persist()
      return this.fanout(g, envs, { msgId: msg.id, convId, queue })
    }
    const c = this.snap.contacts.find((x) => x.fingerprint === convId)
    if (!c) throw new Error('Contact introuvable.')
    const env = e.encryptFor(convId, msg)
    this.persist()
    // Only bubbles get a delivery receipt, so only they can wait for one on the P2P path.
    return this.route(env, { fp: convId, mailbox: c.mailbox }, { msgId: msg.id, convId, queue, ack: BUBBLE_KINDS.has(msg.kind) })
  }

  async sendText(
    convId: string,
    text: string,
    replyTo?: string,
    extra?: { link?: LinkPreview; mentions?: string[] },
  ) {
    const body = text.trim()
    if (!body) return
    const part: Omit<AppMessage, 'id' | 'ts'> = { kind: 'text', text: body, reply_to: replyTo }
    const link = cleanLink(extra?.link)
    if (link) part.link = link
    if (extra?.mentions?.length) part.mentions = extra.mentions
    await this.sendMessage(convId, part)
  }

  private async sendMessage(convId: string, part: Omit<AppMessage, 'id' | 'ts'>, localMedia?: Uint8Array): Promise<string | null> {
    const conv0 = this.snap.conversations.find((c) => c.id === convId)
    const msg: AppMessage = { id: uuidv7(), ts: Date.now(), ...part }
    if (conv0?.expireS) msg.expire_s = conv0.expireS
    if (msg.reply_to === undefined) delete msg.reply_to
    const chat = this.toChat(msg, convId, 'me', 'pending')
    if (!chat) return null
    if (chat.expireS) chat.expireAt = chat.ts + chat.expireS * 1000
    if (localMedia) {
      await this.store?.putBytes('media', msg.id, localMedia)
      const mime = msg.attachment?.mime ?? 'application/octet-stream'
      this.mediaUrls.set(msg.id, URL.createObjectURL(new Blob([buf(localMedia)], { type: mime })))
    }
    await this.saveMessage(chat)
    let via: Transport | null = null
    try {
      via = this.deliver(convId, msg)
    } catch (e) {
      await this.updateStatus([msg.id], 'failed')
      this.toast(e instanceof Error ? e.message : 'Envoi impossible.')
      return msg.id
    }
    // The node confirms with "sent"; other transports count as sent now.
    if (via && via !== 'net') await this.updateStatus([msg.id], 'sent', via)
    else if (via === 'net') await this.patchMessage(msg.id, convId, { transport: 'net' })
    await this.touchConv(convId, { preview: previewOf(chat), ts: chat.ts, transport: via ?? undefined, hadExpiring: !!chat.expireS })
    const conv = this.snap.conversations.find((c) => c.id === convId)
    if (conv?.draft) await this.setDraft(convId, '')
    return msg.id
  }

  /** Control messages (edit, delete, votes...): best effort, queued when offline. */
  private control(convId: string, part: Omit<AppMessage, 'id' | 'ts'>, queue = true): boolean {
    try {
      this.deliver(convId, { id: uuidv7(), ts: Date.now(), ...part }, queue)
      return true
    } catch (e) {
      console.warn('control message failed', e)
      return false
    }
  }

  private async getMessage(convId: string, id: string): Promise<ChatMessage | undefined> {
    const list = this.snap.messages[convId] ?? (await this.loadMessages(convId))
    return list.find((m) => m.id === id)
  }

  // Edit and delete

  canEdit(m: ChatMessage): boolean {
    return m.from === 'me' && m.kind === 'text' && !m.deleted && Date.now() - m.ts < EDIT_WINDOW_MS
  }

  async editMessage(convId: string, id: string, text: string) {
    const m = await this.getMessage(convId, id)
    const body = text.trim()
    if (!m || !this.canEdit(m) || !body || body === m.text) return
    this.control(convId, { kind: 'edit', reply_to: id, text: body })
    await this.patchMessage(id, convId, { text: body, editedAt: Date.now() })
    await this.refreshPreview(convId)
  }

  private async applyEdit(convId: string, from: string, m: AppMessage) {
    if (!m.reply_to || typeof m.text !== 'string' || !m.text.trim()) return
    const t = await this.getMessage(convId, m.reply_to)
    if (!t || t.from !== from || t.kind !== 'text' || t.deleted) return
    if (m.ts - t.ts > EDIT_WINDOW_MS || (t.editedAt && t.editedAt > m.ts)) return
    await this.patchMessage(t.id, convId, { text: m.text.slice(0, 65_536), editedAt: m.ts })
    await this.refreshPreview(convId)
  }

  async deleteForEveryone(convId: string, id: string) {
    const m = await this.getMessage(convId, id)
    if (!m || m.from !== 'me' || m.deleted) return
    this.control(convId, { kind: 'delete', reply_to: id })
    await this.wipeContent(m)
  }

  private async applyDelete(convId: string, from: string, id: string) {
    const t = await this.getMessage(convId, id)
    if (!t || t.from !== from || t.deleted) return
    await this.wipeContent(t)
  }

  /** "Message supprimé": the bubble stays, its content and media go. */
  private async wipeContent(m: ChatMessage) {
    this.stopLive(m.id, false)
    await this.dropMedia(m.id)
    await this.patchMessage(m.id, m.convId, {
      deleted: true,
      text: undefined,
      attachment: undefined,
      poll: undefined,
      votes: undefined,
      location: undefined,
      link: undefined,
      reactions: undefined,
      mentions: undefined,
    })
    await this.refreshPreview(m.convId)
  }

  private async dropMedia(id: string) {
    const url = this.mediaUrls.get(id)
    if (url) URL.revokeObjectURL(url)
    this.mediaUrls.delete(id)
    await this.store?.delete('media', id)
  }

  /** Removes a message from this device only. */
  async deleteForMe(convId: string, id: string) {
    this.stopLive(id, true)
    await this.dropMedia(id)
    const list = this.snap.messages[convId] ?? []
    this.set({ messages: { ...this.snap.messages, [convId]: list.filter((m) => m.id !== id) } })
    await this.store?.delete('messages', id)
    await this.refreshPreview(convId)
  }

  /** Conversation preview from its newest bubble. */
  private async refreshPreview(convId: string) {
    const conv = this.snap.conversations.find((c) => c.id === convId)
    if (!conv) return
    const list = this.snap.messages[convId] ?? []
    const last = [...list].reverse().find((m) => m.kind !== 'system') ?? list[list.length - 1]
    const next = { ...conv, preview: last ? previewOf(last) : '' }
    if (next.preview === conv.preview) return
    this.set({ conversations: this.snap.conversations.map((c) => (c.id === convId ? next : c)) })
    await this.store?.putJson('conversations', convId, next)
  }

  // Forward

  async forward(fromConv: string, id: string, toConv: string) {
    const m = await this.getMessage(fromConv, id)
    if (!m || m.deleted || m.kind === 'call' || m.kind === 'system') return
    const app = toApp(m)
    const part: Omit<AppMessage, 'id' | 'ts'> = { kind: app.kind, forwarded: true }
    if (app.text !== undefined) part.text = app.text
    if (app.attachment) part.attachment = app.attachment // same key and blob URL, no re-upload
    if (app.link) part.link = app.link
    if (m.kind === 'poll' && m.poll) part.poll = { question: m.poll.question, options: m.poll.options, multi: m.poll.multi }
    if (m.kind === 'location' && m.location) {
      const { live_until: _l, stop: _s, heading: _h, ...pin } = m.location
      part.location = pin
    }
    let plain: Uint8Array | undefined
    if (m.attachment) plain = (await this.store?.getBytes('media', m.id)) ?? undefined
    await this.sendMessage(toConv, part, plain)
  }

  // Polls

  async sendPoll(convId: string, poll: PollSpec) {
    const clean = cleanPoll(poll)
    if (!clean) throw new Error('Il faut une question et au moins deux réponses.')
    await this.sendMessage(convId, { kind: 'poll', poll: clean })
  }

  async vote(convId: string, pollId: string, opts: string[]) {
    const ok = await this.applyVote(convId, 'me', { id: uuidv7(), ts: Date.now(), kind: 'poll-vote', reply_to: pollId, vote: opts })
    if (ok) this.control(convId, { kind: 'poll-vote', reply_to: pollId, vote: opts })
  }

  async closePoll(convId: string, pollId: string) {
    const m = await this.getMessage(convId, pollId)
    if (!m || m.from !== 'me' || m.pollClosed) return
    this.control(convId, { kind: 'poll-vote', reply_to: pollId, vote: [], close: true })
    await this.patchMessage(pollId, convId, { pollClosed: true })
  }

  private async applyVote(convId: string, from: string, m: AppMessage): Promise<boolean> {
    if (!m.reply_to) return false
    const t = await this.getMessage(convId, m.reply_to)
    if (!t || t.kind !== 'poll' || !t.poll || t.deleted) return false
    if (m.close === true) {
      if (t.from === from && !t.pollClosed) await this.patchMessage(t.id, convId, { pollClosed: true })
      return false
    }
    if (t.pollClosed || (t.poll.closes_at && m.ts > t.poll.closes_at)) return false
    const valid = new Set(t.poll.options.map((o) => o.id))
    let opts = [...new Set(cleanStrings(m.vote, 12, 16) ?? [])].filter((o) => valid.has(o))
    if (!t.poll.multi) opts = opts.slice(0, 1)
    const prev = t.votes?.[from]
    if (prev && prev.ts > m.ts) return false
    const votes = { ...t.votes }
    if (opts.length) votes[from] = { opts, ts: m.ts }
    else delete votes[from]
    await this.patchMessage(t.id, convId, { votes })
    return true
  }

  // Location

  async sendLocation(convId: string, point: GeoPoint, liveMs?: number) {
    const location: GeoPoint = { lat: point.lat, lon: point.lon }
    if (point.accuracy_m !== undefined) location.accuracy_m = Math.round(point.accuracy_m)
    if (point.name) location.name = point.name
    if (liveMs) location.live_until = Date.now() + liveMs
    const id = await this.sendMessage(convId, { kind: 'location', location })
    if (id && liveMs) this.startLive(convId, id, location)
  }

  private live = new Map<string, { convId: string; watch: number; timer: ReturnType<typeof setTimeout>; last: { lat: number; lon: number; t: number }; pos?: GeolocationPosition }>()

  private startLive(convId: string, id: string, loc: GeoPoint) {
    if (!('geolocation' in navigator) || !loc.live_until) return
    const until = loc.live_until
    const entry = {
      convId,
      watch: 0,
      timer: setTimeout(() => this.stopLive(id, true), Math.max(0, until - Date.now())),
      last: { lat: loc.lat, lon: loc.lon, t: Date.now() },
      pos: undefined as GeolocationPosition | undefined,
    }
    entry.watch = navigator.geolocation.watchPosition(
      (pos) => {
        entry.pos = pos
        const now = Date.now()
        if (now > until) return this.stopLive(id, true)
        const p = { lat: pos.coords.latitude, lon: pos.coords.longitude }
        if (now - entry.last.t < 10_000 || haversine(entry.last, p) <= 10) return
        entry.last = { ...p, t: now }
        const update: GeoPoint = { ...p, accuracy_m: Math.round(pos.coords.accuracy) }
        if (pos.coords.heading !== null && Number.isFinite(pos.coords.heading)) update.heading = pos.coords.heading
        this.control(convId, { kind: 'location-update', reply_to: id, location: update }, false)
        void this.moveLocal(convId, id, update, now, false)
      },
      () => {
        /* keep the last position */
      },
      { enableHighAccuracy: true, maximumAge: 5000 },
    )
    this.live.set(id, entry)
    this.set({ liveShares: new Set(this.live.keys()) })
  }

  /** Ends a live share of mine. `notify` sends the final `stop: true` update. */
  stopLive(id: string, notify = true) {
    const e = this.live.get(id)
    if (!e) return
    navigator.geolocation.clearWatch(e.watch)
    clearTimeout(e.timer)
    this.live.delete(id)
    this.set({ liveShares: new Set(this.live.keys()) })
    if (!notify) return
    const p = e.pos ? { lat: e.pos.coords.latitude, lon: e.pos.coords.longitude } : { lat: e.last.lat, lon: e.last.lon }
    this.control(e.convId, { kind: 'location-update', reply_to: id, location: { ...p, stop: true } })
    void this.moveLocal(e.convId, id, p, Date.now(), true)
  }

  private async moveLocal(convId: string, id: string, p: GeoPoint, ts: number, stop: boolean) {
    const t = await this.getMessage(convId, id)
    if (!t?.location) return
    await this.patchMessage(id, convId, {
      location: { ...t.location, lat: p.lat, lon: p.lon, accuracy_m: p.accuracy_m ?? t.location.accuracy_m, heading: p.heading },
      locationTs: ts,
      liveStopped: stop || t.liveStopped,
    })
  }

  private async applyLocationUpdate(convId: string, from: string, m: AppMessage) {
    if (!m.reply_to) return
    const p = cleanGeo(m.location)
    const t = await this.getMessage(convId, m.reply_to)
    if (!p || !t?.location?.live_until || t.from !== from || t.liveStopped || t.deleted) return
    if (m.ts > t.location.live_until + 60_000 || (t.locationTs && m.ts < t.locationTs)) return
    await this.moveLocal(convId, t.id, p, m.ts, !!p.stop)
  }

  // Disappearing messages

  async setExpire(convId: string, expireS: number) {
    const s = cleanExpire(expireS) ?? 0
    this.control(convId, { kind: 'settings', settings: { expire_s: s } })
    await this.patchConv(convId, { expireS: s, hadExpiring: true })
    await this.addSystem(convId, `Tu as réglé les messages éphémères : ${expireLabel(s)}.`)
  }

  private async applyConvSettings(convId: string, from: string, m: AppMessage) {
    const raw = m.settings?.expire_s
    if (typeof raw !== 'number') return
    const s = raw === 0 ? 0 : cleanExpire(raw)
    if (s === undefined) return
    const conv = this.snap.conversations.find((c) => c.id === convId)
    if ((conv?.expireS ?? 0) === s) return
    await this.addSystem(convId, `${this.titleOf(from)} a réglé les messages éphémères : ${expireLabel(s)}.`)
    await this.patchConv(convId, { expireS: s, hadExpiring: true })
  }

  async patchConv(convId: string, patch: Partial<Conversation>) {
    const conv = this.snap.conversations.find((c) => c.id === convId)
    if (!conv) return
    const next = { ...conv, ...patch }
    this.set({ conversations: this.snap.conversations.map((c) => (c.id === convId ? next : c)) })
    await this.store?.putJson('conversations', convId, next)
  }

  async setMute(convId: string, hours: number | null) {
    const until = hours === null ? undefined : hours === Infinity ? MUTE_ALWAYS : Date.now() + hours * 3600_000
    await this.patchConv(convId, { mutedUntil: until })
  }

  /** Deletes loaded messages whose timer ran out. */
  private async sweepExpired() {
    const now = Date.now()
    for (const [convId, list] of Object.entries(this.snap.messages)) {
      for (const m of list) if (m.expireAt && m.expireAt <= now) await this.deleteForMe(convId, m.id)
    }
  }

  /** At start: sweeps conversations that ever had a timer, loaded or not. */
  private async sweepStored() {
    const now = Date.now()
    for (const c of this.snap.conversations) {
      if (!c.hadExpiring) continue
      const list = (await this.store?.messagesOf<ChatMessage>(c.id)) ?? []
      for (const m of list) {
        if (!m.expireAt || m.expireAt > now) continue
        await this.store?.delete('messages', m.id)
        await this.store?.delete('media', m.id)
      }
    }
  }

  // Search

  /** Local search over conversation titles and message text. */
  async search(q: string): Promise<{ convId: string; id: string; text: string; ts: number }[]> {
    const n = q.trim().toLowerCase()
    if (n.length < 2) return []
    const hits: { convId: string; id: string; text: string; ts: number }[] = []
    for (const c of this.snap.conversations) {
      const list = this.snap.messages[c.id] ?? (await this.store?.messagesOf<ChatMessage>(c.id)) ?? []
      for (const m of list) {
        const text = m.kind === 'poll' ? m.poll?.question : m.kind === 'file' ? (m.attachment?.name ?? m.text) : m.text
        if (!m.deleted && m.kind !== 'system' && text && text.toLowerCase().includes(n)) hits.push({ convId: c.id, id: m.id, text, ts: m.ts })
      }
    }
    return hits.sort((a, b) => b.ts - a.ts).slice(0, 60)
  }

  /** Asks the chat view of `convId` to scroll to `id` once it shows. */
  setJump(convId: string, id: string) {
    this.set({ jump: { convId, id } })
  }

  clearJump() {
    if (this.snap.jump) this.set({ jump: null })
  }

  // Link previews

  private previews = new Map<string, Promise<LinkPreview | null>>()

  /** Preview of `url` made by the node (sender side only). Cached per URL. */
  linkPreview(url: string): Promise<LinkPreview | null> {
    if (!this.snap.settings.linkPreviews || !this.node) return Promise.resolve(null)
    let p = this.previews.get(url)
    if (!p) {
      p = this.node.preview(url).then((j) => (j ? (cleanLink({ ...j, url: typeof j.url === 'string' ? j.url : url }) ?? null) : null))
      this.previews.set(url, p)
      if (this.previews.size > 50) this.previews.delete(this.previews.keys().next().value!)
    }
    return p
  }

  private async patchMessage(id: string, convId: string, patch: Partial<ChatMessage>) {
    const list = this.snap.messages[convId]
    if (!list) return
    const next = list.map((m) => (m.id === id ? { ...m, ...patch } : m))
    this.set({ messages: { ...this.snap.messages, [convId]: next } })
    const m = next.find((x) => x.id === id)
    if (m) await this.store?.putJson('messages', id, m, { convId, ts: m.ts })
  }

  async retry(convId: string, id: string) {
    const m = this.findMessage(convId, id)
    if (!m || m.from !== 'me') return
    await this.patchMessage(id, convId, { status: 'pending' })
    const app = toApp(m)
    try {
      const via = this.deliver(convId, app)
      if (via && via !== 'net') await this.updateStatus([id], 'sent', via)
    } catch {
      await this.updateStatus([id], 'failed')
    }
  }

  async sendMedia(convId: string, kind: 'image' | 'audio' | 'video' | 'file', media: PreparedMedia, name?: string) {
    const e = this.engineOrThrow
    const sealed = e.sealAttachment(media.bytes)
    const key = sealed.slice(0, 32)
    const sha = sealed.slice(32, 64)
    const ct = sealed.slice(64)
    const att: Attachment = {
      mime: media.mime,
      size: media.bytes.length,
      sha256: toHex(sha),
      key: toB64(key),
      name,
      width: media.width,
      height: media.height,
      duration_ms: media.duration_ms,
      thumb: media.thumb,
    }
    if (ct.length <= INLINE_MAX) att.inline = toB64(ct)
    else if (this.node?.isReady) {
      try {
        att.url = await this.node.putBlob(toHex(await sha256(ct)), ct)
      } catch {
        this.toast('Envoi du fichier au nœud impossible.')
        return
      }
    } else if (this.bus && ct.length <= 4 * 1024 * 1024) {
      att.inline = toB64(ct) // local test bus only: no size limit of a node envelope
    } else {
      this.toast('Il faut un nœud en ligne pour les fichiers de plus de 48 Ko.')
      return
    }
    if (media.pages) att.pages = media.pages
    await this.sendMessage(convId, { kind, attachment: att, text: kind === 'file' ? name : undefined }, media.bytes)
  }

  /** Plaintext of an attachment as an object URL (cached, sealed at rest). */
  mediaUrl(m: ChatMessage): Promise<string | null> {
    const hit = this.mediaUrls.get(m.id)
    if (hit) return Promise.resolve(hit)
    const loading = this.mediaLoading.get(m.id)
    if (loading) return loading
    const p = this.fetchMedia(m).finally(() => this.mediaLoading.delete(m.id))
    this.mediaLoading.set(m.id, p)
    return p
  }

  cachedMediaUrl(id: string): string | undefined {
    return this.mediaUrls.get(id)
  }

  private async fetchMedia(m: ChatMessage): Promise<string | null> {
    const a = m.attachment
    if (!a) return null
    let plain = await this.store?.getBytes('media', m.id)
    if (!plain) {
      let ct: Uint8Array
      if (a.inline) ct = fromB64(a.inline)
      else if (a.url) {
        const r = await fetch(a.url)
        if (!r.ok) throw new Error('Pièce jointe indisponible sur le nœud.')
        ct = new Uint8Array(await r.arrayBuffer())
      } else return null
      plain = this.engineOrThrow.openAttachment(fromB64(a.key), fromHex64(a.sha256), ct)
      await this.store?.putBytes('media', m.id, plain)
    }
    const url = URL.createObjectURL(new Blob([buf(plain)], { type: a.mime }))
    this.mediaUrls.set(m.id, url)
    this.set({})
    return url
  }

  async react(convId: string, targetId: string, emoji: string) {
    await this.applyReaction(convId, targetId, emoji, 'me')
    try {
      this.deliver(convId, { id: uuidv7(), ts: Date.now(), kind: 'reaction', text: emoji, reply_to: targetId })
    } catch {
      /* reaction stays local */
    }
  }

  private async applyReaction(convId: string, targetId: string, emoji: string, who: string) {
    const list = this.snap.messages[convId] ?? (await this.loadMessages(convId))
    const m = list.find((x) => x.id === targetId)
    if (!m) return
    const reactions: Record<string, string[]> = {}
    // One reaction per person: remove theirs, then toggle the new one.
    let had = false
    for (const [k, v] of Object.entries(m.reactions ?? {})) {
      if (k === emoji && v.includes(who)) had = true
      const rest = v.filter((x) => x !== who)
      if (rest.length) reactions[k] = rest
    }
    if (!had && emoji) reactions[emoji] = [...(reactions[emoji] ?? []), who]
    await this.patchMessage(targetId, convId, { reactions })
  }

  typing(convId: string) {
    if (convId.startsWith('g:')) return
    const last = this.lastTypingSent.get(convId) ?? 0
    if (Date.now() - last < 3000) return
    this.lastTypingSent.set(convId, Date.now())
    try {
      this.deliver(convId, { id: uuidv7(), ts: Date.now(), kind: 'typing' }, false)
    } catch {
      /* ignore */
    }
  }

  private async logCall(info: CallEndInfo) {
    const label =
      info.outcome === 'ended'
        ? `${info.video ? 'Appel vidéo' : 'Appel audio'}`
        : info.outcome === 'declined'
          ? 'Appel refusé'
          : info.outcome === 'busy'
            ? 'Occupé'
            : info.outgoing
              ? 'Pas de réponse'
              : 'Appel manqué'
    const msg: ChatMessage = {
      id: uuidv7(),
      convId: info.peer,
      from: info.outgoing ? 'me' : info.peer,
      ts: Date.now(),
      kind: 'call',
      text: label,
      status: 'read',
      call: { video: info.video, outcome: info.outcome, durationMs: info.durationMs },
    }
    await this.saveMessage(msg)
    await this.touchConv(info.peer, {
      preview: label,
      ts: msg.ts,
      unread: info.outcome === 'missed' && !info.outgoing && this.snap.activeConv !== info.peer ? 1 : 0,
    })
  }

  // Contacts

  /** Accepts a relay1: card, a relay1c: link or handle@node. */
  async addFromText(input: string): Promise<Contact> {
    const e = this.engineOrThrow
    const t = input.trim()
    let card: string | null = null
    if (t.startsWith('relay1:')) card = t
    else if (t.startsWith('relay1c:')) {
      const link = e.parseCompactLink(t)
      const node = link.node_url ? new NodeClient(link.node_url, e, () => '', () => {}) : this.node
      const mailbox = mailboxOf(link.fingerprint)
      if (link.handle && node) card = await node.lookupHandle(link.handle)
      if (!card && node && mailbox) card = await node.cardByMailbox(mailbox)
      if (!card) throw new Error('Carte introuvable sur le nœud. Demande-lui son lien complet.')
    } else if (/^[a-z0-9_.-]{3,32}(@[^\s@]+)?$/i.test(t)) {
      const [handle, host] = t.toLowerCase().split('@')
      const node = host
        ? new NodeClient(host.includes('://') ? host : `https://${host}`, e, () => '', () => {})
        : this.node
      if (!node) throw new Error('Aucun nœud configuré.')
      card = await node.lookupHandle(handle).catch(() => null)
      if (!card) throw new Error(`Personne ne s’appelle ${handle} sur ce nœud.`)
    } else throw new Error('Colle un lien relay1:, relay1c: ou un identifiant nom@nœud.')
    let contact: Contact
    try {
      contact = e.addContact(card)
    } catch (err) {
      if (err instanceof RelayError && err.code === 'KeyChanged')
        throw new Error('Sa clé a changé. Vérifiez vos mots de sécurité avant de continuer.')
      if (err instanceof RelayError && err.code === 'InvalidCard')
        throw new Error('Cette carte n’est pas valide (signature incorrecte).')
      throw err
    }
    if (linkMismatch(t, e, contact)) {
      e.removeContact(contact.fingerprint)
      throw new Error('La carte reçue ne correspond pas à l’empreinte du lien.')
    }
    this.refreshIdentity()
    this.pollPresence()
    return contact
  }

  setVerified(fp: string, v: boolean) {
    this.engineOrThrow.setVerified(fp, v)
    this.refreshIdentity()
  }

  renameContact(fp: string, name: string) {
    this.engineOrThrow.renameContact(fp, name)
    // A local rename wins over the name in their profile (spec 6).
    this.renamed.add(fp)
    void this.store?.putJson('meta', 'renamed', [...this.renamed])
    this.refreshIdentity()
    void this.retitle(fp)
  }

  private async retitle(convId: string) {
    const conv = this.snap.conversations.find((c) => c.id === convId)
    if (!conv) return
    const next = { ...conv, title: this.titleOf(convId) }
    this.set({ conversations: this.snap.conversations.map((c) => (c.id === convId ? next : c)) })
    await this.store?.putJson('conversations', convId, next)
  }

  async removeContact(fp: string) {
    this.engineOrThrow.removeContact(fp)
    this.p2p.close(fp, false)
    await this.deleteConversation(fp)
    this.refreshIdentity()
  }

  async deleteConversation(convId: string) {
    await this.store?.deleteConversationMessages(convId)
    await this.store?.delete('conversations', convId)
    const messages = { ...this.snap.messages }
    delete messages[convId]
    this.set({ conversations: this.snap.conversations.filter((c) => c.id !== convId), messages })
  }

  safetyWords(fp: string): string[] {
    return this.engineOrThrow.contactSafetyWords(fp)
  }
  safetyCode(fp: string): string {
    return this.engineOrThrow.contactSafetyCode(fp)
  }

  // Groups

  async createGroup(name: string, members: string[], photo?: Uint8Array | null): Promise<string> {
    const e = this.engineOrThrow
    const clean = name.trim()
    const gid = e.createGroup(clean, members)
    this.refreshIdentity()
    this.groupMembers.set(gid, [...(e.groups().find((g) => g.id === gid)?.members ?? [])])
    const convId = `g:${gid}`
    this.deliver(convId, { id: uuidv7(), ts: Date.now(), kind: 'group-op', group: { op: 'create', name: clean } })
    await this.addSystem(convId, `Tu as créé le groupe « ${clean} ».`)
    this.ensureProfile(convId)
    if (photo) await this.setGroupProfile(gid, { avatar: photo }, true)
    return convId
  }

  async groupAdd(gid: string, fp: string) {
    const e = this.engineOrThrow
    const envs = e.groupAdd(gid, fp)
    this.refreshIdentity()
    const g = e.groups().find((x) => x.id === gid)
    if (g) this.fanout(g, envs)
    this.groupMembers.set(gid, [...(g?.members ?? [])])
    await this.addSystem(`g:${gid}`, `Tu as ajouté ${this.nameOf(fp)} au groupe.`)
    // The newcomer gets the group photo and name, and my face (spec 6).
    this.resendGroupProfile(gid)
    delete this.sentProfile[`g:${gid}`]
    this.ensureProfile(`g:${gid}`)
  }

  async groupRemove(gid: string, fp: string, line = true) {
    const e = this.engineOrThrow
    const g0 = e.groups().find((x) => x.id === gid)
    const envs = e.groupRemove(gid, fp)
    this.refreshIdentity()
    if (g0) this.fanout(g0, envs)
    this.groupMembers.set(gid, [...(e.groups().find((x) => x.id === gid)?.members ?? [])])
    if (line) await this.addSystem(`g:${gid}`, `Tu as retiré ${this.nameOf(fp)} du groupe.`)
  }

  /** Says goodbye in the group (spec 6, `group-leave`), then leaves locally and forgets it. */
  async leaveGroup(gid: string) {
    const convId = `g:${gid}`
    this.control(convId, { kind: 'group-leave' })
    this.engineOrThrow.leaveGroup(gid)
    this.groupMembers.delete(gid)
    delete this.sentProfile[convId]
    void this.store?.putJson('meta', 'profile-sent', this.sentProfile)
    this.refreshIdentity()
    await this.deleteConversation(convId)
    await this.dropProfile(convId)
  }

  /** Last known members per group, to say who joined or left when the op log moves. */
  private groupMembers = new Map<string, string[]>()
  /** `gid|fp` of members who said `group-leave`, so the op that follows adds no second line. */
  private leftRecently = new Set<string>()

  private async syncMembers(gid: string, lines: boolean) {
    const g = this.engine?.groups().find((x) => x.id === gid)
    if (!g) return
    const prev = this.groupMembers.get(gid)
    this.groupMembers.set(gid, [...g.members])
    if (!prev || !lines) return
    const me = this.engine!.fingerprintHex()
    const added = g.members.filter((fp) => !prev.includes(fp) && fp !== me)
    const gone = prev.filter((fp) => !g.members.includes(fp) && fp !== me)
    for (const fp of added) await this.addSystem(`g:${gid}`, `${this.nameOf(fp)} a rejoint le groupe.`)
    for (const fp of gone) {
      if (this.leftRecently.delete(`${gid}|${fp}`)) continue
      await this.addSystem(`g:${gid}`, `${this.nameOf(fp)} ne fait plus partie du groupe.`)
    }
    // New faces in the group: they get my profile once.
    if (added.length) {
      delete this.sentProfile[`g:${gid}`]
      this.ensureProfile(`g:${gid}`)
    }
  }

  private async applyGroupLeave(gid: string, from: string) {
    const e = this.engine
    const g = e?.groups().find((x) => x.id === gid)
    if (!e || !g || !g.members.includes(from)) return
    this.leftRecently.add(`${gid}|${from}`)
    await this.addSystem(`g:${gid}`, `${this.nameOf(from)} a quitté le groupe.`)
    // An admin removes the leaver, so the sender key rotates for everyone else.
    if (g.admins.includes(e.fingerprintHex())) {
      try {
        await this.groupRemove(gid, from, false)
      } catch (err) {
        console.warn('group remove after leave failed', err)
      }
    }
  }

  // Profiles (spec 6)

  private sentProfile: Record<string, string> = {}
  private renamed = new Set<string>()

  private async putProfile(p: PeerProfile) {
    this.set({ profiles: { ...this.snap.profiles, [p.id]: p } })
    await this.store?.putJson('profiles', p.id, p)
    if (p.id === 'me') this.markVaultDirty()
  }

  private async dropProfile(id: string) {
    if (!this.snap.profiles[id]) return
    const profiles = { ...this.snap.profiles }
    delete profiles[id]
    this.set({ profiles })
    await this.store?.delete('profiles', id)
  }

  /** What I last sent: photo hash and name. */
  private profileKey(): string {
    return `${this.snap.profiles.me?.hash ?? '-'}|${this.snap.me?.name ?? ''}`
  }

  /** Sends my profile to a contact or into a group, unless that exact profile went there already. */
  private ensureProfile(target: string) {
    if (!this.engine) return
    const key = this.profileKey()
    if (this.sentProfile[target] === key) return
    if (target.startsWith('g:')) {
      if (!this.engine.groups().some((g) => g.id === target.slice(2))) return
    } else if (!this.snap.contacts.some((c) => c.fingerprint === target)) return
    const mine = this.snap.profiles.me
    const profile: ProfileWire = { name: this.snap.me?.name ?? '' }
    if (mine?.avatar) {
      profile.avatar = mine.avatar
      profile.avatar_hash = mine.hash
    } else profile.avatar = null
    if (!this.control(target, { kind: 'profile', profile })) return
    this.sentProfile[target] = key
    void this.store?.putJson('meta', 'profile-sent', this.sentProfile)
  }

  /** After a change of photo or name: every conversation gets it once. */
  private broadcastProfile() {
    for (const c of this.snap.conversations) this.ensureProfile(c.id)
  }

  /** Sets (bytes) or removes (null) my photo and tells everyone. */
  async setMyAvatar(jpeg: Uint8Array | null) {
    if (this.vaultRec?.photo) {
      delete this.vaultRec.photo
      await this.saveVault()
    }
    const cur = this.snap.profiles.me
    if (jpeg) await this.putProfile({ ...cur, id: 'me', avatar: toB64(jpeg), hash: await avatarHash(jpeg), ts: Date.now() })
    else if (cur?.avatar) await this.putProfile({ id: 'me', ts: Date.now() })
    else return
    this.broadcastProfile()
  }

  /** Validates and stores a photo payload. Returns the patch, or null for a no-op or bad data. */
  private async readProfile(cur: PeerProfile | undefined, p: ProfileWire): Promise<{ avatar?: string; hash?: string; removed?: boolean } | null> {
    if (p.avatar === null) return cur?.avatar ? { removed: true } : null
    if (typeof p.avatar !== 'string') return null
    const claimed = typeof p.avatar_hash === 'string' ? p.avatar_hash.toLowerCase() : undefined
    if (claimed && cur?.hash === claimed) return null
    const hash = await checkAvatar(p.avatar)
    if (!hash || (claimed && claimed !== hash) || hash === cur?.hash) return null
    return { avatar: p.avatar, hash }
  }

  private async applyProfile(from: string, raw: unknown) {
    if (!raw || typeof raw !== 'object') return
    const p = raw as ProfileWire
    const cur = this.snap.profiles[from]
    const next: PeerProfile = { ...cur, id: from, ts: Date.now() }
    let changed = false
    const photo = await this.readProfile(cur, p)
    if (photo?.removed) {
      delete next.avatar
      delete next.hash
      changed = true
    } else if (photo) {
      next.avatar = photo.avatar
      next.hash = photo.hash
      changed = true
    }
    const name = typeof p.name === 'string' ? p.name.trim().slice(0, 64) : ''
    if (name && name !== cur?.name) {
      next.name = name
      changed = true
      const c = this.snap.contacts.find((x) => x.fingerprint === from)
      if (c && c.name !== name && !this.renamed.has(from)) {
        this.engineOrThrow.renameContact(from, name)
        this.refreshIdentity()
        void this.retitle(from)
      }
    }
    if (changed) await this.putProfile(next)
  }

  private async applyGroupProfile(gid: string, from: string, raw: unknown) {
    if (!raw || typeof raw !== 'object') return
    const g = this.engine?.groups().find((x) => x.id === gid)
    if (!g || !g.admins.includes(from)) return // admins only (spec 6)
    const id = `g:${gid}`
    const p = raw as ProfileWire
    const cur = this.snap.profiles[id]
    const next: PeerProfile = { ...cur, id, ts: Date.now() }
    const who = this.nameOf(from)
    const lines: string[] = []
    const photo = await this.readProfile(cur, p)
    if (photo?.removed) {
      delete next.avatar
      delete next.hash
      lines.push(`${who} a retiré la photo du groupe.`)
    } else if (photo) {
      next.avatar = photo.avatar
      next.hash = photo.hash
      lines.push(`${who} a changé la photo du groupe.`)
    }
    const name = typeof p.name === 'string' ? p.name.trim().slice(0, 64) : ''
    if (name && name !== this.titleOf(id)) {
      next.name = name
      lines.push(`${who} a renommé le groupe « ${name} ».`)
    } else if (name) next.name = name
    if (!lines.length && next.name === cur?.name) return
    await this.putProfile(next)
    await this.retitle(id)
    for (const l of lines) await this.addSystem(id, l)
  }

  /** Admin only: changes the group photo (bytes, or null to remove) and/or name. */
  async setGroupProfile(gid: string, change: { name?: string; avatar?: Uint8Array | null }, quiet = false) {
    const e = this.engineOrThrow
    const g = e.groups().find((x) => x.id === gid)
    if (!g || !g.admins.includes(e.fingerprintHex())) throw new Error('Seul un admin peut changer le groupe.')
    const id = `g:${gid}`
    const cur = this.snap.profiles[id]
    const next: PeerProfile = { ...cur, id, ts: Date.now() }
    const wire: ProfileWire = {}
    const lines: string[] = []
    if (change.avatar === null && cur?.avatar) {
      delete next.avatar
      delete next.hash
      wire.avatar = null
      lines.push('Tu as retiré la photo du groupe.')
    } else if (change.avatar) {
      next.avatar = toB64(change.avatar)
      next.hash = await avatarHash(change.avatar)
      wire.avatar = next.avatar
      wire.avatar_hash = next.hash
      lines.push('Tu as changé la photo du groupe.')
    }
    const name = change.name?.trim().slice(0, 64)
    if (name && name !== this.titleOf(id)) {
      next.name = name
      wire.name = name
      lines.push(`Tu as renommé le groupe « ${name} ».`)
    }
    if (!lines.length) return
    this.control(id, { kind: 'group-profile', group_profile: wire })
    await this.putProfile(next)
    await this.retitle(id)
    if (!quiet) for (const l of lines) await this.addSystem(id, l)
  }

  /** Admin: sends the current group photo and name again, so a newcomer gets them. */
  private resendGroupProfile(gid: string) {
    const e = this.engine
    const g = e?.groups().find((x) => x.id === gid)
    const p = this.snap.profiles[`g:${gid}`]
    if (!e || !g || !p || !g.admins.includes(e.fingerprintHex())) return
    const wire: ProfileWire = {}
    if (p.name) wire.name = p.name
    if (p.avatar) {
      wire.avatar = p.avatar
      wire.avatar_hash = p.hash
    }
    if (wire.name || wire.avatar) this.control(`g:${gid}`, { kind: 'group-profile', group_profile: wire })
  }

  // In-app banner

  private bannerSeq = 0

  private showBanner(convId: string, m: ChatMessage, mention: boolean) {
    if (document.visibilityState !== 'visible' || this.snap.activeConv === convId) return
    const conv = this.snap.conversations.find((c) => c.id === convId)
    if (conv?.mutedUntil && conv.mutedUntil > Date.now() && !mention) return
    const group = convId.startsWith('g:')
    this.set({
      banner: {
        seq: ++this.bannerSeq,
        convId,
        msgId: m.id,
        avatarId: group ? convId : m.from,
        title: this.titleOf(convId),
        text: this.notifyBody(convId, m),
      },
    })
  }

  dismissBanner(seq?: number) {
    if (this.snap.banner && (seq === undefined || this.snap.banner.seq === seq)) this.set({ banner: null })
  }

  /**
   * Group envelopes (kind 2) go to every other member's mailbox; sender-key distribution
   * envelopes (kind 1) go to the mailbox in their tag. The order returned by the core does
   * not matter. Returns the transport of the group envelope.
   */
  private fanout(
    g: Group,
    envs: Uint8Array[],
    meta: { msgId?: string; convId?: string; queue?: boolean } = {},
  ): Transport | null {
    const e = this.engineOrThrow
    const me = e.fingerprintHex()
    let used: Transport | null = null
    for (const env of envs) {
      const h = e.envelopeHeader(env)
      if (!h) continue
      if (h.kind === 2) {
        g.members.forEach((fp, i) => {
          if (fp === me) return
          const mailbox = g.mailboxes?.[i] ?? this.snap.contacts.find((x) => x.fingerprint === fp)?.mailbox
          if (!mailbox) return
          // Group messages get no receipts, so nothing would notice a dead P2P channel: use the
          // node when it is up, P2P only when it is not.
          used = this.route(env, { fp: this.node?.isReady ? undefined : fp, mailbox }, meta) ?? used
        })
      } else {
        const fp = this.snap.contacts.find((x) => x.mailbox === h.tag)?.fingerprint
        this.route(env, { fp, mailbox: h.tag }, { queue: meta.queue })
      }
    }
    return used
  }

  private async addSystem(convId: string, text: string) {
    const msg: ChatMessage = { id: uuidv7(), convId, from: 'me', ts: Date.now(), kind: 'system', text, status: 'read' }
    await this.saveMessage(msg)
    await this.touchConv(convId, { preview: text, ts: msg.ts })
  }

  // Settings

  async updateSettings(patch: Partial<Settings>) {
    const settings = { ...this.snap.settings, ...patch }
    localSet('settings', JSON.stringify(settings))
    this.iceCache = null
    this.set({ settings })
    if (this.engine && ('nodeUrl' in patch || 'localBus' in patch)) this.startTransports()
    if ('p2p' in patch && !settings.p2p) this.p2p.closeAll()
    if ('nodeUrl' in patch || 'handle' in patch) this.markVaultDirty()
  }

  setDisplayName(name: string) {
    this.engineOrThrow.setDisplayName(name.trim())
    this.refreshIdentity()
    this.node?.reregister()
    this.broadcastProfile()
  }

  async registerHandle(handle: string): Promise<string | null> {
    const h = handle.trim().toLowerCase()
    if (!/^[a-z0-9_.-]{3,32}$/.test(h)) return 'De 3 à 32 caractères : lettres, chiffres, point, tiret.'
    if (!this.node) return 'Aucun nœud.'
    await this.updateSettings({ handle: h })
    try {
      const r = await this.node.registerHandle(h)
      // Signing builds a fresh card and remembers the handle inside the engine.
      this.persist()
      if (r.ok) {
        this.node.reregister()
        return null
      }
      switch (r.code) {
        case 'unsupported':
          return 'Le moteur ne sait pas encore signer pour l’annuaire.'
        case 'handle_taken':
          return 'Cet identifiant est déjà pris.'
        case 'too_many_handles':
          return 'Tu as déjà 5 identifiants sur ce nœud.'
        case 'unknown_mailbox':
          return 'Connecte-toi d’abord au nœud, puis réessaie.'
        case 'bad_signature':
          return 'Le nœud n’a pas reconnu ta signature.'
        case 'card_rejected':
          return 'Le nœud a refusé ta carte.'
      }
      return r.status === 409 ? 'Cet identifiant est déjà pris.' : `Le nœud a refusé (${r.status}).`
    } catch (e) {
      if (e instanceof Error && (e.name === 'Malformed' || (e as { code?: string }).code === 'Malformed'))
        return 'De 3 à 32 caractères : lettres, chiffres, point, tiret.'
      return 'Nœud injoignable.'
    }
  }

  // Passkey backup (spec 2026-11-22-passkey-unlock-backup, sections 3 and 6)

  private vaultRec: VaultRecord | null = null
  private vaultTimer: ReturnType<typeof setTimeout> | null = null
  private vaultUpload: Promise<boolean> | null = null
  private vaultInFlight = 0
  /** Bumped by every dirty mark: an upload only clears the flag for the state it carried. */
  private vaultGen = 0
  private wiping = false
  private vaultBackoff = 0
  private vaultRetry: ReturnType<typeof setTimeout> | null = null

  private restoredFlag = false

  /** True once after a passkey restore: the restored person skips the "Voilà ton code" screen. */
  consumeRestoredFlag(): boolean {
    const f = this.restoredFlag
    this.restoredFlag = false
    return f
  }

  /** The passkey step can be offered: relying party we own, WebAuthn, and the core has the vault. */
  async passkeyAvailable(): Promise<boolean> {
    if (!this.factory?.vault) return false
    return prfAvailable()
  }

  private setVault(patch: Partial<VaultStatus>) {
    this.set({ vault: { ...this.snap.vault, ...patch } })
  }

  private async loadVault() {
    this.vaultRec = (await this.store?.getJson<VaultRecord>('meta', 'vault')) ?? null
    this.set({ vault: statusOf(this.vaultRec) })
  }

  private async saveVault() {
    if (this.vaultRec) await this.store?.putJson('meta', 'vault', this.vaultRec)
  }

  /** The engine state, the handle, the node and my photo changed: upload 10 s after the last change. */
  markVaultDirty(debounced = true) {
    const rec = this.vaultRec
    if (!rec?.key || this.wiping) return
    rec.dirty = true
    this.vaultGen++
    void this.saveVault()
    if (this.vaultTimer) clearTimeout(this.vaultTimer)
    this.vaultTimer = null
    if (this.snap.vault.state === 'saved') this.setVault({ state: 'pending' })
    if (debounced) this.vaultTimer = setTimeout(() => void this.flushVault(), VAULT_DEBOUNCE_MS)
  }

  /** After `rate_limited`: 30 s, then 60 s, doubling, capped at 5 min. */
  private scheduleVaultRetry() {
    if (this.vaultRetry || this.wiping) return
    this.vaultBackoff = Math.min(300_000, this.vaultBackoff ? this.vaultBackoff * 2 : 30_000)
    this.vaultRetry = setTimeout(() => {
      this.vaultRetry = null
      void this.retryVaultIfOwed()
    }, this.vaultBackoff)
  }

  private async retryVaultIfOwed() {
    if (this.vaultRec?.key && this.vaultRec.dirty) await this.flushVault()
  }

  /**
   * Uploads the sealed state if an upload is owed. Returns once the state current at the call is
   * on the node or an attempt for it has ended; a caller that finds an upload running waits for
   * it, then uploads again if a newer state is owed.
   */
  async flushVault(): Promise<void> {
    for (;;) {
      if (this.wiping) return
      if (this.vaultTimer) clearTimeout(this.vaultTimer)
      this.vaultTimer = null
      if (this.vaultUpload) {
        const carried = this.vaultInFlight
        await this.vaultUpload
        if (!this.vaultRec?.dirty || this.vaultGen === carried) return
        continue
      }
      if (!this.vaultRec?.key || !this.vaultRec.dirty || !this.engine) return
      this.vaultInFlight = this.vaultGen
      const task = this.uploadVaultOnce().finally(() => {
        this.vaultUpload = null
      })
      this.vaultUpload = task
      if (!(await task) || !this.vaultRec?.dirty) return
    }
  }

  private async uploadVaultOnce(): Promise<boolean> {
    const rec = this.vaultRec
    const e = this.engine
    const crypto = this.factory?.vault
    if (!rec?.key || !e || !crypto || !this.node) return false
    if (!e.signVault) return false
    const carried = this.vaultGen
    const id = crypto.vaultId(fromB64(rec.credentialId))
    let blob: Uint8Array
    try {
      // My own photo wins; the restored one stays until I set or remove mine.
      const own = this.snap.profiles.me?.avatar
      const kept = own ? fromB64(own) : rec.photo ? fromB64(rec.photo) : null
      const nodeUrl = this.snap.settings.nodeUrl.trim()
      blob = crypto.sealVault(fromB64(rec.key), id, {
        engine: e.exportState(),
        handle: this.snap.settings.handle || null,
        nodeUrl: nodeUrl || null,
        // The web has no channel preferences: a restored list is sealed again byte for byte,
        // else the empty JSON array the apps write.
        channelsPrefs: rec.channelsPrefs ? fromB64(rec.channelsPrefs) : utf8('[]'),
        photo: kept && kept.length <= 64 * 1024 ? kept : null,
      })
    } catch (err) {
      const big = err instanceof Error && /TooLarge/.test(`${err.name} ${err.message}`)
      this.setVault({ state: 'failed', message: big ? 'Sauvegarde trop lourde pour le nœud.' : 'Sauvegarde impossible à chiffrer.' })
      return false
    }
    this.setVault({ busy: true })
    try {
      const code = await this.node.putVault(id, blob, e.signVault(id, blob))
      if (this.vaultRec !== rec) return false
      if (code === '') {
        this.vaultBackoff = 0
        rec.savedAt = Date.now()
        if (this.vaultGen === carried) rec.dirty = false
        await this.saveVault()
        this.set({ vault: { ...statusOf(rec), busy: false } })
        return true
      }
      if (code === 'rate_limited') this.scheduleVaultRetry()
      if (RETRYABLE.has(code)) this.setVault({ state: 'pending', busy: false, message: undefined })
      else this.setVault({ state: 'failed', busy: false, message: refusedMessage(code) })
      return false
    } catch {
      // No network: kept for the next node connection.
      if (this.vaultRec === rec) this.setVault({ state: 'pending', busy: false, message: undefined })
      return false
    }
  }

  /**
   * Creates the passkey, runs one assertion for both PRF outputs, keeps the vault key and uploads
   * the first backup. A passkey manager without PRF still gets its passkey but no backup
   * (`lockOnly`). Passkey failures throw `PasskeyError`.
   */
  async setUpPasskey(): Promise<void> {
    const crypto = this.factory?.vault
    if (!crypto || !this.engine || !this.store || !this.engine.signVault) throw new PasskeyError('unavailable')
    if (this.snap.vault.busy) return
    this.setVault({ busy: true, message: undefined })
    try {
      setPrfSalts({ unlock: crypto.saltUnlock(), backup: crypto.saltBackup() })
      const userHandle = this.vaultRec ? fromB64(this.vaultRec.userHandle) : randomBytes(16)
      const settings = this.snap.settings
      const userName = settings.handle || this.engine.displayName()
      const reg = await registerPasskey(userName, userHandle)
      const a = await assertPasskey(reg.credentialId)
      // A restored vault's channel list and photo come along to the new passkey's vault.
      const rec: VaultRecord = {
        credentialId: toB64(a.credentialId),
        userHandle: toB64(userHandle),
        dirty: false,
        channelsPrefs: this.vaultRec?.channelsPrefs,
        photo: this.vaultRec?.photo,
      }      // `prf` of the registration is not relied on: the assertion outputs decide.
      if (!a.second) {
        this.vaultRec = rec
        await this.saveVault()
        this.set({ vault: statusOf(rec) })
        return
      }
      rec.key = toB64(crypto.vaultKey(a.second))
      this.vaultRec = rec
      await this.saveVault()
      this.markVaultDirty(false)
      await this.flushVault()
    } finally {
      this.setVault({ busy: false })
    }
  }

  /**
   * Restore on a fresh browser: a discoverable assertion (empty allow list) with both salts,
   * `vault_id` from the credential id, `GET /v1/vault/{id}`, open with `vault_key`. Everything
   * that can fail runs before anything local changes.
   */
  async restoreFromPasskey(): Promise<void> {
    const crypto = this.factory?.vault
    const factory = this.factory
    if (!crypto || !factory || !this.store || this.engine) throw new PasskeyRestoreError('unavailable')
    setPrfSalts({ unlock: crypto.saltUnlock(), backup: crypto.saltBackup() })
    let a
    try {
      a = await assertPasskey()
    } catch (e) {
      if (e instanceof PasskeyError) {
        if (e.code === 'cancelled') throw new PasskeyRestoreError('cancelled')
        if (e.code === 'noCredential') throw new PasskeyRestoreError('noPasskey')
      }
      throw new PasskeyRestoreError('unavailable')
    }
    if (!a.second) throw new PasskeyRestoreError('cannotOpen')
    let key: Uint8Array
    try {
      key = crypto.vaultKey(a.second)
    } catch {
      throw new PasskeyRestoreError('cannotOpen')
    }
    const id = crypto.vaultId(a.credentialId)
    let blob: Uint8Array | null
    try {
      blob = await getVault(resolveNodeUrl(this.snap.settings.nodeUrl), id)
    } catch {
      throw new PasskeyRestoreError('network')
    }
    if (!blob) throw new PasskeyRestoreError('noBackup')
    let restored: Engine
    let plain
    try {
      plain = crypto.openVault(key, id, blob)
      restored = factory.restore(plain.engine)
    } catch {
      throw new PasskeyRestoreError('cannotOpen')
    }
    // An identity appeared meanwhile (file import): leave it alone.
    if (this.engine) throw new PasskeyRestoreError('cancelled')

    // Nothing can fail from here on except storage: the browser takes the identity.
    const settings = { ...this.snap.settings }
    if (plain.handle) settings.handle = plain.handle
    if (plain.nodeUrl && plain.nodeUrl !== location.origin) settings.nodeUrl = plain.nodeUrl
    localSet('settings', JSON.stringify(settings))
    this.set({ settings })
    await this.store.putBytes('meta', 'engine', restored.exportState())
    this.engine = restored
    if (plain.photo) {
      const hash = await checkAvatar(toB64(plain.photo))
      if (hash) await this.putProfile({ id: 'me', avatar: toB64(plain.photo), hash, ts: Date.now() })
    }
    const rec: VaultRecord = {
      credentialId: toB64(a.credentialId),
      userHandle: toB64(randomBytes(16)),
      key: toB64(key),
      dirty: true,
      channelsPrefs: toB64(plain.channelsPrefs),
      photo: plain.photo ? toB64(plain.photo) : undefined,
    }
    this.vaultRec = rec
    await this.saveVault()
    this.restoredFlag = true
    await this.afterIdentity()
    this.toast(RESTORED_TOAST)
    // The restored browser keeps the same vault up to date, and uploads once right away.
    this.markVaultDirty(false)
    void this.flushVault()
  }

  /** True when the core can seal a `.relaykey` (relay-core wasm, not the mock). */
  get canSealExport(): boolean {
    return !!this.factory?.sealExport
  }

  /** `.relaykey` sealed with `passphrase` (at least `EXPORT_MIN_PASSPHRASE` characters). */
  async exportFile(passphrase: string): Promise<Blob> {
    const seal = this.factory?.sealExport
    if (!seal) throw new Error('Export chiffré indisponible avec le moteur de test.')
    if (passphrase.length < EXPORT_MIN_PASSPHRASE)
      throw new Error(`Au moins ${EXPORT_MIN_PASSPHRASE} caractères.`)
    const state = this.engineOrThrow.exportState()
    await new Promise((r) => setTimeout(r, 30))
    return new Blob([seal(passphrase, state)], { type: 'text/plain' })
  }

  /** Clear JSON backup, kept for the mock engine only. */
  backupFile(): Blob {
    const state = this.engineOrThrow.exportState()
    return new Blob(
      [JSON.stringify({ kind: 'soma-relay-backup', v: 1, engine: this.engine?.kind, state: toB64(state) })],
      { type: 'application/json' },
    )
  }

  async wipe() {
    this.wiping = true
    if (this.vaultTimer) clearTimeout(this.vaultTimer)
    if (this.vaultRetry) clearTimeout(this.vaultRetry)
    this.vaultTimer = this.vaultRetry = null
    this.node?.stop()
    this.bus?.close()
    this.p2p.closeAll()
    this.store?.close()
    await Storage.wipe()
    localSet('settings', null)
    location.reload()
  }
}

function sortConvs(list: Conversation[]): Conversation[] {
  return [...list].sort((a, b) => b.lastTs - a.lastTs)
}

function fromHex64(hex: string): Uint8Array {
  const out = new Uint8Array(32)
  for (let i = 0; i < 32; i++) out[i] = parseInt(hex.substr(i * 2, 2), 16)
  return out
}

/** Mailbox of a fingerprint, derived like the core: first 16 bytes of SHA3-256. */
function mailboxOf(fp: string): string {
  const fpBytes = new Uint8Array(32)
  for (let i = 0; i < 32; i++) fpBytes[i] = parseInt(fp.substr(i * 2, 2), 16)
  const pre = utf8('soma-relay/mailbox')
  const all = new Uint8Array(pre.length + 32)
  all.set(pre)
  all.set(fpBytes, pre.length)
  return toHex(sha3_256(all).slice(0, 16))
}

function linkMismatch(input: string, e: Engine, c: Contact): boolean {
  if (!input.startsWith('relay1c:')) return false
  try {
    return e.parseCompactLink(input).fingerprint.toLowerCase() !== c.fingerprint.toLowerCase()
  } catch {
    return false
  }
}

export const relay = new Relay()
