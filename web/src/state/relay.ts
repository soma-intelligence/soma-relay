// Relay: the client runtime. Owns the engine, storage, transports and calls, and exposes an
// immutable snapshot for React (useSyncExternalStore).
//
// Router (spec section 6): an open WebRTC data channel first, then the node, then the local
// test bus, else the outbox (dashed "en route" bubbles) flushed when a transport comes back.

import type { AppMessage, Attachment, CallSignal, Contact, Engine, EngineFactory, Group, Inbound } from '../core/engine'
import { RelayError } from '../core/engine'
import { loadEngineFactory } from '../core/loadEngine'
import { Storage } from '../lib/storage'
import { localGet, localSet, PROFILE } from '../lib/profile'
import { sha3_256 } from '@noble/hashes/sha3.js'
import { buf, fromB64, sha256, toB64, toB64Url, toHex, utf8, uuidv7 } from '../lib/bytes'
import { NodeClient, type NodeEvent } from '../net/nodeClient'
import { LocalBus } from '../net/localBus'
import { isDataChannelSignal, P2P } from '../net/p2p'
import { CallManager, type CallEndInfo } from '../calls/callManager'
import type { PreparedMedia } from '../media/media'
import type { ChatKind, ChatMessage, Conversation, NodeState, OutboxItem, Settings, Status, Transport } from './types'

export interface Me {
  name: string
  fingerprint: string
  mailbox: string
  words: string[]
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
}

const INLINE_MAX = 48 * 1024
const RANK: Record<Status, number> = { failed: 0, pending: 1, sent: 2, delivered: 3, read: 4 }

const DEFAULT_SETTINGS: Settings = { nodeUrl: '', handle: '', localBus: false, p2p: true }

export function convIdFor(inbound: { from: string; group?: string }): string {
  return inbound.group ? `g:${inbound.group}` : inbound.from
}

function previewOf(kind: ChatKind, text?: string): string {
  switch (kind) {
    case 'image':
      return 'Photo'
    case 'audio':
      return 'Note vocale'
    case 'video':
      return 'Vidéo'
    case 'file':
      return text || 'Fichier'
    case 'call':
      return text || 'Appel'
    default:
      return text ?? ''
  }
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
      () => this.ice(),
      (info) => void this.logCall(info),
    )
    document.addEventListener('visibilitychange', () => {
      if (document.visibilityState === 'visible' && this.snap.activeConv) void this.markRead(this.snap.activeConv)
    })
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
      // The mock cannot authenticate to a real node, and the dev server has no node: the local
      // bus between tabs is on by default there.
      if ((this.factory.kind === 'mock' || import.meta.env.DEV) && localGet('settings') === null) settings.localBus = true
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

  async restoreBackup(file: File) {
    if (!this.factory || !this.store) return
    const j = JSON.parse(await file.text()) as { kind?: string; state?: string }
    if (j.kind !== 'soma-relay-backup' || !j.state) throw new Error('Ce fichier n’est pas une sauvegarde Soma Relay.')
    this.engine = this.factory.restore(fromB64(j.state))
    await this.store.putBytes('meta', 'engine', this.engine.exportState())
    await this.afterIdentity()
  }

  private async afterIdentity() {
    const e = this.engine!
    e.rotatePrekeyIfDue(Date.now())
    const convs = await this.store!.allJson<Conversation>('conversations')
    this.outbox = await this.store!.allJson<OutboxItem>('outbox')
    this.set({
      phase: 'ready',
      me: this.meOf(e),
      contacts: e.contacts(),
      groups: e.groups(),
      conversations: sortConvs(convs),
      outboxCount: this.outbox.length,
    })
    this.persist()
    this.startTransports()
  }

  private meOf(e: Engine): Me {
    return { name: e.displayName(), fingerprint: e.fingerprintHex(), mailbox: e.mailboxHex(), words: e.safetyWords() }
  }

  /** Saves the engine state, debounced 300 ms (core-api: after every mutating call). */
  persist() {
    if (this.saveTimer) clearTimeout(this.saveTimer)
    this.saveTimer = setTimeout(() => {
      if (this.engine && this.store) void this.store.putBytes('meta', 'engine', this.engine.exportState())
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

  async ice(): Promise<RTCIceServer[]> {
    if (this.iceCache && Date.now() - this.iceCache.at < 10 * 60_000) return this.iceCache.servers
    let servers = (await this.node?.iceServers()) ?? []
    if (!servers.length) servers = [{ urls: 'stun:stun.cloudflare.com:3478' }]
    this.iceCache = { at: Date.now(), servers }
    return servers
  }

  /** Sends one envelope. Returns the transport used, or null when it was queued. */
  private route(
    env: Uint8Array,
    target: { fp?: string; mailbox: string },
    meta?: { msgId?: string; convId?: string; queue?: boolean },
  ): Transport | null {
    if (target.fp && this.p2p.send(target.fp, env)) return 'p2p'
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
        if (ev === 'removed') await this.addSystem(convId, 'Tu as été retiré du groupe.')
        else if (!known) await this.addSystem(convId, `${this.titleOf(inb.from)} t’a ajouté au groupe.`)
        return
      }
      case 'profile':
        return
    }
    const kind = m.kind as ChatKind
    const typing = { ...this.snap.typing }
    delete typing[convId + '|' + inb.from]
    this.set({ typing })
    const msg: ChatMessage = {
      id: m.id,
      convId,
      from: inb.from,
      ts: m.ts,
      kind,
      text: m.text,
      replyTo: m.reply_to,
      attachment: m.attachment,
      status: 'delivered',
      transport: via,
    }
    if (this.findMessage(convId, msg.id)) return
    await this.saveMessage(msg)
    const active = this.snap.activeConv === convId && document.visibilityState === 'visible'
    await this.touchConv(convId, { preview: previewOf(kind, m.text), ts: m.ts, transport: via, unread: active ? 0 : 1 })
    if (!inb.group) this.sendReceipt(inb.from, [m.id], active ? 'read' : 'delivered')
    if (active) await this.updateStatus([m.id], 'read')
    if (!active) this.notify(convId, previewOf(kind, m.text))
    // Small media downloads right away, so they show without a tap.
    if (m.attachment && m.attachment.size < 8 * 1024 * 1024 && kind !== 'file') void this.mediaUrl(msg)
  }

  private notify(convId: string, body: string) {
    if (document.visibilityState === 'visible') return
    if (typeof Notification === 'undefined' || Notification.permission !== 'granted') return
    const title = this.titleOf(convId)
    try {
      new Notification(title, { body, tag: convId, silent: false })
    } catch {
      /* not allowed */
    }
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
    if (convId.startsWith('g:')) return this.snap.groups.find((g) => g.id === convId.slice(2))?.name ?? 'Groupe'
    return this.snap.contacts.find((c) => c.fingerprint === convId)?.name ?? 'Inconnu'
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
    p: { preview: string; ts: number; transport?: Transport; unread?: number },
  ) {
    const existing = this.snap.conversations.find((c) => c.id === convId)
    const conv: Conversation = {
      id: convId,
      kind: convId.startsWith('g:') ? 'group' : 'direct',
      title: this.titleOf(convId),
      lastTs: Math.max(existing?.lastTs ?? 0, p.ts),
      preview: p.preview,
      unread: (existing?.unread ?? 0) + (p.unread ?? 0),
      transport: p.transport ?? existing?.transport,
      draft: existing?.draft,
    }
    this.set({ conversations: sortConvs([...this.snap.conversations.filter((c) => c.id !== convId), conv]) })
    await this.store?.putJson('conversations', convId, conv)
  }

  async openConversation(convId: string | null) {
    this.set({ activeConv: convId })
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
  }

  private async updateStatus(ids: string[], status: Status, transport?: Transport) {
    const set = new Set(ids)
    const messages = { ...this.snap.messages }
    const changed: ChatMessage[] = []
    for (const [conv, list] of Object.entries(messages)) {
      if (!list.some((m) => set.has(m.id))) continue
      messages[conv] = list.map((m) => {
        if (!set.has(m.id)) return m
        if (status !== 'failed' && RANK[m.status] >= RANK[status]) return m
        const next = { ...m, status, transport: transport ?? m.transport }
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
    return this.route(env, { fp: convId, mailbox: c.mailbox }, { msgId: msg.id, convId, queue })
  }

  async sendText(convId: string, text: string, replyTo?: string) {
    const body = text.trim()
    if (!body) return
    await this.sendMessage(convId, { kind: 'text', text: body, reply_to: replyTo })
  }

  private async sendMessage(convId: string, part: Omit<AppMessage, 'id' | 'ts'>, localMedia?: Uint8Array) {
    const msg: AppMessage = { id: uuidv7(), ts: Date.now(), ...part }
    const chat: ChatMessage = {
      id: msg.id,
      convId,
      from: 'me',
      ts: msg.ts,
      kind: msg.kind as ChatKind,
      text: msg.text,
      replyTo: msg.reply_to,
      attachment: msg.attachment,
      status: 'pending',
    }
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
      return
    }
    // The node confirms with "sent"; other transports count as sent now.
    if (via && via !== 'net') await this.updateStatus([msg.id], 'sent', via)
    else if (via === 'net') await this.patchMessage(msg.id, convId, { transport: 'net' })
    await this.touchConv(convId, { preview: previewOf(chat.kind, chat.text), ts: chat.ts, transport: via ?? undefined })
    const conv = this.snap.conversations.find((c) => c.id === convId)
    if (conv?.draft) await this.setDraft(convId, '')
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
    const app: AppMessage = { id: m.id, ts: m.ts, kind: m.kind as AppMessage['kind'], text: m.text, reply_to: m.replyTo, attachment: m.attachment }
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

  async createGroup(name: string, members: string[]): Promise<string> {
    const e = this.engineOrThrow
    const gid = e.createGroup(name.trim(), members)
    this.refreshIdentity()
    const convId = `g:${gid}`
    this.deliver(convId, { id: uuidv7(), ts: Date.now(), kind: 'group-op', group: { op: 'create', name: name.trim() } })
    await this.addSystem(convId, `Tu as créé le groupe « ${name.trim()} ».`)
    return convId
  }

  async groupAdd(gid: string, fp: string) {
    const e = this.engineOrThrow
    const envs = e.groupAdd(gid, fp)
    this.refreshIdentity()
    const g = e.groups().find((x) => x.id === gid)
    if (g) this.fanout(g, envs)
    await this.addSystem(`g:${gid}`, `${this.titleOf(fp)} a rejoint le groupe.`)
  }

  async groupRemove(gid: string, fp: string) {
    const e = this.engineOrThrow
    const g0 = e.groups().find((x) => x.id === gid)
    const envs = e.groupRemove(gid, fp)
    this.refreshIdentity()
    if (g0) this.fanout(g0, envs)
    await this.addSystem(`g:${gid}`, `${this.titleOf(fp)} a quitté le groupe.`)
  }

  async leaveGroup(gid: string) {
    this.engineOrThrow.leaveGroup(gid)
    this.refreshIdentity()
    await this.deleteConversation(`g:${gid}`)
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
          used = this.route(env, { fp, mailbox }, meta) ?? used
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
  }

  setDisplayName(name: string) {
    this.engineOrThrow.setDisplayName(name.trim())
    this.refreshIdentity()
    this.node?.reregister()
  }

  async registerHandle(handle: string): Promise<string | null> {
    const h = handle.trim().toLowerCase()
    if (!/^[a-z0-9_.-]{3,32}$/.test(h)) return 'De 3 à 32 caractères : lettres, chiffres, point, tiret.'
    if (!this.node) return 'Aucun nœud.'
    await this.updateSettings({ handle: h })
    try {
      const r = await this.node.registerHandle(h, this.myCard())
      if (r.ok) {
        this.node.reregister()
        return null
      }
      if (r.msg === 'unsupported') return 'Le moteur ne sait pas encore signer pour l’annuaire.'
      return r.status === 409 ? 'Cet identifiant est déjà pris.' : `Le nœud a refusé (${r.status}).`
    } catch {
      return 'Nœud injoignable.'
    }
  }

  backupFile(): Blob {
    const state = this.engineOrThrow.exportState()
    return new Blob(
      [JSON.stringify({ kind: 'soma-relay-backup', v: 1, engine: this.engine?.kind, state: toB64(state) })],
      { type: 'application/json' },
    )
  }

  async wipe() {
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
