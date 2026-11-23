// Passkey backup state of the web client (spec 2026-11-22-passkey-unlock-backup, section 3).
//
// The vault record sits in the sealed `meta` store next to the engine state, so the vault key has
// the same protection as the state it encrypts (a non-extractable WebCrypto key of the same
// database). It holds the credential id, the 16 byte user handle, and the vault key derived from
// the PRF output (never the PRF output itself). No secret is ever logged.

export interface VaultRecord {
  /** Base64 credential id of the Relay passkey (not secret). */
  credentialId: string
  /** Base64, 16 random bytes handed to the passkey as its user handle. */
  userHandle: string
  /** Base64 vault key. Absent when the manager has no PRF: the passkey exists, no backup. */
  key?: string
  /** An upload is owed. */
  dirty: boolean
  savedAt?: number
}

export type VaultState = 'off' | 'lockOnly' | 'saved' | 'pending' | 'failed'

export interface VaultStatus {
  state: VaultState
  /** Last accepted upload (ms). */
  at?: number
  message?: string
  /** A setup or an upload is running. */
  busy: boolean
}

export const VAULT_OFF: VaultStatus = { state: 'off', busy: false }

/** Debounce after the last engine save (spec: 10 s). */
export const VAULT_DEBOUNCE_MS = 10_000

export function statusOf(rec: VaultRecord | null): VaultStatus {
  if (!rec) return VAULT_OFF
  if (!rec.key) return { state: 'lockOnly', busy: false }
  if (rec.dirty || !rec.savedAt) return { state: 'pending', busy: false }
  return { state: 'saved', at: rec.savedAt, busy: false }
}

export function refusedMessage(code: string): string {
  switch (code) {
    case 'not_owner':
      return 'Ce passkey sauvegarde déjà une autre identité sur ce nœud.'
    case 'bad_signature':
      return 'Le nœud a refusé la signature de la sauvegarde.'
    case 'too_large':
      return 'Sauvegarde trop lourde pour le nœud.'
    default:
      return `Sauvegarde refusée par le nœud (${code}).`
  }
}

/** Codes that leave an upload owed rather than failed: the node link or its auth is not there yet. */
export const RETRYABLE = new Set(['unknown_mailbox', 'rate_limited'])

/** Why a restore from a passkey did not finish. Nothing local changed in any case. */
export type RestoreFailure = 'cancelled' | 'noPasskey' | 'unavailable' | 'noBackup' | 'cannotOpen' | 'network'

export class PasskeyRestoreError extends Error {
  constructor(public failure: RestoreFailure) {
    super(failure)
  }

  /** Text under the restore button; null when the person cancelled on purpose. */
  get text(): string | null {
    switch (this.failure) {
      case 'cancelled':
        return null
      case 'noPasskey':
        return 'Aucun passkey Relay trouvé.'
      case 'unavailable':
        return 'Les passkeys ne sont pas disponibles sur ce navigateur.'
      case 'noBackup':
        return 'Aucune sauvegarde pour ce passkey'
      case 'cannotOpen':
        return 'Ce passkey ne peut pas ouvrir la sauvegarde'
      case 'network':
        return 'Pas de réseau'
    }
  }
}

export const RESTORED_TOAST = 'Identité restaurée. Utilise ce navigateur désormais.'
