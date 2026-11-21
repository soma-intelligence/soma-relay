// MockEngine: UI development stand-in for relay-core. NOT SECURE.
//
// "Encryption" is base64 JSON. It keeps the same shapes as the core (cards, envelopes with a
// postcard-like header, mailbox ids derived like the spec) so the rest of the client runs
// unchanged when the wasm engine lands. Two profiles running the mock can talk to each other
// through a node or through the local test bus.

import { sha3_256 } from '@noble/hashes/sha3.js'
import { sha256 } from '@noble/hashes/sha2.js'
import {
  concat,
  fromB64,
  fromHex,
  fromUtf8,
  randomBytes,
  toB64Url,
  toHex,
  utf8,
} from '../lib/bytes'
import type {
  AppMessage,
  CompactLink,
  Contact,
  Engine,
  EngineFactory,
  EnvelopeHeader,
  Group,
  Inbound,
} from './engine'
import { RelayError } from './engine'

const WORDS = [
  'lanterne', 'orage', 'cobalt', 'mesure', 'falaise', 'givre', 'boussole', 'ardoise',
  'cerise', 'dune', 'escale', 'fougère', 'grenat', 'hibou', 'ivoire', 'jasmin',
  'kayak', 'lagune', 'mistral', 'nacre', 'opale', 'phare', 'quartz', 'récif',
  'safran', 'tilleul', 'ultra', 'velours', 'wagon', 'xénon', 'yole', 'zénith',
]

interface MockCard {
  v: 1
  name: string
  fp: string
  node_url?: string
  handle?: string
  created_at: number
}

interface MockState {
  v: 1
  name: string
  fp: string
  contacts: Contact[]
  groups: Group[]
  channels: string[]
  seen: string[]
}

interface MockEnvelopeBody {
  from: string
  card?: string
  group?: string
  channel?: string
  message: AppMessage
}

const ENVELOPE_KIND = { direct: 1, group: 2, channel: 3 } as const

export function mailboxFor(fpHex: string): string {
  return toHex(sha3_256(concat(utf8('soma-relay/mailbox'), fromHex(fpHex))).slice(0, 16))
}

function wordsFrom(bytes: Uint8Array): string[] {
  return Array.from(bytes.slice(0, 4), (b) => WORDS[b % WORDS.length])
}

function cardText(card: MockCard): string {
  return 'relay1:' + toB64Url(utf8(JSON.stringify(card)))
}

function parseCard(text: string): MockCard {
  const t = text.trim()
  if (!t.startsWith('relay1:')) throw new RelayError('InvalidCard', 'not a relay1 card')
  try {
    const card = JSON.parse(fromUtf8(fromB64(t.slice(7)))) as MockCard
    if (!card.fp || card.fp.length !== 64) throw new Error('fp')
    return card
  } catch {
    throw new RelayError('InvalidCard', 'card does not decode')
  }
}

/** Envelope = v(1) kind(1) tag(16) ttl(1) id(16) then the base64 JSON body, like postcard. */
function buildEnvelope(kind: number, tag: Uint8Array, body: MockEnvelopeBody): Uint8Array {
  const json = utf8(toB64Url(utf8(JSON.stringify(body))))
  return concat(new Uint8Array([1, kind]), tag, new Uint8Array([7]), randomBytes(16), json)
}

class MockEngineImpl implements Engine {
  readonly kind = 'mock' as const
  private s: MockState

  constructor(state: MockState) {
    this.s = state
  }

  private get myCardText(): string {
    return cardText({ v: 1, name: this.s.name, fp: this.s.fp, created_at: Date.now() })
  }

  exportState(): Uint8Array {
    return utf8(JSON.stringify(this.s))
  }
  fingerprintHex(): string {
    return this.s.fp
  }
  safetyWords(): string[] {
    return wordsFrom(fromHex(this.s.fp))
  }
  mailboxHex(): string {
    return mailboxFor(this.s.fp)
  }
  displayName(): string {
    return this.s.name
  }
  setDisplayName(name: string): void {
    this.s.name = name
  }
  myCard(nodeUrl?: string | null, handle?: string | null): string {
    return cardText({
      v: 1,
      name: this.s.name,
      fp: this.s.fp,
      node_url: nodeUrl ?? undefined,
      handle: handle ?? undefined,
      created_at: Date.now(),
    })
  }
  myCompactLink(nodeUrl?: string | null): string {
    const fp = fromHex(this.s.fp)
    const url = utf8(nodeUrl ?? '')
    return 'relay1c:' + toB64Url(concat(fp, new Uint8Array([url.length]), url))
  }
  deviceSigningPublic(): Uint8Array {
    return sha256(utf8('mock-device-' + this.s.fp))
  }
  signNodeChallenge(nonce: Uint8Array): Uint8Array {
    // A mock signature: a real node rejects it. Fine for the local test bus.
    const h = sha256(concat(utf8('soma-relay/node-auth/v1'), nonce, fromHex(this.mailboxHex())))
    return concat(h, h)
  }
  rotatePrekeyIfDue(): boolean {
    return false
  }

  addContact(card: string): Contact {
    return this.add(card, false)
  }
  addContactReplacing(card: string): Contact {
    return this.add(card, true)
  }
  private add(text: string, replace: boolean): Contact {
    const card = parseCard(text)
    if (card.fp === this.s.fp) throw new RelayError('InvalidCard', 'this is your own card')
    const existing = this.s.contacts.find((c) => c.fingerprint === card.fp)
    if (existing) {
      if (replace) existing.name = card.name
      if (card.node_url) existing.node_url = card.node_url
      if (card.handle) existing.handle = card.handle
      return existing
    }
    const contact: Contact = {
      fingerprint: card.fp,
      name: card.name,
      mailbox: mailboxFor(card.fp),
      verified: false,
      node_url: card.node_url,
      handle: card.handle,
      added_at: Date.now(),
    }
    this.s.contacts.push(contact)
    return contact
  }
  parseCompactLink(link: string): CompactLink {
    const t = link.trim()
    if (!t.startsWith('relay1c:')) throw new RelayError('Malformed', 'not a relay1c link')
    const b = fromB64(t.slice(8))
    if (b.length < 33) throw new RelayError('Malformed', 'short link')
    const len = b[32]
    const url = fromUtf8(b.slice(33, 33 + len))
    return { fingerprint: toHex(b.slice(0, 32)), node_url: url || undefined }
  }
  contacts(): Contact[] {
    return this.s.contacts.map((c) => ({ ...c }))
  }
  removeContact(fp: string): void {
    this.s.contacts = this.s.contacts.filter((c) => c.fingerprint !== fp)
  }
  setVerified(fp: string, verified: boolean): void {
    const c = this.s.contacts.find((x) => x.fingerprint === fp)
    if (c) c.verified = verified
  }
  renameContact(fp: string, name: string): void {
    const c = this.s.contacts.find((x) => x.fingerprint === fp)
    if (c) c.name = name
  }
  private pair(fp: string): Uint8Array {
    const [a, b] = [this.s.fp, fp].sort()
    return sha256(concat(utf8('pair'), fromHex(a), fromHex(b)))
  }
  contactSafetyWords(fp: string): string[] {
    return wordsFrom(this.pair(fp))
  }
  contactSafetyCode(fp: string): string {
    const h = this.pair(fp)
    const n = (i: number) => (((h[i] << 8) | h[i + 1]) % 1000).toString().padStart(3, '0')
    return `${n(4)} ${n(6)} ${n(8)}`
  }

  encryptFor(fp: string, message: AppMessage): Uint8Array {
    const c = this.s.contacts.find((x) => x.fingerprint === fp)
    if (!c) throw new RelayError('NoSession', 'unknown contact')
    return buildEnvelope(ENVELOPE_KIND.direct, fromHex(c.mailbox), {
      from: this.s.fp,
      card: this.myCardText,
      message,
    })
  }
  meshTagFor(fp: string): Uint8Array {
    return fromHex(mailboxFor(fp))
  }
  retagForMesh(envelope: Uint8Array): Uint8Array {
    return envelope
  }
  open(envelope: Uint8Array): Inbound | null {
    const h = this.envelopeHeader(envelope)
    if (!h) throw new RelayError('Malformed', 'bad envelope')
    if (this.s.seen.includes(h.id)) return null
    let body: MockEnvelopeBody
    try {
      body = JSON.parse(fromUtf8(fromB64(fromUtf8(envelope.slice(35))))) as MockEnvelopeBody
    } catch {
      throw new RelayError('Decrypt', 'mock body does not decode')
    }
    if (h.kind === ENVELOPE_KIND.direct && h.tag !== this.mailboxHex()) return null
    if (h.kind === ENVELOPE_KIND.group) {
      const g = this.s.groups.find((x) => x.id === body.group)
      if (!g) {
        // A group we have not heard of: the first message carries the group state.
        const gs = body.message.group as { state?: Group } | undefined
        if (!gs?.state) return null
        this.s.groups.push(gs.state)
      } else if (body.message.kind === 'group-op') {
        const gs = body.message.group as { state?: Group } | undefined
        if (gs?.state) Object.assign(g, gs.state)
      }
    }
    this.s.seen.push(h.id)
    if (this.s.seen.length > 4096) this.s.seen.splice(0, 1024)
    if (body.from !== this.s.fp && !this.s.contacts.some((c) => c.fingerprint === body.from) && body.card) {
      try {
        this.add(body.card, false)
      } catch {
        /* ignore a bad card */
      }
    }
    if (body.from === this.s.fp) return null
    return {
      from: body.from,
      group: body.group,
      channel: body.channel,
      message: body.message,
      envelope_id: h.id,
    }
  }

  createGroup(name: string, memberFps: string[]): string {
    const id = toHex(randomBytes(16))
    this.s.groups.push({ id, name, members: [this.s.fp, ...memberFps], admins: [this.s.fp] })
    return id
  }
  private groupEnvelopes(g: Group, message: AppMessage): Uint8Array[] {
    // The mock carries the group state in every group message so late joiners catch up.
    const withState: AppMessage =
      message.kind === 'group-op' ? message : { ...message, group: { ...(message.group ?? {}), state: g } }
    return [
      buildEnvelope(ENVELOPE_KIND.group, fromHex(g.id), {
        from: this.s.fp,
        card: this.myCardText,
        group: g.id,
        message: withState,
      }),
    ]
  }
  groupEncrypt(groupId: string, message: AppMessage): Uint8Array[] {
    const g = this.s.groups.find((x) => x.id === groupId)
    if (!g) throw new RelayError('Group', 'unknown group')
    return this.groupEnvelopes(g, message)
  }
  groups(): Group[] {
    return this.s.groups.map((g) => ({ ...g, members: [...g.members], admins: [...g.admins] }))
  }
  private op(g: Group, op: string): Uint8Array[] {
    return this.groupEnvelopes(g, {
      id: toHex(randomBytes(8)),
      ts: Date.now(),
      kind: 'group-op',
      group: { op, state: g },
    })
  }
  groupAdd(groupId: string, fp: string): Uint8Array[] {
    const g = this.s.groups.find((x) => x.id === groupId)
    if (!g) throw new RelayError('Group', 'unknown group')
    if (!g.members.includes(fp)) g.members.push(fp)
    return this.op(g, 'add')
  }
  groupRemove(groupId: string, fp: string): Uint8Array[] {
    const g = this.s.groups.find((x) => x.id === groupId)
    if (!g) throw new RelayError('Group', 'unknown group')
    g.members = g.members.filter((m) => m !== fp)
    return this.op(g, 'remove')
  }
  leaveGroup(groupId: string): void {
    this.s.groups = this.s.groups.filter((g) => g.id !== groupId)
  }

  channelEncrypt(name: string, _password: string | null, message: AppMessage): Uint8Array {
    return buildEnvelope(ENVELOPE_KIND.channel, sha256(utf8(name)).slice(0, 16), {
      from: this.s.fp,
      channel: name,
      message,
    })
  }
  joinChannel(name: string): void {
    if (!this.s.channels.includes(name)) this.s.channels.push(name)
  }
  leaveChannel(name: string): void {
    this.s.channels = this.s.channels.filter((c) => c !== name)
  }

  sealAttachment(plain: Uint8Array): Uint8Array {
    // Mock: XOR with a key stream derived from a random key. Not encryption, just not plain.
    const key = randomBytes(32)
    return concat(key, sha256(plain), xorStream(key, plain))
  }
  openAttachment(key: Uint8Array, sha: Uint8Array, ciphertext: Uint8Array): Uint8Array {
    const plain = xorStream(key, ciphertext)
    if (toHex(sha256(plain)) !== toHex(sha)) throw new RelayError('Decrypt', 'attachment hash mismatch')
    return plain
  }

  callKey(fp: string, callId: string): Uint8Array {
    return sha256(concat(this.pair(fp), utf8(callId)))
  }

  envelopeHeader(envelope: Uint8Array): EnvelopeHeader | null {
    if (envelope.length < 35 || envelope[0] !== 1) return null
    return { kind: envelope[1], tag: toHex(envelope.slice(2, 18)), id: toHex(envelope.slice(19, 35)) }
  }
}

function xorStream(key: Uint8Array, data: Uint8Array): Uint8Array {
  const out = new Uint8Array(data.length)
  let block = sha256(key)
  for (let i = 0; i < data.length; i++) {
    if (i % 32 === 0 && i > 0) block = sha256(concat(key, block))
    out[i] = data[i] ^ block[i % 32]
  }
  return out
}

export const MockEngineFactory: EngineFactory = {
  kind: 'mock',
  create(displayName: string): Engine {
    return new MockEngineImpl({
      v: 1,
      name: displayName,
      fp: toHex(randomBytes(32)),
      contacts: [],
      groups: [],
      channels: [],
      seen: [],
    })
  },
  restore(state: Uint8Array): Engine {
    const s = JSON.parse(fromUtf8(state)) as MockState
    if (s.v !== 1 || !s.fp) throw new RelayError('Storage', 'bad mock state')
    return new MockEngineImpl(s)
  },
}
