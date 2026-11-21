import type { Attachment, GeoPoint, LinkPreview, PollSpec } from '../core/engine'

/** How a message travelled. `local` is the in-browser test bus (two tabs, no node). */
export type Transport = 'net' | 'p2p' | 'local'

export type Status = 'pending' | 'sent' | 'delivered' | 'read' | 'failed'

export type ChatKind = 'text' | 'image' | 'audio' | 'video' | 'file' | 'call' | 'system' | 'poll' | 'location'

export interface ChatMessage {
  id: string
  convId: string
  /** 'me' or the sender fingerprint. */
  from: string
  ts: number
  kind: ChatKind
  text?: string
  replyTo?: string
  attachment?: Attachment
  status: Status
  transport?: Transport
  /** emoji -> fingerprints ('me' for us). */
  reactions?: Record<string, string[]>
  call?: { video: boolean; outcome: 'missed' | 'ended' | 'declined' | 'busy'; durationMs?: number }
  /** Time of the last accepted edit. */
  editedAt?: number
  /** Deleted for everyone: the bubble shows "Message supprimé". */
  deleted?: boolean
  poll?: PollSpec
  /** Voter ('me' or fingerprint) -> latest vote. */
  votes?: Record<string, { opts: string[]; ts: number }>
  pollClosed?: boolean
  location?: GeoPoint
  /** Time of the last live location update. */
  locationTs?: number
  liveStopped?: boolean
  link?: LinkPreview
  forwarded?: boolean
  mentions?: string[]
  /** Disappearing timer carried by the message (seconds). */
  expireS?: number
  /** When the message is deleted (set once seen). */
  expireAt?: number
  /** When each status was reached, for the Info sheet. */
  times?: Partial<Record<Status | 'received', number>>
}

export interface Conversation {
  /** Direct: the peer fingerprint. Group: 'g:' + group id. */
  id: string
  kind: 'direct' | 'group'
  title: string
  lastTs: number
  preview: string
  unread: number
  transport?: Transport
  draft?: string
  /** Disappearing messages timer, seconds (0 = off). */
  expireS?: number
  /** Some messages of this conversation carry a timer: sweep it at start. */
  hadExpiring?: boolean
  /** Muted until this time (ms). MUTE_ALWAYS for always. */
  mutedUntil?: number
}

export const MUTE_ALWAYS = 8.64e15

export const EXPIRE_CHOICES = [0, 300, 3600, 86400, 604800] as const

export interface Settings {
  /** Empty = same origin (the node serves the web client). */
  nodeUrl: string
  handle: string
  /** In-browser test bus between tabs of this browser, used when no node answers. */
  localBus: boolean
  p2p: boolean
  /** Sender-side link previews through the node (on by default). */
  linkPreviews: boolean
  /** Notifications on (browser permission still required). */
  notifications: boolean
  /** Show sender and text in notifications, else "Nouveau message". */
  notifPreviews: boolean
}

export type NodeState = 'off' | 'connecting' | 'online' | 'offline'

export interface OutboxItem {
  id: string
  /** Mailbox hex the envelope goes to. */
  to: string
  env: string
  msgId?: string
  convId?: string
  ts: number
}
