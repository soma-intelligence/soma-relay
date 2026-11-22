# Soma Relay: passkey unlock and backup (OnePass)

Date: 2026-11-22. Extends [2026-11-21-soma-relay-design.md](2026-11-21-soma-relay-design.md).

The owner asked for two things: when the user has OnePass, Relay unlocks with one gesture, and a new phone gets the Relay identity back from OnePass. Today Relay has no lock, no account and no backup: the identity is the engine state on one device, the storage key is `ThisDeviceOnly`, and the `.relaykey` export is plaintext.

The design uses a standard passkey with the WebAuthn PRF extension. OnePass stores the passkey; any other provider that supports PRF (iCloud Keychain, 1Password, Chrome) works the same way. Nothing in Relay is specific to OnePass.

Owner rulings (2026-11-22):

- Relying party domain: `hushrelay.app` (first `relay.somalabs.me`, changed the same day: Relay gets its own identity, not tied to Soma Labs; the app name stays Soma Relay).
- A restore brings back identity, contacts, groups and channels. No message history in v1.
- Relock delay is a setting: immediately, 1 min (default), 15 min, 1 h, never.

## 1. The passkey

- Relying party id `hushrelay.app`. User name: the handle when there is one, else the display name. User handle: 16 random bytes, kept in the engine metadata.
- Created with `prf` requested, `residentKey: required`, `userVerification: required`.
- Created at onboarding (step "Protéger avec un passkey", skippable) and from Settings > Sécurité for existing accounts.
- Relay stores the credential id (UserDefaults, not secret) to pass it in `allowCredentials` on unlock.
- One assertion can evaluate two PRF salts (`first`, `second`):
  - `first` = `SHA-256("soma-relay/unlock/v1")`
  - `second` = `SHA-256("soma-relay/backup/v1")`

Key derivation from a 32-byte PRF output `p`:

```
unlock_key = HKDF-SHA256(ikm = p_first,  salt = "", info = "soma-relay unlock v1", 32)
vault_key  = HKDF-SHA256(ikm = p_second, salt = "", info = "soma-relay vault v1", 32)
vault_id   = hex(SHA-256("soma-relay vault id v1" || credential_id))
```

## 2. Daily unlock

- Relay shows a lock screen at launch and when it returns to the foreground after the relock delay. The app switcher snapshot is covered by the same screen.
- The lock screen has one button, "Déverrouiller". On launch it starts the assertion by itself, once.
- With a PRF result, Relay computes `HMAC-SHA256(unlock_key, "ok")` and compares it in constant time with the check value stored in the Keychain (`me.somalabs.relay.lock`, `AfterFirstUnlockThisDeviceOnly`). Match: unlocked.
- Without PRF (provider does not support it), or with no passkey, the lock falls back to `LAContext` with `.deviceOwnerAuthentication` (Face ID, then device passcode).
- The lock is a UI gate. `SecretBox` keeps its key as today, so background fetch, the notification path and the mesh keep working while the app is locked. Notification bodies follow the existing preview setting.
- Turning the lock on needs one successful unlock first, so a user cannot lock themselves out. Turning it off needs an unlock.
- Wipe (`AppModel.wipe`) also deletes the check value, the credential id and the lock settings.

## 3. Backup and restore

### Blob

```
blob      = "RVB1" || nonce(12) || AES-256-GCM(vault_key, nonce, plaintext, aad = vault_id)
plaintext = postcard { v: 1, engine: export_state(), handle, node_url, channels_prefs, display_photo? (≤ 64 KiB) }
```

Max blob size 1 MiB. The engine state contains the session state, so the backup must stay current, otherwise a restore desynchronizes sessions. Relay re-uploads the blob after every engine save, debounced to 10 s, and on going to background, including saves made by background fetch.

Background uploads cannot run a passkey ceremony, so after the first PRF result Relay keeps `vault_key` in the Keychain (`me.somalabs.relay.vault`, `AfterFirstUnlockThisDeviceOnly`). This is the same protection as the storage key, which already decrypts everything the blob holds, so it adds no new exposure on this device.

### Node routes

```
PUT /v1/vault/{vault_id}   body = blob
    X-Relay-Mailbox: <32 hex>   X-Relay-Sig: base64 Ed25519 over ("relay-vault-v1" || vault_id || SHA-256(blob))
GET /v1/vault/{vault_id}   -> blob, or 404
```

- PUT checks the signature against the mailbox binding, as `PUT /v1/directory` does. The first PUT records the owner mailbox; later PUTs from another mailbox get 403. A restored device has the same identity, hence the same mailbox, so it can keep writing.
- GET needs no auth: `vault_id` is unguessable without the credential id, and the blob is encrypted. GET is rate limited per IP like the other routes.
- Retention: a vault not written for 400 days is deleted.
- The node never sees a key, a PRF output or a credential id.

### Restore on a new phone

- Onboarding gets a second button, "Restaurer avec un passkey".
- Relay runs a discoverable assertion (empty `allowCredentials`) with both salts. OnePass shows the Relay passkey; Face ID.
- From the result: credential id, then `vault_id`; `GET /v1/vault/{vault_id}`; decrypt with `vault_key`; `RelayCoreFactory.restore(state:)`.
- Relay then writes the unlock check value, stores the credential id, reconnects to the node and announces itself as usual.
- Errors shown in plain words: no blob ("Aucune sauvegarde pour ce passkey"), decryption failure, no network.
- The old phone keeps working. Two devices with the same identity is out of scope; the restore screen says to use the new phone from now on.

### `.relaykey` export

The current export writes `relaystate1:<base64 state>` in clear. It becomes `relaystate2:` sealed with a key from a passphrase the user types (Argon2id, then AES-256-GCM). Import accepts both formats. This is separate from the passkey path and stays for users without a passkey.

## 4. Domain and app association

- Domain: `hushrelay.app`, independent of Soma Labs (owner ruling 2026-11-22). Apex A record to the VM static IP `40.64.127.19`. Bought by the owner (Vercel registrar quote: $9.99 first year, $15 renewal); until then nothing on this domain resolves.
- TLS: the VM reverse proxy gets a certificate for `hushrelay.app` next to the Azure name. Both names keep serving the node and the web app.
- The node serves `/.well-known/apple-app-site-association`:
  ```
  { "webcredentials": { "apps": ["M968YV4J8W.me.somalabs.relay"] } }
  ```
- The iOS app gets the entitlement `com.apple.developer.associated-domains` = `webcredentials:hushrelay.app` (App ID capability on developer.apple.com).
- Clients default to `https://hushrelay.app` as node URL. Existing installs keep their stored URL.

## 5. OnePass: PRF in the credential provider

OnePass already provides passkeys (`ProvidesPasskeys`) but does not answer the PRF extension. iOS 18 passes PRF inputs to the provider in the registration and assertion requests and takes PRF outputs back in the credential.

- The PRF secret of a passkey is derived from its private key (the stored PKCS#8 bytes): `prf_secret = HKDF-SHA256(private_key, salt "", info "onepass webauthn prf v1", 32)`. Owner ruling: derived, not a stored random seed.
  - No new field and no migration: passkeys created before this change answer PRF as they are.
  - The private key already syncs with the item, so every device computes the same outputs.
- Output for a salt `s`: `HMAC-SHA256(prf_secret, SHA-256("WebAuthn PRF" || 0x00 || s))`, the WebAuthn mapping of CTAP `hmac-secret` (the RP salt is hashed before it reaches `hmac-secret`).
- Registration: report `prf.enabled = true`, and outputs when inputs are given.
- Assertion: outputs for `first` and, when present, `second`. Per-credential inputs (`evalByCredential`) are honored.
- This works for every relying party, not only Relay.
- Same code on iOS and macOS AutoFill.

## 6. Web

- Same passkey on the same relying party, through WebAuthn with the `prf` extension (Chrome, Safari 18+, Firefox with a supporting provider). Requires the web app served from `hushrelay.app`.
- Web gets backup and restore in this work. The web lock screen is out of scope.
- Browsers without PRF: the passkey step is hidden and the `.relaykey` export remains.

## 7. Tests

- Core vectors: HKDF derivations, blob seal/open, AAD mismatch rejected, size cap. Same vectors in Rust and Swift (and TypeScript for the web).
- Node: PUT with a bad signature, an unknown mailbox, another owner's mailbox, an oversize blob; GET 404; retention sweep.
- OnePass: PRF output against an independently computed vector; same output from a copy of the passkey (another device); two salts in one assertion.
- Web e2e: Chrome virtual authenticator with PRF. Flow: create account, add passkey, send messages, new browser profile, restore, keep talking with the old contact.
- iOS UI tests: lock screen covers content, relock after the delay, Face ID fallback path (simulator enrolled).
- Device checks, owner: OnePass on the iPhone, restore on a second device, the AASA association.

## 8. Order of work

1. Node: vault routes, AASA, `hushrelay.app` DNS and TLS.
2. Shared crypto (core vectors), then iOS: passkey creation, lock screen, backup upload, restore, `.relaykey` v2.
3. OnePass: PRF in the credential provider (OnePass repo, separate PR).
4. Web: passkey, backup, restore, e2e.

Steps 1, 3 and the crypto part of 2 do not depend on each other.

## Out of scope

- Message history and media in the backup.
- Several active devices for one identity.
- Web lock screen.
- Recovery when the passkey is lost: the `.relaykey` export remains the way out.
