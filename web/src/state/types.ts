import type { Attachment } from '../core/engine'

/** How a message travelled. `local` is the in-browser test bus (two tabs, no node). */
export type Transport = 'net' | 'p2p' | 'local'

export type Status = 'pending' | 'sent' | 'delivered' | 'read' | 'failed'

export type ChatKind = 'text' | 'image' | 'audio' | 'video' | 'file' | 'call' | 'system'

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
}

export interface Settings {
  /** Empty = same origin (the node serves the web client). */
  nodeUrl: string
  handle: string
  /** In-browser test bus between tabs of this browser, used when no node answers. */
  localBus: boolean
  p2p: boolean
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
