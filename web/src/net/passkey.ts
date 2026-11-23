// Passkey with the WebAuthn PRF extension (spec 2026-11-22-passkey-unlock-backup, sections 1 and 6).
//
// One assertion evaluates two salts: `first` for the unlock check (not used on the web, there
// is no web lock screen), `second` for the backup key. PRF outputs never leave this module's
// callers, are never logged and are never stored: only the vault key derived from `second` is
// kept, by the caller, in the sealed IndexedDB next to the engine state.

import { randomBytes, buf } from '../lib/bytes'

/** Relying party id: the production domain, or `localhost` for development. */
export function passkeyRpId(): string | null {
  const h = location.hostname
  return h === 'hushrelay.app' || h === 'localhost' ? h : null
}

export interface PasskeyAssertion {
  credentialId: Uint8Array
  first?: Uint8Array
  second?: Uint8Array
}

export type PasskeyErrorCode = 'cancelled' | 'noCredential' | 'unavailable'

export class PasskeyError extends Error {
  constructor(public code: PasskeyErrorCode) {
    super(code)
  }
}

/** The two salts, supplied by the core (`prfSaltUnlock`, `prfSaltBackup`). */
export interface PrfSalts {
  unlock: Uint8Array
  backup: Uint8Array
}

let salts: PrfSalts | null = null
/** Set once the core is loaded. */
export function setPrfSalts(s: PrfSalts) {
  salts = s
}

/**
 * Whether passkeys with PRF may work here. A browser that reports PRF as unsupported, or has no
 * WebAuthn, or is not on a relying party we own, hides the passkey UI. A passkey manager that
 * lacks PRF is only found out at the first assertion.
 */
export async function prfAvailable(): Promise<boolean> {
  if (!passkeyRpId() || typeof PublicKeyCredential === 'undefined' || !navigator.credentials) return false
  const pkc = PublicKeyCredential as unknown as {
    getClientCapabilities?: () => Promise<Record<string, boolean>>
  }
  try {
    if (pkc.getClientCapabilities) {
      const caps = await pkc.getClientCapabilities()
      if (caps['extension:prf'] === false) return false
    }
  } catch {
    /* unknown: keep going */
  }
  return true
}

interface PrfResults {
  prf?: { enabled?: boolean; results?: { first?: ArrayBuffer; second?: ArrayBuffer } }
}

function evalInput(): { first: BufferSource; second: BufferSource } {
  if (!salts) throw new PasskeyError('unavailable')
  return { first: buf(salts.unlock), second: buf(salts.backup) }
}

function failure(e: unknown): PasskeyError {
  if (e instanceof PasskeyError) return e
  const name = e instanceof DOMException ? e.name : ''
  // NotAllowedError is the user closing the sheet or no passkey matching: not told apart by
  // browsers. InvalidStateError: the credential already exists.
  if (name === 'NotAllowedError' || name === 'AbortError') return new PasskeyError('cancelled')
  return new PasskeyError('unavailable')
}

/** Creates a resident passkey asking for PRF. `prf` says whether the manager reported support. */
export async function registerPasskey(
  userName: string,
  userHandle: Uint8Array,
): Promise<{ credentialId: Uint8Array; prf: boolean }> {
  const rpId = passkeyRpId()
  if (!rpId || !navigator.credentials) throw new PasskeyError('unavailable')
  try {
    const cred = (await navigator.credentials.create({
      publicKey: {
        rp: { id: rpId, name: 'Soma Relay' },
        user: { id: buf(userHandle), name: userName, displayName: userName },
        challenge: buf(randomBytes(32)),
        pubKeyCredParams: [
          { type: 'public-key', alg: -7 },
          { type: 'public-key', alg: -257 },
        ],
        authenticatorSelection: { residentKey: 'required', userVerification: 'required' },
        extensions: { prf: {} } as AuthenticationExtensionsClientInputs,
      },
    })) as PublicKeyCredential | null
    if (!cred) throw new PasskeyError('cancelled')
    const ext = cred.getClientExtensionResults() as PrfResults
    return { credentialId: new Uint8Array(cred.rawId), prf: ext.prf?.enabled === true }
  } catch (e) {
    throw failure(e)
  }
}

/**
 * One assertion with both salts. With `credentialId` the passkey is named (daily use); without
 * it the browser offers every Relay passkey it can see (restore: discoverable, empty allow list).
 */
export async function assertPasskey(credentialId?: Uint8Array): Promise<PasskeyAssertion> {
  const rpId = passkeyRpId()
  if (!rpId || !navigator.credentials) throw new PasskeyError('unavailable')
  try {
    const cred = (await navigator.credentials.get({
      publicKey: {
        rpId,
        challenge: buf(randomBytes(32)),
        userVerification: 'required',
        allowCredentials: credentialId ? [{ type: 'public-key', id: buf(credentialId) }] : [],
        extensions: { prf: { eval: evalInput() } } as AuthenticationExtensionsClientInputs,
      },
    })) as PublicKeyCredential | null
    if (!cred) throw new PasskeyError('noCredential')
    const r = (cred.getClientExtensionResults() as PrfResults).prf?.results
    return {
      credentialId: new Uint8Array(cred.rawId),
      first: r?.first ? new Uint8Array(r.first) : undefined,
      second: r?.second ? new Uint8Array(r.second) : undefined,
    }
  } catch (e) {
    throw failure(e)
  }
}
