// The relay-core surface the web client codes against (docs/specs/core-api.md, camelCase).
//
// Two implementations:
// - WasmEngine wraps the wasm-bindgen build in ./pkg (relay_wasm.js), the real thing.
// - MockEngine fakes the crypto with base64 JSON so the UI can be built before the core
//   exists. It is never chosen when the pkg is present.
//
// JSON strings of the core (ContactJson, InboundJson, groups) are parsed by the adapters,
// so callers get typed objects. AppMessage keeps the wire field names (snake_case).

export type AppKind =
  | 'text'
  | 'image'
  | 'audio'
  | 'video'
  | 'file'
  | 'receipt'
  | 'typing'
  | 'call'
  | 'reaction'
  | 'group-op'
  | 'profile'

export interface Attachment {
  mime: string
  size: number
  /** SHA-256 of the plaintext, hex. */
  sha256: string
  /** AES-256-GCM key, base64 (32 bytes). */
  key: string
  name?: string
  width?: number
  height?: number
  duration_ms?: number
  /** Tiny preview, base64 JPEG/WebP, at most 4 KiB. */
  thumb?: string
  /** The encrypted file itself, base64, when it is at most 48 KiB. */
  inline?: string
  /** Node blob URL of the encrypted file. */
  url?: string
}

export type CallAction = 'offer' | 'answer' | 'ice' | 'end' | 'decline' | 'busy'

export interface CallSignal {
  call_id: string
  action: CallAction
  sdp?: string
  candidate?: string
  video: boolean
}

export interface AppMessage {
  id: string
  ts: number
  kind: AppKind
  text?: string
  reply_to?: string
  attachment?: Attachment
  receipt?: { of: string[]; state: 'delivered' | 'read' }
  call?: CallSignal
  group?: Record<string, unknown>
}

export interface Contact {
  fingerprint: string
  name: string
  mailbox: string
  verified: boolean
  node_url?: string
  handle?: string
  added_at: number
}

export interface CompactLink {
  fingerprint: string
  node_url?: string
  handle?: string
}

export interface Inbound {
  from: string
  group?: string
  channel?: string
  message: AppMessage
  envelope_id: string
}

export interface Group {
  id: string
  name: string
  members: string[]
  admins: string[]
  /** Mailbox of each member (hex), same order as `members` (relay-core 0.1 addition). */
  mailboxes?: string[]
}

/** Envelope header fields read on the client side (not part of the core API). */
export interface EnvelopeHeader {
  kind: number
  /** Routing tag, hex: a mailbox id for node delivery. */
  tag: string
  /** Envelope id, hex, used for node acks and dedup. */
  id: string
}

export class RelayError extends Error {
  constructor(
    public code:
      | 'InvalidCard'
      | 'KeyChanged'
      | 'NoSession'
      | 'Decrypt'
      | 'Malformed'
      | 'Unknown'
      | 'Storage'
      | 'Group',
    message: string,
  ) {
    super(message)
  }
}

export interface Engine {
  readonly kind: 'wasm' | 'mock'

  // Identity
  exportState(): Uint8Array
  fingerprintHex(): string
  safetyWords(): string[]
  mailboxHex(): string
  displayName(): string
  setDisplayName(name: string): void
  myCard(nodeUrl?: string | null, handle?: string | null): string
  myCompactLink(nodeUrl?: string | null): string
  deviceSigningPublic(): Uint8Array
  signNodeChallenge(nonce: Uint8Array): Uint8Array
  rotatePrekeyIfDue(nowMs: number): boolean

  // Contacts
  addContact(card: string): Contact
  addContactReplacing(card: string): Contact
  parseCompactLink(link: string): CompactLink
  contacts(): Contact[]
  removeContact(fp: string): void
  setVerified(fp: string, verified: boolean): void
  renameContact(fp: string, name: string): void
  contactSafetyWords(fp: string): string[]
  contactSafetyCode(fp: string): string

  // Messaging
  encryptFor(fp: string, message: AppMessage): Uint8Array
  meshTagFor(fp: string, nowMs: number): Uint8Array
  retagForMesh(envelope: Uint8Array, fp: string, nowMs: number): Uint8Array
  open(envelope: Uint8Array, nowMs: number): Inbound | null

  // Groups
  createGroup(name: string, memberFps: string[]): string
  groupEncrypt(groupId: string, message: AppMessage): Uint8Array[]
  groups(): Group[]
  groupAdd(groupId: string, fp: string): Uint8Array[]
  groupRemove(groupId: string, fp: string): Uint8Array[]
  leaveGroup(groupId: string): void

  // Local channels (mesh only, the web never sends on them)
  channelEncrypt(name: string, password: string | null, message: AppMessage): Uint8Array
  joinChannel(name: string, password: string | null): void
  leaveChannel(name: string): void

  // Attachments: output is key(32) || sha256(32) || ciphertext
  sealAttachment(plain: Uint8Array): Uint8Array
  openAttachment(key: Uint8Array, sha256: Uint8Array, ciphertext: Uint8Array): Uint8Array

  // Calls
  callKey(fp: string, callId: string): Uint8Array

  /**
   * Optional, not in core-api yet: Ed25519 signature by the device key over raw bytes, used by
   * the node directory (`X-Relay-Sig`). Absent: handle publishing is unavailable.
   */
  signDetached?(message: Uint8Array): Uint8Array

  // Client-side helper, not in the core: reads the postcard header of an envelope.
  envelopeHeader(envelope: Uint8Array): EnvelopeHeader | null
}

export interface EngineFactory {
  readonly kind: 'wasm' | 'mock'
  create(displayName: string): Engine
  restore(state: Uint8Array): Engine
}
